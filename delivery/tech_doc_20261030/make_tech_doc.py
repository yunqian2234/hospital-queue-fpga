"""10/30: technical document for the competition entry, written into the official template
(技术文档模板.docx: page setup and styles are kept, its instruction text is replaced).
Figures are placeholders (grey boxes) that say what picture to insert.
Usage: python make_tech_doc.py  ->  技术文档_医院候诊叫号与辅助沟通系统.docx
"""
from pathlib import Path

import docx
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt, RGBColor, Cm

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]                      # AL_FPGA_Handoff_20260925/AL_FPGA_Handoff_20260925
TEMPLATE = ROOT / '技术文档模板.docx'
OUT = HERE / '技术文档_医院候诊叫号与辅助沟通系统.docx'

d = docx.Document(str(TEMPLATE))
body = d.element.body
for el in list(body):
    if el.tag != qn('w:sectPr'):
        body.remove(el)

GREY = RGBColor(0x59, 0x59, 0x59)


def fonts(run, size, bold=False, cn='宋体', color=None):
    run.font.size = Pt(size)
    run.font.bold = bold
    run.font.name = 'Times New Roman'
    rpr = run._r.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts')
        rpr.insert(0, rf)
    rf.set(qn('w:eastAsia'), cn)
    rf.set(qn('w:ascii'), 'Times New Roman')
    rf.set(qn('w:hAnsi'), 'Times New Roman')
    if color is not None:
        run.font.color.rgb = color


def para(text='', size=12, bold=False, cn='宋体', align=None, indent=True, before=0, after=0, style='Normal',
         line=1.5, color=None):
    p = d.add_paragraph(style=style)
    pf = p.paragraph_format
    pf.space_before, pf.space_after, pf.line_spacing = Pt(before), Pt(after), line
    if indent:
        pf.first_line_indent = Pt(size * 2)
    if align is not None:
        p.alignment = align
    if text:
        fonts(p.add_run(text), size, bold, cn, color)
    return p


def title(text):
    p = d.add_paragraph(style='Heading 2')
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_after = Pt(12)
    fonts(p.add_run(text), 18, True, '黑体', RGBColor(0, 0, 0))


def h1(text):        # 第X部分 / 摘要
    para(text, 14, True, '黑体', indent=False, before=12, after=6)


def h2(text):        # 1.1
    para(text, 12, True, '黑体', indent=False, before=6, after=3)


def h3(text):        # 2.3.2.1 etc.
    para(text, 12, True, '黑体', indent=False, before=3, after=2)


def p(text):
    para(text)


def bullets(items):
    for it in items:
        q = para('', indent=False)
        q.paragraph_format.left_indent = Pt(24)
        q.paragraph_format.first_line_indent = Pt(-12)
        if isinstance(it, tuple):
            fonts(q.add_run('• ' + it[0]), 12, True)
            fonts(q.add_run(it[1]), 12)
        else:
            fonts(q.add_run('• ' + it), 12)


def shade(cell, hexcolor):
    tcPr = cell._tc.get_or_add_tcPr()
    shd = OxmlElement('w:shd')
    shd.set(qn('w:val'), 'clear')
    shd.set(qn('w:color'), 'auto')
    shd.set(qn('w:fill'), hexcolor)
    tcPr.append(shd)


def borders(table, color='000000', style='single', sz='4'):
    tblPr = table._tbl.tblPr
    b = OxmlElement('w:tblBorders')
    for e in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        x = OxmlElement(f'w:{e}')
        x.set(qn('w:val'), style)
        x.set(qn('w:sz'), sz)
        x.set(qn('w:color'), color)
        b.append(x)
    tblPr.append(b)


FIG = {'n': {}}


def fig(chapter, name, hint, height_cm=6.0):
    """grey placeholder box + caption 图c-k name"""
    k = FIG['n'].get(chapter, 0) + 1
    FIG['n'][chapter] = k
    t = d.add_table(rows=1, cols=1)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    borders(t, '7F7F7F', 'dashed', '8')
    c = t.cell(0, 0)
    c.width = Cm(15)
    shade(c, 'F2F2F2')
    tr = t.rows[0]._tr
    trPr = tr.get_or_add_trPr()
    h = OxmlElement('w:trHeight')
    h.set(qn('w:val'), str(int(height_cm * 567)))
    h.set(qn('w:hRule'), 'atLeast')
    trPr.append(h)
    q = c.paragraphs[0]
    q.alignment = WD_ALIGN_PARAGRAPH.CENTER
    fonts(q.add_run(f'【此处插入图片：图{chapter}-{k} {name}】'), 11, True, '黑体', GREY)
    for ln in hint:
        r = c.add_paragraph()
        r.alignment = WD_ALIGN_PARAGRAPH.LEFT
        r.paragraph_format.left_indent = Pt(12)
        fonts(r.add_run(ln), 10.5, False, '宋体', GREY)
    cap = para(f'图{chapter}-{k}  {name}', 10.5, False, '黑体', WD_ALIGN_PARAGRAPH.CENTER, indent=False, after=6)
    return cap


TAB = {'n': {}}


def table(chapter, name, rows, widths=None, size=10.5):
    k = TAB['n'].get(chapter, 0) + 1
    TAB['n'][chapter] = k
    para(f'表{chapter}-{k}  {name}', 10.5, False, '黑体', WD_ALIGN_PARAGRAPH.CENTER, indent=False, before=6, after=2)
    t = d.add_table(rows=len(rows), cols=len(rows[0]))
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    borders(t)
    for i, r in enumerate(rows):
        for j, v in enumerate(r):
            c = t.cell(i, j)
            if widths:
                c.width = Cm(widths[j])
            c.paragraphs[0].paragraph_format.line_spacing = 1.15
            fonts(c.paragraphs[0].add_run(str(v)), size, i == 0, '黑体' if i == 0 else '宋体')
            if i == 0:
                shade(c, 'D9E7E7')
    para('', 6, indent=False)
    return t


# ======================================================================================
title('医院候诊叫号与辅助沟通系统')

h1('摘要')
p('针对门诊候诊区叫号信息分散、听力差或说话困难的患者与医生沟通不便等问题，本作品基于两块安路 EG4S20 FPGA 开发板，'
  '设计并实现了一套“大厅屏 + 诊室屏”的医院候诊叫号与辅助沟通系统。大厅板连接 TF 卡、SDRAM、HDMI 显示器和陶晶驰'
  '串口触摸屏，负责患者自助报到、诊前登记、排队、叫号、语音播报和大屏显示；诊室板连接 HDMI 显示器和医生按键，显示本'
  '诊室当前患者的信息，并向大厅发出叫号、重播和确认求助命令。两板通过板载网口，以自定义以太网原始帧通信：命令带序号，'
  '重发直至大厅回执确认，状态逐帧广播，断链可被及时发现。')
p('在赛题基础功能上，系统从 TF 卡 FAT32 文件系统读取 BMP 图片和 PCM 音频，经 SDRAM 帧缓存，以 640×480 分辨率通过 '
  'HDMI 输出画面和 48 kHz 音频，支持按键切换、自动轮播和淡入淡出转场。扩展方面：采用“区域平均 + 双线性插值”，将 '
  '640×480～1920×1080 的图片按比例自适应缩放；自研基于 Goertzel 算法的 DFT 模块，计算 16 个频段的频谱能量，绘制频谱'
  '柱并叠加到 HDMI 画面；实现抗锯齿中文界面以及亮度、对比度、音量调节。面向特殊患者，触摸屏报到时可登记沟通需求，'
  '叫号时诊室屏依次放大对应的需求卡片，大厅屏同时提示“请留意屏幕”；患者可一键求助，诊室蜂鸣提醒并确认，两端同步显示。')
p('板上功能均由 FPGA 硬件逻辑实现，未使用处理器软核。全部模块均经仿真验证，关键模块与独立参考模型逐像素比对。'
  '大厅板逻辑资源（LUT）占用约 85%，两块板的时序均满足约束。')
q = para('', indent=False)
fonts(q.add_run('关键词：'), 12, True, '黑体')
fonts(q.add_run('FPGA；候诊叫号；以太网通信；DFT 频谱；图像缩放；辅助沟通'), 12)

# ======================================================================================
h1('第一部分  作品概述')
h2('1.1  功能与特性')
bullets([
    ('自助报到与诊前登记：', '患者在触摸屏上选择沟通需求（听力差、说话困难、头晕需搀扶、需家属或翻译，可多选）、主要症状和'
                    '难受程度后报到取号，登记信息与号码绑定。'),
    ('多诊室叫号：', '一个科室一条队列，协议支持 4 个诊室（演示 2 个）；任一诊室按“叫下一位”，大厅屏分两行显示“请 006 号 / '
              '到 02 诊室就诊”，同时语音播报。'),
    ('辅助沟通：', '诊室屏显示当前患者的需求、症状和难受程度；叫到有需求的患者时，诊室屏依次放大每张需求卡，标明“需求 1/2”；'
             '听力差患者叫号时，大厅屏闪烁“请留意屏幕”；患者可一键求助，诊室红条和蜂鸣提醒，医生确认后两端同步显示。'),
    ('多媒体大屏：', 'TF 卡图片手动切换和自动轮播，带淡入淡出转场；背景音乐；音频频谱柱；不同分辨率图片自适应；'
               '中文滚动字幕；亮度、对比度、音量调节。'),
    ('双板协同：', '以太网原始帧通信，命令带序号、重发和回执，断链可检测。'),
])
fig(1, '系统实物全景', ['拍摄内容：大厅板 + 大厅显示器 + 触摸屏（左），诊室板 + 诊室显示器 + 外接按键（右），中间网线相连；',
                     '两块屏幕都处于工作状态（大厅屏显示轮播照片和叫号区，诊室屏显示两栏诊室信息）；',
                     '建议正面或斜 45° 拍摄，桌面整洁，可在图上用箭头标注各部件名称。'], 7)

h2('1.2  应用领域')
p('本作品的主要应用场景是医院门诊候诊区：大厅屏面向候诊患者，诊室屏面向医生，二者通过网线组成分布式叫号系统。'
  '与传统叫号系统相比，本作品在叫号前就把患者的沟通需求传给医生，并在大屏上为听力差的患者增加视觉提示，适合耳鼻喉科、'
  '老年病科、康复科等特殊患者较多的科室。')
p('系统的报到、排队、叫号、语音播报和多屏联动是通用能力，稍作修改即可用于银行、政务服务大厅、车站售票、餐饮取餐等'
  '排队叫号场景。大厅屏的图片轮播、背景音乐和滚动字幕可同时承担信息发布和健康宣教功能。')
fig(1, '应用场景示意', ['可选。示意图或照片：候诊大厅（大屏 + 触摸屏报到机）与诊室（医生桌面诊室屏），用箭头表示网线连接；',
                     '可用绘图软件画简单示意，不必是真实医院照片。'], 5)

h2('1.3  主要技术特点')
bullets([
    ('纯硬件逻辑实现：', '读卡、文件系统、图像缩放、帧缓存、文字渲染、以太网 MAC、业务状态机和语音调度全部由 RTL 实现，无处理器'
                  '软核；多时钟域间信号均做同步处理。'),
    ('流式图像处理：', '边读卡边缩放，不需要整帧缓存；四张图片驻留 SDRAM，切图只更换读取地址。'),
    ('可靠的自定义链路：', '自行实现以太网 MAC 与 RGMII 收发；链路层采用命令序号去重、超时重发和执行结果回执。'),
    ('时分复用运算：', '16 个频段的 DFT 共用一套乘加单元，状态存放在块 RAM 中；中文文字引擎逐行生成字形，像素通路中没有乘除法。'),
    ('资源受限下的优化：', '小容量 ROM 放入块 RAM，计数器位宽按需取，不再使用的 EDID 读取逻辑被裁掉，使 slice 占用低于 90%，'
                    '保证布局布线工具的保持时间修复正常运行。'),
    ('系统化验证：', '关键模块均有独立的 Python 参考模型与 RTL 逐像素比对，并辅以变异测试和随机压力测试。'),
])

h2('1.4  主要性能指标')
table(1, '主要性能指标', [
    ['项目', '指标'],
    ['视频输出', 'HDMI 1.4b，640×480 @ 60 Hz，RGB 24 位，同时输出音频'],
    ['图片输入', 'TF 卡 FAT32，24 位 BMP，640×480～1920×1080 任意宽高比，等比缩放居中'],
    ['音频', '48 kHz、16 位 PCM，背景音乐与语音播报经 HDMI 输出（语音优先，切换时淡入淡出）'],
    ['频谱可视化', '自研 DFT，16 频段（60 Hz～12 kHz，对数间隔），0.5 dB/像素，动态范围 30 dB'],
    ['板间链路', '100 Mbps 以太网，原始帧 EtherType 0x88B5；状态帧约 60 帧/秒；命令约 50 ms 重发，2 s 未回执判定未送达'],
    ['诊室数量', '协议支持 4 个诊室，演示 2 个（一块诊室板模拟双诊室）'],
    ['触摸屏', 'UART 9600 波特，8N1，自定义 7 字节命令帧（带校验）'],
    ['需求卡展示', '120×90 原图双线性放大到 360×270，放大/缩回各 18 帧（约 0.3 s），停留约 5 s'],
    ['资源占用（大厅板）', 'LUT 84.86%，slice 89.59%，DSP 65.5%；时序全部满足'],
    ['资源占用（诊室板）', 'LUT 50.64%，slice 58.47%，DSP 48.3%；时序全部满足'],
], [3.5, 11.5])

h2('1.5  主要创新点')
bullets([
    '诊前登记与需求卡依次展示：沟通需求在叫号前送达医生，诊室屏逐张放大需求卡。',
    '一条队列、多诊室取号：命令序号、重发与回执保证不重号、不漏号、不串诊室。',
    '自研 Goertzel DFT 频谱：16 频段时分复用，对数域求幅值，无开方和除法。',
    '区域平均 + 双线性缩放：抑制摩尔纹，测试图 PSNR 由 10.5 dB 提高到 23.1 dB。',
    '面向听障患者的多通道提示：语音、大屏闪烁提示与诊室需求卡协同。',
])

h2('1.6  设计流程')
p('设计按“需求分析 → 方案设计 → RTL 实现 → 仿真验证 → 综合布局布线 → 上板联调”迭代进行。方案先后经历串口触摸屏（V6）、'
  '取号与双板（V7）、网线链路（V8）和多诊室报到登记等版本。每个模块先用 Python 建立参考模型，并生成字库、界面表等资源，'
  '再用 Icarus Verilog 仿真逐像素比对；随后用安路 TD 进行综合、布局布线和时序检查，最后上板联调，发现问题回到前面的环节修改。')
fig(1, '设计流程图', ['流程图：需求分析 → 方案设计（V4～V8 迭代）→ RTL 编码 → Python 参考模型 / 资源生成 → 仿真（逐像素比对、',
                   '变异测试、随机压力测试）→ TD 综合、布局布线、时序检查 → 上板联调 → 问题反馈回 RTL；用 Visio、draw.io 等绘制。'], 5)

# ======================================================================================
h1('第二部分  系统组成及功能说明')
h2('2.1  整体介绍')
p('系统由大厅子系统和诊室子系统组成，二者通过一根网线相连。大厅子系统包括大厅 FPGA 板、TF 卡、HDMI 显示器（含扬声器）'
  '和陶晶驰串口触摸屏。它保存全部业务状态：号码、队列、各诊室当前患者、登记信息和求助状态。诊室子系统包括诊室 FPGA 板、'
  'HDMI 显示器、板上按键、外接按键模块和蜂鸣器。它不保存业务状态，只显示大厅广播来的状态，并把医生的按键作为命令发给大厅。')
p('大厅板内部有三条数据通路：一是媒体通路，TF 卡读出的图片经缩放写入 SDRAM，读出后与界面文字、频谱柱叠加，经 HDMI 输出；'
  '二是音频通路，背景音乐和语音片段从 TF 卡读出，经语音优先切换和音量调节后送入 HDMI 音频；三是业务通路，触摸屏命令和诊室命令进入'
  '业务核心，核心产生叫号、语音和求助事件，驱动大屏显示、语音调度，并通过链路回传给诊室。')
fig(2, '系统整体框图', ['框图分左右两块：',
                     '大厅板：TF 卡(SPI) → FAT32 / BMP 解码 → 图像缩放 → SDRAM 帧缓存 → 显示叠加（中文界面 / 频谱柱）→ HDMI 发送 → 显示器；',
                     '        TF 卡 → PCM 音乐 / 语音片段 → 语音优先切换、音量 → HDMI 音频；触摸屏(UART) → 业务核心 ⇄ 语音调度；',
                     '        业务核心 ⇄ 链路主机 ⇄ 以太网 MAC ⇄ RGMII 网口芯片；',
                     '诊室板：网口 ⇄ 链路端点（1、2 诊室）→ 需求卡顺序器 → 诊室屏 / 需求卡放大 → HDMI；按键 → 命令发送；蜂鸣器；',
                     '两板之间画网线。标出时钟域：视频 25 MHz、SD 100 MHz、SDRAM 125 MHz、音频 12.288 MHz。'], 8)

h2('2.2  硬件系统介绍')
h3('2.2.1  硬件整体介绍')
p('硬件采用两块相同的 HX4S20C 开发板（安路 EG4S20BG256 FPGA），全部外设都是开发板板载或通过排针连接的标准模块，没有'
  '额外的处理器芯片。主要硬件见表 2-1。')
table(2, '硬件组成', [
    ['部件', '大厅板', '诊室板'],
    ['FPGA', 'EG4S20BG256', 'EG4S20BG256'],
    ['存储', 'SDRAM（4 帧图像缓存）；TF 卡（图片、音乐、语音）', 'TF 卡（需求卡图片 CARD1～CARD5）'],
    ['显示与声音', 'HDMI 显示器，音频经 HDMI 输出', 'HDMI 显示器'],
    ['通信', '板载 RTL8211E 网口（RGMII）；UART 接触摸屏', '板载 RTL8211E 网口（RGMII）'],
    ['人机交互', '陶晶驰串口触摸屏；KEY2/3/4 切图、轮播、调节；SW1～SW4', 'KEY2/3/4（1 诊室）；外接按键模块（2 诊室）；SW3/SW4；蜂鸣器'],
    ['状态指示', '数码管', '数码管（网口状态、收发计数）'],
], [3, 6.5, 5.5])
fig(2, '硬件连接示意图', ['示意图：两块 HX4S20C 开发板，标出 TF 卡座、HDMI 接口、RJ45 网口、按键、拨码开关、J1 排针',
                       '（触摸屏 TX/RX，诊室外接按键）、蜂鸣器；画出显示器、触摸屏、外接按键、网线的连接关系。'], 7)

h3('2.2.2  机械设计介绍')
p('本作品基于开发板实现，未进行专门的机械结构设计。演示时，两套设备分别摆放在大厅侧和诊室侧，用网线连接。')

h3('2.2.3  电路各模块介绍')
p('各外设与 FPGA 的连接及关键信号见表 2-2（引脚均来自工程约束文件）。HDMI 的 TMDS 差分对由 FPGA 内部串化器以 5 倍像素时钟'
  '输出；网口采用 RGMII 接口，发送数据由 125 MHz 双沿 IO 输出，接收在 RXC 下降沿采样；TF 卡工作在 SPI 模式。')
table(2, '外设接口与关键信号', [
    ['接口', '信号（引脚）', '说明'],
    ['HDMI', 'CLK C3、D0 G5、D1 F1、D2 E1；DDC SCL P2 / SDA R2', '640×480 视频 + 48 kHz 音频'],
    ['TF 卡（SPI）', 'NCS A12、DCLK A14、MOSI A13、MISO B14', 'FAT32 读文件'],
    ['网口（RGMII）', 'TXC T12、TX_CTL T7、RXC T14、RX_CTL T13；MDC L13、MDIO M13', '100M 全双工，MDIO 配置'],
    ['触摸屏（UART）', 'FPGA_RX T15（屏 TX）、FPGA_TX R14（屏 RX）', '9600 波特，8N1'],
    ['大厅按键', 'KEY1 A2 复位、KEY2 B2 下一张、KEY3 B1 亮度、KEY4 C1 轮播 / 长按上一张', '低电平有效'],
    ['大厅开关', 'SW1 C8 音量模式、SW2 C7 频谱柱、SW3 C6 对比度、SW4 C5 分辨率显示', '电平'],
    ['诊室按键', 'KEY2 B2 叫号、KEY3 B1 重播、KEY4 C1 确认求助；外接键 M15 / L16 / N16', '1 诊室 / 2 诊室'],
    ['诊室开关与蜂鸣器', 'SW4 C5 单 / 双诊室、SW3 C6 诊室号；蜂鸣器 H11（低有效）', ''],
], [3, 7.5, 4.5])
fig(2, '开发板接口标注图', ['开发板照片或官方原理图截图，用方框标出本作品使用的接口：HDMI、TF 卡座、RJ45、J1 排针（标出 T15/R14',
                        '触摸屏、M15/L16/N16 外接按键）、KEY1～KEY4、SW1～SW5、蜂鸣器、数码管。'], 7)
fig(2, '触摸屏与外接按键接线图', ['照片或示意图：陶晶驰触摸屏 TX/RX/5V/GND 与大厅板 J1 的连线；诊室外接按键模块与诊室板 J1 的连线。'], 5)

h2('2.3  软件系统介绍')
h3('2.3.1  软件整体介绍')
p('本作品的“软件”主要是两块 FPGA 板上的 Verilog 硬件逻辑，另有两个辅助部分：一是触摸屏工程，在陶晶驰 USART HMI 软件中'
  '制作报到、登记和求助页面，按钮按协议发送命令帧；二是 PC 端的 Python 工具，运行时不需要，只在开发阶段使用，用于生成'
  '中文字库和界面表、语音素材，以及充当仿真的参考模型。系统运行时不依赖电脑和云端。')
p('大厅板顶层 top_tf_hdmi_audio 下主要有：存储与媒体（SD 卡驱动、FAT32 / BMP 读取、图像缩放、SDRAM 控制与仲裁、帧读写）、'
  '显示（时序生成、淡入淡出、大厅界面、频谱柱、HDMI 发送）、音频（PCM 播放、语音播放、语音优先切换与音量、HDMI 音频打包）、'
  '业务（触摸屏接收与回写、业务核心、报到登记、语音调度）和链路（链路主机、以太网 MAC、网口芯片配置）。'
  '诊室板顶层 top_clinic 下有：两个诊室链路端点、发送仲裁、需求卡读取与存储、需求卡顺序器、诊室屏、卡片放大和 HDMI 发送。')
fig(2, '大厅板 RTL 模块层次图', ['可用 TD 的 Hierarchy 窗口截图，或按上段文字画层次图；每个模块标注功能，关键模块标注 LUT / BRAM 数量',
                           '（数据见 TD 面积报告 HDMI1.4b_Transmitter_v1.0_phy.area）。'], 7)
fig(2, '诊室板 RTL 模块层次图', ['同上，诊室工程 hospital_clinic 的模块层次。'], 5)
fig(2, '触摸屏页面设计', ['陶晶驰 USART HMI 软件中的主页（报到、请帮助我）、报到登记页（4 个需求按钮、10 个症状、0～10 难受程度）截图。'], 6)

h3('2.3.2  软件各模块介绍')
p('以下按数据流顺序介绍关键模块。')

para('（1）TF 卡读取与图片自适应缩放', 12, True, '黑体', indent=False)
p('SD 卡驱动以 SPI 模式按扇区读取。FAT32 卷扫描模块解析 MBR、BPB 和根目录，按文件名找到 PIC1～PIC4.BMP、AUDIO.PCM 和 '
  'VOICE.PCM 的起始簇，再按簇链读取文件。BMP 解码模块解析文件头，取出宽高并按行输出像素。缩放模块计算 s = min(640/W, 480/H)：'
  '先按 k = ⌊1/s⌋ 做 k×k 区域平均（低通滤波），再以 16 位小数步长、像素中心对齐做双线性插值，输出 Wo×Ho，居中写入帧缓存，'
  '四周用暖白色填充。行缓存占 3 块 32K 块 RAM，R/G/B 三个通道分时共用一条乘加流水线。')
fig(2, '图像缩放流程图', ['流程图：读 BMP 头 → 计算缩放比 s 和区域平均因子 k → 每行累加 k×k 求平均 → 双线性插值（水平、垂直）→',
                       '居中写 SDRAM（填边色 #FAFAF9）；可附 1920×1080 缩放前后对比，或三种算法的摩尔纹对比图',
                       '（delivery/image_scale_20261021/evidence/image_scale_mutations/quality_*.png）。'], 6)

para('（2）SDRAM 帧缓存与显示通路', 12, True, '黑体', indent=False)
p('四张图片各占一个逻辑帧区，加载成功后常驻 SDRAM，切图时只更换读取的帧区。读出的像素经异步 FIFO 进入 25 MHz 视频域，'
  '依次经过淡入淡出、大厅界面（文字和叫号区）和频谱柱叠加，再转成 AXI-Stream 送入 HDMI 1.4b 发送核。叠加层所用的状态只在'
  '帧起始时锁存，因此画面不会撕裂。')

para('（3）业务核心：报到、排队、叫号与求助', 12, True, '黑体', indent=False)
p('业务核心统一处理触摸屏请求（报到、求助、重播）和诊室命令（叫下一位、重播、确认求助）。报到时分配新号码，并把触摸屏上'
  '选择的需求、症状和难受程度（每号 12 位）存入登记表；叫号时取队首号码，记为发出命令的诊室的当前患者，并把语音事件放入'
  '队列；求助状态为“无 / 待回应 / 已确认”，最先确认的诊室成为负责诊室，其他诊室再确认会被拒绝。每条请求都有明确的结果：'
  '已执行、当前不可执行、忙或重复，并回写给触摸屏或诊室。')
fig(2, '业务核心状态与事件流程图', ['状态图：报到（分配号码、存登记）→ 候诊队列 → 诊室叫号（取队首、记诊室当前号、语音事件入队）→',
                              '重播；求助：无 → 待回应 → 已确认（记录负责诊室），重复和冲突的处理分支。'], 6)

para('（4）语音播报调度', 12, True, '黑体', indent=False)
p('语音素材按“请 / 数字 / 号 / 到 X 诊室就诊”等片段存放在 TF 卡 VOICE.PCM 中。调度模块把一次叫号拆成若干片段，依次读取并播放；'
  '事件队列深度为 4，播放期间新的叫号排队等待。语音优先：播报开始前背景音乐先淡出，播报结束后语音淡出、音乐淡入恢复，切换时不丢样本、无爆音。')

para('（5）双板以太网链路', 12, True, '黑体', indent=False)
p('以太网 MAC 由 FPGA 自行实现：发送时组帧（前导码、广播目的地址、本板 MAC、EtherType 0x88B5、链路帧、补零、CRC-32），'
  '接收时校验 CRC 并解出链路帧；上电后通过 MDIO 把 RTL8211E 配置为 100M 全双工。链路层定义三种帧（见表 2-3）。诊室命令带 '
  '8 位序号，约每 50 ms 重发一次，直到大厅在状态帧中回报相同的序号和执行结果；大厅对重复序号只回执、不重复执行。命令在途期间，'
  '其所属诊室固定不变，切换诊室模式也不会串到别的诊室。1 秒收不到对方的帧即判定断链。')
table(2, '链路帧类型', [
    ['帧', '方向', '内容'],
    ['状态帧 0x01（16 字节）', '大厅 → 诊室，每视频帧一次', '当前叫号、已报到、候诊人数、求助状态与负责诊室、1～4 诊室当前号、各诊室命令回执（序号 + 结果）'],
    ['登记帧 0x04（12 字节）', '大厅 → 诊室', '1～4 诊室当前患者的号码及登记（需求、症状、难受程度）'],
    ['命令帧 0x02（1 字节）', '诊室 → 大厅', '操作（叫下一位 / 重播 / 确认求助）+ 诊室号；无命令时每 0.25 s 发一次心跳帧'],
], [4, 4, 7])
fig(2, '链路帧格式与命令时序图', ['上半：以太网帧结构（前导码 | 目的 MAC | 源 MAC | 0x88B5 | 链路帧 A5 类型 序号 长度 数据 CRC8 | 补零 | CRC-32）；',
                            '下半：时序图，诊室按键 → 命令帧（序号 n）→ 丢帧 → 50 ms 后重发 → 大厅执行 → 状态帧回执 n → 诊室显示“已执行”。'], 6)

para('（6）触摸屏通信', 12, True, '黑体', indent=False)
p('触摸屏按钮在弹起事件中发送 7 字节命令帧“5A cmd arg chk FF FF FF”（chk = 5A⊕cmd⊕arg），FPGA 校验后转为业务请求，'
  '并把“报到成功：007 号，前面还有 3 人”“2 诊室已收到，马上到”等结果写回触摸屏的文本框。')

para('（7）中文抗锯齿界面引擎', 12, True, '黑体', indent=False)
p('两块屏的文字由同一个文字引擎绘制。界面上每个文本位置称为“槽位”，每个槽位有坐标、字体和字符串。引擎在行消隐期间为下一行'
  '生成字形描述符，存入乒乓缓存，显示时只按 x 坐标查表，像素通路中没有乘除法。字形每像素 4 级覆盖度，与背景按比例混合，'
  '实现抗锯齿。字库、字符串表和槽位表由 Python 生成器根据界面描述自动生成，存入块 RAM，生成器同时检查字高和槽位冲突。')
fig(2, '文字引擎数据流图', ['数据流：槽位表 → 字符串表 → 字形表 → 字形 ROM（4 级覆盖度）→ 行描述符乒乓缓存 → 与背景混合输出；',
                         '可附一张大厅屏局部放大截图，展示抗锯齿效果。'], 5)

para('（8）自研 DFT 音频频谱', 12, True, '黑体', indent=False)
p('每个频段只需要一个频点，因此采用 Goertzel 算法实现 DFT，而不是完整的 FFT。16 个频段的中心频率为 60 Hz～12 kHz，按对数间隔'
  '分布。每来一个 48 kHz 采样，16 个频段依次共用同一套乘加单元：s0 = x·w(n) + 2cos(ω)·s1 − s2，其中 w(n) 为 32 级 Hann 窗。'
  '低频段块长 2048 点、高频段 32 点，使每个频点的宽度约为中心频率的三分之一；各频段块起点错开，同一采样上最多一个频段到达块尾。'
  '块尾得到 (re, im) 后，在对数域求幅值：log|X| = max(log|re|, log|im|) + G(差值)，不需要开方和除法，再换算为 0～61 像素的柱高。'
  '柱子每帧回落 2 像素，峰值帽缓慢下落，在帧起始时统一更新，在 HDMI 输出前叠加。')
fig(2, '频谱模块结构与效果', ['左：结构框图（PCM 采样 → Hann 窗 → Goertzel 迭代（状态 RAM，16 频段时分）→ 块尾求 re/im → 对数域幅值 → 柱高 → 叠加）；',
                           '右：扫频测试效果，可用 delivery/spectrum_20261029/preview/sweep_stills.png，展示单音从低频到高频时亮柱从左移到右。'], 6)

para('（9）诊室需求卡顺序器与放大动画', 12, True, '黑体', indent=False)
p('需求卡顺序器为每位新患者建立一个任务（诊室、号码、需求集合），放卡时冻结患者、诊室和“需求 i/n”，逐张交给卡片视图放大：'
  '先等前一张完整显示，再放下一张。被求助卡打断的需求卡会补放一次；同一诊室叫了下一位时，旧患者剩余的卡作废；切换诊室模式或'
  '断链时，排队中的任务全部作废，避免串患者。卡片视图把 120×90 的原图用双线性插值放大到 360×270，放大和缩回各 18 帧，'
  '按缓出曲线查表变化，背景压暗。')
fig(2, '需求卡展示流程', ['流程图：新患者登记到达 → 建立任务（冻结诊室、号码、需求集合）→ 放第 i 张卡（放大 → 停留 5 s → 缩回）→ 是否被打断？',
                       '（是：补放一次）→ i < n？→ 结束；旁注：同诊室来新患者 / 切换模式 / 断链时的处理。'], 6)

para('（10）HDMI 音视频输出', 12, True, '黑体', indent=False)
p('HDMI 输出采用安路提供的 HDMI 1.4b 发送核：视频以 AXI-Stream 输入，音频以 48 kHz 采样送入，并由音频时钟再生模块计算 CTS/N，'
  'TMDS 数据经 10:1 串化输出。本作品固定输出 640×480，不读取显示器的 EDID。')

# ======================================================================================
h1('第三部分  完成情况及性能参数')
h2('3.1  整体介绍')
p('作品已完成大厅板、诊室板和触摸屏三部分的设计与联调，实现了第一部分所述的全部功能。整体实物见图 3-1、图 3-2。')
fig(3, '系统实物正面照片', ['正面拍摄：两套设备全部工作，屏幕内容清晰可辨（大厅：照片轮播 + 叫号区；诊室：两栏诊室信息）。'], 7)
fig(3, '系统实物斜 45° 照片', ['斜 45° 拍摄，体现板子、屏幕、触摸屏、网线的空间关系。'], 7)

h2('3.2  工程成果')
h3('3.2.1  机械成果')
p('本作品不涉及机械结构。')
h3('3.2.2  电路成果')
fig(3, '大厅板接线实物', ['大厅板特写：TF 卡、HDMI 线、网线、触摸屏排线已接好，数码管点亮。'], 6)
fig(3, '诊室板接线实物', ['诊室板特写：HDMI 线、网线、外接按键模块、TF 卡已接好；数码管显示网口状态 4（100M 已连通）。'], 6)
h3('3.2.3  软件成果')
fig(3, '大厅屏界面', ['采集卡或手机正面拍摄的大厅屏：全屏照片、顶栏（科室名、网口与诊室在线状态）、两行叫号区、各诊室当前号、',
                   '求助状态、底部滚动字幕；最好再拍一张拨上 SW2 后带频谱柱的画面。'], 7)
fig(3, '诊室屏界面', ['诊室屏：双诊室两栏，当前号码、沟通需求（红字）、主要症状、难受程度、操作结果；',
                   '可用仿真截图 delivery/clinic_seq_20261030/screens/rtl_clinic_seq_back_normal.png 或上板实拍。'], 7)
fig(3, '需求卡依次放大', ['两张并排：“听力差 请书写（需求 1/2）”和“需家属或翻译（需求 2/2）”；',
                       '仿真截图见 delivery/clinic_seq_20261030/screens/rtl_clinic_seq_need1of2.png、rtl_clinic_seq_need2of2.png，建议换成上板实拍。'], 6)
fig(3, '触摸屏报到与求助页面', ['实拍触摸屏：报到登记页（已勾选需求）和报到成功回显“报到成功：00X 号，前面还有 X 人”。'], 6)
fig(3, '自适应分辨率效果', ['同一屏幕上两张不同分辨率图片的显示效果（如 PIC1 1920×1080 与 PIC3 1280×720，缩放后大小相同），',
                         '拨上 SW4 后底行显示板子读到的原图分辨率。'], 6)

h2('3.3  特性成果')
p('功能验证分仿真和上板两部分。仿真部分用独立参考模型逐像素比对，并辅以变异测试和随机压力测试，结果见表 3-1。'
  '资源和时序为安路 TD 综合、布局布线后的报告，见表 3-2。上板实测项见表 3-3。')
table(3, '仿真验证结果', [
    ['验证项', '方法', '结果'],
    ['多诊室业务与链路', '1 块大厅 + 4 个诊室端点随机压力测试（报到、叫号、重播、求助、同时按键）', '20 天 1400 次操作，0 违规'],
    ['命令归属', '命令在途时切换诊室', '只执行一次，归属原诊室'],
    ['需求卡依次展示', '11 个场景（多需求、双诊室、求助打断、换患者、切模式、断链、复位等）', '全部通过；7 处故意改坏全部查出'],
    ['大厅屏显示', '8 组场景，与参考模型逐像素比对', '8/8 通过'],
    ['诊室屏显示', '22 帧与参考模型逐像素比对', '全部一致'],
    ['DFT 频谱', '两组随机音频，逐像素比对；15 处故意改坏', '全部一致；15/15 查出'],
    ['图像缩放', '多种尺寸 BMP 与参考模型比对；摩尔纹测试', 'PSNR 23.1 dB（普通双线性 10.5 dB）'],
    ['触摸屏协议', '26 次报到流程经真实串口接收和业务模块', '全部通过'],
], [3.2, 7.5, 4.3], size=10)
table(3, '资源占用与时序（TD 报告）', [
    ['项目', '大厅板', '诊室板'],
    ['Slice', '89.59%', '58.47%'],
    ['LUT', '16632 / 19600（84.86%）', '9926 / 19600（50.64%）'],
    ['寄存器', '9901 / 19600（50.52%）', '5928 / 19600（30.24%）'],
    ['9K 块 RAM / 32K 块 RAM', '56 / 64，13 / 16', '62 / 64，16 / 16'],
    ['DSP', '19 / 29', '14 / 29'],
    ['建立 / 保持时间余量', '+0.048 ns / +0.003 ns，0 违例', '+0.263 ns / +0.003 ns，0 违例'],
], [4.5, 5.25, 5.25])
table(3, '上板实测（请按实测结果填写）', [
    ['项目', '测试方法', '结果'],
    ['上电到出图时间', '上电计时至大厅屏出现第一张图片', '（待填）'],
    ['叫号响应时间', '诊室按键至大厅屏显示和语音开始', '（待填）'],
    ['连续运行', '自动轮播 + 背景音乐连续运行', '（待填，如 2 小时无异常）'],
    ['断链恢复', '拔插网线，观察链路状态和命令结果', '（待填）'],
    ['自动轮播间隔', '秒表测量', '（待填）'],
], [3.5, 7, 4.5])
fig(3, '现场测试照片', ['可选：秒表计时、拔网线测试、频谱柱随扫频音变化等测试现场照片。'], 5)

# ======================================================================================
h1('第四部分  总结')
h2('4.1  可扩展之处')
p('一是诊室数量扩展：链路协议已按 4 个诊室设计，增加诊室板即可组网，进一步可扩展为多科室，并加入预约与复诊优先等排队策略。'
  '二是求助管理增强：给每条求助编号，增加等待计时和超时升级提醒。三是显示升级：图片和需求卡改用更高分辨率，输出 720p 或 '
  '1080p。四是数据持久化：把参数和当日号码写入 Flash，掉电后可恢复。五是接入医院信息系统：通过网口与 HIS 交换挂号数据。')

h2('4.2  心得体会')
p('这个作品从基础例程起步，一路做成了两块板、三块屏的完整系统。回头看，收获最大的有以下几点。')
p('第一，“能跑”和“可靠”之间差得很远。双板通信最初用 J2 杜邦线，从未丢过帧；换成网线后，偶尔有一次按键“没反应”。排查发现，'
  '诊室把任何一个状态帧都当作“已收到”，而大厅每帧都会发状态，命令帧在网线上丢了也察觉不到。后来改成“大厅回报执行过的序号，'
  '诊室重发到序号一致为止”，问题才彻底解决。这让我们体会到，协议设计要先想清楚“出错时会怎样”。')
p('第二，资源是硬约束。大厅板功能越加越多，slice 一度超过 90%。这时布局布线工具会跳过保持时间修复，时序报告出现保持违例，'
  '上板可能不稳定。我们没有用时序例外去掩盖，而是逐个模块找冗余：小 ROM 改放块 RAM、计数器位宽按需取、去掉从未使用的 EDID '
  '读取逻辑，每次修改后再扫描布局种子，确认占用低于 90% 且时序满足。')
p('第三，先建模型、再写硬件，效率最高。频谱、缩放、文字引擎这些模块，我们都先用 Python 写出与硬件逐位一致的参考模型，再让 '
  'RTL 仿真结果和模型逐像素比对，并故意改坏代码，检查测试能否发现。很多边界问题，例如柱子到顶后峰值帽看不见、仿真看门狗计数溢出，'
  '都是在仿真阶段发现的，节省了大量上板调试时间。')
p('第四，细节决定体验。手动切图时音乐会断约半秒，原因是早期代码让音乐跟着画面淡出一起变小；触摸屏点击会让轮播卡住；滚动字幕偶尔'
  '闪一下……这些问题单看都不大，但都会影响用户感受。我们逐一找到根因并修复，而不是绕开它们。')
p('第五，从需求出发做设计。最初的方案是让患者在触摸屏上点“请写下来”“请再说一遍”等表达卡。讨论后我们改为在报到时登记沟通需求，'
  '叫号时直接送到医生面前，功能更少，却更贴近真实就诊流程。')
p('通过这次竞赛，我们完整经历了需求分析、方案迭代、RTL 设计、验证、时序收敛和上板联调的全过程，对 FPGA 系统设计有了更深的理解。')

# ======================================================================================
h1('第五部分  参考文献')
refs = [
    '上海安路信息科技股份有限公司. EG4 系列 FPGA 器件数据手册[Z]. 上海: 安路科技.',
    '上海安路信息科技股份有限公司. TD 软件用户手册 V6.2[Z]. 上海: 安路科技.',
    '全国大学生嵌入式芯片与系统设计竞赛组委会. 2026 FPGA 赛道选题指南（安路科技）[Z]. 2026.',
    'HDMI Licensing, LLC. High-Definition Multimedia Interface Specification Version 1.4b[S]. 2011.',
    'Consumer Technology Association. CTA-861: A DTV Profile for Uncompressed High Speed Digital Interfaces[S].',
    'Microsoft Corporation. Microsoft Extensible Firmware Initiative FAT32 File System Specification, Version 1.03[S]. 2000.',
    'SD Association. SD Specifications Part 1: Physical Layer Simplified Specification[S].',
    'IEEE. IEEE Std 802.3: IEEE Standard for Ethernet[S]. New York: IEEE.',
    'Realtek Semiconductor Corp. RTL8211E Integrated 10/100/1000M Ethernet Transceiver Datasheet[Z].',
    'Goertzel G. An Algorithm for the Evaluation of Finite Trigonometric Series[J]. The American Mathematical Monthly, 1958, 65(1): 34-35.',
    'Harris F J. On the Use of Windows for Harmonic Analysis with the Discrete Fourier Transform[J]. Proceedings of the IEEE, 1978, 66(1): 51-83.',
    'Oppenheim A V, Schafer R W. Discrete-Time Signal Processing[M]. 3rd ed. Upper Saddle River: Prentice Hall, 2010.',
    'Gonzalez R C, Woods R E. Digital Image Processing[M]. 4th ed. New York: Pearson, 2018.',
    '深圳市陶晶驰电子科技有限公司. USART HMI 指令集[Z].',
]
for i, r in enumerate(refs, 1):
    q = para('', 10.5, indent=False, line=1.3)
    q.paragraph_format.left_indent = Pt(21)
    q.paragraph_format.first_line_indent = Pt(-21)
    fonts(q.add_run(f'[{i}] {r}'), 10.5)

d.save(str(OUT))
print('wrote', OUT)
