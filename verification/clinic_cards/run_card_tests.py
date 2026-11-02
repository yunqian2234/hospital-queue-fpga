"""10/23 clinic card loader regression.

Builds sparse FAT32 card images (../fat32_scale/fat32_image.py) holding CARD1..6.BMP, runs
tb_card_loader.sv (clinic_card_loader + clinic_card_store + SD sector model) and checks the
store against an independent decode of the same files with Pillow:
  pix[c*10800 + y*120 + x] == palette index of pixel (x, y) (y = 0 at the top)
  pal[c*256 + i] == (R, G, B) of palette entry i, for every entry the file defines
and the set of cards reported ready.
Scenarios: all six (fragmented clusters, padded root directory, MBR), bad files, short sector,
hung sector (timeout -> SD re-init -> rescan), card inserted late, bare-VBR volume.
Usage: python run_card_tests.py [--only NAME] [--mutants]
"""
import argparse
import datetime
import hashlib
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[1]
sys.path.insert(0, str(LAB / 'verification/fat32_scale'))
from fat32_image import Fat32Image  # noqa: E402

IVERILOG = r'D:/iverilog/iverilog/bin/iverilog.exe'
VVP = r'D:/iverilog/iverilog/bin/vvp.exe'
HDL = LAB / 'src/user_source/hdl_source'
RTL = [HDL / 'clinic/clinic_card_loader.v', HDL / 'clinic/clinic_card_scanner.v', HDL / 'clinic/clinic_card_store.v',
       HDL / 'SD/fat32_file_streamer.v', HDL / 'SD/sd_sector_adapter.v']
BENCH = HERE / 'tb_card_loader.sv'
CARDS = LAB / 'delivery/clinic_cards_20261023/tf_card_clinic'
EVID = LAB / 'delivery/clinic_cards_20261023/evidence'


def demo(n):
    return (CARDS / f'CARD{n}.BMP').read_bytes()


def bmp8(img_p, colours=None):
    """8-bit BMP from a P-mode image; colours = number of palette entries written (clr_used)."""
    w, h = img_p.size
    pal = img_p.getpalette()[:768]
    pal += [0] * (768 - len(pal))
    used = colours or 256
    stride = (w + 3) & ~3
    pix = img_p.tobytes()
    rows = b''.join(pix[y * w:(y + 1) * w] + bytes(stride - w) for y in range(h - 1, -1, -1))
    off = 14 + 40 + used * 4
    head = struct.pack('<2sIHHI', b'BM', off + len(rows), 0, 0, off)
    info = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 8, 0, len(rows), 2835, 2835, 0 if used == 256 else used, 0)
    table = b''.join(bytes((pal[i * 3 + 2], pal[i * 3 + 1], pal[i * 3], 0)) for i in range(used))
    return head + info + table + rows


def v5_header(n):
    """Same picture with a 124-byte BITMAPV5HEADER (as GIMP writes): palette starts at offset 138."""
    d = demo(n)
    info = bytearray(d[14:54])
    struct.pack_into('<I', info, 0, 124)
    v5 = bytes(info) + bytes(124 - 40)
    rest = d[54:]
    off = 14 + 124 + 1024
    return struct.pack('<2sIHHI', b'BM', off + len(rest) - 1024, 0, 0, off) + v5 + rest


def bpp_field_4(n):
    """An 8-bit layout whose header claims 4 bits per pixel (must be rejected)."""
    d = bytearray(demo(n))
    struct.pack_into('<H', d, 28, 4)
    return bytes(d)


def sixteen_colour(n):
    im = Image.open(io.BytesIO(demo(n))).convert('RGB').quantize(colors=16, dither=Image.Dither.NONE)
    return bmp8(im, 16)


def bmp24(n):
    buf = io.BytesIO()
    Image.open(io.BytesIO(demo(n))).convert('RGB').save(buf, 'BMP')
    return buf.getvalue()


def wrong_size(n):
    im = Image.open(io.BytesIO(demo(n))).convert('RGB').resize((160, 120)).quantize(colors=256)
    return bmp8(im)


def decode(data):
    """Independent decode (Pillow): palette entries defined by the file, index per pixel, top row first."""
    im = Image.open(io.BytesIO(data))
    assert im.mode == 'P' and im.size == (120, 90), (im.mode, im.size)
    clr_used = struct.unpack_from('<I', data, 46)[0] or 256
    pal = im.getpalette()[:clr_used * 3]
    return list(im.tobytes()), [(pal[i * 3] << 16) | (pal[i * 3 + 1] << 8) | pal[i * 3 + 2] for i in range(clr_used)]


def scenarios():
    six = [(f'CARD{n}.BMP', demo(n)) for n in range(1, 7)]
    out = []
    out.append(dict(name='all_six_fragmented', files=six, image=dict(fragment=True, dir_padding=40, seed=3),
                    ready=0b111111))
    bad = [('CARD1.BMP', demo(1)), ('CARD2.BMP', sixteen_colour(2)), ('CARD4.BMP', demo(4)),
           ('CARD5.BMP', bmp24(5)), ('CARD6.BMP', wrong_size(6)), ('PIC1.BMP', demo(3))]
    out.append(dict(name='missing_and_rejected', files=bad, image=dict(fragment=True, seed=5), ready=0b001011))
    out.append(dict(name='short_sector_card4', files=six, image=dict(seed=7), ready=0b110111,
                    bad_sector=('CARD4.BMP', 3)))
    out.append(dict(name='hung_sector_then_recover', files=six, image=dict(fragment=True, seed=9), ready=0b111111,
                    hang_sector=('CARD3.BMP', 5), min_resets=1))
    out.append(dict(name='card_inserted_late', files=six, image=dict(seed=11), ready=0b111111,
                    present_at=700_000, min_resets=2))
    out.append(dict(name='bare_vbr_volume', files=six, image=dict(partitioned=False, seed=13), ready=0b111111))
    hdr = [('CARD1.BMP', demo(1)), ('CARD2.BMP', bpp_field_4(2)), ('CARD3.BMP', v5_header(3)),
           ('CARD4.BMP', demo(4)), ('CARD5.BMP', demo(5)), ('CARD6.BMP', demo(6))]
    out.append(dict(name='v5_header_and_bad_bpp', files=hdr, image=dict(seed=15), ready=0b111101))
    out.append(dict(name='transient_error_recovers', files=six, image=dict(fragment=True, seed=17), ready=0b111111,
                    bad_sector=('CARD2.BMP', 2), bad_once=True, hang_sector=('CARD5.BMP', 4), min_resets=1))
    return out


def sector_of(img, files, name, k):
    i = [n for n, _ in files].index(name)
    chain = img.chains[i]
    return img.cluster_lba(chain[k // img.spc]) + k % img.spc


def run_one(sc, out_dir, rtl):
    out_dir.mkdir(parents=True, exist_ok=True)
    img = Fat32Image(sc['files'], **sc['image'])
    nsec = img.write_hex(out_dir)
    args = [f'+SECTORS={nsec}']
    if 'bad_sector' in sc:
        args.append(f'+BAD_LBA={sector_of(img, sc["files"], *sc["bad_sector"]):x}')
    if 'hang_sector' in sc:
        args.append(f'+HANG_LBA={sector_of(img, sc["files"], *sc["hang_sector"]):x}')
    if sc.get('bad_once'):
        args.append('+BAD_ONCE')
    if 'present_at' in sc:
        args.append(f'+PRESENT_AT={sc["present_at"]}')
    subprocess.run([IVERILOG, '-g2012', '-DCLINIC_CARD_BEHAVIORAL_RAM', '-s', 'tb', '-o', 'tb.vvp', str(BENCH)]
                   + [str(p) for p in rtl], cwd=out_dir, check=True, capture_output=True)
    proc = subprocess.run([VVP, '-n', 'tb.vvp'] + args, cwd=out_dir, capture_output=True, text=True, timeout=3600)
    (out_dir / 'run.log').write_text(proc.stdout + proc.stderr, encoding='utf-8')
    if 'PASS CARD_LOADER' not in proc.stdout:
        return [f'bench failed: {proc.stdout[-600:]}']
    ready, reads, resets, cycles = map(int, (out_dir / 'ready.txt').read_text().split())
    errors = []
    if ready != sc['ready']:
        errors.append(f'ready {ready:06b}, expected {sc["ready"]:06b}')
    if resets < sc.get('min_resets', 0):
        errors.append(f'{resets} SD resets, expected at least {sc["min_resets"]}')
    def memh(name):
        # $writememh adds '// 0x...' address comments
        return [w for line in (out_dir / name).read_text().splitlines()
                for w in line.split('//')[0].split()]
    pix = memh('pix.hex')
    pal = memh('pal.hex')
    if len(pix) != 65536 or len(pal) != 2048:
        return [f'store dump sizes {len(pix)} / {len(pal)}']
    by_name = dict(sc['files'])
    for c in range(6):
        if not (sc['ready'] >> c) & 1:
            continue
        want_pix, want_pal = decode(by_name[f'CARD{c + 1}.BMP'])
        got_pix = pix[c * 10800:(c + 1) * 10800]
        bad = [i for i in range(10800) if got_pix[i] in ('x', 'xx') or int(got_pix[i], 16) != want_pix[i]]
        if bad:
            i = bad[0]
            errors.append(f'card {c + 1}: {len(bad)} pixel indices differ, first x={i % 120} y={i // 120} '
                          f'got {got_pix[i]} want {want_pix[i]:02x}')
        got_pal = pal[c * 256:c * 256 + len(want_pal)]
        badp = [i for i in range(len(want_pal)) if 'x' in got_pal[i] or int(got_pal[i], 16) != want_pal[i]]
        if badp:
            i = badp[0]
            errors.append(f'card {c + 1}: {len(badp)} palette entries differ, first {i}: got {got_pal[i]} want {want_pal[i]:06x}')
    for f in ('pix.hex', 'pal.hex', 'sd_data.hex', 'tb.vvp'):
        (out_dir / f).unlink(missing_ok=True)
    print(f'  {sc["name"]}: ready={ready:06b} reads={reads} resets={resets} cycles={cycles}',
          'PASS' if not errors else 'FAIL')
    for e in errors:
        print('    ', e)
    return errors


# Deliberate RTL faults that the scenarios must detect.
MUTANTS = [
    ('row_order_top_down', 'clinic/clinic_card_loader.v',
     "row_addr <= card * PIXELS + (CH - 1) * CW;", "row_addr <= card * PIXELS;"),
    ('palette_red_blue_swapped', 'clinic/clinic_card_loader.v',
     "pal_wdata <= {byte_data, green, blue};", "pal_wdata <= {blue, green, byte_data};"),
    ('no_bpp_check', 'clinic/clinic_card_loader.v', "planes == 1 && bpp == 8 &&", "planes == 1 &&"),
    ('no_size_check', 'clinic/clinic_card_loader.v', "width == CW && height == CH &&", ""),
    ('palette_start_fixed_54', 'clinic/clinic_card_loader.v',
     "pal_start <= 17'd14 + dib_size[16:0];", "pal_start <= 17'd54;"),
    ('scanner_slot_off_by_one', 'clinic/clinic_card_scanner.v',
     "name_slot<=sector_data_q[2:0]-3'd1;", "name_slot<=sector_data_q[2:0];"),
    ('ready_without_full_frame', 'clinic/clinic_card_loader.v',
     "ok <= stream_done && header_ok && pix_count == PIXELS;", "ok <= header_ok;"),
    ('no_retry_after_reset', 'clinic/clinic_card_loader.v',
     "S_SCAN: begin status <= 1; attempted <= 0;", "S_SCAN: begin status <= 1;"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--only')
    ap.add_argument('--mutants', action='store_true')
    args = ap.parse_args()
    started = datetime.datetime.now()
    out = EVID / ('card_loader' if not args.mutants else 'card_loader_mutants')
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    summary = {'started': started.isoformat(), 'sources': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                                                           for p in RTL + [BENCH, Path(__file__)]}}
    scs = [s for s in scenarios() if not args.only or s['name'] == args.only]
    if not args.mutants:
        failed = 0
        for sc in scs:
            failed += bool(run_one(sc, out / sc['name'], RTL))
        summary['passed'] = failed == 0
        summary['scenarios'] = [s['name'] for s in scs]
    else:
        results = {}
        for name, rel, old, new in MUTANTS:
            src = (HDL / rel).read_text(encoding='utf-8')
            assert src.count(old) == 1, (name, old)
            mdir = out / name
            mdir.mkdir()
            mut = mdir / Path(rel).name
            mut.write_text(src.replace(old, new), encoding='utf-8')
            rtl = [mut if p == HDL / rel else p for p in RTL]
            print('mutant', name)
            detected = False
            for sc in scs:
                if run_one(sc, mdir / sc['name'], rtl):
                    detected = True
                    break
            results[name] = detected
            print('  ->', 'DETECTED' if detected else 'SURVIVED')
        summary['mutants'] = results
        summary['passed'] = all(results.values())
    summary['finished'] = datetime.datetime.now().isoformat()
    (out / 'summary.json').write_text(json.dumps(summary, indent=1, ensure_ascii=False), encoding='utf-8')
    print('PASS' if summary['passed'] else 'FAIL', out)
    sys.exit(0 if summary['passed'] else 1)


if __name__ == '__main__':
    main()
