## bench_menu_shot.gd —— 新菜单九屏截图（**只用于人工看样子**，不是断言）。
##
## 用法（工程根下，必须 _console.exe）：
##   <godot_console.exe> --path . --script res://tests/bench_menu_shot.gd
## 输出：`res://shots/*.png`（看完可删；不参与 run-tests.ps1）。
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

	# 1) 入场页：等启动黑幕 + 扫光都跑完，避免拍到扫光带
	await _wait_sec(2.2)
	await _shoot("01_intro")

	# 2) 主菜单
	screen.dismiss_intro()
	# 2-0) 落位中途：只有 logo/游戏名在右移 + 面板在渐显；左侧**必须还是空的**，
	#      四角泛光也还没亮（用户口径：这两样要等面板站好之后一起亮）
	await _wait_sec(0.12)
	await _shoot("01b_morph_mid")
	# ★ 等的是 start_screen 的「落位结束」（page == PAGE_MENU），不是 deck 的页名 ——
	#   deck 在 prepare_intro 里就已经是 main 了，等它会立刻返回、拍到落位中途。
	var morph_deadline := Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < morph_deadline and screen.page() != 1:
		await process_frame
	# 2-1) 面板刚站好、泛光与雕版正在一起渐显（两者应当同处在半透明状态）
	await _wait_sec(0.22)
	await _shoot("01c_glow_plate_in")
	await _wait_sec(0.9)
	await _shoot("02_menu")

	# 2a) 左侧那幅雕版：关掉动效 = 钉在「扫描头在中间」那一帧
	if screen.art() != null:
		screen.art().set_running(false)
		await _wait_sec(0.2)
		await _shoot("02a_plate_frozen")
		# 2b) 扫描头刚进画：金线正在被点亮
		screen.art().set_time(2.2)
		await _wait_sec(0.15)
		await _shoot("02b_plate_scan")
		# 2c) 轮播的第二张（骑士 + 风车）：拨到它自己那一档、扫到一半
		if screen.art().plate_count() > 1:
			screen.art().set_time(screen.art().time_for_x(0.5, 1))
			await _wait_sec(0.15)
			await _shoot("02c_plate2")
		screen.art().set_running(true)

	# 2b) 退出按钮悬停：右上角边缘泛光变亮
	screen.main_panel().corner_hit().mouse_entered.emit()
	await _wait_sec(0.35)
	await _shoot("02b_exit_hover")
	screen.main_panel().corner_hit().mouse_exited.emit()
	await _wait_sec(0.2)

	# 2c) 主菜单文字按钮悬停：左右横线渐显
	screen.main_panel().main_buttons()[0].mouse_entered.emit()
	await _wait_sec(0.25)
	await _shoot("02c_main_hover")
	screen.main_panel().main_buttons()[0].mouse_exited.emit()
	await _wait_sec(0.2)

	# 3) 战役地图
	screen.main_panel().main_buttons()[0].pressed.emit()
	# 3-0) 左移中途：左侧雕版应当**跟着主面板一起**往左滑出去（不是原地淡出）
	await _wait_sec(0.18)
	await _shoot("03a_slide_out")
	await _wait_page("campaign")
	await _wait_sec(0.4)
	await _shoot("03_campaign")

	# 4) 战役详情
	screen.campaign_panel().flag_buttons()[0].pressed.emit()
	await _wait_page("detail")
	await _wait_sec(0.4)
	await _shoot("04_detail")

	# 5) 合作过渡（从主菜单重新进，避免详情残留）
	screen.open_menu()
	await _wait_sec(0.5)
	screen.main_panel().main_buttons()[1].pressed.emit()
	await _wait_page("coop_start")
	await _wait_sec(0.4)
	await _shoot("05_coop_start")

	# 6) 合作房间（点两旗之间空白）
	deck.goto_coop_room()
	await _wait_page("coop_room")
	await _wait_sec(0.6)
	await _shoot("06_coop_room")

	# 7) 合作准备（AI 队友）
	screen.handle_back()
	await _wait_page("coop_start")
	await _wait_sec(0.3)
	screen.coop_start_panel().empty_flag().pressed.emit()
	await _wait_page("coop_ready")
	await _wait_sec(0.5)
	await _shoot("07_coop_ready")

	# 8) 地图选择层
	deck.open_map_picker()
	await _wait_map(true)
	await _wait_sec(0.3)
	await _shoot("08_map_picker")
	deck.close_map_picker()
	await _wait_map(false)

	# 9) 战役过渡
	screen.open_menu()
	await _wait_sec(0.5)
	main._on_menu_campaign_level_chosen("demo", "mt", "F1")
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and main.level_transition() == null:
		await process_frame
	var tr = main.level_transition()
	if tr != null:
		deadline = Time.get_ticks_msec() + 12000
		while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
			await process_frame
		await _wait_sec(0.4)
		await _shoot("09_campaign_start")
	else:
		print("[SHOT] 战役过渡没出来 —— 09 跳过")

	print("[SHOT] done")
	quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_page(page: String, timeout_ms: int = 8000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck != null and deck.current_page() == page and not deck.is_busy():
			return
		await process_frame


func _wait_map(open: bool, timeout_ms: int = 4000) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck != null and deck.is_map_open() == open and not deck.is_busy():
			return
		await process_frame


func _shoot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("no image")
		return
	var path := "%s/%s.png" % [OUT_DIR, name]
	var err := img.save_png(path)
	print("[SHOT] ", ProjectSettings.globalize_path(path), " err=", err)
