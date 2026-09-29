## general_ai.gd —— **将领性（防御性）AI**：附属在某个将领下的守将。
##
## 需求原文（逐条对照）：
##   1. 「该类 AI 会附属在某个将领下，其没有资源库，没有大本营」
##      → 状态全在**单位自己身上**（`garrison_zone_id` / `patrol_timer` /
##        `combat_idle_timer` / `garrison_recruit_timer`），不新建任何「AI 对象」，
##        也不碰 world.resources。它不生产、不建造、不升级 —— 缺的东西就没有，
##        不是「有但为 0」。
##   2. 「该类 AI 会有其归属的区划，且在其归属的区划中有时间间隔地巡逻」
##      → 归属写在 `unit.garrison_zone_id`（地图 `units[].zone` 或出生格）；
##        每 `ai.general.patrol_interval_sec` 秒朝**自己区划的中心**走一趟（往返巡逻）。
##   3. 「若其警戒到敌方单位会发动攻击，但不会追击超过一个区划」
##      → 交战本身交给 combat.gd（它已经有追击上限那一套）；本模块只补一条
##        **区划级**的硬约束：一旦脚踩进别人的区划（或离归属区划的中心太远），
##        当场脱战并走回去。见 `_out_of_garrison()`。
##        ★ 配套：脱战之后拉起 `unit.retarget_cd`（`ai.general.retarget_cooldown_sec`）——
##          没有它的话 combat.gd 下一帧就把同一个敌人再锁一次，表现为原地抖动。
##   4. 「该类 AI 在脱战（没有攻击行为 10 秒后）且不满员的情况下会无资源消耗地招募单位
##        （或者可以认定该类 AI 资源无限）」
##      → `combat_idle_timer` 连续 `ai.general.combat_idle_sec` 秒没有交战 → 调
##        `world.start_recruit(kind, id, faction, free = true)`：
##        不扣粮食 / 黄金 / 人口（复用招募那一整套读条与队列）。
##
## ★★ 为什么单独一个文件，而不是塞进 enemy_ai.gd：
##   enemy_ai 干的是**完全相反**的事（没有目标就朝玩家大本营推进，走不到就拆墙）。
##   两者判据互斥（本模块只管 `unit.is_garrison()`，enemy_ai 跳过它们），
##   混在一个文件里迟早会出现「守将也在往玩家家跑」这种自相矛盾的画面。
##
## ★ 每帧开销：只遍历 `world.units` 一次；重活儿（数附属兵、下单招募）
##   全部摊到几秒一次的计时器上（见 unit.retinue_size 的说明）。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##    见 docs/pitfalls.md 第五节）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")


## 每帧推进所有「驻防将领」。
##
## @param dt 本帧秒数。★ 必须由调用方传进来：world 上**没有** dt 字段，
##        而脱战计时 / 巡逻计时全靠它 —— 传 0 会让守将永远停在「刚脱战」那一帧。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if dt <= 0.0:
		return
	var gc: Dictionary = cfg.ai_general_cfg()
	var patrol_interval: float = float(gc["patrol_interval_sec"])
	var leash: float = float(gc["patrol_leash_tiles"])
	var idle_sec: float = float(gc["combat_idle_sec"])
	var retarget_cd: float = float(gc["retarget_cooldown_sec"])
	var recruit_check: float = float(gc["recruit_check_sec"])
	var min_retinue: int = int(gc["min_retinue"])
	var orders := 0

	for u in world.units:
		if not u.alive or not u.is_garrison():
			continue
		# ★ 招募读条期间将领被钉在原地（world._pin_training_leaders），
		#   这一段它的移动 / 战斗本来就被 world.tick 整段跳过 —— 这里也别再下命令，
		#   否则那条「走回区划中心」的路径会一直挂着，读条一完就冲出去。
		if u.is_training():
			continue

		var z: Variant = _garrison_zone(world, u)
		u.retarget_cd = maxf(0.0, u.retarget_cd - dt)

		# ---- 1) 区划级追击上限：追出自己那个区划了 → 当场脱战、走回去 ----
		#
		# ⚠️ 顺序：先判「该不该收队」，再更新脱战计时。
		#    反过来的话，「追出区划」那一帧会被记成「正在交战」，
		#    于是 IDLE 计时被清零、招兵要再等满一个 idle_sec。
		var in_combat: bool = u.target != null or u.target_building != null
		if in_combat and _out_of_garrison(world, u, z, leash):
			u.drop_engagement()
			in_combat = false
			# ★★ 拉起再战冷却：这是「不追出一个区划」能真正成立的**配套**。
			#    少了它，下一帧 combat.gd 会把同一个敌人再锁一次，于是
			#    「追出去 → 被叫回来 → 又追出去」原地抖（见 unit.retarget_cd 的说明）。
			u.retarget_cd = retarget_cd
			# 追出去了就立刻回去，不等巡逻计时（不然它会站在别人家里等着挨打）
			_patrol(world, cfg, u, z)
			u.patrol_timer = patrol_interval
			continue

		# ---- 1.5) 再战冷却期内：见到敌人也不接（把它刚锁上的那个放掉）----
		#
		# ⚠️ 这段必须在「脱战计时」**之前**：冷却期内被锁上的那一帧不该算「正在交战」，
		#    否则 IDLE 计时被反复清零，它永远招不了兵（冷却与招兵会互相饿死）。
		if in_combat and u.retarget_cd > 0.0:
			u.drop_engagement()
			in_combat = false

		# ---- 2) 脱战计时（有攻击行为的那一步清零）----
		#
		# ★ 判据用「手上有目标」而不是「这一帧真的开了火」：射程外追击目标的那些帧
		#   也算「还在打」—— 否则追到一半就会被判成脱战，站下来招兵（很难看）。
		#   ⚠️ 但 `moving` **不算**：巡逻本身就是移动，算进去的话永远脱不了战。
		if in_combat:
			u.combat_idle_timer = 0.0
		else:
			u.combat_idle_timer += dt

		# ---- 3) 正在打（单位或建筑）→ 这一帧交给 combat.gd，什么都不做 ----
		if in_combat:
			continue

		# ---- 4) 脱战：先看看要不要无消耗招兵，再巡逻 ----
		if u.combat_idle_timer >= idle_sec and min_retinue > 0:
			u.garrison_recruit_timer -= dt
			if u.garrison_recruit_timer <= 0.0:
				u.garrison_recruit_timer = recruit_check
				if orders < MAX_RECRUIT_ORDERS_PER_TICK and _try_recruit(world, u, min_retinue):
					orders += 1
					continue      # 刚下单：这一帧别再插一条巡逻命令（会把它顶掉）

		# ---- 5) 巡逻：按时间间隔朝自己区划的中心走一趟 ----
		u.patrol_timer -= dt
		if u.patrol_timer <= 0.0:
			u.patrol_timer = patrol_interval
			_patrol(world, cfg, u, z)


## 每次决策里最多下几条「招兵」指令（护栏）。
##
## ★ 为什么要有它：`world.start_recruit` 一单就占一个队列格子，而「不满员就招」
##   在**同一帧**里可能被满足很多次（队列里排着的人算满员，所以正常只下一单）——
##   但配置写错（min_retinue 远大于 queue_max）时它会每帧下一单，队列瞬间堆满。
##   一帧最多一条既能自愈，也让「为什么队列满了」在日志里看得出来。
const MAX_RECRUIT_ORDERS_PER_TICK := 1


## 这个驻防将领负责的区划字典（区划 id 找不到 / 地图换了 → null）。
static func _garrison_zone(world, u) -> Variant:
	if u.garrison_zone_id < 0 or world.zones == null:
		return null
	return world.zone_by_id(u.garrison_zone_id)


## 它现在算不算「追出自己那个区划了」。
##
## ★★ 主判据是**区划归属**（`zones.zone_at()` 给出另一个 id）：
##   需求原话就是「不会追击超过**一个区划**」，而区划形状是不规则的
##   （5×5 的 L 形、跨好几个 x 的矩形都有）—— 用直线距离去代替它一定会在某些形状上判错。
##
## ★ 距离判据（`ai.general.patrol_leash_tiles`）是**兜底**，只在一种情况下用：
##   脚下那一格**不属于任何区划**（`zone_at` 返回 null）—— 典型是区块与区块之间的空地、
##   地图外沿被 exists 挖掉的角落。那里主判据永远不成立，
##   没有兜底的话守将会一路追进无人区，直到撞上它的追击上限（aggro × leash_factor = 7.2 格）。
##
## ★ 归属区划 == null（区划被删 / id 写错）时**不做任何限制**：没有归属就没有
##   「不得超过一个区划」这条约束，硬判会让守将原地定住不动。
static func _out_of_garrison(world, u, z, leash: float) -> bool:
	if z == null:
		return false
	var here: Variant = world.zones.zone_at(u.tx, u.ty)
	if here != null:
		# 主判据：这一格有主，且不是我的那个区划
		return int((here as Dictionary)["id"]) != u.garrison_zone_id
	# 兜底：脚下是无主空地 → 只能按「离家多远」判
	var c: Variant = (z as Dictionary).get("center", null)
	if c == null:
		return false
	var center: Vector2 = GridRes.center_of(c)
	return u.pos.distance_to(center) > leash


## 巡逻一趟：朝**自己区划的中心**走。
##
## ★ 为什么是区划中心而不是「随机挑一格」：中心的语义是稳定的（地图作者指定的那个点），
##   而且它一定在区划里 —— 随机挑格会挑到区划边缘甚至别的区划里去。
## ★ 用 `order_move`（明确命令）而不是 `move_to`：需求要的是「巡逻」——
##   路上遇到敌人**不**主动迎战，靠警戒（静止时的索敌）接敌。这是刻意的：
##   真正的守将不该被路过的敌人牵着走。
## ★ 已经站在中心附近（半格内）就不下命令：否则每 4 秒重算一次路径，白费。
static func _patrol(world, cfg: ConfigRes, u, z) -> void:
	var tile: Vector2i = _patrol_tile(world, u, z)
	if tile.x < 0:
		return
	var pt: Vector2 = GridRes.center_of(tile)
	if u.pos.distance_to(pt) <= 0.5:
		return
	u.order_move(world, cfg, pt)


## 巡逻目标格：优先自己区划的中心，没有中心就退回「区划里第一个地块」。
## 区划整个找不到 → 退回大本营坐标（不然守将会因为没有目标而彻底不动）。
static func _patrol_tile(world, u, z) -> Vector2i:
	if z != null:
		var c: Variant = (z as Dictionary).get("center", null)
		if c != null:
			return c
		var tiles: Array = (z as Dictionary).get("tiles", [])
		if not tiles.is_empty():
			return tiles[0]
	return world.home_base_of(u.faction)


## 脱战满员检查 + 无消耗招兵。
##
## @return true = 这一帧真的下了一单（调用方据此跳过巡逻）
##
## ★★ `free = true`：这就是需求里那句「无资源消耗地招募单位（或者可以认定该类 AI 资源无限）」。
##   `world.start_recruit` 会因此**跳过全部计价**（粮食 / 黄金 / 人口都不扣），
##   但保留读条、队列上限、出生点那一整套规则 —— 「资源无限」不等于「瞬间出人」。
static func _try_recruit(world, u, min_retinue: int) -> bool:
	if u.retinue_size(world) >= min_retinue:
		return false
	if u.train_queue_size() >= world.recruit_queue_max():
		return false
	# 招什么兵：与这个守将自己同类型的兵（需求没指定兵种，跟随自己是唯一不武断的选法）。
	# ⚠️ 必须是**招募表里真的有的** kind，否则会被 world 以拒因 "kind" 挡掉并刷一条事件。
	var kind := String(u.unit_type)
	if not world.is_unit_recruitable(kind):
		# 守将的兵种不在招募表里（比如 "enemy"）→ 退回表里的第一条，
		# 免得「地图上摆的守将因为兵种没进招募表而永远补不了员」。
		var lst: Array = world.recruit_list()
		if lst.is_empty():
			return false
		kind = String((lst[0] as Dictionary).get("kind", ""))
		if kind == "":
			return false
	return world.start_recruit(kind, u.id, u.faction, true)
