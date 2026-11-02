"""Headless TD CHECK of the 20261021 hall project (10/24 UI v3 copy of touch_pause_20261022/tools).

Differences from the earlier copy: the phy script has NO manual fix_hold and NO bitgen - the
check must match what the GUI does on its own (DefaultFlow route with its built-in hold fix,
which TD skips above 90 % slice use). Evidence goes to delivery/ui_redesign_20261024/evidence.
The log is searched for "hold fixing is skipped".

Reproduces the teammate's 10/20 flow (delivery/fullscreen_photo_20261020/evidence/td):
  syn: synWildParams {gate pack_effort high gate pack_seq_in_io on}
  phy: phyWildParams {route effort routability place seed N}, then fix_hold, update_timing final,
       area/timing reports, bitgen.
The project file is the GUI .al with every source path made absolute; nothing is written into
src/td_project/<NAME>_Runs (the GUI's own run folders are untouched). TD resolves the sources'
`include "../user_source/..."` from two levels above the run folder, as in the GUI layout, so
the runs are made at
  src/td_project/scale_runs_seed<N>/{syn_1,phy_1}   (paths in the .prj relative, like the GUI)
and logs/reports/area are copied to delivery/image_scale_20261021/evidence/td_hall_seed<N>.
The generated bit stays in the run folder, only for checking.
Usage: python build_hall.py --seed 1 [--td-root D:/TD] [--strategy timing_ultra]
  --strategy timing_ultra adds the EG4 place options effort/opt_timing/hfn_opt_effort = high to
  the teammate's phyWildParams; runs then go to
  scale_runs_seed<N>_tu and evidence/td_hall_seed<N>_tu.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
DELIVERY = TOOLS.parent
LAB = DELIVERY.parents[1]
AL = LAB / 'src/td_project/HDMI1.4b_Transmitter_v1.0.al'
NAME = 'HDMI1.4b_Transmitter_v1.0'
US = LAB / 'src/user_source'


def settings(run, out_dir):
    adc = (US / 'constraints_source/pin.adc').as_posix()
    sdc = (US / 'constraints_source/timing.sdc').as_posix()
    rfifo = (US / 'hdl_source/IP/afifo_32_16_256.tcl').as_posix()
    wfifo = (US / 'hdl_source/IP/afifo_16_32_256.tcl').as_posix()
    common = (f'# This File is Created by Tang Dynasty.\n'
              f'set ADCList {{"{adc}"}}\n'
              f'set IpSDCList {{ rfifo_32_32_512 {rfifo} wfifo_32_32_512 {wfifo} }}\n'
              f'set SDCList {{"{sdc}"}}\n')
    return common


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--td-root', type=Path, default=Path('D:/TD'))
    ap.add_argument('--strategy', choices=['default', 'timing_ultra'], default='default')
    ap.add_argument('--tag', default='ui3', help='run folder src/td_project/<tag>_seed<N>')
    ap.add_argument('--top', type=Path, help='replace top_tf_hdmi_audio.v by this file (experiments)')
    args = ap.parse_args()
    flow = (args.td_root / 'doc/scripts/DefaultFlow.tcl').as_posix()
    tdc = args.td_root / 'bin/td_commands_prompt.exe'
    ref = DELIVERY.parent / 'fullscreen_photo_20261020/evidence/td'
    tag = '' if args.strategy == 'default' else '_tu'
    out = AL.parent / f'{args.tag}_seed{args.seed}{tag}'
    evidence = DELIVERY / 'evidence' / f'td_{args.tag}_seed{args.seed}{tag}'
    # EG4 place parameters (TD prints them in the place log): effort / opt_timing / hfn_opt_effort.
    # The PH1 "TimingUltra" preset is not usable here (its PH1-only options break the EG4 SDRAM pads).
    ultra = 'place effort high place opt_timing high place hfn_opt_effort high'
    text = AL.read_text(encoding='utf-8-sig')

    text = re.sub(r'<File Path="(?![A-Za-z]:|/)', '<File Path="../../', text)
    text = re.sub(r'<Project Version[^>]+>', '<Project Version="3" Minor="2">', text, count=1)
    text = re.sub(r'    <Runs>.*?</Runs>\s*', '', text, flags=re.S)
    text = re.sub(r'    <Project_Settings>.*?</Project_Settings>\s*', '', text, flags=re.S)
    if args.top:
        old = '<File Path="../../../user_source/hdl_source/top_tf_hdmi_audio.v">'
        assert text.count(old) == 1, 'top entry not found'
        text = text.replace(old, '<File Path="' + args.top.resolve().as_posix() + '">')
    missing = [p for p in re.findall(r'<File Path="([^"]+)"', text) if not ((out / 'syn_1') / p).is_file()]
    if missing:
        raise SystemExit('missing sources: ' + ', '.join(missing))
    inputs = {}
    (out / 'syn_1').mkdir(parents=True, exist_ok=True)
    for run in ('syn_1', 'phy_1'):
        d = out / run
        d.mkdir(parents=True, exist_ok=True)
        (d / f'{NAME}.prj').write_text(text, encoding='utf-8')
        cfg = (ref / run / 'settings.cfg').read_text(encoding='utf-8')
        cfg = re.sub(r'^set (ADCList|IpSDCList|SDCList) .*\n', '', cfg, flags=re.M)
        cfg = cfg.replace('# This File is Created by Tang Dynasty.\n', settings(run, d))
        (d / 'settings.cfg').write_text(cfg, encoding='utf-8')
        tcl = (ref / run / 'handoff_build.tcl').read_text(encoding='utf-8')
        tcl = re.sub(r'source \{[^}]*DefaultFlow\.tcl\}', 'source {' + flow + '}', tcl)
        tcl = '\n'.join(l for l in tcl.splitlines()
                        if l.strip() != 'fix_hold' and not l.startswith(('bitgen', 'export_bitgen_param'))) + '\n'
        tcl = re.sub(r'place seed \d+', f'place seed {args.seed}' + (' ' + ultra if tag else ''), tcl)
        (d / 'handoff_build.tcl').write_text(tcl, encoding='utf-8')
    for p in re.findall(r'<File Path="([^"]+)"', text):
        inputs[p] = hashlib.sha256((out / 'syn_1' / p).read_bytes()).hexdigest()
    (out / 'build_inputs.json').write_text(json.dumps({'seed': args.seed, 'al': str(AL), 'sources': inputs},
                                                      indent=1), encoding='utf-8')
    for run in ('syn_1', 'phy_1'):
        d = out / run
        with open(d / 'run.log', 'wb') as log:
            # stdin closed: at the end of the script TD's prompt reads EOF and exits
            rc = subprocess.run([str(tdc), 'handoff_build.tcl'], cwd=d, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, timeout=7200).returncode
        text_log = (d / 'run.log').read_bytes().decode('utf-8', errors='replace')
        errors = [l for l in text_log.splitlines() if 'ERROR' in l]
        print(f'{run}: rc={rc} errors={len(errors)}')
        for l in errors[:8]:
            print('   ', l[:200])
        if errors:
            sys.exit(1)
    import shutil
    for run, names in (('syn_1', ('run.log', 'audit_timing.rpt', f'{NAME}_gate.area')),
                       ('phy_1', ('run.log', 'audit_timing.rpt', 'audit_exceptions.rpt', 'final_timing.rpt',
                                  f'{NAME}_phy.area', 'settings.cfg', 'handoff_build.tcl'))):
        (evidence / run).mkdir(parents=True, exist_ok=True)
        for n in names:
            if (out / run / n).is_file():
                shutil.copy2(out / run / n, evidence / run / n)
    shutil.copy2(out / 'build_inputs.json', evidence / 'build_inputs.json')
    rpt = (out / 'phy_1/audit_timing.rpt').read_text(encoding='utf-8', errors='replace')
    m = re.search(r'Timing Status.*?SWNS: (\S+), STNS: (\S+).*?HWNS: (\S+), HTNS: (\S+)', rpt, re.S)
    print('timing', m.groups() if m else 'not found')
    plog = (out / 'phy_1/run.log').read_text(encoding='utf-8', errors='replace')
    print('hold fixing skipped:', 'hold fixing is skipped' in plog)
    area = (out / f'phy_1/{NAME}_phy.area').read_text(encoding='utf-8', errors='replace')
    for key in ('#lut', '#reg', '#bram9k', '#bram32k', '#dsp', '#slice'):
        mm = re.search(r'^\s*' + re.escape(key) + r'\s+(\d+)\s+out of\s+(\d+)', area, re.M)
        if mm:
            print(key, mm.group(1), '/', mm.group(2))


if __name__ == '__main__':
    main()
