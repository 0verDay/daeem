## relay_transport.gd —— 用 Godot 的 WebSocketPeer 连 M12.3 的 Python 中继。
##
## ★ 只实现 `net/transport.gd` 的接口；会话 / 协议 / 逻辑都不知道“中继”长什么样。
## ★ WebSocket 只有可靠通道：`send_unreliable()` 先退回 `send_text()`。
## ★ 快照可能很大：把入站 / 出站缓冲调大（默认 64 KiB 对 1000 单位不够）。
## ★ `poll()` 必须由场景每帧调用；它负责握手推进、收包、发 connected/closed。
extends "res://net/transport.gd"

## 8 MiB：给全量快照留余量；中继端 max_message 也是 16 MiB。
const BUFFER_BYTES := 8 * 1024 * 1024

var _ws: WebSocketPeer = null
var _url: String = ""
var _connected_sent: bool = false
var _closed_sent: bool = false
var _last_error: String = ""


func connect_to(url: String) -> void:
	_url = url.strip_edges()
	if _url == "":
		_last_error = "empty url"
		error.emit(_last_error)
		return
	if _ws != null:
		_ws.close()
		_ws = null
	_connected_sent = false
	_closed_sent = false
	_last_error = ""
	_ws = WebSocketPeer.new()
	_ws.set_inbound_buffer_size(BUFFER_BYTES)
	_ws.set_outbound_buffer_size(BUFFER_BYTES)
	var err: int = _ws.connect_to_url(_url)
	if err != OK:
		_last_error = "connect_to_url: %s" % error_string(err)
		error.emit(_last_error)


func poll() -> void:
	if _ws == null:
		return
	# Godot 4.7: WebSocketPeer.poll() returns void; state/availability carry the result.
	_ws.poll()
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _connected_sent:
				_connected_sent = true
				connected.emit()
			while _ws.get_available_packet_count() > 0:
				var packet := _ws.get_packet()
				message.emit(packet.get_string_from_utf8())
		WebSocketPeer.STATE_CLOSED:
			var reason := "closed"
			var code := _ws.get_close_code()
			var why := _ws.get_close_reason()
			if code > 0:
				reason = "closed %d %s" % [code, why]
			_finish(reason)


func send_text(text: String) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		_last_error = "not open"
		error.emit(_last_error)
		return
	var err: int = _ws.send_text(text)
	if err != OK:
		_last_error = "send_text: %s" % error_string(err)
		error.emit(_last_error)


## WebSocket 没有不可靠通道：快照也走可靠发送（丢了不会重传，但 TCP 保证顺序）。
func send_unreliable(text: String) -> void:
	send_text(text)


## 出站缓冲里还积着多少字节；会话层用它做快照背压（见 host_session.send_snapshot）。
func buffered_amount() -> int:
	if _ws == null:
		return 0
	return _ws.get_current_outbound_buffered_amount()


func close() -> void:
	if _ws == null:
		return
	_ws.close()
	# 真正的 closed 信号等下一次 poll() 读到 STATE_CLOSED；调用方不要假设立刻断开。


func is_open() -> bool:
	return _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN


func last_error() -> String:
	return _last_error


func _finish(reason: String) -> void:
	if _closed_sent:
		return
	_closed_sent = true
	_last_error = reason
	closed.emit(reason)
