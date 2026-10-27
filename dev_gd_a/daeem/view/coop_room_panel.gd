## coop_room_panel.gd —— 合作房间面板（640×1080）。
##
## 上方房间列表 + 下方 6 位数字输入器。创建/加入成功由 session.room_entered 通知 deck
## 切到准备页；返回则退出房间回合作过渡。
extends "res://view/menu_page.gd"

signal room_entered

const RoomDirectoryRes = preload("res://net/room_directory.gd")

var session = null
var _list_panel: Panel = null
var _list_title: Label = null
var _refresh_btn: Button = null
var _scroll: ScrollContainer = null
var _rows_box: VBoxContainer = null
var _status: Label = null
var _input_panel: Panel = null
var _code_edit: LineEdit = null
var _key_buttons: Array = []
var _action_btn: Button = null
var _rows: Array = []


func setup(p_cfg, p_font: Font, p_session) -> void:
	name = "CoopRoomPanel"
	session = p_session
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.room", "房间")), true)

	_list_panel = Panel.new()
	_list_panel.name = "RoomListPanel"
	_list_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_list_panel.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_list_panel.z_index = 5
	add_child(_list_panel)

	_list_title = make_label("ListTitle", _txt("room_list", "房间列表"), 20,
		ThemeRes.accent())
	_list_title.position = Vector2(16.0, 12.0)
	_list_title.size = Vector2(320.0, 30.0)
	_list_panel.add_child(_list_title)

	_refresh_btn = make_text_button("RefreshBtn", _txt("refresh", "刷新"), 15)
	_refresh_btn.position = Vector2(444.0, 8.0)
	_refresh_btn.size = Vector2(120.0, 38.0)
	_refresh_btn.pressed.connect(func(): session.refresh_rooms())
	_list_panel.add_child(_refresh_btn)

	var list_bg := Panel.new()
	list_bg.name = "RoomListBox"
	list_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	list_bg.add_theme_stylebox_override("panel", MenuThemeRes.deck_panel())
	list_bg.position = Vector2(12.0, 52.0)
	_list_panel.add_child(list_bg)

	_scroll = ScrollContainer.new()
	_scroll.name = "RoomScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if _font_ok():
		pass
	list_bg.add_child(_scroll)

	_rows_box = VBoxContainer.new()
	_rows_box.name = "RoomRows"
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 6)
	_scroll.add_child(_rows_box)

	_status = make_label("RoomStatus", "", 15, ThemeRes.text_faint())
	_status.position = Vector2(24.0, 582.0)
	_status.size = Vector2(592.0, 24.0)
	_status.clip_text = true
	_status.z_index = 5
	add_child(_status)

	_input_panel = Panel.new()
	_input_panel.name = "RoomInputPanel"
	_input_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_input_panel.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_input_panel.z_index = 5
	add_child(_input_panel)

	_code_edit = LineEdit.new()
	_code_edit.name = "CodeEdit"
	_code_edit.max_length = 6
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_edit.placeholder_text = _txt("code_hint", "输入 6 位数字房间码")
	_code_edit.add_theme_font_size_override("font_size", 28)
	if font != null:
		_code_edit.add_theme_font_override("font", font)
	_code_edit.add_theme_stylebox_override("normal", MenuThemeRes.deck_panel())
	_code_edit.add_theme_stylebox_override("focus", MenuThemeRes.deck_panel())
	_code_edit.add_theme_color_override("font_color", ThemeRes.text())
	_code_edit.add_theme_color_override("font_placeholder_color", ThemeRes.text_faint())
	_code_edit.add_theme_color_override("caret_color", ThemeRes.accent_bright())
	_code_edit.text_changed.connect(_on_code_changed)
	_input_panel.add_child(_code_edit)

	for i in 12:
		var b := make_text_button("Key%d" % i, "", 22)
		b.position = LayoutRes.room_key_rect(0.0, i).position
		b.size = LayoutRes.room_key_rect(0.0, i).size
		_input_panel.add_child(b)
		_key_buttons.append(b)
	_configure_keys()

	_action_btn = make_text_button("ActionBtn", "", 20)
	_action_btn.position = LayoutRes.room_action(0.0).position
	_action_btn.size = LayoutRes.room_action(0.0).size
	_action_btn.pressed.connect(_on_action_pressed)
	_input_panel.add_child(_action_btn)

	_bind_session()
	resized.connect(_layout)
	_layout()
	_update_action()


func _font_ok() -> bool:
	return font != null


func _bind_session() -> void:
	if session == null:
		return
	session.rooms_changed.connect(_on_rooms_changed)
	session.status_changed.connect(_on_status)
	session.room_entered.connect(_on_room_entered)
	session.room_state_changed.connect(_on_room_state)
	session.room_config_changed.connect(func(_e): _update_action())
	session.rooms_changed.connect(func(_r): _update_action())
	session.status_changed.connect(func(_t): _update_action())


func _configure_keys() -> void:
	var digits := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "清空", ""]
	for i in _key_buttons.size():
		var b: Button = _key_buttons[i]
		var label := String(digits[i])
		b.text = label
		b.visible = label != ""
		if label == "":
			continue
		if label == "清空":
			b.pressed.connect(_on_clear)
		else:
			b.pressed.connect(_append_digit.bind(label))


func _on_rooms_changed(rooms: Array) -> void:
	for c in _rows:
		if is_instance_valid(c):
			c.queue_free()
	_rows.clear()
	if rooms.is_empty():
		var e := make_label("RoomEmpty", _txt("empty_rooms", "暂无房间，输入房间码创建"),
			15, ThemeRes.text_faint())
		e.custom_minimum_size = Vector2(0.0, 48.0)
		e.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_rows_box.add_child(e)
		_rows.append(e)
	else:
		for item in rooms:
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = item
			var code := String(d.get("code", ""))
			var joinable := bool(d.get("joinable", false))
			var row := make_text_button("RoomRow_%s" % code,
				"%s    %s" % [code, String(d.get("label", ""))], 16)
			row.custom_minimum_size = Vector2(0.0, 48.0)
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.disabled = not joinable
			if joinable:
				row.pressed.connect(_fill_code.bind(code))
			_rows_box.add_child(row)
			_rows.append(row)
	_list_title.text = "%s  %d" % [_txt("room_list", "房间列表"), rooms.size()]


func _on_room_entered(_role: String, _code: String) -> void:
	room_entered.emit()


func _on_room_state(_state: Dictionary) -> void:
	_update_action()


func _on_status(text: String) -> void:
	if _status != null:
		_status.text = text


func _on_code_changed(_text: String) -> void:
	var filtered := ""
	for i in _code_edit.text.length():
		var c := _code_edit.text.substr(i, 1)
		if c >= "0" and c <= "9":
			filtered += c
	if filtered != _code_edit.text:
		_code_edit.text = filtered
		_code_edit.caret_column = filtered.length()
	_update_action()


func _append_digit(d: String) -> void:
	if _code_edit.text.length() >= 6:
		return
	_code_edit.text += d
	_code_edit.caret_column = _code_edit.text.length()
	_update_action()


func _on_clear() -> void:
	_code_edit.text = ""
	_update_action()


func _fill_code(code: String) -> void:
	_code_edit.text = code
	_code_edit.caret_column = code.length()
	_update_action()


func _code() -> String:
	return _code_edit.text.strip_edges()


func _update_action() -> void:
	if _action_btn == null:
		return
	var code := _code()
	if code.length() < 6:
		_action_btn.text = _txt("need_code", "输入 6 位房间码")
		_action_btn.disabled = true
		return
	var room := RoomDirectoryRes.find_room(session.rooms(), code) if session != null else {}
	if room.is_empty():
		_action_btn.text = _txt("create", "创建房间")
		_action_btn.disabled = false
	elif bool(room.get("joinable", false)):
		_action_btn.text = _txt("enter", "加入房间")
		_action_btn.disabled = false
	elif String(room.get("status", "")) == "playing":
		_action_btn.text = _txt("playing", "对局中")
		_action_btn.disabled = true
	else:
		_action_btn.text = _txt("room_full", "房间已满")
		_action_btn.disabled = true


func _on_action_pressed() -> void:
	if session == null or _code().length() < 6:
		return
	_action_btn.disabled = true
	session.create_or_join(_code())


func _layout() -> void:
	if _list_panel == null:
		return
	var lr := LayoutRes.room_list(size.x)
	_list_panel.position = lr.position
	_list_panel.size = lr.size
	var list_bg := _list_panel.get_node_or_null("RoomListBox") as Panel
	if list_bg != null:
		list_bg.size = Vector2(lr.size.x - 24.0, lr.size.y - 64.0)
		_scroll.position = Vector2(8.0, 8.0)
		_scroll.size = list_bg.size - Vector2(16.0, 16.0)

	var ir := LayoutRes.room_input(size.x)
	_input_panel.position = ir.position
	_input_panel.size = ir.size
	var cr := LayoutRes.room_code_display(ir.size.x)
	_code_edit.position = cr.position
	_code_edit.size = cr.size
	for i in _key_buttons.size():
		var r := LayoutRes.room_key_rect(ir.size.x, i)
		var b: Button = _key_buttons[i]
		b.position = r.position
		b.size = r.size
	var ar := LayoutRes.room_action(ir.size.x)
	_action_btn.position = ar.position
	_action_btn.size = ar.size


func code_edit() -> LineEdit:
	return _code_edit


func action_button() -> Button:
	return _action_btn


func refresh_button() -> Button:
	return _refresh_btn


func room_rows() -> Array:
	return _rows


func status_label() -> Label:
	return _status


func _txt(key: String, fallback: String) -> String:
	if cfg == null:
		return fallback
	return String(cfg.str_val("coop.lobby." + key, fallback))
