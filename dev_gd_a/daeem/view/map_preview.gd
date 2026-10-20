## map_preview.gd —— ★ 战役过渡画面里的**战场缩略图**（左面板）
##
## 纯 `_draw()`，不读任何图片资源：把 `Level.map` 的地形烘成一张 1 像素/格的贴图，
## 再叠上「区划边界 / 目标区高亮 / 双方大本营 / 开局出生点」。
## 配色与游戏内小地图同源（`config.json` 的 `colors.grass/forest/mountain`），
## 一眼能认出「这块就是那一仗的地形」。
##
## ★ 为什么不用 3D 预渲染截图：
##   过渡画面要在**进游戏之前**出现，那时还没有世界与相机；而地图数据已经随关卡载入
##   （`Level.map`），直接画它既快又不会因为窗口比例不同而糊。
##
## ★ 坐标：所有绘制都在控件本地坐标；`_map_rect()` 按地图宽高比**居中**放进面板，
##   四周留 `PADDING`。缩放用 NEAREST（1 像素/格的贴图放大后仍是硬边小方块）。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const SideColorRes = preload("res://view/side_color.gd")

const PADDING := 14.0
const ZONE_LINE_ALPHA := 0.42
## 区划归属的淡底（与游戏内地面同一档 0.22；只在本缩略图上用）。
const ZONE_OWNER_ALPHA := 0.22
const OBJECTIVE_FILL := Color(1.0, 0.84, 0.40, 0.20)
const OBJECTIVE_LINE := Color(1.0, 0.84, 0.40, 0.90)
const BASE_SIZE := 10.0
const SPAWN_SIZE := 3.5

var cfg: ConfigRes = null
var level = null
var _map = null
var _terrain_tex: ImageTexture = null
var _map_px: Rect2 = Rect2()
## ★★ 过渡画面当前的「我方视角」：选中的可玩阵营 id；空串 = 还没选（标识全部灰色）。
var view_faction: String = ""

var _c_grass := Color(0.16, 0.24, 0.16)
var _c_grass_alt := Color(0.14, 0.21, 0.15)
var _c_forest := Color(0.10, 0.18, 0.12)
var _c_mountain := Color(0.22, 0.20, 0.17)
var _c_water := Color(0.18, 0.31, 0.40)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	resized.connect(_on_resized)


func setup(p_cfg: ConfigRes, p_level) -> void:
	cfg = p_cfg
	level = p_level
	_map = level.map if level != null else null
	if cfg != null:
		_c_grass = cfg.color("grass")
		_c_grass_alt = cfg.color("grass_alt")
		_c_forest = cfg.color("forest")
		_c_mountain = cfg.color("mountain")
		_c_water = cfg.color("water")
	_build_terrain()
	queue_redraw()


## 切换「我方视角」：过渡画面里选中 / 更换可玩阵营时调。
## 空串 = 还没选 ⇒ 所有标识用灰色（用户口径：「没有选中可玩阵营时用灰色标识」）。
func set_view_faction(fid: String) -> void:
	var v := String(fid).strip_edges()
	if v == view_faction:
		return
	view_faction = v
	queue_redraw()


func _on_resized() -> void:
	queue_redraw()


# ------------------------------------------------------------------
# 对外状态（测试 / 排查）
# ------------------------------------------------------------------

func map_rect() -> Rect2:
	return _map_px


func has_map() -> bool:
	return _map != null


func objective_zone_ids() -> Array:
	var out: Array = []
	if level == null:
		return out
	for raw in level.objectives:
		var d: Dictionary = raw
		var z := int(d.get("zone", -1))
		if z >= 0 and not out.has(z):
			out.append(z)
	return out


func base_count() -> int:
	return _collect_bases().size()


func spawn_count() -> int:
	var n: int = 0
	if level != null:
		n += level.start_units.size()
	if _map != null:
		n += _map.general_spawns.size()
	return n


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	_map_px = _fit_rect()
	if _map == null or _map.cols <= 0 or _map.rows <= 0:
		_draw_empty()
		return
	if _terrain_tex != null:
		draw_texture_rect(_terrain_tex, _map_px, false)

	# ★★ 区划归属的淡底：与游戏内地面同一条「敌 / 友 / 己」三色口径（本轮新增）。
	_draw_zone_ownership()
	_draw_objective_fill()
	_draw_zone_borders()
	_draw_objective_outline()
	_draw_spawns()
	_draw_bases()


func _fit_rect() -> Rect2:
	if _map == null or _map.cols <= 0 or _map.rows <= 0:
		return Rect2(Vector2.ZERO, size)
	var avail := size - Vector2(PADDING, PADDING) * 2.0
	if avail.x <= 0.0 or avail.y <= 0.0:
		return Rect2(Vector2.ZERO, size)
	var scale: float = minf(avail.x / float(_map.cols), avail.y / float(_map.rows))
	var w := float(_map.cols) * scale
	var h := float(_map.rows) * scale
	return Rect2(
		Vector2(PADDING + (avail.x - w) * 0.5, PADDING + (avail.y - h) * 0.5),
		Vector2(w, h))


func _cell() -> float:
	if _map == null or _map.cols <= 0:
		return 0.0
	return _map_px.size.x / float(_map.cols)


func _tile_rect(x: int, y: int) -> Rect2:
	var c := _cell()
	return Rect2(_map_px.position + Vector2(float(x), float(y)) * c, Vector2(c, c))


func _zone_at(x: int, y: int) -> int:
	var grid: Array = _map.zones_grid
	if y < 0 or y >= grid.size():
		return -1
	var row = grid[y]
	if typeof(row) != TYPE_ARRAY:
		return -1
	var arr: Array = row
	if x < 0 or x >= arr.size():
		return -1
	return int(arr[x])


func _build_terrain() -> void:
	_terrain_tex = null
	if _map == null:
		return
	var cols: int = _map.cols
	var rows: int = _map.rows
	if cols <= 0 or rows <= 0:
		return
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
		for x in cols:
			if not _map.tile_exists(x, y):
				continue
			var t := String(_map.terrain.get_cell(x, y))
			var c: Color = _c_grass if (x + y) % 2 == 0 else _c_grass_alt
			if t == "mountain":
				c = _c_mountain
			elif t == "water":
				c = _c_water
			elif t == "forest":
				c = _c_forest
			img.set_pixel(x, y, c)
	_terrain_tex = ImageTexture.create_from_image(img)


func _draw_empty() -> void:
	draw_rect(Rect2(Vector2(PADDING, PADDING), size - Vector2(PADDING, PADDING) * 2.0),
		ThemeRes.bg_bottom(), true)
	draw_rect(Rect2(Vector2(PADDING, PADDING), size - Vector2(PADDING, PADDING) * 2.0),
		ThemeRes.line_soft(), false, 1.0)


## ★★ 区划归属的淡底：按 owner 上「敌 / 友 / 己」三色（未选阵营时统一灰）。
## ★ 只画**有主**的区划；无主（owner == ""）仍露出地形，不盖色。
func _draw_zone_ownership() -> void:
	if _map == null or _map.zones_grid.is_empty():
		return
	var cache: Dictionary = {}
	for y in _map.rows:
		for x in _map.cols:
			if not _map.tile_exists(x, y):
				continue
			var zid := _zone_at(x, y)
			if zid < 0:
				continue
			var owner := _owner_of_zone(zid)
			if owner == "":
				continue
			if not cache.has(owner):
				var base: Color = zone_owner_color(owner)
				cache[owner] = Color(base.r, base.g, base.b, ZONE_OWNER_ALPHA)
			draw_rect(_tile_rect(x, y), cache[owner], true)


## 某个 owner 在缩略图里的颜色（三色 / 未选阵营时的灰）—— 测试与上面的淡底共用。
func zone_owner_color(owner: String) -> Color:
	return SideColorRes.color_with_allies(cfg, view_faction, owner, _allies())


## 区划的开局归属：**关卡覆盖层优先**（`level.zone_owners`），否则地图 `zones_owners`。
## ⚠️ 关卡里写 `"owner": ""` 是「显式清空」，所以必须用 `has()` 判，不能只看值非空。
func _owner_of_zone(zid: int) -> String:
	if level != null and level.zone_owners.has(zid):
		return String(level.zone_owners[zid])
	if _map != null and _map.zones_owners.has(zid):
		return String(_map.zones_owners[zid])
	return ""


## 本关的盟友表（关卡写了就用关卡的，否则地图的；与运行时同一份 `effective_allies()`）。
func _allies() -> Array:
	if level != null and level.has_method("effective_allies"):
		return level.effective_allies()
	return []


func _draw_objective_fill() -> void:
	var zs: Array = objective_zone_ids()
	if zs.is_empty():
		return
	for y in _map.rows:
		for x in _map.cols:
			if not _map.tile_exists(x, y):
				continue
			if not zs.has(_zone_at(x, y)):
				continue
			draw_rect(_tile_rect(x, y), OBJECTIVE_FILL, true)


func _draw_zone_borders() -> void:
	var c := _cell()
	if c <= 0.0:
		return
	var col := ThemeRes.line()
	col.a = ZONE_LINE_ALPHA
	for y in _map.rows:
		for x in _map.cols:
			if not _map.tile_exists(x, y):
				continue
			var z := _zone_at(x, y)
			var r := _tile_rect(x, y)
			if x + 1 < _map.cols and _map.tile_exists(x + 1, y) \
					and _zone_at(x + 1, y) != z:
				draw_line(Vector2(r.end.x, r.position.y), r.end, col, 1.0, true)
			if y + 1 < _map.rows and _map.tile_exists(x, y + 1) \
					and _zone_at(x, y + 1) != z:
				draw_line(Vector2(r.position.x, r.end.y), r.end, col, 1.0, true)


func _draw_objective_outline() -> void:
	var zs: Array = objective_zone_ids()
	if zs.is_empty():
		return
	for y in _map.rows:
		for x in _map.cols:
			if not _map.tile_exists(x, y):
				continue
			var z := _zone_at(x, y)
			if not zs.has(z):
				continue
			var r := _tile_rect(x, y)
			if _zone_at(x - 1, y) != z:
				draw_line(r.position, Vector2(r.position.x, r.end.y),
					OBJECTIVE_LINE, 2.0, true)
			if _zone_at(x + 1, y) != z:
				draw_line(Vector2(r.end.x, r.position.y), r.end,
					OBJECTIVE_LINE, 2.0, true)
			if _zone_at(x, y - 1) != z:
				draw_line(r.position, Vector2(r.end.x, r.position.y),
					OBJECTIVE_LINE, 2.0, true)
			if _zone_at(x, y + 1) != z:
				draw_line(Vector2(r.position.x, r.end.y), r.end,
					OBJECTIVE_LINE, 2.0, true)


func _draw_bases() -> void:
	for e in _collect_bases():
		var d: Dictionary = e
		var p: Vector2 = _tile_center(d["pos"])
		var r := Rect2(p - Vector2(BASE_SIZE, BASE_SIZE) * 0.5,
			Vector2(BASE_SIZE, BASE_SIZE))
		draw_rect(r, d["color"], true)
		draw_rect(r, Color(0.05, 0.06, 0.07, 0.9), false, 2.0)


func _draw_spawns() -> void:
	if level != null:
		for raw in level.start_units:
			var u: Dictionary = raw
			var p := _tile_center(Vector2i(int(u.get("x", -1)), int(u.get("y", -1))))
			if p == Vector2(-1.0, -1.0):
				continue
			var s := SPAWN_SIZE * (1.5 if String(u.get("kind", "")) == "general" else 1.0)
			draw_rect(Rect2(p - Vector2(s, s) * 0.5, Vector2(s, s)),
				_faction_color(String(u.get("faction", ""))), true)
	if _map != null:
		for raw2 in _map.general_spawns:
			var t: Vector2i = raw2
			var p2 := _tile_center(t)
			draw_rect(Rect2(p2 - Vector2(SPAWN_SIZE, SPAWN_SIZE) * 0.5,
				Vector2(SPAWN_SIZE, SPAWN_SIZE)), Color(1, 0.9, 0.6, 0.75), true)


## 把格子坐标换成控件内像素（越界 / -1 → (-1,-1)）。
func _tile_center(t: Vector2i) -> Vector2:
	if _map == null or t.x < 0 or t.y < 0 or t.x >= _map.cols or t.y >= _map.rows:
		return Vector2(-1.0, -1.0)
	var r := _tile_rect(t.x, t.y)
	return r.position + r.size * 0.5


func _collect_bases() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	if level != null:
		for raw in level.players:
			var d: Dictionary = raw
			_add_base(out, seen, String(d.get("faction", "")), _as_tile(d.get("base", null)))
		for raw2 in level.faction_meta:
			var f: Dictionary = raw2
			_add_base(out, seen, String(f.get("id", "")), _as_tile(f.get("base", null)))
	if _map != null:
		for fid in _map.faction_bases.keys():
			_add_base(out, seen, String(fid), _as_tile(_map.faction_bases[fid]))
	return out


func _add_base(out: Array, seen: Dictionary, fid: String, t: Vector2i) -> void:
	if fid == "" or t.x < 0 or t.y < 0:
		return
	var key := "%s@%d,%d" % [fid, t.x, t.y]
	if seen.has(key):
		return
	seen[key] = true
	out.append({"pos": t, "color": _faction_color(fid)})


func _as_tile(v) -> Vector2i:
	if v is Vector2i:
		return v
	if v is Vector2:
		return Vector2i(v)
	if v is Array and (v as Array).size() >= 2:
		return Vector2i(int(v[0]), int(v[1]))
	return Vector2i(-1, -1)


## 标识颜色（大本营 / 将领出生点）：与区划归属**同一套三色**。
## ★ 未选可玩阵营（`view_faction == ""`）时是灰色 —— 用户口径要求「没选时用灰色标识」。
func _faction_color(fid: String) -> Color:
	return zone_owner_color(fid)
