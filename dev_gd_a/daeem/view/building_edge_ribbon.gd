## building_edge_ribbon.gd —— 从一个建筑网格生成「所有折边」的粗线带网格
##
## ★★ 为什么不是线图元（`PRIMITIVE_LINES`）：
##   Godot 的 3D 线宽不随镜头缩放、最多 1px，做不出「粗描边」。这里把每条边
##   存成**中心线**（两个端点），由 `building_edge_outline.gdshader` 在顶点着色器里
##   按**该实例的真实视线方向**展开成一个面向相机的细长四边形（ribbon）。
##
## ★★ 为什么展开放在着色器里（这是「上半地图有线、下半地图没线」那个 bug 的修法）：
##   透视相机下，屏幕不同位置看到的视线方向**并不相同**（画面上半更俯视、下半更平），
##   而相机只平移 / 缩放、不旋转 —— 在 CPU 上按一个固定方向展开，下半屏的 ribbon
##   会扎进建筑表面，被深度测试整条吃掉，只剩外轮廓。
##   ⇒ 现在每个顶点只存：中心线点（VERTEX）、边方向（NORMAL）、侧向 / 线宽（UV），
##     展开与「向相机抬一点」都按实际视线在 GPU 上算。
##
## ★★ 只取「折边」：
##   把三角形按**位置**焊接（glTF 导入的网格大多是逐面拆点的，不用位置焊接就
##   找不到共享边），再按相邻面法线夹角筛选：
##     · 只有一个相邻面（边界边）→ 保留；
##     · 相邻面夹角 > `crease_deg`（默认 8°）→ 保留；
##     · 共面三角形之间的辅助对角线（夹角 ≈ 0）→ **丢弃**。
##   这样 box 是 12 条棱、台阶是每一级轮廓，而不是把平面切成三角形的对角线也画出来。
##
## ★ 纯静态、无状态：结果只由 mesh / 线宽 / 折边阈值决定，调用方缓存。
extends RefCounted

## 位置焊接精度（1e-3 格）。建筑网格是低模，1e-3 足够合并同一点，
## 又不会把相邻但不同的顶点误焊。
const WELD_SCALE := 1000.0


## 生成一个「所有折边」的 Ribbon ArrayMesh（**中心线** + 边方向 + 线宽，展开在 shader）。
##
## @param mesh      建筑本体网格（合并后的 ArrayMesh，局部坐标 1 单位 = 1 格）
## @param width     ribbon 宽度（局部单位；写进 UV.y，实例缩放后跟着变大）
## @param crease_deg 折边阈值（度）；0 = 所有三角形边都画
## @return ArrayMesh（PRIMITIVE_TRIANGLES）；没有边时返回空网格
static func build(mesh: Mesh, width: float, crease_deg: float = 8.0) -> ArrayMesh:
	var out := ArrayMesh.new()
	if mesh == null or width <= 0.0:
		return out
	var cos_thr: float = cos(deg_to_rad(clampf(crease_deg, 0.0, 179.0)))
	var weld: Dictionary = {}
	var points: PackedVector3Array = PackedVector3Array()
	var edges: Dictionary = {}
	var tris: PackedVector3Array = PackedVector3Array()
	var normals: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var indices: PackedInt32Array = PackedInt32Array()

	for s in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		if verts.is_empty():
			continue
		var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
		var ids := PackedInt32Array()
		ids.resize(verts.size())
		for i in verts.size():
			var p: Vector3 = verts[i]
			var key := Vector3i(roundi(p.x * WELD_SCALE),
				roundi(p.y * WELD_SCALE), roundi(p.z * WELD_SCALE))
			var cid: int = int(weld.get(key, -1))
			if cid < 0:
				cid = points.size()
				weld[key] = cid
				points.append(p)
			ids[i] = cid
		var tri_n: int = idx.size() / 3 if idx.size() > 0 else verts.size() / 3
		for t in tri_n:
			var i0: int
			var i1: int
			var i2: int
			if idx.is_empty():
				i0 = t * 3
				i1 = i0 + 1
				i2 = i0 + 2
			else:
				i0 = idx[t * 3]
				i1 = idx[t * 3 + 1]
				i2 = idx[t * 3 + 2]
			if i0 == i1 or i1 == i2 or i2 == i0:
				continue
			var p0: Vector3 = verts[i0]
			var p1: Vector3 = verts[i1]
			var p2: Vector3 = verts[i2]
			var n := (p1 - p0).cross(p2 - p0)
			if n.length_squared() < 1.0e-12:
				continue
			n = n.normalized()
			var a: int = ids[i0]
			var b: int = ids[i1]
			var c: int = ids[i2]
			_add_edge(edges, a, b, n)
			_add_edge(edges, b, c, n)
			_add_edge(edges, c, a, n)

	# 逐条边判断「是不是折边」，是就写进中心线网格（展开在 shader 里做）。
	for key in edges.keys():
		var e: Dictionary = edges[key]
		var face_normals: Array = e["n"]
		if not _is_crease(face_normals, cos_thr):
			continue
		var k: Vector2i = key
		var p0: Vector3 = points[k.x]
		var p1: Vector3 = points[k.y]
		var d: Vector3 = p1 - p0
		if d.length_squared() < 1.0e-10:
			continue
		d = d.normalized()
		# 每个端点 × 两侧 ⇒ 4 个顶点 + 6 个索引（两个三角形）。
		# 顶点只存**中心线点**，展开方向 / 向相机偏移由 building_edge_outline.gdshader
		# 按真实视线算：
		#   · NORMAL = 边方向（实例缩放后就是世界空间的方向）；
		#   · UV.x  = 侧向（-1 / +1）；
		#   · UV.y  = 线宽（局部单位，shader 里乘实例缩放）。
		var base: int = tris.size()
		for pt in [p0, p1]:
			tris.append(pt)
			normals.append(d)
			uvs.append(Vector2(-1.0, width))
			tris.append(pt)
			normals.append(d)
			uvs.append(Vector2(1.0, width))
		indices.append(base)
		indices.append(base + 1)
		indices.append(base + 2)
		indices.append(base + 1)
		indices.append(base + 3)
		indices.append(base + 2)

	if tris.is_empty():
		return out
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = tris
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


## 一条边是否为「折边」：边界边，或相邻面法线夹角超过阈值。
static func _is_crease(normals: Array, cos_thr: float) -> bool:
	if normals.size() <= 1:
		return normals.size() == 1
	for i in normals.size():
		for j in range(i + 1, normals.size()):
			var n0: Vector3 = normals[i]
			var n1: Vector3 = normals[j]
			# ★ `<=` 而不是 `<`：`crease_deg = 0` 时 cos_thr = 1，
			#   共面三角形（dot = 1）也要算「折边」⇒ 连三角化对角线一起描。
			if n0.dot(n1) <= cos_thr:
				return true
	return false


static func _add_edge(edges: Dictionary, a: int, b: int, n: Vector3) -> void:
	if a == b:
		return
	var key := Vector2i(mini(a, b), maxi(a, b))
	var e: Variant = edges.get(key, null)
	if e == null:
		e = {"n": []}
		edges[key] = e
	(e["n"] as Array).append(n)
