"""app.py —— 地图编辑器的界面（tkinter，零依赖）。

界面结构：

    ┌───────────────────────────────────────────────┬──────────────┐
    │  [地块] [区块]                   新建 打开 导出 │              │
    ├───────────────────────────────────────────────┤   侧边栏     │
    │                                               │  随页签切换  │
    │              地图画布                          │              │
    │                                               │              │
    ├───────────────────────────────────────────────┤              │
    │  状态栏：光标下的格子 / 地图统计 / 提示         │              │
    └───────────────────────────────────────────────┴──────────────┘

操作（与需求一一对应）：

    · 左键点「虚线格」                         → 在里面建一个空白地块（草地），
                                                 并立刻在侧边栏打开它的属性面板
    · 左键点已有地块                           → 侧边栏打开它的属性面板
                                                 （地形只能在这里选，没有笔刷）
    · 右键点已有地块                           → 把它变回虚线格（删掉这个地块）
    · 区块页签：在侧边栏列表里选一个区块后
      左键点任意地块                           → 把它划给该区块；再点一次取消
    · 区块页签：侧边栏列表可新建 / 删除 / 重命名区块

其它：滚轮缩放（以光标为锚点）、中键拖动平移、空格 + 左键拖动平移、
方向键平移、Ctrl+Z 撤销。

★ 为什么是「左键建 / 右键删」而不是「笔刷涂地形」：设计师的动线是
  「点一下地就有了 → 在属性面板里决定它是什么地形」，所以创建与编辑分成两件事，
  左键管「建 + 看」，右键管「删」。地形没有「当前笔刷」这个状态，
  也就不会出现「手一抖把一片地刷错」。
"""

from __future__ import annotations

import copy
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Dict, List, Optional, Tuple

from . import mapfile
from .model import (
    DEFAULT_COLORS,
    FACTION_DEFAULT,
    FACTION_ROSTER,
    MAX_COORD,
    MAX_GRID_BYTES,
    TERRAIN_LABELS,
    TERRAIN_ORDER,
    ZONE_PALETTE,
    MapError,
    MapModel,
    blend,
    config_colors,
    load_config,
    parse_color,
    to_hex,
)

#: 编辑器自己的界面配色（与游戏里的画面无关）
UI = {
    "bg": "#1e1f22",
    "panel": "#26282c",
    "panel_alt": "#2b2d31",
    "line": "#3a3d42",
    "text": "#dcdcdc",
    "text_dim": "#8b8f96",
    "accent": "#5ac8ff",
    "canvas_bg": "#141517",
    "empty": "#222427",
    "empty_line": "#4a4d52",
    "base": "#ffd166",
}

UNDO_LIMIT = 200

#: 一屏虚线格超过这个数量就不画虚线格了（缩得太远时）：一是没必要，二是 tkinter 会卡。
EMPTY_CELL_LIMIT = 6000
#: 虚线格小于这么小（像素）就干脆不画格子 —— 缩到很远时格子会变成一片糊，
#: 而且数量爆炸。实测（1280×800 窗口）：
#:   格子 14px → 一屏 1824 格、光画格子就要 8.6 ms；格子 11px → 约 2900 格。
#: 所以阈值定在 11：保证「一屏格子数 × 每格开销」永远在几毫秒以内，拖起来才跟手。
MIN_GRID_PX = 11.0

#: 格子大于这个尺寸时，一个格子画一个虚线方框（最好看的画法）；
#: 小于它（但还 ≥ MIN_GRID_PX）就改用「一整张虚线网格」——图元从上千降到 2 个，
#: 缩小了看几乎一样。阈值定在 22（≈ config 的 cell_px 36 的 0.6 倍）：
#: 也就是「缩过一点」就直接进快档，别让人一边缩小一边开始卡。
BIG_CELL_PX = 22.0

#: 拖动时的重绘合并窗口（毫秒）：鼠标每秒能发上百个事件，每个都全量重绘就是 2 秒/秒。
REDRAW_COALESCE_MS = 16

#: 鼠标划过格子时，高亮方框跟着走的最小间隔（毫秒）。
#: 一次重绘实测 3~4 ms，所以这里可以贴着「一帧」来定；定大了（比如 40）高亮会明显落后光标。
HOVER_THROTTLE_MS = 16

#: 光标离兜底上限（`model.MAX_COORD`）还剩这么多格时，状态栏给一句提醒。
#: 目的是让「边界」变成**看得见**的东西：以前越界时只在点击的那一下提示一句，
#: 鼠标扫过去什么都不显示，设计师会以为编辑器坏了（用户报的「隐形线」）。
LIMIT_HINT_MARGIN = 64

#: 方向键一次平移多少像素
KEY_PAN_STEP = 90

#: 左键按下到抬起之间，移动超过这个像素数就当成「拖动」而不是「点击」
DRAG_TOLERANCE = 3

#: tk 的事件修饰键位：Shift、左键按住（B1）。
#:
#: ★ 为什么要记 B1：**tk 不保证拖动期间发的是 `<B1-Motion>`**（实测：带 B1 位的
#:   `<Motion>` 会走 `<Motion>` 那条绑定）。所以「拖动中」这件事要看 state 里的 B1 位，
#:   不能只靠绑在 `<B1-Motion>` 上的那个回调 —— 否则预览矩形会停在起点不动。
#: ★ 更要紧的是 Shift：**tk 也不保证鼠标事件带 Shift 位**（实测 `state == 0x0`），
#:   所以 Shift 还得额外从键盘事件里跟踪（见 EditorApp.shift_held）。
SHIFT_MASK = 0x0001
BUTTON1_MASK = 0x0100

#: 框选矩形的预览色（拖动中）与落定色（松开之后）
SELECT_FILL = "#5ac8ff"
SELECT_OUTLINE = "#c9ecff"

#: 批量面板里「选中的格子值不一致」时的占位文案（地形与归属共用）
MULTI_VALUE = "（多个值）"


class EditorApp:
    def __init__(self, root: tk.Tk, project_dir: Path, model: Optional[MapModel] = None,
                 current_path: Optional[Path] = None) -> None:
        self.root = root
        self.project_dir = Path(project_dir)
        self.cfg = load_config(self.project_dir)
        self.color_cfg = config_colors(self.cfg)

        # 初始画布：一张 0×0 的网格 —— 界面上的虚线格是**无限**的（不占内存），
        # 点哪一格就长到哪一格（见 model.MapModel 的 ensure_tile / _grow_to_include）。
        self.model: MapModel = model if model is not None else MapModel(0, 0)
        self.current_path: Optional[Path] = Path(current_path) if current_path else None
        self.dirty = False
        self._undo: List[dict] = []
        self._redo: List[dict] = []

        # ---- 界面状态
        self.page = "tile"                 # "tile" 地块页 / "zone" 区块页 / "faction" 阵营页
        self.selected_zone: Optional[int] = None   # 区块页选中的区块 id
        self.selected_faction: Optional[str] = None   # 阵营页选中的阵营 id
        self.inspect: Optional[Tuple[int, int]] = None   # 属性面板正在看的格子
        self.hover: Optional[Tuple[int, int]] = None
        #: 框选出来的矩形 `(x0, y0, x1, y1)`（世界坐标，已规范化）；None = 没选。
        #: ★ 只放**已有地块**的选择结果，见 batch_tiles()：虚线格不参与批量操作。
        self.selection: Optional[Tuple[int, int, int, int]] = None
        #: 正在拖框选：`(起点格子, 当前格子)`；None = 没在拖
        self._select_drag: Optional[Tuple[Tuple[int, int], Tuple[int, int]]] = None
        #: 侧边栏「地块属性」里那几个会被**就地改值**的控件（见 refresh_tile_panel）。
        #: 用就地改值而不是销毁重建：一次重建要 20+ ms（实测，见 README 第十节），
        #: 点一下地就卡 20+ ms，是「不跟手」的最大来源。
        self._tile_widgets: Dict[str, object] = {}

        # ---- 视图
        self.zoom = 1.0
        self.ox = 20.0
        self.oy = 20.0
        self.min_zoom = 0.05
        self.max_zoom = 8.0

        self._pan_anchor: Optional[Tuple[float, float]] = None
        self._hover_job: Optional[str] = None
        self._suppress_zone_event = False
        #: 正在重建阵营页的 Treeview（与区块页同一套理由，见 refresh_sidebar 的注释）
        self._suppress_faction_event = False
        #: 正在重建侧边栏（防止「重建 → 选区事件 → 又重建」的死循环，见 refresh_sidebar）
        self._rebuilding = False
        #: 是否按住空格（按住 = 进入平移模式，左键拖动移视野）
        self.space_held = False
        #: 是否按住 Shift（按住 + 左键拖动 = 框选）。
        #:
        #: ★ 为什么要单独记一个状态，而不是只看鼠标事件的 `event.state`：
        #:   **tk 的鼠标事件并不保证带上 Shift 位**（实测：把 Shift 与鼠标事件
        #:   分开送进 tk 时，`<ButtonPress-1>` 的 `state` 是 0x0 —— 修饰键没跟过来）。
        #:   于是「按住 Shift 再拖」会被当成普通拖拽，**静默不框选**。
        #:   现在两条路都认：键盘事件维护这个状态，鼠标事件的 state 位**也**算数
        #:   （两者取「或」—— 只要有一个说按住，就按按住处理）。
        self.shift_held = False
        #: 左键按下的位置（判断这次是「点击」还是「拖动」）
        self._left_down_at: Optional[Tuple[float, float]] = None
        #: 画布尺寸未知时先不摆初始视野（见 apply_initial_view）
        self._need_initial_view = True
        #: 合并重绘用的 after id（见 request_redraw）
        self._redraw_job: Optional[str] = None

        self._setup_window()
        self._build_widgets()
        self._bind_keys()

        # 画布是**无限虚线格**：初始地图是空的，画布永远铺满虚线格子，
        # 点哪一格就在哪一格建地块（网格会自己长到装得下，见 model.MapModel）。
        #
        # ⚠️ 初始视野**必须等画布拿到真实尺寸之后再算**：构造函数里窗口还没映射，
        #    canvas.winfo_width() 返回 1 —— 那时算出来的缩放/居中是错的
        #    （实测症状：窗口一开，格子大小与中心位置都不对，点远处会点到意外的位置）。
        #    所以这里只记下意图，真正的应用在 _apply_initial_view()（由 <Configure> 触发）。
        self._need_initial_view = True
        self.update_title()
        self.redraw()

    def apply_initial_view(self) -> None:
        """画布拿到真实尺寸之后，把初始视野摆好（只做一次）。

        空地图 → 原点居中、1:1 缩放（无限虚线画布）；
        已有地图 → 把已画的地块放进视野。
        """
        if not self._need_initial_view:
            return
        if self.canvas.winfo_width() <= 1 or self.canvas.winfo_height() <= 1:
            return                      # 还没映射，等下一次 <Configure>
        self._need_initial_view = False
        if self.model.existing_count() == 0:
            self.zoom = 1.0
            self.center_on(0, 0)
            self.status("无限虚线画布：左键点任意虚线格就建出地块（并在右侧改它的地形），"
                        "左键点已有地块看属性，右键点地块把它删回虚线格；"
                        "空格 + 拖动 / 中键拖动 平移，滚轮缩放；画完用右上角「导出 JSON」")
        else:
            self.fit_view()
            self.status("打开了一张已有地图：%d 个地块、%d 个区块"
                        % (self.model.existing_count(), len(self.model.zones)))
        self.redraw()

    def on_canvas_configure(self, event=None) -> None:
        self.apply_initial_view()
        self.redraw()

    # ==================================================================
    # 窗口与控件
    # ==================================================================

    def _setup_window(self) -> None:
        self.root.title("DAEEM 地图编辑器")
        self.root.configure(bg=UI["bg"])
        self.root.geometry("1280x820")
        self.root.minsize(900, 600)

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
        style.configure("Bar.TLabel", background=UI["bg"], foreground=UI["text"])
        style.configure("Dim.TLabel", background=UI["panel"], foreground=UI["text_dim"])
        style.configure("Title.TLabel", background=UI["panel"], foreground=UI["accent"],
                        font=("Microsoft YaHei UI", 10, "bold"))
        style.configure("TButton", background=UI["panel_alt"], foreground=UI["text"],
                        bordercolor=UI["line"], focuscolor=UI["panel_alt"], padding=(8, 4))
        style.map("TButton",
                  background=[("active", "#3a3d42"), ("pressed", "#45484f")],
                  foreground=[("disabled", UI["text_dim"])])
        style.configure("Accent.TButton", background="#2f5f7a", foreground="#eaf6ff")
        style.map("Accent.TButton", background=[("active", "#3a7699")])
        style.configure("TCheckbutton", background=UI["panel"], foreground=UI["text"],
                        focuscolor=UI["panel"])
        style.map("TCheckbutton", background=[("active", UI["panel"])])
        style.configure("TEntry", fieldbackground=UI["panel_alt"], foreground=UI["text"],
                        insertcolor=UI["text"])
        style.configure("Treeview", background=UI["panel_alt"], fieldbackground=UI["panel_alt"],
                        foreground=UI["text"], bordercolor=UI["line"], rowheight=24)
        style.configure("Treeview.Heading", background=UI["panel"], foreground=UI["text_dim"])
        style.map("Treeview", background=[("selected", "#2f5f7a")],
                  foreground=[("selected", "#ffffff")])
        style.configure("TNotebook", background=UI["bg"], borderwidth=0)
        style.configure("TNotebook.Tab", background=UI["panel"], foreground=UI["text_dim"],
                        padding=(14, 6))
        style.map("TNotebook.Tab", background=[("selected", UI["panel_alt"])],
                  foreground=[("selected", UI["accent"])])
        style.configure("TScale", background=UI["panel"])

    def _build_widgets(self) -> None:
        # ---- 顶部页签栏
        top = tk.Frame(self.root, bg=UI["bg"])
        top.pack(side="top", fill="x")
        tk.Label(top, text="地图编辑器", bg=UI["bg"], fg=UI["accent"],
                 font=("Microsoft YaHei UI", 11, "bold")).pack(side="left", padx=(10, 14), pady=6)

        self.tab_buttons: Dict[str, tk.Button] = {}
        for key, label, hint in (("tile", "地块", "左键建地块 / 看属性，Shift+拖拽框选批量改"),
                                 ("zone", "区块", "选中区块后左键点地块来划分"),
                                 ("faction", "阵营", "选中阵营后左键点地块 = 设它的大本营")):
            # ⚠️ 一律走 _button()：它保证 takefocus=0 且点完把键盘焦点交还画布 ——
            #    否则按钮会拿住焦点，而**空格在 tk 里是「激活焦点按钮」**，
            #    于是「按住空格拖画面」会变成「反复点最后按过的那个页签」
            #    （用户看到的症状：点页签有时像没反应、页面自己乱跳）。
            btn = self._button(top, label, lambda k=key: self.set_page(k),
                               padx=16, pady=5,
                               bg=UI["panel"], fg=UI["text_dim"],
                               activebackground=UI["panel_alt"], activeforeground=UI["accent"],
                               font=("Microsoft YaHei UI", 10))
            btn.pack(side="left", padx=2)
            self.tab_buttons[key] = btn

        # 地图文件三件套（导入 / 导出）。放最右上角，并配一个分组标题 ——
        # 需求原话是「在编辑器里加导入导出按钮」，所以这里要一眼看得见、找得到。
        right = tk.Frame(top, bg=UI["bg"])
        right.pack(side="right", padx=8)
        # 分组标题 + 三颗按钮，整体当一组排在右上角
        tk.Label(right, text="地图文件", bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 9)).pack(side="left", padx=(0, 6))
        self.file_buttons: Dict[str, tk.Button] = {}
        for key, text, cmd, tip in (
                ("export", "导出 JSON", self.do_export, "把当前地图写成 JSON（Ctrl+S）"),
                ("import", "导入地图…", self.do_open, "打开一张已有的地图 JSON（Ctrl+O）"),
                ("new", "新建地图…", self.do_new, "重开一张空白画布（Ctrl+N）")):
            btn = self._button(right, text, cmd, padx=12, pady=5,
                               bg=UI["panel_alt"], fg=UI["text"],
                               activebackground="#3a3d42", activeforeground=UI["accent"],
                               font=("Microsoft YaHei UI", 9))
            btn.pack(side="left", padx=3)
            self.file_buttons[key] = btn
        # 「导出」用强调色：多数时候打开编辑器就是为了导出一张图
        self.file_buttons["export"].configure(bg="#2f5f7a", fg="#eaf6ff",
                                             activebackground="#3a7699")

        # ---- 主体：画布 + 侧边栏
        body = tk.Frame(self.root, bg=UI["bg"])
        body.pack(side="top", fill="both", expand=True)

        canvas_wrap = tk.Frame(body, bg=UI["canvas_bg"])
        canvas_wrap.pack(side="left", fill="both", expand=True)

        self.canvas = tk.Canvas(canvas_wrap, bg=UI["canvas_bg"], highlightthickness=0,
                                bd=0)
        self.canvas.pack(side="left", fill="both", expand=True)

        self.status_var = tk.StringVar(value="")
        status = tk.Label(self.root, textvariable=self.status_var, anchor="w",
                          bg=UI["panel"], fg=UI["text_dim"], padx=10, pady=4,
                          font=("Microsoft YaHei UI", 9))
        status.pack(side="bottom", fill="x")

        self.zone_page_var = tk.StringVar(value="区块页：先选一个区块")

        self.sidebar = tk.Frame(body, bg=UI["panel"], width=320)
        self.sidebar.pack(side="right", fill="y")
        self.sidebar.pack_propagate(False)
        self._build_sidebar()

        self.canvas.bind("<Configure>", self.on_canvas_configure)
        # 关窗口时把还没跑的那次合并重绘取消掉（否则回调会打到已经销毁的控件上）
        self.canvas.bind("<Destroy>", lambda e: self.cancel_redraw(), add="+")
        self.canvas.bind("<Button-1>", self.on_left_down)
        self.canvas.bind("<B1-Motion>", self.on_left_drag)
        self.canvas.bind("<ButtonRelease-1>", self.on_left_up)
        self.canvas.bind("<Button-2>", self.on_middle_down)
        self.canvas.bind("<B2-Motion>", self.on_middle_drag)
        self.canvas.bind("<ButtonRelease-2>", self.on_middle_up)
        self.canvas.bind("<Button-3>", self.on_right_click)
        self.canvas.bind("<Motion>", self.on_motion)
        self.canvas.bind("<Leave>", self.on_leave)
        self.canvas.bind("<MouseWheel>", self.on_wheel)       # Windows / macOS
        self.canvas.bind("<Button-4>", lambda e: self.on_wheel(e, 120))   # X11
        self.canvas.bind("<Button-5>", lambda e: self.on_wheel(e, -120))
        self.canvas.bind("<KeyPress-space>", self.on_space_down)
        self.canvas.bind("<KeyRelease-space>", self.on_space_up)
        # ★ Shift 也要跟着键盘事件走（不能只看鼠标事件的 state 位，见 shift_is_held）。
        #   左右两个 Shift 都绑：用户按哪个都算。
        for seq in ("<KeyPress-Shift_L>", "<KeyPress-Shift_R>"):
            self.canvas.bind(seq, self.on_shift_down)
        for seq in ("<KeyRelease-Shift_L>", "<KeyRelease-Shift_R>"):
            self.canvas.bind(seq, self.on_shift_up)

    # ------------------------------------------------------------------
    # 侧边栏
    # ------------------------------------------------------------------

    def _build_sidebar(self) -> None:
        self._tile_widgets = {}
        #: 这条侧边栏是**照着哪一页**建的：`set_page` 靠它跳过「点同一个页签」的白重建。
        self._sidebar_page: Optional[str] = None
        for child in self.sidebar.winfo_children():
            child.destroy()

        if self.page == "tile":
            self._build_tile_sidebar()
        elif self.page == "faction":
            self._build_faction_sidebar()
        else:
            self._build_zone_sidebar()
        self._build_map_section()
        self._sidebar_page = self.page

    def _section(self, parent, title: str) -> tk.Frame:
        tk.Label(parent, text=title, bg=UI["panel"], fg=UI["accent"], anchor="w",
                 font=("Microsoft YaHei UI", 10, "bold")).pack(fill="x", padx=10, pady=(10, 2))
        frame = tk.Frame(parent, bg=UI["panel"])
        frame.pack(fill="x", padx=10)
        return frame

    def _build_tile_sidebar(self) -> None:
        """地块页的侧边栏（**只在需要时**才走到这里，见 refresh_tile_panel）。

        面板里的地形按钮 / 大本营按钮 / 删除按钮在「换到另一格」时会被**就地改值**复用，
        所以它们的回调必须把坐标用**默认参数**钉住（`lambda bx=x, by=y: ...`）——
        读 `self.inspect` 的话，换格子的那一瞬间它们会指向「当时」那一格。

        ★ 有框选时走的是**另一套面板**（`_build_batch_sidebar`）：那时候点地形按钮
        改的是「选中的一批格子」，语义与单格面板完全不同，硬塞进一个面板只会让
        两边的按钮互相误导。
        """
        if self.selection is not None:
            self._build_batch_sidebar()
            return
        # ---- 地块属性
        sec = self._section(self.sidebar, "地块属性")
        if self.inspect is None:
            tk.Label(sec, text="左键点一个地块，这里会显示它的属性。\n"
                               "（点虚线格 = 先把地块建出来，再在这里选地形）\n"
                               "Shift + 拖拽 = 框选一批地块，批量改地形 / 归属",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left", wraplength=280).pack(fill="x")
            return

        x, y = self.inspect
        self.coord_label = tk.Label(sec, text="", bg=UI["panel"], fg=UI["text"], anchor="w",
                                    justify="left", wraplength=290)
        self.coord_label.pack(fill="x", pady=(0, 4))

        terrain_label = tk.Label(sec, text="地形", bg=UI["panel"], fg=UI["text_dim"],
                                 anchor="w")
        terrain_label.pack(fill="x")
        terrain_buttons: Dict[str, tk.Button] = {}
        for terrain in TERRAIN_ORDER:
            color = self.terrain_color(terrain)
            btn = self._button(sec, TERRAIN_LABELS[terrain],
                               lambda t=terrain: self.set_tile_terrain(t),
                               bg=color, fg=self.text_on(color),
                               activebackground=color, activeforeground=self.text_on(color),
                               anchor="w", padx=8, pady=3,
                               font=("Microsoft YaHei UI", 9))
            btn.pack(fill="x", pady=1)
            terrain_buttons[terrain] = btn

        # ---- 归属
        zsec = self._section(self.sidebar, "归属区块")
        self.zone_row = tk.Frame(zsec, bg=UI["panel"])
        self.zone_row.pack(fill="x")

        # ---- 大本营 & 删除
        bsec = self._section(self.sidebar, "大本营 / 地块")
        # ⚠️ 坐标用**默认参数**钉住（`bx=x, by=y`），不用 `self.inspect`：
        #    这两个按钮建好之后会被就地改值复用，而点击发生在回调执行的那一刻 ——
        #    读 self.inspect 的话，换格子的瞬间它们会指向"当时"那一格而不是自己标签上写的格子。
        self.base_btn = self._button(bsec, "", lambda bx=x, by=y: self.toggle_base(bx, by),
                                     padx=8, pady=4,
                                     bg=UI["panel_alt"], fg=UI["base"],
                                     activebackground="#3a3d42")
        self.base_btn.pack(fill="x", pady=2)
        self.delete_btn = self._button(bsec, "删除这个地块（变回虚线格）",
                                       lambda bx=x, by=y: self.delete_tile(bx, by),
                                       padx=8, pady=4, bg="#5a2f2f", fg="#ffdede",
                                       activebackground="#7a3d3d")
        self.delete_btn.pack(fill="x", pady=2)

        self._tile_widgets = {
            "coord": self.coord_label,
            "terrain": terrain_buttons,
            "terrain_label": terrain_label,
            "zone_row": self.zone_row,
            "base": self.base_btn,
            "delete": self.delete_btn,
            # 建这一条面板时那一格**存在不存在**：决定面板里有没有「地形/归属/大本营/删除」
            # 这几栏。换了格子但「都是已有地块」或「都是虚线格」时，面板结构没变 →
            # refresh_tile_panel() 就地改值就够了，不用把整条侧边栏重建一遍（省 ~14 ms/次）。
            "inspected": self.model.exists(x, y),
        }
        self.refresh_tile_panel()

    # ------------------------------------------------------------------
    # 批量面板（框选之后）
    # ------------------------------------------------------------------

    def batch_tiles(self) -> List[Tuple[int, int]]:
        """当前框选里的**已有地块**（世界坐标）；没框选就返回空列表。"""
        if self.selection is None:
            return []
        return self.model.rect_tiles(*self.selection)

    def _build_batch_sidebar(self) -> None:
        """框选之后的面板：对**选中的一批格子**生效。

        ★ 与单格面板的差别（别把两边混起来）：
          · 这里没有「大本营」—— 大本营是一个点位，批量设没有意义；
          · 地形按钮显示**混合状态**（选中的格子地形不一致时不打勾，标「多个值」）；
          · 操作是「一次改一整批」，撤销栈里只压**一次**快照（一次操作 = 一步撤销）。
        """
        tiles = self.batch_tiles()
        x0, y0, x1, y1 = self.selection  # type: ignore[misc]
        sec = self._section(self.sidebar, "已框选 %d 个地块" % len(tiles))
        tk.Label(sec, text="范围 (%d, %d) – (%d, %d)" % (x0, y0, x1, y1),
                 bg=UI["panel"], fg=UI["text"], anchor="w").pack(fill="x", pady=(0, 4))
        if not tiles:
            tk.Label(sec, text="这个矩形里没有已建的地块（虚线格不参与批量操作）。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left", wraplength=280).pack(fill="x")
            self._button(sec, "取消框选", self.clear_selection, padx=8, pady=4,
                         bg=UI["panel_alt"], fg=UI["text"],
                         activebackground="#3a3d42").pack(fill="x", pady=(6, 0))
            return

        # ---- 地形（混合状态不打勾）
        terrains = {self.model.terrain_at(*t) for t in tiles}
        mixed_terrain = len(terrains) > 1
        tk.Label(sec, text="地形（改选中的 %d 格）" % len(tiles), bg=UI["panel"],
                 fg=UI["text_dim"], anchor="w").pack(fill="x")
        for terrain in TERRAIN_ORDER:
            color = self.terrain_color(terrain)
            mark = "○" if mixed_terrain else ("●" if terrains == {terrain} else "○")
            self._button(sec, mark + " " + TERRAIN_LABELS[terrain],
                         lambda t=terrain: self.batch_set_terrain(t),
                         bg=color, fg=self.text_on(color),
                         activebackground=color, activeforeground=self.text_on(color),
                         anchor="w", padx=8, pady=3,
                         font=("Microsoft YaHei UI", 9)).pack(fill="x", pady=1)
        if mixed_terrain:
            tk.Label(sec, text="选中的地块地形不一致（未打勾）", bg=UI["panel"],
                     fg=UI["text_dim"], anchor="w").pack(fill="x")

        # ---- 归属区块（同样按「是不是同一个值」显示）
        zsec = self._section(self.sidebar, "归属区块（改选中的 %d 格）" % len(tiles))
        names = ["（不属于任何区块）"] + [z.name for z in
                                          sorted(self.model.zones, key=lambda z: z.zone_id)]
        owners = {self.model.zone_at(*t) for t in tiles}
        if len(owners) == 1:
            only = owners.pop()
            current = only.name if only is not None else names[0]
        else:
            current = MULTI_VALUE           # 选中的格子归属不一致
        self.batch_zone_choice = tk.StringVar(value=current)
        combo = ttk.Combobox(zsec, textvariable=self.batch_zone_choice,
                             values=[MULTI_VALUE] + names, state="readonly")
        combo.pack(fill="x")
        combo.bind("<<ComboboxSelected>>", lambda e: self.batch_set_zone())

        # ---- 批量删除
        bsec = self._section(self.sidebar, "批量操作")
        self._button(bsec, "删除选中的 %d 个地块" % len(tiles),
                     self.batch_delete_tiles, padx=8, pady=4,
                     bg="#5a2f2f", fg="#ffdede",
                     activebackground="#7a3d3d").pack(fill="x", pady=2)
        self._button(bsec, "取消框选（Esc）", self.clear_selection, padx=8, pady=4,
                     bg=UI["panel_alt"], fg=UI["text"],
                     activebackground="#3a3d42").pack(fill="x", pady=2)

    def clear_selection(self) -> None:
        """取消框选（Esc / 空白处点一下 / 点「取消框选」都走这里）。"""
        if self.selection is None and self._select_drag is None:
            return
        self.selection = None
        self._select_drag = None
        self.refresh_sidebar()
        self.redraw()
        self.update_status(self.hover)

    def batch_set_terrain(self, terrain: str) -> None:
        """把选中的地块全改成某种地形（一次操作 = 一步撤销）。"""
        tiles = self.batch_tiles()
        if not tiles:
            return
        changed = [t for t in tiles if self.model.terrain_at(*t) != terrain]
        if not changed:
            self.status("选中的 %d 格本来就是%s" % (len(tiles), TERRAIN_LABELS[terrain]))
            return
        self.push_undo()
        for tile in changed:
            self.model.set_terrain(tile[0], tile[1], terrain)
        self.mark_dirty()
        self.status("把选中的 %d 格改成了%s（其中 %d 格真的变了）"
                    % (len(tiles), TERRAIN_LABELS[terrain], len(changed)))
        self.refresh_sidebar()
        self.redraw()

    def batch_set_zone(self) -> None:
        """把选中的地块全划给某个区块（或全部摘出来）。"""
        tiles = self.batch_tiles()
        if not tiles:
            return
        name = self.batch_zone_choice.get()
        if name == MULTI_VALUE:
            return                              # 只是占位提示，不是可选项
        self.push_undo()
        if name.startswith("（"):
            for tile in tiles:
                self.model.clear_zone(tile[0], tile[1])
            self.status("选中的 %d 格不再属于任何区块" % len(tiles))
        else:
            zone = next((z for z in self.model.zones if z.name == name), None)
            if zone is None:
                self.status("找不到区块「%s」" % name)
                return
            for tile in tiles:
                self.model.assign_tile(tile[0], tile[1], zone.zone_id)
            self.status("选中的 %d 格划给了「%s」" % (len(tiles), zone.name))
        self.mark_dirty()
        self.refresh_sidebar()
        self.redraw()

    def batch_delete_tiles(self) -> None:
        """把选中的地块全删掉（变回虚线格）—— 与单格右键删除是同一个动作。"""
        tiles = self.batch_tiles()
        if not tiles:
            return
        if not messagebox.askyesno("删除地块",
                                   "删掉选中的 %d 个地块（变回虚线格）？" % len(tiles)):
            return
        self.push_undo()
        for tile in tiles:
            self.model.delete_tile(tile[0], tile[1])
        self.mark_dirty()
        self.status("删掉了选中的 %d 个地块" % len(tiles))
        self.selection = None                  # 格都没了，框选留着没意义
        self.refresh_sidebar()
        self.redraw()

    def refresh_tile_panel(self) -> None:
        """刷新「地块属性」面板：**能就地改值就就地改，结构变了才整条重建**。

        面板的**结构**由「这一格存不存在」决定（虚线格没有地形/归属/大本营/删除可改），
        所以：
          · 结构没变 → 只改标签文字 / 按钮颜色与选中标记（~3 ms，点一下就走的动线靠它）；
          · 结构变了 → 交给 `refresh_sidebar()` 重画整条（~20 ms，只发生在
            「虚线格 ↔ 有地块」切换的那一刻）。

        ⚠️ 这个「结构变了要重建」的闸门放在这里，而不是放在调用方（show_tile_panel）：
        删格 / 撤销 / 导入之后，谁都可能让面板正在看的那一格消失，
        少一处调用就会留下一个「按钮看起来还能点、点下去没反应」的旧面板（实测踩过）。
        """
        if self.inspect is None or not self._tile_widgets:
            return
        x, y = self.inspect
        model = self.model
        w = self._tile_widgets

        exists = model.exists(x, y)
        zone = model.zone_at(x, y)
        current = model.terrain_at(x, y)
        if exists != w.get("inspected", exists):
            self.refresh_sidebar()
            return
        info = "格 (%d, %d)" % (x, y)
        if exists:
            info += "　%s　归属：%s" % (TERRAIN_LABELS.get(current, "?"),
                                        zone.name if zone else "无")
        else:
            info += "　虚线格（这里还没有地块）"
        w["coord"].configure(text=info)                      # type: ignore[union-attr]

        for terrain, btn in w["terrain"].items():             # type: ignore[union-attr]
            color = self.terrain_color(terrain)
            selected = exists and current == terrain
            btn.configure(text=("● " if selected else "○ ") + TERRAIN_LABELS[terrain],
                          bg=color, fg=self.text_on(color),
                          activebackground=color, activeforeground=self.text_on(color),
                          state=("normal" if exists else "disabled"),
                          command=lambda t=terrain: self.set_tile_terrain(t))
        w["terrain_label"].configure(                       # type: ignore[union-attr]
            text=("地形（点一下改这一格）" if exists else "地形（先把这格建出来才能改）"))

        is_base = exists and model.base == (x, y)
        w["base"].configure(                                # type: ignore[union-attr]
            text=("取消此处的大本营" if is_base else "把大本营设在这里"),
            fg=(UI["text"] if is_base else UI["base"]),
            state=("normal" if exists else "disabled"),
            command=lambda bx=x, by=y: self.toggle_base(bx, by))
        w["delete"].configure(state=("normal" if exists else "disabled"),
                              command=lambda bx=x, by=y: self.delete_tile(bx, by))

        # 归属下拉框的候选会变（新建 / 删除区块、换格子），所以这一个控件就地重建
        for child in w["zone_row"].winfo_children():          # type: ignore[union-attr]
            child.destroy()
        names = ["（不属于任何区块）"] + [z.name for z in
                                          sorted(model.zones, key=lambda z: z.zone_id)]
        self.zone_choice = tk.StringVar(value=zone.name if zone else names[0])
        combo = ttk.Combobox(w["zone_row"], textvariable=self.zone_choice, values=names,
                             state="readonly" if exists else "disabled")
        combo.pack(fill="x")
        if exists:
            combo.bind("<<ComboboxSelected>>", lambda e: self.on_zone_choice(x, y))

    # ------------------------------------------------------------------
    # 阵营页签
    # ------------------------------------------------------------------

    def _build_faction_sidebar(self) -> None:
        """阵营页：列表 + 选中阵营的属性 + 「大本营」操作。

        ★ 阵营 id 用游戏那套字符串（p1…p8 / enemy），因为这正是
          Godot 侧 `faction_bases` 的键 —— 导出的地图不需要任何翻译表。
        ★ 一个阵营只有一个大本营（对齐 Godot 的 TYPE_BASE：一方一座基地），
          所以这里是一颗「设为它的大本营 / 取消」的按钮，不是一套网格。
        """
        sec = self._section(self.sidebar, "阵营列表")
        wrap = tk.Frame(sec, bg=UI["panel"])
        wrap.pack(fill="both", expand=True)
        self.faction_tree = ttk.Treeview(wrap, columns=("base",), show="tree headings",
                                         height=8, selectmode="browse")
        self.faction_tree.heading("#0", text="阵营")
        self.faction_tree.heading("base", text="大本营")
        self.faction_tree.column("#0", width=180, anchor="w")
        self.faction_tree.column("base", width=80, anchor="e")
        scroll = ttk.Scrollbar(wrap, orient="vertical", command=self.faction_tree.yview)
        self.faction_tree.configure(yscrollcommand=scroll.set)
        self.faction_tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")
        self.faction_tree.bind("<<TreeviewSelect>>", self.on_faction_select)

        btn_row = tk.Frame(sec, bg=UI["panel"])
        btn_row.pack(fill="x", pady=(6, 0))
        self._button(btn_row, "新建阵营", self.add_faction, padx=8, pady=4,
                     bg=UI["panel_alt"], fg=UI["text"],
                     activebackground="#3a3d42").pack(side="left", expand=True, fill="x",
                                                       padx=(0, 3))
        self._button(btn_row, "删除", self.delete_selected_faction, padx=8, pady=4,
                     bg="#5a2f2f", fg="#ffdede",
                     activebackground="#7a3d3d").pack(side="left", expand=True, fill="x",
                                                       padx=(3, 0))

        # ---- 选中阵营的属性
        fsec = self._section(self.sidebar, "选中的阵营")
        self.faction_detail_row = tk.Frame(fsec, bg=UI["panel"])
        self.faction_detail_row.pack(fill="x")

        # ---- 大本营
        bsec = self._section(self.sidebar, "大本营")
        self.faction_base_label = tk.Label(fsec, text="", bg=UI["panel"], fg=UI["text"],
                                           anchor="w", justify="left", wraplength=290)
        self.faction_base_label.pack(fill="x", pady=(4, 0))
        self.faction_base_btn = self._button(bsec, "", self.toggle_faction_base,
                                             padx=8, pady=4,
                                             bg=UI["panel_alt"], fg=UI["text"],
                                             activebackground="#3a3d42")
        self.faction_base_btn.pack(fill="x", pady=2)
        tk.Label(bsec, text="在「地块」页签左键点一格来选中它，再回来按上面的按钮 ——\n"
                            "大本营就设在那格（再按一次 = 取消）。",
                 bg=UI["panel"], fg=UI["text_dim"], anchor="w", justify="left",
                 wraplength=290).pack(fill="x", pady=(4, 0))

        # ---- 这一格（面板正在看的那格）现在是谁的大本营：可以直接改归属
        self.faction_tile_section = self._section(self.sidebar, "选中那一格的大本营")

        # 列表、详情、按钮都填一次（就地改值，见 refresh_faction_panel）
        self.refresh_faction_panel()

    def refresh_faction_panel(self) -> None:
        """就地刷新区块…阵营页那几栏（列表 + 选中阵营的属性 + 大本营按钮）。

        ★ 只有「加 / 删阵营」会改变**行数**，那种情况才整条重建（`refresh_sidebar`）；
          改名 / 改色 / 设大本营都走这里就地改值 —— 与区块页同一套理由与做法。
        """
        if self.page != "faction":
            return
        rows = list(self.model.factions)
        iids = [f.faction_id for f in rows]
        if list(self.faction_tree.get_children()) != iids:
            self._suppress_faction_event = True
            try:
                self.faction_tree.delete(*self.faction_tree.get_children())
                for faction in rows:
                    base = self.model.faction_base_of(faction.faction_id)
                    self.faction_tree.insert(
                        "", "end", iid=faction.faction_id, text=faction.label(),
                        values=("(%d, %d)" % base if base else "—",))
            finally:
                self._suppress_faction_event = False
        else:
            for faction in rows:
                base = self.model.faction_base_of(faction.faction_id)
                self.faction_tree.item(faction.faction_id, text=faction.label(),
                                       values=("(%d, %d)" % base if base else "—",))
        if self.selected_faction is not None and self.faction_tree.exists(self.selected_faction):
            self.faction_tree.selection_set(self.selected_faction)

        # 选中阵营的详情（名字 / 颜色）
        row = self.faction_detail_row
        for child in row.winfo_children():
            child.destroy()
        faction = self.model.faction(self.selected_faction) if self.selected_faction else None
        if faction is None:
            tk.Label(row, text="在列表里选一个阵营（没有就新建一个）。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left").pack(fill="x")
        else:
            line = tk.Frame(row, bg=UI["panel"])
            line.pack(fill="x", pady=(0, 2))
            tk.Label(line, text="　", bg=faction.color, width=2).pack(side="left")
            tk.Label(line, text=" " + faction.faction_id, bg=UI["panel"],
                     fg=UI["text_dim"], anchor="w").pack(side="left")
            name_row = tk.Frame(row, bg=UI["panel"])
            name_row.pack(fill="x", pady=2)
            tk.Label(name_row, text="名字", bg=UI["panel"], fg=UI["text_dim"]).pack(side="left")
            self.faction_name_var = tk.StringVar(value=faction.name)
            entry = ttk.Entry(name_row, textvariable=self.faction_name_var)
            entry.pack(side="left", fill="x", expand=True, padx=(6, 4))
            entry.bind("<Return>", lambda e: self.apply_faction_name())
            entry.bind("<FocusOut>", lambda e: self.apply_faction_name())
            self._button(name_row, "✓", self.apply_faction_name, padx=6,
                         bg=UI["panel_alt"], fg=UI["text"],
                         activebackground="#3a3d42").pack(side="left")
            color_row = tk.Frame(row, bg=UI["panel"])
            color_row.pack(fill="x", pady=2)
            tk.Label(color_row, text="颜色", bg=UI["panel"], fg=UI["text_dim"]).pack(side="left")
            self._button(color_row, faction.color + " 换个颜色…",
                         lambda: self.pick_faction_color(faction.faction_id),
                         padx=6, pady=2,
                         bg=UI["panel_alt"], fg=UI["text"],
                         activebackground="#3a3d42").pack(side="left", padx=(6, 0))

        # 大本营那一栏
        if faction is None:
            self.faction_base_label.configure(text="先选一个阵营。")
            self.faction_base_btn.configure(state="disabled", text="把大本营设在这里")
        else:
            base = self.model.faction_base_of(faction.faction_id)
            self.faction_base_label.configure(
                text=("大本营：(%d, %d)" % base) if base else "大本营：还没设")
            self.faction_base_btn.configure(
                state="normal",
                text=("取消「%s」的大本营" % faction.label()) if base
                     else "把大本营设在这里",
                fg=(UI["text"] if base else UI["accent"]))

        # 「选中那一格」现在归谁 —— 可以直接在下拉框里改（等于把大本营挪过去）
        row = self.faction_tile_section
        for child in row.winfo_children():
            child.destroy()
        if self.inspect is None or not self.model.exists(*self.inspect):
            tk.Label(row, text="还没选格子：在「地块」页签左键点一格。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left", wraplength=280).pack(fill="x")
        else:
            x, y = self.inspect
            owner = self.model.faction_base_owner(x, y)
            tk.Label(row, text="(%d, %d) 现在：%s" % (x, y,
                     ("「%s」的大本营" % owner) if owner else "不是任何阵营的大本营"),
                     bg=UI["panel"], fg=UI["text"], anchor="w",
                     justify="left", wraplength=280).pack(fill="x")
            if self.model.factions:
                names = [f.label() for f in self.model.factions]
                self.faction_tile_choice = tk.StringVar(
                    value=next((f.label() for f in self.model.factions
                                if f.faction_id == owner), names[0]))
                combo = ttk.Combobox(row, textvariable=self.faction_tile_choice,
                                     values=names, state="readonly")
                combo.pack(fill="x", pady=(4, 0))
                combo.bind("<<ComboboxSelected>>", lambda e: self.assign_base_by_label())
            else:
                tk.Label(row, text="还没有阵营：先在上面新建一个。", bg=UI["panel"],
                         fg=UI["text_dim"], anchor="w").pack(fill="x")

    def assign_base_by_label(self) -> None:
        """把「选中那一格」的大本营改成下拉框里选的那个阵营。"""
        if self.inspect is None or not self.model.exists(*self.inspect):
            return
        label = self.faction_tile_choice.get()
        faction = next((f for f in self.model.factions if f.label() == label), None)
        if faction is None:
            return
        x, y = self.inspect
        if self.model.faction_base_of(faction.faction_id) == (x, y):
            return
        stolen = self.model.faction_base_owner(x, y)
        self.push_undo()
        if not self.model.set_faction_base(faction.faction_id, x, y):
            self._undo.pop()
            return
        self.mark_dirty()
        if stolen is not None:
            self.status("(%d, %d) 改成「%s」的大本营（原来属于「%s」）"
                        % (x, y, faction.faction_id, stolen))
        else:
            self.status("(%d, %d) 设成「%s」的大本营" % (x, y, faction.faction_id))
        self.refresh_faction_panel()
        self.redraw()

    # ---- 阵营页的编辑动作 ----

    def add_faction(self) -> None:
        """新建阵营：弹一个输入框问 id（默认给下一个没被占用的 p 号）。

        ★ 建议值从 **p1** 开始（p1 = 单机 / 房主），所以第一次新建按回车就是玩家那一方。
        """
        suggestion = next((fid for fid in FACTION_ROSTER
                           if self.model.faction(fid) is None), FACTION_DEFAULT)
        fid = _ask_string(self.root, "新建阵营",
                          "阵营 id（游戏里的名字，如 p1 / p2 / enemy）：", suggestion)
        if fid is None:
            return
        fid = fid.strip()
        if not fid:
            self.status("阵营 id 不能为空")
            return
        self.push_undo()
        faction = self.model.add_faction(fid)
        if faction is None:
            self._undo.pop()
            self.status("阵营「%s」已经存在了" % fid)
            return
        self.selected_faction = faction.faction_id
        self.mark_dirty()
        self.status("新建了阵营「%s」——在地图上点一格，再回来按「把大本营设在这里」"
                    % faction.faction_id)
        self.refresh_sidebar()
        self.redraw()

    def delete_selected_faction(self) -> None:
        faction = self.model.faction(self.selected_faction) if self.selected_faction else None
        if faction is None:
            self.status("先在列表里选一个阵营")
            return
        base = self.model.faction_base_of(faction.faction_id)
        extra = "（它的大本营 (%d, %d) 也会一起忘掉）" % base if base else ""
        if not messagebox.askyesno("删除阵营", "删掉阵营「%s」？%s" % (faction.label(), extra)):
            return
        self.push_undo()
        self.model.remove_faction(faction.faction_id)
        self.selected_faction = (self.model.factions[0].faction_id
                                 if self.model.factions else None)
        self.mark_dirty()
        self.status("删掉了阵营「%s」" % faction.label())
        self.refresh_sidebar()
        self.redraw()

    def apply_faction_name(self) -> None:
        faction = self.model.faction(self.selected_faction) if self.selected_faction else None
        if faction is None or not hasattr(self, "faction_name_var"):
            return
        new_name = self.faction_name_var.get().strip()
        if not new_name or new_name == faction.name:
            return
        self.push_undo()
        self.model.rename_faction(faction.faction_id, new_name)
        self.mark_dirty()
        self.refresh_faction_panel()

    def pick_faction_color(self, faction_id: str) -> None:
        """换阵营颜色（编辑器里的标识色，游戏不读它）。"""
        faction = self.model.faction(faction_id)
        if faction is None:
            return
        try:
            from tkinter import colorchooser
            _, hex_color = colorchooser.askcolor(color=faction.color,
                                                 title="阵营颜色（只影响编辑器显示）",
                                                 parent=self.root)
        except Exception:                       # noqa: BLE001 - 无头环境下没有取色器
            hex_color = None
        if not hex_color:
            return
        self.push_undo()
        self.model.set_faction_color(faction_id, hex_color)
        self.mark_dirty()
        self.refresh_faction_panel()

    def toggle_faction_base(self) -> None:
        """把「属性面板正在看的那一格」设成 / 取消选中阵营的大本营。

        ★ 用 `self.inspect`（面板正在看的格子）而不是鼠标位置：需求要的是
          「先在面板里选格，再点按钮」—— 这样松手时鼠标在哪都不影响，也不会手一抖设错格。
        """
        faction = self.model.faction(self.selected_faction) if self.selected_faction else None
        if faction is None:
            self.status("先在列表里选一个阵营")
            return
        if self.inspect is None:
            self.status("先在地图上点一格（左键点地块 = 选中它），再来设大本营")
            return
        x, y = self.inspect
        if not self.model.exists(x, y):
            self.status("(%d, %d) 还是虚线格：先把这格建出来" % (x, y))
            return
        if self.model.faction_base_of(faction.faction_id) == (x, y):
            self.push_undo()
            self.model.clear_faction_base(faction.faction_id)
            self.status("取消了「%s」的大本营" % faction.faction_id)
        else:
            stolen = self.model.faction_base_owner(x, y)
            self.push_undo()
            if not self.model.set_faction_base(faction.faction_id, x, y):
                self._undo.pop()
                return
            if stolen is not None:
                self.status("(%d, %d) 改成「%s」的大本营了（原来属于「%s」）"
                            % (x, y, faction.faction_id, stolen))
            else:
                self.status("(%d, %d) 设成「%s」的大本营" % (x, y, faction.faction_id))
        self.mark_dirty()
        self.refresh_faction_panel()
        self.redraw()

    def on_faction_select(self, event) -> None:
        if self._rebuilding or self._suppress_faction_event:
            return
        selection = self.faction_tree.selection()
        if not selection:
            return
        new_id = selection[0]
        if new_id == self.selected_faction:
            return
        self.selected_faction = new_id
        self._focus_canvas()
        self.refresh_faction_panel()

    def _click_faction_page(self, x: int, y: int) -> None:
        """阵营页签的左键：选中这一格为「属性面板的当前格」，并显示它属于谁的大本营。

        ★ 与区块页不同，这里**不改任何数据** —— 设大本营走面板里那颗按钮
          （需求要的是「先在面板里选格，再点按钮」），免得鼠标一抖就把某一方的基地挪走。
        """
        self.inspect = (x, y)
        owner = self.model.faction_base_owner(x, y)
        if owner is not None:
            self.status("(%d, %d) 是「%s」的大本营 —— 在右侧可以改成别的阵营" % (x, y, owner))
        elif self.model.faction(self.selected_faction) is not None:
            self.status("(%d, %d) 已选中 —— 在右侧按「把大本营设在这里」"
                        % (x, y))
        else:
            self.status("先在右侧列表里新建 / 选中一个阵营")
        # 这一格只是「被选中」，不是批量框选：把框选清掉，免得两边状态打架
        self.selection = None
        self.refresh_faction_panel()
        self.redraw()

    def _build_zone_sidebar(self) -> None:
        sec = self._section(self.sidebar, "区块列表")
        wrap = tk.Frame(sec, bg=UI["panel"])
        wrap.pack(fill="both", expand=True)
        self.zone_tree = ttk.Treeview(wrap, columns=("tiles",), show="tree headings",
                                      height=8, selectmode="browse")
        self.zone_tree.heading("#0", text="名字")
        self.zone_tree.heading("tiles", text="地块")
        self.zone_tree.column("#0", width=190, anchor="w")
        self.zone_tree.column("tiles", width=60, anchor="e")
        scroll = ttk.Scrollbar(wrap, orient="vertical", command=self.zone_tree.yview)
        self.zone_tree.configure(yscrollcommand=scroll.set)
        self.zone_tree.pack(side="left", fill="both", expand=True)
        scroll.pack(side="right", fill="y")

        self.zone_tree.bind("<<TreeviewSelect>>", self.on_zone_select)
        self.zone_tree.bind("<Double-1>", lambda e: self.rename_selected_zone())

        btn_row = tk.Frame(sec, bg=UI["panel"])
        btn_row.pack(fill="x", pady=(6, 0))
        self._button(btn_row, "新建区块", self.add_zone, padx=8, pady=4,
                  bg=UI["panel_alt"], fg=UI["text"],
                  activebackground="#3a3d42").pack(side="left", expand=True, fill="x",
                                                    padx=(0, 3))
        self._button(btn_row, "删除", self.delete_selected_zone, padx=8, pady=4,
                  bg="#5a2f2f", fg="#ffdede",
                  activebackground="#7a3d3d").pack(side="left", expand=True, fill="x",
                                                   padx=(3, 0))

        # ---- 选中区块的详情
        zsec = self._section(self.sidebar, "选中的区块")
        self.zone_selected_row = tk.Frame(zsec, bg=UI["panel"])
        self.zone_selected_row.pack(fill="x")
        self._button(zsec, "清空这个区块的地块", self.clear_selected_zone_tiles,
                     padx=8, pady=4, bg=UI["panel_alt"], fg=UI["text"],
                     activebackground="#3a3d42").pack(fill="x", pady=(8, 2))
        self._button(zsec, "把清空后的地块变回虚线格", self.delete_selected_zone_tiles,
                     padx=8, pady=4, bg="#3a3d42", fg="#ffdede",
                     activebackground="#5a2f2f").pack(fill="x", pady=2)

        # ---- 图例（哪个颜色是哪个区块 / 正在划分哪一个）
        self.zone_legend = self._section(self.sidebar, "图例")

        # 列表、选中区块的详情、图例都填一次（就地改值，见 refresh_zone_panel）
        self.refresh_zone_panel()

    def refresh_zone_panel(self) -> None:
        """就地刷新区块页那几栏：列表的**名字/地块数** + 选中区块的详情 + 图例。

        ★ 什么时候用它、什么时候用 `refresh_sidebar()`：
          · **加 / 删区块**（列表的**行数**变了）→ 重建整条（`refresh_sidebar()`）；
          · 改名字 / 划走一格 / 换选中项（行数没变）→ 用这里就地改值。
        重建整条要重新 new 一个 Treeview 并把 24 行重新 insert 一遍（实测 300+ ms 一页），
        而「点一下地块划给区块」「在列表里换个区块」都是高频操作，绝不能走那条路。
        """
        if self.page != "zone":
            return
        # 列表：行数不变时只改每行的文字与数字（不再 insert/delete）
        rows = sorted(self.model.zones, key=lambda z: z.zone_id)
        iids = [str(z.zone_id) for z in rows]
        if list(self.zone_tree.get_children()) != iids:
            self._suppress_zone_event = True
            try:
                self.zone_tree.delete(*self.zone_tree.get_children())
                for zone in rows:
                    self.zone_tree.insert("", "end", iid=str(zone.zone_id),
                                          text=zone.name, values=(zone.tile_count,))
            finally:
                self._suppress_zone_event = False
        else:
            for zone in rows:
                self.zone_tree.item(str(zone.zone_id), text=zone.name,
                                    values=(zone.tile_count,))
        if self.selected_zone is not None and self.zone_tree.exists(str(self.selected_zone)):
            self.zone_tree.selection_set(str(self.selected_zone))

        # 选中区块的详情
        row = self.zone_selected_row
        # ⚠️ 这一行会被**销毁重建**（`zone_name_var` / 按钮都要重新接），而重建会打断
        #    「正在输入框里打字」这件事：用户按 Enter 或点到别处改名时，输入框没了，
        #    键盘焦点会掉回画布 —— 想接着改就得再点一次输入框（实测过）。
        #    所以先记下「焦点原来在不在这条详情里」，重建后把它放回新的输入框。
        had_focus = self._focus_inside(row)
        for child in row.winfo_children():
            child.destroy()
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None:
            tk.Label(row, text="在列表里选一个区块，\n然后左键点地图上的地块来划给它。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w",
                     justify="left").pack(fill="x")
        else:
            tk.Label(row, text="名字", bg=UI["panel"], fg=UI["text_dim"]).pack(side="left")
            self.zone_name_var = tk.StringVar(value=zone.name)
            entry = ttk.Entry(row, textvariable=self.zone_name_var)
            entry.pack(side="left", fill="x", expand=True, padx=(6, 4))
            entry.bind("<Return>", lambda e: self.apply_zone_name())
            entry.bind("<FocusOut>", lambda e: self.apply_zone_name())
            self._button(row, "✓", self.apply_zone_name, padx=6,
                         bg=UI["panel_alt"], fg=UI["text"],
                         activebackground="#3a3d42").pack(side="left")
            tk.Label(row, text="　地块数：%d" % zone.tile_count, bg=UI["panel"],
                     fg=UI["text"], anchor="w").pack(side="left")
            if had_focus:
                try:
                    entry.focus_set()
                except tk.TclError:
                    pass

        # 图例
        for child in self.zone_legend.winfo_children():
            child.destroy()
        for zone in rows:
            color = self.zone_color(zone.zone_id)
            line = tk.Frame(self.zone_legend, bg=UI["panel"])
            line.pack(fill="x")
            tk.Label(line, text="　", bg=color, width=2).pack(side="left")
            label = zone.name
            if zone.zone_id == self.selected_zone:
                label += "　← 正在划分"
            tk.Label(line, text=" " + label, bg=UI["panel"],
                     fg=UI["text"] if zone.zone_id == self.selected_zone else UI["text_dim"],
                     anchor="w").pack(side="left", fill="x")

    def _focus_inside(self, widget) -> bool:
        """键盘焦点现在是不是落在 `widget` 这棵子树里（用来判断「用户正在这里打字」）。

        比的是控件的**路径名**（`winfo_name()` 那串点分路径），因为路径名对同一个窗口
        里的控件是唯一的 —— 而 `focus_get()` 给的是控件对象，销掉重建之后它不是新的那一个。
        焦点不在本窗口时 `focus_get()` 返回 None，一律当 False。
        """
        try:
            focused = self.root.focus_get()
        except (tk.TclError, KeyError):
            return False
        if focused is None:
            return False
        try:
            mine = str(widget)
            got = str(focused)
        except tk.TclError:
            return False
        return got == mine or got.startswith(mine + ".")

    def _build_map_section(self) -> None:
        """地图级别的操作（页签切换时都会出现，所以单独建）。

        ★ 这里**没有**「地图尺寸」这个东西，是刻意的：设计师画出来的地图可以是不规则形状
        （内部不会缺格），边界由已画地块的包围盒决定；导出时编辑器自动把它搬到 (0,0)
        （见 mapfile.model_to_dict）。让人先填一个「宽 × 高」再往里画，纯属多余的一步，
        而且填小了会把画好的地裁掉。
        """
        tk.Frame(self.sidebar, bg=UI["line"], height=1).pack(fill="x", pady=(10, 0))
        sec = self._section(self.sidebar, "整张地图")
        self._button(sec, "全部清空（地块都变回虚线格）", self.clear_all_tiles,
                     padx=6, pady=3, bg="#5a2f2f", fg="#ffdede",
                     activebackground="#7a3d3d").pack(fill="x")
        tk.Label(sec, text="导出范围 = 已画地块的包围盒（自动算），不用手工填尺寸；\n"
                           "地图可以是不规则形状（内部不会缺格）。\n"
                           "画布四个方向都能画（往左上画就是负坐标），\n"
                           "兜底边界 ±%d 格（内存上限，不是地图的限制）。"
                           % MAX_COORD,
                 bg=UI["panel"], fg=UI["text_dim"], anchor="w", justify="left",
                 wraplength=290).pack(fill="x", pady=(4, 0))

    def refresh_sidebar(self) -> None:
        """重建侧边栏（**换格子 / 切页签 / 改区块**才用；同一格改属性请用 refresh_tile_panel）。

        ⚠️ 重建整条侧边栏要 20+ ms（实测：销毁 20 来个控件 + 重新布局），
        所以「点一下地」这种高频操作绝不能走这里 —— 见 refresh_tile_panel 的就地改值。

        ⚠️⚠️ 必须防重入：重建会销毁/新建 Treeview，而 tk 在**创建和销毁** Treeview 时
        都会派发一次 `<<TreeviewSelect>>` —— 于是 `on_zone_select`（选区变化）调
        `refresh_sidebar` 就又重建一次，无限递归、程序直接无响应（实测踩过：
        点「地块」再点「区块」必现）。`_suppress_zone_event` 挡不住，因为它是「本次填充
        期间别响应」的意思，而事件是在**建控件的那一步**就发出来的。
        所以这里再加一层「正在重建中，谁也别再让我重建」的硬闸。
        """
        if self._rebuilding:
            return
        self._rebuilding = True
        try:
            self._build_sidebar()
        finally:
            self._rebuilding = False

    # ==================================================================
    # 颜色
    # ==================================================================

    def terrain_color(self, terrain: str) -> str:
        return to_hex(parse_color(self.color_cfg.get(terrain, DEFAULT_COLORS["grass"])))

    def text_on(self, color_hex: str) -> str:
        try:
            r = int(color_hex[1:3], 16)
            g = int(color_hex[3:5], 16)
            b = int(color_hex[5:7], 16)
        except (ValueError, IndexError):
            return UI["text"]
        return "#101010" if (r + g + b) > 380 else "#f0f0f0"

    def zone_color(self, zone_id: int) -> str:
        base = parse_color(ZONE_PALETTE[zone_id % len(ZONE_PALETTE)])
        return to_hex(base)

    def faction_color(self, faction) -> str:
        """阵营的标识色（编辑器里用来画大本营标记；游戏不读这个颜色）。

        ★ 优先取 `config.json` 的 `colors.faction.<id>.main` —— 这样编辑器里看到的
        「玩家是黄的、p2 是蓝的」与游戏里完全一致；config 里没有的 id 才用阵营自己存的颜色
        （新建阵营时按 FACTION_PALETTE 分了一个）。
        """
        faction_cfg = self.color_cfg.get("faction")
        if isinstance(faction_cfg, dict):
            entry = faction_cfg.get(faction.faction_id)
            if isinstance(entry, dict) and isinstance(entry.get("main"), str):
                return to_hex(parse_color(entry["main"]))
        return faction.color

    def blend_to_hex(self, bottom: Tuple[int, int, int, float], top_text, k: float) -> str:
        return to_hex(blend(bottom, parse_color(top_text), k))

    # ==================================================================
    # 坐标换算
    # ==================================================================

    def tile_px(self) -> float:
        return 36.0 * self.zoom

    def view_size(self) -> Tuple[float, float]:
        return (self.model.cols * self.tile_px(), self.model.rows * self.tile_px())

    # ---- 屏幕 ↔ 格子 ----
    #
    # ⚠️ 这里有两套坐标，别混（模型里也只有这两个换算，见 MapModel.view_of / world_of）：
    #   · **世界坐标**：设计师看到的绝对坐标，(0,0) 是画布的起点，往左上画就是负数。
    #     鼠标点击、状态栏、属性面板、导出，一律用它。
    #   · **数组下标**（view）：`ox/oy` 这个视野偏移是按它算的（0 = 数组第一格）。
    #     只有重绘与 `visible_tile_range()` 用它，因为那里每帧要点上千个格子。
    #   换算只有两个方向，都在下面这两对方法里。

    def view_to_world(self, vx: int, vy: int) -> Tuple[int, int]:
        """数组下标 → 世界坐标（给状态栏/悬停用）。"""
        return self.model.world_of(vx, vy)

    def world_to_view(self, x: int, y: int) -> Tuple[int, int]:
        """世界坐标 → 数组下标（给视野换算用）。"""
        return self.model.view_of(x, y)

    def tile_to_screen(self, x: int, y: int) -> Tuple[float, float]:
        """世界坐标 → 屏幕像素。"""
        size = self.tile_px()
        vx, vy = self.model.view_of(x, y)
        return (self.ox + vx * size, self.oy + vy * size)

    def view_to_screen(self, vx: int, vy: int) -> Tuple[float, float]:
        """数组下标 → 屏幕像素（重绘内部用，省一次换算）。"""
        size = self.tile_px()
        return (self.ox + vx * size, self.oy + vy * size)

    def screen_to_tile(self, sx: float, sy: float) -> Optional[Tuple[int, int]]:
        """屏幕坐标 → **世界坐标**的格子。画布是无限的，所以永远有格子（不会返回 None）。

        真正的边界只有兜底上限 `±MAX_COORD`（正常画图撞不到），超出它就不接受落笔 ——
        见 `_within_limit`，而且那时候状态栏会明说。
        """
        size = self.tile_px()
        if size <= 0:
            return None
        vx = int((sx - self.ox) // size)
        vy = int((sy - self.oy) // size)
        return self.model.world_of(vx, vy)

    def center_on(self, tx: float, ty: float) -> None:
        """把某一格（可以是小数）挪到视口正中。"""
        size = self.tile_px()
        cw = max(200, self.canvas.winfo_width())
        ch = max(200, self.canvas.winfo_height())
        self.ox = cw / 2 - tx * size
        self.oy = ch / 2 - ty * size

    def fit_view(self) -> None:
        """把**已画的地块**放进视野正中（空地图就退回原点附近）。"""
        cw = max(200, self.canvas.winfo_width())
        ch = max(200, self.canvas.winfo_height())
        box = self.model.bounds()
        if box is None:
            self.zoom = 1.0
            self.center_on(0, 0)
            return
        x0, y0, x1, y1 = box
        bw = max(1, x1 - x0 + 1)
        bh = max(1, y1 - y0 + 1)
        self.zoom = max(self.min_zoom,
                        min(self.max_zoom, min((cw - 48) / (bw * 36.0), (ch - 48) / (bh * 36.0))))
        self.center_on((x0 + x1 + 1) / 2.0, (y0 + y1 + 1) / 2.0)

    # ==================================================================
    # 绘制
    # ==================================================================

    def visible_tile_range(self) -> Tuple[int, int, int, int]:
        """当前视野覆盖的**数组下标**范围（含边界外一圈）。

        ★ 不再夹到地图范围内：编辑器上的画布是**无限**的，视野里永远有格子
        （只不过地图外的那些是虚线格、还不能站人）。
        ⚠️ 返回的是**数组下标**，不是世界坐标 —— 重绘里逐格扫一千次，这样省一次换算。
        要显示给用户看的时候记得过一手 `view_to_world()`。
        """
        size = self.tile_px()
        cw, ch = self.canvas.winfo_width(), self.canvas.winfo_height()
        x0 = int((0 - self.ox) // size) - 1
        y0 = int((0 - self.oy) // size) - 1
        x1 = int((cw - self.ox) // size) + 1
        y1 = int((ch - self.oy) // size) + 1
        return (x0, y0, x1, y1)

    def redraw(self) -> None:
        """真正重画（比较贵：一次 3~20ms，图元上千）。

        ⚠️ 别在鼠标事件里直接调它 —— 鼠标一秒能发上百个事件，每个都全量重绘会卡成幻灯片
        （实测拖动 100 个事件要 2 秒）。要重画请调 request_redraw()，它会把同一帧里的
        多个请求合并成一次。只有「必须立刻看到结果」的地方（开局、切换页签、导入导出）
       才直接调 redraw()。
        """
        self._redraw_job = None
        c = self.canvas
        c.delete("all")
        size = self.tile_px()
        cw, ch = self.canvas.winfo_width(), self.canvas.winfo_height()
        vx0, vy0, vx1, vy1 = self.visible_tile_range()
        grass_rgb = parse_color(self.color_cfg.get("grass", DEFAULT_COLORS["grass"]))
        grass_alt_rgb = parse_color(self.color_cfg.get("grass_alt", DEFAULT_COLORS["grass_alt"]))
        forest_rgb = parse_color(self.color_cfg.get("forest", DEFAULT_COLORS["forest"]))
        mountain_rgb = parse_color(self.color_cfg.get("mountain", DEFAULT_COLORS["mountain"]))

        # 0) 底色：整块画布一个色，**不做棋盘格**（背景上不该有任何线条/花纹）
        c.create_rectangle(0, 0, cw, ch, fill=UI["canvas_bg"], outline="")

        # 1) 虚线格：一张铺满视野的虚线网格，就是「这里可以点一下建地块」的暗示。
        #    ⚠️ 每一格单独一个虚线方框（不是一条大网格线）：只有方框才是「虚线格子」，
        #       贯通的长线看起来就是实心网格 —— 这两者的观感差别很大，别改回去。
        #    ⚠️ 格子小于 MIN_GRID_PX 就不画了：缩远时格子多到爆炸（一屏 4000+），
        #       而且那个尺寸下也看不出是格子。这条是「卡」的主要来源之一。
        #    ⚠️ 已经有地块的格子不画虚线框：本来画了也会被地块盖住（白画几百个图元），
        #       而且被盖住的那个虚线框会把「已建地块」数出两份来。
        #    ⚠️ 格子偏小（16~11px）时改成「四角短虚线」：一个格子从 1 个虚框变成 4 条短线，
        #       看着还是虚线格，但在缩小的视图下更省（这一档原来一次重绘要 ~20ms）。
        cells = max(1, (vx1 - vx0 + 1) * (vy1 - vy0 + 1))
        if cells <= EMPTY_CELL_LIMIT and size >= MIN_GRID_PX:
            dash_pattern = (3, 3)
            if size >= BIG_CELL_PX:
                for ty in range(vy0, vy1 + 1):
                    y0 = self.oy + ty * size + 1
                    y1 = y0 + size - 2
                    for tx in range(vx0, vx1 + 1):
                        if self.model.exists_view(tx, ty):
                            continue
                        x0 = self.ox + tx * size + 1
                        c.create_rectangle(x0, y0, x0 + size - 2, y1,
                                           fill=UI["empty"], outline=UI["empty_line"],
                                           dash=dash_pattern)
            else:
                # 缩得比较小：一屏几百格，逐格画虚线框太费。
                # 改成「一整张虚线网格」（横线 + 竖线各一条多段线），图元从几百个降到 2 个，
                # 看着仍然是虚线格 —— 这个尺寸下两种画法肉眼几乎分不出来。
                seg: List[float] = []
                left = self.ox + vx0 * size
                right = self.ox + (vx1 + 1) * size
                for ty in range(vy0, vy1 + 2):
                    sy = self.oy + ty * size
                    seg.extend((left, sy, right, sy))
                for tx in range(vx0, vx1 + 2):
                    sx = self.ox + tx * size
                    seg.extend((sx, self.oy + vy0 * size, sx, self.oy + (vy1 + 1) * size))
                if seg:
                    c.create_line(*seg, fill=UI["empty_line"], dash=dash_pattern)

        # 2) 已存在的地块：铺实地形色（虚线格在它下面，被盖住；下面还要补扫一遍「露出来的部分」）
        for ty in range(vy0, vy1 + 1):
            for tx in range(vx0, vx1 + 1):
                if not self.model.exists_view(tx, ty):
                    continue
                x0, y0 = self.view_to_screen(tx, ty)
                terrain = self.model.terrain_view(tx, ty)
                if terrain == "forest":
                    rgb = forest_rgb
                elif terrain == "mountain":
                    rgb = mountain_rgb
                else:
                    rgb = grass_rgb if (tx + ty) % 2 == 0 else grass_alt_rgb
                c.create_rectangle(x0, y0, x0 + size, y0 + size, fill=to_hex(rgb), outline="")

        # 3) 区块底色 + 边界（只画视野内的地块）
        #    ⚠️ 区块的 tiles 存的是**世界坐标**，所以这里先换成数组下标再和视野比对。
        ox, oy = self.model.origin_x, self.model.origin_y
        for zone in sorted(self.model.zones, key=lambda z: z.zone_id):
            visible = [(t[0] + ox, t[1] + oy) for t in zone.tiles
                       if vx0 <= t[0] + ox <= vx1 and vy0 <= t[1] + oy <= vy1]
            if not visible:
                continue
            own = parse_color(ZONE_PALETTE[zone.zone_id % len(ZONE_PALETTE)])
            overlay = to_hex(blend((0, 0, 0), own, 0.22))
            line_color = self.zone_color(zone.zone_id)
            for (tx, ty) in visible:
                x0, y0 = self.view_to_screen(tx, ty)
                c.create_rectangle(x0, y0, x0 + size, y0 + size, fill=overlay,
                                   outline="", stipple="gray50")
            # 边界：邻格不属于同一区块（或地图外）的那条边画一条粗线
            for (tx, ty) in visible:
                x0, y0 = self.view_to_screen(tx, ty)
                x1, y1 = x0 + size, y0 + size
                for (dx, dy) in ((0, -1), (0, 1), (-1, 0), (1, 0)):
                    if self.model.zone_id_at_view(tx + dx, ty + dy) == zone.zone_id:
                        continue
                    if dx == 0 and dy == -1:
                        c.create_line(x0, y0, x1, y0, fill=line_color, width=2)
                    elif dx == 0 and dy == 1:
                        c.create_line(x0, y1, x1, y1, fill=line_color, width=2)
                    elif dx == -1:
                        c.create_line(x0, y0, x0, y1, fill=line_color, width=2)
                    else:
                        c.create_line(x1, y0, x1, y1, fill=line_color, width=2)

        # 4) 大本营
        if self.model.base is not None:
            bx, by = self.model.base
            x0, y0 = self.tile_to_screen(bx, by)
            cx, cy = x0 + size / 2, y0 + size / 2
            rr = max(4.0, size * 0.26)
            c.create_oval(cx - rr, cy - rr, cx + rr, cy + rr,
                          outline=UI["base"], width=3)
            c.create_line(cx - rr * 0.6, cy, cx + rr * 0.6, cy, fill=UI["base"], width=2)
            c.create_line(cx, cy - rr * 0.6, cx, cy + rr * 0.6, fill=UI["base"], width=2)

        # 4b) 各阵营的大本营：用**阵营色**画一个带旗杆的标记（与上面那个「地图默认点位」
        #     区分开 —— 那个是黄色圆圈加十字，这个是彩色实心方块 + 一根杆）。
        for faction in self.model.factions:
            base = self.model.faction_base_of(faction.faction_id)
            if base is None or not self.model.in_bounds(*base):
                continue
            x0, y0 = self.tile_to_screen(*base)
            if not (vx0 - 1 <= self.model.view_of(*base)[0] <= vx1 + 1
                    and vy0 - 1 <= self.model.view_of(*base)[1] <= vy1 + 1):
                continue                      # 不在视野里就别画（省图元）
            color = self.faction_color(faction)
            pad = max(2.0, size * 0.16)
            c.create_rectangle(x0 + pad, y0 + pad, x0 + size - pad, y0 + size - pad,
                               fill=color, outline="#101010", width=1)
            label = faction.faction_id
            if size >= 26:
                c.create_text(x0 + size / 2, y0 + size / 2, text=label,
                              fill=self.text_on(color),
                              font=("Microsoft YaHei UI", max(7, int(size * 0.26)), "bold"))

        # 5) 高亮：光标下的格子 + 属性面板里的格子
        if self.hover is not None:
            hx, hy = self.hover
            x0, y0 = self.tile_to_screen(hx, hy)
            c.create_rectangle(x0, y0, x0 + size, y0 + size,
                               outline=UI["accent"], width=2)
        if self.inspect is not None and self.inspect != self.hover:
            ix, iy = self.inspect
            x0, y0 = self.tile_to_screen(ix, iy)
            c.create_rectangle(x0 + 1, y0 + 1, x0 + size - 1, y0 + size - 1,
                               outline="#ffffff", width=2)

        # 6) 框选：拖动中画预览（虚线），松手后画落定的矩形（实线 + 淡填充）
        rect = self.selection
        dashed = False
        if self._select_drag is not None:
            (ax, ay), (cx, cy) = self._select_drag
            rect = (min(ax, cx), min(ay, cy), max(ax, cx), max(ay, cy))
            dashed = True
        if rect is not None:
            rx0, ry0 = self.tile_to_screen(rect[0], rect[1])
            rx1, ry1 = self.tile_to_screen(rect[2] + 1, rect[3] + 1)
            c.create_rectangle(rx0, ry0, rx1, ry1,
                               outline=SELECT_OUTLINE, width=2,
                               fill=SELECT_FILL, stipple="gray25",
                               dash=(4, 3) if dashed else None)
            if not dashed:
                # 落定之后在角上写一句「框了多少格」——省得设计师自己去数
                c.create_text(rx0 + 4, ry0 + 4, anchor="nw",
                              text="%d 格" % len(self.batch_tiles()),
                              fill=SELECT_OUTLINE,
                              font=("Microsoft YaHei UI", 9, "bold"))

    def blend_hex(self, bg_hex: str, top, k: float) -> str:
        return to_hex(blend(parse_color(bg_hex), parse_color(top), k))

    def request_redraw(self) -> None:
        """请求重画 —— 同一帧里的多次请求只做一次。

        ★ 为什么必须有它：鼠标一秒能发上百个 motion 事件（拖动/平移时），
        每个事件都全量重绘的话就是「一秒里干了两秒的活」，表现就是又卡又不跟手。
        这里用 after(共 16ms) 把这一批请求合并成一次重绘。
        """
        if self._redraw_job is not None:
            return
        self._redraw_job = self.root.after(REDRAW_COALESCE_MS, self.redraw)

    def cancel_redraw(self) -> None:
        """把还没执行的重画回调全部取消（窗口关闭时用，免得回调打到已销毁的控件上）。

        ⚠️ 悬停那次（`_hover_job`）也要取消：它是另一个 after 回调，
        窗口一关就变成「invalid command name ..._do_hover_redraw」的 Tcl 报错
        （实测：无头测试里关窗口时必刷一屏这个）。
        """
        self._cancel_hover_job()
        if self._redraw_job is not None:
            try:
                self.root.after_cancel(self._redraw_job)
            except tk.TclError:
                pass
            self._redraw_job = None

    # ==================================================================
    # 鼠标 / 键盘
    # ==================================================================

    # ---- 左键：空格按住时是「拖画面」，否则是画地块 ----

    def on_left_down(self, event) -> None:
        self._left_down_at = (event.x, event.y)
        self.canvas.focus_set()
        if self.space_held:
            self._pan_anchor = (event.x, event.y)
            return
        # ★ Shift + 拖拽 = 框选（只在地块页签；别的页签上点格子各有各的意思）。
        #   按下时先「武装」这次拖动，拖动中画预览矩形，松手才落地 ——
        #   这样「拖到一半反悔」只要把鼠标拖回起点（下面按 DRAG_TOLERANCE 判定）。
        if self.shift_is_held(event) and self.page == "tile":
            tile = self.screen_to_tile(event.x, event.y)
            if tile is not None and self._within_limit(*tile):
                self._select_drag = (tile, tile)

    def shift_is_held(self, event=None) -> bool:
        """现在按住 Shift 吗？

        ★ 两条来源取「或」：键盘事件维护的 `self.shift_held`，以及鼠标事件的 `state` 位。
          只信 `state` 会漏（tk 不保证它带修饰键，实测见过 0x0），
          只信键盘事件也会漏（窗口刚拿到焦点、或 Shift 是在别处按下再移过来的）。
        """
        if self.shift_held:
            return True
        return bool(getattr(event, "state", 0) & SHIFT_MASK) if event is not None else False

    def on_shift_down(self, event=None) -> None:
        self.shift_held = True

    def on_shift_up(self, event=None) -> None:
        self.shift_held = False
        # Shift 松开时如果正在拖框选预览，就当这一拖结束（避免留下一个「按住 Shift 才更新」
        # 的僵尸状态：预览矩形还停在半路上，而用户已经松手了）。
        if self._select_drag is not None:
            anchor, current = self._select_drag
            self._select_drag = None
            if anchor != current:
                self.setup_selection(anchor, current)
                self.request_redraw()

    def on_left_drag(self, event) -> None:
        if self._select_drag is not None:
            tile = self.screen_to_tile(event.x, event.y)
            if tile is not None:
                self._select_drag = (self._select_drag[0], tile)
                self.request_redraw()      # 预览矩形跟着鼠标走（合并重绘，不卡）
            return
        if self._pan_anchor is None:
            return
        self.ox += event.x - self._pan_anchor[0]
        self.oy += event.y - self._pan_anchor[1]
        self._pan_anchor = (event.x, event.y)
        self.request_redraw()

    def on_left_up(self, event) -> None:
        if self._select_drag is not None:
            anchor, current = self._select_drag
            self._select_drag = None
            tile = self.screen_to_tile(event.x, event.y)
            if tile is not None:
                current = tile
            self._left_down_at = None
            # 起点与终点是同一格（或只差一两像素）→ 当成「单击」，不当框选：
            # 与拖拽判定的容差用同一个常量，免得两套阈值打架。
            if anchor == current:
                self.selection = None
                self.inspect = anchor
                self.refresh_sidebar()
                self.redraw()
                return
            self.setup_selection(anchor, current)
            self.redraw()
            self.status("已框选 %d 个地块（范围 %s）——在右侧批量改地形 / 归属，或批量删除"
                        % (len(self.batch_tiles()), self._selection_text()))
            return
        was_panning = self._pan_anchor is not None
        self._pan_anchor = None
        start = self._left_down_at
        self._left_down_at = None
        if was_panning:
            return                      # 拖过画面了，这一次不算「点」
        if start is None:
            return                      # 没配对上的按下（比如按下时窗口失焦）：不猜，丢弃
        if abs(event.x - start[0]) > DRAG_TOLERANCE or abs(event.y - start[1]) > DRAG_TOLERANCE:
            return                      # 手抖拖了几像素：不当地块点击处理
        self.on_left_click(event)

    def _selection_text(self) -> str:
        if self.selection is None:
            return ""
        x0, y0, x1, y1 = self.selection
        return "(%d, %d) – (%d, %d)" % (x0, y0, x1, y1)

    def on_left_click(self, event) -> None:
        """左键点一下 = 建地块（虚线格）或看属性（已有地块）。

        ★ 需求：「开始时只有全虚线格子，左键点击任意虚线格子则在该格处创建空地，
        左键点击已有格子的地方打开该格的属性面板，在其中选择该格的地形」。
        所以这里没有「当前笔刷」——地形只能在该格的属性面板里选（见 set_tile_terrain）。

        ★ 为什么会顺带把新格子开在属性面板里：设计师点出一格地，下一步几乎必然是
        「它是什么地形」；面板跟着跳过去，这一步就省了。**不弹窗**，所以连片画地不被打断。
        """
        if self.space_held:
            return                      # 空格按住时左键是「拖画面」，不是画地块
        tile = self.screen_to_tile(event.x, event.y)
        if tile is None:
            return
        x, y = tile
        if not self._within_limit(x, y):
            return
        if self.page == "zone":
            self._click_zone_page(x, y)
            return
        if self.page == "faction":
            self._click_faction_page(x, y)
            return

        # ★ 正在框选时，左键点击 = 「结束框选、回到单格模式」：
        #   设计师框一片地改完地形之后，下一步多半是点某一格看它的属性 ——
        #   如果他点的是**选中区域里**的格子，就顺手把那一格开进面板（更符合直觉）。
        if self.selection is not None:
            self.selection = None
            self.show_tile_panel(x, y)
            self.redraw()
            self.status("(%d, %d)：已取消框选，右侧是这一格的属性" % (x, y))
            return

        if not self.model.exists(x, y):
            self.push_undo()
            before = (self.model.origin_x, self.model.origin_y)
            if not self.model.ensure_tile(x, y):
                self._undo.pop()
                # 走到这里说明「坐标没越界（_within_limit 已经放行），但网格会长到吃不消」——
                # 这是内存安全网（见 model.MAX_GRID_BYTES），必须说清楚，
                # 不然又是一条让人摸不着头脑的隐形线。
                self.status("(%d, %d) 放不下：那一片网格会占掉太多内存（上限约 %d MB）——"
                            "按 F 跳回已画的地块"
                            % (x, y, MAX_GRID_BYTES // (1024 * 1024)))
                return
            # ★ 往左上画会改动 origin（模型把整张数组右移/下移一格给负坐标让位）。
            #   格子画在屏幕上的位置 = ox + (世界坐标 + origin) × 格子大小，
            #   所以 origin 加了 S，ox 要**减** S×格子大小，画面才不会跟着动。
            self._follow_origin_shift(before)
            self.model.create_tile(x, y)          # 地形保持默认的空白（草地）
            self.mark_dirty()
            self.status("在 (%d, %d) 建了一个空白地块 —— 在右侧面板里选它的地形"
                        % (x, y))
        else:
            self.status("(%d, %d)：右侧面板里可以改地形 / 归属 / 大本营，或删掉它"
                        % (x, y))
        self.show_tile_panel(x, y)
        self.redraw()

    def _follow_origin_shift(self, before: Tuple[int, int]) -> None:
        """模型动过 `origin` 之后，把视野偏移反向补回来 —— **画面上一格都不该动**。

        推导（别凭感觉写符号，这里错过一次）：
          · 一格画在屏幕上的位置 = `ox + (世界坐标 + origin) × 格子大小`；
          · 模型给负坐标让位时把 `origin` 加了 `S`（数组整体右移/下移 `S` 格，
            老内容的世界坐标不变）；
          · 代入上式：`origin` 加了 `S`，要让屏幕位置不变，`ox` 就必须**减** `S×格子大小`。
        ⚠️ 原来这里写的是 `+=`，方向正好反了 —— 结果是「往左上画一格，画面整体
        往右下跳两格」（`origin` 的一格 + ox 的一格），用户报的「建地块时视角自己移动」
        就是它（`test_app.py::t_draw_up_left_no_invisible_wall` 现在钉住了这条：
        建格前后「已画好的那一格在屏幕上的位置」必须一模一样）。
        """
        dx = self.model.origin_x - before[0]
        dy = self.model.origin_y - before[1]
        if not dx and not dy:
            return
        size = self.tile_px()
        self.ox -= dx * size
        self.oy -= dy * size

    def show_tile_panel(self, x: int, y: int) -> None:
        """把属性面板切到 (x, y) 那一格（能就地改值就不整条重建）。

        结构判断在 `refresh_tile_panel()` 里（唯一一处），这里只管「换成哪一格」。
        """
        self.inspect = (x, y)
        if self._tile_widgets:
            self.refresh_tile_panel()
        else:
            self.refresh_sidebar()

    def _click_zone_page(self, x: int, y: int) -> None:
        """区块页签的左键：把地块划给当前选中的区块 / 再点一次移除（原逻辑，未改）。

        ★ 只有「刷新侧边栏」这一步从整条重建换成了就地改值（地块数 + 图例）——
        行数没变，没必要重建那个 24 行的 Treeview。
        """
        if self.selected_zone is None:
            self.status("先在侧边栏的区块列表里选一个区块（没有就新建一个）")
            return
        if not self.model.exists(x, y):
            self.status("(%d, %d) 还是虚线格：先切到「地块」页签把它建出来" % (x, y))
            return
        self.push_undo()
        action = self.model.toggle_tile_zone(x, y, self.selected_zone)
        if action == MapModel.TOGGLE_ASSIGNED:
            self.status("(%d, %d) 划给了「%s」" % (x, y, self.model.zone_display_name(self.selected_zone)))
        elif action == MapModel.TOGGLE_REMOVED:
            self.status("(%d, %d) 从「%s」里移除了" % (x, y, self.model.zone_display_name(self.selected_zone)))
        else:
            self.status("(%d, %d) 没有变化" % (x, y))
        self.mark_dirty()
        self.refresh_zone_panel()
        self.redraw()

    def on_right_click(self, event) -> None:
        """右键点一个地块 → 把它变回虚线格（删掉这个地块）。

        ★ 需求：「右键点击任意非虚线格会将其变为虚线格」。所以右键在虚线格上什么也不做
        （它不是「删除」的反操作，从零建一格永远走左键）。
        """
        if self.space_held:
            return
        tile = self.screen_to_tile(event.x, event.y)
        if tile is None:
            return
        x, y = tile
        if not self._within_limit(x, y):
            return
        if not self.model.exists(x, y):
            self.status("(%d, %d) 已经是虚线格了" % (x, y))
            return
        self.delete_tile(x, y)      # 与属性面板里那颗「删除这个地块」是同一个动作

    def _within_limit(self, x: int, y: int) -> bool:
        """落笔的兜底上限 —— 判据只有一处：`model.can_draw_at()`。

        ★ 这里的态度是「**别再有隐形线**」：正常画图撞不到这个上限；一旦撞到，
        状态栏必须把话说清楚 —— 是哪个方向、还能画多少格、怎么找回自己的图，
        而不是像以前那样只有一句「已经画到画布上限了」（而且鼠标扫过去毫无提示）。
        """
        if self.model.can_draw_at(x, y):
            return True
        (left, up), (right, down) = self.model.draw_room(x, y)
        self.status("(%d, %d) 超出可用范围：往左还能画 %d 格、往上 %d 格，"
                    "往右 %d 格、往下 %d 格（按 F 跳回已画的地块）"
                    % (x, y, left, up, right, down))
        return False

    def _limit_hint(self, x: int, y: int) -> str:
        """光标接近兜底上限时给一句提示（还没越界时用；离得远就返回空串）。

        ★ 为什么值得有这条：用户报的「隐形线」就是因为**只有点击时才提示**，
        鼠标扫过去什么都不显示 —— 设计师会以为编辑器坏了。
        ⚠️ 判据与「还差几格」都问模型（`draw_room`），别在本文件里另写一套：
        往左上画过之后世界坐标的可画范围是**不对称**的，
        曾经用 `abs(x)` 算距离，结果在那种地图上永远算不到边界（被测试当场抓住）。
        """
        (left, up), (right, down) = self.model.draw_room(x, y)
        room = min(left, up, right, down)
        if 0 <= room <= LIMIT_HINT_MARGIN:
            return "　⚠️ 离可用范围边界还剩 %d 格" % room
        return ""

    def on_motion(self, event) -> None:
        # ★ 先说两件「按着鼠标在动」的事 —— 它们**不能**只靠绑在 `<B1-Motion>` 上的回调：
        #   tk 在拖动期间不保证发 `<B1-Motion>`（实测带 B1 位的 `<Motion>` 走的是
        #   `<Motion>` 这条绑定）。漏了它的后果：框选预览矩形停在起点不动、
        #   平移看起来像没反应。所以这里按 state 里的 B1/B2 位来分派。
        state = getattr(event, "state", 0)
        if self._select_drag is not None or (state & BUTTON1_MASK and self._pan_anchor is None):
            self.on_left_drag(event)
            return
        if self._pan_anchor is not None:
            dx = event.x - self._pan_anchor[0]
            dy = event.y - self._pan_anchor[1]
            self.ox += dx
            self.oy += dy
            self._pan_anchor = (event.x, event.y)
            # 拖动一开始就把「光标下的格子」清掉：平移时鼠标下面的格子一直在换，
            # 留着不放会在拖动过程中画出一个**跟不上手**的高亮方框（看着就是「闪/顿」）。
            self.hover = None
            self.request_redraw()
            self.update_status(self.screen_to_tile(event.x, event.y))
            return
        tile = self.screen_to_tile(event.x, event.y)
        if tile == self.hover:
            return
        self.hover = tile
        self._cancel_hover_job()
        # 悬停重绘节流：鼠标快速划过时不至于每像素重画一次。
        # ⚠️ 这个值**直接决定高亮跟不跟手**：一次重绘只要 3~4 ms（实测），
        #    而 40 ms 的节流意味着高亮最多落后光标两帧半（肉眼看得出来「框在追鼠标」）。
        #    定成 16 ms（≈ 一帧）之后，高亮基本与光标同帧，重绘次数也没上去多少。
        self._hover_job = self.root.after(HOVER_THROTTLE_MS, self._do_hover_redraw)
        self.update_status(tile)

    def _cancel_hover_job(self) -> None:
        if self._hover_job is None:
            return
        try:
            self.root.after_cancel(self._hover_job)
        except tk.TclError:
            pass
        self._hover_job = None

    def _do_hover_redraw(self) -> None:
        self._hover_job = None
        self.request_redraw()

    def on_leave(self, event) -> None:
        self._cancel_hover_job()
        if self.hover is not None:
            self.hover = None
            self.request_redraw()

    # ---- 平移：中键拖动 / 空格 + 左键拖动 ----

    def on_middle_down(self, event) -> None:
        self._pan_anchor = (event.x, event.y)
        self.hover = None               # 同上：平移时不留高亮，免得画出一个错位的框
        self._set_cursor("fleur")

    def on_middle_drag(self, event) -> None:
        if self._pan_anchor is None:
            self._pan_anchor = (event.x, event.y)
            return
        self.ox += event.x - self._pan_anchor[0]
        self.oy += event.y - self._pan_anchor[1]
        self._pan_anchor = (event.x, event.y)
        self.request_redraw()

    def on_middle_up(self, event) -> None:
        self._pan_anchor = None
        self._set_cursor("")

    def on_space_down(self, event) -> None:
        """按住空格 = 进入平移模式（左键拖动移视野，不再画地块）。"""
        if isinstance(self.root.focus_get(), (tk.Entry, ttk.Entry, ttk.Combobox)):
            return                      # 正在输入框里打字，别抢
        self.space_held = True
        self._set_cursor("fleur")
        self.status("平移模式：按住空格拖动鼠标移动视野（松开空格回到画地块）")

    def on_space_up(self, event) -> None:
        if not self.space_held:
            return
        self.space_held = False
        self._set_cursor("")
        self.update_status(self.hover)

    def _set_cursor(self, cursor: str) -> None:
        try:
            self.canvas.configure(cursor=cursor or "")
        except tk.TclError:
            pass

    def _button(self, parent, text: str, command, **kwargs) -> tk.Button:
        """建一颗按钮，并顺手把两件麻烦事处理掉：

        1. `takefocus=0`：Tab 键遍历不落到按钮上；
        2. 点完把键盘焦点交还画布 —— 否则按钮会一直拿住焦点，
           而**空格在 tk 里是「激活当前焦点按钮」**，于是「按住空格拖画面」会变成
           「反复点最后按过的那颗按钮」（页签乱跳 / 看起来没反应，就是这个）。
        """
        kwargs.setdefault("takefocus", 0)
        kwargs.setdefault("bd", 0)
        kwargs.setdefault("relief", "flat")

        def wrapped() -> None:
            self._focus_canvas()
            command()

        return tk.Button(parent, text=text, command=wrapped, **kwargs)

    def _focus_canvas(self) -> None:
        """把键盘焦点交还给画布。

        为什么必须显式做：tk 的按钮在**点过之后**会拿住键盘焦点（takefocus=0 只影响 Tab 键
        遍历，不影响鼠标点击），而按钮一旦有焦点，空格键就会去「按」它 ——
        用户按住空格拖画面时，最后点过的那个页签就会被反复重选，看起来就是「点页签没反应」。
        """
        try:
            self.canvas.focus_set()
        except tk.TclError:
            pass

    def on_wheel(self, event, delta: Optional[int] = None) -> None:
        step = delta if delta is not None else event.delta
        if step == 0:
            return
        factor = 1.12 if step > 0 else 1 / 1.12
        new_zoom = max(self.min_zoom, min(self.max_zoom, self.zoom * factor))
        if abs(new_zoom - self.zoom) < 1e-9:
            return
        # 以光标为锚点：光标底下的那个点缩放前后不动
        mx, my = event.x, event.y
        gx = (mx - self.ox) / self.zoom
        gy = (my - self.oy) / self.zoom
        self.zoom = new_zoom
        self.ox = mx - gx * self.zoom
        self.oy = my - gy * self.zoom
        self.request_redraw()

    def _bind_keys(self) -> None:
        r = self.root
        # ⚠️ 所有单键快捷键都过一道 _shortcut()：光标在输入框里打字时（改区块名）
        #    不该顺手触发「F 适应视野」这种画布快捷键。
        #    （1/2/3 换地形那组已经删掉了：地形只能在属性面板里选，见 set_tile_terrain。）
        r.bind("<Control-z>", lambda e: self._shortcut(self.undo))
        r.bind("<Control-Z>", lambda e: self._shortcut(self.redo))
        r.bind("<Control-y>", lambda e: self._shortcut(self.redo))
        r.bind("<Control-s>", lambda e: self._shortcut(self.do_export))
        r.bind("<Control-o>", lambda e: self._shortcut(self.do_open))
        r.bind("<Control-n>", lambda e: self._shortcut(self.do_new))
        # Esc：先取消框选（更近的一层），没有框选时才切回地块页签
        r.bind("<Escape>", lambda e: self._shortcut(self.on_escape))
        # ★ 方向键的方向：按「看地图」的直觉 —— 按 ← = 视野往左走（看到左边更多），
        #   内容整体右移 ⇒ ox 变大。写反了会让人一按就觉得「怎么反的」。
        #   方向表在 pan_arrow() 里（唯一真相），这里只负责把按键接上它。
        for key in ("Left", "Right", "Up", "Down"):
            r.bind("<KeyPress-%s>" % key,
                   lambda e, k=key: self._shortcut(lambda: self.pan_arrow(k)))
        r.bind("<KeyPress-f>", lambda e: self._shortcut(lambda: (self.fit_view(), self.redraw())))
        r.bind("<KeyPress-g>", lambda e: self._shortcut(self.goto_base))

        # ---- 空格：按住 = 暂时进入「拖画面」模式（左键拖动平移视野）----
        # ⚠️ 只绑在 canvas 上，**不**绑 root：tk 里按钮一旦拿到键盘焦点，
        #    空格会去「激活」那颗按钮（表现：点过页签之后按空格，页签自己反复重选，
        #    看着就像「点页签没反应 / 页面乱跳」）。所以：
        #      · 按钮全部 takefocus=0；
        #      · 点按钮之后把键盘焦点交还给画布（见 _focus_canvas 的调用点）。
        #    这两条一起，空格才稳定等于「拖画面」。

    def _shortcut(self, action) -> None:
        """焦点在输入框里时忽略画布快捷键（返回 "break" 让 tk 别把按键再送给别的绑定）。"""
        if isinstance(self.root.focus_get(), (tk.Entry, ttk.Entry, ttk.Combobox)):
            return
        action()

    def pan_by(self, dx: float, dy: float) -> None:
        self.ox += dx
        self.oy += dy
        self.request_redraw()

    ## 方向键的位移表 —— **方向的唯一真相**。
    ##
    ## 直觉是「按 ← 就把视野往左推」：看得见的地图内容整体往右移 ⇒ ox 增大。
    ## 反过来写（把方向键当成滚动条）用起来会觉得整张图是倒着走的。
    ARROW_PAN = {
        "Left": (KEY_PAN_STEP, 0),
        "Right": (-KEY_PAN_STEP, 0),
        "Up": (0, KEY_PAN_STEP),
        "Down": (0, -KEY_PAN_STEP),
    }

    def pan_arrow(self, key: str) -> None:
        """按一次方向键（key ∈ Left/Right/Up/Down）。"""
        dx, dy = self.ARROW_PAN.get(key, (0, 0))
        if dx or dy:
            self.pan_by(dx, dy)

    def on_escape(self) -> None:
        """Esc：先取消框选，没框选时回到地块页签（两层，从「更近的一层」开始退）。"""
        if self.selection is not None or self._select_drag is not None:
            self.clear_selection()
            return
        self.set_page("tile")

    def setup_selection(self, anchor: Tuple[int, int], current: Tuple[int, int]) -> None:
        """Shift + 拖拽：把「起点格 → 当前格」这个矩形记成框选（松手时调）。"""
        (ax, ay), (cx, cy) = anchor, current
        self.selection = (min(ax, cx), min(ay, cy), max(ax, cx), max(ay, cy))
        self.inspect = None                 # 批量模式下不看单格属性
        self.refresh_sidebar()

    def goto_base(self) -> None:
        if self.model.base is None:
            self.status("还没有设大本营：左键点一格，在侧边栏按「把大本营设在这里」")
            return
        size = self.tile_px()
        cw, ch = self.canvas.winfo_width(), self.canvas.winfo_height()
        self.ox = cw / 2 - (self.model.base[0] + 0.5) * size
        self.oy = ch / 2 - (self.model.base[1] + 0.5) * size
        self.redraw()

    # ==================================================================
    # 页签
    # ==================================================================

    def set_page(self, page: str) -> None:
        self._focus_canvas()
        # ⚠️ 页签没变就什么都别做：点自己已经选中的那个页签（或 `Esc`）会进来，
        #    而重建一条侧边栏（区块页尤其贵：要 new 一个 24 行的 Treeview）是纯浪费。
        #    「点了必须有反应 / 不能卡」这条需求就靠这个提前返回。
        if page == self.page and self._sidebar_page == page:
            return
        # ★ 换页签时把框选清掉：框选面板只属于「地块」页，带到别的页上只会两边打架
        #   （区块页点一下会去划区块，阵营页点一下是选大本营的格子）。
        self.selection = None
        self._select_drag = None
        self.page = page
        self.sync_tabs()
        self.refresh_sidebar()
        if page == "zone" and self.selected_zone is None and self.model.zones:
            self.selected_zone = self.model.zones[0].zone_id
            self.refresh_zone_panel()
        if page == "faction" and self.selected_faction is None and self.model.factions:
            self.selected_faction = self.model.factions[0].faction_id
            self.refresh_faction_panel()
        self.redraw()

    def sync_tabs(self) -> None:
        for key, btn in self.tab_buttons.items():
            active = (key == self.page)
            btn.configure(bg=UI["panel_alt"] if active else UI["panel"],
                          fg=UI["accent"] if active else UI["text_dim"])

    # ==================================================================
    # 编辑动作
    # ==================================================================

    def set_tile_terrain(self, terrain: str) -> None:
        """把属性面板正在看的那一格改成某种地形（地形**只能**从这里改，没有笔刷）。

        ★ 走的是 `refresh_tile_panel()`（就地改值）而不是 `refresh_sidebar()`（整条重建）：
        改地形是连点操作（草→林→山试一遍），每次重建 20+ ms 就明显卡手了。
        """
        if self.inspect is None:
            return
        x, y = self.inspect
        if not self.model.exists(x, y):
            self.status("(%d, %d) 还是虚线格：先左键点它一下把它建出来" % (x, y))
            return
        if self.model.terrain_at(x, y) == terrain:
            self.status("(%d, %d) 本来就是%s" % (x, y, TERRAIN_LABELS[terrain]))
            return
        self.push_undo()
        self.model.set_terrain(x, y, terrain)
        self.mark_dirty()
        self.status("(%d, %d) 的地形 → %s" % (x, y, TERRAIN_LABELS[terrain]))
        self.refresh_tile_panel()
        self.redraw()

    def delete_tile(self, x: int, y: int) -> None:
        if not self.model.exists(x, y):
            return
        self.push_undo()
        self.model.delete_tile(x, y)
        self.mark_dirty()
        self.status("(%d, %d) 已删除（变回虚线格）" % (x, y))
        # ⚠️ 删的**不是**面板在看的那一格时，面板一个字都不许动
        #    （否则删掉别处的格子会把面板从「正在编辑的格子」上拽走）。
        # ⚠️ 顺序也别弄反：先让模型把这格删掉，再刷面板 ——
        #    refresh_tile_panel 是照着「这一格现在存不存在」画按钮的。
        if self.inspect == (x, y):
            self.refresh_tile_panel()   # 面板还指着它，就地变成「虚线格」的样子
        self.redraw()

    def toggle_base(self, x: int, y: int) -> None:
        self.push_undo()
        if self.model.base == (x, y):
            self.model.base = None
            self.status("取消了大本营")
        else:
            self.model.base = (x, y)
            self.status("大本营设在 (%d, %d)" % (x, y))
        self.mark_dirty()
        self.refresh_tile_panel()       # 就地改按钮文字，别重建整条侧边栏
        self.redraw()

    def on_zone_choice(self, x: int, y: int) -> None:
        name = self.zone_choice.get()
        self.push_undo()
        if name.startswith("（"):
            self.model.clear_zone(x, y)
            self.status("(%d, %d) 不再属于任何区块" % (x, y))
        else:
            zone = next((z for z in self.model.zones if z.name == name), None)
            if zone is not None:
                self.model.assign_tile(x, y, zone.zone_id)
                self.status("(%d, %d) 划给「%s」" % (x, y, zone.name))
        self.mark_dirty()
        self.refresh_tile_panel()
        self.redraw()

    def add_zone(self) -> None:
        self.push_undo()
        zone = self.model.add_zone()
        self.selected_zone = zone.zone_id
        self.mark_dirty()
        self.status("新建了区块「%s」：左键点地块就能划给它" % zone.name)
        self.refresh_sidebar()      # 列表多了一行 → 整条重建（行数变了，就地改值不够）
        self.redraw()

    def delete_selected_zone(self) -> None:
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None:
            self.status("先在列表里选一个区块")
            return
        if not messagebox.askyesno("删除区块", "删掉「%s」？\n它名下的 %d 个地块会变回「无归属」。"
                                               % (zone.name, zone.tile_count)):
            return
        self.push_undo()
        self.model.delete_zone(zone.zone_id)
        self.selected_zone = self.model.zones[0].zone_id if self.model.zones else None
        self.mark_dirty()
        self.refresh_sidebar()
        self.redraw()

    def rename_selected_zone(self) -> None:
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None:
            return
        self.push_undo()
        new_name = _ask_string(self.root, "重命名区块", "区块名：", zone.name)
        if new_name is None:
            return
        self.model.rename_zone(zone.zone_id, new_name)
        self.mark_dirty()
        self.refresh_zone_panel()
        self.status("区块改名为「%s」" % self.model.zone_display_name(zone.zone_id))

    def apply_zone_name(self) -> None:
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None or not hasattr(self, "zone_name_var"):
            return
        new_name = self.zone_name_var.get().strip()
        if new_name == zone.name:
            return
        self.push_undo()
        self.model.rename_zone(zone.zone_id, new_name)
        self.mark_dirty()
        self.refresh_zone_panel()

    def on_zone_select(self, event) -> None:
        # ⚠️ 三重保险，缺一不可（这条链踩过一次死循环，见 refresh_sidebar 的注释）：
        #   ① 正在重建侧边栏 → 这个事件是重建过程自己发出来的，忽略；
        #   ② 正在填充列表 → 忽略；
        #   ③ 选中的还是同一个人 → 不用做任何事（**也不重建侧边栏**，否则又是递归）。
        if self._rebuilding or self._suppress_zone_event:
            return
        selection = self.zone_tree.selection()
        if not selection:
            return
        try:
            new_id = int(selection[0])
        except ValueError:
            return
        if new_id == self.selected_zone:
            return
        self.selected_zone = new_id
        self._focus_canvas()
        self.refresh_zone_panel()
        self.status("正在划分「%s」：左键点地块划入 / 再点一次移除"
                    % self.model.zone_display_name(self.selected_zone))

    def clear_selected_zone_tiles(self) -> None:
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None or not zone.tiles:
            return
        self.push_undo()
        for tile in list(zone.tiles):
            self.model.clear_zone(*tile)
        self.mark_dirty()
        self.status("「%s」的地块清空了（地块本身还在）" % zone.name)
        self.refresh_zone_panel()
        self.redraw()

    def delete_selected_zone_tiles(self) -> None:
        zone = self.model.zone(self.selected_zone) if self.selected_zone is not None else None
        if zone is None or not zone.tiles:
            return
        n = len(zone.tiles)
        if not messagebox.askyesno("删除地块", "把「%s」名下的 %d 个地块整个删掉（变回虚线格）？"
                                               % (zone.name, n)):
            return
        self.push_undo()
        for tile in list(zone.tiles):
            self.model.delete_tile(*tile)
        self.mark_dirty()
        self.status("删掉了 %d 个地块" % n)
        self.refresh_zone_panel()
        self.redraw()

    def clear_all_tiles(self) -> None:
        if not messagebox.askyesno("清空画布", "把所有地块都删掉（变回虚线格）？\n区块本身会保留。"):
            return
        self.push_undo()
        self.model.clear_tiles()
        self.mark_dirty()
        self.status("画布已清空（地块全变回虚线格；区块保留，但名下不再有地块）")
        self.refresh_zone_panel()
        self.redraw()

    # ==================================================================
    # 文件
    # ==================================================================

    def _default_dir(self) -> str:
        data_dir = self.project_dir / "data"
        if self.current_path is not None:
            return str(self.current_path.parent)
        if data_dir.is_dir():
            return str(data_dir)
        return str(self.project_dir)

    def do_new(self) -> None:
        """新建地图：直接给一张**全新的无限虚线画布**，不再问宽 × 高。

        ★ 为什么不再问尺寸：设计时地图可以是任意不规则形状（内部不会缺格），
        尺寸是「导出时算出来的包围盒」，不是「画之前要填的参数」。
        所以「新建」等于「把画布清成一片虚线格」，和刚打开编辑器时一模一样。

        ⚠️ 别在这里顺手 resize 成 config 的 24×16：那会把「地图尺寸」这个已经删掉的概念
        又偷偷塞回来（0×0 ⇒ 点哪长哪，才是无限画布）。
        """
        if not self._confirm_discard():
            return
        self.model = mapfile.empty_map(0, 0, None)
        self.current_path = None
        self.inspect = None
        self.selected_zone = None
        self.selected_faction = None
        self.selection = None
        self._select_drag = None
        self._undo.clear()
        self._redo.clear()
        self.dirty = False
        self._need_initial_view = False
        self.update_title()
        self.zoom = 1.0
        self.center_on(0, 0)          # 空画布：原点居中、1:1（与刚打开编辑器时一致）
        self.refresh_sidebar()
        self.redraw()
        self.status("新建了一张空白地图：整张画布都是虚线格，左键点哪就在哪建地块")

    def do_open(self) -> None:
        if not self._confirm_discard():
            return
        path = filedialog.askopenfilename(
            title="打开地图 JSON", initialdir=self._default_dir(),
            filetypes=[("Godot 地图 JSON", "*.json"), ("所有文件", "*.*")])
        if not path:
            return
        try:
            model = mapfile.load_map(path, self.cfg)
        except MapError as exc:
            messagebox.showerror("打开失败", str(exc))
            return
        self.model = model
        self.current_path = Path(path)
        self.inspect = None
        self.selected_zone = self.model.zones[0].zone_id if self.model.zones else None
        self.selected_faction = self.model.factions[0].faction_id if self.model.factions else None
        self.selection = None
        self._select_drag = None
        self._undo.clear()
        self._redo.clear()
        self.dirty = False
        self.update_title()
        self.fit_view()
        self.refresh_sidebar()
        self.redraw()
        self.status("打开了 %s：%d×%d，%d 个地块，%d 个区块，%d 个阵营"
                    % (self.current_path.name, model.cols, model.rows,
                       model.existing_count(), len(model.zones), len(model.factions)))

    def do_export(self) -> None:
        problems = self.model.problems()
        if problems:
            text = "导出前提醒：\n\n· " + "\n· ".join(problems) + "\n\n仍然导出吗？"
            if not messagebox.askyesno("导出提醒", text):
                return
        initial = str(self.current_path) if self.current_path else str(
            self.project_dir / "data" / "map_01.json")
        path = filedialog.asksaveasfilename(
            title="导出地图 JSON", initialdir=self._default_dir(),
            initialfile=Path(initial).name,
            defaultextension=".json",
            filetypes=[("Godot 地图 JSON", "*.json"), ("所有文件", "*.*")])
        if not path:
            return
        try:
            saved = mapfile.save_map(path, self.model)
        except OSError as exc:
            messagebox.showerror("导出失败", str(exc))
            return
        self.current_path = saved
        self.dirty = False
        self.update_title()
        self.status("已导出到 %s（%d 个地块 / %d 个区块）"
                    % (saved, self.model.existing_count(), len(self.model.zones)))

    def _confirm_discard(self) -> bool:
        if not self.dirty:
            return True
        return messagebox.askyesno("还没导出", "当前地图有未导出的改动，直接丢掉吗？")

    # ==================================================================
    # 撤销 / 状态
    # ==================================================================

    def _snapshot(self) -> dict:
        m = self.model
        return {
            "cols": m.cols,
            "rows": m.rows,
            "existing": list(m.existing),
            "terrain": list(m.terrain),
            "zones": [(z.zone_id, z.name, set(z.tiles)) for z in m.zones],
            "zone_of": dict(m.zone_of),
            "base": m.base,
            # 阵营表与大本营也要进撤销栈（否则「设了大本营 → Ctrl+Z」会把它们漏掉）
            "factions": [(f.faction_id, f.name, f.color) for f in m.factions],
            "faction_bases": dict(m.faction_bases),
            # ⚠️ origin 必须一起存：撤销要能把「网格平移过」这件事也退回去，
            #    否则撤销之后同一格的世界坐标会整体偏移（区块 tiles 都是世界坐标，
            #    它们跟着快照一起回去，只有 origin 不回去就会全错位）。
            "origin": (m.origin_x, m.origin_y),
            "extra": copy.deepcopy(m.extra),
        }

    def _restore(self, snap: dict) -> None:
        m = MapModel(snap["cols"], snap["rows"])
        m.existing = list(snap["existing"])
        m.terrain = list(snap["terrain"])
        m.zone_of = dict(snap["zone_of"])
        m.base = snap["base"]
        m.origin_x, m.origin_y = snap.get("origin", (0, 0))
        m.extra = copy.deepcopy(snap["extra"])
        m.zones = []
        from .model import Faction, Zone
        for zid, name, tiles in snap["zones"]:
            zone = Zone(zid, name)
            zone.tiles = set(tiles)
            m.zones.append(zone)
        for fid, name, color in snap.get("factions", []):
            m.factions.append(Faction(fid, name, color))
        m.faction_bases = dict(snap.get("faction_bases", {}))
        m.recount()          # ⚠️ 绕过 set_existing 直接赋了 existing（见 MapModel.recount）
        self.model = m

    def push_undo(self) -> None:
        self._undo.append(self._snapshot())
        if len(self._undo) > UNDO_LIMIT:
            self._undo.pop(0)
        self._redo.clear()

    def undo(self) -> None:
        if not self._undo:
            self.status("没有可撤销的操作了")
            return
        self._redo.append(self._snapshot())
        self._restore(self._undo.pop())
        self.dirty = True
        self.inspect = None
        self.refresh_sidebar()
        self.redraw()
        self.status("撤销")

    def redo(self) -> None:
        if not self._redo:
            self.status("没有可重做的操作了")
            return
        self._undo.append(self._snapshot())
        self._restore(self._redo.pop())
        self.dirty = True
        self.inspect = None
        self.refresh_sidebar()
        self.redraw()
        self.status("重做")

    def mark_dirty(self) -> None:
        self.dirty = True
        self.update_title()

    def update_title(self) -> None:
        name = self.current_path.name if self.current_path else "未命名地图"
        star = " *" if self.dirty else ""
        self.root.title("DAEEM 地图编辑器 — %s%s" % (name, star))

    def status(self, text: str) -> None:
        self.status_var.set(text)

    def update_status(self, tile: Optional[Tuple[int, int]]) -> None:
        """状态栏：光标下的格子（**世界坐标**）+ 地图统计 + 边界提醒。

        ⚠️ `tile` 必须是世界坐标（`screen_to_tile` 给的就是世界坐标）：
        往左上画之后数组下标和世界坐标会差一个 origin，状态栏要显示的是
        设计师心里的那个绝对坐标。
        """
        model = self.model
        parts = []
        if tile is None:
            parts.append("光标：画布外")
        else:
            x, y = tile
            if model.exists(x, y):
                zone = model.zone_at(x, y)
                parts.append("光标：(%d, %d) %s　区块：%s" % (
                    x, y, TERRAIN_LABELS.get(model.terrain_at(x, y), "?"),
                    zone.name if zone else "无"))
            else:
                parts.append("光标：(%d, %d) 虚线格（左键创建地块）" % (x, y))
            hint = self._limit_hint(x, y)
            if hint:
                parts.append(hint)
        base = "大本营：%s" % ("(%d, %d)" % model.base if model.base else "未设")
        parts.append("地块 %d" % model.existing_count())
        parts.append("区块 %d" % len(model.zones))
        parts.append(base)
        if self.page == "zone" and self.selected_zone is not None:
            parts.append("正在划分：%s" % model.zone_display_name(self.selected_zone))
        self.status("　|　".join(parts))


# ----------------------------------------------------------------------
# 小对话框
# ----------------------------------------------------------------------

def run(project_dir: Path, model: Optional[MapModel] = None,
        current_path: Optional[Path] = None) -> int:
    """打开编辑器窗口（阻塞到窗口关闭）。"""
    root = tk.Tk()
    EditorApp(root, project_dir, model, current_path)
    try:
        root.lift()
        root.attributes("-topmost", True)
        root.after(200, lambda: root.attributes("-topmost", False))
    except tk.TclError:
        pass
    root.mainloop()
    return 0


def _ask_string(master, title: str, prompt: str, initial: str) -> Optional[str]:
    """一个极简的输入框（tkinter 没有内置的）。返回 None = 取消。"""
    dlg = tk.Toplevel(master)
    dlg.title(title)
    dlg.configure(bg=UI["panel"])
    dlg.resizable(False, False)
    dlg.transient(master)
    result: Dict[str, Optional[str]] = {"value": None}

    tk.Label(dlg, text=prompt, bg=UI["panel"], fg=UI["text"]).pack(padx=14, pady=(12, 4),
                                                                 anchor="w")
    var = tk.StringVar(value=initial)
    entry = ttk.Entry(dlg, textvariable=var, width=26)
    entry.pack(padx=14)
    entry.focus_set()
    entry.select_range(0, "end")

    def ok() -> None:
        result["value"] = var.get()
        dlg.destroy()

    row = tk.Frame(dlg, bg=UI["panel"])
    row.pack(padx=14, pady=12, anchor="e")
    tk.Button(row, text="取消", bd=0, relief="flat", padx=10, pady=4, bg=UI["panel_alt"],
              fg=UI["text"], activebackground="#3a3d42", command=dlg.destroy).pack(side="right",
                                                                                 padx=(6, 0))
    tk.Button(row, text="确定", bd=0, relief="flat", padx=10, pady=4, bg="#2f5f7a",
              fg="#eaf6ff", activebackground="#3a7699", command=ok).pack(side="right")
    dlg.bind("<Return>", lambda e: ok())
    dlg.bind("<Escape>", lambda e: dlg.destroy())
    dlg.grab_set()
    master.wait_window(dlg)
    return result["value"]
