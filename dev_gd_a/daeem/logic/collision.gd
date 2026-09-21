## collision.gd —— 单位之间的碰撞与局部避让（软分离 + 谁给谁让路）
##
## ★★ 为什么**不**把单位写进寻路（这是本文件存在的全部理由）
##   如果把「别的单位占着这一格」当成 A* 的障碍或代价：
##     · 两队兵会互相把对方判成墙 → 双方都认为无路可走 → 死锁；
##     · 单位每动一格路径就过期 → 要么每帧重寻路，要么走一条已经失效的路线。
##   SC2 的取舍是：**寻路只看地形与建筑，单位之间靠局部推挤解决**。
##   本文件就是那个「局部」。所以 `pathfinder` 至今不认识单位，那不是漏了，是故意的。
##
## ★ 做法（每帧 tick 末尾跑一次，见 world.tick 第 8.5 步）：
##   1. 两两查重叠（单位是圆）；
##   2. 重叠超过 slack 就沿圆心连线各推开一部分 —— 分多少由**权重**决定；
##   3. 推开后的位置必须仍然「站得住」（山 / 不能穿的建筑），推不动就**沿墙滑动**；
##   4. 反复几轮（iterations），消掉三四个单位的连锁重叠。
##
## ★★ 权重就是「谁给谁让路」（手玩反馈定的规则）：
##   **有移动命令的单位推得动待命的单位**，反过来推不动。
##   没有这条，队首堵在窄口时后面全体卡死 —— 谁都等对方先让。
##
## ⚠️ 联机影响（第 1 轮）：推挤改的是**位置**，而位置是权威状态，
##    所以它必须跑在房主侧。客机只收快照（位置本来就在快照里），不需要也不该跑这个。
extends RefCounted

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")


## 碰撞半径（格）。单位很小（直径只占格宽 20% 的量级）是刻意的，见 config 里的说明。
##
## ★ 读的是 cfg 上载入时算好的字段：这个函数在 `_can_stand()` 里**每次尝试推挤**都会调一次，
##   而 num("unit.collision_radius") 每次都要 split(".") + 逐层下潜。
static func radius(cfg: ConfigRes) -> float:
	return maxf(0.0, cfg.unit_collision_radius)


## 一帧里推进一次碰撞消解。
##
## @return Dictionary {"pairs": 参与过推挤的对数, "pushed": 真的动过的单位数}
##   （只用于测试与调试，逻辑上不需要返回值）
static func resolve(world, cfg: ConfigRes) -> Dictionary:
	var stats := {"pairs": 0, "pushed": 0}
	if not cfg.unit_collision_enabled:
		return stats

	var r := radius(cfg)
	if r <= 0.0:
		return stats

	var allowance: float = clampf(cfg.unit_overlap_allowance, 0.0, 1.0)
	var iterations: int = maxi(1, cfg.unit_collision_iterations)
	var slack: float = maxf(0.0, cfg.unit_collision_slack)
	var moved: Dictionary = {}

	for _it in iterations:
		var any := false
		var n: int = world.units.size()
		for i in n:
			var a = world.units[i]
			if not a.alive:
				continue
			for j in range(i + 1, n):
				var b = world.units[j]
				if not b.alive:
					continue
				if _separate(world, cfg, a, b, r, allowance, slack):
					any = true
					stats["pairs"] += 1
					moved[a.id] = true
					moved[b.id] = true
		if not any:
			break                        # 没有重叠了，提前收工
	stats["pushed"] = moved.size()
	return stats


## 把一对重叠的单位分开。返回是否真的动了。
static func _separate(world, cfg: ConfigRes, a, b, r: float, allowance: float, slack: float) -> bool:
	var delta: Vector2 = b.pos - a.pos
	var d := delta.length()
	# 允许的重叠：圆心最小距离 = (ra + rb) × allowance
	var min_dist: float = r * 2.0 * allowance
	if d >= min_dist - slack:
		return false
	var overlap: float = min_dist - d

	# 圆心完全重合时没有方向可用 —— 随便挑一个固定方向（避免 ÷0 与抖动）
	var dir := Vector2.RIGHT
	if d > 1e-6:
		dir = delta / d

	# ★ 谁给谁让路：有移动命令的一方推得动待命的一方
	var wa: float = _weight(cfg, a)
	var wb: float = _weight(cfg, b)
	var total := wa + wb
	if total <= 1e-6:
		# 两边权重都是 0（配置写错了）——退回各推一半，别让这条规则静默失效
		wa = 1.0
		wb = 1.0
		total = 2.0

	# 权重越大承担越少：把 overlap 反比分配
	var move_a: Vector2 = -dir * (overlap * (wb / total))
	var move_b: Vector2 = dir * (overlap * (wa / total))

	# 分开施加：能站住就直接推，站不住就沿墙滑动
	# ⚠️ 两次尝试都要基于各自**当前**的位置算，不能先算好再一起写
	var a_moved := _try_move(world, cfg, a, move_a)
	var b_moved := _try_move(world, cfg, b, move_b)
	return a_moved or b_moved


## 推挤权重：有移动命令（正在执行路径）的单位 = push_moving_weight，
## 待命（没命令 / 已到达）的单位 = push_idle_weight。
##
## ★ settling 的单位算「有命令」：它虽然已经到达落点，但那个落点是**因为拥挤才就近选的**，
##   所以它仍然有权对抗推挤。判成待命的话它会被人群无限推着走 ——
##   实测那正是「到达后一直挤着转」停不下来的原因之一。
static func _weight(cfg: ConfigRes, u) -> float:
	if u.settling:
		return maxf(0.0, cfg.unit_push_moving_weight)
	# 「有命令」= 还在赶路。仅 has_goal 不算：已经到位但没清 goal 的单位应当算待命。
	if u.moving and not u.path.is_empty():
		return maxf(0.0, cfg.unit_push_moving_weight)
	return maxf(0.0, cfg.unit_push_idle_weight)


## 尝试把单位推走 move 这个位移。
##
## ★ 推挤**不能**把单位推进山 / 敌方城墙里（那会直接破坏「城墙挡人」这条规则）。
##   推不动时退一步沿墙滑动（只保留一个轴），这是最省事又够用的做法。
static func _try_move(world, cfg: ConfigRes, u, move: Vector2) -> bool:
	if move.length_squared() <= 1e-12:
		return false
	if _can_stand(world, cfg, u, u.pos + move):
		u.pos += move
		u.sync_tile(world.map)
		# ⚠️ 推挤不碰 path / moving / goal：那是「意图」，这里只改「位置」。
		#    （把意图也改掉会让被推的单位忘掉自己要去哪 —— 表现为“被撞一下就发呆”）
		return true
	# 沿墙滑动：分别试两个轴
	var slide_x := Vector2(move.x, 0.0)
	if absf(move.x) > 1e-9 and _can_stand(world, cfg, u, u.pos + slide_x):
		u.pos += slide_x
		u.sync_tile(world.map)
		return true
	var slide_y := Vector2(0.0, move.y)
	if absf(move.y) > 1e-9 and _can_stand(world, cfg, u, u.pos + slide_y):
		u.pos += slide_y
		u.sync_tile(world.map)
		return true
	return false


## 这个位置站得住吗：在地图内、地形可通行、建筑对自己的阵营不阻挡（格级 + 本体级）。
## 这里**故意用 passable()**（而不是「不能有建筑」）：城墙对己方是放行的，
## 所以己方单位被挤到自家城墙那一格上是被允许的 —— 否则自家城门处会堵成一团。
## ★ 本体级另算：大本营 / 箭塔的格子对敌方是「格级放行」的，但本体不能站进去。
static func _can_stand(world, cfg: ConfigRes, u, p: Vector2) -> bool:
	var t := Vector2i(floori(p.x), floori(p.y))
	if not world.map.terrain.has(t.x, t.y):
		return false
	if not PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, u.faction):
		return false
	return not body_blocked_at(world, cfg, u.faction, p, radius(cfg))


## 某个点（格坐标）是否落在「挡这个阵营」的建筑本体里（含单位半径 r 的间隙）。
##
## ★ 扫 3×3 邻格而不是只看自己那一格：本体虽然在自己的格子里，
##   但「本体 + 单位半径」的外扩区可能跨过格线（body_scale 越小越明显）。
static func body_blocked_at(world, cfg: ConfigRes, faction: String, p: Vector2, r: float = 0.0) -> bool:
	var t := Vector2i(floori(p.x), floori(p.y))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var b = world.building_at(t.x + dx, t.y + dy)
			if b == null or not b.alive:
				continue
			if not b.body_blocks(faction):
				continue
			if b.body_rect(cfg).grow(maxf(0.0, r)).has_point(p):
				return true
	return false


# ------------------------------------------------------------------
# 「强制生成在某一点」：先把那一点上的单位排开
#
# ★ 谁在用：招募读条完成时，新兵**强制生成在将领所在格的格心**（用户需求）。
#   格心上可能正站着别人（将领／亲兵／敌人），所以要先请他们让开 ——
#   不然新兵一出生就和人叠在一起，只能等这一帧末尾的软分离慢慢挤开。
# ★ 与软分离的区别：软分离是「两边各让一点」，这里是**单方面让开**（新兵不让）。
# ------------------------------------------------------------------

## 把一个点周围 `need` 距离内的单位推开（`except` 不动，通常是刚出生的那个）。
## @return 真的挪动过的单位数（只用于调试 / 断言）
static func clear_point(world, cfg: ConfigRes, p: Vector2, need: float, except = null) -> int:
	if need <= 0.0:
		return 0
	var moved := 0
	for k in world.units.size():
		var u = world.units[k]
		if u == except or not u.alive:
			continue
		var delta: Vector2 = u.pos - p
		var d := delta.length()
		if d >= need:
			continue
		# 完全重合时没有方向可用：按序号从八方向里挑一个（确定性，不抖动）
		var dir := Vector2.RIGHT
		if d > 1e-6:
			dir = delta / d
		else:
			dir = Vector2(GridRes.DIRS8[k % GridRes.DIRS8.size()])
		# 推的距离要**刚好推到不重叠**再多一点（PUSH_EPS 见下：边界是含端点的）
		if _try_move(world, cfg, u, dir * (need - d + PUSH_EPS)):
			moved += 1
			continue
		# 推不动（贴着山 / 墙）→ 在格心周围找一格站得住的落脚点
		if _snap_near(world, cfg, u, p, need):
			moved += 1
	return moved


## 推不动时的兜底：在 p 所在的格周围（含斜角）找一格「站得住」的位置搬过去。
## 只改 pos 与 tx/ty —— 与推挤一样，**不碰** path / moving / goal（见文件头第 3 条）。
static func _snap_near(world, cfg: ConfigRes, u, p: Vector2, need: float) -> bool:
	var t := Vector2i(floori(p.x), floori(p.y))
	for ring in range(1, 4):
		for d in GridRes.DIRS8:
			var c := Vector2i(t.x + d.x * ring, t.y + d.y * ring)
			var cand := GridRes.center_of(c)
			if cand.distance_to(p) < need:
				continue
			if not _can_stand(world, cfg, u, cand):
				continue
			u.pos = cand
			u.sync_tile(world.map)
			return true
	return false


# ------------------------------------------------------------------
# 建筑本体：把单位从本体里推出来（大本营 / 箭塔不再整格挡人之后的「本体阻挡」）
#
# ★ 为什么单独一步而不是并进单位的推挤里：
#     单位-单位是「谁给谁让路」的软分离；本体是**不动的硬障碍**，语义不同。
#     分开写之后，这边可以安静地被关掉/调参，也不会污染那套权重规则。
# ★ 只推「本体挡它」的阵营：己方单位可以站在大本营本体上（需求：本体不阻挡己方）。
# ------------------------------------------------------------------

## @return Dictionary {"pushed": 被推出的单位数}
static func resolve_buildings(world, cfg: ConfigRes) -> Dictionary:
	var stats := {"pushed": 0}
	if not cfg.unit_collision_enabled:
		return stats
	var r := radius(cfg)
	var iterations: int = maxi(1, cfg.unit_collision_iterations)

	for _it in iterations:
		var any := false
		for u in world.units:
			if not u.alive:
				continue
			var push := _nearest_body_push_out(world, cfg, u, r)
			if push.length_squared() <= 0.0:
				continue
			if _try_move(world, cfg, u, push):
				any = true
				stats["pushed"] += 1
		if not any:
			break
	return stats


## 单位当前位置若与某个「挡它的」本体重叠，返回把它推到最近空处的位移。
## 同时压着两块本体时，只挑**穿透最深**的那块推 —— 推完下一轮循环会继续处理另一块
## （iterations 通常有 3 轮，够用；一次推两块会互相抵消）。
static func _nearest_body_push_out(world, cfg: ConfigRes, u, r: float) -> Vector2:
	var t := Vector2i(floori(u.pos.x), floori(u.pos.y))
	var best := Vector2.ZERO
	var deepest := 0.0
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var b = world.building_at(t.x + dx, t.y + dy)
			if b == null or not b.alive:
				continue
			if not b.body_blocks(u.faction):
				continue
			var push := _body_push_out(b.body_rect(cfg), u.pos, r)
			var depth := push.length()
			if depth > deepest + 1e-9:
				deepest = depth
				best = push
	return best


## 算出「把半径 r 的圆心从本体里推到最近的空处」所需的位移。
## 圆心已经在本体之外（含 r 的间隙）时返回零向量。
##
## 做法：把本体按 r 外扩，圆心在外扩矩形外就没事；在里面就沿**穿透最浅的那个轴**推出去。
##
## ★★ 推出去时要**多推一个 EPS**：只推到边界上的话，圆心正好落在
##    `zone.position.x`（或 `.end.x`）上 —— 而 `Rect2.has_point()` 是**含边界**的，
##    于是「推完了却仍然被判成挡着」，`_can_stand()` 一看目标点不合法就拒绝这次位移。
##    实测症状：敌人被塞进大本营本体里之后**一步也推不出去**（pushed = 0）——
##    换地图后暴露出来的（老地图上恰好没被这条路径撞到）。
##    EPS 取 1e-6 格（= 0.000064 px），远小于任何视觉/手感阈值。
const PUSH_EPS := 1e-6


static func _body_push_out(body: Rect2, p: Vector2, r: float) -> Vector2:
	var zone := body.grow(r)
	if not zone.has_point(p):
		return Vector2.ZERO
	var left: float = p.x - zone.position.x
	var right: float = zone.end.x - p.x
	var top: float = p.y - zone.position.y
	var bottom: float = zone.end.y - p.y
	var m: float = minf(minf(left, right), minf(top, bottom))
	# ⚠️ 四个分支都要带 PUSH_EPS（见上面那段：不加会把圆心留在边界上）
	if m == left:
		return Vector2(-(left + PUSH_EPS), 0.0)
	if m == right:
		return Vector2(right + PUSH_EPS, 0.0)
	if m == top:
		return Vector2(0.0, -(top + PUSH_EPS))
	return Vector2(0.0, bottom + PUSH_EPS)
