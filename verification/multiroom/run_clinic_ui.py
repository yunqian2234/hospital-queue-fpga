"""10/25 quick look / pixel regression driver for the multi-room clinic screen.

Builds pix.mem / pal.mem from the ENT need cards (delivery/multiroom_20261025/tf_card_clinic),
writes frames.txt for tb_clinic_ui.sv, runs it and saves the dumped frames as PNG. With --check
the frames are compared pixel by pixel against clinic_mr_ref.py (independent reference).
Usage: python run_clinic_ui.py [--scenario look|seq|S_status] [--check]
  seq (10/30): a patient with two needs - card 1/2 grows, holds, shrinks, card 2/2 follows,
  then the normal page; screenshots go to delivery/clinic_seq_20261030/screens.
"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
HDL = LAB / 'src/user_source/hdl_source'
CARDS = LAB / 'delivery/multiroom_20261025/tf_card_clinic'
OUT = LAB / 'delivery/multiroom_20261025/evidence/clinic_ui'
MOCK = LAB / 'delivery/multiroom_20261025'
IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
KEYS = ('dual call issued waiting help hroom link alarm aroom an bn arec brec arok brok aop aops bop bops '
        'zcard zvalid zclicks zroom znum zidx ztot dump').split()


def load_card(path):
    b = path.read_bytes()
    off = struct.unpack_from('<I', b, 10)[0]
    w, h = struct.unpack_from('<ii', b, 18)
    used = struct.unpack_from('<I', b, 46)[0] or 256
    pal = [(b[54 + 4 * i + 2] << 16) | (b[54 + 4 * i + 1] << 8) | b[54 + 4 * i] for i in range(used)]
    stride = (w + 3) & ~3
    pix = []
    for y in range(h):
        row = off + (h - 1 - y) * stride
        pix += list(b[row:row + w])
    return pix, pal + [0] * (256 - len(pal))


def rec(needs=0, sym=15, lvl=15):
    return needs << 8 | sym << 4 | lvl


def F(**kw):
    f = dict(dual=1, call=6, issued=12, waiting=6, help=0, hroom=0, link=1, alarm=0, aroom=0, an=5, bn=6,
             arec=rec(1, 1, 6), brec=rec(0, 5, 3), arok=1, brok=1, aop=1, aops=2, bop=0, bops=0,
             zcard=0, zvalid=0, zclicks=0, zroom=0, znum=0, zidx=0, ztot=0, dump=0)
    f.update(kw)
    return f


def look():
    fr = [F(dump=1)]                                                           # dual idle
    fr += [F() for _ in range(3)]
    fr += [F(zcard=0, zvalid=1, zclicks=1, zroom=1, znum=6, dump=k == 18) for k in range(1, 20)]   # card zooms
    fr += [F(help=1, alarm=1, zcard=0, zvalid=1, zclicks=1, dump=0) for _ in range(30)]
    fr += [F(help=1, alarm=1, zcard=0, zvalid=1, zclicks=1, dump=1)]          # help card zoomed
    fr += [F(dual=0, an=7, arec=rec(0b1010, 7, 9), help=0, zcard=0, zvalid=1, zclicks=1) for _ in range(40)]
    fr += [F(dual=0, an=7, arec=rec(0b1010, 7, 9), help=2, hroom=0, zcard=0, zvalid=1, zclicks=1, dump=1)]
    return fr, ['dual_idle', 'zoom_room2', 'zoom_help', 'single']


def status():
    fr = [F() for _ in range(3)]
    fr += [F(dump=1)]                                                            # dual, both rooms
    fr += [F(an=3, arec=0x0FF, bn=11, brec=rec(15, 9, 10), dump=1)]             # unregistered / all needs
    fr += [F(an=12, arec=rec(0, 15, 15), bn=13, brec=rec(0, 2, 0), waiting=10, issued=20, dump=1)]
    fr += [F(an=8, arec=rec(0b1010, 6, 7), bn=9, brec=rec(0b0100, 3, 1), dump=1)]       # packed needs
    for op in (1, 2, 3):
        for ops in (1, 3, 4, 5):
            fr += [F(aop=op, aops=ops, bop=4 - op, bops=6 - ops if ops > 1 else 2, dump=1)]
    fr += [F(link=0, dump=1), F(an=0, bn=0, dump=1)]
    fr += [F(help=1, alarm=k % 2) for k in range(45)]                          # help zoom runs out
    fr += [F(help=1, alarm=1, dump=1), F(help=1, alarm=0, dump=1)]
    fr += [F(help=2, hroom=1, dump=1), F(help=2, hroom=1)]
    fr += [F(dual=0, aroom=1, an=7, waiting=12, issued=19, call=7, dump=1)]     # single mode, room 2
    fr += [F(dual=0, aroom=0, an=0, waiting=0, call=0, help=1, alarm=1, dump=1)]
    return fr, None


def seq():
    # room 1 patient 7 checked in with 听力差 + 需家属或翻译 (needs 1001): two cards in turn
    base = dict(an=7, arec=rec(0b1001, 0, 6))
    fr = [F(**base, dump=k == 2) for k in range(3)]                                   # normal page
    z1 = dict(base, zcard=0, zvalid=1, zclicks=1, zroom=0, znum=7, zidx=1, ztot=2)
    fr += [F(**z1, dump=k in (8, 19)) for k in range(1, 46)]                           # grow, hold, shrink
    z2 = dict(z1, zcard=3, zclicks=2, zidx=2)
    fr += [F(**z2, dump=k == 19) for k in range(1, 46)]
    fr += [F(**z2, dump=k == 3) for k in range(4)]                                     # back to normal
    return fr, ['seq_normal', 'seq_need1of2_growing', 'seq_need1of2', 'seq_need2of2', 'seq_back_normal']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--scenario', default='look')
    a = ap.parse_args()
    check = a.scenario != 'look'
    out = OUT / a.scenario
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    pix, pal = [0] * 65536, [0] * 2048
    for c in range(5):
        p, q = load_card(CARDS / f'CARD{c + 1}.BMP')
        pix[c * 10800:(c + 1) * 10800] = p
        pal[c * 256:(c + 1) * 256] = q
    (out / 'pix.mem').write_text(''.join(f'{v:02x}\n' for v in pix))
    (out / 'pal.mem').write_text(''.join(f'{v:06x}\n' for v in pal))
    for f in (HDL / 'display').glob('clinic_*.hex'):
        shutil.copy2(f, out / f.name)
    frames, names = {'look': look, 'seq': seq, 'S_status': status}[a.scenario]()
    (out / 'frames.txt').write_text(''.join(' '.join(str(int(f[k])) for k in KEYS) + '\n' for f in frames))
    d = HDL / 'display'
    srcs = [HERE / 'tb_clinic_ui.sv', HDL / 'clinic/clinic_screen.v', HDL / 'clinic/clinic_card_view.v',
            HDL / 'clinic/clinic_card_store.v', d / 'ui_text_engine.v', d / 'ui_glyph_rom.v', d / 'ui_table_rom.v',
            HDL / 'SD/video_timing_ctrl.v']
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-DUI_BEHAVIORAL_ROM', f'-I{HDL / "clinic"}',
                    '-s', 'tb', f'-Ptb.MAX_FRAMES={len(frames)}', '-o', 'tb.vvp'] + [str(s) for s in srcs],
                   cwd=out, check=True)
    r = subprocess.run([VVP, '-n', 'tb.vvp', '+READY=011111'], cwd=out, capture_output=True, text=True)
    print(r.stdout[-300:])
    dump = (out / 'frames.hex').read_text().split()
    if check:
        sys.path.insert(0, str(HERE))
        import clinic_mr_ref as ref
        sts = [tuple(map(int, l.split())) for l in (out / 'states.txt').read_text().splitlines()]
        st = ref.ClinicState()
        bad = compared = skipped = 0
        n = 0
        for i, f in enumerate(frames):
            v = st.step(f)
            if not f['dump']:
                continue
            got = [int(x, 16) for x in dump[n * 307200:(n + 1) * 307200]]
            n += 1
            im = Image.new('RGB', (640, 480))
            im.putdata([(p >> 16, p >> 8 & 255, p & 255) for p in got])
            im.save(out / f'frame_{i + 1:03d}.png')
            if sts[i][0] != 0:
                skipped += 1
                continue
            want = ref.frame(v)
            diff = [k for k in range(307200) if got[k] != want[k]]
            compared += 1
            if diff:
                bad += 1
                k = diff[0]
                print(f'frame {i + 1}: {len(diff)} pixels differ, first x={k % 640} y={k // 640} '
                      f'got {got[k]:06x} want {want[k]:06x}')
                im.putdata([(p >> 16, p >> 8 & 255, p & 255) for p in want])
                im.save(out / f'frame_{i + 1:03d}_expected.png')
        print(f'{a.scenario}: {compared} frames compared pixel by pixel, {skipped} zoom frames skipped,',
              'PASS' if not bad and compared else 'FAIL')
        (out / 'frames.hex').unlink()
        return
    for n, name in enumerate(names):
        im = Image.new('RGB', (640, 480))
        im.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in (int(x, 16) for x in dump[n * 307200:(n + 1) * 307200])])
        dest = LAB / 'delivery/clinic_seq_20261030/screens' if a.scenario == 'seq' else MOCK
        dest.mkdir(parents=True, exist_ok=True)
        im.save(dest / f'rtl_clinic_{name}.png')
    print('wrote', names)


if __name__ == '__main__':
    main()
