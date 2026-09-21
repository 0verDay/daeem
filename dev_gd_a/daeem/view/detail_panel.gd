## detail_panel.gd —— 底栏「详细信息」面板（参考图标注的 1030×240）
##
## 内部分栏：
##   左栏 = **选中对象本身的信息**（部队 / 队伍 / 建筑），没选中就写「未选中」
##          + 右侧的**招募队列五格**（选中正在招募的将领时才出现）
##          + 底下的一行**红字提示**（招募被拒等原因，约 2 秒，见 hud.show_notice）
##   右栏 = **阵营 + 粮食 + 黄金**
##
## ★ 按需求砍掉的东西（别再默默加回来）：
##   · 己方地块 / 区块 / 建造模式 / 暂停 —— 都不显示
##   · **整块事件日志** —— 日志栏已经删掉（事件仍然由 logic 收集，只是没有界面画它，
##     见 view/hud.gd 末尾那段说明）。⚠️ 那行红字提示**不是**日志栏：
##     它只显示「最近一次操作被拒」的一句话，不保留历史、不进快照。
##   · 左栏的各种操作提示（左键选单位 / 右键移动 / 快捷键…）
##
## ★ 只负责显示：文本从哪来由 hud.gd 决定。
extends PanelContainer

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const RecruitQueueRes = preload("res://view/recruit_queue.gd")

## 点到了招募队列的某一格（0 = 正在读条的大格子，1..4 = 排队的小格子）。
## 原样转发给 hud.gd —— 由它翻译成 input_controller 的取消命令。
signal queue_cell_activated(slot: int)

var _body: Label
var _status: Label
var _notice: Label
var _queue: Control


func setup(world = null) -> void:
	name = "DetailPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var s := UiStyleRes.panel_style()
	s.set_content_margin_all(UiLayoutRes.DETAIL_PAD)
	add_theme_stylebox_override("panel", s)
	UiLayoutRes.apply_rect(self, UiLayoutRes.DETAIL_RECT, false, true)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 14)
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(cols)

	# ---- 左栏：选中对象的信息 + 招募队列 + 提示 ----
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(left)

	var title := Label.new()
	title.text = "详细信息"
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	title.add_theme_color_override("font_color", UiStyleRes.ACCENT)
	left.add_child(title)

	# 正文与招募队列并排：文字占满剩下的宽度，队列贴右边（宽度固定）
	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_child(row)

	_body = Label.new()
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_body.add_theme_color_override("font_color", UiStyleRes.TEXT)
	row.add_child(_body)

	_queue = RecruitQueueRes.new()
	_queue.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_queue)
	_queue.setup(world)
	_queue.cell_activated.connect(_on_queue_cell_activated)

	# 提示行：只有被拒时才出现（红字，约 2 秒）
	_notice = Label.new()
	_notice.name = "NoticeLine"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_notice.add_theme_color_override("font_color", UiStyleRes.WARN)
	_notice.visible = false
	left.add_child(_notice)

	# ---- 右栏：阵营 + 资源 ----
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(UiLayoutRes.DETAIL_RIGHT_W, 0.0)
	right.add_theme_constant_override("separation", 4)
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(right)

	_status = Label.new()
	_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_status.add_theme_color_override("font_color", UiStyleRes.TEXT_DIM)
	right.add_child(_status)


# ------------------------------------------------------------------
# 显示
# ------------------------------------------------------------------

func set_detail(text: String) -> void:
	if _body != null:
		_body.text = text


## 右栏：阵营 + 资源（多行也可以，长了会自动折行）
func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


## 左栏右侧的招募队列：显示哪个将领的（null = 没有选中将领 → 整块收起来）
func set_queue(leader) -> void:
	if _queue != null:
		_queue.set_leader(leader)


## 队列控件点到某一格 → 原样转发（本层不认识「取消」这个概念）
func _on_queue_cell_activated(slot: int) -> void:
	queue_cell_activated.emit(slot)


## 提示行（红字）。空串 = 收起来。
func set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""


# ------------------------------------------------------------------
# 给测试用的小接口
# ------------------------------------------------------------------

func detail_text() -> String:
	return _body.text if _body != null else ""


func status_text() -> String:
	return _status.text if _status != null else ""


func notice_text() -> String:
	return _notice.text if _notice != null else ""


func queue_control() -> Control:
	return _queue


## 日志栏是否还在（按需求它必须**不在**：这条断言防止有人顺手加回来）
func has_log() -> bool:
	return get_node_or_null("LogBox") != null
