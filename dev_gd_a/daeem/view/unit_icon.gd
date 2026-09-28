## unit_icon.gd —— 单位在地图上那个图标 = **阵营色圆盘底 + 一个字**
##
## 需求（两轮叠出来的样子）：
##   · 「把游戏内地图上的所有单位图标都改下，改为只显示一个字作为其 2D 图像，
##      这个字也可以在 unit_editor 中编辑」；
##   · 「要保留圆盘底，同时也给将领做圆盘底的描边用于区分」。
## 于是图标 = 圆盘（阵营色，承担「谁的人」）+ 圆盘上那个字（深色，承担「是什么兵」）
## + 圆盘外圈描边（**将领那一档更粗**，「将领和普通兵区分开」那条需求还在）。
##
## ★★ 两条实现路线，为什么各自是现在这样（改这个文件前先读）：
##
##   1. **圆盘底走贴图**（`bake()`，SDF 逐像素光栅化，与 26.x 那一版同一套代码）：
##      只有两张（普通 / 将领），运行时 `draw_texture_rect` + 阵营色 modulate。
##      为什么不 `draw_circle`：实测 1000 单位下 `draw_circle` = **997 个 draw call、18.4 ms**
##      （它完全不参与 2D 合批）；贴图版同贴图的单位合成一个批次。
##
##   2. **那个字走 `draw_char`**（不是烘进上面那张贴图）：
##      动态字体的字形**取不成 Image** —— 实测（Godot 4.7.2 + msyh.ttc，
##      `FontFile.load_dynamic_font` 载入）：
##        `Font.get_glyph_index(64, "枪", 0)` → 7648（找得到）
##        `TextServer.font_get_glyph_texture_idx(rid, Vector2i(64,0), gi)` → **-1**
##        `FontFile.get_texture_image(0, Vector2i(64,0), -1)` → null（引擎日志 `Parameter "fd" is null`）
##      字形是**画的时候才按需光栅化**的，没画过就没有图元可拷。
##      `draw_char` 与区划名字用的 `draw_string` 是同一条路（见 view/zone_view.gd），
##      字形缓存交给引擎 —— 一行也不用我们自己光栅化。
##      ★ 合批：按**字号**分桶（`font_size_for(半径)`，同兵种天然同字号）。
##      ⚠️ 代价：单位数是几十个时看不出来；`tests/bench_fps.gd` 那种 1000 单位的极限场景
##         会比「全贴图」贵。真要回去就得把字预烘成小图集（那时要走 Viewport 烘一次）。
extends RefCounted

## 贴图分辨率。屏幕上画出来约 2 × 单位半径 × EXTENT ≈ 30 px（格宽 128 时），
## 所以 64 是「够清楚 + 缩放时不糊」的档位。
const TEX_SIZE := 64
## 贴图半宽 = 单位半径 × EXTENT。
## ★ 要装得下「圆盘 + 最粗的描边」：0.95 + 0.34 = 1.29 → 1.35 留一点余量
##   （上一版是 1.6，那是为了装下伸到半径之外的枪杆；现在只画圆盘 + 字）。
const EXTENT := 1.35
## 圆盘半径（图标空间；1.0 = 单位半径）。
## ★ 0.95 = 圆盘几乎占满单位半径，多出来的一点点正好留给描边（描边画在圆盘**外侧**）。
##   0.86 那一版圆盘偏小（地图上看着单薄），调到 0.95 之后与「一条枪伸出去」那版
##   的视觉分量接近。
const DISC_R := 0.95

## 描边宽度（图标空间，加在圆盘**外侧**）：普通单位细，将领粗一倍多。
const OUTLINE_W := 0.14
const OUTLINE_W_LEADER := 0.34
const OUTLINE_ALPHA := 0.72

## 字的颜色：深色压在圆盘上（圆盘会被阵营色染，深色字在哪套阵营色上都读得出来）。
const GLYPH_COLOR := Color(0.06, 0.06, 0.08, 0.90)

## 字号 = 单位半径（像素）× FONT_SCALE。
## ★ 1.5 的来历：圆盘直径 = 2 × 0.95 × 半径 = 1.9 半径，而汉字外形约等于自己的 em 方框，
##   所以 1.5 半径的字 ≈ 0.79 × 圆盘直径 —— 字把盘子填满大半、四周还留一圈底色
##   （1.35 那版开窗截图看着字偏小，调到 1.5）。
const FONT_SCALE := 1.5

## 最小字号（像素）：单位半径极小（手改配置写了 0.01）时字也不能缩成看不见的一点。
const MIN_FONT_SIZE := 8


## 描边宽度（图标空间）——将领那一档更粗。
static func outline_w(leader: bool) -> float:
	return OUTLINE_W_LEADER if leader else OUTLINE_W


# ------------------------------------------------------------------
# 圆盘底（贴图；两张，静态缓存）
# ------------------------------------------------------------------

## 取那张圆盘贴图（leader = 将领那一档，描边更粗）。
## ★ 结果是**静态缓存**的：图标只跟「是不是将领」有关，与阵营 / 兵种 / 位置 / 帧无关
##   （阵营色是运行时 modulate 上去的，不烘进图里）。
static var _cache: Dictionary = {}


static func bake(leader: bool) -> ImageTexture:
	var key := "leader" if leader else "troop"
	var hit: Variant = _cache.get(key, null)
	if hit != null:
		return hit
	var tex := _bake_uncached(leader)
	_cache[key] = tex
	return tex


## 清空缓存（测试用：要重新拿一张图时）
static func clear_cache() -> void:
	_cache = {}


static func _bake_uncached(leader: bool) -> ImageTexture:
	var size := TEX_SIZE
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	# 1 个图标空间单位 = 多少像素
	var px_per_unit := float(size) / (2.0 * EXTENT)
	var rim_w: float = outline_w(leader) * px_per_unit
	var body := [_disc(Vector2.ZERO, DISC_R)]
	for y in size:
		for x in size:
			var p := Vector2(
				(float(x) + 0.5) / px_per_unit - EXTENT,
				(float(y) + 0.5) / px_per_unit - EXTENT
			)
			# 距离场：< 0 在形状内部。乘 px_per_unit 换成像素距离，1px 的抗锯齿带就有了。
			var d_px: float = _sdf_union(p, body) * px_per_unit
			var body_cov := clampf(0.5 - d_px, 0.0, 1.0)
			# 描边 = 把圆盘向外膨胀 rim_w：落在「膨胀内、圆盘外」的那一圈
			var rim_cov := clampf(0.5 - (d_px - rim_w), 0.0, 1.0)
			var a_rim := clampf(rim_cov - body_cov, 0.0, 1.0) * OUTLINE_ALPHA
			# 合成顺序：描边（黑，底）→ 圆盘（白，运行时被阵营色乘）
			var col := _over(Color(0, 0, 0, a_rim), Color(0, 0, 0, 0))
			col = _over(Color(1, 1, 1, body_cov), col)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)


# ------------------------------------------------------------------
# 那个字（每帧 draw_char）
# ------------------------------------------------------------------

## 单位半径（像素）→ 字号（像素）。四舍五入到整数：**同字号才能合批**。
static func font_size_for(radius_px: float) -> int:
	return maxi(MIN_FONT_SIZE, int(round(radius_px * FONT_SCALE)))


## 这个单位类型的字（转发 config 的查询 —— 渲染层不认识 config 之外的规则）。
static func char_of(cfg, unit_type: String) -> String:
	if cfg == null:
		return "?"
	return cfg.unit_icon_of(unit_type)


## 一个字的**绘制原点**（draw_char 的原点是基线左端）。
## 水平：按字形宽度居中；竖直：让「上伸 / 下伸」的中线落在中心上（与 Label 的居中同义）。
static func origin_for(font: Font, ch: String, center: Vector2, font_size: int) -> Vector2:
	var ascent: float = font.get_ascent(font_size)
	var descent: float = font.get_descent(font_size)
	var width: float = 0.0
	if ch != "":
		width = font.get_char_size(ch.unicode_at(0), font_size).x
	return Vector2(center.x - width * 0.5, center.y + (ascent - descent) * 0.5)


## 把那个字画在 `center` 上（深色，压在圆盘底上）。
##
## @return 本次发出的 `draw_char` 次数（0 或 1）。
##   ★ 返回值不是装饰：无头测试里 `_draw()` 内部的错误**不会**让测试失败，
##     「一个字都没画」既不报错也不改状态 —— 只有留下一个可数的痕迹才钉得住它
##     （见 docs/pitfalls.md 5.50 与 unit_view.icon_draw_count）。
static func draw_char_at(ci: CanvasItem, font: Font, ch: String, center: Vector2,
		radius_px: float) -> int:
	if font == null or ch == "":
		return 0
	var fsize := font_size_for(radius_px)
	var origin := origin_for(font, ch, center, fsize)
	# ⚠️ 两个 API 的参数类型不一样，别混：`CanvasItem.draw_char` 收的是**字符串**，
	#    而 `Font.get_char_size` 收的是**码点**（int）。
	ci.draw_char(font, origin, ch.substr(0, 1), fsize, GLYPH_COLOR)
	return 1


# ------------------------------------------------------------------
# 距离场 + 合成（圆盘那一张贴图用的；与 26.x 那版同一套）
# ------------------------------------------------------------------

static func _disc(c: Vector2, r: float) -> Dictionary:
	return {"s": "disc", "c": c, "r": r}


## 一组图元的并集距离场（并集 = 取最小）
static func _sdf_union(p: Vector2, prims: Array) -> float:
	var best := 1.0e9
	for pr in prims:
		var d := _sdf(p, pr)
		if d < best:
			best = d
	return best


static func _sdf(p: Vector2, pr: Dictionary) -> float:
	return p.distance_to(pr.get("c", Vector2.ZERO)) - float(pr["r"])


## 直通 alpha 的「src 盖在 dst 上」（与 CanvasItem 的默认混合一致）。
## ⚠️ 不能用 `dst.lerp(src, src.a)`：那是把 rgb 按 alpha 插值，
##    在 dst 透明时会把黑色混进白圆盘里（边缘会出现一圈灰）。
static func _over(src: Color, dst: Color) -> Color:
	var out_a: float = src.a + dst.a * (1.0 - src.a)
	if out_a <= 1e-6:
		return Color(0, 0, 0, 0)
	var k: float = dst.a * (1.0 - src.a)
	var r := (src.r * src.a + dst.r * k) / out_a
	var g := (src.g * src.a + dst.g * k) / out_a
	var b := (src.b * src.a + dst.b * k) / out_a
	return Color(r, g, b, out_a)
