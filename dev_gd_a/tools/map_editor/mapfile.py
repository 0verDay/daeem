"""mapfile.py —— 地图 JSON 的读写（Godot 格式）。

导出的文件就是 ``dev_gd_a/daeem/data/test_map.json`` 那一套加上两张网格：

    {
      "cols": 17, "rows": 22,

      "exists": [[1,1,...], ...],        // ★ 1 = 这个格子存在；0 = 地图外（Godot 里不可通行）
      "layout": ["...", "...", ...],     // 地形：'.' 草地  '^' 森林  '#' 山地

      "zones": [[-1,0,0,...], ...],      // ★ 地块 → 区块 id，-1 = 不属于任何区块
      "zone_list": [                     // ★ 区块表（名字 / 区划中心 / 产能）
        { "id": 0, "name": "A1", "center": [2, 1],
          "production": {"food": 1.0, "gold": 1.0, "population": 0.5},
          "x0": 0, "y0": 0, "x1": 3, "y1": 3, "tiles": [[0,0], ...] }
      ],
      "zone_centers": [[-1,-1,0,-1], ...],  // ★ 地块 → 它是不是某个区划的中心（是就写那个区划 id）

      "faction_bases": {"p1": [2, 2], "p2": [14, 19]},
      ...（导入时文件里有、而编辑器不管的字段原样带过去：general_spawns / buildings /
            units / pvp_points / _comment …）
    }

★ 读旧地图（没有 exists / zones）完全兼容：所有格子都算存在，
  区块按 config.json 的 zone_cols × zone_rows **均分**（与 zone.gd 的老行为一字不差），
  名字是 A1 / A2 …（行在前、列在后），并**自动给每个区块挑一个中心**
  （该区块按行优先的第一个地块）—— 用户要求「每个区划都必须有中心」，
  自动挑一个是为了让「打开旧图 → 导出」这条路不会卡在「还差 24 个中心没设」上，
  设计者再按需要挪。旧格式里的单数 `base` 会被**迁移**成 p1 的大本营（见 `_migrate_legacy_base`）。
  （仓库里已经没有老图样本了：随游戏发布的只剩 `test_map.json`，
   `test_model.py` 里的老格式用例现在自己拼一张。）
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List, Optional, Tuple

from .model import (
    CHAR_TERRAINS,
    PRODUCTION_KEYS,
    ROW_LETTERS,
    TERRAIN_CHARS,
    TERRAIN_ORDER,
    MapError,
    MapModel,
    Zone,
)

#: 旧格式的单数 `base` 迁移给哪个阵营（见 `_migrate_legacy_base`）。
#:
#: ★ 用 'p1' 而不是编辑器里那些自编 id：`logic/faction.gd` 的 DEFAULT_FACTION 就是 'p1'，
#:   单机 / 房主都是它 —— 那个老点位本来就是「主阵营的出生点」。
MIGRATED_BASE_FACTION = "p1"

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
    "zone_list[].center：该区块的「区划中心」地块坐标；每个区块必须有且只有一个。",
    "zone_list[].production：该区块的产能（每地块每秒）：food / gold / population。",
    "zone_centers：地块 → 中心所属的区块 id（-1 = 不是任何区块的中心），由 center 推出来。",
    "factions / faction_bases：阵营表与每个阵营的大本营（每个阵营必须有且只有一个）。",
    "其余出生点 / 预置建筑 / 预置单位由 Godot 脚本生成。",
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

    # ★ 顺序有讲究：**大本营先读、区划中心后补**。
    #   补中心时要跳过「已经是某个阵营大本营」的格子（两者都会落成占格建筑，
    #   叠在一格会互相挡掉），所以必须先知道大本营在哪。
    # ---- 阵营与大本营（地图编辑器加的：老地图没有这两个字段）
    _read_factions(model, data.get("factions"))
    _read_faction_bases(model, data.get("faction_bases"))
    _migrate_legacy_base(model, data.get("base"))

    # ---- 区块
    zones_raw = data.get("zones")
    if zones_raw is None:
        # 旧地图：按 config 的 zone_cols × zone_rows 均分（与 zone.gd 老行为一致）
        _fill_legacy_zones(model, cfg or {})
    else:
        _fill_zones_from_grid(model, zones_raw, data.get("zone_list"), source)
    # 区块的中心与产能（编辑器加的字段；老地图没有 → 保持 None / 0）
    _read_zone_centers(model, data.get("zone_centers"))
    _read_zone_production(model, data.get("zone_list"))
    # ★ 每个区块都必须有中心：从文件里读不到（老地图 / 手写图）的，
    #   在这里**自动挑一个**（该区块按行优先的第一个非大本营地块），最后由 `blockers()`
    #   在导出前确保「一个都不少」。自动挑而不是留空，是为了让「打开旧图」这条路
    #   不会一上来就报 24 个「还没设区划中心」。
    fill_missing_centers(model)

    # ---- 编辑器不管、但要原样带回去的字段
    for key, value in data.items():
        if key in ("cols", "rows", "exists", "layout", "terrain", "zones", "zone_list",
                   "zone_centers", "base", "factions", "faction_bases"):
            continue
        model.extra[key] = value
    return model


## 旧格式的单数 `base`（地图中心 / 默认点位）→ 迁移成主阵营的大本营。
##
## ★ 为什么要迁移而不是丢掉：老格式的地图**只有**这个单数点位，
##   而「每个阵营都必须有大本营」现在是硬规则 —— 直接把 base 删掉会让老地图
##   一打开就导出不了，而那个点位其实是设计师认真选过的（p1 的出生点）。
## ★ 只在这一方**还没有**自己大本营、而且地图上登记了阵营时才迁移：
##   手写图里 base 与 faction_bases 同时存在时，faction_bases 说了算。
def _migrate_legacy_base(model: MapModel, raw) -> None:
    if model.faction_bases:
        return
    if not isinstance(raw, (list, tuple)) or len(raw) < 2:
        return
    x, y = _as_int(raw[0], -1), _as_int(raw[1], -1)
    if not model.in_bounds(x, y):
        return
    fid = MIGRATED_BASE_FACTION
    if model.faction(fid) is None:
        model.add_faction(fid)
    model.faction_bases[fid] = (x, y)


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


## 读区划中心网格：`zone_centers: [[-1,-1,0,-1], ...]` —— 值是「这一格是谁的中心」。
##
## ⚠️ 这是 `zone_list[].center` 的**冗余**表达（两个字段说的是同一件事）。
##    两边都在时的优先级：**zone_list[].center 说了算**，这个网格只当补充
##    （手写地图时可能只写其中一个）。
def _read_zone_centers(model: MapModel, raw) -> None:
    if not isinstance(raw, list):
        return
    ox, oy = model.origin_x, model.origin_y
    for y, row in enumerate(raw[:model.rows]):
        if isinstance(row, str):
            cells = [_as_int(part, -1) for part in row.replace(",", " ").split()]
        elif isinstance(row, (list, tuple)):
            cells = [_as_int(v, -1) for v in row]
        else:
            continue
        for x, zid in enumerate(cells[:model.cols]):
            if zid < 0:
                continue
            zone = model.zone(zid)
            if zone is None or zone.center is not None:
                continue                      # 没有这个区块 / 已经有中心了 → 不覆盖
            model.set_zone_center(zid, x - ox, y - oy)


## 读每个区块的产能：`zone_list[].production = {"food": 1, "gold": 1, "population": 0.5}`。
##
## 宽容点（与别处一致）：
##   · 缺 production / 缺某一档 → 那一档算 0（不是报错）；
##   · 不是数字的值（"abc"）→ 那一档算 0；
##   · 写成 `"production": 1.0`（单个数）也认 —— 当作**粮食**（手写地图时有人会省）。
def _read_zone_production(model: MapModel, zone_list) -> None:
    if not isinstance(zone_list, list):
        return
    for item in zone_list:
        if not isinstance(item, dict):
            continue
        zid = _as_int(item.get("id"), -1)
        if zid < 0 or model.zone(zid) is None:
            continue
        raw = item.get("production")
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            model.set_zone_production(zid, "food", raw)
            continue
        if not isinstance(raw, dict):
            continue
        for key in PRODUCTION_KEYS:
            if key in raw:
                model.set_zone_production(zid, key, raw[key])


## 给「还没有中心的区块」自动挑一个：该区块按行优先的第一个地块。
##
## ★ 只补空的，不动已经设过的 —— 设计者挪过的中心不能被导入流程改掉。
## ★ 跳过「已经是某个阵营大本营」的格子：游戏里大本营与区划中心都会落成占格建筑，
##   叠在同一格会互相挡掉（`set_zone_center()` 本来就拒绝，这里顺着它往下试下一格）。
## ★ 一个地块都还没有的空区块补不了（没有地方放），留给 `blockers()` 在导出前拦住。
def fill_missing_centers(model: MapModel) -> None:
    for zone in model.zones:
        if zone.center is not None:
            continue
        for (tx, ty) in sorted(zone.tiles, key=lambda t: (t[1], t[0])):
            if model.faction_base_owner(tx, ty) is not None:
                continue
            if model.set_zone_center(zone.zone_id, tx, ty):
                break


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
        entry: Dict[str, object] = {
            "id": zone.zone_id,
            "name": zone.name,
        }
        # 中心：每个区块都该有（`blockers()` 保证导出前一定有）；坐标同样搬到左上角
        if zone.center is not None:
            entry["center"] = [int(zone.center[0]) - x0, int(zone.center[1]) - y0]
        # 产能：只在真的有非零产能时才写 —— 没配产能的区块导出后与从前逐字节一致
        if model.zone_has_production(zone.zone_id):
            entry["production"] = {
                key: _clean_number(zone.production.get(key, 0.0)) for key in PRODUCTION_KEYS
            }
        entry["x0"] = min_x - x0
        entry["y0"] = min_y - y0
        entry["x1"] = max_x - x0
        entry["y1"] = max_y - y0
        entry["tile_count"] = tile_count
        entry["tiles"] = tiles
        zone_list.append(entry)

    # 地块 → 中心所属的区块 id（-1 = 不是任何区块的中心）。
    # ★ 与 zone_list[].center 是同一件事的两种写法：Godot 侧按格查中心更方便，
    #   人读 zone_list 更方便，两份都写出来（导出前 `blockers()` 已经保证它们一致）。
    center_rows: List[List[int]] = []
    for y in range(y0, y1 + 1):
        center_row: List[int] = []
        for x in range(x0, x1 + 1):
            owner = model.zone_center_owner(x, y) if model.exists(x, y) else None
            center_row.append(-1 if owner is None else owner)
        center_rows.append(center_row)

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
    out["zone_centers"] = center_rows
    _write_factions(out, model)
    _write_faction_bases(out, model, (x0, y0))
    return out


## 写进 JSON 的数字：整数就写整数（`1.0` → `1`），小数保留原值。
## 纯粹为了让导出的文件好读 —— `1` 比 `1.0` 更接近设计者填进去的东西。
def _clean_number(value) -> object:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0
    if abs(number - round(number)) < 1e-9:
        return int(round(number))
    return round(number, 4)


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
    out["zone_centers"] = []
    # 空地图也可能已经有阵营（先建阵营、还没画地）—— 阵营表照写，
    # 但大本营一律不写（一个地块都没有，坐标无从谈起）。
    _write_factions(out, model)
    return out


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
