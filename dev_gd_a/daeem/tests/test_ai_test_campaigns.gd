## test_ai_test_campaigns.gd —— 战役菜单里的三个测试战役：简单 / 中等 / 困难。
##
## 验四层：
##   1. 数据：三关都在 demo 里，地图 between_moutains，两边都可玩且都挂 commander；
##   2. 难度：每关的 commander_ai.difficulty = easy / normal / hard；
##   3. 装配：选任意一方，另一方由 commander 接管，且难度正确；
##   4. 菜单：campaigns_menu.json 里有三个指向它们的真实章节。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const BriefRes = preload("res://logic/campaign_menu_brief.gd")
const GameSceneRes = preload("res://view/game_scene3d.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVELS := {
	"ai_test_easy": "easy",
	"ai_test_normal": "normal",
	"ai_test_hard": "hard",
}

func _initialize() -> void:
	_case_name = "test_ai_test_campaigns"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	await process_frame

	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(camp != null, "（前提）demo 战役能载入")
	if camp == null:
		quit(1)
		return

	for lid in LEVELS.keys():
		_check_data(camp, String(lid), String(LEVELS[lid]))
	await _check_assembly(cfg, camp)
	_check_menu(cfg)
	await _check_game_scene(camp)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1) 关卡数据
# ------------------------------------------------------------------

func _check_data(camp, lid: String, diff: String) -> void:
	var lv = camp.level(lid)
	ok(lv != null, "关卡 %s 能载入" % lid)
	if lv == null:
		return
	eq(String(lv.map_id), "between_moutains", "%s 地图 = between_moutains" % lid)
	eq(lv.playable_ids(), ["p1", "p2"], "%s 两个可玩阵营" % lid)
	for fid in ["p1", "p2"]:
		var fc: Dictionary = lv.faction_config(String(fid))
		eq(String(fc.get("ai", "")), "commander",
			"%s/%s 是 commander（选哪边都能摘掉自己、让另一边接管）" % [lid, fid])
		var ca: Variant = fc.get("commander_ai", null)
		ok(typeof(ca) == TYPE_DICTIONARY, "%s/%s 有 commander_ai" % [lid, fid])
		if typeof(ca) == TYPE_DICTIONARY:
			eq(String((ca as Dictionary).get("difficulty", "")), diff,
				"★★ %s/%s 难度 = %s" % [lid, fid, diff])
	var blocks: Array = lv.blockers()
	var detail := ""
	for b in blocks:
		detail += " / %s" % String((b as Dictionary)["msg"])
	ok(blocks.is_empty(), "%s 没有拦截项%s" % [lid, detail])


# ------------------------------------------------------------------
# 2) 装配：选任意一方，另一方由 commander 接管
# ------------------------------------------------------------------

func _check_assembly(cfg, camp) -> void:
	for lid in LEVELS.keys():
		var lv = camp.level(String(lid))
		if lv == null:
			continue
		var diff := String(LEVELS[lid])
		for seat in ["p1", "p2"]:
			var foe := "p2" if String(seat) == "p1" else "p1"
			var w = WorldRes.create_from_level(cfg, lv, String(seat),
				lv.build_roster(cfg, seat), true)
			ok(w != null, "%s/%s 能建出世界" % [lid, seat])
			if w == null:
				continue
			eq(w.player_factions, [String(seat)],
				"%s/%s 只有玩家那一方是本机" % [lid, seat])
			eq(w.commander_factions(), [foe],
				"★★ %s/%s 对手 %s 由 commander 接管" % [lid, seat, foe])
			ok(w.ai_commanders.has(foe), "%s/%s 有 AI 控制器" % [lid, seat])
			if w.ai_commanders.has(foe):
				var ai = w.ai_commanders[foe]
				eq(String(ai.profile.get("difficulty_name", "")), diff,
					"★★ %s/%s AI 难度 = %s" % [lid, seat, diff])
			ok(w.find_base_of(String(seat)) != null and w.find_base_of(foe) != null,
				"%s/%s 双方都有大本营" % [lid, seat])
			eq(String(w.objective_state.get("state", "")), "running",
				"%s/%s 目标开局进行中" % [lid, seat])
			w = null


# ------------------------------------------------------------------
# 3) 菜单数据
# ------------------------------------------------------------------

func _check_menu(cfg) -> void:
	var campaigns := CampaignMenuDbRes.load_campaigns()
	for lid in LEVELS.keys():
		var found: Dictionary = {}
		for raw in campaigns:
			if typeof(raw) != TYPE_DICTIONARY:
				continue
			for item in ((raw as Dictionary).get("chapters", []) as Array):
				if typeof(item) == TYPE_DICTIONARY \
						and String((item as Dictionary).get("level_id", "")) == String(lid):
					found = item
		ok(not found.is_empty(), "菜单里有指向 %s 的章节" % lid)
		if found.is_empty():
			continue
		var brief := BriefRes.resolve(cfg, found)
		ok(not bool(brief.get("placeholder", true)), "%s 的菜单章不是占位" % lid)
		eq((brief.get("entries", []) as Array).size(), 2,
			"%s 的菜单章有两个可玩阵营" % lid)
		ok(brief.get("map", null) != null, "%s 的菜单章有地图数据" % lid)


# ------------------------------------------------------------------
# 4) 真实游戏场景：困难关，玩家当下方 p1
# ------------------------------------------------------------------

func _check_game_scene(camp) -> void:
	var lv = camp.level("ai_test_hard")
	ok(lv != null, "（前提）困难关能载入")
	if lv == null:
		return
	var game = GameSceneRes.new()
	game.name = "AiTestCampaignScene"
	root.add_child(game)
	ok(game.start_level(camp, lv, "p1"), "困难关能用下方（p1）直接开局")
	if game.world != null:
		eq(game.world.commander_factions(), ["p2"], "★★ 上方（p2）由 commander 接管")
		if game.world.ai_commanders.has("p2"):
			eq(String(game.world.ai_commanders["p2"].profile.get("difficulty_name", "")),
				"hard", "★★ 对局里的 AI 难度 = hard")
		eq(String(game.world.my_faction), "p1", "本机阵营 = p1")
	game.queue_free()
	await process_frame
