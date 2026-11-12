"""app.py —— 科技编辑器界面（tkinter，零第三方依赖）。

布局（与 unit_editor / map_editor 同一套浅色主题）：

    ┌──────────────────────────────────────────────────────────────┐
    │ DAEEM 科技编辑器        config.json   ● 未保存  [重载] [保存] │
    ├──────────────┬───────────────────────────────────────────────┤
    │ 科技          │ 科技 · 建筑加固  二本 · 1 条效果 · 1 金/秒      │
    │  ▾ 全局       │ 原生科技里的第 7 条……                          │
    │  ▾ 原生科技   ├───────────────────────────────────────────────┤
    │  ▾ 派系科技   │ 文案 / 基础 / 效果 各组                        │
    │  ▾ 科技页     │ 每个数值一行：名称 [输入框] 单位  说明          │
    │              ├───────────────────────────────────────────────┤
    │              │ 游戏里的样子（科技格 / 悬停说明预览）          │
    │              │ 提示：跨字段不合理的组合（只提示，不阻止保存）  │
    ├──────────────┴───────────────────────────────────────────────┤
    │ 状态栏：上一次操作的结果 · 文件路径                            │
    └──────────────────────────────────────────────────────────────┘

交互（与 unit_editor 同一套习惯）：

    · 改完按 Enter（或点别处）生效；打错字**不会写坏数据**，状态栏说一句；
    · 输入框里 Esc = 放弃这一格的改动、恢复原值；
    · Ctrl+S 保存 · Ctrl+Z / Ctrl+Y 撤销 / 重做 · F5 从磁盘重读；
    · 百分数字段显示 / 输入都是**百分数**（50 = 50%），写回文件仍是 0.5。

★ 表单是「整块重建」而不是就地改值：一页最多十几个字段，重建 ~10 ms，
  换来「界面永远等于数据」——不用维护控件与字段的对应关系。
"""

from __future__ import annotations

import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Any, Dict, List, Optional, Tuple

_TOOLS_DIR = Path(__file__).resolve().parent.parent
if str(_TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(_TOOLS_DIR))

# ★ 2026.11 UI 改造：共用暗色主题 / 圆角按钮。
from editor_ui import dpi
from editor_ui import default_preset as _default_tokens
from editor_ui import Card, EditorShell, PillButton, RoundedPanel, ThinScrollbar
from editor_ui import RADIUS_L, RADIUS_M
from editor_ui import apply_theme as _shared_apply_theme
from editor_ui import is_dark as _shared_is_dark
from editor_ui import set_ui as _set_editor_ui
from editor_ui import shade as _shared_shade

from . import model as model_mod  # noqa: F401 - 测试会从这里拿 model 模块
from .configfile import JsonError
from .model import (
    TechPage,
    ConfigModel,
    Field,
    ModelError,
    display_value,
    field_groups,
    fmt_number,
    parse_value,
)

#: 界面配色（四个编辑器同一套 —— 看起来是一家的）。
#: ★ 2026.11：暗色游戏工具（A 方向），token 在 `tools/editor_ui/tokens.py`。
UI = dict(_default_tokens())
_set_editor_ui(UI)

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


RButton = PillButton


def _apply_theme(root: tk.Tk) -> ttk.Style:
    """ttk 主题统一交给 tools/editor_ui/theme.py。"""
    return _shared_apply_theme(root, UI)


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

class TechEditorApp:
    """科技编辑器窗口。测试可以只建 `tk.Tk()` + 这个类（不调 mainloop）。"""

    def __init__(self, root: tk.Tk, model: ConfigModel,
                 config_path: Optional[Path] = None,
                 project_dir: Optional[Path] = None) -> None:
        self.root = root
        self.model = model
        self.config_path = Path(config_path) if config_path else model.path
        self.project_dir = project_dir
        self.current_id: str = ""
        self.entries: Dict[str, ttk.Entry] = {}
        self._field_by_key: Dict[str, Field] = {}
        self._building = False
        self._undo_stack: List[str] = []
        self._redo_stack: List[str] = []
        #: ★★ 2026.11：左栏改成 Treeview 之后，页面 id → 那一行的 iid（`b:<id>`）。
        #: 原来的 `_sidebar_buttons`（id → 圆角按钮）已删 —— 那套「按钮塞进画布」

        self._sidebar_items: Dict[str, str] = {}
        #: Treeview 的 `<<TreeviewSelect>>` 会因为我们**自己**改选中而触发 ⇒ 用它防回环
        self._suppress_side = False

        self.root.title("DAEEM 科技编辑器")
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
        pages = self.model.pages()
        self.current_id = pages[0].id if pages else ""
        self._select_page(self.current_id)
        self._refresh_dirty()

    # ------------------------------------------------------------------
    # 构建：顶栏 / 主体 / 状态栏
    # ------------------------------------------------------------------
    def _build_topbar(self) -> None:
        # ---- 外壳：品牌 + 右侧「路径 / 未保存 / 撤销 重做 重载 保存」+ 状态栏
        self.shell = EditorShell(
            self.root,
            title="DAEEM 科技编辑器",
            brand="科技编辑器",
            geometry="1060x780",
            minsize=(900, 640),
            status_hint="Ctrl+S 保存 · Ctrl+Z 撤销 · F5 重载",
        )
        self.status_var = self.shell.status_var
        path_text = str(self.config_path) if self.config_path else "（未指定文件）"
        # ★ 这个窗口只有 1060 宽，路径按「尾巴」截断，别把右边那排按钮挤出去。
        shown = path_text if len(path_text) <= 40 else "…" + path_text[-39:]
        self.path_label = self.shell.add_file_label()
        self.path_label.configure(text=shown)
        #: 「● 未保存 / 已保存」——沿用 ttk.Label，测试读 `dirty_text()` 不受影响
        self.dirty_label = tk.Label(self.shell.right, textvariable=self.dirty_var,
                                    bg=UI["bar"], fg=UI["text_dim"], font=FONT_SMALL)
        self.dirty_label.pack(side="left", padx=(0, 10), pady=(0, 9))
        self._undo_button = self.shell.add_button("undo", "撤销", self.undo)
        self._redo_button = self.shell.add_button("redo", "重做", self.redo)
        self._reload_button = self.shell.add_button("reload", "重载", self.reload_from_disk)
        self._save_button = self.shell.add_button("save", "保存", self.save, primary=True)

    def _build_body(self) -> None:
        body = self.shell.content

        # ---- 左：科技目录（一张卡片，整列可滚）
        left = RoundedPanel(body, radius=RADIUS_L, fill=UI["panel"],
                            outline=UI["line"], bg=UI["bg"])
        left.pack(side="left", fill="y")
        left.configure(width=dpi.px(252))
        left.pack_propagate(False)

        head = tk.Frame(left.body, bg=UI["panel"])
        head.pack(fill="x", padx=14, pady=(12, 0))
        tk.Label(head, text="科技", bg=UI["panel"], fg=UI["text"],
                 font=FONT_GROUP).pack(side="left")
        tk.Label(left.body, text="点一条 → 右边改它的全部数值",
                 bg=UI["panel"], fg=UI["text_dim"], font=FONT_SMALL,
                 anchor="w", wraplength=dpi.px(212)).pack(fill="x", padx=dpi.px(14), pady=(dpi.px(3), dpi.px(8)))
        tk.Frame(left.body, bg=UI["line_soft"], height=1).pack(fill="x", padx=14)

        # ★ 提示先摆（side=bottom），列表后摆 —— pack 是先到先得，
        #   反过来摆的话窗口一矮，底部提示会被挤出可视区。
        tk.Label(left.body,
                 text="本工具只编辑 config.json 里已经存在的键。\n"
                      "加新科技 / 新效果键仍要先在游戏侧读它\n（README 第四节）。",
                 bg=UI["panel"], fg=UI["text_dim"], font=FONT_SMALL,
                 anchor="w", justify="left", wraplength=dpi.px(212)).pack(
            side="bottom", anchor="w", padx=14, pady=(6, 12))

        side_wrap = tk.Frame(left.body, bg=UI["panel"])
        side_wrap.pack(side="top", fill="both", expand=True, padx=(10, 6), pady=(8, 4))
        # ★ 左栏用 Treeview（单控件自己滚条目，不搬子窗口 → 不会出现文字撕裂）
        self._side_tree = ttk.Treeview(side_wrap, show="tree", selectmode="browse")
        side_vsb = ThinScrollbar(side_wrap, command=self._side_tree.yview,
                                 trough=UI["panel"])
        self._side_tree.configure(yscrollcommand=side_vsb.set)
        side_vsb.pack(side="right", fill="y", padx=(4, 0))
        self._side_tree.pack(side="left", fill="both", expand=True)
        self._side_tree.column("#0", width=dpi.px(190), stretch=True)
        self._side_tree.tag_configure("section", foreground=UI["accent"], font=FONT_GROUP)
        self._side_tree.bind("<<TreeviewSelect>>", self._on_side_select)
        # ★ 滚轮：`_on_wheel` 是 bind_all（窗口任何地方滚都滚右边的表单），
        #   所以这里必须在**控件级**截住（Tk 绑定顺序：控件 → 类 → 顶层 → all）。
        self._side_tree.bind("<MouseWheel>", self._on_side_wheel)

        # ---- 右：内容卡片
        right = RoundedPanel(body, radius=RADIUS_L, fill=UI["panel"],
                             outline=UI["line"], bg=UI["bg"])
        right.pack(side="left", fill="both", expand=True, padx=(12, 0))

        head = tk.Frame(right.body, bg=UI["panel"])
        head.pack(fill="x", padx=16, pady=(12, 0))
        self._icon_canvas = tk.Canvas(head, width=44, height=44, bg=UI["panel"],
                                      highlightthickness=0, bd=0, takefocus=0)
        self._icon_canvas.pack(side="left", anchor="n")
        name_box = tk.Frame(head, bg=UI["panel"])
        name_box.pack(side="left", fill="x", expand=True, padx=(12, 0))
        tk.Label(name_box, textvariable=self.summary_var, bg=UI["panel"],
                 fg=UI["text"], font=FONT_GROUP, anchor="w").pack(anchor="w")
        tk.Label(name_box, textvariable=self.intro_var, bg=UI["panel"],
                 fg=UI["text_dim"], font=FONT_SMALL, wraplength=dpi.px(640),
                 justify="left", anchor="w").pack(anchor="w", pady=(3, 0))

        tk.Frame(right.body, bg=UI["line_soft"], height=1).pack(
            fill="x", padx=16, pady=(10, 0))

        # ---- 表单（可滚动）
        form_wrap = tk.Frame(right.body, bg=UI["panel"])
        form_wrap.pack(fill="both", expand=True, padx=(12, 8), pady=(8, 4))
        self._canvas = tk.Canvas(form_wrap, bg=UI["panel"], highlightthickness=0, bd=0)
        vsb = ThinScrollbar(form_wrap, command=self._canvas.yview, trough=UI["panel"])
        self._canvas.configure(yscrollcommand=vsb.set)
        vsb.pack(side="right", fill="y", padx=(4, 0))
        self._canvas.pack(side="left", fill="both", expand=True)
        self._inner = tk.Frame(self._canvas, bg=UI["panel"])
        self._inner_id = self._canvas.create_window((0, 0), window=self._inner, anchor="nw")
        self._inner.bind("<Configure>", self._on_inner_configure)
        self._canvas.bind("<Configure>", self._on_canvas_configure)
        self._canvas.bind_all("<MouseWheel>", self._on_wheel)

        # ---- 游戏里的样子（固定在下方，不跟着表单滚）
        preview_card = Card(right.body, radius=RADIUS_M, fill=UI["panel_alt"],
                            outline=UI["line"], bg=UI["panel"])
        preview_card.pack(fill="x", padx=16, pady=(6, 6))
        tk.Label(preview_card.body, text="游戏里的样子（科技格 / 悬停说明预览）",
                 bg=UI["panel_alt"], fg=UI["text_dim"], font=FONT_SMALL,
                 anchor="w").pack(fill="x", padx=12, pady=(9, 0))
        self._preview_label = tk.Label(preview_card.body, textvariable=self.preview_var,
                                       bg=UI["panel_alt"], fg=UI["text"],
                                       font=FONT_SMALL, justify="left", anchor="w",
                                       wraplength=dpi.px(720))
        self._preview_label.pack(fill="x", padx=12, pady=(2, 9))

        # ---- 跨字段提示
        self._warning_label = tk.Label(right.body, textvariable=self.warning_var,
                                       bg=UI["panel"], fg=UI["warn"], font=FONT_SMALL,
                                       justify="left", anchor="w", wraplength=dpi.px(860))
        self._warning_label.pack(fill="x", padx=16, pady=(0, 10))

    def _build_statusbar(self) -> None:
        """状态栏由 `EditorShell` 建好了（左边状态文字 / 右边快捷键提示）。"""
        return None

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

    def _on_side_wheel(self, event) -> str:
        """左栏（列表）的滚轮：滚列表，**不要**带着右边的表单一起滚。

        `_on_wheel` 是 `bind_all` 的（窗口任何地方滚都滚表单），而 Tk 的绑定顺序是
        控件 → 类 → 顶层 → all，所以这里返回 "break" 就能把事件截住、不传给 all。
        ★ 也正因为绑定在**控件级**，Treeview 自己的类级滚轮绑定不会跑（控件先于类），
          所以这里得自己 `yview_scroll` —— 否则停在列表上滚轮会「什么都不动」。
        """
        tree = getattr(self, "_side_tree", None)
        if tree is None:
            return "break"
        delta = 0
        if getattr(event, "num", None) == 4:
            delta = -1
        elif getattr(event, "num", None) == 5:
            delta = 1
        elif getattr(event, "delta", 0):
            delta = -1 if event.delta > 0 else 1
        if delta:
            tree.yview_scroll(delta * 2, "units")
        return "break"

    # ------------------------------------------------------------------
    # 列表 / 表单
    # ------------------------------------------------------------------
    def current_page(self) -> TechPage:
        return self.model.page(self.current_id)

    def select_page(self, page_id: str) -> None:
        self._select_page(page_id)

    def _select_page(self, page_id: str) -> None:
        self.current_id = page_id
        self._build_sidebar()
        self._build_form()
        self._refresh_preview()
        self._set_status("已切换到「%s」" % self.current_page().name)
        try:
            self.shell.reveal()
        except (AttributeError, tk.TclError):
            pass

    def _build_sidebar(self) -> None:
        """把当前 doc 的条目填进左栏的 Treeview（四个分组：全局 / 原生 / 派系 / 科技页）。

        ★ 只**填条目**，不重建控件（Treeview 是一次建好的，见 `_build_body`）——
          重建控件会丢滚动位置，也会把用户正在看的那一段弹回顶部。
        """
        tree = self._side_tree
        # 先记下滚动位置：改一个数值后 `_build_sidebar` 也会跑一遍，
        # 每次都跳回顶部的话，滚到下面改科技的时候会一直往上弹。
        try:
            top = float(tree.yview()[0])
        except tk.TclError:
            top = 0.0
        with _NoRepaint(self.root):
            self._suppress_side = True
            try:
                tree.delete(*tree.get_children())
                self._sidebar_items = {}
                parent = ""
                last_section = ""
                for page in self.model.pages():
                    section = _page_section(page.id)
                    if section != last_section:
                        parent = tree.insert("", "end", iid="sec:" + section,
                                             text="  " + section, open=True,
                                             tags=("section",))
                        last_section = section
                    iid = "b:" + page.id
                    # ★ 科技页的名字本来就叫「科技 · 建筑加固」，前面再加个「科」图标
                    #   会读成「科 科技·建筑加固」（像重复）；分组标题已经说明了类别。
                    text = page.name
                    if section in ("全局", "科技页"):
                        text = "%s  %s" % (page.icon, page.name)
                    tree.insert(parent, "end", iid=iid, text=text)
                    self._sidebar_items[page.id] = iid
            finally:
                self._suppress_side = False
            self._sync_sidebar_selection()
            if top > 0.0:
                tree.yview_moveto(top)

    def _sync_sidebar_selection(self) -> None:
        """把 Treeview 的选中项对回 `current_id`（重建 / 换页之后调）。"""
        tree = getattr(self, "_side_tree", None)
        iid = getattr(self, "_sidebar_items", {}).get(self.current_id)
        if tree is None or not iid:
            return
        self._suppress_side = True
        try:
            tree.selection_set(iid)
            tree.see(iid)
        except tk.TclError:
            pass
        finally:
            self._suppress_side = False

    def _on_side_select(self, _event=None) -> None:
        """左栏选中某一条 → 切过去。

        ★ 分组行（`sec:`）也会被点中：那不是一页，**把选中弹回当前页**，
          否则右边还是旧内容、左边却高亮在一个标题上。
        """
        tree = getattr(self, "_side_tree", None)
        if tree is None or self._suppress_side:
            return
        sel = tree.selection()
        if not sel:
            return
        iid = str(sel[0])
        if not iid.startswith("b:"):
            self._sync_sidebar_selection()
            return
        bid = iid[2:]
        if bid and bid != self.current_id:
            self._select_page(bid)

    def _build_form(self, *, reset_scroll: bool = True) -> None:
        """重建整张表单。

        ★ 撤销/重做只改数值时 `reset_scroll=False`：保留用户正在看的位置，
          不再每次都把表单滚回顶部（用户报的「所有 UI 回到初始位置」）。
        """
        page = self.current_page()
        try:
            old_offset = self._canvas.canvasy(0.0)
        except tk.TclError:
            old_offset = 0.0
        with _NoRepaint(self.root):
            self._building = True
            for child in self._inner.winfo_children():
                child.destroy()
            self.entries = {}
            self._field_by_key = {f.key: f for f in page.fields}

            row_i = 0
            for group, fields in field_groups(page):
                header = ttk.Label(self._inner, text=group, style="Group.TLabel")
                header.grid(row=row_i, column=0, sticky="w", padx=4, pady=(12, 4))
                row_i += 1
                for f in fields:
                    row = ttk.Frame(self._inner, style="TFrame")
                    row.grid(row=row_i, column=0, sticky="ew", padx=4, pady=2)
                    row.columnconfigure(3, weight=1)
                    ttk.Label(row, text=f.label, style="TLabel", width=22,
                              anchor="w").grid(row=0, column=0, sticky="w")
                    # ★★ 2026.11：文字字段（科技的名字 / 小字 / 详情、槽位里的 id）要宽一点、
                    #   左对齐 —— 数字那套「窄框 + 右对齐」套在句子上没法读。
                    if f.kind == "text":
                        ent = ttk.Entry(row, width=42, justify="left")
                    else:
                        ent = ttk.Entry(row, width=12, justify="right")
                    ent.grid(row=0, column=1, sticky="w", padx=(8, 4))
                    ttk.Label(row, text=f.unit, style="Hint.TLabel", width=4,
                              anchor="w").grid(row=0, column=2, sticky="w")
                    # ★ 帮助文字放到**下一行**、和输入框左对齐：
                    #   挤在同一行时，窄页面（槽位 / 科技页）里 wraplength 比可用宽度大，
                    #   文字会直接冲出卡片右边被裁掉（实测）。
                    ttk.Label(row, text=f.help, style="Hint.TLabel",
                              wraplength=dpi.px(560), justify="left").grid(
                        row=1, column=1, columnspan=3, sticky="w", padx=(8, 0),
                        pady=(1, 3))
                    ent.insert(0, display_value(f, self.model.value(page, f)))
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
        page = self.current_page()
        self._draw_icon(page.icon)
        self.summary_var.set("%s「%s」  %s" % (page.name, page.icon,
                                              self.model.summary(page)))
        self.intro_var.set(page.intro)
        self.preview_var.set(self.model.preview(page))
        warns = self.model.warnings(page)
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
        ent.insert(0, display_value(field, self.model.value(self.current_page(), field)))
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
        page = self.current_page()
        if field is None or ent is None:
            return False
        text = ent.get()
        try:
            value, note = parse_value(field, text)
        except ValueError as exc:
            self._set_status("「%s」没改成：%s（原值保留）" % (field.label, exc), bad=True)
            self._reset_entry_silent(key)
            return False
        old = self.model.value(page, field)
        if value == old and not note:
            ent.delete(0, "end")
            ent.insert(0, display_value(field, old))
            self._set_status("「%s」没有变化（%s）" % (field.label, display_value(field, old)))
            return True
        self._push_undo()
        self.model.set_value(page, field, value)
        ent.delete(0, "end")
        ent.insert(0, display_value(field, value))
        self._redo_stack.clear()
        self._refresh_preview()
        self._refresh_dirty()
        shown = display_value(field, value)
        self._set_status("已修改「%s · %s」= %s%s（还没保存）"
                         % (page.name, field.label, shown,
                            "；" + note if note else ""))
        return True

    def _reset_entry_silent(self, key: str) -> None:
        field = self._field_by_key.get(key)
        ent = self.entries.get(key)
        if field is None or ent is None:
            return
        ent.delete(0, "end")
        ent.insert(0, display_value(field, self.model.value(self.current_page(), field)))

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
        try:
            self.shell.toast("已保存 %s" % Path(target).name)
        except (AttributeError, tk.TclError):
            pass

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
        self.root.title("DAEEM 科技编辑器%s" % (" *" if self.model.dirty else ""))

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


def _page_section(page_id: str) -> str:
    """左栏分组：全局 / 原生科技 / 派系科技 / 科技页。

    ★ 只影响「怎么摆」，不参与任何数据判断 —— 页面 id 是 `tech:` 开头的那一套
      （见 `model.ConfigModel.tech_pages()`）。
    """
    if page_id == "tech:global":
        return "全局"
    if page_id.startswith("tech:slots:"):
        return "科技页"
    if page_id.startswith("tech:list:"):
        return "原生科技"
    if page_id.startswith("tech:clan_list:"):
        return "派系科技"
    return "其他"


def run(config_path: Path, project_dir: Optional[Path] = None) -> int:
    """打开编辑器主窗口（调用方负责 mainloop 之外的一切）。"""
    model = ConfigModel.load(Path(config_path))
    dpi.enable_high_dpi()
    root = tk.Tk()
    _apply_theme(root)
    TechEditorApp(root, model, config_path, project_dir)
    root.mainloop()
    return 0
