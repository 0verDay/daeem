## menu_faction_button.gd —— 战役详情里的阵营选择按钮。
##
## 一块按钮：左侧本阵营色竖条 + 阵营名 + 目标小字；悬停金仍由 fill_button 负责。
extends Button

const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const ConfigRes = preload("res://logic/config.gd")

var _entry: Dictionary = {}
var _font: Font = null
var _strip: ColorRect = null
var _name_label: Label = null
var _goal_label: Label = null


func setup(p_font: Font, entry: Dictionary) -> void:
	_entry = entry
	_font = p_font
	focus_mode = Control.FOCUS_NONE
	text = ""
	if p_font != null:
		add_theme_font_override("font", p_font)
	FillButtonRes.attach_text(self)
	FillButtonRes.set_base_font_color(self, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(self, ThemeRes.bg_bottom())
	add_theme_stylebox_override("normal", MenuThemeRes.block_button())
	add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	add_theme_stylebox_override("focus", MenuThemeRes.block_button())
	add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())

	_strip = ColorRect.new()
	_strip.name = "FactionStrip"
	_strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strip.color = _color_of(entry)
	add_child(_strip)

	_name_label = _label("FactionName", String(entry.get("name", "")), 26, ThemeRes.text())
	add_child(_name_label)
	_goal_label = _label("FactionGoal", String(entry.get("goal", "")), 16, ThemeRes.text_dim())
	add_child(_goal_label)
	resized.connect(_layout_children)
	_layout_children()


func entry() -> Dictionary:
	return _entry


func _color_of(entry: Dictionary) -> Color:
	var raw := String(entry.get("color", "")).strip_edges()
	if raw != "":
		return ConfigRes.parse_color(raw, ThemeRes.accent())
	return ThemeRes.accent()


func _label(node_name: String, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func _layout_children() -> void:
	if _strip == null:
		return
	_strip.position = Vector2.ZERO
	_strip.size = Vector2(6.0, size.y)
	if _name_label != null:
		_name_label.position = Vector2(20.0, 16.0)
		_name_label.size = Vector2(size.x - 36.0, 34.0)
	if _goal_label != null:
		_goal_label.position = Vector2(20.0, 54.0)
		_goal_label.size = Vector2(size.x - 36.0, 28.0)
