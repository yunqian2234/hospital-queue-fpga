"""10/24 UI v3 quick look: clinic_screen + clinic_card_view + card store (behavioural) over a few
frames with the demo card pictures; writes PNGs to delivery/ui_redesign_20261024/mockups.
Uses tb_card_screen.sv (one line of frames.txt per frame, see that bench).
Usage: python look_clinic.py [--src-screen PATH]
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(LAB / 'verification/clinic_cards'))
from run_screen_tests import load_cards, F, IVERILOG, VVP  # noqa: E402

HDL = LAB / 'src/user_source/hdl_source'
OUT = LAB / 'delivery/ui_redesign_20261024/evidence/look_clinic'
MOCK = LAB / 'delivery/ui_redesign_20261024/mockups'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--src-screen', type=Path, default=HDL / 'clinic/clinic_screen.v')
    ap.add_argument('--assets', type=Path, default=HDL / 'display')
    a = ap.parse_args()
    a.src_screen, a.assets = a.src_screen.resolve(), a.assets.resolve()
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir(parents=True)
    cards = load_cards()
    pix, pal = [0] * 65536, [0] * 2048
    for c, (p, q) in enumerate(cards):
        pix[c * 10800:(c + 1) * 10800] = p
        pal[c * 256:(c + 1) * 256] = q
    (OUT / 'pix.mem').write_text(''.join(f'{v:02x}\n' for v in pix))
    (OUT / 'pal.mem').write_text(''.join(f'{v:06x}\n' for v in pal))
    for f in a.assets.glob('clinic_*.hex'):
        shutil.copy2(f, OUT / f.name)
    # 1 idle (card 2 latest, op done) | 2..4 arm | card 4 (no picture) zooms -> hold panel | help
    frames = [F(1, 1, op=1, ops=2, dump=1)] + [F(1, 1, op=1, ops=2) for _ in range(3)]
    frames += [F(4, 1, dump=(k == 9)) for k in range(1, 19)] + [F(4, 1, dump=1), F(4, 1)]
    frames += [F(0, 1, help_=1, alarm=1, link=1, op=3, ops=1, dump=1)]
    names = ['idle', 'zoom_move', 'zoom_panel', 'help']
    (OUT / 'frames.txt').write_text(''.join(' '.join(map(str, f)) + '\n' for f in frames))
    d = HDL / 'display'
    srcs = [LAB / 'verification/clinic_cards/tb_card_screen.sv', a.src_screen, HDL / 'clinic/clinic_card_view.v',
            HDL / 'clinic/clinic_card_store.v', d / 'ui_text_engine.v', d / 'ui_glyph_rom.v', d / 'ui_table_rom.v',
            HDL / 'SD/video_timing_ctrl.v']
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-DUI_BEHAVIORAL_ROM', f'-I{a.assets}',
                    '-s', 'tb', f'-Ptb.MAX_FRAMES={len(frames)}', '-o', 'tb.vvp'] + [str(s) for s in srcs],
                   cwd=OUT, check=True)
    r = subprocess.run([VVP, '-n', 'tb.vvp', '+READY=101111'], cwd=OUT, capture_output=True, text=True)
    print(r.stdout[-400:])
    dump = (OUT / 'frames.hex').read_text().split()
    for n, name in enumerate(names):
        im = Image.new('RGB', (640, 480))
        im.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in (int(x, 16) for x in dump[n * 307200:(n + 1) * 307200])])
        im.save(MOCK / f'rtl_try_clinic_{name}.png')
    print('wrote', [f'rtl_try_clinic_{n}.png' for n in names])


if __name__ == '__main__':
    main()
