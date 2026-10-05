// ============================================================================
// PCLK の High/Low の長さの分布 (デバッグ用)
//   半サイクルごとのサンプル列 (1 クロックに 2 サンプル) から、High と Low がそれぞれ
//   何サンプル続いたかを 1, 2, 3 以上に分けて WINDOW クロックの窓で数える。
// ============================================================================
module cam_runlen #(
    parameter integer WINDOW = 45_000_000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [1:0]  pair,          // {先, 後}
    output reg  [71:0] hist           // {H1, H2, H3+, L1, L2, L3+} 各 12bit (飽和)
);
    localparam [31:0] WIN_M = WINDOW - 1;
    reg        lvl;
    reg [1:0]  run;                   // 現在の連続長 (3 で飽和)
    reg [11:0] c0, c1, c2, c3, c4, c5;
    reg [31:0] tmr;

    // 2 サンプル分の遷移を組み合わせ回路で求める
    reg        lvl_a, lvl_b;
    reg [1:0]  run_a, run_b;
    reg        end_a, end_b;          // そのサンプルで連続が終わった
    reg        elv_a, elv_b;          // 終わった連続の値
    reg [1:0]  erun_a, erun_b;        // 終わった連続の長さ
    always @* begin
        // 1 サンプル目 (先)
        end_a = (pair[1] != lvl); elv_a = lvl; erun_a = run;
        lvl_a = pair[1];
        run_a = end_a ? 2'd1 : (run == 2'd3 ? 2'd3 : run + 2'd1);
        // 2 サンプル目 (後)
        end_b = (pair[0] != lvl_a); elv_b = lvl_a; erun_b = run_a;
        lvl_b = pair[0];
        run_b = end_b ? 2'd1 : (run_a == 2'd3 ? 2'd3 : run_a + 2'd1);
    end

    function [11:0] inc(input [11:0] v, input e1, input e2);
        reg [1:0] n;
        begin
            n   = {1'b0, e1} + {1'b0, e2};
            inc = (v > 12'hFFD) ? 12'hFFF : v + {10'd0, n};
        end
    endfunction
    // 終わった連続がどの区分か
    wire [5:0] sel_a = !end_a ? 6'd0 : {elv_a && erun_a == 2'd1, elv_a && erun_a == 2'd2, elv_a && erun_a == 2'd3,
                                        !elv_a && erun_a == 2'd1, !elv_a && erun_a == 2'd2, !elv_a && erun_a == 2'd3};
    wire [5:0] sel_b = !end_b ? 6'd0 : {elv_b && erun_b == 2'd1, elv_b && erun_b == 2'd2, elv_b && erun_b == 2'd3,
                                        !elv_b && erun_b == 2'd1, !elv_b && erun_b == 2'd2, !elv_b && erun_b == 2'd3};

    always @(posedge clk) begin
        if (rst) begin
            lvl <= 1'b0; run <= 2'd1; tmr <= 32'd0; hist <= 72'd0;
            c0 <= 12'd0; c1 <= 12'd0; c2 <= 12'd0; c3 <= 12'd0; c4 <= 12'd0; c5 <= 12'd0;
        end else begin
            lvl <= lvl_b; run <= run_b;
            if (tmr == WIN_M) begin
                tmr  <= 32'd0;
                hist <= {c0, c1, c2, c3, c4, c5};
                c0 <= 12'd0; c1 <= 12'd0; c2 <= 12'd0; c3 <= 12'd0; c4 <= 12'd0; c5 <= 12'd0;
            end else begin
                tmr <= tmr + 1'b1;
                c0 <= inc(c0, sel_a[5], sel_b[5]);
                c1 <= inc(c1, sel_a[4], sel_b[4]);
                c2 <= inc(c2, sel_a[3], sel_b[3]);
                c3 <= inc(c3, sel_a[2], sel_b[2]);
                c4 <= inc(c4, sel_a[1], sel_b[1]);
                c5 <= inc(c5, sel_a[0], sel_b[0]);
            end
        end
    end
endmodule
