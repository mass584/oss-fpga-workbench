// ============================================================================
// フレームバッファ 160x120 x 16bit (シンプルデュアルポート, 読み書き別クロック)
//   GowinSynthesis で BSRAM に推論される想定。
//   リソースレポートで BSRAM ≒19〜20 個になっているか確認すること。
//   推論がうまくいかない場合は IP Generator の SDPB (19200x16) に置き換える。
// ============================================================================
module framebuf (
    input  wire        wclk,
    input  wire        we,
    input  wire [14:0] waddr,
    input  wire [15:0] wdata,
    input  wire        rclk,
    input  wire [14:0] raddr,
    output reg  [15:0] rdata
);
    localparam DEPTH = 160 * 120;
    reg [15:0] mem [0:DEPTH-1];

    always @(posedge wclk)
        if (we) mem[waddr] <= wdata;

    always @(posedge rclk)
        rdata <= mem[raddr];
endmodule
