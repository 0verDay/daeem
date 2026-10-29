## test_ai_test_duel.gd —— 主菜单 ai_test：between_moutains 上随机 p1 / p2，另一方交给 commander AI。
##
## 验四件事：
##   1. 数据：ai_test_battle 的目标图是 between_moutains，两边都可玩、目标按阵营分开；
##   2. 装配：玩家当 p1 / 当 p2 各建一局，两边都有基地与开局将领，
##      只有**没被选中的那一方**是 commander（player_factions / ai_commanders 都对）；
##   3. 主菜单按钮的真实入口：`_on_ai_test_button_pressed()` 能开出 between_moutains 对局，
##      玩家落在 p1 / p2 之一、恰好另一方是 commander；
##   4. 随机：`main._roll_ai_test_faction()` 只返回可玩阵营，且多次调用两边都会出现。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const GameSceneRes = preload("res://view/game_scene3d.gd")
const MainScene := preload("res://view/main.tscn")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "ai_test_battle"

func _initialize() -> void:
	_case_name = "test_ai_test_duel"
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
	ok(level != null, "（前提）ai_test_battle 关卡能载入")
	if level == null:
		quit(1)
		return

	# ---- 1) 数据 ----
	eq(String(level.map_id), "between_moutains", "★ ai_test 的目标地图 = between_moutains")
	eq(level.playable_ids(), ["p1", "p2"], "★★ p1 / p2 都是可玩阵营（由运行时随机选边）")
	# ★★ 2026.10.29：起手资源是**逐阵营**配的（factions[].start_food / start_gold）。
	for fid in ["p1", "p2"]:
		var meta: Dictionary = {}
		for item in level.faction_meta:
			if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("id", "")) == fid:
				meta = item
				break
		ok(not meta.is_empty(), "（前提）关卡里有阵营 %s" % fid)
		near(float(meta.get("start_food", -1.0)), 100.0, 1e-4,
			"★★ %s 起手粮食 = 100" % fid)
		near(float(meta.get("start_gold", -1.0)), 100.0, 1e-4,
			"★★ %s 起手黄金 = 100" % fid)
	ok(level.objective_for("p1") != null and level.objective_for("p2") != null,
		"★★ 两个阵营各有自己的目标")
	if level.objective_for("p1") != null:
		eq(int((level.objective_for("p1") as Dictionary).get("zone", -1)), 0,
			"p1 的目标 = 0 号区划")
	if level.objective_for("p2") != null:
		eq(int((level.objective_for("p2") as Dictionary).get("zone", -1)), 2,
			"p2 的目标 = 2 号区划")
	var blocks: Array = level.blockers()
	var detail := ""
	for b in blocks:
		detail += " / %s" % String((b as Dictionary)["msg"])
	ok(blocks.is_empty(), "★ 关卡数据没有拦截项%s" % detail)

	# ---- 2) 玩家当 p1 ----
	await _check_one_side(cfg, camp, level, "p1", "p2")
	# ---- 2b) 玩家当 p2 ----
	await _check_one_side(cfg, camp, level, "p2", "p1")

	# ---- 2c) 主菜单按钮的真实入口（随机 + 装配接在一起）----
	await _check_menu_entry()
	# ---- 2d) 新增 see_ai：同一张图，双方 commander AI，玩家看海 ----
	await _check_see_ai_entry()

	# ---- 3) 随机选边 ----
	await _check_random()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _check_one_side(cfg, camp, level, player_faction: String, ai_faction: String) -> void:
	var game = GameSceneRes.new()
	game.name = "AiTestDuel_%s" % player_faction
	root.add_child(game)
	ok(game.start_level_vs_commander(camp, level, player_faction, ai_faction),
		"★★ 玩家=%s / AI=%s 的对局能装配" % [player_faction, ai_faction])
	if game.world == null:
		game.queue_free()
		await process_frame
		return
	var w = game.world
	eq(String(w.my_faction), player_faction, "本机阵营 = %s" % player_faction)
	eq(w.player_factions, [player_faction], "★★ 只有玩家那一方算「玩家的家」")
	ok(not w.commander_factions().has(player_faction),
		"★ 玩家方不是 commander")
	ok(w.commander_factions().has(ai_faction), "★★ %s 由 commander 接管" % ai_faction)
	ok(w.ai_commanders.has(ai_faction), "★★ %s 有 AI 控制器" % ai_faction)
	ok(w.find_base_of(player_faction) != null, "%s 有基地" % player_faction)
	ok(w.find_base_of(ai_faction) != null, "%s（AI）也有基地" % ai_faction)
	# ★★ 2026.10.29：双方起手统一 100 / 100（AI 不再按难度额外拿 250）。
	var mine_pool: Variant = w.resource_pool_for(player_faction)
	var ai_pool: Variant = w.ai_faction_resources.get(ai_faction, null)
	ok(typeof(mine_pool) == TYPE_DICTIONARY, "★ 玩家方有资源池")
	ok(typeof(ai_pool) == TYPE_DICTIONARY, "★ AI 方有资源池")
	if typeof(mine_pool) == TYPE_DICTIONARY:
		near(float((mine_pool as Dictionary).get("food", -1.0)), 100.0, 1e-4,
			"★★ 玩家起手粮食 = 100")
		near(float((mine_pool as Dictionary).get("gold", -1.0)), 100.0, 1e-4,
			"★★ 玩家起手黄金 = 100")
	if typeof(ai_pool) == TYPE_DICTIONARY:
		near(float((ai_pool as Dictionary).get("food", -1.0)), 100.0, 1e-4,
			"★★ AI 起手粮食 = 100（难度 250 已被关卡覆盖）")
		near(float((ai_pool as Dictionary).get("gold", -1.0)), 100.0, 1e-4,
			"★★ AI 起手黄金 = 100（难度 250 已被关卡覆盖）")
	ok(not game.input_ctrl.observer_mode, "★ 输入层是正常对战（不是观战）")
	ok(not game.hud.observer_mode, "★ HUD 不是观战模式（玩家可以正常操作）")
	var mine_generals := 0
	for u in w.alive_units_of(player_faction):
		if u.is_general():
			mine_generals += 1
	ok(mine_generals > 0, "★ 玩家方有开局将领")
	var ai_generals := 0
	for u in w.alive_units_of(ai_faction):
		if u.is_general():
			ai_generals += 1
	ok(ai_generals > 0, "★ AI 方有开局将领")
	eq(String(w.objective_state.get("seat", "")), player_faction,
		"★ 目标按玩家席位判定")
	eq(int(w.objective_state.get("zone", -1)),
		int((level.objective_for(player_faction) as Dictionary).get("zone", -2)),
		"★ 玩家打的是自己那条目标")
	# 世界能推进（commander 有控制器 + 双方都有单位）。
	for i in 5:
		await process_frame
	ok(w.time > 0.0, "★ 对局世界在推进")
	game.queue_free()
	await process_frame


func _check_menu_entry() -> void:
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	# ★★ 2026.10.29：左上角两颗入口都在，see_ai 在 ai_test 正下方、尺寸一致。
	var deck = main.start_screen._menu_deck
	ok(deck != null and deck._ai_test_btn != null and deck._see_ai_btn != null,
		"★★ 主菜单左上角同时有 ai_test 与 see_ai")
	if deck != null and deck._ai_test_btn != null and deck._see_ai_btn != null:
		eq(deck._see_ai_btn.size, deck._ai_test_btn.size, "★ 两颗按钮尺寸一致")
		ok(deck._see_ai_btn.position.y > deck._ai_test_btn.position.y,
			"★★ see_ai 在 ai_test 的下方")
		deck.finish_intro()
		ok(deck._ai_test_btn.visible and deck._see_ai_btn.visible,
			"★★ 开场结束后两颗入口都显示")
	main._on_ai_test_button_pressed()
	await process_frame
	ok(main.game != null, "★★ 主菜单 ai_test 按钮能直接开出对局")
	if main.game == null:
		main.queue_free()
		await process_frame
		return
	eq(String(main.game.level_playing.id), "ai_test_battle",
		"按钮进的是 ai_test_battle 关")
	eq(String(main.game.level_playing.map_id), "between_moutains",
		"★★ 按钮进的是 between_moutains 地图")
	var w = main.game.world
	var player := String(w.my_faction)
	ok(player == "p1" or player == "p2", "★★ 玩家阵营随机落在 p1 / p2（实际 %s）" % player)
	eq(w.commander_factions().size(), 1, "★ 恰好一方由 commander 接管")
	if w.commander_factions().size() == 1:
		var ai := String(w.commander_factions()[0])
		ok(ai != player, "★★ 被 AI 接管的不是玩家那一方（玩家 %s / AI %s）" % [player, ai])
	ok(main.start_screen != null and not main.start_screen.visible,
		"进游戏后主菜单整层隐藏")
	main.queue_free()
	await process_frame
	await process_frame


## ★★ 2026.10.29：主菜单新增的 see_ai —— 同一张 between_moutains，双方 commander AI，玩家看海。
func _check_see_ai_entry() -> void:
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main._on_see_ai_button_pressed()
	await process_frame
	ok(main.game != null, "★★ see_ai 按钮能直接开出观战局")
	if main.game == null:
		main.queue_free()
		await process_frame
		return
	eq(String(main.game.level_playing.id), "ai_test_battle", "see_ai 进的是 ai_test_battle 关")
	eq(String(main.game.level_playing.map_id), "between_moutains",
		"★★ see_ai 进的仍是 between_moutains 地图")
	var w = main.game.world
	ok(main.game.observer_mode, "★★ see_ai 是观战模式（玩家看海）")
	ok(w.observer_mode, "★★ World 进入观战模式")
	ok(w.commander_factions().has("p1") and w.commander_factions().has("p2"),
		"★★ p1 / p2 都是 commander AI")
	ok(w.ai_commanders.has("p1") and w.ai_commanders.has("p2"),
		"★★ 双方都有 AI 控制器（AI vs AI）")
	ok(w.find_base_of("p1") != null and w.find_base_of("p2") != null,
		"★★ 双方都有基地")
	ok(w.player_factions.is_empty(), "★★ 玩家不属于任何一方（没有自己的家）")
	ok(w.objective_state.is_empty(), "★★ 观战者没有目标 / 胜负")
	ok(w.fog != null and w.fog.is_revealed_for_display("p1"),
		"★★ 看海玩家显示全图（显示键 = 被观察方 p1）")
	ok(w.fog.tile_visible("p1", 0, 31), "★★ 看海玩家能看到远处格子")
	ok(not w.fog.logic_tile_visible("p1", 0, 31),
		"★★ AI 的逻辑视野仍是正常迷雾（看海不给他们开天眼）")
	ok(main.game.input_ctrl.observer_mode, "★ 输入层是观战")
	ok(main.game.hud.observer_mode, "★ HUD 是观战模式")
	main.queue_free()
	await process_frame
	await process_frame


func _check_random() -> void:
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var seen := {}
	for i in 64:
		var pick := String(main._roll_ai_test_faction(["p1", "p2"]))
		ok(pick == "p1" or pick == "p2", "随机结果只可能是 p1 / p2（实际 %s）" % pick)
		seen[pick] = true
	ok(seen.has("p1") and seen.has("p2"),
		"★★ 多次随机后 p1 / p2 两边都出现过（%s）" % str(seen.keys()))
	eq(String(main._roll_ai_test_faction([])), "", "空可玩表返回空串")
	main.queue_free()
	await process_frame
