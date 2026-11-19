# -*- coding: utf-8 -*-
"""卡牌悬停面板 —— 方案渲染（1:1 真实尺寸，叠在真实游戏截图 / 纯底上）。

只做设计稿：配色 / 字体 / 牌面切角全部照抄工程里现有的 language
（config.json 的 theme.palette、assets/fonts/simhei.ttf、
 view/detail_v2.gd draw_plate() 的「投影 + 两层错位背牌 + 竖向渐变 + 黄铜边 + 内圈金线」）。

输出：
  01_insitu_unit.png      单位卡悬停（左侧浮窗）整屏
  01b_insitu_zoom.png     上面那块 2× 放大
  02_sheet_four_types.png 四类卡（单位 / 建筑 / 将领 / 科技）1:1 → 2× 排版图
  03_insitu_dual.png      「左右双联」版（左=身份，右=说明）
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = Path(__file__).parent
ROOT = Path(r"C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem")
SHOT = ROOT / "shots" / "hand_hover.png"
FONT_PATH = str(ROOT / "assets" / "fonts" / "simhei.ttf")
ICON_DIR = ROOT / "assets" / "ui" / "card_icon"

# ---------------------------------------------------------------- palette (config.json theme.palette)
ACCENT = (242, 181, 68)
ACCENT_BRIGHT = (255, 217, 138)
ACCENT_DEEP = (168, 122, 34)
LINE = (138, 117, 64)
LINE_SOFT = (74, 64, 41)
TEXT = (232, 227, 213)
TEXT_DIM = (169, 178, 189)
TEXT_FAINT = (107, 118, 132)
PANEL_TOP = (28, 36, 46)
PANEL_BOT = (10, 13, 18)

_F = {}


def font(sz):
    sz = int(round(sz))
    if sz not in _F:
        _F[sz] = ImageFont.truetype(FONT_PATH, sz)
    return _F[sz]


def tw(s, sz):
    return font(sz).getlength(s)


def txt(d, xy, s, sz, color, anchor="ls"):
    d.text(xy, s, font=font(sz), fill=color, anchor=anchor)


def tracked(d, xy, s, sz, color, track=1.4):
    x = xy[0]
    for ch in s:
        d.text((x, xy[1]), ch, font=font(sz), fill=color, anchor="ls")
        x += font(sz).getlength(ch) + track
    return x - xy[0] - track


def tracked_w(s, sz, track=1.4):
    return sum(font(sz).getlength(c) + track for c in s) - track


def wrap_cjk(s, sz, max_w):
    lines, cur = [], ""
    for ch in s:
        if ch == "\n":
            lines.append(cur)
            cur = ""
            continue
        if tw(cur + ch, sz) > max_w and cur:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        lines.append(cur)
    return lines


# ---------------------------------------------------------------- plate
def plate_pts(w, h, ox=0.0, oy=0.0, cut_x=16.0, cut_top=18.0, cut_bot=16.0):
    return [
        (ox, oy),
        (ox + w - cut_x, oy),
        (ox + w, oy + cut_top),
        (ox + w, oy + h),
        (ox + cut_x, oy + h),
        (ox, oy + h - cut_bot),
    ]


def plate_mask(w, h, **kw):
    m = Image.new("L", (int(w), int(h)), 0)
    ImageDraw.Draw(m).polygon(plate_pts(w, h, 0, 0, **kw), fill=255)
    return m


def gradient(w, h):
    img = Image.new("RGB", (int(w), int(h)))
    d = ImageDraw.Draw(img)
    for y in range(int(h)):
        t = y / max(1.0, h - 1.0)
        col = tuple(int(round(PANEL_TOP[i] + (PANEL_BOT[i] - PANEL_TOP[i]) * t)) for i in range(3))
        d.line([(0, y), (w, y)], fill=col)
    return img


def draw_plate(layer, x, y, w, h, cut_x=16.0, cut_top=18.0, cut_bot=16.0):
    """detail_v2.draw_plate() 的 PIL 版。layer 是透明图层（全屏大小），最后一次性合成。"""
    x, y, w, h = int(round(x)), int(round(y)), int(round(w)), int(round(h))
    # ① 投影
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).polygon(
        plate_pts(w, h, x + 6, y + 8, cut_x, cut_top, cut_bot), fill=(0, 0, 0, 120))
    sh = sh.filter(ImageFilter.GaussianBlur(6))
    layer.alpha_composite(sh)
    d = ImageDraw.Draw(layer)
    # ② 两层错位背牌
    for off, col in (((9, 7), (25, 30, 37, 240)), ((5, 4), (18, 22, 28, 240))):
        d.polygon(plate_pts(w, h, x + off[0], y + off[1], cut_x, cut_top, cut_bot),
                  fill=col, outline=(72, 63, 41, 160))
    # ③ 主牌：竖向渐变 + 黄铜边
    grad = gradient(w, h).convert("RGBA")
    mask = plate_mask(w, h, cut_x=cut_x, cut_top=cut_top, cut_bot=cut_bot)
    layer.paste(grad, (x, y), mask)
    d = ImageDraw.Draw(layer)
    pts = plate_pts(w, h, x, y, cut_x, cut_top, cut_bot)
    d.line(pts + [pts[0]], fill=(*ACCENT, 150), width=2, joint="curve")
    # ④ 内圈 1px 金线
    ins = 6.0
    ipts = plate_pts(w - 2 * ins, h - 2 * ins, x + ins, y + ins, cut_x, cut_top, cut_bot)
    d.line(ipts + [ipts[0]], fill=(*ACCENT, 60), width=1, joint="curve")
    return d


def corner_brackets(d, x, y, w, h, size=13, col=(*ACCENT, 100)):
    o = 9
    d.line([(x + o, y + o + size), (x + o, y + o), (x + o + size, y + o)], fill=col, width=2)
    d.line([(x + w - o - size, y + h - o), (x + w - o, y + h - o), (x + w - o, y + h - o - size)],
           fill=col, width=2)


def connector(d, x_edge, y_mid, side):
    """牌与卡之间的金色小菱形 + 一小段引线。side=+1 表示卡在右边。"""
    s = 5
    x0 = x_edge if side > 0 else x_edge - 8
    d.line([(x0, y_mid), (x0 + 8 * side, y_mid)], fill=(*ACCENT, 130), width=1)
    cx = x_edge + 11 * side
    d.polygon([(cx, y_mid - s), (cx + s, y_mid), (cx, y_mid + s), (cx - s, y_mid)],
              fill=(*ACCENT, 240))


# ---------------------------------------------------------------- layout
PAD = 15.0
NAME_FS = 19
TAG_FS = 10
COST_LABEL_FS = 9
COST_VALUE_FS = 17
DESC_FS = 12
DESC_LH = 18.0
CAP_FS = 9
CHIP_FS = 10
CHIP_H = 19.0


def layout(card, w):
    """把一张牌的全部纵向位置算出来（画和量高共用一份）。"""
    inner = w - 2 * PAD
    rule_y = 45.0
    L = {"w": w, "inner": inner, "rule_y": rule_y, "name_base": 31.0,
         "cost_base": None, "divider_y": None, "desc_top": None, "lines": [],
         "cap_y": None, "chips_y": None}
    y = rule_y
    if card.get("cost"):
        L["cost_base"] = rule_y + 27
        y = rule_y + 27 + 21
        L["divider_y"] = y
        y += 10
    else:
        y += 14
    L["desc_top"] = y
    L["lines"] = wrap_cjk(card.get("desc", ""), DESC_FS, inner)
    y += len(L["lines"]) * DESC_LH
    if card.get("traits"):
        L["cap_y"] = y + 15
        L["chips_y"] = L["cap_y"] + 7
        y = L["chips_y"] + CHIP_H
    L["note_y"] = None
    if card.get("note"):
        L["note_y"] = y + 13
        y += 20
    L["h"] = y + 14
    return L


def draw_panel(layer, x, y, card, side=+1, w=300.0, h=None, show_cost=True, show_name=True):
    card = dict(card)
    if not show_cost:
        card.pop("cost", None)
    L = layout(card, w)
    h = L["h"] if h is None else h
    x, y = int(round(x)), int(round(y))
    cut = dict(cut_x=16.0, cut_top=18.0, cut_bot=16.0)
    d = draw_plate(layer, x, y, w, h, **cut)
    inner = w - 2 * PAD
    # 抬头
    if show_name and card.get("name"):
        txt(d, (x + PAD, y + L["name_base"]), card["name"], NAME_FS, TEXT)
    tag = card.get("tag", "")
    if tag:
        tgw = tracked_w(tag, TAG_FS, 0.8)
        bw, bh = tgw + 15, 18
        bx, by = x + w - PAD - bw, y + 15
        d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=3,
                            fill=(*ACCENT, 22), outline=(*ACCENT, 95), width=1)
        tracked(d, (bx + 7.5, by + 13.5), tag, TAG_FS, ACCENT_BRIGHT, 0.8)
    # 金线（整条淡 + 左端亮头）
    ry = y + L["rule_y"]
    d.line([(x + PAD, ry), (x + w - PAD, ry)], fill=(*ACCENT, 58), width=1)
    d.line([(x + PAD, ry), (x + PAD + 34, ry)], fill=(*ACCENT, 210), width=1)
    # 造价格
    if card.get("cost"):
        cy = y + L["cost_base"]
        gx = x + PAD
        groups = card["cost"]
        for gi, (lbl, val) in enumerate(groups):
            lw = tracked(d, (gx, cy), lbl, COST_LABEL_FS, TEXT_FAINT, 1.6)
            txt(d, (gx + lw + 8, cy + 1), val, COST_VALUE_FS, ACCENT_BRIGHT)
            gx += lw + 8 + tw(val, COST_VALUE_FS) + 24
            if gi < len(groups) - 1:
                d.line([(gx - 13, cy - 12), (gx - 13, cy + 4)], fill=(*LINE_SOFT, 230), width=1)
        # 淡分隔线（与说明段落分开）
        d.line([(x + PAD, y + L["divider_y"]), (x + w - PAD, y + L["divider_y"])],
               fill=(*LINE_SOFT, 210), width=1)
    # 说明段落
    for i, line in enumerate(L["lines"]):
        txt(d, (x + PAD, y + L["desc_top"] + 12 + i * DESC_LH), line, DESC_FS, TEXT_DIM)
    # 特性胶囊
    if card.get("traits"):
        cap = y + L["cap_y"]
        tracked(d, (x + PAD, cap), "特 性", CAP_FS, TEXT_FAINT, 1.6)
        cx = x + PAD
        for tr in card["traits"]:
            tw_ = tracked_w(tr, CHIP_FS, 0.4)
            bw = tw_ + 15
            d.rectangle([cx, y + L["chips_y"], cx + bw, y + L["chips_y"] + CHIP_H - 1],
                        fill=(53, 43, 24, 245), outline=(*ACCENT, 150), width=1)
            tracked(d, (cx + 7.5, y + L["chips_y"] + 13.5), tr, CHIP_FS, ACCENT_BRIGHT, 0.4)
            cx += bw + 6
    # 置灰原因（warn 色，贴底一行）
    if card.get("note"):
        txt(d, (x + PAD, y + L["note_y"]), "· " + card["note"], 11, (229, 72, 77))
    corner_brackets(d, x, y, w, h)
    connector(d, x + w if side > 0 else x, y + h * 0.5, side)
    return h


def compose(base, panels):
    layer = Image.new("RGBA", base.size, (0, 0, 0, 0))
    for p in panels:
        draw_panel(layer, p["x"], p["y"], p["card"], p.get("side", +1),
                   p.get("w", 300.0), p.get("h"), p.get("show_cost", True),
                   p.get("show_name", True))
    img = base.convert("RGBA").copy()
    img.alpha_composite(layer)
    return img


# ---------------------------------------------------------------- content
UNIT = {
    "name": "骑手",
    "tag": "近战·骑兵",
    "cost": [("粮食", "80"), ("黄金", "160")],
    "desc": "轻骑突袭的骑兵，冲锋时撕开阵线；对步兵造成额外伤害，受远程伤害更少。",
}
BUILDING = {
    "name": "粮田",
    "tag": "建筑",
    "cost": [("粮食", "80")],
    "desc": "为己方提供源源不断的粮食。",
}
GENERAL = {
    "name": "将领 1",
    "tag": "将领",
    "cost": [("粮食", "100"), ("黄金", "100")],
    "traits": ["铁壁", "稳定"],
    "desc": "久经沙场的老将，凭铁壁之姿为全军稳住阵线。",
}
TECH = {
    "name": "粮食产量 I",
    "tag": "科技",
    "desc": "玩家总体粮食产能 +10%。",
}

CARD_L, CARD_R, CARD_T, CARD_B = 784, 1011, 668, 997
HAND_TOP = 812.0          # 手牌静止时的上缘（面板尽量停在它上面，不压同伴牌）
GAP = 26.0                # 牌身到卡面的净距（背牌 +9、投影 ~15、菱形都留在这段里）


def insitu_unit():
    base = Image.open(SHOT).convert("RGBA")
    w = 300.0
    h = layout(UNIT, w)["h"]
    x = CARD_L - GAP - w
    y = (CARD_T + CARD_B) / 2.0 - h / 2.0
    img = compose(base, [{"x": x, "y": y, "card": UNIT, "side": +1, "w": w}])
    img.convert("RGB").save(HERE / "01_insitu_unit.png", quality=95)
    # 右侧版（同一张卡：演示「卡在右半边时放右侧」的样子）
    img_r = compose(base, [{"x": CARD_R + GAP, "y": y, "card": UNIT, "side": -1, "w": w}])
    img_r.convert("RGB").save(HERE / "01c_insitu_right.png", quality=95)
    crop = (int(x) - 16, int(y) - 18, CARD_R + 26, CARD_B - 40)
    z = img.crop(crop)
    z = z.resize((z.width * 2, z.height * 2), Image.LANCZOS)
    z.convert("RGB").save(HERE / "01b_insitu_zoom.png", quality=95)
    print("unit", x, y, h)


def insitu_dual():
    base = Image.open(SHOT).convert("RGBA")
    left = {"name": "骑手", "tag": "近战·骑兵", "cost": [("粮食", "80"), ("黄金", "160")],
            "desc": ""}
    right = {"desc": "轻骑突袭的骑兵，冲锋时撕开阵线；对步兵造成额外伤害，受远程伤害更少。",
             "traits": ["对步兵伤害 +25%", "远程减伤 25%"]}
    lw, rw = 232.0, 258.0
    lh = layout(left, lw)["h"] - 6
    rh = layout(right, rw)["h"]
    lx = CARD_L - GAP - lw
    ly = (CARD_T + CARD_B) / 2.0 - lh / 2.0
    rx = CARD_R + GAP
    ry = (CARD_T + CARD_B) / 2.0 - rh / 2.0
    img = compose(base, [
        {"x": lx, "y": ly, "card": left, "side": +1, "w": lw, "h": lh},
        {"x": rx, "y": ry, "card": right, "side": -1, "w": rw, "show_name": False},
    ])
    img.convert("RGB").save(HERE / "03_insitu_dual.png", quality=95)
    print("dual", lx, ly, lh, rx, ry, rh)


def sheet():
    lock = dict(TECH)
    lock.update({"name": "骑士", "tag": "近战·骑兵",
                 "cost": [("粮食", "120"), ("黄金", "320")],
                 "desc": "重甲骑兵，冲锋时碾开阵线；高护甲，受远程伤害更少。",
                 "note": "需 3 级大本营"})
    cards = [(UNIT, "单位 · 名称 + 标签 + 造价 + 一句描述"),
             (BUILDING, "建筑 · 名称 + 造价 + 一句描述"),
             (GENERAL, "将领 · 名称 + 造价 + 特性 + 一句描述"),
             (TECH, "科技 · 名称 + 一句描述（无造价）"),
             (lock, "置灰牌 · 多一行原因（warn 色）")]
    pad = 30
    label_h = 40
    cell_w = 300 + 2 * pad
    heights = [layout(c, 300.0)["h"] + label_h + pad for c, _ in cards]
    row1 = max(heights[0:2])
    row2 = max(heights[2:4])
    row3 = heights[4]
    W = int(cell_w * 2)
    H = int(row1 + row2 + row3 + 30)
    sheet_img = Image.new("RGBA", (W, H), (17, 24, 32, 255))
    d = ImageDraw.Draw(sheet_img)
    for gx in range(0, W, 40):
        d.line([(gx, 0), (gx, H)], fill=(22, 30, 39, 255))
    for gy in range(0, H, 40):
        d.line([(0, gy), (W, gy)], fill=(22, 30, 39, 255))
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for i, (card, label) in enumerate(cards):
        col, row = i % 2, i // 2
        ox = col * cell_w + pad
        oy = (0 if row == 0 else (row1 if row == 1 else row1 + row2 + 10)) + label_h
        draw_panel(layer, ox, oy, card, +1 if col == 0 else +1)
        txt(d, (ox, oy - 14), card["name"], 15, TEXT)
        txt(d, (ox + tw(card["name"], 15) + 12, oy - 14), label, 12, TEXT_FAINT)
    sheet_img.alpha_composite(layer)
    sheet_img = sheet_img.resize((sheet_img.width * 2, sheet_img.height * 2), Image.LANCZOS)
    sheet_img.convert("RGB").save(HERE / "02_sheet_four_types.png")
    print("sheet", sheet_img.size)


if __name__ == "__main__":
    insitu_unit()
    insitu_dual()
    sheet()
