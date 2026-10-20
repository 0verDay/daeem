## coop_map_card.gd —— 合作地图列表里的一张卡片（缩略图 + 地图名 + 一行简介）。
extends Button

const UiStyleRes = preload("res://view/ui_style.gd")
const MapThumbRes = preload("res://view/map_thumb.gd")
const CoopLayoutRes = preload("res://view/coop_layout.gd")

var _thumb = null
var _name_label: Label = null
var _desc_label: Label = null
var _selected: bool = false
var _entry: Dictionary = {}
var _font: Font = null


func setup(cfg, entry: Dictionary, map_data, font: Font) -> void:
	_entry = entry
	_font = font
	focus_mode = Control.FOCUS_NONE
	clip_contents = true
	custom_minimum_size = Vector2(CoopLayoutRes.MAP_CARD_W, CoopLayoutRes.MAP_CARD_H)
	size = custom_minimum_size
	text = ""
	if font != null:
		add_theme_font_override("font", font)
	_apply_style(false)

	_thumb = MapThumbRes.new()
	_thumb.position = Vector2(0, 0)
	_thumb.size = Vector2(CoopLayoutRes.MAP_CARD_W, 132.0)
	_thumb.setup(cfg, map_data)
	add_child(_thumb)

	_name_label = _label("MapName", String(entry.get("map_name", "")), 15, UiStyleRes.text())
	_name_label.position = Vector2(6.0, 136.0)
	_name_label.size = Vector2(CoopLayoutRes.MAP_CARD_W - 12.0, 24.0)
	add_child(_name_label)

	_desc_label = _label("MapDesc", String(entry.get("level_name", entry.get("level", ""))),
		11, UiStyleRes.text_faint())
	_desc_label.position = Vector2(6.0, 162.0)
	_desc_label.size = Vector2(CoopLayoutRes.MAP_CARD_W - 12.0, 28.0)
	add_child(_desc_label)


func entry() -> Dictionary:
	return _entry


func map_name() -> String:
	return _name_label.text if _name_label != null else ""


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_apply_style(on)
	queue_redraw()


func is_selected() -> bool:
	return _selected


func _apply_style(on: bool) -> void:
	# ★ 选中 = **金边**，不是整块金底：金底会把白色地图名吃掉（3.png 的选中态是描边）。
	var normal := UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line_soft()) if not on \
		else UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.accent(), 2)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", UiStyleRes.panel_style(
		UiStyleRes.bg_hover(), UiStyleRes.accent(), 1))
	add_theme_stylebox_override("pressed", UiStyleRes.panel_style(
		UiStyleRes.bg_pressed(), UiStyleRes.accent(), 2))
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _label(node_name: String, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l
