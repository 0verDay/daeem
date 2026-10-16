## elastic_scroll_list.gd —— 任意长列表的滚动容器（拉过头会弹）
##
## ★ 它解决什么：daeem 现有的列表都是**定长**的（左侧部队列表固定 10 行、
##   详细信息的 3×3 靠滚轮翻页），没有一处装得下「条数不确定」的列表。
##   本控件把这件事补齐：内容自己往下堆，超出的部分可以拖 / 滚，
##   拉过头有阻尼、松手回弹到边界。
##
## ★ 与原生 `ScrollContainer` 的分工（两条路都在，别混着再写第三份）：
##   · `ScrollContainer` —— 引擎自带，有滚动条、**不会越界**；
##     想让它也支持「按住拖动」就挂 `view/drag_scroll_helper.gd`；
##   · 本控件 —— **自己管 clip + 偏移**，换来的是橡皮筋手感（见 `_rubber()`）。
##   要哪一条只看界面需不需要「拉一下再弹回去」这种反馈。
##
## ★ 为什么输入走全局 `_input` 而不是 `gui_input`：
##   列表项多半是 `Button` / `PanelContainer`（`mouse_filter = STOP`），
##   鼠标一动它们就把 `MouseMotion` 吃掉，`gui_input` 根本收不到拖拽。
##   ⇒ 拖拽判在 `_input` 里；一旦确认是滚动手势，就挂一层透明 `_drag_overlay`
##     （`MOUSE_FILTER_STOP`）截住后续事件 —— 否则松手那一下会命中列表里的按钮，
##     「滚一下列表」会顺手点掉一个「加入」。
##
## ★ 手感数值全在 `data/config.json` 的 `ui.scroll_*`（载入时夹取，见 logic/config.gd），
##   本文件不写死任何时长 / 阈值。下面那几个 DEFAULT_ 只用于「配置读不出来」时。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")

## 兜底值（与 config.json 的 ui 段逐位一致）：配置坏了也还能滚。
const DEFAULT_RESISTANCE := 0.55
const DEFAULT_SETTLE_SEC := 0.28
const DEFAULT_DRAG_MIN_PX := 18.0
const DEFAULT_WHEEL_STEP_PX := 60.0
const DEFAULT_ITEM_SEPARATION := 8

## 内容层（允许越界平移的那一层）与真正放子项的容器。
var _content: Control = null
var _vbox: VBoxContainer = null
## 拖动期间挂上来的透明层：拦住子元素的 `gui_input`，防止松手触发按钮。
var _drag_overlay: Control = null

## 逻辑偏移：**允许越界**（< 0 = 顶部过拉、> max_scroll() = 底部过拉）。
## 过拉量在画的时候才被阻尼吃掉（见 `_to_display`），所以拖动手感是「越拉越沉」。
var _logical_offset: float = 0.0
var _pressing: bool = false
var _is_scrolling: bool = false
var _press_y: float = 0.0
var _start_offset: float = 0.0
var _settle_tween: Tween = null

## 手感参数（`_ready()` 时从 config.json 读一次，之后只读）。
var _resistance: float = DEFAULT_RESISTANCE
var _settle_sec: float = DEFAULT_SETTLE_SEC
var _drag_min_px: float = DEFAULT_DRAG_MIN_PX
var _wheel_step_px: float = DEFAULT_WHEEL_STEP_PX


func _ready() -> void:
	clip_contents = true                              # 「滚动」的本质就是裁掉溢出部分
	mouse_filter = Control.MOUSE_FILTER_STOP          # 接住滚轮（拖动那条走全局 _input）
	_load_tunables()

	_content = Control.new()
	_content.name = "_content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)

	_vbox = VBoxContainer.new()
	_vbox.name = "_vbox"
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", DEFAULT_ITEM_SEPARATION)
	_content.add_child(_vbox)

	# 内容高度 / 视口高度一变就要重排（重排里会顺便把越界偏移夹回合法区间）。
	resized.connect(_schedule_layout)
	_vbox.minimum_size_changed.connect(_schedule_layout)


func _load_tunables() -> void:
	var cfg = ConfigRes.load_default()
	if cfg == null:
		# 配置读不出来（ConfigRes 自己已经 push_error 过了）：留着与 JSON 一致的兜底值，
		# 列表仍然能滚 —— 这里不该再 push 一次把日志刷花。
		return
	_resistance = cfg.scroll_resistance
	_settle_sec = cfg.scroll_settle_sec
	_drag_min_px = cfg.scroll_drag_min_px
	_wheel_step_px = cfg.scroll_wheel_step_px


# ------------------------------------------------------------------
# 公开 API
# ------------------------------------------------------------------

## 返回内部 VBoxContainer：调用方往它里面 `add_child()` 添加列表项。
func get_content_box() -> VBoxContainer:
	return _vbox


## 列表项间距（像素）。
func set_item_separation(px: int) -> void:
	if _vbox != null:
		_vbox.add_theme_constant_override("separation", px)


## 当前逻辑偏移（**可越界**：负 = 顶部过拉）。
func logical_offset() -> float:
	return _logical_offset


## 实际画出来的偏移（过拉部分已被阻尼吃掉）。
func display_offset() -> float:
	return _to_display(_logical_offset)


## 内容还能往下滚多少（内容比视口矮时 = 0）。
func max_scroll() -> float:
	if _content == null:
		return 0.0
	return maxf(0.0, _content.size.y - size.y)


## 跳到某个逻辑偏移。允许给越界值（与拖动走同一条路径），越界部分照样被阻尼。
func scroll_to(logical: float) -> void:
	_logical_offset = logical
	_apply_offset()


# ---- 手感参数的只读读法（测试与排查用；也说明这几个数从哪来）----

func resistance() -> float:
	return _resistance


func settle_sec() -> float:
	return _settle_sec


func drag_min_px() -> float:
	return _drag_min_px


func wheel_step_px() -> float:
	return _wheel_step_px


# ------------------------------------------------------------------
# 布局
# ------------------------------------------------------------------

func _schedule_layout() -> void:
	call_deferred("_do_layout")


func _do_layout() -> void:
	if not is_instance_valid(_vbox) or not is_instance_valid(_content):
		return
	var content_h := maxf(_vbox.get_combined_minimum_size().y, size.y)
	_content.size = Vector2(size.x, content_h)
	_vbox.size = _content.size
	# 内容变矮（或视口变高）之后原来的偏移可能已经越界，夹回来。
	_logical_offset = clampf(_logical_offset, 0.0, max_scroll())
	_apply_offset()


# ------------------------------------------------------------------
# 滚动数学
# ------------------------------------------------------------------

## 逻辑偏移 → 画面偏移：中间那段 1:1，两端各走一次阻尼。
func _to_display(logical: float) -> float:
	var limit := max_scroll()
	if logical < 0.0:
		return -_rubber(-logical)
	if logical > limit:
		return limit + _rubber(logical - limit)
	return logical


## 橡皮筋阻尼：`f(x) = (x·c·d)/(d + c·x)`。
## x 越小越接近 x（跟手），x 越大被吃掉的比例越多（越拉越沉）——
## 这就是「拉到底还有一点点余量、但怎么拉都拉不远」的来源。
## 分母恒 > 0（d = 视口高，至少 1），所以这个式子不会爆。
func _rubber(x: float) -> float:
	var d := maxf(1.0, size.y)
	return (x * _resistance * d) / (d + _resistance * x)


func _apply_offset() -> void:
	if _content == null:
		return
	_content.position.y = -_to_display(_logical_offset)


func _scroll_by(dy: float) -> void:
	_logical_offset += dy
	_apply_offset()


# ------------------------------------------------------------------
# 拖动遮罩（拖动确认后挂，防止松手命中列表项里的按钮）
# ------------------------------------------------------------------

func _attach_drag_overlay() -> void:
	if is_instance_valid(_drag_overlay):
		return
	_drag_overlay = Control.new()
	_drag_overlay.name = "_drag_overlay"
	_drag_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_drag_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_drag_overlay.z_index = 100
	add_child(_drag_overlay)


func _remove_drag_overlay() -> void:
	if is_instance_valid(_drag_overlay):
		_drag_overlay.queue_free()
	_drag_overlay = null


# ------------------------------------------------------------------
# 回弹
# ------------------------------------------------------------------

## 把越界的偏移送回合法区间。
## ★ 动效总开关关掉（或回弹时长为 0）时**直接就位、不建 Tween** ——
##   与 view/fill_button.gd 同一条口径：关掉动效是「立刻到位」，不是「没有反馈」。
func _settle_to_clamped() -> void:
	_kill_settle_tween()
	var target := clampf(_logical_offset, 0.0, max_scroll())
	if absf(target - _logical_offset) < 0.5 or _settle_sec <= 0.0 or not ThemeRes.animations_enabled():
		_logical_offset = target
		_apply_offset()
		return
	_settle_tween = create_tween()
	_settle_tween.tween_method(_set_logical_offset, _logical_offset, target, _settle_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _set_logical_offset(v: float) -> void:
	_logical_offset = v
	_apply_offset()


func _kill_settle_tween() -> void:
	if _settle_tween != null and _settle_tween.is_valid():
		_settle_tween.kill()
	_settle_tween = null


# ------------------------------------------------------------------
# 输入（全局 _input：绕开子元素的 STOP filter）
# ------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# 隐藏时一概不管 —— 否则藏在别的面板底下 / 已关掉的列表照样吃滚轮，
	# 表现为「鼠标划过某片空白区域时地图缩放失效」。
	if not is_visible_in_tree():
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		if mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			# 内容没超出视口就整件事与它无关（别把滚轮吃掉，留给下层）。
			if not mb.pressed or not get_global_rect().has_point(mb.global_position) or max_scroll() <= 0.0:
				return
			_kill_settle_tween()
			_scroll_by(-_wheel_step_px if mb.button_index == MOUSE_BUTTON_WHEEL_UP else _wheel_step_px)
			_settle_to_clamped()
			get_viewport().set_input_as_handled()
			return

		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 内容没超出视口时**不接管左键**：否则拖一下列表会把下层的地图框选吃掉。
				if get_global_rect().has_point(mb.global_position) and max_scroll() > 0.0:
					_pressing = true
					_is_scrolling = false
					_press_y = mb.global_position.y
					_start_offset = _logical_offset
					_kill_settle_tween()
			elif _pressing:
				# 抬起：不管光标在哪都结束追踪（拖到控件外松手也要能回弹）。
				if _is_scrolling:
					_settle_to_clamped()
					get_viewport().set_input_as_handled()
				_remove_drag_overlay()
				_pressing = false
				_is_scrolling = false

	elif event is InputEventMouseMotion and _pressing:
		var dy := (event as InputEventMouseMotion).global_position.y - _press_y
		if not _is_scrolling and absf(dy) >= _drag_min_px:
			_is_scrolling = true
			_attach_drag_overlay()
		if _is_scrolling:
			_logical_offset = _start_offset - dy
			_apply_offset()
			get_viewport().set_input_as_handled()
