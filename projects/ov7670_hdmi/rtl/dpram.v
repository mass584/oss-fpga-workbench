// ============================================================================
// シンプルデュアルポート RAM (書き込み/読み出しで別クロック, 読み出しレイテンシ 1)
//   BSRAM (SDPB) に推論される想定
// ============================================================================
module dpram #(
    parameter DW = 32,
    parameter AW = 10
)(
    input  wire          wclk,
    input  wire          we,
    input  wire [AW-1:0] waddr,
    input  wire [DW-1:0] wdata,
    input  wire          rclk,
    input  wire [AW-1:0] raddr,
    output reg  [DW-1:0] rdata
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always @(posedge rclk)
        rdata <= mem[raddr];
endmodule
