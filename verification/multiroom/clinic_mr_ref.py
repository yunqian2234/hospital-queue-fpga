"""10/25 reference for the multi-room ENT clinic screen (clinic_screen.v), written from its header spec.

Content (glyphs, strings, item positions) comes from ui3_assets.build() like the RTL ROMs;
the string / colour choice per slot, the digit fields, the page (rules, divider, alert bar) and
the blending are re-implemented here. Only frames without a zoom are modelled (the zoom layer is
clinic_card_view, checked by the card benches); a zoom frame is skipped by the runner.
"""
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'ui3'))
import ui3_assets as A  # noqa: E402
from ui3_ref import draw_text, mix, tens, ones  # noqa: E402

INK, LABEL, TEAL, AMBER, GREEN, RED = 0x1F2933, 0x6B7280, 0x0E6E6E, 0xF08C00, 0x2E9E5B, 0xD64545
PAGE, RULE = 0xFAFAF9, 0xE2E5E9
TAKEN = 300
_b = None


def assets():
    global _b
    if _b is None:
        _b = A.build(A.board_clinic())
    return _b


class ClinicState:
    """Frame latch of clinic_screen: the "X 诊室已确认求助" timer (help 1 -> 2)."""

    def __init__(self):
        self.help_q = 0
        self.taken = 0

    def step(self, f):
        if self.help_q == 1 and f['help'] == 2:
            self.taken = TAKEN
        elif self.taken:
            self.taken -= 1
        self.help_q = f['help']
        return dict(f, taken=self.taken)


def lvl_digits(rec):
    lv = rec & 15
    return [1, 0] if lv >= 10 else [10, lv]


def frame(v):
    """v: one bench frame (run_clinic_ui.F keys) after ClinicState.step. Returns 640*480 pixels."""
    b = assets()
    dual = v['dual']
    bbig = v['bn'] if dual else (v['call'] + 1) & 31
    f = [10] * 64
    f[0:3] = [0, tens(v['an']), ones(v['an'])]
    f[3:6] = [0, tens(bbig), ones(bbig)]
    f[6:8] = lvl_digits(v['arec'])
    f[8:10] = lvl_digits(v['brec'])
    w = v['waiting']
    f[10:12] = [tens(w) if w >= 10 else 10, ones(w)]
    f[12:15] = [0, tens(v['issued']), ones(v['issued'])]
    f[18] = v['hroom'] + 1
    f[19] = v['aroom'] + 1
    f[20] = 2                                  # room B is room 2
    link, help_, taken = v['link'], v['help'], v['taken']
    S = {'TITLE': ('TITLE', INK),
         'LINK': ('LINK_OK', GREEN) if link else ('LINK_DOWN', RED),
         'A_ROOM': ('A_ROOM', TEAL), 'B_ROOM': ('B_ROOM' if dual else 'B_QROOM', TEAL),
         'A_KEY0': ('A_KEY0', LABEL), 'A_KEY1': ('A_KEY1', LABEL)}
    if dual:
        S['QUEUE'] = ('QUEUE', LABEL)
        S['B_KEY0'], S['B_KEY1'] = ('B_KEY0', LABEL), ('B_KEY1', LABEL)
    ops = ['OP0', 'OP1', 'OP2']
    for c in 'AB':
        queue = c == 'B' and not dual
        n = v['bn'] if c == 'B' else v['an']
        rec = v['brec'] if c == 'B' else v['arec']
        rok = v['brok'] if c == 'B' else v['arok']
        op, opst = (v['bop'], v['bops']) if c == 'B' else (v['aop'], v['aops'])
        show = n != 0 and rok
        S[f'{c}_LCUR'] = ('L_NEXTQ' if queue else 'L_CUR', LABEL)
        if queue:
            S[f'{c}_BIG'] = ('B_BIG' if w else 'BIGNONE', AMBER)
        else:
            S[f'{c}_BIG'] = (f'{c}_BIG' if n else 'BIGNONE', AMBER)
        S[f'{c}_LNEED'] = ('L_WAITQ' if queue else 'L_NEED', LABEL)
        if queue:
            S[f'{c}_NEED0'] = ('V_WAITQ', INK)
        elif show:
            needs = rec >> 8
            if rec == 0x0FF:
                S[f'{c}_NEED0'] = ('NEED_UNREG', LABEL)
            elif needs == 0:
                S[f'{c}_NEED0'] = ('NEED_NONE', LABEL)
            else:                                  # packed in bit order
                for slot, k in enumerate(i for i in range(4) if needs >> i & 1):
                    S[f'{c}_NEED{slot}'] = (f'NEED{k}', RED)
        S[f'{c}_LSYM'] = ('L_ISSUEDQ' if queue else 'L_SYM', LABEL)
        if not queue:
            S[f'{c}_LLVL'] = ('L_LVL', LABEL)
        if queue:
            S[f'{c}_SYM'] = ('V_ISSUEDQ', INK)
        elif show:
            sym = rec >> 4 & 15
            S[f'{c}_SYM'] = (f'SYM{sym}' if sym <= 9 else 'SYM_NONE', INK if sym <= 9 else LABEL)
            lv = rec & 15
            S[f'{c}_LVL'] = ('LVL_NONE', LABEL) if lv > 10 else (f'{c}_LVL', RED if lv >= 7 else INK)
        if not queue and op and 1 <= opst <= 5:
            S[f'{c}_OP'] = (f'{ops[op - 1]}_{opst - 1}', LABEL if opst == 1 else GREEN if opst == 2 else RED)
        if not queue and link:
            if help_ == 1:
                S[f'{c}_HELP'] = ('ALERT', RED)
            elif taken:
                S[f'{c}_HELP'] = ('HELP_TAKEN', GREEN)
    layer = draw_text(b, S, f)
    out = []
    for y in range(480):
        for x in range(640):
            cx = x - 320 if x >= 320 else x
            c = PAGE
            if y == 45 and 18 <= x < 622:
                c = RULE
            if 18 <= x < 46 and 41 <= y < 44:
                c = TEAL
            if x == 320 and 56 <= y < 464:
                c = RULE
            if y in (188, 334, 406) and 18 <= cx < 302:
                c = RULE
            if link and help_ == 1 and v['alarm'] and (dual or x < 320) and 8 <= cx < 11 and 372 <= y < 398:
                c = RED
            t = layer.get((x, y))
            out.append(mix(c, t[1], t[0]) if t else c)
    return out
