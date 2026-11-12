## button_reticle.gd —— ★★ 「瞄准框」悬停 / 按下 / 回声环（画在按钮**上面**的一层）
##
## 为什么单独一层、而且**不**画在 fill_button 的动画器里：
##   动画器是 `show_behind_parent`（画在按钮底纹之下，见 fill_button 文件头），
##   而瞄准框的括号现在画在按钮**内侧** 4px —— 按钮的 normal 底纹是不透明的，
##   画在下面就会被盖住。真实悬停时按钮会切到 `hover_clear` 透明底纹，所以有时看得见、
##   有时看不见（取决于那颗按钮有没有透明 hover 底纹），这正是不能依赖的原因。
##   ⇒ 括号 / 内框 / 回声环单独挂在按钮**上面**（普通子节点，画在父节点之后），
##     只画在四角与边缘，不会盖住居中的文字。
##
## ★ 这一层只读状态、不接输入：`glow` / `press` / `pulse` 由 fill_button 每帧喂。
##   它不认识任何玩法，也不改按钮的 disabled / mouse_filter。
##
## ★ 变量全部是纯数值 → 无头测试可以直接断言（不需要真实像素）。
extends Control

const ThemeRes = preload("res://view/theme.gd")
const ConfigRes = preload("res://logic/config.gd")

## 与 fill_button 的兜底值同源（config 缺键时用）。
const ARM := 14.0
const INSET := 4.0
const WIDTH := 1.5
const ALPHA := 0.85
const UNDERLINE := 0.30
const PULSE_SEC := 0.34

static var _cfg: ConfigRes = null

var host: Control = null
## 悬停强度（0~1）。
var glow: float = 0.0
## 按住进度（0~1）。
var press: float = 0.0
## 回声环进度（0~1）；< 0 = 没在播。
var pulse: float = -1.0
## 宿主的金色填充进度（0~1）：> 0.5 时括号提亮一档，否则压在满金上看不见。
var fill: float = 0.0
## 灰档（禁用 / 强制灰）：括号换灰。
var grey: bool = false
var available: bool = true
## 上一帧真正画过的值（避免每帧无条件重绘）。
var _last: Vector4 = Vector4(-1, -1, -1, -1)
var _last_grey: bool = false
var _last_fill: float = -1.0


static func _num(path: String, fallback: float) -> float:
	if _cfg == null:
		_cfg = ConfigRes.load_default()
	if _cfg == null:
		return fallback
	return _cfg.num(path, fallback)


func setup(p_host: Control) -> void:
	host = p_host
	name = "Reticle"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 普通子节点：绘制排在父节点（底纹 + 文字）**之后**。
	show_behind_parent = false
	z_index = 1


## 每帧由 fill_button 调：只有值变了才重绘。
func sync(p_glow: float, p_press: float, p_pulse: float,
		p_fill: float, p_grey: bool, p_available: bool) -> void:
	glow = p_glow
	press = p_press
	pulse = p_pulse
	fill = p_fill
	grey = p_grey
	available = p_available
	var v := Vector4(glow, press, pulse, 1.0 if available else 0.0)
	if v.is_equal_approx(_last) and grey == _last_grey \
			and is_equal_approx(fill, _last_fill):
		return
	_last = v
	_last_grey = grey
	_last_fill = fill
	queue_redraw()


func _draw() -> void:
	if host == null or not is_instance_valid(host) or not available:
		return
	var w: float = host.size.x
	var h: float = host.size.y
	if w <= 4.0 or h <= 4.0:
		return
	if pulse >= 0.0:
		_draw_pulse(w, h, pulse)
	if glow <= 0.001:
		return
	var t: float = clampf(glow, 0.0, 1.0)
	var p: float = clampf(press, 0.0, 1.0)
	var col: Color = _color()
	var a: float = reticle_alpha() * t
	if a <= 0.004:
		return
	var col_a := Color(col.r, col.g, col.b, a)
	var wide: bool = w >= h * 4.0

	if wide:
		# 列表行：左缘竖条（中间先亮，按下长满）+ 底边细线。
		var bar_h: float = h * lerp(0.42, 0.92, maxf(t, p))
		draw_line(Vector2(2.0, (h - bar_h) * 0.5), Vector2(2.0, (h + bar_h) * 0.5),
			col_a, lerp(2.0, 2.6, p), true)
		var half_w: float = w * underline() * t
		if half_w > 0.5:
			draw_line(Vector2(w * 0.5 - half_w, h - 2.0),
				Vector2(w * 0.5 + half_w, h - 2.0),
				Color(col.r, col.g, col.b, a * 0.7), 1.0, true)
		return

	# 普通按钮：四角括号。inset 从 4 收到 1 = 按下时「扣进去」。
	# ★ 小方块（命令卡 / 科技九宫格 / 设置齿轮等，宽高都 < 96）：
	#   内容贴边（命令卡左上角有键位 Q/W/E，字号 12px、就在 (4,1)），
	#   括号必须**贴着边框画**（inset 1、臂长 10），否则会压在键位字母上。
	var compact: bool = w < 96.0 and h < 96.0
	var base_inset: float = 1.0 if compact \
		else clampf(reticle_gap() + 2.0, 2.0, 8.0)
	var inset: float = lerp(base_inset, 0.5, p)
	var arm_cap: float = minf(reticle_arm(), 10.0) if compact else reticle_arm()
	var arm: float = minf(arm_cap, minf(w, h) * 0.30) * lerp(0.55, 1.0, t)
	var lw: float = lerp(reticle_width(), 2.0, p)
	var x0: float = inset
	var y0: float = inset
	var x1: float = w - inset
	var y1: float = h - inset
	_corner(Vector2(x0, y0), 1.0, 1.0, arm, col_a, lw)
	_corner(Vector2(x1, y0), -1.0, 1.0, arm, col_a, lw)
	_corner(Vector2(x0, y1), 1.0, -1.0, arm, col_a, lw)
	_corner(Vector2(x1, y1), -1.0, -1.0, arm, col_a, lw)
	if p > 0.01:
		draw_rect(Rect2(1.0, 1.0, w - 2.0, h - 2.0),
			Color(col.r, col.g, col.b, 0.28 * p * a), false, 1.0)
	var half: float = w * underline() * t * (1.0 - p * 0.7)
	if half > 0.5:
		draw_line(Vector2(w * 0.5 - half, h - 2.0),
			Vector2(w * 0.5 + half, h - 2.0),
			Color(col.r, col.g, col.b, a * 0.7), 1.0, true)


func _corner(p: Vector2, sx: float, sy: float, arm: float,
		col: Color, lw: float) -> void:
	draw_line(p, p + Vector2(arm * sx, 0.0), col, lw, true)
	draw_line(p, p + Vector2(0.0, arm * sy), col, lw, true)


## 回声环：按钮外沿向外扩，alpha 二次衰减。画在最上层；贴屏幕边缘时自然被裁掉。
func _draw_pulse(w: float, h: float, k: float) -> void:
	var grow: float = 1.5 + 11.0 * clampf(k, 0.0, 1.0)
	var a: float = 0.50 * (1.0 - k) * (1.0 - k)
	var col: Color = ThemeRes.accent_bright()
	draw_rect(Rect2(-grow, -grow, w + grow * 2.0, h + grow * 2.0),
		Color(col.r, col.g, col.b, a), false, 1.0)


func _color() -> Color:
	if grey:
		return ThemeRes.fill_disabled_bottom().lightened(0.4)
	if fill > 0.5:
		# 已经满金的按钮：再亮一档，否则亮金括号压在满金上几乎看不出来。
		return ThemeRes.accent_bright().lightened(0.35)
	return ThemeRes.accent_bright()


static func reticle_arm() -> float:
	return clampf(_num("ui.reticle_arm", ARM), 6.0, 28.0)


static func reticle_gap() -> float:
	# 括号离边框的基准 = 本值 + 2px（默认 2 → 4px）；按下再收到 0.5~1px。
	return clampf(_num("ui.reticle_gap", INSET - 2.0), 0.0, 8.0)


static func reticle_width() -> float:
	return clampf(_num("ui.reticle_width", WIDTH), 1.0, 3.0)


static func reticle_alpha() -> float:
	return clampf(_num("ui.reticle_alpha", ALPHA), 0.1, 1.0)


static func underline() -> float:
	return clampf(_num("ui.reticle_underline", UNDERLINE), 0.0, 0.9)
