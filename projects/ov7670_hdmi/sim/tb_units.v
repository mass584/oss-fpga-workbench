// ============================================================================
// 単体テスト
//   tb_tmds     : TMDS エンコード -> デコード往復一致、制御トークン、DC バランス
//   tb_sccb     : SCCB 波形をモニタして書き込みをデコードし、レジスタ表と一致すること
//   tb_capture  : cam_capture の書き込みアドレス/データ/SOF、
//                 途中で打ち切られたフレームの次フレームで先頭から書き直すこと
//   tb_dbg      : dbg_report の UART 出力がテンプレートどおりになること
//   tb_probe    : cam_probe の異常検出・集計
//   tb_csync    : cam_sync がグリッチ入りの PCLK で立ち上がりを 1 回ずつ数えること
//   tb_yuv      : yuv2rgb が BT.601 の式と ±1 以内で一致すること (彩度 x1.0 / x2.0)
//   tb_calc     : env_calc (BME280 の補正計算) が tools/env_asm.py の参照実装と一致すること
//   tb_env      : bme280_env + BME280 モデル (I2C) の通し試験 / tb_env_nack: センサが応答しない場合
//   tb_overlay  : text_overlay の 1 フレームの全画素 (映像の遅れ 1 / 4 クロック)
// ============================================================================
`timescale 1ps / 1ps
`default_nettype none

// ----------------------------------------------------------------------------
module tb_tmds;
    reg        clk = 1'b0, rst = 1'b1, de = 1'b0;
    reg  [7:0] d = 0;
    reg  [1:0] c = 0;
    wire [9:0] q;
    tmds_encoder dut (.clk(clk), .rst(rst), .d(d), .c(c), .de(de), .q(q));
    always #5000 clk = ~clk;

    // DVI 1.0 のデコード
    function [7:0] dec(input [9:0] w);
        reg [7:0] v;
        integer k;
        begin
            v = w[9] ? ~w[7:0] : w[7:0];
            dec[0] = v[0];
            for (k = 1; k < 8; k = k + 1) dec[k] = w[8] ? (v[k] ^ v[k-1]) : ~(v[k] ^ v[k-1]);
        end
    endfunction
    function integer ones10(input [9:0] w);
        integer k;
        begin ones10 = 0; for (k = 0; k < 10; k = k + 1) ones10 = ones10 + w[k]; end
    endfunction

    integer seed = 7, i, errs = 0, disp = 0, max_disp = 0, n_data = 0;
    reg [7:0] d_d;
    reg [1:0] c_d;
    reg       de_d = 1'b0, started = 1'b0;

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin $dumpfile(vcd); $dumpvars(0, tb_tmds); end
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        for (i = 0; i < 200000; i = i + 1) begin
            @(posedge clk);
            // 1 ライン 800 中 640 がデータ。ときどき偏ったデータ (0x00/0xFF) も混ぜる
            de <= (i % 800) < 640;
            case ({$random(seed)} % 8)
                0: d <= 8'h00;
                1: d <= 8'hFF;
                default: d <= $random(seed);
            endcase
            c <= $random(seed);
        end
        @(posedge clk);
        $display("tb_tmds: %0d data words, max |running disparity| = %0d, errors = %0d", n_data, max_disp, errs);
        if (errs == 0 && n_data > 100000) begin $display("tb_tmds: PASS"); $finish; end
        $fatal(1, "tb_tmds: FAIL");
    end

    // q は入力の 1 クロック後
    always @(posedge clk) begin
        d_d <= d; c_d <= c; de_d <= de; started <= !rst;
        if (started) begin
            if (de_d) begin
                n_data = n_data + 1;
                if (dec(q) !== d_d) begin
                    errs = errs + 1;
                    if (errs < 5) $display("tb_tmds: data %h -> %b -> %h", d_d, q, dec(q));
                end
                disp = disp + 2 * ones10(q) - 10;
                if (disp > max_disp) max_disp = disp;
                if (-disp > max_disp) max_disp = -disp;
                // DVI では running disparity は ±10 以内に保たれる (cnt は偏り/2 で ±5 程度)
                if (disp > 10 || disp < -10) begin
                    errs = errs + 1;
                    if (errs < 5) $display("tb_tmds: disparity %0d out of range", disp);
                end
            end else begin
                disp = 0;
                if (q !== (c_d == 2'b00 ? 10'b1101010100 : c_d == 2'b01 ? 10'b0010101011 :
                           c_d == 2'b10 ? 10'b0101010100 : 10'b1010101011)) begin
                    errs = errs + 1;
                    if (errs < 5) $display("tb_tmds: control %b -> %b", c_d, q);
                end
            end
        end
    end
endmodule

// ----------------------------------------------------------------------------
module tb_sccb;
    // CLK_HZ / (SCCB_HZ*4) = 1 にして高速化 (シーケンスは実機と同じ)
    reg  clk = 1'b0, rst = 1'b1;
    wire cam_reset_n, sioc, siod_low, done;
    ov7670_sccb_init #(.CLK_HZ(400_000), .SCCB_HZ(100_000)) dut (
        .clk(clk), .rst(rst), .cam_reset_n(cam_reset_n), .sioc(sioc),
        .siod_drive_low(siod_low), .done(done)
    );
    wire siod = siod_low ? 1'b0 : 1'b1;      // プルアップ
    always #5000 clk = ~clk;

    // 期待値: レジスタ表から待ち(FFF0)を除いたもの
    reg [15:0] rom_q;
    reg [7:0]  rom_i;
    ov7670_regs u_rom (.idx(rom_i), .q(rom_q));

    integer   errs = 0, nbits = 0, nwr = 0, exp_i = 0, n_exp = 0, k;
    reg [26:0] sh = 0;
    reg        in_xfer = 1'b0, sioc_d = 1'b1, siod_d = 1'b1;
    reg [15:0] expv;

    task automatic next_expected;
        begin
            rom_i = exp_i[7:0]; #1;
            while (rom_q == 16'hFFF0) begin exp_i = exp_i + 1; rom_i = exp_i[7:0]; #1; end
            expv = rom_q;
        end
    endtask

    always @(posedge clk) begin
        sioc_d <= sioc; siod_d <= siod;
        // START: SIOC High 中に SIOD 立ち下がり
        if (sioc && sioc_d && siod_d && !siod) begin
            if (!cam_reset_n) begin errs = errs + 1; $display("tb_sccb: START while camera in reset"); end
            in_xfer = 1'b1; nbits = 0;
        end
        // ビット: SIOC 立ち上がりでサンプル (27 ビット後の立ち上がりは STOP 用)
        if (in_xfer && sioc && !sioc_d && nbits < 27) begin
            sh = {sh[25:0], siod};
            nbits = nbits + 1;
        end
        // SIOC High 中のデータ変化は START/STOP 以外は禁止
        if (in_xfer && sioc && sioc_d && siod != siod_d && !(siod_d && !siod) && !(!siod_d && siod && nbits == 27)) begin
            errs = errs + 1; $display("tb_sccb: SIOD changed while SIOC high (bit %0d)", nbits);
        end
        // STOP: SIOC High 中に SIOD 立ち上がり
        if (in_xfer && sioc && sioc_d && !siod_d && siod) begin
            in_xfer = 1'b0;
            next_expected;
            if (nbits != 27 || sh[26:19] != 8'h42 || sh[17:10] != expv[15:8] || sh[8:1] != expv[7:0]) begin
                errs = errs + 1;
                $display("tb_sccb: write %0d: bits=%0d id=%h reg=%h data=%h (expected %h)",
                         nwr, nbits, sh[26:19], sh[17:10], sh[8:1], expv);
            end
            nwr = nwr + 1; exp_i = exp_i + 1;
        end
    end

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin $dumpfile(vcd); $dumpvars(0, tb_sccb); end
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        fork
            wait (done);
            begin #100_000_000_000; $fatal(1, "tb_sccb: TIMEOUT"); end
        join_any
        repeat (10) @(posedge clk);
        next_expected;
        if (expv != 16'hFFFF) begin errs = errs + 1; $display("tb_sccb: done before end of table (%0d writes)", nwr); end
        // 期待する書き込み数 = 表の待ち(FFF0)以外のエントリ数
        n_exp = 0;
        for (k = 0; k < 256; k = k + 1) begin
            rom_i = k[7:0]; #1;
            if (rom_q == 16'hFFFF) k = 256;
            else if (rom_q != 16'hFFF0) n_exp = n_exp + 1;
        end
        $display("tb_sccb: %0d register writes decoded (table has %0d), errors = %0d", nwr, n_exp, errs);
        if (errs == 0 && nwr == n_exp) begin $display("tb_sccb: PASS"); $finish; end
        $fatal(1, "tb_sccb: FAIL");
    end
endmodule

// ----------------------------------------------------------------------------
module tb_capture;
    `include "cam_pattern.vh"

    wire       pclk, vsync, href;
    wire [7:0] d;
    wire [3:0] fid;
    integer    frames;
    // フレーム 1 を 100 ラインで打ち切る
    ov7670_model #(.PCLK_PS(10000), .H_BLANK(20), .TRUNC_FRAME(1), .TRUNC_LINES(100)) cam (
        .pclk(pclk), .vsync(vsync), .href(href), .d(d), .frame_id(fid), .frames_sent(frames)
    );

    wire        we_f, sof_f, ft_f;
    wire [18:0] addr_f;
    wire [15:0] data_f;
    cam_capture #(.AW(19)) cap_full (
        .pclk(pclk), .ce(1'b1), .vsync(vsync), .href(href), .d(d),
        .we(we_f), .waddr(addr_f), .wdata(data_f), .sof(sof_f), .frame_toggle(ft_f));

    integer errs = 0, n_f = 0, exp_f = 0, fr = 0;
    reg [3:0] cur_fid = 0;
    reg [9:0] ex; reg [8:0] ey;

    // フレーム境界 (VSYNC 立ち上がり後の frame_toggle 変化) で個数を確認
    reg ft_prev = 1'b0;
    always @(posedge pclk) if (ft_f !== ft_prev) begin
        ft_prev = ft_f;
        if (fr >= 1) begin
            // 打ち切りフレーム (fr==2 で終わるもの = モデルの frame 1) は 100 ライン分
            if (n_f != ((fr == 2) ? 640 * 100 : 640 * 480)) begin
                errs = errs + 1;
                $display("tb_capture: frame %0d: %0d pixels", fr - 1, n_f);
            end
        end
        fr = fr + 1; n_f = 0; exp_f = 0;
    end

    always @(posedge pclk) begin
        if (we_f) begin
            ex = exp_f % 640; ey = exp_f / 640;
            if (n_f == 0) cur_fid = fid;
            if (addr_f !== exp_f[18:0] || data_f !== cam_pat(ex, ey, cur_fid) || sof_f !== (n_f == 0)) begin
                errs = errs + 1;
                if (errs < 5) $display("tb_capture: full #%0d addr %0d data %h sof %b", n_f, addr_f, data_f, sof_f);
            end
            n_f = n_f + 1; exp_f = exp_f + 1;
        end
    end

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin $dumpfile(vcd); $dumpvars(1, tb_capture); end
        wait (frames == 4);
        #1_000_000;
        $display("tb_capture: %0d frames (one truncated) checked, errors = %0d", fr - 1, errs);
        if (errs == 0 && fr >= 4) begin $display("tb_capture: PASS"); $finish; end
        $fatal(1, "tb_capture: FAIL");
    end
endmodule
// ----------------------------------------------------------------------------
module tb_dbg;
    // dbg_report の出力 (UART) を復号してテンプレートどおりの 1 行になることを確認
    reg clk = 1'b0, rst = 1'b1;
    always #5000 clk = ~clk;
    wire tx;
    localparam TPL = "A=## B=### |";
    dbg_report #(.CLK_HZ(1_152_000), .PERIOD(50), .LEN(12), .NN(5), .TPL(TPL)) dut (
        .clk(clk), .rst(rst), .nib(20'h3C_1F0), .tx(tx));

    reg [8*16-1:0] line = 0;
    integer n = 0, k;
    reg [7:0] ch;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        // 1 文字 = 10 ビット x 10 クロック。スタートビットの中央からサンプル
        while (n < 14) begin
            @(negedge tx);
            repeat (15) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin ch[k] = tx; repeat (10) @(posedge clk); end
            line = {line[8*15-1:0], ch};
            n = n + 1;
        end
        if (line[8*14-1:0] == {"A=3C B=1F0 |", 8'h0D, 8'h0A}) begin
            $display("tb_dbg: \"%0s\" PASS", line[8*14-1:16]);
            $finish;
        end
        $fatal(1, "tb_dbg: FAIL got \"%0s\"", line[8*14-1:0]);
    end
endmodule

module tb_probe;
    // cam_probe: ce 間隔の異常 (余分/取りこぼし)、HREF の瞬断、ライン長の集計、最初の異常の記録、
    // 異常位置から行末までの mark を確認する (BPL=16 の短いラインで)
    reg clk = 1'b0, rst = 1'b1;
    always #5 clk = ~clk;
    reg ce = 1'b0, vsync = 1'b0, href = 1'b0;
    wire [1:0]  mark;
    wire [15:0] n_short, n_long, n_ok, n_bad, n_hg;
    wire [23:0] n_i3, n_i4;
    wire [11:0] bmin, bmax, apos, aline;
    wire [3:0]  atype;
    wire [31:0] ahist;
    wire [95:0] d_ones;
    wire [11:0] d_n;
    cam_probe #(.WINDOW(4000), .LINE_GAP(8), .BPL(12'd16)) dut (
        .clk(clk), .rst(rst), .ce(ce), .vsync(vsync), .href(href), .d(8'h81), .pclk_pair(2'b10),
        .mark(mark), .n_short(n_short), .n_i3(n_i3), .n_i4(n_i4), .n_long(n_long),
        .n_ok(n_ok), .n_bad(n_bad), .bpl_min(bmin), .bpl_max(bmax), .n_hg(n_hg),
        .an_type(atype), .an_pos(apos), .an_line(aline), .an_hist(ahist),
        .d_ones(d_ones), .d_n(d_n));

    // gap クロック目に ce (前の ce から gap クロック後)
    task automatic pulse(input integer gap, input h, input v);
        integer k;
        begin
            for (k = 1; k < gap; k = k + 1) @(posedge clk);
            href <= h; vsync <= v; ce <= 1'b1;
            @(posedge clk) ce <= 1'b0;
        end
    endtask

    integer mark_bad = 0, mark_seen = 0;
    // mark は異常の ce の次から行末まで 0 以外。line1 は余分 (1), line2 は取りこぼし (2)
    always @(posedge clk) if (ce && href) begin
        if (mark != 2'd0) mark_seen = mark_seen + 1;
    end

    // n バイトのライン。bad_at の位置の ce を gap=bad_gap で出す。hg_at から 2 ce だけ HREF=0
    task automatic line(input integer n, input integer bad_at, input integer bad_gap, input integer hg_at);
        integer b;
        begin
            for (b = 0; b < n; b = b + 1)
                pulse((b == bad_at) ? bad_gap : (b[0] ? 4 : 3), (b < hg_at || b >= hg_at + 2), 1'b0);
            for (b = 0; b < 20; b = b + 1) pulse(b[0] ? 4 : 3, 1'b0, 1'b0);   // 水平ブランク
            if (mark != 2'd0) mark_bad = mark_bad + 1;                       // 行末で解除
        end
    endtask

    integer i;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        for (i = 0; i < 4; i = i + 1) pulse(3, 1'b0, 1'b1);   // VSYNC
        for (i = 0; i < 20; i = i + 1) pulse(4, 1'b0, 1'b0);
        line(16, -1, 3, 99);   // 正常
        line(17,  5, 1, 99);   // 余分な立ち上がり (間隔 1) -> 17 バイト
        line(15,  9, 7, 99);   // 取りこぼし (間隔 7) -> 15 バイト
        line(16, -1, 3, 8);    // HREF 瞬断 (2 ce) -> 14 バイト
        for (i = 0; i < 4; i = i + 1) pulse(3, 1'b0, 1'b1);
        wait (dut.tmr == 32'd3999);
        @(posedge clk); @(posedge clk);
        $display("tb_probe: short=%0d i3=%0d i4=%0d long=%0d ok=%0d bad=%0d min=%0d max=%0d hg=%0d an=%0d/%0d/%0d mark_seen=%0d",
                 n_short, n_i3, n_i4, n_long, n_ok, n_bad, bmin, bmax, n_hg, atype, apos, aline, mark_seen);
        if (n_short != 1 || n_long != 1 || n_hg != 1 || n_ok != 1 || n_bad != 3 ||
            bmin != 12'd14 || bmax != 12'd17 || atype != 4'd1 || apos != 12'd5 || aline != 12'd1 ||
            ahist != 32'hAAAA_AAAA || mark_bad != 0)
            $fatal(1, "tb_probe: FAIL");
        // mark は異常の次の ce から見える: line1 は 6..16 の 11 バイト, line2 は 10..14 の 5 バイト,
        // line3 は瞬断明けの 11..15 の 5 バイト
        // データ線: 偶数バイトの 256 個に 1 個 -> この短い試験では最初の 1 個だけ。D=0x81
        if (d_n != 12'd1 || d_ones != {12'd1, 72'd0, 12'd1}) $fatal(1, "tb_probe: FAIL d_n=%0d d_ones=%h", d_n, d_ones);
        if (mark_seen != 11 + 5 + 5) $fatal(1, "tb_probe: FAIL mark_seen=%0d", mark_seen);
        $display("tb_probe: PASS");
        $finish;
    end
endmodule
// ----------------------------------------------------------------------------
module tb_csync;
    // cam_sync: High の途中の短い落ち込み (9ns) と立ち下がり直後のばたつき (5ns のひげ) を混ぜた
    // PCLK で、立ち上がりを 1 回ずつ数え、データを取りこぼし/重複なく出すこと。
    // 実機で見えた波形に合わせ、ひげの後には 2 サンプル (22ns) 以上の Low を残す。
    // k%7==0 では Low を 12ns に縮める (本物の短い Low。1 サンプルしか取れないことがある)
    reg clk = 1'b0;
    always #11111 clk = ~clk;                     // 45MHz
    reg       pclk = 1'b0;
    reg [7:0] d = 8'd0;
    wire       ce, vs_o, hr_o, pclk_s;
    wire [7:0] d_o;
    wire [1:0] pair;
    cam_sync dut (.clk(clk), .pclk(pclk), .vsync(1'b0), .href(1'b1), .d(d),
                  .ce(ce), .vsync_o(vs_o), .href_o(hr_o), .d_o(d_o), .pclk_s(pclk_s), .pclk_pair(pair));

    integer n_ce = 0, errs = 0, k;
    reg [7:0] last = 8'd0;
    always @(posedge clk) if (ce) begin
        if (n_ce > 0 && d_o != last + 8'd1) errs = errs + 1;
        last = d_o;
        n_ce = n_ce + 1;
    end

    // 1 周期 79.4ns: High 55ns (k%3==0 なら 30ns 目に 9ns の落ち込み) / Low 24.4ns
    // (k%5==0 なら立ち下がり 3ns 後に 5ns のひげを入れ、その後 Low を 24ns 保つ = 周期 87ns)
    initial begin
        #200000;
        for (k = 0; k < 300; k = k + 1) begin
            pclk = 1'b1;
            if (k % 3 == 0) begin #30000 pclk = 1'b0; #9000 pclk = 1'b1; #16000; end
            else #55000;
            pclk = 1'b0; #3000 d = d + 8'd1;     // データは立ち下がりの少し後で変わる
            if (k % 5 == 0) begin pclk = 1'b1; #5000 pclk = 1'b0; #24000; end
            else if (k % 7 == 0) #9000;
            else #21400;
        end
        #300000;
        $display("tb_csync: %0d rising edges -> %0d ce, data errors = %0d", 300, n_ce, errs);
        if (n_ce != 300 || errs != 0) $fatal(1, "tb_csync: FAIL");
        $display("tb_csync: PASS");
        $finish;
    end
endmodule
// ----------------------------------------------------------------------------
module tb_yuv;
    // yuv2rgb: BT.601 フルレンジの式 (実数) と ±1 以内で一致すること (Y/U/V を 17 刻みで総当たり,
    // 彩度 x1.0 と x2.0)
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg  [7:0] y = 0, u = 0, v = 0;
    reg  [3:0] sat = 4'd4;
    wire [7:0] r, g, b;
    yuv2rgb dut (.clk(clk), .y(y), .u(u), .v(v), .sat(sat), .r(r), .g(g), .b(b));

    function integer clampi(input real x);
        integer t;
        begin
            t = (x < 0.0) ? 0 : (x > 255.0) ? 255 : $rtoi(x + 0.5);
            clampi = t;
        end
    endfunction
    function integer absd(input integer a, input integer bb);
        absd = (a > bb) ? a - bb : bb - a;
    endfunction

    integer iy, iu, iv, er, eg, eb, errs = 0, n = 0, is;
    real    k, cu, cv;
    initial begin
        for (is = 4; is <= 8; is = is + 4) begin
        sat = is; k = is / 4.0;
        for (iy = 0; iy < 256; iy = iy + 17)
            for (iu = 0; iu < 256; iu = iu + 17)
                for (iv = 0; iv < 256; iv = iv + 17) begin
                    @(negedge clk) begin y = iy; u = iu; v = iv; end
                    repeat (3) @(posedge clk);
                    #1;
                    cu = k * (iu - 128); cv = k * (iv - 128);
                    if (cu > 255.0) cu = 255.0; if (cu < -255.0) cu = -255.0;
                    if (cv > 255.0) cv = 255.0; if (cv < -255.0) cv = -255.0;
                    er = clampi(iy + 1.402 * cv);
                    eg = clampi(iy - 0.344136 * cu - 0.714136 * cv);
                    eb = clampi(iy + 1.772 * cu);
                    if (absd(r, er) > 1 || absd(g, eg) > 1 || absd(b, eb) > 1) begin
                        if (errs < 5) $display("tb_yuv: Y=%0d U=%0d V=%0d got %0d %0d %0d exp %0d %0d %0d",
                                               iy, iu, iv, r, g, b, er, eg, eb);
                        errs = errs + 1;
                    end
                    n = n + 1;
                end
        end
        $display("tb_yuv: %0d points, errors = %0d", n, errs);
        if (errs != 0) $fatal(1, "tb_yuv: FAIL");
        $display("tb_yuv: PASS");
        $finish;
    end
endmodule
// ----------------------------------------------------------------------------
module tb_calc;
    // env_calc: tools/env_asm.py のテストベクタ (データシートの式で求めた表示) と一致すること。
    // エラー表示のエントリも確認する
    reg clk = 1'b0, rst = 1'b1, start = 1'b0;
    always #5 clk = ~clk;
    reg  [7:0] vb [0:255];
    reg  [5*27-1:0] vt;
    `include "env_vectors.vh"

    reg  [7:0] mem [0:255];
    wire [7:0] raddr;
    reg  [7:0] rdata = 8'd0;
    always @(posedge clk) rdata <= mem[raddr];
    reg        err = 1'b0;
    wire       busy, txt_we;
    wire [5:0] txt_addr;
    wire [4:0] txt_data;
    reg  [4:0] txt [0:63];
    always @(posedge clk) if (txt_we) txt[txt_addr] <= txt_data;
    env_calc dut (.clk(clk), .rst(rst), .start(start), .err(err), .busy(busy),
                  .mem_raddr(raddr), .mem_rdata(rdata),
                  .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data));

    function [7:0] ch(input [4:0] c);
        ch = ENV_CHARS[8 * (18 - c) +: 8];
    endfunction

    integer n, i, l, c, errs = 0, cyc;
    reg [8*9-1:0] got, exp;
    task automatic run_check(input integer nv, input ent);
        begin
            for (i = 0; i < 64; i = i + 1) txt[i] = 5'd31;
            err = ent;
            @(negedge clk) start = 1'b1;
            @(negedge clk) start = 1'b0;
            cyc = 0;
            while (busy) begin @(posedge clk); cyc = cyc + 1; end
            for (l = 0; l < 3; l = l + 1) begin
                for (c = 0; c < 9; c = c + 1) begin
                    got[8 * (8 - c) +: 8] = (txt[l * 16 + c] > 5'd18) ? "?" : ch(txt[l * 16 + c]);
                    exp[8 * (8 - c) +: 8] = ch(vt[5 * (26 - (l * 9 + c)) +: 5]);
                end
                if (nv == 0 || nv == 1) $display("tb_calc: vec %0d line %0d \"%s\"", nv, l, got);
                if (got !== exp) begin
                    $display("tb_calc: vec %0d line %0d got \"%s\" exp \"%s\"", nv, l, got, exp);
                    errs = errs + 1;
                end
            end
            $display("tb_calc: vec %0d err %0d: %0d clk", nv, ent, cyc);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        for (n = 0; n < ENV_NV; n = n + 1) begin
            env_vec(n);
            for (i = 0; i < 256; i = i + 1) mem[i] = vb[i];
            run_check(n, 1'b0);
        end
        env_vec(ENV_NV - 1);                   // 最後のベクタはエラー表示 = エラーのエントリと同じ
        run_check(ENV_NV - 1, 1'b1);
        if (errs != 0) $fatal(1, "tb_calc: FAIL (%0d lines)", errs);
        $display("tb_calc: PASS");
        $finish;
    end
endmodule
// ----------------------------------------------------------------------------
module tb_env_core #(
    parameter [6:0] MODEL_ADDR = 7'h76,       // 0x76 以外ならセンサが応答しない (NACK -> エラー表示)
    parameter       NAME = "tb_env"
)(
    output reg done = 1'b0, output reg pass = 1'b0
);
    // bme280_env + BME280 モデル (I2C): 起動時の設定書き込み、補正係数と測定値の読み出し、
    // 表示文字 (tools/env_asm.py のテストベクタ 0 と一致) を確認する。I2C は 1MHz、測定間隔は短くする
    reg clk = 1'b0, rst = 1'b1;
    always #11111 clk = ~clk;                 // 45MHz
    reg  [7:0] vb [0:255];
    reg  [5*27-1:0] vt;
    `include "env_vectors.vh"

    wire scl_low, sda_low;
    wire scl = scl_low ? 1'b0 : 1'b1;         // プルアップ
    wire sda;
    assign (weak1, weak0) sda = 1'b1;         // プルアップ (モデルと FPGA は Low に引くだけ)
    assign sda = sda_low ? 1'b0 : 1'bz;
    bme280_model #(.ADDR(MODEL_ADDR)) u_dev (.scl(scl), .sda(sda));

    wire       txt_we;
    wire [5:0] txt_addr;
    wire [4:0] txt_data;
    wire [7:0] chip_id, n_ok;
    wire       err;
    bme280_env #(.CLK_HZ(45_000_000), .I2C_HZ(1_000_000), .PERIOD(20000), .BOOT(1000)) dut (
        .clk(clk), .rst(rst), .scl_low(scl_low), .sda_low(sda_low), .sda_in(sda),
        .txt_we(txt_we), .txt_addr(txt_addr), .txt_data(txt_data),
        .chip_id(chip_id), .err(err), .n_ok(n_ok)
    );
    reg [4:0] txt [0:63];
    always @(posedge clk) if (txt_we) txt[txt_addr] <= txt_data;

    function [7:0] ch(input [4:0] c);
        ch = ENV_CHARS[8 * (18 - c) +: 8];
    endfunction

    integer i, l, c, errs = 0;
    reg [8*9-1:0] got, exp;
    initial begin
        env_vec((MODEL_ADDR == 7'h76) ? 0 : ENV_NV - 1);   // 応答しないときはエラー表示を期待
        for (i = 0; i < 256; i = i + 1) u_dev.regs[i] = vb[i];
        for (i = 0; i < 64; i = i + 1) txt[i] = 5'd31;
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        // 2 回目の表示更新まで待つ (1 回目の後も同じ内容のはず)
        wait (dut.st == 4'd10);
        wait (dut.st == 4'd0);
        wait (dut.st == 4'd10);
        wait (dut.st == 4'd0);
        for (l = 0; l < 3; l = l + 1) begin
            for (c = 0; c < 9; c = c + 1) begin
                got[8 * (8 - c) +: 8] = (txt[l * 16 + c] > 5'd18) ? "?" : ch(txt[l * 16 + c]);
                exp[8 * (8 - c) +: 8] = ch(vt[5 * (26 - (l * 9 + c)) +: 5]);
            end
            $display("%0s: line %0d \"%s\"", NAME, l, got);
            if (got !== exp) begin $display("%0s: exp \"%s\"", NAME, exp); errs = errs + 1; end
        end
        if (MODEL_ADDR == 7'h76) begin
            // 設定の書き込み (F2=01, F4=27, F5=A0 の順) と、読み出し 1+26+7+8x2 バイト
            if (u_dev.n_wr != 3 || u_dev.wlog_reg[0] != 8'hF2 || u_dev.wlog_val[0] != 8'h01 ||
                u_dev.wlog_reg[1] != 8'hF4 || u_dev.wlog_val[1] != 8'h27 ||
                u_dev.wlog_reg[2] != 8'hF5 || u_dev.wlog_val[2] != 8'hA0) begin
                $display("%0s: 設定の書き込みが違う (n_wr=%0d)", NAME, u_dev.n_wr); errs = errs + 1;
            end
            if (u_dev.n_rd_bytes != 1 + 26 + 7 + 8 * 2 || chip_id != 8'h60 || err || n_ok != 8'd2) begin
                $display("%0s: rd_bytes=%0d chip=%h err=%b n_ok=%0d", NAME, u_dev.n_rd_bytes, chip_id, err, n_ok);
                errs = errs + 1;
            end
        end else if (!err) begin
            $display("%0s: NACK なのに err=0", NAME); errs = errs + 1;
        end
        pass = (errs == 0);
        done = 1'b1;
    end
endmodule

module tb_env;
    wire done, pass;
    tb_env_core #(.MODEL_ADDR(7'h76), .NAME("tb_env")) t (.done(done), .pass(pass));
    initial begin
        fork
            begin wait (done); end
            begin #30_000_000_000; $fatal(1, "tb_env: TIMEOUT"); end
        join_any
        if (pass) begin $display("tb_env: PASS"); $finish; end
        $fatal(1, "tb_env: FAIL");
    end
endmodule

module tb_env_nack;
    wire done, pass;
    tb_env_core #(.MODEL_ADDR(7'h77), .NAME("tb_env_nack")) t (.done(done), .pass(pass));
    initial begin
        fork
            begin wait (done); end
            begin #30_000_000_000; $fatal(1, "tb_env_nack: TIMEOUT"); end
        join_any
        if (pass) begin $display("tb_env_nack: PASS"); $finish; end
        $fatal(1, "tb_env_nack: FAIL");
    end
endmodule
// ----------------------------------------------------------------------------
module tb_overlay_core #(
    parameter integer VLAT = 1,
    parameter         NAME = "tb_overlay"
)(
    output reg done = 1'b0, output reg pass = 1'b0
);
    // text_overlay: 1 フレームの全画素を検査する。映像は x を色にした模様を VLAT クロック遅らせて入れ、
    // 文字領域 (464,14) から 9x3 文字 x (18x24 画素) は env_font のドット = 白、枠 (余白 6) の中は 1/4、
    // それ以外は映像そのまま。出力の遅れは max(VLAT, 3)
    localparam integer LAT = (VLAT > 3) ? VLAT : 3;
    reg clk = 1'b0, rst = 1'b1, wclk = 1'b0;
    always #20 clk = ~clk;
    always #11 wclk = ~wclk;
    wire [9:0] vx, vy;
    wire       vde, vhs, vvs;
    video_timing u_vt (.clk(clk), .rst(rst), .x(vx), .y(vy), .de(vde), .hs(vhs), .vs(vvs));

    // 映像: VLAT クロック遅れ
    reg [9:0] xd [0:15];
    reg [9:0] yd [0:15];
    reg [2:0] sd [0:15];
    integer k;
    always @(posedge clk) begin
        xd[0] <= vx; yd[0] <= vy; sd[0] <= {vde, vhs, vvs};
        for (k = 1; k < 16; k = k + 1) begin xd[k] <= xd[k - 1]; yd[k] <= yd[k - 1]; sd[k] <= sd[k - 1]; end
    end
    wire [9:0] vx_v = xd[VLAT - 1];
    wire [2:0] s_v  = sd[VLAT - 1];
    reg        twe = 1'b0;
    reg  [5:0] taddr = 6'd0;
    reg  [4:0] tdata = 5'd0;
    wire [7:0] r, g, b;
    wire       de_o, hs_o, vs_o;
    text_overlay #(.VLAT(VLAT)) dut (
        .clk(clk), .x(vx), .y(vy), .de(vde),
        .r_in(vx_v[7:0]), .g_in(vx_v[9:2]), .b_in(~vx_v[7:0]),
        .de_in(s_v[2]), .hs_in(s_v[1]), .vs_in(s_v[0]),
        .r(r), .g(g), .b(b), .de_o(de_o), .hs_o(hs_o), .vs_o(vs_o),
        .txt_clk(wclk), .txt_we(twe), .txt_addr(taddr), .txt_data(tdata)
    );

    // 期待値: 出力は (x, y) から LAT 後
    wire [9:0] ex = xd[LAT - 1], ey = yd[LAT - 1];
    wire [2:0] es = sd[LAT - 1];
    reg  [4:0] txt [0:63];
    reg  [4:0] fcode;
    reg  [2:0] frow;
    wire [4:0] fbits;
    env_font u_f (.code(fcode), .row(frow), .bits(fbits));
    integer errs = 0, n_on = 0, n_box = 0, tx, ty, i;
    reg [7:0] er, eg, eb;
    reg       in_txt, in_box, on;
    reg       checking = 1'b0;
    // 立ち下がりで比べる (出力も期待値の遅延段もここでは安定している)
    always @(negedge clk) if (!rst && done == 1'b0 && checking) begin
        tx = ex - 464; ty = ey - 14;
        in_txt = es[2] && ex >= 464 && ex < 464 + 162 && ey >= 14 && ey < 14 + 72;
        in_box = es[2] && ex >= 458 && ex < 632 && ey >= 8 && ey < 92;
        on = 1'b0;
        if (in_txt) begin
            fcode = txt[(ty / 24) * 16 + tx / 18];
            frow  = (ty % 24) / 3;
            #1;
            on = ((tx % 18) / 3 < 5) && fbits[4 - (tx % 18) / 3];
        end
        er = ex[7:0]; eg = ex[9:2]; eb = ~ex[7:0];
        if (on) begin er = 8'hFF; eg = 8'hFF; eb = 8'hFF; n_on = n_on + 1; end
        else if (in_box) begin er = {2'b00, er[7:2]}; eg = {2'b00, eg[7:2]}; eb = {2'b00, eb[7:2]}; n_box = n_box + 1; end
        if ({de_o, hs_o, vs_o} !== es || (es[2] && {r, g, b} !== {er, eg, eb})) begin
            if (errs < 5) $display("%0s: (%0d,%0d) got %h%h%h sync %b exp %h%h%h sync %b", NAME, ex, ey,
                                   r, g, b, {de_o, hs_o, vs_o}, er, eg, eb, es);
            errs = errs + 1;
        end
    end

    initial begin
        // 文字 RAM: 行 0 = "0123456789" の先頭 9 文字, 行 1 = 記号, 行 2 = 文字コード 9..1
        for (i = 0; i < 64; i = i + 1) txt[i] = 5'd10;
        for (i = 0; i < 9; i = i + 1) begin txt[i] = i; txt[16 + i] = 10 + i; txt[32 + i] = 9 - i; end
        for (i = 0; i < 64; i = i + 1) begin
            @(negedge wclk) begin twe = 1'b1; taddr = i; tdata = txt[i]; end
        end
        @(negedge wclk) twe = 1'b0;
        repeat (3) @(posedge clk);
        rst <= 1'b0;
        // 1 フレーム目の先頭から 2 フレーム分検査する
        wait (vy == 10'd524 && vx == 10'd799);
        @(posedge clk) checking = 1'b1;
        wait (vy == 10'd524 && vx == 10'd700);
        wait (vy == 10'd524 && vx == 10'd799);
        @(posedge clk);
        repeat (LAT + 1) @(posedge clk);
        checking = 1'b0;
        $display("%0s: VLAT=%0d errors=%0d (文字ドット %0d, 枠 %0d 画素)", NAME, VLAT, errs, n_on, n_box);
        pass = (errs == 0) && n_on > 1000 && n_box > 10000;
        done = 1'b1;
    end
endmodule

module tb_overlay;
    wire d1, p1, d4, p4;
    tb_overlay_core #(.VLAT(1), .NAME("tb_overlay[VLAT=1]")) t1 (.done(d1), .pass(p1));
    tb_overlay_core #(.VLAT(4), .NAME("tb_overlay[VLAT=4]")) t4 (.done(d4), .pass(p4));
    initial begin
        wait (d1 && d4);
        if (p1 && p4) begin $display("tb_overlay: PASS"); $finish; end
        $fatal(1, "tb_overlay: FAIL");
    end
endmodule
`default_nettype wire
