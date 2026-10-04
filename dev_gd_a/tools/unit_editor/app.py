"""app.py —— 单位编辑器的界面（tkinter，零依赖）。

布局（照 map_editor 那一套，用熟了就不用重新学）：

    ┌──────────────────────────────────────────────────┬──────────────┐
    │ [单位] [建筑] [科技]          单位文件 保存 重载 另存为│              │
    ├──────────────────────────────────────────────────┤   侧边栏      │
    │                                                  │  选中条目的   │
    │    列表（兵种 / 将领 / 建筑 / 科技）              │  属性表单     │
    │                                                  │              │
    ├──────────────────────────────────────────────────┤              │
    │ 状态栏：文件路径 · 改没改 · 上一次操作的结果       │              │
    └──────────────────────────────────────────────────┴──────────────┘

动线（与设计师的说法一一对应）：

    · 点左边一行            → 右边出现它的全部数值，改完按 Enter 或点别处生效
    · 数字输入框打错字      → 状态栏说一句「这不是数字」，**原值不动**（不静默写坏数据）
    · 「＋ 新建兵种 / 建筑」 → 照一个模板复制一份，再改几处（设计师的真实动线）
    · Ctrl+S               → 写回 `daeem/data/config.json`（只动改过的那几个字符）
    · Ctrl+Z / Ctrl+Y      → 撤销 / 重做（按整份文本快照，简单且不会错）
    · F5                   → 从磁盘重新读一遍（外面手改过 config.json 时用）

★ 为什么表单是「重建」而不是「就地改值」：
  地图编辑器那是**画布**，重画一次 20 ms 会让人明显觉得卡；
  这里是**表单**，一次只有几十个控件，重建 ~10 ms，而「选中换了人」本来就该整块换内容。
  重建换来的是「界面永远等于数据」——不用维护一堆控件与字段的对应关系。
"""

from __future__ import annotations

import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Any, Callable, Dict, List, Optional, Tuple

from . import model as model_mod
from .configfile import JsonError, parse_number
from .model import (
    BUILDING_FIELDS,
    GENERAL_STAT_FIELDS,
    ICON_HINT,
    LEVEL_ATTACK_FIELDS,
    LEVEL_FIELDS,
    RECRUIT_FIELDS,
    TECH_EFFECTS,
    TECH_FIELDS,
    UNIT_FIELDS,
    Building,
    ConfigModel,
    Field,
    General,
    ModelError,
    Tech,
    Unit,
    fmt_number,
)

#: 界面里到处都在用的短名字（数字 → 文字）
fmt = fmt_number

#: 界面配色（与地图编辑器同一套 —— 两个工具看起来是一家的）
UI = {
    "bg": "#1e1f22",
    "panel": "#26282c",
    "panel_alt": "#2b2d31",
    "line": "#3a3d42",
    "text": "#dcdcdc",
    "text_dim": "#8b8f96",
    "accent": "#5ac8ff",
    "ok": "#8fd694",
    "warn": "#ffd166",
    "bad": "#e07a7a",
}

#: 三个页签：key → （按钮文字，状态栏提示）
PAGES: Tuple[Tuple[str, str, str], ...] = (
    ("unit", "单位", "单位页：左边上面是兵种、下面是开局三位将领；点一行改右边的数值"),
    ("building", "建筑", "建筑页：造价 / 建造时间 / 血量 / 能不能攻击 / 每一级的升级数值"),
    ("tech", "科技", "科技页：名字与属性加成（这一版不支持新增科技）"),
)

#: 兵种列表（左上 Treeview）的列：key → （表头，列宽）。
#:
#: ★★ 为什么把它提成模块常量：测试要按**列名**取那一格的值，而不是写死下标 ——
#:   本轮在「攻速」后面插了一列「视野」，写死下标的断言会去读错格子，
#:   报出来的还是「造价那一列不对」，完全指不到真正的原因（踩过一次）。
UNIT_TREE_COLUMNS: Tuple[Tuple[str, str, int], ...] = (
    ("glyph", "字", 38),
    ("name", "名称", 100),
    ("cls", "归属", 76),
    ("hp", "血量", 60),
    ("dmg", "攻击", 60),
    ("rng", "距离", 56),
    ("spd", "移速", 56),
    ("cd", "攻速", 56),
    ("vision", "视野", 50),
    ("cost", "造价 粮/金/人口", 150),
    ("train", "招募秒", 64),
)

#: 建筑列表（左下 Treeview）的列 —— 与 `UNIT_TREE_COLUMNS` 同一个理由提成常量
#: （测试按列名取那一格，而不是写死下标：本轮给建筑也加了「视野」一列）。
BUILDING_TREE_COLUMNS: Tuple[Tuple[str, str, int], ...] = (
    ("name", "名称", 110),
    ("hp", "血量", 66),
    ("atk", "攻击", 120),
    ("vision", "视野", 50),
    ("build", "建造秒", 66),
    ("lv", "升级", 70),
    ("buildable", "建造页", 60),
    ("cost", "造价 粮/金", 130),
)

UNDO_LIMIT = 200


class EditorApp:
    def __init__(self, root: tk.Tk, model: ConfigModel, config_path: Optional[Path] = None,
                 project_dir: Optional[Path] = None) -> None:
        self.root = root
        self.model = model
        self.project_dir = Path(project_dir) if project_dir else None
        self.page = "unit"
        #: 当前选中的东西：("unit", id) / ("general", index) / ("building", id) / ("tech", index)
        self.selection: Optional[Tuple[str, Any]] = None
        self._suppress = False            # 重建期间别触发 FocusOut 提交
        self._editing = False             # 正在提交（防止递归）
        self._undo: List[str] = []
        self._redo: List[str] = []

        self._setup_window()
        self._build_widgets()
        self._bind_keys()
        self.refresh_all()
        self.update_title()
        self.status("打开 %s　%s" % (self._path_text(), "（没有改动）" if not self.model.dirty
                                     else "（有未保存的改动）"))

    # ==================================================================
    # 窗口骨架
    # ==================================================================

    def _setup_window(self) -> None:
        self.root.title("DAEEM 单位编辑器")
        self.root.configure(bg=UI["bg"])
        self.root.geometry("1280x820")
        self.root.minsize(1020, 640)
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", background=UI["panel"], foreground=UI["text"],
                        fieldbackground=UI["panel_alt"], bordercolor=UI["line"],
                        lightcolor=UI["panel"], darkcolor=UI["panel"])
        style.configure("TFrame", background=UI["panel"])
        style.configure("Bar.TFrame", background=UI["bg"])
        style.configure("TLabel", background=UI["panel"], foreground=UI["text"])
        style.configure("Dim.TLabel", background=UI["panel"], foreground=UI["text_dim"])
        style.configure("Hint.TLabel", background=UI["panel"], foreground=UI["text_dim"],
                        font=("Microsoft YaHei UI", 8))
        style.configure("TButton", background=UI["panel_alt"], foreground=UI["text"],
                        bordercolor=UI["line"], focuscolor=UI["panel_alt"], padding=(8, 4))
        style.map("TButton", background=[("active", "#3a3d42"), ("pressed", "#45484f")],
                  foreground=[("disabled", UI["text_dim"])])
        style.configure("TEntry", fieldbackground=UI["panel_alt"], foreground=UI["text"],
                        insertcolor=UI["text"])
        style.configure("TCombobox", fieldbackground=UI["panel_alt"], background=UI["panel_alt"],
                        foreground=UI["text"], arrowcolor=UI["text"])
        style.configure("Treeview", background=UI["panel_alt"], fieldbackground=UI["panel_alt"],
                        foreground=UI["text"], bordercolor=UI["line"], rowheight=24)
        style.configure("Treeview.Heading", background=UI["panel"], foreground=UI["text_dim"])
        style.map("Treeview", background=[("selected", "#2f5f7a")],
                  foreground=[("selected", "#ffffff")])
        style.configure("TCheckbutton", background=UI["panel"], foreground=UI["text"],
                        focuscolor=UI["panel"])
        style.map("TCheckbutton", background=[("active", UI["panel"])])
        style.configure("TNotebook", background=UI["bg"], borderwidth=0)

    def _button(self, parent, text: str, command: Callable[[], None], **kw) -> tk.Button:
        """统一造按钮：一律 `takefocus=0`。

        ★ 为什么（与地图编辑器同一个坑）：tk 里**空格**是「激活焦点按钮」，
          按钮拿住键盘焦点之后，设计师在输入框里敲空格会变成「又点了一次那个按钮」。
        """
        kw.setdefault("bg", UI["panel_alt"])
        kw.setdefault("fg", UI["text"])
        kw.setdefault("activebackground", "#3a3d42")
        kw.setdefault("activeforeground", UI["accent"])
        kw.setdefault("padx", 8)
        kw.setdefault("pady", 4)
        kw.setdefault("font", ("Microsoft YaHei UI", 9))
        kw["takefocus"] = 0
        kw["relief"] = "flat"
        return tk.Button(parent, text=text, command=command, **kw)

    def _build_widgets(self) -> None:
        # ---- 顶栏：左页签 + 右文件按钮
        top = tk.Frame(self.root, bg=UI["bg"])
        top.pack(side="top", fill="x")
        tk.Label(top, text="单位编辑器", bg=UI["bg"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 11, "bold")).pack(side="left", padx=(10, 14), pady=6)
        self.tab_buttons: Dict[str, tk.Button] = {}
        for key, label, _hint in PAGES:
            btn = self._button(top, label, lambda k=key: self.set_page(k),
                               bg=UI["panel"], fg=UI["text_dim"],
                               activebackground=UI["panel_alt"], activeforeground=UI["accent"],
                               font=("Microsoft YaHei UI", 10), padx=16, pady=5)
            btn.pack(side="left", padx=2)
            self.tab_buttons[key] = btn

        right = tk.Frame(top, bg=UI["bg"])
        right.pack(side="right", padx=8)
        self.file_label = tk.Label(right, text="", bg=UI["bg"], fg=UI["text_dim"],
                                   font=("Microsoft YaHei UI", 9))
        self.file_label.pack(side="left", padx=(0, 8))
        self.file_buttons: Dict[str, tk.Button] = {}
        for key, text, cmd, tip in (
                ("save", "保存", self.do_save, "写回 data/config.json（Ctrl+S）"),
                ("reload", "重新载入", self.do_reload, "丢掉改动、从磁盘重读（F5）"),
                ("save_as", "另存为…", self.do_save_as, "想留一份对照时用")):
            btn = self._button(right, text, cmd, padx=12, pady=5)
            btn.pack(side="left", padx=3)
            self.file_buttons[key] = btn
        self.file_buttons["save"].configure(bg="#2f5f7a", fg="#eaf6ff",
                                            activebackground="#3a7699")

        # ---- 主体：左列表 + 右侧边栏
        body = tk.Frame(self.root, bg=UI["bg"])
        body.pack(side="top", fill="both", expand=True)

        left = tk.Frame(body, bg=UI["bg"])
        left.pack(side="left", fill="both", expand=True)
        self.list_host = tk.Frame(left, bg=UI["bg"])
        self.list_host.pack(side="top", fill="both", expand=True)
        self.action_bar = tk.Frame(left, bg=UI["bg"])
        self.action_bar.pack(side="bottom", fill="x", padx=10, pady=(0, 8))

        self.status_var = tk.StringVar(value="")
        tk.Label(self.root, textvariable=self.status_var, anchor="w", bg=UI["panel"],
                 fg=UI["text_dim"], padx=10, pady=4,
                 font=("Microsoft YaHei UI", 9)).pack(side="bottom", fill="x")

        # ---- 侧边栏（可滚：建筑页那一堆升级数值会很长）
        side_wrap = tk.Frame(body, bg=UI["panel"], width=420)
        side_wrap.pack(side="right", fill="y")
        side_wrap.pack_propagate(False)
        self.sidebar_scroll = ttk.Scrollbar(side_wrap, orient="vertical",
                                            command=self.sidebar_yview)
        self.sidebar_canvas = tk.Canvas(side_wrap, bg=UI["panel"], width=404,
                                        highlightthickness=0, bd=0, takefocus=0,
                                        yscrollcommand=self.on_sidebar_yscroll)
        self.sidebar_scroll.pack(side="right", fill="y")
        self.sidebar_canvas.pack(side="left", fill="both", expand=True)
        self.sidebar = tk.Frame(self.sidebar_canvas, bg=UI["panel"], width=404)
        self._sidebar_item = self.sidebar_canvas.create_window((0, 0), window=self.sidebar,
                                                              anchor="nw", width=404)
        self.sidebar.bind("<Configure>", self._on_sidebar_configure)
        # ★ 滚动容器自己的尺寸变了（拉窗口）也要重夹一次纵偏移，见那个函数的说明
        self.sidebar_canvas.bind("<Configure>", self.on_sidebar_canvas_configure)
        # ★ 滚轮绑在 root 上：tk 的事件沿 bindtags 往上走，绑在容器上收不到
        #   「指针停在某个输入框上」的滚轮（与地图编辑器同一个坑）。
        self.root.bind("<MouseWheel>", self._on_wheel, add="+")

    def _bind_keys(self) -> None:
        self.root.bind("<Control-s>", lambda e: self.do_save())
        self.root.bind("<Control-S>", lambda e: self.do_save())
        self.root.bind("<Control-z>", lambda e: self.do_undo())
        self.root.bind("<Control-Z>", lambda e: self.do_undo())
        self.root.bind("<Control-y>", lambda e: self.do_redo())
        self.root.bind("<Control-Y>", lambda e: self.do_redo())
        self.root.bind("<F5>", lambda e: self.do_reload())

    def _on_sidebar_configure(self, _event=None) -> None:
        """侧边栏内容尺寸变了 → 更新滚动范围（内容比窗口高时才滚得动）。"""
        try:
            self.sidebar_canvas.configure(scrollregion=self.sidebar_canvas.bbox("all"))
        except tk.TclError:
            return
        self.clamp_sidebar_view()

    # ------------------------------------------------------------------
    # 侧边栏滚动：唯一入口 + 夹值
    #
    # ★★ 这一段是用户报的「过度上下滑动、上方出现大量空白」的修法。
    #    根因是 Tk 的一个反直觉行为（实测 Tk 9.0，内容 713px / 视口 930px）：
    #
    #        canvas.yview("scroll", -5, "units")   →   canvasy(0) = **-217**
    #
    #    也就是「scrollregion 比视口矮」时 Tk **照样允许滚动**：内容被整个推下去，
    #    面板上方空出一大块 —— 而 `yview()` 这时还报 `(0.0, 1.0)`，
    #    光看 yview 是发现不了的（所以这里一律用 `canvasy(0)` 判断，别改回去）。
    #    滚轮 / 滚动条 / 拖动 / 窗口缩放都会走到下面这几个入口，所以修在入口上。
    # ------------------------------------------------------------------

    def sidebar_overflow(self) -> int:
        """内容比视口高出多少像素（<= 0 = 装得下，本来就不该滚）。"""
        try:
            box = self.sidebar_canvas.bbox("all")
            content = float(box[3] - box[1]) if box else float(self.sidebar.winfo_reqheight())
            viewport = float(self.sidebar_canvas.winfo_height())
        except tk.TclError:
            return 0
        return max(0, int(round(content - viewport)))

    def sidebar_yview(self, *args) -> None:
        """侧边栏**唯一**的滚动入口：滚动条 / 滚轮 / 拖动都走它。

        装得下 → 一律钉回顶部（什么都不做）；装不下 → 真滚，再把偏移夹回 [0, 溢出]。
        """
        overflow = self.sidebar_overflow()
        if overflow <= 0:
            self._pin_sidebar_top()
            return
        try:
            self.sidebar_canvas.yview(*args)
        except tk.TclError:
            return
        self.clamp_sidebar_view(overflow)

    def clamp_sidebar_view(self, overflow: Optional[int] = None) -> None:
        """把画布的**纵偏移**夹回 [0, 溢出]。

        ★ 判据是 `canvasy(0)`（视口顶端在画布坐标里的位置），**不是** `yview()` ——
          内容装得下时 yview 永远报 (0.0, 1.0)，而偏移可能是个负数（见上面那段实测）。
        """
        if overflow is None:
            overflow = self.sidebar_overflow()
        try:
            offset = self.sidebar_canvas.canvasy(0.0)
        except tk.TclError:
            return
        if overflow <= 0 or offset < 0.0:
            self._pin_sidebar_top()
        elif offset > float(overflow):
            # 滚过头 → 直接落到最底（分数是相对 scrollregion 总高的）
            total = max(1.0, float(self.sidebar.winfo_reqheight()))
            try:
                self.sidebar_canvas.yview_moveto(float(overflow) / total)
            except tk.TclError:
                pass

    def _pin_sidebar_top(self) -> None:
        """把侧边栏钉回顶部（装得下时「滚动条固定」就是这一句）。"""
        try:
            self.sidebar_canvas.yview_moveto(0.0)
            # 滑块铺满滑槽 = 看着就是「不可滚」；内容装得下时它就该一直是这个样子
            self.sidebar_scroll.set(0.0, 1.0)
        except tk.TclError:
            pass

    def on_sidebar_yscroll(self, first, last) -> None:
        """画布 → 滚动条的位置（装得下时固定成「满格」）。"""
        if self.sidebar_overflow() <= 0:
            self.sidebar_scroll.set(0.0, 1.0)
            return
        self.sidebar_scroll.set(first, last)

    def on_sidebar_canvas_configure(self, event) -> None:
        """滚动容器本身变了 → 内容宽度跟着容器走，顺便把纵偏移夹一次。

        ★ 为什么要夹：窗口被拉高之后，原先「滚到一半」的偏移可能已经越界
          （内容明明装得下了却还停在下面），表现出来就是上/下露出一块空白。
        """
        try:
            self.sidebar_canvas.itemconfigure(self._sidebar_item, width=event.width)
        except tk.TclError:
            return
        self.clamp_sidebar_view()

    def _on_wheel(self, event):
        """滚轮：指针在侧边栏里 → 滚侧边栏（走唯一的那个入口）；否则放行。"""
        if not self._in_sidebar(getattr(event, "widget", None)):
            return None
        delta = getattr(event, "delta", 0)
        if delta:
            self.sidebar_yview("scroll", -1 if delta > 0 else 1, "units")
            return "break"
        return None

    def _in_sidebar(self, widget) -> bool:
        node = widget
        while node is not None:
            if node is self.sidebar:
                return True
            node = getattr(node, "master", None)
        return False

    # ==================================================================
    # 状态与标题
    # ==================================================================

    def _path_text(self) -> str:
        if self.model.path is None:
            return "（还没有文件）"
        text = str(self.model.path)
        if self.project_dir is not None:
            try:
                return str(self.model.path.relative_to(self.project_dir))
            except ValueError:
                return text
        return text

    def update_title(self) -> None:
        mark = " *" if self.model.dirty else ""
        self.root.title("DAEEM 单位编辑器 —— %s%s" % (self.model.path.name
                                                     if self.model.path else "未命名", mark))
        self.file_label.configure(text=self._path_text() + ("　● 未保存" if self.model.dirty
                                                            else "　已保存"),
                                  fg=(UI["warn"] if self.model.dirty else UI["text_dim"]))

    def status(self, message: str, ok: Optional[bool] = None) -> None:
        self.status_var.set(message)
        del ok                                          # 颜色留给以后（现在统一文本色）

    # ==================================================================
    # 页签与列表
    # ==================================================================

    def set_page(self, key: str) -> None:
        if key == self.page:
            return
        self.page = key
        self.selection = None
        self.refresh_all()
        for k, _label, hint in PAGES:
            if k == key:
                self.status(hint)

    def refresh_all(self) -> None:
        self._rebuild_list()
        self._rebuild_sidebar()
        self.update_title()

    def _rebuild_list(self) -> None:
        for child in self.list_host.winfo_children():
            child.destroy()
        for child in self.action_bar.winfo_children():
            child.destroy()
        for key, btn in self.tab_buttons.items():
            btn.configure(fg=(UI["accent"] if key == self.page else UI["text_dim"]),
                          bg=(UI["panel_alt"] if key == self.page else UI["panel"]))
        self._suppress = True
        try:
            if self.page == "unit":
                self._build_unit_lists()
            elif self.page == "building":
                self._build_building_list()
            else:
                self._build_tech_list()
        finally:
            self._suppress = False
        self._select_current()

    # ---- 单位页：上面兵种、下面将领 -------------------------------------

    def _tree(self, parent, columns: List[Tuple[str, str, int]], height: int = 10):
        wrap = tk.Frame(parent, bg=UI["bg"])
        wrap.pack(fill="both", expand=True, padx=10, pady=(8, 0))
        tree = ttk.Treeview(wrap, columns=[c[0] for c in columns], show="tree headings",
                            height=height, selectmode="browse")
        tree.heading("#0", text="id")
        tree.column("#0", width=130, anchor="w", stretch=False)
        for key, label, width in columns:
            tree.heading(key, text=label)
            tree.column(key, width=width, anchor="e" if width <= 70 else "w", stretch=False)
        scroll = ttk.Scrollbar(wrap, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=scroll.set)
        tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        tree.bind("<<TreeviewSelect>>", self._on_list_select)
        return tree

    def _build_unit_lists(self) -> None:
        tk.Label(self.list_host, text="兵种", bg=UI["bg"], fg=UI["accent"], anchor="w",
                 font=("Microsoft YaHei UI", 10, "bold")).pack(fill="x", padx=10, pady=(8, 0))
        self.unit_tree = self._tree(self.list_host, UNIT_TREE_COLUMNS, height=9)
        self.unit_tree.tag_configure("builtin", foreground=UI["text"])
        for unit in self.model.units():
            cost = "%g / %g / %g" % (unit.cost_food, unit.cost_gold, unit.population_cost)
            if not unit.has_recruit:
                cost = "—（不在招募表）"
            self.unit_tree.insert("", "end", iid="u:" + unit.id, text=unit.id,
                                  values=(unit.icon_char, unit.name, unit.class_label,
                                          fmt(unit.hp_max), fmt(unit.damage), fmt(unit.range),
                                          fmt(unit.speed), fmt(unit.cooldown_sec),
                                          # ★ 视野：显示**实际生效值**（没写那个键的兵种
                                          #   吃 config 的 fog.vision_default）——
                                          #   免得一列 0 让人以为这些兵都是瞎子。
                                          fmt(unit.vision_effective), cost,
                                          fmt(unit.train_sec) if unit.has_recruit else "—"),
                                  tags=() if not unit.builtin else ("builtin",))

        tk.Label(self.list_host, text="将领（开局三位；也可以在这里单独给数值）",
                 bg=UI["bg"], fg=UI["accent"], anchor="w",
                 font=("Microsoft YaHei UI", 10, "bold")).pack(fill="x", padx=10, pady=(10, 0))
        self.general_tree = self._tree(self.list_host, [
            ("name", "名字", 100), ("type", "类型", 110), ("hp", "血量", 60),
            ("dmg", "攻击", 60), ("rng", "距离", 56), ("spd", "移速", 56),
            ("vis", "视野", 50),
            ("cost", "造价 粮/金/人口", 150), ("train", "招募秒", 64),
        ], height=4)
        for gen in self.model.generals():
            marked = "" if not gen.override else "（有单独数值）"
            self.general_tree.insert("", "end", iid="g:%d" % gen.index, text=gen.kind,
                                     values=(gen.name + marked, self._type_label(gen.type_id),
                                             fmt(gen.effective_of("hp_max")),
                                             fmt(gen.effective_of("damage")),
                                             fmt(gen.effective_of("range")),
                                             fmt(gen.effective_of("speed")),
                                             # ★ 视野：覆盖 ⊕ 所属兵种（与游戏侧
                                             #   cfg.general_vision_at 同一条口径）
                                             fmt(gen.effective_of("vision")),
                                             "%g / %g / %g" % (gen.cost_food, gen.cost_gold,
                                                               gen.population_cost),
                                             fmt(gen.train_sec)))

        # ---- 操作按钮
        bar = self.action_bar
        self._button(bar, "＋ 新建兵种…", self.do_new_unit, padx=12, pady=5).pack(side="left")
        self._button(bar, "删除选中的兵种", self.do_delete_unit, padx=12, pady=5,
                     bg="#5a2f2f", fg="#ffdede",
                     activebackground="#7a3d3d").pack(side="left", padx=6)
        tk.Label(bar, text="（开局三位将领不在这里增删）", bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left", padx=6)

    def _type_label(self, type_id: str) -> str:
        if not self.model.doc.has(["unit", "types", type_id]):
            return "%s（认不出来）" % type_id
        u = self.model.unit(type_id)
        return "%s（%s）" % (u.name, type_id)

    # ---- 建筑页 --------------------------------------------------------

    def _build_building_list(self) -> None:
        tk.Label(self.list_host, text="建筑", bg=UI["bg"], fg=UI["accent"], anchor="w",
                 font=("Microsoft YaHei UI", 10, "bold")).pack(fill="x", padx=10, pady=(8, 0))
        self.building_tree = self._tree(self.list_host, BUILDING_TREE_COLUMNS, height=14)
        for b in self.model.buildings():
            atk = "—"
            if b.attackable:
                atk = "%g / %g 格 / %gs" % (b.damage, b.range, b.cooldown)
            levels = "%d 级" % b.max_level if b.levels else "没有升级表"
            self.building_tree.insert("", "end", iid="b:" + b.id, text=b.id,
                                      values=(b.name, fmt(b.hp_max), atk,
                                              # ★ 视野：显示**实际生效值**（没写那个键的建筑
                                              #   吃 config 的 fog.vision_building）
                                              fmt(b.vision_effective), fmt(b.build_sec),
                                              levels, "是" if b.buildable else "否",
                                              "%g / %g" % (b.cost_food, b.cost_gold)))
        bar = self.action_bar
        self._button(bar, "＋ 新建建筑…", self.do_new_building, padx=12, pady=5).pack(side="left")
        self._button(bar, "删除选中的建筑", self.do_delete_building, padx=12, pady=5,
                     bg="#5a2f2f", fg="#ffdede",
                     activebackground="#7a3d3d").pack(side="left", padx=6)
        tk.Label(bar, text="（区划中心不是建筑：它是中立障碍，不在这里）", bg=UI["bg"],
                 fg=UI["text_dim"], font=("Microsoft YaHei UI", 8)).pack(side="left", padx=6)

    # ---- 科技页 --------------------------------------------------------

    def _build_tech_list(self) -> None:
        head = tk.Frame(self.list_host, bg=UI["bg"])
        head.pack(fill="x", padx=10, pady=(8, 0))
        tk.Label(head, text="科技", bg=UI["bg"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 10, "bold")).pack(side="left")
        tk.Label(head, text="　同一时间最多启用", bg=UI["bg"], fg=UI["text_dim"]).pack(side="left")
        self.max_active_var = tk.StringVar(value=str(self.model.max_active()))
        entry = ttk.Entry(head, textvariable=self.max_active_var, width=5)
        entry.pack(side="left", padx=4)
        entry.bind("<Return>", lambda e: self._commit_max_active())
        entry.bind("<FocusOut>", lambda e: self._commit_max_active())
        tk.Label(head, text="条（3×3 九格里的名额）", bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left")
        self.tech_tree = self._tree(self.list_host, [
            ("name", "名称", 130), ("line", "小字", 120), ("effect", "加成", 200),
        ], height=12)
        for tech in self.model.techs():
            self.tech_tree.insert("", "end", iid="t:%d" % tech.index, text=tech.id,
                                  values=(tech.name, tech.line, tech.effect_label))
        tk.Label(self.action_bar, text="这一版不支持新增 / 删除科技（需求：暂时不用）。",
                 bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left")

    # ---- 选中 ----------------------------------------------------------

    def _select_current(self) -> None:
        """把 tree 的选中恢复成 self.selection（重建列表之后调）。"""
        kind, key = (self.selection if self.selection else (None, None))
        tree: Optional[ttk.Treeview] = None
        iid = None
        if kind == "unit":
            tree, iid = getattr(self, "unit_tree", None), "u:" + str(key)
        elif kind == "general":
            tree, iid = getattr(self, "general_tree", None), "g:%d" % key
        elif kind == "building":
            tree, iid = getattr(self, "building_tree", None), "b:" + str(key)
        elif kind == "tech":
            tree, iid = getattr(self, "tech_tree", None), "t:%d" % key
        if tree is None or iid is None:
            self.selection = None
            return
        try:
            if not tree.exists(iid):
                self.selection = None
                return
            tree.selection_set(iid)
            tree.see(iid)
        except tk.TclError:
            # 列表刚才被整体重建过（旧控件已销毁）——这一帧不用恢复选中
            self.selection = None

    def _on_list_select(self, event=None) -> None:
        if self._suppress:
            return
        tree = event.widget if event is not None else None
        if tree is None:
            return
        picked = tree.selection()
        if not picked:
            return
        iid = picked[0]
        if iid.startswith("u:"):
            self.selection = ("unit", iid[2:])
        elif iid.startswith("g:"):
            self.selection = ("general", int(iid[2:]))
        elif iid.startswith("b:"):
            self.selection = ("building", iid[2:])
        elif iid.startswith("t:"):
            self.selection = ("tech", int(iid[2:]))
        self._rebuild_sidebar()

    # ==================================================================
    # 侧边栏
    # ==================================================================

    def _section(self, title: str, hint: str = "") -> tk.Frame:
        head = tk.Frame(self.sidebar, bg=UI["panel"])
        head.pack(fill="x", padx=10, pady=(12, 2))
        tk.Label(head, text=title, bg=UI["panel"], fg=UI["accent"], anchor="w",
                 font=("Microsoft YaHei UI", 10, "bold")).pack(side="left")
        if hint:
            tk.Label(head, text="　" + hint, bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     font=("Microsoft YaHei UI", 8)).pack(side="left")
        frame = tk.Frame(self.sidebar, bg=UI["panel"])
        frame.pack(fill="x", padx=10)
        # ★ 记下这一节叫什么。用途之一是**定位控件**：同一页里「血量倍率」会出现三次
        #   （1/2/3 级各一行），只按标签找永远找到第一级那一行 ——
        #   无头测试要的是「升到 2 级那一节里的血量倍率」（见 test_app.py 的 E_in）。
        frame.section_title = title
        return frame

    def _rebuild_sidebar(self) -> None:
        self._suppress = True
        try:
            for child in self.sidebar.winfo_children():
                child.destroy()
            if self.page == "unit":
                if not self.selection:
                    self._empty_hint("左边点一行：上面是兵种，下面是开局三位将领。")
                elif self.selection[0] == "unit":
                    self._build_unit_form(self.model.unit(self.selection[1]))
                else:
                    self._build_general_form(self.model.general(int(self.selection[1])))
            elif self.page == "building":
                if not self.selection:
                    self._empty_hint("左边点一个建筑；没有想要的就在下面「＋ 新建建筑」。")
                else:
                    self._build_building_form(self.model.building(self.selection[1]))
            else:
                if not self.selection:
                    self._empty_hint("左边点一条科技，改它的名字与加成数值。")
                else:
                    self._build_tech_form(self.model.tech(int(self.selection[1])))
            self.sidebar.update_idletasks()
            self.sidebar_canvas.configure(scrollregion=self.sidebar_canvas.bbox("all"))
            # ★ 换了内容/换了一个人 → 一律回到顶部；装不下的时候这也是「从头开始看」，
            #   装得下的时候它同时保证「滚动条固定在顶」（见 sidebar_yview 那一段）。
            self.sidebar_yview("moveto", 0.0)
        finally:
            self._suppress = False

    def _empty_hint(self, text: str) -> None:
        tk.Label(self.sidebar, text=text, bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                 justify="left", wraplength=370).pack(fill="x", padx=10, pady=12)

    # ---- 通用行构造 -----------------------------------------------------

    def _entry_row(self, parent, field: Field, value: Any,
                   commit: Callable[[Any], None], allow_empty: bool = False) -> tk.Frame:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        tk.Label(row, text=field.label, bg=UI["panel"], fg=UI["text"], width=13,
                 anchor="w").pack(side="left")
        var = tk.StringVar(value=value if isinstance(value, str) else fmt(value))
        entry = ttk.Entry(row, textvariable=var)
        entry.pack(side="left", fill="x", expand=True, padx=(4, 0))

        def do_commit(_event=None):
            self._commit_text(var, field, commit, entry, allow_empty)

        entry.bind("<Return>", do_commit)
        entry.bind("<FocusOut>", do_commit)
        # ★ 把绑的那个函数挂在控件上：无头测试没法真的发键盘事件
        #   （tk 只把键事件投给**有 OS 焦点**的窗口，实测 off-screen / withdraw 都收不到），
        #   存一份就能让测试走**同一个函数**，而不是另写一套「测试专用入口」。
        entry.commit_action = do_commit
        if field.hint:
            self._hint(parent, field.hint)
        return row

    def _commit_text(self, var: tk.StringVar, field: Field, commit: Callable[[Any], None],
                     entry, allow_empty: bool) -> None:
        if self._suppress or self._editing:
            return
        text = var.get().strip()
        if field.kind in ("int", "float"):
            # ★ 空框 = **不要这个键**（`None`）—— 只有明确允许为空的字段才认这条路。
            #   目前只有「视野半径」用得上：删掉键 = 回到 config 的 fog.vision_default
            #   （与 icon 清空 = 跟着名字第一个字是同一种语义）。
            if not text and allow_empty:
                value = None
                self._editing = True
                try:
                    if not self._mutate("「%s」改回默认" % field.label,
                                        lambda: commit(None)):
                        var.set(text)
                finally:
                    self._editing = False
                return
            number = parse_number(text)
            if number is None:
                self.status("✗ 「%s」要填一个数字，%r 不是 —— 原值没动" % (field.label, text))
                return
            value: Any = int(number) if field.kind == "int" else number
            clamped = field.clamp(value)
            if clamped != value:
                self.status("（「%s」被夹到 %s：只挡误输入，不做玩法判断）"
                            % (field.label, fmt(clamped)))
                value = clamped
        else:
            if not text and not allow_empty:
                self.status("✗ 「%s」不能空着 —— 原值没动" % field.label)
                return
            value = text
        self._editing = True
        try:
            if not self._mutate("%s → %s" % (field.label, value),
                                lambda: commit(value)):
                var.set(text)                        # 失败就把输入框恢复成原样
        finally:
            self._editing = False

    def _hint(self, parent, text: str) -> None:
        tk.Label(parent, text="　　" + text, bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                 justify="left", wraplength=380,
                 font=("Microsoft YaHei UI", 8)).pack(fill="x")

    def _bool_row(self, parent, field: Field, value: bool,
                  commit: Callable[[Any], None]) -> tk.Frame:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        var = tk.IntVar(value=1 if value else 0)
        chk = ttk.Checkbutton(row, text=field.label, variable=var,
                              command=lambda: self._mutate(
                                  "%s → %s" % (field.label, "是" if var.get() else "否"),
                                  lambda: commit(bool(var.get()))))
        chk.pack(side="left")
        if field.hint:
            self._hint(parent, field.hint)
        return row

    def _choice_row(self, parent, field: Field, value: str,
                    commit: Callable[[Any], None]) -> tk.Frame:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        tk.Label(row, text=field.label, bg=UI["panel"], fg=UI["text"], width=13,
                 anchor="w").pack(side="left")
        labels = {cid: label for cid, label in field.choices}
        current = labels.get(value, value)
        var = tk.StringVar(value=current)
        combo = ttk.Combobox(row, textvariable=var, state="readonly",
                             values=[label for _cid, label in field.choices])
        combo.pack(side="left", fill="x", expand=True, padx=(4, 0))
        by_label = {label: cid for cid, label in field.choices}

        def picked(_event=None):
            cid = by_label.get(var.get(), var.get())
            if cid == value:
                return
            if not self._mutate("%s → %s" % (field.label, var.get()), lambda: commit(cid)):
                var.set(current)

        combo.bind("<<ComboboxSelected>>", picked)
        if field.hint:
            self._hint(parent, field.hint)
        return row

    def _optional_row(self, parent, field: Field, value: float, inheriting: bool,
                      commit: Callable[[Any], None], clear: Optional[Callable[[], None]] = None,
                      inherited_text: str = "") -> tk.Frame:
        """「要么自己填、要么跟随别人」的一行（将领数值 / 升级后的攻击属性）。

        缺省时输入框**留着显示继承来的值但不可编辑** —— 设计师看得见「现在是多少」，
        而不是一行空白让人猜。
        """
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        tk.Label(row, text=field.label, bg=UI["panel"], fg=UI["text"], width=13,
                 anchor="w").pack(side="left")
        var = tk.StringVar(value=fmt(value))
        entry = ttk.Entry(row, textvariable=var)
        entry.pack(side="left", fill="x", expand=True, padx=(4, 4))
        entry.configure(state="disabled" if inheriting else "normal")

        def do_commit(_event=None):
            if inheriting:
                return
            self._commit_text(var, field, commit, entry, False)

        entry.bind("<Return>", do_commit)
        entry.bind("<FocusOut>", do_commit)
        entry.commit_action = do_commit                # 见 _entry_row 里的说明（测试直通）

        def toggle():
            if inheriting:
                self._mutate("把「%s」改成自己填" % field.label,
                             lambda: commit(parse_number(var.get()) or 0))
            else:
                if clear is None:
                    return
                self._mutate("「%s」改回跟随" % field.label, clear)

        self._button(row, "跟随" if not inheriting else "自定" if clear else "沿用",
                     toggle, padx=6, pady=1,
                     bg=(UI["panel_alt"] if not inheriting else "#2f5f7a"),
                     fg=(UI["text"] if not inheriting else "#eaf6ff"),
                     font=("Microsoft YaHei UI", 8)).pack(side="left")
        if inherited_text:
            self._hint(parent, inherited_text)
        return row

    # ---- 单位表单 -------------------------------------------------------

    def _build_unit_form(self, unit: Unit) -> None:
        head = self._section("单位　%s" % unit.id, "内置兵种" if unit.builtin else "自定义兵种")
        tk.Label(head, text=unit.id + ("　（代码与测试按这个 id 引用它，不能删）"
                                       if unit.builtin else ""),
                 bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                 font=("Microsoft YaHei UI", 9)).pack(fill="x")

        sec = self._section("数值")
        for field in UNIT_FIELDS:
            if field.key == "unit_class":
                choice = Field("unit_class", field.label, "choice", field.hint,
                               choices=tuple(self.model.class_choices()))
                self._choice_row(sec, choice, unit.unit_class,
                                 lambda v, u=unit: self.model.set_unit(u.id, "unit_class", v))
            elif field.key == "icon":
                # ★ 地图上那个字：一个普通文本框（不是下拉了 —— 本轮把「借一份线条预制体」
                #   换成了「填一个字」，见 model.ICON_HINT）。
                #   清空 = 删掉这个键 → 跟着**名字的第一个字**（列表里那一列就是生效值）。
                self._entry_row(sec, field, unit.icon,
                                lambda v, u=unit: self.model.set_unit(u.id, "icon", v),
                                allow_empty=True)
            elif field.kind == "bool":
                self._bool_row(sec, field, bool(unit.field(field.key)),
                               lambda v, u=unit, f=field: self.model.set_unit(u.id, f.key, v))
            elif field.key == "vision":
                # ★ 视野半径（战争迷雾）：显示的是**实际生效值** ——
                #   数据里写了 vision 就是它，没写就是 config 的 fog.vision_default
                #   （与游戏侧 cfg.unit_vision_of() 的兜底同一条规则）。
                #   清空输入框 = 删掉这个键 → 回到那个全局默认值。
                #   ⚠️ 这里**不再**多挂一行「没写就用 fog.vision_default」的提示：
                #      右栏是「装得下就不许滚」的（test_app.py 的 [8]），
                #      表单每高一截就有人的窗口装不下 —— 那句话说在字段的 hint 里就够。
                self._entry_row(sec, field, unit.vision_effective,
                                lambda v, u=unit: self.model.set_unit(u.id, "vision", v),
                                allow_empty=True)
            else:
                self._entry_row(sec, field, unit.field(field.key),
                                lambda v, u=unit, f=field: self.model.set_unit(u.id, f.key, v))

        # ---- 造价与招募（在 recruit.list 里）
        rsec = self._section("造价与招募", "recruit.list")
        if not unit.has_recruit:
            tk.Label(rsec, text="「%s」不在招募表里（它出现在地图上，但不是造出来的）。"
                                % unit.id, bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left", wraplength=380).pack(fill="x")
            self._button(rsec, "把它加进招募表（照默认值）",
                         lambda u=unit: self._do(lambda: self.model.add_recruit_entry(u.id),
                                                 "已把 %s 加进招募表" % u.id),
                         padx=8, pady=4).pack(fill="x", pady=4)
        else:
            for field in RECRUIT_FIELDS:
                self._entry_row(rsec, field, unit.field(field.key),
                                lambda v, u=unit, f=field: self.model.set_unit(u.id, f.key, v))
            tk.Label(rsec, text="　提示：改「名称」会连命令卡标题一起改（两处不一致看着像 bug）。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w", justify="left",
                     wraplength=380, font=("Microsoft YaHei UI", 8)).pack(fill="x")

        # ---- 危险操作
        if not unit.builtin:
            dsec = self._section("删除")
            self._button(dsec, "删掉这个兵种（连招募表那一项）", self.do_delete_unit,
                         padx=8, pady=4, bg="#5a2f2f", fg="#ffdede",
                         activebackground="#7a3d3d").pack(fill="x", pady=2)
            tk.Label(dsec, text="　正在用它的将领会被改成第一个还存在的兵种。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     font=("Microsoft YaHei UI", 8)).pack(fill="x")

    # ---- 将领表单 -------------------------------------------------------

    def _build_general_form(self, gen: General) -> None:
        self._section("将领 %d" % (gen.index + 1), gen.kind)
        sec = self._section("基本")
        row = tk.Frame(sec, bg=UI["panel"])
        row.pack(fill="x", pady=2)
        tk.Label(row, text="类型", bg=UI["panel"], fg=UI["text"], width=13,
                 anchor="w").pack(side="left")
        choices = [(u.id, "%s（%s）" % (u.name, u.id)) for u in self.model.units()]
        labels = {cid: label for cid, label in choices}
        var = tk.StringVar(value=labels.get(gen.type_id, gen.type_id))
        combo = ttk.Combobox(row, textvariable=var, state="readonly",
                             values=[label for _cid, label in choices])
        combo.pack(side="left", fill="x", expand=True, padx=(4, 0))
        by_label = {label: cid for cid, label in choices}

        def on_type(_event=None):
            cid = by_label.get(var.get(), var.get())
            self._mutate("将领 %d 的类型 → %s" % (gen.index + 1, cid),
                         lambda: self.model.set_general_type(gen.index, cid))

        combo.bind("<<ComboboxSelected>>", on_type)
        self._hint(sec, "类型决定它是步兵还是骑兵、近战还是远程 —— 与将领自己的数值无关。")

        self._entry_row(sec, Field("name", "名字", "text"), gen.name,
                        lambda v, g=gen: self.model.set_general(g.index, "name", v))

        # ---- 数值（跟随兵种 / 自己填）
        nsec = self._section("数值", "没改过的项跟着上面的类型走")
        for field in GENERAL_STAT_FIELDS:
            inheriting = gen.inherits(field.key)
            inherited = gen.inherited.get(field.key)
            self._optional_row(
                nsec, field, gen.effective_of(field.key), inheriting,
                commit=lambda v, g=gen, f=field: self.model.set_general_stat(g.index, f.key, v),
                clear=lambda g=gen, f=field: self.model.set_general_stat(g.index, f.key, None),
                inherited_text=("　跟随类型：%s（%s）" % (fmt(inherited), gen.type_id)
                                if inheriting else "　自己填的值（按「跟随」回到类型数值）"))
        # ★★ 「开局护卫数」这个输入框**已经删掉**（产品决策）：开局带几个附属兵不再由
        #    `config.json` 给一个全局缺省，只能在**战役编辑器的摆放页**里一个一个摆出来。
        #    ⚠️ 附属兵这个**玩法机制本身一个字没改**（将领带兵 / 点一个兵选整队 /
        #       招募 / 濒死集结 / 队伍列表都在），去掉的只是「开局白送几个」这个配置项。
        #    ★ 这行灰字是**有意留的**：用户就是被「在两个编辑器里改同一件事」坑过的。
        self._hint(nsec, "开局附属兵改在**战役编辑器的摆放页**里摆"
                         "（每个兵一个坐标、可指定属于哪个将领）—— 这里不再提供这个全局缺省。")

        # ---- 造价与招募（recruit.zone.list）
        rsec = self._section("造价与招募", "recruit.zone.list")
        for key, label in (("cost_food", "造价 · 粮食"), ("cost_gold", "造价 · 黄金"),
                           ("population_cost", "造价 · 人口"), ("train_sec", "招募时间")):
            field = Field(key, label, "float", minimum=0)
            self._entry_row(rsec, field, gen.field(key),
                            lambda v, g=gen, k=key: self.model.set_general(g.index, k, v))
        self._hint(rsec, "区划中心招将领时用的钱、人口与读条秒数（与兵种那套同一口径）。")

    # ---- 建筑表单 -------------------------------------------------------

    def _build_building_form(self, b: Building) -> None:
        self._section("建筑　%s" % b.id, "内置建筑" if b.builtin else "自定义建筑")
        sec = self._section("基本")
        for field in BUILDING_FIELDS:
            if field.key == "attackable":
                self._bool_row(sec, field, b.attackable,
                               lambda v, bb=b: self.model.set_building(bb.id, "attackable", v))
            elif field.key in ("name", "hotkey", "color", "desc"):
                self._entry_row(sec, field, b.field(field.key),
                                lambda v, bb=b, f=field: self.model.set_building(bb.id, f.key, v),
                                allow_empty=(field.key == "hotkey"))
            elif field.key == "buildable":
                self._bool_row(sec, field, b.buildable,
                               lambda v, bb=b: self.model.set_building(bb.id, "buildable", v))
            elif field.key in ("damage", "range", "cooldown") and not b.attackable:
                continue                        # 不能攻击就把那三行收起来
            elif field.key == "vision":
                # ★ 视野半径（战争迷雾）：显示的是**实际生效值** ——
                #   数据里写了 vision 就是它，没写就是 config 的 fog.vision_building
                #   （与游戏侧 cfg.building_vision_of() 的兜底同一条规则）。
                #   清空输入框 = 删掉这个键 → 回到那个全局默认值。
                #   ⚠️ 与兵种那一栏是同一条规则、同一段提示文字（VISION_HINT）。
                self._entry_row(sec, field, b.vision_effective,
                                lambda v, bb=b: self.model.set_building(bb.id, "vision", v),
                                allow_empty=True)
            else:
                self._entry_row(sec, field, b.field(field.key),
                                lambda v, bb=b, f=field: self.model.set_building(bb.id, f.key, v))
        if not b.attackable:
            self._hint(sec, "「可攻击」没打勾：攻击力 / 距离 / 速度那三行先收起来了"
                            "（数据还在文件里，勾上就能改）。")

        # ---- 升级表
        if not b.levels:
            lsec = self._section("升级", "还没有升级表")
            tk.Label(lsec, text="这个建筑没有 upgrade.levels 表：游戏里不能升级。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w", justify="left",
                     wraplength=380).pack(fill="x")
            self._button(lsec, "给它加一张 3 级升级表（照默认值）",
                         lambda bb=b: self._do(
                             lambda: self.model.doc.set(["upgrade", "levels", bb.id],
                                                        ConfigModel.default_levels()),
                             "已加升级表"), padx=8, pady=4).pack(fill="x", pady=4)
            return
        for level in b.levels:
            title = "升到 %d 级" % level.level if level.index > 0 else "1 级（开局就是它）"
            lsec = self._section(title, "" if level.index > 0 else "这一行只有血量倍率")
            if level.index == 0:
                for field in LEVEL_FIELDS:
                    if field.key == "hp_mult":
                        self._entry_row(lsec, field, level.hp_mult,
                                        lambda v, bb=b, i=level.index:
                                        self.model.set_level(bb.id, i, "hp_mult", v))
                self._level_hp_hint(lsec, b, level.hp_mult)
                continue
            for field in LEVEL_FIELDS:
                self._entry_row(lsec, field, level.field(field.key),
                                lambda v, bb=b, i=level.index, f=field:
                                self.model.set_level(bb.id, i, f.key, v))
            self._level_hp_hint(lsec, b, level.hp_mult)
            if b.attackable:
                tk.Label(lsec, text="　这一级的攻击（不填就沿用上面的基础值）",
                         bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                         font=("Microsoft YaHei UI", 8)).pack(fill="x", pady=(4, 0))
                for field in LEVEL_ATTACK_FIELDS:
                    has = level.has_attack(field.key)
                    self._optional_row(
                        lsec, field, level.attack_of(field.key), not has,
                        commit=lambda v, bb=b, i=level.index, f=field:
                        self.model.set_level(bb.id, i, f.key, v),
                        clear=lambda bb=b, i=level.index, f=field:
                        self.model.set_level(bb.id, i, f.key, None),
                        inherited_text=("　沿用基础值：%s" % fmt(level.base.get(field.key))
                                        if not has else "　这一级自己填的"))

    def _level_hp_hint(self, parent, b: Building, mult: float) -> None:
        self._hint(parent, "= 血量 %s × %s = **%s**" % (fmt(b.hp_max), fmt(mult),
                                                      fmt(b.hp_max * mult)))

    # ---- 科技表单 -------------------------------------------------------

    def _build_tech_form(self, tech: Tech) -> None:
        self._section("科技　%s" % tech.id)
        sec = self._section("文案")
        for field in TECH_FIELDS:
            self._entry_row(sec, field, tech.field(field.key),
                            lambda v, t=tech, f=field: self.model.set_tech(t.index, f.key, v))
        esec = self._section("属性加成", "填数字 = 有这条加成；清掉 = 这条加成不要了")
        for key, label, hint in TECH_EFFECTS:
            field = Field(key, label, "float", hint)
            value = tech.effect_value(key)
            if value is None:
                row = tk.Frame(esec, bg=UI["panel"])
                row.pack(fill="x", pady=2)
                tk.Label(row, text=label, bg=UI["panel"], fg=UI["text_dim"], width=13,
                         anchor="w").pack(side="left")
                var = tk.StringVar(value="")
                entry = ttk.Entry(row, textvariable=var)
                entry.pack(side="left", fill="x", expand=True, padx=(4, 0))
                tk.Label(row, text="（没有这条）", bg=UI["panel"], fg=UI["text_dim"],
                         font=("Microsoft YaHei UI", 8)).pack(side="left", padx=4)

                def add(_event=None, t=tech, k=key, v=var):
                    number = parse_number(v.get())
                    if number is None:
                        self.status("✗ %s 要填一个数字" % k)
                        return
                    self._mutate("加上加成 %s = %s" % (k, number),
                                 lambda: self.model.set_tech_effect(t.index, k, number))

                entry.bind("<Return>", add)
                entry.bind("<FocusOut>", add)
                entry.commit_action = add              # 见 _entry_row 里的说明（测试直通）
                self._hint(esec, hint)
            else:
                row = tk.Frame(esec, bg=UI["panel"])
                row.pack(fill="x", pady=2)
                tk.Label(row, text=label, bg=UI["panel"], fg=UI["text"], width=13,
                         anchor="w").pack(side="left")
                var = tk.StringVar(value=fmt(value))
                entry = ttk.Entry(row, textvariable=var)
                entry.pack(side="left", fill="x", expand=True, padx=(4, 4))

                def commit(_event=None, t=tech, k=key, v=var):
                    number = parse_number(v.get())
                    if number is None:
                        self.status("✗ %s 要填一个数字 —— 原值没动" % k)
                        return
                    self._mutate("%s → %s" % (k, number),
                                 lambda: self.model.set_tech_effect(t.index, k, number))

                entry.bind("<Return>", commit)
                entry.bind("<FocusOut>", commit)
                entry.commit_action = commit           # 见 _entry_row 里的说明（测试直通）
                self._button(row, "删掉这条", lambda t=tech, k=key: self._mutate(
                    "删掉加成 %s" % k,
                    lambda: self.model.set_tech_effect(t.index, k, None)),
                    padx=6, pady=1, bg="#5a2f2f", fg="#ffdede",
                    activebackground="#7a3d3d",
                    font=("Microsoft YaHei UI", 8)).pack(side="left")
                self._hint(esec, hint)
        self._hint(self.sidebar, "这一版不支持新增 / 删除科技（需求：暂时不用）。")

    # ==================================================================
    # 改动 / 撤销 / 保存
    # ==================================================================

    def _mutate(self, description: str, action: Callable[[], Any]) -> bool:
        """执行一次改动：失败不写坏数据，成功才压撤销栈。"""
        before = self.model.text
        try:
            action()
        except (ModelError, JsonError) as exc:
            self.status("✗ %s" % exc)
            return False
        except Exception as exc:                          # pragma: no cover - 兜底
            self.status("✗ 内部错误：%s" % exc)
            return False
        if self.model.text == before:
            self.status("（%s：值没变）" % description)
            return True
        self._undo.append(before)
        if len(self._undo) > UNDO_LIMIT:
            self._undo.pop(0)
        self._redo.clear()
        self.status("✓ %s" % description)
        self.refresh_all()
        return True

    def _do(self, action: Callable[[], Any], description: str) -> bool:
        """给「不经过输入框」的动作（新建 / 删除）用的糖。"""
        return self._mutate(description, action)

    def do_undo(self) -> None:
        if not self._undo:
            self.status("没有可撤销的改动")
            return
        self._redo.append(self.model.text)
        text = self._undo.pop()
        self.model.doc = model_mod.configfile.Doc(text)
        self.refresh_all()
        self.status("↶ 撤销一步（还剩 %d 步）" % len(self._undo))

    def do_redo(self) -> None:
        if not self._redo:
            self.status("没有可重做的改动")
            return
        self._undo.append(self.model.text)
        text = self._redo.pop()
        self.model.doc = model_mod.configfile.Doc(text)
        self.refresh_all()
        self.status("↷ 重做一步")

    def do_save(self) -> None:
        try:
            target = self.model.save()
        except (ModelError, OSError) as exc:
            self.status("✗ 保存失败：%s" % exc)
            messagebox.showerror("保存失败", str(exc))
            return
        self.status("✓ 已写回 %s" % target)
        self.refresh_all()

    def do_save_as(self) -> None:
        initial = str(self.model.path) if self.model.path else "config.json"
        path = filedialog.asksaveasfilename(title="另存为", initialfile=Path(initial).name,
                                            defaultextension=".json",
                                            filetypes=[("JSON", "*.json"), ("全部文件", "*.*")])
        if not path:
            return
        try:
            self.model.save(Path(path))
        except (ModelError, OSError) as exc:
            self.status("✗ 另存失败：%s" % exc)
            return
        self.status("✓ 另存到 %s（之后「保存」就写这里了）" % path)
        self.refresh_all()

    def do_reload(self) -> None:
        if self.model.dirty and not messagebox.askyesno(
                "重新载入", "现在有没保存的改动，丢掉它们、从磁盘重读？"):
            return
        try:
            self.model.reload()
        except ModelError as exc:
            self.status("✗ %s" % exc)
            return
        self._undo.clear()
        self._redo.clear()
        self.selection = None
        self.refresh_all()
        self.status("✓ 已从磁盘重读 %s" % self._path_text())

    # ---- 新建 / 删除 ----------------------------------------------------

    def do_new_unit(self) -> None:
        values = _ask_new_entry(self.root, "新建兵种", "兵种 id（英文小写）",
                                [(u.id, "%s（%s）" % (u.name, u.id)) for u in self.model.units()])
        if values is None:
            return
        new_id, name, template = values
        self._mutate("新建兵种 %s（照 %s 复制）" % (new_id, template),
                     lambda: self.model.add_unit(new_id, name, template))
        if self.model.doc.has(["unit", "types", new_id]):
            self.selection = ("unit", new_id)
            self.refresh_all()

    def do_delete_unit(self) -> None:
        if not self.selection or self.selection[0] != "unit":
            self.status("先在左边点一个兵种")
            return
        uid = self.selection[1]
        if not messagebox.askyesno("删除兵种", "删掉「%s」？（连招募表那一项一起删）" % uid):
            return
        if self._mutate("删除兵种 %s" % uid, lambda: self.model.remove_unit(uid)):
            self.selection = None
            self.refresh_all()

    def do_new_building(self) -> None:
        values = _ask_new_entry(self.root, "新建建筑", "建筑 id（英文小写）",
                                [(b.id, "%s（%s）" % (b.name, b.id))
                                 for b in self.model.buildings()])
        if values is None:
            return
        new_id, name, template = values
        self._mutate("新建建筑 %s（照 %s 复制，含升级表）" % (new_id, template),
                     lambda: self.model.add_building(new_id, name, template))
        if self.model.doc.has(["building", new_id]):
            self.selection = ("building", new_id)
            self.refresh_all()

    def do_delete_building(self) -> None:
        if not self.selection or self.selection[0] != "building":
            self.status("先在左边点一个建筑")
            return
        bid = self.selection[1]
        if not messagebox.askyesno("删除建筑", "删掉「%s」？（连它的升级表一起删）" % bid):
            return
        if self._mutate("删除建筑 %s" % bid, lambda: self.model.remove_building(bid)):
            self.selection = None
            self.refresh_all()

    def _commit_max_active(self) -> None:
        if self._suppress or self._editing:
            return
        value = parse_number(self.max_active_var.get())
        if value is None or int(value) < 1:
            self.status("✗ 「最多启用几条」要填一个 ≥ 1 的整数 —— 原值没动")
            self.max_active_var.set(str(self.model.max_active()))
            return
        if int(value) == self.model.max_active():
            return
        self._editing = True
        try:
            self._mutate("最多同时启用 %d 条科技" % int(value),
                         lambda: self.model.set_max_active(int(value)))
        finally:
            self._editing = False


# ======================================================================
# 小工具
# ======================================================================

class _NewEntryDialog:
    """「新建兵种 / 建筑」的小对话框：id + 名字 + 照谁复制。

    ★ 为什么要有「照谁复制」：兵种之间大部分数值是一样的，设计师的动线是
      「拿一个像的改几处」。而 id 必须自己起（它是存档 / 地图 JSON 里的键）。
    """

    def __init__(self, root: tk.Tk, title: str, id_label: str,
                 templates: List[Tuple[str, str]]) -> None:
        self.result: Optional[Tuple[str, str, str]] = None
        self.top = tk.Toplevel(root)
        self.top.title(title)
        self.top.configure(bg=UI["bg"])
        self.top.transient(root)
        self.top.resizable(False, False)
        body = tk.Frame(self.top, bg=UI["bg"])
        body.pack(fill="both", expand=True, padx=14, pady=12)

        tk.Label(body, text=id_label, bg=UI["bg"], fg=UI["text"], anchor="w").pack(fill="x")
        self.id_var = tk.StringVar(value="")
        entry = ttk.Entry(body, textvariable=self.id_var, width=34)
        entry.pack(fill="x", pady=(0, 8))

        tk.Label(body, text="名字（中文，显示在界面上）", bg=UI["bg"], fg=UI["text"],
                 anchor="w").pack(fill="x")
        self.name_var = tk.StringVar(value="")
        ttk.Entry(body, textvariable=self.name_var, width=34).pack(fill="x", pady=(0, 8))

        tk.Label(body, text="照谁复制（数值与排版都抄它）", bg=UI["bg"], fg=UI["text"],
                 anchor="w").pack(fill="x")
        self.tpl_var = tk.StringVar(value=templates[0][1] if templates else "")
        combo = ttk.Combobox(body, textvariable=self.tpl_var, state="readonly", width=32,
                             values=[label for _cid, label in templates])
        combo.pack(fill="x", pady=(0, 10))
        self._by_label = {label: cid for cid, label in templates}

        row = tk.Frame(body, bg=UI["bg"])
        row.pack(fill="x")
        tk.Button(row, text="取消", command=self._cancel, bg=UI["panel_alt"], fg=UI["text"],
                  relief="flat", takefocus=0, padx=12, pady=4).pack(side="right")
        tk.Button(row, text="创建", command=self._ok, bg="#2f5f7a", fg="#eaf6ff",
                  relief="flat", takefocus=0, padx=16, pady=4).pack(side="right", padx=6)
        entry.focus_set()
        self.top.bind("<Return>", lambda e: self._ok())
        self.top.bind("<Escape>", lambda e: self._cancel())
        self.top.grab_set()
        self.top.wait_window()

    def _ok(self) -> None:
        new_id = self.id_var.get().strip()
        name = self.name_var.get().strip()
        tpl = self._by_label.get(self.tpl_var.get(), "")
        if not new_id or not name:
            messagebox.showwarning("还差一点", "id 与名字都要填。", parent=self.top)
            return
        self.result = (new_id, name, tpl)
        self.top.destroy()

    def _cancel(self) -> None:
        self.result = None
        self.top.destroy()


def _ask_new_entry(root: tk.Tk, title: str, id_label: str,
                   templates: List[Tuple[str, str]]) -> Optional[Tuple[str, str, str]]:
    if not templates:
        messagebox.showwarning(title, "一个可以照抄的模板都没有，先检查配置文件。", parent=root)
        return None
    return _NewEntryDialog(root, title, id_label, templates).result


def run(config_path: Path, project_dir: Optional[Path] = None) -> int:
    """开窗口（`__main__.py` 与 bat 都走这里）。"""
    try:
        model = ConfigModel.load(config_path)
    except ModelError as exc:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror("打不开配置", str(exc))
        root.destroy()
        return 2
    root = tk.Tk()
    EditorApp(root, model, config_path, project_dir)
    root.mainloop()
    return 0
