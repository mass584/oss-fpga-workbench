// ============================================================================
// DVI 送信部: TMDS エンコード x3 + OSER10(10:1 シリアライザ) + ELVDS 出力
//   ch0=Blue(同期信号を載せる), ch1=Green, ch2=Red, clk=1111100000
// ============================================================================
module dvi_tx (
    input  wire       clk_pix,   // 25.2MHz
    input  wire       clk_ser,   // 126MHz (DDR で 10bit/画素)
    input  wire       rst,
    input  wire [7:0] r, g, b,
    input  wire       de, hs, vs,
    output wire       tmds_clk_p, tmds_clk_n,
    output wire [2:0] tmds_d_p, tmds_d_n
);
    wire [9:0] q [0:3];

    tmds_encoder enc_b (.clk(clk_pix), .rst(rst), .d(b), .c({vs, hs}), .de(de), .q(q[0]));
    tmds_encoder enc_g (.clk(clk_pix), .rst(rst), .d(g), .c(2'b00),    .de(de), .q(q[1]));
    tmds_encoder enc_r (.clk(clk_pix), .rst(rst), .d(r), .c(2'b00),    .de(de), .q(q[2]));
    assign q[3] = 10'b1111100000;

    wire [3:0] ser;
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_ser
            OSER10 #(.GSREN("false"), .LSREN("true")) u_oser (
                .Q(ser[k]),
                .D0(q[k][0]), .D1(q[k][1]), .D2(q[k][2]), .D3(q[k][3]), .D4(q[k][4]),
                .D5(q[k][5]), .D6(q[k][6]), .D7(q[k][7]), .D8(q[k][8]), .D9(q[k][9]),
                .PCLK(clk_pix), .FCLK(clk_ser), .RESET(rst)
            );
        end
    endgenerate

    ELVDS_OBUF u_obuf0 (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
    ELVDS_OBUF u_obuf1 (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
    ELVDS_OBUF u_obuf2 (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));
    ELVDS_OBUF u_obufc (.I(ser[3]), .O(tmds_clk_p),  .OB(tmds_clk_n));
endmodule
