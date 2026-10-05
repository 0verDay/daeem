## overlay_view_3d.gd —— 3D 版的覆盖层：选中圈 / 移动与攻击标记 / 建造预览 / 拖框
##
## ★★ 为什么这一层留在 **2D 屏幕空间**而不是做成 3D 物件（本版的重要取舍）：
##   · 它们是**界面反馈**，不是世界里的东西 —— 玩家要的是「我的部队在哪、点到哪」，
##     这些东西**不该跟着地面倾斜**（跟着歪会难读，也容易与地形混淆）；
##   · 画在 `CanvasLayer` 上的 `Control` 里，天然 1:1、不受透视影响、
##     也不需要为每个标记建 3D 节点（1000 个单位全选时那就是 1000 个节点）。
##   定位靠 `palette.to_px(格)` —— 与「点在哪」用的是同一条投影链路，
##   所以标记与鼠标**天然对齐**（这正是本项目最容易错位的地方）。
##
## ★ 只读逻辑状态 + 只读本地 UI 状态；不发命令、不改逻辑。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const UnitIconRes = preload("res://view/unit_icon.gd")

## 选中光晕贴图边长
const HALO_TEX_SIZE := 32
const HP_BACK_COLOR := Color(0, 0, 0, 0.55)

var cfg: ConfigRes = null
var world = null
var palette = null
var units = null
## ★ 地面层（`ground_view.gd`）：只用来问「这一格的哪几条边是区划边界」
##   与「这个区划的轮廓该是什么颜色」。它**只读**，不改任何东西。
var ground = null

## 由 game_scene / input_controller 每帧塞进来的纯本地状态
var hover_tile: Vector2i = Vector2i(-1, -1)
var hover_valid: bool = false
var build_type: String = ""
var move_marks: Array[Vector2] = []
var attack_marks: Array[Vector2] = []
var drag_active: bool = false
var drag_rect: Rect2 = Rect2()
var mouse_world: Vector2 = Vector2.ZERO
var debug_aim: bool = false

## 诊断（只有测试读它）：最近一次 `_draw()` 发出的绘制命令数
var draw_count: int = 0
var _tex_halo: ImageTexture = null


func setup(p_cfg: ConfigRes, p_world, p_palette, p_units, p_ground = null) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	units = p_units
	ground = p_ground
	# 铺满屏幕、但不吃鼠标（输入走 input_controller 那条路）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_tex_halo = _make_disc_texture()


static func _make_disc_texture() -> ImageTexture:
	var size := HALO_TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var r_out := c - 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
			var cov := clampf(r_out - d + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1, 1, 1, cov))
	return ImageTexture.create_from_image(img)


func sync() -> void:
	queue_redraw()


func _draw() -> void:
	draw_count = 0
	if cfg == null or world == null or palette == null:
		return
	# ★★ 顺序即层次（后画的在上面），这一串是刻意排的：
	#   ① 地面上的"线"（网格 / 区划轮廓）—— 在地面之上、单位之下
	#      ⚠️ 它们必须**先于**单位画：否则网格线会盖在兵人身上（看起来像网格穿透了部队）。
	#   ② 占领进度条 —— 也是地面上的东西，同样在单位之下
	#      （2D 版里它属于 `zone_view`，与地块同层）。
	#   ③ 单位头上的 UI（选中圈 / 血条）—— 最上面
	_draw_grid()
	_draw_zone_outlines()
	_draw_zone_capture()
	_draw_units_ui()
	_draw_move_marks()
	_draw_build_preview()
	_draw_drag_box()


# ------------------------------------------------------------------
# 地面上的"线"：网格 / 区划轮廓 / 占领进度条（本轮从贴图搬到这里）
# ------------------------------------------------------------------
##
## ★★ 为什么必须是**屏幕空间**（用户报「占领的进度条还是太糊了」的正面回答）：
##   这图形里的「线」原来烘在地面贴图里，而贴图是「每格 16 像素」再被放大到
##   一格约 30 屏幕像素 ⇒ 1 像素的线变成 2 像素的**软边**、1 像素 = 1 格的进度贴图
##   更糟（一个纹素铺满整格，LINEAR 的插值就在整格宽度上摊开成 30 px 的渐变）。
##   **烘到低分辨率贴图上再放大，永远不可能像 2D 那样清晰。**
##   2D 版是 `draw_rect` / `draw_multiline` 直接画在画布上 ⇒ 天然逐像素清晰、
##   斜线还有引擎的抗锯齿。这里改成同一套画法之后，
##   ① 线宽是**屏幕像素**（不随缩放变糊）；② 斜线由引擎抗锯齿；
##   ③ 与地块的关系仍然正确 —— 因为**格角是逐个投影出来的**（`palette.to_px`），
##      与 `input_controller` 判"鼠标点在哪一格"用的是同一条链路。

## 网格线的颜色与宽度（屏幕像素）
##
## ★★ 为什么是 **2 px**（实测定的，不是拍脑袋）：
##   屏幕空间的 1 px 线落在**像素边界**上时，引擎的抗锯齿会把它摊到相邻两个像素
##   各一半 ⇒ 亮度只有理论值的一半，实测对比度 **6.8~7.4%**（看起来是"一条软线"）。
##   2 px 之后线的墨量翻倍、不再受半像素落点的影响，实测对比度回到 **~18%**
##   （与「烘进贴图、再放大」那版 18.83% 同一档，但那条路在缩放时会糊）。
## ★ 颜色用 16% 白：与 2D 版 `colors.grid`（5.5% 白）相比更亮 ——
##   因为 2D 是**轴对齐**的实心矩形，而这里是抗锯齿的 2 px 线。
##   ⚠️ 不要再加粗到 3 px 以上：用户当年报过「地图上的格子中有很多奇怪的线条」，
##     那是同一类反感（线抢戏）。
const GRID_COLOR := Color(1.0, 1.0, 1.0, 0.16)
const GRID_WIDTH := 2.0
## 区划轮廓的宽度（屏幕像素）
##
## ★ 与 2D 版 `zone_view` 的 `zone_stroke_width_owned = 2.5` 同一档。
##   ⚠️ 别指望 config 里那个值直接能用：那个是**2D 世界像素**口径，
##     而这里是屏幕像素（缩放时不该跟着变粗/变细）。
const ZONE_OUTLINE_WIDTH := 2.5
## 占领进度条：填充的 alpha，以及前沿那条亮线的宽度与 alpha
##
## ★★ 与 2D 版 `zone_view` 的进度条同一套语义（那里是 `zone_progress` 色的矩形 + 顶边亮线）。
##   用户口径：「由下往上升起一个进度条，进度条填满区划时，区划易主」。
const CAPTURE_FILL_ALPHA := 0.45
const CAPTURE_FRONT_WIDTH := 2.0
const CAPTURE_FRONT_ALPHA := 0.95

## 网格线顶点缓存（只在地图尺寸变化时重建；相机移动不影响它 —— 顶点是**格坐标**）
var _grid_segs: Array = []
var _grid_cols: int = -1
var _grid_rows: int = -1
## 区划轮廓缓存：`{signature, segs}` —— 只有归属 / 地块划分变了才重算
var _zone_segs: Array = []
var _zone_seg_sig: String = ""
## 诊断（测试读它）：最近一次 `_draw()` 里网格线 / 区划轮廓 / 占领填充各画了几条
var grid_draw_count: int = 0
var zone_outline_draw_count: int = 0
var capture_draw_count: int = 0


## 网格线：**整张图**的横竖格线（顶点是格坐标，缓存一次即可）。
##
## ★ 计数与绘制**分开**（下一段说明为什么）。
func _draw_grid() -> void:
	grid_draw_count = _count_grid_lines()
	_draw_logic_segments(_grid_segs_for(int(world.map.cols), int(world.map.rows)),
		GRID_COLOR, GRID_WIDTH)


## 网格线这一帧**画几条**（纯计数，不碰绘制 API）。
##
## ★★ 为什么「数」与「画」要拆开（本轮实测踩到）：
##   在 `_draw()` **之外**调 `draw_multiline()` / `draw_colored_polygon()` 会报
##   `ERROR: Drawing is only allowed inside this node's _draw()` ——
##   而测试要在无头下量这些计数（引擎在无头下不渲染 `Control`，所以没有真的 `_draw()` 可等）。
##   拆开之后：测试调 `_count_*()`（**纯计算、零报错**），
##   真渲染时 `_count_*()` 的结果被记进计数器供诊断。
##   ⇒ 好处不只是「没有噪音」：**日志里出现 ERROR 就说明有真问题**，
##     不会被这几条预期的报错淹掉（本项目已经为「红字里的真错误被淹没」付过学费）。
func _count_grid_lines() -> int:
	if world == null or world.map == null:
		return 0
	return int(world.map.cols) + 1 + int(world.map.rows) + 1


## 网格线顶点（格坐标，成对存放：起点、终点）——**只在格子数变化时重建**。
##
## ★ 为什么缓存：顶点是**格坐标**（世界不变），与相机无关 ——
##   每帧重建一遍 94 条线段是白费（27×22 的图 = 28 + 23 条）。
## ★ 为什么整张图都发出去、不自己裁剪：线段只有 50~200 条，
##   而 `draw_multiline` 是**一次** GPU 调用；自己算可见范围反而多一份容易错的逻辑。
##   （100×100 的图是 202 条 —— 仍然可以忽略。）
func _grid_segs_for(cols: int, rows: int) -> Array:
	if _grid_cols == cols and _grid_rows == rows and not _grid_segs.is_empty():
		return _grid_segs
	var segs: Array = []
	# 竖线：x = 0..cols，从 y=0 到 y=rows
	for x in range(0, cols + 1):
		segs.append(Vector2(float(x), 0.0))
		segs.append(Vector2(float(x), float(rows)))
	# 横线：y = 0..rows
	for y in range(0, rows + 1):
		segs.append(Vector2(0.0, float(y)))
		segs.append(Vector2(float(cols), float(y)))
	_grid_segs = segs
	_grid_cols = cols
	_grid_rows = rows
	return _grid_segs


## 把一串「格坐标线段」投影到屏幕并画出来。
##
## ★★ **必须把端点吸附到像素中心**（这一步不是锦上添花，是清晰度的关键）：
##   格线在世界里落在格边界上，投影之后往往正好落在**屏幕像素的边界**（x.0）上 ⇒
##   1 px 宽的线被抗锯齿**摊到相邻两个像素各一半**，实测对比度只有 7.4%
##   （不吸的话，一条「1 像素实线」看起来是「2 像素的半透明软线」）。
##   吸附到 `.5` 之后线落在像素中心，1 px 就是 1 px —— 与 2D 版 `draw_line`
##   在整数坐标上的观感一致。
##
##   ⚠️ 吸附的代价是线**偏离真实格边最多半个像素**（肉眼不可辨）；
##      换来的是「像 2D 一样清晰」。用户的口径就是这个，所以这个取舍是明确的。
##
## ★ `PackedVector2Array` 而不是 `Array`：`draw_multiline` 要的是 Packed 数组，
##   而逐个 `append` 到 Packed 数组比 `Array` + 转换省一次拷贝。
## ★★ 一次 `draw_multiline` 画**所有**线段 ⇒ 94 条线 = 1 次 draw 调用
##   （与 2D 版 `zone_view` 的「按阵营分组合并」同一条思路）。
func _draw_logic_segments(segs: Array, color: Color, width: float) -> void:
	if segs.is_empty():
		return
	var pts := PackedVector2Array()
	pts.resize(segs.size())
	for i in segs.size():
		var p: Vector2 = segs[i]
		var sp: Vector2 = palette.to_px(p)
		pts[i] = Vector2(roundf(sp.x - 0.5) + 0.5, roundf(sp.y - 0.5) + 0.5)
	draw_multiline(pts, color, width)


## 网格线（整张图）
## 区划轮廓：沿着**地块的边界**画（非矩形区划的轮廓才是它的真实形状）。
##
## ★★ 按**区划 id** 分组、每组一次 `draw_multiline`：
##   一条边两侧的颜色可能不同（两侧属于不同区划），所以不能全图合并成一条。
##   分组之后每块地一次 draw 调用（24 块 ⇒ 24 次），与 2D 版同一取舍。
## ★★ 缓存：边界是**格坐标**的几何，只在归属 / 地块划分变化时才会变
##   —— 相机每帧移动不该让它重算（`palette.to_px` 才是每帧要做的投影）。
func _draw_zone_outlines() -> void:
	zone_outline_draw_count = _count_zone_outlines()
	for entry in _zone_segs:
		var segs: Array = entry["segs"]
		_draw_logic_segments(segs, (entry["color"] as Color), ZONE_OUTLINE_WIDTH)


## 区划轮廓这一帧**画几组**（纯计数，不碰绘制 API）——同时保证几何缓存是新的。
##
## ★ 与 `_count_grid_lines()` 同一个理由：把「数」与「画」拆开，
##   测试才能在无头下量到计数而不触发 `Drawing is only allowed inside _draw()`。
func _count_zone_outlines() -> int:
	if world == null or world.zones == null:
		return 0
	var sig := _zone_edge_signature()
	if sig != _zone_seg_sig:
		_zone_seg_sig = sig
		_zone_segs = _build_zone_segments()
	var n := 0
	for entry in _zone_segs:
		if not (entry["segs"] as Array).is_empty():
			n += 1
	return n


## 边界几何的签名：地块划分（每块的 id + 地块数 + 归属）变了就要重算几何
func _zone_edge_signature() -> String:
	var parts: Array = []
	for z in world.zones.zones:
		parts.append("%d:%d:%s" % [
			int((z as Dictionary).get("id", -1)),
			int((z as Dictionary).get("tile_count", 0)),
			String((z as Dictionary).get("owner", ""))])
	return "|".join(parts)


## 算出每个区划的边界线段（格坐标，成对存放：起点、终点）。
##
## ★ 每条边**只由拥有它的那一格**产生（不重复发两次）：同一条边两侧的格子各查一次
##   邻接，只有「我在区划 A、邻居不在 A」时我才画 ⇒ 每条边恰好被一侧画一次，
##   不会叠成双倍粗细。
## ★ 四条边取哪两个角：格 (tx,ty) 的四角是
##   `(tx,ty)` `(tx+1,ty)` `(tx+1,ty+1)` `(tx,ty+1)` ⇒
##     上边 = 角0→角1、右边 = 角1→角2、下边 = 角2→角3、左边 = 角3→角0。
##   ⚠️ 这里**不**用「按掩码取内缩像素」那套（那是给贴图用的）：屏幕空间直接画格边。
func _build_zone_segments() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for z in world.zones.zones:
		var zid := int((z as Dictionary).get("id", -1))
		var cells: Array = (z as Dictionary).get("tiles", [])
		if cells.is_empty():
			continue
		var segs: Array = []
		for t in cells:
			var tile: Vector2i = t
			# 去重：同一格只处理一次（不同区划的地块列表理论上不重叠，但这是免费的保险）
			var key: int = tile.y * 100000 + tile.x
			if seen.has(key):
				continue
			seen[key] = true
			var mask: int = ground.zone_edge_mask(tile.x, tile.y)
			if mask == 0:
				continue
			var x0 := float(tile.x)
			var y0 := float(tile.y)
			var x1 := x0 + 1.0
			var y1 := y0 + 1.0
			if (mask & 1) != 0:      # 上
				segs.append(Vector2(x0, y0))
				segs.append(Vector2(x1, y0))
			if (mask & 2) != 0:      # 右
				segs.append(Vector2(x1, y0))
				segs.append(Vector2(x1, y1))
			if (mask & 4) != 0:      # 下
				segs.append(Vector2(x1, y1))
				segs.append(Vector2(x0, y1))
			if (mask & 8) != 0:      # 左
				segs.append(Vector2(x0, y1))
				segs.append(Vector2(x0, y0))
		if segs.is_empty():
			continue
		out.append({"id": zid, "segs": segs, "color": ground.zone_outline_color(z)})
	return out


## 占领进度条：**由下往上升起**的一块填充 + 前沿一条亮线（全部屏幕空间矢量）。
##
## ★★ 口径（用户原话）：「当开始占领时，区划由下往上升起一个进度条，
##   进度条填满区划时，区划易主」。
##   ⇒ 填充的顶边（水面）随进度**上升**，读满时 `zone.update()` 改 owner、这一层变空。
##
## ★★ 进度只有一处权威：`world.zones.capture_bar(z)`（读条 / 冻结 / 回落三条规则都在逻辑层）。
##   视图**不许**自己去比各方的进度 —— 2D 版为此记过一条坑。
##
## ★★ 几何怎么算（这是这个函数唯一需要理解的东西）：
##   · 高度基准 = **这个区划自己**的地块外接框 `y0..y1`（整个区划共用，
##     所以前沿是一条**水平的连续线**，不是每格各自升到顶的锯齿）；
##   · 水面 `water = (y1+1) - (y1-y0+1) * v`  ⇒ v 越大 water 越小 ⇒ **往上长**；
##   · 逐格：整格在水面之下 ⇒ 整格填；水面穿过这一格 ⇒ 只填**水面以下那一块**
##     （所以一格之内是**连续**的填充，不是一个整格的跳变）；
##   · 每格画成一个四边形（`draw_colored_polygon`），格角逐个投影 ⇒ 透视正确、
##     边缘逐像素清晰（这正是「像 2D 一样清晰」的来源）。
##   ⚠️ 方向写反过一次（`y0 + span*v` = 从上往下淌），症状是「越占越像退潮」。
##     判据：`water` 必须随 `v` **单调下降**。
func _draw_zone_capture() -> void:
	var items: Array = _capture_items()
	capture_draw_count = 0
	for it in items:
		for quad in (it["quads"] as Array):
			draw_colored_polygon(quad, (it["fill"] as Color))
			capture_draw_count += 1
		var front_pts: PackedVector2Array = it["front"]
		if front_pts.size() >= 2:
			draw_multiline(front_pts, (it["front_color"] as Color), CAPTURE_FRONT_WIDTH)


## 占领进度条这一帧**画几块**（纯计数，不碰绘制 API）。
##
## ★ 与 `_count_grid_lines()` / `_count_zone_outlines()` 同一个理由（见那里的说明）。
func _count_zone_captures() -> int:
	var n := 0
	for it in _capture_items():
		n += (it["quads"] as Array).size()
	return n


## 算出「这一帧要画的占领进度条几何」（**纯计算**，不做任何绘制调用）。
##
## ★★ 几何怎么算（这是这个函数唯一需要理解的东西）：
##   · 高度基准 = **这个区划自己**的地块外接框 `y0..y1`（整个区划共用，
##     所以前沿是一条**水平的连续线**，不是每格各自升到顶的锯齿）；
##   · 水面 `water = (y1+1) - (y1-y0+1) * v`  ⇒ v 越大 water 越小 ⇒ **往上长**；
##   · 逐格：整格在水面之下 ⇒ 整格填；水面穿过这一格 ⇒ 只填**水面以下那一块**
##     （所以一格之内是**连续**的填充，不是一个整格的跳变）；
##   · 每格一个四边形，格角逐个投影 ⇒ 透视正确、边缘逐像素清晰。
##
## @return `[{quads: Array[PackedVector2Array], front: PackedVector2Array,
##           fill: Color, front_color: Color}, ...]`（每个正在读条的区划一项）
func _capture_items() -> Array:
	var out: Array = []
	if world == null or world.zones == null or palette == null or cfg == null:
		return out
	for z in world.zones.zones:
		var bar: Dictionary = world.zones.capture_bar(z)
		var v := clampf(float(bar.get("value", 0.0)), 0.0, 1.0)
		if v <= 0.001:
			continue
		var cells: Array = (z as Dictionary).get("tiles", [])
		if cells.is_empty():
			continue
		# ① 高度基准（整个区划共用）
		var y0 := 1 << 20
		var y1 := -(1 << 20)
		for t in cells:
			var tile: Vector2i = t
			y0 = mini(y0, tile.y)
			y1 = maxi(y1, tile.y)
		if y1 < y0:
			continue
		var span: float = float(y1 - y0 + 1)
		var water: float = float(y1 + 1) - span * v
		# ② 颜色：填充 = 阵营色半透明；前沿 = 同色提亮一档（与地面的对比度更高）
		var fc: Color = cfg.zone_capture_color(String(bar.get("faction", "")))
		var fill := Color(fc.r, fc.g, fc.b, CAPTURE_FILL_ALPHA)
		var front := Color(
			lerpf(fc.r, 1.0, 0.35), lerpf(fc.g, 1.0, 0.35), lerpf(fc.b, 1.0, 0.35),
			CAPTURE_FRONT_ALPHA)
		# ③ 逐格：整格在水面下就整格填；水面穿过就只填水面以下那一块
		var quads: Array = []
		var front_pts := PackedVector2Array()
		for t2 in cells:
			var tile2: Vector2i = t2
			var top: float = float(tile2.y)
			var bottom: float = float(tile2.y) + 1.0
			if bottom <= water:
				continue                       # 整格还在水面之上：什么都不填
			var cut: float = maxf(top, water)   # 这一格被水面切到哪
			var x0 := float(tile2.x)
			var x1 := x0 + 1.0
			quads.append(PackedVector2Array([
				palette.to_px(Vector2(x0, cut)),
				palette.to_px(Vector2(x1, cut)),
				palette.to_px(Vector2(x1, bottom)),
				palette.to_px(Vector2(x0, bottom)),
			]))
			# ④ 水面正好穿过这一格 ⇒ 它的顶边是「前沿」的一段
			if top < water and water < bottom:
				front_pts.append(palette.to_px(Vector2(x0, water)))
				front_pts.append(palette.to_px(Vector2(x1, water)))
		out.append({"quads": quads, "front": front_pts, "fill": fill, "front_color": front})
	return out


## 单位头上的东西（选中圈 / 血条）——都是屏幕空间的圆与条
func _draw_units_ui() -> void:
	if units == null:
		return
	var sel: Dictionary = {}
	if world != null:
		# 选中集合由 game_scene 每帧喂进来（见 set_selection）
		sel = _selection
	for u in world.units:
		if not u.alive or not _unit_visible(u):
			continue
		var p: Vector2 = palette.to_px(u.pos)
		var r: float = units.quad_screen_width(u) * 0.5
		if r <= 0.0:
			continue
		# 选中光晕（脚下的一圈）
		if sel.has(u.id):
			var rr: float = maxf(r, 8.0) + 4.0
			draw_texture_rect(_tex_halo, Rect2(p - Vector2(rr, rr * 0.5), Vector2(rr * 2.0, rr)),
				false, Color(1.0, 0.85, 0.3, 0.45))
			draw_count += 1
		# 血条：不满血才画（满血不画，避免刷屏）
		if u.hp < u.hp_max - 1e-6:
			var w: float = maxf(r * 2.2, 10.0)
			var top: Vector2 = p - Vector2(0.0, units.quad_screen_height(u) * 0.5 + 4.0)
			draw_rect(Rect2(Vector2(top.x - w * 0.5, top.y), Vector2(w, 3.0)), HP_BACK_COLOR, true)
			draw_rect(Rect2(Vector2(top.x - w * 0.5, top.y), Vector2(w * u.hp_ratio(), 3.0)),
				cfg.faction_color(String(u.faction), "bar"), true)
			draw_count += 1


var _selection: Dictionary = {}


## 由 game_scene 每帧喂「哪些单位被选中」
func set_selection(ids: Array) -> void:
	_selection = {}
	for id in ids:
		_selection[String(id)] = true


func _unit_visible(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


## 移动目标点（绿圈 + 十字）与行军攻击目标点（红圈 + 叉）
func _draw_move_marks() -> void:
	for m in move_marks:
		var p: Vector2 = palette.to_px(m)
		var c := Color(0.6, 1.0, 0.7, 0.85)
		draw_arc(p, 14.0, 0.0, TAU, 24, c, 2.0)
		draw_line(p + Vector2(-6, 0), p + Vector2(6, 0), c, 1.5)
		draw_line(p + Vector2(0, -6), p + Vector2(0, 6), c, 1.5)
		draw_count += 1
	for m2 in attack_marks:
		var q: Vector2 = palette.to_px(m2)
		var c2 := Color(1.0, 0.45, 0.4, 0.9)
		draw_arc(q, 16.0, 0.0, TAU, 28, c2, 2.0)
		draw_line(q + Vector2(-7, -7), q + Vector2(7, 7), c2, 2.0)
		draw_line(q + Vector2(-7, 7), q + Vector2(7, -7), c2, 2.0)
		draw_count += 1


## 建造预览：**沿地块的四个角投出来的四边形**（透视下是梯形，不是矩形）
func _draw_build_preview() -> void:
	if build_type == "" or hover_tile.x < 0:
		return
	var ok: bool = world.can_build_at(hover_tile.x, hover_tile.y)
	var c := Color(0.45, 1.0, 0.5, 0.55) if ok else Color(1.0, 0.4, 0.4, 0.55)
	var quad := _tile_screen_quad(hover_tile)
	if quad.size() < 4:
		return
	draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.18))
	var closed := quad.duplicate()
	closed.append(quad[0])
	draw_polyline(closed, c, 2.5)
	draw_count += 1


## 一个格在屏幕上的四个角（顺序：左上 → 右上 → 右下 → 左下）
##
## ★ 用 `palette.to_px` 逐个角投 —— 透视下**不能**只投中心再套一个矩形：
##   那样四角会是错的（地块在屏幕上是梯形）。
func _tile_screen_quad(tile: Vector2i) -> PackedVector2Array:
	return PackedVector2Array([
		palette.to_px(Vector2(float(tile.x), float(tile.y))),
		palette.to_px(Vector2(float(tile.x + 1), float(tile.y))),
		palette.to_px(Vector2(float(tile.x + 1), float(tile.y + 1))),
		palette.to_px(Vector2(float(tile.x), float(tile.y + 1))),
	])


## 框选矩形：世界坐标（格）→ 屏幕多边形（透视下也是一个四边形）
func _draw_drag_box() -> void:
	if not drag_active:
		return
	if drag_rect.size.x <= 0.0 and drag_rect.size.y <= 0.0:
		return
	var quad := PackedVector2Array([
		palette.to_px(drag_rect.position),
		palette.to_px(drag_rect.position + Vector2(drag_rect.size.x, 0.0)),
		palette.to_px(drag_rect.position + drag_rect.size),
		palette.to_px(drag_rect.position + Vector2(0.0, drag_rect.size.y)),
	])
	var c := Color(0.75, 0.95, 1.0, 0.9)
	draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.12))
	var closed := quad.duplicate()
	closed.append(quad[0])
	draw_polyline(closed, c, 2.0)
	draw_count += 1
