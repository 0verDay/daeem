"""app.py —— 战役编辑器的界面（tkinter，零依赖）。

布局（照 `unit_editor` / `map_editor` 那一套，用熟了就不用重新学）：

    ┌────────────────────────────────────────────────────────────┬──────────────┐
    │ [战役] [关卡] [阵营] [摆放] [校验与导出]    保存 重新载入 │              │
    ├────────────────────────────────────────────────────────────┤   侧边栏      │
    │                                                            │  （可滚）     │
    │   画布 / 列表（随页签变）                                    │              │
    │                                                            │              │
    ├────────────────────────────────────────────────────────────┴──────────────┤
    │ 状态栏：当前战役 · 关卡 · 上一次操作的结果                                │
    └──────────────────────────────────────────────────────────────────────────┘

七个页签：

    ① 战役    战役名 / 简介 / 默认模式 / 关卡顺序（上下箭头 + 增删关卡）
    ② 关卡    名字 / 模式 / 地图下拉 / 玩家目标（每个可玩阵营一条）/ 额外失败条件
    ③ 阵营    敌友（边）+ 每一方一行（★可玩徽标）；大本营去 ④ 摆放页摆
    ④ 摆放    画布（点一下放东西、右键删、滚轮缩放、中键或**空格 + 左键拖动**平移）
    ⑤ 区划    开局每一块地归哪个阵营
    ⑥ 红点    画布点击模式：**生成地块 / 行军目标**；时间表 / 将领权重 / 共享附属规格
    ⑦ 校验与导出 逐条显示拦截与警告；有拦截就不许写文件；一键打开地图编辑器

★★ 摆放页**就是**开局部队的全部真相：地图上摆了什么，进游戏就有什么。
   那 3 位将领与它们的附属兵都**在这里摆**（画笔选「将领」/「附属兵」，
   附属兵还要选它**属于哪位将领**）；`config.json` 里已经没有任何「开局带几个兵」的开关了。
   ⚠️ 唯一的「看不到的东西」：某一方**一个附属兵都没摆**时，运行时会替它自动生成 3 位将领
      （历史行为，自由对战地图也靠它）；**只要摆了任何附属兵，运行时就整个不管这一方** ——
      连将领也得你自己摆。这条规则写在摆放页的侧栏提示里。

★★ 界面上必须写清楚的那条分工（不是只写在 README 里）：
    「地形 / 区划 / 中心从地图读出来画成背景；要改地形请点『打开地图编辑器』」
    —— 见 `CANVAS_HINT`，它印在 ④ 摆放页的画布上方。

★ AI 相关字段（`ai` / `attack_target` / `spawn_region` / `garrison_ai` / `reddot_ai`）
  **编辑器基本不提供编辑入口**（用户要求：不在编辑器里改 AI）：它们仍然原样读、原样写
  （不会丢），要改就手改关卡 JSON。
  ★★ 唯一例外：**红点的行军目标**在 ⑥ 红点页编辑（`reddot_ai.march_tiles`：多个格子，
  每位将领随机挑一个）—— 它取代了 ④ 摆放页原来那颗「设进攻目标…」按钮。

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

_TOOLS_DIR = Path(__file__).resolve().parent.parent
if str(_TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(_TOOLS_DIR))
from editor_catalog import add_campaign as catalog_add_campaign
from editor_catalog import campaign_ids as catalog_campaign_ids
from editor_catalog import map_ids as catalog_map_ids

from . import levelfile
from . import model as model_mod
from .model import (
    AI_COMMANDER,
    AI_GARRISON,
    AI_REDDOT,
    AI_KINDS,
    AI_NONE,
    ESCORT_OF_KEY,
    FAIL_ZONE_LOST,
    MODE_COOP,
    MODE_SOLO,
    OBJ_CAPTURE_ZONE,
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
    Issue,
    LevelModel,
    MapInfo,
    ModelError,
    UnitEntry,
    clean_number,
    fmt_sec,
)

#: 编辑器里优先显示的地图/战役（有用表在 `daeem/data/editor_visible.json`）。
def visible_map_ids(project_dir: Any) -> List[str]:
    return catalog_map_ids(project_dir)


def visible_campaign_ids(project_dir: Any) -> List[str]:
    return catalog_campaign_ids(project_dir)


#: 「属于将领」下拉里表示「不是附属兵」的那一项（普通摆放单位）。
ESCORT_NONE_LABEL = "（不是附属兵）"

#: ★ 「敌友（边）」下拉里的两项特殊文字（其余选项是「边 1」「边 2」…）。
#: `ALLY_UNSIDED` = 不属于任何一条边（与所有人都敌对，这也是默认）；
#: `ALLY_NEW_SIDE` = 为这一方**开一条新边**。
ALLY_UNSIDED = "（未分边 · 与所有人为敌）"
ALLY_NEW_SIDE = "＋ 新建一条边"
#: 「红点」页上那颗「新建阵营（自动红点性）」按钮的文字（测试按它找按钮）。
REDDOT_NEW_FACTION = "＋ 新建红点阵营…"


def _fmt_num(v: Any) -> str:
    """数字写成好看的字符串（整数不带 `.0`）—— 输入框初值用。"""
    try:
        f = float(v)
    except (TypeError, ValueError):
        return str(v)
    return str(int(f)) if f == int(f) else str(f)


#: 界面配色（与另两个编辑器同一套 —— 三个工具看起来是一家的）。
#:
#: ★ 「浅色（白）+ 极简」：`bg` = 页面底（顶栏 / 画布外圈），`panel` = 卡片 / 侧栏面（白），
#:   `panel_alt` = 输入框 / 按钮 / 列表行，`line` = 发丝分隔线。
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
    "danger_btn": "#d9534f",
    "danger_btn_hover": "#e26864",
    "danger_fg": "#ffffff",
    "hover": "#e6e9ee",
    "pressed": "#d9dde3",
    "ok": "#1f9d55",
    "warn": "#b7791f",
    "bad": "#d64545",
    "canvas_bg": "#e7eaee",
}

#: 七个页签：key → （按钮文字，状态栏提示）。
PAGES: Tuple[Tuple[str, str, str], ...] = (
    ("campaign", "战役", "战役页：名字 / 简介 / 默认模式 / 关卡顺序（上下箭头排、增删关卡）"),
    ("level", "关卡", "关卡页：当前关的名字 / 模式 / 地图 / 目标 / 额外失败条件"),
    ("factions", "阵营", "阵营页：敌友（边）+ 每一方一行；大本营去 ④ 摆放页摆（AI 不在编辑器里改，见 README）"),
    ("place", "摆放", "摆放页：画布上点一下放将领/单位/建筑；右键删；滚轮缩放；中键或空格+左键拖动"),
    ("zone", "区划", "区划页：开局每一块地归哪个阵营（关卡覆盖地图的 zone_list[].owner）"),
    ("reddot", "红点", "红点页：画布点击模式（生成地块 / 行军目标）/ 生成频率与将领数（函数表达式）/ 将领类型权重 / 共享附属单位规格"),
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
    "water": "#2e4f66",
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


# ======================================================================
# 主题：深色极简 + 圆角按钮 + 重建不闪白
#
# 三个编辑器（本工具 / unit_editor / map_editor）用**同一套**做法，
# 改这里请顺手把另两个也改了（它们刻意各留一份：互不依赖、双击就能跑）。
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
    """**圆角按钮**：本体还是 `tk.Button`，上面盖一层 Canvas 把方角画成圆角。

    ★ 为什么这么做：`invoke` / `cget` / `configure` / `pack` 全是**原生**语义，
      调用方与测试一行都不用改；盖层只负责画面，本体负责量尺寸与「点击 → invoke()」。
      四角填成父容器底色，于是看起来就是一枚圆角按钮。
    """

    RADIUS = 8.0

    def __init__(self, master=None, **kw):
        kw.setdefault("relief", "flat")
        kw.setdefault("bd", 0)
        kw.setdefault("highlightthickness", 0)
        kw.setdefault("takefocus", 0)
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

    def _text_color(self) -> str:
        if self._disabled():
            return UI["text_dim"]
        return str(self.cget("fg"))

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
            anchor = str(self.cget("anchor"))
            font = self.cget("font")
            color = self._text_color()
            if anchor in ("w", "e"):
                x = padx + 2 if anchor == "w" else w - padx - 2
                overlay.create_text(x, h / 2, text=text, fill=color, font=font,
                                    anchor=anchor)
            else:
                overlay.create_text(w / 2, h / 2, text=text, fill=color, font=font)
        except tk.TclError:
            pass


def _apply_theme(root: tk.Tk) -> ttk.Style:
    """把 clam 主题里**所有会漏出浅色**的地方都压回深色（下拉 readonly / 勾选框 / 悬停…）。

    ★ 这是「下拉框选中后变全白」「勾选框一块白」「划过变白」的根因修法：clam 默认在
      `readonly` / `active` / `disabled` 这些状态下会落到浅灰，光 `configure` 压不住状态色。
    """
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
    style.configure("TLabel", background=panel, foreground=text)
    style.configure("Bar.TLabel", background=bg, foreground=text)
    style.configure("Dim.TLabel", background=panel, foreground=dim)
    style.configure("Title.TLabel", background=panel, foreground=accent,
                    font=("Microsoft YaHei UI", 10, "bold"))
    style.configure("Hint.TLabel", background=panel, foreground=dim,
                    font=("Microsoft YaHei UI", 8))

    style.configure("TEntry", fieldbackground=alt, foreground=text, insertcolor=text,
                    bordercolor=line, lightcolor=alt, darkcolor=alt, padding=(6, 4))
    style.map("TEntry",
              fieldbackground=[("readonly", alt), ("disabled", panel)],
              foreground=[("disabled", dim)],
              selectbackground=[("!disabled", sel_bg)],
              selectforeground=[("!disabled", sel_fg)],
              bordercolor=[("focus", accent)], lightcolor=[("focus", accent)],
              darkcolor=[("focus", accent)])

    style.configure("TCombobox", fieldbackground=alt, background=alt, foreground=text,
                    arrowcolor=dim, bordercolor=line, lightcolor=alt, darkcolor=alt,
                    padding=(6, 4))
    style.map("TCombobox",
              fieldbackground=[("readonly", alt), ("disabled", panel)],
              background=[("readonly", alt), ("active", alt), ("disabled", panel)],
              foreground=[("readonly", text), ("disabled", dim)],
              arrowcolor=[("readonly", dim), ("active", text)],
              selectbackground=[("readonly", alt), ("!disabled", sel_bg)],
              selectforeground=[("readonly", text), ("!disabled", sel_fg)],
              bordercolor=[("focus", accent)], lightcolor=[("focus", accent)],
              darkcolor=[("focus", accent)])
    for pattern, value in (("*TCombobox*Listbox.background", alt),
                           ("*TCombobox*Listbox.foreground", text),
                           ("*TCombobox*Listbox.selectBackground", sel_bg),
                           ("*TCombobox*Listbox.selectForeground", sel_fg),
                           ("*TCombobox*Listbox.borderWidth", "0"),
                           ("*TCombobox*Listbox.highlightThickness", "0")):
        root.option_add(pattern, value, "interactive")

    style.configure("Treeview", background=alt, fieldbackground=alt, foreground=text,
                    bordercolor=line, lightcolor=panel, darkcolor=panel, rowheight=26,
                    borderwidth=0)
    style.map("Treeview",
              background=[("selected", sel_bg), ("disabled", alt)],
              foreground=[("selected", sel_fg), ("disabled", dim)])
    style.configure("Treeview.Heading", background=panel, foreground=dim, relief="flat",
                    borderwidth=0, padding=(6, 5))
    style.map("Treeview.Heading",
              background=[("active", hover), ("pressed", pressed)],
              foreground=[("active", text)])

    style.configure("TScrollbar", background=line, troughcolor=panel, bordercolor=panel,
                    arrowcolor=dim, relief="flat", borderwidth=0)
    style.map("TScrollbar",
              background=[("active", "#b9bfc9"), ("pressed", "#a6adba")],
              arrowcolor=[("active", text)])

    for name in ("TCheckbutton", "TRadiobutton"):
        style.configure(name, background=panel, foreground=text, focuscolor=panel,
                        indicatorbackground=alt, indicatorforeground=accent,
                        upperbordercolor=line, lowerbordercolor=line)
        style.map(name,
                  background=[("active", panel)],
                  foreground=[("disabled", dim)],
                  indicatorbackground=[("selected", accent), ("active", hover),
                                       ("disabled", panel)],
                  indicatorforeground=[("selected", "#ffffff")])

    style.configure("TButton", background=alt, foreground=text, bordercolor=line,
                    focuscolor=alt, padding=(10, 5), borderwidth=0)
    style.map("TButton",
              background=[("active", hover), ("pressed", pressed), ("disabled", panel)],
              foreground=[("disabled", dim)])
    style.configure("Accent.TButton", background=UI["accent_btn"],
                    foreground=UI["accent_fg"])
    style.map("Accent.TButton", background=[("active", UI["accent_btn_hover"])])

    style.configure("TNotebook", background=bg, borderwidth=0)
    style.configure("TNotebook.Tab", background=panel, foreground=dim, padding=(16, 7),
                    borderwidth=0)
    style.map("TNotebook.Tab",
              background=[("selected", alt), ("active", hover)],
              foreground=[("selected", accent)])
    style.configure("TSeparator", background=line)
    style.configure("TScale", background=panel, troughcolor=alt)
    return style


class _NoRepaint:
    """整块重建控件时先把窗口的绘制关掉，建完再一次性打开 —— 消掉「闪白」。

    ★★ 为什么换成 `WM_SETREDRAW`（2026.10 用户报「改一个数就闪一下」）：
      `LockWindowUpdate` 是给「拖动窗口时锁别的窗口」用的，它只锁**一个**窗口、
      而且在 DWM 下常常压不住 Tk 子控件的中间态（销毁后先露出白底，再画新控件）。
      `WM_SETREDRAW = 0` 才是「批量改控件期间不许画」的标准做法：重建期间窗口
      保持上一帧，`= 1` 之后一次 `RedrawWindow(...ALLCHILDREN|UPDATENOW)` 画到最终态。
    ★ 同时锁 **顶层窗口 + Tk 客户区**：Tk 在 Windows 上只有一个客户区 HWND，
      两个都发一遍才能覆盖不同 Tk 版本的绘制路径。
    ★ 只在 Windows 上生效；任何异常都退化成空操作 —— 绝不连累别的东西。
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


class EditorApp:
    """战役编辑器主窗口。"""

    def __init__(self, root: tk.Tk, model: CampaignModel, project_dir: Any,
                 config: Optional[ConfigInfo] = None,
                 maps: Optional[Dict[str, MapInfo]] = None,
                 show_all_levels: bool = False) -> None:
        self.root = root
        self.model = model
        self.project_dir = Path(project_dir)
        self.config = config if config is not None else levelfile.load_config(self.project_dir)
        self.maps: Dict[str, MapInfo] = (maps if maps is not None
                                         else levelfile.maps_by_id(self.project_dir))
        #: 编辑器下拉里优先列出的当前地图（完整 self.maps 仍用于校验/保存）。
        self.visible_map_ids: List[str] = visible_map_ids(self.project_dir)
        #: 测试钩子：True = 关卡树列出全部关卡；False = 只列有用表地图对应的关卡。
        self.show_all_levels: bool = bool(show_all_levels)
        # ★ 旧数据迁移兜底：每一关的 `zones[]` 都补齐成显式归属（见 `ensure_zone_owners`）。
        #   正常走 `load_campaign` 时已经补过，这里只是给「直接构造 EditorApp」的调用方兜底。
        self._seed_all_zone_owners()
        self.page = "campaign"
        #: 当前选中的关卡 id（切页签不丢）。默认第一关必须也是「有用关卡」。
        _visible = self._visible_levels()
        self.current_level_id = _visible[0].level_id if _visible else ""
        #: 摆放页的画笔：("unit"|"general"|"building", 值) + 归属阵营。
        self.brush_kind = "unit"
        self.brush_value = (self.config.unit_types[0] if self.config.unit_types else "enemy")
        self.brush_faction = ""
        #: ★★ 附属兵画笔：「这个兵属于第几位将领」（1 起）。只对 `brush_kind == "escort"` 有意义。
        self.brush_escort_of = 1
        #: 摆放页选中的东西：("unit"|"building", 下标)。
        self.selection: Optional[Tuple[str, int]] = None
        #: ★★ 敌友「边」的**编辑期缓存**（一条边一个阵营列表）。None = 还没从数据里读。
        #:   为什么要有它：`allies` 是成对关系，一条只有一个成员的边写进去等于没有
        #:   （推不出来）—— 缓存让「刚新建的边」在 refresh 之间活得下去。
        #:   只在**换关卡 / 重新载入**时重置（见 `_reset_sides`）。
        self._sides: Optional[List[List[str]]] = None
        #: ★★ 红点页当前编辑的阵营（红点生成配置挂在它的 `reddot_ai` 上）。
        self.reddot_faction: str = ""
        #: ★★ 红点页的画布点击模式：`"spawn"` = 编辑生成地块 / `"march"` = 编辑行军目标。
        self.reddot_click_mode: str = "spawn"
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
        #: ★★ 下一次 refresh 是否把侧边栏滚回顶部（换页签 / 换关卡 / 重新载入 = 是；
        #:    改数值 / 摆东西 = 否，保持用户当前看的位置）。
        self._sidebar_reset_pending = False
        #: ★★ 下一次重建画布是否要「适应视图」。只有首次进摆放页 / 换关卡 / 换地图
        #:    才置 True；改数值 / 摆将领绝不能把用户的缩放与平移重置掉。
        self._fit_pending = True
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
        _apply_theme(self.root)

    def _button(self, parent, text: str, command: Callable[[], None], **kw) -> RButton:
        """统一造按钮：一律 `takefocus=0`，并且是一枚**圆角按钮**（见 `RButton`），
        并在点完之后把键盘焦点交还画布。

        ★★ 为什么要交还焦点：tk 的按钮**点过之后会拿住键盘焦点**（`takefocus=0` 只影响
           Tab 键遍历，不影响鼠标点击），而**空格在 tk 里是「激活当前焦点控件」** ——
           于是「按住空格拖画面」会变成「反复点最后按过的那颗按钮」（页签乱跳）。
        """
        kw.setdefault("bg", UI["panel_alt"])
        kw.setdefault("fg", UI["text"])
        kw.setdefault("activebackground", UI["hover"])
        kw.setdefault("activeforeground", UI["accent"])
        kw.setdefault("padx", 10)
        kw.setdefault("pady", 5)
        kw.setdefault("font", ("Microsoft YaHei UI", 9))
        kw["takefocus"] = 0
        kw["relief"] = "flat"

        def wrapped() -> None:
            self._focus_canvas()
            command()

        return RButton(parent, text=text, command=wrapped, **kw)

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
        self.file_buttons["save"].configure(bg=UI["accent_btn"], fg=UI["accent_fg"],
                                            activebackground=UI["accent_btn_hover"])

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
    # ★★ 重建前后的界面状态：整块重建控件不等于「用户想回到初始位置」
    #
    # 用户口径：改一个数值 / 摆一位将领之后，侧边栏滚动位置、列表滚动位置、
    # 画布的缩放与平移、键盘焦点都不应该跳回去。所以 refresh_all() 在重建前
    # 拍一份快照，重建后原样恢复；只有「换页签 / 换关卡 / 重新载入」才显式
    # 要求回到顶部（见 `_sidebar_reset_pending`）。
    # ==================================================================

    def _ui_snapshot(self) -> dict:
        state: dict = {"sidebar": None, "trees": {}, "focus": None}
        try:
            state["sidebar"] = self.sidebar_canvas.canvasy(0.0)
        except tk.TclError:
            pass
        # ★ 用「深度遍历下标」而不是控件路径：Tk 的自动控件名（.!frame4）在销毁/
        #   重建之后会往后递增，路径对不上；界面结构没变时同一个下标就是同一个逻辑控件。
        widgets = list(_walk_widgets(self.root))
        for index, widget in enumerate(widgets):
            if isinstance(widget, ttk.Treeview):
                try:
                    state["trees"][index] = float(widget.yview()[0])
                except tk.TclError:
                    continue
        try:
            focused = self.root.focus_get()
            if focused in widgets:
                pos = None
                if isinstance(focused, ttk.Entry):
                    try:
                        pos = int(focused.index("insert"))
                    except (tk.TclError, ValueError):
                        pos = None
                state["focus"] = (widgets.index(focused), focused.winfo_class(), pos)
        except tk.TclError:
            pass
        return state

    def _ui_restore(self, state: dict, *, sidebar: bool = True) -> None:
        if sidebar:
            offset = state.get("sidebar")
            if offset is not None:
                self._restore_sidebar_offset(offset)
        widgets = list(_walk_widgets(self.root))
        for index, first in state.get("trees", {}).items():
            if 0 <= index < len(widgets) and isinstance(widgets[index], ttk.Treeview):
                try:
                    widgets[index].yview_moveto(max(0.0, min(1.0, float(first))))
                except tk.TclError:
                    pass
        focus = state.get("focus")
        if focus is not None:
            index, cls, pos = focus
            if 0 <= index < len(widgets):
                widget = widgets[index]
                try:
                    if widget.winfo_exists() and widget.winfo_class() == cls:
                        widget.focus_set()
                        if pos is not None and isinstance(widget, ttk.Entry):
                            widget.icursor(pos)
                except tk.TclError:
                    pass

    def _restore_sidebar_offset(self, offset: float) -> None:
        overflow = self.sidebar_overflow()
        if overflow <= 0:
            self._pin_sidebar_top()
            return
        total = max(1.0, float(self.sidebar.winfo_reqheight()))
        pos = max(0.0, min(float(offset), float(overflow)))
        try:
            self.sidebar_canvas.yview_moveto(pos / total)
        except tk.TclError:
            pass

    # ==================================================================
    # 状态 / 标题
    # ==================================================================

    def status(self, message: str) -> None:
        self.status_var.set(message)

    def level(self) -> Optional[LevelModel]:
        return self.model.level(self.current_level_id)

    def _visible_levels(self) -> List[LevelModel]:
        """关卡树里该列哪些关：有用表地图对应的关卡（测试钩子可关掉过滤）。"""
        if self.show_all_levels or not self.visible_map_ids:
            return list(self.model.levels)
        keep = {str(m) for m in self.visible_map_ids}
        return [lv for lv in self.model.levels if str(lv.map_id) in keep]

    def set_current_level(self, level_id: str) -> None:
        """切到某一关（**唯一入口**：所有「换关卡」的路径都必须走它）。

        ★★ 为什么必须集中到一处：下面这些状态全是**「属于上一关」**的编辑期缓存，
          漏清一个就会出现「A 关的配置跑到 B 关」：
            · `_sides` —— 敌友（边）的缓存。最脏的一个：不清的话 B 关会显示
              A 关的边，点一下还会把 A 关的盟友关系**写进 B 关**；
            · `selection` —— ④ 摆放页选中的下标（换关后指向另一关的单位）；
            · `reddot_faction` —— ⑥ 红点页「当前编辑哪一方」；
            · `brush_faction` —— 画笔的归属阵营（A 关的阵营 B 关可能根本没有）；
            · 平移/按下/空格状态 —— 新画布一进来就跟着鼠标跑。
        """
        if self.model.level(level_id) is None:
            return
        self.current_level_id = level_id
        self._reset_level_state()
        # 换关卡 = 新地图：侧边栏回顶部、画布重新适应视图（这两件是用户预期的「重置」）。
        self._sidebar_reset_pending = True
        self._fit_pending = True
        self.refresh_all()
        self.fit_view()

    def _reset_level_state(self) -> None:
        """清掉一切**只属于上一关**的编辑期状态（切关卡 / 重新载入时调）。"""
        self.selection = None
        self._reset_sides()                         # 敌友边重新从当前关的数据里读
        self.reddot_faction = ""                    # 红点页当前编辑的那一方
        self._pan_anchor = None
        self._left_down_at = None
        self.space_held = False
        self.hover = None
        # 画笔的归属：A 关的阵营 B 关可能没有 → 清掉，让界面按当前关重新取第一个
        if self.brush_faction and self.brush_faction not in self.all_faction_ids():
            self.brush_faction = ""

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
        """阵营颜色：**本关** `factions[].color` → config 的配色表 → 兜底轮转。"""
        fid = str(fid)
        if not fid:
            return UI["text_dim"]
        lv = self.level()
        color = (lv.faction_color(fid) if lv is not None else "") \
            or self.config.faction_color(fid)
        if color:
            return color
        if fid not in _EPOCH_COLORS:
            _EPOCH_COLORS[fid] = FALLBACK_COLORS[len(_EPOCH_COLORS) % len(FALLBACK_COLORS)]
        return _EPOCH_COLORS[fid]

    def faction_name(self, fid: str) -> str:
        """阵营显示名：**本关** `factions[].name` → id。"""
        lv = self.level()
        return lv.faction_name(fid) if lv is not None else str(fid)

    def all_faction_ids(self) -> List[str]:
        """界面上该列出的阵营 id：**本关阵营表** ∪ 地图自带的阵营（顺序稳定、去重）。

        ★ 不再包含「战役级阵营表」—— 阵营表跟着关卡走，别的关卡不会跑进来。
        """
        out: List[str] = []
        lv = self.level()
        if lv is not None:
            for e in lv.factions:
                if e.fid and e.fid not in out:
                    out.append(e.fid)
            # ★ 防守：老数据里可能有「席位指向一方、但 factions[] 没写它」——照样列出来
            for fid in lv.seats():
                if fid and fid not in out:
                    out.append(fid)
        info = self.map_info()
        if info is not None:
            for f in info.factions:
                fid = str(f.get("id", ""))
                if fid and fid not in out:
                    out.append(fid)
        return out

    def _seed_all_zone_owners(self) -> None:
        """把每一关的 `zones[]` 补齐成**显式**归属（地图的 owner 只当初始化来源）。"""
        for lv in self.model.levels:
            lv.ensure_zone_owners(self.maps.get(str(lv.map_id)))

    def sync_faction_context(self) -> None:
        self.model.sync_context()
        visible = self._visible_levels()
        visible_ids = {lv.level_id for lv in visible}
        if (not self.current_level_id or self.current_level_id not in visible_ids) and visible:
            # 当前关不存在 / 不在这张有用表里 → 退回第一个可见关卡。
            self.current_level_id = visible[0].level_id
            self._reset_level_state()

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
        # 换页签回顶部是用户预期的；摆放页第一次进来要适应视图。
        self._sidebar_reset_pending = True
        self._fit_pending = True
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
        ★★ 重建**不等于**把用户踢回初始位置：重建前拍快照（侧边栏 / 列表滚动、
          画布缩放平移、键盘焦点），重建后恢复。只有换页签 / 换关卡 / 重新载入
          才用 `_sidebar_reset_pending` 要求侧边栏回顶部。
        """
        state = self._ui_snapshot()
        reset_sidebar = self._sidebar_reset_pending
        self._sidebar_reset_pending = False
        self._suppress = True
        try:
            with _NoRepaint(self.root):        # 整块重建期间关掉重绘，消掉闪白
                self._rebuild_body()
                self._rebuild_sidebar()
                self.update_title()
                self._ui_restore(state, sidebar=not reset_sidebar)
                if reset_sidebar:
                    self._pin_sidebar_top()
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
        levels = self._visible_levels()
        for i, lv in enumerate(levels):
            self.level_tree.insert("", "end", iid="lv:%s" % lv.level_id,
                                   values=(i + 1, lv.level_id, lv.name,
                                           "双人合作" if lv.mode == MODE_COOP else "单人",
                                           lv.map_id, lv.summary(),
                                           model_mod.level_file_of(lv)))
        if not levels:
            self.status("有用表里没有可用关卡：先新建一关，或把地图加进有用表")
        if self.current_level_id and self.level_tree.exists("lv:%s" % self.current_level_id):
            self.level_tree.selection_set("lv:%s" % self.current_level_id)
            self._applied_level_sel = "lv:%s" % self.current_level_id
        self.level_tree.bind("<<TreeviewSelect>>", self._on_campaign_select)

        bar = self.action_bar
        self._button(bar, "▲ 上移", lambda: self.move_level(-1)).pack(side="left")
        self._button(bar, "▼ 下移", lambda: self.move_level(1)).pack(side="left", padx=4)
        self._button(bar, "＋ 新建关卡", self.do_new_level).pack(side="left", padx=(12, 4))
        self._button(bar, "－ 删除关卡", self.do_delete_level,
                     bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(side="left", padx=4)
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
                        tuple(self._map_label(m) for m in self._map_choice_ids()),
                        self._commit_level_map)

        tk.Label(form, text="玩家目标（每个可玩阵营一条；可玩阵营在③阵营页勾选）",
                 bg=UI["panel"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 9)).pack(anchor="w", pady=(6, 2))
        self._objective_rows(form)

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
                     bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(anchor="w", pady=2)
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


    def _map_choice_ids(self) -> List[str]:
        """地图下拉里列哪些图：可见清单 + 当前关卡正在用的图（旧关卡不被改坏）。"""
        ids = [m for m in self.visible_map_ids if m in self.maps]
        cur = self.level().map_id if self.level() is not None else ""
        if cur and cur in self.maps and cur not in ids:
            ids.append(cur)
        return ids or sorted(self.maps)

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
            bar_hint = ("左键放 / 选　右键删（大本营也能右键删）　"
                        "中键或空格+左键拖动平移　滚轮缩放　Esc 取消选中")
        else:
            bar_hint = ("左键点格 = 加/移出「生成地块 / 行军目标」（右侧切换）　右键 = 移出　"
                        "中键或空格+左键拖动平移　滚轮缩放")
        tk.Label(bar, text=bar_hint, bg=UI["bg"], fg=UI["text_dim"],
                 font=("Microsoft YaHei UI", 8)).pack(side="left", padx=10)

        self.canvas.update_idletasks()
        # ★★ 只有首次进摆放页 / 换关卡 / 换地图才「适应视图」。以前每次 refresh_all
        #    都会重建画布并强制 fit_view —— 于是改一个数值 / 摆一位将领，缩放和平移
        #    就被打回初始位置（用户报的「所有 UI 回到初始位置」其中一半）。
        if self._fit_pending:
            self._fit_pending = False
            self.fit_view()
        else:
            self.request_redraw()

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
        """把整张地图放进视口正中（显式「适应视图」；重建时不再自动调用）。"""
        self._fit_pending = False
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
        self._fit_pending = False
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
                fill = {".": C["grass"], "^": C["forest"], "#": C["mountain"],
                        "~": C["water"]}.get(terrain, C["grass"])
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
                # ★★ 建筑**所见即所得**：按类型画不同的形状（木墙 / 石墙 = 线段、哨塔 / 警戒塔 = 圆点、
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

        # ---- 红点生成地块 / 行军目标地块（只红点页画；游戏里这些格子外观**没有任何区别**）----
        if self.page == "reddot":
            for (tx, ty) in self.reddot_spawn_tiles():
                sx, sy = self.cell_origin(tx, ty)
                self.canvas.create_rectangle(sx + 3, sy + 3, sx + size - 3, sy + size - 3,
                                             outline=C["arrow"], width=2, dash=(3, 2))
                self.canvas.create_text(sx + size / 2, sy + size / 2, text="点",
                                        fill=C["arrow"], font=("Microsoft YaHei UI", 8))
            # ★ 行军目标地块：换一种颜色 + 「目」，与「点」（生成地块）区分开
            for (tx, ty) in self.reddot_march_tiles():
                sx, sy = self.cell_origin(tx, ty)
                self.canvas.create_rectangle(sx + 3, sy + 3, sx + size - 3, sy + size - 3,
                                             outline=C["objective"], width=2, dash=(2, 2))
                self.canvas.create_text(sx + size / 2, sy + size / 2, text="目",
                                        fill=C["objective"], font=("Microsoft YaHei UI", 8))

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

        · 城墙（木墙 / 石墙）= 一条横贯整格的**粗线**（本体就是整格）；
        · 箭塔（哨塔 / 警戒塔）= 居中的**实心圆**（本体比一格小一圈）；
        · 大本营 = 居中的**方块**（本体比一格小一圈）；
        · 其它类型（自定义建筑）→ 退回「圆盘 + 类型首字」（与单位同一种画法）。
        """
        size = self.tile_px()
        sx, sy = self.cell_origin(b.x, b.y)
        t = str(b.type)
        if t in ("wall", "stone_wall"):
            self.canvas.create_line(sx + 2, sy + size / 2, sx + size - 2, sy + size / 2,
                                    fill=color, width=max(3, int(size * 0.14)))
        elif t in ("tower", "watch_tower"):
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
        self._fit_pending = False
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
        if self.selection is not None:
            self.selection = None
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
        # ★ 大本营先在关卡层找 —— 它不在 start_units / start_buildings 里。
        base_fid = self._level_base_faction_at(cell)
        if base_fid is not None:
            self.set_faction_field(base_fid, "base", None)
            self.status("清掉了「%s」的大本营（(%d,%d)）" % (base_fid, cell[0], cell[1]))
            self._focus_canvas()
            return
        hit = self._hit_test(cell)
        if hit is None:
            self.status("(%d,%d) 上没有可删的东西" % cell)
            return
        self.delete_entry(hit)
        self._focus_canvas()            # 同上：重建之后把键盘焦点交回新画布

    def _level_base_faction_at(self, cell: Tuple[int, int]) -> Optional[str]:
        """关卡层（`factions[].base`）在这一格设过大本营的那一方；没有 → None。"""
        lv = self.level()
        if lv is None:
            return None
        for e in lv.factions:
            if e.base == cell:
                return e.fid
        return None

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
        if self.brush_kind == "base":
            if not faction:
                self.status("先选「归属」阵营，再摆大本营")
                return
            lv.ensure_faction(faction).base = (cell[0], cell[1])
            self.selection = None
            self.status("设了「%s」的大本营在 (%d,%d)" % (faction, cell[0], cell[1]))
        elif self.brush_kind == "building":
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
                # ★★ 新将领默认用**将领 1** 那一档兵种（`unit_type` = 第一档）；
                #    要换成别的档，用侧栏的「将领」下拉（它决定数值 / 编制上限 / 默认名字）。
                gtypes = self.config.general_types or [""]
                entry.unit_type = gtypes[0]
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
        """右键删单位 / 建筑；大本营走 `on_right_click` 里那条单独的分支（`factions[].base`）。"""
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
                     bg=UI["accent_btn"], fg=UI["accent_fg"]).pack(side="left")
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
            catalog_add_campaign(self.project_dir, self.model.campaign_id)
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
        self._seed_all_zone_owners()
        # ★ 统一入口：重新载入 = 换了一整套关卡数据，上一关的边 / 选中 / 画笔归属都不能留。
        if fresh.levels:
            self.set_current_level(fresh.levels[0].level_id)
        else:
            self.current_level_id = ""
            self._reset_level_state()
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
        # ★ `--campaign-map`：告诉地图编辑器「这张图是给战役用的」——
        #   它导出时会写 `hidden: true`，于是**不进自由对战选择条**（关卡仍按 id 引用它）。
        cmd = [sys.executable, str(self.map_editor_dir()), "--map", str(map_id),
               "--campaign-map"]
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
            # ★★ 必须走 `set_current_level()`：它负责清掉上一关的边缓存 / 选中 / 画笔归属。
            #    以前这里只改 id 再 refresh，于是「选 dscj 再切到别的关」会看到 dscj 的边。
            self.set_current_level(lid)

    def move_level(self, delta: int) -> None:
        visible = self._visible_levels()
        ids = [lv.level_id for lv in visible]
        if self.current_level_id not in ids:
            self.status("当前关不在有用表里，不能调整顺序")
            return
        idx = ids.index(self.current_level_id)
        tgt = idx + int(delta)
        if tgt < 0 or tgt >= len(ids):
            self.status("已经到头了" if delta < 0 else "已经是最后一关")
            return
        target_id = ids[tgt]
        i = self.model.index_of(self.current_level_id)
        j = self.model.index_of(target_id)
        if i < 0 or j < 0 or i == j:
            self.status("关卡顺序没有变化")
            return
        # 在完整 levels[] 里搬动，隐藏关卡不会和可见关卡互换而看起来「没动」。
        self.model.levels.insert(j, self.model.levels.pop(i))
        self.refresh_all()
        self.status("关卡顺序已调整")

    def do_new_level(self) -> None:
        """新建一关（问 id 与地图；对话框可被测试换成「直接给答案」）。"""
        if not self.maps:
            messagebox.showerror("没有地图", "data/maps/ 下一张地图都没有：先放一张图进去。")
            return
        choices = self._map_choice_ids()
        default_map = (self.level().map_id if self.level() and self.level().map_id in choices
                       else choices[0])
        answer = _ask_new_level(self.root, choices, default_map)
        if not answer:
            return
        level_id, map_id = answer
        lv = self.model.new_level(level_id, map_id)
        lv.name = level_id
        # ★ 新关卡没有历史区划归属：按地图的 owner 初始化成显式 zones[]。
        lv.ensure_zone_owners(self.maps.get(str(map_id)), force=True)
        # ★ 走统一入口：新关卡不能继承上一关的边 / 选中 / 画笔归属。
        self.set_current_level(lv.level_id)
        self.status("新建了关卡「%s」（地图 %s）—— 记得配目标（每个可玩阵营一条）+ 摆大本营"
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
            visible = self._visible_levels()
            if visible:
                self.set_current_level(visible[0].level_id)
            else:
                self.current_level_id = ""
                self._reset_level_state()
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
        # ★ 玩家席位不再手填：由「可玩阵营」自动派生（见 `sync_players_from_playable`）。
        self.status("模式改成「%s」" % self.lv_mode_var.get())
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

    # ---- ★ 玩家目标（可变长度：每个可玩阵营一行）----

    def _objective_rows(self, parent) -> None:
        """② 关卡页的「玩家目标」列表：**每个可玩阵营一行**（守 / 攻 + 区划 + 秒数）。

        ★ 一关可以有两个对立的可玩阵营（蓝方守 c1 / 红方攻 c1）—— 本列表就是
          给每个可玩阵营各配一条 `for=<阵营>` 的目标，写进 `objectives[]`。
        """
        lv = self.level()
        if lv is None:
            return
        playable = lv.playable_ids()
        if not playable:
            self._hint(parent, "★ 这一关还没有「可玩阵营」—— 去③阵营页勾上「可玩」或加一方，"
                               "这里就会为每一方各出现一行目标")
            return
        for fid in playable:
            o = lv.objective_for(fid) or {}
            row = tk.Frame(parent, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=2)
            tk.Label(row, text="%s %s" % (fid, lv.faction_name(fid)),
                     width=14, anchor="w", bg=UI["panel"],
                     fg=self.faction_color(fid)).pack(side="left")
            kind = str(o.get("kind", "")) or OBJ_HOLD_ZONE
            kcombo = ttk.Combobox(row, values=("守住", "攻占"), width=6, state="readonly")
            kcombo.set("守住" if kind == OBJ_HOLD_ZONE else "攻占")
            kcombo.pack(side="left")
            kcombo.bind("<<ComboboxSelected>>",
                        lambda e, f=fid, c=kcombo: self._set_objective_kind(f, c.get()))
            zcombo = ttk.Combobox(row, values=self._zone_choices(), width=16, state="readonly")
            zcombo.set(self._zone_label(int(o.get("zone", -1))))
            zcombo.pack(side="left", padx=4)
            zcombo.bind("<<ComboboxSelected>>",
                        lambda e, f=fid, c=zcombo: self._set_objective_zone_for(f, c.get()))
            entry = ttk.Entry(row, width=8)
            entry.insert(0, fmt_sec(float(o.get("hold_sec", 0.0))))
            entry.pack(side="left")
            entry.commit_action = (lambda f=fid, en=entry:      # type: ignore[attr-defined]
                                   self._set_objective_sec_for(f, en.get()))
            entry.bind("<Return>", lambda e, en=entry: en.commit_action())
            entry.bind("<FocusOut>", lambda e, en=entry: en.commit_action())
            if kind != OBJ_HOLD_ZONE:
                entry.configure(state="disabled")   # 「攻占」不需要秒数

    def _set_objective_kind(self, fid: str, label: str) -> None:
        lv = self.level()
        if lv is None:
            return
        o = lv.objective_for(fid) or {}
        kind = OBJ_CAPTURE_ZONE if label == "攻占" else OBJ_HOLD_ZONE
        sec = float(o.get("hold_sec", 0.0))
        if kind == OBJ_HOLD_ZONE and sec <= 0.0:
            sec = 90.0
        lv.set_objective_for(fid, kind, int(o.get("zone", -1)), sec)
        self.status("「%s」的目标 = %s" % (fid, label))
        self._after_change()

    def _set_objective_zone_for(self, fid: str, label: str) -> None:
        lv = self.level()
        if lv is None:
            return
        o = lv.objective_for(fid) or {}
        kind = str(o.get("kind", "")) or OBJ_HOLD_ZONE
        lv.set_objective_for(fid, kind, self._zone_id_from_label(label),
                             float(o.get("hold_sec", 0.0)))
        self._after_change()

    def _set_objective_sec_for(self, fid: str, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        try:
            sec = float(str(text).strip())
        except ValueError:
            self.status("守住秒数要填数字")
            self.refresh_all()
            return
        o = lv.objective_for(fid) or {}
        kind = str(o.get("kind", "")) or OBJ_HOLD_ZONE
        if kind != OBJ_HOLD_ZONE:
            self.status("「攻占」不需要秒数")
            self.refresh_all()
            return
        lv.set_objective_for(fid, kind, int(o.get("zone", -1)), sec)
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
        elif field == "name":
            entry.name = str(value)
        elif field in ("start_food", "start_gold"):
            if value is None:
                setattr(entry, field, None)
            else:
                try:
                    setattr(entry, field, max(0.0, float(value)))
                except (TypeError, ValueError):
                    pass
        elif field == "playable":
            entry.playable = bool(value)
            entry.playable_declared = True
            # ★ 席位由**本关**的可玩阵营派生 —— 只动这一关。
            lv.sync_players_from_playable()
        self._after_change()

    def _add_level_faction(self, text: str) -> None:
        """在本关阵营表里加一方（只写这一关的 JSON）。"""
        lv = self.level()
        if lv is None:
            return
        fid = str(text).strip()
        if not fid:
            return
        if lv.faction(fid) is not None:
            self.status("这一关已经有阵营「%s」了" % fid)
            return
        e = lv.ensure_faction(fid, fid, self.faction_color(fid))
        # 新加的一方默认给个颜色（品红很难看，也过不了配色校验）
        if not e.color:
            e.color = self.faction_color(fid)
        self._after_change()
        self.status("给这一关加了阵营 %s（不勾「可玩」= 不是玩家席位）" % fid)

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

        section2 = self._section("关卡与阵营",
                                 "★ 阵营表跟着**关卡**走：每关的 levels/*.json 自带 "
                                 "id / 名字 / 颜色 / 可玩，互不影响")
        self._hint(section2, "当前关「%s」的阵营表在 **③ 阵营页**（加一方 / 勾可玩 / "
                             "改名字和颜色都在那里）。" % (self.level().level_id
                                                        if self.level() else "—"))
        self._hint(section2, "★ 这一页的列表 = 关卡顺序；点一行切到那一关。")
        self._hint(section2, "★ 阵营不再在战役级维护：A 关卡加的阵营不会出现在 B 关卡。")

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

    # ---- ③ 阵营页：本关阵营表（加一方 / 改字段） ----

    # ---- ② 关卡页侧栏 ----

    def _sidebar_level(self) -> None:
        lv = self.level()
        if lv is None:
            self._section("关卡").pack_forget()
            return
        section = self._section("当前关", "目标按可玩阵营逐条配：「守住某区划 N 秒」/「攻占某区划」")
        self._entry_cell(section, "名字", lv.name,
                         lambda text: self._set_level_name(text))
        self._combo_cell(section, "模式",
                         "双人合作" if lv.mode == MODE_COOP else "单人",
                         ("单人", "双人合作"), self._set_level_mode)
        self._combo_cell(section, "地图", self._map_label(lv.map_id),
                         tuple(self._map_label(m) for m in self._map_choice_ids()),
                         self._set_level_map)

        section2 = self._section("玩家目标",
                                 "每个可玩阵营一条（守住 / 攻占 + 区划 + 秒数）；"
                                 "可玩阵营在③阵营页勾选")
        self._objective_rows(section2)
        self._hint(section2, "额外失败条件（「大本营被拆」那条常开）：")
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
        # ★ 玩家席位不再手填：由「可玩阵营」自动派生。
        self._after_change()

    def _set_level_map(self, text: str) -> None:
        lv = self.level()
        if lv is None:
            return
        lv.map_id = self._map_id_from_label(text)
        lv.mark_declared("map")
        # ★★ 换地图 = 区划表按新地图**整张重建**（旧地图的区划号对新地图没有意义）。
        #    战役编辑器不再有「（用地图的）」，所以这里必须把新地图的 owner 抄成显式值。
        lv.ensure_zone_owners(self.maps.get(str(lv.map_id)), force=True)
        # 换地图 = 画布内容整张换了：重新适应视图（这是用户预期的「换了一张图」）。
        self._fit_pending = True
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
        # ---- ★★ 本关阵营表：跟着关卡走（用户口径：每一关就是一个独立战役）----
        tsec = self._section("本关阵营表（关卡 JSON 的 factions[]）",
                             "★ 阵营表跟着**关卡**走：这里改的只影响这一关，"
                             "另一关 / 另一场战役看不到它。勾「可玩」= 玩家能选谁"
                             "（玩家席位由它自动派生）。")
        for e in lv.factions:
            row = tk.Frame(tsec, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=2)
            tk.Label(row, text=("★可玩" if e.playable else "　"), width=6, anchor="w",
                     bg=UI["panel"],
                     fg=(UI["accent"] if e.playable else UI["text_dim"]),
                     font=("Microsoft YaHei UI", 9, "bold")).pack(side="left")
            tk.Label(row, text=e.fid, width=7, anchor="w", bg=UI["panel"],
                     fg=self.faction_color(e.fid)).pack(side="left")
            name_var = tk.StringVar(value=e.name)
            ne = ttk.Entry(row, textvariable=name_var, width=10)
            ne.pack(side="left", padx=(0, 3))
            ne.commit_action = (lambda f=e.fid, v=name_var:      # type: ignore[attr-defined]
                                self.set_faction_field(f, "name", v.get()))
            ne.bind("<Return>", lambda _e, en=ne: en.commit_action())
            ne.bind("<FocusOut>", lambda _e, en=ne: en.commit_action())
            color_var = tk.StringVar(value=e.color)
            ce = ttk.Entry(row, textvariable=color_var, width=9)
            ce.pack(side="left", padx=(0, 3))
            ce.commit_action = (lambda f=e.fid, v=color_var:     # type: ignore[attr-defined]
                                self.set_faction_field(f, "color", v.get()))
            ce.bind("<Return>", lambda _e, en=ce: en.commit_action())
            ce.bind("<FocusOut>", lambda _e, en=ce: en.commit_action())
            play_var = tk.BooleanVar(value=e.playable)
            ttk.Checkbutton(row, text="可玩", variable=play_var,
                            command=lambda f=e.fid, v=play_var:
                            self.set_faction_field(f, "playable", bool(v.get()))
                            ).pack(side="left", padx=(0, 3))
            self._button(row, "删", lambda f=e.fid: self.remove_faction_entry(f),
                         padx=4, pady=1,
                         font=("Microsoft YaHei UI", 8)).pack(side="right")
            # ★★ 2026.10.29：这一方的起手资源（逐阵营配）。留空 = 不写（运行时默认 0）。
            res = tk.Frame(tsec, bg=UI["panel"])
            res.pack(side="top", fill="x", pady=(0, 4))
            tk.Label(res, text="　　起手", width=8, anchor="w", bg=UI["panel"],
                     fg=UI["text_dim"], font=("Microsoft YaHei UI", 8)).pack(side="left")
            for fld, label in (("start_food", "粮"), ("start_gold", "金")):
                tk.Label(res, text=label, bg=UI["panel"], fg=UI["text_dim"],
                         font=("Microsoft YaHei UI", 8)).pack(side="left")
                cur = getattr(e, fld)
                var = tk.StringVar(
                    value="" if cur is None else str(model_mod.clean_number(cur)))
                ent = ttk.Entry(res, textvariable=var, width=5)
                ent.pack(side="left", padx=(2, 6))
                ent.commit_action = (lambda f=e.fid, fl=fld, v=var:   # type: ignore[attr-defined]
                                     self._set_faction_optional_float(f, fl, v.get()))
                ent.bind("<Return>", lambda _e, en=ent: en.commit_action())
                ent.bind("<FocusOut>", lambda _e, en=ent: en.commit_action())
        self._entry_cell(tsec, "加一方 id", "", self._add_level_faction, width=18)
        self._hint(tsec, "★ 加一方只会写进**这一关**；名字 / 颜色 / 可玩 / 起手粮金都在这一行改。"
                         "起手资源留空 = 不写（commander 默认 0，玩家沿用全局配置）。"
                         "地图自带的阵营照样会列在下面，点「在这关点名」才会写进关卡。")

        # ---- 敌友（边）：同一条边互为友军；不同边 / 没分边的互相敌对 ----
        asec = self._section("敌友（边）",
                             "同一条边里的阵营互为友军；不同边的、以及没分边的阵营互相敌对"
                             "（默认就是敌对）。导出时写进关卡 allies（两两一对）。")
        self._refresh_ally_rows(asec)

        # ---- 每一方一行 ----
        playable = set(lv.playable_ids())
        for fid in self.all_faction_ids():
            e = lv.faction(fid)
            title = "%s %s%s" % (fid, lv.faction_name(fid),
                                 "　★可玩" if fid in playable else "")
            section = self._section(title,
                                    "本关 factions[] 里有这一方（改名字 / 颜色 / 可玩 / 起手资源见上面那张表）"
                                    if e else "这一关没点名它（导出时不会为它写一份）")
            if e is None:
                self._button(section, "在这关点名这一方",
                             lambda f=fid: self._point_faction(f)).pack(anchor="w")
                continue
            # ★ 大本营已统一到「摆放」页画布摆放 —— 这里只显示当前值。
            self._hint(section, "★ 大本营在「摆放」页摆（画笔选「大本营」，归属选这一方）；"
                                "现在：%s" % e.base_label())
            # ---- ★★ 开局附属兵在这里摆（不在「阵营」页，也不再由 config 决定）----
            self._hint(section, "★ 开局带几个附属兵：**去「摆放」页一个一个摆**（画笔选「附属兵」，"
                                "放到地上并选它属于哪位将领）。没摆 = 这一关这一方开局没有附属兵；"
                                "摆了任何附属兵 = 运行时**整个接管这一方**（连 3 位将领也得你自己摆）。")
            # ★ AI 相关（类型 / 进攻目标 / 生成区域 / 高级参数）**不在编辑器里改**（用户要求）。
            #   ⚠️ 字段本身一个字没动：编辑器仍然原样读、原样写（不会丢），
            #      要改 AI 就直接手改关卡 JSON。
            self._hint(section, "★ 这一方的 AI（类型 / 进攻目标 / 生成区域 / 参数）不在编辑器里改 —— "
                                "直接手改关卡 JSON（编辑器会原样保留这些字段）。")
            self._button(section, "从这一关移除这一方",
                         lambda f=fid: self.remove_faction_entry(f),
                         bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(anchor="w", pady=(6, 0))

    # ==================================================================
    # 敌友（边）—— 每关一套，写进关卡 JSON 的 `allies`（两两一对）
    #
    # ★ 语义（与游戏侧 `logic/faction.gd` 的 `set_allies` 完全一致）：`allies` 是**成对**
    #   关系，运行时取它的连通分量 —— 同一条边里的阵营互为友军；不同边的、以及没分边的
    #   阵营互相敌对（**默认就是敌对**：什么都不写 = 全部互相敌对）。
    #   所以「边」不需要新字段：把每条边展开成两两一对就是 `allies`。
    # ==================================================================

    def _effective_pairs(self) -> List[List[str]]:
        """这一关**生效**的 allies：关卡写了就用关卡的，一个字都没写才用地图的。"""
        lv = self.level()
        if lv is None:
            return []
        return [list(p) for p in model_mod._effective_allies(lv, self.map_info())]

    def _reset_sides(self) -> None:
        """丢掉「边」的编辑期缓存（换关卡 / 重新载入之后调）。"""
        self._sides = None

    @staticmethod
    def _components(pairs: List[List[str]]) -> List[List[str]]:
        """把成对关系并成连通分量（边）。顺序按「第一次出现」，稳定可比。"""
        parent: Dict[str, str] = {}

        def find(a: str) -> str:
            parent.setdefault(a, a)
            while parent[a] != a:
                parent[a] = parent[parent[a]]
                a = parent[a]
            return a

        for pair in pairs:
            if len(pair) < 2:
                continue
            ra, rb = find(str(pair[0])), find(str(pair[1]))
            if ra != rb:
                parent[rb] = ra
        groups: Dict[str, List[str]] = {}
        order: List[str] = []
        for fid in list(parent.keys()):
            root = find(fid)
            if root not in groups:
                groups[root] = []
                order.append(root)
            groups[root].append(fid)
        return [groups[r] for r in order]

    def _level_sides(self) -> List[List[str]]:
        """当前编辑中的「边」（缓存见 `self._sides` 的说明）。"""
        if self._sides is None:
            self._sides = self._components(self._effective_pairs())
        return self._sides

    def _side_label_of(self, fid: str) -> str:
        for i, group in enumerate(self._level_sides()):
            if fid in group:
                return "边 %d" % (i + 1)
        return ALLY_UNSIDED

    def _side_choices(self) -> Tuple[str, ...]:
        return tuple([ALLY_UNSIDED]
                     + ["边 %d" % (i + 1) for i in range(len(self._level_sides()))])

    def _new_side(self) -> None:
        """新建一条边（先是一条**空边**，把阵营选进去它才算数）。

        ★ 空边只活在**编辑期缓存**里（`allies` 是成对关系，空边写不进去）——
          但**必须让它看得见**：以前那种「点一下只在暗处挪一挪」的写法，
          表现就是用户报的「点新建一条边没反应」。
        """
        self._level_sides().append([])
        self.refresh_all()
        self.status("新建了一条空边 —— 在下面给每一方选它「在哪条边」")

    def _delete_side(self, index: int) -> None:
        """删掉一条边（里面的阵营回到「未分边」）。删空边不动文件。"""
        sides = self._level_sides()
        if not (0 <= index < len(sides)):
            return
        had_members = bool(sides[index])
        del sides[index]
        if had_members:
            self._commit_sides()
        else:
            self.refresh_all()
        self.status("删了一条边")

    def _set_faction_side(self, fid: str, label: str) -> None:
        """把某一方放进 / 移出一条边（「未分边」= 移出来）。"""
        label = str(label)
        if label == self._side_label_of(fid):
            return
        sides = [list(g) for g in self._level_sides()]
        if label == ALLY_UNSIDED:
            for g in sides:
                if fid in g:
                    g.remove(fid)
        elif label.startswith("边 "):
            try:
                k = int(label.split()[-1]) - 1
            except ValueError:
                return
            if not (0 <= k < len(sides)):
                return
            for g in sides:
                if fid in g:
                    g.remove(fid)
            sides[k].append(fid)
        else:
            return
        # ★ 空边**留着**（看得见才好删）—— 不再静默丢掉，否则「刚建的边」会当场消失。
        self._sides = sides
        self._commit_sides()
        self.status("「%s」的边 → %s" % (fid, label))

    def _commit_sides(self) -> None:
        """把「边」写回关卡：每条边展开成两两一对的 `allies`，并标记成「声明过」。"""
        lv = self.level()
        if lv is None:
            return
        pairs: List[List[str]] = []
        for group in self._level_sides():
            for i in range(len(group)):
                for j in range(i + 1, len(group)):
                    pairs.append([group[i], group[j]])
        lv.allies = pairs
        lv.allies_declared = True
        self._after_change()

    def _refresh_ally_rows(self, parent: tk.Frame) -> None:
        """「敌友（边）」那一节：先列**每条边与它的阵营**，再是「每一方在哪条边」。"""
        sides = self._level_sides()
        if not sides:
            tk.Label(parent, text="还没有边 —— 点下面的「＋ 新建一条边」开一条。",
                     bg=UI["panel"], fg=UI["text_dim"], anchor="w", justify="left",
                     wraplength=260).pack(fill="x")
        for i, group in enumerate(sides):
            row = tk.Frame(parent, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=1)
            tk.Label(row, text="边 %d" % (i + 1), width=6, anchor="w",
                     bg=UI["panel"], fg=UI["text"]).pack(side="left")
            text = ("、".join("%s %s" % (f, self.faction_name(f)) for f in group)
                    if group else "（空）")
            tk.Label(row, text=text, anchor="w", justify="left", wraplength=210,
                     bg=UI["panel"],
                     fg=(UI["text"] if group else UI["text_dim"])).pack(
                         side="left", fill="x", expand=True)
            self._button(row, "删", lambda i=i: self._delete_side(i),
                         padx=4, pady=1,
                         font=("Microsoft YaHei UI", 8)).pack(side="right")
        self._button(parent, ALLY_NEW_SIDE, self._new_side,
                     padx=8, pady=3).pack(anchor="w", pady=(4, 0))

        # ---- 每一方选边（赋值入口）----
        self._hint(parent, "　下面给每一方选一条边：同一条边里的阵营互为友军；"
                           "不同边 / 未分边的互相敌对（默认就是敌对）。")
        for fid in self.all_faction_ids():
            row = tk.Frame(parent, bg=UI["panel"])
            row.pack(side="top", fill="x", pady=1)
            tk.Label(row, text="%s %s" % (fid, self.faction_name(fid)),
                     width=14, anchor="w", bg=UI["panel"],
                     fg=UI["text"]).pack(side="left")
            combo = ttk.Combobox(row, values=self._side_choices(), width=18,
                                 state="readonly")
            combo.set(self._side_label_of(fid))
            combo.pack(side="left")
            combo.bind("<<ComboboxSelected>>",
                       lambda e, f=fid, c=combo: self._set_faction_side(f, c.get()))

    def _ai_label(self, ai: str) -> str:
        return {AI_NONE: "无", AI_GARRISON: "阵地性", AI_REDDOT: "红点性",
                AI_COMMANDER: "指挥官"}.get(ai, "无")

    def _ai_value(self, label: str) -> str:
        return {"无": AI_NONE, "阵地性": AI_GARRISON, "红点性": AI_REDDOT,
                "指挥官": AI_COMMANDER}.get(label, AI_NONE)

    def _point_faction(self, fid: str) -> None:
        """把地图/空表里的某一方**写进这一关**的 factions[]（带名字与颜色）。"""
        lv = self.level()
        if lv is None:
            return
        name, color = "", ""
        info = self.map_info()
        if info is not None:
            for f in info.factions:
                if str(f.get("id", "")) == fid:
                    name = str(f.get("name", ""))
                    color = str(f.get("color", ""))
                    break
        lv.ensure_faction(fid, name, color or self.config.faction_color(fid))
        self._after_change()

    def _set_float(self, fid: str, field: str, text: str) -> None:
        try:
            value = float(str(text).strip())
        except ValueError:
            self.status("「%s」要填数字" % field)
            self.refresh_all()
            return
        self.set_faction_field(fid, field, value)

    def _set_faction_optional_float(self, fid: str, field: str, text: str) -> None:
        """阵营配置里的「可选数字」：留空 = `None`（不写这个键），数字 = max(0, 值)。"""
        s = str(text).strip()
        if s == "":
            self.set_faction_field(fid, field, None)
            return
        try:
            value = float(s)
        except ValueError:
            self.status("「%s」要填数字（留空 = 不配置）" % field)
            self.refresh_all()
            return
        self.set_faction_field(fid, field, max(0.0, value))

    # ---- ④ 摆放页侧栏 ----

    def _sidebar_place(self) -> None:
        lv = self.level()
        if lv is None:
            return
        section = self._section("画笔", "左键点空格 = 放一个；右键点它 = 删；点已有的 = 选中")
        self._combo_cell(section, "放什么", self._brush_label(),
                         ("单位", "将领", "建筑", "大本营"), self._set_brush_kind)
        if self.brush_kind != "base":
            values = (self.config.unit_types if self.brush_kind == "unit"
                      else self._brush_building_types() if self.brush_kind == "building"
                      else ["general"])
            self._combo_cell(section, "种类", self.brush_value,
                             tuple(values) or ("（config 里没有）",), self._set_brush_value)
        factions = self.all_faction_ids()
        self._combo_cell(section, "归属", self.brush_faction or (factions[0] if factions else ""),
                         tuple(factions) or ("（没有阵营）",), self._set_brush_faction)
        if self.brush_kind == "base":
            self._hint(section, "★ 「大本营」画笔：左键点格 = 给「归属」那一方设大本营；"
                                "右键点已有的大本营 = 清掉")

        # ---- 地图上已有的东西 ----
        section2 = self._section("地图上已有的（关卡层）",
                                 "这里列开局摆的单位 / 建筑；大本营用「大本营」画笔在画布上摆 / 右键删")
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
                # ★★ 「这位将领是**哪个将领**」（本轮新增）：决定它的兵种 / 数值档 /
                #    编制上限 / 默认名字（= config 的 unit.general.types/stats/caps/names）。
                #    ⚠️ 与下一行的「将领序号」相互独立：序号只是名册号（运行时 id + 附属兵归属）。
                self._combo_cell(sec, "将领", self._general_label_of_unit(unit),
                                 self._general_choices(), self._set_unit_general)
                # ★★ 将领序号（名册号）：选项 1..10（用户需求：不只 3 个）。
                self._combo_cell(sec, "将领序号",
                                 str(unit.general_index or 1),
                                 tuple(str(i) for i in self.config.general_roster_indices()),
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
                         bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(anchor="w", pady=(6, 0))
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
                         bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(anchor="w", pady=(6, 0))
        else:
            self._section("选中的东西", "在画布上点一个已有的单位 / 建筑，这里就会出现它的全部字段")

    def _brush_label(self) -> str:
        return {"unit": "单位", "general": "将领",
                "building": "建筑", "base": "大本营"}.get(self.brush_kind, "单位")

    def _brush_building_types(self) -> List[str]:
        """「建筑」画笔能放的种类：**剔除 `base`**（大本营走专门的「大本营」画笔）。"""
        return [t for t in self.config.building_types if t != "base"]

    def _set_brush_kind(self, label: str) -> None:
        self.brush_kind = {"单位": "unit", "将领": "general",
                           "建筑": "building", "大本营": "base"}.get(label, "unit")
        if self.brush_kind == "unit":
            self.brush_value = self.config.unit_types[0] if self.config.unit_types else "enemy"
        elif self.brush_kind == "building":
            bt = self._brush_building_types()
            self.brush_value = bt[0] if bt else "tower"
        elif self.brush_kind == "base":
            self.brush_value = "base"
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
    # ★★ 「这位将领是哪个将领」（兵种 / 数值档）
    # ==================================================================

    def _general_choices(self) -> Tuple[str, ...]:
        """「将领」下拉的选项：config 里的全部将领档位（`unit.general.types`）。

        ★ 档位数 = `types` 的长度（当前配置是 10）；每项都带档位序号，重复的兵种
          也各占一行 —— 显式档位由 `general_profile` 保存，不再靠 `unit_type` 反推。
        """
        n = len(self.config.general_types)
        if n == 0:
            return ("（config 里没有将领）",)
        return tuple(self.config.general_label(i + 1) for i in range(n))

    def _general_label_of_unit(self, unit: UnitEntry) -> str:
        """选中将领的「将领」显示值（按**显式档位** → unit_type → kind 查）。"""
        if not self.config.general_types:
            return "（config 里没有将领）"
        profile = model_mod.general_profile_of_unit(unit, self.config) - 1
        if profile < 0 or profile >= len(self.config.general_types):
            profile = 0
        return self.config.general_label(profile + 1)

    def _set_unit_general(self, label: str) -> None:
        """「将领」下拉提交：把选中将领的**档位**改成所选那一档。

        ★★ 写两样东西：
          · `unit_type` = 这一档的兵种（作者看得见、运行时也读）；
          · `general_profile` = 档位序号（1 起）—— `types` 里兵种重复时，只有它能
            区分「将领 4」和「将领 1」。若这个兵种在 types 里第一次出现的位置正好
            就是所选档位，就清掉显式档位（旧数据 / 1..3 档保持不写这个键）。
        """
        u = self.selected_unit()
        if u is None:
            return
        n = self._escort_index_from_label(label)      # 「将领 N（…）」→ N
        types = self.config.general_types
        if 1 <= n <= len(types):
            type_id = types[n - 1]
            u.unit_type = type_id
            first = self.config.general_profile_of(type_id) + 1
            u.general_profile = n if n != first else None
        self.status("将领 → %s" % label)
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
        # ★★ 编制上限按**将领档**取（`general_profile` → unit_type → kind），不是将领序号。
        profile = model_mod.general_profile_of_unit(unit, self.config) - 1
        cap = self.config.general_cap(profile + 1 if profile >= 0 else 1)
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
        """区划页的「归属」下拉：各阵营 / 无主。

        ★★ **没有「（用地图的）」**：地图编辑器不提供区块归属编辑，所以关卡必须
          每一块地都写清楚（阵营 id 或空串 = 无主）。地图的 `zone_list[].owner`
          只在载入旧数据 / 新建关卡时当一次初始化来源。

        ⚠️ 名字**不能**叫 `_zone_choices`：那个是「列出地图里的各区划」（目标 / 失败条件 /
        单位 `zone` 三处用它），两个同名方法在 Python 里**后一个会盖掉前一个**（实测踩到）。
        """
        return tuple([str(f) for f in self.all_faction_ids()] + ["（清空 = 无主）"])

    def _zone_choice_label(self, lv: LevelModel, zid: int) -> str:
        cur = lv.zone_owner(zid)
        # 正常载入后每一块地都有显式值；None 只可能是旧/外部数据 → 按「无主」显示
        return "（清空 = 无主）" if cur is None or cur == "" else str(cur)

    def _build_zone_page(self) -> None:
        """区划页：一张表 —— 每一块地开局归哪个阵营（写 `zones[].owner`）。

        ★★ 每一块地都**必须**有显式归属：阵营 id，或空串 = 无主。
          不再有「不写这个键 = 用地图的」那一档（地图编辑器不编辑归属）。
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
        tk.Label(head, text="　（每一块地都要选：阵营 / 「清空 = 无主」）",
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
        if label == "（清空 = 无主）":
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
        self._hint(sec, "★ 归属属于**关卡层**（`zones[]`）：每块地都显式写阵营 id，"
                        "「清空 = 无主」写空串。地图编辑器不编辑区块归属，所以这里"
                        "没有「（用地图的）」——地图的 owner 只在新建 / 换图时初始化一次。"
                        "地形 / 区划形状要改请点摆放页的『打开地图编辑器』。")
        self._hint(sec, "地图「%s」共 %d 块地；本关已写 %d 块。"
                   % (info.map_id, len(info.zone_ids), len(lv.zone_owners)))

    # ==================================================================
    # ★★ 红点页：生成配置（挂在当前红点阵营的 `reddot_ai` 上）
    # ==================================================================

    def do_new_reddot_faction(self) -> None:
        """新建一个阵营，并**自动把它的 AI 设成红点性**（红点页专用）。

        ★★ 只落在**本关**的 `factions[]` 里（阵营表跟着关卡走：别的关卡 / 别的战役
          不会出现它），`ai = reddot`。建完把它设成红点页当前编辑的那一方 ——
          接着就能配生成地块 / 时间表，也能给它设「边」。
        """
        lv = self.level()
        if lv is None:
            return
        answer = _ask_new_faction(self.root, self.all_faction_ids())
        if not answer:
            return
        fid, name = answer
        entry = lv.ensure_faction(fid, name or fid, self.faction_color(fid))
        entry.ai = AI_REDDOT
        lv.mark_declared("factions")
        self.reddot_faction = fid
        self._after_change()
        self.status("新建红点阵营「%s」（AI 自动 = 红点性）—— 在上面给它设一条边"
                    % fid)

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

    def _reddot_tiles(self, key: str) -> List[Tuple[int, int]]:
        rd = self.reddot_params(False) or {}
        out: List[Tuple[int, int]] = []
        for t in model_mod._as_list(rd.get(key)):
            tp = model_mod._tile_of(t)
            if tp is not None:
                out.append(tp)
        return out

    def reddot_spawn_tiles(self) -> List[Tuple[int, int]]:
        return self._reddot_tiles(model_mod.REDDOT_SPAWN_TILES_KEY)

    def reddot_march_tiles(self) -> List[Tuple[int, int]]:
        """当前红点阵营的**行军目标地块**（`reddot_ai.march_tiles`）。"""
        return self._reddot_tiles(model_mod.REDDOT_MARCH_TILES_KEY)

    def reddot_tile_key(self) -> str:
        """红点页现在编的是哪一种格子（由 `reddot_click_mode` 决定）。"""
        return (model_mod.REDDOT_MARCH_TILES_KEY if self.reddot_click_mode == "march"
                else model_mod.REDDOT_SPAWN_TILES_KEY)

    def set_reddot_click_mode(self, mode: str) -> None:
        """切换画布点击模式：生成地块 / 行军目标。"""
        self.reddot_click_mode = "march" if mode == "march" else "spawn"
        where = "行军目标" if self.reddot_click_mode == "march" else "生成地块"
        n = len(self.reddot_march_tiles() if self.reddot_click_mode == "march"
                else self.reddot_spawn_tiles())
        self.status("红点页：左键点画布 = 编辑「%s」（现在 %d 个）" % (where, n))
        self.refresh_all()

    def _toggle_reddot_tile(self, cell: Tuple[int, int], force_remove: bool = False) -> None:
        """左/右键点画布：往**当前模式那一种**格子里加入 / 移出（生成地块 / 行军目标同一条路）。"""
        self._toggle_reddot_tiles(self.reddot_tile_key(), cell, force_remove)

    def _toggle_reddot_tiles(self, key: str, cell: Tuple[int, int],
                             force_remove: bool = False) -> None:
        info = self.map_info()
        if info is not None and (not info.tile_exists(cell[0], cell[1])
                                 or not info.walkable_at(cell[0], cell[1])):
            self.status("(%d,%d) 不能选：地图外或山地" % cell)
            return
        rd = self.reddot_params(True)
        if rd is None:
            self.status('没有红点阵营：本关没有 `ai: "reddot"` 的阵营'
                        '（AI 类型不在编辑器里改 —— 手改关卡 JSON）')
            return
        tiles = self._reddot_tiles(key)
        if cell in tiles:
            tiles = [t for t in tiles if t != cell]
            action = "移出"
        elif force_remove:
            return
        else:
            tiles.append(cell)
            action = "加入"
        rd[key] = [[int(x), int(y)] for x, y in tiles]
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        what = "行军目标" if key == model_mod.REDDOT_MARCH_TILES_KEY else "生成地块"
        self.status("%s红点%s (%d,%d)：现在共 %d 个"
                    % (action, what, cell[0], cell[1], len(tiles)))
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
        self._button(sec, REDDOT_NEW_FACTION, self.do_new_reddot_faction).pack(
            anchor="w", pady=(0, 4))
        if not reddots:
            self._hint(sec, "本关还没有红点阵营 —— 点上面的按钮建一个（会自动设成红点性 AI）。")
            return
        cur = self.reddot_faction_id()
        self._combo_cell(sec, "编辑哪一方", cur, tuple(reddots), self._set_reddot_faction)
        # ---- 这个红点阵营的「边」（敌友）----
        srow = tk.Frame(sec, bg=UI["panel"])
        srow.pack(side="top", fill="x", pady=2)
        tk.Label(srow, text="边", width=12, anchor="w", bg=UI["panel"],
                 fg=UI["text"]).pack(side="left")
        side_combo = ttk.Combobox(srow, values=self._side_choices(), width=18,
                                  state="readonly")
        side_combo.set(self._side_label_of(cur))
        side_combo.pack(side="left")
        side_combo.bind("<<ComboboxSelected>>",
                        lambda e, f=cur, c=side_combo: self._set_faction_side(f, c.get()))
        self._hint(sec, "边 = 敌友分组：同一条边里的阵营互为友军；不同的边 / 未分边的互相敌对。"
                        "（每条边都有谁，在「阵营」页看。）")
        rd = self.reddot_params(False) or {}

        # ---- 生成地块 / 行军目标（两种画布点击模式）----
        spawn_tiles = self.reddot_spawn_tiles()
        march_tiles = self.reddot_march_tiles()
        mode = self.reddot_click_mode
        tsec = self._section("画布点击：生成地块 / 行军目标",
                             "选一种，然后在画布上**左键点格** = 加/移出；右键 = 移出")
        row = tk.Frame(tsec, bg=UI["panel"])
        row.pack(side="top", fill="x", pady=2)
        for key, label in (("spawn", "生成地块"), ("march", "行军目标")):
            active = (mode == key)
            self._button(row, ("● " if active else "○ ") + label,
                         lambda k=key: self.set_reddot_click_mode(k),
                         padx=6, pady=3,
                         bg=UI["accent_btn"] if active else UI["panel_alt"],
                         fg=UI["accent_fg"] if active else UI["text"],
                         activebackground=UI["hover"]).pack(side="left", padx=(0, 4))
        self._hint(tsec, "已选：生成地块 %d 个；行军目标 %d 个。现在左键点画布 = 编辑「%s」。"
                         % (len(spawn_tiles), len(march_tiles),
                            "行军目标" if mode == "march" else "生成地块"))
        if mode == "march":
            self._hint(tsec, "★ 行军目标：每一波里**每位将领**从这些格子里随机挑一个行军"
                             "（非空时优先于单点 `attack_target`）。")
        self._button(tsec, "清空当前这一种", self._clear_reddot_tiles,
                     bg=UI["danger_btn"], fg=UI["danger_fg"]).pack(anchor="w", pady=(4, 0))

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
        """清空**当前模式**那一栏的所有格子（生成地块 / 行军目标）。"""
        rd = self.reddot_params(True)
        if rd is None:
            return
        key = self.reddot_tile_key()
        rd[key] = []
        lv = self.level()
        if lv is not None:
            lv.mark_declared("factions")
        what = "行军目标" if key == model_mod.REDDOT_MARCH_TILES_KEY else "生成地块"
        self.status("清空了红点%s" % what)
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
        # 点另一行 = 换了编辑对象：侧边栏回顶部，让「选中的单位 / 建筑」第一眼可见。
        self._sidebar_reset_pending = True
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
                     bg=UI["accent_btn"], fg=UI["accent_fg"]).pack(anchor="w", pady=4)
        self._button(section, "打开地图编辑器", self.open_map_editor).pack(anchor="w")
        if self.last_written:
            self._hint(section, "上一次写了 %d 个文件：\n%s"
                       % (len(self.last_written), "\n".join(self.last_written)))
        section2 = self._section("这一版不做的事", "见 dev_plan_7 6.6：编辑器的边界")
        for line in ("不做撤销 / 重做（数据都在 JSON 里，改坏了重新载入）",
                     "不做剧本预览（要预览就进游戏跑一关）",
                     "摆放不做自动避让（允许压在中心格上，但导出会拦）",
                     "单人关可跨边选阵营；合作关要求两个可玩阵营同方",
                     "不做「这一关大概多久成形」的估算提示（用户明确不要）",
                     "地形 / 区划 / 中心归地图编辑器；兵种 / 建筑数值归单位编辑器"):
            self._hint(section2, "· " + line)


# ======================================================================
# 小工具
# ======================================================================

def _walk_widgets(widget):
    """深度遍历一棵控件树（快照/恢复 Treeview 滚动位置用）。"""
    yield widget
    for child in widget.winfo_children():
        yield from _walk_widgets(child)


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


def _ask_new_faction(root: tk.Tk, taken: Sequence[str]) -> Optional[Tuple[str, str]]:
    """问「新建阵营的 id + 显示名」。

    ★ 与 `_ask_new_level` 同一套写法：抽成模块级函数，测试把它换成「直接给答案」，
      不去驱动真对话框。
    """
    fid = simpledialog.askstring("新建红点阵营", "阵营 id（如 red1；别和现有的撞）",
                                 parent=root)
    if not fid:
        return None
    fid = str(fid).strip()
    if not fid:
        return None
    if fid in set(str(x) for x in taken):
        messagebox.showwarning("id 撞了", "已经有阵营叫「%s」了 —— 换一个 id。" % fid,
                               parent=root)
        return None
    name = simpledialog.askstring("新建红点阵营", "显示名（可空 = 用 id）", parent=root)
    return fid, str(name or "").strip()


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
