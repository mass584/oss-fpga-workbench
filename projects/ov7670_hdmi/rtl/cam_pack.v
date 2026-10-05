// ============================================================================
// カメラ画素 -> 非同期 FIFO 書き込み (PCLK ドメイン)
//   - 2 画素 (偶数 x, 奇数 x) を 1 エントリ {sof, even[15:0], odd[15:0]} にまとめる
//     (PSRAM は 16bit DDR で 1 クロック 2 画素を転送するので、FIFO も 2 画素幅にする)
//   - sof はフレーム先頭エントリにだけ立つ
//   - フレーム終了 (VSYNC 立ち上がり = frame_toggle 変化) で、書いたエントリ数が
//     ALIGN の倍数になるまでダミー (sof=0, 0) を詰める。これで次フレームの SOF は
//     必ずバースト境界に来るので、メモリ側はバースト単位で SOF を扱える
//   - FIFO が満杯なら画素を捨てて ovf を立てる (そのフレームは短くなり、メモリ側で破棄される)
//   - ce: cam_capture と同じクロックイネーブル。fifo_wr は次の ce まで保持されるので、
//     FIFO の書き込みイネーブルには fifo_wr & ce を使うこと
// ============================================================================
module cam_pack #(
    parameter ALIGN_LOG2 = 5          // 32 エントリ = 1 バースト
)(
    input  wire        pclk,
    input  wire        ce,
    input  wire        we,
    input  wire [15:0] wdata,
    input  wire        sof,
    input  wire        frame_toggle,
    input  wire        fifo_full,
    output reg         fifo_wr,
    output reg  [32:0] fifo_din,
    output reg         ovf
);
    reg                  have_even, even_sof, ft_d, pad;
    reg [15:0]           even_px;
    reg [ALIGN_LOG2-1:0] cnt;          // 書き込んだエントリ数 mod ALIGN
    initial begin
        fifo_wr = 1'b0; fifo_din = 0; ovf = 1'b0;
        have_even = 1'b0; even_sof = 1'b0; ft_d = 1'b0; pad = 1'b0;
        even_px = 0; cnt = 0;
    end

    // 前サイクルに出した書き込みが受け付けられたか
    wire accepted = fifo_wr && !fifo_full;

    always @(posedge pclk) if (ce) begin
        ft_d <= frame_toggle;
        if (accepted) cnt <= cnt + 1'b1;
        if (fifo_wr && fifo_full && !pad) ovf <= 1'b1;

        // ダミーは受け付けられるまで出し続ける (画素データは取りこぼしたら捨てる)
        if (!(pad && fifo_wr && fifo_full)) fifo_wr <= 1'b0;

        if (frame_toggle != ft_d) begin
            // フレーム終了: 半端な偶数画素は捨て、境界までダミーを詰める
            have_even <= 1'b0;
            pad       <= 1'b1;
        end else if (we) begin
            if (!have_even || sof) begin
                have_even <= 1'b1;
                even_sof  <= sof;
                even_px   <= wdata;
            end else begin
                have_even <= 1'b0;
                fifo_wr   <= 1'b1;
                fifo_din  <= {even_sof, even_px, wdata};
            end
        end else if (pad && !fifo_wr) begin
            // 直前の書き込みは cnt に反映済み (fifo_wr=0 なので accepted=0)
            if (cnt == 0) begin
                pad <= 1'b0;
            end else begin
                fifo_wr  <= 1'b1;
                fifo_din <= 33'd0;
            end
        end
    end
endmodule
