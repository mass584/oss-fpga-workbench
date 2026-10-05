// ============================================================================
// 表示側 (clk_pix ドメイン): ラインバッファからの画素出力とライン読み出し要求
//
//   ラインバッファ: 1024 x 32bit = {面(y[0]), ワード位置 0..319}、1 ワード = {偶数画素, 奇数画素}
//   (RGB565 x 2。CAM_YUV のときは {Y0, U, Y1, V} で、yuv2rgb で変換する)
//   ライン y の表示開始 (x=0) で次のライン y+1 の読み出しを要求し、
//   メモリ側はライン表示期間 (800 clk) 内に反対側の面を埋める。
//   先頭 2 ラインは垂直ブランク中に先読みする: y=523 でライン 0、y=524 でライン 1。
//   垂直ブランク開始 (y=480) で vblank イベントを送り、メモリ側が表示バッファを切り替える。
//
//   アンダーラン: 各ラインの表示開始時に、その面に入っている完了済みラインが
//   表示しようとしているラインと一致しなければ underrun を立てる (スティッキー)。
//   間に合わなくても前の内容がそのまま出るだけで、表示は破綻しない。
// ============================================================================
module fb_display #(
    parameter V_ACT = 480, parameter V_TOT = 525
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [9:0]  x,
    input  wire [9:0]  y,
    input  wire        de,
    input  wire        hs,
    input  wire        vs,
    input  wire        mem_ready,        // 非同期 (PSRAM 初期化完了)
    input  wire [3:0]  sat,              // CAM_YUV の彩度 (1/4 単位, yuv2rgb.v)。ほぼ静的なので同期化は呼び出し側

    // ラインバッファ読み出し
    output wire [9:0]  lb_raddr,
    input  wire [31:0] lb_rdata,

    // メモリ側へのイベント (トグル + 値保持)
    output reg         line_req_tog,
    output reg  [8:0]  line_req_num,
    output reg         vblank_tog,
    // メモリ側からの完了通知 (非同期)
    input  wire        line_done_tog,
    input  wire [8:0]  line_done_num,

    output wire [7:0]  r, g, b,
    output reg         de_o, hs_o, vs_o,
    output reg         underrun
);
    localparam [9:0] Y_PF0  = V_TOT - 2;   // ライン 0 を先読み
    localparam [9:0] Y_PF1  = V_TOT - 1;   // ライン 1 を先読み
    localparam [9:0] Y_VBL  = V_ACT;       // 垂直ブランク開始
    localparam [9:0] Y_LAST = V_ACT - 1;

    // ---- 画素出力 (BSRAM 読み出しレイテンシ 1clk に合わせて同期信号を遅延) ----
    assign lb_raddr = {y[0], x[9:1]};
    reg x0_d;
`ifdef CAM_YUV
    // YUV422 (1 ワード = {Y0, U, Y1, V}, 2 画素で U/V を共有) -> yuv2rgb (3clk) の分だけさらに遅延
    reg [2:0] de_p, hs_p, vs_p;
    always @(posedge clk) begin
        x0_d <= x[0];
        de_p <= {de_p[1:0], de}; hs_p <= {hs_p[1:0], hs}; vs_p <= {vs_p[1:0], vs};
        de_o <= de_p[2]; hs_o <= hs_p[2]; vs_o <= vs_p[2];
    end
    wire [7:0] cy = x0_d ? lb_rdata[15:8] : lb_rdata[31:24];
    wire [7:0] r_c, g_c, b_c;
    yuv2rgb u_yuv (.clk(clk), .y(cy), .u(lb_rdata[23:16]), .v(lb_rdata[7:0]), .sat(sat), .r(r_c), .g(g_c), .b(b_c));
    assign r = de_o ? r_c : 8'd0;
    assign g = de_o ? g_c : 8'd0;
    assign b = de_o ? b_c : 8'd0;
`else
    always @(posedge clk) begin
        de_o <= de; hs_o <= hs; vs_o <= vs; x0_d <= x[0];
    end
    wire [15:0] px = x0_d ? lb_rdata[15:0] : lb_rdata[31:16];

    // RGB565 -> RGB888 (上位ビットを下位に複製)
    assign r = de_o ? {px[15:11], px[15:13]} : 8'd0;
    assign g = de_o ? {px[10:5],  px[10:9]}  : 8'd0;
    assign b = de_o ? {px[4:0],   px[4:2]}   : 8'd0;
    wire unused_sat = &{1'b0, sat};
`endif

    // ---- 完了通知の受信 ----
    wire done_s, ready_s;
    cdc_sync #(.W(2)) u_sync (.clk(clk), .d({line_done_tog, mem_ready}), .q({done_s, ready_s}));
    reg       done_d;
    reg [8:0] filled [0:1];          // 各面に入っている完了済みライン
    reg       chk_en;

    always @(posedge clk) begin
        done_d <= done_s;
        if (rst) begin
            filled[0] <= 9'h1FF; filled[1] <= 9'h1FF;
        end else if (done_s ^ done_d) begin
            filled[line_done_num[0]] <= line_done_num;   // 値はトグル前から安定
        end
    end

    // ---- ライン要求 / vblank / アンダーラン判定 (各ラインの x=0) ----
    wire line_start = (x == 10'd0);
    always @(posedge clk) begin
        if (rst) begin
            line_req_tog <= 1'b0; line_req_num <= 9'd0; vblank_tog <= 1'b0;
            chk_en <= 1'b0; underrun <= 1'b0;
        end else if (line_start) begin
            if (y == Y_PF0) begin
                line_req_num <= 9'd0;  line_req_tog <= ~line_req_tog;
            end else if (y == Y_PF1) begin
                line_req_num <= 9'd1;  line_req_tog <= ~line_req_tog;
            end else if (y >= 10'd1 && y < Y_LAST) begin
                line_req_num <= y[8:0] + 1'b1;  line_req_tog <= ~line_req_tog;
            end

            if (y == Y_VBL) begin
                vblank_tog <= ~vblank_tog;
                chk_en     <= ready_s;          // 先読みが動き始めてから判定する
            end

            if (chk_en && y < Y_VBL && filled[y[0]] != y[8:0]) underrun <= 1'b1;
        end
    end
endmodule
