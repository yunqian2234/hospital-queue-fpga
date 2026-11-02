"""FAT32 media regression: scan, BMP loads, AUDIO.PCM stream and VOICE.PCM clips.

20261021 copy (扩展要求3): runs the 20261021 tree's reader WITH bmp_scaler. The original
scenarios use 16x8 pictures and an OUT_W x OUT_H = 16 x 8 reader, where the scaler must pass
pixels through unchanged, so their expectations are the original ones. Added scenarios:
pictures 2x / 3x / non-integer larger than the output and other aspect ratios (expected
pixels from verification/image_scale/scaler_ref.py), pictures rejected by the size limits
(code 1), and one load at the real 640x480 output size from an 800x600 file.

Builds sparse FAT32 card images in Python, simulates the production fat32_bmp_reader
(with the new clip reader) against an SD sector model, and checks every pixel, audio
byte and clip byte from the trace against the image contents. No TD/bit/hardware/card.
"""
import argparse
from array import array
import datetime
import hashlib
import json
from pathlib import Path
import random
import struct
import subprocess
import sys

import shutil

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / 'image_scale'))
from fat32_image import Fat32Image, SECTOR  # noqa: E402
import voice_bank  # noqa: E402
import scaler_ref  # noqa: E402
import numpy as np  # noqa: E402

LAB = HERE.parents[1]
ROOT = LAB
SD = LAB / 'src/user_source/hdl_source/SD'
RTL = [SD / n for n in ('fat32_bmp_reader.v', 'fat32_volume_scanner.v', 'fat32_file_streamer.v',
                        'fat32_clip_reader.v', 'sd_sector_adapter.v', 'bmp_stream_decode.v', 'bmp_scaler.v')]
BENCH = HERE / 'tb_fat32_media.sv'
REAL_VOICE = LAB / 'assets/tf_card/VOICE.PCM'
W, H = 16, 8          # original pictures; also the reader's output size in most scenarios
OUT = (16, 8)


def tool_path(name, supplied):
    path = supplied or shutil.which(name)
    if not path:
        candidate = Path('D:/iverilog/iverilog/bin') / (name + '.exe')
        if candidate.is_file():
            path = str(candidate)
    if not path:
        raise RuntimeError(f'{name} not found; pass --{name} with its executable path')
    return path
assert sys.byteorder == 'little'


def bmp(seed, w=W, h=H, out=OUT):
    """A w x h 24-bit BMP (rows padded to 4 bytes) and the pixels the reader must deliver for an
    out[0] x out[1] display: the specification model of the scaler (identity when w x h == out)."""
    rng = random.Random(seed)
    stride = (w * 3 + 3) & ~3
    rows = [bytes(rng.randrange(256) for _ in range(w * 3)) + bytes(stride - w * 3) for _ in range(h)]
    pixels = b''.join(rows)
    header = b'BM' + struct.pack('<IHHI', 54 + len(pixels), 0, 0, 54)
    dib = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
    data = header + dib + pixels
    src = np.frombuffer(b''.join(r[:w * 3] for r in rows), dtype=np.uint8).reshape(h, w, 3)
    if (w, h) == tuple(out):
        img = src
    elif w < out[0] or h < out[1]:
        return data, None                        # rejected by the size check
    else:
        img, _ = scaler_ref.scale(src, w, h, out[0], out[1])
    expect = [int(v) for v in scaler_ref.pack(img)]
    return data, expect


def synthetic_bank(seed, empty=(7, 13), longest=900):
    rng = random.Random(seed)
    clips = {}
    for i in range(voice_bank.SLOTS):
        if i in empty:
            continue
        clips[i] = array('h', (rng.randrange(-32768, 32768) for _ in range(rng.randrange(1, longest))))
    return voice_bank.pack(clips), clips


def clip_bytes(clip):
    return array('h', clip).tobytes()  # s16le; the runner asserts a little-endian host


def media_files(seed, voice_blob=None, audio_len=3000, sizes=None, out=OUT):
    rng = random.Random(seed)
    files, pics = [], []
    for i in range(4):
        data, expect = bmp(seed * 10 + i, *(sizes[i] if sizes else (W, H)), out=out)
        files.append((f'PIC{i + 1}.BMP', data))
        pics.append(expect)
    audio = bytes(rng.randrange(256) for _ in range(audio_len))
    files.append(('AUDIO.PCM', audio))
    if voice_blob is not None:
        files.append(('VOICE.PCM', voice_blob))
    rng.shuffle(files)
    return files, pics, audio


def scenarios():
    """Each scenario: image, VOICE param, commands, and an expectation dict."""
    out = []
    # A: voice disabled, behaviour of the original reader (images + background audio).
    blob, clips = synthetic_bank(1)
    files, pics, audio = media_files(1, blob)
    img = Fat32Image(files, spc=8)
    cmds = [(1, 0, 0), (3, 0, 0)] + [(2, i, 0) for i in range(4)] + [(8, 0, 0)]
    out.append((OUT, 'baseline_voice_off', img, 0, cmds, dict(mask=15, voice=0, pics=pics, audio=audio, clips={})))
    # B: spc=1, fragmented, files pushed into later root clusters; every slot; concurrency.
    blob, clips = synthetic_bank(2)
    files, pics, audio = media_files(2, blob)
    img = Fat32Image(files, spc=1, fragment=True, dir_padding=40, seed=2)
    cmds = [(1, 0, 0), (3, 0, 0)] + [(4, i, 0) for i in range(32)] + \
           [(5, 31 - i, i) for i in range(4)] + [(8, 0, 0)]
    out.append((OUT, 'voice_spc1_fragmented', img, 1, cmds, dict(mask=15, voice=1, pics=pics, audio=audio, clips=clips)))
    # C: bare VBR at LBA0, 64 sectors per cluster, fragmented.
    blob, clips = synthetic_bank(3, empty=(0,))
    files, pics, audio = media_files(3, blob, audio_len=70000)
    img = Fat32Image(files, spc=64, partitioned=False, fragment=True, seed=3)
    cmds = [(1, 0, 0), (3, 0, 0), (5, 5, 0), (5, 31, 1)] + [(4, i, 0) for i in range(32)] + \
           [(2, 2, 0), (2, 3, 0), (8, 0, 0)]
    out.append((OUT, 'voice_spc64_vbr', img, 1, cmds, dict(mask=15, voice=1, pics=pics, audio=audio, clips=clips)))
    # C2: spc=8, fragmented, long clips so the bank spans ~50 clusters: every clip after
    #     the first cluster needs FAT hops plus a mid-cluster start sector.
    blob, clips = synthetic_bank(9, empty=(), longest=6000)
    files, pics, audio = media_files(9, blob)
    img = Fat32Image(files, spc=8, fragment=True, seed=9, gap_max=40)   # chain spans several FAT sectors
    voice_chain = img.chains[[n for n, _ in files].index('VOICE.PCM')]
    if len({c // 128 for c in voice_chain}) < 3:
        raise AssertionError('seek scenario must cross FAT sectors')
    cmds = [(1, 0, 0)] + [(4, i, 0) for i in range(32)]
    out.append((OUT, 'voice_spc8_seek', img, 1, cmds, dict(mask=15, voice=1, pics=None, audio=None, clips=clips)))
    # D: broken FAT link inside the bank, and a bad sector inside one clip.
    blob, clips = synthetic_bank(4)
    files, pics, audio = media_files(4, blob)
    img = Fat32Image(files, spc=1, seed=4)
    voice_index = [n for n, _ in files].index('VOICE.PCM')
    chain = img.chains[voice_index]
    broken = len(chain) * 2 // 3
    img.corrupt_fat(chain[broken], 0)
    errors = {}
    for i, clip in clips.items():
        start, count = struct.unpack_from('<II', blob, 16 + 8 * i)
        last_sector = start + (2 * count - 1) // SECTOR
        if last_sector > broken:          # spc=1: sector n of the file is chain[n]
            errors[i] = 4
    victim = min(i for i in clips if i not in errors and i > 3)
    start, _ = struct.unpack_from('<II', blob, 16 + 8 * victim)
    bad = img.cluster_lba(chain[start])
    errors[victim] = 5
    cmds = [(1, 0, 0), (7, bad, 0)] + [(4, i, 0) for i in range(32)]
    out.append((OUT, 'voice_chain_and_read_errors', img, 1, cmds,
                dict(mask=15, voice=1, pics=None, audio=None, clips=clips, errors=errors)))
    # D2: premature end-of-chain marker and a self-loop inside the bank (spc=1).
    blob, clips = synthetic_bank(10)
    files, pics, audio = media_files(10, blob)
    img = Fat32Image(files, spc=1, seed=10)
    chain = img.chains[[n for n, _ in files].index('VOICE.PCM')]
    eoc_at, loop_at = len(chain) * 3 // 4, len(chain) // 3
    img.corrupt_fat(chain[eoc_at], 0x0FFFFFFF)
    img.corrupt_fat(chain[loop_at], chain[loop_at])
    errors = {}
    for i, clip in clips.items():
        start, count = struct.unpack_from('<II', blob, 16 + 8 * i)
        if start + (2 * count - 1) // SECTOR > loop_at:
            errors[i] = 4
    cmds = [(1, 0, 0)] + [(4, i, 0) for i in range(32)]
    out.append((OUT, 'voice_chain_eoc_loop', img, 1, cmds,
                dict(mask=15, voice=1, pics=None, audio=None, clips=clips, errors=errors)))
    # E: header errors: wrong magic, and an entry that points past the end of the file.
    blob, clips = synthetic_bank(5)
    bad_magic = b'HVB0' + blob[4:]
    files, pics, audio = media_files(5, bad_magic)
    img = Fat32Image(files, spc=8, seed=5)
    cmds = [(1, 0, 0), (4, 0, 0), (4, 9, 0)]
    out.append((OUT, 'voice_bad_magic', img, 1, cmds, dict(mask=15, voice=1, pics=None, audio=None,
                                                      clips={0: None, 9: None}, errors={0: 1, 9: 1})))
    blob, clips = synthetic_bank(6)
    hacked = bytearray(blob)
    struct.pack_into('<II', hacked, 16 + 8 * 3, len(blob) // SECTOR - 1, 600)
    files, pics, audio = media_files(6, bytes(hacked))
    img = Fat32Image(files, spc=8, seed=6)
    cmds = [(1, 0, 0), (4, 3, 0), (4, 4, 0)]
    out.append((OUT, 'voice_entry_out_of_file', img, 1, cmds, dict(mask=15, voice=1, pics=None, audio=None,
                                                              clips={3: None, 4: clips[4]}, errors={3: 3})))
    # F: no VOICE.PCM on the card.
    # spc=1 and 4 special + 23 padding + 5 file entries = 32 = exactly two full root
    # clusters: no 0x00 terminator, and with VOICE.PCM absent the scanner cannot stop
    # early, so it must follow the directory chain to its end-of-chain FAT entry.
    files, pics, audio = media_files(7, None)
    img = Fat32Image(files, spc=1, seed=7, dir_padding=23)
    if len(img.chains['root']) != 2:
        raise AssertionError('voice_missing must fill exactly two root clusters')
    cmds = [(1, 0, 0), (3, 0, 0), (4, 1, 0), (2, 0, 0), (8, 0, 0)]
    out.append((OUT, 'voice_missing', img, 1, cmds, dict(mask=15, voice=0, pics=pics[:1], audio=audio,
                                                    clips={1: None}, errors={1: 6})))
    # S1 (10/21): pictures larger than the 16x8 output, scaled by the reader: 2x (area k=2),
    #     3x (k=3), non-integer, and wider/taller aspect ratios (letterbox both ways).
    files, pics, audio = media_files(11, None, sizes=[(32, 16), (48, 24), (24, 12), (40, 10)])
    img = Fat32Image(files, spc=8, seed=11)
    cmds = [(1, 0, 0)] + [(2, i, 0) for i in range(4)]
    out.append((OUT, 'scale_down_k2_k3', img, 0, cmds, dict(mask=15, voice=0, pics=pics, audio=None, clips={})))
    files, pics, audio = media_files(12, None, sizes=[(16, 16), (21, 9), (37, 23), (17, 8)])
    img = Fat32Image(files, spc=1, fragment=True, seed=12)
    cmds = [(1, 0, 0)] + [(2, i, 0) for i in (3, 2, 1, 0)]
    out.append((OUT, 'scale_aspect_fragmented', img, 0, cmds, dict(mask=15, voice=0, pics=pics, audio=None, clips={})))
    # S2 (10/21): size limits. Below the output size (official minimum) and above the maximum are
    #     rejected with code 1 before any pixel; the other pictures still load. The bench sets the
    #     maximum to 64x32 here (production 1920x1080: same comparison, a parameter).
    files, pics, audio = media_files(13, None, sizes=[(15, 8), (16, 7), (65, 32), (64, 33)])
    img = Fat32Image(files, spc=8, seed=13)
    cmds = [(1, 0, 0)] + [(2, i, 0) for i in range(4)]
    out.append((OUT, 'size_limits_rejected', img, 0, cmds,
                dict(mask=15, voice=0, pics=None, audio=None, clips={}, load_errors={0: 1, 1: 1, 2: 1, 3: 1})))
    files, pics, audio = media_files(14, None, sizes=[(64, 32), (64, 8), (16, 32), (16, 8)])
    img = Fat32Image(files, spc=64, seed=14)
    cmds = [(1, 0, 0)] + [(2, i, 0) for i in range(4)]
    out.append((OUT, 'size_limits_largest_accepted', img, 0, cmds, dict(mask=15, voice=0, pics=pics, audio=None, clips={})))
    # S3 (10/21): the real output size: an 800x600 file shown at 640x480 (k=1, step 1.25).
    files, pics, audio = media_files(15, None, sizes=[(800, 600), (16, 8), (16, 8), (16, 8)], out=(640, 480))
    img = Fat32Image(files, spc=64, seed=15)
    cmds = [(1, 0, 0), (2, 0, 0)]
    out.append(((640, 480), 'real_size_800x600', img, 0, cmds,
                dict(mask=15, voice=0, pics=pics, audio=None, clips={})))
    # G: the real generated bank, 32 KB clusters like a 32 GB SDHC card.
    real = REAL_VOICE
    if real.is_file():
        blob = real.read_bytes()
        clips = voice_bank.parse(blob)
        files, pics, audio = media_files(8, blob)
        img = Fat32Image(files, spc=64, seed=8)
        ids = [0, 1, 2, 21, 22, 29, 31]
        cmds = [(1, 0, 0)] + [(4, i, 0) for i in ids]
        out.append((OUT, 'voice_real_bank', img, 1, cmds, dict(mask=15, voice=1, pics=None, audio=None,
                                                          clips={i: clips[i] for i in ids})))
    return out


def check(trace, cmds, expect):
    lines = trace.splitlines()
    if not lines or not lines[-1].startswith('END'):
        raise RuntimeError('trace incomplete')
    scans = [l for l in lines if l.startswith('SCAN')]
    want_scan = f"SCAN failed=0 mask={expect['mask']} voice={expect['voice']}"
    if scans != [want_scan]:
        raise RuntimeError(f'scan result {scans}, expected {want_scan}')
    pixels, clip_bytes_seen, audio_seen = [], bytearray(), bytearray()
    loads, clips_done = [], []
    for line in lines:
        tag = line.split()[0]
        if tag == 'P':
            pixels.append(int(line[2:], 16))
        elif tag == 'C':
            clip_bytes_seen.append(int(line[2:], 16))
        elif tag == 'A':
            audio_seen.append(int(line[2:], 16))
        elif tag == 'LOAD':
            _, index, ok, code = line.split()
            loads.append((int(index), int(ok), int(code), pixels))
            pixels = []
        elif tag == 'CLIP':
            _, cid, ok, code = line.split()
            clips_done.append((int(cid), int(ok), int(code), bytes(clip_bytes_seen)))
            clip_bytes_seen = bytearray()
    if pixels or clip_bytes_seen:
        raise RuntimeError('bytes outside any command')
    want_loads = [a for op, a, b in cmds if op == 2] + [b for op, a, b in cmds if op == 5]
    if sorted(l[0] for l in loads) != sorted(want_loads):
        raise RuntimeError(f'loads {[l[0] for l in loads]} expected {want_loads}')
    load_errors = expect.get('load_errors', {})
    for index, ok, code, got in loads:
        if index in load_errors:
            if ok or code != load_errors[index] or got:
                raise RuntimeError(f'image {index} expected error {load_errors[index]}, got ok={ok} code={code} pixels {len(got)}')
            continue
        if not ok or got != expect['pics'][index]:
            bad = next((k for k, (a, b) in enumerate(zip(got, expect['pics'][index])) if a != b), None)
            raise RuntimeError(f'image {index} ok={ok} code={code} pixels {len(got)}/{len(expect["pics"][index])} '
                               f'mismatch (first differing pixel {bad})')
    want_clips = [a for op, a, b in cmds if op in (4, 5)]
    if [c[0] for c in clips_done] != want_clips:
        raise RuntimeError(f'clips {[c[0] for c in clips_done]} expected {want_clips}')
    errors = dict(expect.get('errors', {}))
    for cid, clip in expect['clips'].items():
        if clip is None and cid not in errors:
            errors[cid] = 2
    if expect['clips'] and set(range(32)) <= set(want_clips):
        for cid in range(32):
            if cid not in expect['clips'] and cid not in errors:
                errors[cid] = 2   # empty slot
    for cid, ok, code, got in clips_done:
        if cid in errors:
            if ok or code != errors[cid] or got and errors[cid] not in (4, 5):
                raise RuntimeError(f'clip {cid} expected error {errors[cid]}, got ok={ok} code={code}')
            if errors[cid] in (4, 5) and got != clip_bytes(expect['clips'][cid])[:len(got)]:
                raise RuntimeError(f'clip {cid} partial bytes before error are wrong')
        else:
            want = clip_bytes(expect['clips'][cid])
            if not ok or code or got != want:
                raise RuntimeError(f'clip {cid} ok={ok} code={code} bytes {len(got)}/{len(want)} mismatch')
    if expect['audio'] is not None:
        if bytes(audio_seen) != expect['audio'] or 'AUDIO done' not in lines:
            raise RuntimeError(f'audio stream {len(audio_seen)}/{len(expect["audio"])} bytes mismatch')
    elif audio_seen:
        raise RuntimeError('unexpected audio bytes')
    return {'loads': len(loads), 'clips': len(clips_done), 'clip_errors': sorted(errors.items()),
            'audio_bytes': len(audio_seen), 'sd_reads': int(lines[-1].split('=')[1])}


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iverilog')
    parser.add_argument('--vvp')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--only')
    parser.add_argument('--mutation-check', action='store_true')
    parser.add_argument('--mutations-only', action='store_true', help='skip the normal scenarios')
    args = parser.parse_args()
    started = datetime.datetime.now().astimezone()
    output = (args.output or HERE / 'fat32_results' / started.strftime('run_%Y%m%d_%H%M%S')).resolve()
    if output.exists() and any(output.iterdir()):
        raise RuntimeError('Output must be new or empty: ' + str(output))
    output.mkdir(parents=True, exist_ok=True)
    iv, vvp = tool_path('iverilog', args.iverilog), tool_path('vvp', args.vvp)
    summary = {'started': started.isoformat(),
               'scope': 'fat32_bmp_reader + SD sector model (no SPI, no SDRAM, no TD/board)',
               'sources': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in RTL + [BENCH, Path(__file__), HERE / 'fat32_image.py']},
               'cases': [], 'mutations': []}

    def simulate(name, img, voice, cmds, rtl, record, out=OUT):
        work = output / name
        work.mkdir()
        count = img.write_hex(work)
        (work / 'cmds.txt').write_text(''.join(f'{op} {a} {b}\n' for op, a, b in cmds))
        maxs = 1 << max(10, (count - 1).bit_length())
        steps = [[iv, '-g2012', '-Wall', '-DBMP_SCALER_BEHAVIORAL_RAM', '-s', 'tb', f'-Ptb.MAXS={maxs}',
                  f'-Ptb.VOICE={voice}', f'-Ptb.OW={out[0]}', f'-Ptb.OH={out[1]}',
                  *([f'-Ptb.MAXW=64', f'-Ptb.MAXH=32'] if name.startswith('size_limits') else []),
                  '-o', 'sim.vvp', str(BENCH), *map(str, rtl)],
                 [vvp, 'sim.vvp', f'+SECTORS={count}', '+CMDS=cmds.txt']]
        record.update({'sectors': count, 'commands': steps})
        for stage, command in zip(('compile', 'run'), steps):
            result = subprocess.run(command, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
            log = result.stdout.decode('utf-8', errors='replace')
            (work / f'{stage}.log').write_text(log, encoding='utf-8')
            if result.returncode or (stage == 'run' and 'PASS FAT32_TRACE' not in log):
                raise RuntimeError(f'{name} {stage} failed:\n{log[-3000:]}')
        return (work / 'trace.txt').read_text()

    try:
        syntax = [iv, '-g2005', '-Wall', '-DBMP_SCALER_BEHAVIORAL_RAM', '-s', 'fat32_bmp_reader', '-o', str(output / 'syntax.vvp'), *map(str, RTL)]
        result = subprocess.run(syntax, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        log = result.stdout.decode('utf-8', errors='replace')
        summary['syntax'] = {'command': syntax, 'messages': log.strip().splitlines()}
        if result.returncode:
            raise RuntimeError('Verilog-2005 syntax failed:\n' + log)
        print('PASS Verilog-2005 syntax' + (' (messages: %d)' % len(log.strip().splitlines()) if log.strip() else ', no warnings'))
        cases = scenarios()
        for out_size, name, img, voice, cmds, expect in cases:
            if args.mutations_only or (args.only and args.only not in name):
                continue
            record = {'name': name, 'voice': voice, 'spc': img.spc, 'output': list(out_size), 'passed': False}
            summary['cases'].append(record)
            trace = simulate(name, img, voice, cmds, RTL, record, out_size)
            record['result'] = check(trace, cmds, expect)
            record['passed'] = True
            (output / name / 'trace.txt').unlink()
            print(f"PASS {name}: {record['result']}")
        if args.mutation_check:
            reader = SD / 'fat32_clip_reader.v'
            # Seek mutants need a clip that starts mid-cluster, so they run on spc=64.
            mutations = [
                ('entry_slot', "dir_ram[sector_index[7:3]-5'd2]", "dir_ram[sector_index[7:3]-5'd1]",
                 'voice_spc1_fragmented'),
                ('fat_cache_tag', "fat_hit<=fat_tag_valid && fat_tag==fat_want;", "fat_hit<=fat_tag_valid;",
                 'voice_spc8_seek'),
                ('fat_cache_index', "fat_q<=fat_ram[cluster[6:0]];", "fat_q<=fat_ram[cluster[7:1]];",
                 'voice_spc8_seek'),
                ('seek_sector_mask', "entry_start[7:0] & (sectors_per_cluster-8'd1)", "entry_start[7:0]",
                 'voice_spc8_seek'),
                ('seek_hops', 'if(hops!=0) begin hops<=hops-1', 'if(hops>1) begin hops<=hops-1', 'voice_spc8_seek'),
                ('tail_bytes', "if(remaining==22'd1) has_bytes<=0;", "if(remaining==22'd2) has_bytes<=0;",
                 'voice_spc1_fragmented'),
                ('chain_check', "fat_bad<=next_cluster<2 || next_cluster>max_cluster || next_cluster==cluster;",
                 "fat_bad<=next_cluster<2;", 'voice_chain_eoc_loop'),
                # Timing pipelines added after the 2026-10-01 23:39 build (file streamer
                # FAT byte register, scanner directory-chain FAT_EVAL).
                ('streamer_fat_lane', "1:next_cluster[15:8]<=fat_data_q;", "1:next_cluster[23:16]<=fat_data_q;",
                 'baseline_voice_off', SD / 'fat32_file_streamer.v'),
                ('scanner_dir_eoc', "if(dir_eoc) state<=FINISH;", "if(1'b0) state<=FINISH;",
                 'voice_missing', SD / 'fat32_volume_scanner.v'),
            ]
            for entry in mutations:
                name, before, after, scenario = entry[:4]
                source = entry[4] if len(entry) > 4 else reader
                text = source.read_text(encoding='utf-8')
                target = next(c for c in cases if c[1] == scenario)
                if text.count(before) != 1:
                    raise RuntimeError('mutation anchor drift: ' + name)
                mutant = output / f'mutant_{name}.v'
                mutant.write_text(text.replace(before, after), encoding='utf-8')
                rtl = [mutant if p == source else p for p in RTL]
                record = {'name': name, 'detected': False}
                summary['mutations'].append(record)
                try:
                    trace = simulate('mut_' + name, target[2], target[3], target[4], rtl, record, target[0])
                    check(trace, target[4], target[5])
                except RuntimeError as exc:
                    record['detected'] = True
                    record['reason'] = str(exc).splitlines()[0][:200]
                if not record['detected']:
                    raise RuntimeError('mutation not detected: ' + name)
                print('PASS MUTATION_DETECTED', name, '-', record['reason'])
        summary['passed'] = True
    except Exception as exc:
        summary['passed'] = False
        summary['error'] = str(exc)
        raise
    finally:
        summary['finished'] = datetime.datetime.now().astimezone().isoformat()
        (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
        print('Evidence:', output / 'summary.json')


if __name__ == '__main__':
    try:
        run()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
