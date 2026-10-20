## test_relay_transport.gd —— M12.3：Godot WebSocketPeer ↔ Python 中继。
##
## 自包含：测试自己用 OS.create_process 起 server/daeem_relay.py（固定测试端口），
## 用完 kill。没有 Python / 端口被占时跳过，不把“环境没装”算成产品失败。
extends "res://tests/test_case.gd"

const RelayTransportRes = preload("res://net/relay_transport.gd")

const PORT := 8773
const BUILD := "coop-m13.1"
const ROOM := "123456"

var _host_msgs: Array = []
var _guest_msgs: Array = []
var _host_closed: Array = []
var _guest_closed: Array = []

func _initialize() -> void:
	_case_name = "test_relay_transport"
	_run()


func _run() -> void:
	var script := ProjectSettings.globalize_path("res://server/daeem_relay.py")
	var pid := OS.create_process("python", [script, "--host", "127.0.0.1", "--port", str(PORT)], false)
	if pid <= 0:
		pid = OS.create_process("python3", [script, "--host", "127.0.0.1", "--port", str(PORT)], false)
	if pid <= 0:
		print("[CASE] %s -> SKIP（没有 python，或进程起不来）" % _case_name)
		quit(0)
		return
	OS.delay_msec(900)

	var host: RelayTransportRes = RelayTransportRes.new()
	var guest: RelayTransportRes = RelayTransportRes.new()
	host.message.connect(_on_host_message)
	guest.message.connect(_on_guest_message)
	host.closed.connect(_on_host_closed)
	guest.closed.connect(_on_guest_closed)
	var url := "ws://127.0.0.1:%d/ws" % PORT
	host.connect_to(url)
	guest.connect_to(url)

	await _pump(host, guest, 90)
	ok(host.is_open(), "★ RelayTransport 连上中继（host）")
	ok(guest.is_open(), "★ RelayTransport 连上中继（guest）")
	ok(host.buffered_amount() >= 0, "★ 出站缓冲读数可用（快照背压的前提）")
	if not host.is_open() or not guest.is_open():
		_kill(pid)
		quit(1)
		return

	_send(host, 1, "hello", {"build": BUILD})
	_send(guest, 1, "hello", {"build": BUILD})
	await _pump(host, guest, 60)
	ok(_has_type(_host_msgs, "hello"), "host 收到 hello 回执")
	ok(_has_type(_guest_msgs, "hello"), "guest 收到 hello 回执")

	_send(host, 2, "create_room", {"code": ROOM})
	await _pump(host, guest, 60)
	ok(_has_type(_host_msgs, "room_state"), "★ host 建出房间")

	_send(guest, 2, "join_room", {"code": ROOM})
	await _pump(host, guest, 60)
	ok(_has_type(_guest_msgs, "room_state"), "★ guest 加入房间")
	ok(_has_type(_host_msgs, "room_state"), "host 收到客人加入的 room_state")

	_send(host, 3, "ready", {})
	_send(guest, 3, "ready", {})
	await _pump(host, guest, 60)
	_send(host, 4, "start", {"level_id": "02_twin_line"})
	await _pump(host, guest, 60)
	ok(_has_type(_guest_msgs, "start"), "★ start 经中继到达客机")

	_send(guest, 4, "cmd", {"by": "F2", "cmd": {"kind": "stop"}})
	await _pump(host, guest, 60)
	var cmd := _first_type(_host_msgs, "cmd")
	ok(not cmd.is_empty(), "★ cmd 经中继到达房主")
	if not cmd.is_empty():
		eq(String((cmd["body"] as Dictionary).get("by", "")), "F2", "cmd.by 原样到达")

	_send(host, 5, "snap", {"snap": {"time": 1.0}})
	await _pump(host, guest, 60)
	var snap := _first_type(_guest_msgs, "snap")
	ok(not snap.is_empty(), "★ snap 经中继到达客机")
	if not snap.is_empty():
		eq(float((snap["body"] as Dictionary)["snap"]["time"]), 1.0, "snap.time 原样到达")

	host.close()
	await _pump(host, guest, 30)
	ok(_host_closed.size() > 0 or not host.is_open(), "★ host.close 后进入关闭态")

	_kill(pid)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _send(t, seq: int, kind: String, body: Dictionary) -> void:
	t.send_text(JSON.stringify({
		"v": 1, "t": kind, "seq": seq, "ts": 0, "body": body,
	}))


func _pump(a, b, frames: int) -> void:
	for i in frames:
		a.poll()
		b.poll()
		await process_frame


func _has_type(msgs: Array, kind: String) -> bool:
	return not _first_type(msgs, kind).is_empty()


func _first_type(msgs: Array, kind: String) -> Dictionary:
	for raw in msgs:
		var parsed: Variant = JSON.parse_string(String(raw))
		if typeof(parsed) == TYPE_DICTIONARY and String((parsed as Dictionary).get("t", "")) == kind:
			return parsed
	return {}


func _on_host_message(text: String) -> void:
	_host_msgs.append(text)


func _on_guest_message(text: String) -> void:
	_guest_msgs.append(text)


func _on_host_closed(reason: String) -> void:
	_host_closed.append(reason)


func _on_guest_closed(reason: String) -> void:
	_guest_closed.append(reason)


func _kill(pid: int) -> void:
	if pid > 0:
		OS.kill(pid)
