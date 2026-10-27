## coop_map_picker.gd —— 合作地图选择面板（640×1080，从右滑入）。
##
## 参考当前合作模式的「地图选择层」：3 列地图卡 + 确认/取消。
## 只对房主/AI 开放；点卡片只高亮，确认才应用。
extends "res://view/menu_page.gd"

signal confirmed(entry: Dictionary)
signal cancelled

const MapCardRes = preload("res://view/coop_map_card.gd")

var session = null
var _scroll: ScrollContainer = null
var _grid: GridContainer = null
var _cards: Array = []
var _pending: Dictionary = {}
var _confirm: Button = null
var _cancel: Button = null
var _empty: Label = null


func setup(p_cfg, p_font: Font, p_session) -> void:
	name = "CoopMapPicker"
	z_index = 50
	session = p_session
	setup_page(p_cfg, p_font, String(p_cfg.str_val("coop.lobby.select_map", "选择地图")), true)
	var opaque := MenuThemeRes.deck_panel()
	opaque.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 1.0)
	background().add_theme_stylebox_override("panel", opaque)
	back_pressed.connect(_on_cancel)

	_scroll = ScrollContainer.new()
	_scroll.name = "MapScroll"
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.z_index = 5
	add_child(_scroll)

	_grid = GridContainer.new()
	_grid.name = "MapGrid"
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	_scroll.add_child(_grid)

	_empty = make_label("MapEmpty", String(cfg.str_val("coop.lobby.map_none", "无可用合作地图")),
		18, ThemeRes.text_faint(), HORIZONTAL_ALIGNMENT_CENTER)
	_empty.z_index = 5
	add_child(_empty)

	var brs := LayoutRes.map_picker_buttons(0.0)
	_cancel = make_text_button("MapCancel", String(cfg.str_val("coop.lobby.back_text", "取消")), 20)
	_cancel.pressed.connect(_on_cancel)
	_cancel.z_index = 5
	add_child(_cancel)

	_confirm = make_text_button("MapConfirm", String(cfg.str_val("coop.lobby.confirm", "确认")), 20)
	_confirm.pressed.connect(_on_confirm)
	_confirm.z_index = 5
	add_child(_confirm)

	resized.connect(_layout)
	_build_cards()
	_layout()
	_refresh_selection()


func _build_cards() -> void:
	if session == null:
		return
	for item in session.entries():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var card = MapCardRes.new()
		card.name = "MapCard_%s" % String(e.get("level", ""))
		_grid.add_child(card)
		card.setup(cfg, e, session.map_data_for(e), font)
		card.pressed.connect(_on_card.bind(e))
		_cards.append(card)
	_empty.visible = _cards.is_empty()
	_confirm.disabled = true


func set_current(entry: Dictionary) -> void:
	_pending = entry
	_refresh_selection()


func pending_entry() -> Dictionary:
	return _pending


func cards() -> Array:
	return _cards


func confirm_button() -> Button:
	return _confirm


func cancel_button() -> Button:
	return _cancel


func _on_card(entry: Dictionary) -> void:
	_pending = entry
	_refresh_selection()


func _refresh_selection() -> void:
	for card in _cards:
		var e: Dictionary = card.entry()
		var same := String(e.get("campaign", "")) == String(_pending.get("campaign", "")) \
			and String(e.get("level", "")) == String(_pending.get("level", ""))
		card.set_selected(same)
	if _confirm != null:
		_confirm.disabled = _pending.is_empty()


func _on_confirm() -> void:
	if _pending.is_empty():
		return
	confirmed.emit(_pending)


func _on_cancel() -> void:
	cancelled.emit()


func _layout() -> void:
	if _scroll == null:
		return
	var gr := LayoutRes.map_grid(size.x)
	_scroll.position = gr.position
	_scroll.size = gr.size
	_empty.position = gr.position
	_empty.size = Vector2(gr.size.x, 80.0)
	var brs := LayoutRes.map_picker_buttons(size.x)
	_cancel.position = brs[0].position
	_cancel.size = brs[0].size
	_confirm.position = brs[1].position
	_confirm.size = brs[1].size
