"""mapfile.py —— 地图 JSON 的读写（Godot 格式）。

导出的文件就是 ``dev_gd_a/daeem/data/map_01.json`` 那一套加上两张网格：

    {
      "cols": 24, "rows": 16,

      "exists": [[1,1,...], ...],        // ★ 1 = 这个格子存在；0 = 地图外（Godot 里不可通行）
      "layout": ["...", "...", ...],     // 地形：'.' 草地  '^' 森林  '#' 山地

      "zones": [[-1,0,0,...], ...],      // ★ 地块 → 区块 id，-1 = 不属于任何区块
      "zone_list": [                     // ★ 区块表（名字；坐标是给人和脚本看的冗余信息）
        { "id": 0, "name": "A1", "x0": 0, "y0": 0, "x1": 3, "y1": 3, "tiles": [[0,0], ...] }
      ],

      "base": [12, 8],
      ...（导入时文件里有、而编辑器不管的字段原样带过去：general_spawns / buildings /
            units / pvp_points / _comment …）
    }

★ 读旧地图（没有 exists / zones 的 map_01.json）完全兼容：所有格子都算存在，
  区块按 config.json 的 zone_cols × zone_rows **均分**（与 zone.gd 的老行为一字不差），
  名字是 A1 / A2 …（行在前、列在后）。也就是说「打开旧图 → 直接导出」不会改变任何东西。
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .model import (
    CHAR_TERRAINS,
    ROW_LETTERS,
    TERRAIN_CHARS,
    TERRAIN_ORDER,
    MapError,
    MapModel,
    Zone,
)

#: 编辑器不负责编辑、但要原样带过去的字段（Godot 用它们生成据点 / 守军 / 多人起点）
PRESERVED_KEYS: Tuple[str, ...] = (
    "general_spawns",
    "buildings",
    "units",
    "pvp_points",
    "_comment",
)

#: 导出时写在 _comment 里的说明（Godot 读不读都行，是给手改 JSON 的人看的）
EDITOR_COMMENT: Tuple[str, ...] = (
    "DAEEM · 地图编辑器导出。",
    "exists：1 = 这个格子存在，0 = 地图外（Godot 里一律不可通行）。",
    "layout：'.' 草地　'^' 森林　'#' 山地；不存在的地块写 '.' 占位，一切以 exists 为准。",
    "zones：地块 → 区块 id（-1 = 不属于任何区块）；zone_list 里是区块的名字。",
    "base：大本营点位。其余出生点 / 预置建筑 / 预置单位由 Godot 脚本生成。",
)


# ----------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------

def _as_int(value, fallback: int = 0) -> int:
    """宽容地取整数（JSON 里的值可能是字符串 / 浮点 / None）。"""
    try:
        return int(value)
    except (TypeError, ValueError):
        return fallback


# ----------------------------------------------------------------------
# 读
# ----------------------------------------------------------------------

def load_map(path, cfg: Optional[dict] = None) -> MapModel:
    """读一张地图 JSON 成 MapModel。

    ⚠️ 必须按 **utf-8-sig** 读：Windows 记事本 / PowerShell 写出来的 UTF-8 文件常带 BOM，
    而 `json.loads` 见到 BOM 会直接报「不是合法 JSON」。地图是给人手改的文件，
    带 BOM 太常见了，不能在这里把人挡住。（实测踩到：拖一张带 BOM 的图进启动器，
    窗口一闪就没。）
    """
    p = Path(path)
    try:
        text = p.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise MapError("打不开地图文件：%s（%s）" % (p, exc)) from exc
    text = text.lstrip("\ufeff")          # 兜底：BOM 不在开头 / 双 BOM 的情况
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise MapError("不是合法 JSON：%s（%s）" % (p, exc)) from exc
    if not isinstance(data, dict):
        raise MapError("地图 JSON 的根必须是一个对象：%s" % p)
    return dict_to_model(data, cfg, source=str(p))


def dict_to_model(data: dict, cfg: Optional[dict] = None,
                  source: str = "") -> MapModel:
    """把地图 JSON 的字典变成 MapModel（不碰文件系统，方便测试）。"""
    cols = _as_int(data.get("cols"), 0)
    rows = _as_int(data.get("rows"), 0)
    layout = data.get("layout")
    if cols <= 0 or rows <= 0:
        if isinstance(layout, list) and layout and isinstance(layout[0], str):
            cols = max(len(r) for r in layout if isinstance(r, str))
            rows = len(layout)
        if cols <= 0 or rows <= 0:
            raise MapError("地图缺少可用的 cols / rows（%s）" % (source or "内存数据"))

    model = MapModel(cols, rows)

    # ---- 地形：三种来源按优先级 layout → terrain 网格 → 全草地
    # ⚠️ 文件里的 x/y 是**从 (0,0) 起算的网格下标**，而模型对外用世界坐标
    #    （origin 一张新地图是 (0,0)，所以现在两者一样；但这里必须显式换算，
    #    否则哪天模型带着 origin 进来就会静默错位）。
    ox, oy = model.origin_x, model.origin_y
    if isinstance(layout, list) and layout:
        for y, raw_row in enumerate(layout[:rows]):
            if not isinstance(raw_row, str):
                continue
            for x, ch in enumerate(raw_row[:cols]):
                model.terrain[model.idx(x + ox, y + oy)] = CHAR_TERRAINS.get(ch, "grass")
    elif isinstance(data.get("terrain"), list):
        grid = data["terrain"]
        for y, raw_row in enumerate(grid[:rows]):
            if not isinstance(raw_row, (list, tuple)):
                continue
            for x, value in enumerate(raw_row[:cols]):
                name = str(value).strip().lower()
                if name in TERRAIN_CHARS:
                    model.terrain[model.idx(x + ox, y + oy)] = name

    # ---- 存在与否
    exists_raw = data.get("exists")
    if exists_raw is None:
        model.existing = [True] * (cols * rows)
    else:
        flags = _read_flag_grid(exists_raw, cols, rows, source)
        if flags is None:
            model.existing = [True] * (cols * rows)
        else:
            model.existing = flags
    model.recount()          # ⚠️ 直接赋过 existing，必须重算缓存（见 MapModel.recount）

    # ---- 区块
    zones_raw = data.get("zones")
    if zones_raw is None:
        # 旧地图：按 config 的 zone_cols × zone_rows 均分（与 zone.gd 老行为一致）
        _fill_legacy_zones(model, cfg or {})
    else:
        _fill_zones_from_grid(model, zones_raw, data.get("zone_list"), source)

    # ---- 大本营
    base = data.get("base")
    if isinstance(base, (list, tuple)) and len(base) >= 2:
        bx, by = _as_int(base[0], -1), _as_int(base[1], -1)
        model.base = (bx, by) if model.in_bounds(bx, by) else None

    # ---- 阵营与大本营（地图编辑器加的：老地图没有这两个字段）
    _read_factions(model, data.get("factions"))
    _read_faction_bases(model, data.get("faction_bases"))

    # ---- 编辑器不管、但要原样带回去的字段
    for key, value in data.items():
        if key in ("cols", "rows", "exists", "layout", "terrain", "zones", "zone_list",
                   "base", "factions", "faction_bases"):
            continue
        model.extra[key] = value
    return model


## 读阵营表：`factions: [{"id": "p1", "name": "玩家", "color": "#ffd166"}]`。
##
## ⚠️ id 就是游戏里的阵营字符串，编辑器**不做合法性校验**（不认识也照读）：
##    导一张别人手写的图时把其中的阵营悄悄吃掉，比留着它更糟；
##    「游戏认不认识」只在导出前提醒（见 MapModel.problems）。
def _read_factions(model: MapModel, raw) -> None:
    if not isinstance(raw, list):
        return
    for item in raw:
        if isinstance(item, str):               # 也认 ["p1", "p2"] 这种极简写法
            model.add_faction(item)
            continue
        if not isinstance(item, dict):
            continue
        fid = str(item.get("id", "")).strip()
        if not fid:
            continue
        model.add_faction(fid, str(item.get("name", "")), str(item.get("color", "")))


## 读各方大本营：`faction_bases: {"p1": [12, 8], "p2": [4, 4]}`。
##
## ⚠️ 两个宽容点（都是「手写地图」的常态）：
##   · 坐标可以是 `[x, y]` 也可以是 `{"x":…, "y":…}`；
##   · 越界的坐标静默丢掉（留着一个图外的点位，Godot 侧会去找不存在的格子）。
## ⚠️ 阵营 id 在 factions 里没登记也不管：先记下来，导出时仍然写回去。
##    （大本营比阵营表更「硬」—— 它直接决定游戏里基地盖在哪。）
def _read_faction_bases(model: MapModel, raw) -> None:
    if not isinstance(raw, dict):
        return
    for fid, point in raw.items():
        key = str(fid).strip()
        if not key:
            continue
        x = y = None
        if isinstance(point, (list, tuple)) and len(point) >= 2:
            x, y = _as_int(point[0], -1), _as_int(point[1], -1)
        elif isinstance(point, dict):
            x, y = _as_int(point.get("x"), -1), _as_int(point.get("y"), -1)
        if x is None or y is None or not model.in_bounds(x, y):
            continue
        model.faction_bases[key] = (x, y)


def _read_flag_grid(raw, cols: int, rows: int, source: str) -> Optional[List[bool]]:
    """exists 的三种写法都认：[[0,1],[1,1]] / ["01","11"] / 扁平列表。"""
    out = [False] * (cols * rows)
    if isinstance(raw, list) and raw and isinstance(raw[0], (list, tuple, str)):
        got_any = False
        for y, row in enumerate(raw[:rows]):
            if isinstance(row, str):
                values = [_truthy(ch) for ch in row[:cols]]
            elif isinstance(row, (list, tuple)):
                values = [_truthy(v) for v in row[:cols]]
            else:
                continue
            for x, flag in enumerate(values):
                out[y * cols + x] = flag
                got_any = True
        return out if got_any else None
    if isinstance(raw, list) and len(raw) >= cols * rows:
        for i, v in enumerate(raw[:cols * rows]):
            out[i] = _truthy(v)
        return out
    return None


def _truthy(value) -> bool:
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "y")
    if isinstance(value, bool):
        return value
    try:
        return int(value) != 0
    except (TypeError, ValueError):
        return bool(value)


def _fill_zones_from_grid(model: MapModel, zones_raw, zone_list, source: str) -> None:
    """读 zones 网格（地块 → 区块 id）+ zone_list（名字）。"""
    if not isinstance(zones_raw, list):
        raise MapError("zones 必须是一个二维数组（%s）" % (source or "内存数据"))

    names: Dict[int, str] = {}
    if isinstance(zone_list, list):
        for item in zone_list:
            if not isinstance(item, dict):
                continue
            zid = _as_int(item.get("id"), -1)
            if zid < 0:
                continue
            name = str(item.get("name", "")).strip()
            if name:
                names[zid] = name

    by_id: Dict[int, Zone] = {}
    ox, oy = model.origin_x, model.origin_y
    for y, row in enumerate(zones_raw[:model.rows]):
        if isinstance(row, str):
            cells = [_as_int(part, -1) for part in row.replace(",", " ").split()]
        elif isinstance(row, (list, tuple)):
            cells = [_as_int(v, -1) for v in row]
        else:
            continue
        for x, zid in enumerate(cells[:model.cols]):
            if zid < 0 or not model.existing[model.idx(x + ox, y + oy)]:
                continue
            zone = by_id.get(zid)
            if zone is None:
                zone = Zone(zid, names.get(zid, ""))
                by_id[zid] = zone
            # 区块的 tiles 一律存**世界坐标**（模型对外都是世界坐标）
            zone.tiles.add((x - ox, y - oy))

    # zone_list 里注册过、但一个地块都没有的区块也要建出来（不然重命名 / 删不掉）
    for zid, name in names.items():
        if zid not in by_id:
            by_id[zid] = Zone(zid, name)

    model.zones = [by_id[k] for k in sorted(by_id)]
    model.zone_of = {}
    for zone in model.zones:
        for tile in zone.tiles:
            model.zone_of[model.idx(*model.view_of(*tile))] = zone.zone_id


def _fill_legacy_zones(model: MapModel, cfg: dict) -> None:
    """旧地图的占位区块：按 config 的 zone_cols × zone_rows 横竖均分。

    与 logic/zone.gd 的老实现逐位一致（含 id 与命名顺序），所以旧地图读进来再导出，
    游戏里的区块归属不会变。
    """
    zone_cfg = cfg.get("zone") if isinstance(cfg, dict) else None
    zone_cols = 6
    zone_rows = 4
    if isinstance(zone_cfg, dict):
        zone_cols = max(1, _as_int(zone_cfg.get("zone_cols"), 6))
        zone_rows = max(1, _as_int(zone_cfg.get("zone_rows"), 4))

    model.zones = []
    model.zone_of = {}
    ox, oy = model.origin_x, model.origin_y
    for zx in range(zone_cols):
        x0 = (zx * model.cols) // zone_cols
        x1 = (((zx + 1) * model.cols) // zone_cols) - 1
        for zy in range(zone_rows):
            y0 = (zy * model.rows) // zone_rows
            y1 = (((zy + 1) * model.rows) // zone_rows) - 1
            if x1 < x0 or y1 < y0:
                continue
            zid = zy * zone_cols + zx
            name = "%s%d" % (ROW_LETTERS[zy:zy + 1], zx + 1)
            zone = Zone(zid, name)
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    if model.existing[model.idx(x + ox, y + oy)]:
                        zone.tiles.add((x - ox, y - oy))     # 世界坐标
            for tile in zone.tiles:
                model.zone_of[model.idx(*model.view_of(*tile))] = zid
            model.zones.append(zone)


# ----------------------------------------------------------------------
# 写
# ----------------------------------------------------------------------

def model_to_dict(model: MapModel) -> dict:
    """MapModel → 可以直接 json.dump 的字典。

    ★ 导出的地图尺寸 = **已画地块的包围盒**（AABB），不是内存里的整张网格，
      也不是「画布有多大」（画布是无限的，没有尺寸这回事）。
      这一条是自动算出来的：`bounds()` 给出所有已画地块的最小/最大格子，
      宽高就写进 JSON 的 cols/rows，坐标整体搬到左上角 (0,0)。
      所以「往左上画（世界坐标是负的）」照样能正确导出 ——
      包围盒是相对的，绝对坐标是多少都不影响游戏里看到的地图。
    """
    box = model.bounds()
    if box is None:                       # 一个地块都没有 → 空地图
        return _empty_dict(model)
    x0, y0, x1, y1 = box
    cols = x1 - x0 + 1
    rows = y1 - y0 + 1
    # 世界坐标 (x, y) → 数组下标：导出循环跑的是世界坐标，取数据要走下标
    ox, oy = model.origin_x, model.origin_y

    exists_rows: List[List[int]] = []
    layout_rows: List[str] = []
    zone_rows: List[List[int]] = []
    for y in range(y0, y1 + 1):
        exists_row: List[int] = []
        layout_row: List[str] = []
        zone_row: List[int] = []
        for x in range(x0, x1 + 1):
            if not model.exists(x, y):
                # 包围盒内部的空洞 = 地图外的虚线格
                exists_row.append(0)
                layout_row.append(".")
                zone_row.append(-1)
                continue
            i = model.idx(x + ox, y + oy)
            exists_row.append(1)
            layout_row.append(TERRAIN_CHARS.get(model.terrain[i], "."))
            zone_row.append(model.zone_of.get(i, -1))
        exists_rows.append(exists_row)
        layout_rows.append("".join(layout_row))
        zone_rows.append(zone_row)

    zone_list: List[dict] = []
    for zone in sorted(model.zones, key=lambda z: z.zone_id):
        tile_count = 0
        min_x = min_y = 1 << 30
        max_x = max_y = -(1 << 30)
        tiles: List[List[int]] = []
        for (tx, ty) in sorted(zone.tiles, key=lambda t: (t[1], t[0])):
            if not model.in_bounds(tx, ty):
                continue
            tile_count += 1
            min_x, min_y = min(min_x, tx), min(min_y, ty)
            max_x, max_y = max(max_x, tx), max(max_y, ty)
            tiles.append([tx - x0, ty - y0])      # 搬到左上角
        if tile_count == 0:
            min_x = min_y = max_x = max_y = 0
        zone_list.append({
            "id": zone.zone_id,
            "name": zone.name,
            "x0": min_x - x0, "y0": min_y - y0,
            "x1": max_x - x0, "y1": max_y - y0,
            "tile_count": tile_count,
            "tiles": tiles,
        })

    out: Dict[str, object] = {}
    for key in PRESERVED_KEYS:
        if key in model.extra:
            out[key] = model.extra[key]
    if "_comment" not in out:
        out["_comment"] = list(EDITOR_COMMENT)

    out["cols"] = cols
    out["rows"] = rows
    out["exists"] = exists_rows
    out["layout"] = layout_rows
    out["zones"] = zone_rows
    out["zone_list"] = zone_list
    out["base"] = _base_point(model, (x0, y0))
    _write_factions(out, model)
    _write_faction_bases(out, model, (x0, y0))
    return out


## 写阵营表与各方大本营。
##
## ★ 两个字段都**只在真的有阵营时才写**：没有阵营的地图导出后与从前逐字节一致 ——
##   这条对「打开旧图什么都不改再导出」很重要（tests/test_model.py 里钉着）。
## ★ 阵营大本营的坐标要**搬到导出坐标系**（和 zone_list 的 tiles、base 同样的处理）：
##   编辑器的画布可以往左上画，导出后地图左上角必须是 (0,0)。
def _write_factions(out: Dict[str, object], model: MapModel) -> None:
    if not model.factions:
        return
    out["factions"] = [
        {"id": f.faction_id, "name": f.name, "color": f.color} for f in model.factions
    ]


def _write_faction_bases(out: Dict[str, object], model: MapModel, origin: Tuple[int, int]) -> None:
    if not model.factions and not model.faction_bases:
        return
    ox, oy = origin
    bases: Dict[str, List[int]] = {}
    for faction in model.factions:                  # 按 factions 的顺序写，方便人读
        tile = model.faction_bases.get(faction.faction_id)
        if tile is not None:
            bases[faction.faction_id] = [tile[0] - ox, tile[1] - oy]
    # 大本营比阵营表更硬：只登记了大本营、没登记阵营的（手写地图）也要写出去
    for fid, tile in model.faction_bases.items():
        if fid not in bases:
            bases[fid] = [tile[0] - ox, tile[1] - oy]
    if bases:
        out["faction_bases"] = bases


## 空地图（一个地块都没有）导出成 0×0 + 空网格 —— Godot 读进来是一张空地图。
def _empty_dict(model: MapModel) -> dict:
    out: Dict[str, object] = {}
    for key in PRESERVED_KEYS:
        if key in model.extra:
            out[key] = model.extra[key]
    out["_comment"] = list(EDITOR_COMMENT)
    out["cols"] = 0
    out["rows"] = 0
    out["exists"] = []
    out["layout"] = []
    out["zones"] = []
    out["zone_list"] = []
    out["base"] = [0, 0]
    # 空地图也可能已经有阵营（先建阵营、还没画地）—— 阵营表照写，
    # 但大本营一律不写（一个地块都没有，坐标无从谈起）。
    _write_factions(out, model)
    return out


## 导出时写哪个 base：
##   · 用户设过 → 就用他设的那个（搬到导出的新坐标里）；
##   · 没设 → 退到**已画地块的包围盒中心**，而不是整张网格的中心。
##     ⚠️ 别改成 cols//2：编辑器的画布会随画的地方生长（可能长到几百格），
##     而地块往往只占一角 —— 那样写出来的 base 会落在空地中央，
##     游戏里大本营就被放到离玩家画的地方很远的位置。
def _base_point(model: MapModel, origin: Tuple[int, int]) -> List[int]:
    ox, oy = origin
    if model.base is not None:
        return [int(model.base[0]) - ox, int(model.base[1]) - oy]
    box = model.bounds()
    if box is None:
        return [0, 0]
    x0, y0, x1, y1 = box
    return [(x0 + x1) // 2 - ox, (y0 + y1) // 2 - oy]


def dumps(model: MapModel, indent: int = 2) -> str:
    return json.dumps(model_to_dict(model), ensure_ascii=False, indent=indent)


def save_map(path, model: MapModel, indent: int = 2) -> Path:
    """导出地图 JSON（UTF-8，末尾带换行，与仓库里其它 JSON 一致）。"""
    p = Path(path)
    if p.parent and not p.parent.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
    text = dumps(model, indent=indent) + "\n"
    p.write_text(text, encoding="utf-8")
    return p


# ----------------------------------------------------------------------
# 新建空地图
# ----------------------------------------------------------------------

def empty_map(cols: int, rows: int, start_terrain: Optional[str] = None) -> MapModel:
    """新建一张地图。

    ``start_terrain`` 为 None → 整张画布都是「不存在」的虚线格（从零开始画）；
    给一个地形 id（"grass" / "forest" / "mountain"）→ 整张画布先铺满这种地形。
    """
    model = MapModel(cols, rows)
    if start_terrain is not None:
        if start_terrain not in TERRAIN_CHARS:
            start_terrain = TERRAIN_ORDER[0]
        model.existing = [True] * (cols * rows)
        model.terrain = [start_terrain] * (cols * rows)
    return model
