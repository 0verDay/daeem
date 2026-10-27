## test_coop_lobby.gd —— 合作会话（CoopSession）：建房 / 加入 / 地图同步 / 准备 / 开局。
##
## 真实中继（server/daeem_relay.py）+ 两个 CoopSession；不点像素、不截图。
## 没有 Python 时 SKIP。
extends "res://tests/test_case.gd"

const SessionRes = preload("res://view/coop_session.gd")
const ProtocolRes = preload("res://net/protocol.gd")

const PORT := 8774
const ROOM := "123456"

var _host_started: Array = []
var _guest_started: Array = []


func _initialize() -> void:
	_case_name = "test_coop_lobby"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var script := ProjectSettings.globalize_path("res://server/daeem_relay.py")
	var pid := OS.create_process("python", [script, "--host", "127.0.0.1", "--port", str(PORT),
		"--build", "coop-m13.1"], false)
	if pid <= 0:
		pid = OS.create_process("python3", [script, "--host", "127.0.0.1", "--port", str(PORT),
			"--build", "coop-m13.1"], false)
	if pid <= 0:
		print("[CASE] %s -> SKIP（没有 python）" % _case_name)
		quit(0)
		return
	OS.delay_msec(900)

	var host = SessionRes.new()
	var guest = SessionRes.new()
	root.add_child(host)
	root.add_child(guest)
	host.setup(cfg)
	guest.setup(cfg)
	host.host_started.connect(func(c, l, t): _host_started.append([c, l, t]))
	guest.guest_started.connect(func(p, t): _guest_started.append([p, t]))
	var url := "ws://127.0.0.1:%d/ws" % PORT
	host.set_relay_url(url)
	guest.set_relay_url(url)
	host.enter_room_mode()
	guest.enter_room_mode()
	await _wait(20)

	# 房主建房
	host.create_or_join(ROOM)
	await _wait_until(func(): return host.room_code() == ROOM, 6000)
	eq(host.room_code(), ROOM, "★ 房主建房拿到房间码")
	eq(host.room_role(), "host", "★ 房主角色")
	ok(not host.current_entry().is_empty(), "房主有默认合作地图")

	# 客机从列表看到房间并加入
	guest.refresh_rooms()
	await _wait_until(func(): return not guest.rooms().is_empty(), 6000)
	ok(not guest.rooms().is_empty(), "★ 客机从 /rooms 看到房间")
	guest.create_or_join(ROOM)
	await _wait_until(func(): return guest.room_code() == ROOM, 6000)
	eq(guest.room_code(), ROOM, "★ 客机加入同一房间")
	eq(guest.room_role(), "guest", "★ 客机角色")
	await _wait_until(func(): return host.guest_joined(), 4000)
	ok(host.guest_joined(), "★ 房主看到客机已加入")

	# 房主切图 → 客机同步
	var entries: Array = host.entries()
	if entries.size() >= 2:
		host.select_map(entries[1])
		await _wait_until(func(): return String(guest.current_entry().get("level", "")) \
			== String(entries[1].get("level", "")), 4000)
		eq(String(guest.current_entry().get("level", "")),
			String(entries[1].get("level", "")), "★ 客机收到房主的地图配置")
	else:
		ok(true, "（当前只有一张图，跳过切图同步）")

	# 客机准备 → 房主开始
	guest.set_ready(true)
	await _wait_until(func(): return host.guest_ready(), 4000)
	ok(host.guest_ready(), "★ 客机准备后房主看到 ready")
	host.start()
	await _wait_until(func(): return not _host_started.is_empty(), 4000)
	eq(_host_started.size(), 1, "★ 房主开局信号")
	if _host_started.is_empty():
		OS.kill(pid)
		quit(1)
		return
	var host_transport = _host_started[0][2]
	ok(host_transport != null, "★ 房主拿到已连接 transport")

	# 会话销毁不能关掉已交出去的连接
	host.queue_free()
	await _wait(3)
	ok(host_transport.is_open(), "★ 会话销毁后 transport 仍可用")

	var host_entry: Dictionary = guest.current_entry()
	var payload := {
		"campaign": String(host_entry.get("campaign", "")),
		"level_id": String(host_entry.get("level", "")),
		"level_data": {},
		"seats": ["F1", "F2"],
		"guest_seat": "F2",
	}
	host_transport.send_text(ProtocolRes.encode(ProtocolRes.make("start", 1, payload)))
	await _wait_until(func(): return not _guest_started.is_empty(), 6000)
	eq(_guest_started.size(), 1, "★ 客机收到 start")
	if not _guest_started.is_empty():
		var got: Dictionary = _guest_started[0][0]
		eq(String(got.get("level_id", "")), String(host_entry.get("level", "")),
			"★ start 带正确关卡")
		var gt = _guest_started[0][1]
		ok(gt != null, "★ 客机拿到已连接 transport")
		if gt != null:
			gt.close()

	host_transport.close()
	guest.queue_free()
	OS.kill(pid)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _wait_until(cond: Callable, timeout_ms: int) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()
