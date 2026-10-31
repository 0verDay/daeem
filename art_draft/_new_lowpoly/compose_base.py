# -*- coding: utf-8 -*-
"""大本营 新旧对比：旧模型（单色） / 新模型（材质色） / 新模型（x 阵营色）"""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")
PICS = [
    ("base_old.png",       "旧大本营", "90 面 / 高 1.35 格 / 单色"),
    ("base_new_color.png", "新大本营（材质色）", "510 面 / 高 1.42 格 / 满格 0.98"),
    ("base_new_tint.png",  "新大本营（x 阵营色）", "相乘后的实际观感"),
]
CELL = 500
GAP = 18
MARGIN = 26
LABEL = 56
FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


W = MARGIN * 2 + len(PICS) * CELL + (len(PICS) - 1) * GAP
H = MARGIN + 74 + CELL + LABEL
canvas = Image.new("RGB", (W, H), (24, 25, 27))
d = ImageDraw.Draw(canvas)
d.text((MARGIN, 16), "大本营换模型 - 新旧对比", font=f(28), fill=(236, 238, 240))
d.text((MARGIN, 52), "同一机位、同一光照；第三张是游戏里相乘后的样子", font=f(15), fill=(150, 156, 164))

for i, (fn, title, note) in enumerate(PICS):
    img = Image.open(os.path.join(REN, fn)).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
    x = MARGIN + i * (CELL + GAP)
    y = MARGIN + 74
    canvas.paste(img, (x, y))
    d.rectangle([x, y, x + CELL - 1, y + CELL - 1], outline=(58, 60, 64))
    d.text((x + 4, y + CELL + 6), title, font=f(21), fill=(238, 236, 228))
    d.text((x + 4, y + CELL + 32), note, font=f(14), fill=(146, 152, 160))

out = os.path.join(BASE, "base_compare.png")
canvas.save(out, quality=95)
print("saved", out, canvas.size)
