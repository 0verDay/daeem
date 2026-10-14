## test_diagonal.gd —— 八方向移动回归（本项目有意偏离 HTML 版的四连通的那一处）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const MapDataRes = preload("res://logic/map_data.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_diagonal"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_direction_sets(cfg)
	_test_diagonal_shortens_path(cfg)
	_test_no_corner_cutting(cfg)
	_test_corner_cut_switch(cfg)
	_test_cost_and_heuristic_agree(cfg)
	_test_switching_back_to_four(cfg)
	_test_wall_still_blocks(cfg)

func _spawn_enemy_far_from(w, base_b, cfg):
	for r in range(6, 13):
		for d in [Vector2i(r, 0), Vector2i(0, r), Vector2i(-r, 0), Vector2i(0, -r),
				Vector2i(r, r), Vector2i(-r, r), Vector2i(r, -r), Vector2i(-r, -r)]:
			var t: Vector2i = Vector2i(base_b.tx + d.x, base_b.ty + d.y)
			if not w.map.terrain_walkable(t.x, t.y):
				continue
			if w.building_at(t.x, t.y) != null:
				continue
			return w.spawn_enemy(t.x, t.y)
	return null

func _clear_zone_centers(w) -> void:
	for b in w.building_list.duplicate():
		if b.type == "zone_center":
			w.remove_building(b, true)
	w.refresh_ownership()

func _test_direction_sets(cfg) -> void:
	eq(GridRes.DIRS4.size(), 4, "DIRS4 仍然是四个方向")
	eq(GridRes.DIRS8.size(), 8, "DIRS8 是八个方向")
	eq(GridRes.DIRS4_DIAGONAL.size(), 4, "对角方向四个")

	var seen: Dictionary = {}
	for d in GridRes.DIRS8:
		seen[d] = true
	eq(seen.size(), 8, "DIRS8 里没有重复方向")
	var diag := 0
	var straight := 0
	for d in GridRes.DIRS8:
		if absi(d.x) + absi(d.y) == 1:
			straight += 1
		elif absi(d.x) == 1 and absi(d.y) == 1:
			diag += 1
	eq(straight, 4, "DIRS8 里 4 个正交方向")
	eq(diag, 4, "DIRS8 里 4 个对角方向")
	ok(GridRes.is_diagonal(Vector2i(1, 1)), "is_diagonal 认对角")
	ok(not GridRes.is_diagonal(Vector2i(1, 0)), "is_diagonal 不认正交")

	near(GridRes.step_length(Vector2i(1, 0)), 1.0, 1e-9, "直走一步的代价是 1")
	near(GridRes.step_length(Vector2i(1, 1)), GridRes.DIAGONAL_COST, 1e-9, "斜走一步的代价是 √2")
	near(GridRes.octile_distance(3, 0), 3.0, 1e-9, "octile：纯水平 = 曼哈顿")
	near(GridRes.octile_distance(2, 2), 2.0 * GridRes.DIAGONAL_COST, 1e-9, "octile：纯对角 = 2√2")
	near(GridRes.octile_distance(3, 1), GridRes.DIAGONAL_COST + 2.0, 1e-9, "octile(3,1) = 1 次斜走 + 2 次直走 = √2 + 2")

	var ok_admissible := true
	for dx in range(-6, 7):
		for dy in range(-6, 7):
			var oct := GridRes.octile_distance(dx, dy)
			var manhattan := float(absi(dx) + absi(dy))
			if oct > manhattan + 1e-9:
				ok_admissible = false
	ok(ok_admissible, "★ octile 不会超过曼哈顿（即可采纳，A* 仍然最优）")

	ok(GridRes.step_length(Vector2i(1, 1)) < 2.0, "★ 一步对角比两步正交便宜（所以八方向路程更短）")

func _test_diagonal_shortens_path(cfg) -> void:
	var w = require_world(cfg)
	_clear_zone_centers(w)
	var from := Vector2i(2, 2)
	var to := Vector2i(8, 5)          # dx=6, dy=3：最短路 = 3 斜 + 3 直 = 6 步
	var path = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, "p1")
	ok(path != null, "开阔地能找到路径")
	if path == null:
		return
	eq((path as Array).size(), 6, "★ 八方向最短路是 6 步（3 斜 + 3 直）")
	var diagonals := 0
	for i in range(path.size()):
		var prev: Vector2i = from if i == 0 else (path as Array)[i - 1]
		var step: Vector2i = (path as Array)[i]
		if absi(step.x - prev.x) == 1 and absi(step.y - prev.y) == 1:
			diagonals += 1
	eq(diagonals, 3, "★ 路径里恰好有 3 个对角步（不拗成直角）")

	var valid := true
	for i in range(path.size()):
		var prev: Vector2i = from if i == 0 else (path as Array)[i - 1]
		var step: Vector2i = (path as Array)[i]
		if maxi(absi(step.x - prev.x), absi(step.y - prev.y)) != 1:
			valid = false
	ok(valid, "每一步都是紧邻格（没有跳格）")

func _test_no_corner_cutting(cfg) -> void:
	var map = MapDataRes.load_from("res://data/maps/frontier/map.json", cfg)
	ok(map != null, "载入地图用于造对角障碍")
	if map == null:
		return
	var cx := 4
	var cy := 12
	map.terrain.set_cell(cx + 1, cy, MapDataRes.TERRAIN_MOUNTAIN)
	map.terrain.set_cell(cx, cy + 1, MapDataRes.TERRAIN_MOUNTAIN)
	map.rebuild_terrain_masks()
	var buildings := GridRes.new(map.cols, map.rows, null)

	ok(not PathfinderRes.passable(map, buildings, cfg, cx + 1, cy, "p1"), "右上角是障碍")
	ok(not PathfinderRes.passable(map, buildings, cfg, cx, cy + 1, "p1"), "左下角是障碍")
	ok(PathfinderRes.passable(map, buildings, cfg, cx, cy, "p1"), "出发点可通行")
	ok(PathfinderRes.passable(map, buildings, cfg, cx + 1, cy + 1, "p1"), "目标格可通行")

	ok(not PathfinderRes.diagonal_step_allowed(map, buildings, cfg, cx, cy, Vector2i(1, 1), "p1"),
		"★ 斜向穿过两个障碍的尖角被禁止")
	var from_pt := Vector2(float(cx) + 0.5, float(cy) + 0.5)
	var to_pt := Vector2(float(cx + 1) + 0.5, float(cy + 1) + 0.5)
	ok(not PathfinderRes.segment_clear(map, buildings, cfg, from_pt, to_pt, "p1"),
		"超覆盖直线判定也拒绝这条对角线")

	var path = PathfinderRes.find_path(map, buildings, cfg, Vector2i(cx, cy), Vector2i(cx + 1, cy + 1), "p1")
	ok(path != null, "对角堵住时仍然绕得过去")
	if path != null:
		ok((path as Array).size() >= 2, "★ 不能一步穿过去（至少要绕一格）")

func _test_corner_cut_switch(cfg) -> void:
	var map = MapDataRes.load_from("res://data/maps/frontier/map.json", cfg)
	var cx := 4
	var cy := 12
	map.terrain.set_cell(cx + 1, cy, MapDataRes.TERRAIN_MOUNTAIN)
	map.terrain.set_cell(cx, cy + 1, MapDataRes.TERRAIN_MOUNTAIN)
	map.rebuild_terrain_masks()
	var buildings := GridRes.new(map.cols, map.rows, null)

	var was: bool = cfg.bool_val("path.diagonal_corner_cut", false)
	cfg.path_diagonal_corner_cut = true
	ok(PathfinderRes.diagonal_step_allowed(map, buildings, cfg, cx, cy, Vector2i(1, 1), "p1"),
		"★ 开关打开后允许穿对角缝")
	var path = PathfinderRes.find_path(map, buildings, cfg, Vector2i(cx, cy), Vector2i(cx + 1, cy + 1), "p1")
	ok(path != null and (path as Array).size() == 1, "开关打开后一步就穿过去")
	cfg.path_diagonal_corner_cut = was

func _test_cost_and_heuristic_agree(cfg) -> void:
	var w = require_world(cfg)
	_clear_zone_centers(w)
	var from := Vector2i(1, 1)
	var to := Vector2i(9, 6)
	var path = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, "p1")
	ok(path != null, "开阔地有路径")
	if path == null:
		return
	var cost := 0.0
	var prev: Vector2i = from
	for step in (path as Array):
		var d: Vector2i = (step as Vector2i) - prev
		cost += GridRes.step_length(d)
		prev = step
	var oct := GridRes.octile_distance(to.x - from.x, to.y - from.y)
	near(cost, oct, 1e-6, "★ 实际路径代价 = octile 距离（代价与启发式同口径）")

func _test_switching_back_to_four(cfg) -> void:
	var was: bool = cfg.bool_val("path.diagonal", true)
	cfg.path_diagonal = false

	eq(GridRes.directions(cfg).size(), 4, "diagonal=false 时方向集退回四个")

	var w = require_world(cfg)
	ok(not w.map.diagonal, "地图也跟着按四连通做连通性修正")
	var from := Vector2i(2, 2)
	var to := Vector2i(8, 5)          # 四连通下最短路 = 6 + 3 = 9 步
	var path = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, "p1")
	ok(path != null, "四连通下也能找到路径")
	if path != null:
		eq((path as Array).size(), 9, "★ 切回四连通后是 9 步（曼哈顿），不再有对角步")
		var diagonals := 0
		var prev: Vector2i = from
		for step in (path as Array):
			var d: Vector2i = (step as Vector2i) - prev
			if absi(d.x) == 1 and absi(d.y) == 1:
				diagonals += 1
			prev = step
		eq(diagonals, 0, "四连通路径里没有任何对角步")

	cfg.path_diagonal = was
	eq(GridRes.directions(cfg).size(), 8, "恢复 diagonal=true 后方向集回到八个")

func _test_wall_still_blocks(cfg) -> void:
	var w = require_world(cfg)
	_clear_zone_centers(w)
	for b in w.building_list.duplicate():
		if b.type == "wall":
			w.remove_building(b, true)
	w.refresh_ownership()
	var base_b = w.find_base_of("p1")
	ok(base_b != null, "有大本营")
	if base_b == null:
		return

	var walled := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var x: int = base_b.tx + dx
			var y: int = base_b.ty + dy
			if not w.map.terrain_walkable(x, y):
				continue
			if w.add_building("wall", x, y, "p1") != null:
				walled += 1
	ok(walled >= 6, "大本营被整圈围住了（%d 段墙）" % walled)

	var e = _spawn_enemy_far_from(w, base_b, cfg)
	ok(e != null, "敌人已生成")
	if e == null:
		return
	var direct = PathfinderRes.find_path(w.map, w.buildings, cfg,
		Vector2i(e.tx, e.ty), Vector2i(base_b.tx, base_b.ty), "enemy")
	ok(direct == null, "★ 八方向下大本营仍然进不去（没有从墙缝钻进来）")

	var solid := 0
	var walls_seen := 0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var b = w.building_at(base_b.tx + dx, base_b.ty + dy)
			if b == null or b.type != "wall":
				continue
			walls_seen += 1
			if not PathfinderRes.passable(w.map, w.buildings, cfg, base_b.tx + dx, base_b.ty + dy, "enemy"):
				solid += 1
	eq(walls_seen, walled, "邻格里数出来的城墙数 = 刚才建的那几段")
	eq(solid, walled, "围圈的每一段墙对敌人都不可通行")
