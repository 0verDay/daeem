# -*- coding: utf-8 -*-
"""Render 4 layout candidates for the new in-game detail panel.

This is a design mockup only: it overlays the real HUD screenshot (00_wide.png)
with a panel at the current DETAIL_RECT (562, 820, 988, 260), using the game's
palette and SimHei so the layout can be judged at actual size.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem")
OUT = Path(r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\详细信息\variants")
BASE = Image.open(ROOT / "shots" / "00_wide.png").convert("RGBA")
FONT = str(ROOT / "assets" / "fonts" / "simhei.ttf")

def font(sz):
    return ImageFont.truetype(FONT, sz)

F = {s: font(s) for s in (10, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 26, 28, 29, 38, 40, 44)}

# palette (data/config.json theme.palette)
ACCENT = (242, 181, 68, 255)
ACCENT_BRIGHT = (255, 217, 138, 255)
ACCENT_DEEP = (168, 122, 34, 255)
LINE = (138, 117, 64, 255)
LINE_SOFT = (74, 64, 41, 255)
TEXT = (232, 227, 213, 255)
TEXT_DIM = (169, 178, 189, 255)
TEXT_FAINT = (107, 118, 132, 255)
WARN = (229, 72, 77, 255)
HP_HIGH = (122, 176, 106, 255)
HP_MID = (224, 176, 74, 255)
HP_LOW = (201, 89, 63, 255)
PANEL = (25, 34, 45)
PANEL_EMPTY = (10, 15, 22)
LIST_BG = (14, 20, 29)
ROW_EXPANDED = (42, 51, 63)
ROW_SELECTED = (55, 49, 36)

PANEL_RECT = (562, 820, 1550, 1080)
PAD = 10
LIST_X, LIST_Y, LIST_W, LIST_H = 572, 830, 288, 240
RIGHT_X = LIST_X + LIST_W + 12          # 872
RIGHT_W = 1540 - RIGHT_X                 # 668
HEAD_Y = 830
DETAIL_Y = 918
DETAIL_H = 122
NOTICE_Y = 1044

def txt(d, xy, s, size, color, anchor="ls"):
    d.text(xy, s, font=F[size], fill=color, anchor=anchor)

def tw(s, size):
    return F[size].getlength(s)

def dotted_underline(d, x, y, s, size, color):
    w = tw(s, size)
    step = 4
    xx = x
    while xx < x + w:
        d.line([(xx, y), (min(xx + 2, x + w), y)], fill=color, width=1)
        xx += step

def hp_color(r):
    return HP_HIGH if r >= 0.5 else (HP_MID if r >= 0.25 else HP_LOW)

def draw_icon(d, x, y, s, ch, fs, hp=1.0, morale=None, fill=(17, 24, 34)):
    if morale is not None:
        col = (122, 176, 106) if morale >= 0.5 else (224, 176, 74) if morale >= 0.25 else (201, 89, 63)
        d.rectangle([x, y, x + s - 1, y + s - 1], fill=col)
    d.rectangle([x, y, x + s - 1, y + s - 1], fill=fill)
    d.rectangle([x, y, x + s - 1, y + s - 1], outline=LINE, width=1)
    txt(d, (x + s / 2, y + s / 2 + 1), ch, fs, TEXT, anchor="mm")
    if hp is not None:
        d.rectangle([x + 1, y + s - 4, x + s - 2, y + s - 2], fill=(0, 0, 0))
        d.rectangle([x + 1, y + s - 4, x + 1 + (s - 3) * max(0.0, min(1.0, hp)), y + s - 2],
                    fill=hp_color(hp))

def bottom_context(d):
    """Replace the stale bottom bar under test with the current geometry:
    map 0..400 (kept from the screenshot), faction 400..562, panel 562..1550."""
    d.rectangle([400, 820, 1550, 1080], fill=(35, 46, 54))
    # faction shield placeholder
    d.rectangle([400, 820, 562, 1080], fill=(39, 50, 58))
    d.rectangle([400, 820, 562, 1080], outline=LINE_SOFT, width=1)
    poly = [(446, 876), (516, 876), (516, 934), (481, 964), (446, 934)]
    d.polygon(poly, outline=LINE, width=2)
    txt(d, (481, 900), "盾", 26, TEXT_FAINT, anchor="mm")
    txt(d, (481, 990), "阵营盾徽", 13, TEXT_FAINT, anchor="ms")
    txt(d, (481, 1012), "旗帜 · 占位", 11, TEXT_FAINT, anchor="ms")


def panel_base(d):
    x0, y0, x1, y1 = PANEL_RECT
    d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=PANEL)
    d.rectangle([x0, y0, x1 - 1, y1 - 1], outline=LINE, width=2)
    # list column
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=LIST_BG)
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], outline=LINE_SOFT, width=1)
    return d

def list_rows(d, selected_unit=1):
    # troop 1 (expanded + focused)
    hx, hy, hw, hh = LIST_X + 1, LIST_Y + 1, LIST_W - 2, 58
    d.rectangle([hx, hy, hx + hw - 1, hy + hh - 1], fill=(48, 45, 36))
    d.rectangle([hx, hy, hx + 2, hy + hh - 1], fill=ACCENT)
    draw_icon(d, hx + 8, hy + 9, 40, "1", 22, hp=1.0, morale=0.85)
    txt(d, (hx + 56, hy + 34), "将领子刹的部队", 13, TEXT)
    txt(d, (hx + 56, hy + 52), "5/11", 11, TEXT_DIM)
    txt(d, (hx + hw - 12, hy + 34), "▾", 11, TEXT_FAINT, anchor="rs")

    units = [("子刹", "将", False, 1.0), ("御林军剑盾兵", "盾", True, 0.82), ("王朝投石车", "车", False, 0.64)]
    uy = hy + hh
    for i, (name, ch, sel, hp) in enumerate(units):
        rh = 38
        if sel:
            d.rectangle([hx, uy, hx + hw - 1, uy + rh - 1], fill=ROW_SELECTED)
            d.rectangle([hx + 1, uy, hx + 2, uy + rh - 1], fill=ACCENT)
        draw_icon(d, hx + 20, uy + 7, 24, ch, 13, hp=hp)
        txt(d, (hx + 52, uy + 25), name, 13, TEXT if sel else TEXT_DIM)
        if i == 0:
            txt(d, (hx + hw - 12, uy + 25), "将", 10, ACCENT, anchor="rs")
        uy += rh

    # troop 2 (collapsed)
    hy2 = uy
    hh2 = LIST_Y + LIST_H - hy2 - 1
    d.rectangle([hx, hy2, hx + hw - 1, hy2 + hh2 - 1], fill=(33, 42, 52))
    d.rectangle([hx, hy2 + hh2 - 1, hx + hw - 1, hy2 + hh2 - 1], fill=LINE_SOFT)
    draw_icon(d, hx + 8, hy2 + 9, 40, "2", 22, hp=1.0, morale=0.66)
    txt(d, (hx + 56, hy2 + 34), "将领阿吉诃德的部队", 13, TEXT)
    txt(d, (hx + 56, hy2 + 52), "4/11", 11, TEXT_DIM)
    txt(d, (hx + hw - 12, hy2 + 34), "▸", 11, TEXT_FAINT, anchor="rs")

def header(d, title="将领子刹的部队", sub="御林军剑盾兵"):
    draw_icon(d, RIGHT_X, HEAD_Y, 72, "盾", 38, hp=0.82, fill=(17, 24, 34))
    txt(d, (RIGHT_X + 84, HEAD_Y + 34), title, 29, TEXT)
    txt(d, (RIGHT_X + 84, HEAD_Y + 66), sub, 15, TEXT_DIM)
    # thin rule under the header
    d.line([(RIGHT_X, HEAD_Y + 84), (RIGHT_X + RIGHT_W - 8, HEAD_Y + 84)], fill=LINE_SOFT, width=1)

def detail_box(d):
    d.rectangle([RIGHT_X, DETAIL_Y, RIGHT_X + RIGHT_W - 8, DETAIL_Y + DETAIL_H - 1], fill=PANEL_EMPTY)
    d.rectangle([RIGHT_X, DETAIL_Y, RIGHT_X + RIGHT_W - 8, DETAIL_Y + DETAIL_H - 1], outline=LINE_SOFT, width=1)

def notice(d, text=""):
    if text:
        txt(d, (RIGHT_X + 2, NOTICE_Y), text, 13, WARN)

TAGS = "步兵  /  近战"
GEN = ["铁壁", "稳定", "横扫"]
UNIT = ["近战减伤 +30%", "远程减伤 +30%", "稳定"]

def draw_gen_inline(d, x, baseline, sep="   "):
    xx = x
    for i, name in enumerate(GEN):
        txt(d, (xx, baseline), name, 15, ACCENT)
        w = tw(name, 15)
        dotted_underline(d, xx, baseline + 3, name, 15, (120, 95, 45))
        xx += w
        if i < len(GEN) - 1:
            txt(d, (xx, baseline), sep, 15, TEXT_FAINT)
            xx += tw(sep, 15)

def variant_a(d):
    detail_box(d)
    x = RIGHT_X + 12
    label_w = 88
    y = DETAIL_Y + 8
    rows = [("属性", TAGS, 15, TEXT), ("将领特性", None, 15, TEXT), ("单位特性", "  ·  ".join(UNIT), 13, TEXT_DIM)]
    for i, (label, content, sz, col) in enumerate(rows):
        cy = y + 16
        txt(d, (x, cy), label, 12, TEXT_FAINT, anchor="lm")
        if i == 1:
            draw_gen_inline(d, x + label_w, cy + 5)
        else:
            txt(d, (x + label_w, cy), content, sz, col, anchor="lm")
        if i < len(rows) - 1:
            yy = y + 32 - 1
            d.line([(x, yy), (RIGHT_X + RIGHT_W - 20, yy)], fill=LINE_SOFT, width=1)
        y += 32

def variant_b(d):
    detail_box(d)
    x = RIGHT_X + 12
    cols = [(x, 190), (x + 210, 196), (x + 430, 198)]
    heads = ["属性", "将领特性", "单位特性"]
    for i, (cx, cw) in enumerate(cols):
        txt(d, (cx, DETAIL_Y + 28), heads[i], 11, TEXT_FAINT)
        if i < 2:
            d.line([(cx + cw + 8, DETAIL_Y + 14), (cx + cw + 8, DETAIL_Y + DETAIL_H - 14)],
                   fill=LINE_SOFT, width=1)
    txt(d, (cols[0][0], DETAIL_Y + 66), TAGS, 15, TEXT)
    draw_gen_inline(d, cols[1][0], DETAIL_Y + 66)
    yy = DETAIL_Y + 58
    for line in UNIT:
        txt(d, (cols[2][0], yy), line, 13, TEXT_DIM)
        yy += 24

def variant_c(d):
    detail_box(d)
    x = RIGHT_X + 12
    txt(d, (x, DETAIL_Y + 26), "属性", 11, TEXT_FAINT)
    txt(d, (x + 46, DETAIL_Y + 27), TAGS, 15, TEXT)
    d.line([(x, DETAIL_Y + 38), (RIGHT_X + RIGHT_W - 20, DETAIL_Y + 38)], fill=LINE_SOFT, width=1)

    left_x = x
    right_x = x + 306
    d.line([(right_x - 14, DETAIL_Y + 48), (right_x - 14, DETAIL_Y + DETAIL_H - 12)],
           fill=LINE_SOFT, width=1)
    txt(d, (left_x, DETAIL_Y + 62), "将领特性", 11, TEXT_FAINT)
    draw_gen_inline(d, left_x, DETAIL_Y + 90, sep="    ")
    txt(d, (left_x, DETAIL_Y + 110), "悬停特性名查看说明", 10, TEXT_FAINT)

    txt(d, (right_x, DETAIL_Y + 62), "单位特性", 11, TEXT_FAINT)
    yy = DETAIL_Y + 90
    for line in UNIT:
        txt(d, (right_x, yy), line, 13, TEXT_DIM)
        yy += 20

def variant_d(d):
    # left portrait card (no common header in this variant)
    lx = RIGHT_X
    draw_icon(d, lx, HEAD_Y, 84, "盾", 40, hp=0.82, fill=(17, 24, 34))
    txt(d, (lx, HEAD_Y + 114), "将领子刹的部队", 22, TEXT)
    txt(d, (lx, HEAD_Y + 140), "御林军剑盾兵", 13, TEXT_DIM)
    txt(d, (lx, HEAD_Y + 166), "步兵 / 近战", 13, ACCENT)
    txt(d, (lx, HEAD_Y + 190), "5/11", 13, TEXT_DIM)
    d.line([(RIGHT_X + 276, HEAD_Y + 6), (RIGHT_X + 276, HEAD_Y + 204)], fill=LINE_SOFT, width=1)
    # right details: 3 tall rows
    rx = RIGHT_X + 292
    rw = RIGHT_X + RIGHT_W - 8 - rx
    d.rectangle([rx, HEAD_Y, rx + rw - 1, HEAD_Y + 210], fill=PANEL_EMPTY)
    d.rectangle([rx, HEAD_Y, rx + rw - 1, HEAD_Y + 210], outline=LINE_SOFT, width=1)
    label_w = 78
    rows = [("属性", TAGS, 15, TEXT), ("将领特性", None, 15, TEXT), ("单位特性", None, 12, TEXT_DIM)]
    for i, (label, content, sz, col) in enumerate(rows):
        cy = HEAD_Y + 34 + i * 62
        txt(d, (rx + 14, cy), label, 11, TEXT_FAINT, anchor="lm")
        if i == 1:
            draw_gen_inline(d, rx + 14 + label_w, cy + 5)
        elif i == 2:
            txt(d, (rx + 14 + label_w, cy - 8), "近战减伤 +30%  ·  远程减伤 +30%", 12, TEXT_DIM)
            txt(d, (rx + 14 + label_w, cy + 12), "稳定", 12, TEXT_DIM)
        else:
            txt(d, (rx + 14 + label_w, cy), content, sz, col, anchor="lm")
        if i < len(rows) - 1:
            yy = HEAD_Y + 62 * (i + 1)
            d.line([(rx + 14, yy), (rx + rw - 14, yy)], fill=LINE_SOFT, width=1)

VARIANTS = {
    "A": ("A · 三段横排（标签在左）", variant_a),
    "B": ("B · 三栏并排（属性 / 将领特性 / 单位特性）", variant_b),
    "C": ("C · 属性横条 + 下方双栏", variant_c),
    "D": ("D · 左侧头像卡 + 右侧详情", variant_d),
}

if __name__ == "__main__":
    for key, (label, fn) in VARIANTS.items():
        img = BASE.copy().convert("RGB")
        d = ImageDraw.Draw(img)
        bottom_context(d)
        panel_base(d)
        list_rows(d)
        if key != "D":
            header(d)
        fn(d)
        notice(d, "")
        img = img.crop((0, 0, 1600, 1080))
        img.convert("RGB").save(OUT / f"variant_{key}.png", quality=95)
        print("wrote", OUT / f"variant_{key}.png")

    # 2x overview of the panel area
    crop = (555, 812, 1558, 1080)
    rows = []
    for key, (label, _) in VARIANTS.items():
        im = Image.open(OUT / f"variant_{key}.png").convert("RGB").crop(crop)
        im = im.resize((im.width * 2, im.height * 2), Image.LANCZOS)
        rows.append((key, label, im))
    label_h = 46
    w = rows[0][2].width
    h = label_h + rows[0][2].height
    sheet = Image.new("RGB", (w, h * len(rows)), (12, 16, 22))
    sd = ImageDraw.Draw(sheet)
    for i, (key, label, im) in enumerate(rows):
        y = i * h
        sd.text((16, y + 12), label, font=font(24), fill=(232, 227, 213))
        sheet.paste(im, (0, y + label_h))
    sheet.save(OUT / "overview.png")
    print("wrote", OUT / "overview.png")
