## bench_hover_shot.gd —— 悬停高亮的**观感截图**（只用于人工验收，不是断言）
##
## 用法（工程根下）：
##   <godot_console.exe> --path . --script res://tests/bench_hover_shot.gd
## 输出：`res://shots/hover_*.png`
##
## ★ 不参与 tools/run-tests.ps1（只跑 test_*.gd）。
## ★ 必须用 **带窗口** 的引擎跑（`--headless` 拿不到视口图像）。
## ★ 做法：先把镜头摆好，然后 `game.set_process(false)` 冻住主循环，
##   再手工调 `units.set_hover()` / `buildings.set_hover()` + `sync()` ——
##   否则每帧的 `poll_mouse()` 会按真实鼠标位置把悬停态覆盖掉。
extends SceneTree

const MainScene := preload("res://view/main.tscn")
const MapLibraryRes = preload("res://logic/map_library.gd")
const Game3DRes = preload("res://view/game_scene3d.gd")
const FactionRes = preload("res://logic/faction.gd")
const UnitRes = preload("res://logic/unit.gd")

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
		printerr("[HOVER-SHOT] 进不了游戏")
		quit(1)
		return
	var w = game.world
	var units = game.units
	var buildings = game.buildings

	# ---------------- ① 己方单位：整支部队一起亮 ----------------
	var own = _find_own_squad(w)
	if own != null:
		var team: Array = w.group_of(own)
		# 把队伍摆成 2×2 一小簇（只为截图；`game.set_process(false)` 之后不会再被推走）
		var anchor := Vector2(float(own.tx) + 1.5, float(own.ty) + 1.5)
		var spots := [Vector2(-0.45, -0.45), Vector2(0.45, -0.45),
			Vector2(-0.45, 0.45), Vector2(0.45, 0.45), Vector2(0.0, 0.0)]
		for i in mini(team.size(), spots.size()):
			team[i].pos = anchor + spots[i]
			team[i].sync_tile(w.map)
		w.fog.update(w)
		await _focus(game, anchor, 0.12)
		game.set_process(false)
		units.set_hover([])
		units.sync(0.2)
		var ids: Array = []
		for m in team:
			ids.append(m.id)
		# ① 常态视野（最远）：看白边在实际游玩尺度下是否还看得清
		game.zoom = Game3DRes.ZOOM_MAX
		game.center_on_tile_precise(anchor)
		units.set_hover(ids)
		units.sync(0.2)
		await _shoot("hover_00_gameplay")
		# ② 近景：看细节
		await _focus(game, anchor, 0.12)
		units.set_hover(ids)
		units.sync(0.2)
		await _shoot("hover_01_own_squad")
		# 选中后再悬停：白边要压过金边
		units.set_selection(ids)
		units.set_hover(ids)
		units.sync(0.2)
		await _shoot("hover_02_own_squad_selected")
		units.set_selection([])
		units.set_hover([])
		units.sync(0.2)
	else:
		printerr("[HOVER-SHOT] 找不到己方部队")

	# ---------------- ② 敌方单位：只亮它自己 ----------------
	var mine = _find_own_unit(w)
	var foe = null
	if mine != null:
		var tx: int = int(mine.tx) + 2
		var ty: int = int(mine.ty)
		foe = w.spawn_enemy(tx, ty)
		if foe == null:
			foe = w.spawn_enemy()
		if foe != null:
			w.fog.update(w)
			await _focus(game, Vector2(float(foe.tx) + 1.0, float(foe.ty) + 1.0), 0.12)
			game.set_process(false)
			units.set_hover([])
			units.sync(0.2)
			units.set_hover([foe.id])
			units.sync(0.2)
			await _shoot("hover_03_enemy_unit")
			units.set_hover([])
			units.sync(0.2)

	# ---------------- ③ 己方建筑：白边 + 纯阵营色 ----------------
	var b = _find_own_building(w, buildings)
	if b != null:
		await _focus(game, Vector2(float(b.tx) + 0.5, float(b.ty) + 0.5), 0.11)
		game.set_process(false)
		units.set_hover([])
		units.sync(0.2)
		buildings.set_fade_marked(units.fade_marked())
		buildings.set_hover([])
		buildings.sync(0.2)
		await _shoot("hover_04_building_before")
		buildings.set_hover([Vector2i(b.tx, b.ty)])
		buildings.sync(0.2)
		await _shoot("hover_05_building_hover")
		# ③.5 再挑一堵矮墙 / 哨塔：低矮方块的描边更接近常态
		var bw = _find_own_building_type(w, buildings, "wall")
		if bw == null:
			bw = _find_own_building_type(w, buildings, "tower")
		if bw != null:
			buildings.set_hover([])
			buildings.sync(0.2)
			await _focus(game, Vector2(float(bw.tx) + 0.5, float(bw.ty) + 0.5), 0.11)
			game.set_process(false)
			buildings.set_hover([Vector2i(bw.tx, bw.ty)])
			buildings.sync(0.2)
			await _shoot("hover_05b_wall_hover")

	# ---------------- ④ 区划中心：周围有单位 ⇒ 淡出；悬停 ⇒ 淡回不透明 ----------------
	var zc = _find_zone_center(w)
	if zc != null and mine != null:
		# 把一个己方单位挪到中心**旁边一格**（仍在 3×3 内 ⇒ 建筑会淡出，但不会挡住旗杆）
		mine.pos = Vector2(float(zc.tx) + 1.35, float(zc.ty) + 0.5)
		mine.sync_tile(w.map)
		w.fog.update(w)
		await _focus(game, Vector2(float(zc.tx) + 0.5, float(zc.ty) + 0.5), 0.1)
		game.set_process(false)
		units.set_hover([])
		units.sync(0.2)
		buildings.set_fade_marked(units.fade_marked())
		buildings.set_hover([])
		buildings.sync(0.2)
		await _shoot("hover_06_zone_faded")
		buildings.set_hover([Vector2i(zc.tx, zc.ty)])
		buildings.sync(0.2)
		await _shoot("hover_07_zone_hover")

	# ---------------- ⑤ 选中金边：区划中心 / 己方建筑 / 敌方建筑 ----------------
	if mine != null and zc != null:
		# 先把单位挪远，取消淡出，单看金边
		mine.pos = Vector2(float(zc.tx) + 5.0, float(zc.ty) + 0.5)
		mine.sync_tile(w.map)
		w.fog.update(w)
	units.sync(0.2)
	buildings.set_fade_marked(units.fade_marked())
	buildings.set_hover([])
	buildings.sync(0.2)
	if zc != null:
		var zz = w.zone_by_id(int(zc.zone_id))
		if zz != null:
			game.input_ctrl.select_zone(zz)
			buildings.set_selected(game._selected_building_tiles_for_view())
			await _focus(game, Vector2(float(zc.tx) + 0.5, float(zc.ty) + 0.5), 0.1)
			buildings.sync(0.2)
			await _shoot("hover_08_zone_selected")
	if b != null:
		game.input_ctrl.select_building(b)
		buildings.set_selected(game._selected_building_tiles_for_view())
		await _focus(game, Vector2(float(b.tx) + 0.5, float(b.ty) + 0.5), 0.11)
		buildings.sync(0.2)
		await _shoot("hover_09_building_selected")
		# 同时选中 + 悬停：白色应覆盖金色
		buildings.set_hover([Vector2i(b.tx, b.ty)])
		buildings.sync(0.2)
		await _shoot("hover_11_selected_and_hovered")
		# 选中 + 旁边站一个单位：选中也要把淡出收回去（与悬停同一条不透明度）
		buildings.set_hover([])
		if mine != null:
			mine.pos = Vector2(float(b.tx) + 1.2, float(b.ty) + 0.5)
			mine.sync_tile(w.map)
			w.fog.update(w)
		units.sync(0.2)
		buildings.set_fade_marked(units.fade_marked())
		buildings.set_selected(game._selected_building_tiles_for_view())
		buildings.sync(0.2)
		await _shoot("hover_12_selected_near_unit")
	var eb = _find_visible_enemy_building(w, buildings)
	if eb != null:
		game.input_ctrl.select_enemy(eb)
		buildings.set_selected(game._selected_building_tiles_for_view())
		await _focus(game, Vector2(float(eb.tx) + 0.5, float(eb.ty) + 0.5), 0.11)
		buildings.sync(0.2)
		await _shoot("hover_10_enemy_building_selected")

	print("[HOVER-SHOT] done")
	quit(0)


func _find_own_unit(w):
	for u in w.units:
		if u.alive and String(u.faction) == String(w.my_faction):
			return u
	return null


func _find_own_squad(w):
	var own = null
	for u in w.units:
		if not u.alive or String(u.faction) != String(w.my_faction):
			continue
		if own == null:
			own = u
		var team: Array = w.group_of(u)
		if team.size() >= 2:
			return u
	if own == null:
		return null
	# 默认地图开局可能只有将领一个人：补两个兵，专门用来截「整支部队一起亮」
	for i in 3:
		var u2 = UnitRes.create(w.cfg, "shot_hover_%d" % i, "兵%d" % (i + 1),
			Vector2i(int(own.tx) + 1, int(own.ty) + i), String(w.my_faction),
			"spearman", "", String(own.id), "spearman")
		w.units.append(u2)
	w.fog.update(w)
	return own


func _find_own_building(w, buildings):
	for b in w.building_list:
		if b == null or not b.alive:
			continue
		if String(b.owner) != String(w.my_faction):
			continue
		if String(b.type) == "zone_center":
			continue
		if buildings._visible_to_me(b):
			return b
	return null


func _find_own_building_type(w, buildings, type: String):
	for b in w.building_list:
		if b == null or not b.alive:
			continue
		if String(b.owner) != String(w.my_faction):
			continue
		if String(b.type) != type:
			continue
		if buildings._visible_to_me(b):
			return b
	return null


func _find_visible_enemy_building(w, buildings):
	for b in w.building_list:
		if b == null or not b.alive:
			continue
		if String(b.owner) == "" or String(b.owner) == String(w.my_faction):
			continue
		if String(b.type) == "zone_center":
			continue
		if buildings._visible_to_me(b):
			return b
	return null


func _find_zone_center(w):
	for b in w.building_list:
		if b != null and b.alive and String(b.type) == "zone_center":
			return b
	return null


func _centroid(team: Array) -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for u in team:
		sum += u.pos
		n += 1
	return sum / float(maxi(1, n))


func _focus(game, logic_pos: Vector2, zoom_value: float) -> void:
	game.zoom = clampf(zoom_value, Game3DRes.ZOOM_MIN, Game3DRes.ZOOM_MAX)
	game.center_on_tile_precise(logic_pos)
	await _wait(SETTLE_FRAMES)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame


func _shoot(shot_name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	if img == null:
		printerr("[HOVER-SHOT] %s: 视口拿不到图像" % shot_name)
		return
	var path := "%s/%s.png" % [OUT_DIR, shot_name]
	var err := img.save_png(path)
	print("[HOVER-SHOT] %s -> %s err=%d" % [shot_name, ProjectSettings.globalize_path(path), err])
