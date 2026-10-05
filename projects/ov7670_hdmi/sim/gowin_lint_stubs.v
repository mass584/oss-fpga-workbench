// ============================================================================
// Gowin プリミティブのブラックボックス宣言 (Verilator lint 専用)
//   ポート宣言だけを持つ。合成 (Yosys は自前のセル定義を使う) と
//   シミュレーション (gowin_sim_models.v) では使わない。
// ============================================================================
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */
/* verilator lint_off DECLFILENAME */
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
    output CLKOUT, output LOCK, output CLKOUTP, output CLKOUTD, output CLKOUTD3,
    input RESET, input RESET_P, input CLKIN, input CLKFB,
    input [5:0] FBDSEL, input [5:0] IDSEL, input [5:0] ODSEL,
    input [3:0] PSDA, input [3:0] DUTYDA, input [3:0] FDLY
);
endmodule

module CLKDIV #(parameter DIV_MODE = "2", parameter GSREN = "false") (
    input HCLKIN, input RESETN, input CALIB, output CLKOUT
);
endmodule

module OSER10 #(parameter GSREN = "false", parameter LSREN = "true") (
    output Q,
    input D0, input D1, input D2, input D3, input D4,
    input D5, input D6, input D7, input D8, input D9,
    input PCLK, input FCLK, input RESET
);
endmodule

module ELVDS_OBUF (input I, output O, output OB);
endmodule

module ODDR #(parameter TXCLK_POL = 0, parameter INIT = 0) (
    output Q0, output Q1, input D0, input D1, input TX, input CLK
);
endmodule

module IDDR #(parameter Q0_INIT = 1'b0, parameter Q1_INIT = 1'b0) (
    output Q0, output Q1, input D, input CLK
);
endmodule

module IOBUF (output O, inout IO, input I, input OEN);
endmodule

module DQCE (input CLKIN, input CE, output CLKOUT);
endmodule
/* verilator lint_on DECLFILENAME */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
