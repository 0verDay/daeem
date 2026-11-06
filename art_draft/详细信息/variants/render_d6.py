# -*- coding: utf-8 -*-
"""D6：按当前项目 UI 重画（不是旧截图那套）。

  · 左列表选中行用 fill_button 的四边泛光（不是平铺棕底）
  · 右下命令卡用 assets/ui/card_icon 的真实金线蒙版
  · 页签用当前 page_tabs 的「外框 + 单页描边 + 选中金色填充 + 白字/压金黑字」
  · 右上将领槽位改成当前的 6 格（旧截图那 10 格已淘汰）
  · 停招不再标红
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).parent))
import render_variants as R

OUT = Path(__file__).parent
BASE = R.BASE
ROOT = Path(r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem")
ICON_DIR = ROOT / "assets" / "ui" / "card_icon"

PANEL = (562, 820, 1179, 1080)
LIST_X, LIST_Y, LIST_W, LIST_H = 564, 822, 185, 256
LIST_FRAME = (564, 822, 749, 1078)
ICON_CELL = 54
TROOP_ICON = 40
ICON_COL_X = LIST_X + LIST_W + 10
ICON_X, ICON_Y, ICON_S = ICON_COL_X + 8, 838, 72
DETAIL_X = ICON_X + ICON_S + 10
DETAIL_RIGHT = 1169
DETAIL_W = DETAIL_RIGHT - DETAIL_X
DETAIL_Y, DETAIL_H = 838, 202
TAGS = "步兵 / 近战"
GEN = ["铁壁", "稳定", "横扫"]
UNIT = ["近战减伤 +30%", "远程减伤 +30%", "稳定"]

CARD_X, CARD_Y, CARD_W, CARD_H = 1552, 820, 260, 260
CELL = CARD_W / 3.0
TAB_X, TAB_W = CARD_X + CARD_W, 1920 - (CARD_X + CARD_W)
QUEUE_FILL = 0.60

_icon_cache = {}


def unit_icon(name: str, size: int):
    key = (name, size)
    if key in _icon_cache:
        return _icon_cache[key]
    p = ICON_DIR / (name + ".png")
    im = Image.open(p).convert("RGBA").resize((size, size), Image.LANCZOS)
    alpha = im.getchannel("A")
    gold = Image.new("RGBA", (size, size), R.ACCENT)
    gold.putalpha(alpha)
    _icon_cache[key] = gold
    return gold


# ---------------------------------------------------------------- list
def draw_panel(d):
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], fill=(25, 34, 45))
    d.rectangle([PANEL[0], PANEL[1], PANEL[2] - 1, PANEL[3] - 1], outline=R.LINE, width=2)
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=(14, 20, 29))
    d.rectangle([LIST_FRAME[0], LIST_FRAME[1], LIST_FRAME[2], LIST_FRAME[3]],
                outline=R.ACCENT, width=2)


def blend(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def draw_glow_row(d, x0, y0, x1, y1, base, band=6, strength=0.42):
    """fill_button 的四边向内渐隐泛光（金色），预先混到底色上。"""
    d.rectangle([x0, y0, x1, y1], fill=base)
    for i in range(band):
        t = strength * (1.0 - i / float(band))
        col = blend(base, R.ACCENT, t)
        d.line([(x0, y0 + i), (x1, y0 + i)], fill=col, width=1)
        d.line([(x0, y1 - i), (x1, y1 - i)], fill=col, width=1)
        d.line([(x0 + i, y0), (x0 + i, y1)], fill=col, width=1)
        d.line([(x1 - i, y0), (x1 - i, y1)], fill=col, width=1)


def draw_troop_icon(d, x, y, number, queue=None):
    d.rectangle([x, y, x + TROOP_ICON - 1, y + TROOP_ICON - 1], fill=(17, 24, 34))
    if queue is not None and queue > 0.0:
        fh = int(round((TROOP_ICON - 2) * queue))
        d.rectangle([x + 1, y + TROOP_ICON - 1 - fh, x + TROOP_ICON - 2, y + TROOP_ICON - 2],
                    fill=(168, 122, 34))
        d.line([(x + 1, y + TROOP_ICON - 1 - fh), (x + TROOP_ICON - 2, y + TROOP_ICON - 1 - fh)],
               fill=R.ACCENT_BRIGHT, width=1)
    d.rectangle([x, y, x + TROOP_ICON - 1, y + TROOP_ICON - 1],
                outline=R.ACCENT if queue else R.LINE, width=1)
    d.text((x + TROOP_ICON / 2, y + TROOP_ICON / 2 + 1), number, font=R.F[22],
           fill=R.TEXT, anchor="mm", stroke_width=1, stroke_fill=(20, 14, 6))
    d.rectangle([x + 1, y + TROOP_ICON - 4, x + TROOP_ICON - 2, y + TROOP_ICON - 2],
                fill=(0, 0, 0))
    d.rectangle([x + 1, y + TROOP_ICON - 4, x + 1 + (TROOP_ICON - 3) * 0.82,
                 y + TROOP_ICON - 2], fill=R.HP_HIGH)


def draw_header_row(d, y, name, count, number, queue=None):
    h = 54
    d.rectangle([LIST_X, y, LIST_X + LIST_W - 1, y + h - 1], fill=(22, 30, 40))
    d.line([(LIST_X, y + h - 1), (LIST_X + LIST_W - 1, y + h - 1)], fill=R.LINE_SOFT, width=1)
    d.rectangle([LIST_X, y, LIST_X + ICON_CELL - 1, y + h - 1], fill=(17, 24, 34))
    draw_troop_icon(d, LIST_X + 7, y + 7, number, queue)
    R.txt(d, (LIST_X + ICON_CELL + 8, y + 34), name, 13, R.TEXT)
    R.txt(d, (LIST_X + LIST_W - 8, y + 34), count, 11, R.TEXT_DIM, anchor="rs")


def draw_list(d):
    draw_header_row(d, LIST_Y, "部队一", "5/11", "1", queue=QUEUE_FILL)
    units = [("子刹", "将", False), ("御林军", "盾", True), ("投石车", "车", False)]
    uy = LIST_Y + 54
    for i, (name, ch, sel) in enumerate(units):
        rh = 36
        if sel:
            draw_glow_row(d, LIST_X, uy, LIST_X + LIST_W - 1, uy + rh - 1, (22, 30, 40))
            d.rectangle([LIST_X, uy, LIST_X + 1, uy + rh - 1], fill=R.ACCENT)
        else:
            d.rectangle([LIST_X, uy, LIST_X + LIST_W - 1, uy + rh - 1], fill=(14, 20, 29))
        ix = LIST_X + (ICON_CELL - 24) // 2
        iy = uy + 6
        d.rectangle([ix, iy, ix + 23, iy + 23], fill=(17, 24, 34),
                    outline=R.ACCENT_BRIGHT if sel else R.LINE_SOFT, width=1)
        R.txt(d, (ix + 12, iy + 13), ch, 13, R.TEXT, anchor="mm")
        d.rectangle([ix, iy + 20, ix + 23, iy + 22], fill=(0, 0, 0))
        d.rectangle([ix, iy + 20, ix + 15, iy + 22], fill=R.HP_HIGH)
        R.txt(d, (LIST_X + ICON_CELL + 8, uy + 24), name, 13, R.TEXT if sel else R.TEXT_DIM)
        if i == 0:
            R.txt(d, (LIST_X + LIST_W - 8, uy + 24), "将", 10, R.ACCENT, anchor="rs")
        uy += rh
    draw_header_row(d, uy, "部队二", "4/11", "2", queue=None)


def draw_portrait(d):
    R.draw_icon(d, ICON_X, ICON_Y, ICON_S, "盾", 38, hp=0.82, fill=(17, 24, 34))
    cx = ICON_X + ICON_S / 2
    R.txt(d, (cx, 934), "部队一", 17, R.TEXT, anchor="ms")
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
    rows = [(y0, 38), (y0 + 38, 74), (y0 + 112, 90)]
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
    top = rows[2][0] + 16
    R.txt(d, (label_x, top), "单位特性", 11, R.TEXT_FAINT, anchor="lm")
    col2 = content_x + 110
    for i, line in enumerate(UNIT):
        cx = content_x if i < 2 else col2
        yy = top + (i if i < 2 else i - 2) * 20
        R.txt(d, (cx, yy), line, 13, R.TEXT_DIM, anchor="lm")


# ---------------------------------------------------------------- command card
KEYS = ["Q", "W", "E", "A", "S", "D", "Z", "X", "C"]
UNIT_PAGE = [
    ("长枪兵", "spearman", 0.60, 3),
    ("长弓兵", "longbowman", 0.60, 0),
    ("骑手", "rider", 0.0, 0),
    ("投石车", "catapult", 0.0, 0),
    ("剑士", "dy_royal_sword", 0.0, 0),
    ("弓手", "dg_archer", 0.0, 0),
    ("骑士", "knight", 0.0, 0),
    ("马弓手", "horse_archer", 0.0, 0),
    ("投石车", "catapult", 0.0, 0),
]
ORDER_PAGE = ["移动", "攻击", "行军", "停止", "停招", "", "", "", ""]


def card_frame(d):
    d.rectangle([CARD_X, CARD_Y, CARD_X + CARD_W - 1, CARD_Y + CARD_H - 1], fill=(25, 34, 45))
    d.rectangle([CARD_X, CARD_Y, CARD_X + CARD_W - 1, CARD_Y + CARD_H - 1],
                outline=R.LINE, width=2)
    for i in range(1, 3):
        d.line([(CARD_X + CELL * i, CARD_Y), (CARD_X + CELL * i, CARD_Y + CARD_H)],
               fill=R.LINE_SOFT, width=1)
        d.line([(CARD_X, CARD_Y + CELL * i), (CARD_X + CARD_W, CARD_Y + CELL * i)],
               fill=R.LINE_SOFT, width=1)
    # current tab column: 2px outer frame, two equal tabs
    d.rectangle([TAB_X, CARD_Y, 1919, CARD_Y + CARD_H - 1], fill=(20, 28, 38))
    d.rectangle([TAB_X, CARD_Y, 1919, CARD_Y + CARD_H - 1], outline=R.LINE, width=2)
    d.line([(TAB_X, CARD_Y + CARD_H / 2), (1919, CARD_Y + CARD_H / 2)],
           fill=R.LINE_SOFT, width=1)


def draw_tab(d, idx, label, active):
    ty = CARD_Y + idx * (CARD_H / 2)
    if active:
        d.rectangle([TAB_X + 1, ty + 1, 1918, ty + CARD_H / 2 - 2], fill=R.ACCENT)
        color = (26, 18, 6)
        border = R.ACCENT_BRIGHT
    else:
        color = R.TEXT
        border = R.LINE_SOFT
    if not active:
        d.rectangle([TAB_X + 1, ty + 1, 1918, ty + CARD_H / 2 - 2], outline=border, width=1)
    R.txt(d, (TAB_X + TAB_W / 2, ty + 52), label[0], 17, color, anchor="mm")
    R.txt(d, (TAB_X + TAB_W / 2, ty + 78), label[1], 17, color, anchor="mm")


def unit_page(d):
    card_frame(d)
    draw_tab(d, 0, "操作", False)
    draw_tab(d, 1, "单位", True)
    for i, (name, icon_name, prog, count) in enumerate(UNIT_PAGE):
        cx = CARD_X + (i % 3) * CELL
        cy = CARD_Y + (i // 3) * CELL
        if prog > 0:
            fh = int(round(CELL * prog))
            d.rectangle([cx + 1, cy + CELL - fh, cx + CELL - 2, cy + CELL - 2],
                        fill=(80, 60, 22))
            d.line([(cx + 1, cy + CELL - fh), (cx + CELL - 2, cy + CELL - fh)],
                   fill=R.ACCENT_BRIGHT, width=2)
            d.rectangle([cx, cy, cx + CELL - 1, cy + CELL - 1], outline=R.ACCENT, width=2)
        R.txt(d, (cx + 5, cy + 15), KEYS[i], 10, R.TEXT_FAINT)
        ic = unit_icon(icon_name, 62)
        CELL_ICONS.append((ic, int(cx + (CELL - 62) / 2), int(cy + 2)))
        d.rectangle([cx + 1, cy + CELL - 16, cx + CELL - 2, cy + CELL - 2], fill=(12, 18, 26))
        R.txt(d, (cx + CELL / 2, cy + CELL - 6), name, 11, R.TEXT_DIM, anchor="mm")
        if count > 0:
            bw, bh = 22, 17
            bx, by = cx + CELL - bw - 3, cy + CELL - bh - 2
            d.rectangle([bx, by, bx + bw, by + bh], fill=(12, 18, 26), outline=R.ACCENT, width=1)
            R.txt(d, (bx + bw / 2, by + bh / 2 + 1), "×%d" % count, 10, R.ACCENT, anchor="mm")


CELL_ICONS = []


def order_page(d):
    card_frame(d)
    draw_tab(d, 0, "操作", True)
    draw_tab(d, 1, "单位", False)
    for i, name in enumerate(ORDER_PAGE):
        if name == "":
            continue
        cx = CARD_X + (i % 3) * CELL
        cy = CARD_Y + (i // 3) * CELL
        R.txt(d, (cx + 5, cy + 15), KEYS[i], 10, R.TEXT_FAINT)
        if name == "停招":
            d.rectangle([cx + 1, cy + 1, cx + CELL - 2, cy + CELL - 2],
                        outline=R.ACCENT, width=2)
        R.txt(d, (cx + CELL / 2, cy + CELL / 2 + 4), name, 15, R.ACCENT, anchor="mm")


# ---------------------------------------------------------------- context
def draw_squad_panel(d):
    x, y, w, rows = 1680, 180, 240, 6
    h = 88
    d.rectangle([x, y, x + w - 1, y + rows * h - 1], fill=(20, 28, 38))
    d.rectangle([x, y, x + w - 1, y + rows * h - 1], outline=R.LINE, width=2)
    for i in range(rows):
        ry = y + i * h
        active = (i == 0)
        if active:
            d.rectangle([x + 1, ry + 1, x + w - 2, ry + h - 2], fill=R.ACCENT)
            tc = (26, 18, 6)
            sc = (26, 18, 6)
        else:
            d.rectangle([x + 1, ry + 1, x + w - 2, ry + h - 2], outline=R.LINE_SOFT, width=1)
            tc = R.TEXT
            sc = R.TEXT_DIM
        R.txt(d, (x + 10, ry + 34), "将领 %d" % i if i else "将领 0", 15, tc)
        R.txt(d, (x + 10, ry + 58), "1/11", 11, sc)
        d.line([(x + 178, ry + 8), (x + 178, ry + h - 8)], fill=(R.LINE_SOFT if not active else (26, 18, 6)), width=1)
        R.txt(d, (x + 206, ry + h / 2 + 14), str(i + 1), 44, tc, anchor="mm")


def bottom_context(img):
    d = ImageDraw.Draw(img)
    # remove the stale 10-slot screenshot panel with a feathered map patch
    px0, py0, px1, py1 = 1470, 160, 1680, 720
    pw, ph = px1 - px0, py1 - py0
    patch = BASE.crop((1260, 160, 1470, 720))
    patch = patch.filter(ImageFilter.GaussianBlur(1.5))
    base_region = img.crop((px0, py0, px1, py1))
    mask = Image.new("L", (pw, ph), 0)
    ImageDraw.Draw(mask).rectangle([5, 5, pw - 6, ph - 6], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(8))
    img.paste(Image.composite(patch, base_region, mask), (px0, py0))
    d = ImageDraw.Draw(img)
    # bottom bar
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
    draw_squad_panel(d)


def render(name, page_fn):
    global CELL_ICONS
    CELL_ICONS = []
    img = BASE.copy().convert("RGB")
    bottom_context(img)
    d = ImageDraw.Draw(img)
    draw_panel(d)
    draw_list(d)
    draw_portrait(d)
    draw_detail(d)
    page_fn(d)
    for ic, ix, iy in CELL_ICONS:
        img.paste(ic, (ix, iy), ic)
    img.save(OUT / name, quality=95)
    print("wrote", name)


def main():
    render("variant_D6_unit.png", unit_page)
    render("variant_D6_order.png", order_page)
    crop = (555, 812, 1188, 1080)
    im = Image.open(OUT / "variant_D6_unit.png").crop(crop)
    im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
    im.save(OUT / "variant_D6_zoom.png")
    print("wrote variant_D6_zoom.png")


if __name__ == "__main__":
    main()
