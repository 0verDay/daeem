## menu_corner_glow.gd —— 右上角向下/向左铺开的柔和金色泛光。
##
## 不画边框：贴片本身是一张以右上角为圆心的径向渐变，只会露出左下那一块。
## 悬停退出/返回按钮时，整体提亮并稍微放大（以右上角为轴，向左下扩）。
extends Control

const ThemeRes = preload("res://view/theme.gd")

const TEX_SIZE := 256
const BASE_ALPHA := 0.55
const HOVER_ALPHA := 0.95

var _tex: ImageTexture = null
var _hovered: bool = false
var _hot: float = 0.0
var _tween: Tween = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_bake()
	_update_pivot()
	resized.connect(func():
		_update_pivot()
		queue_redraw())


func _bake() -> void:
	if _tex != null:
		return
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
	_tex = ImageTexture.create_from_image(img)


func _update_pivot() -> void:
	pivot_offset = Vector2(size.x, 0.0)


func set_hover(on: bool) -> void:
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
