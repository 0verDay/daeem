## command_card.gd —— 右下 3×3 命令卡（参考图里 QWE / ASD / ZXC 那九格）
##
## ★ 内容**随右侧页签实时切换**（需求原话）。页签是**按选中对象动态显示**的
##   （见 view/page_tabs.gd 的文件头），所以这里可能收到的几套内容是：
##     操作页 → 移动(Q) / 攻击(W) / 行军(E) / 停止(A)  ← 对**当前选中的部队**下达的指令
##     单位页 → 占位单位(Q) = 招募亲兵                ← 来自 config.json 的 recruit.list
##     建筑页 → 城墙(Q) / 箭塔(W)                     ← 来自 logic/building.gd 的 DEFS
##     招募页 → 将领 1/2/3(Q/W/E)                     ← 来自 config.json 的 recruit.zone.list
##     科技页 → 本版还没有东西（九格全空）
##   没内容的格子只显示键位字母、置灰、点了不做事（页签一颗都没有时，九格全空）。
##
## ★ 九格的字母**是真快捷键**（需求确认）：有内容的格子优先于其它绑定。
##   这也是 W/A/S/D 从镜头平移里被拿掉的原因（见 view/main.gd）。
##
## ★ 这一层不认识「建造」「招募」「指令」这些概念：它只把格子里的条目原样抛出去，
##   由 hud.gd 翻译成 input_controller 的动作。想加一页，只需要喂一份新的 entries。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 某一格被激活（鼠标点 / 键盘按）时发出，原样带上那一条目
signal entry_activated(entry: Dictionary)

## 键位 → 格子序号。格子序号是行优先（0..2 = Q/W/E）。
const KEY_TO_SLOT := {
	KEY_Q: 0, KEY_W: 1, KEY_E: 2,
	KEY_A: 3, KEY_S: 4, KEY_D: 5,
	KEY_Z: 6, KEY_X: 7, KEY_C: 8,
}

var _entries: Array = []
var _cells: Array[Button] = []
var _key_labels: Array[Label] = []
var _name_labels: Array[Label] = []


func setup() -> void:
	name = "CommandCard"
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, UiLayoutRes.CARD_RECT, true, true)

	for i in UiLayoutRes.CARD_SLOTS:
		var cell := Button.new()
		cell.name = "CardSlot%d" % (i + 1)
		cell.focus_mode = Control.FOCUS_NONE
		cell.tooltip_text = ""
		_cell_style(cell, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		add_child(cell)

		# 键位字母贴左上角（参考图就是这样：字母小、名字居中）
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		name_label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.size = Vector2(UiLayoutRes.card_cell_local(i).size.x, UiLayoutRes.card_cell_local(i).size.y)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)

		_cells.append(cell)
		_key_labels.append(key_label)
		_name_labels.append(name_label)

	set_entries([])


# ------------------------------------------------------------------
# 内容
# ------------------------------------------------------------------

## 换一整页内容（最多 9 条，顺序就是 Q/W/E/A/S/D/Z/X/C）
func set_entries(list: Array) -> void:
	_entries = []
	for i in list.size():
		if i >= UiLayoutRes.CARD_SLOTS:
			break
		var e: Variant = list[i]
		if typeof(e) == TYPE_DICTIONARY:
			_entries.append(e)

	for i in _cells.size():
		var filled: bool = i < _entries.size()
		var cell := _cells[i]
		if filled:
			var e2: Dictionary = _entries[i]
			_name_labels[i].text = String(e2.get("name", ""))
			_name_labels[i].add_theme_color_override("font_color", UiStyleRes.TEXT)
			_key_labels[i].add_theme_color_override("font_color", UiStyleRes.ACCENT)
			cell.tooltip_text = String(e2.get("desc", ""))
			_cell_style(cell, true)
		else:
			_name_labels[i].text = ""
			_name_labels[i].add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
			_key_labels[i].add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
			cell.tooltip_text = ""
			_cell_style(cell, false)


func _cell_style(cell: Button, filled: bool) -> void:
	cell.add_theme_stylebox_override("normal", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("hover", UiStyleRes.card_hover())
	cell.add_theme_stylebox_override("pressed", UiStyleRes.card_pressed())
	cell.add_theme_stylebox_override("disabled", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_cell_pressed(i: int) -> void:
	activate_index(i)


## 激活第 i 格。@return true = 这一格有内容、动作已发出
func activate_index(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	entry_activated.emit(_entries[i])
	return true


## 键盘：只有**有内容的格**才吃掉按键（空格子让给别人，见 hud.handle_key）
##
## ★ 带修饰键的组合（Ctrl / Alt / Cmd）一律放行，不吃。
##   为什么必须有这条：`game_scene._unhandled_input` 里命令卡**排在 input_controller 之前**
##   （先问 hud 再问输入控制器），不放行的话 Ctrl+Q（开发者快捷键：全屏）会先被 Q 格吃掉
##   → 按一下全屏会顺手招募一个兵。
##   顺带把 Ctrl+W / Ctrl+E / … 这一整类组合键都让出来了。
##   ⚠️ 只挡 ctrl / alt / meta：Shift 不算 —— Shift+Q 在玩家看来仍然是 Q 格。
func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return false
	var slot: int = int(KEY_TO_SLOT.get(event.keycode, -1))
	if slot < 0 or slot >= _entries.size():
		return false
	activate_index(slot)
	return true


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
func cell_label(i: int) -> String:
	if i < 0 or i >= _name_labels.size():
		return ""
	return _name_labels[i].text
