"""10/29: fill the band / G tables of audio_bar_visualizer.v (between the TABLE_ and G_ BEGIN/END
markers) and write the coefficient / window ROM (spectrum_rom.mif for TD, spectrum_rom.hex for
simulation, next to the RTL in display/) from spectrum_model.py.
--check: only report whether the RTL tables and the ROM files match the model.
Usage: python delivery/spectrum_20261029/tools/gen_tables.py RTL.v [--rom-dir DIR] [--check]
"""
import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parents[2]
sys.path.insert(0, str(LAB / 'verification/ui3'))
import spectrum_model as sm  # noqa: E402

IND = ' ' * 12
DISPLAY = LAB / 'src/user_source/hdl_source/display'


def blocks():
    t = [f"{IND}4'd{k}: begin t_m = 3'd{sm.M[k] - 5}; t_off = 9'd{sm.OFF[k]}; end" for k in range(sm.BANDS)]
    g = [f"{IND}8'd{d}: g = 3'd{v};" for d, v in enumerate(sm.G)]
    assert all(0 <= v < 512 for v in sm.OFF) and all(v < 8 for v in sm.G)
    assert sm.PH == [2 * k + 1 for k in range(sm.BANDS)], 'the RTL stagger is cnt + 2k (cnt counted first)'
    return {'TABLE': t, 'G': g}


def rom_files():
    words = sm.rom_words()
    assert len(words) == 64 and all(0 <= v < (1 << 17) for v in words)
    mif = ['DEPTH = 64;', 'WIDTH = 18;', 'ADDRESS_RADIX = HEX;', 'DATA_RADIX = HEX;', 'CONTENT', 'BEGIN']
    mif += [f'{a:03x} : {v:05x};' for a, v in enumerate(words)] + ['END;']
    return '\r\n'.join(mif) + '\r\n', '\r\n'.join(f'{v:05x}' for v in words) + '\r\n'


def fill(text):
    eol = '\r\n' if '\r\n' in text else '\n'
    for name, lines in blocks().items():
        pat = re.compile(rf'(// {name}_BEGIN\r?\n)(.*?)(\s*// {name}_END)', re.S)
        assert len(pat.findall(text)) == 1, name
        text = pat.sub(lambda m: m.group(1) + eol.join(lines) + m.group(3), text)
    return text


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('rtl', type=Path)
    ap.add_argument('--rom-dir', type=Path, default=DISPLAY)
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    old = a.rtl.read_text(encoding='utf-8')
    new = fill(old)
    mif, hx = rom_files()
    pm, ph = a.rom_dir / 'spectrum_rom.mif', a.rom_dir / 'spectrum_rom.hex'
    if a.check:
        same = new == old and pm.is_file() and pm.read_bytes() == mif.encode() and ph.read_bytes() == hx.encode()
        print('tables and ROM match the model' if same else 'TABLES / ROM DIFFER from the model')
        return 0 if same else 1
    a.rtl.write_text(new, encoding='utf-8', newline='')
    pm.write_bytes(mif.encode())
    ph.write_bytes(hx.encode())
    print('tables written', a.rtl, '; ROM', pm, ph)
    return 0


if __name__ == '__main__':
    sys.exit(main())
