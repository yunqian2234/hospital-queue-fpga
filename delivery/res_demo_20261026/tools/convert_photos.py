"""10/26 the team's four AI photos -> PIC1..PIC4.BMP at four different native resolutions.

  1.jpg -> PIC1.BMP 1920x1080 (16:9)   2.jpg -> PIC2.BMP 1024x768 (4:3)
  3.jpg -> PIC3.BMP 1280x720  (16:9)   4.jpg -> PIC4.BMP 800x600  (4:3)
A source with another aspect ratio is centre-cropped to the target ratio first (never
stretched); then Lanczos resize to the exact size; written as 24-bit bottom-up BMP.
Usage: python convert_photos.py <source dir> <output dir>
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from bmp_io import write_bmp, read_bmp  # noqa: E402

TARGETS = [('1', 'PIC1', 1920, 1080), ('2', 'PIC2', 1024, 768), ('3', 'PIC3', 1280, 720), ('4', 'PIC4', 800, 600)]


def find(src, stem):
    for ext in ('.jpg', '.jpeg', '.png', '.bmp', '.webp', '.JPG', '.PNG'):
        if (src / (stem + ext)).exists():
            return src / (stem + ext)
    raise FileNotFoundError(f'{stem}.* not in {src}')


def main(src, out):
    src, out = Path(src), Path(out)
    out.mkdir(parents=True, exist_ok=True)
    for stem, name, w, h in TARGETS:
        p = find(src, stem)
        im = Image.open(p).convert('RGB')
        sw, sh = im.size
        if sw * h > sh * w:                      # wider than the target: crop the sides
            cw = round(sh * w / h)
            box = ((sw - cw) // 2, 0, (sw - cw) // 2 + cw, sh)
        else:                                    # taller: crop top and bottom
            ch = round(sw * h / w)
            box = (0, (sh - ch) // 2, sw, (sh - ch) // 2 + ch)
        crop = box != (0, 0, sw, sh)
        im = im.crop(box)
        if im.size != (w, h):
            im = im.resize((w, h), Image.Resampling.LANCZOS)
        write_bmp(out / f'{name}.BMP', im)
        a, err = read_bmp(out / f'{name}.BMP')
        assert err is None and a.shape == (h, w, 3), err
        print(f'{p.name} {sw}x{sh} -> {name}.BMP {w}x{h}' + (f' (cropped to {box})' if crop else '') +
              f', {(out / (name + ".BMP")).stat().st_size} bytes')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
