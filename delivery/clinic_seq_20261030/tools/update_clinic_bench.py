"""10/30 one-off: tb_clinic_ui.sv gets the zidx / ztot columns (need card i of n in the zoom title)."""
from pathlib import Path
BS = chr(92)
p = Path('verification/multiroom/tb_clinic_ui.sv'); t = p.read_text(encoding='utf-8')
fmt25 = ' '.join(['%d'] * 25); fmt27 = ' '.join(['%d'] * 27)
reps = [
 ("//   zcard zvalid zclicks zroom znum dump\n", "//   zcard zvalid zclicks zroom znum zidx ztot dump   (10/30: zidx / ztot = \"需求 i/n\")\n"),
 ("    reg [2:0] aops = 0, bops = 0, zcard = 0;", "    reg [2:0] aops = 0, bops = 0, zcard = 0, zidx = 0, ztot = 0;"),
 (".zoom_help(zoom_card == 3'd4), .zoom_room(zroom), .zoom_number(znum),\n        .out_de(osd_de)",
  ".zoom_help(zoom_card == 3'd4), .zoom_room(zroom), .zoom_number(znum),\n        .zoom_idx(zidx), .zoom_total(ztot),\n        .out_de(osd_de)"),
 ("    integer v [0:24];", "    integer v [0:26];"),
 ('f = $fscanf(vf, "' + fmt25 + BS + 'n",', 'f = $fscanf(vf, "' + fmt27 + BS + 'n",'),
 ("v[13], v[14], v[15], v[16], v[17], v[18], v[19], v[20], v[21], v[22], v[23], v[24]);",
  "v[13], v[14], v[15], v[16], v[17], v[18], v[19], v[20], v[21], v[22], v[23], v[24], v[25], v[26]);"),
 ("zvalid = v[20]; zclicks = v[21]; zroom = v[22]; znum = v[23];", "zvalid = v[20]; zclicks = v[21]; zroom = v[22]; znum = v[23]; zidx = v[24]; ztot = v[25];"),
 ("zroom = 2'd3 - v[22]; znum = 5'd20 - v[23];", "zroom = 2'd3 - v[22]; znum = 5'd20 - v[23]; zidx = 3'd7 - v[24]; ztot = 3'd7 - v[25];"),
 ("dump_this = v[24];", "dump_this = v[26];"),
]
for a, b in reps:
    assert t.count(a) == 1, a; t = t.replace(a, b)
p.write_text(t, encoding='utf-8')
print([l for l in t.splitlines() if 'while (f ==' in l])
