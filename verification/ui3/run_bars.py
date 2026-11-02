"""10/28 audio_bar_visualizer regression: RTL (tb_bars.sv) vs a model written from the module's
header spec. The model replays the logged taps and frame starts (a tap on the same clock as a
frame start counts after it, as the register update does) and draws every dumped frame.
Also checks the dumps really contain bars and caps, and that deliberately broken RTL is caught.
Usage: python verification/ui3/run_bars.py
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
# 10/29: the hall now uses the spectrum bars (run_spectrum.py); this checks the kept 10/28 version
RTL = LAB / 'delivery/spectrum_20261029/before/audio_bar_visualizer.v'
OUT = LAB / 'delivery/ui_tweak_20261028/evidence/bars'
IVL = Path('D:/iverilog/iverilog/bin')
BAR, CAP = 0x0E6E6E, 0xF08C00
WINDOW, CAP_FALL = 600, 3
MUTANTS = [('cap never falls', "else if (fall_now) cap_mem[sk] <= c - 1'b1;", ''),
           ('pointer not advanced', "if (!clr && pend) ptr <= ptr + 1'b1;", ''),
           ('no minimum height', "| {5'd0, win_max != 0}", ''),
           ('enable low does not clear', "if (clr) begin lv_mem[sk] <= 6'd0; cap_mem[sk] <= 6'd0; end", "if (0) ;"),
           ('show ignored', "vis <= show && enable;", "vis <= enable;"),
           ('no 61-px limit', "half > 6'd61 ? 6'd61 : half", 'half'),
           ('newest written to the wrong slot', "lv_mem[ptr] <= pend_val;", "lv_mem[ptr + 4'd1] <= pend_val;")]


def simulate(lines):
    """Replays the log in clock order (header spec of audio_bar_visualizer.v). Returns
    {frame number: (visible, bars oldest..newest, caps)}. On one clock an enable change acts
    first, then a tap, then a frame start (a tap on the frame-start clock counts for that frame)."""
    level, cap, win_peak, win_n, fall_n = [0] * 16, [0] * 16, 0, 0, 0
    pend, pend_val, enable = False, 0, True
    out, n = {}, -1
    events = []
    for ln in lines:
        t = ln.split()
        if t and t[0] in ('P', 'F', 'E'):
            events.append((int(t[1]), {'E': 0, 'P': 1, 'F': 2}[t[0]], t))
    events.sort(key=lambda e: (e[0], e[1]))
    for _, _, t in events:
        if t[0] == 'F':
            show, en = t[2] == '1', t[3] == '1'
            fall_now = fall_n == 0
            fall_n = 0 if fall_n == CAP_FALL - 1 else fall_n + 1
            if not en:
                level, cap, pend = [0] * 16, [0] * 16, False
            else:
                if pend:
                    level = level[1:] + [pend_val]
                    pend = False
                for k in range(16):
                    if level[k] >= cap[k]:
                        cap[k] = level[k]
                    elif fall_now:
                        cap[k] -= 1
            n += 1
            out[n] = (show and en, list(level), list(cap))
        elif t[0] == 'E':
            enable = t[2] == '1'
            if not enable:
                win_peak, win_n, pend = 0, 0, False
        else:
            if not enable:
                continue
            s_ = int(t[2])
            m = -s_ if s_ < 0 else s_
            mag7 = 127 if m >= 32768 else (m >> 8) & 127
            if win_n == WINDOW - 1:
                wm = max(win_peak, mag7)
                pend, pend_val = True, min(61, (wm >> 1) | (1 if wm else 0))   # spec: 1..61 px
                win_peak, win_n = 0, 0
            else:
                win_peak = max(win_peak, mag7)
                win_n += 1
    return out


def draw(state, x, y, rgb_in):
    vis, shown, cap = state
    if not vis:
        return rgb_in
    bi, rx, up = (x - 320) // 16, (x - 320) % 16, 63 - (y - 252)
    if rx >= 12:
        return rgb_in
    h, c = shown[bi], cap[bi]
    if c and up in (c + 1, c + 2):
        return CAP
    if up < h:
        return BAR
    return rgb_in


def run(rtl_text, d, frames=60, seed=3):
    d.mkdir(parents=True, exist_ok=True)
    (d / 'audio_bar_visualizer.v').write_text(rtl_text, encoding='utf-8')
    subprocess.run([str(IVL / 'iverilog'), '-g2012', '-o', str(d / 'tb.vvp'), f'-Ptb_bars.FRAMES={frames}',
                    f'-Ptb_bars.SEED={seed}', str(HERE / 'tb_bars.sv'), str(d / 'audio_bar_visualizer.v')], check=True)
    p = subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=d, capture_output=True, text=True)
    if 'PASS BARS_DUMP' not in p.stdout:
        return None, p.stdout[-400:]
    lines = (d / 'bars.log').read_text().split('\n')
    states = simulate(lines)
    errors, stats, i, frame = 0, [0, 0], 0, None
    first = None
    for ln in lines:
        if ln.startswith('D '):
            frame, i = int(ln.split()[1]), 0
            continue
        if frame is None or not re.fullmatch(r'[0-9a-f]{6}', ln):
            continue
        x, y = 320 + i % 256, 252 + i // 256
        rgb_in = (x & 255) << 16 | (y & 255) << 8 | 0x5a
        want = draw(states[frame], x, y, rgb_in)
        got = int(ln, 16)
        if got != want:
            errors += 1
            first = first or f'frame {frame} x={x} y={y} got {got:06x} want {want:06x}'
        stats[0] += got == BAR
        stats[1] += got == CAP
        i += 1
    return (errors, stats, len(states)), first


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    src = RTL.read_text(encoding='utf-8')
    ok = True
    total_caps = 0
    for seed in (3, 11):
        res, info = run(src, OUT / f'seed{seed}', seed=seed)
        if res is None:
            print('bench failed', info)
            return 1
        errors, (bars, caps), nf = res
        print(f'seed {seed}: {nf} frames, bar pixels {bars}, cap pixels {caps}, mismatches {errors}'
              + (f' (first: {info})' if info else ''))
        ok &= errors == 0 and bars > 1000
        total_caps += caps
    print('cap pixels in all dumps:', total_caps)
    ok &= total_caps > 200
    caught = 0
    for name, old, new in MUTANTS:
        assert src.count(old) == 1, name
        res, _ = run(src.replace(old, new), OUT / ('mut_' + re.sub(r'\W+', '_', name)))
        hit = res is None or res[0] > 0
        caught += hit
        print(f'  mutant {name}: {"caught" if hit else "MISSED"}')
    ok &= caught == len(MUTANTS)
    print(f'mutants caught {caught}/{len(MUTANTS)}')
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
