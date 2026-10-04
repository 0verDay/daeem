## menu_background.gd —— ★ 进入界面的整页背景：**暗色渐变底 + 金色细线**
##
## 需求（参考图）第一件事就是「暗色色渐变底」。这里把它做成一个 Control：
##   · 竖直渐变（theme.palette 的 bg_top → bg_bottom）—— 上浅下深，像参考图那样；
##   · 正中一团**很淡的金色辉光**（主题的 glow 色），把视线收到标题与徽记上；
##   · 上下各两条**金色细线**（只在中间约 2/3 宽的一条带上），
##     与参考图里标题上下的那两条分隔线是同一种装饰。
##
## ★★ 它同时是**收点击的那一层**（mouse_filter = STOP）—— 这是有意合并的：
##   原实现是一个只会填色的 `ColorRect` 负责收点击，而进入界面的点击必须落在
##   **鼠标下最上层**的那个 Control 上（详见 view/start_screen.gd 文件头那条踩坑记录）。
##   背景既然铺满整页、又在最底层，让它自己接 `gui_input` 就少一个「谁在上谁在下」的问题。
##   ⇒ 换掉它的时候要保住两件事：**铺满整页**、**STOP**。
##
## ★ 纹理只生成一次（`_ready`），之后每帧只是两次 `draw_texture_rect`：
##   画 1920×1080 的渐变如果用 `draw_colored_polygon` 逐条带地画，
##   每帧都要提交上百个顶点；而渐变与辉光**永远不变**，
##   烘成两张小纹理（1×256 与 256×256）是这里最省的做法。
##
## ⚠️ 辉光是**椭圆**（横向拉伸）：屏幕是 16:9，正圆的辉光在宽屏上看着像个小点。
extends Control

const ThemeRes = preload("res://view/theme.gd")

## 竖直渐变的采样数（1×N 的纹理）。256 对 1080 高来说足够平滑 ——
## 渐变本来就是低频的，再多只是浪费内存。
## ⚠️ 形状必须是**宽 1、高 N**：GradientTexture2D 的 `fill_from/fill_to` 是**归一化**坐标，
##   只有「宽 1」时那对坐标才对应一条竖线。边长写成一个数会得到一张 256×256 的方图，
##   `draw_texture_rect` 铺满整页时渐变只剩最上面一小条（其余是纯色）——实测踩过。
const GRADIENT_STEPS := 256
## 辉光纹理的边长（之后被拉伸成椭圆；它也是低频的，尺寸小看不出）。
const GLOW_TEX := 256
## 辉光在屏幕上的**宽度比例**与高度比例（椭圆的长短轴）。
## ★ 高度给得比宽度小：参考图的辉光是横向铺开的，不是一团圆斑。
const GLOW_W_RATIO := 0.78
const GLOW_H_RATIO := 0.62
## 上装饰线离屏幕上边的比例（线在**中间这条带**里，两端不到边）
const RULE_TOP_Y := 0.085
const RULE_INSET := 0.30      # 左右各留 30% 的空白
const RULE_W := 1.0

var _gradient: GradientTexture2D = null
var _glow: ImageTexture = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_gradient()
	_build_glow()


## 竖直渐变底：上 = bg_top（略亮的墨蓝），下 = bg_bottom（近黑）。
## ★ 用 Gradient + GradientTexture2D（宽 1、高 GRADIENT_STEPS）而不是自己算像素：
##   引擎的渐变本来就在线性空间里插值，省掉「手算 sRGB 插值偏亮」这类毛病。
func _build_gradient() -> void:
	var g := Gradient.new()
	# ★ 下端就是 `menu.bg`（页面自己的「整页有多暗」那一档），上端由它向 bg_top 提亮：
	#   这样「底色的深度」只有一个旋钮（menu.bg），theme.palette 那边只管**色相**。
	var base := ThemeRes.menu_bg()
	var lit := ThemeRes.mix(base, ThemeRes.bg_top(), 0.45)
	g.set_color(0, lit)
	g.set_color(1, base)
	# ★ 中间插一个稍暗的停靠点：纯两点线性的渐变在 1080 高上会显得「上半太亮」，
	#   加一个中段之后上半的黑得更快，标题落在那一段上对比度才够。
	g.add_point(0.48, ThemeRes.mix(lit, base, 0.72))
	_gradient = GradientTexture2D.new()
	_gradient.gradient = g
	_gradient.width = 1
	_gradient.height = GRADIENT_STEPS
	_gradient.fill_from = Vector2(0.0, 0.0)
	_gradient.fill_to = Vector2(0.0, 1.0)


## 中心辉光：一张 GLOW_TEX² 的 RGBA 贴图，alpha 从中心向外二次衰减。
## ★ 二次（而不是线性）衰减：线性辉光的边界看得出来，二次的边界融进底色里。
func _build_glow() -> void:
	var img := Image.create(GLOW_TEX, GLOW_TEX, false, Image.FORMAT_RGBA8)
	var base := ThemeRes.glow()
	var c := float(GLOW_TEX) * 0.5
	for y in GLOW_TEX:
		for x in GLOW_TEX:
			var dx: float = (float(x) + 0.5 - c) / c
			var dy: float = (float(y) + 0.5 - c) / c
			var d: float = sqrt(dx * dx + dy * dy)
			var t: float = clampf(1.0 - d, 0.0, 1.0)
			img.set_pixel(x, y, ThemeRes.with_alpha(base, base.a * t * t))
	_glow = ImageTexture.create_from_image(img)


func _draw() -> void:
	if size.x <= 0.0 or size.y <= 0.0:
		return
	# 1) 底：竖直渐变铺满整页
	if _gradient != null:
		draw_texture_rect(_gradient, Rect2(Vector2.ZERO, size), false)
	# 2) 中心的椭圆辉光
	if _glow != null:
		var gw: float = size.x * GLOW_W_RATIO
		var gh: float = size.y * GLOW_H_RATIO
		draw_texture_rect(_glow,
			Rect2(Vector2((size.x - gw) * 0.5, (size.y - gh) * 0.5), Vector2(gw, gh)), false)
	# 3) 装饰细线：**只有顶部那一条**。
	#   ⚠️ 底部那条删掉了（第一版画了两条）：入场页的「点击任意处」提示住在屏幕下方，
	#      一条金线正好横穿那排字 —— 实测截图里两样东西叠在一起，像画坏了。
	#      参考图也只有上边一条横线 + 下边一条**贴着内容宽度**的短线（那是页脚），
	#      而本页的页脚位置被提示文字占了，所以这里只保留顶部那条做「画框」。
	var line_col := ThemeRes.with_alpha(ThemeRes.line(), 0.55)
	var x0: float = size.x * RULE_INSET
	var x1: float = size.x * (1.0 - RULE_INSET)
	draw_line(Vector2(x0, size.y * RULE_TOP_Y), Vector2(x1, size.y * RULE_TOP_Y),
		line_col, RULE_W)
