## test_story_glow.gd —— 演出「呼吸泛光」的状态 / 曲线 / 停止。
extends "res://tests/test_case.gd"

const StoryActionsRes = preload("res://logic/story/story_actions.gd")
const StoryGlowRes = preload("res://logic/story/story_glow.gd")


func _initialize() -> void:
	_case_name = "test_story_glow"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_unit_glow(cfg)
	_test_building_glow(cfg)
	_test_stop_by_id(cfg)
	_test_duration(cfg)


func _test_unit_glow(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var u = w.create_general("p1", 0, 900)
	if u == null:
		return
	u.tag = "hero"
	w.units.append(u)
	var n: int = StoryActionsRes.glow_objects(w, {
		"targets": {"tag": "hero"}, "color": "faction",
		"period": 1.0, "strength": 0.8, "id": "focus",
	})
	eq(n, 1, "★ 按 tag 命中单位")
	ok(not (u.story_glow as Dictionary).is_empty(), "★ 单位写上泛光状态")
	eq(String((u.story_glow as Dictionary).get("id", "")), "focus", "id 正确")
	# t=0 时淡入从 0 开始；推进 0.5 秒后应在呼吸区间内
	w.time = 0.5
	var v: float = StoryGlowRes.value(u, w.time)
	ok(v > 0.0 and v <= 0.8, "★★ 0.5s 后呼吸强度在 (0, strength] 内（%.3f）" % v)
	eq(StoryGlowRes.color_hex(u, w), cfg.faction_color("p1").to_html(false),
		"★★ color=faction 解析成阵营色")


func _test_building_glow(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var tile := _free_tile(w)
	if tile.x < 0:
		return
	var b = w.add_building("tower", tile.x, tile.y, "p1", true, true, "glow_tower")
	if b == null:
		return
	var n: int = StoryActionsRes.glow_objects(w, {
		"targets": {"tag": "glow_tower"}, "color": "#ff00ff",
		"period": 1.0, "id": "tower_focus",
	})
	eq(n, 1, "★ 按 tag 命中建筑")
	ok(not (b.story_glow as Dictionary).is_empty(), "★ 建筑写上泛光状态")
	eq(StoryGlowRes.color_hex(b, w), "#ff00ff", "自定义颜色原样保留")
	# 区划中心也是 Building，按坐标也能命中
	var zc = _zone_center(w)
	if zc != null:
		var n2: int = StoryActionsRes.glow_objects(w, {
			"targets": {"tile": [zc.tx, zc.ty]}, "id": "zone_focus",
		})
		ok(n2 >= 1, "★ 区划中心能被泛光目标解析命中")


func _test_stop_by_id(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var u = w.create_general("p1", 0, 901)
	if u == null:
		return
	u.tag = "a"
	w.units.append(u)
	var b = _add_tower(w, "b")
	StoryActionsRes.glow_objects(w, {"targets": {"tag": "a"}, "id": "one"})
	StoryActionsRes.glow_objects(w, {"targets": {"tag": "b"}, "id": "two"})
	eq(StoryActionsRes.stop_glow(w, {"id": "one"}), 1, "★ 按 id 只停一组")
	ok((u.story_glow as Dictionary).is_empty(), "id=one 的已清除")
	ok(b != null and not (b.story_glow as Dictionary).is_empty(), "id=two 的保留")
	eq(StoryActionsRes.stop_glow(w, {}), 1, "★ 不写条件 = 清掉剩余全部")
	ok(b != null and (b.story_glow as Dictionary).is_empty(), "剩余也清掉")


func _test_duration(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var u = w.create_general("p1", 0, 902)
	if u == null:
		return
	u.tag = "timed"
	w.units.append(u)
	StoryActionsRes.glow_objects(w, {
		"targets": {"tag": "timed"}, "duration": 0.5, "period": 1.0,
	})
	w.time = 0.1
	ok(StoryGlowRes.value(u, w.time) > 0.0, "（前提）持续期内有强度")
	w.time = 0.6
	eq(StoryGlowRes.value(u, w.time), 0.0, "★★ duration 到期后强度归零")


# ------------------------------------------------------------------
func _free_tile(w) -> Vector2i:
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			if w.building_at(x, y) == null and w.map.terrain_walkable(x, y):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _add_tower(w, tag: String):
	var tile := _free_tile(w)
	if tile.x < 0:
		return null
	return w.add_building("tower", tile.x, tile.y, "p1", true, true, tag)


func _zone_center(w):
	for b in w.building_list:
		if b != null and String(b.type) == "zone_center":
			return b
	return null
