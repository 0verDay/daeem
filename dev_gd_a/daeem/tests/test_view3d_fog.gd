## test_view3d_fog.gd —— 3D 迷雾的**实测标定**（不是「跑一遍没炸」）
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const GroundRes = preload("res://view/ground_view.gd")

func _initialize() -> void:
	_case_name = "test_view3d_fog"
	_run()

static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

static func _win_lum(img: Image, px: int, py: int, w: int = 5) -> float:
	var h := w / 2
	var sum := 0.0
	var n := 0
	for dy in range(-h, h + 1):
		for dx in range(-h, h + 1):
			var x := px + dx
			var y := py + dy
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			sum += _lum(img.get_pixel(x, y))
			n += 1
	return sum / maxf(1.0, float(n))

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	await process_frame
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，迷雾标定无从谈起")
		game.queue_free()
		quit(1)
		return
	await process_frame
	await process_frame

	game._edge_scroll_on = false
	game.set_process(false)
	game.center_on_tile(Vector2(float(game.world.map.cols) * 0.5,
		float(game.world.map.rows) * 0.5))
	game.cam.force_update_transform()
	await process_frame
	await process_frame

	var shot := await _shot()
	if shot == null:
		print("[CASE] （跳过）无头下拿不到成图（dummy 渲染器）⇒ 迷雾浓度未实测")
		ok(cfg.fog_mask_color.a > 0.0, "（降级）迷雾遮罩 alpha 至少是个正数")
		game.queue_free()
		await process_frame
		print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
		quit(0)
		return

	var g = game.ground
	var m = game.world.map
	var cols := int(m.cols)
	var rows := int(m.rows)
	var mask = game.world.fog.sight.get(String(game.world.my_faction), null)

	game.cfg.fog_enabled = false
	g.rebake(true)
	await process_frame
	await process_frame
	var base := await _shot()
	game.cfg.fog_enabled = true
	g.rebake(true)
	await process_frame
	await process_frame
	var fogged := await _shot()
	if base == null or fogged == null:
		print("[CASE] （跳过）截图拿不到")
		game.queue_free()
		await process_frame
		quit(0)
		return

	var vp: Vector2 = game.get_viewport().get_visible_rect().size
	var scl := Vector2(float(base.get_width()) / maxf(1.0, vp.x),
		float(base.get_height()) / maxf(1.0, vp.y))
	ok(true, "（诊断）视口 %s，截图 %s，缩放 %s" % [str(vp), str(base.get_size()), str(scl)])

	var covered := 0
	var leaked := 0                 # 该被盖住却几乎没变暗
	var sum_rel := 0.0
	var worst_rel := 0.0
	var min_rel := 1.0
	for ty in rows:
		for tx in cols:
			var seen := true
			if mask is PackedByteArray:
				var i: int = ty * cols + tx
				seen = i < (mask as PackedByteArray).size() and (mask as PackedByteArray)[i] != 0
			if seen:
				continue
			var sp: Vector2 = game.palette.to_px(Vector2(float(tx) + 0.5, float(ty) + 0.5))
			var px := int(round(sp.x * scl.x))
			var py := int(round(sp.y * scl.y))
			if px < 4 or py < 4 or px >= base.get_width() - 4 or py >= base.get_height() - 4:
				continue
			var b := _win_lum(base, px, py, 5)
			if b < 0.05:
				continue                  # 地图外 / 背景
			var a := _win_lum(fogged, px, py, 5)
			var rel: float = (b - a) / maxf(1e-6, b)
			covered += 1
			sum_rel += rel
			worst_rel = maxf(worst_rel, rel)
			min_rel = minf(min_rel, rel)
			if rel < 0.05:
				leaked += 1
	var mean_rel: float = sum_rel / maxf(1.0, float(covered))
	print("[CASE] （实测）迷雾覆盖 %d 格：相对亮度下降 平均 %.1f%%，最小 %.1f%%，最大 %.1f%%；几乎没变暗的 %d 格" % [
		covered, 100.0 * mean_rel, 100.0 * min_rel, 100.0 * worst_rel, leaked])

	ok(covered > 0, "★ 屏幕上真的有被迷雾盖住的格（%d 格）" % covered)
	ok(mean_rel >= 0.15,
		"★★ 迷雾的平均亮度下降 ≥ 15%%（实测 %.1f%%；dev_plan_10 说 0.45 只有 10.6%%）"
		% (100.0 * mean_rel))
	var leak_ratio: float = float(leaked) / maxf(1.0, float(covered))
	ok(leak_ratio <= 0.40,
		"★ 「该被迷雾盖住却几乎没变暗」的格不超过 40%%（实测 %d/%d = %.1f%%；成片才是 UV / z-fighting 错）"
		% [leaked, covered, 100.0 * leak_ratio])
	ok(game.cfg.fog_mask_color.a >= 0.7,
		"★ 配置里的遮罩 alpha 已经调到 ≥ 0.7（实测 %.2f）" % game.cfg.fog_mask_color.a)

	var gimg: Image = g._tex.get_image()
	var marked := gimg.duplicate() as Image
	var k: int = GroundRes.PX_PER_TILE
	for pxx in cols * k:
		for py in k:
			marked.set_pixel(pxx, 2 * k + py, Color(1, 0, 0, 1))
	g._mat.albedo_texture = ImageTexture.create_from_image(marked)
	await process_frame
	await process_frame
	var marked_shot := await _shot()
	g._mat.albedo_texture = g._tex          # 还原
	await process_frame
	if marked_shot != null:
		var red_row := _find_marked_row(marked_shot, scl, game, cols, rows)
		print("[CASE] （实测）贴图第 2 行涂红 ⇒ 屏幕上变红的世界行 = %d" % red_row)
		ok(red_row == 2,
			"★★ 贴图行号与世界行号**同向**（涂第 2 行 → 落在世界第 2 行；实测 %d）" % red_row)
	else:
		ok(false, "涂记号之后拿不到截图，无法验证上下方向")

	var clarity := _measure_grid_contrast(game, base, scl, rows, cols)
	print("[CASE] （实测）格线对比度 = %.2f%%（格线 %.4f vs 格心 %.4f，取样 %d 条；宽 %.1f px）" % [
		100.0 * clarity["rel"], clarity["line"], clarity["field"], clarity["n"],
		game.overlay.GRID_WIDTH])
	ok(int(clarity["n"]) > 0, "★ 找到可采样的内部格线（%d 条）" % int(clarity["n"]))
	ok(float(clarity["rel"]) >= 0.12,
		"★★ 格线在屏幕上读得出来（格线比格心亮 ≥ 12%%，实测 %.1f%% —— 糊掉时这个数会趋近 0）"
		% (100.0 * float(clarity["rel"])))
	ok(game.overlay.GRID_WIDTH >= 2.0,
		"★★ 格线宽度 ≥ 2 屏幕像素（实测 %.1f —— 1 px 落在像素边界上会被抗锯齿摊成软线）"
		% game.overlay.GRID_WIDTH)

	game.queue_free()
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _measure_grid_contrast(game, base: Image, scl: Vector2, rows: int, cols: int) -> Dictionary:
	var line_sum := 0.0
	var field_sum := 0.0
	var n := 0
	var g = game.ground
	var w = game.world
	var mask = w.fog.sight.get(String(w.my_faction), null)
	for ty in range(1, rows - 1):
		for tx in range(1, cols - 1):
			var z1 = w.zones.zone_at(tx, ty)
			var z2 = w.zones.zone_at(tx + 1, ty)
			if z1 == null or z2 == null:
				continue
			if int((z1 as Dictionary).get("id", -1)) != int((z2 as Dictionary).get("id", -1)):
				continue
			var t1 := String(w.map.terrain.get_cell(tx, ty))
			var t2 := String(w.map.terrain.get_cell(tx + 1, ty))
			if t1 != t2:
				continue
			if mask is PackedByteArray:
				var i1: int = ty * cols + tx
				var i2: int = ty * cols + tx + 1
				var sz: int = (mask as PackedByteArray).size()
				if i1 >= sz or i2 >= sz:
					continue
				if (mask as PackedByteArray)[i1] == 0 or (mask as PackedByteArray)[i2] == 0:
					continue
			var edge: Vector2 = game.palette.to_px(Vector2(float(tx + 1), float(ty) + 0.5))
			var c1: Vector2 = game.palette.to_px(Vector2(float(tx) + 0.35, float(ty) + 0.5))
			var c2: Vector2 = game.palette.to_px(Vector2(float(tx) + 1.65, float(ty) + 0.5))
			var pe := Vector2(edge.x * scl.x, edge.y * scl.y)
			var p1 := Vector2(c1.x * scl.x, c1.y * scl.y)
			var p2 := Vector2(c2.x * scl.x, c2.y * scl.y)
			if not _inside(base, pe, 3) or not _inside(base, p1, 3) or not _inside(base, p2, 3):
				continue
			line_sum += _win_lum(base, int(round(pe.x)), int(round(pe.y)), 1)
			field_sum += 0.5 * (_win_lum(base, int(round(p1.x)), int(round(p1.y)), 1)
				+ _win_lum(base, int(round(p2.x)), int(round(p2.y)), 1))
			n += 1
			if n >= 60:
				break
		if n >= 60:
			break
	var rel := 0.0
	var field := 0.0
	if n > 0:
		field = field_sum / float(n)
		if field > 1e-6:
			rel = (line_sum / float(n) - field) / field
	return {"line": line_sum / maxf(1.0, float(n)), "field": field, "rel": rel, "n": n}

static func _inside(img: Image, p: Vector2, m: int) -> bool:
	return p.x >= float(m) and p.y >= float(m) \
		and p.x < float(img.get_width() - m) and p.y < float(img.get_height() - m)

func _find_marked_row(shot: Image, scl: Vector2, game, cols: int, rows: int) -> int:
	for ty in rows:
		var n := 0
		var tot := 0
		for tx in cols:
			var sp: Vector2 = game.palette.to_px(Vector2(float(tx) + 0.5, float(ty) + 0.5))
			var px := int(round(sp.x * scl.x))
			var py := int(round(sp.y * scl.y))
			if px < 3 or py < 3 or px >= shot.get_width() - 3 or py >= shot.get_height() - 3:
				continue
			tot += 1
			var c := shot.get_pixel(px, py)
			if c.r > 0.5 and c.g < 0.3 and c.b < 0.3:
				n += 1
		if tot > 0 and n > tot / 2:
			return ty
	return -1

func _shot() -> Image:
	var tex: Variant = root.get_texture()
	if tex == null:
		return null
	var got: Variant = (tex as ViewportTexture).get_image()
	if got is Image:
		return got
	return null
