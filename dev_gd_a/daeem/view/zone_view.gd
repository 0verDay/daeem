## zone_view.gd —— 区块轮廓 + 占领进度（菱形投影：等距 / 斜俯视 45°）
##
## 数量少且不需要交互（24 块 / 一张图几百格），所以一个节点画全部。
## 进度条**从下往上**填充（屏幕上就是从上往上长，与投影无关）。
##
## ⚠️ 只读 world.zones，不改任何逻辑状态。
##
## ★★ 菱形档下有一处**结构性简化**（改之前先读）：
##   老版本把「区块轮廓的线段几何」**缓存**起来（只在归属变化 / 换图时重算），
##   理由是 100×100 图上「每帧 1 万次 draw_rect + 4 万次 zone_at = 23 ms/帧」。
##   菱形档里那套缓存**不再成立**：轮廓点现在由投影决定（`tile_poly`），
##   换投影角度就得全部作废，而且线段是斜的、没法像矩形那样合并。
##   所以这一版**每帧现算**，但把成本压到最低：
##     · 只遍历**区块地块**（`zone.tiles`），不是全图格子；
##     · 每个格子只查 4 次邻接，且同一个格子只处理一次（去重）；
##     · 线段按阵营分组合并成 `draw_multiline`（与从前同一条口径）。
##   ⚠️ 判据依旧是 `tests/bench_fps.gd`：真到 100×100 + 大量非矩形区块时，
##      正确的下一步是「把区块轮廓烘成一张贴图」（与 fog_view 同一条路），
##      而不是把老缓存复活。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const Palette2DRes = preload("res://view/palette2d.gd")

var cfg: ConfigRes = null
var world = null

## 按 N 开关区块名（对应 HTML 版的 N 键）
var show_names: bool = true

## ⚠️ 这里**不再**读 `colors.zone_line`（旧的 10% 白 + 固定 1px 那一档）：
##   那条线在深色地形上基本看不见，现在换成下面的 `zone_stroke*` 口径。
var _c_neutral: Color
var _c_progress: Color
var _font: Font
var _font_size: int = 12

## 描边（所有区划都有清晰的加粗白色描边）。数值全在 config 的 colors.zone_* 里。
var _c_stroke: Color                 # 无主区划的描边色（纯白）
var _c_stroke_owned: Color           # 有主区划的兜底色（正常走 faction_color(main)）
var _c_halo: Color                   # 外圈光晕色
var _w_stroke: float = 3.0           # 无主区划主线宽（px）
var _w_stroke_owned: float = 2.5     # 有主区划主线宽（px）
var _halo_delta: float = 2.0         # 光晕比主线每边多出来的宽度（px）

## ★ 诊断（只有测试读它）：最近一次 `_draw()` / `draw_shapes()` 发出了几次绘制命令。
var draw_count: int = 0

## ★★ 静态形状（区块底色 + 轮廓）画在**子节点**上。
## 为什么仍然拆开：区块形状只在**归属变化**时才变（占下来 / 被抢走 / 换地图），
## 而进度条每帧都在动。拆开之后每帧只剩 24 个进度条 + 24 行名字。
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
	_c_stroke = cfg.color("zone_stroke")
	_c_stroke_owned = cfg.color("zone_stroke_owned")
	_c_halo = cfg.color("zone_halo")
	_w_stroke = cfg.num("colors.zone_stroke_width", 3.0)
	_w_stroke_owned = cfg.num("colors.zone_stroke_width_owned", 2.5)
	_halo_delta = cfg.num("colors.zone_halo_delta", 2.0)
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
func _owner_signature() -> String:
	if world == null or world.zones == null:
		return ""
	var parts: Array = []
	for z in world.zones.zones:
		parts.append(String(z["owner"]))
	return "|".join(parts)


## 静态形状：区块底色（按地块的菱形）+ 沿地块边界的轮廓。
func draw_shapes(ci: Node2D) -> void:
	if cfg == null or world == null:
		return
	for z in world.zones.zones:
		var cells: Array = z.get("tiles", [])
		# 底色：无主 = 暗黄，有主 = 该阵营的浅色
		var fill := _c_neutral
		if String(z["owner"]) != "":
			var owner_color := cfg.faction_color(String(z["owner"]), "main")
			fill = Color(owner_color.r, owner_color.g, owner_color.b, 0.13)
		if cells.is_empty():
			# 老地图兜底：没有地块明细时按包围盒的**投影四边形**涂（与从前语义一致）
			var box := _zone_box_poly(z)
			if box.size() >= 4:
				var tri := PackedVector2Array([box[0], box[1], box[2], box[0], box[2], box[3]])
				ci.draw_colored_polygon(box, fill)
			continue
		# ★ 把这一区块所有地块的四边形拼成**一个**三角形数组，一次画完。
		# ⚠️ 用 draw_primitive（显式三角形）而不是 draw_polygon —— 后者会走引擎的
		#    三角化器，对这种「很多四边形拼成的大数组」会报 triangulation failed，
		#    而那会在 _draw() 里打断整帧的后续提交（单位与字全消失）。见 terrain_view 的说明。
		var poly := PackedVector2Array()
		for t in cells:
			var tile: Vector2i = t
			if cfg == null:
				continue
			var q := Palette2DRes.tile_poly(tile.x, tile.y, cfg)
			if q.size() < 4:
				continue
			poly.append(q[0])
			poly.append(q[1])
			poly.append(q[2])
			poly.append(q[0])
		# ★ 把这一区块的地块四边形**逐个**画（每个四边形 4 点，正好在
		#    `draw_colored_polygon` 的上限内）。合并成一个大数组会踩到
		#    「三角化失败」与「pc > 4」两条限制（见 terrain_view 的说明）。
		if not poly.is_empty():
			var k := 0
			while k + 3 < poly.size():
				ci.draw_colored_polygon(PackedVector2Array([
					poly[k], poly[k + 1], poly[k + 2], poly[k + 3]]), fill)
				k += 4

	# 轮廓：沿着**地块的边界**画（非矩形区块的轮廓才是它的真实形状）
	_draw_outlines(ci)


func _draw() -> void:
	draw_count = 0
	if cfg == null or world == null:
		return
	for z in world.zones.zones:
		var r := _zone_rect(z)
		if r.size == Vector2.ZERO:
			continue

		# 占领进度：**只有一条**（严格阻塞下同一时刻最多一方在读，见 zone.update 的规则 4）。
		#
		# 三种状态（逻辑层给，视图只取色）：
		#   · reading  在涨      → 正常填充，颜色 = 那一方的阵营色
		#   · frozen   冻住      → 双方都在区块里，谁都不涨 → **加一圈白描边**
		#   · decaying 往回退    → 人不在场（移出 / 被打光），条自己慢慢回落
		#
		# ★ 菱形档：进度条仍然画成**竖直的矩形**（它是 UI 读数，不是地面上的东西）——
		#   位置取区块包围盒在屏幕上的外接框。跟着菱形走会让条变成斜的、反而不易读。
		var bar: Dictionary = world.zones.capture_bar(z)
		var value := clampf(float(bar["value"]), 0.0, 1.0)
		if value > 0.001:
			var bar_faction := String(bar["faction"])
			var rc := _bar_rect_from_bottom(r, r.size.y * value)
			draw_rect(rc, _bar_color(bar_faction), true)
			draw_line(Vector2(rc.position.x, rc.position.y), Vector2(rc.end.x, rc.position.y),
				_bar_edge_color(bar_faction), 2.0)
			if String(bar["state"]) == "frozen":
				draw_rect(rc.grow(1.0), Color(1.0, 1.0, 1.0, 0.85), false, 2.0)
			draw_count += 1

		if show_names and _font != null:
			var label := String(z["name"])
			draw_string(_font, r.position + Vector2(6.0, _font_size + 4.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, -1, _font_size, Color(1, 1, 1, 0.45))
			draw_count += 1


## 区块在**世界像素**里的外接框（进度条 / 名字的位置用它）。
##
## ★ 菱形档：地块的四个角不再是轴对齐的，所以「包围盒」要用四个角的投影极值来算。
##   ⚠️ 它不是区块占的那块地（那是菱形），只是它的外接矩形 —— 进度条与文字需要一个
##     轴对齐的落点。区块位置的整体观感由 `draw_shapes()` 的菱形负责。
func _zone_rect(z: Dictionary) -> Rect2:
	var cells: Array = z.get("tiles", [])
	if cells.is_empty():
		return _rect_of_poly(_zone_box_poly(z))
	var poly := PackedVector2Array()
	for t in cells:
		var tile: Vector2i = t
		poly.append_array(Palette2DRes.tile_poly(tile.x, tile.y, cfg))
	return _rect_of_poly(poly)


## 老地图兜底：没有地块明细时，用包围盒格范围投影出来的四边形。
func _zone_box_poly(z: Dictionary) -> PackedVector2Array:
	var x0 := int(z["x0"])
	var y0 := int(z["y0"])
	var x1 := int(z["x1"])
	var y1 := int(z["y1"])
	if x1 < x0 or y1 < y0:
		return PackedVector2Array()
	return Palette2DRes.quad_poly(float(x0), float(y0), float(x1 + 1), float(y1 + 1), cfg)


## 一个「每个顶点同一个颜色」的顶点色数组（`draw_primitive` 要求逐点颜色）。
static func _color_array(n: int, c: Color) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(n)
	out.fill(c)
	return out


static func _rect_of_poly(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)


## 画所有区块的轮廓：先一遍光晕、再一遍主线（白色 / 阵营色）。
##
## ★★ 按**阵营 id** 分组画（无主一组，每个阵营各一组），而不是每块各画一次：
##   同色的线段合并成一次 draw_multiline，区块一多就省下几十次 draw 调用。
## ★★ 关键：分组用的是**阵营 id 本身**，不是「有主 / 无主」两档 ——
##   合作模式下一张图上会有两个玩家阵营同时占着区划，混成一组就会描错颜色。
func _draw_outlines(ci: Node2D) -> void:
	if world == null or world.zones == null:
		return
	var groups := _outline_groups()
	var neutral: PackedVector2Array = groups["neutral"]
	if not neutral.is_empty():
		ci.draw_multiline(neutral, _c_halo, _w_stroke + _halo_delta * 2.0)
	for f in groups["owned"]:
		ci.draw_multiline(groups["owned"][f], _c_halo, _w_stroke_owned + _halo_delta * 2.0)
	if not neutral.is_empty():
		ci.draw_multiline(neutral, _c_stroke, _w_stroke)
	for f in groups["owned"]:
		ci.draw_multiline(groups["owned"][f], _stroke_color_owned(String(f)), _w_stroke_owned)


## 把区块的边按归属分组：`{"neutral": ..., "owned": {阵营id: ...}}`。
##
## ★★ 每帧现算（理由见文件头）：只走区块自己的地块 + 4 邻接，且同格只处理一次。
## ★ 每条边在两端的格子上各画一次（两侧的线头互相盖住接缝，避免发丝缝）。
func _outline_groups() -> Dictionary:
	var neutral := PackedVector2Array()
	var owned := {}
	if world == null or world.zones == null or cfg == null:
		return {"neutral": neutral, "owned": owned}
	var zones: Array = world.zones.zones
	# 四邻：上 / 下 / 左 / 右。哪条边是「外沿」就取菱形那条边的两个顶点。
	#   菱形顶点顺序 = [右, 下, 左, 上]，于是：
	#     上邻不属我 ⇒ 取「上→右」那条边；下邻 ⇒ 「下→左」；左邻 ⇒ 「左→上」；右邻 ⇒ 「右→下」
	var dirs := [
		{"d": Vector2i(0, -1), "a": 3, "b": 0},
		{"d": Vector2i(0, 1), "a": 1, "b": 2},
		{"d": Vector2i(-1, 0), "a": 2, "b": 3},
		{"d": Vector2i(1, 0), "a": 0, "b": 1},
	]
	var seen := {}
	for z in zones:
		var zid := int(z["id"])
		var owner := String(z.get("owner", ""))
		var cells: Array = z.get("tiles", [])
		var segs: PackedVector2Array
		var key_group := owner
		for t in cells:
			var tile: Vector2i = t
			var key: int = tile.y * int(world.zones.cols) + tile.x
			if seen.has(key):
				continue
			seen[key] = true
			var q := Palette2DRes.tile_poly(tile.x, tile.y, cfg)
			for e in dirs:
				var off: Vector2i = e["d"]
				var nb = world.zones.zone_at(tile.x + off.x, tile.y + off.y)
				if nb != null and int(nb["id"]) == zid:
					continue
				# ⚠️ 显式写类型：字典取值在静态分析里是 Variant，
				#    写 `var a := q[int(e["a"])]` 会 **Parse Error**（整个文件编译失败）。
				var a: Vector2 = q[int(e["a"])]
				var b: Vector2 = q[int(e["b"])]
				if owner == "":
					neutral.append(a)
					neutral.append(b)
				else:
					if not owned.has(key_group):
						owned[key_group] = PackedVector2Array()
					segs = owned[key_group]
					segs.append(a)
					segs.append(b)
					owned[key_group] = segs
	return {"neutral": neutral, "owned": owned}


## 有主区划的描边色：该阵营的主色；拿不到阵营色时退回 config 的 zone_stroke_owned。
func _stroke_color_owned(owner: String) -> Color:
	if owner == "" or cfg == null:
		return _c_stroke_owned
	return cfg.faction_color(owner, "main")


## 进度条在区块外接框里的矩形：从**底边**往上 h 像素（我方）
func _bar_rect_from_bottom(r: Rect2, h: float) -> Rect2:
	return Rect2(Vector2(r.position.x, r.position.y + r.size.y - h), Vector2(r.size.x, h))


## 进度条的填充色：该阵营的 main 色 + `colors.zone_progress` 的透明度
func _bar_color(faction: String) -> Color:
	if faction == "":
		return _c_progress
	var fc := cfg.faction_color(faction, "main")
	return Color(fc.r, fc.g, fc.b, _c_progress.a)


## 进度条「生长那一边」的亮线：深色地图上纯半透明色块不太容易注意到
func _bar_edge_color(faction: String) -> Color:
	var c := _bar_color(faction)
	return Color(c.r, c.g, c.b, minf(1.0, c.a + 0.35))
