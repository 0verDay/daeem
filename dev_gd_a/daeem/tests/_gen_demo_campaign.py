"""一次性生成 data/campaigns/demo 的样例地图与关卡 JSON（生成后本文件删除）。

地图 dongzheng：24x18，东征第一章用。四角 + 中心 + 两条边角地带。
地块规则（用代码保证 exists/zones/terrain/中心/摆放全部自洽）：

    x:  0..11 | 12..17 | 18..23
    y:  0..2  | A 外圈 | A 外圈 | A 外圈
        ...
"""
from __future__ import annotations

import json
import io
from pathlib import Path

COLS, ROWS = 24, 18
CAMPAIGN = Path(__file__).resolve().parents[2] / "daeem" / "data" / "campaigns" / "demo"
MAPS = Path(__file__).resolve().parents[2] / "daeem" / "data" / "maps"

# ---------------- 地形 ----------------
# 全部草地，只放两道森林带（通行，只是减速）+ 两条斜切山地（不可通行，但地图仍连通）
MOUNTAIN = [
    (0, 9), (0, 10), (1, 9), (1, 10),
    (23, 7), (23, 8), (22, 7), (22, 8),
]
FOREST = [
    # 中间那道横带（在 zone 4/5 里），留出 x=10..13 的缺口
    (2, 8), (3, 8), (4, 8), (5, 8), (6, 8), (8, 8), (9, 8), (14, 8), (15, 8), (16, 8),
    (18, 8), (19, 8), (20, 8), (21, 8),
    (2, 9), (3, 9), (4, 9), (5, 9), (6, 9), (8, 9), (9, 9), (14, 9), (15, 9), (16, 9),
    (18, 9), (19, 9), (20, 9), (21, 9),
    # 两道竖向林（南北半场里的掩护）
    (7, 4), (7, 5), (7, 6),
    (16, 11), (16, 12), (16, 13),
]

terrain: list[list[str]] = [["." for _ in range(COLS)] for _ in range(ROWS)]
for (x, y) in FOREST:
    terrain[y][x] = "^"
for (x, y) in MOUNTAIN:
    terrain[y][x] = "#"


# ---------------- 区块 ----------------
# ★★ 硬规则：**同一区划的地块必须连成一片**（用户明确要求）。
#    以前这里是「y=3..6 给 c1/c2、y=7..11 给 a1/a2、y=12..17 又给 c1/c2」——
#    于是 c1/c2 各自分成上下两条，把 a1/a2 **夹在中间**：
#      · 运行时的包围盒会「把 a1 整片包住」（c1 的盒子是 (0,3)-(11,17)）；
#      · 从画面上看就是「c1 一会儿在 a1 上面、一会儿在 a1 下面」（玩家实测报回来的）。
#    现在按「一条横带 = 一个区划」重排：每条带内部只有 x<=11 / x>11 两段，
#    所以每个区划都是**单个矩形**，天然连续。
#    ⚠️ 改这里之后必须重算 `zone_list[].center`（生成器自己算）并重跑关卡数据
#      —— 大本营 / 出生点都是按区划挑的（见 BASE_* 与 pick_base）。
def zone_of(x: int, y: int) -> int:
    if y <= 1 and x <= 2:
        return 6                 # f1：西北角（外圈，开场无主）
    if y <= 1 and x >= 21:
        return 7                 # g1：东北角（外圈，开场无主）
    if y <= 2:
        return 0 if x <= 11 else 1          # 北带 y=0..2（b1 / b2）
    if y <= 6:
        return 2 if x <= 11 else 3          # 中上带 y=3..6（a1 / a2）
    return 4 if x <= 11 else 5              # 下半场 y=7..17（c1 / c2）：**一整条，连续**


ZONE_KIND = {0: "food", 1: "gold", 2: "food", 3: "gold", 4: "population", 5: "food", 6: "population", 7: "gold"}
ZONE_NAME = {0: "b1", 1: "b2", 2: "a1", 3: "a2", 4: "c1", 5: "c2", 6: "f1", 7: "g1"}
ZONE_PROD = {
    "food": {"food": 1.0, "gold": 0.0, "population": 0.1},
    "gold": {"food": 0.0, "gold": 1.0, "population": 0.1},
    "population": {"food": 0.0, "gold": 0.0, "population": 0.15},
}

zones = [[zone_of(x, y) for x in range(COLS)] for y in range(ROWS)]
tiles: dict[int, list[list[int]]] = {}
for y in range(ROWS):
    for x in range(COLS):
        tiles.setdefault(zones[y][x], []).append([x, y])


def find_center(zid: int):
    """区块中心：优先取「可通行 + 不是山」的格子里**离区块质心最近的**那一格。"""
    own = tiles[zid]
    cx = sum(p[0] for p in own) / len(own)
    cy = sum(p[1] for p in own) / len(own)
    best, bestd = None, 1e9
    for (x, y) in own:
        if terrain[y][x] == "#":
            continue
        d = (x - cx) ** 2 + (y - cy) ** 2
        if d < bestd:
            bestd, best = d, (x, y)
    return best


centers = {zid: find_center(zid) for zid in sorted(tiles)}
assert all(c is not None for c in centers.values()), "有的区块一格可通行地块都没有"

zone_list = []
for zid in sorted(tiles):
    kind = ZONE_KIND[zid]
    cx, cy = centers[zid]
    xs = [p[0] for p in tiles[zid]]
    ys = [p[1] for p in tiles[zid]]
    entry = {
        "id": zid,
        "name": ZONE_NAME[zid],
        "kind": kind,
        "center": [cx, cy],
        "production": ZONE_PROD[kind],
        "x0": min(xs), "y0": min(ys), "x1": max(xs), "y1": max(ys),
        "tile_count": len(tiles[zid]),
        "tiles": tiles[zid],
    }
    zone_list.append(entry)

zone_centers = [[-1 for _ in range(COLS)] for _ in range(ROWS)]
for zid, (cx, cy) in centers.items():
    zone_centers[cy][cx] = zid

# ---------------- 大本营（手挑：区块中心的质心不一定适合当基地，这里挑区块内靠里的平地） ----------------
#
# ★★ 三条硬约束（每一条都是实测踩出来的）：
#   1. 地块必须是**可通行的平地**（山地不能建基地）；
#   2. 基地所在格**不能是任何区块的中心格** —— 中心是一栋中立障碍建筑，
#      基地先建出来它就只能报警「中心建不出来」（route.md 33.5 坑①）；
#   3. ★★ 还要避开 `_ring_layout()` 给这一方**自动生成**的防御阵地：
#      城墙在 `base + (0,-1)`、箭塔在 `base + (2,0)` —— 那两个格子如果压在
#      **别的**区块中心上，一样会把那栋中心建筑顶掉
#      （实测：基地 (5,10) → 城墙落在 (5,9) = a1 的中心）。
ZONE_CENTER_SET = {(cx, cy) for (cx, cy) in centers.values()}


def check_base(x: int, y: int, zid: int):
    """这个点位能不能当基地？返回 (ok, 说明)。"""
    if zone_of(x, y) != zid:
        return False, "不在区块 %d 里" % zid
    # ★★ 第 4 条（本轮新增，实测踩到）：**大本营不能贴着自己区划的下边界**。
    #   开局单位是 `world.create_generals()` 围着大本营**就近找空格**摆出来的
    #   （用 `_ring_tile` 一圈圈找）——大本营如果正好在区划的最后一排，
    #   出生环往南一步就掉进**下一块地**。
    #   症状：样例第一关里 F1 的将领出生在 c1（目标区划）**外面** ⇒
    #   `objective` 第 0 帧就判「守住的区块不在自己手里」⇒ 开局即负（实测）。
    #   ⇒ 要求 `y + 1` 也在同一个区划里（出生环至少有一格可落）。
    if zone_of(x, y + 1) != zid:
        return False, "贴着区块 %d 的下边界（出生环会掉进别的区块）" % zid
    for (bx, by), what in (((x, y), "基地"), ((x, y - 1), "城墙"), ((x + 2, y), "箭塔")):
        if not (0 <= bx < COLS and 0 <= by < ROWS):
            return False, "%s (%d,%d) 在地图外" % (what, bx, by)
        if terrain[by][bx] != ".":
            return False, "%s (%d,%d) 不是平地" % (what, bx, by)
        if (bx, by) in ZONE_CENTER_SET:
            return False, "%s (%d,%d) 压在区块中心上" % (what, bx, by)
    return True, ""


def pick_base(zid: int, prefer):
    """在区块 `zid` 里挑一个满足上面三条的点位（优先靠近 `prefer`）。"""
    px, py = prefer
    cands = sorted(tiles[zid], key=lambda p: (p[0] - px) ** 2 + (p[1] - py) ** 2)
    for (x, y) in cands:
        ok, _why = check_base(x, y, zid)
        if ok:
            return (x, y)
    raise AssertionError("区块 %d 里找不到能当基地的点位" % zid)


BASE_F1 = pick_base(2, (4, 5))      # a1（玩家一）：偏南一点好，但别贴下边界（见 check_base 第 4 条）
# ★★ F2 的大本营（b1：y=0..2, x<=11）。挑点位有三条硬约束，都是实测踩出来的：
#   1. 不能压区划中心（中心是中立障碍建筑，叠格会让它静默建不出来）；
#   2. ★ 也不能**靠近**区划中心 —— `map_data._ring_layout` 给每一方自动生成的
#      防御阵地是「城墙 = 基地正上方」「箭塔 = 基地 + (2,0)」。基地放 (4,1) 时
#      那支箭塔正好落在 (6,1) = b1 的中心上，把那栋中心建筑顶掉了
#      （引擎只 push 一条 warning，非常安静）；
#   3. 还要给 `_ring_layout` 的 6 个将领站位留出平地。
#   ⇒ (10,1)：离 b1 中心 (6,1) 4 格、离 f1 中心 (1,0) 9 格，站位与防御全在 b1 内。
# ★★ 红方（攻方）的家要**离目标区划 c1 远一点**，理由（实测）：c1 是下半场 x=0..11,
#    y=7..17 —— 它的**北沿就是 y=7**。红方原来放在 b1 的东头 (10,1)，它的开局部队
#    往下走两格就压到 c1 的地块上了：实测玩家选红方时 **31 秒**就占领完了
#    （目标是 1~2 分钟）。放到 b1 西头之后它得真的推下来。
BASE_F2 = pick_base(1, (20, 1))      # b1 西北角（离 c1 最远；b1 是唯一够大又不在 c1 边上的地）
# ⚠️ 这张图现在只有 F1 / F2 两个阵营（E1 已删除，第二关的敌人位也取消了）——
#    所以**不再**给 E1 挑基地。`pick_base` 那三条约束仍然保留（下面是 F1 / F2 在用）。
# ⚠️ 这里钉的 `_zid` 必须与 `pick_base` 的**第一个参数一致**：写错了这一步会在
#    「基地不在那个区划里」上直接 assert 失败 —— 而它失败得**很晚**（关卡文件已经写完了），
#    于是工作区会留下一份「地图是新的、关卡是旧的」的混合数据（实测踩到）。
BASE_ZONE = {"F1": 2, "F2": 1}
for _name, (_bx, _by) in (("F1", BASE_F1), ("F2", BASE_F2)):
    _zid = BASE_ZONE[_name]
    _ok, _why = check_base(_bx, _by, _zid)
    assert _ok, (_name, _why)
    assert zone_centers[_by][_bx] == -1, (_name, "大本营压在区划中心上")

# ---------------- 可玩席位（F1 / F2：玩家挑一个来玩） ----------------
#
# ★★ 两个可玩阵营**都写 `ai: "faction"`**，并在 `campaign.json` 里都标 `playable`。
#    玩家选中哪一方，运行时就把那一方的 AI 摘掉（`world._is_ai_piloted` /
#    `_setup_ai_factions`）；没被选中的那一边照这份数据自己经营。
# ⚠️ 只给一方写 ai 是不够的 —— 另一方在玩家不选它的时候就站在场上发呆
#    （实测：选 F2 时 F1 从头到尾 3 个光杆将领、一波都不出）。
# ★ 两个席位**开局都给附属兵**（`world._keeps_opening_escort` 按 `playable` 判）：
#    它们是我方战线，不是「靠招兵补员」的 NPC 敌人。
FACTION_AI = {
    # ⚠️ 必须等于 `world.create_generals` 给每一方建的那 3 位
    "generals": 3,
    "min_retinue": 3,
    "min_ready": 2,
    "ready_mult": 0.5,
    "attack_repeat_sec": 20.0,
}


def _seat(fid: str, name: str, color: str, base, ai: str, food: int, gold: int) -> dict:
    """一个可玩席位的 `factions[]` 条目。

    ★ 字段顺序与「缺省不写」的口径**要和战役编辑器写出来的一致**
      （`tools/campaign_editor/model.py` 的 `_faction_to_dict`）—— `test_model.py` 有一条
      「写出来的关卡与源文件逐字段一致」的往返断言，这里漂了它就会红。"""
    return {
        "id": fid,
        "ai": ai,
        "base": list(base),
        "start_food": food,
        "start_gold": gold,
        "faction_ai": dict(FACTION_AI),
        "name": name,
        "color": color,
    }


def BLUE_SEAT(fid: str, name: str, color: str, base) -> dict:
    """★ 蓝方（守方）：挂**将领性（守家）AI** —— 在自己的归属区划里巡逻警戒、
    脱战无消耗招兵，**不反推**对方的家（玩家选红方时，它是「只守 c1 周边」的对手）。"""
    # ★ 开局资源：守方要在第一波打过来之前能补上人（不然它 100 秒左右就被拆穿）。
    #   实测：200/200 时它守到 110 秒；给到 600/600 之后能撑过 150 秒。
    return _seat(fid, name, color, base, "general", 600, 600)


def RED_SEAT(fid: str, name: str, color: str, base) -> dict:
    """★ 红方（攻方）：挂**阵营性 AI** —— 招将 → 招兵 → 满员 → 行军攻击，
    会主动打过来（玩家选蓝方时，它就是那波「红点」）。
    ★ 开局多给一点资源：它的地盘（b1 + g1）比蓝方的 c1/c2 小得多，
      不给启动资金的话成型太慢、红方那一路打不动。
    ★★ 进攻目标固定指向 **c1**（这一关的目标区划）：不给的话它会自己挑
      「离自己最近的敌方区划」（多半是 c2）—— 玩家守的是 c1，威胁就摊薄了；
      而且校验第 15 条会为此发一条警告。"""
    # ★ 开局资源压到 200/200：给太多的话它 31 秒就把 c1 打下来了
    #   （目标是「中速：1~2 分钟」），也顺带让它那一路有「招满再出征」的过程。
    out = _seat(fid, name, color, base, "faction", 200, 200)
    out["attack_target"] = {"kind": "zone", "zone": 4}
    out["faction_ai"]["min_ready"] = 3
    out["faction_ai"]["ready_mult"] = 1.0
    return out


# ---------------- 守军 / 建筑 ----------------


def owner_of(x: int, y: int) -> str:
    """地图层的开局归属。

    ★ 这张图现在只有两个阵营（F1 蓝方 / F2 红方），而且**开局归属主要由关卡决定**
      （`levels/*.json` 的 `zones[]` 覆盖地图这一份，见 logic/level.gd 的覆盖规则）。
      地图这里只划「谁一出生就有的那块北带」：b1/a1（z 0/2）归 F1；
      其余（含 a2/b2 与下半场 c1/c2）留空 —— 空 = 开局无主，谁先站进去算谁的，
      这正是「红方要从北边打下来」「蓝方要守住 c1」两条目标的前提。
    """
    z = zones[y][x]
    if z in (2, 0):          # a1 / b1：F1 的北带
        return "F1"
    return ""


# ★ 地图上**不再预置中立守军**：原来的 3 个 E1 哨兵是给「单机试炼」当压力用的，
#   而 E1 已经从这张图移除（它会把 F1/F2 之外的第三方带进名单，见上面 owner_of 的说明）。
units = []

# 开局归属（zone_list[].owner）：写在区块表里
for entry in zone_list:
    zid = entry["id"]
    sample = entry["tiles"][0]
    entry["owner"] = owner_of(sample[0], sample[1])
    if entry["owner"] == "":
        entry.pop("owner")

map_json = {
    "id": "dongzheng",
    "name": "东征",
    # ★★ hidden = 只给战役关卡用：不进「自由对战 / 试炼场」的地图选择条，
    #    也不抢默认地图（见 daeem/logic/map_library.gd 的 KEY_HIDDEN 那一段）。
    #    关卡按 id 直接引用它，不受这个标记影响。
    "hidden": True,
    "cols": COLS,
    "rows": ROWS,
    "exists": [[1 for _ in range(COLS)] for _ in range(ROWS)],
    "layout": ["".join(row) for row in terrain],
    "zones": zones,
    "zone_list": zone_list,
    "zone_centers": zone_centers,
    "faction_bases": {"F1": list(BASE_F1), "F2": list(BASE_F2)},
    "units": units,
    "buildings": [],
    "_comment": [
        "DAEEM · 战役样例地图（东征·第一章）。",
        "hidden: true —— 只给战役关卡用，不进自由对战的地图选择条（见 logic/map_library.gd）。",
        "★★ 布局硬规则：**同一区划的地块必须连成一片**（一条横带 = 一个区划，",
        "   带内只有 x<=11 / x>11 两段 ⇒ 每个区划都是单个矩形）。",
        "   北带 y=0..2 = b1/b2；中上带 y=3..6 = a1/a2；下半场 y=7..17 = c1/c2。",
        "F1 的家在中上带左侧（a1）+ 北带左侧（b1）；E1 在右侧（a2/b2）。",
        "c1 / c2 是中立的下半场：双方都能抢，也是「守住 c1」这个目标的所在地。",
        "f1 / g1 是开场无主的外圈，给 AI 扩张留了余地。",
        "field 布局：'.' 草地  '^' 森林（通行减速）  '#' 山地（不可通行）。",
    ],
}

out_map = MAPS / "dongzheng" / "map.json"
out_map.parent.mkdir(parents=True, exist_ok=True)
out_map.write_text(json.dumps(map_json, ensure_ascii=False, indent=2) + "\n",
                   encoding="utf-8", newline="\n")

# ---------------- 关卡 ----------------
LEVEL_1 = {
    "_comment": [
        "第一关 · 渡口。★★ 一关两个可玩阵营，各打各的：",
        "   蓝方（F1）守住 c1 150 秒；红方（F2）攻占 c1。选谁就取谁那条目标，",
        "   没被选中的那一边由 AI 接管（蓝方 = 守家 AI，红方 = 阵营 AI 主动来打）。",
        "c1 开局归蓝方；红方从北边（b1 + g1）南下进攻。",
    ],
    "name": "第一关·渡口",
    "mode": "solo",
    "map": "dongzheng",
    "players": [{"faction": "F1", "base": list(BASE_F1)}],
    "factions": [
        # ★★ 两个**可选**阵营，两种完全不同的脑子：
        #    · 蓝方 F1：`ai: "general"` —— 守家 AI（将领在自己归属区划里巡逻警戒、
        #      脱战无消耗招兵），**只守 c1 周边、不反推**红方的家；
        #    · 红方 F2：`ai: "faction"` —— 阵营 AI（招将 → 招兵 → 满员 → 行军攻击），
        #      会主动打过来（这是「红点波次」的来源）。
        #    玩家选中哪一方，运行时就把哪一方的 AI 摘掉（见 world._is_ai_piloted）。
        BLUE_SEAT("F1", "蓝方", "#5ac8ff", BASE_F1),
        RED_SEAT("F2", "红方", "#e05a5a", BASE_F2),
    ],
    # ★★ 蓝方在 c1 上**开局就摆一支守备队**（`zone: 4` = 挂守家 AI，原地守住那一区）。
    #
    # 为什么必须有（实测）：没有它的话，蓝方的兵要从 a1 的大本营**走过来**才守得住 ——
    #   而红方（进攻方）从 b1 出发，两边的**先到者**就决定了那一帧的归属：
    #     · 玩家选红方时，红方 30 秒出头就白捡了 c1（目标是 1~2 分钟）；
    #     · 玩家选蓝方时，红方的 AI 一波就把 c1 端了（守方来不及）。
    #   摆上守备队之后，c1 是**真的有人在守**：红方必须打赢他们才占得下来。
    "start_units": [
        {"faction": "F1", "kind": "enemy", "x": 4, "y": 10, "ai": "general", "zone": 4,
         "name": "渡口守军"},
        {"faction": "F1", "kind": "enemy", "x": 6, "y": 10, "ai": "general", "zone": 4,
         "name": "渡口守军"},
        {"faction": "F1", "kind": "enemy", "x": 5, "y": 11, "ai": "general", "zone": 4,
         "name": "渡口守军"},
    ],
    # ★ 手工加一栋塔：给「关卡的开局摆放」（`start_buildings`）留一个真样本，
    #   位置刻意避开基地自己那圈防御（城墙在 base+(0,-1)、箭塔在 base+(2,0)）——
    #   叠在同一个格子上 `add_building` 会拒掉，那就会变成一条「配了但没建出来」的谜团。
    "start_buildings": [
        {"type": "tower", "x": BASE_F1[0] + 3, "y": BASE_F1[1], "owner": "F1"},
    ],
    # ⚠️ **不写 `allies`**：蓝方与红方是对立的（这一关就是「选边打」）。
    "zones": [
        # 开局归属：c1/c2（下半场，132 格）归蓝方 —— 目标区划 c1 开局必须是蓝方的，
        # 否则「丢掉即判负」会让蓝方一进关就输；
        # 红方从北边 b1（产粮 30 格）+ g1（产金 6 格）起家，要自己打下 c1。
        {"id": 4, "owner": "F1"},
        {"id": 5, "owner": "F1"},
        {"id": 0, "owner": "F2"},
        {"id": 7, "owner": "F2"},
    ],
    # ★★ 两条目标，各点名给谁（`for`）。这是「一关两个可玩阵营各打各的」的全部配置：
    #    · 蓝方：守住 c1 150 秒（守满判胜；c1 一丢当场判负）
    #    · 红方：占领 c1 —— 归属翻成红方的那一帧**立刻判胜**（不要求再守）
    "objectives": [
        {"for": "F1", "kind": "hold_zone", "zone": 4, "hold_sec": 150},
        {"for": "F2", "kind": "capture_zone", "zone": 4},
    ],
    "fail_conditions": [],
    "briefing": [],
}

LEVEL_2 = {
    "_comment": [
        "第二关 · 双子防线。双人合作样例：两个玩家各有大本营（b1 / a1 相邻），共享视野。",
        "目标仍是守住 c1 120 秒；额外失败条件：外圈 f1 失守。",
    ],
    "name": "第二关·双子防线",
    "mode": "coop",
    "map": "dongzheng",
    "players": [
        {"faction": "F1", "base": list(BASE_F1)},
        {"faction": "F2", "base": list(BASE_F2)},
    ],
    "factions": [
        {"id": "F2", "ai": "none", "base": list(BASE_F2), "color": "#ffd166"},
        # ★ f1 开局划给玩家同方（它是额外失败条件），所以要给 F1 一个基地点位 ——
        #   关卡点名的阵营**必须**有点位（校验第 4 条），而且**不能压在区划中心上**：
        #   f1 的中心是 (1,0)，所以基地摆在 (2,2)。
        #   ⚠️ 名单里**不要**再单独写一条 `{"id": "F1", "ai": "none"}` —— 同一个 id
        #      出现两次时后一条会覆盖前一条（不会报错，但「改了这一条没生效」很难查）。
        #   ★ 三个阵营的颜色都写全（两处都写是有意的：关卡是覆盖层，
        #     设计者可能想让**这一关**的某一方换个颜色）。
        {"id": "F1", "ai": "none", "base": [2, 2], "color": "#5ac8ff"},
    ],
    "allies": [["F1", "F2"]],
    "start_units": [],
    "start_buildings": [],
    "zones": [
        # ★ F2 是第二个玩家席位，原来**一块地都没有**（没产粮就招不了兵）——
        #   选 F2 时它得有自己的家底。
        {"id": 0, "owner": "F2"},
        {"id": 7, "owner": "F2"},
        {"id": 4, "owner": "F1"},
        # ⚠️⚠️ 额外失败条件的那个区划**必须开局就归玩家同方** —— `zone_lost` 的判据是
        #   「不再归玩家同方就立刻判负」，开局不归己方的话第一帧就判负。
        #   （实测踩到：第一版没给 f1 归属 ⇒ 那一关一进去就输。校验会拦这一条。）
        {"id": 6, "owner": "F1"},
        # ★ 这一关是**两个玩家守住一条线**，没有第三方敌人（E1 已从这张图移除）：
        #   两名玩家各自有粮有金（F1：a1 产粮 + c1 人口；F2：b1 产粮 + g1 产金）。
        #  ⚠️ 原来这里给 E1 划了 a2/b2/c2 —— 那些 id 现在在这张图上不存在了，
        #     继续写会让 `zones[]` 指向一个没有基地的阵营（静默变成中立地）。
    ],
    "objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 120}],
    "fail_conditions": [{"kind": "zone_lost", "zone": 6}],
    "briefing": [],
}

CAMPAIGN_JSON = {
    "_comment": [
        "战役元信息。关卡顺序以 levels[] 为准（不是文件名的字典序）。",
        "factions[].playable = 玩家能选谁；没被选中的参展阵营由 AI 驱动。",
        "★★ 第一关是「选边关」：蓝方（F1）守住 c1，红方（F2）攻占 c1 —— 两边各有一条",
        "   属于自己的目标（objectives[].for），选中谁就打谁那条；两边是对立的。",
    ],
    "name": "东征·第一章",
    "description": "样例战役：第一关选边打（蓝方守 c1 / 红方攻 c1）+ 第二关双人合作。",
    "default_mode": "solo",
    "factions": [
        # ★★ F1 与 F2 **都可玩**：用户要「选择两个阵营其中的一个进行游戏」。
        #   它们在关卡里互为盟友（第一关现在写了 `allies`），所以过得了校验第 7 条。
        #   选中哪一方由玩家在战役页决定；没被选中的那一个由**阵营 AI** 接管。
        {"id": "F1", "name": "蓝方", "color": "#5AC8FF", "playable": True},
        {"id": "F2", "name": "红方", "color": "#E05A5A", "playable": True},
    ],
    "levels": [
        {"id": "01_beachhead", "file": "levels/01_beachhead.json", "name": "第一关·渡口"},
        {"id": "02_twin_line", "file": "levels/02_twin_line.json", "name": "第二关·双子防线"},
    ],
    "unlock": "in_order",
}

CAMPAIGN.mkdir(parents=True, exist_ok=True)
(CAMPAIGN / "levels").mkdir(parents=True, exist_ok=True)
(CAMPAIGN / "campaign.json").write_text(
    json.dumps(CAMPAIGN_JSON, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
for name, data in (("01_beachhead.json", LEVEL_1), ("02_twin_line.json", LEVEL_2)):
    (CAMPAIGN / "levels" / name).write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")

# ---------------- 自检 ----------------
print("map ->", out_map)
print("centers:", {k: tuple(v) for k, v in sorted(centers.items())})
print("bases:", {"F1": BASE_F1, "F2": BASE_F2})
for zid, (cx, cy) in centers.items():
    assert terrain[cy][cx] != "#", f"区块 {zid} 的中心落在山上"
    assert zones[cy][cx] == zid, f"区块 {zid} 的中心不属于它自己"
print("OK")
