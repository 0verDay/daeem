## troop_seat.gd —— 合作大厅左 / 中两块玩家席位卡片（参考 art_draft/1.png）。
##
## 只显示：头像占位 + 名字（本轮统一 player）+ 身份（房主 / 队友）+ 状态
## （等待队友 / 已准备 / 未准备）。不联网、不读 world。
extends Panel

const UiStyleRes = preload("res://view/ui_style.gd")
const CoopLayoutRes = preload("res://view/coop_layout.gd")

var _avatar: Label = null
var _name: Label = null
var _role: Label = null
var _status: Label = null
var _filled: bool = false
var _font: Font = null


func setup(p_font: Font = null) -> void:
	_font = p_font
	add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line_soft()))
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_avatar = _label("SeatAvatar", "将", 48, UiStyleRes.accent())
	_avatar.position = CoopLayoutRes.SEAT_AVATAR.position
	_avatar.size = CoopLayoutRes.SEAT_AVATAR.size
	_avatar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_avatar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_avatar)

	_name = _label("SeatName", "", 28, UiStyleRes.text())
	_name.position = Vector2(20.0, CoopLayoutRes.SEAT_NAME_Y)
	_name.size = Vector2(320.0, 36.0)
	_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_name)

	_role = _label("SeatRole", "", 16, UiStyleRes.text_dim())
	_role.position = Vector2(20.0, CoopLayoutRes.SEAT_ROLE_Y)
	_role.size = Vector2(320.0, 24.0)
	_role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_role)

	_status = _label("SeatStatus", "", 18, UiStyleRes.text_faint())
	_status.position = Vector2(20.0, CoopLayoutRes.SEAT_STATUS_Y)
	_status.size = Vector2(320.0, 28.0)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_status)

	set_seat("", "", "", false, false)


func set_seat(player_name: String, role: String, status: String, filled: bool,
		ready: bool = false) -> void:
	_filled = filled
	_name.text = player_name if filled else "等待队友…"
	_role.text = role if filled else ""
	_status.text = status
	_status.add_theme_color_override("font_color",
		UiStyleRes.accent() if ready else UiStyleRes.text_faint())
	_name.add_theme_color_override("font_color",
		UiStyleRes.text() if filled else UiStyleRes.text_faint())
	modulate.a = 1.0 if filled else 0.55


func is_filled() -> bool:
	return _filled


func _label(node_name: String, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l
