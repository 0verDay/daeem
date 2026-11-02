## test_clan.gd —— **派系**（clan）：原生 / 王朝 / 帝国
##
## 这一套验的是「派系」这条新玩法链路（与 `test_alliance.gd` 那种「阵营关系」不同）：
##   1. **config**：派系表能不能读出来；原生**沿用顶层 recruit.list**（不抄两份数据）；
##      王朝 7 条 / 帝国 6 条；组合条目的 spawn 形状；
##   2. **新兵种数值**：远近免伤 / 稳定（免疫击退）/ 击退 / 直线穿透 / 弹道形状，
##      以及「同素材沿用原生数值 + 叠加需求特性」那条口径的两个代表；
##   3. **关卡 → 世界**：`factions[].clan` 落到 `world.clan_of()`（see_ai 那一关
##      p1 = 王朝、p2 = 帝国），没写派系的关卡 = 原生（逐位不变）；
##   4. **招募表按派系**：`recruit_list / recruit_entry / recruit_tier / recruit_cost`
##      四个查询都认「这一方」；王朝的兵在帝国那边查不到；
##   5. **组合单位**：一次读条出 2 / 3 个兵、名字都取条目 label、人口按整包扣；
##   6. **击退 + 眩晕**：普通单位被推开 + 不能动；**稳定**单位一点不吃、照旧能被推挤；
##   7. **直线穿透子弹**：一条线上三个敌人各吃一次全额伤害，友军不受伤；
##   8. **近战减伤**：「远近免伤+」只挡自己那一类伤害。
##
## ⚠️ 断言的数值都从 config 读（`cfg.unit_*`），不在这里抄死数字 ——
##   调平衡时这套测试不该跟着改（只有「行为」变了才该红）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const UnitRes = preload("res://logic/unit.gd")
const GridRes = preload("res://logic/grid.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const ProjectileRes = preload("res://logic/projectile.gd")
const CombatRes = preload("res://logic/combat.gd")
const AiProfileRes = preload("res://logic/ai_profile.gd")

const DT := 1.0 / 60.0
## see_ai 走的那个关卡（同一张 between_moutains，双方 commander AI）。
const TEST_LEVEL := "res://data/campaigns/demo/levels/ai_test_battle.json"

func _initialize() -> void:
	_case_name = "test_clan"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config_table(cfg)
	_test_new_unit_types(cfg)
	_test_level_clan(cfg)
	_test_world_clans(cfg)
	_test_rosters(cfg)
	_test_composite_recruit(cfg)
	_test_knockback_and_stun(cfg)
	_test_pierce(cfg)
	_test_melee_reduction(cfg)
	_test_arc_flag(cfg)
	_test_ai_uses_own_clan(cfg)
	_test_clan_ai_profile(cfg)
	_test_clan_profiles_compilable(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1) config：派系表
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var ids: Array = cfg.clan_ids()
	ok(ids.has("native") and ids.has("dynasty") and ids.has("empire"),
		"★ 三个派系都在（%s）" % str(ids))
	eq(cfg.clan_default_id(), "native", "★ 默认派系 = 原生")
	eq(cfg.clan_name_of("dynasty"), "王朝", "王朝的显示名")
	eq(cfg.clan_name_of("empire"), "帝国", "帝国的显示名")
	eq(cfg.clan_name_of("native"), "原生", "原生的显示名")
	eq(cfg.clan_icon_of("dynasty").length(), 1, "派系图标是**一个字**")
	ok(not cfg.clan_exists("nope"), "不存在的派系 id 判 false")
	eq(cfg.clan_name_of("nope"), "nope", "未知派系 id 原样返回（界面不出空名字）")

	# ★★ 原生 = 顶层 recruit.list（**不复制**）：这样「已实装的兵种」只有一份数据。
	var native_list: Array = cfg.clan_recruit_list("native")
	var raw_list: Array = cfg.get_path_value("recruit.list")
	eq(native_list.size(), raw_list.size(), "★ 原生的招募表 = 顶层 recruit.list（条数一致）")
	eq(String((native_list[0] as Dictionary).get("kind", "")), "spearman",
		"原生的第一条仍是长枪兵")

	# ★ 王朝 / 帝国是**自己的表**，与原生不同。
	var dy: Array = cfg.clan_recruit_list("dynasty")
	var dg: Array = cfg.clan_recruit_list("empire")
	eq(dy.size(), 7, "★ 王朝有 7 条招募条目")
	eq(dg.size(), 6, "★ 帝国有 6 条招募条目")
	ok(dy != native_list, "王朝的表不是原生那张（各自独立）")

	# ★★ 组合单位：spawn 形状 + 整包人口。
	var guard: Dictionary = cfg.clan_recruit_entry("dynasty", "dy_guard")
	eq((guard.get("spawn", []) as Array).size(), 2, "★ 协防军是 2 个单位的组合条目")
	near(float(guard.get("population_cost", 0.0)), 2.0, 1e-9, "★ 协防军吃 2 人口（整包）")
	eq(int(guard.get("tier", 0)), 1, "协防军在一本（第 1 行）")
	var royal: Dictionary = cfg.clan_recruit_entry("dynasty", "dy_royal")
	eq((royal.get("spawn", []) as Array).size(), 3, "★ 御林军是 3 个单位的组合条目")
	near(float(royal.get("population_cost", 0.0)), 3.0, 1e-9, "★ 御林军吃 3 人口（整包）")

	# ★ AI 编成权重（派系自带的那一张）。
	ok(not cfg.clan_ai_composition("dynasty").is_empty(), "王朝带 AI 编成权重")
	ok(not cfg.clan_ai_composition("empire").is_empty(), "帝国带 AI 编成权重")
	ok(cfg.clan_ai_composition("native").is_empty(),
		"原生不带（退回 ai.commander.production.composition）")


# ------------------------------------------------------------------
# 2) 新兵种的数值 / 特性
# ------------------------------------------------------------------
func _test_new_unit_types(cfg) -> void:
	# 「同素材沿用原生数值」的两个代表：斥候 = 骑手数值 + 移速 / 视野。
	ok(cfg.unit_hp_of("dy_scout") < cfg.unit_hp_of(UnitRes.UNIT_TYPE_RIDER),
		"★★ 斥候比骑手血更少（2026.11：王朝改走「便宜 / 脆 / 轮换勤」，不再沿用原生血量）")
	ok(cfg.unit_speed_of("dy_scout") > cfg.unit_speed_of(UnitRes.UNIT_TYPE_RIDER),
		"★ 斥候比骑手快（移动速度+）")
	ok(cfg.unit_vision_of("dy_scout") > cfg.unit_vision_of(UnitRes.UNIT_TYPE_RIDER),
		"★ 斥候视野更大（视野范围+）")
	eq(cfg.unit_class_of("dy_scout"), ConfigRes.CLASS_CAVALRY, "斥候是骑兵")

	# 冠军骑士：骑士的护甲 / 攻击，但**血更少**、更快。
	near(cfg.unit_armor_of("dg_champion"), cfg.unit_armor_of(UnitRes.UNIT_TYPE_KNIGHT), 1e-9,
		"★ 冠军骑士沿用骑士的护甲")
	ok(cfg.unit_combat_of("dg_champion").get("damage", 0.0) >
		cfg.unit_combat_of(UnitRes.UNIT_TYPE_KNIGHT).get("damage", 0.0),
		"★★ 冠军骑士攻击高于骑士（32 > 30）")
	ok(cfg.unit_hp_of("dg_champion") < cfg.unit_hp_of(UnitRes.UNIT_TYPE_KNIGHT),
		"★★ 冠军骑士比骑士更脆（330 < 365）—— 换来更快、更锋利")
	ok(cfg.unit_speed_of("dg_champion") > cfg.unit_speed_of(UnitRes.UNIT_TYPE_KNIGHT),
		"★ 冠军骑士更快（移动速度+）")

	# 「远近免伤+」
	var royal: Dictionary = cfg.unit_traits_of("dy_royal_sword")
	near(float(royal.get("melee_reduction", 0.0)), 0.3, 1e-9,
		"★★ 御林军剑盾兵：近战减伤 30%（2026.11 数值上调：王朝改走「脆但克制狠」）")
	near(float(royal.get("ranged_reduction", 0.0)), 0.3, 1e-9,
		"★★ 御林军剑盾兵：远程减伤 30%")
	# 「稳定」
	ok(bool(royal.get("knockback_immune", false)), "★ 御林军剑盾兵：稳定（免疫击退）")
	ok(bool(cfg.unit_traits_of("dy_chariot").get("knockback_immune", false)), "战车：稳定")
	ok(bool(cfg.unit_traits_of("dg_champion").get("knockback_immune", false)),
		"冠军骑士：稳定")
	ok(not bool(cfg.unit_traits_of("dy_spear_guard").get("knockback_immune", false)),
		"协防军长枪兵：不稳定（对照组）")

	# 叠加口径：披甲剑士 = 长枪兵的骑兵特攻 + 新增的近战免伤。
	var sword: Dictionary = cfg.unit_traits_of("dg_swordsman")
	var spear: Dictionary = cfg.unit_traits_of(UnitRes.UNIT_TYPE_SPEARMAN)
	near(float((sword.get("attack_vs_class", {}) as Dictionary).get("cavalry", 0.0)),
		float((spear.get("attack_vs_class", {}) as Dictionary).get("cavalry", 0.0)), 1e-9,
		"★ 披甲剑士保留长枪兵的骑兵特攻（沿用 + 叠加）")
	near(float(sword.get("melee_reduction", 0.0)), 0.25, 1e-9, "★ 披甲剑士叠了近战免伤")
	# 「骑兵特攻+」⇒ 在原值上 +0.25。
	# ★★ 2026.11：王朝改走「更强调兵种克制」⇒ 这条特攻从「原生 + 25%」拉到 **+45%**（绝对值 0.70）。
	var sg_cav: float = float((cfg.unit_traits_of("dy_spear_guard")
		.get("attack_vs_class", {}) as Dictionary).get("cavalry", 0.0))
	near(sg_cav, float((spear.get("attack_vs_class", {}) as Dictionary).get("cavalry", 0.0)) + 0.45,
		1e-9, "★★ 协防军长枪兵的骑兵特攻 = 原生 + 45%（0.70）")

	# 击退（王朝投石车）与穿透（帝国扭力弩炮）
	var kb: Dictionary = cfg.unit_knockback_of("dy_catapult")
	ok(float(kb.get("distance", 0.0)) > 0.0, "★ 王朝投石车带击退位移")
	ok(float(kb.get("stun_sec", 0.0)) > 0.0, "★ 王朝投石车带眩晕")
	ok(float(cfg.unit_knockback_of(UnitRes.UNIT_TYPE_CATAPULT).get("distance", 0.0)) <= 0.0,
		"原生投石车**没有**击退（两条不同的兵种）")
	ok(cfg.unit_pierce("dg_bolt"), "★ 扭力弩炮是直线穿透子弹")
	ok(not cfg.unit_pierce(UnitRes.UNIT_TYPE_CATAPULT), "原生投石车不穿透（对照）")
	ok(cfg.unit_is_siege("dy_catapult"), "王朝投石车仍是攻城")
	ok(not cfg.unit_is_siege("dy_chariot"),
		"★ 战车**不是**攻城（造成近战伤害而非器械伤害）")
	eq(cfg.unit_class_of("dy_chariot"), ConfigRes.CLASS_SIEGE, "战车归器械大类")
	ok(not cfg.unit_is_ranged("dy_chariot"), "战车是近战（不走投掷物）")
	ok(cfg.unit_can_attack("dy_chariot"), "战车能攻击（不是支援单位）")


# ------------------------------------------------------------------
# 3) 关卡数据：factions[].clan
# ------------------------------------------------------------------
func _test_level_clan(cfg) -> void:
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	ok(lv != null, "★ see_ai 的关卡能载入（%s）" % TEST_LEVEL)
	if lv == null:
		return
	eq(String(lv.faction_config("p1").get("clan", "")), "dynasty",
		"★★ 关卡数据：p1 是王朝")
	eq(String(lv.faction_config("p2").get("clan", "")), "empire",
		"★★ 关卡数据：p2 是帝国")
	# 没写 clan 的阵营 = 空串（运行时回落原生）。
	eq(String(lv.faction_config("nobody").get("clan", "")), "",
		"没声明的阵营 clan 为空（= 原生）")
	# 校验：写错派系是**警告**而不是拦死。
	var clan_warn := false
	for msg in lv.warnings():
		if String(msg).contains("派系"):
			clan_warn = true
	ok(not clan_warn, "★ 这一关没有「派系不存在」的警告")


# ------------------------------------------------------------------
# 4) 世界：clan_of 与「没写 = 原生」
# ------------------------------------------------------------------
func _test_world_clans(cfg) -> void:
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		ok(false, "（前提）关卡载入")
		return
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1", "p2"], false)
	ok(w != null, "★ see_ai 那一关能建出世界（不开 AI）")
	if w == null:
		return
	eq(w.clan_of("p1"), "dynasty", "★ 世界：p1 的派系 = 王朝")
	eq(w.clan_of("p2"), "empire", "★ 世界：p2 的派系 = 帝国")
	eq(w.clan_name("p1"), "王朝", "★ 世界的派系显示名")
	eq(w.clan_of("enemy"), cfg.clan_default_id(),
		"★ 关卡没提过的阵营 = 默认派系（原生）")

	# 缓存：同一个阵营问两次是同一个值（且不因为调用顺序变化）。
	eq(w.clan_of("p1"), w.clan_of("p1"), "派系查询幂等（有缓存）")

	# 自由对战（world.create，没有 level）⇒ 一律原生。
	var w2 = require_world(cfg)
	if w2 != null:
		eq(w2.clan_of(String(w2.my_faction)), "native", "★ 不带关卡的 world = 原生")


# ------------------------------------------------------------------
# 5) 招募表按派系
# ------------------------------------------------------------------
func _test_rosters(cfg) -> void:
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1", "p2"], false)
	if w == null:
		return
	# 王朝那一方能招王朝的兵，帝国那边不能。
	ok(w.is_unit_recruitable("dy_guard", "p1"), "★ 王朝能招协防军")
	ok(not w.is_unit_recruitable("dy_guard", "p2"), "★ 帝国招不了协防军")
	ok(w.is_unit_recruitable("dg_champion", "p2"), "★ 帝国能招冠军骑士")
	ok(not w.is_unit_recruitable("dg_champion", "p1"), "★ 王朝招不了冠军骑士")
	# 粮车两个派系共用原生那一条（需求里三条描述与原生逐字一致）。
	ok(w.is_unit_recruitable("grain_cart", "p1") and w.is_unit_recruitable("grain_cart", "p2"),
		"★ 粮车两个派系都能招（共用原生兵种）")

	# 表长度 / 首项：与 config 一致（读取路径没有偷偷换表）。
	eq(w.recruit_list("p1").size(), 7, "world.recruit_list(p1) = 王朝的 7 条")
	eq(w.recruit_list("p2").size(), 6, "world.recruit_list(p2) = 帝国的 6 条")

	# tier / cost / 人口都按派系查。
	eq(w.recruit_tier("dy_royal", "p1"), 3, "御林军在三本（第 3 行）")
	near(float(w.recruit_population_cost("dy_guard", "p1")), 2.0, 1e-9,
		"协防军的人口按整包算")
	var c1: Dictionary = w.recruit_cost("dy_scout", "p1")
	ok(float(c1.get("gold", 0.0)) > 0.0, "斥候要黄金（高级单位）")
	# 区划招将表是**全局**的（将领不属于任何派系）。
	ok(w.is_zone_recruitable("general_1"), "★ 区划招将不受派系影响")

	# 组合条目的 spawn 展开。
	eq(w.recruit_spawn_types("dy_guard", "p1"),
		["dy_spear_guard", "dy_archer_guard"], "★ 协防军展开成枪兵 + 弓箭手")
	eq(w.recruit_spawn_types("dg_bolt", "p2"), ["dg_bolt"],
		"普通条目展开成它自己（一条）")
	eq(w.recruit_primary_type("dy_royal", "p1"), "dy_royal_sword",
		"组合条目的代表兵种 = 第一个子单位")
	eq(w.recruit_kind_for_unit("p1", "dy_royal_archer"), "dy_royal",
		"★ 兵种 → 能招出它的那一条（驻防 AI 补员靠它）")


# ------------------------------------------------------------------
# 6) 组合单位：一次读条出多个兵
# ------------------------------------------------------------------
func _test_composite_recruit(cfg) -> void:
	for spec in [["dy_guard", 2], ["dy_royal", 3]]:
		var kind := String(spec[0])
		var want := int(spec[1])
		var w = _clan_world(cfg)
		if w == null:
			return
		# 大本营升到 3 级（御林军在三本）；钱给够（关卡起手只有 100 粮）。
		w.debug_upgrade_base_to_level(3, "p1")
		w.resources["food"] = 5000.0
		w.resources["gold"] = 5000.0
		var leader = _first_leader(w, "p1")
		ok(leader != null, "（前提）%s 有一位将领" % kind)
		if leader == null:
			continue
		var before: int = w.retinue_of(String(leader.id), false).size()
		var food0: float = float(w.resources.get("food", 0.0))
		var zone = w.zones.zone_at(leader.tx, leader.ty)
		# ★ 关卡里那块地的初始人口只有 1（还没涨到上限），而组合单位一单就要 2 / 3 人口
		#   —— 先把它喂够，否则会被拒因 "population" 挡掉。
		if zone != null:
			zone["population"] = maxf(float(zone.get("population", 0.0)), 20.0)
		var pop0: float = float(zone.get("population", 0.0)) if zone != null else 0.0
		leader.recruit_idle_timer = 99999.0
		var pop_cost: float = w.recruit_population_cost(kind, "p1")

		ok(w.start_recruit(kind, String(leader.id), "p1"), "★ 把 %s 排进队列" % kind)
		eq(leader.train_queue_size(), 1, "★ 组合单位只占 **1** 个队列格")
		var cost: Dictionary = w.recruit_cost(kind, "p1")
		near(food0 - float(w.resources.get("food", 0.0)),
			float(cost.get("food", 0.0)), 1e-6, "%s 一次扣整包的粮食" % kind)
		if zone != null:
			near(pop0 - float(zone.get("population", 0.0)), pop_cost, 1e-6,
				"★ %s 一次扣整包人口（%.0f）" % [kind, pop_cost])

		# 推进到读条结束（批次读条 + 一点余量）。
		# ★ 2026.11.2：读条时长由**招兵的这位将领**决定（默认 10，见 leader_recruit_sec）。
		var secs: float = w.leader_recruit_sec(leader) + 0.5
		var frames := int(ceil(secs / DT))
		for _i in frames:
			leader.recruit_idle_timer = 99999.0
			w.tick(DT)
		var after: int = w.retinue_of(String(leader.id), false).size()
		eq(after - before, want, "★ %s 一次生成 %d 个单位" % [kind, want])

		# 名字：都取条目 label（需求「名称均为…」）。
		var label := String(w.recruit_entry(kind, "p1").get("label", ""))
		var named := 0
		for m in w.retinue_of(String(leader.id), false):
			if String(m.name) == label:
				named += 1
		eq(named, want, "★ %d 个单位都叫「%s」" % [want, label])

		# 子单位的兵种真的是 spawn 里那两个 / 三个。
		var types: Array = w.recruit_spawn_types(kind, "p1")
		var got := {}
		for m in w.retinue_of(String(leader.id), false):
			got[String(m.unit_type)] = true
		for t in types:
			ok(got.has(String(t)), "★ 生成出了 %s" % String(t))


# ------------------------------------------------------------------
# 7) 击退 + 眩晕（含「稳定」免疫）
# ------------------------------------------------------------------
func _test_knockback_and_stun(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var plain = _mk_unit(w, cfg, "kb_plain", "dy_spear_guard", "p2")
	var stable = _mk_unit(w, cfg, "kb_stable", "dy_royal_sword", "p2")
	if plain == null or stable == null:
		ok(false, "（前提）两个受击单位都在")
		return
	# ★ 放到一段**连续可通行**的空地上：击退会被地形挡住，随机落脚点会让断言不稳定。
	var spot := _open_spot(w, "p2", 4)
	if spot.x >= 0:
		_place(w, plain, GridRes.center_of(spot))
		# 稳定那个放到**另一段**空地：两个单位叠在同一格会被碰撞推开，
		# 那样「稳定单位一格都没被推」这条断言测的就是碰撞而不是击退了。
		var spot2 := _open_spot(w, "p2", 2, 1)
		if spot2.x >= 0:
			_place(w, stable, GridRes.center_of(spot2))
	var frm: Vector2 = plain.pos - Vector2(2.0, 0.0)
	var p0: Vector2 = plain.pos
	var s0: Vector2 = stable.pos

	ok(plain.apply_knockback(cfg, w, frm, 0.8, 0.5), "★ 普通单位被击退（返回 true）")
	ok(plain.pos.distance_to(p0) > 0.2,
		"★ 普通单位真的被推开了（%.2f 格）" % plain.pos.distance_to(p0))
	near(plain.stun_timer, 0.5, 1e-6, "★ 同时进入眩晕 0.5 秒")

	ok(not stable.apply_knockback(cfg, w, frm, 0.8, 0.5),
		"★★ 稳定单位免疫击退（返回 false）")
	ok(stable.pos.distance_to(s0) < 1e-6, "★★ 稳定单位一格都没被推")
	near(stable.stun_timer, 0.0, 1e-9, "★★ 稳定单位也不吃眩晕")

	# ★ 稳定**只**免疫击退：单位之间的推挤（collision）照旧对它生效 ——
	#   collision.gd 的权重只看「有没有移动命令」，一行都不读这个标记。
	ok(stable.knockback_immune, "稳定标记落在单位身上（供 collision 之外的判据读）")

	# 眩晕期间不能移动（`halt()` + 逻辑跳过那一支）。
	if spot.x >= 0:
		_place(w, plain, GridRes.center_of(spot))
		plain.stun_timer = 0.0
		ok(plain.move_to(w, cfg, GridRes.center_of(Vector2i(spot.x + 3, spot.y))),
			"（前提）能给眩晕单位下移动命令")
		plain.stun_timer = 0.5
		var before: Vector2 = plain.pos
		# 40 帧 > 0.5 秒：多给一点余量，避免 1/60 的浮点累加剩一个 1e-16。
		for _i in 40:
			w.tick(DT)
		near(plain.pos.distance_to(before), 0.0, 1e-6, "★ 眩晕期间原地不动（0.5 秒）")
		ok(plain.stun_timer <= 0.0, "★ 眩晕会自己走完")


# ------------------------------------------------------------------
# 8) 直线穿透子弹
# ------------------------------------------------------------------
func _test_pierce(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var bolt = _mk_unit(w, cfg, "pierce_bolt", "dg_bolt", "p1")
	if bolt == null:
		ok(false, "（前提）扭力弩炮在场")
		return
	# 三个敌人在同一条水平线上（离弩炮 2 / 4 / 6 格），一个友军在旁边。
	var victims: Array = []
	for i in 3:
		var v = _mk_unit(w, cfg, "pierce_v%d" % i, "dg_swordsman", "p2")
		if v == null:
			ok(false, "（前提）靶子 %d" % i)
			return
		v.hp = 100000.0
		v.hp_max = 100000.0
		_place(w, v, bolt.pos + Vector2(2.0 + float(i) * 2.0, 0.0))
		victims.append(v)
	var friend = _mk_unit(w, cfg, "pierce_friend", "dg_swordsman", "p1")
	if friend != null:
		friend.hp = 100000.0
		friend.hp_max = 100000.0
		_place(w, friend, bolt.pos + Vector2(4.0, 0.0))
	var hp0: Array = []
	for v in victims:
		hp0.append(float(v.hp))

	# 朝最远的那个目标开一炮：穿透应当把中间两个也串起来。
	var p = ProjectileRes.spawn(w, cfg, String(bolt.faction), bolt, bolt.pos,
		victims[2], false, bolt.combat_damage(cfg),
		bolt.splash_radius, bolt.siege, bolt.pierce, bolt.projectile_arc,
		bolt.knockback_distance, bolt.knockback_stun_sec, bolt.combat_range(cfg))
	ok(p != null and p.pierce, "★ 投掷物带上了穿透标记")
	_advance_until_landed(w, cfg, 900)
	for i in victims.size():
		var v = victims[i]
		ok(float(v.hp) < float(hp0[i]),
			"★ 直线上的第 %d 个敌人也吃到了伤害（穿透）" % (i + 1))
	if friend != null:
		ok(friend.hp == friend.hp_max, "★ 直线上的**友军**不受伤")

	# 对照组：把 pierce 关掉 ⇒ 只有目标自己掉血（说明上面那条不是巧合）。
	var w2 = _clan_world(cfg)
	if w2 != null:
		var b2 = _mk_unit(w2, cfg, "np_bolt", "dg_bolt", "p1")
		var a = _mk_unit(w2, cfg, "np_a", "dg_swordsman", "p2")
		var b = _mk_unit(w2, cfg, "np_b", "dg_swordsman", "p2")
		if b2 != null and a != null and b != null:
			a.hp = 100000.0
			a.hp_max = 100000.0
			b.hp = 100000.0
			b.hp_max = 100000.0
			_place(w2, a, b2.pos + Vector2(3.0, 0.0))
			_place(w2, b, b2.pos + Vector2(6.0, 0.0))
			ProjectileRes.spawn(w2, cfg, String(b2.faction), b2, b2.pos, b, false,
				b2.combat_damage(cfg), 0.0, false, false, true,
				0.0, 0.0, b2.combat_range(cfg))
			_advance_until_landed(w2, cfg, 900)
			ok(b.hp < b.hp_max, "（对照）目标自己掉血")
			ok(a.hp == a.hp_max, "（对照）不穿透时中间那个不掉血")


# ------------------------------------------------------------------
# 9) 近战减伤（「远近免伤+」只挡自己那一类）
# ------------------------------------------------------------------
func _test_melee_reduction(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var sword = _mk_unit(w, cfg, "mr_sword", "dg_swordsman", "p1")
	var plain = _mk_unit(w, cfg, "mr_plain", "dg_archer", "p1")
	if sword == null or plain == null:
		return
	# 中层士气：不让士气免伤参与，只看兵种特性。
	for u in [sword, plain]:
		u.hp = 1000.0
		u.hp_max = 1000.0
		u.morale = cfg.morale_mid_tier
		u.armor = 0.0
	# 近战那一击：披甲剑士少吃 25%，弓箭手照吃全额。
	sword.take_damage(cfg, w, 100.0, null, false)
	plain.take_damage(cfg, w, 100.0, null, false)
	near(1000.0 - sword.hp, 100.0 * (1.0 - cfg.unit_traits_of("dg_swordsman")
		.get("melee_reduction", 0.0)), 1e-6, "★ 披甲剑士：近战伤害减 25%")
	near(1000.0 - plain.hp, 100.0, 1e-6, "（对照）弓箭手没有近战减伤")

	# 远程那一击：披甲剑士**没有**远程减伤 ⇒ 照吃全额。
	sword.hp = 1000.0
	sword.take_damage(cfg, w, 100.0, null, true)
	near(1000.0 - sword.hp, 100.0, 1e-6,
		"★ 「近战减伤」不挡远程（两类伤害各自独立）")

	# 「远近免伤+」两个都吃。
	var royal = _mk_unit(w, cfg, "mr_royal", "dy_royal_sword", "p1")
	if royal != null:
		royal.hp = 1000.0
		royal.hp_max = 1000.0
		royal.morale = cfg.morale_mid_tier
		royal.armor = 0.0
		royal.take_damage(cfg, w, 100.0, null, false)
		near(1000.0 - royal.hp, 70.0, 1e-6, "★★ 御林军：近战也减 30%")
		royal.hp = 1000.0
		royal.take_damage(cfg, w, 100.0, null, true)
		near(1000.0 - royal.hp, 70.0, 1e-6, "★★ 御林军：远程也减 30%（远近免伤+）")


# ------------------------------------------------------------------
# 10) 弹道形状（抛物线 vs 直线）
# ------------------------------------------------------------------
func _test_arc_flag(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var bolt = _mk_unit(w, cfg, "arc_bolt", "dg_bolt", "p1")
	var cat = _mk_unit(w, cfg, "arc_cat", "dy_catapult", "p1")
	if bolt == null or cat == null:
		return
	ok(not bolt.projectile_arc, "★ 扭力弩炮：直线（不抛物）")
	ok(cat.projectile_arc, "★ 王朝投石车：抛物线")
	ok(_mk_unit(w, cfg, "arc_bow", "dg_archer", "p1").projectile_arc,
		"弓箭手默认抛物线（缺省 true）")
	# 投掷物上的字段（视图读它决定抬不抬高）。
	var p = ProjectileRes.spawn(w, cfg, String(bolt.faction), bolt, bolt.pos,
		cat, false, 10.0, 0.0, false, bolt.pierce, bolt.projectile_arc,
		0.0, 0.0, bolt.combat_range(cfg))
	ok(p != null and not p.arc, "★ 穿透弹的投掷物标记为「不抛物」")
	if p != null:
		p.alive = false
		w.projectiles.clear()


# ------------------------------------------------------------------
# 11) AI 按**自己那一方**的派系招兵（see_ai 就是双方 commander）
# ------------------------------------------------------------------
func _test_ai_uses_own_clan(cfg) -> void:
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return
	# ★ 与 view/game_scene3d.gd 的 start_ai_observer() 同一个装配方式：
	#   关卡里**所有**参展阵营都交给 commander，本机只当观战者。
	var overrides: Dictionary = {}
	var profiles: Dictionary = {}
	for meta in lv.faction_meta:
		var fid := String((meta as Dictionary).get("id", ""))
		if fid == "":
			continue
		overrides[fid] = LevelRes.AI_COMMANDER
		profiles[fid] = {"difficulty": "normal"}
	var w = WorldRes.create_from_level(cfg, lv, "p1", lv.seats(), true,
		overrides, profiles, -1, true)
	ok(w != null, "★ see_ai 那种「双方 commander」的世界能建出来")
	if w == null:
		return
	var ai1 = w.ai_commanders.get("p1", null)
	var ai2 = w.ai_commanders.get("p2", null)
	ok(ai1 != null and ai2 != null, "★★ 两边都挂上了 commander AI")
	if ai1 == null or ai2 == null:
		return
	eq(String(ai1.faction), "p1", "p1 的控制器属于 p1")
	eq(String(ai2.faction), "p2", "p2 的控制器属于 p2")
	# 派系编成权重被 AI 读到（不是全局那张表）。
	ok(not w.clan_ai_composition("p1").is_empty(), "★ p1（王朝）有派系编成")
	ok(not w.clan_ai_composition("p2").is_empty(), "★ p2（帝国）有派系编成")

	# ★★ 关键断言：AI 抽出来的兵种**必须是它自己派系表里的 kind**。
	#   （大本营 1 级 ⇒ 只有 tier 1 解锁；王朝 tier 1 只有协防军。）
	var leader1 = _first_leader(w, "p1")
	var leader2 = _first_leader(w, "p2")
	ok(leader1 != null and leader2 != null, "（前提）双方各有一位将领")
	if leader1 != null:
		var k1 := String(ai1._pick_kind(leader1))
		ok(k1 != "", "★ 王朝 AI 抽得出兵种（%s）" % k1)
		ok(w.is_unit_recruitable(k1, "p1"), "★★ 王朝 AI 抽的 %s 在王朝的招募表里" % k1)
		ok(not w.is_unit_recruitable(k1, "p2") or k1 == "grain_cart",
			"★★ 而且它不是帝国的兵（%s）" % k1)
	if leader2 != null:
		var k2 := String(ai2._pick_kind(leader2))
		ok(k2 != "", "★ 帝国 AI 抽得出兵种（%s）" % k2)
		ok(w.is_unit_recruitable(k2, "p2"), "★★ 帝国 AI 抽的 %s 在帝国的招募表里" % k2)

	# ★ 冒烟：真的跑一段，AI 不会因为派系表而崩（招募 / 出兵 / 索敌全在里面）。
	var before: int = w.units.size()
	for _i in 600:
		w.tick(DT)
	ok(w.units.size() >= before, "★ 跑 10 秒不炸（单位数 %d → %d）" % [before, w.units.size()])


# ------------------------------------------------------------------
# 12) ★★ 每个派系一套**不同倾向**的 commander AI（config 的 clan.list[].commander_ai）
# ------------------------------------------------------------------
func _test_clan_ai_profile(cfg) -> void:
	var global: Dictionary = cfg.ai_commander_cfg()
	ok(not global.is_empty(), "（前提）config.ai.commander 读得出来")

	# ---- 原生：**没写** commander_ai ⇒ 参数与「根本没有派系这回事」逐位一致
	ok(cfg.clan_commander_ai("native").is_empty(),
		"★★ 原生派系没写 commander_ai（它的 AI 行为一个字节都不变）")
	var p_native := AiProfileRes.build(cfg, "p1", [], {}, "")
	var p_native2 := AiProfileRes.build(cfg, "p1", [], {}, "native")
	eq(p_native, p_native2, "★★ 不传派系 / 传原生 → 合并结果完全相同")
	var g_auto: Dictionary = global.get("auto", {})
	near(float(p_native["auto"]["attack_after_sec"]),
		float(g_auto.get("attack_after_sec", 45.0)), 1e-9,
		"★ 原生的进攻时机 = 全局默认（没被任何派系块改过）")
	eq(p_native["roles"].has("line"), false, "★ 原生没有额外的「线列」编成块")

	# ---- 王朝 / 帝国：都有块，而且**两块不一样**
	for cid in ["dynasty", "empire"]:
		ok(not cfg.clan_commander_ai(cid).is_empty(), "★ %s 写了 commander_ai" % cid)
	var p1 := AiProfileRes.build(cfg, "p1", [], {}, "dynasty")
	var p2 := AiProfileRes.build(cfg, "p2", [], {}, "empire")

	near(float(p1["auto"]["attack_after_sec"]), 55.0, 1e-9,
		"★★ 王朝更晚开打（55 秒）")
	near(float(p2["auto"]["attack_after_sec"]), 38.0, 1e-9,
		"★★ 帝国更早开打（38 秒）")
	ok(float(p1["auto"]["attack_after_sec"]) > float(p2["auto"]["attack_after_sec"]),
		"★★ 两派的进攻时机确实不同（王朝 > 帝国）")

	# 队伍职能倾向：王朝偏线列（cycle 里 line 占多数），帝国偏远程/游击（line 只占 1/3）
	var c1: Array = p1["roles"]["cycle"]
	var c2: Array = p2["roles"]["cycle"]
	eq(c1.count("line"), 2, "★★ 王朝的职能轮换里「线列」占 2/3")
	eq(c2.count("line"), 1, "★★ 帝国的职能轮换里「线列」只占 1/3")
	eq(String(c2[0]), "ranged", "★★ 帝国第一支队伍就是远程队")
	eq(String(c1[0]), "line", "★★ 王朝第一支队伍是线列")

	# 编成按**自己派系**的兵种写；王朝更「重」、帝国更「精」
	eq(float(p1["production"]["home_team_size"]), 9.0, "★ 王朝的守军规模更大（9）")
	eq(float(p2["production"]["home_team_size"]), 7.0, "★ 帝国的守军规模更小（7）")
	ok(float(p1["expand"]["target_food_income"]) > float(p2["expand"]["target_food_income"]),
		"★ 王朝更看重粮食（协防军 150 粮 0 金）")
	ok(float(p2["expand"]["target_gold_income"]) > float(p1["expand"]["target_gold_income"]),
		"★ 帝国更看重黄金（冠军骑士 / 弩炮都吃金）")
	ok(float(p2["economy"]["reserve_gold"]) > float(p1["economy"]["reserve_gold"]),
		"★ 帝国的黄金储备更高（留钱买精锐）")

	# ---- 每一条编成里的兵种都必须是**这一派真能招的**（写错一个 id 就等于白配）
	for pair in [["dynasty", p1], ["empire", p2]]:
		var cid := String(pair[0])
		var prof: Dictionary = pair[1]
		for role in ["line", "ranged", "guerrilla"]:
			var rc: Dictionary = (prof["roles"] as Dictionary).get(role, {})
			var comp: Array = rc.get("composition", [])
			ok(not comp.is_empty(), "★ %s 的 %s 队有编成表" % [cid, role])
			for item in comp:
				var t := String((item as Dictionary).get("type", ""))
				# ★ 编成表里写的是**招募 kind**：普通兵种 kind == 兵种 id；
				#   组合单位（dy_guard / dy_royal）的 kind 不是兵种 id，靠 `spawn[]` 出兵。
				var rec: Dictionary = cfg.clan_recruit_entry(cid, t)
				ok(not rec.is_empty(),
					"★★ %s 能招出 %s（编成里不许写别派的兵）" % [cid, t])
				var spawn: Array = rec.get("spawn", []) if not rec.is_empty() else []
				ok(cfg.has_unit_type(t) or not spawn.is_empty(),
					"★ %s 的 %s 要么是真兵种、要么是带 spawn 的组合条目" % [cid, t])
				if not spawn.is_empty():
					for s in spawn:
						ok(cfg.has_unit_type(String((s as Dictionary).get("type", ""))),
							"★ 组合条目 %s 的 spawn 指向真兵种" % t)

	# ---- 控制器真的拿到了这套参数（不是只改了纯函数）
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return
	var ov := {}
	for meta in lv.faction_meta:
		ov[String((meta as Dictionary).get("id", ""))] = LevelRes.AI_COMMANDER
	var w2 = WorldRes.create_from_level(cfg, lv, "p1", lv.seats(), true, ov, {}, -1, true)
	if w2 == null:
		ok(false, "（前提）双方 commander 的世界建得出来")
		return
	var ai1 = w2.ai_commanders.get("p1", null)
	var ai2 = w2.ai_commanders.get("p2", null)
	if ai1 == null or ai2 == null:
		ok(false, "（前提）双方 commander 都在")
		return
	near(float(ai1.profile["auto"]["attack_after_sec"]), 55.0, 1e-9,
		"★★ 王朝的控制器 profile 里就是 55 秒")
	near(float(ai2.profile["auto"]["attack_after_sec"]), 38.0, 1e-9,
		"★★ 帝国的控制器 profile 里就是 38 秒")
	eq(int(ai2.profile["idle"]["max_scouts"]), 3, "★ 帝国派更多侦察")


## 派系块本身要「形状正确」：只许写 ai.commander 里真有意义的键，且不能碰 difficulty。
##
## ★ 这一条是防手滑的：`commander_ai` 是**深合并**进 profile 的，写错一个键不会报错、
##   只会静默无效 —— 所以在这里把「认识的顶层键」钉死。
func _test_clan_profiles_compilable(cfg) -> void:
	var known: Array = cfg.ai_commander_cfg().keys()
	for cid in cfg.clan_ids():
		var block: Dictionary = cfg.clan_commander_ai(cid)
		if block.is_empty():
			continue
		ok(not block.has("difficulty"),
			"★★ %s 的派系块里没有 difficulty（难度不归派系管）" % cid)
		for k in block.keys():
			ok(known.has(k), "★★ %s 的派系块只写认识的键（%s）" % [cid, k])
		# 编成表的权重加起来应该接近 1（差太多说明配漏了 / 配重了）
		for role in ["line", "ranged", "guerrilla"]:
			var rc: Dictionary = (block.get("roles", {}) as Dictionary).get(role, {})
			var comp: Array = rc.get("composition", [])
			if comp.is_empty():
				continue
			var total := 0.0
			for item in comp:
				total += float((item as Dictionary).get("weight", 0.0))
			ok(absf(total - 1.0) < 0.02,
				"★ %s:%s 的编成权重合计 ≈ 1（实际 %.3f）" % [cid, role, total])


# ------------------------------------------------------------------
# 布尔断言的小补丁：`ok(not x == false)` 这种写法读着别扭，这里给它一个名字。
# ------------------------------------------------------------------


# ==================================================================
# 帮手
# ==================================================================

## see_ai 那一关的世界（p1 = 王朝 / p2 = 帝国），不开 AI。
func _clan_world(cfg):
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1", "p2"], false)


func _first_leader(w, faction: String):
	for u in w.units:
		if u.alive and String(u.faction) == faction and w.is_team_leader(u):
			return u
	return null


## 造一个**游离**单位并挂进世界（不进任何队伍；位置在 p1 大本营旁边）。
func _mk_unit(w, cfg, id: String, unit_type: String, faction: String):
	var tile := Vector2i(-1, -1)
	var base = w.find_base_of(faction)
	if base != null:
		tile = _free_tile_near(w, base.tx, base.ty)
	if tile.x < 0:
		tile = _free_tile_near(w, int(w.map.cols / 2), int(w.map.rows / 2))
	if tile.x < 0:
		ok(false, "（前提）给 %s 找到落脚格" % id)
		return null
	var u = UnitRes.create(cfg, id, "测", tile, faction, unit_type, "", "",
		unit_type, -1)
	w.units.append(u)
	return u


func _place(w, u, pos: Vector2) -> void:
	u.pos = pos
	u.sync_tile(w.map)
	u.stop()


func _advance_until_landed(w, cfg, max_frames: int) -> int:
	var frames := 0
	while not w.projectiles.is_empty() and frames < max_frames:
		ProjectileRes.update(w, cfg, DT)
		frames += 1
	return frames


func _free_tile_near(w, cx: int, cy: int) -> Vector2i:
	for r in range(0, 10):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var t := Vector2i(cx + dx, cy + dy)
				if t.x < 0 or t.y < 0 or t.x >= w.map.cols or t.y >= w.map.rows:
					continue
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(-1, -1)


## 找一段**同一行上连续 `len` 格都可通行**的空地（给「击退 / 移动」这类需要空间的用例）。
##
## @param index 要第几段（0 = 第一段）。两段互不重叠 —— 用例里两个单位不能叠在同一格，
##        否则碰撞会把它们推开，那样测到的就不是击退了。
## 找不到返回 (-1,-1)。
func _open_spot(w, faction: String, len: int, index: int = 0) -> Vector2i:
	var found := 0
	for y in w.map.rows:
		var run := 0
		for x in w.map.cols:
			var ok_tile: bool = w.map.tile_exists(x, y) and PathfinderRes.passable(
				w.map, w.buildings, w.cfg, x, y, faction)
			run = run + 1 if ok_tile else 0
			if run >= len:
				# ★ 同一段连续可通行格只算**一段**：跳过这一段的剩余部分，避免
				#   index=1 又落回同一段。
				if found == index:
					return Vector2i(x - len + 1, y)
				found += 1
				run = 0
	return Vector2i(-1, -1)
