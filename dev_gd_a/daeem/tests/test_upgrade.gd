## test_upgrade.gd —— 建筑升级 + 区划特化（右下「操作」页签里那几格）
##
## 需求原话：
##   「为所有单位/建筑都添加上『操作』页签，大本营的操作页签中有一个升级大本营选项，
##     点击后开始读条（和招募单位时的读条一样，可以复用招募单位的面板），
##     箭塔和城墙也有一个升级选项，区划中心有三个特化选项，分别是粮食特化，黄金特化，
##     人口特化，这三个特化玩家只能选一个升级，效果分别为本区块粮食产量 +10%、
##     本区块黄金产量 +10%、本区快人口产量 +10%，特化后的区块无法再次特化，
##     但选中特化后的区块可以在操作面板中选择『取消特化』去除其特化，同理，
##     特化也需要读条，取消特化也需要读条」。
##
## ★ 这里钉**逻辑层**这条链：config 表 → 判定（等级上限 / 读条占用 / 归属 / 费用）
##   → 入队即扣费 → 读条 → 落效果（等级与血量 / 本区块产能）→ 取消与退款 → 命令层。
##   「页签有哪几颗、操作页画哪几格、信息栏那块面板显示什么」在 tests/test_ui.gd 里验。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const DT := 1.0 / 60.0
## 读条一整条（config 里最长的是大本营 3 级的 20 秒）——**一步走完**，
## 靠的是 upgrade.tick 里那套「一帧可能读满好几单」的预算算法。
const BIG_STEP := 60.0


func _initialize() -> void:
	_case_name = "test_upgrade"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_reject_rules(cfg)
	_test_upgrade_flow(cfg)
	_test_cancel_refund(cfg)
	_test_upgrade_scales_with_tech(cfg)
	_test_specialize_flow(cfg)
	_test_spec_stacks_with_tech(cfg)
	_test_cancel_spec(cfg)
	_test_commands(cfg)


# ------------------------------------------------------------------
# 一、表来自 config.json（代码里不写死等级 / 数值）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	ok(cfg.has_upgrade("base"), "大本营有升级表")
	ok(cfg.has_upgrade("wall"), "城墙有升级表")
	ok(cfg.has_upgrade("tower"), "箭塔有升级表")
	ok(not cfg.has_upgrade(BuildingRes.TYPE_ZONE_CENTER),
		"★ 区划中心**没有**升级表（它走特化那三个选项）")
	eq(cfg.upgrade_max_level("base"), 3, "★ 大本营最多 3 级（config 里 3 条）")
	eq(cfg.upgrade_max_level("wall"), 3, "城墙最多 3 级")
	near(cfg.upgrade_hp_mult("base", 1), 1.0, 1e-6, "1 级血量倍率 1.0")
	near(cfg.upgrade_hp_mult("base", 2), 1.5, 1e-6, "★ 2 级血量倍率 1.5")
	near(cfg.upgrade_hp_mult("base", 3), 2.25, 1e-6, "★ 3 级血量倍率 2.25")
	var c1: Dictionary = cfg.upgrade_cost_to("base", 1)
	near(float(c1.get("food", 0.0)), 100.0, 1e-6, "升到 2 级要 100 粮食")
	near(cfg.upgrade_time_to("base", 1), 10.0, 1e-6, "升到 2 级读条 10 秒")
	var c2: Dictionary = cfg.upgrade_cost_to("base", 2)
	near(float(c2.get("food", 0.0)), 200.0, 1e-6, "★ 升到 3 级更贵（200 粮食）")
	near(cfg.upgrade_time_to("base", 2), 20.0, 1e-6, "★ 升到 3 级读条更久（20 秒）")
	ok(cfg.upgrade_cost_to("base", 3).is_empty(), "3 级（最高级）没有 next 的价钱")
	near(cfg.upgrade_time_to("base", 3), 0.0, 1e-6, "最高级没有 next 的读条")

	# 特化表
	eq(cfg.spec_list().size(), 3, "★ 三个特化（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_spec(want), "特化表里有 %s" % want)
	near(float(cfg.spec_entry("food").get("effect", {}).get("food", 0.0)), 0.1, 1e-6,
		"★ 粮食特化 = 本区块粮食 +10%")
	near(float(cfg.spec_entry("gold").get("effect", {}).get("gold", 0.0)), 0.1, 1e-6,
		"★ 黄金特化 = 本区块黄金 +10%")
	near(float(cfg.spec_entry("population").get("effect", {}).get("population", 0.0)), 0.1, 1e-6,
		"★ 人口特化 = 本区块人口 +10%")
	near(cfg.spec_time_sec("food"), 10.0, 1e-6, "★ 特化读条 10 秒")
	var sc: Dictionary = cfg.spec_cost("food")
	near(float(sc.get("food", 0.0)), 50.0, 1e-6, "特化要 50 粮食")
	near(float(sc.get("gold", 0.0)), 50.0, 1e-6, "特化要 50 黄金")
	ok(w.building_can_upgrade("base"), "world 转发：大本营能升级")
	ok(not w.building_can_upgrade(BuildingRes.TYPE_ZONE_CENTER), "world 转发：区划中心不能升级")


# ------------------------------------------------------------------
# 二、判定：谁不能升级（拒因码）
# ------------------------------------------------------------------
func _test_reject_rules(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	# ★ 先把资源给足：`_no_income` 只清产能、不动资源，而新建世界的资源是 0
	#   （`resource.start_food / start_gold` 都是 0）—— 不给钱的话第一条断言就会
	#   落到 `cost` 上，看着像「判定坏了」。
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var base = w.find_base_of("p1")
	var wall = _player_wall(w)
	ok(base != null, "有己方大本营")
	ok(wall != null, "有己方城墙")
	if base == null or wall == null:
		return
	var f: String = String(w.my_faction)
	eq(UpgradeRes.can_upgrade(w, base, f), "", "平常状态下大本营可以升级")
	eq(UpgradeRes.can_upgrade(w, null, f), "type", "不存在的建筑 → type")
	var zc = _zone_center(w)
	if zc != null:
		eq(UpgradeRes.can_upgrade(w, zc, f), "type", "★ 区划中心不能升级（没有升级表）")
	# 归属：不是自己这一方
	var foe = _enemy_building(w)
	if foe != null:
		eq(UpgradeRes.can_upgrade(w, foe, f), "owner", "★ 别人的建筑不能升级")
	# 钱不够
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	eq(UpgradeRes.can_upgrade(w, base, f), "cost", "★ 钱不够 → cost")
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	# 满级
	base.level = cfg.upgrade_max_level("base")
	eq(UpgradeRes.can_upgrade(w, base, f), "max_level", "★ 满级之后不能再升")
	base.level = 1
	# 读条中
	ok(w.start_building_upgrade(base.tx, base.ty), "开始一次升级")
	eq(UpgradeRes.can_upgrade(w, wall, f), "", "读条中的是**大本营**，城墙照样能升")
	eq(UpgradeRes.can_upgrade(w, base, f), "busy", "★ 读条中再升同一栋 → busy")


# ------------------------------------------------------------------
# 三、升级全流程：扣费 → 读条 → 完成（等级 + 血量）
# ------------------------------------------------------------------
func _test_upgrade_flow(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var wall = _player_wall(w)
	ok(wall != null, "有己方城墙")
	if wall == null:
		return
	var lv0: int = wall.level
	var hp0: float = wall.hp_max
	var cost: Dictionary = w.building_upgrade_cost(wall)
	var food0: float = float(w.resources["food"])
	eq(lv0, 1, "城墙开局 1 级")

	# 走命令层（与界面同一条路）
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": wall.tx, "ty": wall.ty}),
		"★ building_upgrade 命令被接受")
	ok(wall.is_upgrading(), "★ 开始读条（is_upgrading）")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-6,
		"★ 入队即扣粮食")
	near(wall.upgrade_progress(), 0.0, 1e-6, "刚入队时进度是 0")
	near(wall.upgrade_eta(), w.building_upgrade_time(wall), 1e-6, "剩余时间 = 整条读条")
	eq(UpgradeRes.can_upgrade(w, wall, w.my_faction), "busy", "读条中拒绝新的升级请求")

	# 读条一半：还没升级
	var half: float = maxf(0.01, wall.upgrade_total * 0.5)
	w.tick(half)
	eq(wall.level, lv0, "★ 读条没读完时等级不变")
	near(wall.upgrade_progress(), 0.5, 0.02, "进度条走到一半")
	near(wall.hp_max, hp0, 1e-6, "血量上限也还没变")

	# 读完
	w.tick(BIG_STEP)
	ok(not wall.is_upgrading(), "★ 读条结束")
	eq(wall.level, lv0 + 1, "★ 等级 +1")
	var mult: float = cfg.upgrade_hp_mult("wall", wall.level)
	near(wall.hp_max, wall.base_hp_max * mult, 1e-3, "★ 血量上限 = 基础值 × 等级倍率")

	# 当前血量按比例：先打掉一半再升一级，升完还是半血
	var w2 = _quiet(cfg)
	var wall2 = _player_wall(w2)
	_give(w2, 1000.0, 1000.0)
	wall2.hp = wall2.hp_max * 0.5
	w2.start_building_upgrade(wall2.tx, wall2.ty)
	w2.tick(BIG_STEP)
	near(wall2.hp / wall2.hp_max, 0.5, 1e-3, "★ 升级按比例带血（半血的墙升完还是半血）")

	# 升级事件（逻辑层给，界面拿去提示）
	var w3 = _quiet(cfg)
	var wall3 = _player_wall(w3)
	_give(w3, 1000.0, 1000.0)
	w3.start_building_upgrade(wall3.tx, wall3.ty)
	var evts: Array = w3.tick(BIG_STEP)
	var done := false
	for e in evts:
		if String((e as Dictionary).get("type", "")) == "upgrade_done" \
				and String((e as Dictionary).get("kind", "")) == "building_upgrade":
			done = true
	ok(done, "★ 升级完成留了一条 upgrade_done 事件")

	# 满级封顶：再点会被拒（界面那一格那时会画成「已满级」）
	var w4 = _quiet(cfg)
	var base4 = w4.find_base_of("p1")
	_give(w4, 100000.0, 100000.0)
	for i in 5:
		w4.start_building_upgrade(base4.tx, base4.ty)
		w4.tick(BIG_STEP)
	eq(base4.level, cfg.upgrade_max_level("base"), "★ 连点多次也封顶在最高等级")
	near(base4.hp_max, base4.base_hp_max * cfg.upgrade_hp_mult("base", base4.level), 1e-3,
		"满级时的血量上限 = 基础值 × 满级倍率")


# ------------------------------------------------------------------
# 四、取消升级：全额退款、等级不变
# ------------------------------------------------------------------
func _test_cancel_refund(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var wall = _player_wall(w)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	w.start_building_upgrade(wall.tx, wall.ty)
	w.tick(DT * 10)
	ok(wall.is_upgrading(), "还在读条中")
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade_cancel",
		"tx": wall.tx, "ty": wall.ty}), "★ building_upgrade_cancel 命令被接受")
	ok(not wall.is_upgrading(), "★ 读条被取消")
	eq(wall.level, 1, "等级没变")
	near(float(w.resources["food"]), food0, 1e-6, "★ 粮食全额退回")
	near(float(w.resources["gold"]), gold0, 1e-6, "★ 黄金全额退回")
	eq(UpgradeRes.can_cancel_upgrade(wall, w.my_faction), "idle", "没有读条时不能取消")

	# 建筑被打掉：读条作废（不退款 —— 钱花在这栋楼上了）
	var w2 = _quiet(cfg)
	var wall2 = _player_wall(w2)
	_give(w2, 1000.0, 1000.0)
	w2.start_building_upgrade(wall2.tx, wall2.ty)
	ok(wall2.is_upgrading(), "在建的墙在读条")
	w2.remove_building(wall2, true)
	ok(not wall2.is_upgrading(), "★ 建筑离场 → 升级读条作废")


# ------------------------------------------------------------------
# 五、升级与科技叠加（上限 = 基础 × 等级 × 科技）
# ------------------------------------------------------------------
func _test_upgrade_scales_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var wall = _player_wall(w)
	var base_hp: float = wall.base_hp_max
	ok(w.set_tech_active("building_hp", true), "启用「建筑加固」（+10%）")
	near(wall.hp_max, base_hp * 1.1, 1e-3, "科技生效：基础 × 1.1")
	w.start_building_upgrade(wall.tx, wall.ty)
	w.tick(BIG_STEP)
	near(wall.hp_max, base_hp * 1.1 * cfg.upgrade_hp_mult("wall", 2), 1e-3,
		"★ 上限 = 基础 × 等级(1.5) × 科技(1.1)（两者叠加）")
	w.set_tech_active("building_hp", false)
	near(wall.hp_max, base_hp * cfg.upgrade_hp_mult("wall", 2), 1e-3,
		"★ 弃用科技后只剩等级那一份（精确回到 1.5 倍）")


# ------------------------------------------------------------------
# 六、特化全流程：只能选一个、读完生效、只影响本区块
# ------------------------------------------------------------------
func _test_specialize_flow(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	# ★ 地图上默认**只有出生区**是己方（大本营把它收归己方），
	#   所以「只影响本区块」这条要自己再认领一块地（模拟玩家占了第二块）。
	#   ⚠️ 不能按「有没有中心」筛：这张图上 14 个区划**每个都有中心**。
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
	# ⚠️ 产能必须在 `_give` **之后**配（`_give` 会清掉所有区划的产能）
	for z in [mine, other]:
		z["production"] = {"food": 2.0, "gold": 3.0, "population": 1.0}
	var n_mine := float(mine["tile_count"])
	var n_other := float(other["tile_count"])
	var f: String = String(w.my_faction)
	var zid := int(mine["id"])

	eq(UpgradeRes.can_specialize(w, mine, "food", f), "", "平常状态下可以做粮食特化")
	eq(UpgradeRes.can_specialize(w, mine, "nope", f), "spec", "不存在的特化 → spec")
	eq(UpgradeRes.can_specialize(w, null, "food", f), "zone", "没有区划 → zone")
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
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.0, 1e-6,
		"★ 读条还没读完 → 加成还没生效")

	# 读条一半：还没生效
	w.tick(5.0)
	near(UpgradeRes.zone_spec_progress(mine, cfg), 0.5, 0.05, "读条走到一半")
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.0, 1e-6, "一半时加成仍未生效")

	# 读完
	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "★ 读条结束")
	eq(String(mine.get("spec_done", "")), "food", "★ 特化生效（spec_done = food）")
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.1, 1e-6, "★ 本区块粮食倍率 1.1")
	near(UpgradeRes.zone_spec_mult(mine, cfg)["gold"], 1.0, 1e-6, "黄金不受粮食特化影响")

	# 产能：本区块 ×1.1，别的区块不变
	var rates: Dictionary = w.zones.production_of(f)
	near(float(rates["food"]), 2.0 * n_mine * 1.1 + 2.0 * n_other, 1e-3,
		"★ 粮食产出 = 本区块 ×1.1 + 别的区块不变")
	near(float(rates["gold"]), 3.0 * n_mine + 3.0 * n_other, 1e-3, "黄金产出不变")

	# 只能选一个：已特化 → 别的特化被拒（命令也不该生效）
	eq(UpgradeRes.can_specialize(w, mine, "gold", f), "spec_done",
		"★ 特化过的区块无法再次特化（spec_done）")
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "zone_specialize", "zone_id": zid, "spec": "gold"}),
		"★ 换一个特化的命令也走不通")
	eq(String(mine.get("spec_done", "")), "food", "★ 还是原来的粮食特化")

	# 人口特化同样只加本区块的增长速度
	#
	# ⚠️ 资源直接写（不用 `_give()`）：本段要的正是产能，而 `_give()` 会把它清掉。
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
	for z in [z2, z3]:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 2.0}
		z["population"] = 0.0
		z["population_cap"] = 1000.0
	# ★ 断言「配好了」：这一段的期望值全靠这两块地的产能，配错了要一眼看出来
	near(float((z2["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）本区块人口产能 2")
	near(float((z3["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）另一块地人口产能 2")
	ok(w2.start_zone_specialize(int(z2["id"]), "population"), "（前提）人口特化入队")
	w2.tick(BIG_STEP)
	eq(String(z2.get("spec_done", "")), "population", "人口特化生效")
	near(UpgradeRes.zone_spec_mult(z2, cfg)["population"], 1.1, 1e-6, "（前提）倍率 1.1")
	# ★ 把两块地都归零，再各跑一秒 —— 这样算的是「一秒钟涨了多少」，与 tick 期间
	#   已经涨过的量无关（tick 里本来也会按秒推进人口）。
	z2["population"] = 0.0
	z3["population"] = 0.0
	w2.zones.update_population(1.0, w2.my_faction, w2.tech_population_mult())
	near(float(z2["population"]), 2.0 * float(z2["tile_count"]) * 1.1, 1e-3,
		"★ 本区块人口涨快 10%")
	near(float(z3["population"]), 2.0 * float(z3["tile_count"]), 1e-3,
		"★ 别的区块不受影响")

	# 特化跟着地块走：区划易主后特化**保留**
	mine["owner"] = "p2"
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.1, 1e-6,
		"★ 区划易主后特化保留（谁占谁吃加成）")
	mine["owner"] = f


# ------------------------------------------------------------------
# 七、特化与科技叠加
# ------------------------------------------------------------------
func _test_spec_stacks_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	if mine == null:
		ok(false, "有己方区划")
		return
	_give(w, 1000.0, 1000.0)
	# ⚠️ 产能必须在 `_give` **之后**配 —— `_give` 会清掉所有区划的产能
	mine["production"] = {"food": 1.0, "gold": 0.0, "population": 0.0}
	# ★ 先记下「没有特化时的产能」：免得把「产能表里还有别的区块」这种事算漏
	var base: float = float(w.zones.production_of(w.my_faction)["food"])
	var tiles_n := float(mine["tile_count"])
	near(base, 1.0 * tiles_n, 1e-3, "（前提）只有本区块的产能")
	w.start_zone_specialize(int(mine["id"]), "food")
	w.tick(BIG_STEP)
	near(w.production_food, base * 1.1, 1e-3, "★ 只有特化时：本区块产能 ×1.1")
	# 科技：每地块加产量（乘的是**占领地块数**，不是产能）
	ok(w.set_tech_active("food_1", true), "再启用科技「粮食 +1/地块/秒」")
	var tiles: int = int(w.owned_tiles)
	near(w.production_food, base * 1.1 + 1.0 * float(tiles), 1e-3,
		"★ 特化（乘在区划产能上）与科技（每地块加产量）叠加")


# ------------------------------------------------------------------
# 八、取消特化：也要读条，读完去掉特化并退款
# ------------------------------------------------------------------
func _test_cancel_spec(cfg) -> void:
	# ★★ 这一段**不做产能对账**（只验特化 / 取消 / 退款这条链），所以把产能清零 ——
	#    读条动辄 60 秒，有产能的话粮食一路在涨，「退回多少」根本算不准。
	var w = _quiet(cfg)
	_no_income(w)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var mine = _own_zone(w)
	var f: String = String(w.my_faction)
	var cost: Dictionary = cfg.spec_cost("food")
	var food0: float = float(w.resources["food"])
	ok(w.start_zone_specialize(int(mine["id"]), "food"), "（前提）粮食特化入队")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-6,
		"★ 入队即扣 50 粮食")
	w.tick(BIG_STEP)
	eq(String(mine.get("spec_done", "")), "food", "先做一次粮食特化")

	# 取消特化：**也要读条**
	ok(CommandRes.apply(w, w.cfg, {"kind": "zone_spec_cancel", "zone_id": int(mine["id"])}),
		"★ zone_spec_cancel 命令被接受")
	ok(UpgradeRes.zone_is_busy(mine), "★ 取消特化也要读条")
	ok(UpgradeRes.zone_spec_is_cancel(mine), "这一条读条标成「取消特化」")
	eq(String(mine.get("spec_done", "")), "food",
		"★ 读条期间特化**仍然生效**（读完才去掉）")
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.1, 1e-6, "加成还在")
	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "读条结束")
	eq(String(mine.get("spec_done", "")), "", "★ 特化被去掉")
	near(UpgradeRes.zone_spec_mult(mine, cfg)["food"], 1.0, 1e-6, "加成没了")
	near(float(w.resources["food"]), food0, 1e-6, "★ 读完退回当初特化花掉的粮食")

	# 没特化过 → 没什么可取消
	eq(UpgradeRes.can_cancel_spec(mine, f), "idle", "没特化过时不能取消特化")

	# 读条中的那一单可以撤掉（退款），撤掉之后**特化还在**
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

	# 「取消特化」那条读条**不可再取消**（没有「取消取消」）
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


# ------------------------------------------------------------------
# 九、命令层：形状与拒因
# ------------------------------------------------------------------
func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var base = w.find_base_of("p1")
	# 不存在的地块
	ok(not CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": -1, "ty": -1}),
		"越界地块的升级命令被拒")
	# 区划中心的升级命令（没有升级表）
	var zc = _zone_center(w)
	if zc != null:
		ok(not CommandRes.apply(w, w.cfg,
			{"kind": "building_upgrade", "tx": zc.tx, "ty": zc.ty}),
			"★ 区划中心不能升级（命令被拒）")
	# 钱不够：留一条 upgrade_rejected 事件给界面
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "building_upgrade", "tx": base.tx, "ty": base.ty}),
		"钱不够时升级命令被拒")
	var got := false
	for e in w.tick(DT):
		if String((e as Dictionary).get("type", "")) == "upgrade_rejected":
			got = true
	ok(got, "★ 被拒时留了一条 upgrade_rejected 事件（界面拿去显示红字）")
	# 未知命令照旧被拒
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")


# ------------------------------------------------------------------
# 小工具（与其它逻辑测试同一套做法）
# ------------------------------------------------------------------

func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return WorldRes.create(c)


func _give(w, food: float, gold: float) -> void:
	# ★ 顺手清掉区划产能：这一组用例全都要**对账**（扣了多少 / 退了多少），
	#   而读条动辄跑 60 秒 —— 不清产能的话资源一路在涨，断言根本算不准。
	_no_income(w)
	w.resources["food"] = food
	w.resources["gold"] = gold


## 把区划产能清零：**要对账的用例必须先调它** —— 否则 tick 期间粮食 / 黄金一直在涨，
## 「扣了多少 / 退了多少」这类断言算不准（读条动不动就跑 60 秒）。
func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 把某一块区划划归玩家（测试要「两块己方区划」时用）——地图上默认只有出生区一块。
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
