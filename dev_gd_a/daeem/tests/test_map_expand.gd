## test_map_expand.gd —— 演出换图：严格扩大校验 + 世界状态保留。
##
## 用运行时写出的两张小地图（6×6 → 8×8）验证：
##   · 旧区域地形 / exists 必须逐格一致；
##   · 单位 / 建筑 / 资源 / 区划状态 / 时间保留；
##   · 新区划中心补建；
##   · 缩小 / 地形不一致 → 拒绝且不改任何状态。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const BuildingRes = preload("res://logic/building.gd")
const TestMaps = preload("res://tests/story_test_maps.gd")

const TMP_DIR := "res://.tmp_story_map_expand"


func _initialize() -> void:
	_case_name = "test_map_expand"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	TestMaps.prepare(TMP_DIR)
	var w = WorldRes.create(cfg, TMP_DIR + "/small.json", false)
	ok(w != null, "（前提）小地图世界能建出来")
	if w == null:
		return

	# 记下一些动态状态
	w.time = 42.0
	w.resources["food"] = 123.0
	w.resources["gold"] = 45.0
	var u = w.create_general(w.my_faction, 0, 990)
	ok(u != null, "（前提）造一个将领")
	if u != null:
		u.tag = "keep_me"
		w.units.append(u)
	var b = _add_tower(w, "keep_tower")
	ok(b != null, "（前提）造一栋塔")
	var z0 = w.zone_by_id(0)
	if z0 != null:
		z0["owner"] = w.my_faction
		z0["progress"] = 0.5
		z0["population"] = 2.0

	var old_cols := int(w.map.cols)
	var old_rows := int(w.map.rows)
	ok(w.swap_map(TMP_DIR + "/big.json"), "★ 6×6 → 8×8 换图成功")
	eq(int(w.map.cols), 8, "新地图宽 = 8")
	eq(int(w.map.rows), 8, "新地图高 = 8")
	ok(_old_area_same(w, old_cols, old_rows), "★★ 旧区域地形 / exists 逐格不变")
	ok(u != null and w.units.has(u), "★★ 单位保留")
	ok(b != null and w.building_list.has(b), "★★ 建筑保留")
	near(float(w.resources["food"]), 123.0, 1e-4, "★ 粮食保留")
	near(float(w.resources["gold"]), 45.0, 1e-4, "★ 黄金保留")
	near(float(w.time), 42.0, 1e-4, "★ 时间保留")
	var z0b = w.zone_by_id(0)
	ok(z0b != null, "旧区划 c0 仍在")
	if z0b != null:
		eq(String(z0b.get("owner", "")), String(w.my_faction), "★ 区划归属保留")
		near(float(z0b.get("progress", 0.0)), 0.5, 1e-4, "★ 占领进度保留")
		near(float(z0b.get("population", 0.0)), 2.0, 1e-4, "★ 人口保留")
	# 新区划 c4 的中心应当被补建出来
	var nb = w.building_at(7, 1)
	ok(nb != null and String(nb.type) == BuildingRes.TYPE_ZONE_CENTER,
		"★ 新区域区划中心已补建")
	# 换图后跑一帧：路径 / 迷雾 / 碰撞 / 区划收口都在这里被真正调用。
	var evs: Array = w.tick(0.016)
	ok(typeof(evs) == TYPE_ARRAY, "★ 换图后 tick 不崩")

	var cols_after := int(w.map.cols)
	ok(not w.swap_map(TMP_DIR + "/smaller.json"), "★★ 换到更小的地图被拒绝")
	eq(int(w.map.cols), cols_after, "拒绝缩小后地图尺寸不变")
	ok(not w.swap_map(TMP_DIR + "/bad.json"), "★★ 旧区域地形不一致被拒绝")
	eq(int(w.map.cols), cols_after, "拒绝坏图后地图尺寸不变")

	TestMaps.cleanup(TMP_DIR)


func _old_area_same(w, old_cols: int, old_rows: int) -> bool:
	# 世界现在已经是新地图；用「新地图旧区域 = 全草地」这一事实做校验。
	for y in old_rows:
		for x in old_cols:
			if String(w.map.terrain.get_cell(x, y)) != "grass":
				return false
			if not bool(w.map.exists.get_cell(x, y)):
				return false
	return true


func _add_tower(w, tag: String):
	for y in int(w.map.rows):
		for x in int(w.map.cols):
			if w.building_at(x, y) != null:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			if not w.can_build_at(x, y, ""):
				continue
			var b = w.add_building("tower", x, y, w.my_faction, true, true, tag)
			if b != null:
				return b
	return null



