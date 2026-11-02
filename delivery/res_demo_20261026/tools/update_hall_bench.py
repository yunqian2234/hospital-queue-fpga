"""10/26 one-off: add the SW4 resolution-line inputs to verification/ui3/tb_hall_screen.sv."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from edit_keep_eol import Editor  # noqa: E402

LAB = HERE.parents[2]
e = Editor(LAB / 'verification/ui3/tb_hall_screen.sv')
e.rep("//   rej h1 h2 h3 r2 r3 r4 hroom present phy online ready auto err dump sset\n",
      "//   rej h1 h2 h3 r2 r3 r4 hroom present phy online ready auto err dump sset res rpic clo chi\n")
e.rep("// Frames with dump=1 are written to frames.hex.",
      "// 10/26: res = SW4 resolution line; rpic = picture on screen; {chi, clo} = its 60 digit-cell bits\n"
      "// (in the board they come from a block RAM read with the frame-latched picture number, so they\n"
      "// are frame-stable inputs and get no mid-frame noise here; res itself is latched by the screen).\n"
      "// Frames with dump=1 are written to frames.hex.")
e.rep("    reg [7:0] rinv = 0, rdup = 0, rfull = 0, rconf = 0;",
      "    reg [7:0] rinv = 0, rdup = 0, rfull = 0, rconf = 0;\n"
      "    reg res_show = 0;\n    reg [1:0] res_pic = 0;\n    reg [59:0] res_cells = 0;")
e.rep("        .phy_connected(phy), .clinic_online(online), .media_ready(ready), .auto_enabled(auto_en), .media_error(err),\n",
      "        .phy_connected(phy), .clinic_online(online), .media_ready(ready), .auto_enabled(auto_en), .media_error(err),\n"
      "        .res_show(res_show), .res_pic(res_pic), .res_cells(res_cells),\n")
e.rep("    integer v [0:28];", "    integer v [0:32];")
fmt29 = ' '.join(['%d'] * 29)
fmt33 = ' '.join(['%d'] * 33)
e.rep(f'f = $fscanf(vf, "{fmt29}\\n",', f'f = $fscanf(vf, "{fmt33}\\n",')
e.rep("v[25], v[26], v[27], v[28]);", "v[25], v[26], v[27], v[28],\n                        v[29], v[30], v[31], v[32]);")
e.rep("                auto_en = v[25]; err = v[26];\n",
      "                auto_en = v[25]; err = v[26];\n"
      "                res_show = v[29]; res_pic = v[30]; res_cells = {v[32][29:0], v[31][29:0]};\n")
e.rep("                ready = !v[24]; err = 4'd12 - v[26]; hroom = 2'd3 - v[20]; r2 = 5'd11 - v[17];\n",
      "                ready = !v[24]; err = 4'd12 - v[26]; hroom = 2'd3 - v[20]; r2 = 5'd11 - v[17];\n"
      "                res_show = !v[29];\n")
e.rep("        while (f == 29) begin", "        while (f == 33) begin")
e.save()
print('tb_hall_screen.sv updated')
