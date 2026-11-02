"""10/30 need-card sequence regression (tb_need_seq.sv: clinic_need_trigger + clinic_card_view).

For every scenario the per-frame log is cut into zoom episodes (a view zoom from GROW k=1 until it
returns to IDLE or grows the next card) and compared with the expected list:
  (card, room, number, idx, total, full)  - full = the hold ran its whole time
Help-card episodes (card 4) are written as ('help',). Besides the list, every need-card episode
must keep one title (room / number / idx / total) for all its frames (snapshot), and a card is
only shown for a patient that had that need.
Also runs a few deliberately broken sequencers (must fail) and the command-ownership bench.
Usage: python verification/multiroom/run_need_seq.py
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
HDL = LAB / 'src/user_source/hdl_source'
OUT = LAB / 'delivery/clinic_seq_20261030/evidence/need_seq'
IVL = Path(r'D:\iverilog\iverilog\bin')
SEQ = HDL / 'clinic/clinic_need_trigger.v'
VIEW = HDL / 'clinic/clinic_card_view.v'

A, B = 0, 1
EXPECT = {
    1: [(0, A, 3, 1, 3, 1), (1, A, 3, 2, 3, 1), (3, A, 3, 3, 3, 1)],
    2: [(0, A, 4, 1, 1, 1), (2, B, 5, 1, 2, 1), (3, B, 5, 2, 2, 1)],
    3: [(0, A, 6, 1, 3, 1), (1, A, 6, 2, 3, 1), (2, A, 6, 3, 3, 1), (1, B, 7, 1, 1, 1)],
    4: [(0, A, 8, 1, 4, 1), (1, A, 8, 2, 4, 1), (2, A, 9, 1, 1, 1)],
    5: [(0, A, 10, 1, 2, 0), ('help',), (0, A, 10, 1, 2, 1), (1, A, 10, 2, 2, 1)],
    6: [(0, A, 11, 1, 2, 0), ('help',), (0, A, 11, 1, 2, 0), ('help',), (1, A, 11, 2, 2, 1)],
    7: [(0, A, 12, 1, 1, 1)],
    8: [(0, A, 13, 1, 3, 1)],
    9: [(0, A, 14, 1, 3, 1)],
    10: [(0, A, 15, 1, 2, 0), (0, A, 15, 1, 2, 1), (1, A, 15, 2, 2, 1)],
    11: [(2, A, 19, 1, 1, 1)],
}
NEEDS = {3: 0b1011, 4: 0b0001, 5: 0b1100, 6: 0b0111, 7: 0b0010, 8: 0b1111, 9: 0b0100, 10: 0b0011,
         11: 0b0011, 12: 0b0001, 13: 0b0111, 14: 0b0111, 15: 0b0011, 19: 0b0100}
MUTANTS = [
    ('only the first need (old behaviour)', "act_rem[act_cur] <= 1'b0; act_idx <= act_idx + 1'b1; act_retry <= 1'b0;",
     "act_rem <= 4'd0; act_idx <= act_idx + 1'b1; act_retry <= 1'b0;"),
    ('title follows the newest event', "room <= act_room; number <= act_num;", "room <= room; number <= number;"),
    ('no retry after an interruption', "end else act_retry <= 1'b1;", "end else begin act_rem[act_cur] <= 1'b0; act_idx <= act_idx + 1'b1; end"),
    ('endless retry', "if (act_done || act_retry) begin", "if (act_done) begin"),
    ('duplicates not ignored', "if (a_new && !a_dup && !cancel) begin", "if (a_new && !cancel) begin"),
    ('mode switch does not cancel', "wire cancel = !link_up || mode != mode_q;", "wire cancel = !link_up;"),
    ('new patient does not stop the old one', "if ((act_v && act_side == 1'b0) || load_a) act_stop <= 1'b1;", ""),
]


def episodes(lines):
    """frame log -> list of episodes; each: dict(card, titles=set, full, frames)"""
    eps, cur, prev_st = [], None, 0
    for ln in lines:
        t = ln.split()
        if len(t) != 10:
            continue
        f, st, k, zc, full, room, num, idx, tot, rst = map(int, t)
        if rst:
            cur = None
            prev_st = 0
            continue
        if st == 1 and k == 1:                       # GROW k=1: a new zoom
            cur = {'card': zc, 'titles': set(), 'full': 0, 'frames': 0}
            eps.append(cur)
        if st != 0 and cur is not None:
            cur['titles'].add((room, num, idx, tot))
            cur['full'] |= full
            cur['frames'] += 1
        if st == 0:
            cur = None
        prev_st = st
    return eps


def summarise(eps):
    out, errs = [], []
    for e in eps:
        if e['card'] == 4:
            out.append(('help',))
            continue
        if len(e['titles']) != 1:
            errs.append(f"card {e['card']}: title changed during the zoom {sorted(e['titles'])}")
        room, num, idx, tot = sorted(e['titles'])[0]
        if num in NEEDS and not NEEDS[num] >> e['card'] & 1:
            errs.append(f'card {e["card"]} shown for patient {num} who does not have that need')
        out.append((e['card'], room, num, idx, tot, e['full']))
    return out, errs


def run(seq_text, scen, d):
    d.mkdir(parents=True, exist_ok=True)
    (d / 'clinic_need_trigger.v').write_text(seq_text, encoding='utf-8')
    c = subprocess.run([str(IVL / 'iverilog'), '-g2012', '-s', 'tb_need_seq', f'-Ptb_need_seq.SCEN={scen}',
                        '-o', str(d / 'tb.vvp'), str(HERE / 'tb_need_seq.sv'), str(d / 'clinic_need_trigger.v'), str(VIEW)],
                       capture_output=True, text=True)
    if c.returncode:
        return None, ['compile: ' + (c.stdout + c.stderr)[-300:]]
    p = subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=d, capture_output=True, text=True, timeout=600)
    if 'PASS SEQ_DUMP' not in p.stdout:
        return None, ['bench: ' + p.stdout[-300:]]
    got, errs = summarise(episodes((d / 'seq.log').read_text().splitlines()))
    if got != EXPECT[scen]:
        errs.append(f'episodes {got} != expected {EXPECT[scen]}')
    return got, errs


def cmd_room():
    d = OUT / 'cmd_room'
    d.mkdir(parents=True, exist_ok=True)
    c = subprocess.run([str(IVL / 'iverilog'), '-g2012', '-s', 'tb_cmd_room', '-o', str(d / 'tb.vvp'),
                        '-y', str(HDL / 'app'), '-y', str(HDL / 'link'), '-y', str(HDL / 'clinic'), '-y', str(HDL / 'uart'),
                        '-I', str(HDL / 'include'), str(HERE / 'tb_cmd_room.sv')], capture_output=True, text=True)
    if c.returncode:
        return False, c.stdout + c.stderr
    p = subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=d, capture_output=True, text=True, timeout=600)
    (d / 'run.log').write_text(p.stdout)
    return 'PASS CMD_ROOM' in p.stdout, p.stdout.strip().splitlines()[0] if p.stdout.strip() else ''


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    src = SEQ.read_text(encoding='utf-8')
    ok = True
    for scen in EXPECT:
        got, errs = run(src, scen, OUT / f'scen{scen}')
        print(f'scenario {scen}: {"PASS" if not errs else "FAIL"}  {got}')
        for e in errs:
            print('    ', e)
        ok &= not errs
    caught = 0
    for name, old, new in MUTANTS:
        assert src.count(old) == 1, name
        bad = src.replace(old, new)
        hit = False
        for scen in EXPECT:
            _, errs = run(bad, scen, OUT / ('mut_' + re.sub(r'\W+', '_', name)) / f's{scen}')
            if errs:
                hit = True
                break
        caught += hit
        print(f'  mutant {name}: {"caught" if hit else "MISSED"}')
    ok &= caught == len(MUTANTS)
    print(f'mutants caught {caught}/{len(MUTANTS)}')
    cr, info = cmd_room()
    print('command ownership bench:', 'PASS' if cr else 'FAIL', info)
    ok &= cr
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
