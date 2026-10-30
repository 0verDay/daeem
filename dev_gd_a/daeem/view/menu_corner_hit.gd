## menu_corner_hit.gd —— 面板一角的三角形触发区。
##
## 视觉上仍是 56×56 的 X / 返回箭头 / 角按钮，但命中区域是贴着那个角的一块
## 直角三角形：以控件方框为界，只有靠近该角的一半算点中（判定在
## LayoutRes.corner_has_point，四角按钮也用同一份）。
## 这样鼠标可以在角落更大范围内触发泛光/退出/返回，而不会点到面板正文。
extends Control

signal pressed
## 按下 / 松开。★ 移动端没有悬停，角泛光改由这两个信号驱动（见 menu_page）。
signal press_started
signal press_ended

const LayoutRes = preload("res://view/menu_deck_layout.gd")
## ★ 点击音效（自绘 Control，不走 fill_button，需要自己挂）。
const SfxRes = preload("res://view/sfx.gd")

## 与 LayoutRes.CORNER_* 一致；默认右上（退出 X / 返回箭头都在右上）。
var corner: int = LayoutRes.CORNER_TOP_RIGHT

var _hovered: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	SfxRes.attach(self)


func _has_point(point: Vector2) -> bool:
	# 三角形：只有靠近这个角的那一半。
	return LayoutRes.corner_has_point(size, corner, point)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			press_started.emit()
			accept_event()
			pressed.emit()
		else:
			press_ended.emit()
			accept_event()


func is_hovered() -> bool:
	return _hovered
