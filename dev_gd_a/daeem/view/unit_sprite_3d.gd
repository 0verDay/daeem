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

static var _cache: Dictionary = {}


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
	# ⚠️ 用 `Image.create` 逐像素写时，第 0 行是**顶部**；而 3D 里 QuadMesh 的
	#    UV v=0 在**底部** ⇒ 需要翻转，否则兵人会**倒过来**。
	img.flip_y()
	return ImageTexture.create_from_image(img)


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
