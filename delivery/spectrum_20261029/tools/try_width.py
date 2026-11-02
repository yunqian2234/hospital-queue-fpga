"""10/29 one-off: how narrow can the Goertzel state be? Compares bars for (XS, W) against XS=3/W=30."""
import importlib, math, statistics, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / 'verification/ui3')); sys.path.insert(0, str(HERE))
import spectrum_model as sm
import preview_spectrum as pv
song = pv.song_pcm()[48000 * 3: 48000 * 6]
def tone(f, a, n=6144): return [int(round(a * math.sin(2 * math.pi * f * i / 48000))) for i in range(n)]
def bars(pcm):
    e = sm.Engine(); res = []
    for x in pcm:
        o = e.sample(x)
        if o: res.append(sorted(o.items()))
    return res
def setw(xs, w):
    sm.XS, sm.W = xs, w
    sm.OFF[:] = [sm.full_scale_level(k) + (sm.full_scale_level(k) >> 1) - sm.FS_PX - sm.TILT[k] for k in range(16)]
setw(3, 30)
ref_song = bars(song); ref_t = [bars(tone(sm.F[k], a)) for k in (0, 3, 8, 15) for a in (16000, 1000)]
quiet = [bars(tone(sm.F[k], 0)) for k in (0,)]
for xs, w in ((5, 28), (6, 26), (7, 25), (7, 24), (8, 24), (8, 23)):
    setw(xs, w)
    s = bars(song)
    d = [abs(a[1] - b[1]) for ra, rb in zip(ref_song, s) for a, b in zip(ra, rb)]
    t = [bars(tone(sm.F[k], a)) for k in (0, 3, 8, 15) for a in (16000, 1000)]
    dt = max(abs(a[1] - b[1]) for x, y in zip(ref_t, t) for ra, rb in zip(x, y) for a, b in zip(ra, rb))
    e = sm.Engine(); big = 0
    for x in tone(sm.F[0], 32767) + song[:20000]:
        e.sample(x); big = max(big, max(abs(v) for v in e.s1 + e.s2))
    print(f'XS {xs} W {w}: song mean |diff| {statistics.mean(d):.2f} px, max {max(d)}; tones max diff {dt}; state needs {big.bit_length() + 1} bits')
