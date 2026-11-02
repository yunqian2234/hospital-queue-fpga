"""Headless TD check build of the clinic project (10/24 UI v3 copy of clinic_cards_20261023/tools; bit only for checking).

The GUI project file is NOT edited (TD may be open): the .prj is the GUI .al plus the new files,
written into src/td_project_clinic/cards_seed<N>/{syn_1,phy_1} (two levels below the .al, like the
GUI runs, so relative paths and $readmemh resolve the same way). settings.cfg / handoff_build.tcl
are the clinic GUI run's own (hospital_clinic_Runs), only the seed changes. Reports are copied to
delivery/clinic_cards_20261023/evidence/td_clinic_seed<N>.
Usage: python build_clinic.py [--seed 1] [--td-root D:/TD]
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
DELIVERY = TOOLS.parent
LAB = DELIVERY.parents[1]
AL = LAB / 'src/td_project_clinic/hospital_clinic.al'
GUI_RUNS = LAB / 'src/td_project_clinic/hospital_clinic_Runs'
NAME = 'hospital_clinic'
# files the 10/23 change adds to the clinic project (also used by add_clinic_al.py)
NEW_FILES = [
    'clinic/clinic_card_view.v', 'clinic/clinic_card_store.v', 'clinic/clinic_card_loader.v',
    'clinic/clinic_card_scanner.v', 'SD/fat32_file_streamer.v', 'SD/sd_sector_adapter.v',
    'SD/sd_card_top.v', 'SD/sd_card_sec_read_write.v', 'SD/sd_card_cmd.v', 'SD/spi_master.v',
]


def file_entry(rel, order):
    return (f'            <File Path="../user_source/hdl_source/{rel}">\n'
            '                <FileInfo>\n'
            '                    <Attr Name="UsedInSyn" Val="true"/>\n'
            '                    <Attr Name="UsedInP&R" Val="true"/>\n'
            '                    <Attr Name="BelongTo" Val="design_1"/>\n'
            f'                    <Attr Name="CompileOrder" Val="{order}"/>\n'
            '                </FileInfo>\n'
            '            </File>\n')


def with_new_files(text):
    """.al text with NEW_FILES appended to the Verilog list (CompileOrder after the last one)."""
    nl = '\r\n' if '\r\n' in text else '\n'
    t = text.replace('\r\n', '\n')
    present = [f for f in NEW_FILES if f'hdl_source/{f}"' in t]
    if present:
        raise SystemExit('already in the project: ' + ', '.join(present))
    top = max(int(v) for v in re.findall(r'CompileOrder" Val="(\d+)"', t))
    block = ''.join(file_entry(f, top + 1 + i) for i, f in enumerate(NEW_FILES))
    assert t.count('        </Verilog>\n') == 1
    t = t.replace('        </Verilog>\n', block + '        </Verilog>\n')
    return t.replace('\n', nl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--td-root', type=Path, default=Path('D:/TD'))
    args = ap.parse_args()
    tdc = args.td_root / 'bin/td_commands_prompt.exe'
    flow = (args.td_root / 'doc/scripts/DefaultFlow.tcl').as_posix()
    out = AL.parent / f'ui3_seed{args.seed}'
    evidence = DELIVERY / 'evidence' / f'td_clinic_ui3_seed{args.seed}'
    text = AL.read_text(encoding='utf-8-sig')
    if 'clinic_card_view.v' not in text:
        text = with_new_files(text)
    text = re.sub(r'<File Path="(?![A-Za-z]:|/)', '<File Path="../../', text)
    text = re.sub(r'    <Runs>.*?</Runs>\s*', '', text, flags=re.S)
    text = re.sub(r'    <Project_Settings>.*?</Project_Settings>\s*', '', text, flags=re.S)
    for run in ('syn_1', 'phy_1'):
        d = out / run
        d.mkdir(parents=True, exist_ok=True)
        (d / f'{NAME}.prj').write_text(text, encoding='utf-8')
        cfg = (GUI_RUNS / run / 'settings.cfg').read_text(encoding='utf-8')
        (d / 'settings.cfg').write_text(cfg, encoding='utf-8')
        tcl = (GUI_RUNS / run / 'handoff_build.tcl').read_text(encoding='utf-8')
        tcl = re.sub(r'source \{[^}]*DefaultFlow\.tcl\}', 'source {' + flow + '}', tcl)
        tcl = re.sub(r'place seed \d+', f'place seed {args.seed}', tcl)
        (d / 'handoff_build.tcl').write_text(tcl, encoding='utf-8')
    paths = re.findall(r'<File Path="([^"]+)"', text)
    missing = [p for p in paths if not (out / 'syn_1' / p).is_file()]
    if missing:
        raise SystemExit('missing sources: ' + ', '.join(missing))
    inputs = {p: hashlib.sha256((out / 'syn_1' / p).read_bytes()).hexdigest() for p in paths}
    (out / 'build_inputs.json').write_text(json.dumps({'seed': args.seed, 'sources': inputs}, indent=1),
                                           encoding='utf-8')
    for run in ('syn_1', 'phy_1'):
        d = out / run
        with open(d / 'run.log', 'wb') as log:
            rc = subprocess.run([str(tdc), 'handoff_build.tcl'], cwd=d, stdin=subprocess.DEVNULL, stdout=log,
                                stderr=subprocess.STDOUT, timeout=7200).returncode
        lines = (d / 'run.log').read_bytes().decode('utf-8', errors='replace').splitlines()
        errors = [l for l in lines if 'ERROR' in l]
        print(f'{run}: rc={rc} errors={len(errors)}')
        for l in errors[:10]:
            print('   ', l[:220])
        if errors:
            sys.exit(1)
    for run, names in (('syn_1', ('run.log', f'{NAME}_gate.area')),
                       ('phy_1', ('run.log', 'audit_timing.rpt', 'audit_exceptions.rpt', f'{NAME}_phy.area'))):
        (evidence / run).mkdir(parents=True, exist_ok=True)
        for n in names:
            if (out / run / n).is_file():
                shutil.copy2(out / run / n, evidence / run / n)
    shutil.copy2(out / 'build_inputs.json', evidence / 'build_inputs.json')
    rpt = (out / 'phy_1/audit_timing.rpt').read_text(encoding='utf-8', errors='replace')
    m = re.search(r'SWNS: (\S+), STNS: (\S+).*?HWNS: (\S+), HTNS: (\S+)', rpt, re.S)
    print('timing', m.groups() if m else 'not found')
    area = (out / f'phy_1/{NAME}_phy.area').read_text(encoding='utf-8', errors='replace')
    for key in ('#lut', '#reg', '#bram9k', '#bram32k', '#dsp'):
        mm = re.search(r'^\s*' + re.escape(key) + r'\s+(\d+)\s+out of\s+(\d+)', area, re.M)
        if mm:
            print(key, mm.group(1), '/', mm.group(2))


if __name__ == '__main__':
    main()
