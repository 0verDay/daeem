## test_building_body.gd —— 建筑「本体」的碰撞与挡路规则（UI 改版之后新增的一整套）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CollisionRes = preload("res://logic/collision.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_building_body"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_geometry(cfg)
	_test_ally_passes(cfg)
	_test_enemy_blocked_by_body(cfg)
	_test_path_avoids_body(cfg)
	_test_gap_between_towers(cfg)
	_test_wall_unchanged(cfg)
	_test_map_outpost(cfg)

func _test_geometry(cfg) -> void:
	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	ok(base_b != null, "有大本营")
	if base_b == null:
		return
	var near_tower: Vector2i = _free_tile_near(w, base_b.tx + 3, base_b.ty)
	var tower = w.add_building("tower", near_tower.x, near_tower.y, FactionRes.DEFAULT_FACTION)
	ok(tower != null, "在大本营旁边建了一座箭塔")
	if tower == null:
		return

	near(base_b.body_scale(cfg), cfg.num("building.base.body_scale", 0.0), 1e-6, "大本营本体走 config")
	near(tower.body_scale(cfg), cfg.num("building.tower.body_scale", 0.0), 1e-6, "箭塔本体走 config")
	ok(base_b.body_scale(cfg) < 1.0, "★ 大本营本体小于一格（%.2f 格）" % base_b.body_scale(cfg))
	ok(tower.body_scale(cfg) < 1.0, "★ 箭塔本体小于一格（%.2f 格）" % tower.body_scale(cfg))

	for b in [base_b, tower]:
		var r: Rect2 = b.body_rect(cfg)
		v2_near(r.get_center(), b.center(), 1e-6, "%s 的本体在格子内居中" % b.display_name())
		near(r.size.x, b.body_scale(cfg), 1e-6, "%s 本体边长 = body_scale" % b.display_name())
		near(r.size.y, b.body_scale(cfg), 1e-6, "%s 本体是正方形" % b.display_name())
		ok(r.position.x >= float(b.tx) - 1e-6 and r.end.x <= float(b.tx) + 1.0 + 1e-6,
			"%s 的本体没有越出自己的格子" % b.display_name())

	var r2: Rect2 = tower.body_rect(cfg)
	var mid: Vector2 = r2.get_center()
	ok(tower.blocks_segment(cfg, mid + Vector2(-1.0, 0.0), mid + Vector2(1.0, 0.0), 0.0),
		"横穿本体的线段被判为「切进本体」")
	ok(not tower.blocks_segment(cfg, mid + Vector2(-1.0, -0.6), mid + Vector2(1.0, -0.6), 0.0),
		"从本体上方掠过的线段不算命中")

func _test_ally_passes(cfg) -> void:
	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	var g = w.unit_by_id("general-0")
	ok(base_b != null and g != null, "有大本营与将领 1")
	if base_b == null or g == null:
		return

	ok(PathfinderRes.passable(w.map, w.buildings, cfg, base_b.tx, base_b.ty, g.faction),
		"★ 大本营那一格对己方是可通行的")
	ok(not base_b.body_blocks(g.faction), "★ 大本营的本体不阻挡己方")
	ok(not CollisionRes.body_blocked_at(w, cfg, g.faction, base_b.center(), CollisionRes.radius(cfg)),
		"己方可以站在大本营本体正中")

	var group: Array = w.group_of(g)
	w.units = group                      # 隔离：只留这一队，别让别的单位挤它
	g.stop()
	var start_tile := Vector2i(base_b.tx, base_b.ty + 2)
	if not PathfinderRes.passable(w.map, w.buildings, cfg, start_tile.x, start_tile.y, g.faction):
		start_tile = Vector2i(base_b.tx - 2, base_b.ty)
	g.pos = GridRes.center_of(start_tile)
	g.sync_tile(w.map)
	ok(g.order_move(w, cfg, base_b.center()), "命令将领走到大本营本体中心")
	var n := 0
	while g.moving and n < frames_at_baseline(cfg, 3000):
		w.tick(DT)
		n += 1
	ok(g.pos.distance_to(base_b.center()) < 0.35,
		"★ 己方单位站在了大本营本体上（距本体中心 %.3f 格）" % g.pos.distance_to(base_b.center()))
	ok(not CollisionRes.body_blocked_at(w, cfg, g.faction, g.pos, CollisionRes.radius(cfg)),
		"★ 站定之后也没有被本体推出去")

func _test_enemy_blocked_by_body(cfg) -> void:
	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	if base_b == null:
		return
	var e = _spawn_enemy_near(w, base_b, cfg, 6)
	ok(e != null, "刷出了测试敌人")
	if e == null:
		return

	ok(PathfinderRes.passable(w.map, w.buildings, cfg, base_b.tx, base_b.ty, e.faction),
		"★ 大本营那一格对敌方也放行（本体小于一格，缝要能走）")
	ok(base_b.body_blocks(e.faction), "★ 但大本营的本体挡敌方")
	ok(CollisionRes.body_blocked_at(w, cfg, e.faction, base_b.center(), CollisionRes.radius(cfg)),
		"敌方站在本体正中是「被挡」的")

	var r: float = CollisionRes.radius(cfg)
	_clear_buildings_around(w, base_b.tx, base_b.ty, 1)
	w.units = [e]
	e.stop()
	e.pos = base_b.center()
	e.sync_tile(w.map)
	var stats := CollisionRes.resolve_buildings(w, cfg)
	ok(int(stats["pushed"]) >= 1, "★ 本体把塞进来的敌人推了出去（pushed = %d）" % int(stats["pushed"]))
	ok(not CollisionRes.body_blocked_at(w, cfg, e.faction, e.pos, r),
		"★ 推出去之后位置不再压着本体（距本体中心 %.3f 格）" % e.pos.distance_to(base_b.center()))

	var e2 = _spawn_enemy_near(w, base_b, cfg, 5)
	if e2 != null:
		for i in 900:
			w.tick(DT)
		ok(not CollisionRes.body_blocked_at(w, cfg, e2.faction, e2.pos, r),
			"★ 推进 900 帧后敌人仍然在本体之外（位置 %s）" % str(e2.pos))
		var p1: Vector2 = e2.pos
		for i in 120:
			w.tick(DT)
		ok(e2.pos.distance_to(p1) < 0.05,
			"★ 顶到据点之后停稳了（120 帧漂移 %.4f 格）" % e2.pos.distance_to(p1))

func _test_path_avoids_body(cfg) -> void:
	var w = require_world(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	if base_b == null:
		return
	var e = _spawn_enemy_near(w, base_b, cfg, 6)
	ok(e != null, "刷出敌人")
	if e == null:
		return
	var mid := Vector2i(base_b.tx + 3, base_b.ty)
	var tower = w.add_building("tower", mid.x, mid.y, "p2")   # 对家箭塔：只挡路，不参与本用例的战斗
	ok(tower != null, "在敌人与据点之间放了一座对家箭塔")
	if tower == null:
		return

	var path = PathfinderRes.find_path(w.map, w.buildings, cfg,
		Vector2i(e.tx, e.ty), Vector2i(base_b.tx, base_b.ty), e.faction)
	ok(path != null, "★ 路上横着一座箭塔时仍然找得到路")
	if path == null:
		return
	var through_body := 0
	for t in (path as Array):
		if tower.body_rect(cfg).has_point(GridRes.center_of(t)):
			through_body += 1
	eq(through_body, 0, "★ 路径一个点都没落在箭塔本体里（A* 的建筑惩罚让它绕开了）")
	ok((path as Array).size() >= 3, "绕路确实变长了（%d 步）" % (path as Array).size())

func _test_gap_between_towers(cfg) -> void:
	var w = require_world(cfg)
	var e = w.spawn_enemy(0, 0)
	if e == null:
		return
	w.units = [e]
	e.hp = 100000.0
	e.hp_max = 100000.0

	var corner := Vector2i(-1, -1)
	for ty in range(2, w.map.rows - 2):
		for tx in range(2, w.map.cols - 2):
			if w.can_build_at(tx, ty) and w.can_build_at(tx + 1, ty + 1) \
					and w.can_build_at(tx + 1, ty) and w.can_build_at(tx, ty + 1):
				corner = Vector2i(tx, ty)
				break
		if corner.x >= 0:
			break
	ok(corner.x >= 0, "找得到一块 2×2 的空地")
	if corner.x < 0:
		return

	var t1 = w.add_building("tower", corner.x, corner.y, "p2")
	var t2 = w.add_building("tower", corner.x + 1, corner.y + 1, "p2")
	ok(t1 != null and t2 != null, "两座对家箭塔摆好了")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, corner.x, corner.y, e.faction),
		"箭塔那一格对敌人**放行**（本体小于一格，缝要能走）")
	ok(t1.body_blocks(e.faction), "但箭塔的本体挡敌人")

	var a := Vector2i(corner.x + 1, corner.y)
	var b := Vector2i(corner.x, corner.y + 1)
	var d := Vector2i(-1, 1)
	ok(PathfinderRes.diagonal_step_allowed(w.map, w.buildings, cfg, a.x, a.y, d, e.faction),
		"★ 两个本体之间的斜缝够宽 → 允许斜穿（本体 0.6 格时缝宽 %.2f 格）" % (1.0 - t1.body_scale(cfg)))

	e.stop()
	e.pos = GridRes.center_of(Vector2i(corner.x + 1, corner.y + 2))
	e.sync_tile(w.map)
	var target := GridRes.center_of(Vector2i(corner.x, corner.y - 1))
	ok(e.order_move(w, cfg, target), "敌人收到绕过两座箭塔的命令")
	var n := 0
	while e.moving and n < frames_at_baseline(cfg, 3000):
		w.tick(DT)
		n += 1
	ok(e.pos.distance_to(target) < 1.6,
		"★ 敌人真的从两座箭塔之间的缝穿过去了（落点距目标 %.3f 格）" % e.pos.distance_to(target))

func _test_wall_unchanged(cfg) -> void:
	var w = require_world(cfg)
	var t := _free_tile_near(w, 6, 6)
	var wall = w.add_building("wall", t.x, t.y, FactionRes.DEFAULT_FACTION)
	ok(wall != null, "建了一段城墙")
	if wall == null:
		return
	ok(wall.body_scale(cfg) == 1.0, "城墙 body_scale = 1.0（本体就是整格）")
	ok(wall.blocks("enemy"), "城墙对敌方整格阻挡")
	ok(not wall.blocks("p1"), "城墙对己方放行")
	ok(not PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, "enemy"),
		"敌方不能进城墙那一格")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, "p1"),
		"己方可以把城墙那一格当通路")

	var spot := Vector2i(-1, -1)
	for ty in range(2, w.map.rows - 2):
		for tx in range(2, w.map.cols - 2):
			if w.can_build_at(tx, ty) and w.can_build_at(tx + 1, ty + 1):
				spot = Vector2i(tx, ty)
				break
		if spot.x >= 0:
			break
	if spot.x >= 0:
		w.add_building("wall", spot.x, spot.y, "p2")
		w.add_building("wall", spot.x + 1, spot.y + 1, "p2")
		ok(not PathfinderRes.diagonal_step_allowed(w.map, w.buildings, cfg,
			spot.x + 1, spot.y, Vector2i(-1, 1), "enemy"),
			"★ 两段对角城墙之间仍然不能斜穿（本体没有缝）")

func _test_map_outpost(cfg) -> void:
	var w = require_world(cfg)
	var prefab: Array = w.map.prefab_buildings
	ok(prefab.size() >= 5, "地图里有预置建筑（%d 条）" % prefab.size())
	if prefab.is_empty():
		return

	var home: Vector2i = w.home_base_of(FactionRes.DEFAULT_FACTION)
	var placed := 0
	var owner_ok := 0
	var min_dist := 999
	var kinds: Dictionary = {}
	for p in prefab:
		var tx := int(p["x"])
		var ty := int(p["y"])
		min_dist = mini(min_dist, absi(tx - home.x) + absi(ty - home.y))
		var b = w.building_at(tx, ty)
		if b == null:
			continue
		placed += 1
		kinds[String(b.type)] = true
		if b.owner == String(p["owner"]):
			owner_ok += 1

	var expected := 0
	for p in prefab:
		if String(p["type"]) == "base" and not w.player_factions.has(String(p["owner"])):
			continue
		expected += 1
	eq(placed, expected, "★ 每一条预置建筑都真的建出来了（AI 大本营除外，占格 / 山上会被静默跳过）")
	eq(owner_ok, placed, "预置建筑的归属与地图里写的一致")
	ok(not kinds.has("base"), "★ 预置据点里**没有**大本营（AI 的大本营已按本轮口径去掉）")
	ok(kinds.has("tower"), "预置据点里有箭塔")
	ok(kinds.has("wall"), "预置据点里有城墙")
	ok(min_dist >= 6, "★ 预置据点离玩家大本营足够远（最近的一条 %d 格）" % min_dist)

	for p in prefab:
		var b2 = w.building_at(int(p["x"]), int(p["y"]))
		if b2 == null or b2.owner != "enemy":
			continue
		if b2.type == "wall":
			ok(not PathfinderRes.passable(w.map, w.buildings, cfg, b2.tx, b2.ty, "p1"),
				"★ 对家城墙那一格对玩家不可通行")
			break

	var tower_tile := Vector2i(-1, -1)
	for p in prefab:
		if String(p["type"]) == "tower":
			tower_tile = Vector2i(int(p["x"]), int(p["y"]))
			break
	if tower_tile.x < 0:
		return
	var g = w.unit_by_id("general-0")
	w.units = [g]                        # 隔离：只留将领，别让附属兵与敌兵干扰
	g.stop()
	g.pos = Vector2(tower_tile) + Vector2(-2.0, 0.5)   # 站在塔西边 2 格（射程 3 格内）
	g.sync_tile(w.map)
	var hp0: float = g.hp
	for i in 90:
		w.tick(DT)
	ok(g.hp < hp0, "★ 走近对家箭塔会挨打（生命 %.0f → %.0f）" % [hp0, g.hp])

func _bld_around(w, cx: int, cy: int, radius: int) -> Array:
	var out: Array = []
	for b in w.building_list:
		if absi(b.tx - cx) <= radius and absi(b.ty - cy) <= radius:
			out.append("%s@(%d,%d)" % [b.type, b.tx, b.ty])
	return out

func _clear_buildings_around(w, cx: int, cy: int, radius: int) -> void:
	for b in w.building_list.duplicate():
		if b.type == "base":
			continue
		if absi(b.tx - cx) <= radius and absi(b.ty - cy) <= radius:
			w.remove_building(b, true)
	w.refresh_ownership()

func _spawn_enemy_near(w, base_b, cfg, radius: int):
	for rr in range(radius, radius + 8):
		for d in [Vector2i(rr, 0), Vector2i(0, rr), Vector2i(-rr, 0), Vector2i(0, -rr),
				Vector2i(rr, rr), Vector2i(-rr, rr), Vector2i(rr, -rr), Vector2i(-rr, -rr)]:
			var t: Vector2i = Vector2i(base_b.tx + d.x, base_b.ty + d.y)
			if not w.map.terrain_walkable(t.x, t.y):
				continue
			if w.building_at(t.x, t.y) != null:
				continue
			return w.spawn_enemy(t.x, t.y)
	return null

func _free_tile_near(w, x: int, y: int) -> Vector2i:
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := Vector2i(x + dx, y + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(x, y)
