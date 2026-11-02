"""10/24 UI v3 assets: anti-aliased glyph ROM, string ROM and item (layout) table for the hall
and clinic screens, plus a Verilog include with the matching localparams.

One authority for every text the two screens show and where it sits. The RTL text engine
(display/ui_text_engine.v) is generic; this file decides the content.

Glyphs
  Rendered offline with Pillow at 4x and box-filtered to the cell, so every pixel stores
  2-bit coverage (0, 1/3, 2/3, 1 -> alpha 0/85/171/256). Stored column-major, glyph after
  glyph, four pixels per byte (pixel p in byte p>>2, bits [2*(p&3)+1 : 2*(p&3)]).
  Pixel (col, row) of glyph g is at start[g] + col*H + row, H = the font's cell height.
  Each font has digits 0..9, then ' ' and '-' as glyphs DIGIT_BASE[font] + 0..11
  (field value 10 = blank, 11 = '-'); the fonts in DIGIT_X also have '×' as value 12 (10/26,
  hall F20: the board-read picture resolution "1920×1080" is a run of packed digit cells).
Strings (string ROM, 12-bit entries)
  bit11 = 0: glyph id;  bit11 = 1: digit field, [10:8] font, [7:0] field number;  0xFFF = end.
Items (item ROM, sorted by x0)
  {y0[8:0], H[6:0], x0[9:0], slot[5:0]} - the RTL maps the slot to a string address and colour
  from the frame-latched state; slot 63 / string address 0 = nothing.

Outputs (next to the RTL; TD resolves $readmemh / INIT_FILE from the source directory):
  <prefix>_glyph.mif / .hex   glyph pixels, 8-bit words
  <prefix>_gtab.hex / .mif    glyph table {start[17:0], width[6:0]}
  <prefix>_str.hex / .mif     string ROM
  <prefix>_item.hex / .mif    item table   (tables padded to a power-of-two depth, 9K BRAM)
  <prefix>_ui.vh              localparams (string addresses, fonts, digit bases, sizes)
Usage: python ui3_assets.py [--board hall|clinic|all] [--out-root DIR]
"""
import argparse
import os
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
HDL = LAB / 'src/user_source/hdl_source'
FD = Path(os.environ.get('WINDIR', 'C:/Windows')) / 'Fonts'
REG, BOLD, NUMF = str(FD / 'msyh.ttc'), str(FD / 'msyhbd.ttc'), str(FD / 'segoeuib.ttf')
SS = 4                                   # supersampling factor
END = 0xFFF

# fonts whose digit set has '×' as field value 12 (10/26); DIGITS[v] = the glyph of field value v
DIGIT_X = {'hall': ('F20',)}
DIGITS = '0123456789 -×'
# palette indices (RTL ui_palette must agree)
INK, LABEL, TEAL, AMBER, GREEN, RED, TICK, WHITE = range(8)
PALETTE = [0x1F2933, 0x4B5563, 0x0E6E6E, 0xF08C00, 0x2E9E5B, 0xD64545, 0x374151, 0xFFFFFF]

SUB = '请先在触摸屏上登记报到，留意屏幕叫号与语音播报。需要帮助请点击“请帮助我”。'
PROMPTS = ['暂无候诊患者', '尚未叫号，暂无可重播的号码', '当前没有待回应的求助',
           '今日号源已发完', '正在处理，请勿重复操作', '操作太快，请稍候再试',
           '请稍候再操作', '求助已发出，请等待工作人员']


class Font:
    def __init__(self, name, ttf, px, h, ref='国', track=0):
        self.name, self.ttf, self.px, self.h, self.ref, self.track = name, ttf, px, h, ref, track
        self.big = ImageFont.truetype(ttf, px * SS)
        l, t, r, b = self.big.getbbox(ref, anchor='ls')
        self.base = (h * SS - (b - t)) // 2 - t          # baseline (4x units) centring the reference
        self.digit_w = max(self.adv(d) for d in '0123456789')

    def adv(self, ch):
        if ch == ' ':
            return max(2, round(self.px * 0.25))
        return max(1, round(self.big.getlength(ch) / SS)) + self.track

    def render(self, ch, width):
        """2-bit coverage, column-major list (width*h)."""
        img = Image.new('L', (width * SS, self.h * SS), 0)
        if ch != ' ':
            d = ImageDraw.Draw(img)
            x = (width * SS - self.big.getlength(ch)) / 2 if ch.isdigit() or ch in '-×' else self.track * SS / 2
            d.text((x, self.base), ch, font=self.big, fill=255, anchor='ls')
        small = img.resize((width, self.h), Image.Resampling.BOX)
        px = small.load()
        out = []
        for c in range(width):
            for r in range(self.h):
                v = px[c, r] / 255
                out.append(0 if v < 1 / 6 else 1 if v < 1 / 2 else 2 if v < 5 / 6 else 3)
        return out


def board_hall():
    fonts = [Font('F16', REG, 16, 20), Font('F20', REG, 20, 26), Font('F20B', BOLD, 20, 26),
             Font('F24B', BOLD, 24, 30), Font('BIG', NUMF, 92, 96, ref='0', track=2),
             Font('F30B', BOLD, 30, 38)]
    S = {}                                     # name -> (font, text); {n} = digit field n
    def s(name, font, text):
        S[name] = (font, text)
    s('TITLE', 'F24B', '耳鼻喉科 叫号')
    s('NET_OK', 'F16', '网口已连接'); s('NET_DOWN', 'F16', '网口未连接')
    s('CLIN_ON', 'F16', '诊室在线'); s('CLIN_OFF', 'F16', '诊室离线')
    s('ERR', 'F16', '图片错误 E{37}{38}')
    for i, w in enumerate(['语音文件缺失', '语音读卡错误', '语音播放超时']):
        s(f'VFAULT{i}', 'F16', w)            # header, in place of the photo error
    s('CALL_LABEL', 'F20B', '当前叫号')
    s('BIGNUM', 'BIG', '{0}{1}{2}')
    # 10/28 two-line call area: 请 [006] 号 / 到 [02] 诊室就诊; idle: 等待叫号 on line 1
    s('C1_PRE', 'F30B', '请'); s('C1_POST', 'F30B', '号'); s('C_WAIT', 'F30B', '等待叫号')
    s('C2_PRE', 'F30B', '到'); s('C2_POST', 'F30B', '诊室就诊')
    s('ROOMNUM', 'BIG', '{0}{39}')
    s('FLASH_TAG', 'F20B', '请留意屏幕')            # 10/26 "听力差" call badge (white on amber pill)
    s('LOADING', 'F20B', '照片加载中')
    for k_, t_ in [('L_NEXT', '下一位'), ('L_WAIT', '候诊'), ('L_ISSUED', '已报到'), ('L_HIST', '历史'),
                   ('L_ROOMS', '各诊室'), ('L_HELP', '求助')]:
        s(k_, 'F16', t_)
    s('V_NEXT', 'F20B', '{3}{4}{5}'); s('V_NEXT_NONE', 'F20B', '暂无')
    s('V_WAIT', 'F20B', '{6}{7} 人')
    s('V_ISSUED', 'F20B', '{8}{9}{10}')
    s('V_HIST', 'F20B', '{11}{12}{13} {14}{15}{16} {17}{18}{19}')
    for r in range(4):                         # room r: number digits 41+3r .. 43+3r
        s(f'ROOM{r}_ON', 'F20B', f'{r + 1}诊室 ' + ''.join('{%d}' % (41 + 3 * r + d) for d in range(3)))
        s(f'ROOM{r}_OFF', 'F20B', f'{r + 1}诊室 空闲')
    s('HELP0', 'F20B', '无'); s('HELP1', 'F20B', '待回应'); s('HELP2', 'F20B', '{40}诊室已确认')
    s('TIP', 'F20B', '温馨提示')
    s('TICKER', 'F20', SUB)
    s('A_BRI', 'F20', '亮度 {25}{26}{27}%'); s('A_CON', 'F20', '对比度 {28}{29}{30}%')
    s('A_MUS', 'F20', '音乐 {31}{32}{33}%'); s('A_VOI', 'F20', '语音 {34}{35}{36}%')
    s('A_AUTO', 'F20', '轮播 自动'); s('A_MANUAL', 'F20', '轮播 手动')
    for i, w in enumerate(PROMPTS):
        s(f'PROMPT{i}', 'F20', w)
    # 10/26 SW4: the picture shown and the resolution the board read from its BMP header.
    # 53 = picture 1..4; 54..62 = source "W×H" in 9 packed cells (bmp_res_info). 10/27: the shown
    # size (fields 63..68, still provided by bmp_res_info) is no longer printed - user decision
    s('RES_PIC', 'F20B', 'PIC{53}.BMP')
    s('RES_LINE', 'F20', '原图 ' + ''.join('{%d}' % n for n in range(54, 63)))
    # 10/28 call area geometry: small words share the baseline of the big digits
    fby = {f.name: f for f in fonts}
    big, small = fby['BIG'], fby['F30B']
    GAP, Y1, Y2 = 8, 86, 188                       # cell tops of the two digit rows
    def on_base(y):                                # small cell top with the digits' baseline
        return y + round(big.base / SS) - round(small.base / SS)
    x_big = 22 + small.adv('请') + GAP
    x1_post = x_big + 3 * big.digit_w + GAP
    x2_post = x_big + 2 * big.digit_w + GAP
    pill_x = x1_post + small.adv('号') + 14
    pill_y = Y1 + 48 - 15                          # centred on the digits (cell centre)
    # items: (slot name, x0, y0, font)  - slot names are the RTL's SL_* localparams
    items = [('TITLE', 18, 8, 'F24B'), ('ERR', 330, 14, 'F16'), ('NET', 470, 14, 'F16'),
             ('CLIN', 560, 14, 'F16'),
             ('CALL_LABEL', 22, 56, 'F20B'),
             ('C1_PRE', 22, on_base(Y1), 'F30B'), ('BIGNUM', x_big, Y1, 'BIG'), ('C1_POST', x1_post, on_base(Y1), 'F30B'),
             ('C2_PRE', 22, on_base(Y2), 'F30B'), ('ROOMNUM', x_big, Y2, 'BIG'), ('C2_POST', x2_post, on_base(Y2), 'F30B'),
             ('FLASH_TAG', pill_x + 14, pill_y + 2, 'F20B'),
             ('LOADING', 450, 150, 'F20B'),
             ('L_NEXT', 18, 337, 'F16'), ('V_NEXT', 72, 332, 'F20B'),
             ('L_WAIT', 160, 337, 'F16'), ('V_WAIT', 198, 332, 'F20B'),
             ('L_ISSUED', 296, 337, 'F16'), ('V_ISSUED', 350, 332, 'F20B'),
             ('L_HIST', 438, 337, 'F16'), ('V_HIST', 474, 332, 'F20B'),
             ('L_ROOMS', 18, 368, 'F16'), ('L_HELP', 470, 368, 'F16')]
    items += [(f'ROOM{r}', 18 + 112 * r, 388, 'F20B') for r in range(4)]
    items += [('V_HELP', 470, 388, 'F20B'),
              ('B0', 18, 442, 'F20B'), ('B1', 146, 442, 'F20'), ('B2', 290, 442, 'F20'),
              ('B3', 412, 442, 'F20'), ('B4', 534, 442, 'F20'), ('TICKER', 118, 442, 'F20'),
              ('RES_LINE', 132, 442, 'F20')]
    extra = {'TICKER_X0': 118, 'TICKER_X1': 622, 'TICKER_GAP': 120,
             'PILL_X0': pill_x, 'PILL_Y0': pill_y,             # "请留意屏幕" pill (RTL draws the shape)
             'UL_MUS_X0': 290, 'UL_VOI_X0': 412, 'UL_Y0': 469}  # adjust-line underline (B2 / B3 x0)
    return 'hall', fonts, S, items, extra


NEEDS = ['听力差 请书写', '说话困难', '头晕需搀扶', '需家属或翻译']
NEED_ZOOM = ['听力差，请书写交流', '说话困难，请耐心沟通', '头晕，请搀扶患者', '需要家属或手语翻译', '患者请求帮助']
SYMPTOMS = ['听力下降', '耳鸣', '耳痛或流脓', '鼻塞流涕', '鼻出血', '咽痛', '声音嘶哑', '吞咽困难或异物感', '头晕', '其他']


def board_clinic():
    fonts = [Font('F16', REG, 16, 20), Font('F20B', BOLD, 20, 26), Font('F24B', BOLD, 24, 30),
             Font('BIG', NUMF, 60, 64, ref='0', track=2)]
    S = {}
    def s(name, font, text):
        S[name] = (font, text)
    # fields: 0-2 room A number, 3-5 room B number (single mode: next number), 6-7 / 8-9 level A / B,
    # 10-11 waiting, 12-14 issued, 18 help room, 19 / 20 room A / B digit, 21 zoom room, 22-24 zoom number,
    # 25 / 26 zoom need card i / n (10/30)
    s('TITLE', 'F24B', '耳鼻喉科 诊室')
    s('QUEUE', 'F16', '候诊 {10}{11} 人   已报到 {12}{13}{14}')
    s('LINK_OK', 'F16', '链路正常'); s('LINK_DOWN', 'F16', '链路断开')
    s('A_ROOM', 'F24B', '{19} 诊室'); s('B_ROOM', 'F24B', '{20} 诊室'); s('B_QROOM', 'F24B', '候诊队列')
    s('L_CUR', 'F16', '当前患者'); s('L_NEXTQ', 'F16', '下一位')
    s('A_BIG', 'BIG', '{0}{1}{2}'); s('B_BIG', 'BIG', '{3}{4}{5}'); s('BIGNONE', 'BIG', '---')
    s('L_NEED', 'F16', '沟通需求'); s('L_WAITQ', 'F16', '候诊')
    for i, w in enumerate(NEEDS):
        s(f'NEED{i}', 'F20B', w)
    s('NEED_NONE', 'F20B', '无'); s('NEED_UNREG', 'F20B', '未登记')
    s('V_WAITQ', 'F20B', '{10}{11} 人')
    s('L_SYM', 'F16', '主要症状'); s('L_LVL', 'F16', '难受程度'); s('L_ISSUEDQ', 'F16', '已报到')
    for i, w in enumerate(SYMPTOMS):
        s(f'SYM{i}', 'F20B', w)
    s('SYM_NONE', 'F20B', '未填写'); s('V_ISSUEDQ', 'F20B', '{12}{13}{14}')
    s('A_LVL', 'F20B', '{6}{7} / 10'); s('B_LVL', 'F20B', '{8}{9} / 10'); s('LVL_NONE', 'F20B', '未填写')
    ops = ['叫下一位', '重播', '确认求助']
    res = [['发送中…', '已执行', '暂无候诊患者', '请求忙，请稍后', '未送达，请检查网线'],
           ['发送中…', '已执行', '尚未叫号', '请求忙，请稍后', '未送达，请检查网线'],
           ['发送中…', '已执行', '当前无求助或已被确认', '请求忙，请稍后', '未送达，请检查网线']]
    for o in range(3):
        for r in range(5):
            s(f'OP{o}_{r}', 'F16', f'{ops[o]}：{res[o][r]}')
    s('ALERT', 'F20B', '有患者求助，请前往'); s('HELP_TAKEN', 'F20B', '{18} 诊室已确认求助')
    s('A_KEY0', 'F16', 'KEY2 叫下一位   KEY3 重播'); s('A_KEY1', 'F16', 'KEY4 确认求助')
    s('B_KEY0', 'F16', '外接键1 叫下一位   键2 重播'); s('B_KEY1', 'F16', '外接键3 确认求助')
    for i, w in enumerate(NEED_ZOOM):
        s(f'ZOOM{i}', 'F20B', w)            # zoom box text (only when a card has no picture)
    # 10/30: fields 25 / 26 = need card i of n (clinic_need_trigger idx / total)
    s('ZOOM_TITLE', 'F24B', '{21} 诊室  {22}{23}{24} 号  需求 {25}/{26}'); s('ZOOM_HELP', 'F24B', '大厅患者请求帮助')
    # (slot, x0, y0, font). Items on one line must not overlap in x (the engine draws them in
    # x order); ZOOM / ZOOM_TITLE x comes from the RTL (centred).
    items = [('TITLE', 18, 8, 'F24B'), ('QUEUE', 300, 14, 'F16'), ('LINK', 556, 14, 'F16')]
    for c, x0 in (('A', 0), ('B', 320)):
        items += [(f'{c}_ROOM', x0 + 18, 56, 'F24B'), (f'{c}_LCUR', x0 + 18, 94, 'F16'),
                  (f'{c}_BIG', x0 + 14, 114, 'BIG'), (f'{c}_LNEED', x0 + 18, 196, 'F16'),
                  (f'{c}_NEED0', x0 + 18, 218, 'F20B'), (f'{c}_NEED1', x0 + 160, 218, 'F20B'),
                  (f'{c}_NEED2', x0 + 18, 248, 'F20B'), (f'{c}_NEED3', x0 + 160, 248, 'F20B'),
                  (f'{c}_LSYM', x0 + 18, 284, 'F16'), (f'{c}_LLVL', x0 + 196, 284, 'F16'),
                  (f'{c}_SYM', x0 + 18, 304, 'F20B'), (f'{c}_LVL', x0 + 196, 304, 'F20B'),
                  (f'{c}_OP', x0 + 18, 340, 'F16'), (f'{c}_HELP', x0 + 18, 372, 'F20B'),
                  (f'{c}_KEY0', x0 + 18, 414, 'F16'), (f'{c}_KEY1', x0 + 18, 438, 'F16')]
    items += [('ZOOM', 140, 0, 'F20B'), ('ZOOM_TITLE', 140, 384, 'F24B')]
    extra = {'GRID_X': 24, 'GRID_DX': 136, 'GRID_Y': 262, 'GRID_DY': 100, 'COL_W': 320}
    return 'clinic', fonts, S, items, extra


# Which strings each slot may show (mirrors the RTL slot cases). The text engine steps through a
# glyph's columns with the item's cell height, so every string must use a font of that height.
def _column(c):
    return {
        f'{c}_ROOM': [f'{c}_ROOM'] + (['B_QROOM'] if c == 'B' else []),
        f'{c}_LCUR': ['L_CUR', 'L_NEXTQ'], f'{c}_BIG': [f'{c}_BIG', 'BIGNONE'],
        f'{c}_LNEED': ['L_NEED', 'L_WAITQ'],
        f'{c}_NEED0': [f'NEED{k}' for k in range(4)] + ['NEED_NONE', 'NEED_UNREG', 'V_WAITQ'],
        **{f'{c}_NEED{s}': [f'NEED{k}' for k in range(4)] for s in (1, 2, 3)},
        f'{c}_LSYM': ['L_SYM', 'L_ISSUEDQ'], f'{c}_LLVL': ['L_LVL'],
        f'{c}_SYM': [f'SYM{i}' for i in range(10)] + ['SYM_NONE', 'V_ISSUEDQ'],
        f'{c}_LVL': [f'{c}_LVL', 'LVL_NONE'],
        f'{c}_OP': [f'OP{o}_{r}' for o in range(3) for r in range(5)], f'{c}_HELP': ['ALERT', 'HELP_TAKEN'],
        f'{c}_KEY0': [f'{c}_KEY0'], f'{c}_KEY1': [f'{c}_KEY1']}


SLOT_STRINGS = {
    'hall': {'ERR': ['ERR', 'VFAULT0', 'VFAULT1', 'VFAULT2'], 'NET': ['NET_OK', 'NET_DOWN'],
             'CLIN': ['CLIN_ON', 'CLIN_OFF'],
             'BIGNUM': ['BIGNUM'], 'C1_PRE': ['C1_PRE', 'C_WAIT'],
             'V_NEXT': ['V_NEXT', 'V_NEXT_NONE'], 'V_HELP': ['HELP0', 'HELP1', 'HELP2'],
             'B0': ['A_BRI', 'TIP', 'RES_PIC'] + [f'PROMPT{i}' for i in range(8)], 'B4': ['A_AUTO', 'A_MANUAL'],
             'B1': ['A_CON'], 'B2': ['A_MUS'], 'B3': ['A_VOI'],
             **{f'ROOM{r}': [f'ROOM{r}_ON', f'ROOM{r}_OFF'] for r in range(4)}},
    'clinic': {'LINK': ['LINK_OK', 'LINK_DOWN'], 'ZOOM': [f'ZOOM{i}' for i in range(5)],
               'ZOOM_TITLE': ['ZOOM_TITLE', 'ZOOM_HELP'],
               **_column('A'), **_column('B')},
}


def check_heights(name, fonts, S, items):
    fh = {f.name: f.h for f in fonts}
    for slot, x, y, fn in items:
        for s_ in SLOT_STRINGS[name].get(slot, [slot] if slot in S else []):
            assert fh[S[s_][0]] == fh[fn], f'{name}: string {s_} ({S[s_][0]}) in slot {slot} ({fn}) - cell heights differ'


def parse(text):
    """'ab{3}c' -> ['a', 'b', ('f', 3), 'c']"""
    out, i = [], 0
    while i < len(text):
        if text[i] == '{':
            j = text.index('}', i)
            out.append(('f', int(text[i + 1:j])))
            i = j + 1
        else:
            out.append(text[i])
            i += 1
    return out


def width_of(font, toks):
    return sum(font.digit_w if isinstance(t, tuple) else font.adv(t) for t in toks)


def build(board):
    name, fonts, S, items, extra = board
    check_heights(name, fonts, S, items)
    fidx = {f.name: i for i, f in enumerate(fonts)}
    # glyph set: fonts used by digit fields get 0-9, ' ', '-' first (glyphs DIGIT_BASE + 0..11),
    # then every character used. Blank glyphs (' ' field blank, 'SP') share one zero area at
    # pixel 0, so they cost no ROM.
    field_fonts = {fidx[fn] for fn, text in S.values() if any(isinstance(t, tuple) for t in parse(text))}
    glyphs = []                      # (font index, char, width)
    gid = {}
    digit_base = []
    for fi, f in enumerate(fonts):
        digit_base.append(len(glyphs) if fi in field_fonts else 0)
        if fi in field_fonts:
            for ch in '0123456789 -' + ('×' if f.name in DIGIT_X.get(name, ()) else ''):
                gid[(fi, ch)] = len(glyphs)
                glyphs.append((fi, ch, f.digit_w))       # field blanks keep the digit width
    for sname, (fn, text) in S.items():
        fi = fidx[fn]
        for t in parse(text):
            key = (fi, 'SP' if t == ' ' else t)
            if not isinstance(t, tuple) and key not in gid:
                gid[key] = len(glyphs)
                glyphs.append((fi, t, fonts[fi].adv(t)))
    blank = lambda ch: ch == ' '
    zero = max([w * fonts[fi].h for fi, ch, w in glyphs if blank(ch)] + [0])
    pix, gtab = [0] * ((zero + 3) // 4 * 4), []
    for fi, ch, w in glyphs:
        if blank(ch):
            gtab.append((0, w))
            continue
        gtab.append((len(pix), w))
        pix += fonts[fi].render(ch, w)
    while len(pix) % 4:
        pix.append(0)
    words = [pix[i] | pix[i + 1] << 2 | pix[i + 2] << 4 | pix[i + 3] << 6 for i in range(0, len(pix), 4)]
    # strings
    srom = [END]                     # address 0 = empty string
    saddr, swidth = {}, {}
    for sname, (fn, text) in S.items():
        fi = fidx[fn]
        saddr[sname] = len(srom)
        toks = parse(text)
        for t in toks:
            srom.append(0x800 | fi << 8 | t[1] if isinstance(t, tuple) else gid[(fi, 'SP' if t == ' ' else t)])
        srom.append(END)
        swidth[sname] = width_of(fonts[fi], toks)
    # items: clinic cells/zoom positions are centred on their longest string
    placed = []
    for slot, x, y, fn in items:
        f = fonts[fidx[fn]]
        if name == 'clinic' and slot == 'ZOOM':
            y = 240 - f.h // 2              # x comes from the RTL (centred per card)
        placed.append((slot, x, y, fi_h(f), fidx[fn]))
    placed.sort(key=lambda p: (p[1], p[2]))
    slots = sorted({p[0] for p in placed})
    slot_id = {s_: i for i, s_ in enumerate(slots)}
    irom = [(y << 23) | (h << 16) | (x << 6) | slot_id[s_] for s_, x, y, h, _ in placed]
    return dict(name=name, fonts=fonts, glyphs=glyphs, gid=gid, digit_base=digit_base, words=words,
                pix=pix, gtab=gtab, srom=srom, saddr=saddr, swidth=swidth, items=placed, irom=irom,
                slot_id=slot_id, extra=extra, strings=S, fidx=fidx)


def fi_h(f):
    return f.h


def write(b, out_dir, vh_dir=None):
    out_dir = Path(out_dir)
    p = b['name']
    n = len(b['words'])
    blk = GLYPH_BLOCK[p]
    depth = -(-n // blk) * blk          # whole 4K x 8 blocks (hall, 32K BRAM) / 1K x 8 (clinic, 9K BRAM)
    b['words'] += [0] * (depth - n)
    n = depth
    (out_dir / f'{p}_glyph.hex').write_text(''.join(f'{w:02x}\n' for w in b['words']), encoding='ascii')
    (out_dir / f'{p}_glyph.mif').write_text(
        f'DEPTH = {n};\nWIDTH = 8;\nADDRESS_RADIX = HEX;\nDATA_RADIX = HEX;\nCONTENT\nBEGIN\n' +
        ''.join(f'{i:05x} : {w:02x};\n' for i, w in enumerate(b['words'])) + 'END;\n', encoding='ascii')
    # small tables: .hex for simulation, .mif (power-of-two depth) for the 9K BRAM (ui_table_rom.v)
    tables = {'gtab': ([s << 7 | w for s, w in b['gtab']], 25), 'str': (b['srom'], 12), 'item': (b['irom'], 32)}
    aw = {}
    for k, (vals, width) in tables.items():
        digits = (width + 3) // 4
        a = max(1, (len(vals) - 1).bit_length())
        aw[k] = a
        full = vals + [0] * ((1 << a) - len(vals))
        (out_dir / f'{p}_{k}.hex').write_text(''.join(f'{v:0{digits}x}\n' for v in full), encoding='ascii')
        (out_dir / f'{p}_{k}.mif').write_text(
            f'DEPTH = {len(full)};\nWIDTH = {width};\nADDRESS_RADIX = HEX;\nDATA_RADIX = HEX;\nCONTENT\nBEGIN\n' +
            ''.join(f'{i:03x} : {v:0{digits}x};\n' for i, v in enumerate(full)) + 'END;\n', encoding='ascii')
    L = [f'// generated by verification/ui3/ui3_assets.py - do not edit ({p})']
    L.append(f'localparam integer UI_GLYPH_WORDS = {n}, UI_GLYPHS = {len(b["gtab"])}, '
             f'UI_STR_WORDS = {len(b["srom"])}, UI_ITEMS = {len(b["irom"])};')
    L.append(f'localparam UI_GLYPH_BRAM = "{"32K" if GLYPH_BLOCK[p] == 4096 else "9K"}";')
    L.append(f'localparam integer UI_GTAB_AW = {aw["gtab"]}, UI_STR_AW = {aw["str"]}, UI_ITEM_AW = {aw["item"]};')
    for i, f in enumerate(b['fonts']):
        L.append(f'localparam integer FONT_{f.name} = {i}, H_{f.name} = {f.h}, DW_{f.name} = {f.digit_w};')
    L.append('function [9:0] font_digit_base; input [2:0] f; begin case (f) ' +
             ' '.join(f'{i}: font_digit_base = 10\'d{v};' for i, v in enumerate(b['digit_base'])) +
             ' default: font_digit_base = 10\'d0; endcase end endfunction')
    for s_, a in b['saddr'].items():
        L.append(f'localparam [11:0] S_{s_} = 12\'d{a};   localparam integer W_{s_} = {b["swidth"][s_]};')
    for s_, i in b['slot_id'].items():
        L.append(f'localparam [5:0] SL_{s_} = 6\'d{i};')
    for k, v in b['extra'].items():
        L.append(f'localparam integer {k} = {v};')
    if 'TICKER' in b['swidth']:
        L.append(f'localparam integer TICKER_PERIOD = {b["swidth"]["TICKER"] + b["extra"]["TICKER_GAP"]};')
    (Path(vh_dir or out_dir) / f'{p}_ui.vh').write_text('\n'.join(L) + '\n', encoding='ascii')
    return n


# glyph ROM block: the hall has free 32K BRAMs; the clinic's 32K BRAMs all hold the card pictures
GLYPH_BLOCK = {'hall': 4096, 'clinic': 1024}
# ROM files go next to ui_glyph_rom.v / ui_table_rom.v (TD resolves INIT_FILE / $readmemh from the
# directory of the file that holds the memory); the .vh goes next to the screen that includes it.
BOARDS = {'hall': (board_hall, HDL / 'display', HDL / 'display'),
          'clinic': (board_clinic, HDL / 'display', HDL / 'clinic')}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--board', default='all')
    ap.add_argument('--out-root', type=Path)
    a = ap.parse_args()
    for k, (fn, d, vd) in BOARDS.items():
        if a.board not in ('all', k):
            continue
        b = build(fn())
        out = (a.out_root / k) if a.out_root else d
        out.mkdir(parents=True, exist_ok=True)
        n = write(b, out, None if a.out_root else vd)
        print(f'{k}: {len(b["gtab"])} glyphs, {len(b["pix"])} pixels = {n} bytes '
              f'({n * 8 / 32768:.1f} x 32K blocks), {len(b["srom"])} string words, {len(b["irom"])} items')


if __name__ == '__main__':
    main()
