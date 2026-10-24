## test_ai_observer.gd —— 主界面 ai_test：AI 接管 F1，玩家观战（只读）。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignRes = preload("res://logic/campaign.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "ai_test"

func _initialize() -> void:
	_case_name = "test_ai_observer"
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
	ok(level != null, "（前提）ai_test 关卡能载入")
	if level == null:
		quit(1)
		return

	var game = GameSceneRes.new()
	game.name = "AiObserverGame"
	root.add_child(game)
	ok(game.start_ai_observer(level), "★ ai_test 观战局能装配")
	if game.world == null:
		quit(1)
		return
	var w = game.world
	ok(game.observer_mode, "GameScene 进入观战模式")
	ok(w.observer_mode, "World 进入观战模式")
	eq(String(w.my_faction), "F1", "被观察的是 F1")
	ok(w.commander_factions().has("F1"), "F1 是 commander")
	ok(w.ai_commanders.has("F1"), "F1 有 AI 控制器")
	eq(String(w.ai_directive_of("F1").get("kind", "")), "auto", "观战默认交给 AI 自主战略")
	ok(w.player_factions.has("F1"), "观战方仍算目标 / 判负口径的玩家阵营")
	ok(w.find_base_of("F1") != null, "F1 有基地")
	var z1 = w.zone_by_id(1)
	ok(z1 != null and float((z1 as Dictionary).get("production", {}).get("gold", 0.0)) > 0.0,
		"★ ai_test 区划有黄金产能（否则 AI 建不了塔 / 补不了将）")
	var start_generals: Array = []
	for u in w.alive_units_of("F1"):
		if u.is_general():
			start_generals.append(u)
	ok(not start_generals.is_empty(), "F1 有开局将领")
	if not start_generals.is_empty():
		eq(String((start_generals[0] as Object).kind), "general_0",
			"★ 开局将领是 #0（不占 #1-9 招募池，才能补到 10 位）")
	ok(game.input_ctrl.observer_mode, "输入层进入观战模式")
	ok(game.hud != null and game.hud.observer_mode, "HUD 进入观战模式")
	ok(not game.hud.command_card.visible, "观战时隐藏命令卡")
	ok(not game.hud.page_tabs.visible, "观战时隐藏命令页签")
	var panel = game.hud.ai_panel
	ok(panel != null and panel.visible, "★ 观战时 AI 面板可见")
	if panel != null:
		eq(String(panel._observer_faction), "F1", "面板绑定 F1")
		ok((panel._buttons["develop"] as Button).disabled, "★ 观战面板按钮只读")
	# 观战命令应被丢弃：发一条 move，世界不应出现玩家命令
	var before := String(w.ai_directive_of("F1").get("kind", ""))
	game._on_command({"kind": "move", "faction": "F1", "ids": [], "x": 1.0, "y": 1.0})
	eq(String(w.ai_directive_of("F1").get("kind", "")), before, "观战命令不改变 AI 指令")
	for i in 20:
		await process_frame
	ok(w.time > 0.0, "观战世界在推进")
	ok(int(w.ai_panel_state("F1").get("army", 0)) > 0, "AI 面板能读到军队")
	game.queue_free()
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
