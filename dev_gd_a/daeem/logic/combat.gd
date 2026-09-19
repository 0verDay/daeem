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


## 每帧推进一个单位的攻击冷却 / 特效计时，并决定它这一帧干什么。
static func update_unit(world, cfg: ConfigRes, u, dt: float) -> void:
	if u.attack_cd > 0.0:
		u.attack_cd = maxf(0.0, u.attack_cd - dt)
	if u.attack_flash > 0.0:
		u.attack_flash = maxf(0.0, u.attack_flash - dt / maxf(0.01, cfg.flash_sec))
	if u.repath_timer > 0.0:
		u.repath_timer = maxf(0.0, u.repath_timer - dt)

	# 己方单位站在**己方**领地内缓慢回血（便于肉眼确认领地归属是否生效）
	# ★ 用 u.faction 比对，而不是写死 'player' —— 联机下「己方领地」= 自己那一方的区块
	if FactionRes.is_player_faction(u.faction):
		var z = world.zones.zone_at(u.tx, u.ty)
		if z != null and z.owner == u.faction and u.hp < u.hp_max:
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
			acquire_target(world, cfg, u)
		if u.target != null:
			update_combat(world, cfg, u)
		elif u.target_building != null:
			update_building_combat(world, cfg, u)
		elif u.has_attack_move and not u.moving:
			# ★ 行军攻击：打完了（或被打断）还没到点 → 接着走。
			if u.pos.distance_to(u.attack_move_goal) <= 0.5:
				u.has_attack_move = false          # 到了，命令完成
			#   ⚠️ 用 repath_timer 限流：走不到的时候（目标点被封）不能每帧算一次 A*。
			elif u.repath_timer <= 0.0:
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
static func acquire_target(world, cfg: ConfigRes, u) -> bool:
	if not cfg.combat_enabled:
		return false
	var aggro: float = u.aggro_range(cfg)
	if aggro <= 0.0:
		return false

	var best = null
	var best_d := INF
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
		u.repath_timer = 0.0
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


## 警戒半径内最近的敌方建筑（距离按「到本体表面」算，与单位同口径）
static func nearest_enemy_building(world, cfg: ConfigRes, u, aggro: float) -> Variant:
	var best = null
	var best_d := INF
	for b in world.building_list:
		if not b.alive:
			continue
		if FactionRes.same_side(b.owner, u.faction):
			continue
		var d: float = u.pos.distance_to(b.center()) - b.body_half(cfg)
		if d <= aggro and d < best_d:
			best_d = d
			best = b
	return best


## 有目标时每帧的决策：够得着 → 站住开火；够不着 → 先移动靠近（追击）；追太远 → 放弃
static func update_combat(world, cfg: ConfigRes, u) -> void:
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

	# 先移动靠近。目标一直在动，所以隔 repath_sec 重新寻路一次，而不是每帧重算
	if u.path.is_empty() or u.repath_timer <= 0.0:
		u.repath_timer = cfg.repath_sec
		u.move_to(world, cfg, t.pos)


## 让单位朝向某个点（八方向之后朝向是完整向量，所以要单独一个函数）。
## 目标与自己在同一位置时保持原朝向，避免把 facing 归一化成零向量。
static func face_toward(u, to_pos: Vector2) -> void:
	var d: Vector2 = to_pos - u.pos
	if d.length() < 1e-6:
		return
	u.facing = d.normalized()
	u.last_dir = u.facing


## 开火：单体伤害 + 冷却
static func attack_unit(world, cfg: ConfigRes, u, t) -> void:
	u.attack_cd = maxf(0.05, u.combat_cooldown(cfg))
	u.attack_flash = 1.0
	u.last_target = t
	u.last_building = null
	t.take_damage(cfg, world, u.combat_damage(cfg), u)


## 锁定一个建筑开始拆它（敌人 AI 用它拆挡路的城墙）。
## 这里只负责「记下来」，靠近与开火交给 update_building_combat()。
static func set_building_target(u, b) -> bool:
	if b == null or not b.alive:
		return false
	u.target_building = b
	u.target = null
	u.anchor = null
	u.repath_timer = 0.0
	return true


## 拆建筑：**先移动靠近，进入攻击距离后再打**（和打单位一样的手感）。
## 建筑的本体是**居中、略小于一格**的，所以「够得着」要按本体半边长来算 ——
## 城墙 body_half = 0.5（与从前逐位一致），大本营 / 箭塔 0.3。
static func update_building_combat(world, cfg: ConfigRes, u) -> void:
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
	if u.path.is_empty() or u.repath_timer <= 0.0:
		u.repath_timer = cfg.repath_sec
		u.move_to(world, cfg, c)


## 拆建筑的一击：墙体不反击，所以只需要冷却 + 伤害；
## 打光后**立刻记下事件**（由 world.tick() 末尾统一收尸 —— 逻辑层不在遍历中改集合）
static func attack_building(world, cfg: ConfigRes, u, b) -> void:
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
		var pad: float = cfg.unit_radius_of("enemy")   # 允许打到「半个身子进射程」的敌人
		var target = null
		var best_d := INF
		for u in world.units:
			if not u.alive:
				continue
			if FactionRes.same_side(u.faction, b.owner):
				continue
			var d: float = b.center().distance_to(u.pos)
			if d <= range_tiles + pad and d < best_d:
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
