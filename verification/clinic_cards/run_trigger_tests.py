"""10/24 clinic card trigger regression (click counter, status d9).

tb_card_trigger.sv runs clinic_card_view's frame-rate state machine; every frame's (st, k, card)
must equal card_screen_ref.states(). Scenarios:
  same_again   card 3 clicked, zooms, shrinks back; the SAME card clicked again (counter +1,
               last_card unchanged) zooms again; clicking it again while it is zoomed is ignored
  old_hall     counter stays 0 (old hall build): a different card still zooms, the same card
               again does not (the 10/23 behaviour)
  other_card   counter + different card during the hold: shrink, then the other card zooms
  wrap         counter wraps 255 -> 0 and still triggers; link down/up re-arms without a zoom
Besides RTL == model, explicit expectations are checked for the key frames.
Usage: python run_trigger_tests.py
"""
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(HERE))
import card_screen_ref as ref  # noqa: E402

IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
HDL = LAB / 'src/user_source/hdl_source'
OUT = LAB / 'delivery/ui_redesign_20261024/evidence/clinic_trigger'


def fr(last, lv, clicks, help_=0, link=1):
    # card_screen_ref frame tuple + clicks: (call, issued, waiting, last, lv, help, link, alarm, op, ops, dump, clicks)
    return (0, 0, 0, last, lv, help_, link, 0, 0, 0, 0, clicks)


def cycle(last, clicks, n):
    return [fr(last, 1, clicks) for _ in range(n)]


ZOOM = 18 + 4 + 17        # grow + hold + shrink frames (bench HOLD_FRAMES = 4)


def same_again():
    f = cycle(0, 0, 4)                         # arm (card 0 valid at power-up: no zoom)
    f += cycle(3, 1, 1 + ZOOM + 2)             # card 3 clicked (counter 1): zoom, back to idle
    f += cycle(3, 2, 10)                       # same card again (counter 2): zooms again
    f += cycle(3, 3, ZOOM)                     # clicked once more while zoomed: ignored
    f += cycle(3, 3, 6)
    a = 4 + 1 + ZOOM + 2
    exp = {3: (0, 0, 0), 4: (1, 1, 3), 4 + ZOOM: (0, 0, 3), a: (1, 1, 3), a + 10: (1, 11, 3),
           a + ZOOM: (0, 0, 3), len(f) - 1: (0, 0, 3)}
    return f, exp


def old_hall():
    f = cycle(0, 0, 4)
    f += cycle(3, 0, 1 + ZOOM + 2)
    f += cycle(3, 0, 10)                       # same card, no counter: nothing
    f += cycle(4, 0, 3)                        # another card: zooms
    a = 4 + 1 + ZOOM + 2
    exp = {4: (1, 1, 3), a: (0, 0, 3), a + 10: (1, 1, 4)}
    return f, exp


def other_card():
    f = cycle(0, 0, 4)
    f += cycle(2, 5, 20)                       # card 2 grows (18) and holds
    f += cycle(5, 6, 20)                       # card 5 during the hold: shrink, then card 5
    f += cycle(5, 6, 10)
    exp = {4: (1, 1, 2), 24: (3, 17, 2), 24 + 17: (1, 1, 5)}
    return f, exp


def wrap():
    f = cycle(1, 255, 4)                       # counter already 255 at power-up: no zoom
    f += cycle(1, 0, 1 + ZOOM + 2)             # 255 -> 0: same card zooms
    f += [fr(1, 1, 0, link=0) for _ in range(3)]
    f += cycle(1, 7, 3)                        # counter moved while the link was down: no zoom
    f += cycle(1, 8, 2)                        # next click after re-arming: zoom
    a = 4 + 1 + ZOOM + 2 + 3
    exp = {3: (0, 0, 0), 4: (1, 1, 1), a: (0, 0, 1), a + 2: (0, 0, 1), a + 3: (1, 1, 1)}
    return f, exp


SCEN = {'same_again': same_again, 'old_hall': old_hall, 'other_card': other_card, 'wrap': wrap}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    vvp = OUT / 'trigger.vvp'
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-o', str(vvp), str(HERE / 'tb_card_trigger.sv'),
                    str(HDL / 'clinic/clinic_card_view.v')], check=True)
    bad = 0
    for name, make in SCEN.items():
        frames, exp = make()
        d = OUT / name
        d.mkdir(exist_ok=True)
        (d / 'trigger.txt').write_text(''.join(f'{f[3]} {f[4]} {f[5]} {f[6]} {f[11]}\n' for f in frames))
        r = subprocess.run([VVP, '-n', str(vvp)], cwd=d, capture_output=True, text=True)
        if 'PASS TRIGGER_DUMP' not in r.stdout:
            print(name, 'FAIL bench', r.stdout[-500:], r.stderr[-500:])
            bad += 1
            continue
        rtl = [tuple(map(int, l.split())) for l in (d / 'trigger_states.txt').read_text().splitlines()]
        model = ref.states(frames)
        diff = [i for i, (a, b) in enumerate(zip(rtl, model)) if a != b]
        if len(rtl) != len(model):
            diff.append(-1)
        miss = [(i, e, rtl[i]) for i, e in exp.items() if rtl[i] != e]
        ok = not diff and not miss
        bad += not ok
        print(f'{name}: {"PASS" if ok else "FAIL"} frames={len(rtl)} rtl/model diffs={diff[:5]} '
              f'expectation misses={miss}')
    print('ALL PASS' if not bad else f'{bad} FAILED')
    sys.exit(bad != 0)


if __name__ == '__main__':
    main()
