# -*- coding: utf-8 -*-
"""Second-round sheets: pure material colours vs material x faction tint."""
import os
from PIL import Image, ImageDraw, ImageFont

BASE = r"C:\Users\yy197\Documents\GitHub\daeem\art_draft\_new_lowpoly"
REN = os.path.join(BASE, "renders")

ITEMS = [
    ("lp_wood_wall",   "1  木墙",   "312 面 | 满格 0.98x0.98 | 高 0.80"),
    ("lp_stone_wall",  "2  石墙",   "300 面 | 满格 0.98x0.98 | 高 0.88"),
    ("lp_tower",       "3  哨塔",   "282 面 | 0.6 格 | 高 1.16"),
    ("lp_watch_tower", "4  警戒塔", "408 面 | 0.6 格 | 高 1.57"),
    ("lp_farm",        "5  粮田",   "420 面 | 0.6 格 | 高 0.33"),
    ("lp_house",       "6  房屋",   "164 面 | 0.6 格 | 高 0.91"),
    ("lp_mine",        "7  矿脉",   "180 面 | 0.55 格 | 高 0.63"),
]

CELL, GAP, MARGIN, LABEL, TITLE, COLS, ROWS = 430, 16, 28, 58, 78, 4, 2
FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def f(size):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


def build(suffix, title, note, out_name, footnote):
    W = MARGIN * 2 + COLS * CELL + (COLS - 1) * GAP
    H = MARGIN + TITLE + ROWS * (CELL + LABEL) + (ROWS - 1) * GAP + 44
    canvas = Image.new("RGB", (W, H), (24, 25, 27))
    d = ImageDraw.Draw(canvas)
    d.text((MARGIN, 18), title, font=f(29), fill=(236, 238, 240))
    d.text((MARGIN, 58), note, font=f(15), fill=(150, 156, 164))

    for i, (name, label, meta) in enumerate(ITEMS):
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
    d.text((MARGIN, fy), footnote, font=f(14), fill=(128, 134, 142))
    out = os.path.join(BASE, out_name)
    canvas.save(out, quality=95)
    print("saved", out, canvas.size)


build("_color.png",
      "低多边形建筑素材 / 第 2 稿 - 模型自带配色",
      "七件全部写入顶点色（木褐 / 石灰 / 陶瓦 / 麦金 / 青矿），墙已改为填满整格的垒体",
      "sheet2_color.png",
      "墙：双排木栅 + 内填土 + 走道 / 错缝石垒 + 外城齿 + 内侧墙道。顶点色全部为 COLOR_0。")

build("_tint.png",
      "低多边形建筑素材 / 第 2 稿 - 材质色 x 阵营色",
      "模拟现有 shader 直接相乘的结果：己方黄 #ffd166，按类型暗化后与顶点色相乘",
      "sheet2_tint.png",
      "相乘后材质色会被阵营色压成同色系（木墙偏橄榄、石墙偏土黄）——敌我识别还在，材质感明显变弱。")
