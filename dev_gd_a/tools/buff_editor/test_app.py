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
