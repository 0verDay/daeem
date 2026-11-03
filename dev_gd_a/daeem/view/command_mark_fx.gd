## command_mark_fx.gd —— 右键指令「圆环 + 行军图标」的**共用素材与配色**（纯静态，无状态）
##
## ★★ 为什么单独一个模块（本轮新增，「指定攻击」目标标记）：
##   需求口径是「头顶出现行军的图标（**共用素材**），脚底泛红圈（移动为绿圈、行军为黄圈，
##   可以**复用样式**）」。于是把两张程序化贴图从 `order_flag_view_3d.gd` 挪到这里，
##   全工程**只留一份**：
##     · `march_icon_texture()` —— 插旗杆顶的红色交叉图标 = 指定攻击目标头顶的图标（同一张）；
##     · `ring_texture()`       —— 插旗落地波纹 = 目标脚下的圆环（同一张）。
##   贴图是白剪影 + alpha，颜色由材质 albedo 乘上去 ⇒ 三种指令共用一张图、只换颜色。
##
## ★★ 三种右键指令的**环色只有这一张表**（`ring_color()`）：
##     move（移动）        = render.flag_move_color   （绿）
##     attack_move（行军） = render.flag_attack_color （黄）
##     attack（指定攻击）  = render.attack_mark_ring_color（红）
##   插旗的落地波纹与目标脚下的环都读它 —— 以后调色只改一处，不会「旗子黄了、圈还是绿的」。
##
## ★ 只读 cfg；不碰 world、不建节点；贴图有静态缓存，进程内只烘一次。
##   纯表现：不进快照、不改任何逻辑状态（与 view/ 的既有约定一致）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")

## 图标与圆环贴图的像素边长（正方形；SDF 光栅化，边缘自带抗锯齿）
const TEX_SIZE := 128
## 圆环贴图里圆环的半径（占贴图边长的比例）
const RING_RADIUS_RATIO := 0.42
## 圆环环的半厚（占贴图边长的比例）
const RING_HALF_RATIO := 0.028
## 圆环的软边（像素）
const RING_SOFT_PX := 2.0

## 「行军图标」的**矢量线段**（归一化坐标：x 向右、y 向下，与贴图行方向一致）。
## 两条长对角线 + 下方两端各一条平行短斜线（程序化画出来，不依赖图片素材）。
const ICON_SEGMENTS := [
	[Vector2(0.02, 0.02), Vector2(0.98, 0.98)],
	[Vector2(0.98, 0.02), Vector2(0.02, 0.98)],
	[Vector2(0.04, 0.72), Vector2(0.23, 0.91)],
	[Vector2(0.96, 0.72), Vector2(0.77, 0.91)],
]

## 生成图贴的缓存（线宽 → ImageTexture；圆环只一张）
static var _icon_cache: Dictionary = {}
static var _ring_cache: ImageTexture = null


## 行军图标的贴图：白剪影 + alpha（红色由材质 albedo 乘上去）。
## ★ 四条线段写在 `ICON_SEGMENTS` 里；`stroke_ratio` = 线宽 ÷ 图标边长。
static func march_icon_texture(stroke_ratio: float = 0.05) -> ImageTexture:
	var stroke: float = clampf(stroke_ratio, 0.01, 0.2)
	var key: String = "%.4f" % stroke
	var hit: Variant = _icon_cache.get(key, null)
	if hit != null:
		return hit
	var n := TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half_px: float = maxf(1.0, stroke * float(n) * 0.5)
	for y in n:
		for x in n:
			var pp := Vector2(float(x) + 0.5, float(y) + 0.5)
			var best := 1.0e9
			for seg in ICON_SEGMENTS:
				var sa: Vector2 = seg[0] * float(n)
				var sb: Vector2 = seg[1] * float(n)
				best = minf(best, _segment_dist(pp, sa, sb))
			var a: float = clampf(half_px + 0.5 - best, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


## 圆环的贴图：白圆环 + alpha（颜色由材质 albedo 乘上去）。
static func ring_texture() -> ImageTexture:
	if _ring_cache != null:
		return _ring_cache
	var n := TEX_SIZE
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := Vector2(float(n) * 0.5, float(n) * 0.5)
	var r: float = float(n) * RING_RADIUS_RATIO
	var half_px: float = maxf(1.0, float(n) * RING_HALF_RATIO)
	for y in n:
		for x in n:
			var d: float = (Vector2(float(x) + 0.5, float(y) + 0.5) - c).length()
			var a: float = clampf(
				(half_px + RING_SOFT_PX - absf(d - r)) / RING_SOFT_PX,
				0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	_ring_cache = ImageTexture.create_from_image(img)
	return _ring_cache


## 一条右键指令的**环色**（三种指令共用的唯一一张表；见文件头）。
## ★ `cfg` 为空时用与 config.json 相同的缺省值，方便纯逻辑测试。
static func ring_color(cfg, kind: String) -> Color:
	if String(kind) == "attack_move":
		return ConfigRes.parse_color(_cfg_str(cfg, "render.flag_attack_color", "#e6c200"))
	if String(kind) == "attack":
		return ConfigRes.parse_color(
			_cfg_str(cfg, "render.attack_mark_ring_color", "#e5383b"))
	return ConfigRes.parse_color(_cfg_str(cfg, "render.flag_move_color", "#4cd964"))


## 行军图标的颜色（插旗与「指定攻击」头顶图标**同一个** key）。
static func icon_color(cfg) -> Color:
	return ConfigRes.parse_color(_cfg_str(cfg, "render.order_flag_icon_color", "#e5383b"))


static func _cfg_str(cfg, key: String, fallback: String) -> String:
	if cfg == null:
		return fallback
	return String(cfg.str_val(key, fallback))


## 点到线段的距离（像素空间；带圆头端点的胶囊距离）。
static func _segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var denom: float = ab.length_squared()
	if denom <= 0.0:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / denom, 0.0, 1.0)
	return p.distance_to(a + ab * t)
