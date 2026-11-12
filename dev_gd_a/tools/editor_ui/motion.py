"""editor_ui/motion.py —— 极小的逐帧动画引擎（零依赖，只用 `after()`）。

★ Tkinter 没有透明度也没有合成器，所谓「动效」只有三条路：
  改颜色、改坐标、改尺寸。所以这里的 API 就是「把 0..1 的进度交给回调」，
  至于回调里画什么，由控件自己决定。

★ 测试里默认关掉动效：`test_app.py` 那种 `root.update()` 循环如果每步都等
  150ms 动画，整套测试会慢到没法跑。判据见 `_auto_enabled()`。
"""

from __future__ import annotations

import os
import sys
import time
import tkinter as tk
from typing import Callable, Optional

from .tokens import FRAME_MS

ENABLED = True


def _auto_enabled() -> bool:
    raw = os.environ.get("DAEEM_UI_MOTION", "").strip().lower()
    if raw in ("0", "off", "false", "no"):
        return False
    if raw in ("1", "on", "true", "yes"):
        return True
    # 测试脚本（python .../test_app.py）里默认关掉，避免拖慢上千条断言。
    argv = " ".join(sys.argv[:2]).lower()
    return not ("test_" in argv or "unittest" in argv or "pytest" in argv)


ENABLED = _auto_enabled()


def set_enabled(flag: bool) -> None:
    global ENABLED
    ENABLED = bool(flag)


def ease_out(t: float) -> float:
    """先快后慢，界面动效的默认手感。"""
    t = max(0.0, min(1.0, t))
    return 1.0 - (1.0 - t) ** 3


def ease_in_out(t: float) -> float:
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def lerp_color(a: str, b: str, t: float) -> str:
    """两个 `#rrggbb` 之间插值；认不出来就返回 b。"""
    try:
        ar, ag, ab = int(a[1:3], 16), int(a[3:5], 16), int(a[5:7], 16)
        br, bg, bb = int(b[1:3], 16), int(b[3:5], 16), int(b[5:7], 16)
    except (ValueError, IndexError, TypeError):
        return b
    t = max(0.0, min(1.0, float(t)))
    return "#%02x%02x%02x" % (
        round(ar + (br - ar) * t),
        round(ag + (bg - ag) * t),
        round(ab + (bb - ab) * t),
    )


class Tween:
    """在一段时间内把 0→1 的进度推给 `on_frame(eased)`。

    ★ 每个 Tween 自己持有一个 after id；控件被销毁时静默停掉，不抛 TclError。
    """

    def __init__(self, widget: tk.Misc, duration_ms: int,
                 on_frame: Callable[[float], None],
                 on_done: Optional[Callable[[], None]] = None,
                 easing: Callable[[float], float] = ease_out) -> None:
        self.widget = widget
        self.duration = max(1, int(duration_ms))
        self.on_frame = on_frame
        self.on_done = on_done
        self.easing = easing
        self._after: Optional[str] = None
        self._t0 = 0.0
        self._running = False

    def start(self) -> "Tween":
        self.cancel()
        if not ENABLED or not self._alive():
            self.on_frame(1.0)
            if self.on_done:
                self.on_done()
            return self
        self._running = True
        self._t0 = time.perf_counter()
        self._tick()
        return self

    def cancel(self) -> None:
        self._running = False
        after, self._after = self._after, None
        if after is not None:
            try:
                self.widget.after_cancel(after)
            except (tk.TclError, ValueError):
                pass

    @property
    def running(self) -> bool:
        return self._running

    def _alive(self) -> bool:
        try:
            return bool(self.widget.winfo_exists())
        except tk.TclError:
            return False

    def _tick(self) -> None:
        self._after = None
        if not self._running or not self._alive():
            self._running = False
            return
        t = (time.perf_counter() - self._t0) * 1000.0 / self.duration
        if t >= 1.0:
            self._running = False
            self.on_frame(1.0)
            if self.on_done:
                self.on_done()
            return
        self.on_frame(self.easing(t))
        try:
            self._after = self.widget.after(FRAME_MS, self._tick)
        except tk.TclError:
            self._running = False


def animate(widget: tk.Misc, duration_ms: int,
            on_frame: Callable[[float], None],
            on_done: Optional[Callable[[], None]] = None) -> Tween:
    """一次性动画的快捷入口。"""
    return Tween(widget, duration_ms, on_frame, on_done).start()
