# -*- coding: utf-8 -*-
"""把 map_excel 里的「登神长阶」Excel 转成 DAEEM 的 map.json + level JSON。

只作为本次导入的生成器：地图边界、区划、建筑、守军都由表格推出来。
"""
from __future__ import annotations

import json
import os
from typing import Dict, List, Tuple

import openpyxl

HERE = os.path.dirname(os.path.abspath(__file__))
XLSX = None
for name in os.listdir(HERE):
    if name.lower().endswith(".xlsx") and not name.startswith("~$"):
        XLSX = os.path.join(HERE, name)
        break
if XLSX is None:
    raise SystemExit("找不到 xlsx")

PROJECT = os.path.abspath(os.path.join(HERE, "..", "daeem"))
MAP_ID = "dengshen_changjie"
MAP_DIR = os.path.join(PROJECT, "data", "maps", MAP_ID)
LEVEL_PATH = os.path.join(PROJECT, "data", "campaigns", "demo", "levels", "%s.json" % MAP_ID)

# 表格里的地图区：K3:AQ53（J 列及以左是图例，AS 及以右忽略）
C0, R0 = 11, 3      # K3
C1, R1 = 43, 53     # AQ53
W, H = C1 - C0 + 1, R1 - R0 + 1

FILL_TERRAIN = {
    "1F2329": "mountain",
    "4E83FD": "water",
    "34C724": "forest",
}
TERRAIN_CHAR = {"grass": ".", "forest": "^", "mountain": "#", "water": "~"}

BUILDING_NUM = {
    "1": "watch_tower",
    "2": "tower",
    "5": "farm",
    "6": "house",
    "7": "mine",
}
WALL_FILL = {"FF8800": "wall", "8F959E": "stone_wall"}
KIND_LABEL = {"population": "人口", "gold": "黄金", "food": "粮食"}
KIND_FROM_CN = {"人": "population", "金": "gold", "粮": "food"}
PRODUCTION = {
    "food": {"food": 1.5, "gold": 0, "population": 0.15},
    "gold": {"food": 0, "gold": 1.2, "population": 0.15},
    "population": {"food": 0.8, "gold": 0, "population": 0.4},
}

ROLE_TYPE = {
    "line": "spearman",
    "ranged": "longbowman",
    "cavalry": "rider",
    "elite": "knight",
}
ROLE_ESCORTS = {
    "line": [("spearman", 0.65), ("longbowman", 0.20), ("rider", 0.15)],
    "ranged": [("longbowman", 0.55), ("spearman", 0.30), ("rider", 0.15)],
    "cavalry": [("rider", 0.55), ("spearman", 0.30), ("longbowman", 0.15)],
    "elite": [("knight", 0.25), ("spearman", 0.40), ("longbowman", 0.20), ("rider", 0.15)],
}
ROLE_ORDER = ["line", "ranged", "cavalry", "elite"]

# 红点阵营：从地图顶部两角刷波，直接压向 p1 / p2 的基地区域。
REDDOT_SPAWN_TILES = [
    [0, 0], [1, 0], [0, 1], [1, 1],
    [31, 0], [32, 0], [31, 1], [32, 1],
]
REDDOT_MARCH_TILES = [
    [1, 48], [2, 49], [3, 48], [1, 49], [3, 49],
    [17, 48], [18, 49], [19, 48], [17, 49], [19, 49],
]
REDDOT_AI = {
    "spawn_tiles": REDDOT_SPAWN_TILES,
    "march_tiles": REDDOT_MARCH_TILES,
    "wave_time_expr": "2.5x+0.5",
    "general_count_expr": "0.5x+0.5",
    "general_count_max": 3,
    "general_weights": [
        {"general": 1, "weight": 0.34},
        {"general": 2, "weight": 0.33},
        {"general": 3, "weight": 0.33},
    ],
    "escort_count": 2,
    "escort_count_expr": "0.5x+0.5",
    "escort_count_max": 5,
    "escort_types": [
        {"type": "spearman", "weight": 0.6},
        {"type": "longbowman", "weight": 0.4},
    ],
    "max_alive": 24,
    "waves": 0,
}

# Excel 黑细线框出来的 16 个区划矩形（local x0,y0,x1,y1，含边界）。
# 键 = 红心在 Excel 里的 local 坐标；值 = 该区划的矩形范围。
# ★ 不在矩形内、或是水域 / 山地的格子 → zone = -1（无区划归属）。
ZONE_RECTS = {
    (2, 1):  (0, 0, 8, 17),      # 人6
    (16, 1): (9, 0, 23, 8),      # 人0
    (28, 11): (24, 0, 32, 17),   # 人6
    (14, 15): (9, 13, 19, 20),   # 金5
    (3, 22): (0, 18, 8, 28),     # 金3
    (28, 22): (24, 20, 32, 28),  # 金3
    (14, 25): (9, 21, 19, 28),   # 粮4
    (4, 32): (0, 29, 8, 36),     # 粮4
    (16, 32): (9, 29, 22, 36),   # 粮6
    (29, 32): (23, 29, 32, 34),  # 人3
    (4, 40): (0, 37, 8, 43),     # 金3
    (16, 40): (13, 37, 22, 43),  # 金2
    (29, 40): (23, 35, 32, 45),  # 人1
    (4, 48): (0, 44, 8, 50),     # 人3
    (16, 48): (13, 44, 22, 50),  # 人2
    (29, 48): (23, 46, 32, 50),  # 粮1
}


def cell(r: int, c: int):
    return ws.cell(r, c)


def fill_rgb(x) -> str:
    p = x.fill.patternType
    return (x.fill.fgColor.rgb or "")[-6:] if p else ""


def main() -> None:
    global ws
    wb = openpyxl.load_workbook(XLSX, data_only=True)
    ws = wb[wb.sheetnames[0]]

    terrain: List[List[str]] = []
    for r in range(R0, R1 + 1):
        row: List[str] = []
        for c in range(C0, C1 + 1):
            row.append(FILL_TERRAIN.get(fill_rgb(cell(r, c)), "grass"))
        terrain.append(row)

    # ---- 区划中心 ----
    centers: List[Dict] = []
    for r in range(R0, R1 + 1):
        for c in range(C0, C1 + 1):
            v = cell(r, c).value
            if isinstance(v, str) and len(v) >= 2 and v[0] in KIND_FROM_CN:
                digits = "".join(ch for ch in v[1:] if ch.isdigit())
                centers.append({
                    "x": c - C0,
                    "y": r - R0,
                    "kind": KIND_FROM_CN[v[0]],
                    "slots": int(digits) if digits else 0,
                    "raw": v,
                })
    centers.sort(key=lambda z: (z["y"], z["x"]))
    for i, z in enumerate(centers):
        z["id"] = i
    if len(centers) != 16:
        raise SystemExit("区划中心数量不是 16：%d" % len(centers))

    # ---- 区划矩形（按 Excel 黑细线框）----
    # ★ 水域 / 山地不属于任何区划（zone = -1）；森林属于区划。
    zone_of: Dict[Tuple[int, int], int] = {}
    for z in centers:
        rect = ZONE_RECTS.get((z["x"], z["y"]))
        if rect is None:
            raise SystemExit("区划中心 (%d,%d) %s 没有矩形定义" % (z["x"], z["y"], z["raw"]))
        x0, y0, x1, y1 = rect
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                if terrain[y][x] != "grass":
                    continue
                if (x, y) in zone_of:
                    raise SystemExit("区划矩形重叠：(%d,%d) 同时属于 Z%d 和 Z%d"
                                     % (x, y, zone_of[(x, y)], z["id"]))
                zone_of[(x, y)] = z["id"]
    # 每个红心本身必须落在自己的可通行矩形里。
    for z in centers:
        if (z["x"], z["y"]) not in zone_of:
            raise SystemExit("区划中心 Z%d (%d,%d) 不在可通行地块上" % (z["id"], z["x"], z["y"]))

    # ---- 地图 JSON ----
    exists = [[1] * W for _ in range(H)]
    layout = ["".join(TERRAIN_CHAR[terrain[y][x]] for x in range(W)) for y in range(H)]
    zones_grid = [[zone_of.get((x, y), -1) for x in range(W)] for y in range(H)]
    centers_grid = [[-1] * W for _ in range(H)]
    for z in centers:
        centers_grid[z["y"]][z["x"]] = z["id"]

    zone_list = []
    for z in centers:
        zid = z["id"]
        tiles = [[x, y] for y in range(H) for x in range(W) if zones_grid[y][x] == zid]
        xs = [t[0] for t in tiles]
        ys = [t[1] for t in tiles]
        entry = {
            "id": zid,
            "name": "%s%d" % (KIND_LABEL[z["kind"]], z["slots"]),
            "kind": z["kind"],
            "center": [z["x"], z["y"]],
            "production": dict(PRODUCTION[z["kind"]]),
            "x0": min(xs),
            "y0": min(ys),
            "x1": max(xs),
            "y1": max(ys),
            "tile_count": len(tiles),
            "tiles": tiles,
        }
        zone_list.append(entry)

    map_doc = {
        "hidden": True,
        "id": MAP_ID,
        "name": "登神长阶",
        "_comment": [
            "DAEEM · 由 map_excel/合作任务：新登神长阶.xlsx 导入生成。",
            "layout：'.' 草地  '^' 森林  '#' 山地  '~' 水域；一切以 exists 为准。",
            "zone_list[].center 是 Excel 红底格；区划边界由 Excel 黑细线围出的区域推出。",
            "地图尺寸 33×51，对应 Excel K3:AQ53；J 列及以左是图例，AS 及以右忽略。",
        ],
        "cols": W,
        "rows": H,
        "exists": exists,
        "layout": layout,
        "zones": zones_grid,
        "zone_list": zone_list,
        "zone_centers": centers_grid,
    }

    # ---- 关卡层：归属 / 建筑 / 守军 / 目标 ----
    base_cells = {}
    for r in range(R0, R1 + 1):
        for c in range(C0, C1 + 1):
            v = cell(r, c).value
            if isinstance(v, str) and v.strip().lower() in ("p1", "p2"):
                base_cells[v.strip().lower()] = (c - C0, r - R0)
    if set(base_cells) != {"p1", "p2"}:
        raise SystemExit("找不到 p1/p2 大本营：%r" % base_cells)

    base_zone = {fid: zones_grid[y][x] for fid, (x, y) in base_cells.items()}
    if base_zone["p1"] == base_zone["p2"]:
        raise SystemExit("p1/p2 落在同一个区划：%r" % base_zone)

    owners = {}
    unowned_zone_ids = {10, 11, 12, 15}
    for z in centers:
        zid = z["id"]
        if zid == base_zone["p1"]:
            owners[zid] = "p1"
        elif zid == base_zone["p2"]:
            owners[zid] = "p2"
        elif zid in unowned_zone_ids:
            owners[zid] = ""
        else:
            owners[zid] = "df"

    level_zones = []
    for z in centers:
        zid = z["id"]
        zone_tiles = [(x, y) for y in range(H) for x in range(W) if zone_of.get((x, y)) == zid]

        def edge_band(radius: int) -> List[List[int]]:
            edge: List[List[int]] = []
            for x, y in zone_tiles:
                if x == z["x"] and y == z["y"]:
                    continue
                is_edge = False
                for dy in range(-radius, radius + 1):
                    for dx in range(-radius, radius + 1):
                        if dx == 0 and dy == 0:
                            continue
                        if zone_of.get((x + dx, y + dy)) != zid:
                            is_edge = True
                            break
                    if is_edge:
                        break
                if is_edge:
                    edge.append([x, y])
            edge.sort(key=lambda t: (t[1], t[0]))
            return edge

        # 中立 / 玩家方区划用 1 格边缘；df 区划保持 2 格。
        edge = edge_band(1 if owners[zid] in ("", "p1", "p2") else 2)
        # 2 格边缘 + 区划中心 3×3 禁建圈会把小区域的建造点全吃掉（实测 Z12）。
        # 这种情况自动退成 1 格边缘，优先保证表格里的 build_point_count 能落地。
        if z["slots"] > 0 and len(zone_tiles) - len(edge) <= 9:
            edge = edge_band(1)
        level_zones.append({
            "id": zid,
            "owner": owners[zid],
            "build_point_count": z["slots"],
            "no_go": edge,
        })

    start_buildings = []
    for r in range(R0, R1 + 1):
        for c in range(C0, C1 + 1):
            v = cell(r, c).value
            fg = fill_rgb(cell(r, c))
            btype = None
            if isinstance(v, str):
                s = v.strip()
                if s.lower() in ("p1", "p2"):
                    continue  # 大本营由 players/factions 的 base 生成
                if s in BUILDING_NUM and fg == "FFFFFF":
                    btype = BUILDING_NUM[s]
            elif isinstance(v, (int, float)) and float(v).is_integer():
                s = str(int(v))
                if s in BUILDING_NUM and fg == "FFFFFF":
                    btype = BUILDING_NUM[s]
            if btype is None and fg in WALL_FILL:
                btype = WALL_FILL[fg]
            if btype is None:
                continue
            x, y = c - C0, r - R0
            # 表格里只允许把建筑放在草地上；水域 / 山地 / 森林上的数字视为无效，
            # 不再生成塔（用户口径：这些地方没有写建筑）。
            if terrain[y][x] != "grass":
                continue
            zid = zones_grid[y][x]
            start_buildings.append({
                "type": btype,
                "x": x,
                "y": y,
                "owner": owners.get(zid, ""),
            })

    # 守军：<n> = 1 将 + n 兵（用户确认不限制 11；校验侧对关卡摆放放开）。
    markers = []
    for r in range(R0, R1 + 1):
        for c in range(C0, C1 + 1):
            v = cell(r, c).value
            if isinstance(v, str) and v.startswith("<") and v.endswith(">"):
                n = int(v[1:-1])
                markers.append({"x": c - C0, "y": r - R0, "n": n, "zid": zones_grid[r - R0][c - C0]})
    markers.sort(key=lambda m: (m["y"], m["x"]))

    by_zone: Dict[int, List[Dict]] = {}
    for m in markers:
        by_zone.setdefault(m["zid"], []).append(m)

    start_units = []
    for fid, (x, y) in base_cells.items():
        start_units.append({
            "faction": fid,
            "kind": "general_0",
            "general_index": 1,
            "x": x,
            "y": y,
            "escort_count": 0,
            "escort_types": [],
        })

    gi = 1
    for zid in sorted(by_zone):
        for i, m in enumerate(by_zone[zid]):
            role = ROLE_ORDER[(i + zid) % len(ROLE_ORDER)]
            start_units.append({
                "faction": "enemy",
                "kind": "general",
                "general_index": gi,
                "unit_type": ROLE_TYPE[role],
                "x": m["x"],
                "y": m["y"],
                "escort_count": m["n"],
                "escort_types": [
                    {"type": t, "weight": w} for t, w in ROLE_ESCORTS[role]
                ],
                "ai": "garrison",
                "zone": zid,
            })
            gi += 1

    # 建筑属于地图本身：放进 map.json 的 `buildings`，不占关卡 start_buildings。
    # 这样山地上的哨塔 / 警戒塔也能保留（运行时 add_building 不检查可通行）。
    map_doc["buildings"] = start_buildings

    top_center = next(z for z in centers if z["raw"].startswith("人0"))
    level_doc = {
        "name": "合作任务·登神长阶",
        "mode": "coop",
        "map": MAP_ID,
        "players": [{"faction": "p1"}, {"faction": "p2"}],
        "factions": [
            {"id": "p1", "ai": "none", "base": [base_cells["p1"][0], base_cells["p1"][1]],
             "name": "蓝方", "color": "#5ac8ff", "playable": True},
            {"id": "p2", "ai": "none", "base": [base_cells["p2"][0], base_cells["p2"][1]],
             "name": "黄方", "color": "#ffd166", "playable": True},
            {"id": "df", "ai": "none", "name": "守军", "color": "#8ce08c", "playable": False},
            {"id": "enemy", "ai": "garrison", "name": "敌军", "color": "#e05a5a", "playable": False},
            {"id": "red1", "ai": "reddot", "name": "红点", "color": "#c9a0ff",
             "playable": False, "reddot_ai": REDDOT_AI},
        ],
        "allies": [["p1", "p2"], ["df", "enemy"], ["df", "red1"], ["enemy", "red1"]],
        "zones": level_zones,
        "start_units": start_units,
        "objectives": [
            {"for": "p1", "kind": "capture_zone", "zone": top_center["id"]},
            {"for": "p2", "kind": "capture_zone", "zone": top_center["id"]},
        ],
        "fail_conditions": [],
        "briefing": [
            "合作任务：从登神长阶底部出发，攻占顶部「人0」区划。",
            "各区划中心都有敌军守将盘踞；清掉守军后站住中心即可占领。",
            "红点会从长阶顶部两角持续增援，直接压向双方基地，注意回防。",
        ],
    }

    os.makedirs(MAP_DIR, exist_ok=True)
    with open(os.path.join(MAP_DIR, "map.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(map_doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(LEVEL_PATH, "w", encoding="utf-8", newline="\n") as f:
        json.dump(level_doc, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print("map:", os.path.join(MAP_DIR, "map.json"))
    print("level:", LEVEL_PATH)
    print("centers:", [(z["id"], z["raw"], z["x"], z["y"]) for z in centers])
    print("base_zone:", base_zone, "top_zone:", top_center["id"])
    print("zone sizes:", [(z["id"], len(z["tiles"])) for z in zone_list])
    print("buildings:", len(start_buildings), "markers:", len(markers), "units:", len(start_units))


if __name__ == "__main__":
    main()
