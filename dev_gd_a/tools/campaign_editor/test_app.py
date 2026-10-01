"""test_app.py —— 战役编辑器**界面**的无头测试（建真窗口，但不显示、不截图）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/campaign_editor/test_app.py

做法（与 `unit_editor/test_app.py` 同一套）：真的 `Tk()` + `EditorApp`，改的是
**临时目录里的一份战役副本**（真 `data/campaigns/**` 一字不动），然后把真的控件抓出来、
灌值、发事件，断言「这一下之后数据层变成了什么样」。

覆盖（对应 dev_plan_7 6.5 那一行）：

    [1] 页签切换（五个页签 + 当前页签高亮 + 换页清选中）
    [2] 画布：放置 / 选中 / 删除（大本营不许在这里删）/ 缩放（以光标为锚点）/ 适应视图
    [3] 「设进攻目标」模式：点区划 → zone / 点空格 → point / Esc 退出
    [4] ★ ③ 与 ④ 改的是**同一个字段**（最容易写成不一致的地方）
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
    """假事件（界面代码只读 x / y / delta / widget 这几样）。"""

    def __init__(self, widget=None, x: int = 0, y: int = 0, delta: int = 0) -> None:
        self.widget = widget
        self.x = x
        self.y = y
        self.delta = delta


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


def setup() -> tuple:
    """开一个真窗口 + 一份临时战役副本。"""
    shutil.rmtree(TMP, ignore_errors=True)
    TMP_PROJECT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(PROJECT_DIR / "data" / "maps", TMP_PROJECT / "data" / "maps")
    shutil.copyfile(PROJECT_DIR / "data" / "config.json", TMP_PROJECT / "data" / "config.json")
    shutil.copytree(PROJECT_DIR / "data" / "campaigns" / "demo",
                    TMP_PROJECT / "data" / "campaigns" / CASE)
    model = levelfile.load_campaign(TMP_PROJECT / "data" / "campaigns" / CASE, TMP_PROJECT)
    root = tk.Tk()
    root.withdraw()                        # 不显示（无头也能跑）
    app = app_module.EditorApp(root, model, TMP_PROJECT)
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
    eq(list(app.tab_buttons.keys()), ["campaign", "level", "factions", "place", "check"],
       "五个页签")
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
    ok("玩家席位" in [getattr(s, "section_title", "") for s in app.sidebar.winfo_children()],
       "阵营页有「玩家席位」那一栏")

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
    type_into(app, row(app, "选中的单位", "zone"), "3")
    eq(level(app).start_units[-1].zone, 3, "右栏改 zone")
    ai_combo = row(app, "选中的单位", "combo:ai")
    pick_combo(app, ai_combo, "将领性")
    eq(level(app).start_units[-1].ai, M.AI_GENERAL, "右栏把 AI 改成将领性")
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

    # ★ 大本营不算「已有」：在摆放页上删不掉（它只在阵营页里改）
    base = f["player_base"]
    app.selection = None
    right_click_canvas(app, base)
    ok(any(e.fid == f["player"] or p.get("base") == base
           for e in level(app).factions for p in level(app).players),
       "★★ 大本营在摆放页上删不掉（右键点它什么都不发生）")

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
# [3] 「设进攻目标」模式
# ======================================================================

def t_target_mode(app, model) -> None:
    print("\n[3] 「设进攻目标」模式：点区划 / 点空格 / Esc 退出")
    f = _facts(app)
    lv = level(app)
    info = app.map_info()
    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()

    # 先清掉样例那一方的进攻目标，便于观察
    entry = lv.ensure_faction(f["player"])
    entry.ai = M.AI_FACTION
    entry.attack_target = None
    app.refresh_all()
    app.root.update()

    app.brush_faction = f["player"]
    app.do_target_mode()
    eq(app.target_mode_faction, f["player"], "进入目标模式并选中了画笔那一方")

    # 点一个**区划** → zone 目标
    zid = next(z for z in info.zone_ids if z != f["obj_zone"])
    cell = info.zone_centers[zid]
    click_canvas(app, cell)
    eq(level(app).faction(f["player"]).attack_target,
       {"kind": M.TARGET_ZONE, "zone": int(zid)}, "★ 点区划 → zone 目标")

    # 点**地图外**的空格 → point 目标（zone_of = -1 的那一格）
    free = None
    for y in range(info.rows):
        for x in range(info.cols):
            if info.zone_of(x, y) < 0 and info.tile_exists(x, y):
                free = (x, y)
                break
        if free:
            break
    if free is None:                        # 这张图每格都属于某个区划 → 用一个格外的坐标
        free = (info.cols + 1, info.rows + 1)
    click_canvas(app, free)
    got = level(app).faction(f["player"]).attack_target
    eq(got, {"kind": M.TARGET_POINT, "x": free[0], "y": free[1]},
       "★ 点空格 → point 目标")

    # Esc 退出
    app.on_escape()
    app.root.update()
    eq(app.target_mode_faction, None, "★ Esc 退出目标模式")
    # 退出之后再点画布 = 正常放置，不再改目标
    before = dict(level(app).faction(f["player"]).attack_target)
    app.selection = None
    app.brush_kind = "unit"
    app.brush_value = app.config.unit_types[-1] if app.config.unit_types else "enemy"
    app.root.update()
    app.place_at(f["spot"])
    eq(level(app).faction(f["player"]).attack_target, before, "★ 退出之后点画布不再改目标")


# ======================================================================
# [4] ★ ③ 与 ④ 改的是同一个字段
# ======================================================================

def t_same_field(app, model) -> None:
    print("\n[4] ★ ③（阵营页下拉）与 ④（画布点选）改的是同一个字段")
    f = _facts(app)
    lv = level(app)
    info = app.map_info()
    lv.ensure_faction(f["player"]).ai = M.AI_FACTION
    app.refresh_all()

    # ---- ③ 改：下拉选「指定区划」，再挑一个区划 ----
    app.set_page("factions")
    app.root.update()
    section = faction_section(app, f["player"])
    pick_combo(app, row(app, section, "combo:进攻目标"), "指定区划")
    target = level(app).faction(f["player"]).attack_target
    eq(target.get("kind"), M.TARGET_ZONE, "③ 下拉选「指定区划」→ 落了 zone 型目标")
    zid = next(z for z in info.zone_ids if z != int(target.get("zone", -1)))
    pick_combo(app, row(app, faction_section(app, f["player"]), "combo:　目标区划"),
               info.zone_label(zid))
    eq(level(app).faction(f["player"]).attack_target, {"kind": M.TARGET_ZONE, "zone": int(zid)},
       "③ 选好区划之后目标就是它")

    # ---- ④ 看：画布上画出来的箭头终点 = 那个区划的中心 ----
    app.set_page("place")
    app.root.update()
    app.fit_view()
    app.root.update()
    spec = level(app).faction(f["player"]).attack_target
    eq(app._target_point(level(app), app.map_info(), spec), info.zone_centers[int(zid)],
       "★ ④ 读到的目标点 = ③ 设的那个区划的中心（同一份数据）")

    # ---- ④ 改：画布点另一个区划 ----
    other = next(z for z in info.zone_ids if z != zid)
    app.target_mode_faction = f["player"]
    click_canvas(app, info.zone_centers[other])
    eq(level(app).faction(f["player"]).attack_target,
       {"kind": M.TARGET_ZONE, "zone": int(other)}, "④ 点画布改掉了目标")

    # ---- ③ 再看：下拉显示的就是 ④ 刚设的那个 ----
    app.set_page("factions")
    app.root.update()
    detail = sectioned(app).get((faction_section(app, f["player"]), "combo:　目标区划"))
    ok(detail is not None, "③ 那一栏还有「目标区划」下拉（因为 kind 是 zone）")
    if detail is not None:
        eq(detail.get(), info.zone_label(other), "★★ ④ 改完之后 ③ 的下拉显示新值")
    eq(M.target_label(level(app).faction(f["player"]).attack_target),
       "指定区划 %s" % M.zone_label(other),
       "★ 目标的一行人话也跟着变（`target_label` 不查地图，所以只用 c<id> 记法）")


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
    app.sidebar_yview("scroll", 50, "units")  # 滚过头
    ok(offset() <= float(app.sidebar_overflow()) + 1.0,
       "★★ 滚过头被夹在「内容底部」（偏移 %.0f ≤ 溢出 %d）"
       % (offset(), app.sidebar_overflow()))
    app.sidebar_yview("scroll", -50, "units")  # 往回滚过头
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
        t_target_mode(app, model)
        t_same_field(app, model)
        t_export_blocked(app, model)
        t_open_map_editor(app, model)
        t_sidebar_scroll(app, model)
        t_misc(app, model)
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
