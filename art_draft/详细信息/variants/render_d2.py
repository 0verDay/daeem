# -*- coding: utf-8 -*-
"""D 方案修订版：左列表 + 左头像卡 + 右详情（属性行压扁，不三等分）。

Changes requested:
  · names: 部队之一 / 部队之二; units: 御林军 / 投石车
  · narrower panel (760 px) because names are short
  · list name + count moved up a little
  · portrait card no longer repeats tags / 5-11
  · right detail: attribute row short, the other two rows share the rest
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import render_variants as R

OUT = Path(__file__).parent
BASE = R.BASE

# ---------------------------------------------------------------- geometry
PANEL = (562, 820, 1322, 1080)          # 760 x 260, still next to the faction block
PAD = 10
LIST_X, LIST_Y, LIST_W, LIST_H = 572, 830, 185, 240
RIGHT_X = LIST_X + LIST_W + 10           # 767
PORTRAIT_W = 190
DETAIL_X = RIGHT_X + PORTRAIT_W + 10     # 967
DETAIL_W = PANEL[2] - PAD - DETAIL_X     # 345
DETAIL_Y, DETAIL_H = 830, 210
TAGS = "步兵 / 近战"
GEN = ["铁壁", "稳定", "横扫"]
UNIT = ["近战减伤 +30%", "远程减伤 +30%", "稳定"]

# ---------------------------------------------------------------- draw helpers
def draw_panel(d):
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], fill=(25, 34, 45))
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], outline=R.LINE, width=2)
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=(14, 20, 29))
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1],
                outline=R.LINE_SOFT, width=1)


def draw_list(d):
    hx, hy, hw, hh = LIST_X + 1, LIST_Y + 1, LIST_W - 2, 54
    # focused troop
    d.rectangle([hx, hy, hx + hw - 1, hy + hh - 1], fill=(48, 45, 36))
    d.rectangle([hx, hy, hx + 2, hy + hh - 1], fill=R.ACCENT)
    R.draw_icon(d, hx + 7, hy + 7, 32, "1", 18, hp=1.0, morale=0.85)
    R.txt(d, (hx + 46, hy + 28), "部队之一", 13, R.TEXT)
    R.txt(d, (hx + 46, hy + 44), "5/11", 11, R.TEXT_DIM)
    R.txt(d, (hx + hw - 10, hy + 28), "▾", 11, R.TEXT_FAINT, anchor="rs")

    units = [("子刹", "将", False, 1.0),
             ("御林军", "盾", True, 0.82),
             ("投石车", "车", False, 0.64)]
    uy = hy + hh
    for i, (name, ch, sel, hp) in enumerate(units):
        rh = 36
        if sel:
            d.rectangle([hx, uy, hx + hw - 1, uy + rh - 1], fill=(55, 49, 36))
            d.rectangle([hx + 1, uy, hx + 2, uy + rh - 1], fill=R.ACCENT)
        R.draw_icon(d, hx + 18, uy + 6, 24, ch, 13, hp=hp)
        R.txt(d, (hx + 50, uy + 24), name, 13, R.TEXT if sel else R.TEXT_DIM)
        if i == 0:
            R.txt(d, (hx + hw - 10, uy + 24), "将", 10, R.ACCENT, anchor="rs")
        uy += rh

    # second, collapsed troop
    hy2 = uy
    hh2 = LIST_Y + LIST_H - hy2 - 1
    d.rectangle([hx, hy2, hx + hw - 1, hy2 + hh2 - 1], fill=(33, 42, 52))
    d.rectangle([hx, hy2 + hh2 - 1, hx + hw - 1, hy2 + hh2 - 1], fill=R.LINE_SOFT)
    R.draw_icon(d, hx + 7, hy2 + 7, 32, "2", 18, hp=1.0, morale=0.66)
    R.txt(d, (hx + 46, hy2 + 28), "部队之二", 13, R.TEXT)
    R.txt(d, (hx + 46, hy2 + 44), "4/11", 11, R.TEXT_DIM)
    R.txt(d, (hx + hw - 10, hy2 + 28), "▸", 11, R.TEXT_FAINT, anchor="rs")


def draw_portrait(d):
    x = RIGHT_X + 8
    R.draw_icon(d, x, 838, 72, "盾", 38, hp=0.82, fill=(17, 24, 34))
    R.txt(d, (x, 936), "部队之一", 22, R.TEXT)
    R.txt(d, (x, 960), "御林军", 13, R.TEXT_DIM)


def draw_gen_inline(d, x, baseline):
    xx = x
    for i, name in enumerate(GEN):
        R.txt(d, (xx, baseline), name, 15, R.ACCENT)
        R.dotted_underline(d, xx, baseline + 3, name, 15, (120, 95, 45))
        xx += R.tw(name, 15)
        if i < len(GEN) - 1:
            R.txt(d, (xx, baseline), "    ", 15, R.TEXT_FAINT)
            xx += R.tw("    ", 15)


def draw_detail(d):
    x0, y0 = DETAIL_X, DETAIL_Y
    x1, y1 = DETAIL_X + DETAIL_W - 1, DETAIL_Y + DETAIL_H - 1
    d.rectangle([x0, y0, x1, y1], fill=(10, 15, 22))
    d.rectangle([x0, y0, x1, y1], outline=R.LINE_SOFT, width=1)

    # 38 / 76 / 96  —— 属性行刻意压短，不再三等分
    rows = [(y0, 38), (y0 + 38, 76), (y0 + 114, 96)]
    for i in range(1, 3):
        yy = rows[i][0]
        d.line([(x0 + 12, yy), (x1 - 12, yy)], fill=R.LINE_SOFT, width=1)

    label_x = x0 + 12
    content_x = x0 + 76

    # 1) attributes (short row)
    cy = rows[0][0] + rows[0][1] / 2
    R.txt(d, (label_x, cy), "属性", 11, R.TEXT_FAINT, anchor="lm")
    R.txt(d, (content_x, cy), TAGS, 15, R.TEXT, anchor="lm")

    # 2) general traits
    cy = rows[1][0] + rows[1][1] / 2
    R.txt(d, (label_x, cy), "将领特性", 11, R.TEXT_FAINT, anchor="lm")
    draw_gen_inline(d, content_x, cy + 5)

    # 3) unit traits
    cy = rows[2][0] + rows[2][1] / 2
    R.txt(d, (label_x, cy), "单位特性", 11, R.TEXT_FAINT, anchor="lm")
    yy = cy - 20
    for line in UNIT:
        R.txt(d, (content_x, yy), line, 13, R.TEXT_DIM, anchor="lm")
        yy += 20


def bottom_context(img):
    d = ImageDraw.Draw(img)
    # remove the stale screenshot bar
    d.rectangle([400, 820, 1550, 1080], fill=(35, 46, 54))
    # the narrower panel leaves the map visible to its right (plain terrain, no props)
    d.rectangle([1322, 820, 1550, 1080], fill=(52, 62, 44))
    d.line([(1322, 948), (1550, 922)], fill=(70, 80, 60), width=2)
    d.line([(1322, 1016), (1550, 1040)], fill=(44, 53, 38), width=2)
    # faction placeholder
    d.rectangle([400, 820, 562, 1080], fill=(39, 50, 58))
    d.rectangle([400, 820, 562, 1080], outline=R.LINE_SOFT, width=1)
    poly = [(446, 876), (516, 876), (516, 934), (481, 964), (446, 934)]
    d.polygon(poly, outline=R.LINE, width=2)
    R.txt(d, (481, 900), "盾", 26, R.TEXT_FAINT, anchor="mm")
    R.txt(d, (481, 990), "阵营盾徽", 13, R.TEXT_FAINT, anchor="ms")
    R.txt(d, (481, 1012), "旗帜 · 占位", 11, R.TEXT_FAINT, anchor="ms")


def main():
    img = BASE.copy().convert("RGB")
    bottom_context(img)
    d = ImageDraw.Draw(img)
    draw_panel(d)
    draw_list(d)
    draw_portrait(d)
    draw_detail(d)
    img.crop((0, 0, 1600, 1080)).save(OUT / "variant_D2.png", quality=95)

    crop = (555, 812, 1332, 1080)
    im = Image.open(OUT / "variant_D2.png").crop(crop)
    im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
    im.save(OUT / "variant_D2_zoom.png")
    print("wrote variant_D2.png / variant_D2_zoom.png")


if __name__ == "__main__":
    main()
