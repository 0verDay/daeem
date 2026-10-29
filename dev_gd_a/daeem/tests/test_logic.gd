## test_logic.gd —— 世界 / 寻路 / 移动 / 战斗 / 城墙 / 区块 / 快照（M2 + M3 + M4 的纯逻辑部分）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const UnitRes = preload("res://logic/unit.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const FactionRes = preload("res://logic/faction.gd")
const CollisionRes = preload("res://logic/collision.gd")
const CombatRes = preload("res://logic/combat.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_logic"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var world = require_world(cfg)
	ok(world != null, "World 能创建（地图载入成功）")
	if world == null:
		return

	_test_world_setup(world, cfg)
	_test_terrain_and_building_passability(world, cfg)
	_test_pathfinding(world, cfg)
	_test_movement(world, cfg)
	_test_segment_clear(world, cfg)
	_test_nearest_reachable(world, cfg)
	_test_combat(world, cfg)
	_test_wall_and_enemy_ai(world, cfg)
	_test_tower(world, cfg)
	_test_zones_and_economy(world, cfg)
	_test_zone_centers(world, cfg)
	_test_zone_population_and_production(world, cfg)
	_test_zone_population_cap(world, cfg)
	_test_build_commands(world, cfg)
	_test_snapshot(world, cfg)

func _test_world_setup(world, cfg) -> void:
	var lv = world.map.spawn_layout_for("p1", "p1")
	var expect_base: Vector2i = lv["base"]
	v2i_eq(world.home_base_of("p1"), expect_base, "大本营坐标来自出生点布局")

	var base_b = world.find_base_of("p1")
	ok(base_b != null, "开局有一方大本营")
	if base_b != null:
		v2i_eq(Vector2i(base_b.tx, base_b.ty), expect_base, "大本营落在出生点")
		ok(base_b.hp == base_b.hp_max, "大本营满血开局")
		eq(base_b.owner, "p1", "大本营属于 player")

	var generals: Array = []
	for u in world.units:
		if u.is_general():
			generals.append(u)
	eq(generals.size(), 1, "★ 自由对战开局只有 #0 一位将领（旧的三位已去掉）")
	if not generals.is_empty():
		var g0 = generals[0]
		eq(String(g0.kind), "general_0", "★ #0 的 kind")
		eq(String(g0.id), "general-0", "★ #0 的 id")
		eq(String(g0.name), "将领 0", "★ #0 的名字")
		eq(String(g0.hotkey), "1", "★ #0 的快捷键是 1")
		eq(String(g0.faction), "p1", "将领属于 player")

	var want_types: Array = cfg.general_types()
	eq(want_types.size(), 10,
		"配置里给了十位将领类型（#0 + 可招募 #1-9）")
	for g in generals:
		var want := String(want_types[int(g.general_index)])
		eq(String(g.unit_type), want,
			"★ %s 是 %s" % [g.id, cfg.unit_name_of(want)])
		# ★★ 2026.10.29：将领 = 所属类型 × 全局将领倍率（血量 / 攻击各乘一次）。
		eq(g.hp_max, cfg.unit_hp_of(want) * cfg.general_hp_mult,
			"★ 将领血量 = 所属类型血量 × 将领倍率（%s）" % cfg.general_hp_mult)
		eq(g.combat_damage(cfg),
			float(cfg.unit_combat_of(want)["damage"]) * cfg.general_damage_mult,
			"将领伤害 = 所属类型伤害 × 将领攻击倍率")
		eq(g.combat_range(cfg), float(cfg.unit_combat_of(want)["range"]),
			"将领射程也走所属类型")
		ok(g.is_general(), "★ is_general() 认得出将领")

	var subs: Array = []
	for u in world.units:
		if u.leader_id != "":
			subs.append(u)
	eq(subs.size(), 0, "★★ 没有关卡的这一局：开局一个附属兵都没有（不再有全局缺省编制）")
	for u in world.units:
		if u.is_general():
			eq(world.retinue_of(String(u.id)).size(), 0,
				"★★ 将领开局光杆：%s（要兵只能靠招募 / 关卡摆放）" % u.id)

	for u in world.units:
		ok(world.map.terrain_walkable(u.tx, u.ty), "开局单位站在可通行格：%s" % u.id)
		ok(not (u.tx == base_b.tx and u.ty == base_b.ty), "开局单位与大本营不同格：%s" % u.id)

	var zs: Array = world.zones.zones
	ok(zs.size() >= 4, "区块划分读进来了（%d 块）" % zs.size())
	eq(zs.size(), world.map.zones_names.size(), "区块数与地图的 zone_list 条数一致")
	var total_tiles := 0
	var empty_zones := 0
	for z in zs:
		total_tiles += int(z["tile_count"])
		if int(z["tile_count"]) <= 0:
			empty_zones += 1
	eq(empty_zones, 0, "★ 每个区块都有地块（地图编辑器不让导出空区块）")
	eq(total_tiles, world.map.zone_tile_total(), "★ Σ区块地块数 = 地图里所有「属于某区块」的格子数")
	eq(String(zs[0]["name"]), "a1", "区块名来自 zone_list（第一个叫 a1）")
	ok(String(zs[zs.size() - 1]["name"]) != "", "最后一个区块也有名字")
	eq(world.owned_tiles, 0, "开局没有己方地块")

	var bz = world.zones.zone_at(base_b.tx, base_b.ty)
	ok(bz != null, "大本营落在某个区块内")
	if bz != null:
		eq(bz["owner"], "p1", "大本营所在区块因建筑归己方（zone_owned_by_building）")

func _test_terrain_and_building_passability(world, cfg) -> void:
	var mountains = 0
	var walkable = 0
	for y in world.map.rows:
		for x in world.map.cols:
			if world.map.terrain_walkable(x, y):
				walkable += 1
			else:
				mountains += 1
	ok(mountains > 0, "地图上有山（%d 格）" % mountains)
	ok(walkable * 3 > (walkable + mountains) * 2,
		"地图上可通行格占 2/3 以上（%d / %d 格）" % [walkable, walkable + mountains])

	var mx = -1
	var my = -1
	for y in world.map.rows:
		for x in world.map.cols:
			if not world.map.terrain_walkable(x, y):
				mx = x
				my = y
				break
		if mx >= 0:
			break
	if mx >= 0:
		ok(not PathfinderRes.passable(world.map, world.buildings, cfg, mx, my, "p1"), "山地不可通行")

	var base_b = world.find_base_of("p1")
	if base_b != null:
		ok(PathfinderRes.passable(world.map, world.buildings, cfg, base_b.tx, base_b.ty, "p1"),
			"★ 大本营那一格对己方放行（本体不阻挡己方）")
		ok(PathfinderRes.passable(world.map, world.buildings, cfg, base_b.tx, base_b.ty, "enemy"),
			"★ 大本营那一格对敌方也放行（本体小于一格，缝要能走）")
		ok(not base_b.blocks("enemy"), "大本营不再「整格」挡敌方")
		ok(base_b.body_blocks("enemy"), "★ 大本营的**本体**挡敌方")
		ok(not base_b.body_blocks("p1"), "★ 大本营的本体不挡己方")

	var wall_tile = _find_free_tile(world, cfg, Vector2i(base_b.tx + 1, base_b.ty + 2))
	ok(wall_tile != null, "找得到一格空地来建测试城墙")
	if wall_tile != null:
		var wall = world.add_building("wall", wall_tile.x, wall_tile.y, "p1")
		ok(wall != null, "城墙建造成功")
		eq(wall.hp, 300.0, "城墙满血 300")
		ok(not wall.blocks("p1"), "城墙对己方放行（blocks = false）")
		ok(wall.blocks("enemy"), "城墙对敌方阻挡（blocks = true）")
		ok(PathfinderRes.passable(world.map, world.buildings, cfg, wall_tile.x, wall_tile.y, "p1"),
			"己方可以把城墙那一格当通路")
		ok(not PathfinderRes.passable(world.map, world.buildings, cfg, wall_tile.x, wall_tile.y, "enemy"),
			"敌方不能进城墙那一格")
		ok(wall.blocks("p2") or wall.blocks("enemy"), "非同一方的阵营被城墙阻挡")
		world.remove_building(wall, false)

	var t2 = _find_free_tile(world, cfg, Vector2i(base_b.tx + 2, base_b.ty + 2))
	if t2 != null:
		var b1 = world.add_building("wall", t2.x, t2.y, "p1")
		var b2 = world.add_building("tower", t2.x, t2.y, "p1")
		ok(b1 != null and b2 == null, "同一地块只能有一个建筑")
		world.remove_building(b1, false)

	if mx >= 0:
		ok(not world.can_build_at(mx, my), "山地不可建造")
	ok(not world.can_build_at(-1, 0), "越界不可建造")

func _test_pathfinding(world, cfg) -> void:
	var from = Vector2i(0, 0)
	var to = Vector2i(3, 0)
	var p = PathfinderRes.find_path(world.map, world.buildings, cfg, from, to, "p1")
	ok(p != null, "开阔地能找到路径")
	if p != null:
		eq(p.size(), 3, "四连通路径长度 = 曼哈顿距离")
		ok(p[0] != from, "路径不含起点")
		v2i_eq(p[p.size() - 1], to, "路径含终点")

	if p != null:
		var prev = from
		var all_adjacent = true
		for step in p:
			if absi(step.x - prev.x) + absi(step.y - prev.y) != 1:
				all_adjacent = false
			prev = step
		ok(all_adjacent, "路径每一步都与上一步四连通相邻")

	var null_path = PathfinderRes.find_path(world.map, world.buildings, cfg, from, Vector2i(-1, -1), "p1")
	ok(null_path == null, "越界目标返回 null")
	var base_b = world.find_base_of("p1")
	if base_b != null:
		var to_base = PathfinderRes.find_path(world.map, world.buildings, cfg, from, Vector2i(base_b.tx, base_b.ty), "p1")
		ok(to_base != null, "★ 目标为大本营时能找到路（格子不再对己方封死）")

	var same = PathfinderRes.find_path(world.map, world.buildings, cfg, from, from, "p1")
	ok(same != null and same.size() == 0, "起点=终点返回空数组（与 null 区分开）")

	var spot = _find_free_pair(world, cfg, Vector2i(6, 2), Vector2i(3, 0))
	ok(spot != null, "起点阻挡用例：找得到「起点 + 右侧 3 格终点」")
	if spot != null:
		var free: Vector2i = spot["from"]
		var goal: Vector2i = spot["to"]
		var tower = world.add_building("tower", free.x, free.y, "p1")
		var out = PathfinderRes.find_path(world.map, world.buildings, cfg, free, goal, "p1")
		ok(out != null, "起点被建筑占住时仍能寻路出来（起点不检查通行性）")
		world.remove_building(tower, false)

	_wall_off_row(world, 9)
	var wall_row_free := 0
	for x in world.map.cols:
		if not world.map.terrain_walkable(x, 9):
			continue
		if world.building_at(x, 9) != null:
			continue          # 已被建筑占住（区划中心 / 预置箭塔 / 城墙…）建不了墙
		wall_row_free += 1
	var wall_row := _build_full_wall_row(world, 9)
	ok(wall_row.size() == wall_row_free,
		"拉出一整条横贯地图的城墙（%d/%d 段）" % [wall_row.size(), wall_row_free])

	var upper = _find_free_tile(world, cfg, Vector2i(0, 4))
	var lower = _find_free_tile(world, cfg, Vector2i(0, 12))
	ok(upper != null and lower != null, "城墙用例：上下两半各取到一个空格")
	if upper != null and lower != null:
		ok(upper.y < 9 and lower.y > 9, "城墙用例：取到的两点确实被墙分在两侧")
		ok(PathfinderRes.find_path(world.map, world.buildings, cfg, upper, lower, "enemy") == null,
			"★ 整条城墙把敌方路线切断（上下两半不可达）")
		ok(PathfinderRes.find_path(world.map, world.buildings, cfg, upper, lower, "p1") != null,
			"同一条城墙对己方完全放行（还能穿过去）")
	var hole = wall_row[wall_row.size() / 2]
	world.remove_building(hole, false)
	ok(PathfinderRes.passable(world.map, world.buildings, cfg, hole.tx, hole.ty, "enemy"),
		"城墙被摘掉后那一格立刻对敌方变成可通行")
	for b in wall_row:
		if b.alive:
			world.remove_building(b, false)

func _test_movement(world, cfg) -> void:
	var u = world.units[0]
	_isolate(world, [u])
	var start = _find_free_tile(world, cfg, Vector2i(2, 12))
	ok(start != null, "找得到开阔地放测试单位")
	if start == null:
		return
	u.pos = GridRes.center_of(start)
	u.sync_tile(world.map)
	u.stop()

	var click = GridRes.center_of(start + Vector2i(4, 0)) + Vector2(0.25, -0.35)
	var ok_move = u.order_move(world, cfg, click)
	ok(ok_move, "move 命令被接受")
	ok(u.moving, "下达后进入移动状态")
	ok(u.path.size() > 0, "路径非空")

	var budget: float = cfg.unit_speed * DT
	var max_step = 0.0
	var prev = u.pos
	for i in frames_at_baseline(cfg, 300):
		world.tick(DT)
		var d: float = u.pos.distance_to(prev)
		max_step = maxf(max_step, d)
		prev = u.pos
		if not u.moving:
			break
	ok(max_step <= budget * 1.5 + 1e-6, "每帧位移不超过速度预算（最大 %.4f 格，预算 %.4f）" % [max_step, budget])
	v2_near(u.pos, click, 1e-4, "终点就是点击的精确位置（不吸附格心）")
	ok(not u.moving, "到达后 moving = false")

	var mountain = _find_mountain_adjacent_walkable(world, cfg)
	if mountain != null:
		var m_pos = Vector2(mountain.x + 0.5, mountain.y + 0.5)
		u.stop()
		u.pos = GridRes.center_of(_find_free_tile(world, cfg, Vector2i(mountain.x + 2, mountain.y)) if
			_find_free_tile(world, cfg, Vector2i(mountain.x + 2, mountain.y)) != null else Vector2i(0, 0))
		u.sync_tile(world.map)
		ok(u.order_move(world, cfg, m_pos), "点到山上下达成功（改走最近可达格）")
		for i in frames_at_baseline(cfg, 600):
			world.tick(DT)
			if not u.moving:
				break
		ok(not PathfinderRes.occupied(world.buildings, u.tx, u.ty), "停在不是建筑的位置")
		ok(u.pos.distance_to(m_pos) <= 1.05, "★ 点山后贴到山边（距山格心 %.3f 格）" % u.pos.distance_to(m_pos))
		ok(u.pos.distance_to(m_pos) > 0.4, "没有真的站进山体内部")

	var a = _find_free_tile(world, cfg, Vector2i(2, 13))
	if a != null:
		u.stop()
		u.pos = GridRes.center_of(a)
		u.sync_tile(world.map)
		u.order_move(world, cfg, GridRes.center_of(a + Vector2i(5, 0)))
		eq(u.path.size(), 1, "开阔地直线可达时路径只有 1 个点（已拉直，不是阶梯）")

	if a != null:
		u.stop()
		u.pos = GridRes.center_of(a)
		u.sync_tile(world.map)
		u.order_move(world, cfg, GridRes.center_of(a + Vector2i(8, 0)))
		for i in 10:
			world.tick(DT)
		var before = u.pos
		u.order_move(world, cfg, GridRes.center_of(a + Vector2i(0, -6)))
		ok(u.pos.distance_to(before) >= 0.0, "换命令后位置连续（没有瞬移）")
		var goal_ok: bool = absf(u.goal.x - (a.x + 0.5)) < 0.01
		ok(goal_ok, "新命令的目标点就是新点击的位置")

	if a != null:
		for d in [0.02, 0.1, 0.3, 0.5, 1.0]:
			u.stop()
			u.pos = GridRes.center_of(a)
			u.sync_tile(world.map)
			var start_pos: Vector2 = u.pos
			var near_click: Vector2 = start_pos + Vector2(d, 0.0)
			ok(u.order_move(world, cfg, near_click), "点击 %.2f 格外：命令被接受" % d)
			ok(u.moving, "★ 点击 %.2f 格外：单位真的进入移动状态（不是原地不动）" % d)
			for i in 600:
				world.tick(DT)
				if not u.moving:
					break
			v2_near(u.pos, near_click, 0.02, "点击 %.2f 格外：走到了点击位置" % d)

		u.stop()
		u.pos = GridRes.center_of(a)
		u.sync_tile(world.map)
		var same_pos2: Vector2 = u.pos
		ok(u.order_move(world, cfg, same_pos2), "点击自己脚下：命令被接受")
		for i in 10:
			world.tick(DT)
		v2_near(u.pos, same_pos2, 1e-6, "点击自己脚下：位置不变（不会自己抖）")

	u.stop()

func _test_segment_clear(world, cfg) -> void:
	var start = _find_free_tile(world, cfg, Vector2i(0, 0))
	ok(start != null, "直线用例：找得到一格干净起点")
	if start != null:
		var right: Vector2i = start + Vector2i(1, 0)
		var right_ok: bool = world.map.terrain_walkable(right.x, right.y) \
			and not PathfinderRes.occupied(world.buildings, right.x, right.y) \
			and world.zone_center_zone_at(right.x, right.y) == null
		ok(right_ok, "直线用例：起点右边那一格也是干净空地")
		if right_ok:
			var y_line: float = float(start.y) + 0.4
			ok(PathfinderRes.segment_clear(world.map, world.buildings, cfg,
				Vector2(float(start.x) + 0.5, y_line),
				Vector2(float(right.x) + 0.5, y_line), "p1"),
				"开阔直线的 segment_clear 为真")
	var free = _find_free_tile(world, cfg, Vector2i(3, 13))
	if free != null:
		var tower = world.add_building("tower", free.x, free.y, "p1")
		ok(tower != null, "起点格上能建起建筑")
		if tower != null:
			var up_ok: bool = free.y - 2 >= 0 \
				and world.map.terrain_walkable(free.x, free.y - 2) \
				and not PathfinderRes.occupied(world.buildings, free.x, free.y - 2) \
				and world.zone_center_zone_at(free.x, free.y - 2) == null
			if up_ok:
				ok(PathfinderRes.segment_clear(world.map, world.buildings, cfg, GridRes.center_of(free),
					Vector2(free.x + 0.5, free.y - 2.5), "p1"),
					"起点格被建筑占住时直线仍然可走（起点不检查）")
			world.remove_building(tower, false)

	var wt = _find_free_tile(world, cfg, Vector2i(3, 14))
	if wt != null:
		var wall = world.add_building("wall", wt.x, wt.y, "p1")
		var left = Vector2(wt.x - 1.5, wt.y + 0.5)
		var right = Vector2(wt.x + 1.5, wt.y + 0.5)
		ok(not PathfinderRes.segment_clear(world.map, world.buildings, cfg, left, right, "enemy"),
			"直线穿过城墙时对敌方为假")
		ok(PathfinderRes.segment_clear(world.map, world.buildings, cfg, left, right, "p1"),
			"同一条直线对己方为真（城墙放行）")
		world.remove_building(wall, false)

	var corner = _find_corner_gap(world)
	if corner != null:
		var mid = Vector2(corner.x + 1.0, corner.y + 1.0)
		var diag_a = Vector2(corner.x + 0.5, corner.y + 0.5)
		var diag_b = Vector2(corner.x + 1.5, corner.y + 1.5)
		ok(not PathfinderRes.segment_clear(world.map, world.buildings, cfg, diag_a, diag_b, "p1"),
			"超覆盖判定拒绝从两座山的对角缝隙穿过")
		ok(mid.x > 0.0 or mid.y > 0.0, "对角判定用例已构造")

func _test_nearest_reachable(world, cfg) -> void:
	var free = _find_free_tile(world, cfg, Vector2i(5, 13))
	if free != null:
		var r = PathfinderRes.nearest_reachable(world.map, world.buildings, cfg, free, free, "p1")
		ok(r != null and r.x == free.x and r.y == free.y, "目标可通行时 nearest_reachable 原样返回")

	var base_b = world.find_base_of("p1")
	if base_b != null:
		var from = Vector2i(base_b.tx + 4, base_b.ty + 3)
		var spot = PathfinderRes.nearest_reachable(world.map, world.buildings, cfg, from, Vector2i(base_b.tx, base_b.ty), "p1", 20)
		ok(spot != null, "大本营旁边的可达格能找出来")
		if spot != null:
			ok(PathfinderRes.passable(world.map, world.buildings, cfg, spot.x, spot.y, "p1"), "找出来的落点可通行")
			var region = PathfinderRes.reachable_tiles(world.map, world.buildings, cfg, from, "p1")
			ok(PathfinderRes.in_region(region, world.map.terrain.idx(spot.x, spot.y)), "★ 落点必须从起点真的走得到（过滤生效）")

func _test_combat(world, cfg) -> void:
	var w2 = require_world(cfg)
	var g = w2.units[0]
	var e = w2.spawn_enemy(g.tx + 6, g.ty)
	ok(e != null, "能刷出测试敌人")
	if e == null:
		return
	eq(e.faction, "enemy", "刷出来的单位属于 enemy 阵营")
	eq(e.hp, cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN), "刷出来的是长枪兵，血量按它的表值")

	_isolate(w2, [g, e])

	g.stop()
	e.stop()
	w2.tick(DT)
	ok(g.target == null, "警戒半径外不索敌")

	g.pos = GridRes.center_of(Vector2i(e.tx - 3, e.ty))
	g.sync_tile(w2.map)
	g.stop()
	w2.tick(DT)
	ok(g.target == e, "警戒半径内的敌人被锁定")
	var hp_before: float = e.hp
	for i in frames_at_baseline(cfg, 240):
		w2.tick(DT)
		if e.hp < hp_before:
			break
	ok(e.hp < hp_before, "追上后真的开火了（敌人掉血）")

	var hp_after_first: float = e.hp
	var cd_hits = 0
	for i in 30:
		w2.tick(DT)
		if e.hp < hp_after_first:
			cd_hits += 1
			hp_after_first = e.hp
	ok(cd_hits <= 1, "0.5 秒内不会连打（攻击冷却生效）")

	# ★ 直接调 order_move 时最后一个参数 = 玩家命令（受击反击不得打断它）。
	#   真实客户端走 command_processor，那条路同样会带 player = true。
	g.order_move(w2, cfg, GridRes.center_of(Vector2i(g.tx, g.ty + 3)), true)
	ok(g.target == null, "右键移动命令会中断交战")

	e.hp = 1.0
	e.take_damage(cfg, w2, 999.0, g)
	ok(not e.alive, "单位被打死")
	ok(not e.awaiting_respawn(), "单机阵亡不进入等待复活（pvp 总开关关着）")
	w2.tick(DT)
	ok(w2.unit_by_id(e.id) == null, "阵亡单位在 tick 后离场")

	var w3 = require_world(cfg)
	cfg.combat_enabled = false
	var g3 = w3.units[0]
	var e3 = w3.spawn_enemy(g3.tx + 2, g3.ty)
	_isolate(w3, [g3, e3])
	w3.tick(DT)
	ok(g3.target == null, "combat.enabled = false 时不索敌")
	cfg.combat_enabled = true

func _test_wall_and_enemy_ai(world, cfg) -> void:
	var w = require_world(cfg)
	var base_b = w.find_base_of("p1")
	ok(base_b != null, "拆墙用例：有大本营")
	if base_b == null:
		return
	var bx: int = base_b.tx
	var by: int = base_b.ty

	_remove_buildings_of_type(w, "tower")
	_remove_buildings_of_type(w, "wall")

	var walls: Array = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var x: int = bx + dx
			var y: int = by + dy
			if not w.map.terrain_walkable(x, y):
				continue
			var b = w.add_building("wall", x, y, "p1")
			if b != null:
				walls.append(b)
	ok(walls.size() >= 4, "大本营周围建起了城墙（%d 段）" % walls.size())

	var e_tile = _find_free_tile(w, cfg, Vector2i(bx + 5, by + 2))
	ok(e_tile != null, "拆墙用例：找得到放敌人的空地")
	if e_tile == null:
		return
	var e = w.spawn_enemy(e_tile.x, e_tile.y)
	ok(e != null, "拆墙用例：敌人已生成")
	if e == null:
		return
	ok(maxi(absi(e.tx - bx), absi(e.ty - by)) >= 4,
		"拆墙用例：敌人确实在围墙外面（%d,%d）" % [e.tx, e.ty])
	eq(e.hp, cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN), "刷出来的是长枪兵，血量按它的表值")

	_isolate(w, [e])

	var direct = PathfinderRes.find_path(w.map, w.buildings, cfg, Vector2i(e.tx, e.ty), Vector2i(bx, by), "enemy")
	ok(direct == null, "城墙拦住后敌人到不了大本营那一格（大本营本身也占格）")

	var target_wall = null
	var best_d := INF
	for wl in walls:
		var d: float = Vector2(e.tx - wl.tx, e.ty - wl.ty).length_squared()
		if d < best_d:
			best_d = d
			target_wall = wl
	ok(target_wall != null, "拆墙用例：取到一段城墙")
	if target_wall != null:
		var hp0: float = target_wall.hp
		CombatRes.set_building_target(e, target_wall)
		var ticks := 0
		while ticks < 60 * 60 and target_wall.hp >= hp0:
			w.tick(DT)
			ticks += 1
		ok(target_wall.hp < hp0, "★ 敌人锁定并开始拆墙（城墙掉血，%d 帧内）" % ticks)
		var lost: float = hp0 - target_wall.hp
		var steps: float = lost / cfg.building_damage
		ok(absf(steps - roundf(steps)) < 1e-6, "掉血量是单次伤害 40 的整数倍（掉了 %.0f）" % lost)
		var guard := 0
		while target_wall.alive and guard < 60 * 120:
			w.tick(DT)
			guard += 1
		ok(not target_wall.alive, "城墙最终被拆毁")
		ok(w.building_at(target_wall.tx, target_wall.ty) == null, "城墙拆毁后从格子索引里摘掉")
		ok(not w.building_list.has(target_wall), "拆毁的城墙也从建筑表里移除")
		ok(PathfinderRes.passable(w.map, w.buildings, cfg, target_wall.tx, target_wall.ty, "enemy"),
			"拆毁的城墙那一格立刻对敌方变成可通行")

func _test_tower(world, cfg) -> void:
	var w = require_world(cfg)
	_remove_buildings_of_type(w, "tower")
	var g = w.units[0]
	var spot = _find_tower_and_target(w, cfg, Vector2i(g.tx + 3, g.ty))
	ok(spot != null, "箭塔用例：找得到「塔位 + 射程内靶位」")
	if spot == null:
		return
	var free: Vector2i = spot["tower"]
	var free_e: Vector2i = spot["enemy"]
	var tower = w.add_building("tower", free.x, free.y, "p1", false, true)
	ok(tower != null, "箭塔建造成功")
	# ★ 大本营现在也会开火（与箭塔同数值）：这条用例只量箭塔那一发，
	#   先把场上所有大本营静音，免得它们也打到靶子上、伤害变成 24。
	for bb in w.building_list:
		if bb != null and bb.type == "base":
			bb.neutralized = true
	if tower == null:
		return
	eq(tower.tower_damage(cfg), 12.0, "箭塔伤害 12")
	eq(tower.tower_range(cfg), 3.0, "箭塔射程 3 格")

	var e = w.spawn_enemy(free_e.x, free_e.y)
	ok(e != null, "箭塔用例：敌人已生成")
	if e == null:
		return
	ok(e.tx == free_e.x and e.ty == free_e.y, "箭塔用例：敌人就站在射程内的靶位上")

	_isolate(w, [e])

	var hp0: float = e.hp
	w.tick(DT)
	ok(w.projectiles.size() >= 1, "★ 箭塔第一帧就开火：生成了一枚投掷物（首次开火无冷却）")
	ok(e.hp == hp0, "★ 命中之前目标不掉血（伤害延迟到命中）")

	var drain := 0
	while not w.projectiles.is_empty() and drain < 600:
		w.tick(DT)
		drain += 1
	ok(absf(e.hp - (hp0 - 12.0)) < 1e-6, "★ 投掷物命中后打掉 12 点")

	var hp1: float = e.hp
	for i in 30:
		w.tick(DT)
	ok(w.projectiles.is_empty() and absf(e.hp - hp1) < 1e-6, "箭塔 0.8 秒冷却内不再开火")

	var wt = require_world(cfg)
	_remove_buildings_of_type(wt, "tower")     # 同上：只留下面这一座，别让别的塔插进来
	var tower2 = wt.add_building("tower", wt.units[0].tx + 3, wt.units[0].ty, "p1", false, true)
	ok(tower2 != null, "不误伤用例：箭塔建好了")
	if tower2 != null:
		var gu2 = wt.units[0]
		_isolate(wt, [gu2])          # 同样只留这一个，别让附属兵跑过来当靶子
		gu2.pos = GridRes.center_of(Vector2i(tower2.tx, tower2.ty - 1))
		gu2.sync_tile(wt.map)
		gu2.stop()
		var g_hp: float = gu2.hp
		for i in 120:
			wt.tick(DT)
		ok(absf(gu2.hp - g_hp) < 1e-6, "箭塔不误伤己方单位（贴脸站 2 秒也不掉血）")

	var e_far = w.spawn_enemy(free.x + 8, free.y)
	if e_far != null:
		_isolate(w, [e, e_far])
		var far_hp: float = e_far.hp
		w.tick(DT)
		ok(absf(e_far.hp - far_hp) < 1e-6, "射程外（8 格）打不到")

func _test_zones_and_economy(world, cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	_isolate(w, [u])
	var spot_d := _find_capture_spot(w, cfg)
	ok(not spot_d.is_empty(), "存在「中心邻域里有空地」的无主区块")
	if spot_d.is_empty():
		return
	var z: Dictionary = spot_d["zone"]
	var spot: Vector2i = spot_d["tile"]
	u.pos = GridRes.center_of(spot)
	u.sync_tile(w.map)
	u.stop()
	var zid: int = int(z["id"])

	var rate: float = 1.0 / float(cfg.capture_time_sec)
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), rate, 1e-4,
		"站 1 秒进度 %.5f（= 1/capture_time_sec）" % rate)
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), rate * 2.0, 1e-4,
		"站 2 秒进度 %.5f" % (rate * 2.0))

	u.pos = GridRes.center_of(Vector2i(2, w.map.rows - 2))
	u.sync_tile(w.map)
	u.drop_engagement()
	var decay: float = float(cfg.decay_per_sec)
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), rate * 2.0 - decay, 1e-4,
		"离开 1 秒后进度回退 %.5f（速率见 config.zone.decay_per_sec）" % decay)

	u.pos = GridRes.center_of(spot)
	u.sync_tile(w.map)
	var ticks := int(ceil(float(cfg.capture_time_sec))) + 2
	for i in ticks:
		w.tick(1.0)
	eq(String(w.zones.zones[zid]["owner"]), "p1",
		"站满 %.0f 秒完成占领" % float(cfg.capture_time_sec))

	var tiles: int = w.zones.owned_tile_count("p1")
	ok(tiles >= int(z["tile_count"]), "己方地块数包含新占的区块")
	eq(w.owned_tiles, tiles, "world.owned_tiles 与区块统计一致")

	var food0: float = float(w.resources["food"])
	w.tick(1.0)
	var gain: float = float(w.resources["food"]) - food0
	near(gain, w.production_food, 1e-3, "每秒粮食产出 = 己方各区划产能之和")
	var zone_now: Dictionary = w.zones.zones[zid]
	(zone_now["production"] as Dictionary)["food"] = 0.0
	w.refresh_zone_production()
	var rate0: float = w.production_food
	(zone_now["production"] as Dictionary)["food"] = 0.4
	w.refresh_zone_production()
	near(w.production_food - rate0, 0.4, 1e-6,
		"★ 给占下来的区划配 0.4 粮食／秒（固定绝对值）→ 每秒产出多出 0.4（不乘地块数）")
	var food1: float = float(w.resources["food"])
	w.tick(1.0)
	near(float(w.resources["food"]) - food1, w.production_food, 1e-3,
		"配上产能之后每帧入账仍然 = 区划产能之和")

	var z2: Dictionary = w.zones.zones[zid]
	ok(z2["progress_by"].has("p1") and z2["progress_by"].has("enemy"), "progress_by 每阵营一项")

func _test_zone_centers(world, cfg) -> void:
	var w = require_world(cfg)
	var centers := _zone_center_buildings(w)
	eq(centers.size(), w.zones.zones.size(), "★ 每个区划都落了一栋中心建筑")

	var zb = centers[0]
	var tile := Vector2i(zb.tx, zb.ty)

	var zone = w.zone_center_zone_at(tile.x, tile.y)
	ok(zone != null, "★ 按格子能问出它是哪个区划的中心")
	if zone != null:
		eq(int(zone["id"]), int(w.zones.center_zone_at_id(tile.x, tile.y)), "两种入口给出同一个 id")
		ok(zone.has("population") and zone.has("production"), "该区划带人口与产能字段")
	ok(w.zone_center_zone_at(tile.x + 50, tile.y + 50) == null, "不是中心的格子问出来是 null")
	ok(w.zones.zone_at(tile.x, tile.y) != null, "中心那一格仍然归属某个区划（两张表各管一件事）")

	for f in ["p1", "p2", "enemy"]:
		ok(PathfinderRes.passable(w.map, w.buildings, cfg, tile.x, tile.y, f),
			"★ 中心格对「%s」**可通行**（格级不再阻挡）" % f)
		ok(not CollisionRes.body_blocked_at(w, cfg, f, GridRes.center_of(tile),
			CollisionRes.radius(cfg)), "★ 中心本体也不挡「%s」（本体级）" % f)
	var through = PathfinderRes.find_path(w.map, w.buildings, cfg,
		Vector2i(tile.x - 2, tile.y), Vector2i(tile.x + 2, tile.y), "p1")
	ok(through != null, "★ 穿过中心的寻路能算出来（中心不再是障碍）")

	eq(zb.hp_max, 0.0, "★ 中心没有血量（hp_max = 0）")
	ok(zb.is_invulnerable(), "★ 中心是无敌的（invulnerable）")
	ok(not zb.take_damage(cfg, 99999.0, null), "打它返回 false（没有摧毁）")
	ok(zb.alive and zb.hp == 0.0, "★ 打完还活着、血量还是 0")
	ok(zb.flash <= 0.0, "受击闪光也不给（纯表现上就不像能打的东西）")

	ok(not CommandRes.apply(w, cfg, {"kind": "demolish", "tx": tile.x, "ty": tile.y, "faction": "p1"}),
		"★ 拆除命令对中心无效")
	ok(w.building_at(tile.x, tile.y) != null, "拆不掉：它还在")

	var g = w.unit_by_id("general-0")
	if g != null:
		g.stop()
		g.pos = GridRes.center_of(Vector2i(tile.x, tile.y + 2))
		g.sync_tile(w.map)
		g.drop_engagement()
		_isolate(w, [g])
		w.tick(DT)
		ok(g.target_building != w.building_at(tile.x, tile.y),
			"★ 玩家单位不会把区划中心当建筑目标")
		ok(not g.moving, "★ 也不会为了「拆它」而走动（站在旁边就是站着）")

		ok(not g.order_attack_building(w, cfg, zb),
			"★ unit.order_attack_building() 拒绝把中心当攻击目标")
		ok(not CommandRes.apply(w, cfg,
			{"kind": "attack", "ids": [g.id], "tx": tile.x, "ty": tile.y, "faction": "p1"}),
			"★ attack 命令对中心无效（连命令层都不受理）")
		ok(g.target_building == null and g.ordered_building == null,
			"★ 拒绝之后没有留下黏住的目标（不然它就一直站着不还手）")

	ok(CombatRes.nearest_enemy_building(w, cfg, g, 99.0) != w.building_at(tile.x, tile.y),
		"★ 建筑索敌会跳过无主/无敌的中心")

func _zone_center_buildings(w) -> Array:
	var out: Array = []
	for b in w.building_list:
		if b.type == "zone_center":
			out.append(b)
	return out

func _test_zone_population_and_production(world, cfg) -> void:
	var w = require_world(cfg)
	var z0: Dictionary = w.zones.zones[0]
	var z1: Dictionary = w.zones.zones[1]

	eq(float(z0["population"]), 0.0, "★ 区划人口开局是 0")
	ok(float(z0["production"]["population"]) > 0.0,
		"★ 发布地图的区划配了人口产能（%s）" % z0["production"]["population"])
	near(w.zones.population_cap_of(z0), 2.0, 1e-9, "★ 发布地图的区块配了人口上限（2）")
	var pop_rate: float = float(z0["production"]["population"])
	z0["population_cap"] = 1.0e9
	var before: float = float(z0["population"])
	w.tick(1.0)
	var gained: float = float(z0["population"]) - before
	near(gained, pop_rate, 1e-3,
		"★ 人口每秒增长 = 人口产能（固定绝对值，不乘地块数）")
	ok(float(z1["population"]) > 0.0, "★ 每个区划各涨各的（第二个区划也在涨）")
	var p0: float = float(z0["population"])
	w.tick(2.0)
	ok(float(z0["population"]) > p0, "★ 人口只增不减（时间只会让它涨）")

	var food_before: float = float(w.resources["food"])
	ok(float(w.resources["food"]) >= food_before, "资源照常按产能涨（人口不掺进来）")
	ok(not w.resources.has("population"), "★ resources 里没有 population 这一项（人口不进 HUD）")

	var zc: Dictionary = w.zones.zones[0]
	zc["owner"] = ""
	var base_food: float = float(w.zones.production_of("p1")["food"])
	var base_gold: float = float(w.zones.production_of("p1")["gold"])
	zc["owner"] = "p1"
	zc["production"]["food"] = 2.0
	zc["production"]["gold"] = 3.0
	var rates: Dictionary = w.zones.production_of("p1")
	near(float(rates["food"]) - base_food, 2.0, 1e-6,
		"★ 产量按「固定基础产能」聚合（粮食：多了这个区划那一份 2.0）")
	near(float(rates["gold"]) - base_gold, 3.0, 1e-6,
		"★ 产量按「固定基础产能」聚合（黄金：多了这个区划那一份 3.0）")

	near(float(w.zones.production_of("")["food"]), 0.0, 1e-9,
		"★ 无主（owner == ''）不产生任何产量")

func _test_zone_population_cap(world, cfg) -> void:
	var w = require_world(cfg)
	var z: Dictionary = w.zones.zones[0]
	z["production"] = {"food": 0.0, "gold": 0.0, "population": 10.0}
	z["population"] = 0.0

	z.erase("population_cap")
	near(w.zones.population_cap_of(z), 1.0, 1e-9, "★ 地图没填上限 → 默认 1")
	w.tick(1.0)
	near(w.zones.population_of(z), 1.0, 1e-6, "★ 人口涨到上限（1）就停住")
	w.tick(5.0)
	near(w.zones.population_of(z), 1.0, 1e-6, "★ 继续跑时间也不会超过上限")

	z["population_cap"] = 0.0
	z["population"] = 0.0
	w.tick(3.0)
	near(w.zones.population_of(z), 0.0, 1e-9, "★ 上限 0 的区块永远没有人口")

	z["population_cap"] = 4.0
	w.tick(1.0)
	near(w.zones.population_of(z), 4.0, 1e-6, "★ 上限抬高之后接着涨，并停在新上限")

	z["population"] = 7.5
	w.tick(1.0)
	near(w.zones.population_of(z), 7.5, 1e-9, "★ 超额的现值不会被上限削回去（只是不再涨）")

	z["population"] = 3.9
	eq(w.zones.population_floor(z), 3, "★ 显示用的人口向下取整（3.9 → 3）")
	z["population"] = 0.0
	eq(w.zones.population_floor(z), 0, "0 → 0")
	z["population"] = 12.0
	eq(w.zones.population_floor(z), 12, "整数照原样")

	var m = require_map(cfg)
	if m != null:
		ok(not m.zones_population_caps.is_empty(),
			"★ 发布地图里配了区块上限（本版每块地都填了）")

func _test_build_commands(world, cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var base_b = w.find_base_of("p1")
	ok(base_b != null, "（前提）有己方大本营（它的区块开局就归 p1）")
	# ★★ 本轮新规则：**只能在自己区划里建造** —— 所以这里限定「p1 自己区划里的空地」
	var hint: Vector2i = Vector2i(3, 3) if base_b == null else Vector2i(base_b.tx + 1, base_b.ty + 1)
	var free = _find_free_tile(w, cfg, hint, "p1")
	ok(free != null, "建造用例：在自己区划里找得到空地")
	if free == null:
		return

	var cmd = {"kind": "build", "build_type": "wall", "tx": free.x, "ty": free.y, "faction": "p1"}
	ok(CommandRes.apply(w, cfg, cmd), "build 命令被接受")
	var b = w.building_at(free.x, free.y)
	ok(b != null, "建筑真的落成了")
	if b != null:
		eq(b.type, "wall", "落成的是城墙")
		eq(b.owner, "p1", "归属是命令里的 faction")

	ok(not CommandRes.apply(w, cfg, cmd), "同一格重复建造被拒绝")

	# ★★ 本轮新增规则：**不能在自己的区划之外建造** —— 否则玩家能在中立地上立一栋楼，
	#    让那一整块地「立即归己」（既成事实扩张，就是本次要修的 bug）。
	var outside := Vector2i(-1, -1)
	for ty in w.map.rows:
		for tx in w.map.cols:
			if w.can_build_at(tx, ty) and not w.zone_allows_build(tx, ty, "p1"):
				outside = Vector2i(tx, ty)
				break
		if outside.x >= 0:
			break
	ok(outside.x >= 0, "（前提）地图上有一格可建造、但不属于 p1 的空地")
	if outside.x >= 0:
		ok(not CommandRes.apply(w, cfg, {"kind": "build", "build_type": "wall",
			"tx": outside.x, "ty": outside.y, "faction": "p1"}),
			"★★ 不能在自己的区划之外建造（既成事实扩张被挡住）")
		ok(w.building_at(outside.x, outside.y) == null, "那一格上什么都没建出来")

	var del = {"kind": "demolish", "tx": free.x, "ty": free.y, "faction": "p1"}
	ok(CommandRes.apply(w, cfg, del), "拆除命令被接受")
	ok(w.building_at(free.x, free.y) == null, "拆除后格子空了")

	ok(not CommandRes.apply(w, cfg, del), "拆不存在的建筑被拒绝")
	if base_b != null:
		ok(not CommandRes.apply(w, cfg, {"kind": "demolish", "tx": base_b.tx, "ty": base_b.ty, "faction": "p1"}),
			"大本营不可拆除")

	var other = w.units[0]
	other.faction = "p2"
	var moved = CommandRes.apply(w, cfg, {"kind": "move", "ids": [other.id], "x": 100.0, "y": 100.0, "faction": "p1"})
	ok(not moved, "★ 拿别人阵营的单位 id 下达 move 命令无效（防冒充）")
	other.faction = "p1"

	ok(not CommandRes.apply(w, cfg, {"kind": "teleport"}), "未知命令返回 false")

func _test_snapshot(world, cfg) -> void:
	var per_general: int = 3
	var w = require_world_with_escorts(cfg, per_general)
	if w == null:
		return
	w.spawn_enemy(10, 12)
	w.tick(DT)
	var snap = SnapshotRes.to_snapshot(w)

	var per_total: int = per_general * 3
	var expect_units: int = 3 + per_total + 1
	eq((snap["units"] as Array).size(), expect_units,
		"快照里有 %d 个单位（3 将领 + %d 附属兵 + 1 敌人；地图预置单位已废弃）" % [
			expect_units, per_total])
	ok((snap["buildings"] as Array).size() >= 1, "快照里有建筑")
	var zone_total: int = w.zones.zones.size()
	ok(zone_total > 0, "地图带区块（%d 个）" % zone_total)
	eq((snap["zones"] as Array).size(), zone_total, "快照把全部 %d 个区块都发出去" % zone_total)
	ok(snap.has("res") and (snap["res"] as Array).size() == 2, "快照带两种资源")
	ok(not (snap["units"] as Array)[0].has("path"), "★ 快照不发路径（只发结果）")
	ok((snap["units"] as Array)[0].has("x") and (snap["units"] as Array)[0].has("fa"), "快照带位置与朝向")

	var by_id: Dictionary = {}
	for su in (snap["units"] as Array):
		by_id[String(su.get("i", ""))] = su
	var sub_in_snap := 0
	var ld_ok := true
	var ut_ok := true
	var snap_general_types: Array = []
	for su in (snap["units"] as Array):
		if String(su.get("ut", "")) == "":
			ut_ok = false
		var ld_v: Variant = su.get("ld", null)
		var ld := String(ld_v) if ld_v != null else ""
		if ld != "":
			sub_in_snap += 1
			if not by_id.has(ld):
				ld_ok = false          # 队长不在快照里 → 客机展开不了整队
		elif String(su.get("k", "")) == UnitRes.KIND_GENERAL:
			snap_general_types.append(String(su.get("ut", "")))
	eq(sub_in_snap, per_total, "快照里有 %d 个附属兵" % per_total)
	ok(ld_ok, "★ 快照里的附属兵都指向一个**在场的**队长 id（客机才做得出整队选中）")
	ok(ut_ok, "★ 快照里每个单位都带单位类型（ut）")
	# ★ 世界开局只造 3 位将领（create_generals 写死 3），所以快照里只有前 3 个类型；
	#   名册第 4..9 位只从招募池里出（见 test_zone_recruit）。
	eq(snap_general_types, cfg.general_types().slice(0, snap_general_types.size()),
		"★ 三个开局将领的 ut 就是名册里那前三个类型")

	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	eq(w2.units.size(), expect_units, "快照应用后单位数一致")
	eq(w2.owned_tiles, w.owned_tiles, "己方地块数一致")
	near(float(w2.time), float(w.time), 0.01, "时间轴一致")

	var src = w.units[0]
	var dst = w2.unit_by_id(src.id)
	ok(dst != null, "按 id 对齐到同一个单位")
	if dst != null:
		v2_near(dst.pos, src.pos, 0.01, "单位位置按 id 对齐")
		eq(int(dst.hp), int(src.hp), "单位血量对齐")
		v2i_eq(Vector2i(dst.tx, dst.ty), Vector2i(src.tx, src.ty), "★ tx/ty 也跟着写了（否则点选/射程判定会错）")

	var per_g1: int = w.retinue_of("general-1").size()
	eq(per_g1, per_general, "（前提）关卡给 general-1 摆了 %d 个附属兵" % per_general)
	if per_g1 > 0:
		var leader = w2.unit_by_id("general-1")
		ok(leader != null, "客机侧有 general-1")
		if leader != null:
			var got: Array = w2.group_of(leader)
			eq(got.size(), 1 + per_g1, "★ 客机侧队伍展开得到「队长 + %d 附属兵」" % per_g1)
		for i in mini(3, cfg.general_types().size()):
			var remote = w2.unit_by_id("general-%d" % (i + 1))
			if remote != null:
				eq(String(remote.unit_type), String(cfg.general_types()[i]),
					"★ 客机侧将领 %d 的类型也重建对了" % (i + 1))

	var small = {"units": [], "buildings": [], "zones": []}
	SnapshotRes.apply_snapshot(w2, cfg, small)
	eq(w2.units.size(), 0, "快照里没有的单位被删除")

	var w3 = require_world(cfg)
	w3.resources["food"] = 42.0
	w3.time = 7.0
	SnapshotRes.apply_snapshot(w3, cfg, {"units": [], "buildings": []})
	near(float(w3.resources["food"]), 42.0, 1e-6, "缺 res 字段时保持本地资源不变")
	near(w3.time, 7.0, 1e-6, "缺 time 字段时保持本地时间不变")
	ok(SnapshotRes.to_snapshot(w3)["units"] is Array, "空世界也能建快照（不崩）")

func _isolate(world, keep: Array) -> void:
	var kept: Dictionary = {}
	for u in keep:
		if u != null:
			kept[u.id] = true
	var survivors: Array = []
	for u in world.units:
		if kept.has(u.id):
			survivors.append(u)
	world.units = survivors

func _remove_buildings_of_type(world, type: String) -> void:
	for b in world.building_list.duplicate():
		if b.type == type:
			world.remove_building(b, true)
	world.refresh_ownership()

func _units_of_kind(world, kind: String) -> Array:
	var out: Array = []
	for u in world.units:
		if u.kind == kind:
			out.append(u)
	return out

func _find_free_pair(world, cfg, hint: Vector2i, offset: Vector2i) -> Variant:
	for r in 12:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var from: Vector2i = hint + Vector2i(dx, dy)
				if _find_free_tile(world, cfg, from) != from:
					continue          # 只认正好落在这一格的
				var to: Vector2i = from + offset
				if _find_free_tile(world, cfg, to) != to:
					continue
				return {"from": from, "to": to}
	return null

func _find_tower_and_target(world, cfg, hint: Vector2i) -> Variant:
	var dirs := [Vector2i(2, 0), Vector2i(-2, 0), Vector2i(0, 2), Vector2i(0, -2),
		Vector2i(2, 2), Vector2i(-2, 2), Vector2i(2, -2), Vector2i(-2, -2)]
	for r in 12:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var tower = _find_free_tile(world, cfg, hint + Vector2i(dx, dy))
				if tower == null or tower != hint + Vector2i(dx, dy):
					continue          # 只认「正好落在这一格」的，别让内层再往外扩
				for d in dirs:
					var t: Vector2i = tower + d
					if PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, FactionRes.NPC_FACTION):
						return {"tower": tower, "enemy": t}
	return null

func _find_capture_spot(w, cfg) -> Dictionary:
	var r: int = maxi(0, int(cfg.zone_capture_radius_tiles))
	for z in w.zones.zones:
		if String(z["owner"]) != "":
			continue
		var c: Variant = z["center"]
		if c == null:
			continue
		var center: Vector2i = c
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var x: int = center.x + dx
				var y: int = center.y + dy
				if not w.map.terrain.has(x, y):
					continue
				if not w.map.terrain_walkable(x, y):
					continue
				if PathfinderRes.occupied(w.buildings, x, y):
					continue
				if w.zone_center_zone_at(x, y) != null:
					continue          # 中心格本身（中立障碍建筑）
				return {"zone": z, "tile": Vector2i(x, y)}
	return {}

func _find_free_tile(world, cfg, hint: Vector2i, faction: String = "") -> Variant:
	for r in 12:
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var x: int = hint.x + dx
				var y: int = hint.y + dy
				if not world.map.terrain.has(x, y):
					continue
				if not world.map.terrain_walkable(x, y):
					continue
				if PathfinderRes.occupied(world.buildings, x, y):
					continue
				if world.zone_center_zone_at(x, y) != null:
					continue          # 区划中心占着这一格（它是中立障碍建筑，站不上去、也走不过）
				if _near_zone_center(world, x, y, 1):
					continue          # 别紧挨着区划中心（会把直线 / 离体判定弄复杂）
				# ★ 给了 faction 就只找**它自己区划里**的空地（建造新规则：只能在自己区划里建）
				if faction != "" and not world.zone_allows_build(x, y, faction):
					continue
				return Vector2i(x, y)
	return null

func _near_zone_center(world, x: int, y: int, radius: int) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			if world.zone_center_zone_at(x + dx, y + dy) != null:
				return true
	return false

func _find_mountain_adjacent_walkable(world, _cfg) -> Variant:
	for y in world.map.rows:
		for x in world.map.cols:
			if not world.map.terrain_walkable(x, y):
				return Vector2i(x, y)
	return null

func _wall_off_row(world, row: int) -> void:
	for x in world.map.cols:
		var b = world.building_at(x, row)
		if b != null:
			world.remove_building(b, true)

func _build_full_wall_row(world, row: int) -> Array:
	var out: Array = []
	for x in world.map.cols:
		if not world.map.terrain_walkable(x, row):
			continue
		if world.building_at(x, row) != null:
			continue
		var b = world.add_building("wall", x, row, "p1")
		if b != null:
			out.append(b)
	return out

func _find_corner_gap(world) -> Variant:
	for y in range(0, world.map.rows - 1):
		for x in range(0, world.map.cols - 1):
			var a: bool = not world.map.terrain_walkable(x, y)
			var b: bool = not world.map.terrain_walkable(x + 1, y + 1)
			var c = world.map.terrain_walkable(x + 1, y)
			var d = world.map.terrain_walkable(x, y + 1)
			if a and b and c and d:
				return Vector2i(x, y)
	return null
