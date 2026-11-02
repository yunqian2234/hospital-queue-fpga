"""10/24 UI v3 reference renderer for the hall and clinic screens (written from the layout
specification, not from the RTL).

Content (glyph coverage, strings, item positions) comes from ui3_assets.build() - the one content
authority both the RTL ROMs and this model use. Everything else is re-implemented here from the
spec in the RTL file headers:
  * layout: each item's string is drawn from (x0, y0) glyph after glyph, digit fields take the
    font's digit glyphs (value 10 = blank, 11 = '-'); text is clipped to the screen, the ticker
    to [TICKER_X0, TICKER_X1) and repeats with TICKER_GAP, starting at TICKER_X0 - scroll; a glyph
    with fewer than two visible columns at the left clip is not drawn
  * which string / colour each slot shows (state rules below)
  * 10/26 SW4 resolution line: "PIC<n>.BMP" in B0 and "原图 W×H → 显示 w×h" in place of the ticker
    (only with a picture ready and no adjust line / prompt); res_cells() writes the text
  * page: hall = photo with the header (y < 46) and the information block (y >= 322) lifted to
    v*5/8 + 96 ((v>>1)+(v>>3)+96), rules y 45 and 428 (x 18..621) d2d6dc, teal accent x 18..45 y 41..43;
    clinic = the warm-white page with rules, card cells and the zoom panel
  * blending: out = b + ((f - b) * k) >> 8, k = 85 / 171 for coverage 1 / 2, f for 3, b for 0
"""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ui3_assets as A  # noqa: E402

INK, LABEL, TEAL, AMBER, GREEN, RED, TICK = 0x1F2933, 0x4B5563, 0x0E6E6E, 0xF08C00, 0x2E9E5B, 0xD64545, 0xC2410C
C_LABEL = 0x6B7280                                   # clinic label grey
_cache = {}


def assets(board):
    if board not in _cache:
        _cache[board] = A.build(A.board_hall() if board == 'hall' else A.board_clinic())
    return _cache[board]


def tens(v):
    return 2 if v >= 20 else 1 if v >= 10 else 0


def ones(v):
    return v % 10


def chan(c, s):
    return (c >> s) & 255


def mix(b, f, a):
    if a == 0:
        return b
    if a == 3:
        return f
    k = 85 if a == 1 else 171
    out = 0
    for s in (16, 8, 0):
        bb, ff = chan(b, s), chan(f, s)
        out |= ((bb + (((ff - bb) * k) >> 8)) & 255) << s
    return out


def lift(c):
    return sum((((chan(c, s) >> 1) + (chan(c, s) >> 3) + 96) & 255) << s for s in (16, 8, 0))


def draw_text(b, slots, fields, scroll=0):
    """slots: name -> (string name or None, colour[, x override]). Returns {(x, y): (cov, colour)}."""
    fonts, gid, gtab, pix = b['fonts'], b['gid'], b['gtab'], b['pix']
    ex = b['extra']
    layer = {}
    for slot, x0, y0, h, fi in b['items']:
        if slot not in slots or slots[slot][0] is None:
            continue
        sname, colour = slots[slot][0], slots[slot][1]
        if len(slots[slot]) > 2:
            x0 = slots[slot][2]
        sfont, text = b['strings'][sname]
        sf = b['fidx'][sfont]
        toks = A.parse(text)
        glyphs = []
        for t in toks:
            if isinstance(t, tuple):
                v = fields[t[1]]
                ch = A.DIGITS[v]
                glyphs.append(gid[(sf, ch)])
            else:
                glyphs.append(gid[(sf, 'SP' if t == ' ' else t)])
        hh = fonts[sf].h
        ticker = slot == 'TICKER'
        lo, hi = (ex['TICKER_X0'], ex['TICKER_X1']) if ticker else (0, 640)
        pen = ex['TICKER_X0'] - scroll if ticker else x0
        while True:
            for g in glyphs:
                start, w = gtab[g]
                if pen + w <= lo + 1:          # fewer than two visible columns at the left clip: not drawn
                    pen += w
                    continue
                for c in range(w):
                    x = pen + c
                    if lo <= x < hi:
                        for r in range(hh):
                            a = pix[start + c * hh + r]
                            if a and 0 <= y0 + r < 480:
                                layer[(x, y0 + r)] = (a, colour)
                pen += w
                if pen >= hi:
                    break
            if not ticker or pen >= hi:
                break
            pen += ex['TICKER_GAP']
            if pen >= hi:
                break
    return layer


# ---------------------------------------------------------------- hall
PROMPT_REASON = None


def res_cells(w, h, fw, fh):
    """Field values 54..68 of the resolution line, from the spec: the text "W×H" left-aligned in
    9 cells (blank = 10, '×' = 12; 10/27), then the shown size as 3 + 3 digits."""
    src = [12 if ch == '×' else int(ch) for ch in f'{w}×{h}']
    assert len(src) <= 9 and 100 <= fw <= 999 and 100 <= fh <= 999
    return src + [10] * (9 - len(src)) + [int(ch) for ch in f'{fw:03d}{fh:03d}']


def res_words(cells):
    """the 60-bit cell vector (cell k in bits 4k+3..4k) as two 30-bit integers for the bench"""
    v = sum(c << 4 * k for k, c in enumerate(cells))
    return v & (1 << 30) - 1, v >> 30


class HallState:
    """Frame-rate state machine of the hall screen (spec: hospital_screen.v header)."""

    def __init__(self, adjust_frames=180, flash_frames=300):
        self.adj = adjust_frames
        self.flash_frames = flash_frames
        self.prev = None
        self.settle = 0
        self.adjust = 0
        self.prompt = 0
        self.prompt_id = 0
        self.scroll = 0
        self.period = None
        self.flash = 0
        self.blink = 0
        self.last_call = 0

    def step(self, f):
        """f: dict of the frame inputs (after the frame start). Returns the latched view."""
        b = assets('hall')
        if self.period is None:
            self.period = b['swidth']['TICKER'] + b['extra']['TICKER_GAP']
        keys = ('bri', 'con', 'music', 'voice', 'auto', 'volmode')
        cur = tuple(f[k] for k in keys)
        prev = self.prev if self.prev is not None else (0, 0, 2, 10, 0, 0)
        changed = cur != prev
        if changed and self.settle == 3:
            self.adjust = self.adj
        elif self.adjust:
            self.adjust -= 1
        if self.settle != 3:
            self.settle += 1
        if f['rej']:
            self.prompt = self.adj
            self.prompt_id = reason(f['rej'], f)
        elif self.prompt:
            self.prompt -= 1
        # badge: a new call whose patient registered needs bit 0 ("听力差"), or an accepted replay
        if (f['call'] != self.last_call and f['call'] != 0 and f['needs'] & 1) or f.get('rep'):
            self.flash, self.blink = self.flash_frames, 0
        else:
            if self.flash:
                self.flash -= 1
            self.blink = (self.blink + 1) & 31
        self.last_call = f['call']
        self.prev = cur
        self.scroll = 0 if self.scroll == self.period - 1 else self.scroll + 1
        if f.get('sset', -1) >= 0:
            self.scroll = f['sset']
        # 10/28: prompt > adjust (SW1 up: always) > resolution > ticker
        prompt = self.prompt != 0
        return dict(f, show_prompt=prompt, show_adjust=(f['volmode'] or self.adjust != 0) and not prompt,
                    prompt_id=self.prompt_id, scroll=self.scroll, flash_act=self.flash != 0,
                    flash_on=self.flash != 0 and self.blink < 16)


def reason(rej, f):
    group, bit = (rej - 1) // 8, (rej - 1) % 8
    if group == 3:
        return 6
    if group == 2:
        return 5
    if group == 0:
        if bit == 0:
            return 0
        if bit in (1, 6):
            return 1
        if bit == 2:
            return 2
        if bit == 7:
            return 3
        return 4
    if group == 1 and bit == 5 and f['help'] == 1:
        return 7
    return 4


def pct(p):
    h = 1 if p >= 100 else 10
    r = p - 100 if p >= 100 else p
    t = r // 10 if (p >= 100 or r >= 10) else 10
    return [h, t, p % 10]


def hall_frame(v, photo):
    """v: HallState.step() output; photo: 640*480 RGB ints. Returns the expected frame.
    v['rooms'] = [room1..room4 current patient], v['lroom'] / v['hroom'] = latest call / help room,
    v['present'] = rooms listed."""
    b = assets('hall')
    n = v['call']
    nx = (n + 1) & 31
    fields = [0] * 64
    fields[0:3] = [0, tens(n), ones(n)]
    fields[3:6] = [0, tens(nx), ones(nx)]
    fields[6:8] = [tens(v['waiting']) if v['waiting'] >= 10 else 10, ones(v['waiting'])]
    fields[8:11] = [0, tens(v['issued']), ones(v['issued'])]
    for i, h in enumerate((v['h1'], v['h2'], v['h3'])):
        fields[11 + 3 * i:14 + 3 * i] = [11, 11, 11] if h == 0 else [0, tens(h), ones(h)]
    bri = [100, 75, 50, 25][v['bri']]
    con = [100, 125, 150, 75][v['con']]
    fields[25:28], fields[28:31] = pct(bri), pct(con)
    fields[31:34], fields[34:37] = pct(v['music'] * 10), pct(v['voice'] * 10)
    e = v['err']
    fields[37:39] = [1, e - 10] if e >= 10 else [0, e]
    fields[39] = v['lroom'] + 1
    fields[40] = v['hroom'] + 1
    for r in range(4):
        rn = v['rooms'][r]
        fields[41 + 3 * r:44 + 3 * r] = [0, tens(rn), ones(rn)]
    fields += [10] * 8
    fields[53] = v.get('rpic', 0) + 1
    fields[54:69] = v.get('cells', [10] * 15)
    S = {}
    S['TITLE'] = ('TITLE', INK)
    if v['vstatus'] in (2, 3, 4):
        S['ERR'] = (f'VFAULT{v["vstatus"] - 2}', RED)
    else:
        S['ERR'] = ('ERR' if e else None, RED)
    S['NET'] = ('NET_OK', LABEL) if v['phy'] else ('NET_DOWN', RED)
    S['CLIN'] = ('CLIN_ON', GREEN) if v['online'] else ('CLIN_OFF', RED)
    S['CALL_LABEL'] = ('CALL_LABEL', INK)
    # 10/28 two lines: 请 [006] 号 / 到 [02] 诊室就诊; idle: 等待叫号 on line 1 only
    if n:
        S['C1_PRE'], S['BIGNUM'], S['C1_POST'] = ('C1_PRE', INK), ('BIGNUM', AMBER), ('C1_POST', INK)
        S['C2_PRE'], S['ROOMNUM'], S['C2_POST'] = ('C2_PRE', INK), ('ROOMNUM', AMBER), ('C2_POST', INK)
    else:
        S['C1_PRE'] = ('C_WAIT', INK)
    if v['flash_on']:
        S['FLASH_TAG'] = ('FLASH_TAG', 0xFFFFFF)
    S['LOADING'] = (None if v['ready'] else 'LOADING', INK)
    for k in ('L_NEXT', 'L_WAIT', 'L_ISSUED', 'L_HIST', 'L_ROOMS', 'L_HELP'):
        S[k] = (k, LABEL)
    S['V_NEXT'] = ('V_NEXT' if v['waiting'] else 'V_NEXT_NONE', INK)
    S['V_WAIT'] = ('V_WAIT', INK)
    S['V_ISSUED'] = ('V_ISSUED', INK)
    S['V_HIST'] = ('V_HIST', INK)
    for r in range(4):
        if v['present'] >> r & 1:
            rn = v['rooms'][r]
            col = AMBER if (n and r == v['lroom'] and rn == n) else INK if rn else LABEL
            S[f'ROOM{r}'] = (f'ROOM{r}_ON' if rn else f'ROOM{r}_OFF', col)
    S['V_HELP'] = (f'HELP{min(v["help"], 2)}', RED if v['help'] == 1 else GREEN)
    if v['show_prompt']:
        S['B0'] = (f'PROMPT{v["prompt_id"]}', RED)
    elif v['show_adjust']:
        S['B0'] = ('A_BRI', INK)
        S['B1'], S['B2'], S['B3'] = ('A_CON', INK), ('A_MUS', INK), ('A_VOI', INK)
        S['B4'] = ('A_AUTO' if v['auto'] else 'A_MANUAL', INK)
    elif v.get('res') and v['ready']:
        S['B0'] = ('RES_PIC', TEAL)
        S['RES_LINE'] = ('RES_LINE', INK)
    else:
        S['B0'] = ('TIP', TEAL)
        S['TICKER'] = ('TICKER', TICK)
    layer = draw_text(b, S, fields, v['scroll'])
    # "听力差" call / replay: the pill badge x PILL_X0 .. + width + 28, y PILL_Y0 .. + 29, ends of
    # radius 15, while it is on. 10/28 SW1 up: underline y UL_Y0..+1 under the selected volume
    ex = b['extra']
    px0, py0 = ex['PILL_X0'], ex['PILL_Y0']
    pill_x1 = px0 + b['swidth']['FLASH_TAG'] + 28
    ul = None
    if v['volmode'] and v['show_adjust']:
        voice_t = v.get('tgt', 0)
        ux = ex['UL_VOI_X0'] if voice_t else ex['UL_MUS_X0']
        ul = (ux, ux + b['swidth']['A_VOI' if voice_t else 'A_MUS'])
    inset = [round(15 - (225 - (r - 14.5) ** 2) ** 0.5) for r in range(30)]
    out = []
    for y in range(480):
        for x in range(640):
            c = photo[y * 640 + x]
            if y < 46 or y >= 322:
                c = lift(c)
            if (y == 45 or y == 428) and 18 <= x < 622:
                c = 0xD2D6DC
            if 18 <= x < 46 and 41 <= y < 44:
                c = TEAL
            if v['flash_on'] and py0 <= y < py0 + 30 and px0 + inset[y - py0] <= x < pill_x1 - inset[y - py0]:
                c = AMBER
            if ul and y in (ex['UL_Y0'], ex['UL_Y0'] + 1) and ul[0] <= x < ul[1]:
                c = AMBER
            t = layer.get((x, y))
            out.append(mix(c, t[1], t[0]) if t else c)
    return out


# ---------------------------------------------------------------- clinic
def clinic_frame(v):
    """v: frame-latched clinic state: call issued waiting last lvalid help link alarm op ops panel zcard.
    Returns the expected clinic_screen output (before clinic_card_view)."""
    b = assets('clinic')
    ex = b['extra']
    n, w, iss = v['call'], v['waiting'], v['issued']
    nx = (n + 1) & 31
    fields = [10] * 64
    fields[0:3] = [0, tens(n), ones(n)]
    fields[3:6] = [0, tens(nx), ones(nx)]
    fields[6:8] = [tens(w) if w >= 10 else 10, ones(w)]
    fields[8:11] = [0, tens(iss), ones(iss)]
    link, help_ = v['link'], v['help']
    S = {'TITLE': ('TITLE', INK),
         'LINK': ('LINK_OK', GREEN) if link else ('LINK_DOWN', RED),
         'L_NUM': ('L_NUM' if link else 'L_NUM_DOWN', C_LABEL),
         'BIGNUM': ('BIGNUM' if n else 'BIGNONE', AMBER),
         'L_EXPR': ('L_EXPR', C_LABEL),
         'V_EXPR': (f'EXPR{min(v["last"], 5)}' if v['lvalid'] else 'EXPR_NONE', INK),
         'L_HELP': ('L_HELP', C_LABEL),
         'L_NEXT': ('L_NEXT', C_LABEL), 'L_WAIT': ('L_WAIT', C_LABEL), 'L_ISSUED': ('L_ISSUED', C_LABEL),
         'V_NEXT': ('V_NEXT' if w else 'V_NEXT_NONE', INK), 'V_WAIT': ('V_WAIT', INK), 'V_ISSUED': ('V_ISSUED', INK)}
    if not link:
        S['V_HELP'] = ('HELP_DOWN', RED)
    elif help_ == 1:
        S['V_HELP'] = ('ALERT', RED)
    else:
        S['V_HELP'] = ('HELP0' if help_ == 0 else 'HELP2', GREEN)
    op, ops = v['op'], v['ops']
    known = op != 0 and 1 <= ops <= 5
    if v['panel']:
        S['OP'] = (None, INK)
    else:
        S['OP'] = (f'OP{op - 1}_{ops - 1}' if known else 'OP_NONE',
                   C_LABEL if not known or ops == 1 else GREEN if ops == 2 else RED)
    for i in range(6):
        S[f'CELL{i}'] = (f'CELL{i}', INK)
    for i in range(3):
        S[f'K{i}'] = (f'K{i}', C_LABEL)
        S[f'KW{i}'] = (f'KW{i}', RED if (i == 2 and help_ == 1 and link) else INK)
    zc = min(v['zcard'], 5)
    if v['panel']:
        S['ZOOM'] = (f'EXPR{zc}', 'ZOOM', 320 - b['swidth'][f'EXPR{zc}'] // 2)
    layer = draw_text(b, S, fields)
    PAGE, RULE, CELL, WHITE = 0xFAFAF9, 0xE2E5E9, 0xF1F0EC, 0xFFFFFF
    out = []
    for y in range(480):
        for x in range(640):
            c = PAGE
            if (y == 45 or y == 198) and 18 <= x < 622:
                c = RULE
            if 18 <= x < 46 and 41 <= y < 44:
                c = TEAL
            if (x == 214 or x == 456) and 64 <= y < 186:
                c = RULE
            if help_ == 1 and link and v['alarm'] and 222 <= x < 225 and 152 <= y < 174:
                c = RED
            if x == 444 and 258 <= y < 448:
                c = RULE
            if (y == 320 or y == 384) and 462 <= x < 622:
                c = RULE
            for i in range(6):
                cx0 = ex['GRID_X'] + ex['GRID_DX'] * (i % 3)
                cy0 = ex['GRID_Y'] + ex['GRID_DY'] * (i // 3)
                if cx0 - 2 <= x < cx0 + 122 and cy0 - 2 <= y < cy0 + 92:
                    inner = cx0 <= x < cx0 + 120 and cy0 <= y < cy0 + 90
                    c = CELL if inner else TEAL if (v['lvalid'] and v['last'] == i) else RULE
            panel = v['panel'] and 140 <= x < 500 and 105 <= y < 375
            if panel:
                c = WHITE
            t = layer.get((x, y))
            if t and panel and t[1] != 'ZOOM':
                t = None
            if t:
                f = INK if t[1] == 'ZOOM' else t[1]
                c = mix(c, f, t[0])
            out.append(c)
    return out
