## bench_prepare_shot.gd —— 备战页截图（**只用于人工看样子**，不是断言）。
##
## 用法（工程根下，必须 _console.exe；不要加 --headless，否则拿不到画面）：
##   <godot_console.exe> --path . --script res://tests/bench_prepare_shot.gd
## 输出：`res://shots/1*_prepare*.png`（看完可删；不参与 run-tests.ps1）。
extends SceneTree

const MainScene := preload("res://view/main.tscn")
const OUT_DIR := "res://shots"

var main = null
var screen = null
var deck = null


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	print("[SHOT] out dir = ", ProjectSettings.globalize_path(OUT_DIR))

	main = MainScene.instantiate()
	root.add_child(main)
	await _wait(20)
	screen = main.start_screen
	deck = screen.menu_deck()

	await _wait_sec(2.2)
	screen.dismiss_intro()
	await _wait_start_page(1)
	await _wait_sec(0.8)
	await _shoot("10_main")

	# 进入备战页：上滑中途 + 落定
	screen.main_panel().bottom_buttons()[1].pressed.emit()
	await _wait_sec(0.12)
	await _shoot("11_prepare_mid")
	await _wait_page("prepare")
	await _wait_sec(0.45)
	await _shoot("12_prepare")

	# 右面板列表：拖到中段，确认分节与滚动裁剪
	var pp = screen.prepare_panel()
	if pp.roster() != null:
		pp.roster().scroll_to(560.0)
		await _wait_sec(0.2)
		await _shoot("12b_roster_scrolled")
		pp.roster().scroll_to(pp.roster().max_scroll())
		await _wait_sec(0.2)
		await _shoot("12c_roster_bottom")
		pp.roster().scroll_to(0.0)
		# 磁贴悬停：金色自下而上填、编号/名字翻面、名字底条淡出
		var tile: Button = pp.roster().general_buttons()[0]
		tile.mouse_entered.emit()
		await _wait_sec(0.3)
		await _shoot("12d_tile_hover")
		tile.mouse_exited.emit()
		await _wait_sec(0.2)

	# 悬停「王朝」（白框那枚）
	pp.faction_buttons()[0].mouse_entered.emit()
	await _wait_sec(0.3)
	await _shoot("13_faction_hover")

	# 点「王朝」→ 金色选中换到上面
	await _click_at(pp.faction_buttons()[0].get_global_rect().get_center())
	await _wait_sec(0.35)
	await _shoot("14_faction_dynasty")

	# 返回：中途 + 落定
	await _click_at(pp.back_area().get_global_rect().get_center())
	await _wait_sec(0.14)
	await _shoot("15_back_mid")
	await _wait_page("main")
	await _wait_sec(0.8)
	await _shoot("16_main_back")

	print("[SHOT] done")
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_start_page(page: int, timeout_ms: int = 8000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline and int(screen.page()) != page:
		await process_frame


func _wait_page(page: String, timeout_ms: int = 8000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck != null and deck.current_page() == page and not deck.is_busy():
			return
		await process_frame


func _click_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


func _shoot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("no image")
		return
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	print("[SHOT] ", ProjectSettings.globalize_path(path), " err=", err)
