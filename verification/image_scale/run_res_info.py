"""10/26 bmp_res_info regression: the digit cells the hall screen shows for the board-read picture
resolution ("原图 W×H → 显示 w×h", SW4), RTL vs an independent formatter (Python string formatting
of the numbers, ui3_ref.res_cells).

Cases: every width 640..1920 and every height 480..1080 (each at least once, so every double-dabble
digit pattern and the 3-/4-digit packing of both numbers), shown sizes from the scaler's rule
(scaler_ref.fit) plus extremes 100/999, all four picture slots, the RAM read through the second
clock, and a commit that arrives while a conversion is still running (the newer one wins; on
the board loads are seconds apart). Mutants of the RTL must each be caught.
Usage: python run_res_info.py [--output DIR]
"""
import argparse
import random
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
RTL = LAB / 'src/user_source/hdl_source/SD/bmp_res_info.v'
IVL = Path('D:/iverilog/iverilog/bin')
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(LAB / 'verification/ui3'))
import scaler_ref  # noqa: E402
from ui3_ref import res_cells  # noqa: E402

MUTANTS = [
    ('add-3 threshold 4', "d[4*k +: 4] >= 4'd5 ?", "d[4*k +: 4] >= 4'd4 ?"),
    ('10 shifts', "if (n == 4'd10) begin", "if (n == 4'd9) begin"),
    ('height thousands ignored', "hbig = dh[15:12] != 0", "hbig = 1'b0"),
    ('width thousands ignored', "wbig = dw[15:12] != 0", "wbig = 1'b0"),
    ('wrong times glyph', "X = 4'd12", "X = 4'd11"),
    ('shown width/height swapped', "wdata = {dfh[3:0], dfh[7:4], dfh[11:8], dfw[3:0], dfw[7:4], dfw[11:8], src_cells}",
     "wdata = {dfw[3:0], dfw[7:4], dfw[11:8], dfh[3:0], dfh[7:4], dfh[11:8], src_cells}"),
    ('inputs not latched', "dw <= {aw[14:0], bw[10]}; bw <= {bw[9:0], 1'b0};",
     "dw <= {aw[14:0], bw[10]}; bw <= {src_w[9:0], 1'b0};"),
]


def cases():
    rnd = random.Random(26)
    ws, hs = list(range(640, 1921)), list(range(480, 1081))
    rnd.shuffle(hs)
    out = []
    for i, w in enumerate(ws):
        h = hs[i % len(hs)]
        if i % 5 == 0:
            fw, fh = rnd.choice([100, 999, 640, 284]), rnd.choice([100, 999, 480, 160])
        else:
            f = scaler_ref.fit(w, h)
            fw, fh = f['Wo'], f['Ho']
        out.append([i % 4, w, h, fw, fh, 0])          # 1281 widths > 601 heights: every height too
    # back-to-back commits: the first is overridden while converting
    for k in range(8):
        out.insert(97 * k + 5, [k % 4, 1111, 999, 555, 444, 1])
    return out


def expected(cs):
    table = [[0] * 15 for _ in range(4)]
    reads = []
    i = 0
    while i < len(cs):
        c = cs[i]
        if c[5]:
            i += 1
            c = cs[i]
        table[c[0]] = res_cells(c[1], c[2], c[3], c[4])
        reads += [list(t) for t in table]
        i += 1
    return reads


def run(rtl_text, out):
    out.mkdir(parents=True, exist_ok=True)
    (out / 'bmp_res_info.v').write_text(rtl_text, encoding='utf-8')
    subprocess.run([str(IVL / 'iverilog'), '-g2012', '-DBMP_SCALER_BEHAVIORAL_RAM', '-o', str(out / 'tb.vvp'),
                    str(HERE / 'tb_res_info.sv'), str(out / 'bmp_res_info.v')], check=True)
    p = subprocess.run([str(IVL / 'vvp'), '-n', 'tb.vvp'], cwd=out, capture_output=True, text=True)
    if 'PASS RES_INFO_DUMP' not in p.stdout:
        return None
    got = []
    for ln in (out / 'res_out.txt').read_text().split('\n'):
        if ln.startswith('R '):
            v = int(ln.split()[2], 16)
            got.append([(v >> 4 * k) & 15 for k in range(15)])
    return got


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', type=Path, default=LAB / 'delivery/res_demo_20261026/evidence/res_info')
    a = ap.parse_args()
    shutil.rmtree(a.output, ignore_errors=True)
    cs = cases()
    a.output.mkdir(parents=True)
    (a.output / 'res_cases.txt').write_text(''.join(' '.join(map(str, c)) + '\n' for c in cs))
    want = expected(cs)
    src = RTL.read_text(encoding='utf-8')
    base = a.output / 'base'
    base.mkdir()
    shutil.copy2(a.output / 'res_cases.txt', base)
    got = run(src, base)
    widths = {c[1] for c in cs if not c[5]}
    heights = {c[2] for c in cs if not c[5]}
    print(f'{len(cs)} commits, widths 640..1920 covered: {widths >= set(range(640, 1921))}, '
          f'heights 480..1080 covered: {heights >= set(range(480, 1081))}, {len(want)} reads')
    ok = got == want
    if not ok:
        bad = next((i for i in range(min(len(got or []), len(want))) if got[i] != want[i]), None)
        print('FAIL: RTL differs', f'(read {bad}: got {got[bad]} want {want[bad]})' if bad is not None else
              f'(got {None if got is None else len(got)} reads)')
    caught = 0
    for name, old, new in MUTANTS:
        assert src.count(old) == 1, name
        d = a.output / ('mut_' + re.sub(r'\W+', '_', name))
        d.mkdir()
        shutil.copy2(a.output / 'res_cases.txt', d)
        g = run(src.replace(old, new), d)
        hit = g != want
        caught += hit
        print(f'  mutant {name}: {"caught" if hit else "MISSED"}')
    print(f'mutants caught {caught}/{len(MUTANTS)}')
    print('PASS' if ok and caught == len(MUTANTS) else 'FAIL')
    return 0 if ok and caught == len(MUTANTS) else 1


if __name__ == '__main__':
    sys.exit(main())
