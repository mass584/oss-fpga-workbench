// ============================================================================
// UART の状態表示 (clk ドメイン = clk_mem, 1 秒ごとに 1 行, 115200 8N1)
//   通常:
//     U=起動後秒数 RC=リセット回数 S={調整失敗あり, PSRAM 初期化完了} G=書き込み gap
//     FW=PSRAM に書けたフレーム数 E={アンダーラン, 読み出しエラー, SOF 異常, FIFO あふれ}
//     SA=CAM_YUV の彩度の段階 (0..4 = x1.0..x2.0) BM={BME280 の品番 (60/58), 通信エラー, 読めた回数}
//   -DCAM_DEBUG のときは、続けてカメラ取り込みの統計を出す (基板の信号品質の評価用):
//     RL: PCLK の High/Low の長さの分布 {H1,H2,H3+,L1,L2,L3+} (4096 クロック窓, cam_runlen)
//     PR/VS/HR: PCLK・VSYNC・HREF の立ち上がり [回/秒] (cam_monitor)
//     以下 cam_probe (1 秒窓)。ライン内の PCLK 立ち上がり (ce) 間隔は 12.6MHz なら 3 か 4 クロック
//     CI: ce 間隔 {<=2 (余分な立ち上がり), =3, =4, >=5 (取りこぼし)}
//     LB: 1 ラインのバイト数 {=1280 のライン数, !=1280 のライン数, 最小, 最大}  HG: HREF の瞬断数
//     AN: 窓内で最初の異常 {種類 1:余分 2:取りこぼし 3:HREF瞬断, バイト位置, ライン番号,
//         PCLK サンプル列 16 クロック x {先,後} (MSB が古い)}
//     DH: 上位バイトの D7..D0 が 1 だった回数 / N: サンプル数
//   (統計のカウンタ群は LUT/ALU を多く使い、BME280 表示と合わせると FPGA に収まらないので既定では入れない)
// ============================================================================
module dbg_uart #(
    parameter integer CLK_HZ = 45_000_000
)(
    input  wire       clk,
    input  wire       rst,
    output wire       tx,
    // 状態
    input  wire       mem_init_done,
    input  wire       mem_init_fail,
    input  wire [3:0] mem_wr_gap,
    input  wire       frame_wr_tog,
    input  wire       underrun,          // 非同期 (clk_pix)
    input  wire       rd_err_seen,
    input  wire       frame_broken,
    input  wire       fifo_ovf,
    input  wire [2:0] sat_sel,
    input  wire [7:0] env_chip,
    input  wire       env_err,
    input  wire [7:0] env_n_ok,
    // カメラ取り込みの統計用 (cam_frontend)
    input  wire       cam_ce,
    input  wire       cam_vsync,
    input  wire       cam_href,
    input  wire [7:0] cam_d,
    input  wire       cam_pclk_s,
    input  wire [1:0] cam_pclk_pair
);
    // 起動後の秒数と、リセットの回数 (リセットが繰り返されていないかの確認)。リセットに関係なく数える
    localparam integer UP_LAST_I = CLK_HZ - 1;
    localparam [25:0]  UP_LAST   = UP_LAST_I[25:0];
    reg [25:0] up_div;
    reg [15:0] uptime;
    reg [7:0]  rst_cnt;
    reg        rst_d;
    initial begin up_div = 0; uptime = 0; rst_cnt = 0; rst_d = 1'b0; end
    always @(posedge clk) begin
        rst_d  <= rst;
        up_div <= (up_div == UP_LAST) ? 26'd0 : up_div + 1'b1;
        if (up_div == UP_LAST) uptime <= uptime + 1'b1;
        if (rst && !rst_d && rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1'b1;
    end
    reg  [7:0] frames_wr;
    reg        fwt_d;
    always @(posedge clk) begin
        fwt_d <= frame_wr_tog;
        if (rst)                         frames_wr <= 8'd0;
        else if (frame_wr_tog != fwt_d)  frames_wr <= frames_wr + 1'b1;
    end
    wire ur_s;
    cdc_sync #(.W(1)) u_sync (.clk(clk), .d(underrun), .q(ur_s));

    wire [67:0] base = {uptime, rst_cnt, 2'b00, mem_init_fail, mem_init_done, mem_wr_gap, frames_wr,
                        ur_s, rd_err_seen, frame_broken, fifo_ovf, 1'b0, sat_sel, env_chip, 3'b000, env_err, env_n_ok};

`ifdef CAM_DEBUG
    wire [71:0] rl;
    cam_runlen #(.WINDOW(4096)) u_rl (.clk(clk), .rst(rst), .pair(cam_pclk_pair), .hist(rl));
    wire [23:0] mon_pr;
    wire [7:0]  mon_vs;
    wire [15:0] mon_hr;
    cam_monitor #(.WINDOW(CLK_HZ)) u_mon (
        .clk(clk), .rst(rst), .pclk_s(cam_pclk_s), .vsync(cam_vsync), .href(cam_href),
        .pr(mon_pr), .vs_cnt(mon_vs), .hr_cnt(mon_hr)
    );
    wire [1:0]  pr_mark;
    wire [15:0] pr_short, pr_long, pr_ok, pr_bad, pr_hg;
    wire [23:0] pr_i3, pr_i4;
    wire [11:0] pr_bmin, pr_bmax, pr_apos, pr_aline;
    wire [3:0]  pr_atype;
    wire [31:0] pr_ahist;
    wire [95:0] pr_d1;
    wire [11:0] pr_dn;
    cam_probe #(.WINDOW(CLK_HZ)) u_probe (
        .clk(clk), .rst(rst), .ce(cam_ce), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .pclk_pair(cam_pclk_pair), .mark(pr_mark),
        .n_short(pr_short), .n_i3(pr_i3), .n_i4(pr_i4), .n_long(pr_long),
        .n_ok(pr_ok), .n_bad(pr_bad), .bpl_min(pr_bmin), .bpl_max(pr_bmax), .n_hg(pr_hg),
        .an_type(pr_atype), .an_pos(pr_apos), .an_line(pr_aline), .an_hist(pr_ahist),
        .d_ones(pr_d1), .d_n(pr_dn)
    );
    localparam TPL = {"U=#### RC=## S=# G=# FW=## E=# SA=# | BM=##:#:##",
                      " | RL=################## PR=###### VS=## HR=####",
                      " | CI=####:######:######:#### LB=####:####:###:### HG=#### AN=#:###:###:########",
                      " DH=###:###:###:###:###:###:###:### N=###"};
    localparam integer LEN = 48 + 48 + 80 + 41;          // 各行の文字数
    localparam integer NN  = 17 + 30 + 53 + 27;          // 各行の '#' の数 (= nib の 4bit 単位の幅)
    wire [4*NN-1:0] nib = {base, rl, mon_pr, mon_vs, mon_hr,
                           pr_short, pr_i3, pr_i4, pr_long, pr_ok, pr_bad, pr_bmin, pr_bmax, pr_hg,
                           pr_atype, pr_apos, pr_aline, pr_ahist, pr_d1, pr_dn};
    wire unused_ok = &{1'b0, pr_mark};
`else
    localparam TPL = "U=#### RC=## S=# G=# FW=## E=# SA=# | BM=##:#:##";
    localparam integer LEN = 48;
    localparam integer NN  = 17;
    wire [4*NN-1:0] nib = base;
    wire unused_ok = &{1'b0, cam_ce, cam_vsync, cam_href, cam_d, cam_pclk_s, cam_pclk_pair};
`endif

    dbg_report #(.CLK_HZ(CLK_HZ), .PERIOD(CLK_HZ), .LEN(LEN), .NN(NN), .TPL(TPL)) u_rep (
        .clk(clk), .rst(rst), .nib(nib), .tx(tx)
    );
endmodule
