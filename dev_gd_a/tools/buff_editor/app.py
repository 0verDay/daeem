"""app.py —— buff 编辑器界面（tkinter，零第三方依赖）。

布局（与 unit_editor / map_editor 同一套浅色主题）：

    ┌──────────────────────────────────────────────────────────────┐
    │ DAEEM buff 编辑器        config.json   ● 未保存  [重载] [保存] │
    ├──────────────┬───────────────────────────────────────────────┤
    │ Buff 列表     │ 士气「士」  90 / 100                           │
    │  ▸ 士气 士    │ 整支部队共享的士气……                          │
    │              ├───────────────────────────────────────────────┤
    │ （以后新增）  │ 基础 / 阈值 / 生命 / 伤害 / 区划 / 战果 各组   │
    │              │ 每个数值一行：名称 [输入框] 单位  说明          │
    │              ├───────────────────────────────────────────────┤
    │              │ 悬停浮窗预览（游戏里「士」上鼠标停住时显示）    │
    │              │ 提示：跨字段不合理的组合（只提示，不阻止保存）  │
    ├──────────────┴───────────────────────────────────────────────┤
    │ 状态栏：上一次操作的结果 · 文件路径                            │
    └──────────────────────────────────────────────────────────────┘

交互（与 unit_editor 同一套习惯）：

    · 改完按 Enter（或点别处）生效；打错字**不会写坏数据**，状态栏说一句；
    · 输入框里 Esc = 放弃这一格的改动、恢复原值；
    · Ctrl+S 保存 · Ctrl+Z / Ctrl+Y 撤销 / 重做 · F5 从磁盘重读；
    · 百分数字段显示 / 输入都是**百分数**（50 = 50%），写回文件仍是 0.5。

★ 表单是「整块重建」而不是就地改值：字段只有 20 个，重建 ~10 ms，
  换来「界面永远等于数据」——不用维护控件与字段的对应关系。
"""

from __future__ import annotations

import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Any, Dict, List, Optional, Tuple

from . import model as model_mod
from .configfile import JsonError
from .model import (
    BUFFS,
    Buff,
    ConfigModel,
    Field,
    ModelError,
    display_value,
    field_groups,
    fmt_number,
    parse_value,
)

#: 界面配色（与 unit_editor / map_editor / campaign_editor **同一套**：
#: 三个工具看起来是一家的。这是深色方案里的浅色版 —— 页面底 / 卡片面 / 输入面三层灰）。
UI = {
    "bg": "#f3f4f6",
    "panel": "#ffffff",
    "panel_alt": "#eef0f3",
    "line": "#d9dce1",
    "text": "#1f2329",
    "text_dim": "#6b7280",
    "accent": "#2f7fe0",
    "accent_btn": "#2f7fe0",
    "accent_btn_hover": "#4a91e6",
    "accent_fg": "#ffffff",
    "hover": "#e6e9ee",
    "pressed": "#d9dde3",
    "ok": "#1f9d55",
    "warn": "#b7791f",
    "bad": "#d64545",
}

#: 字体：Windows 自带；别的系统给 Tk 的默认字体兜底（Tk 会自己换）。
FONT = ("Microsoft YaHei UI", 10)
FONT_SMALL = ("Microsoft YaHei UI", 9)
FONT_TITLE = ("Microsoft YaHei UI", 15, "bold")
FONT_GROUP = ("Microsoft YaHei UI", 10, "bold")

UNDO_LIMIT = 100


# ======================================================================
# 主题：浅色 + 圆角按钮 + 重建不闪白（与 unit_editor 同一套）
# ======================================================================

def _shade(color: str, amount: float) -> str:
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


def _rounded_rect(canvas, x1: float, y1: float, x2: float, y2: float, r: float, **kw):
    """在画布上画一个圆角矩形（平滑多边形近似），返回图元 id。"""
    r = max(1.0, min(r, (x2 - x1) / 2.0, (y2 - y1) / 2.0))
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r,
           x2, y2 - r, x2, y2, x2 - r, y2, x1 + r, y2,
           x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return canvas.create_polygon(pts, smooth=True, splinesteps=12, **kw)


class RButton(tk.Button):
    """圆角按钮（与 unit_editor 的 RButton 同一份做法：本体是 tk.Button，
    上面盖一层 Canvas 只负责画圆角，invoke / configure / pack 全是原生语义）。"""

    RADIUS = 8.0

    def __init__(self, master=None, **kw):
        kw.setdefault("relief", "flat")
        kw.setdefault("bd", 0)
        kw.setdefault("highlightthickness", 0)
        kw.setdefault("takefocus", 0)
        kw.setdefault("font", FONT_SMALL)
        kw.setdefault("activebackground", UI["panel_alt"])
        kw.setdefault("activeforeground", UI["text"])
        super().__init__(master, **kw)
        try:
            surround = str(self.master.cget("bg"))
        except (tk.TclError, AttributeError):
            surround = ""
        self._surround = surround or UI["panel"]
        self._hover = False
        self._active = False
        self._overlay = tk.Canvas(self, highlightthickness=0, bd=0, takefocus=0,
                                  bg=self._surround)
        self._overlay.place(x=0, y=0, relwidth=1, relheight=1)
        for seq, fn in (("<Enter>", self._on_enter), ("<Leave>", self._on_leave),
                        ("<ButtonPress-1>", self._on_press),
                        ("<ButtonRelease-1>", self._on_release)):
            self._overlay.bind(seq, fn)
        self.bind("<Configure>", lambda _e: self._redraw())
        self._redraw()

    def configure(self, cnf=None, **kw):
        if isinstance(cnf, str):
            return super().configure(cnf)
        result = super().configure(cnf, **kw)
        self._redraw()
        return result

    config = configure

    def _disabled(self) -> bool:
        try:
            return str(self.cget("state")) == "disabled"
        except tk.TclError:
            return False

    def _on_enter(self, _e=None):
        self._hover = True
        self._redraw()

    def _on_leave(self, _e=None):
        self._hover = False
        self._active = False
        self._redraw()

    def _on_press(self, _e=None):
        if not self._disabled():
            self._active = True
            self._redraw()

    def _on_release(self, _e=None):
        fire = self._active and not self._disabled()
        self._active = False
        self._hover = True
        self._redraw()
        if fire:
            try:
                self.invoke()
            except tk.TclError:
                pass

    def _fill(self) -> str:
        base = str(self.cget("bg"))
        if self._disabled():
            return base
        if self._active:
            return _shade(base, -0.12)
        if self._hover:
            return _shade(base, -0.06)
        return base

    def _redraw(self):
        overlay = getattr(self, "_overlay", None)
        if overlay is None:
            return
        try:
            overlay.delete("all")
            w = max(1, self.winfo_width())
            h = max(1, self.winfo_height())
            if w <= 1 or h <= 1:
                return
            fill = self._fill()
            _rounded_rect(overlay, 0, 0, w, h, min(self.RADIUS, h / 2.0),
                          fill=fill, outline=fill)
            text = str(self.cget("text"))
            if not text:
                return
            try:
                padx = max(0, int(self.cget("padx")))
            except (tk.TclError, ValueError):
                padx = 6
            overlay.create_text(w / 2, h / 2, text=text,
                                fill=UI["text_dim"] if self._disabled() else str(self.cget("fg")),
                                font=self.cget("font"))
        except tk.TclError:
            pass


def _apply_theme(root: tk.Tk) -> ttk.Style:
    """把 clam 主题会漏出的浅灰压回这套配色（与 unit_editor 的做法一致）。"""
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except tk.TclError:
        pass
    panel, alt, bg = UI["panel"], UI["panel_alt"], UI["bg"]
    line, text, dim, accent = UI["line"], UI["text"], UI["text_dim"], UI["accent"]
    hover, pressed = UI["hover"], UI["pressed"]
    sel_bg, sel_fg = "#cfe3ff", text

    style.configure(".", background=panel, foreground=text, fieldbackground=alt,
                    bordercolor=line, lightcolor=panel, darkcolor=panel, focuscolor=accent)
    style.configure("TFrame", background=panel)
    style.configure("Bar.TFrame", background=bg)
    style.configure("TLabel", background=panel, foreground=text, font=FONT)
    style.configure("Bar.TLabel", background=bg, foreground=text, font=FONT)
    style.configure("Dim.TLabel", background=panel, foreground=dim, font=FONT_SMALL)
    style.configure("BarDim.TLabel", background=bg, foreground=dim, font=FONT_SMALL)
    style.configure("Title.TLabel", background=panel, foreground=accent, font=FONT_TITLE)
    style.configure("Name.TLabel", background=panel, foreground=text, font=FONT_TITLE)
    style.configure("Group.TLabel", background=panel, foreground=accent, font=FONT_GROUP)
    style.configure("Hint.TLabel", background=panel, foreground=dim, font=FONT_SMALL)
    style.configure("AltHint.TLabel", background=alt, foreground=dim, font=FONT_SMALL)
    style.configure("Warn.TLabel", background=panel, foreground=UI["warn"], font=FONT_SMALL)
    style.configure("Bad.TLabel", background=panel, foreground=UI["bad"], font=FONT_SMALL)

    style.configure("TEntry", fieldbackground=alt, foreground=text, insertcolor=text,
                    bordercolor=line, lightcolor=alt, darkcolor=alt, padding=(6, 4),
                    font=FONT)
    style.map("TEntry",
              fieldbackground=[("readonly", alt), ("disabled", panel)],
              foreground=[("disabled", dim)],
              selectbackground=[("!disabled", sel_bg)],
              selectforeground=[("!disabled", sel_fg)],
              bordercolor=[("focus", accent)], lightcolor=[("focus", accent)],
              darkcolor=[("focus", accent)])

    style.configure("Treeview", background=alt, fieldbackground=alt, foreground=text,
                    bordercolor=line, lightcolor=panel, darkcolor=panel, rowheight=26,
                    borderwidth=0)
    style.map("Treeview",
              background=[("selected", sel_bg), ("disabled", alt)],
              foreground=[("selected", sel_fg), ("disabled", dim)])

    style.configure("TScrollbar", background=line, troughcolor=panel, bordercolor=panel,
                    arrowcolor=dim, relief="flat", borderwidth=0)
    style.map("TScrollbar",
              background=[("active", "#b9bfc9"), ("pressed", "#a6adba")],
              arrowcolor=[("active", text)])
    style.configure("TButton", background=alt, foreground=text, bordercolor=line,
                    focuscolor=alt, padding=(10, 5), borderwidth=0, font=FONT_SMALL)
    style.map("TButton",
              background=[("active", hover), ("pressed", pressed), ("disabled", panel)],
              foreground=[("disabled", dim)])
    style.configure("Accent.TButton", background=UI["accent_btn"],
                    foreground=UI["accent_fg"])
    style.map("Accent.TButton", background=[("active", UI["accent_btn_hover"])])
    return style


class _NoRepaint:
    """整块重建控件时先把窗口的绘制关掉，建完再一次性打开（消掉闪白）。

    ★★ 用 `WM_SETREDRAW`（Windows 上批量改控件的标准做法），不是
      `LockWindowUpdate` —— 后者只锁一个窗口，DWM 下压不住 Tk 销毁/新建控件的
      中间态。`= 1` 后一次 `RedrawWindow` 画到最终态；非 Windows / 异常都退化成空操作。
    """

    _WM_SETREDRAW = 0x000B
    _RDW_INVALIDATE = 0x0001
    _RDW_ERASE = 0x0004
    _RDW_ALLCHILDREN = 0x0080
    _RDW_UPDATENOW = 0x0100
    _GA_ROOT = 2

    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self._user32 = None
        self._hwnds: List[int] = []

    def __enter__(self):
        # 窗口不可见（初始化 / 无头测试 withdraw）时不做绘制锁定：
        # 在 withdrawn 窗口上发 WM_SETREDRAW 会把后续 focus_set() 弄失效。
        if sys.platform != "win32" or not self.root.winfo_viewable():
            return self
        try:
            import ctypes
            from ctypes import wintypes
            user32 = ctypes.windll.user32
            user32.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
            user32.GetAncestor.restype = wintypes.HWND
            user32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT,
                                            wintypes.WPARAM, wintypes.LPARAM]
            user32.SendMessageW.restype = wintypes.LPARAM
            user32.RedrawWindow.argtypes = [wintypes.HWND, ctypes.c_void_p,
                                            ctypes.c_void_p, wintypes.UINT]
            top = user32.GetAncestor(self.root.winfo_id(), self._GA_ROOT)
            hwnds: List[int] = []
            for hwnd in (top, self.root.winfo_id()):
                if hwnd and int(hwnd) not in hwnds:
                    hwnds.append(int(hwnd))
            for hwnd in hwnds:
                user32.SendMessageW(hwnd, self._WM_SETREDRAW, 0, 0)
            self._hwnds = hwnds
            self._user32 = user32
        except Exception:                                   # noqa: BLE001
            self._user32 = None
            self._hwnds = []
        return self

    def __exit__(self, *exc):
        user32, self._user32 = self._user32, None
        hwnds, self._hwnds = self._hwnds, []
        if user32 is None or not hwnds:
            return False
        for hwnd in hwnds:
            try:
                user32.SendMessageW(hwnd, self._WM_SETREDRAW, 1, 0)
            except Exception:                               # noqa: BLE001
                pass
        try:
            user32.RedrawWindow(hwnds[0], None, None,
                                self._RDW_INVALIDATE | self._RDW_ERASE
                                | self._RDW_ALLCHILDREN | self._RDW_UPDATENOW)
        except Exception:                                   # noqa: BLE001
            pass
        return False


# ======================================================================
# 主界面
# ======================================================================

class BuffEditorApp:
    """buff 编辑器窗口。测试可以只建 `tk.Tk()` + 这个类（不调 mainloop）。"""

    def __init__(self, root: tk.Tk, model: ConfigModel,
                 config_path: Optional[Path] = None,
                 project_dir: Optional[Path] = None) -> None:
        self.root = root
        self.model = model
        self.config_path = Path(config_path) if config_path else model.path
        self.project_dir = project_dir
        self.current_id: str = BUFFS[0].id if BUFFS else ""
        self.entries: Dict[str, ttk.Entry] = {}
        self._field_by_key: Dict[str, Field] = {}
        self._building = False
        self._undo_stack: List[str] = []
        self._redo_stack: List[str] = []
        self._sidebar_buttons: Dict[str, RButton] = {}

        self.root.title("DAEEM buff 编辑器")
        self.root.geometry("1060x780")
        self.root.minsize(900, 640)
        self.root.configure(bg=UI["bg"])
        self.status_var = tk.StringVar(value="就绪")
        self.dirty_var = tk.StringVar(value="")
        self.preview_var = tk.StringVar(value="")
        self.warning_var = tk.StringVar(value="")
        self.summary_var = tk.StringVar(value="")
        self.intro_var = tk.StringVar(value="")

        _apply_theme(self.root)
        self._build_topbar()
        self._build_body()
        self._build_statusbar()
        self._bind_shortcuts()
        self._select_buff(self.current_id)
        self._refresh_dirty()

    # ------------------------------------------------------------------
    # 构建：顶栏 / 主体 / 状态栏
    # ------------------------------------------------------------------
    def _build_topbar(self) -> None:
        bar = ttk.Frame(self.root, style="Bar.TFrame", padding=(14, 10))
        bar.pack(fill="x")
        ttk.Label(bar, text="DAEEM buff 编辑器", style="Bar.TLabel",
                  font=("Microsoft YaHei UI", 13, "bold")).pack(side="left")
        #: config 路径（太长就只显示尾部；鼠标停上去能看全）
        path_text = str(self.config_path) if self.config_path else "（未指定文件）"
        shown = path_text if len(path_text) <= 58 else "…" + path_text[-57:]
        self.path_label = ttk.Label(bar, text=shown, style="BarDim.TLabel")
        self.path_label.pack(side="left", padx=(14, 8))
        self.dirty_label = ttk.Label(bar, textvariable=self.dirty_var,
                                     style="BarDim.TLabel")
        self.dirty_label.pack(side="left")

        save = RButton(bar, text="保存  Ctrl+S", command=self.save,
                       bg=UI["accent_btn"], fg=UI["accent_fg"], padx=12, pady=5)
        save.pack(side="right", padx=(6, 0))
        reload_btn = RButton(bar, text="重载  F5", command=self.reload_from_disk,
                             bg=UI["panel_alt"], fg=UI["text"], padx=12, pady=5)
        reload_btn.pack(side="right", padx=(6, 0))
        redo = RButton(bar, text="重做  Ctrl+Y", command=self.redo,
                       bg=UI["panel_alt"], fg=UI["text"], padx=10, pady=5)
        redo.pack(side="right", padx=(6, 0))
        undo = RButton(bar, text="撤销  Ctrl+Z", command=self.undo,
                       bg=UI["panel_alt"], fg=UI["text"], padx=10, pady=5)
        undo.pack(side="right")
        self._save_button = save
        self._reload_button = reload_btn
        self._undo_button = undo
        self._redo_button = redo

    def _build_body(self) -> None:
        body = tk.Frame(self.root, bg=UI["bg"])
        body.pack(fill="both", expand=True, padx=12, pady=(0, 8))

        # ---- 左：buff 列表 ----
        left = tk.Frame(body, bg=UI["panel"], width=210, padx=12, pady=12)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)
        ttk.Label(left, text="Buff 列表", style="Group.TLabel").pack(anchor="w")
        ttk.Label(left, text="点一条 → 右边改它的全部数值", style="Hint.TLabel",
                  wraplength=180).pack(anchor="w", pady=(2, 10))
        self._sidebar_host = tk.Frame(left, bg=UI["panel"])
        self._sidebar_host.pack(fill="x")
        ttk.Label(left, text="本工具只编辑 config.json 里\n已经存在的键。加新 buff 仍要先在\n"
                             "游戏侧读它（见 README 第三节）。",
                  style="Hint.TLabel", wraplength=180, justify="left").pack(
            side="bottom", anchor="w")

        # ---- 右：内容 ----
        right = tk.Frame(body, bg=UI["panel"], padx=16, pady=12)
        right.pack(side="left", fill="both", expand=True, padx=(8, 0))

        head = tk.Frame(right, bg=UI["panel"])
        head.pack(fill="x")
        self._icon_canvas = tk.Canvas(head, width=48, height=48, bg=UI["panel"],
                                      highlightthickness=0)
        self._icon_canvas.pack(side="left", anchor="n")
        name_box = tk.Frame(head, bg=UI["panel"])
        name_box.pack(side="left", fill="x", expand=True, padx=(10, 0))
        ttk.Label(name_box, textvariable=self.summary_var, style="Name.TLabel").pack(anchor="w")
        ttk.Label(name_box, textvariable=self.intro_var, style="Hint.TLabel",
                  wraplength=720, justify="left").pack(anchor="w", pady=(4, 0))

        # ---- 表单（可滚动） ----
        form_wrap = tk.Frame(right, bg=UI["panel"])
        form_wrap.pack(fill="both", expand=True, pady=(8, 6))
        self._canvas = tk.Canvas(form_wrap, bg=UI["panel"], highlightthickness=0,
                                 bd=0)
        vsb = ttk.Scrollbar(form_wrap, orient="vertical", command=self._canvas.yview)
        self._canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side="right", fill="y")
        self._canvas.pack(side="left", fill="both", expand=True)
        self._inner = ttk.Frame(self._canvas, style="TFrame")
        self._inner_id = self._canvas.create_window((0, 0), window=self._inner, anchor="nw")
        self._inner.bind("<Configure>", self._on_inner_configure)
        self._canvas.bind("<Configure>", self._on_canvas_configure)
        self._canvas.bind_all("<MouseWheel>", self._on_wheel)

        # ---- 悬停浮窗预览（固定在下半，不跟着表单滚） ----
        preview_card = tk.Frame(right, bg=UI["panel_alt"], padx=12, pady=8)
        preview_card.pack(fill="x", pady=(2, 4))
        ttk.Label(preview_card, text="悬停浮窗预览（游戏里鼠标停在 buff 方块上显示这段）",
                  style="AltHint.TLabel").pack(anchor="w")
        self._preview_label = tk.Label(preview_card, textvariable=self.preview_var,
                                       bg=UI["panel_alt"], fg=UI["text"],
                                       font=FONT_SMALL, justify="left", anchor="w",
                                       wraplength=760)
        self._preview_label.pack(anchor="w", pady=(2, 0))

        # ---- 跨字段提示 ----
        self._warning_label = ttk.Label(right, textvariable=self.warning_var,
                                        style="Warn.TLabel", justify="left",
                                        wraplength=900)
        self._warning_label.pack(fill="x", anchor="w")

    def _build_statusbar(self) -> None:
        bar = ttk.Frame(self.root, style="Bar.TFrame", padding=(14, 6))
        bar.pack(fill="x")
        ttk.Label(bar, textvariable=self.status_var, style="Bar.TLabel").pack(side="left")
        ttk.Label(bar, textvariable=self.dirty_var, style="BarDim.TLabel").pack(side="right")

    def _bind_shortcuts(self) -> None:
        self.root.bind("<Control-s>", lambda _e: (self.save(), "break")[1])
        self.root.bind("<Control-z>", lambda _e: (self.undo(), "break")[1])
        self.root.bind("<Control-y>", lambda _e: (self.redo(), "break")[1])
        self.root.bind("<F5>", lambda _e: (self.reload_from_disk(), "break")[1])
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------------
    # 滚动
    # ------------------------------------------------------------------
    def _on_inner_configure(self, _event=None) -> None:
        self._canvas.configure(scrollregion=self._canvas.bbox("all"))

    def _on_canvas_configure(self, event) -> None:
        self._canvas.itemconfigure(self._inner_id, width=max(1, event.width))

    def _on_wheel(self, event) -> str:
        # 装得下就不许滚（否则「内容比视口短」时上下滚会把表单推走/露空白）
        if self._inner.winfo_reqheight() <= self._canvas.winfo_height():
            return "break"
        delta = 0
        if getattr(event, "num", None) == 4:
            delta = -1
        elif getattr(event, "num", None) == 5:
            delta = 1
        elif getattr(event, "delta", 0):
            delta = -1 if event.delta > 0 else 1
        if delta:
            self._canvas.yview_scroll(delta * 2, "units")
        return "break"

    # ------------------------------------------------------------------
    # 列表 / 表单
    # ------------------------------------------------------------------
    def current_buff(self) -> Buff:
        return self.model.buff(self.current_id)

    def select_buff(self, buff_id: str) -> None:
        self._select_buff(buff_id)

    def _select_buff(self, buff_id: str) -> None:
        self.current_id = buff_id
        self._build_sidebar()
        self._build_form()
        self._refresh_preview()
        self._set_status("已切换到「%s」" % self.current_buff().name)

    def _build_sidebar(self) -> None:
        with _NoRepaint(self.root):
            for child in self._sidebar_host.winfo_children():
                child.destroy()
            self._sidebar_buttons = {}
            for buff in self.model.buffs():
                selected = buff.id == self.current_id
                btn = RButton(
                    self._sidebar_host,
                    text="%s  %s" % (buff.icon, buff.name),
                    command=lambda bid=buff.id: self._select_buff(bid),
                    bg="#cfe3ff" if selected else UI["panel_alt"],
                    fg=UI["text"], anchor="w", padx=10, pady=8,
                )
                btn.pack(fill="x", pady=2)
                self._sidebar_buttons[buff.id] = btn

    def _build_form(self, *, reset_scroll: bool = True) -> None:
        """重建整张表单。

        ★ 撤销/重做只改数值时 `reset_scroll=False`：保留用户正在看的位置，
          不再每次都把表单滚回顶部（用户报的「所有 UI 回到初始位置」）。
        """
        buff = self.current_buff()
        try:
            old_offset = self._canvas.canvasy(0.0)
        except tk.TclError:
            old_offset = 0.0
        with _NoRepaint(self.root):
            self._building = True
            for child in self._inner.winfo_children():
                child.destroy()
            self.entries = {}
            self._field_by_key = {f.key: f for f in buff.fields}

            row_i = 0
            for group, fields in field_groups(buff):
                header = ttk.Label(self._inner, text=group, style="Group.TLabel")
                header.grid(row=row_i, column=0, sticky="w", padx=4, pady=(12, 4))
                row_i += 1
                for f in fields:
                    row = ttk.Frame(self._inner, style="TFrame")
                    row.grid(row=row_i, column=0, sticky="ew", padx=4, pady=2)
                    row.columnconfigure(3, weight=1)
                    ttk.Label(row, text=f.label, style="TLabel", width=22,
                              anchor="w").grid(row=0, column=0, sticky="w")
                    ent = ttk.Entry(row, width=12, justify="right")
                    ent.grid(row=0, column=1, sticky="w", padx=(8, 4))
                    ttk.Label(row, text=f.unit, style="Hint.TLabel", width=4,
                              anchor="w").grid(row=0, column=2, sticky="w")
                    ttk.Label(row, text=f.help, style="Hint.TLabel",
                              wraplength=420, justify="left").grid(
                        row=0, column=3, sticky="w", padx=(8, 0))
                    ent.insert(0, display_value(f, self.model.value(buff, f)))
                    ent.bind("<Return>", lambda _e, key=f.key: self._commit_and_break(key))
                    ent.bind("<FocusOut>", lambda _e, key=f.key: self.commit_field(key))
                    ent.bind("<Escape>", lambda _e, key=f.key: self._reset_entry(key))
                    self.entries[f.key] = ent
                    self._field_by_key[f.key] = f
                    row_i += 1
            self._inner.columnconfigure(0, weight=1)
            self._building = False
            try:
                self._inner.update_idletasks()
                self._canvas.configure(scrollregion=self._canvas.bbox("all"))
            except tk.TclError:
                pass
            if reset_scroll:
                self._canvas.yview_moveto(0.0)
            else:
                total = max(1.0, float(self._inner.winfo_reqheight()))
                viewport = float(self._canvas.winfo_height())
                pos = max(0.0, min(float(old_offset), max(0.0, total - viewport)))
                self._canvas.yview_moveto(pos / total)

    def _draw_icon(self, text: str) -> None:
        c = self._icon_canvas
        c.delete("all")
        _rounded_rect(c, 2, 2, 46, 46, 10, fill=UI["accent"], outline=UI["accent"])
        c.create_text(24, 24, text=text, fill=UI["accent_fg"],
                      font=("Microsoft YaHei UI", 18, "bold"))

    def _refresh_preview(self) -> None:
        buff = self.current_buff()
        self._draw_icon(buff.icon)
        self.summary_var.set("%s「%s」  %s" % (buff.name, buff.icon,
                                              self.model.summary(buff)))
        self.intro_var.set(buff.intro)
        self.preview_var.set(self.model.preview(buff))
        warns = self.model.warnings(buff)
        self.warning_var.set(("⚠ " + "\n⚠ ".join(warns)) if warns else "")

    # ------------------------------------------------------------------
    # 编辑
    # ------------------------------------------------------------------
    def _reset_entry(self, key: str) -> str:
        field = self._field_by_key.get(key)
        ent = self.entries.get(key)
        if field is None or ent is None:
            return "break"
        ent.delete(0, "end")
        ent.insert(0, display_value(field, self.model.value(self.current_buff(), field)))
        self._set_status("已放弃「%s」这一格的改动" % field.label)
        return "break"

    def _commit_and_break(self, key: str) -> str:
        self.commit_field(key)
        return "break"

    def commit_field(self, key: str) -> bool:
        """把某一格的文字写进 model。成功 / 没变化 / 不合法都返回是否成功提交。"""
        if self._building:
            return False
        field = self._field_by_key.get(key)
        ent = self.entries.get(key)
        buff = self.current_buff()
        if field is None or ent is None:
            return False
        text = ent.get()
        try:
            value, note = parse_value(field, text)
        except ValueError as exc:
            self._set_status("「%s」没改成：%s（原值保留）" % (field.label, exc), bad=True)
            self._reset_entry_silent(key)
            return False
        old = self.model.value(buff, field)
        if value == old and not note:
            ent.delete(0, "end")
            ent.insert(0, display_value(field, old))
            self._set_status("「%s」没有变化（%s）" % (field.label, display_value(field, old)))
            return True
        self._push_undo()
        self.model.set_value(buff, field, value)
        ent.delete(0, "end")
        ent.insert(0, display_value(field, value))
        self._redo_stack.clear()
        self._refresh_preview()
        self._refresh_dirty()
        shown = display_value(field, value)
        self._set_status("已修改「%s · %s」= %s%s（还没保存）"
                         % (buff.name, field.label, shown,
                            "；" + note if note else ""))
        return True

    def _reset_entry_silent(self, key: str) -> None:
        field = self._field_by_key.get(key)
        ent = self.entries.get(key)
        if field is None or ent is None:
            return
        ent.delete(0, "end")
        ent.insert(0, display_value(field, self.model.value(self.current_buff(), field)))

    def _push_undo(self) -> None:
        self._undo_stack.append(self.model.text)
        if len(self._undo_stack) > UNDO_LIMIT:
            del self._undo_stack[0]

    def undo(self) -> None:
        if not self._undo_stack:
            self._set_status("没有可撤销的操作")
            return
        self._redo_stack.append(self.model.text)
        self.model.restore_text(self._undo_stack.pop())
        self._after_history_change("已撤销上一步")

    def redo(self) -> None:
        if not self._redo_stack:
            self._set_status("没有可重做的操作")
            return
        self._undo_stack.append(self.model.text)
        self.model.restore_text(self._redo_stack.pop())
        self._after_history_change("已重做")

    def _after_history_change(self, message: str) -> None:
        self._build_form(reset_scroll=False)
        self._refresh_preview()
        self._refresh_dirty()
        self._set_status(message + "（还没保存）" if self.model.dirty else message)

    # ------------------------------------------------------------------
    # 文件
    # ------------------------------------------------------------------
    def save(self) -> None:
        try:
            target = self.model.save()
        except ModelError as exc:
            self._set_status(str(exc), bad=True)
            return
        self._refresh_dirty()
        self._set_status("已保存 → %s" % target, ok=True)

    def reload_from_disk(self, ask: bool = True) -> None:
        if ask and self.model.dirty:
            if not messagebox.askyesno(
                    "重载", "当前有未保存的改动，重载会丢掉它们。继续？", parent=self.root):
                self._set_status("已取消重载")
                return
        try:
            self.model.reload()
        except ModelError as exc:
            self._set_status(str(exc), bad=True)
            return
        self._undo_stack.clear()
        self._redo_stack.clear()
        self._build_form(reset_scroll=False)
        self._refresh_preview()
        self._refresh_dirty()
        self._set_status("已从磁盘重载（撤销 / 重做历史已清空）")

    def _on_close(self) -> None:
        if self.model.dirty:
            answer = messagebox.askyesnocancel(
                "退出", "有未保存的改动，保存后退出？", parent=self.root)
            if answer is None:
                return
            if answer:
                self.save()
                if self.model.dirty:
                    return
        self.root.destroy()

    # ------------------------------------------------------------------
    # 状态 / 测试读口
    # ------------------------------------------------------------------
    def _set_status(self, text: str, ok: bool = False, bad: bool = False) -> None:
        """状态栏一句话。`ok` / `bad` 目前只用于将来上色（保留参数让调用处读得懂）。"""
        self.status_var.set(text)
        del ok, bad

    def _refresh_dirty(self) -> None:
        self.dirty_var.set("● 未保存" if self.model.dirty else "已保存")
        self.root.title("DAEEM buff 编辑器%s" % (" *" if self.model.dirty else ""))

    # 测试读口（不碰私有变量）
    def status_text(self) -> str:
        return self.status_var.get()

    def dirty_text(self) -> str:
        return self.dirty_var.get()

    def preview_text(self) -> str:
        return self.preview_var.get()

    def warnings_text(self) -> str:
        return self.warning_var.get()

    def entry_for(self, key: str) -> Optional[ttk.Entry]:
        return self.entries.get(key)

    def set_entry(self, key: str, text: str) -> None:
        ent = self.entries.get(key)
        if ent is None:
            raise KeyError(key)
        ent.delete(0, "end")
        ent.insert(0, text)


def run(config_path: Path, project_dir: Optional[Path] = None) -> int:
    """打开编辑器主窗口（调用方负责 mainloop 之外的一切）。"""
    model = ConfigModel.load(Path(config_path))
    root = tk.Tk()
    _apply_theme(root)
    BuffEditorApp(root, model, config_path, project_dir)
    root.mainloop()
    return 0
