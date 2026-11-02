## charge_fx_view_3d.gd —— 冲锋命中时贴地扩散的「冲击波圈」（纯表现）。
##
## 设计口径（对标 view/projectile_view_3d.gd）：
##   · **对象池**：固定 8 个槽位，绝不在每帧 new / queue_free；
##   · 每个槽位 = MeshInstance3D + PlaneMesh(FACE_Y) + 独立 StandardMaterial3D；
##     贴图复用 `unit_sprite_3d.selection_ring_texture()`（程序化空心圆）；
##   · `spawn()` 由逻辑事件 `unit_charge` 触发，`sync(dt)` 由 game_scene3d 每帧推进；
##     暂停时传 dt = 0 ⇒ 冲击波跟着冻结（与插旗 / 单位同步同一条口径）；
##   · 颜色 = 冲锋单位的阵营色；时长 / 透明度 / 最小半径全部来自 config 的
##     `render.charge_shock_*`（setup 缓存，不在每帧 cfg.num）。
extends Node3D

const SpriteRes = preload("res://view/unit_sprite_3d.gd")

const SLOT_COUNT := 8

var cfg = null
var palette = null

## 每个槽位：{node, mat, t, radius, color, active}
var _slots: Array = []
var _next: int = 0

## setup 缓存的 render.charge_shock_*
var _sec: float = 0.28
var _alpha: float = 0.8
var _min_radius: float = 0.5
var _from_scale: float = 0.4

## 诊断（测试读它）：本帧还在扩散的圈数
var active_count: int = 0
## 诊断：累计生成过多少次（测试读它）
var spawn_count: int = 0


func setup(p_cfg, p_palette) -> void:
	cfg = p_cfg
	palette = p_palette
	_sec = maxf(0.05, cfg.num("render.charge_shock_sec", 0.28))
	_alpha = clampf(cfg.num("render.charge_shock_alpha", 0.8), 0.0, 1.0)
	_min_radius = maxf(0.05, cfg.num("render.charge_shock_min_radius", 0.5))
	_from_scale = clampf(cfg.num("render.charge_shock_from_scale", 0.4), 0.01, 1.0)
	_build_slots()


func _build_slots() -> void:
	for s in _slots:
		if is_instance_valid(s.get("node", null)):
			(s["node"] as MeshInstance3D).queue_free()
	_slots.clear()
	var quad := PlaneMesh.new()
	quad.size = Vector2(1.0, 1.0)
	quad.orientation = PlaneMesh.FACE_Y
	for i in SLOT_COUNT:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.albedo_texture = SpriteRes.selection_ring_texture()
		mat.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
		var node := MeshInstance3D.new()
		node.name = "ChargeShock_%d" % i
		node.mesh = quad
		node.material_override = mat
		node.visible = false
		add_child(node)
		_slots.append({
			"node": node,
			"mat": mat,
			"t": 0.0,
			"radius": 0.0,
			"color": Color.WHITE,
			"active": false,
		})


## 在 `logic_pos`（格坐标）生成一圈冲击波。
## @param radius 逻辑范围（格；0 = 单体冲锋，用 config 的最小视觉半径）。
func spawn(logic_pos: Vector2, radius: float, color: Color) -> void:
	if palette == null or _slots.is_empty():
		return
	var slot: Dictionary = _free_slot()
	var w: Vector3 = palette.to_world(logic_pos)
	w.y = 1.2
	(slot["node"] as MeshInstance3D).position = w
	slot["t"] = 0.0
	slot["radius"] = maxf(radius, _min_radius)
	slot["color"] = color
	slot["active"] = true
	(slot["node"] as MeshInstance3D).visible = true
	_apply_slot(slot, 0.0)
	spawn_count += 1


func sync(dt: float) -> void:
	active_count = 0
	for s in _slots:
		var slot: Dictionary = s
		if not bool(slot["active"]):
			continue
		slot["t"] = float(slot["t"]) + dt
		var p: float = float(slot["t"]) / _sec
		if p >= 1.0:
			slot["active"] = false
			(slot["node"] as MeshInstance3D).visible = false
			continue
		_apply_slot(slot, p)
		active_count += 1


func _apply_slot(slot: Dictionary, p: float) -> void:
	var final_scale: float = 2.0 * float(slot["radius"])
	var s: float = lerpf(final_scale * _from_scale, final_scale, p)
	var node: MeshInstance3D = slot["node"]
	node.scale = Vector3(s, 1.0, s)
	var mat: StandardMaterial3D = slot["mat"]
	var col: Color = slot["color"]
	mat.albedo_color = Color(col.r, col.g, col.b, _alpha * (1.0 - p) * (1.0 - p))


func _free_slot() -> Dictionary:
	for s in _slots:
		if not bool((s as Dictionary)["active"]):
			return s
	var slot: Dictionary = _slots[_next % _slots.size()]
	_next += 1
	return slot


func clear() -> void:
	active_count = 0
	for s in _slots:
		var slot: Dictionary = s
		slot["active"] = false
		(slot["node"] as MeshInstance3D).visible = false
