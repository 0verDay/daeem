"""editor_ui/widgets.py —— 四个编辑器共用的控件库（纯 tkinter，零依赖）。

★ 设计语言（2026.11「暖金深色 Web 卡片」）：
  · 页面底 `bg` → 卡片 `panel` → 卡内块 `surface2`，三层色阶；
  · 1px 发丝边框勾轮廓，阴影只留很轻的一层（暗色下几乎看不见，靠色阶分层）；
  · 金色只出现在「当前状态」：选中页签、主按钮、列表选中行。

★ 兼容性：老名字一个没删 —— `RoundedButton` / `RoundedCard` / `make_card` /
  `ACTIVE_UI` / `set_ui` / `shade` / `is_dark` / `rounded_rect` 全在，
  四个编辑器里既有的调用点不用改。

★ 三个基础容器，按「高度由谁决定」选：
  · `Card`          高度由内容决定（侧栏卡片）；
  · `RoundedPanel`  填满分配到的空间（主区 / 表格区 / 画布区）；
  · `make_card()`   侧栏分区卡片的工厂（标题 + 提示 + 分隔线 + 内容 frame）。
"""

from __future__ import annotations

import tkinter as tk
import zlib
from tkinter import ttk
from typing import Callable, Dict, Optional

from . import dpi, paint
from .motion import animate, lerp_color
from .tokens import (
    CARD_COLORS,
    CARD_PAD,
    DARK,
    DUR_BASE,
    DUR_FAST,
    FONT_BODY,
    FONT_SECTION,
    FONT_SMALL,
    RADIUS_L,
    RADIUS_M,
    RADIUS_S,
    SPACE_M,
    SPACE_S,
    STATUSBAR_H,
)

#: 圆角卡片给投影预留的边距（px）
SHADOW_M = 6

ACTIVE_UI: Dict[str, str] = DARK


def set_ui(ui: Dict[str, str]) -> None:
    global ACTIVE_UI
    ACTIVE_UI = ui


def ui() -> Dict[str, str]:
    return ACTIVE_UI


# ======================================================================
# 颜色小工具
# ======================================================================

def shade(color: str, amount: float) -> str:
    """把 `#rrggbb` 调亮（amount > 0）或调暗（amount < 0）；认不出来就原样返回。"""
    try:
        r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    except (ValueError, IndexError):
        return color

    def adj(v: int) -> int:
        if amount >= 0:
            return max(0, min(255, int(v + (255 - v) * amount)))
        return max(0, min(255, int(v * (1.0 + amount))))

    return "#%02x%02x%02x" % (adj(r), adj(g), adj(b))


def is_dark(color: str) -> bool:
    try:
        r, g, b = int(color[1:3], 16), int(color[3:5], 16), int(color[5:7], 16)
    except (ValueError, IndexError):
        return True
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) < 128.0


def blend(a: str, b: str, t: float) -> str:
    """把两个 `#rrggbb` 按 t（0 = a，1 = b）混合。"""
    return lerp_color(a, b, t)


def card_color(title: str) -> str:
    """按标题稳定地取一个卡片色（重建侧栏不会换色）。"""
    idx = zlib.crc32(title.encode("utf-8")) % len(CARD_COLORS)
    return CARD_COLORS[idx]


def _parent_bg(widget, fallback: str) -> str:
    try:
        return str(widget.cget("bg"))
    except (tk.TclError, AttributeError):
        return fallback


def rounded_rect(canvas: tk.Canvas, x1: float, y1: float, x2: float, y2: float,
                 r: float, **kw):
    """在画布上画一个圆角矩形（平滑多边形近似），返回图元 id。

    ★ 用 smooth 多边形而不是 arc：tk 的圆弧在 1px 描边下锯齿很明显，
      而平滑多边形在 12 段下肉眼已经看不出折线。
    """
    r = max(1.0, min(r, (x2 - x1) / 2.0, (y2 - y1) / 2.0))
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r,
           x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
           x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return canvas.create_polygon(pts, smooth=True, splinesteps=12, **kw)


def divider(parent, color: str = "", pady=(0, 0)) -> tk.Frame:
    """一条 1px 分隔线（卡片内部用 `line_soft`，比外框更弱）。"""
    ui_ = ACTIVE_UI
    line = tk.Frame(parent, bg=color or ui_.get("line_soft", ui_["line"]), height=1)
    line.pack(fill="x", pady=pady)
    return line


# ======================================================================
# 容器：Card（内容决定高度） / RoundedPanel（填满空间）
# ======================================================================

class Card(tk.Canvas):
    """**圆角卡片**：Canvas 画圆角底板，内容装进内嵌 frame（高度由内容决定）。

    ★ 为什么不用 `tk.Frame`：tk 的 Frame 没有圆角，方角就是「原生感」的来源。
      这里用 Canvas 当底板：四角填成父容器底色，圆角矩形只覆盖中间。
    ★ 尺寸：宽度跟父容器（`fill="x"`），高度由 `body` 的内容高度决定。
    """

    def __init__(self, master=None, radius: float = RADIUS_L, padding: int = 0,
                 fill: str = "", outline: str = "", bg: str = "", shadow: bool = False,
                 **kw):
        ui_ = ACTIVE_UI
        bg = bg or _parent_bg(master, ui_["bg"])
        self._chip_fill = fill or ui_["panel"]
        self._chip_outline = outline or ui_["line"]
        kw.setdefault("height", 1)
        super().__init__(master, bg=bg, highlightthickness=0, bd=0, takefocus=0, **kw)
        self.radius = dpi.pxf(radius)
        self.padding = dpi.px(padding)
        self.use_shadow = bool(shadow)
        # ★ 投影要画在卡片外面，所以画布比卡片本身每边多留 M 像素；
        #   body 也跟着内缩 M，视觉上卡片位置不变、只是小了一圈边。
        self._m = dpi.px(SHADOW_M) if self.use_shadow else 0
        self._bg_color = bg
        self._alpha = 1.0
        self._photo = None
        self.body = tk.Frame(self, bg=self._chip_fill)
        self._win = self.create_window((self.padding + self._m, self.padding + self._m),
                                       window=self.body, anchor="nw")
        self.body.bind("<Configure>", self._on_body)
        self.bind("<Configure>", self._on_canvas)
        self._redraw()

    # -- 尺寸 -------------------------------------------------------
    def _on_body(self, event) -> None:
        h = max(1, int(event.height) + 2 * (self.padding + self._m))
        # ★ 注意：tk.Canvas 的 -height 默认值是 **"7c"（7 厘米）**，
        #   直接 int(cget("height")) 会抛 ValueError，高度就再也设不回去了
        #   （实测表现：卡片底部多出两百多像素空白）。必须用 winfo_pixels 解析屏幕单位。
        try:
            current = float(self.winfo_pixels(str(self.cget("height"))))
        except (tk.TclError, ValueError):
            current = -1.0
        if abs(current - h) > 0.5:
            try:
                self.configure(height=h)
            except tk.TclError:
                pass
        self._redraw()

    def _on_canvas(self, event) -> None:
        w = max(1, int(event.width) - 2 * (self.padding + self._m))
        try:
            self.itemconfigure(self._win, width=w)
        except tk.TclError:
            pass
        self._redraw()

    # -- 画 --------------------------------------------------------
    def _redraw(self):
        try:
            w = max(1, self.winfo_width())
            h = max(1, self.winfo_height())
            if w <= 2 or h <= 2:
                return
            m = self._m
            self.delete("card")
            shadow = None
            if m:
                shadow = (dpi.px(2), m, 0.22,
                          ACTIVE_UI.get("shadow", "#000000"), self._bg_color)
            if not paint.draw_rounded_x(self, m, m, w - m, h - m, self.radius,
                                        self._chip_fill, self._chip_outline, 1,
                                        tags="card", shadow=shadow):
                rounded_rect(self, m, m, w - 1 - m, h - 1 - m, self.radius,
                             fill=self._chip_fill, outline=self._chip_outline,
                             width=1, tags="card")
            self.tag_lower("card")
        except tk.TclError:
            pass

    # -- 入场动效 ---------------------------------------------------
    def appear(self, delay_ms: int = 0) -> None:
        """卡片入场：内容从下方 8px 滑到位。"""
        if delay_ms:
            self.after(delay_ms, self._appear_now)
        else:
            self._appear_now()

    def _appear_now(self) -> None:
        try:
            if not self.winfo_exists():
                return
        except tk.TclError:
            return

        def frame(t: float) -> None:
            try:
                self.coords(self._win, self.padding + self._m,
                            self.padding + self._m + (1.0 - t) * 8)
            except tk.TclError:
                pass

        animate(self, DUR_BASE, frame)


class RoundedPanel(tk.Frame):
    """**圆角底板 + 内容区**：用来包「要填满空间」的东西（表格 / 画布 / 表单）。

    ★ 和 `Card` 的区别：Card 的高度由内容决定，Panel 由父容器决定（撑满）。
    ★ 内容放进 `self.body`；`fit_to_content()` 可以把它钉成内容高度
      （多张表纵向排列时用，否则 pack 会把几块平分成一样高）。
    """

    def __init__(self, master=None, radius: float = RADIUS_L, pad=None, fill: str = "",
                 outline: str = "", bg: str = "", **kw):
        ui_ = ACTIVE_UI
        bg = bg or _parent_bg(master, ui_["bg"])
        super().__init__(master, bg=bg, **kw)
        self.radius = dpi.pxf(radius)
        self._pad = (max(1, int(round(radius * 0.35))) if pad is None else int(pad))
        self._pad = dpi.px(self._pad)
        self._fill = fill or ui_["panel"]
        self._outline = outline or ui_["line"]
        self._bg_color = bg
        self._alpha = 1.0
        self._m = dpi.px(SHADOW_M)
        self._photo = None
        self.canvas = tk.Canvas(self, bg=bg, highlightthickness=0, bd=0, takefocus=0)
        self.canvas.place(x=0, y=0, relwidth=1, relheight=1)
        self.body = tk.Frame(self, bg=self._fill)
        self.body.place(x=self._pad + self._m, y=self._pad + self._m)
        self.bind("<Configure>", self._on_configure)

    def _on_configure(self, event) -> None:
        w = max(2, int(event.width) - 2 * (self._pad + self._m))
        h = max(2, int(event.height) - 2 * (self._pad + self._m))
        try:
            self.body.place_configure(width=w, height=h)
        except tk.TclError:
            pass
        self._redraw()

    def _redraw(self, w=None, h=None) -> None:
        try:
            w = w or self.winfo_width()
            h = h or self.winfo_height()
            if w <= 2 or h <= 2:
                return
            m = self._m
            self.canvas.delete("card")
            shadow = None
            if m:
                shadow = (dpi.px(2), m, 0.22,
                          ACTIVE_UI.get("shadow", "#000000"), self._bg_color)
            if not paint.draw_rounded_x(self.canvas, m, m, w - m, h - m, self.radius,
                                        self._fill, self._outline, 1, tags="card",
                                        shadow=shadow):
                rounded_rect(self.canvas, m, m, w - 1 - m, h - 1 - m, self.radius,
                             fill=self._fill, outline=self._outline, width=1,
                             tags="card")
        except tk.TclError:
            pass

    def apply_ui(self) -> None:
        ui_ = ACTIVE_UI
        try:
            self.configure(bg=self._bg_color)
            self.canvas.configure(bg=self._bg_color)
            self.body.configure(bg=self._fill)
            self._redraw()
        except tk.TclError:
            pass

    def appear(self) -> None:
        def frame(t: float) -> None:
            try:
                self.body.place_configure(y=self._pad + self._m + (1.0 - t) * 6)
            except tk.TclError:
                pass

        animate(self, DUR_BASE, frame)

    def fit_to_content(self, extra: int = 0) -> None:
        """把高度钉成「内容高度」，避免几个面板被 pack 平均分配。"""
        try:
            self.update_idletasks()
            # +4：Treeview 的请求高度不含表头最后那 1px 描边，不留余量最后一行会被切
            h = (self.body.winfo_reqheight() + 2 * (self._pad + self._m)
                 + int(extra) + dpi.px(4))
            self.pack_propagate(False)
            self.configure(height=h)
        except tk.TclError:
            pass


class PillButton(tk.Button):
    """**圆角按钮**（悬停 / 按压有过渡）。圆角就是按钮自己的 `image`。

    ★★ 为什么不是「盖一层 Canvas」：Tk 9 下 **`tk.Button` 的子控件不会被绘制**。
      同样一段 Canvas 代码放在 Frame 上正常，放在 Button 上完全不可见，
      结果就是「按钮永远是方的」——之前那个「悬停圆、移开方」的怪象根源在这。
    ★ 仍然是 `tk.Button`：`invoke` / `cget` / `configure` / `pack` 都是原生语义，
      四个编辑器和测试都不用改。
    """

    RADIUS = RADIUS_M

    def __init__(self, master=None, **kw):
        ui_ = ACTIVE_UI
        kw.setdefault("relief", "flat")
        kw.setdefault("bd", 0)
        kw.setdefault("highlightthickness", 0)
        kw.setdefault("takefocus", 0)
        kw.setdefault("cursor", "hand2")
        base = kw.get("bg") or ui_["panel_alt"]
        kw.setdefault("bg", base)
        kw.setdefault("fg", ui_["text"])
        kw.setdefault("activebackground", base)
        kw.setdefault("activeforeground", kw.get("fg", ui_["text"]))
        super().__init__(master, **kw)
        self._surround = _parent_bg(self.master, ui_["panel"])
        self._base = base
        self._cur = base
        self._hover = False
        self._active = False
        self._tween = None
        self._photo = None
        self._padded = False
        for seq, fn in (("<Enter>", self._on_enter), ("<Leave>", self._on_leave),
                        ("<ButtonPress-1>", self._on_press),
                        ("<ButtonRelease-1>", self._on_release)):
            self.bind(seq, fn, add="+")
        self.bind("<Configure>", lambda _e: self._redraw(), add="+")
        try:
            self.after_idle(self._redraw)
        except tk.TclError:
            pass

    # -- 原生语义透传 ----------------------------------------------
    def configure(self, cnf=None, **kw):
        if isinstance(cnf, str):
            return super().configure(cnf)
        if "bg" in kw:
            self._base = kw["bg"]
            self._cur = kw["bg"]
        result = super().configure(cnf, **kw)
        if "text" in kw or "font" in kw:
            # 文字变了要让按钮重新量尺寸，不然会被旧图钉死在原来的大小
            try:
                tk.Button.configure(self, image="")
            except tk.TclError:
                pass
            self._padded = False
        self._redraw()
        return result

    config = configure

    def _disabled(self) -> bool:
        try:
            return str(self.cget("state")) == "disabled"
        except tk.TclError:
            return False

    # -- 交互 ------------------------------------------------------
    def _on_enter(self, _e=None):
        self._hover = True
        self._target(self._hover_color())

    def _on_leave(self, _e=None):
        self._hover = False
        self._active = False
        self._target(self._base)

    def _on_press(self, _e=None):
        if not self._disabled():
            self._active = True
            self._target(self._press_color())

    def _on_release(self, _e=None):
        fire = self._active and not self._disabled()
        self._active = False
        self._target(self._hover_color() if self._hover else self._base)
        if fire:
            try:
                self.invoke()
            except tk.TclError:
                pass

    # -- 颜色 ------------------------------------------------------
    def _hover_color(self) -> str:
        if self._disabled():
            return self._base
        return shade(self._base, 0.12 if is_dark(self._base) else -0.07)

    def _press_color(self) -> str:
        if self._disabled():
            return self._base
        return shade(self._base, -0.10 if is_dark(self._base) else -0.05)

    def _target(self, color: str) -> None:
        if self._tween is not None:
            self._tween.cancel()
        start = self._cur

        def frame(t: float) -> None:
            self._cur = lerp_color(start, color, t)
            self._redraw()

        self._tween = animate(self, DUR_FAST, frame)

    # -- 画 --------------------------------------------------------
    def _redraw(self):
        try:
            w = max(1, self.winfo_width())
            h = max(1, self.winfo_height())
            if w <= 2 or h <= 2:
                return
            if self._disabled():
                fill = blend(self._base, self._surround, 0.55)
            else:
                fill = self._cur
            edge = shade(fill, 0.16 if is_dark(fill) else -0.10)
            outline = edge if fill != self._surround else ""
            r = min(dpi.px(self.RADIUS), h / 2.0)
            photo, _margin = paint.rounded_photo(self, w, h, r, fill, outline,
                                                 border=1, ss=2)
            if photo is None:                    # 没装 Pillow：退回纯色方块
                tk.Button.configure(self, image="", bg=fill, activebackground=fill)
                return
            self._photo = photo
            kw = {"image": photo, "compound": "center",
                  "bg": self._surround, "activebackground": self._surround}
            if not self._padded:
                kw.update(padx=0, pady=0)
                self._padded = True
            tk.Button.configure(self, **kw)
        except tk.TclError:
            pass


#: 旧名字（四个编辑器与旧代码里还在用）。
RoundedButton = PillButton
RoundedCard = Card


class LinkButton(tk.Label):
    """**文字按钮**（无底色，悬停时文字变亮）：用于卡片头右侧的「+ 新建」这类动作。"""

    def __init__(self, master=None, text: str = "", command: Optional[Callable] = None,
                 color: str = "", **kw):
        ui_ = ACTIVE_UI
        self._base = color or ui_["accent"]
        self._command = command
        kw.setdefault("bg", _parent_bg(master, ui_["panel"]))
        kw.setdefault("fg", self._base)
        kw.setdefault("font", FONT_SMALL)
        kw.setdefault("cursor", "hand2")
        super().__init__(master, text=text, **kw)
        self.bind("<Enter>", lambda _e: self.configure(fg=shade(self._base, 0.25)))
        self.bind("<Leave>", lambda _e: self.configure(fg=self._base))
        self.bind("<Button-1>", self._click)
        self.bind("<ButtonRelease-1>", self._release)

    def _click(self, _e=None):
        self._pressed = True

    def _release(self, _e=None):
        if getattr(self, "_pressed", False) and self._command:
            self._command()



class CheckBox(ttk.Checkbutton):
    """**勾选框**：`ttk.Checkbutton` 的语义 + 自绘的圆角方块对勾。

    ★ 为什么自绘：Tk 9.0 的 clam 主题把「已选中」画成一个**叉**（实测原生 clam 也是），
      看起来像「没勾上」，用户在阵营页 / 建筑页会以为勾错了。
      这里把 ttk 的 indicator 从布局里拿掉，自己画一个 13px 圆角方块 + 对勾；
      点击 / 变量 / command 全都还是 ttk 自己处理，
      `isinstance(w, ttk.Checkbutton)` 依然成立（测试照旧能按类找控件）。
    """

    STYLE = "Card.TCheckbutton"
    SIZE = 16                     # 指示器边长（设计稿像素）

    def __init__(self, master=None, **kw):
        ui_ = ACTIVE_UI
        style = ttk.Style(master)
        try:
            existing = style.layout(self.STYLE)
        except tk.TclError:
            existing = ""
        if not existing:
            style.layout(self.STYLE, [
                ("Checkbutton.padding", {"sticky": "nswe", "children": [
                    ("Checkbutton.label", {"sticky": "nswe"})]})])
            style.configure(self.STYLE, padding=(dpi.px(23), dpi.px(2), 0, dpi.px(2)),
                            background=ui_["panel"], foreground=ui_["text_soft"],
                            focuscolor=ui_["panel"], borderwidth=0, relief="flat",
                            font=FONT_BODY)
            style.map(self.STYLE,
                      background=[("active", ui_["panel"])],
                      foreground=[("disabled", ui_["text_dim"])])
        kw.setdefault("style", self.STYLE)
        self._bg = _parent_bg(master, ui_["panel"])
        super().__init__(master, **kw)
        self._ind = tk.Canvas(self, width=dpi.px(self.SIZE), height=dpi.px(self.SIZE),
                              bg=self._bg,
                              highlightthickness=0, bd=0, takefocus=0,
                              cursor="hand2")
        self._ind.place(x=dpi.px(1), rely=0.5, anchor="w")
        self._ind.bind("<Button-1>", self._on_indicator_click)
        self._ind.bind("<Enter>", lambda _e: self._paint(True))
        self._ind.bind("<Leave>", lambda _e: self._paint(False))
        self.bind("<ButtonRelease-1>", lambda _e: self.after_idle(self._paint), add="+")
        self.bind("<KeyRelease-space>", lambda _e: self.after_idle(self._paint), add="+")
        self._hover = False
        self._paint()

    # -- 交互 ------------------------------------------------------
    def _on_indicator_click(self, _event=None):
        try:
            self.invoke()
        except tk.TclError:
            return
        self.after_idle(self._paint)

    def _selected(self) -> bool:
        try:
            return bool(self.instate(["selected"]))
        except tk.TclError:
            return False

    def _paint(self, hover: bool = None) -> None:
        if hover is not None:
            self._hover = hover
        ui_ = ACTIVE_UI
        try:
            ind = self._ind
            ind.delete("all")
            on = self._selected()
            disabled = bool(self.instate(["disabled"]))
            if on:
                fill = ui_["accent"]
                edge = ui_["accent"]
            else:
                fill = ui_["surface2"]
                edge = ui_["accent"] if self._hover else ui_["line"]
            if disabled:
                fill = ui_["panel"]
                edge = ui_["line_soft"]
            # ★ 必须是**缩放后**的尺寸：画布是 dpi.px(SIZE)，图也要用同一个数，
            #   否则 150% 下一次是 24px 画布套 16px 图，四周露出白底（像个大勾选框）。
            size = dpi.px(self.SIZE)
            ink = ui_["accent_fg"] if not disabled else ui_["text_dim"]
            photo = paint.check_photo(self, size, max(3.0, size * 0.26), fill, edge,
                                      ink=ink, checked=on)
            if photo is not None:
                self._photo_ind = photo
                ind.create_image(0, 0, image=photo, anchor="nw")
            else:
                rounded_rect(ind, 0.5, 0.5, size - 0.5, size - 0.5, 4,
                             fill=fill, outline=edge, width=1)
                if on:
                    ind.create_line(3.6, 7.2, 6.0, 9.6, 10.4, 4.4, fill=ink,
                                    width=1.8, capstyle="round", joinstyle="round")
            # 画布底色跟父容器走（重建 / 换主题后不明显，但重建时是新建的，够用）
            ind.configure(bg=self._bg)
            ind.lift()
        except tk.TclError:
            pass


# ======================================================================
# 页签：滑动下划线
# ======================================================================

class UnderlineTabs(tk.Frame):
    """**下划线页签**：一排真 `tk.Button` + 一条会滑动的下划线。

    ★ 为什么不用 Canvas 自绘页签：地图 / 战役的测试会 `tab_buttons[key].invoke()`
      并读 `cget("fg")` 判断高亮。真按钮天然满足这两条，下划线只是附加装饰。
    """

    def __init__(self, master=None, bg: str = "", on_select: Optional[Callable[[str], None]] = None,
                 **kw):
        ui_ = ACTIVE_UI
        self._bg = bg or ui_["bar"]
        super().__init__(master, bg=self._bg, **kw)
        self.on_select = on_select
        self.buttons: Dict[str, tk.Button] = {}
        self._active: Optional[str] = None
        self._row = tk.Frame(self, bg=self._bg)
        self._row.pack(side="top", fill="x")
        self.strip = tk.Canvas(self, height=dpi.px(3), bg=self._bg, highlightthickness=0,
                               bd=0, takefocus=0)
        self.strip.pack(side="top", fill="x")
        self._ind = (0.0, 0.0)
        self._tween = None
        self.bind("<Configure>", lambda _e: self._place_indicator(False))
        self._row.bind("<Configure>", lambda _e: self._place_indicator(False))
        self.after(40, lambda: self._place_indicator(False))

    def add(self, key: str, label: str, command: Optional[Callable] = None) -> tk.Button:
        ui_ = ACTIVE_UI
        btn = tk.Button(self._row, text=label, bd=0, relief="flat", bg=self._bg,
                        fg=ui_["text_dim"], activebackground=self._bg,
                        activeforeground=ui_["accent"], padx=dpi.px(14), pady=dpi.px(6),
                        font=FONT_BODY, takefocus=0, cursor="hand2",
                        command=command or (lambda k=key: self.select(k)))
        btn.pack(side="left")
        btn.bind("<Enter>", lambda _e, b=btn, k=key: self._hover(b, k, True))
        btn.bind("<Leave>", lambda _e, b=btn, k=key: self._hover(b, k, False))
        self.buttons[key] = btn
        if self._active is None:
            self._active = key
            btn.configure(fg=ACTIVE_UI["accent"], font=FONT_SECTION)
        # 按钮宽度要等布局跑完才有值；`_geom` 会退回 reqwidth，所以这里只补一次校正。
        self.after(40, lambda: self._place_indicator(False))
        return btn

    # -- 状态 ------------------------------------------------------
    def _hover(self, btn: tk.Button, key: str, entering: bool) -> None:
        ui_ = ACTIVE_UI
        if key == self._active:
            return
        btn.configure(fg=ui_["text"] if entering else ui_["text_dim"])

    def select(self, key: str, animate_indicator: bool = True) -> None:
        ui_ = ACTIVE_UI
        if key not in self.buttons:
            return
        changed = key != self._active
        self._active = key
        for k, btn in self.buttons.items():
            active = k == key
            btn.configure(fg=ui_["accent"] if active else ui_["text_dim"],
                          font=FONT_SECTION if active else FONT_BODY)
        self._place_indicator(animate_indicator)
        if changed and self.on_select:
            self.on_select(key)

    def active(self) -> Optional[str]:
        return self._active

    # -- 指示条 ----------------------------------------------------
    def _geom(self) -> tuple:
        """当前激活页签在 strip 坐标系里的 (x, 宽)。

        ★ 窗口还没映射时 `winfo_width()` 是 1，这里退回 `winfo_reqwidth()`
          并用前几个按钮的请求宽度累加出 x —— 否则第一次画的指示条会缩成 8px
          （实测就是这样：页签下划线只有一小截）。
        """
        keys = list(self.buttons)
        if self._active not in self.buttons:
            return (0.0, 0.0)
        idx = keys.index(self._active)
        btn = self.buttons[self._active]
        try:
            w = float(btn.winfo_width())
            x = float(btn.winfo_x())
        except tk.TclError:
            w, x = 1.0, 0.0
        if w <= 1.0:
            w = float(btn.winfo_reqwidth())
            x = 0.0
            for k in keys[:idx]:
                try:
                    x += float(self.buttons[k].winfo_reqwidth())
                except tk.TclError:
                    pass
        # 两端各留 6px，让下划线比文字略窄一点，更像网页里的 tab。
        return (x + dpi.pxf(6), max(dpi.pxf(8), w - dpi.pxf(12)))

    def _place_indicator(self, animate_indicator: bool) -> None:
        target = self._geom()
        if target[1] <= 8.0:
            return
        if not animate_indicator:
            self._draw_indicator(*target)
            self._ind = target
            return

        start = self._ind
        if self._tween is not None:
            self._tween.cancel()

        def frame(t: float) -> None:
            x = start[0] + (target[0] - start[0]) * t
            w = start[1] + (target[1] - start[1]) * t
            self._draw_indicator(x, w)

        def done() -> None:
            self._ind = target

        self._tween = animate(self, DUR_BASE, frame, done)

    def _draw_indicator(self, x: float, w: float) -> None:
        ui_ = ACTIVE_UI
        try:
            self.strip.delete("ind")
            if w <= 1:
                return
            self.strip.create_line(x, dpi.pxf(1.5), x + w, dpi.pxf(1.5),
                                   width=dpi.px(2), capstyle="round",
                                   fill=ui_["accent"], tags="ind")
        except tk.TclError:
            pass


# ======================================================================
# 滚动：卡片列
# ======================================================================

class ScrollColumn(tk.Frame):
    """**可滚动的卡片列**：内部 `inner` 上堆卡片，超出就纵向滚。

    ★ 为什么主区也要能滚：一页里放三张表 + 操作栏，在 820 高的窗口里
      请求高度一旦超过可用高度，Tk 的 pack 会把**最后一张卡直接裁掉**
      （历史上就是「左下那排按钮整排消失」）。让内容自己滚，永不裁。
    """

    def __init__(self, master=None, bg: str = "", **kw):
        ui_ = ACTIVE_UI
        bg = bg or ui_["bg"]
        super().__init__(master, bg=bg, **kw)
        self.canvas = tk.Canvas(self, bg=bg, highlightthickness=0, bd=0, takefocus=0)
        self.bar = ThinScrollbar(self, command=self.canvas.yview, trough=bg, width=8)
        self.bar.pack(side="right", fill="y", padx=(4, 0))
        self.canvas.pack(side="left", fill="both", expand=True)
        self.inner = tk.Frame(self.canvas, bg=bg)
        self._win = self.canvas.create_window((0, 0), window=self.inner, anchor="nw")
        self.canvas.configure(yscrollcommand=self.bar.set)
        self.inner.bind("<Configure>", self._on_inner)
        self.canvas.bind("<Configure>", self._on_canvas)

    def _on_inner(self, _event=None) -> None:
        try:
            self.canvas.configure(scrollregion=self.canvas.bbox("all"))
        except tk.TclError:
            pass

    def _on_canvas(self, event) -> None:
        try:
            self.canvas.itemconfigure(self._win, width=max(1, int(event.width)))
        except tk.TclError:
            return
        self._on_inner()

    def contains(self, widget) -> bool:
        node = widget
        while node is not None:
            if node is self.inner or node is self.canvas:
                return True
            node = getattr(node, "master", None)
        return False

    def scroll(self, units: int) -> None:
        try:
            self.canvas.yview_scroll(units, "units")
        except tk.TclError:
            pass



class ThinScrollbar(tk.Canvas):
    """**细滚动条**（6px 圆头滑块，纵向 / 横向都支持）：接口与 `ttk.Scrollbar` 一致。

    ★ 为什么自己画：ttk 的滚动条在暗色主题里是一整条浅色槽 + 三角箭头，
      又宽又抢眼，是「原生感」最大的破绽。这里只留一根细滑块。
    """

    def __init__(self, master=None, command: Optional[Callable] = None,
                 width: int = 8, trough: str = "", thumb: str = "",
                 orient: str = "vertical", **kw):
        ui_ = ACTIVE_UI
        self._bg = trough or _parent_bg(master, ui_["bg"])
        self._orient = "horizontal" if str(orient).startswith("h") else "vertical"
        # ★ Canvas 的默认高度是 7c（264px）：不显式给 1，它会把自己的「请求高度」
        #   塞给父容器 —— 表格卡片会凭空长高 33px（踩过两次了，Card 里也是同一个坑）。
        if self._orient == "horizontal":
            kw.setdefault("height", dpi.px(width))
            kw.setdefault("width", 1)
        else:
            kw.setdefault("height", 1)
            kw.setdefault("width", dpi.px(width))
        super().__init__(master, bg=self._bg, highlightthickness=0,
                         bd=0, takefocus=0, **kw)
        self._command = command
        self._thumb_color = thumb or blend(ui_.get("line", "#24303d"), ui_["text_dim"], 0.25)
        self._first, self._last = 0.0, 1.0
        self._hover = False
        self._drag: Optional[float] = None
        self._thumb = self.create_polygon(0, 0, 0, 0, 0, 0, fill=self._thumb_color,
                                          outline="")
        self.bind("<Configure>", lambda _e: self._redraw())
        self.bind("<Enter>", lambda _e: self._set_hover(True))
        self.bind("<Leave>", lambda _e: self._set_hover(False))
        self.bind("<Button-1>", self._on_press)
        self.bind("<B1-Motion>", self._on_drag)
        self.bind("<ButtonRelease-1>", self._on_release)
        self._redraw()

    # -- ttk 兼容接口 ----------------------------------------------
    def configure(self, cnf=None, **kw):
        """认 `command=` / `orient=`（ttk.Scrollbar 的老调用点会这么写），其余交给 Canvas。"""
        if "command" in kw:
            self._command = kw.pop("command")
        if "orient" in kw:
            self._orient = "horizontal" if str(kw.pop("orient")).startswith("h") else "vertical"
        if cnf is None and not kw:
            return super().configure(cnf)
        return super().configure(cnf, **kw)

    config = configure

    def set(self, first, last) -> None:
        try:
            self._first = max(0.0, float(first))
            self._last = min(1.0, float(last))
        except (TypeError, ValueError):
            return
        if self._last <= self._first:
            self._last = min(1.0, self._first + 0.001)
        self._redraw()

    def get(self):
        return (self._first, self._last)

    # -- 轴 --------------------------------------------------------
    @property
    def _horizontal(self) -> bool:
        return self._orient == "horizontal"

    def _length(self) -> int:
        try:
            return max(1, self.winfo_width() if self._horizontal else self.winfo_height())
        except tk.TclError:
            return 1

    def _thickness(self) -> int:
        try:
            return max(1, self.winfo_height() if self._horizontal else self.winfo_width())
        except tk.TclError:
            return 1

    # -- 画 --------------------------------------------------------
    def _set_hover(self, flag: bool) -> None:
        self._hover = flag
        self._redraw()

    def _thumb_box(self):
        length = self._length()
        span = self._last - self._first
        a = self._first * length
        b = max(a + dpi.px(18), self._last * length)
        b = min(b, length)
        return (a, b, span)

    def _redraw(self) -> None:
        try:
            if self._length() <= 2 or self._thickness() <= 2:
                return
            a, b, span = self._thumb_box()
            color = (shade(self._thumb_color, 0.30)
                     if (self._hover or self._drag is not None) else self._thumb_color)
            self.delete("thumb")
            if span >= 0.994:
                self._thumb = self.create_polygon(0, 0, 0, 0, 0, 0, fill=self._bg,
                                                  outline="", tags="thumb")
                return
            t = self._thickness()
            if self._horizontal:
                y1, y2 = 1.5, t - 1.5
                x1, x2 = a + 1, b - 1
            else:
                x1, x2 = 1.5, t - 1.5
                y1, y2 = a + 1, b - 1
            r = 3.0
            pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r,
                   x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
                   x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
            self._thumb = self.create_polygon(pts, smooth=True, splinesteps=8,
                                              fill=color, outline="", tags="thumb")
        except tk.TclError:
            pass

    # -- 拖拽 ------------------------------------------------------
    def _pos(self, event) -> float:
        return float(event.x) if self._horizontal else float(event.y)

    def _on_press(self, event) -> None:
        a, b, _span = self._thumb_box()
        pos = self._pos(event)
        if a <= pos <= b:
            self._drag = pos - a
        else:  # 点槽 = 跳一页
            self._drag = (b - a) / 2.0
            self._scroll_to(pos)
        self._redraw()

    def _on_drag(self, event) -> None:
        if self._drag is None:
            return
        self._scroll_to(self._pos(event))

    def _on_release(self, _event) -> None:
        self._drag = None
        self._redraw()

    def _scroll_to(self, pointer: float) -> None:
        if not self._command:
            return
        length = self._length()
        thumb = max(18.0, (self._last - self._first) * length)
        top = pointer - (self._drag or 0.0)
        frac = top / max(1.0, length - thumb)
        frac = max(0.0, min(1.0, frac))
        try:
            self._command("moveto", frac)
        except tk.TclError:
            pass


# ======================================================================
# Toast：右下角浮起一条圆角提示
# ======================================================================

class Toast:
    """轻量提示条：从下方滑入、停留、滑出销毁。

    ★ 不抢焦点、不进布局（place 浮在 root 右下角），所以不会影响任何测试里
      对窗口尺寸 / pack 顺序的断言。
    """

    _current: Optional["Toast"] = None

    def __init__(self, root: tk.Misc, text: str, kind: str = "ok", ms: int = 1800):
        ui_ = ACTIVE_UI
        self.root = root
        self.ms = int(ms)
        colors = {"ok": ui_["ok"], "warn": ui_["warn"], "bad": ui_["bad"],
                  "info": ui_["accent"]}
        dot = colors.get(kind, ui_["ok"])
        self.canvas = tk.Canvas(root, bg=ui_["bg"], highlightthickness=0, bd=0,
                                takefocus=0)
        # 先量文字，再定卡片宽高
        probe = tk.Label(root, text=text, font=FONT_SMALL)
        tw = probe.winfo_reqwidth()
        probe.destroy()
        w = max(140, tw + 58)
        h = 38
        self.canvas.configure(width=w, height=h)
        rounded_rect(self.canvas, 0, 0, w - 1, h - 1, RADIUS_S,
                     fill=ui_["panel"], outline=ui_["line"], width=1)
        self.canvas.create_oval(16, h / 2 - 3.5, 23, h / 2 + 3.5,
                                fill=dot, outline="")
        self.canvas.create_text(34, h / 2, text=text, anchor="w",
                                fill=ui_["text_soft"], font=FONT_SMALL)
        self._w, self._h = w, h

    def show(self) -> "Toast":
        if Toast._current is not None:
            try:
                Toast._current.close()
            except Exception:  # noqa: BLE001 - 关掉旧的失败也不该影响新的
                pass
        Toast._current = self
        self._place(16)
        animate(self.canvas, DUR_BASE, lambda t: self._place(16 * (1.0 - t)))
        self.canvas.after(self.ms, self._hide)
        return self

    def _place(self, dy: float) -> None:
        try:
            # ★ 抬到状态栏上方：贴底会被 statusbar 压住一半。
            self.canvas.place(relx=1.0, rely=1.0, anchor="se",
                              x=-22, y=-(STATUSBAR_H + 18) + dy,
                              width=self._w, height=self._h)
            self.canvas.lift()
        except tk.TclError:
            pass

    def _hide(self) -> None:
        animate(self.canvas, DUR_FAST, lambda t: self._place(14 * t),
                self.close)

    def close(self) -> None:
        if Toast._current is self:
            Toast._current = None
        try:
            self.canvas.destroy()
        except tk.TclError:
            pass


def toast(root: tk.Misc, text: str, kind: str = "ok", ms: int = 1800) -> Toast:
    return Toast(root, text, kind=kind, ms=ms).show()


# ======================================================================
# 侧栏分区卡片
# ======================================================================

def make_card(parent, title: str, hint: str = "", wrap: int = 320,
              color: str = "", actions: Optional[Callable[[tk.Misc], None]] = None,
              animate_in: bool = True) -> tk.Frame:
    """在侧边栏里造一张「分区卡片」，返回**内容 frame**。

    ★ 与旧 `_section()` 的返回值完全一样（调用方继续往返回的 frame 里 pack）。
    ★ 视觉：`panel` 底 + 1px `line` 边框 + 14px 圆角；标题前一颗 6px 彩色圆点
      （按标题稳定取色，重建侧栏不闪），标题下可选一行淡色提示，
      再一条 `line_soft` 分隔线，然后才是内容。
    """
    ui_ = ACTIVE_UI
    accent = color or card_color(title)
    card = Card(parent, radius=RADIUS_L, padding=0, fill=ui_["panel"],
                outline=ui_["line"], bg=ui_["bg"])
    card.section_title = title
    card.pack(fill="x", padx=dpi.px(6), pady=(0, dpi.px(10)))

    head = tk.Frame(card.body, bg=ui_["panel"])
    head.pack(fill="x", padx=dpi.px(CARD_PAD), pady=(dpi.px(13), 0))
    dot = tk.Canvas(head, width=10, height=10, bg=ui_["panel"],
                    highlightthickness=0, bd=0, takefocus=0)
    dot.create_oval(1, 2, 9, 10, fill=accent, outline="")
    dot.pack(side="left", padx=(0, 8), pady=(1, 0))
    tk.Label(head, text=title, bg=ui_["panel"], fg=ui_["text"], anchor="w",
             font=FONT_SECTION).pack(side="left")
    if actions is not None:
        actions(head)

    if hint:
        tk.Label(card.body, text=hint, bg=ui_["panel"], fg=ui_["text_dim"],
                 anchor="w", justify="left", wraplength=dpi.px(wrap),
                 font=FONT_SMALL).pack(fill="x", padx=(dpi.px(CARD_PAD + 18), dpi.px(CARD_PAD)),
                                       pady=(dpi.px(3), 0))

    tk.Frame(card.body, bg=ui_.get("line_soft", ui_["line"]), height=1).pack(
        fill="x", padx=dpi.px(CARD_PAD), pady=(dpi.px(10), 0))

    body = tk.Frame(card.body, bg=ui_["panel"])
    body.pack(fill="x", padx=dpi.px(CARD_PAD - 4), pady=(dpi.px(9), dpi.px(13)))
    body.section_title = title
    if animate_in:
        card.appear()
    return body


def list_card(parent, title: str, kicker: str = "",
              actions: Optional[Callable[[tk.Misc], None]] = None,
              hint: str = "", radius: float = RADIUS_L) -> RoundedPanel:
    """主区里的**表格卡片**：返回撑满父容器的 `RoundedPanel`。

    ★ 用法：`panel = list_card(host, "兵种", "共 8 条")`，然后把卡片头做完，
      再往 `panel.body` 里 pack Treeview。body 已经留好内边距。
    ★ `kicker` 是标题右边的小字（计数 / 说明），`hint` 是标题下面整行淡色说明。
    """
    ui_ = ACTIVE_UI
    panel = RoundedPanel(parent, radius=radius, fill=ui_["panel"],
                         outline=ui_["line"], bg=ui_["bg"])
    head = tk.Frame(panel.body, bg=ui_["panel"])
    head.pack(fill="x", padx=dpi.px(CARD_PAD), pady=(dpi.px(10), 0))
    if title:
        tk.Label(head, text=title, bg=ui_["panel"], fg=ui_["text"],
                 font=FONT_SECTION).pack(side="left")
    if kicker:
        tk.Label(head, text=kicker, bg=ui_["panel"], fg=ui_["text_dim"],
                 font=FONT_SMALL).pack(side="left", padx=(10, 0), pady=(1, 0))
    if actions is not None:
        actions(head)
    if hint:
        tk.Label(panel.body, text=hint, bg=ui_["panel"], fg=ui_["text_dim"],
                 anchor="w", justify="left", font=FONT_SMALL).pack(
                     fill="x", padx=dpi.px(CARD_PAD), pady=(dpi.px(3), 0))
    tk.Frame(panel.body, bg=ui_.get("line_soft", ui_["line"]), height=1).pack(
        fill="x", padx=dpi.px(CARD_PAD), pady=(dpi.px(7), 0))
    panel.appear()
    return panel
