## coop_ready_panel.gd —— 合作准备面板（640×1080，贴边）。
##
## 顶部地图缩略图（房主/AI 可点击换图）→ 地图描述 → 状态小字 → 准备/开始按钮。
## 返回由 MenuDeck 按来源处理：AI 回合作过渡；真人回房间。
extends "res://view/menu_page.gd"

signal map_requested
signal start_requested
signal ready_toggled(on: bool)

const MapThumbRes = preload("res://view/map_thumb.gd")

## 缩略图与地图按钮边框之间的留白。
const THUMB_MARGIN := 12.0

var session = null
var _source: String = "coop_start"
var _thumb_frame: Panel = null
var _map_btn: Button = null
var _thumb = null
var _map_hint: Label = null
var _desc_panel: Panel = null
var _map_name: Label = null
var _desc: RichTextLabel = null
var _status: Label = null
var _action: Button = null


func setup(p_cfg, p_font: Font, p_session) -> void:
	name = "CoopReadyPanel"
	session = p_session
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.ready", "详情")), true)

	_thumb_frame = Panel.new()
	_thumb_frame.name = "MapThumbFrame"
	_thumb_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_thumb_frame.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_thumb_frame.z_index = 5
	add_child(_thumb_frame)

	_map_btn = Button.new()
	_map_btn.name = "MapButton"
	_map_btn.text = ""
	_map_btn.focus_mode = Control.FOCUS_NONE
	_map_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_map_btn.add_theme_stylebox_override("normal", _flat_style(0.0))
	_map_btn.add_theme_stylebox_override("hover", _flat_style(0.10))
	_map_btn.add_theme_stylebox_override("pressed", _flat_style(0.18))
	_map_btn.add_theme_stylebox_override("focus", _flat_style(0.0))
	_map_btn.add_theme_stylebox_override("disabled", _flat_style(0.0))
	_map_btn.pressed.connect(func(): map_requested.emit())
	_thumb_frame.add_child(_map_btn)

	_thumb = MapThumbRes.new()
	_thumb.name = "MapThumb"
	_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_btn.add_child(_thumb)

	_map_hint = make_label("MapHint", "", 14, ThemeRes.accent_bright(),
		HORIZONTAL_ALIGNMENT_CENTER)
	_map_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_map_hint.z_index = 2
	_map_btn.add_child(_map_hint)

	_desc_panel = Panel.new()
	_desc_panel.name = "ReadyDesc"
	_desc_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc_panel.add_theme_stylebox_override("panel", MenuThemeRes.deck_block())
	_desc_panel.z_index = 5
	add_child(_desc_panel)

	_map_name = make_label("MapName", "", 26, ThemeRes.text())
	_map_name.position = Vector2(18.0, 10.0)
	_map_name.size = Vector2(520.0, 34.0)
	_desc_panel.add_child(_map_name)

	_desc = RichTextLabel.new()
	_desc.name = "MapDesc"
	_desc.bbcode_enabled = false
	_desc.fit_content = false
	_desc.scroll_active = false
	_desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_desc.clip_contents = true
	if font != null:
		_desc.add_theme_font_override("normal_font", font)
	_desc.add_theme_font_size_override("normal_font_size", 16)
	_desc.add_theme_color_override("default_color", ThemeRes.text_dim())
	_desc.position = Vector2(18.0, 50.0)
	_desc.size = Vector2(524.0, 138.0)
	_desc_panel.add_child(_desc)

	_status = make_label("ReadyStatus", "", 15, ThemeRes.text_faint())
	_status.position = LayoutRes.ready_status(0.0).position
	_status.size = LayoutRes.ready_status(0.0).size
	_status.clip_text = true
	_status.z_index = 5
	add_child(_status)

	_action = make_text_button("ReadyAction", "", 22)
	_action.pressed.connect(_on_action)
	_action.z_index = 5
	add_child(_action)

	_bind_session()
	resized.connect(_layout)
	_layout()
	refresh()


func _flat_style(alpha: float) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.accent_bright(), alpha)
	s.border_color = ThemeRes.with_alpha(ThemeRes.line(), 0.0)
	s.set_border_width_all(0)
	return s


func _bind_session() -> void:
	if session == null:
		return
	session.room_state_changed.connect(func(_s): refresh())
	session.room_config_changed.connect(func(_e): refresh())
	session.status_changed.connect(func(t): _set_status(t))
	session.rooms_changed.connect(func(_r): pass)


func set_source(source: String) -> void:
	_source = source


func source() -> String:
	return _source


func refresh() -> void:
	if session == null:
		return
	var entry: Dictionary = session.current_entry()
	if entry.is_empty():
		_thumb.visible = false
		_map_name.text = _txt("map_none", "无可用合作地图")
		_desc.text = ""
		_action.text = _txt("map_none", "无可用合作地图")
		_action.disabled = true
		_set_status("")
		return
	_thumb.visible = true
	_thumb.setup(cfg, session.map_data_for(entry))
	_thumb.set_cover(true)
	_map_name.text = String(entry.get("map_name", ""))
	_desc.text = String(entry.get("desc", ""))

	var is_guest: bool = session.is_guest()
	_map_btn.disabled = is_guest or not (session.is_ai() or session.is_host())
	_map_hint.text = _txt("map_hint_guest", "由房主选择地图") if is_guest \
		else _txt("map_hint_host", "点击更换地图")
	_refresh_status(entry)
	_refresh_action(entry)


func _refresh_status(entry: Dictionary) -> void:
	if session.is_ai():
		_status.text = "本地 AI 队友 · 难度 %s · %s" % [
			_txt("ai_teammate.labels.normal", "普通"), String(entry.get("map_name", ""))]
		return
	var code: String = session.room_code()
	var tail := ""
	if session.is_host():
		if not session.guest_joined():
			tail = _txt("wait_guest", "等待队友加入")
		elif not session.guest_ready():
			tail = _txt("wait_ready", "等待队友准备")
		else:
			tail = _txt("status_ready", "双方已准备")
	else:
		tail = _txt("ready", "准备") if not session.guest_ready() else _txt("cancel_ready", "取消准备")
	_status.text = "房间 %s · %s" % [code, tail] if code != "" else tail


func _refresh_action(entry: Dictionary) -> void:
	if session.is_ai():
		_action.text = _txt("ai_teammate.labels.start_ai", "开始")
		_action.disabled = false
		return
	if session.is_host():
		if not session.guest_joined():
			_action.text = _txt("wait_guest", "等待队友加入")
			_action.disabled = true
		elif not session.guest_ready():
			_action.text = _txt("wait_ready", "等待队友准备")
			_action.disabled = true
		else:
			_action.text = _txt("start", "开始")
			_action.disabled = false
	else:
		_action.text = _txt("cancel_ready", "取消准备") if session.guest_ready() \
			else _txt("ready", "准备")
		_action.disabled = false


func _on_action() -> void:
	if session == null:
		return
	if session.is_guest():
		var next: bool = not session.guest_ready()
		ready_toggled.emit(next)
		session.set_ready(next)
		refresh()
		return
	start_requested.emit()
	session.start()


func _set_status(text: String) -> void:
	# 连接/错误信息只作为临时状态显示；下一次 refresh 会被房间状态覆盖。
	if text.strip_edges() != "":
		_status.text = text


func _layout() -> void:
	if _thumb_frame == null:
		return
	var tr := LayoutRes.detail_thumb(size.x)
	_thumb_frame.position = tr.position
	_thumb_frame.size = tr.size
	_map_btn.position = Vector2(1.0, 1.0)
	_map_btn.size = tr.size - Vector2(2.0, 2.0)
	_thumb.position = Vector2(THUMB_MARGIN, THUMB_MARGIN)
	_thumb.size = _map_btn.size - Vector2(THUMB_MARGIN * 2.0, THUMB_MARGIN * 2.0)
	_map_hint.position = Vector2(12.0, _map_btn.size.y - 38.0)
	_map_hint.size = Vector2(_map_btn.size.x - 24.0, 30.0)

	var dr := LayoutRes.detail_desc(size.x)
	_desc_panel.position = dr.position
	_desc_panel.size = dr.size
	_map_name.size = Vector2(dr.size.x - 36.0, 34.0)
	_desc.size = Vector2(dr.size.x - 36.0, dr.size.y - 60.0)

	var sr := LayoutRes.ready_status(size.x)
	_status.position = sr.position
	_status.size = sr.size
	var ar := LayoutRes.ready_action(size.x)
	_action.position = ar.position
	_action.size = ar.size


func map_button() -> Button:
	return _map_btn


func thumb():
	return _thumb


func action_button() -> Button:
	return _action


func status_label() -> Label:
	return _status


func map_name_text() -> String:
	return _map_name.text if _map_name != null else ""


func map_desc_text() -> String:
	return _desc.text if _desc != null else ""


func _txt(key: String, fallback: String) -> String:
	if cfg == null:
		return fallback
	return String(cfg.str_val("coop.lobby." + key, fallback))
