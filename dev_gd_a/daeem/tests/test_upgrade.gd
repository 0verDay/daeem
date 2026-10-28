## test_upgrade.gd —— 建筑升级 + 区划特化（右下「操作」页签里那几格）
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const DT := 1.0 / 60.0
const BIG_STEP := 60.0

func _initialize() -> void:
	_case_name = "test_upgrade"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_zone_kind_table(cfg)
	_test_reject_rules(cfg)
	_test_base_general_gate(cfg)
	_test_base_upgrade_fast_time(cfg)
	_test_upgrade_flow(cfg)
	_test_cancel_refund(cfg)
	_test_upgrade_scales_with_tech(cfg)
	_test_specialize_flow(cfg)
	_test_spec_stacks_with_tech(cfg)
	_test_cancel_spec(cfg)
	_test_commands(cfg)
	_test_respawn_blocks_base_upgrade(cfg)

func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	ok(cfg.has_upgrade("base"), "大本营有升级表")
	ok(not cfg.has_upgrade("wall"), "★★ 木墙没有升级表（本轮取消建筑升级）")
	ok(not cfg.has_upgrade("tower"), "★★ 哨塔没有升级表（本轮取消建筑升级）")
	ok(not cfg.has_upgrade(BuildingRes.TYPE_ZONE_CENTER),
		"★ 区划中心**没有**升级表（它走特化那三个选项）")
	eq(cfg.upgrade_max_level("base"), 3, "★ 大本营最多 3 级（config 里 3 条）")
	eq(cfg.upgrade_max_level("wall"), 1, "★★ 木墙不能升级（最大等级 1）")
	near(cfg.upgrade_hp_mult("base", 1), 1.0, 1e-6, "1 级血量倍率 1.0")
	near(cfg.upgrade_hp_mult("base", 2), 1.5, 1e-6, "★ 2 级血量倍率 1.5")
	near(cfg.upgrade_hp_mult("base", 3), 2.25, 1e-6, "★ 3 级血量倍率 2.25")
	var c1: Dictionary = cfg.upgrade_cost_to("base", 1)
	near(float(c1.get("food", 0.0)), 200.0, 1e-6, "升到 2 级要 200 粮食（造价 ×2）")
	near(cfg.upgrade_time_to("base", 1), 40.0, 1e-6, "升到 2 级读条 40 秒")
	var c2: Dictionary = cfg.upgrade_cost_to("base", 2)
	near(float(c2.get("food", 0.0)), 400.0, 1e-6, "★ 升到 3 级更贵（400 粮食，造价 ×2）")
	near(cfg.upgrade_time_to("base", 2), 80.0, 1e-6, "★ 升到 3 级读条更久（80 秒）")
	# ★ 提速档：≥5 将时 60 秒（只有 2→3 这一档有）。
	near(cfg.upgrade_time_fast_to("base", 2), 60.0, 1e-6, "★ 升 3 本的提速档 = 60 秒")
	eq(cfg.upgrade_fast_need_generals("base", 2), 5, "★ 提速档门槛 = 5 名将领")
	ok(cfg.upgrade_time_fast_to("base", 1) <= 0.0, "升 2 本没有提速档")
	ok(cfg.upgrade_cost_to("base", 3).is_empty(), "3 级（最高级）没有 next 的价钱")
	near(cfg.upgrade_time_to("base", 3), 0.0, 1e-6, "最高级没有 next 的读条")

	eq(cfg.spec_list().size(), 3, "★ 三个特化（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_spec(want), "特化表里有 %s" % want)
	near(float(cfg.spec_entry("food").get("effect", {}).get("food_per_tile", 0.0)), 0.04, 1e-6,
		"★ 粮食特化 = 每地块每秒额外 0.04 粮食")
	near(float(cfg.spec_entry("gold").get("effect", {}).get("gold_per_tile", 0.0)), 0.04, 1e-6,
		"★ 黄金特化 = 每地块每秒额外 0.04 黄金")
	near(float(cfg.spec_entry("population").get("effect", {}).get("population_mult", 0.0)), 0.1, 1e-6,
		"★ 人口特化 = 本区划人口产量 +10%")
	near(cfg.spec_time_sec("food"), 10.0, 1e-6, "★ 特化读条 10 秒")
	var sc: Dictionary = cfg.spec_cost("food")
	near(float(sc.get("food", 0.0)), 100.0, 1e-6, "特化要 100 粮食（造价 ×2）")
	near(float(sc.get("gold", 0.0)), 100.0, 1e-6, "特化要 100 黄金（造价 ×2）")
	ok(w.building_can_upgrade("base"), "world 转发：大本营能升级")
	ok(not w.building_can_upgrade(BuildingRes.TYPE_WALL), "★★ world 转发：木墙不能升级")
	ok(not w.building_can_upgrade(BuildingRes.TYPE_ZONE_CENTER), "world 转发：区划中心不能升级")

func _test_zone_kind_table(cfg) -> void:
	eq(cfg.zone_kind_list().size(), 3, "★ 三种区划（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_zone_kind(want), "种类表里有 %s" % want)
	eq(cfg.zone_kind_default(), "population", "★ 地图没写 kind 时算人口区划（用户确认）")
	ok(not cfg.has_zone_kind("none"), "★ 没有「默认区划」这一档了")
	eq(cfg.zone_kind_name("food"), "粮食区划", "种类名字来自 config")
	var pf: Dictionary = cfg.zone_kind_production("food")
	near(float(pf["food"]), 1.5, 1e-6, "★ 粮食区划预设 = 每秒 1.5 粮食")
	near(float(pf["gold"]), 0.0, 1e-6, "粮食区划不产黄金")
	near(float(pf["population"]), 0.15, 1e-6,
		"★ 粮食区划也带 0.15 人口（所有区划都带一份人口产能）")
	var pg: Dictionary = cfg.zone_kind_production("gold")
	near(float(pg["gold"]), 1.2, 1e-6, "★ 黄金区划预设 = 每秒 1.2 黄金（降幅最大）")
	near(float(pg["population"]), 0.15, 1e-6, "★ 黄金区划也带 0.15 人口")
	var pp: Dictionary = cfg.zone_kind_production("population")
	near(float(pp["population"]), 0.4, 1e-6, "★ 人口区划预设 = 每秒 0.4 人口")
	near(float(pp["food"]), 0.8, 1e-6, "★ 人口区划也产粮（每秒 0.8 粮食）")
	near(float(pp["gold"]), 0.0, 1e-6, "人口区划不产黄金")
	for kind_id in ["food", "gold", "population"]:
		ok(float(cfg.zone_kind_production(kind_id)["population"]) > 0.0,
			"★ %s 的预设人口产能 > 0（实际 %s）"
			% [kind_id, cfg.zone_kind_production(kind_id)["population"]])
	ok(cfg.zone_kind_allows_spec("food", "gold"), "粮食区划能做黄金特化")
	ok(cfg.zone_kind_allows_spec("food", "population"), "粮食区划能做人口特化")
	ok(not cfg.zone_kind_allows_spec("food", "food"), "★ 粮食区划**不能**做粮食特化")
	ok(cfg.zone_kind_allows_spec("gold", "food"), "黄金区划能做粮食特化")
	ok(cfg.zone_kind_allows_spec("gold", "population"), "黄金区划能做人口特化")
	ok(not cfg.zone_kind_allows_spec("gold", "gold"), "★ 黄金区划**不能**做黄金特化")
	ok(cfg.zone_kind_allows_spec("population", "food"), "人口区划能做粮食特化")
	ok(cfg.zone_kind_allows_spec("population", "gold"), "人口区划能做黄金特化")
	ok(not cfg.zone_kind_allows_spec("population", "population"), "★ 人口区划**不能**做人口特化")
	eq(cfg.zone_kind_name("banana"), "人口区划", "认不出的种类 → 默认那一档")
	near(float(cfg.zone_kind_production("banana")["population"]), 0.4, 1e-9,
		"认不出的种类 → 拿默认那一档的预设值（人口区划 0.4）")

	var w = _quiet(cfg)
	var kinds: Dictionary = {}
	var unknown: Array = []
	for z in w.zones.zones:
		var k := String(z["kind"])
		kinds[k] = int(kinds.get(k, 0)) + 1
		if not cfg.has_zone_kind(k):
			unknown.append("%s=%s" % [String(z["name"]), k])
		eq(w.zone_kind_of(z), w.zones.kind_of(z),
			"world 转发的种类 = 区块自己那一格（%s）" % String(z["name"]))
	ok(unknown.is_empty(),
		"★ 发布地图的每个区块都是表里认识的种类（认不出的：%s）" % str(unknown))
	print("   [kinds] 发布地图的区划种类分布：%s（共 %d 块）" % [str(kinds), w.zones.zones.size()])
	eq(w.zone_kind_of(w.zones.zones[0]), w.zones.kind_of(w.zones.zones[0]),
		"world 转发的种类查询（第一个区块）")

func _test_reject_rules(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var base = w.find_base_of("p1")
	var wall = _player_wall(w)
	ok(base != null, "有己方大本营")
	ok(wall != null, "有己方木墙")
	if base == null or wall == null:
		return
	var f: String = String(w.my_faction)
	_ensure_generals(w, 3, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "", "平常状态下大本营可以升级")
	eq(UpgradeRes.can_upgrade(w, null, f), "type", "不存在的建筑 → type")
	eq(UpgradeRes.can_upgrade(w, wall, f), "type", "★★ 木墙不再能升级（只有大本营可升）")
	var zc = _zone_center(w)
	if zc != null:
		eq(UpgradeRes.can_upgrade(w, zc, f), "type", "★ 区划中心不能升级（没有升级表）")
	var foe = _enemy_base(w)
	if foe != null:
		eq(UpgradeRes.can_upgrade(w, foe, f), "owner", "★ 别人的大本营不能升级")
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	eq(UpgradeRes.can_upgrade(w, base, f), "cost", "★ 钱不够 → cost")
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	base.level = cfg.upgrade_max_level("base")
	eq(UpgradeRes.can_upgrade(w, base, f), "max_level", "★ 满级之后不能再升")
	base.level = 1
	ok(w.start_building_upgrade(base.tx, base.ty), "开始一次升级")
	eq(UpgradeRes.can_upgrade(w, base, f), "busy", "★ 读条中再升同一栋 → busy")

## ★★ 升 2 本要 2 将，升 3 本要 4 将（门槛读 config 的 need_generals，与上限 2/5/6 是两件事）。
func _test_base_general_gate(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var base = w.find_base_of(w.my_faction)
	if base == null:
		ok(false, "（前提）有大本营")
		return
	var f := String(w.my_faction)
	base.level = 1
	_ensure_generals(w, 1, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "generals",
		"★★ 只有 1 将时不能升二本")
	ok(not w.start_building_upgrade(base.tx, base.ty, f),
		"★★ 将领不足时升级命令被拒")
	_ensure_generals(w, 2, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "",
		"★★ 2 将后可以升二本")
	base.level = 2
	_ensure_generals(w, 3, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "generals",
		"★★ 只有 3 将时不能升三本")
	_ensure_generals(w, 4, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "",
		"★★ 4 将后可以升三本")


## ★★ 升三本的提速档：4 将 → 80 秒；≥5 将 → 60 秒；且**开始那一刻定死**。
func _test_base_upgrade_fast_time(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var base = w.find_base_of(w.my_faction)
	if base == null:
		ok(false, "（前提）有大本营")
		return
	var f := String(w.my_faction)

	# ① 升二本：40 秒（没有提速档）
	_ensure_generals(w, 2, f)
	base.level = 1
	ok(w.start_building_upgrade(base.tx, base.ty, f), "（前提）2 将时开始升二本")
	near(base.upgrade_total, 40.0, 1e-6, "★ 升二本读条 40 秒")
	w.cancel_building_upgrade(base.tx, base.ty, f)

	# ② 升三本 · 4 将：80 秒
	base.level = 2
	_ensure_generals(w, 4, f)
	ok(w.start_building_upgrade(base.tx, base.ty, f), "（前提）4 将时开始升三本")
	near(base.upgrade_total, 80.0, 1e-6, "★ 4 将升三本读条 80 秒")

	# ③ 读条中补到 5 将 ⇒ 总时长**不重算**（开始时定死）
	_ensure_generals(w, 5, f)
	near(base.upgrade_total, 80.0, 1e-6, "★★ 读条中补到 5 将也不改总时长（定死）")
	near(w.building_upgrade_time(base), 60.0, 1e-6,
		"（对照）现在再问一次会选 60 秒那档 —— 但这一条读条不受影响")
	w.cancel_building_upgrade(base.tx, base.ty, f)

	# ④ 5 将从头开始：60 秒
	ok(w.start_building_upgrade(base.tx, base.ty, f), "（前提）5 将时开始升三本")
	near(base.upgrade_total, 60.0, 1e-6, "★★ 5 将升三本读条降到 60 秒")


func _test_upgrade_flow(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	_ensure_generals(w, 3, w.my_faction)
	var base = w.find_base_of(w.my_faction)
	ok(base != null, "有大本营")
	if base == null:
		return
	var lv0: int = base.level
	var hp0: float = base.hp_max
	var cost: Dictionary = w.building_upgrade_cost(base)
	var food0: float = float(w.resources["food"])
	eq(lv0, 1, "大本营开局 1 级")

	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": base.tx, "ty": base.ty}),
		"★ building_upgrade 命令被接受")
	ok(base.is_upgrading(), "★ 开始读条（is_upgrading）")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-6,
		"★ 入队即扣粮食")
	near(base.upgrade_progress(), 0.0, 1e-6, "刚入队时进度是 0")
	near(base.upgrade_eta(), w.building_upgrade_time(base), 1e-6, "剩余时间 = 整条读条")
	eq(UpgradeRes.can_upgrade(w, base, w.my_faction), "busy", "读条中拒绝新的升级请求")

	var half: float = maxf(0.01, base.upgrade_total * 0.5)
	w.tick(half)
	eq(base.level, lv0, "★ 读条没读完时等级不变")
	near(base.upgrade_progress(), 0.5, 0.02, "进度条走到一半")
	near(base.hp_max, hp0, 1e-6, "血量上限也还没变")

	w.tick(BIG_STEP)
	ok(not base.is_upgrading(), "★ 读条结束")
	eq(base.level, lv0 + 1, "★ 等级 +1")
	var mult: float = cfg.upgrade_hp_mult("base", base.level)
	near(base.hp_max, base.base_hp_max * mult, 1e-3, "★ 血量上限 = 基础值 × 等级倍率")

	var w2 = _quiet(cfg)
	var base2 = w2.find_base_of(w2.my_faction)
	_give(w2, 1000.0, 1000.0)
	_ensure_generals(w2, 3, w2.my_faction)
	base2.hp = base2.hp_max * 0.5
	w2.start_building_upgrade(base2.tx, base2.ty)
	w2.tick(BIG_STEP)
	near(base2.hp / base2.hp_max, 0.5, 1e-3, "★ 升级按比例带血（半血的大本营升完还是半血）")

	var w3 = _quiet(cfg)
	var base3 = w3.find_base_of(w3.my_faction)
	_give(w3, 1000.0, 1000.0)
	_ensure_generals(w3, 3, w3.my_faction)
	w3.start_building_upgrade(base3.tx, base3.ty)
	var evts: Array = w3.tick(BIG_STEP)
	var done := false
	for e in evts:
		if String((e as Dictionary).get("type", "")) == "upgrade_done" \
				and String((e as Dictionary).get("kind", "")) == "building_upgrade":
			done = true
	ok(done, "★ 升级完成留了一条 upgrade_done 事件")

	var w4 = _quiet(cfg)
	var base4 = w4.find_base_of("p1")
	_give(w4, 100000.0, 100000.0)
	_ensure_generals(w4, 6, "p1")
	for i in 5:
		w4.start_building_upgrade(base4.tx, base4.ty)
		w4.tick(BIG_STEP)
	eq(base4.level, cfg.upgrade_max_level("base"), "★ 连点多次也封顶在最高等级")
	near(base4.hp_max, base4.base_hp_max * cfg.upgrade_hp_mult("base", base4.level), 1e-3,
		"满级时的血量上限 = 基础值 × 满级倍率")

func _test_cancel_refund(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	_ensure_generals(w, 3, w.my_faction)
	var base = w.find_base_of(w.my_faction)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	w.start_building_upgrade(base.tx, base.ty)
	w.tick(DT * 10)
	ok(base.is_upgrading(), "还在读条中")
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade_cancel",
		"tx": base.tx, "ty": base.ty}), "★ building_upgrade_cancel 命令被接受")
	ok(not base.is_upgrading(), "★ 读条被取消")
	eq(base.level, 1, "等级没变")
	near(float(w.resources["food"]), food0, 1e-6, "★ 粮食全额退回")
	near(float(w.resources["gold"]), gold0, 1e-6, "★ 黄金全额退回")
	eq(UpgradeRes.can_cancel_upgrade(base, w.my_faction), "idle", "没有读条时不能取消")

	var w2 = _quiet(cfg)
	var base2 = w2.find_base_of(w2.my_faction)
	_give(w2, 1000.0, 1000.0)
	_ensure_generals(w2, 3, w2.my_faction)
	w2.start_building_upgrade(base2.tx, base2.ty)
	ok(base2.is_upgrading(), "大本营在读条")
	w2.remove_building(base2, true)
	ok(not base2.is_upgrading(), "★ 建筑离场 → 升级读条作废")

func _test_upgrade_scales_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	# 「建筑加固」是三阶科技：先把大本营拉到 3 级（等级限制由 test_base_limits 专门验）。
	var base = w.find_base_of(String(w.my_faction))
	var base_hp: float = base.base_hp_max
	base.level = w.cfg.upgrade_max_level("base")
	w.apply_building_level_hp(base)
	ok(w.set_tech_active("building_hp", true), "启用「建筑加固」（+10%）")
	near(base.hp_max, base_hp * cfg.upgrade_hp_mult("base", 3) * 1.1, 1e-3,
		"★ 上限 = 基础 × 等级(2.25) × 科技(1.1)（两者叠加）")
	w.set_tech_active("building_hp", false)
	near(base.hp_max, base_hp * cfg.upgrade_hp_mult("base", 3), 1e-3,
		"★ 弃用科技后只剩等级那一份（精确回到 2.25 倍）")

func _test_specialize_flow(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	var other = null
	for z in w.zones.zones:
		if z != mine:
			_claim(w, z)
			other = z
			break
	ok(mine != null, "有己方区划（大本营把它收归己方）")
	ok(other != null, "还有第二块己方区划（用来验「只影响本区块」）")
	if mine == null or other == null:
		return
	_give(w, 1000.0, 1000.0)
	for z in [mine, other]:
		z["production"] = {"food": 2.0, "gold": 3.0, "population": 1.0}
	var n_mine := float(mine["tile_count"])
	var f: String = String(w.my_faction)
	var zid := int(mine["id"])

	eq(UpgradeRes.can_specialize(w, mine, "food", f), "", "平常状态下可以做粮食特化")
	eq(UpgradeRes.can_specialize(w, mine, "nope", f), "spec", "不存在的特化 → spec")
	eq(UpgradeRes.can_specialize(w, null, "food", f), "zone", "没有区划 → zone")
	eq(String(mine["kind"]), "population", "（前提）这一块是人口区划")
	eq(UpgradeRes.can_specialize(w, mine, "population", f), "kind",
		"★ 人口区划做不了人口特化（拒因 kind）")
	eq(UpgradeRes.spec_choices(mine, cfg).size(), 2,
		"★ 人口区划的操作页只有两格特化（粮食 / 黄金）")
	var foreign = _foreign_zone(w)
	if foreign != null:
		eq(UpgradeRes.can_specialize(w, foreign, "food", f), "zone",
			"★ 不是自己的区划不能特化")

	var food0: float = float(w.resources["food"])
	ok(CommandRes.apply(w, w.cfg, {"kind": "zone_specialize", "zone_id": zid, "spec": "food"}),
		"★ zone_specialize 命令被接受")
	ok(UpgradeRes.zone_is_busy(mine), "★ 开始读条")
	eq(String(mine.get("spec_done", "")), "", "读条中还没生效（spec_done 还是空的）")
	near(float(w.resources["food"]), food0 - float(cfg.spec_cost("food").get("food", 0.0)), 1e-6,
		"★ 入队即扣粮食")
	eq(UpgradeRes.can_specialize(w, mine, "gold", f), "busy", "★ 读条中拒绝别的特化")
	near(UpgradeRes.zone_spec_progress(mine, cfg), 0.0, 1e-6, "刚入队进度 0")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6,
		"★ 读条还没读完 → 加成还没生效")

	w.tick(5.0)
	near(UpgradeRes.zone_spec_progress(mine, cfg), 0.5, 0.05, "读条走到一半")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6, "一半时加成仍未生效")

	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "★ 读条结束")
	eq(String(mine.get("spec_done", "")), "food", "★ 特化生效（spec_done = food）")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.04, 1e-6,
		"★ 粮食特化 = 每地块每秒 +0.04 粮食")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["gold_per_tile"], 0.0, 1e-6,
		"黄金不受粮食特化影响")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["population_mult"], 1.0, 1e-6,
		"人口倍率不受粮食特化影响")

	var rates: Dictionary = w.zones.production_of(f)
	near(float(rates["food"]), (2.0 + 0.04 * n_mine) + 2.0, 1e-3,
		"★ 粮食产出 = 本区块（固定基础 2 + 特化 0.04×地块）+ 别的区块固定 2")
	near(float(rates["gold"]), 3.0 + 3.0, 1e-3, "★ 黄金产出不变（两块各固定 3，无特化）")

	eq(UpgradeRes.can_specialize(w, mine, "gold", f), "spec_done",
		"★ 特化过的区块无法再次特化（spec_done）")
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "zone_specialize", "zone_id": zid, "spec": "gold"}),
		"★ 换一个特化的命令也走不通")
	eq(String(mine.get("spec_done", "")), "food", "★ 还是原来的粮食特化")

	var w2 = _quiet(cfg)
	w2.resources["food"] = 1000.0
	w2.resources["gold"] = 1000.0
	var z2 = _own_zone(w2)
	var z3 = null
	for z in w2.zones.zones:
		if z != z2:
			_claim(w2, z)
			z3 = z
			break
	ok(z3 != null, "（人口特化那条用例也要第二块己方区划）")
	if z3 == null:
		return
	z2["kind"] = "food"
	eq(UpgradeRes.can_specialize(w2, z2, "population", w2.my_faction), "",
		"★ 粮食区划可以做人口特化")
	for z in [z2, z3]:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 2.0}
		z["population"] = 0.0
		z["population_cap"] = 1000.0
	near(float((z2["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）本区块人口产能 2")
	near(float((z3["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）另一块地人口产能 2")
	ok(w2.start_zone_specialize(int(z2["id"]), "population"), "（前提）人口特化入队")
	w2.tick(BIG_STEP)
	eq(String(z2.get("spec_done", "")), "population", "人口特化生效")
	near(UpgradeRes.zone_spec_effect(z2, cfg)["population_mult"], 1.10, 1e-6,
		"★ 人口特化 = 人口产量 ×1.10")
	z2["population"] = 0.0
	z3["population"] = 0.0
	w2.zones.update_population(1.0, w2.my_faction, w2.tech_population_mult())
	near(float(z2["population"]), 2.0 * 1.10, 1e-3,
		"★ 本区块人口涨快 10%（基础产能固定，不乘地块数）")
	near(float(z3["population"]), 2.0, 1e-3, "★ 别的区块不受影响")

	mine["owner"] = "p2"
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.04, 1e-6,
		"★ 区划易主后特化保留（谁占谁吃加成）")
	mine["owner"] = f

func _test_spec_stacks_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	if mine == null:
		ok(false, "有己方区划")
		return
	_give(w, 1000.0, 1000.0)
	mine["production"] = {"food": 1.0, "gold": 0.0, "population": 0.0}
	var base: float = float(w.zones.production_of(w.my_faction)["food"])
	var tiles_n := float(mine["tile_count"])
	near(base, 1.0, 1e-3, "（前提）本区块固定产能 1（绝对值，不乘地块数）")
	w.start_zone_specialize(int(mine["id"]), "food")
	w.tick(BIG_STEP)
	near(w.production_food, base + 0.04 * tiles_n, 1e-3,
		"★ 只有特化时：固定基础 1 + 本区块每地块 +0.04")
	ok(w.set_tech_active("food_1", true), "再启用科技「粮食 +0.04/地块/秒」")
	var tiles: int = int(w.owned_tiles)
	near(w.production_food, base + 0.04 * tiles_n + 0.04 * float(tiles), 1e-3,
		"★ 特化（本区块每地块 +0.04）与科技（每地块 +0.04，乘己方占领地块数）相加")

func _test_cancel_spec(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var mine = _own_zone(w)
	var f: String = String(w.my_faction)
	var cost: Dictionary = cfg.spec_cost("food")
	var gold0: float = float(w.resources["gold"])
	ok(w.start_zone_specialize(int(mine["id"]), "food"), "（前提）粮食特化入队")
	near(float(w.resources["gold"]), gold0 - float(cost.get("gold", 0.0)), 1e-6,
		"★ 入队即扣 50 黄金")
	w.tick(BIG_STEP)
	eq(String(mine.get("spec_done", "")), "food", "先做一次粮食特化")

	ok(CommandRes.apply(w, w.cfg, {"kind": "zone_spec_cancel", "zone_id": int(mine["id"])}),
		"★ zone_spec_cancel 命令被接受")
	ok(UpgradeRes.zone_is_busy(mine), "★ 取消特化也要读条")
	ok(UpgradeRes.zone_spec_is_cancel(mine), "这一条读条标成「取消特化」")
	eq(String(mine.get("spec_done", "")), "food",
		"★ 读条期间特化**仍然生效**（读完才去掉）")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.04, 1e-6, "加成还在")
	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "读条结束")
	eq(String(mine.get("spec_done", "")), "", "★ 特化被去掉")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6, "加成没了")
	near(float(w.resources["gold"]), gold0, 1e-6, "★ 读完退回当初特化花掉的黄金")

	eq(UpgradeRes.can_cancel_spec(mine, f), "idle", "没特化过时不能取消特化")

	var w2 = _quiet(cfg)
	_no_income(w2)
	w2.resources["food"] = 1000.0
	w2.resources["gold"] = 1000.0
	var z2 = _own_zone(w2)
	var food2: float = float(w2.resources["food"])
	ok(w2.start_zone_specialize(int(z2["id"]), "gold"), "（前提）黄金特化入队")
	w2.tick(2.0)
	ok(CommandRes.apply(w2, w2.cfg, {"kind": "zone_spec_bar_cancel", "zone_id": int(z2["id"])}),
		"★ zone_spec_bar_cancel 命令被接受")
	ok(not UpgradeRes.zone_is_busy(z2), "读条被撤掉")
	eq(String(z2.get("spec_done", "")), "", "★ 那一单没生效（没特化）")
	near(float(w2.resources["food"]), food2, 1e-6, "★ 撤单全额退款")

	var w3 = _quiet(cfg)
	_no_income(w3)
	w3.resources["food"] = 1000.0
	w3.resources["gold"] = 1000.0
	var z3 = _own_zone(w3)
	ok(w3.start_zone_specialize(int(z3["id"]), "food"), "（前提）粮食特化入队")
	w3.tick(BIG_STEP)
	ok(w3.cancel_zone_specialize(int(z3["id"])), "（前提）发起取消特化")
	eq(UpgradeRes.can_cancel_spec_bar(z3, w3.my_faction), "idle",
		"（取消特化的读条不算「可撤单的特化读条」）")
	ok(UpgradeRes.zone_spec_is_cancel(z3), "它还是「取消特化」那条读条")
	w3.tick(BIG_STEP)
	eq(String(z3.get("spec_done", "")), "", "读完还是把特化去掉了")

func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var base = w.find_base_of("p1")
	ok(not CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": -1, "ty": -1}),
		"越界地块的升级命令被拒")
	var zc = _zone_center(w)
	if zc != null:
		ok(not CommandRes.apply(w, w.cfg,
			{"kind": "building_upgrade", "tx": zc.tx, "ty": zc.ty}),
			"★ 区划中心不能升级（命令被拒）")
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "building_upgrade", "tx": base.tx, "ty": base.ty}),
		"钱不够时升级命令被拒")
	var got := false
	var got_faction := ""
	var got_building := false
	for e in w.tick(DT):
		if String((e as Dictionary).get("type", "")) == "upgrade_rejected":
			got = true
			got_faction = String((e as Dictionary).get("faction", "<无>"))
			got_building = (e as Dictionary).get("building", null) != null
	ok(got, "★ 被拒时留了一条 upgrade_rejected 事件（界面拿去显示红字）")
	ok(got_faction != "<无>",
		"★★ 被拒事件带上了 faction（界面才能只显示自己这一方的）实际=%s" % got_faction)
	ok(got_building, "★ 被拒事件带着那栋建筑（`busy` 的文案要点名是哪个对象）")
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")

## ★★ 大本营的重生队列不为空时，不能**开始新的**升级；建筑升级本轮只保留大本营。
func _test_respawn_blocks_base_upgrade(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var base = w.find_base_of(w.my_faction)
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	_ensure_generals(w, 3, w.my_faction)
	eq(UpgradeRes.can_upgrade(w, base, w.my_faction), "", "（前提）空闲时大本营可升级")

	base.enqueue_respawn(w.units[0], 5.0)
	ok(base.is_respawning(), "（摆场面）大本营进入重生队列")
	eq(UpgradeRes.can_upgrade(w, base, w.my_faction), "respawning",
		"★★ 重生队列非空 → 拒因码 respawning")
	ok(not w.start_building_upgrade(base.tx, base.ty, w.my_faction), "★ 升级命令被拒")

	var wall = _player_wall(w)
	if wall != null:
		eq(UpgradeRes.can_upgrade(w, wall, w.my_faction), "type",
			"★★ 木墙本来就不能升级（与重生队列无关）")

	base.clear_respawn_queue()
	eq(UpgradeRes.can_upgrade(w, base, w.my_faction), "", "★★ 队列清空后恢复可升级")


func _ensure_generals(w, n: int, faction: String) -> void:
	var idx := 1
	while w.general_count_of(faction) < n and idx < 64:
		var g = w.create_general(faction, idx, 1000 + idx)
		if g == null:
			break
		w.units.append(g)
		idx += 1


func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world(c)

func _give(w, food: float, gold: float) -> void:
	_no_income(w)
	w.resources["food"] = food
	w.resources["gold"] = gold

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _claim(w, zone) -> void:
	zone["owner"] = w.my_faction

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == w.my_faction:
			return z
	return null

func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != w.my_faction:
			return z
	return null

func _player_wall(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL \
				and String(b.owner) == w.my_faction:
			return b
	return _build_wall_near(w)      # 开局不再自动生成防御阵地 → 没有就现造一栋

func _build_wall_near(w):
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.can_build_at(x, y):
				continue
			var b = w.add_building(BuildingRes.TYPE_WALL, x, y, w.my_faction, true, true)
			if b != null:
				return b
	return null

func _zone_center(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_ZONE_CENTER:
			return b
	return null

func _enemy_building(w):
	for b in w.building_list:
		if b.alive and String(b.owner) != "" and String(b.owner) != w.my_faction:
			return b
	return null

func _enemy_base(w):
	for b in w.building_list:
		if b.alive and b.is_base() and String(b.owner) != "" \
				and String(b.owner) != w.my_faction:
			return b
	return null
