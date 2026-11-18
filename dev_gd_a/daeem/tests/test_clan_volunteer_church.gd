## test_clan_volunteer_church.gd —— **王朝·义勇军 / 帝国·教会军**（2026.11.18 新增两条派系线）
##
## 这一套验的是「两个新派系」这条链路的**数据 + 机制**（与 test_clan / test_clan_tech 同一层，互不重复）：
##   1. **表**：两个 clan 能读出来；招募表 6 条；科技页 9 格（空位是占位）；
##      每条科技的效果键都被 `tech.gd` 认识（否则会被静默丢掉）。
##   2. **兵种**：12 个新兵种的字段（水性 / 多段齐射 / 自愈 / 范围攻城 / 治疗光环）。
##   3. **单位状态**：水性（跨水域 + 水域减速）、溺水（不可动 / 易伤）、自由（血上限 +10%）。
##   4. **侵略如火**：己方单位站在敌方区划里 ⇒ 该区划的人口增长 / 产能被压，走开就恢复。
##   5. **教堂 + 自由瘟疫**：只有教会军能造、每区划一座、等级不超过大本营；
##      1 级招募给「自由」；2 级该区划 + 相邻区划染疫；拆掉就消失；染疫区划掉血。
##   6. **两条致命伤保护**：血战到底（回满 + 暴走）、信仰不死（锁血 1 + 无敌）。
##   7. **收税**：不自由税 / 自由税两条互补。
##
## ⚠️ 数值一律从 config 读（`cfg.unit_*` / `cfg.tech_*`），不在这里抄死数字 ——
##   调平衡时这套测试不该跟着改（只有「行为」变了才该红）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const GridRes = preload("res://logic/grid.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const TechRes = preload("res://logic/tech.gd")
const CombatRes = preload("res://logic/combat.gd")
## ★★ 2026.11.18：教堂的 3D 模型登记表（`BUILDING_MODELS` / `BUILDING_MODEL_LEVELS`）。
const BuildingViewRes = preload("res://view/building_view_3d.gd")
## ★★ 2026.11.18：建筑页条目（`hud._build_entries()`）—— 验「哪几格有牌、几级解锁」。
const HudRes = preload("res://view/hud.gd")

const DT := 1.0 / 60.0
const TEST_LEVEL := "res://data/campaigns/demo/levels/ai_test_clan.json"

const CLAN_V := "dynasty_volunteer"
const CLAN_C := "empire_church"


func _initialize() -> void:
	_case_name = "test_clan_volunteer_church"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_tables(cfg)
	_test_unit_types(cfg)
	_test_status_defs(cfg)
	_test_water_walk(cfg)
	_test_drowning(cfg)
	_test_freedom(cfg)
	_test_blitz(cfg)
	_test_church_build_rules(cfg)
	_test_church_freedom_and_plague(cfg)
	_test_fatal_blood_war(cfg)
	_test_fatal_undying(cfg)
	_test_taxes(cfg)
	_test_water_tech(cfg)
	_test_burst(cfg)
	_test_bathe(cfg)
	_test_missionary(cfg)
	_test_church_model(cfg)
	_test_build_card(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ==================================================================
# 世界脚手架
# ==================================================================

func _clan_world(cfg):
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1", "p2"], false)


## 在某一格上造一个单位（**不进任何队**，也不做招募校验）——测试专用。
func _spawn(w, cfg, type_id: String, tile: Vector2i, faction: String):
	var u = UnitRes.create(cfg, "t-%s-%d-%d" % [type_id, tile.x, tile.y], type_id,
		tile, faction, type_id, "", "", type_id, -1)
	u.pos = GridRes.center_of(tile)
	u.tx = tile.x
	u.ty = tile.y
	w.units.append(u)
	return u


func _zone_center_tile(w, owner: String) -> Vector2i:
	for z in w.zones.zones:
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != owner:
			continue
		var c: Variant = zd.get("center", null)
		if c != null:
			return c
	return Vector2i(-1, -1)


func _find_water_tile(map) -> Vector2i:
	for y in map.terrain.rows:
		for x in map.terrain.cols:
			if map.terrain_walkable(x, y):
				continue
			if map.has_method("is_water") and map.is_water(x, y):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


# ==================================================================
# 1) 表
# ==================================================================

func _test_tables(cfg) -> void:
	ok(cfg.clan_exists(CLAN_V), "★★ 派系「王朝·义勇军」能读出来")
	ok(cfg.clan_exists(CLAN_C), "★★ 派系「帝国·教会军」能读出来")
	eq(cfg.clan_name_of(CLAN_V), "王朝·义勇军", "★ 义勇军的显示名")
	eq(cfg.clan_name_of(CLAN_C), "帝国·教会军", "★ 教会军的显示名")

	# ---- 招募表 6 条
	eq(cfg.clan_recruit_list(CLAN_V).size(), 6, "★★ 义勇军 6 条招募")
	eq(cfg.clan_recruit_list(CLAN_C).size(), 6, "★★ 教会军 6 条招募")
	for cid in [CLAN_V, CLAN_C]:
		for e in cfg.clan_recruit_list(cid):
			var d: Dictionary = e
			ok(String(d.get("label", "")) != "", "★ %s 的 %s 有名字" % [cid, d.get("kind", "")])
			var tier := int(d.get("tier", 0))
			ok(tier >= 1 and tier <= 3, "★ %s 的阶合法" % d.get("kind", ""))
	# 阶的分布：义勇军 2 个一本 / 2 个二本 / 2 个三本；教会军 2 / 1 / 3
	eq(_tier_count(cfg, CLAN_V, 1), 2, "★ 义勇军 2 个一本")
	eq(_tier_count(cfg, CLAN_V, 2), 2, "★ 义勇军 2 个二本")
	eq(_tier_count(cfg, CLAN_V, 3), 2, "★ 义勇军 2 个三本")

	# ---- 科技页 9 格 + 空位
	var vtech: Array = cfg.tech_list_for(CLAN_V)
	var ctech: Array = cfg.tech_list_for(CLAN_C)
	eq(vtech.size(), 9, "★★ 义勇军科技页 9 格")
	eq(ctech.size(), 9, "★★ 教会军科技页 9 格")
	eq(_empty_slots(vtech), 2, "★ 义勇军 2 个空位（7 条科技）")
	eq(_empty_slots(ctech), 2, "★ 教会军 2 个空位")
	# 列优先：第 i 格的阶 = i % 3 + 1
	for pair in [["义勇军", vtech], ["教会军", ctech]]:
		var label := String(pair[0])
		var slots: Array = pair[1]
		for i in 9:
			var e: Dictionary = slots[i]
			if String(e.get("id", "")) == "":
				continue
			eq(int(e.get("tier", 0)), i % 3 + 1,
				"★ %s 第 %d 格在第 %d 行" % [label, i, i % 3 + 1])

	# ---- 每条科技的效果键都被 tech.gd 认识
	var known: Dictionary = TechRes.default_effects()
	for cid in [CLAN_V, CLAN_C]:
		for e in cfg.tech_list_for(cid):
			var d: Dictionary = e
			var id := String(d.get("id", ""))
			if id == "":
				continue
			ok(String(d.get("name", "")) != "", "★ %s 有名字" % id)
			ok(String(d.get("desc", "")) != "", "★ %s 有悬停说明" % id)
			for k in (d.get("effect", {}) as Dictionary).keys():
				ok(known.has(String(k)), "★★ %s 的效果键 %s 被 tech.gd 认识" % [id, k])

	# ---- 教会军的建筑白名单
	ok(cfg.clan_buildings(CLAN_C).has("church"), "★★ 教会军的建筑白名单里有教堂")
	ok(not cfg.clan_buildings_all(CLAN_C), "★ 教会军的建筑是白名单（不是「全都能造」）")
	ok(cfg.clan_buildings_all(CLAN_V), "★ 义勇军不写白名单 ⇒ 保持「全都能造」")
	ok(cfg.has_building_type("church"), "★★ 教堂这个建筑类型存在")
	eq(cfg.building_per_zone_limit("church"), 1, "★★ 教堂每区划限一座")
	ok(cfg.building_max_level_by_base("church"), "★★ 教堂等级受大本营等级限制")
	eq(cfg.upgrade_max_level("church"), 2, "★ 教堂 1→2 级")

	# ---- ★★ 2026.11.18 修的两个 bug（用户实测报回来的）
	#  ① 「教会军的其他建筑不见了」：`clan.buildings` 是**额外**建筑，不是「只能造这些」；
	#  ② 「义勇军也能造教堂」：建筑侧的 `clans` 白名单才是唯一的准入判据。
	ok(cfg.clan_can_build(CLAN_C, "church"), "★★ 教会军能造教堂")
	ok(cfg.clan_can_build(CLAN_C, "farm"), "★★ 教会军**照样**能造普通建筑（粮田）")
	ok(cfg.clan_can_build(CLAN_C, "wall"), "★★ 教会军照样能造墙")
	ok(not cfg.clan_can_build(CLAN_V, "church"), "★★ 义勇军**不能**造教堂")
	ok(cfg.clan_can_build(CLAN_V, "farm"), "★ 义勇军能造普通建筑")
	var all_ids := _buildable_ids(cfg.buildable_building_defs())
	var c_ids := _buildable_ids(cfg.buildable_building_defs_for(CLAN_C))
	var v_ids := _buildable_ids(cfg.buildable_building_defs_for(CLAN_V))
	eq(c_ids.size(), all_ids.size(), "★★ 教会军的建筑页 = 全部可建造建筑（含教堂）")
	ok(c_ids.has("church"), "★★ …里面有教堂")
	ok(c_ids.has("farm") and c_ids.has("wall") and c_ids.has("mine"),
		"★★ …而且普通建筑一个都没少")
	eq(v_ids.size(), all_ids.size() - 1, "★★ 义勇军的建筑页 = 全部可建造建筑 − 教堂")
	ok(not v_ids.has("church"), "★★ …义勇军看不到教堂那张牌")
	ok(v_ids.has("farm") and v_ids.has("mine"), "★ …普通建筑照旧")
	# ③ 教堂必须**开局就能造**：它排在第 3 行只是因为建筑页只有那一个空格。
	eq(cfg.building_min_base("church"), 1, "★★ 教堂 1 级大本营就能造（min_base = 1）")
	eq(cfg.building_tier("church"), 3, "★ 教堂仍排在第 3 行（只是排版，不是解锁门槛）")
	eq(cfg.building_min_base("stone_wall"), 2, "★ 没写 min_base 的建筑仍按 tier 解锁")


## 建筑定义数组 → id 数组（测试里比对「哪几种建筑」）。
func _buildable_ids(defs: Array) -> Array:
	var out: Array = []
	for d in defs:
		out.append(String((d as Dictionary).get("id", "")))
	return out


func _tier_count(cfg, clan: String, tier: int) -> int:
	var n := 0
	for e in cfg.clan_recruit_list(clan):
		if int((e as Dictionary).get("tier", 0)) == tier:
			n += 1
	return n


func _empty_slots(slots: Array) -> int:
	var n := 0
	for e in slots:
		if String((e as Dictionary).get("id", "")) == "":
			n += 1
	return n


# ==================================================================
# 2) 兵种
# ==================================================================

func _test_unit_types(cfg) -> void:
	# 义勇军
	ok(cfg.has_unit_type("dv_bandit"), "★★ 流寇存在")
	eq(cfg.unit_class_of("dv_bandit"), ConfigRes.CLASS_INFANTRY, "★ 流寇是步兵")
	ok(cfg.unit_is_ranged("dv_bandit"), "★ 流寇是远程步兵")
	eq(cfg.unit_class_of("dv_jinfan"), ConfigRes.CLASS_INFANTRY, "★ 锦帆是近战步兵")
	ok(cfg.unit_status_ids_of("dv_jinfan").has("water_walk"), "★★ 锦帆天生带「水性」")
	ok(cfg.unit_can_attack("dv_jinfan"), "★ 锦帆能攻击")
	ok(cfg.unit_splash_radius_of("dv_greenwood") > 0.0, "★★ 绿林攻击带范围伤害")
	ok(cfg.unit_traits_of("dv_greenwood")["attack_vs_class"].has("infantry"),
		"★ 绿林对步兵有增伤")
	ok(not cfg.unit_can_attack("dv_grass_cart"), "★★ 草车不攻击（支援单位）")
	ok(cfg.unit_heal_aura_radius_of("dv_grass_cart") > 0.0, "★ 草车有治疗光环")
	ok(cfg.unit_heal_aura_rate_of("dv_grass_cart") < cfg.unit_heal_aura_rate_of("grain_cart"),
		"★★ 草车的回复效果比粮车差")
	ok(cfg.unit_is_ranged("dv_xiangma") and cfg.unit_move_shoot("dv_xiangma"),
		"★★ 响马是骑射（可移动射击）")
	ok(cfg.unit_class_of("dv_xiangma") == ConfigRes.CLASS_CAVALRY, "★ 响马是骑兵")
	eq(cfg.unit_burst_of("dv_arrowstorm")["count"], 6, "★★ 万箭穿心一次打 6 段")
	ok(cfg.unit_burst_of("dv_arrowstorm")["reload_sec"] > 1.0, "★ 万箭穿心有装填时间")
	ok(cfg.unit_is_siege("dv_arrowstorm"), "★ 万箭穿心是攻城")

	# 教会军
	ok(cfg.unit_status_ids_of("ec_pilgrim").is_empty(), "★ 朝圣者没有天生状态")
	ok(cfg.unit_traits_of("ec_pilgrim")["attack_vs_class"].has("cavalry"),
		"★ 朝圣者对骑兵有增伤")
	ok(cfg.unit_traits_of("ec_faith_archer")["attack_vs_class"].has("infantry"),
		"★ 信仰弓手对步兵有增伤")
	eq(cfg.unit_class_of("ec_preacher"), ConfigRes.CLASS_CAVALRY, "★ 传教士是骑兵")
	ok(cfg.unit_self_heal_of("ec_preacher") > 0.0, "★★ 传教士自己会缓慢回血")
	ok(cfg.unit_vision_of("ec_preacher") >= 12.0, "★ 传教士是侦察单位（视野大）")
	ok(cfg.unit_is_siege("ec_flail"), "★★ 神圣连枷是攻城")
	ok(cfg.unit_splash_radius_of("ec_flail") > 0.0, "★★ 神圣连枷是范围攻城伤害")
	var templ: Dictionary = cfg.unit_traits_of("ec_templar")
	ok(bool(templ.get("knockback_immune", false)), "★★ 圣殿骑士稳定（免疫击退）")
	ok(float(templ.get("melee_reduction", 0.0)) > 0.0, "★ 圣殿骑士有近战免伤")
	ok(float(templ.get("ranged_reduction", 0.0)) > 0.0, "★ 圣殿骑士有远程免伤")
	ok(cfg.unit_armor_of("ec_templar") >= 8.0, "★ 圣殿骑士防御高")
	ok(cfg.unit_heal_aura_rate_of("ec_relic_cart") > cfg.unit_heal_aura_rate_of("grain_cart"),
		"★★ 圣物推车回血比粮车快")
	ok(cfg.unit_heal_aura_radius_of("ec_relic_cart") > cfg.unit_heal_aura_radius_of("grain_cart"),
		"★ 圣物推车回血范围比粮车大")

	# 全部新兵种都**没有 sprite** ⇒ 走「单字占位」（用户口径：素材先用字代替图案）
	for tid in ["dv_bandit", "dv_jinfan", "dv_greenwood", "dv_grass_cart", "dv_xiangma",
			"dv_arrowstorm", "ec_pilgrim", "ec_faith_archer", "ec_preacher", "ec_flail",
			"ec_templar", "ec_relic_cart"]:
		eq(cfg.unit_sprite_of(tid), "", "★★ %s 用单字占位（没配 sprite）" % tid)
		ok(cfg.unit_icon_of(tid) != "", "★ %s 有立牌上的那个字" % tid)


# ==================================================================
# 3) 状态池
# ==================================================================

func _test_status_defs(cfg) -> void:
	for sid in ["water_walk", "drowning", "freedom", "blood_war", "undying"]:
		ok(cfg.has_unit_status(sid), "★★ 状态 %s 在池里" % sid)
		ok(cfg.unit_status_name(sid) != "", "★ %s 有名字" % sid)
		ok(cfg.unit_status_desc(sid) != "", "★ %s 有说明" % sid)
	ok(bool(cfg.unit_status_def("water_walk").get("water_walk", false)), "★★ 水性可跨水域")
	near(float(cfg.unit_status_def("water_walk").get("water_speed_mult", 1.0)), 0.5, 1e-6,
		"★★ 水域中移速 −50%")
	ok(bool(cfg.unit_status_def("drowning").get("immobilize", false)), "★★ 溺水不可移动")
	near(float(cfg.unit_status_def("drowning").get("damage_taken_add", 0.0)), 1.0, 1e-6,
		"★★ 溺水易伤 +100%")
	near(float(cfg.unit_status_def("freedom").get("hp_mult", 0.0)), 0.1, 1e-6,
		"★★ 自由 +10% 血上限")
	ok(bool(cfg.unit_status_def("freedom").get("plague_immune", false)), "★★ 自由免疫自由瘟疫")
	near(float(cfg.unit_status_def("blood_war").get("attack_add", 0.0)), 0.5, 1e-6,
		"★★ 血战到底 +50% 伤害")

	# 合并效果：两条状态相加
	var merged: Dictionary = cfg.status_effects_merged(["freedom", "blood_war"])
	near(float(merged.get("attack_add", 0.0)), 0.6, 1e-6, "★ 状态攻击加成相加")
	ok(bool(merged.get("plague_immune", false)), "★ 合并后仍免疫瘟疫")


# ==================================================================
# 4) 水性：跨水域
# ==================================================================

func _test_water_walk(cfg) -> void:
	# ★ 用 ai_test 那张图：它一定有水域（frontier / between_moutains 都是 0 格水）。
	var w = WorldRes.create(cfg, "res://data/maps/ai_test/map.json", false)
	if w == null:
		ok(false, "ai_test 世界能建出来")
		return
	var wt := _find_water_tile(w.map)
	if wt.x < 0:
		ok(false, "（前提）ai_test 图上有水域格")
		return
	# 普通步兵：水域不可通行
	ok(not PathfinderRes.passable(w.map, w.buildings, cfg, wt.x, wt.y, "p1", false),
		"★★ 普通单位不能走水域")
	# 锦帆（天生水性）：水域可通行
	var u = _spawn(w, cfg, "dv_jinfan", _first_land_near(w, wt), "p1")
	ok(u.is_water_walker(), "★★ 锦帆出生就带水性")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, wt.x, wt.y, "p1", u.is_water_walker()),
		"★★ 会水的单位可以走水域")
	# 山仍然挡（水性只放行水域）
	var mt := _find_mountain_tile(w.map)
	if mt.x >= 0:
		ok(not PathfinderRes.passable(w.map, w.buildings, cfg, mt.x, mt.y, "p1", true),
			"★★ 水性不放行山地")
	# 水域格上的移速倍率（面板同源）
	u.tx = wt.x
	u.ty = wt.y
	u.pos = GridRes.center_of(wt)
	var dry_speed: float = cfg.unit_speed_of("dv_jinfan")
	near(u.speed(cfg, w.map, w), dry_speed * 0.5, 1e-4,
		"★★ 在水域里移速减半（面板与实测同源）")


func _first_land_near(w, tile: Vector2i) -> Vector2i:
	for d in GridRes.DIRS8:
		var t := Vector2i(tile.x + d.x, tile.y + d.y)
		if w.map.terrain.has(t.x, t.y) and w.map.terrain_walkable(t.x, t.y):
			return t
	return Vector2i(1, 1)


func _find_mountain_tile(map) -> Vector2i:
	for y in map.terrain.rows:
		for x in map.terrain.cols:
			if map.terrain_walkable(x, y):
				continue
			if map.has_method("is_water") and map.is_water(x, y):
				continue
			return Vector2i(x, y)
	return Vector2i(-1, -1)


# ==================================================================
# 5) 溺水（数据预留，但效果必须是真的）
# ==================================================================

func _test_drowning(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var u = _spawn(w, cfg, "dv_bandit", _zone_center_tile(w, "p1") + Vector2i(1, 0), "p1")
	u.grant_statuses(cfg, ["drowning"])
	ok(u.is_immobilized(), "★★ 溺水 = 不可移动")
	near(u.speed(cfg, w.map, w), 0.0, 1e-6, "★★ 溺水单位移速为 0")
	# 易伤 +100%：同样的一击，溺水单位掉两倍血
	var hp0: float = u.hp
	u.take_damage(cfg, w, 10.0, null, false, true)
	near(hp0 - u.hp, 20.0, 0.6, "★★ 溺水易伤 +100%（10 点伤害掉 20 血）")
	# 每秒掉 5% 最大生命
	var before: float = u.hp
	u.tick_status(cfg, w, 1.0)
	near(before - u.hp, u.hp_max * 0.05, 1.0, "★★ 溺水每秒掉 5% 最大生命")


# ==================================================================
# 6) 自由：血上限 +10%
# ==================================================================

func _test_freedom(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var u = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p2") + Vector2i(1, 0), "p2")
	var base: float = u.hp_max
	ok(u.grant_statuses(cfg, ["freedom"]), "★★ 授予「自由」")
	near(u.hp_max, base * 1.1, 0.5, "★★ 自由让血量上限 +10%")
	ok(u.is_plague_immune(), "★★ 自由免疫自由瘟疫")
	near(u.status_attack_mult(), 1.1, 1e-6, "★ 自由攻击 +10%")
	near(u.effective_armor(w), float(u.armor) * 1.1, 1e-6, "★ 自由防御 +10%")
	# 幂等：再授一次不会叠
	ok(not u.grant_statuses(cfg, ["freedom"]), "★ 重复授予同一条状态不变")
	near(u.hp_max, base * 1.1, 0.5, "★ 重复授予不会叠血上限")


# ==================================================================
# 7) 侵略如火
# ==================================================================

func _test_blitz(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var enemy_tile := _zone_center_tile(w, "p2")
	if enemy_tile.x < 0:
		ok(false, "（前提）p2 有一个己方区划")
		return
	var zid: int = int(w.zones.center_zone_at_id(enemy_tile.x, enemy_tile.y))
	var z: Variant = w.zones.zones_by_id.get(zid, null)
	if typeof(z) != TYPE_DICTIONARY:
		ok(false, "（前提）能拿到 p2 的区划字典")
		return
	var zd: Dictionary = z
	instant_tech(w, "dv_blitz", "p1")
	w.tick(DT)
	near(float(zd.get("production_mult", 1.0)), 1.0, 1e-6,
		"★★ 没有己方单位踩进去时，敌方区划产能不变")

	# 一个义勇军单位站进去
	var u = _spawn(w, cfg, "dv_bandit", enemy_tile, "p1")
	w.tick(DT)
	var prod_mult: float = float(zd.get("production_mult", 1.0))
	var pop_mult: float = float(zd.get("population_mult", 1.0))
	near(prod_mult, 0.98, 1e-6, "★★ 侵略如火：1 个单位 ⇒ 敌方产能 −2%")
	near(pop_mult, 0.96, 1e-6, "★★ 侵略如火：1 个单位 ⇒ 敌方人口增长 −4%")

	# 上限：50 个单位踩进去 ⇒ 产能最多 −50%
	for i in 60:
		_spawn(w, cfg, "dv_bandit", enemy_tile, "p1")
	w.tick(DT)
	near(float(zd.get("production_mult", 1.0)), 0.5, 1e-6, "★★ 侵略如火产能有 50% 上限")
	near(float(zd.get("population_mult", 1.0)), 0.0, 1e-6, "★★ 侵略如火人口有 100% 上限")

	# 全部走开 ⇒ 恢复（把所有 p1 单位挪到自己的区划里）
	var home := _zone_center_tile(w, "p1") + Vector2i(1, 0)
	for u2 in w.units:
		if u2 != null and String(u2.faction) == "p1":
			u2.tx = home.x
			u2.ty = home.y
			u2.pos = GridRes.center_of(home)
	w.tick(DT)
	near(float(zd.get("production_mult", 1.0)), 1.0, 1e-6, "★★ 单位离开后产能恢复")


# ==================================================================
# 8) 教堂：建造准入 / 每区划一座 / 等级上限
# ==================================================================

func _test_church_build_rules(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	eq(w.clan_of("p1"), CLAN_V, "★★ p1 是义勇军")
	eq(w.clan_of("p2"), CLAN_C, "★★ p2 是教会军")
	ok(not w.building_allowed_for_faction("church", "p1"), "★★ 义勇军不能造教堂")
	ok(w.building_allowed_for_faction("church", "p2"), "★★ 教会军能造教堂")
	ok(w.building_allowed_for_faction("farm", "p1"), "★ 义勇军仍能造普通建筑")

	var zt := _zone_center_tile(w, "p2")
	var zid: int = int(w.zones.center_zone_at_id(zt.x, zt.y))
	var pts: Array = w.build_points_of_zone(zid)
	if pts.is_empty():
		ok(false, "（前提）p2 的区划有建造点位")
		return
	var p0: Vector2i = pts[0]
	eq(w.build_reject_reason("church", p0.x, p0.y, "p1"), "clan",
		"★★ 义勇军在教堂点位上被拒（拒因 clan）")
	# 教会军：第一座能建
	ok(w.can_place_building("church", p0.x, p0.y, "p2"), "★★ 教会军能建第一座教堂")
	var b = w.add_building("church", p0.x, p0.y, "p2", false, true)
	ok(b != null, "★ 教堂建出来了")
	eq(w.building_level_cap(b), 1, "★★ 大本营 1 级 ⇒ 教堂最多 1 级")
	# 每区划限一座
	if pts.size() >= 2:
		var p1t: Vector2i = pts[1]
		eq(w.build_reject_reason("church", p1t.x, p1t.y, "p2"), "per_zone_limit",
			"★★ 同一区划第二座教堂被拒（拒因 per_zone_limit）")
	# 大本营升到 3 级 ⇒ 教堂上限跟着到 2 级
	w.debug_upgrade_base_to_level(3, "p2")
	eq(w.building_level_cap(b), 2, "★★ 大本营 3 级 ⇒ 教堂可以升到 2 级")
	# 教堂升级要花钱：给钱后能升（瞬时）
	w.ai_faction_resources["p2"] = {"food": 2000.0, "gold": 2000.0}
	ok(w.start_building_upgrade(b.tx, b.ty, "p2"), "★★ 教堂能升到 2 级")
	eq(int(b.level), 2, "★ 教堂现在是 2 级")


# ==================================================================
# 9) 教堂：1 级给自由 / 2 级染疫 / 拆掉消失 / 瘟疫掉血
# ==================================================================

func _test_church_freedom_and_plague(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var zt := _zone_center_tile(w, "p2")
	var zid: int = int(w.zones.center_zone_at_id(zt.x, zt.y))
	var pts: Array = w.build_points_of_zone(zid)
	if pts.is_empty():
		ok(false, "（前提）p2 的区划有建造点位")
		return
	var p0: Vector2i = pts[0]
	var b = w.add_building("church", p0.x, p0.y, "p2", false, true)
	# 1 级：这一区划招募出来的单位获得「自由」
	var u = _spawn(w, cfg, "ec_pilgrim", _first_land_near(w, p0), "p2")
	u.garrison_zone_id = zid
	ok(w.grant_recruit_statuses(u), "★★ 教堂 1 级：该区划招募的单位获得自由")
	ok(u.has_status("freedom"), "★ 自由真的挂上了")
	var free_hp: float = u.hp_max

	# 另一个区划招募的单位没有自由
	var v = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p1") + Vector2i(1, 0), "p2")
	ok(not w.grant_recruit_statuses(v), "★★ 没教堂的区划不给自由")

	# 1 级还不染疫
	w.tick(DT)
	ok(not w.zone_plague_at(zt.x, zt.y), "★★ 教堂 1 级不产生自由瘟疫")

	# 2 级：本区划 + 相邻区划染疫
	b.level = 2
	w.tick(DT)
	ok(w.zone_plague_at(zt.x, zt.y), "★★ 教堂 2 级：本区划染疫")
	var nbs: Array = w.zones.neighbors_of(zid)
	var any_nb := false
	for nb in nbs:
		var nz: Variant = w.zones.zones_by_id.get(int(nb), null)
		if typeof(nz) != TYPE_DICTIONARY:
			continue
		var nc: Variant = (nz as Dictionary).get("center", null)
		if nc == null:
			continue
		if w.zone_plague_at(int((nc as Vector2i).x), int((nc as Vector2i).y)):
			any_nb = true
			break
	ok(any_nb or nbs.is_empty(), "★★ 相邻区划也染疫")

	# 瘟疫掉血：没自由的掉、有自由的不掉
	var no_free = _spawn(w, cfg, "ec_pilgrim", _first_land_near(w, p0), "p2")
	no_free.garrison_zone_id = zid
	var hp_before: float = no_free.hp
	var free_before: float = u.hp
	w.tick(DT)
	ok(no_free.hp < hp_before, "★★ 染疫区划里没有自由的单位在掉血")
	near(u.hp, free_before, 1e-6, "★★ 「自由」免疫自由瘟疫")
	ok(free_hp > 0.0, "（前提）自由单位的血上限有效")

	# 拆掉教堂 ⇒ 瘟疫消失
	w.remove_building(b, true)
	w.tick(DT)
	ok(not w.zone_plague_at(zt.x, zt.y), "★★ 拆掉教堂后自由瘟疫消失")


# ==================================================================
# 10) 血战到底
# ==================================================================

func _test_fatal_blood_war(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var u = _spawn(w, cfg, "dv_jinfan", _zone_center_tile(w, "p1") + Vector2i(1, 0), "p1")
	var base_hp: float = u.hp_max
	instant_tech(w, "dv_blood_war", "p1")
	near(u.hp_max, base_hp * 0.7, 0.6, "★★ 血战到底：血量上限 −30%")
	ok(w.fatal_refill_enabled("p1"), "★★ 血战到底已启用")
	# 致命伤 ⇒ 不死亡、回满血、进入暴走
	u.take_damage(cfg, w, 99999.0, null)
	ok(u.alive, "★★ 血战到底：第一次致命伤不死")
	near(u.hp, u.hp_max, 1.0, "★★ 血战到底：血量回满")
	ok(u.blood_war_active, "★ 进入暴走状态")
	ok(u.has_status("blood_war"), "★ 状态栏有「血战到底」")
	near(u.status_attack_mult(), 1.5, 1e-6, "★★ 暴走伤害 +50%")
	# 每秒 5% 掉血
	var before: float = u.hp
	u.tick_status(cfg, w, 1.0)
	near(before - u.hp, u.hp_max * 0.05, 1.0, "★★ 暴走每秒扣 5% 血上限")
	# 第二次致命伤 ⇒ 真的死（每个单位只触发一次）
	u.take_damage(cfg, w, 99999.0, null)
	ok(not u.alive, "★★ 血战到底只触发一次")


# ==================================================================
# 11) 信仰不死
# ==================================================================

func _test_fatal_undying(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var u = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p2") + Vector2i(1, 0), "p2")
	instant_tech(w, "ec_undying", "p2")
	near(float(w.fatal_invincible_sec("p2")), 3.0, 1e-6, "★★ 信仰不死：3 秒无敌")
	u.take_damage(cfg, w, 99999.0, null)
	ok(u.alive, "★★ 信仰不死：致命伤不死")
	near(u.hp, 1.0, 1e-6, "★★ 血量被锁在 1 点")
	ok(u.invincible_sec > 0.0, "★ 进入无敌")
	# 无敌期间再挨打：一点血都不掉
	u.take_damage(cfg, w, 99999.0, null)
	near(u.hp, 1.0, 1e-6, "★★ 无敌期间免疫一切伤害")
	# 无敌结束后恢复受伤
	u.tick_status(cfg, w, 3.5)
	ok(u.invincible_sec <= 0.0, "★ 无敌到了 3 秒就结束")
	ok(not u.has_status("undying"), "★ 「信仰不死」状态自动摘掉")
	u.take_damage(cfg, w, 99999.0, null)
	ok(not u.alive, "★★ 无敌结束后会正常死亡（但有冷却，见下）")


# ==================================================================
# 12) 收税
# ==================================================================

func _test_taxes(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	# p2 有两个单位（开局那个将领 + 我们加的一个），都不是自由的
	instant_tech(w, "ec_unfree_tax", "p2")
	var eff: Dictionary = w._eff_for("p2")
	var n := 0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == "p2" and not u.has_status("freedom"):
			n += 1
	var gold: float = w._unit_tax_gold("p2", eff)
	near(gold, float(n) * w.unit_tax_gold_per_sec("p2", false), 1e-4,
		"★★ 不自由税：每个无自由单位给一份金")
	ok(gold > 0.0, "★ 不自由税确实产金")

	# 自由税：只对含自由的单位收
	instant_tech(w, "ec_free_tax", "p2")
	var u0 = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p2") + Vector2i(2, 0), "p2")
	u0.grant_statuses(cfg, ["freedom"])
	var eff2: Dictionary = w._eff_for("p2")
	var n_free := 0
	var n_plain := 0
	for u in w.units:
		if u == null or not u.alive or String(u.faction) != "p2":
			continue
		if u.has_status("freedom"):
			n_free += 1
		else:
			n_plain += 1
	var expect: float = float(n_free) * w.unit_tax_gold_per_sec("p2", true) \
		+ float(n_plain) * w.unit_tax_gold_per_sec("p2", false)
	near(w._unit_tax_gold("p2", eff2), expect, 1e-4, "★★ 两条税互补：各按自己那一档算")


# ==================================================================
# 13) 会水（方略）
# ==================================================================

func _test_water_tech(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var inf = _spawn(w, cfg, "dv_bandit", _zone_center_tile(w, "p1") + Vector2i(1, 0), "p1")
	var cav = _spawn(w, cfg, "dv_xiangma", _zone_center_tile(w, "p1") + Vector2i(2, 0), "p1")
	ok(not inf.has_status("water_walk"), "（前提）流寇本来不会水")
	instant_tech(w, "dv_water", "p1")
	# 状态补写发生在下一帧的 tick 里（版本号机制）
	w.tick(DT)
	ok(inf.has_status("water_walk"), "★★ 会水：步兵获得水性")
	ok(not cav.has_status("water_walk"), "★★ 会水只给步兵（骑兵不吃）")


# ==================================================================
# 14) 多段齐射
# ==================================================================

func _test_burst(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var tile := _zone_center_tile(w, "p1") + Vector2i(1, 0)
	var shooter = _spawn(w, cfg, "dv_arrowstorm", tile, "p1")
	eq(int(shooter.burst_count), 6, "★★ 万箭穿心出生就带 6 段")
	var target = _spawn(w, cfg, "ec_pilgrim", tile + Vector2i(2, 0), "p2")
	CombatRes.attack_unit(w, cfg, shooter, target)
	near(float(shooter.burst_left), 5.0, 0.01, "★★ 开火打出第 1 段，还剩 5 段")
	ok(float(shooter.attack_cd) > 1.0, "★★ 打完之后是长装填（不是普通攻击间隔）")
	shooter.burst_timer = 0.0
	var left_before: int = int(shooter.burst_left)
	CombatRes.tick_burst(w, cfg, shooter)
	eq(int(shooter.burst_left), left_before - 1, "★★ 到点补一段")
	# 目标死了 ⇒ 整段取消
	target.take_damage(cfg, w, 99999.0, null)
	shooter.burst_timer = 0.0
	CombatRes.tick_burst(w, cfg, shooter)
	eq(int(shooter.burst_left), 0, "★★ 目标死了就不再补射")


# ==================================================================
# 15) 沐浴自由（含自由的单位在染疫区划里 +20% 攻防）
# ==================================================================

func _test_bathe(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	instant_tech(w, "ec_bathe", "p2")
	var u = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p2") + Vector2i(1, 0), "p2")
	u.grant_statuses(cfg, ["freedom"])
	var armor_before: float = u.effective_armor(w)
	ok(not w.zone_plague_at(int(u.tx), int(u.ty)), "（前提）这块地还没染疫")
	near(w.freedom_plague_attack_mult(u), 1.0, 1e-6, "★★ 不染疫时没有额外加成")
	# 手动把这块地标成染疫（真实来源是教堂 / 传教，那两条各自有专门的用例）
	var z = w.zones.zone_at(int(u.tx), int(u.ty))
	if typeof(z) != TYPE_DICTIONARY:
		ok(false, "（前提）能拿到单位所在区划")
		return
	(z as Dictionary)["plague"] = true
	near(w.freedom_plague_attack_mult(u), 1.2, 1e-6, "★★ 沐浴自由：染疫区划里含自由单位攻击 +20%")
	near(u.effective_armor(w), armor_before * 1.2, 1e-4, "★★ 沐浴自由：防御同样 +20%")
	# 没有自由的单位不享受（它只会被瘟疫烧）
	var v = _spawn(w, cfg, "ec_pilgrim", _zone_center_tile(w, "p2") + Vector2i(2, 0), "p2")
	near(w.freedom_plague_attack_mult(v), 1.0, 1e-6, "★★ 没有自由就没有沐浴自由")


# ==================================================================
# 16) 传教（脱战单位染敌方区划）
# ==================================================================

func _test_missionary(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var enemy_tile := _zone_center_tile(w, "p1")
	var zid: int = int(w.zones.center_zone_at_id(enemy_tile.x, enemy_tile.y))
	if zid < 0:
		ok(false, "（前提）p1 有一个己方区划")
		return
	# 没有传教：站进去也不染疫
	var u = _spawn(w, cfg, "ec_preacher", enemy_tile, "p2")
	# 手动把它置成「脱战」（真实游戏里是「连续 recruit.combat_idle_sec 秒没目标、没挨打」）：
	# 这一关的敌方区划中心就是 p1 的大本营，站着不动它会去打建筑，永远脱不了战 ——
	# 这里只验证「传教 → 染疫」这条判据，索敌过程不在本用例的范围内。
	u.target = null
	u.target_building = null
	u.recruit_idle_timer = 999.0
	w.tick(DT)
	ok(not w.zone_plague_at(enemy_tile.x, enemy_tile.y), "★★ 没启用传教时敌方区划不染疫")
	instant_tech(w, "ec_missionary", "p2")
	ok(w.tech_missionary_plague("p2"), "★★ 传教已启用")
	u.target = null
	u.target_building = null
	u.recruit_idle_timer = 999.0
	w.tick(DT)
	ok(w.is_out_of_combat(u), "（前提）传教士处于脱战状态")
	ok(w.zone_plague_at(enemy_tile.x, enemy_tile.y), "★★ 传教：脱战单位让敌方区划染疫")
	# 走开 ⇒ 不再染疫（下一帧重算）
	u.tx = 0
	u.ty = 0
	u.pos = GridRes.center_of(Vector2i(0, 0))
	u.recruit_idle_timer = 999.0
	w.tick(DT)
	ok(not w.zone_plague_at(enemy_tile.x, enemy_tile.y), "★★ 单位走开后瘟疫消失")


# ==================================================================
# 17) 教堂的 3D 模型（Blender 建模 → assets/models/church_*_lowpoly.glb）
# ==================================================================

func _first_mesh_instance(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n as MeshInstance3D
	for c in n.get_children():
		var hit := _first_mesh_instance(c)
		if hit != null:
			return hit
	return null


func _test_church_model(cfg) -> void:
	ok(BuildingViewRes.BUILDING_MODELS.has("church"), "★★ 教堂登记进 BUILDING_MODELS")
	eq(String(BuildingViewRes.BUILDING_MODELS.get("church", "")),
		"res://assets/models/church_l1_lowpoly.glb", "★ 一级用 l1 模型")
	var levels: Dictionary = BuildingViewRes.BUILDING_MODEL_LEVELS.get("church", {})
	eq(levels.size(), 2, "★★ 教堂有两档模型（对应 upgrade.levels.church 两行）")
	var expect_h := {1: 1.90, 2: 2.26}
	for lvl in [1, 2]:
		var path := String(levels.get(lvl, ""))
		ok(path != "", "★ %d 级有模型路径" % lvl)
		if path == "":
			continue
		var ps: PackedScene = load(path)
		ok(ps != null, "★★ %d 级模型能加载：%s" % [lvl, path.get_file()])
		if ps == null:
			continue
		var mi := _first_mesh_instance(ps.instantiate())
		ok(mi != null and mi.mesh != null, "★ %d 级模型里有网格" % lvl)
		if mi == null or mi.mesh == null:
			continue
		var arr: Array = mi.mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arr[Mesh.ARRAY_COLOR]
		ok(colors.size() > 0, "★★ %d 级模型带顶点色（COLOR_0）" % lvl)
		var masked := 0
		var plain := 0
		for c in colors:
			if c.a >= 0.5:
				masked += 1
			else:
				plain += 1
		# ★ 这条是老坑：全是 alpha=1 会把整栋染成阵营色（看着像没贴图），
		#   全是 0 又分不清敌我。屋顶 / 尖顶 / 十字 = 1，墙体门窗 = 0。
		ok(masked > 0 and plain > 0,
			"★★ %d 级模型阵营色遮罩正常（a=1 %d / a=0 %d）" % [lvl, masked, plain])
		var box: AABB = mi.mesh.get_aabb()
		near(box.position.y, 0.0, 0.02, "★★ %d 级模型底边在 y = 0（落地不改逻辑）" % lvl)
		near(box.size.y, float(expect_h[lvl]), 0.02,
			"★★ %d 级模型高 %.2f 格" % [lvl, float(expect_h[lvl])])
		# 一格见方（1 单位 = 1 格；body_scale 由 building_view 统一缩放）
		ok(box.size.x <= 1.05 and box.size.z <= 1.05,
			"★ %d 级模型不超过一格（%.2f × %.2f）" % [lvl, box.size.x, box.size.z])
	# 模型只会更「高」，不会更宽 —— 2 级比 1 级高。
	var l1 := load("res://assets/models/church_l1_lowpoly.glb") as PackedScene
	var l2 := load("res://assets/models/church_l2_lowpoly.glb") as PackedScene
	if l1 != null and l2 != null:
		var m1 := _first_mesh_instance(l1.instantiate())
		var m2 := _first_mesh_instance(l2.instantiate())
		if m1 != null and m2 != null:
			ok(m2.mesh.get_aabb().size.y > m1.mesh.get_aabb().size.y,
				"★★ 2 级教堂比 1 级高（升级看得出变化）")


# ==================================================================
# 18) 建筑页（命令卡）：教堂是**额外**一格，且开局就能造
# ==================================================================

## 拿一张建筑页（不建 UI 树，只要 `_build_entries()` 的结果）。
func _build_slots(cfg, level, faction: String) -> Array:
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return []
	var w = WorldRes.create_from_level(cfg, lv, faction, ["p1", "p2"], false)
	var hud = HudRes.new()
	hud.cfg = cfg
	hud.world = w
	var slots: Array = hud._build_entries()
	hud.free()
	return slots


func _slot_of(slots: Array, bid: String) -> Dictionary:
	for s in slots:
		var d: Dictionary = s
		if String(d.get("build_type", "")) == bid:
			return d
	return {}


func _test_build_card(cfg) -> void:
	var church_slots := _build_slots(cfg, null, "p2")   # p2 = 教会军
	var vol_slots := _build_slots(cfg, null, "p1")      # p1 = 义勇军
	if church_slots.is_empty() or vol_slots.is_empty():
		ok(false, "（前提）建筑页能建出来")
		return
	# ① 教会军：通用建筑**一个都不少**，教堂是额外那一格
	var church_entry := _slot_of(church_slots, "church")
	ok(not church_entry.is_empty(), "★★ 教会军的建筑页里有教堂")
	for bid in ["wall", "tower", "farm", "stone_wall", "watch_tower", "house", "mine"]:
		ok(not _slot_of(church_slots, bid).is_empty(),
			"★★ 教会军的建筑页里仍有 %s（额外建筑 ≠ 唯一建筑）" % bid)
	# ② 教堂开局就能造：1 级大本营，ready = true
	eq(int(church_entry.get("min_base", 0)), 1, "★★ 教堂的解锁等级 = 1")
	ok(bool(church_entry.get("ready", false)), "★★ 1 级大本营时教堂牌是可点的")
	# ③ 义勇军：没有教堂这一格
	ok(_slot_of(vol_slots, "church").is_empty(), "★★ 义勇军的建筑页里没有教堂")
	for bid in ["wall", "farm", "mine"]:
		ok(not _slot_of(vol_slots, bid).is_empty(), "★ 义勇军照旧能造 %s" % bid)
	# ④ 老建筑仍按行号解锁（教堂是唯一的例外）
	var sw := _slot_of(vol_slots, "stone_wall")
	if not sw.is_empty():
		eq(int(sw.get("min_base", 0)), 2, "★ 石墙仍是 2 级解锁")
		ok(not bool(sw.get("ready", true)), "★ 1 级大本营时石墙牌还是灰的")
