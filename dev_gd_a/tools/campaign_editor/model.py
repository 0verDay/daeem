"""model.py —— 战役 / 关卡的**数据层**（无界面，可无头测试）。

职责边界（与另两个编辑器同一套规矩）：

    levelfile.py   「战役 / 关卡 JSON 怎么读写、怎么往返」——只管文件
    model.py       「一关到底是什么」——只管语义与校验（★ 本文件**不许** import tkinter）
    app.py         tkinter 界面

★★ 数据契约是 **dev_plan_7 第二节 + `daeem/logic/level.gd` + `daeem/logic/campaign.gd`**。
   本文件是那份契约的 Python 侧镜像：字段名、默认值、覆盖规则、以及那 16 条校验的
   `code` 都逐个对齐，改任何一处都要同时改 `test_model.py` 与逻辑层 ——
   两边漂开的表现是「编辑器说没问题、游戏一进关就判负」，最难查的一类。

★ 为什么校验放在**数据层**而不是界面层（与 `logic/level.gd` 同一条理由）：
  校验逻辑只有一份 —— 编辑器导出前跑它，测试也跑它，界面只是把它显示出来。

★ **不实现 `estimate()`**：用户明确「不做估算提示」（dev_plan_7 9.2 第 1 项）。

⚠️ 字典 / 对象里的**坐标**统一用 `(x, y)` 元组，`None` = 「没写」。
   「没写」与「写了 (0, 0)」是两件事：前者用地图的，后者就是 (0,0) —— 逻辑层用
   `Vector2i(-1, -1)` 表达前者，这里用 `None`，含义相同（见 `logic/level.gd` 的 `_read_point`）。
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

# ======================================================================
# 常量（与 logic/level.gd 逐字一致）
# ======================================================================

#: 模式。
MODE_SOLO = "solo"
MODE_COOP = "coop"

#: `factions[].ai` 的取值。
AI_NONE = "none"
AI_FACTION = "faction"
AI_GENERAL = "general"

#: `attack_target.kind` 的取值（不写这个键 = `None` = 「打离自己最近的敌方区划」）。
TARGET_ZONE = "zone"
TARGET_POINT = "point"
TARGET_BUILDING = "building"
TARGET_BASE = "base"

#: 目标种类：第一版**只有**这一种。
OBJ_HOLD_ZONE = "hold_zone"
## ★★ 「攻占指定区划」——一关两个可玩阵营各打各的时，进攻方用这一条
## （判胜是**立刻**的：归属翻成自己那一帧就赢）。与 `logic/level.gd` 同名同义。
OBJ_CAPTURE_ZONE = "capture_zone"

#: 额外失败条件：第一批**只有**这一种。
FAIL_ZONE_LOST = "zone_lost"

#: 校验级别。
SEV_BLOCK = "block"
SEV_WARN = "warn"

#: 可选的 `attack_target.kind`（界面下拉用；`None` = 不写 = 缺省挑选）。
TARGET_KINDS: Tuple[str, ...] = (TARGET_ZONE, TARGET_POINT, TARGET_BUILDING, TARGET_BASE)

#: `ai` 的三种取值（界面下拉用）。
AI_KINDS: Tuple[str, ...] = (AI_NONE, AI_FACTION, AI_GENERAL)

#: `mode` 的两种取值。
MODES: Tuple[str, ...] = (MODE_SOLO, MODE_COOP)

#: 战役根目录（相对工程目录）—— 与 `logic/campaign.gd` 的 CAMPAIGNS_DIR 同一条约定。
CAMPAIGNS_SUBDIR = ("data", "campaigns")

#: 地图根目录 —— 与 `logic/map_library.gd` 的 MAPS_DIR 同一条约定。
MAPS_SUBDIR = ("data", "maps")

#: 每个地图目录里首选的文件名（其次 `<目录名>.json`，最后任一 `*.json`）。
MAP_FILE_NAME = "map.json"

#: 每个战役目录里首选的文件名（同上，见 `logic/campaign_library.gd` 第 2 条）。
CAMPAIGN_FILE_NAME = "campaign.json"

#: 关卡文件的默认子目录。
LEVELS_SUBDIR = "levels"

#: 配置 JSON（**只读**：兵种 / 将领 / 建筑 / 区划种类 / AI 默认参数 / 配色）。
CONFIG_SUBDIR = ("data", "config.json")

#: 人写的 `_comment` 字段：认它、原样带回去 —— 它是**给人看的文档**，
#: 编辑器往返一次就把它抹掉的话，第一份关卡文件的注释就白写了。
COMMENT_KEY = "_comment"

#: `start_units[].escort_of`：**这个兵属于第几位将领**（1 起，与 `general_index` 同一套编号）。
#:
#: ★★ 为什么要有它（本轮返工的核心）：开局附属兵改成**在摆放页一个一个摆出来**，
#:   所以要有一个字段把「这个兵」和「它的将领」绑起来 —— 运行时靠它填
#:   `unit.leader_id`，于是它真的算那位将领的**部队**（点一个兵选中整队、
#:   将领濒死时它去集结、将领死了它算「部队没了」）。
#:
#: ⚠️ 缺省（不写）= **不是附属兵**，就是一个普通摆放单位 —— 与今天的行为一样。
#: ⚠️ **不再有全局缺省**：`config.json` 的 `unit.general.escort` 已经删掉，
#:    没摆就是 0 个兵（将领光杆）。这一条是用户明确要的「所见即所得」。
ESCORT_OF_KEY = "escort_of"

#: 运行时开局会为每一方自动生成几位将领（`logic/world.gd` 的 `create_generals`）。
#: ⚠️ 只在「这一方**没有**摆附属部队」时才自动生成 —— 摆了就整方交给作者（见 README）。
#:    ⚠️ 目前**只是文档**（没有代码读它）：真要按它做检查时，记得与运行时的
#:    `for i in 3` 一起改。
GENERAL_SLOTS = 3


class ModelError(Exception):
    """数据层说不行的原因（界面直接显示这句话，测试也断言它）。"""


# ======================================================================
# 关卡：一行行的小结构
# ======================================================================

class FactionEntry:
    """关卡 `factions[]` 的一行 —— 「这一方在这一关里怎么打」。

    字段与 `logic/level.gd` 的 `_read_level_factions()` **逐字段对齐**：
    `id / ai / base / color / resource_mult / start_food / start_gold /
     attack_target / faction_ai / general_ai`。

    ★ 多出来的 `name` / `color` 是 `merge_over_map()` 会读的两个字段
      （关卡新点名的阵营要靠它出现在阵营表里），不是运行时 AI 参数。
    """

    __slots__ = ("fid", "ai", "base", "resource_mult", "start_food", "start_gold",
                 "attack_target", "faction_ai", "general_ai", "name", "color",
                 "declared", "attack_target_raw")

    def __init__(self, fid: str) -> None:
        self.fid = fid
        self.ai = AI_NONE
        self.base: Optional[Tuple[int, int]] = None
        self.resource_mult = 1.0
        self.start_food = 0.0
        self.start_gold = 0.0
        #: 形状 {"kind": ..., ...}；None = 没写（运行时退回「打最近的敌方区划」）。
        self.attack_target: Optional[dict] = None
        #: `attack_target` 在源 JSON 里的**原样值**（`True` 表示「这个键出现过」）。
        #: ★ 为什么留着它：`attack_target: "4"` 这种**形状错**（不是对象）是校验第 10 条
        #:   要拦的一档，而规范化之后它就变成一个「kind 空」的字典、与「种类不认识」分不开了。
        #:   留着原值，`attack_target_shape` 才报得准。
        self.attack_target_raw: Any = None
        #: 覆盖 `config.ai.faction` / `config.ai.general` 的那几个键；None = 全部继承。
        self.faction_ai: Optional[dict] = None
        self.general_ai: Optional[dict] = None
        self.name = ""
        self.color = ""
        #: 「这一方在**这一关的 JSON 里**被点名了」—— 与「只是地图上划过」是两件事：
        #: 点名的阵营一律要求大本营（校验第 4 条），地图划过的不用。
        self.declared = True

    def base_label(self) -> str:
        return "—" if self.base is None else "%d,%d" % self.base

    def target_label(self) -> str:
        return target_label(self.attack_target)

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<FactionEntry %s ai=%s base=%r>" % (self.fid, self.ai, self.base)


class UnitEntry:
    """`start_units[]` 的一行（**追加**在地图 `units` 之后）。

    字段与 `logic/level.gd` 的 `_read_start_units()` 逐字段对齐。
    """

    __slots__ = ("faction", "kind", "general_index", "unit_type", "x", "y",
                 "ai", "zone", "hold", "name", "escort_of", "declared")

    def __init__(self, faction: str = "", kind: str = "", x: int = 0, y: int = 0) -> None:
        self.faction = faction
        self.kind = kind
        #: 将领序号（1 起）；`None` = JSON 里没写。
        #: ⚠️ 落进模型时补成 1（与逻辑层 `ConfigRes.general_index_of(kind) + 1` 同一条），
        #:   但**导出时**若它就是 1 且 JSON 里本来没写，就不写出去（免得凭空多一个键）。
        self.general_index: Optional[int] = None
        self.unit_type = ""
        self.x = x
        self.y = y
        self.ai = AI_NONE
        self.zone = -1
        self.hold = False
        self.name = ""
        #: ★★ 这个兵**属于第几位将领**（1 起，见 `ESCORT_OF_KEY`）；`-1` = 不是附属兵。
        #:   运行时靠它填 `unit.leader_id` —— 于是它在游戏里真的是那位将领的**部队**
        #:   （点一个兵选中整队 / 将领濒死时它去集结 / 将领死了它算「部队没了」）。
        self.escort_of = -1
        #: 源 JSON 里**出现过**的键（`{"general_index": 1}` 与「没写」是两件事：
        #: 前者要原样写回去，后者不该被凭空补一个键）。
        #: ★ 这是 `_declared` 那一套在**每一项**上的落点 —— 关卡层的 `_declared` 只管
        #:   顶层键，管不到 `start_units[]` 里面，所以每个单位自己记一份。
        self.declared: set = set()

    def point(self) -> Tuple[int, int]:
        return (int(self.x), int(self.y))

    def has(self, key: str) -> bool:
        """源 JSON 里写过这个键没有（决定导出时要不要写出去）。"""
        return key in self.declared

    def is_general(self) -> bool:
        return str(self.kind).split("_")[0] == "general" or self.kind.startswith("general_")

    def is_escort(self) -> bool:
        """这个兵是不是「附属部队」（挂了归属将领）。"""
        return int(self.escort_of) >= 1

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<UnitEntry %s %s (%d,%d)>" % (self.faction, self.kind, self.x, self.y)


class BuildingEntry:
    """`start_buildings[]` 的一行（**追加**在地图 `buildings` 之后，与它同构）。"""

    __slots__ = ("type", "x", "y", "owner")

    def __init__(self, type_id: str = "", x: int = 0, y: int = 0, owner: str = "") -> None:
        self.type = type_id
        self.x = x
        self.y = y
        self.owner = owner

    def point(self) -> Tuple[int, int]:
        return (int(self.x), int(self.y))

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<BuildingEntry %s %s (%d,%d)>" % (self.type, self.owner, self.x, self.y)


class Issue:
    """一条校验结果。

    `code` 与 `logic/level.gd` / `logic/campaign.gd` 的**同一套**（`map_missing_field`、
    `objective_unowned`…）—— 界面、测试、运行时三边靠它对暗号。

    `where` 是给人看的定位串，形如 `战役 demo / 关卡 01_beachhead`；
    细节（哪一方 / 哪一格）写进 `msg`。
    """

    __slots__ = ("sev", "code", "where", "msg")

    def __init__(self, sev: str, code: str, where: str = "", msg: str = "") -> None:
        self.sev = sev
        self.code = code
        self.where = where
        self.msg = msg

    @property
    def blocked(self) -> bool:
        return self.sev == SEV_BLOCK

    def label(self) -> str:
        """界面上那一行的「通过 / 警告 / 拦截」文字。"""
        return "拦截" if self.sev == SEV_BLOCK else "警告"

    def line(self) -> str:
        return "%s　[%s]　%s　%s" % (self.label(), self.code, self.where, self.msg)

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<Issue %s %s %s>" % (self.sev, self.code, self.where)


# ======================================================================
# LevelModel
# ======================================================================

class LevelModel:
    """一关 = 一张地图 + 一层覆盖。

    ★★ 覆盖规则**不在本文件**实现（那是 `logic/level.gd` 的 `merge_over_map()`，
      运行时唯一的一处）；本文件只负责「把两边的数据都读进来、能比对、能写回去」。
    """

    __slots__ = ("level_id", "name", "mode", "map_id", "players", "factions", "allies",
                 "allies_declared", "zone_owners", "start_units", "start_buildings",
                 "objectives", "fail_conditions", "briefing", "preserved",
                 "file", "briefing_declared", "_declared", "campaign_id",
                 "campaign_factions", "campaign_playable")

    def __init__(self, level_id: str = "", map_id: str = "") -> None:
        self.level_id = level_id
        self.name = level_id
        self.mode = MODE_SOLO
        self.map_id = map_id
        #: 每项 {"faction": str, "base": Optional[Tuple[int,int]]}；**顺序 = 席位顺序**。
        self.players: List[dict] = []
        #: 参展阵营（`FactionEntry`）。
        self.factions: List[FactionEntry] = []
        #: 盟友关系（两两一对）；只有 `allies_declared` 为真时才覆盖地图的。
        self.allies: List[List[str]] = []
        self.allies_declared = False
        #: 开局的区划归属覆盖：区划 id → 阵营 id（**空串 = 显式清空**，见逻辑层说明）。
        self.zone_owners: Dict[int, str] = {}
        self.start_units: List[UnitEntry] = []
        self.start_buildings: List[BuildingEntry] = []
        self.objectives: List[dict] = []
        self.fail_conditions: List[dict] = []
        self.briefing: List[str] = []
        #: 关卡 JSON 里**本编辑器不认识**的字段，原样带回去（导入 → 导出不许掉字段）。
        self.preserved: Dict[str, Any] = {}
        #: 关卡文件（相对战役目录），例如 `levels/01_beachhead.json`。
        self.file = ""
        #: 这几个键在源 JSON 里出现过没有 —— 决定导出时写不写（见 `to_dict`）。
        self.briefing_declared = False
        self._declared: Set[str] = set()
        #: 只用来定位（不参与导出）：所属战役 id / 该战役 `factions[]` 的 id 列表。
        self.campaign_id = ""
        self.campaign_factions: List[str] = []
        #: 该战役里 `playable: true` 的那些 id（校验第 7 条与「玩家能选谁」下拉用）。
        self.campaign_playable: List[str] = []

    # ---- 便捷读 ----

    def seats(self) -> List[str]:
        """玩家席位（阵营 id，按席位顺序）。"""
        return [str(p.get("faction", "")) for p in self.players]

    def objective(self) -> Optional[dict]:
        """第一项目标（没有 → None）。第一版只有一项，所以「第一项」就是「那项」。"""
        return self.objectives[0] if self.objectives else None

    def objective_zone(self) -> int:
        o = self.objective()
        return int(o.get("zone", -1)) if o else -1

    def objective_hold_sec(self) -> float:
        o = self.objective()
        return float(o.get("hold_sec", 0.0)) if o else 0.0

    def faction(self, fid: str) -> Optional[FactionEntry]:
        for e in self.factions:
            if e.fid == fid:
                return e
        return None

    def ensure_faction(self, fid: str) -> FactionEntry:
        """取这一方的条目；没有就**新建**一行并返回（界面「加一方」走它）。"""
        got = self.faction(fid)
        if got is not None:
            return got
        entry = FactionEntry(fid)
        self.factions.append(entry)
        self._declared.add("factions")
        return entry

    def remove_faction(self, fid: str) -> None:
        self.factions = [e for e in self.factions if e.fid != fid]

    def player_base(self, index: int) -> Optional[Tuple[int, int]]:
        if 0 <= index < len(self.players):
            return self.players[index].get("base")
        return None

    def set_player_base(self, index: int, point: Optional[Tuple[int, int]]) -> None:
        while len(self.players) <= index:
            self.players.append({"faction": "", "base": None})
        self.players[index]["base"] = point

    def add_player(self, faction: str = "", base: Optional[Tuple[int, int]] = None) -> dict:
        item = {"faction": faction, "base": base}
        self.players.append(item)
        self._declared.add("players")
        return item

    def remove_player(self, index: int) -> None:
        if 0 <= index < len(self.players):
            del self.players[index]

    def set_zone_owner(self, zid: int, owner: str) -> None:
        """写某区的开局归属；`owner == ""` = **显式清空**（与「没提这一区」是两件事）。"""
        self.zone_owners[int(zid)] = str(owner)
        self._declared.add("zones")

    def clear_zone_owner(self, zid: int) -> None:
        """撤掉这一区的覆盖（回到地图自带的归属）。"""
        self.zone_owners.pop(int(zid), None)

    def zone_owner(self, zid: int) -> Optional[str]:
        """关卡写的归属（没写 → None = 用地图的）。"""
        return self.zone_owners.get(int(zid))

    def is_playable(self, fid: str) -> bool:
        """这一方在**所属战役**里是不是可玩的（关卡自己不带这个标记，见 2.2）。"""
        return str(fid) in self.playable_ids_for_level()

    def playable_ids_for_level(self) -> List[str]:
        """本关能选来玩的阵营 = **战役可玩** ∩ 本关在场（界面下拉与校验第 7 条用）。

        ⚠️ 是「战役可玩」而不是「战役全部阵营」：一个只在战役里登记过、
          `playable: false` 的敌方阵营不该出现在「玩家能选谁」里。
        """
        return [f for f in self.campaign_playable if f in self.present_ids()]

    def present_ids(self) -> List[str]:
        """本关**在场**的阵营（席位 + 关卡 factions + 战役 factions，顺序稳定、去重）。

        ★ 与 `logic/level.gd` 的 `present_ids()` 对齐：那边再加地图的 `factions_meta`
          （这里没有地图对象，所以由校验层把地图那一份并进来）。
        """
        out: List[str] = []
        for f in self.seats():
            if f and f not in out:
                out.append(f)
        for e in self.factions:
            if e.fid and e.fid not in out:
                out.append(e.fid)
        for f in self.campaign_factions:
            if f and f not in out:
                out.append(f)
        return out

    def summary(self) -> str:
        """`"单人 · 守住 c1 90 秒"` 这种一行摘要（关卡列表上那一行）。"""
        parts = ["双人合作" if self.mode == MODE_COOP else "单人"]
        o = self.objective()
        if not o:
            parts.append("（没有目标）")
        else:
            zid = int(o.get("zone", -1))
            sec = float(o.get("hold_sec", 0.0))
            parts.append("守住 %s %s 秒" % (zone_label(zid), fmt_sec(sec)))
        return " · ".join(parts)

    # ---- 写盘用的字典 ----

    def to_dict(self) -> dict:
        """→ 关卡 JSON 的字典（**省略一切等于默认值的字段**，见 dev_plan_7 2.3）。

        ★ 写不写某个键的判据是「**源 JSON 里出现过没有**」（`_declared`）+「现有没有值」：
          源里写了空 `fail_conditions: []` 就继续写空数组（不凭空多也不凭空少），
          源里没写、我们也没改，就不写 —— 这样往返是稳定的。
        """
        out = _ordered_from_preserved(self.preserved)
        out["name"] = self.name or self.level_id
        out["mode"] = self.mode if self.mode in MODES else MODE_SOLO
        # ★ `map` 只在「源里写过」或「真的有值」时才写：解析层把空 map 当作「没写」
        #   （`map_missing_field`），若在这里补一个空串，往返就会多出一个键。
        if self.map_id or "map" in self._declared:
            out["map"] = self.map_id

        players = []
        for p in self.players:
            item: Dict[str, Any] = {"faction": str(p.get("faction", ""))}
            base = p.get("base")
            # ★ `base` 没写就**不写这个键** —— 与 `{"base": [-1,-1]}` 是两件事
            #   （前者用地图的，后者是「就在 (0,0)」）。
            if base is not None:
                item["base"] = [int(base[0]), int(base[1])]
            players.append(item)
        if players or "players" in self._declared:
            out["players"] = players

        entries = []
        for e in self.factions:
            entries.append(_faction_to_dict(e))
        if entries or "factions" in self._declared:
            out["factions"] = entries

        # ★ `allies` 用「声明过没有」而不是「是不是空的」：写了 `[]` = 明确谁都不是盟友，
        #   与「一个字都没写」（用地图的）是两件事（`logic/level.gd` 的 allies_declared）。
        if self.allies_declared:
            out["allies"] = [[str(a), str(b)] for a, b in self.allies]

        if self.zone_owners or "zones" in self._declared:
            out["zones"] = [{"id": int(z), "owner": str(self.zone_owners[z])}
                            for z in sorted(self.zone_owners)]

        if self.start_units or "start_units" in self._declared:
            out["start_units"] = [_unit_to_dict(u) for u in ordered_start_units(self)]
        if self.start_buildings or "start_buildings" in self._declared:
            out["start_buildings"] = [_building_to_dict(b) for b in self.start_buildings]

        out["objectives"] = [_objective_to_dict(o) for o in self.objectives]
        if self.fail_conditions or "fail_conditions" in self._declared:
            out["fail_conditions"] = [_fail_to_dict(f) for f in self.fail_conditions]
        if self.briefing or self.briefing_declared:
            out["briefing"] = list(self.briefing)
        return out

    def mark_declared(self, *keys: str) -> None:
        for k in keys:
            self._declared.add(k)

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<LevelModel %s %s map=%s>" % (self.level_id, self.mode, self.map_id)


# ======================================================================
# CampaignModel
# ======================================================================

class CampaignModel:
    """一个战役：`campaign.json` + 它下面那一串关卡（**顺序 = 关卡顺序**）。"""

    __slots__ = ("campaign_id", "dir_path", "name", "description", "default_mode",
                 "factions", "levels", "unlock", "preserved", "campaign_factions")

    def __init__(self, campaign_id: str = "", dir_path: Any = None) -> None:
        self.campaign_id = campaign_id
        #: 战役目录（`Path`）。保存时按它写 `campaign.json` 与 `levels/*.json`。
        self.dir_path = Path(dir_path) if dir_path is not None else None
        self.name = campaign_id
        self.description = ""
        self.default_mode = MODE_SOLO
        #: 每项 {"id","name","color","playable"}。
        self.factions: List[dict] = []
        self.levels: List[LevelModel] = []
        self.unlock = "in_order"
        self.preserved: Dict[str, Any] = {}
        #: 阵营 id 列表的**快照**（给关卡的下拉与校验用；不参与导出，见 `sync_context`）。
        self.campaign_factions: List[str] = []

    # ---- 关卡管理 ----

    def level(self, level_id: str) -> Optional[LevelModel]:
        for lv in self.levels:
            if lv.level_id == level_id:
                return lv
        return None

    def index_of(self, level_id: str) -> int:
        for i, lv in enumerate(self.levels):
            if lv.level_id == level_id:
                return i
        return -1

    def new_level(self, level_id: str, map_id: str) -> LevelModel:
        """追加一关并返回它（id 撞车时自动加后缀，文件名同 id）。"""
        wanted = str(level_id).strip() or "level"
        unique = wanted
        n = 2
        while self.level(unique) is not None:
            unique = "%s_%d" % (wanted, n)
            n += 1
        lv = LevelModel(unique, map_id)
        lv.name = unique
        lv.mode = self.default_mode if self.default_mode in MODES else MODE_SOLO
        lv.campaign_id = self.campaign_id
        lv.file = "%s/%s.json" % (LEVELS_SUBDIR, unique)
        lv.mark_declared("name", "mode", "map", "players", "factions", "objectives",
                         "start_units", "start_buildings", "fail_conditions")
        self.levels.append(lv)
        self._sync_level_context(lv)
        return lv

    def remove_level(self, level_id: str) -> bool:
        i = self.index_of(level_id)
        if i < 0:
            return False
        del self.levels[i]
        return True

    def move_level(self, level_id: str, delta: int) -> bool:
        """上下箭头排顺序；越界就不动（返回 False）。"""
        i = self.index_of(level_id)
        if i < 0:
            return False
        j = i + int(delta)
        if j < 0 or j >= len(self.levels) or j == i:
            return False
        self.levels.insert(j, self.levels.pop(i))
        return True

    # ---- 便捷读 ----

    def playable_ids(self) -> List[str]:
        """可玩阵营（`campaign.json` 的 `playable: true`，按声明顺序）。"""
        return [str(e["id"]) for e in self.factions if bool(e.get("playable", False))]

    def faction_name(self, fid: str) -> str:
        for e in self.factions:
            if str(e.get("id", "")) == fid:
                return str(e.get("name", "")) or fid
        return fid

    def faction_color(self, fid: str) -> str:
        for e in self.factions:
            if str(e.get("id", "")) == fid:
                return str(e.get("color", ""))
        return ""

    def ensure_faction(self, fid: str, name: str = "", color: str = "") -> dict:
        for e in self.factions:
            if str(e.get("id", "")) == fid:
                return e
        item = {"id": fid, "name": name or fid, "color": color, "playable": False}
        self.factions.append(item)
        return item

    def remove_faction(self, fid: str) -> bool:
        for i, e in enumerate(self.factions):
            if str(e.get("id", "")) == fid:
                del self.factions[i]
                return True
        return False

    def _sync_level_context(self, lv: LevelModel) -> None:
        """把关卡用得着的「战役级」信息塞进它（校验第 7 条与界面下拉要用）。

        ⚠️ 这些不算关卡数据、不进 JSON，只是**上下文** —— 所以它们不参与往返断言。
        """
        lv.campaign_id = self.campaign_id
        lv.campaign_factions = [str(e.get("id", "")) for e in self.factions if e.get("id")]
        lv.campaign_playable = self.playable_ids()

    def sync_context(self) -> None:
        for lv in self.levels:
            self._sync_level_context(lv)

    # ---- 写盘用的字典 ----

    def to_dict(self) -> dict:
        out = _ordered_from_preserved(self.preserved)
        out["name"] = self.name or self.campaign_id
        out["description"] = self.description
        out["default_mode"] = self.default_mode if self.default_mode in MODES else MODE_SOLO
        out["factions"] = [{"id": str(e.get("id", "")),
                            "name": str(e.get("name", "")) or str(e.get("id", "")),
                            "color": str(e.get("color", "")),
                            "playable": bool(e.get("playable", False))}
                           for e in self.factions if str(e.get("id", ""))]
        out["levels"] = [{"id": lv.level_id,
                          "file": level_file_of(lv),
                          "name": lv.name} for lv in self.levels]
        out["unlock"] = self.unlock or "in_order"
        return out

    def summary(self) -> str:
        return "%s（%d 关，默认%s）" % (self.name, len(self.levels),
                                      "双人合作" if self.default_mode == MODE_COOP else "单人")

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<CampaignModel %s %d levels>" % (self.campaign_id, len(self.levels))


def level_file_of(lv: LevelModel) -> str:
    """关卡在战役目录里的相对路径（**保持源文件写的那一个**，别自作主张改名）。"""
    if lv.file:
        return lv.file
    return "%s/%s.json" % (LEVELS_SUBDIR, lv.level_id)


# ======================================================================
# MapInfo / ConfigInfo：只读的快照
# ======================================================================

class MapInfo:
    """`data/maps/<id>/map.json` 读进来的一张图。

    ★ 只取「编辑关卡要用到」的那几样：地形 / 存在 / 区划（中心、产能、归属）/
      阵营表 / 大本营 / 盟友。**地图的编辑仍然归 map_editor** —— 这里是只读快照。
    """

    __slots__ = ("map_id", "path", "name", "cols", "rows", "hidden", "placeholder",
                 "factions", "zone_ids", "zone_names", "zone_centers", "zone_production",
                 "zone_owners", "terrain", "exists", "walkable", "allies", "faction_bases",
                 "raw", "zone_grid", "builtin_factions")

    def __init__(self, map_id: str, path: str = "") -> None:
        self.map_id = map_id
        self.path = path
        self.name = map_id
        self.cols = 0
        self.rows = 0
        #: ★ 两个标记都**照实带上**（不跳过 hidden / placeholder）：
        #:   编辑器的地图下拉要能列出它们（校验也可能引用到它们），
        #:   只是给个文字提示「这张图不进自由对战的选择条」。
        self.hidden = False
        self.placeholder = False
        self.factions: List[dict] = []
        self.zone_ids: List[int] = []
        self.zone_names: Dict[int, str] = {}
        self.zone_centers: Dict[int, Tuple[int, int]] = {}
        self.zone_production: Dict[int, dict] = {}
        self.zone_owners: Dict[int, str] = {}
        #: {(x, y): 地形字符}，字符与地图 `layout` 同一套（'.' / '^' / '#'）。
        self.terrain: Dict[Tuple[int, int], str] = {}
        #: 存在的格子（地图外 = 不在里面）。
        self.exists: Set[Tuple[int, int]] = set()
        #: 存在 **且** 不是山地的格子（校验「可通行」用）。
        self.walkable: Set[Tuple[int, int]] = set()
        #: 地图自带的两两盟友。
        self.allies: List[List[str]] = []
        self.faction_bases: Dict[str, Tuple[int, int]] = {}
        self.raw: dict = {}
        #: 地块 → 区划 id 的**逐格**网格（地图 `zones`）。它很大，所以单列一行说明：
        #: 只有 `zone_of()` / `has_zone()` 与背景绘制读它，别的地方用上面那几张小表。
        self.zone_grid: Dict[Tuple[int, int], int] = {}
        #: ★★ 引擎**内置**的阵营 id（= `config.json` 的 `colors.faction` 键）。
        #:   由 `list_maps()` 一次性填上（`load_map()` 单独调时是空集）。
        #:   用途只有一处：校验「自定义阵营有没有配色」——
        #:   内置 id 不写 color 也有颜色，而自定义 id 不写会退到**品红**（整场一片紫）。
        self.builtin_factions: set = set()

    # ---- 便捷读 ----

    def zone_name(self, zid: int) -> str:
        name = str(self.zone_names.get(int(zid), "")).strip()
        return name or "c%d" % int(zid)

    def zone_label(self, zid: int) -> str:
        """区划的显示名：地图里有名字就用名字，否则 `c<id>`（与逻辑层 `_zone_label` 同一条）。

        ⚠️ 只给**一个**标签，不拼「名字（c3）」那种双写法：地图 `zone_list[].name` 是
          设计者给区划起的名字（样例地图里是 `b1` / `c1` 这种**已经带 c 前缀**的），
          再拼一个 `cNN` 就会出现「c1（c4）」这种自相矛盾的下拉项。
        """
        return self.zone_name(int(zid))

    def tile_exists(self, x: int, y: int) -> bool:
        return (int(x), int(y)) in self.exists

    def terrain_at(self, x: int, y: int) -> str:
        return self.terrain.get((int(x), int(y)), ".")

    def walkable_at(self, x: int, y: int) -> bool:
        return (int(x), int(y)) in self.walkable

    def zone_of(self, x: int, y: int) -> int:
        """这一格属于哪个区划（`zones` 网格）。"""
        return self.zone_grid.get((int(x), int(y)), -1)

    def has_zone(self, zid: int) -> bool:
        """区划存不存在：中心有它 **或** 地块网格里有它。

        ⚠️ 与 `logic/level.gd` 的 `_zone_exists()` 同一条口径：手写地图可能没给某个
          区划中心，而那个区划在地块网格里是实打实存在的。
        """
        zid = int(zid)
        if zid in self.zone_centers:
            return True
        return zid in self.zone_ids

    def faction_base(self, fid: str) -> Optional[Tuple[int, int]]:
        return self.faction_bases.get(str(fid))

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<MapInfo %s %dx%d zones=%d>" % (self.map_id, self.cols, self.rows,
                                                len(self.zone_ids))


class ConfigInfo:
    """`daeem/data/config.json` 的**只读**快照（兵种 / 将领 / 建筑 / 区划种类 / AI 默认值）。

    ★ 只读是硬约定：兵种与建筑数值归 unit_editor 管，本编辑器只拿来填下拉框。
    """

    __slots__ = ("unit_types", "unit_names", "general_types",
                 "general_names", "building_types", "zone_kinds", "ai_faction_cfg",
                 "ai_general_cfg", "colors", "raw")

    def __init__(self) -> None:
        self.unit_types: List[str] = []
        self.unit_names: Dict[str, str] = {}
        self.general_types: List[str] = []
        self.general_names: List[str] = []
        self.building_types: List[str] = []
        self.zone_kinds: List[str] = []
        #: `config.ai.faction` / `config.ai.general` —— 关卡「高级」区的**推荐值**。
        self.ai_faction_cfg: Dict[str, Any] = {}
        self.ai_general_cfg: Dict[str, Any] = {}
        self.colors: Dict[str, Any] = {}
        self.raw: dict = {}

    def unit_name(self, type_id: str) -> str:
        return str(self.unit_names.get(type_id, "")) or type_id

    def general_label(self, index: int) -> str:
        """`"将领 1（长枪兵）"` 这种写法（界面下拉用）。"""
        i = int(index) - 1
        kind = self.general_types[i] if 0 <= i < len(self.general_types) else ""
        name = self.general_names[i] if 0 <= i < len(self.general_names) else ""
        tail = name or (self.unit_name(kind) if kind else "")
        # ★ 序号从**1** 起：JSON 里的 `general_index` 就是这么写的（与逻辑层一致）。
        return "将领 %d%s" % (int(index), "（%s）" % tail if tail else "")

    def general_indices(self) -> List[int]:
        n = max(1, len(self.general_types) or 3)
        return list(range(1, n + 1))

    def faction_color(self, fid: str) -> str:
        """阵营配色：`colors.faction.<id>.main` → 兜底空串（界面自己挑一个）。"""
        table = self.colors.get("faction", {}) if isinstance(self.colors, dict) else {}
        if isinstance(table, dict):
            item = table.get(str(fid))
            if isinstance(item, dict):
                return str(item.get("main", ""))
        return ""

    def __repr__(self) -> str:                          # pragma: no cover - 调试用
        return "<ConfigInfo units=%d buildings=%d>" % (len(self.unit_types),
                                                       len(self.building_types))


# ======================================================================
# 读盘
# ======================================================================

def _read_json(path: Path) -> Any:
    """读一份 JSON（**宽容**：BOM 容忍、解析失败抛 `ModelError` 而不是静默返回空）。

    ⚠️ 用 `utf-8-sig` 读：Windows 记事本 / PowerShell 写出来的 UTF-8 常带 BOM，
      而 `json.loads` 见到 BOM 直接报「不是合法 JSON」（map_editor 的 mapfile.py 同款坑）。
    """
    try:
        text = Path(path).read_text(encoding="utf-8-sig")
    except FileNotFoundError as exc:
        raise ModelError("找不到文件：%s" % path) from exc
    except OSError as exc:
        raise ModelError("打不开文件：%s（%s）" % (path, exc)) from exc
    text = text.lstrip("\ufeff")
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ModelError("不是合法 JSON：%s（第 %d 行：%s）"
                         % (path, exc.lineno, exc.msg)) from exc


def _as_int(value: Any, fallback: int = -1) -> int:
    """宽容地取整数（JSON 里可能是字符串 / 浮点 / None / 布尔）。"""
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        try:
            return int(float(value.strip()))
        except ValueError:
            return fallback
    return fallback


def _as_float(value: Any, fallback: float = 0.0) -> float:
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value.strip())
        except ValueError:
            return fallback
    return fallback


def _as_str(value: Any, fallback: str = "") -> str:
    if isinstance(value, str):
        return value.strip()
    return fallback


def _as_point(value: Any) -> Optional[Tuple[int, int]]:
    """`[x, y]` → `(x, y)`；没写 / 格式不认识 → `None`（= 「没写」）。"""
    if isinstance(value, (list, tuple)) and len(value) >= 2:
        return (_as_int(value[0], 0), _as_int(value[1], 0))
    if isinstance(value, dict) and "x" in value and "y" in value:
        return (_as_int(value["x"], 0), _as_int(value["y"], 0))
    return None


def _as_dict(value: Any) -> Optional[dict]:
    """只认非空字典（`{}` = 「写了但什么都没有」→ 还是当没写，与逻辑层同款宽容）。"""
    if isinstance(value, dict) and value:
        return dict(value)
    return None


def _as_list(value: Any) -> List[Any]:
    return list(value) if isinstance(value, list) else []


def project_path(project_dir: Any, *parts: str) -> Path:
    """把「工程目录 + 相对片段」拼成路径（`project_dir` 允许是 str / Path）。"""
    return Path(project_dir).joinpath(*parts)


def load_config(project_dir: Any) -> ConfigInfo:
    """读 `daeem/data/config.json`（**只读**）。

    读不出来时**返回一份空的 `ConfigInfo`** 而不是抛错：配置坏了照样要能打开编辑器看关卡，
    只是下拉框里没有兵种可选（界面会把这件事说清楚）。
    """
    info = ConfigInfo()
    path = project_path(project_dir, *CONFIG_SUBDIR)
    try:
        data = _read_json(path)
    except ModelError:
        return info
    if not isinstance(data, dict):
        return info
    info.raw = data
    unit = data.get("unit", {}) if isinstance(data.get("unit"), dict) else {}
    types = unit.get("types", {}) if isinstance(unit.get("types"), dict) else {}
    info.unit_types = [str(k) for k in types.keys()]
    info.unit_names = {str(k): _as_str((v or {}).get("name", ""), str(k))
                       for k, v in types.items() if isinstance(v, dict)}
    general = unit.get("general", {}) if isinstance(unit.get("general"), dict) else {}
    info.general_types = [str(x) for x in _as_list(general.get("types"))]
    # ⚠️ 这里**没有**「开局附属兵个数」了：`config.json` 的 `unit.general.escort` 已被删掉，
    #    开局附属兵改由**本编辑器的摆放页**一个一个摆出来（`start_units[].escort_of`）。
    stats = _as_list(general.get("stats"))
    names: List[str] = []
    for item in stats:
        names.append(_as_str(item.get("name", "")) if isinstance(item, dict) else "")
    # 补到与 general_types 一样长：界面按序号取名字，短了会越界。
    while len(names) < len(info.general_types):
        names.append("")
    info.general_names = names
    building = data.get("building", {}) if isinstance(data.get("building"), dict) else {}
    info.building_types = sorted(str(k) for k in building.keys() if not str(k).startswith("_"))
    zone_kind = data.get("zone_kind", {}) if isinstance(data.get("zone_kind"), dict) else {}
    info.zone_kinds = [str((z or {}).get("id", "")) for z in _as_list(zone_kind.get("list"))
                       if isinstance(z, dict)]
    ai = data.get("ai", {}) if isinstance(data.get("ai"), dict) else {}
    info.ai_faction_cfg = dict(ai.get("faction", {})) if isinstance(ai.get("faction"), dict) else {}
    info.ai_general_cfg = dict(ai.get("general", {})) if isinstance(ai.get("general"), dict) else {}
    info.colors = dict(data.get("colors", {})) if isinstance(data.get("colors"), dict) else {}
    return info


def find_map_file(folder: Path, map_id: str) -> str:
    """在 `data/maps/<id>/` 里找那张地图 JSON（候选顺序与 `map_library.gd` 同规）。"""
    folder = Path(folder)
    prefer = folder / MAP_FILE_NAME
    if prefer.is_file():
        return str(prefer)
    named = folder / ("%s.json" % map_id)
    if named.is_file():
        return str(named)
    try:
        cands = sorted(p for p in folder.iterdir()
                       if p.is_file() and p.name.lower().endswith(".json")
                       and not p.name.lower().endswith(".import"))
    except OSError:
        return ""
    return str(cands[0]) if cands else ""


def _fill_map(info: MapInfo, data: dict) -> None:
    """把地图 JSON 里的字段摊进 `MapInfo`（宽容：坏字段跳过，不冒泡）。"""
    info.cols = _as_int(data.get("cols"), 0)
    info.rows = _as_int(data.get("rows"), 0)
    info.name = _as_str(data.get("name", ""), info.map_id)
    info.hidden = bool(data.get("hidden", False))
    info.placeholder = bool(data.get("placeholder", False))

    # ---- 地形：layout（字符串网格）优先，其次 terrain（名字网格），再次全草地 ----
    layout = data.get("layout")
    terrain_grid = data.get("terrain")
    for y in range(info.rows):
        for x in range(info.cols):
            ch = "."
            if isinstance(layout, list) and y < len(layout) and isinstance(layout[y], str) \
                    and x < len(layout[y]):
                ch = layout[y][x]
            elif isinstance(terrain_grid, list) and y < len(terrain_grid) \
                    and isinstance(terrain_grid[y], list) and x < len(terrain_grid[y]):
                ch = _TERRAIN_BY_NAME.get(str(terrain_grid[y][x]).strip().lower(), ".")
            info.terrain[(x, y)] = ch
            info.exists.add((x, y))
            if ch != "#":
                info.walkable.add((x, y))

    # ---- 存在网格：0 = 地图外（不可通行）----
    exists = data.get("exists")
    if isinstance(exists, list):
        for y in range(info.rows):
            row = exists[y] if y < len(exists) else None
            if not isinstance(row, list):
                continue
            for x in range(info.cols):
                if x < len(row) and not bool(row[x]):
                    info.exists.discard((x, y))
                    info.walkable.discard((x, y))

    # ---- 区划网格：地块 → 区划 id ----
    zones = data.get("zones")
    grid: Dict[Tuple[int, int], int] = {}
    if isinstance(zones, list):
        for y in range(info.rows):
            row = zones[y] if y < len(zones) else None
            if not isinstance(row, list):
                continue
            for x in range(info.cols):
                if x < len(row):
                    zid = _as_int(row[x], -1)
                    if zid >= 0:
                        grid[(x, y)] = zid
    info.zone_grid = grid

    # ---- 区划表：名字 / 种类 / 中心 / 产能 / 开局归属 ----
    seen: Set[int] = set()
    for z in _as_list(data.get("zone_list")):
        if not isinstance(z, dict):
            continue
        zid = _as_int(z.get("id"), -1)
        if zid < 0 or zid in seen:
            continue
        seen.add(zid)
        info.zone_ids.append(zid)
        info.zone_names[zid] = _as_str(z.get("name", ""), "")
        point = _as_point(z.get("center"))
        if point is not None:
            info.zone_centers[zid] = point
        prod = z.get("production")
        info.zone_production[zid] = (dict(prod) if isinstance(prod, dict) else {})
        if "owner" in z:
            # ★ **空串也记**：`"owner": ""` 的语义是「这一区开局无主」，
            #   与「没提这一区」（用地图默认）是两件事（见 logic/level.gd 同款说明）。
            info.zone_owners[zid] = _as_str(z.get("owner", ""), "")
    # 地块网格里有、zone_list 里没有的区划也算存在（手写地图常见）
    for zid in sorted(set(grid.values())):
        if zid not in seen:
            info.zone_ids.append(zid)
            seen.add(zid)
    info.zone_ids.sort()

    # ---- 阵营表 / 大本营 / 盟友 ----
    for f in _as_list(data.get("factions")):
        if not isinstance(f, dict):
            continue
        fid = _as_str(f.get("id", ""), "")
        if not fid:
            continue
        info.factions.append({"id": fid,
                              "name": _as_str(f.get("name", ""), fid),
                              "color": _as_str(f.get("color", ""), "")})
    bases = data.get("faction_bases")
    if isinstance(bases, dict):
        for fid, value in bases.items():
            point = _as_point(value)
            if point is not None:
                info.faction_bases[str(fid)] = point
    for pair in _as_list(data.get("allies")):
        if isinstance(pair, list) and len(pair) >= 2:
            a, b = _as_str(pair[0], ""), _as_str(pair[1], "")
            if a and b and a != b:
                info.allies.append([a, b])


def load_map(project_dir: Any, map_id: str) -> Optional[MapInfo]:
    """读一张地图；目录 / 文件不在（或不是 JSON 对象）→ `None`。"""
    mid = str(map_id).strip()
    if not mid:
        return None
    folder = project_path(project_dir, *MAPS_SUBDIR) / mid
    path = find_map_file(folder, mid)
    if not path:
        return None
    try:
        data = _read_json(Path(path))
    except ModelError:
        return None
    if not isinstance(data, dict):
        return None
    info = MapInfo(mid, path)
    info.raw = data
    _fill_map(info, data)
    return info


def list_maps(project_dir: Any) -> List[MapInfo]:
    """扫 `data/maps/` 列出所有地图。

    ★ **不跳过 `hidden` / `placeholder`**：它们照样是能用的地图（`hidden` 只是不进
      自由对战的地图选择条；关卡按 id 直接引用它）。标记原样带上，界面给一句提示。
    坏 JSON 跳过、不冒泡（一张坏图不该让整条列表空掉）。

    ★★ 每张图都带上 `builtin_factions`（= `config.json` 的 `colors.faction` 里那几个 id）：
      校验「阵营有没有配色」时要靠它 —— 内置 id（p1~p8 / enemy / ai）不写 color 也有颜色，
      而**自定义 id 不写就会退成品红**（游戏里表现为「整个战场一片紫」，实测踩过）。
    """
    root = project_path(project_dir, *MAPS_SUBDIR)
    out: List[MapInfo] = []
    # 配色表只读一次（不是每张图一次）：它描述的是「引擎内置了哪些阵营 id」，
    # 与具体是哪张图无关。读不到就留空集 —— 那时所有阵营都会被提示「请写 color」，
    # 属于「多提醒一句」而不是误报（真正写了的颜色照样不会报）。
    builtin = set()
    try:
        cfg = load_config(project_dir)
        table = cfg.colors.get("faction", {}) if isinstance(cfg.colors, dict) else {}
        if isinstance(table, dict):
            builtin = {str(k) for k in table.keys()}
    except Exception:
        builtin = set()
    try:
        names = sorted((p.name for p in root.iterdir() if p.is_dir()), key=str.lower)
    except OSError:
        return out
    for name in names:
        info = load_map(project_dir, name)
        if info is not None:
            info.builtin_factions = builtin
            out.append(info)
    return out


# ======================================================================
# 新建 / 载入
# ======================================================================

def _default_color_for(index: int) -> str:
    """新阵营的兜底配色（与 config.json 的 `colors.faction` 前三档一致）。"""
    palette = ("#ffd166", "#5ac8ff", "#8ce08c", "#c9a0ff", "#ffb0b0", "#ffd9a0")
    return palette[index % len(palette)]


def new_campaign(project_dir: Any, campaign_id: str, name: str = "") -> CampaignModel:
    """在 `data/campaigns/<campaign_id>/` 建一个新战役（**不写盘**；写盘走 `save_campaign`）。"""
    cid = str(campaign_id).strip()
    if not cid:
        raise ModelError("战役 id 不能为空（它就是目录名）")
    if os.sep in cid or "/" in cid or cid in (".", ".."):
        raise ModelError("战役 id 只能是目录名（不能带路径分隔符）：%r" % campaign_id)
    dir_path = project_path(project_dir, *CAMPAIGNS_SUBDIR) / cid
    model = CampaignModel(cid, dir_path)
    model.name = str(name).strip() or cid
    model.description = ""
    model.default_mode = MODE_SOLO
    model.unlock = "in_order"
    model.preserved = {COMMENT_KEY: list(EDITOR_CAMPAIGN_COMMENT)}
    # 头两个可玩阵营：与 config.json 的配色表前两档对得上（改起来更顺眼）。
    for i, fid in enumerate(("F1", "E1")):
        model.factions.append({"id": fid,
                               "name": "赤军" if i == 0 else "边军",
                               "color": _default_color_for(i),
                               "playable": i == 0})
    return model


#: 新建战役时写进 `campaign.json` 的说明（给人看的）。
EDITOR_CAMPAIGN_COMMENT: Tuple[str, ...] = (
    "战役元信息。关卡顺序以 levels[] 为准（不是文件名的字典序）。",
    "factions[].playable = 玩家能选谁；没被选中的参展阵营由 AI 驱动。",
)


def _load_level_factions(raw: Any, lv: LevelModel) -> None:
    """`factions[]` → `FactionEntry`（与 `logic/level.gd` 的 `_read_level_factions` 对齐）。"""
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        fid = _as_str(item.get("id", ""), "")
        if not fid:
            continue                # 没有 id 的项**丢掉**（它会污染「哪一方」的判定）
        e = FactionEntry(fid)
        e.ai = normalize_ai(item.get("ai"))
        e.base = _as_point(item.get("base"))
        e.resource_mult = _as_float(item.get("resource_mult"), 1.0)
        e.start_food = _as_float(item.get("start_food"), 0.0)
        e.start_gold = _as_float(item.get("start_gold"), 0.0)
        spec = item.get("attack_target")
        if isinstance(spec, dict) and spec:
            e.attack_target = normalize_target(spec)
            e.attack_target_raw = spec
        elif "attack_target" in item and spec is not None:
            # ★ 形状错（不是对象 / 是空对象）：留个痕迹给校验第 10 条，别静默吞掉
            e.attack_target = normalize_target(spec) if isinstance(spec, dict) else {"kind": ""}
            e.attack_target_raw = spec
        e.faction_ai = _as_dict(item.get("faction_ai"))
        e.general_ai = _as_dict(item.get("general_ai"))
        e.name = _as_str(item.get("name", ""), "")
        e.color = _as_str(item.get("color", ""), "")
        lv.factions.append(e)


def _load_players(raw: Any, lv: LevelModel) -> None:
    """`players[]`；没有 faction 的项丢掉（否则席位顺序会串）。"""
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        fid = _as_str(item.get("faction", ""), "")
        if not fid:
            continue
        lv.players.append({"faction": fid, "base": _as_point(item.get("base"))})


def _load_zone_owners(raw: Any, lv: LevelModel) -> None:
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        zid = _as_int(item.get("id"), -1)
        if zid < 0:
            continue
        lv.zone_owners[zid] = _as_str(item.get("owner", ""), "")


def _load_start_units(raw: Any, lv: LevelModel) -> None:
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        kind = _as_str(item.get("kind", ""), "")
        if not kind:
            continue
        u = UnitEntry(_as_str(item.get("faction", ""), ""), kind,
                      _as_int(item.get("x"), 0), _as_int(item.get("y"), 0))
        gi = _as_int(item.get("general_index"), -1)
        # ★ 序号缺省 = 1（与逻辑层 `general_index_of(kind) + 1` 同一条：`general` → 1）。
        u.general_index = gi if gi >= 1 else 1
        u.unit_type = _as_str(item.get("unit_type", ""), "")
        u.ai = normalize_ai(item.get("ai"))
        u.zone = _as_int(item.get("zone"), -1)
        u.hold = bool(item.get("hold", False))
        u.name = _as_str(item.get("name", ""), "")
        # ★★ 归属将领：**1 起**；坏值 / 缺省一律当 -1（= 不是附属兵）。
        #    宽容度与逻辑层一致：宁可当「没写」，也不要在运行时造出一个找不到队长的兵。
        u.escort_of = _as_int(item.get(ESCORT_OF_KEY), -1)
        if u.escort_of < 1:
            u.escort_of = -1
        # 记下源里出现过的键（导出时按它决定写不写，见 `_unit_to_dict`）
        u.declared = set(item.keys())
        lv.start_units.append(u)


def _load_start_buildings(raw: Any, lv: LevelModel) -> None:
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        type_id = _as_str(item.get("type", ""), "")
        if not type_id:
            continue
        lv.start_buildings.append(BuildingEntry(
            type_id, _as_int(item.get("x"), 0), _as_int(item.get("y"), 0),
            _as_str(item.get("owner", ""), "")))


def _load_objectives(raw: Any, lv: LevelModel) -> None:
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        # ★★ `for` = 这一条目标是**给哪个阵营的**。一关两个可玩阵营各打各的时，
        #    两条目标靠它区分（空串 = 对任何玩家都成立）。见 daeem/logic/level.gd
        #    的 `_read_objectives` / `objective_for` —— 两边必须同一个口径。
        lv.objectives.append({"kind": _as_str(item.get("kind", ""), "").lower(),
                              "for": _as_str(item.get("for", ""), ""),
                              "zone": _as_int(item.get("zone"), -1),
                              "hold_sec": _as_float(item.get("hold_sec"), 0.0)})


def _load_fails(raw: Any, lv: LevelModel) -> None:
    for item in _as_list(raw):
        if not isinstance(item, dict):
            continue
        lv.fail_conditions.append({"kind": _as_str(item.get("kind", ""), "").lower(),
                                   "zone": _as_int(item.get("zone"), -1)})


#: 关卡 JSON 里**本编辑器认识**的顶层键（其余一律进 `preserved` 原样带回去）。
LEVEL_KNOWN_KEYS: Tuple[str, ...] = (
    "name", "mode", "map", "players", "factions", "allies", "zones",
    "start_units", "start_buildings", "objectives", "fail_conditions", "briefing",
)

#: `campaign.json` 里本编辑器认识的键。
CAMPAIGN_KNOWN_KEYS: Tuple[str, ...] = (
    "name", "description", "default_mode", "factions", "levels", "unlock",
)


def load_level(path: Any, project_dir: Any, campaign_id: str = "",
               default_mode: str = MODE_SOLO, level_id: str = "",
               file_hint: str = "") -> LevelModel:
    """读一份关卡 JSON。

    读不出来（文件不在 / 不是合法 JSON / 根不是对象）→ **抛 `ModelError`**，
    而不是返回 None —— 调用方（`load_campaign`）要能区分「这一关坏了」与「没有这一关」，
    并且把原因说清楚（测试里第 7 组盯的就是这条）。
    """
    p = Path(path)
    data = _read_json(p)
    if not isinstance(data, dict):
        raise ModelError("关卡 JSON 的根必须是一个对象：%s" % p)

    lid = level_id or p.stem
    lv = LevelModel(lid, _as_str(data.get("map", ""), ""))
    lv.campaign_id = campaign_id
    lv.file = file_hint or ("%s/%s" % (LEVELS_SUBDIR, p.name))
    lv.name = _as_str(data.get("name", ""), lid)
    lv.mode = normalize_mode(data.get("mode"), default_mode)
    _load_players(data.get("players"), lv)
    _load_level_factions(data.get("factions"), lv)
    lv.allies_declared = "allies" in data
    lv.allies = normalize_allies(data.get("allies"))
    _load_zone_owners(data.get("zones"), lv)
    _load_start_units(data.get("start_units"), lv)
    _load_start_buildings(data.get("start_buildings"), lv)
    _load_objectives(data.get("objectives"), lv)
    _load_fails(data.get("fail_conditions"), lv)
    lv.briefing = [str(x) for x in _as_list(data.get("briefing")) if isinstance(x, str)]
    lv.briefing_declared = "briefing" in data
    lv.preserved = {k: v for k, v in data.items() if k not in LEVEL_KNOWN_KEYS}
    lv._declared = {k for k in data.keys() if k in LEVEL_KNOWN_KEYS}
    return lv


def _find_campaign_file(dir_path: Path) -> str:
    """在战役目录里找那份元信息 JSON（候选顺序与 `campaign_library.gd` 同规）。"""
    prefer = dir_path / CAMPAIGN_FILE_NAME
    if prefer.is_file():
        return str(prefer)
    named = dir_path / ("%s.json" % dir_path.name)
    if named.is_file():
        return str(named)
    try:
        cands = sorted(p for p in dir_path.iterdir()
                       if p.is_file() and p.name.lower().endswith(".json")
                       and not p.name.lower().endswith(".import"))
    except OSError:
        return ""
    return str(cands[0]) if cands else ""


def load_campaign(dir_path: Any, project_dir: Any) -> CampaignModel:
    """读一个战役（`campaign.json` + 全部关卡）。

    ⚠️ 读不出来就**抛 `ModelError`**（目录不在 / 找不到 `campaign.json` /
      不是合法 JSON / `levels[]` 一关都没有）—— 与 `logic/campaign.gd` 的
      「返回 null」等价，只是 Python 侧的惯例是把原因说清楚（测试第 7 组）。
    """
    dir_path = Path(dir_path)
    if not dir_path.is_dir():
        raise ModelError("战役目录不存在：%s" % dir_path)
    path = _find_campaign_file(dir_path)
    if not path:
        raise ModelError("这个目录里找不到 %s：%s" % (CAMPAIGN_FILE_NAME, dir_path))
    data = _read_json(Path(path))
    if not isinstance(data, dict):
        raise ModelError("%s 的根必须是一个对象：%s" % (CAMPAIGN_FILE_NAME, path))

    cid = dir_path.name
    model = CampaignModel(cid, dir_path)
    model.name = _as_str(data.get("name", ""), cid)
    model.description = _as_str(data.get("description", ""), "")
    model.default_mode = normalize_mode(data.get("default_mode"), MODE_SOLO)
    # ★ `unlock` 缺省与「写成别的值」都落到 `in_order`（第一版只有这一种，
    #   与 `logic/campaign.gd` 的 `_text(..., UNLOCK_IN_ORDER)` 同一条）。
    model.unlock = _as_str(data.get("unlock", ""), "") or "in_order"
    for item in _as_list(data.get("factions")):
        if not isinstance(item, dict):
            continue
        fid = _as_str(item.get("id", ""), "")
        if not fid:
            continue
        model.factions.append({"id": fid,
                               "name": _as_str(item.get("name", ""), fid),
                               "color": _as_str(item.get("color", ""), ""),
                               "playable": bool(item.get("playable", False))})
    model.preserved = {k: v for k, v in data.items() if k not in CAMPAIGN_KNOWN_KEYS}

    # ---- 关卡：`levels[]` 的顺序就是关卡顺序；缺省时退化成「levels/ 下按文件名排」----
    entries: List[dict] = []
    for item in _as_list(data.get("levels")):
        if not isinstance(item, dict):
            continue
        lid = _as_str(item.get("id", ""), "")
        file = _as_str(item.get("file", ""), "")
        if not lid and file:
            lid = Path(file).stem
        if not file and lid:
            file = "%s/%s.json" % (LEVELS_SUBDIR, lid)
        if not file:
            continue
        entries.append({"id": lid, "file": file,
                        "name": _as_str(item.get("name", ""), "")})
    if not entries:
        entries = _scan_level_files(dir_path)

    sync = [str(e.get("id", "")) for e in model.factions if e.get("id")]
    model.campaign_factions = sync
    skipped: List[str] = []
    for entry in entries:
        target = dir_path / str(entry["file"])
        try:
            lv = load_level(target, project_dir, cid, model.default_mode,
                            str(entry["id"]), str(entry["file"]))
        except ModelError:
            skipped.append(str(entry["id"]) or str(entry["file"]))
            continue
        if entry["name"]:
            lv.name = str(entry["name"])
        model.levels.append(lv)
    if not model.levels:
        raise ModelError("战役「%s」一关都没有（levels[] 是空的，或者每一关都读不出来%s）"
                         % (cid, "：%s" % "、".join(skipped) if skipped else ""))
    model.sync_context()
    return model


def _scan_level_files(dir_path: Path) -> List[dict]:
    """`levels[]` 没写时的兜底：扫 `levels/` 下所有 `*.json`，按文件名排序。"""
    root = dir_path / LEVELS_SUBDIR
    try:
        cands = sorted(p for p in root.iterdir()
                       if p.is_file() and p.name.lower().endswith(".json")
                       and not p.name.lower().endswith(".import"))
    except OSError:
        return []
    return [{"id": p.stem, "file": "%s/%s" % (LEVELS_SUBDIR, p.name), "name": ""}
            for p in cands]


# ======================================================================
# 规范化小工具（与逻辑层同一套宽容度）
# ======================================================================

#: 地形字符 → 名字（只用于读「terrain 名字网格」那一种老写法）。
_TERRAIN_BY_NAME = {"grass": ".", "forest": "^", "mountain": "#",
                    ".": ".", "^": "^", "#": "#", "": "."}


def normalize_ai(value: Any) -> str:
    """`ai` 字段：只认 `faction` / `general` / `none`；别的（含缺字段）→ `none`。"""
    s = _as_str(value, "").lower()
    return s if s in AI_KINDS else AI_NONE


def normalize_mode(value: Any, fallback: str = MODE_SOLO) -> str:
    """`mode`：只认 `solo` / `coop`；别的 → 兜底（兜底也不是这两种时按 solo）。"""
    s = _as_str(value, "").lower()
    if s in MODES:
        return s
    return fallback if fallback in MODES else MODE_SOLO


def normalize_target(spec: Any) -> Optional[dict]:
    """`attack_target` → 规范化字典（与逻辑层 `_read_attack_target` 对齐）。

    ★ `kind` 不认识时**保留原样的 kind**（不静默改成 zone）：校验第 10 条要能报
      「种类不认识」，把它改成 `zone` 只会让错误变得更难查。
    """
    if not isinstance(spec, dict):
        return None
    kind = _as_str(spec.get("kind", ""), "").lower()
    out: Dict[str, Any] = {"kind": kind}
    if kind == TARGET_ZONE:
        out["zone"] = _as_int(spec.get("zone"), -1)
    elif kind in (TARGET_POINT, TARGET_BUILDING):
        out["x"] = _as_int(spec.get("x"), -1)
        out["y"] = _as_int(spec.get("y"), -1)
    elif kind == TARGET_BASE:
        out["faction"] = _as_str(spec.get("faction", ""), "")
    return out


def normalize_allies(raw: Any) -> List[List[str]]:
    """`allies`：只认「两项以上的数组」，与 `logic/level.gd` 的宽容度一致。"""
    out: List[List[str]] = []
    for item in _as_list(raw):
        if not isinstance(item, list) or len(item) < 2:
            continue
        a, b = _as_str(item[0], ""), _as_str(item[1], "")
        if not a or not b or a == b:
            continue
        out.append([a, b])
    return out


def target_label(spec: Optional[dict]) -> str:
    """`attack_target` 的一行人话（界面 / 摘要用）。★ 只认 `kind` 与载荷，不查地图。"""
    if not spec:
        return "最近敌方区划（缺省）"
    kind = str(spec.get("kind", ""))
    if kind == TARGET_ZONE:
        return "指定区划 %s" % zone_label(int(spec.get("zone", -1)))
    if kind == TARGET_POINT:
        return "指定格 (%d,%d)" % (int(spec.get("x", -1)), int(spec.get("y", -1)))
    if kind == TARGET_BUILDING:
        return "建筑 (%d,%d)" % (int(spec.get("x", -1)), int(spec.get("y", -1)))
    if kind == TARGET_BASE:
        return "%s 的家" % (str(spec.get("faction", "")) or "？")
    return "不认识的目标种类「%s」" % kind


def zone_label(zid: int) -> str:
    return "c%d" % int(zid) if int(zid) >= 0 else "—"


def fmt_sec(value: float) -> str:
    """秒数显示：整数就不带小数点（与逻辑层 `_fmt_sec` 同款）。"""
    v = float(value)
    if abs(v - round(v)) < 0.001:
        return "%d" % int(round(v))
    return "%.1f" % v


def clean_number(value: Any) -> Any:
    """写进 JSON 的数字：整数写整数（`1.0` → `1`），小数保留（map_editor 同款）。"""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0
    if abs(number - round(number)) < 1e-9:
        return int(round(number))
    return round(number, 4)


def point_label(point: Optional[Tuple[int, int]]) -> str:
    return "—" if point is None else "(%d,%d)" % (int(point[0]), int(point[1]))


# ======================================================================
# 写回字典（关卡 → JSON）
# ======================================================================

def _ordered_from_preserved(preserved: Dict[str, Any]) -> dict:
    """先摆原样的未知字段（保住源文件里那些注释 / 扩展键的位置），已知键随后补。"""
    return {k: v for k, v in preserved.items()}


def _faction_to_dict(e: FactionEntry) -> dict:
    """一行 `factions[]`：**空对象里的默认字段一律省掉**（见 dev_plan_7 2.3）。"""
    out: Dict[str, Any] = {"id": e.fid}
    # ★ `ai` 一律写出来：关卡 `factions[]` 里写了这一方，就要表达「这一方被点名了」，
    #   而 `ai: none` 的语义正是「这一关它不动」（与「没提它」不是一回事）。
    out["ai"] = e.ai if e.ai in AI_KINDS else AI_NONE
    if e.base is not None:
        out["base"] = [int(e.base[0]), int(e.base[1])]
    if abs(float(e.resource_mult) - 1.0) > 1e-9:
        out["resource_mult"] = clean_number(e.resource_mult)
    if abs(float(e.start_food)) > 1e-9:
        out["start_food"] = clean_number(e.start_food)
    if abs(float(e.start_gold)) > 1e-9:
        out["start_gold"] = clean_number(e.start_gold)
    if e.attack_target:
        out["attack_target"] = _target_to_dict(e.attack_target)
    if e.faction_ai:
        out["faction_ai"] = _param_dict(e.faction_ai)
    if e.general_ai:
        out["general_ai"] = _param_dict(e.general_ai)
    if e.name:
        out["name"] = e.name
    if e.color:
        out["color"] = e.color
    return out


def _param_dict(raw: dict) -> dict:
    """AI 参数块：只留**认识的键** + 原样的其它键，数字统一清理成好看的写法。"""
    out: Dict[str, Any] = {}
    for key, value in raw.items():
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            out[key] = clean_number(value)
        else:
            out[key] = value
    return out


def _target_to_dict(spec: dict) -> dict:
    kind = str(spec.get("kind", ""))
    if kind == TARGET_ZONE:
        return {"kind": kind, "zone": int(spec.get("zone", -1))}
    if kind in (TARGET_POINT, TARGET_BUILDING):
        return {"kind": kind, "x": int(spec.get("x", -1)), "y": int(spec.get("y", -1))}
    if kind == TARGET_BASE:
        return {"kind": kind, "faction": str(spec.get("faction", ""))}
    # 不认识的 kind：原样写回（校验会拦），别把它吞掉
    return {k: v for k, v in spec.items()}


def _unit_to_dict(u: UnitEntry) -> dict:
    out: Dict[str, Any] = {"faction": u.faction, "kind": u.kind}
    gi = int(u.general_index) if u.general_index else 1
    # ★★ 写不写 `general_index`：**与缺省不同**（≠1）或**源里本来就有这个键**。
    #    只写「≠1」会丢掉源文件里显式的 `"general_index": 1` ——
    #    那样「导入 → 导出不许掉字段」这条契约就破了（实测踩到：demo 第一关第一关的
    #    主将写了 `general_index: 1`，导出后这个键消失，往返比对当场报不一致）。
    if gi != 1 or u.has("general_index"):
        out["general_index"] = gi
    if u.unit_type:
        out["unit_type"] = u.unit_type
    out["x"] = int(u.x)
    out["y"] = int(u.y)
    if u.ai != AI_NONE or u.has("ai"):
        out["ai"] = u.ai
    if int(u.zone) >= 0 or u.has("zone"):
        out["zone"] = int(u.zone)
    # ⚠️ `hold` 只在 true 时写：`false` 与「没写」在运行时**完全同义**
    #    （`logic/level.gd` 是 `bool(d.get("hold", false))`），所以这里不学上面两条。
    if u.hold:
        out["hold"] = True
    if u.name:
        out["name"] = u.name
    # ★★ 归属将领：只有真的是附属部队时才写（-1 = 普通摆放单位，不写这个键）。
    if u.is_escort():
        out[ESCORT_OF_KEY] = int(u.escort_of)
    return out


def _building_to_dict(b: BuildingEntry) -> dict:
    out: Dict[str, Any] = {"type": b.type, "x": int(b.x), "y": int(b.y)}
    if b.owner:
        out["owner"] = b.owner
    return out


def _objective_to_dict(o: dict) -> dict:
    out: Dict[str, Any] = {}
    # ★ `for` 排在最前（与游戏侧 `logic/level.gd` 的字段顺序一致）：空串不写
    #   （= 这条目标对所有玩家成立，向后兼容老数据）。
    who = str(o.get("for", ""))
    if who:
        out["for"] = who
    out["kind"] = str(o.get("kind", ""))
    out["zone"] = int(o.get("zone", -1))
    # ★★ `hold_sec` **只对「守住」类有意义**：
    #    · `hold_zone` → 写出来（必须 > 0，校验会拦）；
    #    · `capture_zone`（占领即赢）→ **一个字都不写** —— 写了 `0` 也能读，
    #      但往返会比源文件多一个字段（`test_model.py` 有一条「写出来与源文件逐字段
    #      一致」的断言，实测就是这么红的）。
    if str(o.get("kind", "")) == OBJ_HOLD_ZONE:
        out["hold_sec"] = clean_number(o.get("hold_sec", 0.0))
    return out


def _fail_to_dict(f: dict) -> dict:
    return {"kind": str(f.get("kind", "")), "zone": int(f.get("zone", -1))}


def _objective_for(lv: LevelModel, fid: str) -> Optional[dict]:
    """属于 `fid` 的那条目标（与 `logic/level.gd` 的 `objective_for` 同一口径）。

    1. `for` 正好等于 `fid` 的那条；
    2. 否则 `for` 为空的那条（= 对任何玩家都成立）；
    3. 都没有 → None（**不退回第一条**：那样红方会拿到蓝方的目标）。
    """
    generic: Optional[dict] = None
    for o in lv.objectives:
        who = str(o.get("for", ""))
        if who and who == fid:
            return o
        if not who and generic is None:
            generic = o
    return generic


def escorts_of(lv: LevelModel, fid: str, index: int) -> List[UnitEntry]:
    """这一关给「第 `index` 位将领」摆了哪几个附属兵（按摆放顺序）。

    ★★ 这是编辑器侧对运行时口径的镜像：运行时把这些兵的 `leader_id` 指向那位将领，
       于是它们真的算它的**部队**（点一个兵选中整队 / 将领濒死时去集结）。

    ⚠️ 「第 `index` 位将领」= **`general_index == index`** 的那个将领，
      **不是**「摆放列表里的第 index 个」（作者可以乱序摆、也可以改 `将领序号`）。
      两边必须是同一个判据，否则编辑器里画的连线与游戏里的编队会对不上。
    """
    out: List[UnitEntry] = []
    for u in lv.start_units:
        if str(u.faction) == str(fid) and int(u.escort_of) == int(index):
            out.append(u)
    return out


def general_with_index(lv: LevelModel, fid: str, index: int) -> Optional[UnitEntry]:
    """这一方 `general_index == index` 的那位将领（没有 → None）。"""
    for u in lv.start_units:
        if str(u.faction) == str(fid) and u.is_general() and int(u.general_index or 1) == int(index):
            return u
    return None


def placed_generals(lv: LevelModel, fid: str) -> List[UnitEntry]:
    """这一关给某一方摆出来的将领（按摆放顺序）。

    ★ 用途：摆放页「这个兵属于哪个将领」的下拉只能列出**真的摆了**的将领 ——
      运行时不会为「摆过附属部队的那一方」再自动补 3 位将领（见 README 的接管规则）。
    """
    return [u for u in lv.start_units
            if str(u.faction) == str(fid) and u.is_general()]


def ordered_start_units(lv: LevelModel) -> List[UnitEntry]:
    """导出 / 进游戏用的摆放顺序：**每一位将领紧跟着它自己的附属兵**。

    ★★ 为什么要排（这不是美观问题）：运行时按这个顺序造单位，而 `world.units`
       有一条硬约定 —— **每一方的前几个必须是它的将领**（快捷键 1/2/3、AI 的将领槽位、
       `create_generals` 都靠它）。作者在摆放页上「先摆兵、后补将领」是很自然的操作，
       不排一下就会让某个兵插在将领前面。
    ★ 同一组里保持作者自己的摆放顺序（`sorted` 是稳定的）：兵的相对位置是作者的设计。
    ★ 不是将领、也没挂将领的「散兵」排在最前面 —— 它们本来就不参与这条约定，
       而把将领放前面更符合「先看帅旗」的阅读习惯。
    """
    out: List[UnitEntry] = []
    for u in lv.start_units:
        if not u.is_general() and not u.is_escort():
            out.append(u)
    for fid in dict.fromkeys(str(u.faction) for u in lv.start_units):
        for g in placed_generals(lv, fid):
            out.append(g)
            for e in escorts_of(lv, fid, int(g.general_index or 1)):
                out.append(e)
    return out


def faction_has_placed_escorts(lv: LevelModel, fid: str) -> bool:
    """这一方在这一关**摆过附属部队**没有（= 运行时要不要整个接管这一方）。"""
    return any(str(u.faction) == str(fid) and u.is_escort() for u in lv.start_units)


# ======================================================================
# 校验：dev_plan_7 2.5 那张表（16 条）+ 9.1 风险 4 的 overload_hint
# ======================================================================
#
# ★★ `code` 与 `logic/level.gd` 的 `_ck_*` **逐字一致**：两边漂开的话，
#    「编辑器说能过、游戏开局判负」这种错就没法靠 code 对暗号了。
#
# 级别（与逻辑层同一套）：
#   拦（block）—— 不许写文件、不许开局；
#   警告（warn）—— 只提醒，设计者的自由。

def validate_campaign(model: CampaignModel,
                      maps: Dict[str, MapInfo],
                      config: Optional[ConfigInfo] = None) -> List[Issue]:
    """跑全部校验，返回问题数组（顺序稳定：按关卡顺序、按检查顺序）。

    @param maps `{map_id: MapInfo}`（`list_maps()` 的结果做成字典）——
                **关卡用到的每一张图都要在里面**，否则会报 `map_not_found`。
    @param config `load_config()` 的快照；给了才能报「关卡编制与 config 继承值」那几条
                （不给时那两条跳过，其余校验一条不少）。
    """
    issues: List[Issue] = []
    for lv in model.levels:
        where = "战役 %s / 关卡 %s" % (model.campaign_id, lv.level_id)
        validate_level(model, lv, maps, issues, where, config)
    return issues


def validate_level(model: CampaignModel, lv: LevelModel, maps: Dict[str, MapInfo],
                   issues: Optional[List[Issue]] = None,
                   where: str = "",
                   config: Optional[ConfigInfo] = None) -> List[Issue]:
    """校验**单关**（界面可以只跑当前关；`validate_campaign` 走它）。"""
    out = issues if issues is not None else []
    where = where or "战役 %s / 关卡 %s" % (model.campaign_id, lv.level_id)

    def add(sev: str, code: str, msg: str) -> None:
        out.append(Issue(sev, code, where, msg))

    info = maps.get(lv.map_id) if lv.map_id else None

    # ---- 1) 地图字段 + 地图存在 ----
    if not str(lv.map_id).strip():
        add(SEV_BLOCK, "map_missing_field", "没有写 map：这一关没有地图")
    elif info is None:
        add(SEV_BLOCK, "map_not_found",
            "地图「%s」不存在（找不到 data/maps/%s/map.json）" % (lv.map_id, lv.map_id))

    # ---- 2/3/4) 席位数 / 同一阵营 / 每个参展方都要有大本营 ----
    _ck_players(add, model, lv, info)

    # ---- 5/6/12) 点位：在地图内、不是山地、不压区划中心 ----
    if info is not None:
        _ck_points(add, lv, info)

    # ---- 7/8) 可玩阵营同方 + 目标区划的开局归属 ----
    if info is not None:
        _ck_sides(add, model, lv, info)

    # ---- 9) 目标恰好一项 + 额外失败条件 ----
    _ck_objectives(add, lv, info)

    # ---- 10/14/15/16) 进攻目标 + allies + overload ----
    _ck_attack_targets(add, model, lv, info)

    # ---- 12) 摆放的将领性 AI 必须有归属区划 ----
    _ck_start_units(add, lv)

    # ---- 13) 摆放里引用的阵营必须有定义 ----
    _ck_known_factions(add, lv, info)

    # ---- ★ 17) 自定义阵营必须有配色（否则游戏里整场一片紫）----
    _ck_colors(add, model, lv, info)

    # ---- ★ 18) 附属部队的归属（start_units[].escort_of）----
    _ck_escort_links(add, lv)

    return out


def blockers(issues: Sequence[Issue]) -> List[Issue]:
    return [i for i in issues if i.sev == SEV_BLOCK]


def warnings(issues: Sequence[Issue]) -> List[Issue]:
    return [i for i in issues if i.sev == SEV_WARN]


def has_blocker(issues: Sequence[Issue]) -> bool:
    return any(i.sev == SEV_BLOCK for i in issues)


# ---- 7 / 8 用的「同方」：并查集 ----
#
# ★ 为什么不用逻辑层那套 `FactionRes.set_allies` 的全局状态：那是一个**全局副作用**
#   （它改的是 `FactionRes` 的静态表），Python 侧没有对应物，也不该为一个只读校验去造一个。
#   并查集是同一条语义（两两结盟 = 连通分量），但纯函数、可重入。

class _Sides:
    """把 `allies` 合成「同方」关系（两两一对 → 连通分量 → 代表 id）。"""

    def __init__(self) -> None:
        self._parent: Dict[str, str] = {}

    def _find(self, a: str) -> str:
        self._parent.setdefault(a, a)
        while self._parent[a] != a:
            self._parent[a] = self._parent[self._parent[a]]
            a = self._parent[a]
        return a

    def union(self, a: str, b: str) -> None:
        ra, rb = self._find(a), self._find(b)
        if ra == rb:
            return
        # 代表取字典序小的那个：结果与「谁是第一个」无关，稳定可比。
        lo, hi = (ra, rb) if ra <= rb else (rb, ra)
        self._parent[hi] = lo

    def side_of(self, fid: str) -> str:
        return self._find(str(fid))

    def same_side(self, a: str, b: str) -> bool:
        return self._find(str(a)) == self._find(str(b))


def _effective_allies(lv: LevelModel, info: Optional[MapInfo]) -> List[List[str]]:
    """`allies` 的最终取值：关卡写了就用关卡的，**一个字都没写**才用地图的。

    （与 `logic/level.gd` 的 `effective_allies()` 同一条。）
    """
    if lv.allies_declared:
        return lv.allies
    return info.allies if info is not None else []


def _initial_zone_owner(lv: LevelModel, info: Optional[MapInfo], zid: int) -> str:
    """某区的**开局归属**：关卡覆盖 → 地图；无主 / 不认识 → `""`。"""
    if int(zid) in lv.zone_owners:
        return str(lv.zone_owners[int(zid)])
    if info is not None and int(zid) in info.zone_owners:
        return str(info.zone_owners[int(zid)])
    return ""


def _declared_faction_ids(lv: LevelModel) -> List[str]:
    return [e.fid for e in lv.factions if e.fid]


def _level_base(lv: LevelModel, fid: str) -> Optional[Tuple[int, int]]:
    e = lv.faction(fid)
    return e.base if e is not None else None


def _base_of(lv: LevelModel, info: Optional[MapInfo], fid: str) -> Optional[Tuple[int, int]]:
    """**合并之后**这一方的大本营：关卡写了用关卡的，没写用地图的。"""
    point = _level_base(lv, fid)
    if point is not None:
        return point
    if info is not None:
        return info.faction_base(fid)
    return None


def _ck_players(add, model: CampaignModel, lv: LevelModel,
                info: Optional[MapInfo]) -> None:
    """2/3/4：席位数、玩家不能占同一阵营、每个参展方都要有大本营。"""
    if not lv.players:
        add(SEV_BLOCK, "players_empty", "一关至少要有一个玩家席位")
    if lv.mode == MODE_SOLO and len(lv.players) != 1:
        add(SEV_BLOCK, "players_count_solo",
            "单人关只能有一个玩家席位（现在是 %d 个）" % len(lv.players))
    if lv.mode == MODE_COOP and len(lv.players) != 2:
        add(SEV_BLOCK, "players_count_coop",
            "合作关必须有恰好两个玩家席位（现在是 %d 个）" % len(lv.players))

    seats: Dict[str, int] = {}
    for i, p in enumerate(lv.players):
        fid = str(p.get("faction", ""))
        if not fid:
            add(SEV_BLOCK, "player_no_faction", "第 %d 个玩家席位没写 faction" % (i + 1))
            continue
        if fid in seats:
            add(SEV_BLOCK, "players_same_faction", "两个玩家不能占同一阵营（%s）" % fid)
        seats[fid] = i

    # ★★ 4) 每个**会出场的非玩家方**都要有大本营。
    #
    # 判据（与 `logic/level.gd` 的 `_effective_ai_list` 同一套，但只取我们看得见的两档）：
    #   · 关卡 `factions[]` 点名的每一方 —— **一律要求**有点位（关卡写了 ai:none 也要，
    #     因为「不动」不等于「不存在」，它照样会被建出一座大本营）；
    #     大本营可以是关卡自己给的，也可以是地图 `faction_bases` 里给的。
    #   · 地图 `factions_meta` 只划过的阵营**不要求**：地图不一定给每一方都划基地
    #     （见逻辑层那段说明），它进不了这一局的名单。
    #
    # ⚠️ 玩家席位（`players[].faction`）**不在这里拦**：
    #    逻辑层那一份只遍历「参展阵营 ∪ 地图阵营 ∪ config 阵营」，球员席位不在里面；
    #    这里跟着它的口径走，不多拦一条（否则 demo 那种「阵营清单在战役层、席位在关卡层」
    #    的写法会被我们自己的编辑器拒掉，而游戏其实是能跑的）。
    for fid in _declared_faction_ids(lv):
        if fid in seats:
            continue                    # 玩家席位不要求大本营（从 players[].base 来）
        if _base_of(lv, info, fid) is None:
            add(SEV_BLOCK, "faction_no_base",
                "阵营「%s」没有大本营：会落到 (0,0) 顶掉区块中心" % fid)


def _ck_points(add, lv: LevelModel, info: MapInfo) -> None:
    """5/6/12：大本营 / 摆放 / 出生点都要在地图内、不是山地、不压区划中心。"""
    for i, p in enumerate(lv.players):
        fid = str(p.get("faction", ""))
        base = p.get("base")
        # ⚠️ 玩家席位没写 base 时**不在这里报**（那一档归 `faction_no_base` 还是
        #    「用地图的」由运行时决定）；这里只查「写了的那一个点在不在图上」。
        if base is not None:
            _ck_point(add, info, base, "玩家「%s」的大本营" % (fid or "第 %d 位" % (i + 1)))
        # ⚠️ 玩家席位**同一个阵营**又在关卡 `factions[]` 里写了 base 时，那两个点会各查一次：
        #    这是有意的 —— 两个点都必须合法（关卡那份是「阵营的大本营」，席位那份是「开局位置」）。
    for e in lv.factions:
        if e.base is not None:
            _ck_point(add, info, e.base, "阵营「%s」的大本营" % e.fid)
    for u in lv.start_units:
        _ck_point(add, info, u.point(), "摆放单位 (%d,%d)" % (u.x, u.y))
    for b in lv.start_buildings:
        _ck_point(add, info, b.point(), "摆放建筑 (%d,%d)" % (b.x, b.y))


def _ck_point(add, info: MapInfo, point: Tuple[int, int], what: str) -> None:
    """一个点：地图外 → 山地 → 压中心（顺序与逻辑层一致，报最先中的那一条）。"""
    x, y = int(point[0]), int(point[1])
    if x < 0 or y < 0:
        return                          # 没写（哨兵值），由「必须有大本营」那条管
    if not info.tile_exists(x, y):
        add(SEV_BLOCK, "point_outside", "%s (%d,%d) 在地图外" % (what, x, y))
        return
    if not info.walkable_at(x, y):
        add(SEV_BLOCK, "point_on_mountain", "%s (%d,%d) 是山地" % (what, x, y))
        return
    for zid, center in sorted(info.zone_centers.items()):
        if (int(center[0]), int(center[1])) == (x, y):
            add(SEV_BLOCK, "point_on_zone_center",
                "%s (%d,%d) 是区块 c%d 的中心" % (what, x, y, int(zid)))
            return


def _ck_sides(add, model: CampaignModel, lv: LevelModel, info: MapInfo) -> None:
    """7) 可玩阵营必须互为同方；8) 目标区划开局必须归玩家同方。"""
    sides = _Sides()
    for pair in _effective_allies(lv, info):
        if len(pair) >= 2:
            sides.union(str(pair[0]), str(pair[1]))

    # 7) ★ 判据用「战役可玩 ∩ 本关在场」：一个**不在这一关出场**的可玩阵营
    #    （比如战役第二方的席位只在合作关出现）不该把单机关卡拦下来。
    #    逻辑层走的是 `Level.playable_ids()`（按战役的 playable），
    #    它多一步 `present` 过滤 —— 这里跟着它，别放宽成「全部可玩阵营」。
    present = set(lv.present_ids())
    if info is not None:
        present |= {str(f.get("id", "")) for f in info.factions}
    # ★★ 7) 两个口径（**与游戏侧 `logic/level.gd` 的 `_ck_allies` 分支条件一致**）：
    #    (a) **普通关卡**（目标没有 `for`）：≥2 个可玩阵营必须**互为同方**
    #        —— 目标只有一份，判定走「玩家同方」；可玩阵营各占一边的话，
    #        「选谁」就变成两场不同的仗，而数据只描述了一场。
    #    (b) ★ **选边关**（有带 `for` 的目标）：两个可玩阵营**本来就是对立的**
    #        （蓝方守 / 红方攻），所以改拦「每个可玩阵营都要有属于它的目标」。
    present = set(lv.present_ids())
    if info is not None:
        present |= {str(f.get("id", "")) for f in info.factions}
    playable = [f for f in model.playable_ids() if f in present]
    has_for = any(str(o.get("for", "")) for o in lv.objectives)
    if has_for:
        for fid in playable:
            if not _objective_for(lv, fid):
                add(SEV_BLOCK, "playable_no_objective",
                    "可玩阵营「%s」没有属于自己的目标：它选了也没得打"
                    "（objectives[] 里补一条 for=%s 的）" % (fid, fid))
    elif len(playable) >= 2:
        rep = sides.side_of(playable[0])
        for fid in playable:
            if sides.side_of(fid) != rep:
                add(SEV_BLOCK, "playable_not_same_side",
                    "%s 与 %s 是敌对关系，不能同时可玩（可玩阵营必须互为盟友）"
                    % (playable[0], fid))
                break

    # 8) ★★ 目标区划的开局归属 —— **逐条目标**判，判据按目标种类分
    #    （与游戏侧同一套口径）：
    #      · `hold_zone`（守住）：区划**必须开局就归这一方**（否则一进关就判负）；
    #      · `capture_zone`（攻占）：区划**必须开局不归这一方**（否则一进关就判胜）。
    for o in lv.objectives:
        zid = int(o.get("zone", -1))
        if zid < 0 or info is None or not info.has_zone(zid):
            continue                    # 「没写 / 不存在」两档由 `_ck_objectives` 拦
        kind = str(o.get("kind", ""))
        who = str(o.get("for", "")) or (lv.seats()[0] if lv.seats() else "")
        owner = _initial_zone_owner(lv, info, zid)
        if kind == OBJ_CAPTURE_ZONE:
            if owner and who and sides.same_side(owner, who):
                add(SEV_BLOCK, "objective_already_mine",
                    "「占领 %s」的目标区划开局就归 %s（自己）—— 一进关就判胜；"
                    "请把它划给对手" % (info.zone_label(zid), owner))
            elif owner == "":
                add(SEV_WARN, "objective_capture_unowned",
                    "「占领 %s」的目标区划开局无主：走进去就算占领，可能比预期容易"
                    % info.zone_label(zid))
            continue
        if owner == "":
            add(SEV_BLOCK, "objective_unowned",
                "目标区划 %s 开局无主：玩家一进关就会判负（本版没有「先占领再守」）"
                % info.zone_label(zid))
        elif who and not sides.same_side(owner, who):
            add(SEV_BLOCK, "objective_not_players",
                "目标区划 %s 开局归 %s，%s 一进关就会判负"
                % (info.zone_label(zid), owner, who))

    # 16) allies 里出现了不存在的 faction id → 警告
    known = set(lv.present_ids())
    if info is not None:
        known |= {str(f.get("id", "")) for f in info.factions}
    for pair in _effective_allies(lv, info):
        for x in pair:
            if str(x) not in known:
                add(SEV_WARN, "ally_unknown", "盟友表里有未定义的阵营「%s」" % str(x))


def _ck_objectives(add, lv: LevelModel, info: Optional[MapInfo]) -> None:
    """9/11：目标条数 + 种类 + 区划 + 秒数；失败条件的区划存在、不是目标区划。"""
    if not lv.objectives:
        add(SEV_BLOCK, "objective_empty", "这一关没有目标")
    # ★★ 一关可以有多条目标 —— 但**只在「按阵营分开」时**（每条都点名 `for`）。
    #    两条都不点名的话运行时取谁那条说不清（游戏侧 `objective_for` 只会取第一条）。
    #    口径与 `logic/level.gd` 的 `_ck_objectives` 逐字对齐。
    has_for = any(str(o.get("for", "")) for o in lv.objectives)
    if len(lv.objectives) > 1 and not has_for:
        add(SEV_BLOCK, "objective_too_many",
            "写了 %d 个目标、但一条都没点名给谁（每条加一个 for=阵营；"
            "只有一个阵营时只写一条）" % len(lv.objectives))
    seen_for: Dict[str, bool] = {}
    for o in lv.objectives:
        kind = str(o.get("kind", ""))
        who = str(o.get("for", ""))
        if kind not in (OBJ_HOLD_ZONE, OBJ_CAPTURE_ZONE):
            add(SEV_BLOCK, "objective_kind",
                "目标种类「%s」不认识（支持 %s / %s）" % (kind, OBJ_HOLD_ZONE, OBJ_CAPTURE_ZONE))
            continue
        if who and who in seen_for:
            add(SEV_BLOCK, "objective_dup_for", "阵营「%s」配了两条目标（只能一条）" % who)
        seen_for[who] = True
        zid = int(o.get("zone", -1))
        if zid < 0:
            add(SEV_BLOCK, "objective_no_zone", "目标没写 zone")
        elif info is None or not info.has_zone(zid):
            add(SEV_BLOCK, "objective_zone_missing", "目标区划 c%d 不存在" % zid)
        # ⚠️ `hold_sec` 只有「守住」类才要求 > 0：「占领即赢」那条不需要时间
        if kind == OBJ_HOLD_ZONE and float(o.get("hold_sec", 0.0)) <= 0.0:
            add(SEV_BLOCK, "objective_hold_sec",
                "守住时间必须大于 0 秒（现在写的是 %s）" % str(o.get("hold_sec", 0.0)))

    # ★★ 额外失败条件：`zone_lost` 的判据是「这一区**不再**归玩家同方 ⇒ 立刻判负」。
    #    所以它**开局就必须归玩家同方** —— 否则那个条件第一帧就成立、第一帧就判负，
    #    整关一进去就输（Godot 侧实测到：`reason = zone_lost:6`、`held = 0.1`）。
    #    这两条（`fail_zone_unowned` / `fail_zone_not_players`）是目标区划那两条
    #    （`objective_unowned` / `objective_not_players`）在 `fail_conditions` 上的**对偶**。
    #    ⚠️ 与逻辑层 `_ck_allies` 的口径逐字对齐：区划不存在那一档由 `fail_zone_missing`
    #       管，这里直接跳过（一条数据只报一条，别叠着报）。
    sides = _Sides()
    for pair in _effective_allies(lv, info):
        if len(pair) >= 2:
            sides.union(str(pair[0]), str(pair[1]))
    seat = lv.seats()[0] if lv.seats() else ""
    for f in lv.fail_conditions:
        if str(f.get("kind", "")) != FAIL_ZONE_LOST:
            add(SEV_BLOCK, "fail_kind",
                "失败条件种类「%s」不认识（第一批只支持 %s）"
                % (str(f.get("kind", "")), FAIL_ZONE_LOST))
            continue
        fz = int(f.get("zone", -1))
        if fz < 0:
            add(SEV_BLOCK, "fail_no_zone", "「指定区划失守」这条失败条件没写 zone")
            continue
        if info is None or not info.has_zone(fz):
            add(SEV_BLOCK, "fail_zone_missing", "失败条件的区划 c%d 不存在" % fz)
            continue
        if fz == lv.objective_zone():
            add(SEV_BLOCK, "fail_zone_is_objective",
                "额外失败条件的区划不能就是目标区划（重复配置是笔误）")
            continue
        # ★ 开局归属：关卡 `zones[]` 优先 → 地图 `zone_list[].owner`；无主 → ""
        owner = _initial_zone_owner(lv, info, fz)
        label = info.zone_label(fz) if info is not None else zone_label(fz)
        if not owner:
            add(SEV_BLOCK, "fail_zone_unowned",
                "额外失败条件的区划 %s 开局无主：这个条件第一帧就成立，玩家一进关就会判负"
                % label)
        elif seat and not sides.same_side(owner, seat):
            add(SEV_BLOCK, "fail_zone_not_players",
                "额外失败条件的区划 %s 开局归 %s，玩家一进关就会判负" % (label, owner))


def _ck_attack_targets(add, model: CampaignModel, lv: LevelModel,
                       info: Optional[MapInfo]) -> None:
    """10/14/15/16 + overload_hint：进攻目标、自己人警告、缺省警告、AI 参数过载。"""
    faction_ais = [e for e in lv.factions if e.ai == AI_FACTION]

    # 10) 引用的区划 / 格 / 建筑 / 大本营必须存在且可通行
    for e in lv.factions:
        if e.attack_target is not None:
            _ck_attack_target(add, lv, info, e.fid, e.attack_target, e.attack_target_raw)

    # 15) 挂着阵营 AI 的阵营**一个都没写** attack_target → 警告
    if faction_ais and not any(e.attack_target is not None for e in faction_ais):
        add(SEV_WARN, "no_attack_target",
            "挂着阵营 AI 的阵营一个都没写进攻目标：它们会各自去打「离自己最近的敌方区划」")

    # 14) 某个 AI 阵营的进攻目标指向自己的地 → 警告
    for e in faction_ais:
        spec = e.attack_target
        if not spec or str(spec.get("kind", "")) != TARGET_ZONE:
            continue
        zid = int(spec.get("zone", -1))
        owner = _initial_zone_owner(lv, info, zid)
        if not owner:
            continue
        sides = _Sides()
        for pair in _effective_allies(lv, info):
            if len(pair) >= 2:
                sides.union(str(pair[0]), str(pair[1]))
        if sides.same_side(owner, e.fid):
            add(SEV_WARN, "attack_target_own_land",
                "%s 的进攻目标 %s 是自己占的区划，确认是有意的吗"
                % (e.fid, info.zone_label(zid) if info else zone_label(zid)))

    # ★ 9.1 风险 4：出兵间隔很小 **且** 资源倍率很高 → 警告（**警告不是拦截**，
    #   这是设计者的自由；编辑器只是把那个已知的坑指出来）。
    #   阈值与文案取自 dev_plan_7 9.1：「这一方的出兵间隔 2s 且资源 3.0×，可能压不住」。
    for e in faction_ais:
        params = e.faction_ai or {}
        repeat = params.get("attack_repeat_sec")
        if not isinstance(repeat, (int, float)) or isinstance(repeat, bool):
            continue
        if float(repeat) <= 3.0 and float(e.resource_mult) >= 2.0:
            add(SEV_WARN, "overload_hint",
                "「%s」的出兵间隔 %s 秒且资源 %.1f×，可能压不住（一波接一波）"
                % (e.fid, fmt_sec(float(repeat)), float(e.resource_mult)))


def _ck_colors(add, model: CampaignModel, lv: LevelModel, info: Optional[MapInfo]) -> None:
    """★★ 阵营配色：**自定义阵营 id 必须在某处写了颜色** → 否则警告。

    ★ 为什么要有这一条（实测踩过）：配色表 `colors.faction.*` 里只有**内置**阵营 id
      （p1~p8 / enemy / ai），而战役可以用自己的 id。一个 id 在
      `campaign.json` 与关卡 `factions[]` 里都**没写 color** 时，渲染层会退到
      **品红** —— 症状是「整个战场一片紫、敌我分不清」，而且**游戏不报错**，
      设计者只会看到玩家来抱怨。这一条警告就是让它在**导出时就现形**。

    ⚠️ 只对「不在内置配色表里的 id」报警告：`p1` / `enemy` / `ai` 这些
      本来就有颜色，不写完全正常（样例战役三个阵营都写了，所以它是 0 条）。
    """
    builtin = getattr(info, "builtin_factions", set()) if info is not None else set()

    # 战役元信息里的颜色（`campaign.json` 的 `factions[].color`）
    campaign_colors = set()
    for e in getattr(model, "factions", []) or []:
        if isinstance(e, dict) and _as_str(e.get("color", ""), ""):
            campaign_colors.add(str(e.get("id", "")))

    for fid in lv.present_ids():
        fid = str(fid)
        if not fid or fid in builtin or fid in campaign_colors:
            continue
        fe = lv.faction(fid)
        if fe is not None and _as_str(getattr(fe, "color", ""), ""):
            continue
        add(SEV_WARN, "faction_no_color",
            "阵营「%s」没有写颜色，而且它不在内置配色表里 —— 运行时会退成品红"
            "（整个战场一片紫、敌我分不清）。请在 `campaign.json` 的 factions[] "
            "或本关的 factions[] 里给它一个 color（如 \"#5AC8FF\"）" % fid)


def _ck_escort_links(add, lv: LevelModel) -> None:
    """★ 18) 附属部队的归属：`start_units[].escort_of` 必须指向同阵营**真的摆了**的将领。

    ★★ 为什么这三条都要拦（本轮返工的核心契约）：
       开局附属兵现在**只在摆放页摆出来**（`config.json` 的全局缺省已删）。
       一个兵写了 `escort_of: 2` 而这一方**没有**第 2 位将领时，运行时找不到队长 ——
       它要么变成普通散兵（玩家以为它是某个将领的部队，其实点它只选中它自己），
       要么直接消失。两种都是「编辑器里看着对、进游戏不是那回事」，
       正是这一轮要消灭的那类问题，所以导出前必须拦住。

    ⚠️ 判据与运行时/`general_with_index()` **必须是同一套**：**同一阵营 + `general_index`
       等于 `escort_of`**（两者都是 1 起）。用「摆放列表里的第几个」当判据就会两边对不上。
    """
    for u in lv.start_units:
        if not u.is_escort():
            continue
        want = int(u.escort_of)
        fid = str(u.faction)
        # 将领自己不能再挂到别人名下（那是数据环，运行时会造出「队长跟随队长」）
        if u.is_general():
            add(SEV_BLOCK, "escort_is_general",
                "摆放单位 (%d,%d) 是一个将领，却又写了 %s=%d：将领不能当别人的附属兵"
                % (u.x, u.y, ESCORT_OF_KEY, want))
            continue
        if general_with_index(lv, fid, want) is None:
            add(SEV_BLOCK, "escort_no_general",
                "摆放单位 (%d,%d) 写了 %s=%d，但阵营「%s」没有「将领序号 = %d」的将领"
                "（它没有队长，进游戏不会算作任何人的部队）—— 要么补一位将领，要么改这个序号"
                % (u.x, u.y, ESCORT_OF_KEY, want, fid or "（空）", want))
    # 将领序号必须**唯一**：两个将领都写 2 的话，`escort_of: 2` 的兵挂到谁身上是不确定的
    for fid in {str(u.faction) for u in lv.start_units if u.is_general()}:
        seen: Dict[int, int] = {}
        for g in placed_generals(lv, fid):
            idx = int(g.general_index or 1)
            seen[idx] = seen.get(idx, 0) + 1
        for idx, n in sorted(seen.items()):
            if n > 1:
                add(SEV_BLOCK, "general_index_dup",
                    "阵营「%s」有 %d 位将领都写着将领序号 %d：附属兵该跟谁就不确定了"
                    % (fid, n, idx))
    # 摆了附属部队的那一方：运行时**整个接管**（连将领都不自动生成）——
    # 这是个「设计者要知道」的事实，不是错误，所以只在**没摆将领**时警告。
    for fid in {str(u.faction) for u in lv.start_units if u.is_escort()}:
        if not placed_generals(lv, fid):
            add(SEV_WARN, "escort_faction_no_general",
                "阵营「%s」摆了附属部队却一个将领都没摆：运行时看到这一方有附属部队就"
                "**不再自动生成那 3 位将领**，于是这些兵开局群龙无首" % fid)


def _ck_attack_target(add, lv: LevelModel, info: Optional[MapInfo], fid: str,
                      spec: dict, raw: Any = None) -> None:
    # 10) ★ 形状：`attack_target` 必须是一个对象（`"4"` / `4` / `[...]` 都是数据错）
    if raw is not None and not isinstance(raw, dict):
        add(SEV_BLOCK, "attack_target_shape",
            "阵营「%s」的进攻目标不是对象（写的是 %s）" % (fid, type(raw).__name__))
        return
    kind = str(spec.get("kind", ""))
    if kind == TARGET_ZONE:
        zid = int(spec.get("zone", -1))
        if zid < 0 or info is None or not info.has_zone(zid):
            add(SEV_BLOCK, "attack_target_zone",
                "阵营「%s」的进攻目标区划 c%d 不存在" % (fid, zid))
        return
    if kind in (TARGET_POINT, TARGET_BUILDING):
        x, y = int(spec.get("x", -1)), int(spec.get("y", -1))
        if info is None:
            return
        what = "阵营「%s」的进攻目标" % fid
        if x < 0 or y < 0:
            add(SEV_BLOCK, "attack_target_outside", "%s没写坐标" % what)
            return
        if not info.tile_exists(x, y):
            add(SEV_BLOCK, "attack_target_outside", "%s指向 (%d,%d)：地图外" % (what, x, y))
            return
        if not info.walkable_at(x, y):
            add(SEV_BLOCK, "attack_target_mountain",
                "%s指向 (%d,%d)：山地走不到" % (what, x, y))
        return
    if kind == TARGET_BASE:
        target = str(spec.get("faction", ""))
        if not target:
            add(SEV_BLOCK, "attack_target_base",
                "阵营「%s」的进攻目标是「某方的家」但没写 faction" % fid)
            return
        if _base_of(lv, info, target) is None:
            add(SEV_BLOCK, "attack_target_base",
                "阵营「%s」的进攻目标指向 %s 的大本营，但那一方没有大本营" % (fid, target))
        return
    add(SEV_BLOCK, "attack_target_kind",
        "阵营「%s」的进攻目标种类「%s」不认识（支持 %s）"
        % (fid, kind, " / ".join(TARGET_KINDS)))


def _ck_start_units(add, lv: LevelModel) -> None:
    """12) 摆放里 `ai: "general"` 的项都必须有 zone。"""
    for u in lv.start_units:
        if u.ai == AI_GENERAL and int(u.zone) < 0:
            add(SEV_BLOCK, "unit_general_no_zone",
                "摆放的将领 (%d,%d) 挂了将领性 AI 却没有归属区划（它会原地发呆）"
                % (u.x, u.y))
        if not u.faction:
            add(SEV_BLOCK, "unit_no_faction", "摆放单位 (%d,%d) 没写 faction" % (u.x, u.y))


def _ck_known_factions(add, lv: LevelModel, info: Optional[MapInfo]) -> None:
    """13) 摆放里用到的 faction 必须在「地图 factions ∪ 关卡 factions ∪ 玩家席位」里。

    ⚠️ **只管摆放**，不管玩家席位（与逻辑层同一条）：`players[].faction` 写了一个
       谁都不认识的名字不是「没有定义」这种数据错，而是设计意图的问题。
    """
    known = set(lv.present_ids())
    if info is not None:
        known |= {str(f.get("id", "")) for f in info.factions}
    for u in lv.start_units:
        if u.faction and u.faction not in known:
            add(SEV_BLOCK, "faction_unknown", "阵营「%s」没有定义" % u.faction)
    for b in lv.start_buildings:
        if b.owner and b.owner not in known:
            add(SEV_BLOCK, "faction_unknown", "阵营「%s」没有定义" % b.owner)
