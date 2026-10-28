## menu_corner_glow.gd —— 面板四角向内部铺开的柔和金色泛光。
##
## 不画边框：贴片本身是一张以某个角为圆心的径向渐变，只会露出面板内侧那一块。
## 悬停对应按钮时，整体提亮（以该角为轴，向面板内部铺开）。
##
## ★ 默认仍是右上角（退出 X / 返回箭头）。载入 / 好友 / 设置三颗角按钮用
##   `corner` 选自己的角；四张贴片只在第一次用到时生成一次（`_tex_cache`），
##   后三张是把右上那张按 x / y 镜像出来的，不再跑 256×256 的逐像素循环。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const LayoutRes = preload("res://view/menu_deck_layout.gd")

const TEX_SIZE := 256
const BASE_ALPHA := 0.55
const HOVER_ALPHA := 0.95

## 与 LayoutRes.CORNER_* 一一对应。用 set_corner() 改：直接写这个字段不会重烘贴片。
var corner: int = LayoutRes.CORNER_TOP_RIGHT

var _tex: ImageTexture = null
var _hovered: bool = false
var _hot: float = 0.0
var _tween: Tween = null

## 角 → 贴片。四个角共用一份，之后每次 new 都不必重新烘焙。
static var _tex_cache: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_bake()
	_update_pivot()
	resized.connect(func():
		_update_pivot()
		queue_redraw())


## 换成别的角（在 add_child 之前调用最省事）。
func set_corner(c: int) -> void:
	if corner == c:
		return
	corner = c
	_tex = null
	if is_inside_tree():
		_bake()
		_update_pivot()
		queue_redraw()


## 泛光整体透明度（0=全灭，1=常态）。页面转场的渐显/渐隐由 menu_page 统一驱动。
func set_glow_alpha(a: float) -> void:
	modulate.a = clampf(a, 0.0, 1.0)


func glow_alpha() -> float:
	return modulate.a


## 右上角那张母图：上边 + 右边发光，以右上角为中心。
static func _corner_source_texture() -> ImageTexture:
	if _tex_cache.has(LayoutRes.CORNER_TOP_RIGHT):
		return _tex_cache[LayoutRes.CORNER_TOP_RIGHT]
	var img := Image.create(TEX_SIZE, TEX_SIZE, false, Image.FORMAT_RGBA8)
	for y in TEX_SIZE:
		for x in TEX_SIZE:
			# 只让“上边 + 右边”发光：离边越远越暗，沿边向远端渐隐。
			var dx := 1.0 - float(x) / float(TEX_SIZE)   # 离右边缘
			var dy := float(y) / float(TEX_SIZE)          # 离上边缘
			var top := exp(-dy * 13.0) * smoothstep(0.0, 0.65, 1.0 - dx)
			var right := exp(-dx * 13.0) * smoothstep(0.0, 0.65, 1.0 - dy)
			var a := clampf(top + right - top * right, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[LayoutRes.CORNER_TOP_RIGHT] = tex
	return tex


## 某个角的贴片：右上为母图，其余三张镜像（Image 的翻转是 C++ 侧，很快）。
static func _texture_for(c: int) -> ImageTexture:
	if _tex_cache.has(c):
		return _tex_cache[c]
	var img: Image = (_corner_source_texture().get_image() as Image).duplicate()
	match c:
		LayoutRes.CORNER_TOP_LEFT:
			img.flip_x()
		LayoutRes.CORNER_BOTTOM_RIGHT:
			img.flip_y()
		LayoutRes.CORNER_BOTTOM_LEFT:
			img.flip_x()
			img.flip_y()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[c] = tex
	return tex


func _bake() -> void:
	if _tex != null:
		return
	_tex = _texture_for(corner)


func _update_pivot() -> void:
	match corner:
		LayoutRes.CORNER_TOP_LEFT:
			pivot_offset = Vector2(0.0, 0.0)
		LayoutRes.CORNER_BOTTOM_LEFT:
			pivot_offset = Vector2(0.0, size.y)
		LayoutRes.CORNER_BOTTOM_RIGHT:
			pivot_offset = Vector2(size.x, size.y)
		_:
			pivot_offset = Vector2(size.x, 0.0)


## 鼠标悬停（桌面）。★ 移动端没有悬停，这里**直接忽略** —— 触屏按下时会模拟一次
## mouse_entered 却永远等不到 mouse_exited，泛光会一直亮着（以前靠侧栏灰层强行熄灯兜）。
## 移动端改由 `set_lit()` 跟着按下 / 松开来驱动，见 main_menu_panel / menu_page 的接线。
func set_hover(on: bool) -> void:
	if not ThemeRes.hover_enabled():
		return
	_light(on)


## 直接点亮 / 熄灭（移动端的「按下」「松开」走这里）。
func set_lit(on: bool) -> void:
	_light(on)


func _light(on: bool) -> void:
	if _hovered == on:
		return
	_hovered = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if not on:
		# 离开时直接回到初始强度，避免“悬停后移开比初始更亮”。
		_hot = 0.0
		queue_redraw()
		return
	if not ThemeRes.animations_enabled():
		_hot = 1.0
		queue_redraw()
		return
	_tween = create_tween()
	_tween.tween_method(_set_hot, _hot, 1.0, 0.20) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _set_hot(v: float) -> void:
	_hot = clampf(v, 0.0, 1.0)
	queue_redraw()


func _draw() -> void:
	if _tex == null:
		_bake()
	if _tex == null or size.x <= 2.0 or size.y <= 2.0:
		return
	var c := ThemeRes.accent_bright()
	c.a = lerpf(BASE_ALPHA, HOVER_ALPHA, _hot)
	draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, c)


func is_hovered() -> bool:
	return _hovered


func hot() -> float:
	return _hot
