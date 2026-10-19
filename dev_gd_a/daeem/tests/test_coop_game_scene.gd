## test_coop_game_scene.gd —— M12.4：两个 GameScene3D（房主 / 客机）用假连接跑一帧。
##
## 盯：房主 tick + 客机不 tick、快照写回客机、客机命令经 host_session 执行、
## 合作局暂停被禁用、两边 HUD 目标条都出现。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const FakeTransportRes = preload("res://tests/fake_transport.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

var _applied: Array = []

func _initialize() -> void:
	_case_name = "test_coop_game_scene"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	await process_frame
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var level = camp.level(LEVEL_ID) if camp != null else null
	ok(level != null, "（前提）合作关能载入")
	if level == null:
		quit(1)
		return

	var ht = FakeTransportRes.new()
	var gt = FakeTransportRes.new()
	ht.attach(gt)
	gt.attach(ht)

	var host = GameSceneRes.new()
	host.name = "HostGame"
	root.add_child(host)
	ok(host.start_coop_host(camp, level, ht), "★ 房主合作场景能装配")
	if host.world == null:
		quit(1)
		return
	var seats: Array = level.coop_roster()
	var payload := {
		"campaign": "demo",
		"level_id": LEVEL_ID,
		"level_data": level.raw,
		"seats": seats,
		"guest_seat": seats[1],
	}
	var guest = GameSceneRes.new()
	guest.name = "GuestGame"
	root.add_child(guest)
	ok(guest.start_coop_guest(payload, gt), "★ 客机合作场景能装配")
	if guest.world == null:
		quit(1)
		return

	ok(host.coop_role == "host", "房主角色 = host")
	ok(guest.coop_role == "guest", "客机角色 = guest")
	ok(host.input_ctrl.pause_allowed == false, "★ 房主合作局禁用暂停")
	ok(guest.input_ctrl.pause_allowed == false, "★ 客机合作局禁用暂停")
	var pause_key := InputEventKey.new()
	pause_key.keycode = KEY_P
	pause_key.pressed = true
	host.input_ctrl.handle_key(pause_key)
	ok(not host.input_ctrl.paused, "★ 按 P 也不会把合作局冻住")
	eq(guest.world.my_faction, "F2", "客机操作 F2")
	eq(host.world.my_faction, "F1", "房主操作 F1")

	# 房主改一笔客机的钱；等 host_session 发快照 → client_session 应用。
	host.world.player_resources["F2"]["food"] = 777.0
	await _wait(30)
	var guest_food := float(guest.world.resources["food"])
	ok(guest_food >= 777.0 and guest_food < 790.0,
		"★★ 快照把客机自己的钱写回（同时客机经济也在涨：%.1f）" % guest_food)

	# 客机命令：走 guest._on_command（input_controller 的出口）→ client_session
	# → 假连接 → host_session → command_processor。
	host.coop_host_session.command_applied.connect(_on_applied)
	var u = _first_unit(guest.world, "F2")
	ok(u != null, "（前提）客机世界里选得到 F2 单位")
	if u != null:
		guest._on_command({"kind": "stop", "ids": [u.id], "faction": "F2"})
		await _wait(20)
		eq(_applied.size(), 1, "★ 客机命令到房主并被处理")
		if _applied.size() > 0:
			ok(bool((_applied[0] as Dictionary).get("ok", false)), "命令被接受")

	ok(host.hud != null and host.hud.objective_panel != null
		and host.hud.objective_panel.visible, "★ 房主 HUD 显示目标条")
	ok(guest.hud != null and guest.hud.objective_panel != null
		and guest.hud.objective_panel.visible, "★ 客机 HUD 显示目标条")
	eq(guest.world.objective_state.get("defend", []), ["F1", "F2"],
		"客机目标也按两个席位")

	host._shutdown_coop()
	guest._shutdown_coop()
	host.queue_free()
	guest.queue_free()
	await process_frame
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


func _first_unit(w, fid: String):
	for u in w.units:
		if u.alive and String(u.faction) == fid:
			return u
	return null


func _on_applied(ok: bool, cmd: Dictionary) -> void:
	_applied.append({"ok": ok, "cmd": cmd})
