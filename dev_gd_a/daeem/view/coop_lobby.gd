## coop_lobby.gd —— 合作模式大厅（三态：大厅 / 房间 / 地图选择）。
##
## 版式参考 `art_draft/1.png`（大厅）、`2.png`（房间）、`3.png`（地图选择）：
##   · 左 / 中两块玩家席位；
##   · 右侧大厅面板：房间列表（刘海 + 刷新）、6 位数字房间码、键盘、进入 / 创建；
##   · 进入房间后面板右滑出、房间配置面板左滑入；
##   · 点地图预览 → 席位左滑出、房间面板滑到左侧、地图列表从右滑入，返回按钮滑到左上。
##
## ★ 只负责大厅交互；真正的房间协议在 `net/lobby.gd`，房间列表在
##   `net/room_directory.gd`（HTTP /rooms），地图目录在 `logic/coop_catalog.gd`。
## ★ 开局交接与旧版一致：房主点开始 / 客机收到 start 时，把 transport 交出去并发信号。
extends Control

signal host_started(campaign_id: String, level_id: String, transport)
signal guest_started(payload: Dictionary, transport)

const LobbyRes = preload("res://net/lobby.gd")
const RelayTransportRes = preload("res://net/relay_transport.gd")
const ProtocolRes = preload("res://net/protocol.gd")
const RoomDirectoryRes = preload("res://net/room_directory.gd")
const CoopCatalogRes = preload("res://logic/coop_catalog.gd")
const CoopLayoutRes = preload("res://view/coop_layout.gd")
const SeatRes = preload("res://view/troop_seat.gd")
const MapThumbRes = preload("res://view/map_thumb.gd")
const MapCardRes = preload("res://view/coop_map_card.gd")
const ElasticScrollListRes = preload("res://view/elastic_scroll_list.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const ThemeRes = preload("res://view/theme.gd")

const STATE_LOBBY := "lobby"
const STATE_ROOM := "room"
const STATE_MAP := "map"

var cfg = null
var _font: Font = null
var _state: String = STATE_LOBBY
var _anim_sec: float = 0.32

## 网络
var _lobby = null
var _transport = null
var _pending_action: Dictionary = {}
var _in_game: bool = false
## ★★ 调试后门：Ctrl+Q 在房间界面伪造的队友（只在本机，不经过服务器）。
##   见 `_debug_fake_guest()`；真队友加入时会被服务器的 room_state 覆盖掉。
var _fake_guest: bool = false

## 房间列表
var _http: HTTPRequest = null
var _http_busy: bool = false
var _rooms: Array = []
var _room_timer: Timer = null

## 地图目录
var _entries: Array = []
var _current_entry: Dictionary = {}
var _pending_entry: Dictionary = {}
var _map_cache: Dictionary = {}

## 节点
var _self_seat = null
var _mate_seat = null
var _lobby_panel: Panel = null
var _room_panel: Panel = null
var _map_panel: Panel = null
var _room_list_body: VBoxContainer = null
var _room_list: Control = null
var _refresh_btn: Button = null
var _list_title: Label = null
var _lobby_status: Label = null
var _code_edit: LineEdit = null
var _clear_btn: Button = null
var _key_buttons: Dictionary = {}
var _action_btn: Button = null
var _room_preview_btn: Button = null
var _room_thumb = null
var _room_map_name: Label = null
var _room_map_hint: Label = null
var _room_code_label: Label = null
var _room_desc: Label = null
var _room_action_btn: Button = null
var _map_grid: GridContainer = null
var _map_cards: Array = []
var _back_btn: Button = null
var _back_ready: bool = false
var _relay_override: String = ""
var _state_tween: Tween = null
var _last_lobby_error: String = ""
## 大厅面板撑满时的尺寸：收回时按它的比例把整块内容缩小（而不是让内容被裁掉后“往右下跑”）。
var _scale_base: Vector2 = Vector2.ZERO
## 仅测试 / 截图用：覆盖视口宽度，模拟手机横屏比 1920 更宽。
var _screen_width_override: float = 0.0


func setup(p_cfg, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	_anim_sec = 0.0 if cfg == null else maxf(0.0, float(cfg.num("coop.lobby.anim_sec", 0.32)))
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_on_resized)
	_load_catalog()
	_build()
	_reposition_layout.call_deferred()
	_start_room_timer()
	_refresh_rooms()


func _process(_dt: float) -> void:
	if _lobby != null:
		_lobby.poll()


## ★★ 调试后门：在「房间」界面按 Ctrl+Q，本机伪造一个已加入且已准备的队友。
##
## ★ 为什么只在本地改 `_lobby.room`：后门不该要求服务端配合。
##   中继那边这间房仍然没有 guest，房主点「开始」时服务器会回一条 `err: start`，
##   但**不会断开连接**；此时 transport 已经交给 `game_scene`，那条 err 被 HostSession
##   静默丢弃，于是单人也能真的进合作关。
## ★ 进入游戏后第二个席位就是关卡里的 F2：照常生成部队 / 建筑，但没有客机、
##   没有输入、没有 AI —— 纯占位。它不会自己动，也不会发命令。
## ★ 如果真有队友加入，服务器会推 `room_state`，`_on_room_state()` 把 `_fake_guest`
##   清掉、用真实状态覆盖 ⇒ 后门自动失效，不会挡住正常联机。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if not (key.keycode == KEY_Q or key.physical_keycode == KEY_Q) or not key.ctrl_pressed:
		return
	# 只在「房间」界面生效；已经进游戏 / 面板已收起时不响应。
	if _state != STATE_ROOM or _in_game or not is_visible_in_tree():
		return
	if _debug_fake_guest():
		get_viewport().set_input_as_handled()


## 测试 / 排查：覆盖 `net.relay_url`（正常玩家不调用）。
func set_relay_url(url: String) -> void:
	_relay_override = url.strip_edges()
	_refresh_rooms()


func _relay_url() -> String:
	if _relay_override != "":
		return _relay_override
	return String(cfg.str_val("net.relay_url", "")) if cfg != null else ""


## 测试 / 排查：把动效时长设成 0，直接跳到终态。
func set_animation_sec(sec: float) -> void:
	_anim_sec = maxf(0.0, sec)


func state_name() -> String:
	return _state


# ------------------------------------------------------------------
# 构建
# ------------------------------------------------------------------

func _build() -> void:
	_self_seat = _make_seat("SelfSeat", CoopLayoutRes.SELF_SEAT)
	_mate_seat = _make_seat("MateSeat", CoopLayoutRes.MATE_SEAT)

	_lobby_panel = _make_panel("LobbyPanel", CoopLayoutRes.LOBBY_PANEL)
	_room_panel = _make_panel("RoomPanel", CoopLayoutRes.ROOM_PANEL)
	_map_panel = _make_panel("MapPanel", CoopLayoutRes.OFFSCREEN_RIGHT)
	_build_lobby_panel()
	_build_room_panel()
	_build_map_panel()

	# 按钮要压在面板之上（面板后建会盖住席位，这是有意的：席位只是背景）。
	_set_state_instant(STATE_LOBBY)
	_update_seats()
	_update_room_preview(_current_entry)
	_update_room_action()
	_update_action()


func _make_seat(node_name: String, rect: Rect2) -> Panel:
	var seat = SeatRes.new()
	seat.name = node_name
	seat.position = _local_pos(rect.position)
	seat.size = rect.size
	add_child(seat)
	seat.setup(_font)
	return seat


func _make_panel(node_name: String, rect: Rect2) -> Panel:
	var p := Panel.new()
	p.name = node_name
	p.position = _local_pos(rect.position)
	p.size = rect.size
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line_soft()))
	add_child(p)
	return p


## `setup()` 可能在二级面板进树之前调用，那时 `global_position` 还是 0；
## 进树后再按真实的 24px 内缩重排一次（否则右侧面板整体偏 24px）。
func _reposition_layout() -> void:
	if not is_inside_tree():
		_reposition_layout.call_deferred()
		return
	# 撑满后的尺寸作为“1.0”基准；之后面板被 panel_expand 缩回时按比例整体缩小。
	if size.x > 1.0 and size.y > 1.0 and _scale_base == Vector2.ZERO:
		_scale_base = size
	_set_state_instant(_state)
	_apply_collapse_scale()
	if _back_btn != null and is_instance_valid(_back_btn):
		_back_btn.position = _local_pos(_back_rect_for(_state).position)
		_back_btn.size = CoopLayoutRes.BACK_RIGHT.size
		_back_ready = true


## 收回时 `panel_expand` 会把二级面板的 size 缩回原始方块；内容如果还按绝对坐标摆，
## 就会被裁成“整体往右下跑”。这里按面板尺寸等比缩小整块大厅，视觉上就是“整体缩小”。
func _apply_collapse_scale() -> void:
	if _scale_base.x <= 1.0 or _scale_base.y <= 1.0:
		return
	var s := minf(size.x / _scale_base.x, size.y / _scale_base.y)
	s = clampf(s, 0.04, 1.0)
	scale = Vector2(s, s)
	pivot_offset = size * 0.5


## 窗口 / 手机横竖屏变化：只有“收回面板”（宽高都明显变小）才做整体缩小；
## 其余情况按当前可视宽度重新排，面板右边始终跟返回按钮右边对齐。
func _on_resized() -> void:
	if not is_inside_tree():
		return
	var collapsing := _scale_base != Vector2.ZERO \
		and size.x < _scale_base.x * 0.9 and size.y < _scale_base.y * 0.9
	if collapsing:
		_apply_collapse_scale()
		return
	scale = Vector2.ONE
	pivot_offset = Vector2.ZERO
	_set_state_instant(_state)
	if _back_btn != null and is_instance_valid(_back_btn):
		_back_btn.position = _local_pos(_back_rect_for(_state).position)
		_back_btn.size = CoopLayoutRes.BACK_RIGHT.size


## 当前视口宽度。不能拿 `size.x`：二级面板本身比屏幕窄 48px，
## 手机横屏又被 stretch/expand 拉宽。
func _screen_w() -> float:
	if _screen_width_override > 0.0:
		return _screen_width_override
	var vp := get_viewport()
	if vp != null:
		return vp.get_visible_rect().size.x
	return maxf(1920.0, size.x)


## 测试 / 截图：模拟手机横屏宽度；传 0 恢复真实视口。
func set_screen_width_override(w: float) -> void:
	_screen_width_override = maxf(0.0, w)
	_on_resized()


## 右上角返回按钮的右缘（设计坐标）。
func _right_edge() -> float:
	return _screen_w() - 48.0


func _offscreen_right() -> Rect2:
	var r := CoopLayoutRes.OFFSCREEN_RIGHT
	r.position.x = _screen_w() + 20.0
	return r


func _lobby_rect_for(state: String) -> Rect2:
	if state != STATE_LOBBY:
		return _offscreen_right()
	var r := CoopLayoutRes.LOBBY_PANEL
	r.position.x = _right_edge() - r.size.x
	return r


func _room_rect_for(state: String) -> Rect2:
	match state:
		STATE_LOBBY:
			return _offscreen_right()
		STATE_MAP:
			return CoopLayoutRes.ROOM_PANEL_MAP
		_:
			var r := CoopLayoutRes.ROOM_PANEL
			r.position.x = _right_edge() - r.size.x
			return r


func _map_rect_for(state: String) -> Rect2:
	return CoopLayoutRes.MAP_PANEL if state == STATE_MAP else _offscreen_right()


func _back_rect_for(state: String) -> Rect2:
	if state == STATE_MAP:
		return CoopLayoutRes.BACK_LEFT
	var r := CoopLayoutRes.BACK_RIGHT
	r.position.x = _right_edge() - r.size.x
	return r


## 电脑 1920 宽保持原版式；手机横屏更宽时把两席位在左侧可用区里居中，
## 右面板贴到返回按钮下方，避免整页缩在左边、右侧空一大片。
func _seat_rect_for(state: String, base: Rect2) -> Rect2:
	if state == STATE_MAP:
		return CoopLayoutRes.seat_target(state, base)
	if _screen_w() <= 1920.5:
		return base
	var panel_left := _lobby_rect_for(STATE_LOBBY).position.x
	var start := 120.0 + maxf(0.0, ((panel_left - 120.0) - 120.0 - 880.0) * 0.5)
	var r := base
	r.position.x = start if base == CoopLayoutRes.SELF_SEAT else start + 520.0
	return r


## 设计坐标（1920×1080 屏幕）→ 本控件局部坐标。
## `menu_secondary_panel` 自己从 (24,24) 开始，尺寸 1872×1872；不扣掉这个偏移，
## 返回按钮会贴到屏幕最右边、右侧面板整体右移 24px。
func _local_pos(p: Vector2) -> Vector2:
	return p - global_position + position


func _build_lobby_panel() -> void:
	# 刘海：标题 + 数量 + 刷新
	var header := Panel.new()
	header.name = "RoomListHeader"
	header.position = CoopLayoutRes.LOBBY_HEADER.position
	header.size = CoopLayoutRes.LOBBY_HEADER.size
	header.mouse_filter = Control.MOUSE_FILTER_STOP
	header.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line()))
	_lobby_panel.add_child(header)

	_list_title = _label("RoomListTitle", _txt("room_list", "房间列表"), 20, UiStyleRes.accent())
	_list_title.position = Vector2(14, 12)
	_list_title.size = Vector2(330, 32)
	header.add_child(_list_title)

	_refresh_btn = _button("RefreshBtn", _txt("refresh", "刷新"), 14)
	_refresh_btn.position = CoopLayoutRes.LOBBY_REFRESH.position
	_refresh_btn.size = CoopLayoutRes.LOBBY_REFRESH.size
	_refresh_btn.pressed.connect(_refresh_rooms)
	header.add_child(_refresh_btn)

	# 房间列表：单独一块带边框的面板，内部才是可滚动列表（后续加滑动查看）。
	var list_box := Panel.new()
	list_box.name = "RoomListBox"
	list_box.position = CoopLayoutRes.LOBBY_LIST.position
	list_box.size = CoopLayoutRes.LOBBY_LIST.size
	list_box.mouse_filter = Control.MOUSE_FILTER_STOP
	list_box.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line()))
	_lobby_panel.add_child(list_box)

	_room_list = ElasticScrollListRes.new()
	_room_list.name = "RoomList"
	_room_list.position = Vector2(CoopLayoutRes.LOBBY_LIST_PAD, CoopLayoutRes.LOBBY_LIST_PAD)
	_room_list.size = CoopLayoutRes.LOBBY_LIST.size \
		- Vector2(CoopLayoutRes.LOBBY_LIST_PAD, CoopLayoutRes.LOBBY_LIST_PAD) * 2.0
	_room_list.set_allow_empty_drag(true)
	list_box.add_child(_room_list)

	_room_list_body = _room_list.get_content_box()
	_room_list_body.name = "RoomListBody"
	_room_list_body.add_theme_constant_override("separation", 6)

	_lobby_status = _label("LobbyStatus", "", 13, UiStyleRes.text_faint())
	_lobby_status.position = CoopLayoutRes.LOBBY_STATUS.position
	_lobby_status.size = CoopLayoutRes.LOBBY_STATUS.size
	_lobby_panel.add_child(_lobby_status)

	var code_label := _label("CodeLabel", _txt("code_label", "房间码"), 14, UiStyleRes.text_dim())
	code_label.position = CoopLayoutRes.LOBBY_CODE_LABEL.position
	code_label.size = CoopLayoutRes.LOBBY_CODE_LABEL.size
	_lobby_panel.add_child(code_label)

	_code_edit = LineEdit.new()
	_code_edit.name = "CodeEdit"
	_code_edit.position = CoopLayoutRes.LOBBY_CODE_EDIT.position
	_code_edit.size = CoopLayoutRes.LOBBY_CODE_EDIT.size
	_code_edit.max_length = 6
	_code_edit.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_edit.placeholder_text = _txt("code_hint", "输入 6 位数字房间码")
	_code_edit.add_theme_font_size_override("font_size", 28)
	if _font != null:
		_code_edit.add_theme_font_override("font", _font)
	_code_edit.text_changed.connect(_on_code_changed)
	_lobby_panel.add_child(_code_edit)

	_clear_btn = _button("ClearBtn", "x", 18)
	_clear_btn.position = CoopLayoutRes.LOBBY_CODE_CLEAR.position
	_clear_btn.size = CoopLayoutRes.LOBBY_CODE_CLEAR.size
	_clear_btn.pressed.connect(_clear_code)
	_lobby_panel.add_child(_clear_btn)

	for i in range(0, 10):
		var key := _button("Key%d" % i, str(i), 20)
		key.position = CoopLayoutRes.key_rect(i).position
		key.size = CoopLayoutRes.key_rect(i).size
		key.pressed.connect(_append_digit.bind(str(i)))
		_lobby_panel.add_child(key)
		_key_buttons[str(i)] = key

	_action_btn = _button("ActionBtn", _txt("enter", "加入房间"), 18)
	_action_btn.position = CoopLayoutRes.LOBBY_ACTION.position
	_action_btn.size = CoopLayoutRes.LOBBY_ACTION.size
	_action_btn.pressed.connect(_on_action_pressed)
	_lobby_panel.add_child(_action_btn)
	_render_rooms()


func _build_room_panel() -> void:
	_room_preview_btn = _button("RoomPreviewBtn", "", 14)
	_room_preview_btn.position = CoopLayoutRes.ROOM_PREVIEW.position
	_room_preview_btn.size = CoopLayoutRes.ROOM_PREVIEW.size
	_room_preview_btn.pressed.connect(_open_map_select)
	_room_panel.add_child(_room_preview_btn)

	_room_thumb = MapThumbRes.new()
	_room_thumb.name = "RoomMapThumb"
	_room_thumb.position = Vector2(6, 6)
	_room_thumb.size = Vector2(CoopLayoutRes.ROOM_PREVIEW.size.x - 12.0,
		CoopLayoutRes.ROOM_PREVIEW.size.y - 60.0)
	_room_preview_btn.add_child(_room_thumb)

	_room_map_name = _label("RoomMapName", "", 22, UiStyleRes.text())
	_room_map_name.position = Vector2(12, CoopLayoutRes.ROOM_PREVIEW.size.y - 58.0)
	_room_map_name.size = Vector2(CoopLayoutRes.ROOM_PREVIEW.size.x - 24.0, 30.0)
	_room_preview_btn.add_child(_room_map_name)

	_room_map_hint = _label("RoomMapHint", "", 13, UiStyleRes.text_faint())
	_room_map_hint.position = Vector2(12, CoopLayoutRes.ROOM_PREVIEW.size.y - 24.0)
	_room_map_hint.size = Vector2(CoopLayoutRes.ROOM_PREVIEW.size.x - 24.0, 20.0)
	_room_preview_btn.add_child(_room_map_hint)

	# 房间码盖在缩略图左上角（分享 / 核对用；加描边，压在地图上也看得清）。
	_room_code_label = _label("RoomCode", "", 16, UiStyleRes.accent())
	_room_code_label.position = Vector2(36, 36)
	_room_code_label.size = Vector2(260, 26)
	_room_code_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_room_code_label.add_theme_constant_override("outline_size", 4)
	_room_preview_btn.add_child(_room_code_label)

	var desc_bg := Panel.new()
	desc_bg.name = "RoomDescBg"
	desc_bg.position = CoopLayoutRes.ROOM_DESC.position
	desc_bg.size = CoopLayoutRes.ROOM_DESC.size
	desc_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_bg.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line_soft()))
	_room_panel.add_child(desc_bg)

	_room_desc = _label("RoomDesc", "", 15, UiStyleRes.text())
	_room_desc.position = desc_bg.position + Vector2(14, 12)
	_room_desc.size = desc_bg.size - Vector2(28, 24)
	_room_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_room_panel.add_child(_room_desc)

	_room_action_btn = _button("RoomActionBtn", _txt("ready", "准备"), 20)
	_room_action_btn.position = CoopLayoutRes.ROOM_ACTION.position
	_room_action_btn.size = CoopLayoutRes.ROOM_ACTION.size
	_room_action_btn.pressed.connect(_on_room_action_pressed)
	_room_panel.add_child(_room_action_btn)


func _build_map_panel() -> void:
	var title := _label("MapTitle", _txt("select_map", "选择地图"), 20, UiStyleRes.accent())
	title.position = CoopLayoutRes.MAP_HEADER.position
	title.size = CoopLayoutRes.MAP_HEADER.size
	_map_panel.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.name = "MapList"
	scroll.position = CoopLayoutRes.MAP_SCROLL.position
	scroll.size = CoopLayoutRes.MAP_SCROLL.size
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_map_panel.add_child(scroll)

	_map_grid = GridContainer.new()
	_map_grid.name = "MapGrid"
	_map_grid.columns = CoopLayoutRes.MAP_CARD_COLS
	_map_grid.add_theme_constant_override("h_separation", int(CoopLayoutRes.MAP_CARD_GAP))
	_map_grid.add_theme_constant_override("v_separation", int(CoopLayoutRes.MAP_CARD_GAP))
	scroll.add_child(_map_grid)

	for item in _entries:
		var card = MapCardRes.new()
		var e: Dictionary = item
		card.setup(cfg, e, _map_data_for(e), _font)
		card.pressed.connect(_on_map_card_pressed.bind(e))
		_map_grid.add_child(card)
		_map_cards.append(card)


# ------------------------------------------------------------------
# 状态 / 动效
# ------------------------------------------------------------------

func _set_state(next: String, animate: bool = true) -> void:
	if next == _state:
		_update_action()
		return
	_state = next
	if next == STATE_LOBBY:
		_start_room_timer()
	else:
		_stop_room_timer()
	_update_action()
	_update_seats()
	_move_back_btn(animate)
	_apply_input_filters(next)
	if not animate or _anim_sec <= 0.0 or not ThemeRes.animations_enabled():
		_set_state_instant(next)
		return
	# 动画期间三块面板都先可见（否则滑出中的那一块会被立刻隐藏）。
	_lobby_panel.visible = true
	_room_panel.visible = true
	_map_panel.visible = true
	_self_seat.visible = true
	_mate_seat.visible = true
	if _state_tween != null and _state_tween.is_valid():
		_state_tween.kill()
	_state_tween = create_tween()
	var tw := _state_tween
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween_panel(tw, _lobby_panel, _lobby_rect_for(next))
	_tween_panel(tw, _room_panel, _room_rect_for(next))
	_tween_panel(tw, _map_panel, _map_rect_for(next))
	_tween_seat(tw, _self_seat, _seat_rect_for(next, CoopLayoutRes.SELF_SEAT))
	_tween_seat(tw, _mate_seat, _seat_rect_for(next, CoopLayoutRes.MATE_SEAT))
	tw.chain().tween_callback(_finish_state.bind(next))


func _finish_state(next: String) -> void:
	if _state != next:
		return
	_apply_input_filters(next)
	_sync_panel_visibility()


func _set_state_instant(next: String) -> void:
	if _state_tween != null and _state_tween.is_valid():
		_state_tween.kill()
	_state_tween = null
	_lobby_panel.position = _local_pos(_lobby_rect_for(next).position)
	_lobby_panel.modulate.a = 1.0 if next == STATE_LOBBY else 0.0
	_room_panel.position = _local_pos(_room_rect_for(next).position)
	_room_panel.modulate.a = 0.0 if next == STATE_LOBBY else 1.0
	_map_panel.position = _local_pos(_map_rect_for(next).position)
	_map_panel.modulate.a = 1.0 if next == STATE_MAP else 0.0
	_self_seat.position = _local_pos(_seat_rect_for(next, CoopLayoutRes.SELF_SEAT).position)
	_self_seat.modulate.a = 0.0 if next == STATE_MAP else 1.0
	_mate_seat.position = _local_pos(_seat_rect_for(next, CoopLayoutRes.MATE_SEAT).position)
	_mate_seat.modulate.a = 0.0 if next == STATE_MAP else 1.0
	_apply_input_filters(next)
	_sync_panel_visibility()


func _tween_panel(tw: Tween, panel: Panel, target: Rect2) -> void:
	tw.tween_property(panel, "position", _local_pos(target.position), _anim_sec)
	tw.tween_property(panel, "modulate:a", 1.0 if target.position.x >= -1.0 and target.position.x <= _screen_w() + 1.0 else 0.0,
		_anim_sec)


func _tween_seat(tw: Tween, seat, target: Rect2) -> void:
	tw.tween_property(seat, "position", _local_pos(target.position), _anim_sec)
	tw.tween_property(seat, "modulate:a", 0.0 if target.position.x < 0.0 else 1.0, _anim_sec)


func _apply_input_filters(next: String) -> void:
	_lobby_panel.mouse_filter = Control.MOUSE_FILTER_STOP if next == STATE_LOBBY else Control.MOUSE_FILTER_IGNORE
	_room_panel.mouse_filter = Control.MOUSE_FILTER_STOP if next != STATE_LOBBY else Control.MOUSE_FILTER_IGNORE
	_map_panel.mouse_filter = Control.MOUSE_FILTER_STOP if next == STATE_MAP else Control.MOUSE_FILTER_IGNORE


func _sync_panel_visibility() -> void:
	_lobby_panel.visible = _state == STATE_LOBBY
	_room_panel.visible = _state != STATE_LOBBY
	_map_panel.visible = _state == STATE_MAP
	_self_seat.visible = _state != STATE_MAP
	_mate_seat.visible = _state != STATE_MAP


func _move_back_btn(animate: bool) -> void:
	if _back_btn == null or not is_instance_valid(_back_btn):
		return
	if not _back_ready:
		_init_back_btn()
	var target := _back_rect_for(_state)
	if not animate or _anim_sec <= 0.0 or not ThemeRes.animations_enabled():
		_back_btn.position = _local_pos(target.position)
		return
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_back_btn, "position", _local_pos(target.position), _anim_sec)


## 托管 `menu_secondary_panel` 的返回按钮：状态切换时把它从右上来回左上。
func attach_back_button(btn: Button) -> void:
	_back_btn = btn
	_init_back_btn.call_deferred()


func _init_back_btn() -> void:
	if _back_btn == null or not is_instance_valid(_back_btn):
		return
	_back_btn.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	_back_btn.position = _local_pos(_back_rect_for(_state).position)
	_back_btn.size = CoopLayoutRes.BACK_RIGHT.size
	_back_ready = true


## 返回按钮被按下：面板先问这里。
##   · MAP  → 放弃改图，回房间（返回 true = 面板不要收起）
##   · ROOM → 退出房间，回大厅（返回 true）
##   · LOBBY → 返回 false，让面板收起
func handle_back() -> bool:
	if _state == STATE_MAP:
		_cancel_map_select()
		return true
	if _state == STATE_ROOM:
		_leave_room()
		return true
	return false


# ------------------------------------------------------------------
# 房间列表（HTTP /rooms）
# ------------------------------------------------------------------

func _refresh_rooms() -> void:
	if _state != STATE_LOBBY:
		return
	if not is_inside_tree():
		_refresh_rooms.call_deferred()
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "RoomListHttp"
		_http.timeout = 8.0
		# Android 上主线程 `HTTPClient` 偶发卡死 / 超时；房间列表走后台线程更稳。
		_http.use_threads = true
		_http.request_completed.connect(_on_rooms_completed)
		add_child(_http)
	if not _http.is_inside_tree():
		_refresh_rooms.call_deferred()
		return
	if _http_busy:
		return
	var url := _http_url()
	if url == "":
		_set_status("未配置中继地址")
		_rooms = []
		_render_rooms()
		return
	_http_busy = true
	var err := _http.request(url)
	if err != OK:
		_http_busy = false
		_set_status("房间列表获取失败（可直接输码）")
		_render_rooms()


func _http_url() -> String:
	return RoomDirectoryRes.http_url_from_ws(_relay_url())


func _start_room_timer() -> void:
	if not is_inside_tree():
		_start_room_timer.call_deferred()
		return
	if _room_timer == null:
		_room_timer = Timer.new()
		_room_timer.name = "RoomRefreshTimer"
		_room_timer.one_shot = false
		_room_timer.timeout.connect(_refresh_rooms)
		add_child(_room_timer)
	var sec := 2.0
	if cfg != null:
		sec = maxf(1.0, float(cfg.num("coop.lobby.room_refresh_sec", 2.0)))
	_room_timer.wait_time = sec
	if _room_timer.is_inside_tree():
		_room_timer.start()
	else:
		_room_timer.start.call_deferred()


func _stop_room_timer() -> void:
	if _room_timer != null:
		_room_timer.stop()


func _on_rooms_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	_http_busy = false
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		_set_status("房间列表获取失败（可直接输码）")
		_render_rooms()
		return
	_rooms = RoomDirectoryRes.parse_rooms(body.get_string_from_utf8())
	_render_rooms()
	_update_action()


func _render_rooms() -> void:
	if _room_list_body == null:
		return
	for child in _room_list_body.get_children():
		child.queue_free()
	if _rooms.is_empty():
		var e := _label("RoomEmpty", _txt("empty_rooms", "暂无房间，输入房间码创建"),
			14, UiStyleRes.text_faint())
		e.custom_minimum_size = Vector2(0, 40)
		_room_list_body.add_child(e)
	else:
		for item in _rooms:
			var d: Dictionary = item
			var row := Button.new()
			row.name = "RoomRow_%s" % String(d["code"])
			row.text = "%s    %s" % [String(d["code"]), String(d["label"])]
			row.focus_mode = Control.FOCUS_NONE
			row.custom_minimum_size = Vector2(0, CoopLayoutRes.ROOM_ROW_H)
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.alignment = HORIZONTAL_ALIGNMENT_LEFT
			row.disabled = not bool(d["joinable"])
			_row_style(row, bool(d["joinable"]))
			if _font != null:
				row.add_theme_font_override("font", _font)
			row.add_theme_font_size_override("font_size", 15)
			if bool(d["joinable"]):
				row.pressed.connect(_fill_code.bind(String(d["code"])))
			_room_list_body.add_child(row)
	_list_title.text = "%s  %d" % [_txt("room_list", "房间列表"), _rooms.size()]


func _row_style(b: Button, joinable: bool) -> void:
	var n := MenuThemeRes.button_normal() if joinable else MenuThemeRes.button_disabled()
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear() if joinable else n)
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched() if joinable else n)
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", MenuThemeRes.text_normal() if joinable else MenuThemeRes.text_disabled())


# ------------------------------------------------------------------
# 房间码 / 键盘 / 动作按钮
# ------------------------------------------------------------------

func _on_code_changed(_text: String) -> void:
	var filtered := ""
	for i in _code_edit.text.length():
		var c := _code_edit.text.substr(i, 1)
		if c >= "0" and c <= "9":
			filtered += c
	if filtered != _code_edit.text:
		_code_edit.text = filtered
		_code_edit.caret_column = filtered.length()
	_update_action()
	if _code().length() == 6 and _state == STATE_LOBBY:
		_refresh_rooms()


func _append_digit(d: String) -> void:
	if _code_edit.text.length() >= 6:
		return
	_code_edit.text += d
	_code_edit.caret_column = _code_edit.text.length()
	_update_action()
	if _code().length() == 6 and _state == STATE_LOBBY:
		_refresh_rooms()


func _clear_code() -> void:
	_code_edit.text = ""
	_update_action()


func _fill_code(code: String) -> void:
	_code_edit.text = code
	_code_edit.caret_column = code.length()
	_update_action()
	if code.length() == 6 and _state == STATE_LOBBY:
		_refresh_rooms()


func _code() -> String:
	return _code_edit.text.strip_edges()


func _room_for_code() -> Dictionary:
	return RoomDirectoryRes.find_room(_rooms, _code())


func _update_action() -> void:
	if _action_btn == null:
		return
	if _state == STATE_MAP:
		_update_room_action()
		return
	if _state == STATE_ROOM:
		_update_room_action()
		return
	var code := _code()
	if code.length() < 6:
		# 2026.10.20：没输满 6 位**不显示任何字**，也不许点。
		_action_btn.text = ""
		_action_btn.disabled = true
		return
	var room := _room_for_code()
	if room.is_empty():
		_action_btn.text = _txt("create", "创建房间")
		_action_btn.disabled = false
	elif bool(room.get("joinable", false)):
		_action_btn.text = _txt("enter", "加入房间")
		_action_btn.disabled = false
	elif String(room.get("status", "")) == "playing":
		_action_btn.text = _txt("playing", "对局中")
		_action_btn.disabled = true
	else:
		_action_btn.text = _txt("room_full", "房间已满")
		_action_btn.disabled = true


func _on_action_pressed() -> void:
	if _state == STATE_MAP:
		_apply_pending_map()
		return
	if _state == STATE_ROOM:
		_on_room_action_pressed()
		return
	var code := _code()
	if code.length() < 6:
		return
	if _room_for_code().is_empty():
		_begin_join_or_create("create", code)
	else:
		_begin_join_or_create("join", code)


func _begin_join_or_create(kind: String, code: String) -> void:
	_action_btn.disabled = true
	_pending_action = {"kind": kind, "code": code}
	_set_status("连接服务器…")
	if not _ensure_lobby():
		_pending_action = {}
		_set_status("无法连接中继")
		_update_action()
		return
	if _lobby != null and _is_connected():
		_send_pending_action()


func _ensure_lobby() -> bool:
	if _lobby != null:
		return true
	if cfg == null:
		return false
	_last_lobby_error = ""
	_transport = RelayTransportRes.new()
	_lobby = LobbyRes.new()
	_lobby.setup(cfg, _transport, String(cfg.str_val("net.build", ProtocolRes.BUILD)))
	_lobby.connected.connect(_on_lobby_connected)
	_lobby.room_state_changed.connect(_on_room_state)
	_lobby.room_config_changed.connect(_on_room_config)
	_lobby.error.connect(_on_lobby_error)
	_lobby.closed.connect(_on_lobby_closed)
	_lobby.guest_started.connect(_on_guest_started)
	_transport.error.connect(_on_transport_error)
	_lobby.connect_to(_relay_url())
	return true


func _is_connected() -> bool:
	return _transport != null and _transport.is_open()


func _send_pending_action() -> void:
	if _lobby == null or _pending_action.is_empty():
		return
	var kind := String(_pending_action.get("kind", ""))
	var code := String(_pending_action.get("code", ""))
	_pending_action = {}
	if kind == "create":
		_lobby.create_room(code, "player")
	else:
		_lobby.join_room(code, "player")


func _on_lobby_connected() -> void:
	_set_status("已连接")
	_send_pending_action()


func _on_transport_error(message: String) -> void:
	_pending_action = {}
	_set_status("连接失败：%s" % message)
	_update_action()


func _on_lobby_error(code: String, msg: String) -> void:
	_pending_action = {}
	_last_lobby_error = _error_text(code, msg)
	_set_status("错误：%s" % _last_lobby_error)
	if code == "no_room" or code == "room_full" or code == "code_taken":
		_refresh_rooms()
	_update_action()


func _on_lobby_closed(reason: String) -> void:
	if _in_game:
		return
	_reset_network()
	var msg := _last_lobby_error
	_last_lobby_error = ""
	if msg == "" and (reason.contains("build") or reason.contains("1008")):
		msg = "服务端版本不匹配（需部署 coop-m13.1）"
	_set_status(msg if msg != "" else "连接已断开")
	_set_state(STATE_LOBBY, false)
	_update_seats()
	_refresh_rooms()


func _error_text(code: String, msg: String) -> String:
	match code:
		"no_room":
			return "房间不存在"
		"room_full":
			return "房间已满"
		"code_taken":
			return "房间码已被占用"
		"code":
			return "房间码不合法"
		"start":
			return "队友还没准备"
		"build":
			return "服务端版本不匹配（需部署 coop-m13.1）"
		_:
			return msg if msg != "" else code


# ------------------------------------------------------------------
# 房间状态
# ------------------------------------------------------------------

func _on_room_state(state: Dictionary) -> void:
	if _state == STATE_LOBBY and bool(state.get("host", false)):
		# 自己已经是房主：进入房间面板（客机加入时 state 也会到）。
		_set_state(STATE_ROOM)
	# ★ 服务器的 room_state 是唯一真相：后门的 guest 从不上报服务器，
	#   所以任何一次 room_state 都表示「本地那份伪造已被真实状态覆盖」。
	_fake_guest = false
	_update_seats()
	_update_room_preview(_current_entry)
	_update_room_action()
	if _is_host() and bool(state.get("guest", false)):
		_broadcast_room_cfg()


## ★★ 调试后门：把本机的房间状态伪造成「队友已加入且已准备」。
##   服务器不知道这件事；只要没人真的加入，它就不会用 room_state 覆盖这里。
##   返回 true 表示这次真的伪造了（已经有人 / 不是房主时返回 false）。
func _debug_fake_guest() -> bool:
	if _lobby == null or not _is_host():
		return false
	if bool(_lobby.room.get("guest", false)):
		return false        # 幂等：已经有队友（真的或已伪造过）就不重复加
	_lobby.room["guest"] = true
	_lobby.room["ready_guest"] = true
	_fake_guest = true
	_update_seats()
	_update_room_action()
	print("[COOP] Ctrl+Q：已加入占位队友（仅本机，不经过服务器）")
	return true


func _on_room_config(config: Dictionary) -> void:
	if _is_host():
		return
	var e := CoopCatalogRes.find_entry(_entries, String(config.get("campaign", "")),
		String(config.get("level", "")))
	if e.is_empty():
		return
	_current_entry = e
	_update_room_preview(e)
	_update_room_action()


func _on_guest_started(payload: Dictionary, transport) -> void:
	_in_game = true
	# transport 已经交给 game_scene；大厅退出时不能再 close 它。
	_transport = null
	guest_started.emit(payload, transport)


func _update_seats() -> void:
	var host := _is_host()
	var guest := _lobby != null and bool(_lobby.room.get("guest", false))
	var ready_guest := _lobby != null and bool(_lobby.room.get("ready_guest", false))
	var role := "房主" if host else ("队友" if _lobby != null else "")
	_self_seat.set_seat(_txt("player", "player"), role, "已入房" if _lobby != null else "未入房", true)
	if _room_code_label != null:
		var code := String(_lobby.room_code()) if _lobby != null else ""
		_room_code_label.text = ("房间码 %s" % code) if code != "" else ""
	if guest:
		# 后门加进来的队友明确标成「占位队友」，与真联机的队友区分开。
		var guest_role := "占位队友" if _fake_guest else "队友"
		_mate_seat.set_seat(_txt("player", "player"), guest_role,
			"已准备" if ready_guest else "未准备", true, ready_guest)
	else:
		_mate_seat.set_seat("", "", "等待队友…", false)


func _is_host() -> bool:
	return _lobby != null and String(_lobby.my_role) == "host"


func _guest_ready() -> bool:
	return _lobby != null and bool(_lobby.room.get("ready_guest", false))


func _update_room_action() -> void:
	if _room_action_btn == null:
		return
	if _state == STATE_MAP:
		_room_action_btn.text = _txt("confirm", "确认")
		_room_action_btn.disabled = _pending_entry.is_empty()
		return
	var e := _current_entry if _state == STATE_ROOM else {}
	if e.is_empty():
		_room_action_btn.text = _txt("map_none", "无可用合作地图")
		_room_action_btn.disabled = true
		return
	if _is_host():
		if _lobby == null or not bool(_lobby.room.get("guest", false)):
			_room_action_btn.text = _txt("wait_guest", "等待队友加入")
			_room_action_btn.disabled = true
		elif _guest_ready():
			_room_action_btn.text = _txt("start", "开始")
			_room_action_btn.disabled = false
		else:
			_room_action_btn.text = _txt("wait_ready", "等待队友准备")
			_room_action_btn.disabled = true
	else:
		_room_action_btn.text = _txt("cancel_ready", "取消准备") if _guest_ready() else _txt("ready", "准备")
		_room_action_btn.disabled = false


func _on_room_action_pressed() -> void:
	if _state == STATE_MAP:
		_apply_pending_map()
		return
	if _is_host():
		_start_host()
	else:
		if _lobby != null:
			_lobby.ready(not _guest_ready())
			_room_action_btn.disabled = true


func _start_host() -> void:
	if _lobby == null or _current_entry.is_empty():
		return
	if not bool(_lobby.room.get("guest", false)) or not _guest_ready():
		return
	var campaign := String(_current_entry.get("campaign", ""))
	var level := String(_current_entry.get("level", ""))
	var t = _lobby.take_transport()
	if t == null:
		return
	_in_game = true
	# transport 已经交给 game_scene；大厅退出时不能再 close 它。
	_transport = null
	host_started.emit(campaign, level, t)


func _leave_room() -> void:
	if _lobby != null:
		_lobby.leave_room()
	_reset_network()
	_set_state(STATE_LOBBY, false)
	_update_seats()
	_update_room_action()
	_refresh_rooms()


func _reset_network() -> void:
	if _transport != null:
		_transport.close()
	_transport = null
	_lobby = null
	_pending_action = {}
	_fake_guest = false


# ------------------------------------------------------------------
# 地图目录 / 房间配置
# ------------------------------------------------------------------

func _load_catalog() -> void:
	_entries = CoopCatalogRes.entries(cfg)
	if not _entries.is_empty():
		_current_entry = _entries[0]


func _map_data_for(entry: Dictionary):
	var path := String(entry.get("map_path", ""))
	if path == "":
		return null
	if _map_cache.has(path):
		return _map_cache[path]
	var m = CoopCatalogRes.load_map(path, cfg)
	_map_cache[path] = m
	return m


func _update_room_preview(entry: Dictionary) -> void:
	if entry.is_empty():
		_room_thumb.visible = false
		_room_map_name.text = _txt("map_none", "无可用合作地图")
		_room_map_hint.text = ""
		_room_desc.text = ""
		return
	_room_thumb.visible = true
	_room_thumb.setup(cfg, _map_data_for(entry))
	_room_map_name.text = String(entry.get("map_name", ""))
	_room_map_hint.text = _txt("map_hint_host", "点击更换地图") if _is_host() \
		else _txt("map_hint_guest", "由房主选择地图")
	_room_desc.text = String(entry.get("desc", ""))
	# 客机也保持可交互：能悬停 / 长按 / 点击填灰，但 `_open_map_select()` 直接返回，
	# 所以点击没有任何逻辑。不能简单 `disabled=true` —— 触摸下会出现“灰填一半就退、
	# 之后再也点不动”的假死。
	_room_preview_btn.disabled = false
	FillButtonRes.set_grey(_room_preview_btn, not _is_host())


func _broadcast_room_cfg() -> void:
	if _lobby == null or not _is_host() or _current_entry.is_empty():
		return
	if not bool(_lobby.room.get("guest", false)):
		return
	_lobby.send_room_config({
		"campaign": String(_current_entry.get("campaign", "")),
		"level": String(_current_entry.get("level", "")),
		"map_id": String(_current_entry.get("map_id", "")),
		"map_name": String(_current_entry.get("map_name", "")),
		"summary": String(_current_entry.get("desc", "")),
	})


func _open_map_select() -> void:
	if not _is_host() or _current_entry.is_empty():
		return
	_pending_entry = _current_entry
	_set_state(STATE_MAP)
	_refresh_map_selection()
	_update_room_preview(_pending_entry)


func _on_map_card_pressed(entry: Dictionary) -> void:
	_pending_entry = entry
	_refresh_map_selection()
	_update_room_preview(_pending_entry)
	_update_action()


func _refresh_map_selection() -> void:
	for card in _map_cards:
		var e: Dictionary = card.entry()
		var same := String(e.get("campaign", "")) == String(_pending_entry.get("campaign", "")) \
			and String(e.get("level", "")) == String(_pending_entry.get("level", ""))
		card.set_selected(same)


func _apply_pending_map() -> void:
	if _pending_entry.is_empty():
		return
	_current_entry = _pending_entry
	_pending_entry = {}
	_refresh_map_selection()
	_update_room_preview(_current_entry)
	_broadcast_room_cfg()
	_set_state(STATE_ROOM)


func _cancel_map_select() -> void:
	_pending_entry = {}
	_refresh_map_selection()
	_update_room_preview(_current_entry)
	_set_state(STATE_ROOM)


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

func _txt(key: String, fallback: String) -> String:
	if cfg == null:
		return fallback
	return String(cfg.str_val("coop.lobby." + key, fallback))


func _set_status(text: String) -> void:
	if _lobby_status != null:
		_lobby_status.text = text


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


func _button(node_name: String, text: String, fs: int) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", fs)
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


func _exit_tree() -> void:
	if _http != null:
		_http.cancel_request()
	if not _in_game and _lobby != null:
		_lobby.leave_room()
	_reset_network()
