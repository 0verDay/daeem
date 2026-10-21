## test_coop_entry.gd —— M12.4：test_2 不再是「单人进 02_twin_line」，而是打开合作大厅。
extends "res://tests/test_case.gd"

const StartScreenRes = preload("res://view/start_screen.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")

func _initialize() -> void:
	_case_name = "test_coop_entry"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	var screen = StartScreenRes.new()
	root.add_child(screen)
	await process_frame
	screen.setup(cfg, FontLoaderRes.load_font(cfg))
	screen.show_page(1)
	await _wait(10)

	var buttons: Array = screen.test_buttons()
	eq(buttons.size(), 3, "（前提）主界面还是三颗 test 按钮")
	if buttons.size() < 3:
		screen.queue_free()
		quit(1)
		return
	ok(String(buttons[1].text) == "test_2", "第二颗还是 test_2")
	ok(bool((screen._test_entries()[1] as Dictionary).get("coop", false)),
		"★ test_2 的数据带 coop 标记")

	(buttons[1] as Button).pressed.emit()
	var lobby = null
	for i in 120:
		await process_frame
		if screen._chrome != null:
			lobby = screen._chrome.coop_lobby()
		if lobby != null:
			break
	ok(screen._chrome != null, "（前提）主界面外壳在")
	ok(lobby != null, "★★ test_2 打开的是合作大厅，不是单人关")
	if lobby != null:
		ok(lobby.find_child("RoomList", true, false) != null, "大厅里有房间列表")
		ok(lobby.find_child("CodeEdit", true, false) != null, "大厅里有房间码输入框")
		ok(lobby.find_child("ActionBtn", true, false) != null, "大厅里有进入 / 创建按钮")
		ok(lobby.find_child("RoomPanel", true, false) != null, "大厅里有房间配置面板")
		ok(lobby.find_child("MapPanel", true, false) != null, "大厅里有地图选择面板")
		var lp = lobby.find_child("LobbyPanel", true, false)
		ok(lp != null, "大厅面板在")
		if lp != null:
			v2_near((lp as Control).global_position, Vector2(1372, 140), 2.0,
				"★ 大厅面板右缘与返回按钮对齐（宽度 500）")
		var back = lobby.get_parent().find_child("BackBtn", true, false)
		ok(back != null, "大厅返回按钮在")
		if back != null:
			await _wait(5)
			near((back as Control).global_position.x, 1712.0, 2.0,
				"★ 大厅返回按钮与战役面板同一距离（不贴屏幕边）")
			near((back as Control).global_position.y, 48.0, 2.0,
				"★ 返回按钮上方也留出战菜单同样的边距")
			if lp != null:
				near((lp as Control).global_position.x + (lp as Control).size.x,
					(back as Control).global_position.x + (back as Control).size.x, 2.0,
					"★ 大厅面板右缘 == 返回按钮右缘")

	screen.queue_free()
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
