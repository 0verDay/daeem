## test_minimap.gd —— 小地图（3D 外壳）
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：走 `main._on_test_pressed()` 直连默认地图
##   （界面入口已改为 test_1/2/3 与战役菜单，那两条走的是关卡路径）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const UiLayoutRes = preload("res://view/ui_layout.gd")

func _initialize() -> void:
	_case_name = "test_minimap"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return

	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		quit(1)
		return

	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★ 按下 test 之后建出了游戏内场景")
	if game == null:
		main.queue_free()
		quit(1)
		return
	game.set_process(false)

	var mm = game.hud.minimap if game.hud != null else null
	ok(mm != null, "★ HUD 里建出了小地图")
	ok(mm != null and mm.palette != null, "★ 小地图拿到了 3D 投影助手（视野框 / 跳转都靠它）")
	if mm != null:
		var cols: int = int(game.world.map.cols)
		var rows: int = int(game.world.map.rows)

		var mr: Rect2 = mm.map_rect()
		ok(mr.size.x > 0.0 and mr.size.y > 0.0, "小地图的地图矩形非退化")
		near(mr.size.x / maxf(1e-6, mr.size.y), float(cols) / float(rows), 1e-3,
			"★ 地图矩形保持地图比例（cols:rows = %d:%d）" % [cols, rows])
		ok(mr.size.x <= mm.size.x + 1e-3 and mr.size.y <= mm.size.y + 1e-3,
			"★ 整张地图装得进小地图控件（%.0f×%.0f）" % [mm.size.x, mm.size.y])

		game.cam.force_update_transform()
		var r0: Rect2 = mm.view_rect_world()
		ok(r0.size.x > 0.0 and r0.size.y > 0.0, "★ 视野框有面积（不是 0×0 空矩形）")
		var center := Vector2(float(cols) * 0.5, float(rows) * 0.5)
		game.center_on_tile(center + Vector2(4.0, 3.0))
		game.cam.force_update_transform()
		var r1: Rect2 = mm.view_rect_world()
		ok(r1.position.distance_to(r0.position) > 1.0,
			"★ 相机移动后视野框跟着挪（%.1f,%.1f → %.1f,%.1f）"
			% [r0.position.x, r0.position.y, r1.position.x, r1.position.y])

		# ★★ 红点生成事件 → 小地图动效（场景层的唯一接线，见 game_scene3d._feed_red_dot_spawn_fx）。
		#    默认地图上没有红点 AI，所以这里直接喂一条事件形状，验「搬运」这一段。
		game._feed_red_dot_spawn_fx([{
			"type": "red_dot_wave",
			"faction": "red1",
			"wave": 1,
			"spawns": [{"x": 3, "y": 4}, {"x": 5, "y": 6}],
		}])
		eq(mm.red_dot_fx_count(), 2, "★★ 场景把红点出生格交给了小地图（每个出生格一条动效）")
		game._feed_red_dot_spawn_fx([{"type": "unit_recruited"}])
		eq(mm.red_dot_fx_count(), 2, "★ 别的事件不会误触发红点动效")

	main.queue_free()
	await process_frame

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
