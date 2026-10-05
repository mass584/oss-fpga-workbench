// ============================================================================
// OV7670 ストリーム取り込み (VGA RGB565, 2byte/pixel)
//   PCLK 立ち上がりでサンプル。HREF=1 の間 [R5 G3][G3 B5] の順で来る
//   DECIMATE=1 (Phase 1): 横・縦とも4画素に1つを採用して 160x120 としてバッファへ書く
//                         waddr = (y/4)*160 + x/4  (AW=15)
//   DECIMATE=0 (Phase 2): 640x480 全画素を出力する。waddr = y*640 + x (AW=19)
//   sof は「フレームの最初に出力する画素」に we と同時に立つ (VSYNC 後の最初の画素)
//   DECIMATE=0 では、640 画素に足りないラインは HREF 終了後に残りを 0 で埋める
//   ce: PCLK 立ち上がり相当のサイクルだけ 1 (Phase 1 は PCLK で動かして ce=1 固定、
//       Phase 2 はシステムクロックでオーバーサンプルして cam_sync の ce を入れる)。
//       出力 (we/sof/wdata など) は次の ce まで保持される
// ============================================================================
module cam_capture #(
    parameter DECIMATE = 1,
    parameter AW       = 15
)(
    input  wire          pclk,
    input  wire          ce,
    input  wire          vsync,
    input  wire          href,
    input  wire [7:0]    d,
    output reg           we,
    output reg  [AW-1:0] waddr,
    output reg  [15:0]   wdata,
    output reg           sof,
    output reg           frame_toggle
);
    // 入力を一段叩いてタイミングを揃える (IOB レジスタに入る)
    reg       vsync_r, vsync_r2, href_r, href_r2;
    reg [7:0] d_r;
    reg [9:0] x;          // 0..639
    reg [8:0] y;          // 0..479
    reg       phase;      // 0:上位バイト待ち 1:下位バイト待ち
    reg [7:0] hi;
    reg       first;      // フレーム内でまだ 1 画素も出していない

    // PCLK ドメインにはリセットが無いので、FPGA の初期値で起動する
    initial begin
        we = 1'b0; waddr = 0; wdata = 0; sof = 1'b0; frame_toggle = 1'b0;
        vsync_r = 0; vsync_r2 = 0; href_r = 0; href_r2 = 0; d_r = 0;
        x = 0; y = 0; phase = 0; hi = 0; first = 1'b1;
    end

    localparam    LINE_PAD = (DECIMATE == 0);    // Phase 2 だけ、短いラインを埋める
    wire          in_frame = (x < 10'd640) && (y < 9'd480);
    wire          take;
    wire [AW-1:0] addr;

    // 書き込みアドレス (定数乗算はシフト加算で書く)
    generate
        if (DECIMATE) begin : g_dec
            wire [14:0] a = {y[8:2], 7'b0} + {2'b0, y[8:2], 5'b0} + {7'b0, x[9:2]}; // (y/4)*160 + x/4
            assign addr = a[AW-1:0];
            assign take = (x[1:0] == 2'd0) && (y[1:0] == 2'd0) && in_frame;
        end else begin : g_full
            wire [18:0] a = {y, 9'b0} + {2'b0, y, 7'b0} + {9'b0, x};                // y*640 + x
            assign addr = a[AW-1:0];
            assign take = in_frame;
        end
    endgenerate

    always @(posedge pclk) if (ce) begin
        vsync_r <= vsync; vsync_r2 <= vsync_r;
        href_r  <= href;  href_r2  <= href_r;
        d_r     <= d;
        we      <= 1'b0;
        sof     <= 1'b0;

        if (vsync_r & ~vsync_r2) frame_toggle <= ~frame_toggle;

        if (vsync_r) begin                 // 垂直ブランク: フレーム先頭に戻す
            x <= 0; y <= 0; phase <= 0; first <= 1'b1;
        end else if (href_r) begin
            if (!phase) begin
                hi    <= d_r;
                phase <= 1'b1;
            end else begin
                phase <= 1'b0;
                x     <= x + 1'b1;
                if (take) begin
                    we    <= 1'b1;
                    sof   <= first;
                    first <= 1'b0;
                    wdata <= {hi, d_r};
                    waddr <= addr;
                end
            end
        end else if (LINE_PAD && x != 10'd0 && x < 10'd640 && y < 9'd480) begin
            // HREF が終わったのに 640 画素に足りない (PCLK の取りこぼし): 残りを 0 で埋めて
            // 1 ラインの画素数をそろえる。取りこぼしの影響がそのラインだけで済み、
            // フレームの総画素数がずれて丸ごと捨てられるのを防ぐ (ライン間の空白で行う)
            phase <= 1'b0;
            x     <= x + 1'b1;
            we    <= 1'b1;
            sof   <= first;
            first <= 1'b0;
            wdata <= 16'h0000;
            waddr <= addr;
        end else begin
            phase <= 1'b0;
            x     <= 0;
            if (LINE_PAD ? (x != 10'd0) : href_r2) y <= y + 1'b1;    // ライン終了で次のライン
        end
    end
endmodule
