## test_view.gd —— 渲染层冒烟测试（M1 + M3/M4 的「接线对不对」那部分）
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：走 `main._on_test_pressed()` 直连默认地图
##   （界面入口已改为 test_1/2/3 与战役菜单，那两条走的是关卡路径）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const PaletteRes = preload("res://view/palette.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_view"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return

	await process_frame

	_test_palette(cfg)
	_test_font(cfg)

	await _test_scene_tree(cfg)
	await _test_frames_and_input(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_palette(cfg) -> void:
	var cam := make_test_camera(cfg, cfg.cols, cfg.rows)
	var pal := make_test_palette(cfg, cam)
	ok(pal != null, "★ 造得出 palette 实例（3D：它持有 Camera3D）")
	if pal == null:
		return

	var near_tile: PackedVector2Array = pal.tile_poly(10, 20)   # 靠近镜头（格 y 大）
	var far_tile: PackedVector2Array = pal.tile_poly(10, 2)     # 远离镜头
	var near_h: float = absf(near_tile[3].y - near_tile[0].y)
	var far_h: float = absf(far_tile[3].y - far_tile[0].y)
	ok(near_h > far_h * 1.05,
		"★★ 近大远小：近处的格子比远处的高（%.1f > %.1f px）" % [near_h, far_h])
	ok(near_h / far_h > 1.05, "★ 收缩比可测（%.2f 倍）" % (near_h / far_h))

	var t0: PackedVector2Array = pal.tile_poly(5, 4)
	ok(t0.size() == 4, "tile_poly 返回 4 个顶点")
	if t0.size() == 4:
		near(t0[0].y, t0[1].y, 1e-3, "★ 地块的上边是**水平**的（相机没绕竖轴转）")
		near(t0[2].y, t0[3].y, 1e-3, "★ 地块的下边是**水平**的")
		var vp: Variant = _edge_intersection(t0[0], t0[3], t0[1], t0[2])
		ok(vp != null, "★ 地块的两条竖边不平行 ⇒ 交出一个灭点")
		var q_a: PackedVector2Array = pal.tile_poly(2, 4)
		var q_b: PackedVector2Array = pal.tile_poly(24, 4)
		var vp_a: Variant = _edge_intersection(q_a[0], q_a[3], q_a[1], q_a[2])
		var vp_b: Variant = _edge_intersection(q_b[0], q_b[3], q_b[1], q_b[2])
		if vp != null and vp_a != null and vp_b != null:
			var vpv: Vector2 = vp
			v2_near(vp_a, vpv, 1.0, "★ 左侧格子的竖边指向同一个灭点")
			v2_near(vp_b, vpv, 1.0, "★ 右侧格子的竖边指向同一个灭点（两侧没有反向）")
			var vp_center: Vector2 = pal.to_px(Vector2(13.5, 11.0))
			ok(vpv.y < vp_center.y,
				"★ 灭点在屏幕中心**上方**（俯视：竖边向上收敛，实测 y = %.1f，中心 %.1f）"
				% [vpv.y, vp_center.y])
		var top_w: float = absf(t0[1].x - t0[0].x)
		var bot_w: float = absf(t0[2].x - t0[3].x)
		ok(bot_w > top_w, "★ 地块是**梯形**：下边（近）比上边（远）长（%.1f > %.1f）"
			% [bot_w, top_w])

	var p := Vector2(2.0, 3.0)
	var px: Vector2 = pal.to_px(p)
	v2_near(pal.to_logic(px), p, 1e-3, "★ to_logic 是 to_px 的逆")
	for q: Vector2 in [Vector2(0.0, 0.0), Vector2(26.9, 21.9), Vector2(13.5, 0.1),
			Vector2(0.1, 21.5), Vector2(6.5, 5.5)]:
		v2_near(pal.to_logic(pal.to_px(q)), q, 1e-2,
			"★ 互逆（格 %s）" % str(q))

	var flat = ConfigRes.load_default()
	ok(flat != null, "能再载入一份配置（回退口径用）")
	if flat != null:
		flat.cam_pitch = PI * 0.5
		flat.set_viewport_size(flat.proj_vp_w, flat.proj_vp_h)
		var flat_pal := make_test_palette(flat, make_test_camera(flat, flat.cols, flat.rows))
		var f1: PackedVector2Array = flat_pal.tile_poly(10, 20)
		var f2: PackedVector2Array = flat_pal.tile_poly(10, 2)
		var h1: float = absf(f1[3].y - f1[0].y)
		var h2: float = absf(f2[3].y - f2[0].y)
		near(h1, h2, 0.5, "★ 俯角 90°（正俯视）时远近格高相同 ⇒ 退化成仿射")
		var wt: float = absf(f1[1].x - f1[0].x)
		var wb: float = absf(f1[2].x - f1[3].x)
		near(wt, wb, 0.5, "★ 俯角 90° 时上下边等长 ⇒ 地块是矩形")

	var mr := _aabb_of(pal.tile_poly(0, 0))
	mr = mr.merge(_aabb_of(pal.tile_poly(3, 0)))
	mr = mr.merge(_aabb_of(pal.tile_poly(3, 2)))
	mr = mr.merge(_aabb_of(pal.tile_poly(0, 2)))
	ok(mr.size.x > 0.0 and mr.size.y > 0.0, "地图外接框非退化")
	for v in pal.tile_poly(0, 0):
		ok(mr.grow(0.5).has_point(v), "★ 外接框真的套住了地图的角点")

	var near_pos := Vector2(10.0, 20.0)     # 离镜头近
	var far_pos := Vector2(10.0, 2.0)       # 离镜头远
	var span_near := _cell_span_px(pal, near_pos)
	var span_far := _cell_span_px(pal, far_pos)
	var u_rad: float = cfg.unit_radius_of(UnitRes.UNIT_TYPE_SPEARMAN)
	var r_near: float = u_rad * span_near.y
	var r_far: float = u_rad * span_far.y
	ok(span_near.y > 0.0 and span_far.y > 0.0, "★ 单位所在的两格都能投到屏幕上（跨度非零）")
	ok(r_near > r_far, "★★ 单位半径也随透视缩放（近 %.2f px > 远 %.2f px）" % [r_near, r_far])

	var w0 = require_world(cfg)
	var base_b = w0.find_base_of("p1")
	ok(base_b != null, "取得到大本营建筑")
	if base_b != null:
		var base_poly: PackedVector2Array = pal.building_poly(base_b)
		ok(base_poly.size() == 4, "建筑本体是一个四边形")
		var base_mid := _aabb_of(base_poly).get_center()
		v2_near(base_mid, pal.to_px(base_b.center()), 2.0,
			"★ 建筑块与格心同心（外接框中心 = 投影后的格心）")
		var tile_r := _aabb_of(pal.tile_poly(base_b.tx, base_b.ty))
		var base_r := _aabb_of(base_poly)
		ok(base_r.size.x < tile_r.size.x + 1e-3, "大本营比整格窄（内缩留出地面）")
		var wall = w0.add_building("wall", base_b.tx + 1, base_b.ty, "p1")
		if wall != null:
			var wp: PackedVector2Array = pal.building_poly(wall)
			var wq: PackedVector2Array = pal.tile_poly(wall.tx, wall.ty)
			near(_aabb_of(wp).size.x, _aabb_of(wq).size.x, 0.5,
				"★ 城墙填满整格（宽度与地块一致）")

func _aabb_of(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)

func _edge_intersection(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> Variant:
	var d1 := a2 - a1
	var d2 := b2 - b1
	var den := d1.cross(d2)
	if absf(den) < 1e-9:
		return null
	var t: float = (b1 - a1).cross(d2) / den
	return a1 + d1 * t

func _cell_span_px(pal, cell: Vector2) -> Vector2:
	var p0: Vector2 = pal.to_px(cell)
	var px: Vector2 = pal.to_px(cell + Vector2(1.0, 0.0))
	var py: Vector2 = pal.to_px(cell + Vector2(0.0, 1.0))
	return Vector2(p0.distance_to(px), p0.distance_to(py))

func _test_font(cfg) -> void:
	var font = FontLoaderRes.load_font(cfg)
	ok(font != null, "能载入中文字体（拷过 tools/setup-font.ps1？）")
	if font != null:
		ok(font.has_char("军".unicode_at(0)), "字体真的有中文字形（军）")
		ok(font.has_char("城".unicode_at(0)), "字体真的有中文字形（城）")
	var theme = FontLoaderRes.build_theme(cfg, 15)
	if font != null:
		ok(theme != null and theme.default_font != null, "能做出带中文字体的 Theme")
	else:
		ok(theme == null, "没有字体时 build_theme 返回 null（不崩，退回引擎默认字体）")

func _enter_game(packed):
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	return main

func _test_scene_tree(cfg) -> void:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return
	ok(packed is PackedScene, "main.tscn 是 PackedScene（裸脚本不行，实测会启动失败）")

	var main = await _enter_game(packed)
	ok(main != null, "主场景能实例化")
	if main == null:
		return
	ok(main.is_inside_tree(), "主场景真的挂上树了（await process_frame 之后）")

	var game = main.game
	ok(game != null, "★ 按下 test 之后建出了游戏内场景（在 main 根上找 world 是找不到的）")
	if game == null:
		main.queue_free()
		return

	ok(game.world != null, "游戏内场景建出了逻辑世界")
	ok(game.cfg != null, "游戏内场景载入了配置")
	ok(game.cam != null, "游戏内场景建了相机")

	for node_name in ["Camera3D", "GroundView3D", "UnitView3D", "BuildingView3D",
			"OverlayLayer", "InputController", "Hud"]:
		ok(game.get_node_or_null(node_name) != null, "节点树里有 %s" % node_name)
	var cam3: Camera3D = game.get_node_or_null("Camera3D")
	if cam3 != null:
		ok(cam3.get_parent() == game, "★ 相机与内容**并列**挂在根下（不是内容的父节点）")
		for node_name in ["GroundView3D", "UnitView3D", "BuildingView3D"]:
			var n = game.get_node_or_null(node_name)
			ok(n != null and n.get_parent() == game, "%s 与相机并列（相机不是它的父节点）" % node_name)

	ok(game.cam is Camera3D and game.cam.fov > 0.0 and game.cam.fov < 180.0,
		"相机是配好的 Camera3D（fov 合法）")

	ok(not (game.world is Node), "★ world 不是 Node（逻辑层与场景树分离）")

	var uv = game.unit_view
	ok(uv != null, "unit_view 存在（3D 版是 units 的别名）")
	if uv != null:
		var unit_batches := 0
		for ch in uv.get_children():
			if String(ch.name).begins_with("Units_"):
				unit_batches += 1
		ok(unit_batches <= 4,
			"★ unit_view 不为每个单位建节点（只有每变体一个 Units_* 批次，实测 %d 个）"
			% unit_batches)

	game.unit_view.set_selection([game.world.units[0].id])
	_assert_unit_multimesh(game)

	main.queue_free()
	await process_frame

func _test_frames_and_input(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var main = await _enter_game(packed)
	var game = main.game
	if game == null:
		ok(false, "进游戏失败：拿不到 GameScene（后面这些断言全都不会执行）")
		main.queue_free()
		return

	var world = game.world
	var t0: float = world.time
	for i in 30:
		await process_frame

	ok(world.time > t0, "跑 30 帧后世界时间前进（主循环真的在推进逻辑）")

	var u = world.units[0]
	var group_size: int = world.group_of(u).size()
	game.input_ctrl.select_units([u])
	eq(game.input_ctrl.selected_units.size(), group_size,
		"★ 选中将领 1 会同步选中整队（1 + %d 个附属兵）" % (group_size - 1))
	ok(u.selected, "选中后逻辑单位的 selected 标志被置上（view 写的是存在的字段）")
	var sub_selected := 0
	for su in game.input_ctrl.selected_units:
		if su.leader_id == u.id:
			sub_selected += 1
	eq(sub_selected, group_size - 1, "整队里的附属兵也都被选中了")

	var before = u.pos
	var all_ids: Array = []
	for su in game.input_ctrl.selected_units:
		all_ids.append(su.id)
	game._on_command({
		"kind": "move", "ids": all_ids,
		"x": before.x + 3.0, "y": before.y,
		"faction": world.my_faction,
	})
	ok(u.moving, "move 命令让单位进入移动状态")
	var sub_moving := 0
	for su in world.retinue_of(u.id):
		if su.moving:
			sub_moving += 1
	eq(sub_moving, world.retinue_of(u.id).size(), "★ 附属兵也收到了同一条移动命令（都进入移动状态）")
	for i in 120:
		await process_frame
	ok(u.pos.distance_to(before) > 0.05, "跑 120 帧后单位真的动了（命令 → 逻辑 → 渲染这条线通了）")

	var free = Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			# ★ 建造新规则：只能在自己区划里建 —— 找空地时也按这个口径（否则建造命令会被拒）
			if world.can_build_at(tx, ty, String(world.my_faction)):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格可建造的空地")
	if free.x >= 0:
		world.resources["food"] = 1000.0
		world.resources["gold"] = 1000.0
		ok(CommandRes.apply(world, cfg, {"kind": "build", "build_type": "tower", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"建造命令落成")
		await process_frame
		ok(world.building_at(free.x, free.y) != null, "建筑在渲染前就已经在逻辑里了")
		ok(CommandRes.apply(world, cfg, {"kind": "demolish", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"拆除命令生效")
		await process_frame

	CommandRes.apply(world, cfg, {"kind": "spawn_enemy", "faction": "enemy"})
	ok(world.alive_units_of("enemy").size() >= 1, "调试刷敌人成功")
	for i in 60:
		await process_frame
	ok(game.hud != null, "HUD 还在（翻译事件不会炸）")

	_test_zoom_direction(cfg, game)
	_test_fixed_view_range(cfg, game)
	_test_middle_drag_pan(cfg, game)
	_test_fullscreen_hotkey(main)

	main.queue_free()
	await process_frame

func _test_fullscreen_hotkey(main) -> void:
	ok(main._handle_window_hotkey(_key_event(KEY_Q, true)),
		"★ Ctrl+Q 被 main 的全屏快捷键消费")
	ok(not main._handle_window_hotkey(_key_event(KEY_Q, false)),
		"单独按 Q **不**触发全屏（它仍然是命令卡的键）")
	ok(not main._handle_window_hotkey(_key_event(KEY_F, true)),
		"别的键 + Ctrl 也不触发全屏")
	ok(main._handle_window_hotkey(_key_event(KEY_Q, true)),
		"★ Ctrl+Q 是**切换**（再按一次仍然被消费，不是单向）")

func _key_event(code: int, ctrl: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	ev.ctrl_pressed = ctrl
	return ev

func _test_zoom_direction(cfg, game) -> void:
	var input_ctrl = game.input_ctrl
	var center := Vector2(400.0, 300.0)

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	up.position = center
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	down.position = center

	var z0: float = game.zoom
	ok(input_ctrl.handle_mouse_button(up), "滚轮向上被消费")
	ok(game.zoom < z0, "★ 向上滚 = 拉近（相机距离倍率变小；方向按实测核准）")

	var z1: float = game.zoom
	ok(input_ctrl.handle_mouse_button(down), "滚轮向下被消费")
	ok(game.zoom > z1, "★ 向下滚 = 拉远（相机距离倍率变大）")

	for i in 60:
		input_ctrl.handle_mouse_button(up)
	ok(game.zoom >= 0.1 - 1e-6, "★ 一直往上滚 = 夹在距离下限（最紧视野）")
	for i in 120:
		input_ctrl.handle_mouse_button(down)
	ok(game.zoom <= 0.3 + 1e-6, "★ 一直往下滚 = 夹在距离上限（最远视野）")

func _test_fixed_view_range(cfg, game) -> void:
	var input_ctrl = game.input_ctrl
	var center := Vector2(400.0, 300.0)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	up.position = center
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	down.position = center

	for i in 60:
		input_ctrl.handle_mouse_button(up)
	var z_tight: float = game.zoom
	for i in 120:
		input_ctrl.handle_mouse_button(down)
	var z_wide: float = game.zoom
	ok(z_wide > z_tight,
		"★ 最远视野确实比最紧视野看得多（距离 %.3f -> %.3f）" % [z_tight, z_wide])
	ok(z_wide / maxf(1e-6, z_tight) >= 2.0,
		"★ 缩放区间足够宽（最远 / 最紧 = %.2f ≥ 2.0）" % (z_wide / maxf(1e-6, z_tight)))

func _test_middle_drag_pan(cfg, game) -> void:
	var input_ctrl = game.input_ctrl
	game.center_on_tile(Vector2(float(game.world.map.cols) * 0.5, float(game.world.map.rows) * 0.5))
	game.cam.force_update_transform()
	var before: Vector3 = game.cam.global_position

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	press.position = Vector2(900.0, 540.0)
	ok(input_ctrl.handle_mouse_button(press), "中键按下被消费")
	ok(input_ctrl.is_panning(), "★ 中键按下 → 进入平移态")

	var move := InputEventMouseMotion.new()
	move.position = press.position + Vector2(120.0, 0.0)
	ok(input_ctrl.handle_mouse_motion(move), "★ 中键拖拽期间，鼠标移动被消费（不落进框选）")
	game.cam.force_update_transform()
	var after: Vector3 = game.cam.global_position
	ok(after.x < before.x - 1.0,
		"★ 光标右移 → 相机左移（世界 x：%.1f → %.1f）" % [before.x, after.x])
	ok(absf(after.z - before.z) < 1.0,
		"★ 只水平平移（相机 z 基本不动；屏幕 x 方向 = 世界 +X）")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_MIDDLE
	release.pressed = false
	ok(input_ctrl.handle_mouse_button(release), "中键抬起被消费")
	ok(not input_ctrl.is_panning(), "★ 中键抬起 → 退出平移态")

	var p2: Vector3 = game.cam.global_position
	var move2 := InputEventMouseMotion.new()
	move2.position = press.position + Vector2(240.0, 0.0)
	ok(not input_ctrl.handle_mouse_motion(move2), "★ 抬起后鼠标移动不再被平移消费")
	ok(game.cam.global_position.distance_to(p2) < 1e-3, "★ 抬起后相机不再动（无残留）")

func _assert_unit_multimesh(game) -> void:
	var uv = game.unit_view
	if uv == null:
		ok(false, "单位层存在")
		return
	uv.sync()
	var expect := 0
	for u in game.world.units:
		if u.alive and uv._visible_to_me(u):
			expect += 1
	eq(uv.instance_count, expect, "★ 单位层实例数 = 可见单位数（%d）" % expect)
	ok(uv.instance_count > 0, "★ 真有单位被写进 MultiMesh（写 0 个 = 一个都看不见）")
	ok(uv.mesh_batch_count <= 8,
		"★ 批次数受控（%d ≤ 8：每种「阵营 × 将领」变体一个批次）" % uv.mesh_batch_count)
