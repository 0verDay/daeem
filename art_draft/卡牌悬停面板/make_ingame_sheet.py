# -*- coding: utf-8 -*-
"""把四张**真机截图**里的「面板 + 卡牌」拼成一张对照表（2×2，1.5× 放大）。

输入：dev_gd_a/daeem/shots/card_hover_{unit,build,general,tech}.png
输出：04_ingame_sheet.png
坐标取自 tests/bench_card_hover_shot.gd 打印的 panel / card 矩形。
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).parent
SHOTS = Path(r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem\shots")
FONT = str(Path(r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem\assets\fonts\simhei.ttf"))
TEXT = (232, 227, 213)
DIM = (140, 150, 162)

CASES = [
    ("card_hover_unit", "单位 · 名称 + 标签 + 造价 + 简述（含置灰原因）",
     (408.75, 668.4, 300 + 24, 173), (734.75, 668.4, 214.5, 329.6), None),
    ("card_hover_build", "建筑 · 名称 + 造价 + 简述",
     (332.96, 670.0, 300 + 24, 135), (658.96, 670.0, 227.2, 329.6), None),
    ("card_hover_general", "将领 · 左：名称/造价/简述　右：将领特性（只有将领有两块）",
     (181.58, 672.4, 300 + 24, 135), (507.58, 672.4, 167.6, 329.6),
     (701.58, 672.4, 236 + 24, 110)),
    ("card_hover_tech", "科技 · 名称 + 简述（无造价）",
     (181.58, 672.4, 300 + 24, 91), (507.58, 672.4, 167.6, 329.6), None),
]

SCALE = 1.5
PAD = 18
LABEL_H = 34

font = ImageFont.truetype(FONT, 20)
tiles = []
for name, label, panel, card, extra in CASES:
    im = Image.open(SHOTS / (name + ".png")).convert("RGB")
    rects = [panel, card] + ([extra] if extra else [])
    x0 = int(min(r[0] for r in rects) - 14)
    y0 = int(min(r[1] for r in rects) - 10)
    x1 = int(max(r[0] + r[2] for r in rects) + 14)
    y1 = int(max(r[1] + r[3] for r in rects) + 12)
    c = im.crop((x0, y0, x1, y1))
    c = c.resize((int(c.width * SCALE), int(c.height * SCALE)), Image.LANCZOS)
    tiles.append((label, c))

cw = max(t[1].width for t in tiles) + PAD * 2
ch = max(t[1].height for t in tiles) + PAD * 2 + LABEL_H
W = cw * 2
H = ch * 2
sheet = Image.new("RGB", (W, H), (17, 24, 32))
d = ImageDraw.Draw(sheet)
for i, (label, im) in enumerate(tiles):
    col, row = i % 2, i // 2
    x = col * cw + PAD
    y = row * ch + PAD
    d.text((x, y), label, font=font, fill=TEXT)
    sheet.paste(im, (x, y + LABEL_H))
sheet.save(HERE / "04_ingame_sheet.png")
print("wrote", sheet.size)
