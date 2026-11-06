## test_story_tags.gd —— 关卡 `start_units[].tag` / `start_buildings[].tag` 的单向落点。
##
## 只验运行时：Level 读入 → World 装配 → Unit.tag / Building.tag → 演出目标解析。
## 编辑器侧的读写往返由 `tools/campaign_editor/test_model.py` 覆盖。
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const StoryActionsRes = preload("res://logic/story/story_actions.gd")

const TMP_LEVEL := "res://.tmp_story_tags/level.json"


func _initialize() -> void:
	_case_name = "test_story_tags"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var probe = WorldRes.create(cfg, "res://data/maps/frontier/map.json", false)
	if probe == null:
		return
	var base: Vector2i = probe.faction_bases.get("p1", Vector2i(5, 5))
	var unit_tile := _free_tile(probe, base, 1)
	var building_tile := _free_tile(probe, base, 2)
	if unit_tile.x < 0 or building_tile.x < 0:
		ok(false, "（前提）找得到两个空位")
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_LEVEL.get_base_dir()))
	var data := {
		"name": "tag test",
		"mode": "solo",
		"map": "frontier",
		"players": [{"faction": "p1", "base": [base.x, base.y]}],
		"factions": [{"id": "p1", "playable": true}],
		"start_units": [{
			"faction": "p1", "kind": "general_1", "general_index": 1,
			"unit_type": "spearman", "x": unit_tile.x, "y": unit_tile.y,
			"tag": "hero",
		}],
		"start_buildings": [{
			"type": "tower", "x": building_tile.x, "y": building_tile.y,
			"owner": "p1", "tag": "north_gate",
		}],
	}
	var f := FileAccess.open(TMP_LEVEL, FileAccess.WRITE)
	if f == null:
		ok(false, "写临时关卡失败")
		return
	f.store_string(JSON.stringify(data))
	f.close()

	var lv = LevelRes.load_level(null, TMP_LEVEL, cfg)
	ok(lv != null, "关卡能载入")
	if lv == null:
		_cleanup()
		return
	eq(String((lv.start_units[0] as Dictionary).get("tag", "")), "hero",
		"★ Level 读入 start_units[].tag")
	eq(String((lv.start_buildings[0] as Dictionary).get("tag", "")), "north_gate",
		"★ Level 读入 start_buildings[].tag")

	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], false)
	ok(w != null, "世界能装配")
	if w != null:
		var us := StoryActionsRes.resolve_units(w, {"tag": "hero"})
		eq(us.size(), 1, "★★ start_units[].tag 落到 Unit.tag，演出能按 tag 找到")
		if not us.is_empty():
			eq(String(us[0].tag), "hero", "单位 tag 正确")
		var bs := StoryActionsRes.resolve_buildings(w, {"tag": "north_gate"})
		eq(bs.size(), 1, "★★ start_buildings[].tag 落到 Building.tag")
		if not bs.is_empty():
			eq(String(bs[0].tag), "north_gate", "建筑 tag 正确")
	_cleanup()


func _free_tile(w, base: Vector2i, skip: int) -> Vector2i:
	var found := 0
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			var t := Vector2i(x, y)
			if t == base:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			if w.building_at(x, y) != null:
				continue
			found += 1
			if found >= skip:
				return t
	return Vector2i(-1, -1)


func _cleanup() -> void:
	var p := ProjectSettings.globalize_path(TMP_LEVEL)
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
	var d := ProjectSettings.globalize_path(TMP_LEVEL.get_base_dir())
	if DirAccess.dir_exists_absolute(d):
		DirAccess.remove_absolute(d)
