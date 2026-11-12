## cursor_view.gd —— 游戏内**自绘主题光标**（F1）
##
## ★★ 为什么不用系统光标：
##   Godot 内置的 `CURSOR_CROSS` / `CURSOR_FORBIDDEN` 只有「十字 / 禁止」两档，
##   和本作的暗金线框风格对不上；而「悬停敌人 = 攻击」这种状态用系统光标表达不了。
##   这里用一颗铺满视口的 `Control` 自己画：金圈 + 状态图标（攻击 / 建造 / 无效 / UI）。
##
## ★ 生命周期：
##   · 只在**真实窗口、非触摸设备**、`ui.custom_cursor = true` 时创建；
##   · 创建时把系统光标设为 `MOUSE_MODE_HIDDEN`，离开窗口 / 结算 / 退出场景时恢复；
##   · 纯表现层：不读鼠标位置（由 `game_scene3d` 每帧喂），不参与任何玩法判定。
##
## ★ 画在独立的 `CanvasLayer`（layer = 100）上，所以永远压在地图与 HUD 之上。
extends Control

const ConfigRes = preload("res://logic/config.gd")

## 主题金（与 `view/ui_style.gd` 的 accent 同源；这里不 preload 那个文件，
## 避免光标层被 UI 主题的初始化顺序绑住）。
const GOLD := Color(0.949, 0.710, 0.267, 1.0)
const RED := Color(0.898, 0.282, 0.302, 1.0)
const DARK := Color(0.03, 0.04, 0.06, 0.82)

var cfg: ConfigRes = null
## "normal" | "attack" | "build" | "invalid" | "order" | "ui"
var mode: String = "normal"
var _scale: float = 1.0
## ★ 按住左键时整颗光标轻微收一下（菜单 / 游戏内共用）——「点到了」的即时反馈。
var _pressed: bool = false
var _press: float = 0.0


func setup(p_cfg: ConfigRes) -> void:
	cfg = p_cfg
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	size = Vector2.ZERO
	z_index = 4096
	_scale = clampf(cfg.num("ui.cursor_scale", 1.0), 0.5, 2.0)


## 覆盖缩放（菜单等其它宿主希望自己的光标略大 / 略小时用）。
## ⚠️ 不能叫 `set_scale`：`Control` 自带 `set_scale(Vector2)`，签名冲突会直接解析失败。
## 上限给到 8：截图 / 规范样张要放大看，运行时只会传 1.0 附近。
func set_cursor_scale(v: float) -> void:
	_scale = clampf(v, 0.5, 8.0)
	queue_redraw()


## 由 `game_scene3d._update_cursor()` 每帧调用：位置用**视口像素**。
func set_cursor_pos(p: Vector2) -> void:
	position = p
	queue_redraw()


func set_mode(m: String) -> void:
	if m == mode:
		return
	mode = m
	queue_redraw()


## 按住 / 松开（由宿主每帧喂；不读输入，保持纯表现层）。
func set_pressed(on: bool) -> void:
	if on == _pressed:
		return
	_pressed = on
	queue_redraw()


func _process(dt: float) -> void:
	var goal: float = 1.0 if _pressed else 0.0
	if is_equal_approx(_press, goal):
		return
	_press = move_toward(_press, goal, dt / 0.07)
	queue_redraw()


func _draw() -> void:
	var s: float = 1.0 - 0.14 * _press
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))
	match mode:
		"ui":
			_draw_arrow()
		"attack":
			_draw_ring(GOLD)
			_draw_cross(GOLD, 4.2, 1.6)
		"build":
			_draw_ring(GOLD)
			_draw_square(GOLD, 3.2)
		"invalid":
			_draw_ring(RED)
			_draw_slash(RED, 5.0, 1.8)
		"order":
			_draw_ring(GOLD)
			_draw_diamond(GOLD, 3.6)
		_:
			_draw_dot()


func _draw_ring(c: Color) -> void:
	var r: float = 7.0 * _scale
	# 先画一圈深色底，保证在浅色地面 / 雪地上也看得见。
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 28, DARK, 3.4 * _scale, true)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 28, c, 1.6 * _scale, true)


## ★ 可交互时的「点」：金圈 + 深色垫底 + 中心实心点。
##
## 比游戏内原来的「暗光小圈 + 1px 点」更实：菜单里的点在文字 / 面板上要一眼能找到，
## 所以中心是**实心金点**（r=2.4），外面一圈深色把点和背景分开，最外才是金环。
func _draw_dot() -> void:
	var s: float = _scale
	draw_circle(Vector2.ZERO, 3.9 * s, DARK)
	draw_circle(Vector2.ZERO, 2.4 * s, GOLD)
	var r: float = 8.2 * s
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, DARK, 2.1 * s, true)
	draw_arc(Vector2.ZERO, r, 0.0, TAU, 32, Color(GOLD.r, GOLD.g, GOLD.b, 0.95), 1.6 * s, true)


func _draw_cross(c: Color, len: float, w: float) -> void:
	var l: float = len * _scale
	var ww: float = w * _scale
	draw_line(Vector2(-l, 0.0), Vector2(l, 0.0), DARK, ww + 1.6, true)
	draw_line(Vector2(0.0, -l), Vector2(0.0, l), DARK, ww + 1.6, true)
	draw_line(Vector2(-l, 0.0), Vector2(l, 0.0), c, ww, true)
	draw_line(Vector2(0.0, -l), Vector2(0.0, l), c, ww, true)


func _draw_slash(c: Color, len: float, w: float) -> void:
	var l: float = len * _scale
	var ww: float = w * _scale
	draw_line(Vector2(-l, l), Vector2(l, -l), DARK, ww + 1.6, true)
	draw_line(Vector2(-l, l), Vector2(l, -l), c, ww, true)


func _draw_square(c: Color, half: float) -> void:
	var h: float = half * _scale
	var pts := PackedVector2Array([
		Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h), Vector2(-h, -h),
	])
	draw_polyline(pts, DARK, 2.6 * _scale, true)
	draw_polyline(pts, c, 1.3 * _scale, true)


func _draw_diamond(c: Color, half: float) -> void:
	var h: float = half * _scale
	var pts := PackedVector2Array([
		Vector2(0.0, -h), Vector2(h, 0.0), Vector2(0.0, h), Vector2(-h, 0.0), Vector2(0.0, -h),
	])
	draw_polyline(pts, DARK, 2.6 * _scale, true)
	draw_polyline(pts, c, 1.3 * _scale, true)


## UI 层用的小箭头：**热点在 (0,0)**（箭头尖），高 18px，主题金 + 深色描边。
##
## ★ 与系统箭头手感对齐：14~18px 是 Windows 默认指针的可见尺寸；
##   比它再小会「找不到鼠标」，再大又会压住按钮文字。
func _draw_arrow() -> void:
	var s: float = _scale
	var pts := PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(0.0, 18.0 * s),
		Vector2(4.4 * s, 13.6 * s),
		Vector2(7.2 * s, 19.4 * s),
		Vector2(10.4 * s, 17.8 * s),
		Vector2(7.6 * s, 12.2 * s),
		Vector2(12.8 * s, 12.2 * s),
	])
	draw_colored_polygon(pts, GOLD)
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, DARK, 1.4 * s, true)
