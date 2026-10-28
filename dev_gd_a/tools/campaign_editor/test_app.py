"""test_app.py —— 战役编辑器**界面**的无头测试（建真窗口，但不显示、不截图）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/campaign_editor/test_app.py

做法（与 `unit_editor/test_app.py` 同一套）：真的 `Tk()` + `EditorApp`，改的是
**临时目录里的一份战役副本**（真 `data/campaigns/**` 一字不动），然后把真的控件抓出来、
灌值、发事件，断言「这一下之后数据层变成了什么样」。

覆盖（对应 dev_plan_7 6.5 那一行）：

    [1] 页签切换（五个页签 + 当前页签高亮 + 换页清选中）
    [2] 画布：放置 / 选中 / 删除（大本营不许在这里删）/ 缩放（以光标为锚点）/ 适应视图
    [2b] ★ 摆放手势：空格 + 左键拖动平移（放东西 / 选中都不许发生）；中键那条在 [2] 里
    [3] ★★ 红点页「行军目标」：画布点击模式（生成地块 / 行军目标）+ 左键加/移出
    [4] ★ 进攻目标箭头：终点 = 目标的区划中心；`target_label` 的人话
    [4c] ★ 敌友（边）：面板列每条边 + 「＋ 新建一条边」按钮；同边友好、异边敌对
    [4d] ★ 红点页新建阵营：自动红点性 AI + 给它设一条边
    [4e] ★★ 阵营表跟着关卡走（A 关加的一方在 B 关看不到）
    [4f] ★★ 换关卡不串编辑期状态（上一关的边 / 选中 / 红点当前方 / 画笔归属）
    [4g] ★★ 区划归属：没有「（用地图的）」，每块地显式；换地图整张重建
    [5] 导出：有拦截项时**禁止写文件**并弹框说清楚；没有拦截时才真写
    [6] 一键打开地图编辑器（**假 subprocess**，不真起地图编辑器）
    [7] 侧边栏「装得下就不许滚」（用户报过的 bug；判据是 canvasy(0)，不是 yview）

⚠️ 界面文案 / 像素级外观不在这里断言（那要靠人看，见 README.md）。
⚠️ 起不了 Tk 的机器（无显示器 / 没装 tkinter）会打印 `[skip]` 并以 **0** 退出。
"""

from __future__ import annotations

import hashlib
import shutil
import sys
import tkinter as tk
from pathlib import Path
from tkinter import ttk

HERE = Path(__file__).resolve()
PKG_PARENT = HERE.parent.parent                    # dev_gd_a/tools/
PROJECT_DIR = HERE.parent.parent.parent / "daeem"  # dev_gd_a/daeem/
if str(PKG_PARENT) not in sys.path:
    sys.path.insert(0, str(PKG_PARENT))

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")      # type: ignore[union-attr]
    except (AttributeError, ValueError):
        pass

from campaign_editor import app as app_module                      # noqa: E402
from campaign_editor import levelfile                              # noqa: E402
from campaign_editor import model as M                             # noqa: E402

#: 「属于将领」下拉里表示「不是附属兵」的那一项（与 `app.py` 里同一个常量 ——
#: 不在测试里重写一遍字符串，否则改名时测试会「跟着一起错」）。
ESCORT_NONE_LABEL = app_module.ESCORT_NONE_LABEL

#: ★ 临时目录放在**工具目录里**（不放系统 temp）：受限环境下系统 temp 不一定可写
#:   （实测踩到：`mkdtemp()` 成功、往里建子目录 `PermissionError`）。
TMP = HERE.parent / ".tmp_campaign_editor_app_test"
#: 这一套测试的「工程目录」= 临时副本（里面有 maps / config / campaigns 各一份）。
TMP_PROJECT = TMP / "project"
#: 被测的那一份战役（从真 demo 拷过来）。
CASE = "case"

_FAILED = 0
_PASSED = 0


def ok(cond, label: str) -> None:
    global _FAILED, _PASSED
    if cond:
        _PASSED += 1
        print("  [ok]   %s" % label)
    else:
        _FAILED += 1
        print("  [FAIL] %s" % label)


def eq(actual, expected, label: str) -> None:
    ok(actual == expected, "%s（实际 %r，期望 %r）" % (label, actual, expected))


class FakeEvent:
    """假事件（界面代码只读 x / y / delta / state / widget 这几样）。

    ★ `state` 是 tk 的修饰键/按键位；摆放页只用其中一位（左键按住 = B1），
      用来复现「拖动期间 tk 发的是带 B1 位的 `<Motion>` 而不是 `<B1-Motion>`」那条实测行为。
    """

    def __init__(self, widget=None, x: int = 0, y: int = 0, delta: int = 0,
                 state: int = 0) -> None:
        self.widget = widget
        self.x = x
        self.y = y
        self.delta = delta
        self.state = state


class FakePopen:
    """假 subprocess：**不真起地图编辑器**，只把命令记下来（6.5 要求）。"""

    calls: list = []

    def __init__(self, cmd, *args, **kwargs) -> None:
        FakePopen.calls.append(list(cmd))


class FakeSubprocess:
    Popen = FakePopen


# ======================================================================
# 控件抓取小工具
# ======================================================================

def walk(widget):
    """深度遍历一棵控件树。"""
    yield widget
    for child in widget.winfo_children():
        yield from walk(child)


def sectioned(app) -> dict:
    """「（节标题, 标签） → 输入框 / 下拉框」。

    ★ 为什么需要它：阵营页里同一个标签（「大本营」「资源倍率」…）每一方都出现一次，
      只按标签找会永远命中第一方那一行。
    """
    out = {}
    for section in app.sidebar.winfo_children():
        title = getattr(section, "section_title", None)
        if not title:
            continue
        for frame in walk(section):
            if not isinstance(frame, tk.Frame):
                continue
            kids = frame.winfo_children()
            if len(kids) < 2 or not isinstance(kids[0], tk.Label):
                continue
            label = kids[0].cget("text")
            entry = next((k for k in kids if isinstance(k, ttk.Entry)), None)
            combo = next((k for k in kids if isinstance(k, ttk.Combobox)), None)
            if entry is not None:
                out.setdefault((title, label), entry)
            if combo is not None:
                out.setdefault((title, "combo:" + label), combo)
    return out


def row(app, section: str, label: str):
    """按「节 + 标签」取控件（找不到就报出**现在有什么**，省得猜）。"""
    rows = sectioned(app)
    key = (section, label)
    if key not in rows:
        raise AssertionError("「%s」那一节里没有「%s」；现在是：%s"
                             % (section, label, "、".join("%s/%s" % k for k in rows)))
    return rows[key]


def faction_section(app, fid: str) -> str:
    """阵营页里「某方那一节」的标题（形如 `"F1 赤军"`）。

    ★ 标题是 `"%s %s" % (id, 名字)` 拼出来的（名字可能为空），所以按前缀找，
      不要把标题在测试里再拼一遍 —— 那样改一次界面文案就红一片。
    """
    for section in app.sidebar.winfo_children():
        title = getattr(section, "section_title", None)
        if title and (title == fid or title.startswith(fid + " ")):
            return title
    raise AssertionError("阵营页里没有「%s」那一节；现在是：%s"
                         % (fid, "、".join(str(getattr(s, "section_title", ""))
                                          for s in app.sidebar.winfo_children())))


def buttons(app) -> dict:
    out = {}
    for widget in walk(app.sidebar):
        if isinstance(widget, tk.Button):
            out.setdefault(widget.cget("text"), widget)
    return out


def head_buttons(app) -> dict:
    """摆放页画布上方那一条里的按钮（「打开地图编辑器」在那里）。"""
    out = {}
    for widget in walk(app.canvas_host):
        if isinstance(widget, tk.Button):
            out.setdefault(widget.cget("text"), widget)
    return out


def type_into(app, entry, text: str) -> None:
    """往输入框里灌值并提交（等价于打字 + 回车）。

    ★ 为什么不发真键盘事件：tk 只把键事件投给**有 OS 焦点**的窗口
      （实测 withdraw 的窗口收不到），而无头测试不该去抢焦点。
      界面把 Return / FocusOut 绑的那个函数挂在 `entry.commit_action` 上，这里调的就是它。
    """
    entry.delete(0, "end")
    entry.insert(0, text)
    action = getattr(entry, "commit_action", None)
    if action is not None:
        action()
    else:                                              # pragma: no cover - 兜底
        entry.event_generate("<Return>")
    app.root.update()


def pick_combo(app, combo, value: str) -> None:
    combo.set(value)
    action = getattr(combo, "commit_action", None)
    if action is not None:
        action()
    else:                                              # pragma: no cover - 兜底
        combo.event_generate("<<ComboboxSelected>>")
    app.root.update()


def click_canvas(app, cell) -> None:
    """在画布上左键点某一格（走真的事件处理函数）。"""
    sx, sy = app.cell_origin(cell[0] + 0.5, cell[1] + 0.5)
    app.on_left_click(FakeEvent(app.canvas, int(sx), int(sy)))
    app.root.update()


def right_click_canvas(app, cell) -> None:
    sx, sy = app.cell_origin(cell[0] + 0.5, cell[1] + 0.5)
    app.on_right_click(FakeEvent(app.canvas, int(sx), int(sy)))
    app.root.update()


def setup(show_all_levels: bool = True) -> tuple:
    """开一个真窗口 + 一份临时战役副本。"""
    shutil.rmtree(TMP, ignore_errors=True)
    TMP_PROJECT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(PROJECT_DIR / "data" / "maps", TMP_PROJECT / "data" / "maps")
    shutil.copyfile(PROJECT_DIR / "data" / "config.json", TMP_PROJECT / "data" / "config.json")
    catalog = PROJECT_DIR / "data" / "editor_visible.json"
    if catalog.is_file():
        shutil.copyfile(catalog, TMP_PROJECT / "data" / "editor_visible.json")
    shutil.copytree(PROJECT_DIR / "data" / "campaigns" / "demo",
                    TMP_PROJECT / "data" / "campaigns" / CASE)
    model = levelfile.load_campaign(TMP_PROJECT / "data" / "campaigns" / CASE, TMP_PROJECT)
    root = tk.Tk()
    root.withdraw()                        # 不显示（无头也能跑）
    app = app_module.EditorApp(root, model, TMP_PROJECT,
                               show_all_levels=show_all_levels)
    app.subprocess_mod = FakeSubprocess    # ★ 不真起地图编辑器
    root.update()
    return app, model


def teardown(app) -> None:
    try:
        app.root.destroy()
    except tk.TclError:
        pass


def level(app):
    return app.level()


# ======================================================================
# [1] 窗口 / 页签 / 列表
# ======================================================================

def t_window(app, model) -> None:
    print("\n[1] 窗口 / 页签 / 列表")
    eq(app.page, "campaign", "默认停在「战役」页")
    eq(list(app.tab_buttons.keys()),
       ["campaign", "level", "factions", "place", "zone", "reddot", "check"],
       "七个页签")
    eq(app.tab_buttons["campaign"].cget("fg"), app_module.UI["accent"], "当前页签是强调色")
    eq(app.tab_buttons["place"].cget("fg"), app_module.UI["text_dim"], "其它页签是暗色")
    eq(len(app.level_tree.get_children()), len(model.levels), "战役页列出全部关卡")
    eq(app.level_tree.item("lv:%s" % level(app).level_id, "values")[1],
       level(app).level_id, "列表里有关卡 id")

    app.set_page("level")
    app.root.update()
    # ⚠️ 换页之后**不能**再去读 `app.level_tree`：那是战役页那棵树，已经被销毁重建了
    #    （读它会抛 `invalid command name ...!treeview` —— 实测踩到）。
    #    要看「关卡页显示的是不是当前关」，就去抓它这一页的 Label 文字。
    texts = [w.cget("text") for w in walk(app.work) if isinstance(w, tk.Label)]
    ok(any(level(app).level_id in t for t in texts), "关卡页写着当前关的 id")
    ok(any("守住" in t for t in texts), "关卡页写着当前关的目标摘要")
    ok(app.tab_buttons["level"].cget("fg") == app_module.UI["accent"], "换页签之后高亮跟着走")

    app.set_page("factions")
    app.root.update()
    titles = [getattr(s, "section_title", "") for s in app.sidebar.winfo_children()]
    ok("敌友（边）" in titles, "阵营页有「敌友（边）」那一栏")

    app.set_page("place")
    app.root.update()
    ok(hasattr(app, "canvas") and app.canvas.winfo_exists(), "摆放页有画布")
    ok(app_module.CANVAS_HINT in [w.cget("text") for w in walk(app.canvas_host)
                                  if isinstance(w, tk.Label)],
       "★ 界面上写清了「地形 / 区划从地图读出来画成背景」（不是只在 README 里）")

    app.set_page("check")
    app.root.update()
    ok(hasattr(app, "issue_tree"), "校验页有结果列表")
    ok(len(app.last_issues) >= 0, "进校验页时自动跑了一遍校验")
    app.set_page("campaign")
    app.root.update()
    eq(app.selection, None, "换页签之后选中被清掉")


# ======================================================================
# [2] 画布：放置 / 选中 / 删除 / 缩放
# ======================================================================

def t_canvas(app, model) -> None:
    print("\n[2] 画布：放置 / 选中 / 删除 / 缩放")
    app.root.deiconify()                   # geometry / 画布尺寸要真实窗口才生效
    app.root.geometry("1340x900")
    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()
    eq(app.screen_to_cell(*app.cell_origin(3, 4)), (3, 4), "屏幕 ↔ 格子换算是一对逆运算")

    f = _facts(app)
    lv = level(app)
    before_units = len(lv.start_units)
    app.brush_kind = "unit"
    app.brush_value = app.config.unit_types[0] if app.config.unit_types else "enemy"
    app.brush_faction = f["player"]
    app.place_at(f["spot"])
    eq(len(level(app).start_units), before_units + 1, "★ 放了一个单位")
    u = level(app).start_units[-1]
    eq((u.x, u.y), f["spot"], "放在点的那一格")
    eq(u.faction, f["player"], "归属是画笔上那一方")
    eq(app.selection, ("unit", before_units), "放完自动选中它")

    # 左键点已有的 → 选中（而不是又放一个）
    click_canvas(app, f["spot"])
    eq(len(level(app).start_units), before_units + 1, "点已有的**不会再放一个**")
    eq(app.selection, ("unit", before_units), "点已有的 = 选中")

    # 选中之后右栏能改它的字段
    entry = row(app, "选中的单位", "x,y")
    type_into(app, entry, "%d,%d" % (f["spot"][0] + 1, f["spot"][1] + 1))
    eq((level(app).start_units[-1].x, level(app).start_units[-1].y),
       (f["spot"][0] + 1, f["spot"][1] + 1), "★ 右栏改坐标写进了关卡数据")
    # ★ zone 改成**下拉**（列出地图里的区划）：选一个 → 写进单位的 zone（区划编号）
    zone_combo = row(app, "选中的单位", "combo:区划")
    zid = sorted(app.map_info().zone_ids)[0]
    pick_combo(app, zone_combo, app.map_info().zone_label(zid))
    eq(level(app).start_units[-1].zone, int(zid), "右栏用下拉选「区划」→ 写进 zone 编号")
    ai_combo = row(app, "选中的单位", "combo:ai")
    pick_combo(app, ai_combo, "阵地性")
    eq(level(app).start_units[-1].ai, M.AI_GARRISON, "右栏把 AI 改成阵地性")
    pick_combo(app, row(app, "选中的单位", "combo:ai"), "无")
    eq(level(app).start_units[-1].ai, M.AI_NONE, "改回「无」")

    # 右键删
    moved = (f["spot"][0] + 1, f["spot"][1] + 1)
    right_click_canvas(app, moved)
    eq(len(level(app).start_units), before_units, "★ 右键删掉它")
    eq(app.selection, None, "删完清掉选中")

    # 放建筑 + 删
    app.selection = None
    app.brush_kind = "building"
    app.brush_value = app.config.building_types[0] if app.config.building_types else "tower"
    app.root.update()
    app.place_at(f["spot"])
    eq(len(level(app).start_buildings), 2, "★ 放了一个建筑（样例关本来有一个塔）")
    right_click_canvas(app, f["spot"])
    eq(len(level(app).start_buildings), 1, "右键删掉建筑")

    # ★ 大本营改用「大本营」画笔在摆放页摆 / 右键删
    app.selection = None
    app.brush_kind = "base"
    app.brush_faction = f["player"]
    app.root.update()
    app.place_at(f["spot"])
    eq(level(app).ensure_faction(f["player"]).base, f["spot"],
       "★ 「大本营」画笔把家写进 factions[].base")
    right_click_canvas(app, f["spot"])
    ok(level(app).ensure_faction(f["player"]).base is None,
       "★★ 右键点大本营 → 在摆放页直接删掉")

    # ---- 缩放：以光标为锚点 ----
    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()
    anchor = (app.canvas.winfo_width() // 2 + 40, app.canvas.winfo_height() // 2 + 20)
    before_cell = app.screen_to_cell(*anchor)
    zoom_before = app.zoom
    app.on_wheel(FakeEvent(app.canvas, anchor[0], anchor[1], delta=120))
    app.root.update()
    ok(app.zoom > zoom_before, "★ 滚轮向上 = 放大（%.3f → %.3f）" % (zoom_before, app.zoom))
    eq(app.screen_to_cell(*anchor), before_cell, "★★ 以光标为锚点：光标底下那一格没跑")
    app.on_wheel(FakeEvent(app.canvas, anchor[0], anchor[1], delta=-120))
    app.root.update()
    ok(abs(app.zoom - zoom_before) < 1e-6, "★ 滚回去 = 回到原来的缩放")
    for _ in range(60):
        app.on_wheel(FakeEvent(app.canvas, 10, 10, delta=120))
    ok(app.zoom <= app_module.MAX_ZOOM + 1e-9, "★ 放大有上限（%.3f ≤ %.2f）"
       % (app.zoom, app_module.MAX_ZOOM))
    for _ in range(120):
        app.on_wheel(FakeEvent(app.canvas, 10, 10, delta=-120))
    ok(app.zoom >= app_module.MIN_ZOOM - 1e-9, "★ 缩小有下限（%.3f ≥ %.2f）"
       % (app.zoom, app_module.MIN_ZOOM))

    # 中键拖动 = 平移
    ox, oy = app.ox, app.oy
    app.on_middle_down(FakeEvent(app.canvas, 100, 100))
    app.on_middle_drag(FakeEvent(app.canvas, 130, 118))
    app.on_middle_up(FakeEvent(app.canvas, 130, 118))
    eq((app.ox, app.oy), (ox + 30, oy + 18), "★ 中键拖动平移视野")

    # 适应视图 / 悬停状态栏
    app.fit_view()
    app.root.update()
    ok(app.zoom >= app_module.MIN_ZOOM, "适应视图之后缩放仍在区间内")
    app.root.update_idletasks()
    if app.canvas.winfo_width() < 20 or app.canvas.winfo_height() < 20:
        print("  [skip] 画布还没排版（%dx%d），跳过悬停那一条"
              % (app.canvas.winfo_width(), app.canvas.winfo_height()))
    else:
        app.fit_view()
        app.root.update()
        sx, sy = app.cell_origin(f["spot"][0] + 0.5, f["spot"][1] + 0.5)
        app.on_motion(FakeEvent(app.canvas, int(sx), int(sy)))
        ok(("(%d,%d)" % f["spot"]) in app.status_var.get(),
           "★ 悬停时状态栏显示格坐标：%s" % app.status_var.get())
        ok("地形" in app.status_var.get(), "★ 状态栏还写了地形与区划")


# ======================================================================
# [2b] ★ 摆放手势：空格 + 左键拖动 = 平移视野（放东西 / 选中都不许发生）
# ======================================================================

def t_space_drag_pan(app, model) -> None:
    print("\n[2b] ★ 摆放手势：空格 + 左键拖动 = 平移（中键那条已在 [2] 里钉过）")
    app.root.deiconify()
    app.root.geometry("1340x900")
    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()
    app.root.update_idletasks()

    # ---- A. 「按下空格」这件事真的接上了：不只是回调存在，而是真绑到了画布上 ----
    ok(bool(app.canvas.bind("<KeyPress-space>")) and bool(app.canvas.bind("<KeyRelease-space>")),
       "★★ 画布上绑了 <KeyPress-space> / <KeyRelease-space>（只有回调不算接上）")
    ok(bool(app.canvas.bind("<Button-1>")) and bool(app.canvas.bind("<ButtonRelease-1>")),
       "★ 画布上绑了左键的按下与松开（单击判定靠这一对）")
    ok(not app.space_held, "一开始不在平移模式")
    app.canvas.focus_set()                    # 空格要画布拿住键盘焦点才收得到
    app.root.update()
    app.canvas.event_generate("<KeyPress-space>")
    app.root.update()
    ok(app.space_held, "★★ 画布上按空格 → 进入平移模式")
    ok(str(app.canvas.cget("cursor")) == "fleur", "★ 平移模式下鼠标指针变成 fleur（一眼看出能拖）")
    app.canvas.event_generate("<KeyRelease-space>")
    app.root.update()
    ok(not app.space_held, "★ 松开空格 → 退出平移模式")

    # Space 的所有权：焦点在输入框里时不该被画布抢走（走的是回调，避免无头窗口抢不到焦点）
    entries = [widget for widget in walk(app.sidebar) if isinstance(widget, ttk.Entry)]
    if not entries:
        print("  [skip] 侧边栏里没找到输入框，跳过「输入框里空格不被抢」那一条")
    else:
        entry = entries[0]
        entry.focus_set()
        app.root.update()
        app.on_space_down(FakeEvent(app.canvas, 100, 100))
        ok(not app.space_held, "★★ 键盘焦点在输入框里时按空格**不**进平移模式（还能打字）")
        app.canvas.focus_set()
        app.root.update()

    # ---- B. 空格 + 左键拖动 = 平移视野，而且**什么都没放到地图上** ----
    f = _facts(app)
    before_units = len(level(app).start_units)
    app.selection = None
    app.brush_kind = "unit"
    app.brush_faction = f["player"]
    app.root.update()
    ox0, oy0 = app.ox, app.oy
    zoom0 = app.zoom

    app.on_space_down(FakeEvent(app.canvas, 300, 300))
    ok(app.space_held, "★ `on_space_down` 进入平移模式")
    ok(app_module.PAN_MODE_HINT in app.status_var.get(),
       "★ 状态栏说了怎么用：%s" % app.status_var.get())
    app.on_left_down(FakeEvent(app.canvas, 300, 300, state=app_module.BUTTON1_MASK))
    eq(app._pan_anchor, (300, 300), "★ 空格按住时左键按下 = 武装一次平移")
    app.on_left_drag(FakeEvent(app.canvas, 340, 322, state=app_module.BUTTON1_MASK))
    app.on_left_up(FakeEvent(app.canvas, 340, 322, state=app_module.BUTTON1_MASK))
    eq((app.ox, app.oy), (ox0 + 40, oy0 + 22), "★★ 空格 + 左键拖动平移了视野")
    eq(app.zoom, zoom0, "★ 平移不改缩放")
    eq(len(level(app).start_units), before_units, "★★ 拖过画面不算「点」：一个单位都没放")
    eq(app.selection, None, "★ 也没改选中")
    eq(app._pan_anchor, None, "★ 松手之后平移状态清干净")

    # ---- C. ★★ 拖动期间 tk 只发带 B1 位的 <Motion>：那条路也必须能拖 ----
    #   （这是 map_editor 里实测过的 tk 行为；只绑 <B1-Motion> 的实现会在这里装作没反应。）
    ox1, oy1 = app.ox, app.oy
    app.on_space_down(FakeEvent(app.canvas, 300, 300))
    app.on_left_down(FakeEvent(app.canvas, 300, 300, state=app_module.BUTTON1_MASK))
    app.on_motion(FakeEvent(app.canvas, 325, 310, state=app_module.BUTTON1_MASK))
    eq((app.ox, app.oy), (ox1 + 25, oy1 + 10), "★★ 带 B1 位的 <Motion> 也把视野推到位")
    ok(app.hover is None, "★ 平移期间不留「光标底下那一格」的高亮")
    app.on_left_up(FakeEvent(app.canvas, 325, 310, state=app_module.BUTTON1_MASK))
    eq(len(level(app).start_units), before_units, "★ 这一路也没有放东西")

    # ---- D. 空格 + 左键「点一下」（没拖）= 什么都不做（既不放东西，也不移视野）----
    ox2, oy2 = app.ox, app.oy
    app.on_left_down(FakeEvent(app.canvas, 300, 300, state=app_module.BUTTON1_MASK))
    app.on_left_up(FakeEvent(app.canvas, 300, 300, state=app_module.BUTTON1_MASK))
    eq((app.ox, app.oy), (ox2, oy2), "★★ 空格 + 左键轻点：视野不动")
    eq(len(level(app).start_units), before_units, "★★ 空格 + 左键轻点：也不放东西（左键被平移接管了）")

    # ---- E. 没按空格时：单击照旧能放东西（**别把正常摆放弄坏**）----
    app.on_space_up(FakeEvent(app.canvas, 300, 300))
    ok(not app.space_held, "★ 松开空格回到「放东西 / 选中」")
    ok(str(app.canvas.cget("cursor")) == "", "★ 指针也恢复默认")
    sx, sy = app.cell_origin(f["spot"][0] + 0.5, f["spot"][1] + 0.5)
    app.on_left_down(FakeEvent(app.canvas, int(sx), int(sy)))
    app.on_left_up(FakeEvent(app.canvas, int(sx), int(sy)))
    app.root.update()
    eq(len(level(app).start_units), before_units + 1, "★★ 没按空格时左键单击照旧放东西")
    eq(app.selection, ("unit", before_units), "★ 并且选中刚放的那一个")

    # ---- F. 手抖容差：按下与松开之间挪了几像素 → 当点击，不当拖动 ----
    app.on_left_down(FakeEvent(app.canvas, 300, 300))
    app.on_left_up(FakeEvent(app.canvas, 302, 301))
    ok(app._left_down_at is None, "★ 一次按下-松开配对之后起点被清掉")

    # ---- G. 换页签时把平移状态丢掉（画布会被整块重建，别让新画布跟着鼠标跑）----
    app.on_space_down(FakeEvent(app.canvas, 300, 300))
    app.on_left_down(FakeEvent(app.canvas, 300, 300, state=app_module.BUTTON1_MASK))
    ok(app._pan_anchor is not None, "（前提）现在正按着空格拖画面")
    app.set_page("campaign")
    app.root.update()
    ok(not app.space_held and app._pan_anchor is None and app._left_down_at is None,
       "★★ 换页签之后平移状态清干净（新画布不会一进来就跟着鼠标跑）")
    app.set_page("place")
    app.root.update()


def _facts(app) -> dict:
    """测试用例用到的「合成事实」——从被测工程的地图里现读（不写死坐标）。

    ★ 为什么现读：`data/maps/dongzheng/` 与 `data/campaigns/demo/` 是**别人也在改**的样例
      数据（搬过大本营）。断言里写死坐标的后果是「界面的测试」因为样例数据搬家而红。
    """
    lv = level(app)
    info = app.map_info()
    player = lv.seats()[0] if lv.seats() else (info.factions[0]["id"] if info.factions
                                               else "F1")
    base = None
    for p in lv.players:
        if p.get("faction") == player and p.get("base") is not None:
            base = tuple(p["base"])
    if base is None and info is not None:
        got = info.faction_base(player)
        base = tuple(got) if got else (0, 0)
    centers = set(info.zone_centers.values()) if info is not None else set()
    spot = None
    if info is not None:
        for y in range(info.rows):
            for x in range(info.cols):
                if (x, y) in centers or not info.walkable_at(x, y):
                    continue
                if any(u.point() == (x, y) for u in lv.start_units):
                    continue
                if any(b.point() == (x, y) for b in lv.start_buildings):
                    continue
                if (x, y) == base:
                    continue
                spot = (x, y)
                break
            if spot:
                break
    return {"player": player, "player_base": base, "spot": spot or (3, 3),
            "map_id": lv.map_id, "obj_zone": lv.objective_zone()}


# ======================================================================
# [3] ★★ 红点页：画布点击模式（生成地块 / 行军目标）
# ======================================================================

def t_reddot_march_tiles(app, model) -> None:
    """★★ 红点页的行军目标：切到「行军目标」模式后**左键点格** = 加/移出，
    写进 `reddot_ai.march_tiles`（运行时每位将领随机挑一格）；切回「生成地块」不动它。"""
    print("\n[3] ★★ 红点页：生成地块 / 行军目标 两种画布点击模式")
    f = _facts(app)
    lv = level(app)
    app.set_page("reddot")
    app.root.update()
    app.fit_view()
    app.root.update()
    # 建一个红点阵营来编辑（`do_new_reddot_faction` 会弹输入框 → 存根掉）
    real_ask = app_module._ask_new_faction
    app_module._ask_new_faction = lambda root, taken: ("march_probe", "行军探针")
    try:
        app.do_new_reddot_faction()
        app.root.update()
    finally:
        app_module._ask_new_faction = real_ask
    fid = app.reddot_faction_id()
    eq(fid, "march_probe", "★ 建了一个红点阵营并成为当前编辑方")
    eq(app.reddot_click_mode, "spawn", "默认左键 = 编辑「生成地块」")
    eq(app.reddot_march_tiles(), [], "（前提）一开始没有行军目标")

    app.set_reddot_click_mode("march")
    eq(app.reddot_click_mode, "march", "★ 切到「行军目标」模式")
    click_canvas(app, f["spot"])                 # 左键点一格 = 加入
    ok(f["spot"] in app.reddot_march_tiles(), "★ 左键点格 → 加进行军目标")
    ok(f["spot"] not in app.reddot_spawn_tiles(), "★ 没有动「生成地块」那一栏")
    click_canvas(app, f["spot"])                 # 再点一次 = 移出
    ok(f["spot"] not in app.reddot_march_tiles(), "★ 再点一次 → 移出")
    click_canvas(app, f["spot"])
    rd = lv.faction(fid).reddot_ai or {}
    eq(rd.get(M.REDDOT_MARCH_TILES_KEY), [[int(f["spot"][0]), int(f["spot"][1])]],
       "★ 落进 `reddot_ai.march_tiles`")

    # 切回「生成地块」：左键现在编生成地块，行军目标那一栏原封不动
    app.set_reddot_click_mode("spawn")
    click_canvas(app, f["spot"])
    ok(f["spot"] in app.reddot_spawn_tiles(), "★ 切回生成地块 → 左键编的是它")
    eq(rd.get(M.REDDOT_MARCH_TILES_KEY), [[int(f["spot"][0]), int(f["spot"][1])]],
       "★ 行军目标没有被顺带改掉")


# ======================================================================
# [4] 进攻目标箭头（目标只在 JSON / ⑥ 红点页设）
# ======================================================================

def t_same_field(app, model) -> None:
    print("\n[4] ★ 进攻目标箭头：终点 = 目标的区划中心；人话标签")
    f = _facts(app)
    lv = level(app)
    info = app.map_info()
    lv.ensure_faction(f["player"]).ai = M.AI_GARRISON
    lv.ensure_faction(f["player"]).attack_target = {"kind": M.TARGET_ZONE,
                                                    "zone": int(f["obj_zone"])}
    app.refresh_all()

    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()
    spec = level(app).faction(f["player"]).attack_target
    eq(app._target_point(level(app), app.map_info(), spec),
       info.zone_centers[int(f["obj_zone"])],
       "★ ④ 读到的目标点 = 目标的区划中心")
    eq(M.target_label(level(app).faction(f["player"]).attack_target),
       "指定区划 %s" % M.zone_label(int(f["obj_zone"])),
       "★ 目标的一行人话（`target_label` 不查地图，所以只用 c<id> 记法）")


# ======================================================================
# [4c] ★★ 敌友（边）：同边友好、异边敌对 —— 写进关卡 allies
# ======================================================================

def t_ally_sides(app, model) -> None:
    print("\n[4c] ★ 敌友（边）：同边友好、异边敌对（写进关卡 allies）")
    app.set_page("factions")
    app.root.update()
    lv = level(app)
    orig_pairs = [list(p) for p in lv.allies]
    orig_declared = lv.allies_declared

    ok("敌友（边）" in [getattr(s, "section_title", "") for s in app.sidebar.winfo_children()],
       "★ 阵营页出现「敌友（边）」那一节")

    ids = list(app.all_faction_ids())
    if len(ids) < 3:
        ok(False, "至少要有三个阵营才能测敌友（用例前提）")
        return
    a, b, c = ids[0], ids[1], ids[2]

    # ---- 清干净（直接改缓存再提交，保证从「一条边都没有」开始）----
    app._sides = []
    app._commit_sides()
    app.root.update()
    eq(lv.allies, [], "★ 全部「未分边」→ allies 为空（全部互相敌对）")
    ok(lv.allies_declared, "★ 动过敌友之后 allies 就是「声明过」的（不再用地图的）")

    # ---- 点「＋ 新建一条边」→ 多出一条**看得见的空边**（用户报的「点了没反应」）----
    btn = buttons(app).get(app_module.ALLY_NEW_SIDE)
    ok(btn is not None, "★ 敌友那一节里有「＋ 新建一条边」按钮")
    if btn is not None:
        btn.invoke()
    app.root.update()
    eq(len(app._level_sides()), 1, "★★ 点按钮 → 多出一条边（看得见，不再像没反应）")
    ok(app._level_sides()[-1] == [], "★ 新建的边一开始是空的（在面板里显示「（空）」）")

    # ---- 把 a 放进这条新边（走下拉）----
    new_label = "边 %d" % len(app._level_sides())
    combo = sectioned(app).get(("敌友（边）", "combo:%s %s" % (a, level(app).faction_name(a))))
    ok(combo is not None, "★ 每个阵营都有一个「在哪条边」的下拉")
    if combo is not None:
        pick_combo(app, combo, new_label)
    eq(app._side_label_of(a), new_label, "★★ a 进了新建的那条边")

    # ---- b 也进同一条边 ----
    app._set_faction_side(b, new_label)
    eq(app._side_label_of(b), new_label, "★★ b 被放进同一条边")
    eq(lv.allies, [[a, b]], "★★ 同一条边 → allies 里是 [a, b]（两两一对）")

    # ---- c 另开一条边 → 与 a/b 敌对 ----
    app._new_side()
    app.root.update()
    label_c = "边 %d" % len(app._level_sides())
    app._set_faction_side(c, label_c)
    ok(app._side_label_of(c) != new_label, "★★ c 在另一条边上")
    eq(lv.allies, [[a, b]], "★★ 不同边之间**不写** allies（= 互相敌对）")

    # ---- 把 b 移出 → a 单独一条边（单成员边不写 allies）----
    app._set_faction_side(b, app_module.ALLY_UNSIDED)
    eq(lv.allies, [], "★ 只剩单成员边 → allies 为空（单个成员等于没分边）")
    eq(app._side_label_of(b), app_module.ALLY_UNSIDED, "★ b 回到「未分边」")

    # ---- 复原（别把样例的敌友改坏了，后面的用例还要用）----
    lv.allies = orig_pairs
    lv.allies_declared = orig_declared
    app._sides = None
    app.refresh_all()
    app.root.update()


# ======================================================================
# [4d] ★★ 红点页新建阵营：自动红点性 AI + 给它设一条边
# ======================================================================

def t_new_reddot_faction(app, model) -> None:
    print("\n[4d] ★ 红点页：新建阵营（自动红点性）+ 给它设一条边")
    lv = level(app)
    added = "red_probe"
    orig_pairs = [list(p) for p in lv.allies]
    orig_declared = lv.allies_declared

    app.set_page("reddot")
    app.root.update()
    btn = buttons(app).get(app_module.REDDOT_NEW_FACTION)
    ok(btn is not None, "★ 红点页有「＋ 新建红点阵营」按钮")

    real_ask = app_module._ask_new_faction
    app_module._ask_new_faction = lambda root, taken: (added, "红点探针")
    try:
        if btn is not None:
            btn.invoke()
        app.root.update()
    finally:
        app_module._ask_new_faction = real_ask

    ok(lv.faction(added) is not None and lv.faction(added).ai == M.AI_REDDOT,
       "★ 新阵营只进了**本关**的 factions[]（自动红点性 AI）")
    ok(not any(str(e.get("id", "")) == added for e in model.to_dict().get("factions", [])),
       "★★ campaign.json 里**没有**阵营表（不再全战役共用）")
    other = next((x for x in model.levels if x is not lv), None)
    if other is not None:
        ok(other.faction(added) is None,
           "★★ 另一关完全看不到它（阵营表跟着关卡走，不互相污染）")
    e = lv.faction(added)
    if e is not None:
        eq(e.ai, M.AI_REDDOT, "★★ 自动设成红点性 AI")
    reddots = [x.fid for x in lv.factions if x.ai == M.AI_REDDOT]
    ok(added in reddots, "★ 出现在红点阵营列表里")
    eq(app.reddot_faction_id(), added, "★ 建完就是红点页当前编辑的那一方")

    # ---- 给它设一条边 ----
    app._new_side()
    app.root.update()
    label = "边 %d" % len(app._level_sides())
    app._set_faction_side(added, label)
    eq(app._side_label_of(added), label, "★ 给这个红点阵营设了一条边（写进 allies）")

    # ---- 复原（别把样例改坏）----
    lv.remove_faction(added)
    lv.allies = orig_pairs
    lv.allies_declared = orig_declared
    app.reddot_faction = ""
    app._reset_sides()
    app.refresh_all()
    app.root.update()


# ======================================================================
# [4b] ★★ 附属部队：在摆放页摆兵 + 指定它属于哪位将领（所见即所得）
# ======================================================================

def t_escort_placement(app, model) -> None:
    print("\n[4b] ★★ 摆放页：摆将领 → 配「附属单位规格」（数量 + 兵种权重）")
    f = _facts(app)
    lv = level(app)
    lv.start_units = []
    lv.mark_declared("start_units")
    lv.ensure_faction(f["player"])
    app.refresh_all()
    app.set_page("place")
    app.root.update()

    # ---- 1) 画笔选「将领」，在玩家大本营上放一位 ----
    pick_combo(app, row(app, "画笔", "combo:放什么"), "将领")
    app.root.update()
    pick_combo(app, row(app, "画笔", "combo:归属"), f["player"])
    app.brush_faction = f["player"]
    app.place_at(f["player_base"])
    eq(len(level(app).start_units), 1, "★ 画布上放过了一个单位")
    gen = level(app).start_units[0]
    ok(gen.is_general(), "★ 它是将领")
    eq(int(gen.general_index or 1), 1, "★★ 第一位将领的序号自动是 1")
    eq(int(gen.escort_count), 0, "★ 新摆的将领默认生成数量 0（光杆）")

    # ---- 1b) ★★ 「将领」（哪个将领 = 兵种/数值档）与「将领序号」（名册号 1..10）解耦 ----
    eq(gen.unit_type, app.config.general_types[0], "★ 新摆的将领默认是第 1 档兵种")
    pick_combo(app, row(app, "选中的单位", "combo:将领"),
               app.config.general_label(3))
    eq(gen.unit_type, app.config.general_types[2], "★★ 选「将领 3」→ 兵种变成第 3 档")
    # 将领序号 = 名册号：允许 10，且改它不影响「哪个将领」
    app._set_unit_field("general_index", 10)
    eq(int(gen.general_index), 10, "★★ 将领序号可以是 10（不再限于 1..3）")
    eq(gen.unit_type, app.config.general_types[2], "★ 改将领序号不影响「哪个将领」")
    out1 = level(app).to_dict()["start_units"][0]
    eq(out1.get("general_index"), 10, "★★ 名册号 10 写进 JSON")
    eq(out1.get("unit_type"), app.config.general_types[2], "★★ 将领档（兵种）也写进 JSON")
    # 复原，不影响后面的用例
    app._set_unit_field("general_index", 1)
    pick_combo(app, row(app, "选中的单位", "combo:将领"), app.config.general_label(1))
    eq(gen.unit_type, app.config.general_types[0], "★ 复原成将领 1")

    # ---- 1c) ★★ 档位 > 3：types 里有重复兵种，必须靠 general_profile 记住「第几档」 ----
    #   用户报的 bug：选「将领 4/5/6…」后显示按 1/2/3 循环。
    eq(len(app.config.general_types) >= 10, True,
       "（前提）当前配置有 10 个将领档位（实际 %d）" % len(app.config.general_types))
    for n in (4, 5, 6, 7, 8, 9, 10):
        pick_combo(app, row(app, "选中的单位", "combo:将领"), app.config.general_label(n))
        gen = level(app).start_units[0]
        eq(int(gen.general_profile or 0), n, "★★ 选「将领 %d」→ general_profile = %d" % (n, n))
        eq(gen.unit_type, app.config.general_types[n - 1],
           "★ 将领 %d 的兵种 = types[%d]" % (n, n - 1))
        eq(app._general_label_of_unit(gen), app.config.general_label(n),
           "★★ 刷新后显示还是「将领 %d」（不再 1/2/3 循环）" % n)
        out_n = level(app).to_dict()["start_units"][0]
        eq(out_n.get("general_profile"), n,
           "★★ 将领 %d 的档位写进 JSON（general_profile）" % n)
    # 选回 1..3 档：unit_type 已能唯一确定档位，不写多余的 general_profile
    pick_combo(app, row(app, "选中的单位", "combo:将领"), app.config.general_label(3))
    gen = level(app).start_units[0]
    ok(gen.general_profile is None, "★ 第 3 档（兵种唯一）不写 general_profile")
    ok("general_profile" not in level(app).to_dict()["start_units"][0],
       "★ 导出也不落这个键（旧数据格式保持不变）")
    pick_combo(app, row(app, "选中的单位", "combo:将领"), app.config.general_label(1))
    eq(gen.unit_type, app.config.general_types[0], "★ 复原成将领 1")

    # ---- 2) 画笔里**没有**「附属兵」这一档（逐兵摆放已被规格取代）----
    brush = row(app, "画笔", "combo:放什么").cget("values")
    ok("附属兵" not in list(brush), "★★ 画笔不再有「附属兵」，实际 %r" % (brush,))

    # ---- 3) 侧栏出现「附属单位规格」编辑器 ----
    app.selection = ("unit", 0)
    app.refresh_all()
    app.root.update()
    ok(("附属单位规格", "生成数量") in sectioned(app),
       "★★ 侧栏出现「附属单位规格」编辑器（生成数量）")

    # ---- 4) 配规格：数量 4、两行权重 0.5 + 0.5 ----
    app._set_escort_count(gen, "4")
    eq(int(gen.escort_count), 4, "★★ 生成数量写进去了")
    app._set_escort_weight(gen, 0, "0.5")
    app._add_escort_row(gen)
    app._set_escort_weight(gen, 1, "0.5")
    eq(len(gen.escort_types), 2, "加了一行 → 两行权重")
    ok(abs(gen.spec_weight_sum() - 1.0) < 1e-9, "★★ 权重和 = 1")

    # ---- 5) 导出：将领带 escort_count / escort_types ----
    out = level(app).to_dict()["start_units"][0]
    eq(out.get("escort_count"), 4, "★★ 导出带 escort_count")
    eq(len(out.get("escort_types", [])), 2, "★★ 导出带 escort_types")

    # ---- 6) 校验：权重和 ≠1 → escort_weights_sum ----
    app._set_escort_weight(gen, 1, "0.9")
    codes = [i.code for i in app.run_checks()]
    ok("escort_weights_sum" in codes,
       "★★ 权重和 ≠1 被拦（escort_weights_sum），实际：%s" % codes)
    app._set_escort_weight(gen, 1, "0.5")

    # ---- 7) 校验：数量 > 编制上限 → escort_count_over_cap ----
    cap = app.config.general_cap(1)
    app._set_escort_count(gen, str(cap + 1))
    codes = [i.code for i in app.run_checks()]
    ok("escort_count_over_cap" in codes,
       "★★ 数量超过编制上限被拦（escort_count_over_cap），实际：%s" % codes)
    app._set_escort_count(gen, "4")

    # ---- 8) 新页：区划 / 红点都能进，红点页复用画布 ----
    app.set_page("zone")
    app.root.update()
    ok(app.page == "zone", "区划页能进")
    app.set_page("reddot")
    app.root.update()
    ok(hasattr(app, "canvas") and app.canvas.winfo_exists(), "★ 红点页复用了画布")

def faction_section_frame(app, fid: str):
    """按标题取「某方那一节」的 Frame 本体（`faction_section` 只给标题）。"""
    for section in app.sidebar.winfo_children():
        title = getattr(section, "section_title", None)
        if title and (title == fid or title.startswith(fid + " ")):
            return section
    raise AssertionError("阵营页里没有「%s」那一节" % fid)


# ======================================================================
# [5] 导出：有拦截项时禁止写文件
# ======================================================================

def t_export_blocked(app, model) -> None:
    print("\n[5] 导出：有拦截项时禁止写文件并弹框说清楚")
    calls = []
    real_error = app_module.messagebox.showerror

    def fake_error(title, message, **kw):
        calls.append((title, message))

    app_module.messagebox.showerror = fake_error
    try:
        # 造一个必然被拦的错误：把目标区划改成一个不存在的。
        # ★ 先把**原来**的目标存下来 —— 一会儿要拿它复原。直接把 `_facts()["obj_zone"]`
        #   读回来是不行的：它读的就是**刚被改坏**的那一份（实测踩到：复原没生效，
        #   第二次 do_save() 又弹了个**真**对话框，测试直接挂在那里等点击）。
        lv = level(app)
        original = [dict(o) for o in lv.objectives]
        lv.objectives = [{"kind": M.OBJ_HOLD_ZONE, "zone": 99, "hold_sec": 60}]
        app.refresh_all()
        app.set_page("check")
        app.root.update()
        issues = app.run_checks()
        ok(M.has_blocker(issues), "（前提）现在有拦截项")
        ok(any(i.code == "objective_zone_missing" for i in issues), "拦截清单里有那一条 code")
        eq(app.issue_tree.item("issue:0", "values")[0], "拦截", "列表第一列写的是「拦截」")

        camp = app.model.dir_path / "campaign.json"
        before = camp.read_bytes() if camp.exists() else None
        app.do_save()
        app.root.update()
        ok(calls, "★★ 有拦截项 → 弹了对话框，没有静默写文件")
        ok("拦截" in calls[0][1], "★★ 对话框里说清了原因：%s" % calls[0][1].splitlines()[0])
        after = camp.read_bytes() if camp.exists() else None
        ok(after == before, "★★ 磁盘上的文件一个字节都没变")
        ok(not app.last_written, "★ 没有记录任何「写过的文件」")

        # ---- 修好之后能真写 ----
        lv.objectives = original or [{"kind": M.OBJ_HOLD_ZONE, "hold_sec": 60,
                                      "zone": _facts(app)["obj_zone"]}]
        app.refresh_all()
        app.root.update()
        issues = app.run_checks()
        if M.has_blocker(issues):
            print("  [skip] 临时副本上还有别的拦截项（%s），跳过「真写文件」那一条"
                  % "、".join(sorted({i.code for i in M.blockers(issues)})))
            return
        app.do_save()
        app.root.update()
        eq(len(calls), 1, "★★ 没有拦截项时**不再**弹错误框（还是只有第一次那一条）")
        ok(app.last_written, "★ 没有拦截项时会真写文件（%d 个）" % len(app.last_written))
        ok(all(Path(p).exists() for p in app.last_written), "写过的文件都在盘上")
        saved = levelfile.load_campaign(app.model.dir_path, TMP_PROJECT)
        eq(saved.levels[0].objective_hold_sec(),
           float(original[0]["hold_sec"]) if original else 60.0,
           "★ 写出去的那一份能读回来，值还是原来那个")
    finally:
        app_module.messagebox.showerror = real_error


# ======================================================================
# [6] 一键打开地图编辑器（假 subprocess）
# ======================================================================

def t_open_map_editor(app, model) -> None:
    print("\n[6] 一键打开地图编辑器（假 subprocess，不真起地图编辑器）")
    FakePopen.calls = []
    app.set_page("check")
    app.root.update()
    app.open_map_editor()
    app.root.update()
    eq(len(FakePopen.calls), 1, "★ 真的调了一次 subprocess.Popen")
    cmd = FakePopen.calls[0]
    eq(cmd[1], str(app.map_editor_dir()), "命令里的编辑器目录 = tools/map_editor")
    eq(cmd[2], "--map", "★ 传了 --map 参数")
    eq(cmd[3], level(app).map_id, "★ 传的地图 id = 当前关的地图")
    ok("--campaign-map" in cmd,
       "★ 带上 --campaign-map —— 地图导出会自动写 hidden: true（不进自由对战选择条）")
    ok(cmd[0].lower().endswith(("python.exe", "pythonw.exe", "python3.exe")) or "python" in
       Path(cmd[0]).name.lower(), "第一个参数是当前解释器：%s" % cmd[0])
    ok(("--map" in app.status_var.get()) or ("地图编辑器" in app.status_var.get()),
       "状态栏说了要打开地图编辑器：%s" % app.status_var.get())

    # 摆放页那颗按钮走的是同一条路（它在画布上方那一条里，不在 action_bar）
    app.set_page("place")
    app.root.update()
    btns = head_buttons(app)
    ok("打开地图编辑器" in btns, "摆放页画布上方有「打开地图编辑器」按钮")
    if "打开地图编辑器" in btns:
        btns["打开地图编辑器"].invoke()
        app.root.update()
        eq(len(FakePopen.calls), 2, "★ 摆放页的按钮也走同一条路")


# ======================================================================
# [7] 侧边栏：装得下就不许滚
# ======================================================================

def t_sidebar_scroll(app, model) -> None:
    """★★ 这一节钉的是一个**实测复现过的 Tk 行为**（Tk 9.0）：

        内容 713px / 视口 930px（明明装得下）：
            canvas.yview("scroll", -5, "units")  →  canvasy(0) = **-217**
        也就是内容被整个推下去、面板上方空出一大块，而 `yview()` 这时仍报 (0.0, 1.0)
        —— 只看 yview 是发现不了的，所以断言一律读 `canvasy(0)`。

    修法：把滚动收敛到唯一的入口 `app.sidebar_yview()` 上（滚动条 / 滚轮 / 拖动都走它），
    装得下就钉回顶部、装不下就把偏移夹进 [0, 溢出]。
    """
    print("\n[7] 侧边栏：装得下就不许滚")
    app.root.deiconify()                     # withdraw 时 geometry() / 画布尺寸不生效
    cv = app.sidebar_canvas

    def offset() -> float:
        return cv.canvasy(0.0)

    def grow_until_fits(label: str) -> bool:
        need = app.sidebar.winfo_reqheight()
        for h in (1000, 1100, 1200, 1300, 1400, 1500, 1600, 1800, 2000):
            app.root.geometry("1340x%d" % h)
            app.root.update()
            if cv.winfo_height() >= need + 20:
                break
        if app.sidebar_overflow() != 0:
            print("  [skip] %s 的内容 %dpx 装不进面板 %dpx（这台机器的窗口高度不够）"
                  % (label, need, cv.winfo_height()))
            return False
        eq(app.sidebar_overflow(), 0,
           "（前提）%s 的内容（%dpx）装得进面板（%dpx）" % (label, need, cv.winfo_height()))
        return True

    # ---- A. 战役页那张短表单：装得下 → 一律钉在顶部 ----
    app.set_page("campaign")
    app.root.update()
    if grow_until_fits("战役页"):
        eq(offset(), 0.0, "战役页：刚切过来在顶部")
        app.sidebar_yview("scroll", 5, "units")
        eq(offset(), 0.0, "★★ 装得下时向下滚 → 一动不动")
        app.sidebar_yview("scroll", -5, "units")
        eq(offset(), 0.0, "★★ 装得下时向上滚 → 一动不动（**用户报的那个 bug**）")
        app.sidebar_yview("moveto", 0.9)
        eq(offset(), 0.0, "★★ 拖滚动条也不动")
        app.sidebar_yview("moveto", 0.0)
        eq(tuple(app.sidebar_scroll.get()), (0.0, 1.0),
           "★ 滚动条滑块铺满滑槽（看着就是不可滚）")
        app._on_wheel(FakeEvent(cv, delta=-120))
        eq(offset(), 0.0, "滚轮向下也不动")
        app._on_wheel(FakeEvent(cv, delta=120))
        eq(offset(), 0.0, "滚轮向上也不动")

    # ---- B. 阵营页那张长表单：装不下 → 能滚，但滚不出范围 ----
    app.set_page("factions")
    app.root.update()
    app.root.geometry("1340x700")             # 压矮窗口，制造「装不下」
    app.root.update()
    ok(app.sidebar_overflow() > 0,
       "★ 阵营页的内容（%dpx）在矮窗口里装不下（溢出 %d px）"
       % (app.sidebar.winfo_reqheight(), app.sidebar_overflow()))
    app.sidebar_yview("scroll", 3, "units")
    ok(offset() > 0.0, "★ 装不下时向下滚**能动**（偏移 %.0f）" % offset())
    # ★★ 「滚过头」必须**真的一路滚过头**：`units` 的步长 = 视口 / 10，
    #   所以固定写 50 在一张很长的表单上**根本滚不到底**（那样这条断言就白测了）。
    #   用一个远大于任何内容的高度（100000 units）——它必然越过两端、只剩夹值在起作用。
    app.sidebar_yview("scroll", 100000, "units")  # 滚过头
    ok(offset() <= float(app.sidebar_overflow()) + 1.0,
       "★★ 滚过头被夹在「内容底部」（偏移 %.0f ≤ 溢出 %d）"
       % (offset(), app.sidebar_overflow()))
    app.sidebar_yview("scroll", -100000, "units")  # 往回滚过头
    eq(offset(), 0.0, "★★ 往回滚过头夹在顶部（偏移不为负 = 上方不留空白）")

    # ---- C. 把画布内容强行拉长，再造一次溢出（不依赖窗口大小）----
    app.sidebar_canvas.itemconfigure(app._sidebar_item, height=3000)
    app.sidebar.update_idletasks()
    app.root.update()
    ok(app.sidebar_overflow() > 0, "（前提）内容被拉长到 3000px，确实装不下")
    app.sidebar_yview("scroll", -50, "units")
    eq(offset(), 0.0, "★★ 长内容往回滚过头也夹在顶部")
    app.sidebar_yview("scroll", 500, "units")
    ok(offset() <= float(app.sidebar_overflow()) + 1.0,
       "★★ 长内容一路滚到底（偏移 %.0f ≤ 溢出 %d）" % (offset(), app.sidebar_overflow()))
    app.sidebar_canvas.itemconfigure(app._sidebar_item, height=0)   # 0 = 交还给布局
    app.sidebar.update_idletasks()
    app.root.update()

    # ---- D. 拉高窗口 → 偏移当场被夹回顶部 ----
    app.sidebar_yview("scroll", 3, "units")
    for h in (1000, 1100, 1200, 1300, 1400, 1500, 1600, 1800, 2000):
        app.root.geometry("1340x%d" % h)
        app.root.update()
        if app.sidebar_overflow() == 0:
            break
    if app.sidebar_overflow() == 0:
        eq(offset(), 0.0, "★★ 拉高窗口之后偏移自动回到顶部")
    else:
        print("  [skip] 这台机器的窗口高度不够，装不下阵营页那一张表单（溢出 %d px）"
              % app.sidebar_overflow())
    app.root.withdraw()                       # 收工，别把窗口留在屏幕上


# ======================================================================
# [8] 其它：新建 / 删除关卡、页签跳转、重新载入
# ======================================================================

def t_misc(app, model) -> None:
    print("\n[8] 其它：增删关卡 / 一键跳转 / 重新载入")
    app.set_page("campaign")
    app.root.update()
    n = len(app.model.levels)
    app_module._ask_new_level = lambda root, maps_, default: ("99_test", default)
    app.do_new_level()
    app.root.update()
    eq(len(app.model.levels), n + 1, "★ 新建了一关")
    eq(app.current_level_id, "99_test", "新建之后跳到它")
    ok(app.level_tree.exists("lv:99_test"), "列表里出现了它")

    app_module.messagebox.askyesno = lambda *a, **k: True
    app.do_delete_level()
    app.root.update()
    eq(len(app.model.levels), n, "★ 删掉了那一关")
    ok(not app.level_tree.exists("lv:99_test"), "列表里也没了")

    # 上下箭头排顺序
    ids = [lv.level_id for lv in app.model.levels]
    if len(ids) >= 2:
        app.current_level_id = ids[1]
        app.move_level(-1)
        app.root.update()
        eq([lv.level_id for lv in app.model.levels][0], ids[1], "★ 上移改了顺序")
        app.move_level(1)
        app.root.update()
        eq([lv.level_id for lv in app.model.levels], ids, "★ 下移改回来")

    # 重新载入 = 丢掉内存里的改动
    lv = level(app)
    lv.name = "改过的名字"
    app.refresh_all()
    app.do_reload()
    app.root.update()
    ok(level(app).name != "改过的名字", "★ 重新载入丢掉了未保存的改动")

    # One-shot probe: 新加的两条失败条件校验在**真样例数据**上也说得通
    print("\n[9] 新加的两条失败条件校验（真样例数据）")
    issues = M.validate_campaign(app.model, app.maps)
    ok(not M.has_blocker(issues),
       "★★ 样例战役（含第二关的 zone_lost 额外条件）现在 0 条拦截%s"
       % ("" if not M.has_blocker(issues)
          else "：%s" % "、".join(i.code for i in M.blockers(issues))))
    ok(not any(i.code in ("fail_zone_unowned", "fail_zone_not_players") for i in issues),
       "★★ 那两条**没有**误伤样例数据（它把失败条件那一区划给了玩家）")


def t_faction_list_per_level(app, model) -> None:
    print("\n[4e] ★★ 阵营表跟着关卡走（A 关的阵营不会出现在 B 关）")
    if len(model.levels) < 2:
        ok(False, "（前提）样例战役至少两关")
        return
    lv1 = level(app)
    lv2 = next((x for x in model.levels if x is not lv1), None)
    if lv2 is None:
        ok(False, "（前提）找得到另一关")
        return
    added = "scope_probe"

    # ---- 在 A 关加一方：只出现在 A 关 ----
    app._add_level_faction(added)
    ok(lv1.faction(added) is not None, "★ 加的一方进了当前关的 factions[]")
    ok(lv2.faction(added) is None, "★★ 另一关**看不到**它（不污染）")
    ok(added in app.all_faction_ids(), "★ 当前关的界面列表里有它")

    # ---- 切到 B 关：界面列表里没有它 ----
    app.set_current_level(lv2.level_id)
    ok(added not in app.all_faction_ids(), "★★ 切到另一关后，界面列表里没有它")
    ok(not any(e.fid == added for e in level(app).factions), "★ 另一关的阵营表里也没有它")

    # ---- 切回 A 关：它还在 ----
    app.set_current_level(lv1.level_id)
    ok(added in app.all_faction_ids(), "★ 切回来它还在（只属于这一关）")

    # ---- 可玩标记同样是本关的（席位只在本关派生）----
    app.set_faction_field(added, "playable", True)
    ok(added in lv1.playable_ids(), "★★ 当前关把它标成可玩")
    ok(added in lv1.seats(), "★ 当前关的席位由它派生")
    ok(added not in lv2.playable_ids(), "★★ 另一关的可玩列表里没有它")
    ok(added not in lv2.seats(), "★★ 另一关的席位也没有被改")
    ok(not model.to_dict().get("factions"),
       "★★ campaign.json 里始终没有阵营表（阵营表只存关卡）")

    # ---- 复原 ----
    app.set_faction_field(added, "playable", False)
    lv1.remove_faction(added)
    app._sides = None
    app.refresh_all()
    app.root.update()


def t_level_switch_state(app, model) -> None:
    print("\n[4f] ★★ 换关卡不串编辑期状态（用户报的「上一关的边跑到这一关」）")
    if len(model.levels) < 2:
        ok(False, "（前提）样例战役至少两关")
        return
    lv1, lv2 = model.levels[0], model.levels[1]
    ids1 = lv1.present_ids()
    if len(ids1) < 2:
        ok(False, "（前提）第一关至少有两个阵营")
        return

    # ---- 造两组**明显不同**的边：第一关有边，第二关一条都没有 ----
    orig = [(lv1, [list(p) for p in lv1.allies], lv1.allies_declared),
            (lv2, [list(p) for p in lv2.allies], lv2.allies_declared)]
    lv1.allies_declared = True
    lv1.allies = [[ids1[0], ids1[1]]]
    lv2.allies_declared = True
    lv2.allies = []

    def click_level(lid: str) -> bool:
        app.set_page("campaign")
        app.root.update()
        if not app.level_tree.exists("lv:%s" % lid):
            return False
        app.level_tree.selection_set("lv:%s" % lid)
        app._on_campaign_select()
        app.root.update()
        return True

    # ---- 第一关：缓存里是它的边 ----
    # ★ 用 set_current_level 重新从数据里读一次（之前用例可能已经把 _sides 缓存成旧值）
    app.set_current_level(lv1.level_id)
    app.set_page("factions")
    app.root.update()
    eq(app._level_sides(), [[ids1[0], ids1[1]]], "（前提）第一关的边读进来了")

    # ---- 在「上一关」上留下各种编辑期状态 ----
    only1 = [f for f in ids1 if f not in lv2.present_ids()]
    app.selection = ("unit", 0)
    app.reddot_faction = "red1"
    app.brush_faction = only1[-1] if only1 else ""   # 一个只在第一关存在的阵营（如 GD1）
    stale_pair = [list(p) for p in app._level_sides()]

    # ---- 切到第二关：这些都不许跟过来 ----
    ok(click_level(lv2.level_id), "（前提）能点中第二关")
    app.set_page("factions")
    app.root.update()
    eq(app.current_level_id, lv2.level_id, "★ 当前关切到了第二关")
    eq(app._level_sides(), [], "★★ 上一关的边**没有**跟过来（不再是 dscj 那种串数据）")
    ok(app._level_sides() != stale_pair, "★★ 与上一关的边缓存确实不同")
    ok(app.selection is None, "★ 摆放页的选中下标被清掉（它指向上一关的单位）")
    eq(app.reddot_faction, "", "★ 红点页「当前编辑哪一方」被清掉")
    if only1:
        eq(app.brush_faction, "", "★ 画笔归属被清掉（第二关根本没有上一关那个阵营）")

    # ---- 复原（别把样例的边改坏）----
    for lv, pairs, declared in orig:
        lv.allies = pairs
        lv.allies_declared = declared
    app.brush_faction = ""
    app.reddot_faction = ""
    app.set_current_level(lv1.level_id)
    app.refresh_all()
    app.root.update()


def t_zone_owner_explicit(app, model) -> None:
    print("\n[4g] ★★ 区划归属：没有「（用地图的）」，每一块地显式")
    lv = level(app)
    info = app.map_info()
    if lv is None or info is None:
        ok(False, "（前提）当前关有地图")
        return
    orig_zones = dict(lv.zone_owners)
    orig_map = lv.map_id

    # ---- 数据：载入后每一块地都有显式归属 ----
    eq(set(lv.zone_owners), set(info.zone_ids),
       "★★ 每一块地都在 zones[] 里（没有「用地图的」）")
    ok(all(v in set(app.all_faction_ids()) | {""} for v in lv.zone_owners.values()),
       "★ 每个值都是当前关的阵营 id 或空串（无主）")
    # 旧数据缺的那一条 → 载入迁移会补成地图 owner（这里手动模拟「缺一条」）
    missing_zid = info.zone_ids[0]
    saved_value = lv.zone_owners.pop(missing_zid)
    lv.ensure_zone_owners(info)
    eq(lv.zone_owners.get(missing_zid), str(info.zone_owners.get(missing_zid, "")),
       "★★ 缺的区划补成地图 owner（无主 = 空串）")
    lv.zone_owners[missing_zid] = saved_value

    # ---- 界面：下拉里没有「（用地图的）」；最后一项是「清空 = 无主」----
    app.set_page("zone")
    app.root.update()
    combos = [w for w in walk(app.work) if isinstance(w, ttk.Combobox)]
    ok(bool(combos), "★ 区划页有归属下拉")
    if combos:
        values = list(combos[0].cget("values"))
        ok("（用地图的）" not in values, "★★ 下拉里**没有**「（用地图的）」")
        ok("（清空 = 无主）" in values, "★ 有「（清空 = 无主）」")
        eq(values[-1], "（清空 = 无主）", "★ 「无主」是最后一项")
        eq(set(values[:-1]), set(app.all_faction_ids()),
           "★ 其余选项 = 当前关的阵营表（不多不少）")

    # ---- 选「无主」= 写空串；选阵营 = 写 id ----
    zid = info.zone_ids[0]
    app._set_zone_choice(zid, "（清空 = 无主）")
    eq(lv.zone_owners.get(zid), "", "★★ 选「无主」→ 显式空串（不是删掉这个键）")
    fid = app.all_faction_ids()[0]
    app._set_zone_choice(zid, fid)
    eq(lv.zone_owners.get(zid), fid, "★ 选阵营 → 写它的 id")

    # ---- 换地图：区划表按新地图整张重建 ----
    other = next((m for m in sorted(app.maps) if m != orig_map), None)
    if other is not None:
        app._set_level_map(app._map_label(other))
        info2 = app.map_info()
        ok(info2 is not None, "（前提）新地图读得出来")
        if info2 is not None:
            eq(set(lv.zone_owners), set(info2.zone_ids),
               "★★ 换地图后区划表按新地图重建（没有残留旧地图的区划号）")
            for z in info2.zone_ids:
                eq(lv.zone_owners[z], str(info2.zone_owners.get(z, "")),
                   "★ 新地图 c%d 的初值 = 它的 owner" % z)
        app._set_level_map(app._map_label(orig_map))

    # ---- 复原 ----
    lv.zone_owners = orig_zones
    app.refresh_all()
    app.root.update()


def t_refresh_keeps_view(app, model) -> None:
    """★★ 改数值 / 摆将领不能把缩放、平移、侧边栏滚动打回初始位置。

    用户报的「所有 UI 回到初始位置」：战役编辑器以前每次 refresh_all 都重建画布
    并强制 fit_view()，还把长侧边栏滚回顶部。这里钉住「重建 = 数据更新，不是复位」。
    """
    print("\n[4c] ★★ 刷新只更新数据：缩放 / 平移 / 侧边栏滚动都留在原地")
    f = _facts(app)
    app.set_page("place")
    app.root.update()
    app.zoom = 1.75
    app.ox = 137.0
    app.oy = -52.0
    app._fit_pending = False
    app.brush_kind = "general"
    app.brush_faction = f["player"]
    before_view = (app.zoom, app.ox, app.oy)
    app.place_at((f["player_base"][0] + 1, f["player_base"][1]))
    app.root.update()
    eq((app.zoom, app.ox, app.oy), before_view,
       "★★ 摆一位将领不会重置画布缩放 / 平移")

    # 侧边栏：用内容更长的阵营页，把滚动条滚到中间再改一个字段
    app.set_page("factions")
    app.root.update()
    try:
        app.sidebar_canvas.configure(height=240)
        app.root.update()
    except tk.TclError:
        pass
    if app.sidebar_overflow() <= 0:
        ok(True, "（这台机器上阵营页装得下，跳过侧边栏滚动断言）")
        return
    app.sidebar_yview("moveto", 0.5)
    app.root.update()
    before_scroll = app.sidebar_canvas.canvasy(0.0)
    ok(before_scroll > 0, "（前提）先把阵营页滚下去（偏移 %d）" % before_scroll)
    app.set_faction_field(app.all_faction_ids()[0], "name", "测试阵营")
    app.root.update()
    eq(app.sidebar_canvas.canvasy(0.0), before_scroll,
       "★★ 改一个字段不会把侧边栏滚回顶部")


def t_catalog_filter() -> None:
    """有用表过滤：关卡树只显示有用表地图对应的关卡。"""
    print("\n[10] 有用表过滤关卡树")
    model = levelfile.load_campaign(TMP_PROJECT / "data" / "campaigns" / CASE, TMP_PROJECT)
    root = tk.Tk()
    root.withdraw()
    app = app_module.EditorApp(root, model, TMP_PROJECT, show_all_levels=False)
    try:
        root.update()
        ids = [str(app.level_tree.item(iid, "values")[1])
               for iid in app.level_tree.get_children()]
        eq(ids, ["mt", "dscj", "ai_test_2", "ai_test_battle"],
           "★ 关卡树只列有用表地图对应的关卡")
        ok(not app.level_tree.exists("lv:01_beachhead"), "★ 隐藏 01_beachhead")
        ok(not app.level_tree.exists("lv:02_twin_line"), "★ 隐藏 02_twin_line")
        ok(not app.level_tree.exists("lv:ai_test"), "★ 隐藏 ai_test")
        eq(app.current_level_id, "mt", "★ 默认当前关 = 第一个可见关卡")
        eq(app._map_choice_ids(), ["main_test", "ai_test_2", "dscj"],
           "★ 地图下拉 = 有用表三张")
    finally:
        root.destroy()


def main() -> int:
    print("DAEEM 战役编辑器 · 界面测试")
    print("工程目录：%s（测试只动 %s 里的副本）" % (PROJECT_DIR, TMP))
    # ★★ 兜底：这一套测试**只许动临时副本**，真 data/ 必须一字未改。
    #    ⚠️ 快照用 **hash** 而不是字节本身：断言失败时把几 KB 的 JSON 打进日志，
    #       真正有用的那一行（哪个文件变了）会被埋掉（实测踩到）。
    real_camp = PROJECT_DIR / "data" / "campaigns"
    real_maps = PROJECT_DIR / "data" / "maps"
    real_cfg = (PROJECT_DIR / "data" / "config.json").read_bytes()

    def tree_digest(root: Path) -> dict:
        out = {}
        for p in sorted(root.rglob("*")):
            if p.is_file():
                out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
        return out

    before_camp, before_maps = tree_digest(real_camp), tree_digest(real_maps)
    try:
        app, model = setup()
    except tk.TclError as exc:                          # pragma: no cover
        print("  [skip] 这台机器起不了 Tk 窗口：%s" % exc)
        shutil.rmtree(TMP, ignore_errors=True)
        print("\n[CASE] test_app -> passed 0 / failed 0 (skipped)")
        return 0
    try:
        t_window(app, model)
        t_canvas(app, model)
        t_space_drag_pan(app, model)
        t_reddot_march_tiles(app, model)
        t_same_field(app, model)
        t_ally_sides(app, model)
        t_new_reddot_faction(app, model)
        t_faction_list_per_level(app, model)
        t_level_switch_state(app, model)
        t_zone_owner_explicit(app, model)
        t_escort_placement(app, model)
        t_refresh_keeps_view(app, model)
        t_export_blocked(app, model)
        t_open_map_editor(app, model)
        t_sidebar_scroll(app, model)
        t_misc(app, model)
        t_catalog_filter()
    finally:
        teardown(app)
        after_camp, after_maps = tree_digest(real_camp), tree_digest(real_maps)
        ok(after_camp == before_camp,
           "★★ 真 data/campaigns/ 逐字节未改（测试只动 .tmp_campaign_editor_app_test）%s"
           % _changed(before_camp, after_camp))
        ok(after_maps == before_maps,
           "★★ 真 data/maps/ 也一字未改%s" % _changed(before_maps, after_maps))
        ok((PROJECT_DIR / "data" / "config.json").read_bytes() == real_cfg,
           "★★ 真 data/config.json 一字未改")
        shutil.rmtree(TMP, ignore_errors=True)

    print("\n[CASE] test_app -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


def _changed(before: dict, after: dict) -> str:
    """快照差异的**文件名**（不打印内容 —— 那会把日志埋掉）。"""
    keys = sorted(set(before) | set(after))
    diff = [k for k in keys if before.get(k) != after.get(k)]
    return "（变了的文件：%s）" % "、".join(diff) if diff else ""


if __name__ == "__main__":
    raise SystemExit(main())
