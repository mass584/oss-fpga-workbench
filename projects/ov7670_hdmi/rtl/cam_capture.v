// ============================================================================
// OV7670 ストリーム取り込み (VGA, 2byte/pixel: RGB565 または YUV422)
//   PCLK 立ち上がりでサンプル。HREF=1 の間 2 バイトで 1 画素 ({先, 後} を wdata に)
//   640x480 全画素を出力する。waddr = y*640 + x (PSRAM への書き込みは sof で頭出しして順に書くので
//   上位では使わない。単体テストで並び順を確かめるために出している)
//   sof は「フレームの最初に出力する画素」に we と同時に立つ (VSYNC 後の最初の画素)
//   640 画素に足りないラインは HREF 終了後に残りを 0 で埋める
//   ce: PCLK 立ち上がり相当のサイクルだけ 1 (cam_sync がシステムクロックでオーバーサンプルして作る)。
//       出力 (we/sof/wdata など) は次の ce まで保持される
// ============================================================================
module cam_capture #(
    parameter AW = 19
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
    reg       vsync_r, vsync_r2, href_r;
    reg [7:0] d_r;
    reg [9:0] x;          // 0..639
    reg [8:0] y;          // 0..479
    reg       phase;      // 0:上位バイト待ち 1:下位バイト待ち
    reg [7:0] hi;
    reg       first;      // フレーム内でまだ 1 画素も出していない

    // PCLK ドメインにはリセットが無いので、FPGA の初期値で起動する
    initial begin
        we = 1'b0; waddr = 0; wdata = 0; sof = 1'b0; frame_toggle = 1'b0;
        vsync_r = 0; vsync_r2 = 0; href_r = 0; d_r = 0;
        x = 0; y = 0; phase = 0; hi = 0; first = 1'b1;
    end

    wire          take = (x < 10'd640) && (y < 9'd480);
    // 書き込みアドレス y*640 + x (定数乗算はシフト加算で書く)
    wire [18:0]   addr_f = {y, 9'b0} + {2'b0, y, 7'b0} + {9'b0, x};
    wire [AW-1:0] addr   = addr_f[AW-1:0];

    always @(posedge pclk) if (ce) begin
        vsync_r <= vsync; vsync_r2 <= vsync_r;
        href_r  <= href;
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
        end else if (x != 10'd0 && x < 10'd640 && y < 9'd480) begin
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
            if (x != 10'd0) y <= y + 1'b1;    // ライン終了で次のライン
        end
    end
endmodule
