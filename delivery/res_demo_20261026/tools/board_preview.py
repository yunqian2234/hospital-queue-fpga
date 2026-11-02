"""10/26 board preview: what the hall board will show for any BMP, before copying it to the TF card.

For every BMP given (files or folders):
  * checks it the way the board's decoder does (24-bit uncompressed bottom-up, 640x480 .. 1920x1080);
    a rejected file is reported with the reason (the board shows 图片错误 E01 and skips it)
  * scales it with scaler_ref.py - the bit-exact model the RTL scaler is regression-tested against
    (area average + bilinear, aspect kept, centred, warm-white #FAFAF9 fill)
  * writes <name>_board.png (the 640x480 picture in the frame buffer) and, with --ui, <name>_hall.png:
    the whole hall screen (ui3_ref.py, the reference of the RTL screen) with SW4 up, i.e. the bottom
    line "PICn.BMP  原图 W×H → 显示 w×h" the board will print
  * prints the numbers to predict on a whiteboard: shown size, area-average factor k, borders
Usage: python board_preview.py <bmp or folder> [...] [--out DIR] [--ui] [--pic N]
       (the picture number defaults to the N of a PICN.BMP file name, else 1)
"""
import argparse
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(LAB / 'verification/image_scale'))
sys.path.insert(0, str(LAB / 'verification/ui3'))
from bmp_io import read_bmp  # noqa: E402
import scaler_ref  # noqa: E402


def board_picture(rgb):
    """rgb: (H, W, 3) top-down. Returns the 640x480 top-down frame and the fit info."""
    h, w = rgb.shape[:2]
    src = np.ascontiguousarray(rgb[::-1, :, ::-1])            # BMP order: bottom-up, B G R
    shown, info = scaler_ref.scale(src, w, h)
    return shown[::-1, :, ::-1], info


def hall_screen(frame, pic, w, h, fw, fh):
    import ui3_ref as R
    f = dict(call=6, issued=20, waiting=14, needs=0, help=0, lroom=1, vstatus=0, bri=0, con=0, volmode=0,
             music=2, voice=10, rej=0, h1=5, h2=4, h3=3, hroom=0, present=3, phy=1, online=1, ready=1,
             auto=1, err=0, res=1, rpic=pic - 1, rooms=[5, 6, 0, 0], cells=R.res_cells(w, h, fw, fh))
    v = R.HallState().step(f)
    photo = [int(r) << 16 | int(g) << 8 | int(b) for r, g, b in frame.reshape(-1, 3)]
    px = R.hall_frame(v, photo)
    im = Image.new('RGB', (640, 480))
    im.putdata([(c >> 16, c >> 8 & 255, c & 255) for c in px])
    return im


def preview(path, out, ui=False, pic=None):
    rgb, err = read_bmp(path)
    name = Path(path).stem
    if err:
        print(f'{Path(path).name}: 板子会拒绝（图片错误 E01）：{err}')
        return None
    h, w = rgb.shape[:2]
    frame, f = board_picture(rgb)
    Image.fromarray(frame).save(out / f'{name}_board.png')
    top = 480 - f['Ho'] - f['y0']                           # rows are placed in BMP (bottom-up) order
    lr = f'左 {f["x0"]} 列 / 右 {640 - f["Wo"] - f["x0"]} 列'
    tb = f'上 {top} 行 / 下 {f["y0"]} 行'
    edge = '铺满全屏' if (f['Wo'], f['Ho']) == (640, 480) else (lr if f['Wo'] < 640 else tb) + ' 暖白留边'
    print(f'{Path(path).name}: 原图 {w}×{h} → 显示 {f["Wo"]}×{f["Ho"]}，先 {f["k"]}×{f["k"]} 区域平均'
          f'{"（不需要）" if f["k"] == 1 else ""}，{edge}')
    if ui:
        m = re.search(r'PIC(\d)', name, re.I)
        n = pic or (int(m.group(1)) if m else 1)
        hall_screen(frame, n, w, h, f['Wo'], f['Ho']).save(out / f'{name}_hall.png')
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('paths', nargs='+', type=Path)
    ap.add_argument('--out', type=Path)
    ap.add_argument('--ui', action='store_true', help='also render the hall screen with SW4 up')
    ap.add_argument('--pic', type=int, help='picture number shown on the screen (1..4)')
    a = ap.parse_args()
    files = []
    for p in a.paths:
        files += sorted(p.glob('*.[bB][mM][pP]')) if p.is_dir() else [p]
    for p in files:
        out = a.out or p.parent / 'preview'
        out.mkdir(parents=True, exist_ok=True)
        preview(p, out, a.ui, a.pic)


if __name__ == '__main__':
    main()
