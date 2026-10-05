## terrain_view.gd —— 地形渲染（菱形投影：等距 / 斜俯视 45°）
##
## ★ 这里**只画**，通行性判定一律读 logic/map_data.gd 的地形网格。
##   绝不把 TileMapLayer 的图块数据当权威 —— 否则换一张图集就能悄悄改变玩法
##   （而且这种 bug 极难查：看起来只是换了个贴图，见 docs/pitfalls.md 2.2）。
##
## ★★ 菱形档的写法（与「正放矩形」那版的区别，改之前先读）：
##   · 每个地块画成 `palette.tile_poly()` 给的**菱形**（四个顶点），不再是 `Rect2`；
##   · **按地形种类合批**：同一种地形的所有菱形拼成一个大的 `PackedVector2Array`，
##     一次 `draw_polygon` 画完 —— 594 格只有 **4 次** draw 调用（草地两色 / 森林 / 山），
##     而不是「每格一次」。这是菱形档最容易踩的性能坑（逐格 draw 会拆散批次）。
##   · 山体的亮边：`draw_polyline` 每格一圈（描边本来就退让不了，且格子数量有限）。
##
## ⚠️ 顶点是**每帧现算**的（`tile_poly` × 格数）。这是刻意的：
##    它换来的是「改投影角度立刻生效」，而且 594 格 × 4 次点乘在内层循环里可以忽略。
##    真到 100×100（1 万格）时再考虑缓存 —— 判据是 `tests/bench_fps.gd` 的实测数字。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const Palette2DRes = preload("res://view/palette2d.gd")

var cfg: ConfigRes = null
var map = null

var _color_grass: Color
var _color_grass_alt: Color
var _color_forest: Color
var _color_mountain: Color
var _color_mountain_edge: Color
var _color_grid: Color

## ★ 诊断（只有测试读它）：最近一次 `_draw()` 真的发出了几次地形绘制命令。
## 为什么要有：菱形档把「逐格画」改成了「按种类合批」，而**合批写错会什么都不画**
## （例如把顶点拼进值语义的打包数组的副本里）—— 那种失败既不报错也不改状态，
## 只有留下一个可数的痕迹才钉得住（与 unit_view.icon_draw_count 同一条理由）。
var draw_count: int = 0
## 最近一次铺进去的地块总数（用来断言「一格都没漏」）。
var tile_count: int = 0


func setup(p_cfg: ConfigRes, p_map) -> void:
	cfg = p_cfg
	map = p_map
	_color_grass = cfg.color("grass")
	_color_grass_alt = cfg.color("grass_alt")
	_color_forest = cfg.color("forest")
	_color_mountain = cfg.color("mountain")
	_color_mountain_edge = cfg.color("mountain_edge")
	_color_grid = cfg.color("grid")
	queue_redraw()


func _draw() -> void:
	draw_count = 0
	tile_count = 0
	if cfg == null or map == null:
		return

	var cols: int = int(map.cols)
	var rows: int = int(map.rows)
	if cols <= 0 or rows <= 0:
		return

	# ---- 一遍扫过去，把每种地形的菱形分别拼进自己的顶点数组（合批的关键）----
	# 6 个顶点 = 1 个菱形（三角扇：0,1,2 + 0,2,3）
	var grass := PackedVector2Array()
	var grass_alt := PackedVector2Array()
	var forest := PackedVector2Array()
	var mountain := PackedVector2Array()
	var mountain_edges := PackedVector2Array()

	for ty in rows:
		for tx in cols:
			# ⚠️ 地图外的格子（exists = false）不画 —— 露出来的是背景。
			#    菱形地图的「外沿」因此是不规则的（贴边挖空的图也能正确显示）。
			if not map.tile_exists(tx, ty):
				continue
			var q := Palette2DRes.tile_poly(tx, ty, cfg)
			var t := String(map.terrain.get_cell(tx, ty))
			var target: PackedVector2Array
			if t == "mountain":
				target = mountain
			elif t == "forest":
				target = forest
			else:
				# 棋盘格微差：让地块边界看得出来，又不至于像格子纸
				target = grass if (tx + ty) % 2 == 0 else grass_alt
			_append_quad(target, q)
			if t == "mountain":
				# 山体描一圈亮边：地形是可通行性的唯一真相，画得让人一眼看出来。
				# ⚠️ 每段在两个端点上各画一次是有意的（与 zone_view 的轮廓同一条口径），
				#    这样相邻菱形之间的接缝会被两边的线头盖住，不会留下发丝缝。
				for i in 4:
					mountain_edges.append(q[i])
					mountain_edges.append(q[(i + 1) % 4])
			tile_count += 1

	# ---- 每种地形一次 draw_polygon（四次调用，与格数无关）----
	_draw_batch(grass, _color_grass)
	_draw_batch(grass_alt, _color_grass_alt)
	_draw_batch(forest, _color_forest)
	_draw_batch(mountain, _color_mountain)
	if not mountain_edges.is_empty():
		draw_multiline(mountain_edges, _color_mountain_edge, 2.0)
		draw_count += 1

	# ---- 网格线：**逐格描边**（透视下这是唯一正确的画法）----
	# ★★ 为什么不能像正俯视那版那样「每列一条竖线 + 每行一条横线」：
	#    透视下**横线会收敛到灭点**，而一条横线要跨整张地图的宽度 ——
	#    把它画成一条直线段只能在**那个 y 的边界**上对，中间全是错的
	#    （实测的样子是「线飞出去、穿过不是它的地方」）。
	#    ⇒ 逐格描四条边：段数 = 4 × 格数，仍然只有**一次** draw_multiline。
	# ⚠️ 每段在两个端点上各画一次（与 zone_view 的轮廓同一条口径），
	#    这样相邻格之间的接缝会被两边的线头盖住，不留发丝缝。
	var grid_line := PackedVector2Array()
	for ty in rows:
		for tx in cols:
			if not map.tile_exists(tx, ty):
				continue
			var gq := Palette2DRes.tile_poly(tx, ty, cfg)
			if gq.size() < 4:
				continue
			for i in 4:
				grid_line.append(gq[i])
				grid_line.append(gq[(i + 1) % 4])
	if not grid_line.is_empty():
		# ⚠️ `draw_multiline` 每次只接受**最多 2 段**（4 个点）——
		#    实测传一个大数组会报 `Condition "pc == 0 || pc > 4" is true` 并且什么都不画。
		#    所以按 4 个点一批切开发。批数 ≈ 2×格数，但每批只是一次很便宜的调用。
		var i := 0
		while i + 4 <= grid_line.size():
			draw_multiline(PackedVector2Array([
				grid_line[i], grid_line[i + 1], grid_line[i + 2], grid_line[i + 3]]),
				_color_grid, 1.0)
			i += 4
		draw_count += 1

	# ---- 地图边界：给镜头一个「到底了」的参照（透视下是一个梯形）----
	var border := Palette2DRes.map_poly(cfg, cols, rows)
	if border.size() >= 4:
		var outline := border.duplicate()
		outline.append(border[0])
		draw_polyline(outline, Color(1, 1, 1, 0.18), 2.0)
		draw_count += 1


## 把一个四边形拆成**两个三角形**拼进目标数组。
##
## ★★ 为什么必须拆（本轮实测的报错，改之前先读）：
##    `draw_polygon` 在 Godot 里是**三角形数组**语义（每 3 个顶点一个三角形），
##    不是「三角扇」。我第一版把一个区块里**多个地块**的顶点全拼成一个大数组
##    直接丢给 `draw_polygon`，于是它试图把不相邻的地块顶点三角化 ⇒
##       ERROR: Invalid polygon data, triangulation failed.
##       Condition "indices.is_empty()" is true.
##    而且这条报错**危害远超「少画几块地」**：它在 `_draw()` 里抛出，
##    会打断这一帧后续所有画布提交（实测：排在后面的**单位与字全部不见了**）。
##    ⇒ 正确做法：每个四边形自己拆成 2 个三角形（点数 4 → 6），首尾闭合。
## ★ 参数必须是 `PackedVector2Array`（**引用语义**）：打包数组一旦按值传出去
##   （例如 `var b := arr` 再 append），append 只会改到那个临时副本、
##   桶永远是空的、什么都不画、还不报错（与 unit_view 分桶踩过的是同一个坑，见 pitfalls 5.50）。
static func _append_quad(target: PackedVector2Array, q: PackedVector2Array) -> void:
	if q.size() < 4:
		return
	# 三角形 1：0-1-2    三角形 2：0-2-3
	target.append(q[0])
	target.append(q[1])
	target.append(q[2])
	target.append(q[0])
	target.append(q[2])
	target.append(q[3])


## 画一批地形（顶点已经是三角形：每 3 点一个）。
##
## ★★ 三条实测出来的硬限制（都踩过，别再回头）：
##  1. **不能用 `draw_polygon`**：它把顶点丢给引擎的**三角化器**，对我们这种
##     「很多四边形拼成的大数组」直接报 `Invalid polygon data, triangulation failed.`
##     —— 而这条报错在 `_draw()` 里抛出会**打断整帧后续所有画布提交**
##     （实测：排在后面的**单位与字全部不见了**，就是用户报的那个现象）。
##  2. **`draw_primitive` 每次最多 4 个点**（实测：传 6 点会报
##     `Condition "pc == 0 || pc > 4" is true` 且什么都不画）。
##  3. `draw_multiline` 同一条限制。
##   ⇒ 只能**每个三角形发一次**（3 点）。批次数 = 2×格数，
##     每批都不做三角化，是这里能选的最便宜且**正确**的画法。
##   ★ 要再快就得把地形烘成一张贴图（与 `fog_view` 同一条路），
##     那是下一步的事（见 dev_plan_9 的性能项），不是现在。
func _draw_batch(poly: PackedVector2Array, color: Color) -> void:
	if poly.is_empty() or not is_inside_tree():
		return
	var quad := PackedVector2Array()
	var i := 0
	# 顶点是 6 点/四边形（两个三角形）⇒ 每 6 点还原成一个四边形，单独画一次。
	# ★ 用 `draw_colored_polygon`（**四边形**，上限 4 点，正好合法）——
	#   比 `draw_primitive`（上限也是 4 点，所以 6 点的四边形根本发不出去）更合适。
	while i + 5 < poly.size():
		quad.clear()
		quad.append(poly[i])
		quad.append(poly[i + 1])
		quad.append(poly[i + 2])
		quad.append(poly[i + 5])
		draw_colored_polygon(quad, color)
		draw_count += 1
		i += 6
