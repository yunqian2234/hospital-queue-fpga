"""10/31: figures for the technical document that can be produced without a camera.
Diagrams are drawn with matplotlib; screen images are reference-model / RTL renders that already
exist in delivery/ (copied or composed). Output: 图片_已生成/图X-Y_名称.png (not inserted into the docx).

v2 (10/31): every diagram is about 10 inches wide, so a 15 cm Word column shrinks it by only ~0.6 and
the box text (13-14 pt) prints at about 8 pt. Box texts were shortened and long chains split into two
rows. Fig.save() measures every box text after drawing and shrinks it (never below MIN_PT) if it would
touch the border; it prints a warning when that happens, and every free label must stay inside the canvas.
Usage: python make_figures.py
"""
import shutil
import subprocess
import sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Arc
from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
DEL = LAB / 'delivery'
OUT = HERE / '图片_已生成'
WORK = OUT / '_work'
plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'Segoe UI Symbol', 'Cambria Math', 'SimHei']
plt.rcParams['axes.unicode_minus'] = False

TEAL, AMBER, INK, GREY, PALE, PALE2, RED, LINE = ('#0E6E6E', '#F08C00', '#1F2933', '#5B6573', '#E6F0F0',
                                                  '#FDF1E7', '#C2410C', '#9AA5B1')
BOX, LAB_PT, NOTE, TITLE, MIN_PT = 13.5, 12.5, 12.5, 15, 11.5     # point sizes
PAD = 0.9                                                          # min gap text <-> box border (units)


class Fig:
    """1 unit = 0.1 inch; x 0..10*w, y 0..10*h"""

    def __init__(self, w, h, dpi=220):
        self.f, self.ax = plt.subplots(figsize=(w, h), dpi=dpi)
        self.W, self.H = w * 10, h * 10
        self.ax.set_xlim(0, self.W)
        self.ax.set_ylim(0, self.H)
        self.ax.axis('off')
        self.f.subplots_adjust(0, 0, 1, 1)
        self.fit = []           # (text artist, (x, y, w, h))
        self.free = []          # free texts: must stay on the canvas

    def box(self, x, y, w, h, text, fc=PALE, ec=TEAL, size=BOX, bold=False, color=INK, lw=1.4, ls='-'):
        self.ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0,rounding_size=0.8',
                                         fc=fc, ec=ec, lw=lw, ls=ls))
        if text:
            t = self.ax.text(x + w / 2, y + h / 2, text, ha='center', va='center', fontsize=size,
                             fontweight='bold' if bold else 'normal', color=color, linespacing=1.3)
            self.fit.append((t, (x, y, w, h)))
        return (x, y, w, h)

    def group(self, x, y, w, h, title, ec=TEAL):
        self.ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0,rounding_size=1.2',
                                         fc='#FFFFFF', ec=ec, lw=1.6, ls='--'))
        self.text(x + 1.4, y + h - 2.2, title, size=TITLE, color=ec, bold=True, ha='left')

    def arrow(self, x1, y1, x2, y2, color=GREY, both=False, lw=1.6, ls='-'):
        self.ax.annotate('', xy=(x2, y2), xytext=(x1, y1),
                         arrowprops=dict(arrowstyle='<|-|>' if both else '-|>', color=color, lw=lw, ls=ls,
                                         shrinkA=0, shrinkB=0, mutation_scale=15))

    def line(self, xs, ys, color=GREY, lw=1.6, ls='-'):
        self.ax.plot(xs, ys, color=color, lw=lw, ls=ls, solid_capstyle='butt')

    def text(self, x, y, s, size=LAB_PT, color=GREY, ha='center', bold=False, va='center', rot=0):
        t = self.ax.text(x, y, s, ha=ha, va=va, fontsize=size, color=color, fontweight='bold' if bold else 'normal',
                         linespacing=1.3, rotation=rot)
        self.free.append(t)
        return t

    def _bbox(self, t, r):
        return t.get_window_extent(r).transformed(self.ax.transData.inverted())

    def save(self, name):
        self.f.canvas.draw()
        r = self.f.canvas.get_renderer()
        for t, (x, y, w, h) in self.fit:
            s0 = t.get_fontsize()
            while True:
                b = self._bbox(t, r)
                ok = b.x0 >= x + PAD and b.x1 <= x + w - PAD and b.y0 >= y + PAD * 0.7 and b.y1 <= y + h - PAD * 0.7
                if ok or t.get_fontsize() <= MIN_PT:
                    break
                t.set_fontsize(t.get_fontsize() - 0.5)
            if not ok:
                print(f'  !! {name}: text still overflows its box: {t.get_text()!r}')
            elif t.get_fontsize() < s0:
                print(f'  .. {name}: {t.get_text()!r} shrunk {s0} -> {t.get_fontsize()} pt')
        for t in self.free:
            b = self._bbox(t, r)
            if b.x0 < 0 or b.x1 > self.W or b.y0 < 0 or b.y1 > self.H:
                print(f'  !! {name}: label outside the canvas: {t.get_text()!r}')
        self.f.savefig(OUT / f'{name}.png', facecolor='white')
        plt.close(self.f)
        print('wrote', name)


def right(b, dy=0):
    return b[0] + b[2], b[1] + b[3] / 2 + dy


def left(b, dy=0):
    return b[0], b[1] + b[3] / 2 + dy


def top(b, dx=0):
    return b[0] + b[2] / 2 + dx, b[1] + b[3]


def bottom(b, dx=0):
    return b[0] + b[2] / 2 + dx, b[1]


def chain(g, boxes):
    for a, b in zip(boxes, boxes[1:]):
        g.arrow(*right(a), *left(b))


# ---------------------------------------------------------------- 图1-2 应用场景示意
def fig_1_2():
    g = Fig(10, 6)
    g.group(1, 3, 54, 54, '候诊大厅')
    g.text(30, 49.5, '患者：报到 → 看大屏 → 就诊')
    scr = g.box(3, 24, 24, 19, '候诊大屏（HDMI）\n叫号 · 语音播报\n宣教图片 · 频谱柱', fc='#FFFFFF')
    tch = g.box(29.5, 24, 23.5, 19, '触摸屏报到机\n报到 · 登记需求\n一键求助', fc='#FFFFFF')
    hb = g.box(5, 6, 45, 12, '大厅 FPGA 板\n保存号码、队列、登记、求助', bold=True)
    g.arrow(15, 18, 15, 24)
    g.text(12, 21, 'HDMI')
    g.arrow(41, 18, 41, 24)
    g.text(44.5, 21, 'UART')
    g.group(69, 3, 30, 54, '诊室 1、2', ec=AMBER)
    g.text(84, 49.5, '医生：叫号前知道需求')
    cs = g.box(71, 24, 26, 19, '诊室屏（HDMI）\n当前患者 · 需求\n需求卡放大\n求助提醒', fc='#FFFFFF', ec=AMBER)
    cb = g.box(71, 6, 26, 12, '诊室 FPGA 板\n叫号 · 重播 · 确认', fc=PALE2, ec=AMBER, bold=True)
    g.arrow(84, 18, 84, 24)
    g.text(80.5, 21, 'HDMI')
    g.arrow(50, 12, 71, 12, color=TEAL, both=True, lw=2.4)
    g.text(62, 15, '网线', color=TEAL, bold=True)
    g.text(62, 9, '以太网原始帧', color=TEAL)
    g.save('图1-2_应用场景示意')


# ---------------------------------------------------------------- 图1-3 设计流程图
def fig_1_3():
    g = Fig(10, 5.2)
    xs = [2, 27, 52, 77]
    r1 = [g.box(x, 30, 21, 13, t) for x, t in zip(xs, ['需求分析\n场景与赛题', '方案设计\nV4 → V8 迭代',
                                                       '参考模型\nPython 逐位模型', 'RTL 编码\nVerilog'])]
    chain(g, r1)
    sim = g.box(77, 9, 21, 13, '仿真验证\n逐像素 · 变异测试', fc=PALE2, ec=AMBER)
    td = g.box(52, 9, 21, 13, 'TD 检查\n综合 · 布局 · 时序', fc=PALE2, ec=AMBER)
    hw = g.box(27, 9, 21, 13, '上板联调\n实物验证')
    g.arrow(*bottom(r1[3]), *top(sim))
    g.arrow(*left(sim), *right(td))
    g.arrow(*left(td), *right(hw))
    # feedback: every check can send the design back to the RTL
    for b in (sim, td, hw):
        g.line([b[0] + b[2] / 2] * 2, [9, 4.5], color=RED)
    g.line([37.5, 99.3, 99.3], [4.5, 4.5, 36.5], color=RED)
    g.arrow(99.3, 36.5, 98, 36.5, color=RED)
    g.text(18, 4.5, '不通过：回到 RTL 修改', color=RED)
    g.text(50, 48, '每个关键模块：先建参考模型，再写 RTL，仿真时与模型逐位比对', color=GREY)
    g.save('图1-3_设计流程图')


# ---------------------------------------------------------------- 图2-1 系统整体框图
def fig_2_1():
    g = Fig(11, 10)
    g.group(1, 9, 72, 81, '大厅板（EG4S20）')
    s = 13
    xa = [2, 16.5, 31, 45.5, 60]
    ra = [g.box(x, 74, 12, 10, t, size=s, fc=fc) for x, t, fc in zip(
        xa, ['TF 卡', '读卡\nFAT32', '图像\n缩放', 'SDRAM\n帧缓存', '帧读取\n淡入淡出'],
        ['#FFFFFF', PALE, PALE, '#FFFFFF', PALE])]
    chain(g, ra)
    mon = g.box(50, 92, 22, 6.5, '大厅显示器 + 扬声器', fc='#FFFFFF', size=s)
    pcm = g.box(16.5, 56, 12, 12, '音频\n播放', size=s)
    dft = g.box(31, 56, 14, 12, '自研 DFT\n16 频段', fc=PALE2, ec=AMBER, size=s)
    osd = g.box(50, 56, 22, 12, '显示叠加\n中文界面 + 频谱柱', fc=PALE2, ec=AMBER, size=s)
    vd = g.box(16.5, 38, 12, 12, '语音\n调度', size=s)
    mix = g.box(31, 38, 14, 12, '语音优先\n音量调节', size=s)
    hdmi = g.box(50, 38, 22, 12, 'HDMI 发送\n视频 + 音频', size=s)
    tjc = g.box(2, 14, 11, 14, '陶晶驰\n触摸屏', fc='#FFFFFF', size=s)
    uart = g.box(15.5, 14, 11, 14, 'UART\n收发', size=s)
    core = g.box(29, 14, 17, 14, '业务核心\n报到 · 叫号\n求助 · 回执', fc=PALE2, ec=AMBER, size=s, bold=True)
    lm = g.box(49, 14, 10.5, 14, '链路\n主机', size=s)
    mac = g.box(61.5, 14, 10.5, 14, '以太网\nMAC', size=s)
    g.arrow(66, 74, 66, 68)                                   # frame -> overlay
    g.arrow(66, 56, 66, 50)                                   # overlay -> HDMI
    g.line([72, 74.6, 74.6], [44, 44, 95.2])                  # HDMI -> monitor
    g.arrow(74.6, 95.2, 72, 95.2)
    g.arrow(22.5, 74, 22.5, 68)
    g.text(18.2, 71, '音频文件', size=11.5)
    g.arrow(*right(pcm), *left(dft))
    g.arrow(*right(dft), *left(osd))
    g.text(47.5, 64.6, '柱高', size=11.5)
    g.arrow(26, 56, 33, 50)                                   # pcm -> mix
    g.arrow(22.5, 50, 22.5, 56)                               # voice dispatch -> pcm
    # mix -> HDMI with a line jump over the status line at x = 47.5
    g.line([45, 46.6], [44, 44])
    g.ax.add_patch(Arc((47.5, 44), 1.8, 2.2, theta1=0, theta2=180, color=GREY, lw=1.6))
    g.arrow(48.4, 44, 50, 44)

    g.arrow(34, 28, 25, 38)                                   # core -> voice dispatch
    g.text(26, 32.5, '叫号事件', size=11.5)
    g.line([46, 47.5, 47.5], [24, 24, 59])                    # core -> overlay (numbers, state)
    g.arrow(47.5, 59, 50, 59)
    g.text(53.5, 33, '号码\n状态', size=11.5)
    g.arrow(*right(tjc), *left(uart), both=True)
    g.arrow(*right(uart), *left(core), both=True)
    g.arrow(46, 19, 49, 19, both=True)
    g.arrow(*right(lm, -2), *left(mac, -2), both=True)
    # clinic
    g.group(79, 9, 30, 81, '诊室板', ec=AMBER)
    cmac = g.box(81, 14, 12, 14, '以太网\nMAC', size=s)
    clk = g.box(95, 14, 12, 14, '链路端点\n1、2 诊室', size=s)
    seq = g.box(81, 38, 12, 12, '需求卡\n顺序器', fc=PALE2, ec=AMBER, size=s)
    keys = g.box(95, 38, 12, 12, '医生\n按键', fc='#FFFFFF', size=s)
    card = g.box(81, 56, 12, 12, 'TF 卡\n需求卡', size=s)
    cscr = g.box(95, 56, 12, 12, '诊室屏\n卡片放大', size=s)
    buz = g.box(81, 74, 12, 10, '蜂鸣器', fc='#FFFFFF', size=s)
    chd = g.box(95, 74, 12, 10, 'HDMI\n发送', size=s)
    cmon = g.box(95, 92, 12, 6.5, '诊室显示器', fc='#FFFFFF', size=12)
    g.arrow(*right(cmac), *left(clk), both=True)
    g.arrow(101, 38, 101, 28)
    g.arrow(97, 28, 90, 38)
    g.arrow(91, 50, 97, 56)
    g.arrow(*right(card), *left(cscr))
    g.arrow(101, 68, 101, 74)
    g.arrow(101, 84, 101, 92)
    g.arrow(97, 68, 90, 74)
    g.text(91.5, 70.2, '求助', size=11.5)
    g.arrow(72, 19, 81, 19, color=TEAL, both=True, lw=2.6)
    g.text(76.5, 22.2, '网线', color=TEAL, bold=True)
    g.text(2, 4.5, '时钟域：视频 25 MHz · SD 100 MHz · SDRAM 125 MHz · 音频 12.288 MHz · 网口 125 / 25 MHz',
           size=12, ha='left')
    g.save('图2-1_系统整体框图')


# ---------------------------------------------------------------- 图2-2 硬件连接示意图
def fig_2_2():
    g = Fig(10, 6)
    hb = g.box(24, 12, 20, 36, '开发板\n（大厅）\n\nEG4S20\nSDRAM\n数码管\nKEY · SW', fc=PALE, bold=False)
    cb = g.box(60, 12, 20, 36, '开发板\n（诊室）\n\nEG4S20\n数码管\n蜂鸣器\nKEY · SW', fc=PALE2, ec=AMBER)
    lp = [('大厅显示器\n（含扬声器）', 'HDMI'), ('TF 卡\n图片 · 音频', 'SPI'), ('陶晶驰\n触摸屏', 'UART')]
    rp = [('诊室\n显示器', 'HDMI'), ('TF 卡\n需求卡', 'SPI'), ('外接按键\n（2 诊室）', 'J1')]
    for i, (t, lab) in enumerate(lp):
        y = 39 - i * 14.5
        b = g.box(1, y, 17, 11, t, fc='#FFFFFF')
        g.arrow(18, y + 5.5, 24, y + 5.5, both=True)
        g.text(21, y + 8, lab, size=11.5)
    for i, (t, lab) in enumerate(rp):
        y = 39 - i * 14.5
        b = g.box(86, y, 13, 11, t, fc='#FFFFFF', ec=AMBER)
        g.arrow(80, y + 5.5, 86, y + 5.5, both=True)
        g.text(83, y + 8, lab, size=11.5)
    g.arrow(44, 30, 60, 30, color=TEAL, both=True, lw=2.6)
    g.text(52, 33.2, 'RJ45 网线', color=TEAL, bold=True)
    g.text(52, 26.6, '100M 以太网', color=TEAL)
    g.text(50, 5, '两块同型号开发板，无额外处理器；板载网口芯片只做物理层收发', color=GREY)
    g.text(50, 55, 'HX4S20C 开发板 ×2（EG4S20BG256）', size=TITLE, color=INK, bold=True)
    g.save('图2-2_硬件连接示意图')


# ---------------------------------------------------------------- 图2-5 / 2-6 RTL 层次（资源）
HALL_MODS = [('SD 卡 / FAT32 / BMP / 缩放', 'sd_card_bmp', 5555, 11, 7), ('HDMI 1.4b 发送核', 'hdmi_1_4b_transmitter_core_wrapper', 1533, 14, 0),
             ('大厅界面（文字引擎）', 'hospital_screen', 855, 18, 3), ('业务核心', 'hospital_app_core', 624, 0, 0),
             ('帧读取', 'media_frame_reader', 517, 2, 0), ('以太网 MAC', 'eth_link', 514, 0, 0),
             ('帧加载', 'media_frame_loader', 391, 4, 0), ('SDRAM 控制', 'sdram', 370, 0, 0),
             ('DFT 频谱柱', 'audio_bar_visualizer', 365, 3, 3), ('HDMI 音频桥', 'media_hdmi_audio_bridge', 356, 0, 2),
             ('链路主机', 'link_master', 243, 0, 0), ('触摸帧接收', 'tjc_touch_rx', 168, 0, 0),
             ('音乐播放', 'wav_stream_player', 167, 8, 0), ('语音播放', 'hospital_voice_player', 148, 0, 0),
             ('触摸屏回写', 'hospital_touch_status', 145, 1, 0), ('按键前端', 'hospital_key_frontend', 139, 0, 0),
             ('分辨率信息', 'bmp_res_info', 138, 4, 0), ('音量调节', 'hospital_user_volume', 118, 0, 1),
             ('语音 FIFO', 'voice_sample_fifo', 117, 4, 0), ('语音调度', 'hospital_voice_dispatch', 112, 0, 0),
             ('播放控制', 'media_player_control', 111, 0, 0), ('报到登记', 'hospital_registration', 103, 0, 0)]
CLIN_MODS = [('需求卡读取（SD / FAT32 / BMP）', 'clinic_card_loader', 2837, 2, 0),
             ('HDMI 1.4b 发送核', 'hdmi_1_4b_transmitter_core_wrapper', 1432, 12, 0),
             ('诊室屏（文字引擎）', 'clinic_screen', 761, 36, 3), ('需求卡放大（双线性）', 'clinic_card_view', 716, 6, 11),
             ('以太网 MAC', 'eth_link', 538, 0, 0), ('链路端点（1 诊室）', 'clinic_link', 324, 0, 0),
             ('SD 卡驱动', 'sd_card_top', 279, 0, 0), ('视频转 AXI-Stream', 'video_rgb_to_axis_640x480', 199, 0, 0),
             ('按键前端（2 诊室）', 'hospital_key_frontend', 134, 0, 0), ('按键前端（1 诊室）', 'hospital_key_frontend', 130, 0, 0),
             ('链路端点（2 诊室）', 'clinic_link', 106, 0, 0), ('需求卡顺序器', 'clinic_need_trigger', 91, 0, 0),
             ('数码管', 'seg_scan', 85, 0, 0), ('卡片存储', 'clinic_card_store', 32, 22, 0)]


def hier(name, top_name, mods, total, colour):
    n = len(mods)
    f, ax = plt.subplots(figsize=(10, 0.42 * n + 1.5), dpi=220)
    ys = list(range(n))[::-1]
    luts = [m[2] for m in mods]
    ax.barh(ys, luts, color=colour, height=0.66)
    for y, (cn, mod, lut, bram, dsp) in zip(ys, mods):
        extra = '  '.join(s for s in (f'BRAM {bram}' if bram else '', f'DSP {dsp}' if dsp else '') if s)
        ax.text(lut + max(luts) * 0.012, y, f'{lut}' + (f'   {extra}' if extra else ''), va='center', fontsize=12, color=INK)
    ax.set_yticks(ys)
    ax.set_yticklabels([m[0] for m in mods], fontsize=12.5)
    ax.tick_params(axis='x', labelsize=12)
    ax.set_xlabel('LUT（逻辑）', fontsize=12.5)
    ax.set_xlim(0, max(luts) * 1.3)
    ax.spines[['top', 'right']].set_visible(False)
    ax.set_title(f'{top_name}：主要子模块资源（全片 LUT {total}；BRAM、DSP 为块数）', fontsize=13.5, loc='left')
    f.tight_layout()
    f.savefig(OUT / f'{name}.png', facecolor='white')
    plt.close(f)
    print('wrote', name)


# ---------------------------------------------------------------- helpers for figure + image
def stack(parts, name, gap=24):
    ims = [Image.open(p).convert('RGB') for p in parts]
    w = max(i.width for i in ims)
    ims = [i if i.width == w else i.resize((w, int(i.height * w / i.width))) for i in ims]
    out = Image.new('RGB', (w, sum(i.height for i in ims) + gap * (len(ims) - 1)), 'white')
    y = 0
    for i in ims:
        out.paste(i, (0, y))
        y += i.height + gap
    out.save(OUT / f'{name}.png')
    print('wrote', name)


def caption(text, key, h=0.55):
    g = Fig(10, h)
    g.text(50, h * 5, text, color=INK)
    g.save(f'_work/{key}')
    return OUT / f'_work/{key}.png'


# ---------------------------------------------------------------- 图2-8 图像缩放流程（+ 质量对比）
def fig_2_8():
    g = Fig(10, 3.4)
    t = ['读 BMP 头\n宽 W、高 H', '求缩放比\ns = min(640/W,\n480/H)', 'k×k 区域平均\nk = floor(1/s)\n（低通预滤波）',
         '双线性插值\n像素中心对齐', '居中写 SDRAM\n四周暖白填边']
    bs = [g.box(1 + i * 19.7, 9, 18, 19, s, fc=PALE2 if i in (2, 3) else PALE, ec=AMBER if i in (2, 3) else TEAL)
          for i, s in enumerate(t)]
    chain(g, bs)
    g.text(50, 4, '流式处理：每读一行输出一行，不需要整帧缓存；R/G/B 分时共用一条 DSP 流水线')
    g.text(50, 31.5, '图像缩放流程（640×480～1920×1080 → 适配 640×480，保持宽高比）', color=INK, bold=True, size=13)
    g.save('_work/scale_flow')
    crop = DEL / 'image_scale_20261021/evidence/image_scale/quality_zone_plate_crop_x2.png'
    cap = caption('下：环形波带测试图 1920×1080 → 640×360 局部放大；左起最近邻、普通双线性、本设计（PSNR 10.5 / 10.5 / 23.1 dB）', 'scale_cap')
    stack([OUT / '_work/scale_flow.png', cap, crop], '图2-8_图像缩放流程图', gap=8)


# ---------------------------------------------------------------- 图2-9 业务核心状态与事件流程
def fig_2_9():
    g = Fig(10, 7.4)
    s = 13
    g.text(25, 70.5, '号码与叫号', size=TITLE, color=TEAL, bold=True)
    a = g.box(2, 50, 20, 14, '触摸屏报到\n分配新号码\n登记存入该号', size=s)
    b = g.box(28, 50, 20, 14, '候诊队列\n候诊 = 已报到\n − 已叫号', size=s)
    c = g.box(2, 29, 20, 14, '诊室叫下一位\n取队首号码\n记为当前患者', fc=PALE2, ec=AMBER, size=s)
    d = g.box(28, 29, 20, 14, '叫号事件入队\n大屏两行叫号\n语音播报', size=s)
    e = g.box(2, 8, 20, 13, '诊室重播\n本诊室当前号', size=s)
    f_ = g.box(28, 8, 20, 13, '拒绝并回执\n无人候诊 · 未叫号\n语音忙 · 重复', fc='#FFFFFF', ec=RED, color=RED, size=s)
    g.arrow(*right(a), *left(b))
    g.arrow(38, 50, 12, 43)
    g.arrow(*right(c), *left(d))
    g.arrow(12, 21, 31, 29)
    g.arrow(*right(e, -2.5), *left(f_, -2.5), color=RED)
    g.text(25, 2.8, '任一请求不满足条件 → 拒绝并给出原因', color=RED, size=12)
    
    # help state machine (vertical)
    g.text(76, 70.5, '求助状态', size=TITLE, color=AMBER, bold=True)
    h0 = g.box(66, 56, 18, 9, '无', fc='#FFFFFF', size=14, bold=True)
    h1 = g.box(66, 40, 18, 9, '待回应', fc=PALE2, ec=RED, color=RED, size=14, bold=True)
    h2 = g.box(66, 24, 18, 10, '已确认\n（负责诊室）', fc=PALE, size=13, bold=True)
    g.arrow(*bottom(h0), *top(h1))
    g.text(91.5, 52.5, '患者\n“请帮助我”', size=12)
    g.arrow(*bottom(h1), *top(h2))
    g.text(91.5, 36.8, '最先确认\n的诊室', size=12)
    g.line([66, 61.5, 61.5], [29, 29, 60.5])
    g.arrow(61.5, 60.5, 66, 60.5)
    g.text(58.6, 44.8, '下一条求助 / 复位', size=12, rot=90)
    g.box(55, 4, 44, 16, '', fc='#FFFFFF', ec=LINE)
    g.text(57, 16, '• 待回应时再次求助：拒绝（重复）', ha='left', color=INK, size=12)
    g.text(57, 12, '• 已确认后其他诊室再确认：拒绝', ha='left', color=INK, size=12)
    g.text(57, 8, '• 每条请求的结果都回写触摸屏或诊室', ha='left', color=INK, size=12)
    g.save('图2-9_业务核心状态与事件流程图')


# ---------------------------------------------------------------- 图2-10 链路帧格式与命令时序
def fig_2_10():
    g = Fig(10, 7)
    s = 12.5
    g.text(2, 66, '以太网帧（64 字节，EtherType 0x88B5）', size=TITLE - 1, color=TEAL, bold=True, ha='left')
    fields = [('前导码\n8 字节', 9, '#FFFFFF'), ('目的 MAC\n（广播）', 15, PALE), ('源 MAC', 10, PALE),
              ('类型\n0x88B5', 10, PALE2), ('链路帧', 36, PALE2), ('补零', 6, '#FFFFFF'), ('CRC-32', 10, PALE)]
    x = 2
    for t, w, c in fields:
        g.box(x, 52, w, 10, t, fc=c, ec=TEAL, size=s)
        x += w
    x0 = 2 + 9 + 15 + 10 + 10
    sub = [('A5', 5), ('类型', 6), ('序号', 6), ('长度', 6), ('数据', 6), ('CRC8', 7)]
    xx = x0
    for t, w in sub:
        g.box(xx, 41, w, 7, t, fc='#FFFFFF', ec=AMBER, size=s)
        xx += w
    g.line([x0, x0], [52, 48], color=AMBER, lw=1.2)
    g.line([x0 + 36, x0 + 36], [52, 48], color=AMBER, lw=1.2)
    g.text(2, 35, '命令重发与回执', size=TITLE - 1, color=TEAL, bold=True, ha='left')
    yc, yh = 27, 9
    g.line([10, 98], [yc, yc], color=AMBER, lw=2)
    g.line([10, 98], [yh, yh], color=TEAL, lw=2)
    g.text(5, yc, '诊室', size=13, bold=True, color=AMBER)
    g.text(5, yh, '大厅', size=13, bold=True, color=TEAL)
    g.text(15, yc + 3, '按键：命令 n', size=12, color=AMBER)
    g.arrow(14, yc, 23, 15.5, color=RED, ls='--')
    g.text(25.5, 13.5, '丢失 ×', size=12, color=RED)
    g.arrow(34, yc, 44, yh)
    g.text(37, yc + 3, '约 50 ms 后重发 n', size=12)
    g.text(44, yh - 3.2, '执行（仅一次）', size=12, color=TEAL)
    g.arrow(50, yh, 60, yc)
    g.text(62, 17.5, '状态帧：回执 n', size=12)
    g.text(63, yc + 3, '显示“已执行”', size=12, color=AMBER)
    g.arrow(74, yc, 84, yh, ls=':')
    g.text(90.5, 19, '迟到的重复帧\n只回执不执行', size=12)
    g.text(50, 1.8, '2 秒仍无回执 → 显示“未送达”；命令在途期间所属诊室不变', size=12)
    g.save('图2-10_链路帧格式与命令时序图')


# ---------------------------------------------------------------- 图2-11 文字引擎数据流
def fig_2_11():
    g = Fig(10, 4.8)
    g.text(1.6, 45, '离线生成（开发阶段）', size=12.5, color=TEAL, bold=True, ha='left')
    r1x = [1.6, 37.6, 72.6]
    r1 = [g.box(x, 29, 25, 12, t) for x, t in zip(r1x, ['界面描述\n文字 · 坐标 · 字体', 'Python 生成器\n检查字高与冲突',
                                                        '存入块 RAM\n槽位 · 字符串 · 字形'])]
    chain(g, r1)
    g.text(1.6, 22.5, '运行时（每一行）', size=12.5, color=AMBER, bold=True, ha='left')
    r2x = [80, 60.4, 40.8, 21.2, 1.6]
    r2t = ['行消隐：查\n槽位与字符串', '生成下一行\n字形描述符', '乒乓缓存\n两行交替', '显示时按 x\n取字形像素', '按 4 级覆盖度\n与背景混合']
    r2 = [g.box(x, 4, 17.6, 14, t, fc=PALE2 if i in (1, 2) else PALE, ec=AMBER if i in (1, 2) else TEAL)
          for i, (x, t) in enumerate(zip(r2x, r2t))]
    g.arrow(88.8, 29, 88.8, 18)
    for a, b in zip(r2, r2[1:]):
        g.arrow(*left(a), *right(b))
    g.save('图2-11_文字引擎数据流图')


# ---------------------------------------------------------------- 图2-12 频谱模块结构与效果
def fig_2_12():
    g = Fig(10, 5)
    xs = [1, 26.3, 51.7, 77]
    r1 = [g.box(x, 30, 22, 13, t, fc=PALE2 if i == 2 else PALE, ec=AMBER if i == 2 else TEAL)
          for i, (x, t) in enumerate(zip(xs, ['PCM 采样\n48 kHz', 'Hann 窗\n32 级', 'Goertzel 迭代\n16 频段分时复用',
                                               '块尾求\nre、im']))]
    chain(g, r1)
    r2 = [g.box(77, 10, 22, 13, '对数域求幅值\nmax + G(差值)', fc=PALE2, ec=AMBER),
          g.box(51.7, 10, 22, 13, '柱高 0～61 像素\n帧起点更新'),
          g.box(26.3, 10, 22, 13, 'HDMI 输出前\n叠加到画面')]
    g.arrow(88, 30, 88, 23)
    for a, b in zip(r2, r2[1:]):
        g.arrow(*left(a), *right(b))
    g.text(12, 16.5, '每个 48 kHz\n采样算一轮', size=12)
    g.text(50, 46.5, 's0 = x·w(n) + 2cos ω·s1 − s2；中心频率 60 Hz～12 kHz 对数间隔；1 像素 = 0.5 dB', size=12, color=INK)
    g.text(50, 4.5, '状态 s1 / s2 存块 RAM，系数与窗函数存 ROM，16 个频段共用一套乘加单元', size=12)
    g.save('_work/dft_flow')
    st = Image.open(DEL / 'spectrum_20261029/preview/sweep_stills.png').convert('RGB')     # 8 stills of 768x200
    tiles = [st.crop((0, j * 200, 768, j * 200 + 192)) for j in (1, 3, 5, 7)]
    gap = 30
    W = Image.open(OUT / '_work/dft_flow.png').width
    tw = (W - 3 * gap) // 4
    tiles = [t.resize((tw, int(192 * tw / 768))) for t in tiles]
    row = Image.new('RGB', (W, tiles[0].height), 'white')
    for i, t in enumerate(tiles):
        row.paste(t, (i * (tw + gap), 0))
    row.save(OUT / '_work/dft_tiles.png')
    cap = caption('下：参考模型的扫频测试（单音 40 Hz → 16 kHz，亮柱从左移到右；橙色为峰值帽）', 'dft_cap')
    stack([OUT / '_work/dft_flow.png', cap, OUT / '_work/dft_tiles.png'], '图2-12_频谱模块结构与效果', gap=8)


# ---------------------------------------------------------------- 图2-13 需求卡展示流程
def fig_2_13():
    g = Fig(10, 7)
    a = g.box(1, 50, 20, 12, '新患者\n登记到达')
    b = g.box(25, 50, 22, 12, '建立任务并冻结\n诊室、号码、需求', fc=PALE2, ec=AMBER)
    c = g.box(51, 50, 23, 12, '放第 i 张卡\n放大 → 停 5 s → 缩回')
    d = g.box(78, 50, 18, 12, '停留时被\n求助打断？', fc='#FFFFFF')
    e = g.box(78, 26, 18, 12, '这张已\n补放过？', fc='#FFFFFF')
    f_ = g.box(51, 26, 23, 12, 'i = i + 1\n还有下一张？', fc='#FFFFFF')
    h = g.box(25, 26, 22, 12, '全部放完\n回到正常页面')
    chain(g, [a, b, c, d])
    g.arrow(87, 50, 87, 38)
    g.text(89.3, 44, '是')
    g.arrow(80, 50, 72, 38)
    g.text(74, 45.5, '否')
    g.arrow(*left(e), *right(f_))
    g.text(76, 34.6, '是', size=12)
    g.text(76, 29.4, '跳过', size=12)
    g.line([96, 98.5, 98.5, 62.5], [32, 32, 66, 66], color=AMBER)
    g.arrow(62.5, 66, 62.5, 62, color=AMBER)
    g.text(80.5, 68.5, '否：同一张补放一次', color=AMBER)
    g.arrow(57, 38, 57, 50)
    g.text(55, 44, '是')
    g.arrow(*left(f_), *right(h))
    g.text(49, 34.6, '否')
    g.box(1, 2, 97, 18, '', fc='#FFFFFF', ec=LINE)
    for y, t in ((15.5, '• 同一诊室叫了下一位：这张放完，旧患者剩下的卡作废，接着放新患者的卡'),
                 (11, '• 切换单 / 双诊室模式、断链：这张放完（标题仍冻结），排队的任务全部作废'),
                 (6.5, '• 另一列来了新患者：排队等候；同一患者的登记重复到达：不重复放卡')):
        g.text(3, y, t, ha='left', color=INK, size=12.5)
    g.save('图2-13_需求卡展示流程')


# ---------------------------------------------------------------- screen images
def pair(a, b, name, gap=24):
    ia, ib = Image.open(a).convert('RGB'), Image.open(b).convert('RGB')
    out = Image.new('RGB', (ia.width + ib.width + gap, max(ia.height, ib.height)), 'white')
    out.paste(ia, (0, 0))
    out.paste(ib, (ia.width + gap, 0))
    out.save(OUT / f'{name}.png')
    print('wrote', name)


def screens():
    subprocess.run([sys.executable, str(DEL / 'res_demo_20261026/tools/board_preview.py'),
                    str(DEL / 'res_demo_20261026/tf_card_hall/PIC1.BMP'), str(DEL / 'res_demo_20261026/tf_card_hall/PIC3.BMP'),
                    '--out', str(WORK), '--ui'], check=True, capture_output=True)
    shutil.copy2(WORK / 'PIC1_hall.png', OUT / '图3-5_大厅屏界面_参考渲染.png')
    shutil.copy2(DEL / 'spectrum_20261029/evidence/ui3_display/H_sw1/frame_047_scroll47.png', OUT / '图3-5_备选_大厅屏叫号_RTL仿真.png')
    shutil.copy2(DEL / 'clinic_seq_20261030/screens/rtl_clinic_seq_back_normal.png', OUT / '图3-6_诊室屏界面_RTL仿真.png')
    s = DEL / 'clinic_seq_20261030/screens'
    pair(s / 'rtl_clinic_seq_need1of2.png', s / 'rtl_clinic_seq_need2of2.png', '图3-7_需求卡依次放大_RTL仿真')
    pair(WORK / 'PIC1_hall.png', WORK / 'PIC3_hall.png', '图3-9_自适应分辨率效果_参考渲染')


DIAGRAMS = {'1-2': fig_1_2, '1-3': fig_1_3, '2-1': fig_2_1, '2-2': fig_2_2,
            '2-5': lambda: hier('图2-5_大厅板RTL模块层次与资源', '大厅板 top_tf_hdmi_audio', HALL_MODS, 16632, TEAL),
            '2-6': lambda: hier('图2-6_诊室板RTL模块层次与资源', '诊室板 top_clinic', CLIN_MODS, 9926, AMBER),
            '2-8': fig_2_8, '2-9': fig_2_9, '2-10': fig_2_10, '2-11': fig_2_11, '2-12': fig_2_12, '2-13': fig_2_13}


def main():
    """python make_figures.py [figure numbers, e.g. 2-1 2-9] [--no-screens]"""
    WORK.mkdir(parents=True, exist_ok=True)
    want = [a for a in sys.argv[1:] if not a.startswith('--')] or list(DIAGRAMS)
    for k in want:
        DIAGRAMS[k]()
    if '--no-screens' not in sys.argv and len(want) == len(DIAGRAMS):
        screens()
    shutil.rmtree(WORK, ignore_errors=True)       # intermediate files


if __name__ == '__main__':
    main()
