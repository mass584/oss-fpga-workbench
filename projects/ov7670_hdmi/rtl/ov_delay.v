// N クロックの遅延 (N = 0 なら素通し)
module ov_delay #(
    parameter integer W = 1,
    parameter integer N = 0
)(
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    generate
        if (N == 0) begin : g_pass
            assign q = d;
            wire unused_ok = &{1'b0, clk};
        end else begin : g_dly
            reg [W-1:0] sr [0:N-1];
            integer k;
            always @(posedge clk) begin
                sr[0] <= d;
                for (k = 1; k < N; k = k + 1) sr[k] <= sr[k - 1];
            end
            assign q = sr[N - 1];
        end
    endgenerate
endmodule
