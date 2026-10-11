## test_minimap.gd —— 小地图（3D 外壳）
##
## ★★ 本文件原先是一整套 **2D 相机替身**用例（视野框 = 视口/zoom、点击跳转、
##   拖动跟手、夹取极点…），那些在 3D 入口下**整段跳过**（3D 场景里没有 `camera_rig`）。
##   2D 视图栈删除后，只保留 3D 下真正跑得到的这几条。
##
## ★★ 重头戏（视野框跟着相机走、点小地图「点哪去哪」的落点精度）在
##   `tests/test_view3d.gd` 的 `_test_hud_and_minimap` 与 `_test_camera_aim` ——
##   本文件只做「小地图存在 + 拿到了投影助手 + 地图矩形比例 + 视野框随相机挪」的冒烟。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后：`_initialize()` 阶段 root.add_child() 静默失效。
extends "res://tests/test_case.gd"

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
	# ⚠️ headless 的根视口默认是正方形（1920×1920）—— 钉成参考图的 1920×1080。
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	main._on_test_pressed(main.start_screen.selected_map_path())
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★ 按下 test 之后建出了游戏内场景")
	if game == null:
		main.queue_free()
		quit(1)
		return
	# ★ 冻住世界：否则 headless 下鼠标停在 (0,0) ⇒ 边缘滚屏每帧把相机推向左上，
	#   下面「视野框随相机挪」读到的就是被滚屏带偏的位置。
	game.set_process(false)

	var mm = game.hud.minimap if game.hud != null else null
	ok(mm != null, "★ HUD 里建出了小地图")
	ok(mm != null and mm.palette != null, "★ 小地图拿到了 3D 投影助手（视野框 / 跳转都靠它）")
	if mm != null:
		var cols: int = int(game.world.map.cols)
		var rows: int = int(game.world.map.rows)

		# ① 地图矩形：非退化、保持地图比例、装得进控件（小地图画的是**整张地图**）
		var mr: Rect2 = mm.map_rect()
		ok(mr.size.x > 0.0 and mr.size.y > 0.0, "小地图的地图矩形非退化")
		near(mr.size.x / maxf(1e-6, mr.size.y), float(cols) / float(rows), 1e-3,
			"★ 地图矩形保持地图比例（cols:rows = %d:%d）" % [cols, rows])
		ok(mr.size.x <= mm.size.x + 1e-3 and mr.size.y <= mm.size.y + 1e-3,
			"★ 整张地图装得进小地图控件（%.0f×%.0f）" % [mm.size.x, mm.size.y])

		# ② 视野框：有面积，且**跟着相机挪**
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

	main.queue_free()
	await process_frame

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
