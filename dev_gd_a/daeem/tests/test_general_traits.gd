## test_general_traits.gd —— 将领词条：**代码保留、生产路径停用**
##
## 2026.10 口径：随机词条不再挂在将领 / 部队上。
##   · config 的 6 条词条数据仍在；
##   · `unit.set_general_trait()` / `inherit_general_aura()` / HUD 显示 / 快照 gt·ga
##     这些代码仍保留（手动调用仍生效）；
##   · 但 world 的所有出生 / 招募路径**不再授予词条**，招募页也不再显示词条。
##
## 本文件因此分成两半：
##   1) 生产路径：确认「没有任何单位自动带词条」；
##   2) 代码保留：手动 set_general_trait 后，数值 / UI / 快照仍然工作。
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const ConfigRes = preload("res://logic/config.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const HudRes = preload("res://view/hud.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_general_traits"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_no_auto_assignment(cfg)
	_test_manual_aura_effects(cfg)
	_test_manual_retinue_inherit(cfg)
	_test_manual_ui(cfg)
	_test_manual_snapshot(cfg)

# ------------------------------------------------------------------
# 1) config：六条词条的数据仍在
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	var ids: Array = cfg.general_trait_ids()
	eq(ids.size(), 6, "★ 六条基础词条数据仍在")
	for want in ["swift", "melee_guard", "ranged_guard", "infantry_slayer",
			"cavalry_slayer", "might"]:
		ok(ids.has(want), "词条表里有 %s" % want)
	eq(cfg.general_trait_name("swift"), "神速", "神速：显示名")
	eq(cfg.general_trait_short("might"), "神", "神力：短名")
	near(float(cfg.general_trait_def("swift").get("speed_bonus", 0.0)), 0.25, 1e-9,
		"★ 神速：移速 +25%")
	near(float(cfg.general_trait_def("melee_guard").get("melee_reduction", 0.0)), 0.25, 1e-9,
		"★ 近战抵抗：近战减伤 25%")
	near(float(cfg.general_trait_def("ranged_guard").get("ranged_reduction", 0.0)), 0.25, 1e-9,
		"★ 远程抵抗：远程减伤 25%")
	near(float(cfg.general_trait_def("might").get("attack_speed_bonus", 0.0)), 0.25, 1e-9,
		"★ 神力：攻速 +25%")
	near(float((cfg.general_trait_def("infantry_slayer").get("attack_vs_class", {}) as Dictionary)
		.get("infantry", 0.0)), 0.25, 1e-9, "★ 步兵特攻：对步兵 +25%")
	near(float((cfg.general_trait_def("cavalry_slayer").get("attack_vs_class", {}) as Dictionary)
		.get("cavalry", 0.0)), 0.25, 1e-9, "★ 骑兵特攻：对骑兵 +25%")

# ------------------------------------------------------------------
# 2) 生产路径：没有任何单位自动带词条
# ------------------------------------------------------------------
func _test_no_auto_assignment(cfg) -> void:
	# 自由对战 #0
	var w = _quiet(cfg)
	var g0 = w.unit_by_id("general-0")
	ok(g0 != null, "（前提）有开局将领 #0")
	if g0 != null:
		eq(String(g0.general_trait), "", "★★ #0 不再自动获得词条")
		eq(String(g0.aura_trait_id), "", "★ #0 没有光环")
		ok(not g0.has_general_aura(), "has_general_aura() = false")

	# 招募名单：词条接口保留但恒空
	var traits: Array = w.general_recruit_traits("p1")
	for t in traits:
		eq(String(t), "", "★ 招募阵容不再带词条")
	eq(w.general_recruit_trait_for("p1", "general_1"), "", "★ 下单时也取不到词条")

	# 真正招一位出来：仍然没有词条
	_no_income(w)
	_give(w, 5000.0, 5000.0)
	var z = _own_zone(w)
	if z != null:
		z["population"] = 10.0
		ok(w.start_zone_recruit("general_1", int(z["id"]), "p1"), "（前提）招 #1")
		eq(String(w.zone_recruit_trait_at(z, 0)), "", "★ 区划队列里没有词条")
		_tick_secs(w, 11.0)
		var fresh = w.units[w.units.size() - 1]
		eq(String(fresh.general_trait), "", "★★ 招出来的将领没有词条")
		eq(String(fresh.aura_trait_id), "", "★ 也没有光环")

	# 关卡摆放的将领 + 附属兵：同样没有
	var lw = require_world_with_escorts(cfg, 2)
	if lw != null:
		var lg = lw.unit_by_id("general-1")
		ok(lg != null, "（前提）关卡将领在场")
		if lg != null:
			eq(String(lg.general_trait), "", "★★ 关卡将领没有词条")
			for m in lw.retinue_of(lg.id):
				eq(String(m.aura_trait_id), "", "★ 附属兵没有光环")

# ------------------------------------------------------------------
# 3) 代码保留：手动授予仍然生效（六条的数值接入点）
# ------------------------------------------------------------------
func _mk(cfg, id: String, unit_type: String):
	return UnitRes.create(cfg, id, "测", Vector2i.ZERO, "p1", unit_type, "", "", unit_type, -1)

func _test_manual_aura_effects(cfg) -> void:
	# 神速：面板 + step_along_path 的实际预算
	var u = _mk(cfg, "g_swift", UnitRes.UNIT_TYPE_SPEARMAN)
	var base_speed: float = u.speed(cfg, null)
	u.set_general_trait(cfg, "swift")
	near(u.speed(cfg, null), base_speed * 1.25, 1e-6, "★ 神速：移速 ×1.25")

	var w = _quiet(cfg)
	var a = _mk(w.cfg, "move_plain", UnitRes.UNIT_TYPE_SPEARMAN)
	var b = _mk(w.cfg, "move_swift", UnitRes.UNIT_TYPE_SPEARMAN)
	b.set_general_trait(w.cfg, "swift")
	for unit in [a, b]:
		unit.pos = Vector2(3.5, 3.5)
		var pts: Array[Vector2] = [Vector2(5.5, 3.5)]
		unit.path = pts
		unit.goal = Vector2(5.5, 3.5)
		unit.has_goal = true
		unit.moving = true
	a.step_along_path(w, w.cfg, DT)
	b.step_along_path(w, w.cfg, DT)
	var da: float = a.pos.x - 3.5
	var db: float = b.pos.x - 3.5
	ok(da > 0.0 and db > 0.0, "（前提）两个单位这一帧都走了")
	near(db, da * 1.25, 1e-6, "★ 神速也作用于实际移动")

	# 神力
	var m = _mk(cfg, "g_might", UnitRes.UNIT_TYPE_SPEARMAN)
	var cd_base: float = m.combat_cooldown(cfg)
	m.set_general_trait(cfg, "might")
	near(m.combat_cooldown(cfg), cd_base / 1.25, 1e-6, "★ 神力：攻击间隔 ÷1.25")
	CombatRes.attack_unit(null, cfg, m, _mk(cfg, "g_dummy", UnitRes.UNIT_TYPE_SPEARMAN))
	near(m.attack_cd, cd_base / 1.25, 1e-6, "★ attack_cd 也按缩短后的间隔设置")

	# 步兵 / 骑兵特攻
	var s = _mk(cfg, "g_inf", UnitRes.UNIT_TYPE_SPEARMAN)
	var cav_before: float = s.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY)
	s.set_general_trait(cfg, "infantry_slayer")
	near(s.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.25, 1e-9,
		"★ 步兵特攻：对步兵 ×1.25")
	near(s.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY), cav_before, 1e-9,
		"步兵特攻不改变对骑兵的倍率")
	var c = _mk(cfg, "g_cav", UnitRes.UNIT_TYPE_LONGBOWMAN)
	c.set_general_trait(cfg, "cavalry_slayer")
	near(c.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY), 1.25, 1e-9,
		"★ 骑兵特攻：对骑兵 ×1.25")
	var rider = _mk(cfg, "g_rider", UnitRes.UNIT_TYPE_RIDER)
	rider.set_general_trait(cfg, "infantry_slayer")
	near(rider.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.5, 1e-9,
		"★ 将领特攻与兵种特攻加算")

	# 近战 / 远程抵抗
	# ★ 2026.10.29：长枪兵现在有 2 点护甲，会先削掉伤害 —— 这一节只验「抵抗」那 25%，
	#   所以显式把护甲清零（把固定护甲变成被测变量会让下面的数字全是 73.5 这种）。
	var mg = _mk(cfg, "g_melee_guard", UnitRes.UNIT_TYPE_SPEARMAN)
	mg.armor = 0.0
	mg.hp_max = 1000.0
	mg.hp = 1000.0
	mg.morale = cfg.morale_mid_tier
	mg.set_general_trait(cfg, "melee_guard")
	mg.take_damage(cfg, null, 100.0, null, false)
	near(1000.0 - mg.hp, 75.0, 1e-6, "★ 近战抵抗：近战 100 → 75")
	mg.hp = 1000.0
	mg.take_damage(cfg, null, 100.0, null, true)
	near(1000.0 - mg.hp, 100.0, 1e-6, "★ 近战抵抗不挡远程")

	var rg = _mk(cfg, "g_ranged_guard", UnitRes.UNIT_TYPE_SPEARMAN)
	rg.armor = 0.0
	rg.hp_max = 1000.0
	rg.hp = 1000.0
	rg.morale = cfg.morale_mid_tier
	rg.set_general_trait(cfg, "ranged_guard")
	rg.take_damage(cfg, null, 100.0, null, true)
	near(1000.0 - rg.hp, 75.0, 1e-6, "★ 远程抵抗：远程 100 → 75")
	rg.hp = 1000.0
	rg.take_damage(cfg, null, 100.0, null, false)
	near(1000.0 - rg.hp, 100.0, 1e-6, "★ 远程抵抗不挡近战")

	# 清空 → 中性
	var neutral = _mk(cfg, "g_neutral", UnitRes.UNIT_TYPE_SPEARMAN)
	neutral.set_general_trait(cfg, "swift")
	neutral.set_general_trait(cfg, "")
	near(neutral.aura_speed_mult, 1.0, 1e-9, "清空词条 → 移速倍率回到 1")
	eq(neutral.aura_trait_id, "", "清空词条 → aura_trait_id 为空")

# ------------------------------------------------------------------
# 4) 代码保留：手动 inherit_general_aura 仍然工作
# ------------------------------------------------------------------
func _test_manual_retinue_inherit(cfg) -> void:
	var w = _quiet(cfg)
	var g = UnitRes.create(w.cfg, "trait_leader", "将", Vector2i(3, 3), "p1",
		"general_4", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 3)
	w.units.append(g)
	g.set_general_trait(w.cfg, "ranged_guard")
	var e = UnitRes.create(w.cfg, "trait_escort", "兵", Vector2i(3, 3), "p1",
		UnitRes.UNIT_TYPE_SPEARMAN, "", "trait_leader", UnitRes.UNIT_TYPE_SPEARMAN, -1)
	e.inherit_general_aura(w.cfg, g)
	w.units.append(e)
	eq(String(e.aura_trait_id), "ranged_guard", "★ 手动 inherit_general_aura 仍然生效")
	near(e.aura_ranged_reduction, 0.25, 1e-9, "附属兵拿到同样的远程减伤")

# ------------------------------------------------------------------
# 5) 代码保留：HUD 显示仍然工作（手动授予后）
# ------------------------------------------------------------------
func _test_manual_ui(cfg) -> void:
	var hud = HudRes.new()
	hud.cfg = cfg
	var u = _mk(cfg, "ui_slayer", UnitRes.UNIT_TYPE_SPEARMAN)
	u.morale = cfg.morale_mid_tier
	u.set_general_trait(cfg, "infantry_slayer")

	var buffs: Array = hud._buffs_for(u)
	ok(buffs.size() >= 2, "★ buff 条有「将」+「士」两条")
	eq(String(buffs[0].get("id", "")), "general_trait", "第一条是 general_trait")
	eq(String(buffs[0].get("text", "")), "步", "方块里是词条短名")
	eq(String(buffs[0].get("tip_title", "")), "步兵特攻", "悬停标题是词条名")

	var rows: Dictionary = hud._unit_detail_rows(u)
	var left_txt: String = hud._rows_text({"left": rows["left"], "right": []})
	ok(left_txt.contains("对步兵伤害 +25%（将）"), "左列有将领特攻行")
	ok(left_txt.contains("特性 步兵特攻"), "左列写着词条名字")

	var guard = _mk(cfg, "ui_guard", UnitRes.UNIT_TYPE_SPEARMAN)
	guard.morale = cfg.morale_mid_tier
	guard.set_general_trait(cfg, "melee_guard")
	eq(hud._defense_bonus_lines(guard), ["近战减伤 +25%（将）"], "右列：近战抵抗")
	guard.set_general_trait(cfg, "ranged_guard")
	eq(hud._defense_bonus_lines(guard), ["远程减伤 +25%（将）"], "右列：远程抵抗")
	hud.free()

# ------------------------------------------------------------------
# 6) 代码保留：快照 gt / ga 仍然往返
# ------------------------------------------------------------------
func _test_manual_snapshot(cfg) -> void:
	var host = _quiet(cfg)
	var g = UnitRes.create(host.cfg, "snap_general", "将", Vector2i(5, 5), "p1",
		"general_6", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 5)
	host.units.append(g)
	g.set_general_trait(host.cfg, "might")
	var e = UnitRes.create(host.cfg, "snap_escort", "兵", Vector2i(5, 5), "p1",
		UnitRes.UNIT_TYPE_SPEARMAN, "", "snap_general", UnitRes.UNIT_TYPE_SPEARMAN, -1)
	e.inherit_general_aura(host.cfg, g)
	host.units.append(e)

	var snap: Dictionary = SnapshotRes.to_snapshot(host)
	var payloads: Dictionary = {}
	for su in (snap.get("units", []) as Array):
		payloads[String((su as Dictionary).get("i", ""))] = su
	if payloads.has("snap_general"):
		eq(String(payloads["snap_general"].get("gt", "")), "might", "★ 快照带 gt")
		eq(String(payloads["snap_general"].get("ga", "")), "might", "★ 快照带 ga")
	if payloads.has("snap_escort"):
		eq(String(payloads["snap_escort"].get("ga", "")), "might", "★ 附属兵的 ga")

	var guest = _quiet(cfg)
	SnapshotRes.apply_snapshot(guest, cfg, snap)
	var gg = guest.unit_by_id("snap_general")
	var ge = guest.unit_by_id("snap_escort")
	if gg != null:
		eq(String(gg.general_trait), "might", "★ 客机将领词条写回")
		eq(String(gg.aura_trait_id), "might", "★ 客机将领光环写回")
	if ge != null:
		eq(String(ge.aura_trait_id), "might", "★ 客机附属兵光环写回")

# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------
func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	var w = require_world(c)
	var b = w.find_base_of("p1")
	if b != null:
		b.level = w.cfg.upgrade_max_level("base")
		w.apply_building_level_hp(b)
	return w

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == "p1" and z["center"] != null:
			return z
	return null

func _tick_secs(w, secs: float) -> void:
	var n: int = int(ceil(secs / DT))
	for _i in n:
		w.tick(DT)
