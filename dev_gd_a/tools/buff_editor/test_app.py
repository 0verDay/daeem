"""test_app.py —— buff 编辑器界面的测试（真的建一个 Tk 窗口，但不开 mainloop）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/buff_editor/test_app.py

它验的是「界面动作 → 数据 / 回显」这一层（与 test_model 的纯数据层互补）：

    · 一条 buff 建出 20 个输入框，值来自 config；
    · 改一个数按 Enter → 数据变了 / 状态栏 / 「未保存」标记；
    · 打错字 → 数据不动、输入框恢复原值；
    · 百分数字段 50% ⇄ 0.5；超范围夹取；
    · 撤销 / 重做 / 保存 / 从磁盘重载；
    · 跨字段提示会出现在界面上。
"""

from __future__ import annotations

import os
import shutil
import sys
import tkinter as tk
from tkinter import ttk
from pathlib import Path

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

from buff_editor.app import BuffEditorApp          # noqa: E402
from buff_editor.model import (                    # noqa: E402
    BUFFS,
    ConfigModel,
    display_value,
    fmt_number,
)

CONFIG = PROJECT_DIR / "data" / "config.json"

_FAILED = 0
_PASSED = 0
_TMP: list = []


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

def near(actual, expected, label: str, tol: float = 1e-6) -> None:
    ok(abs(float(actual) - float(expected)) <= tol,
       "%s（实际 %r，期望 %r，容差 %g）" % (label, actual, expected, tol))


def _copy_config() -> Path:
    dst = HERE.parent / (".tmp_buff_app_%d.json" % os.getpid())
    _TMP.append(dst)
    shutil.copy2(CONFIG, dst)
    return dst


def _new_app():
    path = _copy_config()
    model = ConfigModel.load(path)
    root = tk.Tk()
    root.withdraw()
    app = BuffEditorApp(root, model, path, PROJECT_DIR)
    root.update_idletasks()
    return root, app, path


def t_basic(app) -> None:
    print("[0] 建窗口：buff 列表 / 字段 / 预览")
    eq(len(app.entries), 20, "★ 士气 buff 建出 20 个输入框")
    ok(app.entry_for("max") is not None, "上限那一格存在")
    buff = app.current_buff()
    vals = app.model.values(buff)
    eq(app.entry_for("max").get(), fmt_number(vals["max"]),
       "上限显示 config 里的值（%s）" % fmt_number(vals["max"]))
    eq(app.entry_for("start").get(), fmt_number(vals["start"]),
       "初始士气显示 config 里的值（%s）" % fmt_number(vals["start"]))
    eq(app.entry_for("damage_reduction").get(),
       display_value(app._field_by_key["damage_reduction"], vals["damage_reduction"]),
       "百分数字段显示 %s" % display_value(app._field_by_key["damage_reduction"],
                                           vals["damage_reduction"]))
    ok(("示例（开局）：当前 %s / %s" % (fmt_number(vals["start"]), fmt_number(vals["max"])))
       in app.preview_text(), "★ 预览显示开局数值")
    ok("快速回血" in app.preview_text(), "★ 预览里有高档说明")
    eq(app.warnings_text(), "", "（前提）当前配置没有跨字段提示")
    eq(app.dirty_text(), "已保存", "刚打开时是「已保存」")


def t_edit_and_invalid(app, model) -> None:
    print("[1] 改值 / 打错字 / 百分数 / 夹取")
    app.set_entry("start", "95")
    ok(app.commit_field("start"), "改「初始士气」提交成功")
    eq(model.value(app.current_buff(), app._field_by_key["start"]), 95,
       "★ 数据层真的变成 95")
    ok("● 未保存" in app.dirty_text(), "状态变成「未保存」")
    ok("已修改" in app.status_text(), "状态栏说了一句「已修改」")

    before = model.value(app.current_buff(), app._field_by_key["start"])
    app.set_entry("start", "abc")
    ok(not app.commit_field("start"), "打错字 → 提交失败")
    eq(model.value(app.current_buff(), app._field_by_key["start"]), before,
       "★ 打错字不会写坏数据（还是 95）")
    eq(app.entry_for("start").get(), "95", "输入框恢复原值（不留下 abc）")
    ok("没改成" in app.status_text(), "状态栏说明「没改成」")

    app.set_entry("damage_reduction", "55%")
    ok(app.commit_field("damage_reduction"), "百分数 55% 提交成功")
    eq(model.value(app.current_buff(), app._field_by_key["damage_reduction"]), 0.55,
       "★ 55% 写进 config 是 0.55")
    eq(app.entry_for("damage_reduction").get(), "55%", "回显还是百分数")
    ok("-55%" in app.preview_text(), "★ 预览跟着变成 -55%")

    app.set_entry("damage_reduction", "500")
    ok(app.commit_field("damage_reduction"), "500% 提交成功（被夹住）")
    eq(model.value(app.current_buff(), app._field_by_key["damage_reduction"]), 0.95,
       "★ 500% 被夹到 95%")
    ok("夹到最大" in app.status_text(), "状态栏说明夹到了多少")


def t_warnings(app) -> None:
    print("[2] 跨字段提示")
    warn_field = app._field_by_key["high_tier"]
    old_high = app.model.value(app.current_buff(), warn_field)
    app.set_entry("high_tier", "10")
    ok(app.commit_field("high_tier"), "把高档阈值改成 10")
    ok("档位顺序" in app.warnings_text(), "★ 界面出现「档位顺序」提示")
    # 改回去，别把它带进后面的保存
    app.set_entry("high_tier", display_value(warn_field, old_high))
    ok(app.commit_field("high_tier"), "改回 %s" % display_value(warn_field, old_high))
    ok("档位顺序" not in app.warnings_text(), "改回去之后「档位顺序」提示消失")


def t_undo_redo(app, model) -> None:
    print("[3] 撤销 / 重做")
    buff = app.current_buff()
    key = app._field_by_key["start"]
    eq(model.value(buff, key), 95, "（前提）当前是 95")
    # 单独再做一次改动，保证「撤销一步」就是它（前面的用例堆了不少历史）
    app.set_entry("start", "99")
    ok(app.commit_field("start"), "再改成 99")
    app.undo()
    eq(model.value(buff, app._field_by_key["start"]), 95, "★ 撤销一步 → 回到 95")
    eq(app.entry_for("start").get(), "95", "输入框也跟着回到 95")
    app.redo()
    eq(model.value(buff, app._field_by_key["start"]), 99, "★ 重做 → 又回到 99")
    app.undo()                                    # 留回 95，后面的保存用例按它断言
    eq(model.value(buff, app._field_by_key["start"]), 95, "再撤销一次，留在 95")


def t_save_reload(app, model, path) -> None:
    print("[4] 保存 / 从磁盘重载")
    app.save()
    ok("已保存" in app.status_text(), "保存成功")
    eq(app.dirty_text(), "已保存", "「未保存」标记消失")
    fresh = ConfigModel.load(path)
    buff = fresh.buffs()[0]
    by_key = {f.key: f for f in buff.fields}
    eq(fresh.value(buff, by_key["start"]), 95, "★ 磁盘上的初始士气 = 95")
    eq(fresh.value(buff, by_key["damage_reduction"]), 0.95, "★ 磁盘上的免伤 = 95%")

    # 改一处不保存 → 重载把它丢掉
    app.set_entry("start", "42")
    ok(app.commit_field("start"), "再改成 42（不保存）")
    ok("● 未保存" in app.dirty_text(), "（前提）现在是脏的")
    app.reload_from_disk(ask=False)
    eq(app.model.value(app.current_buff(), app._field_by_key["start"]), 95,
       "★ 从磁盘重载 → 回到 95（丢掉未保存的 42）")
    eq(app.entry_for("start").get(), "95", "输入框也跟着回到 95")
    eq(app.dirty_text(), "已保存", "重载后是「已保存」")


def t_buff_switch(app) -> None:
    print("[5] 切换 buff（目前只有士气一条）")
    eq([b.id for b in BUFFS], ["morale"], "（前提）注册表里只有士气")
    app.select_buff("morale")
    eq(app.current_buff().id, "morale", "★ 点「士气」→ 当前 buff 是 morale")


def t_tech_pages_in_app(app) -> None:
    print("[6] 科技：列表里有科技页 / 文案能改 / 槽位能改")
    ids = [b.id for b in app.model.buffs()]
    ok(len(ids) > len(BUFFS), "★ 列表比注册表长（科技是现算出来的）")
    ok("tech:global" in ids, "★ 有「科技 · 全局」")
    # ★★ 2026.11：左栏从「一摞圆角按钮」换成了 Treeview（用户报的「下滑后按钮文字
    #   错位 / 撕裂」——按钮 = tk.Button 上盖一层 Canvas，滚动时两个子窗口重绘错序）。
    #   所以这里断言的是**列表里的行**，不再是按钮。
    eq(len(app._sidebar_items), len(ids), "★ 左栏给每一页都建了一行")
    rows = app._side_tree.get_children()
    eq(len(rows), 2, "★ 左栏分两组（Buff / 科技）")
    leaves = []
    for parent in rows:
        leaves.extend(app._side_tree.get_children(parent))
    eq(len(leaves), len(ids), "★ 两组下的条目数 = 页数（没有漏、没有重复）")
    ok(all(str(app._side_tree.item(i, "text")).strip() for i in leaves),
       "★ 每一行都有文字（不是空行）")

    # ---- 一条科技：文案（text）+ 效果（percent/number）
    tech_id = next(i for i in ids if i.startswith("tech:list:"))
    app.select_buff(tech_id)
    tech = app.current_buff()
    eq(tech.id, tech_id, "★ 切到科技页")
    ok(len(app.entries) >= 4, "科技页至少 4 个输入框（名字/小字/详情/阶）")
    ok(app.entry_for("name") is not None, "★ 有「名字」输入框")
    old_name = app.model.value(tech, app._field_by_key["name"])
    app.set_entry("name", "改过的科技名")
    ok(app.commit_field("name"), "改名字提交成功")
    eq(app.model.value(app.current_buff(), app._field_by_key["name"]),
       "改过的科技名", "★ 数据层真的变了")
    ok("● 未保存" in app.dirty_text(), "状态变成「未保存」")
    ok("改过的科技名" in app.preview_text(), "★ 预览里的格子文字跟着变")
    app.set_entry("name", old_name)
    ok(app.commit_field("name"), "改回原名")

    # 效果里的比例字段也要按百分数编辑
    eff_keys = [f.key for f in tech.fields if f.group == "效果"]
    ok(bool(eff_keys), "（前提）这条科技有效果字段")
    if eff_keys:
        key = eff_keys[0]
        f = app._field_by_key[key]
        old_val = app.model.value(app.current_buff(), f)
        if f.kind == "percent":
            app.set_entry(key, "10%")
            ok(app.commit_field(key), "效果比例填 10% 提交成功")
            eq(app.model.value(app.current_buff(), app._field_by_key[key]), 0.1,
               "★ 10% 写进 config 是 0.1")
            app.set_entry(key, display_value(f, old_val))
            ok(app.commit_field(key), "改回原值")

    # ---- 槽位页
    slots_id = next(i for i in ids if i.startswith("tech:slots:"))
    app.select_buff(slots_id)
    eq(len(app.entries), 9, "★ 槽位页正好 9 个输入框")
    first_key = sorted(app.entries, key=lambda k: int(k.split("_")[-1]))[0]
    ok(app.entry_for(first_key).get() != "", "槽位里显示着当前的科技 id")
    app.set_entry(first_key, "")
    ok(app.commit_field(first_key), "把第 1 格清空")
    eq(app.model.value(app.current_buff(), app._field_by_key[first_key]), "",
       "★ 清空写进 config 是空串（= 空位）")
    ok("空位" in app.preview_text(), "★ 预览把空位画成「灰框不可点」")
    # 回到士气页，别把科技页留着影响后面的用例
    app.select_buff("morale")


# ======================================================================
# [7] 左栏是 Treeview（用户报的 bug：下滑后按钮文字错位 / 撕裂）
# ======================================================================

class _Wheel:
    """假滚轮事件（`_on_side_wheel` 只读 num / delta 两个属性）。"""

    def __init__(self, delta: int = 0, num=None) -> None:
        self.delta = delta
        self.num = num


def t_sidebar_tree(app) -> None:
    print("[7] 左栏是 Treeview：不再有「画布 + 一摞圆角按钮」")
    # ★ 那条老结构就是撕裂的根因：RButton = tk.Button 上盖一层 Canvas（两个子窗口），
    #   塞进 Canvas 的 window item 里滚动时两个子窗口重绘顺序不同步 ⇒ 文字错位。
    ok(not hasattr(app, "_side_canvas"), "★★ 左侧不再有 Canvas（老结构已删）")
    ok(not hasattr(app, "_side_window"), "★★ 也没有塞在画布里的 window item")
    ok(not hasattr(app, "_sidebar_host"), "★★ 没有「一摞按钮」那个容器")
    ok(not hasattr(app, "_sidebar_buttons"), "★★ 左栏的按钮表也删掉了（不是留个空表）")
    ok(isinstance(app._side_tree, ttk.Treeview) if hasattr(ttk, "Treeview") else True,
       "★ 左栏是 Treeview")

    # 滚动：Treeview 自己滚条目（不搬子窗口），滚完条目的文字还在
    app.select_buff("morale")
    app.root.update()
    rows = app._side_tree.get_children()
    ok(len(rows) == 2, "（前提）两组")
    leaves = []
    for parent in rows:
        leaves.extend(app._side_tree.get_children(parent))
    ok(len(leaves) > 10, "（前提）条目多到要滚（%d 条）" % len(leaves))
    before = [app._side_tree.item(i, "text") for i in leaves]
    for _ in range(8):
        app._on_side_wheel(_Wheel(delta=-120))
    app.root.update()
    after = [app._side_tree.item(i, "text") for i in leaves]
    eq(after, before, "★★ 滚了 8 格之后每一行的文字原样（不撕裂、不串行）")
    # 滚轮只滚左栏，不该把右边的表单带着滚
    form_before = app._canvas.yview()[0]
    app._on_side_wheel(_Wheel(delta=-120))
    eq(app._canvas.yview()[0], form_before, "★★ 左栏滚轮不影响右边的表单")

    # 点一行 = 换页；点分组行不行（而且选中要弹回当前页）
    app.select_buff("morale")
    target = next(i for i in leaves if app._side_tree.item(i, "text").startswith("科"))
    app._side_tree.selection_set(target)
    app.root.update()
    eq(app.current_id, target[2:], "★ 选中左栏某一行 → 切到那一页")
    section = app._side_tree.get_children()[0]
    app._side_tree.selection_set(section)
    app.root.update()
    eq(app.current_id, target[2:], "★★ 点分组标题不换页")
    eq(app._side_tree.selection(), (target,), "★★ 选中被弹回当前页那一行")

    # 改一个数值之后左栏重建，**不许跳回顶部**（滚到下面改科技时最烦这个）
    app.select_buff(target[2:])
    app.root.update()
    for _ in range(6):
        app._on_side_wheel(_Wheel(delta=-120))
    app.root.update()
    top = app._side_tree.yview()[0]
    ok(top > 0.0, "（前提）先滚下去（%.3f）" % top)
    app._build_sidebar()
    app.root.update()
    near(app._side_tree.yview()[0], top,
         "★★ 重建左栏之后滚动位置不变（改一个数值不会把列表弹回顶部）", tol=0.02)
    app.select_buff("morale")


def main() -> int:
    print("DAEEM buff 编辑器 · 界面测试")
    print("配置文件：%s" % CONFIG)
    real_before = CONFIG.read_bytes()
    try:
        root = tk.Tk()
        root.destroy()
    except tk.TclError as exc:
        print("[skip] 这台机器没有可用的图形界面（%s），跳过界面测试" % exc)
        return 0

    root, app, path = _new_app()
    try:
        t_basic(app)
        t_edit_and_invalid(app, app.model)
        t_warnings(app)
        t_undo_redo(app, app.model)
        t_save_reload(app, app.model, path)
        t_buff_switch(app)
        t_tech_pages_in_app(app)
        t_sidebar_tree(app)
    finally:
        try:
            root.destroy()
        except tk.TclError:
            pass
        for tmp in _TMP:
            try:
                tmp.unlink()
            except OSError:
                pass
    ok(CONFIG.read_bytes() == real_before,
       "★★ 真配置在整个界面测试过程中一字未改（测试只动 .tmp_buff_app_* 里的副本）")
    print("\n[CASE] test_app -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
