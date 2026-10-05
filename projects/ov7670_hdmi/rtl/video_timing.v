// ============================================================================
// 640x480 @60Hz タイミング (画素クロック 25.2MHz)
// ============================================================================
module video_timing #(
    parameter H_ACT = 640, H_FP = 16, H_SYNC = 96, H_BP = 48,
    parameter V_ACT = 480, V_FP = 10, V_SYNC = 2,  V_BP = 33
)(
    input  wire       clk,
    input  wire       rst,
    output reg  [9:0] x,
    output reg  [9:0] y,
    output wire       de,
    output wire       hs,     // 負極性
    output wire       vs      // 負極性
);
    localparam H_TOT = H_ACT + H_FP + H_SYNC + H_BP;   // 800
    localparam V_TOT = V_ACT + V_FP + V_SYNC + V_BP;   // 525

    always @(posedge clk) begin
        if (rst) begin
            x <= 0; y <= 0;
        end else if (x == H_TOT - 1) begin
            x <= 0;
            y <= (y == V_TOT - 1) ? 10'd0 : y + 1'b1;
        end else begin
            x <= x + 1'b1;
        end
    end

    assign de = (x < H_ACT) && (y < V_ACT);
    assign hs = ~((x >= H_ACT + H_FP) && (x < H_ACT + H_FP + H_SYNC));
    assign vs = ~((y >= V_ACT + V_FP) && (y < V_ACT + V_FP + V_SYNC));
endmodule
