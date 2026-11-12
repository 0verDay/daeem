## death_fx_view_3d.gd —— 单位阵亡时贴地扩散的**烟尘**（M3，纯表现）
##
## 设计口径（与 view/charge_fx_view_3d.gd 同一条）：
##   · **对象池**：固定 12 个槽位，绝不在每帧 new / queue_free；
##   · 每个槽位 = MeshInstance3D + PlaneMesh(FACE_Y) + 独立 StandardMaterial3D；
##     贴图复用 `unit_sprite_3d.soft_circle_texture()`（程序化软圆）；
##   · `spawn()` 由逻辑事件 `kill` 触发，`sync(dt)` 由 game_scene3d 每帧推进；
##     暂停时传 dt = 0 ⇒ 烟尘跟着冻结；
##   · 颜色 = 阵亡单位阵营色与灰尘灰的混合（远看是「那一片的兵没了」，
##     近看能分出是哪一方）；时长 / 尺寸 / 透明度来自 `render.death_fx_*`。
##
## ★ 只读 `kill` 事件里的单位位置与阵营，不改任何逻辑状态。
extends Node3D

const SpriteRes = preload("res://view/unit_sprite_3d.gd")

const SLOT_COUNT := 12

var cfg = null
var palette = null

## 每个槽位：{node, mat, t, size, color, active}
var _slots: Array = []
var _next: int = 0

## setup 缓存的 render.death_fx_*
var _sec: float = 0.32
var _size: float = 1.1
var _alpha: float = 0.5
var _from_scale: float = 0.35

## 诊断（测试读它）：本帧还在扩散的烟尘数 / 累计生成过多少次
var active_count: int = 0
var spawn_count: int = 0


func setup(p_cfg, p_palette) -> void:
	cfg = p_cfg
	palette = p_palette
	_sec = maxf(0.05, cfg.num("render.death_fx_sec", 0.32))
	_size = maxf(0.1, cfg.num("render.death_fx_size", 1.1))
	_alpha = clampf(cfg.num("render.death_fx_alpha", 0.5), 0.0, 1.0)
	_from_scale = clampf(cfg.num("render.death_fx_from_scale", 0.35), 0.01, 1.0)
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
		mat.albedo_texture = SpriteRes.soft_circle_texture()
		mat.albedo_color = Color(1.0, 1.0, 1.0, 0.0)
		var node := MeshInstance3D.new()
		node.name = "DeathDust_%d" % i
		node.mesh = quad
		node.material_override = mat
		node.visible = false
		add_child(node)
		_slots.append({
			"node": node,
			"mat": mat,
			"t": 0.0,
			"size": 0.0,
			"color": Color.WHITE,
			"active": false,
		})


## 在 `logic_pos`（格坐标）生成一团烟尘。
## @param faction_color 阵亡单位的阵营主色（会与灰尘灰混合，避免纯阵营色太艳）
func spawn(logic_pos: Vector2, faction_color: Color = Color.WHITE) -> void:
	if palette == null or _slots.is_empty():
		return
	var slot: Dictionary = _free_slot()
	var w: Vector3 = palette.to_world(logic_pos)
	w.y = 1.15
	(slot["node"] as MeshInstance3D).position = w
	slot["t"] = 0.0
	slot["size"] = _size
	# 灰尘灰 0.65 + 阵营色 0.35：远看是一团灰，近看能认出是哪一方。
	slot["color"] = Color(0.55, 0.53, 0.50).lerp(faction_color, 0.35)
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
	var final_scale: float = float(slot["size"])
	var s: float = lerpf(final_scale * _from_scale, final_scale, p)
	var node: MeshInstance3D = slot["node"]
	node.scale = Vector3(s, 1.0, s)
	var mat: StandardMaterial3D = slot["mat"]
	var col: Color = slot["color"]
	# 先亮起、再淡出：`p * (1-p)` 在 0 和 1 两端都为 0，中间最实。
	var a: float = _alpha * clampf(p * 4.0, 0.0, 1.0) * (1.0 - p) * (1.0 - p)
	mat.albedo_color = Color(col.r, col.g, col.b, a)


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
