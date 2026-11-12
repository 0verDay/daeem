## tech_grid.gd —— 右下「科技」页里的 3×3 九格（**盖在命令卡上**）
##
## ★★ 需求原话：
##   「当前占位用科技有 9 个，铺满右下角科技页签的 3x3 格子」；
##   「玩家同一时间仅可启用三个占位科技，玩家需要通过拖牌或快捷键启用科技，
##     当玩家启用的科技数到 3 时，玩家再启用科技会被阻止并提示，
##     玩家可以拖出已启用的科技以弃用科技」。
##
## 分工（与 command_card.gd 同一条边界）：
##   · 本控件只做三件事：摆九格、按权威状态画「已启用 / 没启用」、把拖牌/快捷键抛出去；
##   · 「最多 3 个」这条规则**不在这里**（在 logic/tech.gd + world.set_tech_active）；
##   · 「点一下到底是启用还是弃用」由 hud 按**权威状态**取反决定（`_on_card_entry`）。
##
## ★ 为什么单独一个控件、而不是把科技塞进 command_card 的九格里：
##   命令卡那九格是「页签的另一套内容」（操作 / 单位 / 建筑 / 招募），它只认 `entries`；
##   科技格需要**自己的三态样式**（已启用 / 未启用 / 悬停）与悬停详情。
##   塞进去会让命令卡同时认识三种数据形状。这里复用**它的几何**（card_cell_local），
##   于是两套内容在屏幕上完全重合 —— 换页时看不出是换了控件。
##
## ★★ 格子排版（2026.11）与命令卡统一：「**图标 + 一行名字**」。
##   · 图标 = `tech_<id>.png` 金线蒙版（按名字画的占位图形，见
##     tools/bake_unit_card_icon.py 的 TECH_SHAPES），**铺满整格**；
##   · 名字叠在最下面那条**略黑底条**上（金色填充扫上来时底条淡出）；
##   · **效果 / 造价 / 拒因**全部进悬停面板（`hud._hover_detail`）。
##   · 旧那版在格子里挤两行字（名字 + 效果）已经作废。
##   图标路径由 hud 塞在条目里（`icon_mask`）—— 本控件不认识「科技 id → 图片」这件事。
##
## ★ 上拖松手 / 快捷键走 `cell_activated(id)` → hud → input_controller 发 `tech_toggle` 命令，
##   本控件**从不改逻辑状态**（架构铁律：view 只读 + 发命令）。
extends Control

## 某一格被拖起并松手 / 快捷键激活：带上那一条科技的 id
signal cell_activated(id: String)
signal cell_drag_started(id: String, screen_pos: Vector2)
signal cell_drag_moved(id: String, screen_pos: Vector2)
signal cell_drag_finished(id: String, screen_pos: Vector2, index: int)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）：带上格子序号。
##   hud 收到后弹「悬停详情面板」（与命令卡共用同一块，见 view/hover_tip.gd）——
##   两个控件的九格在屏幕上**逐像素重合**，所以悬停这件事也必须走同一块面板。
##   ★ 与命令卡同一条约定：只报序号，内容由 hud 按当前 entries 现取。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
## ★★ 悬停「四边泛光」+「已启用 = 金色填充满格（切换时播动画）」的那套动效
##   （见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 格子里那两行小字的字号（80×80 的格子：名字一行 + 效果一行）
const FS_NAME := 13
const FS_LINE := 11
## 名字那条底条的高度（与命令卡 `NAME_BAR_H` 同口径：名字就压在这条上）
const NAME_BAR_H := 20.0
## 图标层（画烘好的金线蒙版，与单位 / 建筑页同一套）
const UnitCardIconRes = preload("res://view/unit_card_icon.gd")

var _cells: Array[Button] = []
var _name_labels: Array[Label] = []
var _line_labels: Array[Label] = []
## 每格的图标层（画烘好的金线蒙版；见 `unit_card_icon.IconView`）
var _icon_views: Array = []
## 每格的**名字底条**（略黑半透明横条，名字压在它上面；空格子 / 没图标时隐藏）
var _name_bars: Array[ColorRect] = []
## ★★ 每格左上角的键位字母（与命令卡同一套 QWE / ASD / ZXC）。
var _key_labels: Array[Label] = []
## 上一次喂进来的条目（测试与调试读它；也是拖牌 / 快捷键回调的 id 来源）
var _entries: Array = []
## ★★ 2026.11.5：这一格**第一次拿到内容**时同步的「已启用」直接满格（不播动画）；
##   之后玩家点启用 / 弃用才播填充 / 退回。
var _primer_done: bool = false
var _deck_tween: Tween = null
var _drag_tween: Tween = null
var _drag_index: int = -1
var _drag_start_pos := Vector2.ZERO
var _dragging: bool = false

## ★★ 手机端：按住某一格期间由 hud 置 true —— 忽略「按下」带来的模拟 mouse_entered，
##    悬停详情只在长按够久之后由 hud 调 `hover()` 弹出（与 view/command_card.gd 同一条）。
var touch_suppress_hover: bool = false


func setup() -> void:
	name = "TechGrid"
	# ★ 科技页才显示；其余页签整块藏起来（见 `set_visible_page`）。
	#   ⚠️ 隐藏时**必须**是 IGNORE：Godot 里隐藏的 Control 不吃事件，
	#      但万一哪天改成「半透明可见」，STOP 会把下面命令卡的点击全吞掉。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiLayoutRes.apply_rect(self, UiLayoutRes.CARD_RECT, true, true)

	for i in UiLayoutRes.CARD_SLOTS:
		var cell := Button.new()
		cell.name = "TechCell%d" % (i + 1)
		cell.focus_mode = Control.FOCUS_NONE
		cell.clip_text = true
		cell.clip_contents = true
		cell.visible = false
		_style_cell(cell, false, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		cell.gui_input.connect(_on_cell_gui_input.bind(i))
		# ★ 悬停信号（与命令卡同一套，见文件头那个信号块）。
		#   ⚠️ 空格子（`disabled = true`）也照样发 mouse_entered —— hud 那一侧取不到
		#      entry，自然什么都不弹（`entry_at` 越界返回 {}）。
		cell.mouse_entered.connect(_on_cell_mouse_entered.bind(i))
		cell.mouse_exited.connect(_on_cell_mouse_exited.bind(i))
		# ★★ 悬停泛光 + 启用填充（一行挂上，见 view/fill_button.gd）
		FillButtonRes.attach_text(cell)
		# ★★ 科技格有自己的点击反馈（启用 = 填满、弃用 = 退回）——
		#   关掉「点击闪光」，否则两边会抢同一份 `_fill`。
		FillButtonRes.set_click_flash(cell, false)
		# ★★ 常驻灰底：底纹（`tech_fill*`）是全透明的，灰底画在填充层里、
		#   金的下层 —— 悬停 / 启用时灰底不消失，金只是盖上去。
		FillButtonRes.set_base_bg(cell, UiStyleRes.bg_empty())
		# ★ 与命令卡同一口径：字色走「跟着金色前沿由白变黑」那条统一规则
		#   （`set_prefer_light` 是历史遗留的作废开关，见 fill_button 里的说明）。
		FillButtonRes.set_prefer_light(cell, true)
		add_child(cell)

		# ★★ 图标：和单位 / 建筑页同一套（`unit_card_icon.IconView` 画烘好的金线蒙版）。
		#    **铺满整格**、不考虑文字位置；名字叠在最下面那条底条上（与命令卡同口径）。
		var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
		var icon_view := UnitCardIconRes.IconView.new()
		icon_view.name = "TechIcon%d" % (i + 1)
		cell.add_child(icon_view)
		icon_view.bind(cell)

		# ★ 名字底条（略黑半透明横条）：压在图标上，保证名字读得清。
		var name_bar := ColorRect.new()
		name_bar.name = "TechNameBar%d" % (i + 1)
		name_bar.color = UiStyleRes.name_bar()
		name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_bar.position = Vector2(0.0, cell_size.y - NAME_BAR_H)
		name_bar.size = Vector2(cell_size.x, NAME_BAR_H)
		name_bar.visible = false
		cell.add_child(name_bar)

		# 第一行：科技名（压在最下面那条底条上，字号小一档）
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.add_theme_font_size_override("font_size", FS_LINE)
		name_label.size = Vector2(cell_size.x - 2.0, NAME_BAR_H)
		name_label.position = Vector2(1.0, cell_size.y - NAME_BAR_H)
		cell.add_child(name_label)

		# 第二行：效果小字 —— **不再显示**（描述进悬停面板）。控件保留：
		#   填充层的文字登记按对象走，删掉的话 `on_fill_text` 那张表要另记一份。
		var line_label := Label.new()
		line_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line_label.add_theme_font_size_override("font_size", FS_LINE)
		line_label.size = Vector2(cell_size.x, cell_size.y * 0.34)
		line_label.position = Vector2(0.0, cell_size.y * 0.58)
		line_label.visible = false
		cell.add_child(line_label)

		# ★★ 键位字母（与命令卡 / 页签同一套）：画在左上角。
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		# ★ 三条子 Label 登记到填充上：填满时它们会一起被压成暖黑（否则暖白压金读不出来）
		FillButtonRes.on_fill_text(cell, name_label, UiStyleRes.text())
		FillButtonRes.on_fill_text(cell, line_label, UiStyleRes.text_dim())
		FillButtonRes.on_fill_text(cell, key_label, UiStyleRes.text_faint())

		_cells.append(cell)
		_name_labels.append(name_label)
		_line_labels.append(line_label)
		_key_labels.append(key_label)
		_name_bars.append(name_bar)
		_icon_views.append(icon_view)

	set_entries([])


# ------------------------------------------------------------------
# 每帧喂内容（由 hud 按权威状态算好）
# ------------------------------------------------------------------

## 换一份内容。每条 = {id, name, line, desc, active}
##   · 最多 9 条（顺序 = 左上 → 右下）；
##   · 缺的格子画成空（置灰、点了不做事）；
##   · `active` 决定这一格画「已启用」的那套样式（实心金 + 亮描边）。
##
## ★ 每帧都会被调（hud.refresh 里）——所以这里只在**内容真的变了**时才写控件，
##   否则每帧 add_theme_*_override 会白白重建 StyleBox（与 page_tabs 同一条讲究）。
func set_entries(list: Array) -> void:
	var clean: Array = []
	for item in list:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		if clean.size() >= UiLayoutRes.CARD_SLOTS:
			break
		clean.append(item)
	if _same_entries(clean):
		return
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	for cell in _cells:
		cell.modulate.a = 1.0
	_entries = clean
	_apply()


func _same_entries(clean: Array) -> bool:
	if clean.size() != _entries.size():
		return false
	for i in clean.size():
		var a: Dictionary = clean[i]
		var b: Dictionary = _entries[i]
		if String(a.get("id", "")) != String(b.get("id", "")):
			return false
		if String(a.get("name", "")) != String(b.get("name", "")):
			return false
		if String(a.get("line", "")) != String(b.get("line", "")):
			return false
		if String(a.get("desc", "")) != String(b.get("desc", "")):
			return false
		if bool(a.get("active", false)) != bool(b.get("active", false)):
			return false
		if bool(a.get("available", true)) != bool(b.get("available", true)):
			return false
		if String(a.get("reason", "")) != String(b.get("reason", "")):
			return false
	return true


## ★★ 九格是**列优先**摆的：config 列表第 e 条 → 单元格 (e % 3) * 3 + int(e / 3)。
##   于是第一列 = 粮食 I/II/III、第二列 = 黄金 I/II/III、第三列 = 建筑 / 将领 / 区划人口。
## ★ 科技「阶」= **显示出来的行**：第一行一阶、第二行二阶、第三行三阶
##   （config 里的 tier 字段按 `index % 3` 写；九格转置不改变行号）。
##   `_entry_index_for_cell()` 是它的逆变换（3×3 转置是自逆的）。
func _entry_index_for_cell(cell: int) -> int:
	return (cell % UiLayoutRes.CARD_COLS) * UiLayoutRes.CARD_ROWS \
		+ int(cell / UiLayoutRes.CARD_COLS)


## 第 i 格的图标层换图（空串 = 没图、只剩名字）。
## `locked` = 这一格现在不能启用（阶数不够 / 名额满）⇒ 图标画暗一档，与命令卡同口径。
func _set_icon(i: int, path: String, locked: bool) -> void:
	if i < 0 or i >= _icon_views.size():
		return
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return
	v.set_mask(path)
	v.set_ready(not locked)


## 第 i 格现在画的是哪张图标蒙版（空串 = 没图）。测试用。
func cell_icon_path(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return ""
	return String(v.mask_path())


## 第 i 格的名字底条显示 / 隐藏（有科技的格子才垫这条）。
func _set_bar(i: int, on: bool) -> void:
	if i < 0 or i >= _name_bars.size():
		return
	var b := _name_bars[i]
	if b != null and is_instance_valid(b):
		b.visible = on


## ★ 底条跟着金色填充淡出（理由同命令卡：填充从下往上，底条在最下面，
##   金色盖上来之后字会翻成压金暗色，深底 + 深字就读不出来了）。每帧 9 格，开销可忽略。
func _process(_dt: float) -> void:
	if not is_visible_in_tree():
		return
	for i in _name_bars.size():
		var bar: ColorRect = _name_bars[i]
		if bar == null or not is_instance_valid(bar) or not bar.visible:
			continue
		if i >= _cells.size():
			continue
		var p: float = clampf(FillButtonRes.fill_progress(_cells[i]), 0.0, 1.0)
		var c := UiStyleRes.name_bar()
		bar.color = Color(c.r, c.g, c.b, c.a * (1.0 - p))


func _apply() -> void:
	# ★★ 第一次拿到内容（含「全是未启用」）时，已启用的格子**直接满格**；
	#   不可见时（科技页没开）也直接到位 —— 没人看着的时候不该「攒」一段动画，
	#   否则下次打开科技页会先看到一格从空填上来。
	#   之后玩家点启用 / 弃用才播填充 / 退回（见 view/fill_button.gd）。
	var instant: bool = not _primer_done or not is_visible_in_tree()
	for i in _cells.size():
		var cell := _cells[i]
		var ei := _entry_index_for_cell(i)
		# ★★ 2026.11：**空槽位**（派系科技不满 9 条时那张表里的占位，`id == ""`）与
		#   「根本没有条目」走同一条路：不显示名字、不可点、不参与填充动效
		#   （用户口径：空位画灰框不可点）。
		var filled: bool = ei >= 0 and ei < _entries.size() \
			and String((_entries[ei] as Dictionary).get("id", "")) != ""
		var active := false
		var locked := false
		if filled:
			var e: Dictionary = _entries[ei]
			active = bool(e.get("active", false))
			# ★ 不能启用（阶数不够 / 名额已满 / 黄金净收入赤字）⇒ 置灰不可点；
			#   已启用的照旧可点（= 弃用）。
			locked = not active and not bool(e.get("available", true))
			_name_labels[i].text = String(e.get("name", ""))
			_line_labels[i].text = String(e.get("line", ""))
			# ★★ 图标：蒙版路径由 hud 塞在条目里（`tech_<id>.png`，缺图时为空串，
			#   这一格就只剩名字 —— 不会画错、也不会崩）。
			_set_icon(i, String(e.get("icon_mask", "")), locked)
			_set_bar(i, true)
			cell.disabled = false             # 保持可悬停（悬停要能解释原因）
			# ★★ 走「登记原色」的接口，而不是直接写 font_color override：
			#   填充动效每帧都按「原色 + 当前填充进度」重算（见 fill_button._sync_text）。
			#   ★★ 2026.11.5：已启用的格子**也登记亮色**（不再用近黑的 text_on_accent）——
			#     选中要播填充动画，若一上来就把字设成近黑，动画头 0.1 秒里
			#     「黑字压黑底」读不出来。亮色会在金扫到它时由翻面自动变黑。
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text())
			FillButtonRes.on_fill_text(cell, _line_labels[i],
				Color(1.0, 1.0, 1.0, 0.85) if active else UiStyleRes.text_dim())
			FillButtonRes.on_fill_text(cell, _key_labels[i],
				UiStyleRes.text_faint() if locked else UiStyleRes.text())
			# ★★ 已启用 = 金色填充满格（切换时播动画；建出来那一下直接满格）
			FillButtonRes.set_latched(cell, active, instant)
			# ★★ 这一格「有科技」⇒ 参与悬停泛光。
			#   不能启用的格子**也参与**，只是把泛光换成灰色（用户口径：
			#   「灰色代替金色 + 点击后无效果」，不是实心灰按钮）。
			FillButtonRes.set_available(cell, true)
			FillButtonRes.set_grey(cell, locked)
		else:
			_name_labels[i].text = ""
			_line_labels[i].text = ""
			_set_icon(i, "", false)
			_set_bar(i, false)
			cell.disabled = true              # 空格子点了不做事（也不吃键盘）
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _line_labels[i], UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			FillButtonRes.set_latched(cell, false)
			FillButtonRes.set_grey(cell, false)
			# ★ 空格子**不参与任何动效**：它连「科技」都没有，亮起来会让人以为这一格能点。
			FillButtonRes.set_available(cell, false)
		_style_cell(cell, filled, active, locked)
		cell.visible = filled
	_layout_fan()
	if not _entries.is_empty():
		_primer_done = true


## 科技页沿用同一扇形牌区；空配置槽隐藏，locked 仍是实际科技项，保留灰化状态。
func _layout_fan() -> void:
	var visible_cells: Array[int] = []
	for i in _cells.size():
		var ei := _entry_index_for_cell(i)
		if ei >= 0 and ei < _entries.size() \
				and String((_entries[ei] as Dictionary).get("id", "")) != "":
			visible_cells.append(i)
	var count := visible_cells.size()
	for ordinal in count:
		var i := visible_cells[ordinal]
		var cell := _cells[i]
		var r := UiLayoutRes.card_fan_local(ordinal, count)
		cell.position = r.position
		cell.size = r.size
		cell.rotation = UiLayoutRes.card_fan_rotation(ordinal, count)
		cell.z_index = ordinal
		_key_labels[i].position = Vector2(8.0, 6.0)
		_name_bars[i].position = Vector2(0.0, r.size.y - NAME_BAR_H)
		_name_bars[i].size = Vector2(r.size.x, NAME_BAR_H)
		_name_labels[i].position = Vector2(1.0, r.size.y - NAME_BAR_H)
		_name_labels[i].size = Vector2(r.size.x - 2.0, NAME_BAR_H)
		_line_labels[i].size = Vector2(r.size.x, r.size.y * 0.34)
		_line_labels[i].position = Vector2(0.0, r.size.y * 0.58)


## 三个状态各自一套样式。
##
## ★★ 本版把「未启用」与「已启用」的底色**交给填充层**（`tech_fill()` / `tech_latched()`：
##    底透明、只留描边）—— 旧那版是不透明实底（`tech_normal()` / `tech_active()`），
##    它会把画在底纹**下面**的填充金整个盖住，于是「选中的金色填充」根本看不见。
##   ⇒ 现在：未启用 = 空框；悬停 = 四边泛光；已启用 = 金色填充满格（切换时播动画）。
##   ⚠️ 空格子（`filled = false`）仍用 `tech_disabled()` 的实底 —— 它不是按钮，
##      它是「这里没有科技」的一块底板，本来就该是死的。
func _style_cell(cell: Button, filled: bool, active: bool, locked: bool = false) -> void:
	if not filled:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_disabled())
	elif locked:
		# ★★ 不可启用 = **与普通格同一套透明底纹**，靠填充层画**灰色**填充；
		#   不铺实底（否则灰填充会被压在底纹下面，又变成一坨灰按钮）。
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_fill())
	elif active:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_latched())
	else:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_fill())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_fill_hover())
		# ★ 按下统一成 2px 亮边（与菜单 / 命令卡同一档）；松手后再切到启用态
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_latched())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_fill())
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_cell_pressed(i: int) -> void:
	# 鼠标点按不打出科技牌；鼠标牌统一向上拖起并松手，键盘走 handle_key。
	return


func _activate_cell(i: int) -> void:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return
	var e: Dictionary = _entries[ei]
	if not bool(e.get("active", false)) and not bool(e.get("available", true)):
		return                            # 置灰格：点了什么都不发生
	cell_activated.emit(String(e.get("id", "")))


func _on_cell_gui_input(event: InputEvent, i: int) -> void:
	if OS.has_feature("mobile") or touch_suppress_hover:
		return # 触屏由 HUD 的长按 / 拖牌识别统一路由。
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_drag_index = i
			_drag_start_pos = get_viewport().get_mouse_position()
			_dragging = false
		elif _drag_index == i:
			_finish_touch_drag(i, get_viewport().get_mouse_position())
		return
	if event is InputEventMouseMotion and _drag_index == i:
		var mm := event as InputEventMouseMotion
		if (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) == 0:
			return
		_update_drag(i, get_viewport().get_mouse_position())
		if _dragging:
			accept_event()


func _update_drag(i: int, viewport_pos: Vector2) -> bool:
	if i < 0 or i >= _cells.size():
		return false
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return false
	var entry: Dictionary = _entries[ei]
	if not bool(entry.get("active", false)) and not bool(entry.get("available", true)):
		return false
	if not _dragging and viewport_pos.y - _drag_start_pos.y <= -10.0:
		_dragging = true
		if _deck_tween != null and _deck_tween.is_running():
			_deck_tween.kill()
		if _drag_tween != null and _drag_tween.is_running():
			_drag_tween.kill()
		_cells[i].z_index = UiLayoutRes.CARD_SLOTS + 4
		cell_drag_started.emit(String(entry.get("id", "")), viewport_pos)
	if not _dragging:
		return false
	var local: Vector2 = get_global_transform_with_canvas().affine_inverse() * viewport_pos
	_cells[i].rotation = 0.0
	_cells[i].position = local - _cells[i].size * 0.5
	cell_drag_moved.emit(String(entry.get("id", "")), viewport_pos)
	return true


func _finish_touch_drag(i: int, viewport_pos: Vector2) -> void:
	if i >= 0 and i < _cells.size() and _dragging:
		cell_drag_finished.emit(entry_id_at(i), viewport_pos, i)
		_animate_card_back(i)
	_dragging = false
	_drag_index = -1


func begin_touch_drag(i: int, viewport_pos: Vector2) -> void:
	_drag_index = i
	_drag_start_pos = viewport_pos
	_dragging = false


func move_touch_drag(i: int, viewport_pos: Vector2) -> bool:
	if i != _drag_index:
		return false
	return _update_drag(i, viewport_pos)


func finish_touch_drag(i: int) -> void:
	var pos: Vector2 = get_viewport().get_mouse_position() if get_viewport() != null else Vector2.ZERO
	_finish_touch_drag(i, pos)


func entry_id_at(i: int) -> String:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return ""
	return String((_entries[ei] as Dictionary).get("id", ""))


func _animate_card_back(i: int) -> void:
	if i < 0 or i >= _cells.size():
		return
	var visible_cells: Array[int] = []
	for ci in _cells.size():
		if _cells[ci].visible:
			visible_cells.append(ci)
	var ordinal := visible_cells.find(i)
	if ordinal < 0:
		return
	var target := UiLayoutRes.card_fan_local(ordinal, visible_cells.size())
	var rot := UiLayoutRes.card_fan_rotation(ordinal, visible_cells.size())
	if _drag_tween != null and _drag_tween.is_running():
		_drag_tween.kill()
	_drag_tween = create_tween().set_parallel(true)
	_drag_tween.tween_property(_cells[i], "position", target.position, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_drag_tween.tween_property(_cells[i], "rotation", rot, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_cells[i].z_index = ordinal


## ★★ 键盘：科技页的九格快捷键（Q/W/E/A/S/D/Z/X/C）。
##
## ★ 与上拖松手**完全同一条路**：键位映射到视觉格 → `_activate_cell()` →
##   `cell_activated` → hud → `tech_toggle` 命令。这里不自己改任何逻辑状态。
## ★ 空格 / 置灰格**不吃按键**（与 `command_card.handle_key()` 同一条约定），
##   让这几个字母继续走别的绑定。
## ★ 带 Ctrl / Alt / Meta 的组合键一律放行（Ctrl+Q 全屏等）。
func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	var slot: int = int(UiLayoutRes.CARD_KEY_TO_SLOT.get(event.keycode, -1))
	if slot < 0 or slot >= _cells.size():
		return false
	var ei := _entry_index_for_cell(slot)
	if ei < 0 or ei >= _entries.size():
		return false
	var e: Dictionary = _entries[ei]
	if not bool(e.get("active", false)) and not bool(e.get("available", true)):
		return false
	_activate_cell(slot)
	return true


## 鼠标进入 / 离开第 i 格 —— 只转发序号（内容由 hud 现取，与命令卡同一条约定）
func _on_cell_mouse_entered(i: int) -> void:
	if _dragging:
		return
	if touch_suppress_hover:
		return                       # 手机端按住期间不弹（长按到点后由 hud 调 hover()）
	_raise_card(i, true)
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	if _dragging:
		return
	_raise_card(i, false)
	cell_unhovered.emit(i)


func _raise_card(i: int, raised: bool) -> void:
	if i < 0 or i >= _cells.size() or not _cells[i].visible:
		return
	var visible_cells: Array[int] = []
	for ci in _cells.size():
		var ei := _entry_index_for_cell(ci)
		if ei >= 0 and ei < _entries.size() \
				and String((_entries[ei] as Dictionary).get("id", "")) != "":
			visible_cells.append(ci)
	var ordinal := visible_cells.find(i)
	if ordinal < 0:
		return
	var r := UiLayoutRes.card_fan_local(ordinal, visible_cells.size())
	if raised:
		_cells[i].rotation = 0.0
		_cells[i].position.y = r.position.y - 20.0
		_cells[i].z_index = UiLayoutRes.CARD_SLOTS + 2
	else:
		_cells[i].rotation = UiLayoutRes.card_fan_rotation(ordinal, visible_cells.size())
		_cells[i].position.y = r.position.y
		_cells[i].z_index = ordinal


## 模拟悬停第 i 格 / 离开它（测试用；与 `press()` 一样走引擎同一条信号）。
## ★★ 手机端的长按也走这里 —— 所以它**绕开** `touch_suppress_hover` 直接发信号。
func hover(i: int) -> void:
	cell_hovered.emit(i)


func unhover(i: int) -> void:
	cell_unhovered.emit(i)


# ------------------------------------------------------------------
# 显隐：只有「科技」页才盖在命令卡上
# ------------------------------------------------------------------

## hud 每帧按当前页调它。★ 换页时**什么都不改**（内容照旧留着，只是不画）——
## 重新可见时不需要重建控件，也就不存在「切回来慢一帧」。
func set_visible_page(on: bool) -> void:
	visible = on
	mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE
	# ⚠️ 挡住鼠标的**只在显示时**：隐藏时若还是 STOP，底栏那一片会变成点击黑洞
	#    （鼠标滚轮缩放的判据只看底栏几何、不看控件，所以这条只影响点击）。
	for c in _cells:
		c.mouse_filter = Control.MOUSE_FILTER_STOP if on else Control.MOUSE_FILTER_IGNORE


## 翻到科技页时，实际科技牌从牌手下缘错落升起；空配置槽不参与动效。
func animate_deck_in() -> void:
	if _deck_tween != null and _deck_tween.is_running():
		_deck_tween.kill()
	var visible_cells: Array[int] = []
	for i in _cells.size():
		if _cells[i].visible:
			visible_cells.append(i)
	var count := visible_cells.size()
	if count == 0 or not visible:
		return
	for ordinal in count:
		var i := visible_cells[ordinal]
		_cells[i].modulate.a = 1.0
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		_cells[i].modulate.a = 0.0
		_cells[i].position = target.position + Vector2(0.0, 40.0)
		_cells[i].rotation = rot * 1.5
		_cells[i].z_index = ordinal
	_deck_tween = create_tween().set_parallel(true)
	for ordinal in count:
		var i := visible_cells[ordinal]
		var target := UiLayoutRes.card_fan_local(ordinal, count)
		var rot := UiLayoutRes.card_fan_rotation(ordinal, count)
		var delay := float(ordinal) * 0.025
		_deck_tween.tween_property(_cells[i], "position", target.position, 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "rotation", rot, 0.22) \
			.set_delay(delay).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_deck_tween.tween_property(_cells[i], "modulate:a", 1.0, 0.16).set_delay(delay)


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


## 第 i **格**显示的条目（注意：格 ≠ config 下标 —— 九格是列优先转置过的）
## ★ 空槽位返回 {}（与「没有这一格」同形）：hud 的悬停 / 点击都自带「空字典什么都不做」。
func entry_at(i: int) -> Dictionary:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return {}
	var e: Dictionary = _entries[ei]
	if String(e.get("id", "")) == "":
		return {}
	return e


func cell_at(i: int) -> Button:
	if i < 0 or i >= _cells.size():
		return null
	return _cells[i]


## 第 i 格显示的名字（空格子为空串）
func cell_name(i: int) -> String:
	if i < 0 or i >= _name_labels.size():
		return ""
	return _name_labels[i].text


## 第 i 格的第二行小字
func cell_line(i: int) -> String:
	if i < 0 or i >= _line_labels.size():
		return ""
	return _line_labels[i].text


## 第 i 格左上角显示的键位字母
func cell_key(i: int) -> String:
	if i < 0 or i >= _key_labels.size():
		return ""
	return _key_labels[i].text


## 第 i 格是不是画成「已启用」（实心强调色）。空格子恒为 false。
func cell_active(i: int) -> bool:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return false
	return bool((_entries[ei] as Dictionary).get("active", false))


## 测试辅助：直接触发有效科技牌（真实鼠标操作需上拖松手）。
func press(i: int) -> void:
	_activate_cell(i)
