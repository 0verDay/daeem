## lobby.gd —— 合作大厅的**会话**（房间 / 准备 / 开局），不画界面。
##
## 它只认 `transport`（M12.3 的 RelayTransport）和 `protocol.gd` 的信封；
## 建房 / 加入 / 准备 / 收 `start` 都是四五个字段，真正的 UI 在 `view/coop_lobby.gd`。
##
## ★ 开局的交接：收到 `start`（客机）或房主按下开始（`take_transport()`）之后，
##   本对象把 transport 的 `message` 处理器断开、把通道交给 `host_session` /
##   `client_session`。大厅不再碰这条连接。
extends RefCounted

const ProtocolRes = preload("res://net/protocol.gd")

signal connected
signal room_state_changed(state: Dictionary)
signal guest_started(payload: Dictionary, transport)
signal error(code: String, msg: String)
signal closed(reason: String)

var cfg = null
var transport = null
var build: String = ProtocolRes.BUILD
var room: Dictionary = {}
var my_role: String = ""
var _seq: int = 0
var _hello_ok: bool = false
var _released: bool = false


func setup(p_cfg, p_transport, p_build: String = ProtocolRes.BUILD) -> void:
	cfg = p_cfg
	transport = p_transport
	build = p_build
	_released = false
	if transport == null:
		return
	if not transport.message.is_connected(_on_message):
		transport.message.connect(_on_message)
	if not transport.connected.is_connected(_on_transport_connected):
		transport.connected.connect(_on_transport_connected)
	if not transport.closed.is_connected(_on_transport_closed):
		transport.closed.connect(_on_transport_closed)


func connect_to(url: String) -> void:
	if transport == null:
		error.emit("transport", "没有传输层")
		return
	transport.connect_to(url)


func poll() -> void:
	if transport != null:
		transport.poll()


func create_room(code: String = "", name: String = "host") -> void:
	my_role = "host"
	_send("create_room", {"code": code.strip_edges().to_upper(), "name": name})


func join_room(code: String, name: String = "guest") -> void:
	my_role = "guest"
	_send("join_room", {"code": code.strip_edges().to_upper(), "name": name})


func ready() -> void:
	_send("ready", {})


func room_code() -> String:
	return String(room.get("code", ""))


func is_ready() -> bool:
	return bool(room.get("ready_host", false)) and bool(room.get("ready_guest", false))


func has_guest() -> bool:
	return bool(room.get("guest", false))


## 房主按下「开始」：把 transport 交出去，由 game_scene 建 HostSession 并发送 start。
func take_transport():
	if transport == null:
		return null
	_released = true
	if transport.message.is_connected(_on_message):
		transport.message.disconnect(_on_message)
	if transport.closed.is_connected(_on_transport_closed):
		transport.closed.disconnect(_on_transport_closed)
	var t = transport
	transport = null
	return t


func _send(t: String, body: Dictionary) -> void:
	if transport == null:
		error.emit("transport", "连接还没建立")
		return
	_seq += 1
	transport.send_text(ProtocolRes.encode(ProtocolRes.make(t, _seq, body)))


func _on_transport_connected() -> void:
	if _hello_ok:
		return
	_seq += 1
	transport.send_text(ProtocolRes.encode(ProtocolRes.make("hello", _seq, {
		"build": build,
		"name": "player",
	})))


func _on_transport_closed(reason: String) -> void:
	if not _released:
		closed.emit(reason)


func _on_message(text: String) -> void:
	var res: Dictionary = ProtocolRes.decode(text)
	if not bool(res.get("ok", false)):
		error.emit("protocol", String(res.get("error", "protocol")))
		return
	var msg: Dictionary = res["msg"]
	var t := String(msg.get("t", ""))
	var body: Dictionary = msg.get("body", {})
	match t:
		"hello":
			_hello_ok = true
			connected.emit()
		"room_state":
			room = body.duplicate(true)
			room_state_changed.emit(room)
		"start":
			# Guest: the host is starting; hand the live transport to the game scene.
			var t2 = take_transport()
			guest_started.emit(body, t2)
		"bye":
			closed.emit(String(body.get("reason", "left")))
		"err":
			error.emit(String(body.get("code", "err")), String(body.get("msg", "")))
		_:
			pass
