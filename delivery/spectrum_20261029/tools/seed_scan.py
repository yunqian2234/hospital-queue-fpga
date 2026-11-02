"""10/29: run build_hall.py for several seeds (2 at a time) and print one summary line per seed.
Usage: python seed_scan.py --tag sp3 --seeds 1 2 3 [--top FILE] [--jobs 2]
"""
import argparse
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
BUILD = LAB / 'delivery/ui_redesign_20261024/tools/build_hall.py'
OUT = HERE.parent / 'exp'


def one(tag, seed, top):
    cmd = [sys.executable, str(BUILD), '--seed', str(seed), '--tag', tag] + (['--top', str(top)] if top else [])
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=7000)
    log = p.stdout + p.stderr
    (OUT / f'{tag}_s{seed}.txt').write_text(log, encoding='utf-8')
    run = LAB / f'src/td_project/{tag}_seed{seed}/phy_1'
    q = (run / 'route.qor').read_text(errors='replace') if (run / 'route.qor').is_file() else ''
    m = re.search(r'slices percentage\s*\|\s*(\S+)', q)
    t = re.search(r"timing \((.*?)\)", log)
    h = re.search(r'hold fixing skipped: (\S+)', log)
    return f"{tag} seed {seed}: slices {m.group(1) if m else '?'}  timing {t.group(1) if t else 'FAILED'}  " \
           f"hold-fix skipped {h.group(1) if h else '?'}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tag', required=True)
    ap.add_argument('--seeds', type=int, nargs='+', required=True)
    ap.add_argument('--top', type=Path)
    ap.add_argument('--jobs', type=int, default=2)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(a.jobs) as ex:
        for line in ex.map(lambda s: one(a.tag, s, a.top), a.seeds):
            print(line, flush=True)


if __name__ == '__main__':
    main()
