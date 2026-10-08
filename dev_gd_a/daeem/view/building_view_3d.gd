## building_view_3d.gd —— 3D 建筑：**一个 MultiMeshInstance3D + BoxMesh 画全部**
##
## ★★ 为什么用 BoxMesh 而不是「每种建筑一个 3D 模型」（本版的取舍）：
##   · 建筑数量少（这张图上不到 30 栋），但它们**形状各异**（城墙细长、
##     箭塔方、大本营大）。用 `MultiMesh` + 一个单位立方体，
##     靠**逐实例的非等比缩放**表达尺寸差异 ⇒ **1 次 draw call**；
##   · 真模型（每种一个 `.glb`）现在是空谈 —— 项目还没有任何 3D 美术资源。
##   ⚠️ 代价：所有建筑都是方块（城墙也是方块）。这符合「先程序化占位」的口径，
##      以后有模型了只需把 `_box` 换成对应 mesh、并给每种类型一个 MultiMesh。
##
## ★★ 高度从哪来（关键：`logic/` 一格不改）：
##   高度是**纯表现**的常量，写在 `config.json` 的 `render.building_height.<type>`，
##   缺省 1.0 格。它**不参与**寻路 / 碰撞 / 攻击（那些都读 `logic/building.gd`
##   的 `body_scale`，仍然是一格里的平面块）。
##   ★ 这条边界很重要：视觉上立起来 ≠ 逻辑上有高度。
##
## ★ 不投影阴影（用户口径）。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
## ★ 建筑材质：逐像素受击闪白（自定义 shader，见文件）
const BUILDING_FLASH_SHADER = preload("res://view/building_flash.gdshader")

var cfg: ConfigRes = null
var world = null
var palette = null

var _box: BoxMesh = null
## 变体键（"阵营|类型"）→ {node, mm, capacity}
var _batches: Dictionary = {}
var _color_cache: Dictionary = {}

## 诊断（只有测试读它）
var instance_count: int = 0
var mesh_batch_count: int = 0
var batches_created: int = 0
## ★ 本帧有多少栋建筑被施加了「受击左右振动」（诊断，测试读它）
var shake_applied_last_frame: int = 0
## ★ 本帧有多少栋建筑写了受击闪白（诊断，测试读它）
var flash_written_last_frame: int = 0
## 受击振动参数（setup 缓存）
var _cell: float = 128.0
var _hit_amp: float = 0.06
var _hit_freq: float = 26.0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	# 单位立方体（1×1×1，中心在原点）——靠逐实例缩放表达各建筑的真实尺寸
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	_cell = palette.cell_size()
	_hit_amp = cfg.num("render.hit_shake_cells", 0.06)
	_hit_freq = cfg.num("render.hit_shake_freq", 26.0)


## 建筑在世界里的高度（格）——**纯表现**，缺省 1 格
func _height_of(b) -> float:
	var t := String(b.type)
	var h: float = cfg.num("render.building_height.%s" % t, 0.0)
	if h <= 0.0:
		# 没配就用「类型缺省表」：城墙矮、大本营最高
		match t:
			"wall":
				h = 0.55
			"tower":
				h = 1.15
			"base":
				h = 1.35
			"zone_center":
				h = 0.35
			_:
				h = 1.0
	return maxf(0.05, h)


func _batch_for(key: String, color: Color) -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_FLASH_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _box
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（见 unit_view_3d 的说明）
	mm.use_custom_data = true
	mm.instance_count = 64

	var node := MultiMeshInstance3D.new()
	node.name = "Buildings_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	var rec := {"node": node, "mm": mm}
	_batches[key] = rec
	return rec


## 每帧同步（建筑很少，重建的代价可忽略；但仍按「阵营 + 类型 + 等级」分桶以保持合批）
func sync() -> void:
	if world == null or palette == null or _box == null:
		return
	shake_applied_last_frame = 0
	flash_written_last_frame = 0
	var buckets: Dictionary = {}
	for b in world.building_list:
		if not b.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方建筑**一个实例都不占**
		#    （判据只在 logic/fog.gd：己方 / 无主永远可见，敌方「见过就记住」）
		if not _visible_to_me(b):
			continue
		var key := "%s|%s" % [String(b.owner), String(b.type)]
		var arr: Array = buckets.get(key, [])
		arr.append(b)
		buckets[key] = arr

	var total: int = 0
	var used: int = 0
	for key in buckets.keys():
		var arr: Array = buckets[key]
		var b0 = arr[0]
		var owner := String(b0.owner)
		var col: Color = _faction_or_type_color(b0, owner)
		var rec: Dictionary = _batch_for(key, col)
		var mm: MultiMesh = rec["mm"]
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			mm.set_instance_transform(i, _transform_of(arr[i]))
			# ★ 受击闪白：逐实例自定义数据（建筑很少，直接每帧写，不做脏检查）
			var flash: float = clampf(arr[i].hit_flash, 0.0, 1.0)
			mm.set_instance_custom_data(i, Color(flash, 0.0, 0.0, 0.0))
			if flash > 0.0:
				flash_written_last_frame += 1
		mm.visible_instance_count = arr.size()
		(rec["node"] as MultiMeshInstance3D).visible = true
		total += arr.size()
		used += 1
	for key in _batches.keys():
		if not buckets.has(key):
			var rec2: Dictionary = _batches[key]
			(rec2["mm"] as MultiMesh).visible_instance_count = 0
			(rec2["node"] as MultiMeshInstance3D).visible = false
	instance_count = total
	mesh_batch_count = used


## 一栋建筑在世界里的变换：底边贴地、尺寸 = 本体平面尺寸 × 视觉高度
##
## ★ `body_scale` 是 **logic 的权威**（占一格的比例，碰撞也用它）；
##   这里只把它翻译成 3D 的宽 / 深，**不新增任何尺寸来源**。
##   高度来自 `_height_of()`（纯表现）。
func _transform_of(b) -> Transform3D:
	var cell: float = palette.cell_size()
	var s: float = b.body_scale(cfg)
	var w: float = cell * s
	var h: float = cell * _height_of(b)
	var c: Vector2 = b.center()
	var base: Vector3 = palette.to_world(c)
	# ★ 受击左右振动（纯表现）：X 方向一个小位移，随 hit_flash 衰减
	var shake := 0.0
	if b.hit_flash > 0.0:
		shake = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell
		shake_applied_last_frame += 1
	# 立方体以**中心**为原点 ⇒ 抬到「底边贴地」，并贴在地面之上一点避免 z-fighting
	var pos := Vector3(base.x + shake, h * 0.5 + 0.6, base.z)
	return Transform3D(Basis().scaled(Vector3(w, h, w)), pos)


func _faction_or_type_color(b, owner: String) -> Color:
	# 无主的（区划中心）用它们自己的颜色，别去查阵营色（查不到会画成默认灰）
	if owner == "":
		match String(b.type):
			"zone_center":
				return cfg.color("zone_center")
			_:
				return cfg.color("wall")
	var key := "%s|%s" % [owner, String(b.type)]
	var hit: Variant = _color_cache.get(key, null)
	if hit != null:
		return hit
	var c: Color
	match String(b.type):
		"wall":
			c = cfg.color("wall")
		"tower":
			c = cfg.color("tower")
		"base":
			c = cfg.faction_color(owner, "main")
		_:
			c = cfg.faction_color(owner, "main")
	_color_cache[key] = c
	return c


func _visible_to_me(b) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.building_visible(world.my_faction, b)
