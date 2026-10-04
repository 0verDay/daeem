## menu_emblem.gd —— 进入界面正中那枚**纯几何**徽记
##
## 需求（参考图）：「纯几何形状组合图标」。参考图那枚是一朵云/冠形的线条标，
## 本工程**不照抄那个造型**（它是别家的 logo），而是用同一套手法做一枚属于本作的：
##   **圆环 + 三角 + 一条中轴** —— 三个基本形状，全部细线、全部金色，
##   与「王朝与帝国：东征」的意象（城郭 / 山关 / 中军）对得上。
##
## ★★ 为什么用 `_draw()` 画而不是做一张 .svg / .png：
##   1. 参考图那套风格要的就是**线**（1~2px）。贴图缩放到别的窗口尺寸会糊、
##      或者需要 9-patch；画出来的线在任何缩放下都是清晰的矢量图形。
##   2. 颜色必须跟着主题走（现在是金，将来改主题要一起变）。画出来的图形**取色于 theme.gd**，
##      贴图做不到「跟着配色变」。
##   3. 项目已经有「不建图片资源」的惯例（HUD 全是 StyleBox + _draw，见 view/minimap.gd）。
##
## ⚠️ 它不吃鼠标（IGNORE）：点击是**整页**收的（见 view/start_screen.gd 文件头）。
## ⚠️ 尺寸由调用方给（`emblem_rect`）；图形按**短边**等比缩放 ⇒ 换个尺寸不用改这里的数。
extends Control

const ThemeRes = preload("res://view/theme.gd")

## 线宽（像素）。参考图的图形线都很细，1.5 是「看得见但不宣布自己」的那一档。
const LINE_W := 1.5
## 外圈圆环的半径占短边的比例
const RING_R := 0.46
## 三角（山关）顶点占短边的比例
const TRI_H := 0.30
const TRI_W := 0.52
## 顶部那条短横（冠）的宽度占短边的比例
const BAR_W := 0.24


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var s: float = minf(size.x, size.y)
	if s <= 8.0:
		return
	var c := Vector2(size.x * 0.5, size.y * 0.5)
	var gold := ThemeRes.accent()
	var gold_dim := ThemeRes.with_alpha(gold, 0.55)
	var gold_soft := ThemeRes.with_alpha(gold, 0.28)

	# 1) 最外那圈很淡的环（参考图里图形之外那一圈微光般的圆）
	draw_arc(c, s * RING_R, 0.0, TAU, 72, gold_soft, LINE_W, true)
	# 2) 主环：金色的细圆
	draw_arc(c, s * (RING_R - 0.10), 0.0, TAU, 72, gold, LINE_W, true)

	# 3) 中轴的三角（山关）：底边在下、顶点朝上，压在圆心上方一点
	var half_w: float = s * TRI_W * 0.5
	var apex := Vector2(c.x, c.y - s * TRI_H)
	var left := Vector2(c.x - half_w, c.y + s * TRI_H * 0.35)
	var right := Vector2(c.x + half_w, c.y + s * TRI_H * 0.35)
	draw_polyline(PackedVector2Array([left, apex, right, left]), gold, LINE_W, true)

	# 4) 顶点之上那条短横（冠）+ 它左右两个点：
	#    纯几何风格里「点 + 横」是最省笔墨的收头，参考图的顶部也是这么收的。
	var top_y: float = c.y - s * (TRI_H + 0.09)
	draw_line(Vector2(c.x - s * BAR_W * 0.5, top_y),
		Vector2(c.x + s * BAR_W * 0.5, top_y), gold, LINE_W, true)
	var dot_r: float = maxf(1.0, s * 0.012)
	draw_arc(Vector2(c.x - s * BAR_W * 0.5, top_y), dot_r, 0.0, TAU, 12, gold, 1.0, true)
	draw_arc(Vector2(c.x + s * BAR_W * 0.5, top_y), dot_r, 0.0, TAU, 12, gold, 1.0, true)

	# 5) 底部的两根短竖（城门 / 台基的暗示）—— 只用直线，不加任何曲线
	var stem_y0: float = c.y + s * (TRI_H * 0.35 + 0.03)
	var stem_y1: float = c.y + s * 0.30
	for dx in [-1.0, 1.0]:
		draw_line(Vector2(c.x + dx * s * 0.11, stem_y0),
			Vector2(c.x + dx * s * 0.11, stem_y1), gold_dim, LINE_W, true)
