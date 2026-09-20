## test_crowd_path.gd —— ★★ 距离场（C# 内核）与 A*（logic/pathfinder.gd）必须给出同一个答案
##
## 为什么必须有这个文件：现在跑的是**两套寻路实现** ——
##   · 单个单位 / 内核不可用时：pathfinder.find_path 的 A*（GDScript，参考实现）
##   · 群编（1000 单位）：C# 的 Dijkstra 距离场 + 顺场下降（快 1000 倍的那条路）
## 两条路算出来的**代价必须逐格一致**，否则就是经典的「BFS 说走得到、A* 说走不到」
## （docs/pitfalls.md 3.3）——症状是单位站在原地看着不动，而且不会报任何错。
##
## ★ 这个文件真的抓到过一个 bug：A* 把一步的代价记在**进入的那一格**上，所以
##   这个图是**有向的**；反向 Dijkstra 里如果不把代价记在「离开的那一格」，
##   森林格的代价就会算错一边，场里出现「比真实最优更贵的值」。
##   当时的症状是下降找不到下降方向 → 群编直接不动。见 CrowdKernel.BuildField 的注释。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")

const DT := 1.0 / 60.0
const FACTION := "p1"


func _initialize() -> void:
	_case_name = "test_crowd_path"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var w = WorldRes.create(cfg)
	if w == null:
		return
	w.tick(DT)                  # 触发桥的建表（tick 里第一次用到内核）

	if w.crowd == null or not w.crowd.available():
		ok(false, "★ C# 寻路内核可用（普通版引擎 / 没构建 C# 时这条会红）")
		return
	ok(true, "C# 寻路内核可用")

	_test_path_cost_matches_astar(w, cfg)
	_test_reachable_matches(w, cfg)
	_test_unreachable_agrees(w, cfg)
	_test_segment_clear_matches(w, cfg)


## ★★ 直线判定（segment_clear）的两套实现必须逐条一致。
##
## 为什么这条最关键：`smooth_path` 拿它决定「这条直线能不能走」——
## 一旦内核版比 GDScript 版**宽松**，单位就会沿直线穿墙/翻山；
## 比它**严格**，路径就会莫名其妙变弯。两种都不会报错，只会「手感怪」。
## 所以这里拿一批直线（含刻意对齐格点、只擦到一个角的那些）逐条比对。
func _test_segment_clear_matches(w, cfg) -> void:
	var worst := 0
	var checked := 0
	var mismatches: Array[String] = []

	var anchors: Array[Vector2i] = [Vector2i(2, 14), Vector2i(2, 13), Vector2i(4, 4),
		Vector2i(10, 10), Vector2i(6, 12), Vector2i(0, 0)]
	for sa in anchors:
		for sb in anchors:
			if sa == sb:
				continue
			var a := GridRes.center_of(sa)
			var b := GridRes.center_of(sb)
			checked += 1
			var gd: bool = PathfinderRes.segment_clear(w.map, w.buildings, cfg, a, b, FACTION)
			var cs = w.crowd.segment_clear_here(cfg, a, b, FACTION)
			if cs == null:
				ok(false, "内核 segment_clear 可用")
				return
			if gd != bool(cs):
				worst += 1
				mismatches.append("%s→%s gd=%s cs=%s" % [str(sa), str(sb), str(gd), str(cs)])

	# 再补一批「非格心端点」的斜线：只擦到一个角、正好穿过格点这些退化情况最容易出分歧
	for i in 48:
		var a := Vector2(1.5 + float(i % 7) * 1.37, 2.5 + float(i / 7) * 1.11)
		var b := a + Vector2(6.3 - float(i % 5) * 1.9, 5.1 + float(i % 3) * 2.2)
		checked += 1
		var gd: bool = PathfinderRes.segment_clear(w.map, w.buildings, cfg, a, b, FACTION)
		var cs = w.crowd.segment_clear_here(cfg, a, b, FACTION)
		if cs == null:
			ok(false, "内核 segment_clear 可用")
			return
		if gd != bool(cs):
			worst += 1
			mismatches.append("%s→%s gd=%s cs=%s" % [str(a), str(b), str(gd), str(cs)])

	ok(checked >= 70, "对照了足够多的直线（%d 条）" % checked)
	eq(worst, 0, "★ 内核 segment_clear 与 GDScript 版逐条一致（不一致 %s）" % str(mismatches.slice(0, 3)))


## 逐个 (起点, 终点) 对：场下降出来的路线，代价必须与 A* 的**完全相等**。
## 只比「路一样长」是不够的 —— 森林 / 建筑惩罚都会让「步数」和「代价」脱钩。
func _test_path_cost_matches_astar(w, cfg) -> void:
	var starts: Array[Vector2i] = []
	var goals: Array[Vector2i] = []
	for y in range(2, w.map.rows - 2, 5):
		for x in range(2, w.map.cols - 2, 5):
			if PathfinderRes.passable(w.map, w.buildings, cfg, x, y, FACTION):
				starts.append(Vector2i(x, y))
	for t in starts:
		goals.append(t)

	var checked := 0
	var worst := 0.0
	var mismatch := 0
	for s in starts:
		for g in goals:
			if s == g:
				continue
			var a = PathfinderRes.find_path(w.map, w.buildings, cfg, s, g, FACTION)
			var b = w.crowd.tile_path(w, cfg, s, g, FACTION)
			if a == null or b == null:
				if (a == null) != (b == null):
					mismatch += 1
				continue
			var ca := _path_cost(w, cfg, a, s)
			var cb := _path_cost(w, cfg, b, s)
			worst = maxf(worst, absf(ca - cb))
			checked += 1
	ok(checked > 20, "对照了足够多的 (起点, 终点) 对（%d 组）" % checked)
	ok(mismatch == 0, "★ 场与 A* 对「走不走得到」的判断一致（不一致 %d 组）" % mismatch)
	ok(worst < 1e-6, "★ 场与 A* 算出的路径**代价完全相等**（最大偏差 %.9f）" % worst)


## 可达性掩码（内核 BFS）与 reachable_tiles（GDScript BFS）必须是同一批格子。
## 这两套只要有一点点通行规则不一致，敌人 AI / 落点选择就会开始发呆。
func _test_reachable_matches(w, cfg) -> void:
	var starts: Array[Vector2i] = [Vector2i(2, 14), Vector2i(4, 4), Vector2i(10, 10)]
	var worst := 0
	for s in starts:
		# 起点不可通行也要对得上：GDScript 版把起点自己算进去（单位可能站在建筑格上）
		var region = PathfinderRes.reachable_tiles(w.map, w.buildings, cfg, s, FACTION)
		var mask: PackedByteArray = w.crowd.reachable_mask(w, cfg, s, FACTION)
		if mask.is_empty():
			ok(false, "可达掩码非空（起点 %s）" % str(s))
			continue
		var diff := 0
		for y in w.map.rows:
			for x in w.map.cols:
				var idx: int = w.map.terrain.idx(x, y)
				var a: bool = region.has(idx)
				var b: bool = mask[idx] != 0
				if a != b:
					diff += 1
		worst = maxi(worst, diff)
	ok(worst == 0, "★ 可达性与 GDScript 版逐格一致（最大差异 %d 格）" % worst)


## 目标不可通行 / 地图外时，两边都必须返回 null（而不是给一条穿墙的路）。
func _test_unreachable_agrees(w, cfg) -> void:
	var from := Vector2i(2, 13)
	# (2,14) 是山；(0,0) 越界
	for to in [Vector2i(2, 14), Vector2i(-1, 0), Vector2i(999, 999)]:
		var a = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, FACTION)
		var b = w.crowd.tile_path(w, cfg, from, to, FACTION)
		if to.x < 0 or to.y < 0 or to.x >= w.map.cols or to.y >= w.map.rows:
			ok(a == null and b == null, "越界终点 %s：两边都拒绝" % str(to))
		else:
			ok(a == null and b == null, "不可通行终点 %s：两边都拒绝" % str(to))


## 一条地块路线的**真实代价**：与 find_path 的口径逐条对齐 ——
## 代价记在进入的那一格上（地形代价 + 建筑惩罚），斜走乘 √2。
func _path_cost(w, cfg, path: Array, from: Vector2i) -> float:
	var cost := 0.0
	var cur: Vector2i = from
	for n in path:
		var d := Vector2i(n.x - cur.x, n.y - cur.y)
		cost += (PathfinderRes._terrain_cost(w.map, n.x, n.y)
			+ PathfinderRes._building_penalty(w.buildings, cfg, n.x, n.y, FACTION)) * GridRes.step_length(d)
		cur = n
	return cost
