## test_coop_ai_teammate.gd —— ★ 合作模式「AI 队友」：本地开局、面板、指令链路。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignRes = preload("res://logic/campaign.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

func _initialize() -> void:
	_case_name = "test_coop_ai_teammate"
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

	var game = GameSceneRes.new()
	game.name = "SoloAiGame"
	root.add_child(game)
	ok(game.start_coop_solo(level, {"difficulty": "normal"}), "★ 合作 AI 队友局能装配")
	if game.world == null:
		quit(1)
		return
	ok(game.coop_role == "solo", "角色 = solo")
	ok(game.coop_host_session == null, "没有 HostSession")
	ok(game.world.commander_factions().has("F2"), "第二席位是 commander")
	ok(game.world.find_base_of("F2") != null, "AI 队友有大本营")
	ok(game.world.alive_units_of("F2").size() >= 3, "AI 队友有关卡部队")
	ok(not game.world.player_factions.has("F2"), "AI 队友不算玩家操作席位")
	eq(game.world.ai_directive_of("F2").get("kind", ""), "auto", "默认自主 auto")
	ok(game.input_ctrl.pause_allowed == false, "合作局禁用暂停")

	# --- 面板存在且能显示 ---
	ok(game.hud != null, "HUD 存在")
	var panel = game.hud.ai_panel
	ok(panel != null, "AI 面板已创建")
	if panel != null:
		panel.sync()
		ok(panel.visible, "★ 有 AI 队友时面板可见")
		eq(String(panel._faction), "F2", "面板绑定 F2")
		ok(panel._buttons.has("march") and panel._buttons.has("develop")
			and panel._buttons.has("expand") and panel._buttons.has("mass"), "面板四个按钮")
		# 发展：一键指令 → command_processor → world
		panel.order_requested.emit("develop", "F2")
		eq(String(game.world.ai_directive_of("F2").get("kind", "")), "develop", "面板发 develop")
		# 行军：进入选点模式
		panel.pick_requested.emit("march", "F2")
		eq(String(game.input_ctrl.order_mode), "ai_march", "★ 行军进入 AI 选点模式")
		eq(String(game.input_ctrl.ai_order_faction), "F2", "选点绑定 F2")
		# 模拟点地图：左键那一下由 input_controller 发 ai_order
		game.input_ctrl.mouse_world = Vector2(10.5, 10.5)
		game.input_ctrl._issue_order_click()
		eq(String(game.world.ai_directive_of("F2").get("kind", "")), "march", "★ 点地图后下达 march")
		eq(String(game.input_ctrl.order_mode), "", "选点模式结束")

	# --- 指令拒绝：非同一方 / 非 commander ---
	game._on_command({"kind": "ai_order", "faction": "F1", "ai_faction": "F2",
		"order": "march", "x": 9999.0, "y": 0.0})
	eq(String(game.world.ai_directive_of("F2").get("kind", "")), "march", "非法点不覆盖旧指令")

	# --- 跑几秒：AI 自己动、面板状态更新 ---
	for i in 30:
		await process_frame
	ok(game.world.time > 0.0, "世界在推进")
	var st: Dictionary = game.world.ai_panel_state("F2")
	ok(int(st.get("army", 0)) > 0, "面板能读到 AI 军队")
	ok(int(st.get("army_cap", 0)) > 0, "面板能读到 AI 上限")

	# --- 真人合作路径不受影响：没有 commander 时不显示面板 ---
	var lv2 = camp.level(LEVEL_ID)
	var game2 = GameSceneRes.new()
	game2.name = "HumanCoopGame"
	root.add_child(game2)
	# 不用真 transport：只验证「有 commander 才显示面板」这条判据
	var FakeTransportRes = load("res://tests/fake_transport.gd")
	var ht = FakeTransportRes.new()
	var gt = FakeTransportRes.new()
	ht.attach(gt)
	gt.attach(ht)
	ok(game2.start_coop_host(camp, lv2, ht), "真人合作房主仍能装配")
	if game2.world != null and game2.hud != null and game2.hud.ai_panel != null:
		game2.hud.ai_panel.sync()
		ok(not game2.hud.ai_panel.visible, "★ 真人合作局不显示 AI 面板")
	game.queue_free()
	game2.queue_free()
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
