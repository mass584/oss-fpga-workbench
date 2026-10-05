# nextpnr-himbaechel 用タイミング制約
#   nextpnr は rPLL/CLKDIV の出力周波数を導出しないので、各クロックネットを直接指定する。
#   異なるクロック間のパスは nextpnr の既定で検査されない (cam_pclk / clk_mem / clk_pix は非同期で、
#   async FIFO / ラインバッファ / 2FF 同期化でのみ受け渡す)。
create_clock -period 37.037 -name clk27    [get_ports clk27]
create_clock -period 40.000 -name cam_pclk [get_ports cam_pclk]
# DQCE (グローバル網) を通った後の PCLK。30fps (PCLK 約 25MHz) でも足りるよう 25MHz で検査
create_clock -period 40.000 -name pclk     [get_nets pclk]
create_clock -period 39.683 -name clk_pix  [get_nets clk_pix]
create_clock -period  7.937 -name clk_ser  [get_nets clk_ser]
create_clock -period 22.222 -name clk_mem  [get_nets clk_mem]
create_clock -period 22.222 -name clk_mem_p [get_nets clk_mem_p]
