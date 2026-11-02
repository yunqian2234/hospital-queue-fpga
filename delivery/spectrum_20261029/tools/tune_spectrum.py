"""10/29 one-off: tune the spectrum display (window, dB scale, frame aggregate) on the sweep and 1.wav.
Prints, per setting, the song movement (sd), the song mean and the sweep leakage (mean height of bars
two or more bands away from the tone)."""
import math
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import preview_spectrum as pv  # noqa: E402

FS = 48000
BANDS = 16
F = [60 * (12000 / 60) ** (k / (BANDS - 1)) for k in range(BANDS)]


def lvl(re, im):
    a, b = abs(re), abs(im)
    m = max(a, b) + min(a, b) / 4
    if m < 1:
        return 0.0
    return 8 * math.log2(m)


def run(pcm, mult, win, agg, ratio, fs_px):
    M = [max(5, min(11, round(math.log2(FS / (ratio * f))))) for f in F]
    s1 = [0.0] * 16; s2 = [0.0] * 16
    pend = [0] * 16; last = [0] * 16; bar = [0] * 16; out = []; cnt = 0
    full = [lvl(32767 * (1 << M[k]) / (2 if win == 'rect' else 4), 0) for k in range(16)]
    for i, x in enumerate(pcm):
        for k in range(16):
            N = 1 << M[k]; n = cnt & (N - 1)
            xw = x if win == 'rect' else x * 0.5 * (1 - math.cos(2 * math.pi * n / N))
            w = 2 * math.pi * F[k] / FS
            s0 = xw + 2 * math.cos(w) * s1[k] - s2[k]
            if n == N - 1:
                re = s0 - math.cos(w) * s1[k]; im = math.sin(w) * s1[k]
                v = max(0, min(61, int(mult * (lvl(re, im) - full[k]) / 8 * 8 + fs_px)))
                pend[k] = max(pend[k], v); last[k] = v
                s1[k] = s2[k] = 0
            else:
                s2[k] = s1[k]; s1[k] = s0
        cnt += 1
        if i % 800 == 799:
            src = pend if agg == 'max' else last
            for k in range(16):
                bar[k] = max(src[k], bar[k] - 2 if bar[k] > 2 else 0); pend[k] = 0
            out.append((list(bar), i))
    return out


song = pv.song_pcm()[48000 * 2:48000 * 6]
sweep = pv.sweep_pcm(3)
for mult in (1.0, 1.5, 2.0):
    for win in ('rect', 'hann'):
        for agg in ('max', 'last'):
            for ratio, fs_px in ((0.355, 70),):
                a = run(song, mult, win, agg, ratio, fs_px)
                sd = statistics.mean(statistics.pstdev(b[k] for b, _ in a) for k in range(16))
                mean = statistics.mean(statistics.mean(b[k] for b, _ in a) for k in range(16))
                s = run(sweep, mult, win, agg, ratio, fs_px)
                leak = []
                for b, i in s:
                    f = 40 * (16000 / 40) ** (i / (48000 * 3))
                    if f < 50 or f > 13000:
                        continue
                    kc = min(range(16), key=lambda k: abs(math.log(F[k] / f)))
                    leak += [b[k] for k in range(16) if abs(k - kc) >= 2]
                print(f'x{mult} {win:4s} {agg:4s}: song sd {sd:5.1f} mean {mean:5.1f}  sweep leak {statistics.mean(leak):5.1f}')
