## unit_view_3d.gd —— 3D 单位：**按「阵营 × 是否将领 × 兵种 × 是否濒死」分组的多批次 MultiMesh**
##                   + 将领脚下的**占位贴花**层
##
## ★★ 为什么是「多批次」而不是「一个 MultiMesh 画全部」（本版最重要的性能取舍）：
##   `MultiMesh` 的所有实例**共用同一个 mesh ⇒ 同一张贴图**，因此它**不支持逐实例贴图**。
##   而兵人立牌要做到「阵营色 + 将领更粗的描边 + 每个兵种一张占位素材 + 濒死半透明」，
##   就必须有多张图 / 多个材质。
##   ⇒ 做法是：**每种变体一个 `MultiMeshInstance3D`**（各自一张贴图），
##     变体数 = 阵营数 × 2 × 兵种数，本项目每一项都是个位数 ⇒ **仍然只有个位数 draw call**，
##     1000 个单位全部塞在这些 MultiMesh 里，一个实例一个单位。
##   ★ 与 2D 那版「按贴图分桶再合批」是**同一个意图换了工具**：
##     那次踩过的坑是「桶用值语义的打包数组 ⇒ 永远是空的 ⇒ 什么都不画」，
##     这里同样留了计数器（`instance_count` / `mesh_batch_count`）给测试钉。
##
## ★ 立起来 + 面向相机 = 材质的 `billboard_mode = BILLBOARD_ENABLED`
##   （引擎自带，**不需要自己写 shader**：绕 Y 轴转向相机、保持直立）。
##
## ★ 那个「字」不在这层：它放在**屏幕空间的覆盖层**里（`overlay_view_3d.gd`），
##   好处是天然 1:1、永远正着朝玩家。
##
## ★ 只读 `world`，不改任何逻辑状态。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const HitFxRes = preload("res://view/hit_fx.gd")
## ★ 立牌材质：billboard + 逐像素受击闪白（自定义 shader，见文件头）
const UNIT_FLASH_SHADER = preload("res://view/unit_flash.gdshader")
## ★ 濒死将领的立牌材质：billboard + **整体半透明**（走透明管线；见 unit_downed.gdshader）
const UNIT_DOWNED_SHADER = preload("res://view/unit_downed.gdshader")
## ★ 选中下标：脚下「绿色空心圆」贴花（逐实例透明度动画；见 selection_ring.gdshader）
const SELECTION_RING_SHADER = preload("res://view/selection_ring.gdshader")

## 立牌的世界宽度（一格的比例）
const QUAD_W := 0.42
## 立牌高宽比（贴图是 64×96 ⇒ 1.5）
const QUAD_H_RATIO := 1.5

var cfg: ConfigRes = null
var world = null
var palette = null

var _quad: QuadMesh = null
## 变体键（"阵营|是否将领|兵种|是否濒死"）→ {node, mm, capacity}
var _batches: Dictionary = {}
## 变体键 → 颜色缓存
var _color_cache: Dictionary = {}

## ★★ 将领脚下的**占位贴花**：一个 MultiMesh 画所有将领（逐实例色 = 阵营色）。
var _decal_quad: PlaneMesh = null
var _decal_mm: MultiMesh = null
var _decal_node: MultiMeshInstance3D = null

## ★★ 选中下标：被选中单位脚下的**绿色空心圆**贴花（逐实例透明度动画）。
var _sel_quad: PlaneMesh = null
var _sel_mm: MultiMesh = null
var _sel_node: MultiMeshInstance3D = null
## id → 出现进度（0 = 完全收起，1 = 完全出现）；`sync(dt)` 每帧朝目标推进
var _sel_anim: Dictionary = {}
## 当前选中的 id 集合（由 `set_selection(ids)` 喂进来）
var _selection_set: Dictionary = {}
## 动画参数（setup 缓存）
var _sel_sec: float = 0.18
var _sel_alpha: float = 0.8
var _sel_scale_from: float = 1.5

## 诊断（只有测试读它）
var instance_count: int = 0
var visible_count: int = 0
## 当前**有实例**的批次数（正常 = 场上出现过的变体数）
var mesh_batch_count: int = 0
## 累计创建过的批次数
var batches_created: int = 0
## ★★ 最近一帧真的**写了几次**实例变换（优化的证据：位置没变的单位不算）
var instance_writes_last_frame: int = 0
## ★ 本帧有多少实例被施加了「受击左右振动」（诊断，测试读它）
var shake_applied_last_frame: int = 0
## ★ 本帧有多少实例真的**写了**受击闪白（诊断，测试读它）
var flash_written_last_frame: int = 0
## ★ 本帧有多少单位是「濒死将领」（走半透明材质；诊断，测试读它）
var downed_count: int = 0
## ★ 本帧画了几张将领脚下贴花（诊断，测试读它）
var decal_count: int = 0
## ★ 本帧画了几个「选中下标」（诊断，测试读它）
var selection_ring_count: int = 0
## ★ 本帧**第一个**选中下标的缩放 / 不透明度（诊断，测试读它）。
##   ⚠️ 为什么不直接读 MultiMesh 的实例数据：实测（Godot 4.7 + 无头）
##   `MultiMesh.get_instance_transform()` **读不回**刚写进去的值（单位批次也读回单位阵），
##   所以把动画的两个关键值留成普通字段给测试钉。
var selection_scale_last: float = 0.0
var selection_alpha_last: float = 0.0
## 受击振动参数（setup 缓存）
var _cell: float = 128.0
var _hit_amp: float = 0.06
var _hit_freq: float = 26.0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	_quad = QuadMesh.new()
	var w: float = palette.cell_size() * QUAD_W
	_quad.size = Vector2(w, w * QUAD_H_RATIO)
	# ★ 受击振动参数：setup 时缓存一次（受击是「每单位每帧」的路径，别在里面 cfg.num）
	_cell = palette.cell_size()
	_hit_amp = cfg.num("render.hit_shake_cells", 0.06)
	_hit_freq = cfg.num("render.hit_shake_freq", 26.0)
	_build_decal_layer()
	# 选中下标动画参数（每帧要用 ⇒ setup 缓存）
	_sel_sec = maxf(0.01, cfg.num("render.selection_ring_sec", 0.18))
	_sel_alpha = clampf(cfg.num("render.selection_ring_alpha", 0.8), 0.0, 1.0)
	_sel_scale_from = maxf(0.1, cfg.num("render.selection_ring_scale_from", 1.5))
	_build_selection_layer()


## ★★ 将领脚下的占位贴花层：一块**平放**的 PlaneMesh + 一张程序化占位贴花，
##   逐实例色 = 阵营色（所以一张图复用到任意将领）。只画将领、只读 world。
func _build_decal_layer() -> void:
	var dcell: float = palette.cell_size() * maxf(0.05, cfg.num("render.general_decal_size", 0.6))
	_decal_quad = PlaneMesh.new()
	_decal_quad.size = Vector2(dcell, dcell)
	# ⚠️ PlaneMesh 默认 `FACE_Y`（躺在 XZ 平面、法线朝 +Y）⇒ 它本来就是**平放**的。
	#    显式写出来免得以后有人"顺手"给它加个绕 X 轴的旋转（那会把它立起来、几乎看不见）。
	_decal_quad.orientation = PlaneMesh.FACE_Y
	var dmat := StandardMaterial3D.new()
	dmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dmat.vertex_color_use_as_albedo = true          # 逐实例色（阵营色）乘进贴图
	dmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	dmat.albedo_texture = SpriteRes.decal_texture()
	# ★ 半透明：整张贴花淡一点，别把地面 / 单位压住（config: render.general_decal_alpha）
	dmat.albedo_color = Color(1.0, 1.0, 1.0,
		clampf(cfg.num("render.general_decal_alpha", 0.5), 0.0, 1.0))
	_decal_mm = MultiMesh.new()
	_decal_mm.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠️ `use_colors` 必须在 `instance_count` **之前**设（同 use_custom_data 那条约束）
	_decal_mm.use_colors = true
	_decal_mm.mesh = _decal_quad
	_decal_mm.instance_count = 64
	_decal_node = MultiMeshInstance3D.new()
	_decal_node.name = "GeneralDecals"
	_decal_node.multimesh = _decal_mm
	_decal_node.material_override = dmat
	add_child(_decal_node)


## ★★ 选中下标层：一块平放的小面片 + 「绿色空心圆」贴图；逐实例透明度走 INSTANCE_CUSTOM.r。
##   尺寸**与将领贴花一致**（用户口径：动效收到跟黄色底面贴花一样大）。
func _build_selection_layer() -> void:
	var cell: float = palette.cell_size() * maxf(0.05, cfg.num("render.general_decal_size", 0.6))
	_sel_quad = PlaneMesh.new()
	_sel_quad.size = Vector2(cell, cell)
	_sel_quad.orientation = PlaneMesh.FACE_Y
	var smat := ShaderMaterial.new()
	smat.shader = SELECTION_RING_SHADER
	smat.set_shader_parameter("albedo_tex", SpriteRes.selection_ring_texture())
	smat.set_shader_parameter("ring_color",
		ConfigRes.parse_color(cfg.str_val("render.selection_ring_color", "#3ddc5a")))
	_sel_mm = MultiMesh.new()
	_sel_mm.transform_format = MultiMesh.TRANSFORM_3D
	# ⚠️ `use_custom_data` 必须在 `instance_count` **之前**设（同 unit_flash 那条约束）
	_sel_mm.use_custom_data = true
	_sel_mm.mesh = _sel_quad
	_sel_mm.instance_count = 256
	_sel_node = MultiMeshInstance3D.new()
	_sel_node.name = "SelectionRings"
	_sel_node.multimesh = _sel_mm
	_sel_node.material_override = smat
	add_child(_sel_node)


## 取（或创建）一个变体的批次。
##
## ★ 变体键 = `阵营|是否将领|兵种|是否濒死`（见 `sync` 的拼法）；贴图按变体烘一张。
func _batch_for(key: String, faction: String, leader: bool, unit_type: String,
		downed: bool) -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var col: Color = cfg.faction_color(faction, "main")
	var outline: Color = Color(0.05, 0.05, 0.07, 1.0)
	# ★ 兵种素材（`unit.types.<id>.sprite`）+ 阵营色剪影；将领的描边更粗。
	#   素材缺失 / 没配 → `bake_asset` 内部退回程序化剪影（见 unit_sprite_3d.gd 的说明）。
	var tex: ImageTexture = SpriteRes.bake_asset(cfg.unit_sprite_of(unit_type), col, leader, outline)

	# ★★ 材质按「是否濒死」二选一：
	#   · 正常：flash shader（写 ALPHA + scissor ⇒ **不透明管线**、深度正确）；
	#   · 濒死：downed shader（写 ALPHA、不写 scissor ⇒ **透明管线**、整体半透明）。
	#   两者的 billboard 代码逐字一致，所以同一位将领站起来/倒下的朝向不会变。
	var mat := ShaderMaterial.new()
	mat.set_shader_parameter("albedo_tex", tex)
	if downed:
		mat.shader = UNIT_DOWNED_SHADER
		mat.set_shader_parameter("downed_alpha", cfg.num("render.downed_alpha", 0.4))
	else:
		mat.shader = UNIT_FLASH_SHADER
		mat.set_shader_parameter("scissor_threshold", 0.35)
		mat.set_shader_parameter("flash_strength", cfg.num("render.hit_flash_alpha", 0.8))

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _quad
	# ★⚠️ `use_custom_data` 必须在 `instance_count` **之前**设：
	#   实测（真渲染器）在 instance_count > 0 之后再打开它会报
	#   「Instance count must be 0 to toggle whether custom data is used」，
	#   于是自定义数据整批失效、闪白永远读不到。
	mm.use_custom_data = true
	mm.instance_count = 256

	var node := MultiMeshInstance3D.new()
	node.name = "Units_" + key
	node.multimesh = mm
	node.material_override = mat
	add_child(node)
	batches_created += 1
	# ★ `last_flash` 必须**逐批次**存（每个批次的 MultiMesh 是各自一份自定义数据缓冲）：
	#   共用一份全局缓存会在两个批次落在同一个下标时互相覆盖，把闪白**卡住**。
	var rec := {"node": node, "mm": mm, "faction": faction, "leader": leader, "last_flash": []}
	_batches[key] = rec
	return rec


## 每帧同步：把可见单位按变体分桶，逐桶写实例
##
## ★★ 两处**实测出来的**性能优化（1000 单位时 `_process` 占 36.6 ms）：
##   ① **位置没变就不重写 MultiMesh 实例**：待命单位占多数时（1000 个单位里
##      真正在动的可能只有几十个），省掉的是「每帧每单位一次
##      `set_instance_transform` + 一次 `to_world`」；
##   ② 分桶键用**预拼好的字符串**（`阵营|是否将领|兵种`）：每帧拼 1000 次
##      `"%s|%d" % [...]` 是纯浪费，改成按单位缓存（阵营不会变）。
##   ⚠️ 缓存必须**逐槽位**跟着实例下标走：实例下标每帧都可能变
##      （单位死亡 / 被迷雾挡住 → 桶里的顺序变了），所以缓存键要带下标。
##   ★ 判据：`bench_fps_3d.gd` 的 `_process` 分项 —— 优化前后对比。
var _last_pos: Array = []          # 下标 → 上一次写的世界位置（Vector3）
var _last_slot_key: Array = []     # 下标 → 上一次写的「桶键」（变了就必须重写）
func sync(dt: float = 1.0 / 60.0) -> void:
	if world == null or palette == null or _quad == null:
		return
	shake_applied_last_frame = 0
	flash_written_last_frame = 0
	downed_count = 0
	var buckets: Dictionary = {}
	for u in world.units:
		if not u.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方单位**一个实例都不占**（判据只在 logic/fog.gd）
		if not _visible_to_me(u):
			continue
		var leader: bool = u.is_general()
		var downed: bool = u.is_downed()
		# ★★ 变体键 = 阵营 | 是否将领 | 兵种 | 是否濒死：都会变，各自决定用哪张图 / 哪个材质。
		var key := "%s|%d|%s|%d" % [String(u.faction), 1 if leader else 0,
			String(u.unit_type), 1 if downed else 0]
		var arr: Array = buckets.get(key, [])
		arr.append(u)
		buckets[key] = arr

	var half_h: float = _quad.size.y * 0.5
	var total: int = 0
	var used: int = 0
	var wrote: int = 0
	for key in buckets.keys():
		var arr: Array = buckets[key]
		# ⚠️ `String.split()` 返回的是无类型 `PackedStringArray` 的元素 ⇒
		#    写 `var parts := key.split("|")` 没问题，但 `String(parts[0])` 之后的
		#    `var rec := _batch_for(...)` **不能**用 `:=`（返回值推不出类型）。
		#    本轮第四次踩同类坑：凡是无类型容器 / 无类型参数参与，都要显式标类型。
		var parts: PackedStringArray = key.split("|")
		var rec: Dictionary = _batch_for(key, String(parts[0]), int(parts[1]) == 1,
			String(parts[2]), int(parts[3]) == 1)
		var mm: MultiMesh = rec["mm"]
		var batch_downed: bool = int(parts[3]) == 1
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			var u = arr[i]
			if batch_downed:
				downed_count += 1
			var w: Vector3 = palette.to_world(u.pos)
			# ★ 受击左右振动（纯表现）：X 方向一个小位移，随 hit_flash 衰减
			if u.hit_flash > 0.0:
				w.x += HitFxRes.shake_tiles(u.hit_flash, _hit_amp, _hit_freq) * _cell
				shake_applied_last_frame += 1
			# 立牌原点在**中心** ⇒ 抬到「底边贴地」
			w.y = half_h
			# ★ 优化①：位置与所在批次都没变 ⇒ **跳过这次写入**
			#   （`set_instance_transform` 要走引擎调用，1000 次/帧是实打实的开销）
			var cached_pos: Variant = _last_pos[i] if i < _last_pos.size() else null
			var cached_key: Variant = _last_slot_key[i] if i < _last_slot_key.size() else null
			if cached_key == null or String(cached_key) != key or cached_pos == null \
					or (cached_pos as Vector3) != w:
				mm.set_instance_transform(i, Transform3D(Basis(), w))
				_slot_set(i, w, key)
				wrote += 1
			# ★ 受击闪白：写进**每实例自定义数据**（shader 读 INSTANCE_CUSTOM.r）。
			#   值没变就不写（待命单位占多数，每帧写 1000 次是白花）。
			var flash: float = clampf(u.hit_flash, 0.0, 1.0)
			var lf: Array = rec["last_flash"]
			var cf: Variant = lf[i] if i < lf.size() else null
			if cf == null or float(cf) != flash:
				mm.set_instance_custom_data(i, Color(flash, 0.0, 0.0, 0.0))
				while lf.size() <= i:
					lf.append(null)
				lf[i] = flash
				if flash > 0.0:
					flash_written_last_frame += 1
		mm.visible_instance_count = arr.size()
		(rec["node"] as MultiMeshInstance3D).visible = true
		total += arr.size()
		used += 1
	# 没有实例的批次要隐藏（否则残留上一帧的单位）
	for key in _batches.keys():
		if not buckets.has(key):
			var rec: Dictionary = _batches[key]
			(rec["mm"] as MultiMesh).visible_instance_count = 0
			(rec["node"] as MultiMeshInstance3D).visible = false
	instance_count = total
	visible_count = total
	mesh_batch_count = used
	instance_writes_last_frame = wrote
	_sync_decals()
	_sync_selection_rings(dt)


## 将领脚下的贴花：把每个**可见将领**摆一块平放的小面片（逐实例色 = 阵营色）。
##
## ★ 将领很少（个位数）⇒ 直接每帧重填，不需要脏检查。
## ★ 面片是 `PlaneMesh.FACE_Y`：本来就躺在 XZ 平面上 ⇒ **变换用单位基**（不旋转）。
func _sync_decals() -> void:
	decal_count = 0
	if _decal_node == null or _decal_mm == null or world == null or palette == null:
		return
	var n_generals: int = world.units.size()
	if _decal_mm.instance_count < n_generals:
		_decal_mm.instance_count = maxi(n_generals, _decal_mm.instance_count * 2)
	var i: int = 0
	for u in world.units:
		if not u.alive or not u.is_general():
			continue
		if not _visible_to_me(u):
			continue
		var w: Vector3 = palette.to_world(u.pos)
		w.y = 1.0                       # 贴在地面上方一点点（避免与地面 z-fighting）
		_decal_mm.set_instance_transform(i, Transform3D(Basis(), w))
		_decal_mm.set_instance_color(i, cfg.faction_color(String(u.faction), "main"))
		i += 1
	decal_count = i
	_decal_mm.visible_instance_count = i
	_decal_node.visible = i > 0


## ★★ 选中下标：被选中单位脚下的**绿色空心圆**，带「出现 / 收起」动效。
##
## 每个单位的进度 `p ∈ [0,1]` 朝目标（选中 = 1，未选中 = 0）按 `1/_sel_sec` 每秒推进：
##   · 尺寸 = `lerp(scale_from, 1.0, p)` —— 由 150% 收到 100%（= 将领黄色贴花那个大小）；
##   · 不透明度 = `_sel_alpha * p` —— 由 0 升到 80%。
## 取消选中时目标变 0，同一段插值就往回放（**反向动效**）；收到 0 就把这一项清掉。
func _sync_selection_rings(dt: float) -> void:
	selection_ring_count = 0
	selection_scale_last = 0.0
	selection_alpha_last = 0.0
	if _sel_node == null or _sel_mm == null or world == null or palette == null:
		return
	var rate: float = 1.0 / _sel_sec
	# 先清掉已经不在世界里的单位（阵亡 / 换局），免得进度表无限长大
	var stale: Array = []
	for id in _sel_anim.keys():
		if world.unit_by_id(String(id)) == null:
			stale.append(id)
	for id in stale:
		_sel_anim.erase(id)

	var n: int = world.units.size()
	if _sel_mm.instance_count < n:
		_sel_mm.instance_count = maxi(n, _sel_mm.instance_count * 2)
	var i: int = 0
	for u in world.units:
		if not u.alive or not _visible_to_me(u):
			continue
		var id := String(u.id)
		var want: float = 1.0 if _selection_set.has(id) else 0.0
		var p: float = float(_sel_anim.get(id, 0.0))
		if p < want:
			p = minf(want, p + rate * dt)
		elif p > want:
			p = maxf(want, p - rate * dt)
		if p <= 0.0001:
			_sel_anim.erase(id)
			continue
		_sel_anim[id] = p
		var w: Vector3 = palette.to_world(u.pos)
		w.y = 1.0
		var s: float = lerpf(_sel_scale_from, 1.0, p)
		_sel_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, 1.0, s)), w))
		_sel_mm.set_instance_custom_data(i, Color(_sel_alpha * p, 0.0, 0.0, 0.0))
		if i == 0:
			selection_scale_last = s
			selection_alpha_last = _sel_alpha * p
		i += 1
	selection_ring_count = i
	_sel_mm.visible_instance_count = i
	_sel_node.visible = i > 0


## 写一槽的缓存（下标越界时按需扩容）
func _slot_set(i: int, w: Vector3, key: String) -> void:
	while _last_pos.size() <= i:
		_last_pos.append(null)
		_last_slot_key.append(null)
	_last_pos[i] = w
	_last_slot_key[i] = key


func _visible_to_me(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


## 一个单位立牌在屏幕上的宽度（像素）——覆盖层的选中圈 / 血条用它对齐
##
## ★ 透视下这个值**随位置变化**（近大远小）⇒ 每帧按单位位置现算，
##   绝不要缓存成「一格 = 多少像素」（那正是老 2D 版会错的地方）。
func quad_screen_width(u) -> float:
	if palette == null:
		return 0.0
	var a: Vector2 = palette.to_px(u.pos + Vector2(-QUAD_W * 0.5, 0.0))
	var b: Vector2 = palette.to_px(u.pos + Vector2(QUAD_W * 0.5, 0.0))
	return a.distance_to(b)


func quad_screen_height(u) -> float:
	return quad_screen_width(u) * QUAD_H_RATIO


## 立牌**头顶**在屏幕上的位置（覆盖层放血条 / 字用）
func head_screen_pos(u) -> Vector2:
	if palette == null or palette.cam == null:
		return Vector2.ZERO
	var w: Vector3 = palette.to_world(u.pos)
	w.y = _quad.size.y
	return palette.cam.unproject_position(w)


## 选中集合（`game_scene3d` 每帧把 `_selected_ids()` 喂进来）。
##
## ★★ 3D 版据此画**脚下的绿色空心圆贴花**（见 `_sync_selection_rings`）——带出现/收起动效。
##   ⚠️ 这个方法**必须有**：`game_scene3d` 每帧调用它；缺了会抛 `Nonexistent function`
##   并**中断整个 `_process`**（实测过，见 pitfalls）。
var selected_ids: Array = []


func set_selection(ids: Array) -> void:
	selected_ids = ids
	_selection_set = {}
	for id in ids:
		_selection_set[String(id)] = true

## ★★ 「压扁档的补偿计数」在 3D 下**恒为 0**（保留是为了接口不破）。
##
## 为什么留着：`test_view` 里有一条按名字读它的断言。3D 下没有「压扁」这件事
## （世界是 y = 0 的真实平面、投影交给引擎），所以补偿次数必然是 0。
## ⚠️ 删掉它会抛 `Invalid access to property` 并**中断整段**（实测），
##    那比留一个恒为 0 的字段危险得多 —— 静默少跑断言比多一个无害字段糟。
var comp_group_count: int = 0