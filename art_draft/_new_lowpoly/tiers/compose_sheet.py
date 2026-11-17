# -*- coding: utf-8 -*-
"""把 tiers/*.png 拼成两张对比图（各级建筑摆在一起看）。

跑法（仓库根目录）：python art_draft/_new_lowpoly/tiers/compose_sheet.py

输入：`tiers/*.png` —— Blender 正交渲染的**单个模型**（600×600，同一机位 / 光照；
      同一建筑的各级共用同一个正交比例，所以高度差是**直接可比**的）。
输出：
  · `tier_compare_base.png`      —— 大本营 1 / 2 / 3 级
  · `tier_compare_buildings.png` —— 五种非城墙建筑的 1 级 / 2 级
"""
import os

from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BASE)                      # art_draft/_new_lowpoly
BG = (24, 25, 27)
CARD = (33, 35, 38)
LINE = (58, 60, 64)
TEXT = (236, 238, 240)
DIM = (150, 156, 164)
ACCENT = (240, 196, 96)

FONT = next((p for p in (r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\simhei.ttf")
             if os.path.exists(p)), None)


def font(size: int):
    return ImageFont.truetype(FONT, size) if FONT else ImageFont.load_default()


def cell(name: str, size: int) -> Image.Image:
    img = Image.open(os.path.join(BASE, "%s.png" % name)).convert("RGB")
    return img.resize((size, size), Image.LANCZOS)


def compose_base() -> str:
    size, gap, margin = 420, 22, 30
    cells = [
        ("base_l1", "一本大本营", "base_l1_lowpoly.glb　主堡 + 屋顶（1.80 格高）"),
        ("base_l2", "二本大本营", "base_l2_lowpoly.glb　+ 露台栏杆（2.05）"),
        ("base", "三本大本营（现有）", "base_lowpoly.glb　+ 望楼 + 旗（2.37）"),
    ]
    w = margin * 2 + size * 3 + gap * 2
    h = margin + 80 + size + 58
    canvas = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(canvas)
    d.text((margin, 16), "大本营 · 三档模型", font=font(30), fill=TEXT)
    d.text((margin, 54),
           "三本 = 现有模型（一个顶点没动）；一本 / 二本是在它身上「从上往下拆」得到的："
           "同一机位、同一光照、同一正交比例", font=font(14), fill=DIM)
    for i, (name, title, note) in enumerate(cells):
        x = margin + i * (size + gap)
        y = margin + 80
        d.rectangle([x, y, x + size - 1, y + size - 1], fill=CARD, outline=LINE)
        canvas.paste(cell(name, size), (x, y))
        d.text((x + 6, y + size + 6), title, font=font(22), fill=TEXT)
        d.text((x + 6, y + size + 34), note, font=font(13), fill=DIM)
    out = os.path.join(ROOT, "tier_compare_base.png")
    canvas.save(out)
    return out


def compose_buildings() -> str:
    size, gap, margin, label_w = 320, 18, 26, 96
    # (建筑, 中文名, 左格文件, 右格文件, 左说明, 右说明)
    rows = [
        ("tower", "哨塔", "tower_l1", "tower",
         "1 级：露天哨台（无哨屋）", "2 级（现有）：加哨屋 + 屋顶"),
        ("watch_tower", "警戒塔", "watch_tower_l1", "watch_tower",
         "1 级：平顶石塔（无垛口 / 无旗）", "2 级（现有）：垛口 + 旗 + 挑廊"),
        ("farm", "粮田", "farm_l1", "farm",
         "1 级：有栅栏、矮苗、无稻草人", "2 级（现有）：高麦 + 稻草人"),
        ("mine", "矿脉", "mine_l1", "mine",
         "1 级：两根矿晶（贫矿）", "2 级（现有）：五根矿晶（富矿）"),
        ("house", "房屋", "house_l1", "house_l2",
         "1 级（现有）：单层小屋", "2 级：加高一层（门窗不改尺寸）"),
    ]
    w = margin * 2 + label_w + size * 2 + gap
    h = margin + 104 + len(rows) * (size + 46)
    canvas = Image.new("RGB", (w, h), BG)
    d = ImageDraw.Draw(canvas)
    d.text((margin, 16), "其余建筑 · 一级 / 二级", font=font(28), fill=TEXT)
    d.text((margin, 52),
           "木墙 / 石墙不做（它们本来就是「木墙 → 石墙」两档）；这里只列五种非城墙建筑",
           font=font(14), fill=DIM)
    # 列标题
    for j, label in enumerate(("1 级", "2 级")):
        x = margin + label_w + j * (size + gap)
        d.text((x + 4, margin + 78), label, font=font(18), fill=ACCENT)
    for i, (name, label, f1, f2, note1, note2) in enumerate(rows):
        y = margin + 104 + i * (size + 46)
        d.text((margin, y + size // 2 - 16), label, font=font(24), fill=TEXT)
        for j, (fn, note) in enumerate(((f1, note1), (f2, note2))):
            x = margin + label_w + j * (size + gap)
            d.rectangle([x, y, x + size - 1, y + size - 1], fill=CARD, outline=LINE)
            canvas.paste(cell(fn, size), (x, y))
            d.text((x + 6, y + size + 6), note, font=font(14), fill=DIM)
    out = os.path.join(ROOT, "tier_compare_buildings.png")
    canvas.save(out)
    return out


if __name__ == "__main__":
    print("saved", compose_base())
    print("saved", compose_buildings())
