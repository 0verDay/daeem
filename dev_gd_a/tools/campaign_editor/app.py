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
               **开局编制（逐将带几个兵）** / 进攻目标 / 「高级」AI 参数；玩家席位单独一栏
    ④ 摆放    画布（点一下放东西、右键删、滚轮缩放、中键或**空格 + 左键拖动**平移、
               【设进攻目标】模式）
    ⑤ 校验与导出 16+4 条逐条显示；有拦截就不许写文件；一键打开地图编辑器

★★ 摆放页**就是**开局部队的全部真相：地图上摆了什么，进游戏就有什么。
   那 3 位将领与它们的附属兵都**在这里摆**（画笔选「将领」/「附属兵」，
   附属兵还要选它**属于哪位将领**）；`config.json` 里已经没有任何「开局带几个兵」的开关了。
   ⚠️ 唯一的「看不到的东西」：某一方**一个附属兵都没摆**时，运行时会替它自动生成 3 位将领
      （历史行为，自由对战地图也靠它）；**只要摆了任何附属兵，运行时就整个不管这一方** ——
      连将领也得你自己摆。这条规则写在摆放页的侧栏提示里。

★★ 界面上必须写清楚的那条分工（不是只写在 README 里）：
    「地形 / 区划 / 中心从地图读出来画成背景；要改地形请点『打开地图编辑器』」
    —— 见 `CANVAS_HINT`，它印在 ④ 摆放页的画布上方。

★ 「进攻目标」在 ③（下拉）与 ④（点画布）两处都能改，**底层是同一个字段**
  （`LevelModel.factions[i].attack_target`）——所以两边都走 `set_attack_target()`，
  改完统一 `_after_change()` 重建界面；这是最容易写出不一致的地方。

★ 画布手势照 `map_editor/app.py`：滚轮以光标为锚点缩放、中键拖动（或**空格 + 左键拖动**）
  平移、右键删除。唯一的有意差异是 **左键单击**：那边是「涂地形」，这边是「放东西 / 选中」。

★ 平移有两种按法，**中键**与**空格 + 左键**：后者是给没有中键的机器（触控板 / 笔记本）
  留的路，也是用户点名要的那条手势。它由 `space_held` + `_pan_anchor` 两个状态表达，
  按下与拖动都在 `on_left_down` / `on_left_drag` / `on_motion` 三处分派 ——
  **不能只绑 `<B1-Motion>`**（tk 不保证拖动期间发的是它，见 `BUTTON1_MASK` 那段注释）。
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
    AI_GARRISON,
    AI_REDDOT,
    AI_KINDS,
    AI_NONE,
    ESCORT_OF_KEY,
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

#: 「属于将领」下拉里表示「不是附属兵」的那一项（普通摆放单位）。
ESCORT_NONE_LABEL = "（不是附属兵）"


def _fmt_num(v: Any) -> str:
    """数字写成好看的字符串（整数不带 `.0`）—— 输入框初值用。"""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    return str(int(f)) if f == int(f) else str(f)


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

#: 七个页签：key → （按钮文字，状态栏提示）。
PAGES: Tuple[Tuple[str, str, str], ...] = (
    ("campaign", "战役", "战役页：名字 / 简介 / 默认模式 / 关卡顺序（上下箭头排、增删关卡）"),
    ("level", "关卡", "关卡页：当前关的名字 / 模式 / 地图 / 目标 / 额外失败条件"),
    ("factions", "阵营与AI", "阵营页：每一方的 AI 指派 / 大本营 / 进攻目标；玩家席位单独一栏"),
    ("place", "摆放", "摆放页：画布上点一下放将领/单位/建筑；右键删；滚轮缩放；中键或空格+左键拖动；「设进攻目标」模式"),
    ("zone", "区划", "区划页：开局每一块地归哪个阵营（关卡覆盖地图的 zone_list[].owner）"),
    ("reddot", "红点", "红点页：选生成地块 / 生成频率与将领数（函数表达式）/ 将领类型权重 / 共享附属单位规格"),
    ("check", "校验与导出", "校验页：跑全部硬拦截 + 警告；有拦截时不许写文件"),
)

#: ★★ 分工说明（印在摆放页的画布上方，**不能只写在 README 里**）。
CANVAS_HINT = ("地形 / 区划 / 中心是从地图读出来画成**背景**的；要改地形、区划或中心，"
               "请点本页的『打开地图编辑器』。")

#: 红点页画布上方那句话（红点页复用同一块画布，但手势含义不同）。
REDDOT_CANVAS_HINT = ("左键点一个**空地格** = 把它加进 / 移出「红点生成地块」"
                      "（游戏里这些格子的外观**不会有任何区别**）；右键点 = 移出。")

#: 按住空格时印在状态栏上的话（`on_space_down` 用；测试也读它，别在测试里再拼一遍）。
PAN_MODE_HINT = ("平移模式：按住空格 + 左键拖动 = 移动视野（松开空格回到「放东西 / 选中」；"
                 "中键拖动同样能平移）")

#: 1 格在 100% 缩放下的像素（与 map_editor 的 CELL_PX 同一量级）。
CELL_PX = 30.0
MIN_ZOOM = 0.35
MAX_ZOOM = 4.0
ZOOM_STEP = 1.12

#: 左键按下到抬起之间，移动超过这个像素数就当成「拖动」而不是「点击」。
#: ★ 判据是**两个像素坐标**，不是「拖过几次事件」：手抖一两像素不该被当成拖动
#:   （否则空格 + 左键轻点想放东西，会变成平移）。与 `map_editor` 同一个常量值。
DRAG_TOLERANCE = 3

#: tk 事件里「左键按住」那一位。
#:
#: ★★ 为什么要看它：**tk 不保证拖动期间发的是 `<B1-Motion>`**（实测：带 B1 位的
#:    `<Motion>` 走的是 `<Motion>` 那条绑定）。所以「空格 + 左键拖动」这件事不能只靠
#:    绑在 `<B1-Motion>` 上的那个回调 —— 漏了它，拖动看起来就是「没反应」。
#:    与 `map_editor/app.py` 里那个同名常量是同一件事（两个编辑器的手势要一致）。
BUTTON1_MASK = 0x0100

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
    #: 附属部队与它的将领之间的虚线。
    "escort_link": "#7fd4a0",
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
        #: ★★ 附属兵画笔：「这个兵属于第几位将领」（1 起）。只对 `brush_kind == "escort"` 有意义。
        self.brush_escort_of = 1
        #: 摆放页选中的东西：("unit"|"building", 下标)。
        self.selection: Optional[Tuple[str, int]] = None
        #: 「设进攻目标」模式：选中的阵营 id（None = 不在这个模式里）。
        self.target_mode_faction: Optional[str] = None
        #: ★★ 红点页当前编辑的阵营（红点生成配置挂在它的 `reddot_ai` 上）。
        self.reddot_faction: str = ""
        #: 画布视口（与 map_editor 同一套：zoom + ox/oy 像素偏移）。
        self.zoom = 1.0
        self.ox = 0.0
        self.oy = 0.0
        self._pan_anchor: Optional[Tuple[int, int]] = None
        #: ★ 按住空格 = 进入平移模式（左键拖动移视野，不再放东西 / 选中）。
        #:   名字与 `map_editor` 一致，测试也读它。
        self.space_held = False
        #: 左键**按下**时的像素位置（`on_left_down` 记、`on_left_up` 读）：
        #: 用来把「单击」与「拖动了几像素」分开，见 `DRAG_TOLERANCE`。
        self._left_down_at: Optional[Tuple[int, int]] = None
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
        """统一造按钮：一律 `takefocus=0`（否则空格会去「按」最后点过的按钮），
        并在点完之后把键盘焦点交还画布。

        ★★ 为什么要交还焦点：tk 的按钮**点过之后会拿住键盘焦点**（`takefocus=0` 只影响
           Tab 键遍历，不影响鼠标点击），而**空格在 tk 里是「激活当前焦点控件」** ——
           于是「按住空格拖画面」会变成「反复点最后按过的那颗按钮」（页签乱跳）。
           与 `map_editor/app.py` 里那颗按钮是同一套做法。
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

        def wrapped() -> None:
            self._focus_canvas()
            command()

        return tk.Button(parent, text=text, command=wrapped, **kw)

    def _focus_canvas(self) -> None:
        """把键盘焦点交还给摆放页的画布（别的页签上没有画布 → 什么都不做）。

        没有它，「按住空格 + 左键拖动」这条手势会在点过任何按钮之后静默失效。
        """
        canvas = getattr(self, "canvas", None)
        if canvas is None or self.page != "place":
            return
        try:
            canvas.focus_set()
        except tk.TclError:
            pass

    def _set_cursor(self, cursor: str) -> None:
        """给画布换鼠标指针（`""` = 默认；平移模式给 `fleur`，一眼看出「现在能拖」）。"""
        canvas = getattr(self, "canvas", None)
        if canvas is None:
            return
        try:
            canvas.configure(cursor=cursor or "")
        except tk.TclError:
            pass

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
        # ★ 换页签 = 丢掉上一页的「正在拖 / 按着空格」状态：画布会被整块重建，
        #   留着锚点会让新画布一进来就跟着鼠标跑（`_pan_anchor` 指着一个不存在的按下）。
        self._pan_anchor = None
        self._left_down_at = None
        self.space_held = False
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
        if self.page in ("place", "reddot"):
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
        elif self.page == "zone":
            self._build_zone_page()
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
        hint = CANVAS_HINT if self.page == "place" else REDDOT_CANVAS_HINT
        tk.Label(head, text=hint, bg=UI["bg"], fg=UI["warn"], justify="left",
                 font=("Microsoft YaHei UI", 9)).pack(side="left")
        self._button(head, "打开地图编辑器", self.open_map_editor,
                     padx=10).pack(side="right")

        self.canvas = tk.Canvas(self.canvas_host, bg=UI["canvas_bg"], highlightthickness=0,
                                bd=0, takefocus=1)
        self.canvas.pack(side="top", fill="both", expand=True, padx=10, pady=(2, 4))
        self.canvas.bind("<Button-1>", self.on_left_down)
        self.canvas.bind("<B1-Motion>", self.on_left_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_left_up)
        self.canvas.bind("<Button-3>", self.on_right_click)
        self.canvas.bind("<Button-2>", self.on_middle_down)
        self.canvas.bind("<B2-Motion>", self.on_middle_drag)
        self.canvas.bind("<ButtonRelease-2>", self.on_middle_up)
        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<Leave>", self.on_leave)
        self.canvas.bind("<MouseWheel>", self.on_wheel)
        # ★ 空格 = 平移模式（按住空格 + 左键拖动）。绑在**画布**上：焦点在别处时不算，
        #   免得用户在侧边栏输入框里打空格却把画布切进了平移模式（`on_space_down` 还会
        #   再挡一道输入框）。
        self.canvas.bind("<KeyPress-space>", self.on_space_down)
        self.canvas.bind("<KeyRelease-space>", self.on_space_up)

        bar = self.action_bar
        tk.Label(bar, text="缩放", bg=UI["bg"], fg=UI["text_dim"]).pack(side="left")
        self._button(bar, "－", lambda: self.zoom_by(1 / ZOOM_STEP)).pack(side="left", padx=2)
        self._button(bar, "＋", lambda: self.zoom_by(ZOOM_STEP)).pack(side="left", padx=2)
        self._button(bar, "适应视图", self.fit_view).pack(side="left", padx=6)
        if self.page == "place":
            self.target_button = self._button(bar, "设进攻目标…", self.do_target_mode,
                                              bg="#3a3220", fg=UI["warn"])
            self.target_button.pack(side="left", padx=10)
            bar_hint = ("左键放 / 选　右键删（大本营不在这里删）　"
                        "中键或空格+左键拖动平移　滚轮缩放　Esc 退出目标模式")
        else:
            bar_hint = ("左键点空地 = 加/移出红点生成地块　右键 = 移出　"
                        "中键或空格+左键拖动平移　滚轮缩放")
        tk.Label(bar, text=bar_hint, bg=UI["bg"], fg=UI["text_dim"],
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
        if not hasattr(self, "canvas") or self.page not in ("place", "reddot"):
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
                # ★★ 建筑**所见即所得**：按类型画不同的形状（城墙 = 线段、箭塔 = 圆点、
                #    大本营 = 方块），不再是统一的「建」字 —— 一眼认出摆的是什么。
                self._draw_building_marker(b, self.faction_color(b.owner), ("building", i))
            # ★★ 附属部队先画「它属于哪位将领」的连线（画在方块下面）——
            #    这是「所见即所得」那条要求在本页的落点：一眼能看出哪个兵跟着谁。
            for i, u in enumerate(lv.start_units):
                if not u.is_escort():
                    continue
                leader = self._leader_of(lv, u)
                if leader is None:
                    continue                     # 序号越界（校验会拦），不画假线
                lx, ly = self.cell_origin(leader.x + 0.5, leader.y + 0.5)
                ux, uy = self.cell_origin(u.x + 0.5, u.y + 0.5)
                self.canvas.create_line(lx, ly, ux, uy, fill=C["escort_link"],
                                        width=2, dash=(3, 3))
            for i, u in enumerate(lv.start_units):
                if u.is_general():
                    glyph, tag = "将", "将"
                elif u.is_escort():
                    glyph, tag = "兵", "属"       # 「属」= 它是某个将领的附属部队
                else:
                    glyph, tag = "兵", "兵"
                self._draw_cell_marker(u.point(), glyph, self.faction_color(u.faction),
                                       ("unit", i), corner=tag if tag != glyph else "")

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

        # ---- 红点生成地块（只红点页画；游戏里这些格子外观**没有任何区别**）----
        if self.page == "reddot":
            for (tx, ty) in self.reddot_spawn_tiles():
                sx, sy = self.cell_origin(tx, ty)
                self.canvas.create_rectangle(sx + 3, sy + 3, sx + size - 3, sy + size - 3,
                                             outline=C["arrow"], width=2, dash=(3, 2))
                self.canvas.create_text(sx + size / 2, sy + size / 2, text="点",
                                        fill=C["arrow"], font=("Microsoft YaHei UI", 8))

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
                          tag: Tuple[str, int], corner: str = "") -> None:
        size = self.tile_px()
        sx, sy = self.cell_origin(point[0], point[1])
        pad = max(2.0, size * 0.16)
        self.canvas.create_oval(sx + pad, sy + pad, sx + size - pad, sy + size - pad,
                                fill=color, outline="")
        self.canvas.create_text(sx + size / 2, sy + size / 2, text=glyph, fill="#101010",
                                font=("Microsoft YaHei UI", max(7, int(size * 0.3)), "bold"))
        # ★ 右上角的小记号（目前只有「属」= 这个兵是某个将领的附属部队）。
        #   为什么不换掉中间那个字：「兵 / 将」是**单位性质**（决定它是什么），
        #   附属关系是**附加信息**，两者要能同时看见。
        if corner and size >= 16:
            self.canvas.create_text(sx + size - pad * 0.9, sy + pad * 0.9, text=corner,
                                    fill="#101010", anchor="ne",
                                    font=("Microsoft YaHei UI", max(7, int(size * 0.22))))
        if self.selection == tag:
            self.canvas.create_rectangle(sx + 1, sy + 1, sx + size - 1, sy + size - 1,
                                         outline=C["select"], width=2)

    def _draw_building_marker(self, b: BuildingEntry, color: str,
                              tag: Tuple[str, int]) -> None:
        """★ 建筑的**所见即所得**画法：按类型画不同形状 + 归属色。

        · 城墙 = 一条横贯整格的**粗线**（本体就是整格）；
        · 箭塔 = 居中的**实心圆**（本体比一格小一圈）；
        · 大本营 = 居中的**方块**（本体比一格小一圈）；
        · 其它类型（自定义建筑）→ 退回「圆盘 + 类型首字」（与单位同一种画法）。
        """
        size = self.tile_px()
        sx, sy = self.cell_origin(b.x, b.y)
        t = str(b.type)
        if t == "wall":
            self.canvas.create_line(sx + 2, sy + size / 2, sx + size - 2, sy + size / 2,
                                    fill=color, width=max(3, int(size * 0.14)))
        elif t == "tower":
            pad = size * 0.28
            self.canvas.create_oval(sx + pad, sy + pad, sx + size - pad, sy + size - pad,
                                    fill=color, outline="#101010")
        elif t == "base":
            pad = size * 0.22
            self.canvas.create_rectangle(sx + pad, sy + pad, sx + size - pad, sy + size - pad,
                                         fill=color, outline="#101010")
        else:
            self._draw_cell_marker((b.x, b.y), (t[:1] or "建"), color, tag)
            return
        if self.selection == tag:
            self.canvas.create_rectangle(sx + 1, sy + 1, sx + size - 1, sy + size - 1,
                                         outline=C["select"], width=2)

    def _escort_suffix(self, lv: LevelModel, u: UnitEntry) -> str:
        """状态栏 / 列表里那个「（属于 将领 2）」后缀；不是附属兵就返回空串。"""
        if not u.is_escort():
            return ""
        return "（属于 %s）" % self._escort_label(u)

    def _leader_of(self, lv: LevelModel, u: UnitEntry) -> Optional[UnitEntry]:
        """这个附属兵的带队将领（按「同阵营 + 将领序号」找，与运行时同一套判据）。

        找不到（序号对不上 / 那位将领被删了）→ None：校验会拦（`escort_no_general`），
        这里只负责不要画出指向空气的连线。
        """
        if not u.is_escort():
            return None
        return model_mod.general_with_index(lv, str(u.faction), int(u.escort_of))

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
        # ★★ 先分派「按着左键在动」这件事 —— 它**不能**只靠绑在 `<B1-Motion>` 上的回调：
        #   tk 在拖动期间不保证发 `<B1-Motion>`（实测：带 B1 位的 `<Motion>` 走的是
        #   `<Motion>` 这条绑定）。漏了它，「空格 + 左键拖动」看起来就是没反应。
        state = getattr(event, "state", 0)
        if self._pan_anchor is not None or (self.space_held and state & BUTTON1_MASK):
            self.on_left_drag(event)
            return
        cell = self.screen_to_cell(event.x, event.y)
        self.hover = cell
        self.update_status(cell)
        self.request_redraw()

    def on_leave(self, _event=None) -> None:
        self.hover = None
        self.request_redraw()

    # ---- 平移：中键拖动 / 空格 + 左键拖动 ----

    def _start_pan(self, event) -> None:
        """这次按下是「拖画面」，不是「放东西 / 选中」。"""
        self._pan_anchor = (event.x, event.y)
        self.hover = None               # 平移时不留高亮：鼠标底下那一格一直在换
        self._set_cursor("fleur")
        self.request_redraw()

    def on_middle_down(self, event) -> None:
        self._start_pan(event)

    def on_middle_drag(self, event) -> None:
        self.on_left_drag(event)

    def on_middle_up(self, _event=None) -> None:
        self._end_pan()

    def _end_pan(self) -> None:
        self._pan_anchor = None
        self._set_cursor("fleur" if self.space_held else "")

    def on_left_down(self, event) -> None:
        """左键按下：空格按住 → 武装一次平移；否则记下起点，等松手时再决定「点 / 拖」。"""
        if self.page not in ("place", "reddot"):
            return
        self._left_down_at = (event.x, event.y)
        try:
            self.canvas.focus_set()     # 空格要靠画布拿住键盘焦点才收得到
        except tk.TclError:
            pass
        if self.space_held:
            self._start_pan(event)
            return
        # 不是平移：这里**什么都不做** —— 放东西 / 选中都留到 `on_left_up`
        # （这样「按下之后拖了两像素又松开」不会被误当成点击，见 DRAG_TOLERANCE）。
        self._pan_anchor = None

    def on_left_drag(self, event) -> None:
        """拖动中：`_pan_anchor` 有值 = 正在平移（中键或空格 + 左键都走这里）。"""
        if self._pan_anchor is None:
            return
        self.ox += event.x - self._pan_anchor[0]
        self.oy += event.y - self._pan_anchor[1]
        self._pan_anchor = (event.x, event.y)
        self.hover = None
        self.request_redraw()

    def on_left_up(self, event) -> None:
        was_panning = self._pan_anchor is not None
        self._end_pan()
        start = self._left_down_at
        self._left_down_at = None
        if was_panning:
            return                      # ★ 拖过画面了：这一次不算「点」（不放东西、不改选中）
        if start is None:
            return                      # 没配对上按下（按下时不在这一页）：不猜，丢弃
        if abs(event.x - start[0]) > DRAG_TOLERANCE or abs(event.y - start[1]) > DRAG_TOLERANCE:
            return                      # 手抖拖了几像素：不当地点击处理
        self.on_left_click(event)
        # ★ 放东西 / 选中都会 `refresh_all()` —— 画布被整块销毁重建，键盘焦点跟着没了。
        #   不补这一下，用户「摆一个 → 按住空格拖」时空格就收不到了（第三条手势静默失效）。
        self._focus_canvas()

    def on_space_down(self, event) -> None:
        """按住空格 = 进入平移模式（左键拖动移视野，不再放东西 / 选中）。"""
        if self._typing_in_entry():
            return                      # 正在输入框里打字（关卡名 / 坐标），别抢
        if self.space_held:
            return "break"
        self.space_held = True
        self._set_cursor("fleur")
        self.status(PAN_MODE_HINT)
        return "break"                  # 别让空格顺带「按」了当前焦点里的那颗按钮

    def on_space_up(self, _event=None) -> None:
        if not self.space_held:
            return None
        self.space_held = False
        self._set_cursor("")
        self.update_status(self.hover)
        return "break"

    def _typing_in_entry(self) -> bool:
        """键盘焦点现在在某个能打字的控件里吗（空格该给文字，不该给画布）。"""
        try:
            focus = self.root.focus_get()
        except (tk.TclError, KeyError):    # 窗口还没映射时 focus_get 会抛
            return False
        if focus is None:
            return False
        return isinstance(focus, (tk.Entry, tk.Text, ttk.Entry, ttk.Combobox))

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
        """左键**点一下**（按下与松开之间没怎么动，由 `on_left_up` 判定后才走到这里）。

        ⚠️ `on_left_down` 里已经拦掉了「空格 + 拖动」：走到这里的都已经不是平移，
           所以这里只看「目标模式 / 选中 / 放东西」三件事。
        """
        if self.page not in ("place", "reddot"):
            return
        cell = self.screen_to_cell(event.x, event.y)
        if self.page == "reddot":
            self._toggle_reddot_tile(cell)
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
        if self.page not in ("place", "reddot"):
            return
        cell = self.screen_to_cell(event.x, event.y)
        if self.page == "reddot":
            self._toggle_reddot_tile(cell, force_remove=True)
            self._focus_canvas()
            return
        hit = self._hit_test(cell)
        if hit is None:
            self.status("(%d,%d) 上没有可删的东西（大本营在「阵营与AI」页里改）" % cell)
            return
        self.delete_entry(hit)
        self._focus_canvas()            # 同上：重建之后把键盘焦点交回新画布

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
                    what.append("单位 %s/%s%s" % (u.faction, u.kind,
                                                 self._escort_suffix(lv, u)))
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
                # ★★ 新摆的将领序号 = 这一方已有将领的**最大序号 + 1**（1 起）——
                #    与运行时「第 i 位将领」的编号必须同一套。
                #    ⚠️ 不能用「已有几位 + 1」：作者可能把序号改成 1/3 之后再摆一位。
                used = [int(g.general_index or 1) for g in
                        model_mod.placed_generals(lv, faction)]
                entry.general_index = (max(used) + 1) if used else 1
                gtypes = self.config.general_types or [""]
                entry.unit_type = gtypes[min(entry.general_index - 1, len(gtypes) - 1)]
                # ★★ 附属单位规格的初始值：数量 0（光杆 —— 作者自己去侧栏填），
                #    类型 = 自己这一档（一条权重 1 的行，改起来最省事）。
                entry.escort_count = 0
                entry.escort_types = ([{"type": entry.unit_type, "weight": 1}]
                                      if entry.unit_type else [])
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
        """跑一遍校验，把结果显示在这一页上，并返回问题列表。

        ⚠️ 表格控件可能**已经不存在**：换页时侧栏 / 主体会被重建、
        `issue_tree` 也随之销毁，而 `do_save()` 与测试都会在**别的页**上调这个函数。
        所以整段填表都要防 TclError（只给 delete 加保护是不够的 —— 实测踩到：
        在摆放页调它，`insert` 撞上 `invalid command name`，直接把调用方打崩）。
        """
        issues = model_mod.validate_campaign(self.model, self.maps, self.config)
        self.last_issues = issues
        try:
            if hasattr(self, "issue_tree") and self.issue_tree.winfo_exists():
                self.issue_tree.delete(*self.issue_tree.get_children())
                for i, issue in enumerate(issues):
                    self.issue_tree.insert(
                        "", "end", iid="issue:%d" % i,
                        values=(issue.label(), issue.code, issue.where, issue.msg),
                        tags=(issue.sev,))
        except tk.TclError:
            pass
        blocks = model_mod.blockers(issues)
        warns = model_mod.warnings(issues)
        try:
            if hasattr(self, "check_summary") and self.check_summary.winfo_exists():
                if blocks:
                    self.check_summary.configure(
                        text="拦截 %d 条、警告 %d 条 —— **有拦截项，不许写文件**；"
                             "修好它们再回来。" % (len(blocks), len(warns)), fg=UI["bad"])
                else:
                    self.check_summary.configure(
                        text="通过：0 条拦截、%d 条警告（警告不挡导出）" % len(warns), fg=UI["ok"])
        except tk.TclError:
            pass
        return issues

    def do_save(self) -> None:
        """写文件：**有拦截就不写**（这是 dev_plan_7 2.5 的硬要求）。"""
        issues = model_mod.validate_campaign(self.model, self.maps, self.config)
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
        elif field == "garrison_ai":
            entry.garrison_ai = value
        elif field == "reddot_ai":
            entry.reddot_ai = value
        elif field == "spawn_region":
            entry.spawn_region = value
        elif field == "base":
            entry.base = value
        elif field == "color":
            entry.color = str(value)
            self.model.ensure_faction(fid, fid, str(value))["color"] = str(value)
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
            elif self.page == "zone":
                self._sidebar_zone()
            elif self.page == "reddot":
                self._sidebar_reddot()
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
            # ---- ★★ 开局附属兵在这里摆（不在「阵营与AI」页，也不再由 config 决定）----
            self._hint(section, "★ 开局带几个附属兵：**去「摆放」页一个一个摆**（画笔选「附属兵」，"
                                "放到地上并选它属于哪位将领）。没摆 = 这一关这一方开局没有附属兵；"
                                "摆了任何附属兵 = 运行时**整个接管这一方**（连 3 位将领也得你自己摆）。")
            self._target_rows(section, fid, e)
            if e.ai == AI_REDDOT:
                self._spawn_rows(section, fid, e)

            # ---- 「高级」AI 参数（缺省 = 继承 config）----
            adv = tk.Frame(section, bg=UI["panel"])
            adv.pack(side="top", fill="x", pady=(4, 0))
            toggle = self._button(adv, "高级 AI 参数 ▾", lambda a=adv: self._toggle_advanced(a))
            toggle.pack(anchor="w")
            body = tk.Frame(section, bg=UI["panel"])
            body.pack(side="top", fill="x")
            body.visible = False                      # type: ignore[attr-defined]
            gdefaults = ", ".join("%s=%s" % (k, v) for k, v in
                                  sorted(self.config.ai_garrison_cfg.items()))
            self._hint(body, "阵地性 AI 推荐区间（缺省 = 继承 config）：%s" % (gdefaults or "（config 里没写）"))
            ga = e.garrison_ai or {}
            for key in ("patrol_interval_sec", "patrol_leash_tiles", "combat_idle_sec",
                        "retarget_cooldown_sec", "recruit_check_sec", "min_retinue"):
                inherit = self.config.ai_garrison_cfg.get(key, "")
                self._entry_cell(body, key, "" if key not in ga else "%g" % ga[key],
                                 lambda text, f=fid, k=key: self._set_ai_param(f, "garrison_ai",
                                                                               k, text))
                self._hint(body, "　缺省 = %s" % (inherit if inherit != "" else "（config 里没写）"))
            rdefaults = ", ".join("%s=%s" % (k, v) for k, v in
                                  sorted(self.config.ai_reddot_cfg.items()))
            self._hint(body, "红点性 AI 推荐区间（缺省 = 继承 config）：%s" % (rdefaults or "（config 里没写）"))
            ra = e.reddot_ai or {}
            for key in ("cooldown_sec", "generals", "retinue", "spawn_radius", "waves"):
                inherit = self.config.ai_reddot_cfg.get(key, "")
                self._entry_cell(body, "红点·%s" % key,
                                 "" if key not in ra else "%g" % ra[key],
                                 lambda text, f=fid, k=key: self._set_ai_param(f, "reddot_ai",
                                                                               k, text))
                self._hint(body, "　缺省 = %s" % (inherit if inherit != "" else "（config 里没写）"))
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

    def _spawn_rows(self, parent, fid: str, e: FactionEntry) -> None:
        """红点生成区域：一个下拉 + 载荷（出生点缺省 / 指定区划 / 指定格）。"""
        spec = e.spawn_region
        kind = str(spec.get("kind", "")) if spec else ""
        label = {"": "出生点（缺省）", TARGET_ZONE: "指定区划",
                 TARGET_POINT: "指定格"}.get(kind, "不认识")
        self._combo_cell(parent, "生成区域", label,
                         ("出生点（缺省）", "指定区划", "指定格"),
                         lambda text, f=fid: self._set_spawn_kind(f, text))
        if kind == TARGET_ZONE:
            self._combo_cell(parent, "　生成区划", self._zone_label(int(spec.get("zone", -1))),
                             self._zone_choices(),
                             lambda text, f=fid: self.set_spawn_region(
                                 f, {"kind": TARGET_ZONE, "zone": self._zone_id_from_label(text)}))
        elif kind == TARGET_POINT:
            self._entry_cell(parent, "　中心 x,y",
                             "%d,%d" % (int(spec.get("x", -1)), int(spec.get("y", -1))),
                             lambda text, f=fid: self._set_spawn_point(f, text))
        self._hint(parent, "留空 = 用这一方的出生点 + config 半径；红点每波在这里刷将领")

    def _set_spawn_kind(self, fid: str, label: str) -> None:
        if label.startswith("出生点"):
            self.set_spawn_region(fid, None)
        elif label == "指定区划":
            info = self.map_info()
            zid = info.zone_ids[0] if info is not None and info.zone_ids else -1
            self.set_spawn_region(fid, {"kind": TARGET_ZONE, "zone": int(zid)})
        else:
            self.set_spawn_region(fid, {"kind": TARGET_POINT, "x": 0, "y": 0})

    def _set_spawn_point(self, fid: str, text: str) -> None:
        point = _parse_point(text)
        if point is None:
            self.status("坐标要写成 `x,y`")
            self.refresh_all()
            return
        self.set_spawn_region(fid, {"kind": TARGET_POINT, "x": point[0], "y": point[1]})

    def set_spawn_region(self, fid: str, spec: Optional[dict]) -> None:
        """红点生成区域的唯一入口（与进攻目标同构的字段）。"""
        lv = self.level()
        if lv is None:
            return
        entry = lv.ensure_faction(fid)
        entry.spawn_region = spec
        self._after_change()

    def _ai_label(self, ai: str) -> str:
        return {AI_NONE: "无", AI_GARRISON: "阵地性", AI_REDDOT: "红点性"}.get(ai, "无")

    def _ai_value(self, label: str) -> str:
        return {"无": AI_NONE, "阵地性": AI_GARRISON, "红点性": AI_REDDOT}.get(label, AI_NONE)

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
                                   values=("将领" if u.is_general() else
                                           ("附属兵" if u.is_escort() else "单位"),
                                           "%s/%s%s" % (u.faction, u.kind,
                                                        self._escort_suffix(lv, u)),
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
                # ★★ 附属单位规格（本轮新增）：生成数量 + 兵种权重表。
                self._spec_editor(sec, unit)
            else:
                # ★★ 附属部队：这个兵属于哪位将领（`escort_of`）。
                #    只列**这一方真的摆了**的将领 —— 运行时按「同阵营 + 序号」找队长。
                self._combo_cell(sec, "属于将领", self._escort_label(unit),
                                 self._escort_choices(unit.faction),
                                 lambda text: self._set_unit_escort(text))
                self._hint(sec, "★ 选了将领 = 这个兵是它的**附属部队**（点一个选中整队、"
                                "将领濒死时它去集结）；选「（不是附属兵）」= 它就是普通摆放单位。")
            self._entry_cell(sec, "x,y", "%d,%d" % (unit.x, unit.y),
                             lambda text: self._set_unit_point(text))
            # ★★ 阵地性 AI 的**归属区划**：改成**下拉**（列出当前地图里的每一个区划），
            #    值就是区划**编号**。以前是一个裸数字输入框 —— 用户填 `c1` 这种名字会被
            #    解析成 -1（「怎么改都变 -1」），而地图上区划显示的正是那种名字。
            self._combo_cell(sec, "区划", self._zone_label(unit.zone),
                             self._zone_choices(),
                             lambda text: self._set_unit_field(
                                 "zone", self._zone_id_from_label(text)))
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
        return {"unit": "单位", "general": "将领",
                "building": "建筑"}.get(self.brush_kind, "单位")

    def _set_brush_kind(self, label: str) -> None:
        self.brush_kind = {"单位": "unit", "将领": "general",
                           "建筑": "building"}.get(label, "unit")
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
        self.refresh_all()

    def _set_brush_faction(self, text: str) -> None:
        self.brush_faction = str(text)
        self.status("画笔归属：%s" % self.brush_faction)
        self.refresh_all()

    # ==================================================================
    # ★★ 附属单位规格编辑器（将领：生成数量 + 兵种权重表）
    # ==================================================================

    def _spec_editor(self, parent, unit: UnitEntry) -> None:
        """给选中的**将领**编辑它的附属单位规格（`escort_count` / `escort_types`）。

        · 数量：一个数字输入框（≤ 这位将领的编制上限，实时红字提示）；
        · 权重表：可变长度行（每行 = 兵种下拉 + 权重输入 + 「－」），下面一个「＋」；
        · 实时显示权重和（≠1 时红字提示 —— 校验会拦，这里先给眼睛看到）。
        """
        box = self._section("附属单位规格",
                            "运行时**当场随机生成**满编附属兵（类型按权重抽、数量 ≤ 编制上限）")
        cap = self.config.general_cap(int(unit.general_index or 1))
        self._entry_cell(box, "生成数量", str(int(unit.escort_count)),
                         lambda text: self._set_escort_count(unit, text))
        self._hint(box, "编制上限 = %d（在单位编辑器的「将领」页改）；"
                        "阵地 AI 脱战后也按这份规格补员。" % cap)

        tk.Label(box, text="兵种 / 权重", bg=UI["panel"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="top", anchor="w", pady=(4, 0))
        for i, row in enumerate(unit.escort_types):
            r = tk.Frame(box, bg=UI["panel"])
            r.pack(side="top", fill="x", pady=1)
            types = tuple(self.config.unit_types) or ("—",)
            var = tk.StringVar(value=str(row.get("type", "")))
            combo = ttk.Combobox(r, textvariable=var, state="readonly", values=types, width=12)
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>",
                       lambda _e, idx=i, v=var, u=unit: self._set_escort_type(u, idx, v.get()))
            wvar = tk.StringVar(value=_fmt_num(row.get("weight", 0.0)))
            w = ttk.Entry(r, textvariable=wvar, width=6)
            w.pack(side="left", padx=(4, 0))
            w.bind("<Return>", lambda _e, idx=i, v=wvar, u=unit: self._set_escort_weight(u, idx, v.get()))
            w.bind("<FocusOut>", lambda _e, idx=i, v=wvar, u=unit: self._set_escort_weight(u, idx, v.get()))
            self._button(r, "－", lambda idx=i, u=unit: self._remove_escort_row(u, idx),
                         padx=4).pack(side="left", padx=(4, 0))
        self._button(box, "＋ 加一行", lambda u=unit: self._add_escort_row(u)).pack(
            anchor="w", pady=(4, 0))
        total = unit.spec_weight_sum()
        ok = bool(unit.escort_types) and abs(total - 1.0) <= 1e-3
        if not unit.escort_types and int(unit.escort_count) > 0:
            self._hint(box, "★ 设了数量却没有类型权重表 —— 校验会拦（`escort_types_missing`）")
        elif not ok:
            self._hint(box, "★ 权重和 = %.4f（**必须恰好为 1**）—— 校验会拦"
                            "（`escort_weights_sum`）" % total)
        else:
            self._hint(box, "权重和 = 1 ✓")

    def _spec_changed(self, unit: UnitEntry, what: str) -> None:
        unit.declared.add(model_mod.ESCORT_TYPES_KEY)
        lv = self.level()
        if lv is not None:
            lv.mark_declared("start_units")
        self.status(what)
        self.refresh_all()

    def _set_escort_count(self, unit: UnitEntry, text: str) -> None:
        unit.escort_count = max(0, model_mod._as_int(text, 0))
        unit.declared.add(model_mod.ESCORT_COUNT_KEY)
        lv = self.level()
        if lv is not None:
            lv.mark_declared("start_units")
        self.status("附属单位数量 = %d" % unit.escort_count)
        self.refresh_all()

    def _set_escort_type(self, unit: UnitEntry, row: int, type_id: str) -> None:
        if 0 <= row < len(unit.escort_types):
            unit.escort_types[row]["type"] = str(type_id)
            self._spec_changed(unit, "附属单位类型 → %s" % type_id)

    def _set_escort_weight(self, unit: UnitEntry, row: int, text: str) -> None:
        if 0 <= row < len(unit.escort_types):
            unit.escort_types[row]["weight"] = max(0.0, model_mod._as_float(text, 0.0))
            self._spec_changed(unit, "附属单位权重 = %s"
                               % _fmt_num(unit.escort_types[row]["weight"]))

    def _add_escort_row(self, unit: UnitEntry) -> None:
        default = self.config.unit_types[0] if self.config.unit_types else ""
        unit.escort_types.append({"type": default, "weight": 0})
        self._spec_changed(unit, "加了一行附属单位类型")

    def _remove_escort_row(self, unit: UnitEntry, row: int) -> None:
        if 0 <= row < len(unit.escort_types):
            del unit.escort_types[row]
            self._spec_changed(unit, "删了一行附属单位类型")

    # ==================================================================
    # ★★ 区划页：开局归属
    # ==================================================================

    def _owner_choices(self) -> Tuple[str, ...]:
        """区划页的「归属」下拉：用地图的 / 各阵营 / 清空。

        ⚠️ 名字**不能**叫 `_zone_choices`：那个是「列出地图里的各区划」（目标 / 失败条件 /
        单位 `zone` 三处用它），两个同名方法在 Python 里**后一个会盖掉前一个**（实测踩到）。
        """
        return tuple(["（用地图的）"] + [str(f) for f in self.all_faction_ids()]
                     + ["（清空 = 无主）"])

    def _zone_choice_label(self, lv: LevelModel, zid: int) -> str:
        cur = lv.zone_owner(zid)
        if cur is None:
            return "（用地图的）"
        return "（清空 = 无主）" if cur == "" else str(cur)

    def _build_zone_page(self) -> None:
        """区划页：一张表 —— 每一块地开局归哪个阵营（写 `zones[].owner`）。

        ★ 「不选」= 用地图自带的归属（不写这个键）与「清空 = 无主」（写空串）是两件事。
        """
        for child in self.action_bar.winfo_children():
            child.destroy()
        host = self.list_host
        for child in host.winfo_children():
            child.destroy()
        info = self.map_info()
        lv = self.level()
        if info is None or lv is None:
            tk.Label(host, text="这一关还没有地图（或地图不存在）：去「关卡」页选一张",
                     bg=UI["bg"], fg=UI["warn"]).pack(anchor="w", padx=10, pady=10)
            return
        head = tk.Frame(host, bg=UI["bg"])
        head.pack(side="top", fill="x", padx=10, pady=(8, 2))
        tk.Label(head, text="开局区划归属", bg=UI["bg"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 10, "bold")).pack(side="left")
        tk.Label(head, text="　（不选 = 用地图自带的；「清空 = 无主」写空串）",
                 bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left")

        rows = tk.Frame(host, bg=UI["bg"])
        rows.pack(side="top", fill="both", expand=True, padx=10, pady=4)
        canvas = tk.Canvas(rows, bg=UI["bg"], highlightthickness=0, bd=0)
        sb = ttk.Scrollbar(rows, orient="vertical", command=canvas.yview)
        inner = tk.Frame(canvas, bg=UI["bg"])
        inner.bind("<Configure>", lambda _e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=inner, anchor="nw")
        canvas.configure(yscrollcommand=sb.set)
        canvas.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")

        choices = self._owner_choices()
        for zid in info.zone_ids:
            r = tk.Frame(inner, bg=UI["bg"])
            r.pack(side="top", fill="x", pady=1)
            name = info.zone_name(zid)
            tk.Label(r, text="%s　%s" % (info.zone_label(zid), name), width=24, anchor="w",
                     bg=UI["bg"], fg=UI["text"]).pack(side="left")
            var = tk.StringVar(value=self._zone_choice_label(lv, zid))
            combo = ttk.Combobox(r, textvariable=var, values=list(choices), width=18,
                                 state="readonly")
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>",
                       lambda _e, z=int(zid), v=var: self._set_zone_choice(z, v.get()))

    def _set_zone_choice(self, zid: int, label: str) -> None:
        lv = self.level()
        if lv is None:
            return
        if label == "（用地图的）":
            lv.clear_zone_owner(zid)
            self.status("区划 c%d：改回「用地图自带的」" % zid)
        elif label == "（清空 = 无主）":
            lv.set_zone_owner(zid, "")
            self.status("区划 c%d：开局无主" % zid)
        else:
            lv.set_zone_owner(zid, str(label))
            self.status("区划 c%d 开局归「%s」" % (zid, label))
        self.refresh_all()

    def _sidebar_zone(self) -> None:
        lv = self.level()
        info = self.map_info()
        sec = self._section("区划归属", "左边那一列就是本关的全部区划；在右边选归属")
        if lv is None or info is None:
            self._hint(sec, "这一关还没有地图：先到「关卡」页选一张。")
            return
        self._hint(sec, "★ 归属属于**关卡层**（覆盖地图的 `zone_list[].owner`）："
                        "「用地图的」= 不写这个键；「清空 = 无主」= 显式写空串。"
                        "地形 / 区划形状要改请点摆放页的『打开地图编辑器』。")
        count_override = len(lv.zone_owners)
        self._hint(sec, "本关覆盖了 %d 块地的归属。" % count_override)

    # ==================================================================
    # ★★ 红点页：生成配置（挂在当前红点阵营的 `reddot_ai` 上）
    # ==================================================================

    def reddot_faction_id(self) -> str:
        """红点页当前编辑的阵营：优先记着的那个，否则本关第一个红点阵营。"""
        lv = self.level()
        if lv is None:
            return ""
        reddots = [e.fid for e in lv.factions if e.ai == AI_REDDOT]
        if self.reddot_faction in reddots:
            return self.reddot_faction
        return reddots[0] if reddots else ""

    def reddot_params(self, create: bool = False) -> Optional[dict]:
        """当前红点阵营的 `reddot_ai` 覆盖字典（`create=True` 时没有就建一个）。"""
        fid = self.reddot_faction_id()
        lv = self.level()
        if lv is None or not fid:
            return None
        e = lv.faction(fid)
        if e is None:
            return None
        if not isinstance(e.reddot_ai, dict):
            if not create:
                return {}
            e.reddot_ai = {}
            lv.mark_declared("factions")
        return e.reddot_ai

    def reddot_spawn_tiles(self) -> List[Tuple[int, int]]:
        rd = self.reddot_params(False) or {}
        out: List[Tuple[int, int]] = []
        for t in model_mod._as_list(rd.get(model_mod.REDDOT_SPAWN_TILES_KEY)):
            tp = model_mod._tile_of(t)
            if tp is not None:
                out.append(tp)
        return out

    def _toggle_reddot_tile(self, cell: Tuple[int, int], force_remove: bool = False) -> None:
        info = self.map_info()
        if info is not None and (not info.tile_exists(cell[0], cell[1])
                                 or not info.walkable_at(cell[0], cell[1])):
            self.status("(%d,%d) 不能当生成地块：地图外或山地" % cell)
            return
        rd = self.reddot_params(True)
        if rd is None:
            self.status("没有红点阵营：先在「阵营与AI」页给某一方选 ai = 红点性")
            return
        tiles = self.reddot_spawn_tiles()
        if cell in tiles:
            tiles = [t for t in tiles if t != cell]
            action = "移出"
        elif force_remove:
            return
        else:
            tiles.append(cell)
            action = "加入"
        rd[model_mod.REDDOT_SPAWN_TILES_KEY] = [[int(x), int(y)] for x, y in tiles]
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        self.status("%s红点生成地块 (%d,%d)：现在共 %d 个"
                    % (action, cell[0], cell[1], len(tiles)))
        self.refresh_all()

    def _set_reddot_expr(self, key: str, text: str) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        s = str(text).strip()
        if s == "":
            rd.pop(key, None)
        else:
            rd[key] = s
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        ok = model_mod.is_valid_expr(s) if s else True
        self.status("红点 %s = %s%s" % (key, s or "（默认）", "" if ok else "　（解析不了）"))
        self.refresh_all()

    def _reddot_general_weights(self) -> List[float]:
        """3 位将领的权重（缺省 0）；长度 = max(3, 将领类型数)。"""
        rd = self.reddot_params(False) or {}
        by: Dict[int, float] = {}
        for e in model_mod.normalize_weight_list(rd.get(model_mod.REDDOT_GENERAL_WEIGHTS_KEY)):
            by[int(e.get("general", 0))] = float(e.get("weight", 0.0))
        n = max(3, len(self.config.general_indices()))
        return [by.get(i, 0.0) for i in range(1, n + 1)]

    def _set_reddot_general_weight(self, index: int, text: str) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        weights = self._reddot_general_weights()
        if 1 <= index <= len(weights):
            weights[index - 1] = max(0.0, model_mod._as_float(text, 0.0))
        rd[model_mod.REDDOT_GENERAL_WEIGHTS_KEY] = [
            {"general": i + 1, "weight": w} for i, w in enumerate(weights)]
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        self.status("将领 %d 权重 = %s" % (index, _fmt_num(weights[index - 1])))
        self.refresh_all()

    def _reddot_escort_count(self) -> int:
        rd = self.reddot_params(False) or {}
        return model_mod._as_int(rd.get(model_mod.ESCORT_COUNT_KEY), -1)

    def _reddot_escort_types(self) -> List[dict]:
        rd = self.reddot_params(False) or {}
        return model_mod.normalize_weight_list(rd.get(model_mod.ESCORT_TYPES_KEY))

    def _set_reddot_escort_count(self, text: str) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        rd[model_mod.ESCORT_COUNT_KEY] = max(0, model_mod._as_int(text, 0))
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        self.status("红点共享附属单位数量 = %d" % int(rd[model_mod.ESCORT_COUNT_KEY]))
        self.refresh_all()

    def _set_reddot_escort_row(self, row: int, type_id=None, weight=None) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        types = self._reddot_escort_types()
        if not (0 <= row < len(types)):
            return
        if type_id is not None:
            types[row]["type"] = str(type_id)
        if weight is not None:
            types[row]["weight"] = max(0.0, model_mod._as_float(weight, 0.0))
        rd[model_mod.ESCORT_TYPES_KEY] = types
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        self.refresh_all()

    def _add_reddot_escort_row(self) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        types = self._reddot_escort_types()
        default = self.config.unit_types[0] if self.config.unit_types else ""
        types.append({"type": default, "weight": 0})
        rd[model_mod.ESCORT_TYPES_KEY] = types
        self.refresh_all()

    def _remove_reddot_escort_row(self, row: int) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        types = self._reddot_escort_types()
        if 0 <= row < len(types):
            del types[row]
            rd[model_mod.ESCORT_TYPES_KEY] = types
            self.refresh_all()

    def _sidebar_reddot(self) -> None:
        lv = self.level()
        if lv is None:
            return
        reddots = [e.fid for e in lv.factions if e.ai == AI_REDDOT]
        sec = self._section("红点阵营", "红点生成配置挂在它的 `reddot_ai` 上")
        if not reddots:
            self._hint(sec, "本关没有挂「红点性」AI 的阵营：先到「阵营与AI」页给某一方"
                            "把 AI 类型选成「红点性」。")
            return
        cur = self.reddot_faction_id()
        self._combo_cell(sec, "编辑哪一方", cur, tuple(reddots), self._set_reddot_faction)
        rd = self.reddot_params(False) or {}

        # ---- 生成地块 ----
        tiles = self.reddot_spawn_tiles()
        tsec = self._section("生成地块", "在画布上左键点空地 = 加/移出；右键 = 移出")
        self._hint(tsec, "已选 %d 个地块（游戏里这些格子的外观**没有区别**）。" % len(tiles))
        self._button(tsec, "清空生成地块", self._clear_reddot_tiles, bg="#3a2b2b").pack(anchor="w")

        # ---- 时间表 ----
        isec = self._section("生成时间表", "y = a·x + b（x = 波次，y 的单位分别是「分钟」/「个」）")
        self._entry_cell(isec, "生成频率（x）",
                         str(rd.get(model_mod.REDDOT_WAVE_EXPR_KEY, "x")),
                         lambda text: self._set_reddot_expr(model_mod.REDDOT_WAVE_EXPR_KEY, text))
        self._entry_cell(isec, "将领数（x）",
                         str(rd.get(model_mod.REDDOT_COUNT_EXPR_KEY, "x")),
                         lambda text: self._set_reddot_expr(model_mod.REDDOT_COUNT_EXPR_KEY, text))
        self._hint(isec, "例：`x` → 第 1 波 1min；`x+1` → 第 1 波 2min、第 2 波 3min；"
                         "`2x+1` → 第 1 波 3min。空着 = 用 config 的默认（x）。")

        # ---- 将领类型权重 ----
        wsec = self._section("将领类型和权重", "目前只支持占位的三位将领；权重和必须为 1")
        weights = self._reddot_general_weights()
        for i, w in enumerate(weights):
            label = self.config.general_label(i + 1)
            self._entry_cell(wsec, "权重", _fmt_num(w),
                             lambda text, idx=i + 1: self._set_reddot_general_weight(idx, text))
            # ⚠️ 「权重」这个标签对每一行都一样，靠上面的将领名区分：把名字写进 hint
            #    （_entry_cell 的行标签宽度固定，写长名字会挤；这里用一行灰字代替）。
            self._hint(wsec, "第 %d 行 = %s" % (i + 1, label))
        total = sum(weights)
        self._hint(wsec, "权重和 = %.4f%s" % (total, "" if abs(total - 1.0) <= 1e-3
                                              else "　★ 必须恰好为 1（校验会拦）"))

        # ---- 共享附属单位规格 ----
        ssec = self._section("附属单位规格（共享）",
                             "所有红点将领共用：生成数量 + 兵种权重（运行时当场随机生成）")
        self._entry_cell(ssec, "生成数量", str(self._reddot_escort_count()),
                         self._set_reddot_escort_count)
        types = self._reddot_escort_types()
        for i, row in enumerate(types):
            r = tk.Frame(ssec, bg=UI["panel"])
            r.pack(side="top", fill="x", pady=1)
            tv = tk.StringVar(value=str(row.get("type", "")))
            combo = ttk.Combobox(r, textvariable=tv, state="readonly",
                                 values=tuple(self.config.unit_types) or ("—",), width=12)
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>",
                       lambda _e, idx=i, v=tv: self._set_reddot_escort_row(idx, type_id=v.get()))
            wv = tk.StringVar(value=_fmt_num(row.get("weight", 0.0)))
            we = ttk.Entry(r, textvariable=wv, width=6)
            we.pack(side="left", padx=(4, 0))
            we.bind("<Return>", lambda _e, idx=i, v=wv: self._set_reddot_escort_row(idx, weight=v.get()))
            we.bind("<FocusOut>", lambda _e, idx=i, v=wv: self._set_reddot_escort_row(idx, weight=v.get()))
            self._button(r, "－", lambda idx=i: self._remove_reddot_escort_row(idx),
                         padx=4).pack(side="left", padx=(4, 0))
        self._button(ssec, "＋ 加一行", self._add_reddot_escort_row).pack(anchor="w", pady=(4, 0))
        st = model_mod.weight_sum(types)
        if not types and self._reddot_escort_count() > 0:
            self._hint(ssec, "★ 设了数量却没有类型权重表 —— 校验会拦（`escort_types_missing`）")
        elif types and abs(st - 1.0) > 1e-3:
            self._hint(ssec, "★ 权重和 = %.4f（必须恰好为 1）" % st)
        elif types:
            self._hint(ssec, "权重和 = 1 ✓")

    def _set_reddot_faction(self, text: str) -> None:
        self.reddot_faction = str(text)
        self.refresh_all()

    def _clear_reddot_tiles(self) -> None:
        rd = self.reddot_params(True)
        if rd is None:
            return
        rd[model_mod.REDDOT_SPAWN_TILES_KEY] = []
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        self.status("清空了红点生成地块")
        self.refresh_all()

    # ---- ★★ 附属部队（`start_units[].escort_of`；旧模型，只读兼容）----
    #
    # 这一组是「所见即所得」那一轮的落点：开局附属兵不再由 config 的全局缺省决定，
    # 而是**在这里一个兵一个兵摆出来**，并明确它属于哪位将领。
    # 运行时会把它读成 `unit.leader_id`，于是它在游戏里真的是那位将领的部队。

    def _escort_choices(self, fid: str) -> Tuple[str, ...]:
        """「属于将领」下拉的选项：只列**这一方真的摆了**的将领。

        ⚠️ 不列「第 2 位将领」这种空头衔：运行时不会为摆过附属部队的一方补将领，
           列一个不存在的将领只会让设计者导出一个被校验拦下的关卡。
        ⚠️ 标签里的序号是**将领序号**（`general_index`），不是「列表里第几个」——
           与运行时找队长的判据必须一致。
        """
        lv = self.level()
        out = [ESCORT_NONE_LABEL]
        if lv is None:
            return tuple(out)
        for g in model_mod.placed_generals(lv, str(fid)):
            out.append(self._general_choice_label(int(g.general_index or 1), g))
        return tuple(out)

    def _general_choice_label(self, index: int, g: UnitEntry) -> str:
        name = (g.name or "").strip()
        kind = g.unit_type or g.kind
        return "将领 %d（%s%s）" % (index, kind, "·%s" % name if name else "")

    def _escort_choice_label(self, fid: str) -> str:
        """画笔那一行的当前值（`brush_escort_of` → 下拉文字）。"""
        lv = self.level()
        if lv is None:
            return ESCORT_NONE_LABEL
        g = model_mod.general_with_index(lv, str(fid), int(self.brush_escort_of))
        if g is None:
            return ESCORT_NONE_LABEL
        return self._general_choice_label(int(g.general_index or 1), g)

    def _escort_label(self, u: UnitEntry) -> str:
        """某个摆放单位的「属于将领」显示值。"""
        lv = self.level()
        if lv is None or not u.is_escort():
            return ESCORT_NONE_LABEL
        g = model_mod.general_with_index(lv, str(u.faction), int(u.escort_of))
        if g is not None:
            return self._general_choice_label(int(g.general_index or 1), g)
        # 序号找不到对应将领（例如那位将领被删了）：显示成「将领 N（已经没有这位将领）」——
        # 校验会拦住它（`escort_no_general`），这里只负责别静默显示成「不是附属兵」。
        return "将领 %d（已经没有这位将领）" % int(u.escort_of)

    def _set_brush_escort(self, text: str) -> None:
        if str(text) == ESCORT_NONE_LABEL:
            self.brush_escort_of = 1
            self.status("附属兵画笔要选一位将领（下拉里只有这一方已经摆好的将领）")
            self.refresh_all()
            return
        self.brush_escort_of = self._escort_index_from_label(str(text))
        self.status("附属兵将属于：%s" % text)

    def _escort_index_from_label(self, text: str) -> int:
        """从「将领 2（长弓兵）」这种文字里取回序号（取不到就当 1）。"""
        try:
            head = str(text).split("（")[0].replace("将领", "").strip()
            return max(1, int(head))
        except (ValueError, IndexError):
            return 1

    def _set_unit_escort(self, text: str) -> None:
        """选中单位的「属于将领」提交入口（写 `escort_of`）。"""
        u = self.selected_unit()
        if u is None:
            return
        if str(text) == ESCORT_NONE_LABEL:
            u.escort_of = -1
        else:
            u.escort_of = self._escort_index_from_label(str(text))
        self.refresh_all()

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
