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
			_:
				# 大本营
				draw_rect(local, cfg.color("hq"), true)
				draw_rect(local, cfg.color("hq_light"), false, 3.0)
				var hi: float = local.size.x * 0.18
				draw_rect(Rect2(Vector2(hi, hi), local.size - Vector2(hi * 2.0, hi * 2.0)),
					cfg.color("hq_light"), false, 2.0)

		# 归属描边（谁的建筑一眼看出来；大本营用自己的配色，就不再套一层）
		if building.type != "base":
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

var cfg: ConfigRes = null
var world = null

var _boxes: Dictionary = {}       # building -> Node2D
var _selected = null


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
		seen[b] = true
		var box: BuildingBox = _boxes.get(b, null)
		if box == null:
			box = BuildingBox.new()
			add_child(box)
			box.setup(b, cfg)
			# 建筑节点放在「它自己那一格的像素原点」（尺寸由 _draw 内部算）
			box.position = PaletteRes.tile_rect(b.tx, b.ty, cfg).position
			_boxes[b] = box
		box.selected = (b == _selected)
		box.queue_redraw()

	for b in _boxes.keys():
		if not seen.has(b):
			var box: BuildingBox = _boxes[b]
			box.queue_free()
			_boxes.erase(b)


func set_selected(b) -> void:
	_selected = b
