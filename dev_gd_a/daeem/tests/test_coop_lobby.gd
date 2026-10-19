## test_coop_lobby.gd —— M12.4：真实中继上的大厅（建房 / 加入 / 准备 / 交接）。
##
## 不点像素：直接发 Button.pressed；不截图；没有 Python 时 SKIP。
extends "res://tests/test_case.gd"

const CoopLobbyRes = preload("res://view/coop_lobby.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const ProtocolRes = preload("res://net/protocol.gd")

const PORT := 8774
const ROOM := "CAMP23"

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
	var pid := OS.create_process("python", [script, "--host", "127.0.0.1", "--port", str(PORT)], false)
	if pid <= 0:
		pid = OS.create_process("python3", [script, "--host", "127.0.0.1", "--port", str(PORT)], false)
	if pid <= 0:
		print("[CASE] %s -> SKIP（没有 python）" % _case_name)
		quit(0)
		return
	OS.delay_msec(900)

	var camp = CampaignRes.load_campaign("res://data/campaigns/demo", cfg)
	var level = camp.level("02_twin_line") if camp != null else null
	ok(level != null, "（前提）合作关能载入")
	if level == null:
		OS.kill(pid)
		quit(1)
		return
	var font := FontLoaderRes.load_font(cfg)
	var host = CoopLobbyRes.new()
	var guest = CoopLobbyRes.new()
	root.add_child(host)
	root.add_child(guest)
	host.setup(cfg, font)
	guest.setup(cfg, font)
	host.host_started.connect(_on_host_started)
	guest.guest_started.connect(_on_guest_started)

	var url := "ws://127.0.0.1:%d/ws" % PORT
	(host.find_child("RelayUrl", true, false) as LineEdit).text = url
	(guest.find_child("RelayUrl", true, false) as LineEdit).text = url
	(host.find_child("RoomCode", true, false) as LineEdit).text = ROOM
	(guest.find_child("RoomCode", true, false) as LineEdit).text = ROOM

	_press(host, "CreateBtn")
	await _wait(90)
	_press(guest, "JoinBtn")
	await _wait(60)
	ok(host._lobby != null and host._lobby.room_code() == ROOM, "★ 房主建房拿到房间码")
	ok(guest._lobby != null and guest._lobby.room_code() == ROOM, "★ 客机加入同一房间")

	_press(host, "ReadyBtn")
	_press(guest, "ReadyBtn")
	await _wait(60)
	ok(host._lobby != null and host._lobby.is_ready(), "★ 双方准备（房主视角）")
	ok(guest._lobby != null and guest._lobby.is_ready(), "★ 双方准备（客机视角）")

	var start_btn = host.find_child("StartBtn", true, false) as Button
	ok(start_btn != null and not start_btn.disabled, "★ 房主「开始」在双方准备后可用")
	_press(host, "StartBtn")
	await _wait(30)
	eq(_host_started.size(), 1, "★ 房主开局信号")
	if _host_started.size() == 0:
		OS.kill(pid)
		quit(1)
		return
	var host_transport = _host_started[0][2]
	ok(host_transport != null, "★ 房主拿到已连接的 transport")
	# 测试里没有 game_scene，手动补上房主本来会发的 start。
	host_transport.send_text(ProtocolRes.encode(ProtocolRes.make("start", 1, {
		"campaign": "demo",
		"level_id": "02_twin_line",
		"level_data": level.raw,
		"seats": ["F1", "F2"],
		"guest_seat": "F2",
	})))
	await _wait(60)
	eq(_guest_started.size(), 1, "★ 客机收到 start（大厅交接）")
	if _guest_started.size() > 0:
		var payload: Dictionary = _guest_started[0][0]
		var gt = _guest_started[0][1]
		ok(gt != null, "★ 客机拿到已连接的 transport")
		ok(typeof(payload.get("level_data", null)) == TYPE_DICTIONARY
			and not (payload["level_data"] as Dictionary).is_empty(),
			"★ start 带完整 level_data")

	if host_transport != null:
		host_transport.close()
	if _guest_started.size() > 0 and _guest_started[0][1] != null:
		_guest_started[0][1].close()
	host.queue_free()
	guest.queue_free()
	OS.kill(pid)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _press(owner: Control, button_name: String) -> void:
	var b = owner.find_child(button_name, true, false)
	if b is Button:
		(b as Button).pressed.emit()


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _on_host_started(campaign_id: String, level_id: String, transport) -> void:
	_host_started.append([campaign_id, level_id, transport])


func _on_guest_started(payload: Dictionary, transport) -> void:
	_guest_started.append([payload, transport])
