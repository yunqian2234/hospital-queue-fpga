"""10/26 one-off: add the SW4 resolution line to verification/ui3/run_ui3_tests.py (keys + H_res)."""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from edit_keep_eol import Editor  # noqa: E402

LAB = HERE.parents[2]
e = Editor(LAB / 'verification/ui3/run_ui3_tests.py')
e.rep("  H_flicker scroll positions where a glyph has one visible column at the ticker's left edge\n",
      "  H_flicker scroll positions where a glyph has one visible column at the ticker's left edge\n"
      "  H_res     10/26 SW4: \"PIC<n>.BMP  原图 W×H → 显示 w×h\" for several resolutions (4-digit and\n"
      "            3-digit widths/heights, portrait), hidden while the photo is loading, an adjust line /\n"
      "            prompt wins, SW4 off brings the ticker back; SW4 gets mid-frame noise (frame-latched)\n")
e.rep("""sys.path.insert(0, str(LAB / 'verification/clinic_cards'))
""", """sys.path.insert(0, str(LAB / 'verification/clinic_cards'))
sys.path.insert(0, str(LAB / 'verification/image_scale'))
""")
e.rep("""from run_screen_tests import load_cards, in_rgb as clinic_in_rgb  # noqa: E402
""", """from run_screen_tests import load_cards, in_rgb as clinic_in_rgb  # noqa: E402
import scaler_ref  # noqa: E402
""")
e.rep("""             'r2 r3 r4 hroom present phy online ready auto err dump sset').split()""",
      """             'r2 r3 r4 hroom present phy online ready auto err dump sset res rpic clo chi').split()""")
e.rep("""             online=1, ready=1, auto=1, err=0, dump=0, sset=-1)
    f.update(kw)
    return f""", """             online=1, ready=1, auto=1, err=0, dump=0, sset=-1, res=0, rpic=0, wh=(640, 480))
    f.update(kw)
    fit = scaler_ref.fit(*f['wh'])                   # shown size (the scaler's rule)
    f['cells'] = R.res_cells(*f['wh'], fit['Wo'], fit['Ho'])
    f['clo'], f['chi'] = R.res_words(f['cells'])
    return f""")
e.rep("""HALL = {'H_rooms': hall_rooms,""", """def hall_res():
    fr = [H(dump=0) for _ in range(4)]
    for pic, wh in enumerate([(1920, 1080), (1024, 768), (1280, 720), (800, 600)]):
        fr += [H(res=1, rpic=pic, wh=wh, dump=1)]
    for wh in [(768, 1024), (641, 481), (1600, 1000), (1919, 1079), (640, 1080)]:
        fr += [H(res=1, rpic=1, wh=wh, dump=1)]
    fr += [H(res=1, rpic=2, wh=(1280, 720), ready=0, dump=1)]            # photo loading: ticker
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=1)]              # adjust line wins
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=k == 6) for k in range(7)]
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, rej=1, waiting=0, dump=1)]   # prompt wins
    fr += [H(res=1, rpic=2, wh=(1280, 720), bri=1, dump=k == 6) for k in range(7)]
    fr += [H(res=0, rpic=2, wh=(1280, 720), bri=1, dump=1)]              # SW4 off: ticker
    return fr


HALL = {'H_res': hall_res, 'H_rooms': hall_rooms,""")
e.rep("""            labels.append('adjust' if v['show_adjust'] else f'prompt{v["prompt_id"]}' if v['show_prompt'] else
                          f'scroll{v["scroll"]}')""",
      """            labels.append('adjust' if v['show_adjust'] else f'prompt{v["prompt_id"]}' if v['show_prompt'] else
                          'res{}x{}'.format(*f['wh']) if f['res'] and f['ready'] else f'scroll{v["scroll"]}')""")
e.save()
print('run_ui3_tests.py updated')
