## command_card.gd —— 右下 3×3 命令卡（参考图里 QWE / ASD / ZXC 那九格）
##
## ★ 内容**随右侧页签实时切换**（需求原话）。页签是**按选中对象动态显示**的
##   （见 view/page_tabs.gd 的文件头），所以这里可能收到的几套内容是：
##     操作页 → 移动(Q) / 攻击(W) / 行军(E) / 停止(A)  ← 对**当前选中的部队**下达的指令
##     单位页 → 占位单位(Q) = 招募亲兵                ← 来自 config.json 的 recruit.list
##     建筑页 → 城墙(Q) / 箭塔(W)                     ← 来自 config.json 的 building 段（可建的那些）
##     招募页 → 将领 1/2/3(Q/W/E)                     ← 来自 config.json 的 recruit.zone.list
##     科技页 → **命令卡这里是空的**：九格由 view/tech_grid.gd 画在最上层
##              （同一个 3×3 几何 + 科技自己的三态样式，见那个文件的说明）
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
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 某一格被激活（鼠标点 / 键盘按）时发出，原样带上那一条目
signal entry_activated(entry: Dictionary)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）时发出，带上格子序号。
##   hud 收到后会弹「悬停详情面板」（见 view/hover_tip.gd 与 hud._hover_detail）。
##   ★ 只报序号、不报内容：内容是 hud 按**当前的 entries** 取的 ——
##     与点击那条路（`activate_index`）同一套判据，界面不会出现
##     「点的是这一格、说明写的是上一页那一格」这种错位。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

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
		# ★★ 本版**不用** Godot 原生的 `tooltip_text` 了：说明改由「命令卡正上方的
		#    悬停详情面板」画（需求要的是那块面板）。两个一起挂会同时冒出两个提示框。
		#   ⚠️ `desc` 这个**数据字段**照旧留着（文案的出处是 config / 逻辑层），
		#      只是不再塞给 Button 的原生 tooltip —— 见 hud._hover_detail。
		_cell_style(cell, false)
		UiLayoutRes.apply_rect(cell, UiLayoutRes.card_cell_local(i))
		cell.pressed.connect(_on_cell_pressed.bind(i))
		# ★ 悬停：Godot 的 Control 自带这两个信号（不需要自己算鼠标位置）。
		#   子 Label 全是 IGNORE，所以事件一定落在 Button 自己身上。
		#   ⚠️ 填充动效**也用这两个信号**（它自己连的，见 fill_button.setup_host）——
		#      两条路互不干扰：这里只报「第几格」给 hud 弹说明面板。
		cell.mouse_entered.connect(_on_cell_mouse_entered.bind(i))
		cell.mouse_exited.connect(_on_cell_mouse_exited.bind(i))
		# ★★ 悬停填充：一行挂上「自绘填充（画在底纹下面）+ 鼠标跟随 + 填满时把字压成暖黑」
		FillButtonRes.attach_text(cell)
		# ★★ 字色的**统一口径**（用户要求）：「3×3 里的文字都由下往上由白变黑，
		#   与金色填充线同步」。
		#   ⇒ 一律走「原色 + 跟着金色前沿翻面」那条路（`_sync_text()` 里唯一的规则）。
		#   ⚠️ `set_prefer_light` 这行是**历史遗留**（那个开关已经作废，见 fill_button）：
		#      当年它代表「填满时仍用白字」，而白字压金**读不出来** ——
		#      那正是用户报的「3×3 的字被金色填充遮挡」，别再把它当成有效开关。
		FillButtonRes.set_prefer_light(cell, true)
		add_child(cell)

		# 键位字母贴左上角（参考图就是这样：字母小、名字居中）
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		name_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.size = Vector2(UiLayoutRes.card_cell_local(i).size.x, UiLayoutRes.card_cell_local(i).size.y)
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)

		# ★★ 两条子 Label 也要**登记**到填充上：不登记的话填充满格时它们仍然是
		#    暖白 / 暗金（压在那片金上读不出来）。登记之后由填充按进度一起压成暖黑。
		FillButtonRes.on_fill_text(cell, key_label, UiStyleRes.text_faint())
		FillButtonRes.on_fill_text(cell, name_label, UiStyleRes.text_faint())

		_cells.append(cell)
		_key_labels.append(key_label)
		_name_labels.append(name_label)

	set_entries([])


# ------------------------------------------------------------------
# 内容
# ------------------------------------------------------------------

## 换一整页内容（最多 9 条，顺序就是 Q/W/E/A/S/D/Z/X/C）
##
## ★★ 条目里的 `ready`（缺省 = true）是本版新增的**置灰**开关：条目在、说明也在，
##    但这一格现在点了没用（典型是濒死将领那颗「再起」——血量还没回到 10%）。
##    ⚠️ 为什么不干脆不画那一格：需求原话是「血量回复至 10% 及以上，则其操作栏中
##      会出现『再起』按钮」——**玩家要能看见它在等什么**（一次都不画的话，
##      玩家只会以为这个功能不存在）。所以画灰 + 悬停说明才是对的做法。
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
			var ready: bool = bool(e2.get("ready", true))
			_name_labels[i].text = String(e2.get("name", ""))
			# ★ 置灰那一档的**文字也一起变暗**：只把按钮禁掉而名字照旧是亮白的话，
			#   看起来仍然像「能点」（实测里这类「看着能点、点了没反应」最难自查）。
			# ⚠️ 走 `set_base_font_color` / `on_fill_text` 而**不是**直接写
			#    `add_theme_color_override("font_color", …)`：填充动效每帧都会按
			#    「原色 + 当前填充进度」重算这四条字的颜色，直接写 override 会被下一帧盖掉。
			# ★★ 字色口径（用户要求）：「页签内的 3×3 按钮中的文字要改成白色，
			#   和科技页的一样」。所以这里**名字与键位字母统一用暖白**
			#   （`UiStyleRes.text()`）—— 原来键位字母是暗金、名字是暖白，两套色看着不齐。
			#   ★ 科技页那九格的「名字」那一条也是暖白，这里对齐的就是那一档。
			FillButtonRes.set_base_font_color(cell,
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			# ★★ 名字那条**单独再登记一次**（否则它会停在建出来时的灰色上）。
			#
			# 为什么非要多这一句：这条 Label 是在建按钮时用**灰**（`text_faint`）建出来的，
			#   而填充层在 `attach_text()` 那一刻就把「当下的颜色」当成了这条字的**原色**
			#   （见 fill_button 的 `_current_font_color`）。之后调用点把它改成暖白时，
			#   填充层那边「登记的原色」可能已经等于暖白 ⇒ 走 `on_fill_text` 的
			#   「原色没变」那条近路 ⇒ **一次都没写进 Label**，屏幕上一直是灰的
			#   （用户报的「3×3 里的字是灰的」）。这里显式再登记一次，把渲染色压实。
			FillButtonRes.on_fill_text(cell, _name_labels[i],
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i],
				UiStyleRes.text() if ready else UiStyleRes.text_faint())
			_cell_style(cell, ready)
			cell.disabled = not ready
			# ★★ 置灰的格子**照旧有悬停反馈**，只是填的是**灰**（见 view/fill_button.gd）：
			#   填充层自己看 `disabled` 换档，所以这里**不要**再 `set_available(false)`
			#   —— 那会把动效整个关掉，鼠标停上去一点反应都没有（与需求的「灰色填充」相反）。
		else:
			_name_labels[i].text = ""
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			_cell_style(cell, false)
			cell.disabled = false


func _cell_style(cell: Button, filled: bool) -> void:
	cell.add_theme_stylebox_override("normal", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("hover", UiStyleRes.card_hover())
	cell.add_theme_stylebox_override("pressed", UiStyleRes.card_pressed())
	cell.add_theme_stylebox_override("disabled", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


func _on_cell_pressed(i: int) -> void:
	activate_index(i)


## 鼠标进入 / 离开第 i 格 —— **只转发序号**（内容由 hud 现取，见上面那两个信号的说明）
func _on_cell_mouse_entered(i: int) -> void:
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	cell_unhovered.emit(i)


## 模拟悬停第 i 格 / 离开它（等价于玩家的鼠标停上去 / 移开）。
## ★ 与 `press()` 那条同一条约定：测试走**和引擎同一条信号**，不另开一条捷径。
func hover(i: int) -> void:
	_on_cell_mouse_entered(i)


func unhover(i: int) -> void:
	_on_cell_mouse_exited(i)


## 激活第 i 格。@return true = 这一格有内容、动作已发出
func activate_index(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	entry_activated.emit(_entries[i])
	return true


## 键盘：只有**有内容的格**才吃掉按键（空格子让给别人，见 hud.handle_key）
##
## ★★ 被置灰的格子（`ready == false`）**也不吃按键**（本版新增）：与点击那条路
##   保持一致 —— 否则按 Q 会静默地什么都不发生（格子画着灰、键盘却"接受了"这一下），
##   而玩家更可能只是想按 Q 做别的事（那几个字母同时也是别的绑定的候选）。
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
	if not bool((_entries[slot] as Dictionary).get("ready", true)):
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
