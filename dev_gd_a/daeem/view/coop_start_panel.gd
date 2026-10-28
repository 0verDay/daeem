## coop_start_panel.gd —— 合作过渡面板（1280×1080）。
##
## 两面旗帜：玩家旗 + 虚位旗。
##   · 点虚位旗 → AI 队友 → 准备页；
##   · 点面板空白 → 房间页；
##   · 返回 → 主菜单。
extends "res://view/menu_page.gd"

signal ai_pressed
signal room_pressed

const BannerRes = preload("res://view/menu_banner.gd")

var _self_flag = null
var _empty_flag = null
var _hint: Label = null
var _ai_joined: bool = false


func setup(p_cfg, p_font: Font) -> void:
	name = "CoopStartPanel"
	setup_page(p_cfg, p_font, String(p_cfg.str_val("menu.deck.titles.coop", "合作")), true)
	gui_input.connect(_on_blank_input)

	_self_flag = BannerRes.new()
	_self_flag.name = "PlayerFlag"
	_self_flag.z_index = 6
	add_child(_self_flag)
	_self_flag.setup(font, "player", "你", "房主")

	_empty_flag = BannerRes.new()
	_empty_flag.name = "EmptyFlag"
	_empty_flag.z_index = 6
	add_child(_empty_flag)
	_empty_flag.setup(font, "empty", "虚位以待", "点击加入 AI 队友")
	_empty_flag.pressed.connect(func(): ai_pressed.emit())

	_hint = make_label("BlankHint",
		String(cfg.str_val("coop.lobby.click_blank_hint", "——点击空白处进入房间列表——")),
		22, ThemeRes.text_dim(), HORIZONTAL_ALIGNMENT_CENTER)
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint.z_index = 5
	add_child(_hint)

	resized.connect(_layout)
	_layout()


func _on_blank_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			accept_event()
			room_pressed.emit()


func _layout() -> void:
	if _self_flag == null:
		return
	var r0 := LayoutRes.coop_flag(size.x, size.y, 0)
	var r1 := LayoutRes.coop_flag(size.x, size.y, 1)
	_self_flag.position = r0.position
	_self_flag.size = r0.size
	_empty_flag.position = r1.position
	_empty_flag.size = r1.size

	var hr := LayoutRes.coop_hint(size.x, size.y)
	_hint.position = hr.position
	_hint.size = hr.size


func player_flag():
	return _self_flag


func empty_flag():
	return _empty_flag


func blank_hint() -> Label:
	return _hint


## AI 加入后，虚位旗变成「AI 队友 / 已加入」，并且不再可点。
func set_ai_joined(on: bool) -> void:
	if _ai_joined == on:
		return
	_ai_joined = on
	if _empty_flag == null:
		return
	if on:
		_empty_flag.set_state("player", "AI 队友", "已加入")
		_empty_flag.set_selected(true)
		_empty_flag.set_clickable(false)
	else:
		_empty_flag.set_state("empty", "虚位以待", "点击加入 AI 队友")
		_empty_flag.set_selected(false)
		_empty_flag.set_clickable(true)


func ai_joined() -> bool:
	return _ai_joined
