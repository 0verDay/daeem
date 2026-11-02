"""model.py —— buff 数值的语义 / 校验 / 预览（无界面，可无头测试）。

★★ 这个工具改的是**游戏唯一的数值表** `daeem/data/config.json`。

    游戏里的 buff 现在只有一条 **士气**（详细信息右栏那个「士」方块）：
    `logic/morale.gd` 按 `config.morale.*` 跑规则，`view/hud.gd` 用同一批数拼悬停说明。
    这条 buff 的「数值」= config.morale 的 19 个键 + 一个共用的减伤封顶
    （`combat.damage_reduction_cap`，它同时管士气免伤与骑手的兵种特性）。

★ 以后游戏真加了别的 buff，**不用改界面**：在下面的 `BUFFS` 注册表里加一条
  `Buff(...)`（id / 名字 / 图标 / config 路径前缀 / 字段表），app.py 会自动多一页。
  但注意：本工具只编辑**已经存在的键**，不会替游戏「发明」新 buff 的代码；
  加新 buff 仍然要游戏侧先读它。

★ 「百分数字段」的约定（`Field.kind == "percent"`）：
  config 里存的是**小数**（0.5 = 50%），界面显示与输入都是**百分数**（填 50 = 50%）。
  于是「改 50% → 55%」在编辑器里是 50 → 55，不需要在输入框里数小数点。
  写回文件时仍然是 0.55，与游戏读取口径一致。
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from .configfile import Doc, JsonError, parse_number, path_text

#: 路径 = 一串键（字典的字符串键）
CfgPath = Tuple[Any, ...]


class ModelError(Exception):
    """数据层的问题（配置文件读不到 / 缺字段 / 值不合法）。消息直接给设计师看。"""


# ======================================================================
# 字段描述
# ======================================================================

@dataclass(frozen=True)
class Field:
    """一个可编辑的 buff 数值。

    kind:
      · `"number"`  —— 普通数字（血量 / 每秒速率 / 阈值）。
      · `"percent"` —— 比例：config 存小数、界面显示百分数（见文件头）。
    lo / hi：允许范围（percent 也是**小数**口径，0.5 = 50%）。超出会被夹住并提示。
    path：覆盖默认位置（默认 = buff.path + (key,)）—— 目前只有「减伤封顶」用得上，
          因为它住在 combat 段、却是减伤这条 buff 规则的一部分。
    """

    key: str
    label: str
    group: str
    kind: str = "number"
    lo: Optional[float] = None
    hi: Optional[float] = None
    unit: str = ""
    help: str = ""
    path: Optional[CfgPath] = None

    def config_path(self, buff: "Buff") -> CfgPath:
        return self.path if self.path is not None else tuple(buff.path) + (self.key,)


@dataclass(frozen=True)
class Buff:
    """一条 buff 的元信息 + 它的字段表。"""

    id: str
    name: str
    icon: str
    path: CfgPath
    intro: str
    fields: Tuple[Field, ...]


#: 表单里分组的先后顺序（字段自己带 group 字符串）
GROUP_ORDER: Tuple[str, ...] = ("基础", "阈值", "生命", "伤害", "区划", "战果",
                                "文案", "效果", "槽位")


# ----------------------------------------------------------------------
# 士气（当前唯一的 buff）
# ----------------------------------------------------------------------
#: 游戏侧读这些键的唯一位置：`logic/config.gd` 的 `_cache_scalars()`（`num("morale.…")`）。
#: ⚠️ 改键名必须两边一起改 —— `test_model.py` 的 [4] 组会去 config.gd 里逐条找。
MORALE_FIELDS: Tuple[Field, ...] = (
    # ---- 基础
    Field("max", "士气上限", "基础", unit="点",
          help="所有单位共享的士气上限（游戏夹到 ≥1）"),
    Field("start", "初始士气", "基础", unit="点",
          help="开局每个单位的士气；应 ≤ 上限"),
    # ---- 阈值（从高到低）
    Field("high_tier", "≥ 高档阈值", "阈值", unit="点",
          help="达到它：快速回血 + 受伤减免（免伤比例见「伤害」组）"),
    Field("mid_tier", "≥ 中档阈值", "阈值", unit="点",
          help="达到它：缓慢回血"),
    Field("vuln_tier", "≤ 易伤阈值", "阈值", unit="点",
          help="低于它：受到伤害增加（易伤比例见「伤害」组）"),
    Field("low_tier", "≤ 掉血阈值", "阈值", unit="点",
          help="低于它：缓慢失去生命；士气 0 时换更快的掉血档"),
    # ---- 生命
    Field("hp_regen_high", "高档回血", "生命", unit="/秒",
          lo=0.0, help="士气 ≥ 高档阈值时，每秒回复多少生命"),
    Field("hp_regen_mid", "中档回血", "生命", unit="/秒",
          lo=0.0, help="士气 ≥ 中档阈值时，每秒回复多少生命"),
    Field("hp_decay_low", "低档掉血", "生命", unit="/秒",
          lo=0.0, help="士气 ≤ 掉血阈值时，每秒失去多少生命（不会致死）"),
    Field("hp_decay_zero", "零士气掉血", "生命", unit="/秒",
          lo=0.0, help="士气 = 0 时，每秒失去多少生命（不会致死）"),
    Field("hp_floor", "掉血下限", "生命", unit="点", lo=0.0,
          help="掉血最多扣到这里（游戏默认 1，保证不致死）"),
    # ---- 伤害
    Field("damage_reduction", "士气免伤", "伤害", kind="percent",
          lo=0.0, hi=0.95, help="士气 ≥ 高档阈值时，受到的伤害减少多少（与兵种特性加算）"),
    Field("vulnerability", "士气易伤", "伤害", kind="percent",
          lo=0.0, hi=5.0, help="士气 ≤ 易伤阈值时，受到的伤害增加多少"),
    Field("damage_reduction_cap", "减伤封顶（含兵种特性）", "伤害", kind="percent",
          lo=0.0, hi=0.99, path=("combat", "damage_reduction_cap"),
          help="所有减伤来源相加后的上限；同时管骑手的「对远程减伤」"),
    # ---- 区划联动
    Field("regen_ally", "己方区划回升", "区划", unit="/秒", lo=0.0,
          help="站在己方 / 友方区划里，每秒回升多少士气"),
    Field("decay_enemy", "敌方区划疲惫", "区划", unit="/秒", lo=0.0,
          help="站在敌方 / 中立区划里，每秒下降多少士气"),
    Field("decay_surrounded", "被包围区划疲惫", "区划", unit="/秒", lo=0.0,
          help="己方区划被包围（不与大本营连通）时，每秒下降多少士气"),
    # ---- 战果
    Field("boost_kill", "破敌加成", "战果", unit="点", lo=0.0,
          help="击杀一个敌方单位，所在部队立即 +多少士气"),
    Field("boost_leader", "斩将加成", "战果", unit="点", lo=0.0,
          help="击杀一个敌方将领，所在部队立即 +多少士气"),
    Field("boost_capture", "掠地加成", "战果", unit="点", lo=0.0,
          help="所在区划转为己方 / 友方时，区内单位所在部队立即 +多少士气"),
)


#: ★★ buff 注册表：工具里**所有能编辑的 buff**。
#:
#: 现在只有士气一条。以后加 buff 的步骤：
#:   1. 游戏侧先真的读它（config 段 / 逻辑）；
#:   2. 在下面加一条 `Buff(...)`，把字段与 config 路径写清楚；
#:   3. app.py / README 不用改（列表与表单都是按这张表生成的）。
BUFFS: Tuple[Buff, ...] = (
    Buff(
        id="morale",
        name="士气",
        icon="士",
        path=("morale",),
        intro="整支部队共享的士气：按区划升降；高档回血 + 免伤，低档易伤 + 掉血；"
              "破敌 / 斩将 / 掠地会立刻加成。",
        fields=MORALE_FIELDS,
    ),
)


# ======================================================================
# 科技（2026.11 加进本工具）
# ======================================================================
#
# ★ 为什么科技也归 buff_editor：它和 buff 是同一类东西 —— **一坨可调的数值/文案**，
#   写在同一份 `data/config.json` 里，改错了不会崩、只会静默变成另一套平衡。
#   单位编辑器管兵种/建筑/科技**表**的旧版（`tech.list` 曾经在那边），现在统一搬到这里：
#   `tech.list`（原生 9 条）+ `tech.clan_list`（派系池）+ `clan.list[].tech`（派系槽位）。
#
# ★ 科技**不是**一组标量，而是「几条条目、每条一堆键」。所以这里不写死 Buff，
#   而是按 doc 里**实际存在**的条目**动态生成** `Buff`（见 `ConfigModel.tech_buffs()`）。
#   ⇒ 本工具仍然只编辑**已经存在的键**：没写的 effect 键不会凭空造出来
#     （要加新键请先改 config.json，或者在游戏侧先读它）。

#: 科技条目上那几个**文字**键（其余是数字/百分比）
TECH_TEXT_KEYS: Tuple[str, ...] = ("name", "line", "desc")


@dataclass(frozen=True)
class TechEffectKey:
    """一个科技效果键的元信息（与 `logic/tech.gd` 的 `default_effects()` 一一对应）。

    kind：`number` = 加法增量；`percent` = 比例（config 存小数、界面显示百分数）。
    """

    key: str
    label: str
    kind: str = "number"
    lo: Optional[float] = None
    hi: Optional[float] = None
    unit: str = ""
    help: str = ""


#: ★★ 科技效果键注册表。**必须与 `logic/tech.gd` 的 `default_effects()` 保持一致**：
#: 这里没有的键，编辑器会当成「不认识的键」给出 ⚠ 提示（游戏里也会被静默忽略）。
TECH_EFFECT_KEYS: Tuple[TechEffectKey, ...] = (
    # ---- 2026.10 老键（基数特殊：倍率类 1.0、百分比类 0.0）
    TechEffectKey("food_production_mult", "总粮食产能", "percent", -0.95, 5.0, "%",
                  "作用在「区划基础 + 建筑固定」的总产出上；多条相加"),
    TechEffectKey("gold_production_mult", "总黄金产能", "percent", -0.95, 5.0, "%",
                  "同上，管黄金"),
    TechEffectKey("building_hp_mult", "建筑血量倍率", "percent", 0.0, 5.0, "%",
                  "基数 1.0：+10% 写 0.1"),
    TechEffectKey("leader_hp_mult", "将领血量倍率", "percent", 0.0, 5.0, "%",
                  "基数 1.0：+10% 写 0.1"),
    TechEffectKey("zone_population_mult", "区划人口增速", "percent", 0.0, 5.0, "%",
                  "基数 1.0：+20% 写 0.2；只管涨得多快，不改上限"),
    # ---- 2026.11 派系科技（全部是 0.0 基数的加法增量）
    TechEffectKey("unit_speed_mult", "全单位移速", "percent", -0.9, 3.0, "%",
                  "+0.10 = 移速 +10%"),
    TechEffectKey("capture_time_mult", "占领所需时间", "percent", -0.95, 3.0, "%",
                  "−0.20 = 占领快 20%（写的是「时间倍率」的增量）"),
    TechEffectKey("zone_population_cap_add", "每区划人口上限", "number", 0.0, 99.0, "人",
                  "绝对值增量（不是百分比）"),
    TechEffectKey("unit_melee_reduction_add", "全单位近战免伤", "percent", 0.0, 0.95, "%",
                  "进 take_damage 的同一个减免和，仍受 combat.damage_reduction_cap 封顶"),
    TechEffectKey("unit_ranged_reduction_add", "全单位远程免伤", "percent", 0.0, 0.95, "%",
                  "同上"),
    TechEffectKey("base_gold_per_sec_add", "每座大本营 +金", "number", 0.0, 50.0, "/秒",
                  "绝对值；与自身按等级的产能相加"),
    TechEffectKey("building_gold_per_sec_add", "每栋建筑 +金", "number", 0.0, 50.0, "/秒",
                  "只算**非大本营**建筑"),
    TechEffectKey("building_food_per_sec_add", "每栋建筑 +粮", "number", 0.0, 50.0, "/秒",
                  "只算**非大本营**建筑"),
    TechEffectKey("per_zone_attack_mult", "每区划 +攻击", "percent", 0.0, 1.0, "%",
                  "+0.02 = 每占领 1 个区划全军攻击 +2%"),
    TechEffectKey("per_zone_armor_mult", "每区划 +防御", "percent", 0.0, 1.0, "%",
                  "「防御」= 造成伤害时等额减免的那个数值（armor）"),
    TechEffectKey("per_squad_member_attack_mult", "每队员 +攻击", "percent", 0.0, 1.0, "%",
                  "+0.02 = 部队里每人给全队 +2%（单队封顶 +20%）"),
    TechEffectKey("unit_upkeep_mult", "单位维护费倍率", "percent", -1.0, 5.0, "%",
                  "全局乘数（目前没有科技用它）"),
    TechEffectKey("upkeep_idle_exempt", "脱战免维护", "number", 0.0, 1.0, "",
                  ">0 = 脱战单位免维护费（脱战判据与招募读条同一个）"),
    TechEffectKey("recruit_tier_unlock", "解除招募阶限制", "number", 0.0, 1.0, "",
                  ">0 = 任何阶都能招（不然要够大本营等级）"),
    TechEffectKey("recruit_gold_to_food", "招募金→粮比例", "number", 0.0, 10.0, "倍",
                  ">0 = 招募不再花金，按这个比例折成粮（1.5 = 1 金 → 1.5 粮）"),
    TechEffectKey("zone_convert_restore", "易主即回满", "number", 0.0, 1.0, "",
                  ">0 = 区划转为己方那一刻，区内己方单位血量+士气回满"),
    TechEffectKey("charge_damage_mult", "冲锋额外伤害", "percent", 0.0, 5.0, "%",
                  "冲锋命中时**加法**追加的额外伤害（1.0 = +100%；与兵种自带 charge.damage_bonus 相加，不影响普通攻击）"),
)

#: key → 元信息（查不到 = 不认识的键）
TECH_EFFECT_BY_KEY: Dict[str, TechEffectKey] = {k.key: k for k in TECH_EFFECT_KEYS}


def _tech_effect_field(key: str, entry_path: CfgPath) -> Field:
    """一个 effect 键 → 表单字段（认识的键按注册表给上下限与说明）。

    ⚠️ 效果键住在 `…<条目>.effect.<key>`，不是条目的直接子键 ⇒ 必须显式给 `path`
    （默认是 `buff.path + (key,)`，那是给「直接挂在条目上」的 key 用的）。
    """
    path = tuple(entry_path) + ("effect", key)
    meta = TECH_EFFECT_BY_KEY.get(key)
    if meta is None:
        return Field(key, key, "效果", kind="number", path=path,
                     help="⚠ 游戏不认识的键（会被静默忽略）——除非你真的在游戏侧加了它")
    return Field(key, meta.label, "效果", kind=meta.kind, lo=meta.lo, hi=meta.hi,
                 unit=meta.unit, help=meta.help, path=path)


# ======================================================================
# 显示 / 解析
# ======================================================================

def fmt_number(value: Any) -> str:
    """数字 → 界面写法：整数不带 `.0`（与 unit_editor 同一条口径）。"""
    if isinstance(value, bool):
        return "是" if value else "否"
    if isinstance(value, float):
        if value == int(value) and abs(value) < 1e15:
            return str(int(value))
        return ("%.4f" % value).rstrip("0").rstrip(".")
    if value is None:
        return ""
    return str(value)


def display_value(field: Field, value: Any) -> str:
    """config 里的值 → 输入框里显示的文字（percent 会 ×100 并加 `%`；text 原样）。"""
    if value is None:
        return ""
    if field.kind == "text":
        return str(value)
    if field.kind == "percent":
        return fmt_number(float(value) * 100.0) + "%"
    return fmt_number(value)


def parse_value(field: Field, text: str) -> Tuple[Any, str]:
    """输入框文字 → （写进 config 的值, 夹取提示）。

    · 不合法（空 / 不是数字）→ 抛 `ValueError`，调用方**不要**改数据；
    · 超出 lo/hi → 夹到边界，并在第二个返回值里说明一句；
    · percent：输入按**百分数**理解（`50` / `50%` 都是 0.5；`12.5` 是 0.125）；
    · text：原样当字符串（**允许空串** —— 科技的第二行小字 / 详情可以留空）。
    """
    s = str(text).strip()
    if field.kind == "text":
        return s, ""
    if not s:
        raise ValueError("不能为空")
    if field.kind == "percent":
        if s.endswith("%"):
            s = s[:-1].strip()
        n = parse_number(s)
        if n is None:
            raise ValueError("要填百分数（例如 50 或 50%%，不是「%s」）" % text)
        value: Any = float(n) / 100.0
    else:
        n = parse_number(s)
        if n is None:
            raise ValueError("要填数字（不是「%s」）" % text)
        value = n
    note = ""
    if isinstance(value, (int, float)):
        if field.lo is not None and value < field.lo:
            value = field.lo
            note = "已夹到最小 %s" % display_value(field, value)
        elif field.hi is not None and value > field.hi:
            value = field.hi
            note = "已夹到最大 %s" % display_value(field, value)
    return value, note


def _tech_slot_position(i: int) -> str:
    """第 i 格（0 基）在 3×3 里的位置说明：列优先 + 行 = 阶。"""
    col = ("左", "中", "右")[i // 3] if i < 9 else "?"
    return "第 %d 行 / %s列" % (i % 3 + 1, col)


def field_groups(buff: Buff) -> List[Tuple[str, List[Field]]]:
    """按 `GROUP_ORDER` 把字段分组（未知组排最后，保证不会丢字段）。"""
    out: List[Tuple[str, List[Field]]] = []
    seen: Dict[str, List[Field]] = {}
    for f in buff.fields:
        seen.setdefault(f.group, []).append(f)
    for group in GROUP_ORDER:
        if group in seen:
            out.append((group, seen.pop(group)))
    for group in seen:                     # 注册表里写了一个新组：按出现顺序补在后面
        out.append((group, seen[group]))
    return out


# ======================================================================
# 文档模型
# ======================================================================

class ConfigModel:
    """一份 config.json + 它的 buff 视图。所有修改都只动被改的那个值。"""

    def __init__(self, doc: Doc, path: Optional[Path] = None) -> None:
        self.doc = doc
        self.path = Path(path) if path is not None else None
        #: 上次保存 / 载入时的全文（判断「脏」用；None = 从没保存过，也算脏）
        self.saved_text: Optional[str] = None

    # ------------------------------------------------------------------
    # 载入 / 保存
    # ------------------------------------------------------------------
    @classmethod
    def load(cls, path: Path) -> "ConfigModel":
        path = Path(path)
        try:
            text = path.read_text(encoding="utf-8")
        except OSError as exc:
            raise ModelError("读不到配置文件 %s：%s" % (path, exc))
        model = cls.from_text(text, path)
        model.saved_text = text
        return model

    @classmethod
    def from_text(cls, text: str, path: Optional[Path] = None) -> "ConfigModel":
        try:
            doc = Doc(text)
        except JsonError as exc:
            raise ModelError("config.json 不是合法 JSON：%s" % exc)
        return cls(doc, path)

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
        try:
            target.write_text(self.doc.text, encoding="utf-8", newline="\n")
        except OSError as exc:
            raise ModelError("写不进 %s：%s" % (target, exc))
        self.path = target
        self.saved_text = self.doc.text
        return target

    def reload(self) -> None:
        if self.path is None:
            raise ModelError("没有文件路径，无法重载")
        fresh = ConfigModel.load(self.path)
        self.doc = fresh.doc
        self.saved_text = fresh.saved_text
        self.path = fresh.path

    def restore_text(self, text: str) -> None:
        """用一段旧文本替换内容（撤销 / 重做用）。

        ★ 只换 `doc`，**不动** `saved_text` —— 「脏」是「现在的文本 vs 磁盘上那份」，
          撤销回上次保存的内容时它自己会变回 False；把 saved_text 也一起改，
          反而会让标题在「已经和磁盘一致」时仍挂着「未保存」。
        """
        try:
            self.doc = Doc(text)
        except JsonError as exc:
            raise ModelError("撤销的文本坏了（不该发生）：%s" % exc)

    # ------------------------------------------------------------------
    # buff / 字段
    # ------------------------------------------------------------------
    def buffs(self) -> Tuple[Buff, ...]:
        """列表里能选的全部条目：先 buff，再按 doc 现算出科技条目。"""
        return tuple(BUFFS) + tuple(self.tech_buffs())

    def buff(self, buff_id: str) -> Buff:
        for b in self.buffs():
            if b.id == buff_id:
                return b
        raise ModelError("没有这条 buff：%s" % buff_id)

    # ------------------------------------------------------------------
    # 科技（★★ 2026.11：动态生成，见文件头的说明）
    # ------------------------------------------------------------------
    def tech_tables(self) -> List[Tuple[str, CfgPath, str]]:
        """科技表：[(表 id, config 路径, 人话名字)]。

        · `tech.list`      —— 原生那 9 条（派系「原生」用）；
        · `tech.clan_list` —— 派系科技池（王朝 / 帝国 + 两派共用那两条）。
        """
        out: List[Tuple[str, CfgPath, str]] = []
        for table, path, label in (
            ("list", ("tech", "list"), "原生科技（tech.list）"),
            ("clan_list", ("tech", "clan_list"), "派系科技（tech.clan_list）"),
        ):
            if self.doc.size(list(path)) > 0:
                out.append((table, path, label))
        return out

    def tech_entries(self, path: CfgPath) -> List[Dict[str, Any]]:
        """某张表里的条目（读不出来就是空字典；本工具不改坏数据）。

        ⚠️ 必须走 `Doc.value()`：`Node.value` 对容器是 `None`（它只给标量存值），
        直接读 `node.value` 会把每条科技都读成空字典（踩过）。
        """
        size = self.doc.size(list(path))
        out: List[Dict[str, Any]] = []
        for i in range(size):
            raw = self.doc.value(list(path) + [i], None)
            out.append(raw if isinstance(raw, dict) else {})
        return out

    def tech_buffs(self) -> List[Buff]:
        """把 doc 里**实际存在**的科技条目 / 全局标量 / 派系槽位翻成一页页表单。

        ★ 只编辑已经存在的键 ⇒ 没写的 effect 键不会出现在表单里。
        """
        out: List[Buff] = []
        if self.doc.get(["tech"]) is None:
            return out

        # ---- 全局标量（上限 / 每秒金耗）
        global_fields: List[Field] = []
        if self.doc.has(["tech", "max_active"]):
            global_fields.append(Field("max_active", "同时启用上限", "基础", lo=1, hi=9,
                                       unit="条", path=("tech", "max_active"),
                                       help="玩家同一时间最多能启用几条（默认 3）"))
        for i in range(self.doc.size(["tech", "gold_per_sec_by_tier"])):
            global_fields.append(Field(
                "gold_tier_%d" % (i + 1), "%d 阶每秒扣金" % (i + 1), "基础",
                lo=0.0, hi=100.0, unit="金/秒",
                path=("tech", "gold_per_sec_by_tier", i),
                help="启用中的科技按**阶**每秒扣金；付不起只把金扣到 0，不取消科技"))
        if global_fields:
            out.append(Buff(
                id="tech:global", name="科技 · 全局", icon="科", path=("tech",),
                intro="科技的通用规则：同时启用上限 + 每阶每秒扣多少金。"
                      "（扣金是「维持费」，不是一次性花费。）",
                fields=tuple(global_fields)))

        # ---- 一张表里的每一条科技
        for table, path, label in self.tech_tables():
            for i, entry in enumerate(self.tech_entries(path)):
                out.append(self._tech_entry_buff(table, path, i, entry, label))

        # ---- 派系槽位表（`clan.list[].tech`，9 个 id，空串 = 空位）
        for ci in range(self.doc.size(["clan", "list"])):
            clan = self.doc.value(["clan", "list", ci], None)
            if not isinstance(clan, dict):
                continue
            slots_path = (["clan", "list", ci, "tech"])
            if not self.doc.has(slots_path):
                continue                     # 原生不写 tech（= 用 tech.list），没有可编辑的槽位
            clan_id = str(clan.get("id", "clan%d" % ci))
            clan_name = str(clan.get("name", clan_id))
            n = self.doc.size(slots_path)
            fields: List[Field] = []
            for s in range(max(9, n)):
                if s >= n:
                    break                    # 只编辑已经存在的槽位
                fields.append(Field(
                    "slot_%d" % (s + 1),
                    "第 %d 格（%s）" % (s + 1, _tech_slot_position(s)), "槽位",
                    kind="text",
                    path=tuple(slots_path) + (s,),
                    help="填科技 id（在 tech.clan_list 里）；留空 = 空位（界面画灰框不可点）"))
            if fields:
                out.append(Buff(
                    id="tech:slots:%s" % clan_id, name="科技页 · %s" % clan_name,
                    icon="位", path=tuple(slots_path),
                    intro="%s 的科技页槽位：9 格按**列优先**排（列1上中下 → 列2 → 列3），"
                          "**行 = 阶**。所以第 1/4/7 格放一本、第 2/5/8 格放二本、"
                          "第 3/6/9 格放三本；空串 = 空位。" % clan_name,
                    fields=tuple(fields)))
        return out

    def _tech_entry_buff(self, table: str, path: CfgPath, index: int,
                         entry: Dict[str, Any], label: str) -> Buff:
        """一条科技 → 一页表单（文案 3 项 + 阶 + 它自己写了的每个 effect 键）。"""
        tid = str(entry.get("id", "#%d" % index))
        name = str(entry.get("name", tid))
        fields: List[Field] = [
            Field("name", "名字", "文案", kind="text",
                  help="命令卡那一格的第一行"),
            Field("line", "格子小字", "文案", kind="text",
                  help="第二行小字（80×80 的格子放不下长句，尽量短）"),
            Field("desc", "悬停详情", "文案", kind="text",
                  help="鼠标停在格子上时那块面板里的说明"),
            Field("tier", "阶（第几行）", "基础", lo=1, hi=3, unit="阶",
                  help="科技页第 N 行 = N 阶；要求大本营等级够才点得动"),
        ]
        effect = entry.get("effect", {})
        if isinstance(effect, dict):
            for key in effect:
                fields.append(_tech_effect_field(str(key), tuple(path) + (index,)))
        return Buff(
            id="tech:%s:%d" % (table, index),
            name="科技 · %s" % name,
            icon="科",
            path=tuple(path) + (index,),
            intro="%s 里的第 %d 条：`%s`。改文案与效果数值；"
                  "效果键名写错会被游戏**静默忽略**，所以这里只编辑已经存在的键。"
                  % (label, index + 1, tid),
            fields=tuple(fields))

    def value(self, buff: Buff, field: Field) -> Any:
        path = field.config_path(buff)
        node = self.doc.get(list(path))
        if node is None:
            raise ModelError("config 里缺少 %s（%s 这一项）" % (
                path_text(list(path)), buff.name))
        return node.value

    def set_value(self, buff: Buff, field: Field, value: Any) -> None:
        self.doc.set(list(field.config_path(buff)), value)

    # ------------------------------------------------------------------
    # 校验 / 预览
    # ------------------------------------------------------------------
    def values(self, buff: Buff) -> Dict[str, Any]:
        """`{field.key: 当前值}`（缺字段直接抛 ModelError —— 静默兜底会让工具骗人）。"""
        return {f.key: self.value(buff, f) for f in buff.fields}

    def warnings(self, buff: Buff) -> List[str]:
        """跨字段的合理性提示。**只提示、不阻止保存**（设计师可能在做实验）。"""
        if buff.id.startswith("tech:"):
            return self._tech_warnings(buff)
        out: List[str] = []
        if buff.id != "morale":
            return out
        v = self.values(buff)
        if float(v["start"]) > float(v["max"]):
            out.append("初始士气（%s）大于上限（%s）——游戏会被夹到上限。"
                       % (fmt_number(v["start"]), fmt_number(v["max"])))
        tiers = [float(v["high_tier"]), float(v["mid_tier"]),
                 float(v["vuln_tier"]), float(v["low_tier"])]
        names = ["高档", "中档", "易伤", "掉血"]
        for i in range(3):
            if tiers[i] < tiers[i + 1]:
                out.append("%s阈值（%s）小于下面的%s阈值（%s）——档位顺序反了。"
                           % (names[i], fmt_number(tiers[i]),
                              names[i + 1], fmt_number(tiers[i + 1])))
        if float(v["hp_floor"]) > float(v["max"]):
            out.append("掉血下限（%s）大于士气上限（%s）——单位会一直掉到很高的血。"
                       % (fmt_number(v["hp_floor"]), fmt_number(v["max"])))
        if float(v["damage_reduction"]) > float(v["damage_reduction_cap"]):
            by_key = {f.key: f for f in buff.fields}
            out.append("士气免伤（%s）已经超过减伤封顶（%s）——封顶会让它按上限算。"
                       % (display_value(by_key["damage_reduction"], v["damage_reduction"]),
                          display_value(by_key["damage_reduction_cap"],
                                        v["damage_reduction_cap"])))
        return out

    def summary(self, buff: Buff) -> str:
        """列表里那行短说明（士气：`90 / 100`；科技：`二本 · 3 条效果`）。"""
        if buff.id == "morale":
            v = self.values(buff)
            return "%s / %s" % (fmt_number(v["start"]), fmt_number(v["max"]))
        if buff.id.startswith("tech:"):
            return self._tech_summary(buff)
        return ""

    def preview(self, buff: Buff) -> str:
        """悬停浮窗里会显示的说明（与 `view/hud.gd._buffs_for` 同一套文案口径）。"""
        if buff.id.startswith("tech:"):
            return self._tech_preview(buff)
        if buff.id != "morale":
            return buff.intro
        v = self.values(buff)
        pct = lambda key: int(round(float(v[key]) * 100.0))
        return (
            "示例（开局）：当前 %s / %s\n"
            "≥%s：快速回血，受到伤害 -%d%%\n"
            "≥%s：缓慢回血\n"
            "≤%s：受到伤害 +%d%%\n"
            "≤%s：缓慢失去生命（0 时加快）"
        ) % (
            fmt_number(v["start"]), fmt_number(v["max"]),
            fmt_number(v["high_tier"]), pct("damage_reduction"),
            fmt_number(v["mid_tier"]),
            fmt_number(v["vuln_tier"]), pct("vulnerability"),
            fmt_number(v["low_tier"]),
        )

    # ------------------------------------------------------------------
    # 科技的提示 / 摘要 / 预览
    # ------------------------------------------------------------------
    def _tech_table_ids(self) -> Dict[str, int]:
        """全池子的 `id → 它出现在几张表里`（查重复 + 查槽位引用的 id 存不存在）。"""
        seen: Dict[str, int] = {}
        for _table, path, _label in self.tech_tables():
            for entry in self.tech_entries(path):
                tid = str(entry.get("id", ""))
                if tid:
                    seen[tid] = seen.get(tid, 0) + 1
        return seen

    def _tech_warnings(self, buff: Buff) -> List[str]:
        out: List[str] = []
        if buff.id == "tech:global":
            return out
        if buff.id.startswith("tech:slots:"):
            known = self._tech_table_ids()
            v = self.values(buff)
            used: Dict[str, int] = {}
            for key, tid in v.items():
                tid = str(tid or "").strip()
                if not tid:
                    continue                 # 空位是合法的
                if tid not in known:
                    out.append("%s 填的 `%s` 在任何科技表里都找不到 —— 游戏会把这一格当空位。"
                               % (key, tid))
                used[tid] = used.get(tid, 0) + 1
            for tid, n in used.items():
                if n > 1:
                    out.append("`%s` 在这张科技页里出现了 %d 次 —— 同一个科技重复摆放。" % (tid, n))
            return out
        # 单条科技
        v = self.values(buff)
        tid = str(v.get("id", "") or "")
        tier = int(v.get("tier", 0) or 0)
        if tier < 1 or tier > 3:
            out.append("阶填了 %d —— 科技页只有 3 行（一/二/三本）。" % tier)
        elif buff.id.startswith("tech:list:") or buff.id.startswith("tech:clan_list:"):
            # 列表下标 → 它在 3×3 里的行（列优先：行 = index % 3）
            try:
                index = int(buff.id.rsplit(":", 1)[1])
            except (ValueError, IndexError):
                index = -1
            if index >= 0 and index % 3 + 1 != tier:
                out.append("这一条在第 %d 位，但填的是 %d 阶 —— 科技页是**列优先**摆的，"
                           "第 %d 位会显示在第 %d 行（行 = 阶）。两者不一致时界面上看到的阶"
                           "和规则里的阶会打架。"
                           % (index + 1, tier, index + 1, index % 3 + 1))
        unknown = [f.key for f in buff.fields
                   if f.group == "效果" and f.key not in TECH_EFFECT_BY_KEY]
        for key in unknown:
            out.append("效果键 `%s` 不在注册表里 —— 游戏会静默忽略它（除非你在游戏侧真的读了它）。"
                       % key)
        if not unknown and not any(f.group == "效果" for f in buff.fields):
            out.append("这条科技一条效果都没有（启用了也不会改变任何东西）。")
        if tid and self._tech_table_ids().get(tid, 0) > 1:
            out.append("id `%s` 在两张表里都出现过 —— config.gd 会保留**先读到**的那一条。" % tid)
        return out

    def _tech_summary(self, buff: Buff) -> str:
        if buff.id == "tech:global":
            try:
                v = self.values(buff)
                return "上限 %s 条 · 金耗 %s" % (
                    fmt_number(v.get("max_active", "")),
                    " / ".join(fmt_number(v[k]) for k in v if k.startswith("gold_tier_")))
            except ModelError:
                return ""
        if buff.id.startswith("tech:slots:"):
            v = self.values(buff)
            n = sum(1 for x in v.values() if str(x or "").strip())
            return "9 格 · 放了 %d 条" % n
        try:
            v = self.values(buff)
        except ModelError:
            return ""
        n_eff = sum(1 for f in buff.fields if f.group == "效果")
        tier = v.get("tier", 0)
        tier_name = {1: "一本", 2: "二本", 3: "三本"}.get(int(tier or 0), "%s 阶" % tier)
        return "%s · %d 条效果 · %s 金/秒" % (
            tier_name, n_eff,
            fmt_number(self.doc.value(["tech", "gold_per_sec_by_tier",
                                       max(0, min(2, int(tier or 1) - 1))], "?")))

    def _tech_preview(self, buff: Buff) -> str:
        """科技页的「悬停浮窗预览」= 这一格在游戏里长什么样。"""
        if buff.id == "tech:global":
            return buff.intro
        if buff.id.startswith("tech:slots:"):
            try:
                v = self.values(buff)
            except ModelError:
                return buff.intro
            rows: List[str] = []
            for i, key in enumerate(sorted(v, key=lambda k: int(k.split("_")[-1]))):
                tid = str(v[key] or "").strip()
                if not tid:
                    rows.append("第 %d 格：空位（灰框，不可点）" % (i + 1))
                    continue
                entry = self.doc.get(list(buff.path) + [])  # noqa: F841 - 只为可读性
                name = self._tech_name(tid)
                rows.append("第 %d 格：%s（%s）" % (i + 1, name or tid, tid))
            return "\n".join(rows) if rows else buff.intro
        try:
            v = self.values(buff)
        except ModelError:
            return buff.intro
        name = str(v.get("name", "") or "")
        line = str(v.get("line", "") or "")
        desc = str(v.get("desc", "") or "")
        tier = int(v.get("tier", 0) or 0)
        gold = self.doc.value(["tech", "gold_per_sec_by_tier",
                               max(0, min(2, tier - 1))], 0.0) if tier else 0.0
        head = "第 %d 行（%d 本）· %s 金/秒" % (tier, tier, fmt_number(gold))
        box = "┌─────────────┐\n│ %s\n│ %s\n└─────────────┘" % (
            _pad_cjk(name, 11), _pad_cjk(line, 11))
        eff: List[str] = []
        for f in buff.fields:
            if f.group != "效果":
                continue
            meta = TECH_EFFECT_BY_KEY.get(f.key)
            eff.append("· %s %s" % (display_value(f, v[f.key]),
                                    ("（%s）" % meta.label) if meta else ("（%s）" % f.key)))
        parts = [head, box]
        if desc:
            parts.append("悬停：" + desc)
        if eff:
            parts.append("效果：\n" + "\n".join(eff))
        return "\n".join(parts)

    def _tech_name(self, tech_id: str) -> str:
        for _table, path, _label in self.tech_tables():
            for entry in self.tech_entries(path):
                if str(entry.get("id", "")) == tech_id:
                    return str(entry.get("name", tech_id))
        return ""


def _pad_cjk(text: str, width: int) -> str:
    """把一段文字压/补到「显示宽度」≈ width（中文按 2 算），给 ASCII 预览框对齐用。"""
    s = str(text)
    w = sum(2 if ord(ch) > 0x2E80 else 1 for ch in s)
    if w > width * 2:
        # 截断（按显示宽度）
        acc, out = 0, []
        for ch in s:
            cw = 2 if ord(ch) > 0x2E80 else 1
            if acc + cw > width * 2 - 1:
                break
            out.append(ch)
            acc += cw
        return "".join(out) + "…"
    return s + " " * max(0, width * 2 - w)
