"""editor_ui/shell.py —— 四个编辑器共用的「窗口外壳」。

    ┌──────────────────────────────────────────────────────────┐
    │ ◼ 单位编辑器   [单位] [单位特性] [将领特性] [建筑]   路径 ⬤保存 │  ← topbar
    ├──────────────────────────────────────────────────────────┤
    │                                                          │
    │   content（各编辑器自己排：卡片 / 画布 / 表格）              │  ← body
    │                                                          │
    ├──────────────────────────────────────────────────────────┤
    │ 状态文字                                        快捷键提示 │  ← statusbar
    └──────────────────────────────────────────────────────────┘

★ 只做「壳」：顶栏、页签、状态栏、内容容器、Toast 挂载点。
  具体一页里放什么，由各编辑器自己决定 —— 这样四个窗口才是「一家人」，
  而不是四套各自为政的布局。
"""

from __future__ import annotations

import tkinter as tk
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from . import dpi
from .motion import animate
from .tokens import (
    DUR_BASE,
    FONT_BRAND,
    FONT_SMALL,
    GAP,
    STATUSBAR_H,
    TOPBAR_H,
)
from . import widgets as _widgets
from .widgets import (
    ACTIVE_UI,
    LinkButton,
    PillButton,
    ThinScrollbar,
    UnderlineTabs,
    is_dark,
    rounded_rect,
    shade,
    toast,
)


class EditorShell:
    """建好顶栏 / 内容区 / 状态栏，并把「保存 / 重新载入 / 另存为」放进右侧动作区。"""

    def __init__(self, root: tk.Tk, *, title: str,
                 tabs: Sequence[Tuple[str, str]] = (),
                 on_tab: Optional[Callable[[str], None]] = None,
                 brand: str = "",
                 geometry: str = "", minsize: Optional[Tuple[int, int]] = None,
                 status_hint: str = "") -> None:
        self.root = root
        # ★ 必须动态取：`set_ui()` 是**重新绑定**模块变量，
        #   `from .widgets import ACTIVE_UI` 拿到的是导入那一刻的旧字典
        #   （换浅色主题时整个顶栏还是黑的，就是踩的这个）。
        self.ui = _widgets.ACTIVE_UI
        self.root.configure(bg=self.ui["bg"])
        # ★ geometry / minsize 写成「设计稿尺寸」，这里按 DPI 放大
        if geometry:
            self.root.geometry(dpi.scale_geometry(self.root, geometry))
        if minsize:
            self.root.minsize(dpi.px(minsize[0]), dpi.px(minsize[1]))
        self.root.title(title)

        self.tab_buttons: Dict[str, tk.Button] = {}
        self.actions: Dict[str, PillButton] = {}
        self._build_topbar(title, brand, tabs, on_tab)
        self.body = tk.Frame(root, bg=self.ui["bg"])
        self.body.pack(side="top", fill="both", expand=True)
        self.content = tk.Frame(self.body, bg=self.ui["bg"])
        self.content.pack(side="top", fill="both", expand=True,
                          padx=dpi.px(GAP), pady=(dpi.px(GAP - 2), dpi.px(GAP - 6)))
        self._build_statusbar(status_hint)
        self._curtain: Optional[tk.Frame] = None

    # ------------------------------------------------------------------
    # 顶栏
    # ------------------------------------------------------------------
    def _build_topbar(self, title: str, brand: str,
                      tabs: Sequence[Tuple[str, str]],
                      on_tab: Optional[Callable[[str], None]]) -> None:
        ui = self.ui
        self.topbar = tk.Frame(self.root, bg=ui["bar"], height=dpi.px(TOPBAR_H))
        self.topbar.pack(side="top", fill="x")
        self.topbar.pack_propagate(False)
        # 1px 发丝分隔：比整条深色边更轻，顶栏才不会「贴」在内容上。
        tk.Frame(self.root, bg=ui["line"], height=1).pack(side="top", fill="x")

        brand_box = tk.Frame(self.topbar, bg=ui["bar"])

        # ★ 右侧动作区先 pack：pack 是「先到先得」，右侧按钮簇一旦比剩余空间宽，
        #   后摆的「保存」就会被裁掉（科技编辑器 1060 宽的窗口实测踩到）。
        self.right = tk.Frame(self.topbar, bg=ui["bar"])
        self.right.pack(side="right", padx=(0, dpi.px(16)), pady=(dpi.px(15), 0))

        brand_box.pack(side="left", padx=(dpi.px(18), dpi.px(16)))
        logo = tk.Canvas(brand_box, width=24, height=24, bg=ui["bar"],
                         highlightthickness=0, bd=0, takefocus=0)
        rounded_rect(logo, 0, 0, 23, 23, 7, fill=ui["accent"], outline="")
        rounded_rect(logo, 8, 8, 15, 15, 2.5, fill=ui["bar"], outline="")
        logo.pack(side="left", pady=(dpi.px(18), 0))
        self.brand_label = tk.Label(brand_box, text=brand or title, bg=ui["bar"],
                                    fg=ui["text"], font=FONT_BRAND, anchor="w")
        self.brand_label.pack(side="left", padx=(dpi.px(9), 0), pady=(dpi.px(18), 0))

        self.tabs = UnderlineTabs(self.topbar, bg=ui["bar"], on_select=on_tab)
        self.tabs.pack(side="left", fill="y", padx=(dpi.px(6), 0), pady=(dpi.px(6), 0))
        for key, label in tabs:
            self.tab_buttons[key] = self.tabs.add(key, label)

    # ------------------------------------------------------------------
    # 状态栏
    # ------------------------------------------------------------------
    def _build_statusbar(self, hint: str) -> None:
        ui = self.ui
        tk.Frame(self.root, bg=ui["line"], height=1).pack(side="bottom", fill="x")
        bar = tk.Frame(self.root, bg=ui["bar"], height=dpi.px(STATUSBAR_H))
        bar.pack(side="bottom", fill="x")
        bar.pack_propagate(False)
        self.status_var = tk.StringVar(value="就绪")
        self.status_label = tk.Label(bar, textvariable=self.status_var, anchor="w",
                                     bg=ui["bar"], fg=ui["text_dim"],
                                     font=FONT_SMALL, padx=dpi.px(16))
        self.status_label.pack(side="left", fill="both")
        self.status_hint_var = tk.StringVar(value=hint)
        tk.Label(bar, textvariable=self.status_hint_var, anchor="e", bg=ui["bar"],
                 fg=ui["text_dim"], font=FONT_SMALL, padx=dpi.px(16)).pack(side="right")

    # ------------------------------------------------------------------
    # 右侧动作区
    # ------------------------------------------------------------------
    def add_file_label(self) -> tk.Label:
        """顶栏右侧的文件路径（暗色小字）。"""
        ui = self.ui
        label = tk.Label(self.right, text="", bg=ui["bar"], fg=ui["text_dim"],
                         font=FONT_SMALL, anchor="e")
        label.pack(side="left", padx=(0, dpi.px(10)), pady=(0, dpi.px(9)))
        return label

    def add_dirty_chip(self) -> tk.Label:
        """「已保存 / 未保存」小徽标（带一颗状态圆点）。"""
        ui = self.ui
        chip = tk.Label(self.right, text="● 已保存", bg=ui["bar"], fg=ui["ok"],
                        font=FONT_SMALL, padx=8, pady=2)
        chip.pack(side="left", padx=(0, 10), pady=(0, 9))
        return chip

    def add_button(self, key: str, text: str, command: Callable[[], None],
                   primary: bool = False) -> PillButton:
        ui = self.ui
        if primary:
            bg, fg = ui["accent_btn"], ui["accent_fg"]
        else:
            bg, fg = ui["surface2"], ui["text"]
        btn = PillButton(self.right, text=text, command=command, bg=bg, fg=fg,
                         font=FONT_SMALL, padx=14, pady=6)
        btn.pack(side="left", padx=(0, dpi.px(8)), pady=(0, dpi.px(8)))
        self.actions[key] = btn
        return btn

    # ------------------------------------------------------------------
    # 状态 / 交互
    # ------------------------------------------------------------------
    def set_tab(self, key: str, animate_indicator: bool = True) -> None:
        self.tabs.select(key, animate_indicator=animate_indicator)

    def status(self, message: str) -> None:
        try:
            self.status_var.set(message)
        except tk.TclError:
            pass

    def toast(self, message: str, kind: str = "ok", ms: int = 1600) -> None:
        # ★ 测试里不弹：Toast 用 after() 排队，测试跑完窗口就销毁了，
        #   留着定时器只会制造噪音（错误也被吞掉，没意义）。
        from .motion import ENABLED as _motion_on
        if not _motion_on:
            return
        toast(self.root, message, kind=kind, ms=ms)

    def reveal(self) -> None:
        """换页时的「幕布掀起」：内容区先被底色盖住，再自下而上让出来。

        ★ Tk 没有透明度，所以不能用淡入；用一块纯色幕布快速收边，
          观感接近网页里的页面切换，而且开销只有一次 place 调整。
        """
        ui = self.ui
        try:
            h = max(1, self.content.winfo_height())
        except tk.TclError:
            return
        if self._curtain is not None:
            try:
                self._curtain.destroy()
            except tk.TclError:
                pass
        curtain = tk.Frame(self.content, bg=ui["bg"])
        curtain.place(x=0, y=0, relwidth=1, height=h)
        self._curtain = curtain

        def frame(t: float) -> None:
            try:
                curtain.place_configure(height=max(1, int(h * (1.0 - t))))
            except tk.TclError:
                pass

        def done() -> None:
            try:
                curtain.destroy()
            except tk.TclError:
                pass
            if self._curtain is curtain:
                self._curtain = None

        animate(curtain, DUR_BASE, frame, done)

    def set_status_tone(self, tone: str = "normal") -> None:
        """状态栏左边的文字按结果上色（成功绿 / 失败红 / 普通暗）。"""
        ui = self.ui
        color = {"ok": ui["ok"], "bad": ui["bad"], "warn": ui["warn"]}.get(
            tone, ui["text_dim"])
        try:
            self.status_label.configure(fg=color)
        except tk.TclError:
            pass


def brand_square(parent, color: str = "", bg: str = "", size: int = 22) -> tk.Canvas:
    """一个小尺寸圆角方块（给卡片 / 提示条当图标用）。"""
    ui = ACTIVE_UI
    canvas = tk.Canvas(parent, width=size, height=size, bg=bg or ui["panel"],
                       highlightthickness=0, bd=0, takefocus=0)
    rounded_rect(canvas, 0, 0, size - 1, size - 1, size * 0.3,
                 fill=color or ui["accent"], outline="")
    return canvas
