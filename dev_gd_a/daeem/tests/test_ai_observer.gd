## test_ai_observer.gd —— 主界面 ai_test：AI 接管 F1，玩家观战（只读）。
## 同时验证 ai_test_2：观战但四颗 AI 指令按钮可用（可给 AI 下令）。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const FactionRes = preload("res://logic/faction.gd")

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

	# ★★ ai_test_2：观战，但四颗 AI 指令按钮可用（玩家可以给被观察的 AI 下指令）。
	var level2 = camp.level("ai_test_2") if camp != null else null
	ok(level2 != null, "（前提）ai_test_2 关卡能载入")
	if level2 == null:
		quit(1)
		return
	var game2 = GameSceneRes.new()
	game2.name = "AiObserverGame2"
	root.add_child(game2)
	ok(game2.start_ai_observer(level2, true, true), "★★ ai_test_2 观战 + 可下令 + 全图显示局能装配")
	if game2.world == null:
		quit(1)
		return
	var w2 = game2.world
	ok(w2.observer_mode, "ai_test_2 仍是观战模式")
	ok(game2.observer_can_command, "★★ ai_test_2 放行 AI 面板指令")
	eq(String(w2.my_faction), "p1", "被观察的是 p1")
	ok(w2.ai_commanders.has("p1"), "p1 有 AI 控制器")
	ok(w2.ai_commanders.has("p2"), "★★ p2 也被 commander 接管（AI vs AI）")
	ok(w2.find_base_of("p2") != null, "★★ p2 有基地（双 AI 正常发展）")
	ok(not FactionRes.same_side_for_attack("p1", "p2"), "★★ p1 / p2 互为敌人")
	var p2_reject := String(w2.set_ai_directive("p2", "expand", -1.0, -1.0, "p1"))
	ok(p2_reject != "", "★★ 玩家不能给 p2 下指令（拒因 %s）" % p2_reject)
	# ★ 只给玩家显示开全图：p1 的显示查询全亮，但 p1 的**逻辑**视野仍是正常迷雾。
	ok(w2.fog != null and w2.fog.is_revealed_for_display("p1"),
		"★★ 玩家（p1）显示全图")
	ok(w2.fog.tile_visible("p1", 0, 21), "★★ 玩家能看到远处格子")
	ok(not w2.fog.logic_tile_visible("p1", 0, 21),
		"★★ AI p1 的逻辑视野仍是正常迷雾（没有开天眼）")
	ok(not w2.fog.tile_visible("p2", 0, 21), "p2 没有被开显示全图")
	# ★ 场景干净：没有旧测试的敌方基地 / 塔 / 墙。
	var enemy_buildings := 0
	for b in w2.building_list:
		if String(b.owner) == "enemy":
			enemy_buildings += 1
	eq(enemy_buildings, 0, "★★ ai_test_2 里没有旧测试的 enemy 建筑")
	var z5 = w2.zone_by_id(5)
	ok(z5 != null and String((z5 as Dictionary).get("owner", "")) == "",
		"★★ 5 号区划不再预置给 enemy")
	ok(game2.input_ctrl.observer_mode, "输入层仍是观战")
	ok(game2.input_ctrl.observer_ai_orders, "★★ 输入层放行 AI 选点")
	var panel2 = game2.hud.ai_panel
	ok(panel2 != null and panel2.visible, "ai_test_2 AI 面板可见")
	if panel2 != null:
		eq(String(panel2._observer_faction), "p1", "面板绑定 p1")
		ok(panel2._observer_allow_orders, "★★ 面板处于「观战可下令」")
		for k in ["march", "develop", "expand", "mass"]:
			ok(not (panel2._buttons[k] as Button).disabled,
				"★★ 四颗指令按钮可用：%s" % k)
	# 观战仍不放行部队命令。
	var before2 := String(w2.ai_directive_of("p1").get("kind", ""))
	game2._on_command({"kind": "move", "faction": "p1", "ids": [], "x": 1.0, "y": 1.0})
	eq(String(w2.ai_directive_of("p1").get("kind", "")), before2,
		"★★ 观战仍丢弃 move（只放行 ai_order）")
	# 一键指令：扩张。
	game2._on_command({"kind": "ai_order", "faction": "p1", "ai_faction": "p1",
		"order": "expand", "x": -1.0, "y": -1.0})
	eq(String(w2.ai_directive_of("p1").get("kind", "")), "expand",
		"★★ ai_test_2 里可以给 AI 下「扩张」")
	# 选点指令：行军（走 input_controller 的地图选点路径）。
	game2.input_ctrl.begin_ai_order_pick("march", "p1")
	game2.input_ctrl.mouse_world = Vector2(10.5, 10.5)
	game2.input_ctrl._issue_order_click()
	eq(String(w2.ai_directive_of("p1").get("kind", "")), "march",
		"★★ ai_test_2 里可以在地图上给 AI 下「行军」")
	game2.queue_free()
	await process_frame

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
