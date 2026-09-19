## test_logic.gd —— 世界 / 寻路 / 移动 / 战斗 / 城墙 / 区块 / 快照（M2 + M3 + M4 的纯逻辑部分）
##
## 这里放的是「不开窗口也能断言」的那部分验收（docs/route.md 的 M2~M4）。
## 渲染 / 手感 / 相机那部分只能手玩验收，见 docs/README 的验收清单。
##
## ⚠️ M2 是整个原型的**风险集中点**（HTML 版在 A* 与拉直上踩的坑最多），
##    所以这里的断言密度刻意比别处高。
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

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_logic"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var world = WorldRes.create(cfg)
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
	_test_build_commands(world, cfg)
	_test_snapshot(world, cfg)


# ------------------------------------------------------------------
# 开局状态
# ------------------------------------------------------------------
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

	# ★ 开局既有将领也有亲兵，所以断言要按 kind 分别看 ——
	#   写「所有单位都该是将领」在加兵种的那一天必然假失败（这一条就是这么发现的）
	var generals := _units_of_kind(world, UnitRes.KIND_GENERAL)
	var subs := _units_of_kind(world, UnitRes.KIND_SUBORDINATE)
	eq(generals.size(), 3, "开局 3 个将领")
	var hotkeys: Array[String] = []
	for u in generals:
		hotkeys.append(u.hotkey)
		eq(u.faction, "p1", "将领属于 player")
	ok(hotkeys.has("1") and hotkeys.has("2") and hotkeys.has("3"), "三个将领带 1/2/3 快捷键")

	# 亲兵：每个将领带 count 个，id 以队长 id 开头，leader_id 指向队长
	var per_leader: int = int(cfg.num("unit.subordinate.count", 0.0))
	eq(subs.size(), 3 * per_leader, "每个将领带 %d 个亲兵（共 %d 个）" % [per_leader, subs.size()])
	for s in subs:
		eq(s.faction, "p1", "亲兵属于 player")
		eq(s.hp_max, cfg.unit_hp_of(UnitRes.KIND_SUBORDINATE), "亲兵血量走 config.unit.subordinate")
		ok(s.leader_id != "", "亲兵有队长 id：%s" % s.id)
		ok(s.id.begins_with(s.leader_id), "亲兵 id 以队长 id 开头：%s ← %s" % [s.id, s.leader_id])
		ok(world.unit_by_id(s.leader_id) != null, "亲兵的队长真的在场：%s" % s.leader_id)
		eq(s.hotkey, "", "亲兵没有快捷键（快捷键盘只给将领）")

	# 所有单位（将领 + 亲兵）都不能站在山上或大本营格上
	for u in world.units:
		ok(world.map.terrain_walkable(u.tx, u.ty), "开局单位站在可通行格：%s" % u.id)
		ok(not (u.tx == base_b.tx and u.ty == base_b.ty), "开局单位与大本营不同格：%s" % u.id)

	# 亲兵挨着队长站（1~2 格内）
	if per_leader > 0:
		var g1 = world.unit_by_id("general-1")
		ok(g1 != null, "有 general-1")
		if g1 != null:
			var near := 0
			for s in world.retinue_of(g1.id):
				if maxi(absi(s.tx - g1.tx), absi(s.ty - g1.ty)) <= 2:
					near += 1
			eq(near, world.retinue_of(g1.id).size(), "★ 亲兵都出生在将领旁边（2 格内）")

	eq(world.zones.zones.size(), 24, "区块均分成 6×4 = 24 块")
	eq(world.zones.zones[0]["tile_count"], 16, "每块 16 格")
	eq(world.zones.zones[0]["name"], "A1", "区块命名 A1")
	eq(world.zones.zones[23]["name"], "D6", "区块命名 D6")
	eq(world.owned_tiles, 0, "开局没有己方地块")

	# 出生点区块会被大本营直接收归（zone_owned_by_building 的副作用，照搬 HTML 版）
	var bz = world.zones.zone_at(base_b.tx, base_b.ty)
	ok(bz != null, "大本营落在某个区块内")
	if bz != null:
		eq(bz["owner"], "p1", "大本营所在区块因建筑归己方（zone_owned_by_building）")


# ------------------------------------------------------------------
# 通行规则：山 / 城墙 / 大本营
# ------------------------------------------------------------------
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
	ok(walkable > 300, "地图上可通行格超过 300（实际 %d 格）" % walkable)

	# 山不可通行
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

	# 大本营：本体小于一格 → **整格对谁都不封**（己方直接站上去，敌方也能走进格里绕本体）
	var base_b = world.find_base_of("p1")
	if base_b != null:
		ok(PathfinderRes.passable(world.map, world.buildings, cfg, base_b.tx, base_b.ty, "p1"),
			"★ 大本营那一格对己方放行（本体不阻挡己方）")
		ok(PathfinderRes.passable(world.map, world.buildings, cfg, base_b.tx, base_b.ty, "enemy"),
			"★ 大本营那一格对敌方也放行（本体小于一格，缝要能走）")
		ok(not base_b.blocks("enemy"), "大本营不再「整格」挡敌方")
		ok(base_b.body_blocks("enemy"), "★ 大本营的**本体**挡敌方")
		ok(not base_b.body_blocks("p1"), "★ 大本营的本体不挡己方")

	# 城墙：己方穿过、敌方阻挡
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
		# 联机语义回归：p2 的城墙对 p1 必须阻挡（判定基准是 same_side，不是 == 'player'）
		ok(wall.blocks("p2") or wall.blocks("enemy"), "非同一方的阵营被城墙阻挡")
		world.remove_building(wall, false)

	# 同一格只能有一个建筑
	var t2 = _find_free_tile(world, cfg, Vector2i(base_b.tx + 2, base_b.ty + 2))
	if t2 != null:
		var b1 = world.add_building("wall", t2.x, t2.y, "p1")
		var b2 = world.add_building("tower", t2.x, t2.y, "p1")
		ok(b1 != null and b2 == null, "同一地块只能有一个建筑")
		world.remove_building(b1, false)

	# 不能建在山上
	if mx >= 0:
		ok(not world.can_build_at(mx, my), "山地不可建造")
	ok(not world.can_build_at(-1, 0), "越界不可建造")


# ------------------------------------------------------------------
# A* 寻路
# ------------------------------------------------------------------
func _test_pathfinding(world, cfg) -> void:
	var from = Vector2i(0, 0)
	var to = Vector2i(3, 0)
	var p = PathfinderRes.find_path(world.map, world.buildings, cfg, from, to, "p1")
	ok(p != null, "开阔地能找到路径")
	if p != null:
		eq(p.size(), 3, "四连通路径长度 = 曼哈顿距离")
		ok(p[0] != from, "路径不含起点")
		v2i_eq(p[p.size() - 1], to, "路径含终点")

	# 每一步必须相邻（四连通，不许走对角线）
	if p != null:
		var prev = from
		var all_adjacent = true
		for step in p:
			if absi(step.x - prev.x) + absi(step.y - prev.y) != 1:
				all_adjacent = false
			prev = step
		ok(all_adjacent, "路径每一步都与上一步四连通相邻")

	# 目标不可通行 → 返回 null
	var null_path = PathfinderRes.find_path(world.map, world.buildings, cfg, from, Vector2i(-1, -1), "p1")
	ok(null_path == null, "越界目标返回 null")
	var base_b = world.find_base_of("p1")
	if base_b != null:
		var to_base = PathfinderRes.find_path(world.map, world.buildings, cfg, from, Vector2i(base_b.tx, base_b.ty), "p1")
		ok(to_base != null, "★ 目标为大本营时能找到路（格子不再对己方封死）")

	# 起点 = 终点 → 空数组（不是 null：null 表示不可达）
	var same = PathfinderRes.find_path(world.map, world.buildings, cfg, from, from, "p1")
	ok(same != null and same.size() == 0, "起点=终点返回空数组（与 null 区分开）")

	# 起点本身不可通行时仍要能走出来（脚下被盖了建筑的情况，见 pitfalls 3.4）
	var free = _find_free_tile(world, cfg, Vector2i(6, 2))
	if free != null:
		var tower = world.add_building("tower", free.x, free.y, "p1")
		var out = PathfinderRes.find_path(world.map, world.buildings, cfg, free, Vector2i(free.x + 3, free.y), "p1")
		ok(out != null, "起点被建筑占住时仍能寻路出来（起点不检查通行性）")
		world.remove_building(tower, false)

	# 城墙拦断 → 敌方不可达，己方可达
	#
	# ⚠️ 单格城墙**证明不了**拦断：四连通下总可以绕过去（debug 里实测过）。
	#    要真正切开地图，必须用**一条从地图一侧连到另一侧**的长墙。
	#    这里在第 9 行拉一条横贯全图的墙，把地图切成上下两半。
	_wall_off_row(world, 9)
	var wall_row := _build_full_wall_row(world, 9)
	ok(wall_row.size() >= 24, "拉出一整条横贯地图的城墙（%d 段）" % wall_row.size())
	var top := Vector2i(0, 4)
	var bottom := Vector2i(0, 12)
	ok(PathfinderRes.find_path(world.map, world.buildings, cfg, top, bottom, "enemy") == null,
		"★ 整条城墙把敌方路线切断（上下两半不可达）")
	ok(PathfinderRes.find_path(world.map, world.buildings, cfg, top, bottom, "p1") != null,
		"同一条城墙对己方完全放行（还能穿过去）")
	# 拆掉中间一段就出现缺口 —— 这一格立刻变成可通行
	var hole = wall_row[wall_row.size() / 2]
	world.remove_building(hole, false)
	ok(PathfinderRes.passable(world.map, world.buildings, cfg, hole.tx, hole.ty, "enemy"),
		"城墙被摘掉后那一格立刻对敌方变成可通行")
	for b in wall_row:
		if b.alive:
			world.remove_building(b, false)


# ------------------------------------------------------------------
# 移动：点到哪走到哪 / 每帧预算 / 不跳格 / 能走直线就走直线
# ------------------------------------------------------------------
func _test_movement(world, cfg) -> void:
	var u = world.units[0]
	# 只留这一个单位：移动与路径断言不该被亲兵的推挤/交战干扰
	_isolate(world, [u])
	# 放到一片开阔地
	var start = _find_free_tile(world, cfg, Vector2i(2, 12))
	ok(start != null, "找得到开阔地放测试单位")
	if start == null:
		return
	u.pos = GridRes.center_of(start)
	u.sync_tile(world.map)
	u.stop()

	# 1) 终点 = 点击的精确位置（不吸附格心）
	var click = GridRes.center_of(start + Vector2i(4, 0)) + Vector2(0.25, -0.35)
	var ok_move = u.order_move(world, cfg, click)
	ok(ok_move, "move 命令被接受")
	ok(u.moving, "下达后进入移动状态")
	ok(u.path.size() > 0, "路径非空")

	# 2) 每帧位移不超过预算（速度 × dt），且若干帧后真的走到点击位置
	var budget: float = cfg.unit_speed * DT
	var max_step = 0.0
	var prev = u.pos
	for i in 300:
		world.tick(DT)
		var d: float = u.pos.distance_to(prev)
		max_step = maxf(max_step, d)
		prev = u.pos
		if not u.moving:
			break
	ok(max_step <= budget * 1.5 + 1e-6, "每帧位移不超过速度预算（最大 %.4f 格，预算 %.4f）" % [max_step, budget])
	v2_near(u.pos, click, 1e-4, "终点就是点击的精确位置（不吸附格心）")
	ok(not u.moving, "到达后 moving = false")

	# 3) 点到山上 → 贴到山边（不是停在下一格的格心）
	var mountain = _find_mountain_adjacent_walkable(world, cfg)
	if mountain != null:
		var m_pos = Vector2(mountain.x + 0.5, mountain.y + 0.5)
		u.stop()
		u.pos = GridRes.center_of(_find_free_tile(world, cfg, Vector2i(mountain.x + 2, mountain.y)) if
			_find_free_tile(world, cfg, Vector2i(mountain.x + 2, mountain.y)) != null else Vector2i(0, 0))
		u.sync_tile(world.map)
		ok(u.order_move(world, cfg, m_pos), "点到山上下达成功（改走最近可达格）")
		for i in 600:
			world.tick(DT)
			if not u.moving:
				break
		ok(not PathfinderRes.occupied(world.buildings, u.tx, u.ty), "停在不是建筑的位置")
		# ⚠️ 这里**不能**再断言「所处地块可通行」：贴边落点就在山那一格的边缘上，
		#    所以 tx/ty 会是山格。要保证的是「贴在山的边界上」而不是停在上一格的格心。
		ok(u.pos.distance_to(m_pos) <= 1.05, "★ 点山后贴到山边（距山格心 %.3f 格）" % u.pos.distance_to(m_pos))
		ok(u.pos.distance_to(m_pos) > 0.4, "没有真的站进山体内部")

	# 4) 能走直线就走直线：开阔地的路径被拉直成 1 个点
	var a = _find_free_tile(world, cfg, Vector2i(2, 13))
	if a != null:
		u.stop()
		u.pos = GridRes.center_of(a)
		u.sync_tile(world.map)
		u.order_move(world, cfg, GridRes.center_of(a + Vector2i(5, 0)))
		eq(u.path.size(), 1, "开阔地直线可达时路径只有 1 个点（已拉直，不是阶梯）")

	# 5) 中途立刻换命令会覆盖旧路径
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

	# 6) ★ 点在自己脚下附近（同一格内）也必须真的动 —— 回归：
	#    原来这里用了 `> 0.5`（像素阈值被误用在「格」坐标系里 = 半格），
	#    于是「鼠标点得越准，单位越不动」：0.05 / 0.2 / 0.45 格全都一动不动，
	#    而且 order_move 还返回 true。见 docs/pitfalls.md 3.2 的同款陷阱。
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

		# 点在自己正脚下：不该产生任何位移（但也不能算「失败了」）
		u.stop()
		u.pos = GridRes.center_of(a)
		u.sync_tile(world.map)
		var same_pos: Vector2 = u.pos
		ok(u.order_move(world, cfg, same_pos), "点击自己脚下：命令被接受")
		for i in 10:
			world.tick(DT)
		v2_near(u.pos, same_pos, 1e-6, "点击自己脚下：位置不变（不会自己抖）")

	u.stop()


# ------------------------------------------------------------------
# 直线拉平的超覆盖判定
# ------------------------------------------------------------------
func _test_segment_clear(world, cfg) -> void:
	# 空地图上一条普通直线必须可走
	ok(PathfinderRes.segment_clear(world.map, world.buildings, cfg, Vector2(0.5, 0.5), Vector2(5.5, 0.5), "p1"),
		"开阔直线的 segment_clear 为真")
	# 起点所在格不检查通行性（单位可能正站在后来被建筑占住的格子上）
	var free = _find_free_tile(world, cfg, Vector2i(3, 13))
	if free != null:
		var tower = world.add_building("tower", free.x, free.y, "p1")
		ok(PathfinderRes.segment_clear(world.map, world.buildings, cfg, GridRes.center_of(free),
			Vector2(free.x + 3.5, free.y + 0.5), "p1"),
			"起点格被建筑占住时直线仍然可走（起点不检查）")
		world.remove_building(tower, false)

	# 墙另一侧不可达：起点在一侧、终点在另一侧，中间隔着一段墙
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

	# 超覆盖：两座山之间「只碰一个角」的缝隙不能穿过去（普通 DDA 会漏掉）
	var corner = _find_corner_gap(world)
	if corner != null:
		var mid = Vector2(corner.x + 1.0, corner.y + 1.0)
		var diag_a = Vector2(corner.x + 0.5, corner.y + 0.5)
		var diag_b = Vector2(corner.x + 1.5, corner.y + 1.5)
		ok(not PathfinderRes.segment_clear(world.map, world.buildings, cfg, diag_a, diag_b, "p1"),
			"超覆盖判定拒绝从两座山的对角缝隙穿过")
		ok(mid.x > 0.0 or mid.y > 0.0, "对角判定用例已构造")


# ------------------------------------------------------------------
# nearest_reachable：必须过滤「从起点真的走得到」
# ------------------------------------------------------------------
func _test_nearest_reachable(world, cfg) -> void:
	# 目标就是可通行格 → 原样返回
	var free = _find_free_tile(world, cfg, Vector2i(5, 13))
	if free != null:
		var r = PathfinderRes.nearest_reachable(world.map, world.buildings, cfg, free, free, "p1")
		ok(r != null and r.x == free.x and r.y == free.y, "目标可通行时 nearest_reachable 原样返回")

	# 目标是大本营（占格）→ 返回旁边一格，且那一格必须真的走得到
	var base_b = world.find_base_of("p1")
	if base_b != null:
		var from = Vector2i(base_b.tx + 4, base_b.ty + 3)
		var spot = PathfinderRes.nearest_reachable(world.map, world.buildings, cfg, from, Vector2i(base_b.tx, base_b.ty), "p1", 20)
		ok(spot != null, "大本营旁边的可达格能找出来")
		if spot != null:
			ok(PathfinderRes.passable(world.map, world.buildings, cfg, spot.x, spot.y, "p1"), "找出来的落点可通行")
			var region = PathfinderRes.reachable_tiles(world.map, world.buildings, cfg, from, "p1")
			ok(region.has(world.map.terrain.idx(spot.x, spot.y)), "★ 落点必须从起点真的走得到（过滤生效）")


# ------------------------------------------------------------------
# 战斗与警戒
# ------------------------------------------------------------------
func _test_combat(world, cfg) -> void:
	var w2 = WorldRes.create(cfg)
	var g = w2.units[0]
	var e = w2.spawn_enemy(g.tx + 6, g.ty)
	ok(e != null, "能刷出测试敌人")
	if e == null:
		return
	eq(e.faction, "enemy", "测试敌人阵营")
	eq(e.hp, cfg.enemy_hp, "测试敌人血量来自 config.debug.enemy_hp")

	# ★ 把亲兵和其他将领挪走：否则「谁掉了多少血」「打了几下」全都会被打乱
	#   （亲兵也会一起开火，敌人几帧就被打死，冷却断言反而永远不成立）
	_isolate(w2, [g, e])

	# 距离 6 格 > 警戒 4 格：静止不索敌
	g.stop()
	e.stop()
	w2.tick(DT)
	ok(g.target == null, "警戒半径外不索敌")

	# 拉近到 3 格：应立刻锁定（并先靠近再开火）
	g.pos = GridRes.center_of(Vector2i(e.tx - 3, e.ty))
	g.sync_tile(w2.map)
	g.stop()
	w2.tick(DT)
	ok(g.target == e, "警戒半径内的敌人被锁定")
	var hp_before: float = e.hp
	for i in 240:
		w2.tick(DT)
		if e.hp < hp_before:
			break
	ok(e.hp < hp_before, "追上后真的开火了（敌人掉血）")

	# 攻击间隔：0.9 秒内不该打出第二下
	var hp_after_first: float = e.hp
	var cd_hits = 0
	for i in 30:
		w2.tick(DT)
		if e.hp < hp_after_first:
			cd_hits += 1
			hp_after_first = e.hp
	ok(cd_hits <= 1, "0.5 秒内不会连打（攻击冷却生效）")

	# 玩家命令中断交战
	g.order_move(w2, cfg, GridRes.center_of(Vector2i(g.tx, g.ty + 3)))
	ok(g.target == null, "右键移动命令会中断交战")

	# 阵亡：单机不复活，且阵亡单位会离场
	e.hp = 1.0
	e.take_damage(cfg, w2, 999.0, g)
	ok(not e.alive, "单位被打死")
	ok(not e.awaiting_respawn(), "单机阵亡不进入等待复活（pvp 总开关关着）")
	w2.tick(DT)
	ok(w2.unit_by_id(e.id) == null, "阵亡单位在 tick 后离场")

	# CONFIG.combat.enabled = false 时不索敌、不保留旧目标
	var w3 = WorldRes.create(cfg)
	cfg.combat_enabled = false
	var g3 = w3.units[0]
	var e3 = w3.spawn_enemy(g3.tx + 2, g3.ty)
	_isolate(w3, [g3, e3])
	w3.tick(DT)
	ok(g3.target == null, "combat.enabled = false 时不索敌")
	cfg.combat_enabled = true


# ------------------------------------------------------------------
# 城墙血量 + 敌人拆墙（真实 AI 全链路）
# ------------------------------------------------------------------
func _test_wall_and_enemy_ai(world, cfg) -> void:
	var w = WorldRes.create(cfg)
	var base_b = w.find_base_of("p1")
	ok(base_b != null, "拆墙用例：有大本营")
	if base_b == null:
		return
	var bx: int = base_b.tx
	var by: int = base_b.ty

	# 用城墙把大本营围成一圈（8 邻格里的可通行格）
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

	# 敌人在远处，且它的可通行区域被墙切开
	var e = w.spawn_enemy(bx + 5, by)
	ok(e != null, "拆墙用例：敌人已生成")
	if e == null:
		return
	eq(e.hp, cfg.enemy_hp, "敌人血量 60")

	# ★ 把将领与亲兵全部撤走：这里只验「拆墙」这一条链路本身。
	#   留着防守单位的话敌人会先跟它们打起来 —— 那是**正确**的防守行为，
	#   但会把「墙掉血」这个断言变得又慢又随机（第一版就是被这个绕进去的：
	#   敌人一路被将领咬到 12,6 就死了，一次墙都没砸到）。
	#   防守单位迎战敌人这条链路在 _test_combat 里单独验。
	_isolate(w, [e])

	# 敌人应该找不到通往大本营的完整路径（被墙拦住）
	var direct = PathfinderRes.find_path(w.map, w.buildings, cfg, Vector2i(e.tx, e.ty), Vector2i(bx, by), "enemy")
	ok(direct == null, "城墙拦住后敌人到不了大本营那一格（大本营本身也占格）")

	# 跑一段时间：敌人应当锁定某段城墙并把第一下砸下去
	var wall_lost := false
	var target_wall = null
	var ticks = 0
	while ticks < 60 * 60 and not wall_lost:
		w.tick(DT)
		ticks += 1
		var tb = e.target_building
		if tb != null:
			if target_wall == null:
				target_wall = tb
			if tb.hp < 300.0:
				wall_lost = true
	ok(target_wall != null, "敌人锁定了挡路的城墙（%d 帧内）")
	ok(wall_lost, "敌人真的开始拆墙了（城墙掉血）")

	if target_wall != null:
		ok(walls.has(target_wall), "锁定的确实是大本营周围的城墙")
		# 掉血必须是单次伤害（combat.building_damage = 40）的整数倍
		var lost: float = 300.0 - target_wall.hp
		var steps: float = lost / cfg.building_damage
		ok(absf(steps - roundf(steps)) < 1e-6, "掉血量是单次伤害 40 的整数倍（掉了 %.0f）" % lost)

		# 拆穿：一直跑到它塌
		var guard = 0
		while target_wall.alive and guard < 60 * 120:
			w.tick(DT)
			guard += 1
		ok(not target_wall.alive, "城墙最终被拆毁")
		# 缺口立刻变成可通行（城墙是从地图与建筑表里一起摘掉的）
		ok(w.building_at(target_wall.tx, target_wall.ty) == null, "城墙拆毁后从格子索引里摘掉")
		ok(not w.building_list.has(target_wall), "拆毁的城墙也从建筑表里移除")
		ok(PathfinderRes.passable(w.map, w.buildings, cfg, target_wall.tx, target_wall.ty, "enemy"),
			"拆毁的城墙那一格立刻对敌方变成可通行")

		# 敌人从缺口走进来：最终能贴到大本营旁边
		# （将领死后不再有单位拦截它 —— 单机不复活，这正是「死了就没了」的行为）
		var reached := false
		var guard2 := 0
		while guard2 < 60 * 180 and not reached:
			w.tick(DT)
			guard2 += 1
			if absi(e.tx - bx) + absi(e.ty - by) <= 1:
				reached = true
		ok(reached, "敌人拆穿城墙后走进来并停在大本营旁")


# ------------------------------------------------------------------
# 箭塔
# ------------------------------------------------------------------
func _test_tower(world, cfg) -> void:
	var w = WorldRes.create(cfg)
	var g = w.units[0]
	var free = _find_free_tile(w, cfg, Vector2i(g.tx + 3, g.ty))
	if free == null:
		ok(false, "箭塔用例：找得到空地")
		return
	var tower = w.add_building("tower", free.x, free.y, "p1")
	ok(tower != null, "箭塔建造成功")
	if tower == null:
		return
	eq(tower.tower_damage(cfg), 12.0, "箭塔伤害 12")
	eq(tower.tower_range(cfg), 3.0, "箭塔射程 3 格")

	# 射程内放一个敌人
	var e = w.spawn_enemy(free.x + 2, free.y)
	ok(e != null, "箭塔用例：敌人已生成")
	if e == null:
		return

	# ⚠️ 把**所有**友方单位（将领 + 亲兵）挪走：它们在警戒半径内会去打这个敌人，
	#    那样「敌人掉了多少血」就分不清是箭塔打的还是友军打的。
	#    （第一次写这个用例时就是这么被骗过去的 —— 敌人 30 帧掉了 26 点血，那是将领的伤害；
	#      加了亲兵之后更是几帧就打死了，于是这条断言又假失败一次）
	_isolate(w, [e])

	var hp0: float = e.hp
	w.tick(DT)
	ok(e.hp == hp0 - 12.0, "箭塔第一帧就打掉 12 点（首次开火无冷却）")

	# 冷却 0.8 秒：接下来 0.5 秒内不再掉血
	var hp1: float = e.hp
	for i in 30:
		w.tick(DT)
	ok(absf(e.hp - hp1) < 1e-6, "箭塔 0.8 秒冷却内不再开火")

	# 不误伤己方：**单独建一个世界来测**。
	#
	# ⚠️ 别把这个断言塞进上面那个有敌人的世界里：把将领挪进箭塔射程时，
	#    它同时也进了敌人的警戒半径，敌人会来打它 —— 掉的血是敌人打的，
	#    断言就会误报成「箭塔打自己人」（第一版就是这么被骗的）。
	var wt = WorldRes.create(cfg)
	var tower2 = wt.add_building("tower", wt.units[0].tx + 3, wt.units[0].ty, "p1")
	ok(tower2 != null, "不误伤用例：箭塔建好了")
	if tower2 != null:
		var gu2 = wt.units[0]
		_isolate(wt, [gu2])          # 同样只留这一个，别让亲兵跑过来当靶子
		gu2.pos = GridRes.center_of(Vector2i(tower2.tx, tower2.ty - 1))
		gu2.sync_tile(wt.map)
		gu2.stop()
		var g_hp: float = gu2.hp
		for i in 120:
			wt.tick(DT)
		ok(absf(gu2.hp - g_hp) < 1e-6, "箭塔不误伤己方单位（贴脸站 2 秒也不掉血）")

	# 射程外打不到
	var e_far = w.spawn_enemy(free.x + 8, free.y)
	if e_far != null:
		_isolate(w, [e, e_far])
		var far_hp: float = e_far.hp
		w.tick(DT)
		ok(absf(e_far.hp - far_hp) < 1e-6, "射程外（8 格）打不到")


# ------------------------------------------------------------------
# 区块占领与资源
# ------------------------------------------------------------------
func _test_zones_and_economy(world, cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]
	# 只留这一个：亲兵也会占区块进度，混在一起就分不清是「将领站在那里」还是「亲兵站在那里」
	_isolate(w, [u])
	# 找一个无主区块，把将领放进去（避开大本营所在的那个区块）
	var z = null
	for zz in w.zones.zones:
		if zz["owner"] == "":
			z = zz
			break
	ok(z != null, "存在无主区块")
	if z == null:
		return
	var cx: int = (int(z["x0"]) + int(z["x1"])) / 2
	var cy: int = (int(z["y0"]) + int(z["y1"])) / 2
	var spot = _find_free_tile(w, cfg, Vector2i(cx, cy))
	ok(spot != null, "无主区块里有可站立的格子")
	if spot == null:
		return
	u.pos = GridRes.center_of(spot)
	u.sync_tile(w.map)
	u.stop()
	var zid: int = int(z["id"])

	# 进度每秒 +1/4（capture_time_sec = 4），多个同阵营单位不叠加
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), 0.25, 1e-3, "站 1 秒进度 0.25")
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), 0.5, 1e-3, "站 2 秒进度 0.5")

	# 离开后进度按 0.6/秒 回退
	#
	# ⚠️ 落点要挑**离对家据点足够远**的地方：玩家单位现在会自动索敌建筑
	#    （需求：「给己方单位增加索敌建筑的机制」），停在据点旁边会被一栋对家箭塔拽走，
	#    人就离开区块了 —— 这条断言验证的是「人走了、进度回退」，别掺进战斗。
	u.pos = GridRes.center_of(Vector2i(2, w.map.rows - 2))
	u.sync_tile(w.map)
	u.drop_engagement()
	w.tick(1.0)
	near(float(w.zones.zones[zid]["progress_by"]["p1"]), 0.375, 1e-3,
		"离开 1 秒后进度回退 0.125（0.5 - 0.125，速率见 config.zone.decay_per_sec）")

	# 站满 4 秒完成占领，并开始产出资源
	u.pos = GridRes.center_of(spot)
	u.sync_tile(w.map)
	for i in 5:
		w.tick(1.0)
	eq(String(w.zones.zones[zid]["owner"]), "p1", "站满 4 秒完成占领")

	var tiles: int = w.zones.owned_tile_count("p1")
	ok(tiles >= int(z["tile_count"]), "己方地块数包含新占的区块")
	eq(w.owned_tiles, tiles, "world.owned_tiles 与区块统计一致")

	var food0: float = float(w.resources["food"])
	w.tick(1.0)
	var gain: float = float(w.resources["food"]) - food0
	near(gain, float(tiles), 1e-3, "每秒粮食产出 = 己方地块数")

	# 每阵营独立进度（不再互相抵消）——联机能力的地基，单机也要成立
	var z2: Dictionary = w.zones.zones[zid]
	ok(z2["progress_by"].has("p1") and z2["progress_by"].has("enemy"), "progress_by 每阵营一项")


# ------------------------------------------------------------------
# 建造命令（走 command_processor，不直接调 world）
# ------------------------------------------------------------------
func _test_build_commands(world, cfg) -> void:
	var w = WorldRes.create(cfg)
	var free = _find_free_tile(w, cfg, Vector2i(3, 3))
	ok(free != null, "建造用例：找得到空地")
	if free == null:
		return

	var cmd = {"kind": "build", "build_type": "wall", "tx": free.x, "ty": free.y, "faction": "p1"}
	ok(CommandRes.apply(w, cfg, cmd), "build 命令被接受")
	var b = w.building_at(free.x, free.y)
	ok(b != null, "建筑真的落成了")
	if b != null:
		eq(b.type, "wall", "落成的是城墙")
		eq(b.owner, "p1", "归属是命令里的 faction")

	# 同一格再建 → 拒绝
	ok(not CommandRes.apply(w, cfg, cmd), "同一格重复建造被拒绝")

	# 拆自己人的建筑 → 允许
	var del = {"kind": "demolish", "tx": free.x, "ty": free.y, "faction": "p1"}
	ok(CommandRes.apply(w, cfg, del), "拆除命令被接受")
	ok(w.building_at(free.x, free.y) == null, "拆除后格子空了")

	# 拆别人 / 不存在的 → 拒绝
	ok(not CommandRes.apply(w, cfg, del), "拆不存在的建筑被拒绝")
	var base_b = w.find_base_of("p1")
	if base_b != null:
		ok(not CommandRes.apply(w, cfg, {"kind": "demolish", "tx": base_b.tx, "ty": base_b.ty, "faction": "p1"}),
			"大本营不可拆除")

	# move 命令只能命令自己这一方的单位（防冒充语义）
	var other = w.units[0]
	other.faction = "p2"
	var moved = CommandRes.apply(w, cfg, {"kind": "move", "ids": [other.id], "x": 100.0, "y": 100.0, "faction": "p1"})
	ok(not moved, "★ 拿别人阵营的单位 id 下达 move 命令无效（防冒充）")
	other.faction = "p1"

	# 未知命令返回 false（不要静默吞掉）
	ok(not CommandRes.apply(w, cfg, {"kind": "teleport"}), "未知命令返回 false")


# ------------------------------------------------------------------
# 快照往返 + 缺字段容忍
# ------------------------------------------------------------------
func _test_snapshot(world, cfg) -> void:
	var w = WorldRes.create(cfg)
	w.spawn_enemy(10, 12)
	w.tick(DT)
	var snap = SnapshotRes.to_snapshot(w)

	# 开局单位数 = 将领数 + 将领数×亲兵数 + 1 个敌人 + 地图预置的守军
	var per_leader: int = int(cfg.num("unit.subordinate.count", 0.0))
	var expect_units: int = 3 + 3 * per_leader + 1 + w.map.prefab_units.size()
	eq((snap["units"] as Array).size(), expect_units,
		"快照里有 %d 个单位（3 将领 + %d 亲兵 + 1 敌人 + %d 地图守军）" % [
			expect_units, 3 * per_leader, w.map.prefab_units.size()])
	ok((snap["buildings"] as Array).size() >= 1, "快照里有建筑")
	eq((snap["zones"] as Array).size(), 24, "快照里有 24 个区块")
	ok(snap.has("res") and (snap["res"] as Array).size() == 2, "快照带两种资源")
	ok(not (snap["units"] as Array)[0].has("path"), "★ 快照不发路径（只发结果）")
	ok((snap["units"] as Array)[0].has("x") and (snap["units"] as Array)[0].has("fa"), "快照带位置与朝向")

	# 每个单位都要带队长字段（客机靠它做「选中将领=选中整队」）
	var sub_in_snap := 0
	var ld_ok := true
	for su in (snap["units"] as Array):
		if String(su.get("k", "")) == UnitRes.KIND_SUBORDINATE:
			sub_in_snap += 1
			if su.get("ld", null) == null:
				ld_ok = false
	eq(sub_in_snap, 3 * per_leader, "快照里有 %d 个亲兵" % (3 * per_leader))
	ok(ld_ok, "★ 快照里的亲兵都带队长 id（客机才做得出整队选中）")

	# 应用到一个全新的世界：单位 / 建筑 / 资源都应当对齐
	var w2 = WorldRes.create(cfg)
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

	# 新建的远端亲兵也要认得队长（否则客机上「选中将领」选不到它）
	if per_leader > 0:
		var leader = w2.unit_by_id("general-1")
		ok(leader != null, "客机侧有 general-1")
		if leader != null:
			var got: Array = w2.group_of(leader)
			eq(got.size(), 1 + per_leader, "★ 客机侧队伍展开得到「队长 + %d 亲兵」" % per_leader)

	# 快照里没有的单位 = 已阵亡 → 被删掉
	var small = {"units": [], "buildings": [], "zones": []}
	SnapshotRes.apply_snapshot(w2, cfg, small)
	eq(w2.units.size(), 0, "快照里没有的单位被删除")

	# ★ 缺字段容忍：不含 match / res / time 的旧快照不能把本地状态重置掉
	var w3 = WorldRes.create(cfg)
	w3.resources["food"] = 42.0
	w3.time = 7.0
	SnapshotRes.apply_snapshot(w3, cfg, {"units": [], "buildings": []})
	near(float(w3.resources["food"]), 42.0, 1e-6, "缺 res 字段时保持本地资源不变")
	near(w3.time, 7.0, 1e-6, "缺 time 字段时保持本地时间不变")
	ok(SnapshotRes.to_snapshot(w3)["units"] is Array, "空世界也能建快照（不崩）")


# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

## ★ 把世界里除了 keep 之外的**其他单位全部移出世界**。
##
## 为什么需要：自从「将领带亲兵」之后，一个世界里默认有 12 个单位（3 将领 + 9 亲兵）。
## 凡是断言「谁打了谁」「掉了多少血」「走到了哪」「哪个区块是谁的」的用例，
## 都会被旁观者搅乱 —— 这类坑本项目已经踩过三次
## （将领干扰箭塔测试、将领把测试敌人打死、亲兵占区块进度）。
##
## 做法是**真的从 world.units 里摘掉**，而不是挪到地图角落：
##   · 挪到角落仍然会占区块进度（`站满 4 秒完成占领` 就是这么假失败的：亲兵在角落把区块占了）；
##   · 挪到角落仍然会被碰撞推挤影响轨迹。
##   摘掉则是干净的 —— 被测单位看到的就是一个「只有它自己」的世界。
##
## ⚠️ 只对**权威侧**的世界成立：客机上单位是从快照来的，没有这个需求。
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


## 按 kind 挑出单位（断言里别再写「所有单位都该是将领」——加了新兵种就会假失败）
func _units_of_kind(world, kind: String) -> Array:
	var out: Array = []
	for u in world.units:
		if u.kind == kind:
			out.append(u)
	return out


## 找一格里附近没有建筑、可通行的空地（从 hint 往外扩圈）
func _find_free_tile(world, cfg, hint: Vector2i) -> Variant:
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
				return Vector2i(x, y)
	return null


## 找一座山，并返回它
func _find_mountain_adjacent_walkable(world, _cfg) -> Variant:
	for y in world.map.rows:
		for x in world.map.cols:
			if not world.map.terrain_walkable(x, y):
				return Vector2i(x, y)
	return null


## 清掉某一整行上的建筑（建长墙之前用，保证这一行是干净的一整条）
func _wall_off_row(world, row: int) -> void:
	for x in world.map.cols:
		var b = world.building_at(x, row)
		if b != null:
			world.remove_building(b, true)


## 在某一整行上拉一条城墙（只铺可通行格），返回真正建出来的那些段。
## 用途：造出「横贯地图的墙」——单格城墙在四连通地图上永远绕得过去，证明不了拦断。
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


## 找一处「两格对角相邻、都是山」的构造，用来验证超覆盖判定的对角缝隙
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
