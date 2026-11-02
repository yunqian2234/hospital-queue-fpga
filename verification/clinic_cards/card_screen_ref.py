"""10/23 clinic screen + expression-card reference, written from the layout/animation specification.

render(frames, ready, cards, t, code, font, in_rgb) -> (list of 640x480 pixel lists, list of states)
  frames: (call, issued, waiting, last, last_valid, help, link, alarm, op, op_state, dump)
  ready:  6-bit mask of loaded card pictures
  cards:  for each card (pixel index list, top row first, 120*90) and palette (RGB ints)
Status layout = the 10/18 clinic screen (screen_ref) moved up to make room for the card grid;
cards, zoom geometry, bilinear filter, darkening and the trigger rules follow the specification
in clinic_card_view.v's header (not its code).
"""
from PIL import Image

from screen_ref import Canvas, load_bank, fields, d2, d3, rgb, WHITE, INK, BLUE, GRAY, LINE, PALE, ACCENTS

N, HOLD, ARM = 18, 4, 2
CW, CH = 120, 90
GX, GDX, GY, GDY = 24, 136, 262, 100
XC, YC = 140, 105
BORDER, BORDER_HELP = 0x0e6e6e, 0xd64545          # 10/24 palette
HOLE = 0xf1f0ec                                    # 10/24: cell colour under the zooming card
WORDS = ['请帮助我', '请写下来', '请再说一遍', '是', '不是', '不是这个意思']


def ease(k):
    return round(256 * (1 - (1 - k / N) ** 3))


def geometry(card, k):
    e = ease(k)
    zw, zh = CW + ((240 * e + 128) >> 8), CH + ((180 * e + 128) >> 8)
    xs, ys = GX + GDX * (card % 3), GY + GDY * (card // 3)
    x0 = xs + (((XC - xs) * e + 128) >> 8)
    y0 = ys + (((YC - ys) * e + 128) >> 8)
    return x0, y0, x0 + zw, y0 + zh, CW * 65536 // zw, CH * 65536 // zh, (140 * e + 128) >> 8


def states(frames, hold=HOLD):
    """Per displayed frame: (st, k, card). st 0 idle, 1 grow, 2 hold, 3 shrink."""
    st = k = cnt = 0
    card = pcard = 0
    pend = armed = False
    arm = 0
    prev = (0, 0, 0, 0)       # last, last_valid, help, clicks
    out = []
    for f in frames:
        last, lv, help_, link = f[3], f[4], f[5], f[6]
        clicks = f[11] if len(f) > 11 else 0      # 10/24 status d9: accepted card clicks
        new_card = lv and (not prev[1] or last != prev[0] or clicks != prev[3])
        new_help = help_ == 1 and prev[2] != 1
        trig = armed and link and (new_card or new_help)
        tcard = last if new_card else 0
        other = trig and tcard != card
        # arming (uses the value before this frame's update, like a register)
        if not link:
            armed, arm = False, 0
        elif arm != ARM:
            arm += 1
        else:
            armed = True
        if st == 0:
            if trig:
                st, k, card = 1, 1, tcard
        elif st == 1:
            if other:
                pend, pcard = True, tcard
            if k == N:
                st, cnt = 2, 0
            else:
                k += 1
        elif st == 2:
            if other:
                pend, pcard = True, tcard
            if other or pend or cnt == hold - 1:
                st, k = 3, N - 1
            else:
                cnt += 1
        else:
            if other:
                pend, pcard = True, tcard
            if k == 1:
                if other:
                    st, k, card, pend = 1, 1, tcard, False
                elif pend:
                    st, k, card, pend = 1, 1, pcard, False
                else:
                    st, k = 0, 0
            else:
                k -= 1
        prev = (last, lv, help_, clicks)
        out.append((st, k, card))
    return out


def lerp(a, b, t):
    return (a * 256 + (b - a) * t + 128) >> 8


def lerp_rgb(p, q, t):
    return (lerp(p >> 16, q >> 16, t) << 16) | (lerp(p >> 8 & 255, q >> 8 & 255, t) << 8) | lerp(p & 255, q & 255, t)


def darken(v, d):
    return sum(((v >> s & 255) * (256 - d) >> 8) << s for s in (16, 8, 0))


def screen(c, t, f, zoom_panel, zoom_card):
    call, issued, waiting, last, lv, help_, up, alarm, op, ops = f[:10]
    hp = 15
    c.put(t[0][:5], 16, 8, scale=2)
    c.put(t[17 if up else 18][:4], 512, 24, GRAY)
    c.row(49, 16, 624, LINE)
    c.im.paste(rgb(BLUE), (16, 46, 112, 49))
    c.panel((16, 56, 624, 198), fill=PALE)
    if help_ == 1:
        c.round((16, 56, 624, 198), ACCENTS[hp]); c.round((18, 58, 622, 196), PALE)
    c.im.paste(rgb(LINE), (424, 72, 425, 182))
    c.put(t[3 + help_][:10], 32, 66, BLUE if help_ else GRAY)
    c.put(t[18 if not up else (6 if alarm else 37) if help_ == 1 else 3 + help_][:10], 32, 86, scale=2)
    c.put(t[10][:4], 32, 128, GRAY)
    c.put(t[10 + last if lv else 16][5:11], 32, 150, scale=2)
    c.put(t[38 if up else 39][:4], 448, 66, GRAY)
    c.big(call, 446, 90, 56)
    c.put(fields(t[7], [d3(call + 1)]) if waiting else t[20], 32, 208)
    c.put(fields(t[8], [d2(waiting)]), 240, 208)
    c.put(fields(t[9], [d3(issued)]), 448, 208)
    c.row(229, 16, 624, LINE)
    bad = not op or not ops or ops > 5
    c.put(t[36 if bad else 21 + 5 * (op - 1) + ops - 1][:38], 16, 236,
          GRAY if bad else ACCENTS[15] if ops == 2 else INK)
    for i in range(6):
        x0, y0 = GX + GDX * (i % 3), GY + GDY * (i // 3)
        c.round((x0 - 2, y0 - 2, x0 + 122, y0 + 92), BLUE if lv and last == i else LINE)
        c.im.paste(rgb(PALE), (x0, y0, x0 + 120, y0 + 90))
        c.put(WORDS[i], x0 + 60 - len(WORDS[i]) * 8, y0 + 37)
    for i, (key, word) in enumerate([(t[19][:4], t[19][5:9]), (t[19][11:15], t[19][16:18]),
                                     (t[19][20:24], t[19][25:29])]):
        y = 258 + 67 * i
        c.panel((440, y, 624, y + 62), help_ == 1 and i == 2, fill=PALE)
        c.put(key, 456, y + 8, GRAY)
        c.put(word, 456, y + 26, BLUE if help_ == 1 and i == 2 else INK, 2)
    if zoom_panel:
        c.im.paste(rgb(WHITE), (XC, YC, XC + 360, YC + 270))
        w = WORDS[zoom_card]
        c.put(w, 320 - len(w) * 16, 224, INK, 2)


def render(frames, ready, cards, t, code, font, in_rgb, hold=HOLD, screen_fn=None):
    """screen_fn(frame, zoom_panel, zoom_card) -> clinic_screen pixels (10/24 UI v3); None = 10/18 screen."""
    base = Image.new('RGB', (640, 480))
    base.putdata([rgb(in_rgb(x, y)) for y in range(480) for x in range(640)])
    bank = None if screen_fn else load_bank('clinic')      # 10/18 screen only (old ROM files)
    rgbs = [[pal[i] for i in pix] for pix, pal in cards]       # card pixels as RGB
    out = []
    sts = states(frames, hold)
    for f, (st, k, card) in zip(frames, sts):
        if not f[10]:
            out.append(None)
            continue
        zoom = st != 0
        img_ok = bool(ready >> card & 1)
        if screen_fn:
            px = screen_fn(f, zoom and st == 2 and not img_ok, card)
        else:
            c = Canvas(code, font, bank, base)
            c.phase = 15
            screen(c, t, f, zoom and st == 2 and not img_ok, card)
            px = [(r << 16) | (g << 8) | b for r, g, b in c.im.getdata()]
        screen_px = list(px)          # clinic_screen output alone (the zoom box shows it, not the cards)
        for i in range(6):
            x0, y0 = GX + GDX * (i % 3), GY + GDY * (i // 3)
            if zoom and i == card:
                for y in range(CH):
                    px[(y0 + y) * 640 + x0:(y0 + y) * 640 + x0 + CW] = [HOLE] * CW
            elif ready >> i & 1:
                for y in range(CH):
                    px[(y0 + y) * 640 + x0:(y0 + y) * 640 + x0 + CW] = rgbs[i][y * CW:(y + 1) * CW]
        if zoom:
            x0, y0, x1, y1, sx, sy, dim = geometry(card, k)
            new = [darken(v, dim) for v in px]
            for y in range(y0 - 3, y1 + 3):
                for x in range(x0 - 3, x1 + 3):
                    new[y * 640 + x] = BORDER_HELP if card == 0 else BORDER
            src = rgbs[card]
            for y in range(y0, y1):
                s = (sy >> 1) - 32768 + (y - y0) * sy
                r0, fy = (0, 0) if s < 0 else (s >> 16, (s >> 8) & 255)
                r1 = min(r0 + 1, CH - 1)
                for x in range(x0, x1):
                    if not img_ok:
                        new[y * 640 + x] = screen_px[y * 640 + x] if st == 2 else WHITE
                        continue
                    s = (sx >> 1) - 32768 + (x - x0) * sx
                    j0, fx = (0, 0) if s < 0 else (s >> 16, (s >> 8) & 255)
                    j1 = min(j0 + 1, CW - 1)
                    top = lerp_rgb(src[r0 * CW + j0], src[r0 * CW + j1], fx)
                    bot = lerp_rgb(src[r1 * CW + j0], src[r1 * CW + j1], fx)
                    new[y * 640 + x] = lerp_rgb(top, bot, fy)
            px = new
        out.append(px)
    return out, sts
