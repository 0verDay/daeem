## garrison_ai.gd —— **阵地性 AI**：附属在某个**区划**下的守将。
##
## 需求原文（逐条对照）：
##   1. 「该类 AI 会附属在一个区划下，其没有资源库，没有大本营」
##      → 状态全在**单位自己身上**（`garrison_zone_id` / `patrol_timer` /
##        `combat_idle_timer` / `garrison_recruit_timer`），不新建任何「AI 对象」，
##        也不碰 world 的资源表。它不生产、不建造、不升级 —— 缺的东西就没有，
##        不是「有但为 0」。
##   2. 「该类 AI 会有其归属的区划，且在其归属的区划中有时间间隔地巡逻」
##      → 归属写在 `unit.garrison_zone_id`（关卡 `start_units[].zone` 或出生格）；
##        每 `ai.garrison.patrol_interval_sec` 秒朝**自己区划的中心**走一趟（往返巡逻）。
##   3. 「若其警戒到敌方单位会发动攻击，但不会追击超过一个区划」
##      → 交战本身交给 combat.gd（它已经有追击上限那一套）；本模块只补一条
##        **区划级**的硬约束：一旦脚踩进别人的区划（或离归属区划的中心太远），
##        当场脱战并走回去。见 `_out_of_garrison()`。
##        ★ 配套：脱战之后拉起 `unit.retarget_cd`（`ai.garrison.retarget_cooldown_sec`）——
##          没有它的话 combat.gd 下一帧就把同一个敌人再锁一次，表现为原地抖动。
##   4. 「该类 AI 在脱战（没有攻击行为 10 秒后）且不满员的情况下会无资源消耗地招募单位
##        （或者可以认定该类 AI 资源无限）」
##      → `combat_idle_timer` 连续 `ai.garrison.combat_idle_sec` 秒没有交战 → 调
##        `world.start_recruit(kind, id, faction, free = true)`：
##        不扣粮食 / 黄金 / 人口（复用招募那一整套读条与队列）。
##   5. ★★ 「保留将领的再起逻辑，当将领可以再起时无消耗地立刻执行再起（本轮口径）」
##      → 每帧扫一遍 **AI 阵营的**濒死将领（`_tick_revive()`）：只要
##        `revive_ready()`（血量回到门槛）且没在读条，当场 `world.start_revive()`。
##        无消耗是因为 AI 阵营没有资源池（`resource_pool_for()` 返回 null = 无限）。
##
## ★★ 本模块是「阵地性 AI」—— 现在**所有** AI 阵营（原阵营性 + 原将领性）
##    都用这一套：附属于区划、巡逻、无消耗招募。红点性 AI 见 `logic/red_dot_ai.gd`。
##
## ★ 每帧开销：只遍历 `world.units` 一次；重活儿（数附属兵、下单招募）
##   全部摊到几秒一次的计时器上（见 unit.retinue_size 的说明）。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##    见 docs/pitfalls.md 第五节）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const LevelRes = preload("res://logic/level.gd")
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
	# ★★ 再起与 dt 无关（只看血量门槛与是否在读条）—— 放在最前面，dt <= 0 时也照跑。
	_tick_revive(world, cfg)
	if dt <= 0.0:
		return
	var gc: Dictionary = cfg.ai_garrison_cfg()
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
		# ★★ 返程的**兜底终点**（本轮修 bug，见 `unit.returning_home_sec`）：
		#    实测卡过一次 —— 放弃追击之后它一直没能回到自己区划，
		#    `returning_home` 挂着不清 ⇒ 第 5 步永远跳过 ⇒ 它定死在原地、
		#    再也接不到新的巡逻命令。给它一个上限，超了就当到家。
		if u.returning_home:
			u.returning_home_sec += dt
			if u.returning_home_sec > RETURN_HOME_MAX_SEC:
				u.returning_home = false
				u.returning_home_sec = 0.0
		else:
			u.returning_home_sec = 0.0
		var in_combat: bool = u.target != null or u.target_building != null

		# ---- 1) ★★ 追击状态机（本轮重写，用户口径）----
		#
		# 需求原话：「巡逻时发现敌人后向该敌人追击，当该敌人死亡或在自己的警戒范围外时，
		#           放弃追击转为立刻返回所属区划继续巡逻」。
		#
		# 于是「交战中」拆成两档（`u.chasing`）：
		#   · **追击**（chasing = true）：combt 在巡逻中警戒到的敌人。**不拦它**——
		#     这一帧交给 combat.gd 去追去打（下面第 3 步的 `continue`）；
		#     只要「那个敌人」还活着、还没跑出当初发现它时的警戒范围，就一路追。
		#   · **放弃追击**：上面任一条不成立（或追不动了）⇒ 当场脱战、
		#     拉一段再战冷却（别在回家路上被同一个敌人又锁上），并**立刻**走上返程。
		#
		# ⚠️⚠️ 为什么把旧口径换掉（实测报回来的「在非其所属区域攻击敌人时一定原地抽搐」）：
		#   旧口径是**按我自己的位置**判的（「我一脚踩出自己那个区划就叫回」）——
		#   而边界上的场面天然是自相矛盾的：我在区划外（该回），敌人还在警戒半径内（该打）；
		#   我一回区划里（该打），combat 把敌人再锁一次，我又迈出去（该回）……
		#   两个判据各说各话，肉眼看就是**在区划边缘原地抽**。
		#   ⇒ 新口径把「打不打」只挂在**一个**判据上：**敌人**离「我发现它的那个起点」
		#     有多远（`u.chase_alert_range`，发现那一刻它离我多远，天然 ≤ aggro_range）。
		#     判据只跟**目标的移动**有关，跟我自己被挤到哪、区划边界画在哪都无关 ⇒ 抖动的
		#     回路从根上断掉（只剩「敌人跑了 → 我回家」这一条单调的转移）。
		if in_combat and u.chasing and not _chase_should_continue(world, u, retarget_cd):
			_abandon_chase(world, cfg, u, z, zone_count, retarget_cd)
			in_combat = false

		# ---- 1.2) ★ 追击中：让这一队跟上（本轮新增）----
		#
		# 队长追出去时，**附属兵不会自动跟**（`combat.gd` 只管命令层给它们下的命令，
		# 而追击是 combat 直接驱动队长本人的）。不补这一手的话队长会单枪匹马追出去、
		# 兵留在原地 —— 「将领性 AI 是一支小队」这条设定就废了。
		# ⚠️ 用的是巡逻那一条现成的「掉队就叫上」（`_catch_up_retinue`），阈值
		#    `patrol_retinue_leash_tiles` 与巡逻时同一个口径（不另立一套）。
		if in_combat and u.chasing:
			var stuck := _catch_up_retinue(world, cfg, u, u.pos, dt)
			if stuck or not _chase_should_continue(world, u, retarget_cd):
				_abandon_chase(world, cfg, u, z, zone_count, retarget_cd)
				in_combat = false

		# ---- 1.5) 再战冷却期内：见到敌人也不接（把它刚锁上的那个放掉）----
		#
		# ⚠️ 这一段必须在「脱战计时」**之前**：冷却期内被锁上的那一帧不该算「正在交战」，
		#    否则 IDLE 计时被反复清零，它永远招不了兵（冷却与招兵会互相饿死）。
		if in_combat and u.retarget_cd > 0.0:
			u.drop_engagement()
			u.clear_chase()
			in_combat = false

		# ---- 1.6) 刚警戒到敌人 ⇒ 进入追击状态（记下「发现点」与当时的距离）----
		#
		# ⚠️ 只在**真的锁上了**（`target` 非空）那一帧记一次：`chase_alert_range`
		#    是「这一轮追击的警戒范围」，追的过程中不能再刷新它（那会变成
		#    「敌人跑多远都不算远」，等于没有上限）。
		if in_combat and not u.chasing and u.target != null:
			u.chasing = true
			u.chase_anchor = u.pos
			u.chase_alert_range = maxf(ATTACK_REACH_MIN, u.pos.distance_to(u.target.pos))
			u.chase_stuck_timer = 0.0
			u.chase_last_pos = u.pos

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
		# ★★ 编制上限的口径（本轮修的一个实测 bug）：
		#   · **有关卡** ⇒ 听**关卡数据**（`world.escort_target_of`：谁摆了附属兵就按摆的算，
		#     没摆的那一方退到它自己在关卡 `factions[].faction_ai` 里写的 `min_retinue`）；
		#   · **没有关卡**（自由对战、纯单位测试的世界）⇒ 听全局配置的
		#     `ai.general.min_retinue`（老行为，`tests/test_ai.gd` 那一批靠它）。
		#   ⚠️ 判据必须是「有没有关卡」，不能是「这一关有没有人摆过附属兵」：
		#     后者在「有关卡、但谁都没摆」时也是 false，那就会去读全局配置，
		#     把关卡作者写的 `min_retinue`（比如守军的 **0 = 别给我补兵**）整个无视掉。
		#   ⚠️ 这里原来**直接吃** config 的 `min_retinue`（默认 3）⇒ 关卡里的编制被完全无视：
		#     实测「守军 `min_retinue: 0`」照样一路白嫖到 24 个单位，而它招兵是
		#     **无消耗**的 ⇒ 攻方的兵要付人口、被打得抬不起头，
		#     「攻占目标区划」那条目标**永远拿不下来**。
		var want: int = min_retinue
		if world.level != null:
			want = int(world.escort_target_of(String(u.faction), int(u.general_index)))
		if u.combat_idle_timer >= idle_sec and want > 0:
			u.garrison_recruit_timer -= dt
			if u.garrison_recruit_timer <= 0.0:
				u.garrison_recruit_timer = recruit_check
				if orders < MAX_RECRUIT_ORDERS_PER_TICK and _try_recruit(world, u, want):
					orders += 1
					continue      # 刚下单：这一帧别再插一条巡逻命令（会把它顶掉）

		# ---- 5) 巡逻：按时间间隔朝**自己路线的下一个点**走 ----
		# ★★ 正在回家的路上（`returning_home`）：**不再插新的巡逻命令** ——
		#    那会把返程路径顶掉，于是它一步都走不回去（本轮修的「卡边界抽搐」）。
		#
		# ★★ 但这个标志必须**保证会结束**（否则它一挂上就永远跳过这一步 = 人定死原地）：
		#    · 一脚踏回**自己的区划** ⇒ 返程的目的已经达到，标志当场清掉；
		#      ⚠️ 清掉之后这一帧仍然 `continue`（见下面那半句）：让它在走完最后几步
		#        之前别被新命令打断，但**下一帧**若还没停稳也不会再来一遍 —— flag 已经没了。
		#    · 或者走到了这一趟那个巡逻点上（见 `_patrol_leader` 末尾）。
		if u.returning_home:
			if _in_own_garrison(world, u):
				u.returning_home = false
			else:
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


## 追击时，「警戒范围」的最小值（格）。
##
## 为什么要有下限：警戒范围取的是「发现敌人那一刻它离我多远」，而如果两者
## **贴在同一格**（距离 ≈ 0），那这一轮就变成「敌人挪半格就算跑出警戒范围 ⇒ 立刻回家」——
## 贴脸战斗反而不敢追。给它一个下限，贴脸发现的敌人也允许追出这一小段。
const ATTACK_REACH_MIN := 2.0

## 追击中「原地不动」多久算追不动了（秒）⇒ 放弃追击、转回家。
##
## 为什么需要它：`chase_anchor` 那套判据只管「敌人跑远了没」，管不住
##   「敌人站在我够不着的地方」（隔着城墙 / 河 / 别人堵着）。没有这一条的话，
##   守将会一直贴着障碍站着 —— 既追不到也回不了家（需求要的是「放弃后立刻返回」）。
const CHASE_STUCK_SEC := 3.0

## 追击中「这一帧算动了」的位移阈值（格）。与巡逻那套「到了没有」的 0.5 别混用：
## 这里判的是「有没有在挪」，被挤着微微动一点不算。
const CHASE_MOVE_EPS := 0.05

## 「回家」这一段最多允许持续多久（秒）。超了就当到家，恢复正常巡逻。
##
## 为什么必须有（实测）：返程的终止条件原来只有「走回自己区划」——
##   而**走不回去**的场面是真实存在的（被地形挡住、被人群挤在边缘、目标点在区划另一头
##   而路径被截断）。那时 `returning_home` 挂着不清，`update()` 第 5 步被永远跳过，
##   这位守将就**定死在原地**、再也接不到新巡逻命令。
##   集成探针实测到过一次（25 秒都没回家）；这条兜底把「走不回去」变成「转两圈继续巡逻」。
const RETURN_HOME_MAX_SEC := 6.0


## 这一轮追击还要不要继续（用户口径的两个终止条件 + 「追不动了」那条兜底）。
##
## 终止条件（任一条成立就放弃）：
##   1. **目标没了 / 打不了了**（死亡、进濒死、被别的逻辑结算掉）——`is_attackable()`；
##   2. **目标跑出了警戒范围**：离「我发现它的那个起点」超过 `chase_alert_range`；
##   3. ★ 兜底：追不动了（连续 `CHASE_STUCK_SEC` 秒原地不动）。
##
## ⚠️ 判据**只**看目标的位置与死活 —— 不看「我自己在哪个区划」。
##    那正是旧口径抖动的原因，见 `update()` 第 1 步那一大段说明。
static func _chase_should_continue(world, u, retarget_cd: float) -> bool:
	var t = u.target
	if t == null or not t.is_attackable():
		return false                       # 目标死了 / 打不了了
	if int(u.retarget_cd) > 0:
		return false                       # 冷却期内（理论上进不来，防御性）
	var reach: float = maxf(ATTACK_REACH_MIN, float(u.chase_alert_range))
	if t.pos.distance_to(u.chase_anchor) > reach:
		return false                       # 跑出警戒范围了
	return true


## 放弃追击：当场脱战、拉一段再战冷却，并**立刻**走上返程（用户口径）。
##
## ⚠️ 返程只下一道命令（`returning_home` 把这一段变成**一次**命令）：
##    每帧重下会把路径一帧一帧重置，人永远走不回家（那正是「原地抽搐」的成因之一）。
static func _abandon_chase(world, cfg: ConfigRes, u, z, zone_count: int,
		retarget_cd: float) -> void:
	u.drop_engagement()
	u.clear_chase()
	# ★ 冷却：回家路上别被同一个敌人立刻再锁上（距离判据已经能防抖，
	#   这一条只是把「刚放弃就被再锁」那一下挡掉，不需要很长）。
	u.retarget_cd = maxf(float(u.retarget_cd), retarget_cd)
	if not u.returning_home:
		u.returning_home = true
		_patrol_leader(world, cfg, u, z, zone_count)
	u.patrol_timer = float(cfg.ai_garrison_cfg()["patrol_interval_sec"])


## 追击中「原地不动」的累计与判定（由 `_catch_up_retinue` 顺带驱动，见它的 `dt`）。
##
## ★ 放在 `_catch_up_retinue` 里而不是每帧另起一段：那一手**只在追击/巡逻时**跑，
##   正好覆盖「追不动」的两种场面（被障碍挡着 / 被人群挤住），不必再开一条遍历。
static func _track_chase_stuck(u, dt: float) -> bool:
	if dt <= 0.0:
		return false
	if u.pos.distance_to(u.chase_last_pos) <= CHASE_MOVE_EPS:
		u.chase_stuck_timer += dt
	else:
		u.chase_stuck_timer = 0.0
	u.chase_last_pos = u.pos
	return u.chase_stuck_timer >= CHASE_STUCK_SEC


## 这个驻防将领负责的区划字典（区划 id 找不到 / 地图换了 → null）。
static func _garrison_zone(world, u) -> Variant:
	if u.garrison_zone_id < 0 or world.zones == null:
		return null
	return world.zone_by_id(u.garrison_zone_id)


## 它现在是不是**站在自己负责的那个区划里**（区划级归属的唯一判据，本轮新增）。
##
## 用途只有一处：判断「返程」有没有走到（见 `update()` 第 5 步）。
## ⚠️ 与旧的 `_out_of_garrison()` 不是一回事：那一个判的是「**算不算追出去了**」，
##    而它已经**整个删掉**了 —— 新口径下「打不打」只看敌人离发现点的距离，
##    与我自己站在哪个区划完全无关（那正是抖动 bug 的根因）。
static func _in_own_garrison(world, u) -> bool:
	if u.garrison_zone_id < 0 or world.zones == null:
		return true                        # 没有归属：不限制（与旧口径一致）
	var here: Variant = world.zones.zone_at(u.tx, u.ty)
	if here == null:
		return false
	return int((here as Dictionary)["id"]) == int(u.garrison_zone_id)


## 它现在算不算「追出自己那个区划了」。
##
## ⚠️⚠️ **本轮已被 `_chase_should_continue()` 取代，不要再拿它做判断**（保留此函数
##    只为留下那段推理）：它的判据是「**我自己**在不在归属区划里」，而边界上的场面
##    天然自相矛盾 —— 我在区划外（该回），敌人还在警戒半径内（该打）；我一回区划里
##    （该打），combat 又把敌人锁上，我再迈出去（该回）…… 两个判据各说各话，
##    肉眼看就是**在区划边缘原地抽搐**（用户报回来的正是这个）。
##    新口径只认「**敌人**离我发现它的那个起点有多远」，与我在哪个区划无关。
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
	# ★★ 返程什么时候算结束（本轮重写，别只留「到点」那一条）：
	#   `returning_home` 的语义是「回家路上，别插新的巡逻命令」。它必须**保证会结束**，
	#   否则这个标志一挂上，第 5 步就永远跳过 —— 人定死在原地（那正是旧代码靠
	#   「再战冷却结束」兜住的那个洞，而冷却与返程本来就是两件事）。
	#   两条结束判据，任一条成立即可：
	#     a) **站定在自己的区划里**：这就是「到家了」。巡逻点可能在区划另一头，
	#        要求它一定停在某个**具体点**上会把返程拖成永远（实测：站在自己区划里
	#        不动、离那个点 3 格 ⇒ 标志挂死）。
	#     b) 已经站在这一趟那个点上了（原判据，保留：正常情况走的就是这一条）。
	#   ⚠️ 两条都要求 `not u.moving`：还在路上时不许判结束（不然等于没返程）。
	if u.returning_home and not u.moving:
		var home: Variant = world.zones.zone_at(u.tx, u.ty)
		var in_own_zone: bool = home != null and z != null \
			and int((home as Dictionary)["id"]) == int(u.garrison_zone_id)
		if in_own_zone or u.pos.distance_to(pt) <= 0.75:
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
##
## ★★ `dt`（可选，> 0 时）还顺带驱动「追击卡住了没」（见 `_track_chase_stuck`）：
##    那个判据本来就是「队长自己挪没挪」，而这一手**恰好只在队长带队时跑**
##    （巡逻 / 追击两条路都会调它），不必再开一条遍历。
##
## @return true = 这一队**追不动了**（调用方在追击中据此放弃追击、转回家）
static func _catch_up_retinue(world, cfg: ConfigRes, u, pt: Vector2, dt: float = 0.0) -> bool:
	if dt > 0.0 and u.chasing and _track_chase_stuck(u, dt):
		return true
	var gc: Dictionary = cfg.ai_garrison_cfg()
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
	return false


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
	var want: int = maxi(1, int(cfg.ai_garrison_cfg().get("patrol_points", 3)))
	var spread: float = maxf(1.0, float(cfg.ai_garrison_cfg().get("patrol_spread_tiles", 3.0)))

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


## ★★ 让 **AI 阵营**的濒死将领「一够条件就再起」（本轮口径）。
##
## 需求原话：「保留将领的再起逻辑，当将领可以再起时，无消耗地立刻执行再起」。
##
## 三条件（逐条对应）：
##   1. 是一位**将领**（`is_general()`）且属于 **AI 阵营**（`ai_kind_of` 是阵地性 / 红点性）；
##   2. 正在**濒死**（`downed`）、且**还没在读条**（`revive_remaining <= 0`）；
##   3. 血量已经回到门槛（`revive_ready()`，与玩家同一个 `revive.ready_ratio`）。
##
## ★ 走 `world.start_revive()` —— 与玩家点「再起」**同一条**路。无消耗是免费的：
##   AI 阵营没有资源池（`resource_pool_for()` 返回 null = 无限），
##   于是 `revive_reject_reason()` 里的 "cost" 那一关永远通过、也不扣任何东西。
## ★ 一帧可以起多位（互不干扰），但每位最多一单 —— `revive_remaining > 0` 就跳过，
##   不会对着同一位反复下单。
static func _tick_revive(world, cfg: ConfigRes) -> void:
	for u in world.units:
		if not u.alive or not u.is_general():
			continue
		var kind: String = world.ai_kind_of(String(u.faction))
		if kind != LevelRes.AI_GARRISON and kind != LevelRes.AI_REDDOT:
			continue                        # 玩家 / 不挂 AI 的阵营不走这条路
		if not u.is_downed():
			continue
		if u.revive_remaining > 0.0:
			continue                        # 已经在读条了
		if not u.revive_ready(cfg):
			continue                        # 还没回到门槛
		world.start_revive(String(u.id), String(u.faction))
