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
	if u.attack_cd > 0.0:
		u.attack_cd = maxf(0.0, u.attack_cd - dt)
	if u.attack_flash > 0.0:
		u.attack_flash = maxf(0.0, u.attack_flash - dt / cfg.flash_sec_safe)
	if u.repath_timer > 0.0:
		u.repath_timer = maxf(0.0, u.repath_timer - dt)

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


## 警戒：静止且没有目标的单位搜索警戒半径内的敌方**单位**，锁定最近的一个。
##
## 搜不到敌方单位时，**玩家阵营**的单位会再搜一次**敌方建筑**（需求：
## 「给己方单位增加索敌建筑的机制」）—— 走到对家箭塔/城墙边上就会自己开打。
## ⚠️ NPC 敌人不做这一步：它们拆建筑由 enemy_ai 明确指定（拆挡路的城墙），
##    否则「路过一堵墙就停下来拆」会把敌人推进的节奏彻底改掉。
static func acquire_target(world, cfg: ConfigRes, u: UnitRes, idx: int = -1) -> bool:
	if not cfg.combat_enabled:
		return false
	# ★ 直接读 cfg 上的字段而不是走 u.aggro_range(cfg)：那是每单位每帧一次的方法调用
	var aggro: float = cfg.aggro_range
	if aggro <= 0.0:
		return false

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
	if idx >= 0 and crowd != null and crowd._targets_ready \
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
		if best != null and FactionRes.same_side(String(best.faction), String(u.faction)):
			best = null

	if not used_kernel:
		for other in world.units:
			if other == u or not other.alive:
				continue
			if FactionRes.same_side(other.faction, u.faction):
				continue
			# 距离减去目标体积：允许「半个身子进射程」的目标被发现
			var d: float = u.pos.distance_to(other.pos) - cfg.unit_radius_of(other.kind)
			if d <= aggro and d < best_d:
				best_d = d
				best = other

	if best != null:
		u.target = best
		u.anchor = u.pos                  # 从这里开始算「追出去多远」
		u.reset_repath()
		world.push_event({"type": "alert", "unit": u, "target": best})
		return true

	# 没有敌方单位 → 玩家阵营再看一眼敌方建筑
	if not FactionRes.is_player_faction(u.faction):
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
		if FactionRes.same_side(b.owner, u.faction):
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
	if t == null or not t.alive or t == u:
		# ⚠️ 用 drop_engagement 而不是 clear_target：行军攻击要能在打完一个之后继续走。
		#    只有「玩家点名的那个目标」才连命令一起清掉（命令已经完成了）。
		if u.ordered_target == t:
			u.ordered_target = null
		u.drop_engagement()
		return

	var reach: float = u.combat_range(cfg) + cfg.unit_radius_of(t.kind)
	var d: float = u.pos.distance_to(t.pos)

	if d <= reach:                    # 进入攻击距离：站住打
		u.halt()
		# 朝向指向目标（八方向下是完整向量，不再只有左右）
		face_toward(u, t.pos)
		if u.attack_cd <= 0.0:
			attack_unit(world, cfg, u, t)
		return

	# 脱离：目标已经跑到「警戒起点」的追击上限之外
	# ★ 例外：玩家点名的目标（右键点敌人）不受这条约束 —— 那是玩家的命令，不是它自己追出去的。
	if u.ordered_target == null and u.anchor != null and u.pos.distance_to(u.anchor) > u.leash_range(cfg):
		u.drop_engagement()
		return

	# 先移动靠近。目标一直在动，但**只有它真挪了地方**才重算路径（见 needs_repath）
	if needs_repath(u, cfg, t.pos):
		# ★★ settle = false：追击不需要「落点空位」。
		#    落点就是敌人脚下那格，必然被判为拥挤，于是每次寻路都白跑一遍
		#    _find_arrival_slot（全图可达掩码 + 十几个候选点各扫 1000 个单位 ≈ 226 µs）。
		#    1000 个单位同帧首次锁定目标 → 一帧几百次 → **200+ ms 单帧卡顿**。
		#    另外走 chase_to 而不是 move_to：近距离追击用不着距离场与拉直（见它的注释）。
		u.chase_to(world, cfg, t.pos)


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


## 箭塔开火：对射程内**最近的敌人**造成单体伤害。
##
## ★ 索敌用 `same_side`，**不要**写成 `u.faction == b.owner`：
##   HTML 版的箭塔就是这么写的，偏离了它自己声明的规则 —— 单人下行为等价，
##   但一旦引入结盟/组队就会变成「箭塔打队友」（见 docs/pitfalls.md 3.7）。
static func update_towers(world, cfg: ConfigRes, dt: float) -> void:
	for b in world.building_list:
		if not b.alive or b.type != "tower":
			continue
		if b.cooldown_left > 0.0:
			b.cooldown_left = maxf(0.0, b.cooldown_left - dt)

		var range_tiles: float = b.tower_range(cfg)
		# 允许打到「半个身子进射程」的敌人：用**被瞄准的具体单位**的半径，
		# 而不是写死 enemy —— 亲兵比将领小，写死会让射程口径不一致。
		var target = null
		var best_d := INF
		for u in world.units:
			if not u.alive:
				continue
			if FactionRes.same_side(u.faction, b.owner):
				continue
			var d: float = b.center().distance_to(u.pos)
			if d <= range_tiles + cfg.unit_radius_of(u.kind) and d < best_d:
				best_d = d
				target = u
		b.last_target = target

		if target != null and b.cooldown_left <= 0.0:
			target.take_damage(cfg, world, b.tower_damage(cfg), b)
			b.cooldown_left = b.tower_cooldown(cfg)
			b.flash = 1.0


## 建筑受击闪光的衰减（只有渲染用；每帧一次，覆盖所有建筑）
static func update_building_effects(world, dt: float) -> void:
	for b in world.building_list:
		if b.flash > 0.0:
			b.flash = maxf(0.0, b.flash - dt * 4.0)
