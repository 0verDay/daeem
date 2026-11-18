## test_economy.gd —— 经济相关：持续消耗取消后的净收入 / 科技产能加成
##
## ★★ 2026.11.18：**单位维护粮与科技扣金都已取消**。
##   本文件验证：即使把旧数据 / 旧开关打开，也不会再扣资源；
##   以及科技对「总体产能」的百分比加成仍然生效。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")

const T_FOOD := "food_1"
const T_FOOD2 := "food_2"

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_economy"
	run_all(_cases)
	cleanup_escort_scaffold()


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	# ★★ 2026.11.18：持续消耗已取消；本文件只验「不会扣」与科技产能加成。
	cfg.upkeep_enabled = false
	cfg.combat_enabled = false
	_test_upkeep_table(cfg)
	_test_base_resource_bonus(cfg)
	_test_resource_buildings(cfg)
	_test_upkeep_deducts_food(cfg)
	_test_tech_warmup(cfg)
	_test_tech_gold_drain(cfg)
	_test_tech_shortfall(cfg)
	_test_production_mult(cfg)
	_test_income_report(cfg)


# ------------------------------------------------------------------
# 1) 维护费表
# ------------------------------------------------------------------

func _test_upkeep_table(cfg) -> void:
	# ★★ 口径（用户拍板）：按**阶**分档，高阶单位明显更贵；classes 上的值只是兜底。
	near(cfg.unit_upkeep_of("spearman"), 0.08, 1e-9, "★ 长枪兵（一阶步兵）= 0.08 粮/秒")
	near(cfg.unit_upkeep_of("longbowman"), 0.10, 1e-9, "长弓兵（一阶远程）= 0.10")
	near(cfg.unit_upkeep_of("rider"), 0.18, 1e-9, "骑手（二阶骑兵）= 0.18")
	near(cfg.unit_upkeep_of("grain_cart"), 0.12, 1e-9, "粮车（二阶支援）= 0.12")
	near(cfg.unit_upkeep_of("knight"), 0.32, 1e-9, "★ 骑士（三阶骑兵）= 0.32")
	near(cfg.unit_upkeep_of("horse_archer"), 0.26, 1e-9, "马弓手（三阶远程）= 0.26")
	near(cfg.unit_upkeep_of("catapult"), 0.40, 1e-9, "★ 投石车（三阶器械）= 0.40")
	near(cfg.unit_upkeep_of("nope_not_a_type"), 0.0, 1e-9, "查不到的类型不收费（老地图不会凭空吃粮）")
	# ★★ 差分：跨阶严格递增（一阶 < 二阶 < 三阶），同类里器械最贵。
	ok(cfg.unit_upkeep_of("rider") > cfg.unit_upkeep_of("longbowman"),
		"★ 二阶 > 一阶")
	ok(cfg.unit_upkeep_of("knight") > cfg.unit_upkeep_of("rider"),
		"★ 三阶 > 二阶")
	ok(cfg.unit_upkeep_of("catapult") > cfg.unit_upkeep_of("knight"),
		"★ 器械 > 骑兵")
	ok(cfg.unit_upkeep_of("grain_cart") > cfg.unit_upkeep_of("spearman"),
		"★ 二阶支援也比一阶步兵贵")


# ------------------------------------------------------------------
# 1.5) 大本营分阶资源加成
# ------------------------------------------------------------------

func _test_base_resource_bonus(cfg) -> void:
	var w = _make(cfg)
	var f: String = String(w.my_faction)
	var b = w.find_base_of(f)
	ok(b != null, "（前提）有大本营")
	if b == null:
		return
	b.level = 1
	var flat1: Dictionary = w._flat_resource_bonus(f)
	near(float(flat1["food"]), 0.5, 1e-9, "★ 一本：粮食 +0.5/秒")
	near(float(flat1["gold"]), 0.0, 1e-9, "一本不产黄金")
	var zb1: Dictionary = w._zone_population_bonus_map()
	var zid: int = int(b.zone_id)
	ok(not zb1.has(zid) or float((zb1[zid] as Dictionary).get("rate", 0.0)) == 0.0,
		"一本没有人口速率加成")

	b.level = 2
	var flat2: Dictionary = w._flat_resource_bonus(f)
	near(float(flat2["food"]), 0.5, 1e-9, "★ 二本仍提供粮食 +0.5")
	var zb2: Dictionary = w._zone_population_bonus_map()
	ok(zb2.has(zid), "二本给所在区划人口加成")
	if zb2.has(zid):
		near(float((zb2[zid] as Dictionary).get("rate", 0.0)), 0.05, 1e-9,
			"★ 二本：所在区划人口 +0.05/秒")
		near(float((zb2[zid] as Dictionary).get("cap", 0.0)), 1.0, 1e-9,
			"★ 二本：所在区划人口上限 +1")

	b.level = 3
	var flat3: Dictionary = w._flat_resource_bonus(f)
	near(float(flat3["food"]), 0.5, 1e-9, "★ 三本仍提供粮食")
	near(float(flat3["gold"]), 0.5, 1e-9, "★ 三本：黄金 +0.5/秒")
	var zb3: Dictionary = w._zone_population_bonus_map()
	if zb3.has(zid):
		near(float((zb3[zid] as Dictionary).get("rate", 0.0)), 0.10, 1e-9,
			"★ 三本：所在区划人口 +0.10/秒")
		near(float((zb3[zid] as Dictionary).get("cap", 0.0)), 2.0, 1e-9,
			"★ 三本：所在区划人口上限 +2")


# ------------------------------------------------------------------
# 1.6) 资源建筑：粮田 / 房屋 / 矿脉
# ------------------------------------------------------------------

func _test_resource_buildings(cfg) -> void:
	var w = _make(cfg)
	w.base_bonus_enabled = false
	w.refresh_zone_production()
	var f: String = String(w.my_faction)
	var b = w.find_base_of(f)
	if b == null:
		return
	var zone: Variant = w.zones.zone_at(b.tx, b.ty)
	ok(zone != null, "（前提）大本营所在区划")
	if zone == null:
		return
	var zd: Dictionary = zone
	var pop_cap0: float = w.zones.population_cap_of(zd)

	var farm = _place_free(w, zd, f, "farm")
	var house = _place_free(w, zd, f, "house")
	var mine = _place_free(w, zd, f, "mine")
	ok(farm != null and house != null and mine != null, "★ 三个资源建筑都能建在己方区划")
	if farm == null or house == null or mine == null:
		return

	var flat: Dictionary = w._flat_resource_bonus(f)
	near(float(flat["food"]), 0.5, 1e-9, "★ 粮田：全阵营粮食 +0.5/秒")
	near(float(flat["gold"]), 0.4, 1e-9, "★ 矿脉：全阵营黄金 +0.4/秒")
	var zb: Dictionary = w._zone_population_bonus_map()
	var zid := int(zd["id"])
	ok(zb.has(zid), "房屋给所在区划人口加成")
	if zb.has(zid):
		near(float((zb[zid] as Dictionary).get("rate", 0.0)), 0.03, 1e-9,
			"★ 房屋：人口 +0.03/秒")
		near(float((zb[zid] as Dictionary).get("cap", 0.0)), 1.0, 1e-9,
			"★ 房屋：人口上限 +1")
	w.zones.apply_population_bonuses(zb)
	near(w.zones.population_cap_of(zd), pop_cap0 + 1.0, 1e-9,
		"★ 房屋让所在区划上限 +1")

	w.remove_building(house, true)
	var zb2: Dictionary = w._zone_population_bonus_map()
	ok(not zb2.has(zid), "房屋被拆后人口加成消失")
	w.zones.apply_population_bonuses(zb2)
	near(w.zones.population_cap_of(zd), pop_cap0, 1e-9, "上限也回到原值")


## 在某个区划里找一格空地建一栋资源建筑（silent + instant）。
func _place_free(w, zd: Dictionary, faction: String, type: String):
	for t in (zd.get("tiles", []) as Array):
		var tile: Vector2i = t
		if not w.can_build_at(tile.x, tile.y, faction):
			continue
		var b = w.add_building(type, tile.x, tile.y, faction, true, true)
		if b != null:
			return b
	return null


# ------------------------------------------------------------------
# 2) 扣粮
# ------------------------------------------------------------------

func _test_upkeep_deducts_food(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	var table_rate: float = _upkeep_rate(w, cfg, f)
	ok(table_rate > 0.0, "（旧数据）单位维护费表仍有数值（%s 粮/秒）" % table_rate)

	w.resources["food"] = 100.0
	w.tick(1.0)
	near(float(w.resources["food"]), 100.0, 1e-6,
		"★★ 2026.11.18：取消单位持续耗粮 —— 一秒后粮食不变")
	near(float(w._upkeep_food_rate.get(f, 0.0)), 0.0, 1e-9,
		"★ 维护费速率缓存恒为 0")
	near(float(w.income_breakdown(f)["food"]["net"]), 0.0, 1e-6,
		"★ 报表净粮 = 0（没有产能也没有维护费）")


# ------------------------------------------------------------------
# 4) 点下即生效（预热已删除）
# ------------------------------------------------------------------

func _test_tech_warmup(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	w.resources["gold"] = 1000.0
	ok(w.set_tech_active(T_FOOD, true), "打出「粮食产量 I」")
	ok(w.is_tech_active(T_FOOD), "★ 打出即生效（没有预热）")
	eq(w.tech.slot_count(), 1, "★ 占用一个名额")

	ok(not w.set_tech_active(T_FOOD, false), "★ 科技不可取消（off 被拒）")
	ok(w.is_tech_active(T_FOOD), "★ 取消命令后仍然启用")
	ok(not w.set_tech_active(T_FOOD, true), "★ 同一条科技不能再次打出")
	eq(w.tech.slot_count(), 1, "名额没有被重复占用")


# ------------------------------------------------------------------
# 5) 每秒扣金
# ------------------------------------------------------------------

func _test_tech_gold_drain(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	w.resources["gold"] = 100.0

	instant_tech(w, T_FOOD)
	near(w.tech.gold_drain_per_sec(f), 0.0, 1e-9,
		"★★ 2026.11.18：科技不再持续扣金（一阶 = 0 金/秒）")
	w.tick(1.0)
	near(float(w.resources["gold"]), 100.0, 1e-6, "★★ 一秒后黄金不变")

	instant_tech(w, T_FOOD2)
	near(w.tech.gold_drain_per_sec(f), 0.0, 1e-9, "两条科技也仍是 0 金/秒")
	w.tick(1.0)
	near(float(w.resources["gold"]), 100.0, 1e-6, "★★ 多条科技也不扣金")


# ------------------------------------------------------------------
# 6) 断金：不取消科技，只禁止新启用
# ------------------------------------------------------------------

func _test_tech_shortfall(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	w.resources["gold"] = 1.0
	instant_tech(w, T_FOOD)
	w.tick(3.0)

	ok(w.is_tech_active(T_FOOD), "★ 科技仍在生效（不存在断金取消）")
	near(float(w.resources["gold"]), 1.0, 1e-6, "★★ 科技不扣金，金库保持 1")
	near(w.gold_net_per_sec(f), 0.0, 1e-9, "★ 黄金净收入 = 0（没有科技金耗）")
	ok(w.tech_can_activate(T_FOOD2, f) == "", "★★ 没有黄金赤字拒因，下一条可以直接启用")
	ok(w.set_tech_active(T_FOOD2, true), "启用 food_2")
	ok(w.is_tech_active(T_FOOD2), "新科技立刻生效")
	ok(not w.set_tech_active(T_FOOD, false), "★ 旧科技仍然不可取消")


# ------------------------------------------------------------------
# 7) 总体产能 ×(1+pct)，加法叠加
# ------------------------------------------------------------------

func _test_production_mult(cfg) -> void:
	var w = _make(cfg)
	w.tick(DT)
	var base: Dictionary = w.zones.production_of(w.my_faction)
	var flat: Dictionary = w._flat_resource_bonus(w.my_faction)
	var f0: float = float(base["food"]) + float(flat["food"])
	ok(f0 > 0.0, "（前提）有粮食产能（区划 %s + 大本营/建筑 %s）" % [base["food"], flat["food"]])
	if f0 <= 0.0:
		return
	near(w.production_food, f0, 1e-6, "没科技时产能 = 区划基础 + 大本营/建筑固定产出")

	instant_tech(w, T_FOOD)
	near(w.production_food, f0 * 1.1, 1e-6, "★ 总体产能 +10%（不再是每地块加值）")
	instant_tech(w, T_FOOD2)
	near(w.production_food, f0 * 1.3, 1e-6,
		"★ 加法叠加：+10% +20% = +30%（不是 1.1×1.2 = 1.32）")


# ------------------------------------------------------------------
# 8) 每秒收支报表（资源条那个 (+n) 的数据源）
# ------------------------------------------------------------------

func _test_income_report(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	w.tick(DT)
	var f: String = String(w.my_faction)
	var b: Dictionary = w.income_breakdown(f)
	near(float((b["food"] as Dictionary)["upkeep"]), 0.0, 1e-6,
		"★★ 报表里的「维护费」= 0（持续耗粮已取消）")
	near(float((b["food"] as Dictionary)["net"]), 0.0, 1e-6,
		"★ 产能为 0 时，净粮 = 0")
	near(float((b["gold"] as Dictionary)["net"]), 0.0, 1e-6, "没科技时净金 = 0")

	# 科技不再扣金，报表里的「科技」恒为 0。
	w.resources["gold"] = 1000.0
	instant_tech(w, T_FOOD)
	w.tick(DT)
	var b2: Dictionary = w.income_breakdown(f)
	near(float((b2["gold"] as Dictionary)["tech"]), 0.0, 1e-9,
		"★★ 报表里的「科技」= 0（不再持续耗金）")
	near(float((b2["gold"] as Dictionary)["net"]), 0.0, 1e-9,
		"★ 净金 = 产能 0 − 科技 0")
	var net: Dictionary = w.net_per_sec(f)
	near(float(net["gold"]), 0.0, 1e-9, "net_per_sec() 与明细的 net 一致")

	# 产能那一项要**含科技加成**（它读的就是 production_*）—— 换一个没清零的世界单独看
	var w2 = _make(cfg)
	w2.tick(DT)
	var before: float = float((w2.income_breakdown(f)["food"] as Dictionary)["produce"])
	ok(before > 0.0, "（前提）另一个世界上有粮食基础产能")
	if before > 0.0:
		instant_tech(w2, T_FOOD)
		near(float((w2.income_breakdown(f)["food"] as Dictionary)["produce"]),
			before * 1.1, 1e-6, "★ 报表里的「产能」已经含科技的 +10%")


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

func _make(cfg):
	var w = require_world_with_escorts(cfg, 3)
	if w == null:
		return null
	# 这些用例要同时启用两条科技 / 三阶：先把大本营拉满（等级限制由 test_base_limits 验）。
	var b = w.find_base_of(String(w.my_faction))
	if b != null:
		b.level = w.cfg.upgrade_max_level("base")
		w.apply_building_level_hp(b)
	return w


## 把区划产能与**大本营固定产出**一起清零：只留「持续消耗」那一份。
## ★ 大本营的产出是靠 `neutralized` 关掉的（它同时仍算「有基地」，科技上限不受影响）。
func _no_production(w) -> void:
	if w == null:
		return
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	w.base_bonus_enabled = false
	w.refresh_zone_production()


## 这一方本帧的维护费（粮/秒）= 所有存活单位的 upkeep 之和。
func _upkeep_rate(w, cfg, faction: String) -> float:
	var total := 0.0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction:
			total += float(cfg.unit_upkeep_of(u.unit_type))
	return total
