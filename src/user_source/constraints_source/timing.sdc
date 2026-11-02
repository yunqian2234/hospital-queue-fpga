# 第5课：按真实时钟和具体跨域接口约束；保留 TD 默认 0.1ns uncertainty。
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
derive_clocks
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {ext_mem_clk_sft} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[2]}]
rename_clock -name {video_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk} -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# video_clk/hdmi_5x_clk 同时运行且同源，保留像素到串行域的真实时序检查。
# 不再全局划分 asynchronous/exclusive，跨域例外逐条对应 RTL 结构。
# 外部复位只进入监督/同步复位链，不直接解除任何业务寄存器复位。
set_false_path -from [get_ports {rst_n}]

# 冻结状态字握手：请求/确认只豁免第一级，后两级继续检查本域时序。
set_false_path -to [get_regs {u_media_audio/req0 u_media_audio/ack0 u_diagnostic_board/req0 u_diagnostic_board/ack0}]
# 源数据从请求发起一直保持到确认返回；三级同步后才采样完整总线。
# 10ns 小于最短接收周期 20ns，确保数据先于同步后的请求稳定。
# Optional arpeggio media-ID CDC is pruned when ARP_FALLBACK_ENABLE=0 and AUDIO_SOURCE_MODE!=1.
set_max_delay -quiet -nowarn -datapath_only 10.0 -from [get_regs -quiet {u_media_audio/hold_data[*]}] -to [get_regs -quiet {u_media_audio/dst_data[*]}]
set_max_delay -datapath_only 10.0 -from [get_regs {u_diagnostic_board/hold_data[*]}] -to [get_regs {u_diagnostic_board/dst_data[*]}]

# SDRAM initialized is a held level received by cdc_level (two FFs).
# Bound only the memory-domain input into stage0, independently of the
# incidental 1ns PLL edge spacing. Stage0->stage1 and local reset recovery
# remain timed at 100MHz; no false_path or clock-group exemption is added.
set_max_delay -datapath_only 7.0 -from [get_clocks {ext_mem_clk}] -to [get_regs {u_sdram_ready_sd/stage0}]

# I2S 过采样：数据在 BCLK 下降沿更新，接收端检测同步后的上升沿。
# 只排除已有三级同步链的第一级，不屏蔽后续音频接收/封包路径。
set_false_path -to [get_regs {u_audio_bridge/u_I2S_receiver/S_i2s_bclk_1d u_audio_bridge/u_I2S_receiver/S_i2s_lrck_1d u_audio_bridge/u_I2S_receiver/S_i2s_dout_1d}]

# system_arst 只接专用复位同步链的异步控制端；各域输出复位仍检查恢复/移除时间。
# TD 布局时会复制末级复位 FF 并按使用者命名，所以按此专用异步网约束，
# 覆盖相同 FF 的复制品；不豁免同步链级间路径，也不豁免 rst_sd/rst_mem 等输出。
set_false_path -through [get_nets {system_arst}]
# 第9课审查：OSD 增加复位扇出，TD 会生成 stage2_dup_* 并移除原名。
# 仅补齐末级复位 FF 的复制品；终点仍限于串行域复位同步链的异步输入。
set_false_path -from [get_regs {u_video_reset/stage2*}] -to [get_regs {u_hdmi2phy_wrapper/*/u_serial_reset/stage*}]

# FIFO Gray 指针最大延时继续使用两个 FIFO IP 自带的 scoped Tcl 约束。
# SDRAM 0/180 度物理接口路径保留检查，不能用时钟组/false_path 整组忽略。
# SIP DQ returns belong to the following controller sample after pad/clock
# round-trip delay. sdram.v delays rd_valid by one cycle to match that sample.
# C1=315deg and C2=180deg give an 11ns read window; retain the following
# controller sample on all 32 DQ pins. Continuous burst
# data changes every cycle: hold=0 deliberately retains the next-beat hold
# check (hold=1 would incorrectly relax it by another 8 ns).
set_multicycle_path -setup 2 -from [get_pins {U3/sdram.dq[*]}] -to [get_clocks {ext_mem_clk}]
set_multicycle_path -hold 0 -from [get_pins {U3/sdram.dq[*]}] -to [get_clocks {ext_mem_clk}]
# The output enable is asserted before ACT and remains through the last word;
# unlike the continuous DQ data, this control has a multi-cycle contract.
# Scope only this OE net, preserving ordinary timing for all payload/commands.
set_multicycle_path -setup 2 -through [get_nets {U3/u2_ram/u2_wrrd/sdr_t}] -to [get_pins {U3/sdram.dq[*]}]
set_multicycle_path -hold 1 -through [get_nets {U3/u2_ram/u2_wrrd/sdr_t}] -to [get_pins {U3/sdram.dq[*]}]
# Keep native SIP data setup/hold checks; no unmatched PAD-clock override.
# SD SPI/DDC 板外时序尚未加入板级器件参数，此处不编造 I/O delay。

# 第8课：冻结状态字与读帧请求的具体 CDC 路径；FIFO 沿用原 IP Gray 约束。
set_false_path -to [get_regs {u_catalogue_status/req0 u_catalogue_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_catalogue_status/hold_data[*]}] -to [get_regs {u_catalogue_status/dst_data[*]}]
set_false_path -to [get_regs {u_complete_status/req0 u_complete_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_complete_status/hold_data[*]}] -to [get_regs {u_complete_status/dst_data[*]}]
set_false_path -to [get_regs {u_sd_error_status/req0 u_sd_error_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_sd_error_status/hold_data[*]}] -to [get_regs {u_sd_error_status/dst_data[*]}]
set_false_path -to [get_regs {u_reader_error_status/req0 u_reader_error_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_reader_error_status/hold_data[*]}] -to [get_regs {u_reader_error_status/dst_data[*]}]
set_false_path -to [get_regs {u_loader/u_result_status/req0 u_loader/u_result_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_loader/u_result_status/hold_data[*]}] -to [get_regs {u_loader/u_result_status/dst_data[*]}]
set_false_path -to [get_regs {u_reader/req0 u_reader/ack0 u_retry_sd/stage0 u_loader/u_ready/stage0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_reader/request_index[*]}] -to [get_regs {u_reader/index_mem[*]}]

# 第10课：事件/忙电平仅豁免 2FF 首级；完整帧描述符保持到 reader 确认。
# 2026-10-02：TD 把 generate 块内寄存器命名为 g_fade$xxx，原写法 g_fade/xxx 匹配不到，
# 这三个同步器首级一直被当作同步路径分析，布线后插入 1～1.5ns 的保持修复缓冲链。
set_false_path -to [get_regs {manual_req_sync1 manual_allow_sync1 u_fade_transition/*req_sync1 u_fade_transition/*commit_sync1 u_fade_transition/*busy_sync1}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_reader/request_wipe u_reader/request_old_index[*] u_reader/request_boundary[*]}] -to [get_regs {u_reader/wipe_mem u_reader/old_index_mem[*] u_reader/boundary_mem[*]}]

# 仅豁免异步复位同步器的输入；同步器级间及其下游复位释放继续检查。
set_false_path -from [get_regs {u_sd_reset/stage2* u_mem_reset/stage2*}] -to [get_regs {u_loader/u_stream_fifo/asy_w_rst* u_loader/u_stream_fifo/asy_r_rst*}]
set_false_path -from [get_regs {u_mem_reset/stage2* u_video_reset/stage2* u_reader/reset_count[*]}] -to [get_regs {u_reader/u_read_fifo/asy_w_rst* u_reader/u_read_fifo/asy_r_rst* u_reader/u_prefetch_reset/stage*}]

# 第11讲：音频状态字握手、源域寄存 Gray 指针、单比特 EOF/start。
set_false_path -to [get_regs {u_audio_error_status/req0 u_audio_error_status/ack0 u_audio_gain_status/req0 u_audio_gain_status/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_audio_error_status/hold_data[*]}] -to [get_regs {u_audio_error_status/dst_data[*]}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_audio_gain_status/hold_data[*]}] -to [get_regs {u_audio_gain_status/dst_data[*]}]
# 10/22：10/16 新增的音量 cdc_status（video_clk -> audio_mclk）与上面各 cdc_status 同样处理：
# 握手首级为异步入口，冻结数据在请求同步完成前已稳定，限制数据路径长度即可。
set_false_path -to [get_regs {u_user_volume_cdc/req0 u_user_volume_cdc/ack0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_user_volume_cdc/hold_data[*]}] -to [get_regs {u_user_volume_cdc/dst_data[*]}]
# 7ns 小于最快源时钟 10ns；约束全部 Gray 位传播时间，不能只设 false_path。
set_max_delay -datapath_only 7.0 -from [get_regs {u_wav_stream/wr_gray[*]}] -to [get_regs {u_wav_stream/wr_gray_sync1[*]}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_wav_stream/rd_gray[*]}] -to [get_regs {u_wav_stream/rd_gray_sync1[*]}]
set_false_path -to [get_regs {u_wav_stream/started_sync1 u_wav_stream/end_sync1}]
# 仅异步卡复位到音频复位同步链的入口；输出和级间继续做时序检查。
set_false_path -from [get_regs {u_audio_reset/stage2*}] -to [get_regs {u_wav_audio_reset/stage*}]

# 第12讲：逐样本冻结总线握手；只豁免 req/ack/enable 同步器首级。
set_false_path -to [get_regs {u_wave_tap/req0 u_wave_tap/ack0 u_wave_enable/stage0}]
set_max_delay -datapath_only 7.0 -from [get_regs {u_wave_tap/hold_data[*]}] -to [get_regs {u_wave_tap/dst_sample[*]}]
# 卡复位同时清两端握手，每端同步释放；只豁免专用复位同步链的异步入口。
set_false_path -from [get_regs {u_video_reset/stage2*}] -to [get_regs {u_wave_pix_reset/stage*}]

# 第12讲布线审查：TD 打包后复位 FF 可借用 seg_scan 等 LUT 的物理 slice 名，
# 甚至保留 Q 未连接的复位 FF；仅按 stage* 名字会漏掉这些同步器异步入口。
# 已核对布局网表：下列专用 arst 网只驱动复位同步器的异步 SR，
# 豁免此入口，仍检查 stage0->stage1->stage2 和同步复位输出到所有业务寄存器。
set_false_path -through [get_nets {u_wav_audio_reset/arst u_wave_pix_reset/arst}]

# 第13讲：SW4 只驱动同步首级。TD 将首级打包进 C5 的 PAD 输入寄存器，
# get_regs 不再返回原寄存器名；按外部端口作为起点豁免，不屏蔽 FF 级间路径。
set_false_path -from [get_ports {thumb_sw}]
set_false_path -from [get_ports {contrast_sw}]
set_false_path -from [get_ports {volume_sw}]
# V6：触摸屏串口为异步输入（uart_rx 内两级同步），输出为慢速电平。
set_false_path -from [get_ports {tjc_rx}]
set_false_path -to [get_ports {tjc_tx}]
# V7-2 板间链路：link_tx 是寄存器输出（输出延迟已由 sdc 默认值覆盖即可），link_rx 为异步输入，
# 数据由 link_frame_rx 的两级同步与帧同步头重新对齐，故对输入端口设 false path。
set_false_path -from [get_ports {link_rx}]
# reader 帧描述符从请求发出保持到确认，沿用原 req/ack 同步链。
set_max_delay -datapath_only 7.0 -from [get_regs {u_reader/request_thumb u_reader/request_complete[*]}] -to [get_regs {u_reader/thumb_mem u_reader/complete_mem[*]}]

# 第14讲：KEY3 只进入消抖器两级同步的首级；保留级间和帧锁存时序检查。
# 用端口起点覆盖 TD 将首级 FF 打包进 B1 PAD 的实现，不依赖物理寄存器名。
set_false_path -from [get_ports {key3}]

# External key ports drive only u_key_diag/u_frontend/sync0 input registers.
# Same convention as key3: allow PAD packing of sync0; still time sync0->sync1.
set_false_path -from [get_ports {hospital_keys_n[*]}]
# 阶段C 语音链路跨时钟域：只同步翻转位；多位字段在翻转前冻结、到采样时已稳定两拍以上。
# 实例位于 generate 块内，TD 网表名形如 g_voice$u_voice_player/...，故用前导通配符。
# 命令 video_clk -> sd_card_clk，结果 sd_card_clk -> video_clk。
set_false_path -to [get_regs {*u_voice_player/c_s1 *u_voice_dispatch/rsp_sync1}]
set_max_delay -datapath_only 10.0 -from [get_regs {*u_voice_dispatch/cmd_seq[*] *u_voice_dispatch/cmd_count[*] *u_voice_dispatch/cmd_clips[*]}] -to [get_regs {*u_voice_player/seq[*] *u_voice_player/count[*] *u_voice_player/clips[*]}]
set_max_delay -datapath_only 10.0 -from [get_regs {*u_voice_player/rsp_seq[*] *u_voice_player/rsp_status[*]}] -to [get_regs {*u_voice_dispatch/*}]
# 播放器 sd_card_clk <-> 语音输出 audio_mclk 的开始/取空翻转位，以及语音 FIFO 的 Gray 指针。
set_false_path -to [get_regs {*u_voice_out/g_s1 *u_voice_player/d_s1}]
set_max_delay -datapath_only 7.0 -from [get_regs {*u_voice_fifo/wr_gray[*]}] -to [get_regs {*u_voice_fifo/wr_gray_s1[*]}]
set_max_delay -datapath_only 7.0 -from [get_regs {*u_voice_fifo/rd_gray[*]}] -to [get_regs {*u_voice_fifo/rd_gray_s1[*]}]

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
