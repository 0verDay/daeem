## detail_panel.gd —— 底栏「详细信息」面板（988×**260**）
##
## ★★ 面板高度：参考图标的是 240，**本版按需求加高到 260**。底栏贴着屏幕下沿 ⇒
##    它是**向上长**的，底边仍在屏幕底部、顶边从 y=840 抬到 y=820，不会掉出屏幕。
##    多出来的 20px 全部给了右栏的数值框（96 → 116）。
##
## ★★ 第四轮改版（照新参考图逐像素重量的）：整块仍然是**左右两栏**，
##    但**左栏换成了「1 + 3×3 = 10 个格子」**（几何见 view/ui_layout.gd）：
##
##   左栏（350 宽）
##     ├─ 上半：**当前聚焦 / 唯一选中的那支部队（或建筑）的图标格**（view/unit_roster.gd）
##     │        左边 40×40 图标 + 右边两行「名字 / x÷y」
##     │        ★ 部队图标 = **序号 + 士气填充**；建筑 = 首字、无填充
##     └─ 下半：**3 行 × 3 列的可见窗口**（view/troop_grid.gd），三种语义共用：
##               · **选中多支部队** → 画**其余**选中部队的序号图标（聚焦的那支不重复出现）；
##                 点一格 = 把聚焦的部队换成它（同时右栏切到它的将领）。
##               · **只选中一支**   → 画这支部队的**单位**（第一个就是将领本人）；
##                 点一格 = 右栏切到那个单位；超过 9 个时可**左右滑动**（滚轮按页）。
##               · **选中建筑**     → 左上那一格 = **主选中**的建筑，下面 = 其余选中的建筑；
##                 点一格 = 把右栏详情切到那个建筑；超过 9 个同样可左右滑动。
##
##   右栏（603 宽，本版重排成「顶带 + 下半并排 + 提示带」）
##     y   0.. 96  顶带：选中单位的**头像**（72×72）+「单位名称」+
##                 一行**动态 buff 槽位**（40×40；当前士气系统挂一条「士」）
##     y 100..216  下半：**详细信息框（282 宽）+ 4px 缝 + 招募队列（313 宽）** 并排
##                 · 详情框 = 两列表格（血量/攻击 | 移速/防御；区划中心 = 类型/大小 | 产能）
##                 · 招募队列与详情框**上下缘齐平**（本版按需求从顶带搬下来）
##                 两者都只在对应内容存在时出现；队列不可见时不挡鼠标
##     y 220..240  **红字提示**（操作被拒的原因，约 ui.notice_sec 秒，见 hud.show_notice）
##
## ★★ 第六轮那三处对齐（起因：右栏几块的对齐边各走各的，看着像四块补丁）：
##   · 头像 / 名称上移到 y=0，与左栏第一块方块齐平；
##   · 数值框宽度 606 → 645（第六轮）→ **603**（2026.10.20 底栏缩放后），右缘与队列右缘对齐；
##   · 提示行从面板 VBox 搬进右栏底下那条 20px，**出现时不再压扁两栏**。
##   ⚠️ 前两条改了 ui_layout 里的 UNIT_AVATAR_Y / UNIT_NAME_Y / BUFF_X / DETAIL_BODY_*，
##      被 tests/test_ui.gd 的几何断言盯着（改了要一起改）。
##
## ★ 右栏显示谁（由 hud 决定，规则原话在手玩那边）：
##   · 玩家**拖拽框选**选中的部队 → 默认显示展开那支部队的**将领**；
##   · 玩家**鼠标单击**选中某个单位 → 默认显示**玩家点到的那个单位**。
##
## ★ 按需求砍掉的东西（别再默默加回来）：
##   · **旧的单栏数值正文**（血量 / 士气 / 攻击力 / 攻击距离那一整段）—— 本版换成
##     两列表格；旧的 7 行区划文案也不再使用（见 hud 的 `_*_detail_rows`）。
##   · **三个写死的 buff 占位**（「buff1/2/3」）—— 换成 view/buff_bar.gd 的动态槽位。
##   · **单位 / 建筑图标的纯色背景填充** —— 现在只有「图标 + 底部血条」，没有士气底色；
##     士气只画在**部队**图标上（序号 + 自下而上的士气填充，见 view/icon_badge.gd）。
##   · **「阵营 + 粮食 + 黄金」那一行资源 —— 本轮按参考图删掉了**
##   · **选中单位的那些汇总文字**（队伍人数 / 合计生命 / 指定攻击 / 状态）—— 一并删掉。
##   · **数值区顶上那行「详细信息」标题**（用户原话：「把所有的详细信息栏的『详细信息』字样去除」）。
##   · **选中单位那三条之外的一切**：第二栏（编制 / 状态）、「已选中 N 支部队」、
##     「兵种 …（步兵）」—— 见 hud 的 `_unit_detail_rows`。
##   · **建筑详情里的「升级到 N 级：花费（时间）」那两行**（含满级那句「已经是最高等级」）、
##     大本营那句「开局自带，不可建造、不可拆除」，以及区划详情开头那行「区划「xx」」
##   · **建筑 / 区划详情里的「归属」与「位置」两行**（选中建筑那一轮按需求精简掉），
##     以及区划产能后面的「／地块／秒」和大本营那句锁血注释
##   · 己方地块 / 区块 / 建造模式 / 暂停 —— 都不显示
##   · **整块事件日志** —— 日志栏已经删掉（事件仍然由 logic 收集，只是没有界面画它，
##     见 view/hud.gd 末尾那段说明）。⚠️ 那行红字提示**不是**日志栏：
##     它只显示「最近一次操作被拒」的一句话，不保留历史、不进快照。
##   · 左栏的各种操作提示（左键选单位 / 右键移动 / 快捷键…）
##   · 左栏上半那排**单位小方块 + 滚轮横滚** —— 单位搬进了下面 3×3 的网格里
##
## ★ 只负责显示 + 把「点了哪一格」原样抛出去：文本从哪来由 hud.gd 决定。
extends PanelContainer

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const IconBadgeRes = preload("res://view/icon_badge.gd")
const DetailRowsRes = preload("res://view/detail_rows.gd")
const BuffBarRes = preload("res://view/buff_bar.gd")
const RecruitQueueRes = preload("res://view/recruit_queue.gd")
const UnitRosterRes = preload("res://view/unit_roster.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")

## 点到了招募队列的某一格（0 = 正在读条的大格子，1..4 = 排队的小格子）。
## 原样转发给 hud.gd —— 由它翻译成 input_controller 的取消命令。
signal queue_cell_activated(slot: int)
## 点了左栏下半网格里的一格**将领**（带**部队编号**，1 起）。
## 原样转发给 hud.gd —— 「换成展开那支部队 + 右栏切到它的将领」由它做。
signal troop_activated(number: int)
## 点了左栏下半网格里的一格**单位**（带格下标；只选中一支部队时才是单位格）。
## 原样转发给 hud.gd —— 「右栏切到那个单位」由它做。
signal unit_activated(index: int)
## 点了左栏下半网格里的一格**建筑**（带格下标；选中建筑时才有建筑格）。
## 原样转发给 hud.gd —— 「右栏详情切到那个建筑」由它做。
signal building_activated(index: int)

## 左栏第一格右边那行小字：参考图上写的就是「将领名称」（不是将领真名）——
## 手玩原话：「两行：『将领名称』+『1/11』」。
const ROSTER_LEADER_LABEL := "将领名称"

var _world = null
var _roster: Control
var _grid: Control
var _notice: Label
var _queue: Control
## 右栏整块（宽 **603 固定**；`_layout_right` 仍按实际宽度摆内部几块）
var _right: Control

# 右栏
var _unit_avatar: Control
var _unit_name: Label
## 动态 buff 槽位（不写死占位；HUD 每帧 set_buffs）
var _buff_bar: Control
var _detail_box: Panel
## 两列表格（血量/攻击 | 移速/防御；区划中心另算）
var _rows: Control

# 左栏上半「未选中」时的兜底文字
var _empty_label: Label


func setup(world = null, font: Font = null) -> void:
	_world = world
	name = "DetailPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP
	var s := UiStyleRes.panel_style()
	s.set_content_margin_all(UiLayoutRes.DETAIL_PAD)
	add_theme_stylebox_override("panel", s)
	# ★★ 本版按需求**不再横向拉伸**：手机端不需要和右下角页签栏相连，尺寸恰好即可。
	#   固定 `DETAIL_RECT`（988×260，贴左、贴底）；视口比 16:9 宽时右侧留白，
	#   不再把多出来的宽灌进右栏（那会把面板拉得很长、里面一大片空）。
	UiLayoutRes.apply_fixed_detail(self)

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
	_build_right(cols, world, font)
	# ★ 提示行不再挂在 root_box（VBox）上 —— 它现在是**右栏里的绝对定位浮层**，
	#   见 `_build_notice()` 与 ui_layout 的 NOTICE_Y 注释（原来一出现就把两栏压扁 20px）。


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

	# 没展开任何部队时的兜底文字（与其它面板的占位同一套灰字）
	_empty_label = Label.new()
	_empty_label.name = "EmptyLabel"
	_empty_label.text = "未选中"
	_empty_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_empty_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
	_empty_label.position = rd.position + Vector2(6.0, 6.0)
	left.add_child(_empty_label)

	# 下半：3×3 的网格（多选 = 其余部队的将领；单选 = 这支部队的单位）
	_grid = TroopGridRes.new()
	left.add_child(_grid)
	_grid.setup(font)
	var gd := UiLayoutRes.troop_grid_rect()
	_grid.position = gd.position
	_grid.size = gd.size
	_grid.troop_activated.connect(_on_troop_activated)
	_grid.unit_activated.connect(_on_unit_activated)
	_grid.building_activated.connect(_on_building_activated)


# ------------------------------------------------------------------
# 右栏：选中单位（头像 / 名称 / 动态 buff / 两列详情）+ 招募队列
# ------------------------------------------------------------------
func _build_right(cols: HBoxContainer, world, font: Font) -> void:
	var right := Control.new()
	right.name = "DetailRight"
	_right = right
	right.custom_minimum_size = Vector2(UiLayoutRes.DETAIL_RIGHT_W, 0.0)
	# ★★ 本版不再横向拉伸：面板固定 988 宽，右栏因此固定 603（左栏 350 + 缝 15）。
	#    容器仍用 SIZE_EXPAND_FILL 只是让它在固定宽里把高度撑满，不会再加宽。
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.clip_contents = true
	right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cols.add_child(right)

	# 头像：72×72 的方框；没有头像素材 → 用字填充（字号按方框现算）。
	_unit_avatar = Control.new()
	_unit_avatar.name = "UnitAvatar"
	_unit_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_avatar.position = Vector2(UiLayoutRes.UNIT_AVATAR_X, UiLayoutRes.UNIT_AVATAR_Y)
	_unit_avatar.size = Vector2(UiLayoutRes.UNIT_AVATAR, UiLayoutRes.UNIT_AVATAR)
	_unit_avatar.draw.connect(_draw_unit_avatar)
	right.add_child(_unit_avatar)

	# 名称：右栏最大的字，与头像上半部同一水平线。
	var head_x := UiLayoutRes.UNIT_NAME_X
	_unit_name = Label.new()
	_unit_name.name = "UnitName"
	_unit_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_name.clip_text = true
	_unit_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_unit_name.add_theme_font_size_override("font_size", UiStyleRes.FS_UNIT_NAME)
	_unit_name.add_theme_color_override("font_color", UiStyleRes.text())
	_unit_name.position = Vector2(head_x, UiLayoutRes.UNIT_NAME_Y)
	_unit_name.size = Vector2(UiLayoutRes.UNIT_NAME_W, UiStyleRes.FS_UNIT_NAME + 6.0)
	right.add_child(_unit_name)

	# ★★ 动态 buff 槽位（本版去掉三个写死的占位）：
	#   由 HUD 每帧 `set_buffs([{id, text, color, name}])` 喂；当前至少会有一条「士气」。
	_buff_bar = BuffBarRes.new()
	right.add_child(_buff_bar)
	_buff_bar.setup(font)
	_buff_bar.position = Vector2(UiLayoutRes.BUFF_X, UiLayoutRes.BUFF_Y)
	_buff_bar.size = Vector2(UiLayoutRes.detail_buff_w(UiLayoutRes.DETAIL_RIGHT_W),
		UiLayoutRes.BUFF_SIZE)

	# 数值区：本版**向左收窄**（右缘 = 招募队列左缘前 4px），
	# 里面是两列表格（左 = 血量/攻击，右 = 移速/防御；区划中心另算）。
	_detail_box = Panel.new()
	_detail_box.name = "DetailBox"
	_detail_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_box.position = Vector2(UiLayoutRes.DETAIL_BODY_X, UiLayoutRes.DETAIL_BODY_Y)
	_detail_box.size = Vector2(UiLayoutRes.detail_body_w(UiLayoutRes.DETAIL_RIGHT_W),
		UiLayoutRes.DETAIL_BODY_H)
	_detail_box.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg_empty(), UiStyleRes.line_soft()))
	right.add_child(_detail_box)

	_rows = DetailRowsRes.new()
	_detail_box.add_child(_rows)
	_rows.setup(font)
	_rows.position = Vector2(UiLayoutRes.DETAIL_BODY_PAD, UiLayoutRes.DETAIL_BODY_TEXT_Y)
	_rows.size = Vector2(UiLayoutRes.detail_rows_w(UiLayoutRes.DETAIL_RIGHT_W),
		UiLayoutRes.DETAIL_BODY_ROWS_H)

	# 招募队列：本版搬到**下方**，与数值框上下缘对齐（y = DETAIL_BODY_Y，高 = 116）。
	# 只有正在招募时才出现；不可见时收不到鼠标事件。
	_queue = RecruitQueueRes.new()
	right.add_child(_queue)
	_queue.setup(world)
	_queue.position = Vector2(UiLayoutRes.QUEUE_X, UiLayoutRes.QUEUE_Y)
	_queue.cell_activated.connect(_on_queue_cell_activated)

	_build_notice(right)

	# ★★ buff 条摆到最后一个子节点：它的悬停浮窗会画到方块下面（详情框 / 队列之上）。
	#   它自己的矩形只有 40 高，不挡任何东西；放在最后只影响「浮窗盖住谁」。
	if _buff_bar != null:
		right.move_child(_buff_bar, right.get_child_count() - 1)

	# ★★ 按右栏宽度（固定 603）摆好「钉右 / 跟宽」的那几块；
	#    仍接 resized 信号，纯粹是布局兜底（正常不会变宽）。
	_layout_right(UiLayoutRes.DETAIL_RIGHT_W)
	right.resized.connect(_on_right_resized.bind(right))


## ★★ 右栏里「钉右 / 跟宽」的子控件按**当前右栏宽度**重摆：
##   · 数值框：**固定 282 宽**（向左收窄，不再跟右栏拉伸）；
##   · 两列表格：跟着数值框的内宽；
##   · 动态 buff：左起 84，右到招募队列左缘前 4px；
##   · 招募队列：x = 右栏宽 − QUEUE_MARGIN − QUEUE_W（右缘不动），y = 100；
##   · 单位名称：可写宽缩到招募队列左缘之前（留 8px）；
##   · 提示行：横跨详情框 + 队列（右栏宽 − QUEUE_MARGIN）。
## ★ 头像 / buff / 名称起点都是左对齐的，不随宽度动 —— 所以不在这一函数里。
func _layout_right(right_w: float) -> void:
	# ★ 兜底：容器布局途中可能给一个 0 / 很小的宽度（此时算出来是负数）。
	#   夹到基准宽（603）—— 比「负尺寸」稳，也不会让某一块突然翻到左边去。
	right_w = maxf(right_w, UiLayoutRes.DETAIL_RIGHT_W)
	if _detail_box != null:
		_detail_box.size.x = UiLayoutRes.detail_body_w(right_w)
	if _rows != null:
		_rows.size = Vector2(UiLayoutRes.detail_rows_w(right_w),
			UiLayoutRes.DETAIL_BODY_ROWS_H)
	if _buff_bar != null:
		_buff_bar.size.x = UiLayoutRes.detail_buff_w(right_w)
	if _queue != null:
		_queue.position = Vector2(UiLayoutRes.detail_queue_x(right_w), UiLayoutRes.QUEUE_Y)
	if _unit_name != null:
		_unit_name.size.x = UiLayoutRes.detail_name_w(right_w)
	if _notice != null:
		_notice.size.x = UiLayoutRes.detail_notice_w(right_w)


func _on_right_resized(right: Control) -> void:
	_layout_right(right.size.x)


## 提示行（红字）：**右栏数值框下面那一条 20px**，绝对定位的浮层。
##
## ★★ 它以前是面板 VBox 的第二行 —— 一出现就让上面那两栏各少 20px，
##    而左栏那 3×3 网格是一整段铺满内容高的（40 + 15 + 3×55），于是最下面一截
##    被裁掉（`right` 有 clip_contents，右栏的数值框也会被切掉底边）。
##    现在它住进数值框下面**本来就空着**的那条带（NOTICE_Y..NOTICE_Y+NOTICE_H），
##    出现 / 消失都不动任何一块的几何。
## ★ `clip_text = true`：文案再长也只在这条带里被裁，不会横着顶出面板
##   （最长的两句实测 405px / 360px ≤ 右栏 603，正常情况根本碰不到裁剪）。
func _build_notice(right: Control) -> void:
	_notice = Label.new()
	_notice.name = "NoticeLine"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.clip_text = true
	_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_notice.add_theme_color_override("font_color", UiStyleRes.warn())
	_notice.position = Vector2(0.0, UiLayoutRes.NOTICE_Y)
	_notice.visible = false
	right.add_child(_notice)
	# ⚠️ size 必须在 **add_child 之后**再设：控件还没在树上时主题（= 中文字体）还没继承到，
	#    Label 的最小高度按**引擎兜底字体**算出来是 23px > 20px，于是 `set_size` 当场被夹成 23，
	#    整个提示带就顶出右栏下沿（实测：200 + 23 = 223 > 当时的内容高 220；
	#    现在内容高 240、提示带在 220..240，夹成 23 也只是压到 243 —— 仍在面板内）。
	# ★ 宽度取 `UNIT_CONTENT_RIGHT`（= 599）：横跨详情框 + 招募队列，与右栏公共右缘对齐。
	_notice.size = Vector2(UiLayoutRes.UNIT_CONTENT_RIGHT, UiLayoutRes.NOTICE_H)


# ------------------------------------------------------------------
# 显示
# ------------------------------------------------------------------

## 左栏：喂「当前展开的部队」与「下半网格要画的东西」。
##   @param troop  当前展开的那一支部队（null = 没展开 → 左栏上半收起来）
##   @param troops 多选时下半网格要画的部队 —— **已经去掉展开的那一支**（由 hud 算好）
##   @param units  单选时下半网格要画的**单位**（含将领本人，第一个就是将领）。
##                 非空 → 走单位模式（滚轮翻页），此时 `troops` 被忽略。
##   @param unit_shorts 与 `units` 一一对应的方框短字（由 hud 用 world 算好：
##                 将领 =「将」、可招募兵种 =「兵」）
func set_troops(troop, troops: Array, units: Array = [], unit_shorts: Array = []) -> void:
	if _roster != null:
		_roster.set_troop(troop, ROSTER_LEADER_LABEL)
	if _grid != null:
		if troop == null:
			_grid.clear()
		elif not units.is_empty():
			_grid.set_units(units, unit_shorts)
		else:
			_grid.set_troops(troops)
	if _empty_label != null:
		_empty_label.visible = troop == null


## 左栏：喂「选中的建筑」——同一个 1 + 3×3 版式（见文件头与 view/troop_grid.gd）。
##   @param entries 选中的建筑，每项：{"ref": 建筑, "name": 显示名, "short": 方框短字,
##                  "sub": 第二行（血量 x/y）} —— 顺序 = 选中顺序（由 hud 组装好）
##   @param primary 主选中（**右栏正在显示**）的那一个：画在左上第 1 格；
##                  其余的画在下面 3×3 网格里（点一格 = 换成把右栏切过去）。
func set_buildings(entries: Array, primary) -> void:
	var rest: Array = []
	var main_entry: Dictionary = {}
	for e in entries:
		if e is Dictionary and (e as Dictionary).get("ref", null) == primary and main_entry.is_empty():
			main_entry = e
		else:
			rest.append(e)
	if _roster != null:
		if main_entry.is_empty():
			_roster.set_entry(null)
		else:
			# ★ 左上那一格与部队共用同一个落点（`unit_roster.set_entry`）：
			#   建筑 = 首字图标 + 底部血条，**没有士气填充**。
			var e: Dictionary = (main_entry as Dictionary).duplicate()
			var ref = e.get("ref", null)
			e["kind"] = "building"
			e["icon"] = String(e.get("short", ""))
			e["show_hp"] = ref != null
			e["hp"] = 1.0 if ref == null else float(ref.hp_ratio())
			_roster.set_entry(e)
	if _grid != null:
		if main_entry.is_empty():
			_grid.clear()
		else:
			_grid.set_buildings(rest)
	if _empty_label != null:
		_empty_label.visible = main_entry.is_empty()


## 下半网格现在是什么模式（给 hud / 测试读）：
## "leaders" | "units" | "buildings" | "empty"
func grid_mode() -> String:
	if _grid == null or not _grid.visible:
		return "empty"
	match _grid.mode:
		TroopGridRes.MODE_LEADERS:
			return "leaders"
		TroopGridRes.MODE_BUILDINGS:
			return "buildings"
	return "units"


## 右栏：选中单位的**名称**（空串 = 没有选中单位 → 数值框里只剩「未选中」/空）
func set_unit_name(text: String) -> void:
	if _unit_name != null and _unit_name.text != text:
		_unit_name.text = text


## 右栏：**动态 buff 槽位**。每条 `{id, text, color, name}`（空数组 = 一个都不画）。
## ★ 当前至少会有士气系统给单位挂的一条「士」；以后别的系统直接往数组里追加。
func set_buffs(entries: Array) -> void:
	if _buff_bar != null:
		_buff_bar.set_buffs(entries)


## 右栏：两列表格（区划 / 建筑 / 单位都由 hud 组装成**行**递进来）。
##
## ★ 行格式：`{"text": String, "small": bool, "dim": bool}`，也接受纯字符串。
##   左列 = 血量 / 攻击力（+攻击增益）；右列 = 移动速度 / 防御力（+防御增益）；
##   区划中心则是「类型 / 大小 | 产能」。具体文案的组装**只有一处**（hud），
##   这一层只负责把两列画出来（view/detail_rows.gd）。
func set_detail_rows(left_rows: Array, right_rows: Array) -> void:
	if _rows != null:
		_rows.set_rows(left_rows, right_rows)


## 兼容旧接口：`左 \t 右` 的纯文本 → 两列普通行（老测试 / 临时调用用）。
## ⚠️ 新代码请直接走 `set_detail_rows()`，这样增益行才能用 11 号小字。
func set_detail(text: String) -> void:
	var left: Array = []
	var right: Array = []
	for row in text.split("\n"):
		var parts: PackedStringArray = String(row).split("\t")
		left.append(parts[0])
		right.append(parts[1] if parts.size() > 1 else "")
	set_detail_rows(left, right)


## 测试读口：主数值行用的字号（增益行会更小，见 detail_rows.gd）。
func body_font_size() -> int:
	return UiStyleRes.FS_SMALL


## 测试读口：两列表格没有整块行距覆盖（行高固定 17）。
func body_line_spacing() -> int:
	return 0


## 右栏右上角的招募队列：显示哪个将领 / 哪个区划的（null = 没有 → 整块收起来）
## @param is_zone true = holder 是一个**区划字典**（选中区划中心时的区划招募队列）
## ★ 调它 = 退出「单条读条」模式（建筑升级 / 区划特化 —— 那块面板被两种内容复用）
func set_queue(holder, is_zone: bool = false) -> void:
	if _queue != null:
		_queue.set_queue(holder, is_zone)


## ★★ 右栏右上角显示**一条读条**（建筑升级 / 区划特化 —— 复用招募队列那块面板）。
##
## 需求原话：「点击后开始读条（和招募单位时的读条一样，可以复用招募单位的面板）」。
## @param title 汇总带第一行（「升级大本营」/「粮食特化」/「取消特化」…）；空串 = 收起来
## @param label 大格子里那一行字（「升 2 级」/「粮食」…）
## @param progress / remaining 由**逻辑层**算好传进来（视图不自己推，pitfalls 5.20）
## @param cancellable 现在能不能点它取消
func set_progress_bar(title: String, label: String, progress: float, remaining: float,
		cancellable: bool = true) -> void:
	if _queue != null:
		_queue.set_bar(title, label, progress, remaining, cancellable)


## 右栏那块队列面板现在是不是「单条读条」模式（hud 用它决定点击该发哪条取消命令）
func queue_is_bar() -> bool:
	return _queue != null and _queue.is_bar_mode()


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


func _on_unit_activated(index: int) -> void:
	unit_activated.emit(index)


func _on_building_activated(index: int) -> void:
	building_activated.emit(index)


# ------------------------------------------------------------------
# 右栏那两块自绘：头像方块 / buff 格子
# ------------------------------------------------------------------

## 头像方块里写的字（没有头像素材 → 用字填充）
var _avatar_text: String = ""
## 头像那一块画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var _avatar_draws: int = 0
## 头像底部那条**血量条**：比例 0..1 + 要不要画（区划 / 未选中 → 不画）。
var _avatar_hp_ratio: float = 1.0
var _avatar_hp_visible: bool = false
## 头像血条画过几帧（测试读它，理由同 `_avatar_draws`）
var _avatar_bar_draws: int = 0


func _draw_unit_avatar() -> void:
	_avatar_draws += 1
	var side := UiLayoutRes.UNIT_AVATAR
	var r := Rect2(Vector2.ZERO, Vector2(side, side))
	var f: Font = _unit_avatar.get_theme_default_font()
	var fs: int = _avatar_font_size(f) if f != null else UiStyleRes.FS_TITLE
	# ★★ 本版按需求：头像**没有纯色背景填充**（原来的士气背景板已去掉），
	#   只画边框 + 字 + 底部血条。
	#   （交战中 / 选中的强调不在这里做：右栏头像只表示「现在看的是谁」。）
	IconBadgeRes.draw(_unit_avatar, f, r, "unit", _avatar_text, 1.0,
		_avatar_hp_ratio, _avatar_hp_visible, fs, UiStyleRes.line(), 1.0)
	if _avatar_hp_visible:
		_avatar_bar_draws += 1


## 头像方框里那个字该用多大：**按方框量出来的**，不是写死的字号。
##
## ★ 这里踩过两次（手玩报的「头像里的字右下对齐」）：
##   ① 方框是 40×40，字号写的是 `FS_BIG = 44` —— 汉字的字面高≈字号，44 的字塞进 40 的框
##      **根本装不下**，而 `draw_string` 会被画布裁到控件矩形里 ⇒ 看起来就是
##      「字被推到右下角、还被切掉一角」；
##   ② 方框本身也画错了大小（参考图上它是 **100×100**，不是 40）。
## ⇒ 做法：按方框边长要一个字号（用「一个字的字宽占字号的多少」换算），
##   再量一次**实际渲染尺寸**，超了就按比例缩回去 —— 保证真的装得下、且尽量填满。
func _avatar_font_size(f: Font) -> int:
	var side := UiLayoutRes.UNIT_AVATAR
	# 汉字在 SimHei 下一字的字宽 ≈ 字号（量出来的比例），据此先估一个
	var ratio := maxf(0.2, f.get_string_size("字", HORIZONTAL_ALIGNMENT_LEFT, -1,
		UiStyleRes.FS_BIG).x / float(UiStyleRes.FS_BIG))
	var size := maxi(1, int((side - 6.0) / ratio))
	for _i in 40:
		var sz := f.get_string_size(_avatar_text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		if sz.x <= side - 4.0 and sz.y <= side - 4.0:
			break
		size = maxi(1, size - 1)
	return size


## 在这个矩形里居中画字已经交给 view/icon_badge.gd（三处图标共用同一套基线算法）。
## 这里只保留「按方框量字号」这一段 —— 72×72 的头像要尽量填满，不能写死字号。


func set_unit_avatar_text(text: String) -> void:
	if _avatar_text == text:
		return
	_avatar_text = text
	if _unit_avatar != null:
		_unit_avatar.queue_redraw()


## 右栏头像底下那条**血量条**：`show=false`（区划 / 没选中）→ 不画。
func set_unit_avatar_hp(ratio: float, show: bool) -> void:
	var r := clampf(ratio, 0.0, 1.0)
	if _avatar_hp_visible == show and is_equal_approx(_avatar_hp_ratio, r):
		return
	_avatar_hp_ratio = r
	_avatar_hp_visible = show
	if _unit_avatar != null:
		_unit_avatar.queue_redraw()


## 头像那一块画过几帧（测试读它：确认 `_draw` 真的跑过）
func avatar_draw_count() -> int:
	return _avatar_draws


## 头像血条画过几帧（测试读它）
func avatar_bar_draw_count() -> int:
	return _avatar_bar_draws


# ------------------------------------------------------------------
# 给测试用的小接口
# ------------------------------------------------------------------

## 右栏两列表格的文本：两列**合回**「左 \t 右」的样子
## （文案对不对的断言都在这个出口上；两列各自的内容用下面两个读口）。
func detail_text() -> String:
	return _rows.text() if _rows != null else ""


## 正文**左列**的实际文本
func detail_left_text() -> String:
	return _rows.left_text() if _rows != null else ""


## 正文**右列**的实际文本
func detail_right_text() -> String:
	return _rows.right_text() if _rows != null else ""


## 两列表格控件（测试读行数 / 字号 / 画帧）
func detail_rows_control() -> Control:
	return _rows


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


## 动态 buff 槽位控件（测试读条目 / 方块位置）
func buff_bar_control() -> Control:
	return _buff_bar


func buff_count() -> int:
	return _buff_bar.count() if _buff_bar != null else 0


# ------------------------------------------------------------------
# 给测试读「右栏当前摆成什么样」
# ------------------------------------------------------------------

## 右栏控件（固定 603 宽）
func right_column_control() -> Control:
	return _right


## 右栏当前宽度（无头下未布局时是 `custom_minimum_size.x`）
func right_column_width() -> float:
	return _right.size.x if _right != null else 0.0


## 数值框（正文背景板）当前尺寸
func detail_box_size() -> Vector2:
	return _detail_box.size if _detail_box != null else Vector2.ZERO


## 招募队列控件当前的 x（右缘 = 面板右缘 − QUEUE_MARGIN）
func queue_position_x() -> float:
	return _queue.position.x if _queue != null else 0.0


## 单位名称 Label 当前可写宽
func unit_name_width() -> float:
	return _unit_name.size.x if _unit_name != null else 0.0


## 日志栏是否还在（按需求它必须**不在**：这条断言防止有人顺手加回来）
func has_log() -> bool:
	return get_node_or_null("LogBox") != null
