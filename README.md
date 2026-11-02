# 医院候诊叫号与辅助沟通系统

基于两块安路 EG4S20（HX4S20C 开发板）的门诊候诊叫号系统。大厅屏负责报到和叫号，诊室屏面向医生，两板通过网线协同。全部功能由 FPGA 硬件逻辑实现，未使用处理器软核。

- **大厅板**：读取 TF 卡上的图片和音频（FAT32），用 SDRAM 做帧缓存，经 HDMI 输出 640×480 画面和 48 kHz 音频。
  - 患者在陶晶驰串口触摸屏上报到，并登记沟通需求；
  - 多诊室共用一条队列叫号，叫号时语音播报；
  - 自研 DFT（Goertzel）16 频段音频频谱柱；
  - 640×480～1920×1080 图片自适应缩放；
  - 中文抗锯齿界面。
- **诊室板**：显示本诊室当前患者的号码、需求、症状和难受程度，依次放大该患者的需求卡；医生通过按键叫号、重播和确认求助。
- **板间链路**：100M 以太网原始帧（EtherType 0x88B5）。命令带序号，重发直到大厅回执；状态逐帧广播。

## 目录

| 路径 | 内容 |
|---|---|
| `src/td_project/HDMI1.4b_Transmitter_v1.0.al` | 大厅板 TD 工程（顶层 `top`，`src/user_source/hdl_source/top_tf_hdmi_audio.v`） |
| `src/td_project_clinic/hospital_clinic.al` | 诊室板 TD 工程（顶层 `top_clinic`，`src/user_source/hdl_source/clinic/top_clinic.v`） |
| `src/user_source/hdl_source/` | 全部 Verilog 源码：`SD` 读卡与缩放、`display` 界面与频谱、`audio`、`app` 业务核心、`link` / `eth` 链路、`clinic` 诊室、`uart` 触摸屏 |
| `src/user_source/constraints_source*/` | 两块板的引脚（`pin.adc`）和时序（`timing.sdc`）约束 |
| `src/td_project/al_ip/`、`src/user_source/hdl_source/IP/` | TD IP 向导生成的 PLL、FIFO、ROM |
| `touch_screen/` | 陶晶驰触摸屏工程 `1025.HMI`（报到登记版）及字库；用 USART HMI 软件打开、编译后下载到屏。命令协议见 `docs/TOUCH_CHECKIN_20261025.md`，从零制作的教程见 `docs/TOUCH_HMI_TUTORIAL_20261025.md` |
| `tf_card/hall/`、`tf_card/clinic/` | 两块板 TF 卡根目录要放的文件 |
| `verification/` | 仿真测试平台、Python 参考模型和运行脚本 |
| `docs/` | 各阶段设计与使用说明，最新的是 `SPECTRUM_20261029.md`、`CLINIC_SEQ_20261030.md` |
| `delivery/tech_doc_20261030/` | 竞赛技术文档（docx）及插图 |
| `delivery/video_sop_20261030/` | 展示视频拍摄 SOP 与配音稿 |
| `delivery/*/tools/` | 构建、检查、资源生成脚本 |

## 厂商 IP（需另行放入）

以下文件是安路科技的加密 IP，版权属于厂商，仓库中**没有包含**：
- HDMI 1.4b 发送核：`hdmi_1_4b_transmitter_core_wrapper.enc.v`
- SDRAM 控制器：`sdr_*.enc.v`

文件清单见 `VENDOR_FILES_NOT_INCLUDED.txt`。编译前，请从官方 HDMI 例程或课程资料中把它们复制到清单所列的路径。如果仓库是私有的，也可以直接把它们放进去。

## 编译与下载

1. 安装安路 TD 6.2；打开上述 `.al` 文件即可编译。工程里全部使用相对路径。
   - 工程所在路径不能含空格和中文，并且要短（例如 `D:\source_code`）：TD 遇到空格会截断路径；路径超过 Windows 260 字符上限时，打不开 HDMI 加密 IP。
2. 大厅工程的布局种子已设为 **5**，诊室为 **1**。大厅板 slice 占用约 89.6%，改动 RTL 后需要重新扫描种子，保证低于 90%（否则 TD 会跳过保持时间修复）且时序满足。
3. 生成的 bit 下载到 SRAM 即可运行；需要上电自启时再写 Flash。

## TF 卡

两块板的 TF 卡都格式化为 FAT32，把对应文件放到根目录：

| 板 | 文件 |
|---|---|
| 大厅 | `PIC1.BMP`～`PIC4.BMP`：24 位 BMP，640×480～1920×1080<br>`VOICE.PCM`：叫号语音库<br>`AUDIO.PCM`：背景音乐，48 kHz / 16 位 / 单声道原始 PCM，仓库未包含，可自备；没有时使用内置提示音 |
| 诊室 | `CARD1.BMP`～`CARD5.BMP`：120×90、8 位 256 色需求卡和求助卡 |

## 操作

| 板 | 输入 | 功能 |
|---|---|---|
| 大厅 | KEY2 | 下一张 |
| | KEY4 | 短按：开 / 关轮播；长按 1 秒：上一张 |
| | KEY3 | 亮度（SW3 拨上时为对比度） |
| | SW1 | 拨上时 KEY2 / KEY4 调音量，KEY3 切换音乐 / 语音 |
| | SW2 | 频谱柱 |
| | SW4 | 底行显示原图分辨率 |
| 诊室 | KEY2 / KEY3 / KEY4 | 1 诊室：叫下一位 / 重播 / 确认求助 |
| | 外接按键 1～3 | 2 诊室：同上 |
| | SW4 | 单 / 双诊室 |
| | SW3 | 单诊室时选择诊室号 |

## 仿真

需要 Python 3（numpy、Pillow、matplotlib）和 Icarus Verilog。脚本中 iverilog 的路径写死为 `D:/iverilog/iverilog/bin`，TD 的路径写死为 `D:/TD`，请按本机安装位置修改。

```
python verification/ui3/run_ui3_tests.py          # 大厅屏逐像素测试
python verification/ui3/run_spectrum.py           # DFT 频谱柱（含变异测试）
python verification/multiroom/run_need_seq.py     # 诊室需求卡顺序与命令归属
python verification/multiroom/run_clinic_ui.py --scenario S_status
```

多诊室随机压力测试为 `verification/multiroom/tb_multiroom.sv`（顶层 `tb`），用 iverilog 编译 `src/user_source/hdl_source` 下的各目录即可运行。

## 资源（TD 布局布线报告）

| | 大厅板 | 诊室板 |
|---|---|---|
| LUT | 84.9% | 50.6% |
| Slice | 89.6% | 58.5% |
| 时序 | 满足 | 满足 |
