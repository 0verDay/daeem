## command_card.gd —— 右下 3×3 命令卡（参考图里 QWE / ASD / ZXC 那九格）
##
## ★ 内容**随右侧页签实时切换**（需求原话）。页签是**按选中对象动态显示**的
##   （见 view/page_tabs.gd 的文件头），所以这里可能收到的几套内容是：
##     操作页 → 移动(Q) / 攻击(W) / 行军(E) / 停止(A)  ← 对**当前选中的部队**下达的指令
##     单位页 → 三行兵种（Q/W/E …；第 1/2/3 行分别要 1/2/3 级大本营） ← config.json 的 recruit.list
##     建筑页 → 城墙(Q) / 箭塔(W)                     ← 来自 config.json 的 building 段（可建的那些）
##     招募页 → 池子抽出的一手（Q/W/E）              ← world.general_recruit_slots()
##     科技页 → **命令卡这里是空的**：九格由 view/tech_grid.gd 画在最上层
##              （同一个 3×3 几何 + 科技自己的三态样式，见那个文件的说明）
##   没内容的格子只显示键位字母、置灰、点了不做事（页签一颗都没有时九格全空，
##   并由 hud 把这整块和页签一起收起；见 `hud._sync_tabs()`）。
##
## ★ 九格的字母**是真快捷键**（需求确认）：有内容的格子优先于其它绑定。
##   这也是 W/A/S/D 从镜头平移里被拿掉的原因（见 view/main.gd）。
##
## ★ 这一层不认识「建造」「招募」「指令」这些概念：它只把格子里的条目原样抛出去，
##   由 hud.gd 翻译成 input_controller 的动作。想加一页，只需要喂一份新的 entries。
##
## ★★ 格子排版（2026.11 定稿）：「**图标 + 一行名字**」。
##   条目带 `icon_mask`（金线蒙版路径）或 `icon_role`（矢量兜底）时：
##   · 图标**铺满整格** —— 它不考虑文字的位置（用户口径）；
##   · 名字叠在最下面那条**略黑的底条**上（`NAME_BAR_H`，填充扫上来时底条淡出，
##     字翻成压金暗色 —— 否则深底 + 深字读不出来）；
##   · 更长的说明（造价 / 效果 / 解锁条件）只进**悬停面板**（见 hud 的 `_hover_detail`）。
##   没有图标的页（操作页：移动 / 攻击 / 行军 / 停止）仍是整格居中的一行字、不垫底条。
##   ⚠️ 名字**永远写进 Label、并且可见** —— `cell_label()` 是测试与排查的语义出口，
##      旧版「有图就把名字藏起来」的做法已经作废（用户改口径了）。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")
## ★★ 格子里那枚**单位剪影浮雕图**（见 view/unit_card_icon.gd）。
##   本版：单位页的格子不再写兵种名字，改画**该兵种原画的剪影** ——
##   条目里带 `icon_mask`（hud 灌进来的蒙版路径）就画图；
##   只有 `icon_role` 的旧条目 / 蒙版缺失时退回矢量金线（同一条兜底）。
##   没有这两个键的页面（操作 / 建筑 / 科技）照旧只有字。
const UnitCardIconRes = preload("res://view/unit_card_icon.gd")

## 某一格被激活（鼠标点 / 键盘按）时发出，原样带上那一条目
signal entry_activated(entry: Dictionary)

## ★★ 某一格被**鼠标悬停**（进入 / 离开）时发出，带上格子序号。
##   hud 收到后会弹「悬停详情面板」（见 view/hover_tip.gd 与 hud._hover_detail）。
##   ★ 只报序号、不报内容：内容是 hud 按**当前的 entries** 取的 ——
##     与点击那条路（`activate_index`）同一套判据，界面不会出现
##     「点的是这一格、说明写的是上一页那一格」这种错位。
signal cell_hovered(index: int)
signal cell_unhovered(index: int)

var _entries: Array = []
var _cells: Array[Button] = []
var _key_labels: Array[Label] = []
var _name_labels: Array[Label] = []
## ★★ 每格的**名字底条**（略黑半透明横条，名字压在它上面）。
##    只有「这格有图标」时才显示 —— 操作页那种纯文字页不需要底条。
var _name_bars: Array[ColorRect] = []
## ★★ 每格的**单位剪影浮雕**层（`view/unit_card_icon.gd` 的 `IconView`）。
##   与 `_name_labels` 一一对应、同一序号；空串 = 这一格不画图标。
var _icon_views: Array = []

## ★★ 手机端：按住某一格期间由 hud 置 true —— 「按下」产生的模拟鼠标会让这一格**立刻**
##    收到 mouse_entered，那是「悬停」，而需求是「长按才悬停」⇒ 按住期间忽略鼠标进入。
##    `hover()`（长按到点之后由 hud 调）**不受**它影响，直接发信号。
var touch_suppress_hover: bool = false


## ★★ 格子里的**名字底条**高度（设计像素 @86.67 的格子）。名字就压在这条上。
## 0 / 1 的取舍：够高才装得下 11px 的字，又要尽量少盖图标 —— 15px 是实测折中。
const NAME_BAR_H := 15.0
## 有图标时名字那一行的字号（`ui_style.FS_TINY`：86.67px 的格子里一行放得下 7 个汉字）。
const NAME_ON_ICON_FS := 11


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
		# ★★ 每格都带常驻灰底（空格子也不例外）：底纹是全透明的，
		#   灰底画在填充层里、金的上方；这样悬停时灰底不会消失（用户报的 bug）。
		FillButtonRes.set_base_bg(cell, UiStyleRes.bg_empty())
		# ★★ 字色的**统一口径**（用户要求）：「3×3 里的文字都由下往上由白变黑，
		#   与金色填充线同步」。
		#   ⇒ 一律走「原色 + 跟着金色前沿翻面」那条路（`_sync_text()` 里唯一的规则）。
		#   ⚠️ `set_prefer_light` 这行是**历史遗留**（那个开关已经作废，见 fill_button）：
		#      当年它代表「填满时仍用白字」，而白字压金**读不出来** ——
		#      那正是用户报的「3×3 的字被金色填充遮挡」，别再把它当成有效开关。
		FillButtonRes.set_prefer_light(cell, true)
		add_child(cell)

		# ★★ 金线图标层：**铺满整格**、不吃鼠标。
		#    ★ 它**排在两个 Label / 底条之前**建（= 画在它们下面）—— 快捷键字母与
		#    名字那条底条必须压在图形之上。
		#    ★★ 图标**不考虑文字的位置**（用户口径）：它占满整格，名字改为叠在
		#    最下面那条**略黑的底条**上。以前「图标只占上面 74%」的做法有两个毛病：
		#    ① 蒙版是正方形，塞进扁矩形会被拉伸 ⇒ 图标看着**扁**；
		#    ② 只剩 64px 高，下采样比例更大 ⇒ 更**糊**。
		var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
		var icon_view := UnitCardIconRes.IconView.new()
		icon_view.name = "CardIcon%d" % (i + 1)
		cell.add_child(icon_view)
		# ★ `bind(cell)` 铺满整格（图标自己按正方形居中，见 `IconView` / `mask_rect`）。
		icon_view.bind(cell)

		# 键位字母贴左上角（参考图就是这样：字母小、名字居中）
		var key_label := Label.new()
		key_label.text = String(UiLayoutRes.CARD_KEYS[i])
		key_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		key_label.add_theme_font_size_override("font_size", UiStyleRes.FS_TINY)
		key_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		key_label.position = Vector2(4.0, 1.0)
		cell.add_child(key_label)

		# ★★ 名字底条：叠在图标**最下面**的一条略黑横条。
		#    ★ 为什么需要它：图标现在铺满整格，名字直接压在线稿上读不清；
		#      垫一条半透明深色，既保住可读性，又不把图标切掉一块（用户口径：
		#      「图标不需要考虑文字的位置，文字用一个略黑的底条作为容器」）。
		#    ★ 它建在图标**之后**（= 画在图标之上）、名字 Label **之前**（名字再压它）。
		var name_bar := ColorRect.new()
		name_bar.name = "CardNameBar%d" % (i + 1)
		name_bar.color = UiStyleRes.name_bar()
		name_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_bar.position = Vector2(0.0, cell_size.y - NAME_BAR_H)
		name_bar.size = Vector2(cell_size.x, NAME_BAR_H)
		name_bar.visible = false
		cell.add_child(name_bar)

		var name_label := Label.new()
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		name_label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		name_label.add_theme_color_override("font_color", UiStyleRes.text_faint())
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.clip_text = true
		name_label.size = cell_size
		name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(name_label)

		# ★★ 两条子 Label 也要**登记**到填充上：不登记的话填充满格时它们仍然是
		#    暖白 / 暗金（压在那片金上读不出来）。登记之后由填充按进度一起压成暖黑。
		FillButtonRes.on_fill_text(cell, key_label, UiStyleRes.text_faint())
		FillButtonRes.on_fill_text(cell, name_label, UiStyleRes.text_faint())

		_cells.append(cell)
		_key_labels.append(key_label)
		_name_labels.append(name_label)
		_name_bars.append(name_bar)
		_icon_views.append(icon_view)

	# ★★ 整组 2px 外框：九格自己的 1px 描边只勾出格子，外框把整块命令卡和地图分开。
	#    ★ 最后加（画在九格之上）+ IGNORE（铺满整块，STOP 会吞掉所有格子点击）。
	var frame := Panel.new()
	frame.name = "CardFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	frame.add_theme_stylebox_override("panel", UiStyleRes.outline_style(UiStyleRes.line(), 2))
	add_child(frame)

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
		# ★★ 空字典 = **空格子**（单位页按行解锁后会留下空位，见 hud._recruit_entries）。
		#    它占着序号（Q/W/E/A/S/D/Z/X/C 的键位不挪），但不显示名字、点了不做事。
		var filled: bool = i < _entries.size() and not (_entries[i] as Dictionary).is_empty()
		var cell := _cells[i]
		if filled:
			var e2: Dictionary = _entries[i]
			var ready: bool = bool(e2.get("ready", true))
			_name_labels[i].text = String(e2.get("name", ""))
			# ★★ 条目带 `icon_mask` / `icon_role` ⇒ 这一格画**图标**、把名字那行字藏起来
			#    （需求：「招募单位的按钮内的文字改为图标」）。
			#   `icon_mask` 是主路径（该兵种原画的剪影浮雕）；`icon_role` 是兜底
			#    （蒙版缺失 / 旧条目时退回矢量金线）。
			#   ⚠️ 名字**照旧写进 Label**（只是 `visible = false`）：`cell_label()` 是
			#     测试与排查用的**语义出口**，隐藏文字不该把它一起弄没。
			var role := String(e2.get("icon_role", ""))
			var mask := String(e2.get("icon_mask", ""))
			_set_icon(i, role, mask, ready)
			# ★★ 有图标时：名字**照样显示**，只是压到格子最下面那一行（需求：
			#    「图标 + 一行名字，描述全进悬停面板」——单位和建筑都要这样）。
			#    没有图标时（操作页那种）名字照旧居中、用大一号的字。
			#   ⚠️ 名字**永远写进 Label**：`cell_label()` 是测试与排查的语义出口。
			var has_icon: bool = role != "" or mask != ""
			_name_labels[i].visible = true
			_apply_name_layout(i, has_icon)
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
			_name_labels[i].visible = true
			_set_icon(i, "", "")
			_apply_name_layout(i, false)
			FillButtonRes.set_base_font_color(cell, UiStyleRes.text_faint())
			FillButtonRes.on_fill_text(cell, _key_labels[i], UiStyleRes.text_faint())
			_cell_style(cell, false)
			cell.disabled = false


## 第 i 格**名字那一行**的排版：有图标 → 压到最下面一窄条、字号小一档；
## 没图标 → 整格居中、用正文号（操作 / 建筑 / 科技那种纯文字格）。
## 第 i 格**名字**的排版：
## · 有图标 → 名字压在最下面那条**略黑底条**上（底条显示出来），字号小一档；
## · 没图标（操作页）→ 底条藏起来，名字整格居中、用正文号。
## ★ 图标**不跟着动**：它始终铺满整格（用户口径：图标不考虑文字的位置）。
func _apply_name_layout(i: int, has_icon: bool) -> void:
	if i < 0 or i >= _name_labels.size():
		return
	var label: Label = _name_labels[i]
	var cell_size: Vector2 = UiLayoutRes.card_cell_local(i).size
	if i < _name_bars.size() and _name_bars[i] != null and is_instance_valid(_name_bars[i]):
		(_name_bars[i] as ColorRect).visible = has_icon
	if has_icon:
		label.position = Vector2(1.0, cell_size.y - NAME_BAR_H)
		label.size = Vector2(cell_size.x - 2.0, NAME_BAR_H)
		label.add_theme_font_size_override("font_size", NAME_ON_ICON_FS)
	else:
		label.position = Vector2.ZERO
		label.size = cell_size
		label.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)


## ★★ 底条要**跟着金色填充淡出**（每帧一次，只有 9 格）：
##   填充是从下往上扫的，而底条正好在最下面 —— 金色一盖上来，那段字就该翻成
##   「压金暗色」（填充层管这件事），此时底条若还是深的，就是**深字压深底**、读不出来
##   （实测踩过：悬停时那一格的名字几乎看不见）。所以底条透明度 = 1 - 填充进度。
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


func _cell_style(cell: Button, filled: bool) -> void:
	cell.add_theme_stylebox_override("normal", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("hover", UiStyleRes.card_hover())
	cell.add_theme_stylebox_override("pressed", UiStyleRes.card_pressed())
	cell.add_theme_stylebox_override("disabled", UiStyleRes.card_normal(filled))
	cell.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## 给第 i 格换图标（`mask` 为空且 `role` 也为空 = 这一格不画图标）。
## ★ 本层不认识「兵种」：兵种 → 蒙版路径 / 图形的映射在 view/unit_card_icon.gd，
##   条目那一侧（hud）算好 —— 这里只收两个字符串。
## @param mask 剪影浮雕蒙版路径（主路径）
## @param role 矢量金线图形（蒙版缺失时的兜底）
## @param ready 这一格现在能不能点（锁住的行图标也画暗一档，与灰字同一个观感）
func _set_icon(i: int, role: String, mask: String, ready: bool = true) -> void:
	if i < 0 or i >= _icon_views.size():
		return
	var v = _icon_views[i]
	if v == null or not is_instance_valid(v):
		return
	v.set_role(role)
	v.set_mask(mask)
	v.set_ready(ready)


func _on_cell_pressed(i: int) -> void:
	activate_index(i)


## 鼠标进入 / 离开第 i 格 —— **只转发序号**（内容由 hud 现取，见上面那两个信号的说明）
func _on_cell_mouse_entered(i: int) -> void:
	if touch_suppress_hover:
		return                       # 手机端按住期间不弹（长按到点后由 hud 调 hover()）
	cell_hovered.emit(i)


func _on_cell_mouse_exited(i: int) -> void:
	cell_unhovered.emit(i)


## 模拟悬停第 i 格 / 离开它（等价于玩家的鼠标停上去 / 移开）。
## ★ 与 `press()` 那条同一条约定：测试走**和引擎同一条信号**，不另开一条捷径。
## ★★ 手机端的长按也走这里 —— 所以它**绕开** `touch_suppress_hover` 直接发信号。
func hover(i: int) -> void:
	cell_hovered.emit(i)


func unhover(i: int) -> void:
	cell_unhovered.emit(i)


## 激活第 i 格。@return true = 这一格有内容、动作已发出
func activate_index(i: int) -> bool:
	if i < 0 or i >= _entries.size():
		return false
	if (_entries[i] as Dictionary).is_empty():
		return false                     # 空格子（单位页按行解锁留下的空位）
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
	var slot: int = int(UiLayoutRes.CARD_KEY_TO_SLOT.get(event.keycode, -1))
	if slot < 0 or slot >= _entries.size():
		return false
	if (_entries[slot] as Dictionary).is_empty():
		return false                     # 空格子不吃按键（让给别的绑定）
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


## 第 i 格那行名字**现在看不看得见**。
## ★ 有图标的格子把名字藏起来了（文字由图标代替），但 `cell_label()` 仍读得到 ——
##   这两件事在这里是分开的两个出口，测试要断言哪一个就取哪一个。
func cell_label_visible(i: int) -> bool:
	if i < 0 or i >= _name_labels.size():
		return false
	return _name_labels[i].visible


## 第 i 格现在画的是哪张图标（空串 = 不画图标、只有字）。
func cell_icon_role(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	return String(v.role()) if v != null and is_instance_valid(v) else ""


## 第 i 格现在画的**剪影蒙版路径**（空串 = 走矢量兜底 / 没有图标）。
## ★ 与 `cell_icon_role()` 是两个出口：主路径是蒙版，role 只在缺蒙版时才会被画。
func cell_icon_path(i: int) -> String:
	if i < 0 or i >= _icon_views.size():
		return ""
	var v = _icon_views[i]
	return String(v.mask_path()) if v != null and is_instance_valid(v) else ""
