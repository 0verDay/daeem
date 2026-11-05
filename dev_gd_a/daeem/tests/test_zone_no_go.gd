## test_zone_no_go.gd —— 区划**禁行区**（用户需求：「阵地性 AI 不会巡逻至其区划的禁行区」）。
##
## 这一套钉住四件事：
##   1. 关卡 JSON 的 `zones[].no_go` 能被读进来（去重 / 丢掉坏点 / 缺字段不算错）；
##   2. `zone.apply_no_go()` 只收「属于这条区划」的格子（别人的地 / 地图外 / 没写过的
##      区划号一律忽略），并且查询是「按区划」而不是全图；
##   3. 阵地性 AI 的**巡逻路线一个禁行格都不踩**（`_build_route` / `_patrol_fallback_tile`），
##      整块区划都被禁时干脆原地待命（返回 (-1,-1)），绝不走进去；
##   4. 校验的五个 code（缺区划 / 越界 / 不属于它 / 盖中心 / 整块）与「没配就不报」。
##
## ⚠️ 这里**不**测「寻路绕开禁行格」：用户口径明确是「只避开巡逻目标点」，
##    不挡走路、不影响追击 / 守中心 / 攻城警报（见 `logic/zone.gd` 的 `no_go_by_id`）。
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const MapDataRes = preload("res://logic/map_data.gd")

const MAP_ID := "frontier"

func _initialize() -> void:
	_case_name = "test_zone_no_go"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var map = MapDataRes.load_from("res://data/maps/%s/map.json" % MAP_ID, cfg)
	ok(map != null, "（前提）地图「%s」能载入" % MAP_ID)
	if map == null:
		return
	_test_read(cfg)
	_test_apply_and_query(cfg, map)
	_test_patrol_avoids(cfg, map)
	_test_all_no_go_stops_patrol(cfg, map)
	_test_no_field_unchanged(cfg, map)
	_test_validation(cfg, map)

# ----------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------

## 一关的最小形状：地图 + 一个玩家席位 + 可选的 zones[] / start_units[]。
func _level_data(no_go_by_zone: Dictionary = {}, start_units: Array = [],
		factions: Array = []) -> Dictionary:
	var zones: Array = []
	for zid_v in no_go_by_zone.keys():
		var tiles: Array = []
		for t in (no_go_by_zone[zid_v] as Array):
			var p: Vector2i = t
			tiles.append([p.x, p.y])
		zones.append({"id": int(zid_v), "owner": "", "no_go": tiles})
	return {
		"map": MAP_ID,
		"players": [{"faction": "p1"}],
		"factions": factions,
		"zones": zones,
		"start_units": start_units,
	}

func _world(cfg, data: Dictionary):
	var lv = LevelRes.from_data(data, cfg)
	if lv == null:
		ok(false, "（前提）关卡能建出来")
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)

## 这一格属于哪个区划（`zones_grid`；只服务测试里的 frontier 图，行是数组）。
func _zone_at(map, x: int, y: int) -> int:
	if y < 0 or y >= map.zones_grid.size():
		return -1
	var row: Variant = map.zones_grid[y]
	if typeof(row) == TYPE_ARRAY:
		var arr: Array = row
		return int(arr[x]) if x >= 0 and x < arr.size() else -1
	if typeof(row) == TYPE_STRING:
		var parts := String(row).replace(",", " ").split(" ", false)
		return int(parts[x]) if x >= 0 and x < parts.size() else -1
	return -1

## 某条区划里**能站人**的格子（中心也包含在内；调用方自己排除）。
func _walkable_tiles(map, zid: int) -> Array:
	var out: Array = []
	for y in map.rows:
		for x in map.cols:
			if _zone_at(map, x, y) != zid:
				continue
			if map.terrain_walkable(x, y):
				out.append(Vector2i(x, y))
	return out

## 找一条「能站人的格子够多、且有中心」的区划。
func _pick_zone(map, need: int = 6) -> int:
	for zid_v in map.zones_centers.keys():
		var zid := int(zid_v)
		if _walkable_tiles(map, zid).size() >= need:
			return zid
	return -1

func _codes(lv) -> Array:
	var out: Array = []
	for i in lv.check([]):
		out.append(String((i as Dictionary)["code"]))
	return out

func _has_code(codes: Array, prefix: String) -> bool:
	for c in codes:
		if String(c).begins_with(prefix):
			return true
	return false

# ----------------------------------------------------------------------
# 1) 读关卡 JSON
# ----------------------------------------------------------------------

func _test_read(cfg) -> void:
	var lv = LevelRes.from_data({
		"map": MAP_ID,
		"players": [{"faction": "p1"}],
		"zones": [
			{"id": 0, "owner": "", "no_go": [[1, 1], [2, 2], [2, 2], [-1, -1], "坏点"]},
			{"id": 1, "owner": ""},                 # 没写 no_go = 这一区没有禁行格
			{"id": 2, "owner": "", "no_go": "nope"},  # 类型不对 = 当没写
		],
	}, cfg)
	ok(lv != null, "★ 带 no_go 的关卡能读出来")
	if lv == null:
		return
	eq(lv.zone_no_go.size(), 1, "★ 只有真的写了格子的区划才进表（1 条）")
	eq((lv.zone_no_go.get(0, []) as Array).size(), 2,
		"★★ 同一格写两遍只算一次、坏点丢掉")
	ok(not lv.zone_no_go.has(1), "★ 没写 no_go 的区划不在表里（不是空数组）")
	ok(not lv.zone_no_go.has(2), "★ no_go 类型不对 → 当没写，不崩")

# ----------------------------------------------------------------------
# 2) apply_no_go：只收「属于这条区划」的格子
# ----------------------------------------------------------------------

func _test_apply_and_query(cfg, map) -> void:
	var zid := _pick_zone(map)
	ok(zid >= 0, "（前提）找到一条够大的区划")
	if zid < 0:
		return
	var center: Vector2i = map.zones_centers[zid]
	var tiles := _walkable_tiles(map, zid)
	var mine: Vector2i = tiles[0]
	var other_zid := -1
	for z in map.zones_centers.keys():
		if int(z) != zid:
			other_zid = int(z)
			break
	var other_tile: Vector2i = _walkable_tiles(map, other_zid)[0]

	var w = _world(cfg, _level_data({
		zid: [mine, other_tile],
		999: [Vector2i(0, 0)],                     # 地图上没有的区划号 → 整条忽略
	}))
	ok(w != null, "★ 带 no_go 的世界能建出来")
	if w == null:
		return
	ok(w.zones.is_no_go(zid, mine.x, mine.y), "★★ 自己区划的禁行格查得到")
	ok(not w.zones.is_no_go(zid, other_tile.x, other_tile.y),
		"★★ 别的区划的格子**不会**被算进这条区划（装配时按归属过滤）")
	ok(not w.zones.is_no_go(other_zid, mine.x, mine.y),
		"★ 禁行区不跨区生效：别条区划查同一格是 false")
	ok(not w.zones.is_no_go(zid, -1, 0) and not w.zones.is_no_go(zid, 999, 999),
		"★ 越界查询是 false（不崩）")
	ok(not w.zones.no_go_by_id.has(999), "★ 不存在的区划号整条被忽略")
	eq(w.zones.no_go_tiles_of(zid), _sorted_tiles([mine]),
		"★ no_go_tiles_of 只返回真收下的那一格（按 (y,x) 排序）")

	# 边界：没有配 no_go 的关卡 → 整张表是空的（老行为）
	var w2 = _world(cfg, _level_data())
	ok(w2 != null and w2.zones.no_go_by_id.is_empty(),
		"★ 没配 no_go ⇒ `no_go_by_id` 是空表（老关卡行为不变）")

func _sorted_tiles(tiles: Array) -> Array:
	var out: Array = tiles.duplicate()
	out.sort_custom(func(a, b):
		var pa: Vector2i = a
		var pb: Vector2i = b
		return pa.y < pb.y or (pa.y == pb.y and pa.x < pb.x))
	return out

# ----------------------------------------------------------------------
# 3) 巡逻路线不踩禁行格
# ----------------------------------------------------------------------

func _test_patrol_avoids(cfg, map) -> void:
	var zid := _pick_zone(map, 8)
	if zid < 0:
		ok(false, "（前提）找到一条够大的区划（>= 8 格可站）")
		return
	var center: Vector2i = map.zones_centers[zid]
	var walkable := _walkable_tiles(map, zid)
	# 只留两格可巡逻（都不是中心），其余能站的全设成禁行 —— 路线只能落在这两格里。
	var keep: Array = []
	for t in walkable:
		var p: Vector2i = t
		if p != center and keep.size() < 2:
			keep.append(p)
	ok(keep.size() == 2, "（前提）至少有两格非中心的可站地")
	if keep.size() < 2:
		return
	var no_go: Array = []
	for t in walkable:
		var p: Vector2i = t
		if p == center or keep.has(p):
			continue
		no_go.append(p)
	ok(no_go.size() > 0, "（前提）确实禁掉了别的格子")

	var g_pos: Vector2i = keep[0]
	var w = _world(cfg, _level_data({zid: no_go}, [{
		"faction": "E1", "kind": "general", "unit_type": "spearman",
		"x": g_pos.x, "y": g_pos.y, "ai": "garrison", "zone": zid,
	}], [{"id": "E1", "ai": "garrison", "base": [g_pos.x, g_pos.y]}]))
	if w == null:
		return
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) == zid:
			g = u
			break
	ok(g != null, "★ 摆进去的守将带着归属区划")
	if g == null:
		return
	var z: Dictionary = w.zone_by_id(zid)
	var route: Array = GarrisonAiRes._build_route(w, cfg, g, z, 1)
	ok(route.size() > 0, "★★ 只留两格可巡逻时，路线仍然算得出来")
	if route.is_empty():
		return
	for t in route:
		var p: Vector2i = t
		ok(not w.zones.is_no_go(zid, p.x, p.y),
			"★★ 巡逻点 (%d,%d) 不在禁行区里" % [p.x, p.y])
		var here: Variant = w.zones.zone_at(p.x, p.y)
		ok(here != null and int((here as Dictionary)["id"]) == zid,
			"★ 巡逻点仍然在**自己的区划**里（(%d,%d)）" % [p.x, p.y])
		ok(keep.has(p), "★ 可挑的只剩那两格：路线点只能是它们之一（(%d,%d)）" % [p.x, p.y])
	ok(route.size() <= keep.size(), "★ 候选只有 %d 格 ⇒ 路线不会多于它" % keep.size())

# ----------------------------------------------------------------------
# 4) 整块区划都被禁行 → 原地待命（不走进去）
# ----------------------------------------------------------------------

func _test_all_no_go_stops_patrol(cfg, map) -> void:
	var zid := _pick_zone(map, 4)
	if zid < 0:
		ok(false, "（前提）找到一条区划")
		return
	var walkable := _walkable_tiles(map, zid)
	var g_pos: Vector2i = walkable[0]
	var w = _world(cfg, _level_data({zid: walkable}, [{
		"faction": "E1", "kind": "general", "unit_type": "spearman",
		"x": g_pos.x, "y": g_pos.y, "ai": "garrison", "zone": zid,
	}], [{"id": "E1", "ai": "garrison", "base": [g_pos.x, g_pos.y]}]))
	if w == null:
		return
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) == zid:
			g = u
			break
	ok(g != null, "（前提）守将在场")
	if g == null:
		return
	var z: Dictionary = w.zone_by_id(zid)
	eq(GarrisonAiRes._build_route(w, cfg, g, z, 1).size(), 0,
		"★★ 整块可站地都禁行 ⇒ 路线为空（不挑任何点）")
	eq(GarrisonAiRes._patrol_fallback_tile(w, g, z), Vector2i(-1, -1),
		"★★ 兜底点也是 (-1,-1)：中心与每一格都在禁行区里 ⇒ 这一帧没有可去的点")
	eq(GarrisonAiRes._next_patrol_tile(w, cfg, g, z, 1), Vector2i(-1, -1),
		"★★ `_next_patrol_tile` 返回 (-1,-1) ⇒ `_patrol_leader` 直接收队（原地待命）")
	g.stop()
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(not g.moving, "★★ 一帧之后它没有收到任何移动命令（不会走进禁行区）")
	ok(w.zones.is_no_go(zid, walkable[0].x, walkable[0].y),
		"（前提）那一格确实被标成禁行")

# ----------------------------------------------------------------------
# 5) 没有这个字段时行为不变（回归）
# ----------------------------------------------------------------------

func _test_no_field_unchanged(cfg, map) -> void:
	var zid := _pick_zone(map, 4)
	if zid < 0:
		return
	var g_pos: Vector2i = _walkable_tiles(map, zid)[0]
	var data := _level_data({}, [{
		"faction": "E1", "kind": "general", "unit_type": "spearman",
		"x": g_pos.x, "y": g_pos.y, "ai": "garrison", "zone": zid,
	}], [{"id": "E1", "ai": "garrison", "base": [g_pos.x, g_pos.y]}])
	var w = _world(cfg, data)
	if w == null:
		return
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) == zid:
			g = u
			break
	if g == null:
		ok(false, "（前提）守将在场")
		return
	var z: Dictionary = w.zone_by_id(zid)
	var r1: Array = GarrisonAiRes._build_route(w, cfg, g, z, 1)
	var r2: Array = GarrisonAiRes._build_route(w, cfg, g, z, 1)
	ok(r1.size() > 0, "★ 没配禁行区时路线照常算得出来（老行为）")
	eq(r1, r2, "★ 同一单位两次算出的路线逐位一致（确定性没被打破）")

# ----------------------------------------------------------------------
# 6) 校验：五个 code + 合法配置不报
# ----------------------------------------------------------------------

func _test_validation(cfg, map) -> void:
	var zid := _pick_zone(map, 4)
	if zid < 0:
		return
	var center: Vector2i = map.zones_centers[zid]
	var walkable := _walkable_tiles(map, zid)
	var other_zid := -1
	for z in map.zones_centers.keys():
		if int(z) != zid:
			other_zid = int(z)
			break

	var base := {
		"map": MAP_ID,
		"players": [{"faction": "p1"}],
		"factions": [{"id": "p1", "playable": true}],
		"objectives": [{"kind": "hold_zone", "zone": zid, "hold_sec": 30}],
	}

	# 合法：一格非中心的可站地
	var good_tile: Vector2i = center
	for t in walkable:
		if (t as Vector2i) != center:
			good_tile = t
			break
	var data_ok := base.duplicate(true)
	data_ok["zones"] = [{"id": zid, "owner": "p1", "no_go": [[good_tile.x, good_tile.y]]}]
	var lv_ok = LevelRes.from_data(data_ok, cfg)
	ok(lv_ok != null, "（前提）合法配置的关卡能建出来")
	if lv_ok != null:
		var codes_ok := _codes(lv_ok)
		ok(not _has_code(codes_ok, "zone_no_go_"),
			"★★ 合法配置不报任何 zone_no_go_*（实际：%s）" % str(codes_ok))

	# 盖住中心
	var data_center := base.duplicate(true)
	data_center["zones"] = [{"id": zid, "owner": "p1", "no_go": [[center.x, center.y]]}]
	var lv_center = LevelRes.from_data(data_center, cfg)
	if lv_center != null:
		var codes := _codes(lv_center)
		ok(codes.has("zone_no_go_center"), "★★ 盖住区划中心 → `zone_no_go_center`")

	# 写到别人的地上
	var other_tile: Vector2i = _walkable_tiles(map, other_zid)[0]
	var data_other := base.duplicate(true)
	data_other["zones"] = [{"id": zid, "owner": "p1",
		"no_go": [[other_tile.x, other_tile.y]]}]
	var lv_other = LevelRes.from_data(data_other, cfg)
	if lv_other != null:
		ok(_codes(lv_other).has("zone_no_go_tile_not_in_zone"),
			"★★ 格子不属于这条区划 → `zone_no_go_tile_not_in_zone`")

	# 地图外
	var data_out := base.duplicate(true)
	data_out["zones"] = [{"id": zid, "owner": "p1", "no_go": [[999, 999]]}]
	var lv_out = LevelRes.from_data(data_out, cfg)
	if lv_out != null:
		ok(_codes(lv_out).has("zone_no_go_tile_invalid"),
			"★★ 格子在地图外 → `zone_no_go_tile_invalid`")

	# 整块都被禁（全部可站地）
	var all_tiles: Array = []
	for t in walkable:
		var p: Vector2i = t
		all_tiles.append([p.x, p.y])
	var data_all := base.duplicate(true)
	data_all["zones"] = [{"id": zid, "owner": "p1", "no_go": all_tiles}]
	var lv_all = LevelRes.from_data(data_all, cfg)
	if lv_all != null:
		var codes_all := _codes(lv_all)
		ok(codes_all.has("zone_no_go_all"),
			"★★ 全部可站地都禁行 → `zone_no_go_all`")

	# 不存在的区划号
	var data_missing := base.duplicate(true)
	data_missing["zones"] = [{"id": 999, "owner": "", "no_go": [[0, 0]]}]
	var lv_missing = LevelRes.from_data(data_missing, cfg)
	if lv_missing != null:
		ok(_codes(lv_missing).has("zone_no_go_zone_missing"),
			"★★ 指向不存在的区划 → `zone_no_go_zone_missing`")
