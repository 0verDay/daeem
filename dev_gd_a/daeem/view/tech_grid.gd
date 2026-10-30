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
##   科技格需要**自己的三态样式**（已启用 / 未启用 / 悬停）、两行文字与悬停详情。
##   塞进去会让命令卡同时认识三种数据形状。这里复用**它的几何**（card_cell_local），
##   于是两套内容在屏幕上完全重合 —— 换页时看不出是换了控件。
##
## ★ 点击走 `cell_activated(id)` → hud → input_controller 发 `tech_toggle` 命令，
##   本控件**从不改逻辑状态**（架构铁律：view 只读 + 发命令）。
extends Control

## 某一格被点：带上那一条科技的 id
signal cell_activated(id: String)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）：带上格子序号。
##   hud 收到后弹「悬停详情面板」（与命令卡共用同一块，见 view/hover_tip.gd）——
##   两个控件的九格在屏幕上**逐像素重合**，所以悬停这件事也必须走同一块面板。
##   ★ 与命令卡同一条约定：只报序号，内容由 hud 按当前 entries 现取。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
## ★★ 悬停时「金色自下而上填进来」+「启用后常驻满格并增亮」的那套动效
##   （见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 格子里那两行小字的字号（80×80 的格子：名字一行 + 效果一行）
const FS_NAME := 13
const FS_LINE := 11

var _cells: Array[Button] = []
var _name_labels: Array[Label] = []
var _line_labels: Array[Label] = []
## ★★ 每格左上角的键位字母（与命令卡同一套 QWE / ASD / ZXC）。
var _key_labels: Array[Label] = []
## 上一次喂进来的条目（测试与调试读它；也是点击回调的 id 来源）
var _entries: Array = []

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
		_style_cell(cell, false, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		# ★ 悬停信号（与命令卡同一套，见文件头那个信号块）。
		#   ⚠️ 空格子（`disabled = true`）也照样发 mouse_entered —— hud 那一侧取不到
		#      entry，自然什么都不弹（`entry_at` 越界返回 {}）。
		cell.mouse_entered.connect(_on_cell_mouse_entered.bind(i))
		cell.mouse_exited.connect(_on_cell_mouse_exited.bind(i))
		# ★★ 悬停填充 + 启用常驻（一行挂上，见 view/fill_button.gd）
		FillButtonRes.attach_text(cell)
		# ★★ 常驻灰底：底纹（`tech_fill*`）是全透明的，灰底画在填充层里、
		#   金的下层 —— 悬停 / 启用时灰底不消失，金只是盖上去。
		FillButtonRes.set_base_bg(cell, UiStyleRes.bg_empty())
		# ★ 与命令卡同一口径：字色走「跟着金色前沿由白变黑」那条统一规则
		#   （`set_prefer_light` 是历史遗留的作废开关，见 fill_button 里的说明）。
		FillButtonRes.set_prefer_light(cell, true)
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


func _apply() -> void:
	for i in _cells.size():
		var cell := _cells[i]
		var ei := _entry_index_for_cell(i)
		var filled: bool = ei >= 0 and ei < _entries.size()
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
			cell.disabled = false             # 保持可悬停（悬停要能解释原因）
			# ★★ 走「登记原色」的接口，而不是直接写 font_color override：
			#   填充动效每帧都按「原色 + 当前填充进度」重算（见 fill_button._sync_text）。
			FillButtonRes.set_base_font_color(cell,
				UiStyleRes.text_on_accent() if active else UiStyleRes.text())
			FillButtonRes.on_fill_text(cell, _line_labels[i],
				Color(1.0, 1.0, 1.0, 0.85) if active else UiStyleRes.text_dim())
			FillButtonRes.on_fill_text(cell, _key_labels[i],
				UiStyleRes.text_on_accent() if active
					else (UiStyleRes.text_faint() if locked else UiStyleRes.text()))
			# ★★ 已启用 = 常驻满格 + 更亮那一档金（需求：点击启用后亮度稍微变大）
			FillButtonRes.set_latched(cell, active)
			# ★★ 这一格「有科技」⇒ 参与填充动效。
			#   不能启用的格子**也参与**，只是把填充换成灰色（用户口径：
			#   「灰色填充代替金色填充 + 点击后无效果」，不是实心灰按钮）。
			FillButtonRes.set_available(cell, true)
			FillButtonRes.set_grey(cell, locked)
		else:
			_name_labels[i].text = ""
			_line_labels[i].text = ""
			cell.disabled = true              # 空格子点了不做事（也不吃键盘）
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _line_labels[i], UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			FillButtonRes.set_latched(cell, false)
			FillButtonRes.set_grey(cell, false)
			# ★ 空格子**不参与填充**：它连「科技」都没有，填起来会让人以为这一格能点。
			FillButtonRes.set_available(cell, false)
		_style_cell(cell, filled, active, locked)


## 三个状态各自一套样式。
##
## ★★ 本版把「未启用」与「已启用」的底色**交给填充层**（`tech_fill()` / `tech_latched()`：
##    底透明、只留描边）—— 旧那版是不透明实底（`tech_normal()` / `tech_active()`），
##    它会把画在底纹**下面**的填充金整个盖住，于是「悬停自下而上填金」根本看不见。
##   ⇒ 现在：没悬停 = 空框；悬停 = 金从下往上填；已启用 = 常驻满格且更亮一档。
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
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return
	var e: Dictionary = _entries[ei]
	if not bool(e.get("active", false)) and not bool(e.get("available", true)):
		return                            # 置灰格：点了什么都不发生
	cell_activated.emit(String(e.get("id", "")))


## ★★ 键盘：科技页的九格快捷键（Q/W/E/A/S/D/Z/X/C）。
##
## ★ 与点击**完全同一条路**：键位映射到视觉格 → `_on_cell_pressed()` →
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
	_on_cell_pressed(slot)
	return true


## 鼠标进入 / 离开第 i 格 —— 只转发序号（内容由 hud 现取，与命令卡同一条约定）
func _on_cell_mouse_entered(i: int) -> void:
	if touch_suppress_hover:
		return                       # 手机端按住期间不弹（长按到点后由 hud 调 hover()）
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	cell_unhovered.emit(i)


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


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func entries() -> Array:
	return _entries


## 第 i **格**显示的条目（注意：格 ≠ config 下标 —— 九格是列优先转置过的）
func entry_at(i: int) -> Dictionary:
	var ei := _entry_index_for_cell(i)
	if ei < 0 or ei >= _entries.size():
		return {}
	return _entries[ei]


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


## 模拟点第 i 格（测试用；等价于玩家点那一下）
func press(i: int) -> void:
	_on_cell_pressed(i)
