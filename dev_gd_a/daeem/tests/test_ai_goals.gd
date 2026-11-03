## test_ai_goals.gd —— ★★ 2026.11 四条新口径的回归：
##
##   ① 招兵 tick 放宽（1s → 4s，× 难度 1.2 ⇒ 约 4.8s）；
##   ② 高阶兵倾斜（低阶花够 + 高阶占比不达标 ⇒ 只在高阶里挑）；
##   ③ 招兵只遍历「站在己方区划里」的将领（底层规则不变，只是提前剪枝）；
##   ④ 目的系统（攒钱升本 / 攒钱招高阶）：攒钱期间一分钱不花，钱够了立刻放行。
##
## 用真关卡（demo / ai_test_battle）建世界，p2 交给 commander —— 与 see_ai 同一套装配。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")
const AiArmyRes = preload("res://logic/ai_army.gd")
const AiEconomyRes = preload("res://logic/ai_economy.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "ai_test_battle"

func _initialize() -> void:
	_case_name = "test_ai_goals"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_elite_ratio(cfg)
	_test_goal_hold(cfg)
	_test_zone_only(cfg)
	_test_frontline_first(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _make_world(cfg, seed_value: int = 4321, ai_factions: Array = ["p2"]):
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	if camp == null:
		return null
	var lv = camp.level(LEVEL_ID)
	if lv == null:
		return null
	var seats: Array = lv.seats()
	var overrides := {}
	var profiles := {}
	for fid in ai_factions:
		overrides[String(fid)] = LevelRes.AI_COMMANDER
		profiles[String(fid)] = {"difficulty": "normal"}
	return WorldRes.create_from_level(cfg, lv, String(seats[0]), seats, true,
		overrides, profiles, seed_value)


func _commander(w):
	return w.ai_commanders.get("p2", null)


func _first_general(w, faction: String):
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction and u.is_general():
			return u
	return null


# ---- ① 招兵 tick 放宽 ----
func _test_config(cfg) -> void:
	var w = _make_world(cfg)
	ok(w != null, "（前提）ai_test_battle 世界能建出来")
	if w == null:
		return
	var c = _commander(w)
	ok(c != null, "（前提）p2 交给 commander")
	if c == null:
		return
	var p: Dictionary = c.profile
	eq(float(p["intervals"]["production_interval_sec"]), 4.0,
		"★★ 招兵 tick 配置从 1.0s 放宽到 4.0s")
	var effective := float(c._interval_production)
	ok(effective >= 3.0 and effective <= 7.0,
		"★ 实际招兵 tick = %.2fs（4.0 × 难度倍率，落在 3~7 秒）" % effective)
	ok(bool(p["goals"]["enabled"]), "★★ 目的系统默认开启")
	eq(int(p["production"]["elite"]["elite_tier_min"]), 3, "tier ≥ 3 才算高阶兵")
	ok(float(p["production"]["elite"]["elite_to_low"]) > 0.0, "高阶:低阶 目标比例 > 0")


# ---- ② 高阶兵倾斜 ----
func _test_elite_ratio(cfg) -> void:
	var w = _make_world(cfg)
	if w == null or _commander(w) == null:
		return
	var c = _commander(w)
	w.ai_faction_resources["p2"] = {"food": 3000.0, "gold": 3000.0}
	c.spend_low = 0.0
	c.spend_high = 0.0
	w.time = 200.0                      # 过掉 elite.min_sec
	ok(not c.elite_share_push_needed(), "低阶还没花够 ⇒ 不倾斜")
	c.spend_low = 700.0
	ok(c.elite_share_push_needed(), "★★ 低阶花够 600 之后开始往高阶倾斜")
	c.spend_high = 350.0
	ok(not c.elite_share_push_needed(),
		"★★ 高阶:低阶 已到 1:2 ⇒ 停止倾斜（不再逼它继续买贵的）")
	# 记账口径：一阶算低阶，三阶算高阶
	c.spend_low = 0.0
	c.spend_high = 0.0
	c._note_recruit_spend("dg_swordsman")
	ok(c.spend_low > 0.0 and c.spend_high == 0.0, "★ 一阶兵记进 spend_low")
	var low2: float = c.spend_low
	c._note_recruit_spend("dg_rider")
	ok(c.spend_low > low2 and c.spend_high == 0.0,
		"★★ 二阶的骑手也算**低阶**（否则它会把「高阶:低阶」比例刷满，三阶兵永远不买）")
	c._note_recruit_spend("dg_champion")
	ok(c.spend_high > 0.0, "★ 三阶兵记进 spend_high")
	ok(c.recruit_spend_weight("dg_champion") > c.recruit_spend_weight("dg_swordsman"),
		"★ 三阶一单比一阶一单贵（当量口径：粮 + 2×金）")


# ---- ④ 目的系统：攒钱期间不花钱 ----
func _test_goal_hold(cfg) -> void:
	var w = _make_world(cfg)
	if w == null or _commander(w) == null:
		return
	var c = _commander(w)
	w.ai_faction_resources["p2"] = {"food": 500.0, "gold": 500.0}
	c.retry_timer = 0.0
	w.time = 300.0
	# 手动钉一个「买不起」的升级目标
	c.goal = "upgrade"
	c.goal_need = {"food": 9999.0, "gold": 9999.0}
	c.goal_since = w.time
	ok(c._goal_holding(), "★★ 攒钱期间处于 hold 状态")
	var r0 := int(c.stats.get("recruits", 0))
	c._production_tick()
	eq(int(c.stats.get("recruits", 0)), r0, "★★ 攒钱期间一单都不下")
	# 钱够了 ⇒ 立刻放行
	c.goal_need = {"food": 1.0, "gold": 1.0}
	ok(not c._goal_holding(), "★★ 钱够了就放行（不会一直卡住）")
	c.goal = ""
	c.goal_need = {}
	# 买得起的目标根本不会进入 hold（升级交给 build tick 去做）
	ok(not c._goal_holding(), "没有目标时从不 hold")
	# 收入估算：钱多 ⇒ 立刻可达；收入为 0 ⇒ 不可达
	w.ai_faction_resources["p2"] = {"food": 0.0, "gold": 0.0}
	var far := {"food": 100000.0, "gold": 0.0}
	ok(not c._affordable_within(far, 30.0), "★ 差 10 万粮不可能在 30 秒内攒到")
	w.ai_faction_resources["p2"] = {"food": 3000.0, "gold": 3000.0}
	ok(c._affordable_within({"food": 200.0, "gold": 200.0}, 30.0),
		"★ 钱已经够 ⇒ 视为 0 秒可达")


# ---- ③ 只遍历站在己方区划里的将领 ----
func _test_zone_only(cfg) -> void:
	var w = _make_world(cfg)
	if w == null or _commander(w) == null:
		return
	var c = _commander(w)
	var g = _first_general(w, "p2")
	var base = w.find_base_of("p1")
	ok(g != null and base != null, "（前提）双方都有将领 / 大本营")
	if g == null or base == null:
		return
	# 挪到敌方大本营那一格（那一格属于 p1 的区划）
	g.tx = int(base.tx)
	g.ty = int(base.ty)
	ok(not w.leader_zone_owned(g), "★★ 站到敌方区划里就下不了单（底层规则不变）")
	var cands: Array = AiArmyRes.recruit_candidates(c)
	var found := false
	for it in cands:
		var cd: Dictionary = it
		if String((cd["leader"] as Object).id) == String(g.id):
			found = true
	ok(not found, "★★ 候选表里不再出现「不在己方区划」的将领")
	# 走回自家大本营 ⇒ 重新进候选
	var mine = w.find_base_of("p2")
	if mine != null:
		g.tx = int(mine.tx)
		g.ty = int(mine.ty)
		ok(w.leader_zone_owned(g), "★ 回到己方区划后又能下单了")


# ---- ②b 前排优先：前排没成型不许买后排精英；挑精英按编成权重而不是最便宜 ----
func _test_frontline_first(cfg) -> void:
	var w = _make_world(cfg, 4321, ["p1", "p2"])
	ok(w != null, "（前提）双方都交给 commander 的世界")
	if w == null:
		return
	var c = w.ai_commanders.get("p2", null)
	ok(c != null, "（前提）p2 commander")
	if c == null:
		return
	# 前排判据（纯函数）：数量 ≥ 4 且 占比 ≥ 55%
	ok(c.frontline_ready_from(4, 2), "★ 前排 4 / 后排 2 ⇒ 成型（占比 0.67）")
	ok(not c.frontline_ready_from(2, 6), "★ 前排 2 / 后排 6 ⇒ 没成型（数量不够）")
	ok(not c.frontline_ready_from(3, 3), "★ 前排 3（少于 4）⇒ 没成型")
	ok(not c.frontline_ready_from(5, 5), "★ 前排占比 50% 低于 55% ⇒ 没成型")
	# 前后排分类
	ok(c.is_backline_kind("dg_bolt"), "★ 弩炮算后排")
	ok(not c.is_backline_kind("dg_champion"), "★ 冠军骑士算前排")
	var c1 = w.ai_commanders.get("p1", null)
	if c1 != null:
		ok(c1.is_backline_kind("dy_catapult"), "★ 投石车算后排")
		ok(not c1.is_backline_kind("dy_royal"), "★ 御林军算前排")
		var wr: float = c1.composition_weight_of("dy_royal")
		var wc: float = c1.composition_weight_of("dy_catapult")
		var wch: float = c1.composition_weight_of("dy_chariot")
		ok(wr > wc, "★★ 编成权重：御林军(%.2f) 高于 投石车(%.2f)" % [wr, wc])
		ok(wr > wch, "★★ 编成权重：御林军(%.2f) 高于 战车(%.2f)" % [wr, wch])
	# 解锁三阶（直接把大本营写成 3 级）⇒ 看挑出来的精英是前排还是后排
	var b1 = w.find_base_of("p1")
	var b2 = w.find_base_of("p2")
	if b1 != null:
		(b1 as Object).level = 3
	if b2 != null:
		(b2 as Object).level = 3
	if c1 != null:
		var pick1: Dictionary = c1._elite_candidate()
		ok(not pick1.is_empty(), "★★ 王朝能挑出一条高阶兵")
		if not pick1.is_empty():
			eq(String(pick1["kind"]), "dy_royal",
				"★★ 王朝挑的是御林军（编成权重最高），不是投石车")
	var pick2: Dictionary = c._elite_candidate()
	ok(not pick2.is_empty(), "★★ 帝国能挑出一条高阶兵")
	if not pick2.is_empty():
		eq(String(pick2["kind"]), "dg_champion",
			"★★ 帝国挑的是冠军骑士（前排），不是弩炮")
