"""10/24 UI v3 display regression: RTL full frames vs the independent reference (ui3_ref.py).

Hall (tb_hall_screen.sv, hospital_screen over photo.hex, adjust/prompt timers shortened to 6
frames in the bench):
  H_basic   normal operation; ticker scrolls one pixel per frame; voice/queue/history fields
  H_adjust  brightness/contrast/volume/rotation change -> adjust line replaces the ticker for 6
            frames, then the ticker returns; no adjust line at power-up; a reject prompt (red)
            for 6 frames; an adjust during a prompt wins
  H_states  call 0 (---, 等待叫号), nobody waiting (暂无), history blanks (---), help pending (red),
            voice fault (red), network down / clinic offline (red), photo error E12, photo
            loading, queue 12, issued 20, every brightness/contrast/volume digit format
  H_ticker  ticker wrap-around (scroll set near the period) and the right clip
  H_flicker scroll positions where a glyph has one visible column at the ticker's left edge
  H_res     10/26 SW4: "PIC<n>.BMP  原图 W×H → 显示 w×h" for several resolutions (4-digit and
            3-digit widths/heights, portrait), hidden while the photo is loading, an adjust line /
            prompt wins, SW4 off brings the ticker back; SW4 gets mid-frame noise (frame-latched)
Clinic (tb_card_screen.sv: new clinic_screen + clinic_card_view + card store with the demo
pictures; card reference card_screen_ref.render with ui3_ref.clinic_frame as the screen):
  C_status  idle / operation results (sending, done, refused, busy, not delivered) / link down /
            help alert blink / call 0 / waiting 0 / issued 20
  C_zoom    a card with a picture zooms (grow, hold, shrink frames) and a card without a picture
            (white box, then the centred words panel); help zoom with red border
Every dumped frame must match the reference pixel for pixel.
Usage: python run_ui3_tests.py [--only NAME]
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(LAB / 'verification/clinic_cards'))
sys.path.insert(0, str(LAB / 'verification/image_scale'))
import ui3_ref as R  # noqa: E402
import card_screen_ref as CR  # noqa: E402
from run_screen_tests import load_cards, in_rgb as clinic_in_rgb  # noqa: E402
import scaler_ref  # noqa: E402

IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
HDL = LAB / 'src/user_source/hdl_source'
DISP, CLIN = HDL / 'display', HDL / 'clinic'
EVID = LAB / 'delivery/ui_redesign_20261024/evidence/ui3_display'
ADJ = 6
HALL_KEYS = ('call issued waiting r1 needs help lroom vstatus bri con volmode music voice rej h1 h2 h3 '
             'r2 r3 r4 hroom present phy online ready auto err dump sset res rpic clo chi rep tgt').split()


def H(**kw):
    f = dict(call=6, issued=20, waiting=14, r1=5, needs=0, help=0, lroom=1, vstatus=0, bri=0, con=0, volmode=0,
             music=2, voice=10, rej=0, h1=5, h2=4, h3=3, r2=6, r3=0, r4=0, hroom=0, present=3, phy=1,
             online=1, ready=1, auto=1, err=0, dump=0, sset=-1, res=0, rpic=0, wh=(640, 480), rep=0, tgt=0)
    f.update(kw)
    fit = scaler_ref.fit(*f['wh'])                   # shown size (the scaler's rule)
    f['cells'] = R.res_cells(*f['wh'], fit['Wo'], fit['Ho'])
    f['clo'], f['chi'] = R.res_words(f['cells'])
    return f


def view(f):
    """bench frame -> the reference's view dict (rooms list etc.)"""
    return dict(f, rooms=[f['r1'], f['r2'], f['r3'], f['r4']])


def hall_basic():
    fr = [H(dump=i in (0, 4)) for i in range(5)]
    # room 1 calls 007, room 2 idle, rooms 3/4 present, help confirmed by room 2
    fr += [H(call=7, r1=7, r2=0, lroom=0, waiting=13, dump=1), H(call=7, r1=7, r2=6, present=15, r3=4, r4=0, dump=1),
           H(help=2, hroom=1, dump=1), H(help=1, dump=1)]
    return fr


def hall_rooms():
    # 10/25: hard-of-hearing call flash (needs bit 0) for 300 frames, blinking every 16
    fr = [H(dump=0) for _ in range(4)]
    fr += [H(call=7, r2=7, lroom=1, needs=1, dump=1)]                      # flash starts
    fr += [H(call=7, r2=7, lroom=1, needs=1, dump=k in (14, 15, 16)) for k in range(17)]
    fr += [H(call=8, r1=8, lroom=0, needs=2, dump=1)]                      # next call, no hearing need: off
    fr += [H(call=9, r2=9, lroom=1, needs=0b1001, dump=1)]                 # hearing need again: on
    # 10/26: a replay starts the badge too (no hearing need), restarts it while it runs
    fr += [H(call=10, r1=10, lroom=0, needs=0, dump=k == 0) for k in range(300)]   # badge ran out
    fr += [H(call=10, r1=10, lroom=0, rep=1, dump=1)]                      # replay: badge on
    fr += [H(call=10, r1=10, lroom=0, dump=k in (14, 15, 16)) for k in range(17)]   # blinking
    fr += [H(call=10, r1=10, lroom=0, rep=1, dump=1)]                      # replay again: restarts
    return fr


def hall_adjust():
    fr = [H(bri=1, dump=i == 1) for i in range(4)]          # settings differ at power-up: no adjust line
    fr += [H(bri=2, dump=1)]                                 # brightness change -> adjust line
    fr += [H(bri=2, con=1, music=5, dump=1)] + [H(bri=2, con=1, music=5, dump=k == 4) for k in range(5)]
    fr += [H(bri=2, con=1, music=5, dump=1)]                 # timer ran out: ticker again
    fr += [H(bri=2, con=1, music=5, rej=1, waiting=0, dump=1)]           # reject: prompt 0
    fr += [H(bri=2, con=1, music=5, rej=0, dump=1)]
    fr += [H(bri=2, con=1, music=5, voice=3, auto=0, dump=1)]           # adjust wins over the prompt
    fr += [H(bri=2, con=1, music=5, voice=3, auto=0, dump=k == 5) for k in range(6)]
    for i, rej in enumerate((2, 3, 8, 7, 4, 17, 25, 14, 9)):
        fr += [H(bri=2, con=1, music=5, voice=3, auto=0, rej=rej, help=1 if rej == 14 else 0,
                 last=0 if rej == 14 else 1, dump=1)]
    fr += [H(bri=2, con=1, music=5, voice=3, auto=0, volmode=1, dump=1)]   # volume mode toggle: adjust
    return fr


def hall_states():
    fr = [H(dump=0) for _ in range(4)]
    fr += [H(call=0, waiting=0, h1=0, h2=0, h3=0, help=1, busy=0, vstatus=2, phy=0, online=0, err=12, ready=0,
             queued=12, lvalid=0, dump=1)]
    fr += [H(call=20, issued=20, waiting=1, h1=19, h2=0, help=2, busy=0, vstatus=3, err=1, last=5, dump=1)]
    fr += [H(call=9, waiting=10, help=3, busy=0, vstatus=4, last=2, queued=9, dump=1)]
    fr += [H(call=10, waiting=9, last=3, busy=0, vstatus=5, dump=1)]
    for b, c, m, v, a in ((1, 1, 0, 0, 0), (2, 2, 10, 1, 1), (3, 3, 1, 9, 0), (0, 0, 7, 10, 1)):
        fr += [H(bri=b, con=c, music=m, voice=v, auto=a, dump=1)]
    return fr


def hall_ticker():
    p = R.assets('hall')['swidth']['TICKER'] + R.assets('hall')['extra']['TICKER_GAP']
    fr = [H(dump=0) for _ in range(4)]
    fr += [H(sset=p - 2, dump=1), H(dump=1), H(dump=1), H(sset=p - 120, dump=1), H(sset=400, dump=1),
           H(sset=p - 505, dump=1), H(sset=600, dump=1)]
    return fr


def C(call=5, issued=9, waiting=4, last=1, lv=1, help_=0, link=1, alarm=0, op=0, ops=0, dump=0):
    return (call, issued, waiting, last, lv, help_, link, alarm, op, ops, int(dump))


def clinic_status():
    fr = [C(dump=1)] + [C() for _ in range(3)]
    for op in (1, 2, 3):
        for ops in (1, 2, 3, 4, 5):
            fr += [C(op=op, ops=ops, dump=1)]
    fr += [C(op=2, ops=6, dump=1), C(link=0, dump=1), C(help_=1, alarm=1, dump=1), C(help_=1, alarm=0, dump=1),
           C(help_=2, dump=1), C(call=0, waiting=0, issued=0, lv=0, dump=1), C(call=20, waiting=12, issued=20, last=5, dump=1),
           C(help_=1, alarm=1, link=0, dump=1)]
    return fr


def clinic_zoom():
    fr = [C(dump=1)] + [C() for _ in range(3)]
    fr += [C(last=2, dump=k in (1, 9, 18)) for k in range(1, 19)]          # card 3 (picture)
    fr += [C(last=2, dump=k == 0) for k in range(4)] + [C(last=2, dump=k in (1, 16)) for k in range(17)]
    fr += [C(last=4, dump=k in (1, 18)) for k in range(1, 19)]              # card 5: no picture
    fr += [C(last=4, dump=1), C(last=4)]
    fr += [C(last=0, help_=1, alarm=1, dump=1)]                             # help: shrink, then card 1
    fr += [C(last=0, help_=1, alarm=k % 2, dump=k == 8) for k in range(16)]
    fr += [C(last=0, help_=1, dump=k in (1, 18)) for k in range(1, 19)]
    return fr


def hall_flicker():
    # 10/25 bug: a ticker glyph with exactly one visible column at the left clip (scroll 19, 39, ...)
    # stalled the descriptor playback and the rest of the line vanished for that frame
    fr = [H(dump=0) for _ in range(4)]
    fr += [H(sset=s, dump=1) for s in (19, 20, 39, 819)]
    return fr


def hall_res():
    fr = [H(dump=0) for _ in range(4)]
    for pic, wh in enumerate([(1920, 1080), (1024, 768), (1280, 720), (800, 600)]):
        fr += [H(res=1, rpic=pic, wh=wh, dump=1)]
    for wh in [(768, 1024), (641, 481), (1600, 1000), (1919, 1079), (640, 1080)]:
        fr += [H(res=1, rpic=1, wh=wh, dump=1)]
    fr += [H(res=1, rpic=2, wh=(1280, 720), ready=0, dump=1)]            # photo loading: ticker
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=1)]              # adjust line wins
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=k == 6) for k in range(7)]
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, rej=1, waiting=0, dump=1)]   # prompt wins
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=k == 6) for k in range(7)]
    fr += [H(res=0, rpic=2, wh=(1280, 720), bri=1, dump=1)]              # SW4 off: ticker
    return fr


def hall_sw1():
    # 10/28: SW1 up keeps the adjust line (past the 6-frame timer), underline on music / voice;
    # a reject prompt wins for its 6 frames; SW1 + SW4: adjust wins; SW1 down: ticker / SW4 again;
    # the two-line call area idle (等待叫号) and called; ticker colour
    fr = [H(dump=0) for _ in range(4)]
    fr += [H(volmode=1, dump=k in (0, 8, 12)) for k in range(13)]                # permanent
    fr += [H(volmode=1, tgt=1, dump=1), H(volmode=1, tgt=1, voice=7, dump=1)]     # voice selected
    fr += [H(volmode=1, tgt=1, rej=1, waiting=0, dump=1)]                         # prompt wins
    fr += [H(volmode=1, tgt=1, waiting=0, dump=k == 6) for k in range(7)]          # back to adjust
    fr += [H(volmode=1, res=1, rpic=1, wh=(1024, 768), dump=1)]                   # SW1 beats SW4
    fr += [H(volmode=0, res=1, rpic=1, wh=(1024, 768), dump=k in (0, 7)) for k in range(8)]  # 3 s, then SW4
    fr += [H(volmode=0, dump=k == 7) for k in range(8)]                            # ticker
    fr += [H(call=0, waiting=0, r1=0, r2=0, dump=1)]                               # 等待叫号
    fr += [H(call=17, r1=17, lroom=0, dump=1), H(call=20, r2=20, lroom=1, dump=1)]
    return fr


HALL = {'H_sw1': hall_sw1, 'H_res': hall_res, 'H_rooms': hall_rooms, 'H_flicker': hall_flicker, 'H_basic': hall_basic, 'H_adjust': hall_adjust, 'H_states': hall_states, 'H_ticker': hall_ticker}
CLINIC = {'C_status': clinic_status, 'C_zoom': clinic_zoom}
READY = 0b101111          # card 5 (index 4) has no picture


def png(path, px):
    im = Image.new('RGB', (640, 480))
    im.putdata([(v >> 16, v >> 8 & 255, v & 255) for v in px])
    im.save(path)


def compare(out, frames_dump, expect, labels):
    dump = (out / 'frames.hex').read_text().split()
    errors = []
    if len(dump) != 307200 * len(frames_dump):
        return [f'dump has {len(dump)} pixels, expected {307200 * len(frames_dump)}']
    for n, fi in enumerate(frames_dump):
        got = [int(v, 16) for v in dump[n * 307200:(n + 1) * 307200]]
        want = expect[n]
        bad = [i for i in range(307200) if got[i] != want[i]]
        png(out / f'frame_{fi + 1:03d}_{labels[n]}.png', got)
        if bad:
            i = bad[0]
            errors.append(f'frame {fi + 1} ({labels[n]}): {len(bad)} pixels differ, first x={i % 640} y={i // 640} '
                          f'got {got[i]:06x} want {want[i]:06x}')
            png(out / f'frame_{fi + 1:03d}_expected.png', want)
    (out / 'frames.hex').unlink()
    return errors


def run_hall(name, make, root):
    out = root / name
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    frames = make()
    for f in DISP.glob('hall_*.hex'):
        shutil.copy2(f, out / f.name)
    shutil.copy2(HERE / 'photo.hex', out / 'photo.hex')
    (out / 'frames.txt').write_text(''.join(' '.join(str(int(f[k])) for k in HALL_KEYS) + '\n' for f in frames))
    srcs = [HERE / 'tb_hall_screen.sv', DISP / 'hospital_screen.v', DISP / 'ui_text_engine.v', DISP / 'ui_glyph_rom.v',
            DISP / 'ui_table_rom.v', HDL / 'SD/video_timing_ctrl.v']
    subprocess.run([IVERILOG, '-g2012', '-DUI_BEHAVIORAL_ROM', f'-I{DISP}', '-s', 'tb', f'-Ptb.MAX_FRAMES={len(frames)}',
                    f'-Ptb.ADJ={ADJ}', '-o', 'tb.vvp'] + [str(s) for s in srcs], cwd=out, check=True)
    proc = subprocess.run([VVP, '-n', 'tb.vvp'], cwd=out, capture_output=True, text=True, timeout=14400)
    (out / 'run.log').write_text(proc.stdout + proc.stderr, encoding='utf-8')
    if 'PASS HALL_SCREEN_DUMP' not in proc.stdout:
        print(proc.stdout[-1500:])
        return ['bench failed']
    photo = [int(l, 16) for l in (HERE / 'photo.hex').read_text().split() if not l.startswith('//')]
    st = R.HallState(ADJ)
    expect, dumped, labels = [], [], []
    for i, f in enumerate(frames):
        v = st.step(view(f))
        if f['dump']:
            expect.append(R.hall_frame(v, photo))
            dumped.append(i)
            labels.append('adjust' if v['show_adjust'] else f'prompt{v["prompt_id"]}' if v['show_prompt'] else
                          'res{}x{}'.format(*f['wh']) if f['res'] and f['ready'] else f'scroll{v["scroll"]}')
    (out / 'tb.vvp').unlink()
    return compare(out, dumped, expect, labels)


def run_clinic(name, make, root):
    out = root / name
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True, exist_ok=True)
    frames = make()
    cards = load_cards()
    pix, pal = [0] * 65536, [0] * 2048
    for c, (p, q) in enumerate(cards):
        pix[c * 10800:(c + 1) * 10800] = p
        pal[c * 256:(c + 1) * 256] = q
    (out / 'pix.mem').write_text(''.join(f'{v:02x}\n' for v in pix))
    (out / 'pal.mem').write_text(''.join(f'{v:06x}\n' for v in pal))
    for f in DISP.glob('clinic_*.hex'):
        shutil.copy2(f, out / f.name)
    (out / 'frames.txt').write_text(''.join(' '.join(map(str, f)) + '\n' for f in frames))
    srcs = [LAB / 'verification/clinic_cards/tb_card_screen.sv', CLIN / 'clinic_screen.v', CLIN / 'clinic_card_view.v',
            CLIN / 'clinic_card_store.v', DISP / 'ui_text_engine.v', DISP / 'ui_glyph_rom.v', DISP / 'ui_table_rom.v',
            HDL / 'SD/video_timing_ctrl.v']
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-DUI_BEHAVIORAL_ROM', f'-I{CLIN}', '-s', 'tb',
                    f'-Ptb.MAX_FRAMES={len(frames)}', '-o', 'tb.vvp'] + [str(s) for s in srcs], cwd=out, check=True)
    proc = subprocess.run([VVP, '-n', 'tb.vvp', f'+READY={READY:06b}'], cwd=out, capture_output=True, text=True,
                          timeout=14400)
    (out / 'run.log').write_text(proc.stdout + proc.stderr, encoding='utf-8')
    if 'PASS CARD_SCREEN_DUMP' not in proc.stdout:
        print(proc.stdout[-1500:])
        return ['bench failed']

    def screen_fn(f, zoom_panel, zoom_card):
        call, issued, waiting, last, lv, help_, up, alarm, op, ops = f[:10]
        return R.clinic_frame(dict(call=call, issued=issued, waiting=waiting, last=last, lvalid=lv, help=help_,
                                   link=up, alarm=alarm, op=op, ops=ops, panel=zoom_panel, zcard=zoom_card))
    expect, sts = CR.render(frames, READY, cards, None, None, None, clinic_in_rgb, screen_fn=screen_fn)
    errors = []
    got = [tuple(map(int, l.split()))[:3] for l in (out / 'states.txt').read_text().splitlines()]
    if got != [tuple(s) for s in sts]:
        errors.append('animation states differ from the reference')
    dumped = [i for i, f in enumerate(frames) if f[10]]
    labels = [f'st{sts[i][0]}_k{sts[i][1]:02d}_c{sts[i][2]}' for i in dumped]
    (out / 'tb.vvp').unlink()
    return errors + compare(out, dumped, [expect[i] for i in dumped], labels)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only')
    ap.add_argument('--out', type=Path, default=EVID)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    started = datetime.datetime.now().isoformat()
    results = {}
    for name, make in list(HALL.items()) + list(CLINIC.items()):
        if a.only and name != a.only:
            continue
        errs = (run_hall if name in HALL else run_clinic)(name, make, a.out)
        results[name] = not errs
        print(f'{name}: {"PASS" if not errs else "FAIL"}')
        for e in errs[:10]:
            print('   ', e)
    srcs = [DISP / n for n in ('hospital_screen.v', 'ui_text_engine.v', 'ui_glyph_rom.v', 'ui_table_rom.v')] + \
           [CLIN / 'clinic_screen.v', CLIN / 'clinic_card_view.v', HERE / 'ui3_ref.py', HERE / 'ui3_assets.py',
            Path(__file__)]
    summary = {'started': started, 'finished': datetime.datetime.now().isoformat(), 'results': results,
               'passed': all(results.values()),
               'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in srcs}}
    (a.out / f'summary_{a.only or "all"}.json').write_text(json.dumps(summary, indent=1), encoding='utf-8')
    print('ALL PASS' if summary['passed'] else 'FAIL')
    sys.exit(0 if summary['passed'] else 1)


if __name__ == '__main__':
    main()
