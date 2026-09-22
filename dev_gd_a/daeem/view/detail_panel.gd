## detail_panel.gd —— 底栏「详细信息」面板（1030×240）
##
## ★★ 第四轮改版（照新参考图逐像素重量的）：整块仍然是**左右两栏**，
##    但**左栏换成了「1 + 3×3 = 10 个格子」**（几何见 view/ui_layout.gd）：
##
##   左栏（350 宽）
##     ├─ 上半：**当前展开 / 唯一选中的那支部队的将领格**（view/unit_roster.gd）
##     │        左上角 1 个 40×40 方框 + 右边一行「将领名称 x/y」
##     └─ 下半：**3×3 = 9 格的网格**（view/troop_grid.gd），两种语义共用：
##               · **选中多支部队** → 画**其余**选中部队的将领（展开的那支不重复出现）；
##                 点一格 = 把展开的部队换成它（同时右栏切到它的将领）。
##               · **只选中一支**   → 画这支部队的**单位**（第一个就是将领本人）；
##                 点一格 = 右栏切到那个单位；超过 9 个时滚轮**翻页**（一次一页）。
##
##   右栏（645 宽，第六轮排成「三条带 + 一条提示带」，几何见 ui_layout 那段注释）
##     y   0.. 72  选中单位的**头像**（72×72）+「单位名称」+ 一行 **buff 图标**（占位，无效果）
##                 右上角还有招募队列（view/recruit_queue.gd，只有正在招募时才出现）：
##                 左边 129px 汇总带（「招募队列 3/5」+「共 22s」）+ 1 大 4 小五个格子
##     y  80..196  「详细信息」数值区（血量 / 攻击力 / 射程 / 状态…）—— **横跨整个右栏**
##     y 200..220  **红字提示**（操作被拒的原因，约 ui.notice_sec 秒，见 hud.show_notice）
##
## ★★ 第六轮那三处对齐（起因：右栏几块的对齐边各走各的，看着像四块补丁）：
##   · 头像 / 名称上移到 y=0，与左栏第一块方块齐平；
##   · 数值框宽度 606 → 645（右缘与招募队列的右缘对齐，不再是锯齿）；
##   · 提示行从面板 VBox 搬进右栏底下那条 20px，**出现时不再压扁两栏**。
##   ⚠️ 前两条改了 ui_layout 里的 UNIT_AVATAR_Y / UNIT_NAME_Y / BUFF_X / DETAIL_BODY_*，
##      被 tests/test_ui.gd 的几何断言盯着（改了要一起改）。
##
## ★ 右栏显示谁（由 hud 决定，规则原话在手玩那边）：
##   · 玩家**拖拽框选**选中的部队 → 默认显示展开那支部队的**将领**；
##   · 玩家**鼠标单击**选中某个单位 → 默认显示**玩家点到的那个单位**。
##
## ★ 按需求砍掉的东西（别再默默加回来）：
##   · **「阵营 + 粮食 + 黄金」那一行资源 —— 本轮按参考图删掉了**
##   · **选中单位的那些汇总文字**（队伍人数 / 合计生命 / 指定攻击 / 状态）—— 一并删掉；
##     现在右栏只画「详细信息」这一块数值
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
## 正文**左栏**（单栏文本也用它）与**右栏**（只有两栏文本才显示）
var _body: Label
var _body_right: Label

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
	_empty_label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
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

	# 头像：**100×100** 的方框（参考图实测 x 806..905、y 860..959，就是 100×100）。
	# ⚠️ 这里改过两次（手玩报的「头像不对」）：
	#   ① 方框 40×40 + 字号 44：字比方框大 ⇒ 被裁成右下角一块；
	#   ② 方框本身也画小了 —— 参考图上它是 100×100，不是 40。
	#   没有头像素材 → 方框里用字填充（字号按方框现算，见 _avatar_font_size）。
	_unit_avatar = Control.new()
	_unit_avatar.name = "UnitAvatar"
	_unit_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_avatar.position = Vector2(UiLayoutRes.UNIT_AVATAR_X, UiLayoutRes.UNIT_AVATAR_Y)
	_unit_avatar.size = Vector2(UiLayoutRes.UNIT_AVATAR, UiLayoutRes.UNIT_AVATAR)
	_unit_avatar.draw.connect(_draw_unit_avatar)
	right.add_child(_unit_avatar)

	# 名称：右栏最大的字（参考图实测四个字宽 110、字高约 28 ⇒ 字号 29），
	# 与头像**上半部**同一水平线（参考图 y 881..908，头像 y 860..959）。
	var head_x := UiLayoutRes.UNIT_NAME_X
	_unit_name = Label.new()
	_unit_name.name = "UnitName"
	_unit_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_unit_name.clip_text = true
	_unit_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_unit_name.add_theme_font_size_override("font_size", UiStyleRes.FS_UNIT_NAME)
	_unit_name.add_theme_color_override("font_color", UiStyleRes.TEXT)
	_unit_name.position = Vector2(head_x, UiLayoutRes.UNIT_NAME_Y)
	_unit_name.size = Vector2(UiLayoutRes.UNIT_NAME_W, UiStyleRes.FS_UNIT_NAME + 6.0)
	right.add_child(_unit_name)

	# buff 三格：排在头像右边、**与头像下半同一水平线**
	# （参考图实测 30×30 的三格在 y 930..959，正好落在 100 高的头像下缘那一段）
	for i in UiLayoutRes.BUFF_SLOTS:
		var b := Label.new()
		b.name = "Buff%d" % (i + 1)
		b.text = String(BUFF_PLACEHOLDERS[i % BUFF_PLACEHOLDERS.size()])
		b.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		b.clip_text = true
		# ★ 方框 30 → **40**（与左栏那些 40×40 的方块同一号尺寸），字号 11 → 13：
		#   占位文案「buff1」在 13 号下实测 33px ≤ 40，装得下；而 30×30 + 11 号字
		#   在放大的右栏里看着像两个小疙瘩（手玩：「ui 内容也太小了」）。
		#   `tests/test_ui.gd` 里有一条断言按真实字体量这件事（别改回去）。
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		b.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
		b.position = Vector2(
			UiLayoutRes.BUFF_X + float(i) * (UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_GAP),
			UiLayoutRes.BUFF_Y)
		b.size = Vector2(UiLayoutRes.BUFF_SIZE, UiLayoutRes.BUFF_SIZE)
		b.draw.connect(_draw_buff_box.bind(b))
		right.add_child(b)
		_buffs.append(b)

	# 数值区：标题 + 正文（单位 / 建筑 / 区划的数值）——
	# 横跨整个右栏的一个独立方框，左边缘与头像对齐。
	# ★★ 本轮重排（手玩报的「太拥挤」）：方框 90 → 116 高，正文 FS_TINY(11) → FS_SMALL(13)
	#    且行距回正（原来是 -1，硬压出来的）。正文改成**两栏制表位**，
	#    见下面 _body 的注释与 hud._unit_text()。
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
	_detail_title.position = Vector2(8.0, 3.0)
	_detail_title.size = Vector2(UiLayoutRes.DETAIL_BODY_W - 16.0, 18.0)
	_detail_box.add_child(_detail_title)

	# 正文：**真·两栏** = 两个 Label（左栏 / 右栏），x 由 ui_layout 定死。
	#   ★★ 第七轮修的：以前是一整段带 `\t` 的字符串，而 **Godot 的 Label 不把 `\t` 当制表位**
	#      （只推进一个很小的固定宽度）⇒ 画面上两栏**粘在一起**（「血量 200 / 200状态：待命」），
	#      截图里一眼可见。现在左右各一个 Label，永远对得齐。
	#   ⚠️ 这里**必须关掉 autowrap**：换行由 hud 那边按「行」给；留着 autowrap 会在宽度不够时
	#      把一行拆成两行（版式就散了）。宽度不够宁可裁（clip_text = true），那说明文案该改短。
	#   ⚠️ hud.set_detail() 收到带 `\t` 的文本时才会分两栏；区划 / 建筑那种单栏多行文本
	#      只填左栏，右栏空着（`_body_right.visible = false`）。
	_body = _new_body_label("DetailBody", Vector2(UiLayoutRes.DETAIL_BODY_PAD, 20.0),
		Vector2(UiLayoutRes.DETAIL_BODY_COL_W, UiLayoutRes.DETAIL_BODY_H - 24.0))
	_body_right = _new_body_label("DetailBodyRight", Vector2(UiLayoutRes.DETAIL_BODY_COL2_X, 20.0),
		Vector2(UiLayoutRes.DETAIL_BODY_COL2_W, UiLayoutRes.DETAIL_BODY_H - 24.0))
	_body_right.visible = false

	# 招募队列：贴右栏**右上角**（只有正在招募时才出现；不可见时收不到鼠标事件）
	_queue = RecruitQueueRes.new()
	right.add_child(_queue)
	_queue.setup(world)
	_queue.position = Vector2(UiLayoutRes.QUEUE_X, UiLayoutRes.QUEUE_Y)
	_queue.cell_activated.connect(_on_queue_cell_activated)

	_build_notice(right)


## 造一个正文 Label（左栏 / 右栏共用同一套版式），并按矩形摆好。
func _new_body_label(node_name: String, pos: Vector2, size_v: Vector2) -> Label:
	var l := Label.new()
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	l.clip_text = true
	l.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	l.add_theme_color_override("font_color", UiStyleRes.TEXT)
	l.position = pos
	l.size = size_v
	_detail_box.add_child(l)
	return l


## 提示行（红字）：**右栏数值框下面那一条 20px**，绝对定位的浮层。
##
## ★★ 它以前是面板 VBox 的第二行 —— 一出现就让上面那两栏各少 20px，
##    而左栏那 3×3 网格是**正好铺满 220** 的（40 + 15 + 3×55），于是最下面一截
##    被裁掉（`right` 有 clip_contents，右栏的数值框也会被切掉底边）。
##    现在它住进数值框下面**本来就空着**的那条带（NOTICE_Y..NOTICE_Y+NOTICE_H），
##    出现 / 消失都不动任何一块的几何。
## ★ `clip_text = true`：文案再长也只在这条带里被裁，不会横着顶出面板
##   （最长的两句实测 405px / 360px ≤ 右栏 645，正常情况根本碰不到裁剪）。
func _build_notice(right: Control) -> void:
	_notice = Label.new()
	_notice.name = "NoticeLine"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.clip_text = true
	_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_notice.add_theme_color_override("font_color", UiStyleRes.WARN)
	_notice.position = Vector2(0.0, UiLayoutRes.NOTICE_Y)
	_notice.visible = false
	right.add_child(_notice)
	# ⚠️ size 必须在 **add_child 之后**再设：控件还没在树上时主题（= 中文字体）还没继承到，
	#    Label 的最小高度按**引擎兜底字体**算出来是 23px > 20px，于是 `set_size` 当场被夹成 23，
	#    整个提示带就顶出右栏下沿（实测：200 + 23 = 223 > 220）。进树之后再设就不会被夹。
	# ★ 宽度取 `UNIT_CONTENT_RIGHT`（= 641）：与数值框 / 招募队列共用同一条右缘。
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


## 下半网格现在是什么模式（给 hud / 测试读）："leaders" | "units" | "empty"
func grid_mode() -> String:
	if _grid == null or not _grid.visible:
		return "empty"
	return "leaders" if _grid.mode == TroopGridRes.MODE_LEADERS else "units"


## 右栏：选中单位的**名称**（空串 = 没有选中单位 → 只留「详细信息」标题）
func set_unit_name(text: String) -> void:
	if _unit_name != null:
		_unit_name.text = text


## 右栏：数值区的正文（区划 / 建筑 / 单位数值都由 hud 决定）。
##
## ★★ 文本里有 `\t` 时按**两栏**渲染：`\t` 左边进左栏 Label、右边进右栏 Label
##    （两个 Label 的 x 由 ui_layout 定死，永远对齐）。没有 `\t` 就是普通单栏多行文本。
##
## ★ 为什么按 `\t` 分而不是让 hud 直接喂两份：
##   hud 那边（`_two_columns`）本来就把正文写成「左栏 + `\t` + 右栏」的字符串，
##   而**渲染**不该由 hud 管；这一层按同一个分隔符拆开只是把它画成两栏，
##   文案的组装规则仍然只有一处（hud）。`detail_text()` 会把两栏**合回原样**，
##   所以「文案对不对」的断言照旧在同一个出口上验。
func set_detail(text: String) -> void:
	if _body == null:
		return
	var rows: PackedStringArray = text.split("\n")
	var has_columns := text.contains("\t")
	if not has_columns:
		_body.text = text
		if _body_right != null:
			_body_right.text = ""
			_body_right.visible = false
		return
	var left: PackedStringArray = []
	var right: PackedStringArray = []
	for row in rows:
		var parts: PackedStringArray = String(row).split("\t")
		left.append(parts[0])
		right.append(parts[1] if parts.size() > 1 else "")
	_body.text = "\n".join(left)
	if _body_right != null:
		_body_right.text = "\n".join(right)
		_body_right.visible = true


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


func _on_unit_activated(index: int) -> void:
	unit_activated.emit(index)


# ------------------------------------------------------------------
# 右栏那两块自绘：头像方块 / buff 格子
# ------------------------------------------------------------------

## 头像方块里写的字（没有头像素材 → 用字填充）
var _avatar_text: String = ""
## 头像那一块画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var _avatar_draws: int = 0


func _draw_unit_avatar() -> void:
	_avatar_draws += 1
	var side := UiLayoutRes.UNIT_AVATAR
	var r := Rect2(Vector2.ZERO, Vector2(side, side))
	_unit_avatar.draw_rect(r, UiStyleRes.BG_EMPTY, true)
	_unit_avatar.draw_rect(r, UiStyleRes.LINE, false, 1.0)
	var f: Font = _unit_avatar.get_theme_default_font()
	if _avatar_text != "" and f != null:
		_draw_centered(f, _avatar_text, r, UiStyleRes.TEXT, _avatar_font_size(f))


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


## 在一个矩形里居中画一行字（`draw_string` 的 pos 是**基线** ——
## 垂直居中要按 ascent 推，不能拿字号硬凑，那是「字跑偏」的老根因）。
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	if text == "":
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := r.position.y + (r.size.y + f.get_ascent(size) - f.get_descent(size)) * 0.5
	_unit_avatar.draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


func set_unit_avatar_text(text: String) -> void:
	_avatar_text = text
	if _unit_avatar != null:
		_unit_avatar.queue_redraw()


## 头像那一块画过几帧（测试读它：确认 `_draw` 真的跑过）
func avatar_draw_count() -> int:
	return _avatar_draws


func _draw_buff_box(b: Label) -> void:
	var r := Rect2(Vector2.ZERO, b.size)
	b.draw_rect(r, UiStyleRes.BG_EMPTY, true)
	b.draw_rect(r, UiStyleRes.LINE_SOFT, false, 1.0)


# ------------------------------------------------------------------
# 给测试用的小接口
# ------------------------------------------------------------------

## 右栏数值区的正文：两栏时**合回**「左栏 + \t + 右栏」的样子
## （文案对不对的断言都在这个出口上；两栏各自的内容用下面两个读口）
func detail_text() -> String:
	if _body == null:
		return ""
	if _body_right == null or not _body_right.visible:
		return _body.text
	var left: PackedStringArray = _body.text.split("\n")
	var right: PackedStringArray = _body_right.text.split("\n")
	var out: Array[String] = []
	for i in maxi(left.size(), right.size()):
		var l: String = String(left[i]) if i < left.size() else ""
		var r: String = String(right[i]) if i < right.size() else ""
		out.append("%s\t%s" % [l, r] if r != "" else l)
	return "\n".join(out)


## 正文**左栏**的实际文本（测试用它按真实字体量宽度）
func detail_left_text() -> String:
	return _body.text if _body != null else ""


## 正文**右栏**的实际文本（没有两栏文本时是空串）
func detail_right_text() -> String:
	if _body_right == null or not _body_right.visible:
		return ""
	return _body_right.text


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
