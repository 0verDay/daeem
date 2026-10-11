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
## ★ 本轮新增：验「守将去守自己区划中心」这条阵地 AI 逻辑（判据是纯函数 + update 的行为）。
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")
const GridRes = preload("res://logic/grid.gd")

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


## ★★ 本轮新增：自己区划的中心**被敌对势力占领**时，守将立刻行军攻击到中心。
##
## 分两半验：
##   ① 判据 `_center_under_attack()`（纯函数）：敌对 reading/frozen 才算，
##      自己人读条 / decaying / 进度 0 都不算；
##   ② 行为：`update()` 跑一帧之后，守将进入 `defending_center` 且命令目标落在**中心**。
func _test_garrison_defends_center(cfg) -> void:
	var w = _world(cfg, "garrison_defend", {"factions": [{
		"id": "E1", "ai": "garrison", "base": [18, 18]}]})
	ok(w != null, "能造出 garrison 世界（守中心用例）")
	if w == null:
		return
	# 找一位「有归属区划、且是带队守将」的 E1 单位
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

	# ---- ① 判据（纯函数；占领规则本身由 test_zone_capture 覆盖，这里只摆状态）----
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

	# ---- ② 行为：update 一帧 ⇒ 进入守中心，并朝中心下命令 ----
	z["progress"] = 0.2
	g.stop()
	g.drop_engagement()
	ok(not g.defending_center, "（前提）还没进入「守中心」状态")
	GarrisonAiRes.update(w, cfg, 1.0 / 60.0)
	ok(g.defending_center, "★★ 敌对在占我的区划中心 → 守将立刻进入「守中心」")
	ok(g.goal.distance_to(GridRes.center_of(center)) < 3.0,
		"★★ 它接到的命令目标是**区划中心**")

	# ---- 威胁解除 ⇒ 退出守中心（恢复巡逻）----
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
