"""test_app.py —— 界面动作的无头测试（建真窗口，但不显示、不截图）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/unit_editor/test_app.py

做法：真的 new 一个 Tk 窗口 + EditorApp（改的是工程目录里的一份**临时副本**，
绝不动 `data/config.json`），然后把**真的控件**抓出来、灌值、发事件，
断言「这一下之后数据层变成了什么样」。也就是需求那几条的自动化版：

    1. 点左边一行 → 右边出现它的数值；改一个数 → 写进正确的 JSON 键
    2. 打错字（`abc`）→ 原值不动 + 状态栏说清楚；负数被夹到最小值
    3. 下拉 / 勾选框（归属、可攻击、远程）→ 写进正确的键
    4. 将领：数值旁那个「自定 / 跟随」按钮 = 写覆盖 / 删覆盖
    5. 建筑：升级表每一级的价格 / 时间 / 血量倍率 / 逐级攻击都能改
    6. 科技页已移除（2026.11：科技只在 tools/buff_editor 里编辑，本工具碰不到 tech.*）
    7. 撤销 / 重做 / 保存 / 重新载入
    8. 新建 / 删除兵种与建筑（对话框与确认框被换成「直接给答案」）

⚠️ 界面文案 / 像素级外观不在这里断言（那要靠人看，见 README.md）。
"""

from __future__ import annotations

import json
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

from unit_editor import app as app_module                       # noqa: E402
from unit_editor.model import ConfigModel                       # noqa: E402

CONFIG = PROJECT_DIR / "data" / "config.json"
TMP = PROJECT_DIR / ".tmp_unit_editor_app_test"


def bcols() -> dict:
    """建筑列表的「列名 → 下标」（不写死下标：本轮给建筑加了一列「视野」）。"""
    return {key: i for i, (key, _header, _w) in enumerate(app_module.BUILDING_TREE_COLUMNS)}

_FAILED = 0
_PASSED = 0
_SKIPPED = False


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
    """假事件（只带一个 widget / 一个 delta —— 界面代码只用这两样）。"""

    def __init__(self, widget, delta: int = 0) -> None:
        self.widget = widget
        self.delta = delta


# ======================================================================
# 控件抓取小工具
# ======================================================================

def walk(widget):
    """深度遍历一棵控件树。"""
    yield widget
    for child in widget.winfo_children():
        yield from walk(child)


def sidebar_entries(app) -> dict:
    """侧边栏里「标签 → 输入框」的映射（表单是「一行一个 Label + 一个 Entry」的样式）。

    ⚠️ 每次提交都会重建整条侧边栏 —— 所以**每次用之前都要重新抓一遍**
       （抓着旧控件不放会撞 `invalid command name`）。
    """
    out = {}
    for frame in walk(app.sidebar):
        if not isinstance(frame, tk.Frame):
            continue
        kids = frame.winfo_children()
        if len(kids) >= 2 and isinstance(kids[0], tk.Label):
            label = kids[0].cget("text")
            entry = next((k for k in kids if isinstance(k, ttk.Entry)), None)
            if entry is not None:
                out.setdefault(label, entry)
    return out


def sidebar_labels(app) -> list:
    """侧边栏里**所有 Label 的文字**（用来断言「某句话在不在」——不碰输入框）。

    ⚠️ 与 `sidebar_entries` 一样，每次用之前都要重新抓（每次提交都会重建侧边栏）。
    """
    return [w.cget("text") for w in walk(app.sidebar) if isinstance(w, tk.Label)]


def E(app, label):
    """按标签取输入框（每次重新抓，见 `sidebar_entries` 的说明）。"""
    entries = sidebar_entries(app)
    if label not in entries:
        raise AssertionError("侧边栏里没有「%s」这一行；现在是：%s"
                             % (label, "、".join(entries)))
    return entries[label]


def sectioned(app) -> dict:
    """「（节标题, 标签） → 输入框」。

    ★ 为什么需要它：建筑页里「血量倍率 / 需要的价格」在 1/2/3 级各出现一次，
      只按标签找会永远命中第一级那一行 —— 测试想改的是「升到 2 级」那一节的。
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
            if len(kids) >= 2 and isinstance(kids[0], tk.Label):
                entry = next((k for k in kids if isinstance(k, ttk.Entry)), None)
                if entry is not None:
                    out.setdefault((title, kids[0].cget("text")), entry)
    return out


def E_in(app, section: str, label: str):
    """按「节 + 标签」取输入框。"""
    rows = sectioned(app)
    if (section, label) not in rows:
        raise AssertionError("「%s」那一节里没有「%s」；现在是：%s"
                             % (section, label,
                                "、".join("%s/%s" % k for k in rows)))
    return rows[(section, label)]


def sidebar_checks(app) -> dict:
    out = {}
    for widget in walk(app.sidebar):
        if isinstance(widget, ttk.Checkbutton):
            out[widget.cget("text")] = widget
    return out


def sidebar_combos(app) -> dict:
    """「标签 → 下拉框」（下拉框所在那一行有 Label）。"""
    out = {}
    for frame in walk(app.sidebar):
        if not isinstance(frame, tk.Frame):
            continue
        combo = next((k for k in frame.winfo_children() if isinstance(k, ttk.Combobox)), None)
        label = next((k.cget("text") for k in frame.winfo_children()
                      if isinstance(k, tk.Label)), None)
        if combo is not None and label:
            out.setdefault(label, combo)
    return out


def buttons(app) -> dict:
    out = {}
    for widget in walk(app.sidebar):
        if isinstance(widget, tk.Button):
            out.setdefault(widget.cget("text"), widget)
    return out


def type_into(app, entry, text: str) -> None:
    """往输入框里灌值并提交（等价于设计师打字 + 按 Enter）。

    ★ 为什么不发真的键盘事件：tk 只把键事件投给**有 OS 焦点**的窗口
      （实测 off-screen / withdraw 的窗口都收不到），而无头测试不该去抢焦点。
      界面把 Return / FocusOut 绑的那个函数挂在 `entry.commit_action` 上
      （见 app.py `_entry_row`），这里调的**就是同一个函数**。
    """
    entry.delete(0, "end")
    entry.insert(0, text)
    action = getattr(entry, "commit_action", None)
    if action is not None:
        action()
    else:                                              # pragma: no cover - 兜底
        entry.event_generate("<Return>")
    app.root.update()


def pick(app, iid: str) -> None:
    """在左边列表里点一行（真的选中 + 触发回调）。"""
    tree = None
    for candidate in (getattr(app, "unit_tree", None), getattr(app, "general_tree", None),
                      getattr(app, "trait_tree", None),
                      getattr(app, "package_tree", None),
                      getattr(app, "building_tree", None)):
        if candidate is None:
            continue
        try:
            if candidate.exists(iid):
                tree = candidate
                break
        except tk.TclError:
            continue
    assert tree is not None, "列表里没有这一行：%s（当前页签 %s）" % (iid, app.page)
    tree.selection_set(iid)
    app._on_list_select(FakeEvent(tree))
    app.root.update()


def data(model: ConfigModel):
    return json.loads(model.text)


def setup() -> tuple:
    """开一个真窗口 + 一份临时配置。"""
    shutil.rmtree(TMP, ignore_errors=True)
    TMP.mkdir(parents=True, exist_ok=True)
    path = TMP / "config.json"
    shutil.copyfile(CONFIG, path)
    model = ConfigModel.load(path)
    root = tk.Tk()
    root.withdraw()                       # 不显示（无头也能跑）
    app = app_module.EditorApp(root, model, path, PROJECT_DIR)
    root.update()
    return app, model, path


def teardown(app) -> None:
    try:
        app.root.destroy()
    except tk.TclError:
        pass


# ======================================================================
# [1] 窗口 / 页签 / 列表
# ======================================================================

def t_window(app, model) -> None:
    print("\n[1] 窗口 / 页签 / 列表")
    eq(app.page, "unit", "默认停在「单位」页")
    eq(list(app.tab_buttons.keys()), ["unit", "building"],
       "★★ 两个页签：单位 / 建筑（2026.11：科技页已移除）")
    eq(app.tab_buttons["unit"].cget("fg"), app_module.UI["accent"], "当前页签是强调色")
    eq(app.tab_buttons["building"].cget("fg"), app_module.UI["text_dim"], "其它页签是暗色")

    unit_ids = list(app.unit_tree.get_children())
    ok(all("u:" + uid in unit_ids for uid in ("spearman", "longbowman", "rider")),
       "兵种列表里有三个内置兵种（★ 「测试敌人」已从编辑器移除）")
    eq(len(unit_ids), len(model.units()), "兵种列表覆盖 config 的全部兵种")
    eq(list(app.general_tree.get_children()),
       ["g:%d" % i for i in range(model.general_count())],
       "将领列表 = config 的全部将领档位（当前 %d 位）" % model.general_count())
    eq(app.unit_tree.item("u:rider", "values")[1], "骑手", "列表里有名字")
    eq(app.unit_tree.item("u:rider", "values")[2], "骑兵", "列表里有归属")
    # ★ 列号写成「按列名找」而不是写死 8/9：本轮在「攻速」后面插了一列「视野」
    #   （战争迷雾），写死列号的断言会去读错的那一格，而且报出来的错是
    #   「造价那一列不对」—— 完全指不到真正的原因。
    unit_cols = {key: i for i, (key, _header, _w) in enumerate(app_module.UNIT_TREE_COLUMNS)}
    eq(app.unit_tree.item("u:rider", "values")[unit_cols["vision"]], "9",
       "★ 列表里有「视野」那一列（骑手 = 9 格，需求：单位要有视野范围这个属性）")

    app.set_page("building")
    app.root.update()
    building_rows = list(app.building_tree.get_children())
    ok("b:zone_center" not in building_rows, "建筑列表没有区划中心")
    for required_id in ("wall", "tower", "stone_wall", "watch_tower", "base"):
        ok("b:" + required_id in building_rows, "建筑列表里有「%s」" % required_id)
    app.set_page("unit")
    app.root.update()
    eq(app.selection, None, "换页签之后选中被清掉（免得看见上一页的表单）")


# ======================================================================
# [2] 单位表单：改数值 / 归属 / 远程 / 造价 / 招募
# ======================================================================

def t_unit_form(app, model) -> None:
    print("\n[2] 单位表单")
    pick(app, "u:spearman")
    eq(app.selection, ("unit", "spearman"), "选中长枪兵")
    entries = sidebar_entries(app)
    for label in ("名称", "血量", "攻击力", "攻击距离", "攻击速度", "移动速度", "身体半径",
                  "造价 · 粮食", "造价 · 黄金", "造价 · 人口"):
        ok(label in entries, "表单里有「%s」那一行" % label)
    # ★★ 2026.11.2：兵种自己**不再有**「招募时间」这一行（读条归将领决定）——
    #   反过来钉住「入口没了」+「原地留了一句指向将领页的提示」。
    ok("招募时间" not in entries, "★★ 单位表单里不再有「招募时间」这一行（读条归将领）")
    ok(any("招它的将领" in t for t in sidebar_labels(app)),
       "★ 原地留了一行灰字提示：读条由招它的将领决定")
    eq(E(app, "血量").get(), ("%d" % model.unit("spearman").hp_max
                              if float(model.unit("spearman").hp_max).is_integer()
                              else str(model.unit("spearman").hp_max)),
       "输入框里显示当前值（config 里的 %s）" % model.unit("spearman").hp_max)

    type_into(app, E(app, "血量"), "175")
    eq(data(model)["unit"]["types"]["spearman"]["hp_max"], 175, "改血量 → unit.types.spearman.hp_max")
    eq(E(app, "血量").get(), "175", "刷新之后输入框还是新值")

    type_into(app, sidebar_entries(app)["攻击力"], "24")
    eq(data(model)["unit"]["types"]["spearman"]["damage"], 24, "改攻击力")
    type_into(app, sidebar_entries(app)["攻击距离"], "1.5")
    eq(data(model)["unit"]["types"]["spearman"]["range"], 1.5, "改攻击距离（小数）")
    type_into(app, sidebar_entries(app)["攻击速度"], "0.8")
    eq(data(model)["unit"]["types"]["spearman"]["cooldown_sec"], 0.8, "改攻击速度（间隔）")
    type_into(app, sidebar_entries(app)["移动速度"], "0.75")
    eq(data(model)["unit"]["types"]["spearman"]["speed"], 0.75, "改移动速度")
    type_into(app, sidebar_entries(app)["造价 · 粮食"], "60")
    eq(data(model)["recruit"]["list"][0]["cost"]["food"], 60, "改造价 · 粮食")
    type_into(app, sidebar_entries(app)["造价 · 黄金"], "70")
    eq(data(model)["recruit"]["list"][0]["cost"]["gold"], 70, "改造价 · 黄金")
    type_into(app, sidebar_entries(app)["造价 · 人口"], "2")
    eq(data(model)["recruit"]["list"][0]["population_cost"], 2, "改造价 · 人口")
    # ★★ 2026.11.2 反向契约：单位条目里**不许再有** train_sec（读条归将领）。
    ok("train_sec" not in data(model)["recruit"]["list"][0],
       "★★ 单位条目里没有 train_sec（读条由将领决定）")

    # ★★ 冲锋字段（嵌套 unit.types.<id>.charge）
    for label in ("冲锋距离", "冲锋伤害加成", "冲锋冷却"):
        ok(label in entries, "表单里有「%s」那一行" % label)
    type_into(app, sidebar_entries(app)["冲锋距离"], "3.5")
    eq(data(model)["unit"]["types"]["spearman"]["charge"]["min_distance"], 3.5,
       "★★ 改冲锋距离 → unit.types.spearman.charge.min_distance")
    type_into(app, sidebar_entries(app)["冲锋伤害加成"], "0.4")
    eq(data(model)["unit"]["types"]["spearman"]["charge"]["damage_bonus"], 0.4,
       "★ 改冲锋伤害加成")
    type_into(app, sidebar_entries(app)["冲锋伤害加成"], "")
    ok("damage_bonus" not in data(model)["unit"]["types"]["spearman"]["charge"],
       "★★ 清空冲锋伤害加成 = 删掉那个键")

    # 打错字：原值不动
    before = model.text
    type_into(app, sidebar_entries(app)["血量"], "abc")
    eq(model.text, before, "★ 打错字：一个字符都没写进文件")
    ok("数字" in app.status_var.get(), "★ 状态栏说清楚「要填数字」：%s" % app.status_var.get())
    # 负数被夹到最小值（血量 ≥ 1）
    type_into(app, sidebar_entries(app)["血量"], "-5")
    eq(data(model)["unit"]["types"]["spearman"]["hp_max"], 1, "★ 血量 -5 被夹到 1")
    type_into(app, sidebar_entries(app)["血量"], "175")

    # 名称：连招募卡标题一起改
    type_into(app, sidebar_entries(app)["名称"], "重装长枪兵")
    eq(data(model)["unit"]["types"]["spearman"]["name"], "重装长枪兵", "改名称")
    eq(data(model)["recruit"]["list"][0]["label"], "重装长枪兵", "★ 命令卡标题同步")
    eq(app.unit_tree.item("u:spearman", "values")[1], "重装长枪兵", "列表里的名字也刷新了")
    # 空名字被拒
    type_into(app, sidebar_entries(app)["名称"], "   ")
    eq(data(model)["unit"]["types"]["spearman"]["name"], "重装长枪兵", "★ 空名字被拒（原值不动）")

    # 归属下拉
    combo = sidebar_combos(app)["归属"]
    eq(combo.get(), "步兵", "归属下拉显示当前值")
    combo.set("骑兵")
    combo.event_generate("<<ComboboxSelected>>")
    app.root.update()
    eq(data(model)["unit"]["types"]["spearman"]["class"], "cavalry", "★ 归属改成骑兵")
    eq(app.unit_tree.item("u:spearman", "values")[2], "骑兵", "列表里的归属跟着变")

    # 远程勾选
    chk = sidebar_checks(app)["远程"]
    chk.invoke()
    app.root.update()
    eq(data(model)["unit"]["types"]["spearman"]["ranged"], True, "★ 勾上远程")
    sidebar_checks(app)["远程"].invoke()
    app.root.update()
    eq(data(model)["unit"]["types"]["spearman"]["ranged"], False, "取消远程")

    # 地图上的字（一个文本框；本轮从「挑一份线条预制体」改成「填一个字」）
    ok("地图上的字" in sidebar_entries(app), "表单里有「地图上的字」这一行")
    eq(E(app, "地图上的字").get(), "枪", "输入框里显示配置里的字")
    eq(app.unit_tree.item("u:spearman", "values")[0], "枪", "★ 列表第一列就是它")
    type_into(app, E(app, "地图上的字"), "矛")
    eq(data(model)["unit"]["types"]["spearman"]["icon"], "矛", "改字 → unit.types.spearman.icon")
    eq(app.unit_tree.item("u:spearman", "values")[0], "矛", "列表里那一列跟着变")
    # 两个字被拒
    before_icon = model.text
    type_into(app, E(app, "地图上的字"), "矛盾")
    eq(model.text, before_icon, "★★ 填两个字：一个字符都没写进文件")
    ok("一个字符" in app.status_var.get(), "状态栏说清原因：%s" % app.status_var.get())
    # 清空 → 跟着名字的第一个字
    type_into(app, E(app, "地图上的字"), "")
    eq(data(model)["unit"]["types"]["spearman"].get("icon", None), None,
       "★ 清空 → 那个键被删掉")
    eq(app.unit_tree.item("u:spearman", "values")[0], "重",
       "★ 列表里显示的是**生效值**（跟着名字「重装长枪兵」→ 重）")

    # ---- ★★ 视野半径（战争迷雾）：与建筑那一栏是同一条规则 ----
    ucols = {key: i for i, (key, _h, _w) in enumerate(app_module.UNIT_TREE_COLUMNS)}
    ok("视野半径" in sidebar_entries(app), "兵种表单里有「视野半径」这一行")
    eq(E(app, "视野半径").get(), "8", "输入框里显示配置里的 8")
    eq(app.unit_tree.item("u:spearman", "values")[ucols["vision"]], "8", "★ 列表里也有这一列")
    type_into(app, E(app, "视野半径"), "11")
    eq(data(model)["unit"]["types"]["spearman"]["vision"], 11,
       "★★ 改兵种视野 → 落在 unit.types.spearman.vision")
    eq(app.unit_tree.item("u:spearman", "values")[ucols["vision"]], "11", "列表里的视野刷新了")
    # 清空 → 删掉那个键 → 回到 config 的 fog.vision_default
    type_into(app, E(app, "视野半径"), "")
    eq(data(model)["unit"]["types"]["spearman"].get("vision", None), None,
       "★★ 清空 → unit.types.spearman.vision 那个键被删掉")
    eq(app.unit_tree.item("u:spearman", "values")[ucols["vision"]], "8",
       "★★ 列表里显示的是**生效值**（没写 → config 的 fog.vision_default = 8）")

    # 不在招募表里的单位：说清楚 + 一个「加进招募表」按钮
    # ★ 本次改主角：原来是「测试敌人」（它已经从编辑器与 config 里删除）。
    #   现在造一个「有类型、没招募条目」的兵种 —— 用的都是公开接口：
    #   `add_unit` 会照 rider 复制一份（**连带招募条目**），再把它那一条删掉就是目标状态。
    app_module._ask_new_entry = lambda *a, **k: ("skeleton", "骷髅", "rider")
    app.do_new_unit()
    app.root.update()
    ok(model.unit("skeleton").has_recruit, "（前提）新建兵种默认带一条招募条目")
    model.doc.remove(["recruit", "list", model.unit("skeleton").recruit_index])
    ok(not model.unit("skeleton").has_recruit, "（前提）删掉之后它就不在招募表里了")
    app.refresh_all()
    app.root.update()
    pick(app, "u:skeleton")
    ok("招募表" in " ".join(w.cget("text") for w in walk(app.sidebar)
                            if isinstance(w, tk.Label) and w.cget("text")), 
       "★ 不在招募表里的单位：那一页说明它不在招募表里")
    btn = buttons(app).get("把它加进招募表（照默认值）")
    ok(btn is not None, "有「加进招募表」按钮")
    before_recruits = len(data(model)["recruit"]["list"])
    btn.invoke()
    app.root.update()
    eq(len(data(model)["recruit"]["list"]), before_recruits + 1, "点一下 → 加进招募表")
    eq(data(model)["recruit"]["list"][-1]["kind"], "skeleton", "新那一条的 kind = skeleton")

    # ★★ 2026.11.2：派系兵种的招募条目在 clan.list[].recruit[] 里 ——
    #   列表要显示造价、详情页要能改建价（用户报的「不在招募表」就是这个 bug）。
    pick(app, "u:dy_chariot")
    cell = app.unit_tree.item("u:dy_chariot", "values")[ucols["cost"]]
    ok("不在招募表" not in cell, "★★ 王朝战车：造价列不再写「不在招募表」（%s）" % cell)
    type_into(app, E(app, "造价 · 黄金"), "321")
    dyn = next(c for c in data(model)["clan"]["list"] if c["id"] == "dynasty")
    row = next(r for r in dyn["recruit"] if r["kind"] == "dy_chariot")
    eq(row["cost"]["gold"], 321, "★★ 改建价 → 写进 clan:dynasty 那一张表")

    # ★★ 组合单位的零件：没有自己的条目，但**招得出来**（整包生成）——
    #   不能谎报「不在招募表」，也不该给一组改不动的输入框。
    pick(app, "u:dy_spear_guard")
    cell = app.unit_tree.item("u:dy_spear_guard", "values")[ucols["cost"]]
    ok("协防军" in cell, "★★ 协防军枪：造价列写「随「协防军」」（%s）" % cell)
    ok(any("组合生成" in t for t in sidebar_labels(app)),
       "★ 详情页说清它由「协防军」整包生成")
    ok("造价 · 粮食" not in sidebar_entries(app),
       "★ 组合零件没有「造价」输入框（造价在那一单上）")


# ======================================================================
# [3] 将领表单
# ======================================================================

def row_frame(app, label):
    """侧边栏里「标签」所在的那一行（Frame）。"""
    for frame in walk(app.sidebar):
        if not isinstance(frame, tk.Frame):
            continue
        kids = frame.winfo_children()
        if kids and isinstance(kids[0], tk.Label) and kids[0].cget("text") == label:
            return frame
    raise AssertionError("侧边栏里没有「%s」这一行" % label)


def row_button_at(app, section: str, label: str):
    """指定节里那一行右边的小按钮（「自定 / 跟随」）。"""
    for frame in walk(app.sidebar):
        if not isinstance(frame, tk.Frame) or getattr(frame, "section_title", None) != section:
            continue
        for row in walk(frame):
            if not isinstance(row, tk.Frame):
                continue
            kids = row.winfo_children()
            if kids and isinstance(kids[0], tk.Label) and kids[0].cget("text") == label:
                return next((k for k in kids if isinstance(k, tk.Button)), None)
    raise AssertionError("「%s」那一节里没有「%s」" % (section, label))


def set_optional_at(app, section: str, label: str, text: str) -> None:
    """把「跟随别人」的那一行改成自定并填值（界面上的动线是：先点自定，再改数）。"""
    if str(E_in(app, section, label).cget("state")) == "disabled":
        row_button_at(app, section, label).invoke()
        app.root.update()
    type_into(app, E_in(app, section, label), text)


def follow_optional_at(app, section: str, label: str) -> None:
    """把「自己填」的那一行改回跟随（= 删掉覆盖）。"""
    if str(E_in(app, section, label).cget("state")) != "disabled":
        row_button_at(app, section, label).invoke()
        app.root.update()


def set_optional(app, label: str, text: str) -> None:
    """将领数值那一套（都在「数值」那一节里）。"""
    set_optional_at(app, "数值", label, text)


def follow_optional(app, label: str) -> None:
    follow_optional_at(app, "数值", label)


def t_package_form(app, model) -> None:
    """★★ 2026.11.2：组合招募单（协防军 / 御林军）—— 它们不是兵种，单独一栏一页。"""
    print("\n[2b] 组合招募单表单")
    rows = list(app.package_tree.get_children())
    ok("p:dy_guard" in rows, "★★ 左边有「协防军」这一行（用户报的：找不到改它造价的地方）")
    ok("p:dy_royal" in rows, "★★ 左边有「御林军」这一行")

    pick(app, "p:dy_guard")
    eq(app.selection, ("package", "dy_guard"), "选中组合单")
    for label in ("名字", "命令卡方框字", "命令卡说明",
                  "造价 · 粮食", "造价 · 黄金", "造价 · 人口"):
        ok(label in sidebar_entries(app), "表单里有「%s」那一行" % label)
    ok(any("整包" in t for t in sidebar_labels(app)),
       "★ 页面说明这是「整包」造价（不是每个人）")
    ok(any("dy_spear_guard" in t for t in sidebar_labels(app)),
       "★ 组成栏里写着它由哪些兵种生成")

    # 改整包粮价 → 写进 clan:dynasty 那一行
    type_into(app, E(app, "造价 · 粮食"), "210")
    dyn = next(c for c in data(model)["clan"]["list"] if c["id"] == "dynasty")
    row = next(r for r in dyn["recruit"] if r["kind"] == "dy_guard")
    eq(row["cost"]["food"], 210, "★★ 改「协防军」粮价 → 写进 clan:dynasty 那一单")
    eq(app.package_tree.item("p:dy_guard", "values")[2].split(" / ")[0], "210",
       "★ 左侧列表的造价跟着刷新")

    # 改文案
    type_into(app, E(app, "名字"), "协防营")
    dyn = next(c for c in data(model)["clan"]["list"] if c["id"] == "dynasty")
    row = next(r for r in dyn["recruit"] if r["kind"] == "dy_guard")
    eq(row["label"], "协防营", "改这一单的命令卡标题")

    # 它跟「兵种」页不串线：协防军枪仍然没有自己的招募条目
    pick(app, "u:dy_spear_guard")
    eq(app.selection, ("unit", "dy_spear_guard"), "选中零件兵种")
    ok("造价 · 粮食" not in sidebar_entries(app),
       "★ 零件的详情页仍然没有造价输入框（造价在组合单那一页）")


def t_general_form(app, model) -> None:
    print("\n[3] 将领表单")
    pick(app, "g:0")
    entries = sidebar_entries(app)
    ok("名字" in entries, "有名字输入框")
    ok("血量" in entries, "有血量输入框")
    # ⚠️ [2] 那一段已经改过兵种数值，所以这里一律**按当前配置**算期望值，
    #    不写死 160（写死的话，改一条断言就要跟着改另一条）。
    g0 = model.general(0)
    inherited = app_module.fmt(model.unit(g0.type_id).hp_max)
    eq(E(app, "血量").get(), inherited,
       "★ 没覆盖时显示的是「跟随类型」的 %s" % inherited)
    eq(str(E(app, "血量").cget("state")), "disabled", "★ 跟随状态下输入框不可编辑（看得见、不能改）")

    # 「自定」按钮：把当前继承值写成一份覆盖
    btn = row_button_at(app, "数值", "血量")
    eq(btn.cget("text"), "自定", "「跟随」状态下的按钮写着「自定」")
    btn.invoke()
    app.root.update()
    eq(data(model)["unit"]["general"]["stats"][0]["hp_max"], float(inherited),
       "★ 点「自定」→ 把继承值写成覆盖")
    ok(str(E(app, "血量").cget("state")) != "disabled", "现在可以编辑了")

    type_into(app, E(app, "血量"), "260")
    eq(data(model)["unit"]["general"]["stats"][0]["hp_max"], 260, "改将领自己的血量")
    eq(data(model)["unit"]["types"][g0.type_id]["hp_max"], float(inherited),
       "★★ 兵种那一档没被动过")
    set_optional(app, "攻击力", "30")
    eq(data(model)["unit"]["general"]["stats"][0]["damage"], 30, "改将领自己的攻击力")
    eq(app.general_tree.item("g:0", "values")[0], "将领 1（有单独数值）",
       "将领列表标出「有单独数值」")
    eq(app.general_tree.item("g:0", "values")[2], "260", "列表里显示生效血量")

    # 「跟随」按钮：删掉覆盖
    eq(row_button_at(app, "数值", "血量").cget("text"), "跟随", "自己填之后按钮写着「跟随」")
    follow_optional(app, "血量")
    ok("hp_max" not in data(model)["unit"]["general"]["stats"][0], "★ 点「跟随」→ 覆盖被删掉")
    eq(E(app, "血量").get(), inherited, "回到跟随类型：显示 %s" % inherited)
    eq(app.general_tree.item("g:0", "values")[2], inherited, "列表里也回到类型数值")

    # 类型下拉
    combo = sidebar_combos(app)["类型"]
    combo.set("骑手（rider）")
    combo.event_generate("<<ComboboxSelected>>")
    app.root.update()
    eq(data(model)["unit"]["general"]["types"][0], "rider", "★ 改将领类型")
    # ★ 期望值取**配置里的骑手速度**（不写死 0.9）：换类型之后它应当跟着变成那个数。
    rider_speed = model.unit("rider").speed
    eq(E(app, "移动速度").get(),
       ("%d" % rider_speed if float(rider_speed).is_integer() else str(rider_speed)),
       "★ 类型一换，跟随的数值跟着变（骑手 %s）" % rider_speed)
    eq(data(model)["unit"]["general"]["stats"][0]["damage"], 30,
       "★ 自己填过的项不跟着类型走")

    # 名字 / 造价 / 区划招募读条 / 招兵读条
    type_into(app, E(app, "名字"), "西境骑将")
    eq(data(model)["unit"]["general"]["stats"][0]["name"], "西境骑将", "改将领名字")
    eq(data(model)["recruit"]["zone"]["list"][0]["label"], "西境骑将", "★ 招募卡标题同步")
    type_into(app, E(app, "区划招募读条"), "14")
    eq(data(model)["recruit"]["zone"]["list"][0]["train_sec"], 14, "改区划招募读条")
    # ★★ 2026.11.2：招兵读条 = 这位将领当兵营时的整批读条（unit.general.recruit_sec）
    type_into(app, E(app, "招兵读条"), "7")
    eq(data(model)["unit"]["general"]["recruit_sec"][0], 7, "★★ 改招兵读条")
    type_into(app, E(app, "造价 · 粮食"), "88")
    eq(data(model)["recruit"]["zone"]["list"][0]["cost"]["food"], 88, "改将领造价")
    # ★★ 「开局护卫数」那一行输入控件**已经删掉**（产品决策：开局带几个附属兵不再由
    #    config.json 给全局缺省，只能在战役编辑器的摆放页里摆）。这里**不是把这行断言删掉**，
    #    而是反过来钉住「入口没了」+「原地留了指向新家的灰字提示」——
    #    哪天有人把控件加回来（或把提示删了），当场变红。
    #    ⚠️ 附属兵这个玩法机制本身没动，动的只是「开局白送几个」这个配置项。
    ok("开局护卫数" not in sidebar_entries(app),
       "★★ 将领表单里不再有「开局护卫数」这一行（输入入口已移除）")
    ok(not hasattr(model, "escort") and not hasattr(model, "set_escort"),
       "★★ 模型层也不再提供 escort() / set_escort() 接口")
    ok("escort" not in data(model)["unit"]["general"],
       "★★ 编辑器的数据里也不再有 unit.general.escort")
    hints = [t for t in sidebar_labels(app) if "战役编辑器" in t and "摆放页" in t]
    ok(bool(hints),
       "★ 原地留了一行只读灰字提示，指向「战役编辑器的摆放页」（读者不会被坑第二次）：%s"
       % (hints or "（一句都没有）"))


def t_traits(app, model) -> None:
    """★★ 2026.11.3：特性 —— 兵种那四个键 + 将领特性池（可增删）+ 每位将领指定一条。"""
    print("\n[3b] 特性")
    app.set_page("unit")
    app.root.update()

    # ---------------- 兵种特性（unit.types.<id>.traits）----------------
    pick(app, "u:spearman")
    rows = sectioned(app)
    ok(("特性", "对骑兵伤害") in rows,
       "★★ 兵种表单里有「对骑兵伤害」那一行（长枪兵自带的对骑兵 +25%）")
    eq(E_in(app, "特性", "对骑兵伤害").get(), "0.25",
       "★ 读到 0.25（比例；= +25%）")
    eq(E_in(app, "特性", "远程减伤").get(), "",
       "★★ 没写的减伤是**空框**（不是 0）—— 与「视野半径」同一条语义")
    ok("免疫击退（稳定）" in sidebar_checks(app), "★ 有「免疫击退」勾选框")

    # 改一个已有的比例
    type_into(app, E_in(app, "特性", "对骑兵伤害"), "0.4")
    eq(data(model)["unit"]["types"]["spearman"]["traits"]["attack_vs_class"]["cavalry"], 0.4,
       "★★ 改「对骑兵伤害」→ traits.attack_vs_class.cavalry（config.gd 读这个键）")

    # 删掉那一行
    row_button_at(app, "特性", "对骑兵伤害").invoke()
    app.root.update()
    ok("cavalry" not in (data(model)["unit"]["types"]["spearman"].get("traits", {})
                         .get("attack_vs_class", {})),
       "★★ 点那一行的「删」→ 这条加成没了")
    ok(("特性", "对骑兵伤害") not in sectioned(app), "那一行从表单上消失了")

    # 加一条：下拉里只剩没加过的大类
    combo = sidebar_combos(app)["加一条"]
    ok("步兵" in combo.cget("values"), "★ 「加一条」下拉里有步兵")
    combo.set("步兵")
    row_button_at(app, "特性", "加一条").invoke()
    app.root.update()
    eq(data(model)["unit"]["types"]["spearman"]["traits"]["attack_vs_class"]["infantry"],
       0.25, "★★ 加一条 → 默认 +25%，落在 traits.attack_vs_class.infantry")

    # 减伤：写入 → 清空 = 删掉那个键
    type_into(app, E_in(app, "特性", "远程减伤"), "0.25")
    eq(data(model)["unit"]["types"]["spearman"]["traits"]["ranged_reduction"], 0.25,
       "★★ 「远程减伤」落在 traits.ranged_reduction")
    type_into(app, E_in(app, "特性", "远程减伤"), "")
    ok("ranged_reduction" not in data(model)["unit"]["types"]["spearman"]["traits"],
       "★★ 清空输入框 = 删掉那个键（不写一个 0 进文件）")

    # 稳定：勾上 / 取消
    checks = sidebar_checks(app)
    checks["免疫击退（稳定）"].invoke()
    app.root.update()
    eq(data(model)["unit"]["types"]["spearman"]["traits"]["knockback_immune"], True,
       "★ 勾上「免疫击退」→ traits.knockback_immune = true")
    sidebar_checks(app)["免疫击退（稳定）"].invoke()
    app.root.update()
    ok("knockback_immune" not in data(model)["unit"]["types"]["spearman"]["traits"],
       "★★ 取消勾选 = 删掉那个键")

    # ---------------- 将领特性池（unit.general_traits）----------------
    eq(list(app.trait_tree.get_children()),
       ["t:" + tid for tid in model.general_trait_ids()],
       "★★ 左边有「将领特性池」那一栏，列出池里的每一条")
    trait_cols = {"name": 0, "short": 1, "effect": 2}
    eq(app.trait_tree.item("t:swift", "values")[trait_cols["name"]], "神速",
       "★ 池列表里有名字")
    ok("25%" in app.trait_tree.item("t:swift", "values")[trait_cols["effect"]],
       "★ 池列表里有「效果」摘要（%s）"
       % app.trait_tree.item("t:swift", "values")[trait_cols["effect"]])

    pick(app, "t:swift")
    eq(app.selection, ("trait", "swift"), "★ 点一行 → 右边是这条特性")
    eq(E_in(app, "文案", "名字").get(), "神速", "★ 表单读到了名字")
    eq(E_in(app, "效果", "移速加成").get(), "0.25", "★ 表单读到了移速加成 0.25")
    type_into(app, E_in(app, "效果", "移速加成"), "0.3")
    eq(data(model)["unit"]["general_traits"]["swift"]["speed_bonus"], 0.3,
       "★★ 改移速加成 → unit.general_traits.swift.speed_bonus（config.gd 读它）")
    type_into(app, E_in(app, "文案", "说明"), "移动速度 +30%")
    eq(data(model)["unit"]["general_traits"]["swift"]["desc"], "移动速度 +30%",
       "★ 改说明")

    # 将领特性也能加「对某大类伤害」
    pick(app, "t:infantry_slayer")
    sidebar_combos(app)["加一条"].set("骑兵")
    row_button_at(app, "效果", "加一条").invoke()
    app.root.update()
    eq(data(model)["unit"]["general_traits"]["infantry_slayer"]
       ["attack_vs_class"].get("cavalry"), 0.25,
       "★★ 将领特性也能加一条「对骑兵 +25%」")
    row_button_at(app, "效果", "对骑兵伤害").invoke()
    app.root.update()
    ok("cavalry" not in data(model)["unit"]["general_traits"]["infantry_slayer"]
       ["attack_vs_class"], "★ 也能删掉那一行")

    # ---------------- 新建 / 删除特性 ----------------
    app_module._ask_new_entry = lambda *a, **k: ("brute", "蛮力", "might")
    n_before = len(data(model)["unit"]["general_traits"])
    app.do_new_trait()
    app.root.update()
    pool = data(model)["unit"]["general_traits"]
    eq(len(pool), n_before + 1, "★★ 「＋ 新建特性」真的加进池里")
    eq(pool["brute"]["name"], "蛮力", "★ 新特性用填的名字")
    eq(pool["brute"]["attack_speed_bonus"], 0.25, "★ 照模板（神力）复制了效果")
    eq(app.selection, ("trait", "brute"), "★ 建完自动选中它")
    ok(app.trait_tree.exists("t:brute"), "★ 列表里立刻出现")

    # ---------------- 给将领指定一条 ----------------
    pick(app, "g:0")
    combo = sidebar_combos(app)["特性"]
    ok("（无）" in combo.cget("values"), "★ 将领表单的「特性」下拉里有「（无）」")
    combo.set("蛮力（brute）")
    combo.event_generate("<<ComboboxSelected>>")
    app.root.update()
    eq(data(model)["unit"]["general"]["trait_ids"][0], "brute",
       "★★ 给将领 0 选「蛮力」→ unit.general.trait_ids[0] = brute（游戏侧 general_trait_at 读它）")
    ok(any("蛮力" in t for t in sidebar_labels(app)),
       "★ 表单上写明了这条特性是什么（%s）"
       % [t for t in sidebar_labels(app) if "蛮力" in t])
    sidebar_combos(app)["特性"].set("（无）")
    sidebar_combos(app)["特性"].event_generate("<<ComboboxSelected>>")
    app.root.update()
    eq(data(model)["unit"]["general"]["trait_ids"][0], "", "★ 选「（无）」= 清空")

    # ---------------- 删掉一条正在用的特性：不留坏 id ----------------
    pick(app, "g:0")
    sidebar_combos(app)["特性"].set("蛮力（brute）")
    sidebar_combos(app)["特性"].event_generate("<<ComboboxSelected>>")
    app.root.update()
    eq(data(model)["unit"]["general"]["trait_ids"][0], "brute", "（前提）将领 0 正在用 brute")
    app_module.messagebox.askyesno = lambda *a, **k: True
    pick(app, "t:brute")
    app.do_delete_trait()
    app.root.update()
    ok("brute" not in data(model)["unit"]["general_traits"],
       "★★ 「删除特性」把池里那条删掉了")
    eq(data(model)["unit"]["general"]["trait_ids"][0], "",
       "★★ 正在用它的将领被改成「无」（不留一条指向空 id 的记录）")
    ok(not app.trait_tree.exists("t:brute"), "列表里也没了")


# ======================================================================
# [4] 建筑表单
# ======================================================================

def t_building_form(app, model) -> None:
    print("\n[4] 建筑表单")
    app.set_page("building")
    app.root.update()
    pick(app, "b:wall")
    entries = sidebar_entries(app)
    for label in ("名称", "解锁大本营等级", "排内位置", "建造时间", "造价 · 粮食", "造价 · 黄金",
                  "血量", "本体大小", "视野半径", "远程免伤"):
        ok(label in entries, "建筑表单里有「%s」" % label)
    ok("攻击力" not in entries, "★ 木墙「不可攻击」→ 攻击三行收起来了")

    type_into(app, E(app, "建造时间"), "6")
    eq(data(model)["building"]["wall"]["build_sec"], 6, "★ 改建造时间")
    type_into(app, sidebar_entries(app)["视野半径"], "7")
    eq(data(model)["building"]["wall"]["vision"], 7,
       "★★ 改建筑视野 → 落在 building.wall.vision（每个类型自己一个值）")
    eq(app.building_tree.item("b:wall", "values")[bcols()["vision"]], "7", "列表里的视野刷新了")
    type_into(app, sidebar_entries(app)["血量"], "500")
    eq(data(model)["building"]["wall"]["hp_max"], 500, "改血量")
    type_into(app, sidebar_entries(app)["名称"], "土墙")
    eq(data(model)["building"]["wall"]["name"], "土墙", "改名称")
    eq(app.building_tree.item("b:wall", "values")[0], "土墙", "列表里的名字刷新了")
    type_into(app, sidebar_entries(app)["排内位置"], "2")
    eq(data(model)["building"]["wall"]["slot"], 2, "★ 改排内位置 → building.wall.slot")
    type_into(app, sidebar_entries(app)["排内位置"], "")
    eq("slot" in data(model)["building"]["wall"], False,
       "★★ 清空排内位置 = 删掉 slot 键（回到自动补位）")
    type_into(app, sidebar_entries(app)["造价 · 黄金"], "25")
    eq(data(model)["building"]["wall"]["cost"]["gold"], 25, "改建筑造价")
    type_into(app, sidebar_entries(app)["解锁大本营等级"], "2")
    eq(data(model)["building"]["wall"]["tier"], 2, "★★ 改解锁大本营等级")
    type_into(app, sidebar_entries(app)["远程免伤"], "0.75")
    eq(data(model)["building"]["wall"]["ranged_reduction"], 0.75, "★★ 改远程免伤")

    # 可攻击勾上 → 攻击三行出现
    sidebar_checks(app)["可攻击"].invoke()
    app.root.update()
    eq(data(model)["building"]["wall"]["attackable"], True, "勾上「可攻击」")
    entries = sidebar_entries(app)
    for label in ("攻击力", "攻击距离", "攻击速度"):
        ok(label in entries, "★ 勾上之后出现「%s」" % label)
    type_into(app, E(app, "攻击力"), "9")
    eq(data(model)["building"]["wall"]["damage"], 9, "改建筑攻击力")
    type_into(app, sidebar_entries(app)["攻击距离"], "2.5")
    eq(data(model)["building"]["wall"]["range"], 2.5, "改建筑攻击距离")
    type_into(app, sidebar_entries(app)["攻击速度"], "1.2")
    eq(data(model)["building"]["wall"]["cooldown"], 1.2, "改建筑攻击速度（间隔）")

    # ★ 视野半径（战争迷雾）：建筑与兵种是同一条规则（显示生效值、清空 = 删键）
    ok("视野半径" in sidebar_entries(app), "建筑表单里有「视野半径」这一行")
    eq(E(app, "视野半径").get(), "7", "输入框里显示刚写进去的 7")
    type_into(app, E(app, "视野半径"), "")
    eq(data(model)["building"]["wall"].get("vision", None), None,
       "★★ 清空 → building.wall.vision 那个键被删掉")
    eq(app.building_tree.item("b:wall", "values")[bcols()["vision"]], "9",
       "★★ 列表里显示的是**生效值**（没写 → config 的 fog.vision_building = 9）")

    # ★★ 2026.10.26：升级表只剩大本营；木墙 / 哨塔没有升级区。
    pick(app, "b:base")
    app.root.update()
    # 升级表（★ 按「节 + 标签」定位：同名的行在三级里各有一份）
    type_into(app, E_in(app, "升到 2 级", "需要的价格 · 粮食"), "260")
    eq(data(model)["upgrade"]["levels"]["base"][1]["cost"]["food"], 260,
       "★ 大本营升 2 级的价格（粮食）")
    type_into(app, E_in(app, "升到 2 级", "需要的价格 · 黄金"), "270")
    eq(data(model)["upgrade"]["levels"]["base"][1]["cost"]["gold"], 270,
       "升 2 级的价格（黄金）")
    type_into(app, E_in(app, "升到 2 级", "需要的读条时间"), "12")
    eq(data(model)["upgrade"]["levels"]["base"][1]["time_sec"], 12, "升 2 级的读条时间")
    type_into(app, E_in(app, "升到 2 级", "血量倍率"), "1.8")
    eq(data(model)["upgrade"]["levels"]["base"][1]["hp_mult"], 1.8, "★ 升 2 级的血量倍率")
    eq(data(model)["upgrade"]["levels"]["base"][0]["hp_mult"], 1.0, "★ 1 级那一行没被动过")
    type_into(app, E_in(app, "升到 3 级", "需要的价格 · 粮食"), "450")
    eq(data(model)["upgrade"]["levels"]["base"][2]["cost"]["food"], 450, "★ 升 3 级的价格")

    # 逐级攻击：自定 / 跟随（用的是「跟随基础值」那套可选行）
    set_optional_at(app, "升到 2 级", "攻击力", "20")
    rows = data(model)["upgrade"]["levels"]["base"]
    eq(rows[1]["damage"], 20, "★★ 大本营 2 级可以有自己的攻击力")
    eq(data(model)["building"]["base"]["damage"], 12, "★ 基础攻击力没被动过")
    follow_optional_at(app, "升到 2 级", "攻击力")
    rows = data(model)["upgrade"]["levels"]["base"]
    ok(not any(k in rows[1] for k in ("damage", "range", "cooldown")),
       "★★ 点「跟随」→ 覆盖被删掉（回到沿用基础值）")
    eq(E_in(app, "升到 2 级", "攻击力").get(), "12", "输入框回到基础值 12")

    # 哨塔：默认就能攻击；没有升级表。
    pick(app, "b:tower")
    entries = sidebar_entries(app)
    ok("攻击力" in entries, "哨塔默认就有攻击力那一行")
    eq(E(app, "攻击力").get(), "12", "显示 12")
    ok("可攻击" in sidebar_checks(app), "有「可攻击」勾选框")
    eq(sidebar_checks(app)["可攻击"].instate(["selected"]), True, "★ 哨塔默认是勾上的")
    ok("升到 2 级" not in entries, "★★ 哨塔没有升级表（表单里没有升级区）")


# ======================================================================
# [5] 科技页 —— ★★ 2026.11 已整块移除
# ======================================================================

def t_tech_page_gone(app, model) -> None:
    print("\n[5] 科技页已移除（科技只在 tools/buff_editor 里编辑）")
    ok("tech" not in app.tab_buttons, "★★ 页签里没有「科技」")
    eq([k for k, _l, _h in app_module.PAGES], ["unit", "building"],
       "★★ PAGES 只剩单位 / 建筑")
    ok(not hasattr(app, "tech_tree"), "★★ 没有科技列表")
    ok(not hasattr(app, "max_active_var"), "★★ 没有「最多启用几条」那个输入框")
    ok(not hasattr(app, "_build_tech_form"), "★★ 没有科技表单")
    ok(not hasattr(app, "_build_tech_list"), "★★ 没有科技列表构建函数")
    ok(not hasattr(app, "_commit_max_active"), "★★ 没有那个提交函数")
    # 数据层也碰不到 tech.*
    ok(not hasattr(model, "set_tech"), "★★ 模型层不能改科技")
    # 单位 / 建筑两页照旧
    app.set_page("unit")
    app.root.update()
    ok(app.unit_tree is not None and app.building_tree is not None,
       "★ 单位 / 建筑的列表都还在")

# ======================================================================
# [6] 撤销 / 重做 / 保存 / 重载
# ======================================================================

def t_undo_save(app, model, path) -> None:
    print("\n[6] 撤销 / 重做 / 保存 / 重载")
    app.set_page("unit")
    app.root.update()
    pick(app, "u:longbowman")
    before = model.text
    # ★ 记下**磁盘上原本那个血量**：下面「还没保存时磁盘没变」那条要拿它当期望值
    #   （写死 110 的话，每次调配平都会假失败 —— 这条钉的是「保存」这条链）。
    lb_hp_before = json.loads(path.read_text(encoding="utf-8"))["unit"]["types"]["longbowman"]["hp_max"]
    type_into(app, sidebar_entries(app)["血量"], "130")
    eq(data(model)["unit"]["types"]["longbowman"]["hp_max"], 130, "先改一笔")
    ok(model.dirty, "★ 改完是「脏」的")
    ok("未保存" in app.file_label.cget("text"), "顶栏标出「未保存」")
    app.do_undo()
    app.root.update()
    eq(model.text, before, "★ Ctrl+Z 撤销 → 文本逐字节回到改之前")
    app.do_redo()
    app.root.update()
    eq(data(model)["unit"]["types"]["longbowman"]["hp_max"], 130, "★ Ctrl+Y 重做回来")

    ok(data(model)["unit"]["types"]["longbowman"]["hp_max"] == 130, "（保存前内存里是 130）")
    # ★ 期望值取**磁盘上原本那个数**（不写死 110）：配平会调，这条钉的是「还没保存」。
    eq(json.loads(path.read_text(encoding="utf-8"))["unit"]["types"]["longbowman"]["hp_max"],
       lb_hp_before, "★ 还没保存：磁盘上还是改动前那个值（%s）" % lb_hp_before)
    app.do_save()
    app.root.update()
    ok(not model.dirty, "保存之后不脏了")
    eq(json.loads(path.read_text(encoding="utf-8"))["unit"]["types"]["longbowman"]["hp_max"],
       130, "★ 保存之后磁盘上是 130")

    # 重新载入丢掉未保存的改动
    type_into(app, sidebar_entries(app)["血量"], "999")
    app_module.messagebox.askyesno = lambda *a, **k: True
    app.do_reload()
    app.root.update()
    eq(model.unit("longbowman").hp_max, 130, "★ 重新载入丢掉未保存的改动")
    eq(json.loads(path.read_text(encoding="utf-8"))["unit"]["types"]["longbowman"]["hp_max"],
       130, "磁盘上仍是上一版")


# ======================================================================
# [7] 新建 / 删除
# ======================================================================

def t_add_remove(app, model) -> None:
    print("\n[7] 新建 / 删除")
    # ---- 新建兵种（对话框换成「直接给答案」）
    app_module._ask_new_entry = lambda *a, **k: ("horse_archer", "马弓手", "rider")
    app.do_new_unit()
    app.root.update()
    ok(model.doc.has(["unit", "types", "horse_archer"]), "★ 新建兵种进了配置")
    ok(app.unit_tree.exists("u:horse_archer"), "列表里出现了它")
    eq(app.selection, ("unit", "horse_archer"), "新建之后自动选中它")
    eq(data(model)["unit"]["types"]["horse_archer"]["name"], "马弓手", "名字对")
    eq(data(model)["unit"]["types"]["horse_archer"]["class"], "cavalry", "★ 照 rider 复制：骑兵")
    eq(app.unit_tree.item("u:horse_archer", "values")[2], "骑兵", "列表里显示骑兵")

    # ---- 删掉它（确认框换成「是」）
    app_module.messagebox.askyesno = lambda *a, **k: True
    app.do_delete_unit()
    app.root.update()
    ok(not model.doc.has(["unit", "types", "horse_archer"]), "★ 删掉了")
    ok(not app.unit_tree.exists("u:horse_archer"), "列表里也没了")

    # ---- 内置兵种不许删（点按钮 = 数据层抛错 → 状态栏说清楚，不崩）
    pick(app, "u:spearman")
    app.do_delete_unit()
    app.root.update()
    ok(model.doc.has(["unit", "types", "spearman"]), "★ 内置兵种没被删掉")
    ok("内置" in app.status_var.get(), "状态栏说清了原因：%s" % app.status_var.get())

    # ---- 新建建筑
    app.set_page("building")
    app.root.update()
    app_module._ask_new_entry = lambda *a, **k: ("outpost", "前哨站", "tower")
    app.do_new_building()
    app.root.update()
    ok(model.doc.has(["building", "outpost"]), "★ 新建建筑进了配置")
    ok(app.building_tree.exists("b:outpost"), "建筑列表里出现了它")
    eq(data(model)["building"]["outpost"]["buildable"], True, "★★ 新建筑默认「可建造」")
    ok(not model.doc.has(["upgrade", "levels", "outpost"]),
       "★★ 新建筑不再自动配升级表")
    eq(app.selection, ("building", "outpost"), "自动选中它")
    # 删掉
    app.do_delete_building()
    app.root.update()
    ok(not model.doc.has(["building", "outpost"]), "删掉了")
    ok(not model.doc.has(["upgrade", "levels", "outpost"]), "★ 升级表也删了")
    # 内置建筑不许删
    pick(app, "b:tower")
    app.do_delete_building()
    app.root.update()
    ok(model.doc.has(["building", "tower"]), "★ 内置建筑没被删掉")


# ======================================================================
# [8] 侧边栏滚动：装得下就不许滚（用户报的「上方出现大量空白」）
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
    print("\n[8] 侧边栏滚动：装得下就不许滚")

    # ★ 先把窗口**显示出来**再调尺寸：withdraw 状态下 `geometry()` 不生效
    #   （实测：withdraw 时画布恒为 750，deiconify 之后才跟着窗口走）。
    app.root.deiconify()
    app.set_page("unit")            # 上一节停在科技页，列表是另一棵
    app.root.update()
    cv = app.sidebar_canvas

    def offset() -> float:
        return cv.canvasy(0.0)

    def grow_until_fits(iid: str, label: str) -> bool:
        """把窗口拉高到「这一张表单装得下」为止（不同机器屏幕高度不同，多试几档）。

        ★★ 这一节量的是**「装得下就不许滚」那条逻辑**，不是「表单必须不超过某个高度」。
          所以窗口高度阶梯**要留足余量**：表单每加一行字段就高一截
          （本轮给单位表加了「视野半径」，单位页那一张在 1080p 上就装不下了），
          阶梯到头就会报成「装不下 → 不许滚失效」，而真正的原因只是**窗口不够高**。

        @return bool 装得下了没有（False = 这台机器的窗口高度不够，后面那几条没法验）。
        """
        pick(app, iid)
        app.root.update()
        need = app.sidebar.winfo_reqheight()
        for h in (1000, 1100, 1200, 1300, 1400, 1500, 1600, 1800, 2000):
            app.root.geometry("1280x%d" % h)
            app.root.update()
            if cv.winfo_height() >= need + 20:
                break
        if app.sidebar_overflow() != 0:
            # 窗口顶到阶梯上限（或屏幕真的放不下）→ 这一条**没法验**，明说一句。
            print("  [skip] %s 的表单 %dpx 装不进面板 %dpx（这台机器的窗口高度不够）"
                  % (label, need, cv.winfo_height()))
            return False
        eq(app.sidebar_overflow(), 0,
           "（前提）%s 的表单（%dpx）装得进面板（%dpx）" % (label, need, cv.winfo_height()))
        return True

    # ---- A0. 单位页那一张在 1080p 上**真的装不下**（本轮数据 +1 行「视野半径」之后）----
    #
    # 实测（1280×1048 的窗口 = 一台 1080p 机器能给到的最大高度）：
    #     长枪兵表单 1032px  /  可用的侧边栏视口 978px  → 溢出 54px
    # 这**不是**回归：建筑页那三张（1725 / 1725 / 1262px）早就装不下、一直在滚。
    #
    # ⚠️ 这里判的是**表单本身比 1080p 的侧边栏视口还高**（只跟表单有关，与窗口/屏幕无关），
    #    **不是**「本机此刻溢出 > 0」—— 后者只对屏幕高约 1080 的机器成立：屏幕更高时
    #    窗口真能长到 2000px，这张表单就装得下了（实测 1920×1200 的机器上溢出 0，
    #    原来那条硬判红的断言就是这么假红的）。「装不下 → 滚得动、但滚不出范围」
    #    由下面 B 节**压矮窗口**来验，那一条不依赖屏幕。
    app.set_page("unit")
    app.root.update()
    pick(app, "u:spearman")
    app.root.update()
    need = app.sidebar.winfo_reqheight()
    ok(need > 978,
       "★ 单位页（长枪兵）的表单（%dpx）比 1080p 的侧边栏视口（978px）还高 —— 与建筑页一样要能滚"
       % need)
    app.root.geometry("1280x2000")               # 尽量拉高（1080p 的屏幕会把它夹到 1048）
    app.root.update()
    if app.sidebar_overflow() == 0:
        print("  [skip] 本机屏幕高 %d，窗口拉高之后这张表单装得下（溢出 0）——"
              "「装不下时能滚」由下面 B 节验" % app.root.winfo_screenheight())

    # ---- A. 内容装得下 → 一律钉在顶部（用户报的那个 bug）----
    #
    # ★★ 2026.11：原来这里拿**科技页**那张短表单来验（它是唯一在 1080p 下装得下的）。
    #   科技页删掉之后改用**「什么都没选」的空表单**：它比任何一张真表单都短，
    #   而走的还是同一段滚动逻辑（`_pin_sidebar_top` / `sidebar_yview` / `_on_wheel`）。
    app.set_page("unit")
    app.selection = None
    app.refresh_all()
    app.root.update()
    app.root.geometry("1280x1040")               # 1080p 机器能给到的最大高度
    app.root.update()
    ok(app.sidebar_overflow() == 0,
       "★ 空表单（什么都没选）在 1080p 下装得下（溢出 %d px）" % app.sidebar_overflow())
    eq(offset(), 0.0, "空表单：刚进来时在顶部")
    app.sidebar_yview("scroll", 5, "units")
    eq(offset(), 0.0, "★★ 空表单：装得下时向下滚 → 一动不动")
    # 向上滚：不许动 ← **这就是用户看到的「上方出现大量空白」**
    app.sidebar_yview("scroll", -5, "units")
    eq(offset(), 0.0, "★★ 空表单：装得下时向上滚 → 一动不动（**用户报的那个 bug**）")
    app.sidebar_yview("moveto", 0.9)
    eq(offset(), 0.0, "★★ 空表单：拖滚动条也不动")
    app.sidebar_yview("moveto", 0.0)
    eq(tuple(app.sidebar_scroll.get()), (0.0, 1.0),
       "★ 空表单：滚动条滑块铺满滑槽（看着就是不可滚）")
    app._on_wheel(FakeEvent(cv, delta=-120))
    eq(offset(), 0.0, "空表单：滚轮向下也不动")
    app._on_wheel(FakeEvent(cv, delta=120))
    eq(offset(), 0.0, "空表单：滚轮向上也不动")

    # ---- B. 内容真的装不下 → 滚动照旧可用，但**滚不出范围** ----
    app.set_page("unit")                         # 上一节停在科技页（列表是另一棵）
    app.root.update()
    pick(app, "u:spearman")                      # 长枪兵那张最长（1032px）
    app.root.geometry("1280x600")                # 压矮窗口，制造「装不下」
    app.root.update()
    ok(app.sidebar_overflow() > 0,
       "★ 窗口压矮之后长枪兵表单装不下（溢出 %d px）" % app.sidebar_overflow())
    app.sidebar_yview("scroll", 3, "units")
    ok(offset() > 0.0, "★ 装不下时向下滚**能动**（实际偏移 %.0f）" % offset())
    app.sidebar_yview("scroll", 50, "units")     # 滚过头
    ok(offset() <= float(app.sidebar_overflow()) + 1.0,
       "★★ 滚过头被夹在「内容底部」（偏移 %.0f ≤ 溢出 %d）"
       % (offset(), app.sidebar_overflow()))
    app.sidebar_yview("scroll", -50, "units")    # 往回滚过头
    eq(offset(), 0.0, "★★ 往回滚过头夹在顶部（偏移不为负 = 上方不留空白）")

    # 窗口重新拉高 → 偏移当场被夹回顶部（不然会停在下面露空白）
    app.sidebar_yview("scroll", 3, "units")
    ok(offset() > 0.0, "（前提）先滚下去一点")
    for h in (1000, 1100, 1200, 1300, 1400, 1500, 1600, 1800, 2000):
        app.root.geometry("1280x%d" % h)
        app.root.update()
        if app.sidebar_overflow() == 0:
            break
    if app.sidebar_overflow() == 0:
        eq(offset(), 0.0, "★★ 拉高窗口之后偏移自动回到顶部")
    else:
        print("  [skip] 这台机器的窗口高度不够，装不下这一张表单（溢出 %d px）"
              % app.sidebar_overflow())

    # ---- C. 用「把画布内容强行拉长」再造一次溢出（不依赖窗口大小，稳）----
    app.sidebar_canvas.itemconfigure(app._sidebar_item, height=3000)
    app.sidebar.update_idletasks()
    app.root.update()
    ok(app.sidebar_overflow() > 0, "（前提）内容被拉长到 3000px，确实装不下")
    app.sidebar_yview("scroll", -50, "units")
    eq(offset(), 0.0, "★★ 长内容往回滚过头也夹在顶部")
    app.sidebar_yview("scroll", 500, "units")
    ok(offset() <= float(app.sidebar_overflow()) + 1.0,
       "★★ 长内容向下一路滚到头（偏移 %.0f ≤ 溢出 %d）" % (offset(), app.sidebar_overflow()))
    app.sidebar_canvas.itemconfigure(app._sidebar_item, height=0)   # 0 = 交还给布局
    app.sidebar.update_idletasks()
    app.root.update()
    app.root.withdraw()                          # 收工，别把窗口留在屏幕上


def t_refresh_keeps_scroll(app, model) -> None:
    """★★ 改一个数值不能把侧边栏滚回顶部、也不能把选中项弄丢。

    用户报的「所有 UI 回到初始位置」：以前每次改值都整块重建列表 + 侧边栏，
    侧边栏固定 `moveto(0)`，而且重建列表的 `selection_set()` 会延迟触发
    `<<TreeviewSelect>>` → 再重建一次。这里钉住修完后的行为。
    """
    print("\n[9] ★★ 改数值只更新数据：侧边栏滚动位置留在原地")
    app.set_page("unit")
    tree = app.unit_tree
    tree.selection_set("u:spearman")

    class _Ev:
        widget = tree

    app._on_list_select(_Ev())
    app.root.update()
    eq(app.selection, ("unit", "spearman"), "（前提）选中长枪兵")
    try:
        app.sidebar_canvas.configure(height=240)
        app.root.update()
    except tk.TclError:
        pass
    if app.sidebar_overflow() <= 0:
        ok(True, "（这台机器上长枪兵表单装得下，跳过滚动断言）")
        return
    # 滚到「内容底部」：无头窗口的 canvas 高度不一定听 configure 的，所以按
    # 实际溢出量滚，而不是假设一个像素偏移。
    app.sidebar_yview("scroll", 100000, "units")
    app.root.update()
    before = app.sidebar_canvas.canvasy(0.0)
    ok(before > 0, "（前提）先把长枪兵表单滚下去（偏移 %d）" % before)
    app._mutate("改血量", lambda: app.model.set_unit("spearman", "hp_max", 222))
    app.root.update()
    after = app.sidebar_canvas.canvasy(0.0)
    # 无头窗口的视口高度可能在 update 后变化；能保住的是「不回到 0」，
    # 且最多被夹到当前内容底部（与 sidebar_yview 的夹值同一条）。
    eq(after, min(before, float(app.sidebar_overflow())),
       "★★ 改一个数值不会把侧边栏滚回顶部（偏移 %d）" % after)
    eq(app.selection, ("unit", "spearman"), "★★ 改完选中项还在")


def t_layout_fits(app, model) -> None:
    """★★ 2026.11.3：默认 1280×820 下，**操作栏与状态栏必须看得见**。

    这一条是为一个很隐蔽的回归加的：单位页左下现在有**四栏列表**（兵种 / 将领 /
    将领特性池 / 组合招募单）。Tk 的 pack 是「先到先得」——请求高度总和超过窗口时，
    **后面摆的那块会被压成 0 高**，而且不报错。加「将领特性池」那一轮实测：
    root 请求高度 920 > 820 ⇒ 左下那四颗按钮整排消失、状态栏只剩 1px。

    修法：① 操作栏 / 状态栏**先摆**（`_build_widgets`），列表后摆；② 四张列表各减
    一两行（7 / 3 / 3 / 2），整窗请求高度回到 790 < 820。
    """
    print("\n[10] 默认窗口里操作栏 / 状态栏看得见（四栏列表别把窗口撑爆）")
    app.root.deiconify()
    app.set_page("unit")
    app.selection = None
    app.refresh_all()
    app.root.geometry("1280x820")
    app.root.update()

    req = app.root.winfo_reqheight()
    ok(req <= 820,
       "★★ 单位页整窗请求高度 %d ≤ 默认窗口 820（四栏列表 + 操作栏 + 状态栏）" % req)

    bar = app.action_bar
    ok(bar.winfo_height() >= bar.winfo_reqheight(),
       "★★ 操作栏没被挤没（高 %d / 需要 %d）" % (bar.winfo_height(), bar.winfo_reqheight()))
    buttons = [w for w in walk(bar) if isinstance(w, tk.Button)]
    ok(len(buttons) >= 4,
       "★ 操作栏有四颗按钮（新建兵种 / 删除兵种 / 新建特性 / 删除特性）：%s"
       % [b.cget("text") for b in buttons])

    status = None
    for widget in app.root.winfo_children():
        if isinstance(widget, tk.Label) and str(widget.cget("textvariable")) == str(app.status_var):
            status = widget
    ok(status is not None, "找得到状态栏那个 Label")
    if status is not None:
        ok(status.winfo_height() >= status.winfo_reqheight(),
           "★★ 状态栏没被挤成一条线（高 %d / 需要 %d）"
           % (status.winfo_height(), status.winfo_reqheight()))
        ok(status.winfo_y() + status.winfo_height() <= app.root.winfo_height() + 1,
           "★ 状态栏整个在窗口里（底边 %d ≤ 窗口高 %d）"
           % (status.winfo_y() + status.winfo_height(), app.root.winfo_height()))
    app.root.withdraw()


def main() -> int:
    print("DAEEM 单位编辑器 · 界面测试")
    print("配置文件：%s（改的是 .tmp_unit_editor_app_test 里的副本）" % CONFIG)
    # ★★ 兜底：这一套测试**只许动临时副本**，真配置必须一字未改
    #    （写这份文件的是编辑器自己，而手工试验很容易顺手写坏真文件 —— 本轮真发生过）。
    real_before = CONFIG.read_bytes()
    try:
        app, model, path = setup()
    except tk.TclError as exc:                          # pragma: no cover
        print("  [skip] 这台机器起不了 Tk 窗口：%s" % exc)
        print("\n[CASE] test_app -> passed 0 / failed 0 (skipped)")
        return 0
    try:
        t_window(app, model)
        t_unit_form(app, model)
        t_package_form(app, model)
        t_general_form(app, model)
        t_traits(app, model)
        t_building_form(app, model)
        t_tech_page_gone(app, model)
        t_undo_save(app, model, path)
        t_add_remove(app, model)
        t_sidebar_scroll(app, model)
        t_refresh_keeps_scroll(app, model)
        t_layout_fits(app, model)
    finally:
        teardown(app)
        shutil.rmtree(TMP, ignore_errors=True)
    ok(CONFIG.read_bytes() == real_before,
       "★★ 真配置（%s）在整个测试过程中一字未改（测试只动 .tmp_unit_editor_app_test）"
       % CONFIG.name)
    print("\n[CASE] test_app -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
