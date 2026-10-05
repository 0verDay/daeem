## test_view3d_fog.gd —— 3D 迷雾的**实测标定**（不是「跑一遍没炸」）
##
## ★★ 为什么必须单独有这个文件（这一轮踩到的教训）：
##   `ground_view._bake_fog()` 只要「烘得出贴图、层可见」就算对了，**没有任何断言**能
##   发现「遮罩太淡」—— 用户报的「战争迷雾不明显」正是这种**不报错的功能缺失**。
##   唯一能钉住它的办法是**量成图**：把「关掉迷雾」与「开着迷雾」两张截图逐格比亮度。
##
## ★★ 三个前提，缺一个量出来的数就是错的（本轮为此白跑了好几轮）：
##   ① **必须关掉边缘滚屏 + 冻结 `_process`**：无头下鼠标停在 (0,0)，
##      边缘滚屏会一直把镜头往左上推，量到的「同一格」其实是别的格。
##   ② **必须用 `game.cfg` 改配置**（不是测试自己 load 的那个 `cfg`）：
##      `ConfigRes.load_default()` 每次返回**新实例**，改错对象的表现是
##      「两张截图一模一样 ⇒ 差值 0.000」（实测踩到，看起来像迷雾没画）。
##   ③ **截图坐标必须按 `image / visible_rect` 缩放**：
##      实测视口是 1920×1080（项目设置），而 `--resolution 1600x900` 下截出来是
##      1600×900 ⇒ 直接拿视口坐标去 `get_pixel` 会**整体偏移**（实测偏 4 格，
##      差点被误判成「贴图 UV 映射错了」）。
##
## ⚠️ 无头（`--headless`）下 `get_viewport().get_texture().get_image()` 拿不到图
##    （dummy 渲染器，实测 `Parameter "t" is null`）⇒ 本文件在**无头下自动跳过**，
##    跑全量测试时它安静通过；要真的量，得用真渲染跑一次：
##      Godot_..._console.exe --path <项目> --script res://tests/test_view3d_fog.gd \
##          --rendering-driver vulkan --resolution 1600x900
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const GroundRes = preload("res://view/ground_view.gd")


func _initialize() -> void:
	_case_name = "test_view3d_fog"
	_run()


static func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


## 以 (px,py) 为中心的 w×w 窗口平均亮度
## ★ 用窗口而不是单像素：贴图放大后中央那一个像素可能恰好压在**格线 / 单位**上，
##   实测单像素的方差大到会把 10% 的差读成 0%（这一轮正是被它误导过一次）。
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

	# 前提 ①②
	game._edge_scroll_on = false
	game.set_process(false)
	game.center_on_tile(Vector2(float(game.world.map.cols) * 0.5,
		float(game.world.map.rows) * 0.5))
	game.cam.force_update_transform()
	await process_frame
	await process_frame

	var shot := await _shot()
	if shot == null:
		# 无头：拿不到成图。**不算失败**（否则全量测试在无头下会红），
		# 但要把这件事说出来 —— 静默跳过正是本项目最怕的那类问题。
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

	# ---- 基准：迷雾全关；再开回来。★ 必须改 game.cfg（前提 ②）----
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

	# 前提 ③：视口 → 图像 的缩放
	var vp: Vector2 = game.get_viewport().get_visible_rect().size
	var scl := Vector2(float(base.get_width()) / maxf(1.0, vp.x),
		float(base.get_height()) / maxf(1.0, vp.y))
	ok(true, "（诊断）视口 %s，截图 %s，缩放 %s" % [str(vp), str(base.get_size()), str(scl)])

	# ---- 逐格量：被迷雾盖住的格，亮度必须**明显下降** ----
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
	# ★★ 这两条就是「迷雾不明显」的判据：改回 0.45 时平均只有 10.6%
	ok(mean_rel >= 0.15,
		"★★ 迷雾的平均亮度下降 ≥ 15%%（实测 %.1f%%；dev_plan_10 说 0.45 只有 10.6%%）"
		% (100.0 * mean_rel))
	# ★ 「该被盖住却几乎没变暗」的格：**允许多数、不许成片**
	#   实测口径（1920×1080 视口 / 27×22 图 / alpha 0.8）：
	#     盖住 439 格里有 139 格几乎没变暗 —— 它们不是 z-fighting，
	#     而是那一格的 5×5 采样窗里**大部分像素是单位 / 建筑 / 选中圈**
	#     （迷雾只压地面，压不住立牌与血条）。所以判据是**比例**，不是「必须为 0」：
	#     UV 错位或部分遮挡会是**成片**的（> 40%），零星的单位遮挡不会。
	var leak_ratio: float = float(leaked) / maxf(1.0, float(covered))
	ok(leak_ratio <= 0.40,
		"★ 「该被迷雾盖住却几乎没变暗」的格不超过 40%%（实测 %d/%d = %.1f%%；成片才是 UV / z-fighting 错）"
		% [leaked, covered, 100.0 * leak_ratio])
	ok(game.cfg.fog_mask_color.a >= 0.7,
		"★ 配置里的遮罩 alpha 已经调到 ≥ 0.7（实测 %.2f）" % game.cfg.fog_mask_color.a)

	# ★★ 贴图上下方向（真渲染下的**唯一**判据）
	#
	# 用户曾报「迷雾上下反了、区块也反了」：根因是地面层的 UV 被多做了一次 v 翻转。
	# 这件事**在无头下不会报任何错**，只能靠「在贴图上涂一条不对称的记号，再看屏幕」。
	# 做法：把地面贴图的**第 2 行**整行涂成纯红，然后找屏幕上变红的是哪一行 ——
	# 必须是**世界第 2 行**。涂错方向（翻转还在）会落在世界倒数第 2~3 行。
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

	# ★★ 地表清晰度：**格线在屏幕上的对比度**必须够
	#
	# 用户报「地表太糊了」「占领的进度条还是太糊了」⇒ 这一轮把网格线 / 区划轮廓 /
	# 占领进度条**全部搬到屏幕空间**（矢量画法，与 2D 版同一套）。
	# 判据：取同色地形、同区划、都有视野的一条**竖直格线**与它两侧格心的亮度差。
	#
	# ★★ 一个实测出来的陷阱：屏幕空间的 1 px 线**落在像素边界上**时，
	#   抗锯齿会把它摊到相邻两个像素各一半 ⇒ 一条「1 像素实线」看起来是
	#   「2 像素的半透明软线」（实测对比度只有 7.4%）。
	#   两种解法：① 端点吸附到像素中心；② 加粗到 2 px。
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


## 量「格线在屏幕上读不读得出来」：返回 {"line": 格线平均亮度, "field": 格心平均亮度,
## "rel": 相对差, "n": 取样条数}。
##
## ★★ 取样规则（每一条都是为了别量到别的东西）：
##   · 只看**竖直**格线（横向取样要跨过格线两侧的格心，纵向受透视压缩影响更大）；
##   · 两格必须**同属一个区划**（否则量到的是区划轮廓那条白线，不是网格线）；
##   · 两格必须**同一种地形**（`terrain` 同类）且**都没有迷雾**（否则量到明暗边界）；
##   · 格线位置 = 格边界的屏幕 x 坐标（贴图里线画在格子最左/最右 `edge_px` 列上）。
func _measure_grid_contrast(game, base: Image, scl: Vector2, rows: int, cols: int) -> Dictionary:
	var line_sum := 0.0
	var field_sum := 0.0
	var n := 0
	var g = game.ground
	var w = game.world
	var mask = w.fog.sight.get(String(w.my_faction), null)
	for ty in range(1, rows - 1):
		for tx in range(1, cols - 1):
			# 只挑同一区划的相邻两格
			var z1 = w.zones.zone_at(tx, ty)
			var z2 = w.zones.zone_at(tx + 1, ty)
			if z1 == null or z2 == null:
				continue
			if int((z1 as Dictionary).get("id", -1)) != int((z2 as Dictionary).get("id", -1)):
				continue
			# 同一种地形
			var t1 := String(w.map.terrain.get_cell(tx, ty))
			var t2 := String(w.map.terrain.get_cell(tx + 1, ty))
			if t1 != t2:
				continue
			# 两格都必须有视野（否则量到迷雾边界）
			if mask is PackedByteArray:
				var i1: int = ty * cols + tx
				var i2: int = ty * cols + tx + 1
				var sz: int = (mask as PackedByteArray).size()
				if i1 >= sz or i2 >= sz:
					continue
				if (mask as PackedByteArray)[i1] == 0 or (mask as PackedByteArray)[i2] == 0:
					continue
			# 格线：格 (tx,ty) 的**右边界**（世界格坐标 = tx+1）
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


## 在**涂了记号**的那张截图上，找出「变红的世界行」，返回行号（-1 = 没找到）。
##
## ★ 只认「明显偏红」的格：`r` 高、`g/b` 低。地图底色是最暗的橄榄绿，
##   而轮廓/迷雾都不会产生纯红 ⇒ 判据不会被别的东西误触发。
## ★ 取样坐标同样要**按 `scl` 缩放**（视口 1920×1080 vs 截图 1600×900）。
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
	# ⚠️⚠️ 这里**必须**显式写类型（本轮踩到的 Parse Error）：
	#   `return root.get_texture().get_image()` 会被静态分析推成 **String**
	#   （`Texture2D.get_image()` 的失败路径返回错误字符串），
	#   于是报 `Cannot return value of type "String" because the function return
	#   type is "ImageTexture"` —— 而报错信息完全指不到真因。
	#   ⇒ 先落到变体、判类型、再返回。
	var tex: Variant = root.get_texture()
	if tex == null:
		return null
	var got: Variant = (tex as ViewportTexture).get_image()
	if got is Image:
		return got
	return null
