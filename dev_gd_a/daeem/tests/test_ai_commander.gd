## test_ai_commander.gd —— ★ 阵营指挥官 AI：经济 / 生产 / 建造 / 指令 / 快照 / 确定性。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const AiProfileRes = preload("res://logic/ai_profile.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const UnitRes = preload("res://logic/unit.gd")
const AiArmyRes = preload("res://logic/ai_army.gd")
const AiBuildRes = preload("res://logic/ai_build.gd")
const GridRes = preload("res://logic/grid.gd")

const COOP_LEVEL := "res://data/campaigns/demo/levels/02_twin_line.json"
const AI_TEST_LEVEL := "res://data/campaigns/demo/levels/ai_test.json"

func _initialize() -> void:
	_case_name = "test_ai_commander"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_profile(cfg)
	_test_world_setup(cfg)
	_test_coop_start_resources(cfg)
	_test_force_cap_and_generals(cfg)
	_test_economy_and_production(cfg)
	_test_build_and_tech(cfg)
	_test_directives(cfg)
	_test_command_route(cfg)
	_test_defense(cfg)
	_test_patrol(cfg)
	_test_producer_reserved(cfg)
	_test_rotation(cfg)
	_test_training_home_rotation(cfg)
	_test_training_leader_can_patrol(cfg)
	_test_avoid_big_fights(cfg)
	_test_revive_recall(cfg)
	_test_points_in_bounds(cfg)
	_test_cohesion(cfg)
	_test_undefended_capture(cfg)
	_test_roles(cfg)
	_test_attack_reaction(cfg)
	_test_tower_strategy(cfg)
	_test_build_economy_guard(cfg)
	_test_wall_and_upgrade(cfg)
	_test_wall_border(cfg)
	_test_build_priority(cfg)
	_test_base_build_priority(cfg)
	_test_bootstrap_capture(cfg)
	_test_capture_build_block(cfg)
	_test_idle_defensive_posts(cfg)
	_test_idle_scouting(cfg)
	_test_idle_ready_guards(cfg)
	_test_zone_guards(cfg)
	_test_recruit_recall(cfg)
	_test_general_staffing(cfg)
	_test_early_explore(cfg)
	_test_early_game(cfg)
	_test_front_general_recruit(cfg)
	_test_team_production_targets(cfg)
	_test_march_moves_army(cfg)
	_test_march_early_end(cfg)
	_test_expand_target(cfg)
	_test_auto_captures_zones(cfg)
	_test_no_lone_wanderers(cfg)
	_test_panel_state(cfg)
	_test_snapshot(cfg)
	_test_determinism(cfg)


func _make_world(cfg, seed_value: int = 1234):
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true,
		{"F2": LevelRes.AI_COMMANDER}, {"F2": {"difficulty": "normal"}}, seed_value)


## ai_test 观战局：AI 接管 F1，只有一方（用于验证「自主扩张 / 光杆司令」）。
func _make_ai_test_world(cfg, seed_value: int = 1234):
	var lv = LevelRes.load_level(null, AI_TEST_LEVEL, cfg)
	if lv == null:
		return null
	var seats: Array = lv.seats()
	var watched := String(seats[0]) if not seats.is_empty() else "F1"
	return WorldRes.create_from_level(cfg, lv, watched, seats, true,
		{watched: LevelRes.AI_COMMANDER}, {watched: {"difficulty": "normal"}},
		seed_value, true)


func _ensure_ai_generals(w, faction: String, n: int) -> void:
	var idx := 1
	while w.general_count_of(faction) < n and idx < 64:
		var g = w.create_general(faction, idx, 90)
		if g == null:
			break
		w.units.append(g)
		idx += 1


func _owned_zone_count(w, faction: String) -> int:
	var n := 0
	for z in w.zones.zones:
		if String((z as Dictionary).get("owner", "")) == faction:
			n += 1
	return n


func _test_profile(cfg) -> void:
	var p: Dictionary = AiProfileRes.build(cfg, "F2", [], {"F2": {"difficulty": "hard"}})
	ok(p.has("income_mult"), "profile 有收入倍率")
	ok(float(p["income_mult"]) > 1.0, "hard 收入倍率 > 1")
	ok(int(p["army_cap"]) >= 20, "hard 军队上限够大")
	ok(float(p["army_cap_ratio"]) >= 1.0, "hard 动态上限比例 = 1.0")
	ok(String(p["difficulty_name"]) == "hard", "profile 记住难度名")
	var p2: Dictionary = AiProfileRes.build(cfg, "F2", [], {"F2": {"difficulty": "nope"}})
	eq(String(p2["difficulty_name"]), "normal", "未知难度退回 normal")


func _test_world_setup(cfg) -> void:
	var w = _make_world(cfg)
	ok(w != null, "合作关能建出 AI 队友世界")
	if w == null:
		return
	ok(w.commander_factions().has("F2"), "F2 是 commander")
	ok(not w.commander_factions().has("F1"), "F1 不是 commander")
	ok(w.ai_commanders.has("F2"), "F2 有控制器")
	ok(w.find_base_of("F2") != null, "F2 有大本营")
	ok(w.alive_units_of("F2").size() >= 3, "F2 有关卡摆放的部队")
	ok(w.resource_pool_for("F2") != null, "F2 有自己的资源池")
	eq(w.ai_directive_of("F2").get("kind", ""), "auto", "盟友默认自主 auto")
	ok(not w.player_factions.has("F2"), "AI 队友不算玩家操作席位")
	ok(w.ai_teammates_for("F1").has("F2"), "F1 能看到 F2 这个 AI 队友")


func _test_coop_start_resources(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "合作起手资源测试世界")
		return
	near(float(w.resources.get("food", -1.0)), 250.0, 1e-4,
		"★★ 合作 AI 队友：玩家起手粮食对齐 normal 基准")
	near(float(w.resources.get("gold", -1.0)), 250.0, 1e-4,
		"★★ 合作 AI 队友：玩家起手黄金对齐 normal 基准")
	var ai_pool: Dictionary = w.ai_faction_resources.get("F2", {})
	near(float(ai_pool.get("food", -1.0)), 250.0, 1e-4, "友军 AI 起手粮食 normal = 250")
	# 固定 normal 基准：AI 难度调高，玩家仍是 250，AI 自己变 350。
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	var hard_w = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true,
		{"F2": LevelRes.AI_COMMANDER}, {"F2": {"difficulty": "hard"}}, 1234)
	if hard_w != null:
		near(float(hard_w.resources.get("food", -1.0)), 250.0, 1e-4,
			"★★ 玩家起手固定 normal 基准（不跟随 hard）")
		var hard_pool: Dictionary = hard_w.ai_faction_resources.get("F2", {})
		near(float(hard_pool.get("food", -1.0)), 350.0, 1e-4,
			"（前提）友军 AI 自己按 hard 拿 350")
	# 没有 commander 的合作世界：保持 cfg.start_*，不抬升。
	var plain_w = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true)
	if plain_w != null:
		near(float(plain_w.resources.get("food", -1.0)), float(cfg.start_food), 1e-4,
			"★ 没有 AI 队友的合作局不抬粮食")
		near(float(plain_w.resources.get("gold", -1.0)), float(cfg.start_gold), 1e-4,
			"★ 没有 AI 队友的合作局不抬黄金")


func _test_force_cap_and_generals(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "上限测试世界")
		return
	var c = w.ai_commanders["F2"]
	var base = w.find_base_of("F2")
	if base == null:
		ok(false, "上限测试需要基地")
		return
	var cap3 := int(c.force_cap())
	ok(cap3 > 0, "有将领时有动态军队上限")
	eq(int(c.general_target()), 2, "1 级大本营补将目标 = 2")
	var cap_before := int(c.force_cap())
	var g = w.create_general("F2", 0, 3)
	ok(g != null, "能造第 4 位将领")
	if g != null:
		w.units.append(g)
		ok(int(c.force_cap()) > cap_before, "多一位将领后上限变大")
	base.level = 2
	eq(int(c.general_target()), 5, "2 级大本营补将目标 = 5")
	base.level = 3
	eq(int(c.general_target()), 6, "3 级大本营补将目标 = 6")
	# 3 级基地 + 充足资源：真的会继续补将（不是只算了个目标）
	w.ai_faction_resources["F2"] = {"food": 2000.0, "gold": 2000.0}
	var bz = w.zones.zone_at(base.tx, base.ty)
	if bz != null:
		(bz as Dictionary)["population"] = 10.0
	c.general_try_timer = 0.0
	var before_generals: int = int(w.general_count_of("F2"))
	c._try_general_recruit()
	ok(w.general_count_of("F2") > before_generals, "★ 3 级大本营会实际继续补将")
	base.level = 1


func _test_economy_and_production(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "经济测试世界")
		return
	var c = w.ai_commanders["F2"]
	var f0 := float(c.panel_state()["food"])
	var g0 := float(c.panel_state()["gold"])
	var army0 := AiArmyRes.army_count(c)
	var r0 := int(c.stats.get("recruits", 0))
	for i in 200:
		w.tick(0.1)
	var st: Dictionary = c.panel_state()
	var f1 := float(st["food"])
	var g1 := float(st["gold"])
	ok(f1 >= 0.0 and g1 >= 0.0, "20 秒后资源不为负")
	ok(int(c.stats.get("recruits", 0)) > r0, "★ 有队伍没补满时会继续补员")
	ok(AiArmyRes.army_count(c) >= army0, "军队数量不减少")
	ok(f1 != f0 or g1 != g0, "资源随收入变化")
	# ★ 新口径：每支队伍都有目标规模，不会把全族的兵都塞进一支队伍。
	var biggest := 0
	for t in AiArmyRes.leader_teams(c):
		biggest = maxi(biggest, int(t["size"]))
	ok(biggest <= int(c.profile.get("production", {}).get("home_team_size", 6)) + 2,
		"★ 没有哪支队伍被一路招到全族上限（最大 %d 人）" % biggest)


func _test_build_and_tech(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "建造测试世界")
		return
	var c = w.ai_commanders["F2"]
	# ★ 2026.10.25：基础产能减半 + 全部造价 ×2 之后，AI 的「补员预算优先」在头 25 秒
	#   会把钱全留给招募（补员预留 = 6 个最便宜兵种 × 新造价），建造自然被推迟。
	#   本用例只验「建造 / 科技 / 特化这条链路走得通」，所以先给足资源；
	#   「钱不够时不乱建」由 _test_build_economy_guard / _test_build_priority 单独钉。
	w.ai_faction_resources["F2"] = {"food": 3000.0, "gold": 3000.0}
	for i in 250:
		w.tick(0.1)
	ok(int(c.stats.get("builds", 0)) >= 1, "AI 至少建造 / 升级一次")
	ok(int(c.stats.get("techs", 0)) >= 1, "AI 至少启用一条科技")
	ok(int(c.stats.get("specs", 0)) >= 1, "AI 至少做一次区划特化")


func _test_directives(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "指令测试世界")
		return
	eq(w.set_ai_directive("F2", "march", 10.0, 10.0, "F1"), "", "march 指令被接受")
	eq(int(w.ai_directive_of("F2").get("serial", 0)), 1, "指令序号 +1")
	ok(float(w.ai_directive_of("F2").get("until", 0.0)) > w.time, "★ 指令带临时保留时间")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "march", "指令写回世界")
	eq(w.set_ai_directive("F2", "develop", -1.0, -1.0, "F1"), "", "develop 指令被接受")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "develop", "develop 覆盖 march")
	eq(w.set_ai_directive("F2", "march", 9999.0, -1.0, "F1"), "out_of_map", "地图外被拒")
	eq(w.set_ai_directive("F2", "march", 10.0, 10.0, "enemy"), "not_ally", "非同一方被拒")
	eq(w.set_ai_directive("F1", "develop", -1.0, -1.0, "F1"), "no_ai", "非 commander 被拒")
	eq(w.set_ai_directive("F2", "bogus", -1.0, -1.0, "F1"), "bad_order", "未知指令被拒")
	ok(w.set_ai_directive("F2", "mass", 12.0, 12.0, "F1") == "", "mass 指令被接受")
	ok(w.set_ai_directive("F2", "expand", -1.0, -1.0, "F1") == "", "expand 指令被接受")
	# 水域不可通行：点水面应自动落到最近岸边，而不是拒掉。
	var water := Vector2i(-1, -1)
	for yy in w.map.rows:
		for xx in w.map.cols:
			if w.map.is_water(xx, yy):
				water = Vector2i(xx, yy)
				break
		if water.x >= 0:
			break
	if water.x >= 0:
		eq(w.set_ai_directive("F2", "march", float(water.x) + 0.5,
			float(water.y) + 0.5, "F1"), "", "水面自动落到岸边")
		var tgt: Vector2i = w.ai_panel_state("F2").get("target", Vector2i(-1, -1))
		ok(tgt != water, "落点不是水面")


func _test_command_route(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "命令链路测试世界")
		return
	ok(CommandRes.apply(w, cfg, {
		"kind": "ai_order", "faction": "F1", "ai_faction": "F2",
		"order": "march", "x": 10.0, "y": 10.0,
	}), "★ ai_order 走 command_processor 被接受")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "march", "命令链路写入 march")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "ai_order", "faction": "enemy", "ai_faction": "F2",
		"order": "march", "x": 10.0, "y": 10.0,
	}), "不同方的 ai_order 被拒")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "ai_order", "faction": "F1", "ai_faction": "F2",
		"order": "march", "x": 9999.0, "y": 10.0,
	}), "地图外 ai_order 被拒")
	# 屯兵：接受到点集结
	eq(w.set_ai_directive("F2", "mass", 12.0, 12.0, "F1"), "", "mass 接受")
	var c = w.ai_commanders["F2"]
	for i in 40:
		w.tick(0.1)
	ok(int(c.stats.get("orders", 0)) >= 1, "屯兵至少发出一组命令")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "mass", "指令仍是 mass")
	# 临时倾向到期：直接把它推到过期，下一 tick 应回到 auto
	w.ai_directives["F2"]["until"] = w.time - 0.1
	w.tick(0.1)
	eq(String(w.ai_directive_of("F2").get("kind", "")), "auto", "★ 指令到期回到自主 auto")


func _test_defense(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "回防测试世界")
		return
	var base = w.find_base_of("F2")
	if base == null:
		ok(false, "回防测试需要 F2 大本营")
		return
	var c = w.ai_commanders["F2"]
	var foe = UnitRes.create(cfg, "foe-near-base", "敌将",
		Vector2i(maxi(0, base.tx - 2), base.ty), "enemy", "general")
	ok(foe != null, "能造一个测试敌将")
	if foe == null:
		return
	# 让它活够 4 秒：这段测的是「AI 会不会回防」，不是「守军几秒打死它」。
	foe.hp_max = 100000.0
	foe.base_hp_max = 100000.0
	foe.hp = 100000.0
	w.units.append(foe)
	w.fog.update(w)
	ok(w.fog.unit_visible("F2", foe), "敌将进入 F2 视野（前提）")
	var before := int(c.stats.get("orders", 0))
	# 难度 normal 的 reaction_delay 是 1.2s，army 决策间隔 0.6s；留 4s 足够。
	for i in 40:
		w.tick(0.1)
	ok(c.defend_until > w.time or int(c.stats.get("orders", 0)) > before,
		"★ 基地区域出现敌人时 AI 会回防 / 下令")


func _test_patrol(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "巡逻测试世界")
		return
	var c = w.ai_commanders["F2"]
	c.order_kind = "auto"
	c.patrol_next_at = 0.0
	var before := int(c.stats.get("orders", 0))
	AiArmyRes._patrol(c)
	ok(int(c.stats.get("orders", 0)) > before, "★ 自主模式会派巡逻队")
	ok(c.patrol_next_at > w.time, "巡逻有下一次间隔")


func _test_producer_reserved(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "生产保留测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F2"]
	var home = AiArmyRes.ensure_garrison(c)
	ok(home != null, "★ 基地区划里有守军将领")
	if home == null:
		return
	eq(String(c.garrison_leader_id), String(home.id), "★ 守军 id 写回控制器")
	var fields := AiArmyRes.field_teams(c)
	ok(not fields.is_empty(), "（前提）至少有一支外勤队")
	if fields.is_empty():
		return
	var field_leader = fields[0]["leader"]
	ok(field_leader != home, "★ 外勤队不含守军")
	# 生产候选里，守军的优先级应该高于外勤队（守军先补满）。
	var cands: Array = AiArmyRes.recruit_candidates(c)
	if not cands.is_empty():
		ok(bool((cands[0] as Dictionary).get("garrison", false)),
			"★ 补员优先守军（第一候选是守军）")
	ok(AiArmyRes.recruit_candidates(c).size() < AiArmyRes.leader_teams(c).size(),
		"★ 已经满编的队伍不会出现在补员候选里（按队补员）")


## ★★ 守军轮换：守军补满 + 基地里有一支还没满的接替队 ⇒ 换人，老守军出门。
func _test_rotation(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "轮换测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var home = AiArmyRes.ensure_garrison(c)
	if home == null:
		ok(false, "（前提）ai_test 有守军")
		return
	# 把守军「补满」：直接排 3 个（只要 projected 达到 home_team_size 即可）。
	var target := int(c.profile.get("production", {}).get("home_team_size", 6))
	while AiArmyRes.team_projected(c, home) < target:
		home.train_queue.append("spearman")
	# 造一位接替将领 + 1 个兵，站到基地里。
	var rep = w.create_general("F1", 0, 3)
	if rep == null:
		ok(false, "能造接替将领")
		return
	var base = w.find_base_of("F1")
	rep.pos = Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	rep.sync_tile(w.map)
	w.units.append(rep)
	w.fill_general_retinue(rep, 1, [{"type": "spearman", "weight": 1}])
	ok(AiArmyRes.team_escorts(c, rep) >= 1, "（前提）接替将领至少有 1 个兵")
	var before_id := String(c.garrison_leader_id)
	ok(AiArmyRes.maybe_rotate_garrison(c), "★★ 守军满编后会发生轮换")
	ok(String(c.garrison_leader_id) != before_id, "★★ 守军换成了另一位将领")
	eq(String(c.garrison_leader_id), String(rep.id), "★ 接替的就是那支有兵的队")
	ok(int(c.stats.get("rotations", 0)) >= 1, "★ 轮换计入统计")


## ★★ 每支队伍按自己的目标规模补员：守军 home_team_size、外勤 field_team_size。
## ★★ 读条中的守军只要已经够「出门规模」，就应该能被换下来去巡逻 / 扩张，
## 不必等到补满 home_team_size。
func _test_training_home_rotation(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "训练中守军轮换测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var home = AiArmyRes.ensure_garrison(c)
	if home == null:
		ok(false, "（前提）有守军")
		return
	var ec: Dictionary = c.profile.get("expand", {})
	var min_units := int(ec.get("min_field_units", 3))
	ok(AiArmyRes.team_total(c, home) >= min_units, "（前提）守军已经够出门规模")
	# 让它处于读条中（不是补满状态）。
	home.train_kind = "spearman"
	home.train_total = 10.0
	home.train_remaining = 10.0
	ok(home.is_training(), "（前提）守军正在招募")
	ok(AiArmyRes.team_projected(c, home) < int(c.profile.get("production", {}).get("home_team_size", 6)),
		"（前提）守军还没补满（旧逻辑会一直把它钉在家里）")
	# 造一位能接防的将领（1 个兵）。
	var rep = w.create_general("F1", 0, 3)
	if rep == null:
		ok(false, "能造接防将领")
		return
	var base = w.find_base_of("F1")
	rep.pos = Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	rep.sync_tile(w.map)
	w.units.append(rep)
	w.fill_general_retinue(rep, 1, [{"type": "spearman", "weight": 1}])
	var before := String(c.garrison_leader_id)
	ok(AiArmyRes.maybe_rotate_garrison(c),
		"★★ 读条中的守军够出门规模时可以被换下来（不必补满）")
	ok(String(c.garrison_leader_id) != before, "★★ 守军换人")
	ok(AiArmyRes.ready_field_teams(c, min_units).size() > 0,
		"★★ 换下来的读条守军进入可巡逻 / 可出征的队伍列表")


## ★★ 正在读条的将领也可以被派去巡逻 / 出征（不再因为 is_training 被跳过）。
func _test_training_leader_can_patrol(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "读条将领巡逻测试世界")
		return
	var c = w.ai_commanders["F1"]
	var ec: Dictionary = c.profile.get("expand", {})
	var min_units := int(ec.get("min_field_units", 3))
	# 造一位外勤将领 + 2 个兵（够出门规模），并让它处于读条中。
	var g = w.create_general("F1", 1, 4)
	if g == null:
		ok(false, "能造外勤将领")
		return
	# 放在基地外的己方/中立区划中心附近，确保它不会被 `ensure_garrison` 选成守军。
	var z0 = w.zone_by_id(0)
	if z0 == null:
		ok(false, "（前提）有 0 号区划")
		return
	var ct: Vector2i = (z0 as Dictionary)["center"]
	g.pos = Vector2(float(ct.x) + 1.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	w.fill_general_retinue(g, min_units - 1, [{"type": "spearman", "weight": 1}])
	g.train_kind = "spearman"
	g.train_total = 10.0
	g.train_remaining = 10.0
	ok(g.is_training(), "（前提）它正在读条")
	var ready: Array = AiArmyRes.ready_field_teams(c, min_units)
	var found := false
	for t in ready:
		if (t["leader"] as Object) == g:
			found = true
	ok(found, "★★ 读条中的将领仍在「可出门」队伍里")
	# 直接跑一次巡逻：它应该能被选中（不再被 is_training 过滤）。
	c.patrol_next_at = 0.0
	c.patrol_index = 0
	AiArmyRes._patrol(c)
	ok(c.last_orders.has(String(g.id)), "★★ 读条中的将领真的被派去巡逻了")


## ★★ 小股部队不跟成规模敌人硬碰：危险巡逻点会跳过，附近有大军会回撤。
func _test_avoid_big_fights(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "避战测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.fog = null                                  # 测试里让敌人全部可见
	var ec: Dictionary = c.profile.get("expand", {})
	var min_units := int(ec.get("min_field_units", 3))
	var threat_radius := float(c.profile.get("patrol", {}).get("threat_radius", 7.0))
	var avoid_ratio := float(c.profile.get("patrol", {}).get("avoid_enemy_ratio", 1.25))
	# 在 1 号区划（基地所在、地块最开阔）中心附近堆 6 个敌人。
	var z = w.zone_by_id(1)
	if z == null:
		ok(false, "（前提）有 1 号区划")
		return
	var center: Vector2i = (z as Dictionary)["center"]
	var spawned := 0
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			if spawned >= 6:
				break
			var e = w.spawn_enemy(center.x + dx, center.y + dy)
			if e != null:
				spawned += 1
	ok(spawned >= 5, "（前提）刷出了足够多的敌人（%d）" % spawned)
	var pt := Vector2(float(center.x) + 0.5, float(center.y) + 0.5)
	ok(AiArmyRes._point_too_dangerous(c, pt, float(min_units), threat_radius, avoid_ratio),
		"★★ 小股部队不会把「大量敌人所在」的点当巡逻点")
	ok(not AiArmyRes._point_too_dangerous(c, pt, 20.0, threat_radius, avoid_ratio),
		"★ 大部队不会因为同一群敌人就判定为「不能去」")
	# 造一支 3 人小队站在敌人旁边，跑一次避战：应该被标记为回撤。
	var g = w.create_general("F1", 1, 5)
	if g == null:
		ok(false, "能造避战测试小队")
		return
	g.pos = Vector2(float(center.x) + 1.5, float(center.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	w.fill_general_retinue(g, min_units - 1, [{"type": "spearman", "weight": 1}])
	c.regroup_ids.clear()
	AiArmyRes._avoid_bad_fights(c)
	ok(c.regroup_ids.has(String(g.id)), "★★ 小队附近有大军时会被命令回撤，而不是硬碰")


## ★★ 倒地的将领：安全位置能再起，敌后 / 太远没兵时召回。
func _test_revive_recall(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "再起 / 召回测试世界")
		return
	var c = w.ai_commanders["F1"]
	var base = w.find_base_of("F1")
	if base == null:
		ok(false, "（前提）有基地")
		return
	# 1) 在基地倒下：血量到门槛 → 再起。
	var g = w.create_general("F1", 1, 4)
	if g == null:
		ok(false, "能造再起测试将领")
		return
	g.pos = Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	g.enter_near_death(cfg.revive_regen_sec)
	g.hp = g.hp_max * 0.15
	ok(g.revive_ready(cfg), "（前提）血量回到再起门槛")
	c._revive_tick()
	ok(g.is_reviving(), "★★ 指挥官 AI 会给倒地的将领点再起")
	ok(int(c.stats.get("revives", 0)) >= 1, "★★ 再起计入 stats")
	# 2) 倒在敌方区划、只带一个兵：召回会把它和这个兵一起清掉。
	var g2 = w.create_general("F1", 1, 5)
	if g2 == null:
		ok(false, "能造召回测试将领")
		return
	var z6 = w.zone_by_id(6)
	if z6 == null:
		ok(false, "（前提）有 6 号区划")
		return
	var ct: Vector2i = (z6 as Dictionary)["center"]
	g2.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	g2.sync_tile(w.map)
	w.units.append(g2)
	w.fill_general_retinue(g2, 1, [{"type": "spearman", "weight": 1.0}])
	var escorts: Array = w.retinue_of(g2.id, true)
	ok(escorts.size() == 1, "（前提）召回测试将领带着 1 个兵")
	(z6 as Dictionary)["owner"] = "enemy"
	g2.enter_near_death(cfg.revive_regen_sec)
	ok(not g2.revive_ready(cfg), "（前提）召回测试将领还没到再起门槛")
	c._revive_tick()
	ok(not g2.alive, "★★ 敌后且兵少时，AI 会召回将领")
	for m in escorts:
		ok(not m.alive and not w.units.has(m),
			"★★ 召回立刻清掉旗下所有部队（%s）" % String(m.id))
	ok(int(c.stats.get("recalls", 0)) >= 1, "★★ 召回计入 stats")


## ★★ AI 的所有目标点都必须夹在地图内（基地贴边 / 巡逻环 / 区划中心 +1.5 都可能出界）。
func _test_points_in_bounds(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "边界测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var max_x := float(w.map.cols) - 0.5
	var max_y := float(w.map.rows) - 0.5
	var p = AiArmyRes._clamp_map_point(c, Vector2(-50.0, 999.0))
	ok(p.x >= 0.5 and p.x <= max_x and p.y >= 0.5 and p.y <= max_y,
		"★★ 任意点会被夹进地图（%.1f, %.1f）" % [p.x, p.y])
	var pts: Array = AiArmyRes._patrol_points(c)
	ok(not pts.is_empty(), "（前提）有巡逻点")
	for pt in pts:
		var q: Vector2 = pt
		ok(q.x >= 0.5 and q.x <= max_x and q.y >= 0.5 and q.y <= max_y,
			"★★ 巡逻点在地图内（%.1f, %.1f）" % [q.x, q.y])
	# 直接对一个图外点下命令：`last_orders` 里记的必须是夹过的点。
	var home = AiArmyRes.ensure_garrison(c)
	if home == null:
		ok(false, "（前提）有守军")
		return
	var team := {"leader": home, "units": w.group_of(home)}
	AiArmyRes._order_team(c, team, Vector2(-100.0, -100.0), false)
	var lo: Dictionary = c.last_orders.get(String(home.id), {})
	var lp: Vector2 = lo.get("pt", Vector2(-999.0, -999.0))
	ok(lp.x >= 0.5 and lp.x <= max_x and lp.y >= 0.5 and lp.y <= max_y,
		"★★ 下达给部队的目标点不会跑到地图外（%.1f, %.1f）" % [lp.x, lp.y])
	# 真跑一段：所有 AI 单位都必须留在地图内。
	for i in 200:
		w.tick(0.1)
	for u in w.units:
		ok(u.tx >= 0 and u.tx < w.map.cols and u.ty >= 0 and u.ty < w.map.rows,
			"★★ 单位 %s 的格坐标在地图内（%d,%d）" % [u.id, u.tx, u.ty])
		ok(u.pos.x >= 0.0 and u.pos.x <= float(w.map.cols)
				and u.pos.y >= 0.0 and u.pos.y <= float(w.map.rows),
			"★★ 单位 %s 的浮点坐标在地图内（%.2f,%.2f）" % [u.id, u.pos.x, u.pos.y])


## ★★ 队伍粘合：附属兵掉队 / 停下时，AI 重发的是**整队**命令，不是单个兵的命令。
func _test_cohesion(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "粘合测试世界")
		return
	var c = w.ai_commanders["F1"]
	var g = w.create_general("F1", 1, 6)
	if g == null:
		ok(false, "能造粘合测试将领")
		return
	w.units.append(g)
	w.fill_general_retinue(g, 2, [{"type": "spearman", "weight": 1.0}])
	var escorts: Array = w.retinue_of(g.id, true)
	ok(escorts.size() == 2, "（前提）粘合测试将领带着 2 个兵")
	var target := Vector2(float(w.map.cols) - 3.5, float(w.map.rows) - 3.5)
	AiArmyRes._order_team(c, {"leader": g, "units": w.group_of(g)}, target, true)
	ok(bool(g.has_attack_move), "（前提）将领收到整队行军命令")
	var stray = escorts[0]
	stray.stop()
	stray.has_attack_move = false
	c.cohesion_next_at = 0.0
	var orders_before := int(c.stats.get("orders", 0))
	AiArmyRes._cohesion_tick(c)
	ok(int(c.stats.get("orders", 0)) > orders_before,
		"★★ 掉队时 AI 会重新下命令")
	ok(bool(stray.has_attack_move), "★★ 掉队的附属兵重新收到整队命令")
	ok(stray.attack_move_goal.distance_to(g.attack_move_goal) < 0.1,
		"★★ 重发的是同一个整队目标，不是单独给这个兵指路")
	# ★★ 已经在打自己目标的掉队兵，也要被整队命令收回来。
	var foe = w.spawn_enemy(1, 1)
	if foe != null:
		stray.target = foe
		stray.target_building = null
		stray.pos = g.pos + Vector2(10.0, 0.0)
		stray.has_attack_move = false
		c.cohesion_next_at = 0.0
		AiArmyRes._cohesion_tick(c)
		ok(stray.target == null,
			"★★ 打自己目标的掉队兵，会被整队命令解除单兵交战")
		ok(bool(stray.has_attack_move),
			"★★ 掉队兵重新拿到整队行军命令")
		# ★★ 将领已经在打目标时，后方停住的兵也要被拉上来；
		#    以前 `leader.target != null` 会直接跳过整支队的粘合。
		g.target = foe
		g.target_building = null
		stray.target = null
		stray.target_building = null
		stray.stop()
		stray.pos = g.pos + Vector2(9.0, 0.0)
		stray.sync_tile(w.map)
		c.cohesion_next_at = 0.0
		AiArmyRes._cohesion_tick(c)
		ok(bool(stray.moving) or bool(stray.has_attack_move),
			"★★ 将领交战时，后方停住的兵也会重新收到移动命令")


## ★★ 区划守军被清空后，残队也要继续去中心占领，不能因为掉编就放弃。
func _test_undefended_capture(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "占领测试世界")
		return
	var c = w.ai_commanders["F1"]
	var z6 = w.zone_by_id(6)
	if z6 == null:
		ok(false, "（前提）6 号区划")
		return
	var g = w.create_general("F1", 1, 8)
	if g == null:
		ok(false, "能造占领测试将领")
		return
	w.units.append(g)
	ok(AiArmyRes.team_total(c, g) == 1, "（前提）这支残队只有将领 1 人")
	c.target_zone = 6
	c.expand_team_ids.clear()
	c.expand_team_ids.append(String(g.id))
	c.expand_started_at = w.time
	ok(AiArmyRes._continue_expand(c), "★★ 区划已无守军时，残队仍会继续执行占领")
	eq(c.target_zone, 6, "★★ 不会因为队伍掉编就清掉占领任务")
	ok(bool(g.has_attack_move), "★★ 残队被派往区划中心")
	var ct: Vector2i = (z6 as Dictionary)["center"]
	var center := Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	ok(g.attack_move_goal.distance_to(center) < 2.0,
		"★★ 目标是区划中心（占领范围）")
	# ★★ 敌方区划的守军已经清空：不应再被 enemy_zone_min_units=7 卡住。
	(z6 as Dictionary)["owner"] = "enemy"
	var req := AiArmyRes._required_units_for_zone(c, z6)
	ok(req <= int(c.profile.get("expand", {}).get("min_field_units", 3)),
		"★★ 敌方区划无守军时，按小队规模派兵（实际要求 %d 人）" % req)
	# ★★ 已经在敌方区划里、敌人清空但没有扩张任务的队伍，也要直接去中心。
	c.target_zone = -1
	c.expand_team_ids.clear()
	c.assault_team_ids.clear()
	g.stop()
	g.target = null
	g.target_building = null
	g.has_attack_move = false
	g.pos = Vector2(float(ct.x) + 2.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	AiArmyRes._capture_cleared_zone_tick(c)
	ok(bool(g.has_attack_move), "★★ 已进入敌方空区划的部队会去中心占领")
	ok(g.attack_move_goal.distance_to(center) < 2.0,
		"★★ 占领目标就是该区划中心")


## ★★ 职能：按 cycle 分配；远程队有独立编成 / 站位；游击队只打空档。
func _test_roles(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "职能测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	c._ensure_team_roles()
	var roles: Dictionary = c.team_roles
	ok(not roles.is_empty(), "（前提）初始将领分到职能")
	# 补两位将，确保 cycle 里的远程 / 游击队都出现。
	for i in 2:
		var g = w.create_general("F1", 1, 20 + i)
		if g != null:
			w.units.append(g)
	c._ensure_team_roles()
	var vals: Array = []
	for v in c.team_roles.values():
		if not vals.has(String(v)):
			vals.append(String(v))
	ok(vals.has("line"), "★★ 有正面队（line）")
	ok(vals.has("ranged"), "★★ 有远程队标签")
	ok(vals.has("guerrilla"), "★★ 有游击队标签")
	var roles_cfg: Dictionary = c.profile.get("roles", {})
	var gc: Dictionary = roles_cfg.get("guerrilla", {})
	var gcomp: Array = gc.get("composition", [])
	var has_fast := false
	for item in gcomp:
		if typeof(item) == TYPE_DICTIONARY:
			var k := String((item as Dictionary).get("type", ""))
			if k == "rider" or k == "horse_archer":
				has_fast = true
	ok(has_fast, "★★ 游击队编成偏快速单位")
	var gz = AiArmyRes._pick_guerrilla_zone(c)
	ok(gz != null, "★★ 游击队能找到没有防备的边界区划")
	var rcomp: Array = (roles_cfg.get("ranged", {}) as Dictionary).get("composition", [])
	ok(not c._first_frontline_kind(rcomp).is_empty(),
		"★★ 远程队编成里保留了可招的抗线兵")
	# 远程队目标点：停在 standoff 距离外，而不是贴着中心。
	var ranged_leader = null
	for u in w.units:
		if u.alive and u.is_general() and String(c.team_roles.get(String(u.id), "")) == "ranged":
			ranged_leader = u
			break
	ok(ranged_leader != null, "（前提）找到远程队将领")
	if ranged_leader != null:
		var target := Vector2(10.0, 10.0)
		ranged_leader.pos = Vector2(4.0, 4.0)
		var rp := AiArmyRes._role_target_point(c, ranged_leader, target)
		var standoff := float((roles_cfg.get("ranged", {}) as Dictionary).get("standoff_tiles", 4.5))
		ok(absf(rp.distance_to(target) - standoff) < 0.6,
			"★★ 远程队停在目标 %.1f 格外（实际 %.1f）" % [standoff, rp.distance_to(target)])
	# 远程队前排倒光 + 附近有敌人 ⇒ 整队后撤。
	var rg = w.create_general("F1", 1, 30)
	if rg != null:
		w.units.append(rg)
		rg.pos = Vector2(3.5, 3.5)
		rg.sync_tile(w.map)
		c.team_roles[String(rg.id)] = "ranged"
		w.fill_general_retinue(rg, 2, [{"type": "longbowman", "weight": 1.0}])
		ok(c.frontline_count(rg) == 0, "（前提）远程队没有前排")
		w.spawn_enemy(5, 3)
		var before := int(c.stats.get("role_retreats", 0))
		AiArmyRes._avoid_bad_fights(c)
		ok(int(c.stats.get("role_retreats", 0)) > before,
			"★★ 前排倒光的远程队会触发职能后撤")
		var base = w.find_base_of("F1")
		if base != null:
			var rally := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
			ok(bool(rg.moving) and rg.goal.distance_to(rally) < 5.0,
				"★★ 后撤目标是基地（整队普通移动，不是行军攻击）")


## ★★ 队伍有命令时挨打：不进入默认单兵复仇，由 AI 立即整队反击 / 继续撤。
func _test_attack_reaction(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "受击决策测试世界")
		return
	var c = w.ai_commanders["F1"]
	var g = w.create_general("F1", 1, 40)
	if g == null:
		ok(false, "能造受击决策将领")
		return
	w.units.append(g)
	g.pos = Vector2(10.5, 10.5)
	g.sync_tile(w.map)
	c.team_roles[String(g.id)] = "line"
	w.fill_general_retinue(g, 2, [{"type": "spearman", "weight": 1.0}])
	var target := Vector2(float(w.map.cols) - 3.0, 10.5)
	AiArmyRes._order_team(c, {"leader": g, "units": w.group_of(g)}, target, true)
	ok(bool(g.has_attack_move), "（前提）队伍有行军命令")
	var foe = w.spawn_enemy(12, 10)
	ok(foe != null, "（前提）有攻击者")
	var ev: bool = w.on_unit_attacked(g, foe)
	ok(not ev and g.retaliate_target == null,
		"★★ 队伍有命令时，不进入默认单兵复仇反击")
	ok(bool(g.has_attack_move), "★★ AI 给整队重新下达了命令")
	var counter := int(c.stats.get("counterattacks", 0))
	ok(counter >= 1, "★★ 敌弱时 AI 选择整队反击")
	# 冷却 / 模式锁内再次挨打：不能每一下都重新下命令（这是抽搐的主要来源）。
	w.on_unit_attacked(g, foe)
	eq(int(c.stats.get("counterattacks", 0)), counter,
		"★★ 冷却期内连续受击不重复刷即时命令")
	ok(bool(g.has_attack_move) and g.retaliate_target == null,
		"★★ 冷却期内保持当前整队命令，不切单兵复仇")
	# 冷却到期也不能马上反悔：模式锁还在，继续保持反击。
	c.react_next.clear()
	w.on_unit_attacked(g, foe)
	eq(int(c.stats.get("counterattacks", 0)), counter,
		"★★ 冷却到期但模式锁未到期时，仍不重新决策")
	# 敌强：整队改为后撤回基地，而不是几个兵各自反击。
	_clear_react_locks(c)
	g.attack_move_goal = target
	g.has_attack_move = true
	for i in 5:
		w.spawn_enemy(12, 10 + i)
	var before_retreat := int(c.stats.get("role_retreats", 0))
	w.on_unit_attacked(g, foe)
	ok(int(c.stats.get("role_retreats", 0)) > before_retreat,
		"★★ 敌强时 AI 选择整队后撤")
	var base = w.find_base_of("F1")
	if base != null:
		var rally := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
		ok(bool(g.moving) and g.goal.distance_to(rally) < 5.0,
			"★★ 后撤命令的目标是基地（普通移动）")
	# ★★ 没有任务时同样不能走单兵复仇：指挥官要接管并给整队下令。
	_clear_react_locks(c)
	var g2 = w.create_general("F1", 2, 41)
	if g2 != null:
		w.units.append(g2)
		g2.pos = Vector2(4.5, 16.5)
		g2.sync_tile(w.map)
		c.team_roles[String(g2.id)] = "line"
		w.fill_general_retinue(g2, 2, [{"type": "spearman", "weight": 1.0}])
		var foe2 = w.spawn_enemy(6, 16)
		if foe2 == null:
			ok(false, "（前提）能刷出第二个攻击者")
		else:
			var before_counter := int(c.stats.get("counterattacks", 0))
			w.on_unit_attacked(g2, foe2)
			ok(g2.retaliate_target == null,
				"★★ 没有任务时挨打也不进入单兵复仇")
			ok(int(c.stats.get("counterattacks", 0)) > before_counter,
				"★★ 没有任务时 AI 仍然判断并下达整队反击")
			ok(bool(g2.has_attack_move), "★★ 整队拿到行军攻击命令")
			var escorts_ok := true
			for m in w.group_of(g2):
				if m != g2 and (not m.alive or not bool(m.has_attack_move)):
					escorts_ok = false
			ok(escorts_ok, "★★ 附属兵也拿到同一条整队命令，不脱轨")
			# 已经进入单兵反击的兵，也必须被整队命令收回来。
			g2.retaliate_target = foe2
			g2.target = foe2
			var ordered := AiArmyRes._order_team(c,
				{"leader": g2, "units": w.group_of(g2)}, foe2.pos, false, true)
			ok(ordered and g2.retaliate_target == null,
				"★★ 整队命令会清掉单兵受击反击，防止一个兵自己追出去")
			# 当前任务是侦察 ⇒ 受击不反击，直接收队回安全区。
			_clear_react_locks(c)
			c.scout_missions[String(g2.id)] = {"pt": g2.pos, "zone": -1}
			var before_scout_retreat := int(c.stats.get("role_retreats", 0))
			w.on_unit_attacked(g2, foe2)
			ok(not c.scout_missions.has(String(g2.id)),
				"★★ 侦察队受击会放弃侦察任务")
			ok(int(c.stats.get("role_retreats", 0)) > before_scout_retreat,
				"★★ 侦察队受击选择整队后撤，而不是反击")


## ★★ 箭塔：一个区划可以多座；前线多、后方少；被入侵时靠中心；拆掉后不原地重建。
func _test_tower_strategy(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "箭塔测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.ai_faction_resources["F1"] = {"food": 6000.0, "gold": 6000.0}
	var z0 = null
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY and String((z as Dictionary).get("owner", "")) == "F1" \
				and (z as Dictionary).get("center", null) != null:
			z0 = z
			break
	if z0 == null:
		ok(false, "（前提）有己方区划")
		return
	var zid := int((z0 as Dictionary).get("id", -1))
	var target := AiBuildRes._tower_target(c)
	ok(target >= 2, "★★ 前线区划的目标箭塔数 > 1（实际 %d）" % target)
	AiBuildRes._try_tower(c)
	AiBuildRes._try_tower(c)
	var mine: Array = []
	for b in w.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == "F1" \
				and int(b.zone_id) == zid:
			mine.append(b)
	ok(mine.size() >= 2, "★★ 同一个区划可以建多座箭塔（实际 %d）" % mine.size())
	if mine.size() >= 2:
		ok(not (int(mine[0].tx) == int(mine[1].tx) and int(mine[0].ty) == int(mine[1].ty)),
			"★★ 多座塔不挤在同一格")
	# 前线塔应压向靠敌方边界，而不是缩在区划中心。
	var ftiles: Array = AiBuildRes._frontier_tiles(c, z0)
	ok(not ftiles.is_empty(), "（前提）前线区划有靠敌方的边界格")
	for b in mine:
		var fmin := 999
		for ft in ftiles:
			var fv: Vector2i = ft
			fmin = mini(fmin, maxi(absi(fv.x - int(b.tx)), absi(fv.y - int(b.ty))))
		ok(fmin <= 4, "★★ 前线箭塔靠近敌方边界（距边界 %d 格）" % fmin)
	# 被入侵：优先贴中心补塔。
	var ct: Vector2i = (z0 as Dictionary)["center"]
	w.spawn_enemy(ct.x + 1, ct.y + 1)
	ok(AiBuildRes._zone_threatened(c, z0), "★★ 区划中心附近出现敌人 → 判定被入侵")
	var near_tile = AiBuildRes._pick_tower_tile(c, z0)
	if near_tile != null:
		var ntv: Vector2i = near_tile
		ok(maxi(absi(ntv.x - ct.x), absi(ntv.y - ct.y)) <= 3,
			"★★ 被入侵时补塔位置贴近区划中心")


## ★★ 经济规划：缺编时暂停防御建造，并把补员 / 补将的钱预留下来。
func _test_build_economy_guard(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "经济规划测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.time = 61.0
	w.ai_faction_resources["F1"] = {"food": 200.0, "gold": 200.0}
	var g = w.create_general("F1", 1, 60)
	if g == null:
		ok(false, "（前提）能造缺编将领")
		return
	w.units.append(g)
	g.pos = Vector2(5.5, 5.5)
	g.sync_tile(w.map)
	ok(AiArmyRes.understrength_team_count(c) > 0, "（前提）存在缺编队伍")
	ok(AiBuildRes._defense_paused(c), "★★ 缺编时暂停防御建造")
	var reserve: Dictionary = AiBuildRes._production_reserve(c)
	ok(float(reserve.get("food", 0.0)) >= 200.0,
		"★★ 生产预留覆盖补员成本（food=%.1f）" % float(reserve.get("food", 0.0)))
	var avail: Dictionary = AiBuildRes._build_available(c)
	ok(float(avail.get("food", 0.0)) <= 0.0,
		"★★ 扣除生产预留后没有造塔预算（food）")
	var before := 0
	for b in w.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == "F1":
			before += 1
	AiBuildRes.update(c)
	var after := 0
	for b in w.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == "F1":
			after += 1
	ok(after == before, "★★ 缺编时 update 不会拿补员的钱去建塔")


## ★★ 城墙：前线区划围绕中心 3×3 外圈连续造；被入侵时补缺口；木墙 / 哨塔不升级。
func _test_wall_and_upgrade(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "城墙测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.ai_faction_resources["F1"] = {"food": 8000.0, "gold": 8000.0}
	var z0 = null
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY and String((z as Dictionary).get("owner", "")) == "F1" \
				and (z as Dictionary).get("center", null) != null:
			z0 = z
			break
	if z0 == null:
		ok(false, "（前提）有己方前线区划")
		return
	var ring: Array = AiBuildRes._wall_ring_tiles(c, z0)
	ok(ring.size() == 8, "（前提）中心 3×3 外圈是 8 格")
	for i in 16:
		AiBuildRes._try_wall(c)
	var ring_walls: Array = []
	for b in w.building_list:
		if b.alive and String(b.type) == "wall" and String(b.owner) == "F1":
			ring_walls.append(b)
	ok(ring_walls.size() >= 6, "★★ 前线区划围绕中心连续造墙（%d/8）" % ring_walls.size())
	# 被入侵时补缺口。
	if not ring_walls.is_empty():
		var wb = ring_walls[0]
		var old := Vector2i(int(wb.tx), int(wb.ty))
		w.remove_building(wb, true)
		(z0 as Dictionary)["capture_state"] = "reading"
		(z0 as Dictionary)["capture_faction"] = "p2"
		(z0 as Dictionary)["capture_value"] = 0.5
		AiBuildRes._try_wall(c)
		var rebuilt = false
		for b in w.building_list:
			if b.alive and String(b.type) == "wall" and String(b.owner) == "F1" \
					and int(b.tx) == old.x and int(b.ty) == old.y:
				rebuilt = true
		ok(rebuilt, "★★ 被入侵时优先补上城墙缺口")
	# ★★ 2026.10.26：取消建筑升级 —— AI 只造木墙 / 哨塔，不再升级任何墙塔。
	var any_upgrading := false
	for b in w.building_list:
		if b.alive and String(b.owner) == "F1" and b.is_upgrading():
			any_upgrading = true
			break
	ok(not any_upgrading, "★★ AI 不再升级木墙 / 哨塔")
	ok(not c.stats.has("upgrades"), "★★ AI 统计里不再有 upgrades")


## ★★ 2026.10.25：边境封墙。前期只封与敌方接壤的边；资源到 3×max_float
## 后再补中立边；每 tick 最多 3 格；每一格都真的贴着非己方地块。
func _test_wall_border(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "边境城墙测试世界")
		return
	var c = w.ai_commanders["F1"]
	var bcfg: Dictionary = c.profile.get("build", {})
	ok(int(bcfg.get("wall_hard_max", 0)) >= 200,
		"（前提）全境封边的墙数上限够用（%d）" % int(bcfg.get("wall_hard_max", 0)))
	# 1) 只有 1.67× 浮存、又没有敌方接壤：中立边先不封。
	w.ai_faction_resources["F1"] = {"food": 1000.0, "gold": 1000.0}
	var before := int(c.stats.get("walls_border", 0))
	AiBuildRes._try_border_walls(c, 3)
	eq(int(c.stats.get("walls_border", 0)), before,
		"★ 未到全境富足线时，不封中立接壤的边")
	# 1.5× 富足 + 有敌方接壤：先封前线（不需要等到 3×）。
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY and String((z as Dictionary).get("owner", "")) == "":
			(z as Dictionary)["owner"] = "F2"
	w.ai_faction_resources["F1"] = {"food": 1000.0, "gold": 1000.0}
	var before_front := int(c.stats.get("walls_border", 0))
	AiBuildRes._try_border_walls(c, 3)
	ok(int(c.stats.get("walls_border", 0)) > before_front,
		"★★ 1.5× 富足且与敌方接壤时，先封前线边境")
	# 2) 极富足：继续铺边境长墙。
	w.ai_faction_resources["F1"] = {"food": 3000.0, "gold": 3000.0}
	var before2 := int(c.stats.get("walls_border", 0))
	AiBuildRes._try_border_walls(c, 3)
	var built := int(c.stats.get("walls_border", 0)) - before2
	ok(built >= 1 and built <= 3,
		"★★ 资源极富时按每 tick 预算铺边境墙（实际 %d 格）" % built)
	# 3) 连续两轮也不能超过每 tick 预算。
	var before3 := int(c.stats.get("walls_border", 0))
	AiBuildRes._try_border_walls(c, 3)
	var built3 := int(c.stats.get("walls_border", 0)) - before3
	ok(built3 <= 3, "★★ 单次铺墙不超过 wall_border_per_tick（实际 %d）" % built3)
	# 4) 每一堵墙都应该贴着非己方地块，而不是又围在区划中心。
	var border_walls := 0
	var other_walls := 0
	for b in w.building_list:
		if b == null or not b.alive or String(b.type) != "wall" \
				or String(b.owner) != "F1":
			continue
		if _wall_touches_foreign_tile(w, b):
			border_walls += 1
		else:
			other_walls += 1
	ok(border_walls >= 3,
		"★★ 边境墙真的贴着非己方地块（%d 堵，中心环 %d 堵）" % [border_walls, other_walls])
	# 5) 资源掉下去后不再铺。
	w.ai_faction_resources["F1"] = {"food": 0.0, "gold": 0.0}
	var before4 := int(c.stats.get("walls_border", 0))
	AiBuildRes._try_border_walls(c, 3)
	eq(int(c.stats.get("walls_border", 0)), before4,
		"★ 资源不足时不铺边境墙")


func _wall_touches_foreign_tile(w, b) -> bool:
	for d in GridRes.DIRS4:
		var n: Vector2i = Vector2i(int(b.tx), int(b.ty)) + d
		var oz = w.zones.zone_at(n.x, n.y)
		if oz == null:
			continue
		var owner := String((oz as Dictionary).get("owner", ""))
		if owner != "F1":
			return true
	return false


## ★★ 2026.10.25：建造优先级 —— 这一 tick 能造塔就不造墙；前线塔优先于后方塔。
func _test_build_priority(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "建造优先级测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.ai_faction_resources["F1"] = {"food": 6000.0, "gold": 6000.0}
	var before_t := AiBuildRes._tower_count(c)
	var before_w := AiBuildRes._wall_count(c)
	AiBuildRes._try_tower_then_walls(c)
	ok(AiBuildRes._tower_count(c) > before_t,
		"★★ 有塔位时这一 tick 先造塔")
	eq(AiBuildRes._wall_count(c), before_w,
		"★★ 造出塔的同一 tick 不再花墙的钱")
	# 钱只够墙、不够塔：应该攒钱等塔，而不是先造墙。（墙 50/50，塔 100/100 —— 造价已 ×2）
	w.ai_faction_resources["F1"] = {"food": 60.0, "gold": 60.0}
	var t_starved := AiBuildRes._tower_count(c)
	var w_starved := AiBuildRes._wall_count(c)
	AiBuildRes._try_tower_then_walls(c)
	eq(AiBuildRes._tower_count(c), t_starved, "★ 钱不够塔时这一 tick 不造塔")
	eq(AiBuildRes._wall_count(c), w_starved,
		"★★ 钱不够塔时也不拿这笔钱去造墙，先攒塔")
	# 把地图改成「一块中立 + 其余全归 F1」，制造明确的前线 / 后方。
	var neutral = w.zone_by_id(0)
	if neutral == null:
		ok(false, "（前提）0 号区划")
		return
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY:
			(z as Dictionary)["owner"] = "F1"
	(neutral as Dictionary)["owner"] = ""
	var front = null
	var rear = null
	var nid := int((neutral as Dictionary).get("id", -1))
	for z2 in w.zones.zones:
		if typeof(z2) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z2
		if int(zd.get("id", -1)) == nid or zd.get("center", null) == null:
			continue
		if _zone_touches_zone(zd, neutral, w):
			if front == null:
				front = zd
		elif rear == null:
			rear = zd
	if front == null or rear == null:
		ok(false, "（前提）能找到前线 / 后方各一块己方区划")
		return
	c.profile["build"]["tower_front_towers"] = 1
	c.profile["build"]["tower_rear_towers"] = 3
	c.profile["build"]["tower_threat_towers"] = 1
	var picked = AiBuildRes._pick_tower_zone(c)
	ok(picked != null and _zone_is_front(c, picked),
		"★★ 前线有塔缺口时，后方塔目标再大也先造前线")


func _zone_touches_zone(zone: Dictionary, other: Dictionary, w) -> bool:
	var oid := int(other.get("id", -1))
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			var oz = w.zones.zone_at(n.x, n.y)
			if oz != null and int((oz as Dictionary).get("id", -1)) == oid:
				return true
	return false


func _zone_is_front(c, zone: Dictionary) -> bool:
	return AiBuildRes._zone_is_frontier(c, zone)


## ★★ 2026.10.25：资源顺序 部队发展 > 升本 > 建造建筑。
func _test_base_build_priority(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "升本优先级测试世界")
		return
	var c = w.ai_commanders["F1"]
	var b = w.find_base_of("F1")
	if b == null:
		ok(false, "（前提）有基地")
		return
	# 1) 钱够：先升大本营，这一 tick 不造塔 / 墙。
	ok(AiBuildRes._base_upgrade_candidate(c).is_empty(),
		"★★ 将领不足 2 时 AI 不把升二本当作候选")
	_ensure_ai_generals(w, "F1", 2)
	ok(not AiBuildRes._base_upgrade_candidate(c).is_empty(),
		"★★ 2 将后 AI 才把升二本当作候选")
	w.ai_faction_resources["F1"] = {"food": 6000.0, "gold": 6000.0}
	var towers0 := AiBuildRes._tower_count(c)
	var walls0 := AiBuildRes._wall_count(c)
	AiBuildRes.update(c)
	ok(bool(b.is_upgrading()), "★★ 资源够时第一优先级是升大本营")
	eq(AiBuildRes._tower_count(c), towers0, "★★ 升本开始的同一 tick 不造塔")
	eq(AiBuildRes._wall_count(c), walls0, "★★ 升本开始的同一 tick 不造墙")
	# 2) 钱不够：攒钱等升本，不把余钱花到建筑上。
	var w2 = _make_ai_test_world(cfg)
	if w2 == null:
		ok(false, "升本攒钱测试世界")
		return
	var c2 = w2.ai_commanders["F1"]
	var b2 = w2.find_base_of("F1")
	_ensure_ai_generals(w2, "F1", 3)
	w2.ai_faction_resources["F1"] = {"food": 10.0, "gold": 10.0}
	var towers1 := AiBuildRes._tower_count(c2)
	var walls1 := AiBuildRes._wall_count(c2)
	AiBuildRes.update(c2)
	ok(not bool(b2.is_upgrading()), "（前提）钱不够时没升成")
	eq(AiBuildRes._tower_count(c2), towers1, "★★ 攒升本钱时不造塔")
	eq(AiBuildRes._wall_count(c2), walls1, "★★ 攒升本钱时不造墙")


## ★★ 没有满编外勤队时，1 人外勤队也能被派去占「无守军无主区划」，不原地闲置。
func _test_bootstrap_capture(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "小队伍占空区测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var base = w.find_base_of("F1")
	if base == null:
		ok(false, "（前提）有基地")
		return
	var g = w.create_general("F1", 2, 200)
	if g == null:
		ok(false, "（前提）能造外勤将领")
		return
	w.units.append(g)
	g.pos = Vector2(float(base.tx) + 2.5, float(base.ty) + 0.5)
	g.sync_tile(w.map)
	ok(AiArmyRes.team_total(c, g) == 1, "（前提）外勤队只有 1 人")
	c.target_zone = -1
	c.expand_team_ids.clear()
	c.next_target_at = 0.0
	var boot: Variant = AiArmyRes._pick_bootstrap_team(c)
	ok(boot != null and String((boot["leader"] as Object).id) == String(g.id),
		"★★ 没有满编外勤队时，小队伍能当占空区候选")
	# 直接走一次扩张：目标必须是无主且无守军，才会用 bootstrap。
	var z0 = w.zone_by_id(0)
	if z0 != null:
		(z0 as Dictionary)["owner"] = ""
	AiArmyRes._expand(c, false)
	ok(c.expand_team_ids.has(String(g.id)),
		"★★ 1 人外勤队会被派去占无主 / 无守军区划，而不是闲置")


## ★★ 2026.10.25：敌方进入中心 3×3 占领区时，AI 不在该区划造塔 / 不选它。
func _test_capture_build_block(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "占领封锁测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.ai_faction_resources["F1"] = {"food": 6000.0, "gold": 6000.0}
	var zd = null
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY \
				and String((z as Dictionary).get("owner", "")) == "F1" \
				and (z as Dictionary).get("center", null) != null:
			zd = z
			break
	if zd == null:
		ok(false, "（前提）有己方区划")
		return
	var zid := int((zd as Dictionary).get("id", -1))
	var ct: Vector2i = (zd as Dictionary)["center"]
	var foe = w.spawn_enemy(ct.x, ct.y)
	ok(foe != null, "（前提）能刷出进入占领区的敌人")
	ok(AiBuildRes._zone_capture_blocked(c, zd),
		"★★ AI 能识别「敌方踩在中心 3×3」的区划")
	var picked = AiBuildRes._pick_tower_zone(c)
	ok(picked == null or int((picked as Dictionary).get("id", -1)) != zid,
		"★★ AI 不会把被踩占领区的区划选为造塔目标")
	var before := AiBuildRes._tower_count(c)
	AiBuildRes._try_tower(c)
	var built_here := false
	for b in w.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == "F1" \
				and int(b.zone_id) == zid:
			built_here = true
	ok(not built_here, "★★ 被占领中的区划内不会新增箭塔")
	# 敌人移出中心 3×3：封锁解除。
	foe.pos = Vector2(float(ct.x) + 20.0, float(ct.y) + 20.0)
	foe.sync_tile(w.map)
	ok(not AiBuildRes._zone_capture_blocked(c, zd),
		"★★ 敌人离开中心 3×3 后 AI 解除建造封锁")
	ok(AiBuildRes._tower_count(c) >= before, "（前提）塔数不变或之后可继续造")


## ★★ 2026.10.25：缺编队去己方前线中心 / 隘口驻守；光杆不出门；驻守不会被
## `_regroup` 每秒叫停。缺编队不参与侦察。
func _test_idle_defensive_posts(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "缺编驻守测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var z0 = w.zone_by_id(0)
	if z0 == null or (z0 as Dictionary).get("center", null) == null:
		ok(false, "（前提）0 号区划有中心")
		return
	(z0 as Dictionary)["owner"] = "F1"
	var ct: Vector2i = (z0 as Dictionary)["center"]
	var g = w.create_general("F1", 1, 71)
	if g == null:
		ok(false, "（前提）能造缺编将领")
		return
	g.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	ok(AiArmyRes.team_total(c, g) < int(c.profile.get("expand", {}).get("min_field_units", 3)),
		"（前提）这是缺编队")
	AiArmyRes._assign_defensive_posts(c)
	ok(not c.post_missions.has(String(g.id)), "★★ 光杆将领不单独去驻守")
	w.fill_general_retinue(g, 1, [{"type": "spearman", "weight": 1}])
	ok(AiArmyRes.team_total(c, g) == 2, "（前提）补到 2 人，仍然缺编")
	AiArmyRes._assign_defensive_posts(c)
	ok(c.post_missions.has(String(g.id)),
		"★★ 有 1 个兵的缺编队会被派去己方前线中心 / 隘口驻守")
	if c.post_missions.has(String(g.id)):
		var m: Dictionary = c.post_missions[String(g.id)]
		var zid := int(m.get("zone", -1))
		var pz = w.zone_by_id(zid)
		ok(pz != null and String((pz as Dictionary).get("owner", "")) == "F1",
			"★★ 驻守点仍在自己的区划里")
		var before_post := m.duplicate()
		AiArmyRes._regroup(c)
		ok(c.post_missions.has(String(g.id)),
			"★★ 有效驻守任务不会被 _regroup 每秒叫停")
		ok(String(c.post_missions[String(g.id)].get("kind", "")) != "",
			"（前提）驻守任务带类型（center / choke）")
		eq(String(c.post_missions[String(g.id)].get("kind", "")),
			String(before_post.get("kind", "")), "驻守任务在检查中保持不变")
	ok(not c.scout_missions.has(String(g.id)), "★ 缺编队不参与侦察")
	ok(int(c.stats.get("guards", 0)) >= 1, "★ 驻守计入统计")


## ★★ 2026.10.25：满编队去边界外侧侦察；空区划顺手占领；领地翻过来后任务结束。
func _test_idle_scouting(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "闲置侦察测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var z0 = w.zone_by_id(0)
	if z0 == null or (z0 as Dictionary).get("center", null) == null:
		ok(false, "（前提）0 号区划有中心")
		return
	(z0 as Dictionary)["owner"] = "F1"
	var ct: Vector2i = (z0 as Dictionary)["center"]
	var g = w.create_general("F1", 1, 72)
	if g == null:
		ok(false, "（前提）能造侦察将领")
		return
	g.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	w.fill_general_retinue(g, 2, [{"type": "rider", "weight": 1}])
	ok(AiArmyRes.team_total(c, g) >= int(c.profile.get("expand", {}).get("min_field_units", 3)),
		"（前提）侦察队是满编队")
	c.target_zone = -1
	AiArmyRes._scout_tick(c)
	ok(c.scout_missions.has(String(g.id)),
		"★★ 满编队会被派去边界外侧侦察 / 占空区划")
	ok(int(c.stats.get("scouts", 0)) >= 1, "★ 侦察计入统计")
	var target_zone := -1
	if c.scout_missions.has(String(g.id)):
		var m: Dictionary = c.scout_missions[String(g.id)]
		target_zone = int(m.get("zone", -1))
		var z = w.zone_by_id(target_zone)
		ok(z != null, "★ 侦察目标是有中心的区划")
		if z != null:
			ok(String((z as Dictionary).get("owner", "")) != "F1",
				"★★ 侦察目标是敌方 / 中立区划，不是自家")
			if bool(m.get("capture", false)):
				var c2: Vector2i = (z as Dictionary)["center"]
				var want := GridRes.center_of(c2)
				var got: Vector2 = m.get("pt", Vector2.ZERO)
				ok(got.distance_to(want) <= 1.0,
					"★★ 空区划侦察会直接去中心读条")
	# 领地翻过来后：这一条侦察任务必须结束 / 换目标。
	if target_zone >= 0:
		var z2 = w.zone_by_id(target_zone)
		if z2 != null:
			(z2 as Dictionary)["owner"] = "F1"
		AiArmyRes._scout_tick(c)
		var still_same: bool = c.scout_missions.has(String(g.id)) \
			and int((c.scout_missions[String(g.id)] as Dictionary).get("zone", -1)) == target_zone
		ok(not still_same, "★★ 目标区划归己方后不再继续侦察同一点")
	# 缺编队不会被派侦察。
	var weak = w.create_general("F1", 2, 73)
	if weak != null:
		weak.pos = Vector2(float(ct.x) + 2.5, float(ct.y) + 0.5)
		weak.sync_tile(w.map)
		w.units.append(weak)
		AiArmyRes._scout_tick(c)
		ok(not c.scout_missions.has(String(weak.id)), "★ 缺编队不会被派去侦察")


## ★★ 2026.10.25：没有安全侦察目标时，满编队别在后方站着，去前线中心 / 隘口
## 当哨兵；侦察名额 / 扩张任务优先，守备任务不抢它们。
func _test_idle_ready_guards(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "满编守备测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var z0 = w.zone_by_id(0)
	if z0 == null or (z0 as Dictionary).get("center", null) == null:
		ok(false, "（前提）0 号区划有中心")
		return
	(z0 as Dictionary)["owner"] = "F1"
	var ct: Vector2i = (z0 as Dictionary)["center"]
	var g = w.create_general("F1", 1, 74)
	if g == null:
		ok(false, "（前提）能造守备将领")
		return
	g.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	w.fill_general_retinue(g, 2, [{"type": "spearman", "weight": 1}])
	ok(AiArmyRes.team_total(c, g) >= int(c.profile.get("expand", {}).get("min_field_units", 3)),
		"（前提）这是满编队")
	AiArmyRes._assign_ready_guards(c)
	ok(c.guard_missions.has(String(g.id)),
		"★★ 没有侦察 / 扩张任务的满编队会去前线中心 / 隘口守备")
	if c.guard_missions.has(String(g.id)):
		var m: Dictionary = c.guard_missions[String(g.id)]
		var zid := int(m.get("zone", -1))
		var z = w.zone_by_id(zid)
		ok(z != null and String((z as Dictionary).get("owner", "")) == "F1",
			"★★ 守备点在自己的区划里")
		ok(not c.post_missions.has(String(g.id)),
			"★ 满编队走 guard_missions，不占缺编驻守名额")
	# 缺编调度不能误删满编守备任务。
	AiArmyRes._assign_defensive_posts(c)
	ok(c.guard_missions.has(String(g.id)),
		"★ 缺编调度不会误删满编守备任务")
	# 撤退时守备任务要立刻解除，避免回家路上又被拉回哨位。
	AiArmyRes._retreat_team(c, g)
	ok(not c.guard_missions.has(String(g.id)), "★ 整队撤退时守备任务解除")


## ★★ 2026.10.25：区划布防 —— 闲置满编队要铺到多个暴露区划，一区一队，不挤大本营。
func _test_zone_guards(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "区划布防测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var base = w.find_base_of("F1")
	if base == null:
		ok(false, "（前提）大本营")
		return
	# 全图归 F1，再把两块改成中立，制造多个「可能被偷袭」的边境区划。
	for z in w.zones.zones:
		if typeof(z) == TYPE_DICTIONARY:
			(z as Dictionary)["owner"] = "F1"
	for zid in [0, 6]:
		var zz = w.zone_by_id(zid)
		if zz != null:
			(zz as Dictionary)["owner"] = ""
	var bz: Vector2i = Vector2i(int(base.tx), int(base.ty))
	var center := Vector2(float(bz.x) + 0.5, float(bz.y) + 0.5)
	var made := 0
	for i in 3:
		var g = w.create_general("F1", 1, 80 + i)
		if g == null:
			continue
		g.pos = center
		g.sync_tile(w.map)
		w.units.append(g)
		w.fill_general_retinue(g, 5, [{"type": "spearman", "weight": 1}])
		made += 1
	if made < 2:
		ok(false, "（前提）能造至少 2 支闲置满编队")
		return
	c.post_missions.clear()
	c.scout_missions.clear()
	c.guard_missions.clear()
	c.regroup_ids.clear()
	AiArmyRes._assign_zone_guards(c)
	var zones: Dictionary = {}
	for lid in c.guard_missions.keys():
		var m: Dictionary = c.guard_missions[lid]
		if String(m.get("kind", "")) != "zone":
			continue
		var zid := int(m.get("zone", -1))
		zones[zid] = true
		var zd = w.zone_by_id(zid)
		ok(zd != null and String((zd as Dictionary).get("owner", "")) == "F1",
			"★★ 区划布防点在自己的区划里")
	ok(zones.size() >= 2,
		"★★ 闲置满编队被铺到多个暴露区划，而不是全挤在大本营 / 中场（%d 个）" % zones.size())
	ok(not zones.has(int(base.zone_id)),
		"★ 大本营区划由守军负责，不占区划布防名额")
	ok(int(c.stats.get("zone_guards", 0)) >= 2, "★ 区划布防计入统计")


## ★★ 2026.10.25：缺兵且不在己方人口区 / 在野外的队伍，会被叫回人口区补员。
func _test_recruit_recall(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "补员回撤测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var z0 = w.zone_by_id(0)
	if z0 == null or (z0 as Dictionary).get("center", null) == null:
		ok(false, "（前提）0 号区划有中心")
		return
	var ct: Vector2i = (z0 as Dictionary)["center"]
	# 0 号区划保持中立：将领站在这里就是「不在己方区划」，下不了招募单。
	var g = w.create_general("F1", 1, 75)
	if g == null:
		ok(false, "（前提）能造缺兵将领")
		return
	g.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
	g.sync_tile(w.map)
	w.units.append(g)
	w.fill_general_retinue(g, 2, [{"type": "spearman", "weight": 1}])
	ok(AiArmyRes.team_total(c, g) < int(c.profile.get("production", {}).get("field_team_size", 6)),
		"（前提）还没补到外勤队目标规模")
	c.regroup_ids.clear()
	AiArmyRes._recall_understrength_for_recruit(c)
	ok(c.regroup_ids.has(String(g.id)),
		"★★ 在野外 / 无人口区的缺兵队会被叫回己方人口区补员")
	ok(int(c.stats.get("recruit_recalls", 0)) >= 1, "★ 补员回撤计入统计")
	# 已经在己方人口区里的缺兵队不折腾。
	var z1 = w.zone_by_id(1)
	if z1 != null and (z1 as Dictionary).get("center", null) != null:
		(z1 as Dictionary)["population"] = 5.0
		var ct1: Vector2i = (z1 as Dictionary)["center"]
		var g2 = w.create_general("F1", 2, 76)
		if g2 != null:
			g2.pos = Vector2(float(ct1.x) + 0.5, float(ct1.y) + 0.5)
			g2.sync_tile(w.map)
			w.units.append(g2)
			w.fill_general_retinue(g2, 2, [{"type": "spearman", "weight": 1}])
			c.regroup_ids.clear()
			AiArmyRes._recall_understrength_for_recruit(c)
			ok(not c.regroup_ids.has(String(g2.id)),
				"★ 已经在己方人口区的缺兵队不会被叫走")


## ★★ 2026.10.25：现有队伍没补到「目标 - margin」时，不招新将领。
func _test_general_staffing(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "补将门槛测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	w.ai_faction_resources["F1"] = {"food": 5000.0, "gold": 5000.0}
	ok(AiArmyRes.understaffed_team_count(c) > 0,
		"（前提）开局将领还没补到接近目标规模")
	var before: int = w.general_count_of("F1")
	c.retry_timer = 0.0
	c._production_tick()
	eq(w.general_count_of("F1"), before,
		"★★ 现有队伍只有 3 人（目标 6）时，不急着招新光杆将领")
	# 把守军补到 6 人（守军目标 8 - margin 2）后，门槛应放行。
	var home = AiArmyRes.ensure_garrison(c)
	if home != null:
		w.fill_general_retinue(home, 3, [{"type": "spearman", "weight": 1}])
		ok(AiArmyRes.understaffed_team_count(c) <= 0,
			"★ 补到「目标 - 2」后，补将门槛放行")
	else:
		ok(false, "（前提）能找到守军将领")


## ★★ 2026.10.25：开局唯一一支初始部队要出去探索，而不是绕基地转圈。
func _test_early_explore(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "开局探索测试世界")
		return
	var c = w.ai_commanders["F1"]
	c.explore_leader_id = ""
	c.explore_phase = ""
	c.explore_target = Vector2.ZERO
	c.explore_until = 0.0
	c.explore_away = false
	var base = w.find_base_of("F1")
	var g = AiArmyRes._first_alive_general(c)
	if base == null or g == null:
		ok(false, "（前提）有基地和初始将领")
		return
	ok(int(w.general_count_of("F1")) == 1, "（前提）开局只有一支初始部队")
	if AiArmyRes.team_escorts(c, g) < 2:
		w.fill_general_retinue(g, 2, [{"type": "spearman", "weight": 1}])
	var base_pt := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	var before := int(c.stats.get("explores", 0))
	var handled: bool = AiArmyRes._early_explore_tick(c)
	ok(handled and String(c.explore_phase) == "out",
		"★★ 开局初始部队会出门探索，而不是在基地转圈")
	eq(String(c.explore_leader_id), String(g.id), "★★ 探索队就是初始将领")
	ok(bool(g.moving) and not bool(g.has_attack_move),
		"★★ 探索用普通移动，不主动行军攻击")
	ok(g.pos.distance_to(c.explore_target) >= 6.0,
		"★★ 探索目标在基地外，不是原地左左右右")
	ok(int(c.stats.get("explores", 0)) > before, "★ 探索计入统计")
	# 刚下命令时队伍还在基地附近，不能立刻判定「已经回来了」。
	AiArmyRes._early_explore_tick(c)
	eq(String(c.explore_phase), "out", "★★ 刚出门不会因为还在基地附近就取消")
	# ★★ 到达一个探索点后继续去下一个远处点，不要立刻回基地 → 再出门。
	var first_target: Vector2 = c.explore_target
	g.pos = first_target
	g.sync_tile(w.map)
	c.explore_until = w.time + 100.0
	AiArmyRes._early_explore_tick(c)
	eq(String(c.explore_phase), "out", "★★ 到达探索点后继续探索，不立刻回基地")
	ok(c.explore_target.distance_to(first_target) > 4.0,
		"★★ 下一个探索点在别处，不会原地绕圈")
	# 超时 → 回基地；回基地也是普通移动。
	c.explore_until = w.time - 0.1
	AiArmyRes._early_explore_tick(c)
	eq(String(c.explore_phase), "home", "★★ 探索超时会回基地")
	ok(bool(g.moving) and not bool(g.has_attack_move),
		"★★ 回基地也是普通移动，不一路打回去")
	# 到基地 → 休整补员。
	g.pos = base_pt
	g.sync_tile(w.map)
	c.explore_until = w.time - 0.1
	AiArmyRes._early_explore_tick(c)
	eq(String(c.explore_phase), "rest", "★★ 回到基地后进入休整 / 补员")
	# 休整结束 → 下一次再出门。
	c.explore_until = w.time - 0.1
	AiArmyRes._early_explore_tick(c)
	eq(String(c.explore_phase), "", "★ 休整结束")
	var handled2: bool = AiArmyRes._early_explore_tick(c)
	ok(handled2 and String(c.explore_phase) == "out",
		"★★ 休整后会再次出门探索")


## ★★ 2026.10.25：开局 60 秒允许小队伍出门；之后恢复「少于 3 人不出门」。
func _test_early_game(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "开局扩张期测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.time = 0.0
	ok(AiArmyRes.is_early_game(c), "（前提）开局在扩张期内")
	eq(AiArmyRes._min_units(c), 1, "★★ 开局允许 1 人队出门")
	eq(AiArmyRes._squad_units(c), 1, "★★ 开局 1 人也能去占无守军区划")
	var base = w.find_base_of("F1")
	var g0 = AiArmyRes._first_alive_general(c)
	if base != null and g0 != null:
		g0.pos = Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5)
		g0.sync_tile(w.map)
	ok(AiArmyRes.ensure_garrison(c) == null,
		"★★ 开局 60 秒不强制大本营区划留一支守军")
	var g = w.create_general("F1", 1, 90)
	if g == null:
		ok(false, "（前提）能造开局小队伍")
		return
	w.units.append(g)
	g.pos = Vector2(3.5, 3.5)
	g.sync_tile(w.map)
	ok(AiArmyRes.team_total(c, g) == 1, "（前提）这是 1 人队")
	var pt := Vector2(5.5, 5.5)
	var picked = AiArmyRes._pick_mission_teams(c, pt, 1, false)
	var found := false
	for t in picked:
		if String((t["leader"] as Object).id) == String(g.id):
			found = true
	ok(found, "★★ 开局 1 人队也能被选去向外占区划")
	# 60 秒后恢复常规。
	w.time = 61.0
	ok(not AiArmyRes.is_early_game(c), "★★ 60 秒后退出开局扩张期")
	ok(AiArmyRes.ensure_garrison(c) != null,
		"★★ 60 秒后恢复「大本营区划有守军」")

	eq(AiArmyRes._min_units(c), 3, "★★ 60 秒后恢复「少于 3 人不出门」")
	eq(AiArmyRes._squad_units(c), 3, "★★ 60 秒后恢复常规占区规模")
	var picked2 = AiArmyRes._pick_mission_teams(c, pt, 1, false)
	var found2 := false
	for t in picked2:
		if String((t["leader"] as Object).id) == String(g.id):
			found2 = true
	ok(not found2, "★★ 60 秒后 1 人队不再被派出去")
	# 开局探索也在 60 秒停止。
	c.explore_leader_id = ""
	c.explore_phase = ""
	c.explore_target = Vector2.ZERO
	c.explore_until = 0.0
	c.explore_away = false
	ok(not AiArmyRes._early_explore_tick(c), "★★ 60 秒后不再启动开局探索")


## ★★ 招将：优先前线 / 被入侵区划，基地只是兜底。
func _test_front_general_recruit(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "招将测试世界")
		return
	var c = w.ai_commanders["F1"]
	w.time = 61.0
	var z1 = w.zone_by_id(1)
	if z1 == null:
		ok(false, "（前提）1 号区划")
		return
	(z1 as Dictionary)["owner"] = "F1"
	(z1 as Dictionary)["capture_state"] = "reading"
	(z1 as Dictionary)["capture_faction"] = "p2"
	(z1 as Dictionary)["capture_value"] = 0.5
	var order: Array = c._general_recruit_zones()
	ok(not order.is_empty() and int(order[0]) == 1,
		"★★ 被入侵的前线区划排在招将顺序第一（实际 %s）" % str(order))
	# 前线刚招出来、还没形成编制的将领：遇敌先整队后撤。
	var g = w.create_general("F1", 1, 50)
	if g != null:
		w.units.append(g)
		var ct: Vector2i = (z1 as Dictionary)["center"]
		g.pos = Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5)
		g.sync_tile(w.map)
		w.spawn_enemy(ct.x + 1, ct.y + 1)
		var before := int(c.stats.get("role_retreats", 0))
		AiArmyRes._avoid_bad_fights(c)
		ok(int(c.stats.get("role_retreats", 0)) > before,
			"★★ 前线未成形部队遇敌会整队后撤")


func _test_team_production_targets(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "按队补员测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var home = AiArmyRes.ensure_garrison(c)
	if home == null:
		ok(false, "（前提）ai_test 有守军")
		return
	var pc: Dictionary = c.profile.get("production", {})
	var home_target := int(pc.get("home_team_size", 6))
	var field_target := int(pc.get("field_team_size", 4))
	ok(AiArmyRes.team_projected(c, home) < home_target, "（前提）守军还没补满")
	ok(AiArmyRes.team_projected(c, home) <= home_target,
		"★ 守军最多补到 home_team_size（%d）" % home_target)
	# 外勤队不应该按守军规模补：把它的 projected 拉到 field_target 后就该没有缺口。
	var rep = w.create_general("F1", 1, 4)
	if rep != null:
		var base = w.find_base_of("F1")
		rep.pos = Vector2(float(base.tx) - 1.5, float(base.ty) + 1.5)
		rep.sync_tile(w.map)
		w.units.append(rep)
		w.fill_general_retinue(rep, field_target - 1, [{"type": "spearman", "weight": 1}])
		var cands: Array = AiArmyRes.recruit_candidates(c)
		var found := false
		for cand in cands:
			if (cand as Dictionary).get("leader", null) == rep:
				found = true
		ok(not found, "★ 外勤队补到 field_team_size（%d）后不再进补员候选" % field_target)


func _test_march_moves_army(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "行军测试世界")
		return
	var c = w.ai_commanders["F2"]
	var target := Vector2(10.5, 10.5)
	var before := _nearest_unit_distance(w, "F2", target)
	eq(w.set_ai_directive("F2", "march", target.x, target.y, "F1"), "", "行军指令接受")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "march", "世界指令是 march")
	for i in 120:
		w.tick(0.1)
	var after := _nearest_unit_distance(w, "F2", target)
	ok(int(c.stats.get("orders", 0)) >= 1, "AI 至少发出一条行军命令")
	ok(after < before, "部队离目标更近了（%f -> %f）" % [before, after])


func _test_march_early_end(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "行军主动结束测试世界")
		return
	var c = w.ai_commanders["F2"]
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "F2" and u.is_general() and not u.is_downed():
			g = u
			break
	ok(g != null, "（前提）F2 有开局将领")
	if g == null:
		return
	var pt: Vector2 = g.pos
	# 单元判据：全部到点 + 目标点清场 → 可以结束。
	ok(AiArmyRes._march_reached_clear(c, pt, AiArmyRes.leader_teams(c)),
		"★ 全部到点且清场 → 可以结束")
	# 目标点附近有可见敌人 → 不结束。
	var fx := clampi(int(floor(pt.x)) + 2, 0, w.map.cols - 1)
	var fy := clampi(int(floor(pt.y)), 0, w.map.rows - 1)
	var foe = UnitRes.create(cfg, "foe-march-clear", "敌将",
		Vector2i(fx, fy), "enemy", "general")
	ok(foe != null, "能造一个测试敌将")
	if foe != null:
		foe.hp_max = 100000.0
		foe.base_hp_max = 100000.0
		foe.hp = 100000.0
		w.units.append(foe)
		w.fog.update(w)
		if w.fog.unit_visible("F2", foe):
			ok(not AiArmyRes._march_reached_clear(c, pt, AiArmyRes.leader_teams(c)),
				"★★ 目标点周围有可见敌人 → 不结束")
		else:
			ok(true, "（跳过）敌将不在 F2 视野内，无法验证敌人分支")
		foe.alive = false
		w.units.erase(foe)
	# 集成：向 F2 大本营中心下令 march（开局三将都在 3 格内），army tick 后应自动结束。
	var base = w.find_base_of("F2")
	ok(base != null, "（前提）F2 有基地")
	if base == null:
		return
	eq(w.set_ai_directive("F2", "march", float(base.tx) + 0.5, float(base.ty) + 0.5, "F1"),
		"", "行军指令接受")
	var serial0 := int(w.ai_directive_of("F2").get("serial", 0))
	for i in 10:
		w.tick(0.1)
	eq(String(w.ai_directive_of("F2").get("kind", "")), "auto",
		"★★ 到点且清场后行军提前结束（不用等 60 秒）")
	ok(int(w.ai_directive_of("F2").get("serial", 0)) > serial0, "结束也会 bump serial")
	near(float(w.ai_panel_state("F2").get("hold_left", -1.0)), 0.0, 1e-4,
		"结束后没有保留倒计时")
	# 反向：远处目标在没到点前不会提前结束。
	eq(w.set_ai_directive("F2", "march", 1.5, 1.5, "F1"), "", "远处行军接受")
	for i in 20:
		w.tick(0.1)
	eq(String(w.ai_directive_of("F2").get("kind", "")), "march", "★★ 没到点不会提前结束")
	# 手动结束：进行中 true，auto 再结束 false。
	ok(w.end_ai_directive("F2", ""), "end_ai_directive 能结束进行中的指令")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "auto", "结束后回到 auto")
	ok(not w.end_ai_directive("F2", ""), "auto 状态再结束返回 false")


func _test_expand_target(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "扩张测试世界")
		return
	var c = w.ai_commanders["F1"]
	eq(w.set_ai_directive("F1", "expand", -1.0, -1.0, "F1"), "", "扩张指令接受")
	for i in 80:
		w.tick(0.1)
	ok(int(c.target_zone) >= 0 or int(c.stats.get("expands", 0)) >= 1,
		"★ AI 找到扩张目标并派出队伍")
	if int(c.target_zone) >= 0:
		var z = w.zone_by_id(int(c.target_zone))
		ok(z != null and (z as Dictionary).get("center", null) != null,
			"★ 扩张目标是有区划中心的地块")
		ok(int(c.expand_team_ids.size()) >= 1, "★ 至少有一支队伍被派往该中心")


## ★★ 自主模式真的会占领区划（本轮需求 #1 的核心断言）。
func _test_auto_captures_zones(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "自主扩张测试世界")
		return
	var c = w.ai_commanders["F1"]
	var owned0 := _owned_zone_count(w, "F1")
	# ai_test 的 1 号区划是开局领地；其余 6 块是可扩张目标。
	var captured := -1
	var elapsed := 0.0
	while elapsed < 180.0:
		w.tick(0.1)
		elapsed += 0.1
		var owned := _owned_zone_count(w, "F1")
		if owned > owned0:
			captured = owned
			break
	ok(captured > owned0,
		"★★ 自主模式在 180 秒内占下了新地块（%d → %d）" % [owned0, maxi(owned0, captured)])
	ok(int(c.stats.get("expands", 0)) >= 1, "★ 至少发起过一次扩张任务")
	# 归属统计每 2 秒对一次账：多跑一个战略周期再断言。
	for _i in 22:
		w.tick(0.1)
	ok(int(c.stats.get("zones_taken", 0)) >= 1, "★ 扩张完成时计入 zones_taken")


## ★★ 光杆司令不出门：任何被下达行军命令的将领都至少带着 min_field_units-1 个兵。
func _test_no_lone_wanderers(cfg) -> void:
	var w = _make_ai_test_world(cfg)
	if w == null:
		ok(false, "光杆司令测试世界")
		return
	w.time = 61.0
	var c = w.ai_commanders["F1"]
	var ec: Dictionary = c.profile.get("expand", {})
	var min_units := int(ec.get("min_field_units", 3))
	var violations := 0
	var max_team := 0
	for i in 900:
		w.tick(0.1)
		for t in AiArmyRes.leader_teams(c):
			var leader = t["leader"]
			max_team = maxi(max_team, int(t["size"]))
			if not leader.has_attack_move:
				continue
			if c.regroup_ids.has(String(leader.id)):
				continue                 # 兵力不足但正在回撤整备：这不是「出去浪」
			if c.post_missions.has(String(leader.id)):
				continue                 # 缺编队去己方前线中心 / 隘口驻守：防守性移动
			# 2026.10.25：没有满编外勤队时，允许小队伍去占「无守军无主区划」。
			if c.expand_team_ids.has(String(leader.id)):
				continue
			if AiArmyRes.team_total(c, leader) < min_units:
				violations += 1
	ok(violations == 0,
		"★★ 没有任何「只有将领 / 兵力不足」的队伍被派出去（违规帧 %d）" % violations)
	var home_target := int(c.profile.get("production", {}).get("home_team_size", 6))
	ok(max_team <= home_target + 2,
		"★ 单支队伍没有被招成巨型部队（最大 %d 人）" % max_team)


func _test_panel_state(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "面板状态测试世界")
		return
	var st: Dictionary = w.ai_panel_state("F2")
	eq(String(st.get("kind", "")), "commander", "面板状态 kind")
	ok(st.has("army") and st.has("army_cap"), "面板有军队数量")
	ok(st.has("food") and st.has("gold"), "面板有资源")
	ok(String(st.get("directive", "")) != "", "面板有当前指令")
	ok(typeof(st.get("target")) == TYPE_VECTOR2I, "面板目标点是 Vector2i")


func _test_snapshot(cfg) -> void:
	var w = _make_world(cfg)
	if w == null:
		ok(false, "快照测试世界")
		return
	w.set_ai_directive("F2", "march", 11.0, 9.0, "F1")
	var snap: Dictionary = SnapshotRes.to_snapshot(w)
	ok(snap.has("aid"), "快照带 aid")
	ok(snap.has("air"), "快照带 air")
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	var guest = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], false)
	SnapshotRes.apply_snapshot(guest, cfg, snap)
	eq(String(guest.ai_directive_of("F2").get("kind", "")), "march", "客机读回 march")
	var gp: Variant = guest.ai_faction_resources.get("F2", null)
	ok(typeof(gp) == TYPE_DICTIONARY and float((gp as Dictionary).get("food", -1.0)) >= 0.0,
		"客机读回 AI 资源")
	ok(guest.ai_commanders.is_empty(), "客机不创建 AI 控制器")


func _test_determinism(cfg) -> void:
	var a = _make_world(cfg, 4242)
	var b = _make_world(cfg, 4242)
	if a == null or b == null:
		ok(false, "确定性测试世界")
		return
	for i in 150:
		a.tick(0.1)
		b.tick(0.1)
	var da: Dictionary = a.ai_commanders["F2"].debug_state()
	var db: Dictionary = b.ai_commanders["F2"].debug_state()
	var sa: Dictionary = da.get("stats", {})
	var sb: Dictionary = db.get("stats", {})
	eq(int(da["army"]), int(db["army"]), "同种子：军队数量一致")
	eq(String(da["order"]), String(db["order"]), "同种子：指令一致")
	eq(int(da["target_zone"]), int(db["target_zone"]), "同种子：扩张目标一致")
	eq(int(sa.get("recruits", 0)), int(sb.get("recruits", 0)), "同种子：招募数一致")
	eq(int(sa.get("orders", 0)), int(sb.get("orders", 0)), "同种子：命令数一致")


func _clear_react_locks(c) -> void:
	c.react_next.clear()
	c.react_mode.clear()
	c.react_point.clear()
	c.react_until.clear()


func _nearest_unit_distance(w, faction: String, pt: Vector2) -> float:
	var best := INF
	for u in w.units:
		if not u.alive or String(u.faction) != faction or u.is_downed():
			continue
		best = minf(best, u.pos.distance_to(pt))
	return best
