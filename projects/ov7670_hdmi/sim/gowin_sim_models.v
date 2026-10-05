// ============================================================================
// Gowin プリミティブの振る舞いモデル (Icarus Verilog シミュレーション専用)
//   ベンダの暗号化モデルは使えないので、UG286/UG289 の記述に沿った最小限の動作を書く。
//   - rPLL  : CLKIN の周期を実測し、FBDIV/IDIV/ODIV と PSDA_SEL(22.5°刻み) から出力を生成
//   - CLKDIV: DIV_MODE 分周
//   - ODDR  : CLK 立ち上がりで D0/D1/TX を取り込み、その周期の前半 D0・後半 D1 を出力。
//             Q1 は TX を 1 周期遅らせたもの (IOBUF の OEN に繋ぐ)
//   - IDDR  : 立ち上がりと立ち下がりでサンプルし、次の立ち上がりで Q0(先=立ち上がり側),
//             Q1(後=立ち下がり側) を同時に出力
//   - DQCE  : グローバルクロックのゲート (CE=1 で素通し)
//   - OSER10: 10:1 シリアライザ (LSB first)。TMDS の往復検証は別テストで行うので簡易実装
// ============================================================================
`timescale 1ps / 1ps

module rPLL #(
    parameter FCLKIN = "100.0", parameter DEVICE = "GW1NR-9C",
    parameter DYN_IDIV_SEL = "false", parameter IDIV_SEL = 0,
    parameter DYN_FBDIV_SEL = "false", parameter FBDIV_SEL = 0,
    parameter DYN_ODIV_SEL = "false", parameter ODIV_SEL = 8,
    parameter PSDA_SEL = "0000", parameter DYN_DA_EN = "false", parameter DUTYDA_SEL = "1000",
    parameter CLKOUT_FT_DIR = 1'b1, parameter CLKOUTP_FT_DIR = 1'b1,
    parameter CLKOUT_DLY_STEP = 0, parameter CLKOUTP_DLY_STEP = 0,
    parameter CLKFB_SEL = "internal",
    parameter CLKOUT_BYPASS = "false", parameter CLKOUTP_BYPASS = "false", parameter CLKOUTD_BYPASS = "false",
    parameter DYN_SDIV_SEL = 2, parameter CLKOUTD_SRC = "CLKOUT", parameter CLKOUTD3_SRC = "CLKOUT"
) (
    output reg CLKOUT = 1'b0, output reg LOCK = 1'b0, output reg CLKOUTP = 1'b0,
    output CLKOUTD, output CLKOUTD3,
    input RESET, input RESET_P, input CLKIN, input CLKFB,
    input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL,
    input [3:0] PSDA, input [3:0] DUTYDA, input [3:0] FDLY
);
    assign CLKOUTD = 1'b0;
    assign CLKOUTD3 = 1'b0;

    // PSDA_SEL は 4bit 文字列 ("0100" = 4 * 22.5° = 90°)
    function integer bin4(input [8*4-1:0] s);
        integer k;
        begin
            bin4 = 0;
            for (k = 3; k >= 0; k = k - 1) bin4 = bin4 * 2 + (s[8*k +: 8] == "1");
        end
    endfunction

    realtime t_last = 0, t_in = 0, t_out = 0;
    integer  n_edges = 0;
    always @(posedge CLKIN) begin
        if (t_last != 0) t_in = $realtime - t_last;
        t_last = $realtime;
        n_edges = n_edges + 1;
    end

    initial begin
        wait (n_edges >= 4);
        t_out = t_in * (IDIV_SEL + 1) / (FBDIV_SEL + 1);
        fork
            forever begin #(t_out / 2) CLKOUT = ~CLKOUT; end
            begin
                #(t_out * bin4(PSDA_SEL) / 16);
                forever begin #(t_out / 2) CLKOUTP = ~CLKOUTP; end
            end
            begin #(t_out * 20) LOCK = 1'b1; end
        join
    end
endmodule

module CLKDIV #(parameter DIV_MODE = "2", parameter GSREN = "false") (
    input HCLKIN, input RESETN, input CALIB, output reg CLKOUT = 1'b0
);
    localparam integer N = (DIV_MODE == "5") ? 5 : (DIV_MODE == "4") ? 4 :
                           (DIV_MODE == "3.5") ? 4 : (DIV_MODE == "8") ? 8 : 2;
    // 奇数分周は両エッジで数えてデューティ 50% にする
    integer cnt = 0;
    always @(HCLKIN) begin
        if (!RESETN) begin
            cnt = 0; CLKOUT = 1'b0;
        end else begin
            cnt = cnt + 1;
            if (cnt == N) begin cnt = 0; CLKOUT = ~CLKOUT; end
        end
    end
endmodule

module OSER10 #(parameter GSREN = "false", parameter LSREN = "true") (
    output reg Q = 1'b0,
    input D0, input D1, input D2, input D3, input D4,
    input D5, input D6, input D7, input D8, input D9,
    input PCLK, input FCLK, input RESET
);
    reg [9:0] hold = 0, sh = 0;
    integer   k = 0;
    always @(posedge PCLK) hold <= {D9, D8, D7, D6, D5, D4, D3, D2, D1, D0};
    always @(FCLK) begin
        if (k == 0) sh = hold; else sh = sh >> 1;
        Q = sh[0];
        k = (k == 9) ? 0 : k + 1;
    end
endmodule

module ELVDS_OBUF (input I, output O, output OB);
    assign O  = I;
    assign OB = ~I;
endmodule

module ODDR #(parameter TXCLK_POL = 0, parameter INIT = 0) (
    output reg Q0 = INIT, output reg Q1 = 1'b1, input D0, input D1, input TX, input CLK
);
    // 出力はレジスタ (クロックと同時刻のグリッチを出さない)
    reg d1 = INIT;
    always @(posedge CLK) begin
        Q0 <= D0; d1 <= D1; Q1 <= TX;
    end
    always @(negedge CLK) Q0 <= d1;
endmodule

module IDDR #(parameter Q0_INIT = 1'b0, parameter Q1_INIT = 1'b0) (
    output reg Q0 = Q0_INIT, output reg Q1 = Q1_INIT, input D, input CLK
);
    reg s_r = 1'b0, s_f = 1'b0;
    always @(posedge CLK) begin
        Q0 <= s_r; Q1 <= s_f;
        s_r <= D;
    end
    always @(negedge CLK) s_f <= D;
endmodule

module IOBUF #(parameter integer OUT_DLY = 3000) (output O, inout IO, input I, input OEN);
    // 出力側に遅延を入れる (実機で DQ が CK より約 T/4 遅れて出ていたのを再現)
    assign #(OUT_DLY) IO = OEN ? 1'bz : I;
    assign O  = IO;
endmodule

module DQCE (input CLKIN, input CE, output CLKOUT);
    assign CLKOUT = CLKIN & CE;
endmodule
