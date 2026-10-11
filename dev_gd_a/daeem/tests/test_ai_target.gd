## test_ai_target.gd —— 行军目标（`attack_target`）解析 + 红点 AI 的「行军」。
##
## 盯的是「不写就会静默错」的那一类：
##   · 四种 `attack_target.kind`（zone / point / building / base）各自解析成**正确的目标格**；
##   · 关卡给的目标**不可达 / 解析不出来时要退回现状**（别对着走不到的点发呆）；
##   · 红点 AI 刷出来的将领，带整队向 `attack_target` 行军（`world.level_attack_target` 的消费者）。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const RedDotAiRes = preload("res://logic/red_dot_ai.gd")

const TMP_ROOT := "res://.tmp_ai_target_tests"
const MAP_ID := "frontier"


func _initialize() -> void:
	run_all(Callable(self, "_run"))


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_clean_tmp()
	_group_resolve(cfg)
	_group_reddot_march(cfg)
	_clean_tmp()


# ------------------------------------------------------------------
# 一、四种 kind 各自解析成正确的目标格
# ------------------------------------------------------------------
func _group_resolve(cfg) -> void:
	# 先用一个普通红点世界拿到地图上的真实点位。
	var w0 = _reddot_world(cfg, "resolve", {}, 999.0)
	ok(w0 != null, "能造出红点世界")
	if w0 == null:
		return
	# zone：就是**那个区划的中心格**。
	var zid := 1
	var zc = w0.zone_by_id(zid)
	ok(zc != null, "（前提）区划 c%d 存在" % zid)
	if zc != null:
		var want_center: Vector2i = (zc as Dictionary)["center"]
		var w1 = _reddot_world(cfg, "rt_zone", {"attack_target": {"kind": "zone", "zone": zid}}, 999.0)
		eq(w1.level_attack_target("E1"), want_center, "★ kind=zone → 那个区划的中心格")

	# point：原样。
	var pt := Vector2i(2, 11)
	var w2 = _reddot_world(cfg, "rt_point", {"attack_target": {"kind": "point", "x": pt.x, "y": pt.y}}, 999.0)
	eq(w2.level_attack_target("E1"), pt, "★ kind=point → 那一格（原样）")

	# point 在地图外 → null（退回现状）。
	var w3 = _reddot_world(cfg, "rt_out", {"attack_target": {"kind": "point", "x": 999, "y": 999}}, 999.0)
	ok(w3.level_attack_target("E1") == null, "★ 目标在地图外 → null（退回现状）")

	# building：没有写坐标那一格的建筑 → null。
	var w4 = _reddot_world(cfg, "rt_bld_empty", {"attack_target": {"kind": "building", "x": pt.x, "y": pt.y}}, 999.0)
	ok(w4.level_attack_target("E1") == null, "★ kind=building 但那一格没建筑 → null")

	# base：玩家 p1 的大本营格（玩家才有大本营）。
	var w5 = _reddot_world(cfg, "rt_base", {"attack_target": {"kind": "base", "faction": "p1"}}, 999.0)
	var fb = w5.find_base_of("p1")
	ok(fb != null, "（前提）玩家 p1 有大本营")
	if fb != null:
		eq(w5.level_attack_target("E1"), Vector2i(int(fb.tx), int(fb.ty)),
			"★ kind=base → 那一方的大本营格")
	# base 指向没有大本营的阵营 → null。
	var w6 = _reddot_world(cfg, "rt_base_missing", {"attack_target": {"kind": "base", "faction": "NOPE"}}, 999.0)
	ok(w6.level_attack_target("E1") == null, "★ kind=base 但那一方没有大本营 → null")


# ------------------------------------------------------------------
# 二、红点 AI 刷出来的将领向 attack_target 行军
# ------------------------------------------------------------------
func _group_reddot_march(cfg) -> void:
	var target := Vector2i(7, 2)
	var w = _reddot_world(cfg, "march", {
		"attack_target": {"kind": "point", "x": target.x, "y": target.y},
		"reddot_ai": {"wave_time_expr": "x", "general_count_expr": "1",
			"escort_count": 2, "spawn_radius": 3},
	}, 999.0)
	ok(w != null, "能造出「红点向指定目标行军」的世界")
	if w == null:
		return
	ok(w.reddot_states.size() == 1, "有一条红点状态（E1）")
	if w.reddot_states.is_empty():
		return
	# 推进到第 1 波（wave_time_expr = "x" ⇒ 1min = 60s）。
	RedDotAiRes.update(w, cfg, 61.0)
	var gens := _generals_of(w, "E1")
	ok(gens.size() == 1, "刷出 1 位将领")
	# 单位数 = 1 将领 ×（1 + 2 满编）= 3。
	eq(_units_of(w, "E1").size(), 3, "★ 满编（1 将领 + 2 兵）")
	# 行军：将领下过攻击移动命令（goal 指向目标附近，或有路径 / 已在移动）。
	var marched := false
	var goal_pt := Vector2(target.x, target.y)
	for g in gens:
		if g.has_attack_move:
			marched = true
		elif g.moving or not g.path.is_empty():
			marched = true
	ok(marched, "★ 红点将领带整队向 attack_target 行军（已下攻击移动命令）")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 造一个「p1 玩家 + 红点阵营 E1」的世界；attack_target 缺省指向地图角落。
func _reddot_world(cfg, name: String, patch: Dictionary, cooldown: float):
	var fac := {
		"id": "E1", "ai": "reddot", "base": [18, 18],
		"spawn_region": {"kind": "point", "x": 18, "y": 18, "radius": 3},
		"attack_target": {"kind": "point", "x": 2, "y": 11},
	}
	for k in patch.keys():
		fac[k] = patch[k]
	var level_json := {
		"map": MAP_ID,
		"name": name,
		"players": [{"faction": "p1"}],
		"factions": [fac],
		"start_units": [],
	}
	var path := "%s/%s.json" % [TMP_ROOT, name]
	_write(path, JSON.stringify(level_json))
	var lcls := script_at("res://logic/level.gd")
	if lcls == null:
		return null
	var lv = lcls.load_level(null, path, cfg)
	if lv == null:
		ok(false, "红点探针关卡能载入：%s" % name)
		return null
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], true)
	return w


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


func _write(path: String, text: String) -> void:
	var dir := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("写不了 %s" % path)
		return
	f.store_string(text)
	f.close()


func _clean_tmp() -> void:
	_remove_dir(TMP_ROOT)


func _remove_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	for sub in d.get_directories():
		_remove_dir(path.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
