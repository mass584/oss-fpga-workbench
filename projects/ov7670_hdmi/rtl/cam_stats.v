// ============================================================================
// カメラ信号の統計 (デバッグ用。PCLK 立ち上がりごとの ce で動く)
//   bpl : 直前のラインで HREF=1 だった PCLK 数 (RGB565 VGA なら 1280 = 0x500)
//   lpf : 直前のフレームのライン数 (480 = 0x1E0)
//   pdiv: ce を 16 回数えるごとに反転 (メモリクロック側で数えて取り込みが動いているかを見る)
//   出力はフレームごと/ラインごとに更新されるだけなので、読む側は多少の取りこぼしを許す
// ============================================================================
module cam_stats (
    input  wire        pclk,
    input  wire        ce,           // PCLK 立ち上がり相当 (cam_sync)
    input  wire        vsync,
    input  wire        href,
    output reg  [11:0] bpl,
    output reg  [11:0] lpf,
    output wire        pdiv
);
    reg        vs_r, vs_d, hr_r, hr_d;
    reg [11:0] bcnt, lcnt;
    reg [3:0]  div;
    initial begin
        vs_r = 0; vs_d = 0; hr_r = 0; hr_d = 0; bcnt = 0; lcnt = 0; div = 0; bpl = 0; lpf = 0;
    end
    assign pdiv = div[3];

    always @(posedge pclk) if (ce) begin
        vs_r <= vsync; vs_d <= vs_r;
        hr_r <= href;  hr_d <= hr_r;
        div  <= div + 1'b1;
        if (hr_r) bcnt <= bcnt + 1'b1;
        if (hr_d && !hr_r) begin                 // HREF 立ち下がり: 1 ライン終了
            bpl  <= bcnt;
            bcnt <= 12'd0;
            lcnt <= lcnt + 1'b1;
        end
        if (vs_r && !vs_d) begin                 // VSYNC 立ち上がり: 1 フレーム終了
            lpf  <= lcnt;
            lcnt <= 12'd0;
        end
    end
endmodule
