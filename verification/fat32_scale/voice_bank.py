"""Hospital voice bank (VOICE.PCM) builder and reference parser.

The FPGA plays fixed clips by id. This file is the single authority for:
  * the clip id table (must match CLIP_* in 07_app_dev/rtl/hospital_voice_dispatch.v),
  * the VOICE.PCM binary layout read by the future SD-side clip player.

VOICE.PCM layout (all integers little-endian):
  sector 0 (512 bytes) header
    0..3    magic b'HVB1'
    4..5    clip slot count (32)
    6..7    sample rate in kHz (48)
    8..15   reserved, zero
    16+8*i  start sector of clip i, relative to the file start (>=1), u32
    20+8*i  sample count of clip i (0 = slot empty), u32
    rest    zero
  sector 1.. clip data: signed 16-bit mono 48 kHz PCM, each clip starts on a sector
            boundary and is zero padded to the end of its last sector.

Never writes to a TF card. Copy the produced VOICE.PCM to the FAT32 root yourself,
next to PIC1..4.BMP. Do not use the old sync_to_sd.py (it deletes card contents).
"""
from array import array
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import wave

SECTOR = 512
RATE = 48000
SLOTS = 32
MAGIC = b'HVB1'
MAX_CLIP_SAMPLES = (1 << 20) - 1  # ~21.8 s; the player rejects longer entries

# Clip ids shared with the RTL (CLIP_* localparams).
CLIP_IDS = {
    'CLIP_CHIME': 0,
    'CLIP_PLEASE': 1,
    'CLIP_NUMBER_BASE': 1,   # call number n (1..20) -> clip 1+n
    'CLIP_CALL_SUFFIX': 22,  # 10/25: no longer used by the sentences (kept for old benches)
    'CLIP_ROOM_BASE': 23,    # 10/25: room r (0..3) -> clip 23+r "到 r+1 诊室就诊"; 27..29 spare
    'CLIP_HELP_ACK': 30,
    'CLIP_HELP_REQ': 31,
}

_DIGITS = '零一二三四五六七八九'


def chinese_number(n):
    if n < 10:
        return _DIGITS[n]
    if n == 10:
        return '十'
    if n < 20:
        return '十' + _DIGITS[n - 10]
    tens, ones = divmod(n, 10)
    return _DIGITS[tens] + '十' + (_DIGITS[ones] if ones else '')


def default_phrases():
    """Clip id -> spoken text. Slot 0 is the synthetic chime (None)."""
    phrases = {0: None, 1: '请'}
    for n in range(1, 21):
        phrases[CLIP_IDS['CLIP_NUMBER_BASE'] + n] = chinese_number(n) + '号'
    phrases[22] = '到诊室就诊'
    for r in range(4):                                   # 10/25 multi-room
        phrases[CLIP_IDS['CLIP_ROOM_BASE'] + r] = '到' + _DIGITS[r + 1] + '诊室就诊'
    for k in (27, 28, 29):                               # spare (the expression cards were removed)
        phrases[k] = '请稍候'
    phrases[30] = '工作人员已收到求助，请稍候'
    phrases[31] = '患者请求帮助，请工作人员前往'
    assert sorted(phrases) == list(range(SLOTS))
    return phrases


def sentence(kind, number, card):
    """Reference of the dispatcher mapping: event kind/number/card -> clip ids."""
    if kind in (1, 2):                                   # card field = room 0..3
        return [0, 1, 1 + number, 23 + (card & 3)] if 1 <= number <= 20 else []
    if kind == 4:
        return [0, 31]
    if kind == 5:
        return [30]
    return []


def chime():
    """Two-tone 'ding-dong' (E5 then C5) with decay; peak about half scale."""
    out = array('h')
    for freq, length in ((659.25, 0.32), (523.25, 0.50)):
        count = int(RATE * length)
        for i in range(count):
            t = i / RATE
            env = min(1.0, i / (0.005 * RATE)) * math.exp(-4.0 * t)
            v = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(4 * math.pi * freq * t)
            out.append(int(0.5 * 32767 * env * v / 1.25))
    out.extend([0] * int(0.08 * RATE))
    return out


def read_wav(path):
    with wave.open(str(path), 'rb') as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getcomptype()) != (1, 2, RATE, 'NONE'):
            raise ValueError(f'{path}: need 48 kHz, 16-bit, mono, uncompressed PCM WAV')
        data = array('h')
        data.frombytes(w.readframes(w.getnframes()))
    if sys.byteorder != 'little':
        data.byteswap()
    return data


def trim(samples, threshold=300, pad_ms=60):
    loud = [i for i, v in enumerate(samples) if abs(v) > threshold]
    if not loud:
        return array('h')
    pad = int(RATE * pad_ms / 1000)
    return samples[max(0, loud[0] - pad):min(len(samples), loud[-1] + pad + 1)]


def tts_generate(phrases, workdir, voice):
    """Render phrases with Windows SAPI (System.Speech) straight to 48 kHz/16-bit/mono."""
    jobs = [{'id': i, 'text': t, 'path': str(Path(workdir) / f'tts_{i:02d}.wav')}
            for i, t in sorted(phrases.items()) if t]
    job_file = Path(workdir) / 'jobs.json'
    job_file.write_text(json.dumps(jobs, ensure_ascii=False), encoding='utf-8')
    script = (
        "$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Speech;"
        "$s=New-Object System.Speech.Synthesis.SpeechSynthesizer;"
        f"$s.SelectVoice('{voice}');"
        "$f=New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(48000,"
        "[System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,[System.Speech.AudioFormat.AudioChannel]::Mono);"
        f"$jobs=Get-Content -Raw -Encoding UTF8 -LiteralPath '{job_file}' | ConvertFrom-Json;"
        "foreach($j in $jobs){$s.SetOutputToWaveFile($j.path,$f);$s.Speak($j.text)};$s.SetOutputToNull()")
    subprocess.run(['powershell', '-NoProfile', '-Command', script], check=True)
    return {j['id']: Path(j['path']) for j in jobs}


def pack(clips):
    """clips: id -> array('h'). Returns VOICE.PCM bytes."""
    header = bytearray(SECTOR)
    header[0:8] = MAGIC + struct.pack('<HH', SLOTS, RATE // 1000)
    body = bytearray()
    for i in range(SLOTS):
        samples = clips.get(i, array('h'))
        if len(samples) > MAX_CLIP_SAMPLES:
            raise ValueError(f'clip {i} too long: {len(samples)} samples')
        start = 1 + len(body) // SECTOR if samples else 0
        struct.pack_into('<II', header, 16 + 8 * i, start, len(samples))
        if samples:
            raw = samples.tobytes() if sys.byteorder == 'little' else _swapped(samples)
            body += raw + bytes(-len(raw) % SECTOR)
    return bytes(header + body)


def _swapped(samples):
    copy = array('h', samples)
    copy.byteswap()
    return copy.tobytes()


def parse(blob):
    """Reference parser with the same checks the RTL player must apply."""
    if len(blob) < SECTOR or blob[0:4] != MAGIC:
        raise ValueError('bad magic / short header')
    slots, khz = struct.unpack_from('<HH', blob, 4)
    if slots != SLOTS or khz != RATE // 1000:
        raise ValueError(f'unsupported slots={slots} rate={khz}k')
    clips = {}
    for i in range(SLOTS):
        start, count = struct.unpack_from('<II', blob, 16 + 8 * i)
        if count == 0:
            continue
        if start < 1 or count > MAX_CLIP_SAMPLES or start * SECTOR + 2 * count > len(blob):
            raise ValueError(f'clip {i} outside file: start={start} count={count}')
        raw = blob[start * SECTOR:start * SECTOR + 2 * count]
        data = array('h')
        data.frombytes(raw)
        if sys.byteorder != 'little':
            data.byteswap()
        clips[i] = data
    return clips


def write_wav(path, samples):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes() if sys.byteorder == 'little' else _swapped(samples))


def build(out_dir, wav_dir=None, voice='Microsoft Huihui Desktop', peak=0.8):
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    phrases = default_phrases()
    sources = {}
    with tempfile.TemporaryDirectory() as work:
        # Recorded clips (clip_XX.wav) override TTS for the same id.
        recorded = {}
        if wav_dir:
            for i in phrases:
                candidate = Path(wav_dir) / f'clip_{i:02d}.wav'
                if candidate.is_file():
                    recorded[i] = candidate
        missing = {i: t for i, t in phrases.items() if t and i not in recorded}
        rendered = tts_generate(missing, work, voice) if missing else {}
        clips = {0: chime()}
        sources[0] = 'synthetic chime'
        for i, text in phrases.items():
            if not text:
                continue
            path = recorded.get(i) or rendered[i]
            clips[i] = trim(read_wav(path))
            sources[i] = 'recorded ' + path.name if i in recorded else 'TTS ' + voice
            if not clips[i]:
                raise ValueError(f'clip {i} ({text}) is silent')
    # One global gain for all speech clips keeps relative loudness natural.
    loudest = max(max(abs(v) for v in clips[i]) for i in clips if i)
    gain = peak * 32767 / loudest
    for i in clips:
        if i:
            clips[i] = array('h', (max(-32768, min(32767, int(round(v * gain)))) for v in clips[i]))
    blob = pack(clips)
    if parse(blob) != clips:
        raise RuntimeError('round-trip mismatch')
    (out_dir / 'VOICE.PCM').write_bytes(blob)
    preview = out_dir / 'preview'
    preview.mkdir(exist_ok=True)
    for i, samples in clips.items():
        write_wav(preview / f'clip_{i:02d}.wav', samples)
    examples = {'call_07': sentence(1, 7, 0), 'call_20': sentence(1, 20, 0),
                'express_write': sentence(3, 0, 1), 'help': sentence(4, 0, 0), 'help_ack': sentence(5, 0, 0)}
    for name, ids in examples.items():
        joined = array('h')
        for i in ids:
            joined.extend(clips[i])
        write_wav(preview / f'sentence_{name}.wav', joined)
    manifest = {
        'file': 'VOICE.PCM', 'bytes': len(blob), 'sha256': hashlib.sha256(blob).hexdigest(),
        'format': 's16le mono 48 kHz, sector-aligned clips, header in sector 0',
        'gain': gain, 'clip_ids': CLIP_IDS,
        'clips': [{'id': i, 'text': phrases[i] or '(chime)', 'source': sources[i], 'samples': len(clips[i]),
                   'seconds': round(len(clips[i]) / RATE, 3),
                   'start_sector': struct.unpack_from('<I', blob, 16 + 8 * i)[0]} for i in range(SLOTS)],
        'example_sentences': examples,
    }
    (out_dir / 'voice_manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--out', type=Path, default=Path(__file__).resolve().parents[1] / 'voice_bank')
    parser.add_argument('--wav-dir', type=Path, help='optional recorded clip_XX.wav (48k/16-bit/mono)')
    parser.add_argument('--voice', default='Microsoft Huihui Desktop')
    args = parser.parse_args()
    manifest = build(args.out, args.wav_dir, args.voice)
    total = sum(c['seconds'] for c in manifest['clips'])
    print(f"VOICE.PCM {manifest['bytes']} bytes, {total:.1f} s audio, sha256 {manifest['sha256']}")
    print('Output:', args.out.resolve())


if __name__ == '__main__':
    main()
