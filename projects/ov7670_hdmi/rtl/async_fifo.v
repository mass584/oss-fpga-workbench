// ============================================================================
// 非同期 FIFO (グレイコードポインタ, First-Word-Fall-Through)
//   - 書き込み側: full のとき wr_en は無視される (呼び出し側で取りこぼしを検出する)
//   - 読み出し側: valid=1 の間 dout が先頭データ。rd_en で 1 つ進める
//     rcount = 読み出せる個数 (dout 上の 1 個を含む)。書き込み側から見て保守的な値
//   - メモリはデュアルクロック BSRAM に推論される (DW x 2^AW)
//   - リセットは持たない (FPGA の初期値で空から始まる)
// ============================================================================
module async_fifo #(
    parameter DW = 33,
    parameter AW = 9
)(
    input  wire          wclk,
    input  wire          wr_en,
    input  wire [DW-1:0] din,
    output wire          full,

    input  wire          rclk,
    input  wire          rd_en,
    output reg  [DW-1:0] dout,
    output reg           valid,
    output wire [AW+1:0] rcount
);
    reg [DW-1:0] mem [0:(1<<AW)-1];

    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction
    function [AW:0] gray2bin(input [AW:0] g);
        integer k;
        begin
            gray2bin[AW] = g[AW];
            for (k = AW - 1; k >= 0; k = k - 1) gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction

    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] rgray_w1, rgray_w2;     // rgray -> wclk
    reg [AW:0] wgray_r1, wgray_r2;     // wgray -> rclk
    initial begin
        wbin = 0; wgray = 0; rbin = 0; rgray = 0;
        rgray_w1 = 0; rgray_w2 = 0; wgray_r1 = 0; wgray_r2 = 0;
        dout = 0; valid = 1'b0;
    end

    // ---- 書き込み側 ----
    wire [AW:0] wbin_n = wbin + 1'b1;
    assign full = (wgray == {~rgray_w2[AW:AW-1], rgray_w2[AW-2:0]});

    always @(posedge wclk) begin
        rgray_w1 <= rgray;
        rgray_w2 <= rgray_w1;
        if (wr_en && !full) begin
            mem[wbin[AW-1:0]] <= din;
            wbin  <= wbin_n;
            wgray <= bin2gray(wbin_n);
        end
    end

    // ---- 読み出し側 ----
    wire        empty  = (rgray == wgray_r2);
    wire        load   = !empty && (!valid || rd_en);
    wire [AW:0] rbin_n = rbin + 1'b1;

    always @(posedge rclk) begin
        wgray_r1 <= wgray;
        wgray_r2 <= wgray_r1;
        if (load) begin
            dout  <= mem[rbin[AW-1:0]];
            rbin  <= rbin_n;
            rgray <= bin2gray(rbin_n);
        end
        if (load)       valid <= 1'b1;
        else if (rd_en) valid <= 1'b0;
    end

    wire [AW:0] in_mem = gray2bin(wgray_r2) - rbin;
    assign rcount = {1'b0, in_mem} + {{(AW+1){1'b0}}, valid};
endmodule
