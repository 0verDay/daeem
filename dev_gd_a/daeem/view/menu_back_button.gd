## menu_back_button.gd —— 新菜单统一的方形返回按钮（56×56）。
extends Button

const ThemeRes = preload("res://view/theme.gd")
const SfxRes = preload("res://view/sfx.gd")


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
	SfxRes.attach(self)
