## test_coop_ui.gd —— 合作大厅的三态 UI：房间码键盘 / 按钮三态 / 地图选择 / 返回语义。
##
## 不连网：只验界面状态与几何；真实中继流程在 test_coop_lobby.gd。
extends "res://tests/test_case.gd"

const CoopLobbyRes = preload("res://view/coop_lobby.gd")
const LobbyRes = preload("res://net/lobby.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")


func _initialize() -> void:
	_case_name = "test_coop_ui"
	_run()


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	var old_url := ""
	if cfg.data.has("net") and typeof(cfg.data["net"]) == TYPE_DICTIONARY:
		old_url = String((cfg.data["net"] as Dictionary).get("relay_url", ""))
		(cfg.data["net"] as Dictionary)["relay_url"] = "ws://127.0.0.1:1/ws"
	var lobby = CoopLobbyRes.new()
	root.add_child(lobby)
	lobby.setup(cfg, FontLoaderRes.load_font(cfg))
	lobby.set_animation_sec(0.0)
	await process_frame

	eq(lobby.state_name(), "lobby", "★ 初始状态是大厅")
	ok(lobby.find_child("LobbyPanel", true, false) != null, "大厅面板在")
	ok(lobby.find_child("RoomPanel", true, false) != null, "房间面板在")
	ok(lobby.find_child("MapPanel", true, false) != null, "地图面板在")
	ok(lobby.find_child("RoomList", true, false) != null, "房间列表在")
	ok(lobby.find_child("RoomListBox", true, false) != null, "房间列表有单独的边框面板")
	var empty_list = lobby.find_child("RoomList", true, false)
	ok(empty_list != null, "（前提）房间列表控件在")
	if empty_list != null:
		# 没有房间时也要能拖动，用来验证橡皮筋 / 回弹
		var p0 := InputEventMouseButton.new()
		p0.button_index = MOUSE_BUTTON_LEFT
		p0.pressed = true
		p0.global_position = empty_list.global_position + Vector2(20, 20)
		empty_list._input(p0)
		var m0 := InputEventMouseMotion.new()
		m0.global_position = p0.global_position + Vector2(0, -60)
		empty_list._input(m0)
		ok(absf(empty_list.logical_offset()) > 0.0,
			"★ 没有房间时也能拖动列表（逻辑偏移 %s）" % str(empty_list.logical_offset()))
		var r0 := InputEventMouseButton.new()
		r0.button_index = MOUSE_BUTTON_LEFT
		r0.pressed = false
		r0.global_position = m0.global_position
		empty_list._input(r0)
		empty_list.scroll_to(0.0)
	var header = lobby.find_child("RoomListHeader", true, false)
	var refresh = lobby.find_child("RefreshBtn", true, false)
	ok(header != null and refresh != null, "（前提）刘海与刷新按钮在")
	if header != null and refresh != null:
		var rr := Rect2((refresh as Control).position, (refresh as Control).size)
		ok(Rect2(Vector2.ZERO, (header as Control).size).encloses(rr),
			"★ 刷新按钮完整落在刘海底框内（不乱跑）")

	# 房间列表：条数超过一屏时能滚，越界拖动有橡皮筋（elastic_scroll_list）
	var many_rooms: Array = []
	for i in 12:
		many_rooms.append({"code": "1000%02d" % i, "status": "lobby", "label": "等待中", "joinable": true})
	lobby._rooms = many_rooms
	lobby._render_rooms()
	await _wait(3)
	var room_list = lobby.find_child("RoomList", true, false)
	ok(room_list != null, "（前提）房间列表控件在")
	if room_list != null:
		ok(room_list.max_scroll() > 0.0, "★ 12 个房间超过一屏 → 列表可滚动")
		room_list.scroll_to(room_list.max_scroll() + 120.0)
		ok(room_list.display_offset() > room_list.max_scroll(),
			"★ 拉到底还能再拖出一段（过量拖动 / 回弹）")
		room_list.scroll_to(0.0)
		# 鼠标拖动：按下后往上拖 80px，列表内容跟着滚
		var press := InputEventMouseButton.new()
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		press.global_position = room_list.global_position + Vector2(20, 20)
		room_list._input(press)
		var motion := InputEventMouseMotion.new()
		motion.global_position = press.global_position + Vector2(0, -80)
		room_list._input(motion)
		ok(room_list.logical_offset() > 0.0, "★ 上下拖动真的滚动了列表")
		var release := InputEventMouseButton.new()
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		release.global_position = motion.global_position
		room_list._input(release)
		room_list._settle_to_clamped()
		room_list.scroll_to(0.0)
	lobby._rooms = []
	lobby._render_rooms()

	# 返回按钮：大厅在右上，地图选择滑到左上（3.png）
	var back := Button.new()
	back.name = "FakeBack"
	root.add_child(back)
	lobby.attach_back_button(back)
	await _wait(3)
	eq(back.position, Vector2(1712, 48), "★ 大厅返回按钮在右上（与战役面板同距）")

	# ---- 房间码 / 键盘 / 按钮三态
	var code := lobby.find_child("CodeEdit", true, false) as LineEdit
	var action := lobby.find_child("ActionBtn", true, false) as Button
	ok(code != null and action != null, "（前提）输入框与动作按钮在")
	code.text = "12345"
	lobby._on_code_changed("12345")
	ok(action.disabled, "★ 不足 6 位：动作按钮置灰")
	eq(action.text, "", "★ 不足 6 位：按钮不显示任何字")

	lobby._append_digit("6")
	eq(code.text, "123456", "★ 键盘 / 输入补满 6 位")
	ok(not action.disabled, "6 位且无此房间：按钮可用")
	eq(action.text, "创建房间", "★ 6 位且无此房间 → 「创建房间」")

	lobby._rooms = [{"code": "123456", "status": "lobby", "label": "等待中", "joinable": true}]
	lobby._update_action()
	eq(action.text, "加入房间", "★ 6 位且房间存在 → 「加入房间」")

	lobby._rooms = [{"code": "123456", "status": "full", "label": "已满", "joinable": false}]
	lobby._update_action()
	ok(action.disabled and action.text == "房间已满", "★ 已满房间 → 按钮禁用")

	lobby._rooms = [{"code": "123456", "status": "playing", "label": "游戏中", "joinable": false}]
	lobby._update_action()
	ok(action.disabled and action.text == "对局中", "★ 游戏中房间 → 按钮禁用")

	lobby._clear_code()
	eq(code.text, "", "★ 清除按钮清空房间码")
	(lobby.find_child("Key1", true, false) as Button).pressed.emit()
	(lobby.find_child("Key2", true, false) as Button).pressed.emit()
	eq(code.text, "12", "★ 数字键盘真的把 1、2 填进输入框")
	lobby._clear_code()
	lobby._rooms = [{"code": "123456", "status": "lobby", "label": "等待中", "joinable": true}]
	lobby._render_rooms()
	var row = lobby.find_child("RoomRow_123456", true, false)
	ok(row != null, "房间列表渲染出可点行")
	if row != null:
		(row as Button).pressed.emit()
		eq(code.text, "123456", "★ 点房间行 → 自动填入房间码")
	lobby._clear_code()

	# ---- 房间面板：host 无队友 → 等待队友；guest → 准备
	var fake = LobbyRes.new()
	fake.my_role = "host"
	fake.room = {"code": "123456", "host": true, "guest": false, "ready_guest": false}
	lobby._lobby = fake
	lobby._on_room_state(fake.room)
	eq(lobby.state_name(), "room", "★ 房主收到 room_state → 房间面板")
	eq(lobby.find_child("RoomActionBtn", true, false).text, "等待队友加入",
		"★ 没队友时房主按钮「等待队友加入」")
	ok(lobby.find_child("RoomActionBtn", true, false).disabled, "★ 没队友时按钮禁用")

	fake.my_role = "guest"
	fake.room = {"code": "123456", "host": true, "guest": true, "ready_guest": false}
	lobby._on_room_state(fake.room)
	eq(lobby.find_child("RoomActionBtn", true, false).text, "准备",
		"★ 客机未准备 → 「准备」")
	fake.room["ready_guest"] = true
	lobby._on_room_state(fake.room)
	eq(lobby.find_child("RoomActionBtn", true, false).text, "取消准备",
		"★ 客机已准备 → 「取消准备」")

	# ---- 地图选择：host 打开 → 确认 → 回房间
	fake.my_role = "host"
	fake.room = {"code": "123456", "host": true, "guest": false, "ready_guest": false}
	lobby._current_entry = lobby._entries[0] if not lobby._entries.is_empty() else {}
	ok(not lobby._current_entry.is_empty(), "（前提）有合作地图")
	lobby._open_map_select()
	eq(lobby.state_name(), "map", "★ 点地图预览 → 地图选择界面")
	eq(back.position, Vector2(60, 48), "★ 地图选择时返回按钮滑到左上")
	eq(lobby.find_child("RoomActionBtn", true, false).text, "确认",
		"★ 地图选择时按钮变「确认」")
	var card = lobby._map_cards[0] if not lobby._map_cards.is_empty() else null
	ok(card != null, "（前提）地图列表有卡片")
	if card != null:
		card.pressed.emit()
		ok(lobby._pending_entry != null and not lobby._pending_entry.is_empty(),
			"★ 点卡片选中待确认地图")
	lobby._apply_pending_map()
	eq(lobby.state_name(), "room", "★ 确认后回房间面板")
	ok(not lobby._current_entry.is_empty(), "★ 地图已应用")

	# ---- 返回语义
	lobby._open_map_select()
	ok(lobby.handle_back(), "★ MAP 返回被大厅消费")
	eq(lobby.state_name(), "room", "★ MAP 返回 → 房间（放弃改图）")
	ok(lobby.handle_back(), "★ ROOM 返回被大厅消费")
	eq(lobby.state_name(), "lobby", "★ ROOM 返回 → 大厅（退出房间）")
	ok(not lobby.handle_back(), "★ LOBBY 返回不消费（交给面板收起）")

	# 收回动效：按面板尺寸整体缩小，而不是只裁切内容
	lobby._scale_base = Vector2(1000, 800)
	lobby.size = Vector2(500, 400)
	lobby._apply_collapse_scale()
	near(lobby.scale.x, 0.5, 0.001, "★ 面板收回到一半尺寸 → 内容缩到 0.5")
	near(lobby.pivot_offset.x, 250.0, 0.01, "★ 以面板中心为缩放轴")
	lobby.scale = Vector2.ONE

	lobby.queue_free()
	back.queue_free()
	if cfg.data.has("net") and old_url != "":
		(cfg.data["net"] as Dictionary)["relay_url"] = old_url
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
