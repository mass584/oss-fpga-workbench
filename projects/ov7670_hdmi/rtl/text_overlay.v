// ============================================================================
// 文字の重ね描き (clk_pix ドメイン): 画面右上に 3 行 x 9 文字
//   文字 RAM (書き込みは別クロック, txt_addr = 行 * 16 + 桁) の文字コードを 5x7 フォント (env_font.v)
//   で描く。1 文字 6x8 ドット (右と下の 1 ドットは間隔) を SCALE 倍に拡大する。
//   枠の中は映像を 1/4 の明るさにし、文字は白で描く。
//
//   タイミング: x/y/de は表示タイミング (video_timing) のまま、映像 (r/g/b/de/hs/vs_in) は
//   そこから VLAT クロック遅れて来る。文字の判定は x/y から 3 クロックかかるので、
//   出力は max(VLAT, 3) クロック遅れ (映像と同期信号は max - VLAT だけさらに遅らせる)
// ============================================================================
module text_overlay #(
    parameter integer VLAT   = 1,
    parameter integer SCALE  = 3,
    parameter integer X0     = 464,        // 文字領域の左上
    parameter integer Y0     = 14,
    parameter integer PAD    = 6,          // 暗くする枠の余白
    parameter integer ENABLE = 1
)(
    input  wire       clk,
    input  wire [9:0] x,
    input  wire [9:0] y,
    input  wire       de,
    input  wire [7:0] r_in, g_in, b_in,
    input  wire       de_in, hs_in, vs_in,
    output wire [7:0] r, g, b,
    output wire       de_o, hs_o, vs_o,
    // 文字 RAM の書き込み (txt_clk ドメイン)
    input  wire       txt_clk,
    input  wire       txt_we,
    input  wire [5:0] txt_addr,
    input  wire [4:0] txt_data
);
    localparam integer COLS = 9, ROWS = 3;
    localparam integer CW = 6 * SCALE, CH = 8 * SCALE;
    localparam integer X1 = X0 + COLS * CW, Y1 = Y0 + ROWS * CH;
    localparam integer LAT = (VLAT > 3) ? VLAT : 3;
    localparam integer BX0_I = X0 - PAD, BX1_I = X1 + PAD, BY0_I = Y0 - PAD, BY1_I = Y1 + PAD;
    localparam integer SC_M_I = SCALE - 1;
    localparam [9:0] BX0 = BX0_I[9:0], BX1 = BX1_I[9:0], BY0 = BY0_I[9:0], BY1 = BY1_I[9:0];
    localparam [9:0] TX0 = X0[9:0], TX1 = X1[9:0], TY0 = Y0[9:0], TY1 = Y1[9:0];
    localparam [3:0] SC_M = SC_M_I[3:0];

    // ---- 段 1: 文字領域の中の位置 (x を 1 画素ずつ数える) ----
    reg [3:0] cx, sx, rx;            // 桁, 文字内の列 0..5, 拡大の繰り返し
    reg [1:0] cy;
    reg [2:0] sy;
    reg [3:0] ry;
    reg       in_box1, in_txt1;
    always @(posedge clk) begin
        in_box1 <= de && x >= BX0 && x < BX1 && y >= BY0 && y < BY1;
        in_txt1 <= de && x >= TX0 && x < TX1 && y >= TY0 && y < TY1;
        if (x == TX0) begin
            cx <= 4'd0; sx <= 4'd0; rx <= 4'd0;
        end else if (rx == SC_M) begin
            rx <= 4'd0;
            if (sx == 4'd5) begin sx <= 4'd0; cx <= cx + 4'd1; end
            else sx <= sx + 4'd1;
        end else begin
            rx <= rx + 4'd1;
        end
        // 行は各ラインの先頭 (x=0) で進める
        if (x == 10'd0) begin
            if (y == TY0) begin
                cy <= 2'd0; sy <= 3'd0; ry <= 4'd0;
            end else if (ry == SC_M) begin
                ry <= 4'd0;
                if (sy == 3'd7) begin sy <= 3'd0; cy <= cy + 2'd1; end
                else sy <= sy + 3'd1;
            end else begin
                ry <= ry + 4'd1;
            end
        end
    end

    // ---- 段 2: 文字コードを読む (RAM 1 クロック) ----
    wire [4:0] code;
    dpram #(.DW(5), .AW(6)) u_txt (
        .wclk(txt_clk), .we(txt_we), .waddr(txt_addr), .wdata(txt_data),
        .rclk(clk), .raddr({cy, cx}), .rdata(code)
    );
    reg [3:0] sx2;
    reg [2:0] sy2;
    reg       in_box2, in_txt2;
    always @(posedge clk) begin
        sx2 <= sx; sy2 <= sy; in_box2 <= in_box1; in_txt2 <= in_txt1;
    end

    // ---- 段 3: フォントの 1 ドット ----
    wire [4:0] bits;
    env_font u_font (.code(code), .row(sy2), .bits(bits));
    reg on3, box3;
    always @(posedge clk) begin
        on3  <= in_txt2 && sx2 < 4'd5 && bits[3'd4 - sx2[2:0]];
        box3 <= in_box2;
    end

    // ---- 映像と合わせる ----
    //   段 3 の出力 (on3/box3) は x から 3 クロック後、映像は VLAT 後に来るので、どちらも LAT にそろえる
    wire [26:0] v_al;                              // {de, hs, vs, r, g, b}
    wire [1:0]  ob;
    ov_delay #(.W(27), .N(LAT - VLAT)) u_dv (.clk(clk), .d({de_in, hs_in, vs_in, r_in, g_in, b_in}), .q(v_al));
    ov_delay #(.W(2),  .N(LAT - 3))    u_do (.clk(clk), .d({on3, box3}), .q(ob));
    wire        on  = ob[1];
    wire        box = ob[0];
    wire [7:0]  vr = v_al[23:16], vg = v_al[15:8], vb = v_al[7:0];
    wire        use_ov = (ENABLE != 0) && v_al[26];

    assign de_o = v_al[26];
    assign hs_o = v_al[25];
    assign vs_o = v_al[24];
    assign r = (use_ov && on) ? 8'hFF : (use_ov && box) ? {2'b00, vr[7:2]} : vr;
    assign g = (use_ov && on) ? 8'hFF : (use_ov && box) ? {2'b00, vg[7:2]} : vg;
    assign b = (use_ov && on) ? 8'hFF : (use_ov && box) ? {2'b00, vb[7:2]} : vb;
endmodule

