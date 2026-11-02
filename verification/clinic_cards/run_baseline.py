"""Baseline: the UI-B clinic screen reference model against the clinic_screen.v from before 10/23.

Proves the copied reference model (screen_ref.py) still matches the original hardware before it is
extended for the card grid. Same frame list as the UI-B delivery's run_clinic_tests.py.
Usage: python run_baseline.py <clinic_screen.v> <output dir>
"""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(HERE))
import clinic_screen_assets as assets  # noqa: E402
from screen_ref import render_clinic  # noqa: E402

IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
TIMING = LAB / 'src/user_source/hdl_source/SD/video_timing_ctrl.v'
CLINIC = LAB / 'src/user_source/hdl_source/clinic'

FRAMES = [
    (0, 0, 0, 0, 0, 0, 1, 0, 0, 0), (0, 3, 3, 0, 0, 0, 1, 0, 1, 1), (1, 3, 2, 0, 0, 0, 1, 0, 1, 2),
    (1, 3, 2, 0, 1, 1, 1, 1, 2, 4), (1, 3, 2, 0, 1, 1, 1, 0, 3, 2), (2, 5, 3, 5, 1, 0, 1, 0, 3, 3),
    (20, 20, 0, 3, 1, 2, 1, 0, 1, 3), (20, 20, 0, 3, 1, 2, 0, 0, 1, 5), (7, 12, 5, 1, 1, 0, 1, 0, 2, 2),
]
for _op in range(1, 4):
    for _result in range(1, 6):
        _call = 0 if (_op == 2 and _result == 3) else 5
        _issued = _call if (_op == 1 and _result == 3) else 13
        _help = 0 if (_op == 3 and _result == 3) else 1
        FRAMES.append((_call, _issued, _issued - _call, 1, 1, _help, 1, 1, _op, _result))
for _card in range(6):
    FRAMES.append((6, 9, 3, _card, 1, 1 if _card == 0 else 0, 1, 0, 0, 0))
for _number in (1, 9, 10, 19, 20):
    _issued = min(20, _number + 3)
    FRAMES.append((_number, _issued, _issued - _number, 5, 1, 0, 1, 0, 0, 0))


import os
if os.environ.get('ONLY'):
    a, b = map(int, os.environ['ONLY'].split(':'))
    FRAMES = FRAMES[a:b]


def in_rgb(x, y):
    return ((x & 255) ^ 0x5a) << 16 | (y & 255) << 8 | (((x >> 2) & 255) + ((y >> 1) & 255)) & 255


def main():
    rtl = Path(sys.argv[1]).resolve()
    out = Path(sys.argv[2]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    for name in ('clinic_font.hex', 'clinic_text.hex', 'ui_digits.hex'):
        (out / name).write_bytes((CLINIC / name).read_bytes())
    (out / 'frames.txt').write_text(''.join(' '.join(map(str, f)) + '\n' for f in FRAMES))
    subprocess.run([IVERILOG, '-g2012', '-s', 'tb', f'-Ptb.MAX_FRAMES={len(FRAMES)}', '-o', 'b.vvp',
                    str(HERE / 'tb_clinic_screen_orig.sv'), str(rtl), str(TIMING)], cwd=out, check=True)
    log = subprocess.run([VVP, '-n', 'b.vvp'], cwd=out, capture_output=True, text=True).stdout
    if 'PASS CLINIC_DUMP' not in log:
        raise SystemExit(log[-2000:])
    t, chars, code, text_rom, font = assets.build()
    expect = render_clinic(FRAMES, t, code, font, in_rgb)
    dump = (out / 'clinic_frames.hex').read_text().split()
    bad = 0
    for fi in range(len(FRAMES)):
        got = [int(v, 16) for v in dump[fi * 307200:(fi + 1) * 307200]]
        n = sum(1 for i in range(307200) if got[i] != expect[fi][i])
        if n:
            i = next(i for i in range(307200) if got[i] != expect[fi][i])
            print(f'frame {fi + 1}: {n} mismatches, first x={i % 640} y={i // 640} got {got[i]:06x} want {expect[fi][i]:06x}')
            bad += 1
    from PIL import Image
    for fi in range(min(2, len(FRAMES))):
        got = [int(v, 16) for v in dump[fi * 307200:(fi + 1) * 307200]]
        im = Image.new('RGB', (1280, 480))
        im.putdata([0] * 0 + [])
        a = Image.new('RGB', (640, 480)); a.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in got])
        b = Image.new('RGB', (640, 480)); b.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in expect[fi]])
        im.paste(a, (0, 0)); im.paste(b, (640, 0)); im.save(out / f'cmp_{fi + 1}.png')
    (out / 'clinic_frames.hex').unlink()
    print('BASELINE', 'PASS' if not bad else 'FAIL', len(FRAMES), 'frames')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
