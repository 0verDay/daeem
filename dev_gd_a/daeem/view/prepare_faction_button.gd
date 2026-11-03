## prepare_faction_button.gd —— 备战页右侧的「王朝 / 帝国」竖排按钮。
##
## 版式（用户口径）：贴住屏幕右缘、**右边向左边泛光**、**左边不画框**，
## 文字从上往下排列；选中态是「金色填充（黑块）」，未选中是「透明 + 白色细框（白框）」。
##
## ------------------------------------------------------------------
## 为什么是「空 Button + 自己画」
## ------------------------------------------------------------------
## 它要的不是方框按钮：没有左边框、底色是一条从右往左衰减的横向渐变。
## StyleBoxFlat 只有单色、也没有「只画三条边」的能力，所以这里：
##   · 用 **Button** 拿 hover / 按下 / 点击音效 / 按下缩放（PressFx 只认 Control）；
##   · 把五档 StyleBox 全换成 `StyleBoxEmpty`（引擎什么都不画）；
##   · 在 `_draw()` 里画渐变 + 三条边（上 / 下 / 右）。
## 层次天然正确：父节点（本按钮）先画，竖排文字的 Label 是子节点、后画。
##
## 渐变用一张 256×1 的**白色 alpha 斜坡**贴图，靠 `modulate` 染成金色 / 暖白：
## 一张贴图给选中、未选中、悬停三档共用，不需要每次换态重新烘焙。
extends Button

const ThemeRes = preload("res://view/theme.gd")
const SfxRes = preload("res://view/sfx.gd")
const PressFxRes = preload("res://view/press_fx.gd")

## 渐变贴图的横向采样数（只烘一次，所有按钮共用）。
const RAMP_W := 256
## 右缘那根竖线的宽度。
const EDGE_W := 2.0

## 两张斜坡：填充用的更集中在右缘（pow 1.6），描边用的更平（pow 0.85）——
## 未选中那枚是「白框」，上/下沿要能一直看到中段，不能像填充那样只在右端亮。
static var _fill_ramp: ImageTexture = null
static var _edge_ramp: ImageTexture = null

var _font: Font = null
var _display: String = ""
var _faction_id: String = ""
var _label: Label = null
var _selected: bool = false
var _hovered: bool = false
var _sel_t: float = 0.0
var _hot: float = 0.0
var _glow_alpha: float = 1.0
var _sel_tween: Tween = null
var _hot_tween: Tween = null


func setup(p_font: Font, display: String, faction_id: String,
		font_size: int = 40, line_gap: int = 8) -> void:
	_font = p_font
	_display = display
	_faction_id = faction_id
	name = "Faction_%s" % faction_id
	text = ""
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR

	# 引擎的五档底纹全部清空：底 / 边 / 字都由下面的 `_draw` 与 Label 负责。
	var empty := StyleBoxEmpty.new()
	for slot in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(slot, empty)

	_label = Label.new()
	_label.name = "VerticalText"
	_label.text = _vertical_text(display)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_constant_override("line_spacing", line_gap)
	if _font != null:
		_label.add_theme_font_override("font", _font)
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", ThemeRes.text())
	add_child(_label)

	SfxRes.attach(self)
	PressFxRes.attach(self)
	mouse_entered.connect(_on_hover.bind(true))
	mouse_exited.connect(_on_hover.bind(false))
	button_down.connect(_on_button_down)
	button_up.connect(_on_button_up)
	resized.connect(_layout)
	_layout()


func _layout() -> void:
	if _label == null:
		return
	_label.position = Vector2.ZERO
	_label.size = size


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

## 选中 / 未选中（不播动画的场合由 `instant` 控制）。
func set_selected(on: bool, instant: bool = false) -> void:
	_selected = on
	_kill_tween(_sel_tween)
	_sel_tween = null
	var target := 1.0 if on else 0.0
	if instant or not ThemeRes.animations_enabled():
		_sel_t = target
		queue_redraw()
		return
	_sel_tween = create_tween()
	_sel_tween.tween_method(_set_sel_t, _sel_t, target, 0.16) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func is_selected() -> bool:
	return _selected


func faction_id() -> String:
	return _faction_id


func display_text() -> String:
	return _display


## 页面转场用：整枚按钮的光一起渐显 / 渐隐（0 = 全灭）。
func set_glow_alpha(a: float) -> void:
	_glow_alpha = clampf(a, 0.0, 1.0)
	queue_redraw()


func glow_alpha() -> float:
	return _glow_alpha


func _set_sel_t(v: float) -> void:
	_sel_t = clampf(v, 0.0, 1.0)
	queue_redraw()


# ------------------------------------------------------------------
# 悬停 / 按下
# ------------------------------------------------------------------

func _on_hover(on: bool) -> void:
	# ★ 触屏没有悬停（按下时模拟 enter、松手不补 exit）；和主菜单一样，
	#   移动端把「亮不亮」交给按住 / 松开，这里只保留移出的兜底清场。
	if not ThemeRes.hover_enabled():
		if not on:
			_set_hot(false)
		return
	_set_hot(on)


func _on_button_down() -> void:
	if not ThemeRes.hover_enabled():
		_set_hot(true)


func _on_button_up() -> void:
	if not ThemeRes.hover_enabled():
		_set_hot(false)


func _set_hot(on: bool) -> void:
	if _hovered == on:
		return
	_hovered = on
	_kill_tween(_hot_tween)
	_hot_tween = null
	var target := 1.0 if on else 0.0
	if not ThemeRes.animations_enabled():
		_hot = target
		queue_redraw()
		return
	_hot_tween = create_tween()
	_hot_tween.tween_method(_set_hot_t, _hot, target, 0.18) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _set_hot_t(v: float) -> void:
	_hot = clampf(v, 0.0, 1.0)
	queue_redraw()


func _kill_tween(t: Tween) -> void:
	if t != null and t.is_valid():
		t.kill()


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w <= 1.0 or h <= 1.0:
		return
	var ga: float = clampf(_glow_alpha, 0.0, 1.0)
	if ga <= 0.001:
		return
	var tex := _fill_texture()
	var edge := _edge_texture()
	if tex == null or edge == null:
		return
	var sel: float = clampf(_sel_t, 0.0, 1.0)
	var hot: float = clampf(_hot, 0.0, 1.0)

	# ① 选中态的「黑块」：一整块暗底（左端保持不透明，右端由金盖上去）。
	var base := ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.92 * sel)
	if base.a > 0.001:
		draw_rect(Rect2(Vector2.ZERO, size), base, true)

	# ② 右 → 左的泛光 / 金色填充。未选中是一层很淡的金，选中时压满右半边。
	var fill := ThemeRes.fill_bottom().lerp(ThemeRes.fill_top(), 0.45)
	var fill_a: float = lerpf(0.26, 0.95, sel) * (1.0 + 0.30 * hot) * ga
	draw_texture_rect(tex, Rect2(0.0, 0.0, w, h), false,
		Color(fill.r, fill.g, fill.b, fill_a))

	# ③ 三条边：上 / 下沿「右亮左灭」渐隐，右缘一根竖线；**左边不画**。
	#    未选中是暖白细框（设计稿里的「白框」），选中转成亮金。
	var fc: Color = ThemeRes.text().lerp(ThemeRes.accent_bright(), sel)
	var fa: float = lerpf(0.72, 0.95, sel) * (1.0 + 0.20 * hot) * ga
	var top_bottom := Color(fc.r, fc.g, fc.b, fa)
	draw_texture_rect(edge, Rect2(0.0, 0.0, w, 1.0), false, top_bottom)
	draw_texture_rect(edge, Rect2(0.0, h - 1.0, w, 1.0), false, top_bottom)
	draw_rect(Rect2(w - EDGE_W, 0.0, EDGE_W, h),
		Color(fc.r, fc.g, fc.b, fa * 0.95), true)


## 白色 alpha 斜坡：左端 0 → 右端 1。
## @param power 越大越贴右缘（填充 1.6；描边 0.85 更平、能看见中段）。
static func _ramp(power: float) -> ImageTexture:
	var img := Image.create(RAMP_W, 1, false, Image.FORMAT_RGBA8)
	for x in RAMP_W:
		var t: float = float(x) / float(RAMP_W - 1)
		img.set_pixel(x, 0, Color(1.0, 1.0, 1.0, pow(t, power)))
	return ImageTexture.create_from_image(img)


static func _fill_texture() -> ImageTexture:
	if _fill_ramp == null:
		_fill_ramp = _ramp(1.6)
	return _fill_ramp


static func _edge_texture() -> ImageTexture:
	if _edge_ramp == null:
		_edge_ramp = _ramp(0.85)
	return _edge_ramp


## 竖排：一个字一行（「王朝」→「王\n朝」）。用 Label 的换行而不是 VBox：
## Label 自己会把整段在竖直方向居中，字号 / 行距都只在一处设置。
static func _vertical_text(s: String) -> String:
	var out := ""
	for i in s.length():
		if i > 0:
			out += "\n"
		out += s.substr(i, 1)
	return out
