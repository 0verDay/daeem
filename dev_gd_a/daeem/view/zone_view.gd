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

var _c_line: Color
var _c_neutral: Color
var _c_progress: Color
var _font: Font
var _font_size: int = 12

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
	_c_line = cfg.color("zone_line")
	_c_neutral = cfg.color("zone_neutral")
	_c_progress = cfg.color("zone_progress")
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
		if cells.is_empty():
			ci.draw_rect(r, _c_line, false, 1.0)
		else:
			_draw_zone_outline(ci, cells, cell)


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


## 沿地块边界画区块轮廓：只在「邻格不属于同一区块（或不存在）」的那条边上画线。
## 与地图编辑器里看到的那圈边界是同一套规则。
func _draw_zone_outline(ci: Node2D, cells: Array, cell: float) -> void:
	var dirs := [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]
	for t in cells:
		var tile: Vector2i = t
		var zone = world.zones.zone_at(tile.x, tile.y)
		if zone == null:
			continue
		var zid := int(zone["id"])
		var x0 := float(tile.x) * cell
		var y0 := float(tile.y) * cell
		var x1 := x0 + cell
		var y1 := y0 + cell
		for d in dirs:
			var nb = world.zones.zone_at(tile.x + d.x, tile.y + d.y)
			if nb != null and int(nb["id"]) == zid:
				continue
			if d.y == -1:
				ci.draw_line(Vector2(x0, y0), Vector2(x1, y0), _c_line, 1.0)
			elif d.y == 1:
				ci.draw_line(Vector2(x0, y1), Vector2(x1, y1), _c_line, 1.0)
			elif d.x == -1:
				ci.draw_line(Vector2(x0, y0), Vector2(x0, y1), _c_line, 1.0)
			else:
				ci.draw_line(Vector2(x1, y0), Vector2(x1, y1), _c_line, 1.0)


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
