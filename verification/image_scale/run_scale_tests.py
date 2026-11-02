"""扩展要求3 BMP scaler regression (bmp_scaler.v) against the specification model scaler_ref.py.

  * 15 source resolutions from 640x480 (must come out bit-identical) to 1920x1080, odd sizes,
    very wide / narrow / square images; every one of the 640x480 output pixels is compared.
  * one run where a first load is aborted part-way and the image is then loaded again.
  * mutants of the RTL (no area pre-filter, wrong weight, wrong edge tap, wrong 1/9, off-centre
    letterbox, no first-row guard, wrong RAM field) must each be caught.
  * --quality: PNG comparison for the defence: nearest neighbour / plain bilinear / area + bilinear
    (this design) on a 1920x1080 zone plate and photo-like test card, with PSNR against a Lanczos
    reference (PIL).
Simulation: Icarus, BMP_SCALER_BEHAVIORAL_RAM for the line buffer (TD's BRAM model is encrypted).
No TD, no bit file, no hardware.
"""
import argparse
import concurrent.futures as cf
import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
RTL = LAB / 'src/user_source/hdl_source/SD/bmp_scaler.v'
BENCH = HERE / 'tb_bmp_scaler.sv'
IVERILOG = Path('D:/iverilog/iverilog/bin/iverilog.exe')
VVP = Path('D:/iverilog/iverilog/bin/vvp.exe')
sys.path.insert(0, str(HERE))
import scaler_ref as ref  # noqa: E402

CASES = [(640, 480), (800, 600), (1024, 768), (1280, 720), (1920, 1080), (1280, 1024),
         (720, 480), (640, 1080), (1080, 1080), (1919, 1079), (641, 481), (1440, 1080),
         (1366, 768), (1920, 480), (1600, 1080), (641, 1080)]
ABORT_CASE = (1024, 768)

MUTATIONS = [
    ('no_area_prefilter', "kk <= w >= 3 * OUT_W ? 2'd3 : w >= 2 * OUT_W ? 2'd2 : 2'd1;", "kk <= 2'd1;"),
    ('weight_never_one', "wire [8:0] t_x = xi[15:0] == 0 ? 9'd256 : {1'b0, xi[15:8]};",
     "wire [8:0] t_x = {1'b0, xi[15:8]};"),
    ('first_column_tap', "ah[q] <= f_j0 ? (hc == 0 ? 10'd0 : hsum[q]) + {2'b00, ib_rgb[q*8 +: 8]} : bprev[q];",
     "ah[q] <= bprev[q];"),
    ('channel_order', "dp_pix <= {v_lerp[15:8], out_lo};", "dp_pix <= {out_lo, v_lerp[15:8]};"),
    ('line_buffer_shared_by_channels', "wire [AW+1:0] line_addr = {chs, xo_l};", "wire [AW+1:0] line_addr = {2'b00, xo_l};"),
    # 7281 would be an equivalent mutant: over the reachable range asum = 0..2295 it rounds exactly like
    # 7282 (both give round(asum/9)), so a clearly wrong constant is used instead.
    ('ninth_constant', "nmul <= asum * 13'd7282;", "nmul <= asum * 13'd7000;"),
    ('letterbox_off_centre', "x0 <= (OUT_W - wo) >> 1;", "x0 <= (OUT_W - wo + 1) >> 1;"),
    ('first_row_guard', "wire [7:0] pv = i0_l ? c8 : prev_old;", "wire [7:0] pv = prev_old;"),
    ('accumulate_not_reset', "asum <= (first_l ? 12'd0 : acc_old) + {2'b00, hval};",
     "asum <= acc_old + {2'b00, hval};"),
    ('step_not_rounded_down', "sx <= dv_q[16:0];", "sx <= dv_q[16:0] + 1'b1;"),
]
# 641x1080 -> 285x480 leaves an odd 355-pixel margin, so the centring rounding is observable.
MUTATION_CASES = [(1920, 1080), (1024, 768), (640, 1080), (641, 1080)]


def test_image(W, H, seed):
    """Gradients, fine stripes/checks (aliasing-sensitive) and a noise block, BMP row order."""
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:H, 0:W]
    img = np.zeros((H, W, 3), dtype=np.int64)
    img[..., 0] = (x * 255) // max(W - 1, 1)
    img[..., 1] = (y * 255) // max(H - 1, 1)
    img[..., 2] = ((x // 3 + y // 3) % 2) * 255
    band = (y > H // 3) & (y < H // 2)
    img[band, 0] = ((x[band] % 4) < 2) * 255
    blk = (x > 2 * W // 3) & (y > 2 * H // 3)
    img[blk] = rng.integers(0, 256, size=(int(blk.sum()), 3))
    img[0, :] = [255, 0, 0]
    img[:, 0] = [0, 255, 0]
    img[-1, :] = [0, 0, 255]
    img[:, -1] = [255, 255, 0]
    return img.astype(np.uint8)


def write_case(work, src, W, H):
    work.mkdir(parents=True, exist_ok=True)
    (work / 'meta.hex').write_text(f'{W:08x}\n{H:08x}\n', encoding='ascii')
    words = ref.pack(src)
    (work / 'src.hex').write_text('\n'.join(f'{v:06x}' for v in words) + '\n', encoding='ascii')


def compile_bench(out_dir, rtl, defines=()):
    exe = out_dir / 'sim.vvp'
    cmd = [str(IVERILOG), '-g2012', '-DBMP_SCALER_BEHAVIORAL_RAM', *[f'-D{d}' for d in defines],
           '-s', 'tb', '-o', str(exe), str(BENCH), str(rtl)]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=600)
    log = p.stdout.decode(errors='replace')
    if p.returncode:
        raise RuntimeError('compile failed:\n' + log)
    return exe


def run_case(exe, work, W, H, seed):
    p = subprocess.run([str(VVP), str(exe), f'+SEED={seed}'], cwd=work, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=3600)
    log = p.stdout.decode(errors='replace')
    (work / 'run.log').write_text(log, encoding='utf-8')
    if p.returncode or 'PASS SCALER' not in log:
        return False, log.strip().splitlines()[-3:] if log.strip() else ['no output']
    raw = (work / 'out.hex').read_text().split()
    unknown = sum(1 for v in raw if not all(c in '0123456789abcdefABCDEF' for c in v))
    if unknown:
        return False, [f'{unknown} output pixels contain X/Z']
    words = [int(v, 16) for v in raw]
    got = ref.unpack(words, 480, 640)
    src = ref.unpack([int(v, 16) for v in (work / 'src.hex').read_text().split()], H, W)
    want, info = ref.scale(src, W, H)
    fitline = re.search(r'FIT (\d+) (\d+) (\d+)', log)
    pct = (info['Wo'] * 100 + W // 2) // W
    if not fitline or tuple(map(int, fitline.groups())) != (info['Wo'], info['Ho'], info['k']):
        return False, [f'fit {fitline.groups()} != model {info}']
    bad = np.argwhere(np.any(got != want, axis=-1))
    if len(bad):
        y, x = bad[0]
        return False, [f'{len(bad)} pixels differ, first (x={x}, row={y}) got {got[y, x]} want {want[y, x]}']
    if (W, H) == (640, 480) and not np.array_equal(got, src):
        return False, ['640x480 is not passed through unchanged']
    (work / 'src.hex').unlink()
    (work / 'out.hex').unlink()
    return True, [f"{W}x{H} -> {info['Wo']}x{info['Ho']} (k={info['k']}, {pct}%, offset {info['x0']},{info['y0']})"]


def suite(exe, out_dir, cases, tag, jobs):
    results = {}
    with cf.ThreadPoolExecutor(jobs) as pool:
        futs = {}
        for n, (W, H) in enumerate(cases):
            work = out_dir / f'{tag}_{W}x{H}'
            write_case(work, test_image(W, H, 100 + n), W, H)
            futs[pool.submit(run_case, exe, work, W, H, 7 + n)] = (W, H)
        for f in cf.as_completed(futs):
            results[futs[f]] = f.result()
    return results


def quality(out_dir):
    from PIL import Image
    W, H = 1920, 1080
    y, x = np.mgrid[0:H, 0:W].astype(np.float64)
    r2 = ((x - W / 2) ** 2 + (y - H / 2) ** 2)
    zone = (127.5 + 127.5 * np.cos(np.pi * r2 / (W * 1.1))).astype(np.uint8)   # zone plate
    card = test_image(W, H, 5)
    report = {}
    for name, img in (('zone_plate', np.repeat(zone[..., None], 3, axis=2)), ('test_card', card)):
        ours, info = ref.scale(img, W, H)
        y0, x0, Wo, Ho = info['y0'], info['x0'], info['Wo'], info['Ho']
        ours = ours[y0:y0 + Ho, x0:x0 + Wo]
        pil = Image.fromarray(img[::-1, :, ::-1])                            # to top-down RGB
        lanczos = np.asarray(pil.resize((Wo, Ho), Image.LANCZOS)).astype(np.float64)
        variants = {
            'nearest': np.asarray(pil.resize((Wo, Ho), Image.NEAREST)),
            'bilinear_2tap': _plain_bilinear(img, Wo, Ho)[::-1, :, ::-1],
            'area_plus_bilinear_FPGA': ours[::-1, :, ::-1],
        }
        report[name] = {}
        tiles = []
        for vname, v in variants.items():
            mse = np.mean((v.astype(np.float64) - lanczos) ** 2)
            report[name][vname] = round(10 * np.log10(255 ** 2 / mse), 2) if mse else 99.0
            Image.fromarray(v.astype(np.uint8)).save(out_dir / f'quality_{name}_{vname}.png')
            tiles.append(v.astype(np.uint8)[Ho // 4:Ho // 4 + 160, Wo // 4:Wo // 4 + 200])
        Image.fromarray(np.concatenate(tiles, axis=1)).resize((1200, 320), Image.NEAREST).save(
            out_dir / f'quality_{name}_crop_x2.png')
    return report


def _plain_bilinear(img, Wo, Ho):
    """Textbook two-tap bilinear straight from the source (no pre-filter), same centre alignment."""
    H, W = img.shape[:2]
    xs = (np.arange(Wo) + 0.5) * W / Wo - 0.5
    ys = (np.arange(Ho) + 0.5) * H / Ho - 0.5
    x0 = np.clip(np.floor(xs).astype(int), 0, W - 2); fx = np.clip(xs - x0, 0, 1)
    y0 = np.clip(np.floor(ys).astype(int), 0, H - 2); fy = np.clip(ys - y0, 0, 1)
    a = img.astype(np.float64)
    top = a[y0][:, x0] * (1 - fx)[None, :, None] + a[y0][:, x0 + 1] * fx[None, :, None]
    bot = a[y0 + 1][:, x0] * (1 - fx)[None, :, None] + a[y0 + 1][:, x0 + 1] * fx[None, :, None]
    return np.round(top * (1 - fy)[:, None, None] + bot * fy[:, None, None]).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--mutation-check', action='store_true')
    ap.add_argument('--quality', action='store_true')
    ap.add_argument('--mutations-only', action='store_true', help='skip the normal cases')
    ap.add_argument('--mutants', help='comma-separated subset of mutant names (default: all)')
    ap.add_argument('--jobs', type=int, default=4)
    args = ap.parse_args()
    out = args.output.resolve()
    if out.exists() and any(out.iterdir()):
        raise SystemExit('output must be new or empty: ' + str(out))
    out.mkdir(parents=True, exist_ok=True)
    summary = {'started': datetime.datetime.now().astimezone().isoformat(),
               'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in (RTL, BENCH, HERE / 'scaler_ref.py', Path(__file__))},
               'cases': {}, 'mutations': {}}
    ok_all = True
    exe = compile_bench(out, RTL)
    for (W, H), (ok, msg) in sorted(suite(exe, out, [] if args.mutations_only else CASES, 'case', args.jobs).items()):
        summary['cases'][f'{W}x{H}'] = {'passed': ok, 'detail': msg}
        print('PASS' if ok else 'FAIL', f'{W}x{H}', '|', ' '.join(msg))
        ok_all &= ok
    abort_dir = out / 'abort'
    abort_dir.mkdir()
    if args.mutations_only:
        ABORT = None
    else:
        ABORT = ABORT_CASE
    if ABORT:
        exe_ab = compile_bench(abort_dir, RTL, ['ABORT_FIRST'])
        work = abort_dir / f'{ABORT_CASE[0]}x{ABORT_CASE[1]}'
        write_case(work, test_image(*ABORT_CASE, 55), *ABORT_CASE)
        ok, msg = run_case(exe_ab, work, *ABORT_CASE, 3)
        summary['cases']['abort_then_reload'] = {'passed': ok, 'detail': msg}
        print('PASS' if ok else 'FAIL', 'abort then reload', '|', ' '.join(msg))
        ok_all &= ok
    if args.mutation_check:
        text = RTL.read_bytes().decode('utf-8').replace('\r\n', '\n')
        chosen = set(args.mutants.split(',')) if args.mutants else None
        if chosen and chosen - {m[0] for m in MUTATIONS}:
            raise SystemExit('unknown mutants: ' + ', '.join(sorted(chosen - {m[0] for m in MUTATIONS})))
        for name, before, after in MUTATIONS:
            if chosen and name not in chosen:
                continue
            if text.count(before) != 1:
                raise SystemExit('mutation anchor drift: ' + name)
            mdir = out / ('mut_' + name)
            mdir.mkdir()
            mrtl = mdir / 'bmp_scaler.v'
            mrtl.write_text(text.replace(before, after), encoding='utf-8')
            mexe = compile_bench(mdir, mrtl)
            res = suite(mexe, mdir, MUTATION_CASES, 'm', args.jobs)
            caught = [f'{w}x{h}: {" ".join(m)}' for (w, h), (ok, m) in res.items() if not ok]
            summary['mutations'][name] = {'detected': bool(caught), 'by': caught}
            print('PASS MUTATION_DETECTED' if caught else 'FAIL MUTANT SURVIVED', name,
                  '|', caught[0][:150] if caught else '')
            ok_all &= bool(caught)
            shutil.rmtree(mdir / 'm_1920x1080', ignore_errors=True)
    if args.quality:
        summary['quality_psnr_vs_lanczos_db'] = quality(out)
        print('quality (PSNR vs Lanczos, dB):', json.dumps(summary['quality_psnr_vs_lanczos_db']))
    summary['passed'] = ok_all
    summary['finished'] = datetime.datetime.now().astimezone().isoformat()
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print('Evidence:', out / 'summary.json')
    sys.exit(0 if ok_all else 1)


if __name__ == '__main__':
    main()
