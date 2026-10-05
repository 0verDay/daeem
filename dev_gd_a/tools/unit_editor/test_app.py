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
    6. 科技：名字与加成数值；加成可以加一条、删一条
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
                      getattr(app, "building_tree", None), getattr(app, "tech_tree", None)):
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
    eq(list(app.tab_buttons.keys()), ["unit", "building", "tech"], "三个页签：单位 / 建筑 / 科技")
    eq(app.tab_buttons["unit"].cget("fg"), app_module.UI["accent"], "当前页签是强调色")
    eq(app.tab_buttons["building"].cget("fg"), app_module.UI["text_dim"], "其它页签是暗色")

    eq(list(app.unit_tree.get_children()), ["u:spearman", "u:longbowman", "u:rider"],
       "兵种列表：三个单位类型（★ 本次：「测试敌人」已从编辑器移除）")
    eq(list(app.general_tree.get_children()), ["g:0", "g:1", "g:2"], "将领列表：三位")
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
    eq(list(app.building_tree.get_children()), ["b:wall", "b:tower", "b:base"],
       "建筑列表：三个（没有区划中心）")
    app.set_page("tech")
    app.root.update()
    eq(len(app.tech_tree.get_children()), 9, "科技列表：九条")
    eq(app.tech_tree.item("t:0", "values")[2], "粮食产量 +1", "列表里有加成那句话")
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
                  "造价 · 粮食", "造价 · 黄金", "造价 · 人口", "招募时间"):
        ok(label in entries, "表单里有「%s」那一行" % label)
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
    type_into(app, sidebar_entries(app)["招募时间"], "12")
    eq(data(model)["recruit"]["list"][0]["train_sec"], 12, "改招募时间")

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
    btn.invoke()
    app.root.update()
    eq(len(data(model)["recruit"]["list"]), 4, "点一下 → 加进招募表")
    eq(data(model)["recruit"]["list"][3]["kind"], "skeleton", "新那一条的 kind = skeleton")


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

    # 名字 / 造价 / 招募时间
    type_into(app, E(app, "名字"), "西境骑将")
    eq(data(model)["unit"]["general"]["stats"][0]["name"], "西境骑将", "改将领名字")
    eq(data(model)["recruit"]["zone"]["list"][0]["label"], "西境骑将", "★ 招募卡标题同步")
    type_into(app, E(app, "招募时间"), "14")
    eq(data(model)["recruit"]["zone"]["list"][0]["train_sec"], 14, "改将领招募时间")
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


# ======================================================================
# [4] 建筑表单
# ======================================================================

def t_building_form(app, model) -> None:
    print("\n[4] 建筑表单")
    app.set_page("building")
    app.root.update()
    pick(app, "b:wall")
    entries = sidebar_entries(app)
    for label in ("名称", "建造时间", "造价 · 粮食", "造价 · 黄金", "血量", "本体大小", "视野半径"):
        ok(label in entries, "建筑表单里有「%s」" % label)
    ok("攻击力" not in entries, "★ 城墙「不可攻击」→ 攻击三行收起来了")

    type_into(app, E(app, "建造时间"), "6")
    eq(data(model)["building"]["wall"]["build_sec"], 6, "★ 改建造时间")
    type_into(app, sidebar_entries(app)["视野半径"], "7")
    eq(data(model)["building"]["wall"]["vision"], 7,
       "★★ 改建筑视野 → 落在 building.wall.vision（每个类型自己一个值）")
    eq(app.building_tree.item("b:wall", "values")[bcols()["vision"]], "7", "列表里的视野刷新了")
    type_into(app, sidebar_entries(app)["血量"], "500")
    eq(data(model)["building"]["wall"]["hp_max"], 500, "改血量")
    type_into(app, sidebar_entries(app)["名称"], "石墙")
    eq(data(model)["building"]["wall"]["name"], "石墙", "改名称")
    eq(app.building_tree.item("b:wall", "values")[0], "石墙", "列表里的名字刷新了")
    type_into(app, sidebar_entries(app)["快捷键"], "W")
    eq(data(model)["building"]["wall"]["hotkey"], "W", "改建造页快捷键")
    type_into(app, sidebar_entries(app)["造价 · 黄金"], "25")
    eq(data(model)["building"]["wall"]["cost"]["gold"], 25, "改建筑造价")

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

    # 升级表（★ 按「节 + 标签」定位：同名的行在三级里各有一份）
    type_into(app, E_in(app, "升到 2 级", "需要的价格 · 粮食"), "80")
    eq(data(model)["upgrade"]["levels"]["wall"][1]["cost"]["food"], 80, "★ 升 2 级的价格（粮食）")
    type_into(app, E_in(app, "升到 2 级", "需要的价格 · 黄金"), "90")
    eq(data(model)["upgrade"]["levels"]["wall"][1]["cost"]["gold"], 90, "升 2 级的价格（黄金）")
    type_into(app, E_in(app, "升到 2 级", "需要的读条时间"), "12")
    eq(data(model)["upgrade"]["levels"]["wall"][1]["time_sec"], 12, "升 2 级的读条时间")
    type_into(app, E_in(app, "升到 2 级", "血量倍率"), "1.8")
    eq(data(model)["upgrade"]["levels"]["wall"][1]["hp_mult"], 1.8, "★ 升 2 级的血量倍率")
    eq(data(model)["upgrade"]["levels"]["wall"][0]["hp_mult"], 1.0, "★ 1 级那一行没被动过")
    type_into(app, E_in(app, "升到 3 级", "需要的价格 · 粮食"), "150")
    eq(data(model)["upgrade"]["levels"]["wall"][2]["cost"]["food"], 150, "★ 升 3 级的价格")

    # 逐级攻击：自定 / 跟随（用的是「跟随基础值」那套可选行）
    set_optional_at(app, "升到 2 级", "攻击力", "20")
    rows = data(model)["upgrade"]["levels"]["wall"]
    eq(rows[1]["damage"], 20, "★★ 2 级可以有自己的攻击力")
    eq(data(model)["building"]["wall"]["damage"], 9, "★ 基础攻击力没被动过")
    follow_optional_at(app, "升到 2 级", "攻击力")
    rows = data(model)["upgrade"]["levels"]["wall"]
    ok(not any(k in rows[1] for k in ("damage", "range", "cooldown")),
       "★★ 点「跟随」→ 覆盖被删掉（回到沿用基础值）")
    eq(E_in(app, "升到 2 级", "攻击力").get(), "9", "输入框回到基础值 9")

    # 箭塔：默认就能攻击，升级表里直接有攻击三行
    pick(app, "b:tower")
    entries = sidebar_entries(app)
    ok("攻击力" in entries, "箭塔默认就有攻击力那一行")
    eq(E(app, "攻击力").get(), "12", "显示 12")
    ok("可攻击" in sidebar_checks(app), "有「可攻击」勾选框")
    eq(sidebar_checks(app)["可攻击"].instate(["selected"]), True, "★ 箭塔默认是勾上的")


# ======================================================================
# [5] 科技表单
# ======================================================================

def t_tech_form(app, model) -> None:
    print("\n[5] 科技表单")
    app.set_page("tech")
    app.root.update()
    pick(app, "t:0")
    entries = sidebar_entries(app)
    ok("名称" in entries and "第二行小字" in entries and "说明" in entries, "文案三件套")
    ok("粮食产量" in entries, "★ 有「粮食产量」这一条加成的输入框")
    ok("黄金产量" in entries, "★ 没有的加成也列出来（填数字 = 加上它）")

    type_into(app, E(app, "名称"), "粮食产量 甲")
    eq(data(model)["tech"]["list"][0]["name"], "粮食产量 甲", "改科技名称")
    eq(app.tech_tree.item("t:0", "values")[0], "粮食产量 甲", "列表刷新")
    type_into(app, sidebar_entries(app)["第二行小字"], "粮食 +++")
    eq(data(model)["tech"]["list"][0]["line"], "粮食 +++", "改第二行小字")
    type_into(app, sidebar_entries(app)["粮食产量"], "2.5")
    eq(data(model)["tech"]["list"][0]["effect"]["food_per_tile_per_sec"], 2.5, "★ 改加成数值")
    eq(app.tech_tree.item("t:0", "values")[2], "粮食产量 +2.5", "列表里的加成跟着变")

    # 加一条原来没有的加成
    type_into(app, sidebar_entries(app)["黄金产量"], "3")
    eq(data(model)["tech"]["list"][0]["effect"]["gold_per_tile_per_sec"], 3,
       "★ 填一个数 = 加上这条加成")
    # 删一条
    btn = buttons(app).get("删掉这条")
    ok(btn is not None, "有「删掉这条」按钮")
    btn.invoke()
    app.root.update()
    eq(list(data(model)["tech"]["list"][0]["effect"].keys()), ["gold_per_tile_per_sec"],
       "★ 删掉第一条加成（粮食那条没了）")

    # 「最多启用几条」
    app.max_active_var.set("2")
    app._commit_max_active()
    app.root.update()
    eq(data(model)["tech"]["max_active"], 2, "改「同一时间最多启用几条」")
    app.max_active_var.set("abc")
    app._commit_max_active()
    app.root.update()
    eq(data(model)["tech"]["max_active"], 2, "★ 非法输入被拒，原值不动")


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
    eq(len(data(model)["upgrade"]["levels"]["outpost"]), 3, "★ 连带一张 3 级升级表")
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
    # ★★ 用**科技页**那张短表单来验这一条：它是这个工具里唯一在 1080p 下装得下的
    #    （建筑页 / 单位页那几张都装不下，拿它们验只会验出一个假红）。
    app.set_page("tech")
    app.root.update()
    if grow_until_fits("t:0", "科技 1"):
        eq(offset(), 0.0, "科技 1：刚选中时在顶部")
        app.sidebar_yview("scroll", 5, "units")
        eq(offset(), 0.0, "★★ 科技 1：装得下时向下滚 → 一动不动")
        # 向上滚：不许动 ← **这就是用户看到的「上方出现大量空白」**
        app.sidebar_yview("scroll", -5, "units")
        eq(offset(), 0.0, "★★ 科技 1：装得下时向上滚 → 一动不动（**用户报的那个 bug**）")
        app.sidebar_yview("moveto", 0.9)
        eq(offset(), 0.0, "★★ 科技 1：拖滚动条也不动")
        app.sidebar_yview("moveto", 0.0)
        eq(tuple(app.sidebar_scroll.get()), (0.0, 1.0),
           "★ 科技 1：滚动条滑块铺满滑槽（看着就是不可滚）")
        app._on_wheel(FakeEvent(cv, delta=-120))
        eq(offset(), 0.0, "科技 1：滚轮向下也不动")
        app._on_wheel(FakeEvent(cv, delta=120))
        eq(offset(), 0.0, "科技 1：滚轮向上也不动")

        eq(offset(), 0.0, "★★ 将领 2 滚轮向上也不动")

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
        t_general_form(app, model)
        t_building_form(app, model)
        t_tech_form(app, model)
        t_undo_save(app, model, path)
        t_add_remove(app, model)
        t_sidebar_scroll(app, model)
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
