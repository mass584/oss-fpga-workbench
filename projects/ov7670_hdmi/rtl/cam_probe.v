// ============================================================================
// PCLK 取り込みの異常検出 (横筋の原因切り分け用。clk_mem ドメイン, cam_sync の ce で動く)
//   仮説: PCLK 立ち上がりの誤検出 (余分) / 取りこぼしで 1 バイトずれ、RGB565 の上位/下位バイトの
//         組がその行の終わりまでずれる (横筋が行の途中から右端まで続く)
//   1. ライン内 (HREF=1 が続く間) の ce 間隔 [クロック] を数える。PCLK 12.6MHz / clk 45MHz なら 3 か 4。
//        2 以下 = 余分な立ち上がり (グリッチ)、5 以上 = 立ち上がりの取りこぼし
//   2. 1 ラインのバイト数 (HREF=1 の ce 数, BPL 期待) が合わないラインを数え、最小/最大を取る
//   3. HREF の短い Low (ライン内で HREF が一瞬落ちる) を数える
//   4. 窓内で最初の異常について {種類, ライン内のバイト位置, ライン番号, PCLK サンプル列} を保持する。
//      サンプル列は 16 クロック x {先,後} の 32bit で MSB が古い。末尾の約 3 クロックは検出した
//      立ち上がりより後 (cam_sync の段数分)
//   5. mark: 異常が起きたラインでは、その位置から行末まで種類 (0 以外) を出す。top で画素を
//      塗りつぶし、画面の横筋の始点と異常の位置が一致するかを目で確かめる
//   6. データ線の 1 の割合: 上位バイト (ライン内の偶数バイト = [R5 G3]) を 256 個に 1 個ずつ
//      最大 4095 個サンプルし、ビットごとに 1 だった回数を数える。暗い画面でも D7 (R の MSB) が
//      ほぼ 4095 なら D7 の High 張り付き (断線で浮いている / 隣とショート) を疑う
//   ライン終了 = HREF=0 が LINE_GAP 回 (ce) 続いたとき、または VSYNC (短い Low はライン内のグリッチ)
//   窓の切り替えの 1 クロックに起きたイベントは数えない
// ============================================================================
module cam_probe #(
    parameter integer WINDOW   = 45_000_000,
    parameter integer LINE_GAP = 64,
    parameter [11:0]  BPL      = 12'd1280
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    input  wire        vsync,
    input  wire        href,
    input  wire [7:0]  d,
    input  wire [1:0]  pclk_pair,      // {先, 後}
    output reg  [1:0]  mark,           // 0:なし 1:余分な立ち上がり 2:取りこぼし 3:HREF グリッチ
    // 窓ごとの集計
    output reg  [15:0] n_short,        // ce 間隔 <= 2
    output reg  [23:0] n_i3,           // ce 間隔 = 3
    output reg  [23:0] n_i4,           // ce 間隔 = 4
    output reg  [15:0] n_long,         // ce 間隔 >= 5
    output reg  [15:0] n_ok,           // バイト数 = BPL のライン数
    output reg  [15:0] n_bad,          // バイト数 != BPL のライン数
    output reg  [11:0] bpl_min,
    output reg  [11:0] bpl_max,
    output reg  [15:0] n_hg,           // HREF グリッチ数
    output reg  [3:0]  an_type,        // 窓内で最初の異常 (0 = なし)
    output reg  [11:0] an_pos,         // そのライン内のバイト位置
    output reg  [11:0] an_line,        // ライン番号 (VSYNC 後 0 から)
    output reg  [31:0] an_hist,        // PCLK サンプル列
    output reg  [95:0] d_ones,         // ビットごとの 1 の回数 {D7, ..., D0} 各 12bit
    output reg  [11:0] d_n             // サンプル数 (最大 4095)
);
    localparam [31:0] WIN_M = WINDOW - 1;
    localparam integer GAP_I = LINE_GAP;
    localparam [7:0]  GAP   = GAP_I[7:0];

    function [15:0] inc16(input [15:0] v);
        inc16 = (v == 16'hFFFF) ? v : v + 16'd1;
    endfunction
    function [23:0] inc24(input [23:0] v);
        inc24 = (v == 24'hFFFFFF) ? v : v + 24'd1;
    endfunction

    // ce で動く状態 (リセットなし。FPGA の初期値で起動)
    reg [3:0]  gap;          // 前の ce からのクロック数 (15 で飽和)
    reg        hr_prev;      // 前の ce での HREF
    reg [7:0]  lowrun;       // HREF=0 が続いた ce 数 (255 で飽和)
    reg [11:0] bcnt, lcnt;
    reg [31:0] hist;         // PCLK サンプル列 (新しいものが下位)
    initial begin
        mark = 2'd0; gap = 4'd0; hr_prev = 1'b0; lowrun = 8'hFF; bcnt = 0; lcnt = 0; hist = 0;
    end

    wire       in_line  = ce && href && hr_prev && !vsync;
    wire       ev_short = in_line && (gap <= 4'd2);
    wire       ev_i3    = in_line && (gap == 4'd3);
    wire       ev_i4    = in_line && (gap == 4'd4);
    wire       ev_long  = in_line && (gap >= 4'd5);
    wire       ev_hg    = ce && href && !hr_prev && !vsync && (lowrun < GAP) && (bcnt != 12'd0);
    wire       ev_lend  = ce && !href && (vsync || lowrun == GAP - 8'd1) && (bcnt != 12'd0);
    wire       anom     = ev_short | ev_long | ev_hg;
    wire [1:0] atype    = ev_short ? 2'd1 : ev_long ? 2'd2 : 2'd3;

    always @(posedge clk) begin
        hist <= {hist[29:0], pclk_pair};
        gap  <= ce ? 4'd1 : (gap == 4'hF) ? gap : gap + 4'd1;
        if (ce) begin
            hr_prev <= href;
            if (vsync) begin
                lowrun <= 8'hFF; bcnt <= 12'd0; lcnt <= 12'd0; mark <= 2'd0;
            end else if (href) begin
                lowrun <= 8'd0;
                if (bcnt != 12'hFFF) bcnt <= bcnt + 12'd1;
                if (anom && mark == 2'd0) mark <= atype;
            end else begin
                if (lowrun != 8'hFF) lowrun <= lowrun + 8'd1;
                if (ev_lend) begin bcnt <= 12'd0; lcnt <= lcnt + 12'd1; mark <= 2'd0; end
            end
        end
    end

    // 窓ごとの集計
    reg [31:0] tmr;
    reg [15:0] c_short, c_long, c_ok, c_bad, c_hg;
    reg [23:0] c_i3, c_i4;
    reg [11:0] c_min, c_max;
    reg        c_an;
    reg [1:0]  c_type;
    reg [11:0] c_pos, c_line;
    reg [31:0] c_hist;
    reg [7:0]  c_div;
    reg [11:0] c_dn;
    reg [95:0] c_d1;
    wire       ev_dsamp = ce && href && !vsync && !bcnt[0] && (c_div == 8'd0) && (c_dn != 12'hFFF);
    reg [95:0] d1_next;
    integer    k;
    always @* begin
        for (k = 0; k < 8; k = k + 1)
            d1_next[12*k +: 12] = c_d1[12*k +: 12] + {11'd0, d[k]};
    end

    always @(posedge clk) begin
        if (rst) begin
            tmr <= 32'd0;
            c_short <= 0; c_long <= 0; c_ok <= 0; c_bad <= 0; c_hg <= 0; c_i3 <= 0; c_i4 <= 0;
            c_min <= 12'hFFF; c_max <= 12'd0;
            c_an <= 1'b0; c_type <= 2'd0; c_pos <= 0; c_line <= 0; c_hist <= 0;
            n_short <= 0; n_i3 <= 0; n_i4 <= 0; n_long <= 0; n_ok <= 0; n_bad <= 0;
            bpl_min <= 12'd0; bpl_max <= 12'd0; n_hg <= 0;
            an_type <= 4'd0; an_pos <= 0; an_line <= 0; an_hist <= 0;
            c_div <= 8'd0; c_dn <= 12'd0; c_d1 <= 96'd0; d_ones <= 96'd0; d_n <= 12'd0;
        end else if (tmr == WIN_M) begin
            tmr <= 32'd0;
            n_short <= c_short; n_i3 <= c_i3; n_i4 <= c_i4; n_long <= c_long;
            n_ok <= c_ok; n_bad <= c_bad; n_hg <= c_hg;
            bpl_min <= (c_ok == 16'd0 && c_bad == 16'd0) ? 12'd0 : c_min;
            bpl_max <= c_max;
            an_type <= {2'b00, c_type}; an_pos <= c_pos; an_line <= c_line; an_hist <= c_hist;
            d_ones <= c_d1; d_n <= c_dn;
            c_div <= 8'd0; c_dn <= 12'd0; c_d1 <= 96'd0;
            c_short <= 0; c_long <= 0; c_ok <= 0; c_bad <= 0; c_hg <= 0; c_i3 <= 0; c_i4 <= 0;
            c_min <= 12'hFFF; c_max <= 12'd0;
            c_an <= 1'b0; c_type <= 2'd0; c_pos <= 0; c_line <= 0; c_hist <= 0;
        end else begin
            tmr <= tmr + 32'd1;
            if (ev_short) c_short <= inc16(c_short);
            if (ev_i3)    c_i3    <= inc24(c_i3);
            if (ev_i4)    c_i4    <= inc24(c_i4);
            if (ev_long)  c_long  <= inc16(c_long);
            if (ev_hg)    c_hg    <= inc16(c_hg);
            if (ev_lend) begin
                if (bcnt == BPL) c_ok  <= inc16(c_ok);
                else             c_bad <= inc16(c_bad);
                if (bcnt < c_min) c_min <= bcnt;
                if (bcnt > c_max) c_max <= bcnt;
            end
            if (ce && href && !vsync && !bcnt[0]) c_div <= c_div + 8'd1;
            if (ev_dsamp) begin c_dn <= c_dn + 12'd1; c_d1 <= d1_next; end
            if (anom && !c_an) begin
                c_an <= 1'b1; c_type <= atype; c_pos <= bcnt; c_line <= lcnt; c_hist <= hist;
            end
        end
    end
endmodule
