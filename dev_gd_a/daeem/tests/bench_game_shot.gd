## bench_game_shot.gd —— 把**游戏内**某几个状态渲染成 PNG（**只用于人工看样子**）
##
## 用法（在工程根下）：
##   <godot_console.exe> --path . --script res://tests/bench_game_shot.gd
## 输出：`res://shots/*.png`（看完随手删；shots/ 已在 .gitignore 里）
##
## ⚠️ 与 tests/bench_menu_shot.gd 同一类：**不参与** tools/run-tests.ps1（只跑 test_*.gd）。
## ⚠️ 必须用 _console.exe 跑（GUI 版会 detach，拿不到输出）。
## ⚠️ `--script` 模式下入口是 SceneTree 的 `_initialize()`（没有 _ready）。
extends SceneTree

const MainScene := preload("res://view/main.tscn")
const FactionRes = preload("res://logic/faction.gd")
## ★ 缩放档位的**唯一取值处**（`game_scene3d.ZOOM_MIN/MAX`）——别在这里另写 0.1 / 0.3。
const Game3DRes = preload("res://view/game_scene3d.gd")

const OUT_DIR := "res://shots"
const SETTLE_FRAMES := 20


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var main = MainScene.instantiate()
	root.add_child(main)
	await _wait(SETTLE_FRAMES)
	# 直接进游戏（与玩家点 test 按钮同一条路）
	main._on_test_pressed(main.start_screen.selected_map_path())
	await _wait(SETTLE_FRAMES)
	var game = main.game
	if game == null:
		printerr("[SHOT] 进不了游戏")
		quit(1)
		return
	var world = game.world
	var ic = game.input_ctrl

	# 0) ★★ 全景（第一眼看观感的图）：把镜头拉到**最远**一档，看整片地形与地物
	game.zoom = Game3DRes.ZOOM_MAX
	game.camera_rig.center_on_tile(
		Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))
	await _wait(SETTLE_FRAMES)
	await _shoot("00_wide")

	# 1) 己方部队：右下角是「操作 / 单位」两页 + 命令卡有内容（对照组）
	var mine = null
	for u in world.units:
		if u.alive and FactionRes.same_side(u.faction, world.my_faction):
			mine = u
			break
	if mine != null:
		ic.select_units([mine])
		_aim(ic, mine.tx, mine.ty)
		await _wait(SETTLE_FRAMES)
		await _shoot("10_own_selected")

	# 2) 敌对单位：右下角只有一颗**空格子**
	var foe = world.spawn_enemy(6, 4)
	await _wait(SETTLE_FRAMES)
	if foe != null:
		ic.select_enemy(foe)
		# 顺手把镜头挪过去（不然它在屏幕外，看不出选中圈）
		game.camera_rig.center_on_tile(foe.pos)
		await _wait(SETTLE_FRAMES)
		await _shoot("11_enemy_unit_selected")

	# 3) 敌对建筑：同样只有一颗空格子
	#    ⚠️ 必须挑一个**看得见**的（战争迷雾：看不见的敌方建筑点不中也选不上 ——
	#      这是刻意的规则，别拿一个迷雾里的塔来「验」界面）。
	var foe_b = null
	for b in world.building_list:
		if b != null and b.alive and not b.is_invulnerable() \
				and not FactionRes.same_side(b.owner, world.my_faction) \
				and world.fog.building_visible(world.my_faction, b):
			foe_b = b
			break
	if foe_b == null:
		# 没有现成的可见敌楼：把 p1 的兵挪到最近一座敌楼旁边，把它「发现」出来
		var cand = null
		for b2 in world.building_list:
			if b2 != null and b2.alive and not b2.is_invulnerable() \
					and not FactionRes.same_side(b2.owner, world.my_faction):
				cand = b2
				break
		if cand != null and mine != null:
			mine.pos = Vector2(float(cand.tx + 2), float(cand.ty) + 0.5)
			mine.sync_tile(world.map)
			world.fog.update(world)
			if world.fog.building_visible(world.my_faction, cand):
				foe_b = cand
	if foe_b != null:
		ic.select_enemy(foe_b)
		game.camera_rig.center_on_tile(Vector2(float(foe_b.tx) + 0.5, float(foe_b.ty) + 0.5))
		await _wait(SETTLE_FRAMES)
		await _shoot("12_enemy_building_selected")

	# 4) ★★ 建筑近景（第二张「看立体感 / 遮挡」的图）：拉到**最紧**一档，把镜头放到大本营上 ——
	#    要能一眼看出「地物前后关系」与「字 / 血条有没有被盖住」。
	game.zoom = Game3DRes.ZOOM_MIN
	var home: Vector2i = world.home_base_of(world.my_faction)
	game.camera_rig.center_on_tile(Vector2(float(home.x) + 0.5, float(home.y) + 0.5))
	await _wait(SETTLE_FRAMES)
	await _shoot("13_closeup")

	print("[SHOT] done")
	quit(0)


func _aim(ic, tx: int, ty: int) -> void:
	ic.hover_tile = Vector2i(tx, ty)
	ic.mouse_world = Vector2(float(tx) + 0.5, float(ty) + 0.5)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _shoot(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] %s: 视口拿不到图像（是不是在用 --headless 跑？）" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[SHOT] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
