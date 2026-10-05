// ============================================================================
// カメラ取り込み経路 (clk ドメイン = clk_mem)
//   cam_sync (PCLK をオーバーサンプル) -> cam_capture (640x480, 2 バイト/画素)
//   -> cam_pack (2 画素/エントリ + SOF, フレーム末を BL 境界まで詰める) -> async_fifo (FWFT)
//   FIFO の読み出し側は psram_fb がつなぐ。cam_* は取り込み統計 (dbg_uart) 用に出している
// ============================================================================
module cam_frontend #(
    parameter [3:0]   HOLD       = 4'd5,     // cam_sync のホールドオフ [サンプル] (0 で無効)
    parameter integer FIFO_AW    = 9,        // 512 エントリ = 1024 画素
    parameter integer ALIGN_LOG2 = 4         // フレーム末を 2^ALIGN_LOG2 エントリ (PSRAM のバースト) にそろえる
)(
    input  wire               clk,
    // OV7670 (非同期, ピン)
    input  wire               pclk,
    input  wire               vsync,
    input  wire               href,
    input  wire [7:0]         d,
    // FIFO の読み出し側
    input  wire               fifo_rd,
    output wire [32:0]        fifo_dout,         // {sof, 偶数画素, 奇数画素}
    output wire               fifo_valid,
    output wire [FIFO_AW+1:0] fifo_count,
    // 状態
    output wire               frame_toggle,      // カメラのフレームごとに反転
    output wire               fifo_ovf,          // FIFO があふれた (スティッキー)
    // 取り込み統計用 (cam_sync の出力)
    output wire               cam_ce,
    output wire               cam_vsync,
    output wire               cam_href,
    output wire [7:0]         cam_d,
    output wire               cam_pclk_s,
    output wire [1:0]         cam_pclk_pair
);
    cam_sync #(.HOLD(HOLD)) u_sync (
        .clk(clk), .pclk(pclk), .vsync(vsync), .href(href), .d(d),
        .ce(cam_ce), .vsync_o(cam_vsync), .href_o(cam_href), .d_o(cam_d),
        .pclk_s(cam_pclk_s), .pclk_pair(cam_pclk_pair)
    );

    wire        cap_we, cap_sof;
    wire [18:0] cap_waddr;
    wire [15:0] cap_wdata;
    cam_capture #(.AW(19)) u_cap (
        .pclk(clk), .ce(cam_ce), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .we(cap_we), .waddr(cap_waddr), .wdata(cap_wdata), .sof(cap_sof),
        .frame_toggle(frame_toggle)
    );

    wire        fifo_wr, fifo_full;
    wire [32:0] fifo_din;
    cam_pack #(.ALIGN_LOG2(ALIGN_LOG2)) u_pack (
        .pclk(clk), .ce(cam_ce), .we(cap_we), .wdata(cap_wdata), .sof(cap_sof),
        .frame_toggle(frame_toggle), .fifo_full(fifo_full),
        .fifo_wr(fifo_wr), .fifo_din(fifo_din), .ovf(fifo_ovf)
    );

    async_fifo #(.DW(33), .AW(FIFO_AW)) u_fifo (
        .wclk(clk), .wr_en(fifo_wr & cam_ce), .din(fifo_din), .full(fifo_full),
        .rclk(clk), .rd_en(fifo_rd), .dout(fifo_dout), .valid(fifo_valid), .rcount(fifo_count)
    );

    wire unused_ok = &{1'b0, cap_waddr};
endmodule
