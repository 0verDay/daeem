## test_morale.gd —— 士气机制（logic/morale.gd + world 的区划联动）
##
## 覆盖：配置默认值 / 生命档位（回血·掉血·不致死）/ 免伤易伤 / 区划升降 / 包围（疲惫）/
##       部队共享（镜像）/ 破敌·斩将·掠地 / 快照 round-trip。
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const MoraleRes = preload("res://logic/morale.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")


func _initialize() -> void:
	_case_name = "test_morale"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_tiers(cfg)
	_test_damage_mult(cfg)
	var w = require_world(cfg)
	if w != null:
		_test_zone_drift(cfg, w)
		_test_surrounded(cfg, w)
		_test_boosts(cfg, w)
		_test_snapshot(cfg, w)
	_test_campaign_no_false_surround(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## 造一个游离单位（不进 world —— 档位 / 免伤这些只依赖单位自身）。
func _mk(cfg, kind: String, faction: String, id: String):
	return UnitRes.create(cfg, id, "测", Vector2i.ZERO, faction, kind, "", "", "spearman", -1)


# ------------------------------------------------------------------
# 配置 + 单位初始化
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	eq(cfg.morale_max, 100.0, "士气初始上限 = 100")
	eq(cfg.morale_start, 90.0, "士气初始值 = 90")
	eq(cfg.morale_high_tier, 100.0, "高档阈值 = 100（快速回血 + 免伤）")
	eq(cfg.morale_mid_tier, 90.0, "中档阈值 = 90（缓慢回血）")
	eq(cfg.morale_vuln_tier, 50.0, "易伤阈值 = 50")
	eq(cfg.morale_low_tier, 25.0, "掉血阈值 = 25")
	ok(cfg.morale_regen_ally > 0.0, "己方区划上升速率 > 0")
	ok(cfg.morale_decay_enemy > 0.0 and cfg.morale_decay_surrounded > 0.0, "疲惫下降速率 > 0")
	ok(cfg.morale_hp_regen_high > cfg.morale_hp_regen_mid, "「快速回血」比「缓慢回血」快")
	ok(cfg.morale_hp_decay_zero > cfg.morale_hp_decay_low, "「快速掉血」比「缓慢掉血」快")
	ok(cfg.morale_damage_reduction > 0.0 and cfg.morale_damage_reduction < 1.0, "免伤在 (0, 1)")
	ok(cfg.morale_vulnerability > 0.0, "易伤 > 0")

	var u = _mk(cfg, "general", "p1", "c1")
	eq(u.morale_max, cfg.morale_max, "create 后 morale_max 取 config")
	near(u.morale, cfg.morale_start, 1e-6, "create 后 morale 取 config.start")
	near(u.morale_ratio(), cfg.morale_start / cfg.morale_max, 1e-6, "morale_ratio = morale / morale_max")


# ------------------------------------------------------------------
# 生命档位（world=null → 只在档位上动，不碰区划）
# ------------------------------------------------------------------
func _test_tiers(cfg) -> void:
	var u = _mk(cfg, "general", "p1", "t1")

	u.hp = 1.0
	u.morale = cfg.morale_high_tier
	MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, 1.0 + cfg.morale_hp_regen_high, 1e-4, "★ 士气 ≥100：快速回血")

	u.hp = 1.0
	u.morale = cfg.morale_mid_tier
	MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, 1.0 + cfg.morale_hp_regen_mid, 1e-4, "★ 士气 ≥90：缓慢回血")

	u.hp = 100.0
	u.morale = cfg.morale_low_tier
	MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, 100.0 - cfg.morale_hp_decay_low, 1e-4, "★ 士气 ≤25：缓慢掉血")

	u.hp = 100.0
	u.morale = 0.0
	MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, 100.0 - cfg.morale_hp_decay_zero, 1e-4, "★ 士气 =0：快速掉血")

	# 掉血**止于极小值、不致死**（连跑一大段都停在下限）
	u.hp = 50.0
	u.morale = 0.0
	for i in 50:
		MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, cfg.morale_hp_floor, 1e-6, "★ 持续掉血止于 hp_floor（趋近 0 但不为 0）")
	ok(u.alive, "★ 士气掉血**不会**让单位死亡")

	# 回血封顶在 hp_max
	u.hp = u.hp_max - 1.0
	u.morale = cfg.morale_high_tier
	for i in 50:
		MoraleRes.tick_unit(null, cfg, u, 1.0)
	near(u.hp, u.hp_max, 1e-6, "★ 回血封顶在 hp_max")


# ------------------------------------------------------------------
# 免伤 / 易伤（走 take_damage —— 近战与远程的唯一收口）
# ------------------------------------------------------------------
func _test_damage_mult(cfg) -> void:
	var u = _mk(cfg, "general", "p1", "d1")
	u.hp_max = 1000.0

	u.morale = cfg.morale_high_tier
	u.hp = 1000.0
	u.take_damage(cfg, null, 100.0, null)
	near(1000.0 - u.hp, 100.0 * (1.0 - cfg.morale_damage_reduction), 1e-3, "★ 高士气：受到伤害减少（免伤）")

	u.morale = cfg.morale_vuln_tier
	u.hp = 1000.0
	u.take_damage(cfg, null, 100.0, null)
	near(1000.0 - u.hp, 100.0 * (1.0 + cfg.morale_vulnerability), 1e-3, "★ 低士气（≤50）：受到伤害增加（易伤）")

	u.morale = 0.0
	u.hp = 1000.0
	u.take_damage(cfg, null, 100.0, null)
	near(1000.0 - u.hp, 100.0 * (1.0 + cfg.morale_vulnerability), 1e-3,
		"★ 士气 0：易伤**仍然存在**（50 以下各档都保留）")

	u.morale = (cfg.morale_mid_tier + cfg.morale_vuln_tier) * 0.5   # 中间档
	u.hp = 1000.0
	u.take_damage(cfg, null, 100.0, null)
	near(1000.0 - u.hp, 100.0, 1e-3, "★ 中间档士气：不加不减")


# ------------------------------------------------------------------
# 区划升降（己方↑ / 中立不变 / 敌方↓）
# ------------------------------------------------------------------
func _test_zone_drift(cfg, w) -> void:
	var u = w.unit_by_id("general-0")
	ok(u != null, "（前提）世界里有 general-0")
	if u == null:
		return
	var base: Vector2i = w.home_base_of("p1")
	var bz = w.zones.zone_at(base.x, base.y)
	ok(bz != null, "（前提）大本营落在某个区划里")

	if bz != null:
		u.tx = base.x
		u.ty = base.y
		u.morale = 50.0
		MoraleRes.tick_unit(w, cfg, u, 1.0)
		near(u.morale, 50.0 + cfg.morale_regen_ally, 1e-4, "★ 站己方区划：士气缓慢上升")

	var nz = _zone_owned_by(w, "")
	if nz != null:
		var t: Vector2i = nz["tiles"][0]
		u.tx = t.x
		u.ty = t.y
		u.morale = 50.0
		MoraleRes.tick_unit(w, cfg, u, 1.0)
		near(u.morale, 50.0 - cfg.morale_decay_enemy, 1e-4, "★ 站中立区划：也算疲惫（士气下降）")

		nz["owner"] = "enemy"
		u.morale = 50.0
		MoraleRes.tick_unit(w, cfg, u, 1.0)
		near(u.morale, 50.0 - cfg.morale_decay_enemy, 1e-4, "★ 站敌方区划：士气下降（疲惫）")
	else:
		ok(true, "（这张图没有中立区划，跳过中立 / 敌方升降）")


# ------------------------------------------------------------------
# 包围：与大本营区划不连通的己方区划 → 区内单位「疲惫」
# ------------------------------------------------------------------
func _test_surrounded(cfg, w) -> void:
	if w.zones == null:
		return
	for z in w.zones.zones:
		z["owner"] = ""
	var base: Vector2i = w.home_base_of("p1")
	var basez = w.zones.zone_at(base.x, base.y)
	if basez == null:
		ok(false, "（前提）大本营落在某个区划里")
		return
	basez["owner"] = "p1"
	w.refresh_zone_connectivity()
	ok(not w.zone_is_surrounded(int(basez["id"])), "★ 大本营所在区划**不算**被包围")

	# ★★ 回归（本次报的 bug）：邻接图必须是**无向**的 —— 基地所在区划得有邻接区划，
	#    而且与它**相邻**的己方区划**不算**被包围（否则占领相邻区划后士气会一直掉）。
	var base_adj: Array = w._zone_adj.get(int(basez["id"]), [])
	ok(base_adj.size() > 0, "★★ 基地所在的区划有邻接区划（邻接图必须有无向边）")
	var near_z = _zone_in_ids(w, base_adj)
	if near_z != null:
		near_z["owner"] = "p1"
		w.refresh_zone_connectivity()
		ok(not w.zone_is_surrounded(int(near_z["id"])),
			"★★ 与基地相邻的己方区划**不算**被包围（回归：邻接表曾经为空 → 全体误判）")
		near_z["owner"] = ""
		w.refresh_zone_connectivity()

	# 找一个「与大本营区划不相邻」的区划 → 才是真正的「被包围」
	var far = null
	for z in w.zones.zones:
		if int(z["id"]) == int(basez["id"]):
			continue
		if base_adj.has(int(z["id"])):
			continue
		far = z
		break
	if far == null:
		ok(true, "（这张图没有与大本营不相邻的区划，跳过包围用例）")
		return
	far["owner"] = "p1"
	w.refresh_zone_connectivity()
	ok(w.zone_is_surrounded(int(far["id"])), "★ 与营地不连通的己方区划 = 被包围")

	var u = w.unit_by_id("general-0")
	if u != null:
		var t: Vector2i = far["tiles"][0]
		u.tx = t.x
		u.ty = t.y
		u.morale = 50.0
		MoraleRes.tick_unit(w, cfg, u, 1.0)
		near(u.morale, 50.0 - cfg.morale_decay_surrounded, 1e-4,
			"★ 被包围的己方区划：区内单位士气下降（疲惫）")


# ------------------------------------------------------------------
# 部队共享（镜像）+ 破敌 / 斩将 / 掠地
# ------------------------------------------------------------------
func _test_boosts(cfg, w) -> void:
	var leader = w.unit_by_id("general-0")
	ok(leader != null, "（前提）世界里有 general-0")
	if leader == null:
		return
	# 手动挂一个附属兵：验证「部队共享 = 队员镜像锚」
	var m = UnitRes.create(cfg, "m1", "兵", Vector2i.ZERO, "p1", "soldier", "", leader.id, "spearman", -1)
	w.units.append(m)
	leader.morale = 50.0
	MoraleRes.sync_members(w, leader)
	near(m.morale, 50.0, 1e-6, "（前提）队员镜像队长")
	MoraleRes.tick_unit(w, cfg, m, 1.0)
	near(m.morale, leader.morale, 1e-6, "★ 队员每帧镜像队长（整支部队共享一个士气）")

	# ★ 生命档位对**整支部队**生效：士气为 0 时队员也要掉血（不能只有将领掉）
	leader.morale = 0.0
	MoraleRes.sync_members(w, leader)
	m.hp = 100.0
	MoraleRes.tick_unit(w, cfg, m, 1.0)
	near(m.hp, 100.0 - cfg.morale_hp_decay_zero, 1e-4, "★ 士气 0：队员也掉血（整支部队，不只将领）")

	# 破敌
	leader.morale = 50.0
	MoraleRes.boost_kill(w, cfg, _mk(cfg, "soldier", "enemy", "ds"), leader)
	near(leader.morale, 50.0 + cfg.morale_boost_kill, 1e-4, "★ 破敌：击杀敌方单位 → 全队士气上升")
	near(m.morale, leader.morale, 1e-6, "★ 加成**瞬时**同步给队员")

	# 斩将（加得更多）
	leader.morale = 50.0
	MoraleRes.boost_kill(w, cfg, _mk(cfg, "general", "enemy", "dl"), leader)
	near(leader.morale, 50.0 + cfg.morale_boost_leader, 1e-4, "★ 斩将：击杀敌方将领 → 加得更多")

	# 同阵营击杀不算破敌
	leader.morale = 50.0
	MoraleRes.boost_kill(w, cfg, _mk(cfg, "soldier", "p1", "ally"), leader)
	near(leader.morale, 50.0, 1e-6, "★ 击杀同阵营不算破敌")

	# 掠地
	var nz = _zone_owned_by(w, "")
	if nz != null:
		var t: Vector2i = nz["tiles"][0]
		leader.tx = t.x
		leader.ty = t.y
		leader.morale = 50.0
		nz["owner"] = "p1"
		MoraleRes.boost_capture(w, cfg, nz)
		near(leader.morale, 50.0 + cfg.morale_boost_capture, 1e-4,
			"★ 掠地：区划转己方 → 区内己方单位士气上升")
	else:
		ok(true, "（这张图没有中立区划，跳过掠地）")

	w.units.erase(m)          # 别把临时兵留给后面的用例


# ------------------------------------------------------------------
# 快照 round-trip
# ------------------------------------------------------------------
func _test_snapshot(cfg, w) -> void:
	var u = w.unit_by_id("general-0")
	if u == null:
		return
	u.morale = 33.0
	var snap: Dictionary = SnapshotRes.to_snapshot(w)
	var mo = null
	for su in snap.get("units", []):
		if String(su.get("i", "")) == u.id:
			mo = su.get("mo", null)
	eq(mo, 33, "★ 快照里带士气字段 mo")

	var w2 = require_world(cfg)
	if w2 == null:
		return
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var u2 = w2.unit_by_id(u.id)
	ok(u2 != null, "（前提）快照写回后有同一个单位")
	if u2 != null:
		near(u2.morale, 33.0, 1e-6, "★ 快照写回后士气保留")


## 找一个 owner 匹配、且至少有一个地块的区划（exclude_id 用来排掉某一个）。
func _zone_owned_by(w, owner: String, exclude_id: int = -1):
	for z in w.zones.zones:
		if int(z["id"]) == exclude_id:
			continue
		if String(z.get("owner", "")) == owner and (z["tiles"] as Array).size() > 0:
			return z
	return null


## 在给定的一组区划 id 里挑第一个区划（测试用）。
func _zone_in_ids(w, ids: Array):
	for z in w.zones.zones:
		if ids.has(int(z["id"])):
			return z
	return null


## 某阵营的一支在场部队（队长优先；测试用）。
func _first_unit_of(w, faction: String):
	for u in w.units:
		if u.alive and String(u.faction) == faction and w.is_team_leader(u):
			return u
	for u in w.units:
		if u.alive and String(u.faction) == faction:
			return u
	return null


## ★★ 回归：真关卡（战役 mt）里，玩家自己那块**含大本营**的区划不能被误判成「被包围」。
## 起因：`spawned_factions()` 把 AI / NPC 阵营也算进来，而它们的大本营点是**占位(0,0)**；
## 拿它做连通洪泛会把盟友（同一边）的己方区划标成被包围 → 玩家站在自己地盘里士气一直掉。
func _test_campaign_no_false_surround(cfg) -> void:
	var path := "res://data/campaigns/demo/levels/mt.json"
	if not FileAccess.file_exists(path):
		ok(true, "（没有 mt 关卡，跳过）")
		return
	var lv = LevelRes.load_level(null, path, cfg)
	if lv == null:
		ok(false, "mt 关卡能载入")
		return
	var w = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], false)
	ok(w != null, "（前提）mt 关卡能开出世界")
	if w == null:
		return
	var base: Vector2i = w.home_base_of("F1")
	var bz = w.zones.zone_at(base.x, base.y)
	ok(bz != null, "（前提）F1 大本营落在某个区划里")
	if bz != null:
		ok(not w.zone_is_surrounded(int(bz["id"])),
			"★★ 玩家自己那块（含大本营的）区划**不算**被包围（盟友的占位大本营不再误伤）")
	# F1 的一支部队（mt 里单位 id 不是 general-0，按阵营 + 队长找）
	var u = _first_unit_of(w, "F1")
	ok(u != null, "（前提）mt 里找得到 F1 的单位")
	if u != null:
		u.morale = 50.0
		for i in 60:
			w.tick(1.0 / 60.0)
		near(u.morale, 50.0 + cfg.morale_regen_ally, 1e-3,
			"★★ 站己方区划 1 秒：士气上升（不再「无论在哪都掉」）")

	# ★★ 回归（本次报的 bug）：占领一个**与基地相邻**的中立区划后，不该算被包围、士气该回升
	if bz == null:
		return
	var base_adj: Array = w._zone_adj.get(int(bz["id"]), [])
	var neutral_near = null
	for z in w.zones.zones:
		if String(z["owner"]) == "" and base_adj.has(int(z["id"])):
			neutral_near = z
			break
	if neutral_near == null:
		ok(true, "（mt 里没有与基地相邻的中立区划，跳过）")
		return
	var t: Vector2i = neutral_near["tiles"][0]
	neutral_near["owner"] = "F1"
	# 先跑一帧：把「掠地」的即时加成结掉、让 owner 快照跟上 —— 这样下面单独量
	# 「站在刚占领的地里会不会回升」就不会混进那 +boost_capture。
	w.tick(1.0 / 60.0)
	w.refresh_zone_connectivity()
	ok(not w.zone_is_surrounded(int(neutral_near["id"])),
		"★★ 占领与基地相邻的中立区划后：不算被包围（回归：邻接图曾经是有向的）")
	if u != null:
		u.tx = t.x
		u.ty = t.y
		u.morale = 50.0
		for i in 60:
			w.tick(1.0 / 60.0)
		near(u.morale, 50.0 + cfg.morale_regen_ally, 1e-3,
			"★★ 站在刚占领的相邻区划里 1 秒：士气回升（不再继续掉）")
