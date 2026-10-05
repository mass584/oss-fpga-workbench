// ============================================================================
// カメラ信号の活動量 (clk ドメイン, デバッグ用。-DCAM_DEBUG)
//   1 秒窓ごとに PCLK・VSYNC・HREF の立ち上がり数を数える。入力は cam_sync がサンプルしたもの
//   (2FF を通っている) なので、PCLK が止まっていても 0 として見える。
//   PCLK は 1 クロックに 1 サンプルで数えるので、High/Low が 1 クロック未満のパルスは取りこぼす
// ============================================================================
module cam_monitor #(
    parameter integer WINDOW = 45_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        pclk_s,
    input  wire        vsync,
    input  wire        href,
    output reg  [23:0] pr,           // PCLK 立ち上がり [回/秒]
    output reg  [7:0]  vs_cnt,       // VSYNC [回/秒]
    output reg  [15:0] hr_cnt        // HREF  [回/秒]
);
    localparam [31:0] WIN_M = WINDOW - 1;

    reg        vs_d, hr_d, pp_d;
    reg [31:0] tmr;
    reg [23:0] c_pr;
    reg [7:0]  c_vs;
    reg [15:0] c_hr;

    always @(posedge clk) begin
        vs_d <= vsync; hr_d <= href; pp_d <= pclk_s;
        if (rst) begin
            tmr <= 32'd0; c_vs <= 8'd0; c_hr <= 16'd0; c_pr <= 24'd0;
            vs_cnt <= 8'd0; hr_cnt <= 16'd0; pr <= 24'd0;
        end else if (tmr == WIN_M) begin
            tmr <= 32'd0;
            vs_cnt <= c_vs; hr_cnt <= c_hr; pr <= c_pr;
            c_vs <= 8'd0; c_hr <= 16'd0; c_pr <= 24'd0;
        end else begin
            tmr <= tmr + 1'b1;
            if (vsync && !vs_d)   c_vs <= c_vs + 1'b1;
            if (href && !hr_d)    c_hr <= c_hr + 1'b1;
            if (pclk_s && !pp_d)  c_pr <= c_pr + 1'b1;
        end
    end
endmodule
