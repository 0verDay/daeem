"""把 Godot 实拍图整理成 docs 里的三张交付图。

用法：python .ui-preview/compose_docs.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
PROJ = ROOT / "dev_gd_a" / "daeem"
DOCS = ROOT / "dev_gd_a" / "docs"
FONT = Path("C:/Windows/Fonts")
GOLD = (242, 181, 68, 255)
GOLD_SOFT = (242, 181, 68, 190)
GOLD_FAINT = (242, 181, 68, 70)
TEXT = (232, 227, 213, 255)
DIM = (169, 178, 189, 255)


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONT / ("msyhbd.ttc" if bold else "msyh.ttc")), size)


def plaque(img: Image.Image, xywh, lines, pad=18, fill=(9, 13, 18, 228), border=GOLD_SOFT,
           line_gap=22):
    x, y, w, h = xywh
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle([x, y, x + w, y + h], radius=3, fill=fill, outline=border, width=1)
    ty = y + pad
    for text, size, bold, color in lines:
        d.text((x + pad, ty), text, font=font(size, bold), fill=color)
        ty += size + line_gap
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def marker(img: Image.Image, cx: int, cy: int, label: str, r: int = 14):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GOLD, outline=(10, 12, 16, 255), width=2)
    f = font(17, True)
    bbox = d.textbbox((0, 0), label, font=f)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    d.text((cx - tw / 2, cy - th / 2 - 2), label, font=f, fill=(16, 12, 6, 255))
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def sheet():
    img = Image.open(PROJ / "_shot_kit.png").convert("RGB")
    img = plaque(
        img, (64, 1000, 1240, 56),
        [("实现：button_reticle.gd（画在按钮上面）· press_fx.gd（四角内扣）· fill_button.gd（状态 / 金闪）",
          15, False, DIM)],
        pad=14, fill=(11, 16, 22, 210), border=GOLD_FAINT,
    )
    img.save(DOCS / "ui_button_states.png")
    print("saved", DOCS / "ui_button_states.png", img.size)


def hero():
    img = Image.open(PROJ / "_shot_pose_bottom_hover.png").convert("RGB")

    # 页眉：放在 ai_test 按钮右边、雕版左缘的空白带里，用一块小牌而不是整条黑幕。
    img = plaque(
        img, (330, 36, 566, 118),
        [("UI 交互方案 · 2026.11.12", 32, True, TEXT),
         ("悬停 = 锁定 / 按下 = 扣入 / 松开 = 回声环 / 选中 = 金填充", 17, False, DIM)],
        pad=20, fill=(9, 13, 18, 215), border=GOLD_FAINT, line_gap=10,
    )

    # 引线（先画线，再盖标记）
    lead = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ld = ImageDraw.Draw(lead)
    ld.line([(1616, 944), (1608, 968)], fill=GOLD_SOFT, width=1)
    ld.line([(1852, 990), (1834, 1016)], fill=GOLD_SOFT, width=1)
    img = Image.alpha_composite(img.convert("RGBA"), lead).convert("RGB")

    # 三个标记：① 悬停中的「备战」 ② 光标 ③ 静息的文字导航
    img = marker(img, 1616, 944, "1")
    img = marker(img, 1852, 990, "2")
    img = marker(img, 1710, 438, "3")

    img = plaque(
        img, (60, 838, 828, 162),
        [("① 悬停：四角括号画在按钮内侧 4px，按下内扣", 20, False, TEXT),
         ("② 光标：可交互 = 金圈点；空白 / 不可点 = 箭头", 20, False, TEXT),
         ("③ 静息：文字导航只留 42% 短横线，不跟内容抢位置", 20, False, TEXT)],
        pad=18, fill=(9, 13, 18, 232), border=GOLD_SOFT, line_gap=12,
    )
    img.save(DOCS / "ui_menu_after.png")
    print("saved", DOCS / "ui_menu_after.png", img.size)


def cursor():
    img = Image.open(PROJ / "_shot_cursor_sheet.png").convert("RGB")
    img.save(DOCS / "ui_cursor_states.png")
    print("saved", DOCS / "ui_cursor_states.png", img.size)


if __name__ == "__main__":
    sheet()
    cursor()
    hero()
