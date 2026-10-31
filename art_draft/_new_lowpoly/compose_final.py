# -*- coding: utf-8 -*-
"""Final reference sheet: structures in faction single colour, resource buildings with own vertex colours."""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")

# (object, label, meta, render suffix)
ITEMS = [
    ("lp_wood_wall",   "1  木墙",   "162 面 | 满格 1x1 | 高 0.57", "_game.png"),
    ("lp_stone_wall",  "2  石墙",   "192 面 | 满格 1x1 | 高 0.72", "_game.png"),
    ("lp_tower",       "3  哨塔",   "282 面 | 0.6 格 | 高 1.16",   "_game.png"),
    ("lp_watch_tower", "4  警戒塔", "408 面 | 0.6 格 | 高 1.57",   "_game.png"),
    ("lp_farm",        "5  粮田",   "420 面 | 0.6 格 | 高 0.33",   "_color.png"),
    ("lp_house",       "6  房屋",   "164 面 | 0.6 格 | 高 0.91",   "_color.png"),
    ("lp_mine",        "7  矿脉",   "180 面 | 0.55 格 | 高 0.63",  "_color.png"),
]

CELL, GAP, MARGIN, LABEL, TITLE, COLS, ROWS = 430, 16, 28, 58, 78, 4, 2
FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


def build(title, note, out_name):
    W = MARGIN * 2 + COLS * CELL + (COLS - 1) * GAP
    H = MARGIN + TITLE + ROWS * (CELL + LABEL) + (ROWS - 1) * GAP + 44
    canvas = Image.new("RGB", (W, H), (24, 25, 27))
    d = ImageDraw.Draw(canvas)
    d.text((MARGIN, 18), title, font=f(29), fill=(236, 238, 240))
    d.text((MARGIN, 58), note, font=f(15), fill=(150, 156, 164))

    for i, (name, label, meta, suffix) in enumerate(ITEMS):
        img = Image.open(os.path.join(REN, name + suffix)).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
        r, c = divmod(i, COLS)
        x = MARGIN + c * (CELL + GAP)
        y = MARGIN + TITLE + r * (CELL + LABEL + GAP)
        canvas.paste(img, (x, y))
        d.rectangle([x, y, x + CELL - 1, y + CELL - 1], outline=(58, 60, 64))
        d.text((x + 6, y + CELL + 8), label, font=f(21), fill=(238, 236, 228))
        d.text((x + 6, y + CELL + 34), meta, font=f(14), fill=(146, 152, 160))

    fy = H - 40
    d.line([(MARGIN, fy - 8), (W - MARGIN, fy - 8)], fill=(56, 58, 62))
    d.text((MARGIN, fy), "墙 / 塔：顶点色填白，颜色由阵营色 + 每类型暗化给；粮田 / 房屋 / 矿脉：自带顶点色。",
           font=f(14), fill=(128, 134, 142))
    out = os.path.join(BASE, out_name)
    canvas.save(out, quality=95)
    print("saved", out, canvas.size)


build("低多边形建筑素材 / 第 1 稿定案预览",
      "按你选的方案渲染：结构物单色（靠剪影识别），资源建筑自带配色",
      "sheet_final.png")
