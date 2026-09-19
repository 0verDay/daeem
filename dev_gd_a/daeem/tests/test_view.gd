## test_view.gd —— 渲染层冒烟测试（M1 + M3/M4 的「接线对不对」那部分）
##
## 为什么值得测：真正的接线 bug（脚本访问了逻辑对象上不存在的属性、HUD 的
## Theme 字体拿不到、节点树装配顺序错）在无头模式下会打成 SCRIPT ERROR ——
## 而那类错误如果不测，第一次发现就是「打开游戏画面不对」。
## ★ 实测抓到过：view 往逻辑单位上写 `selected`，而 logic/unit.gd 里当时没有这个字段。
##
## 这个文件**不测观感**（那是手玩验收的事），只测：
##   - 逻辑坐标 ↔ 像素换算（HTML 版为它吃过一次大亏）
##   - 主场景真的能挂上树、节点树齐了
##   - 跑若干帧 + 注入点击/键盘之后，世界与渲染都不炸
##   - 中文字体能加载（否则 HUD 全是方框）
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（is_inside_tree() 仍是 false，见 pitfalls 1.2）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
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

	_test_palette(cfg)
	_test_font(cfg)

	# ★ 关键：先等一帧，root.add_child() 才会真的生效
	await process_frame
	await _test_scene_tree(cfg)
	await _test_frames_and_input(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 坐标换算：逻辑坐标一律是「格」，像素只在 view/ 出现
# ------------------------------------------------------------------
func _test_palette(cfg) -> void:
	near(PaletteRes.to_px(Vector2(2.0, 3.0), cfg).x, 2.0 * cfg.cell_px, 1e-6, "to_px 的 x")
	near(PaletteRes.to_px(Vector2(2.0, 3.0), cfg).y, 3.0 * cfg.cell_px, 1e-6, "to_px 的 y")
	v2_near(PaletteRes.to_logic(Vector2(2.5, 3.5) * cfg.cell_px, cfg), Vector2(2.5, 3.5), 1e-6, "to_logic 是 to_px 的逆")
	near(PaletteRes.unit_radius_px(cfg, "general"), cfg.unit_radius_factor * cfg.cell_px, 1e-6,
		"单位半径（像素）= 逻辑半径 × 格宽")

	var r = PaletteRes.tile_rect(3, 2, cfg)
	near(r.position.x, 3.0 * cfg.cell_px, 1e-6, "tile_rect 的 x")
	near(r.position.y, 2.0 * cfg.cell_px, 1e-6, "tile_rect 的 y")
	near(r.size.x, cfg.cell_px, 1e-6, "tile_rect 宽度 = 一格")

	# 建筑矩形：城墙填满整格，其它内缩
	var w0 = WorldRes.create(cfg)
	var base_b = w0.find_base_of("p1")
	ok(base_b != null, "取得到大本营建筑")
	if base_b != null:
		var base_rect = PaletteRes.building_rect(base_b, cfg)
		ok(base_rect.size.x < cfg.cell_px, "大本营矩形比整格小（内缩，留出地面）")
		var wall = w0.add_building("wall", base_b.tx + 1, base_b.ty, "p1")
		if wall != null:
			var wall_rect = PaletteRes.building_rect(wall, cfg)
			near(wall_rect.size.x, cfg.cell_px, 1e-6, "城墙矩形填满整个地块")


# ------------------------------------------------------------------
# 中文字体
# ------------------------------------------------------------------
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


# ------------------------------------------------------------------
# 节点树：主场景真的能挂上树
# ------------------------------------------------------------------
func _test_scene_tree(cfg) -> void:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return
	ok(packed is PackedScene, "main.tscn 是 PackedScene（裸脚本不行，实测会启动失败）")

	var main = (packed as PackedScene).instantiate()
	ok(main != null, "主场景能实例化")
	if main == null:
		return
	root.add_child(main)
	await process_frame

	ok(main.is_inside_tree(), "主场景真的挂上树了（await process_frame 之后）")
	ok(main.world != null, "主场景建出了逻辑世界")
	ok(main.cfg != null, "主场景载入了配置")
	ok(main.cam != null, "主场景建了相机")

	# 渲染节点齐了
	for node_name in ["TerrainView", "ZoneView", "BuildingView", "UnitView", "Overlay", "CameraRig", "InputController", "Hud"]:
		ok(main.get_node_or_null(node_name) != null, "节点树里有 %s" % node_name)

	# 相机是纯表现：不该进快照
	ok(main.cam.zoom.x > 0.0, "相机缩放合法（fit 之后）")

	# 逻辑与渲染是两棵树：world 不是 Node
	ok(not (main.world is Node), "★ world 不是 Node（逻辑层与场景树分离）")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 跑帧 + 注入输入：世界推进、渲染同步都不炸
# ------------------------------------------------------------------
func _test_frames_and_input(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame

	var world = main.world
	var t0: float = world.time
	for i in 30:
		await process_frame

	# headless 下 delta 可能极小，但 world.time 必须**前进**（tick 真的在跑）
	ok(world.time > t0, "跑 30 帧后世界时间前进（主循环真的在推进逻辑）")

	# 注入一次「选中 + 下令移动」：走的是命令这条路
	#
	# ★ 注意这里是**整队**选中：将领带亲兵，选中队长时会把亲兵一起带上，
	#   所以选中数不是 1 而是「1 + 亲兵数」。这正是需求要的行为，断言照实写。
	var u = world.units[0]
	var group_size: int = world.group_of(u).size()
	main.input_ctrl.select_units([u])
	eq(main.input_ctrl.selected_units.size(), group_size,
		"★ 选中将领 1 会同步选中整队（1 + %d 个亲兵）" % (group_size - 1))
	ok(u.selected, "选中后逻辑单位的 selected 标志被置上（view 写的是存在的字段）")
	var sub_selected := 0
	for su in main.input_ctrl.selected_units:
		if su.leader_id == u.id:
			sub_selected += 1
	eq(sub_selected, group_size - 1, "整队里的亲兵也都被选中了")

	var before = u.pos
	# ★ 命令要下给**整队**：这正是「右键移动同步给亲兵下达指令」那条需求，
	#   所以这里把选中列表里所有 id 都带上（input_controller 就是这么做的）
	var all_ids: Array = []
	for su in main.input_ctrl.selected_units:
		all_ids.append(su.id)
	main._on_command({
		"kind": "move", "ids": all_ids,
		"x": before.x + 3.0, "y": before.y,
		"faction": world.my_faction,
	})
	ok(u.moving, "move 命令让单位进入移动状态")
	var sub_moving := 0
	for su in world.retinue_of(u.id):
		if su.moving:
			sub_moving += 1
	eq(sub_moving, world.retinue_of(u.id).size(), "★ 亲兵也收到了同一条移动命令（都进入移动状态）")
	for i in 120:
		await process_frame
	ok(u.pos.distance_to(before) > 0.05, "跑 120 帧后单位真的动了（命令 → 逻辑 → 渲染这条线通了）")

	# 建造命令 + 拆除命令（走同一条命令流）
	var free = Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			if world.can_build_at(tx, ty):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格可建造的空地")
	if free.x >= 0:
		ok(CommandRes.apply(world, cfg, {"kind": "build", "build_type": "tower", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"建造命令落成")
		await process_frame
		ok(world.building_at(free.x, free.y) != null, "建筑在渲染前就已经在逻辑里了")
		ok(CommandRes.apply(world, cfg, {"kind": "demolish", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"拆除命令生效")
		await process_frame

	# 刷一个敌人 + 跑一会儿：覆盖「有战斗、有事件、HUD 要翻译事件」这条路径
	CommandRes.apply(world, cfg, {"kind": "spawn_enemy", "faction": "enemy"})
	ok(world.alive_units_of("enemy").size() >= 1, "调试刷敌人成功")
	for i in 60:
		await process_frame
	ok(main.hud != null, "HUD 还在（翻译事件不会炸）")

	_test_zoom_direction(cfg, main)

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 滚轮缩放方向（第一版写反过，所以钉一条回归）
# ------------------------------------------------------------------
func _test_zoom_direction(cfg, main) -> void:
	var cam: Camera2D = main.cam
	var input_ctrl = main.input_ctrl
	var center := Vector2(400.0, 300.0)

	# 先回到中间倍率，保证两个方向都有余地
	cam.zoom = Vector2.ONE
	var z0: float = cam.zoom.x

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	up.position = center
	ok(input_ctrl.handle_mouse_button(up), "滚轮向上被消费")
	ok(cam.zoom.x > z0, "★ 向上滚 = 放大（zoom 变大，画面拉近）")

	var z1: float = cam.zoom.x
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	down.position = center
	ok(input_ctrl.handle_mouse_button(down), "滚轮向下被消费")
	ok(cam.zoom.x < z1, "★ 向下滚 = 缩小（zoom 变小，画面拉远）")
	near(cam.zoom.x, z0, 1e-4, "一上一下应该回到原点")

	# 上下限必须被夹住（不能无限拉近 / 拉远）
	for i in 40:
		input_ctrl.handle_mouse_button(up)
	ok(cam.zoom.x <= cfg.num("camera.max_scale", 1.6) + 1e-6, "缩放不超过 max_scale")
	for i in 80:
		input_ctrl.handle_mouse_button(down)
	ok(cam.zoom.x >= cfg.num("camera.min_scale", 0.18) - 1e-6, "缩放不低于 min_scale")
