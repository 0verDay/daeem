## test_story_spawn.gd —— 演出生成：红点、单位 / 将领、建筑。
extends "res://tests/test_case.gd"

const StoryActionsRes = preload("res://logic/story/story_actions.gd")
const StoryDirectorRes = preload("res://logic/story/story_director.gd")
const StoryGlowRes = preload("res://logic/story/story_glow.gd")


func _initialize() -> void:
	_case_name = "test_story_spawn"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_spawn_units(cfg)
	_test_spawn_building(cfg)
	_test_spawn_red_dot(cfg)
	_test_director_steps(cfg)


func _test_spawn_units(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var base: Vector2i = w.home_base_of("p1")
	var before: int = w.units.size()
	var us: Array = StoryActionsRes.spawn_units(w, {
		"faction": "p1", "unit_type": "spearman", "count": 2,
		"spawn": {"tile": [base.x + 2, base.y]}, "tag": "spawned",
	})
	eq(us.size(), 2, "★ 生成 2 个普通单位")
	eq(w.units.size(), before + 2, "★ 单位进了 world.units")
	for u in us:
		eq(String(u.faction), "p1", "单位阵营正确")
		eq(String(u.unit_type), "spearman", "单位兵种正确")
		eq(String(u.tag), "spawned", "★ 单位 tag 正确")
		ok(u.alive, "单位存活")

	var gs: Array = StoryActionsRes.spawn_units(w, {
		"faction": "p1", "general": 1, "name": "剧情将",
		"spawn": {"tile": [base.x - 2, base.y]}, "tag": "story_general",
		"escort_count": 2, "escort_types": [{"type": "spearman", "weight": 1}],
	})
	eq(gs.size(), 1, "★ 生成 1 位将领")
	if not gs.is_empty():
		var g = gs[0]
		eq(String(g.name), "剧情将", "将领名字来自剧本")
		eq(String(g.tag), "story_general", "将领 tag")
		ok(g.is_general(), "确实是将领")
		var escort := 0
		for u in w.units:
			if String(u.leader_id) == String(g.id):
				escort += 1
		eq(escort, 2, "★★ 将领带 2 个附属兵")

	# count = 0 也至少生成 1 个（与红点一致）
	var one: Array = StoryActionsRes.spawn_units(w, {
		"faction": "p1", "unit_type": "spearman", "count": 0,
		"spawn": {"tile": [base.x, base.y]},
	})
	eq(one.size(), 1, "count=0 仍生成 1 个")


func _test_spawn_building(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var tile := _free_tile(w)
	if tile.x < 0:
		ok(false, "（前提）找不到空格")
		return
	var b = StoryActionsRes.spawn_building(w, {
		"faction": "p1", "type": "tower", "spawn": {"tile": [tile.x, tile.y]},
		"tag": "story_tower",
	})
	ok(b != null, "★ 生成建筑")
	if b != null:
		eq(String(b.type), "tower", "建筑类型正确")
		eq(String(b.tag), "story_tower", "★ 建筑 tag 正确")
		ok(not b.is_under_construction(), "★★ 默认跳过建造读条（瞬间出现）")
		eq(w.building_at(tile.x, tile.y), b, "建筑真的落在那一格")


func _test_spawn_red_dot(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var base: Vector2i = w.home_base_of("p1")
	var target := _free_tile(w)
	if target.x < 0:
		return
	var before: int = w.units.size()
	var n: int = StoryActionsRes.spawn_red_dot(w, {
		"faction": "p1",
		"spawn": {"tile": [base.x + 3, base.y + 3]},
		"target": {"tile": [target.x, target.y]},
		"count": 1,
		"escort_count": 1,
		"escort_types": [{"type": "spearman", "weight": 1}],
		"tag": "red_wave",
	})
	eq(n, 1, "★ 生成 1 位红点将领")
	ok(w.units.size() >= before + 2, "红点将领 + 附属兵都进了 world.units")
	var found = null
	for u in w.units:
		if String(u.tag) == "red_wave":
			found = u
			break
	ok(found != null, "★★ 红点将领带 tag")
	if found != null:
		ok(String(found.id).begins_with("reddot-"), "红点 id 前缀正确")
		ok(String(found.leader_id) == "", "红点将领自己是队长")
	var evs: Array = w.tick(0.016)
	var wave := _find(evs, "red_dot_wave")
	ok(not wave.is_empty(), "★ 推了 red_dot_wave（小地图生成动效）")
	if not wave.is_empty():
		eq(int(wave.get("leaders", 0)), 1, "事件里 leaders = 1")
		ok((wave.get("spawns", []) as Array).size() >= 1, "事件里带出生点")


## 确认五个新 step kind 真的被导演分发（拼错时只会 warning，不会报错）。
func _test_director_steps(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var base: Vector2i = w.home_base_of("p1")
	var d = StoryDirectorRes.new()
	d.world = w
	d.on_start([
		{"kind": "spawn_unit", "faction": "p1", "unit_type": "spearman",
			"spawn": {"tile": [base.x + 1, base.y]}, "tag": "step_unit"},
		{"kind": "spawn_building", "faction": "p1", "type": "tower",
			"spawn": {"tile": [base.x + 2, base.y]}, "tag": "step_building"},
		{"kind": "spawn_red_dot", "faction": "p1",
			"spawn": {"tile": [base.x + 3, base.y + 1]},
			"target": {"base": "p1"}, "tag": "step_red"},
		{"kind": "glow_object", "targets": {"tag": "step_unit"}, "id": "step_glow"},
		{"kind": "stop_glow", "id": "step_glow"},
	])
	d.tick(0.0, [])
	ok(not StoryActionsRes.resolve_units(w, {"tag": "step_unit"}).is_empty(),
		"★ 导演执行 spawn_unit")
	ok(not StoryActionsRes.resolve_buildings(w, {"tag": "step_building"}).is_empty(),
		"★ 导演执行 spawn_building")
	ok(not StoryActionsRes.resolve_units(w, {"tag": "step_red"}).is_empty(),
		"★ 导演执行 spawn_red_dot")
	var us := StoryActionsRes.resolve_units(w, {"tag": "step_unit"})
	if not us.is_empty():
		ok((us[0].story_glow as Dictionary).is_empty(),
			"★ 导演执行 glow_object + stop_glow")


# ------------------------------------------------------------------
func _free_tile(w) -> Vector2i:
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			if w.building_at(x, y) != null:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			return Vector2i(x, y)
	return Vector2i(-1, -1)


func _find(events: Array, type: String) -> Dictionary:
	for e in events:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("type", "")) == type:
			return e
	return {}
