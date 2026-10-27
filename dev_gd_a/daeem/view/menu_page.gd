## menu_page.gd —— 新菜单所有整块面板的公共底座。
##
## 提供：底板 / 顶部泛光 / 右上返回 / 左侧灰层（SidebarDim）/ 常用控件工厂。
## 面板本身不负责导航，返回只发 `back_pressed`；谁接、退到哪由 MenuDeck 决定。
extends Control

signal back_pressed

const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const LayoutRes = preload("res://view/menu_deck_layout.gd")
const GlowRes = preload("res://view/menu_glow_header.gd")
const BackRes = preload("res://view/menu_back_button.gd")
const CornerGlowRes = preload("res://view/menu_corner_glow.gd")
const CornerHitRes = preload("res://view/menu_corner_hit.gd")
const FillButtonRes = preload("res://view/fill_button.gd")

var cfg = null
var font: Font = null

var _bg: Panel = null
var _corner_glow: Control = null
var _corner_hit: Control = null
var _glow: Control = null
var _back: Button = null
var _dim: ColorRect = null
var _dim_tween: Tween = null
var _dimmed: bool = false


## 在 add_child + 设置 size 之后调用。
func setup_page(p_cfg, p_font: Font, title: String = "", with_back: bool = true) -> void:
	cfg = p_cfg
	font = p_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_TOP_LEFT)

	_bg = Panel.new()
	_bg.name = "Bg"
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.add_theme_stylebox_override("panel", MenuThemeRes.deck_panel())
	add_child(_bg)

	_corner_glow = CornerGlowRes.new()
	_corner_glow.name = "CornerGlow"
	_corner_glow.z_index = 4
	_corner_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_corner_glow)

	if title != "":
		_glow = GlowRes.new()
		_glow.name = "GlowHeader"
		_glow.z_index = 10
		add_child(_glow)
		_glow.setup(font, title)

	if with_back:
		_back = BackRes.new()
		_back.z_index = 20
		add_child(_back)
		_back.setup(font)
		_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_back.pressed.connect(func(): back_pressed.emit())

	_corner_hit = CornerHitRes.new()
	_corner_hit.name = "CornerHit"
	_corner_hit.z_index = 30
	add_child(_corner_hit)
	_corner_hit.mouse_entered.connect(func(): _corner_glow.set_hover(true))
	_corner_hit.mouse_exited.connect(func(): _corner_glow.set_hover(false))
	if with_back:
		_corner_hit.pressed.connect(func(): back_pressed.emit())

	_dim = ColorRect.new()
	_dim.name = "SidebarDim"
	_dim.color = MenuThemeRes.sidebar_dim_color()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.z_index = 100
	_dim.visible = false
	_dim.modulate.a = 0.0
	add_child(_dim)

	resized.connect(_place_chrome)
	_place_chrome()


func _place_chrome() -> void:
	if _glow != null:
		_glow.position = LayoutRes.glow_rect(size.x).position
		_glow.size = LayoutRes.glow_rect(size.x).size
	if _back != null:
		_back.position = LayoutRes.back_rect(size.x).position
		_back.size = LayoutRes.back_rect(size.x).size
	if _corner_glow != null:
		_corner_glow.position = LayoutRes.corner_glow_rect(size.x).position
		_corner_glow.size = LayoutRes.corner_glow_rect(size.x).size
	if _corner_hit != null:
		_corner_hit.position = LayoutRes.corner_hit_rect(size.x).position
		_corner_hit.size = LayoutRes.corner_hit_rect(size.x).size
	# _dim 是 FULL_RECT 锚点，尺寸由父节点给，不要再写 size（会触发 anchor 警告）。


# ------------------------------------------------------------------
# 侧栏灰层
# ------------------------------------------------------------------

## 左移成侧栏时调用；on=true 显示灰层并清掉悬停/满格。
func set_sidebar_dimmed(on: bool, animate: bool = true) -> void:
	_dimmed = on
	if _dim == null:
		return
	if _dim_tween != null and _dim_tween.is_valid():
		_dim_tween.kill()
	_dim_tween = null
	if on:
		# ★ 只把 z_index 调高不够：GUI 命中测试按子节点顺序走，内容是在灰层之后
		#   才被子树加进来的；因此灰层要移到最后一个子节点，否则按钮仍能点到。
		_dim.move_to_front()
		if _corner_glow != null:
			_corner_glow.set_hover(false)
		FillButtonRes.clear_hover_in(self)
		FillButtonRes.clear_latched_in(self)
	if not ThemeRes.animations_enabled() or not animate:
		_dim.visible = on
		_dim.modulate.a = 1.0 if on else 0.0
		return
	if on:
		_dim.visible = true
		_dim_tween = create_tween()
		_dim_tween.tween_property(_dim, "modulate:a", 1.0, 0.2)
	else:
		_dim_tween = create_tween()
		_dim_tween.tween_property(_dim, "modulate:a", 0.0, 0.2)
		_dim_tween.tween_callback(func(): _dim.visible = false)


func is_sidebar_dimmed() -> bool:
	return _dimmed


func sidebar_dim() -> ColorRect:
	return _dim


func corner_glow() -> Control:
	return _corner_glow


func corner_hit() -> Control:
	return _corner_hit


func glow_header() -> Control:
	return _glow


func back_button() -> Button:
	return _back


func background() -> Panel:
	return _bg


# ------------------------------------------------------------------
# 零件
# ------------------------------------------------------------------

func make_label(node_name: String, text: String, fs: int, color: Color,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	return l


func make_panel(node_name: String, style: StyleBox = null) -> Panel:
	var p := Panel.new()
	p.name = node_name
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", style if style != null else MenuThemeRes.deck_block())
	return p


func make_block_button(node_name: String, text: String, fs: int,
		style: StyleBox = null) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if font != null:
		b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", fs)
	FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_bottom())
	var normal: StyleBox = style if style != null else MenuThemeRes.block_button()
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	b.add_theme_stylebox_override("focus", normal)
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	return b


func make_text_button(node_name: String, text: String, fs: int) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if font != null:
		b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", fs)
	FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_bottom())
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	return b
