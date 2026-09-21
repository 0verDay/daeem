## test_building_body.gd —— 建筑「本体」的碰撞与挡路规则（UI 改版之后新增的一整套）
##
## 需求原话：「将大本营和箭塔在格子内居中，且大本营和箭塔略小于一个格子大小，
##            其本体会阻挡敌方单位，但敌方单位可以从建筑空隙中穿过，
##            其本体不会阻挡己方单位」
##
## 这套断言盯五件事：
##   1. **尺寸与来源**：本体边长 = config 的 building.<type>.body_scale × 格宽，且居中；
##      渲染用的矩形与碰撞用的矩形是**同一个数**（不是各写一套内缩量）
##   2. **己方**：整格放行 + 本体也不挡 —— 可以直接站在大本营本体上
##   3. **敌方**：格子能走（缝要能走），但**本体挡** —— 位置不会被推进本体里
##   4. **缝**：两个对角相邻的箭塔之间能挤过去（本体小于一格才有这条缝），
##      两段对角相邻的城墙之间**不能**（墙是整格，缝宽 0）
##   5. **城墙行为不变**：整格挡敌方、放行己方（这条是回归，别被本体模型带偏）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CollisionRes = preload("res://logic/collision.gd")
const BuildingRes = preload("res://logic/building.gd")
const PaletteRes = preload("res://view/palette.gd")
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
	_test_map_units(cfg)


# ------------------------------------------------------------------
# 1. 几何：本体大小 / 居中 / 渲染 = 碰撞
# ------------------------------------------------------------------
func _test_geometry(cfg) -> void:
	var w = WorldRes.create(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	ok(base_b != null, "有大本营")
	if base_b == null:
		return
	# ⚠️ 两个坐标都要用**元组**传：`add_building(type, x, y, owner)` 收的是四个参数，
	#    而 `_free_tile_near()` 返回的是一个 Vector2i —— 直接传进去会
	#    `Invalid call ... Expected 4 argument(s)`（换图之后这条路径才被走到）。
	var near_tower: Vector2i = _free_tile_near(w, base_b.tx + 3, base_b.ty)
	var tower = w.add_building("tower", near_tower.x, near_tower.y, FactionRes.DEFAULT_FACTION)
	ok(tower != null, "在大本营旁边建了一座箭塔")
	if tower == null:
		return

	# 数值来自 config：0.6 格
	near(base_b.body_scale(cfg), cfg.num("building.base.body_scale", 0.0), 1e-6, "大本营本体走 config")
	near(tower.body_scale(cfg), cfg.num("building.tower.body_scale", 0.0), 1e-6, "箭塔本体走 config")
	ok(base_b.body_scale(cfg) < 1.0, "★ 大本营本体小于一格（%.2f 格）" % base_b.body_scale(cfg))
	ok(tower.body_scale(cfg) < 1.0, "★ 箭塔本体小于一格（%.2f 格）" % tower.body_scale(cfg))

	# 居中：本体中心 == 格心
	for b in [base_b, tower]:
		var r: Rect2 = b.body_rect(cfg)
		v2_near(r.get_center(), b.center(), 1e-6, "%s 的本体在格子内居中" % b.display_name())
		near(r.size.x, b.body_scale(cfg), 1e-6, "%s 本体边长 = body_scale" % b.display_name())
		near(r.size.y, b.body_scale(cfg), 1e-6, "%s 本体是正方形" % b.display_name())
		# 本体必须整个落在自己那一格里
		ok(r.position.x >= float(b.tx) - 1e-6 and r.end.x <= float(b.tx) + 1.0 + 1e-6,
			"%s 的本体没有越出自己的格子" % b.display_name())

	# ★ 渲染矩形 = 碰撞矩形（同一个来源；各写一套内缩量迟早错位）
	#
	# ⚠️ 容差用 1e-4 而不是 1e-6：这两边是**两条不同的算式**
	#    （一边 `cell_px*0.6`、一边 `cell_px - 2*cell_px*(1-0.6)*0.5`），
	#    而 0.6 在二进制里是无限循环小数 —— 差额在 1e-6 量级。
	#    断言的本意是「两者等价」，不是「逐位相同」（实测 38.400002 vs 38.400000）。
	var px: Rect2 = PaletteRes.building_rect(base_b, cfg)
	near(px.size.x, base_b.body_scale(cfg) * cfg.cell_px, 1e-4, "★ 大本营的渲染宽度 = 本体宽度（像素）")
	near(px.size.y, base_b.body_scale(cfg) * cfg.cell_px, 1e-4, "★ 大本营的渲染高度 = 本体高度（像素）")
	v2_near(px.get_center(), PaletteRes.to_px(base_b.center(), cfg), 1e-4, "★ 渲染矩形与本体同心")

	# ★★ 真正被画出来的那个矩形是**节点局部坐标**的（节点原点 = 自己那一格的左上角）。
	#    第一版就是这里错的：只取了绝对矩形的 size、从 (0,0) 开始画 →
	#    城墙（1.0 格）看不出来，大本营 / 箭塔却贴到了格子左上角。
	#    所以这条断言必须按**局部**矩形写，光验绝对矩形是不够的（吃过一次亏）。
	var half: float = cfg.cell_px * 0.5
	for b in [base_b, tower]:
		var lr: Rect2 = PaletteRes.building_local_rect(b, cfg)
		v2_near(lr.get_center(), Vector2(half, half), 1e-4,
			"★★ %s 在格子里居中（渲染用的局部矩形，中心 = 格心）" % b.display_name())
		near(lr.position.x, (cfg.cell_px - lr.size.x) * 0.5, 1e-4,
			"%s 的左边距 = 右边距（留白对称）" % b.display_name())
	var near_wall: Vector2i = _free_tile_near(w, base_b.tx - 3, base_b.ty)
	var wall = w.add_building("wall", near_wall.x, near_wall.y, FactionRes.DEFAULT_FACTION)
	if wall != null:
		near(PaletteRes.building_rect(wall, cfg).size.x, cfg.cell_px, 1e-6, "城墙仍然填满整格")
		v2_near(PaletteRes.building_local_rect(wall, cfg).get_center(), Vector2(half, half), 1e-6,
			"城墙的局部矩形也居中（整格时中心同样是格心）")

	# 线段判定：横穿本体 → 命中；擦着本体外面过 → 不命中
	var r2: Rect2 = tower.body_rect(cfg)
	var mid: Vector2 = r2.get_center()
	ok(tower.blocks_segment(cfg, mid + Vector2(-1.0, 0.0), mid + Vector2(1.0, 0.0), 0.0),
		"横穿本体的线段被判为「切进本体」")
	ok(not tower.blocks_segment(cfg, mid + Vector2(-1.0, -0.6), mid + Vector2(1.0, -0.6), 0.0),
		"从本体上方掠过的线段不算命中")


# ------------------------------------------------------------------
# 2. 己方：整格放行 + 本体不挡
# ------------------------------------------------------------------
func _test_ally_passes(cfg) -> void:
	var w = WorldRes.create(cfg)
	var base_b = w.find_base_of(FactionRes.DEFAULT_FACTION)
	var g = w.unit_by_id("general-1")
	ok(base_b != null and g != null, "有大本营与将领 1")
	if base_b == null or g == null:
		return

	ok(PathfinderRes.passable(w.map, w.buildings, cfg, base_b.tx, base_b.ty, g.faction),
		"★ 大本营那一格对己方是可通行的")
	ok(not base_b.body_blocks(g.faction), "★ 大本营的本体不阻挡己方")
	ok(not CollisionRes.body_blocked_at(w, cfg, g.faction, base_b.center(), CollisionRes.radius(cfg)),
		"己方可以站在大本营本体正中")

	# 真的站上去：命令它走到本体中心，跑完不该被推开
	#
	# ⚠️ 起点必须**真的走得到**本体中心：这张图上大本营正上方就是自己的城墙、
	#    右边有箭塔、东边一整排是山 —— 写死「base + 4 格」会落在山那边，
	#    `order_move` 直接返回 false（实测距离 4.0 格、根本没动）。
	#    所以从一个**可通行且可达**的邻格出发（南边那一格）。
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


# ------------------------------------------------------------------
# 3. 敌方：格子能走，但本体挡
# ------------------------------------------------------------------
func _test_enemy_blocked_by_body(cfg) -> void:
	var w = WorldRes.create(cfg)
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

	# 硬碰撞：把敌人硬塞进本体里，跑一帧就该被挤出去
	#
	# ⚠️ 先把据点**周围一圈**的建筑摘掉再验这一条：
	#    这张图上大本营正上方就有一段自己的城墙 —— 敌人被挤出本体后会落在那一格上，
	#    `_can_stand()` 判它不可通行 → 推不动 → `pushed = 0`（实测）。
	#    这一条要验的是「本体把人挤出去」，不是「四周有没有墙」，所以先清场。
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

	# 一路推进：敌人从远处来，最后一定停在「本体之外」，不会钻进本体里
	var e2 = _spawn_enemy_near(w, base_b, cfg, 5)
	if e2 != null:
		for i in 900:
			w.tick(DT)
		ok(not CollisionRes.body_blocked_at(w, cfg, e2.faction, e2.pos, r),
			"★ 推进 900 帧后敌人仍然在本体之外（位置 %s）" % str(e2.pos))
		# 停稳之后不能来回抖（本体硬碰撞最容易出的退化就是这个）
		var p1: Vector2 = e2.pos
		for i in 120:
			w.tick(DT)
		ok(e2.pos.distance_to(p1) < 0.05,
			"★ 顶到据点之后停稳了（120 帧漂移 %.4f 格）" % e2.pos.distance_to(p1))


# ------------------------------------------------------------------
# 3.5 敌人与据点之间横着一座箭塔：寻路要绕开本体，而不是一条直线顶上去
# ------------------------------------------------------------------
## 这条盯的是 A* 的建筑惩罚：塔格虽然可通行，但不该被当成捷径穿过去。
## 只验寻路（不跑 tick），所以不怕塔把敌人打死 —— 断言是确定性的。
func _test_path_avoids_body(cfg) -> void:
	var w = WorldRes.create(cfg)
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


# ------------------------------------------------------------------
# 4. 缝：对角相邻的两个箭塔之间能挤过去（墙不能）
# ------------------------------------------------------------------
func _test_gap_between_towers(cfg) -> void:
	var w = WorldRes.create(cfg)
	var e = w.spawn_enemy(0, 0)
	if e == null:
		return
	w.units = [e]
	# ★ 只验「缝能不能走」：把探针敌人做成打不死的。
	#   单位速度降到 1/4 之后，这段 4 格的路要走近 10 秒，而两座箭塔
	#   （12 伤 / 0.8 秒）足够把 60 血的测试敌人在半路打死 ——
	#   那样量到的是「它死了」，不是「缝走不通」（实测 hp 12/60 → 0，第 97 帧停住）。
	#   战斗本身在 test_attack_orders / test_logic 里单独验，这里不掺。
	e.hp = 100000.0
	e.hp_max = 100000.0

	# 找一对对角相邻的空格，摆两座**对家**箭塔（对敌人来说是障碍）
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

	# 两座对家箭塔摆在**对角**：敌人从 (tx+1, ty) 斜着走到 (tx, ty+1)，正好从两座本体之间的缝穿过
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

	# 真的走过去：从左下角绕到右上角，必须能到
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


# ------------------------------------------------------------------
# 5. 城墙：语义一字未变（整格挡敌方、放行己方）
# ------------------------------------------------------------------
func _test_wall_unchanged(cfg) -> void:
	var w = WorldRes.create(cfg)
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

	# 两段对角相接的城墙之间**不能**斜穿（缝宽 0）
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


# ------------------------------------------------------------------
# 6. 地图上预置的对家据点（test_map.json 的 "buildings" 字段）
#
# 这一组是**给手玩测试用的摆设**：大本营 + 箭塔 + 城墙，放在地图东南角。
# （原来是老图 map_01.json 里的东侧据点，老图删掉后搬进了 test_map.json。）
# 断言盯三件事：每一条都真的建出来了、归属对、**离玩家大本营足够远**。
# ------------------------------------------------------------------
func _test_map_outpost(cfg) -> void:
	var w = WorldRes.create(cfg)
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

	eq(placed, prefab.size(), "★ 每一条预置建筑都真的建出来了（占格 / 山上会被静默跳过）")
	eq(owner_ok, placed, "预置建筑的归属与地图里写的一致")
	ok(kinds.has("base"), "预置据点里有大本营")
	ok(kinds.has("tower"), "预置据点里有箭塔")
	ok(kinds.has("wall"), "预置据点里有城墙")
	ok(min_dist >= 6, "★ 预置据点离玩家大本营足够远（最近的一条 %d 格）" % min_dist)

	# 敌方城墙挡玩家、敌方本体的空隙能走（把新模型放到真实地图上再验一次）
	for p in prefab:
		var b2 = w.building_at(int(p["x"]), int(p["y"]))
		if b2 == null or b2.owner != "enemy":
			continue
		if b2.type == "wall":
			ok(not PathfinderRes.passable(w.map, w.buildings, cfg, b2.tx, b2.ty, "p1"),
				"★ 对家城墙那一格对玩家不可通行")
			break

	# 走近对家箭塔会挨打（「放几个敌人让我测试」最核心的一条）
	var tower_tile := Vector2i(-1, -1)
	for p in prefab:
		if String(p["type"]) == "tower":
			tower_tile = Vector2i(int(p["x"]), int(p["y"]))
			break
	if tower_tile.x < 0:
		return
	var g = w.unit_by_id("general-1")
	w.units = [g]                        # 隔离：只留将领，别让亲兵与敌兵干扰
	g.stop()
	g.pos = Vector2(tower_tile) + Vector2(-2.0, 0.5)   # 站在塔西边 2 格（射程 3 格内）
	g.sync_tile(w.map)
	var hp0: float = g.hp
	for i in 90:
		w.tick(DT)
	ok(g.hp < hp0, "★ 走近对家箭塔会挨打（生命 %.0f → %.0f）" % [hp0, g.hp])


# ------------------------------------------------------------------
# 7. 地图上预置的对家单位（test_map.json 的 "units"）
#
# 给手玩测试用的守军：断言盯「每一条都建出来了 / 位置对 / hold 标记对 / 离大本营够远」，
# 外加一条行为：hold 的单位**不会**朝玩家据点行军（那是它们能当靶子的前提）。
# ------------------------------------------------------------------
func _test_map_units(cfg) -> void:
	var w = WorldRes.create(cfg)
	var prefab: Array = w.map.prefab_units
	ok(prefab.size() >= 4, "地图里有预置单位（%d 条）" % prefab.size())
	if prefab.is_empty():
		return

	var home: Vector2i = w.home_base_of(FactionRes.DEFAULT_FACTION)
	var min_dist := 999
	var placed := 0
	var held := 0
	var movers := 0
	for p in prefab:
		var tile := Vector2i(int(p["x"]), int(p["y"]))
		min_dist = mini(min_dist, absi(tile.x - home.x) + absi(tile.y - home.y))
		var found = null
		for u in w.units:
			if u.alive and u.tx == tile.x and u.ty == tile.y and not FactionRes.same_side(u.faction, w.my_faction):
				found = u
				break
		if found == null:
			continue
		placed += 1
		if found.hold_position:
			held += 1
		else:
			movers += 1
		eq(String(found.name), String(p["name"]), "预置单位的名字与地图里写的一致（%s）" % found.name)

	eq(placed, prefab.size(), "★ 每一条预置单位都真的建出来了")
	ok(held >= 1, "有驻守（hold）的守军 —— 拿来当靶子用")
	ok(movers >= 1, "也有不驻守的巡逻兵 —— 用来验「敌人行军」这条老行为还在")
	ok(min_dist >= 6, "★ 预置单位离玩家大本营足够远（最近的一条 %d 格）" % min_dist)

	# hold 单位的核心行为：不朝玩家据点行军
	var holder = null
	for u in w.units:
		if u.alive and u.hold_position and not FactionRes.same_side(u.faction, w.my_faction):
			holder = u
			break
	ok(holder != null, "取到一个驻守单位")
	if holder != null:
		# ★ 关掉战斗再验「不推进」：
		#   `hold_position` 的语义是「**不执行推进 AI**」，迎战不受影响（有人靠近照样打）。
		#   而这张图的 p2 大本营就在 (14,19)、离它不远，开着战斗时它会迎战并移动 ——
		#   那是**正确**的防守行为，不是「跑去打据点」。这一条只验推进 AI 不启动。
		var was_combat: bool = cfg.combat_enabled
		cfg.combat_enabled = false
		var start: Vector2 = holder.pos
		for i in 300:
			w.tick(DT)
		cfg.combat_enabled = was_combat
		ok(holder.pos.distance_to(start) < 0.6,
			"★ 驻守单位不会自己跑去打据点（5 秒位移 %.3f 格）" % holder.pos.distance_to(start))


# ---- 工具 ----

## 调试用：列出某格周围的建筑
func _bld_around(w, cx: int, cy: int, radius: int) -> Array:
	var out: Array = []
	for b in w.building_list:
		if absi(b.tx - cx) <= radius and absi(b.ty - cy) <= radius:
			out.append("%s@(%d,%d)" % [b.type, b.tx, b.ty])
	return out


## 把 (cx, cy) 周围 radius 格内的建筑（**不含大本营自己**）摘掉。
##
## 用途：验「本体把单位挤出去」时，别让旁边的城墙把挤出的落点堵死
## （堵死时 `_can_stand()` 会拒绝位移，断言就会得到 `pushed = 0` 这种假失败）。
func _clear_buildings_around(w, cx: int, cy: int, radius: int) -> void:
	for b in w.building_list.duplicate():
		if b.type == "base":
			continue
		if absi(b.tx - cx) <= radius and absi(b.ty - cy) <= radius:
			w.remove_building(b, true)
	w.refresh_ownership()


## 在离某个据点大约 R 格的地方刷一个敌人（挑真正可通行、没建筑的格）。
##
## ★ 为什么不能写死 `base + R`：不同地图上那个方向可能是山、图外或自己的建筑 ——
##   那样 `spawn_enemy` 会返回 null，测试报的却是「刷不出测试敌人」，
##   看起来像功能坏了（这一轮换图时真的踩到）。
##   所以**先试 R 那一圈，再往外多试几圈**（半径可变），直到找到一格能站人的。
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
