// Gowin EDA 用タイミング制約 (参考。OSS フローは tangnano9k_nextpnr.sdc を使う)
create_clock -name clk27    -period 37.037 [get_ports {clk27}]
create_clock -name cam_pclk -period 40.0   [get_ports {cam_pclk}]
create_generated_clock -name clk_ser   -source [get_ports {clk27}] -multiply_by 14 -divide_by 3 [get_pins {u_pll/CLKOUT}]
create_generated_clock -name clk_pix   -source [get_pins {u_pll/CLKOUT}] -divide_by 5 [get_pins {u_clkdiv/CLKOUT}]
create_generated_clock -name clk_mem   -source [get_ports {clk27}] -multiply_by 7 -divide_by 3 [get_pins {u_pll_mem/CLKOUT}]
create_generated_clock -name clk_mem_p -source [get_ports {clk27}] -multiply_by 7 -divide_by 3 -phase 90 [get_pins {u_pll_mem/CLKOUTP}]
// cam_pclk / clk_mem / clk_pix は互いに非同期 (async FIFO, ラインバッファ, 2FF 同期化のみで受け渡す)
set_clock_groups -asynchronous -group [get_clocks {cam_pclk}] -group [get_clocks {clk_mem clk_mem_p}] -group [get_clocks {clk_ser clk_pix}]
