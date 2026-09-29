## building_view.gd —— 建筑渲染（对应 HTML 版 render.js 的建筑 / 血条 / 受击闪光）
##
## ★ 只读逻辑状态 + 只画。每个逻辑建筑持有一个绘制节点；
##   ⚠️ 只在集合变化时增删，不在 _process 里重建（docs/pitfalls.md 2.3）。
##
## 观感对齐 HTML 版：
##   - 城墙「填满整个地块」，其余建筑内缩一点留出地面
##   - 挨打整格闪红（flash 1 → 0）
##   - 血量不满时在格子底部画血条（满血不画，避免刷屏）
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

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
		# 节点的原点是「自己那一格的左上角」，所以这里要拿**局部**矩形。
		# ⚠️ 不能自己写 `Rect2(Vector2.ZERO, rect.size)` —— 那会把居中偏移丢掉，
		#    大本营 / 箭塔就会贴到格子左上角（手玩一眼能看出来，测试也钉住了）。
		var local := PaletteRes.building_local_rect(building, cfg)
		var base_color: Color = cfg.faction_color(building.owner, "main")

		match building.type:
			"wall":
				var wall: Color = cfg.color("wall")
				var wall_dark: Color = cfg.color("wall_dark")
				draw_rect(local, wall, true)
				# 砖缝：两道横线就够了，原型不追求质感
				for k in [0.33, 0.66]:
					var y: float = local.size.y * k
					draw_line(Vector2(0.0, y), Vector2(local.size.x, y), wall_dark, 2.0)
				draw_rect(local, wall_dark, false, 3.0)
			"tower":
				draw_rect(local, cfg.color("tower"), true)
				draw_rect(local, Color(0, 0, 0, 0.35), false, 2.5)
				# 塔顶：一个内缩的方块，和城墙区分开
				var inset: float = local.size.x * 0.22
				draw_rect(Rect2(Vector2(inset, inset), local.size - Vector2(inset * 2.0, inset * 2.0)),
					base_color.lerp(Color.BLACK, 0.25), true)
			"zone_center":
				# ★ 区划中心：中立障碍。画成「品红菱形 + 中心点」，与城墙 / 箭塔 / 大本营
				#   都不一样（地图编辑器里也是同一个菱形，两边一眼对得上）。
				var zc: Color = cfg.color("zone_center")
				var mid: Vector2 = local.position + local.size * 0.5
				var zr: float = local.size.x * 0.5
				var diamond := PackedVector2Array([
					mid + Vector2(0.0, -zr), mid + Vector2(zr, 0.0),
					mid + Vector2(0.0, zr), mid + Vector2(-zr, 0.0),
				])
				draw_colored_polygon(diamond, Color(zc.r, zc.g, zc.b, 0.35))
				var outline := diamond.duplicate()
				outline.append(diamond[0])
				draw_polyline(outline, zc, 3.0)
				draw_circle(mid, maxf(2.0, zr * 0.22), zc)
			_:
				# 大本营
				draw_rect(local, cfg.color("hq"), true)
				draw_rect(local, cfg.color("hq_light"), false, 3.0)
				var hi: float = local.size.x * 0.18
				draw_rect(Rect2(Vector2(hi, hi), local.size - Vector2(hi * 2.0, hi * 2.0)),
					cfg.color("hq_light"), false, 2.0)

		# 归属描边（谁的建筑一眼看出来；大本营用自己的配色，就不再套一层）
		# ⚠️ 区划中心是**无主**的（owner = ""），套阵营色只会画出一圈无意义的颜色，
		#    所以它也不套这层描边 —— 它的菱形本身就是标识。
		if building.type != "base" and building.type != "zone_center":
			draw_rect(local, Color(base_color.r, base_color.g, base_color.b, 0.9), false, 2.0)

		# 受击闪光：整格叠一层红
		if building.flash > 0.0:
			draw_rect(local, Color(1.0, 0.25, 0.2, 0.45 * clampf(building.flash, 0.0, 1.0)), true)

		# 选中：金色外框
		if selected:
			draw_rect(Rect2(local.position - Vector2(2, 2), local.size + Vector2(4, 4)),
				Color(1.0, 0.92, 0.55, 0.95), false, 3.0)

		# 血条（不满血才画）
		if building.hp < building.hp_max - 1e-6:
			var bar_h: float = 5.0
			var bar := Rect2(Vector2(local.position.x, local.position.y + local.size.y - bar_h - 2.0),
				Vector2(local.size.x, bar_h))
			draw_rect(bar, Color(0, 0, 0, 0.6), true)
			draw_rect(Rect2(bar.position, Vector2(bar.size.x * building.hp_ratio(), bar.size.y)),
				cfg.faction_color(building.owner, "bar"), true)

		# ★ 建造读条（config 的 `building.<type>.build_sec` > 0 时才有）：
		#   画在**本体下沿**，与血条同一套画法但用黄绿色 ——
		#   「这栋楼还在造」是玩家要一眼知道的事（造完之前它不开火）。
		if building.is_under_construction():
			var cbar_h: float = 4.0
			var cbar := Rect2(
				Vector2(local.position.x, local.position.y + local.size.y + 3.0),
				Vector2(local.size.x, cbar_h))
			draw_rect(cbar, Color(0, 0, 0, 0.6), true)
			draw_rect(Rect2(cbar.position,
					Vector2(cbar.size.x * building.build_progress(), cbar.size.y)),
				Color(0.85, 0.78, 0.35, 0.95), true)

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
		#   敌方建筑「进过视野一次就永久可见」（记忆表在 fog.gd 里维护），
		#   被摧毁时那一份记忆才清掉 —— 所以这里不需要任何「已发现」状态。
		# ⚠️ 用 `continue`（而不是把节点 hide）会走到下面的「回收」逻辑：节点被 queue_free，
		#    等它再被看见时重建。建筑本来就少（这张图上不到 30 栋），重建的代价可忽略，
		#    换来的是「地图上有多少节点 = 玩家看得见多少建筑」这条干净的对应关系。
		if not _visible_to_me(b):
			continue
		seen[b] = true
		var box: BuildingBox = _boxes.get(b, null)
		if box == null:
			box = BuildingBox.new()
			add_child(box)
			box.setup(b, cfg)
			# 建筑节点放在「它自己那一格的像素原点」（尺寸由 _draw 内部算）
			box.position = PaletteRes.tile_rect(b.tx, b.ty, cfg).position
			_boxes[b] = box
		box.selected = _selected_set.has(b)
		box.queue_redraw()

	for b in _boxes.keys():
		if not seen.has(b):
			var box: BuildingBox = _boxes[b]
			box.queue_free()
			_boxes.erase(b)


## 这栋建筑现在该不该画给玩家看（战争迷雾的唯一判据入口）。
##
## ★ 与 unit_view 的同名函数同一条口径：判据在 logic/fog.gd，视图只提供「我这边的阵营」。
## ★ 没建迷雾（无头测试）或总开关关着 → 一律画（宁可多画，不要静默少画）。
func _visible_to_me(b) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.building_visible(world.my_faction, b)


## 当前选中的建筑（框选可以一次选中一批；空数组 = 没选中任何建筑）。
## ★ 只读这份本地状态：选中是纯本地的，不进逻辑、不进命令流。
func set_selected_buildings(list: Array) -> void:
	_selected_set = {}
	for b in list:
		if b != null:
			_selected_set[b] = true
