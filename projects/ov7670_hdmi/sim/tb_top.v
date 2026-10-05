// ============================================================================
// システム試験: top 全体 + 疑似カメラ + PSRAM モデル x2
//
//   表示側 (dvi_tx の手前: r8/g8/b8/de) の画素を毎クロック検査する:
//     - 表示フレームの先頭画素からフレーム番号を復元し、全画素がそのフレームの
//       パターンと一致すること (= 1 フレーム内に別フレームが混ざらない: ティアリングなし)
//     - フレーム番号が戻らないこと、新しいフレームに更新されていくこと
//     - アンダーランが起きないこと / PSRAM 読み出しエラーがないこと
//     - 読み出しが書き込み中のバッファを指さないこと
//     - 初期化後に FIFO があふれないこと / PSRAM モデルが違反を検出しないこと
//   カメラ信号は cam_sync が clk_mem (45MHz) でオーバーサンプルして取り込むので、PCLK は
//   周期がホールドオフ (5 サンプル = 55ns) より長いこと (18MHz 未満)。表示 (60Hz) より速い
//   カメラは作れないので、どちらもカメラが表示より遅い条件になる
//   tb_top_fast: cam_sync が受け付ける上限付近 (PCLK 15.6MHz, 約 42ms/フレーム)
//   tb_top_slow: 実機と同じ PCLK 12.6MHz (約 51ms/フレーム) + 同期崩れフレームからの回復
// ============================================================================
`timescale 1ps / 1ps
`default_nettype none

module tb_sys #(
    parameter integer PCLK_PS     = 40000,
    parameter integer H_BLANK     = 40,
    parameter integer TRUNC_FRAME = -1,
    parameter integer N_CHECK     = 3,       // 検査する表示フレーム数 (以上)
    parameter integer MIN_FIDS    = 2,       // 表示されるべき異なるカメラフレーム数 (これを見るまで検査を続ける)
    parameter [8*8-1:0] NAME      = "sys"
)(
    output reg done = 1'b0,
    output reg pass = 1'b0
);
    `include "cam_pattern.vh"

    reg clk27 = 1'b0;
    always #18518 clk27 = ~clk27;

    wire       cam_pclk, cam_vsync, cam_href, cam_xclk, cam_reset_n, cam_pwdn, cam_sioc;
    wire [7:0] cam_d;
    wire       cam_siod;
    wire [3:0] cam_fid;
    integer    cam_frames;
    pullup (cam_siod);

    ov7670_model #(.PCLK_PS(PCLK_PS), .H_BLANK(H_BLANK), .TRUNC_FRAME(TRUNC_FRAME)) cam (
        .pclk(cam_pclk), .vsync(cam_vsync), .href(cam_href), .d(cam_d),
        .frame_id(cam_fid), .frames_sent(cam_frames)
    );

    wire        tmds_clk_p, tmds_clk_n;
    wire [2:0]  tmds_d_p, tmds_d_n;
    wire [1:0]  ck, ck_n, cs_n, prst_n;
    wire [15:0] dq;
    wire [1:0]  rwds;
    wire [5:0]  led;
    wire        env_sda, env_scl;                 // BME280 はつながない (プルアップのみ。表示は ENV_OVERLAY=0)
    pullup (env_sda);
    pullup (env_scl);

    top #(.ENV_OVERLAY(0)) dut (
        .clk27(clk27), .btn_rst_n(1'b1), .btn_s2_n(1'b1),
        .cam_pclk(cam_pclk), .cam_vsync(cam_vsync), .cam_href(cam_href), .cam_d(cam_d),
        .cam_xclk(cam_xclk), .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn),
        .cam_sioc(cam_sioc), .cam_siod(cam_siod),
        .tmds_clk_p(tmds_clk_p), .tmds_clk_n(tmds_clk_n), .tmds_d_p(tmds_d_p), .tmds_d_n(tmds_d_n),
        .O_psram_ck(ck), .O_psram_ck_n(ck_n), .O_psram_cs_n(cs_n), .O_psram_reset_n(prst_n),
        .IO_psram_dq(dq), .IO_psram_rwds(rwds),
        .env_sda(env_sda), .env_scl(env_scl),
        .uart_tx(), .led(led)
    );

    psram_model die0 (.ck(ck[0]), .ck_n(ck_n[0]), .cs_n(cs_n[0]), .reset_n(prst_n[0]), .dq(dq[7:0]),  .rwds(rwds[0]));
    psram_model die1 (.ck(ck[1]), .ck_n(ck_n[1]), .cs_n(cs_n[1]), .reset_n(prst_n[1]), .dq(dq[15:8]), .rwds(rwds[1]));

    // ------------------------------------------------------------------
    // 表示画素の検査 (clk_pix)。r8/de_d は vx/vy の text_overlay の遅れ (u_ov.LAT) クロック後に出る
    // ------------------------------------------------------------------
    integer    errs = 0, frames_checked = 0, n_fids = 0, pix_bad = 0;
    reg  [9:0] px_x = 0, px_y = 0;
    reg  [9:0] vxd [0:7];
    reg  [9:0] vyd [0:7];
    integer    k;
    reg        checking = 1'b0, frame_ok = 1'b0;
    reg  [3:0] cur_fid = 0, last_fid = 0;
    reg        have_last = 1'b0;
    // PSRAM には 14bit (G, B の最下位ビットを捨てる) で保存されるので比較もそのビットを除く
    localparam [15:0] PXM = 16'hFFDE;
    wire [15:0] px = {dut.r8[7:3], dut.g8[7:2], dut.b8[7:3]} & PXM;
    function [3:0] fid_of(input [15:0] v);   // (0,0) の画素 = fid*0x1111 (上位 4bit がそのまま fid)
        fid_of = v[15:12];
    endfunction

    always @(posedge dut.clk_pix) begin
        if (dut.de_d) begin
            if (px_x == 0 && px_y == 0) begin
                // 表示フレーム先頭: フレーム番号を復元
                frame_ok = (px == ((16'h1111 * fid_of(px)) & PXM)) && dut.u_fb.latest_valid;
                if (frame_ok) cur_fid = fid_of(px);
                if (frame_ok && !checking) begin
                    checking = 1'b1;
                    $display("[%0s] %0t ps: display shows camera frame %0d -> start checking", NAME, $time, cur_fid);
                end
                if (checking && !frame_ok) begin
                    errs = errs + 1;
                    $display("[%0s] ERROR %0t: frame start pixel %h is not a frame-start pattern", NAME, $time, px);
                end
                pix_bad = 0;
            end
            if (checking && frame_ok && px !== (cam_pat(px_x, px_y[8:0], cur_fid) & PXM)) begin
                pix_bad = pix_bad + 1;
                errs = errs + 1;
                if (pix_bad <= 3)
                    $display("[%0s] ERROR %0t: (%0d,%0d) got %h exp %h (fid %0d)", NAME, $time,
                             px_x, px_y, px, cam_pat(px_x, px_y[8:0], cur_fid) & PXM, cur_fid);
            end
            if (checking && px_x == 639 && px_y == 479) begin
                frames_checked = frames_checked + 1;
                if (have_last && ((cur_fid - last_fid) & 4'h8)) begin
                    errs = errs + 1;
                    $display("[%0s] ERROR: frame number went back %0d -> %0d", NAME, last_fid, cur_fid);
                end
                if (!have_last || cur_fid != last_fid) n_fids = n_fids + 1;
                $display("[%0s] %0t ps: display frame %0d = camera frame %0d, bad pixels %0d",
                         NAME, $time, frames_checked, cur_fid, pix_bad);
                last_fid = cur_fid; have_last = 1'b1;
            end
        end
        // vx/vy を LAT クロック遅らせて、次のクロックの r8/de_d の座標にする
        vxd[0] <= dut.vx; vyd[0] <= dut.vy;
        for (k = 1; k < 8; k = k + 1) begin vxd[k] <= vxd[k - 1]; vyd[k] <= vyd[k - 1]; end
        px_x <= (dut.u_ov.LAT == 1) ? dut.vx : vxd[dut.u_ov.LAT - 2];
        px_y <= (dut.u_ov.LAT == 1) ? dut.vy : vyd[dut.u_ov.LAT - 2];
    end

    // ------------------------------------------------------------------
    // その他の監視
    // ------------------------------------------------------------------
    // 読み出しは書き込み中のバッファを指さない
    always @(posedge dut.clk_mem)
        if (dut.mem_req && !dut.mem_req_we && dut.mem_req_addr[19:18] == dut.wr_buf) begin
            errs = errs + 1;
            $display("[%0s] ERROR %0t: read from buffer %0d being written", NAME, $time, dut.wr_buf);
        end
    // 最初のフレーム完成後は FIFO があふれない (それまではメモリ未初期化で捨てている)
    always @(posedge dut.clk_mem)
        if (dut.u_fb.latest_valid && dut.u_cam.fifo_wr && dut.cam_ce && dut.u_cam.fifo_full) begin
            errs = errs + 1;
            $display("[%0s] ERROR %0t: camera FIFO overflow", NAME, $time);
        end
    integer frames_written = 0;
    always @(dut.frame_wr_tog) if (dut.mem_init_done) frames_written = frames_written + 1;

    // 進捗表示 (既定 2ms ごと。+progress_us=N で変更)
    integer progress_us = 2000;
    initial begin
        if ($value$plusargs("progress_us=%d", progress_us)) ;
        forever begin
        #(progress_us * 1_000_000);
        $display("[%0s] %0d us: psram init=%b gap=%0d, cam frames %0d, written %0d, buf disp/wr/latest=%0d/%0d/%0d valid=%b, checked %0d",
                 NAME, $time / 1_000_000, dut.mem_init_done, dut.mem_wr_gap, cam_frames, frames_written,
                 dut.disp_buf, dut.wr_buf, dut.latest_buf, dut.u_fb.latest_valid, frames_checked);
        end
    end

    reg [1023:0] vcd;
    initial begin
        if ($value$plusargs("vcd=%s", vcd)) begin
            $dumpfile(vcd);
            // 長時間なので低速な信号だけを残す
            $dumpvars(1, dut.led, dut.vvs, cam_vsync, dut.mem_init_done, dut.frame_wr_tog,
                      dut.disp_buf, dut.wr_buf, dut.latest_buf, dut.underrun);
        end
        // カメラは表示より遅いので、異なるカメラフレームを MIN_FIDS 種類見るまで続ける
        wait (frames_checked >= N_CHECK && n_fids >= MIN_FIDS);
        if (dut.underrun)           begin errs = errs + 1; $display("[%0s] ERROR: underrun", NAME); end
        if (dut.rd_err_seen)        begin errs = errs + 1; $display("[%0s] ERROR: PSRAM read error", NAME); end
        if (dut.frame_broken)       begin errs = errs + 1; $display("[%0s] ERROR: SOF inside a burst", NAME); end
        if (dut.mem_init_fail)      begin errs = errs + 1; $display("[%0s] ERROR: PSRAM calibration retried", NAME); end
        if (die0.errors + die1.errors) begin errs = errs + 1; $display("[%0s] ERROR: PSRAM model violations", NAME); end
        if (n_fids < MIN_FIDS)      begin errs = errs + 1; $display("[%0s] ERROR: only %0d distinct frames shown", NAME, n_fids); end
        $display("[%0s] camera frames sent %0d, written to PSRAM %0d, display frames checked %0d (%0d distinct), wr_gap=%0d, errors %0d",
                 NAME, cam_frames, frames_written, frames_checked, n_fids, dut.mem_wr_gap, errs);
        pass = (errs == 0);
        done = 1'b1;
    end
endmodule

module tb_top_fast;
    // PCLK 15.6MHz (cam_sync の上限付近), 横ブランク短め -> 約 42ms/フレーム
    wire done, pass;
    tb_sys #(.PCLK_PS(64000), .H_BLANK(40), .N_CHECK(3), .MIN_FIDS(2), .NAME("fast")) t (.done(done), .pass(pass));
    initial begin
        fork
            wait (done);
            begin #400_000_000_000; $fatal(1, "tb_top_fast: TIMEOUT"); end
        join_any
        if (pass) begin $display("tb_top_fast: PASS"); $finish; end
        $fatal(1, "tb_top_fast: FAIL");
    end
endmodule

module tb_top_slow;
    // PCLK 12.6MHz (実機と同じ) -> 約 51ms/フレーム。2 枚目のフレームを途中で打ち切る
    wire done, pass;
    // 打ち切られたフレーム 2 は表示されず、0, 1, 3 が表示されること
    tb_sys #(.PCLK_PS(79365), .H_BLANK(40), .TRUNC_FRAME(2), .N_CHECK(3), .MIN_FIDS(3), .NAME("slow")) t (.done(done), .pass(pass));
    initial begin
        fork
            wait (done);
            begin #500_000_000_000; $fatal(1, "tb_top_slow: TIMEOUT"); end
        join_any
        if (pass) begin $display("tb_top_slow: PASS"); $finish; end
        $fatal(1, "tb_top_slow: FAIL");
    end
endmodule
`default_nettype wire
