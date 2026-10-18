## touch_controller.gd —— 手机端触摸手势识别（Rusted Warfare 风格）
##
## 职责边界：本文件**只把触摸事件翻成「高层动作」** —— 真正的选中 / 下令 / 框选全在
##   view/input_controller.gd（它仍是「输入 → 命令」的唯一出处），相机平移走 game_scene3d
##   的 CameraFacade。换句话说，这里跟桌面鼠标那条路**共用同一个大脑**，只是换了只手。
##
## 手势（需求原话）：
##   · 单指拖动（起点不在 UI 上）= 拖动视野（抓着地图拖，与鼠标中键拖拽同一手感）；
##   · 单指单击（没怎么动、够快）= 选中 / 下命令（策略见 input_controller.touch_tap）；
##   · 双击 = 行军（attack_move）；
##   · 双指滑动 = 框选，**选框的两个角 = 两指的当前位置**（两指张开 = 放大选框）；
##   · 起点落在 UI 上的一律不算（交给 Godot 的 GUI，判据见 hud.point_hits_ui）。
##
## ★★ 为什么由 game_scene3d 在 **_input**（GUI 之前）里喂事件：
##   手指可能从地图滑到 UI 控件（MOUSE_FILTER_STOP）上，那时触摸事件会被 GUI 吃掉；
##   在 `_input` 里能稳稳拿到全过程。⚠️ 本文件**不 set_input_as_handled** ——
##   让 emulate_mouse_from_touch 产生的模拟鼠标照旧交给 GUI（菜单 / 按钮靠它工作）。
##   模拟鼠标会在 `_unhandled_input` 里被 game_scene3d 丢弃（看 `suppresses_mouse()`），
##   否则一次点击会被「手势 + 输入层」各处理一遍。
##
## ★ 世界坐标一律走 `palette.to_logic()`（「换算只有一处」那条铁律），本文件不自己算投影。
extends RefCounted

const MODE_IDLE := 0
const MODE_HOLD := 1     # 单指按下，还没判定是「点击」还是「拖动视野」
const MODE_PAN := 2
const MODE_BOX := 3
const MODE_DONE := 4     # 这一串触摸已被消化（等手指全部抬起，剩下的手指不再触发点击）

var cfg = null
var palette = null
var input_ctrl = null
var camera_rig = null
## HUD（用来判「起点是不是在 UI 上」）。测试可以传 null —— 那时一律当作「不在 UI 上」。
var hud = null

## touch index -> 屏幕坐标
var _points: Dictionary = {}
var _mode: int = MODE_IDLE
var _started_on_ui: bool = false
var _press_screen: Vector2 = Vector2.ZERO
var _press_ms: int = 0
var _pan_last: Vector2 = Vector2.ZERO
var _box_started: bool = false
## 上一次单击的时间 / 落点（判双击）
var _last_tap_ms: int = -99999999
var _last_tap_screen: Vector2 = Vector2.ZERO
## 最近一次触摸事件的时间（`suppresses_mouse` 的时间窗用它）
var _last_touch_ms: int = -99999999


func setup(p_cfg, p_palette, p_input, p_camera_rig, p_hud = null) -> void:
	cfg = p_cfg
	palette = p_palette
	input_ctrl = p_input
	camera_rig = p_camera_rig
	hud = p_hud
	_points = {}
	_mode = MODE_IDLE
	_started_on_ui = false
	_box_started = false
	_last_tap_ms = -99999999
	_last_tap_screen = Vector2.ZERO
	_last_touch_ms = -99999999


# ------------------------------------------------------------------
# 给 game_scene3d 读的状态
# ------------------------------------------------------------------

## 有没有手指按在屏幕上（game_scene3d 用它**压住边缘滚屏**：手指在屏上时别让镜头被边缘推走）。
func is_active() -> bool:
	return _points.size() > 0


## 现在到达的这个**鼠标事件**是不是由触摸模拟出来的（要丢弃）。
##
## ★★ 必须带**时间窗**，不能只判 `is_active()`：一次很短的点击里，touch 与模拟 mouse
##   往往在同一帧内送达 —— 等处理 mouse 时手指可能已经抬起（`is_active()` 已是 false），
##   只判 is_active 会**漏掉**这一刻，于是同一次点击被走两遍（手势一次 + 输入层一次）。
func suppresses_mouse() -> bool:
	if _points.size() > 0:
		return true
	return (Time.get_ticks_msec() - _last_touch_ms) < int(cfg.touch_mouse_suppress_sec * 1000.0)


# ------------------------------------------------------------------
# 事件入口（由 game_scene3d._input 转发）
# ------------------------------------------------------------------

func handle_touch(event: InputEventScreenTouch) -> void:
	_last_touch_ms = Time.get_ticks_msec()
	if event.pressed:
		_on_press(event)
	else:
		_on_release(event)


func handle_drag(event: InputEventScreenDrag) -> void:
	_last_touch_ms = Time.get_ticks_msec()
	if not _points.has(event.index):
		return
	_points[event.index] = event.position
	match _mode:
		MODE_HOLD:
			# ★★ 单击 vs 拖动：**移动够远**（pan_min_px）**或**按住够久（pan_hold_sec）都进拖动。
			#   这样「快速点击」不会再被手指微动误判成拖视野（时间短 + 移动小 = 单击，见 _maybe_tap）。
			var moved: float = event.position.distance_to(_press_screen)
			var held_ms: int = Time.get_ticks_msec() - _press_ms
			if moved >= cfg.touch_pan_min_px \
					or held_ms >= int(cfg.touch_pan_hold_sec * 1000.0):
				_mode = MODE_PAN
				_pan_last = event.position
				if input_ctrl != null:
					input_ctrl.set_touch_panning(true)
		MODE_PAN:
			var d: Vector2 = event.position - _pan_last
			_pan_last = event.position
			if camera_rig != null:
				# 取负号 = 「抓着地图拖」：手指右移 → 地图跟着右移（相机往左走），与中键拖拽同一手感。
				camera_rig.pan_screen(-d)
		MODE_BOX:
			_update_box()


# ------------------------------------------------------------------
# 按下 / 抬起
# ------------------------------------------------------------------

func _on_press(event: InputEventScreenTouch) -> void:
	_points[event.index] = event.position
	var n: int = _points.size()
	if n == 1:
		_press_screen = event.position
		_press_ms = Time.get_ticks_msec()
		_pan_last = event.position
		_started_on_ui = _point_hits_ui(event.position)
		_mode = MODE_IDLE if _started_on_ui else MODE_HOLD
		_box_started = false
	elif n == 2:
		# 起点在 UI 上 / 这一串已消化：第二指不改变手势。
		if _started_on_ui or _mode == MODE_DONE:
			return
		# ★★ 第二根手指 = **框选**，即使第一根已经在拖视野（两指手势一律框选）。
		#   不停掉拖视野的话：第一指先动超过 pan_min 就进了 MODE_PAN，整段被当成拖视野
		#   —— 这正是「双指时偶发触发平移」的根因。
		if _mode == MODE_PAN and input_ctrl != null:
			input_ctrl.set_touch_panning(false)
		_mode = MODE_BOX
		_box_started = false
	# 3 指及以上：忽略（仍记点，但不改模式）


func _on_release(event: InputEventScreenTouch) -> void:
	_points.erase(event.index)
	match _mode:
		MODE_HOLD:
			if _points.is_empty():
				_maybe_tap(event.position)
				_reset_sequence()
		MODE_PAN:
			if _points.is_empty():
				if input_ctrl != null:
					input_ctrl.set_touch_panning(false)
				_reset_sequence()
		MODE_BOX:
			# 任一手指抬起 = 结束这次框选；剩下的手指不再触发点击。
			if _points.size() < 2:
				if _box_started and input_ctrl != null:
					input_ctrl.touch_box_end()
				_box_started = false
				if _points.is_empty():
					_reset_sequence()
				else:
					_mode = MODE_DONE
		_:
			if _points.is_empty():
				_reset_sequence()


func _reset_sequence() -> void:
	_mode = MODE_IDLE
	_started_on_ui = false
	_box_started = false


# ------------------------------------------------------------------
# 双指框选
# ------------------------------------------------------------------

func _update_box() -> void:
	if input_ctrl == null or _points.size() < 2:
		return
	var rr: Rect2 = _two_finger_screen_rect()
	if not _box_started:
		# 两指张开到阈值才真的开始画框（防止一次两指轻点被当成框选）。
		if rr.size.length() < cfg.touch_box_min_px:
			return
		_box_started = true
	# ★★ 两个角必须取**两根手指自己的位置**，不能取 `rr.position` / `rr.end`
	#   （= 屏幕矩形的左上 / 右下角）。用户报的 bug：「右手在上、左手在下时，
	#   选框的右上角和左下角不跟手，和手指差一截」。
	#
	#   原因：屏幕矩形的左上 / 右下是「x 最小、y 最小」与「x 最大、y 最大」这两个**组合点**，
	#   它们只有在「一根手指在左上、另一根在右下」时才等于手指；一旦是**另一条对角线**
	#   （右上一根、左下一根，x 方向相反），rr.position 落在**左手**、rr.end 落在**右手**，
	#   而屏幕矩形真正属于那两根手指的两个角（右上 / 左下）**从来没有被采集过** ——
	#   把这两点投回地面再投影回来，自然就离手指一截。
	#   ⇒ 直接喂两指本身：`drag_box()` 自己做 `abs()`，于是那两个角正好落在手指上；
	#     另两个角由世界矩形透视投影得到（是个四边形，这是对的，不是 bug）。
	var ps: Array = _first_two_points()
	if ps.size() < 2:
		return
	var wa = _to_world(ps[0])
	var wb = _to_world(ps[1])
	if wa == null or wb == null:
		return
	# ★ 世界矩形负责「框到谁」，屏幕矩形负责「画出来的框」——后者逐像素跟手（见下面注释）。
	input_ctrl.touch_box_set(wa, wb, ps[0], ps[1])


## 前两根手指的屏幕坐标（按按下顺序，最多两个）。
func _first_two_points() -> Array:
	var out: Array = []
	for k in _points.keys():
		out.append(_points[k])
		if out.size() >= 2:
			break
	return out


## 前两个手指在当前屏幕上的外接矩形（选框的两个角 = 两指当前位置）。
func _two_finger_screen_rect() -> Rect2:
	var ps: Array = []
	for k in _points.keys():
		ps.append(_points[k])
		if ps.size() >= 2:
			break
	if ps.size() < 2:
		return Rect2()
	var a: Vector2 = ps[0]
	var b: Vector2 = ps[1]
	return Rect2(a, b - a).abs()


# ------------------------------------------------------------------
# 单击 / 双击
# ------------------------------------------------------------------

func _maybe_tap(screen: Vector2) -> void:
	if input_ctrl == null:
		return
	# 按太久不算点击（UI 上的长按另有用途；地图上按太久也不该突然下命令）。
	if Time.get_ticks_msec() - _press_ms > int(cfg.touch_tap_max_sec * 1000.0):
		return
	# ★★ 移动太大也不算点击：单击 = 「时间短 **且** 移动小」。
	#   移动超过容差、又还没到拖动阈值的这一段，**什么都不做**（绝不误发选中 / 命令）。
	if screen.distance_to(_press_screen) > cfg.touch_tap_max_move_px:
		return
	var world = _to_world(screen)
	if world == null:
		return
	var now: int = Time.get_ticks_msec()
	var is_double: bool = (now - _last_tap_ms) <= int(cfg.touch_double_tap_sec * 1000.0) \
		and screen.distance_to(_last_tap_screen) <= cfg.touch_double_tap_px
	if is_double:
		_last_tap_ms = -99999999     # 消化掉，免得第三次点击又跟第二次配成一次双击
		input_ctrl.touch_double_tap(world)
	else:
		_last_tap_ms = now
		_last_tap_screen = screen
		input_ctrl.touch_tap(world)


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

func _point_hits_ui(screen: Vector2) -> bool:
	if hud == null:
		return false
	return hud.point_hits_ui(screen)


## 屏幕像素 → 世界（格）；打不到地面（相机贴地平线）时返回 null。
func _to_world(screen: Vector2) -> Variant:
	if palette == null:
		return null
	return palette.to_logic(screen)
