// ============================================================================
// カメラ信号の活動量 (メモリクロックドメイン, デバッグ用)
//   1 秒窓ごとに、PCLK/16 トグルの両エッジ数 (= PCLK/8)、VSYNC・HREF の立ち上がり数を数える。
//   すべて 2FF で同期してから数えるので、PCLK が止まっていても 0 として見える。
// ============================================================================
module cam_monitor #(
    parameter integer WINDOW = 63_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        pdiv,         // 非同期
    input  wire        vsync,        // 非同期 (ピン)
    input  wire        href,         // 非同期 (ピン)
    input  wire        pclk_pin,     // 非同期 (ピン)。DQCE を通る前の PCLK をそのまま数える
    output reg  [23:0] pc8,          // PCLK/8 [回/秒] (DQCE 後のクロックで動く分周器から)
    output reg  [23:0] pr,           // PCLK 立ち上がり [回/秒] (ピンを直接サンプル)
    output reg  [7:0]  vs_cnt,       // VSYNC [回/秒]
    output reg  [15:0] hr_cnt        // HREF  [回/秒]
);
    localparam [31:0] WIN_M = WINDOW - 1;

    wire pd_s, vs_s, hr_s, pp_s;
    cdc_sync #(.W(4)) u_sync (.clk(clk), .d({pdiv, vsync, href, pclk_pin}), .q({pd_s, vs_s, hr_s, pp_s}));
    reg        pd_d, vs_d, hr_d, pp_d;
    reg [23:0] c_pr;
    reg [31:0] tmr;
    reg [23:0] c_pc;
    reg [7:0]  c_vs;
    reg [15:0] c_hr;

    always @(posedge clk) begin
        pd_d <= pd_s; vs_d <= vs_s; hr_d <= hr_s; pp_d <= pp_s;
        if (rst) begin
            tmr <= 32'd0; c_pc <= 24'd0; c_vs <= 8'd0; c_hr <= 16'd0; c_pr <= 24'd0;
            pc8 <= 24'd0; vs_cnt <= 8'd0; hr_cnt <= 16'd0; pr <= 24'd0;
        end else if (tmr == WIN_M) begin
            tmr <= 32'd0;
            pc8 <= c_pc; vs_cnt <= c_vs; hr_cnt <= c_hr; pr <= c_pr;
            c_pc <= 24'd0; c_vs <= 8'd0; c_hr <= 16'd0; c_pr <= 24'd0;
        end else begin
            tmr <= tmr + 1'b1;
            if (pd_s ^ pd_d)   c_pc <= c_pc + 1'b1;
            if (vs_s && !vs_d) c_vs <= c_vs + 1'b1;
            if (hr_s && !hr_d) c_hr <= c_hr + 1'b1;
            if (pp_s && !pp_d) c_pr <= c_pr + 1'b1;
        end
    end
endmodule
