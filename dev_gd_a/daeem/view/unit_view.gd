## unit_view.gd —— 单位的渲染（对应 HTML 版 render.js 的单位与射程圈）
##
## ★ 只读逻辑状态 + 只画，不改任何东西（docs/architecture.md 的第三条铁律）。
##
## 数量少且需要交互（人看清谁是谁），所以给每个逻辑单位持有一个内部轻量节点。
## ⚠️ 绝不在 _process 里 queue_free() + new() 重建（docs/pitfalls.md 2.3）：
##    只在「单位集合变了」时增删，其余帧只改位置 / 颜色 / 可见性。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

## 每个逻辑单位对应的绘制节点
class UnitDot:
	extends Node2D
	var unit = null
	var cfg = null
	var body_color: Color = Color.WHITE
	var ring_color: Color = Color.WHITE
	var selected: bool = false

	func setup(p_unit, p_cfg) -> void:
		unit = p_unit
		cfg = p_cfg
		z_index = 10
		body_color = cfg.faction_color(unit.faction, "main")
		ring_color = cfg.faction_color(unit.faction, "sel")

	func _draw() -> void:
		if unit == null or not unit.alive:
			return
		var r: float = PaletteRes.unit_radius_px(cfg, unit.kind)
		# 选中圈：画在单位外面一圈，和 HTML 版的观感一致
		if selected:
			draw_circle(Vector2.ZERO, r + 4.0, Color(ring_color.r, ring_color.g, ring_color.b, 0.35))
		# 单位本体（占位美术：一个圆）
		draw_circle(Vector2.ZERO, r, body_color)
		draw_arc(Vector2.ZERO, r, 0.0, TAU, 20, Color(0, 0, 0, 0.45), 1.5)
		# 朝向：一条短短的线，指向 facing —— 八方向之后 facing 是完整向量，
		# 所以这条线会跟着斜着走时的实际方向转（原来只画水平线）
		var dir: Vector2 = unit.facing
		if dir.length() > 1e-6:
			draw_line(Vector2.ZERO, dir.normalized() * (r * 1.5), Color(0, 0, 0, 0.5), 2.0)
		# 交战标记：头顶小三角
		if unit.target != null or unit.target_building != null:
			var d: float = r + 5.0
			draw_colored_polygon(PackedVector2Array([
				Vector2(-3.5, -d), Vector2(3.5, -d), Vector2(0.0, -d - 5.0),
			]), Color(1.0, 0.45, 0.35, 0.95))
		# 血条：不满血才画（满血不画，避免刷屏）
		if unit.hp < unit.hp_max - 1e-6:
			var w: float = r * 2.4
			var y: float = r + 4.0
			draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w, 3.0)), Color(0, 0, 0, 0.55), true)
			draw_rect(Rect2(Vector2(-w * 0.5, y), Vector2(w * unit.hp_ratio(), 3.0)),
				cfg.faction_color(unit.faction, "bar"), true)

var cfg: ConfigRes = null
var world = null

var _dots: Dictionary = {}          # unit.id -> UnitDot
var _selection: Dictionary = {}     # unit.id -> true（纯本地，不进命令流）


func setup(p_cfg: ConfigRes, p_world) -> void:
	cfg = p_cfg
	world = p_world
	z_index = 10


## 每帧同步：只在这里增删节点，其余帧只更新
func sync(dt: float) -> void:
	if world == null:
		return
	var seen: Dictionary = {}
	for u in world.units:
		seen[u.id] = true
		var dot: UnitDot = _dots.get(u.id, null)
		if dot == null:
			dot = UnitDot.new()
			add_child(dot)
			dot.setup(u, cfg)
			_dots[u.id] = dot
		dot.visible = u.alive
		if not u.alive:
			continue
		dot.position = PaletteRes.to_px(u.pos, cfg)
		var sel: bool = _selection.has(u.id)
		if dot.selected != sel:
			dot.selected = sel
			dot.queue_redraw()
		# 阵营可能变（调试 / 联机时换阵营），变了要换色
		var want := cfg.faction_color(u.faction, "main")
		if not dot.body_color.is_equal_approx(want):
			dot.setup(u, cfg)
			dot.queue_redraw()
		# 血条 / 交战标记每帧都可能变，直接重画（单位数量很少，代价可忽略）
		dot.queue_redraw()

	# 逻辑上已经没有的单位 → 摘掉节点（**只在这里**做增删）
	for id in _dots.keys():
		if not seen.has(id):
			var dot: UnitDot = _dots[id]
			dot.queue_free()
			_dots.erase(id)


## 设置选中集合（view 内部状态，不发命令）
func set_selection(ids: Array) -> void:
	var next: Dictionary = {}
	for id in ids:
		next[String(id)] = true
	_selection = next
	for id in _dots.keys():
		var dot: UnitDot = _dots[id]
		var sel: bool = _selection.has(id)
		if dot.selected != sel:
			dot.selected = sel
			dot.queue_redraw()
