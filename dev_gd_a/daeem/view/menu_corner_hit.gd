## menu_corner_hit.gd —— 右上角的三角形触发区。
##
## 视觉上仍是 56×56 的 X / 返回箭头，但命中区域是右上角一个直角三角形：
## 以控件左上角为原点，x >= y 的那一半（右角在右上角）。
## 这样鼠标可以在右上角更大范围内触发泛光/退出/返回，而不会点到面板正文。
extends Control

signal pressed

var _hovered: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _has_point(point: Vector2) -> bool:
	# 三角形：上边 + 右边 + 从左上到右下的斜边。
	return point.x >= point.y


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			accept_event()
			pressed.emit()


func is_hovered() -> bool:
	return _hovered
