"""10/29 spectrum bars regression: RTL (tb_spectrum.sv + audio_bar_visualizer.v) vs the bit-exact
model verification/ui3/spectrum_model.py, every pixel of the dumped frames; checks no tap is lost,
the RTL band tables equal the model's, the dumps really contain bars and caps, and that
deliberately broken RTL is caught.
Usage: python verification/ui3/run_spectrum.py [--rtl FILE]
"""
import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(HERE))
import spectrum_model as sm  # noqa: E402

RTL = LAB / 'src/user_source/hdl_source/display/audio_bar_visualizer.v'
DISPLAY = LAB / 'src/user_source/hdl_source/display'
OUT = LAB / 'delivery/spectrum_20261029/evidence/bench'
ROM_DIR = DISPLAY
IVL = Path('D:/iverilog/iverilog/bin')
BAR, CAP = 0x0E6E6E, 0xF08C00
MUTANTS = [
    ('cap never falls', "else if (fall_now) cap_mem[sk] <= c - 1'b1;", ''),
    ('bar never sinks', "wire [5:0] sunk = h > BAR_FALL ? h - BAR_FALL : 6'd0;", "wire [5:0] sunk = h;"),
    ('no Hann window', "x * $signed({1'b0, rom_q[7:0]})", "x * $signed(9'd255)"),
    ('im uses the cos coefficient', "rom_a <= {2'b01, k}; st <= E_CALC;", "rom_a <= {2'b00, k}; st <= E_CALC;"),
    ('no G term (max only)', "wire [8:0] lsum = lmax + g;", "wire [8:0] lsum = lmax;"),
    ('block end not zeroed', "ram_d <= last ? {W{1'b0}} : dv + p16;", "ram_d <= dv + p16;"),
    ('taps kept while enable low', "if (!enable) tap_pend <= 1'b0;", "if (0) tap_pend <= 1'b0;"),
    ('enable low does not clear', "wire [5:0] nl = clr ? 6'd0 : pv > sunk ? pv : sunk;",
     "wire [5:0] nl = pv > sunk ? pv : sunk;"),
    ('show ignored', "vis <= show && enable;", "vis <= enable;"),
    ('no 61-px limit', "vh > 10'd61 ? 6'd61 : vh[5:0]", "vh[5:0]"),
    ('pending overwritten, not max', "st == E_CMB && val > pv", "st == E_CMB"),
    ('wrong band offset', "wire [9:0] vh = v15 > t_off ? v15 - t_off : 10'd0;",
     "wire [9:0] vh = v15 > t_off + 9'd2 ? v15 - t_off - 9'd2 : 10'd0;"),
    ('no block stagger', "wire [10:0] sft = cnt + {6'd0, k, 1'b0};", "wire [10:0] sft = cnt;"),
    # (shifting in 0 instead of the sign is not visible: those bits reach the fraction only for |value| < 8,
    #  which is 0 px in every band - so that change is not a useful mutant)
    ('log exponent off by one', "la <= lz; t <= p16; e <= W - 2; pass <= 1'b1;", "la <= lz; t <= p16; e <= W - 3; pass <= 1'b1;"),
    ('fraction not sign-corrected', "t[W-3:W-5] ^ {3{t[W-1]}}", "t[W-3:W-5]"),]


def simulate(lines):
    """replay the log (header of spectrum_model.py / audio_bar_visualizer.v); on one clock an enable
    change acts first, then an engine start, then a frame start"""
    eng = sm.Engine()
    pend, lv, cap, fall_n = [0] * 16, [0] * 16, [0] * 16, 0
    out, n, events = {}, -1, []
    for ln in lines:
        t = ln.split()
        if t and t[0] in ('P', 'F', 'E'):
            events.append((int(t[1]), {'E': 0, 'P': 1, 'F': 2}[t[0]], t))
    events.sort(key=lambda e: (e[0], e[1]))
    for _, _, t in events:
        if t[0] == 'E':
            if t[2] == '0':
                eng.reset()
        elif t[0] == 'P':
            for k, v in eng.sample(int(t[2])).items():
                pend[k] = max(pend[k], v)
        else:
            show, en = t[2] == '1', t[3] == '1'
            fall_now = fall_n == 0
            fall_n = 0 if fall_n == sm.CAP_FALL - 1 else fall_n + 1
            for k in range(16):
                sunk = lv[k] - sm.BAR_FALL if lv[k] > sm.BAR_FALL else 0
                nl = max(pend[k], sunk) if en else 0
                lv[k], pend[k] = nl, 0
                if not en:
                    cap[k] = 0
                elif nl >= cap[k]:
                    cap[k] = nl
                elif fall_now:
                    cap[k] -= 1
            n += 1
            out[n] = (show and en, list(lv), list(cap))
    return out


def draw(state, x, y, rgb_in):
    vis, bars, cap = state
    if not vis:
        return rgb_in
    bi, rx, up = (x - 320) // 16, (x - 320) % 16, 63 - (y - 252)
    if rx >= 12:
        return rgb_in
    h, c = bars[bi], cap[bi]
    if c and up in (c + 1, c + 2):
        return CAP
    if up < h:
        return BAR
    return rgb_in


def run(rtl_text, d, frames=60, seed=3):
    d.mkdir(parents=True, exist_ok=True)
    (d / 'audio_bar_visualizer.v').write_text(rtl_text, encoding='utf-8')
    shutil.copy2(ROM_DIR / 'spectrum_rom.hex', d / 'spectrum_rom.hex')
    c = subprocess.run([str(IVL / 'iverilog'), '-g2012', '-DSPECTRUM_BEHAVIORAL_RAM', '-DUI_BEHAVIORAL_ROM', '-o', str(d / 'tb.vvp'),
                        f'-Ptb_spectrum.FRAMES={frames}', f'-Ptb_spectrum.SEED={seed}',
                        str(HERE / 'tb_spectrum.sv'), str(d / 'audio_bar_visualizer.v'), str(DISPLAY / 'ui_table_rom.v')],
                       capture_output=True, text=True)
    if c.returncode:
        return None, 'compile: ' + (c.stdout + c.stderr)[-400:]
    p = subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=d, capture_output=True, text=True)
    if 'PASS SPECTRUM_DUMP' not in p.stdout:
        return None, p.stdout[-400:]
    lines = (d / 'spectrum.log').read_text().split('\n')
    states = simulate(lines)
    errors, stats, i, frame, first = 0, [0, 0], 0, None, None
    lost = sum(1 for ln in lines if ln.startswith('L '))
    taps = sum(1 for ln in lines if ln.startswith('T '))
    starts = sum(1 for ln in lines if ln.startswith('P '))
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
    return dict(errors=errors, bars=stats[0], caps=stats[1], frames=len(states), lost=lost, taps=taps,
                starts=starts), first


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--rtl', type=Path, default=RTL)
    ap.add_argument('--no-mutants', action='store_true')
    ap.add_argument('--rom-dir', type=Path, default=DISPLAY)
    args = ap.parse_args()
    global ROM_DIR
    ROM_DIR = args.rom_dir
    shutil.rmtree(OUT, ignore_errors=True)
    src = args.rtl.read_text(encoding='utf-8')
    ok = True
    chk = subprocess.run([sys.executable, str(LAB / 'delivery/spectrum_20261029/tools/gen_tables.py'),
                          str(args.rtl), '--rom-dir', str(ROM_DIR), '--check'], capture_output=True, text=True)
    print(chk.stdout.strip())
    ok &= chk.returncode == 0
    total_caps = 0
    for seed in (3, 11):
        res, info = run(src, OUT / f'seed{seed}', seed=seed)
        if res is None:
            print('bench failed', info)
            return 1
        print(f"seed {seed}: {res['frames']} frames, taps {res['taps']} engine starts {res['starts']} "
              f"lost {res['lost']}, bar pixels {res['bars']}, cap pixels {res['caps']}, mismatches {res['errors']}"
              + (f' (first: {info})' if info else ''))
        ok &= res['errors'] == 0 and res['bars'] > 1000 and res['lost'] == 0 and 0 <= res['taps'] - res['starts'] <= 1
        total_caps += res['caps']
    print('cap pixels in all dumps:', total_caps)
    ok &= total_caps > 200
    if not args.no_mutants:
        caught = 0
        for name, old, new in MUTANTS:
            assert src.count(old) == 1, name
            res, _ = run(src.replace(old, new), OUT / ('mut_' + re.sub(r'\W+', '_', name)), seed=11)
            hit = res is None or res['errors'] > 0 or res['lost'] > 0 or not 0 <= res['taps'] - res['starts'] <= 1
            caught += hit
            print(f'  mutant {name}: {"caught" if hit else "MISSED"}')
        ok &= caught == len(MUTANTS)
        print(f'mutants caught {caught}/{len(MUTANTS)}')
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
