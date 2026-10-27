## main_menu_panel.gd —— 主菜单右侧面板（640×1080）。
##
## 结构：退出 X / 方形 logo + 名称条 / 战役·合作·演义 / 底部自定义·备战。
## 入场时这块面板渐显，入场页的徽记与标题由 start_screen 缓动到 logo_rect / name_rect。
extends "res://view/menu_page.gd"

signal campaign_pressed
signal coop_pressed
signal quit_pressed

const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
const CloseRes = preload("res://view/menu_close_button.gd")
const TextButtonRes = preload("res://view/menu_text_button.gd")

const DEFAULT_MAIN_BUTTONS := ["战役", "合作", "演义"]
const DEFAULT_BOTTOM_BUTTONS := ["自定义", "备战"]

var _content: Control = null
var _exit: Button = null
var _logo_frame: Panel = null
var _emblem = null
var _name_bar: Panel = null
var _wordmark = null
var _main_buttons: Array = []
var _bottom_bar: Control = null
var _bottom_buttons: Array = []
var _divider: ColorRect = null
var _active_index: int = -1
var _active_marker: Control = null


func setup(p_cfg, p_font: Font) -> void:
	name = "MainPanel"
	setup_page(p_cfg, p_font, "", false)

	_content = Control.new()
	_content.name = "Content"
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.z_index = 5
	add_child(_content)

	_exit = CloseRes.new()
	_exit.z_index = 2
	_content.add_child(_exit)
	_exit.setup()
	_exit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_exit.pressed.connect(func(): quit_pressed.emit())
	corner_hit().pressed.connect(func(): quit_pressed.emit())

	_logo_frame = Panel.new()
	_logo_frame.name = "LogoFrame"
	_logo_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_frame.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_content.add_child(_logo_frame)

	_emblem = MenuEmblemRes.new()
	_emblem.name = "Emblem"
	_emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_logo_frame.add_child(_emblem)

	_name_bar = Panel.new()
	_name_bar.name = "NameBar"
	_name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_bar.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_content.add_child(_name_bar)

	_wordmark = TextMarksRes.SpacedLabel.new()
	_wordmark.name = "Wordmark"
	_wordmark.text = String(cfg.str_val("menu.title", "DAEEM"))
	_wordmark.font = font
	_wordmark.font_size = int(cfg.num("menu.deck.main.name_size", 36.0))
	_wordmark.tracking = cfg.num("menu.deck.main.name_tracking", 8.0)
	_wordmark.color_from = ThemeRes.text()
	_wordmark.color_to = ThemeRes.accent_bright()
	_wordmark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_bar.add_child(_wordmark)

	var labels := _string_list("menu.deck.main.buttons", DEFAULT_MAIN_BUTTONS)
	for i in labels.size():
		var b := TextButtonRes.new()
		b.name = "MainBtn%d" % i
		b.setup(font, String(labels[i]), 44)
		b.pressed.connect(_on_main_pressed.bind(i))
		_content.add_child(b)
		_main_buttons.append(b)

	_bottom_bar = Control.new()
	_bottom_bar.name = "BottomBar"
	_bottom_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(_bottom_bar)

	var bottoms := _string_list("menu.deck.main.bottom_buttons", DEFAULT_BOTTOM_BUTTONS)
	for i in bottoms.size():
		var b := make_block_button("BottomBtn%d" % i, String(bottoms[i]), 30,
			MenuThemeRes.bottom_button())
		b.pressed.connect(func(): pass)
		_bottom_bar.add_child(b)
		_bottom_buttons.append(b)

	_divider = ColorRect.new()
	_divider.name = "BottomDivider"
	_divider.color = ThemeRes.with_alpha(ThemeRes.line(), 0.85)
	_divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bottom_bar.add_child(_divider)

	resized.connect(_layout)
	_layout()


func _on_main_pressed(index: int) -> void:
	match index:
		0:
			campaign_pressed.emit()
		1:
			coop_pressed.emit()
		_:
			pass


func _layout() -> void:
	if _content == null:
		return
	var w: float = size.x
	var h: float = size.y
	var er := LayoutRes.main_exit(w)
	_exit.position = er.position
	_exit.size = er.size

	var lr := LayoutRes.main_logo(w)
	_logo_frame.position = lr.position
	_logo_frame.size = lr.size
	_emblem.position = Vector2(8.0, 8.0)
	_emblem.size = lr.size - Vector2(16.0, 16.0)

	var nr := LayoutRes.main_name(w)
	_name_bar.position = nr.position
	_name_bar.size = nr.size
	_wordmark.position = Vector2.ZERO
	_wordmark.size = nr.size

	for i in _main_buttons.size():
		var r := LayoutRes.main_button(w, i)
		_main_buttons[i].position = r.position
		_main_buttons[i].size = r.size

	var br := LayoutRes.main_bottom(w, h)
	_bottom_bar.position = br.position
	_bottom_bar.size = br.size
	for i in _bottom_buttons.size():
		var r := LayoutRes.main_bottom_half(w, h, i)
		var b: Button = _bottom_buttons[i]
		b.position = Vector2(r.position.x, 0.0)
		b.size = Vector2(r.size.x, br.size.y)
	_divider.position = Vector2(w * 0.5 - 0.5, 0.0)
	_divider.size = Vector2(1.0, br.size.y)
	_layout_active_marker()


## 当前左侧大类：0=战役，1=合作，-1=无。选中态是在灰层之上放一块
## 透明的“文字 + 左右横线”标记层；没有方框，也不会被灰层压暗。
func set_active(index: int) -> void:
	if index == _active_index:
		if index < 0 or (_active_marker != null and is_instance_valid(_active_marker)):
			return
	_active_index = index
	if _active_marker != null and is_instance_valid(_active_marker):
		_active_marker.visible = false
		_active_marker.queue_free()
	_active_marker = null
	if index < 0 or index >= _main_buttons.size():
		return
	var b = _main_buttons[index]
	_active_marker = TextButtonRes.new()
	_active_marker.name = "ActiveMarker"
	_active_marker.z_index = 101
	_active_marker.setup(font, String(b.text()), 44)
	_active_marker.set_passive()
	_active_marker.set_selected_immediate(true)
	add_child(_active_marker)
	_layout_active_marker()


func _layout_active_marker() -> void:
	if _active_marker == null or not is_instance_valid(_active_marker):
		return
	if _active_index < 0 or _active_index >= _main_buttons.size():
		return
	var b: Control = _main_buttons[_active_index]
	_active_marker.position = b.position
	_active_marker.size = b.size


func active_index() -> int:
	return _active_index


func active_marker() -> Control:
	return _active_marker


func set_content_alpha(a: float) -> void:
	if _content != null:
		_content.modulate.a = clampf(a, 0.0, 1.0)


func content_alpha() -> float:
	return _content.modulate.a if _content != null else 1.0


func logo_rect() -> Rect2:
	return _logo_frame.get_global_rect() if _logo_frame != null else Rect2()


func name_rect() -> Rect2:
	return _name_bar.get_global_rect() if _name_bar != null else Rect2()


func wordmark():
	return _wordmark


func exit_button() -> Button:
	return _exit


func main_buttons() -> Array:
	return _main_buttons


func bottom_buttons() -> Array:
	return _bottom_buttons


func content() -> Control:
	return _content


func _string_list(path: String, fallback: Array) -> Array:
	var v: Variant = cfg.get_path_value(path) if cfg != null else null
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for item in (v as Array):
			var s := String(item).strip_edges()
			if s != "":
				out.append(s)
	return out if not out.is_empty() else fallback
