## campaign_carousel.gd —— 战役菜单左侧那条**战役竖向轮播**（样式移植自 nsoc 的
## `scripts/ui/campaign_carousel.gd`）
##
## 做法（与 nsoc 逐条一致，只把配色换成本作的暗金）：
##   · 自己是裁剪容器（`clip_contents = true`），尺寸跟着父面板；
##   · 里面固定 3 个等高占位 page（prev / current / next），track 任意时刻位移 -page_h，
##     使 `_pages[1]` 正好盖住可视区 ⇒ 「循环」不需要真的建 N 个节点；
##   · 拖动时实时改 track.position.y；松手后：
##       |dy| ≥ SNAP_RATIO × page_h → 吸附翻页（0.18s 补间）
##       |dy| <  阈值               → 回弹
##     补间完成后重排索引并把 track 复位，视觉无缝；
##   · 每张卡片底部 25% 一条**渐变遮罩**，压着「战役名 + 简介」（见 DescMask）。
##
## ★★ 与 nsoc 的差别只有「颜色从哪来」：那边写死白底 / 深灰字，这边全部走
##   `view/theme.gd` + `view/menu_theme.gd`（暗金线框），与主界面是同一套皮肤。
##   ⇒ 要改观感只改主题色，**不要在文件里写第二组颜色**。
##
## ★ 数据由调用方（`view/campaign_menu.gd`）传进来，本文件**不读盘**：
##   一处加载、一处排序，界面与「长按进入时用的那一项」才不会漂成两份。
extends Control

## 翻页完成（当前战役变了）后发出，参数 = 新的下标。
signal current_campaign_changed(index: int)

## 拖动 / 回弹 / snap 期间持续发出，progress ∈ [-1, 1]：
##   0 = 完全停在当前页；±1 = 已达到 snap 阈值。供章节圆点做渐隐。
signal drag_progress(progress: float)

const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

const SNAP_RATIO: float = 0.25
const TWEEN_DURATION: float = 0.18
const DRAG_THRESHOLD_PX: float = 8.0
const PAGE_GAP_PX: float = 24.0
const PAGE_MARGIN_X: float = 16.0
const PAGE_MARGIN_Y: float = 16.0

## 遮罩内顶部「战役名」区域所占高度比例（剩余给简介）。
const NAME_HEIGHT_RATIO: float = 0.42
## 描述遮罩占 page 底部高度比例。
const DESC_MASK_RATIO: float = 0.25
const DESC_MASK_CORNER_RADIUS: float = 20.0
const DESC_MASK_CORNER_SEGMENTS: int = 12

const TEXT_PAD_LEFT: float = 16.0
const TEXT_PAD_RIGHT: float = 12.0
const TEXT_PAD_TOP: float = 8.0
const TEXT_PAD_BOTTOM: float = 8.0

const DESC_PLACEHOLDER: String = "暂无描述"


## 卡片底部的渐变遮罩（纯自绘：圆角 + 自上而下的 alpha 渐变）。
##
## ★ 为什么不直接铺一块半透明 ColorRect：卡片圆角是 2px，ColorRect 是直角，
##   压在卡片底部会在下缘露出两个尖角。这里按圆角轮廓拼多边形，与卡片严丝合缝。
class DescMask extends Control:
	var top_color: Color = Color(0.10, 0.14, 0.20, 0.55)
	var bot_color: Color = Color(0.04, 0.06, 0.09, 0.92)
	var corner_radius: float = 20.0
	var corner_segments: int = 12

	func _ready() -> void:
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 0.0 or h <= 0.0:
			return
		var r: float = min(corner_radius, min(w * 0.5, h))
		var pts := PackedVector2Array()
		var cols := PackedColorArray()

		pts.append(Vector2(0, 0))
		cols.append(top_color)
		pts.append(Vector2(w, 0))
		cols.append(top_color)

		var steps: int = max(1, corner_segments)
		for i in range(0, steps + 1):
			var a: float = (PI * 0.5) * (float(i) / float(steps))
			var x: float = (w - r) + r * cos(a)
			var y: float = (h - r) + r * sin(a)
			pts.append(Vector2(x, y))
			cols.append(_color_at_y(y, h))

		for i in range(0, steps + 1):
			var a: float = (PI * 0.5) + (PI * 0.5) * (float(i) / float(steps))
			var x: float = r + r * cos(a)
			var y: float = (h - r) + r * sin(a)
			pts.append(Vector2(x, y))
			cols.append(_color_at_y(y, h))

		draw_polygon(pts, cols)

	func _color_at_y(y: float, h: float) -> Color:
		var t: float = clampf(y / h, 0.0, 1.0)
		return top_color.lerp(bot_color, t)


var _font: Font = null
var _campaigns: Array = []

var _track: Control = null
var _pages: Array[Panel] = []
var _page_labels: Array[Label] = []
var _desc_labels: Array[Label] = []

var _current: int = 0
var _page_h: float = 0.0

var _pressing: bool = false
var _dragging: bool = false
var _press_y: float = 0.0
var _start_track_y: float = 0.0
var _animating: bool = false


## @param campaigns `logic/campaign_menu_db.gd` 的结果（Array[Dictionary]）
## @param p_font    中文字体（null = 引擎默认字体，中文会是方框）
## @param name_size 卡片上战役名的字号
## @param desc_size 卡片上简介的字号
func setup(campaigns: Array, p_font: Font, name_size: int = 30, desc_size: int = 17) -> void:
	_campaigns = campaigns
	_font = p_font
	name = "Carousel"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	# ★ 铺满左侧那块裁剪容器（它是 Panel，不是 Container，不会替子节点排版）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_track = Control.new()
	_track.name = "Track"
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)

	for i in 3:
		var page := _make_page(name_size, desc_size)
		_pages.append(page)
		_track.add_child(page)

	gui_input.connect(_on_gui_input)
	resized.connect(_layout_pages)
	_layout_pages()
	call_deferred("_layout_pages")


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func campaign_count() -> int:
	return _campaigns.size()


func current_index() -> int:
	return _current


## 当前停着的那一项（空表时返回 {}）。
func current_campaign() -> Dictionary:
	if _campaigns.is_empty():
		return {}
	return _campaigns[posmod(_current, _campaigns.size())]


func campaign_at(index: int) -> Dictionary:
	if _campaigns.is_empty():
		return {}
	return _campaigns[posmod(index, _campaigns.size())]


## 三张占位卡上的字（slot 0 = 上一页 / 1 = 当前 / 2 = 下一页）—— 给测试与排查用。
func page_name(slot: int) -> String:
	if slot < 0 or slot >= _page_labels.size():
		return ""
	return _page_labels[slot].text


func is_animating() -> bool:
	return _animating


## 直接切到第 index 项（不播翻页动画）。
##
## ★ 给测试 / 程序化切换用：翻页动画是时间驱动的 Tween，断言不该跟它赛跑。
##   玩家那条路仍然走拖动 + `_settle()`。
func select_campaign(index: int, emit_signal_now: bool = true) -> void:
	if _campaigns.is_empty():
		return
	_current = posmod(index, _campaigns.size())
	_layout_pages()
	if emit_signal_now:
		current_campaign_changed.emit(_current)


## 翻到下一页 / 上一页（播动画；正忙或只有一个战役时忽略）。
func next() -> void:
	if _animating or _campaigns.size() <= 1:
		return
	_animate_to(-(_page_h + PAGE_GAP_PX) * 2.0, +1)


func prev() -> void:
	if _animating or _campaigns.size() <= 1:
		return
	_animate_to(0.0, -1)


# ------------------------------------------------------------------
# 搭卡片
# ------------------------------------------------------------------

func _make_page(name_size: int, desc_size: int) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", MenuThemeRes.campaign_card())

	var mask := DescMask.new()
	mask.name = "DescMask"
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.corner_radius = DESC_MASK_CORNER_RADIUS
	mask.corner_segments = DESC_MASK_CORNER_SEGMENTS
	mask.top_color = ThemeRes.with_alpha(ThemeRes.bg_top(), 0.55)
	mask.bot_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.92)
	mask.anchor_top = 1.0 - DESC_MASK_RATIO
	mask.anchor_bottom = 1.0
	mask.anchor_left = 0.0
	mask.anchor_right = 1.0
	mask.offset_left = 0.0
	mask.offset_right = 0.0
	mask.offset_top = 0.0
	mask.offset_bottom = 0.0
	p.add_child(mask)

	var name_lbl := Label.new()
	name_lbl.name = "CampaignName"
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_color_override("font_color", ThemeRes.text())
	name_lbl.add_theme_font_size_override("font_size", name_size)
	if _font != null:
		name_lbl.add_theme_font_override("font", _font)
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.clip_text = true
	name_lbl.anchor_left = 0.0
	name_lbl.anchor_right = 1.0
	name_lbl.anchor_top = 0.0
	name_lbl.anchor_bottom = NAME_HEIGHT_RATIO
	name_lbl.offset_left = TEXT_PAD_LEFT
	name_lbl.offset_right = -TEXT_PAD_RIGHT
	name_lbl.offset_top = TEXT_PAD_TOP
	name_lbl.offset_bottom = 0.0
	mask.add_child(name_lbl)
	_page_labels.append(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.name = "Desc"
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.text = DESC_PLACEHOLDER
	desc_lbl.add_theme_color_override("font_color", ThemeRes.text_dim())
	desc_lbl.add_theme_font_size_override("font_size", desc_size)
	if _font != null:
		desc_lbl.add_theme_font_override("font", _font)
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	desc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.clip_text = true
	desc_lbl.anchor_left = 0.0
	desc_lbl.anchor_right = 1.0
	desc_lbl.anchor_top = NAME_HEIGHT_RATIO
	desc_lbl.anchor_bottom = 1.0
	desc_lbl.offset_left = TEXT_PAD_LEFT
	desc_lbl.offset_right = -TEXT_PAD_RIGHT
	desc_lbl.offset_top = 0.0
	desc_lbl.offset_bottom = -TEXT_PAD_BOTTOM
	mask.add_child(desc_lbl)
	_desc_labels.append(desc_lbl)
	return p


# ------------------------------------------------------------------
# 排版 / 刷新
# ------------------------------------------------------------------

func _layout_pages() -> void:
	if _pages.is_empty() or _track == null:
		return
	_page_h = size.y
	if _page_h <= 0.0:
		return
	var step: float = _page_h + PAGE_GAP_PX
	var page_w: float = maxf(0.0, size.x - PAGE_MARGIN_X * 2.0)
	var page_inner_h: float = maxf(0.0, _page_h - PAGE_MARGIN_Y * 2.0)
	for i in _pages.size():
		var p: Panel = _pages[i]
		p.position = Vector2(PAGE_MARGIN_X, float(i) * step + PAGE_MARGIN_Y)
		p.size = Vector2(page_w, page_inner_h)
	_track.size = Vector2(size.x, step * float(_pages.size()))
	_track.position = Vector2(0, -step)
	_refresh_labels()


func _refresh_labels() -> void:
	if _page_labels.size() < 3:
		return
	for offset in range(-1, 2):
		var idx: int = offset + 1
		var item: Dictionary = campaign_at(_current + offset)
		_page_labels[idx].text = String(item.get("name", ""))
		var desc_text := String(item.get("description", ""))
		if desc_text.strip_edges() == "":
			desc_text = DESC_PLACEHOLDER
		if idx < _desc_labels.size():
			_desc_labels[idx].text = desc_text


# ------------------------------------------------------------------
# 拖动 / 吸附
# ------------------------------------------------------------------

func _on_gui_input(event: InputEvent) -> void:
	if _animating or _campaigns.size() <= 1:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_dragging = false
			_press_y = event.global_position.y
			_start_track_y = _track.position.y
		else:
			if _pressing:
				_pressing = false
				if _dragging:
					_dragging = false
					accept_event()
					_settle()
	elif event is InputEventMouseMotion and _pressing:
		var dy: float = event.global_position.y - _press_y
		if not _dragging and absf(dy) >= DRAG_THRESHOLD_PX:
			_dragging = true
		if _dragging:
			_track.position.y = _start_track_y + dy
			_emit_drag_progress()
			accept_event()


func _drag_progress_value() -> float:
	if _page_h <= 0.0:
		return 0.0
	var step: float = _page_h + PAGE_GAP_PX
	var delta: float = _track.position.y - (-step)
	var thresh: float = _page_h * SNAP_RATIO
	if thresh <= 0.0:
		return 0.0
	return clampf(-delta / thresh, -1.0, 1.0)


func _emit_drag_progress() -> void:
	drag_progress.emit(_drag_progress_value())


func _settle() -> void:
	var step: float = _page_h + PAGE_GAP_PX
	var delta: float = _track.position.y - (-step)
	var snap: float = _page_h * SNAP_RATIO
	if delta <= -snap:
		_animate_to(-step * 2.0, +1)
	elif delta >= snap:
		_animate_to(0.0, -1)
	else:
		_animate_to(-step, 0)


func _animate_to(target_y: float, page_delta: int) -> void:
	_animating = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_track, "position:y", target_y, TWEEN_DURATION) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_method(func(_t): _emit_drag_progress(), 0.0, 1.0, TWEEN_DURATION)
	await tw.finished
	if not is_instance_valid(self):
		return
	if page_delta != 0:
		_current = posmod(_current + page_delta, _campaigns.size())
		_refresh_labels()
		current_campaign_changed.emit(_current)
	else:
		drag_progress.emit(0.0)
	_track.position.y = -(_page_h + PAGE_GAP_PX)
	_animating = false
