## ground_view.gd —— 3D 地面：**一块 PlaneMesh + 一张烘出来的底色贴图**
##
## ★★ 这一层的职责（本轮收窄过，改之前先读）：
##   它只画**平坦的底色**：地形（草地 / 森林 / 山）+ 区划归属的一层阵营色。
##   **网格线 / 区划轮廓 / 占领进度条都不在这里** —— 它们改由
##   `view/overlay_view_3d.gd` 在**屏幕空间**用矢量画法画（与 2D 版同一套画法）。
##
## ★★ 为什么这样分（用户报「占领的进度条还是太糊了」之后的实测结论）：
##   **烘到低分辨率贴图上、再放大，永远不可能像 2D 那样清晰** ——
##   1 像素 = 1 格的贴图被拉伸到一格约 **30 屏幕像素**，LINEAR 的插值就是在
##   **整格宽度**上摊开（实测：占领填充的前沿是一条 30 px 宽的渐变带）。
##   而 2D 版（`zone_view` / `terrain_view`）是 `draw_rect` / `draw_multiline`
##   直接画在画布上 ⇒ 天然逐像素清晰、斜线还有引擎的抗锯齿。
##   ⇒ 凡是**有"边"的东西**（网格线、轮廓、进度条）都必须走屏幕空间；
##     而**大块平坦色**（地形底色、区划底色）烘贴图反而更好（1 次 draw call）。
##
## ★★ 贴图坐标约定：
##   贴图 1 像素 = 1 格（乘 `PX_PER_TILE`）。图上的 (px, py) 对应逻辑格 (px, py)。
##   ★★ UV 变换必须是**恒等**：`PlaneMesh` 的 `uv.y = 0` 在 z 最小那一侧（北边），
##      而贴图第 0 行也是北边 ⇒ 两者本来就同向。
##
## ★ 只读 `world` / `map`，不改任何逻辑状态。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")

## 地面**底色**贴图的像素/格。
##
## ★ 为什么是 16（用户报「地表太糊了」，实测后定的）：
##   实测一格在屏幕上横向约 **29.7 px**（1920 视口 / 默认相机距离 6400）。
##   8 像素/格时 1 个贴图像素被放大 **3.7 倍**，16 时降到 **1.9 倍**。
##   底色是平坦色块，放大不会产生糊感，但**区划底色的边界**需要这个分辨率 ——
##   1 像素/格时区划之间的颜色过渡会在整格宽度上摊开，看起来像雾。
##
## ★ 代价（实测过，可接受）：
##   · 内存：27×22 的图 = **432×352**；100×100 的图 = 1600×1600（`MAX_TEX_PX` 内）；
##   · 烘图 CPU：27×22 图约 15 万个像素。它只在**归属签名变化**时跑
##     （`game_scene3d` 每 15 帧查一次签名），比 `_fog_signature()` 仍然便宜。
const PX_PER_TILE := 16
## 贴图最长边的上限（防止极大的地图把内存吃满）
const MAX_TEX_PX := 4096
## 迷雾贴图的像素/格。
##
## ★ 为什么迷雾也提了分辨率（原来是 1）：1 像素/格 = 一个纹素占整格约 30 屏幕像素
##   ⇒ 迷雾的**边界是一格一格跳的方块**（用户报过「迷雾上下反了」，方向修好之后
##   剩下的就是这种颗粒感）。提到 4 之后，一个纹素约 7.5 屏幕像素，
##   边界明显平滑，而贴图只有原来的 16 倍（100×100 图 = 400×400，仍然很小）。
const FOG_PX_PER_TILE := 4

var cfg: ConfigRes = null
var world = null
var palette = null

var _mesh: MeshInstance3D = null
var _mat: StandardMaterial3D = null
var _tex: ImageTexture = null
var _tex_cols: int = 0
var _tex_rows: int = 0

## ★★ 迷雾层：**另一块平面 + 另一张贴图**，压在地面之上一点点
##
## 为什么分开（而不是把迷雾烘进地形那张图）：
##   地形 + 区块归属变化**很少**（归属一变才重烘），而迷雾**每帧都在变**。
##   烘在一起的话，单位一走就要重烘整张地形图 —— 那是纯粹的浪费。
##   ★ 两块平面都是 1 次 draw call，所以拆开的代价可以忽略。
var _fog_mesh: MeshInstance3D = null
var _fog_mat: StandardMaterial3D = null
var _fog_tex: ImageTexture = null
var _fog_sig: String = ""

## 归属签名：区块归属没变就不重烘（重烘要写一张图，相对贵）
var _zone_sig: String = ""
## 诊断（只有测试读它）：最近一次烘图写下的格数
var baked_tiles: int = 0
var bake_count: int = 0
## 最近一次烘迷雾贴图的次数（纯诊断）
var fog_bake_count: int = 0


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	_build_mesh()
	rebake(true)


func _build_mesh() -> void:
	var cols: int = int(world.map.cols)
	var rows: int = int(world.map.rows)
	var cell: float = palette.cell_size()
	var plane := PlaneMesh.new()
	# ★ PlaneMesh 默认在 XZ 平面上、以原点为中心 ⇒ 尺寸给全图大小，再把节点挪到图心
	plane.size = Vector2(float(cols) * cell, float(rows) * cell)
	plane.subdivide_width = 0
	plane.subdivide_depth = 0

	_mat = StandardMaterial3D.new()
	# ★ 不投影阴影、也不接收阴影（用户口径：暂时不需要阴影）
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# ★★ 过滤方式（用户报「地表太糊了」，本轮实测后定的）：
	#   原来是 `LINEAR_WITH_MIPMAPS_ANISOTROPIC` ——
	#   ★★ mipmap 那一项在**放大**时不该起作用的，可它确实让地面糊掉了。
	#   地面这块平面**永远是放大的**（一格 30 屏幕像素 vs 每格 16 个贴图像素），
	#   所以 `LINEAR`（不带 mipmap）才是对的。
	# ⚠️ 不要改成 `NEAREST`：底色是平坦色块，NEAREST 只会让区划边界出现硬阶跃。
	_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	# ★★ UV 变换 = **恒等**（本轮修掉的一个真 bug：整个地面贴图上下是反的）。
	#
	# ⚠️⚠️ 这里原来写的是 `uv1_scale = (1, -1)` + `uv1_offset = (0, 1)`
	#    （也就是「把 v 翻转一次」），注释还写着「PlaneMesh 的 v 向上 ⇒ 不翻转会上下颠倒」。
	#    **那条注释是错的，翻转才是反的。** 实测（真渲染 + 在贴图上涂不对称记号）：
	#      · 在贴图第 2 行涂一条红 → 屏幕上变红的是**世界第 19 行**；
	#      · 在迷雾贴图第 2 行涂不透明 → 屏幕上变暗的也是**世界第 19 行**。
	#    ⇒ 贴图行号与世界行号是**反**的，把 v 翻回来（恒等）才对。
	#
	#    ★ 为什么一直没被发现：地形底色是**棋盘格 + 平坦色**，上下翻转看不出差别
	#      （实测「同向一致 77 / 反向一致 122」，两种假设都"差不多对"）。
	#      是**区划轮廓**（不规则形状）与**迷雾**（玩家视野的形状）把这件事暴露出来的 ——
	#      用户看到的「迷雾上下反了、区块也反了」就是这一条。
	#
	#    ★ 判据（可复用的那条）：**贴图行号必须与世界行号同向增大**。
	#      要验它，就在贴图上涂一条**不对称的记号**再看屏幕（见
	#      `tests/test_view3d_fog.gd` 的 `_find_marked_row`）。
	_mat.uv1_scale = Vector3(1.0, 1.0, 1.0)
	_mat.uv1_offset = Vector3(0.0, 0.0, 0.0)

	_mesh = MeshInstance3D.new()
	_mesh.name = "GroundMesh"
	_mesh.mesh = plane
	_mesh.material_override = _mat
	# 节点原点落在**图心**（PlaneMesh 以自己为中心展开）
	_mesh.position = palette.to_world(Vector2(float(cols) * 0.5, float(rows) * 0.5))
	add_child(_mesh)

	# ---- 迷雾层：同一块平面、抬高一点点，用一张独立的 alpha 贴图 ----
	var fog_plane := PlaneMesh.new()
	fog_plane.size = plane.size
	_fog_mat = StandardMaterial3D.new()
	_fog_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# ★ 迷雾是**半透明黑**压在地面上 ⇒ 必须开 alpha 混合（不是 scissor：
	#   scissor 会把边缘切成硬齿，而迷雾的边缘本来就该是柔和的）
	_fog_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# ★ 迷雾贴图是「每格 FOG_PX_PER_TILE 像素」的方块数据
	#   （一个纹素约 7.5 屏幕像素）⇒ NEAREST 才是对的：
	#   LINEAR 会在纹素之间插值，把「哪一格有视野」这条**硬边界**糊掉。
	_fog_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# ★★ 与地面层**同一套 UV 变换**（恒等）——两层只要差一点点，
	#   迷雾的边界就会与地块错开（本轮修的就是「翻转」这件事，见 `_mat` 的说明）。
	_fog_mat.uv1_scale = Vector3(1.0, 1.0, 1.0)
	_fog_mat.uv1_offset = Vector3(0.0, 0.0, 0.0)
	# 颜色（含 alpha）来自 config，与 2D 版同一份口径
	_fog_mat.albedo_color = cfg.fog_mask_color
	_fog_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_fog_mesh = MeshInstance3D.new()
	_fog_mesh.name = "FogMesh"
	_fog_mesh.mesh = fog_plane
	_fog_mesh.material_override = _fog_mat
	# ⚠️ 抬高 1.5 个世界单位：不抬会与地面 z-fighting（闪面）
	#    ★ 实测（本轮）：抬高 1.5 之后「迷雾覆盖的格」亮度下降是**均匀**的
	#      ⇒ 不需要按 dev_plan 的猜测抬到 20~50，也不需要用 render_priority。
	_fog_mesh.position = _mesh.position + Vector3(0.0, 1.5, 0.0)
	add_child(_fog_mesh)


## 重烘地面贴图。`force = false` 时只在归属签名变化时重烘。
func rebake(force: bool = false) -> void:
	if world == null or world.map == null or palette == null:
		return
	var sig := _zone_signature()
	if not force and sig == _zone_sig and _tex != null:
		rebake_fog(force)
		return
	_zone_sig = sig
	var cols: int = int(world.map.cols)
	var rows: int = int(world.map.rows)
	_tex = _bake(cols, rows)
	_tex_cols = cols
	_tex_rows = rows
	_mat.albedo_texture = _tex
	bake_count += 1
	rebake_fog(force)


## 重烘迷雾贴图（比地形图便宜得多，但仍然只在掩码真的变了时做）。
##
## ★★ 签名怎么取（这是本函数最容易做错的地方）：掩码是 `cols×rows` 的
##   `PackedByteArray`，逐格比对一次是 O(格数)（594~10000）—— 每帧做一次
##   就是每帧几万次数组访问。所以**抽样**：取 16 个固定格 + 首尾两格，
##   把它们的有视野位拼成一个字符串当签名。
##   ⚠️ 代价是「只在被抽样的那些格上变化」可能漏检（下一次别的格变化会补上）。
##      对「迷雾」这种**大块连续变化**的数据，抽样足够灵敏；
##      真要严格，就得走 `fog.gd` 的版本号（那是 logic 的事，本版不动）。
func rebake_fog(force: bool = false) -> void:
	if world == null or world.map == null or _fog_mat == null:
		return
	if world.fog == null or not cfg.fog_enabled:
		# 没迷雾 / 总开关关掉 ⇒ 整层不可见（与 2D 版的行为一致）
		if _fog_mesh != null:
			_fog_mesh.visible = false
		_fog_sig = ""
		return
	var m = world.map
	var sig := _fog_signature(m.cols, m.rows)
	if not force and sig == _fog_sig:
		return
	_fog_sig = sig
	_fog_tex = _bake_fog(m.cols, m.rows)
	_fog_mat.albedo_texture = _fog_tex
	if _fog_mesh != null:
		_fog_mesh.visible = true
	fog_bake_count += 1


func _fog_signature(cols: int, rows: int) -> String:
	var parts: Array = []
	for i in 16:
		var tx: int = (i * 7) % maxi(1, cols)
		var ty: int = (i * 3) % maxi(1, rows)
		parts.append("1" if world.fog.tile_visible(world.my_faction, tx, ty) else "0")
	parts.append("1" if world.fog.tile_visible(world.my_faction, 0, 0) else "0")
	parts.append("1" if world.fog.tile_visible(world.my_faction, cols - 1, rows - 1) else "0")
	return "".join(parts)


## 烘迷雾贴图：**每格 FOG_PX_PER_TILE 像素**，透明 = 看得见。
##
## ★ 地图外的格子（`exists = false`）一律烘成**透明**：那里本来什么都没有，
##   盖上去只会在屏幕外沿多出一圈方块（2D 版为这条专门写过注释）。
## ★ 用 `fill_rect` 按格刷（而不是逐像素 `set_pixel`）：一格 = 4×4 像素，
##   逐像素写是 16 次调用，`fill_rect` 是 1 次 —— 而且它本来就是**按格**的语义。
func _bake_fog(cols: int, rows: int) -> ImageTexture:
	var k: int = FOG_PX_PER_TILE
	while (cols * k > MAX_TEX_PX or rows * k > MAX_TEX_PX) and k > 1:
		k -= 1
	var img := Image.create(cols * k, rows * k, false, Image.FORMAT_RGBA8)
	var c: Color = cfg.fog_mask_color
	var clear := Color(c.r, c.g, c.b, 0.0)
	var solid := Color(c.r, c.g, c.b, c.a)
	for ty in rows:
		for tx in cols:
			var seen: bool = world.fog.tile_visible(world.my_faction, tx, ty)
			if not world.map.tile_exists(tx, ty):
				seen = true
			img.fill_rect(Rect2i(tx * k, ty * k, k, k), clear if seen else solid)
	return ImageTexture.create_from_image(img)


## 把地形 + 区划归属烘成一张 `cols × rows` 的贴图（每格 `PX_PER_TILE` 像素）。
##
## ★★ 这张图里**只有平坦色块**，没有任何线：
##   网格线、区划轮廓、占领进度条都由 `overlay_view_3d.gd` 在屏幕空间画。
##   为什么（实测）：贴图里的线会被放大成**又宽又淡的糊带** —— 1 像素的线画在
##   16 像素/格的图上、再放大 1.9 倍，就是一条 2 像素的软边；而屏幕空间画的是
##   真正的 1~2 像素硬线。用户的判据是「和看 2D 时一样清晰」，那就必须用 2D 的画法。
##
## ★ 用 `fill_rect` 按格刷（一格的底色是**平的**）：原来逐像素 `set_pixel` 在
##   16 像素/格下是 256 次调用/格，`fill_rect` 只要 1 次。烘图时间从「秒级」降回可忽略。
func _bake(cols: int, rows: int) -> ImageTexture:
	var k: int = PX_PER_TILE
	while (cols * k > MAX_TEX_PX or rows * k > MAX_TEX_PX) and k > 1:
		k -= 1
	var img := Image.create(cols * k, rows * k, false, Image.FORMAT_RGBA8)
	var c_grass: Color = cfg.color("grass")
	var c_grass_alt: Color = cfg.color("grass_alt")
	var c_forest: Color = cfg.color("forest")
	var c_mountain: Color = cfg.color("mountain")
	var c_neutral: Color = cfg.color("zone_neutral")
	baked_tiles = 0
	for ty in rows:
		for tx in cols:
			# ① 地形底色（棋盘格微差：让地块边界看得出来，又不至于像格子纸）
			var kind := String(world.map.terrain.get_cell(tx, ty)) \
				if world.map.terrain.has(tx, ty) else ""
			var c: Color
			match kind:
				"mountain":
					c = c_mountain
				"forest":
					c = c_forest
				_:
					c = c_grass if (tx + ty) % 2 == 0 else c_grass_alt
			# ② 区划归属：**一层半透明的阵营色**压在底色上（不画任何轮廓）
			var z = world.zones.zone_at(tx, ty) if world.zones != null else null
			if z != null:
				var owner := String((z as Dictionary).get("owner", ""))
				if owner != "":
					var oc: Color = cfg.faction_color(owner, "main")
					c = c_lerp(c, oc, 0.22)
				else:
					c = c_lerp(c, c_neutral, 0.18)
			# ③ 地图外的格子（exists = false）烘成**透明**：露出来的是世界背景
			var exists: bool = world.map.tile_exists(tx, ty)
			img.fill_rect(Rect2i(tx * k, ty * k, k, k), c if exists else Color(0, 0, 0, 0))
			baked_tiles += 1
	return ImageTexture.create_from_image(img)


## 归属签名：区块归属（或地块划分）没变就不重烘地面贴图。
##
## ★★ 为什么签名里必须同时有 **owner** 与 **地块数**：
##    · owner 变了 ⇒ 底色要变（区划轮廓由屏幕空间那层自己重算，见 overlay）；
##    · **地块数变了** ⇒ 区划的**边界**变了，而 owner 可能一个字没动
##      （重划战区 / 关卡重置就是这种）。
##    ⚠️ 漏掉地块数会表现成「归属没变所以不重烘，轮廓停在旧形状上」——
##      不报错、只是线画错了，属于本项目最怕的那类静默失败。
func _zone_signature() -> String:
	if world == null or world.zones == null:
		return ""
	var parts: Array = []
	for z in world.zones.zones:
		parts.append("%s:%d" % [String(z["owner"]), int(z.get("tile_count", 0))])
	return "|".join(parts)


# ------------------------------------------------------------------
# 区划的几何查询（**给屏幕空间的画法用**）
# ------------------------------------------------------------------
##
## ★★ 这几个函数原来只服务「烘进贴图」那条路，现在改成服务
##   `overlay_view_3d.gd` 的屏幕空间画法（网格线 / 区划轮廓）。
##   放在这里而不是 overlay 里：它们要读 `world.zones` 与 `world.map`，
##   而 `ground_view` 本来就是「把世界的地面信息翻译给渲染层」的那一层。
##   ⚠️ 它们是**只读**的（不发命令、不改逻辑），与这个文件其余部分同一条纪律。

## 这一格的**哪几条边**是区划边界（位掩码：1=上 2=右 4=下 8=左，0 = 不是边界）。
##
## ★★ 判据是「**四邻里有没有不属于同一区划的**」（不是比 owner）：
##    · 邻格不属于任何区划（无主 / 越界 / 地图外）→ 这条边是边界；
##    · 邻格属于**别的区划**（id 不同）→ 这条边是边界；
##    · 邻格是**同一个区划** → 不是边界。
##
## ★ 为什么用**邻接**而不是「比较 owner」：两个相邻但不同的区划如果恰好都无主，
##   比 owner 会得出「没有边界」，那块地看起来就是糊在一起的一大片 —— 那正是
##   用户报的「看不出属于哪个区划」。（2D 版 `zone_view` 也是按邻接画的。）
func zone_edge_mask(tx: int, ty: int) -> int:
	if world == null or world.zones == null:
		return 0
	var z = world.zones.zone_at(tx, ty)
	var kind := zone_key(z)
	var mask := 0
	if zone_key(world.zones.zone_at(tx, ty - 1)) != kind:
		mask |= 1
	if zone_key(world.zones.zone_at(tx + 1, ty)) != kind:
		mask |= 2
	if zone_key(world.zones.zone_at(tx, ty + 1)) != kind:
		mask |= 4
	if zone_key(world.zones.zone_at(tx - 1, ty)) != kind:
		mask |= 8
	return mask


## 两个地块「算不算同一个区划」的键。
## ⚠️ 无主地块**不给统一的键**：两块都无主的相邻区划仍是**两个**区划，
##    它们之间应当有边界（否则整张图的无主区看起来是一块）。
##    ⇒ 无主时用 `"z<id>"`（区划自己的 id）当键，越界（null）用 ""。
static func zone_key(z) -> String:
	if z == null:
		return ""
	return "z%d" % int((z as Dictionary).get("id", -1))


## 区划轮廓的颜色：**无主 = `colors.zone_stroke`；有主 = 该阵营主色**。
##
## ★ 与 2D 版 `zone_view._stroke_color_owned()` 同一条口径（无主白、有主阵营色）。
## ★★ 这条线是**屏幕空间**画的（`overlay_view_3d._draw_zone_outlines`），
##   所以直接用 config 里那套 `zone_stroke*` 就行 —— 它们本来就是「屏幕像素」口径。
##   ⚠️ 曾经为了「烘进贴图」临时加过一个 `zone_stroke_bake`（按底色压暗的变体），
##     改成屏幕空间之后**已删除**（零引用），别再把它加回来。
func zone_outline_color(z) -> Color:
	if cfg == null:
		return Color(1, 1, 1)
	if z == null:
		return cfg.color("zone_stroke")
	var owner := String((z as Dictionary).get("owner", ""))
	if owner == "":
		return cfg.color("zone_stroke")
	return cfg.faction_color(owner, "main")


## 地形种类的颜色（屏幕空间的网格线不需要它，但 overlay 画底色时可能要用）
func terrain_color_at(tx: int, ty: int) -> Color:
	if world == null or world.map == null:
		return Color.BLACK
	var kind := String(world.map.terrain.get_cell(tx, ty)) \
		if world.map.terrain.has(tx, ty) else ""
	match kind:
		"mountain":
			return cfg.color("mountain")
		"forest":
			return cfg.color("forest")
		_:
			return cfg.color("grass")


static func c_lerp(a: Color, b: Color, t: float) -> Color:
	return a.lerp(b, clampf(t, 0.0, 1.0))
