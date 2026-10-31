# -*- coding: utf-8 -*-
"""Compose the low-poly reference sheets from individual Blender renders."""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")

ITEMS = [
    ("lp_wood_wall",   "1  木墙",   "162 面 | 满格 1x1 | 高 0.57"),
    ("lp_stone_wall",  "2  石墙",   "192 面 | 满格 1x1 | 高 0.72"),
    ("lp_tower",       "3  哨塔",   "282 面 | 0.6 格 | 高 1.16"),
    ("lp_watch_tower", "4  警戒塔", "408 面 | 0.6 格 | 高 1.57"),
    ("lp_farm",        "5  粮田",   "420 面 | 0.6 格 | 高 0.33"),
    ("lp_house",       "6  房屋",   "164 面 | 0.6 格 | 高 0.91"),
    ("lp_mine",        "7  矿脉",   "180 面 | 0.55 格 | 高 0.63"),
]

CELL = 430
GAP = 16
MARGIN = 28
LABEL = 58
TITLE = 78
COLS, ROWS = 4, 2

FONT = None
for cand in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf", r"C:\Windows\Fonts\arial.ttf"):
    if os.path.exists(cand):
        FONT = cand
        break


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


def build(suffix, title, out_name, note):
    W = MARGIN * 2 + COLS * CELL + (COLS - 1) * GAP
    H = MARGIN + TITLE + ROWS * (CELL + LABEL) + (ROWS - 1) * GAP + 44
    canvas = Image.new("RGB", (W, H), (24, 25, 27))
    d = ImageDraw.Draw(canvas)

    d.text((MARGIN, 20), title, font=f(30), fill=(236, 238, 240))
    d.text((MARGIN, 20 + 40), note, font=f(15), fill=(150, 156, 164))

    for i, (name, label, meta) in enumerate(ITEMS):
        path = os.path.join(REN, name + suffix)
        img = Image.open(path).convert("RGB").resize((CELL, CELL), Image.LANCZOS)
        r, c = divmod(i, COLS)
        x = MARGIN + c * (CELL + GAP)
        y = MARGIN + TITLE + r * (CELL + LABEL + GAP)
        canvas.paste(img, (x, y))
        d.rectangle([x, y, x + CELL - 1, y + CELL - 1], outline=(58, 60, 64))
        d.text((x + 6, y + CELL + 8), label, font=f(21), fill=(238, 236, 228))
        d.text((x + 6, y + CELL + 34), meta, font=f(14), fill=(146, 152, 160))

    # footnote strip
    fy = H - 40
    d.line([(MARGIN, fy - 8), (W - MARGIN, fy - 8)], fill=(56, 58, 62))
    d.text((MARGIN, fy), "单位格 = 1x1 灰底方块；模型底边贴地、原点在格心。1 Blender 单位 = 1 格。",
           font=f(14), fill=(128, 134, 142))

    out = os.path.join(BASE, out_name)
    canvas.save(out, quality=95)
    print("saved", out, canvas.size)


build("_color.png",
      "低多边形建筑素材 / 第 1 稿 - 建议配色",
      "sheet_color.png",
      "带材质配色：木褐 / 石灰 / 陶瓦 / 麦金 / 青矿，用于判断体块与细节")
build("_game.png",
      "低多边形建筑素材 / 第 1 稿 - 当前游戏观感",
      "sheet_game.png",
      "按现有管线渲的单色版：阵营色 + 每类型暗化 + 法线明暗（游戏里连灯都没有）")
