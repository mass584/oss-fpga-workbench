// ============================================================================
// TMDS 8b/10b エンコーダ (DVI 1.0 仕様どおり)
// ============================================================================
module tmds_encoder (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] d,
    input  wire [1:0] c,     // {C1, C0}
    input  wire       de,
    output reg  [9:0] q
);
    function [3:0] ones8(input [7:0] v);
        integer i;
        begin
            ones8 = 0;
            for (i = 0; i < 8; i = i + 1) ones8 = ones8 + v[i];
        end
    endfunction

    // Stage 1: 遷移最小化
    wire [3:0] n1d = ones8(d);
    wire use_xnor = (n1d > 4) || (n1d == 4 && d[0] == 1'b0);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar i;
    generate
        for (i = 1; i < 8; i = i + 1) begin : g_qm
            assign qm[i] = use_xnor ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
        end
    endgenerate
    assign qm[8] = ~use_xnor;

    // Stage 2: DC バランス
    wire [3:0] n1q = ones8(qm[7:0]);
    wire signed [4:0] diff = $signed({1'b0, n1q}) - 5'sd4;   // (n1 - n0)/2
    reg  signed [4:0] cnt;   // 実際の偏り/2 を保持

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 0; q <= 10'b1101010100;
        end else if (!de) begin
            cnt <= 0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                2'b11: q <= 10'b1010101011;
            endcase
        end else if (cnt == 0 || diff == 0) begin
            q   <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + diff : cnt - diff;
        end else if ((cnt > 0 && diff > 0) || (cnt < 0 && diff < 0)) begin
            q   <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + $signed({4'b0, qm[8]}) - diff;
        end else begin
            q   <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - $signed({4'b0, ~qm[8]}) + diff;
        end
    end
endmodule
