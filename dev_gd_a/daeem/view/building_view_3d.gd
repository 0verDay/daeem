## building_view_3d.gd —— 3D 建筑：**一个 MultiMeshInstance3D 画一批**（网格按类型：有模型用模型，否则单位方块）
##
## ★★ 网格从哪来（本版）：
##   · **城墙 / 箭塔 / 大本营 / 区划中心用 Blender 导出的模型**（`assets/models/*_lowpoly.glb`，
##     路径表 = `BUILDING_MODELS`，见文件末尾 `_uses_model` / `_load_building_mesh`）——
##     模型按「1 单位 = 1 格、底边在 y = 0」建好，落地时**统一缩放格宽 × body_scale**、
##     高度由模型自己决定（不走 `_height_of`）；
##   · 其余类型仍是**单位立方体 `BoxMesh`**，靠**逐实例的非等比缩放**
##     `(格宽 × body_scale, 格宽 × 视觉高度, 格宽 × body_scale)` 表达尺寸差异。
##   两者都是「一批一个 MultiMesh ⇒ 每批 1 次 draw call」。
##   ★ 有模型的类型**只有模型这一条路**：不再有「素材缺失就退回方块」的兜底 ——
##     那会把「模型根本没加载进来」这个真问题，藏成一个看不出差别的立方体。
##     模型加载不到时 `_load_building_mesh` 会 `push_error`，而不是悄悄画方块。
##
## ★★ 高度从哪来（关键：`logic/` 一格不改）：
##   · 方块类型：**纯表现**的常量，写在 `config.json` 的 `render.building_height.<type>`，
##     缺省 1.0 格（见 `_height_of`：箭塔 1.15 / 大本营 1.35 …）；
##   · 模型类型（城墙 / 箭塔 / 大本营 / 区划中心）：由模型自带（城墙 0.55、箭塔 1.9167、大本营 2.25、旗子 0.86 格高）。
##   它**不参与**寻路 / 碰撞 / 攻击（那些都读 `logic/building.gd`
##   的 `body_scale`，仍然是一格里的平面块）。
##   ★ 这条边界很重要：视觉上立起来 ≠ 逻辑上有高度。
##
## ★★ 有单位靠近 ⇒ 整栋淡出（见文件末尾 `_fade_marked_tiles` 与 building_flash.gdshader）：
##   以建筑所在格为中心的 3x3 内有**可见单位**时，整栋淡到 `render.building_fade_alpha`，
##   这样单位不会被建筑挡住。★ 该 shader 写了 ALPHA（走透明管线），靠 `depth_draw_always`
##   强制写深度，建筑之间的前后遮挡才不会按「谁后画谁在上」乱掉。
##
## ★ 不投影阴影（用户口径）。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
## ★ 建筑材质：逐像素受击闪白（自定义 shader，见文件）
const BUILDING_FLASH_SHADER = preload("res://view/building_flash.gdshader")

## ★★ 有模型的建筑类型 → 模型路径（Blender 导出；**1 单位 = 1 格**、底边在 y = 0、铺满整格）。
##   游戏里按「格宽 × body_scale」**统一缩放** ⇒ 落地尺寸 = 128 × body_scale × 模型尺寸：
##     · 城墙（body_scale 1.0）：128 × 128 × 70.4（模型高 0.55）；
##     · 箭塔 / 大本营（body_scale 0.6）：76.8 × 76.8 × 147.2 / 172.8（模型高 1.9167 / 2.25）；
##   · 区划中心（body_scale 1.0，**旗杆**）：128 × …（模型高 1.10 ⇒ 落地 140.8）。
##   ★ 这些类型一律用各自的模型；加载不到由 `_load_building_mesh` 报错，**不退回方块**。
##   ★★ 这张表是**唯一**的「哪些类型走模型」的判据（`_uses_model` / `_mesh_for` 都读它）。
const BUILDING_MODELS := {
	"wall": "res://assets/models/wall_lowpoly.glb",
	"tower": "res://assets/models/tower_lowpoly.glb",
	"base": "res://assets/models/base_lowpoly.glb",
	"zone_center": "res://assets/models/zone_center_lowpoly.glb",
}

## ★★ 可动部件：类型 → 模型路径。这些网格**不随建筑本体固定**，而是由 `_sync_flags()` 按
##   游戏状态**逐实例摆**（目前只有区划中心的**旗面**：占领时沿旗杆上升）。
##   ★ 旗面模型按「底边在 y = 0」建好 ⇒ 把它整体平移到哪，底边就落在哪。
const BUILDING_MOVING_MODELS := {
	"zone_center": "res://assets/models/zone_center_flag_lowpoly.glb",
}

## ★★ 「离地抬起量」（世界单位）：所有建筑/旗子都按它贴地（见 `_transform_of` / `_flag_transform`）。
const GROUND_LIFT := 0.6

## ★★ 区划中心旗子的动画几何（**必须与两个模型对得上**；1 单位 = 1 格）。
##   · 旗杆模型 zone_center_lowpoly.glb：杆身 z ∈ [ZC_POLE_BOTTOM, ZC_POLE_TOP]；
##   · 旗面模型 zone_center_flag_lowpoly.glb：底边在 z = 0、高 ZC_CLOTH_H。
##   旗面**底边**随占领进度从杆底线性升到「杆顶 − 旗高」（升到顶时旗面顶边正好到杆顶）。
const ZC_POLE_BOTTOM := 0.12
const ZC_POLE_TOP := 1.02
const ZC_CLOTH_H := 0.32

var cfg: ConfigRes = null
var world = null
var palette = null

var _box: BoxMesh = null
## 类型 → 合并后的模型网格（加载不到 = null ⇒ **不画**，由 `_load_building_mesh` 报错；**不退回方块**）
var _model_meshes: Dictionary = {}
## 可动部件：类型 → 网格（同上，加载不到 = null ⇒ 不画）
var _moving_meshes: Dictionary = {}
## 变体键（"阵营|类型"）→ {node, mm, capacity}
var _batches: Dictionary = {}
## ★★ 旗面批：**颜色**键 → {node, mm}（不同占领方颜色不同，所以按颜色分桶）
var _flag_batches: Dictionary = {}
var _color_cache: Dictionary = {}

## 诊断（只有测试读它）
var instance_count: int = 0
var mesh_batch_count: int = 0
var batches_created: int = 0
## ★ 本帧有多少栋建筑被施加了「受击左右振动」（诊断，测试读它）
var shake_applied_last_frame: int = 0
## ★ 本帧有多少栋建筑写了受击闪白（诊断，测试读它）
var flash_written_last_frame: int = 0
## ★ 本帧有多少栋建筑被「单位靠近」淡出（诊断，测试读它）
var faded_last_frame: int = 0
## ★★ 本帧画了几面旗（区划中心占领动画；诊断，测试读它）
var flag_instance_count: int = 0
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
	_model_meshes = {}
	for t in BUILDING_MODELS:
		_model_meshes[t] = _load_building_mesh(BUILDING_MODELS[t])
	_moving_meshes = {}
	for t in BUILDING_MOVING_MODELS:
		_moving_meshes[t] = _load_building_mesh(BUILDING_MOVING_MODELS[t])


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


func _batch_for(key: String, color: Color, type: String = "") -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_FLASH_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))
	# ★ 有单位靠近时整栋淡到的不透明度（见 building_flash.gdshader 的 depth_draw_always 说明）
	mat.set_shader_parameter("fade_alpha", cfg.num("render.building_fade_alpha", 0.3))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# ★ 有模型的类型（城墙 / 箭塔 / 大本营 / 区划中心）用各自的模型网格；其余仍是单位方块（逐实例缩放表达尺寸）
	mm.mesh = _mesh_for(type)
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
	faded_last_frame = 0
	flag_instance_count = 0
	# ★ 先把「哪些格附近有可见单位」标出来（一次 O(单位数)），建筑逐栋查表即可
	var marked: Dictionary = _fade_marked_tiles()
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
		var rec: Dictionary = _batch_for(key, col, String(b0.type))
		var mm: MultiMesh = rec["mm"]
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			mm.set_instance_transform(i, _transform_of(arr[i]))
			# ★ 受击闪白（.r）+ 靠近淡出（.g）：逐实例自定义数据
			#   （建筑很少，直接每帧写，不做脏检查 —— 与闪白同一条口径）
			var flash: float = clampf(arr[i].hit_flash, 0.0, 1.0)
			var fade: float = 1.0 if should_fade(arr[i], marked) else 0.0
			mm.set_instance_custom_data(i, Color(flash, fade, 0.0, 0.0))
			if flash > 0.0:
				flash_written_last_frame += 1
			if fade > 0.0:
				faded_last_frame += 1
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
	# ★★ 旗面（可动部件）单独一发：按占领进度摆在旗杆上（见 `_sync_flags`）
	_sync_flags(marked)


## 一栋建筑在世界里的变换：底边贴地、尺寸 = 本体平面尺寸 × 视觉高度
##
## ★ `body_scale` 是 **logic 的权威**（占一格的比例，碰撞也用它）；
##   这里只把它翻译成 3D 的宽 / 深，**不新增任何尺寸来源**。
##   高度来自 `_height_of()`（纯表现）；有模型的类型（城墙）改用模型自带的高度。
func _transform_of(b) -> Transform3D:
	var cell: float = palette.cell_size()
	var c: Vector2 = b.center()
	var base: Vector3 = palette.to_world(c)
	# ★ 受击左右振动（纯表现）：X 方向一个小位移，随 hit_flash 衰减
	var shake := 0.0
	if b.hit_flash > 0.0:
		shake = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell
		shake_applied_last_frame += 1
	var s: float = b.body_scale(cfg)
	# ★★ 有模型的类型（城墙 / 箭塔 / 大本营 / 区划中心）：模型已按「1 单位 = 1 格、底边在 y = 0」建好 ⇒
	#    统一缩放格宽 × body_scale、底边直接贴地（高度由模型自己决定，不再走 `_height_of`）。
	if _uses_model(String(b.type)):
		var k: float = cell * s
		return Transform3D(Basis().scaled(Vector3(k, k, k)),
			Vector3(base.x + shake, GROUND_LIFT, base.z))
	var w: float = cell * s
	var h: float = cell * _height_of(b)
	# 立方体以**中心**为原点 ⇒ 抬到「底边贴地」，并贴在地面之上一点避免 z-fighting
	var pos := Vector3(base.x + shake, h * 0.5 + GROUND_LIFT, base.z)
	return Transform3D(Basis().scaled(Vector3(w, h, w)), pos)


# ------------------------------------------------------------------
# ★★ 区划中心旗子（占领动画）：旗面沿旗杆上升，升起程度 = 占领进度
# ------------------------------------------------------------------

## 这一类型有没有**可动部件**（旗面）。
func _uses_moving(type: String) -> bool:
	return BUILDING_MOVING_MODELS.has(type)


## 一面旗子现在该画成什么样：`progress` 0 = **不画**（无人占领），0~1 = 升起程度；`color` = 旗色。
##
## ★ 口径（与 logic/zone.gd 的字段一一对应，别在别处重算）：
##   · 已被某一方占领（`owner != ""`）                → progress 1.0（升到顶），旗色 = 归属方主色；
##   · 正在被读条占领（`capture_state != ""` 且有进度）→ progress = 该进度，旗色 = 占领方主色；
##   · 其余（无主且无人读条）                        → progress 0.0（**旗杆上没有旗子**）。
func zone_flag_state(b) -> Dictionary:
	var fallback: Color = cfg.color("zone_center")
	if world == null:
		return {"progress": 0.0, "color": fallback}
	var z: Variant = world.zone_by_id(int(b.zone_id))
	if z == null:
		return {"progress": 0.0, "color": fallback}
	var owner := String(z["owner"])
	if owner != "":
		return {"progress": 1.0, "color": cfg.faction_color(owner, "main")}
	var who := String(z.get("capture_faction", ""))
	var state := String(z.get("capture_state", ""))
	var prog: float = clampf(float(z.get("progress", 0.0)), 0.0, 1.0)
	if state != "" and prog > 0.0 and who != "":
		return {"progress": prog, "color": cfg.faction_color(who, "main")}
	return {"progress": 0.0, "color": fallback}


## 旗面在世界里的变换：**底边**随进度从杆底线性升到「杆顶 − 旗高」。
## ★ 旗面模型底边在局部 y = 0 ⇒ 整体抬到 `GROUND_LIFT + 底边高度 × k` 就是它的世界位置。
func _flag_transform(b, progress: float) -> Transform3D:
	var cell: float = palette.cell_size()
	var base: Vector3 = palette.to_world(b.center())
	var shake := 0.0
	if b.hit_flash > 0.0:
		shake = HitFxRes.shake_tiles(b.hit_flash, _hit_amp, _hit_freq) * cell
	var k: float = cell * b.body_scale(cfg)
	var t: float = clampf(progress, 0.0, 1.0)
	var z_bottom: float = lerpf(ZC_POLE_BOTTOM, ZC_POLE_TOP - ZC_CLOTH_H, t)
	return Transform3D(Basis().scaled(Vector3(k, k, k)),
		Vector3(base.x + shake, GROUND_LIFT + z_bottom * k, base.z))


## 旗面的 MultiMesh（按「类型 + 颜色」分桶：不同占领方颜色不同 ⇒ 一批一色）。
func _flag_batch_for(key: String, color: Color, type: String) -> Dictionary:
	var hit: Variant = _flag_batches.get(key, null)
	if hit != null:
		return hit
	var mat := ShaderMaterial.new()
	mat.shader = BUILDING_FLASH_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))
	mat.set_shader_parameter("fade_alpha", cfg.num("render.building_fade_alpha", 0.3))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _moving_meshes.get(type, null)
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（见 unit_view_3d 的说明）
	mm.use_custom_data = true
	mm.instance_count = 16
	var node := MultiMeshInstance3D.new()
	node.name = "Flags_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	var rec := {"node": node, "mm": mm}
	_flag_batches[key] = rec
	return rec


## 每帧摆旗面：只画 `progress > 0` 的区划中心，逐面按进度抬高（闪白 / 淡出与建筑同一条口径）。
func _sync_flags(marked: Dictionary) -> void:
	if world == null or cfg == null:
		return
	var buckets: Dictionary = {}
	for b in world.building_list:
		if not b.alive or not _uses_moving(String(b.type)):
			continue
		# ★★ 战争迷雾：看不见的敌方建筑不给画旗（判据同建筑本体）
		if not _visible_to_me(b):
			continue
		var st: Dictionary = zone_flag_state(b)
		var pr: float = float(st["progress"])
		if pr <= 0.0:
			continue
		var type := String(b.type)
		var col: Color = st["color"]
		var key := "%s|%s" % [type, col.to_html(false)]
		var rec: Variant = buckets.get(key, null)
		if rec == null:
			rec = {"type": type, "color": col, "items": []}
			buckets[key] = rec
		(rec["items"] as Array).append({"b": b, "p": pr})
	for key in buckets.keys():
		var rec2: Dictionary = buckets[key]
		var items: Array = rec2["items"]
		var brec: Dictionary = _flag_batch_for(key, rec2["color"], String(rec2["type"]))
		var mm: MultiMesh = brec["mm"]
		if mm.instance_count < items.size():
			mm.instance_count = maxi(items.size(), mm.instance_count * 2)
		for i in items.size():
			var b = items[i]["b"]
			mm.set_instance_transform(i, _flag_transform(b, float(items[i]["p"])))
			var flash: float = clampf(b.hit_flash, 0.0, 1.0)
			var fade: float = 1.0 if should_fade(b, marked) else 0.0
			mm.set_instance_custom_data(i, Color(flash, fade, 0.0, 0.0))
		mm.visible_instance_count = items.size()
		(brec["node"] as MultiMeshInstance3D).visible = true
		flag_instance_count += items.size()
	for key in _flag_batches.keys():
		if not buckets.has(key):
			var r2: Dictionary = _flag_batches[key]
			(r2["mm"] as MultiMesh).visible_instance_count = 0
			(r2["node"] as MultiMeshInstance3D).visible = false


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


# ------------------------------------------------------------------
# ★★ 有单位靠近 ⇒ 建筑淡出（本轮新增；口径见 config.json 的 _building_fade_comment）
# ------------------------------------------------------------------

## 「哪些格附近有可见单位」——以每个可见单位所在格为中心，连同它 8 个邻格一起标出。
##
## ★ 建筑只要落在这些格之一就淡出 ⇒ 「以建筑为中心的 3x3 内有单位」= 一次字典查找。
##   比「逐建筑扫全部单位」便宜（建筑逐帧重画；单位可能有几十个）。
## ★ 只算**当前可见**的单位：迷雾里的敌人不该让建筑淡出 —— 那会把它的位置漏出去。
func _fade_marked_tiles() -> Dictionary:
	var marked: Dictionary = {}
	if world == null:
		return marked
	for u in world.units:
		if not u.alive:
			continue
		if not _unit_visible(u):
			continue
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				marked[Vector2i(u.tx + dx, u.ty + dy)] = true
	return marked


## 这栋建筑要不要淡出（它所在格在 `marked` 里 = 以它为中心的 3x3 内有可见单位）。
func should_fade(b, marked: Dictionary) -> bool:
	return marked.has(Vector2i(b.tx, b.ty))


## 单位对「我这边」可不可见（与 unit_view_3d 同一条判据：迷雾的唯一出处是 logic/fog.gd）。
func _unit_visible(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


# ------------------------------------------------------------------
# ★★ 建筑模型（本轮新增）：用 Blender 导出的 `.glb` 取代单位方块
# ------------------------------------------------------------------

## 这一类型是不是走模型（而不是单位方块）。
## ★ 只此一处判据：`_batch_for` 选网格、`_transform_of` 选变换都读它，两边永远一致。
## ★★ 这里**不看**模型是否加载成功 —— 这些类型就是模型这条路，
##   加载失败由 `_load_building_mesh` 报错，绝不退回方块（见文件头）。
func _uses_model(type: String) -> bool:
	return BUILDING_MODELS.has(type)


## 这一类型用哪个网格：有模型的走模型，其余走单位方块。
## ★ 与 `_uses_model` 同源（同一张 `BUILDING_MODELS`）⇒ 不会出现「变换按模型算、网格却是方块」。
func _mesh_for(type: String) -> Mesh:
	if _uses_model(type):
		return _model_meshes.get(type, null)
	return _box


## 载入一个建筑模型；失败返回 null 并 `push_error`（**不退回方块**）。
## ★★ 不走 `ResourceLoader.exists` 那道「保险」：导出后的工程里，源文件路径与存在的资源
##   不是一回事（资源被改写成 `.scn` / `.ctex` 并重映射），先 `exists` 再 `load` 会在
##   导出包里把「模型在」误判成「模型不在」⇒ 悄悄退回方块。`load()` 自己会走重映射。
func _load_building_mesh(path: String) -> Mesh:
	var res: Variant = load(path)
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		var m: Mesh = _build_merged_mesh(inst)
		inst.free()
		if m != null:
			return m
	push_error("建筑模型加载失败：%s（该类型不退回方块，请确认素材已导入 / 已随工程导出）" % path)
	return null


## 把导入场景里**所有** MeshInstance3D 的网格按各自节点变换**合并成一个** ArrayMesh。
## ★★ 为什么不「取一个网格」：Blender 里的模型往往是**多个物体的组合**（塔身 + 基座 + 尖顶 …），
##   glb 会把它们当成**多个 mesh** 带进来，而 MultiMesh 一个批次只能挂一个 mesh。
##   取「第一个」只会拿到排在前面的那块、取「占地最大」又会丢掉细部 —— 两种都错。
##   正确做法是**全都要**：合成一个再交给 MultiMesh。
func _build_merged_mesh(root: Node) -> Mesh:
	var parts: Array = []
	_collect_meshes(root, Transform3D.IDENTITY, parts)
	if parts.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for e in parts:
		var m: Mesh = e["mesh"]
		for s in m.get_surface_count():
			st.append_from(m, s, e["xform"])
	return st.commit()


## 深度优先收集所有 MeshInstance3D 的网格，以及它**相对根节点**的变换。
## ★ 合并时必须带上节点自身的平移 / 旋转 / 缩放，否则各部分的位置会丢（柱子会塌回原点）。
func _collect_meshes(node: Node, parent: Transform3D, out: Array) -> void:
	var here: Transform3D = parent * node.transform
	if node is MeshInstance3D:
		var m: Mesh = (node as MeshInstance3D).mesh
		if m != null:
			out.append({"mesh": m, "xform": here})
	for ch in node.get_children():
		_collect_meshes(ch, here, out)
