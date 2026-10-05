// ============================================================================
// HyperBus PSRAM 1 ダイ分の振る舞いモデル (x8, 32Mbit = 2M x 16bit)
//
//   - CS# Low 後の最初の CK 立ち上がりから 6 エッジで CA を受け取る
//   - レジスタ書き込み (CR0 @ 0x800) はレイテンシなしの 1 クロック
//   - メモリアクセスは固定レイテンシ (2 x LAT)。データは CA 最終クロックの後
//     GAP = 2*LAT-1 クロック空けて始まる (ここはモデルの仮定。コントローラは gap を自動探索する)
//   - 読み出し: CK の各エッジから TCKD 後にデータと RWDS (立ち上がり側=1, 立ち下がり側=0) を出す
//     CA 中は RWDS=1 (固定レイテンシ表示)、レイテンシ中は RWDS=0 を駆動する
//   - 書き込み: CK の各エッジで DQ をサンプル。RWDS=1 のバイトはマスク
//   - 起動時は CR0 既定値 (レイテンシ 6)。CR0 書き込みで更新
//
//   違反検出 ($error を数えて errors に出す):
//     CS# Low が TCSM を超えた / 書き込みバーストが行 (1KB) 境界をまたいだ /
//     RESET# 解除後 TVCS 経過前にアクセスした / CA 中に DQ が不定
// ============================================================================
`timescale 1ps / 1ps
module psram_model #(
    parameter integer TCKD  = 4000,       // CK エッジ -> 出力 (ps)
    parameter integer TCSM  = 4_000_000,  // CS# Low 最大 (ps)
    parameter integer TVCS  = 150_000_000, // RESET# 解除後の待ち (ps)
    // 1: 実機と同じく、CA で連続バーストを指定しても 16 ワード (32 バイト) で折り返す
    parameter integer WRAP16 = 1
)(
    input  wire       ck,
    input  wire       ck_n,
    input  wire       cs_n,
    input  wire       reset_n,
    inout  wire [7:0] dq,
    inout  wire       rwds
);
    reg [15:0] mem [0:(1<<21)-1];
    integer    errors = 0;
    integer    row_cross_reads = 0;
    reg [15:0] cr0 = 16'h8F1F;

    reg  [7:0] dq_o = 8'h00;
    reg        dq_oe = 1'b0, rw_o = 1'b0, rw_oe = 1'b0;
    // CS# High から tOZ (1ns) 後に出力を止める。遅延付きで予約した出力イネーブルが
    // CS# High 後に実行されても、ここで確実に切る
    wire cs_n_dly;
    assign #1000 cs_n_dly = cs_n;
    wire drive_ok = !(cs_n && cs_n_dly);
    assign dq   = (dq_oe && drive_ok) ? dq_o : 8'bz;
    assign rwds = (rw_oe && drive_ok) ? rw_o : 1'bz;

    function integer lat_of(input [3:0] code);
        case (code)
            4'b1110: lat_of = 3;
            4'b1111: lat_of = 4;
            4'b0000: lat_of = 5;
            4'b0001: lat_of = 6;
            4'b0010: lat_of = 7;
            default: lat_of = 6;
        endcase
    endfunction

    // ---- 状態 ----
    integer    edge_n;        // CS# Low 後の CK エッジ番号 (0 = 最初の立ち上がり)
    reg [47:0] ca;
    reg        is_rd, is_reg;
    reg [20:0] addr, addr0;
    integer    first_data_edge;
    reg [7:0]  hi_byte;
    reg        hi_mask;
    realtime   t_cs_fall, t_reset_rise = 0;
    reg        active = 1'b0;

    always @(posedge reset_n) t_reset_rise = $realtime;

    always @(negedge cs_n) begin
        if (ck === 1'b1) begin
            errors = errors + 1;
            $error("psram_model %m: CS# fell while CK high (CA would be misaligned)");
        end
        edge_n    = 0;
        ca        = 48'd0;
        active    = 1'b1;
        t_cs_fall = $realtime;
        if (!reset_n || $realtime - t_reset_rise < TVCS) begin
            errors = errors + 1;
            $error("psram_model %m: access before RESET#/tVCS");
        end
        // 固定レイテンシ: CA 中は RWDS=1。DQ は CA を受けるので離す
        dq_oe = 1'b0;
        rw_o = 1'b1; rw_oe = 1'b1;
    end

    always @(posedge cs_n) begin
        if (active && $realtime - t_cs_fall > TCSM) begin
            errors = errors + 1;
            $error("psram_model %m: CS# low %0t ps > tCSM", $realtime - t_cs_fall);
        end
        active = 1'b0;
    end

    // CS# High の間に CK が動いたら記録 (コントローラは CK を止める設計)
    integer ck_idle_toggles = 0;
    always @(ck) if (cs_n === 1'b1 && reset_n === 1'b1 && $realtime > 0) ck_idle_toggles = ck_idle_toggles + 1;

    // CK の両エッジで処理。CS# Low 後の最初のエッジから CA を数える (実デバイスと同じく厳密に)
    always @(ck) begin
        if (!cs_n && active) begin
            if (edge_n < 6) begin
                if (^dq === 1'bx) begin
                    errors = errors + 1;
                    $error("psram_model %m: DQ unknown during CA");
                end
                ca = {ca[39:0], dq};
                if (edge_n == 5) begin
                    is_rd  = ca[47];
                    is_reg = ca[46];
                    addr   = {ca[33:16], ca[2:0]};
                    addr0  = addr;
                    first_data_edge = is_reg ? 6 : 6 + 2 * (2 * lat_of(cr0[7:4]) - 1);
                    if (!is_reg) rw_o <= #TCKD 1'b0;     // レイテンシ中は Low
                end
            end else if (is_reg) begin
                if (!is_rd) begin
                    if (edge_n == 6) hi_byte = dq;
                    if (edge_n == 7 && {ca[33:16], ca[2:0]} == 21'h000800) begin
                        cr0 = {hi_byte, dq};
                    end
                end
            end else if (edge_n >= first_data_edge) begin
                if (is_rd) begin
                    // 読み出し: 立ち上がり = 上位バイト + RWDS=1
                    if (((edge_n - first_data_edge) % 2) == 0) begin
                        dq_o  <= #TCKD mem[addr][15:8];
                        rw_o  <= #TCKD 1'b1;
                    end else begin
                        dq_o  <= #TCKD mem[addr][7:0];
                        rw_o  <= #TCKD 1'b0;
                        if (addr[8:0] == 9'h1FF) row_cross_reads = row_cross_reads + 1;
                        addr = WRAP16 ? {addr[20:4], addr[3:0] + 4'd1} : addr + 1'b1;
                    end
                    dq_oe <= #TCKD 1'b1;
                end else begin
                    // 書き込み: 立ち上がり = 上位バイト
                    if (((edge_n - first_data_edge) % 2) == 0) begin
                        hi_byte = dq;
                        hi_mask = rwds;
                        rw_oe   = 1'b0;                     // 書き込みデータ中は駆動しない
                    end else begin
                        if (hi_mask !== 1'b1) mem[addr][15:8] = hi_byte;
                        if (rwds    !== 1'b1) mem[addr][7:0]  = dq;
                        addr = WRAP16 ? {addr[20:4], addr[3:0] + 4'd1} : addr + 1'b1;
                    end
                end
            end else if (!is_rd && edge_n == 6) begin
                rw_oe = 1'b0;                               // 書き込み: CA 後は RWDS を離す
            end
            // 書き込みで行境界をまたいだか (行の先頭ワードを、バースト先頭以外で書いた)
            if (!is_reg && !is_rd && edge_n > first_data_edge && ((edge_n - first_data_edge) % 2) == 0
                && addr[8:0] == 9'h000 && addr != addr0) begin
                errors = errors + 1;
                $error("psram_model %m: write burst crosses row boundary at %h", addr);
            end
            edge_n = edge_n + 1;
        end
    end
endmodule
