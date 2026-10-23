## bench_outcome_shot.gd —— 把胜利 / 失败结算画面渲染成 PNG（**只用于人眼看样子**，不是断言）
##
## 用法（在工程根下，必须用 **_console.exe** + 真实渲染，不要 --headless）：
##   <godot_console.exe> --path . --script res://tests/bench_outcome_shot.gd
## 输出：`res://shots/outcome_*.png`
##
## ★ 它真的开一局（3D 地图在暗幕后面），再走 Ctrl+W / Ctrl+L 同一条路弹结算，
##   所以截图里能看到「结算画面压在实际战场之上」的效果。
extends SceneTree

const ConfigRes = preload("res://logic/config.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const GameSceneRes = preload("res://view/game_scene3d.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")

const OUT_DIR := "res://shots"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[SHOT] out dir = ", ProjectSettings.globalize_path(OUT_DIR))
	var cfg = ConfigRes.load_default()
	if cfg == null:
		printerr("[SHOT] 配置载入失败")
		quit(1)
		return

	await _capture("win", cfg)
	await _capture("lose", cfg)

	print("[SHOT] done")
	quit(0)


func _capture(result: String, cfg) -> void:
	var game = GameSceneRes.new()
	root.add_child(game)
	if not game.start(String(MapLibraryRes.default_map_path())):
		printerr("[SHOT] 开局失败：%s" % result)
		game.queue_free()
		return
	await _wait_sec(0.35)

	# 走与玩家 / 开发者快捷键同一条路（不是直接 new overlay）——
	# 这样截到的就是「结算层压在实际游戏上」的最终形态。
	var evt := InputEventKey.new()
	evt.pressed = true
	evt.keycode = KEY_W if result == "win" else KEY_L
	evt.ctrl_pressed = true
	game._handle_dev_hotkey(evt)

	await _wait_sec(0.18)
	await _shoot("outcome_%s_1_crown" % result)
	await _wait_sec(0.60)
	await _shoot("outcome_%s_2_%s" % [result, "gem" if result == "win" else "crack"])
	await _wait_sec(0.95)
	await _shoot("outcome_%s_3_banner" % result)
	await _wait_sec(0.55)
	await _shoot("outcome_%s_4_hint" % result)

	var ov = game.outcome_overlay()
	if ov != null:
		# 等「提示淡入 + 可点击」真的到位（失败那一套比胜利多 0.25s 裂纹）。
		var deadline: int = Time.get_ticks_msec() + 4000
		while Time.get_ticks_msec() < deadline and not ov.ready_for_click():
			await process_frame
		ov.accept_click()
		await _wait_sec(0.55)
		await _shoot("outcome_%s_5_buttons" % result)

	game.queue_free()
	await _wait_sec(0.15)


func _wait_sec(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _shoot(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] %s: 视口拿不到图像（是不是在用 --headless 跑？）" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[SHOT] %s -> %s (%dx%d) err=%d"
		% [shot_name, ProjectSettings.globalize_path(path),
			img.get_width(), img.get_height(), err])
