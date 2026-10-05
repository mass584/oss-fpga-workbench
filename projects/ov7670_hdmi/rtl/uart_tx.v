// ============================================================================
// UART 送信 (8N1)
//   valid=1 かつ ready=1 のサイクルで data を受け付ける
// ============================================================================
module uart_tx #(
    parameter integer CLK_HZ = 63_000_000,
    parameter integer BAUD   = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       valid,
    input  wire [7:0] data,
    output wire       ready,
    output reg        tx
);
    localparam integer DIV   = CLK_HZ / BAUD;
    localparam integer DIV_MI = DIV - 1;
    localparam [15:0]  DIV_M  = DIV_MI[15:0];

    reg [15:0] cnt;
    reg [3:0]  bitn;          // 0: アイドル, 1..10: スタート/データ/ストップ
    reg [8:0]  sh;

    assign ready = (bitn == 4'd0);

    always @(posedge clk) begin
        if (rst) begin
            cnt <= 16'd0; bitn <= 4'd0; sh <= 9'h1FF; tx <= 1'b1;
        end else if (bitn == 4'd0) begin
            tx <= 1'b1;
            if (valid) begin
                sh   <= {data, 1'b0};        // LSB 側から: スタート, D0..D7
                bitn <= 4'd1;
                cnt  <= 16'd0;
            end
        end else begin
            tx <= sh[0];
            if (cnt == DIV_M) begin
                cnt  <= 16'd0;
                sh   <= {1'b1, sh[8:1]};     // 最後はストップビット (1)
                bitn <= (bitn == 4'd10) ? 4'd0 : bitn + 1'b1;
            end else begin
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule
