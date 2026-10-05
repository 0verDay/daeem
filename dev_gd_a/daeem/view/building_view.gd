## building_view.gd —— 建筑渲染（菱形投影：等距 / 斜俯视 45°）
##
## ★ 只读逻辑状态 + 只画。每个逻辑建筑持有一个绘制节点；
##   ⚠️ 只在集合变化时增删，不在 _process 里重建（docs/pitfalls.md 2.3）。
##
## ★★ 菱形档的几何口径（改之前先读）：
##   · 建筑本体画成**菱形**（`palette.building_local_poly()`），不再是 `Rect2`；
##   · 节点原点放在**建筑自己那一格的格心**（`palette.to_px(b.center())`），
##     于是 `_draw()` 里的多边形是「相对格心的局部坐标」——这一步让
##     「建筑在哪」与「画成什么形状」彻底解耦（老版本的 `local_rect` 那套居中偏移
##     就是为此存在的，现在由 `centered_poly()` 一处负责）。
##   · **血条 / 建造读条仍然画成水平矩形**（它们是 UI 读数，不是地面上的东西），
##     走 `palette.comp_scale()` 的纵向补偿，不被镜头俯角压扁。
##
## ★ 强度提示：这一版**不做高度**（没有立面 / 厚度），所以建筑是「地上的一个菱形块」。
##   要立起来需要给每个类型加一个「视觉高度」+ 顶面 / 侧面两层绘制 —— 见 dev_plan_9。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const Palette2DRes = preload("res://view/palette2d.gd")

class BuildingBox:
	extends Node2D
	var building = null
	var cfg = null
	var selected: bool = false

	func setup(p_building, p_cfg) -> void:
		building = p_building
		cfg = p_cfg

	func _draw() -> void:
		if building == null or not building.alive:
			return
		# 节点原点 = 本建筑那一格的**格心**，所以这里拿的是相对格心的局部菱形。
		var poly := Palette2DRes.building_local_poly(building, cfg)
		if poly.size() < 3:
			return
		var base_color: Color = cfg.faction_color(building.owner, "main")
		var mid := Vector2.ZERO          # 局部坐标里格心就是原点

		match building.type:
			"wall":
				var wall: Color = cfg.color("wall")
				var wall_dark: Color = cfg.color("wall_dark")
				draw_polygon(poly, PackedColorArray([wall]))
				# 砖缝：沿「上→下」方向两道弦就够了，原型不追求质感。
				# ⚠️ 菱形档下不能再画水平线（那会穿过菱形外面），要沿格方向画弦。
				var ex := (poly[0] - mid) * 0.34      # 右方向的 0.34
				var ey := (poly[1] - mid) * 0.34      # 下方向的 0.34
				for k in [0.34, 0.68]:
					# ⚠️ 显式写类型：`for k in [0.34, 0.68]` 里的 k 是 Variant，
					#    于是 `mid + ex * k - ey` 推不出类型 ⇒ **Parse Error**（整个文件编译失败）。
					#    这是本轮**第二次**踩同一个坑（第一次在 input_controller），
					#    判据：任何来自数组 / 字典 / 动态容器的值参与运算时都要显式标注。
					var fk: float = k
					var a: Vector2 = mid + ex * fk - ey
					var b: Vector2 = mid - ex * fk + ey
					draw_line(a - (ex * fk * 2.0), b + (ex * fk * 2.0), wall_dark, 2.0)
				var closed := poly.duplicate()
				closed.append(poly[0])
				draw_polyline(closed, wall_dark, 3.0)
			"tower":
				draw_polygon(poly, PackedColorArray([cfg.color("tower")]))
				var closed_t := poly.duplicate()
				closed_t.append(poly[0])
				draw_polyline(closed_t, Color(0, 0, 0, 0.35), 2.5)
				# 塔顶：一个内缩的菱形，和城墙区分开
				var top := Palette2DRes.centered_poly(building.center(),
					building.body_scale(cfg) * 0.28, building.body_scale(cfg) * 0.28, cfg)
				var top_local := _to_local(top, mid)
				draw_polygon(top_local, PackedColorArray([base_color.lerp(Color.BLACK, 0.25)]))
			"zone_center":
				# ★ 区划中心：中立障碍。画成「品红菱形 + 中心点」——
				#   菱形档下它与地块同形状，所以再加一圈亮描边把它与地面区分开。
				var zc: Color = cfg.color("zone_center")
				draw_polygon(poly, PackedColorArray([Color(zc.r, zc.g, zc.b, 0.55)]))
				var closed_z := poly.duplicate()
				closed_z.append(poly[0])
				draw_polyline(closed_z, zc, 3.0)
				draw_circle(mid, maxf(2.0, (poly[0] - mid).length() * 0.22), zc)
			_:
				# 大本营
				draw_polygon(poly, PackedColorArray([cfg.color("hq")]))
				var closed_h := poly.duplicate()
				closed_h.append(poly[0])
				draw_polyline(closed_h, cfg.color("hq_light"), 3.0)
				var inner := Palette2DRes.centered_poly(building.center(),
					building.body_scale(cfg) * 0.32, building.body_scale(cfg) * 0.32, cfg)
				var inner_local := _to_local(inner, mid)
				var closed_i := inner_local.duplicate()
				closed_i.append(inner_local[0])
				draw_polyline(closed_i, cfg.color("hq_light"), 2.0)

		# 归属描边（谁的建筑一眼看出来；大本营 / 区划中心用自己的配色，就不再套一层）
		if building.type != "base" and building.type != "zone_center":
			var closed_o := poly.duplicate()
			closed_o.append(poly[0])
			draw_polyline(closed_o, Color(base_color.r, base_color.g, base_color.b, 0.9), 2.0)

		# 受击闪光：整格叠一层红
		if building.flash > 0.0:
			draw_polygon(poly, PackedColorArray([
				Color(1.0, 0.25, 0.2, 0.45 * clampf(building.flash, 0.0, 1.0))]))

		# 选中：金色外框（沿菱形放大一圈）
		if selected:
			var grown := PackedVector2Array()
			for p in poly:
				grown.append(mid + (p - mid) * 1.12)
			grown.append(grown[0])
			draw_polyline(grown, Color(1.0, 0.92, 0.55, 0.95), 3.0)

		# 血条 / 建造读条：★ 屏幕 1:1（走反向补偿），位置取本体的**屏幕外接框**
		var box := _local_aabb(poly)
		if building.hp < building.hp_max - 1e-6:
			var bar_h: float = 5.0
			var bar := Rect2(Vector2(box.position.x, box.end.y - bar_h - 2.0),
				Vector2(box.size.x, bar_h))
			draw_set_transform(bar.position, 0.0, Vector2(1.0, Palette2DRes.comp_scale(cfg)))
			draw_rect(Rect2(Vector2.ZERO, bar.size), Color(0, 0, 0, 0.6), true)
			draw_rect(Rect2(Vector2.ZERO, Vector2(bar.size.x * building.hp_ratio(), bar.size.y)),
				cfg.faction_color(building.owner, "bar"), true)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

		if building.is_under_construction():
			var cbar_h: float = 4.0
			var cbar := Rect2(Vector2(box.position.x, box.end.y + 3.0),
				Vector2(box.size.x, cbar_h))
			draw_set_transform(cbar.position, 0.0, Vector2(1.0, Palette2DRes.comp_scale(cfg)))
			draw_rect(Rect2(Vector2.ZERO, cbar.size), Color(0, 0, 0, 0.6), true)
			draw_rect(Rect2(Vector2.ZERO,
					Vector2(cbar.size.x * building.build_progress(), cbar.size.y)),
				Color(0.85, 0.78, 0.35, 0.95), true)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	## 把世界坐标的多边形换成「相对某个原点」的局部多边形
	static func _to_local(poly: PackedVector2Array, origin: Vector2) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in poly:
			out.append(p - origin)
		return out

	## 多边形在局部坐标里的轴对齐外接框（血条 / 读条的位置用它）
	static func _local_aabb(poly: PackedVector2Array) -> Rect2:
		if poly.is_empty():
			return Rect2()
		var mn := poly[0]
		var mx := poly[0]
		for p in poly:
			mn = mn.min(p)
			mx = mx.max(p)
		return Rect2(mn, mx - mn)


var cfg: ConfigRes = null
var world = null

var _boxes: Dictionary = {}       # building -> Node2D
## 选中的那批建筑（building -> true）。★ 用集合而不是单个引用：框选建筑时可能选中一整批，
## 它们**都**该点亮金色外框（谁被选中一眼看出来）。
var _selected_set: Dictionary = {}


func setup(p_cfg: ConfigRes, p_world) -> void:
	cfg = p_cfg
	world = p_world
	z_index = 0


func sync() -> void:
	if world == null:
		return
	var seen: Dictionary = {}
	for b in world.building_list:
		if not b.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方建筑**连节点都不留**（"一个图元都不发"的同一条口径）。
		#
		# ★ 判据在 logic/fog.gd 的 `building_visible()`：己方 / 无主（区划中心）永远可见；
		#   敌方建筑「进过视野一次就永久可见」（记忆表在 fog.gd 里维护）。
		# ⚠️ 用 `continue`（而不是把节点 hide）会走到下面的「回收」逻辑：节点被 queue_free，
		#    等它再被看见时重建。建筑本来就少（这张图上不到 30 栋），重建的代价可忽略。
		if not _visible_to_me(b):
			continue
		seen[b] = true
		var box: BuildingBox = _boxes.get(b, null)
		if box == null:
			box = BuildingBox.new()
			add_child(box)
			box.setup(b, cfg)
			# ★ 节点原点 = 本建筑那一格的**格心**（不是格左上角）：
			#   局部多边形因此天然以格心为原点，与 `centered_poly()` 口径一致。
			box.position = Palette2DRes.to_px(b.center(), cfg)
			_boxes[b] = box
		box.selected = _selected_set.has(b)
		box.queue_redraw()

	for b in _boxes.keys():
		if not seen.has(b):
			var box: BuildingBox = _boxes[b]
			box.queue_free()
			_boxes.erase(b)


## 这栋建筑现在该不该画给玩家看（战争迷雾的唯一判据入口）。
func _visible_to_me(b) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.building_visible(world.my_faction, b)


## 当前选中的建筑（框选可以一次选中一批；空数组 = 没选中任何建筑）。
func set_selected_buildings(list: Array) -> void:
	_selected_set = {}
	for b in list:
		if b != null:
			_selected_set[b] = true
