"""editor_ui/paint.py —— 用图片画「真·抗锯齿」的圆角与投影。

★ 为什么需要它：`tk.Canvas` 的 `create_polygon` **不做抗锯齿**，
  14px 圆角放大看是台阶；而且没有 alpha 合成，露底的四个角只能涂成父容器纯色。
★ 这里用 Pillow 在内存里画（3 倍超采样 → LANCZOS 缩回），得到带 alpha 的 RGBA，
  `ImageTk.PhotoImage` 贴到 Canvas 上时由 Tk 与画布底色做逐像素混合 —— 角是真透明的，
  投影是高斯模糊出来的，不是「画两个偏移矩形」。

★ 依赖是可选的：没装 Pillow 时 `available()` 返回 False，
  控件自动退回原来的多边形画法（外观降级，功能不变）。
★ 缓存挂在 root 上：一套进程里测试会反复建/销毁 Tk，
  缓存跟着 root 一起死，不会出现「用着已销毁解释器的图片」。
"""

from __future__ import annotations

import tkinter as tk
from typing import Dict, Optional, Tuple

try:  # 可选依赖
    from PIL import Image, ImageDraw, ImageFilter, ImageTk

    _PIL = True
except Exception:  # noqa: BLE001 - 没装 Pillow 也要能跑
    Image = ImageDraw = ImageFilter = ImageTk = None  # type: ignore[assignment]
    _PIL = False

#: 超采样倍数：2 倍足够（3 倍画质提升很小，但耗时是 2 倍的 2.25 倍）
SS = 2

#: 单张图最大像素数：再大就退化成多边形（防止极端窗口尺寸卡死）
MAX_PIXELS = 4_000_000

_CACHE_ATTR = "_editor_ui_paint_cache"
_CACHE_LIMIT = 160


def available() -> bool:
    return _PIL


def _cache(root) -> Dict[tuple, tuple]:
    cache = getattr(root, _CACHE_ATTR, None)
    if cache is None:
        cache = {}
        setattr(root, _CACHE_ATTR, cache)
    return cache


def _hex_rgba(color: str, alpha: int = 255) -> Tuple[int, int, int, int]:
    try:
        return (int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16), alpha)
    except (ValueError, IndexError, TypeError):
        return (0, 0, 0, alpha)


def rounded_photo(root, width: int, height: int, radius: float,
                  fill: str, outline: str = "", border: int = 1,
                  shadow: Optional[Tuple[float, float, float]] = None,
                  ss: int = SS):
    """生成一张圆角图（可带投影），返回 `(PhotoImage, margin)`。

    · `shadow=(dy, blur, alpha)`：向下偏移 dy、高斯模糊 blur、黑底 alpha（0-255）。
    · `margin`：图片四周为投影留出的空白像素数 —— 贴图时坐标要减去它。
    · 失败（没装 Pillow / 尺寸过大 / 没有可用 root）时返回 `(None, 0)`。
    """
    if not _PIL or width <= 0 or height <= 0:
        return None, 0
    if width * height * (ss * ss) > MAX_PIXELS:
        return None, 0
    shadow = tuple(shadow) if shadow else None
    key = (int(width), int(height), round(float(radius), 1), fill, outline,
           int(border), shadow, ss, int(root.winfo_fpixels("1i")))
    cache = _cache(root)
    hit = cache.get(key)
    if hit is not None:
        cache.pop(key, None)
        cache[key] = hit      # LRU：最近用过的挪到末尾
        return hit

    try:
        w, h = int(width) * ss, int(height) * ss
        r = max(0.0, float(radius)) * ss
        img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, w - 1, h - 1], radius=r,
                            fill=_hex_rgba(fill),
                            outline=_hex_rgba(outline) if outline else None,
                            width=max(1, int(border * ss)))

        margin = 0
        if shadow:
            dy, blur, alpha = shadow
            pad = int(max(2.0, blur * 2.0 + abs(dy))) * ss
            margin = int(round(pad / ss))
            out = Image.new("RGBA", (w + pad * 2, h + pad * 2), (0, 0, 0, 0))
            # ★ 投影只画「形状」，模糊在半分辨率上做（视觉一样，快 4 倍）——
            #   900×300 的卡片从 ~150ms 降到 ~25ms，拉窗口才不卡。
            half = 2
            sw, sh = max(1, out.width // half), max(1, out.height // half)
            small = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
            ds = ImageDraw.Draw(small)
            ds.rounded_rectangle(
                [pad / half, (pad + dy * ss) / half,
                 (pad + w) / half, (pad + h + dy * ss) / half],
                radius=max(1.0, r / half), fill=(0, 0, 0, int(alpha)))
            small = small.filter(ImageFilter.GaussianBlur(max(0.5, blur * ss / half)))
            layer = small.resize(out.size, Image.BILINEAR)
            out = Image.alpha_composite(out, layer)
            body = Image.new("RGBA", out.size, (0, 0, 0, 0))
            body.alpha_composite(img, (pad, pad))
            out = Image.alpha_composite(out, body)
            img = out

        img = img.resize((img.width // ss, img.height // ss), Image.LANCZOS)
        photo = ImageTk.PhotoImage(img, master=root)
    except Exception:  # noqa: BLE001 - 画不出来就退化成多边形，绝不连累界面
        return None, 0

    if len(cache) >= _CACHE_LIMIT:
        cache.pop(next(iter(cache)), None)
    cache[key] = (photo, margin)
    return photo, margin



def _corner_tile(radius: int, fill: str, outline: str, border: int, ss: int):
    """左上角的小图（含 1px 圆弧描边），其余三角用 transpose 得到。"""
    size = int(radius) + 2
    canvas = Image.new("RGBA", (size * ss, size * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(canvas)
    # 画一个完整的圆角矩形，再裁左上角那块：圆弧就落在角上
    d.rounded_rectangle([0, 0, size * ss * 2 - 1, size * ss * 2 - 1],
                        radius=radius * ss, fill=_hex_rgba(fill),
                        outline=_hex_rgba(outline) if outline else None,
                        width=max(1, border * ss))
    tile = canvas.crop((0, 0, size * ss, size * ss))
    return tile.resize((size, size), Image.LANCZOS)


def corner_photos(root, radius: float, fill: str, outline: str = "",
                  border: int = 1):
    """返回四角图 `(tl, tr, bl, br)`，按 (半径, 颜色, DPI) 缓存。

    ★ 这是「9 宫格」画法：四角用抗锯齿小图，中间用普通矩形 + 1px 直线。
      好处是把成本从「随面积增长」（900×300 要 60ms）变成「一次 4 张小图」，
      而且大面板（地图画布那种 1200×1000）也不会退化。
    """
    if not _PIL or radius < 1:
        return None
    r = int(round(radius))
    key = ("corner", r, fill, outline, int(border), int(root.winfo_fpixels("1i")))
    cache = _cache(root)
    hit = cache.get(key)
    if hit is not None:
        cache.pop(key, None)
        cache[key] = hit
        return hit
    try:
        tl = _corner_tile(r, fill, outline, border, SS)
        tr = tl.transpose(Image.FLIP_LEFT_RIGHT)
        bl = tl.transpose(Image.FLIP_TOP_BOTTOM)
        br = bl.transpose(Image.FLIP_LEFT_RIGHT)
        photos = tuple(ImageTk.PhotoImage(img, master=root) for img in (tl, tr, bl, br))
    except Exception:  # noqa: BLE001
        return None
    if len(cache) >= _CACHE_LIMIT:
        cache.pop(next(iter(cache)), None)
    cache[key] = photos
    return photos



def check_photo(root, size: int, radius: float, fill: str, outline: str,
                ink: str = "", checked: bool = False, ss: int = 4):
    """勾选框的一整块图：圆角方块 + 对勾（对勾也抗锯齿，不用画布直线）。

    ★ 之前是「图片画方块 + `create_line` 画对勾」：14px 下 1.8px 的直线会糊成一坨，
      而且直线端点没有圆头，看起来像个小方块缺口。整体走一次栅格化就没这问题。
    """
    if not _PIL:
        return None
    key = ("check", int(size), round(float(radius), 1), fill, outline, ink,
           bool(checked), int(root.winfo_fpixels("1i")))
    cache = _cache(root)
    hit = cache.get(key)
    if hit is not None:
        cache.pop(key, None)
        cache[key] = hit
        return hit
    try:
        S = int(size) * ss
        img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rounded_rectangle([0, 0, S - 1, S - 1], radius=float(radius) * ss,
                            fill=_hex_rgba(fill),
                            outline=_hex_rgba(outline) if outline else None,
                            width=max(1, ss))
        if checked and ink:
            col = _hex_rgba(ink)
            wid = max(2, int(S * 0.14))
            pts = [(S * 0.28, S * 0.53), (S * 0.44, S * 0.69), (S * 0.74, S * 0.34)]
            d.line(pts, fill=col, width=wid, joint="curve")
            # 两端补圆头（PIL 的 line 只有中间接头是圆的）
            for (px, py) in (pts[0], pts[-1]):
                r = wid / 2.0
                d.ellipse([px - r, py - r, px + r, py + r], fill=col)
        photo = ImageTk.PhotoImage(img.resize((int(size), int(size)), Image.LANCZOS),
                                   master=root)
    except Exception:  # noqa: BLE001
        return None
    if len(cache) >= _CACHE_LIMIT:
        cache.pop(next(iter(cache)), None)
    cache[key] = photo
    return photo


def _blend(a: str, b: str, t: float) -> str:
    try:
        ar, ag, ab = int(a[1:3], 16), int(a[3:5], 16), int(a[5:7], 16)
        br, bg, bb = int(b[1:3], 16), int(b[3:5], 16), int(b[5:7], 16)
    except (ValueError, IndexError, TypeError):
        return b
    t = max(0.0, min(1.0, float(t)))
    return "#%02x%02x%02x" % (round(ar + (br - ar) * t),
                              round(ag + (bg - ag) * t),
                              round(ab + (bb - ab) * t))


def draw_rounded_x(canvas, x1: float, y1: float, x2: float, y2: float, radius: float,
                   fill: str, outline: str = "", border: int = 1, tags=(),
                   shadow=None):
    """在 Canvas 上画一个**抗锯齿圆角矩形**（9 宫格），可选软投影。返回 True 表示已绘制。

    · `shadow=(dy, spread, strength, shadow_color, bg_color)`：
      由外向内叠 `spread` 层 9 宫格，颜色从底色渐变到投影色——暗色下几乎看不见，
      浅色底上就是标准的网页投影。`spread` 同时也是调用方要预留的边距。
    ★ 画不出来（没装 Pillow / 半径太小）时返回 False，调用方退回多边形。
    """
    if shadow:
        dy, spread, strength, sh_color, bg = shadow
        spread = max(1, int(spread))
        for grow in range(spread, 0, -1):
            k = strength * (1.0 - (grow - 1) / float(spread))
            col = _blend(bg, sh_color, k)
            if not _nine_slice(canvas, x1 - grow, y1 - grow + dy, x2 + grow,
                               y2 + grow + dy, radius + grow, col, "", 0, tags):
                return False
    return _nine_slice(canvas, x1, y1, x2, y2, radius, fill, outline, border, tags)


def _nine_slice(canvas, x1, y1, x2, y2, radius, fill, outline="", border=1, tags=()):
    photos = corner_photos(canvas, radius, fill, outline, border)
    if not photos:
        return False
    r = int(round(radius))
    w, h = x2 - x1, y2 - y1
    if w <= 2 * r + 2 or h <= 2 * r + 2:
        return False
    tl, tr, bl, br = photos
    m = getattr(canvas, "_corner_photos", None)
    if m is None:
        m = {}
        canvas._corner_photos = m          # 防 GC：Tk 图片被回收就变空白
    m[id(photos)] = photos
    # 中间填充
    canvas.create_rectangle(x1 + r, y1, x2 - r, y2, fill=fill, outline="", tags=tags)
    canvas.create_rectangle(x1, y1 + r, x1 + r, y2 - r, fill=fill, outline="", tags=tags)
    canvas.create_rectangle(x2 - r, y1 + r, x2, y2 - r, fill=fill, outline="", tags=tags)
    # 四角
    canvas.create_image(x1, y1, image=tl, anchor="nw", tags=tags)
    canvas.create_image(x2, y1, image=tr, anchor="ne", tags=tags)
    canvas.create_image(x1, y2, image=bl, anchor="sw", tags=tags)
    canvas.create_image(x2, y2, image=br, anchor="se", tags=tags)
    # 四条边（圆角之间那一段）
    if outline:
        canvas.create_line(x1 + r, y1 + 0.5, x2 - r, y1 + 0.5, fill=outline,
                           width=border, tags=tags)
        canvas.create_line(x1 + r, y2 - 0.5, x2 - r, y2 - 0.5, fill=outline,
                           width=border, tags=tags)
        canvas.create_line(x1 + 0.5, y1 + r, x1 + 0.5, y2 - r, fill=outline,
                           width=border, tags=tags)
        canvas.create_line(x2 - 0.5, y1 + r, x2 - 0.5, y2 - r, fill=outline,
                           width=border, tags=tags)
    return True


def clear_cache(root) -> None:
    try:
        delattr(root, _CACHE_ATTR)
    except AttributeError:
        pass
