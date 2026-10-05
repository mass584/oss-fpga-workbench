// ============================================================================
// BME280 の I2C スレーブの振る舞いモデル (シミュレーション用)
//   regs[] をレジスタイメージとして読み出しに答え、書き込みは regs[] に入れて wlog に記録する。
//   ADDR に一致しないアドレスには ACK を返さない。SDA はオープンドレイン (Low に引くだけ)
// ============================================================================
`timescale 1ps / 1ps
module bme280_model #(
    parameter [6:0] ADDR = 7'h76
)(
    input  wire scl,
    inout  wire sda
);
    reg sda_low = 1'b0;
    assign sda = sda_low ? 1'b0 : 1'bz;

    reg [7:0] regs [0:255];
    reg [7:0] wlog_reg [0:15];
    reg [7:0] wlog_val [0:15];
    integer   n_wr = 0, n_rd_bytes = 0, n_start = 0;

    localparam [1:0] IDLE = 2'd0, RX = 2'd1, TX = 2'd2;
    reg [1:0] st = IDLE;
    reg       is_addr = 1'b0;     // RX で受けているのがアドレスバイト
    reg       need_ptr = 1'b0;    // 書き込みの最初のデータバイトはレジスタ番号
    reg       rw = 1'b0;
    reg [3:0] bitc = 4'd0;
    reg [7:0] sh = 8'd0, tx = 8'd0, ptr = 8'd0;
    reg       mack = 1'b0;

    // START / 繰り返し START (SCL High 中の SDA 立ち下がり) / STOP (同 立ち上がり)
    always @(negedge sda) if (scl === 1'b1) begin
        st = RX; is_addr = 1'b1; bitc = 4'd0; sda_low = 1'b0; n_start = n_start + 1;
    end
    always @(posedge sda) if (scl === 1'b1) begin
        st = IDLE; sda_low = 1'b0;
    end

    always @(posedge scl) begin
        case (st)
            RX: if (bitc < 4'd8) begin sh = {sh[6:0], (sda === 1'b0) ? 1'b0 : 1'b1}; bitc = bitc + 4'd1; end
            TX: if (bitc < 4'd8) bitc = bitc + 4'd1;
                else if (bitc == 4'd8) begin mack = (sda === 1'b0); bitc = 4'd9; end
            default: ;
        endcase
    end

    always @(negedge scl) begin
        case (st)
            RX: if (bitc == 4'd8) begin                   // 8 ビット受けた: ACK を返すか決める
                    if (is_addr) begin
                        if (sh[7:1] == ADDR) begin sda_low = 1'b1; rw = sh[0]; need_ptr = !sh[0]; bitc = 4'd9; end
                        else st = IDLE;
                    end else begin
                        sda_low = 1'b1; bitc = 4'd9;
                        if (need_ptr) begin ptr = sh; need_ptr = 1'b0; end
                        else begin
                            regs[ptr] = sh;
                            if (n_wr < 16) begin wlog_reg[n_wr] = ptr; wlog_val[n_wr] = sh; end
                            n_wr = n_wr + 1; ptr = ptr + 8'd1;
                        end
                    end
                end else if (bitc == 4'd9) begin          // ACK のクロックが終わった
                    sda_low = 1'b0; bitc = 4'd0;
                    if (is_addr && rw) begin
                        st = TX; tx = regs[ptr]; ptr = ptr + 8'd1; n_rd_bytes = n_rd_bytes + 1;
                        sda_low = !tx[7];
                    end
                    is_addr = 1'b0;
                end
            TX: if (bitc < 4'd8) sda_low = !tx[7 - bitc];
                else if (bitc == 4'd8) sda_low = 1'b0;    // マスタの ACK を待つ
                else begin                                // ACK のクロックが終わった
                    if (mack) begin
                        tx = regs[ptr]; ptr = ptr + 8'd1; n_rd_bytes = n_rd_bytes + 1;
                        bitc = 4'd0; sda_low = !tx[7];
                    end else begin
                        st = IDLE; sda_low = 1'b0;
                    end
                end
            default: ;
        endcase
    end
endmodule
