## test_diagonal.gd —— 八方向移动回归（本项目有意偏离 HTML 版的四连通的那一处）
##
## 八方向只有两个地方会出错，而且**都会「能跑通但感觉怪」**，所以必须用断言钉住：
##   1. 对角穿角：从两个障碍的尖角之间挤过去（四连通下物理上不存在，八方向才会出现）
##   2. 代价与启发式不成对：斜走记 1 而不是 √2，A* 就会偏爱斜线、给出绕远的路线
##
## 另外验证「切回四连通」这条路真的还在（config.path.diagonal = false），
## 因为文档说了四连通才是 HTML 版的原版规则，它必须还能切得回去。
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


## 在离某个点足够远的地方刷一个敌人（挑可通行格，不写死偏移量）。
##
## ★ 为什么不能写死 `base + 6`：换一张地图就可能落到山上或图外，
##   —— `spawn_enemy` 那时会返回 null，测试报的却是「敌人没生成」，
##   看起来像功能坏了（换地图时真的踩到了）。
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


## 把地图上的**区划中心**（中立障碍建筑）摘掉。
##
## ★ 这套用例验的是「八方向的代价 / 对角守卫 / 城墙阻挡」，而中心是**另一码事**：
##   它们按 6×4 的规律每隔 4 格一根，会把「开阔地走直线、绕圈」这类
##   本该干净的场景弄脏（实测：代价断言 10.66 ≠ octile 10.07、步数 8 ≠ 6）。
##   障碍本身的行为在 test_logic / test_building_body 里单独验。
func _clear_zone_centers(w) -> void:
	for b in w.building_list.duplicate():
		if b.type == "zone_center":
			w.remove_building(b, true)
	w.refresh_ownership()


## 方向集本身
func _test_direction_sets(cfg) -> void:
	eq(GridRes.DIRS4.size(), 4, "DIRS4 仍然是四个方向")
	eq(GridRes.DIRS8.size(), 8, "DIRS8 是八个方向")
	eq(GridRes.DIRS4_DIAGONAL.size(), 4, "对角方向四个")

	# DIRS8 = DIRS4 + 四个对角，且没有重复
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

	# 步长与 octile 距离：这是「代价与启发式同口径」的基座
	near(GridRes.step_length(Vector2i(1, 0)), 1.0, 1e-9, "直走一步的代价是 1")
	near(GridRes.step_length(Vector2i(1, 1)), GridRes.DIAGONAL_COST, 1e-9, "斜走一步的代价是 √2")
	near(GridRes.octile_distance(3, 0), 3.0, 1e-9, "octile：纯水平 = 曼哈顿")
	near(GridRes.octile_distance(2, 2), 2.0 * GridRes.DIAGONAL_COST, 1e-9, "octile：纯对角 = 2√2")
	near(GridRes.octile_distance(3, 1), GridRes.DIAGONAL_COST + 2.0, 1e-9, "octile(3,1) = 1 次斜走 + 2 次直走 = √2 + 2")

	# ★ octile 对八方向是**可采纳**的：它永远不超过真实最优代价（否则 A* 会不最优）
	#
	# 「真实最优代价 = 尽量斜着走 + 剩下的直走」= 与 octile 同一个式子的下界。
	# 所以可采纳性等价于「octile ≤ 曼哈顿」（曼哈顿是四连通下的最优代价，八方向只会更短）。
	var ok_admissible := true
	for dx in range(-6, 7):
		for dy in range(-6, 7):
			var oct := GridRes.octile_distance(dx, dy)
			var manhattan := float(absi(dx) + absi(dy))
			if oct > manhattan + 1e-9:
				ok_admissible = false
	ok(ok_admissible, "★ octile 不会超过曼哈顿（即可采纳，A* 仍然最优）")

	# 顺带：斜走确实比两条直走便宜（1.414 < 2），这就是八方向能抄近路的原因。
	ok(GridRes.step_length(Vector2i(1, 1)) < 2.0, "★ 一步对角比两步正交便宜（所以八方向路程更短）")


## 开阔地斜着走：八方向应该比四连通短
func _test_diagonal_shortens_path(cfg) -> void:
	var w = WorldRes.create(cfg)
	# ★ 摘掉区划中心再验「开阔地更短」：这张图上 (5,4) 就是一根中心柱，
	#   正好卡在 (2,2) 到 (8,5) 的直线路径上（实测：不摘掉时 6 步变 7 步）。
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

	# 每一步都必须真的是八个方向之一（防止出现「跳格」）
	var valid := true
	for i in range(path.size()):
		var prev: Vector2i = from if i == 0 else (path as Array)[i - 1]
		var step: Vector2i = (path as Array)[i]
		if maxi(absi(step.x - prev.x), absi(step.y - prev.y)) != 1:
			valid = false
	ok(valid, "每一步都是紧邻格（没有跳格）")


## ★ 对角不许穿角：两座山对着一个格，斜着穿不过去
func _test_no_corner_cutting(cfg) -> void:
	var map = MapDataRes.load_from("res://data/test_map.json", cfg)
	ok(map != null, "载入地图用于造对角障碍")
	if map == null:
		return
	# 人工造一个「山 / 山」的对角结构
	var cx := 4
	var cy := 12
	map.terrain.set_cell(cx + 1, cy, MapDataRes.TERRAIN_MOUNTAIN)
	map.terrain.set_cell(cx, cy + 1, MapDataRes.TERRAIN_MOUNTAIN)
	# ⚠️ 手改地形之后必须重建掩码（is_forest / terrain_cost 现在读的是掩码）
	map.rebuild_terrain_masks()
	var buildings := GridRes.new(map.cols, map.rows, null)

	ok(not PathfinderRes.passable(map, buildings, cfg, cx + 1, cy, "p1"), "右上角是障碍")
	ok(not PathfinderRes.passable(map, buildings, cfg, cx, cy + 1, "p1"), "左下角是障碍")
	ok(PathfinderRes.passable(map, buildings, cfg, cx, cy, "p1"), "出发点可通行")
	ok(PathfinderRes.passable(map, buildings, cfg, cx + 1, cy + 1, "p1"), "目标格可通行")

	# 该斜步必须被守卫拦住
	ok(not PathfinderRes.diagonal_step_allowed(map, buildings, cfg, cx, cy, Vector2i(1, 1), "p1"),
		"★ 斜向穿过两个障碍的尖角被禁止")
	# 直线段判定同样不该放行（超覆盖 DDA 早就拦掉了，这里一起盯着）。
	var from_pt := Vector2(float(cx) + 0.5, float(cy) + 0.5)
	var to_pt := Vector2(float(cx + 1) + 0.5, float(cy + 1) + 0.5)
	ok(not PathfinderRes.segment_clear(map, buildings, cfg, from_pt, to_pt, "p1"),
		"超覆盖直线判定也拒绝这条对角线")

	# A* 仍然能到（绕一格），但**不能**一步穿过去
	var path = PathfinderRes.find_path(map, buildings, cfg, Vector2i(cx, cy), Vector2i(cx + 1, cy + 1), "p1")
	ok(path != null, "对角堵住时仍然绕得过去")
	if path != null:
		ok((path as Array).size() >= 2, "★ 不能一步穿过去（至少要绕一格）")


## 放开开关后，对角缝就允许穿（这是 config 里那个开关的契约）。
func _test_corner_cut_switch(cfg) -> void:
	var map = MapDataRes.load_from("res://data/test_map.json", cfg)
	var cx := 4
	var cy := 12
	map.terrain.set_cell(cx + 1, cy, MapDataRes.TERRAIN_MOUNTAIN)
	map.terrain.set_cell(cx, cy + 1, MapDataRes.TERRAIN_MOUNTAIN)
	# ⚠️ 手改地形之后必须重建掩码（is_forest / terrain_cost 现在读的是掩码）
	map.rebuild_terrain_masks()
	var buildings := GridRes.new(map.cols, map.rows, null)

	var was: bool = cfg.bool_val("path.diagonal_corner_cut", false)
	cfg.path_diagonal_corner_cut = true
	ok(PathfinderRes.diagonal_step_allowed(map, buildings, cfg, cx, cy, Vector2i(1, 1), "p1"),
		"★ 开关打开后允许穿对角缝")
	var path = PathfinderRes.find_path(map, buildings, cfg, Vector2i(cx, cy), Vector2i(cx + 1, cy + 1), "p1")
	ok(path != null and (path as Array).size() == 1, "开关打开后一步就穿过去")
	cfg.path_diagonal_corner_cut = was


## 代价与启发式的口径一致性：在开阔地，实际代价应该 ≈ octile 距离
##
## ⚠️ 先把**区划中心**摘掉：它们是中立障碍柱，按 6×4 的规律每隔 4 格一根；
##    (1,1)→(9,6) 这条线正好要绕过 (5,5) 那一根，于是「实际代价」会比 octile 大，
##    这一条就不再是「代价与启发式同口径」的验证了。
func _test_cost_and_heuristic_agree(cfg) -> void:
	var w = WorldRes.create(cfg)
	_clear_zone_centers(w)
	var from := Vector2i(1, 1)
	var to := Vector2i(9, 6)
	var path = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, "p1")
	ok(path != null, "开阔地有路径")
	if path == null:
		return
	# 自己按「直走 1 / 斜走 √2」算一遍这条路的代价（忽略森林，取纯几何）
	var cost := 0.0
	var prev: Vector2i = from
	for step in (path as Array):
		var d: Vector2i = (step as Vector2i) - prev
		cost += GridRes.step_length(d)
		prev = step
	var oct := GridRes.octile_distance(to.x - from.x, to.y - from.y)
	near(cost, oct, 1e-6, "★ 实际路径代价 = octile 距离（代价与启发式同口径）")


## 切回四连通：行为必须真的变回四连通（文档说四连通是 HTML 版原规则，这条路要留着）
func _test_switching_back_to_four(cfg) -> void:
	var was: bool = cfg.bool_val("path.diagonal", true)
	cfg.path_diagonal = false

	eq(GridRes.directions(cfg).size(), 4, "diagonal=false 时方向集退回四个")

	var w = WorldRes.create(cfg)
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
	# 复原后方向集要回来
	eq(GridRes.directions(cfg).size(), 8, "恢复 diagonal=true 后方向集回到八个")


## ★ 城墙的阻挡语义在八方向下**不能变弱**（否则所有防御工事都被悄悄削弱）
func _test_wall_still_blocks(cfg) -> void:
	var w = WorldRes.create(cfg)
	# ★ 先摘掉区划中心：它们会占掉大本营周围的一格，让「围一圈」少一段；
	#   而下面那条 `eq(solid, walled)` 会把中心也数进去（它是建筑、也对敌人不可通行），
	#      于是「8 != 6」这种假失败。这一节验的是**城墙**。
	_clear_zone_centers(w)
	# ★ 再把地图预置的城墙也摘掉：出生点的防御阵地里就有几段墙（在大本营的右上方），
	#   它会让下面的「邻格数出来的墙」比「我这一圈砌的墙」多一段（实测 8 != 7）。
	for b in w.building_list.duplicate():
		if b.type == "wall":
			w.remove_building(b, true)
	w.refresh_ownership()
	var base_b = w.find_base_of("p1")
	ok(base_b != null, "有大本营")
	if base_b == null:
		return

	# 把大本营周围能站人的邻格全部用墙围死（8 邻格）。
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

	# 敌人从远处来时**不能**斜着从两段墙的夹缝钻进大本营。
	# ⚠️ 出生点要挑一个**能站人**的：`spawn_enemy` 会自己就近找可通行格，
	#    但「离远处」这个语义得由测试保证 —— 这一版的地图大本营周围有山，
	#    写死偏移量会落到山上 / 图外（实测 `spawn_enemy(base+6, base)` 返回 null）。
	var e = _spawn_enemy_far_from(w, base_b, cfg)
	ok(e != null, "敌人已生成")
	if e == null:
		return
	var direct = PathfinderRes.find_path(w.map, w.buildings, cfg,
		Vector2i(e.tx, e.ty), Vector2i(base_b.tx, base_b.ty), "enemy")
	ok(direct == null, "★ 八方向下大本营仍然进不去（没有从墙缝钻进来）")

	# 围圈的每一段墙，对敌人来说都不可通行
	# ⚠️ 只数**城墙**：大本营 / 箭塔也占地格、也对敌人不可通行，
	#    混进来会让「可通行的一段」把分母撑大（实测 8 != 7 —— 那是旁边的箭塔）。
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
