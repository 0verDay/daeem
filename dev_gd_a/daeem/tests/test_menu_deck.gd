## test_menu_deck.gd —— 新菜单页面栈 / 横向位置 / 侧栏灰层 / 返回。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const ThemeRes := preload("res://view/theme.gd")

func _initialize() -> void:
	_case_name = "test_menu_deck"
	_run()


func _run() -> void:
	await process_frame
	await _test_navigation()
	await _test_animations_off()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.15)
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_page(screen.menu_deck(), "main")
	await _wait_sec(0.9)
	return main


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _hover_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame
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


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()


func _test_navigation() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var mp = screen.main_panel()

	near(mp.position.x, 1280.0, 1.0, "MAIN：主面板在右")
	ok(not screen.campaign_panel().visible, "MAIN：战役面板隐藏")
	ok(not screen.coop_start_panel().visible, "MAIN：合作面板隐藏")

	# 右上角命中区是三角形：三角内亮、左下角外不亮。
	var hit: Control = mp.corner_hit()
	var hr: Rect2 = hit.get_global_rect()
	await _hover_at(hr.position + Vector2(120.0, 20.0))
	ok(mp.corner_glow().is_hovered(), "MAIN：右上角三角区内悬停亮起")
	await _hover_at(hr.position + Vector2(20.0, 120.0))
	ok(not mp.corner_glow().is_hovered(), "MAIN：右上角三角区外不亮")

	mp.main_buttons()[0].pressed.emit()
	ok(await _wait_page(deck, "campaign"), "进入 CAMPAIGN")
	near(mp.position.x, 0.0, 1.0, "CAMPAIGN：主面板贴左")
	near(screen.campaign_panel().position.x, 640.0, 1.0, "CAMPAIGN：战役面板在 x=640")
	ok(mp.is_sidebar_dimmed(), "CAMPAIGN：主面板灰层")
	ok(mp.sidebar_dim().visible, "CAMPAIGN：灰层可见")
	eq(mp.sidebar_dim().mouse_filter, Control.MOUSE_FILTER_STOP, "CAMPAIGN：灰层吃点击")
	# 灰层挡住的不是「视觉」，而是真的点不到：点 X / 战役按钮都不应该生效
	var quit_before = main._quit_confirm
	await _click_at(mp.exit_button().get_global_rect().get_center())
	ok(main._quit_confirm == quit_before or main._quit_confirm == null
			or not main._quit_confirm.is_open(), "CAMPAIGN：侧栏 X 被灰层挡住")
	await _click_at(mp.main_buttons()[0].get_global_rect().get_center())
	eq(deck.current_page(), "campaign", "CAMPAIGN：侧栏按钮被灰层挡住")

	ok(screen.handle_back(), "CAMPAIGN：返回被菜单受理")
	ok(await _wait_page(deck, "main"), "返回 MAIN")
	near(mp.position.x, 1280.0, 1.0, "MAIN：主面板回右")
	ok(not mp.is_sidebar_dimmed(), "MAIN：灰层关闭")

	mp.main_buttons()[1].pressed.emit()
	ok(await _wait_page(deck, "coop_start"), "进入 COOP_START")
	near(screen.coop_start_panel().position.x, 640.0, 1.0, "COOP_START：合作面板在 x=640")
	ok(mp.is_sidebar_dimmed(), "COOP_START：主面板灰层")
	eq(mp.active_index(), 1, "COOP_START：合作按钮满金选中")

	deck.goto_coop_room()
	near(screen.coop_start_panel().position.x, 640.0, 1.0, "COOP_ROOM：合作面板从右侧开始滑入")
	ok(await _wait_page(deck, "coop_room"), "进入 COOP_ROOM")
	near(screen.coop_start_panel().position.x, 0.0, 1.0, "COOP_ROOM：合作面板贴左")
	near(screen.coop_room_panel().position.x, 1280.0, 1.0, "COOP_ROOM：房间面板在右")
	ok(screen.coop_start_panel().is_sidebar_dimmed(), "COOP_ROOM：合作面板灰层")
	near(screen.main_panel().position.x, -640.0, 1.0, "COOP_ROOM：主菜单跟到左滑出")

	ok(screen.handle_back(), "COOP_ROOM：返回被受理")
	ok(await _wait_page(deck, "coop_start"), "COOP_ROOM → COOP_START")
	near(screen.coop_start_panel().position.x, 640.0, 1.0, "COOP_START：合作面板回右")
	ok(not screen.coop_start_panel().is_sidebar_dimmed(), "COOP_START：合作面板灰层关闭")
	near(screen.main_panel().position.x, 0.0, 1.0, "COOP_START：主菜单滑回左侧栏")

	ok(screen.handle_back(), "COOP_START：返回被受理")
	ok(await _wait_page(deck, "main"), "COOP_START → MAIN")

	main.queue_free()
	await process_frame


func _test_animations_off() -> void:
	ThemeRes.set_animations_enabled(false)
	var main = await _spawn_main_instant()
	if main != null:
		var screen = main.start_screen
		var deck = screen.menu_deck()
		deck.goto_campaign()
		eq(deck.current_page(), "campaign", "动效关闭：goto_campaign 同步到位")
		near(screen.main_panel().position.x, 0.0, 1.0, "动效关闭：主面板同步贴左")
		near(screen.campaign_panel().position.x, 640.0, 1.0, "动效关闭：战役面板同步到位")
		deck.goto_campaign_detail(screen.campaign_panel().current_chapter())
		eq(deck.current_page(), "detail", "动效关闭：详情同步到位")
		screen.handle_back()
		eq(deck.current_page(), "campaign", "动效关闭：返回同步到位")
		main.queue_free()
		await process_frame
	ThemeRes.set_animations_enabled(true)


func _spawn_main_instant():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var screen = main.start_screen
	screen.dismiss_intro()
	await process_frame
	return main
