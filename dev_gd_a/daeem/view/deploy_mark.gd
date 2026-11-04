## deploy_mark.gd —— 备战页「已设为出战」的指示：**嵌在磁贴顶边居中的小倒三角**。
##
## 用户口径：「被设为出战的将领其按钮上方会有一个小的倒三角嵌入按钮中作为指示」。
##   · 画在磁贴**内部**的上沿（不是悬在外面）—— 磁贴归 GridContainer 管，
##     长到外面会压到上一行，也会被列表的裁剪区切掉；
##   · 只是**显示**，不接收输入（`MOUSE_FILTER_IGNORE`），点击仍然落到磁贴上。
##
## 颜色走 `ThemeRes.accent()`（与标题金线、选中填充同一套），
## 底下垫一条更深的同色描边，保证压在深色 / 金色填充上都看得清。
extends Control

const ThemeRes = preload("res://view/theme.gd")

var _on: bool = false


func setup(width: float, height: float) -> void:
	name = "DeployMark"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(width, height)
	size = Vector2(width, height)
	_on = false
	visible = false


func set_on(on: bool) -> void:
	if _on == on:
		return
	_on = on
	visible = on
	queue_redraw()


func is_on() -> bool:
	return _on


func _draw() -> void:
	if not _on:
		return
	var w: float = maxf(1.0, size.x)
	var h: float = maxf(1.0, size.y)
	# 倒三角：上沿满宽、下沿收到中心一点。
	var pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(w, 0.0),
		Vector2(w * 0.5, h),
	])
	# 先画深色底（比磁贴底色更深一档），再压金色 —— 纯金压在金色填充上会糊。
	var dark := ThemeRes.bg_bottom()
	draw_colored_polygon(pts, Color(dark.r, dark.g, dark.b, 0.9))
	var gold: Color = ThemeRes.accent()
	var inner := PackedVector2Array([
		Vector2(w * 0.10, h * 0.12),
		Vector2(w * 0.90, h * 0.12),
		Vector2(w * 0.5, h * 0.86),
	])
	draw_colored_polygon(inner, gold)
