## combat.gd —— 战斗结算与事件：索敌 / 开火 / 拆建筑 / 箭塔
##                （对应 HTML 版 js/unit.js 的战斗那一半 + building.js 的 update_towers）
##
## 数值全部在 config.combat 里，`combat.enabled = false` 可整体关掉（只留移动）。
##
## 规则（与 HTML 版一致）：
##   - **警戒**：没有攻击目标、且处于**静止**的单位，搜索警戒半径内**最近的**敌方单位
##     并锁定它，然后由 update_unit() 负责「先移动靠近，进入攻击距离再开火」；
##   - **追击上限**（leash）：目标离「发现它的那个位置」超过 aggro_range × leash_factor
##     就放弃，不会一路追到地图另一头；
##   - 追击期间目标一直在动，所以每 repath_sec 秒重新寻路一次，不每帧重算；
##   - 目标死亡 / 被移出战场 → 自动脱离交战，回到警戒状态；
##   - **玩家操作优先**：右键移动命令（order_move）会立刻中断交战；
##   - **拆建筑**：单位也能把建筑当目标（set_building_target），同样「先靠近、再一下一下打」。
##     建筑占满整格，所以攻击距离额外算**半格**（贴着墙就能砸到）；
##   - **两个阵营对称**：敌我共用同一套逻辑，静止的敌人也会盯上我方单位。
##
## ⚠️ 逻辑层不用信号（见 docs/pitfalls.md 2.5）：事件走 world.push_event()，
##    由 world.tick() 末尾统一收口，view/ 只读不写。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
## ★★ 用 preload 常量给参数**加类型**，是这里最重要的一处性能改动。
##
## GDScript 里**无类型**的参数（`func f(u)`）访问 `u.moving` / `u.pos` 时走的是
## **动态属性查找**（每次一个哈希查找 + 类型检查），而有类型时编译器能静态解析成员。
## 实测：1000 个单位待命时，`update_unit` 从 **18 ms/帧** 掉到 1 ms 量级 ——
## 因为那个函数每单位要读二十来个字段，动态查找把成本放大了一个数量级。
## ⚠️ 这也是 `unit.gd` 里**不能** preload `combat.gd` 的原因：两边互相 preload 会形成
##    循环依赖（Godot 直接报 Could not resolve script）。所以 `tick_frame` 放在这边。
const UnitRes = preload("res://logic/unit.gd")
## ★ 同理给「碰撞/索敌桥」加类型：`world.crowd` 本身是动态查找，而
##   `crowd._targets_ready` / `crowd._target_idx` 在**每单位每帧**的索敌路径上。
##   crowd_bridge.gd 不 preload 本文件，所以不是循环依赖。
const CrowdBridgeRes = preload("res://logic/crowd/crowd_bridge.gd")

## ★ 诊断计数器：本帧真正算了多少次「追击寻路」。只在基准里读，逻辑不依赖它。
##   用途：把「重寻路次数太多」和「单次寻路太贵」这两种可能分开 —— 实测实机行军攻击
##   20 fps 时，必须先知道是哪个，否则优化就是瞎猜。
##   `move_to_calls` 在 unit.gd 上（那里才是真正寻路的地方，不能反向 preload 本文件）。
static var repath_calls: int = 0


## 一帧的单位更新（战斗 / 警戒 → 回位 → 沿路推进）。
##
## ★ 为什么把这三步合并进一个函数：原来 `world.tick` 对每个单位要跨**三次**对象边界
##   （`CombatRes.update_unit` / `u.reclaim_settled_spot` / `u.step_along_path`）。
##   合并之后每单位只剩一次调用 —— 1000 单位就是每帧省下 2000 次 GDScript 方法调用。
##
## @param idx 本单位在 world.units 里的下标（用于取本帧批量算好的索敌结果）
static func tick_frame(world, cfg: ConfigRes, u: UnitRes, dt: float, idx: int) -> void:
	# ★★ 生产路径：三段直接连着跑，**不做任何逐段计时**。
	#    ⚠️ 濒死的将领不在这里特判（`update_unit` 第一句就接管了）：这一层被
	#       `world.tick` 只在「活着 + 没在招募 + 没濒死」时调用，所以那一支走不到；
	#       真在这里也补一次的话，`update_unit` 那一支会让回复**跑两遍**（实测踩到）。
	#    分段计时如果写在这个循环里（每单位 4 次 `_prof()`），即使 profile 关着也要付那 4 次调用
	#    —— 1000 单位就是每帧 ~0.8 ms，纯属为了「跑 bench 时能看细分」在生产路径上白交的钱。
	if not world.profile_on:
		update_unit(world, cfg, u, dt, idx)
		# 站定后被推离落点就自己走回去（必须在 step 之前：先决定要不要回位）
		if not u.moving and u.has_settled_goal:
			u.reclaim_settled_spot(world, cfg)
		if not u.path.is_empty():
			u.step_along_path(world, cfg, dt)
		return

	var t0 := Time.get_ticks_usec()
	update_unit(world, cfg, u, dt, idx)
	var t1 := Time.get_ticks_usec()
	if not u.moving and u.has_settled_goal:
		u.reclaim_settled_spot(world, cfg)
	var t2 := Time.get_ticks_usec()
	if not u.path.is_empty():
		u.step_along_path(world, cfg, dt)
	var t3 := Time.get_ticks_usec()
	world.profile_sub("units/combat", t1 - t0)
	world.profile_sub("units/reclaim", t2 - t1)
	world.profile_sub("units/step", t3 - t2)


## 每帧推进一个单位的攻击冷却 / 特效计时，并决定它这一帧干什么。
##
## @param idx 这个单位在 world.units 里的下标（由 world.tick 传进来）。
##        有它才能取「本帧批量算好的索敌结果」；不传就走原来的逐个扫描（测试里会这样调）。
static func update_unit(world, cfg: ConfigRes, u: UnitRes, dt: float, idx: int = -1) -> void:
	# ★★ 濒死的将领（本轮新增）：这一帧**只跑濒死状态机**（缓慢回复 / 全灭判定 /
	#    再起读条），其余什么都不做 —— 需求是「倒在原地」：不能移动、不能攻击、
	#    也不做任何索敌（它已经不可能被谁选中了，见 `is_attackable()`）。
	#
	# ⚠️⚠️ 这一支**只能出现在这里或 `tick_frame` 里，二选一**（实测踩到）：
	#    `tick_frame` 会调 `update_unit`，两处都补一次的话回复速度翻倍
	#    （实测：每 3 秒 1% 变成每 2 秒 1%），而且「全灭判定」也会跑两遍。
	#    现在唯一入口是 `tick_frame` 的开头，这里保留的只是「有人绕过 tick_frame
	#    直接调本函数」时的兜底 —— 所以它排在最前面并立即返回。
	if u.is_downed():
		u.tick_near_death(cfg, world, dt)
		return

	if u.attack_cd > 0.0:
		u.attack_cd = maxf(0.0, u.attack_cd - dt)
	if u.attack_flash > 0.0:
		u.attack_flash = maxf(0.0, u.attack_flash - dt / cfg.flash_sec_safe)
	if u.repath_timer > 0.0:
		u.repath_timer = maxf(0.0, u.repath_timer - dt)
	# ★★ 「因为追击上限放弃」之后的冷却（见 config 的 leash_release_cd）：
	#    它只挡**自动索敌**，不影响任何玩家命令。
	if u.leash_cd > 0.0:
		u.leash_cd = maxf(0.0, u.leash_cd - dt)

	# 己方单位站在**己方**领地内缓慢回血（便于肉眼确认领地归属是否生效）
	# ★ 用 u.faction 比对，而不是写死 'player' —— 联机下「己方领地」= 自己那一方的区块
	#
	# ⚠️ 判定顺序有讲究：**先看血量**再看领地。满血的单位占绝大多数（1000 单位常态下
	#    就是全部），先查血就整个跳过 zone_at 的区块查表与阵营判定 ——
	#    实测这一条把每帧的 combat 段从 1.5 ms 压到不足一半。
	if u.hp < u.hp_max and FactionRes.is_player_faction(u.faction):
		var z = world.zones.zone_at(u.tx, u.ty)
		if z != null and z.owner == u.faction:
			u.hp = minf(u.hp_max, u.hp + 4.0 * dt)

	if not cfg.combat_enabled:
		# 关掉战斗时不保留旧目标，否则表现上像「还在交战」
		if u.target != null or u.target_building != null:
			u.clear_target()
	elif u.target != null:
		update_combat(world, cfg, u)
	elif u.ordered_building != null and u.ordered_building.alive:
		# ★★ 玩家**点名**拆除的建筑还活着 → **只打它**，这一帧不做任何自动索敌。
		#
		# 为什么必须单独一支（手玩报的 bug）：单位走到建筑旁边会 `halt()`（moving = false），
		# 而下面的警戒分支正是「静止就索敌」—— 于是它一到地方就把旁边的敌人认成新目标，
		# 表现就是「走到箭塔附近之后随机打周围的敌人」，玩家点的那个建筑反而没人管了。
		# 与 SC2 一致：明确点名的目标不会被路过的敌人顶掉，直到它被摧毁。
		update_building_combat(world, cfg, u)
	elif u.ordered_target != null and u.ordered_target.alive:
		# 点名要打的**单位**还在，但当前交战对象被清掉了（理论上不该发生，留个保险）：
		# 直接重新锁上，别让这条命令悬在半空。
		u.target = u.ordered_target
		update_combat(world, cfg, u)
	else:
		# 警戒：只有**静止**的单位才会索敌；附近有敌方单位就先打单位，没有才继续拆建筑
		#
		# ★ 例外：**行军攻击**（has_attack_move）在移动中也要索敌 ——
		#   那正是「按 A 走过去、路上遇敌就停下来打」的全部含义。
		#   （第一版漏了这条：单位一路走到终点都不理路上的敌人，测试当场抓住。）
		if not u.moving or u.has_attack_move:
			# ★★ 行军攻击的单位在赶路时**每帧**都要索敌（那是 A 键的语义），
			#    而 1000 个单位每帧走一遍索敌是 3 ms 量级的开销（实测）。
			#    这里**错开成三帧一次**：每个单位仍然以 20 Hz 索敌，肉眼完全看不出延迟
			#    （「路上遇敌就停下来打」本来也不需要 60 Hz 的反应速度），
			#    但每帧的索敌量降到三分之一。驻守/待命单位不受影响（照旧每帧扫）。
			#    ⚠️ 错开的相位用 (单位下标 + 帧号)，保证同一帧里三拨各占三分之一 ——
			#      只用单位下标的话，一波单位会永远落在同一帧上，等于没分摊。
			if not u.has_attack_move or (idx + world.frame_serial) % 3 == 0:
				acquire_target(world, cfg, u, idx)
		# ★★ 行军攻击的「到点就算完成」必须**在索敌之前**判，不能等下面三个分支都落空：
		#    打完之后它会站住，而「静止」正是自动索敌的触发条件 —— 目标点旁边要是
		#    有建筑在警戒半径内（区划中心 / 对家城墙），`target_building` 那一支就会
		#    抢先生效，行军攻击的标记**永远清不掉**（实测：`has_attack_move` 一直为真）。
		#    走到点了就是走到了 —— 命令的完成不该被路过的东西拦住。
		if u.has_attack_move and not u.moving and u.pos.distance_to(u.attack_move_goal) <= 0.5:
			u.has_attack_move = false          # 到了，命令完成
		if u.target != null:
			update_combat(world, cfg, u)
		elif u.target_building != null:
			update_building_combat(world, cfg, u)
		elif u.has_attack_move and not u.moving:
			# ★ 行军攻击：打完了（或被打断）还没到点 → 接着走。
			#   ⚠️ 用 repath_timer 限流：走不到的时候（目标点被封）不能每帧算一次 A*。
			if u.repath_timer <= 0.0:
				u.repath_timer = cfg.repath_sec
				if not u.move_to(world, cfg, u.attack_move_goal):
					# 已经到不了（比如目标点被建筑占满）→ 认账，别再每帧试
					u.has_attack_move = false

	# ★★ 濒死救援的「打完了继续去救」（本次修 bug）。
	#
	# 为什么单独一支、而不是并进上面那个 `elif`：救援**不依赖** `has_attack_move`
	#   —— 战斗接管过的附属兵那个标志已经是 false 了（`order_attack_unit` /
	#   战斗内的清理都会清它），正是它们最需要被送回倒下点。
	#   ⇒ 判据只看「意图还在 + 停下来了」；目的地每次现读队长的 `downed_anchor`
	#     （队长在濒死期间位置被钉住，所以它就是倒下点）。
	#   ⚠️ 这一支必须放在 `update_combat` **之后**：它要读的是「打完之后」的状态
	#     （还在打的话 `u.moving` 为真或目标非空，这里自然不触发）。
	if u.is_rescuing() and not u.moving and u.target == null and u.target_building == null:
		var rescue_leader = world.unit_by_id(u.rescue_leader_id)
		if rescue_leader != null and rescue_leader.is_downed():
			if u.repath_timer <= 0.0:
				u.repath_timer = cfg.repath_sec
				u.order_attack_move(world, cfg, rescue_leader.downed_anchor)


## 警戒：静止且没有目标的单位搜索警戒半径内的敌方**单位**，锁定最近的一个。
##
## 搜不到敌方单位时，**任何阵营**的单位都会再搜一次**敌方建筑**（需求：
## 「给己方单位增加索敌建筑的机制」）—— 走到对家箭塔/城墙边上就会自己开打。
##
## ★★ 本次改动：这一条原来是「只有玩家阵营才做」（`is_player_faction` 那道早退）。
##   实测报回来的两条正是它的后果：
##     ·「我在敌方部队附近建造建筑，敌方不会有想打掉这个建筑」；
##     ·「他只会让箭塔持续攻击自己」（被塔打也不还手，因为「建筑」这个目标类别
##       对 AI 单位根本不存在）。
##   ⇒ 改成**按阵营无关**的通用规则。
##
## ⚠️ 与 `enemy_ai`（测试敌人的推进 AI）的关系：那条 AI 仍然负责「朝玩家据点推进 +
##    拆挡路的城墙」，两条**不冲突** —— `enemy_ai` 只在 `target_building == null`
##    时才动手（拆墙只是它推进受阻时的兜底），而这里只是多加了一个「附近有可打建筑
##    就顺手拆掉」的来源。真正的推进节奏由 `enemy_ai` 的目标选择决定，没有被改掉。
## ⚠️ 中立 / 无敌建筑（区划中心）在 `nearest_enemy_building` 里已被跳过，所以
##    「AI 跑去对着打不掉的柱子敲一辈子」那条老坑不会复活。
static func acquire_target(world, cfg: ConfigRes, u: UnitRes, idx: int = -1) -> bool:
	if not cfg.combat_enabled:
		return false
	# ★★ 已经在打一个还能打的目标 ⇒ **不重新索敌**（本轮修 bug 时补上的一句）。
	#
	# 为什么必须有它（这是「原地抽搐」这条 bug 的**第二层**根因）：
	#   下面「锁定那一刻把参照点设成当前位置」那一句，原来在**每次**索敌成功时都会执行；
	#   生产路径上 `update_unit` 是「没有 target 才索敌」，所以平时碰不到 ——
	#   但**只要有一次在「已经有目标」时也调了它**（测试、以后新加的 AI 逻辑），
	#   参照点就被抹回当前位置，追击上限立刻失效，症状与玩家报的一模一样。
	#   ⇒ 把「已经锁着目标就别再索敌」写成**函数自己的契约**，调用方怎么写都不会踩。
	# ★ 顺带也是性能：待命单位每帧索敌时，已经锁定的那些一句就返回了。
	# ⚠️ 目标失效（阵亡 / 刚进濒死）时**不能**在这里返回：那种情况必须让
	#    `update_combat` 去脱战，否则它会一直挂着一个打不动的目标（见那里的判据）。
	if u.target != null and u.target.is_attackable():
		return false
	# ★ 直接读 cfg 上的字段而不是走 u.aggro_range(cfg)：那是每单位每帧一次的方法调用
	var aggro: float = cfg.aggro_range
	if aggro <= 0.0:
		return false
	# ★★ 濒死救援途中（`unit.is_rescuing()`）：警戒半径**缩一圈**（本次修 bug）。
	#
	# 为什么需要它：赶去救队长的那几个兵，如果沿用正常警戒半径，路过的任何敌人都会
	#   把它们拽进追击；追击上限一触发就 `drop_engagement()` + 回家 ——
	#   而那条救援命令**已经被战斗清掉了** ⇒ 表现就是「将领倒了，部队不去保护」。
	#   ⇒ 救援期间只理「贴到脸上的威胁」（`ai.rescue_aggro_mult` × 正常半径，默认 40%），
	#     打完继续往倒下点走（见 `update_unit` 末尾那一段）。
	#   ⚠️ 注意这里**不是**禁止索敌：完全不还手会让援军被沿途的敌人白打。
	if u.is_rescuing():
		aggro *= cfg.rescue_aggro_mult
	# ★★ 「因为追击上限刚放弃过」的冷却期内**不再自动锁定单位**（本轮修 bug）。
	#
	# 修的是实测报回来的现象：「单位在区划边界要追击的敌方单位会在原地抽搐」。
	#   放弃那一下只清 `target`，而目标**还在警戒半径里** —— 下一帧这里立刻又把它锁上，
	#   而锁定那一刻「离参照点 `anchor` 的距离」当然是 0 ⇒ 再走一格又超上限、又放弃，
	#   一帧一放一锁就是抽搐。
	#   ⚠️ 判据放在**索敌这一层**（不是 `update_combat` 里）：要挡的就是「重新锁上」这件事。
	#   ⚠️ 只挡**单位**索敌：下面的「索敌敌方建筑」照旧要跑（那是另一条路 ——
	#      玩家阵营的兵贴到对家塔边就该开打，与「追人追过头了」无关）；
	#      玩家点名的目标也不受影响（它本来就不受 leash 约束）。
	var scan_units: bool = u.leash_cd <= 0.0

	var best = null
	var best_d := INF
	# ★★ 优先取「本帧批量算好的结果」：内核按阵营分组，只扫敌对那一组，
	#    而原来的写法是每个待命单位扫一遍全部单位（O(n²)，1000 单位待命时 283 ms/帧）。
	#    ⚠️ 只有 idx 有效、且结果确实是**本帧**的（frame_serial 对得上）才用它 ——
	#      否则宁可退回下面的逐个扫描，也不要拿上一帧的结果去索敌。
	#
	# ⚠️ 这里刻意**直接读桥上的字段**而不是走 targets_ready()/target_at() 两个方法：
	#    它们在「每帧每单位」的路径上，两次 GDScript 方法调用 ≈ 0.6 µs/单位
	#    （1000 单位就是每帧 0.6 ms）。同一个 logic 模块内部读自己的字段，值这个钱。
	var crowd: CrowdBridgeRes = world.crowd
	var used_kernel := false
	if scan_units and idx >= 0 and crowd != null and crowd._targets_ready \
			and crowd._targets_serial == world.frame_serial:
		used_kernel = true
		if idx < crowd._target_idx.size():
			var j: int = crowd._target_idx[idx]
			if j >= 0 and j < world.units.size():
				best = world.units[j]
			# ⚠️ j < 0 时**不要**退回逐个扫描：内核已经替这一帧判断过「射程内没有敌人」了。
			#    （退回扫描只是白花 O(n)；真正的目标缺失是内核的输入/映射出错，
			#      那种问题必须在内核一侧修，不能靠这里兜。）
		# ★★ 最后一道闸门：内核给的目标**必须真是敌对的**。
		#    为什么值得多花一次字符串比较（每帧每索敌单位一次，量级 1 µs）：
		#    下标映射一旦串位，内核会返回**别人那一格**的结果 —— 那一格的目标很可能
		#    就是一个自己人。而这里是**唯一**没有 `same_side` 判定的取目标路径
		#    （上面那段逐个扫描判了），少了这道闸门的表现就是「友军打友军」。
		#    实测出过一次：crowd_bridge 写回结果时用了 `if m == n` 图快，见
		#    docs/pitfalls.md 5.38 与 tests/test_csharp_bridge.gd 的 _test_no_friendly_fire。
		#    ⚠️ 这道闸门只是**保险**，不是修法：串位本身必须在内核映射那一侧修掉
		#      （否则单位会「看到了敌人却当没看到」，表现成有时不还手）。
		if best != null and FactionRes.same_side_for_attack(String(best.faction), String(u.faction)):
			best = null
		#  ★★ 同一道闸门还要挡「濒死的将领」（本轮新增）：内核只认「活着的单位」，
		#     而濒死将领在它眼里就是活的（alive == true，见 unit.downed 的说明）——
		#     不过滤的话「已经倒地的将领照旧挨打」，正是需求禁止的那件事。
		#     ⚠️ 只用 `alive` 判是不够的：`_tgt_alive` 那一档在内核里表达的是
		#     「这个单位在不在场」，把它写成 0 会让濒死将领**连索敌都做不了**，
		#     而它作为「在场单位」要照旧占位（占 AI 槽位、进区块读条）。
		#     所以过滤放在这里、读目标的 `is_attackable()`。
		if best != null and not best.is_attackable():
			best = null

	if not used_kernel:
		# ★ 冷却期（scan_units == false）时这一段整个跳过 —— 这就是「不重新锁定」。
		#   ⚠️ 写成 `for other in (world.units if scan_units else [])` 会**每次分配一个空数组**
		#      （这一段在每单位每帧的路径上），所以用外层 if 收口。
		if scan_units:
			for other in world.units:
				# ★★ 濒死的将领**不能被选为攻击对象**（需求原话）——
				#    判据走 `is_attackable()`（= alive and not downed），不是 alive。
				if other == u or not other.is_attackable():
					continue
				if FactionRes.same_side_for_attack(other.faction, u.faction):
					continue
				# 距离减去目标体积：允许「半个身子进射程」的目标被发现
				var d: float = u.pos.distance_to(other.pos) - cfg.unit_radius_of(other.unit_type)
				if d <= aggro and d < best_d:
					best_d = d
					best = other

	if best != null:
		u.target = best
		# ★★ 参照点只在**这里**（真正锁定那一刻）设一次 —— 之后由
		#    `_refresh_leash_anchor()` 跟着目标往前挪。见 `unit.anchor` 与
		#    `_refresh_leash_anchor` 的说明（本轮修的「原地抽搐」就是这里原来写成了
		#    「每次索敌都重置」）。
		u.anchor = u.pos
		u.reset_repath()
		world.push_event({"type": "alert", "unit": u, "target": best})
		return true

	# 没有敌方单位 → 再看一眼敌方**建筑**（本次改动：从「只有玩家阵营」放开）
	#
	# ★★ 原来这一句是 `if not FactionRes.is_player_faction(u.faction): return false`
	#    —— 也就是**只有玩家阵营**才会自动索敌建筑，AI 阵营根本走不到下面那几行。
	#    实测报回来的现象正是它的后果：
	#      ·「我在敌方部队附近建造建筑，敌方不会有想打掉这个建筑」；
	#      ·「他只会让箭塔持续攻击自己」—— 被塔打也不还手，因为「建筑」这个目标类别
	#        对 AI 单位根本不存在。
	#
	# ⚠️ 唯一的例外是 `enemy_ai` 驱动的那一类**测试敌人**（`FactionRes.NPC_FACTION`
	#    且**没有驻防归属**）：它们的行为是「朝玩家据点一路推进」，路上顺手拆任何
	#    警戒半径内的建筑会把它钉在半路（实测：全局放开之后
	#    `test_logic` 的「敌人拆穿城墙后走进来并停在大本营旁」当场变红，
	#    因为它转头去拆旁边的别的建筑了）。那类单位的建筑目标仍然只由
	#    `enemy_ai` 明确指定（拆挡路的城墙）。
	#   ★ 有驻防归属的守军**不受这个例外影响**（它们是 `ai: "general"` 的驻防将领，
	#     由 general_ai 驱动）—— 用户要的「AI 对建筑有反应」正是它们。
	if u.faction == FactionRes.NPC_FACTION and not u.is_garrison():
		return false
	var b = nearest_enemy_building(world, cfg, u, aggro)
	if b == null:
		return false
	set_building_target(u, b)
	world.push_event({"type": "alert_building", "unit": u, "building": b})
	return true


## 警戒半径内最近的敌方建筑（距离按「到本体表面」算，与单位同口径）。
##
## ★★ 两类别索敌都跳过：
##   · **无主建筑**（owner == ""，例如区划中心）：它不是「敌方」，而是中立障碍 ——
##     不跳过的后果实测过：将军会自动跑去「拆」区划中心，指着它一路走（因为
##     拆不动、也打不掉，就永远停在那儿），玩家的移动命令看起来像失灵。
##   · **无敌建筑**（`is_invulnerable()`，同上那类）：打不掉的东西不该进目标列表。
static func nearest_enemy_building(world, cfg: ConfigRes, u: UnitRes, aggro: float) -> Variant:
	var best = null
	var best_d := INF
	# ★ 先用**格差**把远处的建筑挡掉：警戒半径只有几格，格差超过它就不可能命中。
	#   下面那几个判定（String(owner) / is_invulnerable() / center() / body_half()）
	#   每一个都比两次整数比较贵得多，而这是「每单位每建筑」都要跑一遍的循环
	#   （1000 单位待命时就是每帧几万次）。
	var reach := int(ceilf(aggro)) + 2
	for b in world.building_list:
		if not b.alive:
			continue
		if absi(b.tx - u.tx) > reach or absi(b.ty - u.ty) > reach:
			continue
		if String(b.owner) == "" or b.is_invulnerable():
			continue                      # 中立 / 无敌：不是可打的目标
		if FactionRes.same_side_for_attack(b.owner, u.faction):
			continue
		var d: float = u.pos.distance_to(b.center()) - b.body_half(cfg)
		if d <= aggro and d < best_d:
			best_d = d
			best = b
	return best


## 该不该为「走向 to_pos」重算一次路径？
##
## ★★ 这是行军攻击性能的关键。原来的条件是 `u.path.is_empty() or u.repath_timer <= 0.0`
##    —— 也就是**每 repath_sec 秒无条件重算一次**。1000 个单位追击时那是每秒 3000+ 次
##    完整寻路，而目标往往是**站着不动的**（墙、建筑、站定的单位），那些计算全是白费。
##    实测实机行军攻击因此掉到 49 ms/帧（20 fps）；更糟的是帧一慢 dt 就变大、
##    同一帧里 repath_timer 到期的单位成比例变多，形成正反馈。
##
## 现在两条路：
##   - 路径是空的（还没走 / 走完了 / 走不到）：按 repath_sec 限流重试。
##     ⚠️ 这一支必须保留周期限流：目标不可达时 move_to 会一直把 path 留空，
##        没有限流就成了每帧一次 A*。
##   - 已经有路径：只有**目标从上一次算路的位置挪出 repath_min_move 格**才重算。
##     目标不动 → 一次路走到底，零额外开销；目标在动 → 恰好是旧路开始失效的时候。
static func needs_repath(u: UnitRes, cfg: ConfigRes, to_pos: Vector2) -> bool:
	if u.repath_timer > 0.0:
		return false
	# 已经有路径，而目标没怎么动 → 旧路还是对的，不用重算。
	if not u.path.is_empty() and u.last_repath_to.distance_to(to_pos) <= cfg.repath_min_move:
		return false
	u.repath_timer = cfg.repath_sec
	u.last_repath_to = to_pos
	repath_calls += 1
	return true


## 有目标时每帧的决策：够得着 → 站住开火；够不着 → 先移动靠近（追击）；追太远 → 放弃
static func update_combat(world, cfg: ConfigRes, u: UnitRes) -> void:
	var t = u.target
	# ★★ `not t.is_attackable()` 覆盖两种「这个目标不该再打了」：
	#   · 目标阵亡（老行为，用 alive）；
	#   · ★ 目标**刚进濒死**（本轮新增）—— 需求明确「濒死期间无法被选中为攻击对象」，
	#     所以已经锁定它的单位要当场脱战，否则它会一路走到那个打不动的人身上站着。
	if t == null or not t.is_attackable() or t == u:
		# ⚠️ 用 drop_engagement 而不是 clear_target：行军攻击要能在打完一个之后继续走。
		#    只有「玩家点名的那个目标」才连命令一起清掉（命令已经完成了）。
		if u.ordered_target == t:
			u.ordered_target = null
		u.drop_engagement()
		return

	var reach: float = u.combat_range(cfg) + cfg.unit_radius_of(t.unit_type)
	var d: float = u.pos.distance_to(t.pos)

	if d <= reach:                    # 进入攻击距离：站住打
		u.halt()
		# 朝向指向目标（八方向下是完整向量，不再只有左右）
		face_toward(u, t.pos)
		# ★★ 已经贴上目标 ⇒ 这一段追击结束了，把参照点推到**目标身上**
		#    （跟着打、目标边走边追时，leash 量的是「我掉队多远」而不是「我跑了多远」）。
		_refresh_leash_anchor(u, cfg, t.pos)
		if u.attack_cd <= 0.0:
			attack_unit(world, cfg, u, t)
		return

	# 脱离：目标已经跑到「警戒起点」的追击上限之外
	# ★ 例外：玩家点名的目标（右键点敌人）不受这条约束 —— 那是玩家的命令，不是它自己追出去的。
	if u.ordered_target == null and u.anchor != null and u.pos.distance_to(u.anchor) > u.leash_range(cfg):
		u.drop_engagement()
		# ★★ 放弃之后**拉一段冷却**（本轮修 bug）：不拉的话下一帧又会把还在警戒半径里的
		#    同一个目标锁上，而锁定那一刻距离参照点是 0 ⇒ 再走一格又放弃 …… 原地抽搐。
		#    见 config 的 `combat.leash_release_cd` 与 `combat.acquire_target` 里那一句。
		u.leash_cd = cfg.leash_release_cd
		return

	# 先移动靠近。目标一直在动，但**只有它真挪了地方**才重算路径（见 needs_repath）
	if needs_repath(u, cfg, t.pos):
		# ★★ 参照点跟着目标往前挪（先于这一步：它的节流判据就是「目标挪过地方了没」）。
		_refresh_leash_anchor(u, cfg, t.pos)
		# ★★ settle = false：追击不需要「落点空位」。
		#    落点就是敌人脚下那格，必然被判为拥挤，于是每次寻路都白跑一遍
		#    _find_arrival_slot（全图可达掩码 + 十几个候选点各扫 1000 个单位 ≈ 226 µs）。
		#    1000 个单位同帧首次锁定目标 → 一帧几百次 → **200+ ms 单帧卡顿**。
		#    另外走 chase_to 而不是 move_to：近距离追击用不着距离场与拉直（见它的注释）。
		u.chase_to(world, cfg, t.pos)


## ★★ 把「追击参照点」`anchor` 跟着目标往前挪（本轮修 bug）。
##
## 为什么必须有它（实测报回来的现象：「单位在区划边界要追击的敌方单位会在原地抽搐」）：
##   参照点原来只在**锁定那一刻**设一次、之后永不更新 ⇒ 追击上限量的其实是
##   「我离（当时站的那个位置）有多远」—— 这是一个**恒真的判据**：
##   一旦追出 `aggro_range × leash_factor`，之后就永远是「超了」，
##   于是每一帧都在「锁定 → 走一格 → 超上限 → 放弃 → 下一帧又锁上」之间打转。
##   （区划边界最容易看到：驻防将领正好在那条线上被 `general_ai` 叫回、又被重新锁定。）
##
## 改法：把参照点更新成**目标当前所在的位置**，于是判据变成
##   「我离**当前这一轮追击的起点**有多远」= 「我掉队掉了多远」——
##   这正是追击上限本来要表达的意思（追出去太远就回家），而且**目标不动时行为完全不变**
##   （目标不动 ⇒ 这条判据永不通过 ⇒ 参照点永不更新 ⇒ 与从前逐位一致）。
##
## ⚠️ 节流用 `repath_timer`：它与 `needs_repath()` 的判据同源（「目标挪过地方了没」），
##    所以既不会每帧更新（便宜），也不会在目标慢慢挪时永远不更新。
##    `repath_timer` 在 `update_unit` 里每帧递减，`needs_repath()` 命中时会把它重置成
##    `cfg.repath_sec`，所以刚算过的一次不会再更新 —— 那是对的（那一刻参照点刚挪过）。
##
## @param to_pos 目标**现在**所在的位置
static func _refresh_leash_anchor(u: UnitRes, cfg: ConfigRes, to_pos: Vector2) -> void:
	if u.anchor == null:
		return                            # 玩家点名的目标：锚点为空 = 不受追击上限约束
	if u.repath_timer > 0.0:
		return
	if u.anchor.distance_squared_to(to_pos) < cfg.repath_min_move * cfg.repath_min_move:
		return
	u.anchor = to_pos


## 让单位朝向某个点（八方向之后朝向是完整向量，所以要单独一个函数）。
## 目标与自己在同一位置时保持原朝向，避免把 facing 归一化成零向量。
static func face_toward(u: UnitRes, to_pos: Vector2) -> void:
	var d: Vector2 = to_pos - u.pos
	if d.length() < 1e-6:
		return
	u.facing = d.normalized()
	u.last_dir = u.facing


## 开火：单体伤害 + 冷却
static func attack_unit(world, cfg: ConfigRes, u: UnitRes, t: UnitRes) -> void:
	u.attack_cd = maxf(0.05, u.combat_cooldown(cfg))
	u.attack_flash = 1.0
	u.last_target = t
	u.last_building = null
	t.take_damage(cfg, world, u.combat_damage(cfg), u)


## 锁定一个建筑开始拆它（敌人 AI 用它拆挡路的城墙）。
## 这里只负责「记下来」，靠近与开火交给 update_building_combat()。
static func set_building_target(u: UnitRes, b) -> bool:
	if b == null or not b.alive:
		return false
	u.target_building = b
	u.target = null
	u.anchor = null
	u.reset_repath()
	return true


## 拆建筑：**先移动靠近，进入攻击距离后再打**（和打单位一样的手感）。
## 建筑的本体是**居中、略小于一格**的，所以「够得着」要按本体半边长来算 ——
## 城墙 body_half = 0.5（与从前逐位一致），大本营 / 箭塔 0.3。
static func update_building_combat(world, cfg: ConfigRes, u: UnitRes) -> void:
	var b = u.target_building
	if b == null or not b.alive:
		# 拆完了（或目标没了）：玩家点名的那个命令就算完成了；
		# 行军攻击则继续走（drop_engagement 不动 has_attack_move）。
		if u.ordered_building == b:
			u.ordered_building = null
		u.drop_engagement()
		return

	var c: Vector2 = b.center()
	var reach: float = u.combat_range(cfg) + b.body_half(cfg)
	var d: float = u.pos.distance_to(c)

	if d <= reach:                    # 够得着：站住拆
		u.halt()
		face_toward(u, c)
		if u.attack_cd <= 0.0:
			attack_building(world, cfg, u, b)
		return

	# 够不着：朝建筑走（move_to 会发现该格不可通行 → 自动改走到贴墙的可达格）
	# ★ 建筑永远不动，所以 needs_repath 里的「目标没挪地方」这条会一直成立 ——
	#   第一次算完就不再重算，只有路径走空（走不到）时按周期重试。
	if needs_repath(u, cfg, c):
		u.move_to(world, cfg, c)


## 拆建筑的一击：墙体不反击，所以只需要冷却 + 伤害；
## 打光后**立刻记下事件**（由 world.tick() 末尾统一收尸 —— 逻辑层不在遍历中改集合）
static func attack_building(world, cfg: ConfigRes, u: UnitRes, b) -> void:
	if b == null or not b.alive:
		u.target_building = null          # 已经塌了就别再对着空气拆
		return
	u.attack_cd = maxf(0.05, u.combat_cooldown(cfg))
	u.attack_flash = 1.0
	u.last_building = b
	u.last_target = null
	# ⚠️ 拆建筑用的伤害是**共用的** combat.building_damage（40），不是该单位打人的伤害。
	#    节奏仍沿用该单位自己的 cooldown（敌人 40/1.2s ≈ 33 dps，一堵 300 血的墙约 9.6 秒）
	#
	# ⚠️ take_damage 返回的是「**本击是否造成摧毁**」，所以这里只在首次摧毁时广播。
	#    否则同一帧里几个单位围着同一堵墙，会广播出好几条重复的 building_down。
	if b.take_damage(cfg, cfg.building_damage, u):
		world.push_event({"type": "building_down", "building": b, "source": u})


## 会攻击的建筑（箭塔，以及编辑器里新加的任何 `attackable = true` 的建筑）开火：
## 对射程内**最近的敌人**造成单体伤害。
##
## ★★ 判据从「type == "tower"」改成 config 的 `attackable`（本轮）：
##    原来写死 tower，于是设计师在编辑器里加一栋「炮塔」永远打不出伤害 ——
##    一个改了没用的字段。伤害 / 射程 / 间隔也改成按**当前等级**取
##    （见 building.attack_damage 与 cfg.building_attack_of）。
## ★ 建造读条中的建筑**不开火**（b.is_under_construction()）：它还没有战斗力。
##
## ★ 索敌走「攻击口径的同一方」（`same_side_for_attack` = 同阵营 **或盟友**），
##   **不要**写成 `u.faction == b.owner`：
##   HTML 版的箭塔就是这么写的，偏离了它自己声明的规则 —— 单人下行为等价，
##   但一旦引入结盟/组队就会变成「箭塔打队友」（见 docs/pitfalls.md 3.7）。
##   ★ 这一行就是那句预言的落点：加了阵营归属（盟友）之后，两方的箭塔不再互射。
static func update_towers(world, cfg: ConfigRes, dt: float) -> void:
	for b in world.building_list:
		if not b.alive:
			continue
		if not b.is_attackable(cfg):
			continue
		if b.is_under_construction():
			continue                       # ★ 还在建造：这一栋先不开火
		if b.cooldown_left > 0.0:
			b.cooldown_left = maxf(0.0, b.cooldown_left - dt)

		var range_tiles: float = b.attack_range(cfg)
		# 允许打到「半个身子进射程」的敌人：用**被瞄准的具体单位**的半径，
		# 而不是写死某一种类型 —— 各单位类型的半径不同（骑兵最大、长弓兵最小），写死会让射程口径不一致。
		var target = null
		var best_d := INF
		for u in world.units:
			# ★ 濒死的将领不在箭塔的目标列表里（需求：不会受到任何伤害）。
			if not u.is_attackable():
				continue
			if FactionRes.same_side_for_attack(u.faction, b.owner):
				continue
			var d: float = b.center().distance_to(u.pos)
			if d <= range_tiles + cfg.unit_radius_of(u.unit_type) and d < best_d:
				best_d = d
				target = u
		b.last_target = target

		if target != null and b.cooldown_left <= 0.0:
			target.take_damage(cfg, world, b.attack_damage(cfg), b)
			b.cooldown_left = b.attack_cooldown(cfg)
			b.flash = 1.0


## 建筑受击闪光的衰减（只有渲染用；每帧一次，覆盖所有建筑）
static func update_building_effects(world, dt: float) -> void:
	for b in world.building_list:
		if b.flash > 0.0:
			b.flash = maxf(0.0, b.flash - dt * 4.0)
