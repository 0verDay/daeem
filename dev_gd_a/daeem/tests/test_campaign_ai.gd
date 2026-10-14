## test_campaign_ai.gd —— 关卡里的 AI 指派（本轮口径）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const GridRes = preload("res://logic/grid.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")

const TMP_ROOT := "res://.tmp_campaign_ai_tests"
const MAP_ID := "frontier"

func _initialize() -> void:
	_case_name = "test_campaign_ai"
	run_all(_cases)
	_clean_tmp()

func _clean_tmp() -> void:
	if DirAccess.dir_exists_absolute(TMP_ROOT):
		_remove_dir(TMP_ROOT)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_garrison(cfg)
	_test_garrison_defends_center(cfg)
	_test_reddot_cfg(cfg)
	_test_reddot_march_tiles(cfg)
	_test_none_and_player(cfg)
	_test_general_roster_profile(cfg)

func _test_general_roster_profile(cfg) -> void:
	var w = _world(cfg, "gen_roster", {
		"factions": [{"id": "E1", "ai": "none", "base": [18, 18]}],
		"start_units": [{"faction": "E1", "kind": "general", "unit_type": "rider",
			"general_index": 5, "x": 18, "y": 18}]})
	if w == null:
		return
	var g = w.unit_by_id("general-E1-5")
	ok(g != null, "★ 名册号 5 → 运行时 id 是 general-E1-5（序号只决定 id）")
	if g == null:
		return
	eq(String(g.unit_type), "rider", "★ 兵种由「哪个将领」决定（这里选了骑手）")
	eq(g.hp_max, cfg.unit_hp_of("rider"), "★ 数值按骑手那一档（与名册号 5 无关）")
	eq(int(g.general_index), cfg.general_slot_of_type("rider"),
		"★ 单位记的将领档 = 兵种在将领表里的下标（不是名册号 5）")

func _test_garrison(cfg) -> void:
	var w = _world(cfg, "garrison", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18],
		"garrison_ai": {"min_retinue": 7},
	}], "start_units": [{"faction": "E1", "kind": "general", "unit_type": "spearman",
		"x": 17, "y": 17, "ai": "garrison", "zone": 9}]})
	ok(w != null, "能造出 garrison 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_GARRISON, "E1 是阵地性 AI")
	ok(w.find_base_of("E1") == null, "★ AI 阵营没有大本营")
	eq(int(w.garrison_ai_cfg("E1").get("min_retinue", -1)), 7, "★ 关卡 garrison_ai 覆盖生效")
	var gens := 0
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and u.is_general():
			gens += 1
	ok(gens >= 1, "E1 有将领（%d 位）" % gens)

func _test_garrison_defends_center(cfg) -> void:
	var w = _world(cfg, "garrison_defend", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18]}],
		"start_units": [{"faction": "E1", "kind": "general", "unit_type": "spearman",
			"x": 17, "y": 16, "ai": "garrison", "zone": 9}]})
	ok(w != null, "能造出 garrison 世界（守中心用例）")
	if w == null:
		return
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and int(u.garrison_zone_id) >= 0 \
				and GarrisonAiRes.is_patrol_leader(w, u):
			g = u
			break
	ok(g != null, "E1 有一位「有归属区划」的带队守将")
	if g == null:
		return
	var z: Dictionary = w.zone_by_id(int(g.garrison_zone_id))
	ok(z != null and z.get("center", null) != null, "它负责的区划有中心")
	if z == null or z.get("center", null) == null:
		return
	var center: Vector2i = z["center"]

	z["capture_state"] = "reading"
	z["capture_faction"] = "enemy"
	z["progress"] = 0.2
	ok(GarrisonAiRes._center_under_attack(w, g, z), "★ 判据：敌对在读条 ⇒ 中心被攻击")
	z["capture_faction"] = String(g.faction)
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "自己人在读条不算威胁")
	z["capture_faction"] = "enemy"
	z["capture_state"] = "frozen"
	ok(GarrisonAiRes._center_under_attack(w, g, z),
		"★ 冻住（双方同场、谁都没涨）**仍然算威胁**（敌人还在场上）")
	z["capture_state"] = "decaying"
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "★ 敌人在退（decaying）不算威胁")
	z["capture_state"] = "reading"
	z["progress"] = 0.0
	ok(not GarrisonAiRes._center_under_attack(w, g, z), "进度为 0 不算威胁")

	z["progress"] = 0.2
	g.stop()
	g.drop_engagement()
	ok(not g.defending_center, "（前提）还没进入「守中心」状态")
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(g.defending_center, "★★ 敌对在占我的区划中心 → 守将立刻进入「守中心」")
	ok(g.goal.distance_to(GridRes.center_of(center)) < 3.0,
		"★★ 它接到的命令目标是**区划中心**")

	z["capture_state"] = ""
	z["capture_faction"] = ""
	z["progress"] = 0.0
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(not g.defending_center, "★ 威胁解除 → 退出「守中心」，恢复正常巡逻")

func _test_reddot_cfg(cfg) -> void:
	var w = _world(cfg, "reddot", {"factions": [{
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 2},
		"attack_target": {"kind": "point", "x": 2, "y": 11},
		"reddot_ai": {"wave_time_expr": "2x+1", "general_count_expr": "x+2", "escort_count": 5},
	}]})
	ok(w != null, "能造出 reddot 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_REDDOT, "E1 是红点性 AI")
	eq(String(w.reddot_ai_cfg("E1").get("wave_time_expr", "")), "2x+1", "★ 关卡 reddot_ai 覆盖生效")
	eq(int(w.reddot_ai_cfg("E1").get("escort_count", -1)), 5, "★ 共享附属单位数量按关卡覆盖")
	ok(w.reddot_states.size() == 1, "红点状态表建了一条（E1）")
	if w.reddot_states.size() == 1:
		eq(String((w.reddot_states[0] as Dictionary).get("faction", "")), "E1", "那一方是 E1")

## ★★ 关卡里那一方的 `reddot_ai` fixture（`rd_extra` 是额外的覆盖键，通常给 march_tiles）。
func _reddot_fac(rd_extra: Dictionary) -> Dictionary:
	var rd := {"general_count_expr": "2"}
	for k in rd_extra.keys():
		rd[k] = rd_extra[k]
	return {
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 2},
		"attack_target": {"kind": "point", "x": 1, "y": 1},
		"reddot_ai": rd,
	}

func _test_reddot_march_tiles(cfg) -> void:
	# ★★ 走**真实数据路径**：`march_tiles` 写在**关卡 JSON** 的 `reddot_ai` 里，
	#    由 `config.ai.reddot` ⊕ 关卡覆盖合并进 `params`。
	#    ⚠️ 这条用例原来是把 `w.reddot_states[0]["params"]["march_tiles"]` **直接赋值**的 ——
	#    绕开了合并，于是「config 漏声明 march_tiles ⇒ 关卡这个键被白名单丢掉」的 bug
	#    一直测不出来（红点将领只会退回单点目标，永远不按 march_tiles 随机行军）。
	var t1 := Vector2i(18, 18)
	var t2 := Vector2i(19, 18)
	var pts: Array = RedDotAiRes._march_points([[t1.x, t1.y], [t2.x, t2.y]])
	eq(pts.size(), 2, "★ `_march_points` 解析出 2 个目标点")
	eq(pts[0], GridRes.center_of(t1), "★ 目标点 = 那一格的中心")

	# 1) 先造一个**不写** march_tiles 的探针世界，只为挑两个可站人的格子当行军目标。
	var probe = _world(cfg, "reddot_march_probe", {"factions": [_reddot_fac({})]})
	ok(probe != null, "能造出 reddot 探针世界（march_tiles 用例）")
	if probe == null:
		return
	var near: Array = []
	for r in range(0, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if near.size() >= 2:
					break
				var t := Vector2i(18 + dx, 18 + dy)
				if near.has(t):
					continue
				if not probe.map.tile_exists(t.x, t.y) or not probe.map.terrain_walkable(t.x, t.y):
					continue
				if probe.building_at(t.x, t.y) != null:
					continue
				near.append(t)
	ok(near.size() >= 2, "找到两个可站人的格子当行军目标")
	if near.size() < 2:
		return
	var raw: Array = []
	for t in near:
		raw.append([t.x, t.y])

	# 2) 把这两个格子写进**关卡数据**，造真正的世界。
	var w = _world(cfg, "reddot_march", {"factions": [_reddot_fac({"march_tiles": raw})]})
	ok(w != null, "能造出 reddot 关卡世界（march_tiles 用例）")
	if w == null or w.reddot_states.is_empty():
		ok(false, "红点状态表建起来了")
		return
	# ★★ 根因断言：关卡写的 march_tiles 必须经 `config.ai.reddot` 的声明合并进 params
	#    （漏声明 ⇒ `world._ai_cfg_with_override` 的白名单把它丢掉，这一条当场变红）。
	ok(not w.reddot_ai_cfg("E1").get("march_tiles", []).is_empty(),
		"★★ 关卡 `reddot_ai.march_tiles` 经 config 合并进了 params")

	RedDotAiRes.update(w, cfg, 61.0)
	var goals: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and u.is_general():
			goals.append(u.goal)
	ok(goals.size() >= 1, "★ 第 1 波刷出了将领（%d 位）" % goals.size())
	var allowed: Array = []
	for t in near:
		allowed.append(GridRes.center_of(t))
	for g in goals:
		var hit := false
		for c in allowed:
			if (g as Vector2).distance_to(c) < 3.0:
				hit = true
		ok(hit, "★★ 每一位将领的行军目标都落在 march_tiles 里（%s）" % str(g))

func _test_none_and_player(cfg) -> void:
	var w = _world(cfg, "none", {"factions": [
		{"id": "E1", "ai": "none", "base": [18, 18]}]})
	ok(w != null, "能造出 none 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_NONE, "★ ai: none 的阵营这一局不动")
	eq(w.ai_kind_of("p1"), LevelRes.AI_NONE, "★ 玩家席位不算 AI")
	ok(w.find_base_of("p1") != null, "玩家 p1 有大本营")

func _world(cfg, name: String, patch: Dictionary):
	var level_json := {
		"map": MAP_ID, "name": name,
		"players": [{"faction": "p1"}],
		"start_units": [],
	}
	for k in patch.keys():
		level_json[k] = patch[k]
	var path := "%s/%s.json" % [TMP_ROOT, name]
	_write(path, JSON.stringify(level_json))
	var lcls := script_at("res://logic/level.gd")
	if lcls == null:
		return null
	var lv = lcls.load_level(null, path, cfg)
	if lv == null:
		ok(false, "关卡能载入：%s" % name)
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)

func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写临时关卡：%s" % path)
		return
	f.store_string(text)
	f.close()

func _remove_dir(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
