# -*- coding: utf-8 -*-
"""D6 其他选中：建筑 / 区划 / 敌方单位。

按用户最新字段：
  建筑 = 属性(类型/等级) + 特殊(远程免伤/归属)
  区划 = 属性(归属/区划类型/产出) + 特殊(建筑加成)
  敌方 = 属性(兵种/近战远程) + 特性(将领特性/单位特性)
左侧：小按钮列表，没有部队大按钮。
"""
import sys
from pathlib import Path
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import render_variants as R

OUT = Path(__file__).parent
PANEL_W, PANEL_H = 617, 260
LIST_X, LIST_Y, LIST_W, LIST_H = 2, 2, 185, 256
ICON_X, ICON_Y, ICON_S = 205, 18, 72
DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H = 287, 18, 320, 202


def blend(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def glow_row(d, x0, y0, x1, y1, base, band=6, strength=0.42):
    d.rectangle([x0, y0, x1, y1], fill=base)
    for i in range(band):
        t = strength * (1.0 - i / float(band))
        col = blend(base, R.ACCENT, t)
        d.line([(x0, y0 + i), (x1, y0 + i)], fill=col, width=1)
        d.line([(x0, y1 - i), (x1, y1 - i)], fill=col, width=1)
        d.line([(x0 + i, y0), (x0 + i, y1)], fill=col, width=1)
        d.line([(x1 - i, y0), (x1 - i, y1)], fill=col, width=1)


def panel(d):
    d.rectangle([0, 0, PANEL_W - 1, PANEL_H - 1], fill=(25, 34, 45))
    d.rectangle([0, 0, PANEL_W - 1, PANEL_H - 1], outline=R.LINE, width=2)
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1], fill=(14, 20, 29))
    d.rectangle([LIST_X, LIST_Y, LIST_X + LIST_W - 1, LIST_Y + LIST_H - 1],
                outline=R.ACCENT, width=2)


def small_rows(d, rows, selected=0):
    y = LIST_Y
    for i, (name, ch, sub) in enumerate(rows):
        h = 40
        if i == selected:
            glow_row(d, LIST_X + 1, y, LIST_X + LIST_W - 2, y + h - 1, (22, 30, 40))
            d.rectangle([LIST_X + 1, y, LIST_X + 2, y + h - 1], fill=R.ACCENT)
        else:
            d.rectangle([LIST_X + 1, y, LIST_X + LIST_W - 2, y + h - 1], fill=(14, 20, 29))
        ix = LIST_X + (54 - 24) // 2
        iy = y + 8
        d.rectangle([ix, iy, ix + 23, iy + 23], fill=(17, 24, 34),
                    outline=R.ACCENT_BRIGHT if i == selected else R.LINE_SOFT, width=1)
        R.txt(d, (ix + 12, iy + 13), ch, 13, R.TEXT, anchor="mm")
        R.txt(d, (LIST_X + 54 + 8, y + 25), name, 13, R.TEXT if i == selected else R.TEXT_DIM)
        R.txt(d, (LIST_X + LIST_W - 10, y + 25), sub, 11, R.TEXT_DIM, anchor="rs")
        y += h
        d.line([(LIST_X + 1, y - 1), (LIST_X + LIST_W - 2, y - 1)], fill=R.LINE_SOFT, width=1)


def portrait(d, icon, title, sub, show_hp):
    R.draw_icon(d, ICON_X, ICON_Y, ICON_S, icon, 38, hp=(0.9 if show_hp else None),
                fill=(17, 24, 34))
    cx = ICON_X + ICON_S / 2
    R.txt(d, (cx, ICON_Y + 96), title, 17, R.TEXT, anchor="ms")
    R.txt(d, (cx, ICON_Y + 120), sub, 13, R.TEXT_DIM, anchor="ms")


def detail_frame(d):
    d.rectangle([DETAIL_X, DETAIL_Y, DETAIL_X + DETAIL_W - 1, DETAIL_Y + DETAIL_H - 1],
                fill=(10, 15, 22))
    d.rectangle([DETAIL_X, DETAIL_Y, DETAIL_X + DETAIL_W - 1, DETAIL_Y + DETAIL_H - 1],
                outline=R.LINE_SOFT, width=1)


def label(d, y, text):
    R.txt(d, (DETAIL_X + 12, y), text, 11, R.TEXT_FAINT, anchor="lm")


def content(d, y, text, color=None, size=13):
    R.txt(d, (DETAIL_X + 76, y), text, size, color if color else R.TEXT, anchor="lm")


def sep(d, y):
    d.line([(DETAIL_X + 12, y), (DETAIL_X + DETAIL_W - 12, y)], fill=R.LINE_SOFT, width=1)


def building(d):
    panel(d)
    small_rows(d, [("哨塔", "塔", "800/800"), ("木墙", "墙", "500/500")])
    portrait(d, "塔", "哨塔", "建筑 · Lv1", True)
    detail_frame(d)
    # 属性 38
    label(d, DETAIL_Y + 19, "属性")
    content(d, DETAIL_Y + 19, "防御建筑 / Lv1", R.TEXT, 15)
    sep(d, DETAIL_Y + 38)
    # 特殊 164
    label(d, DETAIL_Y + 54, "特殊")
    content(d, DETAIL_Y + 54, "远程免伤 90%")
    content(d, DETAIL_Y + 78, "归属 己方")


def zone(d):
    panel(d)
    small_rows(d, [("粮食区", "粮", "9 格"), ("伐木区", "木", "7 格")])
    portrait(d, "粮", "粮食区", "区划 · 9 格", False)
    detail_frame(d)
    # 属性 74：归属 / 区划类型 / 产出
    label(d, DETAIL_Y + 16, "属性")
    content(d, DETAIL_Y + 16, "归属 己方")
    content(d, DETAIL_Y + 38, "区划类型 粮食区")
    content(d, DETAIL_Y + 60, "产出 粮食 +1.2/s")
    sep(d, DETAIL_Y + 74)
    # 特殊 128
    label(d, DETAIL_Y + 92, "特殊")
    content(d, DETAIL_Y + 92, "建筑加成 +20%")


def enemy(d):
    panel(d)
    small_rows(d, [("长枪兵", "枪", "140/140")])
    portrait(d, "枪", "长枪兵", "敌方 · 步兵", True)
    detail_frame(d)
    # 属性 38
    label(d, DETAIL_Y + 19, "属性")
    content(d, DETAIL_Y + 19, "步兵 / 近战", R.TEXT, 15)
    sep(d, DETAIL_Y + 38)
    # 特性 164
    label(d, DETAIL_Y + 54, "特性")
    R.txt(d, (DETAIL_X + 76, DETAIL_Y + 54), "将领特性", 11, R.TEXT_FAINT, anchor="lm")
    R.txt(d, (DETAIL_X + 76, DETAIL_Y + 78), "神速", 15, R.ACCENT)
    R.dotted_underline(d, DETAIL_X + 76, DETAIL_Y + 81, "神速", 15, (120, 95, 45))
    R.txt(d, (DETAIL_X + 186, DETAIL_Y + 54), "单位特性", 11, R.TEXT_FAINT, anchor="lm")
    R.txt(d, (DETAIL_X + 186, DETAIL_Y + 78), "对骑兵 +25%", 13, R.TEXT_DIM)


def render(name, fn):
    img = Image.new("RGB", (PANEL_W, PANEL_H), (10, 15, 22))
    d = ImageDraw.Draw(img)
    fn(d)
    img.save(OUT / name, quality=95)
    return img


def main():
    ims = [("建筑", render("variant_D6_building.png", building)),
           ("区划", render("variant_D6_zone.png", zone)),
           ("敌方单位", render("variant_D6_enemy.png", enemy))]
    scale = 1.6
    label_h = 36
    w = int(PANEL_W * scale)
    h = int(PANEL_H * scale)
    sheet = Image.new("RGB", (w, (h + label_h) * len(ims)), (10, 15, 22))
    sd = ImageDraw.Draw(sheet)
    for i, (name, im) in enumerate(ims):
        y = i * (h + label_h)
        sd.text((10, y + 8), name, font=R.F[18], fill=(232, 227, 213))
        sheet.paste(im.resize((w, h), Image.LANCZOS), (0, y + label_h))
    sheet.save(OUT / "variant_D6_other.png")
    print("wrote building/zone/enemy + variant_D6_other.png")


if __name__ == "__main__":
    main()
