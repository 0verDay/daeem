## test_friendly_building.gd —— ★ 右键友军建筑必须下「移动」而不是「攻击」（本轮修）。
##
## 背景：`input_controller` 判断「敌对建筑」时用的是严格的 `same_side`（只认同阵营），
##   而逻辑层删除建筑用的是 `same_side_for_attack`（同阵营 **或盟友**）。
##   于是右键盟友建筑会发一条 `attack` —— 逻辑层按「同方」把它拒掉，表现就是
##   「右键友军建筑完全没反应」。这条测试同时钉住「敌方建筑仍然是攻击」。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const Game3DRes = preload("res://view/game_scene3d.gd")
const CommandProcessorRes = preload("res://logic/command_processor.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")


func _initialize() -> void:
	_case_name = "test_friendly_building"
	_run()


func _run() -> void:
	await process_frame
	var cfg = ConfigRes.load_default()
	var camp = CampaignRes.load_campaign("res://data/campaigns/demo", cfg)
	var lv = camp.level("mt") if camp != null else null
	ok(lv != null, "（前提）mt 关卡能载入")
	if lv == null:
		_finish()
		return
	var game = Game3DRes.new()
	root.add_child(game)
	var started: bool = game.start_level(camp, lv, "F2")
	ok(started, "（前提）3D 场景能以 F2 起局")
	if not started:
		game.queue_free()
		_finish()
		return
	for i in 5:
		await process_frame
	game.set_process(false)
	var w = game.world
	var mine: Array = []
	for u in w.units:
		if u.alive and String(u.faction) == "F2":
			mine.append(u)
	ok(not mine.is_empty(), "（前提）有 F2 单位")
	if mine.is_empty():
		game.queue_free()
		_finish()
		return
	var u = mine[0]
	var bt := _free_tile_near(w, cfg, u, "F2")
	ok(bt.x >= 0, "（前提）找到一格空地放友军建筑")
	if bt.x < 0:
		game.queue_free()
		_finish()
		return
	# ★ dgj 是 F2 的盟友（mt.json allies）—— 这正是用户报的「友军建筑」。
	var ally_b = w.add_building("tower", bt.x, bt.y, "dgj", true, true)
	ok(ally_b != null, "（前提）友军（dgj）箭塔放好了")
	game.input_ctrl.select_units([u])
	game.input_ctrl.hover_tile = bt
	game.input_ctrl.mouse_world = Vector2(bt.x + 0.5, bt.y + 0.5)
	var got: Array = []
	var sink = func(cmd): got.append(cmd)
	game.input_ctrl.command_issued.connect(sink)
	game.input_ctrl._on_right_click(false)
	game.input_ctrl.command_issued.disconnect(sink)
	eq(got.size(), 1, "右键友军建筑发出了命令")
	if not got.is_empty():
		eq(String(got[0].get("kind", "")), "move",
			"★★ 右键友军建筑 = 移动（不是 attack）")
		ok(not got[0].has("target_id") and not got[0].has("tx"),
			"★ 移动命令不带建筑目标（只是走到那个位置）")
		var before: Vector2 = u.pos
		var applied: bool = CommandProcessorRes.apply_move(w, cfg, got[0])
		ok(applied, "★★ 移动命令被逻辑层接受")
		for i in 200:
			w.tick(0.05)
		ok(before.distance_to(u.pos) > 0.5,
			"★★ 单位真的动了（%.2f 格）" % before.distance_to(u.pos))

	# 反向：敌方（sj）建筑仍然必须是攻击命令（别把修复扩大成「所有建筑都移动」）。
	var ebt := _free_tile_near(w, cfg, u, "F2")
	ok(ebt.x >= 0, "（前提）再找一格放敌方建筑")
	if ebt.x >= 0:
		var foe_b = w.add_building("tower", ebt.x, ebt.y, "sj", true, true)
		ok(foe_b != null, "（前提）敌方箭塔放好了")
		game.input_ctrl.hover_tile = ebt
		game.input_ctrl.mouse_world = Vector2(ebt.x + 0.5, ebt.y + 0.5)
		got.clear()
		game.input_ctrl.command_issued.connect(sink)
		game.input_ctrl._on_right_click(false)
		game.input_ctrl.command_issued.disconnect(sink)
		if not got.is_empty():
			eq(String(got[0].get("kind", "")), "attack", "★ 敌方建筑仍然是攻击命令")
			ok(got[0].has("tx") and int(got[0]["tx"]) == ebt.x, "★ 攻击命令带建筑地块")

	game.queue_free()
	await process_frame
	_finish()


## 在 `u` 附近找一格可通行、无建筑的空地（优先离得近）。
func _free_tile_near(w, cfg, u, faction: String) -> Vector2i:
	for r in range(1, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := Vector2i(u.tx + dx, u.ty + dy)
				if not w.map.terrain_walkable(t.x, t.y):
					continue
				if w.building_at(t.x, t.y) != null:
					continue
				if not PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, faction):
					continue
				return t
	return Vector2i(-1, -1)


func _finish() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
