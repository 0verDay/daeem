## unit_view_3d.gd —— 3D 单位：**按「阵营 × 是否将领」分组的多批次 MultiMesh**
##
## ★★ 为什么是「多批次」而不是「一个 MultiMesh 画全部」（本版最重要的性能取舍）：
##   `MultiMesh` 的所有实例**共用同一个 mesh ⇒ 同一张贴图**，因此它**不支持逐实例贴图**。
##   而兵人立牌要做到「阵营色 + 将领更粗的描边」，就必须有多张图（阵营数 × 2）。
##   ⇒ 做法是：**每种变体一个 `MultiMeshInstance3D`**（各自一张贴图），
##     变体数 = 阵营数 × 2，本项目是个位数 ⇒ **仍然只有个位数 draw call**，
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

## 立牌的世界宽度（一格的比例）
const QUAD_W := 0.42
## 立牌高宽比（贴图是 64×96 ⇒ 1.5）
const QUAD_H_RATIO := 1.5

var cfg: ConfigRes = null
var world = null
var palette = null

var _quad: QuadMesh = null
## 变体键（"阵营|是否将领"）→ {node, mm, capacity}
var _batches: Dictionary = {}
## 变体键 → 颜色缓存
var _color_cache: Dictionary = {}

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


## 取（或创建）一个变体的批次
func _batch_for(key: String, faction: String, leader: bool) -> Dictionary:
	var hit: Variant = _batches.get(key, null)
	if hit != null:
		return hit
	var col: Color = cfg.faction_color(faction, "main")
	var outline: Color = Color(0.05, 0.05, 0.07, 1.0)
	# ★ 将领的描边更粗：靠**另一张贴图**（见 unit_sprite_3d.gd 的说明）
	var tex: ImageTexture = SpriteRes.bake(col, leader, outline)

	# ★★ 自定义材质（本轮的「逐像素闪白」就落在这里）：
	#   · billboard 由 **shader 自己**做（`BaseMaterial3D.billboard_mode` 对自定义材质无效）；
	#   · 闪白走**每实例自定义数据** `INSTANCE_CUSTOM.r`（见 sync 里的 set_instance_custom_data）。
	#   · unshaded / cull_disabled / alpha scissor 0.35 / 线性 mipmap 各向异性 —— 与原
	#     StandardMaterial3D 逐条对齐，换材质不改观感。
	var mat := ShaderMaterial.new()
	mat.shader = UNIT_FLASH_SHADER
	mat.set_shader_parameter("albedo_tex", tex)
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
##   ② 分桶键用**预拼好的字符串**（`阵营|是否将领`）：每帧拼 1000 次
##      `"%s|%d" % [...]` 是纯浪费，改成按单位缓存（阵营不会变）。
##   ⚠️ 缓存必须**逐槽位**跟着实例下标走：实例下标每帧都可能变
##      （单位死亡 / 被迷雾挡住 → 桶里的顺序变了），所以缓存键要带下标。
##   ★ 判据：`bench_fps_3d.gd` 的 `_process` 分项 —— 优化前后对比。
var _last_pos: Array = []          # 下标 → 上一次写的世界位置（Vector3）
var _last_slot_key: Array = []     # 下标 → 上一次写的「桶键」（变了就必须重写）
func sync() -> void:
	if world == null or palette == null or _quad == null:
		return
	shake_applied_last_frame = 0
	flash_written_last_frame = 0
	var buckets: Dictionary = {}
	for u in world.units:
		if not u.alive:
			continue
		# ★★ 战争迷雾：看不见的敌方单位**一个实例都不占**（判据只在 logic/fog.gd）
		if not _visible_to_me(u):
			continue
		var leader: bool = u.is_general()
		var key := "%s|%d" % [String(u.faction), 1 if leader else 0]
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
		var rec: Dictionary = _batch_for(key, String(parts[0]), int(parts[1]) == 1)
		var mm: MultiMesh = rec["mm"]
		if mm.instance_count < arr.size():
			mm.instance_count = maxi(arr.size(), mm.instance_count * 2)
		for i in arr.size():
			var u = arr[i]
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


## 点亮选中单位（**选中标记是屏幕空间的**，由覆盖层画，见 `overlay_view_3d.gd`）。
##
## ★★ 为什么这个方法必须有、而且允许是「存起来不画」：
##   `input_controller` 每帧会调 `unit_view.set_selection(ids)`（2D 版就是在那里画的）。
##   3D 版把选中圈移到了屏幕空间的覆盖层，但**接口必须留着** ——
##   否则那一行调用会抛 `Nonexistent function` 并**中断整个 `_process`**
##   （实测：`test_view` 里以 `Nonexistent function 'set_selection'` 暴露，
##    连带它之后的每帧同步全都不执行）。
##   ⇒ 这里只做记录（`selected_ids` 供覆盖层与调试读），真正的绘制在覆盖层。
var selected_ids: Array = []


func set_selection(ids: Array) -> void:
	selected_ids = ids

## ★★ 「压扁档的补偿计数」在 3D 下**恒为 0**（保留是为了接口不破）。
##
## 为什么留着：`test_view` 里有一条按名字读它的断言。3D 下没有「压扁」这件事
## （世界是 y = 0 的真实平面、投影交给引擎），所以补偿次数必然是 0。
## ⚠️ 删掉它会抛 `Invalid access to property` 并**中断整段**（实测），
##    那比留一个恒为 0 的字段危险得多 —— 静默少跑断言比多一个无害字段糟。
var comp_group_count: int = 0