## test_settings_menu.gd —— ★ 游戏内「设置」二级菜单：全屏 / 返回主菜单
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：地图选择条已经搬进「战役」面板（见
##   view/battle_entries.gd），所以直接问逻辑层要默认地图（与面板默认选中的是同一张）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const UiLayoutRes = preload("res://view/ui_layout.gd")

const PAGE_MENU := 1

const CLICK_CENTER := Vector2(960.0, 540.0)

func _initialize() -> void:
	_case_name = "test_settings_menu"
	_run()

func _run() -> void:
	await process_frame
	await _test_menu_structure()
	await _test_fullscreen_request()
	await _test_return_to_menu()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_menu_structure() -> void:
	var main = await _enter_game()
	if main == null:
		ok(false, "能进游戏（后面几条都在游戏里验）")
		return
	var hud = main.game.hud

	var panel = hud.get_node_or_null("HudRoot/SettingsMenu")
	ok(panel is PanelContainer, "设置面板挂在 HudRoot 下（SettingsMenu）")
	var fullscreen = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/FullscreenButton")
	var to_menu = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/ReturnMenuButton")
	ok(fullscreen is Button, "面板里有一颗「全屏」按钮")
	ok(to_menu is Button, "面板里有一颗「返回主菜单」按钮")

	if panel is Control and fullscreen is Button and to_menu is Button:
		var p: Control = panel

		eq((fullscreen as Button).text, hud.cfg.str_val("settings.fullscreen_off_text", "全屏"),
			"「全屏」按钮的文案来自 config")
		eq((to_menu as Button).text, hud.cfg.str_val("settings.menu_text", "返回主菜单"),
			"「返回主菜单」按钮的文案来自 config")
		eq(hud.settings_button.text, hud.cfg.str_val("settings.title", "设置"),
			"设置按钮本身的文案也来自 config")

		ok(not p.visible, "★ 刚进游戏时设置面板是收着的")

		var btn_center: Vector2 = hud.settings_button.get_global_rect().get_center()
		await _click_at(btn_center)
		ok(p.visible, "★ 点设置按钮 → 面板弹出来")
		await _click_at(btn_center)
		ok(not p.visible, "★ 再点一下 → 面板收回去（开关式）")

		hud.set_settings_menu_open(true)
		await process_frame
		ok(p.visible, "（前提）面板已经打开")

		var btn_rect: Rect2 = hud.settings_button.get_global_rect()
		var panel_rect: Rect2 = p.get_global_rect()
		ok(panel_rect.position.y >= btn_rect.end.y - 1.0,
			"★ 面板在设置按钮**下方**（按钮底 %.0f ≤ 面板顶 %.0f）"
			% [btn_rect.end.y, panel_rect.position.y])
		ok(not panel_rect.intersects(btn_rect), "面板与设置按钮不重叠")
		ok(panel_rect.size.x > 0.0 and panel_rect.size.y > 0.0, "面板有实际尺寸（没缩成一团）")
		ok(panel_rect.size.y >= UiLayoutRes.SETTINGS_MENU_ITEM_H * 2.0,
			"★ 面板装得下两颗按钮（高度 %.0f ≥ 两格 %.0f）"
			% [panel_rect.size.y, UiLayoutRes.SETTINGS_MENU_ITEM_H * 2.0])
		var fr: Rect2 = (fullscreen as Control).get_global_rect()
		var tr: Rect2 = (to_menu as Control).get_global_rect()
		ok(tr.position.y >= fr.end.y - 1.0, "「返回主菜单」在「全屏」下面")
		ok(tr.size.y > 0.0 and fr.size.y > 0.0, "两颗按钮都有实际高度")
		ok(absf(panel_rect.end.x - btn_rect.end.x) < 40.0,
			"面板靠在设置按钮那一侧（右边缘 %.0f vs 按钮右边缘 %.0f）"
			% [panel_rect.end.x, btn_rect.end.x])

		eq(p.mouse_filter, Control.MOUSE_FILTER_STOP,
			"★ 面板整块吃鼠标（STOP）—— 不然点它会穿到地图，顺手给单位下命令")
		eq((fullscreen as Control).mouse_filter, Control.MOUSE_FILTER_STOP,
			"「全屏」按钮吃鼠标")
		eq((to_menu as Control).mouse_filter, Control.MOUSE_FILTER_STOP,
			"「返回主菜单」按钮吃鼠标")

		hud.set_settings_menu_open(false)

	await _dispose(main)

func _test_fullscreen_request() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	hud.set_settings_menu_open(true)
	await process_frame

	ok(hud.fullscreen_toggled.is_connected(Callable(game, "_on_fullscreen_toggled")),
		"★ hud 的「全屏」请求接到了 game_scene")
	ok(game.fullscreen_toggled.is_connected(Callable(main, "toggle_fullscreen")),
		"★ game_scene 又把它转给了 main.toggle_fullscreen（窗口模式只在那里改）")

	var before_mode: int = DisplayServer.window_get_mode()
	var page_before := String(hud.page_tabs.page())
	var center: Vector2 = hud.fullscreen_button.get_global_rect().get_center()
	await _click_at(center)
	ok(true, "★ 按下「全屏」不报错（信号链走通）")
	eq(String(hud.page_tabs.page()), page_before, "切全屏不会顺手切页签")
	eq(DisplayServer.window_get_mode(), before_mode,
		"⚠️ 无头下窗口模式不变（DisplayServer 是空实现）——这条只保证没崩")
	ok(hud.settings_panel.visible, "按全屏不会把设置面板收掉（玩家可能还想按第二项）")

	var label := String(hud.fullscreen_button.text)
	var expect: String = hud.cfg.str_val("settings.fullscreen_off_text", "全屏")
	if hud._is_fullscreen():
		expect = hud.cfg.str_val("settings.fullscreen_on_text", "窗口化")
	eq(label, expect, "★ 按钮文案跟着当前窗口状态走（全屏时写「窗口化」）")

	ok(main.has_method("toggle_fullscreen"),
		"★ main 有一个公开的 toggle_fullscreen（Ctrl+Q 与设置菜单共用它）")
	main.toggle_fullscreen()          # 无头下什么都不发生，只要求不崩
	ok(true, "直接调 main.toggle_fullscreen() 不报错")

	hud.set_settings_menu_open(false)
	await _dispose(main)

func _test_return_to_menu() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	var screen = main.start_screen
	hud.set_settings_menu_open(true)
	await process_frame
	ok(hud.settings_panel.visible, "（前提）设置面板开着")

	await _click_settings_item(main, "ReturnMenuButton")

	eq(main.game, null, "★ 点「返回主菜单」→ main 的游戏句柄清空")
	ok(main.get_node_or_null("GameScene") == null,
		"★ GameScene 节点已经不在树上了（不只是 queue_free 排队）")
	var still_in_tree: bool = is_instance_valid(game) and game.is_inside_tree()
	ok(not still_in_tree, "★ 旧游戏场景立刻离开了场景树（这一帧就不再跑逻辑 / 收输入）")

	ok(screen.visible, "★ 开场页重新可见（整层 show() 了，不只是页内两层）")
	eq(int(screen.page()), PAGE_MENU,
		"★ 回到的是**主界面**那一页（不收入场页：那一次「点击任意处」玩家已经付过）")
	ok(screen.get_node("StartRoot/MainMenu").visible, "主界面那一层可见")
	ok(not screen.get_node("StartRoot/Intro").visible, "入场页那一层没有回来")
	ok(screen.get_node("StartRoot/Background").visible,
		"背景那一层回来了（菜单不是浮在游戏画面上）")

	# ★★ 地图选择条 / test 现在住在**「战役」面板**里（view/battle_entries.gd）——
	#   回到菜单之后要先把那块面板撑开，才能拿到它们（面板开时建、关时销毁）。
	var entries = await open_battle_panel(screen)
	ok(entries != null, "★★ 回到菜单后能撑开「战役」面板，里面有地图选择条与 test")
	if entries == null:
		main.queue_free()
		return
	ok(entries.map_select_item_count() > 0
			and entries.map_select_item_count() == entries.map_options().size(),
		"★ 选择条的选项来自目录扫描（%d 条）" % entries.map_select_item_count())

	var sel_node: Button = entries.map_select_button()
	await _hover_at((sel_node as Control).get_global_rect().get_center())
	ok(root.gui_get_hovered_control() != null,
		"★ 回到菜单后鼠标停在选择条上有控件接住（背景那一层活着，不是「看着在、点不动」）")

	var tb: Button = entries.test_button()
	ok(tb is Button and tb.get_global_rect().size.y > 1.0, "（前提）test 按钮排过版了")
	await _click_at(tb.get_global_rect().get_center())
	var second = main.game
	ok(second != null, "★ 回到菜单之后再按 test 能开出一局新的")
	ok(second != game, "★ 新一局是**新的** game_scene（不是那个已经被拆掉的）")
	if second != null:
		ok(second.world != null, "新一局的世界建出来了")
		ok(second.get_node_or_null("Hud") != null, "新一局的 HUD 也在")
		ok(main.get_node_or_null("GameScene") == second, "新的 GameScene 挂在 main 下")
		ok(not screen.visible, "★ 进新一局之后开场页又整层下线了")

		second.hud.return_menu_button.emit_signal("pressed")
		await process_frame
		eq(main.game, null, "★ 第二次返回菜单同样生效（不是只能回一次）")
		ok(screen.visible, "★ 第二次回来主界面同样可见")
		await _hover_at((sel_node as Control).get_global_rect().get_center())
		ok(root.gui_get_hovered_control() != null, "★ 第二次回来照样点得动")

	await _dispose(main)

func _enter_game() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main.start_screen.dismiss_intro()
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

func _click_settings_item(main, node_name: String) -> void:
	if main.game == null:
		ok(false, "（前提）还在游戏里，设置菜单才点得到")
		return
	var hud = main.game.hud
	hud.set_settings_menu_open(true)
	await process_frame
	var item = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/%s" % node_name)
	if not (item is Button):
		ok(false, "设置菜单里有 %s 可以点" % node_name)
		return
	await _click_at((item as Control).get_global_rect().get_center())

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
