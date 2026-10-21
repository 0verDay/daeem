## terrain_props_view.gd —— 地形装饰：**树 / 山块 / 水面**
##
## ★ 草地的建模已移除：草地只保留 `ground_view` 烘的平坦底色，不再生成任何 3D 草叶。
##   其余道具的摆放 / 迷雾 / 建筑占位 / 淡出逻辑不变。
##
## ★★ 这一层只做「让地块一眼能分辨」，不参与任何玩法：
##   · 只读 `world.map.terrain` / `world.fog` / `world.buildings`，不改逻辑、不发命令；
##   · 不进快照、没有碰撞、寻路完全不知道它存在。
##
## ★★ 为什么不是「每格建一个 Node3D」：
##   一张图最多几百个森林格、几百个山格。每格一个节点会在手机上换来几百次 draw call；
##   这里按**道具种类**各建一个 `MultiMeshInstance3D`
##   （树 / 树影 / 山 / 水 = +4 次），CPU 只在装配时摆一次。
##
## ★★ 模型与尺寸约定（与 `building_view_3d` 同一套）：
##   · `assets/models/*.glb` 里 **1 单位 = 1 格**、**底边在 y = 0**、原点在底面中心；
##   · 落地时统一乘 `palette.cell_size()` ⇒ 模型高度 0.96 ⇒ 实际高 0.96 格。
##   · 树 / 山块来自 Blender（`tree_lowpoly.glb` / `mountain_block_lowpoly.glb`），
##     水是每格一块方片，树底另有一层接地暗斑。
##
## ★★ 三个必须自己处理的坑（前两个是「地面那一套压不到道具」造成的）：
##   1. **迷雾**：`ground_view` 的迷雾平面在 y = 1.5，只压地面。道具高过它 ⇒
##      被迷雾盖住的树/山会**亮着**。这里按格把实例色乘 `fog_dim`（= 1 − 迷雾 alpha），
##      与地面被压暗的程度一致。⚠️ 不能直接把迷雾平面抬高：相机是透视的，
##      抬高之后迷雾的格子边会和地面格子错开（越远越明显）。
##   2. **建筑**：墙 / 箭塔**可以建在森林和草地上** ⇒ 树会跟建筑穿模。
##      这里每 `BUILDING_CHECK_FRAMES` 帧比一次建筑占位，占位格上的实例缩放到 0，
##      拆掉后恢复。地面重烘也是 15 帧一拍（见 `ground_view`），两边节奏一致。
##   3. **单位靠近**：树 / 山块要像建筑那样淡出（3×3 规则），但道具是几百个实例的
##      MultiMesh —— 直接写 ALPHA 会让整批进透明管线、树与树的遮挡乱掉；建筑那套
##      `depth_draw_always` 又会把后面的单位挡住。⇒ 拆成**不透明主批 + 淡出批**：
##      只有靠近单位的那几个实例搬到淡出批（不写深度、画在单位之前）。
##      见 `_apply_fade()` 与 `view/terrain_props_fade.gdshader`。
##
## ★ 摆放全部由 `_hash01(gx, gy, salt)` 与全局网格间距决定：同一张图每次进都是同一个样子，
##   不会「重新加载就换一片树林」，也方便测试断言数量。★ 树是**全局撒**的，
##   不按格中心摆 ⇒ 没有一格为周期的重复。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const FactionRes = preload("res://logic/faction.gd")

const PROP_SHADER = preload("res://view/terrain_props.gdshader")
const FADE_SHADER = preload("res://view/terrain_props_fade.gdshader")
const WATER_SHADER = preload("res://view/terrain_water.gdshader")
const SHADOW_SHADER = preload("res://view/terrain_shadow.gdshader")

## 树 / 山块的模型（Blender 导出；1 单位 = 1 格、底边 y = 0）
const TREE_MODEL := "res://assets/models/tree_lowpoly.glb"
const MOUNTAIN_MODEL := "res://assets/models/mountain_block_lowpoly.glb"

## 建筑占位检查的节拍（帧）。与 `ground_view` 的 15 帧一次同频。
const BUILDING_CHECK_FRAMES := 15

## 一批道具（一个 MultiMesh + 它的逐实例基础变换）
##
## ★ `bases` 存**未被建筑藏起来**的原始变换：建筑拆掉时要按它恢复。
class Batch:
	var mmi: MultiMeshInstance3D = null
	var mm: MultiMesh = null
	## ★ 淡出层：同一批实例的“靠近单位”副本。正常时全部缩放到 0；
	##   某实例需要淡出时，主批里缩 0、这里按原变换出现（半透明、不写深度）。
	var fade_mm: MultiMesh = null
	var fade_mmi: MultiMeshInstance3D = null
	var has_fade: bool = false
	var faded: PackedByteArray = PackedByteArray()
	var tiles: PackedInt32Array = PackedInt32Array()
	var bases: Array[Transform3D] = []
	var hidden: PackedByteArray = PackedByteArray()
	## 上一次写入的「看得见」状态（1 = 亮，0 = 被迷雾压暗，2 = 还没写过）。
	## ★ 只改真的翻转的实例：单位走动时通常只有十几格的可见性变化。
	var visible: PackedByteArray = PackedByteArray()
	## 逐实例色调（乘在顶点色上）：打散「同一批模型一模一样」的感觉。
	var tints: PackedColorArray = PackedColorArray()
	var hide_on_build: bool = true
	## 是否参与迷雾压暗（接地阴影不参与：黑斑再压黑没有意义）
	var receives_fog: bool = true

var cfg: ConfigRes = null
var world = null
var palette = null

## 诊断：各批次的实例数（测试 / 排查读它，别去反推网格）
var built_counts: Dictionary = {}

var _enabled: bool = true
var _cell: float = 128.0
var _cols: int = 0
var _rows: int = 0
var _frame: int = 0

## ---- 参数（全部来自 config.json 的 render.terrain_props.*）----
## 树：按格全局撒，允许向林缘外溢 `tree_spill_tiles` 格
var _tree_spacing: float = 0.50
var _tree_scale: float = 0.78
var _tree_density: float = 0.95
var _tree_spill_tiles: float = 0.35
var _mountain_scale: float = 1.0
var _water_lift: float = 2.0
var _water_color: Color = Color(0.24, 0.52, 0.68, 0.55)
var _fog_dim: float = 0.55
## 接地暗斑的浓度（0 = 关掉）
var _shadow_alpha: float = 0.34
## 单位靠近时，树 / 山块淡到的不透明度（与建筑的 render.building_fade_alpha 同一口径）
var _fade_alpha: float = 0.30

var _prop_mat: ShaderMaterial = null
var _fade_mat: ShaderMaterial = null
var _water_mat: ShaderMaterial = null
var _shadow_mat: ShaderMaterial = null
var _batches: Array[Batch] = []
## 树的落点（阴影层要用同一批位置）与所属格
var _tree_spots: Array[Transform3D] = []
var _tree_tiles: PackedInt32Array = PackedInt32Array()

## 迷雾快照：不为空 ⇒ 「上一次已经按这份掩码画过」
var _fog_mask: PackedByteArray = PackedByteArray()
var _fog_side: String = ""
## 上一次是否处于「迷雾关闭」状态（关掉时要一次性把所有实例恢复成亮色）
var _fog_was_off: bool = false


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	if world == null or world.map == null or palette == null:
		push_error("terrain_props_view：world / map / palette 为空，装饰层不建")
		return
	_enabled = cfg.bool_val("render.terrain_props.enabled", true)
	if not _enabled:
		set_process(false)
		return

	_cell = palette.cell_size()
	_cols = int(world.map.cols)
	_rows = int(world.map.rows)
	_read_params()

	_prop_mat = ShaderMaterial.new()
	_prop_mat.shader = PROP_SHADER
	# 淡出层：画在**单位之前**（render_priority 更小），且不写深度 ⇒ 单位始终叠在它上面。
	# 见 view/terrain_props_fade.gdshader 的文件头。
	_fade_mat = ShaderMaterial.new()
	_fade_mat.shader = FADE_SHADER
	_fade_mat.set_shader_parameter("fade_alpha", _fade_alpha)
	_fade_mat.render_priority = -1
	_water_mat = ShaderMaterial.new()
	_water_mat.shader = WATER_SHADER
	_water_mat.set_shader_parameter("water_color", _water_color)
	_shadow_mat = ShaderMaterial.new()
	_shadow_mat.shader = SHADOW_SHADER
	_shadow_mat.set_shader_parameter("shadow_color", Color(0.0, 0.0, 0.0, _shadow_alpha))

	# 顺序：树 → 阴影（阴影要复用树的落点）→ 山 → 水
	_build_trees()
	_build_tree_shadows()
	_build_mountains()
	_build_water()

	_refresh_buildings()
	_apply_fog(true)
	_apply_fade()


func _read_params() -> void:
	_tree_spacing = clampf(cfg.num("render.terrain_props.tree_spacing", 0.50), 0.2, 3.0)
	_tree_scale = maxf(0.1, cfg.num("render.terrain_props.tree_scale", 0.78))
	_tree_density = clampf(cfg.num("render.terrain_props.tree_density", 0.95), 0.0, 1.0)
	_tree_spill_tiles = clampf(cfg.num("render.terrain_props.tree_spill_tiles", 0.35), 0.0, 0.8)
	_mountain_scale = clampf(cfg.num("render.terrain_props.mountain_scale", 1.0), 0.2, 2.0)
	_water_lift = cfg.num("render.terrain_props.water_lift", 2.0)
	_water_color = _parse_color(cfg.str_val("render.terrain_props.water_color", "#3d84ad"), Color(0.24, 0.52, 0.68))
	_water_color.a = clampf(cfg.num("render.terrain_props.water_alpha", 0.55), 0.0, 1.0)
	_fog_dim = clampf(cfg.num("render.terrain_props.fog_dim", 0.55), 0.0, 1.0)
	_shadow_alpha = clampf(cfg.num("render.terrain_props.shadow_alpha", 0.34), 0.0, 0.8)
	_fade_alpha = clampf(cfg.num("render.terrain_props.fade_alpha", 0.30), 0.0, 1.0)


static func _parse_color(text: String, fallback: Color) -> Color:
	return ConfigRes.parse_color(text, fallback)


func _process(_dt: float) -> void:
	if not _enabled or world == null:
		return
	_frame += 1
	_apply_fog(false)
	_apply_fade()
	if _frame % BUILDING_CHECK_FRAMES == 0:
		_refresh_buildings()


# ------------------------------------------------------------------
# 生成
# ------------------------------------------------------------------

## 草：**已移除**。草地不再生成任何草簇网格，只保留 `ground_view` 的平坦底色。
##   原来的逐格 / 全局撒簇逻辑（含 `grass_spacing` 等参数）一并删掉，
##   避免「参数还在、但没人读」的假开关。
##
## 树：**全局撒**，并且允许往林缘外的草地上溢 `tree_spill_tiles` 格。
##
## ★ 为什么（本轮重做）：原来「每格 3–4 棵、都落在格心附近」⇒ 树林边界是一刀切的矩形，
##   格内还挤成 4 棵一团。改成按 `tree_spacing` 的全局抖动网格撒：
##   树的间距与格边无关，林缘会自然过渡到草地上；每格约 2–3 棵。
##
## ★ 只允许长在森林格、或森林边缘 `tree_spill_tiles` 内的草地格；
##   水 / 山 / 地图外的点直接跳过（否则树会站在水里）。
func _build_trees() -> void:
	var mesh := _load_model_mesh(TREE_MODEL)
	if mesh == null:
		return
	var xforms: Array[Transform3D] = []
	var tints := PackedColorArray()
	var step: float = maxf(0.2, _tree_spacing)
	var nx: int = int(ceil(float(_cols) / step))
	var ny: int = int(ceil(float(_rows) / step))
	for gy in ny:
		for gx in nx:
			var px: float = (float(gx) + 0.5) * step + (_hash01(gx, gy, 51) - 0.5) * step * 0.8
			var py: float = (float(gy) + 0.5) * step + (_hash01(gx, gy, 52) - 0.5) * step * 0.8
			if px < 0.0 or py < 0.0 or px >= float(_cols) or py >= float(_rows):
				continue
			if _hash01(gx, gy, 53) > _tree_density:
				continue
			if not _near_kind(px, py, "forest", _tree_spill_tiles):
				continue
			var tx: int = int(px)
			var ty: int = int(py)
			var kind := String(world.map.terrain.get_cell(tx, ty)) \
				if world.map.terrain.has(tx, ty) else ""
			if kind == "water" or kind == "mountain":
				continue
			if not world.map.tile_exists(tx, ty):
				continue
			var s: float = _cell * _tree_scale * lerpf(0.85, 1.15, _hash01(gx, gy, 54))
			var yaw: float = TAU * _hash01(gx, gy, 55)
			var k: float = lerpf(0.86, 1.10, _hash01(gx, gy, 56))
			var pos: Vector3 = palette.to_world(Vector2(px, py))
			var xf := Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), pos)
			xforms.append(xf)
			_tree_spots.append(xf)
			_tree_tiles.append(ty * _cols + tx)
			tints.append(Color(minf(k * 0.95, 1.0), minf(k, 1.0), minf(k * 0.93, 1.0), 1.0))
	_make_batch("TreeProps", mesh, _prop_mat, xforms, _tree_tiles, true, "tree", tints, true, true)


## 树底的接地暗斑。位置 / 大小跟着树走；建筑占位时和树一起消失（同一个格）。
func _build_tree_shadows() -> void:
	if _shadow_alpha <= 0.0 or _tree_spots.is_empty():
		return
	var xforms: Array[Transform3D] = []
	for t in _tree_spots:
		var s: float = t.basis.get_scale().x
		xforms.append(Transform3D(
			Basis.from_scale(Vector3(s * 0.95, 1.0, s * 0.95)),
			t.origin + Vector3(0.0, 0.6, 0.0)))
	_make_batch("TreeShadows", _make_shadow_mesh(), _shadow_mat,
		xforms, _tree_tiles, true, "shadow", PackedColorArray(), false)


## 这个点周围 `extra` 格内有没有 `kind` 地形（用于树的林缘外溢）。
func _near_kind(px: float, py: float, kind: String, extra: float) -> bool:
	var tx: int = int(floor(px))
	var ty: int = int(floor(py))
	var r: float = 0.5 + extra
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if not _is_kind(tx + dx, ty + dy, kind):
				continue
			var cx: float = float(tx + dx) + 0.5
			var cy: float = float(ty + dy) + 0.5
			if (px - cx) * (px - cx) + (py - cy) * (py - cy) <= r * r:
				return true
	return false


## 山：**每格一个方块，铺满整格**（用户口径）。
##
## ★ 不抖动、不旋转、统一尺寸 ⇒ 相邻山格会拼成一堵连续的方块墙，边界清晰；
##   方块自带 0.035 的倒角，接缝处会有一条细沟，不会糊成一整块。
##
## ★ `mountain_scale` **只压高度**（XZ 仍然铺满整格）：嫌方块挡视线时调它，
##   不用重导模型、也不会在格与格之间留下缝。
func _build_mountains() -> void:
	var mesh := _load_model_mesh(MOUNTAIN_MODEL)
	if mesh == null:
		return
	var xforms: Array[Transform3D] = []
	var tiles := PackedInt32Array()
	for ty in _rows:
		for tx in _cols:
			if not _is_kind(tx, ty, "mountain"):
				continue
			var pos: Vector3 = palette.to_world(Vector2(float(tx) + 0.5, float(ty) + 0.5))
			xforms.append(Transform3D(
				Basis.from_scale(Vector3(_cell, _cell * _mountain_scale, _cell)), pos))
			tiles.append(ty * _cols + tx)
	_make_batch("MountainProps", mesh, _prop_mat, xforms, tiles, false, "mountain",
		PackedColorArray(), true, true)


## 水：每格一块方片，抬高 `water_lift` 个世界单位。
##
## ★ 网格是 0..1 的方片，实例把 XZ 缩放到格宽、Y 保持 1（高度为 0），
##   再靠实例位置的 y 抬高 —— 这样 `water_lift` 是**世界单位**，不会跟着格宽再乘一次。
func _build_water() -> void:
	var mesh := _make_water_mesh()
	if mesh == null:
		return
	var xforms: Array[Transform3D] = []
	var tiles := PackedInt32Array()
	for ty in _rows:
		for tx in _cols:
			if not _is_kind(tx, ty, "water"):
				continue
			var xf := Transform3D(
				Basis.from_scale(Vector3(_cell, 1.0, _cell)),
				Vector3(float(tx) * _cell, _water_lift, float(ty) * _cell))
			xforms.append(xf)
			tiles.append(ty * _cols + tx)
	_make_batch("WaterProps", mesh, _water_mat, xforms, tiles, false, "water")


func _make_batch(batch_name: String, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], tiles: PackedInt32Array,
		hide_on_build: bool, kind: String,
		tints: PackedColorArray = PackedColorArray(),
		receives_fog: bool = true,
		with_fade: bool = false) -> Batch:
	built_counts[kind] = xforms.size()
	if xforms.is_empty():
		return null
	if tints.size() != xforms.size():
		tints.resize(xforms.size())
		tints.fill(Color.WHITE)
	var b := Batch.new()
	b.hide_on_build = hide_on_build
	b.receives_fog = receives_fog
	b.has_fade = with_fade
	b.tiles = tiles
	b.bases = xforms
	b.tints = tints
	b.hidden.resize(xforms.size())
	b.hidden.fill(0)
	b.faded.resize(xforms.size())
	b.faded.fill(0)
	b.visible.resize(xforms.size())
	b.visible.fill(2)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		# 初始 = 逐株色调（迷雾变化时再乘压暗系数）
		mm.set_instance_custom_data(i, tints[i])
	b.mm = mm

	var mmi := MultiMeshInstance3D.new()
	mmi.name = batch_name
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ★ 显式给一个整张图的包围盒：MultiMesh 的实例变换是我们自己写的，
	#   不希望视锥剔除依赖引擎有没有及时重算 AABB（漏算会表现为「转个视角道具消失」）。
	mmi.custom_aabb = AABB(
		Vector3.ZERO,
		Vector3(float(_cols) * _cell, _cell * 2.0, float(_rows) * _cell))
	add_child(mmi)
	b.mmi = mmi

	# ★ 淡出层：同一批实例的副本，正常全部缩到 0；`_apply_fade` 把靠近单位的那些搬过来。
	#   它走透明管线（不写深度、render_priority 更小）⇒ 单位永远画在它上面。
	if with_fade:
		var fmm := MultiMesh.new()
		fmm.transform_format = MultiMesh.TRANSFORM_3D
		fmm.use_custom_data = true
		fmm.mesh = mesh
		fmm.instance_count = xforms.size()
		for i in xforms.size():
			fmm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), xforms[i].origin))
			fmm.set_instance_custom_data(i, tints[i])
		var fmmi := MultiMeshInstance3D.new()
		fmmi.name = batch_name + "Fade"
		fmmi.multimesh = fmm
		fmmi.material_override = _fade_mat
		fmmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fmmi.custom_aabb = mmi.custom_aabb
		add_child(fmmi)
		b.fade_mm = fmm
		b.fade_mmi = fmmi

	_batches.append(b)
	return b


func _make_water_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_normal(Vector3.UP)
	st.set_color(Color.WHITE)
	st.add_vertex(Vector3(0.0, 0.0, 0.0))
	st.add_vertex(Vector3(1.0, 0.0, 0.0))
	st.add_vertex(Vector3(1.0, 0.0, 1.0))
	st.add_vertex(Vector3(0.0, 0.0, 0.0))
	st.add_vertex(Vector3(1.0, 0.0, 1.0))
	st.add_vertex(Vector3(0.0, 0.0, 1.0))
	return st.commit()


## 接地暗斑的网格：以原点为中心的 1×1 方片，带 0..1 的 UV（shader 按 UV 距离算圆形）。
func _make_shadow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners: Array[Vector3] = [
		Vector3(-0.5, 0.0, -0.5), Vector3(0.5, 0.0, -0.5),
		Vector3(0.5, 0.0, 0.5), Vector3(-0.5, 0.0, 0.5),
	]
	var uvs: Array[Vector2] = [
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
	]
	for idx in [0, 1, 2, 0, 2, 3]:
		st.set_normal(Vector3.UP)
		st.set_color(Color.WHITE)
		st.set_uv(uvs[idx])
		st.add_vertex(corners[idx])
	return st.commit()


# ------------------------------------------------------------------
# glb 合并（与 building_view_3d 同一条思路：所有 MeshInstance 合成一个网格）
# ------------------------------------------------------------------
##
## ★★ 为什么不「取第一个网格」：Blender 里的树是**树干 + 两层树冠**三个物体，
##   glb 会带成多个 primitive。取一个只会剩下零件（这是本项目踩过的坑）。
##   ⇒ 全部按各自节点变换合并，再把每个面的基色写成顶点色。
##
## ★ 颜色来源：优先用 glb 自带的 `COLOR_0`（Blender 里已经按材质烘好）；
##   没有的话退回该面的材质 `albedo_color` —— 这样模型即使没导顶点色也能看。
func _load_model_mesh(path: String) -> Mesh:
	if not ResourceLoader.exists(path):
		push_error("地形道具模型不存在：%s（确认已放在 assets/models 并导入）" % path)
		return null
	var res: Variant = load(path)
	if not (res is PackedScene):
		push_error("地形道具模型不是 PackedScene：%s" % path)
		return null
	var inst: Node = (res as PackedScene).instantiate()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tris: int = _append_node_meshes(inst, Transform3D.IDENTITY, st)
	inst.free()
	if tris <= 0:
		push_error("地形道具模型里没有可用的网格：%s" % path)
		return null
	return st.commit()


func _append_node_meshes(node: Node, parent_xf: Transform3D, st: SurfaceTool) -> int:
	var here: Transform3D = parent_xf * node.transform
	var tris: int = 0
	if node is MeshInstance3D:
		var m: Mesh = (node as MeshInstance3D).mesh
		if m != null:
			tris += _append_mesh(m, here, st)
	for ch in node.get_children():
		tris += _append_node_meshes(ch, here, st)
	return tris


func _append_mesh(mesh: Mesh, xform: Transform3D, st: SurfaceTool) -> int:
	var nm: Basis = xform.basis.inverse().transposed()
	var tris: int = 0
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var norms_v: Variant = arrays[Mesh.ARRAY_NORMAL]
		var norms: PackedVector3Array = norms_v if norms_v is PackedVector3Array else PackedVector3Array()
		var cols_v: Variant = arrays[Mesh.ARRAY_COLOR]
		var cols: PackedColorArray = cols_v if cols_v is PackedColorArray else PackedColorArray()
		var idx_v: Variant = arrays[Mesh.ARRAY_INDEX]
		var idx: PackedInt32Array = idx_v if idx_v is PackedInt32Array else PackedInt32Array()

		var fallback := Color.WHITE
		var mat: Material = mesh.surface_get_material(s)
		if mat is BaseMaterial3D:
			fallback = (mat as BaseMaterial3D).albedo_color

		var n: int = idx.size() if idx.size() > 0 else verts.size()
		for k in n:
			var vi: int = idx[k] if idx.size() > 0 else k
			if vi < 0 or vi >= verts.size():
				continue
			st.set_color(cols[vi] if cols.size() > vi else fallback)
			var nrm: Vector3 = Vector3.UP
			if norms.size() > vi:
				nrm = (nm * norms[vi]).normalized()
			st.set_normal(nrm)
			st.add_vertex(xform * verts[vi])
		tris += n / 3
	return tris


# ------------------------------------------------------------------
# 迷雾：按格乘实例色
# ------------------------------------------------------------------

## `force = true` 用于装配 / 迷雾开关切换；平时只在掩码真的变了时重刷。
func _apply_fog(force: bool = false) -> void:
	if world == null:
		return
	var fog_on: bool = cfg != null and cfg.fog_enabled and world.fog != null
	if not fog_on:
		if _fog_was_off and not force:
			return
		_fog_was_off = true
		_fog_mask = PackedByteArray()
		_fog_side = ""
		_set_all_instances_visible()
		return
	_fog_was_off = false
	var side := FactionRes.side_of(String(world.my_faction))
	var mask_v: Variant = world.fog.sight.get(side, PackedByteArray())
	var mask: PackedByteArray = mask_v if mask_v is PackedByteArray else PackedByteArray()
	if not force and side == _fog_side and mask == _fog_mask:
		return
	_fog_side = side
	_fog_mask = mask.duplicate()

	for b in _batches:
		if not b.receives_fog:
			continue
		for i in b.tiles.size():
			var t: int = b.tiles[i]
			var tx: int = t % _cols
			var ty: int = t / _cols
			var seen: bool = world.fog.tile_visible(world.my_faction, tx, ty)
			if not world.map.tile_exists(tx, ty):
				seen = true
			var want: int = 1 if seen else 0
			if b.visible[i] == want:
				continue
			b.visible[i] = want
			var tint: Color = b.tints[i]
			var d: float = 1.0 if seen else _fog_dim
			_set_batch_custom_data(b, i, Color(tint.r * d, tint.g * d, tint.b * d, 1.0))


func _set_all_instances_visible() -> void:
	for b in _batches:
		if not b.receives_fog:
			continue
		for i in b.tiles.size():
			if b.visible[i] == 1:
				continue
			b.visible[i] = 1
			_set_batch_custom_data(b, i, b.tints[i])


## 主批 + 淡出批要写**同一份**逐实例色（色调 × 迷雾压暗），否则淡出时会闪一下颜色。
func _set_batch_custom_data(b: Batch, i: int, c: Color) -> void:
	b.mm.set_instance_custom_data(i, c)
	if b.has_fade:
		b.fade_mm.set_instance_custom_data(i, c)


# ------------------------------------------------------------------
# 建筑占位：占位格上的草/树缩到 0，拆掉恢复
# ------------------------------------------------------------------

func _refresh_buildings() -> void:
	if world == null or world.buildings == null:
		return
	for b in _batches:
		if not b.hide_on_build:
			continue
		for i in b.tiles.size():
			var t: int = b.tiles[i]
			var tx: int = t % _cols
			var ty: int = t / _cols
			var want: int = 1 if PathfinderRes.occupied(world.buildings, tx, ty) else 0
			if b.hidden[i] == want:
				continue
			b.hidden[i] = want
			_apply_instance_state(b, i)


# ------------------------------------------------------------------
# 单位靠近 ⇒ 树 / 山块淡出（与建筑同一条 3×3 规则）
# ------------------------------------------------------------------
##
## ★ 为什么是「搬到另一批」而不是直接改 ALPHA：
##   主批是几百个实例的 MultiMesh，写 ALPHA 会让整批进透明管线、树与树的遮挡乱掉；
##   而建筑那套 `depth_draw_always` 又会让淡出的树**挡住后面的单位**。
##   ⇒ 正常实例留在不透明主批；只有靠近单位的那几个搬到“淡出批”
##     （透明、不写深度、render_priority 更小 ⇒ 画在单位之前）。
##
## ★ 规则与建筑完全一致：**自己所在格的 3×3 内有可见单位**就淡出。
##   只算「我这边看得见」的单位 —— 迷雾里的敌人不该让树淡出（会漏位置）。

## 外部喂进来的「可见单位所在格」（与 building_view_3d 同一份，来自 unit_view_3d）。
## ★ null = 没人喂 ⇒ 自己扫一遍 world.units（测试 / 独立使用时不破）。
var _provided_marked = null


func set_fade_marked(m: Variant) -> void:
	_provided_marked = m


## 每帧重算：哪些格上有「我这边的可见单位」。
func _fade_marked_tiles() -> Dictionary:
	if _provided_marked != null:
		var provided: Variant = _provided_marked
		_provided_marked = null        # 只消费一次，避免读到上一帧的旧值
		return provided
	var marked: Dictionary = {}
	if world == null:
		return marked
	for u in world.units:
		if not u.alive:
			continue
		if not _unit_visible(u):
			continue
		marked[Vector2i(u.tx, u.ty)] = true
	return marked


## 一个实例的目标状态：主批（不透明）/ 淡出批 / 都不画（被建筑占位）。
## ★ `hidden` 与 `faded` 会同时变，所以统一从这里落到两批 MultiMesh 上。
func _apply_instance_state(b: Batch, i: int) -> void:
	var base: Transform3D = b.bases[i]
	var hidden: bool = b.hidden[i] != 0
	var faded: bool = b.faded[i] != 0
	var zero := Transform3D(Basis().scaled(Vector3.ZERO), base.origin)
	if hidden:
		b.mm.set_instance_transform(i, zero)
		if b.has_fade:
			b.fade_mm.set_instance_transform(i, zero)
	elif faded and b.has_fade:
		b.mm.set_instance_transform(i, zero)
		b.fade_mm.set_instance_transform(i, base)
	else:
		b.mm.set_instance_transform(i, base)
		if b.has_fade:
			b.fade_mm.set_instance_transform(i, zero)


## 每帧：3×3 内有可见单位的树 / 山块搬到淡出批，其余回主批。
func _apply_fade() -> void:
	var marked: Dictionary = _fade_marked_tiles()
	for b in _batches:
		if not b.has_fade:
			continue
		for i in b.tiles.size():
			var t: int = b.tiles[i]
			var tx: int = t % _cols
			var ty: int = t / _cols
			var near: bool = false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if marked.has(Vector2i(tx + dx, ty + dy)):
						near = true
						break
				if near:
					break
			var want: int = 1 if near else 0
			if b.faded[i] == want:
				continue
			b.faded[i] = want
			_apply_instance_state(b, i)


## 单位对「我这边」可不可见（与 building_view_3d 同一条判据）。
func _unit_visible(u) -> bool:
	if world == null or world.fog == null or cfg == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

func _is_kind(tx: int, ty: int, kind: String) -> bool:
	if not world.map.tile_exists(tx, ty):
		return false
	return world.map.terrain.has(tx, ty) and String(world.map.terrain.get_cell(tx, ty)) == kind


## 确定性哈希 → [0, 1]。同一个 (tx, ty, salt) 永远同一个数。
static func _hash01(x: int, y: int, salt: int) -> float:
	var h: int = x * 374761393 + y * 668265263 + salt * 1442695041
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0x7FFFFFFF) / float(0x7FFFFFFF)
