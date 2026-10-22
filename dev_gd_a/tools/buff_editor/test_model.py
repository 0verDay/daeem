"""test_model.py —— buff 编辑器数据层的无头测试（不需要图形界面）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/buff_editor/test_model.py

这个工具改的是**游戏唯一的一份数值表** `data/config.json`。写错一个键名，
游戏不会报错、只会静默用兜底值 —— 所以这里把四件事钉成断言：

    1. **原地最小改动**：没改就是逐字节原样；改一个数只多出一行 diff；改回来还原；
    2. **字段 → JSON 路径**：每个字段写到哪个键上；游戏侧真的读那几个键；
    3. **解析 / 夹取**：百分数字段 50 ⇄ 0.5；非法输入抛异常、不写坏数据；
    4. **跨字段提示 / 悬停文案**：档位顺序反了要提示；预览与 HUD 的文案口径一致。
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path
from typing import Dict, List

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

from buff_editor.model import (                     # noqa: E402
    BUFFS,
    GROUP_ORDER,
    ConfigModel,
    Field,
    ModelError,
    display_value,
    field_groups,
    fmt_number,
    parse_value,
)

CONFIG = PROJECT_DIR / "data" / "config.json"

_FAILED = 0
_PASSED = 0
_TMP: List[Path] = []


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


def near(actual, expected, label: str, tol: float = 1e-9) -> None:
    ok(abs(float(actual) - float(expected)) <= tol,
       "%s（实际 %r，期望 %r）" % (label, actual, expected))


def raises(fn, label: str, exc=ModelError) -> None:
    try:
        fn()
    except exc:
        ok(True, label)
        return
    except Exception as other:                             # noqa: BLE001
        ok(False, "%s（抛的是 %s: %s）" % (label, type(other).__name__, other))
        return
    ok(False, "%s（没有抛异常）" % label)


def _copy_config() -> Path:
    # ★ 临时文件放在**包目录下、但不再建子目录**：本仓库的测试可能在 DSH 的
    #   workspace-write 沙箱里跑，系统 %TEMP% 与「新建目录」都不保证可写，
    #   而工作区里直接建文件是允许的。
    dst = HERE.parent / (".tmp_buff_editor_%d.json" % os.getpid())
    _TMP.append(dst)
    shutil.copy2(CONFIG, dst)
    return dst


def _morale():
    return BUFFS[0]


# ----------------------------------------------------------------------
# [0] 原地最小改动
# ----------------------------------------------------------------------
def t_text_roundtrip() -> None:
    print("[0] 文本层：原地最小改动 / 尾逗号 / 坏 JSON")
    path = _copy_config()
    model = ConfigModel.load(path)

    before = model.text
    model.save(path)
    ok(path.read_bytes() == before.encode("utf-8"),
       "没改动就保存 == 原文件逐字节一致")

    field = _morale().fields[1]                        # start
    cfg_path = list(field.config_path(_morale()))
    original = model.doc.value(cfg_path)
    model.set_value(_morale(), field, original + 1)
    changed = model.text
    ok(changed != before, "改一个数 → 文本真的变了")

    a_lines, b_lines = before.splitlines(), changed.splitlines()
    eq(len(a_lines), len(b_lines), "改一个数不改变行数")
    diff = [i for i, (x, y) in enumerate(zip(a_lines, b_lines)) if x != y]
    eq(len(diff), 1, "改一个数只多出 1 行 diff（实际 %d 行）" % len(diff))

    model.doc.set(cfg_path, original)                  # 按原类型写回
    ok(model.text == before, "改回原值 → 与原文逐字节一致")

    # ★ 尾逗号：读的时候容忍、写出去是严格 JSON（与 unit_editor 同一套）
    tolerant = ConfigModel.from_text('{"a": 1, "b": [1, 2,],}')
    eq(tolerant.doc.value(["b"]), [1, 2], "读取容忍尾逗号（Godot 也容忍）")
    ok('"b": [1, 2]' in tolerant.text, "保存出去的是严格 JSON（尾逗号已被擦掉）")

    raises(lambda: ConfigModel.from_text('{"a": '), "坏 JSON → ModelError", ModelError)


# ----------------------------------------------------------------------
# [1] 字段表：路径 / 数量 / 分组
# ----------------------------------------------------------------------
def t_fields() -> None:
    print("[1] 字段表：每个字段都指向 config 里真实存在的数字")
    model = ConfigModel.load(_copy_config())
    buff = _morale()
    by_key = {f.key: f for f in buff.fields}
    expected = {
        "max", "start", "high_tier", "mid_tier", "vuln_tier", "low_tier",
        "hp_regen_high", "hp_regen_mid", "hp_decay_low", "hp_decay_zero", "hp_floor",
        "damage_reduction", "vulnerability", "damage_reduction_cap",
        "regen_ally", "decay_enemy", "decay_surrounded",
        "boost_kill", "boost_leader", "boost_capture",
    }
    keys = [f.key for f in buff.fields]
    eq(len(keys), len(set(keys)), "字段 key 没有重复")
    eq(set(keys), expected, "★ 士气 buff 的字段 = 19 个 morale 键 + 减伤封顶")
    eq(len(keys), 20, "一共 20 个可编辑数值")

    for f in buff.fields:
        node = model.doc.get(list(f.config_path(buff)))
        ok(node is not None, "%s 的路径存在（%s）"
           % (f.label, ".".join(str(p) for p in f.config_path(buff))))
        if node is not None:
            ok(isinstance(node.value, (int, float)), "%s 是数字" % f.label)
        ok(f.group in GROUP_ORDER, "%s 的分组在 GROUP_ORDER 里（%s）" % (f.label, f.group))

    groups = field_groups(buff)
    eq([g for g, _ in groups], list(GROUP_ORDER), "表单分组顺序 = GROUP_ORDER")
    eq(sum(len(fs) for _, fs in groups), len(buff.fields), "分组后一条字段都没丢")
    eq(model.summary(buff),
       "%s / %s" % (fmt_number(model.value(buff, by_key["start"])),
                    fmt_number(model.value(buff, by_key["max"]))),
       "列表短说明 = 初始 / 上限")


# ----------------------------------------------------------------------
# [2] 解析 / 夹取 / 百分数
# ----------------------------------------------------------------------
def t_parse() -> None:
    print("[2] 解析：百分数 50 ⇄ 0.5、夹取、非法输入")
    buff = _morale()
    by_key: Dict[str, Field] = {f.key: f for f in buff.fields}
    pct = by_key["damage_reduction"]
    num = by_key["hp_regen_high"]

    eq(display_value(pct, 0.5), "50%", "显示：0.5 → 50%")
    eq(display_value(pct, 0.125), "12.5%", "显示：0.125 → 12.5%")
    eq(display_value(num, 8), "8", "普通数字整数不带 .0")
    eq(display_value(num, 0.75), "0.75", "普通数字小数原样")

    eq(parse_value(pct, "50")[0], 0.5, "输入 50 → 写 0.5")
    eq(parse_value(pct, "50%")[0], 0.5, "输入 50% → 写 0.5")
    eq(parse_value(pct, "12.5")[0], 0.125, "输入 12.5 → 写 0.125")
    eq(parse_value(num, "0.75")[0], 0.75, "普通数字 0.75 → 0.75")
    v, note = parse_value(num, "-1")
    eq(v, 0.0, "负数被夹到最小 0")
    ok(note != "", "夹取时给一句提示")
    v, note = parse_value(pct, "500")
    eq(v, 0.95, "500% 被夹到 95%")
    ok(note != "", "百分数夹取也给提示")

    for bad in ("", "abc", "1..2", "nan", "inf"):
        raises(lambda b=bad: parse_value(num, b), "非法输入被拒：%r" % bad, ValueError)


# ----------------------------------------------------------------------
# [3] 跨字段提示 / 悬停文案
# ----------------------------------------------------------------------
def t_warnings_and_preview() -> None:
    print("[3] 跨字段提示 / 悬停浮窗文案")
    model = ConfigModel.load(_copy_config())
    buff = _morale()
    eq(model.warnings(buff), [], "（前提）当前配置没有跨字段提示")

    by_key = {f.key: f for f in buff.fields}
    old = model.value(buff, by_key["high_tier"])
    model.set_value(buff, by_key["high_tier"], 10)      # 低于中档 90
    warns = model.warnings(buff)
    ok(any("档位顺序" in w for w in warns), "高档阈值低于中档 → 提示「档位顺序」")
    model.set_value(buff, by_key["high_tier"], old)

    old = model.value(buff, by_key["start"])
    model.set_value(buff, by_key["start"], 200)
    ok(any("大于上限" in w for w in model.warnings(buff)), "初始士气 > 上限 → 提示")
    model.set_value(buff, by_key["start"], old)

    old = model.value(buff, by_key["damage_reduction"])
    model.set_value(buff, by_key["damage_reduction"], 0.9)
    ok(any("减伤封顶" in w for w in model.warnings(buff)), "免伤 > 封顶 → 提示")
    model.set_value(buff, by_key["damage_reduction"], old)

    preview = model.preview(buff)
    v = model.values(buff)
    start_line = "示例（开局）：当前 %s / %s" % (
        fmt_number(v["start"]), fmt_number(v["max"]))
    ok(preview.startswith(start_line), "★ 预览第一行 = %s" % start_line)
    ok(("≥%s：快速回血，受到伤害 -%d%%" % (
        fmt_number(v["high_tier"]), int(round(float(v["damage_reduction"]) * 100.0))))
       in preview, "★ 预览高档文案带免伤比例")
    ok(("≤%s：受到伤害 +%d%%" % (
        fmt_number(v["vuln_tier"]), int(round(float(v["vulnerability"]) * 100.0))))
       in preview, "★ 预览易伤档文案带易伤比例")
    ok(("≤%s：缓慢失去生命（0 时加快）" % fmt_number(v["low_tier"])) in preview,
       "★ 预览掉血档文案")

    model.set_value(buff, by_key["high_tier"], 80)
    ok("≥80：" in model.preview(buff), "改阈值后预览跟着变")


# ----------------------------------------------------------------------
# [4] 游戏侧真的读这些键
# ----------------------------------------------------------------------
def t_game_contract() -> None:
    print("[4] 游戏侧契约：config.gd 读的就是这些键")
    game = (PROJECT_DIR / "logic" / "config.gd").read_text(encoding="utf-8")
    buff = _morale()
    for f in buff.fields:
        path = list(f.config_path(buff))
        dotted = ".".join(str(p) for p in path)
        ok('"%s"' % dotted in game, "★ config.gd 里有 %s" % dotted)
    # 声望 / 生命 / 伤害文案在 hud 与 morale 里各读一次（改名会当场红）
    hud = (PROJECT_DIR / "view" / "hud.gd").read_text(encoding="utf-8")
    ok("morale_high_tier" in hud and "morale_damage_reduction" in hud,
       "hud.gd 的悬停文案读 morale 的档位与免伤")
    morale = (PROJECT_DIR / "logic" / "morale.gd").read_text(encoding="utf-8")
    ok("morale_regen_ally" in morale and "morale_hp_decay_zero" in morale,
       "morale.gd 读回升 / 掉血数值")


# ----------------------------------------------------------------------
# [5] 保存 / 重载 / 撤销
# ----------------------------------------------------------------------
def t_save_and_reload() -> None:
    print("[5] 保存 / 重载 / 撤销")
    path = _copy_config()
    model = ConfigModel.load(path)
    buff = _morale()
    by_key = {f.key: f for f in buff.fields}

    saved = model.text
    original_start = model.value(buff, by_key["start"])
    model.set_value(buff, by_key["start"], 95)
    ok(model.dirty, "改完是「脏」")
    model.save(path)
    ok(not model.dirty, "保存后不再脏")

    fresh = ConfigModel.load(path)
    eq(fresh.value(buff, by_key["start"]), 95, "重载后读到 95")

    # restore_text：撤销回改动前那一份（相对磁盘是脏的），再恢复成磁盘上那一份（不脏）
    model.restore_text(saved)
    ok(model.dirty, "撤销回改动前的文本 → 相对磁盘仍是「脏」")
    eq(model.value(buff, by_key["start"]), original_start, "撤销后值回到改之前")

    model.restore_text(model.saved_text or "")
    ok(not model.dirty, "恢复成磁盘上那一份 → 不脏")
    eq(model.value(buff, by_key["start"]), 95, "恢复后值回到 95")

    raises(lambda: ConfigModel.load(path.parent / "nope.json"),
           "文件不存在 → ModelError", ModelError)


# ----------------------------------------------------------------------
def main() -> int:
    print("DAEEM buff 编辑器 · 数据层测试")
    print("配置文件：%s" % CONFIG)
    # ★ 兜底：这套测试**只许动临时副本**，真配置必须一字未改。
    real_before = CONFIG.read_bytes()
    t_text_roundtrip()
    t_fields()
    t_parse()
    t_warnings_and_preview()
    t_game_contract()
    t_save_and_reload()
    ok(CONFIG.read_bytes() == real_before,
       "★★ 真配置（%s）在整个测试过程中一字未改（测试只动 .tmp_buff_editor_* 里的副本）"
       % CONFIG.name)
    for tmp in _TMP:
        try:
            tmp.unlink()
        except OSError:
            pass
    print("\n[CASE] test_model -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
