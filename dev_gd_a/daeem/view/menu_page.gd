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

## 泛光渐显/渐隐的默认时长（可被 config 的 `menu.deck.glow_fade_sec` 覆盖）。
const GLOW_FADE_SEC := 0.26

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
var _glow_alpha: float = 1.0
var _glow_tween: Tween = null


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
	# ★ 桌面：悬停点亮角泛光。移动端：没有悬停（按下时的模拟 enter 不再有 exit，
	#   泛光会一直亮着），改成按住才亮；另外留一条 mouse_exited 兜底清场。
	if ThemeRes.hover_enabled():
		_corner_hit.mouse_entered.connect(func(): _corner_glow.set_hover(true))
		_corner_hit.mouse_exited.connect(func(): _corner_glow.set_hover(false))
	else:
		_corner_hit.press_started.connect(func(): _corner_glow.set_lit(true))
		_corner_hit.press_ended.connect(func(): _corner_glow.set_lit(false))
		_corner_hit.mouse_exited.connect(func(): _corner_glow.set_lit(false))
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
			# ★ 强制熄灭走 set_lit：移动端没有悬停，set_hover 是空操作，熄不掉。
			_corner_glow.set_lit(false)
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
# 泛光渐显 / 渐隐
# ------------------------------------------------------------------
#
# 每块面板都自带泛光：右上角那团角光（子类还会加四角）、以及带标题的页面
# 顶部那团半圆光。转场时「聚焦的那一页渐显、其余页渐隐」就靠这一组接口：
#   deck 只认 `set_glows(on, animate)` / `glow_alpha()`，
#   具体每个控件怎么变暗由各自的 `set_glow_alpha(a)` 决定
#   （角光是整块 modulate，顶部半圆光只压纹理 alpha，标题文字不动）。

## 本页所有泛光控件。子类可以追加自己的（主菜单的四角就走这条路）。
func glow_nodes() -> Array:
	var out: Array = []
	if _corner_glow != null:
		out.append(_corner_glow)
	if _glow != null:
		out.append(_glow)
	return out


## 整组泛光的当前透明度（0=全灭，1=常态）。
func glow_alpha() -> float:
	return _glow_alpha


## 立即把整组泛光设到 a。不做补间：`tween_method` 与「动效关闭」都走这里。
func apply_glow_alpha(a: float) -> void:
	_glow_alpha = clampf(a, 0.0, 1.0)
	for n in glow_nodes():
		if n != null and is_instance_valid(n):
			n.set_glow_alpha(_glow_alpha)


## 整组泛光渐显/渐隐到 to。animate=false（或动效关闭）时瞬间到位。
func fade_glows(to: float, animate: bool = true, sec: float = -1.0) -> void:
	to = clampf(to, 0.0, 1.0)
	if _glow_tween != null and _glow_tween.is_valid():
		_glow_tween.kill()
	_glow_tween = null
	var dur: float = glow_fade_sec() if sec <= 0.0 else sec
	if not animate or not ThemeRes.animations_enabled() or dur <= 0.0 \
			or is_equal_approx(to, _glow_alpha) or not is_inside_tree():
		apply_glow_alpha(to)
		return
	_glow_tween = create_tween()
	_glow_tween.tween_method(apply_glow_alpha, _glow_alpha, to, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 亮起 / 熄灭整组泛光。
func set_glows(on: bool, animate: bool = true) -> void:
	fade_glows(1.0 if on else 0.0, animate)


func glow_fade_sec() -> float:
	if cfg != null:
		return maxf(0.0, cfg.num("menu.deck.glow_fade_sec", GLOW_FADE_SEC))
	return GLOW_FADE_SEC


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
