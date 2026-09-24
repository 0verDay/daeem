## tech_grid.gd —— 右下「科技」页里的 3×3 九格（**盖在命令卡上**）
##
## ★★ 需求原话：
##   「当前占位用科技有 9 个，铺满右下角科技页签的 3x3 格子」；
##   「玩家同一时间仅可启用三个占位科技，玩家需要通过点击科技以启用科技，
##     当玩家启用的科技数到 3 时，玩家再启用科技会被阻止并提示，
##     玩家可以点击已启用的科技以弃用科技」。
##
## 分工（与 command_card.gd 同一条边界）：
##   · 本控件只做三件事：摆九格、按权威状态画「已启用 / 没启用」、把点击抛出去；
##   · 「最多 3 个」这条规则**不在这里**（在 logic/tech.gd + world.set_tech_active）；
##   · 「点一下到底是启用还是弃用」由 hud 按**权威状态**取反决定（`_on_card_entry`）。
##
## ★ 为什么单独一个控件、而不是把科技塞进 command_card 的九格里：
##   命令卡那九格是「页签的另一套内容」（操作 / 单位 / 建筑 / 招募），它只认 `entries`；
##   科技格需要**自己的三态样式**（已启用 / 未启用 / 悬停）、两行文字与 tooltip。
##   塞进去会让命令卡同时认识三种数据形状。这里复用**它的几何**（card_cell_local），
##   于是两套内容在屏幕上完全重合 —— 换页时看不出是换了控件。
##
## ★ 点击走 `cell_activated(id)` → hud → input_controller 发 `tech_toggle` 命令，
##   本控件**从不改逻辑状态**（架构铁律：view 只读 + 发命令）。
extends Control

## 某一格被点：带上那一条科技的 id
signal cell_activated(id: String)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 格子里那两行小字的字号（80×80 的格子：名字一行 + 效果一行）
const FS_NAME := 13
const FS_LINE := 11

var _cells: Array[Button] = []
var _name_labels: Array[Label] = []
var _line_labels: Array[Label] = []
## 上一次喂进来的条目（测试与调试读它；也是点击回调的 id 来源）
var _entries: Array = []


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
		_style_cell(cell, false, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		add_child(cell)

		# 第一行：科技名（居中偏上，给第二行留出位置）
		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.add_theme_font_size_override("font_size", FS_NAME)
		var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
		name_label.size = Vector2(cell_size.x, cell_size.y * 0.56)
		name_label.position = Vector2(0.0, cell_size.y * 0.12)
		cell.add_child(name_label)

		# 第二行：效果小字（「粮食 +1」「建筑血量 +10%」）
		var line_label := Label.new()
		line_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		line_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		line_label.add_theme_font_size_override("font_size", FS_LINE)
		line_label.size = Vector2(cell_size.x, cell_size.y * 0.34)
		line_label.position = Vector2(0.0, cell_size.y * 0.58)
		cell.add_child(line_label)

		_cells.append(cell)
		_name_labels.append(name_label)
		_line_labels.append(line_label)

	set_entries([])


# ------------------------------------------------------------------
# 每帧喂内容（由 hud 按权威状态算好）
# ------------------------------------------------------------------

## 换一份内容。每条 = {id, name, line, desc, active}
##   · 最多 9 条（顺序 = 左上 → 右下）；
##   · 缺的格子画成空（置灰、点了不做事）；
##   · `active` 决定这一格画「已启用」的那套样式（实心蓝 + 亮描边）。
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
	return true


func _apply() -> void:
	for i in _cells.size():
		var cell := _cells[i]
		var filled: bool = i < _entries.size()
		var active := false
		if filled:
			var e: Dictionary = _entries[i]
			active = bool(e.get("active", false))
			_name_labels[i].text = String(e.get("name", ""))
			_line_labels[i].text = String(e.get("line", ""))
			cell.tooltip_text = String(e.get("desc", ""))
			cell.disabled = false
			_name_labels[i].add_theme_color_override(
				"font_color", UiStyleRes.TEXT_ON_ACCENT if active else UiStyleRes.TEXT)
			_line_labels[i].add_theme_color_override(
				"font_color",
				Color(1.0, 1.0, 1.0, 0.85) if active else UiStyleRes.TEXT_DIM)
		else:
			_name_labels[i].text = ""
			_line_labels[i].text = ""
			cell.tooltip_text = ""
			cell.disabled = true              # 空格子点了不做事（也不吃键盘）
			_name_labels[i].add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
			_line_labels[i].add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
		_style_cell(cell, filled, active)


## 三个状态各自一套样式（**不透明底**，见 ui_style.gd 那一节的说明）
func _style_cell(cell: Button, filled: bool, active: bool) -> void:
	if not filled:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_disabled())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_disabled())
	elif active:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_active())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_active_hover())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_active_hover())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_active())
	else:
		cell.add_theme_stylebox_override("normal", UiStyleRes.tech_normal())
		cell.add_theme_stylebox_override("hover", UiStyleRes.tech_hover())
		cell.add_theme_stylebox_override("pressed", UiStyleRes.tech_hover())
		cell.add_theme_stylebox_override("disabled", UiStyleRes.tech_normal())
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_cell_pressed(i: int) -> void:
	if i < 0 or i >= _entries.size():
		return
	cell_activated.emit(String((_entries[i] as Dictionary).get("id", "")))


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


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


func entry_at(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	return _entries[i]


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


## 第 i 格是不是画成「已启用」（实心强调色）。空格子恒为 false。
func cell_active(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	return bool((_entries[i] as Dictionary).get("active", false))


## 模拟点第 i 格（测试用；等价于玩家点那一下）
func press(i: int) -> void:
	_on_cell_pressed(i)
