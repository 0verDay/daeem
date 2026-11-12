"""test_model.py —— 单位编辑器数据层的无头测试（不需要图形界面）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/unit_editor/test_model.py

为什么要有它：这个编辑器改的是**游戏唯一的一份数值表** `data/config.json`，
写错一个键名（`cooldown` 写成 `cooldown_sec`）游戏不会报错，只会静默用兜底值 ——
而「静默用了别的数」正是这个项目最贵的一类 bug（见 docs/pitfalls.md）。
所以这里把三件事钉成断言：

    1. **原地最小改动**：没改就是逐字节原样；改一个数只多出一处 diff；改回来还原；
    2. **字段 → JSON 路径**：每个字段写到哪个键上，以及游戏侧真的读那几个键；
    3. **校验**：内置的不许删、id 不许乱起、非法输入不许写进文件。
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
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

from unit_editor import configfile                        # noqa: E402
from unit_editor import model as model_mod                 # noqa: E402
from unit_editor.configfile import Doc, JsonError, parse_number   # noqa: E402
from unit_editor.model import (                           # noqa: E402
    BUILTIN_BUILDINGS,
    BUILTIN_UNITS,
    GENERAL_TRAIT_ATTACK_KEY,
    UNIT_TRAIT_ATTACK_KEY,
    UNIT_TRAIT_KNOCKBACK,
    ConfigModel,
    ModelError,
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
    ok(False, "%s（居然没抛）" % label)


def fresh_model() -> ConfigModel:
    """一份内存里的模型（不动磁盘上的真文件）。"""
    return ConfigModel.load(CONFIG)


def parse(text: str):
    return json.loads(text)


def changed_lines(before: str, after: str) -> int:
    import difflib
    a, b = before.split("\n"), after.split("\n")
    n = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if tag != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


def tmp_copy() -> Path:
    """在**工程里**开一份临时副本（与 map_editor 的测试同一套做法）。

    ⚠️ 用工程目录而不是系统临时目录：这里要真写文件、真读回来，
       而系统 temp 在受限环境下不一定可写（实测被拦过）。
    """
    tmp = PROJECT_DIR / ".tmp_unit_editor_test"
    tmp.mkdir(parents=True, exist_ok=True)
    _TMP.append(tmp)
    target = tmp / "config.json"
    shutil.copyfile(CONFIG, target)
    return target


# ======================================================================
# [0] 文本层：原地最小改动
# ======================================================================

def t_text_roundtrip() -> None:
    print("\n[0] 文本层：原地最小改动")
    text = CONFIG.read_text(encoding="utf-8")
    doc = Doc(text)
    eq(doc.text, text, "读一遍再吐出来：逐字节原样")
    eq(doc.value(["building", "tower", "damage"]), 12, "读数：箭塔攻击 12")
    eq(doc.value(["unit", "types", "spearman", "name"]), "长枪兵", "读数：中文原样")
    eq(doc.value(["grid", "cols"]), 24, "读数：int 保持 int")
    eq(doc.value(["resource", "decimals"]), 1, "★ 一眼像 int 的键也是按原文念")
    ok(isinstance(doc.value(["unit", "types", "rider", "speed"]), float),
       "★ 小数保持 float（0.9 不会变成 0.9.0 这种）")

    model = fresh_model()
    before = model.text
    model.set_building("tower", "damage", 15)
    eq(changed_lines(before, model.text), 1, "★ 改一个数：只有 1 行发生变化")
    parse(model.text)
    model.set_building("tower", "damage", 12)
    eq(model.text, before, "★ 改回原值：文本逐字节回到原样")

    # 尾逗号：Godot 容忍、Python 的 json 不容忍 —— 编辑器要能读进去
    strict_bad = '{\n  "a": [\n    1,\n    2,\n  ],\n  "b": 3\n}\n'
    try:
        json.loads(strict_bad)
        ok(False, "（前提）这段文本应当不是严格 JSON")
    except json.JSONDecodeError:
        ok(True, "（前提）尾逗号那段文本不是严格 JSON")
    doc2 = Doc(strict_bad)
    eq(doc2.value(["a"]), [1, 2], "★★ 尾逗号能读进来（Godot 容忍它，Python 不容忍）")
    doc2.set(["b"], 4)
    parse(doc2.text)
    ok(True, "改一处之后写出来是**严格合法**的 JSON（尾逗号被顺手清掉）")
    ok(",\n  ]" not in doc2.text, "★ 那个尾逗号没了")

    # 空容器里插东西：括号要撑开，不能留下 `{ , }`
    doc3 = Doc('{\n  "stats": [{}, {}, {}]\n}\n')
    doc3.set(["stats", 0, "hp_max"], 200)
    parse(doc3.text)
    eq(doc3.value(["stats", 0, "hp_max"]), 200, "空字典里插一个键")
    eq(doc3.size(["stats"]), 3, "★ 插完还是三个元素")
    doc3.remove(["stats", 0, "hp_max"])
    eq(doc3.text, '{\n  "stats": [{}, {}, {}]\n}\n', "★ 加一个键再删掉：回到原样")

    # 数组增删
    doc4 = Doc('{\n  "list": [\n    {"k": 1},\n    {"k": 2}\n  ]\n}\n')
    doc4.append(["list"], {"k": 3})
    parse(doc4.text)
    eq([e["k"] for e in doc4.value(["list"])], [1, 2, 3], "数组追加")
    doc4.remove(["list", 1])
    eq([e["k"] for e in doc4.value(["list"])], [1, 3], "★ 数组删中间那个（连逗号一起）")
    doc4.remove(["list", 0])
    eq([e["k"] for e in doc4.value(["list"])], [3], "★ 删第一个")
    doc4.remove(["list", 0])
    eq(doc4.value(["list"]), [], "★ 删光了就是空数组")
    parse(doc4.text)

    # 数字解析：只认严格 JSON 数字
    eq(parse_number("8"), 8, "整数字面量")
    ok(isinstance(parse_number("8"), int), "「8」是 int（写回去也是 8，不是 8.0）")
    ok(isinstance(parse_number("8.0"), float), "「8.0」是 float")
    eq(parse_number(" 12 "), 12, "两边空格无所谓")
    for bad in ("", "abc", "1,5", "nan", "inf", "1_000", "--1", "0x10"):
        eq(parse_number(bad), None, "不是数字：%r" % bad)


# ======================================================================
# [1] 单位：字段落在哪个键上
# ======================================================================

def t_unit_fields() -> None:
    print("\n[1] 单位：字段 → JSON 路径")
    model = fresh_model()
    u = model.unit("spearman")
    eq(u.name, "长枪兵", "名称")
    eq(u.unit_class, "infantry", "归属 = infantry（步兵）")
    eq(u.class_label, "步兵", "归属的中文说法读 config 的 unit.classes")
    eq(u.ranged, False, "长枪兵不是远程")
    # ★★ 2026.10.29：TTK 改版 —— 血量上调、攻击下调、并把护甲写进兵种表。
    near(u.hp_max, 180, "血量")
    near(u.armor, 2, "护甲")
    near(u.damage, 11, "攻击力")
    near(u.range, 1, "攻击距离")
    near(u.cooldown_sec, 1.0, "攻击速度（间隔秒）")
    near(u.speed, 0.6, "移动速度")
    # ★★ 本次：长枪兵是**低级单位，只吃粮食**（用户口径：「低级单位只需要粮食就可以招募」）
    near(u.cost_food, 80, "造价 · 粮食（来自 recruit.list，已按造价 ×2 调整）")
    near(u.cost_gold, 0, "造价 · 黄金（低级单位不要黄金）")
    near(u.population_cost, 1, "造价 · 人口")
    ok(u.has_recruit, "它在招募表里")
    eq(u.recruit_owner, "recruit.list", "★ 招募条目记下了来源表（原生兵种在全局表）")
    eq(u.recruit_path, ["recruit", "list", 0], "★ 记下了条目所在的 JSON 路径")
    # ★★ 2026.11.2：读条时间不再是兵种的属性（单位条目里的 train_sec 已删），
    #   它由「招它的将领」决定 —— 见下面将领那一段的 recruit_sec。
    ok(not hasattr(u, "train_sec"), "★ 兵种上没有 train_sec 这个属性了")
    # ★★ 派系兵种（王朝）的招募条目在 clan.list[].recruit[] 里 ——
    #   老实现只查全局表，于是把它们误判成「不在招募表」（用户报的就是这个）。
    var_u = model.unit("dy_chariot")
    ok(var_u.has_recruit, "★★ 派系兵种（王朝战车）**在**招募表里")
    ok(var_u.recruit_owner.startswith("clan:"), "★ 它的招募条目来自派系表（%s）"
       % var_u.recruit_owner)
    ok(var_u.cost_gold > 0, "★★ 能读到派系表里的造价（战车 %s 金）" % var_u.cost_gold)
    # ★★ 组合单位的零件（协防军枪）没有自己的条目，但**招得出来**（整包生成）——
    #   它有 spawn_source，界面上不该说「不在招募表」。
    part = model.unit("dy_spear_guard")
    ok(not part.has_recruit, "（前提）协防军枪没有自己的招募条目")
    ok(part.spawn_source is not None, "★★ 但它记着「被哪一单整包生成」")
    eq(part.spawn_label, "协防军", "★ 那一单的显示名（协防军）")
    ok(model.unit("longbowman").ranged, "★ 长弓兵是远程的（远程 + 步兵 = 两个维度）")
    # ★ 一个**不在招募表里**的单位：has_recruit 为假。
    #   （原来这里用「测试敌人」当例子，它已被删除；而 `add_unit` 造出来的新兵种
    #    一定会带上招募条目，所以直接往文档里插一条没有招募项的类型。）
    model.doc.set(["unit", "types", "no_recruit_probe"], {"name": "无招募",
                                                          "class": "infantry",
                                                          "ranged": False})
    ok(not model.unit("no_recruit_probe").has_recruit,
       "★ 不在招募表里的单位，has_recruit 为假")

    # 每一项都写到正确的键上
    for field, value, path in (
            ("name", "长矛兵", ["unit", "types", "spearman", "name"]),
            ("unit_class", "cavalry", ["unit", "types", "spearman", "class"]),
            ("ranged", True, ["unit", "types", "spearman", "ranged"]),
            ("hp_max", 175, ["unit", "types", "spearman", "hp_max"]),
            ("damage", 25, ["unit", "types", "spearman", "damage"]),
            ("range", 2, ["unit", "types", "spearman", "range"]),
            ("cooldown_sec", 0.8, ["unit", "types", "spearman", "cooldown_sec"]),
            ("speed", 0.7, ["unit", "types", "spearman", "speed"]),
            ("radius_factor", 0.11, ["unit", "types", "spearman", "radius_factor"]),
            ("cost_food", 60, ["recruit", "list", 0, "cost", "food"]),
            ("cost_gold", 70, ["recruit", "list", 0, "cost", "gold"]),
            ("population_cost", 2, ["recruit", "list", 0, "population_cost"]),
            ("desc", "说明文字", ["recruit", "list", 0, "desc"]),
    ):
        model.set_unit("spearman", field, value)
        eq(model.doc.value(path), value, "set_unit(%s) → %s" % (field, ".".join(map(str, path))))
    eq(parse(model.text)["recruit"]["list"][0]["kind"], "spearman",
       "★★ 写招募表时按 **kind** 找那一项（不是按顺序）")

    # 名称同步
    m2 = fresh_model()
    m2.set_unit("spearman", "name", "重装长枪兵")
    eq(m2.doc.value(["recruit", "list", 0, "label"]), "重装长枪兵",
       "★ 改名称 → 命令卡标题一起改（两处不一致看着像 bug）")

    # 地图上的字（icon）：**正好一个字符**；空 = 删掉这个键（跟着名字的第一个字）
    m3 = fresh_model()
    eq(m3.unit("spearman").icon, "枪", "配置里写着地图上那个字（枪）")
    eq(m3.unit("spearman").icon_char, "枪", "生效的字 = 配置里那个字")
    eq(m3.unit("longbowman").icon_char, "弓", "长弓兵也有自己的字（弓）")
    m3.set_unit("spearman", "icon", "矛")
    eq(m3.doc.value(["unit", "types", "spearman", "icon"]), "矛", "改成一个别的字")
    m3.set_unit("spearman", "icon", "")
    ok(not m3.doc.has(["unit", "types", "spearman", "icon"]),
       "★ 清空 → 这个键被删掉（不留一个空字符串）")
    eq(m3.unit("spearman").icon_char, "长",
       "★ 清空之后跟着**名字的第一个字**（长枪兵 → 长）")
    raises(lambda: m3.set_unit("spearman", "icon", "矛盾"),
           "★★ 两个字被拒（地图上只画一个字）")
    raises(lambda: m3.set_unit("spearman", "icon", "ab"), "两个字母也被拒")
    eq(m3.doc.value(["unit", "types", "spearman", "icon"], None), None,
       "被拒之后什么都没写进去")
    m3.set_unit("spearman", "name", "矛兵")
    eq(m3.unit("spearman").icon_char, "矛", "★ 改名之后「跟着名字」的那个字当场跟着变")
    eq(m3.unit("longbowman").icon_char, "弓", "别的兵种不受影响")

    # 校验
    raises(lambda: model.set_unit("spearman", "unit_class", "空军"),
           "归属只认 unit.classes 里那几种")
    raises(lambda: model.set_unit("spearman", "hp_maxx", 1), "不认识的字段被拒")
    raises(lambda: model.set_unit("nope", "hp_max", 1), "不存在的单位被拒")
    # ---- 「不在招募表里的单位」那一整条路（★ 本次换主角：原来是「测试敌人」，
    #      它已从编辑器与 config 里删除；现在用**自定义兵种**来验，语义完全一样）----
    m4 = fresh_model()
    m4.add_unit("zombie", "僵尸", "spearman")
    # 造一个「不在招募表里」的状态：把它的招募条目删掉
    idx_z = m4.unit("zombie").recruit_index
    ok(idx_z >= 0, "（前提）新兵种默认是有招募条目的")
    m4.doc.remove(["recruit", "list", idx_z])
    ok(not m4.unit("zombie").has_recruit, "★ 删掉招募条目之后它就不在招募表里了")
    raises(lambda: m4.set_unit("zombie", "cost_food", 5),
           "★ 不在任何招募表里的单位：改造价 / 文案会被拒（并提示先加进招募表）")

    # 再把它加回招募表
    before = m4.text
    before_count = m4.doc.size(["recruit", "list"])
    m4.add_recruit_entry("zombie")
    eq(m4.doc.size(["recruit", "list"]), before_count + 1, "加进招募表：多了一条")
    eq(m4.unit("zombie").has_recruit, True, "加完之后它有招募数值了")
    m4.set_unit("zombie", "population_cost", 3)
    eq(m4.doc.value(["recruit", "list", before_count, "population_cost"]), 3,
       "加进去之后就能改造价")
    ok(changed_lines(before, m4.text) > 0, "确实动了文件")


# ======================================================================
# [2] 新建 / 删除兵种
# ======================================================================

def t_recruit_packages() -> None:
    """★★ 2026.11.2：组合招募单（协防军 / 御林军）—— 它们不是兵种，但造价必须能改。"""
    print("\n[1c] 组合招募单（一次出多个兵的招募条目）")
    model = fresh_model()
    by_kind = {p.kind: p for p in model.recruit_packages()}
    ok("dy_guard" in by_kind, "★★ 列出「协防军」这一单（它不是兵种，单位页列不出来）")
    ok("dy_royal" in by_kind, "★★ 列出「御林军」这一单")
    ok("spearman" not in by_kind, "★ 普通兵种不算组合单（不在这一栏里重复出现）")
    guard = by_kind["dy_guard"]
    eq(guard.label, "协防军", "名字")
    eq(guard.count, 2, "★ 协防军一次出 2 个")
    ok("dy_spear_guard" in guard.member_text, "★ 组成里写着枪兵（%s）" % guard.member_text)
    # ★ 粮食价**不钉死具体数字**：它天天跟着调参走（本地把 145 调成 120 是正常的），
    #   钉死会让「改了一个平衡数值」变成编辑器测试红。这里验的是「模型读的就是
    #   clan 表那一项」—— 与文件里那一格逐位相等。
    near(guard.cost_food, model.doc.value(guard.path + ["cost", "food"]),
         "整包造价 · 粮食（读的是 clan 表那一格）")
    near(guard.population_cost, 2, "整包造价 · 人口")
    ok(guard.owner.startswith("clan:"), "★ 记下了来源表（%s）" % guard.owner)

    # 改整包造价 → 写进 clan 表那一行（不是另建一条）
    recruit_before = len(model.doc.value(["clan", "list", 1, "recruit"], []))
    model.set_recruit_package("dy_guard", "cost_food", 200)
    eq(model.doc.value(["clan", "list", 1, "recruit", 0, "cost", "food"]), 200,
       "★★ 改「协防军」的粮价 → 写进 clan:dynasty 那一行")
    near(model.recruit_package("dy_guard").cost_food, 200, "模型读回同一个数")
    eq(len(model.doc.value(["clan", "list", 1, "recruit"], [])), recruit_before,
       "★ 改价不会新增招募条目（王朝仍然是 %d 条）" % recruit_before)

    # 文案也能改
    model.set_recruit_package("dy_guard", "label", "协防营")
    eq(model.doc.value(["clan", "list", 1, "recruit", 0, "label"]), "协防营",
       "★ 改这一单的命令卡标题")

    # 与「兵种页」不串线：改这一单不改成员自己的数值
    spear = model.unit("dy_spear_guard")
    ok(not spear.has_recruit, "（前提）协防军枪没有自己的招募条目")
    raises(lambda: model.recruit_package("spearman"), "兵种不是组合单：查它会报错")
    raises(lambda: model.set_recruit_package("dy_guard", "hp_max", 1),
           "组合单没有 hp_max 这种字段（数值去兵种页改）")


def t_charge_fields() -> None:
    print("\n[1b] 冲锋字段（嵌套 unit.types.<id>.charge）")
    model = fresh_model()
    # 已有配置：骑手有 charge，长枪兵没有
    eq(model.unit("rider").charge_field("min_distance"), 3.0,
       "★ 骑手读到 charge.min_distance")
    eq(model.unit("spearman").charge_field("min_distance"), 0.0,
       "★ 长枪兵没配 charge → 读 0（= 不冲锋）")
    # 第一次写：自动建 charge 块，其余项补 0
    model.set_unit("spearman", "charge.min_distance", 3.5)
    eq(model.unit("spearman").charge_field("min_distance"), 3.5,
       "★★ 第一次编辑会自动建 charge 块并写入")
    eq(model.unit("spearman").charge_field("damage_bonus"), 0.0,
       "★ 新建的块里其余项是 0（不会凭空给数值）")
    model.set_unit("spearman", "charge.damage_bonus", 0.4)
    eq(model.unit("spearman").charge_field("damage_bonus"), 0.4, "★ 改冲锋伤害加成")
    # 清空 = 删掉这一项（读回 0），但块还在
    model.set_unit("spearman", "charge.damage_bonus", None)
    eq(model.unit("spearman").charge_field("damage_bonus"), 0.0,
       "★★ 清空某一项 = 删掉键，读回 0")
    raises(lambda: model.set_unit("spearman", "charge.nope", 1.0),
           "不认识的冲锋字段被拒")


def t_unit_traits() -> None:
    """★★ 2026.11：单位特性池（`unit.unit_traits`）+ 兵种挂 `trait_ids`。

    这一组钉六件事：
      1. **读**：池里的定义、兵种挂的标签、摘要；
      2. **写池**：攻击加成 / 两条减伤 / 稳定 / 文案，落到 game 侧
         `_normalize_unit_trait()` 认的位置；减伤夹在 0~1；
      3. **挂 / 摘**：兵种 `trait_ids` 可多条；摘到空 = 连键一起删（不留空数组）；
      4. **删池**：正在挂它的兵种自动摘掉（不留指向空 id 的记录）；
      5. **新建**：照模板复制 + 改名；id 重复 / 非法被拒；
      6. **排版**：改已有值只动一行；加键后缩进不漂。
    """
    print("\n[1d] 单位特性池 + 兵种挂标签（对某大类伤害 / 远近减伤 / 免疫击退）")
    model = fresh_model()
    names = dict(model.class_choices())

    # ---- 1) 池：13 条（迁移出来的那批）
    eq(len(model.unit_trait_ids()), 13, "★ 单位特性池 13 条")
    eq(model.unit_trait_ids()[:3],
       ["vs_cavalry_25", "vs_cavalry_70", "vs_infantry_10"],
       "★ 顺序 = config 里的顺序（界面照它列）")
    cav = model.unit_trait("vs_cavalry_25")
    eq(cav.name, "骑兵特攻", "★ 名字读得到")
    eq(cav.attack_rows(names), [("cavalry", 0.25, "骑兵")],
       "★★ 「对骑兵 +25%」读成一行 (cavalry, 0.25, 骑兵)")
    eq(cav.effect_summary(names), "对骑兵 +25%", "摘要 = 对骑兵 +25%")
    ok(cav.effect_number("ranged_reduction") is None,
       "★★ 没写的减伤读成 None（界面空框，不是 0）")
    eq(cav.knockback_immune, False, "没写「稳定」→ False")
    eq(cav.short_text, "骑", "★ 短名 = 骑")

    # ---- 2) 兵种挂的标签
    eq(model.unit("spearman").trait_ids, ["vs_cavalry_25"],
       "★★ 长枪兵挂的是「骑兵特攻」")
    eq(model.unit_traits_at("spearman"), ["vs_cavalry_25"], "…读回来也是这一条")
    eq(model.unit("rider").trait_ids, ["vs_infantry_25", "ranged_guard_25"],
       "★ 骑手挂两条（对步兵 + 远程抵抗）")

    # ---- 3) 改池里的效果（只动一行 / 夹取）
    before = model.text
    model.set_unit_trait_field("vs_cavalry_25", "ranged_reduction", 0.25)
    eq(model.doc.value(["unit", "unit_traits", "vs_cavalry_25", "ranged_reduction"]), 0.25,
       "★★ 「远程减伤」落在 unit.unit_traits.<id>.ranged_reduction")
    eq(model.unit_trait("vs_cavalry_25").effect_summary(names),
       "对骑兵 +25% / 远程减伤 25%", "摘要带上远程减伤")
    model.set_unit_trait_field("vs_cavalry_25", "melee_reduction", 2.0)
    eq(model.doc.value(["unit", "unit_traits", "vs_cavalry_25", "melee_reduction"]), 1.0,
       "★★ 减伤被夹到 1（写 2 = 无敌，只挡误输入）")
    model.set_unit_trait_field("vs_cavalry_25", "melee_reduction", 0.3)
    mid = model.text
    model.set_unit_trait_field("vs_cavalry_25", "melee_reduction", 0.35)
    eq(changed_lines(mid, model.text), 1,
       "★★ 改一个已有值：全文件只有那一行变化（不整块重排）")

    # 稳定（开关）
    model.set_unit_trait_field("vs_cavalry_25", UNIT_TRAIT_KNOCKBACK.key, True)
    eq(model.doc.value(["unit", "unit_traits", "vs_cavalry_25", "knockback_immune"]), True,
       "★ 「稳定」落在 knockback_immune = true")
    model.set_unit_trait_field("vs_cavalry_25", UNIT_TRAIT_KNOCKBACK.key, False)
    ok(not model.doc.has(["unit", "unit_traits", "vs_cavalry_25", "knockback_immune"]),
       "★★ 取消勾选 = 删掉那个键（不留一个 false）")

    # 文案
    model.set_unit_trait_field("vs_cavalry_25", "desc", "对骑兵 +25%（测试写的）")
    eq(model.unit_trait("vs_cavalry_25").desc, "对骑兵 +25%（测试写的）", "★ 说明写进去")
    model.set_unit_trait_field("vs_cavalry_25", "desc", "")
    ok(not model.doc.has(["unit", "unit_traits", "vs_cavalry_25", "desc"]),
       "★★ 清空说明 = 删掉那个键（不留空串）")
    raises(lambda: model.set_unit_trait_field("vs_cavalry_25", "name", ""),
           "名字不允许清空（列表 / 下拉会变成空白）")

    # ---- 4) 对某大类：加 / 改 / 删
    model.add_unit_trait_attack("vs_cavalry_25", "infantry")
    eq(model.doc.value(["unit", "unit_traits", "vs_cavalry_25", "attack_vs_class",
                        "infantry"]), 0.25,
       "★★ 「加一条」默认 +25%，落在 attack_vs_class.infantry")
    eq([row[0] for row in model.unit_trait("vs_cavalry_25").attack_rows(names)],
       ["cavalry", "infantry"], "★ 行的顺序 = 文件里的顺序（新加的排在后面）")
    raises(lambda: model.add_unit_trait_attack("vs_cavalry_25", "infantry"),
           "同一个大类不能加两次（改那一行的数就行）")
    raises(lambda: model.set_unit_trait_attack("vs_cavalry_25", "nope", 0.1),
           "不存在的兵种大类被拒")
    model.set_unit_trait_attack("vs_cavalry_25", "infantry", 0.4)
    eq(model.doc.value(["unit", "unit_traits", "vs_cavalry_25", "attack_vs_class",
                        "infantry"]), 0.4, "改那一行")
    model.set_unit_trait_attack("vs_cavalry_25", "infantry", None)
    ok(not model.doc.has(["unit", "unit_traits", "vs_cavalry_25", "attack_vs_class",
                          "infantry"]), "★★ 删掉那一行 → 键没了")

    # ---- 5) 只改一个已有值再改回来：逐字节还原
    rider_before = model.text
    model.set_unit_trait_field("ranged_guard_25", "ranged_reduction", 0.35)
    eq(changed_lines(rider_before, model.text), 1,
       "★★ 改池里一条已有值：全文件只有那一行变化")
    model.set_unit_trait_field("ranged_guard_25", "ranged_reduction", 0.25)
    eq(model.text, rider_before, "★★ 改一个已有的值再改回来：文本逐字节还原")

    # ---- 6) 挂 / 摘（可多条）
    model.add_unit_trait_to("spearman", "steady")
    eq(model.unit("spearman").trait_ids, ["vs_cavalry_25", "steady"],
       "★★ 一个兵种可以挂多条")
    raises(lambda: model.add_unit_trait_to("spearman", "steady"), "同一条不能挂两次")
    raises(lambda: model.add_unit_trait_to("spearman", "nope"), "挂不存在的特性被拒")
    model.remove_unit_trait_from("spearman", "steady")
    eq(model.unit("spearman").trait_ids, ["vs_cavalry_25"], "★ 摘掉其中一条，其余保留")
    model.remove_unit_trait_from("spearman", "vs_cavalry_25")
    ok(not model.doc.has(["unit", "types", "spearman", "trait_ids"]),
       "★★ 摘到空 → 连 trait_ids 键一起删（文件里不留 `[]`）")
    model.add_unit_trait_to("spearman", "vs_cavalry_25")

    # ★ 手改配置写了一个池里不存在的 id：unit_traits_at 会过滤掉（与游戏侧同一条）。
    model.doc.set(["unit", "types", "spearman", "trait_ids"],
                  ["vs_cavalry_25", "ghost"])
    eq(model.unit_traits_at("spearman"), ["vs_cavalry_25"],
       "★★ 坏 id 被过滤掉（否则兵种表单会因为查不到那条特性而打不开）")
    model.doc.set(["unit", "types", "spearman", "trait_ids"], ["vs_cavalry_25"])

    # ---- 7) 新建（照模板复制）/ 删除（兵种自动摘掉）
    model.add_unit_trait("taunt", "嘲讽", "vs_cavalry_25")
    eq(model.doc.value(["unit", "unit_traits", "taunt", "name"]), "嘲讽",
       "★ 新特性用填的名字")
    eq(model.doc.value(["unit", "unit_traits", "taunt", "attack_vs_class", "cavalry"]),
       0.25, "★★ 照模板复制：连效果一起抄")
    ok(not model.doc.has(["unit", "unit_traits", "taunt", "short"]),
       "★ 模板的 short 被删掉（不然会顶着模板那个字）")
    raises(lambda: model.add_unit_trait("taunt", "再来一个", "steady"),
           "重复的 id 被拒")
    raises(lambda: model.add_unit_trait("Bad Id", "坏 id", "steady"),
           "非法 id 被拒")
    model.add_unit_trait_to("rider", "taunt")
    model.remove_unit_trait("taunt")
    ok(not model.doc.has(["unit", "unit_traits", "taunt"]), "★★ 池里那条删掉了")
    for uid in ("rider", "spearman"):
        ok("taunt" not in model.unit(uid).trait_ids,
           "★★ %s 身上也不再有 taunt（不留指向空 id 的记录）" % uid)

    # ---- 8) 排版：往池里那条加几个键，缩进必须对（不能歪到嵌套字典那一列）
    model.set_unit_trait_field("vs_cavalry_25", "ranged_reduction", 0.25)
    model.set_unit_trait_field("vs_cavalry_25", UNIT_TRAIT_KNOCKBACK.key, True)
    model.add_unit_trait_attack("vs_cavalry_25", "infantry", 0.1)
    block = model.doc.text_of(["unit", "unit_traits", "vs_cavalry_25"])
    lines = [line for line in block.split("\n") if line.strip()]
    indents = [len(line) - len(line.lstrip(" ")) for line in lines]
    eq(all(i % 2 == 0 for i in indents), True,
       "★★ 池里那条每一行都是偶数缩进（缩进漂移时会出现 29 这种奇数）：%s" % indents)
    key_indents = [ind for line, ind in zip(lines, indents)
                   if line.lstrip().startswith('"')]
    eq(len(set(key_indents)), 2,
       "★★ 一级键同列、嵌套键同列（两个缩进层级）：%s" % key_indents)


def t_general_traits() -> None:
    """★★ 2026.11.3：将领特性池（`unit.general_traits`）+ 每位将领指定一条。"""
    print("\n[1e] 将领特性池与「每位将领指定一条」")
    model = fresh_model()
    names = dict(model.class_choices())
    eq(model.general_trait_ids(),
       ["swift", "melee_guard", "ranged_guard", "infantry_slayer", "cavalry_slayer", "might",
        "steadfast", "arrow_wall", "formation_breaker", "capture_expert",
        "call_to_arms", "new_knighthood", "crushing_blow"],
       "★ 池里那 13 条（6 基础 + 7 条新特性；每条只做一件事）")
    swift = model.general_trait("swift")
    eq((swift.name, swift.short, swift.desc), ("神速", "速", "移动速度 +25%"), "★ 神速的三件套")
    eq(swift.effect_number("speed_bonus"), 0.25, "★ 神速 = 移速 +25%（比例 0.25）")
    eq(swift.effect_summary(names), "移速 +25%", "摘要：移速 +25%")
    ok(model.general_trait("infantry_slayer").effect_number("melee_reduction") is None,
       "★ 没写的那项读成 None（= 这条特性没有它）")

    # ---- 指定 / 取消指定
    # ★ 2026.11.4：设计师已经给几位将领指定了特性，所以这里不再假设「默认全空」，
    #   改成「每一位要么空数组、要么是池里真实存在的若干条」——这才是配置合法性的判据。
    ids = model.doc.value(["unit", "general", "trait_ids"], [])
    ok(isinstance(ids, list) and len(ids) == model.general_count(),
       "trait_ids 与将领同序同长")
    for i, entry in enumerate(ids if isinstance(ids, list) else []):
        picks = [entry] if isinstance(entry, str) else list(entry or [])
        ok(all(isinstance(t, str) and model.general_trait_ids().count(t) == 1 for t in picks),
           "第 %d 位将领的特性都在池里（实际 %r）" % (i + 1, entry))
    model.assign_general_trait(0, "")
    eq(model.general(0).trait_ids, [], "（前提）清空将领 0 的特性")
    model.assign_general_trait(0, "swift")
    eq(model.doc.value(["unit", "general", "trait_ids", 0]), ["swift"],
       "★★ 给将领 0 指定神速 → 写进 unit.general.trait_ids[0]（数组）")
    eq(model.general(0).trait_ids, ["swift"], "模型读回同一条")
    # ★★ 2026.11：一个将领可以有**多条**特性
    model.add_general_trait_to(0, "steadfast")
    eq(model.general(0).trait_ids, ["swift", "steadfast"],
       "★★ 再给它加一条「稳定」→ 两条并存（用户口径：一个将领可以有多个特性）")
    eq(model.general(0).trait_id, "swift", "★ trait_id 兼容字段 = 第一条")
    raises(lambda: model.add_general_trait_to(0, "steadfast"), "同一条不能加两次")
    model.remove_general_trait_from(0, "swift")
    eq(model.general(0).trait_ids, ["steadfast"], "★ 移除一条，其余保留")
    model.assign_general_trait(0, "")
    eq(model.general(0).trait_ids, [], "★ 指定「无」= 清空，不是删掉整个数组")
    ok(isinstance(model.doc.value(["unit", "general", "trait_ids"]), list),
       "trait_ids 仍是与将领同序的数组（下标不能错位）")
    raises(lambda: model.assign_general_trait(0, "nope"), "指定一条不存在的特性被拒")
    raises(lambda: model.assign_general_trait(99, "swift"), "越界的将领序号被拒")

    # ---- 改池里的定义
    model.set_general_trait_field("swift", "name", "疾行")
    eq(model.doc.value(["unit", "general_traits", "swift", "name"]), "疾行", "改名字")
    raises(lambda: model.set_general_trait_field("swift", "name", ""), "名字不能空着")
    model.set_general_trait_field("swift", "speed_bonus", 0.4)
    eq(model.doc.value(["unit", "general_traits", "swift", "speed_bonus"]), 0.4,
       "★ 改移速加成 → unit.general_traits.swift.speed_bonus（config.gd 读它）")
    model.set_general_trait_field("swift", "ranged_reduction", 1.5)
    eq(model.doc.value(["unit", "general_traits", "swift", "ranged_reduction"]), 1.0,
       "★ 减伤夹到 1")
    model.set_general_trait_field("swift", "short", "")
    ok(not model.doc.has(["unit", "general_traits", "swift", "short"]),
       "★ 清空短名 = 删掉键（游戏侧退成名字首字）")
    model.add_general_trait_attack("swift", "cavalry")
    eq(model.doc.value(["unit", "general_traits", "swift", "attack_vs_class", "cavalry"]),
       0.25, "★ 将领特性也能写「对某大类伤害 +x%」")
    model.set_general_trait_attack("swift", "cavalry", None)
    ok(not model.doc.has(["unit", "general_traits", "swift", "attack_vs_class"]),
       "★ 删掉唯一一行 → 整张 attack_vs_class 表也没了")

    # ---- 新建 / 删除
    before_ids = model.general_trait_ids()
    model.add_general_trait("brute", "蛮力", "might")
    eq(model.general_trait_ids(), before_ids + ["brute"], "★ 新建的特性追加在池尾")
    brute = model.general_trait("brute")
    eq(brute.name, "蛮力", "名字用新建时填的")
    eq(brute.attack_speed_bonus, 0.25, "★ 照模板（might）复制了效果")
    eq(brute.short, "", "★★ 短名**不抄模板**（否则新特性顶着模板那个「神」字）")
    raises(lambda: model.add_general_trait("brute", "又一个", "might"), "id 不许重复")
    raises(lambda: model.add_general_trait("Bad Id", "坏", "might"), "id 只许小写 + 下划线")

    # 删掉一条正在用的：必须把用它的将领身上那一条去掉（别的特性保留）
    model.assign_general_trait(0, "brute")
    model.add_general_trait_to(0, "steadfast")
    eq(model.general(0).trait_ids, ["brute", "steadfast"], "（前提）将领 0 同时带 brute + 稳定")
    model.remove_general_trait("brute")
    ok(not model.doc.has(["unit", "general_traits", "brute"]), "★★ 删掉了池里那一条")
    eq(model.general(0).trait_ids, ["steadfast"],
       "★★ 只把这一条从将领身上去掉，另一条保留（不留指向空 id 的记录）")
    raises(lambda: model.remove_general_trait("brute"), "再删一次被拒")

    # ---- 读法契约：缺项 / 越界 / 坏 id 都当「没有那一条」
    model.doc.set(["unit", "general", "trait_ids", 1], ["ghost"])
    eq(model.general(1).trait_ids, [],
       "★★ trait_ids 里写了一个池里没有的 id → 当成「没有特性」（写错当没写）")
    eq(model.general(9).trait_ids, [], "越界的序号 → 空数组，不抛异常")

    # ---- 池被删空时也能建第一条（否则「把特性全删了」会把功能锁死）
    for tid in list(model.general_trait_ids()):
        model.remove_general_trait(tid)
    eq(model.general_trait_ids(), [], "（前提）池被删空了")
    model.add_general_trait("first", "第一条", "")
    eq(model.general_trait("first").name, "第一条", "★★ 没有模板时也能新建（只写名字）")
    eq(model.general_trait("first").effect_summary(names), "（没有效果）", "新特性默认没有效果")


def t_trait_game_keys() -> None:
    """★★ 「编辑器写的键」= 「游戏读的键」 —— 这一组是跨语言契约的反向钉子。"""
    print("\n[1f] 特性的键名契约（编辑器 ↔ logic/config.gd）")
    model = fresh_model()
    eq({f.key for f in model_mod.UNIT_TRAIT_FIELDS} | {UNIT_TRAIT_KNOCKBACK.key},
       {"ranged_reduction", "melee_reduction", "knockback_immune"},
       "★★ 兵种特性的标量/开关键 = config.gd 的 _normalize_traits() 认的那几个")
    eq(UNIT_TRAIT_ATTACK_KEY, "attack_vs_class", "兵种特性的「对某大类」键名")
    eq({f.key for f in model_mod.GENERAL_TRAIT_FIELDS},
       {"speed_bonus", "attack_speed_bonus", "melee_reduction", "ranged_reduction",
        "capture_speed_bonus", "recruit_cavalry_discount", "charge_damage_bonus"},
       "★★ 将领特性的标量键 = config.gd 的 _normalize_general_trait() 认的那几个")
    eq(GENERAL_TRAIT_ATTACK_KEY, "attack_vs_class", "将领特性的「对某大类」键名")
    # 池里每一条的键都必须在那张白名单里（多了游戏会静默丢掉 —— 编辑器不该让人写出来）
    allowed = ({f.key for f in model_mod.GENERAL_TRAIT_FIELDS}
               | {f.key for f in model_mod.GENERAL_TRAIT_TEXT_FIELDS}
               | {GENERAL_TRAIT_ATTACK_KEY}
               | {UNIT_TRAIT_KNOCKBACK.key}
               | {"melee_splash"})
    for trait in model.general_traits():
        extra = set(trait.raw.keys()) - allowed
        eq(extra, set(), "%s 的键都在白名单里" % trait.id)
        for cls in trait.attack_vs_class:
            ok(cls in dict(model.class_choices()),
               "%s 的 attack_vs_class 键 %s 是 unit.classes 里的真实大类" % (trait.id, cls))
    # 单位特性池里每条也只能写那四个效果键（+ 文案三件套）
    unit_allowed = ({f.key for f in model_mod.UNIT_TRAIT_FIELDS}
                    | {UNIT_TRAIT_KNOCKBACK.key, UNIT_TRAIT_ATTACK_KEY}
                    | {f.key for f in model_mod.UNIT_TRAIT_TEXT_FIELDS}
                    | {"id"})
    for trait in model.unit_traits():
        extra = set(trait.raw.keys()) - unit_allowed
        eq(extra, set(), "%s 的键都在白名单里" % trait.id)
        for cls in trait.attack_vs_class:
            ok(cls in dict(model.class_choices()),
               "%s 的 attack_vs_class 键 %s 是 unit.classes 里的真实大类"
               % (trait.id, cls))
    # 每个兵种只记 trait_ids（老式内嵌 traits 不允许再写）
    for uid in model.unit_ids():
        eq(model.unit(uid).has_legacy_traits(), False,
           "%s 不再写老式内嵌 traits（已全部迁成标签）" % uid)
        for tid in model.unit(uid).trait_ids:
            ok(model.doc.has(["unit", "unit_traits", tid]),
               "%s 的 trait_ids 里 %r 指向池里真实的单位特性" % (uid, tid))
    # 每位将领的 trait_ids：每一项都是数组，里面的 id 指向池里真实存在的一条
    arr = model.doc.value(["unit", "general", "trait_ids"], [])
    ok(isinstance(arr, list), "★★ unit.general.trait_ids 是数组（与将领同序）")
    eq(len(arr), model.general_count(), "★ 长度 = 将领个数（%d）" % model.general_count())
    for i, entry in enumerate(arr):
        ok(isinstance(entry, list),
           "★★ trait_ids[%d] 是**数组**（一位将领可以带多条；用户口径 2026.11）" % i)
        for tid in (entry if isinstance(entry, list) else []):
            ok(model.doc.has(["unit", "general_traits", tid]),
               "trait_ids[%d] 里的 %r 指向池里真实的特性" % (i, tid))


def t_upkeep() -> None:
    """★★ 2026.11.4：持久消耗（`upkeep_food`，粮/秒）。

    钉四件事：
      1. **读**：兵种自己的值 / 大类的默认值 / 实际生效值（写了用写的，没写跟大类）；
      2. **写**：落到 `unit.types.<id>.upkeep_food` 与 `unit.classes.<cls>.upkeep_food`；
      3. **删**：清空 = 删键 ⇒ 立刻变成「跟随大类」，改大类会跟着动；
      4. **将领**：`unit.general.upkeep_override[<index>]` 是稀疏对象，写了用写的、
         清空就删掉那一项（回到跟随所属兵种），负数 / 越界都当场拒掉。
    """
    print("\n[1g] 持久消耗（upkeep_food）")
    model = fresh_model()
    spear = model.unit("spearman")
    near(spear.upkeep_own, 0.08, "读得出兵种自己的维护费")
    ok(not spear.inherits_upkeep, "写了自己的值 ⇒ 不是「跟随大类」")
    near(spear.upkeep_effective, 0.08, "生效值 = 自己写的")
    near(model.class_upkeep("infantry"), 0.08, "读得出步兵大类的默认维护费")

    # 删键 ⇒ 跟随大类；改大类 ⇒ 立刻跟着动（游戏侧 unit_type_entry 也是这么合并的）
    model.set_unit_upkeep("spearman", None)
    ok(not model.doc.has(["unit", "types", "spearman", "upkeep_food"]),
       "★★ 清空 = 删掉这个键（不是写 0）")
    ok(model.unit("spearman").inherits_upkeep, "删了就变成「跟随大类」")
    near(model.unit("spearman").upkeep_effective, model.class_upkeep("infantry"),
         "跟随大类 ⇒ 生效值 = 大类默认")
    model.set_class_upkeep("infantry", 0.12)
    near(model.unit("spearman").upkeep_effective, 0.12,
         "★★ 跟随时改大类，兵种的生效值立刻跟着变")
    model.set_class_upkeep("infantry", 0.08)
    model.set_unit_upkeep("spearman", 0.08)
    near(parse(model.text)["unit"]["types"]["spearman"]["upkeep_food"], 0.08,
         "★ 写回同一个值 ⇒ 解析回来还是 0.08")

    # 负数不许
    raises(lambda: model.set_unit_upkeep("spearman", -0.1), "兵种维护费不能是负数")
    raises(lambda: model.set_class_upkeep("infantry", -1.0), "大类默认不能是负数")
    # 大类默认写进去也读得回来
    model.set_class_upkeep("cavalry", 0.2)
    near(model.class_upkeep("cavalry"), 0.2, "大类默认写进去读得回来")
    model.set_class_upkeep("cavalry", 0.18)

    # ---- 将领：自己的覆盖 + 跟随 ----
    model.set_general_upkeep(0, None)                    # 先确保干净
    g0 = model.general(0)
    ok(g0.inherits_upkeep, "将领默认「跟随所属兵种」")
    near(g0.upkeep_effective, model.unit(g0.type_id).upkeep_effective,
         "跟随 ⇒ 生效值 = 所属兵种的生效值")
    model.set_general_upkeep(0, 0.5)
    eq(model.general(0).upkeep_override, 0.5, "★ 写了覆盖 ⇒ 读回来是 0.5")
    ok(not model.general(0).inherits_upkeep, "…而且不再是跟随")
    near(parse(model.text)["unit"]["general"]["upkeep_override"]["0"], 0.5,
         "★★ 写进稀疏对象 unit.general.upkeep_override[\"0\"]")
    model.set_general_upkeep(0, None)
    ok(not model.doc.has(["unit", "general", "upkeep_override", "0"]),
       "★★ 清空 ⇒ 稀疏对象里那一项被删掉（不留 null / 0）")
    ok(model.general(0).inherits_upkeep, "…于是回到跟随")
    raises(lambda: model.set_general_upkeep(0, -2.0), "将领维护费也不能是负数")
    raises(lambda: model.set_general_upkeep(99, 1.0), "越界的将领序号被拒")


def t_add_remove_unit() -> None:
    print("\n[2] 新建 / 删除兵种")
    model = fresh_model()
    model.add_unit("test_horse", "马弓手", "rider")
    ok(model.doc.has(["unit", "types", "test_horse"]), "新兵种进了 unit.types")
    u = model.unit("test_horse")
    eq(u.name, "马弓手", "名字")
    eq(u.unit_class, "cavalry", "★ 照模板复制：归属跟着 rider（骑兵）")
    eq(u.ranged, False, "★ 远程标记也照抄（之后设计师自己改）")
    # ★★ 照模板复制：拿**模板自己**当期望值（模型读的是同一份文档）。
    #    不写死数字：配平会随玩法调，而这里要钉的是「复制」这条行为。
    rider = model.unit("rider")
    near(u.hp_max, rider.hp_max, "血量照抄模板（骑手的 %s）" % rider.hp_max)
    eq(u.has_recruit, True, "同时建了招募表那一项")
    near(u.cost_food, rider.cost_food, "造价照抄模板（骑手的 %s）" % rider.cost_food)
    near(u.cost_gold, rider.cost_gold, "黄金造价照抄模板（骑手的 %s）" % rider.cost_gold)
    eq(u.label, "马弓手", "★ 命令卡标题 = 新名字")
    eq(u.icon, "", "★ 模板抄过来的那个字被删掉了（不留着模板的 icon）")
    eq(u.icon_char, "马", "★★ 新兵种地图上显示「马」（跟着名字的第一个字）")
    model.set_unit("test_horse", "icon", "弓")
    eq(model.unit("test_horse").icon_char, "弓", "想换就填一个自己的字")
    rows = parse(model.text)["recruit"]["list"]
    eq([r["kind"] for r in rows][-1], "test_horse",
       "招募表顺序：新的排在最后")
    eq(model.unit("spearman").name, "长枪兵", "★ 模板本身没被改动")

    # 改成「马弓手 = 远程骑兵」（这就是设计师真实的下一步）
    model.set_unit("test_horse", "ranged", True)
    model.set_unit("test_horse", "range", 3.0)
    eq(model.unit("test_horse").ranged, True, "改成远程")
    near(model.unit("test_horse").range, 3.0, "改成 3 格射程")

    # 照一个**不在招募表**的模板加：招募条目按默认值新建
    # ★ 本次改法：原来这里用「测试敌人」当那个模板（它不在招募表里），但那个单位
    #   已经被删掉了。现在自己造一个「有类型、没招募条目」的模板 ——
    #   先加一个兵种，再把它的招募条目删掉，它就正好是那个形状。
    m2 = fresh_model()
    m2.add_unit("skeleton", "骷髅", "rider")
    m2.doc.remove(["recruit", "list", m2.unit("skeleton").recruit_index])
    ok(not m2.unit("skeleton").has_recruit, "（前提）skeleton 已不在招募表里")
    m2.add_unit("zombie", "僵尸", "skeleton")
    ok(m2.unit("zombie").has_recruit,
       "★ 模板不在招募表 → 新兵种仍然进招募表（照默认值）")
    near(m2.unit("zombie").cost_food, 50, "默认造价 50 粮")
    near(m2.unit("zombie").population_cost, 1, "默认人口 1")

    # id 校验
    m3 = fresh_model()
    raises(lambda: m3.add_unit("Horse", "马", "rider"), "id 不许有大写")
    raises(lambda: m3.add_unit("horse archer", "马", "rider"), "id 不许有空格")
    raises(lambda: m3.add_unit("9horse", "马", "rider"), "id 不许数字开头")
    raises(lambda: m3.add_unit("", "马", "rider"), "id 不许空")
    raises(lambda: m3.add_unit("general_9", "马", "rider"), "id 不许撞将领前缀")
    raises(lambda: m3.add_unit("rider", "马", "rider"), "id 不许与已有单位重复")
    raises(lambda: m3.add_unit("tower", "马", "rider"), "★ id 不许与已有**建筑**撞")
    raises(lambda: m3.add_unit("n1", "马", "no_such"), "模板不存在被拒")

    # 删除
    m4 = fresh_model()
    m4.add_unit("test_horse", "马弓手", "rider")
    m4.remove_unit("test_horse")
    ok(not m4.doc.has(["unit", "types", "test_horse"]), "自定义兵种删掉了")
    eq([r["kind"] for r in parse(m4.text)["recruit"]["list"]],
       [r["kind"] for r in parse(fresh_model().text)["recruit"]["list"]],
       "★ 招募表那一项一起删掉（不留孤儿）")
    for uid in BUILTIN_UNITS:
        raises(lambda u=uid: fresh_model().remove_unit(u), "内置兵种不许删：%s" % uid)

    # 将领用着它 → 删掉之后要回退到还存在的兵种
    m5 = fresh_model()
    m5.set_general_type(0, "rider")
    m5.remove_unit("rider") if False else None
    m5.add_unit("tmp_unit", "临时", "rider")
    m5.set_general_type(0, "tmp_unit")
    m5.remove_unit("tmp_unit")
    eq(m5.general(0).type_id, "spearman",
       "★★ 删掉将领正在用的兵种 → 它自动改成第一个还存在的兵种")


# ======================================================================
# [3] 将领
# ======================================================================

def t_generals() -> None:
    print("\n[3] 将领（类型 + 造价 + 单独数值）")
    model = fresh_model()
    eq(model.general_count(), len(model.doc.value(["unit", "general", "types"], [])),
       "将领数 = unit.general.types 的长度（当前 10 位）")
    # ★★ 「开局护卫数」（`unit.general.escort`）这个配置项**已经整体删掉**（产品决策）：
    #   开局带几个附属兵不再由 config.json 给一个全局缺省，只能在**战役编辑器的摆放页**
    #   里一个一个摆出来。★ 这里**不是把旧断言删掉**，而是反过来钉住「键没了 + 接口没了」
    #   —— 哪天有人把配置项或调用点加回来，这一组当场变红。
    #   ⚠️ 附属兵这个**玩法机制本身一个字没改**（将领带兵 / 点一个兵选整队 / 招募 /
    #      濒死集结 / 队伍列表），去掉的只是「开局白送几个」这个配置项与它的编辑器界面。
    ok(not model.doc.has(["unit", "general", "escort"]),
       "★★ unit.general.escort 已从 config 移除（开局编制不再有全局缺省）")
    for _name in ("escort", "escort_at", "set_escort", "set_escort_at"):
        ok(not hasattr(model, _name),
           "★★ 模型不再提供 %s() 接口（配置项删了，接口不许留着当摆设）" % _name)
    # 前 3 位是开局将领；第 4..9 位只从招募池里出（同一条名册，编辑器一视同仁）。
    g0, g1, g2 = model.generals()[:3]
    eq(g0.type_id, "spearman", "将领 1 = 长枪兵")
    eq(g1.type_id, "longbowman", "将领 2 = 长弓兵")
    eq(g2.type_id, "rider", "将领 3 = 骑手")
    eq(g0.kind, "general_1", "招募卡里的 kind")
    ok(g0.inherits("hp_max"), "★ 默认：数值跟随所属兵种（stats 里是空的）")
    # ★★ 期望值取**兵种自己的数**（同一份文档）：不写死，配平改了这条也不会假失败。
    near(g0.effective_of("hp_max"), model.unit("spearman").hp_max,
         "生效血量 = 长枪兵的血量（%s）" % model.unit("spearman").hp_max)
    near(g2.effective_of("speed"), model.unit("rider").speed,
         "将领 3 的移速 = 骑手的移速（%s）" % model.unit("rider").speed)
    eq(g0.name, "将领 1", "名字默认取招募卡 label")
    # ★★ 将领的造价来自**另一张表**（`recruit.zone.list`，区划招将领那一张），
    #    不是 unit.types / recruit.list 里那个兵种造价 —— 所以这里读那一份。
    zone_row = next(r for r in model.doc.value(["recruit", "zone", "list"])
                    if r["kind"] == "general_1")
    near(g1.train_sec, zone_row["train_sec"], "区划招募读条（来自 recruit.zone.list）")
    near(g1.cost_food, zone_row["cost"]["food"], "造价 · 粮食（来自 recruit.zone.list）")
    near(g1.population_cost, 1, "造价 · 人口")
    near(g1.recruit_cooldown_sec, zone_row.get("recruit_cooldown_sec", 0),
         "招募冷却（本轮新增，来自 recruit.zone.list）")
    # ★★ 招兵读条（2026.11.2）：来自 unit.general.recruit_sec[index]，默认 10。
    near(g0.recruit_sec, 10, "★★ 招兵读条默认 10 秒（unit.general.recruit_sec）")

    # 类型 / 名称 / 造价 / 招募时间
    model.set_general_type(1, "rider")
    eq(model.general(1).type_id, "rider", "改类型 → unit.general.types[1]")
    eq(model.doc.value(["unit", "general", "types", 1]), "rider", "确实是这个键")
    model.set_general(1, "name", "西境骑将")
    eq(model.general(1).name, "西境骑将", "改名字")
    eq(model.doc.value(["unit", "general", "stats", 1, "name"]), "西境骑将", "名字写进 stats")
    eq(model.doc.value(["recruit", "zone", "list", 1, "label"]), "西境骑将",
       "★ 名字同时写进招募卡（两处一致）")
    model.set_general(1, "train_sec", 14)
    eq(model.doc.value(["recruit", "zone", "list", 1, "train_sec"]), 14, "区划招募读条")
    # ★★ 招兵读条：写 unit.general.recruit_sec[index]（与上面那条是两件事）
    model.set_general(1, "recruit_sec", 6.5)
    eq(model.doc.value(["unit", "general", "recruit_sec", 1]), 6.5, "★ 招兵读条写进将领属性")
    near(model.general(1).recruit_sec, 6.5, "模型读回同一个数")
    eq(model.doc.value(["recruit", "zone", "list", 1, "train_sec"]), 14,
       "★★ 改招兵读条**不动**区划招募读条（两条互不干扰）")
    model.set_general(1, "recruit_sec", None)
    eq(model.doc.value(["unit", "general", "recruit_sec", 1]), 10,
       "★ 清空 → 回到默认 10 秒")
    model.set_general(1, "recruit_cooldown_sec", 33)
    eq(model.doc.value(["recruit", "zone", "list", 1, "recruit_cooldown_sec"]), 33,
       "★ 招募冷却（本轮新增：招到这位之后该玩家全局锁多少秒）")
    near(model.general(1).recruit_cooldown_sec, 33, "模型读回同一个数")
    model.set_general(1, "cost_food", 80)
    eq(model.doc.value(["recruit", "zone", "list", 1, "cost", "food"]), 80, "造价 · 粮食")
    model.set_general(1, "cost_gold", 90)
    model.set_general(1, "population_cost", 3)
    # ★ 这里原来有 `model.set_escort(4)` + `eq(model.escort(), 4, "开局护卫数")` 两行：
    #   接口与配置项都删了（见 [3] 开头那一组断言），所以不再有可写的「开局护卫数」。
    raises(lambda: model.set_general_type(1, "no_such"), "类型必须是表里有的兵种")
    raises(lambda: model.set_general(model.general_count(), "name", "越界"),
           "越界的将领序号被拒")

    # 单独数值：写 / 读 / 删
    m2 = fresh_model()
    m2.set_general_stat(0, "hp_max", 260)
    g = m2.general(0)
    ok(not g.inherits("hp_max"), "写过之后 = 自己填")
    near(g.effective_of("hp_max"), 260, "生效血量 = 260")
    near(g.inherited["hp_max"], m2.unit("spearman").hp_max,
         "★ 仍然记着「跟随类型时是多少」（界面要显示它）")
    near(g.effective_of("damage"), m2.unit("spearman").damage,
         "★ 没覆盖的项还是跟随兵种")
    eq(m2.doc.value(["unit", "general", "stats", 0, "hp_max"]), 260, "写在 stats[0].hp_max")
    m2.set_general_stat(0, "damage", 33)
    m2.set_general_stat(0, "range", 1.5)
    m2.set_general_stat(0, "cooldown_sec", 0.9)
    m2.set_general_stat(0, "speed", 0.75)
    g = m2.general(0)
    near(g.effective_of("damage"), 33, "攻击")
    near(g.effective_of("range"), 1.5, "距离")
    near(g.effective_of("cooldown_sec"), 0.9, "攻速")
    near(g.effective_of("speed"), 0.75, "移速")
    m2.set_general_stat(0, "hp_max", None)
    ok(m2.general(0).inherits("hp_max"), "★ 传 None = 删掉覆盖，回到「跟随兵种」")
    ok(not m2.doc.has(["unit", "general", "stats", 0, "hp_max"]), "键真的被删了")
    near(m2.general(0).effective_of("hp_max"), m2.unit("spearman").hp_max,
         "生效值回到「跟随兵种」那一档")
    raises(lambda: m2.set_general_stat(0, "banana", 1), "不认识的将领数值被拒")

    # 老配置里没有 stats 整段时，也要能写进去
    old = parse(model.text)
    del old["unit"]["general"]["stats"]
    m3 = ConfigModel.from_text(json.dumps(old, ensure_ascii=False, indent=2))
    m3.set_general_stat(2, "damage", 40)
    eq(m3.doc.value(["unit", "general", "stats", 2, "damage"]), 40,
       "★ 配置里原本没有 stats 段 → 自动补出来，并且下标对齐")
    eq(m3.general(0).type_id, model.general(0).type_id, "补出来的段不影响 types")

    # ★★ 编制上限（本轮新增）：`unit.general.caps[i]`，与 types 同序。
    eq(model.general(0).cap, 11, "编制上限默认 11")
    model.set_general(1, "cap", 7)
    eq(model.general(1).cap, 7, "set_general(cap) 生效")
    eq(model.doc.value(["unit", "general", "caps", 1]), 7, "写在 unit.general.caps[1]")
    model.set_general(1, "cap", 0)
    eq(model.general(1).cap, 1, "★ 编制上限被夹到 ≥ 1")
    # 老配置里没有 caps 整段时也要能读能写
    old2 = parse(model.text)
    del old2["unit"]["general"]["caps"]
    m4 = ConfigModel.from_text(json.dumps(old2, ensure_ascii=False, indent=2))
    eq(m4.general(0).cap, 11, "没有 caps 段 → 退到默认 11")
    m4.set_general(2, "cap", 6)
    eq(m4.general(2).cap, 6, "补出来的 caps 段能写")
    eq(m4.general(0).cap, 11, "补出来的段不影响别的将领")


# ======================================================================
# [3b] 将领的阶 / 派系归属 / 0 阶成长 / 「加将领」
# ======================================================================

def t_general_tier_faction_growth() -> None:
    """★★ 2026.11.5：三件新东西的**数据层契约**。

    1. `unit.general.tiers[i]`   —— 阶（0~3，与 types 同序；以前写在招募表里）；
    2. `unit.general.factions[i]`—— 派系归属（一位可属多派；备战页按它过滤）；
    3. `unit.general.growth`     —— 0 阶将领的大本营成长（每级加多少血 / 攻）。

    另外验「加将领」：追加在名册末尾、七张同序表一起变长、**不进**招募九宫格。
    """
    print("\n[3b] 将领的阶 / 派系归属 / 0 阶成长 / 加将领")
    model = fresh_model()

    # ---- 阶：默认与「加 tiers 之前」逐位一致
    eq(model.general_tier(0), 1, "将领 1 默认一阶")
    eq(model.general_tier(3), 2, "将领 4 默认二阶")
    eq(model.general_tier(6), 3, "将领 7 默认三阶")
    eq(model.general_tier(9), 0, "★★ 开局将领 #0 默认零阶")
    eq(model.general(9).tier, 0, "★ General 对象也带 tier")
    eq(model.general(9).kind, "general_0", "★ 第 10 档的 kind 是 general_0（不是 general_10）")
    model.set_general_tier(0, 0)
    eq(model.doc.value(["unit", "general", "tiers", 0]), 0,
       "★ 改阶写 unit.general.tiers[0]")
    eq(model.general_tier(0), 0, "模型读回同一个数")
    model.set_general_tier(0, 9)
    eq(model.general_tier(0), 3, "★ 阶被夹到 3")
    model.set_general_tier(0, -5)
    eq(model.general_tier(0), 0, "★ 阶被夹到 0")
    # 老配置：没有 tiers 这一栏 ⇒ 退回招募表里的 tier（兼容）
    old = parse(model.text)
    del old["unit"]["general"]["tiers"]
    m_old = ConfigModel.from_text(json.dumps(old, ensure_ascii=False, indent=2))
    eq(m_old.general_tier(0), 1, "★ 没有 tiers 段 → 退回招募表的 tier（1）")
    eq(m_old.general_tier(9), 0, "…开局 #0 仍是 0 阶")
    m_old.set_general_tier(9, 1)
    eq(m_old.general_tier(9), 1, "★ 没 tiers 段时写一次 → 自动补出整段并写对位置")

    # ---- 派系归属：默认三派全勾；可多选；空 = 哪个都不显示
    eq(model.general_faction_ids(), ["native", "dynasty", "empire"],
       "派系选项来自 clan.list（原生 / 王朝 / 帝国）")
    eq(model.faction_choices(), [("native", "原生"), ("dynasty", "王朝"), ("empire", "帝国")],
       "派系下拉的 id → 名字")
    eq(model.general_factions(0), ["native", "dynasty", "empire"],
       "★★ 默认三派全勾（一位将领可属多个派系）")
    eq(model.general(0).factions, ["native", "dynasty", "empire"], "★ General 对象也带 factions")
    model.set_general_faction(0, "empire", False)
    eq(model.general_factions(0), ["native", "dynasty"], "取消一个派系")
    eq(model.doc.value(["unit", "general", "factions", 0]), ["native", "dynasty"],
       "★ 写进 unit.general.factions[0]")
    model.set_general_faction(0, "empire", True)
    eq(model.general_factions(0), ["native", "dynasty", "empire"],
       "★★ 重新勾上 → 按 clan.list 的声明顺序写回（勾选顺序不影响文件）")
    for cid, _name in model.faction_choices():
        model.set_general_faction(0, cid, False)
    eq(model.general_factions(0), [], "全取消 = 空数组（哪个派系都不显示）")
    raises(lambda: model.set_general_faction(0, "no_such_clan", True),
           "不认识的派系被拒")
    # 老配置：没有 factions 这一栏 ⇒ 全部派系都算
    old2 = parse(model.text)
    del old2["unit"]["general"]["factions"]
    m_old2 = ConfigModel.from_text(json.dumps(old2, ensure_ascii=False, indent=2))
    eq(m_old2.general_factions(0), ["native", "dynasty", "empire"],
       "★★ 没有 factions 段 → 三派全算（老配置行为不变）")

    # ---- 0 阶成长（`unit.general.growth`，全局一份）
    growth = model.general_growth()
    near(growth["hp_max_per_level"], 30, "0 阶成长 · 血量 / 级 = 30（占位）")
    near(growth["damage_per_level"], 3, "0 阶成长 · 攻击 / 级 = 3（占位）")
    model.set_general_growth("hp_max_per_level", 50)
    eq(model.doc.value(["unit", "general", "growth", "hp_max_per_level"]), 50.0,
       "★ 改成长写 unit.general.growth.hp_max_per_level")
    near(model.general_growth()["hp_max_per_level"], 50, "模型读回同一个数")
    model.set_general_growth("damage_per_level", -5)
    eq(model.doc.value(["unit", "general", "growth", "damage_per_level"]), 0.0,
       "★ 成长被夹到 ≥ 0")
    raises(lambda: model.set_general_growth("no_such_key", 1), "不认识的成长字段被拒")
    old3 = parse(model.text)
    del old3["unit"]["general"]["growth"]
    m_old3 = ConfigModel.from_text(json.dumps(old3, ensure_ascii=False, indent=2))
    near(m_old3.general_growth()["hp_max_per_level"], 0,
         "★ 没有 growth 段 → 0（老配置不会静默变强）")

    # ---- 加将领：追加在末尾，七张同序表一起变长，不进招募九宫格
    m = fresh_model()
    before = m.general_count()
    idx = m.add_general("将领 10", "spearman", 0)
    eq(idx, before, "add_general 返回末尾下标")
    eq(m.general_count(), before + 1, "★ 名册多了一位")
    ng = m.general(idx)
    eq(ng.name, "将领 10", "名字来自对话框")
    own = "spearman_lord_%d" % (before + 1)
    eq(ng.type_id, own, "★★ 类型 = 复制出来的**独立兵种**（模板 spearman）")
    ok(m.doc.has(["unit", "types", own]), "…unit.types 里多了这一条")
    eq(m.doc.value(["unit", "types", own, "name"]), "将领 10",
       "…独立兵种的名字 = 将领名")
    eq(ng.tier, 0, "阶来自对话框（默认零阶）")
    eq(ng.kind, "general_%d" % (before + 1),
       "★★ 新将领的 kind = general_<下标+1>（general_10 永不存在）")
    eq(ng.factions, ["native", "dynasty", "empire"], "★ 派系默认三派全勾")
    ok(not ng.has_recruit, "★★ 加出来的将领不进招募九宫格（没有招募条目）")
    ok(not any(r.get("kind") == "general_11"
               for r in m.doc.value(["recruit", "zone", "list"], [])),
       "…recruit.zone.list 里没有它")
    for key in ("types", "stats", "caps", "recruit_sec", "trait_ids", "tiers", "factions"):
        eq(m.doc.size(["unit", "general", key]), before + 1,
           "★★ 同序表 %s 一起变长" % key)
    idx2 = m.add_general("将领 11", "longbowman", 1)
    eq(m.general(idx2).kind, "general_%d" % (before + 2), "★ 再加一位 → kind 继续递增")
    eq(m.general(idx2).tier, 1, "…阶也可以是 1（对话框里选的）")
    eq(m.general(idx2).name, "将领 11", "…名字各是各的")
    raises(lambda: m.add_general("", "spearman"), "空名字被拒")
    raises(lambda: m.add_general("某人", "no_such_type"), "不存在的兵种被拒")
    # 开局将领 #0 的位置不能被新加的顶掉
    eq(m.general(9).kind, "general_0", "★★ 开局将领仍然在第 10 档（kind = general_0）")


# ======================================================================
# [4] 建筑：造价 / 建造时间 / 血量 / 攻击 / 每一级
# ======================================================================

def t_buildings() -> None:
    print("\n[4] 建筑")
    model = fresh_model()
    building_ids = [b.id for b in model.buildings()]
    ok("zone_center" not in building_ids, "★ 建筑表里没有区划中心（它不是建筑）")
    for required_id in ("wall", "tower", "stone_wall", "watch_tower", "base"):
        ok(required_id in building_ids, "建筑表里有「%s」" % required_id)
    wall = model.building("wall")
    eq(wall.name, "木墙", "名称")
    near(wall.hp_max, 300, "血量")
    # ★★ 城墙现在**要钱、要时间**（本次经济调参：堵掉「0 成本造墙占地」那条路）。
    #    数值不写死 —— 读出来只钉「编辑器能正确读到 config 里的数」。
    near(wall.build_sec, model.doc.value(["building", "wall", "build_sec"]),
         "建造时间来自 config（%s 秒）" % model.doc.value(["building", "wall", "build_sec"]))
    near(wall.cost_food, model.doc.value(["building", "wall", "cost", "food"]),
         "造价 · 粮食来自 config（%s）" % model.doc.value(["building", "wall", "cost", "food"]))
    near(wall.body_scale, 1.0, "本体大小")
    ok(not wall.attackable, "木墙不能攻击")
    ok(wall.buildable, "木墙在建造页里")
    eq(wall.tier, 1, "★ 木墙在第 1 行")
    near(wall.ranged_reduction, 0.9, "★★ 木墙远程免伤 90%")
    # ★ 视野（战争迷雾）：**每个建筑类型自己一个值**，与 unit.types.<id>.vision 对称
    near(wall.vision, 5.0, "★ 木墙的视野 5")
    ok(not wall.inherits_vision, "木墙写了 vision（不是吃全局兜底）")
    eq(model.building("tower").vision, 12.0, "★ 哨塔的视野 12")
    eq(model.building("base").vision, 9.0, "大本营的视野 9")
    eq(model.building("stone_wall").vision, 5.0, "★★ 石墙的视野 5")
    eq(model.building("watch_tower").vision, 15.0, "★★ 警戒塔的视野 15")
    ok(model.building("tower").vision > model.building("wall").vision,
       "★ 每个类型各写各的（塔 > 墙）")
    ok(not model.building("base").buildable, "★ 大本营不在建造页里")
    tower = model.building("tower")
    ok(tower.attackable, "哨塔能攻击")
    near(tower.damage, 12, "攻击力")
    near(tower.range, 3, "攻击距离")
    near(tower.cooldown, 0.8, "攻击速度（间隔）")
    eq(tower.max_level, 1, "★★ 哨塔没有升级表（最大等级 1）")
    eq(len(tower.levels), 0, "★★ 哨塔没有逐级数据")
    stone = model.building("stone_wall")
    ok(not stone.attackable, "★★ 石墙不能攻击")
    near(stone.hp_max, 700, "★★ 石墙 700 血")
    eq(stone.tier, 2, "★★ 石墙在第 2 行")
    watch = model.building("watch_tower")
    ok(watch.attackable, "★★ 警戒塔能攻击")
    near(watch.damage, 16, "★★ 警戒塔攻击 16")
    near(watch.range, 4, "★★ 警戒塔射程 4")
    near(watch.cooldown, 0.7, "★★ 警戒塔间隔 0.7")
    eq(watch.tier, 2, "★★ 警戒塔在第 2 行")
    base = model.building("base")
    eq(base.max_level, 3, "★★ 只有大本营有 3 级升级表")
    near(base.levels[1].hp_mult, 1.5, "大本营 2 级血量倍率 1.5")
    near(base.levels[1].cost_food, 200, "大本营升 2 级要 200 粮")
    near(base.levels[1].time_sec,
         float(model.doc.value(["upgrade", "levels", "base", 1, "time_sec"])),
         "大本营升 2 级读条 = config 里写的值（数值可调，不写死）")

    # 字段 → 键
    for field, value, path in (
            ("tier", 2, ["building", "wall", "tier"]),
            ("ranged_reduction", 0.75, ["building", "wall", "ranged_reduction"]),
            ("name", "木墙改", ["building", "wall", "name"]),
            ("buildable", False, ["building", "wall", "buildable"]),
            ("slot", 2, ["building", "wall", "slot"]),
            ("build_sec", 6, ["building", "wall", "build_sec"]),
            ("cost_food", 10, ["building", "wall", "cost", "food"]),
            ("cost_gold", 20, ["building", "wall", "cost", "gold"]),
            ("hp_max", 500, ["building", "wall", "hp_max"]),
            ("body_scale", 0.8, ["building", "wall", "body_scale"]),
            ("vision", 7, ["building", "wall", "vision"]),
            ("attackable", True, ["building", "wall", "attackable"]),
            ("damage", 9, ["building", "wall", "damage"]),
            ("range", 2, ["building", "wall", "range"]),
            ("cooldown", 1.5, ["building", "wall", "cooldown"]),
            ("color", "#123456", ["building", "wall", "color"]),
            ("desc", "说明", ["building", "wall", "desc"]),
    ):
        model.set_building("wall", field, value)
        eq(model.doc.value(path), value, "set_building(%s) → %s" % (field, ".".join(path)))
    raises(lambda: model.set_building("wall", "banana", 1), "不认识的建筑字段被拒")
    raises(lambda: model.set_building("nope", "hp_max", 1), "不存在的建筑被拒")

    # ---- ★★ 清空视野 = **删掉那个键** → 退回 fog.vision_building（与兵种那边同一条）----
    m_v = fresh_model()
    eq(m_v.doc.has(["building", "tower", "vision"]), True, "（前提）哨塔写了 vision")
    m_v.set_building("tower", "vision", None)
    eq(m_v.doc.has(["building", "tower", "vision"]), False,
       "★★ set_building(vision = None) → 删掉那个键")
    tower_v = m_v.building("tower")
    ok(tower_v.inherits_vision, "★ 于是它变成「吃全局兜底」")
    near(tower_v.vision_effective, m_v.fog_vision_building_default(),
         "★★ 生效值 = config 的 fog.vision_building（编辑器里显示的就是它）")
    near(m_v.fog_vision_building_default(), 9.0, "（前提）fog.vision_building = 9")

    # ---- ★★ 清空「排内位置」= 删掉 slot 键 → 回到按 config 顺序自动排 ----
    m_s = fresh_model()
    eq(m_s.building("wall").slot, None, "（前提）木墙没写 slot")
    m_s.set_building("wall", "slot", 2)
    eq(m_s.building("wall").slot, 2, "★ 写 slot = 建造页同一行第 2 列")
    m_s.set_building("wall", "slot", None)
    eq(m_s.doc.has(["building", "wall", "slot"]), False,
       "★★ set_building(slot = None) → 删掉那个键")
    eq(m_s.building("wall").slot, None, "于是又回到「自动补位」")

    # ★★ 升级表只剩大本营；对哨塔调用 set_level 应该被拒。
    m2 = fresh_model()
    for field, value, path in (
            ("cost_food", 260, ["upgrade", "levels", "base", 1, "cost", "food"]),
            ("cost_gold", 270, ["upgrade", "levels", "base", 1, "cost", "gold"]),
            ("time_sec", 12, ["upgrade", "levels", "base", 1, "time_sec"]),
            ("hp_mult", 1.8, ["upgrade", "levels", "base", 1, "hp_mult"]),
    ):
        m2.set_level("base", 1, field, value)
        eq(m2.doc.value(path), value, "set_level(%s) → %s" % (field, ".".join(map(str, path))))
    near(m2.building("base").levels[1].hp_of(1000), 1800, "改完倍率：大本营 2 级血量 1800")
    raises(lambda: m2.set_level("base", 9, "time_sec", 1), "越界等级被拒")
    raises(lambda: m2.set_level("base", 1, "banana", 1), "不认识的升级字段被拒")
    raises(lambda: m2.set_level("tower", 0, "hp_mult", 1),
           "★★ 哨塔没有升级表：set_level 被拒")

    # 逐级攻击：写 / 读 / 删（删 = 沿用基础值）—— 只有大本营还有等级表。
    m3 = fresh_model()
    t = m3.building("base")
    ok(not t.levels[1].has_attack("damage"), "★ 现在大本营 2 级没有自己的攻击力")
    near(t.levels[1].attack_of("damage"), 12, "没写 → 沿用基础值 12")
    m3.set_level("base", 1, "damage", 20)
    m3.set_level("base", 1, "range", 4)
    m3.set_level("base", 1, "cooldown", 0.6)
    t = m3.building("base")
    ok(t.levels[1].has_attack("damage"), "2 级有自己的攻击力了")
    near(t.levels[1].attack_of("damage"), 20, "2 级攻击 20")
    near(t.levels[1].attack_of("range"), 4, "2 级射程 4")
    near(t.levels[1].attack_of("cooldown"), 0.6, "2 级间隔 0.6")
    near(t.damage, 12, "★ 基础值没被动过（1 级还是 12）")
    eq(m3.doc.value(["upgrade", "levels", "base", 1, "damage"]), 20, "写在目标等级那一行")
    m3.set_level("base", 1, "damage", None)
    ok(not m3.building("base").levels[1].has_attack("damage"), "★ 传 None = 删掉覆盖")
    near(m3.building("base").levels[1].attack_of("damage"), 12, "回到沿用基础值 12")

    # 新建建筑
    m4 = fresh_model()
    before = m4.text
    m4.add_building("outpost", "前哨站", "tower")
    ok(m4.doc.has(["building", "outpost"]), "新建筑进了 building")
    b = m4.building("outpost")
    eq(b.name, "前哨站", "名字")
    ok(b.buildable, "★★ 新建筑一律「可建造」（否则游戏里根本出不来）")
    eq(b.slot, None, "排内位置留空（在它那一行自动补位）")
    ok(not m4.doc.has(["building", "outpost", "slot"]),
       "★ 新建筑不继承模板的 slot 键")
    near(b.damage, 12, "数值照模板（哨塔）")
    near(b.hp_max, 300, "血量照模板")
    eq(b.max_level, 1, "★★ 新建筑不再自动配升级表（最大等级 1）")
    eq(len(b.levels), 0, "★★ 新建筑没有逐级数据")
    ok(not m4.doc.has(["upgrade", "levels", "outpost"]),
       "★★ 不会生成 upgrade.levels.outpost")
    ids_after_add = [x.id for x in m4.buildings()]
    eq(ids_after_add[-1], "outpost", "建筑顺序：新的排在最后")
    for required_id in ("wall", "tower", "stone_wall", "watch_tower", "base"):
        ok(required_id in ids_after_add, "原有建筑「%s」还在" % required_id)
    ok(changed_lines(before, m4.text) > 10, "确实往文件里加了东西")
    parse(m4.text)

    m4.add_building("barrackslike", "兵营", "base")
    ok(m4.building("barrackslike").buildable, "★ 照「不可建造」的模板加，也强制成可建造")
    ok(not m4.doc.has(["upgrade", "levels", "barrackslike"]),
       "★★ 新建筑即使照大本营复制，也不带升级表")

    # 删除
    m5 = fresh_model()
    m5.add_building("outpost", "前哨站", "tower")
    m5.remove_building("outpost")
    ok(not m5.doc.has(["building", "outpost"]), "自定义建筑删掉了")
    ok(not m5.doc.has(["upgrade", "levels", "outpost"]), "★ 升级表一起删掉")
    eq([k for k in m5.doc.keys(["upgrade", "levels"]) if not k.startswith("_")],
       ["base"], "★★ 升级表里只剩大本营那一张")
    for bid in BUILTIN_BUILDINGS:
        raises(lambda b=bid: fresh_model().remove_building(b), "内置建筑不许删：%s" % bid)


# ======================================================================
# [5] 科技 —— ★★ 2026.11 已搬走
# ======================================================================

def t_techs_moved() -> None:
    """科技不再由本工具编辑（用户口径：「把单位编辑器中的科技编辑界面去掉」）。

    这条用例不删「为什么」：它钉的是**本工具碰不到 tech.* 那几段**。
    科技现在只在 `tools/tech_editor` 里编辑（两张表 + 每派槽位 + 全局上限 / 每阶金耗）。
    """
    print("\n[5] 科技已搬走：本工具不再有科技的数据层")
    model = fresh_model()
    for name in ("techs", "tech", "set_tech", "set_tech_effect",
                 "max_active", "set_max_active"):
        ok(not hasattr(model, name), "★★ ConfigModel 不再有 %s()" % name)
    from unit_editor import model as model_mod
    ok(not hasattr(model_mod, "Tech"), "★★ 模型层不再有 Tech 类")
    ok(not hasattr(model_mod, "TECH_FIELDS"), "★★ 不再有 TECH_FIELDS")
    ok(not hasattr(model_mod, "TECH_EFFECTS"), "★★ 不再有 TECH_EFFECTS")


# ======================================================================
# [6] 与游戏侧的键名契约
# ======================================================================

def t_game_contract() -> None:
    """把「游戏侧真的读那几个键」钉住。

    ★ 这一组是**跨语言契约**：logic/config.gd / building.gd / unit.gd 里那些
      `cfg.num("building.%s.hp_max")` 之类的字符串，改名的代价是「游戏静默用兜底值」。
      编辑器改了键名、游戏没跟上 —— 那种 bug 只能靠这一组断言拦下来。
    """
    print("\n[6] 与游戏侧的键名契约")
    model = fresh_model()
    for uid in model.unit_ids():
        path = ["unit", "types", uid]
        for key in ("name", "class", "ranged", "hp_max", "speed", "damage", "range",
                    "cooldown_sec", "radius_factor"):
            ok(model.doc.has(path + [key]), "unit.types.%s.%s 存在" % (uid, key))
        eq(model.doc.value(path + ["class"]) in {cid for cid, _label in model.class_choices()},
           True,
           "★ %s 的 class 是 config.gd 认的类别之一" % uid)
    for idx in range(3):
        ok(model.doc.has(["unit", "general", "types", idx]),
           "unit.general.types[%d] 存在（将领 = 带类型的队长）" % idx)
    # ★★ 反向契约：`unit.general.escort` **已经删掉**了 —— 开局带几个附属兵不再由
    #   config.json 给全局缺省（只能在战役编辑器的摆放页里摆）。这一条是**反着钉**的：
    #   谁把这个键加回来（比如为了让老代码还能跑），这里立刻变红。
    ok(not model.doc.has(["unit", "general", "escort"]),
       "★★ unit.general.escort 不存在（开局编制已改由战役编辑器摆放页决定）")
    ok(model.doc.has(["unit", "general", "stats"]), "unit.general.stats 存在（本轮新增）")
    # ★★ 2026.11：**派系专属兵种**（王朝 dy_* / 帝国 dg_*）**不在**全局 `recruit.list`
    #   里 —— 它们的招募条目挂在 `clan.list[].recruit[]` 上（见 config 的 clan 段）。
    #   所以这里的契约从「每个兵种都在 recruit.list」放宽成：
    #     · 在 recruit.list 里 → 那一条的字段必须齐全（world.gd 逐字段读）；
    #     · 不在 → 必须能在**某个派系**的招募表里找到（否则它谁都招不出来，是死数据）。
    def _clan_roster_ids() -> set:
        out = set()
        for item in (model.doc.value(["clan", "list"], []) or []):
            if not isinstance(item, dict):
                continue
            for r in (item.get("recruit") or []):
                if not isinstance(r, dict):
                    continue
                kind = str(r.get("kind", ""))
                if kind:
                    out.add(kind)
                for s in (r.get("spawn") or []):
                    if isinstance(s, dict) and str(s.get("type", "")):
                        out.add(str(s["type"]))
        return out

    clan_roster = _clan_roster_ids()
    # ★★ 2026.11：新将领的专属兵种（`dy_lord_*` / `dg_lord_*`）**没有招募条目**，
    #   它们由 `unit.general.types[]` 引用 —— 这也算「活着的数据」。
    general_types = set(model.doc.value(["unit", "general", "types"], []) or [])
    for uid in model.unit_ids():
        u = model.unit(uid)
        if not u.has_recruit:
            ok(uid in clan_roster or uid in general_types,
               "★ %s 没有任何招募条目，但被某个派系的招募表或某位将领引用" % uid)
            continue
        # ★★ 2026.11.2：条目可能挂在**任意**一张表里（全局 / 派系），按实际路径验字段。
        path = u.recruit_path
        for key in ("kind", "label", "short", "desc", "population_cost", "cost"):
            ok(model.doc.has(path + [key]),
               "%s.%s 存在（world.gd 读它）" % (u.recruit_owner, key))
        # ★★ 2026.11.2 反向契约：读条时间**不再属于兵种** —— 谁把 train_sec 加回
        #   单位条目（全局或派系都算），这里立刻变红。
        ok(not model.doc.has(path + ["train_sec"]),
           "★★ %s 的条目里**没有** train_sec（读条归将领：unit.general.recruit_sec）" % uid)
    # ★★ 将领的招兵读条表：与 types 同长，每项都是正数（默认 10）。
    rsecs = model.doc.value(["unit", "general", "recruit_sec"], [])
    ok(isinstance(rsecs, list) and len(rsecs) >= model.general_count(),
       "★★ unit.general.recruit_sec 覆盖到每一位将领（%s 项）" % len(rsecs))
    for i, v in enumerate(rsecs):
        ok(isinstance(v, (int, float)) and float(v) > 0,
           "unit.general.recruit_sec[%d] 是正数（%r）" % (i, v))
    for bid in model.building_ids():
        path = ["building", bid]
        for key in ("id", "name", "cost", "hp_max", "body_scale"):
            ok(model.doc.has(path + [key]), "building.%s.%s 存在（building.gd 读它）" % (bid, key))
        ok(model.doc.has(path + ["attackable"]), "building.%s.attackable 存在（本轮新增）" % bid)
        ok(model.doc.has(path + ["build_sec"]), "building.%s.build_sec 存在（本轮新增）" % bid)
        for key in ("blocks_player", "blocks_enemy", "body_blocks_player", "body_blocks_enemy"):
            ok(model.doc.has(path + [key]), "building.%s.%s 存在（阻挡语义在数据里）" % (bid, key))
        if bid == "tower":
            for key in ("damage", "range", "cooldown"):
                ok(model.doc.has(path + [key]), "building.tower.%s 存在（箭塔三件套）" % key)
            near(model.doc.value(path + ["damage"]), 12, "★ 箭塔伤害还是 12（没被这一轮改掉）")
    for bid in model.building_ids():
        if not model.doc.has(["upgrade", "levels", bid]):
            continue
        rows = model.doc.value(["upgrade", "levels", bid])
        ok(len(rows) >= 1, "upgrade.levels.%s 是等级表" % bid)
        eq(rows[0]["level"], 1, "★ 下标 0 = 1 级（config.gd 按 level-1 取）")
        for i, row in enumerate(rows):
            ok("hp_mult" in row, "upgrade.levels.%s[%d].hp_mult 存在" % (bid, i))
            if i > 0:
                for key in ("cost", "time_sec"):
                    ok(key in row, "upgrade.levels.%s[%d].%s 存在（升级代价）" % (bid, i, key))
    # ★★ 2026.11：科技那一段契约检查已删 —— 科技不归本工具改了。
    #   它现在由 `tools/tech_editor/test_model.py` 的 [4] 组验
    #   （编辑器的效果键注册表 ↔ logic/tech.gd 的 default_effects() 双向对齐）。

# ======================================================================
# [7] 保存 / 重载（真写一次磁盘）
# ======================================================================

def t_save_and_reload() -> None:
    print("\n[7] 保存 / 重载")
    path = tmp_copy()
    model = ConfigModel.load(path)
    ok(not model.dirty, "刚载入：不脏")
    # ★ 期望值**先读出来**：配平会调，而这些断言要钉的是「保存 / 重载这条链」，
    #   不是某个具体的血量数字。
    hp_before = model.unit("spearman").hp_max
    dmg_before = model.unit("spearman").damage
    model.set_unit("spearman", "hp_max", 175)
    ok(model.dirty, "改一笔之后：脏")
    saved = parse(path.read_text(encoding="utf-8"))
    eq(saved["unit"]["types"]["spearman"]["hp_max"], hp_before,
       "还没保存：磁盘上还是改动前那个值（%s）" % hp_before)
    model.save()
    ok(not model.dirty, "保存之后：不脏了")
    eq(parse(path.read_text(encoding="utf-8"))["unit"]["types"]["spearman"]["hp_max"], 175,
       "磁盘上确实写了 175")
    model.set_unit("spearman", "damage", 99)
    model.reload()
    eq(model.unit("spearman").damage, dmg_before, "★ 重载丢掉未保存的改动")
    eq(model.unit("spearman").hp_max, 175, "重载保留已保存的改动")
    other = path.parent / "copy.json"
    model.save(other)
    eq(model.path, other, "另存为之后，以后「保存」就写这一份")
    eq(parse(other.read_text(encoding="utf-8"))["grid"]["cols"], 24, "另存的文件内容完整")
    # 文件行尾：写出来是 LF、不带 BOM（与仓库里那份一致）
    raw = other.read_bytes()
    ok(not raw.startswith(b"\xef\xbb\xbf"), "写出来不带 BOM")
    ok(b"\r\n" not in raw, "写出来是 LF 行尾（与仓库里那份一致）")


def t_bad_file() -> None:
    print("\n[7b] 坏文件 / 坏输入")
    tmp = PROJECT_DIR / ".tmp_unit_editor_bad"
    tmp.mkdir(parents=True, exist_ok=True)
    _TMP.append(tmp)
    bad = tmp / "broken.json"
    bad.write_text("{ this is not json }", encoding="utf-8")
    raises(lambda: ConfigModel.load(bad), "坏 JSON：载入时就说清楚，而不是静默崩")
    missing = tmp / "nope.json"
    raises(lambda: ConfigModel.load(missing), "文件不存在被拒")
    doc = Doc('{"a": 1}')
    raises(lambda: doc.set(["a", "b"], 1), "往标量下面写：被拒", JsonError)
    raises(lambda: doc.remove(["a", "b"]), "删不存在的路径：被拒", JsonError)
    raises(lambda: doc.remove([]), "不能删掉根节点", JsonError)


def main() -> int:
    print("DAEEM 单位编辑器 · 数据层测试")
    print("配置文件：%s" % CONFIG)
    # ★★ 兜底：这一套测试**只许动临时副本**，真配置必须一字未改。
    #    为什么值得专门钉一条：写这份文件的是编辑器本身（`ConfigModel.save()`），
    #    而「临时脚本 / 手工试验」很容易顺手把真文件写了 —— 那样坏掉的是**随游戏发布的数值**，
    #    而且不会有任何报错（本轮真发生过一次：unit.general.stats 被写成了两位将领的覆盖）。
    real_before = CONFIG.read_bytes()
    t_text_roundtrip()
    t_unit_fields()
    t_recruit_packages()
    t_charge_fields()
    t_unit_traits()
    t_general_traits()
    t_trait_game_keys()
    t_upkeep()
    t_add_remove_unit()
    t_generals()
    t_general_tier_faction_growth()
    t_buildings()
    t_techs_moved()
    t_game_contract()
    t_save_and_reload()
    t_bad_file()
    ok(CONFIG.read_bytes() == real_before,
       "★★ 真配置（%s）在整个测试过程中一字未改（测试只动 .tmp_unit_editor_* 里的副本）"
       % CONFIG.name)
    for tmp in _TMP:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\n[CASE] test_model -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
