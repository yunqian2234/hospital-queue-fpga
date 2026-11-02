"""10/26 BMP helpers shared by the photo converter, the calibration generator and the preview tool.

write_bmp: 24-bit uncompressed bottom-up BMP with a 40-byte BITMAPINFOHEADER - the format
bmp_stream_decode accepts (also what Windows Paint writes for "24 位位图").
read_bmp: parses a BMP with the same acceptance rules as bmp_stream_decode (BM, planes 1,
24 bit, BI_RGB, positive height = bottom-up, pixel data inside the file, 640x480 .. 1920x1080)
and says why a file would be rejected (the board shows error code E01 for those).
"""
import struct
from pathlib import Path

import numpy as np

MIN_W, MIN_H, MAX_W, MAX_H = 640, 480, 1920, 1080


def write_bmp(path, img):
    a = np.asarray(img.convert('RGB'))
    h, w = a.shape[:2]
    stride = (w * 3 + 3) & ~3
    pad = bytes(stride - w * 3)
    pix = b''.join(a[y, :, ::-1].tobytes() + pad for y in range(h - 1, -1, -1))
    head = b'BM' + struct.pack('<IHHI', 54 + len(pix), 0, 0, 54)
    dib = struct.pack('<IiiHHIIiiII', 40, w, h, 1, 24, 0, len(pix), 2835, 2835, 0, 0)
    Path(path).write_bytes(head + dib + pix)


def read_bmp(path):
    """Returns (rgb array (H, W, 3) top-down, None) or (None, reason) like the board decoder."""
    d = Path(path).read_bytes()
    if len(d) < 54 or d[:2] != b'BM':
        return None, '不是 BMP 文件'
    file_len, = struct.unpack_from('<I', d, 2)
    off, dib, w, h, planes, bpp, comp = struct.unpack_from('<IIiiHHI', d, 10)
    if planes != 1 or bpp != 24 or comp != 0:
        return None, f'不是 24 位无压缩 BMP（{bpp} 位，压缩方式 {comp}）'
    if h <= 0:
        return None, '自上而下存储的 BMP（高度为负）不支持'
    if not (MIN_W <= w <= MAX_W and MIN_H <= h <= MAX_H):
        return None, f'尺寸 {w}×{h} 超出 {MIN_W}×{MIN_H} ~ {MAX_W}×{MAX_H}'
    stride = (w * 3 + 3) & ~3
    if off < 14 + dib or off + stride * h > min(file_len, len(d)):
        return None, '文件头里的长度或数据位置不对'
    rows = np.frombuffer(d, np.uint8, stride * h, off).reshape(h, stride)[:, :w * 3].reshape(h, w, 3)
    return rows[::-1, :, ::-1].copy(), None
