// ============================================================================
// ボタンのチャタリング除去 (負論理のボタン)
//   2FF で同期し、同じ値が 2^CW クロック続いたら確定する (45MHz, CW=20 で約 23ms)。
//   押した (High -> Low が確定した) クロックで press を 1 クロック立てる
// ============================================================================
module btn_debounce #(
    parameter integer CW = 20
)(
    input  wire clk,
    input  wire btn_n,            // 非同期 (ピン)
    output reg  press
);
    wire          s;
    cdc_sync #(.W(1)) u_sync (.clk(clk), .d(btn_n), .q(s));
    reg  [CW-1:0] cnt;
    reg           st;             // 確定した値 (1 = 離している)
    initial begin cnt = 0; st = 1'b1; press = 1'b0; end
    always @(posedge clk) begin
        press <= 1'b0;
        if (s == st) begin
            cnt <= {CW{1'b0}};
        end else if (&cnt) begin
            cnt   <= {CW{1'b0}};
            st    <= s;
            press <= !s;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end
endmodule
