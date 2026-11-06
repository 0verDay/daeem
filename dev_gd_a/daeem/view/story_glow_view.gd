## story_glow_view.gd —— 演出「呼吸泛光」的 3D 表现层。
##
## ★★ 三部分：
##   1. **地面光环**（单位和建筑共用）：复用选中圈的环形贴图 + `selection_ring.gdshader`，
##      逐实例 alpha 走 `INSTANCE_CUSTOM.r`；颜色按目标分组（默认金色，可跟阵营色）。
##   2. **建筑外壳**：把建筑网格放大一圈、只画背面（`story_glow_shell.gdshader`），
##      与现有悬停 / 选中描边同一个思路，但用独立 MultiMesh 层，**不占用**
##      主材质的 `.b` / `.a` 通道。
##   3. 单位本体泛光：在 `unit_flash.gdshader` 里用空闲的 `.a` 通道做金色混合
##      （见 view/unit_view_3d.gd）。
##
## ★ 状态只读 `Unit.story_glow` / `Building.story_glow`；曲线由
##   `logic/story/story_glow.gd` 统一算（单位本体与光环必须同一条曲线）。
## ★ 迷雾：看不见的敌人不发光（用 `fog.unit_visible` / `fog.building_visible`，
##   与主视图同一套显示口径）。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const StoryGlowRes = preload("res://logic/story/story_glow.gd")
const RING_SHADER = preload("res://view/selection_ring.gdshader")
const SHELL_SHADER = preload("res://view/story_glow_shell.gdshader")

const RING_Y := 1.1
const RIPPLE_Y := 1.14
const RING_CAPACITY := 256
const SHELL_CAPACITY := 64

var cfg: ConfigRes = null
var world = null
var palette = null
var buildings_view = null

var _ring_quad: PlaneMesh = null
var _ring_layers: Dictionary = {}      # color hex -> {mm, node}
var _ripple_layers: Dictionary = {}    # color hex -> {mm, node}
var _shell_layers: Dictionary = {}     # "type|color" -> {mm, node, mesh}

var _unit_ring_size: float = 0.9
var _building_ring_size: float = 1.3
var _ring_alpha: float = 1.0
var _ripple_alpha: float = 0.9
var _ripple_from: float = 0.35
var _ripple_to: float = 2.1
var _shell_scale: float = 1.06
var _shell_alpha: float = 0.7

## 诊断（测试读）：本帧实际写了多少个光环 / 波纹 / 外壳实例。
var glow_ring_count: int = 0
var glow_ripple_count: int = 0
var glow_shell_count: int = 0


func setup(p_cfg: ConfigRes, p_world, p_palette, p_buildings_view = null) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	buildings_view = p_buildings_view
	_unit_ring_size = maxf(0.1, cfg.num("render.story_glow_unit_ring_size", 0.9))
	_building_ring_size = maxf(0.1, cfg.num("render.story_glow_building_ring_size", 1.3))
	_ring_alpha = clampf(cfg.num("render.story_glow_ring_alpha", 1.0), 0.0, 1.0)
	_ripple_alpha = clampf(cfg.num("render.story_glow_ripple_alpha", 0.9), 0.0, 1.0)
	_ripple_from = clampf(cfg.num("render.story_glow_ripple_scale_from", 0.35), 0.05, 1.0)
	_ripple_to = maxf(_ripple_from, cfg.num("render.story_glow_ripple_scale_to", 2.1))
	_shell_scale = maxf(1.0, cfg.num("render.story_glow_shell_scale", 1.06))
	_shell_alpha = clampf(cfg.num("render.story_glow_shell_alpha", 0.7), 0.0, 1.0)

	var cell: float = palette.cell_size()
	_ring_quad = PlaneMesh.new()
	_ring_quad.size = Vector2(cell, cell)
	_ring_quad.orientation = PlaneMesh.FACE_Y


func sync(_dt: float) -> void:
	glow_ring_count = 0
	glow_ripple_count = 0
	glow_shell_count = 0
	if world == null or palette == null or not bool(world.story_glow_active):
		# 本局从未出现过泛光：把所有层收掉即可，不扫描单位 / 建筑。
		_hide_all_layers(_ring_layers)
		_hide_all_layers(_ripple_layers)
		_hide_all_layers(_shell_layers)
		return
	var now := float(world.time)
	var rings: Dictionary = {}       # color -> Array[{pos, scale, alpha}]
	var ripples: Dictionary = {}     # color -> Array[{pos, scale, alpha}]
	var shells: Dictionary = {}      # "type|color" -> Array[{xform, alpha}]

	for u in world.units:
		if u == null or not u.alive:
			continue
		if not StoryGlowRes.is_active(u, now):
			continue
		if not _unit_visible(u):
			continue
		var a := StoryGlowRes.value(u, now)
		if a <= 0.001:
			continue
		var color := StoryGlowRes.color_hex(u, world)
		if not rings.has(color):
			rings[color] = []
		if not ripples.has(color):
			ripples[color] = []
		var pos: Vector3 = palette.to_world(u.pos)
		pos.y = RING_Y
		(rings[color] as Array).append({
			"pos": pos, "scale": _unit_ring_size, "alpha": a * _ring_alpha,
		})
		_add_ripple(ripples[color], u.story_glow, now, pos, _unit_ring_size, a)

	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if not StoryGlowRes.is_active(b, now):
			continue
		if not _building_visible(b):
			continue
		var a2 := StoryGlowRes.value(b, now)
		if a2 <= 0.001:
			continue
		var color2 := StoryGlowRes.color_hex(b, world)
		if not rings.has(color2):
			rings[color2] = []
		if not ripples.has(color2):
			ripples[color2] = []
		var bp: Vector3 = palette.to_world(b.center())
		bp.y = RING_Y
		(rings[color2] as Array).append({
			"pos": bp, "scale": _building_ring_size, "alpha": a2 * _ring_alpha,
		})
		_add_ripple(ripples[color2], b.story_glow, now, bp, _building_ring_size, a2)
		# 区划中心是旗面（会随占领进度上下移动），外壳会错位 → 只给它地面光环。
		if String(b.type) == "zone_center" or buildings_view == null:
			continue
		var mesh: Mesh = buildings_view.story_glow_mesh_for(String(b.type))
		if mesh == null:
			continue
		var key := "%s|%s" % [String(b.type), color2]
		if not shells.has(key):
			shells[key] = []
		(shells[key] as Array).append({
			"xform": buildings_view.story_glow_transform_of(b),
			"alpha": a2 * _shell_alpha,
		})

	_sync_rings(rings)
	_sync_ripples(ripples)
	_sync_shells(shells)


## 由内往外的一次性波纹：与右键指令的插旗 / 攻击圈同一条「先快后慢 + 淡出」曲线。
func _add_ripple(bucket: Array, glow: Dictionary, now: float, pos: Vector3, base: float, a: float) -> void:
	var period := maxf(0.05, float(glow.get("period", 1.6)))
	var start := float(glow.get("start", now))
	var p := fmod(maxf(0.0, now - start) / period, 1.0)
	var e := 1.0 - (1.0 - p) * (1.0 - p)
	var s := lerpf(_ripple_from, _ripple_to, e) * base
	var alpha := a * _ripple_alpha * (1.0 - p)
	if alpha <= 0.001:
		return
	var rp := pos
	rp.y = RIPPLE_Y
	bucket.append({"pos": rp, "scale": s, "alpha": alpha})


func _hide_all_layers(layers: Dictionary) -> void:
	for k in layers.keys():
		var rec: Dictionary = layers[k]
		(rec["mm"] as MultiMesh).visible_instance_count = 0
		(rec["node"] as MultiMeshInstance3D).visible = false


# ------------------------------------------------------------------
# 光环
# ------------------------------------------------------------------

func _sync_rings(buckets: Dictionary) -> void:
	for color in buckets.keys():
		var layer := _ring_layer(String(color))
		var list: Array = buckets[color]
		var mm: MultiMesh = layer["mm"]
		if mm.instance_count < list.size():
			mm.instance_count = maxi(list.size(), mm.instance_count * 2)
		for i in list.size():
			var it: Dictionary = list[i]
			var s := float(it["scale"])
			mm.set_instance_transform(i, Transform3D(
				Basis().scaled(Vector3(s, 1.0, s)), it["pos"]))
			mm.set_instance_custom_data(i, Color(float(it["alpha"]), 0.0, 0.0, 0.0))
		mm.visible_instance_count = list.size()
		(layer["node"] as MultiMeshInstance3D).visible = true
		glow_ring_count += list.size()
	for color2 in _ring_layers.keys():
		if buckets.has(color2):
			continue
		var rec: Dictionary = _ring_layers[color2]
		(rec["mm"] as MultiMesh).visible_instance_count = 0
		(rec["node"] as MultiMeshInstance3D).visible = false


func _ring_layer(color_hex: String) -> Dictionary:
	var hit: Variant = _ring_layers.get(color_hex, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = RING_SHADER
	mat.set_shader_parameter("albedo_tex", SpriteRes.selection_ring_texture())
	mat.set_shader_parameter("ring_color", ConfigRes.parse_color(color_hex))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _ring_quad
	mm.instance_count = RING_CAPACITY
	var node := MultiMeshInstance3D.new()
	node.name = "StoryGlowRings"
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	var rec := {"mm": mm, "node": node}
	_ring_layers[color_hex] = rec
	return rec


func _sync_ripples(buckets: Dictionary) -> void:
	for color in buckets.keys():
		var layer := _ripple_layer(String(color))
		var list: Array = buckets[color]
		var mm: MultiMesh = layer["mm"]
		if mm.instance_count < list.size():
			mm.instance_count = maxi(list.size(), mm.instance_count * 2)
		for i in list.size():
			var it: Dictionary = list[i]
			var s := float(it["scale"])
			mm.set_instance_transform(i, Transform3D(
				Basis().scaled(Vector3(s, 1.0, s)), it["pos"]))
			mm.set_instance_custom_data(i, Color(float(it["alpha"]), 0.0, 0.0, 0.0))
		mm.visible_instance_count = list.size()
		(layer["node"] as MultiMeshInstance3D).visible = true
		glow_ripple_count += list.size()
	for color2 in _ripple_layers.keys():
		if buckets.has(color2):
			continue
		var rec: Dictionary = _ripple_layers[color2]
		(rec["mm"] as MultiMesh).visible_instance_count = 0
		(rec["node"] as MultiMeshInstance3D).visible = false


func _ripple_layer(color_hex: String) -> Dictionary:
	var hit: Variant = _ripple_layers.get(color_hex, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = RING_SHADER
	mat.set_shader_parameter("albedo_tex", SpriteRes.selection_ring_texture())
	mat.set_shader_parameter("ring_color", ConfigRes.parse_color(color_hex))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _ring_quad
	mm.instance_count = RING_CAPACITY
	var node := MultiMeshInstance3D.new()
	node.name = "StoryGlowRipples"
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	var rec := {"mm": mm, "node": node}
	_ripple_layers[color_hex] = rec
	return rec


# ------------------------------------------------------------------
# 建筑外壳
# ------------------------------------------------------------------

func _sync_shells(buckets: Dictionary) -> void:
	for key in buckets.keys():
		var sep := String(key).find("|")
		var type := String(key).substr(0, sep)
		var color := String(key).substr(sep + 1)
		var layer := _shell_layer(type, color)
		if layer.is_empty():
			continue
		var list: Array = buckets[key]
		var mm: MultiMesh = layer["mm"]
		if mm.instance_count < list.size():
			mm.instance_count = maxi(list.size(), mm.instance_count * 2)
		for i in list.size():
			var it: Dictionary = list[i]
			mm.set_instance_transform(i, it["xform"])
			mm.set_instance_custom_data(i, Color(float(it["alpha"]), 0.0, 0.0, 0.0))
		mm.visible_instance_count = list.size()
		(layer["node"] as MultiMeshInstance3D).visible = true
		glow_shell_count += list.size()
	for k2 in _shell_layers.keys():
		if buckets.has(k2):
			continue
		var rec: Dictionary = _shell_layers[k2]
		(rec["mm"] as MultiMesh).visible_instance_count = 0
		(rec["node"] as MultiMeshInstance3D).visible = false


func _shell_layer(type: String, color_hex: String) -> Dictionary:
	var key := "%s|%s" % [type, color_hex]
	var hit: Variant = _shell_layers.get(key, null)
	if hit != null:
		return hit
	if buildings_view == null:
		return {}
	var mesh: Mesh = buildings_view.story_glow_mesh_for(type)
	if mesh == null:
		return {}
	var mat := ShaderMaterial.new()
	mat.shader = SHELL_SHADER
	mat.set_shader_parameter("glow_scale", _shell_scale)
	mat.set_shader_parameter("glow_pivot", mesh.get_aabb().get_center())
	mat.set_shader_parameter("glow_color", ConfigRes.parse_color(color_hex))
	mat.set_shader_parameter("alpha_scale", _shell_alpha)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = SHELL_CAPACITY
	var node := MultiMeshInstance3D.new()
	node.name = "StoryGlowShell_" + type
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	var rec := {"mm": mm, "node": node, "mesh": mesh}
	_shell_layers[key] = rec
	return rec


# ------------------------------------------------------------------
# 迷雾
# ------------------------------------------------------------------

func _unit_visible(u) -> bool:
	if world.fog == null:
		return true
	return world.fog.unit_visible(String(world.my_faction), u)


func _building_visible(b) -> bool:
	if world.fog == null:
		return true
	return world.fog.building_visible(String(world.my_faction), b)
