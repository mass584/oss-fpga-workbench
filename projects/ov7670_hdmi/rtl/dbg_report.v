// ============================================================================
// デバッグ出力: 一定周期で 1 行のテキストを UART に送る
//   テンプレート文字列 TPL の '#' を、nib の 16 進数字で左から順に置き換え、
//   最後に CR LF を付ける。nib は行の先頭でまとめてラッチする (1 行の中で値が揃う)。
//   NN は TPL 中の '#' の個数と一致させること。
// ============================================================================
module dbg_report #(
    parameter integer CLK_HZ = 63_000_000,
    parameter integer PERIOD = 63_000_000,     // 送信周期 (クロック数)
    parameter integer LEN    = 4,              // TPL の文字数
    parameter integer NN     = 2,              // '#' の個数
    parameter [8*LEN-1:0] TPL = "X=##"
)(
    input  wire          clk,
    input  wire          rst,
    input  wire [4*NN-1:0] nib,
    output wire          tx
);
    localparam [31:0] PERIOD_M = PERIOD - 1;
    localparam integer CW      = $clog2(LEN + 2);       // 文字番号 (CR LF を含む) のビット幅
    localparam integer LEN_I   = LEN;
    localparam [CW-1:0] LENC   = LEN_I[CW-1:0];

    reg [31:0]     tmr;
    reg [4*NN-1:0] snap;
    reg            sending, v;
    reg [CW-1:0]   ci;
    reg [7:0]      data;
    wire           ready;

    uart_tx #(.CLK_HZ(CLK_HZ)) u_tx (
        .clk(clk), .rst(rst), .valid(v), .data(data), .ready(ready), .tx(tx)
    );

    // テンプレートは左から番号付けした配列にして 1 段レジスタを挟んで読む。
    // 値は snap を 4bit ずつ左へシフトして先頭から取り出す (大きなマルチプレクサを避ける)
    wire [7:0] tpl_c [0:LEN-1];
    genvar j;
    generate
        for (j = 0; j < LEN; j = j + 1) begin : g_tpl
            assign tpl_c[j] = TPL[8 * (LEN - 1 - j) +: 8];
        end
    endgenerate
    reg  [7:0] tch;
    reg        prep;            // tch が ci の文字になっている
    wire [3:0] hv  = snap[4*NN-1 -: 4];
    wire [7:0] hch = (hv < 4'd10) ? 8'h30 + {4'd0, hv} : 8'h37 + {4'd0, hv};   // '0'-'9', 'A'-'F'

    always @(posedge clk) begin
        v <= 1'b0;
        if (rst) begin
            tmr <= 32'd0; snap <= 0; sending <= 1'b0; ci <= 0; data <= 8'd0;
            tch <= 8'd0; prep <= 1'b0;
        end else begin
            tmr <= (tmr == PERIOD_M) ? 32'd0 : tmr + 1'b1;
            if (tmr == PERIOD_M && !sending) begin
                snap <= nib; sending <= 1'b1; ci <= 0; prep <= 1'b0;
            end
            if (sending && ready && !v) begin
                if (!prep) begin
                    tch  <= tpl_c[ci];
                    prep <= 1'b1;
                end else begin
                    prep <= 1'b0;
                    v    <= 1'b1;
                    if (ci < LENC) begin
                        if (tch == "#") begin data <= hch; snap <= {snap[4*NN-5:0], 4'd0}; end
                        else            data <= tch;
                    end else begin
                        data <= (ci == LENC) ? 8'h0D : 8'h0A;   // CR LF
                    end
                    ci <= ci + 1'b1;
                    if (ci == LENC + 1'b1) sending <= 1'b0;
                end
            end
        end
    end
endmodule
