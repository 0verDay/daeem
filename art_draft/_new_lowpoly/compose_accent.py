# -*- coding: utf-8 -*-
"""蓝方视角：只在显眼件（旗 / 屋顶 / 门廊 / 栅栏）上阵营色，其余保留材质原色。"""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")

ITEMS = [
    ("lp_wood_wall",   "1  木墙",   "312+ 面 | 顶部小旗上色"),
    ("lp_stone_wall",  "2  石墙",   "300+ 面 | 顶部小旗上色"),
    ("lp_tower",       "3  哨塔",   "282 面 | 屋顶上色"),
    ("lp_watch_tower", "4  警戒塔", "408 面 | 旗 + 观景廊上色"),
    ("lp_farm",        "5  粮田",   "420 面 | 栅栏 + 草人上色"),
    ("lp_house",       "6  房屋",   "164 面 | 屋顶上色"),
    ("lp_mine",        "7  矿脉",   "180 面 | 矿洞木框上色"),
    ("lp_base",        "8  大本营", "510 面 | 屋顶 + 旗上色"),
]

CELL, GAP, MARGIN, LABEL, TITLE, COLS, ROWS = 430, 16, 28, 58, 78, 4, 2
FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


W = MARGIN * 2 + COLS * CELL + (COLS - 1) * GAP
H = MARGIN + TITLE + ROWS * (CELL + LABEL) + (ROWS - 1) * GAP + 44
canvas = Image.new("RGB", (W, H), (24, 25, 27))
d = ImageDraw.Draw(canvas)
d.text((MARGIN, 18), "局部阵营色 - 蓝方视角（#5ac8ff）", font=f(29), fill=(236, 238, 240))
d.text((MARGIN, 58), "只有旗 / 屋顶 / 廊柱 / 栅栏吃阵营色，木石材质保持原色",
       font=f(15), fill=(150, 156, 164))

for i, (name, label, meta) in enumerate(ITEMS):
    img = Image.open(os.path.join(REN, name + "_accent.png")).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
    r, c = divmod(i, COLS)
    x = MARGIN + c * (CELL + GAP)
    y = MARGIN + TITLE + r * (CELL + LABEL + GAP)
    canvas.paste(img, (x, y))
    d.rectangle([x, y, x + CELL - 1, y + CELL - 1], outline=(58, 60, 64))
    d.text((x + 6, y + CELL + 8), label, font=f(21), fill=(238, 236, 228))
    d.text((x + 6, y + CELL + 34), meta, font=f(14), fill=(146, 152, 160))

fy = H - 40
d.line([(MARGIN, fy - 8), (W - MARGIN, fy - 8)], fill=(56, 58, 62))
d.text((MARGIN, fy), "遮罩写在顶点色的 alpha 通道：COLOR.a = 1 -> 阵营色，= 0 -> 模型原色。",
       font=f(14), fill=(128, 134, 142))

out = os.path.join(BASE, "sheet3_accent.png")
canvas.save(out, quality=95)
print("saved", out, canvas.size)
