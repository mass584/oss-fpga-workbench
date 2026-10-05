// ============================================================================
// Tang Nano 9K + OV7670(FIFOなし) -> HDMI(DVI) 640x480@60Hz
//
//   Phase 2 (既定): 内蔵 PSRAM をトリプルバッファにして 640x480 RGB565 をフル解像度表示
//     cam_pclk         clk_mem (45MHz)                         clk_pix (25.2MHz)
//     cam_capture ─► cam_pack ─► async FIFO ─► psram_fb ◄─► psram_ctrl
//                                                │
//                                                └─► line buffer (ping-pong) ─► fb_display ─► dvi_tx
//
//   Phase 1 (`define FB_PHASE1): 1/4 間引き 160x120 を内蔵 BSRAM に保存して 4 倍拡大表示
//     make PROJECT=ov7670_hdmi EXTRA_DEFINES=-DFB_PHASE1 ...
// ============================================================================
/* verilator lint_off PINCONNECTEMPTY */   // ベンダプリミティブの未使用出力
module top #(
    parameter ENV_OVERLAY = 1        // BME280 の表示を重ねる (システム試験では 0)
)(
    input  wire        clk27,        // 27MHz 水晶
    input  wire        btn_rst_n,    // ボタン S1 (押すとリセット)
    input  wire        btn_mark_n,   // ボタン S2 (Phase 2: 押すごとに CAM_YUV の彩度を切り替え)

    // OV7670
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        cam_href,
    input  wire [7:0]  cam_d,
    output wire        cam_xclk,
    output wire        cam_reset_n,
    output wire        cam_pwdn,
    output wire        cam_sioc,
    inout  wire        cam_siod,

    // HDMI
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire [2:0]  tmds_d_p,
    output wire [2:0]  tmds_d_n,
`ifndef FB_PHASE1
    // 内蔵 PSRAM (ポート名で内部ピンに自動配置される)
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds,
`endif
    // BME280 (I2C, オープンドレイン。Phase 2 のみ)
    inout  wire        env_sda,
    inout  wire        env_scl,
    output wire        uart_tx,      // デバッグ出力 (BL702 経由で USB シリアル, 115200 8N1)
    output wire [5:0]  led           // 負論理
);
    // ------------------------------------------------------------------
    // クロック生成: 27MHz -> 126MHz(TMDS 5倍) -> /5 -> 25.2MHz(画素)
    // ------------------------------------------------------------------
    wire clk_ser, clk_pix, pll_lock;

    // IP Generator で作った rPLL に置き換えても可 (入力27MHz, 出力126MHz)
    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),    // /3
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(13), // x14 -> 126MHz
        .DYN_ODIV_SEL("false"), .ODIV_SEL(4),    // VCO = 504MHz
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) u_pll (
        .CLKOUT(clk_ser), .LOCK(pll_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_clkdiv (
        .HCLKIN(clk_ser), .RESETN(pll_lock), .CALIB(1'b0), .CLKOUT(clk_pix)
    );

    // リセット同期化 (clk_pix ドメイン)
    reg [3:0] rst_sr;
    initial rst_sr = 4'hF;
    always @(posedge clk_pix or negedge pll_lock)
        if (!pll_lock) rst_sr <= 4'hF;
        else           rst_sr <= {rst_sr[2:0], ~btn_rst_n};
    wire rst = rst_sr[3];


    // ------------------------------------------------------------------
    // カメラへの XCLK 供給 (ODDR でクロックを外部ピンへ転送)
    // ------------------------------------------------------------------
    ODDR u_xclk (
        .Q0(cam_xclk), .Q1(), .D0(1'b1), .D1(1'b0), .TX(1'b0), .CLK(clk_pix)
    );
    assign cam_pwdn = 1'b0;   // 常に動作。ピン (41) は PCLK の隣を通す GND ガード線を兼ねる (cst 参照)

    // ------------------------------------------------------------------
    // SCCB でレジスタ初期化
    // ------------------------------------------------------------------
    wire siod_drive_low, cfg_done;
    ov7670_sccb_init #(.CLK_HZ(25_200_000), .SCCB_HZ(100_000)) u_cfg (
        .clk(clk_pix), .rst(rst),
        .cam_reset_n(cam_reset_n),
        .sioc(cam_sioc), .siod_drive_low(siod_drive_low),
        .done(cfg_done)
    );
    assign cam_siod = siod_drive_low ? 1'b0 : 1'bz;   // オープンドレイン

    // ------------------------------------------------------------------
    // 表示タイミング (clk_pix ドメイン)
    // ------------------------------------------------------------------
    wire [9:0] vx, vy;
    wire       vde, vhs, vvs;
    video_timing u_vt (
        .clk(clk_pix), .rst(rst), .x(vx), .y(vy), .de(vde), .hs(vhs), .vs(vvs)
    );

    wire [7:0] r8, g8, b8;
    wire       de_d, hs_d, vs_d;
    wire       frame_toggle;

`ifdef FB_PHASE1
    // ==================================================================
    // Phase 1: 160x120 BSRAM フレームバッファ
    // ==================================================================
    wire        fb_we, fb_sof;
    wire [14:0] fb_waddr;
    wire [15:0] fb_wdata;
    wire        pclk = cam_pclk;

    cam_capture #(.DECIMATE(1), .AW(15)) u_cap (
        .pclk(pclk), .ce(1'b1), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata), .sof(fb_sof),
        .frame_toggle(frame_toggle)
    );

    // 4x 拡大: 表示座標 /4 = バッファ座標
    wire [7:0]  fx = vx[9:2];                                     // 0..159
    wire [6:0]  fy = vy[8:2];                                     // 0..119
    wire [14:0] fb_raddr = {fy, 7'b0} + {2'b0, fy, 5'b0} + {7'b0, fx};  // fy*160 + fx
    wire [15:0] fb_rdata;

    framebuf u_fb (
        .wclk(pclk), .we(fb_we), .waddr(fb_waddr), .wdata(fb_wdata),
        .rclk(clk_pix), .raddr(fb_raddr), .rdata(fb_rdata)
    );

    // BSRAM の読み出しレイテンシ(1clk)に合わせて同期信号を遅延
    reg de_r, hs_r, vs_r;
    always @(posedge clk_pix) begin
        de_r <= vde; hs_r <= vhs; vs_r <= vvs;
    end
    assign de_d = de_r; assign hs_d = hs_r; assign vs_d = vs_r;

    // RGB565 -> RGB888 (上位ビットを下位に複製)
    assign r8 = de_d ? {fb_rdata[15:11], fb_rdata[15:13]} : 8'd0;
    assign g8 = de_d ? {fb_rdata[10:5],  fb_rdata[10:9]}  : 8'd0;
    assign b8 = de_d ? {fb_rdata[4:0],   fb_rdata[4:2]}   : 8'd0;

    // デバッグ LED (負論理)
    //   LED0: PLL ロック  LED1: 設定完了  LED2: カメラフレームごとに点滅
    assign led[0] = ~pll_lock;
    assign led[1] = ~cfg_done;
    assign led[2] = ~frame_toggle;
    assign led[5:3] = 3'b111;
    assign uart_tx  = 1'b1;
    assign env_sda  = 1'bz;
    assign env_scl  = 1'bz;

    // Phase 1 で使わない信号 (lint 用にまとめて参照)
    wire unused_ok = &{1'b0, fb_sof, vx[1:0], vy[9], vy[1:0], btn_mark_n, env_sda, env_scl, ENV_OVERLAY != 0};
`else
    // ==================================================================
    // Phase 2: PSRAM トリプルバッファ
    // ==================================================================
    // ---- メモリクロック: 27MHz -> 45MHz (CLKOUT) / 45MHz 90°遅れ (CLKOUTP, PSRAM の CK 用)
    //   実機 (OSS フロー) で 63MHz では PSRAM の読み出しが不安定だったので下げている。
    //   帯域: 1 ラインの読み出し 10 バースト ≒ 630 クロック = 14µs (ライン表示時間 31.7µs)
    localparam integer MEM_HZ = 45_000_000;
    wire clk_mem, clk_mem_p, pll2_lock;
    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),    // /3
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(4),  // x5 -> 45MHz
        .DYN_ODIV_SEL("false"), .ODIV_SEL(16),   // VCO = 720MHz
        .PSDA_SEL("0100"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),   // CLKOUTP = 90°
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) u_pll_mem (
        .CLKOUT(clk_mem), .LOCK(pll2_lock), .CLKOUTP(clk_mem_p), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    // リセット同期化 (clk_mem ドメイン)
    reg [3:0] rst_mem_sr;
    initial rst_mem_sr = 4'hF;
    always @(posedge clk_mem or negedge pll2_lock)
        if (!pll2_lock) rst_mem_sr <= 4'hF;
        else            rst_mem_sr <= {rst_mem_sr[2:0], ~btn_rst_n};
    wire rst_mem = rst_mem_sr[3];

    // ---- キャプチャ: カメラ信号を clk_mem でオーバーサンプルし (cam_sync)、
    //      PCLK 立ち上がりごとの ce で 640x480 全画素を取り込んで 2 画素単位で FIFO へ
    wire        cam_ce, cam_vs_s, cam_hr_s, cam_pclk_s;
    wire [1:0]  cam_pclk_pair;
    wire [1:0]  cam_dsel = 2'd0;  // データのサンプル位置 (cam_sync.v)。実機で 0 (立ち上がりのサンプル) が最良だった
    wire [7:0]  cam_d_s;
`ifdef CAM_NO_HOLDOFF
    localparam [3:0] CAM_HOLD = 4'd0;    // ホールドオフなし (基板の信号品質の評価用。グリッチをそのまま数える)
`elsif CAM_SLOW
    localparam [3:0] CAM_HOLD = 4'd10;   // PCLK 6.3MHz (約 14 サンプル周期)
`else
    localparam [3:0] CAM_HOLD = 4'd5;    // PCLK 12.6MHz (約 7 サンプル周期)
`endif
    cam_sync #(.HOLD(CAM_HOLD)) u_csync (
        .clk(clk_mem), .dsel(cam_dsel), .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .ce(cam_ce), .vsync_o(cam_vs_s), .href_o(cam_hr_s), .d_o(cam_d_s), .pclk_s(cam_pclk_s), .pclk_pair(cam_pclk_pair)
    );
`ifdef CAM_DEBUG
    wire [71:0] cam_rl;
    cam_runlen #(.WINDOW(4096)) u_crl (.clk(clk_mem), .rst(rst_mem), .pair(cam_pclk_pair), .hist(cam_rl));
`endif
    wire        cap_we, cap_sof;
    wire [18:0] cap_waddr;
    wire [15:0] cap_wdata;
    cam_capture #(.DECIMATE(0), .AW(19)) u_cap (
        .pclk(clk_mem), .ce(cam_ce), .vsync(cam_vs_s), .href(cam_hr_s), .d(cam_d_s),
        .we(cap_we), .waddr(cap_waddr), .wdata(cap_wdata), .sof(cap_sof),
        .frame_toggle(frame_toggle)
    );

    // ---- 取り込み異常の検出 (横筋の原因切り分け, cam_probe.v)。-DCAM_DEBUG のときだけ入れる
    //   (デバッグ用のカウンタ群は LUT/ALU を多く使い、BME280 表示と合わせると FPGA に収まらない)
    //   -DCAM_DEBUG -DCAM_DBG_MARK のとき、異常を検出した位置から行末までを単色で塗る
    //   (赤: 余分な PCLK 立ち上がり  青: 立ち上がりの取りこぼし  緑: HREF の瞬断)
`ifdef CAM_DEBUG
    wire [1:0]  cam_mark;
    wire [15:0] pr_short, pr_long, pr_ok, pr_bad, pr_hg;
    wire [23:0] pr_i3, pr_i4;
    wire [11:0] pr_bmin, pr_bmax, pr_apos, pr_aline;
    wire [3:0]  pr_atype;
    wire [31:0] pr_ahist;
    wire [95:0] pr_d1;
    wire [11:0] pr_dn;
    cam_probe #(.WINDOW(MEM_HZ)) u_cprobe (
        .clk(clk_mem), .rst(rst_mem), .ce(cam_ce), .vsync(cam_vs_s), .href(cam_hr_s), .d(cam_d_s), .pclk_pair(cam_pclk_pair),
        .mark(cam_mark),
        .n_short(pr_short), .n_i3(pr_i3), .n_i4(pr_i4), .n_long(pr_long),
        .n_ok(pr_ok), .n_bad(pr_bad), .bpl_min(pr_bmin), .bpl_max(pr_bmax), .n_hg(pr_hg),
        .an_type(pr_atype), .an_pos(pr_apos), .an_line(pr_aline), .an_hist(pr_ahist),
        .d_ones(pr_d1), .d_n(pr_dn)
    );
`else
    wire [1:0]  cam_mark = 2'b00;
`endif

    // S2 (負論理) のチャタリング除去 (約 23ms 安定で確定) と、押すごとの彩度の切り替え (CAM_YUV)
    //   sat_sel 0..4 -> 彩度 x1.0, x1.25, x1.5, x1.75, x2.0。起動時は x1.0 (実機で見比べて最良)
    wire        btn_mark_s;
    cdc_sync #(.W(1)) u_btn_sync (.clk(clk_mem), .d(btn_mark_n), .q(btn_mark_s));
    reg [19:0]  btn_cnt;
    reg         btn_st;
    reg  [2:0]  sat_sel;
    initial begin btn_cnt = 0; btn_st = 1'b1; sat_sel = 3'd0; end
    always @(posedge clk_mem) begin
        if (btn_mark_s == btn_st) begin
            btn_cnt <= 20'd0;
        end else if (&btn_cnt) begin
            btn_cnt <= 20'd0;
            btn_st  <= btn_mark_s;
            if (!btn_mark_s) sat_sel <= (sat_sel == 3'd4) ? 3'd0 : sat_sel + 3'd1;
        end else begin
            btn_cnt <= btn_cnt + 20'd1;
        end
    end
`ifdef CAM_DEBUG
`ifdef CAM_DBG_MARK
    wire        mark_en = 1'b1;
`else
    wire        mark_en = 1'b0;
`endif
`else
    wire        mark_en = 1'b0;
`endif
    wire [15:0] mark_px     = (cam_mark == 2'd1) ? 16'hF800 : (cam_mark == 2'd2) ? 16'h001F : 16'h07E0;
    wire [15:0] cap_wdata_m = (mark_en && cam_mark != 2'd0) ? mark_px : cap_wdata;

    localparam FIFO_AW  = 9;              // 512 エントリ = 1024 画素
    // PSRAM のバースト長 (ワード)。実機のデバイスは 16 ワード (32 バイト/ダイ) で折り返すので 16
    localparam PSRAM_BL = 16;
    wire        fifo_wr, fifo_full, fifo_ovf;
    wire [32:0] fifo_din;
    cam_pack #(.ALIGN_LOG2($clog2(PSRAM_BL))) u_pack (
        .pclk(clk_mem), .ce(cam_ce), .we(cap_we), .wdata(cap_wdata_m), .sof(cap_sof),
        .frame_toggle(frame_toggle), .fifo_full(fifo_full),
        .fifo_wr(fifo_wr), .fifo_din(fifo_din), .ovf(fifo_ovf)
    );

    wire [32:0]        fifo_dout;
    wire               fifo_valid, fifo_rd;
    wire [FIFO_AW+1:0] fifo_count;
    async_fifo #(.DW(33), .AW(FIFO_AW)) u_fifo (
        .wclk(clk_mem), .wr_en(fifo_wr & cam_ce), .din(fifo_din), .full(fifo_full),
        .rclk(clk_mem), .rd_en(fifo_rd), .dout(fifo_dout), .valid(fifo_valid), .rcount(fifo_count)
    );

    // ---- PSRAM コントローラとフレームバッファ管理 (clk_mem ドメイン)
    wire        mem_init_done, mem_init_fail, mem_ready, mem_req, mem_req_we;
    wire [20:0] mem_req_addr;
    wire        mem_wd_take, mem_rd_valid, mem_xfer_done, mem_rd_err;
    wire [31:0] mem_wd, mem_rd_data;
    wire [3:0]  mem_wr_gap;
    wire [7:0]  dbg_attempts;
    wire [95:0] dbg_res;
    wire [63:0] dbg_rwtrace;
    wire [63:0] dbg_q7, dbg_q15;
    wire [31:0] dbg_word, dbg_word2, dbg_id0, dbg_cr0a, dbg_cr0b;

    psram_ctrl #(.CLK_HZ(MEM_HZ), .BL(PSRAM_BL)) u_psram (
        .clk(clk_mem), .clk_p(clk_mem_p), .rst(rst_mem),
        .init_done(mem_init_done), .init_fail(mem_init_fail), .wr_gap(mem_wr_gap),
        .ready(mem_ready), .req(mem_req), .req_we(mem_req_we), .req_addr(mem_req_addr),
        .wd_take(mem_wd_take), .wd(mem_wd),
        .rd_valid(mem_rd_valid), .rd_data(mem_rd_data),
        .xfer_done(mem_xfer_done), .rd_err(mem_rd_err),
        .dbg_attempts(dbg_attempts), .dbg_res(dbg_res), .dbg_rwtrace(dbg_rwtrace), .dbg_word(dbg_word), .dbg_word2(dbg_word2), .dbg_q7(dbg_q7), .dbg_q15(dbg_q15),
        .dbg_id0(dbg_id0), .dbg_cr0a(dbg_cr0a), .dbg_cr0b(dbg_cr0b),
        .O_psram_ck(O_psram_ck), .O_psram_ck_n(O_psram_ck_n), .O_psram_cs_n(O_psram_cs_n),
        .O_psram_reset_n(O_psram_reset_n), .IO_psram_dq(IO_psram_dq), .IO_psram_rwds(IO_psram_rwds)
    );

    wire        line_req_tog, vblank_tog, line_done_tog;
    wire [8:0]  line_req_num, line_done_num;
    wire        lb_we;
    wire [9:0]  lb_waddr, lb_raddr;
    wire [31:0] lb_wdata, lb_rdata;
    wire        frame_wr_tog, rd_err_seen, frame_broken;
    wire [1:0]  disp_buf, wr_buf, latest_buf;

    psram_fb #(.FIFO_AW(FIFO_AW), .BL(PSRAM_BL)) u_fb (
        .clk(clk_mem), .rst(rst_mem),
        .fifo_dout(fifo_dout), .fifo_valid(fifo_valid), .fifo_count(fifo_count), .fifo_rd(fifo_rd),
        .line_req_tog(line_req_tog), .line_req_num(line_req_num), .vblank_tog(vblank_tog),
        .line_done_tog(line_done_tog), .line_done_num(line_done_num),
        .lb_we(lb_we), .lb_waddr(lb_waddr), .lb_wdata(lb_wdata),
        .mem_init_done(mem_init_done), .mem_ready(mem_ready),
        .mem_req(mem_req), .mem_req_we(mem_req_we), .mem_req_addr(mem_req_addr),
        .mem_wd_take(mem_wd_take), .mem_wd(mem_wd),
        .mem_rd_valid(mem_rd_valid), .mem_rd_data(mem_rd_data),
        .mem_xfer_done(mem_xfer_done), .mem_rd_err(mem_rd_err),
        .frame_wr_tog(frame_wr_tog), .disp_buf(disp_buf), .wr_buf(wr_buf), .latest_buf(latest_buf),
        .rd_err_seen(rd_err_seen), .frame_broken(frame_broken)
    );

    // ---- ラインバッファ (ping-pong 2 面 x 320 ワード x 32bit, BSRAM)
    dpram #(.DW(32), .AW(10)) u_lb (
        .wclk(clk_mem), .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
        .rclk(clk_pix), .raddr(lb_raddr), .rdata(lb_rdata)
    );

    // ---- 表示 (clk_pix ドメイン)
    wire underrun;
    // 彩度 (clk_mem の S2 で切り替え) を表示側へ。ほぼ静的な値なので 2FF で十分
    //   (切り替えの瞬間に 1 画素だけ中間の値になりうるが表示上は問題ない)
    wire [2:0] sat_sel_p;
    cdc_sync #(.W(3)) u_sat_sync (.clk(clk_pix), .d(sat_sel), .q(sat_sel_p));
    wire [3:0] yuv_sat = 4'd4 + {1'b0, sat_sel_p};
    wire [7:0] rv8, gv8, bv8;
    wire       de_v, hs_v, vs_v;
    fb_display u_disp (
        .clk(clk_pix), .rst(rst), .x(vx), .y(vy), .de(vde), .hs(vhs), .vs(vvs),
        .mem_ready(mem_init_done), .sat(yuv_sat),
        .lb_raddr(lb_raddr), .lb_rdata(lb_rdata),
        .line_req_tog(line_req_tog), .line_req_num(line_req_num), .vblank_tog(vblank_tog),
        .line_done_tog(line_done_tog), .line_done_num(line_done_num),
        .r(rv8), .g(gv8), .b(bv8), .de_o(de_v), .hs_o(hs_v), .vs_o(vs_v),
        .underrun(underrun)
    );

    // ---- BME280 (温度・湿度・気圧) を I2C で読み、表示文字を作る (clk_mem)
    wire       env_scl_low, env_sda_low, env_txt_we, env_err;
    wire [5:0] env_txt_addr;
    wire [4:0] env_txt_data;
    wire [7:0] env_chip, env_n_ok;
    bme280_env #(.CLK_HZ(MEM_HZ), .PERIOD(MEM_HZ), .BOOT(MEM_HZ / 100)) u_env (
        .clk(clk_mem), .rst(rst_mem), .scl_low(env_scl_low), .sda_low(env_sda_low), .sda_in(env_sda),
        .txt_we(env_txt_we), .txt_addr(env_txt_addr), .txt_data(env_txt_data),
        .chip_id(env_chip), .err(env_err), .n_ok(env_n_ok)
    );
    assign env_scl = env_scl_low ? 1'b0 : 1'bz;
    assign env_sda = env_sda_low ? 1'b0 : 1'bz;

    // ---- 画面右上に重ねる (clk_pix)。fb_display の出力は vx/vy から VLAT 遅れ
`ifdef CAM_YUV
    localparam integer DISP_LAT = 4;           // BSRAM 1 + yuv2rgb 3
`else
    localparam integer DISP_LAT = 1;
`endif
    text_overlay #(.VLAT(DISP_LAT), .ENABLE(ENV_OVERLAY)) u_ov (
        .clk(clk_pix), .x(vx), .y(vy), .de(vde),
        .r_in(rv8), .g_in(gv8), .b_in(bv8), .de_in(de_v), .hs_in(hs_v), .vs_in(vs_v),
        .r(r8), .g(g8), .b(b8), .de_o(de_d), .hs_o(hs_d), .vs_o(vs_d),
        .txt_clk(clk_mem), .txt_we(env_txt_we), .txt_addr(env_txt_addr), .txt_data(env_txt_data)
    );

    // ---- デバッグ LED (負論理)
    //   LED0: PLL ロック (2 個とも)   LED1: SCCB 設定完了   LED2: カメラフレームごとに点滅
    //   LED3: PSRAM 初期化完了 (調整失敗中は点滅)   LED4: アンダーラン検出 (スティッキー)
    //   LED5: PSRAM へのフレーム書き込み完了ごとに点滅
    reg [24:0] blink;
    initial blink = 0;
    always @(posedge clk_mem) blink <= blink + 1'b1;
    wire psram_led = mem_init_done | (mem_init_fail & blink[24]);

    assign led[0] = ~(pll_lock & pll2_lock);
    assign led[1] = ~cfg_done;
    assign led[2] = ~frame_toggle;
    assign led[3] = ~psram_led;
    assign led[4] = ~underrun;
    assign led[5] = ~frame_wr_tog;

    // ---- UART デバッグ出力 (1 秒ごとに 1 行)
    //   通常: U=起動後秒数 RC=リセット回数 S G FW E SA BM (下の説明を参照)
    //   -DCAM_DEBUG: 以下すべて (カメラ取り込みの詳しい統計)
    //   A: 調整ラウンド数  S: {init_fail, init_done}  G: 採用 gap
    //   PR: PCLK ピンの立ち上がり [回/秒] (DQCE を通る前)
    //   PC8: PCLK/8 [回/秒]  VS: VSYNC [回/秒]  HR: HREF [回/秒]
    //   BL: 1 ラインの PCLK 数 (0x500 期待)  LN: 1 フレームのライン数 (0x1E0 期待)
    //   FW: PSRAM に書けたフレーム数  E: {underrun, rd_err, SOF異常, FIFOあふれ(初期化前を含む)}
    //   以下は cam_probe (1 秒窓)。ライン内の PCLK 立ち上がり (ce) 間隔は正常なら 3 か 4 クロック
    //   CI: ce 間隔 {<=2 (余分な立ち上がり), =3, =4, >=5 (取りこぼし)}
    //   LB: 1 ラインのバイト数 {=1280 のライン数, !=1280 のライン数, 最小, 最大}  HG: HREF の瞬断数
    //   AN: 窓内で最初の異常 {種類 1:余分 2:取りこぼし 3:HREF瞬断, ライン内バイト位置, ライン番号,
    //       PCLK サンプル列 16 クロック x {先,後} (MSB が古い)}   M: マーカー表示 (-DCAM_DBG_MARK)
    //   SA: CAM_YUV の彩度の段階 (0..4 = x1.0..x2.0。S2 で切り替え)
    //   BM: BME280 {品番 (60=BME280, 58=BMP280), 通信エラー, 測定値を読めた回数}
    //   DH: 上位バイト ([R5 G3]) の D7..D0 が 1 だった回数 / N: サンプル数 (FFF)。D7 = R の MSB
`ifdef CAM_DEBUG
    wire [11:0] cam_bpl, cam_lpf;
    wire        cam_pdiv;
    cam_stats u_cstat (
        .pclk(clk_mem), .ce(cam_ce), .vsync(cam_vs_s), .href(cam_hr_s),
        .bpl(cam_bpl), .lpf(cam_lpf), .pdiv(cam_pdiv)
    );
    wire [23:0] mon_pc8, mon_pr;
    wire [7:0]  mon_vs;
    wire [15:0] mon_hr;
    cam_monitor #(.WINDOW(MEM_HZ)) u_cmon (
        .clk(clk_mem), .rst(rst_mem), .pdiv(cam_pdiv), .vsync(cam_vs_s), .href(cam_hr_s),
        .pclk_pin(cam_pclk_s),
        .pc8(mon_pc8), .pr(mon_pr), .vs_cnt(mon_vs), .hr_cnt(mon_hr)
    );
`endif
    // リセットに関係なく数える: 起動後の秒数と、mem 側リセットの回数 (リセットが繰り返されていないかの確認)
    localparam integer UP_LAST_I = MEM_HZ - 1;
    localparam [25:0]  UP_LAST   = UP_LAST_I[25:0];
    reg [25:0] up_div;
    reg [15:0] uptime;
    reg [7:0]  rst_cnt;
    reg        rst_mem_d;
    initial begin up_div = 0; uptime = 0; rst_cnt = 0; rst_mem_d = 1'b0; end
    always @(posedge clk_mem) begin
        rst_mem_d <= rst_mem;
        up_div <= (up_div == UP_LAST) ? 26'd0 : up_div + 1'b1;
        if (up_div == UP_LAST) uptime <= uptime + 1'b1;
        if (rst_mem && !rst_mem_d && rst_cnt != 8'hFF) rst_cnt <= rst_cnt + 1'b1;
    end
    reg  [7:0] frames_wr;
    reg        fwt_d;
    always @(posedge clk_mem) begin
        fwt_d <= frame_wr_tog;
        if (rst_mem)                     frames_wr <= 8'd0;
        else if (frame_wr_tog != fwt_d)  frames_wr <= frames_wr + 1'b1;
    end
    wire ur_s, ovf_s;
    cdc_sync #(.W(2)) u_dbg_sync (.clk(clk_mem), .d({underrun, fifo_ovf}), .q({ur_s, ovf_s}));

`ifdef CAM_DEBUG
    localparam DBG_TPL = "U=#### RC=## A=## S=# G=# | RL=################## PR=###### PC8=###### VS=## HR=#### BL=### LN=### FW=## E=# | CI=####:######:######:#### LB=####:####:###:### HG=#### AN=#:###:###:######## M=# SA=# DH=###:###:###:###:###:###:###:### N=### | BM=##:#:##";
    dbg_report #(.CLK_HZ(MEM_HZ), .PERIOD(MEM_HZ), .LEN(251), .NN(142), .TPL(DBG_TPL)) u_dbg (
        .clk(clk_mem), .rst(rst_mem),
        .nib({uptime, rst_cnt, dbg_attempts, 2'b00, mem_init_fail, mem_init_done, mem_wr_gap, cam_rl, mon_pr, mon_pc8, mon_vs, mon_hr, cam_bpl, cam_lpf, frames_wr,
              ur_s, rd_err_seen, frame_broken, ovf_s,
              pr_short, pr_i3, pr_i4, pr_long, pr_ok, pr_bad, pr_bmin, pr_bmax, pr_hg,
              pr_atype, pr_apos, pr_aline, pr_ahist, 3'b000, mark_en, 1'b0, sat_sel, pr_d1, pr_dn, env_chip, 3'b000, env_err, env_n_ok}),
        .tx(uart_tx)
    );
`else
    localparam DBG_TPL = "U=#### RC=## S=# G=# FW=## E=# SA=# | BM=##:#:##";
    dbg_report #(.CLK_HZ(MEM_HZ), .PERIOD(MEM_HZ), .LEN(48), .NN(17), .TPL(DBG_TPL)) u_dbg (
        .clk(clk_mem), .rst(rst_mem),
        .nib({uptime, rst_cnt, 2'b00, mem_init_fail, mem_init_done, mem_wr_gap, frames_wr,
              ur_s, rd_err_seen, frame_broken, ovf_s, 1'b0, sat_sel, env_chip, 3'b000, env_err, env_n_ok}),
        .tx(uart_tx)
    );
    wire unused_dbg = &{1'b0, cam_pclk_pair, cam_pclk_s, dbg_attempts, mark_en};
`endif

    // 検証用に残す信号 (lint 用にまとめて参照)
    // PSRAM 立ち上げ用のデバッグ出力 (R/T/W/X/Q/P/I/C/D) は UART から外した。出力に含めると
    // cam_probe と合わせて nextpnr の HeAP 配置が終わらなくなるため。必要なら DBG_TPL と nib に戻す
    wire unused_ok = &{1'b0, dbg_res, dbg_rwtrace, dbg_word, dbg_word2, dbg_q7, dbg_q15, dbg_id0, dbg_cr0a, dbg_cr0b,
                       cap_waddr, disp_buf, wr_buf, latest_buf};
`endif

    // ------------------------------------------------------------------
    // DVI(HDMI) 送信
    // ------------------------------------------------------------------
    dvi_tx u_dvi (
        .clk_pix(clk_pix), .clk_ser(clk_ser), .rst(rst),
        .r(r8), .g(g8), .b(b8), .de(de_d), .hs(hs_d), .vs(vs_d),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );
endmodule
/* verilator lint_on PINCONNECTEMPTY */
