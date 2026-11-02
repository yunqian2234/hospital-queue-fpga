"""Hospital screen assets: text templates, 16x16 Chinese font ROM, layout constants.

Single authority for what the HDMI hospital screen says. Generates, next to the RTL
(TD requires $readmemh files in the .v source directory):
  hospital_font.hex   GLYPHS*16 lines, 16-bit row bitmaps, bit 15 = leftmost pixel
  hospital_text.hex   TEMPLATES*64 lines, 8-bit glyph code per template column
  hospital_font_head/tail.hex   hardware banks 128+64 glyphs (same font, no duplicate OSD)
  hospital_edge.hex             outline rows for the first 64 photograph glyphs
  ui_digits.hex                native 56x96 number spans, 48-bit rows
  ui_geometry.hex              one shared immutable row/column descriptor bank
  ui_card_x.hex                card column/glyph position per raster X
hospital_font.hex remains the complete 192-glyph reference artifact.
The hardware banks concatenate exactly to that file. Also writes a font sheet PNG for review. The layout numbers (template ids,
field columns, card spans) are declared as localparams in hospital_screen.v; this
script checks them against the RTL and refuses to write if they disagree.

Font: Windows Microsoft YaHei (msyh.ttc), rendered offline at 16 px with Pillow.
"""
import argparse
import os
from pathlib import Path
import re
import sys

from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = ROOT / '01_project/lab_ex5_i2s/src/user_source/hdl_source/display'
RTL = RTL_DIR / 'hospital_screen.v'
FONT_FILE = Path(os.environ.get('FPGA_UI_FONT', str(Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts/msyh.ttc')))
GLYPH_SLOTS, TEMPLATE_SLOTS, COLS = 192, 64, 64
COLUMN_DEFS=[(0, 40, 0), (16, 4, 1), (16, 14, 0), (16, 38, 0), (28, 4, 0), (28, 7, 0), (28, 9, 0), (28, 10, 0), (32, 3, 0), (32, 4, 0), (32, 5, 0), (32, 5, 1), (32, 6, 0), (32, 7, 0), (32, 14, 0), (80, 2, 0), (92, 2, 0), (92, 6, 0), (96, 3, 0), (112, 6, 0), (208, 6, 0), (260, 4, 0), (276, 11, 0), (368, 3, 1), (368, 6, 1), (368, 7, 0), (368, 7, 1), (400, 14, 0), (432, 10, 0), (448, 4, 0), (464, 2, 1), (512, 3, 0)]
ROW_DEFS=[(8, 1), (24, 0), (78, 1), (80, 0), (80, 1), (82, 0), (94, 0), (120, 0), (132, 1), (150, 1), (156, 0), (176, 1), (192, 0), (228, 0), (232, 0), (250, 0), (252, 0), (262, 0), (278, 0), (302, 0), (328, 0), (330, 0), (364, 0), (388, 0), (416, 0), (464, 0)]
DIGITS = '０１２３４５６７８９'

# Placeholders (one column each): '#' digit field, '$' help word, '@' voice word.
BANNER_COLS, LINE_COLS, SUB_COLS = 20, 40, 64
CARDS = ['请帮助我', '请写下来', '请再说一遍', '是', '不是', '不是这个意思']


def centered(text, width):
    pad = (width - len(text)) // 2
    return ' ' * pad + text


STATUS = ' 亮度###％  对比度###％  求助：$$$  语音：@@@'
VOICE_WORDS = ['正常', '跳过', '无文件', '读卡错', '超时', '关闭', '－－', '播放中']
HELP_WORDS = ['无', '待回应', '已确认']
SUBTITLE = '温馨提示：请先在触摸屏上取号，留意屏幕叫号与语音播报。需要帮助请点击“请帮助我”。'
# V7 queue line (always shown under the banner). Both variants must keep the count and
# issued fields in the same columns; layout() checks this.
QUEUE = '  下一位：###号    候诊：##人    已取号：###号'
QUEUE_NONE = '  下一位：暂无      候诊：##人    已取号：###号'


def templates():
    t = {
        0: centered('请###号患者到诊室就诊', BANNER_COLS),          # T_CALL
        1: centered('等待叫号', BANNER_COLS),                       # T_IDLE
        2: centered('暂无候诊患者，无法叫下一号', LINE_COLS),       # T_P_LAST (K1, nobody waiting)
        3: centered('尚未叫号，暂无可重播的号码', LINE_COLS),       # T_P_NOCALL
        4: centered('当前没有待回应的求助', LINE_COLS),             # T_P_NOHELP
        5: centered('今日号源已取完', LINE_COLS),                   # T_P_SPARE (K8 ticket refused)
        6: centered('正在处理，请勿重复操作', LINE_COLS),           # T_P_DUP
        7: centered('操作太快，请稍候再试', LINE_COLS),             # T_P_FULL
        8: centered('请勿同时按上一张和下一张', LINE_COLS),         # T_P_CONFLICT
        9: centered('求助已发出，请等待工作人员', LINE_COLS),       # T_P_HELPDUP
        10: centered('请在触摸屏上点击卡片表达需求', LINE_COLS),   # T_EXPR_IDLE
        11: SUBTITLE,                                               # T_SUB
        12: STATUS,                                                 # T_STATUS
    }
    for i, w in enumerate(HELP_WORDS):
        t[13 + i] = w                                               # T_HELP + help_state
    for i, w in enumerate(VOICE_WORDS):
        t[16 + i] = w                                               # T_VOICE + voice index
    for i, w in enumerate(CARDS):
        t[24 + i] = centered('患者表达：' + w, LINE_COLS)           # T_EXPR + card
    t[30] = QUEUE                                                   # T_QUEUE
    t[31] = QUEUE_NONE                                              # T_QUEUE_NONE
    # Product UI templates; same single text/font pipeline as the existing screen.
    t[1] = centered('当前叫号 ---',20)
    t[10] = '已提交：暂无'
    for i, w in enumerate(HELP_WORDS): t[13+i] = '求助：'+w
    for i, w in enumerate(CARDS): t[24+i] = '已提交：'+w
    t[32] = '历史 ### ### ###'
    for i in range(4):
        t[33+i] = '网口：'+('通' if i&2 else '断')+' 诊室：'+('在线' if i&1 else '离线')
    t[37] = centered('K6选卡 K7短按重播预览 长按K7回主页',40)
    t[38] = centered('K4上一张 K5下一张 K6预览 长按K7回主页',40)
    t[39] = centered('K6确认播放 长按K7取消并回主页',40)
    t[40] = '表达预览'
    t[41] = '重播预览'
    t[42] = centered('确认重播 ### 号',26)
    t[43] = '播报：叫号###号'
    t[44] = '播报：待机'
    t[45] = '待语音# 总未完# 语音@@@'
    t[46] = '亮度###％ 对比###％ 自动 图# 错##'
    t[47] = t[46].replace('自动','手动')
    for i,w in enumerate(CARDS): t[48+i] = w.center(6)
    for i,w in enumerate(['已加入语音队列','尚未叫号，暂无可重播号码','请求无效，请重新选择','相同请求正在处理，请稍候','语音队列已满，请稍后再确认','操作冲突，请分别操作']):
        t[54+i]=centered(w,40)
    t[60]='播报：'
    t[61]='播报：求助应答'
    t[62]='播报：重播###号'
    t[63]=centered('照片加载中，请检查TF卡',38)
    # B layout reuses the same 64-slot text ROM and 192 glyphs.
    t[0] = '门诊叫号        请到诊室就诊'
    t[1] = '当前叫号      当前选择：'
    t[10] = '暂无'
    t[12] = '下一位 ###'
    t[30] = '候诊 ##人'
    t[31] = '已取号 ###'
    t[40] += '       请选择表达'
    t[45] = t[45].replace(' 语音','／８ 语音')
    t[42] = 'K6确认 长按K7取消 ###'
    return t


def layout():
    t = templates()
    call = t[0]
    status = t[12]
    queue = t[30]
    wait_d0 = queue.index('#')
    issued_d0 = t[31].index('#')
    return {
        'GLYPH_SLOTS': GLYPH_SLOTS, 'TEMPLATE_SLOTS': TEMPLATE_SLOTS,
        'ROW_FLAG_COUNT':len(ROW_DEFS),'ROW_FLAG_WORDS':256,
        'COLUMN_FLAG_COUNT':32,'COLUMN_FLAG_WORDS':256,
        'T_HISTORY':32,'T_LINK':33,'T_HINT':37,'T_CARD':48,'T_NOTICE':53,
        'HISTORY_D0':t[32].index('#'),'PREVIEW_D0':t[42].index('#'),
        'ACTIVE_D0':t[43].index('#'),'WAIT_VOICE_D0':t[45].index('#'),
        'TOTAL_D0':t[45].index('#',t[45].index('#')+1),'VOICE_D0':t[45].index('@'),
        'BRI_D0':t[46].index('#'),'CON_D0':t[46].index('#',t[46].index('％')),
        'IMAGE_D0':t[46].index('#',t[46].index('图')),'ERROR_D0':t[46].index('#',t[46].index('错')),
        'CALL_D0':5,'NEXT_D0':t[12].index('#'),'WAIT_D0':t[30].index('#'),'ISSUED_D0':t[31].index('#'),
        'CARD_LEFT':28,'CARD_PITCH':198,'CARD_WIDTH':188,'CARD_TOP':156,'CARD_BOTTOM':272,
        'PHOTO_TOP':64,'PHOTO_BOTTOM':302,'WAVE_TOP':384,'WAVE_BOTTOM':408,
    }



def render_glyph(font, ch):
    img = Image.new('L', (16, 16), 0)
    if ch != ' ':
        draw = ImageDraw.Draw(img)
        box = draw.textbbox((0, 0), ch, font=font)
        w, h = box[2] - box[0], box[3] - box[1]
        draw.text(((16 - w) // 2 - box[0], (16 - h) // 2 - box[1]), ch, font=font, fill=255)
    rows = []
    for y in range(16):
        bits = 0
        for x in range(16):
            bits = (bits << 1) | (img.getpixel((x, y)) >= 110)
        rows.append(bits)
    return rows


def build():
    t = templates()
    assert all(len(t[48+i])==6 for i in range(6))
    assert 28+2*198+188<=640 and 6*24<=188-4
    assert len(t[45])<=19 and len(t[32])<=25
    for tid, text in t.items():
        limit = BANNER_COLS if tid < 2 else SUB_COLS if tid == 11 else LINE_COLS
        if len(text) > limit:
            raise ValueError(f'template {tid} longer than {limit}: {text}')
    chars = [' '] + list(DIGITS) + list('ABCDEF')
    photo_text=t[0][:4]+t[0][12:]+t[1]+t[10]+t[12]+t[30]+t[31]+t[32]+t[40][11:]+'－'+''.join(t[48+i] for i in range(6))
    for ch in photo_text:
        if ch not in '#$@' and ch not in chars:chars.append(ch)
    assert len(chars)<=64, 'photographic outline bank overflow'
    for tid in sorted(t):
        for ch in t[tid]:
            if ch not in '#$@' and ch not in chars:
                chars.append(ch)
    if len(chars) > GLYPH_SLOTS:
        raise ValueError(f'{len(chars)} glyphs > {GLYPH_SLOTS}')
    code = {ch: i for i, ch in enumerate(chars)}
    text_rom = [0] * (TEMPLATE_SLOTS * COLS)
    for tid, text in t.items():
        for col, ch in enumerate(text):
            text_rom[tid * COLS + col] = 0 if ch in '#$@' else code[ch]
    font = ImageFont.truetype(str(FONT_FILE), 16)
    font_rom = []
    for ch in chars:
        font_rom += render_glyph(font, ch)
    font_rom += [0] * (GLYPH_SLOTS * 16 - len(font_rom))
    font_rom = outline_rows(font_rom)
    return t, chars, code, text_rom, font_rom


def outline_rows(rows):
    # Upper plane is a one-pixel white outline. Both planes share one BRAM address.
    result=[]
    for base in range(0,len(rows),16):
        for y in range(16):
            dil=0
            for yy in range(max(0,y-1),min(16,y+2)):
                r=rows[base+yy];dil|=r|(r<<1)|(r>>1)
            result.append(((dil&65535)<<16)|rows[base+y])
    return result


def write_digits(out_dir):
    font=ImageFont.truetype(str(Path(os.environ.get('WINDIR','C:/Windows'))/'Fonts/segoeuib.ttf'),96)
    words=[]
    def runs(bits):
        ans=[];start=None
        for x,on in enumerate(bits+[False]):
            if on and start is None:start=x
            if not on and start is not None:ans.append((start,x));start=None
        return ans
    def clean(bits):
        # Tiny threshold specks in rasterized curves are merged offline, never at runtime.
        spans=runs(bits)
        while len(spans)>2:
            i=min(range(len(spans)-1),key=lambda i:spans[i+1][0]-spans[i][1])
            for x in range(spans[i][1],spans[i+1][0]):bits[x]=True
            spans=runs(bits)
        return bits
    def encode(bits):
        spans=runs(clean(bits));spans+= [(0,0)]*(2-len(spans))
        return spans[0][0]|(spans[0][1]<<6)|(spans[1][0]<<12)|(spans[1][1]<<18)
    for ch in '0123456789-':
        height=64 if ch=='-' else 96
        m=Image.new('L',(56,height),0)
        if ch=='-':ImageDraw.Draw(m).rectangle((4,46,51,51),fill=255)
        else:
            bb=font.getbbox(ch);raw=Image.new('L',(bb[2]-bb[0],bb[3]-bb[1]),0)
            ImageDraw.Draw(raw).text((-bb[0],-bb[1]),ch,font=font,fill=255)
            m.paste(raw.resize((52,80),Image.Resampling.LANCZOS),(2,8))
        for yy in range(height):
            row=clean([m.getpixel((xx,yy))>=110 for xx in range(56)])
            for xx,on in enumerate(row):m.putpixel((xx,yy),255 if on else 0)
        edge=m.filter(ImageFilter.MaxFilter(3))
        for yy in range(height):
            words.append(encode([m.getpixel((xx,yy))!=0 for xx in range(56)]) |
                         (encode([edge.getpixel((xx,yy))!=0 for xx in range(56)])<<24))
    assert len(words)==1024
    (Path(out_dir)/'ui_digits.hex').write_text(''.join(f'{v:012x}\n' for v in words),encoding='ascii')


def check_rtl(values):
    text = RTL.read_text(encoding='utf-8')
    found = {k: int(v) for k, v in re.findall(r'\b([A-Z][A-Z0-9_]*)\s*=\s*(\d+)\b', text)}
    bad = {k: (v, found.get(k)) for k, v in values.items() if found.get(k) != v}
    if bad:
        raise RuntimeError('hospital_screen.v localparams differ from screen_assets.py: ' +
                           ', '.join(f'{k}: assets={v} rtl={r}' for k, (v, r) in bad.items()))


def write(out_dir=RTL_DIR, sheet=None):
    t, chars, code, text_rom, font_rom = build()
    check_rtl(layout())
    out_dir = Path(out_dir)
    write_digits(out_dir)
    row_words=[sum(1<<i for i,(y0,dbl) in enumerate(ROW_DEFS) if y0<=2*y<y0+(32 if dbl else 16)) for y in range(256)]
    row_words=[v | ((1<<26) if 156<=2*i<208 or 220<=2*i<272 else 0) for i,v in enumerate(row_words)]
    assert all(y%2==0 for y,dbl in ROW_DEFS)
    column_words=[sum(1<<i for i,(x0,n,dbl) in enumerate(COLUMN_DEFS) if x0<=4*x<x0+n*(32 if dbl else 16)) for x in range(256)]
    (out_dir/'ui_geometry.hex').write_text(''.join(f'{v:08x}\n' for v in row_words+column_words),encoding='ascii')
    rtl=RTL.read_text(encoding='utf-8')
    for i,(x,n,dbl) in enumerate(COLUMN_DEFS):
        if f"19'd{(dbl<<18)+(x<<6)+n}:column_slot=6'd{i};" not in rtl:raise ValueError('column ROM mapping differs from RTL')
    for i,(y,dbl) in enumerate(ROW_DEFS):
        if f"13'd{y+4096*dbl}:row_slot=5'd{i};" not in rtl:raise ValueError('scanline ROM mapping differs from RTL')
    # Split 192 glyphs into 128+64, avoiding power-of-two padding to 256.
    for name,part in [('hospital_font_head.hex',font_rom[:2048]),('hospital_font_tail.hex',font_rom[2048:])]:
        (out_dir/name).write_text(''.join(f'{v&65535:04x}\n' for v in part),encoding='ascii')
    card=[]
    for x in range(1024):
        col=0 if x<226 else 1 if x<424 else 2
        dx=x-[28,226,424][col];text=22<=dx<166
        char=(dx-22)//24 if text else 7
        bit=((dx-22)%24)*2//3 if text else 0
        card.append(col|(char<<2)|(bit<<5))
    (out_dir/'ui_card_x.hex').write_text(''.join(f'{v:03x}\n' for v in card),encoding='ascii')
    (out_dir / 'hospital_font.hex').write_text(''.join(f'{v&65535:04x}\n' for v in font_rom), encoding='ascii')
    (out_dir / 'hospital_edge.hex').write_text(''.join(f'{v>>16:04x}\n' for v in font_rom[:1024]),encoding='ascii')
    (out_dir / 'hospital_text.hex').write_text(''.join(f'{v:02x}\n' for v in text_rom), encoding='ascii')
    if sheet:
        img = Image.new('RGB', (16 * 16 * 2, ((len(chars) + 15) // 16) * 16 * 2), (11, 23, 36))
        for i in range(len(chars)):
            ox, oy = (i % 16) * 32, (i // 16) * 32
            for y in range(16):
                for x in range(16):
                    if font_rom[i * 16 + y] >> (15 - x) & 1:
                        img.putpixel((ox + 2 * x, oy + 2 * y), (255, 255, 255))
                        img.putpixel((ox + 2 * x + 1, oy + 2 * y), (255, 255, 255))
                        img.putpixel((ox + 2 * x, oy + 2 * y + 1), (255, 255, 255))
                        img.putpixel((ox + 2 * x + 1, oy + 2 * y + 1), (255, 255, 255))
        img.save(sheet)
    return len(chars)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--sheet', type=Path, help='write a font sheet PNG for review')
    args = parser.parse_args()
    try:
        print(f'{write(sheet=args.sheet)} glyphs written to {RTL_DIR}')
    except Exception as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)


