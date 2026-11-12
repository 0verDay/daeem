## menu_cursor.gd —— ★★ 菜单层的自绘光标：**平时是箭头，能点时是点**
##
## 用户口径（2026.11.12）：
##   「把游戏内的光标变化应用到主菜单中，正常情况下需要为鼠标（箭头）而不是一个点，
##     当可以交互时再显示为点。」
##
## ⇒ 菜单里的语义只有两档（游戏内有 attack / build / invalid 等玩法状态，菜单没有）：
##   · "ui"     —— 空白处 / 不可点区域 = **主题金箭头**（热点在尖端，18px）；
##   · "normal" —— 指针下面是**可交互控件** = **金圈 + 中心圆点**。
##
## ★ 与游戏内光标（`view/cursor_view.gd`）共用同一套画法与配色，只是状态映射不同：
##   `game_scene3d._cursor_mode()` 从玩法状态推导，本文件从「鼠标底下是谁」推导。
##
## ★★ 为什么不用系统光标 + `mouse_default_cursor_shape`：
##   1. 系统光标只有箭头 / 手型 / 十字几档，做不出「金圈点」这套主题；
##   2. 主菜单四角的三角命中区、文字按钮等自绘控件的悬停区域与方形控件不一致，
##      系统光标只能跟随 Control 矩形，会在三角命中的空白角上错误地变成手型；
##   3. 用户明确要求「菜单里也能看到游戏内那套光标变化」。
##
## ★ 生命周期（与 `start_screen` 同生共死）：
##   · 创建时**不**动系统光标；`set_active(true)` 才隐藏；
##   · 菜单关闭（进游戏）→ `set_active(false)`，把系统光标还回去；
##   · 窗口失焦 / 指针移出窗口 → 临时还回系统光标（否则桌面会「没有鼠标」）；
##   · 纯表现层：不参与任何点击判定，也不改任何 Control 的 mouse_filter。
##
## ★ 判定「能不能点」的口径（`is_interactive()`，纯函数、可测）：
##   鼠标底下必须是一个**真的会收事件**的 Control（MOUSE_FILTER_STOP），并且
##     · 是 BaseButton 且没被 disabled；或
##     · 自己声明了非箭头光标（`menu_text_button` / 列表行 / 角按钮都这么标）；
##     · 或是文本输入（LineEdit / TextEdit）—— 它们是「能交互」的，只是形状不是手型。
##   这样铺满全屏的遮罩（TransitionShield）不会误判成可点：它的光标形状是箭头。
extends CanvasLayer

const CursorViewRes = preload("res://view/cursor_view.gd")
const ConfigRes = preload("res://logic/config.gd")

## 菜单光标默认缩放：18px 箭头 / 7px 圈，在 1080p 设计空间里与系统指针同量级。
const DEFAULT_SCALE := 1.0

var cfg: ConfigRes = null
var view = null
var _active: bool = false
var _hidden: bool = false
var _inside: bool = false


func setup(p_cfg: ConfigRes) -> void:
	cfg = p_cfg
	name = "MenuCursor"
	# 压在所有菜单层之上（面板 / 退出确认 / 转场黑幕都不该盖住光标）。
	layer = 500
	view = CursorViewRes.new()
	view.name = "Cursor"
	add_child(view)
	view.setup(cfg)
	view.set_cursor_scale(DEFAULT_SCALE * (cfg.num("ui.menu_cursor_scale", 1.0) if cfg != null else 1.0))
	view.visible = false


## 菜单显示 / 隐藏时调用。`false` 一定会把系统光标还回去。
func set_active(on: bool) -> void:
	if _active == on:
		return
	_active = on
	if not on:
		_inside = false
		_set_system_hidden(false)
		if view != null:
			view.visible = false
			view.set_pressed(false)


func is_active() -> bool:
	return _active


## ★ 只有真实窗口 + 非触摸 + 配置打开时才接管系统光标。
##   `ui.custom_cursor = false` 是排查用的总开关：菜单也一起回到系统光标。
static func supported(cfg: ConfigRes) -> bool:
	if cfg == null or not cfg.custom_cursor_enabled:
		return false
	if OS.has_feature("mobile"):
		return false
	return true


func _process(_dt: float) -> void:
	if not _active or view == null:
		return
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var mouse: Vector2 = vp.get_mouse_position()
	var rect := Rect2(Vector2.ZERO, vp.get_visible_rect().size)
	# 失焦 / 移出窗口：把系统光标还回去（与 game_scene3d 同一条口径）。
	var inside: bool = DisplayServer.window_is_focused() and rect.has_point(mouse)
	if inside != _inside:
		_inside = inside
		_set_system_hidden(inside)
		view.visible = inside
		if not inside:
			view.set_pressed(false)
	if not inside:
		return
	view.set_cursor_pos(mouse)
	view.set_mode("normal" if is_interactive(vp.gui_get_hovered_control()) else "ui")
	view.set_pressed(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT))


## 只切一次 `Input.mouse_mode`（每帧切会在窗口边缘抖）。
func _set_system_hidden(hide_it: bool) -> void:
	if hide_it == _hidden:
		return
	_hidden = hide_it
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN if hide_it else Input.MOUSE_MODE_VISIBLE


## ★ 纯判定：这个 Control 值不值得把光标变成「点」。见文件头的口径。
static func is_interactive(c: Control) -> bool:
	if c == null or not is_instance_valid(c):
		return false
	if not c.is_visible():
		return false
	if c.mouse_filter != Control.MOUSE_FILTER_STOP:
		return false
	if c is BaseButton:
		return not (c as BaseButton).disabled
	if c is LineEdit or c is TextEdit:
		return true
	return c.mouse_default_cursor_shape != Control.CURSOR_ARROW
