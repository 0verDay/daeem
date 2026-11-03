## bench_card_icon_shot.gd —— 命令卡「单位」页剪影图标的**观感截图**（人工验收用，不是断言）
##
## 用法（工程根下，★ 不加 --headless，否则拿不到视口图像）：
##   <godot_console.exe> --path . --script res://tests/bench_card_icon_shot.gd
## 输出：`res://shots/card_icon_*.png`
##
## ★ 不参与 tools/run-tests.ps1（那套只跑 test_*.gd）。
## ★ 走真实链路：进局 → 用 input_controller 选中自己的部队 → 让 hud 自己算页签
##   → 切到「单位」页。不手搓 entries，否则截出来的不是玩家会看到的画面。
## ★ 悬停那一张要**手工补发 mouse_entered**：`command_card.hover()` 只发「悬停详情」
##   那条信号（hud 用），金色填充是 fill_button 自己听 mouse_entered 起的。
extends SceneTree

const MainScene := preload("res://view/main.tscn")
const MapLibraryRes := preload("res://logic/map_library.gd")
const PageTabsRes := preload("res://view/page_tabs.gd")
const UiLayoutRes := preload("res://view/ui_layout.gd")

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
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await _wait(SETTLE_FRAMES)
	var game = main.game
	if game == null:
		printerr("[CARD-ICON] 进不了游戏")
		quit(1)
		return
	var w = game.world
	var hud = game.hud
	var own = _find_own_unit(w)
	if own == null:
		printerr("[CARD-ICON] 找不到己方单位")
		quit(1)
		return

	game.input_ctrl.select_units([own])
	await _wait(SETTLE_FRAMES)
	if hud.page_tabs != null:
		hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)
	await _wait(SETTLE_FRAMES)

	# ① 整屏（看命令卡与整个 HUD 的比例关系）
	await _shoot("card_icon_ingame")
	# ② 命令卡特写（1 级大本营：第 1 行亮、第 2/3 行锁灰）
	await _shot_card("card_icon_zoom")

	# ③ 悬停第 1 格：金色自下而上填满 → 图标要跟着翻成压金档
	game.set_process(false)
	var cell = hud.command_card.cell_at(0)
	if cell != null:
		cell.mouse_entered.emit()
	await _wait(50)
	await _shot_card("card_icon_hover")
	if cell != null:
		cell.mouse_exited.emit()

	# ④ 大本营升到 3 级：九格全部解锁（三行都亮），看满编时的观感
	var base = w.find_base_of(String(w.my_faction))
	if base != null:
		base.level = 3
		await _wait(SETTLE_FRAMES + 20)
		await _shot_card("card_icon_unlocked")

	print("[CARD-ICON] done")
	quit(0)


func _find_own_unit(w):
	for u in w.units:
		if u.alive and String(u.faction) == String(w.my_faction):
			return u
	return null


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _shoot(shot_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[CARD-ICON] %s: 视口拿不到图像（是不是在用 --headless？）" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[CARD-ICON] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])


## 只截右下角命令卡（裁切后放大 3 倍，方便看线条）。
func _shot_card(shot_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[CARD-ICON] %s: 视口拿不到图像" % shot_name)
		return
	var r := UiLayoutRes.CARD_RECT
	var region := Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y))
	var crop := img.get_region(region)
	if crop == null:
		printerr("[CARD-ICON] %s: 裁切失败" % shot_name)
		return
	crop.resize(crop.get_width() * 3, crop.get_height() * 3, Image.INTERPOLATE_NEAREST)
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := crop.save_png(path)
	print("[CARD-ICON] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
