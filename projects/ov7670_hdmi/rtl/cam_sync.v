// ============================================================================
// カメラ信号のオーバーサンプリング (システムクロックドメインへ取り込む)
//   PCLK をクロックとして使わず、PCLK/VSYNC/HREF/D を IDDR で clk の両エッジでサンプルし
//   (実効 2 x clk)、さらに 2FF で同期する。サンプル列の中で PCLK が 0->1 になった位置を
//   見つけたサイクルで ce=1 を出し、立ち上がりのサンプルから dsel で選んだ位置の vsync/href/d を
//   出力する (dsel 0:そのサンプル 1:+1 2:+2 3:-1 サンプル, 1 サンプル = 11ns)。
//   実機 (ブレッドボード) では、立ち上がり直後 (0) だと多くのビットが同時に変わる画素で化けて
//   なだらかな面に等高線状の色の点が出、+2 (約 22ns 後) ではほぼ全面が化けた。データの切り替わりが
//   配線の遅れで立ち上がりの後ろにずれ込んでいると考えられるので、実行中に選べるようにしてある
//
//   立ち上がり = Low (1 サンプル以上) の直後に High が 2 サンプル以上続く位置。ただし前の立ち上がり
//   から HOLD サンプル以内のものは捨てる (ホールドオフ)。
//   実機 (ブレッドボード配線) では High の途中に 1 サンプルの落ち込みが周期の 3 割ほど乗り、余分な
//   立ち上がりと数えて 1 ラインのバイト数がずれていた (cam_probe / cam_runlen で確認)。
//   本物の Low も約 20ns と短く 1 サンプルしか取れないことがあるので、形 (Low を 2 サンプル要求)
//   では区別できない。落ち込みは立ち上がりの直後 (High の途中) に来るので、時間で区別する。
//   Low の途中の 1 サンプルのひげは High 2 サンプルの条件で捨てる。
//
//   条件: PCLK の High が clk 1 周期 (45MHz なら 22ns, 2 サンプル) 以上、Low が半周期 (11ns) 以上。
//         PCLK の周期が HOLD サンプル (既定 5 x 11.1ns = 56ns) より長い (PCLK < 18MHz)。HOLD <= 13。
//         VGA 15fps の PCLK 12.6MHz は 1 周期 79ns (実機, PLL バイパス: High 約 55ns / Low 22〜33ns)。
//         clk 1 周期に PCLK の立ち上がりが 2 回来ないこと (PCLK < clk)。
//
//   理由: OSS フローでは pin 35 (GCLKT_4) からグローバル網へ入れられず、一般配線のクロックは
//         hold 違反、DQCE 経由は実機で動かなかった。また単純な 1 エッジのサンプルでは、
//         カメラ内蔵 PLL を使ったときの短い High 期間 (<22ns) を取りこぼした。
// ============================================================================
module cam_sync #(
    parameter [3:0] HOLD = 4'd5   // ホールドオフ [サンプル]。PCLK の周期 (サンプル数) より短くする。0 で無効
)(
    input  wire       clk,
    input  wire [1:0] dsel,       // データを取るサンプル位置 (上記)
    input  wire       pclk,       // 非同期 (ピン)
    input  wire       vsync,      // 非同期 (ピン)
    input  wire       href,       // 非同期 (ピン)
    input  wire [7:0] d,          // 非同期 (ピン)
    output reg        ce,         // PCLK 立ち上がり 1 回につき 1 サイクル
    output reg        vsync_o,
    output reg        href_o,
    output reg  [7:0] d_o,
    output wire       pclk_s,     // サンプルした PCLK (デバッグ用。ピンを直接ファブリックへ引かないため)
    output wire [1:0] pclk_pair   // 同 半サイクルごとの 2 サンプル {先, 後} (デバッグ用)
);
    // IDDR: q0 = 立ち上がりでのサンプル (先), q1 = 立ち下がりでのサンプル (後)
    wire [10:0] pin = {pclk, vsync, href, d};
    wire [10:0] q0, q1;
    genvar k;
    generate
        for (k = 0; k < 11; k = k + 1) begin : g_in
            IDDR u_iddr (.Q0(q0[k]), .Q1(q1[k]), .D(pin[k]), .CLK(clk));
        end
    endgenerate

    // 2FF 同期 (IDDR の出力はすでに clk 同期だが、メタステーブル対策でもう 1 段)
    // さらに 1 サイクル分を残し、サンプル列 ... pp1, c0, c1, b0, b1 (古い順) で判定する
    reg [10:0] a0, a1, b0, b1, c0, c1;
    reg        pp1;         // 前サイクルの c1
    reg [9:0]  pd1;         // 同 データ (dsel=3 で c0 の 1 サンプル前として使う)
    reg [3:0]  sc;          // 前の立ち上がりのサンプルから pp1 までのサンプル数 (13 で飽和。sc+2 があふれない)
    initial begin
        a0 = 0; a1 = 0; b0 = 0; b1 = 0; c0 = 0; c1 = 0; pp1 = 1'b0; pd1 = 0; sc = 4'd13;
        ce = 1'b0; vsync_o = 1'b0; href_o = 1'b0; d_o = 0;
    end

    assign pclk_s    = b0[10];
    assign pclk_pair = {b0[10], b1[10]};

    // サンプル列 ... pp1, c0, c1, b0 (古い順)。c0 は前の立ち上がりから sc+1、c1 は sc+2 サンプル目
    wire hold_ok0, hold_ok1;                       // ホールドオフが明けている (c0 / c1)
    generate
        if (HOLD == 4'd0) begin : g_nohold
            assign hold_ok0 = 1'b1;
            assign hold_ok1 = 1'b1;
        end else begin : g_hold
            assign hold_ok0 = (sc + 4'd1 >= HOLD);
            assign hold_ok1 = (sc + 4'd2 >= HOLD);
        end
    endgenerate
    wire rise0 = !pp1 && c0[10] && c1[10] && hold_ok0;              // c0 で立ち上がり
    wire rise1 = !rise0 && !c0[10] && c1[10] && b0[10] && hold_ok1; // c1 で立ち上がり

    always @(posedge clk) begin
        a0 <= q0;  a1 <= q1;
        b0 <= a0;  b1 <= a1;
        c0 <= b0;  c1 <= b1;
        pp1 <= c1[10];
        pd1 <= c1[9:0];
        sc  <= rise0 ? 4'd1 : rise1 ? 4'd0 : (sc >= 4'd11) ? 4'd13 : sc + 4'd2;
        ce  <= 1'b0;
        if (rise0) begin
            ce <= 1'b1;
            case (dsel)
                2'd0: {vsync_o, href_o, d_o} <= c0[9:0];
                2'd1: {vsync_o, href_o, d_o} <= c1[9:0];
                2'd2: {vsync_o, href_o, d_o} <= b0[9:0];
                default: {vsync_o, href_o, d_o} <= pd1;
            endcase
        end else if (rise1) begin
            ce <= 1'b1;
            case (dsel)
                2'd0: {vsync_o, href_o, d_o} <= c1[9:0];
                2'd1: {vsync_o, href_o, d_o} <= b0[9:0];
                2'd2: {vsync_o, href_o, d_o} <= b1[9:0];
                default: {vsync_o, href_o, d_o} <= c0[9:0];
            endcase
        end
    end
endmodule
