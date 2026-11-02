"""10/30 one-off: tb_clinic_ui loop count 27; run_clinic_ui.py gets the zidx / ztot keys, the
reference model the "需求 i/n" title fields, and a 'seq' screenshot scenario (two needs in turn)."""
from pathlib import Path
p = Path('verification/multiroom/tb_clinic_ui.sv'); t = p.read_text(encoding='utf-8')
a = '        while (f == 25) begin'
assert t.count(a) == 1
p.write_text(t.replace(a, '        while (f == 27) begin'), encoding='utf-8')

p = Path('verification/multiroom/run_clinic_ui.py'); t = p.read_text(encoding='utf-8')
reps = [
 ("'zcard zvalid zclicks zroom znum dump').split()", "'zcard zvalid zclicks zroom znum zidx ztot dump').split()"),
 ("zcard=0, zvalid=0, zclicks=0, zroom=0, znum=0, dump=0)", "zcard=0, zvalid=0, zclicks=0, zroom=0, znum=0, zidx=0, ztot=0, dump=0)"),
 ("Usage: python run_clinic_ui.py [--scenario look|S_status|S_zoom|S_single] [--check]",
  "Usage: python run_clinic_ui.py [--scenario look|seq|S_status] [--check]\n"
  "  seq (10/30): a patient with two needs - card 1/2 grows, holds, shrinks, card 2/2 follows,\n"
  "  then the normal page; screenshots go to delivery/clinic_seq_20261030/screens."),
 ("def main():",
  """def seq():
    # room 1 patient 7 checked in with 听力差 + 需家属或翻译 (needs 1001): two cards in turn
    base = dict(an=7, arec=rec(0b1001, 0, 6))
    fr = [F(**base, dump=k == 2) for k in range(3)]                                   # normal page
    z1 = dict(base, zcard=0, zvalid=1, zclicks=1, zroom=0, znum=7, zidx=1, ztot=2)
    fr += [F(**z1, dump=k in (8, 19)) for k in range(1, 46)]                           # grow, hold, shrink
    z2 = dict(z1, zcard=3, zclicks=2, zidx=2)
    fr += [F(**z2, dump=k == 19) for k in range(1, 46)]
    fr += [F(**z2, dump=k == 3) for k in range(4)]                                     # back to normal
    return fr, ['seq_normal', 'seq_need1of2_growing', 'seq_need1of2', 'seq_need2of2', 'seq_back_normal']


def main():"""),
 ("    frames, names = {'look': look, 'S_status': status}[a.scenario]()",
  "    frames, names = {'look': look, 'seq': seq, 'S_status': status}[a.scenario]()"),
 ("        im.save(MOCK / f'rtl_clinic_{name}.png')",
  "        dest = LAB / 'delivery/clinic_seq_20261030/screens' if a.scenario == 'seq' else MOCK\n"
  "        dest.mkdir(parents=True, exist_ok=True)\n"
  "        im.save(dest / f'rtl_clinic_{name}.png')"),
]
for a, b in reps:
    assert t.count(a) == 1, a; t = t.replace(a, b)
p.write_text(t, encoding='utf-8')
print('ok')
