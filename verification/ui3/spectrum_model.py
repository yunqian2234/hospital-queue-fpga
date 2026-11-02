"""10/29 spectrum bars: bit-exact model of the DFT engine in audio_bar_visualizer.v (v2) and the band
tables the RTL uses (run this file to print them; gen_tables.py writes them into the RTL / ROM).

Engine (one time-shared Goertzel pass over the 16 bands for every PCM tap):
  band k: centre F[k] (60 Hz .. 12 kHz, log spaced), block N = 2**M[k] taps (bin about 0.36 F),
  C = round(2 cos w * 2^16), S = round(sin w * 2^16) (both 0..131071), w = 2 pi F / 48000.
  Blocks are staggered: band k's block position is n = (cnt + 2k) mod N, so no two bands end a
  block on the same tap (the log step after a block end is serial and slow).
  per tap: x = pcm >>> XS; cnt = taps worked on since reset (11-bit wrap; taps while enable is low
  are ignored and do not count)
    idx = n >> (M-5); xw = (x * HANN[idx]) >>> 8      (32-step Hann window)
    s1, s2 = stored values (0 at power-up and after the band's previous block end)
    d = xw - s2; p = C*s1; s0 = d + (p >>> 16); stored s1, s2 <- s0, s1, or 0, 0 at a block end (W-bit wrap)
    if n == N-1 (block end):
      re = d + (p >>> 17); im = (S*s1) >>> 16
      la = LG(re ^ sign), lb = LG(im ^ sign)          (ones' complement |.|; LG = 8 log2, 3 frac bits)
      L = max(la, lb) + G[|la - lb|]                  (log of sqrt(re^2 + im^2))
      v = clamp(L + (L >> 1) - OFF[k], 0, 61)         (1 px = 0.5 dB, 61 px = 30 dB; OFF has TILT)
      pend[k] = max(pend[k], v)
Display (every frame start): bar = max(pend, bar - BAR_FALL), pend = 0; cap as in the 10/28 bars.
"""
import math

FS = 48000
BANDS = 16
W = 27            # state width (a full-scale 60 Hz tone needs 26 bits)
XS = 6            # input shift
F = [60 * (12000 / 60) ** (k / (BANDS - 1)) for k in range(BANDS)]
M = [max(5, min(11, round(math.log2(FS / (0.355 * f))))) for f in F]
C = [round(2 * math.cos(2 * math.pi * f / FS) * 65536) for f in F]
S = [round(math.sin(2 * math.pi * f / FS) * 65536) for f in F]
PH = [2 * k + 1 for k in range(BANDS)]      # block stagger (distinct mod 32; +1: the RTL counts the tap first)
HANN = [round(255 * 0.5 * (1 - math.cos(2 * math.pi * (i + 0.5) / 32))) for i in range(32)]
G = [round(4 * math.log2(1 + 2 ** (-d / 4))) for d in range(32)]
G = G[:G.index(0)] if 0 in G else G          # entries after the last nonzero are 0
FS_PX = 76        # a full-scale sine on the band centre -> 76 px (clipped to 61): music sits mid-box
TILT = [0] * 12 + [4, 8, 12, 16]   # px lift of the top bands (music has little energy up there)
BAR_FALL = 2      # px per frame a bar sinks when the band gets quieter
CAP_FALL = 3      # frames per 1 px of cap fall


def wrap(v, w=None):
    w = W if w is None else w
    m = 1 << w
    v &= m - 1
    return v - m if v >> (w - 1) else v


def lg(z):
    """8 * log2(z) with 3 fraction bits from the bits after the msb; 0 for z = 0 or 1"""
    if z <= 0:
        return 0
    p = z.bit_length() - 1
    f = (z >> (p - 3)) & 7 if p >= 3 else (z << (3 - p)) & 7
    return 8 * p + f


def gtab(d):
    return G[d] if d < len(G) else 0


def full_scale_level(k):
    a = ((32767 >> XS) * sum(HANN[i * 32 >> M[k]] for i in range(1 << M[k]))) >> 9   # A N/4-ish
    return lg(a)


def make_off():
    return [full_scale_level(k) + (full_scale_level(k) >> 1) - FS_PX - TILT[k] for k in range(BANDS)]


OFF = make_off()


def level(re, im):
    la = lg(re ^ -1 if re < 0 else re)
    lb = lg(im ^ -1 if im < 0 else im)
    return max(la, lb) + gtab(abs(la - lb))


class Engine:
    def __init__(self):
        self.s1 = [0] * BANDS
        self.s2 = [0] * BANDS
        self.cnt = 0

    def reset(self):          # enable low: nothing (the RTL keeps counter and states)
        pass

    def sample(self, pcm):
        """one tap; returns {band: height} for bands whose block ended on it"""
        x = pcm >> XS
        out = {}
        for k in range(BANDS):
            n = (self.cnt + PH[k]) & ((1 << M[k]) - 1)
            idx = n >> (M[k] - 5)
            xw = (x * HANN[idx]) >> 8
            s1, s2 = self.s1[k], self.s2[k]
            p = C[k] * s1
            d = wrap(xw - s2)
            s0 = wrap(d + (p >> 16))
            if n == (1 << M[k]) - 1:
                re = wrap(d + (p >> 17))
                im = wrap((S[k] * s1) >> 16)
                L = level(re, im)
                out[k] = max(0, min(61, L + (L >> 1) - OFF[k]))
                self.s1[k], self.s2[k] = 0, 0
            else:
                self.s1[k], self.s2[k] = s0, s1
        self.cnt = (self.cnt + 1) & 2047
        return out


def rom_words():
    """18-bit ROM of the RTL: 0..15 C, 16..31 S, 32..63 HANN"""
    return C + S + HANN


if __name__ == '__main__':
    for k in range(BANDS):
        print(f'{k:2d} {F[k]:8.1f} Hz  N {1 << M[k]:5d}  C {C[k]:6d}  S {S[k]:6d}  OFF {OFF[k]}')
    print('HANN', HANN)
    print('G', G)
