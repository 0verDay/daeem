## bench_hand_shot.gd —— 手牌摆位 / 悬停 / 拖出 的观感回归图（**只用于人工看样子**）
##
## 用法（在工程根下，**不要**加 --headless）：
##   <godot_console.exe> --path . --script res://tests/bench_hand_shot.gd
## 输出：`res://shots/hand_*.png`
##
## ⚠️ 与 bench_game_shot.gd 同一类：**不参与** tools/run-tests.ps1（只跑 test_*.gd）。
extends SceneTree

const MapLibraryRes = preload("res://logic/map_library.gd")
const MainScene := preload("res://view/main.tscn")
const FactionRes = preload("res://logic/faction.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")

const OUT_DIR := "res://shots"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var main = MainScene.instantiate()
	root.add_child(main)
	await _sleep(0.4)
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await _sleep(0.4)
	var game = main.game
	if game == null:
		printerr("[SHOT] 进不了游戏")
		quit(1)
		return
	var world = game.world
	var ic = game.input_ctrl
	var mine = null
	for u in world.units:
		if u.alive and FactionRes.same_side(u.faction, world.my_faction):
			mine = u
			break
	if mine != null:
		ic.select_units([mine])
		ic.hover_tile = Vector2i(mine.tx, mine.ty)
		ic.mouse_world = Vector2(float(mine.tx) + 0.5, float(mine.ty) + 0.5)
	await _sleep(0.5)
	var card = game.hud.command_card
	await _shoot("hand_idle")

	# 悬停中间那张（直接调内部接口，避开真实鼠标位置）
	var vis = card._visible_entry_indices()
	var hi: int = int(vis[2]) if vis.size() >= 3 else 0
	card._raise_card(hi, true)
	await _sleep(0.3)
	await _shoot("hand_hover")
	card._raise_card(hi, false)
	await _sleep(0.3)

	# 拖出第一张可用的牌
	var di: int = int(vis[0])
	for cand in vis:
		if card._card_ready(int(cand)):
			di = int(cand)
			break
	var origin: Vector2 = card._cells[di].get_global_transform_with_canvas() \
		* (card._cells[di].size * 0.5)
	card._drag_index = di
	card._drag_start_global = origin
	card._update_drag_position(di, origin - Vector2(0.0, 60.0))
	card._update_drag_position(di, Vector2(960.0, 620.0))
	await _sleep(0.5)
	await _shoot("hand_drag")
	card.finish_touch_drag(di, Vector2(960.0, 620.0))
	await _sleep(0.8)
	await _shoot("hand_after_drag")

	# 科技页（先清空选中：选中部队时页签只有「单位」）
	if game.hud.page_tabs != null:
		ic.select_units([])
		await _sleep(0.3)
		game.hud.page_tabs.select_page(PageTabsRes.PAGE_TECH)
		await _sleep(0.8)
		await _shoot("hand_tech_idle")
		game.hud.tech_grid._raise_card(1, true)
		await _sleep(0.3)
		await _shoot("hand_tech_hover")

		# 科技牌拖到地图上：透明度应该渐到 0.3
		var tg = game.hud.tech_grid
		var tv = tg._visible_cell_indices()
		var ti: int = int(tv[0])
		var tc: Control = tg._cells[ti]
		var to: Vector2 = tc.get_global_transform_with_canvas() * (tc.size * 0.5)
		tg.begin_touch_drag(ti, to)
		tg.move_touch_drag(ti, to - Vector2(0.0, 24.0))
		tg.move_touch_drag(ti, Vector2(900.0, 400.0))
		await _sleep(0.4)
		await _shoot("hand_tech_drag")

		# 收尾：拖回手牌 = 取消（不要真的启用一条科技，后面的图会变）
		tg.finish_touch_drag(ti, to)
		await _sleep(0.4)

	print("[SHOT] done")
	quit(0)


func _sleep(sec: float) -> void:
	await create_timer(sec).timeout


func _shoot(shot_name: String) -> void:
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[SHOT] %s: 视口拿不到图像（是不是在用 --headless 跑？）" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[SHOT] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
