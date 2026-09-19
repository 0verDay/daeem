## pathfinder.gd —— 四连通网格通行判定 + A* 寻路 + 直线拉平
##                    （对应 HTML 版 js/path.js）
##
## 通行规则集中在这里：
##   - 地形：山完全阻挡，草地/森林可通行（森林只是「贵」一点）
##   - 建筑：城墙对「己方单位」放行、对「敌方单位」阻挡（城墙填充整个地块）
##           大本营/箭塔等占位建筑：单位不能站上去（点击它们时自动停在最近可站格）
##
## 寻路分两步（这样单位在开阔地走直线，而不是沿格心走阶梯）：
##   1. find_path()   —— 四连通 A*，只负责回答「绕开山 / 城墙该走哪几个格子」
##   2. smooth_path() —— 把 A* 的折线拉直：每次贪心跳到「直线可达」的最远点，
##                       直线是否可达由 segment_clear() 逐格判定
##
## ⚠️ 全部坐标都是**格**（逻辑坐标），不是像素。像素只在 view/ 出现。
extends RefCounted

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")

## 每个圆角细分成几段。段数越多转向越平滑（每帧转角 ≈ 整个拐角 / 段数），
## 代价只是路径数组多几个点 —— 8 段足够把 90° 摊到每帧十几度以内。
const CORNER_SEGMENTS := 8


## 某地块对指定阵营是否可通行（**格级**）。
##
## ★ UI 改版之后：城墙仍然「整格挡敌方 / 放行己方」；
##   大本营 / 箭塔**整格对谁都不封**（本体小于一格，缝隙要能走）。
##   它们的阻挡交给 building.body_blocks() + 移动碰撞（logic/collision.gd），
##   以及下面 _squeeze_through_gap() 的斜向缝判定。
## state 需要：terrain(GridRes) / building_at(tx,ty) -> Building 或 null
static func passable(map, buildings, cfg: ConfigRes, x: int, y: int, faction: String) -> bool:
	if not map.terrain.has(x, y):
		return false
	if not map.terrain_walkable(x, y):
		return false
	var b = buildings.get_cell(x, y)
	if b != null:
		# 城墙：己方放行、敌方挡死；大本营/箭塔：两边都放行（本体另行处理）
		return b.blocks(faction) == false
	return true


## 是否被建筑占据（建造校验用）
static func occupied(buildings, x: int, y: int) -> bool:
	return buildings.get_cell(x, y) != null


## 地形移动消耗：森林更「贵」（A* 的代价）
static func _terrain_cost(map, x: int, y: int) -> float:
	return map.terrain_cost(x, y)


## 建筑格在 A* 里的额外代价：**本体真的挡这个阵营**时才加
## （己方本来就能从本体上走过去，没必要罚它绕路）。
##
## 数值是 config 的 path.building_penalty（口径 = 「多绕几格才划算」）。
## 为什么需要它：大本营 / 箭塔的格子现在是可通行的，不加惩罚的话
## 敌人会一条直线从箭塔正中穿过去 —— 结果就是一路顶着本体蹭，看着很蠢。
static func _building_penalty(buildings, cfg: ConfigRes, x: int, y: int, faction: String) -> float:
	var b = buildings.get_cell(x, y)
	if b == null or not b.alive:
		return 0.0
	if not b.body_blocks(faction):
		return 0.0
	return maxf(0.0, cfg.num("path.building_penalty", 12.0))


## 斜向一步是否**允许**（反对角穿角）。
##
## 八方向有一个四连通根本不存在的陷阱：
##     山 草
##     草 山      ← 两个可通行格只在一个角上相碰
## 只看目标格可通行的话，单位就会从两座山的**尖角之间**挤过去。
## 所以斜走时要求**两个正交邻格都可通行**。
##
## 守方视角：这条守卫让「城墙的阻挡语义」与四连通时完全一致 ——
## 斜着一格错开的墙照样挡得住人（否则八方向会悄悄削弱所有防御工事）。
## 想放开就把 config 的 path.diagonal_corner_cut 设成 true。
##
## ★ UI 改版补的一个例外：两个正交邻格如果都是**本体小于一格的建筑**（大本营 / 箭塔），
##   那么它们在本体之外是留了缝的 —— 缝够这个单位挤过去时放行（见 _squeeze_through_gap）。
##   城墙是整格的，缝宽为 0，所以上面那条守卫对城墙**一字未变**。
static func diagonal_step_allowed(map, buildings, cfg: ConfigRes, x: int, y: int, d: Vector2i, faction: String) -> bool:
	if not GridRes.is_diagonal(d):
		return true
	if cfg.bool_val("path.diagonal_corner_cut", false):
		return true
	if not passable(map, buildings, cfg, x + d.x, y, faction):
		return _squeeze_through_gap(map, buildings, cfg, x, y, d, faction)
	if not passable(map, buildings, cfg, x, y + d.y, faction):
		return _squeeze_through_gap(map, buildings, cfg, x, y, d, faction)
	return true


## 斜着从两个建筑本体之间的缝挤过去 —— 只有真的够宽才放行。
##
## 几何：四格交汇的角 P（斜步走向的那一侧）。两块本体各自取「离 P 最近的点」，
## 两点的距离就是这条斜向通道的净宽。城墙的本体就是整格，最近点都是 P → 宽 0 → 不放行。
## 要求：净宽 ≥ 单位直径（unit.collision_radius × 2，与单位之间挤碰同一套半径）。
static func _squeeze_through_gap(map, buildings, cfg: ConfigRes, x: int, y: int, d: Vector2i, faction: String) -> bool:
	var ax: int = x + d.x
	var ay: int = y
	var bx: int = x
	var by: int = y + d.y
	# 「斜穿两座山」仍然一律禁止：只有两边都是**建筑**才谈得上缝
	if not _blocked_by_building(map, buildings, ax, ay):
		return false
	if not _blocked_by_building(map, buildings, bx, by):
		return false
	var ba = buildings.get_cell(ax, ay)
	var bb = buildings.get_cell(bx, by)
	if ba == null or bb == null or not ba.alive or not bb.alive:
		return false
	var corner := Vector2(float(x + maxi(d.x, 0)), float(y + maxi(d.y, 0)))
	var pa: Vector2 = ba.closest_point_on_body(cfg, corner)
	var pb: Vector2 = bb.closest_point_on_body(cfg, corner)
	var width: float = pa.distance_to(pb)
	var need: float = maxf(0.0, cfg.num("unit.collision_radius", 0.18)) * 2.0
	return width >= need


## 这一格是不是「只被活着的建筑挡着」（山 / 地图边界不算）
static func _blocked_by_building(map, buildings, x: int, y: int) -> bool:
	if not map.terrain.has(x, y) or not map.terrain_walkable(x, y):
		return false
	var b = buildings.get_cell(x, y)
	return b != null and b.alive


## A* 寻路（四连通 / 八方向，由 config 的 path.diagonal 决定）
##
## @return Array[Vector2i]：**不含起点、含终点**的地块列表；
##         起点即终点时返回空数组；不可达或终点不可通行时返回 null。
##
## ★ 两条必须保持的行为（都是有出处的坑）：
##   1. **起点所在格不检查通行性** —— 单位可能正站在后来被建筑占住的格子上
##      （脚下被盖了箭塔），不许检查它，否则单位永远走不出来。
##   2. 终点必须完全可通行；点到山/建筑时由调用方先换成最近可达格。
##
## ★★ 八方向的两条铁律（改这里之前先读 docs/pitfalls.md 5.8）：
##   1. **步进代价与启发式必须成对改**：斜走 1.414 而不是 1，启发式就必须从曼哈顿
##      换成 octile。只改一个的后果是 A* 偏爱斜线、给出明显绕远的路（而且能走通，
##      所以不会报错，只会「感觉怪」）。
##   2. **对角不能穿角**：见 diagonal_step_allowed()。
static func find_path(map, buildings, cfg: ConfigRes, from: Vector2i, to: Vector2i, faction: String) -> Variant:
	var cols: int = map.terrain.cols
	var rows: int = map.terrain.rows
	if not map.terrain.has(from.x, from.y) or not map.terrain.has(to.x, to.y):
		return null
	if from == to:
		var empty: Array[Vector2i] = []
		return empty
	if not passable(map, buildings, cfg, to.x, to.y, faction):
		return null

	var start_idx: int = map.terrain.idx(from.x, from.y)
	var goal_idx: int = map.terrain.idx(to.x, to.y)

	var g_score: Dictionary = {start_idx: 0.0}
	var came_from: Dictionary = {}
	var closed: Dictionary = {}
	var open: Array = []

	# octile 启发式：与「直走 1 / 斜走 √2」同一套口径，所以是可采纳的
	var h := func(x: int, y: int) -> float:
		return GridRes.octile_distance(x - to.x, y - to.y)

	open.append({"i": start_idx, "x": from.x, "y": from.y, "g": 0.0, "f": h.call(from.x, from.y)})

	while open.size() > 0:
		# 线性取最小。地图只有 24×16=384 格，线性扫描完全够用，
		# 而且不会像手写二叉堆那样出现「堆坏了但测试看不出来」的问题。
		var best_i := 0
		for k in range(1, open.size()):
			if float(open[k]["f"]) < float(open[best_i]["f"]):
				best_i = k
		var cur: Dictionary = open[best_i]
		open.remove_at(best_i)

		if int(cur["i"]) == goal_idx:
			# 回溯（不含起点、含终点）
			var out: Array[Vector2i] = []
			var k2: int = goal_idx
			while k2 != start_idx:
				out.append(Vector2i(k2 % cols, k2 / cols))
				if not came_from.has(k2):
					return null
				k2 = int(came_from[k2])
			out.reverse()
			return out

		if closed.has(int(cur["i"])):
			continue
		closed[int(cur["i"])] = true

		for d in GridRes.directions(cfg):
			var nx: int = int(cur["x"]) + d.x
			var ny: int = int(cur["y"]) + d.y
			if not map.terrain.has(nx, ny):
				continue
			if not passable(map, buildings, cfg, nx, ny, faction):
				continue
			if not diagonal_step_allowed(map, buildings, cfg, int(cur["x"]), int(cur["y"]), d, faction):
				continue
			var ni: int = map.terrain.idx(nx, ny)
			if closed.has(ni):
				continue
			# 代价 = 地形代价 × 这一步的距离权重（直走 1 / 斜走 √2）
			# ★ 再给「本体挡自己」的建筑格加一笔惩罚：建筑格是允许走的（本体只挡一部分），
			#   但不该被当成捷径 —— 加了它，敌人会优先绕开玩家的箭塔，绕不开才贴本体滑过去。
			var ng: float = float(cur["g"]) + (_terrain_cost(map, nx, ny) + _building_penalty(buildings, cfg, nx, ny, faction)) * GridRes.step_length(d)
			if (not g_score.has(ni)) or ng < float(g_score[ni]) - 1e-9:
				g_score[ni] = ng
				came_from[ni] = int(cur["i"])
				open.append({"i": ni, "x": nx, "y": ny, "g": ng, "f": ng + h.call(nx, ny)})

	return null


## 从起点做一次「按阵营通行规则」的 BFS，返回所有**走得到**的地块索引集合。
## 与地图连通性修正（只看地形）的区别：这里会把城墙 / 建筑一起算进去。
##
## 用途：判断「某格是不是我真能走到」（挑拆墙目标、挑点击不可通行处时的落脚点）。
## ⚠️ 这里的邻居生成与 A* **必须用同一套方向 + 同一条对角守卫**，
##    否则会出现「BFS 说走得到、A* 却找不到路」的不一致
##    （表现就是单位站在原地不动 —— docs/pitfalls.md 3.3 那个症状的另一条来路）。
static func reachable_tiles(map, buildings, cfg: ConfigRes, from: Vector2i, faction: String) -> Dictionary:
	var seen: Dictionary = {}
	if not map.terrain.has(from.x, from.y):
		return seen
	# 起点自己也算在内：单位可能站在后来被建筑占住的格子上，得允许它走出来
	seen[map.terrain.idx(from.x, from.y)] = true
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in GridRes.directions(cfg):
			var nx: int = c.x + d.x
			var ny: int = c.y + d.y
			if not map.terrain.has(nx, ny):
				continue
			var ni: int = map.terrain.idx(nx, ny)
			if seen.has(ni):
				continue
			if not passable(map, buildings, cfg, nx, ny, faction):
				continue
			if not diagonal_step_allowed(map, buildings, cfg, c.x, c.y, d, faction):
				continue
			seen[ni] = true
			queue.append(Vector2i(nx, ny))
	return seen


## 找到一个「离目标最近、**而且从 from 真的走得到**」的格子（BFS 扩散）。
## 用途：右键点到城墙/大本营/山上时，走到它旁边。
##
## ⚠️⚠️ 必须检查可达性：BFS 是从目标往外扩的，第一圈「可通行」的格子很可能是
##    墙 / 山**另一侧**的格子。旧实现直接返回它，于是 find_path() 必然失败、
##    调用方以为「哪都去不了」—— 这正是「敌人被城墙拦断后站在出生点发呆」的根因之一
##    （见 docs/pitfalls.md 3.3）。
##
## @return Vector2i 或 null
static func nearest_reachable(map, buildings, cfg: ConfigRes, from: Vector2i, target: Vector2i, faction: String, max_radius: int = 12) -> Variant:
	if passable(map, buildings, cfg, target.x, target.y, faction):
		return target
	var region := reachable_tiles(map, buildings, cfg, from, faction)
	var seen: Dictionary = {map.terrain.idx(target.x, target.y): true}
	var frontier: Array[Vector2i] = [target]
	for _r in max_radius:
		var next: Array[Vector2i] = []
		for c in frontier:
			# 与 reachable_tiles() 用同一套方向：否则会出现「扩圈说能到、可达性说不能」的错配
			for d in GridRes.directions(cfg):
				var nx: int = c.x + d.x
				var ny: int = c.y + d.y
				if not map.terrain.has(nx, ny):
					continue
				var ni: int = map.terrain.idx(nx, ny)
				if seen.has(ni):
					continue
				seen[ni] = true
				if passable(map, buildings, cfg, nx, ny, faction):
					if region.has(ni):
						return Vector2i(nx, ny)   # ★ 只认自己走得到的
					continue                       # 墙那一边的格子：当不了终点
				next.append(Vector2i(nx, ny))      # 继续穿过障碍往外找
		frontier = next
		if frontier.is_empty():
			break
	return null


## 线段是否「全程可通行」（直线移动的核心判定，单位是**格**）。
##
## 用超覆盖 DDA（Amanatides & Woo 体素遍历的加强版）枚举线段「擦到」的每一个地块，
## 包括只与线段相交于一个角的格子，所以直线不会从两座山 / 两段城墙的夹缝里穿过去
## （普通 DDA 会漏掉「只碰一个角」的格子，单位就能钻过去 —— 见 docs/pitfalls.md 3.5）。
##
## 注意：只检查线段**进入**的格子，**起点所在格不检查** —— 单位可能正站在之后被
##       建筑占住的格子上（例如脚下被盖了箭塔），此时仍必须允许它走出来。
static func segment_clear(map, buildings, cfg: ConfigRes, a: Vector2, b: Vector2, faction: String) -> bool:
	# 「这一格能不能切」= 格级可通行 **且** 这条线没有切进挡自己的建筑本体。
	# 后半条是 UI 改版补的：大本营 / 箭塔现在整格放行，只靠 passable() 会让
	# 拉直后的直线从本体正中穿过去（单位再撞在本体上，看着像卡住）。
	var pad: float = maxf(0.0, cfg.num("unit.collision_radius", 0.18))
	var blocked := func(cx: int, cy: int) -> bool:
		if not passable(map, buildings, cfg, cx, cy, faction):
			return true
		return _tile_body_blocks_segment(buildings, cfg, cx, cy, a, b, faction, pad)

	var x0: float = a.x
	var y0: float = a.y
	var dx: float = b.x - x0
	var dy: float = b.y - y0
	var tx: int = floori(x0)
	var ty: int = floori(y0)

	var step_x: int = 1 if dx > 0.0 else -1
	var step_y: int = 1 if dy > 0.0 else -1
	var t_delta_x: float = absf(1.0 / dx) if dx != 0.0 else INF
	var t_delta_y: float = absf(1.0 / dy) if dy != 0.0 else INF
	var t_max_x: float = ((tx + 1 - x0) * t_delta_x) if dx > 0.0 else ((x0 - tx) * t_delta_x)
	var t_max_y: float = ((ty + 1 - y0) * t_delta_y) if dy > 0.0 else ((y0 - ty) * t_delta_y)
	if dx == 0.0:
		t_max_x = INF
	if dy == 0.0:
		t_max_y = INF

	var guard := 0
	while guard < 8192:
		guard += 1
		if t_max_x > 1.0 and t_max_y > 1.0:
			return true                     # 线段已经走完
		if t_max_x < t_max_y:
			tx += step_x
			t_max_x += t_delta_x
			if blocked.call(tx, ty):
				return false
		elif t_max_y < t_max_x:
			ty += step_y
			t_max_y += t_delta_y
			if blocked.call(tx, ty):
				return false
		else:
			# 正好穿过格点：对角两侧都得让得开，才允许走这条直线
			if blocked.call(tx + step_x, ty):
				return false
			if blocked.call(tx, ty + step_y):
				return false
			tx += step_x
			ty += step_y
			t_max_x += t_delta_x
			t_max_y += t_delta_y
			if blocked.call(tx, ty):
				return false
	return false


## 线段是否切进这一格里「挡这个阵营」的建筑本体
static func _tile_body_blocks_segment(buildings, cfg: ConfigRes, x: int, y: int, a: Vector2, b: Vector2, faction: String, pad: float) -> bool:
	var bld = buildings.get_cell(x, y)
	if bld == null or not bld.alive:
		return false
	if not bld.body_blocks(faction):
		return false
	return bld.blocks_segment(cfg, a, b, pad)


## 把折线「拉直」（string pulling / 漏斗算法的贪心版）。
##
## 从第一个点出发，每次找「直线可达的最远点」作为下一个拐点；
## 于是开阔地带退化成一条直线，遇到山 / 城墙才保留必要的拐点。
## 因为每一段都用 segment_clear() 验证过，所以拉直不会让单位穿墙或翻山。
##
## 输入与输出都是**格**坐标（不是像素）；输出长度 ≤ 输入长度，首尾点不变。
static func smooth_path(map, buildings, cfg: ConfigRes, points: Array[Vector2], faction: String) -> Array[Vector2]:
	if points.size() <= 2:
		return points.duplicate()
	var out: Array[Vector2] = [points[0]]
	var i := 0
	while i < points.size() - 1:
		var j := points.size() - 1
		while j > i + 1 and not segment_clear(map, buildings, cfg, points[i], points[j], faction):
			j -= 1
		out.append(points[j])
		i = j
	return out


## 拐角圆化（把「到点才允许转向」变成「沿弧线转过去」）。
##
## 为什么需要：拉直只会**减少**路径点，但单位是走到路点才换方向的，
## 所以拐弯发生在**一帧之内**（实测直角弯处单帧转角 58°）——看着生硬。
## 圆化在每个拐点前后各切一小段、用二次贝塞尔曲线连过去。
##
## ★ 为什么要**细分**成多段（CORNER_SEGMENTS）：只在两个切点处各放一个点的话，
##   step_along_path() 会把它当成两个普通线段走，转向仍然集中在一两帧里
##   （实测只能从 58° 降到 30.6°）。细分成 8 段后，每一步只有整段转角 / 8，
##   转向才真正摊开。多出来的点很便宜：路径数组本来就只有几个点。
##
## ★ 安全性论证（这是本函数唯一需要被信任的地方）：
##   二次贝塞尔曲线**完全落在**「前一段切点 P、拐角 V、后一段切点 Q」构成的三角形内侧
##   （凸包性质）。而 P、V、Q 三点都在原来的折线上、原折线又被 segment_clear() 验证过，
##   所以曲线不可能越过障碍。函数里仍然对 P→Q 再做一次 segment_clear 兜底，
##   不通过就**放弃这个拐角**（宁可生硬，不可穿墙）。
##
## 输入输出都是**格**坐标。首点不变；末点一定是原来那个末点（玩家点击的位置）。
static func round_corners(map, buildings, cfg: ConfigRes, points: Array[Vector2], faction: String) -> Array[Vector2]:
	if not cfg.bool_val("path.corner_round_enabled", true):
		return points
	if points.size() <= 2:
		return points

	var cutting: float = cfg.num("path.corner_round_cutting", 0.35)
	var min_angle: float = deg_to_rad(cfg.num("path.corner_round_min_angle_deg", 20.0))
	if cutting <= 0.0:
		return points

	var out: Array[Vector2] = [points[0]]
	for idx in range(1, points.size() - 1):
		var prev: Vector2 = out[out.size() - 1]
		var v: Vector2 = points[idx]
		var next: Vector2 = points[idx + 1]

		var d_in: float = prev.distance_to(v)
		var d_out: float = v.distance_to(next)
		if d_in <= 1e-6 or d_out <= 1e-6:
			out.append(v)
			continue

		# 转向角：两条方向向量之间的夹角。小于阈值（接近直线）就不动它，
		# 免得把本来笔直的路硬掰成细细的波浪。
		var dir_in: Vector2 = (v - prev) / d_in
		var dir_out: Vector2 = (next - v) / d_out
		if absf(dir_in.angle_to(dir_out)) < min_angle:
			out.append(v)
			continue

		# 切点距离：既不能超过 cutting，也不能超过相邻段长的一半（否则两个圆角会互相吃掉）
		var cut: float = minf(cutting, minf(d_in, d_out) * 0.5)
		if cut <= 1e-6:
			out.append(v)
			continue

		var p: Vector2 = v - dir_in * cut
		var q: Vector2 = v + dir_out * cut
		if not segment_clear(map, buildings, cfg, p, q, faction):
			out.append(v)          # 兜底：宁可保留硬拐角
			continue
		# 二次贝塞尔：B(t) = (1-t)²P + 2(1-t)t·V + t²Q
		for i in range(1, CORNER_SEGMENTS):
			var t := float(i) / float(CORNER_SEGMENTS)
			var it := 1.0 - t
			out.append(it * it * p + 2.0 * it * t * v + t * t * q)
		out.append(q)

	# 末点无论如何都要保住：它是玩家点击的精确位置
	out.append(points[points.size() - 1])

	# 去掉因圆角而靠得过近的点（叠在一起的点只会浪费帧数，还会让朝向抖）
	var cleaned: Array[Vector2] = []
	for pt in out:
		if cleaned.is_empty() or cleaned[cleaned.size() - 1].distance_to(pt) > 1e-4:
			cleaned.append(pt)
	return cleaned


## 点到线段的最近点（圆化 / 落点投影都要用）
static func closest_point_on_segment(p: Vector2, a: Vector2, b: Vector2) -> Vector2:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq <= 1e-12:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


## 「离点击位置最近的、真正站得住的点」。
##
## 用途：右键点到山 / 城墙 / 建筑那一格时，原来的做法是走到**那一格的格心**，
## 于是你点格内哪个位置，停点都一样（实测：点大本营格靠右半边，停点离你点的地方 1.077 格），
## 看上去就是「贴不上去」。这里改成把点击位置投影到那一格内可行走的那部分边界上。
##
## 沿「格心 → 点击位置」这条方向逐段加密采样（而不是逐格试）：
## 单调步进的采样里最后一个可通行点就落在边界上，精度由 samples 决定
## （默认 32 段 ≈ 整格内 0.03 格的误差，比原来差半格好一个量级）。
##
## ⚠️ 采样点必须「真的从 from 走得到」—— 否则会给出墙另一侧的落点，
##    find_path 必然失败，调用方以为哪都去不了（docs/pitfalls.md 3.3）。
##
## @return Dictionary {"pt": Vector2, "tile": Vector2i} 或 null。
##   ⚠️ 一定要连**落点所在的格**一起返回：A* 的终点必须是可通行格，
##      而贴边落点往往就在（不可通行的）目标格边缘上，所以寻路终点得改成相邻那一格。
##      第一版只返回了一个点，于是调用方拿目标格去寻路 → 直接失败（连山都点不动了）。
static func nearest_reachable_point(map, buildings, cfg: ConfigRes, from: Vector2i, tile: Vector2i, click: Vector2, faction: String, samples: int = 32) -> Variant:
	if passable(map, buildings, cfg, tile.x, tile.y, faction):
		# 这一格本来就能站，直接走点击的精确位置
		return {"pt": click, "tile": tile}

	var center := GridRes.center_of(tile)
	var lim := Vector2(
		clampf(click.x, float(tile.x) + 1e-4, float(tile.x) + 1.0 - 1e-4),
		clampf(click.y, float(tile.y) + 1e-4, float(tile.y) + 1.0 - 1e-4)
	)

	# 主力方案：走到「本格内离点击最近的那个点」。
	# 为什么这样合法 —— 单位在格内自由走动，最后一步只是从相邻的可通行格跨进本格边缘，
	# **不会站在障碍里**；而 find_path 只被要求到相邻那格，所以路线照样成立。
	var region := reachable_tiles(map, buildings, cfg, from, faction)
	if region.has(map.terrain.idx(tile.x, tile.y)):
		# 本格自己就是可通行格（只是不在可达区域内）：按格内可通行部分投影
		var best: Variant = null
		var best_tile := tile
		for i in range(1, maxi(2, samples) + 1):
			var t := float(i) / float(maxi(2, samples))
			var p := center.lerp(lim, t)
			var pt := Vector2i(floori(p.x), floori(p.y))
			if not passable(map, buildings, cfg, pt.x, pt.y, faction):
				break
			best = p
			best_tile = pt
		if best != null:
			return {"pt": best, "tile": best_tile}

	# 本格完全不可通行（山 / 建筑）：找一条「从内侧跨进本格」的边。
	#
	# ⚠️ 这里从「按点击方向推两个候选」改成了「把所有方向的邻居都试一遍、
	#    取离出发点最近的」：八方向下推候选很容易漏掉合法的入射方向
	#    （斜着点一个山角时，内侧可能在对角而不是正交方向）。
	var best_c := Vector2i(-1, -1)
	var best_d := 0x7FFFFFFF
	for d in GridRes.DIRS8:
		var c := Vector2i(tile.x + d.x, tile.y + d.y)
		if not map.terrain.has(c.x, c.y):
			continue
		if not region.has(map.terrain.idx(c.x, c.y)):
			continue
		if not passable(map, buildings, cfg, c.x, c.y, faction):
			continue
		# 斜向入射同样要过对角守卫，否则会贴着障碍尖角钻进去
		if not diagonal_step_allowed(map, buildings, cfg, tile.x, tile.y, Vector2i(-d.x, -d.y), faction):
			continue
		var dist: int = absi(c.x - from.x) + absi(c.y - from.y)
		if dist < best_d:
			best_d = dist
			best_c = c
	if best_c.x >= 0:
		# 落点取本格内、贴着这一侧边界、且对着点击位置的点
		var p2 := Vector2(
			clampf(click.x, float(tile.x) + 1e-4, float(tile.x) + 1.0 - 1e-4),
			clampf(click.y, float(tile.y) + 1e-4, float(tile.y) + 1.0 - 1e-4)
		)
		if best_c.x < tile.x:
			p2.x = float(tile.x) + 1e-4
		elif best_c.x > tile.x:
			p2.x = float(tile.x) + 1.0 - 1e-4
		if best_c.y < tile.y:
			p2.y = float(tile.y) + 1e-4
		elif best_c.y > tile.y:
			p2.y = float(tile.y) + 1.0 - 1e-4
		# ⚠️ 寻路终点必须是那个**可通行的相邻格**，不是目标格本身
		return {"pt": p2, "tile": best_c}

	# 兜底：交给调用方的 nearest_reachable（往外扩圈找最近的可达格）
	return null


## 找出「挡住 from → to 这条路」的建筑（默认城墙）里，离 to 最近的那一个。
##
## 两个条件缺一不可：
##   1. 建筑必须挨着「from 这边真的走得到」的区域（否则拆了也过不去）；
##   2. 在候选里挑离 to 最近的 —— 这样拆穿一段后可达区域扩大，下一次自然接着往目标方向拆。
##
## 用途：敌人被城墙拦断时决定先拆哪一段。
## ⚠️ 旧实现是「在单位身边 2 格内找墙」，玩家用一整条墙拦断路线时根本找不到，敌人会发呆
##    （见 docs/pitfalls.md 3.3）。
##
## @return Building 或 null
static func find_blocking_wall_toward(map, buildings, cfg: ConfigRes, building_list: Array, from: Vector2i, to: Vector2i, faction: String, type: String = "wall") -> Variant:
	var region := reachable_tiles(map, buildings, cfg, from, faction)
	var best = null
	var best_d := 0x7FFFFFFF
	for b in building_list:
		if not b.alive or b.type != type:
			continue
		if FactionRes.same_side(b.owner, faction):
			continue
		var touches := false
		# 「挨着我的可达区域」用八方向判（斜着贴住的那一段墙同样值得拆）
		for d in GridRes.DIRS8:
			var nx: int = b.tx + d.x
			var ny: int = b.ty + d.y
			if not map.terrain.has(nx, ny):
				continue
			if region.has(map.terrain.idx(nx, ny)):
				touches = true
				break
		if not touches:
			continue
		# 挑「离目标最近」的那一段：用八方向距离，与寻路口径一致
		var dist: int = int(GridRes.octile_distance(b.tx - to.x, b.ty - to.y) * 10.0)
		if dist < best_d:
			best_d = dist
			best = b
	return best
