# 两块屏界面改版（暖白医疗 UI v3）  2026-10-24

工作目录：`20261021/lab_ex5_i2s`。本次只改源文件、工程文件、约束、测试和文档；**不交付 bit**（无头 TD 编译只做检查），也不写 Flash。

## 1. 用户定下的方案

| 项 | 决定 |
|---|---|
| 外接八键（J1）、HDMI 选卡/预览页、按键提示 | 删除 |
| 缩略图模式（SW4） | 删除 |
| 配色 | 暖白医疗：正文墨色 #1F2933、标签灰、青绿 #0E6E6E 只做小标记、叫号琥珀 #F08C00、状态绿 #2E9E5B / 红 #D64545 |
| 大厅照片 | 全屏显示；顶栏和底部信息区为浅色半透明带（照片 ×5/8 + 96），不加深色底、不加白描边 |
| 文字 | 抗锯齿（每像素 4 级覆盖度），按原始字号生成，不放大 |
| 滚动字幕 | 左侧固定“温馨提示”，原文不变，字号 20 px |
| 亮度/对比度/音量/轮播信息 | 只在调节时显示 3 秒（替代字幕行），无背景 |
| 音频波形 | 最初版本：绿色 20ff90，宽 512，32 点，无底板 |
| 同一卡片缩回后再点 | 再次放大（点击计数） |
| 保持时间修复 | 不手动补做 fix_hold：大厅 slice < 90%，让 TD 自己的 hold fix 运行 |

## 2. 改了什么

### 大厅板（HDMI1.4b_Transmitter_v1.0.al，种子 8 → **5**）
* `display/hospital_screen.v` 重写：全屏照片 + 两条浅色半透明带 + 抗锯齿文字。状态在帧起点锁存；调节信息 180 帧（3 s）后自动隐藏，上电前几帧不显示；拒绝提示（红字）同样 3 s。
* 新增通用模块（两块板共用）：`display/ui_text_engine.v`（逐行生成字形描述符，乒乓缓存，像素路径无乘除）、`display/ui_glyph_rom.v`（字形 ROM，EG_LOGIC_BRAM + MIF，大厅 32K 块 / 诊室 9K 块）、`display/ui_table_rom.v`（条目/字符串/字形表，9K 块；TD 会把小 `$readmemh` ROM 做成 LUT，大厅放不下）。
* 内容由 `verification/ui3/ui3_assets.py` 统一生成：`display/hall_*.{mif,hex}`、`display/hall_ui.vh`、`display/clinic_*.{mif,hex}`、`clinic/clinic_ui.vh`。生成器检查每个槽位里所有字符串的字体高度一致（引擎按槽位的字高取列）。
* `top_tf_hdmi_audio.v`：删除 J1 端口/八键消抖、hospital_patient_ui、request_mux、staff_arbiter、缩略图（thumb_sw、两个 thumbnail_layout、reader/player 缩略图模式）；触摸请求直连业务核心；诊室命令 `& 8'h07` 后直接作为核心按键；波形恢复最初参数（y 252..315，画在照片上）；link_master 新端口 `card_accepted`。
* `pin.adc`：删除 `thumb_sw`（C5）与 `hospital_keys_n[0..7]`（J1-31..38）。
* `.al`：去掉 22 个已无任何模块引用的源文件条目（依赖遍历确认），加入 3 个新模块。

### 点击计数（同一卡片缩回后再点会再放大）
* 大厅 `link/link_master.v`：状态帧 d9 = 核心每接受一次表达卡（`accepted_keys[5]`，含“请帮助我”）加 1。
* 诊室 `clinic/clinic_link.v` 解出 d9，`top_clinic.v` 帧锁存，`clinic/clinic_card_view.v` 计数变化等同“新卡”。放大期间点同一张卡仍忽略。大厅若还是旧程序（d9 = 0），诊室行为与 10/23 完全相同。

### 诊室板（hospital_clinic.al，种子 1 不变）
* `clinic/clinic_screen.v` 重写为同一风格：暖白页面、细分隔线、琥珀当前号、患者表达/求助、下一位/候诊/已取号、操作结果、六张卡格（最近一张青绿边框）、KEY2/3/4 说明；无图片卡放大时中间白框显示卡片文字。
* `clinic_card_view.v`：放大边框改为青绿（求助卡红 #D64545），卡格底色与新页面一致。
* `.al` 加入 3 个新模块。诊室 32K 块全部被卡片图片占用，字形 ROM 用 9K 块（共 25 块）。

### 移出源码树（未删除）
`delivery/ui_redesign_20261024/removed/`：旧字库/文字表 hex（hospital_font*、hospital_text、hospital_edge、ui_card_x、ui_digits、ui_geometry、clinic_font、clinic_text）、thumbnail_layout.v、hospital_key_diagnostic.v、hospital_patient_ui.v、hospital_request_mux.v。原始文件全部备份在 `delivery/ui_redesign_20261024/before/`。

## 3. 验证

| 检查 | 结果 |
|---|---|
| 画面逐像素对比（`verification/ui3/run_ui3_tests.py`，独立参考模型 `ui3_ref.py`） | 6/6 PASS：大厅 H_basic / H_adjust / H_states / H_ticker，诊室 C_status / C_zoom（`evidence/ui3_display_final` 为 H_basic、H_adjust、H_ticker、C_zoom 的最终单独运行；H_states、C_status 在 `evidence/ui3_display`） |
| 诊室放大触发（`verification/clinic_cards/run_trigger_tests.py`） | 同卡再点、旧大厅程序、放大中换卡、计数回绕/断链：4/4 PASS |
| 两板业务（`verification/ui3/tb_system_link.sv`：触摸串口→核心→以太网字节流→诊室链路→放大触发；医生命令回送） | 15/15 PASS（`evidence/system/system_link.log`） |
| 大厅 TD（GUI 同流程，**无手动 fix_hold**，种子 5） | slice 89.14%，hold fix 已运行（无 “hold fixing is skipped”），setup +0.048 ns，hold +0.003 ns，0 违例；LUT 16540、32K 块 14/16 |
| 大厅其他种子 | 7：同样通过（89.16%）；2：setup −0.038 ns |
| 诊室 TD（种子 1） | setup +0.152 ns，hold +0.003 ns，0 违例，slice 56%，9K 块 59/64 |

证据：`delivery/ui_redesign_20261024/evidence/td_ui3d_seed5`、`td_clinic_ui3_seed1`。

## 4. 上板步骤（队友）
1. 关闭 TD 后打开两个工程（.al 已更新），GUI 正常编译即可；大厅日志里应**没有** “hold fixing is skipped”。
2. 下载到 SRAM 试用；不写 Flash。
3. J1 31..38 不再使用，可拔掉外接按键模块；SW4 不再有作用。
4. 大厅、诊室两块板都要用新程序（点击计数）；只换一块也能工作，但同卡再点不会再放大。

## 5. 注意
* 大厅余量很小（89.1%）。之后再改大厅源码，需要重新做无头检查确认 < 90% 且 0 违例，否则 TD 会跳过 hold fix。
* 改任何文字/位置：改 `ui3_assets.py` 后运行 `python verification/ui3/ui3_assets.py`，再跑 `run_ui3_tests.py`。
