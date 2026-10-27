## menu_close_button.gd —— 程序化绘制的退出 X（占位图标，不用贴图）。
##
## 只在主菜单面板的右上角出现；点击发 `pressed`（Button 原生信号），
## 由 start_screen 转成 quit_requested。侧栏灰层会盖住它，因此侧栏位不可点。
extends Button

const ThemeRes = preload("res://view/theme.gd")


func setup() -> void:
	name = "ExitButton"
	text = ""
	tooltip_text = "退出游戏"
	focus_mode = Control.FOCUS_NONE
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("normal", empty)
	add_theme_stylebox_override("hover", empty)
	add_theme_stylebox_override("pressed", empty)
	add_theme_stylebox_override("focus", empty)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func _draw() -> void:
	var pad: float = minf(size.x, size.y) * 0.28
	var a := Vector2(pad, pad)
	var b := Vector2(size.x - pad, size.y - pad)
	var c: Color = ThemeRes.accent_bright() if is_hovered() else ThemeRes.text()
	var w: float = 2.4
	draw_line(a, b, c, w, true)
	draw_line(Vector2(b.x, a.y), Vector2(a.x, b.y), c, w, true)
