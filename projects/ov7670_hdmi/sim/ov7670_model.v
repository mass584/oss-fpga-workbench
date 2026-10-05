// ============================================================================
// OV7670 (FIFO なし) 出力の疑似モデル: VGA RGB565 の既知パターンを流す
//   - PCLK 立ち下がりで VSYNC/HREF/D を変化させる (FPGA は立ち上がりでサンプル)
//   - HREF=1 の間 [上位バイト][下位バイト] の順で 1 画素
//   - 画素値 = cam_pat(x, y, frame_id)。frame_id はフレームごとに +1 (mod 16)
//   - TRUNC_FRAME 番目のフレームは TRUNC_LINES ラインで打ち切る (同期崩れの再現)
// ============================================================================
`timescale 1ps / 1ps
module ov7670_model #(
    parameter integer PCLK_PS     = 40000,
    parameter integer H_BLANK     = 288,     // HREF=0 の PCLK 数
    parameter integer VS_LINES    = 3,
    parameter integer VBP_LINES   = 17,
    parameter integer VFP_LINES   = 10,
    parameter integer ACT_W       = 640,
    parameter integer ACT_H       = 480,
    parameter integer TRUNC_FRAME = -1,
    parameter integer TRUNC_LINES = 100
)(
    output reg       pclk  = 1'b0,
    output reg       vsync = 1'b0,
    output reg       href  = 1'b0,
    output reg [7:0] d     = 8'h00,
    output reg [3:0] frame_id = 4'd0,
    output integer   frames_sent
);
    `include "cam_pattern.vh"

    initial frames_sent = 0;
    always #(PCLK_PS / 2) pclk = ~pclk;

    task automatic idle(input integer n);
        integer k;
        for (k = 0; k < n; k = k + 1) @(negedge pclk);
    endtask

    integer line_len, x, y, nlines, f;
    reg [15:0] px;
    initial begin
        line_len = 2 * ACT_W + H_BLANK;
        idle(100);
        for (f = 0; ; f = f + 1) begin
            // VSYNC
            @(negedge pclk) vsync = 1'b1;
            idle(VS_LINES * line_len);
            @(negedge pclk) vsync = 1'b0;
            idle(VBP_LINES * line_len);
            nlines = (f == TRUNC_FRAME) ? TRUNC_LINES : ACT_H;
            for (y = 0; y < nlines; y = y + 1) begin
                for (x = 0; x < ACT_W; x = x + 1) begin
                    px = cam_pat(x[9:0], y[8:0], frame_id);
                    @(negedge pclk) begin href = 1'b1; d = px[15:8]; end
                    @(negedge pclk) d = px[7:0];
                end
                @(negedge pclk) begin href = 1'b0; d = 8'h00; end
                idle(H_BLANK - 1);
            end
            idle(VFP_LINES * line_len);
            frame_id    = frame_id + 1'b1;
            frames_sent = frames_sent + 1;
        end
    end
endmodule
