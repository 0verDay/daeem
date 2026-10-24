## test_settings_menu.gd —— ★ 选项页菜单（仿 nsoc）：HUD 右上角 / 主菜单右上角
##
## 盯的东西：
##   · 按钮文案改成「选项」，点开是**居中 overlay**（不是贴按钮下方的下拉）；
##   · 一级继续 / 设置 / 返回主菜单；二级设置里是 全屏/窗口化 + 返回；
##   · HUD 的全屏 / 返回主菜单仍然只发信号（窗口与流程归 main.gd）；
##   · 主菜单右上角的「选项」走同一套控制器。
extends "res://tests/test_case.gd"

const MapLibraryRes = preload("res://logic/map_library.gd")
const FillButtonRes = preload("res://view/fill_button.gd")

const PAGE_MENU := 1
const CLICK_CENTER := Vector2(960.0, 540.0)


func _initialize() -> void:
	_case_name = "test_settings_menu"
	_run()


func _run() -> void:
	await process_frame
	await _test_hud_options_structure()
	await _test_fullscreen_request()
	await _test_touch_release_clears_hud_hover()
	await _test_return_to_menu()
	await _test_menu_options()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _test_hud_options_structure() -> void:
	var main = await _enter_game()
	if main == null:
		ok(false, "能进游戏（后面几条都在游戏里验）")
		return
	var hud = main.game.hud
	var op = hud.options_panel
	ok(op != null, "★★ HUD 有选项页控制器（options_panel）")
	if op == null:
		await _dispose(main)
		return
	ok(op.overlay != null and op.panel != null, "选项页有 overlay + 居中面板")
	ok(not op.overlay.visible, "★ 刚进游戏时选项页是收着的")
	eq(hud.settings_button.text, hud.cfg.str_val("settings.title", "选项"),
		"★ 右上角按钮写着「选项」（不再是「设置」）")
	eq(hud.settings_panel, op.overlay, "★ 兼容字段 settings_panel 指向 overlay")
	eq(op.resume_button.text, hud.cfg.str_val("settings.continue_text", "继续"),
		"一级第一项文案来自 config（游戏内「继续」）")
	eq(op.settings_button.text, hud.cfg.str_val("settings.panel_title", "设置"),
		"一级第二项是「设置」")
	eq(op.exit_button.text, hud.cfg.str_val("settings.menu_text", "返回主菜单"),
		"一级第三项是「返回主菜单」")

	var btn_center: Vector2 = hud.settings_button.get_global_rect().get_center()
	await _click_at(btn_center)
	await _wait_sec(0.28)
	ok(op.overlay.visible, "★ 点「选项」→ overlay 弹出来")
	ok(op.panel.visible, "居中面板可见")
	ok(not op.is_settings_page_open(), "刚打开时停在一级菜单")
	ok(hud.blocks_edge_scroll(Vector2(600.0, 540.0)),
		"★★ 选项页开着时屏幕中间也不滚地图（模态 overlay）")
	ok(hud.blocks_wheel_zoom(Vector2(960.0, 1000.0)),
		"★★ 选项页开着时底栏滚轮缩放也让路")

	var panel_rect: Rect2 = op.panel.get_global_rect()
	var vp_center: Vector2 = op.overlay.size * 0.5
	v2_near(panel_rect.get_center(), vp_center, 3.0, "★★ 面板在屏幕中央（仿 nsoc）")
	ok(panel_rect.size.x >= 360.0 and panel_rect.size.y >= 300.0,
		"面板有实际尺寸（%.0f × %.0f）" % [panel_rect.size.x, panel_rect.size.y])
	eq(op.overlay.mouse_filter, Control.MOUSE_FILTER_STOP,
		"★ overlay 整块吃鼠标（点空白处关闭，不穿到地图）")
	eq(op.panel.mouse_filter, Control.MOUSE_FILTER_STOP, "面板吃鼠标")
	eq(op.resume_button.mouse_filter, Control.MOUSE_FILTER_STOP, "一级按钮吃鼠标")
	eq(op.settings_button.mouse_filter, Control.MOUSE_FILTER_STOP, "设置页按钮吃鼠标")

	# 一级 → 设置子页
	await _click_at(op.settings_button.get_global_rect().get_center())
	await _wait_sec(0.22)
	ok(op.is_settings_page_open(), "★ 点「设置」进入二级页")
	ok(op.config_vbox.visible and not op.menu_vbox.visible,
		"二级页显示、一级页收起")
	eq(op.back_button.text, hud.cfg.str_val("settings.back_text", "返回"),
		"二级页有「返回」")
	ok(op.fullscreen_button.text == hud.cfg.str_val("settings.fullscreen_on_text", "窗口化")
			or op.fullscreen_button.text == hud.cfg.str_val("settings.fullscreen_off_text", "全屏"),
		"「全屏 / 窗口化」文案来自 config")

	# 返回一级
	await _click_at(op.back_button.get_global_rect().get_center())
	await _wait_sec(0.22)
	ok(not op.is_settings_page_open() and op.menu_vbox.visible,
		"★ 「返回」回到一级菜单")

	# 点 overlay 空白处关闭（选左上角，远离居中面板）
	await _click_at(Vector2(20.0, 20.0))
	await _wait_sec(0.28)
	ok(not op.overlay.visible, "★ 点空白处 → 选项页关闭")

	# 再开一次，用「继续」关闭
	hud.set_settings_menu_open(true)
	await _wait_sec(0.28)
	ok(op.overlay.visible, "（前提）选项页再次打开")
	await _click_at(op.resume_button.get_global_rect().get_center())
	await _wait_sec(0.28)
	ok(not op.overlay.visible, "★ 「继续」关闭选项页")
	ok(not FillButtonRes.is_latched(hud.settings_button),
		"★ 关闭后右上角按钮不再常驻满格（overlay 自己关也不会把按钮锁死）")
	await _dispose(main)


func _test_fullscreen_request() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	var op = hud.options_panel
	hud.set_settings_menu_open(true)
	await _wait_sec(0.28)
	await _click_at(op.settings_button.get_global_rect().get_center())
	await _wait_sec(0.22)

	ok(hud.fullscreen_toggled.is_connected(Callable(game, "_on_fullscreen_toggled")),
		"★ hud 的「全屏」请求接到了 game_scene")
	ok(game.fullscreen_toggled.is_connected(Callable(main, "toggle_fullscreen")),
		"★ game_scene 又把它转给了 main.toggle_fullscreen（窗口模式只在那里改）")

	var before_mode: int = DisplayServer.window_get_mode()
	var page_before := String(hud.page_tabs.page())
	await _click_at(op.fullscreen_button.get_global_rect().get_center())
	await _wait_sec(0.12)
	ok(true, "★ 按下「全屏」不报错（信号链走通）")
	eq(String(hud.page_tabs.page()), page_before, "切全屏不会顺手切页签")
	eq(DisplayServer.window_get_mode(), before_mode,
		"⚠️ 无头下窗口模式不变（DisplayServer 是空实现）——这条只保证没崩")
	ok(op.overlay.visible, "按全屏不会把选项页收掉（玩家可能还想按返回）")
	await _dispose(main)


## ★★ 游戏内按钮：手指抬起之后悬停必须**作废**（用户报的第二处「按钮仍然满填充」）。
func _test_touch_release_clears_hud_hover() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	hud.set_settings_menu_open(false)
	await process_frame
	var btn: Button = hud.settings_button
	await _hover_at(btn.get_global_rect().get_center())
	await _wait_sec(0.35)
	ok(FillButtonRes.fill_progress(btn) > 0.9, "（前提）鼠标停上去之后它填满了")

	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = false
	ev.position = btn.get_global_rect().get_center()
	hud.handle_touch(ev)
	await _wait_sec(0.45)
	ok(FillButtonRes.fill_progress(btn) < 0.05,
		"★★ 手指抬起 → 游戏内按钮的悬停也作废（当前 %.2f）"
		% FillButtonRes.fill_progress(btn))
	await _dispose(main)


func _test_return_to_menu() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	var screen = main.start_screen

	hud.set_settings_menu_open(true)
	await _wait_sec(0.28)
	ok(hud.options_panel.overlay.visible, "（前提）选项页开着")
	await _click_at(hud.options_panel.exit_button.get_global_rect().get_center())
	await _wait_sec(0.32)

	eq(main.game, null, "★ 点「返回主菜单」→ main 的游戏句柄清空")
	ok(main.get_node_or_null("GameScene") == null,
		"★ GameScene 节点已经不在树上了（不只是 queue_free 排队）")
	var still_in_tree: bool = is_instance_valid(game) and game.is_inside_tree()
	ok(not still_in_tree, "★ 旧游戏场景立刻离开了场景树（这一帧就不再跑逻辑 / 收输入）")

	ok(screen.visible, "★ 开场页重新可见（整层 show() 了，不只是页内两层）")
	eq(int(screen.page()), PAGE_MENU, "★ 回到的是**主界面**那一页")
	ok(screen.get_node("StartRoot/MainMenu").visible, "主界面那一层可见")
	ok(not screen.get_node("StartRoot/Intro").visible, "入场页那一层没有回来")

	var buttons: Array = screen.test_buttons()
	ok(buttons.size() == 4, "★★ 回到菜单后主界面正中还是那四颗按钮（test_1/2/3 + ai_test）")
	if buttons.is_empty():
		await _dispose(main)
		return
	var tb: Button = buttons[0]
	await _click_at(tb.get_global_rect().get_center())
	# ★ 现在点 test_1 先进战役过渡画面：选 F1 再点进入，才建第二局。
	var tr = await _wait_transition(main)
	ok(tr != null, "★ 回到菜单之后再按 test_1 会先出现战役过渡画面")
	if tr != null:
		tr.select_faction("F1")
		await _wait_transition_ready(tr)
		tr._enter()
		var d: int = Time.get_ticks_msec() + 6000
		while Time.get_ticks_msec() < d and main.game == null:
			await process_frame
		await process_frame
	var second = main.game
	ok(second != null, "★ 回到菜单之后再按 test_1 能开出一局新的")
	ok(second != game, "★ 新一局是**新的** game_scene")

	if second != null:
		second.hud.set_settings_menu_open(true)
		await _wait_sec(0.28)
		ok(second.hud.options_panel.overlay.visible, "★ 新一局的选项页也能开")
		second.hud.options_panel.close()
		await _wait_sec(0.28)
		second.hud.return_menu_button.emit_signal("pressed")
		await _wait_sec(0.32)
		eq(main.game, null, "★ 第二次返回菜单同样生效")

	await _dispose(main)


func _test_menu_options() -> void:
	var packed = load("res://view/main.tscn")
	if packed == null:
		ok(false, "能载入主场景 main.tscn")
		return
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_sec(0.12)
	while int(screen.page()) != PAGE_MENU:
		await process_frame
	# 主菜单三块面板的首次滑入也是 panel_expand 的 busy 状态；等它跑完再点选项。
	await _wait_sec(0.75)

	var btn: Button = screen.options_button()
	ok(btn != null, "★★ 主菜单右上角有「选项」按钮")
	if btn == null:
		await _dispose(main)
		return
	eq(btn.text, screen.cfg.str_val("settings.title", "选项"), "主菜单选项按钮文案来自 config")
	ok(btn.visible, "主界面时选项按钮可见")
	ok(btn.get_global_rect().position.x > 1600.0, "选项按钮在屏幕右上角")

	var op = screen.options_panel()
	ok(op != null, "主菜单也挂了同一个选项页控制器")
	if op == null:
		await _dispose(main)
		return
	await _click_at(btn.get_global_rect().get_center())
	await _wait_sec(0.28)
	ok(op.overlay.visible, "★ 主菜单点「选项」→ overlay 打开")
	eq(op.resume_button.text, screen.cfg.str_val("settings.back_text", "返回"),
		"主菜单一级第一项是「返回」")
	eq(op.exit_button.text, screen.cfg.str_val("settings.exit_game_text", "退出游戏"),
		"主菜单一级第三项是「退出游戏」")

	await _click_at(op.settings_button.get_global_rect().get_center())
	await _wait_sec(0.22)
	ok(op.is_settings_page_open(), "★ 主菜单也能进「设置」二级页")
	await _click_at(op.back_button.get_global_rect().get_center())
	await _wait_sec(0.22)
	await _click_at(op.resume_button.get_global_rect().get_center())
	await _wait_sec(0.28)
	ok(not op.overlay.visible, "★ 主菜单「返回」关闭选项页")

	await _dispose(main)


# ------------------------------------------------------------------
# 测试脚手架
# ------------------------------------------------------------------

func _enter_game() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main.start_screen.dismiss_intro()
	await _wait_sec(0.12)
	while int(main.start_screen.page()) != PAGE_MENU:
		await process_frame
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	if main.game == null:
		ok(false, "进游戏失败（后面那些断言就都测不到东西了）")
		return null
	return main


func _dispose(main) -> void:
	if main == null or not is_instance_valid(main):
		return
	if main.get_parent() != null:
		main.get_parent().remove_child(main)
	main.free()
	await process_frame


func _hover_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame


func _click_at(pos: Vector2) -> void:
	await _hover_at(pos)
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


func _wait_sec(sec: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(maxf(0.0, sec) * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## 等战役过渡画面挂出来。
func _wait_transition(main):
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and main.level_transition() == null:
		await process_frame
	return main.level_transition()


## 等过渡画面加载完 + 提示可点。
func _wait_transition_ready(tr) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
		await process_frame
