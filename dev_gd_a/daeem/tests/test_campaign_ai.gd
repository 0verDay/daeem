## test_campaign_ai.gd —— 关卡里的 AI 指派（本轮口径）。
##
## 盯的是「不写就会静默错」的那一类：
##   · 关卡 `factions[].ai`（garrison / reddot / none）落到世界上的 `ai_kind_of`；
##   · AI 阵营**没有大本营、没有资源池**（本轮口径）；
##   · 关卡按阵营覆盖的 `garrison_ai` / `reddot_ai` 参数**真的生效**；
##   · `ai: none` 的阵营这一局不动。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")

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
	_test_reddot_cfg(cfg)
	_test_none_and_player(cfg)


func _test_garrison(cfg) -> void:
	var w = _world(cfg, "garrison", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18],
		"garrison_ai": {"min_retinue": 7},
	}]})
	ok(w != null, "能造出 garrison 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_GARRISON, "E1 是阵地性 AI")
	ok(w.find_base_of("E1") == null, "★ AI 阵营没有大本营")
	eq(int(w.garrison_ai_cfg("E1").get("min_retinue", -1)), 7, "★ 关卡 garrison_ai 覆盖生效")
	# 有将领（阵地性 AI 靠它巡逻 / 招兵）。
	var gens := 0
	for u in w.units:
		if u.alive and String(u.faction) == "E1" and u.is_general():
			gens += 1
	ok(gens >= 1, "E1 有将领（%d 位）" % gens)


func _test_reddot_cfg(cfg) -> void:
	var w = _world(cfg, "reddot", {"factions": [{
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 2},
		"attack_target": {"kind": "point", "x": 2, "y": 11},
		"reddot_ai": {"cooldown_sec": 42, "generals": 3, "retinue": 5},
	}]})
	ok(w != null, "能造出 reddot 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_REDDOT, "E1 是红点性 AI")
	eq(int(w.reddot_ai_cfg("E1").get("cooldown_sec", -1)), 42, "★ 关卡 reddot_ai 覆盖生效")
	eq(int(w.reddot_ai_cfg("E1").get("retinue", -1)), 5, "★ 每位满编数按关卡覆盖")
	ok(w.reddot_states.size() == 1, "红点状态表建了一条（E1）")
	if w.reddot_states.size() == 1:
		eq(String((w.reddot_states[0] as Dictionary).get("faction", "")), "E1", "那一方是 E1")


func _test_none_and_player(cfg) -> void:
	var w = _world(cfg, "none", {"factions": [
		{"id": "E1", "ai": "none", "base": [18, 18]}]})
	ok(w != null, "能造出 none 关卡世界")
	if w == null:
		return
	eq(w.ai_kind_of("E1"), LevelRes.AI_NONE, "★ ai: none 的阵营这一局不动")
	eq(w.ai_kind_of("p1"), LevelRes.AI_NONE, "★ 玩家席位不算 AI")
	# 玩家才有大本营。
	ok(w.find_base_of("p1") != null, "玩家 p1 有大本营")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

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
