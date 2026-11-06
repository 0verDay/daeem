# -*- coding: utf-8 -*-
"""D4：金色列表边框 / 详情下移收窄 / 大部队图标 / 招募队列 demo。

Two images:
  variant_D4_unit.png  —— unit page: troop icon gold fill + unit button fill + ×3 badge
  variant_D4_order.png —— order page: same queue, with the new 停招 cell
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import render_variants as R

OUT = Path(__file__).parent
BASE = R.BASE

# ---------------------------------------------------------------- geometry
PANEL = (562, 820, 1262, 1080)            # 700 x 260 (narrowed)
LIST_X, LIST_Y, LIST_W, LIST_H = 564, 822, 185, 256
LIST_FRAME = (564, 822, 749, 1078)        # gold stroke around the list
ICON_CELL = 54                             # 54 x 54: 40 icon + 7 px on each side
TROOP_ICON = 40
ICON_COL_X = LIST_X + LIST_W + 10          # 759
ICON_X, ICON_Y, ICON_S = ICON_COL_X + 8, 838, 72
DETAIL_X = ICON_X + ICON_S + 10            # 849
DETAIL_RIGHT = 1252
DETAIL_W = DETAIL_RIGHT - DETAIL_X         # 403
DETAIL_Y, DETAIL_H = 842, 198
TAGS = "步兵 / 近战"
GEN = ["铁壁", "稳定", "横扫"]
UNIT = ["近战减伤 +30%", "远程减伤 +30%", "稳定"]

CARD_X, CARD_Y, CARD_W, CARD_H = 1552, 820, 260, 260
CELL = CARD_W / 3.0
TAB_X, TAB_W = CARD_X + CARD_W, 1920 - (CARD_X + CARD_W)

QUEUE_FILL = 0.60          # 60% progress for the demo


def draw_panel(d):
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], fill=(25, 34, 45))
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], outline=R.LINE, width=2)
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=(14, 20, 29))
    # gold stroke around the whole list
    d.rectangle([LIST_FRAME[0], LIST_FRAME[1], LIST_FRAME[2], LIST_FRAME[3]],
                outline=R.ACCENT, width=2)


def draw_header_row(d, y, name, count, number, queue=None):
    h = 54
    d.rectangle([LIST_X, y, LIST_X + LIST_W - 1, y + h - 1], fill=(22, 30, 40))
    d.line([(LIST_X, y + h - 1), (LIST_X + LIST_W - 1, y + h - 1)], fill=R.LINE_SOFT, width=1)
    # 54 x 54 icon cell, 40 icon centered => 7 px on all four sides
    ix, iy = LIST_X + 7, y + 7
    d.rectangle([LIST_X, y, LIST_X + ICON_CELL - 1, y + h - 1], fill=(17, 24, 34))
    if queue is None:
        # normal troop: morale fill stays as before
        d.rectangle([ix, iy, ix + TROOP_ICON - 1, iy + TROOP_ICON - 1], fill=(45, 60, 38))
        d.rectangle([ix, iy, ix + TROOP_ICON - 1, iy + TROOP_ICON - 1], outline=R.LINE, width=1)
        d.text((ix + TROOP_ICON / 2, iy + TROOP_ICON / 2 + 1), number,
               font=R.F[22], fill=R.TEXT, anchor="mm", stroke_width=1,
               stroke_fill=(20, 14, 6))
        d.rectangle([ix + 1, iy + TROOP_ICON - 4, ix + 1 + (TROOP_ICON - 3) * 0.66,
                     iy + TROOP_ICON - 2], fill=R.HP_MID)
    else:
        # recruiting troop: gold fill rises from the bottom
        d.rectangle([ix, iy, ix + TROOP_ICON - 1, iy + TROOP_ICON - 1], fill=(17, 24, 34))
        fh = int(round((TROOP_ICON - 2) * queue))
        if fh > 0:
            d.rectangle([ix + 1, iy + TROOP_ICON - 1 - fh, ix + TROOP_ICON - 2,
                         iy + TROOP_ICON - 2], fill=(168, 122, 34))
            d.line([(ix + 1, iy + TROOP_ICON - 1 - fh),
                    (ix + TROOP_ICON - 2, iy + TROOP_ICON - 1 - fh)],
                   fill=R.ACCENT_BRIGHT, width=1)
        d.rectangle([ix, iy, ix + TROOP_ICON - 1, iy + TROOP_ICON - 1], outline=R.ACCENT, width=1)
        d.text((ix + TROOP_ICON / 2, iy + TROOP_ICON / 2 + 1), number,
               font=R.F[22], fill=R.TEXT, anchor="mm", stroke_width=1,
               stroke_fill=(20, 14, 6))

    R.txt(d, (LIST_X + ICON_CELL + 8, y + 34), name, 13, R.TEXT)
    R.txt(d, (LIST_X + LIST_W - 8, y + 34), count, 11, R.TEXT_DIM, anchor="rs")


def draw_list(d):
    draw_header_row(d, LIST_Y, "部队之一", "5/11", "1", queue=QUEUE_FILL)

    units = [("子刹", "将", False),
             ("御林军", "盾", True),
             ("投石车", "车", False)]
    uy = LIST_Y + 54
    for i, (name, ch, sel) in enumerate(units):
        rh = 36
        if sel:
            d.rectangle([LIST_X, uy, LIST_X + LIST_W - 1, uy + rh - 1], fill=(55, 49, 36))
            d.rectangle([LIST_X, uy, LIST_X + 2, uy + rh - 1], fill=R.ACCENT)
        # center the 24 icon in the same 54-wide column as the 40 troop icon
        ix = LIST_X + (ICON_CELL - 24) // 2
        iy = uy + 6
        if sel:
            d.rectangle([ix, iy, ix + 23, iy + 23], outline=R.ACCENT, width=1)
        else:
            d.rectangle([ix, iy, ix + 23, iy + 23], outline=R.LINE_SOFT, width=1)
        R.txt(d, (ix + 12, iy + 13), ch, 13, R.TEXT, anchor="mm")
        d.rectangle([ix, iy + 20, ix + 23, iy + 22], fill=(0, 0, 0))
        d.rectangle([ix, iy + 20, ix + 15, iy + 22], fill=R.HP_HIGH)
        R.txt(d, (LIST_X + ICON_CELL + 8, uy + 24), name, 13, R.TEXT if sel else R.TEXT_DIM)
        if i == 0:
            R.txt(d, (LIST_X + LIST_W - 8, uy + 24), "将", 10, R.ACCENT, anchor="rs")
        uy += rh

    draw_header_row(d, uy, "部队之二", "4/11", "2", queue=None)


def draw_portrait(d):
    R.draw_icon(d, ICON_X, ICON_Y, ICON_S, "盾", 38, hp=0.82, fill=(17, 24, 34))
    cx = ICON_X + ICON_S / 2
    R.txt(d, (cx, 936), "部队之一", 17, R.TEXT, anchor="ms")
    R.txt(d, (cx, 960), "御林军", 13, R.TEXT_DIM, anchor="ms")


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

    rows = [(y0, 38), (y0 + 38, 74), (y0 + 112, 86)]
    for i in range(1, 3):
        d.line([(x0 + 12, rows[i][0]), (x1 - 12, rows[i][0])], fill=R.LINE_SOFT, width=1)

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


# ---------------------------------------------------------------- command card
KEYS = ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"]

UNIT_PAGE = [
    ("长枪兵", "枪", 0.60, 3),
    ("长弓兵", "弓", 0.0, 0),
    ("骑手", "骑", 0.0, 0),
    ("投石车", "车", 0.0, 0),
    ("剑士", "剑", 0.0, 0),
    ("弓手", "弓", 0.0, 0),
    ("骑士", "骑", 0.0, 0),
    ("马弓手", "马", 0.0, 0),
    ("投石车", "车", 0.0, 0),
]

ORDER_PAGE = ["移动", "攻击", "行军", "停止", "停招", "", "", "", ""]


def card_frame(d, active_tab):
    d.rectangle([CARD_X, CARD_Y, CARD_X + CARD_W - 1, CARD_Y + CARD_H - 1], fill=(25, 34, 45))
    d.rectangle([CARD_X, CARD_Y, CARD_X + CARD_W - 1, CARD_Y + CARD_H - 1],
                outline=R.LINE, width=2)
    for i in range(1, 3):
        d.line([(CARD_X + CELL * i, CARD_Y), (CARD_X + CELL * i, CARD_Y + CARD_H)],
               fill=R.LINE_SOFT, width=1)
        d.line([(CARD_X, CARD_Y + CELL * i), (CARD_X + CARD_W, CARD_Y + CELL * i)],
               fill=R.LINE_SOFT, width=1)
    # tabs
    d.rectangle([TAB_X, CARD_Y, 1919, CARD_Y + CARD_H - 1], fill=(25, 34, 45))
    d.rectangle([TAB_X, CARD_Y, 1919, CARD_Y + CARD_H - 1], outline=R.LINE, width=1)
    labels = ["操作", "单位"]
    for i, lab in enumerate(labels):
        ty = CARD_Y + i * (CARD_H / 2)
        active = (lab == active_tab)
        d.rectangle([TAB_X, ty, 1919, ty + CARD_H / 2 - 1],
                    fill=R.ACCENT if active else (20, 28, 38))
        color = (26, 18, 6) if active else R.ACCENT
        R.txt(d, (TAB_X + TAB_W / 2, ty + 52), lab[0], 17, color, anchor="mm")
        R.txt(d, (TAB_X + TAB_W / 2, ty + 78), lab[1], 17, color, anchor="mm")


def unit_page(d):
    card_frame(d, "单位")
    for i, (name, ch, prog, count) in enumerate(UNIT_PAGE):
        cx = CARD_X + (i % 3) * CELL
        cy = CARD_Y + (i // 3) * CELL
        # progress fill
        if prog > 0:
            fh = int(round(CELL * prog))
            d.rectangle([cx + 1, cy + CELL - fh, cx + CELL - 2, cy + CELL - 2],
                        fill=(80, 60, 22))
            d.line([(cx + 1, cy + CELL - fh), (cx + CELL - 2, cy + CELL - fh)],
                   fill=R.ACCENT_BRIGHT, width=2)
            d.rectangle([cx, cy, cx + CELL - 1, cy + CELL - 1], outline=R.ACCENT, width=2)
        R.txt(d, (cx + 5, cy + 15), KEYS[i], 10, R.TEXT_FAINT)
        R.txt(d, (cx + CELL / 2, cy + CELL / 2 - 4), ch, 28, R.ACCENT, anchor="mm")
        d.rectangle([cx + 1, cy + CELL - 16, cx + CELL - 2, cy + CELL - 2], fill=(12, 18, 26))
        R.txt(d, (cx + CELL / 2, cy + CELL - 6), name, 11, R.TEXT_DIM, anchor="mm")
        if count > 0:
            bw, bh = 22, 17
            bx, by = cx + CELL - bw - 3, cy + CELL - bh - 2
            d.rectangle([bx, by, bx + bw, by + bh], fill=(12, 18, 26), outline=R.ACCENT, width=1)
            R.txt(d, (bx + bw / 2, by + bh / 2 + 1), "×%d" % count, 10, R.ACCENT, anchor="mm")


def order_page(d):
    card_frame(d, "操作")
    for i, name in enumerate(ORDER_PAGE):
        if name == "":
            continue
        cx = CARD_X + (i % 3) * CELL
        cy = CARD_Y + (i // 3) * CELL
        R.txt(d, (cx + 5, cy + 15), KEYS[i], 10, R.TEXT_FAINT)
        col = R.WARN if name == "停招" else R.ACCENT
        if name == "停招":
            d.rectangle([cx + 1, cy + 1, cx + CELL - 2, cy + CELL - 2],
                        outline=R.WARN, width=2)
        R.txt(d, (cx + CELL / 2, cy + CELL / 2 + 4), name, 15, col, anchor="mm")


def bottom_context(img):
    d = ImageDraw.Draw(img)
    d.rectangle([400, 820, 1920, 1080], fill=(35, 46, 54))
    d.rectangle([PANEL[2], 820, CARD_X, 1080], fill=(52, 62, 44))
    d.line([(PANEL[2], 948), (CARD_X, 922)], fill=(70, 80, 60), width=2)
    d.line([(PANEL[2], 1016), (CARD_X, 1040)], fill=(44, 53, 38), width=2)
    d.rectangle([400, 820, 562, 1080], fill=(39, 50, 58))
    d.rectangle([400, 820, 562, 1080], outline=R.LINE_SOFT, width=1)
    poly = [(446, 876), (516, 876), (516, 934), (481, 964), (446, 934)]
    d.polygon(poly, outline=R.LINE, width=2)
    R.txt(d, (481, 900), "盾", 26, R.TEXT_FAINT, anchor="mm")
    R.txt(d, (481, 990), "阵营盾徽", 13, R.TEXT_FAINT, anchor="ms")
    R.txt(d, (481, 1012), "旗帜 · 占位", 11, R.TEXT_FAINT, anchor="ms")


def render(name, page_fn):
    img = BASE.copy().convert("RGB")
    bottom_context(img)
    d = ImageDraw.Draw(img)
    draw_panel(d)
    draw_list(d)
    draw_portrait(d)
    draw_detail(d)
    page_fn(d)
    img.save(OUT / name, quality=95)
    print("wrote", name)


def main():
    render("variant_D4_unit.png", unit_page)
    render("variant_D4_order.png", order_page)
    crop = (555, 812, 1270, 1080)
    im = Image.open(OUT / "variant_D4_unit.png").crop(crop)
    im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
    im.save(OUT / "variant_D4_zoom.png")
    print("wrote variant_D4_zoom.png")


if __name__ == "__main__":
    main()
