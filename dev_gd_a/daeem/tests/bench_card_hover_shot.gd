## bench_card_hover_shot.gd —— 卡牌悬停面板的**观感截图**（只用于人工验收，不是断言）。
##
## 用法（工程根下，**不要**加 --headless）：
##   <godot_console.exe> --path . --script res://tests/bench_card_hover_shot.gd
## 输出：`res://shots/card_hover_*.png`
##
## ★ 不参与 tools/run-tests.ps1（只跑 test_*.gd）。
## ★ 每张图之前：先 `_raise_card()` 把牌抬起来，再 `hover()` 让 hud 弹面板
##   （面板按「悬停最终姿势」定位，所以牌必须在悬停态才对得上）。
extends SceneTree

const MapLibraryRes = preload("res://logic/map_library.gd")
const MainScene := preload("res://view/main.tscn")
const PageTabsRes = preload("res://view/page_tabs.gd")
const FactionRes = preload("res://logic/faction.gd")

const OUT_DIR := "res://shots"


func _initialize() -> void:
	DisplayServer.window_set_size(Vector2i(1920, 1080))
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var main = MainScene.instantiate()
	root.add_child(main)
	await _sleep(0.5)
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await _sleep(0.6)
	var game = main.game
	if game == null:
		printerr("[CH-SHOT] 进不了游戏")
		quit(1)
		return
	var hud = game.hud
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
	await _sleep(0.6)
	var card = hud.command_card
	# 单位页有空槽位（按行解锁会留空）：挑**真的可见**的第 3 张来悬停。
	var vis: Array = card._visible_entry_indices()
	var pick: int = int(vis[mini(2, vis.size() - 1)]) if not vis.is_empty() else 0
	await _shot("card_hover_unit", hud, card, pick)

	# 建筑页（没选中东西时停在建筑页）
	ic.select_units([])
	hud.refresh()
	if hud.page_tabs != null:
		hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	await _sleep(0.5)
	await _shot("card_hover_build", hud, card, 1)

	# 将领页（没选中东西时也能开：将领牌是拖到区划中心招募的）
	ic.select_units([])
	hud.refresh()
	hud.page_tabs.select_page(PageTabsRes.PAGE_GENERAL)
	await _sleep(0.5)
	var gp: int = -1
	var gvis: Array = card._visible_entry_indices()
	for gi in gvis:
		var e: Dictionary = card.entry_at(int(gi))
		if String(e.get("type", "")) == "general_drag":
			gp = int(gi)
			break
	if gp >= 0:
		await _shot("card_hover_general", hud, card, gp)

	# 科技页
	ic.select_units([])
	hud.refresh()
	hud.page_tabs.select_page(PageTabsRes.PAGE_TECH)
	await _sleep(0.6)
	await _shot("card_hover_tech", hud, hud.tech_grid, 0)

	print("[CH-SHOT] done")
	quit(0)


func _shot(shot_name: String, hud, grid, index: int) -> void:
	grid._raise_card(index, true)
	grid.hover(index)
	await _sleep(0.4)
	var panel = hud.card_hover
	if panel != null:
		var crect: Rect2 = grid.cell_pose_rect(index, true)
		print("[CH-SHOT] %s panel=%s occ=%s card=%s overlap=%s" % [
			shot_name, panel.get_global_rect(), panel.occupied_rect(), crect,
			panel.occupied_rect().intersects(crect)])
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[CH-SHOT] %s: 视口拿不到图像" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[CH-SHOT] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
	grid._raise_card(index, false)
	grid.unhover(index)
	await _sleep(0.25)


func _sleep(sec: float) -> void:
	await create_timer(sec).timeout
