// ============================================================================
// クロックとリセット (Tang Nano 9K, 27MHz 水晶)
//   clk_ser  126MHz   TMDS のシリアライザ (画素の 5 倍)
//   clk_pix  25.2MHz  画素 (640x480@60Hz)。clk_ser を CLKDIV で 1/5
//   clk_mem  45MHz    PSRAM / カメラ取り込み / BME280
//   clk_mem_p         clk_mem の 90° 遅れ (PSRAM の CK を作る ODDR 用)
//   リセットはボタン (負論理) と PLL ロックからそれぞれのクロックに同期して作る (4 段)
// ============================================================================
/* verilator lint_off PINCONNECTEMPTY */   // ベンダプリミティブの未使用出力
module clocks (
    input  wire clk27,
    input  wire btn_rst_n,
    output wire clk_ser,
    output wire clk_pix,
    output wire clk_mem,
    output wire clk_mem_p,
    output wire locked,           // PLL が 2 個ともロック
    output wire rst_pix,
    output wire rst_mem
);
    // ---- 27MHz -> 126MHz (TMDS 5 倍) -> /5 -> 25.2MHz (画素)
    wire pll_lock;
    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),    // /3
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(13), // x14 -> 126MHz
        .DYN_ODIV_SEL("false"), .ODIV_SEL(4),    // VCO = 504MHz
        .PSDA_SEL("0000"), .DYN_DA_EN("true"), .DUTYDA_SEL("1000"),
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) u_pll (
        .CLKOUT(clk_ser), .LOCK(pll_lock), .CLKOUTP(), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    CLKDIV #(.DIV_MODE("5"), .GSREN("false")) u_clkdiv (
        .HCLKIN(clk_ser), .RESETN(pll_lock), .CALIB(1'b0), .CLKOUT(clk_pix)
    );

    // ---- 27MHz -> 45MHz (CLKOUT) / 45MHz 90° 遅れ (CLKOUTP)
    //   実機 (OSS フロー) で 63MHz では PSRAM の読み出しが不安定だったので下げている。
    //   帯域: 1 ラインの読み出し 10 バースト ≒ 630 クロック = 14µs (ライン表示時間 31.7µs)
    wire pll2_lock;
    rPLL #(
        .FCLKIN("27"),
        .DYN_IDIV_SEL("false"), .IDIV_SEL(2),    // /3
        .DYN_FBDIV_SEL("false"), .FBDIV_SEL(4),  // x5 -> 45MHz
        .DYN_ODIV_SEL("false"), .ODIV_SEL(16),   // VCO = 720MHz
        .PSDA_SEL("0100"), .DYN_DA_EN("false"), .DUTYDA_SEL("1000"),   // CLKOUTP = 90°
        .CLKOUT_FT_DIR(1'b1), .CLKOUTP_FT_DIR(1'b1),
        .CLKOUT_DLY_STEP(0), .CLKOUTP_DLY_STEP(0),
        .CLKFB_SEL("internal"),
        .CLKOUT_BYPASS("false"), .CLKOUTP_BYPASS("false"), .CLKOUTD_BYPASS("false"),
        .DYN_SDIV_SEL(2), .CLKOUTD_SRC("CLKOUT"), .CLKOUTD3_SRC("CLKOUT"),
        .DEVICE("GW1NR-9C")
    ) u_pll_mem (
        .CLKOUT(clk_mem), .LOCK(pll2_lock), .CLKOUTP(clk_mem_p), .CLKOUTD(), .CLKOUTD3(),
        .RESET(1'b0), .RESET_P(1'b0), .CLKIN(clk27), .CLKFB(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );

    assign locked = pll_lock & pll2_lock;

    // ---- リセット同期化
    reg [3:0] rst_pix_sr, rst_mem_sr;
    initial begin rst_pix_sr = 4'hF; rst_mem_sr = 4'hF; end
    always @(posedge clk_pix or negedge pll_lock)
        if (!pll_lock) rst_pix_sr <= 4'hF;
        else           rst_pix_sr <= {rst_pix_sr[2:0], ~btn_rst_n};
    always @(posedge clk_mem or negedge pll2_lock)
        if (!pll2_lock) rst_mem_sr <= 4'hF;
        else            rst_mem_sr <= {rst_mem_sr[2:0], ~btn_rst_n};
    assign rst_pix = rst_pix_sr[3];
    assign rst_mem = rst_mem_sr[3];
endmodule
/* verilator lint_on PINCONNECTEMPTY */
