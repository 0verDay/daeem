## menu_back_button.gd —— 新菜单统一的方形返回按钮（56×56）。
##
## ★ 2026.11.12：与四角图标按钮同一套「瞄准框」悬停 —— 悬停时图标外补四角括号，
##   按住时括号内扣。`‹` 本身仍按原来的字色变化（暖白 → 亮金 → 压暗）。
extends Button

const ThemeRes = preload("res://view/theme.gd")
const ReticleRes = preload("res://view/button_reticle.gd")

var _reticle = null


func setup(p_font: Font) -> void:
	name = "BackButton"
	text = "‹"
	tooltip_text = "返回"
	focus_mode = Control.FOCUS_NONE
	if p_font != null:
		add_theme_font_override("font", p_font)
	add_theme_font_size_override("font_size", 38)
	var empty := StyleBoxEmpty.new()
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(state, empty)
	add_theme_color_override("font_color", ThemeRes.text())
	add_theme_color_override("font_hover_color", ThemeRes.accent_bright())
	add_theme_color_override("font_pressed_color", ThemeRes.accent())
	add_theme_color_override("font_focus_color", ThemeRes.text())
	# 瞄准框：返回键没有底纹，括号画在 56×56 的内侧四角。
	_reticle = ReticleRes.new()
	add_child(_reticle)
	_reticle.setup(self)
	set_process(true)


func _process(_dt: float) -> void:
	if _reticle == null or not is_instance_valid(_reticle):
		return
	_reticle.sync(1.0 if is_hovered() else 0.0, 1.0 if is_pressed() else 0.0,
		-1.0, 0.0, disabled, true)
