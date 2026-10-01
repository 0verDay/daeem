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
from unit_editor.configfile import Doc, JsonError, parse_number   # noqa: E402
from unit_editor.model import (                           # noqa: E402
    BUILTIN_BUILDINGS,
    BUILTIN_UNITS,
    TECH_EFFECTS,
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
    near(u.hp_max, 160, "血量")
    near(u.damage, 20, "攻击力")
    near(u.range, 1, "攻击距离")
    near(u.cooldown_sec, 1.0, "攻击速度（间隔秒）")
    near(u.speed, 0.6, "移动速度")
    near(u.cost_food, 50, "造价 · 粮食（来自 recruit.list）")
    near(u.cost_gold, 50, "造价 · 黄金")
    near(u.population_cost, 1, "造价 · 人口")
    near(u.train_sec, 10, "招募时间")
    ok(u.has_recruit, "它在招募表里")
    ok(model.unit("longbowman").ranged, "★ 长弓兵是远程的（远程 + 步兵 = 两个维度）")
    ok(not model.unit("enemy").has_recruit, "★ 测试敌人不在招募表里")

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
            ("train_sec", 12, ["recruit", "list", 0, "train_sec"]),
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
    eq(m3.unit("enemy").icon_char, "敌", "测试敌人也有自己的字（敌）")
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
    raises(lambda: model.set_unit("enemy", "train_sec", 5),
           "★ 不在招募表里的单位：改造价 / 招募时间会被拒（并提示先加进招募表）")

    # 把测试敌人加进招募表
    m4 = fresh_model()
    before = m4.text
    m4.add_recruit_entry("enemy")
    eq(m4.doc.size(["recruit", "list"]), 4, "加进招募表：多了一条")
    eq(m4.unit("enemy").has_recruit, True, "加完之后它有招募数值了")
    m4.set_unit("enemy", "train_sec", 6)
    eq(m4.doc.value(["recruit", "list", 3, "train_sec"]), 6, "加进去之后就能改招募时间")
    ok(changed_lines(before, m4.text) > 0, "确实动了文件")


# ======================================================================
# [2] 新建 / 删除兵种
# ======================================================================

def t_add_remove_unit() -> None:
    print("\n[2] 新建 / 删除兵种")
    model = fresh_model()
    model.add_unit("horse_archer", "马弓手", "rider")
    ok(model.doc.has(["unit", "types", "horse_archer"]), "新兵种进了 unit.types")
    u = model.unit("horse_archer")
    eq(u.name, "马弓手", "名字")
    eq(u.unit_class, "cavalry", "★ 照模板复制：归属跟着 rider（骑兵）")
    eq(u.ranged, False, "★ 远程标记也照抄（之后设计师自己改）")
    near(u.hp_max, 140, "血量照抄模板")
    eq(u.has_recruit, True, "同时建了招募表那一项")
    near(u.train_sec, 10, "招募时间照抄模板")
    near(u.cost_food, 50, "造价照抄模板")
    eq(u.label, "马弓手", "★ 命令卡标题 = 新名字")
    eq(u.icon, "", "★ 模板抄过来的那个字被删掉了（不留着模板的 icon）")
    eq(u.icon_char, "马", "★★ 新兵种地图上显示「马」（跟着名字的第一个字）")
    model.set_unit("horse_archer", "icon", "弓")
    eq(model.unit("horse_archer").icon_char, "弓", "想换就填一个自己的字")
    rows = parse(model.text)["recruit"]["list"]
    eq([r["kind"] for r in rows], ["spearman", "longbowman", "rider", "horse_archer"],
       "招募表顺序：新的排在最后")
    eq(model.unit("spearman").name, "长枪兵", "★ 模板本身没被改动")

    # 改成「马弓手 = 远程骑兵」（这就是设计师真实的下一步）
    model.set_unit("horse_archer", "ranged", True)
    model.set_unit("horse_archer", "range", 3.0)
    eq(model.unit("horse_archer").ranged, True, "改成远程")
    near(model.unit("horse_archer").range, 3.0, "改成 3 格射程")

    # 照一个**不在招募表**的模板加：招募条目按默认值新建
    m2 = fresh_model()
    m2.add_unit("zombie", "僵尸", "enemy")
    ok(m2.unit("zombie").has_recruit, "★ 模板不在招募表 → 新兵种仍然进招募表（照默认值）")
    near(m2.unit("zombie").cost_food, 50, "默认造价 50 粮")
    near(m2.unit("zombie").train_sec, 10, "默认招募 10 秒")

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
    m4.add_unit("horse_archer", "马弓手", "rider")
    m4.remove_unit("horse_archer")
    ok(not m4.doc.has(["unit", "types", "horse_archer"]), "自定义兵种删掉了")
    eq([r["kind"] for r in parse(m4.text)["recruit"]["list"]],
       ["spearman", "longbowman", "rider"], "★ 招募表那一项一起删掉（不留孤儿）")
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
    eq(model.general_count(), 3, "开局三位将领")
    # ★★ 护卫数现在是**逐将一份**：`unit.general.escort` 可以写成数组（config 里是
    #   `[4,5,6]`）。这里只钉「配了、且是正数、且三位各有各的值」——
    #   具体数值是平衡数据，不该被用例写死。逐将口径走 `escort_at(i)`。
    ok(model.escort_at(0) > 0, "开局护卫数（将领 1）是正数（%r）" % model.escort_at(0))
    ok(model.escort_at(1) > 0 and model.escort_at(2) > 0,
       "将领 2 / 3 也各有编制（%r / %r）" % (model.escort_at(1), model.escort_at(2)))
    ok(model.escort_at(2) >= model.escort_at(0),
       "★ 样例配置有意做成「后一位带得不少于前一位」（逐将不同 ⇒ 波次规模会浮动）")
    g0, g1, g2 = model.generals()
    eq(g0.type_id, "spearman", "将领 1 = 长枪兵")
    eq(g1.type_id, "longbowman", "将领 2 = 长弓兵")
    eq(g2.type_id, "rider", "将领 3 = 骑手")
    eq(g0.kind, "general_1", "招募卡里的 kind")
    ok(g0.inherits("hp_max"), "★ 默认：数值跟随所属兵种（stats 里是空的）")
    near(g0.effective_of("hp_max"), 160, "生效血量 = 长枪兵的 160")
    near(g2.effective_of("speed"), 0.9, "将领 3 的移速 = 骑手的 0.9")
    eq(g0.name, "将领 1", "名字默认取招募卡 label")
    near(g1.train_sec, 10, "招募时间")
    near(g1.cost_food, 50, "造价 · 粮食")
    near(g1.population_cost, 1, "造价 · 人口")

    # 类型 / 名称 / 造价 / 招募时间 / 护卫数
    model.set_general_type(1, "rider")
    eq(model.general(1).type_id, "rider", "改类型 → unit.general.types[1]")
    eq(model.doc.value(["unit", "general", "types", 1]), "rider", "确实是这个键")
    model.set_general(1, "name", "西境骑将")
    eq(model.general(1).name, "西境骑将", "改名字")
    eq(model.doc.value(["unit", "general", "stats", 1, "name"]), "西境骑将", "名字写进 stats")
    eq(model.doc.value(["recruit", "zone", "list", 1, "label"]), "西境骑将",
       "★ 名字同时写进招募卡（两处一致）")
    model.set_general(1, "train_sec", 14)
    eq(model.doc.value(["recruit", "zone", "list", 1, "train_sec"]), 14, "招募时间")
    model.set_general(1, "cost_food", 80)
    eq(model.doc.value(["recruit", "zone", "list", 1, "cost", "food"]), 80, "造价 · 粮食")
    model.set_general(1, "cost_gold", 90)
    model.set_general(1, "population_cost", 3)
    model.set_escort(4)
    eq(model.escort(), 4, "开局护卫数")
    raises(lambda: model.set_general_type(1, "no_such"), "类型必须是表里有的兵种")
    raises(lambda: model.set_general(9, "name", "越界"), "越界的将领序号被拒")

    # 单独数值：写 / 读 / 删
    m2 = fresh_model()
    m2.set_general_stat(0, "hp_max", 260)
    g = m2.general(0)
    ok(not g.inherits("hp_max"), "写过之后 = 自己填")
    near(g.effective_of("hp_max"), 260, "生效血量 = 260")
    near(g.inherited["hp_max"], 160, "★ 仍然记着「跟随类型时是多少」（界面要显示它）")
    near(g.effective_of("damage"), 20, "★ 没覆盖的项还是跟随兵种")
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
    near(m2.general(0).effective_of("hp_max"), 160, "生效值回到 160")
    raises(lambda: m2.set_general_stat(0, "banana", 1), "不认识的将领数值被拒")

    # 老配置里没有 stats 整段时，也要能写进去
    old = parse(model.text)
    del old["unit"]["general"]["stats"]
    m3 = ConfigModel.from_text(json.dumps(old, ensure_ascii=False, indent=2))
    m3.set_general_stat(2, "damage", 40)
    eq(m3.doc.value(["unit", "general", "stats", 2, "damage"]), 40,
       "★ 配置里原本没有 stats 段 → 自动补出来，并且下标对齐")
    eq(m3.general(0).type_id, model.general(0).type_id, "补出来的段不影响 types")


# ======================================================================
# [4] 建筑：造价 / 建造时间 / 血量 / 攻击 / 每一级
# ======================================================================

def t_buildings() -> None:
    print("\n[4] 建筑")
    model = fresh_model()
    eq([b.id for b in model.buildings()], ["wall", "tower", "base"],
       "★ 建筑表里没有区划中心（它不是建筑）")
    wall = model.building("wall")
    eq(wall.name, "城墙", "名称")
    near(wall.hp_max, 300, "血量")
    near(wall.build_sec, 0, "建造时间（默认 0 = 瞬发）")
    near(wall.cost_food, 0, "造价 · 粮食")
    near(wall.body_scale, 1.0, "本体大小")
    ok(not wall.attackable, "城墙不能攻击")
    ok(wall.buildable, "城墙在建造页里")
    # ★ 视野（战争迷雾）：**每个建筑类型自己一个值**，与 unit.types.<id>.vision 对称
    near(wall.vision, 5.0, "★ 城墙的视野 5")
    ok(not wall.inherits_vision, "城墙写了 vision（不是吃全局兜底）")
    eq(model.building("tower").vision, 12.0, "★ 箭塔的视野 12（瞭望塔看得最远）")
    eq(model.building("base").vision, 9.0, "大本营的视野 9")
    ok(model.building("tower").vision > model.building("wall").vision,
       "★ 每个类型各写各的（塔 > 墙）")
    ok(not model.building("base").buildable, "★ 大本营不在建造页里")
    tower = model.building("tower")
    ok(tower.attackable, "箭塔能攻击")
    near(tower.damage, 12, "攻击力")
    near(tower.range, 3, "攻击距离")
    near(tower.cooldown, 0.8, "攻击速度（间隔）")
    eq(tower.max_level, 3, "三级")
    near(tower.levels[1].hp_mult, 1.5, "2 级血量倍率 1.5")
    near(tower.levels[1].cost_food, 50, "升 2 级要 50 粮")
    near(tower.levels[1].time_sec, 10, "升 2 级读条 10 秒")
    near(tower.levels[2].cost_gold, 100, "升 3 级要 100 金")
    near(tower.levels[0].cost_food, 0, "1 级那行没有代价（开局就是它）")
    near(tower.levels[1].hp_of(tower.hp_max), 450, "★ 2 级血量 = 基础 × 倍率 = 450")
    near(tower.levels[2].hp_of(tower.hp_max), 675, "3 级血量 675")

    # 字段 → 键
    for field, value, path in (
            ("name", "石墙", ["building", "wall", "name"]),
            ("buildable", False, ["building", "wall", "buildable"]),
            ("hotkey", "W", ["building", "wall", "hotkey"]),
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
    eq(m_v.doc.has(["building", "tower", "vision"]), True, "（前提）箭塔写了 vision")
    m_v.set_building("tower", "vision", None)
    eq(m_v.doc.has(["building", "tower", "vision"]), False,
       "★★ set_building(vision = None) → 删掉那个键")
    tower_v = m_v.building("tower")
    ok(tower_v.inherits_vision, "★ 于是它变成「吃全局兜底」")
    near(tower_v.vision_effective, m_v.fog_vision_building_default(),
         "★★ 生效值 = config 的 fog.vision_building（编辑器里显示的就是它）")
    near(m_v.fog_vision_building_default(), 9.0, "（前提）fog.vision_building = 9")

    # 升级表：每一级
    m2 = fresh_model()
    for field, value, path in (
            ("cost_food", 60, ["upgrade", "levels", "tower", 1, "cost", "food"]),
            ("cost_gold", 70, ["upgrade", "levels", "tower", 1, "cost", "gold"]),
            ("time_sec", 12, ["upgrade", "levels", "tower", 1, "time_sec"]),
            ("hp_mult", 1.8, ["upgrade", "levels", "tower", 1, "hp_mult"]),
    ):
        m2.set_level("tower", 1, field, value)
        eq(m2.doc.value(path), value, "set_level(%s) → %s" % (field, ".".join(map(str, path))))
    near(m2.building("tower").levels[1].hp_of(300), 540, "改完倍率：2 级血量 540")
    raises(lambda: m2.set_level("tower", 9, "time_sec", 1), "越界等级被拒")
    raises(lambda: m2.set_level("tower", 1, "banana", 1), "不认识的升级字段被拒")

    # 逐级攻击：写 / 读 / 删（删 = 沿用基础值）
    m3 = fresh_model()
    t = m3.building("tower")
    ok(not t.levels[1].has_attack("damage"), "★ 现在 2 级没有自己的攻击力")
    near(t.levels[1].attack_of("damage"), 12, "没写 → 沿用基础值 12")
    m3.set_level("tower", 1, "damage", 20)
    m3.set_level("tower", 1, "range", 4)
    m3.set_level("tower", 1, "cooldown", 0.6)
    t = m3.building("tower")
    ok(t.levels[1].has_attack("damage"), "2 级有自己的攻击力了")
    near(t.levels[1].attack_of("damage"), 20, "2 级攻击 20")
    near(t.levels[1].attack_of("range"), 4, "2 级射程 4")
    near(t.levels[1].attack_of("cooldown"), 0.6, "2 级间隔 0.6")
    near(t.damage, 12, "★ 基础值没被动过（1 级还是 12）")
    eq(m3.doc.value(["upgrade", "levels", "tower", 1, "damage"]), 20, "写在目标等级那一行")
    m3.set_level("tower", 1, "damage", None)
    ok(not m3.building("tower").levels[1].has_attack("damage"), "★ 传 None = 删掉覆盖")
    near(m3.building("tower").levels[1].attack_of("damage"), 12, "回到沿用基础值 12")

    # 新建建筑
    m4 = fresh_model()
    before = m4.text
    m4.add_building("outpost", "前哨站", "tower")
    ok(m4.doc.has(["building", "outpost"]), "新建筑进了 building")
    b = m4.building("outpost")
    eq(b.name, "前哨站", "名字")
    ok(b.buildable, "★★ 新建筑一律「可建造」（否则游戏里根本出不来）")
    eq(b.hotkey, "", "快捷键留空（设计师自己填）")
    near(b.damage, 12, "数值照模板（箭塔）")
    near(b.hp_max, 300, "血量照模板")
    eq(b.max_level, 3, "★ 连升级表一起复制（3 级）")
    near(b.levels[1].cost_food, 50, "升级表的数字也照抄")
    eq([lv.id for lv in m4.buildings()] == ["wall", "tower", "base", "outpost"], True,
       "建筑顺序：新的排在最后")
    ok(changed_lines(before, m4.text) > 10, "确实往文件里加了东西")
    parse(m4.text)

    m4.add_building("barrackslike", "兵营", "base")
    ok(m4.building("barrackslike").buildable, "★ 照「不可建造」的模板加，也强制成可建造")

    # 删除
    m5 = fresh_model()
    m5.add_building("outpost", "前哨站", "tower")
    m5.remove_building("outpost")
    ok(not m5.doc.has(["building", "outpost"]), "自定义建筑删掉了")
    ok(not m5.doc.has(["upgrade", "levels", "outpost"]), "★ 升级表一起删掉")
    eq([k for k in m5.doc.keys(["upgrade", "levels"]) if not k.startswith("_")],
       ["base", "wall", "tower"], "升级表里只剩内置那三张")
    for bid in BUILTIN_BUILDINGS:
        raises(lambda b=bid: fresh_model().remove_building(b), "内置建筑不许删：%s" % bid)


# ======================================================================
# [5] 科技
# ======================================================================

def t_techs() -> None:
    print("\n[5] 科技")
    model = fresh_model()
    techs = model.techs()
    eq(len(techs), 9, "九条科技（3×3）")
    eq(model.max_active(), 3, "同一时间最多启用 3 条")
    eq(techs[0].name, "粮食产量 I", "名称")
    eq(techs[0].line, "粮食 +1", "第二行小字")
    ok(techs[0].desc, "有悬停说明")
    near(techs[0].effect_value("food_per_tile_per_sec"), 1, "加成数值")
    eq(techs[0].effect_label, "粮食产量 +1", "列表里那一句话")
    near(techs[8].effect_value("zone_population_mult"), 0.1, "人口科技是倍率 0.1")

    model.set_tech(0, "name", "粮食产量 甲")
    eq(model.doc.value(["tech", "list", 0, "name"]), "粮食产量 甲", "改名称")
    model.set_tech(0, "line", "粮食 +++")
    eq(model.doc.value(["tech", "list", 0, "line"]), "粮食 +++", "改小字")
    model.set_tech(0, "desc", "说明改过了")
    eq(model.doc.value(["tech", "list", 0, "desc"]), "说明改过了", "改说明")
    model.set_tech_effect(0, "food_per_tile_per_sec", 2.5)
    eq(model.doc.value(["tech", "list", 0, "effect", "food_per_tile_per_sec"]), 2.5,
       "改加成数值")
    eq(model.tech(0).effect_value("food_per_tile_per_sec"), 2.5, "读回来是 2.5")
    model.set_max_active(2)
    eq(model.max_active(), 2, "改「最多启用几条」")
    raises(lambda: model.set_tech(0, "id", "x"), "id 不许改（它是存档 / 引用的键）")
    raises(lambda: model.set_tech(0, "banana", "x"), "不认识的科技字段被拒")
    raises(lambda: model.set_tech(99, "name", "x"), "越界的科技序号被拒")
    raises(lambda: model.set_tech_effect(0, "banana", 1), "不认识的加成被拒")

    # 加成：加一条 / 删一条 / 换成另一种形状
    m2 = fresh_model()
    m2.set_tech_effect(0, "gold_per_tile_per_sec", 3)
    eq(sorted(k for k in m2.tech(0).effect if not k.startswith("_")),
       ["food_per_tile_per_sec", "gold_per_tile_per_sec"], "★ 一条科技可以同时有两条加成")
    m2.set_tech_effect(0, "food_per_tile_per_sec", None)
    eq(list(m2.tech(0).effect.keys()), ["gold_per_tile_per_sec"], "删掉其中一条")
    eq(m2.tech(0).effect_label, "黄金产量 +3", "列表里那句话跟着变")
    eq(m2.tech(0).effect_value("food_per_tile_per_sec"), None, "删掉之后读不到")
    ok(TECH_EFFECTS and all(len(t) == 3 for t in TECH_EFFECTS), "加成表是（键, 名字, 说明）三件套")


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
        eq(model.doc.value(path + ["class"]) in ("infantry", "cavalry"), True,
           "★ %s 的 class 是 config.gd 认的那两种之一" % uid)
    for idx in range(3):
        ok(model.doc.has(["unit", "general", "types", idx]),
           "unit.general.types[%d] 存在（将领 = 带类型的队长）" % idx)
    ok(model.doc.has(["unit", "general", "escort"]), "unit.general.escort 存在")
    ok(model.doc.has(["unit", "general", "stats"]), "unit.general.stats 存在（本轮新增）")
    for uid in model.unit_ids():
        if uid == "enemy":
            continue
        idx = model.unit(uid).recruit_index
        ok(idx >= 0, "recruit.list 里有 %s 那一项" % uid)
        for key in ("kind", "label", "short", "desc", "train_sec", "population_cost", "cost"):
            ok(model.doc.has(["recruit", "list", idx, key]),
               "recruit.list[%d].%s 存在（world.gd 读它）" % (idx, key))
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
    for tech in model.techs():
        ok(tech.id, "科技有 id")
        path = ["tech", "list", tech.index]
        for key in ("id", "name", "line", "desc", "effect"):
            ok(model.doc.has(path + [key]), "tech.list[%d].%s 存在（tech.gd 读它）" % (tech.index, key))
        known = [k for k, _l, _h in TECH_EFFECTS]
        for key in tech.effect:
            if key.startswith("_"):
                continue
            ok(key in known, "★ 科技 %s 的加成键 %s 在编辑器的已知形状里" % (tech.id, key))


# ======================================================================
# [7] 保存 / 重载（真写一次磁盘）
# ======================================================================

def t_save_and_reload() -> None:
    print("\n[7] 保存 / 重载")
    path = tmp_copy()
    model = ConfigModel.load(path)
    ok(not model.dirty, "刚载入：不脏")
    model.set_unit("spearman", "hp_max", 175)
    ok(model.dirty, "改一笔之后：脏")
    saved = parse(path.read_text(encoding="utf-8"))
    eq(saved["unit"]["types"]["spearman"]["hp_max"], 160, "还没保存：磁盘上还是 160")
    model.save()
    ok(not model.dirty, "保存之后：不脏了")
    eq(parse(path.read_text(encoding="utf-8"))["unit"]["types"]["spearman"]["hp_max"], 175,
       "磁盘上确实写了 175")
    model.set_unit("spearman", "damage", 99)
    model.reload()
    eq(model.unit("spearman").damage, 20, "★ 重载丢掉未保存的改动")
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
    t_add_remove_unit()
    t_generals()
    t_buildings()
    t_techs()
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
