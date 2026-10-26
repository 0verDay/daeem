## test_hover_fill.gd —— 鼠标悬停高亮（阵营色填充）
##
## 需求口径（2026.10.26）：
##   · 己方单位 → 它**所属整支部队**一起填色；
##   · 敌方 / 友方单位、任意建筑 → 只填那一个；
##   · 手机端整个功能不启用。
##
## 这里钉的是**接线与口径**（谁被点亮 / 不新增批次 / 手机关掉），
## 观感（颜色浓淡、淡入淡出）由用户在编辑器里验收 —— 无头测试不做截图。
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const InputControllerRes = preload("res://view/input_controller.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")
const UnitFlashShaderRes = preload("res://view/unit_flash.gdshader")
const UnitDownedShaderRes = preload("res://view/unit_downed.gdshader")
const BuildingShaderRes = preload("res://view/building_flash.gdshader")

func _initialize() -> void:
	_case_name = "test_hover_fill"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_shaders()
	await _test_unit_grouping(cfg)
	await _test_views(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _test_config(cfg) -> void:
	var a: float = cfg.num("render.hover_fill_alpha", -1.0)
	ok(a >= 0.0 and a <= 1.0, "★ render.hover_fill_alpha 在 0..1 内（默认 0.7）")
	ok(cfg.num("render.hover_fill_sec", -1.0) >= 0.0,
		"★ render.hover_fill_sec ≥ 0（0 = 立即切换）")
	ok(cfg.hover_pick_radius_tiles > 0.0,
		"★★ 悬停拾取的格半径剪枝有值（%f）" % cfg.hover_pick_radius_tiles)


func _test_shaders() -> void:
	var uf: String = UnitFlashShaderRes.code
	ok(uf.contains("INSTANCE_CUSTOM.g"), "★ 单位 shader 从每实例数据读悬停进度(.g)")
	ok(uf.contains("hover_fill_color") and uf.contains("hover_fill_alpha"),
		"★ 单位 shader 有填充色 / 强度两个 uniform")
	ok(uf.contains("ALPHA_SCISSOR_THRESHOLD"),
		"★★ 单位 shader 仍然写 scissor（不透明管线、深度正确 —— 别为了填充把它删了）")
	var ud: String = UnitDownedShaderRes.code
	ok(ud.contains("hover_fill_color"), "★ 濒死 shader 也支持悬停填充（部队里的濒死将领跟着亮）")
	ok(not ud.contains("ALPHA_SCISSOR_THRESHOLD ="), "★ 濒死 shader 仍然不写 scissor")
	var bf: String = BuildingShaderRes.code
	ok(bf.contains("INSTANCE_CUSTOM.b"), "★★ 建筑 shader 从每实例数据读悬停进度(.b)")
	ok(bf.contains("hover_fill_color"), "★ 建筑 shader 有填充色 uniform")
	ok(bf.contains("depth_draw_always"), "★★ 建筑 shader 仍然写 depth_draw_always（别删）")
	ok(bf.contains("shade"), "★ 建筑的假光照仍然作用在填充后的颜色上（不丢立体感）")


## 口径：己方 = 整支部队；敌 / 友 = 单个；拾取剪枝只是省算、不改判定口径。
func _test_unit_grouping(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	# 用一份**只有自己造的单位**的列表，避免地图预置单位干扰命中排序（跑完还原）。
	var saved: Array = w.units
	w.units = []
	w.my_faction = "p1"
	var leader = UnitRes.create(cfg, "hf_leader", "队长", Vector2i(4, 4),
		"p1", "general", "", "", "spearman", 0)
	var a1 = UnitRes.create(cfg, "hf_a1", "兵一", Vector2i(4, 5),
		"p1", "spearman", "", "hf_leader", "spearman")
	var a2 = UnitRes.create(cfg, "hf_a2", "兵二", Vector2i(5, 4),
		"p1", "spearman", "", "hf_leader", "spearman")
	var foe = UnitRes.create(cfg, "hf_foe", "敌人", Vector2i(20, 15),
		"enemy", "spearman", "", "", "spearman")
	var pal = UnitRes.create(cfg, "hf_pal", "盟友", Vector2i(24, 18),
		"p2", "spearman", "", "", "spearman")
	w.units.append(leader)
	w.units.append(a1)
	w.units.append(a2)
	w.units.append(foe)
	w.units.append(pal)
	# 一栋己方建筑（框选兜底那条路要验「框里的己方建筑」）
	var saved_buildings: Array = w.building_list
	var wall = BuildingRes.create(cfg, "wall", 8, 8, "p1")
	w.building_list = saved_buildings.duplicate()
	w.building_list.append(wall)

	var ic = InputControllerRes.new()
	ic.cfg = cfg
	ic.world = w

	# ① 悬停附属兵 → 将领 + 两个兵（整支部队）
	ic._hover_on_unit(a1)
	eq(ic.hover_unit_ids.size(), 3, "★★ 悬停己方附属兵 → 整支部队（3 个 id）")
	ok(ic.hover_unit_ids.has("hf_leader") and ic.hover_unit_ids.has("hf_a1")
		and ic.hover_unit_ids.has("hf_a2"), "★★ 整队的 id 就这三个（将领 + 两个兵）")
	ok(ic.hover_buildings.is_empty(), "★ 悬停单位时不带建筑")
	# ② 悬停将领 → 同一队
	ic._hover_on_unit(leader)
	eq(ic.hover_unit_ids.size(), 3, "★★ 悬停将领 → 同一支部队（3 个 id）")
	# ③ 敌方 → 只有它自己
	ic._hover_on_unit(foe)
	eq(ic.hover_unit_ids, ["hf_foe"], "★★ 悬停敌方单位 → 只点亮它自己（不展开它的部队）")
	# ④ 友方（盟友）→ 也只有它自己：判据是 world.my_faction，**不是** same_side
	FactionRes.set_allies([["p1", "p2"]])
	ok(FactionRes.same_side_for_attack("p2", "p1"), "（前提）p2 与 p1 是盟友")
	ic._hover_on_unit(pal)
	eq(ic.hover_unit_ids, ["hf_pal"], "★★ 悬停友方单位 → 仍只点亮它自己（不展开整队）")
	FactionRes.clear_allies()
	ic._clear_hover()
	ok(ic.hover_unit_ids.is_empty() and ic.hover_unit == null,
		"★ 清空后悬停状态全归零")

	# ⑤ 拖框预览：己方单位（整队）> 己方建筑（那一批）> 光标单目标
	#   `_hover_from_box()` 只读 `drag_box()`（= 两个世界点围出的矩形），与松手时
	#   `box_select` 的判据逐条一致，所以这里直接摆那两个点。
	ic.drag_start_world = Vector2(4.1, 4.1)
	ic.drag_current_world = Vector2(4.9, 4.9)       # 只框住将领一个人的脚底
	ok(ic._hover_from_box(), "★★ 框到己方单位 ⇒ 预览命中")
	eq(ic.hover_unit_ids.size(), 3, "★★ 框里只框到一个人也整队亮（3 个 id）")
	ok(ic.hover_buildings.is_empty(), "★ 有己方单位时建筑让位（优先级更低）")

	ic.drag_start_world = Vector2(8.1, 8.1)
	ic.drag_current_world = Vector2(8.9, 8.9)       # 只框住那栋己方城墙
	ok(ic._hover_from_box(), "★★ 框到己方建筑 ⇒ 预览命中")
	ok(ic.hover_unit_ids.is_empty(), "★ 只框到建筑时没有单位被点亮")
	eq(ic.hover_buildings, [Vector2i(8, 8)], "★★ 框里的己方建筑那一格被点亮")

	ic.drag_start_world = Vector2(4.1, 4.1)
	ic.drag_current_world = Vector2(8.9, 8.9)       # 单位 + 建筑同时在框里
	ok(ic._hover_from_box(), "★ 单位 + 建筑都在框里 ⇒ 仍然命中")
	eq(ic.hover_unit_ids.size(), 3, "★★ 单位优先：整队亮")
	ok(ic.hover_buildings.is_empty(), "★★ 单位优先时建筑不亮（需求：建筑优先级低于单位）")

	ic.drag_start_world = Vector2(12.0, 12.0)
	ic.drag_current_world = Vector2(13.0, 13.0)     # 空的
	ok(not ic._hover_from_box(), "★ 框里什么都没有 ⇒ 退回光标单目标那条路")

	ic.drag_start_world = Vector2(24.1, 18.1)
	ic.drag_current_world = Vector2(24.9, 18.9)     # 只有盟友（非己方）
	ok(not ic._hover_from_box(), "★★ 框到友方单位不算「己方」⇒ 不预览（同 box_select 口径）")

	ic.drag_start_world = Vector2.ZERO
	ic.drag_current_world = Vector2.ZERO
	ic._clear_hover()

	# ⑤.5 触摸端：双指框选用**屏幕矩形**判定（与 box_select_screen 逐条一致）
	var cam = make_test_camera(cfg)
	# ★ 相机必须先真的在这个视口里跑过一帧，否则 `unproject_position` 全是 0
	#   （见 pitfalls 10.3：投影 API 会退化成零值 ⇒ 屏幕框会落在原点、命中全乱）。
	await process_frame
	var screen_pal = make_test_palette(cfg, cam)
	if screen_pal != null:
		ic.palette = screen_pal
		ic.touch_mode = true
		ic.drag_screen_valid = true
		ic.drag_screen_box = ic._unit_icon_screen_rect(leader).grow(2.0)
		ok(ic._hover_from_box(), "★★ 触摸端：屏幕框罩住立牌 ⇒ 预览命中")
		eq(ic.hover_unit_ids.size(), 3, "★★ 触摸端屏幕框只碰到一个兵也整队亮")
		ok(ic.hover_from_box, "★★ 标记成「来自框选」（手机端只有这一路放行）")
		# 建筑：屏幕框罩住城墙那一格的屏幕点
		var bp: Vector2 = screen_pal.to_px(wall.center())
		ic.drag_screen_box = Rect2(bp - Vector2(2.0, 2.0), Vector2(4.0, 4.0))
		ok(ic._hover_from_box(), "★★ 触摸端：屏幕框罩住己方城墙 ⇒ 预览命中")
		ok(ic.hover_unit_ids.is_empty(), "★ 触摸端：只框到建筑时没有单位被点亮")
		eq(ic.hover_buildings, [Vector2i(8, 8)], "★★ 触摸端框里的己方建筑被点亮")
		# 屏幕框为空 ⇒ 没有预览
		var empty_p: Vector2 = screen_pal.to_px(Vector2(12.5, 12.5))
		ic.drag_screen_box = Rect2(empty_p - Vector2(2.0, 2.0), Vector2(4.0, 4.0))
		ok(not ic._hover_from_box(), "★ 触摸端空框 ⇒ 不出预览")
		ok(not ic.hover_from_box, "★ 空框不会标记成「来自框选」")
		# 没有屏幕框（老路径）⇒ 退回世界矩形
		ic.drag_screen_valid = false
		ic.drag_start_world = Vector2(4.1, 4.1)
		ic.drag_current_world = Vector2(4.9, 4.9)
		ok(ic._hover_from_box(), "★ 触摸端没有屏幕框时退回世界矩形")
		eq(ic.hover_unit_ids.size(), 3, "★ 退回世界矩形后口径不变（整队）")
		ic.touch_mode = false
		ic.drag_screen_valid = false

	# ⑥ 拾取剪枝：只省算，不改「谁算命中」的口径
	#   ★ 这个探针世界里的单位是后加的，迷雾掩码里没有它们 ⇒ 敌方会被「看不见」挡掉。
	#     这里只验拾取的距离口径，所以临时把本世界的迷雾摘掉（跑完还原）。
	var saved_fog = w.fog
	w.fog = null
	var saved_pad: float = cfg.unit_hit_pad_px
	cfg.unit_hit_pad_px = cfg.cell_px * 3.0      # 脚底圆半径 ≈ 3 格，好观察剪枝
	var probe: Vector2 = foe.pos + Vector2(2.0, 0.0)
	var unpruned = ic._pick_any_unit_at(probe)
	ok(unpruned == foe, "★ 不剪枝时：2 格外（在放大后的命中圆内）也算命中")
	var pruned = ic._pick_any_unit_at(probe, 0.5)
	ok(pruned == null, "★★ 剪枝半径 0.5 格 → 先被距离挡掉（不会为每个兵投一次屏）")
	var kept = ic._pick_any_unit_at(probe, 2.5)
	ok(kept == foe, "★ 剪枝半径 2.5 格 → 命中不变（只是省算）")
	cfg.unit_hit_pad_px = saved_pad
	w.fog = saved_fog

	w.units = saved
	w.building_list = saved_buildings
	ic.free()


func _test_views(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	ok(game.start(), "3D 游戏场景装得起来")
	if game.world == null:
		game.queue_free()
		return
	await process_frame
	await process_frame
	game.set_process(false)          # 冻住主循环，让计数确定

	var w = game.world
	var units = game.units
	var buildings = game.buildings

	# ① 单位：己方整队被点亮，**不新增批次**（钉住「不加 MultiMesh 变体桶」这条契约）
	units.set_hover([])
	units.sync(0.2)
	var base_batches: int = units.mesh_batch_count
	var base_created: int = units.batches_created
	var target = null
	for u in w.units:
		if u.alive and units._visible_to_me(u):
			target = u
			break
	if target != null:
		var team: Array = w.group_of(target)
		game.input_ctrl._hover_on_unit(target)
		eq(game.input_ctrl.hover_unit_ids.size(), team.size(),
			"★★ 悬停己方单位 → hover_unit_ids = 整支部队（%d）" % team.size())
		units.set_hover(game.input_ctrl.hover_unit_ids)
		units.sync(0.2)
		var expect := 0
		for m in team:
			if m.alive and units._visible_to_me(m):
				expect += 1
		eq(units.hover_instance_count, expect,
			"★★ 被填充的实例数 = 可见的队伍人数（%d）" % expect)
		eq(units.mesh_batch_count, base_batches,
			"★★ 悬停不新增 MultiMesh 批次（%d == %d）" % [units.mesh_batch_count, base_batches])
		eq(units.batches_created, base_created, "★★ 也不会新建批次")
		# 淡出：0.2s 足够走完 0.1s 的淡出
		units.set_hover([])
		units.sync(0.2)
		eq(units.hover_instance_count, 0, "★ 移开鼠标后填充退回 0（淡出完成）")
	else:
		ok(false, "地图里找不到可用于悬停测试的己方单位")

	# ② 建筑：只有鼠标底下那一栋 .b > 0
	var b0 = null
	for b in w.building_list:
		if b.alive and buildings._visible_to_me(b):
			b0 = b
			break
	if b0 != null:
		buildings.set_hover([Vector2i(b0.tx, b0.ty)])
		buildings.sync(0.2)
		eq(buildings.hovered_last_frame, 1, "★★ 只有鼠标底下那一栋建筑被填充")
		# ★ 不读 MultiMesh 的逐实例数据：实测（Godot 4.7 + 无头）`get_instance_transform` /
		#   `get_instance_custom_data` **读不回**刚写进去的值（见 unit_view_3d 的同一处注释），
		#   所以钉的是建筑层自己的进度表（真实的一手数据）。
		eq(buildings._hover_anim.size(), 1, "★★ 进度表里正好一栋（那一栋）")
		ok(absf(float(buildings._hover_anim.values()[0]) - 1.0) < 0.01,
			"★★ 0.2s ≥ hover_fill_sec(0.1s) ⇒ 进度满 1.0")
		buildings.set_hover([])
		buildings.sync(0.2)
		eq(buildings.hovered_last_frame, 0, "★ 移开后建筑填充归零")
		ok(buildings._hover_anim.is_empty(), "★ 进度表清空（不会一直留着）")
	else:
		ok(false, "地图里找不到可用于悬停测试的建筑")

	# ③ 触摸端门：只有**双指框选预览**放行（没有悬停这一说）
	game.input_ctrl.hover_unit_ids = ["dummy"]
	game.input_ctrl.hover_buildings = [Vector2i(0, 0)]
	game.touch_device = false
	game.input_ctrl.hover_from_box = false
	eq(game._hover_ids_for_view(), ["dummy"], "★ 桌面端把悬停 id 交给视图层")
	eq(game._hover_buildings_for_view().size(), 1, "★ 桌面端把悬停建筑交给视图层")
	game.touch_device = true
	ok(game._hover_ids_for_view().is_empty(), "★★ 触摸端非框选 ⇒ 不出单位遮罩")
	ok(game._hover_buildings_for_view().is_empty(), "★★ 触摸端非框选 ⇒ 不出建筑遮罩")
	game.input_ctrl.hover_from_box = true
	eq(game._hover_ids_for_view(), ["dummy"], "★★ 触摸端双指框选预览照常出遮罩")
	eq(game._hover_buildings_for_view().size(), 1, "★★ 触摸端框选预览也管建筑")
	game.touch_device = false
	game.input_ctrl.hover_from_box = false
	game.input_ctrl._clear_hover()

	game.queue_free()
	await process_frame
