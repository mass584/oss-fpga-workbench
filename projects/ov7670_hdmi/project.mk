# OV7670 -> HDMI(DVI) カメラモニタ + BME280 表示 (Tang Nano 9K)
# Paths are relative to this directory.
TOP      := top
RTL_SRCS := rtl/top.v rtl/clocks.v rtl/btn_debounce.v rtl/cdc_sync.v rtl/dpram.v rtl/async_fifo.v \
            rtl/ov7670_sccb_init.v rtl/ov7670_regs.v \
            rtl/cam_frontend.v rtl/cam_sync.v rtl/cam_capture.v rtl/cam_pack.v \
            rtl/psram_ctrl.v rtl/psram_fb.v \
            rtl/video_timing.v rtl/fb_display.v rtl/yuv2rgb.v rtl/tmds_encoder.v rtl/dvi_tx.v \
            rtl/i2c_master.v rtl/bme280_env.v rtl/env_calc.v rtl/env_prog.v \
            rtl/text_overlay.v rtl/env_font.v rtl/ov_delay.v \
            rtl/dbg_uart.v rtl/dbg_report.v rtl/uart_tx.v rtl/cam_probe.v rtl/cam_runlen.v rtl/cam_monitor.v
TB_TOP   := tb_top
TB_SRCS  := sim/gowin_sim_models.v sim/psram_model.v sim/ov7670_model.v sim/bme280_model.v \
            sim/tb_units.v sim/tb_psram.v sim/tb_top.v
TB_TOPS  ?= tb_tmds tb_sccb tb_capture tb_dbg tb_probe tb_csync tb_yuv tb_calc tb_env tb_env_nack tb_overlay \
            tb_psram tb_top_fast tb_top_slow
# Verilator はベンダプリミティブを知らないので、ポート宣言だけのスタブを渡す
LINT_SRCS := sim/gowin_lint_stubs.v
# nextpnr は PLL 出力の周波数を導出しないので SDC でクロックごとに指定する
NEXTPNR_FLAGS := --sdc $(PROJDIR)/constr/tangnano9k_nextpnr.sdc
