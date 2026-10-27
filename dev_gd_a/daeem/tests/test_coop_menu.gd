## test_coop_menu.gd —— 合作过渡 / 房间 / 准备 / 地图选择。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")

func _initialize() -> void:
	_case_name = "test_coop_menu"
	_run()


func _run() -> void:
	await process_frame
	await _test_flow()
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
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_page(screen.menu_deck(), "main")
	await _wait_sec(0.9)
	return main


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()


func _test_flow() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var coop_start = screen.coop_start_panel()
	var ready = screen.coop_ready_panel()

	screen.main_panel().main_buttons()[1].pressed.emit()
	ok(await _wait_page(deck, "coop_start"), "点合作进入合作过渡")
	near(coop_start.position.x, 640.0, 1.0, "合作面板在右 2/3")
	ok(screen.main_panel().is_sidebar_dimmed(), "主菜单侧栏灰层")
	eq(screen.main_panel().active_index(), 1, "合作页左侧「合作」按钮保持选中")
	ok(screen.main_panel().active_marker() != null, "合作选中标记层存在")
	if screen.main_panel().active_marker() != null:
		eq(screen.main_panel().active_marker().text(), "合作", "合作选中标记文字")
	ok(coop_start.player_flag() != null, "有玩家旗帜")
	ok(coop_start.empty_flag() != null, "有虚位旗帜")

	# 点虚位旗 → AI 准备
	coop_start.empty_flag().pressed.emit()
	ok(await _wait_page(deck, "coop_ready"), "点虚位旗进入准备页")
	eq(ready.source(), "coop_start", "准备页来源是合作过渡")
	ok(deck.session().is_ai(), "会话进入本地 AI 模式")
	eq(coop_start.empty_flag().kind(), "player", "虚位旗变成 AI 队友旗")
	eq(coop_start.empty_flag().title_text(), "AI 队友", "AI 旗标题")
	eq(coop_start.empty_flag().subtitle_text(), "已加入", "AI 旗副标题")
	eq(deck.session().mode(), "ai", "会话 mode=ai")
	ok(ready.action_button().disabled == false, "AI 准备页开始按钮可用")
	ok(ready.action_button().text.contains("开始"), "AI 准备页按钮是开始")
	ok(ready.status_label().text.contains("AI"), "准备页状态显示本地 AI")
	ok(ready.map_name_text() != "", "准备页有地图名")
	ok(ready.thumb().has_map(), "准备页缩略图有地图")

	# 地图选择层：右侧滑入，选第二张并确认
	var first_level := String(deck.session().current_entry().get("level", ""))
	deck.open_map_picker()
	ok(await _wait_map(deck, true), "地图选择面板滑入")
	ok(screen.handle_back(), "地图选择打开时返回被受理")
	ok(await _wait_map(deck, false), "返回只关闭地图选择，不改地图")
	eq(String(deck.session().current_entry().get("level", "")), first_level,
		"取消地图选择不改当前地图")
	deck.open_map_picker()
	ok(await _wait_map(deck, true), "地图选择可再次滑入")
	var picker = deck.map_picker()
	ok(picker.cards().size() >= 2, "地图选择至少两张地图")
	if picker.cards().size() >= 2:
		picker.cards()[1].pressed.emit()
		await process_frame
		picker.confirm_button().pressed.emit()
		ok(await _wait_map(deck, false), "确认后地图选择面板滑出")
		ok(String(deck.session().current_entry().get("level", "")) != first_level,
			"确认后切换到另一张地图")
		ok(ready.map_name_text() != "", "准备页地图名同步")
	else:
		picker.cancel_button().pressed.emit()
		await _wait_map(deck, false)

	# AI 准备页返回：回合作过渡并清掉本地会话
	ok(screen.handle_back(), "AI 准备页返回被受理")
	ok(await _wait_page(deck, "coop_start"), "AI 准备页 → 合作过渡")
	eq(deck.session().mode(), "idle", "AI 返回后会话回到 idle")
	near(coop_start.position.x, 640.0, 1.0, "AI 返回后合作面板回右")
	ok(screen.main_panel().is_sidebar_dimmed(), "AI 返回后主菜单仍在灰层")

	# 再进一次 AI，验证开始
	eq(coop_start.empty_flag().kind(), "empty", "返回合作过渡后虚位旗恢复")
	coop_start.empty_flag().pressed.emit()
	ok(await _wait_page(deck, "coop_ready"), "再次进入 AI 准备页")
	ok(deck.session().is_ai(), "再次进入仍是 AI 模式")

	# AI 开始 → 游戏
	ready.action_button().pressed.emit()
	ok(await _wait_until(func(): return main.game != null, 15000), "AI 准备页开始 → 建出合作游戏")
	if main.game != null:
		ok(not screen.visible, "进游戏后菜单隐藏")
		await _wait_sec(1.0)
	main.queue_free()
	await _wait_sec(1.2)
	await _test_room_and_back()


func _test_room_and_back() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	screen.main_panel().main_buttons()[1].pressed.emit()
	ok(await _wait_page(deck, "coop_start"), "（二）合作过渡")
	var coop_start = screen.coop_start_panel()
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	coop_start._on_blank_input(ev)
	ok(await _wait_page(deck, "coop_room"), "点空白进入合作房间")
	var room = screen.coop_room_panel()
	near(coop_start.position.x, 0.0, 1.0, "合作面板左移")
	near(room.position.x, 1280.0, 1.0, "房间面板在右")
	ok(coop_start.is_sidebar_dimmed(), "合作面板侧栏灰层")
	ok(room.code_edit() != null, "房间有房间码输入")
	ok(room.action_button() != null, "房间有创建/加入按钮")
	room.code_edit().text = "123456"
	room._on_code_changed("123456")
	await process_frame
	ok(room.action_button().text != "", "6 位码后按钮有文案")
	ok(room.action_button().text.contains("创建"), "无此房时按钮是创建房间")

	ok(screen.handle_back(), "房间返回被受理")
	ok(await _wait_page(deck, "coop_start"), "房间 → 合作过渡")
	ok(not coop_start.is_sidebar_dimmed(), "合作过渡回到右侧后灰层关闭")
	ok(screen.handle_back(), "合作过渡返回被受理")
	ok(await _wait_page(deck, "main"), "合作过渡 → 主菜单")

	main.queue_free()
	await _wait_sec(0.2)


func _wait_map(deck, open: bool, timeout_ms: int = 4000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.is_map_open() == open and not deck.is_busy():
			return true
		await process_frame
	return deck.is_map_open() == open and not deck.is_busy()


func _wait_until(cond: Callable, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()
