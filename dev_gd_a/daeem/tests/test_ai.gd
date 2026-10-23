## test_ai.gd —— ★ 本轮的两种 AI：**阵地性 AI**（garrison）+ **红点性 AI**（reddot）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const LevelRes = preload("res://logic/level.gd")

const TMP_ROOT := "res://.tmp_ai_tests"
const MAP_PATH := "res://data/maps/frontier/map.json"

func _initialize() -> void:
	_case_name = "test_ai"
	run_all(_cases)
	_clean_tmp()

func _clean_tmp() -> void:
	if not DirAccess.dir_exists_absolute(TMP_ROOT):
		return
	for f in DirAccess.get_files_at(TMP_ROOT):
		DirAccess.remove_absolute("%s/%s" % [TMP_ROOT, f])
	DirAccess.remove_absolute(TMP_ROOT)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_legacy_kinds(cfg)
	_test_garrison_presence(cfg)
	_test_garrison_zone_assignment(cfg)
	_test_garrison_free_recruit(cfg)
	_test_garrison_revive(cfg)
	_test_reddot_spawn(cfg)
	_test_reddot_spawn_tiles(cfg)
	_test_reddot_random(cfg)

func _test_config(cfg) -> void:
	ok(cfg.ai_garrison_cfg().has("patrol_interval_sec"), "ai.garrison 有巡逻间隔")
	ok(cfg.ai_garrison_cfg().has("min_retinue"), "ai.garrison 有满编门槛")
	ok(cfg.ai_reddot_cfg().has("wave_time_expr"), "ai.reddot 有生成时间表达式")
	ok(cfg.ai_reddot_cfg().has("general_count_expr"), "ai.reddot 有将领数表达式")
	ok(cfg.ai_reddot_cfg().has("general_weights"), "ai.reddot 有将领类型权重")
	ok(cfg.ai_reddot_cfg().has("escort_count"), "ai.reddot 有共享附属单位数量")
	ok(cfg.ai_reddot_cfg().has("spawn_tiles"), "ai.reddot 有生成地块表")
	ok(cfg.ai_reddot_cfg().has("spawn_radius"), "ai.reddot 有生成半径")
	ok(cfg.ai_reddot_cfg().has("waves"), "ai.reddot 有波数")

	var list: Array = cfg.ai_factions()
	ok(list.size() >= 1, "ai.factions 至少一条")
	var first: Dictionary = list[0]
	eq(String(first.get("id", "")), "ai", "默认 AI 阵营 id 是 'ai'")
	eq(String(first.get("ai", "")), "garrison", "缺省 ai 字段 = garrison")
	ok(first.has("base"), "条目带出生锚点 base")
	ok(not first.has("resource_mult"), "★ AI 条目不再带 resource_mult（没有资源库）")
	ok(not first.has("start_food"), "★ 不再带 start_food")
	ok(cfg.is_ai_faction("ai"), "is_ai_faction('ai')")

func _test_legacy_kinds(cfg) -> void:
	eq(LevelRes._ai_kind("faction"), LevelRes.AI_GARRISON, "旧值 faction → garrison")
	eq(LevelRes._ai_kind("general"), LevelRes.AI_GARRISON, "旧值 general → garrison")
	eq(LevelRes._ai_kind("garrison"), LevelRes.AI_GARRISON, "garrison 原样")
	eq(LevelRes._ai_kind("reddot"), LevelRes.AI_REDDOT, "reddot 原样")
	eq(LevelRes._ai_kind("none"), LevelRes.AI_NONE, "none 原样")
	eq(LevelRes._ai_kind("乱写"), LevelRes.AI_NONE, "认不出的 → none")

func _test_garrison_presence(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	ok(w != null, "带 AI 的世界能建出来")
	if w == null:
		return
	_spawn_ai_generals(w, cfg)
	eq(w.ai_kind_of("ai"), LevelRes.AI_GARRISON, "'ai' 是阵地性 AI")
	ok(w.find_base_of("ai") == null, "★ AI 阵营没有大本营建筑")
	ok(w.resource_pool_for("ai") == null, "★ AI 阵营没有资源池（null = 无限）")
	var gens := _generals_of(w, "ai")
	ok(gens.size() >= 1, "AI 阵营有将领（%d 位）" % gens.size())

func _test_garrison_zone_assignment(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	if w == null:
		return
	_spawn_ai_generals(w, cfg)
	var n_zoned := 0
	for g in _generals_of(w, "ai"):
		if int(g.garrison_zone_id) >= 0:
			n_zoned += 1
	ok(n_zoned >= 1, "★ 阵地性 AI 的将领有归属区划（%d 位）" % n_zoned)

func _test_garrison_free_recruit(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	if w == null:
		return
	_spawn_ai_generals(w, cfg)
	var gens := _generals_of(w, "ai")
	if gens.is_empty():
		ok(false, "（前提）AI 要有将领才能验招兵")
		return
	var g = gens[0]
	var z = w.zones.zone_at(g.tx, g.ty)
	if z == null:
		ok(false, "（前提）将领脚下要有区划")
		return
	(z as Dictionary)["owner"] = "ai"
	g.combat_idle_timer = float(cfg.ai_garrison_cfg()["combat_idle_sec"]) + 1.0
	g.garrison_recruit_timer = 0.0
	var before_pop := float(z.get("population", 0.0))
	GarrisonAiRes.update(w, cfg, 0.05)
	ok(g.is_training() or g.train_queue_size() > 0, "★ 脱战满员不足 → 无消耗招兵（进入读条）")
	near(float(z.get("population", 0.0)), before_pop, 1e-6, "★ 免费招兵不动人口")

func _test_garrison_revive(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	if w == null:
		return
	_spawn_ai_generals(w, cfg)
	var gens := _generals_of(w, "ai")
	if gens.is_empty():
		ok(false, "（前提）AI 要有将领才能验再起")
		return
	var g = gens[0]
	g.downed = true
	g.hp = g.hp_max
	g.revive_remaining = 0.0
	ok(g.is_downed(), "（前提）将领处于濒死")
	GarrisonAiRes.update(w, cfg, 0.05)
	ok(g.revive_remaining > 0.0, "★ 濒死将领够条件 → 立刻无消耗再起（进入读条）")

func _test_reddot_spawn(cfg) -> void:
	var w = _reddot_world(cfg)
	if w == null:
		return
	ok(w.reddot_states.size() == 1, "★ 红点状态表里有 1 条（E1）")
	if w.reddot_states.is_empty():
		return
	var st: Dictionary = w.reddot_states[0]
	eq(String(st.get("faction", "")), "E1", "红点阵营是 E1")
	var params: Dictionary = st["params"]
	eq(String(params["wave_time_expr"]), "x+1", "关卡覆盖的生成时间表达式生效")
	eq(String(params["general_count_expr"]), "x+1", "关卡覆盖的将领数表达式生效")
	eq(int(params["escort_count"]), 3, "关卡覆盖的共享附属单位数量生效")
	ok(w.find_base_of("E1") == null, "★ 红点阵营没有大本营")
	ok(w.resource_pool_for("E1") == null, "★ 红点阵营没有资源池")
	eq(_units_of(w, "E1").size(), 0, "红点阵营开局没有单位")
	RedDotAiRes.update(w, cfg, 121.0)
	var units := _units_of(w, "E1")
	eq(units.size(), 8, "★ 一波刷出 2 位满编将领（2×(1+3) = 8 个单位）")
	var gens := _generals_of(w, "E1")
	eq(gens.size(), 2, "★ 其中 2 位是将领")
	var marching := false
	for g in gens:
		if g.moving or not g.path.is_empty():
			marching = true
	ok(marching, "★ 刷出来的将领向目标点行军（已下 command）")

func _test_reddot_spawn_tiles(cfg) -> void:
	var w = _reddot_world(cfg)
	if w == null or w.reddot_states.is_empty():
		return
	var tiles := _passable_tiles(w, cfg, "E1", 3)
	ok(tiles.size() >= 2, "（前提）地图上能找到至少 2 个可通行空地")
	if tiles.size() < 2:
		return
	var cell: Vector2i = tiles[0]
	w.add_building("wall", cell.x, cell.y, "p1", true, true)
	ok(w.building_at(cell.x, cell.y) != null, "（前提）敌对城墙已摆在生成地块上")
	(w.reddot_states[0] as Dictionary)["params"]["spawn_tiles"] = [[cell.x, cell.y]]
	RedDotAiRes.update(w, cfg, 121.0)
	ok(w.building_at(cell.x, cell.y) == null, "★ 生成地块上的敌对建筑被立刻拆除")
	var gens := _generals_of(w, "E1")
	eq(gens.size(), 2, "★ 拆除挡路建筑后，第 1 波 2 位将领照常刷出")
	var all_on := true
	for g in gens:
		if g.tx != cell.x or g.ty != cell.y:
			all_on = false
	ok(all_on, "★ 将领落在配置的生成地块上（允许叠兵同一格）")

	var w2 = _reddot_world(cfg)
	if w2 == null or w2.reddot_states.is_empty():
		return
	var t2 := _passable_tiles(w2, cfg, "E1", 3)
	if t2.size() < 2:
		return
	var a: Vector2i = t2[0]
	var b: Vector2i = t2[1]
	(w2.reddot_states[0] as Dictionary)["params"]["spawn_tiles"] = [[a.x, a.y], [b.x, b.y]]
	RedDotAiRes.update(w2, cfg, 121.0)
	var gens2 := _generals_of(w2, "E1")
	eq(gens2.size(), 2, "★ 配置 2 个生成地块，第 1 波将领照常刷出")
	var all_in := true
	for g in gens2:
		if not ((g.tx == a.x and g.ty == a.y) or (g.tx == b.x and g.ty == b.y)):
			all_in = false
	ok(all_in, "★ 将领只落在配置的生成地块上（随机落点）")

## ★★ 回归：红点必须**每局不同**（用户报「测试很多次，每波敌人都是同一批」）。
##
## 根因：`unit_rand(key, k)` 只用 `(key, k)`，而红点的 key 里只有 `serial`（每局都从 0 开始）
##   ⇒ 同一张图 / 同一关，每局刷出来的将领与落点完全一致。
## 修法：`world.rand_salt` 每局现抽一个，混进 `unit_rand()`；同盐仍可复现（测试 / 回放）。
func _test_reddot_random(cfg) -> void:
	var w1 = _reddot_world(cfg)
	var w2 = _reddot_world(cfg)
	var w3 = _reddot_world(cfg)
	if w1 == null or w2 == null or w3 == null:
		return
	w1.set_rand_salt(1234)
	w2.set_rand_salt(1234)
	w3.set_rand_salt(9999)

	eq(w1.unit_rand("reddot-spawn|E1|0", 0), w2.unit_rand("reddot-spawn|E1|0", 0),
		"★ 同一个盐 ⇒ 同一个随机数（可复现）")
	ok(w1.unit_rand("reddot-spawn|E1|0", 0) != w3.unit_rand("reddot-spawn|E1|0", 0),
		"★★ 不同盐 ⇒ 不同随机数（不再每局一样）")

	var sig1 := _wave_signature(w1, cfg)
	var sig2 := _wave_signature(w2, cfg)
	var sig3 := _wave_signature(w3, cfg)
	eq(sig1, sig2, "★ 同盐的两局：三波红点完全一致（测试可复现）")
	ok(sig1 != sig3, "★★ 不同盐的两局：三波红点不同（%s vs %s）" % [sig1, sig3])


## 连刷三波，把「将领类型 + 落点」拼成签名。
func _wave_signature(w, cfg) -> String:
	var parts: Array = []
	for t in [61.0, 121.0, 181.0]:
		var st: Dictionary = w.reddot_states[0]
		RedDotAiRes.update(w, cfg, t - float(st.get("elapsed", 0.0)))
		for u in w.units:
			if u.alive and String(u.faction) == "E1" and u.is_general():
				parts.append("%s@%d,%d" % [String(u.unit_type), u.tx, u.ty])
	return "|".join(parts)


func _passable_tiles(w, cfg, faction: String, need: int) -> Array:
	var out: Array = []
	for y in w.map.rows:
		for x in w.map.cols:
			if out.size() >= need:
				return out
			if w.building_at(x, y) != null:
				continue
			if PathfinderRes.passable(w.map, w.buildings, cfg, x, y, faction):
				out.append(Vector2i(x, y))
	return out

## ★ 新口径：AI 阵营不再自动生成开局将领。这组用例验的是「AI 逻辑」本身，
##   所以手动给它摆 3 位（并补齐归属区划），不改游戏的生产行为。
func _spawn_ai_generals(w, cfg) -> void:
	if w == null:
		return
	for f in w.factions:
		if w.ai_kind_of(String(f)) != LevelRes.AI_GARRISON:
			continue
		if not _generals_of(w, String(f)).is_empty():
			continue
		var from: int = w.units.size()
		for i in 3:
			var g = w.create_general(String(f), i, i)
			if g != null:
				w.units.append(g)
		w._assign_garrison_zones(String(f), from)


func _generals_of(w, faction: String) -> Array:
	var out: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == faction and u.is_general():
			out.append(u)
	return out

func _units_of(w, faction: String) -> Array:
	var out: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == faction:
			out.append(u)
	return out

func _reddot_world(cfg) -> RefCounted:
	var level_json := {
		"map": "frontier",
		"name": "reddot probe",
		"players": [{"faction": "p1"}],
		"factions": [{
			"id": "E1", "ai": "reddot", "base": [18, 18],
			"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 3},
			"attack_target": {"kind": "point", "x": 7, "y": 2},
			"reddot_ai": {"wave_time_expr": "x+1", "general_count_expr": "x+1",
				"escort_count": 3, "spawn_radius": 3,
				# ★ 给随机测试用：多个生成地块 + 三种将领权重（否则落点/类型恒定，
				#   连「不同随机盐」都验不出来 —— 第一版就是这么假绿的）。
				"spawn_tiles": [[16, 16], [17, 17], [18, 18], [19, 19],
					[20, 20], [21, 21], [15, 18], [18, 15]],
				"general_weights": [{"general": 1, "weight": 0.34},
					{"general": 2, "weight": 0.33}, {"general": 3, "weight": 0.33}]},
		}],
		"start_units": [],
	}
	DirAccess.make_dir_recursive_absolute(TMP_ROOT)
	var path := "%s/reddot_probe.json" % TMP_ROOT
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写红点探针关卡")
		return null
	f.store_string(JSON.stringify(level_json))
	f.close()
	var lcls := script_at("res://logic/level.gd")
	if lcls == null:
		return null
	var lv = lcls.load_level(null, path, cfg)
	if lv == null:
		ok(false, "红点探针关卡能载入")
		return null
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)
	ok(w != null, "红点世界能建出来")
	return w
