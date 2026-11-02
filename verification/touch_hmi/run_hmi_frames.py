"""10/25 check of docs/TOUCH_HMI_TUTORIAL_20261025.md against the FPGA.

Reads the tutorial's HMI code (```tjc page.control``` blocks and the s0..s9 / L0..L10 tables),
executes it the way the TJC screen does (one statement per line, printh = raw bytes,
prints x,1 = one byte, page = switch page + run its pre-init, controls reset when a page
loads, sys0 global), drives patient scenarios, and sends the resulting byte stream at 9600 baud
through the real uart_rx + tjc_touch_rx + hospital_registration (tb_hmi_frames.sv).

Expected records come from the patient's intent (what was selected on screen), not from the
bytes, so a wrong checksum, bit order or lost reset in the tutorial code shows up as FAIL.
Usage: python verification/touch_hmi/run_hmi_frames.py
"""
from pathlib import Path
import re
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
DOC = LAB / 'docs/TOUCH_HMI_TUTORIAL_20261025.md'
HDL = LAB / 'src/user_source/hdl_source'
OUT = LAB / 'delivery/multiroom_20261025/evidence/touch_hmi'
IVL = Path('D:/iverilog/iverilog/bin')
SYMS = ['听力下降', '耳鸣', '耳痛或流脓', '鼻塞流涕', '鼻出血', '咽痛', '声音嘶哑', '吞咽困难或异物感', '头晕', '其他']
NONE = 0x0FF
# control defaults when a page loads (private scope), as in the tutorial's control tables
DEFAULTS = {'page0': {}, 'page1': {f'bt{i}': {'val': 0} for i in range(4)} | {'va0': {'val': 0}},
            'page2': {'t_sym': {'txt': '未选'}, 't_lvl': {'txt': '未选'}}}


def parse_doc():
    text = DOC.read_text(encoding='utf-8')
    ev = {}
    for page, ctl, code in re.findall(r'```tjc (\w+)\.(\w+)\n(.*?)```', text, re.S):
        ev[(page, ctl)] = [ln.strip() for ln in code.splitlines() if ln.strip()]
    for row in text.splitlines():
        m = re.match(r'\| (s\d|L\d+) \|', row)
        if m:
            code = re.findall(r'`([^`]+)`', row)
            assert len(code) == 2, row
            ev[('page2', m.group(1))] = code
    for p, c in [('page2', 't_sym'), ('page2', 't_lvl')]:
        assert re.search(rf'\| 文本 \| {c} \|.*\| 未选 \|', text), c
    return ev


class Screen:
    def __init__(self, ev):
        self.ev, self.sys0, self.out = ev, 0, []
        self.load('page0')

    def load(self, page):
        self.page = page
        self.ctl = {k: dict(v) for k, v in DEFAULTS[page].items()}
        self.run(self.ev.get((page, 'preinit'), []))

    def operand(self, t):
        if t.isdigit():
            return int(t)
        if t == 'sys0':
            return self.sys0
        name, attr = t.split('.')
        return self.ctl[name][attr]

    def run(self, code):
        for n, ln in enumerate(code):
            if ln.startswith('printh '):
                self.out += [int(h, 16) for h in ln.split()[1:]]
            elif ln.startswith('prints '):
                var, length = ln[7:].split(',')
                assert length == '1', ln
                self.out.append(self.operand(var) & 0xFF)
            elif ln.startswith('page '):
                assert n == len(code) - 1, 'page must be the last statement: ' + ln
                self.load(ln[5:])
                return
            else:
                lhs, rhs = ln.split('=', 1)
                if rhs.startswith('"'):
                    assert rhs.endswith('"'), ln
                    name, attr = lhs.split('.')
                    assert attr == 'txt' and name in self.ctl, ln
                    self.ctl[name]['txt'] = rhs[1:-1]
                    continue
                m = re.fullmatch(r'(\w+(?:\.\w+)?)(?:([-+*/%])(\w+(?:\.\w+)?))?', rhs)
                assert m, 'one operator per line: ' + ln
                v = self.operand(m.group(1))
                if m.group(2):
                    w = self.operand(m.group(3))
                    op = m.group(2)
                    v = v + w if op == '+' else v - w if op == '-' else v * w if op == '*' else \
                        v // w if op == '/' else v % w
                if lhs == 'sys0':
                    self.sys0 = v
                else:
                    name, attr = lhs.split('.')
                    assert name in self.ctl and attr == 'val', ln
                    self.ctl[name]['val'] = v

    def tap(self, c):
        code = self.ev.get((self.page, c))
        assert code is not None, f'no code for {self.page}.{c}'
        self.run(code)
        self.out.append(0x100)                      # 2 ms before the next touch


class Patient:
    """Drives the screen and keeps the patient's intent (what the screen shows as selected)."""

    def __init__(self, scr):
        self.s, self.needs, self.sym, self.lvl, self.expect = scr, 0, None, None, []

    def check_page(self):
        s = self.s
        if s.page == 'page1':
            got = sum(s.ctl[f'bt{i}']['val'] << i for i in range(4))
            assert got == self.needs, f'page1 shows needs {got}, patient selected {self.needs}'
        if s.page == 'page2':
            want = SYMS[self.sym] if self.sym is not None else '未选'
            assert s.ctl['t_sym']['txt'] == want, (s.ctl['t_sym']['txt'], want)
            want = f'{self.lvl} 级' if self.lvl is not None else '未选'
            assert s.ctl['t_lvl']['txt'] == want, (s.ctl['t_lvl']['txt'], want)

    def tap(self, c):
        before = self.s.page
        if c in ('b_start', 'b_redo'):
            self.needs = 0
        if c == 'b_skip':
            self.expect.append(NONE)
        if c == 'b_submit':
            self.expect.append(self.needs << 8 | (self.sym if self.sym is not None else 15) << 4 |
                               (self.lvl if self.lvl is not None else 15))
        if c[0] == 's' and c[1:].isdigit():
            self.sym = int(c[1:])
        if c[0] == 'L' and c[1:].isdigit():
            self.lvl = int(c[1:])
        self.s.tap(c)
        if self.s.page == 'page2' and before != 'page2':
            self.sym = self.lvl = None
        self.check_page()

    def toggle(self, i):
        assert self.s.page == 'page1'
        self.s.ctl[f'bt{i}']['val'] ^= 1
        self.needs ^= 1 << i
        self.check_page()

    def register(self, needs, sym=None, lvl=None):
        self.tap('b_start')
        for i in range(4):
            if needs >> i & 1:
                self.toggle(i)
        self.tap('b_next')
        if sym is not None:
            self.tap(f's{sym}')
        if lvl is not None:
            self.tap(f'L{lvl}')
        self.tap('b_submit')


def scenarios(p):
    p.register(0b1001, 1, 6)                         # 听力差 + 需翻译, 耳鸣, 6
    p.tap('b_start'); p.tap('b_skip')                # 直接报到
    p.tap('b_start'); p.toggle(1); p.tap('b_next'); p.tap('s4')
    p.tap('b_prev'); p.toggle(0); p.tap('b_next'); p.tap('L10'); p.tap('b_submit')   # back: symptom dropped
    p.tap('b_start'); p.tap('b_next'); p.tap('L5'); p.tap('b_prev'); p.toggle(2)
    p.tap('b_next'); p.tap('s3'); p.tap('b_submit')                                   # back: level dropped
    p.tap('b_start'); p.toggle(0); p.tap('b_next'); p.tap('s2'); p.tap('L3')
    p.tap('b_redo'); p.tap('b_next'); p.tap('b_submit')                               # 重新填写 -> nothing
    p.tap('b_start'); p.toggle(2); p.tap('b_back'); p.tap('b_help'); p.tap('b_replay')
    p.tap('b_start'); p.tap('b_next'); p.tap('b_submit')                              # restart clears 头晕
    p.tap('b_start'); p.toggle(3); p.tap('b_next'); p.tap('s5'); p.tap('b_prev'); p.tap('b_skip')  # skip after step 2
    for n in range(16):                              # every needs value, symptom, level
        p.register(n, n % 10, n % 11)
    p.tap('b_start'); [p.toggle(i) for i in range(4)]; p.tap('b_help'); p.tap('b_next')
    p.tap('s9'); p.tap('s0'); p.tap('L10'); p.tap('L0'); p.tap('b_help'); p.tap('b_submit')  # reselect
    p.register(0, 9, None)
    p.register(0, None, 10)
    p.tap('b_replay')


def frames(stream):
    out, cur = [], []
    for b in stream:
        if b == 0x100:
            assert not cur, 'touch ended inside a frame'
            continue
        cur.append(b)
        if cur[-3:] == [0xFF] * 3:
            assert len(cur) == 7 and cur[0] == 0x5A and cur[3] == 0x5A ^ cur[1] ^ cur[2], cur
            out.append((cur[1], cur[2]))
            cur = []
    assert not cur
    return out


def main():
    ev = parse_doc()
    scr = Screen(ev)
    p = Patient(scr)
    scenarios(p)
    want_f = frames(scr.out)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'stim.mem').write_text(''.join(f'{b:03x}\n' for b in scr.out + [0x1FF]), encoding='ascii')
    srcs = [HERE / 'tb_hmi_frames.sv', HDL / 'uart/uart_rx.v', HDL / 'uart/tjc_touch_rx.v',
            HDL / 'app/hospital_registration.v']
    subprocess.run([str(IVL / 'iverilog'), '-g2012', '-o', str(OUT / 'tb.vvp')] + [str(s) for s in srcs], check=True)
    subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=OUT, check=True, stdout=subprocess.DEVNULL)
    got_f, got_t, stat = [], [], None
    for ln in (OUT / 'hmi_frames.log').read_text().split('\n'):
        f = ln.split()
        if not f:
            continue
        if f[0] == 'F':
            got_f.append((int(f[1]), int(f[2])))
        elif f[0] == 'T':
            got_t.append(tuple(int(x, 16) for x in f[1:]))
        elif f[0] == 'S':
            stat = list(map(int, f[1:]))
    errs = []
    if got_f != want_f:
        errs.append(f'frames: sent {len(want_f)}, decoded {len(got_f)}')
    if stat != [len(want_f), 0, 0, 0]:
        errs.append(f'rx counters good/bad/other/line = {stat}')
    if len(got_t) != len(p.expect):
        errs.append(f'{len(p.expect)} check-ins, FPGA saw {len(got_t)}')
    for k, (exp, got) in enumerate(zip(p.expect, got_t)):
        if got != (exp, exp, NONE):
            errs.append(f'check-in {k + 1}: expected {exp:03x}, pending/room/after = '
                        + ' '.join(f'{g:03x}' for g in got))
    n_bytes = sum(1 for b in scr.out if b < 0x100)
    print(f'{len(ev)} event blocks from the tutorial, {n_bytes} bytes, {len(want_f)} frames, '
          f'{len(p.expect)} check-ins')
    for e in errs:
        print('FAIL', e)
    print('FAIL' if errs else 'PASS')
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main())
