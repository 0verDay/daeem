## coop_session.gd —— 合作模式的会话 / 网络控制器（无绘制）。
##
## 从旧 `view/coop_lobby.gd` 抽出：房间列表、创建/加入、准备/开始、房主地图广播、
## AI 队友本地局。新 UI 的「合作过渡 / 房间 / 准备」三块面板只读这里的状态并发信号。
##
## ★ 不建任何 Control、不读字体；协议 / 中继 / 房间目录代码保持原样。
extends Node

signal rooms_changed(rooms: Array)
signal status_changed(text: String)
signal room_entered(role: String, code: String)
signal room_state_changed(state: Dictionary)
signal room_config_changed(entry: Dictionary)
signal host_started(campaign_id: String, level_id: String, transport)
signal guest_started(payload: Dictionary, transport)
signal solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary)
signal room_left

const LobbyRes = preload("res://net/lobby.gd")
const RelayTransportRes = preload("res://net/relay_transport.gd")
const ProtocolRes = preload("res://net/protocol.gd")
const RoomDirectoryRes = preload("res://net/room_directory.gd")
const CoopCatalogRes = preload("res://logic/coop_catalog.gd")

const MODE_IDLE := "idle"
const MODE_AI := "ai"
const MODE_ROOM := "room"

var cfg = null
var _entries: Array = []
var _current_entry: Dictionary = {}
var _map_cache: Dictionary = {}

var _mode: String = MODE_IDLE
var _lobby = null
var _transport = null
var _pending_action: Dictionary = {}
var _in_game: bool = false
var _room_entered: bool = false
var _fake_guest: bool = false
var _last_error: String = ""

var _http: HTTPRequest = null
var _http_busy: bool = false
var _rooms: Array = []
var _room_timer: Timer = null
var _relay_override: String = ""


func setup(p_cfg) -> void:
	cfg = p_cfg
	_entries = CoopCatalogRes.entries(cfg)
	if not _entries.is_empty():
		_current_entry = _entries[0]


func _process(_dt: float) -> void:
	if _lobby != null:
		_lobby.poll()


# ------------------------------------------------------------------
# 状态
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


func current_entry() -> Dictionary:
	return _current_entry


func mode() -> String:
	return _mode


func is_ai() -> bool:
	return _mode == MODE_AI


func is_host() -> bool:
	return _lobby != null and String(_lobby.my_role) == "host"


func is_guest() -> bool:
	return _lobby != null and String(_lobby.my_role) == "guest"


func room_code() -> String:
	return String(_lobby.room_code()) if _lobby != null else ""


func guest_joined() -> bool:
	return _lobby != null and bool(_lobby.room.get("guest", false))


func guest_ready() -> bool:
	return _lobby != null and bool(_lobby.room.get("ready_guest", false))


func my_ready() -> bool:
	return _lobby != null and bool(_lobby.room.get("ready_host", false))


func room_role() -> String:
	if is_host():
		return "host"
	if is_guest():
		return "guest"
	return ""


func status() -> String:
	return _last_error


func _status(text: String) -> void:
	status_changed.emit(text)


func set_relay_url(url: String) -> void:
	_relay_override = url.strip_edges()
	refresh_rooms()


func _relay_url() -> String:
	if _relay_override != "":
		return _relay_override
	return String(cfg.str_val("net.relay_url", "")) if cfg != null else ""


# ------------------------------------------------------------------
# 模式切换
# ------------------------------------------------------------------

func enter_ai_mode() -> void:
	_leave_room_internal(false)
	_stop_room_timer()
	_mode = MODE_AI
	_in_game = false
	_fake_guest = false
	if _current_entry.is_empty() and not _entries.is_empty():
		_current_entry = _entries[0]
	_status("本地 AI 队友")


func enter_room_mode() -> void:
	if _mode == MODE_AI:
		_leave_room_internal(false)
	_mode = MODE_ROOM
	_in_game = false
	_start_room_timer()
	refresh_rooms()


func leave_all() -> void:
	_leave_room_internal(false)
	_stop_room_timer()
	_mode = MODE_IDLE
	_in_game = false
	_current_entry = _entries[0] if not _entries.is_empty() else {}


func leave_room() -> void:
	var was_room := _mode == MODE_ROOM
	_leave_room_internal(true)
	_in_game = false
	if was_room:
		_mode = MODE_ROOM
		_start_room_timer()
		refresh_rooms()


# ------------------------------------------------------------------
# 地图
# ------------------------------------------------------------------

func select_map(entry: Dictionary) -> void:
	if entry.is_empty():
		return
	_current_entry = entry
	if _mode == MODE_ROOM and is_host():
		_broadcast_room_cfg()


func map_data_for(entry: Dictionary):
	var path := String(entry.get("map_path", ""))
	if path == "":
		return null
	if _map_cache.has(path):
		return _map_cache[path]
	var m = CoopCatalogRes.load_map(path, cfg)
	_map_cache[path] = m
	return m


# ------------------------------------------------------------------
# 房间列表
# ------------------------------------------------------------------

func refresh_rooms() -> void:
	if _mode != MODE_ROOM:
		return
	if not is_inside_tree():
		refresh_rooms.call_deferred()
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "RoomListHttp"
		_http.timeout = 8.0
		_http.use_threads = true
		_http.request_completed.connect(_on_rooms_completed)
		add_child(_http)
	if not _http.is_inside_tree():
		refresh_rooms.call_deferred()
		return
	if _http_busy:
		return
	var url := _http_url()
	if url == "":
		_rooms = []
		rooms_changed.emit(_rooms)
		status_changed.emit("未配置中继地址")
		return
	_http_busy = true
	var err := _http.request(url)
	if err != OK:
		_http_busy = false
		rooms_changed.emit(_rooms)
		status_changed.emit("房间列表获取失败（可直接输码）")


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
		_room_timer.timeout.connect(refresh_rooms)
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
		rooms_changed.emit(_rooms)
		status_changed.emit("房间列表获取失败（可直接输码）")
		return
	_rooms = RoomDirectoryRes.parse_rooms(body.get_string_from_utf8())
	rooms_changed.emit(_rooms)


func rooms() -> Array:
	return _rooms


# ------------------------------------------------------------------
# 创建 / 加入
# ------------------------------------------------------------------

func create_or_join(code: String) -> void:
	var c := code.strip_edges()
	if c.length() != 6:
		return
	var kind := "create"
	if not RoomDirectoryRes.find_room(_rooms, c).is_empty():
		kind = "join"
	_begin_join_or_create(kind, c)


func _begin_join_or_create(kind: String, code: String) -> void:
	_pending_action = {"kind": kind, "code": code}
	status_changed.emit("连接服务器…")
	if not _ensure_lobby():
		_pending_action = {}
		status_changed.emit("无法连接中继")
		return
	if _lobby != null and _is_connected():
		_send_pending_action()


func _ensure_lobby() -> bool:
	if _lobby != null:
		return true
	if cfg == null:
		return false
	_last_error = ""
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
	status_changed.emit("已连接")
	_send_pending_action()


func _on_transport_error(message: String) -> void:
	_pending_action = {}
	status_changed.emit("连接失败：%s" % message)


func _on_lobby_error(code: String, msg: String) -> void:
	_pending_action = {}
	_last_error = _error_text(code, msg)
	status_changed.emit("错误：%s" % _last_error)
	if code == "no_room" or code == "room_full" or code == "code_taken":
		refresh_rooms()


func _on_lobby_closed(reason: String) -> void:
	if _in_game:
		return
	_reset_network()
	var msg := _last_error
	_last_error = ""
	if msg == "" and (reason.contains("build") or reason.contains("1008")):
		msg = "服务端版本不匹配（需部署 coop-m13.1）"
	status_changed.emit(msg if msg != "" else "连接已断开")
	room_left.emit()
	refresh_rooms()


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
	_fake_guest = false
	if not _room_entered:
		_room_entered = true
		room_entered.emit(room_role(), room_code())
	room_state_changed.emit(state)
	if is_host() and bool(state.get("guest", false)):
		_broadcast_room_cfg()


func _on_room_config(config: Dictionary) -> void:
	if is_host():
		return
	var e := CoopCatalogRes.find_entry(_entries, String(config.get("campaign", "")),
		String(config.get("level", "")))
	if e.is_empty():
		return
	_current_entry = e
	room_config_changed.emit(e)


func _on_guest_started(payload: Dictionary, transport) -> void:
	_in_game = true
	_transport = null
	guest_started.emit(payload, transport)


func set_ready(on: bool) -> void:
	if _lobby == null or not is_guest():
		return
	_lobby.ready(on)
	room_state_changed.emit(_lobby.room)


func start() -> void:
	if _mode == MODE_AI:
		if _current_entry.is_empty():
			return
		_in_game = true
		solo_started.emit(String(_current_entry.get("campaign", "")),
			String(_current_entry.get("level", "")), {"difficulty": "normal"})
		return
	if is_host():
		_start_host()


func _start_host() -> void:
	if _lobby == null or _current_entry.is_empty():
		return
	if not guest_joined() or not guest_ready():
		return
	var campaign := String(_current_entry.get("campaign", ""))
	var level := String(_current_entry.get("level", ""))
	var t = _lobby.take_transport()
	if t == null:
		return
	_in_game = true
	_transport = null
	host_started.emit(campaign, level, t)


func _broadcast_room_cfg() -> void:
	if _lobby == null or not is_host() or _current_entry.is_empty():
		return
	if not guest_joined():
		return
	_lobby.send_room_config({
		"campaign": String(_current_entry.get("campaign", "")),
		"level": String(_current_entry.get("level", "")),
		"map_id": String(_current_entry.get("map_id", "")),
		"map_name": String(_current_entry.get("map_name", "")),
		"summary": String(_current_entry.get("desc", "")),
	})


func _leave_room_internal(emit: bool) -> void:
	if _lobby != null:
		_lobby.leave_room()
	_reset_network()
	_room_entered = false
	if emit:
		room_left.emit()


func _reset_network() -> void:
	if _transport != null:
		_transport.close()
	_transport = null
	_lobby = null
	_pending_action = {}
	_fake_guest = false


func debug_fake_guest() -> bool:
	if _lobby == null or not is_host():
		return false
	if bool(_lobby.room.get("guest", false)):
		return false
	_lobby.room["guest"] = true
	_lobby.room["ready_guest"] = true
	_fake_guest = true
	room_state_changed.emit(_lobby.room)
	return true


func _exit_tree() -> void:
	if not _in_game:
		_leave_room_internal(false)
	_stop_room_timer()
