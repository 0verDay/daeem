## test_build_point_and_death.gd —— 可建造点位指示物 + 建筑倒毁动画（2026.11.15）
##
## 验三件事：
##   1. Blender 导出的 `build_point_lowpoly.glb` 真的加载进来了（不是空 MultiMesh）；
##   2. 常驻指示物 = 己方区划里**空着**的点位；拖建筑牌时对应的点位进入高亮批次；
##   3. 建筑被打掉后会生成「多块」碎块一起下落，约 1.2 秒后自己清干净。
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")


func _initialize() -> void:
	_case_name = "test_build_point_and_death"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景启动成功")
		game.queue_free()
		quit(1)
		return
	await process_frame
	await process_frame
	# 手动推进：避免和场景自己的 `_process` 抢同一个世界 / 同一个倒毁层。
	game.set_process(false)

	# ---- 1) 模型真的加载 ----
	ok(game.build_points_view != null, "可建造点位视图层存在")
	ok(game.build_points_view._mesh != null,
		"★★ build_point_lowpoly.glb 加载成功（模型指示物不是空的）")
	var maabb: AABB = game.build_points_view._mesh.get_aabb()
	near(maabb.position.y, 0.0, 0.01,
		"★★ 模型底边在 y = 0（贴地，不会陷进去 / 浮起来）")
	ok(maabb.size.x > 0.4 and maabb.size.x < 0.7,
		"★ 模型占地约 0.54 格（实际 %.2f × %.2f）" % [maabb.size.x, maabb.size.z])
	ok(maabb.size.y < 0.15, "★ 碎石堆是低矮的（高 %.3f 格）" % maabb.size.y)
	ok(game.build_points_view.base_count > 0,
		"★★ 己方区划里有可建造点位（%d 个）" % game.build_points_view.base_count)
	ok(game.build_points_view._base_root.visible,
		"★ 常驻指示物在画（不是只在拖牌时出现）")
	eq(game.build_points_view._base_items.size(),
		game.build_points_view.base_count, "常驻实例数 = 点位数")
	eq(game.build_points_view.hi_count, 0, "（前提）没拖牌时没有高亮")

	# ---- 2) 拖建筑牌 → 点位高亮 ----
	var tiles: Array[Vector2i] = []
	for z in game.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		if String((z as Dictionary).get("owner", "")) != String(game.world.my_faction):
			continue
		for p in ((z as Dictionary).get("build_points", []) as Array):
			var t: Vector2i = p
			if game.world.can_build_at(t.x, t.y):
				tiles.append(t)
	ok(not tiles.is_empty(), "（前提）拿到用于高亮的点位")
	game.build_points_view.sync("build", tiles)
	eq(game.build_points_view.hi_count, tiles.size(),
		"★★ 拖建筑牌时所有可建点位都进入高亮（%d 个）" % tiles.size())
	ok(game.build_points_view._hi_root.visible, "★ 高亮批次显示了")
	var hi_mat: StandardMaterial3D = game.build_points_view._hi_mat
	ok(hi_mat != null and hi_mat.emission_enabled,
		"★★ 高亮材质是自发光（换色 + 放大）")
	# 招募牌不应该高亮点位
	game.build_points_view.sync("recruit", tiles)
	eq(game.build_points_view.hi_count, 0, "★ 拖将领牌不会把建造点位点亮")
	game.build_points_view.sync("", [])

	# ---- 3) 建筑倒毁：多块碎块 + 自己清理 ----
	ok(game.building_death != null, "建筑倒毁视图层存在")
	game.building_death.sync(0.0)                 # 基线：这些建筑现在是活着的
	var victim = null
	for b in game.world.building_list:
		if b != null and b.alive and String(b.type) != "zone_center":
			victim = b
			break
	ok(victim != null, "（前提）找一栋可摧毁的建筑")
	if victim == null:
		game.queue_free()
		quit(1)
		return
	var type := String(victim.type)
	var pieces: Array = game.building_death._pieces_of(type)
	ok(pieces.size() >= 4, "★★ 模型能拆成多块（%s：%d 块）" % [type, pieces.size()])

	victim.take_damage(game.cfg, victim.hp + 9999.0, null)
	for _i in 3:
		game.world.tick(1.0 / 60.0)
	game.building_death.sync(1.0 / 60.0)
	ok(game.building_death.active_count >= 1,
		"★★ 建筑消失后开始播倒毁动画（%d 栋在倒）" % game.building_death.active_count)
	ok(game.building_death.last_piece_count >= 4,
		"★★ 一栋拆成多块一起塌（%d 块）" % game.building_death.last_piece_count)
	if game.building_death.active_count > 0:
		var c: Dictionary = game.building_death._collapses[0]
		var mm: MultiMesh = c["mm"]
		eq(mm.instance_count, game.building_death.last_piece_count,
			"碎块数 = MultiMesh 实例数")
		var p0: Dictionary = (c["pieces"] as Array)[0]
		var y0: float = (p0["pos"] as Vector3).y
		for _i in 8:
			game.building_death.sync(1.0 / 60.0)
		var y1: float = (p0["pos"] as Vector3).y
		ok(y1 < y0, "★★ 碎块真的往下掉（%.2f → %.2f）" % [y0, y1])
	for _i in 90:
		game.building_death.sync(1.0 / 60.0)
	eq(game.building_death.active_count, 0, "★★ 倒完自动清理（不会留一堆碎块）")

	game.queue_free()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
