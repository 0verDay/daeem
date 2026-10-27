## menu_banner.gd —— 参考图里的「组合形状旗帜」按钮。
##
## 形状：竖旗杆 + 顶部横杆 + 垂下来的旗面（纯 _draw，无贴图）。
## 三种状态：
##   · player —— 玩家旗帜（暖金旗面）
##   · empty  —— 虚位以待（虚线边 + 中央 +）
##   · level  —— 战役关卡旗帜（暗底金线 + 关卡名）
##
## 旗帜自身 STOP 鼠标；点击发 `pressed`。侧栏灰层会在父面板上盖住它。
extends Control

signal pressed

const ThemeRes = preload("res://view/theme.gd")

var _kind: String = "level"
var _title: String = ""
var _subtitle: String = ""
var _hovered: bool = false
var _selected: bool = false
var _clickable: bool = true
var _font: Font = null
var _title_label: Label = null
var _sub_label: Label = null


func setup(p_font: Font, kind: String, title: String, subtitle: String = "") -> void:
	_font = p_font
	_kind = kind
	_title = title
	_subtitle = subtitle
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_title_label = _make_label("Title", 30, ThemeRes.text())
	_sub_label = _make_label("Sub", 17, ThemeRes.text_dim())
	if kind == "level":
		_title_label.add_theme_font_size_override("font_size", 15)
		_sub_label.add_theme_font_size_override("font_size", 12)
	elif kind == "empty":
		_title_label.add_theme_font_size_override("font_size", 28)
	add_child(_title_label)
	add_child(_sub_label)
	mouse_entered.connect(func(): _hovered = true; queue_redraw())
	mouse_exited.connect(func(): _hovered = false; queue_redraw())
	resized.connect(_layout_labels)
	_layout_labels()
	queue_redraw()


func _make_label(node_name: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func set_title(text: String) -> void:
	_title = text
	_refresh_labels()


func set_subtitle(text: String) -> void:
	_subtitle = text
	_refresh_labels()


## 不重建节点地切换状态（用于虚位旗 → AI 队友）。
func set_state(kind: String, title: String, subtitle: String = "") -> void:
	_kind = kind
	_title = title
	_subtitle = subtitle
	var ts := 30
	var ss := 17
	if kind == "level":
		ts = 15
		ss = 12
	elif kind == "empty":
		ts = 28
	_title_label.add_theme_font_size_override("font_size", ts)
	_sub_label.add_theme_font_size_override("font_size", ss)
	_refresh_labels()
	queue_redraw()


func title_text() -> String:
	return _title


func subtitle_text() -> String:
	return _subtitle


func set_selected(on: bool) -> void:
	_selected = on
	queue_redraw()


## 关掉点击仍然吃鼠标：避免点到 AI 旗时穿透到父面板的空白区域。
func set_clickable(on: bool) -> void:
	_clickable = on
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if on else Control.CURSOR_ARROW


func is_selected() -> bool:
	return _selected


func kind() -> String:
	return _kind


func _cloth_rect() -> Rect2:
	if _kind == "level":
		var pole_x: float = size.x * 0.32
		var top: float = 16.0
		var w: float = size.x * 0.64
		var h: float = size.y * 0.76
		return Rect2(pole_x - 2.0, top, w, h)
	# 合作旗帜：没有竖杆，布面居中，由顶部一根实心横线承托。
	var cw: float = size.x * 0.72
	return Rect2((size.x - cw) * 0.5, 18.0, cw, size.y * 0.74)


func _layout_labels() -> void:
	if _title_label == null:
		return
	var c := _cloth_rect()
	var pad: float = 12.0
	_title_label.position = c.position + Vector2(pad, c.size.y * 0.34)
	_title_label.size = Vector2(c.size.x - pad * 2.0, 52.0)
	_sub_label.position = c.position + Vector2(pad, c.size.y * 0.34 + 52.0)
	_sub_label.size = Vector2(c.size.x - pad * 2.0, 30.0)
	_refresh_labels()


func _refresh_labels() -> void:
	if _title_label == null:
		return
	if _kind == "empty":
		_title_label.text = _title if _title != "" else "虚位以待"
		_sub_label.text = _subtitle if _subtitle != "" else "点击加入 AI 队友"
		_title_label.add_theme_color_override("font_color", ThemeRes.text_dim())
		_sub_label.add_theme_color_override("font_color", ThemeRes.text_faint())
	elif _kind == "player":
		_title_label.text = _title if _title != "" else "你"
		_sub_label.text = _subtitle
		_title_label.add_theme_color_override("font_color", ThemeRes.text())
		_sub_label.add_theme_color_override("font_color", ThemeRes.accent_bright())
	else:
		_title_label.text = _title
		_sub_label.text = _subtitle
		_title_label.add_theme_color_override("font_color", ThemeRes.text())
		_sub_label.add_theme_color_override("font_color", ThemeRes.text_dim())


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			accept_event()
			if _clickable:
				pressed.emit()


## 命中区只覆盖旗面 + 旗杆 + 顶部横杆，不再把整块 170×210 的透明边距都算成按钮。
func _has_point(point: Vector2) -> bool:
	if size.x <= 2.0 or size.y <= 2.0:
		return false
	if _cloth_rect().grow(6.0).has_point(point):
		return true
	var pole_x: float = size.x * 0.32
	if _kind == "level":
		if Rect2(pole_x - 9.0, 0.0, 18.0, size.y).has_point(point):
			return true
		return Rect2(pole_x, 0.0, size.x * 0.62, 12.0).has_point(point)
	var c := _cloth_rect()
	return Rect2(c.position.x, maxf(0.0, c.position.y - 8.0), c.size.x, 10.0).has_point(point)


func _draw() -> void:
	if size.x <= 2.0 or size.y <= 2.0:
		return
	var pole_x: float = size.x * 0.32
	var pole_w: float = 8.0
	var bar_h: float = 10.0
	var cloth := _cloth_rect()
	var gold: Color = ThemeRes.accent_bright() if (_hovered or _selected) else ThemeRes.line()
	var line_w: float = 2.0 if _selected else 1.4

	# 战役旗：竖杆 + 顶部横杆；合作旗：只有贴着布面上沿的实心横线。
	if _kind == "level":
		draw_rect(Rect2(pole_x - pole_w * 0.5, 0.0, pole_w, size.y), gold, true)
		draw_rect(Rect2(pole_x, 0.0, size.x * 0.62, bar_h), gold, true)
	else:
		draw_rect(Rect2(cloth.position.x, maxf(0.0, cloth.position.y - 6.0),
			cloth.size.x, 6.0), gold, true)

	# 旗面
	if _kind == "empty":
		_draw_dashed_rect(cloth, gold, line_w)
		var plus := Vector2(cloth.get_center().x, cloth.position.y + cloth.size.y * 0.16)
		var arm: float = 24.0
		draw_line(plus - Vector2(arm, 0.0), plus + Vector2(arm, 0.0), gold, 2.0, true)
		draw_line(plus - Vector2(0.0, arm), plus + Vector2(0.0, arm), gold, 2.0, true)
	else:
		var fill: Color
		if _kind == "player":
			fill = ThemeRes.with_alpha(ThemeRes.accent(), 0.20)
		else:
			fill = ThemeRes.with_alpha(ThemeRes.bg_top(), 0.86)
		if _hovered:
			fill = ThemeRes.with_alpha(ThemeRes.accent_bright(), fill.a + 0.08)
		draw_rect(cloth, fill, true)
		draw_rect(cloth, gold, false, line_w)
		if _selected:
			draw_rect(cloth.grow(4.0), ThemeRes.accent_bright(), false, 2.0)


func _draw_dashed_rect(r: Rect2, c: Color, w: float) -> void:
	var dash: float = 14.0
	var gap: float = 10.0
	var step: float = dash + gap
	var x := r.position.x
	while x < r.end.x:
		var x2: float = minf(x + dash, r.end.x)
		draw_line(Vector2(x, r.position.y), Vector2(x2, r.position.y), c, w, true)
		draw_line(Vector2(x, r.end.y), Vector2(x2, r.end.y), c, w, true)
		x += step
	var y := r.position.y
	while y < r.end.y:
		var y2: float = minf(y + dash, r.end.y)
		draw_line(Vector2(r.position.x, y), Vector2(r.position.x, y2), c, w, true)
		draw_line(Vector2(r.end.x, y), Vector2(r.end.x, y2), c, w, true)
		y += step
