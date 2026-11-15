## building_death_view_3d.gd —— 建筑倒毁动画（纯表现，2026.11.15）
##
## 用户口径：「建筑向下塌陷（零件需要分开塌陷倒地）+ 碎石尘土」；任何消失都播放。
##
## 做法（不改逻辑 / 协议）：
##   1. 本层每帧对 `world.building_list` 做一次「上一次活着、这一次不见了」的差分；
##      —— 战斗摧毁、主动拆除、剧本移除都会走到这里（用户选的「任何消失都播放」）；
##   2. 消失的建筑按**它自己那一帧的模型**拆成碎块：
##      模型是 Blender 导出的合并网格，但每个砖 / 板 / 石本身是独立的小体块 ——
##      这里按「共享顶点位置」做并查集连通分量，得到一块块 AABB，再当刚体碎块扔下去；
##   3. 碎块用一个 MultiMesh（一次 draw call）逐帧积分重力 / 旋转 / 落地，
##      同时调用 `death_fx.spawn()` 起一团尘土；整栋「向下塌」。
##
## 为什么在**视图层**做差分：`building.alive = false` 之后 world 会把它从列表摘掉，
##   但没有任何「建筑死亡」事件（协议里也没有）—— 差分是唯一不动逻辑的入口。
##   代价：地图切换 / 重置时也会看到一堆消失 —— 用「一次消失超过 8 栋视为换图」挡掉。
extends Node3D

const DebrisShader := preload("res://view/building_debris.gdshader")

## 一次倒塌持续多久（含最后 35% 的淡出）。
const COLLAPSE_SEC := 1.15
## 同时最多几栋在倒（一排城墙被拆时不会无限叠加）。
const MAX_COLLAPSES := 20
## 单栋最多拆几块（按体积取前 N 块；小碎屑丢掉不影响观感）。
const MAX_PIECES := 64
## 重力：世界单位/秒²。1 格 = 128 世界单位，这里按「约 9.8 格/秒²」放大。
const GRAVITY_TILES := 9.8

var cfg = null
var palette = null
var buildings = null
var death_fx = null

## 上一帧还活着的建筑：`id -> {type, xform}`。
var _alive: Dictionary = {}
## 正在倒的：`[{node, mm, pieces, t}]`。
var _collapses: Array = []
## 类型 → 碎块模板（模型局部空间：中心 / 尺寸 / 颜色）。
var _piece_cache: Dictionary = {}
var _mat: ShaderMaterial = null
var _box: BoxMesh = null

## 诊断（测试读）：正在倒几栋 / 最近一次拆了几块。
var active_count: int = 0
var last_piece_count: int = 0


func setup(p_cfg, p_palette, p_buildings, p_death_fx = null) -> void:
	cfg = p_cfg
	palette = p_palette
	buildings = p_buildings
	death_fx = p_death_fx
	_box = BoxMesh.new()
	_box.size = Vector3.ONE
	_mat = ShaderMaterial.new()
	_mat.shader = DebrisShader
	_alive = {}
	_piece_cache = {}
	for c in _collapses:
		_free_collapse(c)
	_collapses = []
	active_count = 0
	last_piece_count = 0


## 每帧：先记「谁还活着」，再推进正在倒的碎块。
## @param dt 暂停时传 0（冻结）
func sync(dt: float) -> void:
	_track_buildings()
	_advance(dt)
	active_count = _collapses.size()


func _track_buildings() -> void:
	if buildings == null:
		return
	var seen: Dictionary = {}
	if buildings.world == null:
		return
	for b in buildings.world.building_list:
		if b == null or not is_instance_valid(b) or not b.alive:
			continue
		var bid := int(b.get_instance_id())
		seen[bid] = {
			"type": String(b.type),
			# ★ 直接复用建筑视图的落地变换：不做 `Building` 对象的临时分配（每帧每栋一次会 GC 抖）。
			"xform": buildings._static_transform_of(b),
			"tx": int(b.tx),
			"ty": int(b.ty),
		}
	# 第一次同步只记基线，不播（避免开局把整张图的建筑当成「刚消失」）。
	if _alive.is_empty():
		_alive = seen
		return
	var gone: Array = []
	for bid in _alive.keys():
		if seen.has(bid):
			continue
		# 快照里留下的是**上一次还活着**的那一帧（类型 / 位置）。
		gone.append(_alive[bid])
	_alive = seen
	# 一帧少 8 栋以上 = 换图 / 重置，不是战斗摧毁：不播。
	if gone.size() > 8:
		return
	for snap in gone:
		_spawn_collapse(snap)


func _spawn_collapse(snap: Dictionary) -> void:
	var type := String(snap.get("type", ""))
	var pieces := _pieces_of(type)
	if pieces.is_empty():
		return
	if _collapses.size() >= MAX_COLLAPSES:
		return
	var xf: Transform3D = snap.get("xform", Transform3D.IDENTITY)
	var world_scale: Vector3 = xf.basis.get_scale().abs()
	var cell: float = palette.cell_size() if palette != null else 128.0
	var center := xf.origin
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _box
	mm.instance_count = pieces.size()
	mm.visible_instance_count = pieces.size()
	var mi := MultiMeshInstance3D.new()
	mi.name = "BuildingCollapse"
	mi.multimesh = mm
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(center - Vector3(cell * 2.0, cell * 1.5, cell * 2.0),
		Vector3(cell * 4.0, cell * 4.0, cell * 4.0))
	add_child(mi)

	var states: Array = []
	var ground: float = center.y
	for p in pieces:
		var local_center: Vector3 = p["center"]
		var wp: Vector3 = xf * local_center
		var size: Vector3 = (p["size"] as Vector3) * world_scale
		size = Vector3(maxf(size.x, 0.01), maxf(size.y, 0.01), maxf(size.z, 0.01))
		var dir2 := Vector2(wp.x - center.x, wp.z - center.z)
		if dir2.length() < 1e-4:
			dir2 = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0))
		dir2 = dir2.normalized()
		var spread := randf_range(0.55, 1.5)
		states.append({
			"pos": wp,
			"vel": Vector3(dir2.x * cell * spread, cell * randf_range(0.15, 0.8),
				dir2.y * cell * spread),
			"rot": Basis(Vector3.UP, randf_range(0.0, TAU)),
			"ang": Vector3(randf_range(-6.0, 6.0), randf_range(-6.0, 6.0),
				randf_range(-6.0, 6.0)),
			"size": size,
			"color": p["color"],
		})
	last_piece_count = states.size()
	_collapses.append({"node": mi, "mm": mm, "pieces": states, "t": 0.0,
		"ground": ground, "gravity": GRAVITY_TILES * cell})
	if death_fx != null:
		# 三团错开的尘土：单团 0.32s 太短，一栋楼塌下来盖不住整个占地。
		var lp := Vector2(float(snap.get("tx", 0)) + 0.5,
			float(snap.get("ty", 0)) + 0.5)
		var dust := Color(0.62, 0.58, 0.52)
		death_fx.spawn(lp, dust)
		death_fx.spawn(lp + Vector2(0.24, -0.12), dust)
		death_fx.spawn(lp + Vector2(-0.20, 0.16), dust)


func _advance(dt: float) -> void:
	if _collapses.is_empty():
		return
	var keep: Array = []
	for c in _collapses:
		var node: MultiMeshInstance3D = c["node"]
		if not is_instance_valid(node):
			continue
		c["t"] = float(c["t"]) + dt
		var t: float = c["t"]
		if t >= COLLAPSE_SEC:
			_free_collapse(c)
			continue
		var fade: float = 1.0
		if t > COLLAPSE_SEC * 0.65:
			fade = 1.0 - (t - COLLAPSE_SEC * 0.65) / (COLLAPSE_SEC * 0.35)
		var mm: MultiMesh = c["mm"]
		var ground: float = c["ground"]
		var g: float = c["gravity"]
		for i in (c["pieces"] as Array).size():
			var p: Dictionary = (c["pieces"] as Array)[i]
			var pos: Vector3 = p["pos"]
			var vel: Vector3 = p["vel"]
			var rot: Basis = p["rot"]
			var ang: Vector3 = p["ang"]
			var size: Vector3 = p["size"]
			vel.y -= g * dt
			pos += vel * dt
			if ang.length() > 1e-4:
				rot = Basis(ang.normalized(), ang.length() * dt) * rot
			var half_h: float = size.y * 0.5
			if pos.y - half_h < ground:
				pos.y = ground + half_h
				if absf(vel.y) > 18.0:
					vel.y = -vel.y * 0.22
				else:
					vel.y = 0.0
				vel.x *= 0.62
				vel.z *= 0.62
				ang *= 0.55
			p["pos"] = pos
			p["vel"] = vel
			p["rot"] = rot
			p["ang"] = ang
			var cbase: Color = p["color"]
			mm.set_instance_transform(i, Transform3D(rot.scaled(size), pos))
			mm.set_instance_custom_data(i, Color(cbase.r, cbase.g, cbase.b, fade))
		keep.append(c)
	_collapses = keep


func _free_collapse(c: Dictionary) -> void:
	var node = c.get("node", null)
	if node != null and is_instance_valid(node):
		node.queue_free()


# ------------------------------------------------------------------
# 模型 → 碎块模板
# ------------------------------------------------------------------

func _pieces_of(type: String) -> Array:
	if _piece_cache.has(type):
		return _piece_cache[type]
	var mesh: Mesh = buildings.preview_mesh(type) if buildings != null else null
	var out: Array = []
	if mesh != null and mesh.get_surface_count() > 0:
		out = _split_mesh(mesh)
	_piece_cache[type] = out
	return out


## 把合并网格按「共享顶点位置」拆成连通分量，每个分量压成一个 AABB 碎块。
##
## ★ 为什么不能按索引连通：Blender 导出的模型是**平面着色**的（每个面独立顶点），
##   按索引拆会得到「每个三角形一块」。按位置量化后并查集，才能把一块砖的 12 个三角形
##   合成一块刚体 —— 这也是「零件分开塌陷」真正的粒度。
func _split_mesh(mesh: Mesh) -> Array:
	var arrays: Array = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return []
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return []
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var idx_v: Variant = arrays[Mesh.ARRAY_INDEX]
	var indices: PackedInt32Array = idx_v if idx_v is PackedInt32Array else PackedInt32Array()
	var tri_count: int = (indices.size() / 3) if not indices.is_empty() else (verts.size() / 3)
	if tri_count <= 0:
		return []
	# 三角形 → 分量（并查集）
	var parent: Array[int] = []
	parent.resize(tri_count)
	for i in tri_count:
		parent[i] = i
	var first_by_key: Dictionary = {}
	for tri in tri_count:
		for k in 3:
			var vi: int = indices[tri * 3 + k] if not indices.is_empty() else tri * 3 + k
			var key := Vector3i(
				int(round(verts[vi].x * 10000.0)),
				int(round(verts[vi].y * 10000.0)),
				int(round(verts[vi].z * 10000.0)))
			if first_by_key.has(key):
				_uf_union(parent, tri, int(first_by_key[key]))
			else:
				first_by_key[key] = tri
	# 收集每个根下的三角形
	var groups: Dictionary = {}
	for tri in tri_count:
		var r := _uf_find(parent, tri)
		if not groups.has(r):
			groups[r] = []
		(groups[r] as Array).append(tri)
	var pieces: Array = []
	for r in groups.keys():
		var tris: Array = groups[r]
		var mn := Vector3(1e9, 1e9, 1e9)
		var mx := Vector3(-1e9, -1e9, -1e9)
		var col := Color(0, 0, 0, 0)
		var col_n := 0
		var vseen: Dictionary = {}
		for tri in tris:
			for k in 3:
				var vi: int = indices[tri * 3 + k] if not indices.is_empty() else tri * 3 + k
				if vseen.has(vi):
					continue
				vseen[vi] = true
				var v: Vector3 = verts[vi]
				mn = Vector3(minf(mn.x, v.x), minf(mn.y, v.y), minf(mn.z, v.z))
				mx = Vector3(maxf(mx.x, v.x), maxf(mx.y, v.y), maxf(mx.z, v.z))
				if vi < colors.size():
					col += colors[vi]
					col_n += 1
		var size: Vector3 = mx - mn
		if maxf(size.x, maxf(size.y, size.z)) < 1e-5:
			continue
		if col_n > 0:
			col = Color(col.r / col_n, col.g / col_n, col.b / col_n, 1.0)
		else:
			col = Color(0.55, 0.53, 0.50, 1.0)
		col.a = 1.0
		pieces.append({"center": (mn + mx) * 0.5, "size": size, "color": col,
			"vol": size.x * size.y * size.z})
	# 大块优先；太小的碎屑丢掉（最多 MAX_PIECES 块）
	pieces.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["vol"]) > float(b["vol"]))
	if pieces.size() > MAX_PIECES:
		pieces.resize(MAX_PIECES)
	return pieces


func _uf_find(parent: Array[int], x: int) -> int:
	var root: int = x
	while parent[root] != root:
		root = parent[root]
	while parent[x] != root:
		var nxt: int = parent[x]
		parent[x] = root
		x = nxt
	return root


func _uf_union(parent: Array[int], a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra
