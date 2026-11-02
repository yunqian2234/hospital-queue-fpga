"""10/29: synthesize ONE module (default audio_bar_visualizer.v) on its own with TD (syn only, same
synWildParams as the hall) and print its gate area - for comparing cheaper variants quickly.
Run folders: delivery/spectrum_20261029/td_unit/<tag>/syn_1 (nothing in src/ is touched).
Usage: python unit_syn.py RTL.v --tag v1 [--top audio_bar_visualizer]
"""
import argparse
import re
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
TD = Path('D:\TD')
NAME = 'unit'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rtl', type=Path)
    ap.add_argument('--tag', required=True)
    ap.add_argument('--top', default='audio_bar_visualizer')
    a = ap.parse_args()
    d = HERE.parent / 'td_unit' / a.tag / 'syn_1'
    d.mkdir(parents=True, exist_ok=True)
    rtl = a.rtl.resolve().as_posix()
    (d / f'{NAME}.prj').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.168116</TD_Version>
    <Name>{NAME}</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>EG4S20BG256</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
            <File Path="{rtl}">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&amp;R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="1"/>
                </FileInfo>
            </File>
        </Verilog>
    </Source_Files>
    <FileSets>
        <FileSet Name="design_1" Type="DesignFiles">
        </FileSet>
        <FileSet Name="constraint_1" Type="ConstrainFiles">
        </FileSet>
    </FileSets>
    <TOP_MODULE>
        <LABEL>{a.top}</LABEL>
        <MODULE>{a.top}</MODULE>
        <CREATEINDEX>user</CREATEINDEX>
    </TOP_MODULE>
    <Property>
    </Property>
    <Device_Settings>
    </Device_Settings>
    <Configurations>
    </Configurations>
<Project_Settings>
    </Project_Settings>
</Project>
''', encoding='utf-8')
    (d / 'settings.cfg').write_text(f'''# This File is Created by Tang Dynasty.
set area_option -packarea
set device_name eagle_s20.db
set end_step opt_gate
set package_name EG4S20BG256
set prj_name {{{NAME}}}
set run_type syn
set start_step read_design
set top_model_name {{{a.top}}}
''', encoding='utf-8')
    (d / 'build.tcl').write_text('set synWildParams {gate pack_effort high gate pack_seq_in_io on}\n'
                                 'source {' + (TD / 'doc/scripts/DefaultFlow.tcl').as_posix() + '}\n',
                                 encoding='utf-8')
    with open(d / 'run.log', 'wb') as log:
        rc = subprocess.run([str(TD / 'bin/td_commands_prompt.exe'), 'build.tcl'], cwd=d,
                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, timeout=1800).returncode
    text = (d / 'run.log').read_bytes().decode('utf-8', errors='replace')
    errs = [l for l in text.splitlines() if 'ERROR' in l]
    print(f'{a.tag}: rc={rc} errors={len(errs)}')
    for l in errs[:6]:
        print('   ', l[:200])
    area = d / f'{NAME}_gate.area'
    if area.is_file():
        t = area.read_text(encoding='utf-8', errors='replace')
        for key in ('#lut', '#reg', '#le', '#bram', '#dsp'):
            m = re.search(r'^\s*' + re.escape(key) + r'\s+(\d+)', t, re.M)
            if m:
                print(f'  {key} {m.group(1)}')


if __name__ == '__main__':
    main()
