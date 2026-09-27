## unit_icon.gd —— 单位在地图上显示的那张 2D 图标（**线条画的「预制体」**）
##
## 需求原话：「为游戏中的这些单位绘制在地图上显示的 2D 图标（你简单用线条绘制成预制体即可，
##            后续再考虑加素材）」+「将将领的描边变粗一点（以此和其他普通单位区分开来）」。
##
## ★★ 为什么是「一份定义 + 烘成贴图」而不是每单位一个场景（Godot 意义上的 prefab）：
##    见 unit_view.gd 文件头那段实测 —— 1000 个单位下，
##      draw_circle ×1000 → 997 个 draw call、18.4 ms（完全不参与合批）；
##      同一张贴图 ×1000 → 1 个批次。
##    所以图标走的是「**静态美术烘成 ImageTexture**」这条路：贴图只跟
##    （单位类型 × 是否将领）有关，一共十来张，游戏里 `draw_texture_rect` 直接贴。
##    将来换上真素材（png / svg）时，只要把 `bake()` 换成 load() 即可 ——
##    调用方（unit_view）读的还是「贴图」这一层，不用改。
##
## ★ 图标空间（下面每一份定义用的坐标）：
##    · 原点 = 单位中心，**1.0 = 单位半径**（也就是 cfg.unit_radius_of(type)）；
##    · +x 向右、+y 向下（与屏幕一致），所以 -y 是单位的「正面」；
##    · 整张图覆盖 [-EXTENT, EXTENT]²，超出去的部分会被裁掉。
##  于是「身体圆盘 = 半径 0.86」意味着它比逻辑半径略小一圈，
##  多出来的那一圈正好留给描边（见 OUTLINE_W / OUTLINE_W_LEADER）。
##
## ★ 两层图元（都用有向距离场画，抗锯齿天然就有了）：
##    · body  —— 白色实体，运行时被阵营色乘出颜色（与旧版那张圆盘贴图同一套染法）；
##    · glyph —— 叠在最上面的深色线条 = 「这是什么兵」的那一笔（枪 / 弓 / 矛 / 叉）。
##   描边不是一层图元，而是 body 的**膨胀环**（sdf - w），所以「描边变粗」= 改一个数。
##
## ⚠️ 图标**不随朝向旋转**（有意）：
##    旋转要么每单位一次 `draw_set_transform`（把批次打散成上千个，等于退回 draw_circle 那条老路），
##    要么把 8 个方向各烘一张图集 —— 两者都不划算，而朝向已经由那条朝向线表达了
##    （见 unit_view 的第 3 遍）。等到有真素材、真要转的时候，走图集那条路。
extends RefCounted

const UnitRes = preload("res://logic/unit.gd")

## 贴图分辨率。屏幕上画出来约 3.2 × 单位半径 ≈ 41 px（格宽 128 时），
## 所以 64 是「够清楚 + 缩放时不糊」的档位。
const TEX_SIZE := 64
## 图标空间半径：1.0 = 单位半径。1.6 刚好装下最长的那一杆枪（枪头到 1.44）。
const EXTENT := 1.6

## 描边：普通单位细、将领粗（需求：将领靠描边与普通单位区分开）。
## 单位是「图标空间」的，也就是**单位半径的倍数** —— 0.16 ≈ 半径的 1/6。
const OUTLINE_W := 0.16
const OUTLINE_W_LEADER := 0.34
const OUTLINE_ALPHA := 0.72
## 兵种线条（glyph）的不透明度：它压在身体与地图上，要够黑才看得出来。
const GLYPH_ALPHA := 0.88


## 一份图标定义的形状（给测试与渲染共用的只读查询）。
## @return {"body": [图元…], "glyph": [图元…]}
##   图元只有两种：
##     {"s": "disc",    "c": Vector2, "r": float}                  —— 实心圆
##     {"s": "capsule", "a": Vector2, "b": Vector2, "r": float}     —— 粗线段（两端是半圆）
## ⚠️ 只支持这两种是**有意的**：它们的距离场各三行，加别的东西（多边形 / 弧线）
##   就得写重心坐标那一套，而这一版是「占位图标，后续再换素材」。
##   弧线（弓）是用三段 capsule 拼的 —— 看着就是一条弯的。
static func icon_def(unit_type: String) -> Dictionary:
	match unit_type:
		UnitRes.UNIT_TYPE_SPEARMAN:
			# 长枪兵：一个圆盘 + 一杆斜跨整个图标的长枪（枪头在左上，最长那一笔）。
			return {
				"body": [_disc(Vector2.ZERO, 0.86)],
				"glyph": [
					_capsule(Vector2(0.66, 1.10), Vector2(-0.72, -1.02), 0.12),
					_disc(Vector2(-0.78, -1.12), 0.20),
				],
			}
		UnitRes.UNIT_TYPE_LONGBOWMAN:
			# 长弓兵（弓箭手 = 远程步兵）：圆盘 + 右侧一张弓（三段折线拼弧）+ 弓弦 + 一支箭。
			return {
				"body": [_disc(Vector2.ZERO, 0.86)],
				"glyph": [
					_capsule(Vector2(0.42, -1.05), Vector2(1.02, -0.40), 0.12),
					_capsule(Vector2(1.02, -0.40), Vector2(1.02, 0.40), 0.12),
					_capsule(Vector2(1.02, 0.40), Vector2(0.42, 1.05), 0.12),
					_capsule(Vector2(0.42, -1.05), Vector2(0.42, 1.05), 0.055),
					_capsule(Vector2(-0.80, 0.0), Vector2(0.80, 0.0), 0.085),
				],
			}
		UnitRes.UNIT_TYPE_RIDER:
			# 骑手（近战骑兵）：从正上方看的一匹马 —— 窄脖子 + 马头探在前（-y 是正面）、
			# 躯干在后、骑手坐在背上，再加一杆长矛。
			# ★ 形状刻意与长枪兵拉开：长枪兵是一个**圆**，骑手是一条**拉长的马身**
			#   （俯视看马就是细长的），远看轮廓就能分清这两类。
			return {
				"body": [
					_capsule(Vector2(0.0, 0.85), Vector2(0.0, -0.50), 0.34),
					_capsule(Vector2(0.0, -0.50), Vector2(0.0, -1.22), 0.21),
					_disc(Vector2(0.0, 0.30), 0.40),
				],
				"glyph": [
					_capsule(Vector2(0.70, 0.95), Vector2(-0.70, -1.15), 0.10),
				],
			}
		UnitRes.KIND_ENEMY:
			# 测试敌人：圆盘 + 一个叉（「这是敌人」的记号）。它不是正式兵种，但同样要有图标。
			return {
				"body": [_disc(Vector2.ZERO, 0.86)],
				"glyph": [
					_capsule(Vector2(-0.62, -0.62), Vector2(0.62, 0.62), 0.11),
					_capsule(Vector2(-0.62, 0.62), Vector2(0.62, -0.62), 0.11),
				],
			}
	# 兜底：一个素圆盘（与改动前那一版长得一样）。
	# ★ 有兜底是有意的 —— 手写地图 / 老快照里出现一个没见过的单位类型时，
	#   它应该画成一个普通单位，而不是让渲染报错或画成空白。
	return {"body": [_disc(Vector2.ZERO, 0.86)], "glyph": []}


## 这个单位类型有没有专属图标（兜底那种不算）。
## ★ 判据是「有没有兵种线条（glyph）」而不是列举类型 id —— 以后加一个兵种只要改 `icon_def()`，
##   不会漏改这里（列举法迟早会漂）。
static func has_icon(unit_type: String) -> bool:
	var def := icon_def(unit_type)
	return not (def["glyph"] as Array).is_empty()


## 描边宽度（图标空间；1.0 = 单位半径）。将领那一档更粗 —— 需求就是靠它区分将领。
static func outline_width(leader: bool) -> float:
	return OUTLINE_W_LEADER if leader else OUTLINE_W


## 烘一张图标贴图。
##
## @param unit_type 单位类型 id（见 config.unit.types）
## @param leader true = 将领那一档（**描边更粗**）
## @return ImageTexture：白色 = 身体（运行时被阵营色乘）、深色 = 描边与兵种线条（乘完仍然深）
##
## ★ 结果是**静态缓存**的：图标只跟（类型 × 是否将领）有关，与阵营 / 位置 / 帧无关。
##   所以同一张图在所有 UnitView 实例之间共用 —— 一局里只烘十张，
##   测试里反复建 view 也不会反复烧 CPU（每次 64×64×图元数的光栅化）。
static var _cache: Dictionary = {}


static func bake(unit_type: String, leader: bool) -> ImageTexture:
	var key := "%s|%d" % [unit_type, 1 if leader else 0]
	var hit: Variant = _cache.get(key, null)
	if hit != null:
		return hit
	var tex := _bake_uncached(unit_type, leader)
	_cache[key] = tex
	return tex


## 清空缓存（测试用：验证「烘出来的图真的随描边粗细变了」时要拿到新图）
static func clear_cache() -> void:
	_cache = {}


static func _bake_uncached(unit_type: String, leader: bool) -> ImageTexture:
	var def := icon_def(unit_type)
	var body: Array = def["body"]
	var glyph: Array = def["glyph"]
	var size := TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# 1 个图标空间单位 = 多少像素
	var px_per_unit := float(size) / (2.0 * EXTENT)
	var rim_w: float = outline_width(leader) * px_per_unit
	for y in size:
		for x in size:
			var p := Vector2(
				(float(x) + 0.5) / px_per_unit - EXTENT,
				(float(y) + 0.5) / px_per_unit - EXTENT
			)
			# 距离场：< 0 在形状内部。乘 px_per_unit 换成像素距离，1px 的抗锯齿带就有了。
			var d_px: float = _sdf_union(p, body) * px_per_unit
			var body_cov := clampf(0.5 - d_px, 0.0, 1.0)
			# 描边 = 把身体向外膨胀 rim_w：落在「膨胀内、身体外」的那一圈
			var rim_cov := clampf(0.5 - (d_px - rim_w), 0.0, 1.0)
			var a_rim := clampf(rim_cov - body_cov, 0.0, 1.0) * OUTLINE_ALPHA
			var a_glyph := 0.0
			if not glyph.is_empty():
				a_glyph = clampf(0.5 - _sdf_union(p, glyph) * px_per_unit, 0.0, 1.0) * GLYPH_ALPHA
			# 合成顺序：描边（黑，底）→ 身体（白，会被阵营色乘）→ 兵种线条（黑，顶）
			var col := _over(Color(0, 0, 0, a_rim), Color(0, 0, 0, 0))
			col = _over(Color(1, 1, 1, body_cov), col)
			col = _over(Color(0.06, 0.06, 0.08, a_glyph), col)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------
# 图元 + 距离场 + 合成
# ------------------------------------------------------------------

static func _disc(c: Vector2, r: float) -> Dictionary:
	return {"s": "disc", "c": c, "r": r}


static func _capsule(a: Vector2, b: Vector2, r: float) -> Dictionary:
	return {"s": "capsule", "a": a, "b": b, "r": r}


## 一组图元的并集距离场（并集 = 取最小）
static func _sdf_union(p: Vector2, prims: Array) -> float:
	var best := 1.0e9
	for pr in prims:
		var d := _sdf(p, pr)
		if d < best:
			best = d
	return best


static func _sdf(p: Vector2, pr: Dictionary) -> float:
	if String(pr.get("s", "disc")) == "capsule":
		var a: Vector2 = pr["a"]
		var b: Vector2 = pr["b"]
		var pa := p - a
		var ba := b - a
		# 参数落在 [0,1] 上：0 = 起点、1 = 终点、中间 = 垂足
		var h := clampf(pa.dot(ba) / maxf(ba.length_squared(), 1e-9), 0.0, 1.0)
		return (pa - ba * h).length() - float(pr["r"])
	return p.distance_to(pr.get("c", Vector2.ZERO)) - float(pr["r"])


## 直通 alpha 的「src 盖在 dst 上」（与 CanvasItem 的默认混合一致）。
## ⚠️ 不能用 `dst.lerp(src, src.a)`：那是把 rgb 按 alpha 插值，
##    在 dst 透明时会把黑色混进白身体里（圆的边缘会出现一圈灰）。
static func _over(src: Color, dst: Color) -> Color:
	var out_a: float = src.a + dst.a * (1.0 - src.a)
	if out_a <= 1e-6:
		return Color(0, 0, 0, 0)
	var k: float = dst.a * (1.0 - src.a)
	var r := (src.r * src.a + dst.r * k) / out_a
	var g := (src.g * src.a + dst.g * k) / out_a
	var b := (src.b * src.a + dst.b * k) / out_a
	return Color(r, g, b, out_a)
