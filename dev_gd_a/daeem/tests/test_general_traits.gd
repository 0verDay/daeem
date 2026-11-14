## test_general_traits.gd —— 将领特性（部队光环）的数据 + 生效口径
##
## ★★ 2026.11.3 口径变更：特性**恢复生效**，但不再是「随机抽词条」——
##   config 的 `unit.general.trait_ids[i]` 指定第 i 位将领用哪一条（`""` = 没有）；
##   编辑器（tools/unit_editor）的「将领」页里选，「将领特性池」里改定义 / 加删。
##   ⚠️ 默认配置里 `trait_ids` 全是 `""`（= 谁都没有特性），所以下面「生产路径」那一组
##      验的仍然是「默认没有」——那是**配置的结果**，不是「功能停用」。
##
## 本文件分两半：
##   1) 生产路径：默认配置下没有任何单位自动带特性（随机抽取已删除）；
##   2) 代码本身：手动 set_general_trait 后，数值 / UI / 快照仍然工作。
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
# 1) config：六条特性的数据仍在
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	var ids: Array = cfg.general_trait_ids()
	eq(ids.size(), 13, "★ 十三条词条数据（6 条基础 + 7 条新特性；每条只做一件事）")
	for want in ["swift", "melee_guard", "ranged_guard", "infantry_slayer",
			"cavalry_slayer", "might", "steadfast", "arrow_wall",
			"formation_breaker", "capture_expert", "call_to_arms",
			"new_knighthood", "crushing_blow"]:
		ok(ids.has(want), "词条表里有 %s" % want)
	eq(cfg.general_trait_name("swift"), "神速", "神速：显示名")
	eq(cfg.general_trait_short("might"), "神", "神力：短名")
	# ★★ 2026.11：一个特性 = 一个特性名 = 一个效果（用户口径）。
	eq(cfg.general_trait_name("steadfast"), "稳定", "稳定：特性名")
	eq(cfg.general_trait_desc("steadfast"), "免疫击退（与眩晕）", "★ 稳定的效果只有「免疫击退」")
	ok(bool(cfg.general_trait_def("steadfast").get("knockback_immune", false)),
		"★ 稳定 = knockback_immune")
	eq(cfg.general_trait_name("call_to_arms"), "一呼百应", "一呼百应：特性名")
	near(float(cfg.general_trait_def("call_to_arms").get("recruit_cavalry_discount", 0.0)),
		0.25, 1e-9, "…它的效果只有「招募骑兵 -25%」")
	eq(cfg.general_trait_name("new_knighthood"), "新骑士精神", "新骑士精神：特性名")
	near(float(cfg.general_trait_def("new_knighthood").get("charge_damage_bonus", 0.0)),
		1.0, 1e-9, "…它的效果只有「冲锋额外伤害 +100%」")
	eq(cfg.general_trait_name("crushing_blow"), "横扫", "横扫：特性名")
	var ms: Dictionary = cfg.general_trait_def("crushing_blow").get("melee_splash", {})
	near(float(ms.get("radius", 0.0)), 1.0, 1e-9, "…效果：范围伤害半径 1 格")
	near(float(ms.get("knockback", 0.0)), 0.5, 1e-9, "…并击退 0.5 格")
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
	# ★★ 每条特性只能有一个效果键（名字 / 短名 / 说明之外）
	#   ★ 读**原始**配置（`general_trait_def` 是洗过的，所有键都会带默认值）。
	var effect_keys := ["speed_bonus", "attack_speed_bonus", "melee_reduction",
		"ranged_reduction", "attack_vs_class", "knockback_immune",
		"capture_speed_bonus", "recruit_cavalry_discount", "charge_damage_bonus",
		"melee_splash"]
	for tid in ids:
		var raw: Variant = cfg.get_path_value("unit.general_traits.%s" % String(tid))
		var d: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
		var used: Array = []
		for k in effect_keys:
			if d.has(k):
				used.append(k)
		ok(used.size() <= 1,
			"★★ 特性「%s」最多只有一个效果键（实际 %s）" % [cfg.general_trait_name(String(tid)), str(used)])

# ------------------------------------------------------------------
# 2) 默认配置：特性**按 trait_ids 指定**（不再是随机抽，也不是「谁都没有」）
#
# ★★ 2026.11：默认配置里 #1 / #6 / #8 带「神速」，#0 没有；
#   新加的四位将领各自带**多条**（如子刹 = 铁壁 + 稳定）。这里验的是「配置写了就真的生效」。
# ------------------------------------------------------------------
func _test_no_auto_assignment(cfg) -> void:
	# 自由对战 #0（trait_ids[9] = []）
	var w = _quiet(cfg)
	var g0 = w.unit_by_id("general-0")
	ok(g0 != null, "（前提）有开局将领 #0")
	if g0 != null:
		eq(String(g0.general_trait), "", "★★ #0 没有指定词条")
		eq(g0.general_traits, [], "★ #0 的特性列表是空数组")
		ok(not g0.has_general_aura(), "has_general_aura() = false")

	# 招募名单：按 config 的 trait_ids 逐位对齐（#1 = [swift]）
	var traits: Array = w.general_recruit_traits("p1")
	eq(traits[0], ["swift"], "★ 招募阵容第 1 位带「神速」（config 指定）")
	eq(w.general_recruit_traits_for("p1", "general_1"), ["swift"],
		"★ 下单时也取到同一组词条")
	eq(traits[1], [], "★ 第 2 位没指定 → 没有词条")
	# ★★ 新将领：一位带多条
	eq(w.general_recruit_traits_for("p1", "general_12"),
		["arrow_wall", "steadfast", "crushing_blow"],
		"★★ 子刹带「铁壁 + 稳定 + 横扫」三条（一个将领可以有多个特性）")

	# 真正招一位出来：带的就是 config 指定的那组
	_no_income(w)
	_give(w, 5000.0, 5000.0)
	var z = _own_zone(w)
	if z != null:
		z["population"] = 10.0
		var units0: int = w.units.size()
		ok(w.start_zone_recruit("general_1", int(z["id"]), "p1"), "（前提）招 #1")
		# ★★ 2026.11.14：招募即时 ⇒ 没有队列，特性当场上到招出来的那位身上
		eq(w.units.size(), units0 + 1, "★★ 即时：将领当场出现")
		var fresh = w.units[w.units.size() - 1]
		eq(fresh.general_traits, ["swift"], "★★ 招出来的将领带着「神速」")
		eq(String(fresh.aura_trait_id), "swift", "★ 光环也是它")

	# 关卡摆放的将领 + 附属兵：将领自己有，附属兵继承整组
	var lw = require_world_with_escorts(cfg, 2)
	if lw != null:
		var lg = lw.unit_by_id("general-1")
		ok(lg != null, "（前提）关卡将领在场")
		if lg != null:
			eq(lg.general_traits, ["swift"], "★★ 关卡将领带「神速」")
			for m in lw.retinue_of(lg.id):
				eq(m.aura_traits, ["swift"], "★ 附属兵继承同一条光环")

# ------------------------------------------------------------------
# 3) 代码保留：手动授予仍然生效（十条的数值接入点）
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
	eq(neutral.aura_traits, [], "清空词条 → aura_traits 为空")

	# ★★ 2026.11：**多条特性同时生效**（用户口径：一个将领可以有多个特性）
	var multi = _mk(cfg, "g_multi", UnitRes.UNIT_TYPE_SPEARMAN)
	multi.set_general_traits(cfg, ["swift", "might", "melee_guard", "steadfast"])
	eq(multi.general_traits.size(), 4, "★ 一个单位带四条特性")
	eq(multi.aura_traits.size(), 4, "★ 四条都生效（aura_traits）")
	near(multi.aura_speed_mult, 1.25, 1e-9, "…神速的移速")
	near(multi.aura_cooldown_mult, 0.8, 1e-9, "…神力的攻速")
	ok(multi.aura_knockback_immune, "…稳定（免疫击退）")
	near(multi.aura_melee_reduction, 0.25, 1e-9, "…近战抵抗")
	eq(String(multi.general_trait), "swift", "★ 兼容字段 = 第一条")

	# 同类比例**相加**（两条远程减伤：25% + 50% = 75%）
	var double = _mk(cfg, "g_double", UnitRes.UNIT_TYPE_SPEARMAN)
	double.set_general_traits(cfg, ["ranged_guard", "arrow_wall"])
	near(double.aura_ranged_reduction, 0.75, 1e-9,
		"★★ 两条远程减伤相加：25% + 50% = 75%")
	# 对同一个大类的特攻也相加（25% + 50%）
	var breaker = _mk(cfg, "g_breaker", UnitRes.UNIT_TYPE_SPEARMAN)
	breaker.set_general_traits(cfg, ["infantry_slayer", "formation_breaker"])
	near(breaker.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.75, 1e-9,
		"★★ 两条对步兵特攻相加：+25% + +50% = ×1.75")
	# 重复 id 只算一次
	var dup = _mk(cfg, "g_dup", UnitRes.UNIT_TYPE_SPEARMAN)
	dup.set_general_traits(cfg, ["swift", "swift"])
	eq(dup.aura_traits.size(), 1, "★ 同一条特性写两次只算一次")
	near(dup.aura_speed_mult, 1.25, 1e-9, "…不会叠成 +50%")

	# ★★ 横扫：攻击附带范围伤害 + 击退（作为光环生效，兵种本身没有）
	var sweep = _mk(cfg, "g_sweep", UnitRes.UNIT_TYPE_SPEARMAN)
	near(sweep.melee_splash_radius(), 0.0, 1e-9, "（前提）长枪兵本来没有范围伤害")
	sweep.set_general_traits(cfg, ["crushing_blow"])
	near(sweep.melee_splash_radius(), 1.0, 1e-9, "★★ 横扫光环：攻击获得 1 格范围伤害")
	near(sweep.melee_knock_distance(), 0.5, 1e-9, "★★ 横扫光环：击退 0.5 格")
	near(sweep.melee_knock_stun(), 0.25, 1e-9, "…眩晕 0.25 秒")

# ------------------------------------------------------------------
# 4) 代码保留：手动 inherit_general_aura 仍然工作
# ------------------------------------------------------------------
func _test_manual_retinue_inherit(cfg) -> void:
	var w = _quiet(cfg)
	var g = UnitRes.create(w.cfg, "trait_leader", "将", Vector2i(3, 3), "p1",
		"general_4", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 3)
	w.units.append(g)
	g.set_general_traits(w.cfg, ["ranged_guard", "steadfast"])
	var e = UnitRes.create(w.cfg, "trait_escort", "兵", Vector2i(3, 3), "p1",
		UnitRes.UNIT_TYPE_SPEARMAN, "", "trait_leader", UnitRes.UNIT_TYPE_SPEARMAN, -1)
	e.inherit_general_aura(w.cfg, g)
	w.units.append(e)
	eq(String(e.aura_trait_id), "ranged_guard", "★ 手动 inherit_general_aura 仍然生效")
	eq(e.aura_traits, ["ranged_guard", "steadfast"], "★★ 附属兵继承**整组**光环（两条都拿到）")
	near(e.aura_ranged_reduction, 0.25, 1e-9, "附属兵拿到同样的远程减伤")
	ok(e.aura_knockback_immune, "…也拿到稳定")

# ------------------------------------------------------------------
# 5) 代码保留：HUD 显示仍然工作（手动授予后）
# ------------------------------------------------------------------
func _test_manual_ui(cfg) -> void:
	var hud = HudRes.new()
	hud.cfg = cfg
	var u = _mk(cfg, "ui_slayer", UnitRes.UNIT_TYPE_SPEARMAN)
	u.set_general_trait(cfg, "infantry_slayer")

	var buffs: Array = hud._buffs_for(u)
	ok(buffs.size() >= 2, "★ buff 条有「将」+「士」两条")
	eq(String(buffs[0].get("id", "")), "general_trait:infantry_slayer",
		"第一条是 general_trait:<id>")
	eq(String(buffs[0].get("text", "")), "步", "方块里是词条短名")
	eq(String(buffs[0].get("tip_title", "")), "步兵特攻", "悬停标题是词条名")

	var rows: Dictionary = hud._unit_detail_rows(u)
	var left_txt: String = hud._rows_text({"left": rows["left"], "right": []})
	ok(left_txt.contains("对步兵 +25%（将）"), "左列有将领特攻行")
	ok(left_txt.contains("特性 步兵特攻"), "左列写着词条名字")

	var guard = _mk(cfg, "ui_guard", UnitRes.UNIT_TYPE_SPEARMAN)
	guard.set_general_trait(cfg, "melee_guard")
	eq(hud._defense_bonus_lines(guard), ["近战减伤 +25%（将）"], "右列：近战抵抗")
	guard.set_general_trait(cfg, "ranged_guard")
	eq(hud._defense_bonus_lines(guard), ["远程减伤 +25%（将）"], "右列：远程抵抗")

	# ★★ 2026.11：多条特性 → 多个「将」字方块 + 名字用「、」连起来
	var multi = _mk(cfg, "ui_multi", UnitRes.UNIT_TYPE_SPEARMAN)
	multi.set_general_traits(cfg, ["swift", "infantry_slayer"])
	var mb: Array = hud._buffs_for(multi)
	var trait_ids: Array = []
	for b in mb:
		if String((b as Dictionary).get("id", "")).begins_with("general_trait:"):
			trait_ids.append(String((b as Dictionary).get("id", "")))
	eq(trait_ids, ["general_trait:swift", "general_trait:infantry_slayer"],
		"★★ 一条特性一个方块（两条就两个）")
	var mrows: Dictionary = hud._unit_detail_rows(multi)
	var mleft: String = hud._rows_text({"left": mrows["left"], "right": []})
	ok(mleft.contains("特性 神速、步兵特攻"), "★★ 特性名用「、」连起来：%s" % mleft)
	hud.free()

# ------------------------------------------------------------------
# 6) 代码保留：快照 gt / ga 仍然往返
# ------------------------------------------------------------------
func _test_manual_snapshot(cfg) -> void:
	var host = _quiet(cfg)
	var g = UnitRes.create(host.cfg, "snap_general", "将", Vector2i(5, 5), "p1",
		"general_6", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 5)
	host.units.append(g)
	g.set_general_traits(host.cfg, ["might", "steadfast"])
	var e = UnitRes.create(host.cfg, "snap_escort", "兵", Vector2i(5, 5), "p1",
		UnitRes.UNIT_TYPE_SPEARMAN, "", "snap_general", UnitRes.UNIT_TYPE_SPEARMAN, -1)
	e.inherit_general_aura(host.cfg, g)
	host.units.append(e)

	var snap: Dictionary = SnapshotRes.to_snapshot(host)
	var payloads: Dictionary = {}
	for su in (snap.get("units", []) as Array):
		payloads[String((su as Dictionary).get("i", ""))] = su
	if payloads.has("snap_general"):
		eq(payloads["snap_general"].get("gts"), ["might", "steadfast"],
			"★ 快照带 gts（整组特性）")
		eq(payloads["snap_general"].get("gas"), ["might", "steadfast"],
			"★ 快照带 gas（整组光环）")
	if payloads.has("snap_escort"):
		eq(payloads["snap_escort"].get("gas"), ["might", "steadfast"], "★ 附属兵的 gas")

	var guest = _quiet(cfg)
	SnapshotRes.apply_snapshot(guest, cfg, snap)
	var gg = guest.unit_by_id("snap_general")
	var ge = guest.unit_by_id("snap_escort")
	if gg != null:
		eq(gg.general_traits, ["might", "steadfast"], "★ 客机将领词条写回")
		eq(gg.aura_traits, ["might", "steadfast"], "★ 客机将领光环写回")
	if ge != null:
		eq(ge.aura_traits, ["might", "steadfast"], "★ 客机附属兵光环写回")

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
