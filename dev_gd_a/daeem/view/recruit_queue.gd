## recruit_queue.gd —— 「招募队列」显示（左边汇总带 + 1 大格 + 4 小格，星际争霸那套）
##
## 需求原话：「当将领开始招募时，其信息栏内出现五个格子（一个大的，四个小的，
##            代表最多能有五个单位进入招募队列，正在招募的单位即为在大格子中显示的
##            单位），同时开始读条」。
##
## 落在哪：**详细信息面板右栏的顶带里**（单位名称右边；选中哪个将领就显示哪个的队列），
##   由 view/detail_panel.gd 摆进右栏、由 view/hud.gd 每帧喂当前选中的将领。
##
## ★ 交互（用户需求）：「点击对应的格子取消对应格子上的造兵队列，其后方的造兵队列前移」。
##   本控件只负责「点到了哪一格」并把它抛出去（`cell_activated`），
##   取消与退款是**权威逻辑**（`world.cancel_recruit`）—— 视图不碰逻辑状态。
##
## ★ 纯表现：只**读** `unit.train_kind / train_remaining / train_total / train_queue`
##   这几个权威字段，以及**逻辑层算好的** `world.recruit_eta()`；
##   从不写它们（改世界只有一条路 —— 发命令）。
## ★ 几何全在 view/ui_layout.gd（QUEUE_* 常量 + queue_cell_rect / queue_info_line_rect），
##   本文件不写坐标字面量（与其它 view 文件同规矩）。
## ★ 大格子里画读条：进度 = 1 - train_remaining / train_total（由 unit.train_progress()
##   算好，视图不自己推 —— 见 docs/pitfalls.md 5.20「视图不许发明判定规则」）。
##
## ★★ 第七轮（显示优化）改了三件事，都在这一层：
##   ① **左边加一条汇总带**（现在 141px，位置本来就是空的）：「招募队列 3/5」+「共 22s」，
##      并给整块垫一层与其它面板同一套的底板 / 1px 描边 + 一条竖分隔线 ——
##      「这是一组队列、现在排了几个、全部读完还要多久」一眼可见；
##   ② **每个格子都带时间**：大格子写「兵 / 剩 7.3s」，四个小格子写「兵 / 10s」
##      （= 轮到它还差几秒）。★ 那个秒数由 `world.recruit_eta()` 给 ——
##      「排队的一单各自读多久、什么时候轮到我」是玩法规则，视图不许自己乘 train_sec
##      （同 pitfalls 5.20）。排队项的秒数天然递增，所以「谁在前谁在后」不用再画序号；
##   ③ **读条更好认**：大格子底下垫一层空槽色轨道、进度仍从**下往上**填（与区块占领条
##      同一方向），填充顶端加一条亮色「读头」线；鼠标停在哪一格，那一格画红框、
##      右上角画一个「×」——「点这一格 = 取消这一单」不用猜。
##
## ★★ 手玩说「还是不好看」之后又按截图改了两处（同一轮）：
##   · **整块放大** 261×64 → **313×92**（大格 64→84、小格 30→40、字号 13/11 → **15/13**）——
##     原来在一整排 72 的头像 / 29 号的名称旁边显得又小又空；
##   · **不贴右栏的裁剪线**：块的上/右边缘各留 4px（`QUEUE_MARGIN`）。原来贴边时
##     `draw_rect(..., false, 1)` 的描边有一半落在 `right.clip_contents` 之外，
##     **上边框整条不见**（手玩原话「它的上方被裁剪了」）—— 见 pitfalls 5.44。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 点到了某一格（已经确认那一格上**有东西可取消**）。0 = 大格子，1..4 = 小格子。
signal cell_activated(slot: int)

var world = null

## 当前显示的「队列主人」——**将领单位**或**区划字典**（由 detail_panel / hud 每帧给；null = 没有）
var _holder = null
## 这个主人是不是一个**区划**（true 时走 world 的 zone_* 那一套查询）
var _is_zone: bool = false
## 五个格子的文字标签（第 0 个是大格子）
var _labels: Array[Label] = []
## 汇总带的两行字（「招募队列 3/5」/「共 22s」）
var _title: Label = null
var _total: Label = null
## 鼠标停在哪一格上（-1 = 没停在任何**有内容**的格子上）
var _hover_slot: int = -1
## 这一块画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0


func setup(p_world) -> void:
	world = p_world
	name = "RecruitQueue"
	# ★ 要能点（取消队列），所以这里收鼠标；但**只有正在招募时**才可见，
	#   不可见的控件收不到鼠标事件，所以平时不会挡住详细信息面板。
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_H)
	size = custom_minimum_size

	# 汇总带的两行字：第一行是数量（15 号，与右栏名称以外的正文同级），
	# 第二行是全部读完还要多久（13 号 —— 次要信息那一档）。
	_title = _new_label("QueueTitle", UiStyleRes.FS_BODY, UiStyleRes.TEXT)
	_title.text = ""
	_place(_title, UiLayoutRes.queue_info_line_rect(0))
	_total = _new_label("QueueTotal", UiStyleRes.FS_SMALL, UiStyleRes.TEXT_DIM)
	_total.text = ""
	_place(_total, UiLayoutRes.queue_info_line_rect(1))

	for i in UiLayoutRes.QUEUE_SLOTS:
		# 大格子里的字大一号（它是正在读条的那个）：15 号；小格子两行用 13 号
		# —— 40×40 装两行 13 号（28px）还剩 12px 余量（第七轮整块放大前是 30×30 + 11 号）。
		var fs: int = UiStyleRes.FS_BODY if i == 0 else UiStyleRes.FS_SMALL
		var l := _new_label("QueueCell%d" % i, fs, UiStyleRes.TEXT)
		_place(l, UiLayoutRes.queue_cell_rect(i))
		_labels.append(l)

	visible = false


## 造一个格子/汇总用的 Label（居中、不吃鼠标、不写坐标 —— 位置由 _place 给）
func _new_label(node_name: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	add_child(l)
	return l


## 把 Label 摆到某个局部矩形里。
## ⚠️ 位置与尺寸一律走 ui_layout 给出的矩形，本文件不写字面量。
func _place(l: Label, r: Rect2) -> void:
	l.position = r.position
	l.size = r.size


## 这一帧要显示的队列主人（传 null = 没选中将领 / 选中的是建筑或区划）。
## @param is_zone true 时 holder 是一个**区划字典**（区划招募：点区划中心时显示它的队列）
func set_queue(holder, is_zone: bool = false) -> void:
	_holder = holder
	_is_zone = is_zone
	refresh()


## 旧接口（将领队列）：保留它，测试与调用方按「将领」读更清楚
## （区划队列直接走 `set_queue(zone, true)`，由 detail_panel 转发）
func set_leader(leader) -> void:
	set_queue(leader, false)


## 现在显示的是不是区划的队列
func is_zone_queue() -> bool:
	return _is_zone


func holder():
	return _holder


## 这个主人现在是不是「正在招募」。
## ★ 将领：`unit.is_training()`；区划：队列字段挂在区划字典上，判据由**逻辑层**给
##   （`world.zone_is_training`）—— 视图不自己发明判定（pitfalls 5.20）。
func showing() -> bool:
	if _holder == null:
		return false
	if not _is_zone:
		return bool(_holder.is_training())
	if world != null and world.has_method("zone_is_training"):
		return bool(world.zone_is_training(_holder))
	return _zone_kind() != "" or not _zone_queue().is_empty()


func _zone_dict() -> Dictionary:
	return _holder if typeof(_holder) == TYPE_DICTIONARY else {}


func _zone_kind() -> String:
	return String(_zone_dict().get("train_kind", ""))


func _zone_queue() -> Array:
	var v: Variant = _zone_dict().get("train_queue", [])
	return v if typeof(v) == TYPE_ARRAY else []


## 大格子里这一单还剩几秒（两种主人各读各的字段）
func _remaining() -> float:
	if _holder == null:
		return 0.0
	if _is_zone:
		return maxf(0.0, float(_zone_dict().get("train_remaining", 0.0)))
	return maxf(0.0, float(_holder.train_remaining))


func refresh() -> void:
	var show_now := showing()
	visible = show_now
	if not show_now:
		_hover_slot = -1
		_title.text = ""
		_total.text = ""
		for l in _labels:
			l.text = ""
		queue_redraw()
		return

	# 汇总带：已排几个 / 上限 + 整条队列读完还要多久
	_title.text = "招募队列 %d/%d" % [queue_count(), queue_max()]
	_total.text = "共 %ds" % int(ceil(total_eta()))

	for i in _labels.size():
		var kind := cell_kind(i)
		if kind == "":
			_labels[i].text = ""
		elif i == 0:
			# 大格子：短名 + **这一单**的剩余秒数（读条的「同时开始读条」那半句）
			_labels[i].text = "%s\n剩 %.1fs" % [cell_text(i), _remaining()]
		else:
			# 小格子：短名 + **轮到它还差几秒**（累计剩余，由逻辑层给）
			_labels[i].text = "%s\n%ds" % [cell_text(i), eta_seconds(i)]
	# 鼠标原来停着的那一格被取消掉了 → 把悬停态也清掉（不然光标还留在「手型」）
	if _hover_slot >= 0 and not cell_filled(_hover_slot):
		_hover_slot = -1
		mouse_default_cursor_shape = Control.CURSOR_ARROW
	queue_redraw()


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

## 第 i 格里的兵种（空串 = 空格子）。0 = 正在读条的大格子，1..4 = 排队的小格子。
## ★ 两种主人（将领 / 区划）读的字段名一样，只是挂在不同的对象上。
func cell_kind(i: int) -> String:
	if _holder == null:
		return ""
	if _is_zone:
		if i <= 0:
			return _zone_kind()
		var zq := _zone_queue()
		var zk := i - 1
		if zk < 0 or zk >= zq.size():
			return ""
		return String(zq[zk])
	if i == 0:
		return String(_holder.train_kind)
	var k := i - 1
	var q: Array = _holder.train_queue
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
	if _holder == null:
		return 0.0
	if _is_zone:
		if world != null and world.has_method("zone_train_progress"):
			return float(world.zone_train_progress(_holder))
		return 0.0
	return float(_holder.train_progress())


## 第 i 格还要等多久（秒）。★ 走逻辑层的查询（见文件头第 ② 条），视图不自己推。
func eta_of(i: int) -> float:
	if _holder == null:
		return 0.0
	if world == null:
		# 没有 world（极端情况）时只报得出大格子自己的剩余秒；排队项无从算起。
		return _remaining() if i <= 0 else 0.0
	if _is_zone:
		return float(world.zone_recruit_eta(_holder, i))
	return float(world.recruit_eta(_holder, i))


## 格子文案里那个秒数：向上取整到整秒，且**最小 1 秒**
## （显示「0s」会让玩家以为已经造好了；空槽不走这条路）。
func eta_seconds(i: int) -> int:
	return maxi(1, int(ceil(eta_of(i))))


## 整条队列读完还要多久 = 最后那个非空格子的 ETA（给汇总带第二行用）
func total_eta() -> float:
	var last := -1
	for i in UiLayoutRes.QUEUE_SLOTS:
		if cell_filled(i):
			last = i
	if last < 0:
		return 0.0
	return eta_of(last)


## 队列里现在有几个（含正在读条的那个）
func queue_count() -> int:
	if _holder == null:
		return 0
	if _is_zone:
		if world != null and world.has_method("zone_recruit_queue_size"):
			return int(world.zone_recruit_queue_size(_holder))
		var n := _zone_queue().size()
		return n + (1 if _zone_kind() != "" else 0)
	return int(_holder.train_queue_size())


## 队列上限（将领 = config.recruit.queue_max；区划 = config.recruit.zone.queue_max）
func queue_max() -> int:
	if world == null:
		return UiLayoutRes.QUEUE_SLOTS
	if _is_zone:
		return int(world.zone_recruit_queue_max())
	return int(world.recruit_queue_max())


func slot_count() -> int:
	return _labels.size()


func cell_label(i: int) -> String:
	if i < 0 or i >= _labels.size():
		return ""
	return _labels[i].text


## 汇总带第一行（「招募队列 3/5」；没在招募时是空串）
func title_text() -> String:
	return "" if _title == null else _title.text


## 汇总带第二行（「共 22s」；没在招募时是空串）
func total_text() -> String:
	return "" if _total == null else _total.text


## 当前显示的队列主人（将领或区划字典）。★ 旧名保留：老调用方/测试按「将领」读它 ——
## 它现在可能返回一个**区划字典**（用 is_zone_queue() 区分）。
func leader():
	return _holder


## 鼠标现在停在第几格（-1 = 没停在有内容的格子上）。测试读它；游戏里没人读。
func hover_slot() -> int:
	return _hover_slot


# ------------------------------------------------------------------
# 点击：哪一格可以取消
# ------------------------------------------------------------------

## 这个点落在哪一格上（**只有有内容的格子**才算命中；空格子 / 汇总带 / 外面 → -1）。
##
## ★ 「有内容」= 那一格上排着一个单位（正在读条或排队），也就是「点了有东西可取消」。
##   空格子点了什么都不该发生（与部队列表的空槽同一条规矩）。
## ★ 汇总带那 129px 不是格子：鼠标停在上面不显示手型、点了也不发命令
##   （`queue_cell_rect()` 已经带上了那段偏移，所以这里天然判不到它）。
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
# 画：底板 / 五格 / 读条 / 悬停的「×」
# ------------------------------------------------------------------

func _draw() -> void:
	if not showing():
		return
	draw_count += 1

	# ① 整块底板 + 1px 描边（与「详细信息」方框、底栏其它面板同一套板式）——
	#    它让「这 261×64 是一组东西」一眼可见，而不是几个孤零零的方块浮在右栏上。
	draw_rect(Rect2(Vector2.ZERO, Vector2(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_H)),
		UiStyleRes.BG_SOFT, true)
	draw_rect(Rect2(Vector2.ZERO, Vector2(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_H)),
		UiStyleRes.LINE, false, 1.0)
	# ② 汇总带与格子之间的一条竖分隔线（底栏那套「1px 线分隔」的同一手法）
	var split_x := UiLayoutRes.QUEUE_INFO_W
	draw_line(Vector2(split_x, 0.0), Vector2(split_x, UiLayoutRes.QUEUE_H),
		UiStyleRes.LINE_SOFT, 1.0)

	# ③ 五个格子
	for i in UiLayoutRes.QUEUE_SLOTS:
		var r := UiLayoutRes.queue_cell_rect(i)
		var filled := cell_filled(i)
		var big: bool = i == 0

		if big:
			# 大格子：空槽色轨道 + 从下往上填的进度 + 填充顶端一条亮色「读头」
			draw_rect(r, UiStyleRes.BG_EMPTY, true)
			if filled:
				var p: float = clampf(progress(), 0.0, 1.0)
				if p > 0.0:
					var h: float = r.size.y * p
					var top := r.position.y + r.size.y - h
					draw_rect(Rect2(r.position.x, top, r.size.x, h), UiStyleRes.ACCENT_DIM, true)
					if p < 1.0:
						# 读头只有 3px：远看是「进度到哪了」的一根亮线，不抢文字
						draw_rect(Rect2(r.position.x, top, r.size.x, 3.0), UiStyleRes.ACCENT, true)
		else:
			draw_rect(r, UiStyleRes.BG_PRESSED if filled else UiStyleRes.BG_EMPTY, true)

		# 边框：大格子（正在读条）用强调色、排队的小格子用弱化的强调色、空槽用白线；
		# 鼠标停在哪一格，那一格换成红框 —— 「哪一格可以点、点了会取消谁」一眼看得见。
		var edge: Color = UiStyleRes.LINE
		if big and filled:
			edge = UiStyleRes.ACCENT
		elif filled:
			edge = UiStyleRes.ACCENT_DIM
		if i == _hover_slot and filled:
			edge = UiStyleRes.WARN
		draw_rect(r, edge, false, 1.0)

		# 悬停那一格右上角画个「×」：这是「点它会取消这一单」的记号
		# （用两条短线画，不依赖字体 —— 也就不会因为中文字体缺失变成方框）
		if i == _hover_slot and filled:
			var x_size := UiLayoutRes.QUEUE_HOVER_X_SIZE
			var x_pad := UiLayoutRes.QUEUE_HOVER_X_PAD
			var x0 := r.position.x + r.size.x - x_pad - x_size
			var y0 := r.position.y + x_pad
			draw_line(Vector2(x0, y0), Vector2(x0 + x_size, y0 + x_size),
				UiStyleRes.WARN, 1.0)
			draw_line(Vector2(x0 + x_size, y0), Vector2(x0, y0 + x_size),
				UiStyleRes.WARN, 1.0)
