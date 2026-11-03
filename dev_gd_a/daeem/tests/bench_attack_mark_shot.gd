## bench_attack_mark_shot.gd —— 把「指定攻击」的目标标记渲染成 PNG（**只用于人工看样子**）
##
## 用法（在工程根下，**不要加 --headless**；headless 拿不到视口图像）：
##   <godot_console.exe> --path . --script res://tests/bench_attack_mark_shot.gd
## 输出：`res://shots/attack_mark_*.png`（shots/ 已在 .gitignore 里，看完随手删）
##
## 验的是两样东西（需求口径）：
##   1. 右键点**敌方单位** → 头顶浮起行军图标（与插旗图标共用素材）+ 脚底红圈；
##   2. 右键点**敌方建筑** → 同样是头顶图标 + 脚底红圈（圈按本体边长放大）。
## ⚠️ 与 tests/bench_game_shot.gd 同一类：**不参与** tools/run-tests.ps1（只跑 test_*.gd）。
## ⚠️ 必须用 _console.exe 跑（GUI 版会 detach，拿不到输出）。
## ⚠️ `--script` 模式下入口是 SceneTree 的 `_initialize()`（没有 _ready）。
extends SceneTree

const MainScene := preload("res://view/main.tscn")
const MapLibraryRes = preload("res://logic/map_library.gd")
const Game3DRes = preload("res://view/game_scene3d.gd")
const FactionRes = preload("res://logic/faction.gd")

const OUT_DIR := "res://shots"

func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1600, 900))
	_run()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var main = MainScene.instantiate()
	root.add_child(main)
	await _wait(20)
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await _wait(20)
	var game = main.game
	if game == null:
		printerr("[SHOT] 进不了游戏")
		quit(1)
		return
	var w = game.world
	game.cfg.fog_enabled = false
	game.zoom = Game3DRes.ZOOM_MIN

	var mine = null
	for u in w.units:
		if u.alive and FactionRes.same_side(u.faction, w.my_faction):
			mine = u
			break
	if mine == null:
		printerr("[SHOT] 没有己方单位")
		quit(1)
		return

	# 1) 敌方**单位**：头顶图标 + 脚底红圈（红圈 = 一次性外泛波纹）
	var foe = w.spawn_enemy(mine.tx + 3, mine.ty)
	await _wait(6)
	if foe != null:
		game.center_on_tile(foe.pos)
		game.attack_marks.mark("attack", foe)
		# ★ 按**时间**等（不是按帧）：这个窗口的帧率不受控，按帧会拍不到波纹的各个阶段
		await create_timer(0.10).timeout
		await _shoot("attack_mark_unit_a")     # 波纹刚起步（小圈）
		await create_timer(0.22).timeout
		await _shoot("attack_mark_unit_b")     # 波纹扩到最大前后
		await create_timer(0.40).timeout
		await _shoot("attack_mark_unit_c")     # 波纹已收（只剩头顶图标）

	# 2) 敌方**建筑**（挑一座可见的、非无敌的）
	var foe_b = null
	for b in w.building_list:
		if b != null and b.alive and not b.is_invulnerable() \
				and not FactionRes.same_side(b.owner, w.my_faction):
			foe_b = b
			break
	if foe_b != null:
		game.center_on_tile(Vector2(float(foe_b.tx) + 0.5, float(foe_b.ty) + 0.5))
		game.attack_marks.mark("attack", foe_b)
		await create_timer(0.30).timeout   # 波纹扩到建筑本体之外时再拍
		await _shoot("attack_mark_building")

	print("[SHOT] done")
	quit(0)

func _wait(frames: int) -> void:
	for i in frames:
		await process_frame

func _shoot(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] %s: 视口拿不到图像" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[SHOT] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
