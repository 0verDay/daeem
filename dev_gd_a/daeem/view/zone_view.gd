## zone_view.gd —— 区块轮廓 + 占领进度（对应 HTML 版 render.js 的区块那一段）
##
## 数量少且不需要交互（24 块），所以一个节点画全部。
## 进度条从下往上填充：颜色取「当前 owner（或领先者）」的阵营色。
##
## ⚠️ 只读 world.zones，不改任何逻辑状态。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

var cfg: ConfigRes = null
var world = null

## 按 N 开关区块名（对应 HTML 版的 N 键）
var show_names: bool = true

## ⚠️ 这里**不再**读 `colors.zone_line`（旧的 10% 白 + 固定 1px 那一档）：
##   那条线在深色地形上基本看不见，现在换成下面的 `zone_stroke*` 口径。
##   ⚠️ config 里那个键**刻意留着**（`tools/map_editor/model.py` 的 DEFAULT_COLORS
##   还写着同一个键名），删它属于「顺带改编辑器」，而这一轮明确不动编辑器。
var _c_neutral: Color
var _c_progress: Color
var _font: Font
var _font_size: int = 12

## 描边（本轮：所有区划都有清晰的加粗白色描边）。数值全在 config 的 colors.zone_* 里。
##   · 无主区划 → 纯白主线；有主区划 → 该阵营主色主线（归属照样看得出来）
##   · 主线外面再垫一圈半透明白光晕：亮地形（山体灰）上白线也不会糊掉
var _c_stroke: Color                 # 无主区划的描边色（纯白）
var _c_stroke_owned: Color           # 有主区划的兜底色（正常走 faction_color(main)）
var _c_halo: Color                   # 外圈光晕色
var _w_stroke: float = 3.0           # 无主区划主线宽（px）
var _w_stroke_owned: float = 2.5     # 有主区划主线宽（px）
var _halo_delta: float = 2.0         # 光晕比主线每边多出来的宽度（px）

## ★★ 轮廓几何**缓存在这里**：形状不随归属变，只有颜色随归属变。
## 为什么必须缓存：按地块算一遍轮廓 = 每格问 4 次 `zone_at`（100×100 图上是 4 万次）。
## 从前那 23 ms/帧的教训就是把「每帧重算几何」当成了免费的（见上面 _shape 的注释 / pitfalls 2.0）。
## 缓存之后：几何只在 setup（换地图 / 重开一局）算一次，归属一变只做两次 draw_multiline。
var _edges_by_zone: Array = []       # [zone_id] = PackedVector2Array（该区块的轮廓线段）
var _edges_all: PackedVector2Array = PackedVector2Array()
var _edges_geom_ready: bool = false
var _geom_sig: String = ""

## ★★ 静态形状（底色 + 地块边界轮廓）画在**子节点**上。
##
## 为什么必须拆开：区块形状原来和进度条一起、每帧重画一遍，而它是**按地块**画的 ——
## 100×100 图上就是每帧 1 万次 draw_rect + 4 万次 zone_at（实测 23 ms/帧，
## 占当时整帧 26 ms 的绝大部分，而逻辑只有 0.16 ms）。
## 形状只在**归属变化**时才变（占下来 / 被抢走 / 换地图），进度条才需要每帧动。
## 拆开之后每帧只剩 24 个进度条 + 24 行名字。
var _shape: Node2D = null
var _shape_sig: String = ""


class ZoneShape:
	extends Node2D
	var owner_view = null          # 指向 zone_view，真正的画法在那边

	func _draw() -> void:
		if owner_view != null:
			owner_view.draw_shapes(self)


func setup(p_cfg: ConfigRes, p_world, p_font: Font = null, p_font_size: int = 12) -> void:
	cfg = p_cfg
	world = p_world
	_font = p_font
	_font_size = p_font_size
	_c_neutral = cfg.color("zone_neutral")
	_c_progress = cfg.color("zone_progress")
	# 描边口径：config 里缺项时退回「3px 纯白 + 2px 光晕」——
	# 这层兜底是刻意的（老地图 / 老配置也要看得清），但不该悄悄生效：
	# 改 config 的键名忘了改这里，画面会退回默认值而不是报错，所以测试里钉了取值口径。
	_c_stroke = cfg.color("zone_stroke")
	_c_stroke_owned = cfg.color("zone_stroke_owned")
	_c_halo = cfg.color("zone_halo")
	_w_stroke = cfg.num("colors.zone_stroke_width", 3.0)
	_w_stroke_owned = cfg.num("colors.zone_stroke_width_owned", 2.5)
	_halo_delta = cfg.num("colors.zone_halo_delta", 2.0)
	_edges_geom_ready = false
	_geom_sig = ""
	if _shape == null:
		_shape = ZoneShape.new()
		_shape.name = "ZoneShape"
		_shape.owner_view = self
		_shape.z_index = -1        # 形状压在进度条下面
		add_child(_shape)
	_shape_sig = ""
	sync()


## 每帧调用：形状只在归属变了时重画，进度条每次都重画。
func sync() -> void:
	var sig := _owner_signature()
	if sig != _shape_sig:
		_shape_sig = sig
		if _shape != null:
			_shape.queue_redraw()
	queue_redraw()


## 归属签名：只要「每个区块属于谁」这一串没变，形状就不用重画。
## （地块明细与包围盒都来自地图，换地图时会被 _owner_signature 之外的重建接住 —— 见 setup。）
func _owner_signature() -> String:
	if world == null or world.zones == null:
		return ""
	var parts: Array = []
	for z in world.zones.zones:
		parts.append(String(z["owner"]))
	return "|".join(parts)


## 静态形状：区块底色（按地块）+ 沿地块边界的轮廓。由子节点在自己的 _draw 里调。
##
## ★ 轮廓走**两遍 draw_multiline**（光晕一遍、主线一遍），而不是「每段画两次线」：
##   · 段数一样多，draw 调用少一半；
##   · 主线画在光晕之上，重叠处的半透明光晕不会被反复叠加成一块白斑。
func draw_shapes(ci: Node2D) -> void:
	if cfg == null or world == null:
		return
	var cell: float = cfg.cell_px
	for z in world.zones.zones:
		# 区块形状：**按地块画**。
		#   · 地图编辑器划出来的区块可以是非矩形的（L 形、贴着地图边界的八边形…），
		#     只按包围盒画会把地图外的空地也涂成领地；
		#   · 老地图（6×4 均分）每个区块的地块刚好填满自己的包围盒，所以这条路
		#     画出来与从前逐像素一致。
		var cells: Array = z.get("tiles", [])
		var r := _zone_rect(z)

		# 底色：无主 = 暗黄，有主 = 该阵营的浅色
		var fill := _c_neutral
		if String(z["owner"]) != "":
			var owner_color := cfg.faction_color(String(z["owner"]), "main")
			fill = Color(owner_color.r, owner_color.g, owner_color.b, 0.13)
		if cells.is_empty():
			ci.draw_rect(r, fill, true)
		else:
			for t in cells:
				var tile: Vector2i = t
				ci.draw_rect(Rect2(Vector2(tile.x * cell, tile.y * cell),
					Vector2(cell, cell)), fill, true)

	# 轮廓：沿着**地块的边界**画（非矩形区块的轮廓才是它的真实形状）
	_ensure_outline_geometry(cell)
	_draw_outlines(ci)


func _draw() -> void:
	if cfg == null or world == null:
		return
	var cell: float = cfg.cell_px
	for z in world.zones.zones:
		var r := _zone_rect(z)

		# 占领进度：**只有一条**（严格阻塞下同一时刻最多一方在读，见 zone.update 的规则 4）。
		#
		# 三种状态（逻辑层给，视图只取色）：
		#   · reading  在涨      → 正常填充，颜色 = 那一方的阵营色
		#   · frozen   冻住      → 双方都在区块里，谁都不涨 → **加一圈白描边**
		#   · decaying 往回退    → 人不在场（移出 / 被打光），条自己慢慢回落
		var bar: Dictionary = world.zones.capture_bar(z)
		var value := clampf(float(bar["value"]), 0.0, 1.0)
		if value > 0.001:
			var bar_faction := String(bar["faction"])
			var rc := _bar_rect_from_bottom(r, r.size.y * value)
			draw_rect(rc, _bar_color(bar_faction), true)
			# 生长那一边画一条更亮的线（深色地图上纯半透明块不容易注意到）
			draw_line(Vector2(rc.position.x, rc.position.y), Vector2(rc.end.x, rc.position.y),
				_bar_edge_color(bar_faction), 2.0)
			if String(bar["state"]) == "frozen":
				# 争抢中：整条套一圈白描边 —— 一眼看出「停住了」（手玩要求）
				draw_rect(rc.grow(1.0), Color(1.0, 1.0, 1.0, 0.85), false, 2.0)

		if show_names and _font != null:
			var label := String(z["name"])
			draw_string(_font, r.position + Vector2(6.0, _font_size + 4.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(1, 1, 1, 0.45))


## 区块的包围盒：进度条与名字用它（地块明细只用来画形状）
func _zone_rect(z: Dictionary) -> Rect2:
	var cell: float = cfg.cell_px
	var x0 := int(z["x0"])
	var y0 := int(z["y0"])
	var x1 := int(z["x1"])
	var y1 := int(z["y1"])
	if x1 < x0 or y1 < y0:
		return Rect2(Vector2(x0 * cell, y0 * cell), Vector2.ZERO)
	return Rect2(Vector2(x0 * cell, y0 * cell),
		Vector2((x1 - x0 + 1) * cell, (y1 - y0 + 1) * cell))


## 沿地块边界算区块轮廓：只在「邻格不属于同一区块（或不存在）」的那条边上画线。
## 与地图编辑器里看到的那圈边界是同一套规则；每段在两个端点上各画一次，
## 好让相邻段之间的接缝被两边的线头盖住（只有一段的线头会留下一条发丝缝）。
##
## ★ 只在 setup / 换地图时跑一次（结果缓存在 _edges_by_zone），不每帧跑。
func _ensure_outline_geometry(cell: float, force: bool = false) -> void:
	var sig := _geometry_signature(cell)
	if not force and _edges_geom_ready and sig == _geom_sig:
		return
	_geom_sig = sig
	_edges_geom_ready = true
	_edges_by_zone.clear()
	_edges_all = PackedVector2Array()
	if world == null or world.zones == null:
		return

	var zones: Array = world.zones.zones
	# 下标就是 zone_id（`zone_at` 返回的 id 与 zones 的下标是同一套，见 zone.gd）
	_edges_by_zone.resize(zones.size())
	for i in zones.size():
		_edges_by_zone[i] = PackedVector2Array()

	var dirs := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	var seen := {}
	for z in zones:
		var zid := int(z["id"])
		if zid < 0 or zid >= _edges_by_zone.size():
			continue
		var cells: Array = z.get("tiles", [])
		if cells.is_empty():
			# 老地图兜底：区块没有地块明细时按包围盒的矩形轮廓画（与从前一致）
			_append_rect_edges(_edges_by_zone[zid], _zone_rect(z))
			continue
		var segs: PackedVector2Array = _edges_by_zone[zid]
		for t in cells:
			var tile: Vector2i = t
			# ⚠️ 地图数据里可能出现重复地块（两行单元格填了同一个格）：
			#    不去重的话同一条边会画两遍，半透明光晕就会被叠成一块白斑。这里只处理一次。
			var key: int = tile.y * world.zones.cols + tile.x
			if seen.has(key):
				continue
			seen[key] = true
			var x0 := float(tile.x) * cell
			var y0 := float(tile.y) * cell
			var x1 := x0 + cell
			var y1 := y0 + cell
			for d in dirs:
				var nb = world.zones.zone_at(tile.x + d.x, tile.y + d.y)
				if nb != null and int(nb["id"]) == zid:
					continue
				if d.y == -1:
					segs.append(Vector2(x0, y0))
					segs.append(Vector2(x1, y0))
				elif d.y == 1:
					segs.append(Vector2(x0, y1))
					segs.append(Vector2(x1, y1))
				elif d.x == -1:
					segs.append(Vector2(x0, y0))
					segs.append(Vector2(x0, y1))
				else:
					segs.append(Vector2(x1, y0))
					segs.append(Vector2(x1, y1))
		_edges_by_zone[zid] = segs
		_edges_all.append_array(segs)


## 几何签名：地块明细 + 格宽。换地图 / 地图被编辑器改过时它才变。
func _geometry_signature(cell: float) -> String:
	if world == null or world.zones == null:
		return ""
	var parts: Array = [str(cell)]
	for z in world.zones.zones:
		parts.append("%d:%d" % [int(z["id"]), (z.get("tiles", []) as Array).size()])
	return "|".join(parts)


## 把一个矩形拆成 4 条边（同样每段画两次端点的口径）。
func _append_rect_edges(segs: PackedVector2Array, r: Rect2) -> void:
	var a := r.position
	var b := Vector2(r.end.x, r.position.y)
	var c := r.end
	var d := Vector2(r.position.x, r.end.y)
	for seg in [[a, b], [b, c], [c, d], [d, a]]:
		segs.append(seg[0])
		segs.append(seg[1])


## 画所有区块的轮廓：先一遍光晕、再一遍主线（白色 / 阵营色）。
##
## ★ 按**归属分组**画（无主一组，每个阵营各一组），而不是每块各画一次：
##   同色的线段合并成一次 draw_multiline，区块一多就省下几十次 draw 调用，观感完全一样。
## ★★ 关键：分组用的是**阵营 id 本身**，不是「有主 / 无主」两档。
##   合作模式下一张图上会有两个玩家阵营同时占着区划 —— 要是把「所有有主的区块」
##   合成一组、拿第一个阵营的颜色去画，另一个阵营的区划就会被描成别人的颜色
##   （"有主区划仍用阵营色" 这条口径当场失效，而且在单机下测不出来）。
func _draw_outlines(ci: Node2D) -> void:
	if _edges_all.is_empty():
		return
	var groups := _outline_groups()
	var neutral: PackedVector2Array = groups["neutral"]
	# 外圈光晕：半透明白，比主线每边宽 _halo_delta
	if not neutral.is_empty():
		ci.draw_multiline(neutral, _c_halo, _w_stroke + _halo_delta * 2.0)
	for f in groups["owned"]:
		ci.draw_multiline(groups["owned"][f], _c_halo, _w_stroke_owned + _halo_delta * 2.0)
	# 主线：无主 = 纯白；有主 = **该阵营自己的**主色
	if not neutral.is_empty():
		ci.draw_multiline(neutral, _c_stroke, _w_stroke)
	for f in groups["owned"]:
		ci.draw_multiline(groups["owned"][f], _stroke_color_owned(String(f)), _w_stroke_owned)


## 把缓存的边按归属分组：`{"neutral": PackedVector2Array, "owned": {阵营id: PackedVector2Array}}`。
##
## ★★ 为什么必须按**阵营 id**分组，而不是「有主 / 无主」两档：
##   合作模式下一张图上会有两个玩家阵营同时占着区划 —— 要是把「所有有主的区块」
##   合成一组、拿第一个阵营的颜色去画，另一个阵营的区划就会被描成别人的颜色
##   （「有主区划仍用阵营色」这条口径当场失效，而且在单机下测不出来）。
## ★ 单独拆成一个纯函数是为了**能测**：headless 下画到 CanvasItem 上的东西取不回来，
##   但「哪一块分到哪一组」是纯数据，可以直接断言（见 tests/test_view.gd）。
func _outline_groups() -> Dictionary:
	var zones: Array = world.zones.zones
	var neutral := PackedVector2Array()
	var owned := {}
	for i in _edges_by_zone.size():
		var segs: PackedVector2Array = _edges_by_zone[i]
		if segs.is_empty():
			continue
		var owner := ""
		if i < zones.size():
			owner = String((zones[i] as Dictionary).get("owner", ""))
		# ★ 描边要压在**所有**底色之上、进度条之下：底色是在上面的循环里逐块涂的，
		#   如果描边跟着每块的底色一起画，后画的区块底色会盖掉先画的区块描边。
		if owner == "":
			neutral.append_array(segs)
		else:
			var list: PackedVector2Array = owned.get(owner, PackedVector2Array())
			list.append_array(segs)
			owned[owner] = list
	return {"neutral": neutral, "owned": owned}


## 有主区划的描边色：该阵营的主色；拿不到阵营色时退回 config 的 zone_stroke_owned。
func _stroke_color_owned(owner: String) -> Color:
	if owner == "" or cfg == null:
		return _c_stroke_owned
	return cfg.faction_color(owner, "main")



## 进度条在区块里的矩形：从**底边**往上 h 像素（我方）
func _bar_rect_from_bottom(r: Rect2, h: float) -> Rect2:
	return Rect2(Vector2(r.position.x, r.position.y + r.size.y - h), Vector2(r.size.x, h))


## 进度条的填充色：该阵营的 main 色 + `colors.zone_progress` 的透明度
## （透明度仍然在 config 里，改一处就够；阵营色让「谁在推」一眼可辨）
func _bar_color(faction: String) -> Color:
	if faction == "":
		return _c_progress
	var fc := cfg.faction_color(faction, "main")
	return Color(fc.r, fc.g, fc.b, _c_progress.a)


## 进度条「生长那一边」的亮线：深色地图上纯半透明色块不太容易注意到
func _bar_edge_color(faction: String) -> Color:
	var c := _bar_color(faction)
	return Color(c.r, c.g, c.b, minf(1.0, c.a + 0.35))
