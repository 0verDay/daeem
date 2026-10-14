## morale.gd —— ★★ 士气：整支部队共享的回血 / 掉血 / 免伤 / 易伤，与区划和战斗联动
##
## 需求（原话拆解）：
##   · 士气是**单位属性**、初始上限 100、初始值 90；
##   · ≥100：快速回复生命 + 远近免伤；≥90：缓慢回复生命；
##   · ≤50：远近易伤（50 以下的各档继续保留该效果）；
##   · ≤25：缓慢失去生命；==0：快速失去生命 —— 两者都**不致死**，血量止于极小值（hp_floor）；
##   · 区划联动：进己方/友方区划 → 缓慢上升；敌方区划 / 被包围的己方区划 → 「疲惫」缓慢下降；
##   · 破敌 / 斩将 / 掠地 → 士气立即上升。
##
## ★★ 「整支部队共享一个值」怎么落地（关键设计，别绕）：
##   这份代码里**没有 Squad 类**（队伍是算出来的，见 world.group_of）。于是把士气也做成
##   「**锚**持有权威值 + 队员镜像」：锚 = 队长（`world.team_leader`）；没有存活队长
##   （自己是队长 / 队长已阵亡 / 前提是测试敌人）时，自己当锚。
##   每帧 `tick_unit`：锚自己按区划算升降、吃生命档位；队员只做 `morale = 锚.morale`。
##   ⇒ 同一支部队里每个单位读到的 morale 都一样，详情栏画出来自然一致。
##
## ★ 作用范围 = 场上**所有**单位（含 AI / 敌方），所以这里不做任何阵营过滤。
## ★ 受到的伤害系数（免伤 / 易伤）**不在这里**：它在 `unit.take_damage` 里内联
##   （那里是近战 + 远程两条路的唯一收口，见 logic/unit.gd 那段注释）。
extends RefCounted

const FactionRes = preload("res://logic/faction.gd")


## 这个单位的**锚**（持有权威士气的那个单位）：有存活队长 → 队长，否则自己。
static func anchor_of(world, u):
	if u == null:
		return null
	if world == null:
		return u
	var leader = world.team_leader(u)      # 没有队长 / 队长已阵亡 → null
	return leader if leader != null else u


## ★★ 每帧推进一个单位的士气（**唯一入口**，由 combat.update_unit 调用）。
## 锚：按所在区划升降士气 + 吃生命档位；队员：镜像锚的值。
static func tick_unit(world, cfg, u, dt: float) -> void:
	if u == null or not u.alive:
		return
	var anchor = anchor_of(world, u)
	if anchor != u:
		# 队员：镜像锚的权威值（区划升降只由锚算一次）
		u.morale = anchor.morale
		u.morale_max = anchor.morale_max
	else:
		# 锚：按所在区划升降
		var rate := 0.0
		if world != null and world.zones != null:
			var z = world.zones.zone_at(u.tx, u.ty)
			var owner := "" if z == null else String(z.get("owner", ""))
			if z != null and owner != "" and FactionRes.same_side_for_attack(owner, u.faction):
				# 己方 / 友方区划：被包围（不与大本营区划连通）时改判「疲惫」
				rate = -cfg.morale_decay_surrounded if world.zone_is_surrounded(int(z["id"])) \
					else cfg.morale_regen_ally
			else:
				# ★ 敌方区划**与中立区划**都算「疲惫」（中立也缓慢掉士气）。
				rate = -cfg.morale_decay_enemy
		u.morale = clampf(u.morale + rate * dt, 0.0, u.morale_max)

	# ★★ 生命档位对**每个单位**都生效（不只锚）：士气是整支部队共享的，
	#    就该整支部队一起回血 / 掉血 —— 只给锚上档位的话，只有将领一个人动血（实测踩到）。
	_apply_hp_tiers(cfg, u, dt)


## 生命档位（回血 / 掉血）。★ 只增到 hp_max、只减到 hp_floor —— **不触发死亡**。
static func _apply_hp_tiers(cfg, u, dt: float) -> void:
	if u.morale >= cfg.morale_high_tier:
		u.hp = minf(u.hp_max, u.hp + cfg.morale_hp_regen_high * dt)
	elif u.morale >= cfg.morale_mid_tier:
		u.hp = minf(u.hp_max, u.hp + cfg.morale_hp_regen_mid * dt)
	if u.morale <= 0.0:
		u.hp = maxf(cfg.morale_hp_floor, u.hp - cfg.morale_hp_decay_zero * dt)
	elif u.morale <= cfg.morale_low_tier:
		u.hp = maxf(cfg.morale_hp_floor, u.hp - cfg.morale_hp_decay_low * dt)


## 把锚的士气**立刻**推给队员（加成是瞬时事件，别等下一帧镜像）。
static func sync_members(world, anchor) -> void:
	if world == null or anchor == null:
		return
	for m in world.retinue_of(anchor.id):
		m.morale = anchor.morale
		m.morale_max = anchor.morale_max


## 破敌 / 斩将：击杀者所在部队士气立即上升（杀将领加得更多）。
##   @param dead   被击杀的单位；@param source 击杀者（可能是 null —— 建筑被拆等）。
static func boost_kill(world, cfg, dead, source) -> void:
	if world == null or dead == null or source == null:
		return
	if not source.alive:
		return
	# 只认「击败敌方」：同一边不算
	if FactionRes.same_side_for_attack(String(source.faction), String(dead.faction)):
		return
	var amount: float = cfg.morale_boost_leader if dead.is_general() else cfg.morale_boost_kill
	var anchor = anchor_of(world, source)
	if anchor == null:
		return
	anchor.morale = clampf(anchor.morale + amount, 0.0, anchor.morale_max)
	sync_members(world, anchor)


## 掠地：区划转为「己方/友方」时，站在该区划里、与新区主同一边的单位所在部队士气上升。
## ★ 同一支部队只加一次（否则一个队员一份会重复加）。
static func boost_capture(world, cfg, zone) -> void:
	if world == null or zone == null:
		return
	var owner := String(zone.get("owner", ""))
	if owner == "":
		return
	var anchors: Dictionary = {}
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side_for_attack(owner, String(u.faction)):
			continue
		if not _in_zone(world, u, zone):
			continue
		var a = anchor_of(world, u)
		if a != null:
			anchors[a.id] = a
	for id in anchors:
		var a = anchors[id]
		a.morale = clampf(a.morale + cfg.morale_boost_capture, 0.0, a.morale_max)
		sync_members(world, a)


## 这个单位现在站不站在给定区划里（按区划 id 比）。
static func _in_zone(world, u, zone) -> bool:
	if world == null or world.zones == null:
		return false
	var z2 = world.zones.zone_at(u.tx, u.ty)
	if z2 == null:
		return false
	return int(z2.get("id", -1)) == int(zone.get("id", -2))
