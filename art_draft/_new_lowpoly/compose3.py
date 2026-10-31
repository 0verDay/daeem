# -*- coding: utf-8 -*-
"""Colour-policy comparison: pure vertex colour / 30% faction mix / multiply."""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")

COLS = [
    ("lp_wood_wall", "木墙"),
    ("lp_stone_wall", "石墙"),
    ("lp_tower", "哨塔"),
    ("lp_watch_tower", "警戒塔"),
    ("lp_farm", "粮田"),
    ("lp_house", "房屋"),
    ("lp_mine", "矿脉"),
]
ROWS = [
    ("_color.png", "纯顶点色", "COLOR 直接当 albedo，阵营色不上身"),
    ("_mix.png", "弱混合 30%", "mix(COLOR, 阵营色, 0.30)"),
    ("_tint.png", "相乘（现状）", "COLOR x 阵营色，材质被压成同色系"),
]

CELL = 236
GAP = 10
LEFT = 226
MARGIN = 26
TOP = 96
ROW_LABEL = 40
FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


W = MARGIN * 2 + LEFT + len(COLS) * CELL + (len(COLS) - 1) * GAP
H = TOP + len(ROWS) * (CELL + ROW_LABEL) + (len(ROWS) - 1) * GAP + 26
canvas = Image.new("RGB", (W, H), (24, 25, 27))
d = ImageDraw.Draw(canvas)

d.text((MARGIN, 16), "配色方案对比 - 阵营色怎么叠在材质色上", font=f(27), fill=(236, 238, 240))
d.text((MARGIN, 52), "同一套模型，三种 shader 写法；己方阵营色 #ffd166", font=f(15), fill=(150, 156, 164))

x0 = MARGIN + LEFT
for c, (name, label) in enumerate(COLS):
    x = x0 + c * (CELL + GAP)
    d.text((x + 4, TOP - 26), label, font=f(19), fill=(226, 224, 216))

for r, (suffix, name, note) in enumerate(ROWS):
    y = TOP + r * (CELL + ROW_LABEL + GAP)
    d.text((MARGIN, y + 6), name, font=f(19), fill=(238, 236, 228))
    d.text((MARGIN, y + 32), note, font=f(13), fill=(146, 152, 160))
    for c, (obj, _) in enumerate(COLS):
        img = Image.open(os.path.join(REN, obj + suffix)).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
        x = x0 + c * (CELL + GAP)
        canvas.paste(img, (x, y))
        d.rectangle([x, y, x + CELL - 1, y + CELL - 1], outline=(58, 60, 64))

out = os.path.join(BASE, "sheet2_compare.png")
canvas.save(out, quality=95)
print("saved", out, canvas.size)
