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


BASE_F1 = pick_base(2, (5, 8))      # a1（玩家一）：偏南一点好，但别贴下边界（见 check_base 第 4 条）
BASE_F2 = pick_base(0, (6, 1))      # b1（玩家二，合作关）
BASE_E1 = pick_base(3, (17, 8))     # a2（敌方）
for _name, (_bx, _by), _zid in (("F1", BASE_F1, 2), ("F2", BASE_F2, 0), ("E1", BASE_E1, 3)):
    _ok, _why = check_base(_bx, _by, _zid)
    assert _ok, (_name, _why)
    assert zone_centers[_by][_bx] == -1, (_name, "大本营压在区划中心上")

# ---------------- 守军 / 建筑 ----------------
# 中立守军摆在 c1 的**北沿**（y=8..9，「一进关就有压力」：玩家从 a1 往南推进进 c1
# 就会撞上它们）。
# ⚠️ 必须落在 **c1 的地块里**（那一片是 y=7..17）：摆在 a1 里会变成
#    「敌方单位站在玩家自己的开发区里」，既不中立也会挡住建东西。
# ⚠️ 也别摆在 y=7（c1 的第一排）—— 那一排紧挨着玩家大本营的出生环，一进关就打起来。
GUARDS = [(10, 8), (10, 9), (11, 9)]


def owner_of(x: int, y: int) -> str:
    z = zones[y][x]
    if z in (2, 0):          # a1 / b1：玩家
        return "F1"
    if z in (3, 1):          # a2 / b2：敌方
        return "E1"
    if z in (6, 7):          # f1 / g1：中立地带（开局无主，双方都能抢）
        return ""
    return ""


units = []
for (x, y) in GUARDS:
    units.append({"x": x, "y": y, "name": "哨兵", "faction": "E1", "kind": "enemy", "hold": True})

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
    "factions": [
        {"id": "F1", "name": "赤军", "color": "#5AC8FF"},
        {"id": "E1", "name": "边军", "color": "#FF6B6B"},
    ],
    "faction_bases": {"F1": list(BASE_F1), "E1": list(BASE_E1)},
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
        "第一关 · 守住中场。单人战役样例：玩家守住 c1 90 秒。",
        "边军（E1）挂阵营性 AI，进攻目标固定指向 c1 —— 这就是「波次」的全部配置。",
    ],
    "name": "第一关·渡口",
    "mode": "solo",
    "map": "dongzheng",
    "players": [{"faction": "F1", "base": list(BASE_F1)}],
    "factions": [
        # ★ 只列出**本关真的要挂 AI 的**那一方。全局 config.ai.factions 里那个 "ai"
        #   不需要在这里写 —— 有 level 时「这一关有哪些阵营」由关卡数据说了算，
        #   只有 config 提过的阵营**不会**悄悄进场（见 world._merged_ai_roster 的说明）。
        {
            "id": "E1",
            "ai": "faction",
            "base": list(BASE_E1),
            # ★★ 颜色**必须写**：配色表 `colors.faction.*` 里只有内置阵营 id（p1~p8/enemy/ai），
            #   而本战役用的是自己的 id（F1/E1）—— 不写的话 `cfg.faction_color("E1")`
            #   会一路退到兜底的**品红**，症状是「整个战场一片紫、敌我分不清」（实测踩到）。
            #   运行时会按 `campaign.json` / 关卡 `factions[]` 里的 color 登记
            #   （见 `world._register_level_colors`）。
            "color": "#e05a5a",
            "resource_mult": 1.6,
            "start_food": 700,
            "start_gold": 700,
            "attack_target": {"kind": "zone", "zone": 4},
            "faction_ai": {
                # ⚠️★ `generals` 必须与「世界初始化给这一方建的将领数」对得上
                #   （`world.create_generals` 一次建 3 位）。写小了**不会少建** ——
                #   世界那 3 位是既成事实；写大了才会让 AI 去补招第 4、5 位
                #   （一支敌军变成无限增兵，而且「派几成」的分母跟着涨）。
                "generals": 3,
                # 这一方的**最低要求**：每位将领至少补到 3 个才算出兵。
                #   ★ 真正的目标编制是 `max(将领自己的编制, min_retinue)`，
                #   而「将领自己的编制」= `unit.general.escort = [4,5,6]`（逐将不同）
                #   ⇒ 第一波满编 = 4+5(+6) 个兵，波次大小自然在 4~6 这个量级浮动。
                "min_retinue": 3,
                # ⚠️★ `min_ready` 是「一波至少派几位」。第一关设成 **3 = 全员一起上**：
                #   原先写 2 配合 `ready_mult 0.6` 会算出「只派 1 位」——
                #   玩家实测的抱怨「只派一个将领过来」正是从这里来的。
                #   留在 3 还有第二个作用：三条「编制上限 4/5/6」的线**同时**满足，
                #   于是一波的总兵力就是 4+5+6=15 这个满编规模（而不是随人数抖动）。
                "min_ready": 3,
                "ready_mult": 1.0,
                "attack_repeat_sec": 18.0,
            },
        }
    ],
    "start_units": [],
    # ★ 手工加一栋塔：给「关卡的开局摆放」（`start_buildings`）留一个真样本，
    #   位置刻意避开基地自己那圈防御（城墙在 base+(0,-1)、箭塔在 base+(2,0)）——
    #   叠在同一个格子上 `add_building` 会拒掉，那就会变成一条「配了但没建出来」的谜团。
    "start_buildings": [
        {"type": "tower", "x": BASE_F1[0] + 3, "y": BASE_F1[1], "owner": "F1"},
    ],
    "zones": [
        {"id": 4, "owner": "F1"},
    ],
    "zones": [
        # ★ 地图上 a1/b1（下半场）划给玩家、a2/b2（上半场）划给敌方 —— c1/c2 留作中立的中场。
        {"id": 2, "owner": "F1"},
        {"id": 4, "owner": "F1"},
        # ★★ 敌方**必须有一块产粮的地**（`zone_kind` 里只有 food 区划产粮）：
        #    a2 / b2 都是 gold 区划 ⇒ 只有钱、没有粮 ⇒ 阵营 AI 招不出将领
        #    （实测：「一进去就白送胜利」，AI 单位从头到尾只有地图上那几个守军）。
        {"id": 1, "owner": "E1"},
        {"id": 3, "owner": "E1"},
        {"id": 5, "owner": "E1"},
    ],
    # ★★ 守住 150 秒（原来 90）：调平衡调出来的，理由写在这里免得下次又改回去 ——
    #   敌人**开局没有任何附属兵**（AI 阵营靠招，见 `world.spawn_faction_units`），
    #   要先把 3 位将领各补到 4/5/6 个兵（共 15 个，每单 10 秒读条、队列上限 5），
    #   所以**第一波大约 50 秒才出发**。守 90 秒的话打完第一波就到点了，
    #   「一波接一波」根本看不出来 —— 实测确认过。150 秒能压进 3~4 波。
    "objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 150}],
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
        {"id": "F2", "ai": "none", "color": "#ffd166"},
        # ★ f1 开局划给玩家同方（它是额外失败条件），所以要给 F1 一个基地点位 ——
        #   关卡点名的阵营**必须**有点位（校验第 4 条），而且**不能压在区划中心上**：
        #   f1 的中心是 (1,0)，所以基地摆在 (2,2)。
        #   ⚠️ 名单里**不要**再单独写一条 `{"id": "F1", "ai": "none"}` —— 同一个 id
        #      出现两次时后一条会覆盖前一条（不会报错，但「改了这一条没生效」很难查）。
        #   ★ 三个阵营的颜色都写全（两处都写是有意的：关卡是覆盖层，
        #     设计者可能想让**这一关**的某一方换个颜色）。
        {"id": "F1", "ai": "none", "base": [2, 2], "color": "#5ac8ff"},
        {
            "id": "E1",
            "ai": "faction",
            "base": list(BASE_E1),
            "color": "#e05a5a",
            "resource_mult": 1.1,
            "start_food": 300,
            "start_gold": 300,
            "attack_target": {"kind": "zone", "zone": 4},
            "faction_ai": {
                "generals": 3,
                "min_retinue": 3,
                "min_ready": 2,
                "ready_mult": 0.5,
                "attack_repeat_sec": 20.0,
            },
        },
    ],
    "allies": [["F1", "F2"]],
    "start_units": [
        {"faction": "E1", "kind": "enemy", "x": 12, "y": 2, "hold": True, "name": "边军斥候"},
    ],
    "start_buildings": [],
    "zones": [
        {"id": 4, "owner": "F1"},
        # ⚠️⚠️ 额外失败条件的那个区划**必须开局就归玩家同方** —— `zone_lost` 的判据是
        #   「不再归玩家同方就立刻判负」，开局不归己方的话第一帧就判负。
        #   （实测踩到：第一版没给 f1 归属 ⇒ 那一关一进去就输。校验会拦这一条。）
        {"id": 6, "owner": "F1"},
        # 敌方拿 a2 / b2 / c2（与第一关同一套归属；c2 是产粮区，它得靠这个招兵）
        {"id": 1, "owner": "E1"},
        {"id": 3, "owner": "E1"},
        {"id": 5, "owner": "E1"},
    ],
    "objectives": [{"kind": "hold_zone", "zone": 4, "hold_sec": 120}],
    "fail_conditions": [{"kind": "zone_lost", "zone": 6}],
    "briefing": [],
}

CAMPAIGN_JSON = {
    "_comment": [
        "战役元信息。关卡顺序以 levels[] 为准（不是文件名的字典序）。",
        "factions[].playable = 玩家能选谁；没被选中的参展阵营由 AI 驱动。",
    ],
    "name": "东征·第一章",
    "description": "样例战役：单人守中场 + 双人合作双子防线。",
    "default_mode": "solo",
    "factions": [
        # ★ `playable` 只给**第一关能选的那一方**（F1）。F2 是合作关里的第二个玩家，
        #   但「可玩」是**战役级**属性，而它在第一关与 F1 **不是盟友** ⇒
        #   标成可玩会让第一关过不了校验第 7 条（可玩阵营必须互为同方）。
        #   ⚠️ 这条约束是**故意的**：同一战役里「这一关能选谁」不能因关而异，
        #      否则「选中的那一方」在另一关里可能根本不在场。
        {"id": "F1", "name": "赤军", "color": "#5AC8FF", "playable": True},
        {"id": "F2", "name": "金军", "color": "#FFD166", "playable": False},
        {"id": "E1", "name": "边军", "color": "#FF6B6B", "playable": False},
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
for gx, gy in GUARDS:
    assert terrain[gy][gx] == ".", f"守军 ({gx},{gy}) 不在草地上"
print("bases:", {"F1": BASE_F1, "F2": BASE_F2, "E1": BASE_E1})
for zid, (cx, cy) in centers.items():
    assert terrain[cy][cx] != "#", f"区块 {zid} 的中心落在山上"
    assert zones[cy][cx] == zid, f"区块 {zid} 的中心不属于它自己"
print("OK")
