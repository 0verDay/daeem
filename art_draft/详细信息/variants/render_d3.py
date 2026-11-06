# -*- coding: utf-8 -*-
"""D3：按最新反馈收口。

  · 选中单位时不再高亮它所属的部队行
  · 左列表贴面板内缘，不留外边距
  · 部队图标与单位图标左对齐（同一条竖线）
  · 部队名 + 编制放同一行（名字左、编制右），不再上下堆
  · 右侧详情面板左移，只和图标留 10px；部队名字号缩到 17（4 字 = 68 < 图标 72）
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import render_variants as R

OUT = Path(__file__).parent
BASE = R.BASE

# ---------------------------------------------------------------- geometry
PANEL = (562, 820, 1322, 1080)          # 760 x 260
LIST_X, LIST_Y, LIST_W, LIST_H = 564, 822, 185, 256   # flush to the panel's inner edge
ICON_COL_X = LIST_X + LIST_W + 10        # 759
ICON_X, ICON_Y, ICON_S = ICON_COL_X + 8, 838, 72      # 767..839
DETAIL_X = ICON_X + ICON_S + 10          # 849
DETAIL_Y, DETAIL_H = 830, 210
DETAIL_W = 1312 - DETAIL_X               # 463
TAGS = "步兵 / 近战"
GEN = ["铁壁", "稳定", "横扫"]
UNIT = ["近战减伤 +30%", "远程减伤 +30%", "稳定"]


def draw_panel(d):
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], fill=(25, 34, 45))
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], outline=R.LINE, width=2)
    # list: flush to the panel's inner border, only a right divider
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=(14, 20, 29))
    d.line([(LIST_X + LIST_W - 1, LIST_Y), (LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1)],
           fill=R.LINE_SOFT, width=1)


def draw_header_row(d, y, name, count, expanded=False, focus=False):
    h = 54
    fill = (22, 30, 40)
    d.rectangle([LIST_X, y, LIST_X + LIST_W - 1, y + h - 1], fill=fill)
    d.line([(LIST_X, y + h - 1), (LIST_X + LIST_W - 1, y + h - 1)], fill=R.LINE_SOFT, width=1)
    # icon and unit icons share the same left edge
    R.draw_icon(d, LIST_X + 4, y + 11, 32, "1" if name == "部队之一" else "2", 18,
                hp=1.0, morale=0.85 if name == "部队之一" else 0.66)
    R.txt(d, (LIST_X + 40, y + 34), name, 13, R.TEXT)
    R.txt(d, (LIST_X + LIST_W - 8, y + 34), count, 11, R.TEXT_DIM, anchor="rs")


def draw_list(d):
    draw_header_row(d, LIST_Y, "部队之一", "5/11", expanded=True)

    units = [("子刹", "将", False, 1.0),
             ("御林军", "盾", True, 0.82),
             ("投石车", "车", False, 0.64)]
    uy = LIST_Y + 54
    for i, (name, ch, sel, hp) in enumerate(units):
        rh = 36
        if sel:
            d.rectangle([LIST_X, uy, LIST_X + LIST_W - 1, uy + rh - 1], fill=(55, 49, 36))
            d.rectangle([LIST_X, uy, LIST_X + 2, uy + rh - 1], fill=R.ACCENT)
        R.draw_icon(d, LIST_X + 4, uy + 6, 24, ch, 13, hp=hp)
        R.txt(d, (LIST_X + 40, uy + 24), name, 13, R.TEXT if sel else R.TEXT_DIM)
        if i == 0:
            R.txt(d, (LIST_X + LIST_W - 8, uy + 24), "将", 10, R.ACCENT, anchor="rs")
        uy += rh

    draw_header_row(d, uy, "部队之二", "4/11", expanded=False)


def draw_portrait(d):
    R.draw_icon(d, ICON_X, ICON_Y, ICON_S, "盾", 38, hp=0.82, fill=(17, 24, 34))
    cx = ICON_X + ICON_S / 2
    R.txt(d, (cx, 934), "部队之一", 17, R.TEXT, anchor="ms")
    R.txt(d, (cx, 958), "御林军", 13, R.TEXT_DIM, anchor="ms")


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

    rows = [(y0, 38), (y0 + 38, 76), (y0 + 114, 96)]
    for i in range(1, 3):
        yy = rows[i][0]
        d.line([(x0 + 12, yy), (x1 - 12, yy)], fill=R.LINE_SOFT, width=1)

    label_x = x0 + 12
    content_x = x0 + 76

    cy = rows[0][0] + rows[0][1] / 2
    R.txt(d, (label_x, cy), "属性", 11, R.TEXT_FAINT, anchor="lm")
    R.txt(d, (content_x, cy), TAGS, 15, R.TEXT, anchor="lm")

    cy = rows[1][0] + rows[1][1] / 2
    R.txt(d, (label_x, cy), "将领特性", 11, R.TEXT_FAINT, anchor="lm")
    draw_gen_inline(d, content_x, cy + 5)

    cy = rows[2][0] + rows[2][1] / 2
    R.txt(d, (label_x, cy), "单位特性", 11, R.TEXT_FAINT, anchor="lm")
    yy = cy - 20
    for line in UNIT:
        R.txt(d, (content_x, yy), line, 13, R.TEXT_DIM, anchor="lm")
        yy += 20


def bottom_context(img):
    d = ImageDraw.Draw(img)
    d.rectangle([400, 820, 1550, 1080], fill=(35, 46, 54))
    d.rectangle([1322, 820, 1550, 1080], fill=(52, 62, 44))
    d.line([(1322, 948), (1550, 922)], fill=(70, 80, 60), width=2)
    d.line([(1322, 1016), (1550, 1040)], fill=(44, 53, 38), width=2)
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
    img.crop((0, 0, 1600, 1080)).save(OUT / "variant_D3.png", quality=95)

    crop = (555, 812, 1332, 1080)
    im = Image.open(OUT / "variant_D3.png").crop(crop)
    im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
    im.save(OUT / "variant_D3_zoom.png")
    print("wrote variant_D3.png / variant_D3_zoom.png")


if __name__ == "__main__":
    main()
