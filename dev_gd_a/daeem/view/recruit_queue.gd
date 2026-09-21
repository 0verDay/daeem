## recruit_queue.gd —— 「招募队列」五格显示（1 个大格 + 4 个小格，星际争霸那套）
##
## 需求原话：「当将领开始招募时，其信息栏内出现五个格子（一个大的，四个小的，
##            代表最多能有五个单位进入招募队列，正在招募的单位即为在大格子中显示的
##            单位），同时开始读条」。
##
## 落在哪：**详细信息面板的左栏**（选中哪个将领就显示哪个的队列），
##   由 view/detail_panel.gd 摆进左栏、由 view/hud.gd 每帧喂当前选中的将领。
##
## ★ 交互（用户需求）：「点击对应的格子取消对应格子上的造兵队列，其后方的造兵队列前移」。
##   本控件只负责「点到了哪一格」并把它抛出去（`cell_activated`），
##   取消与退款是**权威逻辑**（`world.cancel_recruit`）—— 视图不碰逻辑状态。
##
## ★ 纯表现：只**读** `unit.train_kind / train_remaining / train_total / train_queue`
##   这几个权威字段，从不写它们（改世界只有一条路 —— 发命令）。
## ★ 五个格子的几何全在 view/ui_layout.gd（QUEUE_* 常量 + queue_cell_rect），
##   本文件不写坐标字面量（与其它 view 文件同规矩）。
## ★ 大格子里画读条：进度 = 1 - train_remaining / train_total（由 unit.train_progress()
##   算好，视图不自己推 —— 见 docs/pitfalls.md 5.20「视图不许发明判定规则」）。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 点到了某一格（已经确认那一格上**有东西可取消**）。0 = 大格子，1..4 = 小格子。
signal cell_activated(slot: int)

var world = null

## 当前显示的将领（由 detail_panel / hud 每帧给；null = 没选中将领）
var _leader = null
## 五个格子的文字标签（第 0 个是大格子）
var _labels: Array[Label] = []
## 鼠标停在哪一格上（-1 = 没停在任何**有内容**的格子上）
var _hover_slot: int = -1


func setup(p_world) -> void:
	world = p_world
	name = "RecruitQueue"
	# ★ 要能点（取消队列），所以这里收鼠标；但**只有正在招募时**才可见，
	#   不可见的控件收不到鼠标事件，所以平时不会挡住详细信息面板。
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_H)
	size = custom_minimum_size

	for i in UiLayoutRes.QUEUE_SLOTS:
		var l := Label.new()
		l.name = "QueueCell%d" % i
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		var r := UiLayoutRes.queue_cell_rect(i)
		l.position = r.position
		l.size = r.size
		add_child(l)
		_labels.append(l)

	visible = false


## 这一帧要显示的将领（传 null = 没选中将领 / 选中的是建筑或区划）
func set_leader(leader) -> void:
	_leader = leader
	refresh()


## 现在该不该显示：**正在招募时才出现**（需求：将领开始招募时信息栏里出现五个格子）
func showing() -> bool:
	return _leader != null and _leader.is_training()


func refresh() -> void:
	var show_now := showing()
	visible = show_now
	if not show_now:
		_hover_slot = -1
		for l in _labels:
			l.text = ""
		queue_redraw()
		return
	for i in _labels.size():
		var kind := cell_kind(i)
		if kind == "":
			_labels[i].text = ""
		elif i == 0:
			# 大格子：短名 + 剩余秒数（读条的「同时开始读条」那半句）
			_labels[i].text = "%s\n%.1fs" % [cell_text(i), maxf(0.0, float(_leader.train_remaining))]
		else:
			_labels[i].text = cell_text(i)
	# 鼠标原来停着的那一格被取消掉了 → 把悬停态也清掉（不然光标还留在「手型」）
	if _hover_slot >= 0 and not cell_filled(_hover_slot):
		_hover_slot = -1
		mouse_default_cursor_shape = Control.CURSOR_ARROW
	queue_redraw()


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

## 第 i 格里的兵种（空串 = 空格子）。0 = 正在读条的大格子，1..4 = 排队的小格子。
func cell_kind(i: int) -> String:
	if _leader == null:
		return ""
	if i == 0:
		return String(_leader.train_kind)
	var k := i - 1
	var q: Array = _leader.train_queue
	if k < 0 or k >= q.size():
		return ""
	return String(q[k])


func cell_filled(i: int) -> bool:
	return cell_kind(i) != ""


## 第 i 格显示的字（config 里的 short，没配就退回 label 首字）
func cell_text(i: int) -> String:
	var kind := cell_kind(i)
	if kind == "":
		return ""
	if world == null:
		return kind
	return world.recruit_short_of(kind)


## 大格子的读条进度（0~1）
func progress() -> float:
	if _leader == null:
		return 0.0
	return float(_leader.train_progress())


func slot_count() -> int:
	return _labels.size()


func cell_label(i: int) -> String:
	if i < 0 or i >= _labels.size():
		return ""
	return _labels[i].text


func leader():
	return _leader


# ------------------------------------------------------------------
# 点击：哪一格可以取消
# ------------------------------------------------------------------

## 这个点落在哪一格上（**只有有内容的格子**才算命中；空格子 / 外面 → -1）。
##
## ★ 「有内容」= 那一格上排着一个单位（正在读条或排队），也就是「点了有东西可取消」。
##   空格子点了什么都不该发生（与部队列表的空槽同一条规矩）。
func cell_at_position(p: Vector2) -> int:
	if not showing():
		return -1
	for i in UiLayoutRes.QUEUE_SLOTS:
		if UiLayoutRes.queue_cell_rect(i).has_point(p) and cell_filled(i):
			return i
	return -1


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var s := cell_at_position(event.position)
		if s != _hover_slot:
			_hover_slot = s
			mouse_default_cursor_shape = (Control.CURSOR_POINTING_HAND if s >= 0
				else Control.CURSOR_ARROW)
			queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var slot := cell_at_position(event.position)
		if slot >= 0:
			# 只抛「点到了第几格」；取消与退款走命令那条路（见文件头）
			cell_activated.emit(slot)
			accept_event()


# ------------------------------------------------------------------
# 画：五格 + 边框 + 大格子里的读条
# ------------------------------------------------------------------

func _draw() -> void:
	if not showing():
		return
	for i in UiLayoutRes.QUEUE_SLOTS:
		var r := UiLayoutRes.queue_cell_rect(i)
		var filled := cell_filled(i)
		var big: bool = i == 0
		draw_rect(r, UiStyleRes.BG_PRESSED if filled else UiStyleRes.BG_EMPTY, true)
		if big and filled:
			var p: float = clampf(progress(), 0.0, 1.0)
			if p > 0.0:
				# 读条从格子**底边**往上填（与区块占领进度条一个方向，看着一致）
				var h: float = r.size.y * p
				draw_rect(Rect2(r.position.x, r.position.y + r.size.y - h, r.size.x, h),
					UiStyleRes.ACCENT_DIM, true)
		# 边框：大格子（正在读条）用强调色；鼠标停在这格上时也点亮 ——
		# 这样「哪一格可以点、点了会取消谁」一眼看得见
		var edge: Color = UiStyleRes.LINE
		if big and filled:
			edge = UiStyleRes.ACCENT
		if i == _hover_slot and filled:
			edge = UiStyleRes.WARN
		draw_rect(r, edge, false, 1.0)
