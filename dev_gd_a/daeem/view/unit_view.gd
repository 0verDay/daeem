## unit_view.gd —— 单位的渲染（对应 HTML 版 render.js 的单位与射程圈）
##
## ★★ 为什么是「一个 CanvasItem 画全部」而不是「每个单位一个 Node2D」：
##    1000 单位常态下，后者 = 1000 个节点、每帧 1000 次 queue_redraw → 1000 次 _draw 回调，
##    外加每帧每单位一次阵营配色查表；而且它把绘制打成了 1000 个碎片批次。
##    画在一起之后每帧只有**一次** _draw。
##    （架构文档 3.2 那条「数量少且需要交互 → 每个逻辑对象一个节点」在 1000 单位下不再成立，
##     已按大数量场景改成「一个节点画全部」。）
##
## ★ 仍然只读逻辑状态（第三条铁律）：本文件不写 world / unit 的任何字段。
## ⚠️ 绝不在 _process 里 queue_free() + new() 重建（docs/pitfalls.md 2.3）——
##    现在干脆没有「每个单位一个节点」这回事了。
extends Node2D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
## ★ 给 for 循环变量加类型：`u.pos` / `u.alive` 这类成员访问在有类型时是静态解析，
##   无类型时是动态查找（每单位每批次一次）。见 docs/pitfalls.md 1.7。
##   unit.gd 不 preload view/，所以这里不是循环依赖。
const UnitRes = preload("res://logic/unit.gd")

## 屏幕外剔除的余量（像素）：血条 / 选中圈会画到单位本体之外一点
const CULL_PAD_PX := 48.0

## 朝向线 / 交战标记 / 血条的配色（都是能合批的图元，见下面 _draw 的说明）
const FACING_COLOR := Color(0, 0, 0, 0.5)
const ENGAGED_COLOR := Color(1.0, 0.45, 0.35, 0.95)
const HP_BACK_COLOR := Color(0, 0, 0, 0.55)
## 描边（黑，0.45）烘进本体贴图里，见 _make_disc_texture
const OUTLINE_ALPHA := 0.45

## 单位贴图的边长（像素）。单位在屏幕上是 4~13 像素直径，32 足够，还能抗缩放。
const DISC_TEX_SIZE := 32

## ★★ 为什么单位本体改成「贴图」而不是 draw_circle / draw_arc：
##    实测（1000 单位、100×100 图）——
##      draw_circle ×1000 → **997 个 draw call、18.4 ms**
##      draw_arc    ×1000 → **997 个 draw call、10.2 ms**
##      draw_line   ×1000 → 只多 **1 个 draw call**、几乎不耗时（线能合批）
##    也就是说这两个 API **完全不参与 2D 合批**，每单位各占一个绘制批次。
##    换成同一张贴图之后，1000 个单位合成 1 个批次。
##    （描边也一起烘进贴图了，所以 draw_arc 那一笔整笔消失。）
var _tex_body: ImageTexture = null
var _tex_halo: ImageTexture = null

var cfg: ConfigRes = null
var world = null

## unit.id -> true（纯本地，不进命令流）
var _selection: Dictionary = {}
## 阵营 → [主体色, 选中色, 血条色]。每帧每单位都查一次的东西，缓存成一次查表。
var _color_cache: Dictionary = {}


func setup(p_cfg: ConfigRes, p_world) -> void:
	cfg = p_cfg
	world = p_world
	z_index = 10
	_color_cache = {}
	_tex_body = _make_disc_texture(true)
	_tex_halo = _make_disc_texture(false)


## 生成一张圆盘贴图。
## rim = true 时把「黑描边」烘进去：贴图里白色部分是本体（会被实例色染成阵营色），
## 黑色半透明部分是描边（乘任何颜色都还是黑）。
static func _make_disc_texture(rim: bool) -> ImageTexture:
	var size := DISC_TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var r_out := c - 0.5
	var r_in := r_out - (2.5 if rim else 0.0)
	for y in size:
		for x in size:
			var d := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
			var cov := clampf(r_out - d + 0.5, 0.0, 1.0)          # 外缘抗锯齿
			if rim:
				var inner := clampf(d - r_in + 0.5, 0.0, 1.0)     # 0 = 描边, 1 = 本体
				var col := Color(0.0, 0.0, 0.0, OUTLINE_ALPHA).lerp(Color(1, 1, 1, 1), inner)
				col.a *= cov
				img.set_pixel(x, y, col)
			else:
				img.set_pixel(x, y, Color(1, 1, 1, cov))
	return ImageTexture.create_from_image(img)


## 每帧同步：位置 / 血条 / 朝向每帧都可能变，所以每帧排一次重画。
## 只有一个 CanvasItem，这一次 queue_redraw 的代价可以忽略。
func sync(_dt: float) -> void:
	if world == null:
		return
	queue_redraw()


## 设置选中集合（view 内部状态，不发命令）。只有真的变了才重画。
func set_selection(ids: Array) -> void:
	var next: Dictionary = {}
	for id in ids:
		next[String(id)] = true
	if next.size() == _selection.size():
		var same := true
		for id in next.keys():
			if not _selection.has(id):
				same = false
				break
		if same:
			return
	_selection = next
	queue_redraw()


func _draw() -> void:
	if world == null or cfg == null:
		return

	# ---- 第一遍：筛出可见单位，并把后面所有图元都要用的东西**一次算好** ----
	# 位置 / 半径 / 配色 在下面 6 个绘制批次里都要用；不先算好就会变成
	# 「每个单位在每个批次里各查一次」= 1000 × 6 次方法调用。
	#
	# ★★ 这一段的开销几乎全在「每单位每批次一次 draw_* 调用」上：实测 1000 单位时
	#    整个 UnitView 约 8 ms（把节点 visible=false 一藏，帧时间直接掉 8 ms），
	#    而 draw call 只有个位数 —— 也就是说贵的是**在 GDScript 里攒绘制命令**，
	#    不是 GPU。所以这里做的是「少一次查表、少一次开方」这类便宜但确定的事：
	#      · `u.pos * cell_px` **内联**，不再每单位调一次 PaletteRes.to_px；
	#      · 半径按 kind 每帧查一次表（原来是每单位一次 `unit_radius_of` + 一次乘法）；
	#      · 朝向上不再 `normalized()`（facing 本来就存的是单位向量），
	#        判零也改成平方比较，省掉每单位一次开方。
	var cell_px: float = cfg.cell_px
	var vis := _visible_rect()
	var units: Array = []
	var pts := PackedVector2Array()
	var radii := PackedFloat32Array()
	var body_cols := PackedColorArray()
	var ring_cols := PackedColorArray()
	var hp_cols := PackedColorArray()
	var radius_by_kind: Dictionary = {}
	for u: UnitRes in world.units:
		if not u.alive:
			continue
		var p: Vector2 = u.pos * cell_px
		if not vis.has_point(p):
			continue                    # 屏幕外：连指令都不发
		var r: float = radius_by_kind.get(u.kind, -1.0)
		if r < 0.0:
			r = cfg.unit_radius_of(u.kind) * cell_px
			radius_by_kind[u.kind] = r
		var col: Array = _colors_for(u.faction)
		units.append(u)
		pts.append(p)
		radii.append(r)
		body_cols.append(col[0])
		ring_cols.append(col[1])
		hp_cols.append(col[2])

	var n := units.size()
	if n == 0:
		return
	# ---- 后面 6 遍：**按图元类型分组**，而不是「一个单位画完自己那一套」 ----
	# ★★ 为什么必须分组：Godot 的 2D 画布按图元/状态合批。
	#    原来每个单位连着画 circle→arc→line→(血条)，批次状态在单位之间反复横跳，
	#    1000 个单位就变成 **4000+ 个 draw call**（实测 4204），完全合不了批。
	#    分组之后同一类图元连着画 → 合批 → draw call 掉到个位数。
	#    （实测：1000 单位实机帧从 60.8 ms 的渲染降到见 bench_fps 的输出。）

	# 1) 选中圈（先画，压在主体下面）：同一个贴图放大 + 半透明阵营色
	for i in n:
		if _selection.has(units[i].id):
			var rr: float = radii[i] + 4.0
			var rc: Color = ring_cols[i]
			draw_texture_rect(_tex_halo, Rect2(pts[i] - Vector2(rr, rr), Vector2(rr * 2.0, rr * 2.0)),
				false, Color(rc.r, rc.g, rc.b, 0.35))
	# 2) 单位本体（贴图里已经烘了描边；同一张贴图 → 1000 个单位合一个批次）
	for i in n:
		var r2: float = radii[i]
		draw_texture_rect(_tex_body,
			Rect2(pts[i] - Vector2(r2, r2), Vector2(r2 * 2.0, r2 * 2.0)),
			false, body_cols[i])
	# 3) 朝向：一条短线，指向 facing（八方向之后 facing 是完整向量）—— 线能合批，随便画
	for i in n:
		var f: Vector2 = units[i].facing
		# ⚠️ facing 存的本来就是单位向量（face_toward / step_along_path 都归一过），
		#    所以这里**不再 normalized()**；判零用平方比较，省掉每单位一次开方。
		if f.x * f.x + f.y * f.y > 1e-12:
			draw_line(pts[i], pts[i] + f * (radii[i] * 1.5), FACING_COLOR, 2.0)
	# 5) 交战标记：头顶小三角
	for i in n:
		var u2 = units[i]
		if u2.target != null or u2.target_building != null:
			var d: float = radii[i] + 5.0
			draw_colored_polygon(PackedVector2Array([
				pts[i] + Vector2(-3.5, -d), pts[i] + Vector2(3.5, -d), pts[i] + Vector2(0.0, -d - 5.0),
			]), ENGAGED_COLOR)
	# 6) 血条：不满血才画（满血不画，避免刷屏）。
	#    底 + 填充合成**一遍**：两笔都是 draw_rect（顶点色不同，仍然合批），
	#    拆成两遍只是白扫 1000 个单位、白判两次血量。
	for i in n:
		var u3 = units[i]
		if u3.hp < u3.hp_max - 1e-6:
			var w: float = radii[i] * 2.4
			var top: float = pts[i].y + radii[i] + 4.0
			draw_rect(Rect2(Vector2(pts[i].x - w * 0.5, top), Vector2(w, 3.0)), HP_BACK_COLOR, true)
			draw_rect(Rect2(Vector2(pts[i].x - w * 0.5, top), Vector2(w * u3.hp_ratio(), 3.0)),
				hp_cols[i], true)


func _colors_for(faction: String) -> Array:
	var c: Variant = _color_cache.get(faction, null)
	if c == null:
		c = [
			cfg.faction_color(faction, "main"),
			cfg.faction_color(faction, "sel"),
			cfg.faction_color(faction, "bar"),
		]
		_color_cache[faction] = c
	return c


## 当前可见的世界像素矩形（用来剔除屏幕外的单位）。
## 不在场景树里时（无头测试直接调 _draw）返回一个巨大的矩形 —— 宁可多画，不要漏画。
func _visible_rect() -> Rect2:
	if not is_inside_tree():
		return Rect2(-1e9, -1e9, 2e9, 2e9)
	var vp := get_viewport_rect()
	var inv := get_global_transform_with_canvas().affine_inverse()
	var a := inv * vp.position
	var b := inv * vp.end
	var rect := Rect2(a, Vector2.ZERO).expand(b)
	return rect.grow(CULL_PAD_PX)
