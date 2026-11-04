"""model.py —— 单位 / 将领 / 建筑的**数据层**（无界面，可无头测试）。

职责边界（与地图编辑器那一套对齐）：

    configfile.py  「一份带注释的 JSON 文本怎么原地改几个字符」——只管文本
    model.py       「游戏里的单位 / 建筑是什么」——只管语义与校验
    app.py         tkinter 界面

★ 数据只有一个来源：`daeem/data/config.json`（`logic/config.gd` 读的就是它）。
  本模块**不复制**任何数值：每一个字段都直说它落在 JSON 的哪条路径上。
  游戏侧读的键见 docs/route.md 那一节，两边对不上的话 test_model.py 会红。

★ 字段表（`UNIT_FIELDS` / `BUILDING_FIELDS` / …）是**给界面看的**：
  界面照它生成表单，所以「加一个可编辑字段」= 在表里加一行 + 在 set_* 里认一下，
  不用动 app.py。
"""

from __future__ import annotations

import json
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

#: ★★ 2026.11：**科技不再由本工具编辑**（用户口径：「把单位编辑器中的科技编辑界面去掉」）——
#:   科技的两张表（`tech.list` / `tech.clan_list`）、每派 9 个槽位（`clan.list[].tech`）、
#:   以及 `tech.max_active` / 每阶金耗，全部搬到了 `tools/buff_editor`。
#:   ⚠️ 别在这里重新加回来：一个键只有一处能改，才不会出现两边改法不一致。

#: 内置单位 / 建筑：**不许删**（代码与测试按 id 引用它们）。删掉它们不会报错，
#: 而是让游戏在某条路上静默走兜底值 —— 那正是 docs/pitfalls.md 反复说的坑。
#: ★★ 本次：「测试敌人」（enemy）从内置名单里**移除**（用户口径：「将『敌』从
#:    editor 工具中移除」）—— 它已经从 data/config.json 的 unit.types 里删掉了，
#:    调试刷兵改刷长枪兵，所以编辑器不该再列出这一条。
#:    ⚠️ 它同时也是一个「可以被删除」的自定义单位 id 了；若某个旧地图/关卡里还写着
#:       kind = "enemy"，游戏会退到 unit.<default> 的兜底值（不崩）。
BUILTIN_UNITS: Tuple[str, ...] = ("spearman", "longbowman", "rider")
BUILTIN_BUILDINGS: Tuple[str, ...] = ("wall", "tower", "stone_wall", "watch_tower", "base")

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
    Field("armor", "护甲", "float",
          "每次受击先减这么多点伤害（最低仍造成 1 点）；骑士 6、其余 1~2", minimum=0),
    Field("damage", "攻击力", "float", "每次攻击造成的伤害", minimum=0),
    Field("range", "攻击距离", "float", "单位：**格**（1 = 贴脸）", minimum=0),
    Field("cooldown_sec", "攻击速度", "float",
          "两次攻击之间的**间隔秒数**：数字越小打得越快", minimum=0.01),
    Field("speed", "移动速度", "float", "格 / 秒（森林里会乘 unit.forest_mult）", minimum=0),
    Field("radius_factor", "身体半径", "float", "格；渲染与射程判定共用", minimum=0.01, maximum=0.5),
    Field("icon", "地图上的字", "text", ICON_HINT),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
)

#: ★★ 持久消耗（`unit.types.<id>.upkeep_food`，粮/秒）—— 2026.11.4 加进编辑器。
#: 口径：**每个存活单位每秒吃多少粮**，由 `world._tick_upkeep()` 按存活单位累加；
#:   清空输入框 = 删掉这个键 = 跟随大类（`unit.classes.<class>.upkeep_food`）。
UNIT_UPKEEP_FIELD = Field(
    "upkeep_food", "每秒耗粮", "float",
    "每个存活单位每秒吃多少粮（0 = 不耗粮）；清空 = 跟随大类默认",
    minimum=0.0, maximum=10.0)

#: 大类的默认持久消耗（`unit.classes.<class>.upkeep_food`）——
#: 同大类里**没单独写** `upkeep_food` 的兵种都跟它（游戏侧载入时合并进每个兵种）。
CLASS_UPKEEP_FIELD = Field(
    "class_upkeep", "大类默认", "float",
    "同大类里没单独写的兵种都跟这个；清空 = 不加这个键（按 0 算）",
    minimum=0.0, maximum=10.0)

#: 将领自己的持久消耗覆盖（`unit.general.upkeep_override[<index>]`，2026.11.4）。
#: 清空 = 删掉这条覆盖 = 跟随所属兵种（与 hp / armor 那套「不写就跟随」同语义）。
GENERAL_UPKEEP_FIELD = Field(
    "upkeep_food", "每秒耗粮", "float",
    "这位将领每秒吃多少粮；清空 = 跟随所属兵种",
    minimum=0.0, maximum=10.0)

#: ★★ 冲锋（`unit.types.<id>.charge`）—— 全部可留空；不写 / min_distance = 0 = 不冲锋。
#: 口径与 logic/config.gd 的 `_normalize_charge()` 一致（这里只是编辑入口，不做玩法夹取）。
CHARGE_FIELDS: Tuple[Field, ...] = (
    Field("min_distance", "冲锋距离", "float",
          "连续直线移动多少格后进入冲锋态；0 / 留空 = 不冲锋", minimum=0, maximum=40),
    Field("max_distance", "冲锋累积上限", "float",
          "冲锋距离最多累计到这里（格）；留空按 min_distance 处理", minimum=0, maximum=40),
    Field("turn_max_deg", "最大转向角", "float",
          "与冲锋起始方向的夹角超过它就中断重算（度）", minimum=0, maximum=180),
    Field("speed_bonus", "冲锋移速加成", "float",
          "冲锋态下移速 +x（0.2 = +20%）", minimum=0, maximum=2),
    Field("damage_bonus", "冲锋伤害加成", "float",
          "冲锋首次命中的额外伤害（0.5 = +50%）", minimum=0, maximum=5),
    Field("knock_distance", "冲锋击退距离", "float",
          "命中时把目标推开多少格（0 = 不击退）", minimum=0, maximum=2),
    Field("knock_stun_sec", "冲锋眩晕", "float",
          "命中时目标眩晕多少秒（0 = 不眩晕）", minimum=0, maximum=3),
    Field("splash_radius", "范围撞击半径", "float",
          "冲锋命中的范围半径（格；0 = 单体）", minimum=0, maximum=3),
    Field("splash_damage_ratio", "副目标伤害比例", "float",
          "范围内其他敌人吃主伤害的几成（0.6 = 60%）", minimum=0, maximum=1),
    Field("cooldown_sec", "冲锋冷却", "float",
          "一次冲锋命中后多久不能再次累积（秒）", minimum=0, maximum=120),
)

#: ★★ 兵种特性（`unit.types.<id>.traits`，2026.11.3 加进编辑器）——
#: 与 `logic/config.gd` 的 `_normalize_traits()` **一一对应**：游戏那边只认这四个键，
#: 写别的会被静默丢掉。所以这里也只给这四样编辑入口：
#:   · `attack_vs_class` = 对某一大类的伤害加成（一行一个大类，可加可删，见
#:     `UNIT_TRAIT_ATTACK_KEY`）；
#:   · 下面两条标量减伤 + 「稳定」（免疫击退）。
#: ⚠️ 减伤写的是**比例**（0.25 = 25%），与建筑那条「远程免伤」同一个口径；
#:   清空输入框 = **删掉这个键**（游戏侧读回 0），不会在文件里留一个 0。
UNIT_TRAIT_FIELDS: Tuple[Field, ...] = (
    Field("ranged_reduction", "远程减伤", "float",
          "0.25 = 25%（挡箭 / 投掷物）；清空 = 不减免", minimum=0.0, maximum=1.0),
    Field("melee_reduction", "近战减伤", "float",
          "0.25 = 25%；清空 = 不减免", minimum=0.0, maximum=1.0),
)

#: 兵种特性里「对某大类伤害 +x%」那一张表的键（值是 `{大类 id: 比例}`）。
#: ★ 值只能打**单位**；打建筑不受影响（建筑没有兵种大类）。
UNIT_TRAIT_ATTACK_KEY = "attack_vs_class"

#: 新增一行「对某大类伤害」时的缺省比例（0.25 = +25%，与需求里的例子一致）。
UNIT_TRAIT_ATTACK_DEFAULT = 0.25

#: 兵种特性的「稳定」：免疫击退（位移 + 眩晕）整套效果。
UNIT_TRAIT_KNOCKBACK = Field("knockback_immune", "免疫击退（稳定）", "bool",
                             "勾上 = 免疫击退（推开 + 眩晕）；碰撞挤开照旧")

#: 招募（`recruit.list[]` / `clan.list[].recruit[]`，按 kind 找那一项）—— 造价与文案
#: ★★ 2026.11.2：**读条时间不在这里**（单位条目里的 train_sec 已经从 config 里删掉）——
#:   读条由「招它的那位将领」决定（`unit.general.recruit_sec`，默认 10），见 GENERAL_RECRUIT_FIELD。
RECRUIT_FIELDS: Tuple[Field, ...] = (
    Field("cost_food", "造价 · 粮食", "float", minimum=0),
    Field("cost_gold", "造价 · 黄金", "float", minimum=0),
    Field("population_cost", "造价 · 人口", "float",
          "扣的是**将领所在区划**的人口（不是全局人口）", minimum=0),
    Field("label", "命令卡名字", "text", "右下「单位」页那一格的标题（默认跟名称同步）"),
    Field("short", "命令卡方框字", "text", "格子里那个方框写的字（一般一个字）"),
    Field("desc", "命令卡说明", "text", "悬停详情里的一句话"),
)

#: ★★ 组合招募单（2026.11.2 新增）：`kind` **不是**一个兵种 id、靠 `spawn` 一次生成
#: 好几个单位的招募条目（「协防军」= 枪 + 弓，「御林军」= 剑盾 + 弓 + 着甲骑）。
#: 它们没有 `unit.types.<kind>`，所以**单位页里根本列不出来** —— 造价必须在这里改，
#: 否则「协防军 / 御林军 一次要多少粮」在编辑器里无处可改。
PACKAGE_FIELDS: Tuple[Field, ...] = (
    Field("label", "名字", "text", "右下「单位」页那一格的标题"),
    Field("short", "命令卡方框字", "text", "格子里那个方框写的字（一般一个字）"),
    Field("desc", "命令卡说明", "text", "悬停详情里的一句话"),
    Field("cost_food", "造价 · 粮食", "float", "这一单「整包」的粮食价", minimum=0),
    Field("cost_gold", "造价 · 黄金", "float", "这一单「整包」的黄金价", minimum=0),
    Field("population_cost", "造价 · 人口", "float",
          "这一单「整包」扣多少人口（扣的是将领所在区划的人口）", minimum=0),
)

#: ★★ 编制上限的默认值（`config.json` 的 `unit.general.caps` 缺省 / 越界都用它）。
#: 与 view/ui_layout.gd 的 UNIT_CAP 同值（11）—— 但两者**暂时各自独立**（界面那
#: 一处本版没接过来，见 config.json 的 `_caps_comment`）。
GENERAL_CAP_DEFAULT = 11

#: ★★ 编制上限（`unit.general.caps[index]`）：这位将领的**目标编队规模**。
#: 摆放 / 红点 / 阵地补员都以它封顶（见 logic/config.gd 的 general_cap_at）。
GENERAL_CAP_FIELD = Field("cap", "编制上限", "int",
                          "这位将领的目标编队规模：摆放时开局生成到它、阵地 AI 脱战补到它、"
                          "红点将领的附属兵也以它封顶（生成数量 ≤ 它）", minimum=1)

#: ★★ 招兵读条（`unit.general.recruit_sec[index]`）—— 2026.11.2 新增。
#: 语义：这位将领当兵营时，**一次批次读条**几秒；队列长短 / 队列里的兵种都不影响它
#: （见 logic/world.gd 的 leader_recruit_sec / _start_training）。
#: 缺项 / 越界 / ≤ 0 ⇒ 游戏退回 config 的 `recruit.batch_sec`（默认也是 10）。
GENERAL_RECRUIT_DEFAULT = 10.0
GENERAL_RECRUIT_FIELD = Field("recruit_sec", "招兵读条", "float",
                              "这位将领招兵时「整批」读条几秒（与队列长短 / 兵种无关；"
                              "默认 10，清空 = 回到默认）", minimum=0.01)

#: ★★ 2026.11.5：**将领的阶**（`unit.general.tiers[index]`，0~3）。
#:   · 阶 = 备战页分组的行 + 「大本营升到几级才招得到」（0 阶不参与区划招募）；
#:   · 0 阶将领吃 `unit.general.growth` 那一份**大本营成长**（见 GENERAL_GROWTH_FIELDS）；
#:   · 这个数以前写在 `recruit.zone.list[].tier` 里，本轮搬到 unit.general.tiers
#:     （一个数只有一处；新加的将领不在招募表里，也就只有这里能记阶）。
GENERAL_START_INDEX = 9                 # 名册第 10 档 = 开局将领 #0（kind = general_0）
GENERAL_TIER_DEFAULT = 1
GENERAL_TIER_CHOICES: Tuple[Tuple[str, str], ...] = (
    ("0", "零阶"), ("1", "一阶"), ("2", "二阶"), ("3", "三阶"),
)
GENERAL_TIER_FIELD = Field(
    "tier", "阶", "choice",
    "备战页的分组 + 招将门槛；**0 阶**会吃下面「成长（0 阶）」那一份大本营加成",
    choices=GENERAL_TIER_CHOICES)

#: ★★ 2026.11.5：**将领的派系归属**（`unit.general.factions[index]`）——
#: 一位将领可以同时属于多个派系。选项来自 config 的 `clan.list`（现在原生 / 王朝 / 帝国）。
#: ★ 只勾「原生」的将领**不会**出现在备战页：右面板只有王朝 / 帝国两枚按钮。
GENERAL_FACTION_FIELD = Field(
    "factions", "派系归属", "text",
    "可以多选：备战页按选中的派系过滤将领；「原生」没有按钮 ⇒ 只勾原生的将领不上备战页")

#: 配置里**没有** `clan.list` 时的派系兜底（与 data/config.json 的三派同名）。
#: ★ 只在「这份配置根本没有派系表」时用 —— 正常配置一律读 `clan.list`。
GENERAL_FACTION_DEFAULT_IDS: Tuple[str, ...] = ("native", "dynasty", "empire")

#: ★★ 2026.11.5：**0 阶将领的大本营成长**（`unit.general.growth`）。
#: 数值是「每级加多少」，加成 = 每级值 × 当前大本营等级（1 级就给）。
#: ★ 这是**全局一份**（所有 0 阶将领共享），不是逐位将领的字段 ——
#:   所以它在任何一位 0 阶将领的表单里都能改，改的是同一个键。
GENERAL_GROWTH_FIELDS: Tuple[Field, ...] = (
    Field("hp_max_per_level", "血量 / 级", "float",
          "大本营每升 1 级给 0 阶将领加多少**血量上限**（占位：30）", minimum=0),
    Field("damage_per_level", "攻击力 / 级", "float",
          "大本营每升 1 级给 0 阶将领加多少**攻击力**（占位：3）", minimum=0),
)

#: 将领的数值覆盖（`unit.general.stats[i]`；没写的键 = 跟随所属兵种）
GENERAL_STAT_FIELDS: Tuple[Field, ...] = (
    Field("hp_max", "血量", "float", minimum=1),
    Field("armor", "护甲", "float",
          "每次受击先减这么多点伤害（再加将领全局护甲加成）；不写就跟随所属兵种",
          minimum=0),
    Field("damage", "攻击力", "float", minimum=0),
    Field("range", "攻击距离", "float", minimum=0),
    Field("cooldown_sec", "攻击速度", "float", minimum=0.01),
    Field("speed", "移动速度", "float", minimum=0),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
)

#: ★★ 将领特性（`unit.general_traits.<id>`，2026.11.3 加进编辑器）的**效果**。
#: 与 `logic/config.gd` 的 `_normalize_general_trait()` 一一对应：那边只认这五个效果键，
#: 写别的会被静默丢掉。`attack_vs_class` 是「对某大类伤害 +x%」（与兵种特性同形状）。
GENERAL_TRAIT_FIELDS: Tuple[Field, ...] = (
    Field("speed_bonus", "移速加成", "float",
          "移动速度 +比例（0.25 = +25%）；清空 = 没有这一条", minimum=0.0, maximum=10.0),
    Field("attack_speed_bonus", "攻速加成", "float",
          "攻击速度 +比例（0.25 = 攻击间隔 ÷1.25）；清空 = 没有这一条",
          minimum=0.0, maximum=10.0),
    Field("melee_reduction", "近战减伤", "float",
          "受到近战伤害时少受的比例（0.25 = 25%）；清空 = 没有这一条",
          minimum=0.0, maximum=1.0),
    Field("ranged_reduction", "远程减伤", "float",
          "受到远程伤害时少受的比例（0.25 = 25%）；清空 = 没有这一条",
          minimum=0.0, maximum=1.0),
    # ★★ 2026.11：新将领的三条「只给合作模式将领用」的效果。
    Field("capture_speed_bonus", "占领速度加成", "float",
          "占领速度 +比例（0.4 = 读条快 40%）；只在这个光环的单位站在区划中心邻域时生效",
          minimum=0.0, maximum=10.0),
    Field("recruit_cavalry_discount", "招募骑兵折扣", "float",
          "用这位将领当兵营招募**骑兵**单位时的资源折扣（0.25 = -25%；夹 0~1）",
          minimum=0.0, maximum=1.0),
    Field("charge_damage_bonus", "近战骑兵冲锋加成", "float",
          "部队里的**近战骑兵**冲锋额外伤害 +比例（1.0 = +100%）",
          minimum=0.0, maximum=10.0),
)

#: 将领特性里的**开关**（写 `true` / 不写）。
GENERAL_TRAIT_KNOCKBACK = Field(
    "knockback_immune", "稳定（免疫击退）", "bool",
    "光环里的单位免疫击退 + 眩晕（子刹用这一条）")

#: 将领特性里「对某大类伤害 +x%」那一张表的键 / 新加一行时的缺省比例。
GENERAL_TRAIT_ATTACK_KEY = "attack_vs_class"
GENERAL_TRAIT_ATTACK_DEFAULT = 0.25

#: 将领特性的**文案**三件套（列表 / 悬停 / 卡牌都读它们）。
GENERAL_TRAIT_TEXT_FIELDS: Tuple[Field, ...] = (
    Field("name", "名字", "text", "特性名（悬停标题 / 卡牌上用）"),
    Field("short", "短名", "text", "信息栏格子里那一个字；留空 = 名字的第一个字"),
    Field("desc", "说明", "text", "悬停正文里的那一句"),
)

#: 建筑（`building.<type>`）
BUILDING_FIELDS: Tuple[Field, ...] = (
    Field("name", "名称", "text", "地图上 / 建造页里的名字"),
    Field("buildable", "可建造", "bool", "会不会出现在右下「建筑」页的命令卡里"),
    Field("tier", "解锁大本营等级", "int",
          "建筑页的行号 / 解锁所需的大本营等级：1 = 第 1 行，2 = 第 2 行（2 级大本营）",
          minimum=1, maximum=3),
    Field("slot", "排内位置", "int",
          "建筑页同一行内的列：1 = 最左，3 = 最右；空 = 按 config 顺序自动排",
          minimum=1, maximum=3),
    Field("build_sec", "建造时间", "float",
          "秒。**0 = 瞬发**（默认，与从前一致）；> 0 就要读条，读条期间不能攻击", minimum=0),
    Field("cost_food", "造价 · 粮食", "float",
          "economy.enabled = false 时建造免费（那个开关只管建造）", minimum=0),
    Field("cost_gold", "造价 · 黄金", "float", minimum=0),
    Field("hp_max", "血量", "float", "基础血量上限；大本营等级与科技都在它上面乘倍率", minimum=1),
    Field("body_scale", "本体大小", "float",
          "本体边长占一格的比例（渲染与碰撞共用）：1.0 = 填满整格", minimum=0.05, maximum=1.0),
    Field("vision", "视野半径", "float", VISION_HINT, minimum=0),
    Field("ranged_reduction", "远程免伤", "float",
          "0~1：对投掷物伤害的免伤比例（0.9 = 90%）。攻城（投石车）不受影响",
          minimum=0.0, maximum=0.99),
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


def fmt_percent(ratio: Any) -> str:
    """比例 → 「25%」。

    ★ 只用于**给人看的摘要 / 提示**：写回文件的永远是比例（0.25），
      不是百分数 —— 否则「界面上填 25、文件里也是 25」会让 25 倍伤害。
    """
    try:
        value = float(ratio) * 100.0
    except (TypeError, ValueError):
        return ""
    if abs(value - round(value)) < 1e-9:
        return "%d%%" % int(round(value))
    return ("%.1f%%" % value).rstrip("0").rstrip(".")


# ======================================================================
# 只读快照（界面列表 / 表单都读它们，不直接摸 Doc）
# ======================================================================

class Unit:
    """一个单位类型 + 它在**任意一张招募表**里的那一项（没有就是 has_recruit = False）。

    ★★ 2026.11.2：招募条目不再只认全局 `recruit.list` —— 派系兵种（王朝 dy_* / 帝国 dg_*）
    的条目挂在 `clan.list[].recruit[]` 上。所以这里记的是**那一行的路径**（`recruit_path`）
    与它属于哪张表（`recruit_owner`），`set_unit` 照着路径写，界面照着 owner 显示来源。
    """

    def __init__(self, uid: str, data: Dict[str, Any],
                 recruit: Optional[Dict[str, Any]], recruit_index: int,
                 fog_default: float = 0.0,
                 recruit_path: Optional[JsonPath] = None,
                 recruit_owner: str = "",
                 spawn_source: Optional[Tuple[JsonPath, str, str]] = None,
                 class_upkeep: float = 0.0) -> None:
        self.id = uid
        #: 这一条在 JSON 里的**原文**（判「哪个键真的写了」要它，不能只看取到的数）
        self.raw: Dict[str, Any] = dict(data)
        #: config 的 `fog.vision_default`（没写 vision 的兵种实际生效的那个数）
        self.fog_default = fog_default
        self.name = _s(data.get("name"), uid)
        self.unit_class = _s(data.get("class"), "infantry")
        self.ranged = _b(data.get("ranged"), False)
        self.hp_max = _f(data.get("hp_max"), 0.0)
        #: ★ 固定护甲（每次受击先减这么多点，最低仍造成 1 点）。没写 = 0。
        self.armor = _f(data.get("armor"), 0.0)
        self.damage = _f(data.get("damage"), 0.0)
        self.range = _f(data.get("range"), 0.0)
        self.cooldown_sec = _f(data.get("cooldown_sec"), 0.0)
        self.speed = _f(data.get("speed"), 0.0)
        self.radius_factor = _f(data.get("radius_factor"), 0.0)
        self.icon = _s(data.get("icon"), "")
        #: ★ 视野半径（格）—— 战争迷雾。**读的是「写了的那个数」**：
        #: 没写 = 0，界面上得显示 `vision_effective`（免得看着像「这个兵是瞎子」）。
        self.vision = _f(data.get("vision"), 0.0)
        #: ★★ 冲锋参数（`unit.types.<id>.charge`；不写 = 空字典 = 不冲锋）。
        self.charge = data.get("charge") if isinstance(data.get("charge"), dict) else {}
        #: ★★ 兵种特性（`unit.types.<id>.traits`，2026.11.3）—— 与游戏侧
        #: `logic/config.gd` 的 `_normalize_traits()` 同形状：四个键，没写 = 空字典。
        self.traits = data.get("traits") if isinstance(data.get("traits"), dict) else {}
        #: 「对某大类伤害 +x%」那张表（`traits.attack_vs_class`）；没写 = 空字典。
        _av = self.traits.get(UNIT_TRAIT_ATTACK_KEY)
        self.attack_vs_class: Dict[str, float] = (
            {str(k): _f(v) for k, v in _av.items()} if isinstance(_av, dict) else {})
        self.has_recruit = recruit is not None
        self.recruit_index = recruit_index
        #: 招募条目那一行的 **JSON 路径**（`["recruit","list",i]` 或
        #: `["clan","list",ci,"recruit",ri]`）；没有条目就是 None。
        self.recruit_path: Optional[JsonPath] = list(recruit_path) if recruit_path else None
        #: 条目属于哪张表：`"recruit.list"` / `"clan:<派系 id>"`（界面用它说明来源）。
        self.recruit_owner = recruit_owner
        #: ★★ 这个兵种**没有自己的招募条目**、但会被某张「组合单」一起生成时记这里：
        #: `(那一单的路径, 表名, 那一单的显示名)`。例如 dy_spear_guard 由「协防军」生成。
        #: 有它 ⇒ 界面上不该说「不在招募表」（它确实招得出来，只是不单独占一格）。
        self.spawn_source = spawn_source
        self.spawn_label = spawn_source[2] if spawn_source else ""
        rec = recruit or {}
        cost = rec.get("cost") if isinstance(rec.get("cost"), dict) else {}
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.population_cost = _f(rec.get("population_cost"), 0.0)
        self.label = _s(rec.get("label"), self.name)
        self.short = _s(rec.get("short"), "")
        self.desc = _s(rec.get("desc"), "")
        #: ★★ 持久消耗（`unit.types.<id>.upkeep_food`，粮/秒）—— 2026.11.4 加进编辑器。
        #: **没写就是 None**（不是 0）：界面靠它区分「继承大类」与「明确写了 0（免费）」。
        self.upkeep_own: Optional[float] = (
            _f(data.get("upkeep_food"), 0.0) if "upkeep_food" in data else None)
        #: 所属大类的默认维护费（`unit.classes.<class>.upkeep_food`）。
        self.class_upkeep = _f(class_upkeep, 0.0)

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

    # ---- 持久消耗（`unit.types.<id>.upkeep_food`，2026.11.4）----------------

    @property
    def inherits_upkeep(self) -> bool:
        """维护费是不是「没写、跟随大类」的（界面要标出来）。"""
        return self.upkeep_own is None

    @property
    def upkeep_effective(self) -> float:
        """**实际生效**的每秒维护费。

        ★ 与游戏侧 `logic/config.gd` 的 `unit_upkeep_of()` 同一条规则：类型自己写了
          就用它，没写就用大类的默认值（载入时合并好的那一份）。
        """
        return self.class_upkeep if self.upkeep_own is None else self.upkeep_own

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def charge_field(self, key: str) -> float:
        """冲锋参数的一项（`unit.types.<id>.charge.<key>`）；没写 = 0。"""
        return _f(self.charge.get(key), 0.0)

    # ---- 兵种特性（`unit.types.<id>.traits`）-------------------------------

    def trait_number(self, key: str) -> Optional[float]:
        """一条标量特性（`ranged_reduction` / `melee_reduction`）的值。

        ★ **没写就返回 None**（不是 0）—— 界面靠它区分「文件里没有这个键」
          与「明确写了 0」：前者空框、后者显示 0。与 `vision` 同一条语义。
        """
        if key not in self.traits:
            return None
        value = self.traits[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)

    def trait_flag(self, key: str) -> bool:
        """一条开关型特性（目前只有 `knockback_immune`）；没写 / 写错类型 = False。"""
        return self.traits.get(key) is True

    def attack_rows(self, names: Dict[str, str]) -> List[Tuple[str, float, str]]:
        """「对某大类伤害 +x%」的每一行：`(大类 id, 比例, 大类显示名)`。

        ★ 顺序就是文件里的顺序（不排序）：设计师按自己写的顺序看更顺，
          也免得每改一次值列表就跳一下。
        """
        out: List[Tuple[str, float, str]] = []
        for cls, ratio in self.attack_vs_class.items():
            out.append((str(cls), float(ratio), names.get(str(cls), str(cls))))
        return out

    def trait_summary(self, names: Dict[str, str]) -> str:
        """一行摘要（例如「对骑兵 +25% / 远程减伤 25%」）；没有特性 = 空串。"""
        parts: List[str] = []
        for cls, ratio, cname in self.attack_rows(names):
            parts.append("对%s %+d%%" % (cname, int(round(ratio * 100.0))))
        for field in UNIT_TRAIT_FIELDS:
            value = self.trait_number(field.key)
            if value:
                parts.append("%s %s" % (field.label, fmt_percent(value)))
        if self.trait_flag(UNIT_TRAIT_KNOCKBACK.key):
            parts.append("免疫击退")
        return " / ".join(parts)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<Unit %s %s>" % (self.id, self.name)


class GeneralTrait:
    """一条**将领特性**（`unit.general_traits.<id>`）：部队光环的文案 + 效果。

    ★ 效果键与 `logic/config.gd` 的 `_normalize_general_trait()` **一一对应**：
      `speed_bonus` / `attack_speed_bonus` / `melee_reduction` / `ranged_reduction` /
      `attack_vs_class`。游戏那边只认这五个，写别的会被静默丢掉。
    ★ 这是**池**里的定义（全局一份）；「哪一位将领用它」在
      `unit.general.trait_ids[index]`（见 `ConfigModel.general_trait_at`）。
    """

    def __init__(self, tid: str, row: Dict[str, Any]) -> None:
        self.id = tid
        #: 原文（判「这个效果键到底写了没有」要它，不能只看取到的数）
        self.raw: Dict[str, Any] = dict(row)
        self.name = _s(row.get("name"), tid)
        self.short = _s(row.get("short"), "")
        self.desc = _s(row.get("desc"), "")
        self.speed_bonus = _f(row.get("speed_bonus"), 0.0)
        self.attack_speed_bonus = _f(row.get("attack_speed_bonus"), 0.0)
        self.melee_reduction = _f(row.get("melee_reduction"), 0.0)
        self.ranged_reduction = _f(row.get("ranged_reduction"), 0.0)
        # ★★ 2026.11：稳定 + 三条新效果（键不存在 = 没有）。
        self.knockback_immune = bool(row.get("knockback_immune", False))
        self.capture_speed_bonus = _f(row.get("capture_speed_bonus"), 0.0)
        self.recruit_cavalry_discount = _f(row.get("recruit_cavalry_discount"), 0.0)
        self.charge_damage_bonus = _f(row.get("charge_damage_bonus"), 0.0)
        #: ★★ 2026.11：横扫（攻击附带范围伤害 + 击退），形状 `{radius, knockback, stun_sec}`。
        self.melee_splash = dict(row.get("melee_splash")) \
            if isinstance(row.get("melee_splash"), dict) else {}
        _av = row.get(GENERAL_TRAIT_ATTACK_KEY)
        self.attack_vs_class: Dict[str, float] = (
            {str(k): _f(v) for k, v in _av.items()} if isinstance(_av, dict) else {})

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    @property
    def short_text(self) -> str:
        """信息栏格子里真正显示的那个字：短名 → 名字首字 → 空（与游戏侧同一条）。"""
        if self.short:
            return self.short[:1]
        return self.name[:1] if self.name else ""

    def effect_number(self, key: str) -> Optional[float]:
        """一条标量效果的值；**没写返回 None**（界面空框 = 文件里没有这个键）。"""
        if key not in self.raw:
            return None
        value = self.raw[key]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
        return float(value)

    def attack_rows(self, names: Dict[str, str]) -> List[Tuple[str, float, str]]:
        return [(str(cls), float(ratio), names.get(str(cls), str(cls)))
                for cls, ratio in self.attack_vs_class.items()]

    def effect_summary(self, names: Dict[str, str]) -> str:
        """一行效果摘要（列表里那一列 / 将领表单下面那句话）。"""
        parts: List[str] = []
        if self.speed_bonus:
            parts.append("移速 +%s" % fmt_percent(self.speed_bonus))
        if self.attack_speed_bonus:
            parts.append("攻速 +%s" % fmt_percent(self.attack_speed_bonus))
        if self.melee_reduction:
            parts.append("近战减伤 %s" % fmt_percent(self.melee_reduction))
        if self.ranged_reduction:
            parts.append("远程减伤 %s" % fmt_percent(self.ranged_reduction))
        if self.knockback_immune:
            parts.append("稳定")
        if self.capture_speed_bonus:
            parts.append("占领速度 +%s" % fmt_percent(self.capture_speed_bonus))
        if self.recruit_cavalry_discount:
            parts.append("招募骑兵 -%s" % fmt_percent(self.recruit_cavalry_discount))
        if self.charge_damage_bonus:
            parts.append("近战骑兵冲锋 +%s" % fmt_percent(self.charge_damage_bonus))
        if self.melee_splash:
            parts.append("范围伤害 %s 格 + 击退" % fmt_number(self.melee_splash.get("radius", 0.0)))
        for cls, ratio, cname in self.attack_rows(names):
            parts.append("对%s %s" % (cname, fmt_percent(ratio)))
        return " / ".join(parts) if parts else "（没有效果）"

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<GeneralTrait %s %s>" % (self.id, self.name)


class General:
    """一位将领：类型（决定兵种数值）+ 可选的数值覆盖 + 招募那一项。"""

    def __init__(self, index: int, kind: str, type_id: str, override: Dict[str, Any],
                 recruit: Optional[Dict[str, Any]], defaults: Dict[str, Any],
                 cap: int = GENERAL_CAP_DEFAULT,
                 recruit_sec: float = GENERAL_RECRUIT_DEFAULT,
                 trait_ids: Optional[Sequence[str]] = None,
                 upkeep_override: Optional[float] = None,
                 inherited_upkeep: float = 0.0,
                 tier: int = GENERAL_TIER_DEFAULT,
                 factions: Optional[Sequence[str]] = None,
                 coop_recruit: bool = False) -> None:
        self.index = index
        self.kind = kind
        self.type_id = type_id
        self.override = dict(override)
        #: ★★ 2026.11.5：这位将领的**阶**（`unit.general.tiers[index]`，0~3）。
        #: 0 阶 = 吃大本营成长（血量 / 攻击随局内大本营等级涨），也是备战页的「零阶」那一行。
        self.tier = max(0, min(3, int(tier)))
        #: ★★ 2026.11.5：**派系归属**（`unit.general.factions[index]`，可多个）。
        #: 顺序按 config 的 `clan.list`；空列表 = 哪个派系都不显示（设计师的明确选择）。
        self.factions: List[str] = list(factions or [])
        #: ★★ 2026.11：这位将领带的**全部**将领特性 id（`unit.general.trait_ids[index]`）。
        #: 空列表 = 没有特性。游戏侧由 `world.create_general()` 交给 `set_general_traits()`，
        #: 旗下附属兵出生时继承**全部**光环（`inherit_general_aura`）。
        self.trait_ids: List[str] = list(trait_ids or [])
        #: 第一条的兼容字段（老代码 / 老测试读它；多特性的完整列表看 `trait_ids`）。
        self.trait_id = self.trait_ids[0] if self.trait_ids else ""
        #: ★★ 这位将领自己的**持久消耗覆盖**（`unit.general.upkeep_override[<index>]`，
        #: 2026.11.4）：粮/秒。None = 跟随所属兵种（与 hp / armor 那套「不写就跟随」同语义）。
        self.upkeep_override = upkeep_override
        #: 所属兵种实际生效的维护费（覆盖时不看它，但界面要显示「跟随类型：0.08」）。
        self.inherited_upkeep = _f(inherited_upkeep, 0.0)
        #: ★★ 编制上限（`unit.general.caps[index]`）：这位将领的目标编队规模。
        #: 摆放 / 红点 / 阵地补员都以它封顶（见 logic/config.gd 的 general_cap_at）。
        self.cap = int(cap)
        #: ★★ 招兵读条秒数（`unit.general.recruit_sec[index]`，2026.11.2）：
        #: 这位将领当兵营时整批读条多久。没写 = GENERAL_RECRUIT_DEFAULT（10）。
        self.recruit_sec = _f(recruit_sec, GENERAL_RECRUIT_DEFAULT)
        rec = recruit or {}
        cost = rec.get("cost") if isinstance(rec.get("cost"), dict) else {}
        self.has_recruit = recruit is not None
        #: ★★ 2026.11：这条招募条目来自 `recruit.zone.coop_list`（**合作模式专用**），
        #:   还是常规的 `recruit.zone.list`。新将领不进对战 / 战役的招募表。
        self.coop_recruit = bool(coop_recruit)
        self.name = _s(self.override.get("name"), _s(rec.get("label"), "将领 %d" % (index + 1)))
        self.label = _s(rec.get("label"), self.name)
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.population_cost = _f(rec.get("population_cost"), 0.0)
        self.train_sec = _f(rec.get("train_sec"), 0.0)
        #: ★★ 「招募冷却」（本轮新增，`recruit.zone.list[].recruit_cooldown_sec`）：
        #: 招到这位之后、**该玩家全局**锁多少秒（见 logic/world.gd 的将领招募池段）。
        #: 0 = 招完不冷却（老数据 / 普通占位将领的行为）。
        self.recruit_cooldown_sec = _f(rec.get("recruit_cooldown_sec"), 0.0)
        #: 所属兵种那一档的数值（「跟随兵种」时显示的就是它）
        self.inherited = dict(defaults)
        #: 真正生效的数值 = 覆盖 ⊕ 兵种
        self.effective = dict(defaults)
        # ★ 可覆盖的数值键全在这里（与 GENERAL_STAT_FIELDS 同序）。
        #   ⚠️ 加一个可覆盖字段就必须同时加进 GENERAL_STAT_FIELDS（那张表是界面的来源）
        #      和这一行 —— 少一处就会「界面上有输入框、改了却没生效」。
        for key in ("hp_max", "armor", "damage", "range", "cooldown_sec", "speed", "vision"):
            if key in self.override and isinstance(self.override[key], (int, float)):
                self.effective[key] = float(self.override[key])

    def inherits(self, stat: str) -> bool:
        return stat not in self.override or not isinstance(self.override[stat], (int, float))

    # ---- 持久消耗（`unit.general.upkeep_override[<index>]`，2026.11.4）----

    @property
    def inherits_upkeep(self) -> bool:
        """维护费是不是「没写、跟随所属兵种」的。"""
        return self.upkeep_override is None

    @property
    def upkeep_effective(self) -> float:
        """**实际生效**的每秒维护费 = 自己的覆盖 ⊕ 所属兵种。"""
        return self.inherited_upkeep if self.upkeep_override is None else self.upkeep_override

    def effective_of(self, stat: str) -> float:
        return _f(self.effective.get(stat), 0.0)

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<General %d %s>" % (self.index + 1, self.type_id)


class RecruitPackage:
    """★ 一张**组合招募单**：一次下单生成好几个单位（`spawn` 列表）。

    例：王朝的 `dy_guard`（协防军）= `dy_spear_guard` + `dy_archer_guard`；
    `dy_royal`（御林军）= `dy_royal_sword` + `dy_royal_archer` + `dy_royal_cavalry`。

    ★★ 为什么单独一个类：它的 `kind` **不是** `unit.types` 里的兵种（没有血条 / 攻击
    这些数值），所以单位页列不出来；但它的**造价 / 人口 / 命令卡文案**必须能改，
    否则「协防军一次要多少粮」在编辑器里无处可改（2026.11.2 用户报的）。
    """

    def __init__(self, kind: str, row: Dict[str, Any], path: JsonPath, owner: str,
                 members: Sequence[Tuple[str, str]]) -> None:
        self.kind = kind
        self.path = list(path)
        self.owner = owner
        #: `[(兵种 id, 显示名)]` —— 这一单会生成谁（只读展示，数值去单位页改）
        self.members = list(members)
        self.label = _s(row.get("label"), kind)
        self.short = _s(row.get("short"), "")
        self.desc = _s(row.get("desc"), "")
        self.tier = int(row.get("tier", 1)) if isinstance(row.get("tier"), (int, float)) else 1
        cost = row.get("cost") if isinstance(row.get("cost"), dict) else {}
        self.cost_food = _f(cost.get("food"), 0.0)
        self.cost_gold = _f(cost.get("gold"), 0.0)
        self.population_cost = _f(row.get("population_cost"), 0.0)

    @property
    def count(self) -> int:
        """一次出几个（`spawn` 的条数）。"""
        return len(self.members)

    @property
    def member_text(self) -> str:
        """给人看的一行：`协防军枪（dy_spear_guard） + 协防军弓（dy_archer_guard）`。"""
        return " + ".join("%s（%s）" % (name, tid) for tid, name in self.members)

    def field(self, key: str) -> Any:
        return getattr(self, key, None)

    def __repr__(self) -> str:                        # pragma: no cover - 调试用
        return "<RecruitPackage %s %s>" % (self.kind, self.label)


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
        #: ★ 建造页同一行内的列（1..3）；没写 = None（自动排序，界面显示空输入框）。
        self.slot = int(_f(data.get("slot"), 0)) if "slot" in data else None
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
        #: ★★ 2026.10.26：建筑页行号 / 解锁所需的大本营等级（缺省 1）。
        self.tier = int(_f(data.get("tier"), 1))
        #: ★★ 2026.10.26：对远程伤害的免伤比例（缺省 0.9 = 90%）。
        self.ranged_reduction = _f(data.get("ranged_reduction"), 0.9)
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

    def class_upkeep(self, cls: str) -> float:
        """某个大类的**默认**持久消耗（`unit.classes.<class>.upkeep_food`，粮/秒）。

        ★ 这是「兵种没写 upkeep_food 时」的兜底值；游戏侧在载入时把它并进每个兵种
          （`logic/config.gd` 的 `unit_type_entry`），所以两边读到的是同一个数。
        """
        entry = self.doc.value(["unit", "classes", cls], None)
        if isinstance(entry, dict):
            return _f(entry.get("upkeep_food"), 0.0)
        return 0.0

    def set_unit_upkeep(self, uid: str, value: Optional[float]) -> None:
        """写兵种的持久消耗（粮/秒）。`None` = **删键**（跟随大类）。"""
        path: JsonPath = ["unit", "types", uid]
        if not self.doc.has(path):
            raise ModelError("没有这个单位类型：%s" % uid)
        if value is None:
            if self.doc.has(path + ["upkeep_food"]):
                self.doc.remove(path + ["upkeep_food"])
            return
        v = float(value)
        if v < 0.0:
            raise ModelError("持久消耗不能是负数：%r" % (value,))
        self.doc.set(path + ["upkeep_food"], v)

    def set_class_upkeep(self, cls: str, value: Optional[float]) -> None:
        """写大类的默认持久消耗（`unit.classes.<cls>.upkeep_food`）。`None` = 删键。"""
        path: JsonPath = ["unit", "classes", cls]
        if not self.doc.has(path):
            raise ModelError("没有这个兵种大类：%s" % cls)
        if value is None:
            if self.doc.has(path + ["upkeep_food"]):
                self.doc.remove(path + ["upkeep_food"])
            return
        v = float(value)
        if v < 0.0:
            raise ModelError("持久消耗不能是负数：%r" % (value,))
        self.doc.set(path + ["upkeep_food"], v)

    def _recruit_rows(self) -> List[Dict[str, Any]]:
        rows = self.doc.value(["recruit", "list"], [])
        return rows if isinstance(rows, list) else []

    def _recruit_locations(self) -> List[Tuple[JsonPath, str]]:
        """**所有**招募条目：全局表 + 每个派系的表（`clan.list[].recruit[]`）。

        @return `[(那一行的 JSON 路径, 表名)]`；表名给界面说明「这条在哪儿」。
        ★★ 2026.11.2：派系兵种（王朝 dy_* / 帝国 dg_*）的招募条目**只**存在于 clan 表里。
          只查全局表的老实现会把它们误判成「不在招募表」，造价 / 文案都改不了
          （用户报的就是这个）。
        """
        out: List[Tuple[JsonPath, str]] = []
        for i in range(len(self._recruit_rows())):
            out.append((["recruit", "list", i], "recruit.list"))
        clans = self.doc.value(["clan", "list"], [])
        if isinstance(clans, list):
            for ci in range(len(clans)):
                rows = self.doc.value(["clan", "list", ci, "recruit"], [])
                if not isinstance(rows, list):
                    continue
                cid = _s(self.doc.value(["clan", "list", ci, "id"], ""))
                owner = ("clan:%s" % cid) if cid else ("clan[%d]" % ci)
                for ri in range(len(rows)):
                    out.append((["clan", "list", ci, "recruit", ri], owner))
        return out

    def _recruit_location(self, kind: str) -> Optional[Tuple[JsonPath, str]]:
        """这个 kind 的招募条目在哪一行（全局表优先，再按派系顺序找）。"""
        for path, owner in self._recruit_locations():
            row = self.doc.value(path, None)
            if isinstance(row, dict) and _s(row.get("kind")) == kind:
                return path, owner
        return None

    def _recruit_index(self, kind: str) -> int:
        """这个 kind 在**全局** `recruit.list` 里的下标（不在那张表里 = -1）。"""
        for i, row in enumerate(self._recruit_rows()):
            if isinstance(row, dict) and _s(row.get("kind")) == kind:
                return i
        return -1

    def _spawn_source(self, uid: str) -> Optional[Tuple[JsonPath, str, str]]:
        """哪个招募条目会「顺带生成」这个兵种（组合单位的零件，如 dy_spear_guard）。

        @return `(那一单的路径, 表名, 那一单的显示名)`；没有任何单会生成它 → None。
        ★ 有它的兵种**不是**「不在招募表」：它跟那一单一起出，只是不单独占一格、
          也没有自己的一份造价（造价在那一单上）。
        """
        for path, owner in self._recruit_locations():
            row = self.doc.value(path, None)
            if not isinstance(row, dict):
                continue
            for s in (row.get("spawn") or []):
                if isinstance(s, dict) and _s(s.get("type")) == uid:
                    label = _s(row.get("label"), _s(row.get("kind")))
                    return path, owner, label
        return None

    def unit(self, uid: str) -> Unit:
        data = self.doc.value(["unit", "types", uid], None)
        if not isinstance(data, dict):
            raise ModelError("没有这个单位类型：%s" % uid)
        loc = self._recruit_location(uid)
        path, owner = loc if loc is not None else (None, "")
        row = self.doc.value(path, None) if path is not None else None
        return Unit(uid, data, row if isinstance(row, dict) else None,
                    self._recruit_index(uid), self.fog_vision_default(),
                    path, owner, self._spawn_source(uid),
                    self.class_upkeep(_s(data.get("class"), "infantry")))

    # ------------------------------------------------------------------
    # ★★ 组合招募单（`kind` 不是兵种 id、靠 spawn 一次出好几个的招募条目）
    # ------------------------------------------------------------------

    def _unit_name(self, uid: str) -> str:
        data = self.doc.value(["unit", "types", uid], None)
        return _s(data.get("name"), uid) if isinstance(data, dict) else uid

    def recruit_packages(self) -> List[RecruitPackage]:
        """所有**组合招募单**（`kind` 不是一个兵种 id 的招募条目），按数据里的顺序。

        ★ 典型例子：王朝的「协防军」（dy_guard）/「御林军」（dy_royal）。
        ★ 判据就是「kind 在不在 unit.types 里」——**不**看有没有 spawn：
          将来若出现「一单只出一个非兵种单位」，它同样需要这一页来改造价。
        """
        types = set(self.unit_ids())
        out: List[RecruitPackage] = []
        for path, owner in self._recruit_locations():
            row = self.doc.value(path, None)
            if not isinstance(row, dict):
                continue
            kind = _s(row.get("kind"))
            if not kind or kind in types:
                continue
            members: List[Tuple[str, str]] = []
            for s in (row.get("spawn") or []):
                if not isinstance(s, dict):
                    continue
                tid = _s(s.get("type"))
                if tid:
                    members.append((tid, self._unit_name(tid)))
            out.append(RecruitPackage(kind, row, path, owner, members))
        return out

    def recruit_package(self, kind: str) -> RecruitPackage:
        for pkg in self.recruit_packages():
            if pkg.kind == kind:
                return pkg
        raise ModelError("没有这张组合招募单：%s" % kind)

    def _write_recruit_field(self, path: JsonPath, field: str, value: Any) -> None:
        """把「造价 / 文案」写进**那一条招募行的实际路径**（单位页与组合单页共用）。"""
        if not self.doc.has(path + ["cost"]):
            self.doc.set(path + ["cost"], {})
        if field == "cost_food":
            self.doc.set(path + ["cost", "food"], value)
        elif field == "cost_gold":
            self.doc.set(path + ["cost", "gold"], value)
        else:
            self.doc.set(path + [field], value)

    def set_recruit_package(self, kind: str, field: str, value: Any) -> None:
        """改一张组合招募单的 文案 / 造价。`field` 见 PACKAGE_FIELDS。"""
        if field not in {f.key for f in PACKAGE_FIELDS}:
            raise ModelError("不认识的组合单字段：%s" % field)
        pkg = self.recruit_package(kind)
        self._write_recruit_field(pkg.path, field, value)

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
        if field in ("name", "ranged", "hp_max", "armor", "damage", "range", "cooldown_sec",
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
            #   ★★ 2026.11.2：按**条目实际所在的那张表**同步（派系兵种在 clan 表里）。
            if field == "name":
                loc = self._recruit_location(uid)
                if loc is not None:
                    self.doc.set(loc[0] + ["label"], value)
            return
        if field in ("cost_food", "cost_gold", "population_cost",
                     "label", "short", "desc"):
            loc = self._recruit_location(uid)
            if loc is None:
                raise ModelError("「%s」不在任何招募表里（recruit.list / clan.list[].recruit）："
                                 "先在下面的「加入招募表」按一下，才能改造价 / 文案" % uid)
            self._write_recruit_field(loc[0], field, value)
            return
        # ★★ 冲锋（嵌套在 `unit.types.<id>.charge` 里）：
        #   · 空值 = **删掉这一项**（读的时候按 0 处理）；
        #   · 第一次编辑时先建 charge 块（全 0），再写目标项 —— 与「不写 = 不冲锋」兼容。
        if field.startswith("charge."):
            sub = field.split(".", 1)[1]
            if sub not in {f.key for f in CHARGE_FIELDS}:
                raise ModelError("不认识的冲锋字段：%s" % sub)
            charge_path: JsonPath = unit_path + ["charge"]
            if value is None:
                if self.doc.has(charge_path + [sub]):
                    self.doc.remove(charge_path + [sub])
                return
            if not self.doc.has(charge_path):
                self.doc.set(charge_path, {f.key: 0.0 for f in CHARGE_FIELDS})
            self.doc.set(charge_path + [sub], value)
            return
        raise ModelError("不认识的单位字段：%s" % field)

    # ------------------------------------------------------------------
    # 兵种特性（`unit.types.<id>.traits`，2026.11.3）
    #
    # ★ 写法与「视野半径 / 冲锋」同一条：**空值 = 删掉那个键**（游戏侧读回 0 / 关闭），
    #   第一次编辑时才把 `traits` 那一块建出来 —— 没特性的兵种在文件里保持不变。
    # ------------------------------------------------------------------

    def _unit_traits_path(self, uid: str) -> JsonPath:
        unit_path: JsonPath = ["unit", "types", uid]
        if not self.doc.has(unit_path):
            raise ModelError("没有这个单位类型：%s" % uid)
        return unit_path + ["traits"]

    def _traits_of(self, uid: str) -> Dict[str, Any]:
        """这个兵种现在的 traits（**一层深拷贝**：改它不会动 Doc）。"""
        unit = self.unit(uid)
        out: Dict[str, Any] = {}
        for key, value in unit.traits.items():
            out[str(key)] = dict(value) if isinstance(value, dict) else value
        return out

    def _write_unit_traits(self, uid: str, traits: Dict[str, Any]) -> None:
        """把**整块** traits 写回去（加键 / 删键时才用它）。

        ★ 为什么加 / 删键要整块写：`configfile` 往多行字典**尾部插键**时，缩进按
          「最后一个子项的值」算 —— 而 traits 的最后一项常常是 `attack_vs_class`
          那个嵌套字典，插出来的新键会歪到它的列上（实测，见 test_model.py 的
          「排版」那一条）。整块写交给 `_dump` 统一排版。
        ★ 改**已有**键的值仍然走 `doc.set(path, value)`：只动一行，diff 最小。
        """
        path = self._unit_traits_path(uid)
        clean: Dict[str, Any] = {}
        for key, value in traits.items():
            if key == UNIT_TRAIT_ATTACK_KEY and not value:
                continue                  # 空的加成表不写进文件（读回来等价）
            clean[key] = value
        if not clean:
            # 加完又删回去：整块也不用留（`traits: {}` 与「没有这个键」在游戏里等价，
            # 但不留空块的文件更干净 —— 与「视野半径清空 = 删掉那个键」同一条）。
            if self.doc.has(path):
                self.doc.remove(path)
            return
        self.doc.set(path, clean)

    def _drop_unit_trait_key(self, uid: str, key: str) -> None:
        """删掉 traits 里的一个键；**删的是最后一个**就整块删掉（不留 `{}`）。"""
        path = self._unit_traits_path(uid)
        traits = self._traits_of(uid)
        if len(traits) <= 1:
            self.doc.remove(path)
            return
        self.doc.remove(path + [key])

    def set_unit_trait(self, uid: str, key: str, value: Any) -> None:
        """写 / 删兵种的一条**标量或开关**特性。

        @param key   `UNIT_TRAIT_FIELDS` 里的键，或 `knockback_immune`
        @param value `None` = 删掉这个键（回到「没有这一条」）；数字 / 布尔 = 写入
        """
        if key not in [f.key for f in UNIT_TRAIT_FIELDS] + [UNIT_TRAIT_KNOCKBACK.key]:
            raise ModelError("不认识的兵种特性：%s（只有 %s）"
                             % (key, "、".join([f.key for f in UNIT_TRAIT_FIELDS]
                                               + [UNIT_TRAIT_KNOCKBACK.key])))
        traits = self._traits_of(uid)
        if value is None:
            if key not in traits:
                return
            self._drop_unit_trait_key(uid, key)
            return
        if key == UNIT_TRAIT_KNOCKBACK.key:
            if not bool(value):
                # 取消勾选 = **删掉这个键**（与「清空减伤」同一条语义：文件里不留 false）。
                if key in traits:
                    self._drop_unit_trait_key(uid, key)
                return
            new_value: Any = True
        else:
            new_value = max(0.0, min(1.0, float(value)))
        if key in traits:
            if traits[key] == new_value:
                return                    # 值没变：一个字都不写（保住「改回来还原」）
            self.doc.set(self._unit_traits_path(uid) + [key], new_value)
            return
        traits[key] = new_value
        self._write_unit_traits(uid, traits)

    def set_unit_trait_attack(self, uid: str, cls: str, value: Optional[float]) -> None:
        """写 / 删「对某一大类伤害 +x%」（`traits.attack_vs_class.<cls>`）。

        @param value 比例（0.25 = +25%）；`None` = 删掉这一行
        """
        allowed = [cid for cid, _label in self.class_choices()]
        if cls not in allowed:
            raise ModelError("没有这个兵种大类：%r（unit.classes 里是：%s）"
                             % (cls, "、".join(allowed)))
        traits = self._traits_of(uid)
        raw_table = traits.get(UNIT_TRAIT_ATTACK_KEY)
        table: Dict[str, Any] = dict(raw_table) if isinstance(raw_table, dict) else {}
        if value is None:
            if cls not in table:
                return
            path = self._unit_traits_path(uid) + [UNIT_TRAIT_ATTACK_KEY]
            if len(table) <= 1:
                self.doc.remove(path)          # 最后一行：整张表也删掉
                return
            self.doc.remove(path + [cls])
            return
        # ★ 游戏侧只夹下界（`maxf(0.0, ...)`），这里给个上限只挡误输入
        #   （写成 25 会被夹到 10，状态栏会说一句）。
        new_value = max(0.0, min(10.0, float(value)))
        if cls in table:
            if table[cls] == new_value:
                return
            self.doc.set(self._unit_traits_path(uid) + [UNIT_TRAIT_ATTACK_KEY, cls],
                         new_value)
            return
        table[cls] = new_value
        traits[UNIT_TRAIT_ATTACK_KEY] = table
        self._write_unit_traits(uid, traits)

    def add_unit_trait_attack(self, uid: str, cls: str,
                              value: float = UNIT_TRAIT_ATTACK_DEFAULT) -> None:
        """给一个兵种加一条「对某大类伤害 +x%」（缺省 +25%）。"""
        unit = self.unit(uid)
        if cls in unit.attack_vs_class:
            raise ModelError("「%s」已经有对%s的加成了（改那一行的数就行）"
                             % (uid, dict(self.class_choices()).get(cls, cls)))
        self.set_unit_trait_attack(uid, cls, value)

    def add_recruit_entry(self, uid: str) -> None:
        """把一个**任何招募表里都没有**的单位加进全局招募表（照默认值，之后可改）。

        ★★ 2026.11.2：已经在某个派系表（`clan.list[].recruit[]`）里的单位**不再**加一条 ——
          它本来就招得出来，再加一条全局条目等于让它对所有派系都出现。
        """
        if self._recruit_location(uid) is not None:
            return
        unit = self.unit(uid)
        self.doc.append(["recruit", "list"], {
            "kind": uid,
            "label": unit.name,
            "short": unit.name[:1],
            "desc": "招募 1 名%s" % unit.name,
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
        # 2) 招募表那一项：模板有就抄（不论它在全局表还是派系表里），没有就照默认值新建
        loc = self._recruit_location(template_id)
        if loc is not None:
            self.doc.append_raw(["recruit", "list"], self.doc.text_of(loc[0]))
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
        # ★★ 2026.11.2：招募条目可能挂在**任何**一张表里（全局 / 派系），按实际路径删。
        loc = self._recruit_location(uid)
        if loc is not None:
            self.doc.remove(loc[0])
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
        """第 index 位将领在**招募卡**里的 kind（`general_1` / `general_2` / …）。

        ★★ 2026.11.5：名册的下标与 kind 的对应关系现在**两种**：
          · 下标 9（`GENERAL_START_INDEX`）= 开局将领 #0 → kind `general_0`；
          · 其余下标 N → kind `general_<N+1>`。
        于是编辑器在末尾「加将领」得到的下标 10/11… 对应 `general_11` / `general_12` ——
        **`general_10` 这个 kind 永远不存在**（第 10 档已经叫 `general_0` 了）。
        这与运行时 `ConfigRes.general_index_of()` 是同一套映射（那边是静态函数）。
        """
        if index == GENERAL_START_INDEX:
            return "general_0"
        return "general_%d" % (index + 1)

    def _general_recruit_slot(self, kind: str) -> Tuple[Tuple[str, ...], int]:
        """第 `kind` 位将领的招募条目在哪张表、第几条。

        ★★ 2026.11：两张表 **`recruit.zone.list`（对战 / 战役）** 与
        **`recruit.zone.coop_list`（合作专用）**。先查常规表，再查合作表；
        都没有 → `((), -1)`。`general()` 与 `set_general()` 共用这一处，
        免得「读的是 A 表、写的是 B 表」。
        """
        for table in (("recruit", "zone", "list"), ("recruit", "zone", "coop_list")):
            rows = self.doc.value(list(table), [])
            if not isinstance(rows, list):
                continue
            for i, row in enumerate(rows):
                if isinstance(row, dict) and _s(row.get("kind")) == kind:
                    return table, i
        return (), -1

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
        recruit_path: Tuple[str, ...] = ()
        table, ridx = self._general_recruit_slot(kind)
        if ridx >= 0:
            rows = self.doc.value(list(table), [])
            recruit = rows[ridx]
            recruit_path = table
        coop_recruit = bool(recruit_path) and recruit_path[-1] == "coop_list"
        defaults: Dict[str, Any] = {}
        if self.doc.has(["unit", "types", type_id]):
            u = self.unit(type_id)
            defaults = {"hp_max": u.hp_max, "damage": u.damage, "range": u.range,
                        "cooldown_sec": u.cooldown_sec, "speed": u.speed,
                        # ★ 视野跟随所属兵种（含「兵种没写 → fog.vision_default」那一层，
                        #   见 Unit.vision_effective）—— 将领的覆盖就是在这个数上覆盖。
                        "vision": u.vision_effective}
        # ★★ 编制上限：读 `unit.general.caps[index]`（缺省 / 越界 → GENERAL_CAP_DEFAULT）。
        cap = GENERAL_CAP_DEFAULT
        caps = self.doc.value(["unit", "general", "caps"], [])
        if isinstance(caps, list) and index < len(caps) \
                and isinstance(caps[index], (int, float)):
            cap = max(0, int(caps[index]))
        # ★★ 招兵读条：读 `unit.general.recruit_sec[index]`（缺省 / 越界 / ≤ 0 → 10）。
        recruit_sec = GENERAL_RECRUIT_DEFAULT
        rsecs = self.doc.value(["unit", "general", "recruit_sec"], [])
        if isinstance(rsecs, list) and index < len(rsecs):
            v = rsecs[index]
            if isinstance(v, (int, float)) and not isinstance(v, bool) and float(v) > 0.0:
                recruit_sec = float(v)
        # ★★ 将领特性（2026.11.3）：读 `unit.general.trait_ids[index]`
        #   （缺省 / 越界 / 指向池里不存在的 id → ""，与游戏侧 `general_trait_at` 同一条）。
        # ★★ 持久消耗（2026.11.4）：`unit.general.upkeep_override[str(index)]`；
        #   没写 = 跟随所属兵种（`unit_upkeep_of(type_id)`）。
        uph: Optional[float] = None
        ov = self.doc.value(["unit", "general", "upkeep_override"], None)
        if isinstance(ov, dict):
            raw = ov.get(str(index), None)
            if isinstance(raw, (int, float)) and not isinstance(raw, bool):
                uph = max(0.0, float(raw))
        inherited_upkeep = 0.0
        if self.doc.has(["unit", "types", type_id]):
            inherited_upkeep = self.unit(type_id).upkeep_effective
        return General(index, kind, type_id, override, recruit, defaults, cap, recruit_sec,
                       self.general_traits_at(index), uph, inherited_upkeep,
                       self.general_tier(index), self.general_factions(index),
                       coop_recruit)

    def generals(self) -> List[General]:
        return [self.general(i) for i in range(self.general_count())]

    # ------------------------------------------------------------------
    # 将领的阶 / 派系归属 / 大本营成长（2026.11.5）
    # ------------------------------------------------------------------

    def general_tier(self, index: int) -> int:
        """第 index 位将领的**阶**（`unit.general.tiers[index]`，0~3）。

        ★ 口径与游戏侧 `config.general_tier_at()` **逐条一致**：
          1. `unit.general.tiers[index]` 有数字 → 用它；
          2. 没写这一栏 → 退回老的 `recruit.zone.list[].tier`（兼容老配置）；
          3. 都没有 → 开局那一档（下标 9）是 0，其余是 1。
        """
        tiers = self.doc.value(["unit", "general", "tiers"], [])
        if isinstance(tiers, list) and 0 <= index < len(tiers) \
                and isinstance(tiers[index], (int, float)) and not isinstance(tiers[index], bool):
            return max(0, min(3, int(tiers[index])))
        kind = self._general_kind(index)
        rows = self.doc.value(["recruit", "zone", "list"], [])
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict) and _s(row.get("kind")) == kind:
                    v = row.get("tier")
                    if isinstance(v, (int, float)) and not isinstance(v, bool):
                        return max(0, min(3, int(v)))
        return 0 if index == GENERAL_START_INDEX else GENERAL_TIER_DEFAULT

    def set_general_tier(self, index: int, tier: Any) -> None:
        """改第 index 位将领的**阶**（写 `unit.general.tiers[index]`，夹到 0~3）。

        ★ 只写这一个键：招募表里那份旧的 `tier` 已经删掉了（一个数只有一处），
          所以「阶」对「可招募将领」与「编辑器新加的将领」是同一份数据。
        """
        self._check_general_index(index)
        value = 0 if tier is None else int(tier)
        value = max(0, min(3, value))
        self._ensure_general_array("tiers", lambda i: self.general_tier(i))
        self.doc.set(["unit", "general", "tiers", index], value)

    def general_faction_ids(self) -> List[str]:
        """`clan.list` 里的全部派系 id（**声明顺序**；没有 clan 段时退回三派常量）。"""
        ids: List[str] = []
        rows = self.doc.value(["clan", "list"], [])
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    cid = _s(row.get("id"))
                    if cid and cid not in ids:
                        ids.append(cid)
        return ids or list(GENERAL_FACTION_DEFAULT_IDS)

    def faction_choices(self) -> List[Tuple[str, str]]:
        """派系复选框的选项：`(id, 名字)`（名字来自 `clan.list[].name`）。"""
        out: List[Tuple[str, str]] = []
        names: Dict[str, str] = {}
        rows = self.doc.value(["clan", "list"], [])
        if isinstance(rows, list):
            for row in rows:
                if isinstance(row, dict):
                    cid = _s(row.get("id"))
                    if cid:
                        names[cid] = _s(row.get("name"), cid)
        for cid in self.general_faction_ids():
            out.append((cid, names.get(cid, cid)))
        return out

    def general_factions(self, index: int) -> List[str]:
        """第 index 位将领的**派系归属**（`unit.general.factions[index]`）。

        ★ 口径与游戏侧 `config.general_factions_at()` 一致：
          · 这一项**没写** ⇒ 返回**全部派系**（= 哪个派系都显示它，老配置行为不变）；
          · 写了（哪怕是 `[]`）⇒ 就是写的那几个（`[]` = 哪个派系都不显示）。
        """
        all_ids = self.general_faction_ids()
        arr = self.doc.value(["unit", "general", "factions"], None)
        if not isinstance(arr, list) or not (0 <= index < len(arr)):
            return list(all_ids)
        raw = arr[index]
        ids: List[str] = []
        if isinstance(raw, list):
            ids = [_s(v) for v in raw if isinstance(v, str) and _s(v) != ""]
        elif isinstance(raw, str) and raw != "":
            ids = [raw]
        else:
            return []                                   # 显式写了空 = 哪个派系都不显示
        # 未知 id（派系被删 / 拼错）在这里过滤掉，免得界面出现一个查不到的勾。
        return [cid for cid in ids if cid in all_ids]

    def set_general_faction(self, index: int, cid: str, on: bool) -> None:
        """勾 / 取消一个派系归属（写 `unit.general.factions[index]`，**保持顺序**）。"""
        self._check_general_index(index)
        if cid not in self.general_faction_ids():
            raise ModelError("没有这个派系：%s" % cid)
        ids = self.general_factions(index)
        if on and cid not in ids:
            ids.append(cid)
        elif not on and cid in ids:
            ids.remove(cid)
        else:
            return
        self._ensure_general_array("factions", lambda i: self.general_factions(i))
        # ★ 顺序按 `clan.list` 的声明顺序写回：勾选顺序不影响文件（免得撤销 / 重做 diff 抖动）。
        order = {c: i for i, c in enumerate(self.general_faction_ids())}
        ids.sort(key=lambda c: order.get(c, 999))
        self.doc.set(["unit", "general", "factions", index], list(ids))

    def add_general(self, name: str, type_id: str, tier: int = 0) -> int:
        """★ 2026.11.5：**在名册末尾加一位将领**（`unit.general.*` 每张同序表一起变长）。

        @return 新将领的名册下标（0 起）

        口径（用户拍板：「只加数值档，不进招募九宫格」）：
          · 只在 `unit.general.*` 那几张表里追加，**不动** `recruit.zone.list`
            ⇒ 这位将领不会被区划招募出来；它由关卡摆放 / 开局获得；
          · 类型 / 名字 / 阶由对话框给；编制上限 / 招兵读条 / 特性 / 成长按缺省补；
          · 派系归属默认**全部派系**（与「没写这一项」等价，改名 / 改归属在侧栏里做）。

        ★★ 2026.11（用户口径：「将领应当是单独的单位，有独立的对象……后续要加新将领也独立」）：
          `type_id` 现在是**模板**——会先复制出一条**只属于这位将领**的新兵种
          （id = `<模板>_lord_<序号>`，名字 / 图标取将领的名字），再让 `unit.general.types`
          指向它。之后改这位将领的数值 = 改它自己的兵种，不会连带改到模板 / 别的将领。

        ★ 为什么必须「先把每张表补齐、再一起追加」：这几张表是**按下标对齐**的，
          少补一张就会出现「第 11 位将领读到了别的东西」——那是最难查的一类 bug。
        """
        name = (name or "").strip()
        if not name:
            raise ModelError("将领名字不能空着")
        if not self.doc.has(["unit", "types", type_id]):
            raise ModelError("没有这个单位类型：%s" % type_id)
        idx = self.general_count()
        if idx <= GENERAL_START_INDEX:
            # 名册不足 10 档时「追加」会占掉开局将领 #0 的位置（下标 9）——先修 types。
            raise ModelError("名册只有 %d 档（至少要 %d 档：0-8 可招募 + 第 10 档开局将领），"
                             "先把 unit.general.types 补全" % (idx, GENERAL_START_INDEX + 1))
        # ① 现有各表补齐到「当前将领数」，保证追加后仍是同长的
        self._ensure_general_slot(idx - 1)
        self._ensure_caps_slot(idx - 1)
        self._ensure_recruit_sec_slot(idx - 1)
        self._ensure_trait_ids_slot(idx - 1)
        self._ensure_general_array("tiers", lambda i: self.general_tier(i))
        self._ensure_general_array("factions", lambda i: self.general_factions(i))
        # ①.5 ★★ 复制出一条「只属于这位将领」的兵种（独立对象）
        own_type = self._clone_lord_type(type_id, name, idx + 1)
        # ② 七张同序表各追加一项
        self.doc.append(["unit", "general", "types"], own_type)
        self.doc.append(["unit", "general", "stats"], {"name": name})
        self.doc.append(["unit", "general", "caps"], GENERAL_CAP_DEFAULT)
        self.doc.append(["unit", "general", "recruit_sec"], GENERAL_RECRUIT_DEFAULT)
        self.doc.append(["unit", "general", "trait_ids"], [])
        self.doc.append(["unit", "general", "tiers"], max(0, min(3, int(tier))))
        self.doc.append(["unit", "general", "factions"], list(self.general_faction_ids()))
        return idx

    def _clone_lord_type(self, template_id: str, name: str, ordinal: int) -> str:
        """复制一条**只属于某位将领**的兵种（`unit.types.<新 id>`），返回新 id。

        ★★ 2026.11 用户口径：「将领应当是单独的单位，有独立的对象；后续要加新将领也独立」。
          · 复制模板的**全部**字段（贴图 / 大类 / 远近 / 血量 / 攻击 / 特性 / 冲锋…）；
          · 名字 = 将领名，图标 = 名字首字（没写时会跟着名字走，也就不用手填了）；
          · id = `<模板>_lord_<序号>`，撞了就往后加数字 —— 序号只增不减，稳定可读。
        """
        src = self.doc.value(["unit", "types", template_id], None)
        if not isinstance(src, dict):
            raise ModelError("没有这个单位类型：%s" % template_id)
        row = json.loads(json.dumps(src, ensure_ascii=False))
        row["name"] = name
        row["icon"] = name[:1]
        base = "%s_lord" % template_id
        cand = "%s_%d" % (base, ordinal)
        n = ordinal
        while self.doc.has(["unit", "types", cand]):
            n += 1
            cand = "%s_%d" % (base, n)
        self.doc.set(["unit", "types", cand], row)
        return cand

    def general_growth(self) -> Dict[str, float]:
        """**0 阶将领的大本营成长**（`unit.general.growth`，全局一份）。

        ★ 缺省 0：老配置 / 测试配置不会静默变强（与游戏侧 `num(...)` 的兜底一致）。
        """
        row = self.doc.value(["unit", "general", "growth"], {})
        row = row if isinstance(row, dict) else {}
        return {
            "hp_max_per_level": _f(row.get("hp_max_per_level"), 0.0),
            "damage_per_level": _f(row.get("damage_per_level"), 0.0),
        }

    def set_general_growth(self, key: str, value: Any) -> None:
        """改 0 阶成长的一个键（`unit.general.growth.<key>`，夹 ≥ 0）。"""
        keys = [f.key for f in GENERAL_GROWTH_FIELDS]
        if key not in keys:
            raise ModelError("不认识的将领成长字段：%s" % key)
        v = max(0.0, _f(value, 0.0))
        if not self.doc.has(["unit", "general", "growth"]):
            self.doc.set(["unit", "general", "growth"], {})
        self.doc.set(["unit", "general", "growth", key], v)

    def _ensure_general_array(self, key: str, default_of) -> None:
        """保证 `unit.general.<key>` 是一个**补到将领个数**的数组。

        @param default_of `default_of(i) -> 第 i 项的缺省值`
          （`tiers` 用「现在读到的那一阶」，`factions` 用「现在读到的那些派系」）
        ★ 只在缺项时补：已经写了的那几项一个都不动（老配置保存后的 diff 只有新项）。
        ★ 缺省值必须在**写数组之前**算好：`default_of()` 读的就是这个路径，
          先 set 一个空数组再逐项问「缺省是什么」会读到刚写进去的空壳。
        """
        path: JsonPath = ["unit", "general", key]
        count = self.general_count()
        cur = self.doc.value(path, None)
        if not isinstance(cur, list):
            cur = []
        if len(cur) >= count:
            return
        if not isinstance(self.doc.value(path, None), list):
            self.doc.set(path, [default_of(i) for i in range(count)])
            return
        for i in range(len(cur), count):
            self.doc.append(path, default_of(i))

    def set_general_type(self, index: int, type_id: str) -> None:
        self._check_general_index(index)
        if not self.doc.has(["unit", "types", type_id]):
            raise ModelError("没有这个单位类型：%s" % type_id)
        self.doc.set(["unit", "general", "types", index], type_id)

    def _check_general_index(self, index: int) -> None:
        """将领的**个数**由 unit.general.types 定。

        ★★ 2026.11.5：编辑器现在**能加将领**（`add_general`，只追加在末尾），
           但**不能删 / 不能插队**：删掉中间一位会让后面所有将领的序号前移，
           而存档 / 关卡 JSON / 招募表都按序号引用它们（那是不可逆的数据损坏）。
        ⚠️ 越界的序号必须当场拒掉：`_ensure_general_slot` 会「顺手补一条」，
           不拦的话 `set_general(99, ...)` 会真的写出第 100 条覆盖记录，
           而游戏只读 types 那么多个 —— 数据里躺着一份谁也读不到的东西。
        """
        if not 0 <= index < self.general_count():
            raise ModelError("没有第 %d 位将领（现在有 %d 位）" % (index + 1, self.general_count()))

    def set_general(self, index: int, field: str, value: Any) -> None:
        """改将领的 名称 / 招兵读条 / 造价 / 区划招募读条 / 招募冷却。"""
        self._check_general_index(index)
        kind = self._general_kind(index)
        self._ensure_general_slot(index)
        table, ridx = self._general_recruit_slot(kind)
        if field == "cap":
            # ★★ 编制上限：写 `unit.general.caps[index]`（≥ 1）。
            self._ensure_caps_slot(index)
            self.doc.set(["unit", "general", "caps", index], max(1, int(value)))
            return
        if field == "recruit_sec":
            # ★★ 招兵读条（2026.11.2）：写 `unit.general.recruit_sec[index]`。
            #   清空（None）= 删掉这一项 → 回到 GENERAL_RECRUIT_DEFAULT（10 秒）。
            self._ensure_recruit_sec_slot(index)
            path = ["unit", "general", "recruit_sec", index]
            if value is None:
                self.doc.set(path, GENERAL_RECRUIT_DEFAULT)
            else:
                self.doc.set(path, max(0.01, float(value)))
            return
        if field == "name":
            self.doc.set(["unit", "general", "stats", index, "name"], value)
            if ridx >= 0:
                self.doc.set(list(table) + [ridx, "label"], value)
            return
        if field in ("cost_food", "cost_gold", "population_cost", "train_sec",
                     "recruit_cooldown_sec"):
            if ridx < 0:
                raise ModelError("将领 %d 不在任何招募表里（recruit.zone.list / coop_list），"
                                 "改不了造价 / 招募时间 / 招募冷却" % (index + 1))
            if field == "cost_food":
                self.doc.set(list(table) + [ridx, "cost", "food"], value)
            elif field == "cost_gold":
                self.doc.set(list(table) + [ridx, "cost", "gold"], value)
            else:
                self.doc.set(list(table) + [ridx, field], value)
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

    def set_general_upkeep(self, index: int, value: Optional[float]) -> None:
        """写 / 删**将领自己的**持久消耗覆盖（`unit.general.upkeep_override[<index>]`）。

        `None` = 删掉这一项 → 跟随所属兵种（与 hp / armor 那套覆盖同一条语义）。
        ★ 这一项是**稀疏对象**（键 = 将领序号的字符串），不是数组：
          缺项就是「跟随类型」，不需要往文件里写 null。
        """
        self._check_general_index(index)
        root: JsonPath = ["unit", "general", "upkeep_override"]
        if value is None:
            if self.doc.has(root + [str(index)]):
                self.doc.remove(root + [str(index)])
            return
        v = float(value)
        if v < 0.0:
            raise ModelError("持久消耗不能是负数：%r" % (value,))
        if not self.doc.has(root):
            self.doc.set(root, {})
        self.doc.set(root + [str(index)], v)

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

    def _ensure_caps_slot(self, index: int) -> None:
        """保证 `unit.general.caps` 存在、且补到**将领个数**（老配置里可能整段都没有）。

        ★ 缺省值用 `GENERAL_CAP_DEFAULT`（= 引擎 `general_cap_at` 的兜底），
          这样补出来的那几位与「没写」在游戏里完全等价。
        """
        if not self.doc.has(["unit", "general", "caps"]):
            self.doc.set(["unit", "general", "caps"],
                         [GENERAL_CAP_DEFAULT for _ in range(self.general_count())])
        while self.doc.size(["unit", "general", "caps"]) <= index:
            self.doc.append(["unit", "general", "caps"], GENERAL_CAP_DEFAULT)

    def _ensure_recruit_sec_slot(self, index: int) -> None:
        """保证 `unit.general.recruit_sec` 存在、且补到**将领个数**。

        ★ 缺省值用 `GENERAL_RECRUIT_DEFAULT`（= 引擎 `general_recruit_sec` 的兜底），
          补出来的那几位与「没写」在游戏里完全等价（都是 10 秒）。
        """
        if not self.doc.has(["unit", "general", "recruit_sec"]):
            self.doc.set(["unit", "general", "recruit_sec"],
                         [GENERAL_RECRUIT_DEFAULT for _ in range(self.general_count())])
        while self.doc.size(["unit", "general", "recruit_sec"]) <= index:
            self.doc.append(["unit", "general", "recruit_sec"], GENERAL_RECRUIT_DEFAULT)

    # ------------------------------------------------------------------
    # 将领特性池（`unit.general_traits`）+ 每位将领指定哪一条
    #   （`unit.general.trait_ids[index]`）—— 2026.11.3
    #
    # ★ 为什么分成两张表：特性是**全局的一份池**（一族效果的定义），
    #   将领只是「点名要池里的哪一条」；删掉池里的一条时，正在用它的将领要一起清掉，
    #   否则游戏侧会读到一条永远匹配不上的 id（静默没有特性，最难查的那类 bug）。
    # ------------------------------------------------------------------

    def general_trait_ids(self) -> List[str]:
        """池里全部特性的 id（**按 config 里的顺序**，跳过 `_comment` 那类键）。"""
        return [k for k in self.doc.keys(["unit", "general_traits"]) if not k.startswith("_")]

    def general_trait(self, tid: str) -> GeneralTrait:
        row = self.doc.value(["unit", "general_traits", tid], None)
        if not isinstance(row, dict):
            raise ModelError("没有这条将领特性：%s" % tid)
        return GeneralTrait(tid, row)

    def general_traits(self) -> List[GeneralTrait]:
        return [self.general_trait(tid) for tid in self.general_trait_ids()]

    def general_trait_choices(self) -> List[Tuple[str, str]]:
        """池里每一条 `名字（id）`（多特性 UI 的「＋ 添加特性」下拉用）。"""
        out: List[Tuple[str, str]] = []
        for trait in self.general_traits():
            out.append((trait.id, "%s（%s）" % (trait.name, trait.id)))
        return out

    def general_traits_at(self, index: int) -> List[str]:
        """第 index 位将领带的**全部**特性 id（无效 / 不存在 / 重复的已过滤）。

        ★ 兼容老配置：`unit.general.trait_ids[index]` 写成字符串时当成「只有一条」。
        """
        arr = self.doc.value(["unit", "general", "trait_ids"], [])
        if not isinstance(arr, list) or index < 0 or index >= len(arr):
            return []
        raw = arr[index]
        if isinstance(raw, str):
            ids = [raw]
        elif isinstance(raw, list):
            ids = raw
        else:
            return []
        out: List[str] = []
        for v in ids:
            tid = _s(v)
            if tid and tid not in out and self.doc.has(["unit", "general_traits", tid]):
                out.append(tid)
        return out

    def general_trait_at(self, index: int) -> str:
        """第一条特性 id（兼容旧调用点）；**没指定 / 越界 / 池里没有 → 空串**。"""
        ids = self.general_traits_at(index)
        return ids[0] if ids else ""

    def _ensure_trait_ids_slot(self, index: int) -> JsonPath:
        """保证 `unit.general.trait_ids` 存在、补到**将领个数**，且每一项都是**数组**。

        ★ 老配置里可能是字符串（一条）—— 这里就地升成 `[\"...\"]`，之后写回一律是数组。
        """
        path: JsonPath = ["unit", "general", "trait_ids"]
        count = self.general_count()
        if not self.doc.has(path):
            self.doc.set(path, [[] for _ in range(count)])
        while self.doc.size(path) < count:
            self.doc.append(path, [])
        if index >= self.doc.size(path):                 # pragma: no cover - 越界已先被拒
            raise ModelError("没有第 %d 位将领" % (index + 1))
        arr = self.doc.value(path, [])
        if isinstance(arr, list):
            for i, value in enumerate(arr):
                if isinstance(value, str):
                    self.doc.set(path + [i], [value] if value else [])
        return path

    def assign_general_trait(self, index: int, tid: Optional[str]) -> None:
        """把一位将领的特性**整组替换**成 `[tid]`；`""` / `None` = 改成「无」。"""
        self._check_general_index(index)
        ids: List[str] = []
        if tid:
            if not self.doc.has(["unit", "general_traits", tid]):
                raise ModelError("没有这条将领特性：%s" % tid)
            ids = [tid]
        path = self._ensure_trait_ids_slot(index)
        self.doc.set(path + [index], ids)

    def add_general_trait_to(self, index: int, tid: str) -> None:
        """给一位将领**再加**一条特性（用户口径：「一个将领可以有多个特性」）。"""
        self._check_general_index(index)
        if not self.doc.has(["unit", "general_traits", tid]):
            raise ModelError("没有这条将领特性：%s" % tid)
        ids = self.general_traits_at(index)
        if tid in ids:
            raise ModelError("这位将领已经有「%s」了" % tid)
        ids.append(tid)
        path = self._ensure_trait_ids_slot(index)
        self.doc.set(path + [index], ids)

    def remove_general_trait_from(self, index: int, tid: str) -> None:
        """把某一条特性从一位将领身上拿掉（其余保持原顺序）。"""
        self._check_general_index(index)
        ids = [t for t in self.general_traits_at(index) if t != tid]
        path = self._ensure_trait_ids_slot(index)
        self.doc.set(path + [index], ids)

    def _general_trait_row(self, tid: str) -> Dict[str, Any]:
        """池里一条特性的原文（**一层深拷贝**；不存在就报错）。"""
        row = self.doc.value(["unit", "general_traits", tid], None)
        if not isinstance(row, dict):
            raise ModelError("没有这条将领特性：%s" % tid)
        out: Dict[str, Any] = {}
        for key, value in row.items():
            out[str(key)] = dict(value) if isinstance(value, dict) else value
        return out

    def _write_general_trait(self, tid: str, row: Dict[str, Any]) -> None:
        """整条特性写回去（加 / 删键时用）——理由与 `_write_unit_traits` 同一条：
        往多行字典尾部插键会按「最后那个值」的列缩进，而最后一项常常是
        `attack_vs_class` 那个嵌套字典。"""
        clean: Dict[str, Any] = {}
        for key, value in row.items():
            if key == GENERAL_TRAIT_ATTACK_KEY and not value:
                continue
            clean[key] = value
        self.doc.set(["unit", "general_traits", tid], clean)

    def set_general_trait_field(self, tid: str, field: str, value: Any) -> None:
        """改池里一条特性的**文案 / 标量效果**（`None` / 空串 = 删掉这个键）。"""
        # ★★ 2026.11：稳定是**开关**（写 true / 删键），与数值项分开处理。
        if field == GENERAL_TRAIT_KNOCKBACK.key:
            row = self._general_trait_row(tid)
            if value:
                if row.get(field) is True:
                    return
                row[field] = True
            else:
                if field not in row:
                    return
                row.pop(field, None)
            self._write_general_trait(tid, row)
            return
        row = self._general_trait_row(tid)
        text_keys = [f.key for f in GENERAL_TRAIT_TEXT_FIELDS]
        number_keys = [f.key for f in GENERAL_TRAIT_FIELDS]
        if field in text_keys:
            if field == "name":
                if not value:
                    raise ModelError("特性的名字不能空着")
                self.doc.set(["unit", "general_traits", tid, "name"], value)
                return
            # 空串 = 删掉这个键（`short` / `desc` 都是「没写也行」的）。
            if value is None or value == "":
                if field not in row:
                    return
                row.pop(field)
                self._write_general_trait(tid, row)
                return
            if field in row:
                if row[field] == value:
                    return
                self.doc.set(["unit", "general_traits", tid, field], value)
                return
            row[field] = value
            self._write_general_trait(tid, row)
            return
        if field not in number_keys:
            raise ModelError("不认识的将领特性字段：%s" % field)
        if value is None:
            if field not in row:
                return
            row.pop(field)
            self._write_general_trait(tid, row)
            return
        # 减伤 / 折扣是「比例」，超过 1 就等于无敌 / 免费 —— 与游戏侧 clampf 同一条上限。
        top = 1.0 if (field.endswith("_reduction")
                      or field == "recruit_cavalry_discount") else 10.0
        new_value = max(0.0, min(top, float(value)))
        if field in row:
            if row[field] == new_value:
                return
            self.doc.set(["unit", "general_traits", tid, field], new_value)
            return
        row[field] = new_value
        self._write_general_trait(tid, row)

    def set_general_trait_attack(self, tid: str, cls: str, value: Optional[float]) -> None:
        """写 / 删一条将领特性的「对某大类伤害 +x%」。"""
        allowed = [cid for cid, _label in self.class_choices()]
        if cls not in allowed:
            raise ModelError("没有这个兵种大类：%r（unit.classes 里是：%s）"
                             % (cls, "、".join(allowed)))
        row = self._general_trait_row(tid)
        raw_table = row.get(GENERAL_TRAIT_ATTACK_KEY)
        table: Dict[str, Any] = dict(raw_table) if isinstance(raw_table, dict) else {}
        if value is None:
            if cls not in table:
                return
            table.pop(cls)
            if table:
                row[GENERAL_TRAIT_ATTACK_KEY] = table
            else:
                row.pop(GENERAL_TRAIT_ATTACK_KEY, None)
            self._write_general_trait(tid, row)
            return
        new_value = max(0.0, min(10.0, float(value)))
        if cls in table:
            if table[cls] == new_value:
                return
            self.doc.set(["unit", "general_traits", tid, GENERAL_TRAIT_ATTACK_KEY, cls],
                         new_value)
            return
        table[cls] = new_value
        row[GENERAL_TRAIT_ATTACK_KEY] = table
        self._write_general_trait(tid, row)

    def add_general_trait_attack(self, tid: str, cls: str,
                                 value: float = GENERAL_TRAIT_ATTACK_DEFAULT) -> None:
        trait = self.general_trait(tid)
        if cls in trait.attack_vs_class:
            raise ModelError("「%s」已经有对%s的加成了" % (tid, dict(self.class_choices()).get(cls, cls)))
        self.set_general_trait_attack(tid, cls, value)

    def add_general_trait(self, new_id: str, name: str, template_id: str) -> None:
        """新建一条将领特性：**照模板复制一份原文**（连排版一起抄），再改 id 与名字。

        ★ 与 `add_unit` 同一条动线（「拿一个像的改几处」）。模板的 `short` 要删掉：
          留着会顶着模板那个字（例如新特性显示成「速」），删掉 = 跟着名字首字。
        ★ `template_id = ""`（池被删空、没有模板可抄）退成「只写名字」——
          否则「把特性全删了」会让这个功能把自己锁死（再也建不出第一条）。
        """
        self._check_new_trait_id(new_id)
        path: JsonPath = ["unit", "general_traits", new_id]
        if not template_id:
            self.doc.set(path, {"name": name})
            return
        if not self.doc.has(["unit", "general_traits", template_id]):
            raise ModelError("模板特性不存在：%s" % template_id)
        self.doc.insert_raw(["unit", "general_traits"], new_id,
                            self.doc.text_of(["unit", "general_traits", template_id]))
        self.doc.set(path + ["name"], name)
        if self.doc.has(path + ["short"]):
            self.doc.remove(path + ["short"])

    def remove_general_trait(self, tid: str) -> None:
        """删掉池里的一条特性，并把**正在用它的将领**身上的那一条去掉。

        ★ 这一步不能省：只删池里那份，`unit.general.trait_ids` 会留下一条指向不存在
          id 的记录 —— 游戏侧读到空特性、界面显示「无」，但数据里躺着一个坏 id。
        ★★ 2026.11：一位将领可以带多条 ⇒ 只把这一条从它的数组里拿掉，别的保留。
        """
        if not self.doc.has(["unit", "general_traits", tid]):
            raise ModelError("没有这条将领特性：%s" % tid)
        self.doc.remove(["unit", "general_traits", tid])
        arr = self.doc.value(["unit", "general", "trait_ids"], [])
        if isinstance(arr, list):
            for i, value in enumerate(arr):
                if isinstance(value, str):
                    if value == tid:
                        self.doc.set(["unit", "general", "trait_ids", i], [])
                    continue
                if isinstance(value, list) and tid in value:
                    self.doc.set(["unit", "general", "trait_ids", i],
                                 [t for t in value if _s(t) != tid])

    def _check_new_trait_id(self, new_id: str) -> None:
        if not new_id:
            raise ModelError("请填特性 id（英文小写 + 下划线）")
        if not ID_RE.match(new_id):
            raise ModelError("特性 id 只能用**小写字母开头** + 小写字母 / 数字 / 下划线：%r"
                             % new_id)
        if self.doc.has(["unit", "general_traits", new_id]):
            raise ModelError("已经有一条叫「%s」的将领特性了" % new_id)

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
        elif field == "slot" and value is None:
            # ★ `slot = None` = 删掉这个键 → 回到「按 config 顺序自动排」。
            if self.doc.has(path + ["slot"]):
                self.doc.remove(path + ["slot"])
        elif field in ("name", "buildable", "tier", "slot", "build_sec", "hp_max",
                       "body_scale", "vision", "ranged_reduction", "attackable",
                       "damage", "range", "cooldown", "color", "desc"):
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
        """加一个建筑：复制模板的定义（**不再**给新建筑配升级表）。"""
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
        # ★ 新建筑不继承模板的排内位置：空着 = 在它那一行自动补位。
        if self.doc.has(["building", new_id, "slot"]):
            self.doc.remove(["building", new_id, "slot"])
        # ★★ 2026.10.26：只有大本营可以升级；新建筑不再自动生成 upgrade.levels。

    @staticmethod
    def default_levels() -> List[Dict[str, Any]]:
        """一份 3 级升级表（只给大本营 / 旧数据兜底；普通建筑不再使用）。"""
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
    # 科技：★ 2026.11 已整块搬走（见文件头那条说明）
    #
    # 原来这里有 `techs()/tech()/set_tech()/set_tech_effect()/max_active()/set_max_active()`
    # 与 `Tech` 类。现在科技（两张表 + 每派槽位 + 全局上限 / 每阶金耗）由
    # `tools/buff_editor` 编辑；本工具碰都不碰 `tech.*`，所以也**不会**因为
    # 「它不认识派系池」而把 `tech.clan_list` 写坏。
    # ------------------------------------------------------------------
