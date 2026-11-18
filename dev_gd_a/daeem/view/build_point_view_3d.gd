## build_point_view_3d.gd —— 可建造点位的**地面碎石/断木指示物**（纯表现，2026.11.18）
##
## 需求：
##   · 每个可建造点位铺一小堆碎石 / 断木（Blender 导出的 `build_point_lowpoly.glb`，约 0.58 格）；
##   · **常驻淡显**：平时就能看出「这里能建」，但不抢建筑与单位的注意力；
##   · **拖建筑牌时高亮**：同一堆碎石换成暖金自发光 + 放大 1.14 倍（不呼吸），
##     配合 overlay 已有的地块框 / 圈。
##
## 只画**己方区划里、当前空着（没有建筑）**的点位：
##   · 敌方 / 中立区划的点位不能建，画出来只会误导；
##   · 点位被建筑占用后不再画（那已经不是「可建造」点位了）。
##
## ★ 为什么用 MeshInstance3D 池而不是 MultiMesh：
##   实测 MultiMesh 画这个 GLB 时只出来一小块（同一个网格换成 MeshInstance3D 就完整），
##   而点位数量级只是「区划数 × 2」—— 几十个 draw call 换来「模型真的完整」更划算。
extends Node3D

const BuildPointModelPath := "res://assets/models/build_point_lowpoly.glb"

## 常驻模型的高度余量：贴地但不与地面 z-fighting。
const GROUND_LIFT := 0.02
## 高亮放大倍数（用户口径：换色 + 放大，不呼吸）。
const HIGHLIGHT_SCALE := 1.14
## 常驻批次压暗多少 —— 「淡显」，不是直接藏起来（0.82 仍能在深绿草地上看出石头）。
const BASE_DIM := Color(0.82, 0.82, 0.80, 1.0)
## 高亮批次的自发光：用**暖金**（不是绿）—— 草地本身是绿的，绿高亮会糊成一片；
## 金也与右下建造页签 / 选中金边同一套语义。
const HIGHLIGHT_EMISSION := Color(1.0, 0.62, 0.12, 1.0)
const HIGHLIGHT_EMISSION_ENERGY := 1.0

var cfg = null
var world = null
var palette = null
var buildings = null

var _mesh: Mesh = null
var _base_root: Node3D = null
var _hi_root: Node3D = null
var _base_mat: StandardMaterial3D = null
var _hi_mat: StandardMaterial3D = null
var _base_items: Array[MeshInstance3D] = []
var _hi_items: Array[MeshInstance3D] = []
## 诊断（测试读）：本帧画了几个常驻点 / 几个高亮。
var base_count: int = 0
var hi_count: int = 0
## 最近一次高亮的格子（诊断用）。
var highlighted_tiles: Array = []


func setup(p_cfg, p_world, p_palette, p_buildings = null) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	buildings = p_buildings
	_mesh = _load_mesh(BuildPointModelPath)
	_base_mat = StandardMaterial3D.new()
	# ★ 指示物用 unshaded：它是一层「地图标记」，不该被太阳 / 建筑阴影吃掉。
	_base_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_base_mat.vertex_color_use_as_albedo = true
	_base_mat.albedo_color = BASE_DIM
	_base_mat.roughness = 1.0
	_base_mat.metallic = 0.0
	_base_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_hi_mat = StandardMaterial3D.new()
	# ★ 高亮要的是「自发光」：走正常光照 + emission（unshaded 会忽略 emission）。
	#   不乘顶点色：石头的灰 / 木头的棕会把金色压暗，远看和常驻没区别。
	_hi_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	_hi_mat.vertex_color_use_as_albedo = false
	_hi_mat.albedo_color = Color(0.18, 0.12, 0.04, 1.0)
	_hi_mat.roughness = 0.85
	_hi_mat.emission_enabled = true
	_hi_mat.emission = HIGHLIGHT_EMISSION
	_hi_mat.emission_energy_multiplier = HIGHLIGHT_EMISSION_ENERGY
	_hi_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_base_root = Node3D.new()
	_base_root.name = "BuildPointBase"
	add_child(_base_root)
	_hi_root = Node3D.new()
	_hi_root.name = "BuildPointHighlight"
	add_child(_hi_root)
	_base_items = []
	_hi_items = []
	base_count = 0
	hi_count = 0
	highlighted_tiles = []


## 从 GLB 里取第一个 MeshInstance3D 的网格（资产只有一个合并网格）。
func _load_mesh(path: String) -> Mesh:
	var res: Variant = load(path)
	if res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		var mi := _first_mesh_instance(inst)
		var m: Mesh = mi.mesh if mi != null else null
		inst.free()
		if m != null:
			return m
	push_error("建造点位模型加载失败：%s" % path)
	return null


func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node as MeshInstance3D
	for ch in node.get_children():
		var found := _first_mesh_instance(ch)
		if found != null:
			return found
	return null


## 每帧同步：先列「己方区划里空着的点位」，再把拖牌锚点里属于点位的那些高亮。
## @param drag_kind  "build" 时才高亮（招募将领没有点位）
## @param drag_tiles 拖牌锚点格（`hud.drag_anchor_tiles`）
func sync(drag_kind: String = "", drag_tiles: Array = []) -> void:
	if _mesh == null or _base_root == null or world == null or palette == null:
		return
	var faction := String(world.my_faction)
	var tiles: Array[Vector2i] = []
	for z in world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != faction:
			continue
		for p in (zd.get("build_points", []) as Array):
			var t: Vector2i = p
			if t.x < 0 or t.y < 0:
				continue
			# 已被建筑占用 / 地形不可建 / 区划正在被占领 / 演出边界外 ⇒ 不再画。
			if not world.build_point_available(t.x, t.y, faction):
				continue
			tiles.append(t)

	var hi_tiles: Array[Vector2i] = []
	if drag_kind == "build" and not drag_tiles.is_empty():
		var wanted: Dictionary = {}
		for d in drag_tiles:
			if typeof(d) == TYPE_VECTOR2I:
				wanted[d] = true
			elif typeof(d) == TYPE_DICTIONARY:
				var dt: Variant = (d as Dictionary).get("tile", null)
				if typeof(dt) == TYPE_VECTOR2I:
					wanted[dt] = true
		for t in tiles:
			if wanted.has(t):
				hi_tiles.append(t)
	# 锚点可能包含城墙中心（不是建造点位）：那些不画碎石，高亮由城墙虚影负责。
	base_count = tiles.size()
	hi_count = hi_tiles.size()
	highlighted_tiles = hi_tiles.duplicate()
	_fill(_base_items, _base_root, _base_mat, tiles, 1.0, GROUND_LIFT)
	_fill(_hi_items, _hi_root, _hi_mat, hi_tiles, HIGHLIGHT_SCALE, GROUND_LIFT + 0.01)
	_base_root.visible = base_count > 0
	_hi_root.visible = hi_count > 0


func _fill(items: Array[MeshInstance3D], root: Node3D, mat: Material,
		tiles: Array[Vector2i], scale_mul: float, lift: float) -> void:
	var cell: float = palette.cell_size()
	for i in tiles.size():
		var mi: MeshInstance3D = null
		if i < items.size():
			mi = items[i]
		else:
			mi = MeshInstance3D.new()
			mi.mesh = _mesh
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
			items.append(mi)
		var t: Vector2i = tiles[i]
		var center: Vector3 = palette.to_world(Vector2(float(t.x) + 0.5, float(t.y) + 0.5))
		center.y = lift
		var s: float = cell * scale_mul * _scale_jitter(t)
		mi.position = center
		mi.basis = Basis(Vector3.UP, _yaw_for(t)).scaled(Vector3(s, s, s))
		mi.visible = true
	# 多余的那几块收起来（点位被建筑占用 / 拖牌结束）
	for i in range(tiles.size(), items.size()):
		items[i].visible = false


## 每格一个稳定的朝向 / 大小抖动（同一局的同一个点位不会每帧变）。
func _yaw_for(t: Vector2i) -> float:
	var h: int = (t.x * 73856093) ^ (t.y * 19349663)
	return float(h & 1023) / 1024.0 * TAU


func _scale_jitter(t: Vector2i) -> float:
	var h: int = (t.x * 83492791) ^ (t.y * 2654435761)
	return 0.92 + float(h & 255) / 255.0 * 0.16
