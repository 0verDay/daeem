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
## ★ 给 for 循环变量加类型：`u.pos` / `u.alive` 这类成员访问在有类型时是静态解析，
##   无类型时是动态查找（每单位每批次一次）。见 docs/pitfalls.md 1.7。
##   unit.gd 不 preload view/，所以这里不是循环依赖。
const UnitRes = preload("res://logic/unit.gd")
## ★ 单位在地图上 = **阵营色圆盘底 + 一个字**（见 view/unit_icon.gd 的文件头：
##   圆盘走贴图（能合批），字走 draw_char（动态字体的字形取不成 Image）；
##   将领那一档的**圆盘描边更粗**，用来与普通兵区分）。
const UnitIconRes = preload("res://view/unit_icon.gd")

## 屏幕外剔除的余量（像素）：血条 / 选中圈会画到单位本体之外一点
const CULL_PAD_PX := 48.0

## 朝向线 / 交战标记 / 血条的配色（都是能合批的图元，见下面 _draw 的说明）
const FACING_COLOR := Color(0, 0, 0, 0.5)
const ENGAGED_COLOR := Color(1.0, 0.45, 0.35, 0.95)
const HP_BACK_COLOR := Color(0, 0, 0, 0.55)
## 选中光晕（那张纯白圆盘贴图）的贴图边长（像素）。
## ⚠️ 单位本体现在画的是**一个字的图标**（见 view/unit_icon.gd），不再是圆盘 ——
##   圆盘只留给「选中光晕」这一层用（它本来就是一团柔和的圆）。
const HALO_TEX_SIZE := 32

## ★★ 为什么单位本体是「贴图 + 字」这两条路各走各的：
##    圆盘底走**贴图**（两张：普通 / 将领），同贴图的几百个单位合成一个批次 ——
##    这是为 1000 单位基准做的（实测：draw_circle ×1000 = **997 个 draw call、18.4 ms**，
##    贴图版同贴图合成一个批次；draw_line 能合批所以朝向线照旧随便画）。
##    那个字只能走 **draw_char**：动态字体的字形取不成 Image（实测记录见 unit_icon.gd 文件头）。
var _tex_halo: ImageTexture = null

var cfg: ConfigRes = null
var world = null
## 画字用的字体（game_scene 传进来；没传就用引擎兜底字体 —— 无头测试走这条路）。
var _font: Font = null

## unit.id -> true（纯本地，不进命令流）
var _selection: Dictionary = {}
## 阵营 → [主体色, 选中色, 血条色]。每帧每单位都查一次的东西，缓存成一次查表。
var _color_cache: Dictionary = {}
## ★★ 最近一次 `_draw()` 里**真的发出了几张单位图标**（纯诊断，只有测试读它）。
##
## 为什么要有这个计数器：无头测试里 `_draw()` 内部的错误**不会**让测试失败，
## 而「一个图标都没画」这件事既不报错、也不改变任何逻辑状态 ——
## 只有留下一个可数的痕迹才钉得住它（上一轮真踩过：分桶用了值语义的 PackedInt32Array，
## 桶永远是空的 ⇒ 画面上只剩朝向线。见 docs/pitfalls.md 5.50）。
var icon_draw_count: int = 0
## ★ 其中圆盘底画了几张（正常情况 = icon_draw_count：每个单位一个盘 + 一个字）。
##   两个字分开数，是为了「盘画了、字没画」和「字画了、盘没画」都能被测出来。
var icon_disc_count: int = 0


func setup(p_cfg: ConfigRes, p_world, p_font: Font = null) -> void:
	cfg = p_cfg
	world = p_world
	_font = p_font if p_font != null else ThemeDB.fallback_font
	z_index = 10
	_color_cache = {}
	_tex_halo = _make_disc_texture()


## 生成「选中光晕」用的那张纯白圆盘贴图（白色部分会被实例色染成阵营色）。
static func _make_disc_texture() -> ImageTexture:
	var size := HALO_TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := float(size) * 0.5
	var r_out := c - 0.5
	for y in size:
		for x in size:
			var d := Vector2(float(x) + 0.5 - c, float(y) + 0.5 - c).length()
			var cov := clampf(r_out - d + 0.5, 0.0, 1.0)          # 外缘抗锯齿
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
	#      · 半径与图标贴图按**单位类型**每帧查一次表（原来是每单位一次
	#        `unit_radius_of` + 一次乘法）—— 类型只有几种，查表几乎免费；
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
	var glyphs: Array = []          # 每个单位要画的**那个字**
	var discs: Array = []           # 每个单位那张**圆盘贴图**（普通 / 将领两档）
	var leaders := PackedByteArray()
	## 单位类型 → 屏幕半径（像素）。**逻辑半径**，字的外框另乘 unit_icon.EXTENT。
	var radius_by_type: Dictionary = {}
	## 单位类型 → 地图上那个字（同一个兵种几百个单位只查一次表）
	var char_by_type: Dictionary = {}
	for u: UnitRes in world.units:
		if not u.alive:
			continue
		var p: Vector2 = u.pos * cell_px
		if not vis.has_point(p):
			continue                    # 屏幕外：连指令都不发
		var utype := String(u.unit_type)
		var r: float = radius_by_type.get(utype, -1.0)
		if r < 0.0:
			r = cfg.unit_radius_of(utype) * cell_px
			radius_by_type[utype] = r
		var ch: String = char_by_type.get(utype, "")
		if ch == "":
			# ★ 字走**数据**：config 的 `unit.types.<类型>.icon`（编辑器里那一栏），
			#   没写就退成名字的第一个字 —— 规则在 config.gd 的 unit_icon_of 里，只一份。
			ch = UnitIconRes.char_of(cfg, utype)
			char_by_type[utype] = ch
		var col: Array = _colors_for(u.faction)
		var is_leader: bool = u.is_general()
		units.append(u)
		pts.append(p)
		radii.append(r)
		glyphs.append(ch)
		# ★ 圆盘贴图只有两张（普通 / 将领那一档的**描边更粗**），静态缓存
		discs.append(UnitIconRes.bake(is_leader))
		leaders.append(1 if is_leader else 0)
		body_cols.append(col[0])
		ring_cols.append(col[1])
		hp_cols.append(col[2])

	var n := units.size()
	if n == 0:
		icon_draw_count = 0
		icon_disc_count = 0
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
	# 2) 单位本体 = **阵营色圆盘底 + 一个字**（本轮：圆盘保留，字压在盘上，将领的描边更粗）。
	#
	# ★★ 分两遍画，两遍各自按「会被批次切断的那个键」分桶：
	#   2a) 圆盘：按**贴图**分桶（普通 / 将领两张）—— 一个单位换一次贴图就等于把批次切断
	#       （与文件头那段「按图元类型分组，而不是一个单位画完自己那一套」同一条道理）；
	#   2b) 字：按**字号**分桶（字号由半径算出来，同兵种天然同字号）。
	#   颜色都是逐图元的顶点色 / modulate（阵营色不同不会切断批次）。
	#   ⚠️ 分桶本身抽成了纯函数（`_bucket_by_tex` / `_bucket_by_size`），并且有测试钉它 ——
	#      上一轮在分桶上踩过一次**静默不画**的坑，见 docs/pitfalls.md 5.50。
	var by_tex := _bucket_by_tex(discs, n)
	var disc_drawn := 0
	for key_tex in by_tex.keys():
		var tex: ImageTexture = key_tex
		for i in (by_tex[key_tex] as Array):
			# ⚠️ 矩形是**图标空间**那一片：半径 × EXTENT（装得下圆盘 + 最粗的描边）
			var r2: float = radii[i] * UnitIconRes.EXTENT
			draw_texture_rect(tex,
				Rect2(pts[i] - Vector2(r2, r2), Vector2(r2 * 2.0, r2 * 2.0)),
				false, body_cols[i])
			disc_drawn += 1
	icon_disc_count = disc_drawn
	var by_size := _bucket_by_size(radii, n)
	var drawn := 0
	for fsize in by_size.keys():
		for i in (by_size[fsize] as Array):
			drawn += UnitIconRes.draw_char_at(self, _font, String(glyphs[i]), pts[i], radii[i])
	icon_draw_count = drawn
	# 3) 朝向：一条短线，指向 facing（八方向之后 facing 是完整向量）—— 线能合批，随便画
	#
	# ⚠️ 字**不随朝向旋转**（画出格会挤到旁边单位身上）。朝向由这一条线表达。
	for i in n:
		var f: Vector2 = units[i].facing
		# ⚠️ facing 存的本来就是单位向量（face_toward / step_along_path 都归一过），
		#    所以这里**不再 normalized()**；判零用平方比较，省掉每单位一次开方。
		if f.x * f.x + f.y * f.y > 1e-12:
			draw_line(pts[i], pts[i] + f * (radii[i] * 1.5), FACING_COLOR, 2.0)
	# 5) 交战标记：头顶小三角
	#
	# ⚠️ 头顶 / 血条的偏移都要**让开那个字**：字的外框是 `半径 × EXTENT`，
	#    用「半径 + 4」在字号偏大时会压到笔画上。
	for i in n:
		var u2 = units[i]
		if u2.target != null or u2.target_building != null:
			var d: float = radii[i] * UnitIconRes.EXTENT + 1.0
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
			var top: float = pts[i].y + radii[i] * UnitIconRes.EXTENT + 1.0
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


## 把「每个单位用哪张圆盘贴图」整理成「贴图 → 该贴图下要画的单位下标」。
##
## ★★ 为什么要分组：Godot 的 2D 画布按「贴图 + 状态」合批 —— 一个单位换一次贴图就等于
##    把批次切断（与文件头那段「按图元类型分组，而不是一个单位画完自己那一套」同一条道理）。
##
## ⚠️⚠️ **桶必须是 `Array`，绝不能图省事换成 `PackedInt32Array`**：
##   打包数组是**值语义**（写时复制），而 `(bucket as PackedInt32Array).append(i)`
##   改到的是那个临时副本 —— 字典里的桶**永远是空的**，于是**一个图标都画不出来**，
##   画面上只剩那条朝向线，而且**不报任何错**（实测踩过，见 pitfalls.md 5.50）。
##   `Array` 是引用语义，所以 `append` 才真的落进字典里那个桶。
##
## ★ 它是 static 且不碰任何状态，正是为了让测试能直接钉住「n 个单位一个不漏地分完」。
static func _bucket_by_tex(textures: Array, n: int) -> Dictionary:
	var out: Dictionary = {}
	for i in n:
		var tex: ImageTexture = textures[i]
		var bucket: Variant = out.get(tex, null)
		if bucket == null:
			bucket = []
			out[tex] = bucket
		(bucket as Array).append(i)
	return out


## 把「每个单位该用哪个字号」整理成「字号 → 该字号下要画的单位下标」。
## 分桶的理由与桶必须是 Array 的理由，与 `_bucket_by_tex` 完全一样（那边注释更细）。
static func _bucket_by_size(radii: PackedFloat32Array, n: int) -> Dictionary:
	var out: Dictionary = {}
	for i in n:
		var fsize: int = UnitIconRes.font_size_for(radii[i])
		var bucket: Variant = out.get(fsize, null)
		if bucket == null:
			bucket = []
			out[fsize] = bucket
		(bucket as Array).append(i)
	return out


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
