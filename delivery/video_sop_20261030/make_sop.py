"""10/30: build the team's video shooting SOP (pptx) for 医院候诊叫号与辅助沟通系统, following the
structure of FPGA竞赛作品视频拍摄SOP.pptx (five parts, 3 min, checklists) with this project's real
controls, files and figures. Usage: python make_sop.py  ->  拍摄SOP_医院候诊叫号与辅助沟通系统.pptx
"""
from pathlib import Path

from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.util import Inches, Pt

HERE = Path(__file__).resolve().parent
OUT = HERE / '拍摄SOP_医院候诊叫号与辅助沟通系统.pptx'
FONT = '微软雅黑'
TEAL, AMBER, INK, GREY, PAGE, RED, PALE = (RGBColor(0x0E, 0x6E, 0x6E), RGBColor(0xF0, 0x8C, 0x00),
                                           RGBColor(0x1F, 0x29, 0x33), RGBColor(0x6B, 0x72, 0x80),
                                           RGBColor(0xFA, 0xFA, 0xF9), RGBColor(0xC2, 0x41, 0x0C),
                                           RGBColor(0xE6, 0xF0, 0xF0))
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

prs = Presentation()
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
BLANK = prs.slide_layouts[6]


def run(p, text, size=16, bold=False, color=INK):
    r = p.add_run()
    r.text = text
    f = r.font
    f.name, f.size, f.bold, f.color.rgb = FONT, Pt(size), bold, color
    rpr = r._r.get_or_add_rPr()
    ea = rpr.find('{http://schemas.openxmlformats.org/drawingml/2006/main}ea')
    if ea is None:
        ea = rpr.makeelement('{http://schemas.openxmlformats.org/drawingml/2006/main}ea', {})
        rpr.append(ea)
    ea.set('typeface', FONT)
    return r


def box(slide, x, y, w, h, fill=None, line=None):
    s = slide.shapes.add_shape(1, Inches(x), Inches(y), Inches(w), Inches(h))
    if fill is None:
        s.fill.background()
    else:
        s.fill.solid()
        s.fill.fore_color.rgb = fill
    if line is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line
    s.shadow.inherit = False
    return s


def text(slide, x, y, w, h, lines, size=16, color=INK, bold=False, align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP,
         spacing=1.15):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    tf.vertical_anchor = anchor
    tf.margin_left = tf.margin_right = Inches(0.05)
    for i, ln in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = spacing
        parts = ln if isinstance(ln, list) else [(ln, {})]
        for t, kw in parts:
            run(p, t, kw.get('size', size), kw.get('bold', bold), kw.get('color', color))
    return tb


def header(slide, no, title, sub=None):
    box(slide, 0, 0, 13.333, 7.5, fill=PAGE)
    box(slide, 0, 0, 0.18, 7.5, fill=TEAL)
    text(slide, 0.55, 0.35, 12, 0.4, [no], size=13, color=AMBER, bold=True)
    text(slide, 0.55, 0.62, 12.2, 0.7, [title], size=28, bold=True, color=INK)
    if sub:
        text(slide, 0.55, 1.28, 12.2, 0.45, [sub], size=15, color=GREY)
    box(slide, 0.55, 1.78, 12.2, 0.02, fill=RGBColor(0xE2, 0xE5, 0xE9))


def note(slide, s, y=6.72, color=RED):
    box(slide, 0.55, y, 12.2, 0.5, fill=RGBColor(0xFD, 0xF1, 0xE7))
    text(slide, 0.7, y + 0.04, 11.9, 0.45, [s], size=14, color=color, bold=True, anchor=MSO_ANCHOR.MIDDLE)


def table(slide, x, y, w, rows, widths, size=12, head_fill=TEAL, row_h=0.36):
    nr, nc = len(rows), len(rows[0])
    t = slide.shapes.add_table(nr, nc, Inches(x), Inches(y), Inches(w), Inches(row_h * nr)).table
    for j, cw in enumerate(widths):
        t.columns[j].width = Inches(cw)
    for i, r in enumerate(rows):
        t.rows[i].height = Inches(row_h)
        for j, v in enumerate(r):
            c = t.cell(i, j)
            c.margin_left = c.margin_right = Inches(0.06)
            c.margin_top = c.margin_bottom = Inches(0.03)
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.fill.solid()
            c.fill.fore_color.rgb = head_fill if i == 0 else (WHITE if i % 2 else PALE)
            tf = c.text_frame
            tf.word_wrap = True
            for k, ln in enumerate(str(v).split('\n')):
                p = tf.paragraphs[0] if k == 0 else tf.add_paragraph()
                run(p, ln, size, bold=i == 0, color=WHITE if i == 0 else INK)
    return t


def card(slide, x, y, w, h, title, lines, accent=TEAL, size=14):
    box(slide, x, y, w, h, fill=WHITE, line=RGBColor(0xE2, 0xE5, 0xE9))
    box(slide, x, y, w, 0.08, fill=accent)
    text(slide, x + 0.15, y + 0.18, w - 0.3, 0.45, [title], size=16, bold=True, color=accent)
    text(slide, x + 0.15, y + 0.62, w - 0.3, h - 0.7, lines, size=size)


# ---------------- 1 cover ----------------
s = prs.slides.add_slide(BLANK)
box(s, 0, 0, 13.333, 7.5, fill=TEAL)
box(s, 0.8, 2.1, 0.12, 2.3, fill=AMBER)
text(s, 1.15, 1.9, 11, 0.6, ['2026 FPGA 赛道 · 安路 EG4S20 · 作品展示视频'], size=18, color=RGBColor(0xCC, 0xE3, 0xE3))
text(s, 1.15, 2.5, 11.5, 1.2, ['医院候诊叫号与辅助沟通系统'], size=44, bold=True, color=WHITE)
text(s, 1.15, 3.55, 11.5, 0.8, ['展示视频拍摄 SOP（本作品专用版）'], size=28, color=WHITE)
text(s, 1.15, 4.7, 11.5, 1.2, ['依据《FPGA竞赛作品视频拍摄SOP》五段式结构，按本作品的实际功能、按键、文件与数据填写',
                              '大厅板 + 诊室板 + 陶晶驰触摸屏 · 总时长 3:00 · 1080p 横屏'], size=16,
     color=RGBColor(0xCC, 0xE3, 0xE3))
text(s, 1.15, 6.6, 11, 0.4, ['版本 2026-10-30 · 拍摄前请先完成第 14 节“开拍前必须确认”'], size=14, color=AMBER, bold=True)

# ---------------- 2 positioning ----------------
s = prs.slides.add_slide(BLANK)
header(s, '01 · 本片定位', '一句话讲清：这是什么、给谁用、解决什么问题')
card(s, 0.55, 2.05, 6.0, 2.3, '一句话定位（开场口播用）',
     ['面向医院门诊候诊区，用两块安路 EG4S20 FPGA 板通过网线组成“大厅屏 + 诊室屏”，',
      '实现自助报到、多诊室叫号与语音播报，并为听力差、说话困难等特殊患者提供辅助沟通。'], size=15)
card(s, 6.75, 2.05, 6.0, 2.3, '评委需要在 3 分钟内记住的三件事', [
    '① 赛题基础功能全部到位：TF 读图、HDMI 640×480、切图、轮播、48 kHz 音频',
    '② 两个扩展要求做实：自研 DFT 音频频谱柱、自适应分辨率',
    '③ 真实场景闭环：报到 → 叫号 → 需求卡 → 求助 → 确认'], accent=AMBER, size=15)
table(s, 0.55, 4.6, 12.2, [
    ['成片规格', '要求'],
    ['分辨率 / 格式', '1920×1080，MP4（H.264），横屏 16:9，高码率导出'],
    ['时长', '3:00 左右，最长不超过 3:15'],
    ['声音', '配音后期录制；板子音乐与语音播报用采集卡录 HDMI 声音，不用手机外放收音'],
    ['字幕', '每个功能配“基础功能 X / 扩展功能 X：名称”，参数用字幕标注'],
], [2.6, 9.6], size=13)

# ---------------- 3 structure ----------------
s = prs.slides.add_slide(BLANK)
header(s, '02 · 整体结构', '五段式，总时长 3 分钟', '先让评委知道是什么 → 逐项核对赛题功能 → 用医院场景证明作品价值')
segs = [('开场定位', '0:00–0:10', '10 秒', '作品名称\n一句话定位\n两板三屏全景'),
        ('基础功能', '0:10–0:35', '25 秒', 'TF 读图 · HDMI\n手动切图 · 自动轮播\n48 kHz 音频'),
        ('扩展功能', '0:35–1:10', '35 秒', '频谱柱（DFT）\n自适应分辨率\n淡入淡出 · 中文 OSD'),
        ('主题化演示', '1:10–2:35', '85 秒', '报到 → 叫号 → 语音\n需求卡依次展示\n求助 → 确认 → 恢复'),
        ('结尾总结', '2:35–3:00', '25 秒', '三个亮点\n资源占用\n可靠性')]
for i, (n, t, d, c) in enumerate(segs):
    x = 0.55 + i * 2.48
    acc = AMBER if n == '主题化演示' else TEAL
    box(s, x, 2.15, 2.3, 0.75, fill=acc)
    text(s, x, 2.15, 2.3, 0.75, [n], size=20, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    text(s, x, 3.0, 2.3, 0.4, [t], size=14, color=GREY, align=PP_ALIGN.CENTER)
    text(s, x, 3.35, 2.3, 0.5, [d], size=22, bold=True, color=acc, align=PP_ALIGN.CENTER)
    box(s, x, 4.0, 2.3, 1.8, fill=WHITE, line=RGBColor(0xE2, 0xE5, 0xE9))
    text(s, x + 0.1, 4.12, 2.1, 1.6, c.split('\n'), size=15, align=PP_ALIGN.CENTER)
note(s, '本作品功能多：主题化演示是“记忆点”，给足 85 秒；基础功能每项约 5 秒，一次成功，不现场调试', y=6.2)

# ---------------- 4 opening ----------------
s = prs.slides.add_slide(BLANK)
header(s, '03 · 第一段 / 开场定位（0:00–0:10）', '让评委 10 秒内看懂“这是什么”')
table(s, 0.55, 2.05, 7.2, [
    ['镜头', '画面', '时长'],
    ['1-1', '片头字幕：作品名称居中，停留 3 秒\n（可叠在大厅屏轮播画面上）', '3 秒'],
    ['1-2', '实物全景：大厅板 + 大厅显示器 + 触摸屏，\n网线连到诊室板 + 诊室显示器，一个摇镜带过', '4 秒'],
    ['1-3', '大厅屏画面（采集卡）：照片轮播 + 叫号区 + 字幕', '3 秒'],
], [0.8, 5.4, 1.0], size=13, row_h=0.62)
card(s, 8.0, 2.05, 4.75, 3.1, '口播稿（约 9 秒）', [
    '“本作品名为',
    '《医院候诊叫号与辅助沟通系统》，',
    '面向医院门诊候诊区，',
    '基于两块安路 EG4S20 FPGA，',
    '实现了图片轮播、音频输出、多诊室叫号，',
    '以及面向特殊患者的辅助沟通。”'], accent=AMBER, size=15)
text(s, 0.55, 5.0, 7.2, 1.2, ['摆位建议：两套设备左右排开，大厅在左、诊室在右，中间露出网线，',
                              '体现“双板协同”；桌面清空，只留板子、屏幕、触摸屏和线。'], size=14, color=GREY)
note(s, '避坑：开场不讲 PLL、SDRAM、Goertzel 等技术细节；先讲“是什么、解决什么问题”')

# ---------------- 5 basic ----------------
s = prs.slides.add_slide(BLANK)
header(s, '04 · 第二段 / 基础功能（0:10–0:35）', '赛题基础功能逐项展示，一项都不能漏', '每项约 5 秒，必须一次成功')
table(s, 0.55, 2.0, 12.2, [
    ['序号', '基础功能', '展示动作（大厅板）', '画面要点 / 字幕'],
    ['01', 'TF 卡图片读取', '插着 TF 卡上电（或按 KEY1 复位），屏幕出图', '字幕“基础功能1：TF 卡 BMP 图片读取（FAT32）”'],
    ['02', 'HDMI 画面输出', '采集卡录大厅屏完整画面，停 3 秒', '字幕“基础功能2：HDMI 640×480 稳定输出”'],
    ['03', '手动切换', '短按 KEY2 下一张；长按 KEY4 ≥1 秒上一张', '手部按键特写 + 屏幕淡入淡出切图\n字幕“基础功能3：按键上一张 / 下一张”'],
    ['04', '自动轮播', '短按 KEY4 开启自动轮播，连续切 2 张', '字幕“基础功能4：自动轮播（间隔 X 秒）”\n（间隔以拍摄当天实测为准）'],
    ['05', '48 kHz 音频输出', '背景音乐从 TF 卡 AUDIO.PCM 播放，经 HDMI 输出', '字幕“基础功能5：48 kHz 音频经 HDMI 输出”\n声音用采集卡录'],
], [0.8, 2.0, 4.6, 4.8], size=13, row_h=0.62)
note(s, '注意：SW1 必须拨下（拨上时 KEY2/KEY3/KEY4 变成调音量）；不要出现“等一下、没反应”的画面', y=6.0)

# ---------------- 6 extensions ----------------
s = prs.slides.add_slide(BLANK)
header(s, '05 · 第三段 / 扩展功能（0:35–1:10）', '亮点先行，每项讲清“做了什么、看效果”')
table(s, 0.55, 2.0, 12.2, [
    ['顺序', '扩展功能', '操作', '画面要点 / 字幕', '时长'],
    ['01', '音频频谱可视化\n（扩展要求5）', '播放音乐，拨上 SW2', '16 根柱子：左低音 60 Hz → 右高音 12 kHz，峰值帽回落\n字幕“自研 DFT（Goertzel）16 频段频谱，HDMI 输出前叠加”', '12 秒'],
    ['02', '自适应分辨率\n（扩展要求3）', '切到 PIC1（1920×1080）再切 PIC3（1280×720），拨上 SW4', '两张不同分辨率的 16:9 图缩放后画面大小相同；\n底行显示板子读到的原图分辨率', '10 秒'],
    ['03', '淡入淡出转场', '切图时自然出现', '字幕“扩展：帧淡入淡出转场”', '4 秒'],
    ['04', '中文 OSD 与调节', 'KEY3 调亮度；SW3 拨上后 KEY3 调对比度；\nSW1 拨上后 KEY2/KEY4 调音量', '抗锯齿中文界面、滚动字幕；调节时底行显示数值', '9 秒'],
], [0.8, 2.0, 3.6, 4.8, 1.0], size=12, row_h=0.78)
note(s, '口播要点：频谱柱讲“频谱”不讲“波形”——鼓点在左、镲片在右；自适应分辨率强调“板子自己读文件头、自己缩放”', y=6.2)

# ---------------- 7 story ----------------
s = prs.slides.add_slide(BLANK)
header(s, '06 · 第四段 / 主题化演示（1:10–2:35）', '用一位“听力差、需要翻译”的患者，把全部业务走一遍')
stages = [('日常状态', '大厅轮播照片 + 音乐 + 频谱柱\n叫号区显示“等待叫号”\n诊室屏显示两个诊室', TEAL),
          ('事件触发', '患者在触摸屏报到，\n勾选“听力差”“需家属或翻译”\n屏幕回显“报到成功：00X 号”', TEAL),
          ('叫号与沟通', '医生按 KEY2 叫号：\n大厅两行叫号 + 语音播报 +“请留意屏幕”\n诊室依次放大需求卡 1/2、2/2', AMBER),
          ('求助与恢复', '患者按“请帮助我”：诊室红条 + 蜂鸣\n医生按 KEY4 确认 →“X 诊室已确认求助”\n画面回到日常轮播', AMBER)]
for i, (n, c, acc) in enumerate(stages):
    x = 0.55 + i * 3.1
    box(s, x, 2.1, 2.9, 0.7, fill=acc)
    text(s, x, 2.1, 2.9, 0.7, [n], size=20, bold=True, color=WHITE, align=PP_ALIGN.CENTER, anchor=MSO_ANCHOR.MIDDLE)
    box(s, x, 2.9, 2.9, 2.2, fill=WHITE, line=RGBColor(0xE2, 0xE5, 0xE9))
    text(s, x + 0.12, 3.05, 2.66, 2.0, c.split('\n'), size=14)
text(s, 0.55, 5.3, 12.2, 1.0, ['拍摄要点：① 整段一次走完，不中断、不调试；② 配音提前写好，后期配；③ 三块屏同时录（见第 10 节机位）；',
                              '④ 操作者提前排练，按键节奏与配音对齐；⑤ 每个画面切换处配字幕“主题演示：报到 / 叫号 / 求助”'], size=14, color=GREY)
note(s, '这一段是记忆点：评委看完应能复述“患者报到后，诊室医生在叫号时就知道他听力差、需要翻译”', y=6.35)

# ---------------- 8 shot list ----------------
s = prs.slides.add_slide(BLANK)
header(s, '07 · 主题化演示分镜表', '按时间顺序拍；括号内为主要机位')
table(s, 0.55, 1.95, 12.2, [
    ['时间', '动作', '画面（机位）', '口播 / 字幕要点'],
    ['1:10', '日常状态', '大厅屏全画面（采集卡 A）', '“候诊区大屏平时轮播健康宣教图片和音乐”'],
    ['1:18', '患者走到触摸屏，点“报到”', '手部 + 触摸屏特写（手机）', '“患者自助报到，可登记沟通需求和主要症状”'],
    ['1:28', '勾选听力差、需家属或翻译，确认报到', '触摸屏特写 → 回显号码', '字幕“报到成功：00X 号”'],
    ['1:38', '医生按诊室板 KEY2 叫下一位', '诊室板按键特写（手机）', '“1 诊室医生按键叫号，命令经网线发到大厅板”'],
    ['1:42', '大厅叫号 + 语音播报', '大厅屏（采集卡 A），声音录 HDMI', '两行“请 00X 号 / 到 01 诊室就诊”+“请留意屏幕”胶囊'],
    ['1:50', '诊室需求卡依次放大', '诊室屏（采集卡 B）', '“听力差 1/2”→“需家属或翻译 2/2”，每张约 5 秒'],
    ['2:05', '患者点“请帮助我”', '触摸屏特写 → 大厅“待回应”', '“遇到困难可一键求助”'],
    ['2:12', '诊室红条闪烁 + 蜂鸣', '诊室屏 + 板子（采集卡 B / 手机）', '字幕“诊室蜂鸣提醒”'],
    ['2:20', '医生按 KEY4 确认求助', '按键特写 → 两屏显示已确认', '“1 诊室已确认求助”，大厅同步'],
    ['2:28', '回到日常轮播', '大厅屏全画面', '“处理完毕，系统回到日常状态”'],
], [0.9, 3.6, 3.7, 4.0], size=12, row_h=0.4)
note(s, '求助卡会打断需求卡：拍需求卡时不要按求助，等 2/2 放完再求助，画面最干净', y=6.55)

# ---------------- 9 ending ----------------
s = prs.slides.add_slide(BLANK)
header(s, '08 · 第五段 / 结尾总结（2:35–3:00）', '收束全片：亮点 + 数据 + 可靠性')
card(s, 0.55, 2.05, 4.0, 3.1, '三个核心亮点', ['① 双板网线协同的多诊室叫号，命令带序号、重发与确认',
                                           '② 自研 DFT 16 频段音频频谱柱',
                                           '③ 面向特殊患者的辅助沟通：报到登记需求、诊室依次展示需求卡、一键求助'], size=14)
table(s, 4.75, 2.05, 8.0, [
    ['资源占用（TD 报告）', '大厅板', '诊室板'],
    ['Slice', '89.59%', '58.47%'],
    ['LUT', '84.86%', '50.64%'],
    ['寄存器', '50.52%', '30.24%'],
    ['9K BRAM / 32K BRAM', '87.5% / 81.3%', '96.9% / 100%'],
    ['DSP', '65.5%', '48.3%'],
    ['时序', 'setup / hold 全部满足', 'setup / hold 全部满足'],
], [3.0, 2.5, 2.5], size=13, row_h=0.42)
card(s, 0.55, 5.3, 12.2, 1.25, '结尾口播稿（约 22 秒）', [
    '“本作品基于两块安路 EG4S20，实现了多诊室叫号、语音播报、音频频谱可视化与自适应分辨率，核心亮点是双板协同、自研 DFT 频谱和辅助沟通。'
    '大厅板逻辑资源占用约 85%，时序全部满足，可应用于医院、银行、政务大厅等排队叫号场景。”'], accent=AMBER, size=14)
note(s, '表中数字来自 10/29–10/30 无界面 TD 检查；成片前请用 GUI 实际编译报告核对后再上字幕', y=6.72)

# ---------------- 10 timing ----------------
s = prs.slides.add_slide(BLANK)
header(s, '09 · 时间分配总表', '总时长控制在 3:00，超时优先压缩扩展功能里的简单项')
table(s, 0.55, 2.0, 12.2, [
    ['段落', '内容', '时长', '累计'],
    ['第一段', '开场：名称、定位、两板三屏全景', '10 秒', '0:10'],
    ['第二段', '基础功能 5 项：TF 读图、HDMI、手动切图、自动轮播、48 kHz 音频', '25 秒', '0:35'],
    ['第三段', '扩展功能：频谱柱、自适应分辨率、淡入淡出、中文 OSD 与调节', '35 秒', '1:10'],
    ['第四段', '主题化演示：报到 → 叫号 → 语音 → 需求卡 → 求助 → 确认 → 恢复', '85 秒', '2:35'],
    ['第五段', '结尾：三个亮点、资源占用、可靠性', '25 秒', '3:00'],
], [1.4, 7.8, 1.4, 1.6], size=14, row_h=0.55)
text(s, 0.55, 5.6, 12.2, 0.9, ['压缩顺序（超时用）：淡入淡出 → 对比度/音量调节 → 自适应分辨率只保留一组对比 → 需求卡只保留 1/2 的完整放大和 2/2 的开头。',
                              '不能删：五项基础功能、频谱柱、报到—叫号—求助闭环、开头名称与结尾总结。'], size=14, color=GREY)

# ---------------- 11 cameras ----------------
s = prs.slides.add_slide(BLANK)
header(s, '10 · 机位与录制方案', '屏幕用采集卡录，人手和实物用手机拍')
table(s, 0.55, 2.0, 12.2, [
    ['机位', '设备', '拍什么', '要点'],
    ['A', 'HDMI 采集卡 + 电脑（OBS）', '大厅屏画面 + 大厅板 HDMI 声音', '录 1080p/60 或 30 帧；声音直接录 HDMI 音轨（音乐、语音播报、频谱同步）'],
    ['B', '第二块采集卡（或分时录）', '诊室屏画面', '没有第二块采集卡时：主题段分两遍录，第二遍只录诊室屏，后期对齐'],
    ['C', '手机 + 支架（横屏）', '全景、触摸屏、按键手部特写', '固定机位、手动对焦并锁定曝光；正对屏幕，关闭顶灯减少反光'],
    ['D（可选）', '第二部手机', '诊室板按键与蜂鸣器', '蜂鸣声可用此机位收音，后期压低环境声'],
], [1.2, 3.0, 3.5, 4.5], size=13, row_h=0.62)
text(s, 0.55, 5.35, 12.2, 1.2, ['直接拍显示器时：镜头正对屏幕，调低显示器亮度，手机开专业模式把快门调到 1/60 秒左右以减少闪烁条纹；',
                               '出现摩尔纹时稍微拉远或轻微离焦。能用采集卡的画面一律用采集卡，清晰度和颜色都更好。'], size=14, color=GREY)
note(s, '显示器、采集卡都按 640×480 输入；后期在 1920×1080 画布上居中放大，不要拉伸变形', y=6.6)

# ---------------- 12 setup ----------------
s = prs.slides.add_slide(BLANK)
header(s, '11 · 开拍前设备与开关状态表', '每条开拍前都按这张表复位一遍')
table(s, 0.55, 1.95, 6.0, [
    ['大厅板', '状态'],
    ['TF 卡', 'PIC1–PIC4.BMP、AUDIO.PCM、VOICE.PCM'],
    ['SW1（C8）音量模式', '拨下（拍音量调节时才拨上）'],
    ['SW2（C7）频谱柱', '拨上（显示频谱柱）'],
    ['SW3（C6）对比度', '拨下（KEY3 调亮度）'],
    ['SW4（C5）分辨率行', '拨下（拍自适应分辨率时拨上）'],
    ['触摸屏', '已接好，主页显示“报到”“请帮助我”'],
    ['网线', '大厅板 ↔ 诊室板，屏上显示“链路正常”'],
], [2.4, 3.6], size=12, row_h=0.5)
table(s, 6.75, 1.95, 6.0, [
    ['诊室板', '状态'],
    ['TF 卡', 'CARD1–CARD5.BMP（需求卡、求助卡）'],
    ['SW4（C5）', '拨下 = 双诊室（1、2 诊室）'],
    ['SW5', '拨下（蜂鸣器开）'],
    ['KEY2 / KEY3 / KEY4', '叫下一位 / 重播 / 确认求助（1 诊室）'],
    ['外接按键 1/2/3', '2 诊室的叫号 / 重播 / 确认求助'],
    ['屏幕', '链路正常，两栏显示 1、2 诊室'],
], [2.4, 3.6], size=12, row_h=0.5)
note(s, '每条主题演示前：两板都按 KEY1 复位，让号码从头开始；确认大厅“等待叫号”、诊室两栏都没有患者', y=6.2)

# ---------------- 13 pitfalls ----------------
s = prs.slides.add_slide(BLANK)
header(s, '12 · 避坑指南（本作品专用）', '这 10 条最容易出问题')
card(s, 0.55, 2.0, 6.0, 4.1, '操作与内容', [
    '01　SW1 忘了拨下，KEY2/KEY4 变成调音量，切图“没反应”',
    '02　求助卡打断需求卡：等需求卡 2/2 放完再求助',
    '03　报到时忘勾需求，诊室不会弹卡',
    '04　KEY4 长按是上一张、短按是轮播开关，别按混',
    '05　拍频谱柱时音乐要在播放，SW2 要拨上'], size=14)
card(s, 6.75, 2.0, 6.0, 4.1, '拍摄与后期', [
    '06　手机外放收音：嘈杂、偏小；声音一律用采集卡录 HDMI',
    '07　字幕写错术语：频谱柱是“频谱”不是“波形”',
    '08　画面里出现 TD、下载器、电脑桌面',
    '09　640×480 画面被拉伸成 16:9，人物和文字变形',
    '10　总时长超过 3:15'], accent=AMBER, size=14)
note(s, '原则：视频里只保留“一次成功、画面清晰、声音清楚、结构明确”的镜头，其余剪掉或重拍', y=6.35)

# ---------------- 14 checklist ----------------
s = prs.slides.add_slide(BLANK)
header(s, '13 · 拍摄检查清单', '开拍前、拍摄中、剪辑后逐项打勾')
table(s, 0.55, 1.95, 12.2, [
    ['阶段', '检查项'],
    ['开拍前', '□ 两板程序已下载并上板验收（含 10/29 频谱柱、10/30 需求卡依次展示）□ 第 14 节事项已确认\n'
              '□ 两张 TF 卡文件齐全 □ 开关按第 11 节复位 □ 网线链路正常 □ 触摸屏响应正常\n'
              '□ 采集卡试录 10 秒并回放（画面、声音都有）□ 手机电量、空间充足 □ 支架固定、桌面整洁'],
    ['拍摄中', '□ 五段齐全 □ 基础功能 5 项都拍到 □ 扩展功能按亮点顺序 □ 主题演示整段一次走完\n'
              '□ 每段录完立即回放 □ 失败就复位重拍，不将就'],
    ['剪辑后', '□ 剪掉调试、等待、失败画面 □ 每个功能都有字幕，位置统一、无错别字\n'
              '□ 配音与画面对齐 □ 音量统一、无爆音 □ 640×480 画面等比放大不变形\n'
              '□ 总时长约 3:00 □ 导出 1080p MP4 □ 从头到尾完整看一遍再提交'],
], [1.6, 10.6], size=13, row_h=0.95)
note(s, '使用方法：打印或存到手机，拍摄时逐项核对，全部打勾再提交', y=6.1, color=TEAL)

# ---------------- 15 open items ----------------
s = prs.slides.add_slide(BLANK)
header(s, '14 · 开拍前必须确认（未完成项）', '以下几项决定能不能拍、怎么拍，请负责人逐条确认')
table(s, 0.55, 1.95, 12.2, [
    ['事项', '现状', '需要做什么'],
    ['上板验收', '10/29 频谱柱、不读 EDID，10/30 需求卡依次展示、在途命令不串诊室：只完成了仿真和 TD 检查，尚未上板', '拍摄前先按 docs/SPECTRUM_20261029.md、CLINIC_SEQ_20261030.md 的步骤上板验证'],
    ['上电自启（固化）', '目前只下载到 SRAM，断电后程序丢失；按约定，写 Flash 留到最后阶段', '团队决定是否在拍摄前写 Flash；不写的话，视频中不要出现断电重启的镜头'],
    ['资源与时序数字', '第 08 节数字来自无界面 TD 检查', '用 GUI 编译后的实际报告核对后再上字幕'],
    ['可靠性指标', '启动时间、连续运行时长尚未实测', '拍摄当天实测并记录；没有测的指标不要写进字幕'],
    ['自动轮播间隔', '工程默认 3 秒（media_player_control 的 AUTO_MS）', '拍摄时实测，字幕写实测值'],
    ['分辨率展示规则', '官方要求“一高一低两张图缩放后画面大小相同”', '演示用 PIC1（1920×1080）与 PIC3（1280×720），两者都是 16:9，缩放后都是 640×360'],
], [2.2, 5.0, 5.0], size=12, row_h=0.62)

prs.save(OUT)
print('wrote', OUT)
