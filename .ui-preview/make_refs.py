"""生成四套「圆角卡片 Web UI」风格的参考图（同一屏：单位编辑器）。

只画 tkinter 真能做到的东西：纯色面、1px 发丝边框、Canvas 圆角、
轻微投影（多层半透明近似）、无模糊/无渐变玻璃。

用法：python .ui-preview/make_refs.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

OUT = Path(__file__).resolve().parent
S = 2  # 超采样，圆角和文字边缘更干净
W, H = 1280, 820

FONT_DIR = Path("C:/Windows/Fonts")
_FONTS: dict[tuple[int, bool], ImageFont.FreeTypeFont] = {}


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    key = (size, bold)
    if key not in _FONTS:
        name = "msyhbd.ttc" if bold else "msyh.ttc"
        _FONTS[key] = ImageFont.truetype(str(FONT_DIR / name), size * S)
    return _FONTS[key]


class Comp:
    def __init__(self, style: dict) -> None:
        self.st = style
        self.img = Image.new("RGB", (W * S, H * S), style["bg"])
        self.draw = ImageDraw.Draw(self.img)

    # ---------- 基本图元 ----------
    def rect(self, x, y, w, h, fill=None, outline=None):
        self.draw.rectangle([x * S, y * S, (x + w) * S, (y + h) * S],
                            fill=fill, outline=outline, width=S)

    def rr(self, x, y, w, h, r, fill=None, outline=None, width=1):
        self.draw.rounded_rectangle(
            [x * S, y * S, (x + w) * S, (y + h) * S],
            radius=r * S, fill=fill, outline=outline, width=max(1, round(width * S)))

    def shadow(self, x, y, w, h, r, alpha=70, dy=8, blur=14):
        layer = Image.new("RGBA", self.img.size, (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        d.rounded_rectangle(
            [x * S, (y + dy) * S, (x + w) * S, (y + h + dy) * S],
            radius=r * S, fill=(0, 0, 0, alpha))
        layer = layer.filter(ImageFilter.GaussianBlur(blur * S / 2))
        self.img = Image.alpha_composite(self.img.convert("RGBA"), layer).convert("RGB")
        self.draw = ImageDraw.Draw(self.img)

    def text(self, x, y, s, size=12, color=None, bold=False, anchor="lm"):
        self.draw.text((x * S, y * S), s, font=font(size, bold),
                       fill=color or self.st["text"], anchor=anchor)

    def tw(self, s, size=12, bold=False) -> float:
        return self.draw.textlength(s, font=font(size, bold)) / S

    # ---------- 组件 ----------
    def card(self, x, y, w, h, r=None, tint=None, shadow=True):
        st = self.st
        r = st["radius"] if r is None else r
        if shadow and st.get("shadow", 0):
            self.shadow(x, y, w, h, r, alpha=st["shadow"],
                        dy=st.get("shadow_dy", 8), blur=st.get("shadow_blur", 14))
        self.rr(x, y, w, h, r, fill=tint or st["surface"], outline=st["border"])

    def button(self, x, y, w, h, label, kind="ghost", size=12):
        st = self.st
        r = st.get("btn_radius", 9)
        if kind == "primary":
            fill, fg, border = st["accent"], st["accent_fg"], None
        elif kind == "danger":
            fill, fg, border = st["danger_bg"], st["danger"], st["danger_border"]
        elif kind == "ghost":
            fill, fg, border = st["surface2"], st["text"], None
        else:  # quiet
            fill, fg, border = None, st["dim"], None
        self.rr(x, y, w, h, r, fill=fill, outline=border)
        self.text(x + w / 2, y + h / 2, label, size=size,
                  color=fg, bold=(kind == "primary"))

    def chip(self, x, y, label, color, size=10, padx=8, h=20, fg=None):
        wid = self.tw(label, size) + padx * 2
        self.rr(x, y, wid, h, h / 2, fill=color)
        self.text(x + wid / 2, y + h / 2, label, size=size,
                  color=fg or self.st["chip_fg"])
        return wid

    def icon_chip(self, x, y, size, color, glyph=False):
        self.rr(x, y, size, size, size * 0.32, fill=color)
        if glyph:
            self.draw.ellipse([(x + size * 0.34) * S, (y + size * 0.34) * S,
                               (x + size * 0.66) * S, (y + size * 0.66) * S],
                              fill=self.st["surface"])

    def table(self, x, y, w, cols, rows, row_h=34, head_h=36, size=11,
              selected=0):
        st = self.st
        # 表头
        cx = x
        for label, cw, align in cols:
            if align == "right":
                self.text(cx + cw - 12, y + head_h / 2, label, size=size - 1,
                          color=st["dim"], bold=False, anchor="rm")
            else:
                self.text(cx + 12, y + head_h / 2, label, size=size - 1,
                          color=st["dim"], anchor="lm")
            cx += cw
        self.draw.line([x * S, (y + head_h - 0.5) * S, (x + w) * S, (y + head_h - 0.5) * S],
                       fill=st["border"], width=S)
        # 数据行
        for i, row in enumerate(rows):
            ry = y + head_h + i * row_h
            if i == selected:
                self.rr(x - 6, ry + 2, w + 12, row_h - 4, 8, fill=st["row_sel"])
            cx = x
            for (label, cw, align), cell in zip(cols, row):
                first = cx == x
                col = st["text"] if first else st["text_soft"]
                if align == "right":
                    self.text(cx + cw - 12, ry + row_h / 2, cell, size=size,
                              color=col, anchor="rm",
                              bold=(first and st.get("bold_first", True)))
                else:
                    self.text(cx + 12, ry + row_h / 2, cell, size=size,
                              color=col, bold=(first and st.get("bold_first", True)))
                cx += cw

    def card_header(self, x, y, w, title, right=None, kicker=None, tint=None):
        """卡片头：标题（+小图标）+ 右侧动作。返回内容起始 y。"""
        st = self.st
        hx = x
        if tint:
            self.icon_chip(x, y - 2, 26, tint, glyph=True)
            hx = x + 38
        self.text(hx, y + 11, title, size=13, bold=True)
        if kicker:
            self.text(hx + self.tw(title, 13, True) + 10, y + 12, kicker,
                      size=11, color=st["dim"])
        return y + 30


STYLES: dict[str, dict] = {
    # A —— 冷灰 + 靛蓝，分段式页签，紧凑（Linear / Vercel 仪表盘）
    "A": dict(
        name="A · 冷灰靛蓝（分段页签 / 紧凑）",
        bg="#0A0B0F", bar="#0A0B0F", surface="#13151B", surface2="#1B1E26",
        border="#262A34", text="#EDF0F5", text_soft="#C9CEDB", dim="#868C9C",
        accent="#7C8CFF", accent_fg="#0B0C12",
        row_sel="#1E2230", chip_fg="#DDE2EE",
        danger="#F26D6D", danger_bg="#2A1619", danger_border="#4A2328",
        ok="#3ECF8E", radius=12, btn_radius=8,
        shadow=26, shadow_dy=10, shadow_blur=18,
        tabs="segmented", density="compact",
        head_tint=None,
    ),
    # B —— 保留暖金，下划线页签，发丝边框（游戏工具的自然延续）
    "B": dict(
        name="B · 暖金深色（下划线页签 / 发丝边框）",
        bg="#0A0E13", bar="#0B1016", surface="#121A23", surface2="#18222D",
        border="#24303D", text="#E7EEF5", text_soft="#C2CEDB", dim="#8795A6",
        accent="#F2B544", accent_fg="#17120A",
        row_sel="#1D2A38", chip_fg="#F5E6C8",
        danger="#F87171", danger_bg="#2B1618", danger_border="#4C2427",
        ok="#3FB950", radius=12, btn_radius=8,
        shadow=40, shadow_dy=9, shadow_blur=16,
        tabs="underline", density="normal",
        head_tint=None,
    ),
    # C —— 浅色 Notion / Figma 风
    "C": dict(
        name="C · 浅色 Notion（白卡片 / 柔和投影）",
        bg="#F5F5F2", bar="#FFFFFF", surface="#FFFFFF", surface2="#F1F1EC",
        border="#E5E5DF", text="#33332D", text_soft="#55554E", dim="#7E7E76",
        accent="#2F6FEB", accent_fg="#FFFFFF",
        row_sel="#F0F4FF", chip_fg="#FFFFFF",
        danger="#D64545", danger_bg="#FCEEEE", danger_border="#F3D2D2",
        ok="#1F9D55", radius=14, btn_radius=9,
        shadow=26, shadow_dy=6, shadow_blur=16,
        tabs="underline", density="normal",
        head_tint=None,
    ),
    # D —— 深色 + 彩色图标芯片，大圆角，宽松（Dashboard）
    "D": dict(
        name="D · 彩色芯片（大圆角 / 宽松）",
        bg="#0D0F14", bar="#0D0F14", surface="#161A21", surface2="#1E232C",
        border="#272D38", text="#EAEEF4", text_soft="#C7CEDA", dim="#8A91A1",
        accent="#4FD18B", accent_fg="#07130C",
        row_sel="#1B2A24", chip_fg="#DFF6EA",
        danger="#F07171", danger_bg="#2A171A", danger_border="#492429",
        ok="#4FD18B", radius=18, btn_radius=10,
        shadow=34, shadow_dy=10, shadow_blur=20,
        tabs="pills", density="airy",
        head_tint=True,
    ),
}

TINTS = {"mint": "#4FD18B", "blue": "#5AA9FF", "violet": "#A78BFA", "amber": "#F2B544"}


def draw_topbar(c: Comp, active=0):
    st = c.st
    c.rect(0, 0, W, 62, fill=st["bar"])
    c.draw.line([0, 61 * S, W * S, 61 * S], fill=st["border"], width=S)

    # 品牌
    c.rr(24, 20, 22, 22, 7, fill=st["accent"])
    c.rr(31, 27, 8, 8, 2.5, fill=st["bar"])
    c.text(56, 31, "单位编辑器", size=14, bold=True)

    tabs = ["单位", "单位特性", "将领特性", "建筑"]
    tx = 176
    if st["tabs"] == "segmented":
        total = sum(c.tw(t, 12) + 32 for t in tabs) + 8
        c.rr(tx - 6, 14, total, 34, 10, fill=st["surface2"])
        x = tx + 4
        for i, t in enumerate(tabs):
            wseg = c.tw(t, 12) + 32
            if i == active:
                c.rr(x, 18, wseg - 6, 26, 8, fill=st["surface"])
            c.text(x + (wseg - 6) / 2, 31, t, size=12,
                   color=st["text"] if i == active else st["dim"],
                   bold=(i == active))
            x += wseg
    elif st["tabs"] == "underline":
        x = tx
        for i, t in enumerate(tabs):
            tw_ = c.tw(t, 12)
            c.text(x, 30, t, size=12,
                   color=st["text"] if i == active else st["dim"],
                   bold=(i == active))
            if i == active:
                c.rr(x, 50, tw_, 2.5, 1.5, fill=st["accent"])
            x += tw_ + 26
    else:  # pills
        x = tx
        for i, t in enumerate(tabs):
            tw_ = c.tw(t, 12) + 26
            if i == active:
                c.rr(x, 17, tw_, 30, 15, fill=st["surface"], outline=st["border"])
                c.rr(x + 11, 30, 5, 5, 2.5, fill=st["accent"])
                c.text(x + 22, 31, t, size=12, color=st["text"], bold=True)
            else:
                c.text(x + 12, 31, t, size=12, color=st["dim"])
            x += tw_ + 6

    # 右侧：路径 + 状态 + 按钮
    btns = [("另存为…", 86, "ghost"), ("重新载入", 92, "ghost"), ("保存", 74, "primary")]
    bx = W - 24
    for label, bw, kind in reversed(btns):
        bx -= bw
        c.button(bx, 16, bw, 30, label, kind=kind, size=12)
        bx -= 8
    c.rr(bx - 62, 22, 54, 18, 9, fill=st["surface2"])
    c.draw.ellipse([(bx - 55) * S, 29 * S, (bx - 49) * S, 35 * S], fill=st["ok"])
    c.text(bx - 44, 31, "已保存", size=10, color=st["dim"])
    c.text(bx - 74, 31, "data/config.json", size=11, color=st["dim"], anchor="rm")


UNIT_COLS = [
    ("id", 104, "left"), ("字", 40, "left"), ("名称", 96, "left"),
    ("归属", 64, "left"), ("血量", 52, "right"), ("攻击", 52, "right"),
    ("距离", 50, "right"), ("移速", 50, "right"), ("攻速", 50, "right"),
    ("视野", 50, "right"), ("造价 粮/金/人口", 142, "right"),
]

UNIT_ROWS = [
    ("spearman", "枪", "长枪兵", "步兵", "180", "11", "1", "0.6", "1", "8", "80 / 0 / 1"),
    ("longbowman", "弓", "长弓兵", "步兵", "115", "18", "4", "0.5", "1.4", "10", "120 / 0 / 1"),
    ("rider", "骑", "骑手", "骑兵", "150", "20", "1", "1.2", "0.9", "9", "80 / 160 / 1"),
    ("grain_cart", "粮", "粮车", "siege", "150", "0", "0", "0.6", "1", "6", "100 / 0 / 1"),
    ("knight", "士", "骑士", "骑兵", "365", "30", "1", "1", "6", "9", "120 / 320 / 1"),
    ("catapult", "车", "投石车", "siege", "265", "46", "6", "0.35", "3", "11", "360 / 360 / 1"),
]

RECRUIT_ROWS = [
    ("dy_guard", "协防军", "2", "100 / 0 / 2", "dynasty"),
    ("dy_royal", "御林军", "3", "120 / 100 / 3", "dynasty"),
]

GEN_COLS = [
    ("id", 96, "left"), ("阶", 40, "left"), ("派系", 110, "left"),
    ("名字", 190, "left"), ("类型", 120, "left"), ("血量", 52, "right"),
    ("攻击", 52, "right"), ("移速", 52, "right"), ("造价", 96, "right"),
]

GEN_ROWS = [
    ("general_1", "1", "原生 / 王朔", "将领 1 · 长枪兵 (spear)", "长枪兵", "180", "11", "0.6", "100 / 100"),
    ("general_2", "1", "原生 / 王朔", "将领 2 · 长弓兵 (longbow)", "长弓兵", "115", "18", "0.5", "100 / 100"),
    ("general_3", "1", "原生 / 王朔", "将领 3 · 骑手 (rider)", "骑兵", "150", "20", "1.2", "100 / 100"),
    ("general_4", "2", "原生 / 王朔", "将领 4 · 长枪兵（有单骑）", "长枪兵", "220", "16", "0.6", "150 / 150"),
]


def draw_screen(c: Comp, *, radius_note: bool = True):
    st = c.st
    draw_topbar(c)

    pad, gap, right_w = 20, 16, 318
    left_w = W - pad * 2 - gap - right_w
    x0, x1 = pad, pad + left_w + gap
    y0 = 62 + 18

    # ---------- 左：兵种 ----------
    c1h = 320
    c.card(x0, y0, left_w, c1h)
    tint = TINTS["mint"] if st.get("head_tint") else None
    cy = c.card_header(x0 + 20, y0 + 18, left_w - 40, "兵种", tint=tint)
    chip_x = x0 + 20 + c.tw("兵种", 13, True) + (38 if tint else 0) + 10
    c.chip(chip_x, y0 + 17, "6 条", st["surface2"], size=10, fg=st["dim"])
    c.button(x0 + left_w - 20 - 96, y0 + 14, 96, 28, "+ 新建兵种", kind="ghost", size=11)
    c.table(x0 + 20, cy + 6, left_w - 40, UNIT_COLS, UNIT_ROWS,
            row_h=30 if st["density"] == "compact" else 34, head_h=34)

    # ---------- 左中：将领 ----------
    c2h = 206
    y2 = y0 + c1h + gap
    c.card(x0, y2, left_w, c2h)
    tint = TINTS["blue"] if st.get("head_tint") else None
    cy = c.card_header(x0 + 20, y2 + 18, left_w - 40, "将领", tint=tint,
                       kicker="可加：阶 / 派系归属 / 数值都在改")
    c.button(x0 + left_w - 20 - 96, y2 + 14, 96, 28, "+ 新建将领", kind="ghost", size=11)
    c.table(x0 + 20, cy + 6, left_w - 40, GEN_COLS, GEN_ROWS, row_h=30, head_h=32,
            selected=-1)

    # ---------- 左下：组合招募单 ----------
    y3 = y2 + c2h + gap
    c3h = 792 - y3
    c.card(x0, y3, left_w, c3h)
    tint = TINTS["violet"] if st.get("head_tint") else None
    c.card_header(x0 + 20, y3 + 18, left_w - 40, "组合招募单", tint=tint,
                  kicker="一次出多个兵")
    c.button(x0 + left_w - 20 - 96, y3 + 14, 96, 28, "+ 新建组合", kind="ghost", size=11)
    c.table(x0 + 20, y3 + 56, left_w - 40,
            [("id", 110, "left"), ("名字", 150, "left"), ("出几个", 70, "right"),
             ("造价 粮/金/人口", 150, "right"), ("来源", 120, "left")],
            RECRUIT_ROWS, row_h=30, head_h=32, selected=-1)

    # ---------- 右：说明 ----------
    r1h = c1h
    c.card(x1, y0, right_w, r1h)
    tint = TINTS["amber"] if st.get("head_tint") else None
    cy = c.card_header(x1 + 20, y0 + 18, right_w - 40, "说明", tint=tint)
    lines = ["左边点一行 → 右边改它的全部数值；",
             "特性本身在「单位特性」/「将领特性」两页里改。",
             "",
             "改完按 Ctrl+S 保存，保存后 tab 左侧的",
             "「已保存」会变成「未保存」。",
             "",
             "拖右侧滚动条可以看下面的卡片。"]
    ly = cy + 10
    for ln in lines:
        c.text(x1 + 20, ly, ln, size=11, color=st["text_soft"])
        ly += 25

    # ---------- 右：选中详情 ----------
    y4 = y0 + r1h + gap
    c.card(x1, y4, right_w, 792 - y4)
    tint = TINTS["mint"] if st.get("head_tint") else None
    cy = c.card_header(x1 + 20, y4 + 18, right_w - 40, "选中 · spearman", tint=tint)
    kv = [("名称", "长枪兵"), ("归属", "步兵"), ("血量", "180"),
          ("攻击", "11"), ("射程", "1"), ("移速", "0.6"),
          ("攻速", "1"), ("视野", "8"), ("造价", "80 / 0 / 1")]
    ry = cy + 10
    for k, v in kv:
        c.text(x1 + 20, ry, k, size=11, color=st["dim"])
        c.text(x1 + right_w - 20, ry, v, size=11, anchor="rm")
        ry += 25
    c.button(x1 + 20, 792 - 20 - 32, right_w - 40, 32, "复制为新兵种", kind="ghost", size=11)

    # ---------- 状态栏 ----------
    c.draw.line([0, 792 * S, W * S, 792 * S], fill=st["border"], width=S)
    c.text(24, 806, "打开 data/config.json", size=11, color=st["dim"])
    c.text(W - 24, 806, "已保存", size=11, color=st["dim"], anchor="rm")


def render(key: str) -> Path:
    style = STYLES[key]
    c = Comp(style)
    draw_screen(c)
    img = c.img.resize((W, H), Image.LANCZOS)
    path = OUT / f"ref_{key}.png"
    img.save(path)
    return path


def contact_sheet(paths: dict[str, Path]) -> Path:
    tw, th = 640, 410
    pad, label_h = 16, 34
    sheet = Image.new("RGB", (tw * 2 + pad * 3, (th + label_h) * 2 + pad * 3), "#15171C")
    d = ImageDraw.Draw(sheet)
    for i, key in enumerate("ABCD"):
        img = Image.open(paths[key]).convert("RGB").resize((tw, th), Image.LANCZOS)
        x = pad + (i % 2) * (tw + pad)
        y = pad + (i // 2) * (th + label_h + pad)
        sheet.paste(img, (x, y + label_h))
        d.text((x + 2, y + 8), STYLES[key]["name"], font=font(13, True), fill="#D8DCE6")
    path = OUT / "ref_contact_sheet.png"
    sheet.save(path)
    return path


if __name__ == "__main__":
    paths = {k: render(k) for k in "ABCD"}
    sheet = contact_sheet(paths)
    for p in list(paths.values()) + [sheet]:
        print("saved", p)
