## press_fx.gd —— **所有按钮统一**的「按下压缩 → 松手回弹」动效
##
## ★★ 为什么用 `button_down` / `button_up`，而不是 `pressed`：
##   Godot 的 Button 默认 `action_mode = ACTION_MODE_BUTTON_RELEASE`（实测值 1），
##   `pressed` 在**松手时**才发。按下阶段只有 `button_down` / `button_up`。
##   （fill_button 的「确认满格」仍走 `pressed`；本文件不抢那条逻辑。）
##
## ★★ 统一接法：
##   `fill_button.attach()` 会自动调用 `PressFx.attach()` ⇒ 所有 Button 共用这一份实现；
##   `menu_chrome` / `start_screen` / `page_tabs` / `command_card` / `tech_grid` /
##   `squad_panel` / `hud` 的设置按钮与设置项都不需要各写一遍。
##   自绘可点控件若要复用，只需 `PressFxRes.attach(control)`，再在按下/抬起时调
##   `PressFxRes.press(control)` / `PressFxRes.release(control)`。
##
## ★ 只改两样东西：
##   · `host.scale` / `host.pivot_offset` —— **纯视觉缩放**，不改 size / position、不进布局；
##   · 本节点自己画的一层亮边（画在按钮边缘外侧一半，尽量不盖住按钮文字）。
##   不碰主题样式、不碰 world、不碰任何玩法状态。
##
## ★ 动效总开关 `ThemeRes.animations_enabled()` 关掉时：
##   不缩放、不播补间；按住只保留静态亮边，松手立刻清掉 —— 仍然是「有反馈」，
##   与 fill_button / panel_expand 的「关掉 = 立刻到位」同一条口径。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")

const META := "press_fx"
const NODE_NAME := "PressFx"

enum Phase { IDLE, DOWN, HELD, UP }

## 配置只读一次（ui.press_* 在运行中不会变；测试也不改盘上的 config）
static var _cfg: ConfigRes = null

var _host: Control = null
var _phase: int = Phase.IDLE
var _t: float = 0.0
var _held: bool = false
var _has_base: bool = false
var _idle_scale: Vector2 = Vector2.ONE
var _idle_pivot: Vector2 = Vector2.ZERO
var _base_scale: Vector2 = Vector2.ONE
var _scale_from: Vector2 = Vector2.ONE
var _edge: float = 0.0
var _edge_px: float = 2.0
var _edge_alpha: float = 0.55
var _brighten_alpha: float = 0.03

## 诊断（只有测试读）
var press_count: int = 0
var press_active: bool = false
var press_held: bool = false
var press_phase_last: int = Phase.IDLE
var press_scale_last: float = 1.0
var press_edge_last: float = 0.0


# ------------------------------------------------------------------
# 配置（缓存；缺字段时回退到常量）
# ------------------------------------------------------------------

static func _config() -> ConfigRes:
	if _cfg == null:
		_cfg = ConfigRes.load_default()
	return _cfg


static func _num(path: String, fallback: float) -> float:
	var c := _config()
	if c == null:
		return fallback
	return c.num(path, fallback)


static func press_scale() -> float:
	return clampf(_num("ui.press_scale", 0.975), 0.90, 1.0)


static func down_sec() -> float:
	return maxf(0.01, _num("ui.press_down_sec", 0.07))


static func release_sec() -> float:
	return maxf(0.01, _num("ui.press_release_sec", 0.16))


static func overshoot() -> float:
	return clampf(_num("ui.press_overshoot", 1.004), 1.0, 1.03)


## 给 fill_button 的「确认满格」用：从当前填充快速补到 100% 的时长 / 满格保持时长。
static func snap_sec() -> float:
	return maxf(0.01, _num("ui.press_snap_sec", 0.07))


static func snap_hold_sec() -> float:
	return maxf(0.0, _num("ui.press_snap_hold_sec", 0.06))


# ------------------------------------------------------------------
# 挂载 / 查询
# ------------------------------------------------------------------

## 给一个 Control 挂上按下动效（幂等；重复调用返回同一个节点）。
static func attach(host: Control) -> Control:
	if host == null:
		return null
	var old: Variant = host.get_meta(META) if host.has_meta(META) else null
	if old != null and is_instance_valid(old):
		return old
	var fx = new()
	fx.name = NODE_NAME
	fx._host = host
	host.add_child(fx)
	fx._setup()
	host.set_meta(META, fx)
	return fx


## 取回 host 上的按下动效（没有 = null）。
static func of(host: Control):
	if host == null or not is_instance_valid(host) or not host.has_meta(META):
		return null
	var v: Variant = host.get_meta(META)
	return v if is_instance_valid(v) else null


## 给自绘可点控件用：按下 / 抬起。
static func press(host: Control) -> void:
	var fx = of(host)
	if fx != null:
		fx.press_now()


static func release(host: Control) -> void:
	var fx = of(host)
	if fx != null:
		fx.release_now()


static func cancel(host: Control) -> void:
	var fx = of(host)
	if fx != null:
		fx.cancel_now()


# ------------------------------------------------------------------
# 生命周期
# ------------------------------------------------------------------

func _setup() -> void:
	name = NODE_NAME
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process(false)
	_edge_px = clampf(_num("ui.press_edge_px", 2.0), 1.0, 4.0)
	_edge_alpha = clampf(_num("ui.press_edge_alpha", 0.55), 0.0, 1.0)
	_brighten_alpha = clampf(_num("ui.press_brighten_alpha", 0.03), 0.0, 0.12)
	_idle_scale = _host.scale
	_idle_pivot = _host.pivot_offset
	if _host is Button:
		var b := _host as Button
		b.button_down.connect(_on_down)
		b.button_up.connect(_on_up)
		b.pressed.connect(_on_confirm)
		b.visibility_changed.connect(_on_visibility_changed)
		b.resized.connect(_on_resized)
	else:
		_host.gui_input.connect(_on_gui_input)


func _on_gui_input(event: InputEvent) -> void:
	if _host == null or not is_instance_valid(_host):
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if (event as InputEventMouseButton).pressed:
			_on_down()
		else:
			_on_up()


func _on_down() -> void:
	if _host == null or not is_instance_valid(_host):
		return
	if _host is Button and (_host as Button).disabled:
		return
	if _held:
		return
	var was_idle: bool = _phase == Phase.IDLE
	_held = true
	press_held = true
	press_active = true
	press_count += 1
	_phase = Phase.DOWN
	_t = 0.0
	_has_base = true
	# ★ 只在真正静息时更新「原位」；如果上一轮回弹还没播完，仍回到最初的原位，
	#   否则连续快速点按会把「过冲后的 1.003」误当成 100%（按钮越点越大）。
	if was_idle:
		_idle_scale = _host.scale
		_idle_pivot = _host.pivot_offset
	_base_scale = _idle_scale
	_host.pivot_offset = _host.size * 0.5
	_scale_from = _host.scale
	_edge = 1.0

	if ThemeRes.animations_enabled():
		# 按下当帧先压一小段：极快的点击也能看到「按下去」这一下
		var immediate: float = lerpf(1.0, press_scale(), 0.35)
		_host.scale = _base_scale * immediate
		_scale_from = _host.scale
		set_process(true)
	else:
		# 关掉动效：不缩放，只保留静态亮边
		_phase = Phase.HELD
		_host.scale = _base_scale
		press_phase_last = _phase
		press_scale_last = 1.0
		press_edge_last = 1.0
	queue_redraw()


func _on_up() -> void:
	if not _held:
		return
	_held = false
	press_held = false
	if not ThemeRes.animations_enabled():
		_finish_instant()
		return
	_phase = Phase.UP
	_t = 0.0
	_scale_from = _host.scale if _host != null and is_instance_valid(_host) else _base_scale
	set_process(true)
	queue_redraw()


func _on_confirm() -> void:
	# 兜底：万一某平台没发 button_up，确认按下时也要收掉按住态
	if _held:
		_on_up()


func _on_visibility_changed() -> void:
	if _host == null or not is_instance_valid(_host):
		return
	# ★ 只看**自己的 visible**：无头测试里根 Window 不可见，
	#   `is_visible_in_tree()` 会一直是 false（会把每一帧都当「被藏起来」）。
	if not _host.visible:
		_cancel()


func _on_resized() -> void:
	if _held and _host != null and is_instance_valid(_host):
		_host.pivot_offset = _host.size * 0.5
		queue_redraw()


func _process(dt: float) -> void:
	if _host == null or not is_instance_valid(_host):
		set_process(false)
		return
	if not _host.visible:
		_cancel()
		return
	if _host is Button and (_host as Button).disabled:
		_cancel()
		return
	if not ThemeRes.animations_enabled():
		_finish_instant()
		return

	_t += dt
	if _phase == Phase.DOWN:
		var k: float = clampf(_t / down_sec(), 0.0, 1.0)
		var target: Vector2 = _base_scale * press_scale()
		_host.scale = _scale_from.lerp(target, _ease_out(k))
		_edge = 1.0
		if k >= 1.0:
			_phase = Phase.HELD
			set_process(false)
	elif _phase == Phase.UP:
		var k: float = clampf(_t / release_sec(), 0.0, 1.0)
		var over: Vector2 = _base_scale * overshoot()
		if k < 0.55:
			_host.scale = _scale_from.lerp(over, _ease_out(k / 0.55))
		else:
			_host.scale = over.lerp(_base_scale, _smooth((k - 0.55) / 0.45))
		_edge = 1.0 - _ease_in(k)
		if k >= 1.0:
			_finish_instant()
			return

	press_phase_last = _phase
	press_scale_last = _host.scale.x / maxf(0.001, _base_scale.x)
	press_edge_last = _edge
	queue_redraw()


func _finish_instant() -> void:
	_edge = 0.0
	_phase = Phase.IDLE
	_restore_host()
	press_active = false
	press_held = false
	press_phase_last = _phase
	press_scale_last = 1.0
	press_edge_last = 0.0
	set_process(false)
	queue_redraw()


func _cancel() -> void:
	_held = false
	_t = 0.0
	_edge = 0.0
	_phase = Phase.IDLE
	_restore_host()
	press_active = false
	press_held = false
	press_phase_last = _phase
	press_scale_last = 1.0
	press_edge_last = 0.0
	set_process(false)
	queue_redraw()


func _restore_host() -> void:
	if _host != null and is_instance_valid(_host) and _has_base:
		_host.scale = _idle_scale
		_host.pivot_offset = _idle_pivot
	_has_base = false


func press_now() -> void:
	_on_down()


func release_now() -> void:
	_on_up()


func cancel_now() -> void:
	_cancel()


# ------------------------------------------------------------------
# 绘制：按钮外缘的亮边 + 极淡的整体提亮
# ------------------------------------------------------------------

func _draw() -> void:
	if _host == null or not is_instance_valid(_host) or _edge <= 0.001:
		return
	if size.x <= 2.0 or size.y <= 2.0:
		return
	# 整体提亮 3%：不改变任何配色，只是「亮起来一点」（方案 A 的「亮度 +3~5%」）
	if _brighten_alpha > 0.0:
		draw_rect(Rect2(Vector2.ZERO, size),
			Color(1.0, 0.955, 0.83, _brighten_alpha * _edge), true)
	# 2px 亮边：一半在按钮内、一半在外 —— 不盖住居中的文字
	var w: float = _edge_px
	var col: Color = ThemeRes.accent_bright()
	var a: float = _edge_alpha * _edge
	var edge_col := Color(col.r, col.g, col.b, a)
	var inset: float = w * 0.5
	draw_rect(Rect2(Vector2(-inset, -inset), size + Vector2(w, w)), edge_col, false, w)


# ------------------------------------------------------------------
# 缓动
# ------------------------------------------------------------------

static func _ease_out(k: float) -> float:
	return 1.0 - (1.0 - k) * (1.0 - k)


static func _ease_in(k: float) -> float:
	return k * k


static func _smooth(k: float) -> float:
	return k * k * (3.0 - 2.0 * k)
