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


## ★★ 2026.10.27：**整遍士气结算**（`world.tick` 在单位循环之前调一次）。
##
## ★ 为什么从"逐单位"改成"一整遍"：见 `combat.update_unit` 里那段说明 ——
##   ① 它全是逐单位的查表 + 算术，**能整段下沉到 C#**（`logic/unit/UnitMoraleKernel.cs`）；
##   ② 批量要求它不与战斗交替：交错着算的话只能逐单位跨语言调用，开销反而更大。
## ★ 语义：所有单位在同一时刻结算士气 / 回复，再统一结算战斗（不再依赖遍历顺序）。
static func tick_all(world, cfg, dt: float) -> void:
	if world == null or cfg == null or dt <= 0.0:
		return
	# ★★ 2026.10.29：**濒死将领先结算**。它是整队的士气锚 —— 队员在本帧要镜像
	#    它这一帧的值（先算锚、再算队员，与下标顺序无关）。
	#    ⚠️ 这一步必须在 C# 分支之前：内核里濒死单位是 skip 的，它只会读输入里的
	#       士气；不先把它算好，队员就会镜像上一帧（或 0，见 `_tick_all_csharp`）。
	for u in world.units:
		if u != null and u.alive and u.is_downed():
			tick_downed_leader(world, cfg, u, dt)
	if String(cfg.unit_sim_backend) == "csharp":
		var k = _get_kernel()
		if k != null and _tick_all_csharp(k, world, cfg, dt):
			world.unit_sim_used = "csharp(morale)"
			return
	# ── GDScript 回退（逐单位，与重构前逐位一致）──
	for u in world.units:
		if u == null or not u.alive:
			continue
		# ★★ **濒死的将领不吃常规士气 / 回血档位** —— 它这一帧只跑「濒死状态机」
		#    （`unit.tick_near_death`，由 `combat.update_unit` 的第一句接管）。
		#    士气下降已经在上面 `tick_downed_leader()` 里单独结算过；这里跳过，
		#    否则「濒死缓慢回复」会和「士气回血」叠加成双倍回复。
		if u.is_downed():
			continue
		tick_unit(world, cfg, u, dt)


## ★★ C# 内核（`logic/unit/UnitMoraleKernel.cs`）。加载不到（普通版 Godot）时为 null，
##    自动退回上面的 GDScript 逐单位实现 —— 与 fog / crowd 的回退是同一条约定。
const KERNEL_PATH := "res://logic/unit/UnitMoraleKernel.cs"
static var _kernel = null
static var _kernel_tried: bool = false


static func _get_kernel():
	if not _kernel_tried:
		_kernel_tried = true
		var s = load(KERNEL_PATH)
		if s != null:
			_kernel = s.new()
	return _kernel


## 整帧一次调用：把 n 个单位压成几条 Packed 数组 → 内核算 → 写回。
## @return true = 走了内核；false = 环境不满足（调用方回退 GDScript）。
##
## ★ 组包 / 写回的开销实测约 0.2~0.3 ms / 256 单位，所以这一刀只值 ~0.3 ms ——
##   真正的收益要等**整段 `update_unit`** 也搬过去（那时组包只发生一次、而不是每个子系统一次）。
##   这一块先落地是为了把「开关 + 等价测试 + 数组接口」这条流水线跑通。
static func _tick_all_csharp(k, world, cfg, dt: float) -> bool:
	var units: Array = world.units
	var n: int = units.size()
	if n <= 0:
		return true
	var zones = world.zones
	if zones == null or world.map == null:
		return false
	var cols: int = int(world.map.cols)
	var rows: int = int(world.map.rows)
	var zone_of_tile: PackedInt32Array = zones.lookup
	if zone_of_tile.size() != cols * rows:
		return false

	# ── 方编号表：阵营 id → 方编号（同方 = 同一个编号，与 same_side_for_attack 同口径）──
	var side_ids: Dictionary = {}
	for f in world.factions:
		var s := String(FactionRes.side_of(String(f)))
		if not side_ids.has(s):
			side_ids[s] = side_ids.size()
	var fac_side: Dictionary = {}
	for f in world.factions:
		var fid := String(f)
		fac_side[fid] = int(side_ids.get(String(FactionRes.side_of(fid)), -1))
	# ── 区划表（按 zone id 索引；id 允许跳号）──
	var max_id := -1
	for z in zones.zones:
		max_id = maxi(max_id, int((z as Dictionary)["id"]))
	var zone_owner_side := PackedInt32Array()
	var zone_surrounded := PackedByteArray()
	if max_id >= 0:
		zone_owner_side.resize(max_id + 1)
		zone_owner_side.fill(-1)
		zone_surrounded.resize(max_id + 1)
		zone_surrounded.fill(0)
	for z2 in zones.zones:
		var zz: Dictionary = z2
		var zid2 := int(zz["id"])
		var owner := String(zz.get("owner", ""))
		zone_owner_side[zid2] = int(fac_side.get(owner, -1)) if owner != "" else -1
		zone_surrounded[zid2] = 1 if world.zone_is_surrounded(zid2) else 0

	# ── 单位 → 下标索引（队员要找到队长的**下标**）──
	var idx_by_id: Dictionary = {}
	for i in n:
		idx_by_id[String(units[i].id)] = i

	var skip := PackedByteArray()
	var anchor := PackedInt32Array()
	var mo := PackedFloat64Array()
	var mo_max := PackedFloat64Array()
	var hp := PackedFloat64Array()
	var hp_max := PackedFloat64Array()
	var tile := PackedInt32Array()
	var side := PackedInt32Array()
	var aura := PackedFloat64Array()
	skip.resize(n)
	anchor.resize(n)
	mo.resize(n)
	mo_max.resize(n)
	hp.resize(n)
	hp_max.resize(n)
	tile.resize(n)
	side.resize(n)
	aura.resize(n)
	var has_aura: bool = not world.morale_aura_bonus.is_empty()
	# ★★ 2026.10.29：断粮惩罚也走**同一个 `aura` 列**（它是「每单位额外的士气速率修正」），
	#    这样 C# 内核一行都不用改、两条后端天然等价（见 `_zone_morale_rate` 的同一条口径）。
	var has_starve: bool = not world.starving_factions.is_empty()
	for i in n:
		var u = units[i]
		anchor[i] = i
		if u == null or not u.alive:
			skip[i] = 1
			continue
		# ★★ 2026.10.29：**先填士气**，再判「这一位要不要跳过」。
		#    濒死将领在核心里是 skip（不写回），但它的**队员要镜像它的士气** ——
		#    以前在 skip 之后才填 `mo[i]`，濒死 / 已阵亡队长的 `mo` 永远是 0，
		#    队员整队士气会瞬间归零（用户报的「主将死后士气掉得很快」）。
		mo[i] = u.morale
		mo_max[i] = u.morale_max
		hp[i] = u.hp
		hp_max[i] = u.hp_max
		if u.is_downed():
			skip[i] = 1
			continue
		tile[i] = int(u.ty) * cols + int(u.tx)
		side[i] = int(fac_side.get(String(u.faction), -1))
		if has_aura or has_starve:
			var extra: float = float(world.morale_aura_bonus.get(u.id, 0.0))
			if has_starve and world.is_starving(String(u.faction)):
				extra -= cfg.morale_starve_drain
			aura[i] = extra
		if u.leader_id != "":
			var lead: Variant = idx_by_id.get(String(u.leader_id), null)
			# ★ 只锚到**还活着**的队长，与 GDScript 的 `team_leader()` 同口径：
			#   阵亡队长已经不在队里（`team_leader` 返回 null），不能再让队员镜像 0。
			if lead != null:
				var lu = units[int(lead)]
				if lu != null and lu.alive:
					anchor[i] = int(lead)

	var out: PackedFloat64Array = k.Tick(skip, anchor, mo, mo_max, hp, hp_max,
		tile, side, aura, zone_of_tile, zone_owner_side, zone_surrounded, dt,
		cfg.morale_regen_ally, cfg.morale_decay_enemy, cfg.morale_decay_surrounded,
		cfg.morale_high_tier, cfg.morale_mid_tier, cfg.morale_low_tier,
		cfg.morale_hp_regen_high, cfg.morale_hp_regen_mid, cfg.morale_hp_floor,
		cfg.morale_hp_decay_zero, cfg.morale_hp_decay_low)
	if out.size() != 2 * n:
		return false
	# ── 写回（跳过的单位不动）──
	for i2 in n:
		if skip[i2] != 0:
			continue
		var u2 = units[i2]
		u2.morale = out[i2]
		u2.hp = out[n + i2]
	return true



## ★★ 每帧推进一个单位的士气（**唯一入口**，由 combat.update_unit 调用）。
## 锚：按所在区划升降士气 + 吃生命档位；队员：镜像锚的值。
static func tick_unit(world, cfg, u, dt: float) -> void:
	if u == null or not u.alive:
		return
	# ★★ 2026.10.29：濒死将领（整队的锚）只跑「主将倒地」这一套：
	#    常规区划速率 + 粮车光环 - 固定下降；**不碰生命档位**（HP 回复由
	#    `unit.tick_near_death` 独占，见那里的说明）。
	if u.is_downed():
		tick_downed_leader(world, cfg, u, dt)
		return
	var anchor = anchor_of(world, u)
	if anchor != u:
		# 队员：镜像锚的权威值（区划升降只由锚算一次）
		u.morale = anchor.morale
		u.morale_max = anchor.morale_max
	else:
		# 锚：按所在区划升降
		var rate := _zone_morale_rate(world, cfg, u)
		u.morale = clampf(u.morale + rate * dt, 0.0, u.morale_max)

	# ★★ 生命档位对**每个单位**都生效（不只锚）：士气是整支部队共享的，
	#    就该整支部队一起回血 / 掉血 —— 只给锚上档位的话，只有将领一个人动血（实测踩到）。
	_apply_hp_tiers(cfg, u, dt)


## 常规「所在区划 + 粮车光环」的士气速率（点/秒），锚与濒死将领共用。
static func _zone_morale_rate(world, cfg, u) -> float:
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
	# ★★ 粮车光环（本轮新增）：`world.morale_aura_bonus` 已在单位循环之前算好，
	#    键 = 士气锚 id。它**加在**区划速率上（不是取代），所以：
	#      · 与区划回士气 / 其它士气上升效果叠加；
	#      · 多辆粮车覆盖同一支部队时 world 那边只留最大值 ⇒ 不叠加（需求口径）。
	if world != null and world.morale_aura_bonus.has(u.id):
		rate += float(world.morale_aura_bonus[u.id])
	# ★★ 2026.10.29 断粮：这一方**付不起单位维护费**（world._tick_upkeep 当帧写的标记）时，
	#    全军额外 -morale.starve_drain（默认 0.5/秒）。
	#    ★ 与粮车光环**等速**是有意的：一辆粮车刚好把这个惩罚抵消掉。
	#    ★ 它叠加在「区划速率 + 光环」之上 ⇒ 站在敌方区划上断粮 = 0.5(疲惫) + 0.5(断粮)。
	if world != null and world.is_starving(String(u.faction)):
		rate -= cfg.morale_starve_drain
	return rate


## ★★ 2026.10.29：主将**濒死（倒地）**期间的整队士气结算。
##
## 用户口径：
##   · 只在 `is_downed()` 期间生效；
##   · 固定额外 `-cfg.morale_leader_down_drain`（默认 3/s）；
##   · 「增加和减少都叠加」：先算常规区划速率（己方回士气 / 敌方·中立掉士气 /
##     被包围疲惫）+ 粮车光环，再减这个固定值；
##   · 再起后不做补偿：士气停在当前值，下一帧起按正常规则走。
##
## ★ 这个函数只改士气，不碰 HP：濒死回复由 `unit.tick_near_death` 独占，
##   两边都动 HP 会把「每 3 秒回 1%」变成双倍。
static func tick_downed_leader(world, cfg, u, dt: float) -> void:
	if u == null or not u.is_downed():
		return
	var rate: float = _zone_morale_rate(world, cfg, u) \
		- float(cfg.morale_leader_down_drain)
	u.morale = clampf(u.morale + rate * dt, 0.0, u.morale_max)


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
