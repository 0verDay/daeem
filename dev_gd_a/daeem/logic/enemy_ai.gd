## enemy_ai.gd —— 测试敌人的推进 AI（对应 HTML 版 main.js 的 updateEnemies / nearestPlayerBase）
##
## **本版按需求不做正式敌人**，这里只是调试面板刷出来的「测试敌人」，用来验证：
##   - 城墙只挡敌方（它会绕路，绕不过去就拆）
##   - 箭塔会打它、将领的警戒会迎战它
##   - 大本营被围住时它不会站在出生点发呆（这条踩过三个坑，见下）
##
## 行为：朝**最近的玩家大本营**推进；走到「能走到的最近处」就锁定挡路的城墙，
##       由 combat.gd 负责「先贴到墙边、再一下一下拆」。
##
## ★ 必须照抄的三条（都是 HTML 版真实踩过的坑，见 docs/pitfalls.md 3.2 / 3.3）：
##   1. `move_to()` 收的是**格坐标点**，而 A* 给的是**地块**坐标 —— 必须换算成格心，
##      否则单位会把地块坐标当成位置本身，朝地图左上角走；
##   2. `move_to()` **原地不动时也返回 true**，所以不能只看返回值判断「是不是已经到位了」
##      ——「到了就继续赶路」和「到了就找墙拆」必须分开判断，否则敌人站在墙边发呆；
##   3. 「该拆哪段墙」不能只在身边 2 格内找。要用 pathfinder.find_blocking_wall_toward()：
##      挨着**自己真的走得到**的区域 + 离目标最近。
extends RefCounted

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CombatRes = preload("res://logic/combat.gd")
const FactionRes = preload("res://logic/faction.gd")


## 每帧推进所有敌人
static func update(world, cfg: ConfigRes) -> void:
	for u in world.units:
		if not u.alive or u.faction != FactionRes.NPC_FACTION:
			continue
		# ★ 驻守单位：不参与「朝玩家据点推进」，原地待命（迎战由 combat.gd 负责）。
		#   地图预置的测试守军走这条；调试刷兵（E 键）默认不驻守，照旧推进。
		if u.hold_position:
			continue

		# 正在交战（警戒发现了我方单位）：交给 combat.gd 的攻击 / 追击逻辑
		if u.target != null:
			continue
		# 正在拆建筑（通常是挡路的城墙）：交给 combat.gd 的 update_building_combat
		if u.target_building != null:
			continue

		var goal_base = nearest_player_base(world, Vector2i(u.tx, u.ty))
		if goal_base == null:
			continue

		# 已经贴到据点、**而且没有墙挡着**就停下（本版不做近战拆家）。
		#
		# ⚠️ 这个 stop() 必须先确认「不欠着一段没拆的墙」。第一版把它写在拆墙判定**之前**，
		#    于是「大本营被墙围住」时 enemy_ai 每帧都先 stop() 把它按住，
		#    combat.update_building_combat 那一帧又 halt 一次 —— 两头一夹，
		#    敌人贴着墙站住、一下也不拆（症状和 HTML 版那个「站在墙边发呆」一模一样）。
		#
		# 这里用**切比雪夫**距离判「相邻」：`<= 1` 覆盖「四邻 + 对角」，
		# 也就是八方向下的「紧挨着」。
		# ⚠️ 原来写的是曼哈顿 `|dx|+|dy| <= 1`，而曼哈顿下对角是 2 ——
		#    于是「斜着贴住据点」的敌人进不了这个分支，会去 move_to 据点格心、往本体里挤；
		#    同一个据点，从正面来和从斜角来行为不一样（当时的注释还写着「覆盖对角」，是错的）。
		#    回归测试在 test_logic.gd 的「敌人停在大本营旁」那一条（判据也一并改成切比雪夫）。
		if maxi(absi(u.tx - goal_base.x), absi(u.ty - goal_base.y)) <= 1:
			var wall_here = PathfinderRes.find_blocking_wall_toward(
				world.map, world.buildings, cfg, world.building_list,
				Vector2i(u.tx, u.ty), goal_base, u.faction, "wall", world.crowd
			)
			if wall_here != null:
				CombatRes.set_building_target(u, wall_here)
				continue
			u.stop()
			continue
		if not u.path.is_empty():
			continue                      # 还在赶路

		# 按「敌方通行规则」寻路：城墙会阻挡，所以只能绕路或拆墙
		var goal = PathfinderRes.nearest_reachable(
			world.map, world.buildings, cfg, Vector2i(u.tx, u.ty), goal_base, u.faction, 12, world.crowd
		)
		if goal != null and (u.tx != goal.x or u.ty != goal.y):
			# ⚠️ move_to 收的是格坐标点，A* 给的是地块坐标：这里必须换算成格心
			var goal_pt: Vector2 = GridRes.center_of(goal)
			var moved: bool = u.move_to(world, cfg, goal_pt)
			if moved and u.moving:
				continue                  # 还在赶路

		# 已经站在「能走到的最近处」（典型情况：大本营被城墙围住，或路线被一整条墙拦断）
		# → 锁定挡路的城墙，由 combat.gd 负责「先靠近、再一下一下拆」。
		# ⚠️ 这里**不能**只看 move_to 的返回值：原地不动时它也返回 true
		#    （这曾经就是「敌人不拆墙、站在墙边发呆」的原因）
		var blocker = PathfinderRes.find_blocking_wall_toward(
			world.map, world.buildings, cfg, world.building_list,
			Vector2i(u.tx, u.ty), goal_base, u.faction, "wall", world.crowd
		)
		if blocker != null:
			CombatRes.set_building_target(u, blocker)


## 找出敌人该往哪个「玩家据点」推进：离它最近的玩家大本营。
##
## 单机下永远只有一个大本营（阵营 'player'）；联机下按距离挑最近的，
## 免得两个玩家时敌人只认死一个目标。
##
## ★ 只把**名单里的玩家阵营**的大本营算进去 —— 不能拿所有 base 一起比，
##   否则以后有中立/敌方基地时会朝它推进。
##
## @return Vector2i 或 null
static func nearest_player_base(world, from: Vector2i) -> Variant:
	var player_factions: Array = world.factions
	var best = null
	var best_d = 0x7FFFFFFF
	for b in world.building_list:
		if not b.alive or b.type != "base":
			continue
		if not player_factions.has(b.owner):
			continue
		# 用八方向距离（octile）挑最近的据点：与寻路的代价口径一致，
		# 否则会出现「地平线看着更近、实际走起来更远」的选目标偏差。
		# 乘 10 取整只是为了避免浮点比较，排序语义不变。
		var d: int = int(GridRes.octile_distance(b.tx - from.x, b.ty - from.y) * 10.0)
		if d < best_d:
			best_d = d
			best = Vector2i(b.tx, b.ty)
	if best != null:
		return best
	# 没有任何玩家大本营时退回本地大本营坐标（不该发生，但别让它崩）
	return world.home_base_of(FactionRes.DEFAULT_FACTION)
