"""test_model.py —— 战役编辑器**数据层**的无头测试（不需要图形界面）。

跑法（仓库根目录任意处）：

    python dev_gd_a/tools/campaign_editor/test_model.py

为什么要有它：编辑器写的是**运行时真正会读的那两个文件**
（`data/campaigns/<id>/campaign.json` 与 `levels/*.json`），而写错一个键名、少写一个字段、
或者把「没写」写成「写了默认值」都不会报错 —— 只会让游戏里静默按别的数据跑。
所以这一套把三件事钉成断言：

    1. **往返**：读进来 → 写出去 → 再读进来，逐字段一致；LF 行尾、无 BOM、不多写默认值；
    2. **校验**：dev_plan_7 2.5 那 16 条（+9.1 风险 4 的过载提示）**每条各造一个坏样例**，
       确认它真的被拦 / 被警告 —— 只测「合法数据能过」等于没测；
    3. ★ **真文件不被测试改坏**：整场测试只动 `.tmp_campaign_editor_test/` 里的副本，
       跑完 `data/campaigns/**`、`data/maps/**`、`data/config.json` 的字节与开始时**逐个一致**。

⚠️ 这一份**不许 import tkinter**（数据层的测试不开窗）；界面断言在 `test_app.py`。
"""

from __future__ import annotations

import copy
import hashlib
import json
import shutil
import sys
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

from campaign_editor import levelfile                              # noqa: E402
from campaign_editor import model as M                             # noqa: E402

#: 仓库里的样例战役（**只读**；测试会把整个 data/ 拷进临时目录再改）。
REAL_CAMPAIGNS = PROJECT_DIR / "data" / "campaigns"
REAL_MAPS = PROJECT_DIR / "data" / "maps"
REAL_CONFIG = PROJECT_DIR / "data" / "config.json"
REAL_DEMO = REAL_CAMPAIGNS / "demo"

#: ★ 临时目录放在**工具目录里**（不放系统 temp）：受限环境下系统 temp 不一定可写
#:   （实测踩到：`mkdtemp()` 成功、往里建子目录 `PermissionError`）。
TMP_ROOT = HERE.parent / ".tmp_campaign_editor_test"
#: 这个沙盒里「工程目录」用临时副本：测试会写它，而真 `daeem/data/` 一个字节都不许动。
TMP_PROJECT = TMP_ROOT / "project"

_FAILED = 0
_PASSED = 0

#: 「逐字段一致」的比较**只有一处实现**（`levelfile.canonical_payload`）：
#: 它把数字统一成 float、把「顺序无意义」的数组（`zones[]`/`factions[]`/…）排序。
#: ★ 为什么不在测试里再写一份：三份实现必然漂开，而且这一份漂开的后果是**假红**——
#:   编辑器重建 `zones[]` 时按区划号排了个序，测试就报「往返不一致」，
#:   而真正要钉的「字段与取值逐字段一致」其实一个都没破（实测踩到过）。


def same_payload(a, b) -> bool:
    """两份 JSON 载荷是不是「逐字段一致」（数字宽松、无意义顺序的数组忽略顺序）。"""
    return levelfile.canonical_payload(a) == levelfile.canonical_payload(b)


def _payload_diff(a, b) -> str:
    """两份载荷的差异说明（人话；比对时同样忽略无意义顺序）。"""
    a = levelfile.canonical_payload(a)
    b = levelfile.canonical_payload(b)
    if a == b:
        return ""
    lines = []
    for key in sorted(set(a) | set(b)):
        if key not in a:
            lines.append("%s 多写了 %r" % (key, b[key]))
        elif key not in b:
            lines.append("%s 丢了（原来 %r）" % (key, a[key]))
        elif a[key] != b[key]:
            lines.append("%s：%r → %r" % (key, a[key], b[key]))
    return "；".join(lines[:6])


#: 样例地图 dongzheng 的几个已知点位（校验断言用；写死比现算更好读）。
BASE_F1 = (5, 10)        # a1 区块里，玩家一的大本营
BASE_E1 = (18, 10)       # a2 区块里，敌方的大本营
ZONE_C1 = 4              # 中立中场（样例关卡的争夺点）
ZONE_OWNED_F1 = 0        # b1：地图上开局归 F1（校验第 8 条要它）
ZONE_OWNED_E1 = 1        # b2：地图上开局归 E1
ZONE_NEUTRAL = 6         # f1：地图上开局无主
ZONE_CENTER = (1, 0)     # f1 的中心格（压上去要拦）
MOUNTAIN = (0, 9)        # 山地（布局里是 '#'）


#: 合成地图的尺寸（够摆下 9 个 3×3 的区划 + 一圈边界）。
SYN_COLS, SYN_ROWS = 9, 12


def synthetic_map(project: Path) -> M.MapInfo:
    """造一张**内存里的**小地图（`FACTS` 用的那张）。

    ★★ 为什么要造一张自己的图，而不是直接拿 `data/maps/dongzheng`：
      样例数据是**别人也在改**的东西（里程碑之间搬过大本营、改过区划归属）。
      把校验用例钉在样例数据上，会出现「样例数据搬家 → 校验器的测试红」这种
      完全指不到原因的失败（实测踩到一次，查了很久）。
      于是这里自己造一张**结构可控**的小图：
        · 9×12，地形全是草地，只留一格山地 (1, 0) 与一格水域 (2, 0)；
        · 9 个 3×3 的区划，中心格 = 每区左上角那一格（不压在大本营上）；
        · 三档归属各 3 个：玩家 / 敌方 / 无主 —— 每条规则都能挑到合适的区划。
      这样断言里的每个坐标 / 区划号都是**本文件定义**的，样例数据怎么改都不影响。
    """
    info = M.MapInfo("synth", "")
    info.cols, info.rows = SYN_COLS, SYN_ROWS
    info.name = "合成测试图"
    info.factions = [{"id": "A1", "name": "甲", "color": "#5AC8FF"},
                     {"id": "B1", "name": "乙", "color": "#FF6B6B"}]
    info.faction_bases = {"A1": (2, 8), "B1": (8, 3)}
    info.allies = []
    for y in range(SYN_ROWS):
        for x in range(SYN_COLS):
            # 山地放在 (1,0)、水域放在 (2,0)：都**不是**任何区划的中心
            # （中心是每区左上角 (0,0)/(3,0)…），于是校验用例能各自造出干净的坏样例。
            if (x, y) == (1, 0):
                ch = "#"
            elif (x, y) == (2, 0):
                ch = "~"
            else:
                ch = "."
            info.terrain[(x, y)] = ch
            info.exists.add((x, y))
            if ch not in ("#", "~"):
                info.walkable.add((x, y))
    for zid in range(9):
        zx, zy = (zid % 3) * 3, (zid // 3) * 3
        center = (zx, zy)
        owner = {0: "A1", 1: "A1", 2: "A1", 3: "B1", 4: "B1", 5: "B1"}.get(zid, "")
        info.zone_ids.append(zid)
        info.zone_names[zid] = "z%d" % zid
        info.zone_centers[zid] = center
        info.zone_production[zid] = {"food": 1.0, "gold": 0.0, "population": 0.1}
        if owner:
            info.zone_owners[zid] = owner
        for y in range(zy, zy + 3):
            for x in range(zx, zx + 3):
                info.zone_grid[(x, y)] = zid
    info.raw = {}
    return info


class Facts:
    """测试用的「已知事实」= **合成地图**上一组挑好的点位与区划号。

    ★ 全是本文件定义的常量（见 `synthetic_map` 的说明），与样例数据无关。
    """

    def __init__(self, project: Path) -> None:
        self.info = synthetic_map(project)
        self.map_id = self.info.map_id
        self.map_factions = ["A1", "B1"]
        self.player = "A1"
        self.enemy = "B1"
        self.player_base = (2, 8)           # 区划 7 里，不是任何中心
        self.enemy_base = (8, 3)            # 区划 5 里，不是任何中心
        self.mountain = (1, 0)              # 唯一一格山地 / 一格水域（都**不是**任何区划的中心）
        self.water = (2, 0)
        self.obj_zone = 0                   # 归玩家
        self.attack_zone = 7                # 无主（可以当进攻目标）
        self.fail_zone = 1                  # ★ 另一个**归玩家**的区划（失败条件要它同方）
        self.centers = set(self.info.zone_centers.values())
        self.own_zone = 3                   # 归敌方（验「进攻目标指向自己的地」）
        self.spot = (1, 1)                  # 一格可通行、**非任何区划中心**的空地
        self.bad_center = (0, 0)            # 区划 0 的中心格（也正好是 obj_zone 的中心）

    def maps(self) -> dict:
        """`{map_id: MapInfo}`（只含这一张合成图）—— 校验只认它。"""
        return {self.map_id: self.info}

    def maps_with(self, **changes) -> dict:
        """这张合成图的一份**改动副本**（只为某一条断言造条件，不碰真文件）。"""
        import copy as _copy
        info = _copy.deepcopy(self.info)
        for key, value in changes.items():
            setattr(info, key, value)
        return {self.map_id: info}


#: 合成事实（`main()` 里 `setup_project()` 之后填）。
FACTS: Facts = None                                     # type: ignore[assignment]


# ======================================================================
# 断言小工具（与另两个编辑器同款，纯标准库）
# ======================================================================

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


def raises(fn, label: str, exc=M.ModelError) -> None:
    try:
        fn()
    except exc:
        ok(True, label)
        return
    except Exception as other:                                 # noqa: BLE001
        ok(False, "%s（抛的是 %s: %s）" % (label, type(other).__name__, other))
        return
    ok(False, "%s（居然没抛）" % label)


def codes(issues) -> list:
    return [i.code for i in issues]


def block_codes(issues) -> list:
    return [i.code for i in M.blockers(issues)]


def warn_codes(issues) -> list:
    return [i.code for i in M.warnings(issues)]


def has(issues, code: str, sev: str = M.SEV_BLOCK) -> bool:
    return any(i.code == code and i.sev == sev for i in issues)


# ======================================================================
# 临时工程 + 关卡工厂
# ======================================================================

def setup_project() -> None:
    """把真 `data/` 拷一份到 `.tmp_campaign_editor_test/project/data/`（只读真文件）。

    ★★ 每次跑都**先删干净再拷**：上一轮如果中途被打断（Ctrl+C / 崩了），
      临时目录里会留着那一轮的改动 —— 而「关卡比对」这类断言读的正是临时副本，
      于是第二轮会在一个被污染的基础上跑，报出一些**看着完全莫名其妙**的失败
      （实测踩到：地图大本营变成了测试里写的坐标、关卡 zones 里多出几条）。
      从真文件重建是唯一稳妥的做法。
    """
    shutil.rmtree(TMP_ROOT, ignore_errors=True)
    TMP_PROJECT.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REAL_CAMPAIGNS, TMP_PROJECT / "data" / "campaigns")
    shutil.copytree(REAL_MAPS, TMP_PROJECT / "data" / "maps")
    shutil.copyfile(REAL_CONFIG, TMP_PROJECT / "data" / "config.json")


def cleanup() -> None:
    shutil.rmtree(TMP_ROOT, ignore_errors=True)


def snapshot(root: Path) -> dict:
    """目录树的「路径 → 内容 hash」（字节级）；用来钉「真文件一字未改」。"""
    out = {}
    for p in sorted(root.rglob("*")):
        if p.is_file():
            out[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


def tmp_campaign_dir(name: str = "demo") -> Path:
    """临时工程里的战役目录（**每个测试独立一份**，互不污染）。"""
    return TMP_PROJECT / "data" / "campaigns" / name


def maps(real: bool = False) -> dict:
    """校验要用的地图表。

    ★ 默认给**合成地图**（`FACTS.maps()`）：校验用例全部钉在自己造的那张图上，
      样例数据怎么改都不会把它们搞红（见 `synthetic_map` 的长说明）。
      要验样例数据自己时，传 `real=True` 走盘上那个工程目录。
    """
    if real:
        return levelfile.maps_by_id(TMP_PROJECT)
    return dict(FACTS.maps())


def base_level(**over) -> dict:
    """一份**能通过全部校验**的关卡（每个测试改一处来验一条规则）。

    ★ 为什么要有它：那 18 条里有好几条是「必须没有别的问题才能验」的
      （比如第 8 条只在目标区划存在时才判），一条条手搓 JSON 既啰嗦又容易自己写错。
    ★ 里头的坐标 / 区划号全部来自 `FACTS`（**合成地图**上的常量）：
      样例数据搬家不该把校验器的测试搞红（见 `synthetic_map` 的说明）。
    """
    f = FACTS
    data = {
        "_comment": ["测试用例：合法基线。"],
        "name": "基线关",
        "mode": "solo",
        "map": f.map_id,
        "players": [{"faction": f.player, "base": list(f.player_base)}],
        "factions": [
            {"id": f.enemy, "ai": "garrison", "base": list(f.enemy_base),
             "attack_target": {"kind": "zone", "zone": f.attack_zone}},
        ],
        "start_units": [],
        "start_buildings": [{"type": "tower", "x": f.spot[0], "y": f.spot[1],
                             "owner": f.player}],
        "zones": [{"id": f.obj_zone, "owner": f.player},
                  {"id": f.attack_zone, "owner": ""}],
        "objectives": [{"kind": "hold_zone", "zone": f.obj_zone, "hold_sec": 90}],
        "fail_conditions": [],
        "briefing": [],
    }
    data.update(over)
    return data


def write_level(data: dict, name: str = "case", root: Path = None) -> Path:
    """把一份关卡 JSON 写进某个临时战役目录，返回路径。"""
    folder = (root or (tmp_campaign_dir() / "_cases")) / "levels"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / ("%s.json" % name)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n",
                    encoding="utf-8", newline="\n")
    return path


def _facts_colors() -> dict:
    """测试里两个「已知阵营」的默认名字 / 颜色（等价于旧 campaign.json 那一份）。"""
    return {FACTS.player: ("甲", "#5AC8FF"), FACTS.enemy: ("乙", "#FF6B6B")}


def level_with_playable(data: dict, playable: list = None) -> dict:
    """把关卡 JSON 变成**新格式**：`factions[]` 自带 `playable`（每项都显式写）。

    `playable=None` → 用 `players[]` 的席位（老关卡那种「席位就是可玩」的口径）。
    """
    data = copy.deepcopy(data)
    known = _facts_colors()
    factions = [dict(x) for x in data.get("factions", []) if isinstance(x, dict)]
    by_id = {str(f.get("id", "")): f for f in factions}
    for fid, (name, color) in known.items():
        f = by_id.get(fid)
        if f is not None:
            if not f.get("name"):
                f["name"] = name
            if not f.get("color"):
                f["color"] = color
    if playable is None:
        playable = [str(p.get("faction", "")) for p in data.get("players", [])
                    if isinstance(p, dict) and p.get("faction")]
    wanted = {str(f) for f in playable}
    for fid in wanted:
        f = by_id.get(fid)
        if f is None:
            name, color = known.get(fid, ("", "#8CE08C"))
            f = {"id": fid, "ai": "none", "name": name, "color": color}
            factions.append(f)
            by_id[fid] = f
    for fid, f in by_id.items():
        f["playable"] = fid in wanted
    data["factions"] = factions
    return data


def campaign_with(data: dict, playable: list = None,
                  legacy_factions: list = None) -> M.CampaignModel:
    """建一个**只含这一关**的临时战役，返回载入好的模型（每次全新）。

    ⚠️ 用 `demo/_cases` 而不是 `demo` 本身：`demo` 是「往返 / 覆盖规则」那几组
      断言的**基准数据**，被这里覆盖掉的话，后跑的测试会在一份被改过的数据上断言
      （踩过：`zones[]` 里多出几条、地图大本营变成别的坐标）。

    @param playable 这一关哪些阵营可玩（写进关卡 `factions[].playable`）；
                    省略 = `players[]` 的席位。
    @param legacy_factions 给了就写**旧格式** `campaign.json` 的 `factions[]`
                    （关卡那份**不带** `playable`，用来测一次性迁移）。
    """
    root = tmp_campaign_dir() / "_cases"
    shutil.rmtree(root, ignore_errors=True)
    (root / "levels").mkdir(parents=True, exist_ok=True)
    level_data = data if legacy_factions is not None else level_with_playable(data, playable)
    write_level(level_data, "case")
    camp = {
        "_comment": ["测试战役"],
        "name": "测试战役",
        "description": "",
        "default_mode": data.get("mode", "solo"),
        "levels": [{"id": "case", "file": "levels/case.json", "name": "用例"}],
        "unlock": "in_order",
    }
    if legacy_factions is not None:
        camp["factions"] = legacy_factions
    (root / "campaign.json").write_text(json.dumps(camp, ensure_ascii=False, indent=2) + "\n",
                                        encoding="utf-8", newline="\n")
    return levelfile.load_campaign(root, TMP_PROJECT)


def check(data: dict, maps_override=None, playable=None, legacy_factions=None) -> list:
    """造一个战役 → 跑校验 → 返回 issue 列表。"""
    model = campaign_with(data, playable, legacy_factions)
    return M.validate_campaign(model, maps_override if maps_override is not None else maps())


# ======================================================================
# [0] 读 / 写 / 往返
# ======================================================================

def t_load_and_roundtrip() -> None:
    print("\n[0] 载入 / 保存 / 往返")
    model = levelfile.load_campaign(tmp_campaign_dir(), TMP_PROJECT)
    eq(model.campaign_id, "demo", "战役 id = 目录名")
    eq(model.name, "东征·第一章", "战役显示名")
    eq(model.default_mode, M.MODE_SOLO, "默认模式")
    eq(model.unlock, "in_order", "解锁方式")
    # ⚠️ 样例战役**随时会加关**（作者在编辑器里新建一关就多一个）—— 只钉前两关的顺序，
    #    别写死「一共几关」（写死了的话加一关就假红）。
    eq([lv.level_id for lv in model.levels][:2], ["01_beachhead", "02_twin_line"],
       "关卡顺序 = levels[] 的顺序（前两关固定）")
    # ★★ 样例战役有**两个**可玩阵营（F1 赤军 / F2 金军）—— 用户在关卡里挑一个来玩，
    #    没被选中的那一个由阵营 AI 接管（见 docs/route.md 37.18）。
    # ★★ 阵营表跟着关卡走：每一关自己带 playable（样例前两关都是 F1 / F2）。
    eq(model.levels[0].playable_ids(), ["F1", "F2"],
       "第一关可玩阵营 = 关卡 factions[] 里 playable 的那些")
    eq(set(model.levels[1].playable_ids()), {"F1", "F2"},
       "第二关也同样自带可玩阵营（席位顺序优先）")
    ok(not model.to_dict().get("factions"),
       "★★ campaign.json 不再写 factions[]（阵营表下放到关卡）")
    eq(model.levels[0].mode, M.MODE_SOLO, "第一关是单人")
    eq(model.levels[1].mode, M.MODE_COOP, "第二关是合作")
    ok(model.levels[1].allies, "第二关的 allies 读进来了（两两一对）")
    # ★ `zones[]` 里覆盖了哪几区**是样例数据自己的事**（会被别人改），这里只钉形状：
    #   「它读进来了，而且是 区划号(int) → 阵营 id(str)」。
    owners = model.levels[0].zone_owners
    ok(owners and all(isinstance(z, int) and isinstance(o, str) for z, o in owners.items()),
       "zones[] 的归属读进来了（%r）" % owners)
    # ★★ 载入时已把地图的 zone_list[].owner 落成**每一块地**的显式归属：
    #    战役编辑器不再有「（用地图的）」（地图编辑器不编辑区块归属）。
    info0 = levelfile.load_map(TMP_PROJECT, model.levels[0].map_id)
    ok(info0 is not None, "（前提）第一关的地图读得出来")
    if info0 is not None:
        eq(set(owners), set(info0.zone_ids),
           "★★ 第一关的 zones[] 覆盖了地图里的**每一块地**（没有「用地图的」）")
        src_zones = json.loads((tmp_campaign_dir() / "levels" / "01_beachhead.json")
                               .read_text(encoding="utf-8-sig")).get("zones", [])
        explicit = {int(z["id"]): str(z.get("owner", "")) for z in src_zones
                    if isinstance(z, dict) and isinstance(z.get("id"), int)}
        for zid in info0.zone_ids:
            want = explicit[zid] if zid in explicit \
                else str(info0.zone_owners.get(zid, ""))
            eq(owners[zid], want,
               "★ 区划 c%d：已有的显式值保留 / 缺的补成地图 owner（无主 = 空串）" % zid)
    eq(model.levels[0].objective_zone(), 4, "目标区划（样例第一关守的是 c1）")
    # ★ 断言的是**关系**（摘要由同一份 hold_sec 拼出来），不是调平衡用的那个数：
    #   写死 90.0 会在改关卡时长时假红，而它想钉的其实是「读进来了、且两处一致」。
    hold = model.levels[0].objective_hold_sec()
    ok(hold > 0, "守住秒数是正数（%r）" % hold)
    eq([f["kind"] for f in model.levels[1].fail_conditions], ["zone_lost"],
       "额外失败条件读进来了")
    eq(model.levels[0].summary(), "单人 · 守住 c4 %s 秒" % M.fmt_sec(hold),
       "一行摘要（★ 关卡模型没有地图，所以区划只能用 c<id> 记法）")

    # ---- 往返：读 → 写 → 再读，逐字段一致 ----
    tmp = TMP_ROOT / "roundtrip"
    shutil.rmtree(tmp, ignore_errors=True)
    same, diffs = levelfile.roundtrip_ok(model, tmp, TMP_PROJECT)
    ok(same, "★ 读进来 → 写出去 → 再读进来：逐字段一致%s"
       % ("" if same else "（差异：%s）" % "；".join(diffs[:5])))

    # ---- 与源文件逐字段比对（`_comment` 也算：它是给人看的文档，必须原样带回）----
    src = json.loads((tmp_campaign_dir() / "levels" / "01_beachhead.json")
                     .read_text(encoding="utf-8-sig"))
    out = json.loads((tmp / "demo" / "levels" / "01_beachhead.json")
                     .read_text(encoding="utf-8-sig"))
    ok(same_payload(out, src),
       "★★ 写出来的关卡与源文件**逐字段一致**（含 _comment 原样带回）%s"
       % ("" if same_payload(out, src) else
          "（差异：%s）" % _payload_diff(out, src)))

    # ---- 行尾 / BOM / 多余字段 ----
    raw = (tmp / "demo" / "levels" / "01_beachhead.json").read_bytes()
    ok(not raw.startswith(b"\xef\xbb\xbf"), "写出来不带 BOM")
    ok(b"\r\n" not in raw, "写出来是 LF 行尾（Windows 上也不会变成 CRLF）")
    ok(raw.endswith(b"\n"), "末尾有一个换行")
    camp_raw = (tmp / "demo" / "campaign.json").read_bytes()
    ok(not camp_raw.startswith(b"\xef\xbb\xbf") and b"\r\n" not in camp_raw,
       "campaign.json 同样是 LF、无 BOM")

    # ---- 不写多余字段：默认值一个都不写 ----
    lv = M.LevelModel("t", FACTS.map_id)
    lv.name = "t"
    lv.add_player(FACTS.player)
    lv.ensure_faction(FACTS.enemy)                # ai=none、没大本营、没目标
    lv.objectives = [{"kind": M.OBJ_HOLD_ZONE, "zone": FACTS.obj_zone, "hold_sec": 30.0}]
    out = lv.to_dict()
    ok("resource_mult" not in out["factions"][0], "★ 资源倍率 = 1.0 不写")
    ok("start_food" not in out["factions"][0] and "start_gold" not in out["factions"][0],
       "★ 开局资源 = 0 不写")
    ok("base" not in out["factions"][0], "★ base 没写就不写这个键")
    ok("attack_target" not in out["factions"][0], "★ attack_target 没写就不写这个键")
    ok("faction_ai" not in out["factions"][0] and "general_ai" not in out["factions"][0],
       "★ AI 参数为 None 不写")
    eq(out["factions"][0]["ai"], M.AI_NONE, "★ 但 `ai` 一律写出来（表达「这一方被点名了」）")
    ok("base" not in out["players"][0], "★★ `players[].base` 没写就不写这个键")
    lv.set_player_base(0, (0, 0))
    eq(lv.to_dict()["players"][0]["base"], [0, 0], "★★ 写了 (0,0) 就写出来（与「没写」是两件事）")
    lv.objectives[0]["desc"] = "先守 30 秒，再看情况"
    eq(lv.to_dict()["objectives"][0].get("desc", ""), "先守 30 秒，再看情况",
       "★ 目标自由描述原样写出（局内左上目标栏用）")
    lv.objectives[0]["desc"] = ""
    ok("desc" not in lv.to_dict()["objectives"][0], "★ 空描述不写（老数据往返不多字段）")
    lv.objectives[0]["short"] = "死守"
    eq(lv.to_dict()["objectives"][0].get("short", ""), "死守",
       "★ 目标简称原样写出（左上 ※死守）")
    lv.objectives[0]["short"] = ""
    ok("short" not in lv.to_dict()["objectives"][0], "★ 空简称不写")

    # ---- zones 里的空串 = 显式清空（不是「没提这一区」）----
    lv2 = M.LevelModel("t2", FACTS.map_id)
    lv2.name = "t2"
    lv2.set_zone_owner(FACTS.obj_zone, "")
    eq(lv2.to_dict()["zones"], [{"id": FACTS.obj_zone, "owner": ""}],
       "★ zones 里的空串照写（显式清空）")
    eq(M._initial_zone_owner(lv2, maps()[FACTS.map_id], FACTS.obj_zone), "",
       "★★ 显式清空之后，这一区**不再是**地图上的归属")

    # ---- preserved：不认识的字段原样带回 ----
    lv3 = M.LevelModel("t3", FACTS.map_id)
    lv3.name = "t3"
    lv3.preserved = {"_comment": ["给我自己看的"], "future_field": {"a": 1}}
    out3 = lv3.to_dict()
    eq(out3["future_field"], {"a": 1}, "★★ 不认识的字段原样带回（导入 → 导出不掉字段）")
    eq(out3["_comment"], ["给我自己看的"], "★ _comment 原样带回")


# ======================================================================
# [1] 覆盖规则（关卡 vs 地图）
# ======================================================================

def t_override_rules() -> None:
    print("\n[1] 覆盖规则（关卡没写 → 用地图的；写了 → 逐字段覆盖）")
    f = FACTS
    info = maps(real=True)["dongzheng"]
    # ★ 不写死坐标（`(5,11)` 那种）：它是**地图数据**，区划一重排就变
    #   （实测：把 c1/c2 改成连续之后大本营挪到了 (4,5)/(16,5)，这几条当场假红）。
    #   要钉的是「读进来了、而且与地图 JSON 里那一份一致」。
    map_base_f1 = info.faction_base("F1")
    map_base_f2 = info.faction_base("F2")
    ok(map_base_f1 is not None and map_base_f2 is not None,
       "★ 地图自带两个阵营的大本营（F1=%s / F2=%s）" % (map_base_f1, map_base_f2))
    eq(info.zone_owners.get(0), "F1", "地图自带 b1 的开局归属")
    # ★ c1（区划 4）现在**有主**：归与蓝方结盟的渡口守军 GD1 ——
    #   用户口径「守住任务只要区划属于己方**或友方**都可」，于是把 c1 划给了友军。
    eq(info.zone_owners.get(4), "GD1", "★ 地图上 c1 开局归友军 GD1（不再是「无主」）")
    eq(info.allies, [], "样例地图没有 allies（盟友写在关卡那一份里）")

    # 关卡没写 factions / zones / allies → 一律用地图的
    # ★ `zones` 的这条只是**模型层兜底**：正常 `load_campaign` 会先
    #   `ensure_zone_owners()` 把地图的每一块地抄成关卡显式值（见 [1c]）。
    lv = M.LevelModel("bare", "dongzheng")
    lv.name = "bare"
    eq(lv.factions, [], "关卡没写 factions：列表是空的（运行时用地图的）")
    eq(M._base_of(lv, info, "F2"), map_base_f2, "★ 关卡没写大本营 → 落回地图的")
    eq(M._initial_zone_owner(lv, info, 0), "F1", "★ 关卡没写 zones → 用地图的归属")
    eq(M._initial_zone_owner(lv, info, 4), "GD1", "★ 关卡没写 zones → c1 也用地图的（GD1）")
    # 「无主」那一档仍然要能表达（找一块地图上真没写 owner 的区划来验）
    empty_zid = next((z for z in info.zone_ids if z not in info.zone_owners), None)
    if empty_zid is not None:
        eq(M._initial_zone_owner(lv, info, empty_zid), "",
           "★ 地图上无主的区划 → 空串（不是 None）")
    eq(M._effective_allies(lv, info), [], "★ 关卡没写 allies → 用地图的（这里是空表）")
    lv.allies_declared = True
    eq(M._effective_allies(lv, info), [], "★★ 关卡写了空 allies → **就用这个空表**（不是回退地图）")
    lv.allies = [["F1", "E1"]]
    eq(M._effective_allies(lv, info), [["F1", "E1"]], "关卡写了 allies → 用它")

    # 关卡写了 factions → 逐字段覆盖（只改大本营不会把别的抹掉）
    lv2 = M.LevelModel("over", "dongzheng")
    lv2.name = "over"
    e = lv2.ensure_faction("E1")
    e.ai = M.AI_GARRISON
    e.base = (20, 13)
    eq(M._base_of(lv2, info, "E1"), (20, 13), "★★ 关卡写了大本营 → 覆盖地图的")
    eq(lv2.faction("E1").garrison_ai, None, "★ 只改了大本营：别的字段还留在**默认值**上")
    eq(M._base_of(lv2, info, "F1"), map_base_f1, "★ 没点名的 F1 照样用地图的大本营")

    # 地图里有、关卡里没点名的一方：base 从地图来
    eq([f.fid for f in lv2.factions], ["E1"], "关卡点名的阵营只有 E1")


def t_zone_owner_materialization() -> None:
    """★★ 区划归属：地图 owner → 关卡显式 `zones[]`（「（用地图的）」已删除）。"""
    print("\n[1c] 区划归属：每一块地都显式（地图 owner 只当初始化来源）")
    info = maps(real=True)["dongzheng"]
    ok(bool(info.zone_ids), "（前提）地图有区划")

    lv = M.LevelModel("z", "dongzheng")
    lv.name = "z"
    changed = lv.ensure_zone_owners(info)
    ok(changed, "★ 第一次补齐：有改动")
    eq(set(lv.zone_owners), set(info.zone_ids), "★★ 每一块地都有显式归属")
    for zid in info.zone_ids:
        eq(lv.zone_owners[zid], str(info.zone_owners.get(zid, "")),
           "★ c%d 初值 = 地图 owner（没写就是空串 = 无主）" % zid)
    empty_zid = next((z for z in info.zone_ids if z not in info.zone_owners), None)
    if empty_zid is not None:
        eq(lv.zone_owners[empty_zid], "", "★★ 地图上无主的区划 → 显式空串（不是不写）")

    # 再补一次：不再改动（幂等）
    ok(not lv.ensure_zone_owners(info), "★ 再补一次是幂等的（没有改动）")

    # fill 模式保留作者已有的显式值
    explicit_zid = info.zone_ids[0]
    lv.set_zone_owner(explicit_zid, "ZZ")
    lv.ensure_zone_owners(info)
    eq(lv.zone_owners[explicit_zid], "ZZ", "★★ 已有显式归属保留（不拿地图覆盖回去）")

    # force 模式（换地图）：整张表按新地图重建
    lv.ensure_zone_owners(info, force=True)
    eq(lv.zone_owners[explicit_zid], str(info.zone_owners.get(explicit_zid, "")),
       "★★ force=True → 按地图整张重建（换地图用）")

    # 地图里不存在的区划号 → 载入补齐时清掉（地图改过区划后不留脏数据）
    lv.set_zone_owner(999999, "ZZ")
    ok(lv.ensure_zone_owners(info), "★ 清掉地图里不存在的区划号：算有改动")
    ok(999999 not in lv.zone_owners, "★★ 残留的旧区划号被清掉")

    # 写盘：zones[] 里是地图里的每一块地
    out = lv.to_dict()
    eq(len(out.get("zones", [])), len(info.zone_ids), "★ 导出写全每一块地")
    eq([e["id"] for e in out["zones"]], sorted(info.zone_ids), "★ 按区划号排序写出")

    # 地图缺失 → 不动（校验会报 map_not_found）
    ok(not M.LevelModel("n", "no_such_map").ensure_zone_owners(None),
       "★ 地图缺失 → 不补（留给校验报 map_not_found）")

    # ---- 载入集成：旧的关卡 JSON 没写 zones[] → load_campaign 自动补齐 ----
    info2 = maps(real=True)["dongzheng"]
    model = campaign_with(base_level(map="dongzheng", players=[], factions=[],
                                     zones=[], objectives=[], start_buildings=[]))
    lv_loaded = model.levels[0]
    eq(set(lv_loaded.zone_owners), set(info2.zone_ids),
       "★★ 载入旧关卡（zones 为空）→ 自动补全地图的每一块地")
    for zid in info2.zone_ids:
        eq(lv_loaded.zone_owners[zid], str(info2.zone_owners.get(zid, "")),
           "★ 载入补齐 c%d = 地图 owner / 空串" % zid)


def t_config_and_maps() -> None:
    print("\n[1b] 地图列表 / config 只读快照")
    info = levelfile.load_config(TMP_PROJECT)
    ok(set(["spearman", "longbowman", "rider"]) <= set(info.unit_types),
       "config：三个内置兵种都在（enemy 类型已删除），实际：%s" % info.unit_types)
    eq(info.general_types[:3], ["spearman", "longbowman", "rider"],
       "config：前三位将领的类型")
    eq(len(info.general_types), 10, "config：将领档位有 10 个（types 可以重复兵种）")
    # ★★ 开局附属兵**没有全局缺省**了：`config.json` 的 `unit.general.escort` 已被删掉，
    #    每个兵都在摆放页里摆出来（`start_units[].escort_of`）。
    #    这里反过来钉住它 —— 守卫「有人把那个全局开关加回来」这种回归。
    ok("escort" not in (info.raw.get("unit", {}).get("general", {}) or {}),
       "★★ config 的 unit.general 里**没有** escort（开局附属兵改在摆放页摆）")
    ok(not hasattr(info, "escort_count") and not hasattr(info, "escorts"),
       "★ 只读快照也不再提供「开局编制」那种字段")
    eq(info.building_types,
       ["base", "stone_wall", "tower", "wall", "watch_tower"],
       "config：五种建筑（按 id 排序）")
    eq(info.zone_kinds, ["food", "gold", "population"], "config：三种区划")
    ok("patrol_interval_sec" in info.ai_garrison_cfg, "config：阵地性 AI 的默认参数拿到了")
    ok("cooldown_sec" in info.ai_reddot_cfg, "config：红点性 AI 的默认参数拿到了")
    ok(info.faction_color("p1").lower() == "#ffd166", "config：阵营配色表")
    eq(info.general_label(1), "将领 1（长枪兵）", "将领下拉的写法")
    # ★★ 名册号与档位解耦：档位选项仍 1..3（= 将领类型数），名册号放宽到 1..10。
    eq(list(info.general_indices()), list(range(1, len(info.general_types) + 1)),
       "将领**档位**选项 = 1..将领类型数（当前 10）")
    eq(list(info.general_roster_indices()), list(range(1, 11)),
       "★★ 将领序号（名册号）放宽到 1..10（用户需求）")
    eq(info.general_profile_of("rider"), 2, "★ 兵种 rider = 第 3 档（0 起 2）")
    eq(info.general_profile_of("nope"), -1, "★ 不在将领档里的兵种 → -1")
    eq(M.general_kind_slot("general_5"), 4, "★ kind general_5 → 档位 4（旧数据兜底用）")
    eq(M.general_kind_slot("general_0"), 9, "★ kind general_0 → 档位 10（开局将领 #0）")
    # ★★ 显式档位优先于 unit_type：types 里重复兵种时，unit_type 只能取第一次出现。
    probe = M.UnitEntry("p1", "general", 0, 0)
    probe.unit_type = "rider"
    eq(M.general_profile_of_unit(probe, info), 3, "★ 旧数据：unit_type rider → 第 3 档")
    probe.general_profile = 7
    eq(M.general_profile_of_unit(probe, info), 7,
       "★★ 显式 general_profile 优先（能区分重复兵种的第 7 档）")
    probe.general_profile = None
    probe.unit_type = "nope"
    probe.kind = "general_5"
    eq(M.general_profile_of_unit(probe, info), 5, "★ 最后兜底：kind general_5 → 第 5 档")

    ms = maps(real=True)
    info = ms["dongzheng"]
    # ⚠️ 只要求「这几张在」—— 作者随时会往 data/maps/ 加新图，写死全集会假红。
    ok(set(["arena", "crossing", "dongzheng", "frontier"]) <= set(ms),
       "★ 四张地图全在（含 hidden 与 占位），实际：%s" % sorted(ms))
    ok(info.hidden, "★ dongzheng 带 hidden 标记（照样列出来）")
    ok(ms["arena"].placeholder, "★ arena 带 placeholder 标记（照样列出来）")
    ok(not ms["frontier"].hidden and not ms["frontier"].placeholder, "frontier 两个标记都没有")
    eq((info.cols, info.rows), (24, 18), "地图尺寸")
    ok(info.zone_ids and all(z in info.zone_centers for z in info.zone_ids), "每个区划都有中心")
    ok(info.zone_name(0), "区划有名字")
    eq(info.zone_label(0), info.zone_name(0),
       "★ 区划标签只用名字（不拼 cNN，免得自相矛盾）")
    eq(info.zone_label(999), "c999", "★ 没有名字的区划退回 c<id>")
    ok(info.walkable_at(*info.faction_base("F1")), "玩家大本营可通行")
    mountain = next((p for p, ch in info.terrain.items() if ch == "#"), None)
    ok(mountain is not None, "布局里有山地")
    ok(not info.walkable_at(*mountain), "★ 山地不可通行")
    ok(info.has_zone(0) and not info.has_zone(99), "区划存在性")
    eq(info.allies, [], "地图没有 allies")
    eq(ms["frontier"].allies, [["enemy", "ai"]], "frontier 的 allies 读到了")
    eq(levelfile.load_map(TMP_PROJECT, "不存在的图"), None, "★ 不存在的地图 → None（不崩）")
    # 地形字符与「可通行」的关系：山地 '#' 不可通行，森林 '^' 照走
    eq(info.terrain_at(*mountain), "#", "山地那一格的地形字符是 '#'")
    forests = [(x, y) for (x, y), ch in info.terrain.items() if ch == "^"]
    ok(forests, "布局里确实有森林 '^'")
    ok(all(info.walkable_at(x, y) for (x, y) in forests), "★ 森林可通行（只减速）")


# ======================================================================
# [2] 校验：16 条（+ 过载提示）—— 每条各造一个坏样例
# ======================================================================

def t_validation_pass() -> None:
    print("\n[2] 校验：合法基线必须一条拦截都没有")
    lv = base_level()
    issues = check(lv)
    eq(block_codes(issues), [], "★ 合法基线：0 条拦截")
    eq(warn_codes(issues), [], "★ 合法基线：0 条警告（进攻目标是**中立**区划，不触发第 14 条）")


def t_validation_map() -> None:
    print("\n[2.1] 校验 1：地图字段 / 地图存在")
    issues = check(base_level(map=""))
    ok(has(issues, "map_missing_field"), "★ 没写 map → map_missing_field（拦）")
    issues = check(base_level(map="不存在的图"))
    ok(has(issues, "map_not_found"), "★ 地图不存在 → map_not_found（拦）")
    ok(all(i.where.startswith("战役 ") for i in issues), "★ where 能定位到战役与关卡")


def t_validation_players() -> None:
    print("\n[2.2] 校验 2/3/4/5：可玩阵营数、同一阵营、没有大本营")
    f = FACTS
    # ★★ 判据是「可玩阵营」而不是「席位」：一个可玩阵营都没有 → players_empty
    issues = check(base_level(), playable=[])
    ok(has(issues, "players_empty"), "★ 一个可玩阵营都没有 → players_empty")
    # ★ 单人关**两个**可玩阵营 → 合法（选边关）—— 不再有 players_count_solo
    issues = check(base_level(), playable=[f.player, f.enemy])
    ok(not has(issues, "players_count_solo"), "★ 单人关两个可玩阵营 → 合法（选边关）")
    # ★ 合作关必须恰好两个可玩阵营
    issues = check(base_level(mode="coop"), playable=[f.player])
    ok(has(issues, "players_count_coop"), "★ 合作关一个可玩阵营 → players_count_coop")
    issues = check(base_level(mode="coop"), playable=[f.player, f.enemy, "丙"])
    ok(has(issues, "players_count_coop"), "★ 合作关三个可玩阵营 → players_count_coop")
    # ★ 「席位重复 / 没写 faction」是**防守性**检查：`players[]` 由可玩阵营派生
    #   （不会重复、也不会缺 faction），所以只能直接构造模型来验。
    model = campaign_with(base_level())
    model.levels[0].players.append({"faction": f.player, "base": None})
    issues = M.validate_campaign(model, maps())
    ok(has(issues, "players_same_faction"), "★ 两个席位同一阵营 → players_same_faction")
    model = campaign_with(base_level())
    model.levels[0].players.insert(0, {"faction": "", "base": None})
    issues = M.validate_campaign(model, maps())
    ok(has(issues, "player_no_faction"), "★ 席位没写 faction → player_no_faction")
    # ★★ 大本营只对**可玩阵营**要求（AI / NPC 不要求 —— 用户口径）。
    #   ① 可玩阵营（本关所属战役里 playable 的玩家方）在席位 / 关卡 / 地图上都没有大本营 → 拦
    issues = check(base_level(players=[{"faction": f.player}], factions=[]),
                   maps_override=maps_without_base(f.player))
    ok(has(issues, "faction_no_base"),
       "★ 可玩阵营没有大本营 → faction_no_base（拦）")
    #   ② 非可玩的一方（AI / NPC）没有大本营 → **不拦**
    issues = check(base_level(factions=[{"id": "幽灵军", "ai": "garrison"}],
                              start_buildings=[]))
    eq(block_codes(issues), [],
       "★★ AI 阵营没有大本营 → 不拦（只有可玩阵营必须配大本营）")
    #   ★ 反面：可玩阵营的大本营从**地图**来也认（关卡没写不拦）
    issues = check(base_level(players=[{"faction": f.player}], factions=[]))
    eq(block_codes(issues), [], "★★ 可玩阵营的 base 从地图来 → 不拦（覆盖规则）")


def maps_without_base(fid: str = None) -> dict:
    """一份把某个阵营的大本营抹掉的（内存里的）地图表 —— 不碰真文件。"""
    ms = maps()
    info = copy.deepcopy(ms[FACTS.map_id])
    info.faction_bases.pop(fid or FACTS.enemy, None)
    ms[FACTS.map_id] = info
    return ms


def t_validation_points() -> None:
    print("\n[2.3] 校验 5/6：压区划中心、山地、地图外")
    f = FACTS
    center = f.info.zone_centers[f.obj_zone]
    issues = check(base_level(players=[{"faction": f.player, "base": list(center)}],
                              start_buildings=[]))
    ok(has(issues, "point_on_zone_center"), "★ 大本营压在中心格 → point_on_zone_center")
    issues = check(base_level(factions=[{"id": f.enemy, "ai": "garrison",
                                         "base": list(f.mountain)}]))
    ok(has(issues, "point_on_mountain"), "★ 大本营在山地 → point_on_mountain")
    issues = check(base_level(factions=[{"id": f.enemy, "ai": "garrison",
                                         "base": list(f.water)}]))
    ok(has(issues, "point_on_mountain"), "★ 大本营在水域 → 同样被拦（不可通行）")
    issues = check(base_level(players=[{"faction": f.player, "base": [99, 99]}]))
    ok(has(issues, "point_outside"), "★ 大本营在地图外 → point_outside")
    issues = check(base_level(start_units=[{"faction": f.player, "kind": "spearman",
                                            "x": f.mountain[0], "y": f.mountain[1]}]))
    ok(has(issues, "point_on_mountain"), "★ 摆放单位在山地 → point_on_mountain")
    issues = check(base_level(start_buildings=[{"type": "tower", "x": center[0],
                                                "y": center[1], "owner": f.player}]))
    ok(has(issues, "point_on_zone_center"), "★ 摆放建筑压在中心格 → point_on_zone_center")
    issues = check(base_level(start_units=[{"faction": f.player, "kind": "spearman",
                                            "x": 99, "y": 99}]))
    ok(has(issues, "point_outside"), "★ 摆放单位在地图外 → point_outside")
    # ⚠️ 负坐标不是「地图外」，而是「没写」的哨兵值（逻辑层用 Vector2i(-1,-1) 表达它），
    #    所以它**不该**在这里报 —— 那一档归「必须有大本营」管。这条断言把口径钉住。
    issues = check(base_level(factions=[{"id": f.enemy, "ai": "garrison", "base": [-3, 4]}]))
    ok(not has(issues, "point_outside"), "★ 负坐标 = 「没写」的哨兵值，不报 point_outside")


def t_validation_sides() -> None:
    print("\n[2.4] 校验 7/8：可玩阵营同方、目标区划的开局归属")
    f = FACTS
    # ---- 7) 两个可玩阵营不互为盟友 → 拦（★ 必须有反例）----
    model = campaign_with(base_level(mode="coop",
                                     players=[{"faction": "F1", "base": list(f.player_base)},
                                              {"faction": "F2", "base": list(f.enemy_base)}]),
                          playable=["F1", "F2"])
    issues = M.validate_campaign(model, maps())
    ok(has(issues, "playable_not_same_side"),
       "★★ 两个可玩阵营不互为同方 → playable_not_same_side（拦）")
    # ★ 正面：同一份数据 + allies 声明 → 通过
    lv = model.levels[0]
    lv.allies_declared = True
    lv.allies = [["F1", "F2"]]
    issues = M.validate_campaign(model, maps())
    ok(not has(issues, "playable_not_same_side"),
       "★★ 声明它们互为盟友之后 → 第 7 条不再拦")
    # ★ 只有**一个**可玩阵营时不判（另一个只是战役里登记过）
    eq(block_codes(check(base_level())), [], "只有一个可玩阵营 → 第 7 条不触发")

    # ---- 8) 目标区划开局归属（★ 两种反例都要有）----
    issues = check(base_level(zones=[{"id": f.obj_zone, "owner": ""}]))
    ok(has(issues, "objective_unowned"),
       "★★ 目标区划开局无主（显式清空）→ objective_unowned（拦）")
    issues = check(base_level(zones=[{"id": f.obj_zone, "owner": f.enemy}]))
    ok(has(issues, "objective_not_players"),
       "★★ 目标区划开局归敌方 → objective_not_players（拦）")
    # ★★ 归**友军**（盟友）→ **不拦**（用户口径：「守住」任务只要区划属于己方**或友方**都可）
    #
    # 这一条是把「目标区划只能归玩家自己」放宽成「归玩家**同方**」的回归断言。
    # 样例战役第一关正是这个形状：c1 归与蓝方结盟的渡口守军（GD1），目标写「蓝方守住 c1」。
    # ⚠️ 判据只有一处：`_Sides.same_side()`（由 `allies` 建出来的连通分量）——
    #    它同时服务目标区划与额外失败条件那四条。
    issues = check(base_level(allies=[[f.player, "ALLY1"]],
                              zones=[{"id": f.obj_zone, "owner": "ALLY1"}]))
    ok(not has(issues, "objective_not_players"),
       "★★ 目标区划开局归**友军** → **不拦**（守住友军的地是合法设计）")
    ok(not has(issues, "objective_unowned"),
       "★ 而且也不算「无主」（它有主，只是主是盟友）")
    # 同一份数据但**没有**盟友声明 → 那就是敌人（区划 id 不在 present 里也照样拦）
    issues = check(base_level(zones=[{"id": f.obj_zone, "owner": "ALLY1"}]))
    ok(has(issues, "objective_not_players"),
       "★ 没声明盟友时同一份数据照旧拦（区别就在 allies 那一行上）")
    issues = check(base_level(objectives=[{"kind": "hold_zone", "zone": f.attack_zone,
                                          "hold_sec": 60}],
                              factions=[{"id": f.enemy, "ai": "garrison"}],
                              start_buildings=[]))
    ok(has(issues, "objective_unowned"),
       "★ 目标区划在地图上就没有归属（且关卡没覆盖）→ 也拦")
    # 地图自带归属、关卡一个字没写 → 用地图的（第 8 条放行）
    issues = check(base_level(objectives=[{"kind": "hold_zone", "zone": f.obj_zone,
                                          "hold_sec": 60}],
                              zones=[{"id": f.attack_zone, "owner": ""}]))
    ok(not has(issues, "objective_unowned") and not has(issues, "objective_not_players"),
       "★ 关卡没覆盖目标区划 → 用地图自带的归属（归玩家 → 放行）")


def t_validation_objectives() -> None:
    print("\n[2.5] 校验 9/11：目标恰好一项、失败条件的区划")
    f = FACTS
    issues = check(base_level(objectives=[]))
    ok(has(issues, "objective_empty"), "★ 没有目标 → objective_empty")
    issues = check(base_level(objectives=[{"kind": "hold_zone", "zone": f.obj_zone,
                                          "hold_sec": 60},
                                          {"kind": "hold_zone", "zone": f.obj_zone,
                                           "hold_sec": 60}]))
    ok(has(issues, "objective_too_many"), "★ 两个目标 → objective_too_many（第一版只支持一个）")
    issues = check(base_level(objectives=[{"kind": "kill_all", "zone": f.obj_zone,
                                          "hold_sec": 60}]))
    ok(has(issues, "objective_kind"), "★ 目标种类不认识 → objective_kind")
    issues = check(base_level(objectives=[{"kind": "hold_zone", "hold_sec": 60}]))
    ok(has(issues, "objective_no_zone"), "★ 目标没写 zone → objective_no_zone")
    issues = check(base_level(objectives=[{"kind": "hold_zone", "zone": 99, "hold_sec": 60}]))
    ok(has(issues, "objective_zone_missing"), "★ 目标区划不存在 → objective_zone_missing")
    issues = check(base_level(objectives=[{"kind": "hold_zone", "zone": f.obj_zone,
                                          "hold_sec": 0}]))
    ok(has(issues, "objective_hold_sec"), "★ 守住 0 秒 → objective_hold_sec")

    issues = check(base_level(fail_conditions=[{"kind": "lose_all", "zone": f.fail_zone}]))
    ok(has(issues, "fail_kind"), "★ 失败条件种类不认识 → fail_kind")
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost"}]))
    ok(has(issues, "fail_no_zone"), "★ 失败条件没写 zone → fail_no_zone")
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost", "zone": 99}]))
    ok(has(issues, "fail_zone_missing"), "★ 失败条件的区划不存在 → fail_zone_missing")
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost", "zone": f.obj_zone}]))
    ok(has(issues, "fail_zone_is_objective"),
       "★★ 失败条件的区划就是目标区划 → fail_zone_is_objective（拦）")
    # ★ 合法的一档：另一个**开局归玩家**的区划
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost", "zone": f.fail_zone}]))
    ok(not has(issues, "fail_zone_is_objective") and not has(issues, "fail_zone_unowned")
       and not has(issues, "fail_zone_not_players"),
       "★★ 换一个开局归玩家同方的区划 → 三条都不拦（合法）")

    # ---- ★★ 新增两条：失败条件的区划开局必须归玩家同方 ----
    # （与 objective_unowned / objective_not_players 是同一个坑的两面：
    #   `zone_lost` 的判据是「不再归玩家同方 ⇒ 立刻判负」，开局就不归玩家 = 第一帧就输。）
    # ① 开局无主：地图上那一区没写 owner，关卡也没覆盖
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost", "zone": f.attack_zone}]))
    ok(has(issues, "fail_zone_unowned"),
       "★★ 失败条件的区划开局无主 → fail_zone_unowned（拦，第一帧就判负）")
    # ② 开局归敌方（不是玩家的盟友）
    issues = check(base_level(zones=[{"id": f.own_zone, "owner": f.enemy},
                                     {"id": f.attack_zone, "owner": ""}],
                              fail_conditions=[{"kind": "zone_lost", "zone": f.own_zone}]))
    ok(has(issues, "fail_zone_not_players"),
       "★★ 失败条件的区划开局归敌方 → fail_zone_not_players（拦）")
    ok(not has(issues, "fail_zone_is_objective"),
       "★ 那一条仍然不是「等于目标区划」（两档别混）")
    # ③ 区划不存在那一档只报 fail_zone_missing（不叠着报归属问题）
    issues = check(base_level(fail_conditions=[{"kind": "zone_lost", "zone": 99}]))
    ok(not has(issues, "fail_zone_unowned") and not has(issues, "fail_zone_not_players"),
       "★ 区划不存在时只报 fail_zone_missing（一条数据只报一条）")
    # ④ 关卡的 zones[] 覆盖能把那一区**划回**玩家 → 放行
    issues = check(base_level(zones=[{"id": f.attack_zone, "owner": ""},
                                     {"id": f.own_zone, "owner": f.player}],
                              fail_conditions=[{"kind": "zone_lost", "zone": f.own_zone}]))
    ok(not has(issues, "fail_zone_unowned") and not has(issues, "fail_zone_not_players"),
       "★ 关卡 zones[] 里把它划给玩家 → 两条都不拦（覆盖规则生效）")
    # ⑤ 盟友算同方：把敌人加成玩家的盟友 → 那一区归敌人也不再拦
    issues = check(base_level(zones=[{"id": f.own_zone, "owner": f.enemy},
                                     {"id": f.attack_zone, "owner": ""}],
                              allies=[[f.player, f.enemy]],
                              fail_conditions=[{"kind": "zone_lost", "zone": f.own_zone}]))
    ok(not has(issues, "fail_zone_not_players"),
       "★★ 开局归属方是玩家的**盟友** → 算同方，两条都不拦")


def t_validation_attack_target() -> None:
    print("\n[2.6] 校验 10/14/15/16：进攻目标与盟友")
    f = FACTS
    with_faction = lambda entry: base_level(factions=[entry], start_buildings=[])   # noqa: E731

    def enemy_entry(**over) -> dict:
        data = {"id": f.enemy, "ai": "reddot", "base": list(f.enemy_base)}
        data.update(over)
        return data

    issues = check(with_faction(enemy_entry(attack_target={"kind": "zone", "zone": 99})))
    ok(has(issues, "attack_target_zone"), "★ 进攻目标区划不存在 → attack_target_zone")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "point", "x": 999,
                                                           "y": 999})))
    ok(has(issues, "attack_target_outside"), "★ 进攻目标在地图外 → attack_target_outside")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "point",
                                                           "x": f.mountain[0],
                                                           "y": f.mountain[1]})))
    ok(has(issues, "attack_target_mountain"), "★ 进攻目标在山地 → attack_target_mountain")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "moon"})))
    ok(has(issues, "attack_target_kind"), "★ 进攻目标种类不认识 → attack_target_kind")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "base",
                                                           "faction": "不带家的军"})))
    ok(has(issues, "attack_target_base"), "★ 指向「某方的家」但那一方没有大本营 → attack_target_base")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "base",
                                                           "faction": f.player})))
    ok(not has(issues, "attack_target_base"), "★ 指向玩家的大本营（它有）→ 放行")
    issues = check(with_faction(enemy_entry(attack_target="4")))
    ok(has(issues, "attack_target_shape"),
       "★★ 进攻目标写成字符串（不是对象）→ attack_target_shape")
    issues = check(with_faction(enemy_entry()))
    ok(has(issues, "no_attack_target", M.SEV_WARN),
       "★ 挂着阵营 AI 但一个都没写目标 → 警告 no_attack_target")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "zone",
                                                           "zone": f.own_zone})))
    ok(has(issues, "attack_target_own_land", M.SEV_WARN),
       "★ 进攻目标指向自己占的区划 → 警告 attack_target_own_land")
    issues = check(with_faction(enemy_entry(attack_target={"kind": "zone",
                                                           "zone": f.attack_zone})))
    ok(not has(issues, "attack_target_own_land", M.SEV_WARN),
       "★ 指向中立区划 → 不警告")
    issues = check(base_level(allies=[[f.player, "zz"]]))
    ok(has(issues, "ally_unknown", M.SEV_WARN), "★ allies 里有未定义的阵营 → 警告 ally_unknown")


def t_validation_units_and_factions() -> None:
    print("\n[2.7] 校验 12/13：摆放里的将领性 AI 与阵营定义")
    f = FACTS
    # 摆放点：别压在区划中心上（那是另一条规则），随便挑一格可通行的平地
    spot = next((x, y) for (x, y) in sorted(f.info.walkable)
                if (x, y) not in f.centers)
    issues = check(base_level(start_units=[{"faction": f.enemy, "kind": "general",
                                            "x": spot[0], "y": spot[1], "ai": "general"}]))
    ok(has(issues, "unit_general_no_zone"), "★ 将领性 AI 没有 zone → unit_general_no_zone")
    issues = check(base_level(start_units=[{"faction": f.enemy, "kind": "general",
                                            "x": spot[0], "y": spot[1],
                                            "ai": "general", "zone": f.attack_zone}]))
    ok(not has(issues, "unit_general_no_zone"), "★ 带了 zone → 不拦")
    issues = check(base_level(start_units=[{"kind": "enemy", "x": spot[0], "y": spot[1]}]))
    ok(has(issues, "unit_no_faction"), "★ 摆放单位没写 faction → unit_no_faction")
    issues = check(base_level(start_units=[{"faction": "zz", "kind": "enemy",
                                            "x": spot[0], "y": spot[1]}]))
    ok(has(issues, "faction_unknown"), "★ 摆放单位引用了没定义的阵营 → faction_unknown")
    issues = check(base_level(start_buildings=[{"type": "tower", "x": spot[0], "y": spot[1],
                                                "owner": "zz"}]))
    ok(has(issues, "faction_unknown"), "★ 摆放建筑引用了没定义的阵营 → faction_unknown")


def t_validation_overload() -> None:
    print("\n[2.8] 红点 AI：缺省行军目标 → 警告（旧的 overload_hint 已随阵营 AI 删除）")
    f = FACTS
    entry = {"id": f.enemy, "ai": "reddot", "base": list(f.enemy_base)}
    issues = check(base_level(factions=[entry], start_buildings=[]))
    ok(has(issues, "no_attack_target", M.SEV_WARN),
       "★ 红点 AI 没写行军目标 → 警告 no_attack_target")
    ok(not has(issues, "overload_hint", M.SEV_WARN),
       "★ 旧的 overload_hint 已随阵营 AI 删除（不再出现）")
    entry2 = {"id": f.enemy, "ai": "reddot", "base": list(f.enemy_base),
              "attack_target": {"kind": "zone", "zone": f.attack_zone}}
    issues = check(base_level(factions=[entry2], start_buildings=[]))
    ok(not has(issues, "no_attack_target", M.SEV_WARN),
       "★ 红点 AI 写了行军目标 → 不再警告")

    # ★★ `reddot_ai.march_tiles`（多格行军目标，运行时每位将领随机挑一格）
    entry3 = {"id": f.enemy, "ai": "reddot", "base": list(f.enemy_base),
              "reddot_ai": {"march_tiles": [[f.spot[0], f.spot[1]]]}}
    issues = check(base_level(factions=[entry3], start_buildings=[]))
    ok(not has(issues, "no_attack_target", M.SEV_WARN),
       "★ 红点写了 `march_tiles` → 也算写了目标（不再警告）")
    ok(not has(issues, "reddot_march_tile_invalid"), "★ 合法的行军目标格 → 不拦")
    issues = check(base_level(factions=[{"id": f.enemy, "ai": "reddot",
                                         "base": list(f.enemy_base),
                                         "reddot_ai": {"march_tiles": [[99, 99]]}}],
                              start_buildings=[]))
    ok(has(issues, "reddot_march_tile_invalid"),
       "★ 行军目标在地图外 → reddot_march_tile_invalid（拦）")
    issues = check(base_level(factions=[{"id": f.enemy, "ai": "reddot",
                                         "base": list(f.enemy_base),
                                         "reddot_ai": {"march_tiles": [list(f.mountain)]}}],
                              start_buildings=[]))
    ok(has(issues, "reddot_march_tile_invalid"),
       "★ 行军目标在山上 → reddot_march_tile_invalid（拦）")
    model = campaign_with(base_level(factions=[entry3], start_buildings=[]))
    out = model.levels[0].to_dict()["factions"][0]
    eq(out.get("reddot_ai", {}).get("march_tiles"), [[f.spot[0], f.spot[1]]],
       "★ `march_tiles` 原样写进 JSON（往返保留）")


def t_validation_faction_color() -> None:
    """★★ 校验 18：**自定义阵营必须有配色**（否则游戏里整场一片紫）。

    这是玩家实测报回来的：战役用自己的阵营 id（`F1`/`E1`），而引擎的配色表里只有
    内置 id（p1~p8/enemy/ai）—— 没写 color 的阵营会退到 `Color.MAGENTA`，
    画面上就是「整个战场一片紫、敌我分不清」，而且**游戏不报错**。
    """
    print("\n[2.9] 校验 18：阵营配色（不写就是品红）")
    f = FACTS
    # 前提：内置配色表里的 id 已知。
    # ⚠️ 合成地图是直接 `MapInfo(...)` 造的（没走 `list_maps()`），所以它身上
    #    `builtin_factions` 是空的 —— 这里按真配置补上，等价于 `list_maps()` 做的事。
    f.info.builtin_factions = {str(k) for k in
                               M.load_config(PROJECT_DIR).colors.get("faction", {}).keys()}
    ok("p1" in f.info.builtin_factions and f.enemy not in f.info.builtin_factions,
       "（前提）内置配色表里有 p1、没有自定义的 %s" % f.enemy)

    # ---- 不写 color 的自定义阵营 → 警告 ----
    # ⚠️ 必须用一个**测试没给它补颜色**的新 id：`campaign_with()` 会给 A1/B1
    #    补上默认颜色（等价于旧 campaign.json 那一份），拿 B1 来测测不出这一条。
    entry = {"id": "Z9", "ai": "garrison", "base": list(f.enemy_base)}
    issues = check(base_level(factions=[entry], start_buildings=[]))
    ok(has(issues, "faction_no_color", M.SEV_WARN),
       "★★ 自定义阵营没写颜色 → 警告 faction_no_color")
    eq(block_codes(issues), [],
       "★ 它是**警告不是拦截**（老战役数据不该因为这个导不出去）")
    ok("品红" in "".join(i.msg for i in M.warnings(issues)), "警告文案点明了后果（品红）")

    # ---- 关卡里写了 color → 不警告 ----
    entry2 = dict(entry, color="#e05a5a")
    issues = check(base_level(factions=[entry2], start_buildings=[]))
    ok(not has(issues, "faction_no_color", M.SEV_WARN), "★ 关卡 factions[] 写了 color → 不警告")

    # ---- 旧格式（campaign.json 有 factions[]）：颜色 / 名字迁移进关卡 ----
    #   `adopt_legacy_factions()` 会把旧表的 color 抄进关卡 factions[]，于是不再警告。
    model = campaign_with(base_level(factions=[{"id": "Z9", "ai": "garrison",
                                                 "base": list(f.enemy_base)}],
                                     start_buildings=[]),
                          legacy_factions=[{"id": "Z9", "name": "旧阵营",
                                            "color": "#123456", "playable": False}])
    issues = M.validate_campaign(model, maps())
    ok(not has(issues, "faction_no_color", M.SEV_WARN),
       "★ 旧 campaign.json 的颜色迁移进关卡后 → 不警告")
    eq(model.levels[0].faction("Z9").name, "旧阵营", "★ 旧表的名字也迁移进来了")
    ok(not model.to_dict().get("factions"), "★★ 保存时不再写 campaign.json 的 factions[]")

    # ---- 内置 id 不写也不警告（p1 本来就有颜色）----
    entry3 = {"id": "p1", "ai": "none", "base": list(f.player_base)}
    issues = check(base_level(factions=[entry3], start_buildings=[]))
    ok(not has(issues, "faction_no_color", M.SEV_WARN),
       "★ 内置阵营 id（p1）不写 color 也不警告（它本来就有颜色）")


# ======================================================================
# [3] AI 指派 / 进攻目标 / 目标与失败条件 的往返
# ======================================================================

def t_ai_assignment_roundtrip() -> None:
    print("\n[3] AI 指派：garrison / reddot / commander / none 能存能读；旧值归一；玩家席位也能配 AI")
    f = FACTS
    for ai in ("garrison", "reddot", "commander", "none"):
        data = base_level(factions=[{"id": f.enemy, "ai": ai, "base": list(f.enemy_base),
                                     "attack_target": {"kind": "zone", "zone": f.attack_zone}}])
        model = campaign_with(data)
        eq(model.levels[0].faction(f.enemy).ai, ai, "★ ai=%s 读得回来" % ai)
        eq(model.levels[0].to_dict()["factions"][0]["ai"], ai, "★ ai=%s 写得出去" % ai)
        same, diffs = levelfile.roundtrip_ok(model, TMP_ROOT / ("rt_%s" % ai), TMP_PROJECT)
        ok(same, "★ ai=%s 往返一致%s" % (ai, "" if same else "：%s" % diffs[:3]))

    # ★ 旧值 faction / general 归一成 garrison（兼容老关卡数据）
    for legacy in ("faction", "general"):
        model = campaign_with(base_level(factions=[{"id": f.enemy, "ai": legacy,
                                                    "base": list(f.enemy_base)}]))
        eq(model.levels[0].faction(f.enemy).ai, "garrison",
           "★ 旧值 ai=%s → 归一成 garrison" % legacy)

    # ★★ 不可玩的 AI 对手也占一个**席位**（ai_test_battle：p2 玩家 / p1 commander AI）。
    #    编辑器保存时必须保住它，否则「一保存 AI 对手就没了」。
    data = base_level(factions=[{"id": f.player, "ai": "none", "base": list(f.player_base),
                                 "playable": True},
                                {"id": f.enemy, "ai": "commander", "base": list(f.enemy_base),
                                 "playable": False}],
                      players=[{"faction": f.player}, {"faction": f.enemy}])
    model = campaign_with(data, playable=[f.player])
    lv = model.levels[0]
    eq(lv.seats(), [f.player, f.enemy], "★★ 非可玩的 commander AI 也留在 players[] 里")
    eq(lv.playable_ids(), [f.player], "★★ 但它不是可玩阵营（玩家只能选 p2）")
    eq(lv.to_dict()["players"], [{"faction": f.player}, {"faction": f.enemy}],
       "★★ 导出时 AI 席位原样带回")
    same, diffs = levelfile.roundtrip_ok(model, TMP_ROOT / "ai_seat_rt", TMP_PROJECT)
    ok(same, "★★ 带 AI 席位的关卡往返一致%s" % ("" if same else "：%s" % diffs[:3]))

    data = base_level(factions=[{"id": f.player, "ai": "garrison", "base": list(f.player_base),
                                 "attack_target": {"kind": "zone", "zone": f.attack_zone}},
                                {"id": f.enemy, "ai": "reddot", "base": list(f.enemy_base),
                                 "attack_target": {"kind": "zone", "zone": f.attack_zone}}],
                      players=[{"faction": f.player, "base": list(f.player_base)}])
    issues = check(data)
    eq(block_codes(issues), [], "★★ 给可玩阵营配 AI → 不拦（运行时按席位摘掉）")
    model = campaign_with(data)
    eq(model.levels[0].faction(f.player).ai, "garrison", "★ 玩家席位那一方的 ai 也存得住")

    # ★ 「关卡没写 ai」与「写了 ai:none」在数据里是两件事
    model = campaign_with(base_level(factions=[{"id": f.enemy, "ai": "none"}]))
    eq(model.levels[0].faction(f.enemy).ai, "none", "★ 写了 ai:none 读得回来")
    model = campaign_with(base_level(factions=[{"id": f.enemy}]))
    eq(model.levels[0].faction(f.enemy).ai, "none",
       "★ 没写 ai → 默认 none（「不动」；运行时才区分「没写」与「写了 none」）")
    model = campaign_with(base_level(factions=[{"id": f.enemy, "ai": "不认识"}]))
    eq(model.levels[0].faction(f.enemy).ai, "none", "★ 不认识的 ai → 退回 none（宽容）")


def t_attack_target_roundtrip() -> None:
    print("\n[3b] 进攻目标：四种 kind 的往返 + 缺省不落字段")
    f = FACTS
    spot = next((x, y) for (x, y) in sorted(f.info.walkable) if (x, y) not in f.centers)
    specs = [
        {"kind": "zone", "zone": f.attack_zone},
        {"kind": "point", "x": spot[0], "y": spot[1]},
        {"kind": "building", "x": spot[0], "y": spot[1]},
        {"kind": "base", "faction": f.player},
    ]
    for spec in specs:
        data = base_level(factions=[{"id": f.enemy, "ai": "garrison", "base": list(f.enemy_base),
                                     "attack_target": spec}])
        model = campaign_with(data)
        got = model.levels[0].faction(f.enemy).attack_target
        eq(got, spec, "★ kind=%s 读得回来" % spec["kind"])
        eq(model.levels[0].to_dict()["factions"][0]["attack_target"], spec,
           "★ kind=%s 写得出去" % spec["kind"])
        same, diffs = levelfile.roundtrip_ok(model, TMP_ROOT / ("tgt_%s" % spec["kind"]),
                                            TMP_PROJECT)
        ok(same, "★ kind=%s 往返一致%s" % (spec["kind"], "" if same else "：%s" % diffs[:3]))

    model = campaign_with(base_level(factions=[{"id": f.enemy, "ai": "garrison",
                                                "base": list(f.enemy_base)}]))
    eq(model.levels[0].faction(f.enemy).attack_target, None, "★ 缺省 = None")
    ok("attack_target" not in model.levels[0].to_dict()["factions"][0],
       "★★ 缺省时**一个字段都不落**（运行时退回「打最近的敌方区划」）")

    issues = check(base_level(factions=[{"id": f.enemy, "ai": "garrison",
                                         "base": list(f.enemy_base),
                                         "attack_target": {"kind": "zone", "zone": 42}}]))
    ok(has(issues, "attack_target_zone"), "★ 引用不存在的区划被拦")


def t_escort_placement() -> None:
    print("\n[3b2] 附属部队：摆在 start_units 里 + escort_of 绑定将领 + 往返")
    f = FACTS
    data = base_level(start_units=[
        {"faction": f.enemy, "kind": "general", "general_index": 1, "x": f.enemy_base[0],
         "y": f.enemy_base[1], "name": "主将"},
        {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1],
         "escort_of": 1, "name": "兵 1"},
    ])
    model = campaign_with(data)
    lv = model.levels[0]
    gen = M.general_with_index(lv, f.enemy, 1)
    ok(gen is not None and gen.is_general(), "★ 按「将领序号」找得到那位将领")
    squad = M.escorts_of(lv, f.enemy, 1)
    eq(len(squad), 1, "★★ escorts_of 数出「属于第 1 位将领」的兵")
    eq(squad[0].unit_type if squad else "", "", "（不必有 unit_type）")
    eq(M.escorts_of(lv, f.enemy, 2), [], "★ 第 2 位将领名下没有兵")
    ok(M.faction_has_placed_escorts(lv, f.enemy), "★★ 这一方被判定为「摆了附属部队」")
    ok(not M.faction_has_placed_escorts(lv, f.player), "★ 另一方没有")
    eq(len(M.placed_generals(lv, f.enemy)), 1, "★ 数得出摆了 1 位将领")

    # 导出：`escort_of` 只写在真的是附属兵的那一项上
    out = lv.to_dict()["start_units"]
    escorts = [u for u in out if u.get("escort_of")]
    eq(len(escorts), 1, "★★ 导出时只有附属兵带 escort_of")
    eq(escorts[0].get("escort_of"), 1, "★ 归属将领序号写对了")
    eq([u for u in out if u.get("kind") == "general"][0].get("escort_of"), None,
       "★ 将领自己没有这个键")
    same, diffs = levelfile.roundtrip_ok(model, TMP_ROOT / "escort_rt", TMP_PROJECT)
    ok(same, "★★ 带附属部队的关卡往返逐字段一致%s" % ("" if same else "：%s" % diffs[:3]))

    # 没摆 = 不是附属兵（不写这个键）
    model = campaign_with(base_level(start_units=[
        {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1]}]))
    eq(model.levels[0].start_units[0].escort_of, -1, "★ 没写 escort_of = -1（普通摆放单位）")
    ok("escort_of" not in model.levels[0].to_dict()["start_units"][0],
       "★ 缺省不落这个键（老关卡一个字节都不变）")
    ok(not M.faction_has_placed_escorts(model.levels[0], f.enemy),
       "★ 没摆附属兵 → 运行时照样自动生成将领")

    # ★★ 将领档位 general_profile：读写往返（types 里重复兵种时靠它区分 4..10 档）
    model = campaign_with(base_level(start_units=[
        {"faction": f.enemy, "kind": "general", "general_index": 1,
         "general_profile": 4, "unit_type": "spearman",
         "x": f.enemy_base[0], "y": f.enemy_base[1]}]))
    lv = model.levels[0]
    eq(lv.start_units[0].general_profile, 4, "★★ 读盘：general_profile = 4")
    out = lv.to_dict()["start_units"][0]
    eq(out.get("general_profile"), 4, "★★ 写盘：general_profile 原样带出去")
    same, diffs = levelfile.roundtrip_ok(model, TMP_ROOT / "general_profile_rt", TMP_PROJECT)
    ok(same, "★★ 带 general_profile 的关卡往返一致%s" % ("" if same else "：%s" % diffs[:3]))


def t_validation_escort_links() -> None:
    print("\n[3b3] 校验：附属部队的归属（没队长 / 将领当兵 / 序号重复）")
    f = FACTS
    gen = {"faction": f.enemy, "kind": "general", "general_index": 1,
           "x": f.enemy_base[0], "y": f.enemy_base[1]}

    # 1) 有队长 → 通过
    issues = check(base_level(start_units=[
        dict(gen), {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1],
                    "escort_of": 1}]))
    eq(block_codes(issues), [], "★ 有对应将领 → 0 条拦截")

    # 2) 没有那位将领 → 拦
    issues = check(base_level(start_units=[
        dict(gen), {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1],
                    "escort_of": 2}]))
    ok(has(issues, "escort_no_general"),
       "★★ escort_of 指向不存在的将领序号 → 拦截（它进游戏没有队长）")

    # 3) 一个将领都没摆，却有附属兵 → 拦 + 警告
    issues = check(base_level(start_units=[
        {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1],
         "escort_of": 1}]))
    ok(has(issues, "escort_no_general"), "★★ 一个将领都没摆 → 拦截")
    ok(has(issues, "escort_faction_no_general", M.SEV_WARN),
       "★★ 并且警告「这一方被运行时整个接管，连将领都不自动生成」")

    # 4) 将领自己挂了 escort_of → 拦
    issues = check(base_level(start_units=[
        dict(gen, escort_of=1)]))
    ok(has(issues, "escort_is_general"), "★ 将领当别人的附属兵 → 拦截")

    # 5) 两位将领同一个序号 → 拦（兵的归属不确定）
    issues = check(base_level(start_units=[
        dict(gen), dict(gen, x=f.spot[0], y=f.spot[1]),
        {"faction": f.enemy, "kind": "spearman", "x": f.enemy_base[0], "y": f.enemy_base[1],
         "escort_of": 1}]))
    ok(has(issues, "general_index_dup"), "★★ 两位将领同一个将领序号 → 拦截")


def t_ordered_start_units() -> None:
    print("\n[3b4] 导出顺序：将领必须排在它自己的兵前面（运行时的硬约定）")
    f = FACTS
    # 故意「先摆兵、后摆将」，看导出会不会排回来
    lv_data = base_level(start_units=[
        {"faction": f.enemy, "kind": "spearman", "x": f.spot[0], "y": f.spot[1],
         "escort_of": 1, "name": "兵 1"},
        {"faction": f.enemy, "kind": "general", "general_index": 1,
         "x": f.enemy_base[0], "y": f.enemy_base[1], "name": "主将"},
        {"faction": f.player, "kind": "enemy", "x": f.spot[0], "y": f.spot[1],
         "name": "散兵"},
    ])
    model = campaign_with(lv_data)
    out = model.levels[0].to_dict()["start_units"]
    kinds = [str(u.get("kind")) for u in out]
    ok(kinds.index("general") < kinds.index("spearman"),
       "★★ 导出时将领排在它自己的兵前面（源文件里是先兵后将）：%s" % kinds)
    eq(len(out), 3, "★ 一个都不多、一个都不少")
    eq([u.get("name") for u in out if u.get("kind") == "enemy"], ["散兵"],
       "★ 散兵照旧带出去")


def t_ordering() -> None:
    print("\n[3c] 关卡的新增 / 删除 / 排序")
    model = levelfile.load_campaign(tmp_campaign_dir(), TMP_PROJECT)
    ids = [lv.level_id for lv in model.levels]
    ok(len(ids) >= 2, "（前提）样例战役至少两关")
    first, second = ids[0], ids[1]
    last_orig = ids[-1]                 # 原有关卡里最后一个（99 会被追加在它后面）
    lv = model.new_level("99_last_stand", FACTS.map_id)
    eq([x.level_id for x in model.levels], ids + ["99_last_stand"], "★ new_level 追加到末尾")
    eq(lv.map_id, FACTS.map_id, "★ 新关卡记住了地图")
    eq(lv.mode, model.default_mode, "★ 新关卡的模式 = 战役的 default_mode")
    eq(lv.file, "levels/99_last_stand.json", "★ 新关卡的默认文件路径")
    # id 撞车 → 自动加后缀（不然两关会写同一个文件）
    dup = model.new_level("99_last_stand", FACTS.map_id)
    ok(dup.level_id != "99_last_stand", "★ id 撞车 → 自动改名（%s）" % dup.level_id)
    model.remove_level(dup.level_id)

    ok(model.move_level("99_last_stand", -1), "★ 上移成功")
    eq([x.level_id for x in model.levels][-1], last_orig, "★ 上移之后它在原来那一关前面")
    ok(model.move_level("99_last_stand", 1), "★ 下移成功")
    eq([x.level_id for x in model.levels][-1], "99_last_stand", "★ 下移回到末尾")
    ok(not model.move_level(first, -1), "★ 第一关再上移 → 不动（返回 False）")
    ok(not model.move_level("不存在的关", 1), "★ 不存在的关卡 → False")
    ok(model.remove_level("99_last_stand"), "★ 删除成功")
    ok(not model.remove_level("99_last_stand"), "★ 再删一次 → False")
    eq([x.level_id for x in model.levels], ids, "★ 删完回到原来的关卡")

    # 顺序会写进 campaign.json（只钉前两关的先后，后面可能还有别的关）
    model.move_level(second, -1)
    eq([str(e["id"]) for e in model.to_dict()["levels"]],
       [second, first] + ids[2:], "★★ 关卡顺序写进 campaign.json 的 levels[]")


def t_preserved_unknown_fields() -> None:
    print("\n[4] 未知字段 / 宽容度（不冒泡、不丢字段）")
    data = base_level()
    data["future_thing"] = {"keep": [1, 2, 3]}
    data["another"] = "原样带回"
    model = campaign_with(data)
    eq(model.levels[0].preserved.get("future_thing"), {"keep": [1, 2, 3]}, "★ 未知字段进 preserved")
    out = model.levels[0].to_dict()
    eq(out.get("future_thing"), {"keep": [1, 2, 3]}, "★ 导出时原样写回")
    eq(out.get("another"), "原样带回", "★ 未知字段（字符串）也写回")

    # 坏项被丢掉，而不是让整关读不出来
    data = base_level(factions=[{"id": FACTS.enemy, "ai": "garrison",
                                 "base": list(FACTS.enemy_base)},
                                {"ai": "garrison"},                 # 没有 id → 丢
                                "不是对象"],                        # 不是对象 → 丢
                      players=[{"faction": FACTS.player, "base": list(FACTS.player_base)},
                               {"base": [1, 1]},                   # 没有 faction → 丢
                               "x"])
    model = campaign_with(data)
    eq([e.fid for e in model.levels[0].factions], [FACTS.enemy, FACTS.player],
       "★ 没有 id 的阵营项被丢掉（席位那一方照旧补成可玩阵营）")
    eq(model.levels[0].seats(), [FACTS.player],
       "★ 没有 faction 的席位项被丢掉（否则席位顺序会串）")
    data = base_level(start_units=[{"faction": FACTS.enemy, "x": 3, "y": 3},   # 没有 kind → 丢
                                   {"faction": FACTS.enemy, "kind": "enemy", "x": 4, "y": 4}])
    model = campaign_with(data)
    eq(len(model.levels[0].start_units), 1, "★ 没有 kind 的摆放项被丢掉")
    data = base_level(start_buildings=[{"x": 3, "y": 3},                   # 没有 type → 丢
                                       {"type": "tower", "x": FACTS.player_base[0],
                                        "y": FACTS.player_base[1], "owner": FACTS.player}])
    model = campaign_with(data)
    eq(len(model.levels[0].start_buildings), 1, "★ 没有 type 的摆放项被丢掉")

    # 缺 levels[] → 退化成扫 levels/ 目录（老 / 手写战役）
    root = tmp_campaign_dir() / "_scan"
    shutil.rmtree(root, ignore_errors=True)
    (root / "levels").mkdir(parents=True, exist_ok=True)
    write_level(base_level(), "case", root)
    (root / "campaign.json").write_text(json.dumps(
        {"name": "没有 levels[]", "factions": [{"id": "F1", "playable": True}]},
        ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    model = levelfile.load_campaign(root, TMP_PROJECT)
    eq([lv.level_id for lv in model.levels], ["case"], "★ 没写 levels[] → 扫 levels/ 目录兜底")
    eq(model.name, "没有 levels[]", "战役名读到了")
    eq(model.unlock, "in_order", "★ 没写 unlock → 默认 in_order")


# ======================================================================
# [5] 坏输入 / 新建
# ======================================================================

def t_bad_input() -> None:
    print("\n[5] 坏输入：说清楚，而不是静默崩")
    bad = TMP_ROOT / "bad"
    bad.mkdir(parents=True, exist_ok=True)
    broken = bad / "broken.json"
    broken.write_text("{ 这不是 json }", encoding="utf-8")
    raises(lambda: levelfile.load_level(broken, TMP_PROJECT),
           "★ 坏 JSON → ModelError（说清楚，不静默）")
    try:
        levelfile.load_level(broken, TMP_PROJECT)
    except M.ModelError as exc:
        ok("不是合法 JSON" in str(exc), "错误信息说了「不是合法 JSON」：%s" % exc)
    raises(lambda: levelfile.load_level(bad / "nope.json", TMP_PROJECT),
           "★ 关卡文件不存在 → ModelError")
    arr = bad / "array.json"
    arr.write_text("[1, 2, 3]", encoding="utf-8")
    raises(lambda: levelfile.load_level(arr, TMP_PROJECT),
           "★ 根不是对象 → ModelError")
    raises(lambda: levelfile.load_campaign(bad / "没有这个目录", TMP_PROJECT),
           "★ 战役目录不存在 → ModelError")
    empty = bad / "empty_campaign"
    empty.mkdir(parents=True, exist_ok=True)
    raises(lambda: levelfile.load_campaign(empty, TMP_PROJECT),
           "★ 目录里没有 campaign.json → ModelError")
    # 目录被删
    gone = tmp_campaign_dir()
    shutil.rmtree(gone, ignore_errors=True)
    raises(lambda: levelfile.load_campaign(gone, TMP_PROJECT),
           "★ 战役目录被删 → ModelError（不是静默返回空模型）")
    # 带 BOM 的关卡要能读（Windows 记事本很常见）
    bom = bad / "bom.json"
    bom.write_text(json.dumps(base_level(), ensure_ascii=False), encoding="utf-8-sig")
    lv = levelfile.load_level(bom, TMP_PROJECT)
    eq(lv.map_id, FACTS.map_id, "★ 带 BOM 的关卡照样能读（utf-8-sig）")
    # 战役里有一关读不出来 → 跳过它，但整个战役照样载入（照 campaign.gd 的宽容度）
    root = tmp_campaign_dir() / "_broken"
    shutil.rmtree(root, ignore_errors=True)
    (root / "levels").mkdir(parents=True, exist_ok=True)
    write_level(base_level(), "good", root)
    (root / "levels" / "broken.json").write_text("{坏}", encoding="utf-8")
    (root / "campaign.json").write_text(json.dumps({
        "name": "有一关坏了",
        "levels": [{"id": "good", "file": "levels/good.json"},
                   {"id": "broken", "file": "levels/broken.json"}]},
        ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    model = levelfile.load_campaign(root, TMP_PROJECT)
    eq([lv.level_id for lv in model.levels], ["good"], "★ 读不出来的那一关被跳过，别的照旧")
    # 一关都没有 → 抛（与 campaign.gd 的「返回 null」等价）
    root2 = bad / "no_levels"
    root2.mkdir(parents=True, exist_ok=True)
    (root2 / "campaign.json").write_text('{"name": "空战役"}', encoding="utf-8")
    raises(lambda: levelfile.load_campaign(root2, TMP_PROJECT),
           "★ 一关都没有的战役 → ModelError")


def t_new_campaign() -> None:
    print("\n[5b] 新建战役 / 保存")
    target = TMP_ROOT / "newproj"
    shutil.rmtree(target, ignore_errors=True)
    setup_like = target / "data"
    setup_like.mkdir(parents=True, exist_ok=True)
    shutil.copytree(REAL_MAPS, setup_like / "maps")
    shutil.copyfile(REAL_CONFIG, setup_like / "config.json")
    (setup_like / "campaigns").mkdir(parents=True, exist_ok=True)

    model, written = levelfile.create_campaign(target, "brand_new", "新战役", "dongzheng")
    eq(model.campaign_id, "brand_new", "新建战役的 id")
    eq(model.name, "新战役", "新建战役的名字")
    eq(len(model.levels), 1, "★ 新建战役顺手建一关（一关都没有的战役读不出来）")
    ok(all(Path(p).exists() for p in written), "★ 写过的文件都真的在盘上")
    ok((target / "data" / "campaigns" / "brand_new" / "campaign.json").is_file(),
       "campaign.json 在")
    ok((target / "data" / "campaigns" / "brand_new" / "levels").is_dir(), "levels/ 建好了")
    back = levelfile.load_campaign(target / "data" / "campaigns" / "brand_new", target)
    eq(back.name, "新战役", "★ 新建的战役能立刻读回来")
    eq(back.levels[0].map_id, "dongzheng", "第一关的地图")
    raises(lambda: M.new_campaign(target, ""), "★ 空 id 被拒")
    raises(lambda: M.new_campaign(target, "a/b"), "★ 带路径分隔符的 id 被拒")
    # 新建的战役**还没填**，所以它必然有拦截项 —— 但那必须是**能说清楚**的拦截
    issues = M.validate_campaign(back, levelfile.maps_by_id(target))
    ok(len(M.blockers(issues)) > 0, "★ 新建的战役还没填完 → 有拦截项（免得作者以为已经能导）")
    ok(all(i.where and i.msg for i in issues), "★ 每条拦截都带 where 与 msg")
    # 存档：save_campaign 返回写过的路径
    again = levelfile.save_campaign(back)
    ok(len(again) == 1 + len(back.levels), "★ save_campaign 写了 campaign.json + 每一关")
    # 越界路径要挡住（源 JSON 里的 file 是别人写的字符串）
    lv = back.levels[0]
    lv.file = "../../evil.json"
    raises(lambda: levelfile.save_campaign(back), "★★ 关卡文件越出战役目录 → 被拒（不照写）")
    lv.file = "levels/%s.json" % lv.level_id


# ======================================================================
# 主流程
# ======================================================================

def main() -> int:
    print("DAEEM 战役编辑器 · 数据层测试")
    print("工程目录：%s（测试只动 %s 里的副本）" % (PROJECT_DIR, TMP_ROOT))
    global FACTS
    setup_project()
    FACTS = Facts(TMP_PROJECT)
    print("样例数据事实（现读，不写死）：地图 %s，玩家 %s @ %s，敌方 %s @ %s，"
          "目标区划 %s，进攻目标区划 %s，失败条件区划 %s，山地 %s"
          % (FACTS.map_id, FACTS.player, FACTS.player_base, FACTS.enemy, FACTS.enemy_base,
             FACTS.obj_zone, FACTS.attack_zone, FACTS.fail_zone, FACTS.mountain))
    # ★★ 兜底：这一套测试**只许动临时副本**，真 data/ 必须一字未改。
    #    为什么值得专门钉一条：写这些文件的是编辑器本身（`levelfile.save_campaign()`），
    #    而「临时脚本 / 手工试验」很容易顺手把真文件写了 —— 那样坏掉的是随游戏发布的数据，
    #    而且不会有任何报错（另两个编辑器都踩过一次）。
    before = {name: snapshot(path) for name, path in
              (("campaigns", REAL_CAMPAIGNS), ("maps", REAL_MAPS))}
    before_config = REAL_CONFIG.read_bytes()

    try:
        t_load_and_roundtrip()
        t_override_rules()
        t_zone_owner_materialization()
        t_config_and_maps()
        t_validation_pass()
        t_validation_map()
        t_validation_players()
        t_validation_points()
        t_validation_sides()
        t_validation_objectives()
        t_validation_attack_target()
        t_validation_units_and_factions()
        t_validation_overload()
        t_validation_faction_color()
        t_ai_assignment_roundtrip()
        t_attack_target_roundtrip()
        t_escort_placement()
        t_validation_escort_links()
        t_ordered_start_units()
        t_ordering()
        t_preserved_unknown_fields()
        t_bad_input()
        t_new_campaign()
    finally:
        after = {name: snapshot(path) for name, path in
                 (("campaigns", REAL_CAMPAIGNS), ("maps", REAL_MAPS))}
        same_config = REAL_CONFIG.read_bytes() == before_config
        for name in before:
            eq(after[name], before[name],
               "★★ 真 data/%s/ 在整个测试过程中逐字节未改（测试只动临时副本）" % name)
        ok(same_config, "★★ 真 data/config.json 一字未改")
        cleanup()

    print("\n[CASE] test_model -> passed %d / failed %d" % (_PASSED, _FAILED))
    return 1 if _FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
