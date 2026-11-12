## menu_text_button.gd —— 主菜单的纯文字大按钮。
##
## 没有方框；鼠标悬停时左右各渐显一根金色短横线，并在**两端补一对短竖线**
## `|— 战役 —|`（与矩形按钮的瞄准框同一套「线 + 几何」语言）。
## 按下：横线回缩 18%、文字下沉 1px；**松手且指针仍在按钮内**才发 `pressed`
## （按下后移出 = 标准取消手势，见 `_gui_input`）。
## 选中态由 MainMenuPanel 在灰层之上放一块同样的“标记层”，所以左移成侧栏后
## 文字与左右横线仍保持原样，而不是被灰层一起压暗；选中时整字变亮金。
extends Control

signal pressed

const ThemeRes = preload("res://view/theme.gd")
## ★ 点击音效（本控件是自绘 Control，不走 fill_button，需要自己挂）。
const SfxRes = preload("res://view/sfx.gd")

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
## ★★ 2026.11.12：按住进度（0~1）与「按下后是否还停在按钮里」。
##   旧实现在**按下那一帧**就 `pressed.emit()` —— 于是页面立刻推走，玩家根本看不到
##   「按下去」这一下。现在改成标准的 **按下 = 压住，松手才发**；
##   指针按下后移出 = 取消（不发）。
var _press: float = 0.0
var _press_tween: Tween = null
var _armed: bool = false


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
	_sync_label_color()
	queue_redraw()

	SfxRes.attach(self)
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	resized.connect(_layout_label)
	_layout_label()


func _layout_label() -> void:
	if _label == null:
		return
	# FULL_RECT 锚点由父节点决定；这里只保证文本在按钮正中。
	_label.position = Vector2(0.0, _press)
	_label.size = size


func _on_hover(on: bool) -> void:
	# ★ 触屏没有悬停：手指按下去会模拟 mouse_entered，但松开不补 mouse_exited，
	#   照旧处理的话横线会**一直亮着**。移动端把「亮不亮」交给按下/松开（见 _gui_input），
	#   这里只保留「离开」的兜底清场。
	if not ThemeRes.hover_enabled():
		if not on:
			_lit(false)
			_armed = false
			_set_press(false)
		return
	if not on:
		# ★★ 按住后移出按钮：取消这次点击（松手不再发 pressed），压住态也收回。
		_armed = false
		_set_press(false)
	_lit(on)


## 点亮 / 熄灭左右横线（悬停在桌面端、按住/松开在移动端）。
func _lit(on: bool) -> void:
	if _hovered == on:
		return
	_hovered = on
	_sync_label_color()
	_animate_dash()


## ★ 字色跟着状态走：静息暖白 → 悬停往亮金偏 35% → 选中整字亮金。
##   只在状态变化时写一次 override（每帧写会触发重新排版）。
func _sync_label_color() -> void:
	if _label == null:
		return
	var c: Color = ThemeRes.text()
	if _selected:
		c = ThemeRes.accent_bright()
	elif _hovered:
		c = ThemeRes.text().lerp(ThemeRes.accent_bright(), 0.35)
	_label.add_theme_color_override("font_color", c)


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_sync_label_color()
	_animate_dash()


## 标记层用：立即显示/隐藏，不播 0.16s 的渐显。
func set_selected_immediate(on: bool) -> void:
	_selected = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	_dash = HOVER_DASH if on else DEFAULT_DASH
	_sync_label_color()
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


## 按下 / 松开：压住进度（0~1）只影响横线与文字的位置，不改布局尺寸。
func _set_press(on: bool) -> void:
	var target: float = 1.0 if on else 0.0
	if is_equal_approx(_press, target):
		return
	if _press_tween != null and _press_tween.is_valid():
		_press_tween.kill()
	_press_tween = null
	if not ThemeRes.animations_enabled():
		_press = target
		_layout_label()
		queue_redraw()
		return
	_press_tween = create_tween()
	_press_tween.tween_method(_apply_press, _press, target, 0.06 if on else 0.12) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _apply_press(v: float) -> void:
	_press = clampf(v, 0.0, 1.0)
	_layout_label()
	queue_redraw()


## ★★ 交互顺序（2026.11.12 改）：
##   按下 = 压住（横线回缩、字下沉 1px）；**松手且指针仍在按钮内**才发 `pressed`。
##   旧实现在按下当帧就发 —— 页面立刻推走，玩家看不到「按下去」这一下，
##   也失去了「按下后反悔、移出去再松手」的标准取消手势。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_armed = true
			_set_press(true)
			if not ThemeRes.hover_enabled():
				_lit(true)
			accept_event()
			return
		var inside: bool = Rect2(Vector2.ZERO, size).has_point(mb.position)
		var fire: bool = _armed and inside
		_armed = false
		_set_press(false)
		if not ThemeRes.hover_enabled():
			_lit(false)
		accept_event()
		if fire:
			pressed.emit()


func _draw() -> void:
	if _label == null:
		return
	var text_w: float = _label.get_minimum_size().x
	var gap: float = 22.0
	var full_len: float = 116.0
	var left_end: float = (size.x - text_w) * 0.5 - gap
	var right_start: float = (size.x + text_w) * 0.5 + gap
	var max_len: float = minf(left_end - 4.0, size.x - right_start - 4.0)
	# ★ 按下时横线回缩 18%：读作「按进去了」，但不至于整条消失。
	var len: float = clampf(full_len * _dash * (1.0 - 0.18 * _press), 0.0, maxf(0.0, max_len))
	var y: float = size.y * 0.5
	var t: float = clampf((_dash - DEFAULT_DASH) / (HOVER_DASH - DEFAULT_DASH), 0.0, 1.0)
	var c: Color = ThemeRes.line().lerp(ThemeRes.accent_bright(), t)
	c.a = lerpf(0.62, 1.0, t)
	var shift: float = 3.0 * _press
	draw_line(Vector2(left_end - len + shift, y), Vector2(left_end + shift, y), c, 2.0, true)
	draw_line(Vector2(right_start - shift, y), Vector2(right_start + len - shift, y),
		c, 2.0, true)
	# ★★ 两端的小竖线：悬停 / 选中时把「两根横线」收成一对括号 `|— 战役 —|`。
	#   高度只有 8px，和 44 号字同高的一半，不会和字形打架。
	if t > 0.02:
		var tick: float = 10.0 * t
		var tx_l: float = left_end - len + shift
		var tx_r: float = right_start + len - shift
		var tc := Color(c.r, c.g, c.b, c.a * 0.9)
		draw_line(Vector2(tx_l, y - tick * 0.5), Vector2(tx_l, y + tick * 0.5), tc, 1.5, true)
		draw_line(Vector2(tx_r, y - tick * 0.5), Vector2(tx_r, y + tick * 0.5), tc, 1.5, true)


func text() -> String:
	return _text


func dash_amount() -> float:
	return _dash


func press_amount() -> float:
	return _press
