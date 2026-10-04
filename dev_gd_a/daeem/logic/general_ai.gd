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
## 挑巡逻路线上的点时要用它判「这一格能不能站人」（与出生点 / 招募共用同一套判据）。
const PathfinderRes = preload("res://logic/pathfinder.gd")
## ★★ 巡逻的**整队命令**走它（`order_group_attack_move`）—— 与玩家 / 阵营 AI 同一条路径，
##    队形落点与通行判定都在里面，见 `_patrol_group`。
const CommandProcessorRes = preload("res://logic/command_processor.gd")


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

	# ★★ 每个区划里有几位「要巡逻的将领」（= 巡逻队长；见 `is_patrol_leader`）。
	#
	# 为什么要先统计一遍：巡逻路线要**按区划切成几块**（`zone_count` 是切几段），
	#   而那个数必须在**同一帧里对同一区划的每个人都一致** —— 边遍历边算的话，
	#   先被访问到的那个拿到的是「还没数完」的数。
	#   ★ 至于「我分到第几段」——由 `_sector_of()` 按 **id** 稳定派生，不是遍历序号。
	# ⚠️ 只数「活着 + 有归属区划 + 自己带队」的：附属兵**不算**（它们跟着队长走，
	#    各算一个的话「同一个区划里几个队长」这个数会虚高、扇区被切得太碎）。
	# ⚠️ 正在招兵的那些**不算**（它们这一帧不巡逻，算进去会让别人的下标跟着跳）。
	var patrol_counts: Dictionary = {}
	for u2 in world.units:
		if not u2.alive or int(u2.garrison_zone_id) < 0:
			continue
		# ★ 濒死者不算「这一帧要巡逻的队长」（本轮新增）：它倒在原地，
		#   算进去会让同一区划里**别人**分到的扇区跟着变（路线随人数切分）。
		if u2.is_downed():
			continue
		if not is_patrol_leader(world, u2):
			continue
		var zid2 := int(u2.garrison_zone_id)
		patrol_counts[zid2] = int(patrol_counts.get(zid2, 0)) + 1

	for u in world.units:
		if not u.alive or not u.is_garrison():
			continue
		# ★★ 附属兵**不走这一套**：它们不是「守将」，而是队长手下的兵 ——
		#    队长的巡逻命令会把整队带上（见 `_patrol_leader` 的 `_patrol_group`）。
		#    ⚠️ 少了这一条就是手玩报的那个 bug：「将领会巡逻，但将领招募出来的
		#       单位不会巡逻」—— 每个兵各算一个巡逻队长时，它们要么站着不动
		#       （没有路线可用），要么各走各的（一支小队散成四个人）。
		if not is_patrol_leader(world, u):
			continue
		# ★ 这一方在自己区划里排第几个**不看**（扇区由 `_sector_of()` 按 id 稳定派生）——
		#   只有「这个区划里有几位要巡逻」这一个数会影响切分。
		var zid_self := int(u.garrison_zone_id)
		var zone_count := int(patrol_counts.get(zid_self, 1))
		# ★ 招募读条期间将领被钉在原地（world._pin_training_leaders），
		#   这一段它的移动 / 战斗本来就被 world.tick 整段跳过 —— 这里也别再下命令，
		#   否则那条「走回区划中心」的路径会一直挂着，读条一完就冲出去。
		if u.is_training():
			continue
		# ★★ 濒死的驻防将领**这一帧什么都不做**（本轮新增）：需求是「倒在原地」——
		#    不能巡逻、不能接战、也不该把整队带向某个巡逻点。
		#    ⚠️ 这一条必须**早于**下面那些「脱战 / 收队 / 招兵」的判定：
		#      它现在没有交战目标（濒死时 stop() 清过了），往下走也不会有副作用，
		#      但「走到这里」本身就意味着这一帧会去碰它的命令队列 —— 不值得。
		#    ★ 它辖下的部队**不受影响**：救它那支行军命令是 `world.enter_near_death`
		#      下的（它们正朝倒下点走），而 `_catch_up_retinue` 那类「叫回来巡逻」
		#      的逻辑不该把援军又拽走。
		if u.is_downed():
			continue

		var z: Variant = _garrison_zone(world, u)
		u.retarget_cd = maxf(0.0, u.retarget_cd - dt)
		# ★★ 冷却结束 = 返程这一段也结束了（见下面「回家」那一支与 `returning_home`）
		if u.retarget_cd <= 0.0:
			u.returning_home = false

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
			# ★★ 返程**只下一道命令**（本轮修 bug）：实测报回来的「卡边界时还是会抽搐」
			#    就是这里——原来每一帧命中这一支都会重下一条「回巡逻点」的命令，
			#    而巡逻路线上的下一个点还会被 `_next_patrol_tile` 换掉 ⇒
			#    路径每帧重置、人永远走不回家，看着就是在区划边缘原地抽。
			#    ⇒ 只在**还没上路**时下这一道；走到了（或冷却结束）由下面第 5 步接手。
			if not u.returning_home:
				u.returning_home = true
				_patrol_leader(world, cfg, u, z, zone_count)
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

		# ---- 5) 巡逻：按时间间隔朝**自己路线的下一个点**走 ----
		# ★★ 正在回家的路上（`returning_home`）：**不再插新的巡逻命令** ——
		#    那会把返程路径顶掉，于是它一步都走不回去（本轮修的「卡边界抽搐」）。
		#    等它走到（见 `_patrol_leader` 末尾的到达判定）或冷却结束（上面那句）再恢复。
		if u.returning_home:
			continue
		u.patrol_timer -= dt
		if u.patrol_timer <= 0.0:
			u.patrol_timer = patrol_interval
			_patrol_leader(world, cfg, u, z, zone_count)


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


## ★★ 这个单位是不是一位「**巡逻队长**」（= 该自己带队巡逻的那个）。
##
## 判据两条：
##   1. 有归属区划（`is_garrison()`）；
##   2. **自己带队**：没有队长，或者队长已经不在了（阵亡 / 被清场）。
##
## ★★ 为什么要这一条（手玩报的 bug）：将领性 AI 原先的循环是「所有 `is_garrison()`
##   的单位各自巡逻」—— 而将领**招出来的兵**只要跟着沾上归属区划，就会各算一个
##   巡逻队长：它们要么因为路线算不出来而站着不动，要么四个人朝四个方向走，
##   一支小队散成一盘沙。正确的模型是「**一个队长带队**，兵跟着队长的命令走」。
##
## ★ 队长阵亡之后**不**让那一队站死：`world.team_leader()` 查不到队长 ⇒ 剩下的兵
##   自己接手巡逻（那一块地照样有人守）。
static func is_patrol_leader(world, u) -> bool:
	if u == null or not u.alive:
		return false
	# ★ 濒死的将领不是「这一块的巡逻队长」（本轮新增）：它倒在原地，
	#   而「队长」这个身份是用来派巡逻命令的（见 `_patrol_leader`）。
	#   ⚠️ 于是它辖下的部队会**自己接手**巡逻（它们的 `team_leader()` 仍然返回这个
	#      倒下的将领 —— 濒死是 alive 的，所以这里必须显式挡一下，不能靠 team_leader）。
	if u.is_downed():
		return false
	if int(u.garrison_zone_id) < 0:
		return false
	return world.team_leader(u) == null


## 巡逻一趟：**整队**（队长 + 辖下附属兵）朝自己路线的下一个点走。
##
## ★★ 这一版（docs/route.md 39.2）把「只有将领一个人走」改成**整队一起走**：
##   命令走 `CommandProcessorRes.order_group_attack_move` —— 与玩家「选中整队再点地图」
##   和阵营 AI「派一批将领出征」是**同一条**路径（队形落点、避开障碍都由它保证），
##   所以不会出现「将领在前面走、兵在后面杵着」。
##   ⚠️ 之前只调 `u.order_move()`：那是**单个单位**的命令，附属兵根本收不到。
##
## ★ 路线仍是每位队长一条（`patrol_points` 个点，由 `_ensure_route()` 用
##   **单位 id 派生的固定种子**在自己的归属区划里挑出来），走到尽头折返。
## ★ 为什么用行军攻击（attack move）而不是普通移动：巡逻中的守军**路上遇敌要打**
##   （需求里「警戒到敌人会发动攻击」那条），而行军攻击正好是「边走边打」；
##   普通移动是「明确命令、遇敌不停」，用在守军身上会变成被路过的敌人白打一顿。
## ★ 已经站在目标点附近（半格内）就**直接跳到下一个点**：否则每几秒重算一次路径，白费。
##
## @param zone_count 同一区划里**要巡逻的队长总数**（用来把区划切成几个扇区）
static func _patrol_leader(world, cfg: ConfigRes, u, z, zone_count: int) -> void:
	var tile: Vector2i = _next_patrol_tile(world, cfg, u, z, zone_count)
	if tile.x < 0:
		# ★ 算不出巡逻点（区划被删 / 数据坏了）⇒ 返程也算结束，否则这个标志会
		#   一直挂着、第 5 步永远不巡逻（人就定死在原地了）。
		u.returning_home = false
		return
	var pt: Vector2 = GridRes.center_of(tile)
	if u.pos.distance_to(pt) > 0.5:
		_patrol_group(world, cfg, u, pt)
	# ★★ 即使队长**已经站在**这个点上（这一趟不挪窝），也要检查一次队里有没有人掉队：
	#    「队长到了、兵还落在后面」正是最常见的掉队形态，只在队长移动时才检查的话
	#    那几个人会一直站在半路（它们没有新命令，旧的 goal 早就到了）。
	_catch_up_retinue(world, cfg, u, pt)
	# ★★ 返程走到头了（本轮修 bug，见 `unit.returning_home`）：
	#    队长已经站在这一趟的目标点上 ⇒ 这一段「回家」结束，恢复正常巡逻节奏。
	#    ⚠️ 阈值必须**不小于**上面判「要不要下命令」的那个 0.5 —— 否则会出现
	#      「下了命令、下一帧又判成到了」的循环。这里取 0.75，且只在真的停住时清。
	#    ⚠️ 不断言「路径已空」：被挤住（人群 / 窄口）时路径可能还在，但它已经站住了。
	if u.returning_home and not u.moving and u.pos.distance_to(pt) <= 0.75:
		u.returning_home = false


## 让**整队**朝 `pt` 走（队长 + 它辖下活着的附属兵）。
##
## ★ 队形槽位由命令层算：`group.size() >= unit.formation.min_units`（默认 4）时排阵，
##   否则逐个下 —— 「一个将领 + 3 个兵」正好是 4 个，所以默认就会排开，
##   不会四个人挤在同一个格子上。
static func _patrol_group(world, cfg: ConfigRes, u, pt: Vector2) -> void:
	var group: Array = [u]
	for m in _retinue_of(world, u):
		group.append(m)
	# ⚠️ 用命令层那一条（而不是自己写循环调 order_move）：
	#    队形 / 落点挑选 / 通行判定全在它里面，抄一份出来迟早会漂开。
	if not CommandProcessorRes.order_group_attack_move(world, cfg, group, pt):
		# 兜底：命令层整队那条失败（理论上到不了）时，至少别让队长站着不动。
		u.order_attack_move(world, cfg, pt)


## 队里有没有人掉队 —— 有就重新下一次整队命令（把它们叫上）。
##
## ★★ 为什么需要它：巡逻是**一步一个命令**的，命令只在「队长走到某个点那一帧」下。
##   路上要是有人被地形卡住、被别人挤开、或者去追了一下路过的敌人，
##   它就会**永远**停在那儿（它自己的目标早就到了，没有任何新命令会再来）。
##
## ★ 判据两条，**都成立**才算掉队（这是为了不打断正在赶路的兵）：
##   1. 离队长超过 `patrol_retinue_leash_tiles` 格（默认 3 —— 队形槽位本身就有
##      一格间距，卡太紧会让每一步都重下一遍命令、整队一直在互相挤）；
##   2. 它**没有在朝目标走**（停着，或者动了半天离自己的目标还是那么远）。
##      ⚠️ 少了第 2 条就会「把一个正在努力爬山的兵每秒打断一次」——
##      重新下命令会把它的路径重算一遍，反而更慢。
## ★ 只对**附属兵**做这件事：队长自己的位置由路线决定，不需要被谁叫。
static func _catch_up_retinue(world, cfg: ConfigRes, u, pt: Vector2) -> void:
	var gc: Dictionary = cfg.ai_general_cfg()
	var leash: float = float(gc.get("patrol_retinue_leash_tiles", 3.0))
	var missing := false
	for m in _retinue_of(world, u):
		if m.pos.distance_to(u.pos) <= leash:
			continue
		if not m.moving or m.path.is_empty() or m.pos.distance_to(m.goal) >= m.best_dist:
			# 停着 / 没有路径 / 走了半天离目标还是那么远 ⇒ 它到不了，重新叫一次
			missing = true
			break
	if missing:
		_patrol_group(world, cfg, u, pt)


## 某位队长**还活着**的附属兵（`world.retinue_of` 的薄封装，只为少写一遍 id 转换）。
static func _retinue_of(world, u) -> Array:
	return world.retinue_of(String(u.id))


## 下一个巡逻点（网格坐标；`x < 0` = 这一帧没有可去的点）。
##
## ⚠️ 顺序：先确保路线存在 → 看当前那个点到了没 → 到了就推进下标（折返）→ 返回那个点。
static func _next_patrol_tile(world, cfg: ConfigRes, u, z, zone_count: int) -> Vector2i:
	_ensure_route(world, cfg, u, z, zone_count)
	if u.patrol_points.is_empty():
		return _patrol_fallback_tile(world, u, z)
	var tile: Vector2i = u.patrol_points[clampi(u.patrol_index, 0, u.patrol_points.size() - 1)]
	# 已经到了 → 换下一个（走到底就折返，而不是从第一个重来：那样会在两端"瞬移"）
	if u.pos.distance_to(GridRes.center_of(tile)) <= 0.5:
		_advance_patrol_index(u)
		tile = u.patrol_points[clampi(u.patrol_index, 0, u.patrol_points.size() - 1)]
	return tile


## 把巡逻下标推进一格；到头折返。
static func _advance_patrol_index(u) -> void:
	if u.patrol_points.size() <= 1:
		u.patrol_index = 0
		u.patrol_dir = 1
		return
	var nxt: int = int(u.patrol_index) + int(u.patrol_dir)
	if nxt < 0 or nxt >= u.patrol_points.size():
		u.patrol_dir = -int(u.patrol_dir)
		nxt = int(u.patrol_index) + int(u.patrol_dir)
	u.patrol_index = clampi(nxt, 0, u.patrol_points.size() - 1)


## ★★ 这位守将的巡逻路线：**没算过、或换了区划**时算一次，之后一直复用。
##
## 判据用 `patrol_zone_id`（路线是给哪个区划算的）：-2 = 从没算过。
## ⚠️ 路线存在**单位自己身上**（`unit.patrol_points`），不进快照 ——
##   客机不跑 AI，也用不到它（与 `patrol_timer` 那些一样是权威侧的状态）。
static func _ensure_route(world, cfg: ConfigRes, u, z, zone_count: int) -> void:
	if u.patrol_zone_id == u.garrison_zone_id and not u.patrol_points.is_empty():
		return
	u.patrol_zone_id = u.garrison_zone_id
	u.patrol_points = _build_route(world, cfg, u, z, zone_count)
	u.patrol_index = 0
	u.patrol_dir = 1


## 在某位守将的**归属区划**里挑 `patrol_points` 个能站人的点。
##
## ★★ 做法（两层「分开」）：
##   1. **按人切扇区**：把区划的地块列表切成 `zone_count` 段，这位守将只在自己那一段里挑点
##      —— 于是同一区划的几位守将**各占一块**（不会几个人都围着中心转，实测那会互相重叠）。
##      ⚠️ 分到第几段由 `_sector_of()` **按 id 稳定派生**（不是遍历序号）；
##   2. **段内随机**：在自己那一段里用**由单位 id 派生的固定种子**随机挑锚点，再在
##      `patrol_spread_tiles` 格内挑其余的点 —— 于是路线看起来是乱的、不是整齐划一。
##
## ⚠️ 一格都挑不出来（扇区里全是山地 / 建筑）→ 退回**整个区划**再挑一次；
##    再挑不出来就返回空数组，调用方退回老口径（区划中心 / 大本营）。
static func _build_route(world, cfg: ConfigRes, u, z, zone_count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if z == null or world == null:
		return out
	var tiles: Array = (z as Dictionary).get("tiles", [])
	if tiles.is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = _route_seed(String(u.id), String(u.faction))
	var want: int = maxi(1, int(cfg.ai_general_cfg().get("patrol_points", 3)))
	var spread: float = maxf(1.0, float(cfg.ai_general_cfg().get("patrol_spread_tiles", 3.0)))

	# 1) 先在自己那个扇区里挑（扇区序号由 **id 稳定派生**，见下）
	var slice: Array = _sector_tiles(tiles, zone_count, _sector_of(u, zone_count))
	if not slice.is_empty():
		out = _pick_points(world, cfg, u, slice, rng, want, spread)
	# 2) 扇区里挑不出来（全是障碍 / 扇区太小）→ 退回整个区划挑一次，
	#    免得那位守将彻底不巡逻（它是「有归属区划但不走」的静默失败）
	if out.is_empty():
		out = _pick_points(world, cfg, u, tiles, rng, want, spread)
	return out


## ★★ 这位守将分到第几个扇区：**由单位 id 稳定派生**，不看「它是第几个被遍历到的」。
##
## ⚠️⚠️ 为什么不能用遍历序号（实测踩到）：路线的确定性是**硬要求**（存档 / 回放），
##   而遍历序号会随着「别人死没死 / 有没有在招兵 / 集合顺序」变化 ——
##   同一个单位重算一次就可能换到另一个扇区，于是「同 id ⇒ 同路线」不成立。
##   改成 id 派生之后：**同一个单位永远在自己那块地里巡逻**，
##   不管同区划里还有几个人、也不管谁先被访问。
##
## ★ 不同的 id 会散到不同扇区（`_route_seed` 是稳定哈希）；万一两个人撞进同一扇区，
##   它们仍然会因为**种子不同**而走出不同的路线（只是地盘重叠，不会并排走）。
static func _sector_of(u, zone_count: int) -> int:
	if zone_count <= 1:
		return 0
	return _route_seed(String(u.id), String(u.faction)) % zone_count


## 把区划的地块切成 `count` 段，返回第 `index` 段。
##
## ⚠️ **不排序**：直接按原顺序切片 —— 地图的 `tiles` 顺序是按行扫出来的
##   （`zone_list[].tiles` 由生成器逐行 append），所以天然连续；
##   排一次序反而会让「同一段」散成好几片（区划是矩形时也一样连续，但没必要冒险）。
## ⚠️ 段大小至少 1（地块数比守将数还少时，后面的守将会拿到空段 → 由调用方退回全区划）。
static func _sector_tiles(tiles: Array, count: int, index: int) -> Array:
	var n: int = tiles.size()
	if count <= 1 or n <= 0:
		return tiles
	var per: int = maxi(1, int(ceil(float(n) / float(count))))
	var from: int = clampi(index * per, 0, n)
	var to: int = clampi(from + per, 0, n)
	if from >= to:
		return []
	return tiles.slice(from, to)


## 在给定的一批地块里挑 `want` 个点（锚点 + 周围限距内的点）。
##
## ⚠️ 锚点必须**可通行且没有建筑**：巡逻点落在山地上会让守将永远走不到（路径找不到），
##   落在建筑上会卡在建筑里（与出生点同一条判据，见 `_zone_spawn_tile`）。
static func _pick_points(world, cfg: ConfigRes, u, tiles: Array, rng: RandomNumberGenerator,
		want: int, spread: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if tiles.is_empty():
		return out
	var anchor := Vector2i(-1, -1)
	var start: int = rng.randi_range(0, tiles.size() - 1)
	for k in tiles.size():
		var t: Vector2i = tiles[(start + k) % tiles.size()]
		if _can_stand(world, cfg, u, t):
			anchor = t
			break
	if anchor.x < 0:
		return out
	out.append(anchor)
	var start2: int = rng.randi_range(0, tiles.size() - 1)
	for k in tiles.size():
		if out.size() >= want:
			break
		var t2: Vector2i = tiles[(start2 + k) % tiles.size()]
		if not _can_stand(world, cfg, u, t2):
			continue
		var d_anchor := Vector2(t2 - anchor).length()
		if d_anchor > spread or d_anchor < 1.0:
			continue
		var too_close := false
		for p in out:
			if Vector2(t2 - p).length() < 1.0:
				too_close = true
				break
		if too_close:
			continue
		out.append(t2)
	return out


## 这一格能不能站人（可通行 + 没有建筑）。
static func _can_stand(world, cfg: ConfigRes, u, t: Vector2i) -> bool:
	if not PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, String(u.faction)):
		return false
	return world.building_at(t.x, t.y) == null


## ★★ 巡逻路线的种子：**由单位 id 派生**，而不是取引擎随机数。
##
## 为什么必须这样（这是本项目的硬规矩，见 dev_plan_7 3.10）：
##   「出兵成形与 AI 决策**都不许**用『随机数决定结果』」——
##   房主权威下客机不需要确定性，但**存档 / 回放需要**：
##   同一份关卡 + 同一份快照必须还原出同一个世界。
##   ⇒ 用**确定性伪随机**（种子只来自稳定的数据）：看起来杂乱，
##     但同一个单位在同一局里每次算出来的路线**完全一样**，重复跑也不变。
##
## ⚠️⚠️ **不能**用 `String.hash()`：Godot 的字符串哈希在**不同进程之间不一样**
##   （实测：同 id 的守将两次算出完全不同的路线）—— 那样「确定性」是假的，
##   存档 / 回放会漂。所以自己按**字符码**做一个稳定的小哈希（只用整数运算）。
static func _route_seed(unit_id: String, faction: String) -> int:
	var h: int = 2166136261            # FNV-1a 的 32 位偏移基数
	for i in (unit_id + "|" + faction).length():
		h = ((h ^ int((unit_id + "|" + faction).unicode_at(i))) * 16777619) & 0x7FFFFFFF
	return h


## 路线算不出来时的兜底：老口径 —— 区划中心，其次区划第一格，最后大本营。
static func _patrol_fallback_tile(world, u, z) -> Vector2i:
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
