## test_path_feel.gd —— 寻路手感回归（拐角圆化 / 贴边落点 / 近距离点选）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_path_feel"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_corner_rounding(cfg)
	_test_rounded_path_is_walkable(cfg)
	_test_own_base_landing(cfg)
	_test_hug_enemy_wall(cfg)
	_test_click_for_impassable(cfg)

func _run_move(cfg, from_tile: Vector2i, to_pt: Vector2) -> Dictionary:
	var w = require_world(cfg)
	var u = w.units[0]
	w.units = [u]
	u.stop()
	u.pos = GridRes.center_of(from_tile)
	u.sync_tile(w.map)
	u.order_move(w, cfg, to_pt)
	var path_pts: Array[Vector2] = u.path.duplicate()

	var trace: Array[Vector2] = [u.pos]
	var m := 0
	while u.moving and m < 6000:
		w.tick(DT)
		trace.append(u.pos)
		m += 1

	var max_turn := 0.0
	var turns_over_than_15 := 0
	for i in range(2, trace.size()):
		var d1: Vector2 = trace[i - 1] - trace[i - 2]
		var d2: Vector2 = trace[i] - trace[i - 1]
		if d1.length() > 1e-9 and d2.length() > 1e-9:
			var ang := rad_to_deg(absf(d1.normalized().angle_to(d2.normalized())))
			max_turn = maxf(max_turn, ang)
			if ang > 15.0:
				turns_over_than_15 += 1
	return {"world": w, "unit": u, "path": path_pts, "trace": trace,
		"max_turn": max_turn, "big_turns": turns_over_than_15, "frames": m, "end": u.pos}

func _pick_corner_route(cfg) -> Dictionary:
	var candidates := [
		[Vector2i(10, 10), Vector2i(4, 11)],
		[Vector2i(18, 17), Vector2i(12, 14)],
		[Vector2i(4, 6), Vector2i(25, 12)],
		[Vector2i(1, 3), Vector2i(18, 19)],
	]
	var was_enabled: bool = cfg.bool_val("path.corner_round_enabled", true)
	cfg.path_corner_round_enabled = false
	for c in candidates:
		var r: Dictionary = _run_move(cfg, c[0], GridRes.center_of(c[1]))
		print("   [corner] %s → %s：路径 %d 点，单帧最大转角 %.1f°" % [
			str(c[0]), str(c[1]), (r["path"] as Array).size(), float(r["max_turn"])])
		if (r["path"] as Array).size() >= 3 and float(r["max_turn"]) > 25.0:
			cfg.path_corner_round_enabled = was_enabled
			return {"from": c[0], "to": c[1], "raw": r}
	cfg.path_corner_round_enabled = was_enabled
	return {}

func _test_corner_rounding(cfg) -> void:
	var picked := _pick_corner_route(cfg)
	ok(not picked.is_empty(), "★ 找得到一条真有硬拐角的路线（换地图时这条要先过）")
	if picked.is_empty():
		return
	var from: Vector2i = picked["from"]
	var to: Vector2 = GridRes.center_of(picked["to"])
	var raw: Dictionary = picked["raw"]

	var was_enabled: bool = cfg.bool_val("path.corner_round_enabled", true)

	ok(float(raw["max_turn"]) > 20.0, "关闭圆化时单帧转角很大（实测 %.1f°，说明这条用例确实有硬拐角）" % raw["max_turn"])
	v2_near(raw["end"], to, 0.05, "关闭圆化时也能走到目标")

	cfg.path_corner_round_enabled = true
	var rounded := _run_move(cfg, from, to)
	ok((rounded["path"] as Array).size() > (raw["path"] as Array).size(),
		"★ 开启圆化后路径点变多（被细分成弧线）")
	ok(float(rounded["max_turn"]) < float(raw["max_turn"]) * 0.5,
		"★ 圆化把单帧转角压到原来的一半以下（%.1f° → %.1f°）" % [raw["max_turn"], rounded["max_turn"]])
	ok(float(rounded["max_turn"]) < 15.0, "★ 圆化后单帧转角小于 15°（实测 %.1f°）" % rounded["max_turn"])
	ok(int(rounded["frames"]) <= int(raw["frames"]) + 5, "圆化不会让路程变长（帧数 %d → %d）" % [raw["frames"], rounded["frames"]])
	v2_near(rounded["end"], to, 0.05, "★ 圆化后仍然精确到达点击位置（末点没被切掉）")

	cfg.path_corner_round_enabled = was_enabled

	var straight := _run_move(cfg, Vector2i(6, 14), GridRes.center_of(Vector2i(11, 14)))
	eq((straight["path"] as Array).size(), 1, "直线路径仍然是 1 个点（圆化对直线无副作用）")

func _test_rounded_path_is_walkable(cfg) -> void:
	var picked := _pick_corner_route(cfg)
	if picked.is_empty():
		ok(false, "圆化轨迹用例：先得挑到一条有拐角的路线")
		return
	var from: Vector2i = picked["from"]
	var to: Vector2 = GridRes.center_of(picked["to"])
	var r := _run_move(cfg, from, to)
	var w = r["world"]
	var u = r["unit"]
	var bad := 0
	for p in (r["trace"] as Array):
		var t := Vector2i(floori((p as Vector2).x), floori((p as Vector2).y))
		if not PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, u.faction):
			bad += 1
	eq(bad, 0, "★ 圆化后的轨迹全程都在可通行格上（没有靠圆角穿墙 / 翻山）")

	var pts: Array = r["path"]
	var pos0: Vector2 = GridRes.center_of(from)
	var prev := pos0
	var seg_bad := 0
	for p in pts:
		if not PathfinderRes.segment_clear(w.map, w.buildings, cfg, prev, p, u.faction):
			seg_bad += 1
		prev = p
	eq(seg_bad, 0, "圆化后的每一段都通过超覆盖直线判定")

func _test_own_base_landing(cfg) -> void:
	var w = require_world(cfg)
	var b = w.find_base_of("p1")
	ok(b != null, "有大本营")
	if b == null:
		return
	var u = w.units[0]

	var click: Vector2 = Vector2(float(b.tx) + 0.9, float(b.ty) + 0.5)
	var start := Vector2i(b.tx, b.ty + 1)
	u.stop()
	u.pos = GridRes.center_of(start)
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, click), "点大本营：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	var center := GridRes.center_of(Vector2i(b.tx, b.ty))
	ok(u.pos.distance_to(click) < 0.45,
		"★ 己方单位直接走到了大本营本体上的点击处（距点击点 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.distance_to(center) < 0.5, "落点在目标格内")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, u.tx, u.ty, u.faction),
		"★ 大本营那一格对己方是可通行的（本体不阻挡己方）")

func _test_hug_enemy_wall(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	var spot := Vector2i(-1, -1)
	for ty in range(3, w.map.rows - 3):
		for tx in range(3, w.map.cols - 3):
			if w.can_build_at(tx, ty):
				spot = Vector2i(tx, ty)
				break
		if spot.x >= 0:
			break
	ok(spot.x >= 0, "找得到一格空地放对家的墙")
	if spot.x < 0:
		return
	var wall = w.add_building("wall", spot.x, spot.y, "p2")
	ok(wall != null, "放下了 p2 的城墙")
	ok(not PathfinderRes.passable(w.map, w.buildings, cfg, spot.x, spot.y, u.faction),
		"p2 的城墙对 p1 不可通行（判定基准是 same_side）")

	var click: Vector2 = Vector2(float(spot.x) + 0.1, float(spot.y) + 0.5)
	u.stop()
	u.pos = GridRes.center_of(Vector2i(spot.x - 3, spot.y))
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, click), "点对家城墙：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	ok(u.pos.distance_to(click) < 0.6,
		"★ 落点贴着那堵墙（距点击点 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.x <= float(spot.x) + 0.05,
		"★ 从左边来就停在墙的左边（贴边落点，不钉到格心）")

func _test_click_for_impassable(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]

	var mountain := Vector2i(-1, -1)
	var region = PathfinderRes.reachable_tiles(w.map, w.buildings, cfg, Vector2i(u.tx, u.ty), u.faction)
	for y in w.map.rows:
		for x in w.map.cols:
			if w.map.terrain_walkable(x, y):
				continue
			for d in GridRes.DIRS8:
				var nb := Vector2i(x + d.x, y + d.y)
				if w.map.terrain.has(nb.x, nb.y) and PathfinderRes.in_region(region, w.map.terrain.idx(nb.x, nb.y)):
					mountain = Vector2i(x, y)
					break
			if mountain.x >= 0:
				break
		if mountain.x >= 0:
			break
	ok(mountain.x >= 0, "地图上有 p1 走得到的山")
	if mountain.x < 0:
		return
	var start := Vector2i(-1, -1)
	for d in GridRes.DIRS8:
		var nb := Vector2i(mountain.x + d.x, mountain.y + d.y)
		if w.map.terrain.has(nb.x, nb.y) and PathfinderRes.in_region(region, w.map.terrain.idx(nb.x, nb.y)):
			start = nb
			break
	u.stop()
	u.pos = GridRes.center_of(start)
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, GridRes.center_of(mountain)), "点山：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	var mc := GridRes.center_of(mountain)
	ok(u.pos.distance_to(mc) <= 1.05, "点山后贴到了山边（距山格心 %.3f 格）" % u.pos.distance_to(mc))
	ok(not PathfinderRes.occupied(w.buildings, u.tx, u.ty), "点山后没停在建筑上")

	var occ := PathfinderRes.occupied(w.buildings, u.tx, u.ty)
	ok(not occ, "落点有效（不是被占住的格子）")
