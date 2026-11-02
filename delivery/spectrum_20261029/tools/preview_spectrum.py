"""10/29 preview: spectrum bars from spectrum_model on a sine sweep and on 1.wav (GIF + stills).
Usage: python delivery/spectrum_20261029/tools/preview_spectrum.py
"""
import math
import statistics
import sys
import wave
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
sys.path.insert(0, str(LAB / 'verification/ui3'))
import spectrum_model as sm  # noqa: E402

OUT = HERE.parent / 'preview'
TAPS_PER_FRAME = 800          # 48000 / 60


def frames(pcm, fall=sm.BAR_FALL, capfall=sm.CAP_FALL):
    """display rule of the RTL: per frame bar = max(newest block values, bar - fall), cap as before"""
    eng = sm.Engine()
    bar, cap, pend, res, fn = [0] * 16, [0] * 16, [0] * 16, [], 0
    for i, x in enumerate(pcm):
        for k, v in eng.sample(x).items():
            pend[k] = max(pend[k], v)
        if i % TAPS_PER_FRAME == TAPS_PER_FRAME - 1:
            fall_now = fn == 0
            fn = 0 if fn == capfall - 1 else fn + 1
            for k in range(16):
                bar[k] = max(pend[k], bar[k] - fall if bar[k] > fall else 0)
                pend[k] = 0
                if bar[k] >= cap[k]:
                    cap[k] = bar[k]
                elif fall_now:
                    cap[k] -= 1
            res.append((list(bar), list(cap)))
    return res


def img(b, c, scale=3):
    im = Image.new('RGB', (256, 64), (0xfa, 0xfa, 0xf9))
    d = ImageDraw.Draw(im)
    for k in range(16):
        x = k * 16
        if b[k]:
            d.rectangle([x, 64 - b[k], x + 11, 63], fill=(0x0e, 0x6e, 0x6e))
        if c[k]:
            d.rectangle([x, 64 - c[k] - 3, x + 11, 64 - c[k] - 2], fill=(0xf0, 0x8c, 0x00))
    return im.resize((256 * scale, 64 * scale), Image.NEAREST)


def song_pcm():
    w = wave.open(str(LAB / 'src/user_source/hdl_source/python/1.wav'))
    raw, n, ch, sw = w.readframes(w.getnframes()), w.getnframes(), w.getnchannels(), w.getsampwidth()
    step = ch * sw          # left channel, upper 16 bits
    return [int.from_bytes(raw[i * step + sw - 2:i * step + sw], 'little', signed=True) for i in range(n)]


def sweep_pcm(seconds=4, amp=16000):
    out, ph = [], 0.0
    for i in range(48000 * seconds):
        f = 40 * (16000 / 40) ** (i / (48000 * seconds))
        ph += 2 * math.pi * f / 48000
        out.append(int(amp * math.sin(ph)))
    return out


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, pcm in (('sweep', sweep_pcm()), ('song', song_pcm()[48000 * 2:48000 * 8])):
        fr = frames(pcm)
        ims = [img(*f) for f in fr]
        ims[0].save(OUT / f'{name}.gif', save_all=True, append_images=ims[1:], duration=17, loop=0)
        st = Image.new('RGB', (768, 8 * 200), 'white')
        for j in range(8):
            st.paste(ims[j * len(ims) // 8], (0, j * 200))
        st.save(OUT / f'{name}_stills.png')
        allb = [b for b, c in fr]
        print(name, 'mean', [round(statistics.mean(b[k] for b in allb)) for k in range(16)])
        print(name, 'sd  ', [round(statistics.pstdev(b[k] for b in allb)) for k in range(16)])


if __name__ == '__main__':
    main()
