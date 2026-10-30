## menu_corner_button.gd —— 主菜单四角的程序化图标按钮（退出 / 载入 / 好友 / 设置）。
##
## 图标全部 draw_* 现画，不用贴图、不用字体：一条 2.4px 的线，悬停时换成
## `accent_bright`，与右上角的退出 X 是同一套画法（退出 X 就是这里的 ICON_CLOSE）。
## 没有底板 / 边框 / 文字，名字只放 tooltip；点击只发 Button 原生 `pressed`，
## 接不接、接到哪，由 main_menu_panel 决定。
##
## ★ 命中区不是整个矩形：控件自己占的是一块贴角的 180×180 方框，只有靠近那个角
##   的三角形才认（`corner_has_point`，与返回/退出按钮同一份判定）；图标画在
##   `icon_rect` 这块 56×56 里。
extends Button

const ThemeRes = preload("res://view/theme.gd")
const LayoutRes = preload("res://view/menu_deck_layout.gd")
const SfxRes = preload("res://view/sfx.gd")

const ICON_CLOSE := 0
const ICON_LOAD := 1
const ICON_FRIENDS := 2
const ICON_SETTINGS := 3

const STROKE := 2.4
## 图标内缩比例：X 沿用历史值 0.28；另三个收到 0.24，小尺寸下齿轮/人形更清楚。
const PAD_CLOSE := 0.28
const PAD_ICON := 0.24

var icon_kind: int = ICON_CLOSE
## 控件贴的是哪个角（决定三角命中区朝哪边）。
var corner: int = LayoutRes.CORNER_TOP_RIGHT
## 图标画在哪（本控件局部坐标里的 56×56）。留空则占满整个控件。
var icon_rect: Rect2 = Rect2()


func setup(p_kind: int = ICON_CLOSE, p_tip: String = "",
		p_corner: int = LayoutRes.CORNER_TOP_RIGHT) -> void:
	icon_kind = p_kind
	corner = p_corner
	text = ""
	focus_mode = Control.FOCUS_NONE
	tooltip_text = p_tip
	# 右上角那只 X 靠 corner_hit 的三角命中区给手型光标；另外三颗自己给，
	# 四个角的手感才一致。
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("normal", empty)
	add_theme_stylebox_override("hover", empty)
	add_theme_stylebox_override("pressed", empty)
	add_theme_stylebox_override("focus", empty)
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	SfxRes.attach(self)


## 图标落位（局部坐标）。四角按钮的控件框是 180×180，图标只占其中 56×56。
func set_icon_rect(r: Rect2) -> void:
	icon_rect = r
	queue_redraw()


## 三角形命中：只有靠近自己那个角的一半算点中。
func _has_point(point: Vector2) -> bool:
	return LayoutRes.corner_has_point(size, corner, point)


## 这一帧图标该不该用亮金。
##   · 桌面：鼠标停上来（`is_hovered()`）；
##   · 移动端：按住（`is_pressed()`）—— 没有悬停这回事，松手就回白。
func is_lit() -> bool:
	return lit_for(is_hovered(), is_pressed(), ThemeRes.hover_enabled())


## 纯函数版本（可测）：有悬停就听 hovered，没有悬停就听 pressed。
static func lit_for(hovered: bool, pressed: bool, hover_on: bool) -> bool:
	return hovered if hover_on else pressed


func _draw() -> void:
	if size.x <= 2.0 or size.y <= 2.0:
		return
	var inner: Rect2 = icon_rect
	if inner.size.x <= 1.0 or inner.size.y <= 1.0:
		inner = Rect2(Vector2.ZERO, size)
	var pad: float = minf(inner.size.x, inner.size.y) \
		* (PAD_CLOSE if icon_kind == ICON_CLOSE else PAD_ICON)
	var box := Rect2(inner.position + Vector2(pad, pad),
		inner.size - Vector2(pad, pad) * 2.0)
	if box.size.x <= 2.0 or box.size.y <= 2.0:
		return
	# ★ 桌面：悬停变亮金。移动端：没有悬停（按下时的模拟 enter 不会再有 exit，
	#   图标会一直亮着），改成**按住才亮** —— 悬停与点击合并成同一个反馈。
	var c: Color = ThemeRes.accent_bright() if is_lit() else ThemeRes.text()
	match icon_kind:
		ICON_LOAD:
			_draw_load(box, c)
		ICON_FRIENDS:
			_draw_friends(box, c)
		ICON_SETTINGS:
			_draw_settings(box, c)
		_:
			_draw_close(box, c)


## 单位坐标（0..1，相对内缩框）→ 像素。
func _u(box: Rect2, x: float, y: float) -> Vector2:
	return box.position + Vector2(x * box.size.x, y * box.size.y)


# ------------------------------------------------------------------
# 四个图标
# ------------------------------------------------------------------

## 退出：一个 X（历史 menu_close_button 的几何与线宽，一点没改）。
func _draw_close(box: Rect2, c: Color) -> void:
	var a := box.position
	var b := box.position + box.size
	draw_line(a, b, c, STROKE, true)
	draw_line(Vector2(b.x, a.y), Vector2(a.x, b.y), c, STROKE, true)


## 载入：上边开口的托盘 + 一根向下扎进去的箭头。
func _draw_load(box: Rect2, c: Color) -> void:
	draw_polyline(PackedVector2Array([
		_u(box, 0.08, 0.46),
		_u(box, 0.08, 1.00),
		_u(box, 0.92, 1.00),
		_u(box, 0.92, 0.46),
	]), c, STROKE, true)
	draw_line(_u(box, 0.50, 0.02), _u(box, 0.50, 0.62), c, STROKE, true)
	draw_polyline(PackedVector2Array([
		_u(box, 0.28, 0.40),
		_u(box, 0.50, 0.63),
		_u(box, 0.72, 0.40),
	]), c, STROKE, true)


## 好友：一大一小两个「头 + 肩」；小的那个在右上、位置更高，读作站得更远。
func _draw_friends(box: Rect2, c: Color) -> void:
	var r: float = minf(box.size.x, box.size.y)
	# 先画远的那个，两条弧和前人的轮廓交叉，交叉处就是前后遮挡。
	draw_arc(_u(box, 0.76, 0.22), r * 0.125, 0.0, TAU, 16, c, STROKE, true)
	draw_arc(_u(box, 0.76, 0.685), r * 0.200, PI, TAU, 20, c, STROKE, true)
	# 近的那个：左下，略大。
	draw_arc(_u(box, 0.40, 0.33), r * 0.175, 0.0, TAU, 24, c, STROKE, true)
	draw_arc(_u(box, 0.40, 0.95), r * 0.300, PI, TAU, 28, c, STROKE, true)


## 设置：齿轮 —— 一圈轮缘 + 8 颗齿 + 中间那个孔。
func _draw_settings(box: Rect2, c: Color) -> void:
	var center: Vector2 = box.position + box.size * 0.5
	var r: float = minf(box.size.x, box.size.y) * 0.5
	var ring: float = r * 0.56
	for i in 8:
		var a: float = TAU * float(i) / 8.0 + PI / 8.0
		var dir := Vector2(cos(a), sin(a))
		draw_line(center + dir * (ring * 0.90), center + dir * (r * 0.97),
			c, STROKE, true)
	draw_arc(center, ring, 0.0, TAU, 40, c, STROKE, true)
	draw_arc(center, r * 0.22, 0.0, TAU, 20, c, STROKE, true)
