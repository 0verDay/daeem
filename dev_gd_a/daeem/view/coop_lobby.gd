## coop_lobby.gd —— 主界面「合作模式」面板的内容（M12.4）。
##
## 只负责**大厅交互**：填中继地址 / 建房 / 输码加入 / 准备 / 房主开始。
## 真正的房间协议在 `net/lobby.gd`；进游戏后的房主 / 客机接线在 `game_scene3d.gd`。
##
## ★ 开局交接：房主点「开始」或客机收到 `start` 时，本控件把 transport 交出去
##   （`lobby.take_transport()`）并发出 `host_started` / `guest_started`；
##   从那一刻起这个面板不再碰网络。
extends Control

const LobbyRes = preload("res://net/lobby.gd")
const RelayTransportRes = preload("res://net/relay_transport.gd")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const ThemeRes = preload("res://view/theme.gd")

signal host_started(campaign_id: String, level_id: String, transport)
signal guest_started(payload: Dictionary, transport)

var cfg = null
var _font: Font = null
var _lobby = null
var _levels: Array = []
var _pending: String = ""

var _url_edit: LineEdit = null
var _code_edit: LineEdit = null
var _level_opt: OptionButton = null
var _status: Label = null
var _create_btn: Button = null
var _join_btn: Button = null
var _ready_btn: Button = null
var _start_btn: Button = null
var _started: bool = false


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var margin: float = cfg.num("menu.chrome.expanded_margin", 24.0) if cfg != null else 24.0
	var center := CenterContainer.new()
	center.name = "CoopCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.offset_top = margin + 70.0
	center.offset_bottom = -margin
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var box := VBoxContainer.new()
	box.name = "CoopBox"
	box.custom_minimum_size = Vector2(760, 0)
	box.add_theme_constant_override("separation", 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	box.add_child(_label("标题", cfg.str_val("coop.lobby.title", "合作模式"), 42,
		ThemeRes.text(), false))
	box.add_child(_label("说明", cfg.str_val("coop.lobby.subtitle",
		"两人各指挥一方，共享视野；先建房或输入房间码加入。"), 18,
		ThemeRes.text_dim(), true))

	# 中继地址
	box.add_child(_label("地址标签", cfg.str_val("coop.lobby.url_label", "中继地址"), 18,
		ThemeRes.text_dim(), false))
	_url_edit = _line_edit("RelayUrl", cfg.str_val("net.relay_url", "ws://127.0.0.1:8770/ws"), 36)
	box.add_child(_url_edit)

	# 关卡（房主用；客机从 start 里拿）
	box.add_child(_label("关卡标签", cfg.str_val("coop.lobby.host_level", "关卡"), 18,
		ThemeRes.text_dim(), false))
	_level_opt = OptionButton.new()
	_level_opt.name = "LevelOption"
	_level_opt.custom_minimum_size = Vector2(0, 44)
	_level_opt.focus_mode = Control.FOCUS_NONE
	if _font != null:
		_level_opt.add_theme_font_override("font", _font)
	_level_opt.add_theme_font_size_override("font_size", 18)
	box.add_child(_level_opt)
	_load_levels()

	# 房间码
	box.add_child(_label("房间码标签", cfg.str_val("coop.lobby.code_label", "房间码"), 18,
		ThemeRes.text_dim(), false))
	_code_edit = _line_edit("RoomCode", "", 44)
	_code_edit.max_length = 6
	_code_edit.placeholder_text = cfg.str_val("coop.lobby.code_placeholder", "6 位码（建房可留空）")
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_code_edit)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(row)

	_create_btn = _button("CreateBtn", cfg.str_val("coop.lobby.create", "创建房间"))
	_create_btn.pressed.connect(_on_create)
	row.add_child(_create_btn)

	_join_btn = _button("JoinBtn", cfg.str_val("coop.lobby.join", "加入房间"))
	_join_btn.pressed.connect(_on_join)
	row.add_child(_join_btn)

	_ready_btn = _button("ReadyBtn", cfg.str_val("coop.lobby.ready", "准备"))
	_ready_btn.pressed.connect(_on_ready)
	_ready_btn.disabled = true
	row.add_child(_ready_btn)

	_start_btn = _button("StartBtn", cfg.str_val("coop.lobby.start", "开始"))
	_start_btn.pressed.connect(_on_start)
	_start_btn.disabled = true
	row.add_child(_start_btn)

	_status = _label("Status", cfg.str_val("coop.lobby.status_idle", "未连接"), 18,
		ThemeRes.accent(), true)
	box.add_child(_status)


func _process(_dt: float) -> void:
	if _lobby != null:
		_lobby.poll()


func _exit_tree() -> void:
	_reset_lobby()


func _reset_lobby() -> void:
	if _lobby != null:
		var t = _lobby.take_transport()
		if t != null:
			t.close()
		_lobby = null


# ------------------------------------------------------------------
# 按钮
# ------------------------------------------------------------------

func _on_create() -> void:
	_begin("create")


func _on_join() -> void:
	var code := _code_edit.text.strip_edges()
	if code.length() != 6:
		_set_status("请输入 6 位房间码")
		return
	_begin("join")


func _on_ready() -> void:
	if _lobby == null:
		return
	_lobby.ready()
	_ready_btn.disabled = true


func _on_start() -> void:
	if _lobby == null or _started or _lobby.my_role != "host":
		return
	if not (_lobby.has_guest() and _lobby.is_ready()):
		_set_status("等队友加入并准备")
		return
	var entry := _selected_level()
	if entry.is_empty():
		_set_status("没有可用的合作关")
		return
	_started = true
	_set_status(cfg.str_val("coop.lobby.status_started", "房主已开始"))
	var t = _lobby.take_transport()
	host_started.emit(String(entry["campaign"]), String(entry["level"]), t)


func _begin(action: String) -> void:
	if _lobby != null:
		return
	var url := _url_edit.text.strip_edges()
	if url == "":
		_set_status("中继地址为空")
		return
	_pending = action
	_lobby = LobbyRes.new()
	_lobby.setup(cfg, RelayTransportRes.new(), cfg.str_val("net.build", "coop-m12.2"))
	_lobby.connected.connect(_on_connected)
	_lobby.room_state_changed.connect(_on_room_state)
	_lobby.guest_started.connect(_on_guest_started)
	_lobby.error.connect(_on_error)
	_lobby.closed.connect(_on_closed)
	_set_status(cfg.str_val("coop.lobby.status_connecting", "连接服务器…"))
	_create_btn.disabled = true
	_join_btn.disabled = true
	_lobby.connect_to(url)


func _on_connected() -> void:
	_set_status(cfg.str_val("coop.lobby.status_connected", "已连接"))
	var action := _pending
	_pending = ""
	if action == "create":
		_lobby.create_room(_code_edit.text.strip_edges())
	elif action == "join":
		_lobby.join_room(_code_edit.text.strip_edges())
	else:
		_ready_btn.disabled = false


func _on_room_state(state: Dictionary) -> void:
	var code := String(state.get("code", ""))
	_code_edit.text = code
	_ready_btn.disabled = false
	var both := bool(state.get("ready_host", false)) and bool(state.get("ready_guest", false))
	var guest := bool(state.get("guest", false))
	if both:
		_set_status(cfg.str_val("coop.lobby.status_ready", "房间 %s · 双方已准备") % code)
	elif guest:
		_set_status(cfg.str_val("coop.lobby.status_full", "房间 %s · 队友已加入") % code)
	else:
		_set_status(cfg.str_val("coop.lobby.status_room", "房间 %s · 等待队友") % code)
	_start_btn.disabled = not (_lobby != null and _lobby.my_role == "host" and guest and both)


func _on_guest_started(payload: Dictionary, transport) -> void:
	_started = true
	_set_status(cfg.str_val("coop.lobby.status_started", "房主已开始"))
	guest_started.emit(payload, transport)


func _on_error(code: String, msg: String) -> void:
	_set_status(cfg.str_val("coop.lobby.err", "错误：%s") % ("%s %s" % [code, msg]).strip_edges())
	_reset_lobby()
	_create_btn.disabled = false
	_join_btn.disabled = false


func _on_closed(_reason: String) -> void:
	if _started:
		return
	_set_status(cfg.str_val("coop.lobby.closed", "连接已断开"))
	_reset_lobby()
	_create_btn.disabled = false
	_join_btn.disabled = false
	_ready_btn.disabled = true
	_start_btn.disabled = true


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text


# ------------------------------------------------------------------
# 关卡表
# ------------------------------------------------------------------

func _load_levels() -> void:
	_levels.clear()
	for opt in CampaignLibraryRes.coop_campaigns(cfg):
		var camp = CampaignLibraryRes.load_campaign_by_option(opt, cfg)
		if camp == null:
			continue
		for lv in camp.levels:
			if lv != null and String(lv.mode) == "coop":
				_levels.append({
					"campaign": String(camp.id),
					"level": String(lv.id),
					"label": String(lv.name) if String(lv.name) != "" else String(lv.id),
				})
	for e in _levels:
		_level_opt.add_item(String((e as Dictionary)["label"]))
	if _level_opt.item_count == 0:
		_level_opt.add_item("无合作关")
		_level_opt.disabled = true
	else:
		_level_opt.select(0)


func _selected_level() -> Dictionary:
	if _levels.is_empty():
		return {}
	var idx := maxi(0, _level_opt.selected)
	return _levels[mini(idx, _levels.size() - 1)]


# ------------------------------------------------------------------
# 控件
# ------------------------------------------------------------------

func _label(node_name: String, text: String, size: int, color: Color,
		wrap: bool) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _line_edit(node_name: String, text: String, height: float) -> LineEdit:
	var e := LineEdit.new()
	e.name = node_name
	e.text = text
	e.custom_minimum_size = Vector2(0, height)
	e.focus_mode = Control.FOCUS_ALL
	if _font != null:
		e.add_theme_font_override("font", _font)
	e.add_theme_font_size_override("font_size", 20)
	e.add_theme_color_override("font_color", ThemeRes.text())
	e.add_theme_color_override("font_placeholder_color", ThemeRes.text_dim())
	return e


func _button(node_name: String, text: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(0, 54)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", 20)
	FillButtonRes.attach_text(b)
	UiWidgetsRes.apply_button_styles(b, {
		"normal": MenuThemeRes.button_normal(),
		"hover": MenuThemeRes.button_hover_clear(),
		"pressed": MenuThemeRes.button_fill_latched(),
		"disabled": MenuThemeRes.button_disabled(),
	})
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	return b
