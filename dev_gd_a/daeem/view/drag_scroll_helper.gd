## drag_scroll_helper.gd —— 给原生 `ScrollContainer` 加「按住拖动滚动」
##
## ★ 用途：`ScrollContainer` 自带滚动条与滚轮，但**按住内容往下拖**它不会动
##   （引擎只认滚动条的拖动）。这个挂件补上那一段，界面就能像手机列表那样拖。
##   用法：
##       const DragScrollHelperRes = preload("res://view/drag_scroll_helper.gd")
##       var helper := DragScrollHelperRes.new()
##       helper.setup(scroll, on_drag_start)      # on_drag_start 可省
##       scroll.add_child(helper)
##
## ★ 与 `view/elastic_scroll_list.gd` 的分工：那一个是「自己管 clip + 偏移」的橡皮筋列表；
##   本文件只服务**引擎自带的** `ScrollContainer`（不会越界、有滚动条）。
##
## ★ 阈值来自 `data/config.json` 的 `ui.drag_scroll_min_px`（见 logic/config.gd），
##   它比滚动列表那条 `ui.scroll_drag_min_px` 小：原生滚动不会误点列表项。
##
## ⚠️ daeem 目前还没有任何 `ScrollContainer`，所以这个文件暂时没有调用点 ——
##   它是上面那条滚动能力的姊妹件，先随滚动能力一起进来，避免以后各写一份。
extends Node

const ConfigRes = preload("res://logic/config.gd")

## 兜底值（与 config.json 的 ui 段逐位一致）。
const DEFAULT_DRAG_MIN_PX := 8.0

var _scroll: ScrollContainer = null
var _on_drag_start: Callable = Callable()
var _drag_min_px: float = DEFAULT_DRAG_MIN_PX

var _pressing: bool = false
var _dragging: bool = false
var _press_y: float = 0.0
var _start_scroll: int = 0


## 挂到一个 `ScrollContainer` 上。
## @param on_drag_start 拖动**判定成立**时调用一次（用来取消长按这类副作用）；可省。
func setup(scroll: ScrollContainer, on_drag_start: Callable = Callable()) -> void:
	_scroll = scroll
	_on_drag_start = on_drag_start
	var cfg = ConfigRes.load_default()
	if cfg != null:
		_drag_min_px = cfg.drag_scroll_min_px
	# 重复 setup() 不该挂第二条连接（两次连上会让每次拖动都走一遍逻辑）。
	if not scroll.gui_input.is_connected(_on_scroll_input):
		scroll.gui_input.connect(_on_scroll_input)


func drag_min_px() -> float:
	return _drag_min_px


func is_pressing() -> bool:
	return _pressing


func is_dragging() -> bool:
	return _dragging


func _on_scroll_input(event: InputEvent) -> void:
	if _scroll == null:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_pressing = true
			_dragging = false
			_press_y = mb.global_position.y
			_start_scroll = _scroll.scroll_vertical
		else:
			# 拖动结束：若已确认拖动就把这次释放吃掉，
			# 免得松手时命中列表项里的 Button（"滚一下" 变成 "点一下"）。
			if _dragging:
				_scroll.accept_event()
			_pressing = false
			_dragging = false

	elif event is InputEventMouseMotion and _pressing:
		var dy := (event as InputEventMouseMotion).global_position.y - _press_y
		if not _dragging and absf(dy) >= _drag_min_px:
			_dragging = true
			if _on_drag_start.is_valid():
				_on_drag_start.call()
		if _dragging:
			_scroll.scroll_vertical = _start_scroll - int(dy)
			_scroll.accept_event()
