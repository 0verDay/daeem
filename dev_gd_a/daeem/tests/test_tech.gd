## test_tech.gd —— 科技模块（右下「科技」页签 → 3×3 九格 → 启用 / 弃用）
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")

const DT := 1.0 / 60.0
const T_FOOD := "food_1"
const T_FOOD2 := "food_2"
const T_GOLD := "gold_1"
const T_BUILDING := "building_hp"
const T_LEADER := "leader_hp"
const T_POP := "zone_population"

func _initialize() -> void:
	_case_name = "test_tech"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_toggle_basics(cfg)
	_test_limit_three(cfg)
	_test_food_and_gold_bonus(cfg)
	_test_hp_bonus(cfg)
	_test_population_bonus(cfg)
	_test_commands(cfg)

func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	eq(w.tech_list().size(), 9, "★ 表里有 9 条占位科技（铺满 3×3 九格）")
	eq(w.tech_max_active(), 3, "★ 同一时间最多启用 3 条（config.tech.max_active）")
	var ids: Array = []
	for e in w.tech_list():
		ids.append(String((e as Dictionary).get("id", "")))
	eq(ids.size(), 9, "九条都有 id")
	for want in ["food_1", "food_2", "food_3", "gold_1", "gold_2", "gold_3",
			"building_hp", "leader_hp", "zone_population"]:
		ok(ids.has(want), "表里有 %s" % want)
	var missing: Array = []
	for e2 in w.tech_list():
		var d: Dictionary = e2
		if String(d.get("name", "")) == "" or String(d.get("line", "")) == "" \
				or String(d.get("desc", "")) == "":
			missing.append(String(d.get("id", "?")))
	eq(missing.size(), 0, "★ 九条都配齐了 name / line / desc（缺的：%s）" % str(missing))

	var entries: Array = w.tech_entries()
	eq(entries.size(), 9, "★ tech_entries() 给出九格")
	eq(String((entries[0] as Dictionary).get("id", "")), "food_1", "第 1 格 = 粮食产量 I")
	ok(not bool((entries[0] as Dictionary).get("active", true)), "开局一条都没启用")

func _test_toggle_basics(cfg) -> void:
	var w = _quiet(cfg)
	ok(not w.is_tech_active(T_FOOD), "开局 food_1 没启用")
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": true}),
		"★ tech_toggle(on) 命令被接受")
	ok(w.is_tech_active(T_FOOD), "启用之后是启用状态")
	eq(w.active_tech_ids().size(), 1, "启用列表里有 1 条")
	eq(w.tech_remaining_slots(), 2, "还剩 2 个名额")
	var act := false
	for e in w.tech_entries():
		if String((e as Dictionary).get("id", "")) == T_FOOD:
			act = bool((e as Dictionary).get("active", false))
	ok(act, "★ tech_entries() 里这一格标成 active（界面按它画高亮）")

	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": true}),
		"重复启用同一条返回 false（状态没变）")
	eq(w.active_tech_ids().size(), 1, "★ 重复启用不会占用第二个名额")

	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": false}),
		"★ tech_toggle(off) 命令被接受")
	ok(not w.is_tech_active(T_FOOD), "★ 弃用之后不再是启用状态")
	eq(w.active_tech_ids().size(), 0, "启用列表空了")
	eq(w.tech_remaining_slots(), 3, "名额全回来了")
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD}),
		"不带 on 的 tech_toggle = 切换（点一下格子的语义）")
	ok(w.is_tech_active(T_FOOD), "切换之后启用了")
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD}),
		"再切换一次")
	ok(not w.is_tech_active(T_FOOD), "★ 第二次切换 = 弃用")

	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": "nope", "on": true}),
		"不存在的科技 id 被拒")
	ok(not w.is_tech_active("nope"), "不存在的科技不会进启用列表")

func _test_limit_three(cfg) -> void:
	var w = _quiet(cfg)
	for id in [T_FOOD, T_FOOD2, T_GOLD]:
		ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": id, "on": true}),
			"启用第 %d 条" % (w.active_tech_ids().size()))
	eq(w.active_tech_ids().size(), 3, "★ 三条都启用了")
	eq(w.tech_remaining_slots(), 0, "名额用完")
	ok(w.tech.can_activate(T_BUILDING) == "limit", "★ 第 4 条被规则判为 limit")
	ok(not w.is_tech_active(T_BUILDING), "第 4 条现在没启用")
	eq(w.tech_remaining_slots(), 0, "world.tech_remaining_slots() 也是 0")

	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_BUILDING, "on": true}),
		"第 4 条的命令被拒")
	var evts: Array = w.tick(DT)
	var got_reject := false
	for e in evts:
		if String((e as Dictionary).get("type", "")) == "tech_rejected" \
				and String((e as Dictionary).get("reason", "")) == "limit":
			got_reject = true
	ok(got_reject, "★ 第 4 条被阻止，并留了一条 tech_rejected(limit) 给界面提示")
	ok(not w.is_tech_active(T_BUILDING), "★ 第 4 条没有生效")
	eq(w.active_tech_ids().size(), 3, "启用数仍然是 3")

	ok(w.set_tech_active(T_GOLD, false), "弃用中间那一条")
	ok(w.set_tech_active(T_BUILDING, true), "★ 腾出名额之后第 4 条可以启用")
	ok(w.is_tech_active(T_BUILDING), "它现在生效")
	eq(w.active_tech_ids().size(), 3, "又是 3 条")

	w.reset()
	eq(w.active_tech_ids().size(), 0, "★ reset() 之后一条科技都没启用")

func _test_food_and_gold_bonus(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)                       # 先把区划产能清零，只留科技那一份
	w.tick(DT)
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	var tiles: int = int(w.owned_tiles)
	ok(tiles > 0, "开局有己方占领地块（大本营把出生区划收归己方）")
	if tiles <= 0:
		return
	var f0: float = w.production_food
	var g0: float = w.production_gold

	ok(w.set_tech_active(T_FOOD, true), "启用「粮食产量 I」")
	near(w.production_food, f0 + 0.05 * float(tiles), 1e-6,
		"★ 粮食 +0.05/地块/秒（%d 地块 → +%s/秒）" % [tiles, 0.05 * tiles])
	near(w.production_gold, g0, 1e-6, "黄金不受影响")

	ok(w.set_tech_active(T_FOOD2, true), "再启用「粮食产量 II」")
	near(w.production_food, f0 + 0.15 * float(tiles), 1e-6,
		"★ 两条叠加 = +0.15/地块/秒（加产量求和）")

	var before: float = float(w.resources["food"])
	w.tick(1.0)
	near(float(w.resources["food"]) - before, w.production_food, 1e-3,
		"★ 一秒钟涨的量 = HUD 上显示的那个「+n/秒」")

	w.resources["gold"] = 0.0
	ok(w.set_tech_active(T_GOLD, true), "启用「黄金产量 I」")
	near(w.production_gold, g0 + 0.05 * float(tiles), 1e-6,
		"★ 黄金 +0.05/地块/秒")

	w.set_tech_active(T_FOOD, false)
	w.set_tech_active(T_FOOD2, false)
	near(w.production_food, f0, 1e-6, "★ 弃用之后粮食加成归零")
	w.set_tech_active(T_GOLD, false)
	near(w.production_gold, g0, 1e-6, "弃用之后黄金加成归零")

func _test_hp_bonus(cfg) -> void:
	var w = _quiet(cfg)
	var base = w.find_base_of("p1")
	var wall = _player_wall(w)
	var leader = w.unit_by_id("general-1")
	var sub = _first_retinue(w)
	ok(base != null, "有己方大本营")
	ok(wall != null, "有一栋己方城墙（大本营旁的防御阵地）")
	ok(leader != null, "有将领 general-1")
	ok(sub != null, "有附属兵（用来验「只加将领、不加附属兵」）")
	if base == null or wall == null or leader == null or sub == null:
		return

	var base_max: float = base.hp_max
	var wall_max: float = wall.hp_max
	var leader_max: float = leader.hp_max
	var sub_max: float = sub.hp_max
	wall.hp = wall_max * 0.75
	var wall_hp: float = wall.hp

	ok(w.set_tech_active(T_BUILDING, true), "启用「建筑加固」")
	near(base.hp_max, base_max * 1.1, 1e-3, "★ 已建好的大本营血量上限 +10%")
	near(wall.hp_max, wall_max * 1.1, 1e-3, "★ 已建好的城墙血量上限 +10%")
	near(wall.hp / wall.hp_max, wall_hp / wall_max, 1e-6,
		"★ 当前血量按比例缩放（残血的墙不会因为加成变成满血）")
	near(leader.hp_max, leader_max, 1e-6, "只启用建筑那一条时，将领血量不变")

	ok(w.set_tech_active(T_LEADER, true), "启用「将领强化」")
	near(leader.hp_max, leader_max * 1.1, 1e-3, "★ 将领血量上限 +10%")
	near(sub.hp_max, sub_max, 1e-6, "★ 附属兵不吃这一条（需求只写将领）")
	near(base.hp_max, base_max * 1.1, 1e-3, "建筑那一条仍在生效（两条互不影响）")

	w.tick(DT)
	near(leader.hp_max, leader_max * 1.1, 1e-3, "★ 反复推进不会重复放大血量")
	near(base.hp_max, base_max * 1.1, 1e-3, "建筑同理")

	var nb = _build_wall_near(w)
	ok(nb != null, "找得到一格空地，能造一栋新墙")
	if nb != null:
		near(nb.hp_max, float(w.cfg.num("building.wall.hp_max", 300.0)) * 1.1, 1e-3,
			"★ 新造的建筑当场带上 +10%")

	var ratio_before: float = leader.hp / leader.hp_max
	w.set_tech_active(T_LEADER, false)
	near(leader.hp_max, leader_max, 1e-3, "★ 弃用之后将领上限回到基础值")
	near(leader.hp / leader.hp_max, ratio_before, 1e-6, "弃用同样按比例缩放当前血量")
	w.set_tech_active(T_BUILDING, false)
	near(base.hp_max, base_max, 1e-3, "弃用之后大本营血量上限回到基础值")
	near(wall.hp_max, wall_max, 1e-3, "弃用之后城墙血量上限回到基础值")

func _test_population_bonus(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	var theirs = _foreign_zone(w)
	ok(mine != null, "有一块己方区划")
	ok(theirs != null, "有一块别人（无主 / 敌方）的区划")
	if mine == null or theirs == null:
		return

	for z in [mine, theirs]:
		(z["production"] as Dictionary)["population"] = 2.0
		z["population"] = 0.0
		z["population_cap"] = 1000.0

	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0, 1e-6,
		"没科技时己方区划按基础速度涨（固定 2/秒，不乘地块数）")
	near(float(theirs["population"]), 2.0, 1e-6, "没科技时别人区划按基础速度涨")

	for z in [mine, theirs]:
		z["population"] = 0.0
	ok(w.set_tech_active(T_POP, true), "启用「区划人口」")
	near(w.tech_population_mult(), 1.1, 1e-6, "★ 人口增长倍率变成 1.1")
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0 * 1.1, 1e-6,
		"★ 己方区划人口涨得快 10%")
	near(float(theirs["population"]), 2.0, 1e-6,
		"★ 别人（无主 / 敌方）的区划**不受**加成")

	for z in [mine]:
		z["population"] = 0.0
	w.tick(1.0)
	near(float(mine["population"]), 2.0 * 1.1, 1e-3, "★ world.tick 里同样生效")

	mine["population"] = float(mine["population_cap"]) - 0.001
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), float(mine["population_cap"]), 1e-6,
		"★ 科技加的是速度，不是上限：涨到 population_cap 就停")

	mine["population"] = 0.0
	ok(w.set_tech_active(T_POP, false), "弃用「区划人口」")
	near(w.tech_population_mult(), 1.0, 1e-6, "倍率回到 1.0")
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0, 1e-6, "★ 弃用之后回到基础速度")

func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_POP}), "切换命令")
	ok(w.is_tech_active(T_POP), "切换 = 启用")
	near(w.tech_population_mult(), 1.1, 1e-6, "★ 命令生效后当帧就能读到加成")
	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": ""}),
		"空 id 的命令被拒")
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")

func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world_with_escorts(c, 3)

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != w.my_faction:
			continue
		return z
	return null

func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == w.my_faction:
			continue
		return z
	return null

func _player_wall(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL \
				and String(b.owner) == w.my_faction:
			return b
	return _build_wall_near(w)      # 开局不再自动生成防御阵地 → 没有就现造一栋

func _first_retinue(w):
	for u in w.units:
		if u.alive and u.leader_id != "" and String(u.faction) == w.my_faction:
			return u
	return null

func _build_wall_near(w):
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.can_build_at(x, y):
				continue
			var b = w.add_building(BuildingRes.TYPE_WALL, x, y, w.my_faction, true, true)
			if b != null:
				return b
	return null
