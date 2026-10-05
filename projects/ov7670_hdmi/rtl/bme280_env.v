// ============================================================================
// BME280 (I2C) を定期的に読み、温度・湿度・気圧の表示文字を作る (clk_mem ドメイン)
//   起動: BOOT 待ち -> ctrl_hum (0xF2) = 0x01 (湿度 x1), ctrl_meas (0xF4) = 0x27 (温度/気圧 x1, ノーマル),
//         config (0xF5) = 0xA0 (待機 1000ms, フィルタなし) を書き、品番 (0xD0)、
//         補正係数 (0x88..0xA1, 0xE1..0xE7) を読む
//   以後 PERIOD ごとに測定値 (0xF7..0xFE) を読み、env_calc で表示文字を作る
//   NACK (センサが応答しない) ならエラー表示にし、PERIOD 後に最初からやり直す
//   バイト RAM はセンサのレジスタアドレスそのまま (env_calc / tools/env_asm.py と共通)
//   表示文字は txt_we/txt_addr/txt_data で出す (行 * 16 + 桁, 文字コードは env_asm.py の CHARS)
// ============================================================================
module bme280_env #(
    parameter integer CLK_HZ = 45_000_000,
    parameter integer I2C_HZ = 100_000,
    parameter integer PERIOD = 45_000_000,     // 測定間隔 [クロック]
    parameter integer BOOT   = 450_000,        // 起動待ち [クロック] (BME280 の起動 2ms 以上)
    parameter [6:0]   ADDR   = 7'h76           // SDO = GND
)(
    input  wire       clk,
    input  wire       rst,
    output wire       scl_low,
    output wire       sda_low,
    input  wire       sda_in,
    output wire       txt_we,
    output wire [5:0] txt_addr,
    output wire [4:0] txt_data,
    output reg  [7:0] chip_id,                 // 最後に読んだ品番 (デバッグ表示用)
    output reg        err,                     // 最後の通信が NACK で失敗した
    output reg  [7:0] n_ok                     // 測定値を読めた回数 (下位 8bit)
);
    // ---- I2C マスタ ----
    reg        cmd_valid, mack;
    reg  [1:0] cmd;
    reg  [7:0] wdata;
    wire       i_ready, i_done, i_nack;
    wire [7:0] i_rdata;
    i2c_master #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ)) u_i2c (
        .clk(clk), .rst(rst), .cmd_valid(cmd_valid), .cmd(cmd), .wdata(wdata), .mack(mack),
        .ready(i_ready), .done(i_done), .rdata(i_rdata), .nack(i_nack),
        .scl_low(scl_low), .sda_low(sda_low), .sda_in(sda_in)
    );

    // ---- バイト RAM と計算器 ----
    reg        bw_en;
    reg  [7:0] bw_addr, bw_data;
    wire [7:0] br_addr, br_data;
    dpram #(.DW(8), .AW(8)) u_bram (
        .wclk(clk), .we(bw_en), .waddr(bw_addr), .wdata(bw_data),
        .rclk(clk), .raddr(br_addr), .rdata(br_data)
    );
    reg  calc_start, calc_err;
    wire calc_busy;
    env_calc u_calc (
        .clk(clk), .rst(rst), .start(calc_start), .err(calc_err), .busy(calc_busy),
        .mem_raddr(br_addr), .mem_rdata(br_data),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data)
    );

    // ---- 通信の手順 (トランザクション表) ----
    //   {読み=1, レジスタ, 書く値 または 読むバイト数}
    localparam integer T_LOOP = 6;             // 以後はこれを繰り返す
    function [16:0] tr(input [2:0] i);
        case (i)
            3'd0: tr = {1'b0, 8'hF2, 8'h01};
            3'd1: tr = {1'b0, 8'hF4, 8'h27};
            3'd2: tr = {1'b0, 8'hF5, 8'hA0};
            3'd3: tr = {1'b1, 8'hD0, 8'd1};
            3'd4: tr = {1'b1, 8'h88, 8'd26};
            3'd5: tr = {1'b1, 8'hE1, 8'd7};
            default: tr = {1'b1, 8'hF7, 8'd8};
        endcase
    endfunction

    localparam [3:0] S_WAIT = 4'd0, S_START = 4'd1, S_ADDRW = 4'd2, S_REG = 4'd3, S_VAL = 4'd4,
                     S_RSTART = 4'd5, S_ADDRR = 4'd6, S_READ = 4'd7, S_STOP = 4'd8, S_CALC = 4'd9,
                     S_CALCW = 4'd10;
    reg  [3:0]  st;
    reg  [2:0]  ti;                            // トランザクション番号
    reg  [7:0]  bi;                            // 読んだバイト数
    reg         issued;                        // 今の状態のコマンドを出した
    reg         fail;
    reg  [31:0] tmr;
    wire [16:0] t_cur = tr(ti);
    wire        t_rd  = t_cur[16];
    wire [7:0]  t_reg = t_cur[15:8];
    wire [7:0]  t_arg = t_cur[7:0];
    wire [31:0] boot_m = BOOT - 1;
    wire [31:0] per_m  = PERIOD - 1;

    // 1 コマンドを出して終わりを待つ。終わったら next へ (WRITE が NACK なら STOP へ)
    task automatic do_cmd(input [1:0] c, input [7:0] d, input m, input [3:0] next);
        begin
            if (!issued) begin
                if (i_ready) begin cmd_valid <= 1'b1; cmd <= c; wdata <= d; mack <= m; issued <= 1'b1; end
            end else if (i_done) begin
                issued <= 1'b0;
                if (c == 2'd2 && i_nack) begin fail <= 1'b1; st <= S_STOP; end
                else st <= next;
            end
        end
    endtask

    always @(posedge clk) begin
        cmd_valid  <= 1'b0;
        bw_en      <= 1'b0;
        calc_start <= 1'b0;
        if (rst) begin
            st <= S_WAIT; ti <= 3'd0; bi <= 8'd0; issued <= 1'b0; fail <= 1'b0; tmr <= boot_m;
            cmd <= 2'd0; wdata <= 8'd0; mack <= 1'b0; bw_addr <= 8'd0; bw_data <= 8'd0;
            calc_err <= 1'b1; chip_id <= 8'd0; err <= 1'b0; n_ok <= 8'd0;
        end else begin
            case (st)
                S_WAIT: begin
                    if (tmr == 32'd0) st <= S_START;
                    else              tmr <= tmr - 32'd1;
                end
                S_START:  do_cmd(2'd0, 8'd0, 1'b0, S_ADDRW);
                S_ADDRW:  do_cmd(2'd2, {ADDR, 1'b0}, 1'b0, S_REG);
                S_REG:    do_cmd(2'd2, t_reg, 1'b0, t_rd ? S_RSTART : S_VAL);
                S_VAL:    do_cmd(2'd2, t_arg, 1'b0, S_STOP);
                S_RSTART: do_cmd(2'd0, 8'd0, 1'b0, S_ADDRR);
                S_ADDRR: begin
                    bi <= 8'd0;
                    do_cmd(2'd2, {ADDR, 1'b1}, 1'b0, S_READ);
                end
                S_READ: begin
                    if (!issued) begin
                        if (i_ready) begin
                            cmd_valid <= 1'b1; cmd <= 2'd3; mack <= (bi != t_arg - 8'd1); issued <= 1'b1;
                        end
                    end else if (i_done) begin
                        issued  <= 1'b0;
                        bw_en   <= 1'b1; bw_addr <= t_reg + bi; bw_data <= i_rdata;
                        if (t_reg == 8'hD0) chip_id <= i_rdata;
                        bi <= bi + 8'd1;
                        if (bi == t_arg - 8'd1) st <= S_STOP;
                    end
                end
                S_STOP: begin
                    if (!issued) begin
                        if (i_ready) begin cmd_valid <= 1'b1; cmd <= 2'd1; issued <= 1'b1; end
                    end else if (i_done) begin
                        issued <= 1'b0;
                        if (fail) begin
                            err <= 1'b1; calc_err <= 1'b1; st <= S_CALC;
                        end else if (ti == T_LOOP[2:0]) begin
                            err <= 1'b0; calc_err <= 1'b0; n_ok <= n_ok + 8'd1; st <= S_CALC;
                        end else begin
                            ti <= ti + 3'd1; st <= S_START;
                        end
                    end
                end
                S_CALC: begin
                    if (!calc_busy) begin calc_start <= 1'b1; st <= S_CALCW; end
                end
                S_CALCW: begin
                    // calc_start の次のクロックから busy が立つ
                    if (!calc_start && !calc_busy) begin
                        if (fail) begin fail <= 1'b0; ti <= 3'd0; end
                        tmr <= per_m; st <= S_WAIT;
                    end
                end
                default: st <= S_WAIT;
            endcase
        end
    end

endmodule
