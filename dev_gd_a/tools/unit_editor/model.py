"""model.py —— 单位 / 将领 / 建筑 / 科技的**数据层**（无界面，可无头测试）。

职责边界（与地图编辑器那一套对齐）：

    configfile.py  「一份带注释的 JSON 文本怎么原地改几个字符」——只管文本
    model.py       「游戏里的单位 / 建筑 / 科技是什么」——只管语义与校验
    app.py         tkinter 界面

★ 数据只有一个来源：`daeem/data/config.json`（`logic/config.gd` 读的就是它）。
  本模块**不复制**任何数值：每一个字段都直说它落在 JSON 的哪条路径上。
  游戏侧读的键见 docs/route.md 那一节，两边对不上的话 test_model.py 会红。

★ 字段表（`UNIT_FIELDS` / `BUILDING_FIELDS` / …）是**给界面看的**：
  界面照它生成表单，所以「加一个可编辑字段」= 在表里加一行 + 在 set_* 里认一下，
  不用动 app.py。
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from . import configfile
from .configfile import Doc, JsonError, Path as JsonPath, parse_number

#: 单位大类的 id → 界面上的说法（中文只在数据层这一处，界面不再写一遍）
CLASS_CHOICES: Tuple[Tuple[str, str], ...] = (
    ("infantry", "步兵"),
    ("cavalry", "骑兵"),
)

#: 图标 = **地图上显示的那一个字**（本轮改版：原来是借一份线条预制体）。
#: 空字符串 = 不写这个键 → 游戏侧退成「名字的第一个字」（见 `Unit.icon_char`）。
#: ⚠️ 这段提示**只写一行**是刻意的：编辑器右栏是「装得下就不许滚」的，
#:   提示每多折一行就有一张表单在 1080p 上装不下（见 test_app.py 的 [8] 那一节）。
ICON_HINT = "地图上就显示这**一个字**；不写 = 用名字的第一个字（将领用所属兵种的字）"

#: ★ 视野（战争迷雾）：半径是**格**，从单位所在的**格心**算起，被**山脉**挡住视线。
#: 兵种写在 `unit.types.<id>.vision`；将领想单独调就写 `unit.general.stats[i].vision`。
#: ⚠️ 这段提示**只写一行**是刻意的：编辑器右栏那一列是「装得下就不许滚」的，
#:   提示每多折一行，就有人的表单装不下（见 test_app.py 的 [8] 那一节）。
VISION_HINT = "战争迷雾的视野半径（格）：从单位所在的格心算起，视线被山脉挡住（其他地形不挡）"

#: 科技效果的形状（`logic/tech.gd` 的 effects_of 认这几个键；数值全是单个数字）
TECH_EFFECTS: Tuple[Tuple[str, str, str], ...] = (
    ("food_per_tile_per_sec", "粮食产量", "每地块每秒 +n（与地图编辑器给区划配的产能同一口径）"),
    ("gold_per_tile_per_sec", "黄金产量", "每地块每秒 +n"),
    ("building_hp_mult", "己方建筑血量上限", "倍率（1.1 = +10%），实时生效"),
    ("leader_hp_mult", "己方将领血量上限", "倍率（1.1 = +10%），实时生效"),
    ("zone_population_mult", "己方区划人口增长", "倍率（1.25 = +25%），只影响涨得多快"),
)

#: 内置单位 / 建筑：**不许删**（代码与测试按 id 引用它们）。删掉它们不会报错，
#: 而是让游戏在某条路上静默走兜底值 —— 那正是 docs/pitfalls.md 反复说的坑。
#: ★★ 本次：「测试敌人」（enemy）从内置名单里**移除**（用户口径：「将『敌』从
#:    editor 工具中移除」）—— 它已经从 data/config.json 的 unit.types 里删掉了，
#:    调试刷兵改刷长枪兵，所以编辑器不该再列出这一条。
#:    ⚠️ 它同时也是一个「可以被删除」的自定义单位 id 了；若某个旧地图/关卡里还写着
#:       kind = "enemy"，游戏会退到 unit.<default> 的兜底值（不崩）。
BUILTIN_UNITS: Tuple[str, ...] = ("spearman", "longbowman", "rider")
BUILTIN_BUILDINGS: Tuple[str, ...] = ("wall", "tower", "base")

#: id 的写法：小写字母开头 + 小写字母/数字/下划线。
#: ★ 为什么必须限制：id 会进 `kind`（存档 / 快照 / 地图 JSON 都在用它），
#:   一个带空格或大写的 id 会在别处变成两个不同的字符串。
ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")

#: 将领类 id 的前缀（`general` / `general_1`…）—— 单位 id 不许撞上它
GENERAL_KINDS = ("general",)


class ModelError(Exception):
    """数据层说不行的原因（界面直接显示这句话）。"""


# ======================================================================
# 字段表（界面照它生成表单）
# ======================================================================

class Field:
    """一个可编辑字段的界面描述。

    kind: "int" / "float" / "text" / "bool" / "choice"
    """

    def __init__(self, key: str, label: str, kind: str, hint: str = "",
                 choices: Sequence[Tuple[str, str]] = (), minimum: Optional[float] = None,
                 maximum: Optional[float] = None) -> None:
        self.key = key
        self.label = label
        self.kind = kind
        self.hint = hint
        self.choices = tuple(choices)
        self.minimum = minimum
        self.maximum = maximum

    def clamp(self, value: Any) -> Any:
        """按 min/max 夹一下（只挡误输入，不做玩法判断）。"""
        if self.kind in ("int", "float") and isinstance(value, (int, float)):
            if self.minimum is not None and value < self.minimum:
                return self.minimum
            if self.maximum is not None and value > self.maximum:
                return self.maximum
        return value

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<Field %s:%s>" % (self.key, self.kind)


#: 单位（`unit.types.<id>`）—— 需求里那八项 + 半径 / 图标
UNIT_FIELDS: Tuple[Field, ...] = (
    Field("name", "名称", "text", "显示在单位详情 / 悬停里的名字"),
    Field("unit_class", "归属", "choice", "步兵 / 骑兵 —— 「按兵种额外伤害」按它算",
          choices=CLASS_CHOICES),
    Field("ranged", "远程", "bool", "远程单位（弓箭手那种）：与归属是两维，长弓兵 = 远程步兵"),
    Field("hp_max", "血量", "float", "单位出生时的血量上限", minimum=1),
    Field("damage", "攻击力", "float", "每次攻击造成的伤害", minimum=0),
    Field("range", "攻击距离", "float", "单位：**格**（1 = 贴脸）", minimum=0),
    Field("cooldown_sec", "攻击速度", "float",
          "两次攻击之间的**间隔秒数**：数字越小打得越快", minimum=0.01),
    Field("speed", "移动速度", "float", "格 / 秒（森林里会乘 unit.forest_mult）", minimum=0),
    Field("radius_factor", "身体半径", "float", "格；渲染与射程判定共用", minimum=0.01, maximum=0.5),
    Field("icon", "地图上的字", "text", ICON_HINT),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
)

#: 招募（`recruit.list[]`，按 kind 找那一项）—— 造价与读条
RECRUIT_FIELDS: Tuple[Field, ...] = (
    Field("cost_food", "造价 · 粮食", "float", minimum=0),
    Field("cost_gold", "造价 · 黄金", "float", minimum=0),
    Field("population_cost", "造价 · 人口", "float",
          "扣的是**将领所在区划**的人口（不是全局人口）", minimum=0),
    Field("train_sec", "招募时间", "float", "每个单位的读条秒数", minimum=0),
    Field("label", "命令卡名字", "text", "右下「单位」页那一格的标题（默认跟名称同步）"),
    Field("short", "命令卡方框字", "text", "格子里那个方框写的字（一般一个字）"),
    Field("desc", "命令卡说明", "text", "悬停详情里的一句话"),
)

#: 将领的数值覆盖（`unit.general.stats[i]`；没写的键 = 跟随所属兵种）
GENERAL_STAT_FIELDS: Tuple[Field, ...] = (
    Field("hp_max", "血量", "float", minimum=1),
    Field("damage", "攻击力", "float", minimum=0),
    Field("range", "攻击距离", "float", minimum=0),
    Field("cooldown_sec", "攻击速度", "float", minimum=0.01),
    Field("speed", "移动速度", "float", minimum=0),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
)

#: 建筑（`building.<type>`）
BUILDING_FIELDS: Tuple[Field, ...] = (
    Field("name", "名称", "text", "地图上 / 建造页里的名字"),
    Field("buildable", "可建造", "bool", "会不会出现在右下「建筑」页的命令卡里"),
    Field("hotkey", "快捷键", "text",
          "建造页那一格上的快捷键字母（可空）。⚠️ 别用已经被占用的键："
          "N（区划名字）/ P（暂停）/ E（刷敌人）/ G / 数字 1~3 —— 占了就会把那个键抢走"),
    Field("build_sec", "建造时间", "float",
          "秒。**0 = 瞬发**（默认，与从前一致）；> 0 就要读条，读条期间不能攻击", minimum=0),
    Field("cost_food", "造价 · 粮食", "float",
          "economy.enabled = false 时建造免费（那个开关只管建造）", minimum=0),
    Field("cost_gold", "造价 · 黄金", "float", minimum=0),
    Field("hp_max", "血量", "float", "基础血量上限；等级与科技都在它上面乘倍率", minimum=1),
    Field("body_scale", "本体大小", "float",
          "本体边长占一格的比例（渲染与碰撞共用）：1.0 = 填满整格", minimum=0.05, maximum=1.0),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
    Field("attackable", "可攻击", "bool", "不打勾 = 不显示也不需要下面的攻击三属性"),
    Field("damage", "攻击力", "float", minimum=0),
    Field("range", "攻击距离", "float", "格", minimum=0),
    Field("cooldown", "攻击速度", "float", "两次攻击之间的间隔秒数", minimum=0.01),
    Field("color", "地图颜色", "text", "十六进制，例如 #8d6e63"),
    Field("desc", "说明", "text", "建造页 / 悬停里的一句话"),
)

#: 升级表的**每一级**（`upgrade.levels.<type>[k]`）—— 下标 0 = 1 级
LEVEL_FIELDS: Tuple[Field, ...] = (
    Field("cost_food", "需要的价格 · 粮食", "float", "升到**这一级**要花的钱（1 级那行没意义）",
          minimum=0),
    Field("cost_gold", "需要的价格 · 黄金", "float", minimum=0),
    Field("time_sec", "需要的读条时间", "float", "秒", minimum=0),
    Field("hp_mult", "血量倍率", "float",
          "这一级的血量上限倍率：本级的血量 = 基础血量 × 这个倍率", minimum=0.01),
)

#: 升级表里**可以省**的攻击三属性（没写 = 沿用基础值）—— 单独一张表，
#: 因为它们的「空」是有意义的（与 hp_mult 必须有个数不同）。
LEVEL_ATTACK_FIELDS: Tuple[Field, ...] = (
    Field("damage", "攻击力", "float", minimum=0),
    Field("range", "攻击距离", "float", minimum=0),
    Field("cooldown", "攻击速度", "float", minimum=0.01),
)

#: 科技（`tech.list[]`）
TECH_FIELDS: Tuple[Field, ...] = (
    Field("name", "名称", "text", "九格里的第一行"),
    Field("line", "第二行小字", "text", "格子里的效果小字（例如「粮食 +1」）"),
    Field("desc", "说明", "text", "鼠标悬停时那块详情面板里的一句话"),
)


# ======================================================================
# 读值的小工具
# ======================================================================

def _f(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _b(value: Any, default: bool = False) -> bool:
    return bool(value) if isinstance(value, bool) else default


def _s(value: Any, default: str = "") -> str:
    return value if isinstance(value, str) else default


def to_number(text: str) -> Optional[float]:
    """输入框文字 → 数字（非法返回 None）。"""
    return parse_number(text)


def fmt_number(value: Any) -> str:
    """数字 → 界面 / 日志上的写法：**整数不带小数点**（`10` 而不是 `10.0`）。

    ★ 这一条不是审美问题：编辑器把输入框里的字原样写回文件，
      显示成 `10.0` 会诱导设计师把本来写 `10` 的地方改成 `10.0`（纯 diff 噪音）。
    """
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, float):
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return ("%.4f" % value).rstrip("0").rstrip(".")
    if value is None:
        return ""
    return str(value)


# ======================================================================
# 只读快照（界面列表 / 表单都读它们，不直接摸 Doc）
# ======================================================================

class Unit:
    """一个单位类型 + 它在招募表里的那一项（没有就是 has_recruit = False）。"""

    def __init__(self, uid: str, data: Dict[str, Any],
                 recruit: Optional[Dict[str, Any]], recruit_index: int,
                 fog_default: float = 0.0) -> None:
        self.id = uid
        #: 这一条在 JSON 里的**原文**（判「哪个键真的写了」要它，不能只看取到的数）
        self.raw: Dict[str, Any] = dict(data)
        #: config 的 `fog.vision_default`（没写 vision 的兵种实际生效的那个数）
        self.fog_default = fog_default
        self.name = _s(data.get("name"), uid)
        self.unit_class = _s(data.get("class"), "infantry")
        self.ranged = _b(data.get("ranged"), False)
        self.hp_max = _f(data.get("hp_max"), 0.0)
        self.damage = _f(data.get("damage"), 0.0)
        self.range = _f(data.get("range"), 0.0)
        self.cooldown_sec = _f(data.get("cooldown_sec"), 0.0)
        self.speed = _f(data.get("speed"), 0.0)
        self.radius_factor = _f(data.get("radius_factor"), 0.0)
        self.icon = _s(data.get("icon"), "")
        #: ★ 视野半径（格）—— 战争迷雾。**读的是「写了的那个数」**：
        #: 没写 = 0，界面上得显示 `vision_effective`（免得看着像「这个兵是瞎子」）。
        self.vision = _f(data.get("vision"), 0.0)
        self.has_recruit = recruit is not None
        self.recruit_index = recruit_index
        rec = recruit or {}
        cost = rec.get("cost") if isinstance(rec.get("cost"), dict) else {}
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.population_cost = _f(rec.get("population_cost"), 0.0)
        self.train_sec = _f(rec.get("train_sec"), 0.0)
        self.label = _s(rec.get("label"), self.name)
        self.short = _s(rec.get("short"), "")
        self.desc = _s(rec.get("desc"), "")

    @property
    def builtin(self) -> bool:
        return self.id in BUILTIN_UNITS

    @property
    def icon_char(self) -> str:
        """**真正画在地图上的那个字**：`icon` → 名字的第一个字 → `?`。

        ★ 与游戏侧 `logic/config.gd` 的 `unit_icon_of()` 是**同一条规则**，
          两边各有一份实现是刻意的：编辑器要能在设计师改名字时**当场**显示
          「不填字的话会显示成什么」，不可能去问游戏。
          规则只有三行，两边都有断言钉着（`test_model.py` / `tests/test_unit_editor.gd`）。
        """
        if self.icon:
            return self.icon[:1]
        if self.name:
            return self.name[:1]
        return "?"

    @property
    def class_label(self) -> str:
        return dict(CLASS_CHOICES).get(self.unit_class, self.unit_class)

    @property
    def vision_effective(self) -> float:
        """**实际生效**的视野半径（格）。

        ★ 数据里写了 `vision` 就是它；没写就是 config 的 `fog.vision_default`
          （游戏侧 `cfg.unit_vision_of()` 的兜底是同一条规则）。界面上显示这一个值，
          免得一个没写 vision 的兵种在编辑器里显示成 0（看着像「这个兵是瞎子」）。
        """
        if "vision" in self.raw:
            return self.vision
        return _f(self.fog_default, 0.0)

    @property
    def inherits_vision(self) -> bool:
        """视野是不是「没写、吃全局兜底」的（界面要标出来）。"""
        return "vision" not in self.raw

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<Unit %s %s>" % (self.id, self.name)


class General:
    """一位将领：类型（决定兵种数值）+ 可选的数值覆盖 + 招募那一项。"""

    def __init__(self, index: int, kind: str, type_id: str, override: Dict[str, Any],
                 recruit: Optional[Dict[str, Any]], defaults: Dict[str, Any]) -> None:
        self.index = index
        self.kind = kind
        self.type_id = type_id
        self.override = dict(override)
        rec = recruit or {}
        cost = rec.get("cost") if isinstance(rec.get("cost"), dict) else {}
        self.has_recruit = recruit is not None
        self.name = _s(self.override.get("name"), _s(rec.get("label"), "将领 %d" % (index + 1)))
        self.label = _s(rec.get("label"), self.name)
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.population_cost = _f(rec.get("population_cost"), 0.0)
        self.train_sec = _f(rec.get("train_sec"), 0.0)
        #: 所属兵种那一档的数值（「跟随兵种」时显示的就是它）
        self.inherited = dict(defaults)
        #: 真正生效的数值 = 覆盖 ⊕ 兵种
        self.effective = dict(defaults)
        # ★ 可覆盖的数值键全在这里（与 GENERAL_STAT_FIELDS 同序）。
        #   ⚠️ 加一个可覆盖字段就必须同时加进 GENERAL_STAT_FIELDS（那张表是界面的来源）
        #      和这一行 —— 少一处就会「界面上有输入框、改了却没生效」。
        for key in ("hp_max", "damage", "range", "cooldown_sec", "speed", "vision"):
            if key in self.override and isinstance(self.override[key], (int, float)):
                self.effective[key] = float(self.override[key])

    def inherits(self, stat: str) -> bool:
        return stat not in self.override or not isinstance(self.override[stat], (int, float))

    def effective_of(self, stat: str) -> float:
        return _f(self.effective.get(stat), 0.0)

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<General %d %s>" % (self.index + 1, self.type_id)


class Level:
    """升级表的第 k 级（下标 0 = 1 级）。"""

    def __init__(self, index: int, row: Dict[str, Any], base: Dict[str, Any]) -> None:
        self.index = index
        self.level = index + 1
        cost = row.get("cost") if isinstance(row.get("cost"), dict) else {}
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.time_sec = _f(row.get("time_sec"), 0.0)
        self.hp_mult = _f(row.get("hp_mult"), 1.0)
        #: 基础（1 级 / building.<type> 那一档）的攻击三属性
        self.base = dict(base)
        #: 这一级**自己的**覆盖（键存在 = 数据里真的写了）
        self.attack: Dict[str, float] = {}
        for key in ("damage", "range", "cooldown"):
            if isinstance(row.get(key), (int, float)):
                self.attack[key] = float(row[key])

    def has_attack(self, key: str) -> bool:
        return key in self.attack

    def attack_of(self, key: str) -> float:
        """这一级的攻击数值（没写 = 沿用基础值）。"""
        return self.attack.get(key, _f(self.base.get(key), 0.0))

    def hp_of(self, base_hp: float) -> float:
        return base_hp * self.hp_mult

    def field(self, key: str) -> Any:
        return getattr(self, key, None)


class Building:
    """一个建筑类型 + 它的升级表。"""

    def __init__(self, bid: str, data: Dict[str, Any], levels: List[Dict[str, Any]],
                 fog_default: float = 0.0) -> None:
        self.id = bid
        #: 这一条在 JSON 里的**原文**（判「哪个键真的写了」要它，不能只看取到的数）
        self.raw: Dict[str, Any] = dict(data)
        #: config 的 `fog.vision_building`（没写 vision 的建筑实际生效的那个数）
        self.fog_default = fog_default
        self.name = _s(data.get("name"), bid)
        self.buildable = _b(data.get("buildable"), False)
        self.hotkey = _s(data.get("hotkey"), "")
        self.build_sec = _f(data.get("build_sec"), 0.0)
        cost = data.get("cost") if isinstance(data.get("cost"), dict) else {}
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.hp_max = _f(data.get("hp_max"), 0.0)
        self.body_scale = _f(data.get("body_scale"), 1.0)
        self.attackable = _b(data.get("attackable"), False)
        self.damage = _f(data.get("damage"), 0.0)
        self.range = _f(data.get("range"), 0.0)
        self.cooldown = _f(data.get("cooldown"), 0.0)
        #: ★ 视野半径（格）—— 战争迷雾。没写那个键时显示的是 `vision_effective`
        self.vision = _f(data.get("vision"), 0.0)
        self.color = _s(data.get("color"), "#888888")
        self.desc = _s(data.get("desc"), "")
        base = {"damage": self.damage, "range": self.range, "cooldown": self.cooldown}
        self.levels = [Level(i, row, base) for i, row in enumerate(levels)]

    @property
    def vision_effective(self) -> float:
        """**实际生效**的视野半径（格）。

        ★ 与 `Unit.vision_effective` 是同一条规则：数据里写了 `vision` 就是它，
          没写就是 config 的 `fog.vision_building`（游戏侧 `cfg.building_vision_of()`
          的兜底）。界面上显示这一个值，免得没写的建筑显示成 0。
        """
        if "vision" in self.raw:
            return self.vision
        return _f(self.fog_default, 0.0)

    @property
    def inherits_vision(self) -> bool:
        """视野是不是「没写、吃全局兜底」的（界面要标出来）。"""
        return "vision" not in self.raw

    @property
    def builtin(self) -> bool:
        return self.id in BUILTIN_BUILDINGS

    @property
    def max_level(self) -> int:
        return max(1, len(self.levels))

    def level(self, index: int) -> Optional[Level]:
        if 0 <= index < len(self.levels):
            return self.levels[index]
        return None

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<Building %s %s>" % (self.id, self.name)


class Tech:
    """一条科技。"""

    def __init__(self, index: int, data: Dict[str, Any]) -> None:
        self.index = index
        self.id = _s(data.get("id"), "")
        self.name = _s(data.get("name"), self.id)
        self.line = _s(data.get("line"), "")
        self.desc = _s(data.get("desc"), "")
        self.effect: Dict[str, Any] = dict(data.get("effect")) \
            if isinstance(data.get("effect"), dict) else {}

    def effect_value(self, key: str) -> Optional[float]:
        value = self.effect.get(key)
        return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) \
            else None

    @property
    def effect_label(self) -> str:
        """给列表用的一句话（第一条加成）。"""
        for key, label, _hint in TECH_EFFECTS:
            value = self.effect_value(key)
            if value is not None:
                return "%s %+g" % (label, value)
        return "（没有加成）"

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<Tech %s %s>" % (self.id, self.name)


# ======================================================================
# 模型
# ======================================================================

class ConfigModel:
    """`data/config.json` 的数据层。

    所有写操作都会**立刻**落到 Doc 的文本上（Doc 每次都重新解析），
    所以「界面看到的」与「存盘的」永远是同一份东西。
    """

    def __init__(self, doc: Doc, path: Optional[Path] = None) -> None:
        self.doc = doc
        self.path = Path(path) if path is not None else None
        #: 上次保存时的文本（判断「脏」用；None = 从没保存过，也算脏）
        self.saved_text: Optional[str] = None

    # ------------------------------------------------------------------
    # 载入 / 保存
    # ------------------------------------------------------------------

    @staticmethod
    def load(path: Path) -> "ConfigModel":
        path = Path(path)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ModelError("读不到配置文件：%s（%s）" % (path, exc))
        try:
            doc = Doc(text)
        except JsonError as exc:
            raise ModelError("%s 不是合法的 JSON：%s" % (path.name, exc))
        model = ConfigModel(doc, path)
        model.saved_text = doc.text
        return model

    @staticmethod
    def from_text(text: str, path: Optional[Path] = None) -> "ConfigModel":
        return ConfigModel(Doc(text), path)

    @property
    def text(self) -> str:
        return self.doc.text

    @property
    def dirty(self) -> bool:
        return self.saved_text != self.doc.text

    def save(self, path: Optional[Path] = None) -> Path:
        target = Path(path) if path is not None else self.path
        if target is None:
            raise ModelError("没有指定要保存到哪里")
        target.write_text(self.doc.text, encoding="utf-8", newline="\n")
        self.path = target
        self.saved_text = self.doc.text
        return target

    def reload(self) -> None:
        if self.path is None:
            raise ModelError("没有指定文件")
        fresh = ConfigModel.load(self.path)
        self.doc = fresh.doc
        self.saved_text = fresh.saved_text
        self.path = fresh.path

    # ------------------------------------------------------------------
    # 单位
    # ------------------------------------------------------------------

    def class_choices(self) -> List[Tuple[str, str]]:
        """归属下拉的选项：**读 config 的 `unit.classes`**（不在这里再写一份中文）。

        表缺了 / 写坏了就退回 `CLASS_CHOICES`（模块顶上那份），
        免得一个坏配置让界面连「步兵 / 骑兵」都显示不出来。
        """
        out: List[Tuple[str, str]] = []
        data = self.doc.value(["unit", "classes"], {})
        if isinstance(data, dict):
            for cid, entry in data.items():
                if cid.startswith("_") or not isinstance(entry, dict):
                    continue
                out.append((cid, _s(entry.get("name"), cid)))
        return out or list(CLASS_CHOICES)

    def unit_ids(self) -> List[str]:
        return [k for k in self.doc.keys(["unit", "types"]) if not k.startswith("_")]

    def _recruit_rows(self) -> List[Dict[str, Any]]:
        rows = self.doc.value(["recruit", "list"], [])
        return rows if isinstance(rows, list) else []

    def _recruit_index(self, kind: str) -> int:
        for i, row in enumerate(self._recruit_rows()):
            if isinstance(row, dict) and _s(row.get("kind")) == kind:
                return i
        return -1

    def unit(self, uid: str) -> Unit:
        data = self.doc.value(["unit", "types", uid], None)
        if not isinstance(data, dict):
            raise ModelError("没有这个单位类型：%s" % uid)
        idx = self._recruit_index(uid)
        recruit = self._recruit_rows()[idx] if idx >= 0 else None
        return Unit(uid, data, recruit, idx, self.fog_vision_default())

    def fog_vision_default(self) -> float:
        """config 的 `fog.vision_default`（没写 `vision` 的**兵种**实际生效的视野半径）。

        ★ 编辑器**读**它只是为了把「没写」显示成「实际会用多少」；
          改它不在这里（那是 config 的 fog 段，属于游戏侧参数，本轮不给编辑器做页面）。
        """
        return _f(self.doc.value(["fog", "vision_default"], 0.0), 0.0)

    def fog_vision_building_default(self) -> float:
        """config 的 `fog.vision_building`（没写 `vision` 的**建筑**实际生效的视野半径）。

        ★ 与 `fog_vision_default` 是同一条口径的两半：单位一份、建筑一份。
        """
        return _f(self.doc.value(["fog", "vision_building"], 0.0), 0.0)

    def units(self) -> List[Unit]:
        return [self.unit(uid) for uid in self.unit_ids()]

    def set_unit(self, uid: str, field: str, value: Any) -> None:
        """写单位的一个字段。`field` 见 UNIT_FIELDS / RECRUIT_FIELDS。"""
        unit_path: JsonPath = ["unit", "types", uid]
        if not self.doc.has(unit_path):
            raise ModelError("没有这个单位类型：%s" % uid)
        if field == "unit_class":
            if value not in [cid for cid, _label in self.class_choices()]:
                raise ModelError("归属只能是表里那几种大类（unit.classes）：%r" % (value,))
            self.doc.set(unit_path + ["class"], value)
            return
        if field == "icon":
            # ★ 地图上只画**一个字**：多一个字会挤成一团，所以在写进去之前就拦住
            #   （空 = 删掉这个键，游戏侧退成「名字的第一个字」）。
            if value:
                if len(value) != 1:
                    raise ModelError("「地图上的字」只能填**正好一个字符**"
                                     "（现在填了 %d 个：%r）" % (len(value), value))
                self.doc.set(unit_path + ["icon"], value)
            elif self.doc.has(unit_path + ["icon"]):
                self.doc.remove(unit_path + ["icon"])
            return
        if field in ("name", "ranged", "hp_max", "damage", "range", "cooldown_sec",
                     "speed", "radius_factor", "vision"):
            # ★ `vision = None` = **删掉这个键** → 回到 config 的 fog.vision_default
            #   （与将领数值覆盖那套「不写就跟随」同一条语义）。
            if field == "vision" and value is None:
                if self.doc.has(unit_path + ["vision"]):
                    self.doc.remove(unit_path + ["vision"])
                return
            self.doc.set(unit_path + [field], value)
            # ★ 名称与招募卡的名字**同步**：设计师改一次名字，不该还要记得改第二处
            #   （两处不一致时，界面上会同时出现两个名字，看着像 bug）。
            if field == "name" and self.doc.has(["recruit", "list"]):
                idx = self._recruit_index(uid)
                if idx >= 0:
                    self.doc.set(["recruit", "list", idx, "label"], value)
            return
        if field in ("cost_food", "cost_gold", "population_cost", "train_sec",
                     "label", "short", "desc"):
            idx = self._recruit_index(uid)
            if idx < 0:
                raise ModelError("「%s」不在招募表（recruit.list）里：先在下面的"
                                 "「加入招募表」按一下，才能改造价 / 招募时间" % uid)
            if field == "cost_food":
                self.doc.set(["recruit", "list", idx, "cost", "food"], value)
            elif field == "cost_gold":
                self.doc.set(["recruit", "list", idx, "cost", "gold"], value)
            else:
                self.doc.set(["recruit", "list", idx, field], value)
            return
        raise ModelError("不认识的单位字段：%s" % field)

    def add_recruit_entry(self, uid: str) -> None:
        """把一个**不在招募表里**的单位加进招募表（照默认值，之后可改）。"""
        if self._recruit_index(uid) >= 0:
            return
        unit = self.unit(uid)
        self.doc.append(["recruit", "list"], {
            "kind": uid,
            "label": unit.name,
            "short": unit.name[:1],
            "desc": "招募 1 名%s" % unit.name,
            "train_sec": 10,
            "population_cost": 1,
            "cost": {"food": 50, "gold": 50},
        })

    def add_unit(self, new_id: str, name: str, template_id: str) -> None:
        """加一个兵种：**照模板复制一份**（连样式一起抄），再改 id 与名字。

        ★ 为什么是「复制模板」而不是「写一份默认值」：
          兵种之间大部分数值是相同的，设计师的动线是「拿一个像的改几处」；
          而且复制原文能让新条目与邻居**排版完全一致**（见 configfile 的文件头）。
        """
        self._check_new_id(new_id, "单位")
        if not self.doc.has(["unit", "types", template_id]):
            raise ModelError("模板兵种不存在：%s" % template_id)
        # 1) 复制 unit.types.<模板> 的原文
        self.doc.insert_raw(["unit", "types"], new_id,
                            self.doc.text_of(["unit", "types", template_id]))
        self.doc.set(["unit", "types", new_id, "name"], name)
        # ⚠️ 把模板抄过来的 `icon` 删掉：留着的话新兵种会顶着模板那个字
        #   （「马弓手」抄骑手 → 地图上显示「骑」，容易看成一匹马）。
        #   删掉 = **跟着名字的第一个字**（马弓手 → 马），设计师想换再自己填。
        if self.doc.has(["unit", "types", new_id, "icon"]):
            self.doc.remove(["unit", "types", new_id, "icon"])
        # 2) 招募表那一项：模板有就抄，没有就照默认值新建
        src = self._recruit_index(template_id)
        if src >= 0:
            self.doc.append_raw(["recruit", "list"],
                                self.doc.text_of(["recruit", "list", src]))
            idx = len(self._recruit_rows()) - 1
            self.doc.set(["recruit", "list", idx, "kind"], new_id)
            self.doc.set(["recruit", "list", idx, "label"], name)
            self.doc.set(["recruit", "list", idx, "short"], name[:1])
            self.doc.set(["recruit", "list", idx, "desc"], "招募 1 名%s" % name)
        else:
            self.add_recruit_entry(new_id)

    def remove_unit(self, uid: str) -> None:
        """删一个兵种（内置的不许删）。"""
        self._check_removable_unit(uid)
        self.doc.remove(["unit", "types", uid])
        idx = self._recruit_index(uid)
        if idx >= 0:
            self.doc.remove(["recruit", "list", idx])
        # 将领如果正用着它，改成第一个还存在的兵种（否则游戏会退回兜底数值）
        types = self.doc.value(["unit", "general", "types"], [])
        if isinstance(types, list):
            fallback = self.doc.value(["unit", "types"], {})
            first = next((k for k in fallback if not k.startswith("_")), "spearman")
            for i, tid in enumerate(types):
                if tid == uid:
                    self.doc.set(["unit", "general", "types", i], first)

    def _check_removable_unit(self, uid: str) -> None:
        if uid in BUILTIN_UNITS:
            raise ModelError("「%s」是内置兵种，不能删（代码与测试按 id 引用它：" % uid
                             + "、".join(BUILTIN_UNITS) + "）")
        if uid not in self.doc.value(["unit", "types"], {}):
            raise ModelError("没有这个单位类型：%s" % uid)

    def _check_new_id(self, new_id: str, what: str) -> None:
        if not new_id:
            raise ModelError("请填 %s id（英文小写 + 下划线）" % what)
        if not ID_RE.match(new_id):
            raise ModelError("%s id 只能用**小写字母开头** + 小写字母 / 数字 / 下划线：%r"
                             % (what, new_id))
        if new_id in GENERAL_KINDS or new_id.startswith("general_"):
            raise ModelError("id 不能以 general 开头：那是将领类单位的保留前缀")
        if self.doc.has(["unit", "types", new_id]):
            raise ModelError("已经有一个叫「%s」的单位了" % new_id)
        if self.doc.has(["building", new_id]):
            raise ModelError("已经有一个叫「%s」的建筑了（单位与建筑的 id 不要撞）" % new_id)

    # ------------------------------------------------------------------
    # 将领
    # ------------------------------------------------------------------

    def general_count(self) -> int:
        types = self.doc.value(["unit", "general", "types"], [])
        return len(types) if isinstance(types, list) else 0

    def _general_kind(self, index: int) -> str:
        """第 index 位将领在**招募卡**里的 kind（`general_1` / `general_2` / `general_3`）。

        ⚠️ 开局那三位在游戏里 kind 都是 `general`（见 world.create_generals），
           而区划招募出来的是 `general_1/2/3`；两边**共用同一个数值槽位**
           （config.gd 的 general_index_of 把 `general` 与 `general_N` 都映射到同一个序号，
           见 unit.general._stats_comment）。招募卡那三条才是设计师看得见的名字，
           所以这里按它取。
        """
        return "general_%d" % (index + 1)

    def general(self, index: int) -> General:
        types = self.doc.value(["unit", "general", "types"], [])
        if not isinstance(types, list) or index < 0 or index >= len(types):
            raise ModelError("没有第 %d 位将领" % (index + 1))
        type_id = _s(types[index])
        stats = self.doc.value(["unit", "general", "stats"], [])
        override = stats[index] if isinstance(stats, list) and index < len(stats) \
            and isinstance(stats[index], dict) else {}
        kind = self._general_kind(index)
        recruit = None
        rows = self.doc.value(["recruit", "zone", "list"], [])
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict) and _s(row.get("kind")) == kind:
                    recruit = row
                    break
        defaults: Dict[str, Any] = {}
        if self.doc.has(["unit", "types", type_id]):
            u = self.unit(type_id)
            defaults = {"hp_max": u.hp_max, "damage": u.damage, "range": u.range,
                        "cooldown_sec": u.cooldown_sec, "speed": u.speed,
                        # ★ 视野跟随所属兵种（含「兵种没写 → fog.vision_default」那一层，
                        #   见 Unit.vision_effective）—— 将领的覆盖就是在这个数上覆盖。
                        "vision": u.vision_effective}
        return General(index, kind, type_id, override, recruit, defaults)

    def generals(self) -> List[General]:
        return [self.general(i) for i in range(self.general_count())]

    def set_general_type(self, index: int, type_id: str) -> None:
        self._check_general_index(index)
        if not self.doc.has(["unit", "types", type_id]):
            raise ModelError("没有这个单位类型：%s" % type_id)
        self.doc.set(["unit", "general", "types", index], type_id)

    def _check_general_index(self, index: int) -> None:
        """将领的**个数**由 unit.general.types 定（开局三位），编辑器不增删将领。

        ⚠️ 所以越界的序号必须当场拒掉：`_ensure_general_slot` 会「顺手补一条」，
           不拦的话 `set_general(9, ...)` 会真的写出第 10 条覆盖记录，
           而游戏只读 types 那么多个 —— 数据里躺着一份谁也读不到的东西。
        """
        if not 0 <= index < self.general_count():
            raise ModelError("没有第 %d 位将领（现在有 %d 位）" % (index + 1, self.general_count()))

    def set_general(self, index: int, field: str, value: Any) -> None:
        """改将领的 名称 / 造价 / 招募时间（名称同时写进覆盖与招募卡）。"""
        self._check_general_index(index)
        kind = self._general_kind(index)
        self._ensure_general_slot(index)
        rows = self.doc.value(["recruit", "zone", "list"], [])
        ridx = -1
        if isinstance(rows, list):
            for i, row in enumerate(rows):
                if isinstance(row, dict) and _s(row.get("kind")) == kind:
                    ridx = i
                    break
        if field == "name":
            self.doc.set(["unit", "general", "stats", index, "name"], value)
            if ridx >= 0:
                self.doc.set(["recruit", "zone", "list", ridx, "label"], value)
            return
        if field in ("cost_food", "cost_gold", "population_cost", "train_sec"):
            if ridx < 0:
                raise ModelError("将领 %d 不在 recruit.zone.list 里，改不了造价 / 招募时间"
                                 % (index + 1))
            if field == "cost_food":
                self.doc.set(["recruit", "zone", "list", ridx, "cost", "food"], value)
            elif field == "cost_gold":
                self.doc.set(["recruit", "zone", "list", ridx, "cost", "gold"], value)
            else:
                self.doc.set(["recruit", "zone", "list", ridx, field], value)
            return
        raise ModelError("不认识的将领字段：%s" % field)

    def set_general_stat(self, index: int, stat: str, value: Optional[float]) -> None:
        """写 / 删将领的一项数值覆盖（None = 删掉，回到「跟随所属兵种」）。"""
        keys = [f.key for f in GENERAL_STAT_FIELDS]
        if stat not in keys:
            raise ModelError("不认识的将领数值：%s" % stat)
        self._check_general_index(index)
        self._ensure_general_slot(index)
        path: JsonPath = ["unit", "general", "stats", index, stat]
        if value is None:
            if self.doc.has(path):
                self.doc.remove(path)
            return
        self.doc.set(path, value)

    def _ensure_general_slot(self, index: int) -> None:
        """保证 `unit.general.stats[index]` 存在（老配置里可能整段都没有）。

        ⚠️ 这里**只补到将领个数**，不做「越界就顺手加一条」（越界在
           `_check_general_index` 已经被拒了）。
        """
        if not self.doc.has(["unit", "general", "stats"]):
            self.doc.set(["unit", "general", "stats"],
                         [{} for _ in range(self.general_count())])
        while self.doc.size(["unit", "general", "stats"]) <= index:
            self.doc.append(["unit", "general", "stats"], {})

    # ------------------------------------------------------------------
    # 建筑
    # ------------------------------------------------------------------

    def building_ids(self) -> List[str]:
        return [k for k in self.doc.keys(["building"]) if not k.startswith("_")]

    def building(self, bid: str) -> Building:
        data = self.doc.value(["building", bid], None)
        if not isinstance(data, dict):
            raise ModelError("没有这个建筑：%s" % bid)
        rows = self.doc.value(["upgrade", "levels", bid], [])
        return Building(bid, data, rows if isinstance(rows, list) else [],
                        self.fog_vision_building_default())

    def buildings(self) -> List[Building]:
        return [self.building(bid) for bid in self.building_ids()]

    def set_building(self, bid: str, field: str, value: Any) -> None:
        path: JsonPath = ["building", bid]
        if not self.doc.has(path):
            raise ModelError("没有这个建筑：%s" % bid)
        if field == "cost_food":
            self.doc.set(path + ["cost", "food"], value)
        elif field == "cost_gold":
            self.doc.set(path + ["cost", "gold"], value)
        elif field == "vision" and value is None:
            # ★ `vision = None` = **删掉这个键** → 回到 config 的 fog.vision_building
            #   （与兵种那边的 `set_unit("vision", None)` 同一条语义）。
            if self.doc.has(path + ["vision"]):
                self.doc.remove(path + ["vision"])
        elif field in ("name", "buildable", "hotkey", "build_sec", "hp_max", "body_scale",
                       "vision", "attackable", "damage", "range", "cooldown", "color", "desc"):
            self.doc.set(path + [field], value)
        else:
            raise ModelError("不认识的建筑字段：%s" % field)

    def set_level(self, bid: str, index: int, field: str, value: Optional[float]) -> None:
        """改升级表的某一级。`value = None` 只对攻击三属性有意义（= 删掉 → 沿用基础值）。"""
        base: JsonPath = ["upgrade", "levels", bid]
        if not self.doc.has(base):
            raise ModelError("「%s」还没有升级表（upgrade.levels 里没有它）" % bid)
        if not 0 <= index < self.doc.size(base):
            raise ModelError("「%s」没有第 %d 级" % (bid, index + 1))
        row: JsonPath = base + [index]
        if field == "cost_food":
            self.doc.set(row + ["cost", "food"], value)
        elif field == "cost_gold":
            self.doc.set(row + ["cost", "gold"], value)
        elif field in ("time_sec", "hp_mult"):
            self.doc.set(row + [field], value)
        elif field in ("damage", "range", "cooldown"):
            if value is None:
                if self.doc.has(row + [field]):
                    self.doc.remove(row + [field])
                return
            self.doc.set(row + [field], value)
        else:
            raise ModelError("不认识的升级字段：%s" % field)

    def add_building(self, new_id: str, name: str, template_id: str) -> None:
        """加一个建筑：复制模板的定义 **与它的整张升级表**。"""
        self._check_new_id(new_id, "建筑")
        if not self.doc.has(["building", template_id]):
            raise ModelError("模板建筑不存在：%s" % template_id)
        self.doc.insert_raw(["building"], new_id,
                            self.doc.text_of(["building", template_id]))
        self.doc.set(["building", new_id, "id"], new_id)
        self.doc.set(["building", new_id, "name"], name)
        # ★ 新建筑一律**可建造**：否则它在游戏里根本出不来（建造页不列它），
        #   设计师会以为编辑器坏了。想让它当「开局自带」的东西，把勾去掉即可。
        self.doc.set(["building", new_id, "buildable"], True)
        self.doc.set(["building", new_id, "hotkey"], "")
        if self.doc.has(["upgrade", "levels", template_id]):
            self.doc.insert_raw(["upgrade", "levels"], new_id,
                                self.doc.text_of(["upgrade", "levels", template_id]))
        else:
            self.doc.set(["upgrade", "levels", new_id], self.default_levels())

    @staticmethod
    def default_levels() -> List[Dict[str, Any]]:
        """一份 3 级升级表（照 base / wall / tower 现在的口径）。"""
        return [
            {"level": 1, "hp_mult": 1.0},
            {"level": 2, "hp_mult": 1.5, "cost": {"food": 50, "gold": 50}, "time_sec": 10},
            {"level": 3, "hp_mult": 2.25, "cost": {"food": 100, "gold": 100}, "time_sec": 15},
        ]

    def remove_building(self, bid: str) -> None:
        if bid in BUILTIN_BUILDINGS:
            raise ModelError("「%s」是内置建筑，不能删（代码与测试按 id 引用它：%s）"
                             % (bid, "、".join(BUILTIN_BUILDINGS)))
        if not self.doc.has(["building", bid]):
            raise ModelError("没有这个建筑：%s" % bid)
        self.doc.remove(["building", bid])
        if self.doc.has(["upgrade", "levels", bid]):
            self.doc.remove(["upgrade", "levels", bid])

    # ------------------------------------------------------------------
    # 科技
    # ------------------------------------------------------------------

    def techs(self) -> List[Tech]:
        rows = self.doc.value(["tech", "list"], [])
        out: List[Tech] = []
        if isinstance(rows, list):
            for i, row in enumerate(rows):
                if isinstance(row, dict):
                    out.append(Tech(i, row))
        return out

    def tech(self, index: int) -> Tech:
        techs = self.techs()
        if not 0 <= index < len(techs):
            raise ModelError("没有第 %d 条科技" % (index + 1))
        return techs[index]

    def set_tech(self, index: int, field: str, value: Any) -> None:
        if field not in ("name", "line", "desc"):
            raise ModelError("不认识的科技字段：%s" % field)
        self.tech(index)                                    # 越界检查
        self.doc.set(["tech", "list", index, field], value)

    def set_tech_effect(self, index: int, key: str, value: Optional[float]) -> None:
        """写 / 删一条加成（数值 = None 表示这条加成不要了）。"""
        if key not in [k for k, _l, _h in TECH_EFFECTS]:
            raise ModelError("不认识的科技加成：%s" % key)
        self.tech(index)
        path: JsonPath = ["tech", "list", index, "effect", key]
        if value is None:
            if self.doc.has(path):
                self.doc.remove(path)
            return
        self.doc.set(path, value)

    def max_active(self) -> int:
        return int(_f(self.doc.value(["tech", "max_active"], 3), 3.0))

    def set_max_active(self, value: int) -> None:
        self.doc.set(["tech", "max_active"], int(value))
