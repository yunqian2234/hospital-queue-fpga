"""10/26 equivalence of the trimmed UART modules (uart_tx, uart_rx, tjc_touch_rx) with the
versions before the trim (delivery/flash_audio_20261026/before/uart, renamed …_old), cycle for
cycle, random stimulus, at the baud ratios used on the boards (touch 25 MHz / 9600 = DIV 2604,
board link 25 MHz / 1 Mbaud = DIV 25) and odd ones. A deliberately wrong trim must be caught.
Usage: python verification/touch_hmi/run_uart_equiv.py
"""
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
NEW = LAB / 'src/user_source/hdl_source/uart'
OLD = LAB / 'delivery/flash_audio_20261026/before/uart'
OUT = LAB / 'delivery/flash_audio_20261026/evidence/uart_equiv'
IVL = Path('D:/iverilog/iverilog/bin')
# (CLK_HZ, BAUD, GAP, CYCLES)
CASES = [(25_000_000, 9600, 1_250_000, 12_000_000), (25_000_000, 1_000_000, 2_000, 3_000_000),
         (1_000_000, 9600, 5_000, 3_000_000), (1_000_000, 115_200, 300, 2_000_000), (3_000, 1000, 40, 400_000)]


def old_sources(d):
    for f in ('uart_tx.v', 'uart_rx.v', 'tjc_touch_rx.v'):
        t = (OLD / f).read_text(encoding='utf-8')
        t = re.sub(r'\bmodule (uart_tx|uart_rx|tjc_touch_rx)\b', r'module \1_old', t)
        t = re.sub(r'\buart_rx #', 'uart_rx_old #', t)
        (d / ('old_' + f)).write_text(t, encoding='utf-8')
    return [d / ('old_' + f) for f in ('uart_tx.v', 'uart_rx.v', 'tjc_touch_rx.v')]


def run(d, new_dir, case, seed):
    clk, baud, gap, cyc = case
    srcs = [HERE / 'tb_uart_equiv.sv'] + [new_dir / f for f in ('uart_tx.v', 'uart_rx.v', 'tjc_touch_rx.v')] + old_sources(d)
    subprocess.run([str(IVL / 'iverilog'), '-g2012', '-o', str(d / 'tb.vvp'), f'-Ptb_uart_equiv.CLK_HZ={clk}',
                    f'-Ptb_uart_equiv.BAUD={baud}', f'-Ptb_uart_equiv.GAP={gap}', f'-Ptb_uart_equiv.CYCLES={cyc}',
                    f'-Ptb_uart_equiv.SEED={seed}'] + [str(s) for s in srcs], check=True)
    p = subprocess.run([str(IVL / 'vvp'), '-n', str(d / 'tb.vvp')], cwd=d, capture_output=True, text=True)
    line = next((l for l in p.stdout.splitlines() if 'uart equivalence' in l), p.stdout[-300:])
    return line


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    ok = True
    for i, case in enumerate(CASES):
        d = OUT / f'case{i}'
        d.mkdir()
        line = run(d, NEW, case, 11 + i)
        print(case[:2], line)
        ok &= line.startswith('PASS') and ' commands=0' not in line
    # the check must catch a wrong trim: shift register taking the wrong bit
    mut = OUT / 'mutant'
    mut.mkdir()
    for f in ('uart_rx.v', 'tjc_touch_rx.v'):
        shutil.copy2(NEW / f, mut / f)
    t = (NEW / 'uart_tx.v').read_text(encoding='utf-8').replace('tx <= shift[1];', 'tx <= shift[2];')
    (mut / 'uart_tx.v').write_text(t, encoding='utf-8')
    line = run(mut, mut, CASES[2], 5)
    caught = line.startswith('FAIL')
    print('mutant (wrong tx bit):', 'caught' if caught else 'MISSED')
    ok &= caught
    print('PASS' if ok else 'FAIL')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
