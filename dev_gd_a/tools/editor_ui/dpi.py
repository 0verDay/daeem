"""editor_ui/dpi.py —— 高 DPI 感知 + 全局缩放系数。

★ 为什么必须有：Windows 在 150% 缩放下，如果进程不声明 DPI 感知，
  系统会把整个窗口当位图**拉伸 1.5 倍**——文字、圆角、投影全糊。
  声明之后 Tk 直接在物理像素上绘制，字号按 `tk scaling` 放大，边缘是锐的。

★ 为什么还要 `SCALE`：声明感知后，字体会自动变大 1.5 倍，
  但代码里写死的像素（侧栏 476px、卡片 14px 圆角、表格行高 30px）不会变，
  于是文字撑破布局。所以所有**结构性像素**都要乘同一个系数。

★ 只在交互入口（各编辑器的 `run()`）里调用 `enable_high_dpi()`；
  测试直接 new `EditorApp` 时不调用，缩放系数 = 1.0，断言一个都不用改。
"""

from __future__ import annotations

import sys
import tkinter as tk

_SCALE = 1.0
_ENABLED = False


def enable_high_dpi() -> bool:
    """声明「本进程自己处理缩放」。重复调用无副作用；非 Windows 直接返回 False。"""
    global _ENABLED
    if _ENABLED:
        return True
    if sys.platform != "win32":
        return False
    try:
        import ctypes

        try:
            # 2 = PER_MONITOR_AWARE_V2（Win10 1703+）
            ctypes.windll.shcore.SetProcessDpiAwareness(2)
        except Exception:  # noqa: BLE001 - 老系统没有 shcore
            ctypes.windll.user32.SetProcessDPIAware()
        _ENABLED = True
        return True
    except Exception:  # noqa: BLE001
        return False


def measure(root: tk.Misc) -> float:
    """当前窗口的缩放系数（96 DPI = 1.0）。"""
    try:
        return max(1.0, float(root.winfo_fpixels("1i")) / 96.0)
    except (tk.TclError, ValueError):
        return 1.0


def set_scale(value: float) -> float:
    global _SCALE
    try:
        _SCALE = max(1.0, float(value))
    except (TypeError, ValueError):
        _SCALE = 1.0
    return _SCALE


def scale() -> float:
    return _SCALE


def px(n: float) -> int:
    """把「设计稿里的像素」换成当前 DPI 下的像素。"""
    return int(round(float(n) * _SCALE))


def pxf(n: float) -> float:
    return float(n) * _SCALE


def scale_geometry(root: tk.Misc, geometry: str) -> str:
    """把 `"1280x820"` 按 DPI 放大（保留原有的 +x+y 偏移）。"""
    if not geometry:
        return geometry
    try:
        size, *rest = geometry.split("+")
        w, h = size.lower().split("x")
        out = "%dx%d" % (px(w), px(h))
        return "+".join([out] + rest) if rest else out
    except (ValueError, TypeError):
        return geometry
