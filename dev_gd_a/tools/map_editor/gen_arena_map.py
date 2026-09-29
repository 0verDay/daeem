"""gen_arena_map.py —— 一次性脚本：生成开场「地图选择条」用的**占位地图**。

为什么要有它：`daeem/logic/map_library.gd` 会**扫描 `data/maps/` 下的目录**、
每个目录里找一张地图 JSON，然后自动生成选择条上的选项。仓库里原本只有
`data/maps/frontier/`（随游戏发布的正式图），只有一个选项时「选项是扫出来的」
这件事看不出来 —— 所以补一张 `data/maps/arena/` 当第二个选项。

⚠️ 它**不是编辑器的一部分**，平时不用跑。想再补一张占位图时手动跑：

    python dev_gd_a/tools/map_editor/gen_arena_map.py

生成的地图刻意做得和 frontier 明显不同（16×12、两个大本营都在北侧、
区划是 2×2 而不是 6×4），这样「选择条上选了第二张图」在游戏里一眼就能看出
真的换了地图，而不只是换了个名字。
"""

from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE.parent) not in sys.path:
    sys.path.insert(0, str(HERE.parent))

from map_editor import mapfile                          # noqa: E402
from map_editor.model import (                          # noqa: E402
    MapModel,
    load_config,
    zone_kind_default,
    zone_kind_table,
)

#: 仓库里的 Godot 工程目录（读它的 data/config.json 拿区划种类表与默认配色）
PROJECT_DIR = HERE.parent.parent / "daeem"

#: 占位图的输出路径（一个地图一个目录，目录名 = 地图的 id）
OUT_PATH = PROJECT_DIR / "data" / "maps" / "arena" / "map.json"

ARENA_ID = "arena"
ARENA_NAME = "试炼场"

COLS = 16
ROWS = 12

#: 地形：'.' 草地  '^' 森林  '#' 山地。
#: ★ 刻意留了一小片山与几块林子（让画面与 frontier 一眼可分），但**不封死任何一片区域** ——
#:   `logic/map_data.gd` 的连通性修正会把走不到的可通行格塞成山，真封死了地图会缺一块。
LAYOUT = [
    "................",
    "................",
    "...###..........",
    "...###....^^^...",
    "..........^^^...",
    "................",
    "................",
    "................",
    "......^^^^......",
    "......^^^^......",
    "................",
    "................",
]

#: 两个阵营：玩家在西北、对家在东北（frontier 是西北 / 东南，容易一眼分辨）
FACTIONS = [
    ("p1", "p1", "#5AC8FF"),
    ("p2", "p2", "#FFD166"),
]
BASES = {"p1": (2, 8), "p2": (13, 3)}

#: 区划：2×2 均分（每块 8×6）—— frontier 用的是 6×4，所以两张图的区块结构也不同
ZONE_NAMES = {(0, 0): "西北", (1, 0): "东北", (0, 1): "西南", (1, 1): "东南"}
ZONE_KINDS = {
    (0, 0): "population", (1, 0): "gold",
    (0, 1): "food", (1, 1): "population",
}
ZONE_PRODUCTION = {
    "population": {"food": 0.0, "gold": 0.0, "population": 0.15},
    "food": {"food": 1.0, "gold": 0.0, "population": 0.1},
    "gold": {"food": 0.0, "gold": 1.0, "population": 0.1},
}


def build_model(cfg: dict) -> MapModel:
    """拼出占位地图的模型（地形 / 阵营 / 大本营 / 2×2 区划与中心）。"""
    kinds = zone_kind_table(cfg)
    model = MapModel(COLS, ROWS, kinds, zone_kind_default(cfg, kinds))

    # ---- 地形：整张图先铺草地，再按 LAYOUT 覆盖
    # ⚠️ 走 `create_tile()` 而不是直接赋值 `model.existing` / `model.terrain`：
    #    「已存在地块数」是 `set_existing()` 里增量维护的缓存，绕过它就要自己
    #    `recount()` —— 症状是导出时还以为图是空的（`bounds()` 返回 None）。
    legend = {".": "grass", "^": "forest", "#": "mountain"}
    for y in range(ROWS):
        for x in range(COLS):
            model.create_tile(x, y)
    for y, row in enumerate(LAYOUT[:ROWS]):
        for x, ch in enumerate(row[:COLS]):
            model.set_terrain(x, y, legend.get(ch, "grass"))

    # ---- 阵营与大本营
    for fid, name, color in FACTIONS:
        model.add_faction(fid, name, color)
    for fid, tile in BASES.items():
        if not model.set_faction_base(fid, tile[0], tile[1]):
            raise SystemExit("大本营设不上：%s %s" % (fid, tile))

    # ---- 区块：2×2 均分，每块按行优先挑一个中心（不与大本营同格）
    half_x, half_y = COLS // 2, ROWS // 2
    zone_ids: dict = {}
    for (cx, cy), name in ZONE_NAMES.items():
        zone = model.add_zone(name)
        zone_ids[(cx, cy)] = zone.zone_id
        model.set_zone_kind(zone.zone_id, ZONE_KINDS[(cx, cy)], apply_preset=True)
        for key, value in ZONE_PRODUCTION[ZONE_KINDS[(cx, cy)]].items():
            model.set_zone_production(zone.zone_id, key, value)

    for y in range(ROWS):
        for x in range(COLS):
            model.assign_tile(x, y, zone_ids[(x // half_x, y // half_y)])

    for (cx, cy), zid in zone_ids.items():
        model.set_zone_center(zid, cx * half_x + 1, cy * half_y + 1)

    return model


def main() -> int:
    cfg = load_config(PROJECT_DIR)
    model = build_model(cfg)

    blockers = model.blockers()
    if blockers:
        print("[error] 生成的图还过不了导出硬规则：%s" % "；".join(blockers))
        return 1
    for problem in model.problems():
        print("[warn] %s" % problem)

    # ★ 编辑器不编辑 id / name / placeholder，靠 PRESERVED_KEYS 原样带走（见 mapfile.py）
    model.extra["id"] = ARENA_ID
    model.extra["name"] = ARENA_NAME
    # ★ 占位图标记：选择条上它照样是一个选项，但「不选就按 test」默认进的那张
    #   会跳过它（`logic/map_library.gd` 的 default_map_path）—— 否则加一张测试图
    #    就把默认局换掉了，而这张图的地形 / 区划根本没调过。
    model.extra["placeholder"] = True

    mapfile.save_map(OUT_PATH, model)
    print("[ok] %s -> %d×%d, tiles=%d, zones=%d, factions=%d"
          % (OUT_PATH, model.cols, model.rows, model.existing_count(),
             len(model.zones), len(model.factions)))

    # 回读一遍：确认导出的文件真能被编辑器读回来（格式自洽）
    again = mapfile.load_map(OUT_PATH, cfg)
    print("[reload] %d×%d, tiles=%d, zones=%d, name=%r"
          % (again.cols, again.rows, again.existing_count(), len(again.zones),
             again.extra.get("name")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
