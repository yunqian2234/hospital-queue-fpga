"""Reference model of the BMP scaler (扩展要求3) written from the algorithm specification.

Integer arithmetic, chosen to be bit-exact with the specified fixed-point rules (not derived from
the RTL's structure):
  * fit: s = min(OUT_W/W, OUT_H/H); the limiting side becomes OUT, the other side
    round(other*OUT/this); k = floor(1/s) in 1..3; Wi = W//k, Hi = H//k; Wo<=Wi, Ho<=Hi.
  * steps sx = floor(Wi*65536/Wo), sy likewise; sample position of output xo:
    xi = (sx>>1) - 32768 + xo*sx (16 fractional bits); j = ceil(xi); t = 256 if xi is an
    integer else frac>>8; value = (a*256 + 128 + (b-a)*t) >> 8 with a = b[j-1] (a = b[0] for j=0).
  * horizontal pass per source row on k-pixel sums; vertical: k rows of horizontal results summed,
    normalised (k=1: as is, k=2: (s+2)>>2, k=3: (s*7282+32768)>>16), then the same lerp.
  * frame: Wo x Ho centred in OUT_W x OUT_H (offsets floor((OUT-Wo)/2)), FILL elsewhere.
Rows are in BMP order (bottom-up); the model works in that order throughout.
"""
import numpy as np

FILL = 0xFAFAF9                                       # 10/26: warm white (was 0x1A2C4A)


def fit(W, H, OUT_W=640, OUT_H=480):
    wide = W * OUT_H >= H * OUT_W
    if wide:
        k = 3 if W >= 3 * OUT_W else 2 if W >= 2 * OUT_W else 1
        Wo, Ho = OUT_W, (H * OUT_W + W // 2) // W
    else:
        k = 3 if H >= 3 * OUT_H else 2 if H >= 2 * OUT_H else 1
        Ho, Wo = OUT_H, (W * OUT_H + H // 2) // H
    Wi, Hi = W // k, H // k
    Wo, Ho = min(Wo, Wi), min(Ho, Hi)
    sx, sy = (Wi << 16) // Wo, (Hi << 16) // Ho
    return dict(k=k, Wi=Wi, Hi=Hi, Wo=Wo, Ho=Ho, sx=sx, sy=sy)


def _taps(n_out, step):
    """(j, t) for every output index: sample at j = ceil(x), weight t on b[j]."""
    x = (step >> 1) - 32768 + np.arange(n_out, dtype=np.int64) * step
    j = (x + 0xFFFF) >> 16
    frac = x & 0xFFFF
    t = np.where(frac == 0, 256, frac >> 8)
    return j, t


def _lerp(a, b, t):
    return (a * 256 + 128 + (b - a) * t) >> 8


def scale(src, W, H, OUT_W=640, OUT_H=480, fill=FILL):
    """src: (H, W, 3) uint8 array in BMP row order (bottom-up), channels in packing order
    (index 0 = bits 7:0). Returns (OUT_H, OUT_W, 3) in the same order, plus the fit info."""
    f = fit(W, H, OUT_W, OUT_H)
    k, Wi, Hi, Wo, Ho = f['k'], f['Wi'], f['Hi'], f['Wo'], f['Ho']
    a = src[:Hi * k, :Wi * k].astype(np.int64)
    hs = a.reshape(Hi * k, Wi, k, 3).sum(axis=2)                     # k-pixel row sums
    jx, tx = _taps(Wo, f['sx'])
    hval = _lerp(hs[:, np.maximum(jx - 1, 0)], hs[:, jx], tx[None, :, None])
    asum = hval.reshape(Hi, k, Wo, 3).sum(axis=1)
    if k == 1:
        c8 = asum
    elif k == 2:
        c8 = (asum + 2) >> 2
    else:
        c8 = (asum * 7282 + 32768) >> 16
    jy, ty = _taps(Ho, f['sy'])
    img = _lerp(c8[np.maximum(jy - 1, 0)], c8[jy], ty[:, None, None])
    out = np.empty((OUT_H, OUT_W, 3), dtype=np.int64)
    out[:] = [(fill >> 0) & 255, (fill >> 8) & 255, (fill >> 16) & 255]
    x0, y0 = (OUT_W - Wo) // 2, (OUT_H - Ho) // 2
    out[y0:y0 + Ho, x0:x0 + Wo] = img
    assert out.min() >= 0 and out.max() <= 255
    return out.astype(np.uint8), dict(f, x0=x0, y0=y0)


def pack(img):
    """(rows, cols, 3) -> list of 24-bit words, row order kept."""
    v = img.astype(np.uint32)
    return (v[..., 0] | (v[..., 1] << 8) | (v[..., 2] << 16)).reshape(-1)


def unpack(words, rows, cols):
    v = np.asarray(words, dtype=np.uint32).reshape(rows, cols)
    return np.stack([v & 255, (v >> 8) & 255, (v >> 16) & 255], axis=-1).astype(np.uint8)
