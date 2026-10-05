// ============================================================================
// psram_ctrl 単体テスト
//   CK->DQ 遅延 (tCKD) と CK 位相を変えた複数の構成を並行して走らせ、
//   (1) 書き込み gap の自動調整がモデルの値 (2*3-1=5) に収束する
//   (2) ランダムなアドレス/データのバースト書き込み -> 読み出しが一致する
//   (3) PSRAM モデルが違反 (tCSM, 行境界, 早すぎるアクセス) を検出しない
//   を確認する。
// ============================================================================
`timescale 1ps / 1ps
`default_nettype none

module tb_psram_one #(
    parameter integer CLK_PS   = 15873,   // 63MHz
    parameter integer PHASE_PS = 3968,    // CK の遅れ (90°)
    parameter integer TCKD     = 4000,
    parameter integer NBURST   = 24,
    parameter integer SEED     = 1,
    parameter integer CK_MODE  = 0,
    parameter integer BL       = 16
)(
    output reg done = 1'b0,
    output reg pass = 1'b0
);
    reg clk = 1'b0, clk_p = 1'b0, rst = 1'b1;
    always #(CLK_PS / 2) clk = ~clk;
    always @(clk) clk_p <= #(PHASE_PS) clk;

    wire        init_done, init_fail, ready, wd_take, rd_valid, xfer_done, rd_err;
    wire [3:0]  wr_gap;
    wire [31:0] rd_data;
    reg         req = 1'b0, req_we = 1'b0;
    reg  [20:0] req_addr = 0;
    reg  [31:0] wd = 0;

    wire [1:0]  ck, ck_n, cs_n, rst_n;
    wire [15:0] dq;
    wire [1:0]  rwds;

    psram_ctrl #(.CLK_HZ(63_000_000), .INIT_US(1), .CK_MODE(CK_MODE), .BL(BL)) dut (
        .clk(clk), .clk_p(clk_p), .rst(rst),
        .init_done(init_done), .init_fail(init_fail), .wr_gap(wr_gap),
        .ready(ready), .req(req), .req_we(req_we), .req_addr(req_addr),
        .wd_take(wd_take), .wd(wd), .rd_valid(rd_valid), .rd_data(rd_data),
        .xfer_done(xfer_done), .rd_err(rd_err),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n), .O_psram_reset_n(rst_n),
        .IO_psram_dq(dq), .IO_psram_rwds(rwds)
    );

    psram_model #(.TCKD(TCKD), .TVCS(500_000)) die0 (
        .ck(ck[0]), .ck_n(ck_n[0]), .cs_n(cs_n[0]), .reset_n(rst_n[0]), .dq(dq[7:0]),  .rwds(rwds[0]));
    psram_model #(.TCKD(TCKD), .TVCS(500_000)) die1 (
        .ck(ck[1]), .ck_n(ck_n[1]), .cs_n(cs_n[1]), .reset_n(rst_n[1]), .dq(dq[15:8]), .rwds(rwds[1]));

    // ---- テストデータ ----
    reg [31:0] data [0:NBURST*BL-1];
    reg [20:0] addrs [0:NBURST-1];
    integer    seed = SEED, i, b, widx, errs = 0, rd_cnt;

    // 書き込みデータ供給 (wd_take のサイクルで消費される = FWFT FIFO と同じ)
    always @(posedge clk) if (wd_take) begin
        widx <= widx + 1;
    end
    always @* wd = data[b * BL + widx];

    always @(posedge clk) if (rd_valid) begin
        if (rd_data !== data[b * BL + rd_cnt]) begin   // (コントローラ自体は 32bit 全部を読み書きする)
            errs = errs + 1;
            if (errs < 5) $display("  [tckd=%0d ph=%0d] burst %0d word %0d: got %h exp %h",
                                   TCKD, PHASE_PS, b, rd_cnt, rd_data, data[b * BL + rd_cnt]);
        end
        rd_cnt = rd_cnt + 1;
    end
    always @(posedge clk) if (rd_err) begin
        errs = errs + 1;
        $display("  [tckd=%0d ph=%0d] rd_err", TCKD, PHASE_PS);
    end

    task automatic issue(input we, input [20:0] a);
        begin
            @(posedge clk);
            while (!ready) @(posedge clk);
            req <= 1'b1; req_we <= we; req_addr <= a;
            @(posedge clk);
            req <= 1'b0;
            @(posedge xfer_done);
        end
    endtask

    initial begin
        for (i = 0; i < NBURST * BL; i = i + 1) data[i] = $random(seed);
        // 3 フレームバッファと調整領域の範囲で、BL 境界のランダムアドレス
        for (i = 0; i < NBURST; i = i + 1) addrs[i] = {$random(seed)} % 21'h1C0000 & ~(BL - 1);
        addrs[0] = 21'h040000 - BL;         // 行末 (512 ワード行の最後のバースト)
        widx = 0; b = 0; rd_cnt = 0;

        repeat (5) @(posedge clk);
        rst <= 1'b0;
        wait (init_done);
        // CR0 は書かない (既定の固定レイテンシ 6) ので、モデルの gap は 2*6-1 = 11
        if (wr_gap != 4'd11) begin
            errs = errs + 1;
            $display("  [tckd=%0d ph=%0d] wr_gap=%0d (expected 11)", TCKD, PHASE_PS, wr_gap);
        end
        if (init_fail) begin
            errs = errs + 1;
            $display("  [tckd=%0d ph=%0d] init_fail (calibration retried)", TCKD, PHASE_PS);
        end

        for (b = 0; b < NBURST; b = b + 1) begin widx = 0; issue(1'b1, addrs[b]); end
        for (b = 0; b < NBURST; b = b + 1) begin
            rd_cnt = 0;
            issue(1'b0, addrs[b]);
            if (rd_cnt != BL) begin
                errs = errs + 1;
                $display("  [tckd=%0d ph=%0d] burst %0d: %0d words", TCKD, PHASE_PS, b, rd_cnt);
            end
        end

        errs = errs + die0.errors + die1.errors;
        if (die0.ck_idle_toggles > 4) begin
            errs = errs + 1;
            $display("  [tckd=%0d ph=%0d] CK toggled %0d times while CS# high", TCKD, PHASE_PS, die0.ck_idle_toggles);
        end
        $display("tb_psram: CK_MODE=%0d tCKD=%0d ps, CK phase=%0d ps: wr_gap=%0d errors=%0d",
                 CK_MODE, TCKD, CK_MODE ? CLK_PS / 2 : PHASE_PS, wr_gap, errs);
        pass = (errs == 0);
        done = 1'b1;
    end
endmodule

module tb_psram;
    // CK 180° (既定): tCKD 1〜7ns。CK を clk_p で作る方式: 位相 90°/112.5°
    // (sim の IOBUF は出力に 3ns 遅延があるので、それより早い CK 位相は成立しない)
    wire [6:0] done, pass;
    tb_psram_one #(.TCKD(1000), .SEED(1)) t0 (.done(done[0]), .pass(pass[0]));
    tb_psram_one #(.TCKD(3000), .SEED(2)) t1 (.done(done[1]), .pass(pass[1]));
    tb_psram_one #(.TCKD(5000), .SEED(3)) t2 (.done(done[2]), .pass(pass[2]));
    tb_psram_one #(.TCKD(7000), .SEED(4)) t3 (.done(done[3]), .pass(pass[3]));
    tb_psram_one #(.TCKD(2000), .PHASE_PS(4960), .SEED(5), .CK_MODE(0)) t4 (.done(done[4]), .pass(pass[4]));
    tb_psram_one #(.TCKD(4000), .PHASE_PS(3968), .SEED(6), .CK_MODE(0)) t5 (.done(done[5]), .pass(pass[5]));
    tb_psram_one #(.TCKD(6000), .PHASE_PS(4960), .SEED(7), .CK_MODE(0)) t6 (.done(done[6]), .pass(pass[6]));

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin
            $dumpfile(vcd);
            $dumpvars(0, t1);
        end
        fork
            wait (&done);
            begin #200_000_000; $fatal(1, "tb_psram: TIMEOUT"); end
        join_any
        if (&pass) begin
            $display("tb_psram: PASS");
            $finish;
        end
        $fatal(1, "tb_psram: FAIL (pass=%b)", pass);
    end
endmodule
`default_nettype wire
