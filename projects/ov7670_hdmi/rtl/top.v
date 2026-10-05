// ============================================================================
// Tang Nano 9K + OV7670 (FIFO なし) -> HDMI (DVI) 640x480@60Hz カメラモニタ
//   内蔵 PSRAM をトリプルバッファにして 640x480 をフル解像度で表示し、
//   BME280 の温度・湿度・気圧を右上に重ねる
//
//     clk_mem (45MHz)                                                  clk_pix (25.2MHz)
//     cam_frontend ─► psram_fb ◄─► psram_ctrl ◄─► 内蔵 PSRAM
//     (取り込み+FIFO)    └─► ラインバッファ (2 面) ─► fb_display ─► text_overlay ─► dvi_tx
//     bme280_env ─────────────────────── 表示文字 ───────────────┘
//
//   設計の切り替え (EXTRA_DEFINES, 変更後は make clean):
//     -DCAM_YUV        カメラを YUV422 で受けて FPGA で RGB に変換する (既定は RGB565)
//     -DCAM_SLOW       カメラを 7.5fps (PCLK 6.3MHz) にする。YUV を 15fps で取り込めない配線向け
//     -DCAM_NO_HOLDOFF PCLK のグリッチを捨てない (基板の信号品質の評価用)
//     -DCAM_DEBUG      UART にカメラ取り込みの統計を出す (dbg_uart.v)。統計のカウンタ群と BME280 を
//                      両方入れると FPGA に収まらないので、このときは BME280 を入れない
//     -DCAM_TESTBAR    カメラにカラーバーを出させる (ov7670_regs.v)
// ============================================================================
/* verilator lint_off PINCONNECTEMPTY */   // ベンダプリミティブの未使用出力
module top #(
    parameter ENV_OVERLAY = 1        // BME280 の表示を重ねる (システム試験では 0)
)(
    input  wire        clk27,        // 27MHz 水晶
    input  wire        btn_rst_n,    // ボタン S1: リセット
    input  wire        btn_s2_n,     // ボタン S2: 押すごとに CAM_YUV の彩度を切り替え

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

    // 内蔵 PSRAM (ポート名で内部ピンに自動配置される)
    output wire [1:0]  O_psram_ck,
    output wire [1:0]  O_psram_ck_n,
    output wire [1:0]  O_psram_cs_n,
    output wire [1:0]  O_psram_reset_n,
    inout  wire [15:0] IO_psram_dq,
    inout  wire [1:0]  IO_psram_rwds,

    // BME280 (I2C, オープンドレイン)
    inout  wire        env_sda,
    inout  wire        env_scl,

    output wire        uart_tx,      // 状態表示 (BL702 経由で USB シリアル, 115200 8N1)
    output wire [5:0]  led           // 負論理
);
    localparam integer MEM_HZ   = 45_000_000;
    localparam integer FIFO_AW  = 9;          // カメラ FIFO 512 エントリ = 1024 画素
    // PSRAM のバースト長 (ワード)。実機のデバイスは 16 ワード (32 バイト/ダイ) で折り返すので 16
    localparam integer PSRAM_BL = 16;
`ifdef CAM_NO_HOLDOFF
    localparam [3:0]   CAM_HOLD = 4'd0;       // ホールドオフなし (グリッチをそのまま数える)
`elsif CAM_SLOW
    localparam [3:0]   CAM_HOLD = 4'd10;      // PCLK 6.3MHz (約 14 サンプル周期)
`else
    localparam [3:0]   CAM_HOLD = 4'd5;       // PCLK 12.6MHz (約 7 サンプル周期)
`endif
`ifdef CAM_DEBUG
    localparam integer USE_ENV  = 0;          // BME280 なし (上記)
`else
    localparam integer USE_ENV  = 1;
`endif
`ifdef CAM_YUV
    localparam integer DISP_LAT = 4;          // fb_display の遅れ: BSRAM 1 + yuv2rgb 3
`else
    localparam integer DISP_LAT = 1;          // BSRAM 1
`endif

    // ------------------------------------------------------------------
    // クロックとリセット
    // ------------------------------------------------------------------
    wire clk_ser, clk_pix, clk_mem, clk_mem_p, locked, rst, rst_mem;
    clocks u_clk (
        .clk27(clk27), .btn_rst_n(btn_rst_n),
        .clk_ser(clk_ser), .clk_pix(clk_pix), .clk_mem(clk_mem), .clk_mem_p(clk_mem_p),
        .locked(locked), .rst_pix(rst), .rst_mem(rst_mem)
    );

    // ------------------------------------------------------------------
    // カメラ: XCLK (25.2MHz) の供給と SCCB でのレジスタ設定 (clk_pix)
    // ------------------------------------------------------------------
    ODDR u_xclk (.Q0(cam_xclk), .Q1(), .D0(1'b1), .D1(1'b0), .TX(1'b0), .CLK(clk_pix));
    assign cam_pwdn = 1'b0;   // 常に動作。ピン (41) は PCLK の隣を通す GND ガード線を兼ねる (cst 参照)

    wire siod_drive_low, cfg_done;
    ov7670_sccb_init #(.CLK_HZ(25_200_000), .SCCB_HZ(100_000)) u_cfg (
        .clk(clk_pix), .rst(rst),
        .cam_reset_n(cam_reset_n),
        .sioc(cam_sioc), .siod_drive_low(siod_drive_low),
        .done(cfg_done)
    );
    assign cam_siod = siod_drive_low ? 1'b0 : 1'bz;   // オープンドレイン

    // ------------------------------------------------------------------
    // カメラの取り込み (clk_mem): オーバーサンプル -> 640x480 -> 2 画素単位で FIFO へ
    // ------------------------------------------------------------------
    wire [32:0]        fifo_dout;
    wire               fifo_valid, fifo_rd, fifo_ovf, frame_toggle;
    wire [FIFO_AW+1:0] fifo_count;
    wire               cam_ce, cam_vs_s, cam_hr_s, cam_pclk_s;
    wire [7:0]         cam_d_s;
    wire [1:0]         cam_pclk_pair;
    cam_frontend #(.HOLD(CAM_HOLD), .FIFO_AW(FIFO_AW), .ALIGN_LOG2($clog2(PSRAM_BL))) u_cam (
        .clk(clk_mem), .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .fifo_rd(fifo_rd), .fifo_dout(fifo_dout), .fifo_valid(fifo_valid), .fifo_count(fifo_count),
        .frame_toggle(frame_toggle), .fifo_ovf(fifo_ovf),
        .cam_ce(cam_ce), .cam_vsync(cam_vs_s), .cam_href(cam_hr_s), .cam_d(cam_d_s),
        .cam_pclk_s(cam_pclk_s), .cam_pclk_pair(cam_pclk_pair)
    );

    // ------------------------------------------------------------------
    // PSRAM コントローラとフレームバッファ管理 (clk_mem)
    // ------------------------------------------------------------------
    wire        mem_init_done, mem_init_fail, mem_ready, mem_req, mem_req_we;
    wire [20:0] mem_req_addr;
    wire        mem_wd_take, mem_rd_valid, mem_xfer_done, mem_rd_err;
    wire [31:0] mem_wd, mem_rd_data;
    wire [3:0]  mem_wr_gap;
    psram_ctrl #(.CLK_HZ(MEM_HZ), .BL(PSRAM_BL)) u_psram (
        .clk(clk_mem), .clk_p(clk_mem_p), .rst(rst_mem),
        .init_done(mem_init_done), .init_fail(mem_init_fail), .wr_gap(mem_wr_gap),
        .ready(mem_ready), .req(mem_req), .req_we(mem_req_we), .req_addr(mem_req_addr),
        .wd_take(mem_wd_take), .wd(mem_wd),
        .rd_valid(mem_rd_valid), .rd_data(mem_rd_data),
        .xfer_done(mem_xfer_done), .rd_err(mem_rd_err),
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

    // ラインバッファ (ping-pong 2 面 x 320 ワード x 32bit, BSRAM)
    dpram #(.DW(32), .AW(10)) u_lb (
        .wclk(clk_mem), .we(lb_we), .waddr(lb_waddr), .wdata(lb_wdata),
        .rclk(clk_pix), .raddr(lb_raddr), .rdata(lb_rdata)
    );

    // ------------------------------------------------------------------
    // ボタン S2: 押すごとに彩度 x1.0, x1.25, x1.5, x1.75, x2.0 (CAM_YUV のみ有効)
    // ------------------------------------------------------------------
    wire      s2_press;
    reg [2:0] sat_sel;
    initial sat_sel = 3'd0;
    btn_debounce u_s2 (.clk(clk_mem), .btn_n(btn_s2_n), .press(s2_press));
    always @(posedge clk_mem)
        if (s2_press) sat_sel <= (sat_sel == 3'd4) ? 3'd0 : sat_sel + 3'd1;
    // 表示側へ。ほぼ静的な値なので 2FF で十分 (切り替えの瞬間に 1 画素だけ中間の値になりうる)
    wire [2:0] sat_sel_p;
    cdc_sync #(.W(3)) u_sat_sync (.clk(clk_pix), .d(sat_sel), .q(sat_sel_p));

    // ------------------------------------------------------------------
    // 表示 (clk_pix)
    // ------------------------------------------------------------------
    wire [9:0] vx, vy;
    wire       vde, vhs, vvs;
    video_timing u_vt (.clk(clk_pix), .rst(rst), .x(vx), .y(vy), .de(vde), .hs(vhs), .vs(vvs));

    wire       underrun;
    wire [7:0] rv8, gv8, bv8;
    wire       de_v, hs_v, vs_v;
    fb_display u_disp (
        .clk(clk_pix), .rst(rst), .x(vx), .y(vy), .de(vde), .hs(vhs), .vs(vvs),
        .mem_ready(mem_init_done), .sat(4'd4 + {1'b0, sat_sel_p}),
        .lb_raddr(lb_raddr), .lb_rdata(lb_rdata),
        .line_req_tog(line_req_tog), .line_req_num(line_req_num), .vblank_tog(vblank_tog),
        .line_done_tog(line_done_tog), .line_done_num(line_done_num),
        .r(rv8), .g(gv8), .b(bv8), .de_o(de_v), .hs_o(hs_v), .vs_o(vs_v),
        .underrun(underrun)
    );

    // BME280 (温度・湿度・気圧) を I2C で読み、表示文字を作る (clk_mem)
    wire       env_scl_low, env_sda_low, env_txt_we, env_err;
    wire [5:0] env_txt_addr;
    wire [4:0] env_txt_data;
    wire [7:0] env_chip, env_n_ok;
    generate
        if (USE_ENV != 0) begin : g_env
            bme280_env #(.CLK_HZ(MEM_HZ), .PERIOD(MEM_HZ), .BOOT(MEM_HZ / 100)) u_env (
                .clk(clk_mem), .rst(rst_mem), .scl_low(env_scl_low), .sda_low(env_sda_low), .sda_in(env_sda),
                .txt_we(env_txt_we), .txt_addr(env_txt_addr), .txt_data(env_txt_data),
                .chip_id(env_chip), .err(env_err), .n_ok(env_n_ok)
            );
        end else begin : g_noenv
            assign {env_scl_low, env_sda_low, env_txt_we, env_err} = 4'b0000;
            assign {env_txt_addr, env_txt_data, env_chip, env_n_ok} = 27'd0;
        end
    endgenerate
    assign env_scl = env_scl_low ? 1'b0 : 1'bz;
    assign env_sda = env_sda_low ? 1'b0 : 1'bz;

    // 画面右上に重ねる
    wire [7:0] r8, g8, b8;
    wire       de_d, hs_d, vs_d;
    text_overlay #(.VLAT(DISP_LAT), .ENABLE((ENV_OVERLAY != 0 && USE_ENV != 0) ? 1 : 0)) u_ov (
        .clk(clk_pix), .x(vx), .y(vy), .de(vde),
        .r_in(rv8), .g_in(gv8), .b_in(bv8), .de_in(de_v), .hs_in(hs_v), .vs_in(vs_v),
        .r(r8), .g(g8), .b(b8), .de_o(de_d), .hs_o(hs_d), .vs_o(vs_d),
        .txt_clk(clk_mem), .txt_we(env_txt_we), .txt_addr(env_txt_addr), .txt_data(env_txt_data)
    );

    dvi_tx u_dvi (
        .clk_pix(clk_pix), .clk_ser(clk_ser), .rst(rst),
        .r(r8), .g(g8), .b(b8), .de(de_d), .hs(hs_d), .vs(vs_d),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n)
    );

    // ------------------------------------------------------------------
    // 状態表示
    // ------------------------------------------------------------------
    // LED (負論理)
    //   0: PLL ロック (2 個とも)   1: SCCB 設定完了   2: カメラフレームごとに点滅
    //   3: PSRAM 初期化完了 (調整失敗中は点滅)   4: アンダーラン検出 (スティッキー)
    //   5: PSRAM へのフレーム書き込み完了ごとに点滅
    reg [24:0] blink;
    initial blink = 0;
    always @(posedge clk_mem) blink <= blink + 1'b1;
    wire psram_led = mem_init_done | (mem_init_fail & blink[24]);

    assign led[0] = ~locked;
    assign led[1] = ~cfg_done;
    assign led[2] = ~frame_toggle;
    assign led[3] = ~psram_led;
    assign led[4] = ~underrun;
    assign led[5] = ~frame_wr_tog;

    // UART (1 秒ごとに 1 行。項目は dbg_uart.v)
    dbg_uart #(.CLK_HZ(MEM_HZ)) u_dbg (
        .clk(clk_mem), .rst(rst_mem), .tx(uart_tx),
        .mem_init_done(mem_init_done), .mem_init_fail(mem_init_fail), .mem_wr_gap(mem_wr_gap),
        .frame_wr_tog(frame_wr_tog), .underrun(underrun), .rd_err_seen(rd_err_seen),
        .frame_broken(frame_broken), .fifo_ovf(fifo_ovf), .sat_sel(sat_sel),
        .env_chip(env_chip), .env_err(env_err), .env_n_ok(env_n_ok),
        .cam_ce(cam_ce), .cam_vsync(cam_vs_s), .cam_href(cam_hr_s), .cam_d(cam_d_s),
        .cam_pclk_s(cam_pclk_s), .cam_pclk_pair(cam_pclk_pair)
    );

    // システム試験が参照する信号 (lint 用にまとめて参照)
    wire unused_ok = &{1'b0, disp_buf, wr_buf, latest_buf};
endmodule
/* verilator lint_on PINCONNECTEMPTY */
