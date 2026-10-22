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
GROUP_ORDER: Tuple[str, ...] = ("基础", "阈值", "生命", "伤害", "区划", "战果")


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
    """config 里的值 → 输入框里显示的文字（percent 会 ×100 并加 `%`）。"""
    if value is None:
        return ""
    if field.kind == "percent":
        return fmt_number(float(value) * 100.0) + "%"
    return fmt_number(value)


def parse_value(field: Field, text: str) -> Tuple[Any, str]:
    """输入框文字 → （写进 config 的值, 夹取提示）。

    · 不合法（空 / 不是数字）→ 抛 `ValueError`，调用方**不要**改数据；
    · 超出 lo/hi → 夹到边界，并在第二个返回值里说明一句；
    · percent：输入按**百分数**理解（`50` / `50%` 都是 0.5；`12.5` 是 0.125）。
    """
    s = str(text).strip()
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
        return BUFFS

    def buff(self, buff_id: str) -> Buff:
        for b in BUFFS:
            if b.id == buff_id:
                return b
        raise ModelError("没有这条 buff：%s" % buff_id)

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
        """列表里那行短说明（士气：`90 / 100`）。"""
        if buff.id == "morale":
            v = self.values(buff)
            return "%s / %s" % (fmt_number(v["start"]), fmt_number(v["max"]))
        return ""

    def preview(self, buff: Buff) -> str:
        """悬停浮窗里会显示的说明（与 `view/hud.gd._buffs_for` 同一套文案口径）。"""
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
