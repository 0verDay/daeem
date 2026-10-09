## test_ai.gd —— ★ 本轮的两种 AI：**阵地性 AI**（garrison）+ **红点性 AI**（reddot）。
##
## 覆盖（每条对着需求口径写）：
##   A. 配置与名单
##      · `ai.factions` 条目形状（{id, ai, base}）、`ai.garrison` / `ai.reddot` 参数表；
##      · 关卡 `ai` 取值归一：旧值 faction / general → **garrison**；新值 reddot / none；
##      · 合并名单**不再带** resource_mult / start_food / start_gold（AI 没有资源库）。
##   B. 阵地性 AI（garrison_ai.gd）
##      · 附属区划落到单位（`garrison_zone_id`）、脱战无消耗招兵；
##      · **没有资源池 / 没有大本营**（resource_pool_for 返回 null、find_base_of 返回 null）；
##      · 濒死将领血量回到门槛 → **立刻无消耗再起**（本轮口径）。
##   C. 红点性 AI（red_dot_ai.gd）
##      · 按长冷却在 `spawn_region` 刷一波**满编**将领；刷出来的将领向目标点行军。
##
## ⚠️ `--script` 跑的：跨文件引用只用自己的 preload 常量。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")
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


# ---- A. 配置 / 名单 ----

func _test_config(cfg) -> void:
	ok(cfg.ai_garrison_cfg().has("patrol_interval_sec"), "ai.garrison 有巡逻间隔")
	ok(cfg.ai_garrison_cfg().has("min_retinue"), "ai.garrison 有满编门槛")
	ok(cfg.ai_reddot_cfg().has("cooldown_sec"), "ai.reddot 有冷却")
	ok(cfg.ai_reddot_cfg().has("generals"), "ai.reddot 有每波将领数")
	ok(cfg.ai_reddot_cfg().has("retinue"), "ai.reddot 有每位满编数")
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


# ---- B. 阵地性 AI ----

func _test_garrison_presence(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	ok(w != null, "带 AI 的世界能建出来")
	if w == null:
		return
	eq(w.ai_kind_of("ai"), LevelRes.AI_GARRISON, "'ai' 是阵地性 AI")
	# ★ AI 没有大本营（本轮口径：只有玩家有大本营）。
	ok(w.find_base_of("ai") == null, "★ AI 阵营没有大本营建筑")
	# ★ AI 没有资源库 → null = 资源无限。
	ok(w.resource_pool_for("ai") == null, "★ AI 阵营没有资源池（null = 无限）")
	# 但它有将领（阵地性 AI 靠将领巡逻 / 招兵）。
	var gens := _generals_of(w, "ai")
	ok(gens.size() >= 1, "AI 阵营有将领（%d 位）" % gens.size())


func _test_garrison_zone_assignment(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	if w == null:
		return
	# 阵地性 AI 的将领都该有归属区划（出生格所在区划兜底）。
	var n_zoned := 0
	for g in _generals_of(w, "ai"):
		if int(g.garrison_zone_id) >= 0:
			n_zoned += 1
	ok(n_zoned >= 1, "★ 阵地性 AI 的将领有归属区划（%d 位）" % n_zoned)


func _test_garrison_free_recruit(cfg) -> void:
	var w = WorldRes.create(cfg, MAP_PATH, true)
	if w == null:
		return
	var gens := _generals_of(w, "ai")
	if gens.is_empty():
		ok(false, "（前提）AI 要有将领才能验招兵")
		return
	var g = gens[0]
	var z = w.zones.zone_at(g.tx, g.ty)
	if z == null:
		ok(false, "（前提）将领脚下要有区划")
		return
	# 让这块地归 AI（本轮 AI 没有大本营，不会自动占地）—— 招募要求「在己方区划内」。
	(z as Dictionary)["owner"] = "ai"
	# 备好条件：脱战够久 + 检查计时器到点 + 未满员。
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
	var gens := _generals_of(w, "ai")
	if gens.is_empty():
		ok(false, "（前提）AI 要有将领才能验再起")
		return
	var g = gens[0]
	# 让它濒死且血量到门槛之上。
	g.downed = true
	g.hp = g.hp_max
	g.revive_remaining = 0.0
	ok(g.is_downed(), "（前提）将领处于濒死")
	GarrisonAiRes.update(w, cfg, 0.05)
	ok(g.revive_remaining > 0.0, "★ 濒死将领够条件 → 立刻无消耗再起（进入读条）")


# ---- C. 红点性 AI ----

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
	near(float(params["cooldown_sec"]), 10.0, 1e-6, "关卡覆盖的冷却生效")
	eq(int(params["generals"]), 2, "关卡覆盖的每波将领数生效")
	eq(int(params["retinue"]), 3, "关卡覆盖的每位满编数生效")
	# E1 没有大本营 / 资源池（红点也不需要）。
	ok(w.find_base_of("E1") == null, "★ 红点阵营没有大本营")
	ok(w.resource_pool_for("E1") == null, "★ 红点阵营没有资源池")
	# 初始没有 E1 的单位（红点不预置将领）。
	eq(_units_of(w, "E1").size(), 0, "红点阵营开局没有单位")
	# 推进冷却 → 刷一波。
	RedDotAiRes.update(w, cfg, 11.0)
	var units := _units_of(w, "E1")
	# 2 位将领 ×（1 自己 + 3 满编）= 8 个单位。
	eq(units.size(), 8, "★ 一波刷出 2 位满编将领（2×4 = 8 个单位）")
	var gens := _generals_of(w, "E1")
	eq(gens.size(), 2, "★ 其中 2 位是将领")
	# 将领带着整队向目标点行军（下过命令：有路径或已移动）。
	var marching := false
	for g in gens:
		if g.moving or not g.path.is_empty():
			marching = true
	ok(marching, "★ 刷出来的将领向目标点行军（已下 command）")


# ---- 工具 ----

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


## 造一个「只有 p1 玩家 + 一个红点阵营 E1」的世界（探针关卡）。
func _reddot_world(cfg) -> RefCounted:
	var level_json := {
		"map": "frontier",
		"name": "reddot probe",
		"players": [{"faction": "p1"}],
		"factions": [{
			"id": "E1", "ai": "reddot", "base": [18, 18],
			"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 3},
			"attack_target": {"kind": "point", "x": 7, "y": 2},
			"reddot_ai": {"cooldown_sec": 10, "generals": 2, "retinue": 3, "spawn_radius": 3},
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
