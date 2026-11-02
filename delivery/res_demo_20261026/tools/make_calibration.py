"""10/26 calibration BMPs for the 扩展要求3 defence (they carry no resolution text on purpose: the
board prints the size it read from the file header itself, SW4).

Each picture W×H has, scaled to its own size:
  * a light blue-grey page (so the warm-white letterbox around a 16:9 or portrait picture is visible)
  * a red frame on the very edge, thick enough to survive the downscale: the frame complete on the
    HDMI screen = nothing cropped
  * a circle and a square of the same size: still round / square on the screen = aspect kept
  * coloured corner blocks (red top-left, green top-right, blue bottom-left, amber bottom-right):
    orientation (a bottom-up BMP shown the right way up, not mirrored)
  * tick marks every 10 % of the width / height along the edges
  * three stripe patches of 1, 2 and 4 source pixels: the area average turns detail finer than a
    screen pixel into a flat or low-contrast grey instead of moire (2x: 1-px stripes flat grey;
    3x: 1-px stripes a faint 1/3-2/3 grey pattern); the exact look is in the preview PNGs
Plus two files the board must refuse (E01): 2000×1000 (too wide) and 600×400 (too small).
Usage: python make_calibration.py <output dir>   (previews in <output dir>/preview, board_preview.py)
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from bmp_io import write_bmp  # noqa: E402
import board_preview  # noqa: E402

SIZES = [(1920, 1080), (1600, 1000), (1366, 768), (1280, 1024), (1024, 768), (800, 600), (768, 1024),
         (640, 480)]
REJECT = [(2000, 1000), (600, 400)]
PAGE, INK, RED, GREEN, BLUE, AMBER = (220, 230, 240), (31, 41, 51), (214, 69, 69), (46, 158, 91), (41, 101, 192), (240, 140, 0)
FONT = 'C:/Windows/Fonts/msyhbd.ttc'


def card(w, h):
    im = Image.new('RGB', (w, h), PAGE)
    d = ImageDraw.Draw(im)
    k = math.ceil(max(w / 640, h / 480))                 # source pixels per screen pixel (about)
    t = 3 * k                                             # frame: about 3 screen pixels
    d.rectangle([0, 0, w - 1, h - 1], outline=RED, width=t)
    m = min(w, h)
    cb = int(m * 0.08)
    for (x, y), c in zip([(t, t), (w - t - cb, t), (t, h - t - cb), (w - t - cb, h - t - cb)], [RED, GREEN, BLUE, AMBER]):
        d.rectangle([x, y, x + cb - 1, y + cb - 1], fill=c)
    for i in range(1, 10):                                # 10 % ticks
        x, y = round(w * i / 10), round(h * i / 10)
        L = int(m * (0.05 if i == 5 else 0.03))
        d.rectangle([x - k, t, x + k - 1, t + L], fill=INK)
        d.rectangle([x - k, h - t - L, x + k - 1, h - t - 1], fill=INK)
        d.rectangle([t, y - k, t + L, y + k - 1], fill=INK)
        d.rectangle([w - t - L, y - k, w - t - 1, y + k - 1], fill=INK)
    s = int(m * 0.36)                                     # circle and square, same size
    cy = int(h * 0.42)
    cx1, cx2 = int(w * 0.30), int(w * 0.70)
    lw = max(2, 2 * k)
    d.ellipse([cx1 - s // 2, cy - s // 2, cx1 + s // 2, cy + s // 2], outline=BLUE, width=lw)
    d.line([cx1 - s // 2, cy, cx1 + s // 2, cy], fill=BLUE, width=max(1, k))
    d.line([cx1, cy - s // 2, cx1, cy + s // 2], fill=BLUE, width=max(1, k))
    d.rectangle([cx2 - s // 2, cy - s // 2, cx2 + s // 2, cy + s // 2], outline=GREEN, width=lw)
    f = ImageFont.truetype(FONT, int(m * 0.045))
    d.text((cx1, cy + s // 2 + int(m * 0.02)), '正圆', font=f, fill=INK, anchor='mt')
    d.text((cx2, cy + s // 2 + int(m * 0.02)), '正方形', font=f, fill=INK, anchor='mt')
    d.text((w // 2, int(m * 0.09)), '分辨率标定图', font=ImageFont.truetype(FONT, int(m * 0.06)), fill=INK, anchor='mt')
    pw, ph = int(w * 0.22), int(h * 0.14)                 # stripe patches 1 / 2 / 4 px
    y0 = int(h * 0.74)
    for n, period in enumerate((1, 2, 4)):
        x0 = int(w * (0.12 + 0.27 * n))
        for x in range(pw):
            if (x // period) % 2 == 0:
                d.line([x0 + x, y0, x0 + x, y0 + ph - 1], fill=(0, 0, 0))
            else:
                d.line([x0 + x, y0, x0 + x, y0 + ph - 1], fill=(255, 255, 255))
        d.text((x0 + pw // 2, y0 + ph + int(m * 0.01)), f'{period} 像素条纹', font=f, fill=INK, anchor='mt')
    return im


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    prev = out / 'preview'
    prev.mkdir(exist_ok=True)
    for i, (w, h) in enumerate(SIZES + REJECT):
        name = f'CAL{i + 1:02d}.BMP'
        write_bmp(out / name, card(w, h))
        board_preview.preview(out / name, prev, ui=True, pic=1)


if __name__ == '__main__':
    main(sys.argv[1])
