## unit_sprite_3d.gd —— 程序化生成**兵人立牌贴图**（白剪影 + alpha，阵营色靠逐实例染）
##
## ★★ 为什么是「白剪影 + alpha」而不是「直接画出彩色兵人」（本版的关键取舍）：
##   `MultiMesh` 的合批前提是**所有实例共用同一个 mesh**（= 同一张贴图）。
##   如果每个阵营各烘一张彩色兵人图，就变成「一张贴图一个 draw call」，
##   阵营一多就把合批拆散了。
##   ⇒ 所以贴图里**只放形状与明暗**（白色），颜色由 `MultiMesh.set_instance_color`
##     在运行时乘上去（材质的 `vertex_color_use_as_albedo = true`）。
##   ★ 与 2D 那版「圆盘底走贴图、阵营色走 modulate」是同一个意图换了工具。
##
## ★ 形态：一个**立着的小兵**（头 + 肩 + 躯干 + 两条腿），底边贴地。
##   剪影之外还有一圈深色描边（压在 alpha 边缘），让兵人在任何底色上都看得清 ——
##   这条与 2D 图标「描边区分将领」的口径一致。
##
## ⚠️ 本文件是**纯静态生成**，不持有任何状态、不读 world；缓存按「类型」键。
extends RefCounted

## 贴图像素尺寸（宽 × 高）。64×96 在「一格 128 世界单位」的尺度下足够清晰
const TEX_W := 64
const TEX_H := 96
## 描边宽度（像素）
const OUTLINE_PX := 3.0
## 剪影色（纯白 —— 会被逐实例颜色乘成阵营色）
const BODY_COLOR := Color(1, 1, 1, 1)
## 描边色（深色，压在剪影外缘）
const OUTLINE_COLOR := Color(0.05, 0.05, 0.07, 1.0)
## ★★ 素材版立牌的描边宽度（像素，加在剪影**外侧**）——将领那一档更粗。
##   与程序化那版的 OUTLINE_PX 是同一种单位（64×96 画布上的像素）；
##   素材的剪影更实心，所以数值略收敛。两档的「粗细分档」与 2D 图标
##   （view/unit_icon.gd 的 OUTLINE_W / OUTLINE_W_LEADER）是同一个口径。
const ASSET_OUTLINE_PX := 2.0
const ASSET_OUTLINE_PX_LEADER := 5.0
## 描边不透明度（与 view/unit_icon.gd 的 OUTLINE_ALPHA 同一档）
const OUTLINE_ALPHA := 0.72
## 将领脚下**占位贴花**贴图的边长（像素）
const DECAL_SIZE := 64

static var _cache: Dictionary = {}
## ★★ 素材源图缓存（路径 → Image；**载不到的记 `false` 哨兵**，免得每帧每单位都去 load 一次）。
static var _asset_cache: Dictionary = {}
## 将领脚下占位贴花的缓存（只一张）
static var _decal_cache: ImageTexture = null
## 选中下标（空心圆）贴图的缓存（只一张）
static var _sel_ring_cache: ImageTexture = null


## 取一张兵人贴图。
##
## ★★ 为什么把**阵营色直接烘进贴图**（而不是靠逐实例颜色乘上去）：
##   `MultiMesh` 的所有实例**共用同一个 mesh ⇒ 同一张贴图**。
##   如果贴图是白色、颜色靠 `set_instance_color` 乘，那么
##   「阵营 A 的将领要有粗描边」与「阵营 B 的普通兵要细描边」就**分不开**
##   （将领与普通兵的形状不同 ⇒ 必须两张图 ⇒ 也就没必要再用逐实例染色）。
##   ⇒ 直接按「阵营色 × 是否将领」烘：变体数 = 阵营数 × 2，
##     每种变体一个 MultiMeshInstance3D ⇒ **每种变体只 1 次 draw call**，
##     仍然满足「1000 单位保持合批」的目标（阵营数是个位数）。
##   ⚠️ 烘图有缓存，切换阵营 / 重开一局都不会重复光栅化。
static func bake(faction_color: Color, leader: bool, outline: Color) -> ImageTexture:
	var key := "%s|%d|%s" % [faction_color.to_html(false), 1 if leader else 0,
		outline.to_html(false)]
	var hit: Variant = _cache.get(key, null)
	if hit != null:
		return hit
	var tex := _bake_uncached(leader, faction_color, outline)
	_cache[key] = tex
	return tex


static func clear_cache() -> void:
	_cache = {}
	_asset_cache = {}
	_decal_cache = null
	_sel_ring_cache = null


## 逐像素光栅化：把「兵人剪影」写成一张 RGBA 图。
##
## ★ 用**距离场**（SDF）而不是逐形状画：剪影由若干椭圆/胶囊的并集构成，
##   取最小值就是并集；再用它算抗锯齿与描边。
##   这套做法在本项目里已经用过一次（`view/unit_icon.gd` 的圆盘烘图），
##   直接沿用同一个模式 —— 不引入任何新依赖。
static func _bake_uncached(leader: bool, body: Color, outline: Color) -> ImageTexture:
	var img := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	var parts: Array = _silhouette_parts(leader)
	# 1 像素在「剪影空间」里是多少（剪影空间用 0..1 的归一化坐标，x 居中于 0）
	var px_per_unit := float(TEX_W)
	var rim := OUTLINE_PX / px_per_unit
	for y in TEX_H:
		for x in TEX_W:
			# 归一化到 [-0.5, 0.5] × [0, 1]（y 向上：贴图第 0 行是**顶**，所以翻转）
			var p := Vector2((float(x) + 0.5) / float(TEX_W) - 0.5,
				1.0 - (float(y) + 0.5) / float(TEX_H))
			var d: float = _sdf_union(p, parts)
			var body_cov := clampf(0.5 - d * px_per_unit, 0.0, 1.0)
			var rim_cov := clampf(0.5 - (d * px_per_unit - OUTLINE_PX), 0.0, 1.0)
			var a_rim := clampf(rim_cov - body_cov, 0.0, 1.0)
			# 合成：描边在下、躯体在上（与 2D 图标同一顺序）
			var col := _over(Color(outline.r, outline.g, outline.b, a_rim), Color(0, 0, 0, 0))
			col = _over(Color(body.r, body.g, body.b, body_cov), col)
			img.set_pixel(x, y, col)
	# ★ 朝向：第 0 行是**顶部**，而 QuadMesh 的 UV v=0 也在**顶部**
	#   （实测顶点 (−0.5, 0.5) 的 uv = (0,0)）⇒ **不需要翻转**，兵人就是头朝上。
	#   ⚠️ 这里曾经写过 `flip_y()`（注释误以为 v=0 在底部），那会让兵人**倒过来**。
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------
# ★★ 素材版立牌（本轮新增）：用 `unit.types.<id>.sprite` 的那张占位图当形状
#
# 口径（用户拍板「阵营色剪影」）：
#   · 取素材的**形状**（alpha 当剪影遮罩），填**阵营色** —— 敌我仍然分得清；
#   · 素材**缺失 / 路径为空**时**退回程序化剪影**（`bake()`），
#     所以未知兵种、老地图里的怪 kind 都不会「没图」。
# ★ 与程序化那版共用同一块 QuadMesh / 同一个 shader ⇒ 画布尺寸与**朝向**必须一致
#   （两者都**不翻转**：QuadMesh 的 UV v=0 在**顶部**，见 `_bake_uncached` 的说明）。
# ------------------------------------------------------------------

## 取一张**基于兵种素材**的立牌贴图。
##
## @param path  素材路径（`cfg.unit_sprite_of(unit_type)`；空串 = 没配）
## @param faction_color 阵营主色（烘进剪影 —— MultiMesh 一批共用一张贴图，没法逐实例染色）
## @param leader 将领档（描边更粗）
## @param outline 描边色
## @return 贴图；素材载不到时返回**程序化剪影**（永远不返回 null）
static func bake_asset(path: String, faction_color: Color, leader: bool, outline: Color) -> ImageTexture:
	var src: Image = _load_asset_image(path)
	if src == null:
		return bake(faction_color, leader, outline)
	var key := "%s|%s|%d|%s" % [path, faction_color.to_html(false),
		1 if leader else 0, outline.to_html(false)]
	var hit: Variant = _cache.get(key, null)
	if hit != null:
		return hit
	var tex := _bake_from_image(src, leader, faction_color, outline)
	if tex == null:
		return bake(faction_color, leader, outline)
	_cache[key] = tex
	return tex


## 载入素材源图（路径 → Image），**静态缓存**；载不到返回 null 并记 `false` 哨兵。
##
## ★ 为什么缓存里要能存 `false`：素材一旦缺失就会**每帧每单位**被问一次，
##   不记忆的话就是每帧几千次 `ResourceLoader.exists` + `load`（都白费）。
static func _load_asset_image(path: String) -> Image:
	if path == "":
		return null
	var hit: Variant = _asset_cache.get(path, null)
	if hit != null:
		return hit if hit is Image else null      # false 哨兵 = 已知载不到
	var img: Image = null
	if ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			img = (res as Texture2D).get_image()
	_asset_cache[path] = img if img != null else false
	return img


## 把一张素材图烘成 64×96 立牌：contain-fit（保长宽比）+ 底部对齐 + 阵营色剪影 + 膨胀描边。
static func _bake_from_image(src: Image, leader: bool, body: Color, outline: Color) -> ImageTexture:
	var sw: int = src.get_width()
	var sh: int = src.get_height()
	if sw <= 0 or sh <= 0:
		return null
	# ① contain-fit：整张装得进画布，水平居中、**底部对齐**（脚贴地）
	var scale: float = minf(float(TEX_W) / float(sw), float(TEX_H) / float(sh))
	var tw: int = maxi(1, int(round(float(sw) * scale)))
	var th: int = maxi(1, int(round(float(sh) * scale)))
	var scaled: Image = src.duplicate()
	if scaled.is_compressed():
		scaled.decompress()          # 导入设置可能压过（VRAM 压缩），先解回像素
	scaled.convert(Image.FORMAT_RGBA8)
	if tw != sw or th != sh:
		scaled.resize(tw, th, Image.INTERPOLATE_NEAREST)   # 像素风：硬边更贴素材
	var canvas := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	canvas.blit_rect(scaled, Rect2i(0, 0, tw, th), Vector2i((TEX_W - tw) / 2, TEX_H - th))

	# ② 剪影覆盖率（= 画布 alpha）+ 膨胀（取「环」当描边）
	var cov := PackedFloat32Array()
	cov.resize(TEX_W * TEX_H)
	for y in TEX_H:
		for x in TEX_W:
			cov[y * TEX_W + x] = canvas.get_pixel(x, y).a
	var rim_px: float = ASSET_OUTLINE_PX_LEADER if leader else ASSET_OUTLINE_PX
	var dil := _dilate(cov, TEX_W, TEX_H, int(ceil(rim_px)))

	# ③ 合成：描边在下、阵营色躯体在上（与程序化那版同一顺序）
	var out := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGBA8)
	for y in TEX_H:
		for x in TEX_W:
			var i := y * TEX_W + x
			var body_cov: float = cov[i]
			var ring: float = clampf(dil[i] - body_cov, 0.0, 1.0) * OUTLINE_ALPHA
			var col := _over(Color(outline.r, outline.g, outline.b, ring), Color(0, 0, 0, 0))
			col = _over(Color(body.r, body.g, body.b, body_cov), col)
			out.set_pixel(x, y, col)
	# ★ 朝向：与程序化那版一致 —— QuadMesh 的 UV v=0 在**顶部**（见 `_bake_uncached`），
	#   素材头朝上 = 屏幕头朝上 ⇒ **不需要翻转**。
	return ImageTexture.create_from_image(out)


## 对一张覆盖率图做**可分离**的膨胀（max filter）：先横向、再纵向。
## @return 每个像素在半径 r 邻域内的最大覆盖率（=「向外扩 r 像素」的形状）
static func _dilate(cov: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	if r <= 0:
		return cov.duplicate()
	var tmp := PackedFloat32Array()
	tmp.resize(w * h)
	for y in h:
		for x in w:
			var m := 0.0
			for dx in range(-r, r + 1):
				var xx: int = x + dx
				if xx < 0 or xx >= w:
					continue
				m = maxf(m, cov[y * w + xx])
			tmp[y * w + x] = m
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y in h:
		for x in w:
			var m := 0.0
			for dy in range(-r, r + 1):
				var yy: int = y + dy
				if yy < 0 or yy >= h:
					continue
				m = maxf(m, tmp[yy * w + x])
			out[y * w + x] = m
	return out


# ------------------------------------------------------------------
# 将领脚下的**占位贴花**（本轮新增）
# ------------------------------------------------------------------

## 一张白剪影 + alpha 的**占位贴花**：圆环 + 中心点 + 四向小节点。
## ★ 一张图**复用到任意将领**，运行时靠实例色（阵营色）区分敌我（见 unit_view_3d 的贴花层）。
## ★ 纯静态生成 + 缓存，不读任何状态。
static func decal_texture() -> ImageTexture:
	if _decal_cache != null:
		return _decal_cache
	var n := DECAL_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(n) * 0.5, float(n) * 0.5)
	var r_ring := float(n) * 0.36
	var ring_w := maxf(1.5, float(n) * 0.05)
	var r_dot := float(n) * 0.10
	var node_r := float(n) * 0.075
	for y in n:
		for x in n:
			var pp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var d := (pp - c).length()
			# 圆环：离「半径 r_ring」越近越实（1px 软边）
			var a: float = clampf(ring_w - absf(d - r_ring) + 0.5, 0.0, 1.0)
			# 中心点
			a = maxf(a, clampf(r_dot - d + 0.5, 0.0, 1.0))
			# 四向小节点（东南西北各一个圆点）
			for k in 4:
				var ang := TAU * float(k) / 4.0
				var q := c + Vector2(cos(ang), sin(ang)) * r_ring
				a = maxf(a, clampf(node_r - (pp - q).length() + 0.5, 0.0, 1.0))
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_decal_cache = ImageTexture.create_from_image(img)
	return _decal_cache


## 选中下标用的**空心圆**贴图（白剪影 + alpha）：一个圆环，中间是空的。
## ★ 一张图复用到任意被选中的单位；颜色走材质 uniform（绿），透明度走逐实例数据（动画）。
static func selection_ring_texture() -> ImageTexture:
	if _sel_ring_cache != null:
		return _sel_ring_cache
	var n := DECAL_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(n) * 0.5, float(n) * 0.5)
	var r_ring := float(n) * 0.42
	var half_thick := maxf(1.0, float(n) * 0.045)   # 环的半厚（总厚 ≈ 0.09n）
	for y in n:
		for x in n:
			var d := (Vector2(float(x) + 0.5, float(y) + 0.5) - c).length()
			var a: float = clampf(half_thick - absf(d - r_ring) + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	_sel_ring_cache = ImageTexture.create_from_image(img)
	return _sel_ring_cache


## 兵人剪影的几何（归一化坐标：x ∈ [-0.5, 0.5] 居中，y ∈ [0, 1] 自下而上）
##
## ⚠️ 返回类型必须**显式写 `-> Array`**：调用方写 `var parts := _silhouette_parts(...)`
##    时若推不出类型会直接 Parse Error（本轮第四次踩同类坑）。
static func _silhouette_parts(leader: bool) -> Array:
	var shoulder: float = 0.20 if leader else 0.165
	return [
		_disc(Vector2(0.0, 0.86), 0.115),                        # 头
		_capsule(Vector2(0.0, 0.42), Vector2(0.0, 0.70), shoulder),  # 躯干
		_capsule(Vector2(-shoulder * 0.55, 0.68), Vector2(-shoulder * 1.25, 0.40), 0.055),  # 左臂
		_capsule(Vector2(shoulder * 0.55, 0.68), Vector2(shoulder * 1.25, 0.40), 0.055),    # 右臂
		_capsule(Vector2(-0.085, 0.30), Vector2(-0.105, 0.02), 0.070),  # 左腿
		_capsule(Vector2(0.085, 0.30), Vector2(0.105, 0.02), 0.070),    # 右腿
	] + ([_disc(Vector2(0.0, 0.99), 0.07)] if leader else [])   # 将领：头顶一撮缨


static func _disc(c: Vector2, r: float) -> Dictionary:
	return {"s": "disc", "c": c, "r": r}


static func _capsule(a: Vector2, b: Vector2, r: float) -> Dictionary:
	return {"s": "capsule", "a": a, "b": b, "r": r}


## 一组图元的并集距离场（并集 = 取最小）
static func _sdf_union(p: Vector2, prims: Array) -> float:
	var best := 1.0e9
	for pr in prims:
		var d: float = _sdf(p, pr)
		if d < best:
			best = d
	return best


static func _sdf(p: Vector2, pr: Dictionary) -> float:
	if String(pr.get("s", "disc")) == "capsule":
		var a: Vector2 = pr["a"]
		var b: Vector2 = pr["b"]
		var ab := b - a
		var t: float = clampf((p - a).dot(ab) / maxf(1e-9, ab.length_squared()), 0.0, 1.0)
		return (p - (a + ab * t)).length() - float(pr["r"])
	return p.distance_to(pr.get("c", Vector2.ZERO)) - float(pr["r"])


## 直通 alpha 的「src 盖在 dst 上」
## ⚠️ 不能用 `dst.lerp(src, src.a)`：那会把黑色混进白色剪影边缘（一圈灰边）。
static func _over(src: Color, dst: Color) -> Color:
	var out_a: float = src.a + dst.a * (1.0 - src.a)
	if out_a <= 1e-6:
		return Color(0, 0, 0, 0)
	var k: float = dst.a * (1.0 - src.a)
	return Color(
		(src.r * src.a + dst.r * k) / out_a,
		(src.g * src.a + dst.g * k) / out_a,
		(src.b * src.a + dst.b * k) / out_a,
		out_a)
