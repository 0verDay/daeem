## test_coop_lobby.gd —— 合作大厅：数字房间码 / 房间列表 / 准备 / 开始 / 房间配置。
##
## 真实中继（`server/daeem_relay.py`）+ 两个 CoopLobby 实例；不点像素、不截图。
## 没有 Python 时 SKIP。
extends "res://tests/test_case.gd"

const CoopLobbyRes = preload("res://view/coop_lobby.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
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
	host.set_animation_sec(0.0)
	guest.set_animation_sec(0.0)
	host.host_started.connect(_on_host_started)
	guest.guest_started.connect(_on_guest_started)

	var url := "ws://127.0.0.1:%d/ws" % PORT
	host.set_relay_url(url)
	guest.set_relay_url(url)
	await _wait(20)

	# ---- 房主建房（输入 6 位数字 → 按钮变「创建房间」）
	_set_code(host, ROOM)
	eq(_text(host, "ActionBtn"), "创建房间", "★ 6 位码且无此房间 → 「创建房间」")
	_press(host, "ActionBtn")
	await _wait(90)
	ok(host._lobby != null and host._lobby.room_code() == ROOM, "★ 房主建房拿到房间码")
	eq(host.state_name(), "room", "★ 房主进入房间面板")

	# ---- 客机加入（房间列表刷新后按钮变「进入房间」）
	_set_code(guest, ROOM)
	guest._refresh_rooms()
	for i in 90:
		await process_frame
		if guest._rooms.size() > 0:
			break
	ok(guest._rooms.size() > 0, "★ 客机通过 /rooms 看到房主的房间")
	guest._update_action()
	eq(_text(guest, "ActionBtn"), "加入房间", "★ 6 位码且房间存在 → 「加入房间」")
	_press(guest, "ActionBtn")
	await _wait(90)
	ok(guest._lobby != null and guest._lobby.room_code() == ROOM, "★ 客机加入同一房间")
	eq(guest.state_name(), "room", "★ 客机进入房间面板")

	# ---- 房主选中的地图同步给客机
	await _wait(30)
	ok(not host._current_entry.is_empty(), "★ 房主有默认合作地图")
	ok(not guest._current_entry.is_empty(), "★ 客机收到房主的地图配置")
	if not host._current_entry.is_empty() and not guest._current_entry.is_empty():
		eq(String(guest._current_entry.get("level", "")), String(host._current_entry.get("level", "")),
			"★ 客机地图 = 房主地图")

	# ---- 客机准备 / 取消 / 再准备
	_press(guest, "RoomActionBtn")
	await _wait(45)
	ok(host._lobby.is_guest_ready(), "★ 客机点准备 → 房主看到客机已准备")
	eq(_text(guest, "RoomActionBtn"), "取消准备", "★ 客机按钮变「取消准备」")
	_press(guest, "RoomActionBtn")
	await _wait(45)
	ok(not host._lobby.is_guest_ready(), "★ 客机取消准备")
	eq(_text(guest, "RoomActionBtn"), "准备", "★ 按钮变回「准备」")
	_press(guest, "RoomActionBtn")
	await _wait(45)
	ok(host._lobby.is_guest_ready(), "★ 客机再次准备")

	# ---- 房主开始（房主自己不需要准备）
	eq(_text(host, "RoomActionBtn"), "开始", "★ 客机准备好后房主按钮是「开始」")
	_press(host, "RoomActionBtn")
	await _wait(30)
	eq(_host_started.size(), 1, "★ 房主开局信号")
	if _host_started.size() == 0:
		OS.kill(pid)
		quit(1)
		return
	var host_transport = _host_started[0][2]
	ok(host_transport != null, "★ 房主拿到已连接的 transport")
	# ★ 大厅交给 game_scene 之后，房间面板被销毁也不能把这条连接关掉。
	host.queue_free()
	await _wait(3)
	ok(host_transport.is_open(), "★ 大厅销毁后 transport 仍然可用（没有被 _exit_tree 关掉）")
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
	if is_instance_valid(host):
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


func _set_code(owner: Control, code: String) -> void:
	var e := owner.find_child("CodeEdit", true, false) as LineEdit
	if e != null:
		e.text = code
		e.caret_column = code.length()
	if owner.has_method("_on_code_changed"):
		owner._on_code_changed(code)


func _text(owner: Control, button_name: String) -> String:
	var b := owner.find_child(button_name, true, false) as Button
	return "" if b == null else b.text


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
