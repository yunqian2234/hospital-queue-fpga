"""10/23 clinic expression-card display regression: RTL full frames vs card_screen_ref.py.

Two scenarios (one video frame per line, HOLD_FRAMES=4 in the bench; the board uses 298 = 5 s):
  A image_zoom   - card 2 (请写下来) zooms with its picture: every grow and shrink frame plus the
                   hold are compared; card 5 has no picture (text in its cell)
  B rules        - a card valid at power-up does not zoom; a card without a picture (white box,
                   then the centred text panel); a help request during the hold ends it and zooms
                   card 1 (请帮助我, red border) after the shrink; link loss during a zoom
Every compared frame must match pixel for pixel; the per-frame animation state from the RTL
(states.txt) must equal the reference state machine for every frame.
Usage: python run_screen_tests.py [--only A|B] [--rtl-dir DIR]
"""
import argparse
import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(HERE))
import clinic_screen_assets as assets  # noqa: E402
import card_screen_ref as ref  # noqa: E402

IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
HDL = LAB / 'src/user_source/hdl_source'
CLINIC = HDL / 'clinic'
TIMING = HDL / 'SD/video_timing_ctrl.v'
BENCH = HERE / 'tb_card_screen.sv'
CARDS = LAB / 'delivery/clinic_cards_20261023/tf_card_clinic'
EVID = LAB / 'delivery/clinic_cards_20261023/evidence'


def load_cards():
    cards = []
    for n in range(1, 7):
        im = Image.open(CARDS / f'CARD{n}.BMP')
        pal = im.getpalette()[:768]
        pal += [0] * (768 - len(pal))
        cards.append((list(im.tobytes()), [(pal[i * 3] << 16) | (pal[i * 3 + 1] << 8) | pal[i * 3 + 2]
                                           for i in range(256)]))
    return cards


def in_rgb(x, y):
    return ((x & 255) ^ 0x5a) << 16 | (y & 255) << 8 | (((x >> 2) & 255) + ((y >> 1) & 255)) & 255


def F(last, lv, help_=0, link=1, dump=0, call=5, issued=9, waiting=4, alarm=0, op=0, ops=0):
    return (call, issued, waiting, last, lv, help_, link, alarm, op, ops, int(dump))


def scenario_a():
    fr = [F(0, 0) for _ in range(3)]
    fr[0] = F(0, 0, dump=1)                                # power-up grid: five pictures, card 5 as text
    grow = [F(1, 1, dump=1) for _ in range(18)]            # card 2 (index 1) clicked: k = 1..18
    hold = [F(1, 1, dump=(i in (0, 3))) for i in range(4)]
    shrink = [F(1, 1, dump=1) for _ in range(17)]          # k = 17..1
    after = [F(1, 1, dump=1), F(1, 1, dump=0)]             # idle again, card 2 framed blue
    return fr + grow + hold + shrink + after


def scenario_b():
    fr = [F(3, 1, dump=(i == 3)) for i in range(4)]        # card 4 valid before arming: no zoom
    fr += [F(4, 1, dump=(k in (1, 9, 18))) for k in range(1, 19)]   # card 5 (no picture): white box
    fr += [F(4, 1, dump=1), F(4, 1, dump=0)]               # hold: centred text panel
    fr += [F(0, 1, help_=1, dump=1)]                       # help request: hold ends, shrink starts
    fr += [F(0, 1, help_=1, dump=(k in (8, 1))) for k in range(16, 0, -1)]
    fr += [F(0, 1, help_=1, dump=(k in (1, 10, 18))) for k in range(1, 19)]   # card 1 zooms, red border
    fr += [F(0, 1, help_=1, link=0, dump=1), F(0, 1, help_=1, link=1)]          # link loss in the hold
    fr += [F(2, 1, help_=1, dump=0) for _ in range(2)]     # another card during the hold
    fr += [F(2, 1, help_=1, dump=(i == 16)) for i in range(17)]
    return fr


SCENARIOS = {'A': ('image_zoom', scenario_a, 0b101111), 'B': ('rules', scenario_b, 0b101111)}


def write_png(path, pixels):
    im = Image.new('RGB', (640, 480))
    im.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in pixels])
    im.save(path)


def run(key, rtl_dir, out_root):
    name, make, ready = SCENARIOS[key]
    out = out_root / name
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    frames = make()
    if os.environ.get('QUICK'):
        frames = frames[:int(os.environ['QUICK'])]
    cards = load_cards()
    pix = [0] * 65536
    pal = [0] * 2048
    for c, (p, q) in enumerate(cards):
        pix[c * 10800:(c + 1) * 10800] = p
        pal[c * 256:(c + 1) * 256] = q
    (out / 'pix.mem').write_text(''.join(f'{v:02x}\n' for v in pix))
    (out / 'pal.mem').write_text(''.join(f'{v:06x}\n' for v in pal))
    for n in ('clinic_font.hex', 'clinic_text.hex', 'ui_digits.hex'):
        shutil.copy2(CLINIC / n, out / n)
    (out / 'frames.txt').write_text(''.join(' '.join(map(str, f)) + '\n' for f in frames))
    srcs = [BENCH, rtl_dir / 'clinic_screen.v', rtl_dir / 'clinic_card_view.v', rtl_dir / 'clinic_card_store.v', TIMING]
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-s', 'tb', f'-Ptb.MAX_FRAMES={len(frames)}',
                    '-o', 'tb.vvp'] + [str(s) for s in srcs], cwd=out, check=True)
    proc = subprocess.run([VVP, '-n', 'tb.vvp', f'+READY={ready:06b}'], cwd=out, capture_output=True, text=True,
                          timeout=7200)
    (out / 'run.log').write_text(proc.stdout + proc.stderr, encoding='utf-8')
    if 'PASS CARD_SCREEN_DUMP' not in proc.stdout:
        print(proc.stdout[-1500:])
        return ['bench failed']
    t, chars, code, text_rom, font = assets.build()
    expect, sts = ref.render(frames, ready, cards, t, code, font, in_rgb)
    errors = []
    got_states = [tuple(map(int, l.split())) for l in (out / 'states.txt').read_text().splitlines()]
    for i, (g, (st, k, card)) in enumerate(zip(got_states, sts)):
        if g[:3] != (st, k, card):
            errors.append(f'frame {i + 1}: RTL state {g[:3]}, reference {(st, k, card)}')
    if len(got_states) != len(frames) or 'frames=%d' % len(frames) not in proc.stdout:
        errors.append(f'{len(got_states)} state lines for {len(frames)} frames')
    dump = (out / 'frames.hex').read_text().split()
    dumped = [i for i, f in enumerate(frames) if f[10]]
    if len(dump) != 307200 * len(dumped):
        errors.append(f'dump has {len(dump)} pixels, expected {307200 * len(dumped)}')
    else:
        for n, fi in enumerate(dumped):
            got = [int(v, 16) for v in dump[n * 307200:(n + 1) * 307200]]
            want = expect[fi]
            bad = [i for i in range(307200) if got[i] != want[i]]
            st, k, card = sts[fi]
            write_png(out / f'frame_{fi + 1:03d}_st{st}_k{k:02d}_c{card}.png', got)
            if bad:
                i = bad[0]
                errors.append(f'frame {fi + 1} (st {st} k {k} card {card}): {len(bad)} pixels differ, '
                              f'first x={i % 640} y={i // 640} got {got[i]:06x} want {want[i]:06x}')
                write_png(out / f'frame_{fi + 1:03d}_expected.png', want)
    (out / 'frames.hex').unlink()
    (out / 'tb.vvp').unlink()
    print(f'{name}: {len(frames)} frames, {len(dumped)} compared pixel by pixel,',
          'PASS' if not errors else f'FAIL ({len(errors)})')
    for e in errors[:12]:
        print('   ', e)
    return errors


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only')
    ap.add_argument('--rtl-dir', type=Path, default=CLINIC)
    ap.add_argument('--out', type=Path, default=EVID / 'card_screen')
    args = ap.parse_args()
    keys = [args.only] if args.only else list(SCENARIOS)
    started = datetime.datetime.now().isoformat()
    results = {k: not run(k, args.rtl_dir.resolve(), args.out) for k in keys}
    summary = {'started': started, 'finished': datetime.datetime.now().isoformat(), 'results': results,
               'passed': all(results.values()),
               'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
                           [args.rtl_dir / 'clinic_screen.v', args.rtl_dir / 'clinic_card_view.v',
                            args.rtl_dir / 'clinic_card_store.v', BENCH, Path(__file__), HERE / 'card_screen_ref.py']}}
    (args.out / f'summary_{"".join(keys)}.json').write_text(json.dumps(summary, indent=1), encoding='utf-8')
    print('PASS' if summary['passed'] else 'FAIL')
    sys.exit(0 if summary['passed'] else 1)


if __name__ == '__main__':
    main()
