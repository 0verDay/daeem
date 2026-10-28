## menu_glow_header.gd —— 新菜单顶部的「半圆形泛光 + 标题」。
##
## 参考图里每块大面板顶部都有一团半圆光，标题压在光心。这里用一张
## 256×128 的程序化纹理（中心在上边缘、二次衰减）拉伸绘制，不引入图片资源。
extends Control

const ThemeRes = preload("res://view/theme.gd")

const TEX_W := 256
const TEX_H := 128

var _tex: ImageTexture = null
var _title: Label = null
## 只有那团半圆光受它控制；标题文字不跟着变淡（转场时文字不该闪）。
var _alpha: float = 1.0


func setup(p_font: Font, text: String, title_size: int = 44) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_texture()

	_title = Label.new()
	_title.name = "GlowTitle"
	_title.text = text
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if p_font != null:
		_title.add_theme_font_override("font", p_font)
	_title.add_theme_font_size_override("font_size", title_size)
	_title.add_theme_color_override("font_color", ThemeRes.text())
	add_child(_title)
	resized.connect(_layout)
	_layout()


func set_title(text: String) -> void:
	if _title != null:
		_title.text = text


func title_label() -> Label:
	return _title


## 半圆光的透明度（0=全灭，1=常态）。标题文字保持原样。
func set_glow_alpha(a: float) -> void:
	a = clampf(a, 0.0, 1.0)
	if is_equal_approx(a, _alpha):
		return
	_alpha = a
	queue_redraw()


func glow_alpha() -> float:
	return _alpha


func _build_texture() -> void:
	var img := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	var base := ThemeRes.accent_bright()
	var cx := float(TEX_W) * 0.5
	for y in TEX_H:
		var dy: float = float(y) / float(TEX_H)
		for x in TEX_W:
			var dx: float = (float(x) + 0.5 - cx) / cx
			var r: float = sqrt(dx * dx + dy * dy)
			var t: float = clampf(1.0 - r, 0.0, 1.0)
			var a: float = t * t * 0.34
			img.set_pixel(x, y, ThemeRes.with_alpha(base, a))
	_tex = ImageTexture.create_from_image(img)


func _layout() -> void:
	if _title == null:
		return
	_title.position = Vector2(0.0, 38.0)
	_title.size = Vector2(size.x, 64.0)


func _draw() -> void:
	if _tex == null or size.x <= 1.0 or size.y <= 1.0:
		return
	draw_texture_rect(_tex, Rect2(Vector2.ZERO, size), false, Color(1.0, 1.0, 1.0, _alpha))
