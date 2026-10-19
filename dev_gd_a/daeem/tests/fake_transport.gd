## fake_transport.gd —— M12.2 的「假连接」：两条端点互发字符串，不碰网络。
##
## 用法：
##   var a = FakeTransportRes.new()
##   var b = FakeTransportRes.new()
##   a.attach(b); b.attach(a)
##   a.send_text("...")      # 进 b.inbox
##   b.poll()                # 触发 b.message 信号
##
## ★ 它继承 `net/transport.gd`，所以 host_session / client_session 不需要知道
##   这是假的 —— M12.3 换成真实 WebSocket 时，会话代码一行不改。
extends "res://net/transport.gd"

var peer = null
var inbox: Array = []
var sent: Array = []
## 模拟 WebSocket 出站缓冲；测试背压时把它调大即可（默认 0 = 不阻塞）。
var buffered: int = 0


func attach(p) -> void:
	peer = p


func connect_to(_url: String) -> void:
	connected.emit()


func send_text(text: String) -> void:
	sent.append(text)
	if peer != null:
		peer.inbox.append(text)


func send_unreliable(text: String) -> void:
	# 假连接没有「丢包」：与可靠通道同一条队列（测试只关心内容与顺序）。
	send_text(text)


func buffered_amount() -> int:
	return buffered


func poll() -> void:
	var items: Array = inbox
	inbox = []
	for t in items:
		message.emit(String(t))


func close() -> void:
	closed.emit("closed")
