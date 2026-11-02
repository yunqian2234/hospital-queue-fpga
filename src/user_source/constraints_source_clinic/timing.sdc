# 诊室板（V7-3）时序约束。与主板同一套写法：先 derive_clocks，再逐条改名并给出跨域例外。
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_video_pll/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# 外部复位只进入监督/同步复位链，不直接解除任何业务寄存器复位。
set_false_path -from [get_ports {rst_n}]
# system_arst 只接专用复位同步链的异步控制端；各域输出复位仍检查恢复/移除时间。
set_false_path -through [get_nets {system_arst}]

# 板间链路接收：异步输入，数据由 link_frame_rx 的两级同步与帧同步头重新对齐。
set_false_path -from [get_ports {link_rx}]
# 板上按键：两级同步 + 20ms 消抖在 hospital_key_frontend 内部完成。
set_false_path -from [get_ports {key1}]
set_false_path -from [get_ports {key2}]
set_false_path -from [get_ports {key3}]

# V8 网口（RGMII 100M）：RXC 为网口芯片送来的 25 MHz 接收时钟。
create_clock -name eth_rxc -period 40 -waveform {0 20} [get_ports {eth_rxc}]
# 网口芯片在 RXC 上升沿附近 ±0.5 ns 内切换数据（带 RXDLY 配置时数据提前 2 ns），
# FPGA 在 RXC 下降沿采样（eth_rgmii_io），因此留有约 18 ns 余量。
set_input_delay -clock eth_rxc -max 0.5 [get_ports {eth_rxd[*] eth_rx_ctl}]
set_input_delay -clock eth_rxc -min -2.5 [get_ports {eth_rxd[*] eth_rx_ctl}]
# eth_rxc 与 video_clk 不同源：只有 eth_mac_rx 的翻转位（三级同步）和发布期间保持不变的
# 帧缓冲/长度跨域。缓冲和长度在翻转位同步完成前至少两拍已稳定，限制其数据路径即可。
set_max_delay -datapath_only 20.0 -from [get_clocks {eth_rxc}] -to [get_clocks {video_clk}]
set_max_delay -datapath_only 20.0 -from [get_clocks {video_clk}] -to [get_clocks {eth_rxc}]
# MDIO 读入经 eth_mdio 内两级同步，MDC 仅 1.25 MHz。
set_false_path -from [get_ports {eth_mdio}]
# 10/23 TF 卡：SPI 由 video_clk 分频产生（初始化 390 kHz，之后 6.25 MHz，一个 SPI 位 4 个 video_clk），
# MISO 在 SPI 时钟沿之后两拍以上才采样，按异步慢速输入处理。sd_card_top 的局部复位计数器
# 只在 video_clk 域内产生并使用，无跨域。
set_false_path -from [get_ports {sd_miso}]
