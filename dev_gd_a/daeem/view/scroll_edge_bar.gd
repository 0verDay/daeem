## scroll_edge_bar.gd —— ★★ 备战页的「风格化滚动条」：一整块金色进度条贴边。
##
## 用户口径（2026.11.16）：
##   「为备战界面做风格化滚动条，具体为一整块金色进度条贴边。」
##
## ★ 它是一根**外置**的滚动条，不画在 `elastic_scroll_list` 里面：
##   · 列表自己左右都有内边距（右面板 16px、左详情 30px），画在列表里会离面板边缘
##     还有一截，看起来像「浮在内容上」；外置之后金条**贴住面板右缘**（用户口径）。
##   · 列表只负责滚动数学（`max_scroll()` / `display_offset()`），本控件只负责
##     「读那两个数 → 画一根金条 + 把拖动换算回偏移」。
##
## ★ 形状：**一整块金色**（没有轨道、没有箭头、没有圆角把手）。
##   贴右边画一条 5px 宽的金条，左侧再压一层很淡的金晕，暗底上能看出边界。
##   松手 / 悬停时金条亮一档（`accent_bright`）。
##
## ★ 拖动：整条命中区宽 `HIT_W`（14px，靠右），比金条宽，方便抓。
##   · 按在**金条上** = 按住滑块拖；
##   · 按在**空白处** = 跳到那个位置再从那里拖（常见滚动条手感）；
##   · 拖动期间偏移由「滑块移动距离 × 内容/轨道比例」换算，和滚轮 / 拖列表共用
##     同一条 `scroll_to()`，所以过拉回弹也照旧。
##
## ★ 只在列表真的能滚（`max_scroll() > 0`）时出现；不能滚就整根隐藏。
extends Control

const ThemeRes = preload("res://view/theme.gd")

## 金条宽度（像素，贴右缘）。
const BAR_W := 5.0
## 命中区宽度（像素）：比金条宽，方便鼠标抓；外置在面板内边距里，不盖住内容。
const HIT_W := 14.0

var _list = null
var _dragging: bool = false
var _drag_start_y: float = 0.0
var _drag_start_offset: float = 0.0
var _hovered: bool = false
var _active: bool = false
var _last_offset: float = -1.0
var _last_max: float = -1.0
var _last_vis: bool = false


func setup() -> void:
	name = "ScrollEdgeBar"
	# ★★ 不靠 `visible` 开关：Godot 不给**隐藏**的 CanvasItem 跑 `_process`，
	#   而这根条一开始是「不能滚 ⇒ 不画」——如果那时把 visible 设成 false，
	#   等到列表变长（能滚了）就再也没有帧去把它打开了（实测：进备战页后
	#   右面板能滚，但金条一直不出现，直到手动拖一下才醒）。
	#   ⇒ 控件常驻可见，由 `_active` 决定「画不画 + 吃不吃鼠标」。
	visible = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## 绑定要驱动的滚动列表（`view/elastic_scroll_list.gd` 或它的子类）。
func bind(list) -> void:
	_list = list
	_update_visibility()
	queue_redraw()


## 现在是不是「能滚、因此显示金条」的状态（测试 / 截图用）。
func is_active() -> bool:
	return _active


func _process(_dt: float) -> void:
	if _list == null or not is_instance_valid(_list):
		return
	var m: float = float(_list.max_scroll())
	var o: float = float(_list.display_offset())
	var vis: bool = _list.is_visible_in_tree()
	# 偏移 / 上限 / 列表显隐变了才重画：这根条在绝大多数帧里是静止的。
	# ★ 显隐也要算进判据：面板打开前列表已经算好高度（偏移与上限都不再变），
	#   只看那两个数的话，页面打开这一帧永远不会把金条「点亮」。
	if not is_equal_approx(m, _last_max) or not is_equal_approx(o, _last_offset) \
			or vis != _last_vis:
		_last_max = m
		_last_offset = o
		_last_vis = vis
		_update_visibility()
		queue_redraw()


func _update_visibility() -> void:
	var on: bool = _list != null and is_instance_valid(_list) \
		and _list.is_visible_in_tree() and float(_list.max_scroll()) > 0.5
	if on != _active:
		_active = on
		# 不能滚时让出整条命中区，否则会白吃掉面板右缘的点击 / 拖拽。
		mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
		if not on:
			_dragging = false
	queue_redraw()


## 视口高度（列表自己可见的那一块）。
func _view_h() -> float:
	if _list == null or not is_instance_valid(_list):
		return 1.0
	return maxf(1.0, float(_list.size.y))


## 内容高度。
func _content_height() -> float:
	if _list == null or not is_instance_valid(_list):
		return 0.0
	return _view_h() + maxf(0.0, float(_list.max_scroll()))


## 越界量（像素）：顶部过拉 = display_offset 的负值；底部过拉 = 超出上限的部分。
## ★ 用 `display_offset()` 而不是逻辑偏移：它已经过橡皮筋阻尼，所以金条的收缩
##   天然是「越拉越紧、松手弹回」的，不需要再叠一条 Tween。
func _overscroll() -> float:
	if _list == null or not is_instance_valid(_list):
		return 0.0
	var d: float = float(_list.display_offset())
	var m: float = float(_list.max_scroll())
	if d < 0.0:
		return -d
	if d > m:
		return d - m
	return 0.0


## 滑块高度：轨道 / 内容占比；**过拉时在拉动的那一端收缩**（最多缩一半）。
##
## ★ 轨道 = 本控件高度（现在铺满面板，见 prepare_panel / prepare_detail_view），
##   所以滚到顶 / 到底时金条能贴住面板的上 / 下边缘。
func _thumb_h() -> float:
	var track: float = maxf(1.0, size.y)
	var vh: float = _view_h()
	var ch: float = maxf(vh, _content_height())
	var base: float = clampf(track * (vh / ch), minf(26.0, track), track)
	var over: float = _overscroll()
	if over <= 0.0:
		return base
	var shrink: float = clampf(over / maxf(vh * 0.18, 1.0), 0.0, 0.5)
	return base * (1.0 - shrink)


## 滑块可以走的距离（轨道 = 本控件高度）。
func _travel() -> float:
	return maxf(0.0, maxf(1.0, size.y) - _thumb_h())


## 当前滑块顶边（相对本控件）。
## ★ 顶部过拉时 t=0、底部过拉时 t=1 ⇒ 收缩永远发生在被拉动的那一端：
##   顶部过拉时底边上移、底边不动；底部过拉时顶边下移、底边不动。
func _thumb_y() -> float:
	if _list == null or not is_instance_valid(_list):
		return 0.0
	var m: float = maxf(0.001, float(_list.max_scroll()))
	var t: float = clampf(float(_list.display_offset()) / m, 0.0, 1.0)
	return t * _travel()


func _draw() -> void:
	if _list == null or not is_instance_valid(_list) or not _active:
		return
	var w: float = size.x
	var y: float = _thumb_y()
	var h: float = _thumb_h()
	var x0: float = w - BAR_W
	var accent: Color = ThemeRes.accent_bright() if (_dragging or _hovered) \
		else ThemeRes.accent()
	# 左侧一层很淡的金晕：让金条和面板暗底之间有一道过渡，不显得是硬贴上去的。
	draw_rect(Rect2(x0 - 4.0, y, BAR_W + 4.0, h), ThemeRes.with_alpha(accent, 0.16), true)
	# 本体：一整块金。
	draw_rect(Rect2(x0, y, BAR_W, h), accent, true)
	# 上下两端的亮线：金条的头尾各压一道更亮的一像素，暗底上更「有金属感」。
	var edge: Color = ThemeRes.with_alpha(ThemeRes.accent_bright(), 0.95)
	draw_rect(Rect2(x0, y, BAR_W, 1.0), edge, true)
	draw_rect(Rect2(x0, y + h - 1.0, BAR_W, 1.0), edge, true)


func _gui_input(event: InputEvent) -> void:
	if not _active or _list == null or not is_instance_valid(_list):
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_dragging = true
			_drag_start_y = mb.global_position.y
			var travel: float = _travel()
			var on_thumb: bool = mb.position.y >= _thumb_y() \
				and mb.position.y <= _thumb_y() + _thumb_h()
			if not on_thumb and travel > 0.0:
				# 按在轨道空白处：先把滑块中心跳到指针位置，再从这里接着拖。
				var t: float = clampf((mb.position.y - _thumb_h() * 0.5) / travel, 0.0, 1.0)
				_list.scroll_to(t * float(_list.max_scroll()))
				_drag_start_y = mb.global_position.y
			_drag_start_offset = clampf(float(_list.logical_offset()), 0.0,
				float(_list.max_scroll()))
			accept_event()
		else:
			_dragging = false
			queue_redraw()
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		var travel: float = _travel()
		if travel > 0.0:
			var ratio: float = float(_list.max_scroll()) / travel
			var want: float = _drag_start_offset \
				+ ((event as InputEventMouseMotion).global_position.y - _drag_start_y) * ratio
			_list.scroll_to(clampf(want, 0.0, float(_list.max_scroll())))
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER:
		_hovered = true
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		_hovered = false
		queue_redraw()
