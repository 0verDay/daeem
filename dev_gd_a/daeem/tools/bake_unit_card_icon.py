#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""bake_unit_card_icon.py —— 把单位原画烘成命令卡「单位」页的**图标蒙版**（默认金线线稿）。

用法（任意目录；路径按本文件位置接）：

    python tools/bake_unit_card_icon.py                       # 三版对比图（不写 assets/）
    python tools/bake_unit_card_icon.py --only rider,catapult --ascii
    python tools/bake_unit_card_icon.py --commit --style etch

产物：

    --preview（默认）→ ../../art_draft/card_icon/
        preview_<style>.png   每版一张 5×3 大图（220px，深底 + 主题金）
        preview_small.png     三版 × 全部单位，按**真实格子尺寸 86.67px** 排（这一张判断辨识度）
        contact_sheet.png     三版各一行，标注文件名（人眼总览）
    --commit --style=<v> → assets/ui/card_icon/<原画文件名>.png
        正式蒙版。`etch`：RGB = 白、A = 线覆盖率；
        `relief` / `flat`：RGB = 明暗（运行时乘主题金）、A = 形状。

★ 为什么只烘**蒙版**、不烘彩色图：
  线色必须跟着 `theme.palette.accent` 走（换主题不用重烘），且命令卡悬停时金色会
  自下而上填满格子 —— 图标必须跟着翻成「压金那一档」（view/unit_card_icon.gd 的
  `ink()`）。把颜色烤死就等于把这条规则焊死在 PNG 里。
  运行时只做 `draw_texture_rect(tex, rect, false, ink)`，零 shader。

★ 为什么这台机器能「抽线」，而上一版的**边线检测**不行：
  这套立绘是「平涂 + 一圈占 30~40% 面积的粗黑描边」。DoG 边线检测勾的是**描边的两侧**
  （两条平行线），低反差处还会断 —— 缩到 87px 就并成粗块 + 一截一截。
  现在 `etch` 走的是**细化（Zhang-Suen）**：把粗黑描边压成**一根中线**再加粗。
  粗黑边从此不是障碍，反而是**最好的线源**（它本来就在画线）。
  ⚠️ 连通域必须 8 连通，否则斜着走的骨架会被判成碎点整条删掉（见 `_components8`）。

⚠️ 换单位素材 / 加兵种之后要重跑一次（`--commit`），再让 Godot 导入：
   `<godot>_console.exe --headless --path . --import`
   缺 `.import` 时 `ResourceLoader.exists()` 为 false，运行时会**静默退回矢量兜底**，
   症状是「改了素材但画面没变」（tests/test_unit_art.gd 里记过同一个坑）。
"""

import argparse
import json
import math
import os
import re
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ------------------------------------------------------------------
# 参数（改这里就能调味道）
# ------------------------------------------------------------------

## 线掩膜的收边参数（见 `_finish_lines`）
LINE_BLUR = 0.55
LINE_CURVE_LO = 0.20
LINE_CURVE_HI = 0.72

## 画布边长。格子是 86.67 设计像素 —— 4.4 倍，留足缩小余量与手机放大。
SIZE = 384
## 四周内边距（相对 SIZE）。命令卡格子自己还有 1px 边框，不能再贴上去。
PAD = int(round(SIZE * 0.06))
## 内侧亮边宽度（像素）：浮雕「翻起来的那道边」。
RIM_PX = 3

## relief：剪影里的明暗 ramp（暗部深金 → 亮部亮金）。数值是**乘色前的灰度**。
## ★ 0.16 是比对过三档（0.42 / 0.28 / 0.16）之后定的：原画的粗黑描边在 0.42 档
##   只是「稍微暗一点」，整块看着像平涂贴了金；压到 0.16 才真正读成**凹槽**，
##   87px 的格子里轮廓也还立得住。别再往 0.08 调 —— 凹槽会黑成一片，图形散架。
RELIEF_DEEP = 0.16
RELIEF_BRIGHT = 1.0
## flat：纯剪影的灰度（亮边仍是 1.0）。
FLAT_LEVEL = 0.78

## etch：**金线线稿**（订单原话：「完全用金线代替」）。
##
## 做法 = 先抠出**原画的黑描边**，再把它**抽成一根中线**（Zhang-Suen 细化），最后加粗。
## ★ 为什么必须是「中线」而不是「描边的两侧」：描边本身就有 8~12px 粗（画到 384 画布上），
##   勾两侧会得到两条相距很近的平行线；87px 的格子里它们会并成一根粗块（上一版就是这个毛病，
##   见 preview_etch.png 里那些糊在一起的边）。中线一根就是一根，缩小后仍然是一条线。
## ★ 为什么线是「连的」：黑描边在原画里本来就是**连续的闭合曲线**，细化只会在
##   网格对角处断开 —— 所以下面用**8 连通**判连通域（用 4 连通会把斜线判成一地碎点，
##   上一版 `--style etch` 的「断裂像素」有一半是这个坑）。
ETCH_STROKE_LUM = 0.16      # 亮度低于它算「黑描边」。实测描边 <0.10~0.16，平涂色块 ≥0.19
ETCH_CLOSE = 1              # 细化前先闭运算（补上描边里的 1~2px 缝），半径 = 像素
ETCH_MIN_COMPONENT = 40     # 细化后丢掉小于这么多像素的碎线（噪点 / 描边上掉下来的毛刺）
ETCH_LINE_PX = 3            # 中线加粗半径（像素）。3 → 线宽 7px；画到 87px 格子 ≈ 1.5px

## **组合条目**（协防军 2 人 / 御林军 3 人）：一张蒙版里并排画好几个单位。
##
## ★ 排法是用户口径：2 个 =「o o」一排；3 个 =「o」在上、「o o」在下（三角）。
## ★ 线要比单兵那张**细**：组合里每个小人只占格子的一半 / 三分之一，
##   沿用单兵那档 1.5px 会把脸糊成一团。
## ★★ 组合**仍然画细线（骨架）而不是只画外轮廓**：实测只留轮廓时，30~40px 的人
##   会变成一块「土豆」，看不出是谁、甚至看不出是兵；骨架版虽然密一点，
##   **枪尖 / 弓弧 / 盾牌**这些辨识点还在（1:1 对比过四轮）。
## ★ 黑边阈值略收（0.13）、碎线阈值放大（120）：去掉脸缝那种最细的结构，
##   保留武器与甲胄的主线。
ETCH_LINE_PX_COMBO = 2
ETCH_MIN_COMPONENT_COMBO = 120
ETCH_STROKE_LUM_COMBO = 0.13
## 组合里每个小格之间的间距 / 相对整块内边距（比例）
COMBO_GAP = 0.035
## 每个小格内部的留白（相对该格短边）：小人别贴上相邻那格
COMBO_SLOT_PAD = 0.03

STYLES = ("relief", "flat", "etch")
## config 读一次就存下来（组合条目按兵种 id 反查 `sprite` 时每张都要问一次）。
_CFG_CACHE = {}

## 预览配色（只影响预览图，不影响产物）
PREVIEW_BG = (24, 33, 44)              # ≈ palette.bg_bottom #18212C
PREVIEW_FALLBACK_ACCENT = "#F2B544"    # 读不到 config 时的主题金


# ------------------------------------------------------------------
# 路径与源清单
# ------------------------------------------------------------------

def _paths():
    here = os.path.abspath(os.path.dirname(__file__))
    project = os.path.abspath(os.path.join(here, ".."))          # dev_gd_a/daeem
    repo = os.path.abspath(os.path.join(project, "..", ".."))    # 仓库根
    return project, repo


def _read_config(project):
    path = os.path.join(project, "data", "config.json")
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def discover_sprites(cfg):
    """config 里所有非空 `sprite` 值 → 去重后的 (文件名, res 路径, [兵种 id...])。

    ★ 不写死清单：以后加兵种 / 换素材，脚本自动跟上，不会漏烘一张。
    ★ 按**原画文件名**去重 —— 多个兵种复用同一张原画（dy_scout 与 rider 等），
      蒙版也就只有一张，这正是命令卡想要的（长得一样就是一样）。
    """
    found = {}

    def walk(node, owner=""):
        if isinstance(node, dict):
            if "id" in node and isinstance(node["id"], str):
                owner = node["id"]
            for k, v in node.items():
                if k == "sprite" and isinstance(v, str) and v.startswith("res://assets/"):
                    found.setdefault(v, [])
                    if owner and owner not in found[v]:
                        found[v].append(owner)
                elif isinstance(v, dict):
                    # 兵种表是 `"types": { "<兵种 id>": {... "sprite": ...} }` ——
                    # 这一层的 dict 就是兵种本身，key 即 id（没有单独的 id 字段）。
                    walk(v, k if "sprite" in v else owner)
                elif isinstance(v, list):
                    for item in v:
                        walk(item, owner)

    walk(cfg)
    by_name = {}
    for res, owners in found.items():
        base = os.path.splitext(os.path.basename(res))[0]
        by_name.setdefault(base, {"name": base, "res": res, "owners": []})
        by_name[base]["owners"] += owners
    return [by_name[k] for k in sorted(by_name)]


def discover_combos(cfg):
    """config 里所有**组合条目**（`spawn` 里 ≥2 个兵种）→ [{kind, types}]。

    ★ 为什么不写死「协防军 / 御林军」：用户口径是「哪些条目一次出多个兵」，
      不是「哪两个 id」。以后加一个一次出 4 个的组合，脚本自动跟上。
    """
    out = []
    seen = set()

    def walk(node):
        if isinstance(node, dict):
            spawn = node.get("spawn")
            kind = node.get("kind")
            if isinstance(spawn, list) and len(spawn) > 1 and isinstance(kind, str):
                types = [s.get("type") for s in spawn
                         if isinstance(s, dict) and isinstance(s.get("type"), str)]
                if len(types) > 1 and kind not in seen:
                    seen.add(kind)
                    out.append({"kind": kind, "types": types})
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(cfg)
    return out


def accent_color(project):
    """主题金（config theme.palette.accent）→ (r, g, b) 0~255。"""
    try:
        hexs = _read_config(project)["theme"]["palette"]["accent"]
        hexs = hexs.lstrip("#")
        return tuple(int(hexs[i:i + 2], 16) for i in (0, 2, 4))
    except Exception:
        hexs = PREVIEW_FALLBACK_ACCENT.lstrip("#")
        return tuple(int(hexs[i:i + 2], 16) for i in (0, 2, 4))


# ------------------------------------------------------------------
# 图像工具
# ------------------------------------------------------------------

def _premult_resize(img, tw, th):
    """带 alpha 的等比缩放。

    ★ 必须**预乘后再缩放**：直接 resize RGBA 会让透明区的黑渗进边缘，
      剪影边上一圈脏灰（PIL 是逐通道独立采样的）。
    """
    arr = np.asarray(img, dtype=np.float32) / 255.0
    arr[:, :, :3] *= arr[:, :, 3:4]
    pm = Image.fromarray((arr * 255.0).round().astype(np.uint8), "RGBA")
    pm = pm.resize((tw, th), Image.LANCZOS)
    out = np.asarray(pm, dtype=np.float32) / 255.0
    out[:, :, :3] /= np.maximum(out[:, :, 3:4], 1e-4)
    np.clip(out[:, :, :3], 0.0, 1.0, out=out[:, :, :3])
    return out


def fit_canvas(src):
    """原画 → SIZE×SIZE 画布（等比 contain-fit、水平居中、**底部对齐**）。

    返回 (rgb, alpha, lum)：三个都是 SIZE×SIZE 的 float32。
    """
    a = src.getchannel("A")
    bbox = a.point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox:
        src = src.crop(bbox)                    # 去掉原画的透明留白，剪影才够大
    cw, ch = src.size
    avail = SIZE - PAD * 2
    k = min(float(avail) / max(1, cw), float(avail) / max(1, ch))
    tw = max(1, int(round(cw * k)))
    th = max(1, int(round(ch * k)))
    fitted = _premult_resize(src.convert("RGBA"), tw, th)

    rgb = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    alpha = np.zeros((SIZE, SIZE), dtype=np.float32)
    x0 = (SIZE - tw) // 2
    y0 = SIZE - PAD - th                       # 底对齐：脚贴地
    rgb[y0:y0 + th, x0:x0 + tw] = fitted[:, :, :3]
    alpha[y0:y0 + th, x0:x0 + tw] = fitted[:, :, 3]
    lum = 0.2126 * rgb[:, :, 0] + 0.7152 * rgb[:, :, 1] + 0.0722 * rgb[:, :, 2]
    return rgb, alpha, lum


def _finish_lines(line, blur=LINE_BLUR):
    """线掩膜的**收边**：轻糊一圈，再过一条 S 曲线把灰边压掉。

    ★ 为什么不是「多糊一点」：运行时要把它从 384 缩到 ~80px（4.8 倍），
      糊多了缩下去就是一团灰（用户报的「图标有点糊」）；
      糊少了硬边直接缩会闪（摩尔纹）。
    ★ S 曲线（`LINE_CURVE_LO..HI`）把 alpha 拉成接近二值：下采样后线芯仍然是实的，
      边缘只留 1px 过渡 —— 这是「看着清楚」和「不闪」之间的那个点。
    """
    img = Image.fromarray((np.clip(line, 0.0, 1.0) * 255.0).astype(np.uint8), "L")
    if blur > 0:
        img = img.filter(ImageFilter.GaussianBlur(blur))
    a = np.asarray(img, dtype=np.float32) / 255.0
    span = max(1e-4, LINE_CURVE_HI - LINE_CURVE_LO)
    return np.clip((a - LINE_CURVE_LO) / span, 0.0, 1.0)


def _morph(mask, radius, mode):
    """形态学腐蚀 / 膨胀（PIL 的最小/最大值滤波，方形核）。"""
    if radius <= 0:
        return mask
    size = radius * 2 + 1
    img = Image.fromarray((np.clip(mask, 0.0, 1.0) * 255.0).round().astype(np.uint8), "L")
    img = img.filter(ImageFilter.MinFilter(size) if mode == "erode" else ImageFilter.MaxFilter(size))
    return np.asarray(img, dtype=np.float32) / 255.0


def _normalize_lum(lum, mask):
    """把原画亮度在**剪影内部**按 p2..p98 拉满 0..1。

    ★ 必须归一化：各张原画的曝光差得很远（早期占位图偏灰白、王朝系偏暗红）。
      不归一化的话，同一套 ramp 在粮车上是灰、在骑手上一片白。
    """
    inside = lum[mask > 0.5]
    if inside.size == 0:
        return np.zeros_like(lum)
    lo, hi = np.percentile(inside, (2.0, 98.0))
    if hi - lo < 1e-4:
        return np.full_like(lum, 0.5)
    return np.clip((lum - lo) / (hi - lo), 0.0, 1.0)


def _components8(mask, min_size):
    """按 **8 连通** 过滤连通域：只保留像素数 ≥ min_size 的。

    ★ 必须 8 连通：细化出来的骨架在「斜着走」的地方只有对角相邻的像素，
      用 4 连通会把它判成一串互不相连的碎点，然后被当成噪点整条删掉
      —— 屏幕上就是「线断成一节一节」。这正是上一版 etch 的元凶。
    """
    h, w = mask.shape
    seen = np.zeros_like(mask, bool)
    keep = np.zeros_like(mask, bool)
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or seen[y, x]:
                continue
            stack = [(y, x)]
            seen[y, x] = True
            pts = []
            while stack:
                cy, cx = stack.pop()
                pts.append((cy, cx))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dy == 0 and dx == 0:
                            continue
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
            if len(pts) >= min_size:
                for (py, px) in pts:
                    keep[py, px] = True
    return keep


def _thin(mask):
    """Zhang-Suen 细化：把一条粗描边压成**一根像素宽的中线**（bool 数组进、bool 数组出）。"""
    img = mask.copy()
    changed = True
    while changed:
        changed = False
        for step in (0, 1):
            p = np.pad(img, 1)
            P2 = p[0:-2, 1:-1]
            P3 = p[0:-2, 2:]
            P4 = p[1:-1, 2:]
            P5 = p[2:, 2:]
            P6 = p[2:, 1:-1]
            P7 = p[2:, 0:-2]
            P8 = p[1:-1, 0:-2]
            P9 = p[0:-2, 0:-2]
            nb = [P2, P3, P4, P5, P6, P7, P8, P9]
            count = sum(n.astype(np.uint8) for n in nb)
            seq = nb + [P2]
            turns = sum(((seq[i] == 0) & (seq[i + 1] == 1)).astype(np.uint8) for i in range(8))
            if step == 0:
                cond = (~P2 | ~(P4 & P6)) & (~P4 | ~(P6 & P8))
            else:
                cond = (~P2 | ~(P4 & P8)) & (~P2 | ~(P6 & P8))
            drop = img & (count >= 2) & (count <= 6) & (turns == 1) & cond
            if drop.any():
                img = img & ~drop
                changed = True
    return img


def _etch_lines(alpha, lum, line_px=ETCH_LINE_PX, min_comp=ETCH_MIN_COMPONENT,
                stroke_lum=ETCH_STROKE_LUM):
    """金线线稿：黑描边 → 中线 → 加粗，返回 0..1 的覆盖率图。

    @param line_px   加粗半径（像素）。**组合条目**用更细的一档
    @param min_comp  丢掉小于这么多像素的碎线
    @param stroke_lum 亮度低于它算「黑描边」。组合条目收得更紧（只留主轮廓）
    """
    solid = alpha > 0.5
    stroke = solid & (lum < stroke_lum)
    if not stroke.any():
        return np.zeros_like(alpha)
    # ① 闭运算：补上描边本身的小缝（否则细化后会在缝处断成两截）
    if ETCH_CLOSE > 0:
        stroke = _morph(stroke.astype(np.float32), ETCH_CLOSE, "dilate")
        stroke = _morph(stroke, ETCH_CLOSE, "erode") > 0.5
    # ② 抽中线
    skel = _thin(stroke)
    # ③ 丢掉碎线（8 连通）
    skel = _components8(skel, min_comp)
    # ④ 加粗成一圈可见的线
    line = _morph(skel.astype(np.float32), line_px, "dilate")
    # ⑤ 收边（轻糊 + 上一条曲线，见 `_finish_lines`）
    return _finish_lines(line)


def build_style(style, rgb, alpha, lum):
    """合成一版蒙版 → (SIZE, SIZE, 4) 的 uint8 RGBA。

    · `relief` / `flat`：RGB = 灰度明暗（运行时乘主题金），A = 形状。
    · `etch`：RGB = **纯白**（乘上去就是主题金本色），A = 线覆盖率。
    """
    a = np.clip(alpha, 0.0, 1.0)
    solid = (a > 0.5).astype(np.float32)
    inside = _morph(solid, RIM_PX, "erode")
    rim = np.clip(solid - inside, 0.0, 1.0)          # 内侧那一道亮边

    if style == "flat":
        shade = np.full_like(lum, FLAT_LEVEL)
        shade = np.maximum(shade, rim)
        out_a = a
    elif style == "relief":
        l = _normalize_lum(lum, solid)
        shade = RELIEF_DEEP + (RELIEF_BRIGHT - RELIEF_DEEP) * l
        shade = np.maximum(shade, rim)
        out_a = a
    else:  # etch：金线线稿（见 ETCH_* 与 `_etch_lines()`）
        line = _etch_lines(a, lum)
        shade = np.ones_like(line)
        out_a = line

    rgba = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
    rgba[:, :, :3] = shade[:, :, None]
    rgba[:, :, 3] = out_a
    return (rgba * 255.0).round().astype(np.uint8)


# ------------------------------------------------------------------
# 预览
# ------------------------------------------------------------------

def _tint(rgba, accent, bg=PREVIEW_BG):
    """模拟运行时：`rgb * accent` 再按 alpha 叠在格子底色上。"""
    a = rgba[:, :, 3:4].astype(np.float32) / 255.0
    rgb = rgba[:, :, :3].astype(np.float32) / 255.0 * (np.asarray(accent, np.float32) / 255.0)
    base = np.asarray(bg, np.float32) / 255.0
    out = base * (1.0 - a) + rgb * a
    return Image.fromarray((np.clip(out, 0, 1) * 255.0).round().astype(np.uint8), "RGB")


def _scaled(img, px):
    return img.resize((px, px), Image.LANCZOS)


def _ascii(rgba, cols=44):
    """终端里看一眼剪影形状（人工核对的最后一道）。"""
    a = np.asarray(Image.fromarray(rgba[:, :, 3], "L").resize((cols, cols), Image.BILINEAR),
                   dtype=np.float32) / 255.0
    ramp = " .:-=+*#%@"
    lines = []
    for y in range(cols):
        line = "".join(ramp[min(len(ramp) - 1, int(v * len(ramp)))] for v in a[y])
        lines.append(line.rstrip())
    return "\n".join(lines)


def write_previews(project, repo, masks, accent, styles):
    out_dir = os.path.join(repo, "art_draft", "card_icon")
    os.makedirs(out_dir, exist_ok=True)
    # ★ 三套东西分开出图：兵种（含组合）/ 建筑 / 科技 —— 混在一行里看不出细节。
    #   只按名字前缀分，不额外记账单。
    def _split(items):
        units, blds, techs = [], [], []
        for name, rgba in items:
            if name.startswith("building_"):
                blds.append((name, rgba))
            elif name.startswith("tech_"):
                techs.append((name, rgba))
            else:
                units.append((name, rgba))
        return units, blds, techs

    styles = list(styles)
    unit_masks = {}
    for st in styles:
        u, b, t = _split(masks[st])
        unit_masks[st] = u
        if st == styles[0]:
            extra = {"buildings": b, "techs": t}
    names = [n for n, _ in unit_masks[styles[0]]]

    # ① 每版一张 5×3 大图（220px）
    ## ⚠️ 每个子图必须**先缩到格子大小再贴**：`_tint()` 返回的是 SIZE×SIZE（384px）
    ##    原图，直接按 220px 间距贴会互相压盖、右边和下边被裁掉 ——
    ##    「预览图里有单位只剩一角 / 根本没显示」就是这一步的锅，不是蒙版坏了。
    big = 220
    for st in styles:
        cols = 5
        items = unit_masks[st]
        rows = (len(items) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * big, rows * big), PREVIEW_BG)
        for i, (name, rgba) in enumerate(items):
            sheet.paste(_scaled(_tint(rgba, accent), big), ((i % cols) * big, (i // cols) * big))
        path = os.path.join(out_dir, "preview_%s.png" % st)
        sheet.save(path, "PNG", optimize=True)
        print("[preview] %s" % path)

    # ② 真实格子尺寸（86.67px，取整 87）× 三版 —— 这一张判断辨识度
    cell = 87
    gap = 6
    width = len(names) * (cell + gap) + gap
    height = len(styles) * (cell + gap) + gap
    small = Image.new("RGB", (width, height), (12, 16, 21))
    for r, st in enumerate(styles):
        for c, (name, rgba) in enumerate(unit_masks[st]):
            tile = _scaled(_tint(rgba, accent), cell)
            small.paste(tile, (gap + c * (cell + gap), gap + r * (cell + gap)))
    path = os.path.join(out_dir, "preview_small.png")
    small.save(path, "PNG", optimize=True)
    print("[preview] %s  （三版 × 真实格子尺寸）" % path)

    # ③ 总览：三版各一行，大图 + 版名
    row_h = 120
    label_w = 190
    sheet = Image.new("RGB", (label_w + len(names) * (row_h + 4) + 8,
                              len(styles) * (row_h + 10) + 10), (12, 16, 21))
    draw = ImageDraw.Draw(sheet)
    for r, st in enumerate(styles):
        y = 10 + r * (row_h + 10)
        draw.text((8, y + row_h // 2 - 6), st, fill=(232, 227, 213))
        for c, (name, rgba) in enumerate(unit_masks[st]):
            tile = _scaled(_tint(rgba, accent), row_h)
            x = label_w + c * (row_h + 4)
            sheet.paste(tile, (x, y))
    path = os.path.join(out_dir, "contact_sheet.png")
    sheet.save(path, "PNG", optimize=True)
    print("[preview] %s" % path)

    # ④ 建筑 / 科技：单独两张（各自一行 160px + 真实尺寸 87px），并标注名字
    for key, title in (("buildings", "preview_buildings"), ("techs", "preview_techs")):
        items = extra.get(key, [])
        if not items:
            continue
        big2 = 160
        label_h = 18
        cols = 6
        rows = (len(items) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * (big2 + 8) + 8,
                                  rows * (big2 + 87 + label_h * 2 + 14) + 8), (12, 16, 21))
        d2 = ImageDraw.Draw(sheet)
        for i, (name, rgba) in enumerate(items):
            x = 8 + (i % cols) * (big2 + 8)
            y = 8 + (i // cols) * (big2 + 87 + label_h * 2 + 14)
            sheet.paste(_scaled(_tint(rgba, accent), big2), (x, y + label_h))
            sheet.paste(_scaled(_tint(rgba, accent), 87), (x + (big2 - 87) // 2, y + label_h + big2))
            d2.text((x, y), name, fill=(200, 196, 184))
        path = os.path.join(out_dir, "%s.png" % title)
        sheet.save(path, "PNG", optimize=True)
        print("[preview] %s  (%d 张)" % (path, len(items)))
    return out_dir


def _ensure_mipmaps(png_path):
    """把同名 `.import` 里的 `mipmaps/generate` 打开（文件不存在就跳过）。

    ★ 为什么非要开：蒙版是 384px、运行时要缩到 81px（4.7 倍）。不开 mipmap 直接
      线性采样，细线会闪、会断成一节一节 —— 那正是「图标看着毛刺」的来源之一。
    ★ 为什么在这里改而不是靠人记得：新烘出来的 `.import` 默认是 false，
      漏改的症状只在画面上，测试抓不到（尺寸 / 覆盖率都对）。
    """
    ip = png_path + ".import"
    if not os.path.isfile(ip):
        return False
    with open(ip, "r", encoding="utf-8") as f:
        text = f.read()
    if "mipmaps/generate=true" in text:
        return False
    new = text.replace("mipmaps/generate=false", "mipmaps/generate=true")
    if new == text:
        return False
    with open(ip, "w", encoding="utf-8", newline="") as f:
        f.write(new)
    return True


# ------------------------------------------------------------------
# 建筑：从 .glb 抽几何边线 → 等轴测线稿
# ------------------------------------------------------------------
#
# 建筑没有 2D 原画，只有 `assets/models/*_lowpoly.glb`。所以这里不是「描线」而是
# **真的把模型渲染成线稿**：
#   ① 读 glTF 的顶点 / 三角（只有一个 mesh，够用）；
#   ② 等轴测投影（方位角 42°、俯角 28°，接近游戏里那种 3/4 视角）；
#   ③ 只留**折角边**（相邻两面夹角 > BUILDING_CREASE_DEG）+ 边界边 ——
#      这样三角化产生的对角线不会被画出来；
#   ④ **背面剔除 + z-buffer 消隐**：只画看得见的边，否则墙里的梁会全透出来（像 X 光）。
#   ⑤ 线宽 BUILDING_LINE_PX，最后轻微糊一下防摩尔纹。
#
# ⚠️ 深度方向：投影后深度是「越大 = 离镜头越近」，所以 z-buffer 里存的是
#   **最大深度**、可见判据是 `d_edge >= d_buf - bias`。写反了的症状是
#   「几乎整张图被消隐掉、只剩几根线」（实测踩过）。

BUILDING_SIZE = SIZE
BUILDING_PAD = 34
BUILDING_CREASE_DEG = 14.0
BUILDING_LINE_PX = 3
BUILDING_AZ_DEG = 42.0
BUILDING_EL_DEG = 28.0

_GLTF_COMP = {5121: ("B", 1), 5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}


def discover_buildings(project):
    """`view/building_view_3d.gd` 的 `BUILDING_MODELS` → [{type, res}]。

    ★ 表只有一份（视图层那张），这里**解析它**而不是另抄一份：抄一份就会漂。
      解析失败时返回空表（宁可这次不烘，也不要烘出错的图）。
    """
    path = os.path.join(project, "view", "building_view_3d.gd")
    if not os.path.isfile(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    m = re.search(r"const BUILDING_MODELS := \{(.*?)\}", src, re.S)
    if not m:
        return []
    out = []
    for btype, res in re.findall(r'"([a-z_]+)":\s*"res://([^"]+)"', m.group(1)):
        if btype == "zone_center":      # 区划中心不可建造（不进建筑页）
            continue
        out.append({"type": btype, "res": "res://" + res})
    return out


def _glb_mesh(path):
    """glb → (顶点 (n,3), 三角 (m,3))。只取 POSITION + indices。"""
    data = open(path, "rb").read()
    off = 12
    chunks = []
    while off + 8 <= len(data):
        ln, ty = struct.unpack("<II", data[off:off + 8])
        off += 8
        chunks.append((ty, data[off:off + ln]))
        off += ln
    js = json.loads(chunks[0][1].decode("utf-8"))
    blob = chunks[1][1] if len(chunks) > 1 else b""
    verts, tris, base = [], [], 0
    for mesh in js.get("meshes", []):
        for pr in mesh["primitives"]:
            acc = js["accessors"][pr["attributes"]["POSITION"]]
            bv = js["bufferViews"][acc["bufferView"]]
            fmt, sz = _GLTF_COMP[acc["componentType"]]
            n = acc["count"]
            stride = bv.get("byteStride") or sz * 3
            start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
            pos = np.zeros((n, 3), np.float32)
            for i in range(n):
                pos[i] = struct.unpack_from("<3f", blob, start + i * stride)
            verts.append(pos)
            if "indices" in pr:
                ia = js["accessors"][pr["indices"]]
                ib = js["bufferViews"][ia["bufferView"]]
                ifmt, isz = _GLTF_COMP[ia["componentType"]]
                st = ib.get("byteStride") or isz
                s0 = ib.get("byteOffset", 0) + ia.get("byteOffset", 0)
                idx = np.frombuffer(blob, dtype=np.dtype("<" + ifmt),
                                    count=ia["count"], offset=s0)
            else:
                idx = np.arange(n, dtype=np.int32)
            tris.append(idx.reshape(-1, 3).astype(np.int32) + base)
            base += n
    v = np.concatenate(verts) if len(verts) > 1 else verts[0]
    t = np.concatenate(tris) if len(tris) > 1 else tris[0]
    return v, t


def _iso_project(v):
    """等轴测投影 → (屏幕 xy, 深度)。深度**越大越近**（见上面那段说明）。"""
    az = math.radians(BUILDING_AZ_DEG)
    el = math.radians(BUILDING_EL_DEG)
    ca, sa = math.cos(az), math.sin(az)
    ry = np.array([[ca, 0, -sa], [0, 1, 0], [sa, 0, ca]], np.float32)
    p = v @ ry.T
    ce, se = math.cos(el), math.sin(el)
    rx = np.array([[1, 0, 0], [0, ce, -se], [0, se, ce]], np.float32)
    p = p @ rx.T
    return np.stack([p[:, 0], -p[:, 1]], axis=1), -p[:, 2]


def _visible_edges(verts, tris):
    """折角 / 边界边。

    ★★ **边界边（只有一张面贴着）一律保留**，不看朝向。
       这些模型大多是「薄壳」（墙 / 塔身是一层片），边界边就是它的**外轮廓**；
       按朝向剔掉一半，画出来就像被刀切掉一块 —— 用户说的「剪影有些割裂」，
       一半是这个原因。
    ★ 有两张面的边才做「两张都朝后 ⇒ 不要」的剔除（那是模型内部的边）。
    """
    v0, v1, v2 = verts[tris[:, 0]], verts[tris[:, 1]], verts[tris[:, 2]]
    fn = np.cross(v1 - v0, v2 - v0)
    ln = np.linalg.norm(fn, axis=1)
    keep = ln > 1e-9
    tris, fn, ln = tris[keep], fn[keep], ln[keep]
    fn = fn / ln[:, None]
    front = fn[:, 2] > 0

    table = {}
    for ti in range(len(tris)):
        for a, b in ((0, 1), (1, 2), (2, 0)):
            i, j = int(tris[ti][a]), int(tris[ti][b])
            key = (i, j) if i < j else (j, i)
            table.setdefault(key, []).append(ti)

    cos_thr = math.cos(math.radians(BUILDING_CREASE_DEG))
    out = []
    for (i, j), faces in table.items():
        if len(faces) == 1:
            out.append((i, j))          # 薄壳的外轮廓：无条件保留（见上面说明）
            continue
        f0, f1 = faces[0], faces[1]
        if not front[f0] and not front[f1]:
            continue
        if abs(float(np.dot(fn[f0], fn[f1]))) >= cos_thr:
            continue
        out.append((i, j))
    return out


def _zbuffer(p2d, depth, tris):
    """三角形深度缓冲：每像素存**最小深度**（最近的表面）。

    ★ `_iso_project()` 返回的深度是「越大 = 离镜头越远」，所以最近 = 最小。
      可见判据写 `d_edge <= d_buf + bias`（见 `bake_building`）。
    """
    zb = np.full((BUILDING_SIZE, BUILDING_SIZE), np.inf, np.float32)
    for t in tris:
        q = p2d[t]
        zz = depth[t]
        x0, y0 = q.min(axis=0)
        x1, y1 = q.max(axis=0)
        ix0, iy0 = max(0, int(math.floor(x0))), max(0, int(math.floor(y0)))
        ix1 = min(BUILDING_SIZE - 1, int(math.ceil(x1)))
        iy1 = min(BUILDING_SIZE - 1, int(math.ceil(y1)))
        if ix1 < ix0 or iy1 < iy0:
            continue
        gx, gy = np.meshgrid(np.arange(ix0, ix1 + 1) + 0.5,
                             np.arange(iy0, iy1 + 1) + 0.5)
        ax, ay = q[0]
        bx, by = q[1]
        cx, cy = q[2]
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-12:
            continue
        w0 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        w1 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        w2 = 1.0 - w0 - w1
        inside = (w0 >= -1e-4) & (w1 >= -1e-4) & (w2 >= -1e-4)
        if not inside.any():
            continue
        d = w0 * zz[0] + w1 * zz[1] + w2 * zz[2]
        sub = zb[iy0:iy1 + 1, ix0:ix1 + 1]
        np.minimum(sub, np.where(inside, d, np.inf), out=sub)
    return zb


def _keep_large_components(mask, frac=0.10, floor=30):
    """只保留**够大**的连通块（面积 ≥ 最大块 × frac 且 ≥ floor 像素），其余丢掉。

    用于建筑：模型里可能带互不相连的碎件，投影后像贴在旁边的悬浮方块。
    ★ 判据是「相对最大块」而不是「相对整张图」：墙体那种细长结构整体占比很低，
      按全图比例会被误删。
    """
    h, w = mask.shape
    seen = np.zeros_like(mask, bool)
    comps = []
    for y in range(h):
        for x in range(w):
            if not mask[y, x] or seen[y, x]:
                continue
            stack = [(y, x)]
            seen[y, x] = True
            pts = []
            while stack:
                cy, cx = stack.pop()
                pts.append((cy, cx))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dy == 0 and dx == 0:
                            continue
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
            comps.append(pts)
    if not comps:
        return mask
    biggest = max(len(c) for c in comps)
    thr = max(floor, int(biggest * frac))
    keep = np.zeros_like(mask, bool)
    for pts in comps:
        if len(pts) >= thr:
            for (py, px) in pts:
                keep[py, px] = True
    return keep


def bake_building(project, entry):
    """一张建筑图标 → (384,384,4) uint8 RGBA（RGB 白、A 线）。"""
    path = os.path.join(project, entry["res"][len("res://"):].replace("/", os.sep))
    if not os.path.isfile(path):
        return None
    verts, tris = _glb_mesh(path)
    p2d, depth = _iso_project(verts)
    lo, hi = p2d.min(axis=0), p2d.max(axis=0)
    span = max(float(hi[0] - lo[0]), float(hi[1] - lo[1]), 1e-6)
    scale = (BUILDING_SIZE - BUILDING_PAD * 2) / span
    off = np.array([BUILDING_PAD, BUILDING_PAD], np.float32) \
        + ((BUILDING_SIZE - BUILDING_PAD * 2) - (hi - lo) * scale) * 0.5
    p = (p2d - lo) * scale + off
    d = depth * scale
    zb = _zbuffer(p, d, tris)
    # ★★ 空像素（没有任何三角形覆盖）必须单独判：那里的 zb 是 inf，
    #    `zz <= inf` 恒真 ⇒ 背后那些本来看不见的边会**漏画到空白区**（实测：墙上多几根悬空线）。
    #   先记住有没有覆盖，再向外扩 2px 让轮廓边（正好压在覆盖边界上）仍然算可见。
    covered = np.isfinite(zb)
    cov_img = Image.fromarray((covered * 255).astype(np.uint8), "L").filter(ImageFilter.MaxFilter(5))
    cov = np.asarray(cov_img) > 60
    zb = np.where(covered, zb, 1.0e6).astype(np.float32)

    img = Image.new("L", (BUILDING_SIZE, BUILDING_SIZE), 0)
    draw = ImageDraw.Draw(img)
    bias = BUILDING_LINE_PX * 1.8
    for (i, j) in _visible_edges(verts, tris):
        a, b = p[i], p[j]
        da, db = d[i], d[j]
        seg = float(np.hypot(*(b - a)))
        n = max(2, int(seg / 1.5))
        vis = np.zeros(n + 1, bool)
        for k in range(n + 1):
            u = k / n
            pt = a + (b - a) * u
            zz = da + (db - da) * u
            x, y = int(pt[0]), int(pt[1])
            vis[k] = (0 <= x < BUILDING_SIZE and 0 <= y < BUILDING_SIZE
                      and cov[y, x] and zz <= zb[y, x] + bias)
        # ★★ **补齐短缺口**：z-buffer 是逐像素采样的，同一条边前后两个采样点可能一个
        #   落在面内、一个落在边界外像素上 ⇒ 线上出现 1~3 个采样点的空洞，看着像虚线。
        #   把长度 ≤ GAP_FILL 的不可见段直接补成可见（真正的遮挡远长于此）。
        GAP_FILL = 6
        k = 0
        while k <= n:
            if vis[k]:
                k += 1
                continue
            k0 = k
            while k <= n and not vis[k]:
                k += 1
            run = k - k0
            inner_gap = k0 > 0 and k <= n      # 两端都有可见点 ⇒ 是「缺口」不是「末端」
            if inner_gap and run <= GAP_FILL:
                vis[k0:k] = True
        # 按可见段画折线（每段一次 draw，拐角处不会漏成小洞）
        k = 0
        while k <= n:
            if not vis[k]:
                k += 1
                continue
            k0 = k
            while k <= n and vis[k]:
                k += 1
            run = [(a + (b - a) * (t / n)) for t in range(k0, k)]
            if len(run) >= 2:
                draw.line([tuple(q) for q in run], fill=255,
                          width=BUILDING_LINE_PX, joint="curve")
            # ★ 单独一个采样点的可见段（尖角 / 短边）画成点，否则那根线就整个消失了
            elif len(run) == 1:
                qx, qy = run[0]
                draw.ellipse([qx - BUILDING_LINE_PX, qy - BUILDING_LINE_PX,
                              qx + BUILDING_LINE_PX, qy + BUILDING_LINE_PX], fill=255)
    # ★ 丢掉「离主体的碎块」：有些模型里带好几段互不相连的部件（石头墙 / 房屋尤其明显），
    #   投影到同一个画面后会出现悬浮的小方块。判据见 `_keep_large_components`。
    solid = np.asarray(img) > 0
    keep = _keep_large_components(solid, 0.14, 30)
    line = _finish_lines(keep.astype(np.float32))
    rgba = np.zeros((BUILDING_SIZE, BUILDING_SIZE, 4), np.uint8)
    rgba[:, :, :3] = 255
    rgba[:, :, 3] = (np.clip(line, 0, 1) * 255).round().astype(np.uint8)
    return rgba


# ------------------------------------------------------------------
# 科技：没有原画 → 按文字描述**画一版占位图形**
# ------------------------------------------------------------------
#
# 科技一条原画都没有（config 里只有 id / 名字 / 效果），所以这里是**纯手画的
# 矢量线稿**：一堆 0..1 空间里的折线 / 圆弧，按 id 挑一组，最后统一上金。
# ★ 每格右下角额外画 1~3 根短竖条 = **阶数**（I / II / III），这样同系列的三条
#   能一眼分出档位，而不用在图上挤罗马数字。
# ★ 图形只求「看得懂是哪一类」，细枝末节交给悬停面板的文案。

TECH_LINE_PX = 4
TECH_BOX = 0.82          # 图形占画布的比例（四周留白）
TECH_TICK = True         # 右下角阶数短条


def _tv(x, y):
    return (x, y)


def _tl(a, b):
    return [a, b]


def _tpoly(pts, closed=True):
    return list(pts) + ([pts[0]] if closed else [])


def _tarc(c, r, a0, a1, seg=26):
    return [(c[0] + r * math.cos(math.radians(a0 + (a1 - a0) * i / seg)),
             c[1] + r * math.sin(math.radians(a0 + (a1 - a0) * i / seg)))
            for i in range(seg + 1)]


def _tcircle(c, r, seg=32):
    return _tarc(c, r, 0, 360, seg)


# --- 各科技用的图形（每个返回一组折线，坐标 0..1、y 向下） ---
def _wheat():
    out = [_tl((0.50, 0.92), (0.50, 0.30))]
    for k, yy in enumerate((0.34, 0.46, 0.58)):
        w = 0.13 + k * 0.02
        out.append(_tl((0.50, yy), (0.50 - w, yy - 0.10)))
        out.append(_tl((0.50, yy), (0.50 + w, yy - 0.10)))
        out.append(_tarc((0.50 - w, yy + 0.02), 0.045, 200, 20, 8))
        out.append(_tarc((0.50 + w, yy + 0.02), 0.045, 160, -20, 8))
    out.append(_tarc((0.50, 0.30), 0.07, 180, 360, 10))
    return out


def _coin():
    """三枚叠起来的钱（比「圆里画花纹」稳：一眼就是钱，数量感也直接）。"""
    out = []
    for k, yy in enumerate((0.68, 0.56, 0.44)):
        rx, ry = 0.30, 0.11
        out.append(_tarc_c((0.50, yy), rx, ry))
        if k < 2:
            out.append(_tl((0.20, yy), (0.20, yy + 0.12)))
            out.append(_tl((0.80, yy), (0.80, yy + 0.12)))
    out.append(_tarc_c((0.50, 0.80), 0.30, 0.11, bottom=True))
    return out


def _tarc_c(c, rx, ry, bottom=False):
    """椭圆弧（钱币那种扁圆）。bottom=True 只画下半圈。"""
    pts = []
    for i in range(33):
        a = math.radians(360.0 * i / 32)
        pts.append((c[0] + rx * math.cos(a), c[1] + ry * math.sin(a)))
    if bottom:
        pts = pts[17:]
    return pts


def _wall_shield():
    return [_tpoly([(0.12, 0.30), (0.88, 0.30), (0.88, 0.62), (0.12, 0.62)]),
            _tl((0.12, 0.46), (0.88, 0.46)),
            _tl((0.34, 0.30), (0.34, 0.62)), _tl((0.62, 0.30), (0.62, 0.62)),
            _tpoly([(0.50, 0.56), (0.72, 0.64), (0.68, 0.84), (0.50, 0.92),
                    (0.32, 0.84), (0.28, 0.64)])]


def _helmet_cross():
    """头盔（正面）：穹顶 + 面部开口 + 颈甲，右边接一枚「+」（将领强化）。"""
    return [_tarc((0.42, 0.48), 0.28, 180, 360, 22),
            _tl((0.14, 0.48), (0.14, 0.66)), _tl((0.70, 0.48), (0.70, 0.66)),
            _tarc((0.42, 0.48), 0.28, 8, 40, 8),
            _tl((0.30, 0.66), (0.30, 0.82)), _tl((0.54, 0.66), (0.54, 0.82)),
            _tl((0.30, 0.82), (0.54, 0.82)),
            _tl((0.80, 0.60), (0.80, 0.86)), _tl((0.68, 0.73), (0.92, 0.73))]


def _house_people():
    return [_tpoly([(0.14, 0.52), (0.40, 0.26), (0.66, 0.52)], False),
            _tpoly([(0.22, 0.52), (0.22, 0.84), (0.58, 0.84), (0.58, 0.52)]),
            _tcircle((0.76, 0.46), 0.08),
            _tpoly([(0.62, 0.86), (0.62, 0.70), (0.90, 0.70), (0.90, 0.86)], False)]


def _chevrons():
    return [_tpoly([(0.20, 0.30), (0.46, 0.50), (0.20, 0.70)], False),
            _tpoly([(0.42, 0.30), (0.68, 0.50), (0.42, 0.70)], False),
            _tpoly([(0.64, 0.30), (0.90, 0.50), (0.64, 0.70)], False)]


def _shield_check():
    return [_tpoly([(0.50, 0.14), (0.82, 0.26), (0.78, 0.60), (0.50, 0.88),
                    (0.22, 0.60), (0.18, 0.26)]),
            _tpoly([(0.36, 0.50), (0.47, 0.62), (0.66, 0.38)], False)]


def _bell():
    return [_tarc((0.50, 0.46), 0.26, 180, 360, 18),
            _tl((0.24, 0.46), (0.20, 0.74)), _tl((0.76, 0.46), (0.80, 0.74)),
            _tl((0.20, 0.74), (0.80, 0.74)),
            _tcircle((0.50, 0.84), 0.06),
            _tl((0.50, 0.14), (0.50, 0.20))]


def _poly_crown():
    """王冠：三个尖 + 底沿（底沿一定要画，否则只像一条折线）。"""
    return _tpoly([(0.18, 0.70), (0.24, 0.34), (0.36, 0.54), (0.50, 0.30),
                   (0.64, 0.54), (0.76, 0.34), (0.82, 0.70)], False)


def _crown():
    bottom = _tpoly([(0.16, 0.70), (0.84, 0.70), (0.84, 0.80), (0.16, 0.80)])
    return [_poly_crown(), bottom]


def _banner():
    return [_tl((0.32, 0.14), (0.32, 0.90)),
            _tpoly([(0.32, 0.18), (0.72, 0.18), (0.64, 0.32), (0.72, 0.46),
                    (0.32, 0.46)]),
            _tl((0.20, 0.90), (0.44, 0.90))]


def _formation():
    """军阵：三排交错的人（横线 + 短竖），排与排错开。"""
    out = []
    for r, yy in enumerate((0.34, 0.54, 0.74)):
        off = 0.06 if r % 2 else 0.0
        for k in range(4):
            x = 0.18 + off + k * 0.20
            out.append(_tl((x, yy), (x, yy + 0.10)))
            out.append(_tcircle((x, yy - 0.06), 0.05))
    return out


def _field():
    """农田：三条垄 + 中间一株苗。"""
    out = []
    for k in range(3):
        yy = 0.62 + k * 0.12
        out.append(_tl((0.14, yy), (0.86, yy)))
    out.append(_tl((0.50, 0.56), (0.50, 0.28)))
    out.append(_tarc((0.50, 0.58), 0.10, 200, 340, 12))
    out.append(_tl((0.50, 0.34), (0.36, 0.24)))
    out.append(_tl((0.50, 0.34), (0.64, 0.24)))
    return out


def _plough():
    return [_tpoly([(0.12, 0.80), (0.62, 0.80)], False),
            _tl((0.52, 0.80), (0.52, 0.46)),
            _tpoly([(0.52, 0.46), (0.84, 0.38), (0.86, 0.58), (0.58, 0.60)]),
            _tcircle((0.24, 0.80), 0.10),
            _tcircle((0.44, 0.80), 0.07)]


def _spear_flag():
    return [_tl((0.56, 0.92), (0.56, 0.12)),
            _tpoly([(0.56, 0.12), (0.48, 0.26), (0.64, 0.24)]),
            _tl((0.10, 0.34), (0.34, 0.34)), _tl((0.10, 0.52), (0.34, 0.52)),
            _tl((0.10, 0.70), (0.34, 0.70))]


def _fence():
    out = []
    for k in range(4):
        x = 0.18 + k * 0.22
        out.append(_tl((x, 0.30), (x, 0.84)))
        out.append(_tpoly([(x, 0.30), (x + 0.05, 0.20), (x + 0.10, 0.30)], False))
    out.append(_tl((0.14, 0.46), (0.86, 0.46)))
    out.append(_tl((0.14, 0.68), (0.86, 0.68)))
    return out


def _flag_path():
    return [_tl((0.22, 0.90), (0.22, 0.30)),
            _tpoly([(0.22, 0.30), (0.60, 0.30), (0.60, 0.52), (0.22, 0.52)]),
            _tpoly([(0.34, 0.90), (0.74, 0.90)], False),
            _tpoly([(0.62, 0.78), (0.80, 0.90), (0.62, 0.78)], False)]


def _horseshoe():
    return [_tarc((0.50, 0.46), 0.28, 200, 340, 20),
            _tl((0.22, 0.60), (0.22, 0.80)), _tl((0.78, 0.60), (0.78, 0.80)),
            _tcircle((0.36, 0.32), 0.03), _tcircle((0.64, 0.32), 0.03),
            _tcircle((0.50, 0.18), 0.03)]


def _pickaxe():
    return [_tpoly([(0.24, 0.82), (0.66, 0.30)], False),
            _tarc((0.62, 0.28), 0.26, 150, 330, 14),
            _tcircle((0.68, 0.74), 0.16), _tcircle((0.68, 0.74), 0.09)]


def _wedge():
    return [_tpoly([(0.16, 0.34), (0.16, 0.68), (0.56, 0.50)]),
            _tl((0.60, 0.18), (0.60, 0.84)),
            _tl((0.72, 0.18), (0.72, 0.84)),
            _tl((0.84, 0.18), (0.84, 0.84))]


TECH_SHAPES = {
    "food_1": _wheat, "food_2": _wheat, "food_3": _wheat,
    "gold_1": _coin, "gold_2": _coin, "gold_3": _coin,
    "building_hp": _wall_shield,
    "leader_hp": _helmet_cross,
    "zone_population": _house_people,
    "tech_speed_rush": _chevrons,
    "tech_unbreakable": _shield_check,
    "dy_liyue": _bell,
    "dy_grace": _crown,
    "dy_formation": _formation,
    "dy_farming": _field,
    "dy_plow": _plough,
    "dg_levy": _spear_flag,
    "dg_enclosure": _fence,
    "dg_expedition": _flag_path,
    "dg_chivalry": _horseshoe,
    "dg_goldrush": _pickaxe,
    "dg_breakthrough": _wedge,
}


def discover_techs(cfg):
    """原生 + 两个派系的科技 → [{id, name, tier}]（顺序 = 九格顺序）。"""
    out = []
    seen = set()

    def take(node):
        if isinstance(node, dict):
            tid = node.get("id")
            if isinstance(tid, str) and tid not in seen and (
                    "name" in node or "label" in node):
                seen.add(tid)
                out.append({"id": tid, "name": node.get("name", node.get("label", tid)),
                            "tier": int(node.get("tier", 0) or 0),
                            "icon": node.get("icon", "")})
            for v in node.values():
                take(v)
        elif isinstance(node, list):
            for v in node:
                take(v)

    take(cfg.get("tech", {}).get("list", []))
    take(cfg.get("tech", {}).get("clan_list", []))
    return out


def bake_tech(entry):
    """一条科技 → (384,384,4) uint8 RGBA。没有专属图形时退回「钱币」占位。"""
    shapes = TECH_SHAPES.get(entry["id"])
    if shapes is None:
        shapes = _coin
    box = BUILDING_SIZE * TECH_BOX
    off = (BUILDING_SIZE - box) * 0.5 - BUILDING_SIZE * 0.02   # 给下面的阶数点留位置
    img = Image.new("L", (BUILDING_SIZE, BUILDING_SIZE), 0)
    draw = ImageDraw.Draw(img)
    for pts in shapes():
        pts = [(off + x * box, off + y * box) for (x, y) in pts]
        if len(pts) >= 2:
            draw.line(pts, fill=255, width=TECH_LINE_PX, joint="curve")
    # ★ 阶数：图形正下方居中摆 1~3 个**实心小方点**（不是罗马数字 —— 87px 下笔画糊成一片，
    #   点数反而一眼看得出「第几级」）。放在图形下方而不是角上，避免看着像散落的脏点。
    tier = int(entry.get("tier", 0) or 0)
    if TECH_TICK and tier > 0:
        side = max(6, int(BUILDING_SIZE * 0.026))
        gap = int(side * 1.2)
        total = tier * side + (tier - 1) * gap
        x0 = (BUILDING_SIZE - total) // 2
        y0 = int(off + box + BUILDING_SIZE * 0.035)
        for k in range(tier):
            x = x0 + k * (side + gap)
            draw.rectangle([x, y0, x + side, y0 + side], fill=255)
    line = _finish_lines(np.asarray(img, dtype=np.float32) / 255.0, blur=0.4)
    rgba = np.zeros((BUILDING_SIZE, BUILDING_SIZE, 4), np.uint8)
    rgba[:, :, :3] = 255
    rgba[:, :, 3] = (np.clip(line, 0, 1) * 255).round().astype(np.uint8)
    return rgba


# ------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------

def bake_one(style, abs_path):
    src = Image.open(abs_path).convert("RGBA")
    rgb, alpha, lum = fit_canvas(src)
    rgba = build_style(style, rgb, alpha, lum)
    stats = {
        "coverage": float((rgba[:, :, 3] > 24).mean() * 100.0),
        "shade_min": float(rgba[:, :, :3].min()) / 255.0,
        "shade_max": float(rgba[:, :, :3].max()) / 255.0,
    }
    return rgba, stats


# ------------------------------------------------------------------
# 组合条目（一次出 2 / 3 个兵）
# ------------------------------------------------------------------

def combo_boxes(count):
    """组合蒙版里每个小人的**插槽**矩形（画布坐标）：2 个一排；3 个上一下二。

    ★ 摆法就是用户口径：「协防军以『o o』摆放两个单位，御林军以『o / o o』摆放三个单位」。
    ★ 整块仍留 PAD 的内边距（和单兵那张同一档），所以并排的两个不会贴到格子边框上。
    """
    inner = SIZE - PAD * 2
    if count <= 1:
        return [(PAD, PAD, inner, inner)]
    gap = int(round(inner * COMBO_GAP))
    if count == 2:
        w = (inner - gap) // 2
        x0 = PAD + (inner - (w * 2 + gap)) // 2
        return [(x0, PAD, w, inner), (x0 + w + gap, PAD, w, inner)]
    # 3 个：上面一个居中，下面两个并排
    w = (inner - gap) // 2
    top_h = int(round(inner * 0.52))
    bot_h = inner - top_h
    top_x = PAD + (inner - w) // 2
    bot_x = PAD + (inner - (w * 2 + gap)) // 2
    return [
        (top_x, PAD, w, top_h),
        (bot_x, PAD + top_h, w, bot_h),
        (bot_x + w + gap, PAD + top_h, w, bot_h),
    ]


def fit_into(src, box):
    """把一张原画等比例塞进画布上的某个矩形（水平居中、**竖直居中**）。

    ★ 与 `fit_canvas()` 同一套 contain-fit，两点不同：
      · 落点是任意矩形（组合里每个小人按自己的格子缩放，不是整张缩了再切）；
      · **竖直居中**而不是底对齐 —— 一格小人只占格子宽度那么多，底对齐会让整组
        沉到格子下沿、上面空一大块（实测 Q 格就是这样）。居中之后上下留白对称。
    """
    x, y, w, h = box
    pad = int(round(min(w, h) * COMBO_SLOT_PAD))
    a = src.getchannel("A")
    bbox = a.point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox:
        src = src.crop(bbox)
    cw, ch = src.size
    k = min(float(max(1, w - pad * 2)) / max(1, cw), float(max(1, h - pad * 2)) / max(1, ch))
    tw = max(1, int(round(cw * k)))
    th = max(1, int(round(ch * k)))
    fitted = _premult_resize(src.convert("RGBA"), tw, th)
    rgb = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    alpha = np.zeros((SIZE, SIZE), dtype=np.float32)
    x0 = x + (w - tw) // 2
    y0 = y + (h - th) // 2
    rgb[y0:y0 + th, x0:x0 + tw] = fitted[:, :, :3]
    alpha[y0:y0 + th, x0:x0 + tw] = fitted[:, :, 3]
    return rgb, alpha


def bake_combo(style, project, combo):
    """一个组合条目 → 一张蒙版（好几个小人摆在同一个画布上）。"""
    boxes = combo_boxes(len(combo["types"]))
    rgb = np.zeros((SIZE, SIZE, 3), dtype=np.float32)
    alpha = np.zeros((SIZE, SIZE), dtype=np.float32)
    for i, tid in enumerate(combo["types"]):
        sprite = None
        try:
            cfg_sprite = _sprite_of_type(project, tid)
        except Exception:
            cfg_sprite = ""
        if cfg_sprite:
            p = os.path.join(project, cfg_sprite[len("res://"):].replace("/", os.sep))
            if os.path.isfile(p):
                sprite = Image.open(p).convert("RGBA")
        if sprite is None:
            print("[combo] 跳过 %s（%s 没有原画）" % (combo["kind"], tid))
            continue
        r, a = fit_into(sprite, boxes[i])
        rgb = np.maximum(rgb, r)
        alpha = np.maximum(alpha, a)
    lum = 0.2126 * rgb[:, :, 0] + 0.7152 * rgb[:, :, 1] + 0.0722 * rgb[:, :, 2]
    if style == "etch":
        line = _etch_lines(alpha, lum, ETCH_LINE_PX_COMBO, ETCH_MIN_COMPONENT_COMBO,
                           ETCH_STROKE_LUM_COMBO)
        rgba = np.zeros((SIZE, SIZE, 4), dtype=np.float32)
        rgba[:, :, :3] = 1.0
        rgba[:, :, 3] = line
    else:
        rgba = build_style(style, rgb, alpha, lum).astype(np.float32) / 255.0
    out = (np.clip(rgba, 0, 1) * 255.0).round().astype(np.uint8)
    stats = {
        "coverage": float((out[:, :, 3] > 24).mean() * 100.0),
        "shade_min": float(out[:, :, :3].min()) / 255.0,
        "shade_max": float(out[:, :, :3].max()) / 255.0,
    }
    return out, stats


def _sprite_of_type(project, unit_type):
    """兵种 id → 它的 `sprite` 路径（读 config；找不到返回空串）。"""
    if project not in _CFG_CACHE:
        _CFG_CACHE[project] = _read_config(project)
    types = _CFG_CACHE[project].get("unit", {}).get("types", {})
    entry = types.get(unit_type, {}) if isinstance(types, dict) else {}
    return entry.get("sprite", "") if isinstance(entry, dict) else ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true",
                    help="写 assets/ui/card_icon/（正式产物）；缺省只出对比图")
    ap.add_argument("--style", default="relief", choices=STYLES)
    ap.add_argument("--only", default="",
                    help="只处理这些原画（逗号分隔；缺省 = 全部）")
    ap.add_argument("--ascii", action="store_true", help="顺手在终端打几张剪影")
    args = ap.parse_args()

    project, repo = _paths()
    cfg = _read_config(project)
    accent = accent_color(project)
    sprites = discover_sprites(cfg)
    if args.only:
        keep = {s.strip() for s in args.only.split(",") if s.strip()}
        sprites = [s for s in sprites if s["name"] in keep]
        if not sprites:
            raise SystemExit("--only 没匹配到任何原画")

    print("原画 %d 张（去重后），主题金 #%02X%02X%02X"
          % (len(sprites), accent[0], accent[1], accent[2]))

    styles = (args.style,) if args.commit else STYLES
    combos = discover_combos(cfg)
    masks = {}
    for st in styles:
        masks[st] = []
        for s in sprites:
            abs_path = os.path.join(project, s["res"][len("res://"):].replace("/", os.sep))
            if not os.path.isfile(abs_path):
                print("[skip] 找不到：%s" % abs_path)
                continue
            rgba, stats = bake_one(st, abs_path)
            masks[st].append((s["name"], rgba))
            print("[%s] %-18s cov=%5.1f%%  shade=%.2f..%.2f  ← %s"
                  % (st, s["name"], stats["coverage"], stats["shade_min"],
                     stats["shade_max"], ", ".join(s["owners"][:4]) or "-"))
        # ★ 组合条目（一次出 2 / 3 个兵）：一张蒙版里排好几个小人，产物名 = combo_<条目 kind>
        for cb in combos:
            rgba, stats = bake_combo(st, project, cb)
            masks[st].append(("combo_" + cb["kind"], rgba))
            print("[%s] %-18s cov=%5.1f%%  shade=%.2f..%.2f  ← %s"
                  % (st, "combo_" + cb["kind"], stats["coverage"], stats["shade_min"],
                     stats["shade_max"], ", ".join(cb["types"])))

    # ★ 建筑：从 .glb 抽边线的等轴测线稿（与风格无关，三档产同一张）
    bld_sheet = []
    for b in discover_buildings(project):
        rgba = bake_building(project, b)
        if rgba is None:
            print("[skip] 建筑 %s 的模型读不到" % b["type"])
            continue
        bld_sheet.append(("building_" + b["type"], rgba))
        print("[build] %-18s cov=%5.1f%%" % ("building_" + b["type"],
                                              float((rgba[:, :, 3] > 24).mean() * 100.0)))
    # ★ 科技：没有原画，按文字描述画的占位线稿
    tech_sheet = []
    for t in discover_techs(cfg):
        rgba = bake_tech(t)
        tech_sheet.append(("tech_" + t["id"], rgba))
    print("[tech] %d 条 → %d 张占位图形" % (len(tech_sheet), len(tech_sheet)))
    for st in styles:
        masks[st] += bld_sheet + tech_sheet

    if args.ascii:
        for st in styles:
            for name, rgba in masks[st][:2]:
                print("\n=== %s / %s ===" % (st, name))
                print(_ascii(rgba))

    if args.commit:
        out_dir = os.path.join(project, "assets", "ui", "card_icon")
        os.makedirs(out_dir, exist_ok=True)
        for name, rgba in masks[args.style]:
            path = os.path.join(out_dir, name + ".png")
            Image.fromarray(rgba, "RGBA").save(path, "PNG", optimize=True)
            fixed = _ensure_mipmaps(path)
            print("[commit] %s  %.1f KB%s" % (path, os.path.getsize(path) / 1024.0,
                                              "  (mipmap on)" if fixed else ""))
        print("\n★ 记得让 Godot 导入：<godot>_console.exe --headless --path . --import")
    else:
        write_previews(project, repo, masks, accent, styles)

    return 0


if __name__ == "__main__":
    sys.exit(main())
