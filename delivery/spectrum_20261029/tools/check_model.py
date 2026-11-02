"""10/29 spectrum model checks (Python only, no RTL):
  1. a pure tone at each band centre lights that band highest; neighbours two or more bands away
     stay low (the bars really are a spectrum, low on the left, high on the right)
  2. -6 dB on the input lowers the band by 12 px (1 px = 0.5 dB)
  3. song statistics (mean / movement) for the chosen FS_PX
  4. state never wraps (largest |s1| over full-scale tones and the song fits W bits)
Usage: python delivery/spectrum_20261029/tools/check_model.py
"""
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
sys.path.insert(0, str(LAB / 'verification/ui3'))
sys.path.insert(0, str(HERE))
import spectrum_model as sm  # noqa: E402
import preview_spectrum as pv  # noqa: E402


def tone(f, amp, n):
    return [int(round(amp * math.sin(2 * math.pi * f * i / 48000))) for i in range(n)]


def run(pcm, track=None):
    eng = sm.Engine()
    last = [0] * 16
    big = 0
    for x in pcm:
        for k, v in eng.sample(x).items():
            last[k] = v
        if track is not None:
            big = max(big, max(abs(v) for v in eng.s1 + eng.s2))
    return last, big


ok = True
worst = 0
print('band  F(Hz)   bars (tone at the band centre, amplitude 16000)')
for k in range(16):
    bars, big = run(tone(sm.F[k], 16000, 4096 + 2048), track=True)
    worst = max(worst, big)
    far = max([bars[j] for j in range(16) if abs(j - k) >= 2] or [0])
    good = bars.index(max(bars)) == k or bars[k] == max(bars)
    ok &= good and far <= bars[k] - 15
    print(f'{k:2d} {sm.F[k]:8.1f}  {" ".join(f"{b:2d}" for b in bars)}  {"ok" if good and far <= bars[k] - 15 else "BAD"}')
for k in (0, 7, 11):          # bands without TILT: -12 dB is below the clip
    a, big = run(tone(sm.F[k], 32767, 4096 + 2048), track=True)
    worst = max(worst, big)
    b, _ = run(tone(sm.F[k], 8192, 4096 + 2048))
    c, _ = run(tone(sm.F[k], 2048, 4096 + 2048))
    print(f'band {k}: full scale {a[k]} px, -12 dB {b[k]} px, -24 dB {c[k]} px')
    ok &= a[k] == 61 and abs((b[k] - c[k]) - 24) <= 2
song = pv.song_pcm()
_, big = run(song[: 48000 * 4], track=True)
worst = max(worst, big)
print(f'largest |state| {worst} -> {worst.bit_length() + 1} bits of {sm.W}')
ok &= worst.bit_length() + 1 <= sm.W - 1
fr = pv.frames(song[48000 * 2: 48000 * 10])
allb = [b for b, c in fr]
print('song mean', [round(statistics.mean(b[k] for b in allb)) for k in range(16)])
print('song sd  ', [round(statistics.pstdev(b[k] for b in allb)) for k in range(16)])
print('PASS' if ok else 'FAIL')
sys.exit(0 if ok else 1)
