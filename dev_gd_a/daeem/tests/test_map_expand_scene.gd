## test_map_expand_scene.gd —— 换图后**视图层重建**的冒烟测试。
##
## 只验「换图 → 重建 ground / terrain_props / map_border / overlay 不崩、引用接对」，
## 不验截图。纯逻辑的状态保留在 `test_map_expand.gd`。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const TestMaps = preload("res://tests/story_test_maps.gd")

const TMP_DIR := "res://.tmp_story_map_expand"


func _initialize() -> void:
	_case_name = "test_map_expand_scene"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	await process_frame
	TestMaps.prepare(TMP_DIR)

	var game = GameSceneRes.new()
	root.add_child(game)
	await process_frame
	if not game.start(TMP_DIR + "/small.json"):
		ok(false, "（前提）小地图场景能装起来")
		game.queue_free()
		TestMaps.cleanup(TMP_DIR)
		_quit_case()
		return
	await process_frame
	ok(game.ground != null and game.terrain_props != null and game.map_border != null,
		"（前提）三层地图视图存在")

	ok(game.world.swap_map(TMP_DIR + "/big.json"), "★ 世界换图成功")
	game._rebuild_map_views()
	await process_frame
	ok(game.ground != null and is_instance_valid(game.ground), "★ 地面层重建")
	ok(game.terrain_props != null and is_instance_valid(game.terrain_props), "★ 地形装饰层重建")
	ok(game.map_border != null and is_instance_valid(game.map_border), "★ 金线层重建")
	ok(game.overlay != null and game.overlay.ground == game.ground,
		"★ overlay 拿到新的 ground 引用")
	ok(int(game.world.map.cols) == 8, "★ 视图使用新地图尺寸")

	game._apply_story_expand_opts({})
	await process_frame
	ok(true, "★ HUD / 小地图刷新不崩")

	game.queue_free()
	await process_frame
	TestMaps.cleanup(TMP_DIR)
	_quit_case()


func _quit_case() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
