## building_view_3d.gd —— 3D 建筑：**一个 MultiMeshInstance3D 画一批**（网格按类型二选一）
##
## ★★ 网格从哪来（本版）：
##   · **城墙用 Blender 导出的模型**（`assets/models/wall_lowpoly.glb`，见文件末尾
##     `_uses_model` / `_load_wall_mesh`）——模型按「1 单位 = 1 格、底边在 y = 0」建好，
##     落地时**统一缩放格宽**、高度由模型自己决定（不走 `_height_of`）；
##   · 其余类型仍是**单位立方体 `BoxMesh`**，靠**逐实例的非等比缩放**
##     `(格宽 × body_scale, 格宽 × 视觉高度, 格宽 × body_scale)` 表达尺寸差异。
##   两者都是「一批一个 MultiMesh ⇒ 每批 1 次 draw call」。
##   ★ 城墙**只有模型这一条路**：不再有「素材缺失就退回方块」的兜底 ——
##     那会把「模型根本没加载进来」这个真问题，藏成一个看不出差别的立方体。
##     模型加载不到时 `_load_wall_mesh` 会 `push_error`，而不是悄悄画方块。
##   ⚠️ 还没有模型的类型（箭塔 / 大本营）形状仍是方块 —— 以后照城墙这条加即可。
##
## ★★ 高度从哪来（关键：`logic/` 一格不改）：
##   · 方块类型：**纯表现**的常量，写在 `config.json` 的 `render.building_height.<type>`，
##     缺省 1.0 格（见 `_height_of`：箭塔 1.15 / 大本营 1.35 …）；
##   · 城墙模型：由模型自带（已按 0.55 格高建好）。
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

## ★★ 城墙的 3D 模型（Blender 导出；**1 单位 = 1 格**、底边在 y = 0、铺满整格）。
##   游戏里按「格宽 × body_scale」**统一缩放** ⇒ 落地尺寸 = 128 × 128 × 70.4。
##   ★ 城墙一律用这个模型；加载不到由 `_load_wall_mesh` 报错，**不退回方块**。
const WALL_MODEL := "res://assets/models/wall_lowpoly.glb"

var cfg: ConfigRes = null
var world = null
var palette = null

var _box: BoxMesh = null
## 城墙模型（加载不到 = null ⇒ **不画**，由 `_load_wall_mesh` 报错；**不退回方块**）
var _wall_mesh: Mesh = null
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
## ★ 本帧有多少栋建筑被「单位靠近」淡出（诊断，测试读它）
var faded_last_frame: int = 0
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
	_wall_mesh = _load_wall_mesh()


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
	# ★ 有模型的类型（城墙）用模型网格；其余仍是单位方块（逐实例缩放表达尺寸）
	mm.mesh = _wall_mesh if _uses_model(type) else _box
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
	# ★★ 有模型的类型（城墙）：模型已按「1 单位 = 1 格、底边在 y = 0」建好 ⇒
	#    统一缩放格宽、底边直接贴地（高度由模型自己决定，不再走 `_height_of`）。
	if _uses_model(String(b.type)):
		var k: float = cell * s
		return Transform3D(Basis().scaled(Vector3(k, k, k)),
			Vector3(base.x + shake, 0.6, base.z))
	var w: float = cell * s
	var h: float = cell * _height_of(b)
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
# ★★ 城墙模型（本轮新增）：用 Blender 导出的 `.glb` 取代单位方块
# ------------------------------------------------------------------

## 这一类型是不是走模型（而不是单位方块）。
## ★ 只此一处判据：`_batch_for` 选网格、`_transform_of` 选变换都读它，两边永远一致。
## ★★ 这里**不看** `_wall_mesh` 是否加载成功 —— 城墙就是模型这条路，
##   加载失败由 `_load_wall_mesh` 报错，绝不退回方块（见文件头）。
func _uses_model(type: String) -> bool:
	return type == "wall"


## 载入城墙模型；失败返回 null 并 `push_error`（**不退回方块**）。
## ★★ 不走 `ResourceLoader.exists` 那道「保险」：导出后的工程里，源文件路径与存在的资源
##   不是一回事（资源被改写成 `.scn` / `.ctex` 并重映射），先 `exists` 再 `load` 会在
##   导出包里把「模型在」误判成「模型不在」⇒ 悄悄退回方块。`load()` 自己会走重映射。
func _load_wall_mesh() -> Mesh:
	var res: Variant = load(WALL_MODEL)
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		var m: Mesh = _build_wall_mesh(inst)
		inst.free()
		if m != null:
			return m
	push_error("城墙模型加载失败：%s（城墙不退回方块，请确认素材已导入 / 已随工程导出）" % WALL_MODEL)
	return null


## 把导入场景里**所有** MeshInstance3D 的网格按各自节点变换**合并成一个** ArrayMesh。
## ★★ 为什么不「取一个网格」：Blender 里的城墙是**多个物体的组合**（墙身 + 它上面那根
##   细柱 …），glb 会把它们当成**多个 mesh** 带进来，而 MultiMesh 一个批次只能挂一个 mesh。
##   取「第一个」只会拿到排在前面的那块（实测：柱子在墙身前 ⇒ 城墙上只剩一根刺），
##   取「占地最大」又会把柱子丢掉 —— 两种都错。正确做法是**全都要**：合成一个再交给 MultiMesh。
func _build_wall_mesh(root: Node) -> Mesh:
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
