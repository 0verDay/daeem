## detail_panel.gd —— 底栏「详细信息」面板（参考图标注的 1030×240）
##
## ★ 第三轮改版（照新参考图）：整块重排成**左右两栏** ——
##
##   左栏（605 宽）
##     ├─ 上半：**当前展开的那支部队**（view/unit_roster.gd）
##     │        将领头像 + 「将领名称 / x/y」+ 该部队每个单位一个方块
##     │        （队长 40×40 大方块、亲兵 20×20 小方块，一行最多 10 个，**滚轮**横向滚）
##     └─ 下半：**选中部队的将领头像网格**（view/troop_grid.gd）
##               3 列 × 4 行 = 12 格；点一格 = 把左栏上半切到那支部队（同时选中它）
##
##   右栏（395 宽）
##     ├─ 选中单位的**头像**（64×64）+「单位名称」+ 一行 **buff 图标**（占位，无效果）
##     ├─ 「详细信息」数值区（血量 / 攻击力 / 射程 / 状态…）
##     ├─ 招募队列的五个格子（view/recruit_queue.gd，贴右上角；只有正在招募时才出现）
##     └─ 最下面一行**红字提示**（操作被拒的原因，约 ui.notice_sec 秒，见 hud.show_notice）
##
## ★ 按需求砍掉的东西（别再默默加回来）：
##   · **「阵营 + 粮食 + 黄金」那一行资源 —— 本轮按参考图删掉了**
##     （玩家要恢复的话：放回 detail_panel 的一个 Label，数据从 hud 那边喂）
##   · **选中单位的那些汇总文字**（队伍人数 / 合计生命 / 指定攻击 / 状态）—— 一并删掉；
##     现在右栏只画「详细信息」这一块数值
##   · 己方地块 / 区块 / 建造模式 / 暂停 —— 都不显示
##   · **整块事件日志** —— 日志栏已经删掉（事件仍然由 logic 收集，只是没有界面画它，
##     见 view/hud.gd 末尾那段说明）。⚠️ 那行红字提示**不是**日志栏：
##     它只显示「最近一次操作被拒」的一句话，不保留历史、不进快照。
##   · 左栏的各种操作提示（左键选单位 / 右键移动 / 快捷键…）
##
## ★ 只负责显示 + 把「点了哪一格」原样抛出去：文本从哪来由 hud.gd 决定。
extends PanelContainer

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const RecruitQueueRes = preload("res://view/recruit_queue.gd")
const UnitRosterRes = preload("res://view/unit_roster.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")

## 点到了招募队列的某一格（0 = 正在读条的大格子，1..4 = 排队的小格子）。
## 原样转发给 hud.gd —— 由它翻译成 input_controller 的取消命令。
signal queue_cell_activated(slot: int)
## 点了左栏下半某一格将领头像（带**部队编号**，1 起）。
## 原样转发给 hud.gd —— 「换成选中那支部队 + 把左栏切过去」由它做。
signal troop_activated(number: int)
## 点了左栏**上半**方块行里的第 k 个方块（0 = 队长）。
## 原样转发给 hud.gd —— 「右栏切到那个单位」由它做（手玩原话：「玩家点击了左栏中展开部队的
## 单位，则切换详情至这个单位」）。
signal block_activated(k: int)

## buff 占位（手玩原话：「可以先做几个无效果的 buff 凑数」）。
## ★ 它是**纯显示**：逻辑层没有 buff 系统，这里只是把这几个字画进格子里。
const BUFF_PLACEHOLDERS := ["buff1", "buff2", "buff3"]
## 左栏第一格右边那行小字：参考图上写的就是「将领名称」（不是将领真名）——
## 手玩原话：「两行：『将领名称』+『1/11』」。
const ROSTER_LEADER_LABEL := "将领名称"

var _world = null
var _roster: Control
var _grid: Control
var _notice: Label
var _queue: Control

# 右栏
var _unit_avatar: Control
var _unit_name: Label
var _buffs: Array[Label] = []
var _detail_box: Panel
var _detail_title: Label
var _body: Label

# 左栏上半「未选中」时的兜底文字
var _empty_label: Label


func setup(world = null, font: Font = null) -> void:
	_world = world
	name = "DetailPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var s := UiStyleRes.panel_style()
	s.set_content_margin_all(UiLayoutRes.DETAIL_PAD)
	add_theme_stylebox_override("panel", s)
	UiLayoutRes.apply_rect(self, UiLayoutRes.DETAIL_RECT, false, true)

	# 整块面板的根：两行 —— 上面是左右两栏，下面是提示行（红字，出现时才占位）
	var root_box := VBoxContainer.new()
	root_box.name = "DetailBox"
	root_box.add_theme_constant_override("separation", 2)
	root_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_box)

	var cols := HBoxContainer.new()
	cols.name = "DetailCols"
	cols.add_theme_constant_override("separation", int(UiLayoutRes.DETAIL_GAP))
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root_box.add_child(cols)

	_build_left(cols, world, font)
	_build_right(cols, world)

	# 提示行：只有被拒时才出现（红字，约 2 秒）
	_notice = Label.new()
	_notice.name = "NoticeLine"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_notice.add_theme_color_override("font_color", UiStyleRes.WARN)
	_notice.visible = false
	root_box.add_child(_notice)


# ------------------------------------------------------------------
# 左栏：上半「当前展开的部队」+ 下半「选中部队的将领头像网格」
# ------------------------------------------------------------------
func _build_left(cols: HBoxContainer, world, font: Font) -> void:
	var left := Control.new()
	left.name = "DetailLeft"
	left.custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, 0.0)
	left.size_flags_horizontal = Control.SIZE_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(left)

	# 上半：当前展开的部队（绝对定位 —— 几何全在 ui_layout 里）
	_roster = UnitRosterRes.new()
	left.add_child(_roster)
	_roster.setup(world, font)
	var rd := UiLayoutRes.roster_detail_rect()
	_roster.position = rd.position
	_roster.size = rd.size
	_roster.block_activated.connect(_on_block_activated)

	# 没展开任何部队时的兜底文字（与其它面板的占位同一套灰字）
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "未选中"
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_empty_label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
	_empty_label.position = rd.position + Vector2(6.0, 6.0)
	left.add_child(_empty_label)

	# 下半：选中部队的将领头像网格
	_grid = TroopGridRes.new()
	left.add_child(_grid)
	_grid.setup(font)
	var gd := UiLayoutRes.troop_grid_rect()
	_grid.position = gd.position
	_grid.size = gd.size
	_grid.troop_activated.connect(_on_troop_activated)


# ------------------------------------------------------------------
# 右栏：选中单位（头像 / 名称 / buff / 数值）+ 招募队列
# ------------------------------------------------------------------
func _build_right(cols: HBoxContainer, world) -> void:
	var right := Control.new()
	right.name = "DetailRight"
	right.custom_minimum_size = Vector2(UiLayoutRes.DETAIL_RIGHT_W, 0.0)
	right.size_flags_horizontal = Control.SIZE_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.clip_contents = true
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(right)

	# 头像：64×64 的方块（没有头像素材 → 用字填充）。
	# ⚠️ 它**不是**贴着顶边：参考图里头像上面还留着一条（给「单位名称」那一行让位），
	#    位置与大小全部走 ui_layout 的 UNIT_* 常量。
	_unit_avatar = Control.new()
	_unit_avatar.name = "UnitAvatar"
	_unit_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_avatar.position = Vector2(0.0, UiLayoutRes.UNIT_AVATAR_Y)
	_unit_avatar.size = Vector2(UiLayoutRes.UNIT_AVATAR, UiLayoutRes.UNIT_AVATAR)
	_unit_avatar.draw.connect(_draw_unit_avatar)
	right.add_child(_unit_avatar)

	# 名称：36px 的大字，与头像同一水平线（参考图就是这个位置）
	var head_x := UiLayoutRes.UNIT_NAME_X
	_unit_name = Label.new()
	_unit_name.name = "UnitName"
	_unit_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_name.clip_text = true
	_unit_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_unit_name.add_theme_font_size_override("font_size", UiStyleRes.FS_UNIT_NAME)
	_unit_name.add_theme_color_override("font_color", UiStyleRes.TEXT)
	_unit_name.position = Vector2(head_x, UiLayoutRes.UNIT_NAME_Y)
	_unit_name.size = Vector2(UiLayoutRes.UNIT_NAME_W, 34.0)
	right.add_child(_unit_name)

	# buff 三格：排在头像右边、**与头像中线对齐**（参考图 y 406..434 就是这么排的）
	for i in UiLayoutRes.BUFF_SLOTS:
		var b := Label.new()
		b.name = "Buff%d" % (i + 1)
		b.text = String(BUFF_PLACEHOLDERS[i % BUFF_PLACEHOLDERS.size()])
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.clip_text = true
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		b.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
		b.position = Vector2(
			UiLayoutRes.BUFF_X + float(i) * (UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_GAP),
			UiLayoutRes.BUFF_Y)
		b.size = Vector2(UiLayoutRes.BUFF_SIZE, UiLayoutRes.BUFF_SIZE)
		b.draw.connect(_draw_buff_box.bind(b))
		right.add_child(b)
		_buffs.append(b)

	# 数值区：标题 + 正文（区划 / 建筑 / 多选汇总也画在这里）——
	# 参考图里它是头像**下面**一个独立的方框，所以这里也给它一块自己的底 + 描边。
	_detail_box = Panel.new()
	_detail_box.name = "DetailBox"
	_detail_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_box.position = Vector2(UiLayoutRes.DETAIL_BODY_X, UiLayoutRes.DETAIL_BODY_Y)
	_detail_box.size = Vector2(UiLayoutRes.DETAIL_BODY_W, UiLayoutRes.DETAIL_BODY_H)
	_detail_box.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.BG_EMPTY, UiStyleRes.LINE_SOFT))
	right.add_child(_detail_box)

	_detail_title = Label.new()
	_detail_title.name = "DetailTitle"
	_detail_title.text = "详细信息"
	_detail_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_title.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_detail_title.add_theme_color_override("font_color", UiStyleRes.ACCENT)
	_detail_title.position = Vector2(8.0, 4.0)
	_detail_title.size = Vector2(UiLayoutRes.DETAIL_BODY_W - 16.0, 18.0)
	_detail_box.add_child(_detail_title)

	_body = Label.new()
	_body.name = "DetailBody"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.clip_text = true
	_body.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	_body.add_theme_color_override("font_color", UiStyleRes.TEXT)
	_body.position = Vector2(8.0, 24.0)
	_body.size = Vector2(UiLayoutRes.DETAIL_BODY_W - 16.0, UiLayoutRes.DETAIL_BODY_H - 30.0)
	_detail_box.add_child(_body)

	# 招募队列：贴右栏**右上角**（只有正在招募时才出现；不可见时收不到鼠标事件）
	_queue = RecruitQueueRes.new()
	right.add_child(_queue)
	_queue.setup(world)
	_queue.position = Vector2(UiLayoutRes.QUEUE_X, UiLayoutRes.QUEUE_Y)
	_queue.cell_activated.connect(_on_queue_cell_activated)


# ------------------------------------------------------------------
# 显示
# ------------------------------------------------------------------

## 左栏：喂「当前展开的部队」与「下半网格要画的部队」。
##   @param troop  当前展开的那一支部队（null = 没展开 → 左栏上半收起来）
##   @param troops 下半网格要画的部队 —— **已经去掉展开的那一支**（由 hud 算好，见那里注释）
func set_troops(troop, troops: Array) -> void:
	if _roster != null:
		_roster.set_troop(troop, ROSTER_LEADER_LABEL)
	if _grid != null:
		_grid.set_troops(troops)
	if _empty_label != null:
		_empty_label.visible = troop == null


## 右栏：选中单位的**名称**（空串 = 没有选中单位 → 只留「详细信息」标题）
func set_unit_name(text: String) -> void:
	if _unit_name != null:
		_unit_name.text = text


## 右栏：数值区的正文（区划 / 建筑 / 单位数值 / buff 占位说明都由 hud 决定）
func set_detail(text: String) -> void:
	if _body != null:
		_body.text = text


## 右栏：数值区的标题（默认「详细信息」）
func set_detail_title(text: String) -> void:
	if _detail_title != null:
		_detail_title.text = text


## 右栏右上角的招募队列：显示哪个将领的（null = 没有选中将领 → 整块收起来）
func set_queue(leader) -> void:
	if _queue != null:
		_queue.set_leader(leader)


## 提示行（红字）。空串 = 收起来。
func set_notice(text: String) -> void:
	if _notice == null:
		return
	_notice.text = text
	_notice.visible = text != ""


# ------------------------------------------------------------------
# 转发信号（本层不认识「取消」「选中」这些概念）
# ------------------------------------------------------------------

func _on_queue_cell_activated(slot: int) -> void:
	queue_cell_activated.emit(slot)


func _on_troop_activated(number: int) -> void:
	troop_activated.emit(number)


func _on_block_activated(k: int) -> void:
	block_activated.emit(k)


# ------------------------------------------------------------------
# 右栏那两块自绘：头像方块 / buff 格子
# ------------------------------------------------------------------

## 头像方块里写的字（没有头像素材 → 用字填充）
var _avatar_text: String = ""


func _draw_unit_avatar() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(UiLayoutRes.UNIT_AVATAR, UiLayoutRes.UNIT_AVATAR))
	_unit_avatar.draw_rect(r, UiStyleRes.BG_EMPTY, true)
	_unit_avatar.draw_rect(r, UiStyleRes.LINE, false, 1.0)
	var f: Font = _unit_avatar.get_theme_default_font()
	var text := _avatar_text
	if text != "" and f != null:
		var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, UiStyleRes.FS_BIG).x
		var baseline := r.size.y * 0.5 + float(UiStyleRes.FS_BIG) * 0.5 - 6.0
		_unit_avatar.draw_string(f, Vector2((r.size.x - w) * 0.5, baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, UiStyleRes.FS_BIG, UiStyleRes.TEXT)


func set_unit_avatar_text(text: String) -> void:
	_avatar_text = text
	if _unit_avatar != null:
		_unit_avatar.queue_redraw()


func _draw_buff_box(b: Label) -> void:
	var r := Rect2(Vector2.ZERO, b.size)
	b.draw_rect(r, UiStyleRes.BG_EMPTY, true)
	b.draw_rect(r, UiStyleRes.LINE_SOFT, false, 1.0)


# ------------------------------------------------------------------
# 给测试用的小接口
# ------------------------------------------------------------------

## 右栏数值区的正文
func detail_text() -> String:
	return _body.text if _body != null else ""


## 右栏单位名称
func unit_name_text() -> String:
	return _unit_name.text if _unit_name != null else ""


## 左栏上半「当前展开的部队」（测试读它的分组与方块）
func roster_control() -> Control:
	return _roster


## 左栏下半「选中部队的将领头像网格」（测试读它的格数与点击）
func grid_control() -> Control:
	return _grid


func queue_control() -> Control:
	return _queue


func notice_text() -> String:
	return _notice.text if _notice != null else ""


func buff_count() -> int:
	return _buffs.size()


## 日志栏是否还在（按需求它必须**不在**：这条断言防止有人顺手加回来）
func has_log() -> bool:
	return get_node_or_null("LogBox") != null
