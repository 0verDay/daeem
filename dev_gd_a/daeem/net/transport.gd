## transport.gd —— 会话层看到的「一条双向文本通道」接口。
##
## ★★ 为什么要有这一层（用户拍板：以后想换 Steam P2P）：
##   `host_session` / `client_session` 只认下面四个方法 + 四个信号；
##   WebSocket 中继（M12.3）与 Steam P2P（以后）各自实现一份，协议 / 会话 / 逻辑都不改。
##
## ★ 可靠 / 不可靠分开：
##   · `send_text()` = 可靠有序（命令、start、bye）；
##   · `send_unreliable()` = 允许丢（快照；丢了等下一帧）。WebSocket 下两者都走同一条
##     TCP 流（可靠），Steam P2P 下快照走不可靠通道。
##
## ⚠️ 这是**接口 / 基类**，不是能直接用的网络实现：方法都是空实现。
##    M12.2 的测试用 `tests/fake_transport.gd`；M12.3 用 `net/relay_transport.gd`。
extends RefCounted

## 收到一条文本消息（已解码成字符串，未解析 JSON）。
signal message(text: String)
## 连接建立 / 断开 / 出错。
signal connected
signal closed(reason: String)
signal error(message: String)


## 连接到中继（WebSocket）或对端（Steam P2P / 直连）。
func connect_to(_url: String) -> void:
	pass


## 发送一条**可靠有序**的文本消息。
func send_text(_text: String) -> void:
	pass


## 发送一条**允许丢**的文本消息（快照）。
func send_unreliable(text: String) -> void:
	# 默认退回可靠通道：WebSocket 没有「不可靠」；Steam P2P 会覆盖它。
	send_text(text)


## 当前出站缓冲里还积着多少字节。
## ★ 默认 0 = 这个传输层不提供背压信息；WebSocket 会覆盖它。
##   会话层用它判断「这一帧快照还该不该发」（见 host_session.send_snapshot）。
func buffered_amount() -> int:
	return 0


## 驱动收包（Node 的 _process 或测试手动调用）。
func poll() -> void:
	pass


## 主动关闭。
func close() -> void:
	pass
