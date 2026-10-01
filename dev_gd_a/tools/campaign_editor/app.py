"""app.py —— 战役编辑器的界面（tkinter，零依赖）。

布局（照 `unit_editor` / `map_editor` 那一套，用熟了就不用重新学）：

    ┌────────────────────────────────────────────────────────────┬──────────────┐
    │ [战役] [关卡] [阵营与AI] [摆放] [校验与导出]    保存 重新载入 │              │
    ├────────────────────────────────────────────────────────────┤   侧边栏      │
    │                                                            │  （可滚）     │
    │   画布 / 列表（随页签变）                                    │              │
    │                                                            │              │
    ├────────────────────────────────────────────────────────────┴──────────────┤
    │ 状态栏：当前战役 · 关卡 · 上一次操作的结果                                │
    └──────────────────────────────────────────────────────────────────────────┘

五个页签（dev_plan_7 6.2）：

    ① 战役    战役名 / 简介 / 默认模式 / 关卡顺序（上下箭头 + 增删关卡）
    ② 关卡    当前关的名字 / 模式 / 地图下拉 / 目标（区划 + 秒数）/ 额外失败条件
    ③ 阵营与AI 每一方一行：可玩 / 颜色 / 大本营 / AI 类型 / 资源倍率 / 开局资源 /
              进攻目标 / 「高级」AI 参数；玩家席位单独一栏
    ④ 摆放    画布（点一下放东西、右键删、【设进攻目标】模式）
    ⑤ 校验与导出 16+4 条逐条显示；有拦截就不许写文件；一键打开地图编辑器

★★ 界面上必须写清楚的那条分工（不是只写在 README 里）：
    「地形 / 区划 / 中心从地图读出来画成背景；要改地形请点『打开地图编辑器』」
    —— 见 `CANVAS_HINT`，它印在 ④ 摆放页的画布上方。

★ 「进攻目标」在 ③（下拉）与 ④（点画布）两处都能改，**底层是同一个字段**
  （`LevelModel.factions[i].attack_target`）——所以两边都走 `set_attack_target()`，
  改完统一 `_after_change()` 重建界面；这是最容易写出不一致的地方。

★ 画布手势照 `map_editor/app.py`：滚轮以光标为锚点缩放、中键（或空格）拖动平移、
  右键删除。唯一的有意差异是 **左键单击**：那边是「涂地形」，这边是「放东西 / 选中」。
"""

from __future__ import annotations

import subprocess
import sys
import tkinter as tk
from pathlib import Path
from tkinter import messagebox, simpledialog, ttk
from typing import Any, Callable, Dict, List, Optional, Sequence, Tuple

from . import levelfile
from . import model as model_mod
from .model import (
    AI_FACTION,
    AI_GENERAL,
    AI_KINDS,
    AI_NONE,
    FAIL_ZONE_LOST,
    MODE_COOP,
    MODE_SOLO,
    OBJ_HOLD_ZONE,
    SEV_BLOCK,
    SEV_WARN,
    TARGET_BASE,
    TARGET_BUILDING,
    TARGET_POINT,
    TARGET_ZONE,
    BuildingEntry,
    CampaignModel,
    ConfigInfo,
    FactionEntry,
    Issue,
    LevelModel,
    MapInfo,
    ModelError,
    UnitEntry,
    clean_number,
    fmt_sec,
    point_label,
    target_label,
)

#: 界面配色（与另两个编辑器同一套 —— 三个工具看起来是一家的）。
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
    "canvas_bg": "#17181a",
}

#: 五个页签：key → （按钮文字，状态栏提示）。
PAGES: Tuple[Tuple[str, str, str], ...] = (
    ("campaign", "战役", "战役页：名字 / 简介 / 默认模式 / 关卡顺序（上下箭头排、增删关卡）"),
    ("level", "关卡", "关卡页：当前关的名字 / 模式 / 地图 / 目标 / 额外失败条件"),
    ("factions", "阵营与AI", "阵营页：每一方的 AI 指派 / 资源 / 大本营 / 进攻目标；玩家席位单独一栏"),
    ("place", "摆放", "摆放页：画布上点一下放东西；右键删；滚轮缩放；中键拖动；「设进攻目标」模式"),
    ("check", "校验与导出", "校验页：跑 16 条硬拦截 + 4 条警告；有拦截时不许写文件"),
)

#: ★★ 分工说明（印在摆放页的画布上方，**不能只写在 README 里**）。
CANVAS_HINT = ("地形 / 区划 / 中心是从地图读出来画成**背景**的；要改地形、区划或中心，"
               "请点本页的『打开地图编辑器』。")

#: 1 格在 100% 缩放下的像素（与 map_editor 的 CELL_PX 同一量级）。
CELL_PX = 30.0
MIN_ZOOM = 0.35
MAX_ZOOM = 4.0
ZOOM_STEP = 1.12

#: 画布上的图元颜色。
C = {
    "grass": "#33422f",
    "forest": "#24402a",
    "mountain": "#4c4a45",
    "zone_line": "#5c6066",
    "center": "#ff8adf",
    "grid": "#2a2c30",
    "text": "#f0f0f0",
    "dim": "#9aa0a8",
    "select": "#ffffff",
    "objective": "#ffd166",
    "unit": "#8fd694",
    "building": "#c0a080",
    "base": "#5ac8ff",
    "arrow": "#ff6b6b",
}

#: 阵营配色的兜底（config 里没写这一方时用）。
FALLBACK_COLORS: Tuple[str, ...] = (
    "#ffd166", "#5ac8ff", "#8ce08c", "#c9a0ff", "#ffb0b0", "#ffd9a0", "#a0e8e0",
)

#: 画布上「这一方」用什么颜色（阵营 id → 固定色，保证同一次会话里稳定）。
_EPOCH_COLORS: Dict[str, str] = {}


class EditorApp:
    """战役编辑器主窗口。"""

    def __init__(self, root: tk.Tk, model: CampaignModel, project_dir: Any,
                 config: Optional[ConfigInfo] = None,
                 maps: Optional[Dict[str, MapInfo]] = None) -> None:
        self.root = root
        self.model = model
        self.project_dir = Path(project_dir)
        self.config = config if config is not None else levelfile.load_config(self.project_dir)
        self.maps: Dict[str, MapInfo] = (maps if maps is not None
                                         else levelfile.maps_by_id(self.project_dir))
        self.page = "campaign"
        #: 当前选中的关卡 id（切页签不丢）。
        self.current_level_id = model.levels[0].level_id if model.levels else ""
        #: 摆放页的画笔：("unit"|"general"|"building", 值) + 归属阵营。
        self.brush_kind = "unit"
        self.brush_value = (self.config.unit_types[0] if self.config.unit_types else "enemy")
        self.brush_faction = ""
        #: 摆放页选中的东西：("unit"|"building", 下标)。
        self.selection: Optional[Tuple[str, int]] = None
        #: 「设进攻目标」模式：选中的阵营 id（None = 不在这个模式里）。
        self.target_mode_faction: Optional[str] = None
        #: 画布视口（与 map_editor 同一套：zoom + ox/oy 像素偏移）。
        self.zoom = 1.0
        self.ox = 0.0
        self.oy = 0.0
        self._pan_anchor: Optional[Tuple[int, int]] = None
        self._space_held = False
        self.hover: Optional[Tuple[int, int]] = None
        self._redraw_job: Optional[str] = None
        #: ★★ 重建期间的**重入闸门**：重建控件时给 Treeview 调 `selection_set()` 会触发
        #:    `<<TreeviewSelect>>` → 回调 → `refresh_all()` → 再重建…… 实测直接死循环
        #:    （栈里能看到 `_on_entry_select → refresh_all → _rebuild_sidebar → update_idletasks`）。
        #:    所有「由选中触发」的回调都要先看这个标记。
        self._suppress = False
        #: ★★ 重建时**我们自己**设过的那一行（iid），与 `_on_entry_select` 收到的比对：
        #:    一样 = 这是重建的回声（Tk 的 `<<TreeviewSelect>>` 是**延迟**派发的，
        #:    `_suppress` 那时已经放开了，所以光靠闸门挡不住）→ 忽略；
        #:    不一样 = 真的是用户点了另一行 → 正常处理。
        #:    ★ 少了这一步的后果是**死循环**，实测直接把进程挂住。
        self._applied_entry_sel: Optional[str] = None
        self._applied_level_sel: Optional[str] = None
        #: 最近一次写盘的结果（测试与状态栏都读它）。
        self.last_written: List[str] = []
        self.last_issues: List[Issue] = []
        #: 启动地图编辑器的钩子（测试把它换成假的，别真起进程）。
        self.subprocess_mod: Any = subprocess

        self._setup_window()
        self._build_widgets()
        self._bind_keys()
        self.sync_faction_context()
        self.refresh_all()
        self.status("打开 %s　%s" % (self.model.campaign_id,
                                    "（%d 关）" % len(self.model.levels)))

    # ==================================================================
    # 窗口骨架
    # ==================================================================

    def _setup_window(self) -> None:
        self.root.title("DAEEM 战役编辑器")
        self.root.configure(bg=UI["bg"])
        self.root.geometry("1340x860")
        self.root.minsize(1060, 660)
        style = ttk.Style(self.root)
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure(".", background=UI["panel"], foreground=UI["text"],
                        fieldbackground=UI["panel_alt"], bordercolor=UI["line"],
                        lightcolor=UI["panel"], darkcolor=UI["panel"])
        style.configure("TFrame", background=UI["panel"])
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

    def _button(self, parent, text: str, command: Callable[[], None], **kw) -> tk.Button:
        """统一造按钮：一律 `takefocus=0`（否则空格会去「按」最后点过的按钮）。"""
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
        # ---- 顶栏：左页签 + 右文件按钮 ----
        top = tk.Frame(self.root, bg=UI["bg"])
        top.pack(side="top", fill="x")
        tk.Label(top, text="战役编辑器", bg=UI["bg"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 11, "bold")).pack(side="left", padx=(10, 14), pady=6)
        self.tab_buttons: Dict[str, tk.Button] = {}
        for key, label, _hint in PAGES:
            btn = self._button(top, label, lambda k=key: self.set_page(k),
                               bg=UI["panel"], fg=UI["text_dim"],
                               activebackground=UI["panel_alt"], activeforeground=UI["accent"],
                               font=("Microsoft YaHei UI", 10), padx=14, pady=5)
            btn.pack(side="left", padx=2)
            self.tab_buttons[key] = btn

        right = tk.Frame(top, bg=UI["bg"])
        right.pack(side="right", padx=8)
        self.file_label = tk.Label(right, text="", bg=UI["bg"], fg=UI["text_dim"],
                                   font=("Microsoft YaHei UI", 9))
        self.file_label.pack(side="left", padx=(0, 8))
        self.file_buttons: Dict[str, tk.Button] = {}
        for key, text, cmd in (("save", "保存", self.do_save),
                               ("reload", "重新载入", self.do_reload)):
            btn = self._button(right, text, cmd, padx=12, pady=5)
            btn.pack(side="left", padx=3)
            self.file_buttons[key] = btn
        self.file_buttons["save"].configure(bg="#2f5f7a", fg="#eaf6ff",
                                            activebackground="#3a7699")

        # ---- 主体：左工作区 + 右侧边栏 ----
        body = tk.Frame(self.root, bg=UI["bg"])
        body.pack(side="top", fill="both", expand=True)

        self.work = tk.Frame(body, bg=UI["bg"])
        self.work.pack(side="left", fill="both", expand=True)
        self.canvas_host = tk.Frame(self.work, bg=UI["bg"])
        self.list_host = tk.Frame(self.work, bg=UI["bg"])
        self.action_bar = tk.Frame(self.work, bg=UI["bg"])
        self.action_bar.pack(side="bottom", fill="x", padx=10, pady=(0, 8))

        self.status_var = tk.StringVar(value="")
        tk.Label(self.root, textvariable=self.status_var, anchor="w", bg=UI["panel"],
                 fg=UI["text_dim"], padx=10, pady=4,
                 font=("Microsoft YaHei UI", 9)).pack(side="bottom", fill="x")

        # ---- 侧边栏（可滚：「阵营与 AI」那一页很长）----
        side_wrap = tk.Frame(body, bg=UI["panel"], width=430)
        side_wrap.pack(side="right", fill="y")
        side_wrap.pack_propagate(False)
        self.sidebar_scroll = ttk.Scrollbar(side_wrap, orient="vertical",
                                            command=self.sidebar_yview)
        self.sidebar_canvas = tk.Canvas(side_wrap, bg=UI["panel"], width=414,
                                        highlightthickness=0, bd=0, takefocus=0,
                                        yscrollcommand=self.on_sidebar_yscroll)
        self.sidebar_scroll.pack(side="right", fill="y")
        self.sidebar_canvas.pack(side="left", fill="both", expand=True)
        self.sidebar = tk.Frame(self.sidebar_canvas, bg=UI["panel"], width=414)
        self._sidebar_item = self.sidebar_canvas.create_window((0, 0), window=self.sidebar,
                                                               anchor="nw", width=414)
        self.sidebar.bind("<Configure>", self._on_sidebar_configure)
        self.sidebar_canvas.bind("<Configure>", self.on_sidebar_canvas_configure)
        # ★ 滚轮绑在 root 上：tk 的事件沿 bindtags 往上走，绑在容器上收不到
        #   「指针停在某个输入框上」的滚轮（与另两个编辑器同一个坑）。
        self.root.bind("<MouseWheel>", self._on_wheel, add="+")

    def _bind_keys(self) -> None:
        self.root.bind("<Control-s>", lambda e: self.do_save())
        self.root.bind("<Control-S>", lambda e: self.do_save())
        self.root.bind("<F5>", lambda e: self.do_reload())
        self.root.bind("<Escape>", lambda e: self.on_escape())

    # ==================================================================
    # 侧边栏滚动：唯一入口 + 夹值（与 unit_editor 同一段实测坑）
    #
    # ★★ 为什么这么写：Tk 在「scrollregion 比视口矮」时**照样允许滚动**
    #    （实测 Tk 9.0：内容 713px / 视口 930px，`yview("scroll", -5)` 之后
    #     `canvasy(0)` = -217），表现就是面板上方空出一大块，而 `yview()` 还报 (0,1)。
    #    所以判据一律用 `canvasy(0)`，修法一律收敛到 `sidebar_yview()` 这一个入口。
    # ==================================================================

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
        """侧边栏**唯一**的滚动入口（滚动条 / 滚轮 / 拖动都走它）。"""
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
        if overflow is None:
            overflow = self.sidebar_overflow()
        try:
            offset = self.sidebar_canvas.canvasy(0.0)
        except tk.TclError:
            return
        if overflow <= 0 or offset < 0.0:
            self._pin_sidebar_top()
        elif offset > float(overflow):
            total = max(1.0, float(self.sidebar.winfo_reqheight()))
            try:
                self.sidebar_canvas.yview_moveto(float(overflow) / total)
            except tk.TclError:
                pass

    def _pin_sidebar_top(self) -> None:
        try:
            self.sidebar_canvas.yview_moveto(0.0)
            self.sidebar_scroll.set(0.0, 1.0)
        except tk.TclError:
            pass

    def on_sidebar_yscroll(self, first, last) -> None:
        if self.sidebar_overflow() <= 0:
            self.sidebar_scroll.set(0.0, 1.0)
            return
        self.sidebar_scroll.set(first, last)

    def _on_sidebar_configure(self, _event=None) -> None:
        try:
            self.sidebar_canvas.configure(scrollregion=self.sidebar_canvas.bbox("all"))
        except tk.TclError:
            return
        self.clamp_sidebar_view()

    def on_sidebar_canvas_configure(self, event) -> None:
        try:
            self.sidebar_canvas.itemconfigure(self._sidebar_item, width=event.width)
        except tk.TclError:
            return
        self.clamp_sidebar_view()

    def _in_sidebar(self, widget) -> bool:
        node = widget
        while node is not None:
            if node is self.sidebar:
                return True
            node = getattr(node, "master", None)
        return False

    def _on_wheel(self, event):
        """滚轮：指针在侧边栏里 → 滚侧边栏；在画布上 → 缩放（画布自己处理）。"""
        if not self._in_sidebar(getattr(event, "widget", None)):
            return None
        delta = getattr(event, "delta", 0)
        if delta:
            self.sidebar_yview("scroll", -1 if delta > 0 else 1, "units")
            return "break"
        return None

    # ==================================================================
    # 状态 / 标题
    # ==================================================================

    def status(self, message: str) -> None:
        self.status_var.set(message)

    def level(self) -> Optional[LevelModel]:
        return self.model.level(self.current_level_id)

    def set_current_level(self, level_id: str) -> None:
        if self.model.level(level_id) is None:
            return
        self.current_level_id = level_id
        self.selection = None
        self.target_mode_faction = None
        self.refresh_all()
        self.fit_view()

    def _path_text(self) -> str:
        if self.model.dir_path is None:
            return "（还没有目录）"
        try:
            return str(Path(self.model.dir_path).relative_to(self.project_dir))
        except ValueError:
            return str(self.model.dir_path)

    def update_title(self) -> None:
        self.root.title("DAEEM 战役编辑器 —— %s" % self.model.campaign_id)
        self.file_label.configure(text="%s　%d 关" % (self._path_text(), len(self.model.levels)),
                                  fg=UI["text_dim"])

    def map_info(self, map_id: Optional[str] = None) -> Optional[MapInfo]:
        mid = map_id if map_id is not None else (self.level().map_id if self.level() else "")
        return self.maps.get(str(mid))

    def faction_color(self, fid: str) -> str:
        """阵营颜色：战役 `factions[].color` → config 的配色表 → 兜底轮转。"""
        fid = str(fid)
        if not fid:
            return UI["text_dim"]
        color = self.model.faction_color(fid) or self.config.faction_color(fid)
        if color:
            return color
        if fid not in _EPOCH_COLORS:
            _EPOCH_COLORS[fid] = FALLBACK_COLORS[len(_EPOCH_COLORS) % len(FALLBACK_COLORS)]
        return _EPOCH_COLORS[fid]

    def all_faction_ids(self) -> List[str]:
        """界面上该列出的阵营 id：战役表 ∪ 本关在场（顺序稳定、去重）。"""
        out: List[str] = [str(e.get("id", "")) for e in self.model.factions if e.get("id")]
        lv = self.level()
        if lv is not None:
            for f in lv.present_ids():
                if f and f not in out:
                    out.append(f)
        info = self.map_info()
        if info is not None:
            for f in info.factions:
                fid = str(f.get("id", ""))
                if fid and fid not in out:
                    out.append(fid)
        return out

    def sync_faction_context(self) -> None:
        self.model.sync_context()
        if not self.current_level_id and self.model.levels:
            self.current_level_id = self.model.levels[0].level_id

    # ==================================================================
    # 页签 / 重画
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
        """整窗重建（数据变了就走它）。

        ★ 整块重建而不是「就地改值」：表单只有几十个控件，重建 ~10ms，
          换来「界面永远等于数据」——不用维护一堆控件与字段的对应关系。
        ★★ 重建期间必须把重入闸门关上（见 `self._suppress` 的说明）：不然
          `selection_set()` 触发的回调会再调一次 `refresh_all()`，直接死循环。
        """
        self._suppress = True
        try:
            self._rebuild_body()
            self._rebuild_sidebar()
            self.update_title()
        finally:
            self._suppress = False

    def _rebuild_body(self) -> None:
        for child in self.work.winfo_children():
            if child not in (self.canvas_host, self.list_host, self.action_bar):
                child.destroy()
        self.canvas_host.pack_forget()
        self.list_host.pack_forget()
        for key, btn in self.tab_buttons.items():
            btn.configure(fg=(UI["accent"] if key == self.page else UI["text_dim"]),
                          bg=(UI["panel_alt"] if key == self.page else UI["panel"]))
        if self.page in ("place",):
            self._build_canvas_page()
        elif self.page == "check":
            self._build_check_page()
        else:
            self._build_list_page()

    # ------------------------------------------------------------------
    # ① 战役 / ② 关卡：列表式页面
    # ------------------------------------------------------------------

    def _build_list_page(self) -> None:
        self.list_host.pack(side="top", fill="both", expand=True)
        for child in self.list_host.winfo_children():
            child.destroy()
        for child in self.action_bar.winfo_children():
            child.destroy()
        if self.page == "campaign":
            self._build_campaign_page()
        else:
            self._build_level_page()

    def _tree(self, parent, columns: Sequence[Tuple[str, str, int]], height: int = 12):
        wrap = tk.Frame(parent, bg=UI["bg"])
        wrap.pack(side="top", fill="both", expand=True, padx=10, pady=(8, 0))
        names = [c[0] for c in columns]
        tree = ttk.Treeview(wrap, columns=names, show="headings", height=height,
                            selectmode="browse")
        for key, header, width in columns:
            tree.heading(key, text=header)
            tree.column(key, width=width, anchor="w")
        tree.pack(side="left", fill="both", expand=True)
        bar = ttk.Scrollbar(wrap, orient="vertical", command=tree.yview)
        tree.configure(yscrollcommand=bar.set)
        bar.pack(side="right", fill="y")
        return tree

    def _build_campaign_page(self) -> None:
        self.level_tree = self._tree(self.list_host, (
            ("no", "序", 40), ("id", "关卡 id", 190), ("name", "名字", 210),
            ("mode", "模式", 80), ("map", "地图", 110), ("summary", "目标", 260),
            ("file", "文件", 240)))
        for i, lv in enumerate(self.model.levels):
            self.level_tree.insert("", "end", iid="lv:%s" % lv.level_id,
                                   values=(i + 1, lv.level_id, lv.name,
                                           "双人合作" if lv.mode == MODE_COOP else "单人",
                                           lv.map_id, lv.summary(),
                                           model_mod.level_file_of(lv)))
        if self.current_level_id and self.level_tree.exists("lv:%s" % self.current_level_id):
            self.level_tree.selection_set("lv:%s" % self.current_level_id)
            self._applied_level_sel = "lv:%s" % self.current_level_id
        self.level_tree.bind("<<TreeviewSelect>>", self._on_campaign_select)

        bar = self.action_bar
        self._button(bar, "▲ 上移", lambda: self.move_level(-1)).pack(side="left")
        self._button(bar, "▼ 下移", lambda: self.move_level(1)).pack(side="left", padx=4)
        self._button(bar, "＋ 新建关卡", self.do_new_level).pack(side="left", padx=(12, 4))
        self._button(bar, "－ 删除关卡", self.do_delete_level,
                     bg="#3a2b2b").pack(side="left", padx=4)
        tk.Label(bar, text="关卡顺序就是这里的顺序（上下箭头排）；levels[] 里的 file 相对战役目录",
                 bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left", padx=12)

    def _build_level_page(self) -> None:
        outer = tk.Frame(self.list_host, bg=UI["bg"])
        outer.pack(side="top", fill="both", expand=True, padx=10, pady=8)
        lv = self.level()
        if lv is None:
            tk.Label(outer, text="这个战役一关都没有：先到「战役」页新建一关。",
                     bg=UI["bg"], fg=UI["warn"]).pack(anchor="w")
            return

        tk.Label(outer, text="当前关：%s（%s）" % (lv.level_id, lv.name), bg=UI["bg"],
                 fg=UI["accent"], font=("Microsoft YaHei UI", 11, "bold")).pack(anchor="w")
        tk.Label(outer, text=lv.summary(), bg=UI["bg"], fg=UI["text_dim"]).pack(anchor="w",
                                                                               pady=(2, 8))

        box = tk.Frame(outer, bg=UI["panel"])
        box.pack(side="top", fill="both", expand=True)
        form = tk.Frame(box, bg=UI["panel"])
        form.pack(side="left", fill="y", padx=12, pady=10)

        self.lv_name_var = tk.StringVar(value=lv.name)
        self._form_row(form, "关卡名字", self.lv_name_var, self._commit_level_name)

        self.lv_mode_var = tk.StringVar(value=("双人合作" if lv.mode == MODE_COOP else "单人"))
        self._combo_row(form, "模式", self.lv_mode_var, ("单人", "双人合作"),
                        self._commit_level_mode)

        self.lv_map_var = tk.StringVar(value=self._map_label(lv.map_id))
        self._combo_row(form, "地图", self.lv_map_var,
                        tuple(self._map_label(m) for m in sorted(self.maps)),
                        self._commit_level_map)

        obj = lv.objective() or {}
        self.lv_obj_zone_var = tk.StringVar(value=self._zone_label(int(obj.get("zone", -1))))
        self._combo_row(form, "目标区划", self.lv_obj_zone_var, self._zone_choices(),
                        self._commit_objective_zone)
        self.lv_obj_sec_var = tk.StringVar(value=fmt_sec(float(obj.get("hold_sec", 0.0))))
        self._form_row(form, "守住秒数", self.lv_obj_sec_var, self._commit_objective_sec)

        tk.Label(form, text="额外失败条件（第一批只支持「指定区划失守」）", bg=UI["panel"],
                 fg=UI["text_dim"], font=("Microsoft YaHei UI", 9)).pack(anchor="w", pady=(12, 4))
        self.fail_tree = ttk.Treeview(form, columns=("kind", "zone"), show="headings",
                                      height=5, selectmode="browse")
        self.fail_tree.heading("kind", text="种类")
        self.fail_tree.heading("zone", text="区划")
        self.fail_tree.column("kind", width=120)
        self.fail_tree.column("zone", width=120)
        self.fail_tree.pack(side="top", fill="x")
        for i, f in enumerate(lv.fail_conditions):
            self.fail_tree.insert("", "end", iid="fail:%d" % i,
                                  values=(f.get("kind", ""), self._zone_label(int(f.get("zone", -1)))))
        self._button(form, "＋ 加一条「指定区划失守」", self.do_add_fail).pack(anchor="w",
                                                                          pady=(6, 2))
        self._button(form, "－ 删掉选中的一条", self.do_remove_fail,
                     bg="#3a2b2b").pack(anchor="w", pady=2)
        tk.Label(form, text="大本营被拆那条失败条件是**常开的**，不写在这里", bg=UI["panel"],
                 fg=UI["text_dim"], font=("Microsoft YaHei UI", 8)).pack(anchor="w", pady=(6, 0))

    def _form_row(self, parent, label: str, var: tk.StringVar,
                  commit: Callable[[], None]) -> None:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(side="top", fill="x", pady=3)
        tk.Label(row, text=label, width=12, anchor="w", bg=UI["panel"],
                 fg=UI["text"]).pack(side="left")
        entry = ttk.Entry(row, textvariable=var, width=26)
        entry.pack(side="left")
        entry.commit_action = commit                # type: ignore[attr-defined]
        entry.bind("<Return>", lambda e: commit())
        entry.bind("<FocusOut>", lambda e: commit())
        return None

    def _combo_row(self, parent, label: str, var: tk.StringVar,
                   choices: Sequence[str], commit: Callable[[], None]) -> ttk.Combobox:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(side="top", fill="x", pady=3)
        tk.Label(row, text=label, width=12, anchor="w", bg=UI["panel"],
                 fg=UI["text"]).pack(side="left")
        combo = ttk.Combobox(row, textvariable=var, values=list(choices), width=24,
                             state="readonly")
        combo.pack(side="left")
        combo.commit_action = commit                # type: ignore[attr-defined]
        combo.bind("<<ComboboxSelected>>", lambda e: commit())
        return combo

    def _map_label(self, map_id: str) -> str:
        info = self.maps.get(str(map_id))
        if info is None:
            return "%s（不存在）" % (map_id or "—")
        marks = []
        if info.hidden:
            marks.append("仅战役")
        if info.placeholder:
            marks.append("占位")
        return "%s%s" % (info.map_id, "（%s）" % "、".join(marks) if marks else "")

    def _map_id_from_label(self, label: str) -> str:
        return str(label).split("（")[0].strip()

    def _zone_choices(self) -> Tuple[str, ...]:
        info = self.map_info()
        if info is None:
            return ("—",)
        out = ["（不写）"]
        for zid in info.zone_ids:
            out.append(info.zone_label(zid))
        return tuple(out)

    def _zone_label(self, zid: int) -> str:
        info = self.map_info()
        if int(zid) < 0:
            return "（不写）"
        return info.zone_label(zid) if info is not None else model_mod.zone_label(zid)

    def _zone_id_from_label(self, label: str) -> int:
        info = self.map_info()
        text = str(label).strip()
        if not text or text.startswith("（不写"):
            return -1
        for zid in (info.zone_ids if info is not None else []):
            if (info.zone_label(zid) if info else "") == text:
                return int(zid)
        # 用户直接敲了 `c3` / `3` 这种写法也认
        tail = text.split("（")[0].strip()
        if tail.startswith("c") and tail[1:].isdigit():
            return int(tail[1:])
        if tail.isdigit():
            return int(tail)
        return -1

    # ==================================================================
    # ④ 摆放页：画布
    # ==================================================================

    def _build_canvas_page(self) -> None:
        self.canvas_host.pack(side="top", fill="both", expand=True)
        for child in self.canvas_host.winfo_children():
            child.destroy()
        for child in self.action_bar.winfo_children():
            child.destroy()

        head = tk.Frame(self.canvas_host, bg=UI["bg"])
        head.pack(side="top", fill="x", padx=10, pady=(6, 2))
        tk.Label(head, text=CANVAS_HINT, bg=UI["bg"], fg=UI["warn"], justify="left",
                 font=("Microsoft YaHei UI", 9)).pack(side="left")
        self._button(head, "打开地图编辑器", self.open_map_editor,
                     padx=10).pack(side="right")

        self.canvas = tk.Canvas(self.canvas_host, bg=UI["canvas_bg"], highlightthickness=0,
                                bd=0, takefocus=1)
        self.canvas.pack(side="top", fill="both", expand=True, padx=10, pady=(2, 4))
        self.canvas.bind("<Button-1>", self.on_left_click)
        self.canvas.bind("<Button-3>", self.on_right_click)
        self.canvas.bind("<Button-2>", self.on_middle_down)
        self.canvas.bind("<B2-Motion>", self.on_middle_drag)
        self.canvas.bind("<ButtonRelease-2>", self.on_middle_up)
        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<Leave>", self.on_leave)
        self.canvas.bind("<MouseWheel>", self.on_wheel)

        bar = self.action_bar
        tk.Label(bar, text="缩放", bg=UI["bg"], fg=UI["text_dim"]).pack(side="left")
        self._button(bar, "－", lambda: self.zoom_by(1 / ZOOM_STEP)).pack(side="left", padx=2)
        self._button(bar, "＋", lambda: self.zoom_by(ZOOM_STEP)).pack(side="left", padx=2)
        self._button(bar, "适应视图", self.fit_view).pack(side="left", padx=6)
        self.target_button = self._button(bar, "设进攻目标…", self.do_target_mode,
                                          bg="#3a3220", fg=UI["warn"])
        self.target_button.pack(side="left", padx=10)
        tk.Label(bar, text="左键放 / 选　右键删（大本营不在这里删）　中键拖动　滚轮缩放　Esc 退出目标模式",
                 bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left", padx=10)

        self.canvas.update_idletasks()
        self.fit_view()

    # ---- 坐标换算（与 map_editor 同一套：1 格 = CELL_PX × zoom 像素）----

    def tile_px(self) -> float:
        return CELL_PX * self.zoom

    def cell_origin(self, x: float, y: float) -> Tuple[float, float]:
        size = self.tile_px()
        return (self.ox + x * size, self.oy + y * size)

    def screen_to_cell(self, sx: float, sy: float) -> Tuple[int, int]:
        size = self.tile_px()
        return (int((sx - self.ox) // size), int((sy - self.oy) // size))

    def center_on(self, cx: float, cy: float) -> None:
        if not hasattr(self, "canvas"):
            return
        size = self.tile_px()
        cw = max(200, self.canvas.winfo_width())
        ch = max(200, self.canvas.winfo_height())
        self.ox = cw / 2 - cx * size
        self.oy = ch / 2 - cy * size

    def fit_view(self) -> None:
        """把整张地图放进视口正中。"""
        info = self.map_info()
        if info is None or not hasattr(self, "canvas"):
            return
        cw = max(200, self.canvas.winfo_width())
        ch = max(200, self.canvas.winfo_height())
        self.zoom = max(MIN_ZOOM, min(MAX_ZOOM,
                                      min((cw - 24) / max(1.0, info.cols * CELL_PX),
                                          (ch - 24) / max(1.0, info.rows * CELL_PX))))
        self.center_on(info.cols / 2.0, info.rows / 2.0)
        self.request_redraw()

    def zoom_by(self, factor: float, anchor: Optional[Tuple[float, float]] = None) -> None:
        """缩放；`anchor` 是**光标位置**（给了就以它为锚点，光标底下那一点不动）。"""
        if not hasattr(self, "canvas"):
            return
        new_zoom = max(MIN_ZOOM, min(MAX_ZOOM, self.zoom * factor))
        if abs(new_zoom - self.zoom) < 1e-9:
            return
        if anchor is None:
            anchor = (self.canvas.winfo_width() / 2.0, self.canvas.winfo_height() / 2.0)
        mx, my = anchor
        gx = (mx - self.ox) / self.zoom
        gy = (my - self.oy) / self.zoom
        self.zoom = new_zoom
        self.ox = mx - gx * self.zoom
        self.oy = my - gy * self.zoom
        self.request_redraw()

    def on_wheel(self, event, delta: Optional[int] = None):
        step = delta if delta is not None else getattr(event, "delta", 0)
        if not step:
            return None
        self.zoom_by(ZOOM_STEP if step > 0 else 1 / ZOOM_STEP,
                     (getattr(event, "x", 0), getattr(event, "y", 0)))
        return "break"

    def request_redraw(self) -> None:
        """合并同一帧里的多次重画请求（鼠标一秒能发上百个事件）。"""
        if self._redraw_job is not None:
            return
        try:
            self._redraw_job = self.root.after(16, self.redraw)
        except tk.TclError:
            self._redraw_job = None

    def redraw(self) -> None:
        self._redraw_job = None
        if not hasattr(self, "canvas") or self.page != "place":
            return
        try:
            self.canvas.delete("all")
        except tk.TclError:
            return
        info = self.map_info()
        lv = self.level()
        size = self.tile_px()
        cw = max(1, self.canvas.winfo_width())
        ch = max(1, self.canvas.winfo_height())

        if info is None:
            self.canvas.create_text(cw / 2, ch / 2, fill=UI["warn"],
                                    text="这一关还没有地图（或地图不存在）：去「关卡」页选一张")
            return

        # ---- 背景：地形（只画视野里的那些格）----
        x0 = max(0, int((0 - self.ox) // size) - 1)
        y0 = max(0, int((0 - self.oy) // size) - 1)
        x1 = min(info.cols - 1, int((cw - self.ox) // size) + 1)
        y1 = min(info.rows - 1, int((ch - self.oy) // size) + 1)
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                sx, sy = self.cell_origin(x, y)
                if not info.tile_exists(x, y):
                    continue
                terrain = info.terrain_at(x, y)
                fill = {".": C["grass"], "^": C["forest"], "#": C["mountain"]}.get(terrain,
                                                                                  C["grass"])
                self.canvas.create_rectangle(sx, sy, sx + size, sy + size,
                                             fill=fill, outline=C["grid"])

        # ---- 区划线 + 区划名字（区划是背景信息，改了它要去地图编辑器）----
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                zid = info.zone_of(x, y)
                if zid < 0:
                    continue
                sx, sy = self.cell_origin(x, y)
                if x + 1 < info.cols and info.zone_of(x + 1, y) != zid:
                    self.canvas.create_line(sx + size, sy, sx + size, sy + size,
                                            fill=C["zone_line"], width=2)
                if y + 1 < info.rows and info.zone_of(x, y + 1) != zid:
                    self.canvas.create_line(sx, sy + size, sx + size, sy + size,
                                            fill=C["zone_line"], width=2)
        if size >= 22:
            for zid in info.zone_ids:
                label = info.zone_name(zid)
                if not label:
                    continue
                # 区划名字画在它的中心格上（没有中心就不画）
                center = info.zone_centers.get(zid)
                if center is None:
                    continue
                cx, cy = center
                sx, sy = self.cell_origin(cx, cy)
                self.canvas.create_text(sx + size / 2, sy + size * 0.2, text=label,
                                        fill=C["dim"], font=("Microsoft YaHei UI", 8))

        # ---- 目标区划高亮 ----
        if lv is not None:
            oz = lv.objective_zone()
            if oz >= 0:
                for y in range(y0, y1 + 1):
                    for x in range(x0, x1 + 1):
                        if info.zone_of(x, y) == oz:
                            sx, sy = self.cell_origin(x, y)
                            self.canvas.create_rectangle(sx + 1, sy + 1, sx + size - 1,
                                                         sy + size - 1,
                                                         outline=C["objective"], width=2)

        # ---- 区划中心（小十字）----
        for zid, center in sorted(info.zone_centers.items()):
            sx, sy = self.cell_origin(center[0], center[1])
            self.canvas.create_line(sx + 2, sy + 2, sx + size - 2, sy + size - 2,
                                    fill=C["center"])
            self.canvas.create_line(sx + size - 2, sy + 2, sx + 2, sy + size - 2,
                                    fill=C["center"])

        # ---- 大本营（地图自带的 + 关卡覆盖的）----
        bases: Dict[str, Tuple[int, int]] = dict(info.faction_bases)
        if lv is not None:
            for p in lv.players:
                if p.get("base") is not None:
                    bases[str(p.get("faction", ""))] = p["base"]
            for e in lv.factions:
                if e.base is not None:
                    bases[e.fid] = e.base
        for fid, point in bases.items():
            sx, sy = self.cell_origin(point[0], point[1])
            self.canvas.create_rectangle(sx + 2, sy + 2, sx + size - 2, sy + size - 2,
                                         fill=self.faction_color(fid), outline="")
            self.canvas.create_text(sx + size / 2, sy + size / 2, text="家",
                                    fill="#101010", font=("Microsoft YaHei UI", 8, "bold"))

        # ---- 摆放的建筑 / 单位 ----
        if lv is not None:
            for i, b in enumerate(lv.start_buildings):
                self._draw_cell_marker(b.point(), "建", self.faction_color(b.owner),
                                       ("building", i))
            for i, u in enumerate(lv.start_units):
                self._draw_cell_marker(u.point(), "将" if u.is_general() else "兵",
                                       self.faction_color(u.faction), ("unit", i))

        # ---- 进攻目标的箭头 ----
        if lv is not None:
            for e in lv.factions:
                if e.attack_target is None:
                    continue
                src = self._base_point(lv, info, e.fid)
                dst = self._target_point(lv, info, e.attack_target)
                if src is None or dst is None:
                    continue
                sx, sy = self.cell_origin(src[0] + 0.5, src[1] + 0.5)
                tx, ty = self.cell_origin(dst[0] + 0.5, dst[1] + 0.5)
                self.canvas.create_line(sx, sy, tx, ty, fill=C["arrow"], width=2,
                                        arrow="last", dash=(4, 3))

        # ---- 悬停格 ----
        if self.hover is not None:
            hx, hy = self.hover
            sx, sy = self.cell_origin(hx, hy)
            self.canvas.create_rectangle(sx, sy, sx + size, sy + size,
                                         outline=C["select"], width=2)

        self.canvas.create_text(8, 8, anchor="nw", fill=UI["text_dim"],
                                text="%s　缩放 %.0f%%" % (info.map_id, self.zoom * 100),
                                font=("Microsoft YaHei UI", 8))

    def _draw_cell_marker(self, point: Tuple[int, int], glyph: str, color: str,
                          tag: Tuple[str, int]) -> None:
        size = self.tile_px()
        sx, sy = self.cell_origin(point[0], point[1])
        pad = max(2.0, size * 0.16)
        self.canvas.create_oval(sx + pad, sy + pad, sx + size - pad, sy + size - pad,
                                fill=color, outline="")
        self.canvas.create_text(sx + size / 2, sy + size / 2, text=glyph, fill="#101010",
                                font=("Microsoft YaHei UI", max(7, int(size * 0.3)), "bold"))
        if self.selection == tag:
            self.canvas.create_rectangle(sx + 1, sy + 1, sx + size - 1, sy + size - 1,
                                         outline=C["select"], width=2)

    def _base_point(self, lv: LevelModel, info: MapInfo,
                    fid: str) -> Optional[Tuple[int, int]]:
        e = lv.faction(fid)
        if e is not None and e.base is not None:
            return e.base
        for p in lv.players:
            if str(p.get("faction", "")) == fid and p.get("base") is not None:
                return p["base"]
        return info.faction_base(fid)

    def _target_point(self, lv: LevelModel, info: MapInfo,
                      spec: dict) -> Optional[Tuple[int, int]]:
        kind = str(spec.get("kind", ""))
        if kind == TARGET_ZONE:
            return info.zone_centers.get(int(spec.get("zone", -1)))
        if kind in (TARGET_POINT, TARGET_BUILDING):
            return (int(spec.get("x", -1)), int(spec.get("y", -1)))
        if kind == TARGET_BASE:
            return self._base_point(lv, info, str(spec.get("faction", "")))
        return None

    # ---- 画布事件 ----

    def on_motion(self, event) -> None:
        cell = self.screen_to_cell(event.x, event.y)
        self.hover = cell
        self.update_status(cell)
        self.request_redraw()

    def on_leave(self, _event=None) -> None:
        self.hover = None
        self.request_redraw()

    def on_middle_down(self, event) -> None:
        self._pan_anchor = (event.x, event.y)

    def on_middle_drag(self, event) -> None:
        if self._pan_anchor is None:
            self._pan_anchor = (event.x, event.y)
            return
        self.ox += event.x - self._pan_anchor[0]
        self.oy += event.y - self._pan_anchor[1]
        self._pan_anchor = (event.x, event.y)
        self.request_redraw()

    def on_middle_up(self, _event=None) -> None:
        self._pan_anchor = None

    def on_escape(self) -> None:
        if self.target_mode_faction is not None:
            self.target_mode_faction = None
            self.status("已退出「设进攻目标」模式")
            self.refresh_all()
        elif self.selection is not None:
            self.selection = None
            self.refresh_all()

    def do_target_mode(self) -> None:
        """进入「设进攻目标」模式：先选一方（取当前摆放归属那一方）。"""
        if self.page != "place":
            self.set_page("place")
        lv = self.level()
        if lv is None:
            return
        candidates = [e.fid for e in lv.factions] or self.all_faction_ids()
        if not candidates:
            self.status("没有可选的阵营：先到「阵营与AI」页加一方")
            return
        pick = self.brush_faction if self.brush_faction in candidates else candidates[0]
        self.target_mode_faction = pick
        self.status("「设进攻目标」模式：选中「%s」—— 点区划 = zone 目标，点空格 = point 目标，Esc 退出"
                    % pick)
        self.refresh_all()

    def on_left_click(self, event) -> None:
        if self.page != "place":
            return
        cell = self.screen_to_cell(event.x, event.y)
        if self._space_held:
            self._pan_anchor = (event.x, event.y)
            return
        if self.target_mode_faction is not None:
            self._click_target(cell)
            return
        info = self.map_info()
        lv = self.level()
        if lv is None:
            return
        hit = self._hit_test(cell)
        if hit is not None:
            self.selection = hit
            self.refresh_all()
            self.status("选中 %s" % self._selection_text())
            return
        if info is None or not info.tile_exists(cell[0], cell[1]) \
                or not info.walkable_at(cell[0], cell[1]):
            self.status("(%d,%d) 不能放东西：地图外或山地" % cell)
            return
        self.place_at(cell)

    def on_right_click(self, event) -> None:
        if self.page != "place":
            return
        cell = self.screen_to_cell(event.x, event.y)
        hit = self._hit_test(cell)
        if hit is None:
            self.status("(%d,%d) 上没有可删的东西（大本营在「阵营与AI」页里改）" % cell)
            return
        self.delete_entry(hit)

    def _hit_test(self, cell: Tuple[int, int]) -> Optional[Tuple[str, int]]:
        lv = self.level()
        if lv is None:
            return None
        for i, u in enumerate(lv.start_units):
            if u.point() == cell:
                return ("unit", i)
        for i, b in enumerate(lv.start_buildings):
            if b.point() == cell:
                return ("building", i)
        return None

    def _selection_text(self) -> str:
        lv = self.level()
        if lv is None or self.selection is None:
            return "（没有选中）"
        kind, index = self.selection
        if kind == "unit" and index < len(lv.start_units):
            u = lv.start_units[index]
            return "单位 %s/%s (%d,%d)" % (u.faction, u.kind, u.x, u.y)
        if kind == "building" and index < len(lv.start_buildings):
            b = lv.start_buildings[index]
            return "建筑 %s/%s (%d,%d)" % (b.owner, b.type, b.x, b.y)
        return "（选中已失效）"

    def _click_target(self, cell: Tuple[int, int]) -> None:
        """「设进攻目标」：点区划 → zone；点空格 → point。"""
        lv = self.level()
        info = self.map_info()
        fid = self.target_mode_faction
        if lv is None or info is None or fid is None:
            return
        zid = info.zone_of(cell[0], cell[1])
        if zid >= 0 and (cell == info.zone_centers.get(zid)
                         or info.terrain_at(*cell) != "#"):
            # ★ 有区划的格子按「指定区划」处理；这正是 6.3 那条手势
            #   （点区划 → zone 目标 / 点空格 → point 目标）。
            self.set_attack_target(fid, {"kind": TARGET_ZONE, "zone": int(zid)})
            self.status("「%s」的进攻目标 = 指定区划 %s" % (fid, info.zone_label(zid)))
        else:
            self.set_attack_target(fid, {"kind": TARGET_POINT, "x": cell[0], "y": cell[1]})
            self.status("「%s」的进攻目标 = 指定格 (%d,%d)" % (fid, cell[0], cell[1]))

    def update_status(self, cell: Optional[Tuple[int, int]]) -> None:
        if cell is None:
            return
        info = self.map_info()
        lv = self.level()
        x, y = cell
        if info is None:
            self.status("(%d,%d)" % cell)
            return
        zid = info.zone_of(x, y)
        terrain = {".": "草地", "^": "森林", "#": "山地"}.get(info.terrain_at(x, y), "?")
        what: List[str] = []
        if lv is not None:
            for u in lv.start_units:
                if u.point() == cell:
                    what.append("单位 %s/%s" % (u.faction, u.kind))
            for b in lv.start_buildings:
                if b.point() == cell:
                    what.append("建筑 %s/%s" % (b.owner, b.type))
        for fid, point in info.faction_bases.items():
            if tuple(point) == cell:
                what.append("%s 的大本营（地图）" % fid)
        if lv is not None:
            for e in lv.factions:
                if e.base == cell:
                    what.append("%s 的大本营（关卡）" % e.fid)
        self.status("(%d,%d)　地形 %s　%s　%s"
                    % (x, y, terrain,
                       ("区划 %s" % info.zone_label(zid)) if zid >= 0 else "不属于任何区划",
                       "　".join(what) if what else "（空的）"))

    # ---- 放置 / 删除 / 选中改字段 ----

    def place_at(self, cell: Tuple[int, int]) -> None:
        """在当前画笔下往这一格放东西。"""
        lv = self.level()
        if lv is None:
            return
        faction = self.brush_faction or (self.all_faction_ids()[0]
                                        if self.all_faction_ids() else "")
        if self.brush_kind == "building":
            entry = BuildingEntry(self.brush_value or "tower", cell[0], cell[1], faction)
            lv.start_buildings.append(entry)
            lv.mark_declared("start_buildings")
            self.selection = ("building", len(lv.start_buildings) - 1)
            self.status("放了建筑「%s」在 (%d,%d)（归属 %s）"
                        % (entry.type, cell[0], cell[1], faction or "？"))
        else:
            kind = self.brush_value or "enemy"
            if self.brush_kind == "general":
                # ★ 将领：`kind` 用 `general`，序号决定用哪一套数值（与逻辑层同一条）。
                kind = "general"
            entry = UnitEntry(faction, kind, cell[0], cell[1])
            if self.brush_kind == "general":
                entry.general_index = 1
                entry.unit_type = (self.config.general_types[0]
                                   if self.config.general_types else "")
            lv.start_units.append(entry)
            lv.mark_declared("start_units")
            self.selection = ("unit", len(lv.start_units) - 1)
            self.status("放了单位「%s」在 (%d,%d)（归属 %s）"
                        % (kind, cell[0], cell[1], faction or "？"))
        self.refresh_all()

    def delete_entry(self, tag: Tuple[str, int]) -> None:
        """右键删；★ **大本营不算「已有」**，所以不在这里删（见 6.3）。"""
        lv = self.level()
        if lv is None:
            return
        kind, index = tag
        if kind == "unit" and index < len(lv.start_units):
            del lv.start_units[index]
        elif kind == "building" and index < len(lv.start_buildings):
            del lv.start_buildings[index]
        else:
            return
        self.selection = None
        self.refresh_all()
        self.status("删掉了一个%s" % ("单位" if kind == "unit" else "建筑"))

    def selected_unit(self) -> Optional[UnitEntry]:
        lv = self.level()
        if lv is None or self.selection is None or self.selection[0] != "unit":
            return None
        index = self.selection[1]
        return lv.start_units[index] if 0 <= index < len(lv.start_units) else None

    def selected_building(self) -> Optional[BuildingEntry]:
        lv = self.level()
        if lv is None or self.selection is None or self.selection[0] != "building":
            return None
        index = self.selection[1]
        return lv.start_buildings[index] if 0 <= index < len(lv.start_buildings) else None

    # ==================================================================
    # ⑤ 校验与导出
    # ==================================================================

    def _build_check_page(self) -> None:
        self.list_host.pack(side="top", fill="both", expand=True)
        for child in self.list_host.winfo_children():
            child.destroy()
        for child in self.action_bar.winfo_children():
            child.destroy()
        outer = tk.Frame(self.list_host, bg=UI["bg"])
        outer.pack(side="top", fill="both", expand=True, padx=10, pady=8)
        head = tk.Frame(outer, bg=UI["bg"])
        head.pack(side="top", fill="x")
        tk.Label(head, text="导出前的硬拦截清单（dev_plan_7 2.5 那 16 条 + 风险 4 的过载提示）",
                 bg=UI["bg"], fg=UI["accent"], font=("Microsoft YaHei UI", 10, "bold")).pack(side="left")
        self._button(head, "重新校验", self.run_checks, padx=10).pack(side="right")
        self._button(head, "打开地图编辑器（当前关的地图）", self.open_map_editor,
                     padx=10).pack(side="right", padx=6)

        self.check_summary = tk.Label(outer, text="", bg=UI["bg"], fg=UI["text_dim"],
                                      justify="left")
        self.check_summary.pack(side="top", anchor="w", pady=(6, 4))

        self.issue_tree = ttk.Treeview(outer, columns=("sev", "code", "where", "msg"),
                                       show="headings", selectmode="browse")
        for key, header, width in (("sev", "结果", 60), ("code", "code", 190),
                                   ("where", "位置", 240), ("msg", "说明", 560)):
            self.issue_tree.heading(key, text=header)
            self.issue_tree.column(key, width=width, anchor="w")
        self.issue_tree.pack(side="top", fill="both", expand=True)
        self.issue_tree.tag_configure(SEV_BLOCK, foreground=UI["bad"])
        self.issue_tree.tag_configure(SEV_WARN, foreground=UI["warn"])
        self.issue_tree.tag_configure("pass", foreground=UI["ok"])

        bar = self.action_bar
        self._button(bar, "写文件（有拦截时禁止）", self.do_save, padx=14,
                     bg="#2f5f7a", fg="#eaf6ff").pack(side="left")
        self._button(bar, "打开地图编辑器", self.open_map_editor).pack(side="left", padx=8)
        self.run_checks()

    def run_checks(self) -> List[Issue]:
        """跑一遍校验，把结果显示在这一页上，并返回问题列表。"""
        issues = model_mod.validate_campaign(self.model, self.maps)
        self.last_issues = issues
        if hasattr(self, "issue_tree"):
            try:
                self.issue_tree.delete(*self.issue_tree.get_children())
            except tk.TclError:
                pass
            for i, issue in enumerate(issues):
                self.issue_tree.insert("", "end", iid="issue:%d" % i,
                                       values=(issue.label(), issue.code, issue.where, issue.msg),
                                       tags=(issue.sev,))
        blocks = model_mod.blockers(issues)
        warns = model_mod.warnings(issues)
        if hasattr(self, "check_summary"):
            if blocks:
                self.check_summary.configure(
                    text="拦截 %d 条、警告 %d 条 —— **有拦截项，不许写文件**；"
                         "修好它们再回来。" % (len(blocks), len(warns)), fg=UI["bad"])
            else:
                self.check_summary.configure(
                    text="通过：0 条拦截、%d 条警告（警告不挡导出）" % len(warns), fg=UI["ok"])
        return issues

    def do_save(self) -> None:
        """写文件：**有拦截就不写**（这是 dev_plan_7 2.5 的硬要求）。"""
        issues = model_mod.validate_campaign(self.model, self.maps)
        self.last_issues = issues
        blocks = model_mod.blockers(issues)
        if blocks:
            messagebox.showerror(
                "有拦截项，没有写文件",
                "这一份数据有 %d 条拦截项，导出被拒绝：\n\n%s\n\n"
                "（完整清单见「校验与导出」页；警告不影响导出）"
                % (len(blocks),
                   "\n".join("· [%s] %s %s" % (i.code, i.where, i.msg) for i in blocks[:12])))
            self.status("有 %d 条拦截项：没有写文件" % len(blocks))
            if self.page != "check":
                self.set_page("check")
            return
        try:
            self.last_written = levelfile.save_campaign(self.model)
        except (ModelError, OSError) as exc:
            messagebox.showerror("写文件失败", str(exc))
            self.status("写文件失败：%s" % exc)
            return
        self.status("写了 %d 个文件：%s" % (len(self.last_written),
                                          "、".join(Path(p).name for p in self.last_written)))
        self.refresh_all()

    def do_reload(self) -> None:
        """从磁盘重读整个战役（丢掉未保存的改动）。"""
        if self.model.dir_path is None:
            return
        try:
            fresh = levelfile.load_campaign(self.model.dir_path, self.project_dir)
        except ModelError as exc:
            messagebox.showerror("重新载入失败", str(exc))
            return
        self.model = fresh
        self.maps = levelfile.maps_by_id(self.project_dir)
        self.config = levelfile.load_config(self.project_dir)
        self.current_level_id = (fresh.levels[0].level_id if fresh.levels else "")
        self.selection = None
        self.refresh_all()
        self.status("重新载入了 %s" % fresh.campaign_id)

    # ---- 一键打开地图编辑器（6.4）----

    def map_editor_dir(self) -> Path:
        return Path(__file__).resolve().parent.parent / "map_editor"

    def open_map_editor(self) -> None:
        """`subprocess.Popen([python, map_editor 目录, "--map", <map_id>])`。

        ★ 用 `self.subprocess_mod` 而不是直接 `subprocess`：测试要把它换成假的
          （**不真起地图编辑器**，见 6.5）。这是这一处唯一的可测性改造。
        ★ `sys.executable` 而不是字面 `"python"`：双击 .bat 进来的解释器可能不是 PATH 里那个。
        """
        lv = self.level()
        map_id = lv.map_id if lv is not None else ""
        if not map_id:
            messagebox.showwarning("没有地图", "这一关还没有写 map，先到「关卡」页选一张。")
            return
        cmd = [sys.executable, str(self.map_editor_dir()), "--map", str(map_id)]
        try:
            self.subprocess_mod.Popen(cmd)
        except OSError as exc:
            messagebox.showerror("打开失败", "起不来地图编辑器：%s\n\n命令：%s" % (exc, cmd))
            self.status("打开地图编辑器失败：%s" % exc)
            return
        self.status("已请求打开地图编辑器：%s" % " ".join(cmd))

    # ==================================================================
    # ① 战役页的动作
    # ==================================================================

    def _on_campaign_select(self, _event=None) -> None:
        """左边列表里点了一行 → 切到那一关。

        ⚠️ 整段包 `try/except TclError`：Tk 的 `<<TreeviewSelect>>` 是**延迟**派发的，
          事件到手时那一棵 Treeview 可能已经被 `refresh_all()` 销毁重建过了 ——
          这时读它的 selection() 会抛 `invalid command name ".!frame...!treeview"`
          （实测踩到：点一下关卡列表就崩）。「控件已经不在了」= 这次点击已经过期，忽略掉。
        """
        if self._suppress:
            return
        try:
            if not hasattr(self, "level_tree") or not self.level_tree.winfo_exists():
                return
            sel = self.level_tree.selection()
        except tk.TclError:
            return
        if not sel:
            return
        if str(sel[0]) == self._applied_level_sel:
            return                      # 重建的回声（见 `_applied_entry_sel` 的说明）
        lid = str(sel[0]).split(":", 1)[1]
        if lid != self.current_level_id:
            self.current_level_id = lid
            self.refresh_all()

    def move_level(self, delta: int) -> None:
        if self.model.move_level(self.current_level_id, delta):
            self.refresh_all()
            self.status("关卡顺序已调整")
        else:
            self.status("已经到头了" if delta < 0 else "已经是最后一关")

    def do_new_level(self) -> None:
        """新建一关（问 id 与地图；对话框可被测试换成「直接给答案」）。"""
        if not self.maps:
            messagebox.showerror("没有地图", "data/maps/ 下一张地图都没有：先放一张图进去。")
            return
        default_map = (self.level().map_id if self.level() and self.level().map_id in self.maps
                       else sorted(self.maps)[0])
        answer = _ask_new_level(self.root, sorted(self.maps), default_map)
        if not answer:
            return
        level_id, map_id = answer
        lv = self.model.new_level(level_id, map_id)
        lv.name = level_id
        self.current_level_id = lv.level_id
        self.refresh_all()
        self.status("新建了关卡「%s」（地图 %s）—— 记得填席位 / 目标 / 大本营"
                    % (lv.level_id, map_id))

    def do_delete_level(self) -> None:
        lv = self.level()
        if lv is None:
            return
        if not messagebox.askyesno("删除关卡",
                                   "从战役里删掉关卡「%s」？\n"
                                   "（只从 levels[] 移除，文件留在盘上，由你自己决定要不要删）"
                                   % lv.level_id):
            return
        if self.model.remove_level(lv.level_id):
            self.current_level_id = (self.model.levels[0].level_id
                                     if self.model.levels else "")
            self.selection = None
            self.refresh_all()
            self.status("删掉了关卡 %s（文件没有删）" % lv.level_id)

    # ---- ② 关卡页的提交 ----

    def _after_change(self) -> None:
        """改完数据之后统一走它：重建两栏 + 重画。"""
        self.sync_faction_context()
        self.refresh_all()

    def _commit_level_name(self) -> None:
        lv = self.level()
        if lv is None:
            return
        text = self.lv_name_var.get().strip()
        if not text:
            self.status("关卡名字不能为空")
            self.lv_name_var.set(lv.name)
            return
        lv.name = text
        self.refresh_all()

    def _commit_level_mode(self) -> None:
        lv = self.level()
        if lv is None:
            return
        new_mode = MODE_COOP if str(self.lv_mode_var.get()).strip() == "双人合作" else MODE_SOLO
        if new_mode == lv.mode:
            return
        lv.mode = new_mode
        # ★ 「模式一改，玩家席位数跟着变」（6.2）：合作补到 2 个席位、单人裁到 1 个。
        want = 2 if new_mode == MODE_COOP else 1
        while len(lv.players) < want:
            lv.add_player("")
        while len(lv.players) > want:
            lv.remove_player(len(lv.players) - 1)
        self.status("模式改成「%s」：席位现在是 %d 个" % (self.lv_mode_var.get(), len(lv.players)))
        self._after_change()

    def _commit_level_map(self) -> None:
        lv = self.level()
        if lv is None:
            return
        map_id = self._map_id_from_label(self.lv_map_var.get())
        if map_id == lv.map_id:
            return
        lv.map_id = map_id
        lv.mark_declared("map")
        self.status("地图改成 %s（画布与下拉都重载了）" % map_id)
        self._after_change()
        if self.page == "place":
            self.fit_view()

    def _commit_objective_zone(self) -> None:
        lv = self.level()
        if lv is None:
            return
        zid = self._zone_id_from_label(self.lv_obj_zone_var.get())
        if not lv.objectives:
            lv.objectives.append({"kind": OBJ_HOLD_ZONE, "zone": zid, "hold_sec": 90.0})
        else:
            lv.objectives[0]["kind"] = OBJ_HOLD_ZONE
            lv.objectives[0]["zone"] = zid
        self.status("目标区划 = %s" % self._zone_label(zid))
        self._after_change()

    def _commit_objective_sec(self) -> None:
        lv = self.level()
        if lv is None:
            return
        text = self.lv_obj_sec_var.get().strip()
        try:
            sec = float(text)
        except ValueError:
            self.status("守住秒数要填数字（现在写的是「%s」）" % text)
            return
        if not lv.objectives:
            lv.objectives.append({"kind": OBJ_HOLD_ZONE, "zone": -1, "hold_sec": sec})
        else:
            lv.objectives[0]["hold_sec"] = sec
        self._after_change()

    def do_add_fail(self) -> None:
        """点一下加一条 `zone_lost`（第一批只有这一种）。"""
        lv = self.level()
        if lv is None:
            return
        info = self.map_info()
        used = {int(f.get("zone", -1)) for f in lv.fail_conditions}
        pick = -1
        if info is not None:
            for zid in info.zone_ids:
                if zid not in used and zid != lv.objective_zone():
                    pick = int(zid)
                    break
        lv.fail_conditions.append({"kind": FAIL_ZONE_LOST, "zone": pick})
        lv.mark_declared("fail_conditions")
        self._after_change()
        self.status("加了一条失败条件（区划 %s）—— 在下面那个列表里可删"
                    % self._zone_label(pick))

    def do_remove_fail(self) -> None:
        lv = self.level()
        if lv is None or not hasattr(self, "fail_tree"):
            return
        sel = self.fail_tree.selection()
        if not sel:
            self.status("先在上面那个列表里点一条")
            return
        index = int(str(sel[0]).split(":", 1)[1])
        if 0 <= index < len(lv.fail_conditions):
            del lv.fail_conditions[index]
            self._after_change()

    # ==================================================================
    # ③ 阵营与 AI 页的动作
    # ==================================================================

    def set_player_faction(self, index: int, fid: str) -> None:
        lv = self.level()
        if lv is None:
            return
        while len(lv.players) <= index:
            lv.add_player("")
        lv.players[index]["faction"] = fid
        self._after_change()

    def set_player_base(self, index: int, point: Optional[Tuple[int, int]]) -> None:
        lv = self.level()
        if lv is None:
            return
        while len(lv.players) <= index:
            lv.add_player("")
        lv.players[index]["base"] = point
        self._after_change()

    def toggle_playable(self, fid: str) -> None:
        entry = None
        for e in self.model.factions:
            if str(e.get("id", "")) == fid:
                entry = e
                break
        if entry is None:
            entry = self.model.ensure_faction(fid, fid, self.faction_color(fid))
        entry["playable"] = not bool(entry.get("playable", False))
        self._after_change()

    def set_faction_field(self, fid: str, field: str, value: Any) -> None:
        lv = self.level()
        if lv is None:
            return
        entry = lv.ensure_faction(fid)
        if field == "ai":
            entry.ai = str(value)
        elif field == "resource_mult":
            entry.resource_mult = float(value)
        elif field == "start_food":
            entry.start_food = float(value)
        elif field == "start_gold":
            entry.start_gold = float(value)
        elif field == "base":
            entry.base = value
        elif field == "color":
            entry.color = str(value)
            self.model.ensure_faction(fid, fid, str(value))["color"] = str(value)
        elif field == "faction_ai":
            entry.faction_ai = value
        elif field == "general_ai":
            entry.general_ai = value
        self._after_change()

    def set_attack_target(self, fid: str, spec: Optional[dict]) -> None:
        """③ 的下拉与 ④ 的画布点选**共用的唯一入口**（保证两处看到的是同一个值）。"""
        lv = self.level()
        if lv is None:
            return
        entry = lv.ensure_faction(fid)
        entry.attack_target = spec
        self._after_change()

    def remove_faction_entry(self, fid: str) -> None:
        lv = self.level()
        if lv is None:
            return
        lv.remove_faction(fid)
        self._after_change()

    # ==================================================================
    # 侧边栏
    # ==================================================================

    def _rebuild_sidebar(self) -> None:
        for child in self.sidebar.winfo_children():
            child.destroy()
        try:
            if self.page == "campaign":
                self._sidebar_campaign()
            elif self.page == "level":
                self._sidebar_level()
            elif self.page == "factions":
                self._sidebar_factions()
            elif self.page == "place":
                self._sidebar_place()
            else:
                self._sidebar_check()
        finally:
            try:
                self.sidebar.update_idletasks()
                self._on_sidebar_configure()
            except tk.TclError:
                pass

    def _section(self, title: str, hint: str = "") -> tk.Frame:
        wrap = tk.Frame(self.sidebar, bg=UI["panel"])
        wrap.pack(side="top", fill="x", padx=10, pady=(10, 0))
        head = tk.Frame(wrap, bg=UI["panel"])
        head.pack(side="top", fill="x")
        tk.Label(head, text=title, bg=UI["panel"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 10, "bold")).pack(side="left")
        frame = tk.Frame(wrap, bg=UI["panel"])
        frame.pack(side="top", fill="x")
        wrap.section_title = title                 # type: ignore[attr-defined]
        if hint:
            tk.Label(frame, text=hint, bg=UI["panel"], fg=UI["text_dim"], justify="left",
                     wraplength=390, font=("Microsoft YaHei UI", 8)).pack(side="top", anchor="w")
        return frame

    def _entry_cell(self, parent, label: str, value: str, commit: Callable[[str], None],
                    width: int = 26) -> ttk.Entry:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(side="top", fill="x", pady=2)
        tk.Label(row, text=label, width=12, anchor="w", bg=UI["panel"],
                 fg=UI["text"]).pack(side="left")
        var = tk.StringVar(value=value)
        entry = ttk.Entry(row, textvariable=var, width=width)
        entry.pack(side="left")
        entry.commit_action = lambda: commit(var.get())      # type: ignore[attr-defined]
        entry.bind("<Return>", lambda e: entry.commit_action())
        entry.bind("<FocusOut>", lambda e: entry.commit_action())
        return entry

    def _combo_cell(self, parent, label: str, value: str, choices: Sequence[str],
                    commit: Callable[[str], None], width: int = 24) -> ttk.Combobox:
        row = tk.Frame(parent, bg=UI["panel"])
        row.pack(side="top", fill="x", pady=2)
        tk.Label(row, text=label, width=12, anchor="w", bg=UI["panel"],
                 fg=UI["text"]).pack(side="left")
        var = tk.StringVar(value=value)
        combo = ttk.Combobox(row, textvariable=var, values=list(choices), width=width,
                             state="readonly")
        combo.pack(side="left")
        combo.commit_action = lambda: commit(var.get())       # type: ignore[attr-defined]
        combo.bind("<<ComboboxSelected>>", lambda e: combo.commit_action())
        return combo

    def _check_cell(self, parent, label: str, value: bool,
                    commit: Callable[[bool], None]) -> ttk.Checkbutton:
        var = tk.BooleanVar(value=bool(value))
        chk = ttk.Checkbutton(parent, text=label, variable=var,
                              command=lambda: commit(bool(var.get())))
        chk.pack(side="top", anchor="w", pady=1)
        return chk

    def _hint(self, parent, text: str) -> None:
        tk.Label(parent, text=text, bg=UI["panel"], fg=UI["text_dim"], justify="left",
                 wraplength=390, font=("Microsoft YaHei UI", 8)).pack(side="top", anchor="w",
                                                                     pady=(2, 0))

    # ---- ① 战役页侧栏 ----

    def _sidebar_campaign(self) -> None:
        section = self._section("战役")
        self._entry_cell(section, "战役名", self.model.name, self._commit_campaign_name)
        self._entry_cell(section, "简介", self.model.description,
                         self._commit_campaign_desc)
        self._combo_cell(section, "默认模式",
                         "双人合作" if self.model.default_mode == MODE_COOP else "单人",
                         ("单人", "双人合作"), self._commit_default_mode)
        self._hint(section, "默认模式 = 「新建关卡」时新关卡的初始模式（关卡自己还能改）")

        section2 = self._section("阵营表（campaign.json 的 factions[]）",
                                 "playable = 玩家能选谁；不选的那些由 AI 驱动")
        for e in self.model.factions:
            fid = str(e.get("id", ""))
            row = tk.Frame(section2, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=2)
            tk.Label(row, text=fid, width=8, anchor="w", bg=UI["panel"],
                     fg=self.faction_color(fid)).pack(side="left")
            self._entry_cell(row, "名字", str(e.get("name", "")),
                             lambda text, f=fid: self._set_campaign_faction(f, "name", text),
                             width=14).pack(side="left")
            self._entry_cell(row, "颜色", str(e.get("color", "")),
                             lambda text, f=fid: self._set_campaign_faction(f, "color", text),
                             width=10).pack(side="left")
            self._check_cell(row, "可玩", bool(e.get("playable", False)),
                             lambda on, f=fid: self._set_campaign_faction(f, "playable", on))
        self._entry_cell(section2, "加一方 id", "", self._add_campaign_faction)
        self._hint(section2, "加一方的 id 会同时出现在这一关的阵营页里（点「可玩」决定谁能被选）")

        section3 = self._section("关卡")
        self._entry_cell(section3, "新关卡 id", "",
                         lambda text: self._new_level_quick(text))
        self._hint(section3, "新关卡用当前关的地图；排顺序、删关卡在左边的列表上做")

    def _commit_campaign_name(self, text: str) -> None:
        text = str(text).strip()
        if not text:
            self.status("战役名不能为空")
            return
        self.model.name = text
        self.refresh_all()

    def _commit_campaign_desc(self, text: str) -> None:
        self.model.description = str(text)
        self.status("简介已改（写文件才落盘）")

    def _commit_default_mode(self, text: str) -> None:
        self.model.default_mode = MODE_COOP if str(text).strip() == "双人合作" else MODE_SOLO
        self.refresh_all()

    def _set_campaign_faction(self, fid: str, field: str, value: Any) -> None:
        entry = self.model.ensure_faction(fid, fid, self.faction_color(fid))
        if field == "playable":
            entry["playable"] = bool(value)
        else:
            entry[field] = str(value)
        self._after_change()

    def _add_campaign_faction(self, text: str) -> None:
        fid = str(text).strip()
        if not fid:
            return
        self.model.ensure_faction(fid, fid, self.faction_color(fid))
        self._after_change()
        self.status("加了阵营 %s" % fid)

    def _new_level_quick(self, text: str) -> None:
        lid = str(text).strip()
        if not lid:
            return
        map_id = self.level().map_id if self.level() else (sorted(self.maps)[0]
                                                           if self.maps else "")
        lv = self.model.new_level(lid, map_id)
        lv.name = lv.level_id
        self.current_level_id = lv.level_id
        self._after_change()
        self.status("新建了关卡 %s" % lv.level_id)

    # ---- ② 关卡页侧栏 ----

    def _sidebar_level(self) -> None:
        lv = self.level()
        if lv is None:
            self._section("关卡").pack_forget()
            return
        section = self._section("当前关", "目标第一版**只有**一种：「守住某个区划 N 秒」")
        self._entry_cell(section, "名字", lv.name,
                         lambda text: self._set_level_name(text))
        self._combo_cell(section, "模式",
                         "双人合作" if lv.mode == MODE_COOP else "单人",
                         ("单人", "双人合作"), self._set_level_mode)
        self._combo_cell(section, "地图", self._map_label(lv.map_id),
                         tuple(self._map_label(m) for m in sorted(self.maps)),
                         self._set_level_map)

        section2 = self._section("目标与失败条件")
        obj = lv.objective() or {}
        self._combo_cell(section2, "目标区划", self._zone_label(int(obj.get("zone", -1))),
                         self._zone_choices(), self._set_objective_zone)
        self._entry_cell(section2, "守住秒数", fmt_sec(float(obj.get("hold_sec", 0.0))),
                         self._set_objective_sec)
        for i, f in enumerate(lv.fail_conditions):
            row = tk.Frame(section2, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=1)
            tk.Label(row, text="区划失守", width=12, anchor="w", bg=UI["panel"],
                     fg=UI["text"]).pack(side="left")
            combo = self._combo_cell(row, "", self._zone_label(int(f.get("zone", -1))),
                                     self._zone_choices(),
                                     lambda text, idx=i: self._set_fail_zone(idx, text),
                                     width=18)
            combo.pack_forget()
            combo.pack(side="left")
            self._button(row, "删", lambda idx=i: self._delete_fail(idx), padx=6).pack(side="left",
                                                                                       padx=4)
        self._button(section2, "＋ 加一条「指定区划失守」", self.do_add_fail).pack(anchor="w",
                                                                              pady=(4, 0))
        self._hint(section2, "「大本营被拆」那条是常开的，不写在这里；额外条件不能就是目标区划")

    def _set_level_name(self, text: str) -> None:
        lv = self.level()
        if lv is None or not str(text).strip():
            return
        lv.name = str(text).strip()
        self.refresh_all()

    def _set_level_mode(self, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        lv.mode = MODE_COOP if str(text).strip() == "双人合作" else MODE_SOLO
        want = 2 if lv.mode == MODE_COOP else 1
        while len(lv.players) < want:
            lv.add_player("")
        while len(lv.players) > want:
            lv.remove_player(len(lv.players) - 1)
        self._after_change()

    def _set_level_map(self, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        lv.map_id = self._map_id_from_label(text)
        lv.mark_declared("map")
        self._after_change()

    def _set_objective_zone(self, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        zid = self._zone_id_from_label(text)
        if not lv.objectives:
            lv.objectives.append({"kind": OBJ_HOLD_ZONE, "zone": zid, "hold_sec": 90.0})
        else:
            lv.objectives[0]["kind"] = OBJ_HOLD_ZONE
            lv.objectives[0]["zone"] = zid
        self._after_change()

    def _set_objective_sec(self, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        try:
            sec = float(str(text).strip())
        except ValueError:
            self.status("守住秒数要填数字")
            self.refresh_all()
            return
        if not lv.objectives:
            lv.objectives.append({"kind": OBJ_HOLD_ZONE, "zone": -1, "hold_sec": sec})
        else:
            lv.objectives[0]["hold_sec"] = sec
        self._after_change()

    def _set_fail_zone(self, index: int, text: str) -> None:
        lv = self.level()
        if lv is None or not (0 <= index < len(lv.fail_conditions)):
            return
        lv.fail_conditions[index]["kind"] = FAIL_ZONE_LOST
        lv.fail_conditions[index]["zone"] = self._zone_id_from_label(text)
        self._after_change()

    def _delete_fail(self, index: int) -> None:
        lv = self.level()
        if lv is None or not (0 <= index < len(lv.fail_conditions)):
            return
        del lv.fail_conditions[index]
        self._after_change()

    # ---- ③ 阵营与 AI 页侧栏 ----

    def _sidebar_factions(self) -> None:
        lv = self.level()
        if lv is None:
            return
        # ---- 玩家席位（1 或 2 个）----
        seats = self._section("玩家席位",
                              "顺序 = 席位顺序（房主第 1 个、客机第 2 个）；"
                              "合作关必须是恰好 2 个，且两方要互为盟友")
        choices = self.all_faction_ids()
        for i, p in enumerate(lv.players):
            row = tk.Frame(seats, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=2)
            tk.Label(row, text="席位 %d" % (i + 1), width=12, anchor="w", bg=UI["panel"],
                     fg=UI["text"]).pack(side="left")
            combo = ttk.Combobox(row, values=choices, width=12, state="readonly")
            combo.set(str(p.get("faction", "")))
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>",
                       lambda e, idx=i, c=combo: self.set_player_faction(idx, c.get()))
            base = p.get("base")
            entry = ttk.Entry(row, width=12)
            entry.insert(0, "" if base is None else "%d,%d" % (base[0], base[1]))
            entry.pack(side="left", padx=4)
            entry.commit_action = (lambda idx=i, en=entry:            # type: ignore[attr-defined]
                                   self._commit_player_base(idx, en.get()))
            entry.bind("<Return>", lambda e, en=entry: en.commit_action())
            entry.bind("<FocusOut>", lambda e, en=entry: en.commit_action())
        self._hint(seats, "大本营留空 = 用地图的 `faction_bases`；填 `x,y` 就覆盖它")

        # ---- 玩家席位也能配 AI（允许，运行时按选中的席位摘掉）----
        self._hint(seats, "★ 给「可玩」阵营配 AI 是允许的：运行时按选中的席位摘掉"
                          "（本局谁在被玩，谁就不动）；不是错误，所以校验不会拦它。")

        # ---- 每一方一行 ----
        for fid in self.all_faction_ids():
            e = lv.faction(fid)
            title = "%s %s" % (fid, self.model.faction_name(fid))
            section = self._section(title,
                                    "关卡 factions[] 里写了这一方 = 这一关它被点名" if e
                                    else "这一关没点名它（导出时不会为它写一份）")
            if e is None:
                self._button(section, "在这关点名这一方",
                             lambda f=fid: self._point_faction(f)).pack(anchor="w")
                continue
            self._combo_cell(section, "AI 类型", self._ai_label(e.ai),
                             tuple(self._ai_label(k) for k in AI_KINDS),
                             lambda text, f=fid: self.set_faction_field(f, "ai",
                                                                        self._ai_value(text)))
            self._entry_cell(section, "大本营", e.base_label(),
                             lambda text, f=fid: self._set_base_text(f, text))
            self._entry_cell(section, "资源倍率", "%g" % e.resource_mult,
                             lambda text, f=fid: self._set_float(f, "resource_mult", text))
            self._entry_cell(section, "开局粮食", "%g" % e.start_food,
                             lambda text, f=fid: self._set_float(f, "start_food", text))
            self._entry_cell(section, "开局黄金", "%g" % e.start_gold,
                             lambda text, f=fid: self._set_float(f, "start_gold", text))
            self._target_rows(section, fid, e)

            # ---- 「高级」AI 参数（缺省 = 继承 config）----
            adv = tk.Frame(section, bg=UI["panel"])
            adv.pack(side="top", fill="x", pady=(4, 0))
            toggle = self._button(adv, "高级 AI 参数 ▾", lambda a=adv: self._toggle_advanced(a))
            toggle.pack(anchor="w")
            body = tk.Frame(section, bg=UI["panel"])
            body.pack(side="top", fill="x")
            body.visible = False                      # type: ignore[attr-defined]
            defaults = ", ".join("%s=%s" % (k, v) for k, v in
                                 sorted(self.config.ai_faction_cfg.items()))
            self._hint(body, "阵营性 AI 推荐区间（缺省 = 继承 config）：%s" % (defaults or "（config 里没写）"))
            fa = e.faction_ai or {}
            for key in ("generals", "min_retinue", "min_ready", "ready_mult",
                        "attack_repeat_sec", "recruit_cooldown_sec"):
                inherit = self.config.ai_faction_cfg.get(key, "")
                self._entry_cell(body, key, "" if key not in fa else "%g" % fa[key],
                                 lambda text, f=fid, k=key: self._set_ai_param(f, "faction_ai",
                                                                               k, text))
                self._hint(body, "　缺省 = %s" % (inherit if inherit != "" else "（config 里没写）"))
            gd = e.general_ai or {}
            for key in ("patrol_interval_sec", "patrol_leash_tiles", "min_retinue"):
                self._entry_cell(body, "将领·%s" % key,
                                 "" if key not in gd else "%g" % gd[key],
                                 lambda text, f=fid, k=key: self._set_ai_param(f, "general_ai",
                                                                               k, text))
            self._button(section, "从这一关移除这一方",
                         lambda f=fid: self.remove_faction_entry(f),
                         bg="#3a2b2b").pack(anchor="w", pady=(6, 0))

    def _target_rows(self, parent, fid: str, e: FactionEntry) -> None:
        """进攻目标：一个下拉 + 一个「载荷」输入（③ 与 ④ 共用的同一个字段）。"""
        spec = e.attack_target
        kind = str(spec.get("kind", "")) if spec else ""
        label = {"": "最近敌方区划（缺省）", TARGET_ZONE: "指定区划", TARGET_POINT: "指定格",
                 TARGET_BUILDING: "指定建筑", TARGET_BASE: "某方的家"}.get(kind, "不认识")
        combo = self._combo_cell(parent, "进攻目标", label,
                                 tuple(self._target_labels()),
                                 lambda text, f=fid: self._set_target_kind(f, text))
        del combo
        if kind == TARGET_ZONE:
            self._combo_cell(parent, "　目标区划", self._zone_label(int(spec.get("zone", -1))),
                             self._zone_choices(),
                             lambda text, f=fid: self.set_attack_target(
                                 f, {"kind": TARGET_ZONE, "zone": self._zone_id_from_label(text)}))
        elif kind in (TARGET_POINT, TARGET_BUILDING):
            self._entry_cell(parent, "　坐标 x,y",
                             "%d,%d" % (int(spec.get("x", -1)), int(spec.get("y", -1))),
                             lambda text, f=fid, k=kind: self._set_target_point(f, k, text))
        elif kind == TARGET_BASE:
            self._combo_cell(parent, "　哪一方", str(spec.get("faction", "")),
                             tuple(self.all_faction_ids()),
                             lambda text, f=fid: self.set_attack_target(
                                 f, {"kind": TARGET_BASE, "faction": str(text)}))
        self._hint(parent, "当前：%s（在「摆放」页点画布也能改同一个字段）"
                   % target_label(spec))

    def _target_labels(self) -> List[str]:
        return ["最近敌方区划（缺省）", "指定区划", "指定格", "指定建筑", "某方的家"]

    def _set_target_kind(self, fid: str, label: str) -> None:
        if label.startswith("最近"):
            self.set_attack_target(fid, None)
        elif label == "指定区划":
            info = self.map_info()
            zid = info.zone_ids[0] if info is not None and info.zone_ids else -1
            self.set_attack_target(fid, {"kind": TARGET_ZONE, "zone": int(zid)})
        elif label == "指定格":
            self.set_attack_target(fid, {"kind": TARGET_POINT, "x": 0, "y": 0})
        elif label == "指定建筑":
            self.set_attack_target(fid, {"kind": TARGET_BUILDING, "x": 0, "y": 0})
        else:
            self.set_attack_target(fid, {"kind": TARGET_BASE, "faction": fid})

    def _set_target_point(self, fid: str, kind: str, text: str) -> None:
        point = _parse_point(text)
        if point is None:
            self.status("坐标要写成 `x,y`")
            self.refresh_all()
            return
        self.set_attack_target(fid, {"kind": kind, "x": point[0], "y": point[1]})

    def _ai_label(self, ai: str) -> str:
        return {AI_NONE: "无", AI_FACTION: "阵营性", AI_GENERAL: "将领性"}.get(ai, "无")

    def _ai_value(self, label: str) -> str:
        return {"无": AI_NONE, "阵营性": AI_FACTION, "将领性": AI_GENERAL}.get(label, AI_NONE)

    def _point_faction(self, fid: str) -> None:
        lv = self.level()
        if lv is None:
            return
        lv.ensure_faction(fid)
        self._after_change()

    def _set_base_text(self, fid: str, text: str) -> None:
        text = str(text).strip()
        if not text or text == "—":
            self.set_faction_field(fid, "base", None)
            return
        point = _parse_point(text)
        if point is None:
            self.status("大本营要写成 `x,y`（清空 = 用地图的）")
            self.refresh_all()
            return
        self.set_faction_field(fid, "base", point)

    def _set_float(self, fid: str, field: str, text: str) -> None:
        try:
            value = float(str(text).strip())
        except ValueError:
            self.status("「%s」要填数字" % field)
            self.refresh_all()
            return
        self.set_faction_field(fid, field, value)

    def _set_ai_param(self, fid: str, block: str, key: str, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        e = lv.ensure_faction(fid)
        current = dict(getattr(e, block) or {})
        text = str(text).strip()
        if not text:
            current.pop(key, None)                  # 清空 = 删掉这个键 = 继承 config
        else:
            try:
                value = float(text)
            except ValueError:
                self.status("AI 参数要填数字")
                self.refresh_all()
                return
            current[key] = value
        self.set_faction_field(fid, block, current or None)

    def _toggle_advanced(self, body: tk.Frame) -> None:
        visible = not getattr(body, "visible", False)
        body.visible = visible                        # type: ignore[attr-defined]
        if visible:
            body.pack(side="top", fill="x")
        else:
            body.pack_forget()
        try:
            self.sidebar.update_idletasks()
            self._on_sidebar_configure()
        except tk.TclError:
            pass

    # ---- ④ 摆放页侧栏 ----

    def _sidebar_place(self) -> None:
        lv = self.level()
        if lv is None:
            return
        section = self._section("画笔", "左键点空格 = 放一个；右键点它 = 删；点已有的 = 选中")
        self._combo_cell(section, "放什么", self._brush_label(),
                         ("单位", "将领", "建筑"), self._set_brush_kind)
        values = (self.config.unit_types if self.brush_kind == "unit"
                  else self.config.building_types if self.brush_kind == "building"
                  else ["general"])
        self._combo_cell(section, "种类", self.brush_value,
                         tuple(values) or ("（config 里没有）",), self._set_brush_value)
        factions = self.all_faction_ids()
        self._combo_cell(section, "归属", self.brush_faction or (factions[0] if factions else ""),
                         tuple(factions) or ("（没有阵营）",), self._set_brush_faction)

        if self.target_mode_faction is not None:
            self._hint(section, "★ 正在「设进攻目标」模式：「%s」—— 点区划 / 空格改它的目标，Esc 退出"
                       % self.target_mode_faction)

        # ---- 地图上已有的东西 ----
        section2 = self._section("地图上已有的（关卡层）",
                                 "大本营不在这里 —— 它在「阵营与AI」页里改，免得删出「没有大本营」的关卡")
        self.entry_tree = ttk.Treeview(section2, columns=("what", "who", "pos"),
                                       show="headings", height=10, selectmode="browse")
        for key, header, width in (("what", "什么", 110), ("who", "归属/种类", 130),
                                   ("pos", "位置", 90)):
            self.entry_tree.heading(key, text=header)
            self.entry_tree.column(key, width=width, anchor="w")
        self.entry_tree.pack(side="top", fill="x")
        for i, u in enumerate(lv.start_units):
            self.entry_tree.insert("", "end", iid="unit:%d" % i,
                                   values=("将领" if u.is_general() else "单位",
                                           "%s/%s" % (u.faction, u.kind),
                                           "%d,%d" % (u.x, u.y)))
        for i, b in enumerate(lv.start_buildings):
            self.entry_tree.insert("", "end", iid="building:%d" % i,
                                   values=("建筑", "%s/%s" % (b.owner, b.type),
                                           "%d,%d" % (b.x, b.y)))
        self.entry_tree.bind("<<TreeviewSelect>>", self._on_entry_select)
        self._applied_entry_sel = None
        if self.selection is not None:
            iid = "%s:%d" % self.selection
            if self.entry_tree.exists(iid):
                self.entry_tree.selection_set(iid)
                self._applied_entry_sel = iid

        # ---- 选中项的属性 ----
        unit = self.selected_unit()
        building = self.selected_building()
        if unit is not None:
            sec = self._section("选中的单位", "选中改归属 / 兵种 / 将领序号 / zone / hold / 是否挂将领性 AI")
            factions = self.all_faction_ids()
            self._combo_cell(sec, "归属", unit.faction, tuple(factions) or ("—",),
                             lambda text: self._set_unit_field("faction", str(text)))
            kinds = list(self.config.unit_types)
            if unit.is_general():
                kinds = ["general"] + kinds
            self._combo_cell(sec, "兵种", unit.kind, tuple(kinds), 
                             lambda text: self._set_unit_field("kind", str(text)))
            if unit.is_general():
                self._combo_cell(sec, "将领序号",
                                 str(unit.general_index or 1),
                                 tuple(str(i) for i in self.config.general_indices()),
                                 lambda text: self._set_unit_field("general_index", int(text)))
            self._entry_cell(sec, "x,y", "%d,%d" % (unit.x, unit.y),
                             lambda text: self._set_unit_point(text))
            self._entry_cell(sec, "zone", str(unit.zone),
                             lambda text: self._set_unit_field("zone", _as_int(text, -1)))
            self._combo_cell(sec, "ai", self._ai_label(unit.ai),
                             tuple(self._ai_label(k) for k in AI_KINDS),
                             lambda text: self._set_unit_field("ai", self._ai_value(text)))
            self._check_cell(sec, "原地不动（hold）", unit.hold,
                             lambda on: self._set_unit_field("hold", bool(on)))
            self._entry_cell(sec, "显示名", unit.name,
                             lambda text: self._set_unit_field("name", str(text)))
            self._button(sec, "删掉它", lambda: self.delete_entry(("unit",
                                                                  self.selection[1])),
                         bg="#3a2b2b").pack(anchor="w", pady=(6, 0))
        elif building is not None:
            sec = self._section("选中的建筑", "建筑的**类型与数值**归 unit_editor / map_editor；这里只管开局摆在哪、归谁")
            factions = self.all_faction_ids()
            self._combo_cell(sec, "归属", building.owner, tuple(factions) or ("—",),
                             lambda text: self._set_building_field("owner", str(text)))
            self._combo_cell(sec, "类型", building.type,
                             tuple(self.config.building_types) or ("—",),
                             lambda text: self._set_building_field("type", str(text)))
            self._entry_cell(sec, "x,y", "%d,%d" % (building.x, building.y),
                             lambda text: self._set_building_point(text))
            self._button(sec, "删掉它", lambda: self.delete_entry(("building",
                                                                  self.selection[1])),
                         bg="#3a2b2b").pack(anchor="w", pady=(6, 0))
        else:
            self._section("选中的东西", "在画布上点一个已有的单位 / 建筑，这里就会出现它的全部字段")

    def _brush_label(self) -> str:
        return {"unit": "单位", "general": "将领", "building": "建筑"}.get(self.brush_kind, "单位")

    def _set_brush_kind(self, label: str) -> None:
        self.brush_kind = {"单位": "unit", "将领": "general", "建筑": "building"}.get(label, "unit")
        if self.brush_kind == "unit":
            self.brush_value = self.config.unit_types[0] if self.config.unit_types else "enemy"
        elif self.brush_kind == "building":
            self.brush_value = (self.config.building_types[0]
                                if self.config.building_types else "tower")
        else:
            self.brush_value = "general"
        self.refresh_all()

    def _set_brush_value(self, text: str) -> None:
        self.brush_value = str(text)
        self.status("画笔：%s" % self.brush_value)

    def _set_brush_faction(self, text: str) -> None:
        self.brush_faction = str(text)
        self.status("画笔归属：%s" % self.brush_faction)

    def _on_entry_select(self, _event=None) -> None:
        """摆放页那个列表里点了一行 → 选中它（**大本营不在这个列表里**，见 6.3）。

        ⚠️ 与 `_on_campaign_select` 同一条防御：事件是延迟派发的，那时控件可能已经被
          重建过（`invalid command name`）。「控件不在了」= 这次点击过期，忽略。
        """
        if self._suppress:
            return                      # 重建期间 `selection_set` 会打回来（见 `_suppress`）
        try:
            if not hasattr(self, "entry_tree") or not self.entry_tree.winfo_exists():
                return
            sel = self.entry_tree.selection()
        except tk.TclError:
            return
        if not sel:
            return
        if str(sel[0]) == self._applied_entry_sel:
            return                      # 重建的回声（见 `_applied_entry_sel` 的说明）
        kind, index = str(sel[0]).split(":", 1)
        self.selection = (kind, int(index))
        self.refresh_all()

    def _set_unit_field(self, field: str, value: Any) -> None:
        u = self.selected_unit()
        if u is None:
            return
        setattr(u, field, value)
        if field == "kind" and u.is_general() and not u.unit_type:
            u.unit_type = (self.config.general_types[0] if self.config.general_types else "")
        self.refresh_all()

    def _set_unit_point(self, text: str) -> None:
        u = self.selected_unit()
        point = _parse_point(text)
        if u is None or point is None:
            self.status("坐标要写成 `x,y`")
            return
        u.x, u.y = point
        self.refresh_all()

    def _set_building_field(self, field: str, value: Any) -> None:
        b = self.selected_building()
        if b is None:
            return
        setattr(b, field, value)
        self.refresh_all()

    def _set_building_point(self, text: str) -> None:
        b = self.selected_building()
        point = _parse_point(text)
        if b is None or point is None:
            self.status("坐标要写成 `x,y`")
            return
        b.x, b.y = point
        self.refresh_all()

    # ---- ⑤ 校验页侧栏 ----

    def _sidebar_check(self) -> None:
        section = self._section("导出", "有拦截项时**禁止写文件**（这是硬要求，不是提示）")
        self._button(section, "跑一遍校验", self.run_checks, padx=12).pack(anchor="w")
        self._button(section, "写文件", self.do_save, padx=12,
                     bg="#2f5f7a", fg="#eaf6ff").pack(anchor="w", pady=4)
        self._button(section, "打开地图编辑器", self.open_map_editor).pack(anchor="w")
        if self.last_written:
            self._hint(section, "上一次写了 %d 个文件：\n%s"
                       % (len(self.last_written), "\n".join(self.last_written)))
        section2 = self._section("这一版不做的事", "见 dev_plan_7 6.6：编辑器的边界")
        for line in ("不做撤销 / 重做（数据都在 JSON 里，改坏了重新载入）",
                     "不做剧本预览（要预览就进游戏跑一关）",
                     "摆放不做自动避让（允许压在中心格上，但导出会拦）",
                     "不做「每方一份目标」（可玩阵营必须同方）",
                     "不做「这一关大概多久成形」的估算提示（用户明确不要）",
                     "地形 / 区划 / 中心归地图编辑器；兵种 / 建筑数值归单位编辑器"):
            self._hint(section2, "· " + line)


# ======================================================================
# 小工具
# ======================================================================

def _parse_point(text: str) -> Optional[Tuple[int, int]]:
    """`"3,4"` / `"3 4"` → `(3, 4)`；解析不了 → None。"""
    raw = str(text).replace("，", ",").replace(" ", ",")
    parts = [p for p in raw.split(",") if p.strip()]
    if len(parts) != 2:
        return None
    try:
        return (int(float(parts[0])), int(float(parts[1])))
    except ValueError:
        return None


def _as_int(text: str, fallback: int = -1) -> int:
    try:
        return int(float(str(text).strip()))
    except ValueError:
        return fallback


def _ask_new_level(root: tk.Tk, map_ids: Sequence[str],
                   default_map: str) -> Optional[Tuple[str, str]]:
    """问「新关卡 id + 用哪张图」。

    ★ 单独抽成一个模块级函数（而不是写在方法里）：测试把它换成「直接给答案」，
      与 unit_editor 的 `_ask_new_entry` 完全同款 —— 免得测试去驱动真对话框。
    """
    level_id = simpledialog.askstring("新建关卡", "关卡 id（也是文件名）：", parent=root)
    if not level_id:
        return None
    map_id = simpledialog.askstring("新建关卡", "用哪张地图？（可选：%s）" % "、".join(map_ids),
                                    initialvalue=default_map, parent=root)
    if not map_id or map_id not in map_ids:
        map_id = default_map
    return (str(level_id).strip(), str(map_id).strip())


def run(campaign_dir: Any, project_dir: Any, config: Optional[ConfigInfo] = None,
        maps: Optional[Dict[str, MapInfo]] = None) -> int:
    """界面入口：载入一个战役目录并开窗。

    @return 进程退出码（0 = 正常退出；2 = 载入失败，原因已经弹过框）
    """
    project_dir = Path(project_dir)
    try:
        model = levelfile.load_campaign(campaign_dir, project_dir)
    except ModelError as exc:
        print("[error] %s" % exc)
        try:
            root = tk.Tk()
            root.withdraw()
            messagebox.showerror("载入失败", str(exc))
            root.destroy()
        except tk.TclError:
            pass
        return 2
    root = tk.Tk()
    app = EditorApp(root, model, project_dir, config, maps)
    root.mainloop()
    return 0


#: 别名：另两个编辑器管主类叫 `EditorApp`，这里也留一个 `CampaignEditorApp` 方便外部引用。
CampaignEditorApp = EditorApp
