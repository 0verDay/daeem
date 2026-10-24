## test_base_limits.gd —— 大本营等级限制（将领数 / 编制 / 科技数 / 科技阶）
##
## 规则（config.json 的 upgrade.levels.base）：
##   1 级：3 将 / 编制 +0 / 1 条科技 / 仅一阶
##   2 级：6 将 / 编制 +2 / 2 条科技 / 一二阶
##   3 级：10 将 / 编制 +4 / 3 条科技 / 一二三阶
extends "res://tests/test_case.gd"

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_base_limits"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_level_values(cfg)
	_test_tech_gating(cfg)
	_test_general_count_cap(cfg)
	_test_retinue_cap(cfg)
	_test_base_attack(cfg)
	_test_unit_recruit_tiers(cfg)
	_test_debug_upgrade_base(cfg)

# ------------------------------------------------------------------
# 配置表
# ------------------------------------------------------------------

func _test_config_table(cfg) -> void:
	eq(cfg.upgrade_limit("base", 1, "max_generals", -1), 3, "★ 1 级最多 3 名将领")
	eq(cfg.upgrade_limit("base", 2, "max_generals", -1), 6, "★ 2 级最多 6 名将领")
	eq(cfg.upgrade_limit("base", 3, "max_generals", -1), 10, "★ 3 级最多 10 名将领")
	eq(cfg.upgrade_limit("base", 1, "retinue_cap_bonus", -1), 0, "1 级编制 +0")
	eq(cfg.upgrade_limit("base", 2, "retinue_cap_bonus", -1), 2, "★ 2 级编制 +2")
	eq(cfg.upgrade_limit("base", 3, "retinue_cap_bonus", -1), 4, "★ 3 级编制 +4")
	eq(cfg.upgrade_limit("base", 1, "max_techs", -1), 1, "★ 1 级最多启用 1 条科技")
	eq(cfg.upgrade_limit("base", 2, "max_techs", -1), 2, "★ 2 级最多启用 2 条")
	eq(cfg.upgrade_limit("base", 3, "max_techs", -1), 3, "★ 3 级最多启用 3 条")
	eq(cfg.upgrade_limit("base", 1, "max_tech_tier", -1), 1, "★ 1 级仅一阶")
	eq(cfg.upgrade_limit("base", 2, "max_tech_tier", -1), 2, "★ 2 级到二阶")
	eq(cfg.upgrade_limit("base", 3, "max_tech_tier", -1), 3, "★ 3 级到三阶")

	# ★ 阶 = 科技页的**行**（第一行一阶 / 第二行二阶 / 第三行三阶）。
	eq(cfg.tech_tier("food_1"), 1, "第一行：food_1 = 一阶")
	eq(cfg.tech_tier("gold_1"), 1, "第一行：gold_1 = 一阶")
	eq(cfg.tech_tier("building_hp"), 1, "第一行：building_hp = 一阶")
	eq(cfg.tech_tier("food_2"), 2, "第二行：food_2 = 二阶")
	eq(cfg.tech_tier("gold_2"), 2, "第二行：gold_2 = 二阶")
	eq(cfg.tech_tier("leader_hp"), 2, "第二行：leader_hp = 二阶")
	eq(cfg.tech_tier("food_3"), 3, "第三行：food_3 = 三阶")
	eq(cfg.tech_tier("gold_3"), 3, "第三行：gold_3 = 三阶")
	eq(cfg.tech_tier("zone_population"), 3, "第三行：zone_population = 三阶")

	ok(cfg.building_destructible("base"), "★ 大本营可被摧毁（不再锁血）")
	ok(cfg.building_destructible("wall"), "城墙照旧可摧毁")
	ok(cfg.building_destructible("tower"), "箭塔照旧可摧毁")

# ------------------------------------------------------------------
# 等级 → 生效值
# ------------------------------------------------------------------

func _test_level_values(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	ok(b != null, "（前提）有己方大本营")
	if b == null:
		return
	eq(w.base_level_of("p1"), 1, "开局大本营 1 级")
	eq(w.base_max_generals("p1"), 3, "1 级将领上限 3")
	eq(w.base_retinue_bonus("p1"), 0, "1 级编制 +0")
	eq(w.tech_max_active("p1"), 1, "★ 1 级最多 1 条科技")
	eq(w.tech_max_tier("p1"), 1, "★ 1 级仅一阶")

	_set_level(w, b, 2)
	eq(w.base_level_of("p1"), 2, "升到 2 级")
	eq(w.base_max_generals("p1"), 6, "★ 2 级将领上限 6")
	eq(w.base_retinue_bonus("p1"), 2, "★ 2 级编制 +2")
	eq(w.tech_max_active("p1"), 2, "★ 2 级最多 2 条科技")
	eq(w.tech_max_tier("p1"), 2, "★ 2 级到二阶")

	_set_level(w, b, 3)
	eq(w.base_max_generals("p1"), 10, "★ 3 级将领上限 10")
	eq(w.base_retinue_bonus("p1"), 4, "★ 3 级编制 +4")
	eq(w.tech_max_active("p1"), 3, "★ 3 级最多 3 条科技")
	eq(w.tech_max_tier("p1"), 3, "★ 3 级到三阶")

	# 没有大本营的阵营（AI / NPC）：不受限（0 = 不约束）
	eq(w.base_level_of("enemy"), 0, "没有大本营的阵营 level = 0")
	eq(w.base_max_generals("enemy"), 9999, "没有大本营 → 将领数不限制")
	eq(w.tech_max_tier("enemy"), 3, "没有大本营 → 科技阶不限制")

# ------------------------------------------------------------------
# 科技：阶 + 名额
# ------------------------------------------------------------------

func _test_tech_gating(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	eq(w.tech_can_activate("food_1"), "", "1 级：第一行（一阶）科技可以启用")
	eq(w.tech_can_activate("gold_1"), "",
		"1 级：还没启用任何科技时，第一行的任意一条都能当「那一条」")
	eq(w.tech_can_activate("food_2"), "tier", "★ 1 级：第二行（二阶）被阶数挡住（tier）")
	eq(w.tech_can_activate("zone_population"), "tier", "★ 1 级：第三行（三阶）被阶数挡住（tier）")

	var entries: Array = w.tech_entries()
	var by_id: Dictionary = {}
	for e in entries:
		by_id[String((e as Dictionary).get("id", ""))] = e
	eq(int((by_id["food_2"] as Dictionary).get("tier", 0)), 2, "★ 九格数据带 tier")
	ok(not bool((by_id["food_2"] as Dictionary).get("available", true)),
		"★ 1 级：第二行格 available = false（界面置灰）")
	eq(String((by_id["food_2"] as Dictionary).get("reason", "")), "tier", "拒因 = tier")
	ok(bool((by_id["food_1"] as Dictionary).get("available", false)),
		"第一行格 available = true")

	ok(w.set_tech_active("food_1", true), "启用 food_1")
	eq(w.tech_can_activate("gold_1"), "limit", "名额用完后第一行的另一条被名额挡住")
	ok(w.set_tech_active("food_1", false), "弃用 food_1")

	_set_level(w, b, 2)
	eq(w.tech_can_activate("food_2"), "", "★ 2 级：第二行科技可以启用")
	ok(w.set_tech_active("food_2", true), "启用 food_2")
	eq(w.tech_can_activate("building_hp"), "", "2 级：第一行仍可再启用一条")
	ok(w.set_tech_active("building_hp", true), "再启用一条第一行（凑满 2 条）")
	eq(w.tech_can_activate("gold_2"), "limit", "★ 2 级：第 3 条被名额挡住")
	eq(w.tech_can_activate("zone_population"), "tier", "★ 2 级：三阶仍被阶数挡住")

	_set_level(w, b, 3)
	ok(w.set_tech_active("zone_population", true), "★ 3 级：第三行科技可以启用（第 3 条）")
	eq(w.active_tech_ids().size(), 3, "3 级可同时启用 3 条")
	eq(w.tech_remaining_slots(), 0, "名额用完")
	eq(w.tech_can_activate("leader_hp"), "limit", "3 级也已满：第 4 条被名额挡住")

# ------------------------------------------------------------------
# 将领数量硬上限
# ------------------------------------------------------------------

func _test_general_count_cap(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	eq(w.general_count_of("p1"), 3, "开局正好 3 名将领")
	var z = _own_zone(w)
	ok(z != null, "（前提）找得到己方区划")
	if z == null:
		return
	var zid := int(z["id"])
	# ★ 关卡开局摆了 #1-3（已拥有）。清掉「已拥有」集合，专门验**将领上限**这一条；
	#   否则会先撞上 owned / tier。
	w.general_recruit_pools["p1"]["taken"] = []
	var kind := "general_1"
	eq(w.can_recruit_zone(kind, zid, "p1"), "general_limit",
		"★ 1 级 3 将已满：区划招将被拒（general_limit）")
	_set_level(w, b, 2)
	eq(w.can_recruit_zone(kind, zid, "p1"), "",
		"★ 升到 2 级（上限 6）：可以继续招将")
	_set_level(w, b, 3)
	eq(w.base_max_generals("p1"), 10, "3 级上限 10")

# ------------------------------------------------------------------
# 编制上限硬拦截
# ------------------------------------------------------------------

func _test_retinue_cap(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	var g = null
	for u in w.units:
		if u.alive and u.is_general() and String(u.faction) == "p1":
			g = u
			break
	ok(g != null, "（前提）找得到将领")
	if g == null:
		return
	eq(w.effective_retinue_cap(g), 11, "1 级：编制 = 基础 11")
	_set_level(w, b, 2)
	eq(w.effective_retinue_cap(g), 13, "★ 2 级：编制 11 + 2 = 13")
	_set_level(w, b, 3)
	eq(w.effective_retinue_cap(g), 15, "★ 3 级：编制 11 + 4 = 15")

	# 降回 1 级，把这位将领补到满编（11），再招兵必须被 cap 挡住。
	_set_level(w, b, 1)
	var need: int = maxi(0, w.effective_retinue_cap(g) - g.retinue_size(w))
	if need > 0:
		w.fill_general_retinue(g, need, [])
	eq(g.retinue_size(w), 11, "（前提）已满编 11")
	ok(w.leader_zone_owned(g), "（前提）将领站在己方区划里")
	eq(w.can_recruit("spearman", String(g.id), "p1"), "cap",
		"★ 满编时拒绝继续招募（cap）")
	_set_level(w, b, 2)
	eq(w.can_recruit("spearman", String(g.id), "p1"), "",
		"★ 升到 2 级（编制 13）后立刻可以再招")

# ------------------------------------------------------------------
# 大本营本身：攻击数值与不可摧毁标记
# ------------------------------------------------------------------

func _test_base_attack(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	ok(b.is_attackable(w.cfg), "★ 大本营可攻击")
	ok(not b.is_invulnerable(), "大本营不是无敌建筑")
	for lv in [1, 2, 3]:
		_set_level(w, b, lv)
		near(b.attack_damage(w.cfg), 12.0, 1e-6, "%d 级大本营伤害 = 箭塔的 12" % lv)
		near(b.attack_range(w.cfg), 3.0, 1e-6, "%d 级大本营射程 = 3" % lv)
		near(b.attack_cooldown(w.cfg), 0.8, 1e-6, "%d 级大本营间隔 = 0.8s" % lv)

# ------------------------------------------------------------------
# 单位招募的「按行解锁」（第 2 / 3 行要 2 / 3 级大本营）
# ------------------------------------------------------------------

func _test_unit_recruit_tiers(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	var g = null
	for u in w.units:
		if u.alive and u.is_general() and String(u.faction) == "p1":
			g = u
			break
	ok(g != null, "（前提）找得到一位己方将领")
	if g == null:
		return
	ok(w.leader_zone_owned(g), "（前提）将领站在己方区划里")

	_set_level(w, b, 1)
	eq(w.unit_recruit_level("p1"), 1, "1 级大本营 = 只开第 1 行")
	eq(w.can_recruit("spearman", String(g.id), "p1"), "", "第 1 行（长枪兵）1 级可招")
	eq(w.can_recruit("rider", String(g.id), "p1"), "tier", "★ 第 2 行（骑手）1 级被挡")
	eq(w.can_recruit("grain_cart", String(g.id), "p1"), "tier", "★ 第 2 行（粮车）1 级被挡")
	eq(w.can_recruit("knight", String(g.id), "p1"), "tier", "★ 第 3 行（骑士）1 级被挡")
	eq(w.can_recruit("catapult", String(g.id), "p1"), "tier", "★ 第 3 行（投石车）1 级被挡")

	_set_level(w, b, 2)
	eq(w.unit_recruit_level("p1"), 2, "2 级大本营 = 开到第 2 行")
	eq(w.can_recruit("rider", String(g.id), "p1"), "", "★ 2 级解锁骑手")
	eq(w.can_recruit("grain_cart", String(g.id), "p1"), "", "★ 2 级解锁粮车")
	eq(w.can_recruit("knight", String(g.id), "p1"), "tier", "第 3 行在 2 级仍然被挡")
	eq(w.can_recruit("horse_archer", String(g.id), "p1"), "tier", "马弓手在 2 级仍然被挡")
	eq(w.can_recruit("catapult", String(g.id), "p1"), "tier", "投石车在 2 级仍然被挡")

	_set_level(w, b, 3)
	eq(w.unit_recruit_level("p1"), 3, "3 级大本营 = 三行全开")
	eq(w.can_recruit("knight", String(g.id), "p1"), "", "★ 3 级解锁骑士")
	eq(w.can_recruit("horse_archer", String(g.id), "p1"), "", "★ 3 级解锁马弓手")
	eq(w.can_recruit("catapult", String(g.id), "p1"), "", "★ 3 级解锁投石车")

	# ★★ 无消耗招募（AI 专用）跳过行号：否则没有大本营的守军 AI 一个兵都补不出来。
	_set_level(w, b, 1)
	eq(w.can_recruit("catapult", String(g.id), "p1", true), "",
		"★ free / AI 招募不受大本营行号限制")


# ------------------------------------------------------------------
# 开发者快捷键 Ctrl+3 的底层入口：大本营立即升到 3 级
# ------------------------------------------------------------------

func _test_debug_upgrade_base(cfg) -> void:
	var w = _world(cfg)
	var b = _base(w)
	if b == null:
		return
	_set_level(w, b, 1)
	w.resources["food"] = 10000.0
	w.resources["gold"] = 10000.0
	# 先起一条正常升级读条：Ctrl+3 必须把它撤掉，否则读完后会从 3 级再 +1。
	ok(w.start_building_upgrade(b.tx, b.ty, "p1"), "（前提）大本营能开始正常升级")
	ok(b.is_upgrading(), "（前提）升级读条已经在跑")

	eq(w.debug_upgrade_base_to_level(3, "p1"), "", "★ 开发者入口：立即升到 3 级")
	eq(int(b.level), 3, "★ 等级当场变成 3")
	ok(not b.is_upgrading(), "★ 原来那条升级读条被撤掉")
	eq(w.base_level_of("p1"), 3, "★ 大本营等级查询当场读到 3")
	eq(w.base_max_generals("p1"), 10, "★ 3 级限制（10 将）当场生效")
	near(b.hp_max, b.base_hp_max * cfg.upgrade_hp_mult("base", 3), 1e-6,
		"★ 血量上限按 3 级的 hp_mult 重算")
	eq(w.debug_upgrade_base_to_level(3, "p1"), "already", "已经是 3 级 → already")
	eq(w.debug_upgrade_base_to_level(3, "no_such_faction"), "no_base",
		"没有大本营的阵营 → no_base")

	# 之后再 tick 很久，也不能从 3 级读到 4 级。
	for _i in 600:
		w.tick(DT)
	eq(int(b.level), 3, "★ 撤掉读条后不会继续升到 4 级")


# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

func _world(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world_with_escorts(c, 3, "p1")

func _base(w):
	return w.find_base_of("p1")

func _set_level(w, b, lv: int) -> void:
	b.level = lv
	w.apply_building_level_hp(b)

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != "p1":
			continue
		if z["center"] == null:
			continue
		return z
	return null
