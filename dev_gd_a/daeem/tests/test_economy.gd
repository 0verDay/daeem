## test_economy.gd —— ★★ 2026.10.29 经济改版的**持续消耗**与**科技投资**
##
## 这一份专门验「每帧都在扣的东西」，所以它和别的用例**反着来**：
##   `test_case.require_config()` 默认把 `economy.upkeep_enabled` 关掉
##   （让旧用例的精确对账不被维护费搅乱），这里把它**重新打开**，用真实数值断言。
##
## 覆盖六件事：
##   1. 维护费按阶分档、高阶更贵（一阶 枪 0.08 / 弓 0.10；二阶 骑手 0.18 / 粮车 0.12；
##      三阶 骑士 0.32 / 马弓 0.26 / 投石车 0.40）；
##   2. 每帧扣粮 = Σ 维护费，且「粮够」时不算断粮；
##   3. 断粮 ⇒ 全军每秒多掉 `morale.starve_drain`，且这个数与粮车光环**等速**；
##   4. 科技的 30 秒**预热**（点下去 ≠ 生效，但名额当场就占住）；
##   5. 科技的**每秒扣金**（按阶 0.5 / 1.0 / 2.0，预热期间照样扣）；
##   6. 断金 ⇒ 全部科技弃用 + 全科技 30 秒冷却，冷却结束后能重新点；
##   7. 科技是「总体产能 ×(1+百分比)」且**加法叠加**。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const MoraleRes = preload("res://logic/morale.gd")

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
	# ★★ 本文件的存在意义就是验这两条：把总闸**打开**，用真实的维护费 / 金耗跑。
	cfg.upkeep_enabled = true
	cfg.combat_enabled = false
	_test_upkeep_table(cfg)
	_test_upkeep_deducts_food(cfg)
	_test_starving_morale(cfg)
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
# 2) 扣粮
# ------------------------------------------------------------------

func _test_upkeep_deducts_food(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)                       # 只留维护费，别让区划收入掺进来
	var f: String = String(w.my_faction)
	var rate: float = _upkeep_rate(w, cfg, f)
	ok(rate > 0.0, "开局有单位 ⇒ 维护费 > 0（%s 粮/秒）" % rate)

	w.resources["food"] = 100.0
	w.tick(1.0)
	near(float(w.resources["food"]), 100.0 - rate, 1e-3,
		"★ 一秒正好扣掉 Σ 维护费（%s）" % rate)
	ok(not bool(w.is_starving(f)), "粮够 ⇒ 不算断粮")

	# 断粮边界：刚好不够一帧的量 ⇒ 扣到 0 并标记断粮
	w.resources["food"] = rate * 0.5
	w.tick(1.0)
	near(float(w.resources["food"]), 0.0, 1e-6, "★ 付不起就扣到 0（不欠账、不变负）")
	ok(bool(w.is_starving(f)), "★ 付不起 ⇒ 断粮标记")


# ------------------------------------------------------------------
# 3) 断粮士气
# ------------------------------------------------------------------

func _test_starving_morale(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	var u = _first_leader(w, f)
	ok(u != null, "（前提）有一名己方将领（士气的锚）")
	if u == null:
		return

	# ① 端到端：同一位置、同一秒，断粮时的士气必须**低于**没断粮时。
	#    ⚠️ 站在己方区划时基础回士气是 +1.5/秒，断粮只减 0.5 ⇒ 绝对值仍会上升，
	#    所以这里比的是「同样条件下断粮 vs 不断粮」，而不是「必须下降」。
	w.resources["food"] = 0.0
	u.morale = 80.0
	w.tick(1.0)
	ok(bool(w.is_starving(f)), "★ 粮为 0 ⇒ 断粮")
	var starving_morale: float = u.morale
	w.resources["food"] = 10000.0
	u.morale = 80.0
	w.tick(1.0)
	ok(starving_morale < u.morale,
		"★ 断粮时士气低于同位置不断粮（%.3f < %.3f）" % [starving_morale, u.morale])

	# ② 精确：同一个人、同一个位置，**只切换断粮标记**，速率差必须正好是 starve_drain。
	#    （不走 tick：移动 / 换区划会把区划速率也换掉，那样比出来的差就不是 0.5 了）
	w.resources["food"] = 10000.0
	w.tick(DT)                                  # 清掉断粮标记
	u = _first_leader(w, f)
	var r_ok: float = MoraleRes._zone_morale_rate(w, cfg, u)
	w.starving_factions[f] = true
	var r_bad: float = MoraleRes._zone_morale_rate(w, cfg, u)
	w.starving_factions.erase(f)
	near(r_ok - r_bad, float(cfg.morale_starve_drain), 1e-9,
		"★ 断粮让每秒速率正好多掉 morale.starve_drain（%s）" % cfg.morale_starve_drain)

	# 用户口径：断粮的下降速度 = 粮车使士气上升的速度（一辆粮车刚好抵消）。
	var cart_rate: float = cfg.num("unit.types.grain_cart.morale_aura_rate", 0.5)
	near(float(cfg.morale_starve_drain), cart_rate, 1e-9,
		"★ 断粮速率 == 粮车光环速率（%s/秒）：一辆粮车刚好抵消断粮" % cart_rate)


# ------------------------------------------------------------------
# 4) 预热
# ------------------------------------------------------------------

func _test_tech_warmup(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	w.resources["gold"] = 1000.0           # 没有金会在下一帧直接断金，先把钱给足
	ok(w.set_tech_active(T_FOOD, true), "点下「粮食产量 I」")
	ok(not w.is_tech_active(T_FOOD), "★ 点下去 ≠ 生效（预热期间没有加成）")
	ok(w.tech.is_warming(T_FOOD), "★ 它在预热队列里")
	eq(w.tech.slot_count(), 1, "★ 预热的也占名额")
	near(w.tech.warmup_left(T_FOOD), float(cfg.tech_warmup_sec), 0.5,
		"预热时长 = tech.warmup_sec（%s 秒）" % cfg.tech_warmup_sec)

	w.tick(float(cfg.tech_warmup_sec) * 0.5)
	ok(not w.is_tech_active(T_FOOD), "预热一半时还没生效")
	w.tick(float(cfg.tech_warmup_sec) * 0.5 + 0.1)
	ok(w.is_tech_active(T_FOOD), "★ 预热满 30 秒之后生效")

	# 预热中取消：立即退出，不留冷却。
	ok(w.set_tech_active(T_FOOD, false), "弃用")
	ok(not w.is_tech_active(T_FOOD), "弃用后立即失效")
	ok(not w.tech.in_cooldown(w.my_faction), "★ 手动取消**不进冷却**（用户口径）")
	ok(w.set_tech_active(T_FOOD, true), "可以马上再点")
	ok(not w.is_tech_active(T_FOOD), "再点又是从预热开始")
	ok(w.set_tech_active(T_FOOD, false), "（收尾）取消，别把金耗留给后面的用例")


# ------------------------------------------------------------------
# 5) 每秒扣金
# ------------------------------------------------------------------

func _test_tech_gold_drain(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	w.resources["gold"] = 100.0

	ok(w.set_tech_active(T_FOOD, true), "启用 food_1（一阶）")
	near(w.tech.gold_drain_per_sec(f), 0.5, 1e-9, "★ 一阶 = 0.5 金/秒")
	w.tick(1.0)
	near(float(w.resources["gold"]), 99.5, 1e-3,
		"★ **预热期间就开始扣金**（用户口径：点下那刻开始付钱）")

	instant_tech(w, T_FOOD2)
	near(w.tech.gold_drain_per_sec(f), 1.5, 1e-9,
		"★ 一阶 + 二阶 = 0.5 + 1.0 = 1.5 金/秒")
	w.tick(1.0)
	near(float(w.resources["gold"]), 98.0, 1e-3, "★ 一秒扣 1.5")

	w.set_tech_active(T_FOOD, false)
	w.set_tech_active(T_FOOD2, false)
	near(w.tech.gold_drain_per_sec(f), 0.0, 1e-9, "全部弃用后不再扣金")


# ------------------------------------------------------------------
# 6) 断金：全灭 + 冷却
# ------------------------------------------------------------------

func _test_tech_shortfall(cfg) -> void:
	var w = _make(cfg)
	_no_production(w)
	var f: String = String(w.my_faction)
	w.resources["gold"] = 1.0
	ok(w.set_tech_active(T_FOOD, true), "启用 food_1")
	w.tick(3.0)                            # 0.5/秒 的消耗在 2 秒内就吃光这 1 金

	ok(w.active_tech_ids().is_empty(), "★ 断金 ⇒ 全部科技被弃用")
	eq(w.tech.warming_count(), 0, "★ 预热中的也一起清掉")
	ok(w.tech.in_cooldown(f), "★ 进入「全科技冷却」")
	near(w.tech.cooldown_left(f), float(cfg.tech_shortfall_cooldown_sec), 1.5,
		"冷却是 shortfall_cooldown_sec（%s 秒）" % cfg.tech_shortfall_cooldown_sec)
	eq(w.tech_can_activate(T_FOOD, f), "cooldown", "★ 冷却期间一格都点不了")
	ok(not w.set_tech_active(T_FOOD, true), "冷却期间启用被拒")

	w.tick(float(cfg.tech_shortfall_cooldown_sec) + 1.0)
	ok(not w.tech.in_cooldown(f), "冷却结束")
	ok(w.tech_can_activate(T_FOOD, f) == "", "★ 冷却结束后可以重新点")
	w.resources["gold"] = 1000.0
	ok(w.set_tech_active(T_FOOD, true), "重新点得动")
	ok(not w.is_tech_active(T_FOOD), "★ 但还要重新等一次 30 秒预热（一次断金 = 60 秒没科技）")
	finish_tech_warmup(w, cfg)
	ok(w.is_tech_active(T_FOOD), "预热满之后才恢复")


# ------------------------------------------------------------------
# 7) 总体产能 ×(1+pct)，加法叠加
# ------------------------------------------------------------------

func _test_production_mult(cfg) -> void:
	var w = _make(cfg)
	w.tick(DT)
	var base: Dictionary = w.zones.production_of(w.my_faction)
	var f0: float = float(base["food"])
	ok(f0 > 0.0, "（前提）有粮食基础产能（%s/秒）" % f0)
	if f0 <= 0.0:
		return
	near(w.production_food, f0, 1e-6, "没科技时产能 = 区划基础产能")

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
	var up: float = _upkeep_rate(w, cfg, f)
	var b: Dictionary = w.income_breakdown(f)
	near(float((b["food"] as Dictionary)["upkeep"]), up, 1e-6,
		"★ 报表里的「维护费」= Σ 各兵种 upkeep（%s）" % up)
	near(float((b["food"] as Dictionary)["net"]), -up, 1e-6,
		"★ 产能为 0 时，净粮 = −维护费")
	near(float((b["gold"] as Dictionary)["net"]), 0.0, 1e-6, "没科技时净金 = 0")

	# 科技的金耗要单独列出来，并且从**净额**里扣掉（玩家才知道钱被谁烧的）
	w.resources["gold"] = 1000.0
	instant_tech(w, T_FOOD)
	w.tick(DT)
	var b2: Dictionary = w.income_breakdown(f)
	near(float((b2["gold"] as Dictionary)["tech"]), 0.5, 1e-9,
		"★ 报表里的「科技」= 一阶 0.5 金/秒")
	near(float((b2["gold"] as Dictionary)["net"]), -0.5, 1e-9,
		"★ 净金 = 产能 0 − 科技 0.5")
	var net: Dictionary = w.net_per_sec(f)
	near(float(net["gold"]), -0.5, 1e-9, "net_per_sec() 与明细的 net 一致")

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


## 把区划产能清零：只留「持续消耗」那一份，别让收入掺进来。
func _no_production(w) -> void:
	if w == null:
		return
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 这一方本帧的维护费（粮/秒）= 所有存活单位的 upkeep 之和。
func _upkeep_rate(w, cfg, faction: String) -> float:
	var total := 0.0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction:
			total += float(cfg.unit_upkeep_of(u.unit_type))
	return total


## 取一名「士气锚」——leader_id 为空、还活着的那一个（通常是主将）。
func _first_leader(w, faction: String):
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction \
				and String(u.leader_id) == "" and not u.is_downed():
			return u
	return null
