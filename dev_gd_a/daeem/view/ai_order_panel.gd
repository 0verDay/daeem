## ai_order_panel.gd —— 合作模式「AI 队友」的浮动指令面板。
##
## 只读 world 的 AI 状态，只**发信号**（不直接改世界）：
##   · order_requested(order, ai_faction)  —— 发展 / 扩张：点一下立刻下指令；
##   · pick_requested(order, ai_faction)   —— 行军 / 屯兵：进入地图选点模式。
## 真正的命令由 `view/game_scene3d.gd` 组装并交给 `command_processor`。
##
## ★ 面板只在「本机有同方 commander」时出现；传统真人合作局 / 战役 / 自由对战不建它。
## ★ 位置与尺寸进 config（`ui.ai_panel`），view 里不写死几何。
## ★ 拖动 / 折叠只改本地状态，不进快照。
extends Control

signal order_requested(order: String, ai_faction: String)
signal pick_requested(order: String, ai_faction: String)

const UiStyleRes = preload("res://view/ui_style.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

var cfg = null
var world = null
var _font: Font = null

var _faction: String = ""
## ★★ 观战模式：面板只显示状态、不接命令（空 = 正常 AI 队友面板）。
var _observer_faction: String = ""
## ★★ 观战但仍授权下令（ai_test_2）：四颗指令按钮保持可点，只放行 AI 指令。
var _observer_allow_orders: bool = false
var _collapsed: bool = false
var _w: float = 320.0
var _h: float = 236.0
var _ch: float = 40.0
var _margin_r: float = 16.0
var _margin_t: float = 96.0
## 右侧部队列表（SQUAD_RECT 宽 240）与它的缝：面板右缘必须停在它左边，
## 否则会压住 1..0 的部队列表（实机截图确认过）。
var _right_reserve: float = 300.0

var _title: Label = null
var _collapsed_btn: Button = null
var _buttons: Dictionary = {}
var _lbl_directive: Label = null
var _lbl_army: Label = null
var _lbl_res: Label = null
var _lbl_status: Label = null
var _hint: Label = null

var _dragging: bool = false
var _moved: bool = false
var _drag_off: Vector2 = Vector2.ZERO
var _sync_acc: float = 0.0
var _pick_mode: String = ""


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	_w = _num("ui.ai_panel.width", 320.0)
	_h = _num("ui.ai_panel.height", 236.0)
	_ch = _num("ui.ai_panel.collapsed_height", 40.0)
	_margin_r = _num("ui.ai_panel.margin_right", 16.0)
	_margin_t = _num("ui.ai_panel.margin_top", 96.0)
	_right_reserve = _num("ui.ai_panel.right_reserve", 300.0)
	if OS.has_feature("mobile"):
		_w = _num("ui.ai_panel.mobile_width", 260.0)
		_h = _num("ui.ai_panel.mobile_height", 210.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()
	_reposition()
	resized.connect(_reposition)


func bind_world(p_world) -> void:
	world = p_world
	sync()


## ★★ 观战：绑定被观察的 AI 阵营，四颗指令按钮默认置灰（只读）。
## `allow_orders = true`（ai_test_2）时按钮保持可点，玩家可以给 AI 下四条指令。
func set_observer(fid: String, allow_orders: bool = false) -> void:
	_observer_faction = fid
	_observer_allow_orders = allow_orders and fid != ""
	_pick_mode = ""
	for k in _buttons.keys():
		(_buttons[k] as Button).disabled = fid != "" and not _observer_allow_orders
	if fid != "":
		if _observer_allow_orders:
			_title.text = "观战 · 可下令"
		else:
			_title.text = "观战 · %s" % _txt("title", "AI 队友")
	else:
		_title.text = _txt("title", "AI 队友")
	sync()


func _num(path: String, fallback: float) -> float:
	if cfg == null:
		return fallback
	return float(cfg.num(path, fallback))


func _txt(path: String, fallback: String) -> String:
	if cfg == null:
		return fallback
	return String(cfg.str_val("ui.ai_panel." + path, fallback))


func _build() -> void:
	var bg := Panel.new()
	bg.name = "Bg"
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line()))
	add_child(bg)

	_title = _label("Title", _txt("title", "AI 队友"), int(_num("ui.ai_panel.title_font_size", 18.0)), UiStyleRes.accent())
	_title.position = Vector2(14, 10)
	_title.size = Vector2(_w - 54, _ch - 16)
	add_child(_title)

	_collapsed_btn = Button.new()
	_collapsed_btn.name = "Collapse"
	_collapsed_btn.text = "▾"
	_collapsed_btn.focus_mode = Control.FOCUS_NONE
	_collapsed_btn.size = Vector2(30, 26)
	_collapsed_btn.position = Vector2(_w - 40, 7)
	_collapsed_btn.pressed.connect(_toggle_collapsed)
	if _font != null:
		_collapsed_btn.add_theme_font_override("font", _font)
	add_child(_collapsed_btn)

	var grid := GridContainer.new()
	grid.name = "Buttons"
	grid.columns = 2
	grid.position = Vector2(12, _ch + 6)
	grid.size = Vector2(_w - 24, 64)
	grid.add_theme_constant_override("h_separation", int(_num("ui.ai_panel.button_gap", 6.0)))
	grid.add_theme_constant_override("v_separation", int(_num("ui.ai_panel.button_gap", 6.0)))
	add_child(grid)

	var keys := ["march", "develop", "expand", "mass"]
	for k in keys:
		var b := _button("Btn_" + k, _txt("buttons." + k, k))
		b.custom_minimum_size = Vector2((_w - 24 - 6) / 2.0, 28)
		b.pressed.connect(_on_order.bind(k))
		grid.add_child(b)
		_buttons[k] = b

	var y0 := _ch + 70
	_lbl_directive = _label("Directive", "", int(_num("ui.ai_panel.font_size", 15.0)), UiStyleRes.text())
	_lbl_directive.position = Vector2(14, y0)
	_lbl_directive.size = Vector2(_w - 28, 22)
	add_child(_lbl_directive)

	_lbl_army = _label("Army", "", int(_num("ui.ai_panel.font_size", 15.0)), UiStyleRes.text())
	_lbl_army.position = Vector2(14, y0 + 24)
	_lbl_army.size = Vector2(_w - 28, 22)
	add_child(_lbl_army)

	_lbl_res = _label("Res", "", int(_num("ui.ai_panel.font_size", 15.0)), UiStyleRes.text_dim())
	_lbl_res.position = Vector2(14, y0 + 48)
	_lbl_res.size = Vector2(_w - 28, 22)
	add_child(_lbl_res)

	_lbl_status = _label("Status", "", int(_num("ui.ai_panel.font_size", 15.0)), UiStyleRes.accent())
	_lbl_status.position = Vector2(14, y0 + 72)
	_lbl_status.size = Vector2(_w - 28, 22)
	add_child(_lbl_status)

	_hint = _label("Hint", "", int(_num("ui.ai_panel.font_size", 15.0)) - 1, UiStyleRes.text_faint())
	_hint.position = Vector2(14, _h - 26)
	_hint.size = Vector2(_w - 28, 20)
	_hint.visible = false
	add_child(_hint)


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


func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", int(_num("ui.ai_panel.font_size", 15.0)))
	UiWidgetsRes.apply_button_styles(b, {
		"normal": MenuThemeRes.button_normal(),
		"hover": MenuThemeRes.button_hover_clear(),
		"pressed": MenuThemeRes.button_fill_latched(),
		"disabled": MenuThemeRes.button_disabled(),
	})
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	return b


func _reposition() -> void:
	if _dragging or not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	if not _moved:
		var reserve: float = _right_reserve if _right_reserve > 0.0 else _margin_r
		position = Vector2(maxf(0.0, vp.x - _w - reserve), _margin_t)
	size = Vector2(_w, _ch if _collapsed else _h)


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	size = Vector2(_w, _ch if _collapsed else _h)
	_collapsed_btn.text = "▸" if _collapsed else "▾"
	_set_body_visible(not _collapsed)


func _set_body_visible(v: bool) -> void:
	for k in _buttons.keys():
		(_buttons[k] as Control).visible = v
	_lbl_directive.visible = v
	_lbl_army.visible = v
	_lbl_res.visible = v
	_lbl_status.visible = v
	_hint.visible = v and _pick_mode != ""


func _on_order(order: String) -> void:
	if _faction == "":
		return
	if _observer_faction != "" and not _observer_allow_orders:
		return
	if order == "march" or order == "mass":
		_sync_pick_hint(order)
		pick_requested.emit(order, _faction)
	else:
		order_requested.emit(order, _faction)
	sync()


## 由场景层告知「现在正在为哪条指令选点」；"" = 没在选。
func set_pick_mode(order: String) -> void:
	_pick_mode = order
	if _hint != null:
		_hint.text = _txt("target_pick_hint", "点击地图选择目标（右键 / Esc 取消）")
		_hint.visible = not _collapsed and order != ""
	if _lbl_status != null and order != "":
		_lbl_status.text = _state_text(order)


func _sync_pick_hint(order: String) -> void:
	set_pick_mode(order)


func _process(dt: float) -> void:
	if not visible or world == null:
		return
	_sync_acc += dt
	if _sync_acc < 0.2:
		return
	_sync_acc = 0.0
	sync()


func sync() -> void:
	if world == null or cfg == null:
		return
	if world.observer_mode:
		_faction = String(world.my_faction)
		visible = _faction != ""
		if not visible:
			return
		_reposition()
		_sync_state(not _observer_allow_orders)
		return
	var mates: Array = world.ai_teammates_for(world.my_faction)
	if mates.is_empty():
		visible = false
		_faction = ""
		return
	_faction = String(mates[0])
	visible = true
	_reposition()
	_sync_state(false)


## 面板内容刷新。`read_only` = 观战（按钮已由 set_observer 置灰）。
func _sync_state(read_only: bool) -> void:
	var st: Dictionary = world.ai_panel_state(_faction)
	var title := _txt("title", "AI 队友")
	var nm := String(st.get("name", _faction))
	if _observer_faction != "":
		if _observer_allow_orders:
			_title.text = "观战 · 可下令 · %s" % nm
		else:
			_title.text = "观战 · %s · %s" % [title, nm]
	else:
		_title.text = "%s · %s" % [title, nm]
	var dir := String(st.get("directive", ""))
	for k in _buttons.keys():
		var b: Button = _buttons[k]
		var on: bool = String(k) == dir
		b.disabled = read_only
		b.add_theme_color_override("font_color",
			UiStyleRes.accent() if on else UiStyleRes.text())
	_lbl_directive.text = "%s  %s" % [
		_txt("status_labels.directive", "指令"), _directive_text(st)]
	_lbl_army.text = "%s  %d / %d · 将 %d / %d" % [
		_txt("status_labels.army", "部队"), int(st.get("army", 0)), int(st.get("army_cap", 0)),
		int(st.get("generals", 0)), int(st.get("general_target", 0))]
	_lbl_res.text = "%s  粮 %d · 金 %d" % [
		_txt("status_labels.resources", "资源"), int(st.get("food", 0.0)), int(st.get("gold", 0.0))]
	var status := String(st.get("status", ""))
	var state_text := _state_text(status)
	var hold_left := int(round(float(st.get("hold_left", 0.0))))
	if hold_left > 0:
		state_text += " · 指令 %ds" % hold_left
	_lbl_status.text = "%s  %s" % [
		_txt("status_labels.state", "状态"), state_text]
	if _pick_mode != "":
		_hint.visible = not _collapsed
	_hint.text = _txt("target_pick_hint", "点击地图选择目标（右键 / Esc 取消）")


func _directive_text(st: Dictionary) -> String:
	var kind := String(st.get("directive", ""))
	var target: Vector2i = st.get("target", Vector2i(-1, -1))
	match kind:
		"march":
			return "行军至 (%d, %d)" % [target.x, target.y]
		"mass":
			return "集结于 (%d, %d)" % [target.x, target.y]
		"expand":
			return "扩张"
		"auto":
			return "自动"
		_:
			return "发展"


func _state_text(key: String) -> String:
	return _txt("states." + key, key)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed and mb.position.y <= _ch:
			_dragging = true
			_drag_off = mb.position
			accept_event()
		elif not mb.pressed and _dragging:
			_dragging = false
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		position += mm.relative
		_moved = true
		var vp := get_viewport_rect().size
		position.x = clampf(position.x, 0.0, maxf(0.0, vp.x - size.x))
		position.y = clampf(position.y, 0.0, maxf(0.0, vp.y - size.y))
		accept_event()
