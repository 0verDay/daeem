## menu_text_button.gd —— 主菜单的纯文字大按钮。
##
## 没有方框；鼠标悬停时左右各渐显一根金色短横线。
## 选中态由 MainMenuPanel 在灰层之上放一块同样的“标记层”，所以左移成侧栏后
## 文字与左右横线仍保持原样，而不是被灰层一起压暗。
extends Control

signal pressed

const ThemeRes = preload("res://view/theme.gd")

const DEFAULT_DASH := 0.42
const HOVER_DASH := 1.0

var _label: Label = null
var _hovered: bool = false
var _selected: bool = false
var _dash: float = DEFAULT_DASH
var _tween: Tween = null
var _font: Font = null
var _font_size: int = 44
var _text: String = ""


func setup(p_font: Font, text: String, font_size: int = 44) -> void:
	_font = p_font
	_font_size = font_size
	_text = text
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_NONE

	_label = Label.new()
	_label.name = "Text"
	_label.text = text
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_label.position = Vector2.ZERO
	_label.size = size
	if _font != null:
		_label.add_theme_font_override("font", _font)
	_label.add_theme_font_size_override("font_size", _font_size)
	_label.add_theme_color_override("font_color", ThemeRes.text())
	add_child(_label)
	_dash = DEFAULT_DASH
	queue_redraw()

	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	resized.connect(_layout_label)
	_layout_label()


func _layout_label() -> void:
	if _label == null:
		return
	# FULL_RECT 锚点由父节点决定；这里只保证文本在按钮正中。
	_label.position = Vector2.ZERO
	_label.size = size


func _on_hover(on: bool) -> void:
	_hovered = on
	_animate_dash()


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_animate_dash()


## 标记层用：立即显示/隐藏，不播 0.16s 的渐显。
func set_selected_immediate(on: bool) -> void:
	_selected = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_dash = HOVER_DASH if on else DEFAULT_DASH
	queue_redraw()


func is_selected() -> bool:
	return _selected


func set_passive() -> void:
	# 标记层：只画字与横线，不接收鼠标，也不响应悬停。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	mouse_default_cursor_shape = Control.CURSOR_ARROW


func _animate_dash() -> void:
	var target := HOVER_DASH if (_hovered or _selected) else DEFAULT_DASH
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if not ThemeRes.animations_enabled():
		_dash = target
		queue_redraw()
		return
	_tween = create_tween()
	_tween.tween_method(_set_dash, _dash, target, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _set_dash(v: float) -> void:
	_dash = clampf(v, 0.0, 1.0)
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			accept_event()
			pressed.emit()


func _draw() -> void:
	if _label == null:
		return
	var text_w: float = _label.get_minimum_size().x
	var gap: float = 22.0
	var full_len: float = 58.0
	var len: float = full_len * _dash
	var y: float = size.y * 0.5
	var t: float = clampf((_dash - DEFAULT_DASH) / (HOVER_DASH - DEFAULT_DASH), 0.0, 1.0)
	var c: Color = ThemeRes.line().lerp(ThemeRes.accent_bright(), t)
	c.a = lerpf(0.62, 1.0, t)
	var left_end: float = (size.x - text_w) * 0.5 - gap
	var right_start: float = (size.x + text_w) * 0.5 + gap
	draw_line(Vector2(left_end - len, y), Vector2(left_end, y), c, 2.0, true)
	draw_line(Vector2(right_start, y), Vector2(right_start + len, y), c, 2.0, true)


func text() -> String:
	return _text


func dash_amount() -> float:
	return _dash
