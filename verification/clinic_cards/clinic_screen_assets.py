"""Clinic screen assets: text templates and a 16x16 Chinese font ROM for clinic_screen.v.

Kept separate from hospital_screen's ROMs on purpose: the hall screen is already accepted on
hardware, so nothing here can disturb it. This file is the single authority for what the
clinic screen says and where the digit fields sit; clinic_screen.v declares the same numbers
and this script checks them before writing.

Generates (next to the RTL, where TD's $readmemh looks):
  clinic_font.hex   GLYPH_SLOTS*16 lines, 16-bit row bitmaps, bit 15 = leftmost pixel
  clinic_text.hex   TEMPLATE_SLOTS*64 lines, 8-bit glyph code per template column
"""
import argparse
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]          # 10/23 copy: lab_ex5_i2s
RTL_DIR = ROOT / 'src/user_source/hdl_source/clinic'
RTL = RTL_DIR / 'clinic_screen.v'
sys.path.insert(0, str(Path(__file__).resolve().parent))
import screen_assets  # noqa: E402  (DIGITS, render_glyph, FONT_FILE)

GLYPH_SLOTS, TEMPLATE_SLOTS, COLS = 192, 40, 64
BIG_COLS, LINE_COLS = 20, 40
DIGITS = screen_assets.DIGITS
CARDS = ['请帮助我', '请写下来', '请再说一遍', '是', '不是', '不是这个意思']
HELP_WORDS = ['无', '待回应', '已确认']
# Result of the doctor's last press (V8 fix 10/07): OPS x RESULTS, template 21 + 5*op + result.
OPS = ['叫下一位', '重播', '确认求助']
# per op: sending, done, not possible now (business rule), busy, not delivered
RESULTS = [
    ['发送中…', '已执行', '未执行：暂无候诊患者', '未执行：请求忙，请稍后', '未送达，请检查网线后重按'],
    ['发送中…', '已执行', '未执行：尚未叫号', '未执行：请求忙，请稍后', '未送达，请检查网线后重按'],
    ['发送中…', '已执行', '未执行：当前无求助', '未执行：请求忙，请稍后', '未送达，请检查网线后重按'],
]


def centered(text, width):
    return ' ' * ((width - len(text)) // 2) + text


def templates():
    t = {
        0: centered('诊室医生端', BIG_COLS),        # T_TITLE (32x32)
        1: centered('###号', BIG_COLS),             # T_BIG (32x32 call number)
        2: centered('无叫号', BIG_COLS),            # T_NOCALL_BIG (32x32)
        6: centered('有患者求助，请前往诊室', LINE_COLS),   # T_ALERT
        7: centered('下一位：###号', LINE_COLS),    # T_NEXT
        8: centered('候诊人数：##人', LINE_COLS),   # T_WAIT
        9: centered('已取号：###号', LINE_COLS),    # T_ISSUED
        16: centered('患者表达：暂无', LINE_COLS),  # T_EXPR_NONE
        # Bottom line: link state in columns 0..9, key legend from column 10 (not centred:
        # each part is drawn in its own column range by clinic_screen.v).
        17: ' 链路：正常',                              # T_LINK_OK
        18: ' 链路：断开',                              # T_LINK_DOWN
        19: 'KEY2 叫下一位  KEY3 重播  KEY4 确认求助',   # T_KEYS (board silkscreen names)
        20: centered('下一位：暂无', LINE_COLS),        # T_NEXT_NONE (nobody waiting)
        36: centered('操作：无', LINE_COLS),            # T_OP_NONE
    }
    for o, op in enumerate(OPS):
        for r, res in enumerate(RESULTS[o]):
            t[21 + 5 * o + r] = centered('操作：' + op + ' ' + res, LINE_COLS)   # T_OP
    for i, w in enumerate(HELP_WORDS):
        t[3 + i] = centered('求助：' + w, LINE_COLS)          # T_HELP + help_state
    for i, w in enumerate(CARDS):
        t[10 + i] = centered('患者表达：' + w, LINE_COLS)     # T_EXPR + card
    t[0]='诊室医生端'
    t[1]='###'
    t[2]='---'
    t[6]='有患者求助'
    t[7]='下一位 ###'
    t[8]='候诊 ##人'
    t[9]='已取号 ###'
    for i,w in enumerate(HELP_WORDS):t[3+i]='求助：'+w
    for i,w in enumerate(CARDS):t[10+i]='患者表达：'+w
    t[16]='患者表达：暂无'
    t[17]='链路正常'
    t[18]='链路断开'
    t[20]='下一位 暂无'
    for o,op in enumerate(OPS):
        for r,res in enumerate(RESULTS[o]):t[21+5*o+r]='操作：'+op+' '+res
    t[36]='操作：无'
    t[37]='求助待处理'
    t[38]='当前号码'
    t[39]='最近号码'
    return t


def layout():
    """Localparams clinic_screen.v must declare."""
    t = templates()
    return {
        'T_TITLE': 0, 'T_BIG': 1, 'T_NOCALL_BIG': 2, 'T_HELP': 3, 'T_ALERT': 6,
        'T_NEXT': 7, 'T_WAIT': 8, 'T_ISSUED': 9, 'T_EXPR': 10, 'T_EXPR_NONE': 16,
        'T_LINK_OK': 17, 'T_LINK_DOWN': 18, 'T_KEYS': 19, 'T_NEXT_NONE': 20,
        'T_OP': 21, 'T_OP_NONE': 36,
        'BIG_D0': t[1].index('#'),
        'NEXT_D0': t[7].index('#'),
        'WAIT_D0': t[8].index('#'),
        'ISSUED_D0': t[9].index('#'),
    }


def check_rtl(values):
    text = RTL.read_text(encoding='utf-8')
    found = {k: int(v) for k, v in re.findall(r'\b([A-Z][A-Z0-9_]*)\s*=\s*(\d+)\b', text)}
    bad = {k: (v, found.get(k)) for k, v in values.items() if found.get(k) != v}
    if bad:
        raise RuntimeError('clinic_screen.v localparams differ from this tool: ' +
                           ', '.join(f'{k}: assets={v} rtl={r}' for k, (v, r) in bad.items()))


def build():
    t = templates()
    for tid, text in t.items():
        limit = BIG_COLS if tid <= 2 else 10 if tid in (17, 18) else 30 if tid == 19 else LINE_COLS
        if len(text) > limit:
            raise ValueError(f'template {tid} longer than {limit}: {text}')
    chars = [' '] + list(DIGITS)
    for tid in sorted(t):
        for ch in t[tid]:
            if ch != '#' and ch not in chars:
                chars.append(ch)
    if len(chars) > GLYPH_SLOTS:
        raise ValueError(f'{len(chars)} glyphs > {GLYPH_SLOTS}')
    code = {ch: i for i, ch in enumerate(chars)}
    text_rom = [0] * (TEMPLATE_SLOTS * COLS)
    for tid, text in t.items():
        for col, ch in enumerate(text):
            text_rom[tid * COLS + col] = 0 if ch == '#' else code[ch]
    from PIL import ImageFont
    font = ImageFont.truetype(str(screen_assets.FONT_FILE), 16)
    font_rom = []
    for ch in chars:
        font_rom += screen_assets.render_glyph(font, ch)
    font_rom += [0] * (GLYPH_SLOTS * 16 - len(font_rom))
    font_rom = screen_assets.outline_rows(font_rom)
    return t, chars, code, text_rom, font_rom


def write(out_dir=RTL_DIR):
    t, chars, code, text_rom, font_rom = build()
    check_rtl(layout())
    out_dir = Path(out_dir)
    screen_assets.write_digits(out_dir)
    (out_dir / 'clinic_font.hex').write_text(''.join(f'{v:08x}\n' for v in font_rom), encoding='ascii')
    (out_dir / 'clinic_text.hex').write_text(''.join(f'{v:02x}\n' for v in text_rom), encoding='ascii')
    return len(chars)


if __name__ == '__main__':
    argparse.ArgumentParser(description=__doc__).parse_args()
    print(f'{write()} glyphs written to {RTL_DIR}')
