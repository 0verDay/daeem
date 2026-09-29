## map_select.gd —— ★ 开场主界面那条**地图选择条**（自绘，不用 OptionButton）
##
## 需求原文：「在其上方加一个选择条，可以在其中选择地图……游戏会根据地图目录下的文件
##           自动给出新的选项」。选项从哪来（`logic/map_library.gd` 扫 `data/maps/`）
## 与本文件无关 —— 这里只管「怎么把它显示出来、怎么让玩家选」。
##
## ★★ 为什么不用引擎自带的 `OptionButton`（这是踩过坑才换的，别再换回去）：
##   `OptionButton` = Button + PopupMenu，而**按钮上那行字由它的内部状态决定何时刷新**。
##   实测（手玩报的）：点开列表之后，按钮上那行字**会变成空白**，把鼠标移到某一项上
##   才又出现。原因在引擎那一侧（打开 / 关闭原生列表窗口的过程中，按钮停在
##   「字是空的那一帧」上，且**不保证重画**）——在 `_process` 里补 `queue_redraw()`、
##   自己写 `text` 都只是碰运气，无头 / 子视口下还复现不出来（列表是独立 OS 窗口）。
##
##   所以这里换成**我们自己画的按钮**：
##     · 那行字是 `Button.text`，由 `_sync_text()` **每次选中都重新写一遍**；
##     · 列表用 `PopupMenu`，只在选中 / 取消时回调，**不参与按钮的绘制**；
##     · 按钮的 `pressed` 只负责开关列表 —— 没有任何「等引擎重画」的时机问题。
##
## ★ 对外 API 刻意做成与 `OptionButton` 同名同义（`item_count` / `get_item_text` /
##   `selected` / `select()` / `disabled` / `item_selected`），
##   这样 view/start_screen.gd 与测试不必知道底下换过实现。
##
## ⚠️ 它**不自己造样式**：配色 / 字号 / 边框由 view/start_screen.gd 做好传进来
##   （那两页是白底、不走 ui_style 的深色 HUD 配色，样式只有一个来源）。
extends RefCounted

## 选了某一项（`index` 是新选中项）。★ 与 OptionButton 的同名信号语义一致。
signal item_selected(index: int)

## 放选项与那行字的按钮（`start_screen` 需要它来摆位置、加进容器）
var button: Button = null
## 下拉列表（挂在按钮下面，由本类创建与开关）
var popup: PopupMenu = null

## 当前选中项（-1 = 没有任何选项）。★ 与 OptionButton 同名。
## ⚠️ 读它请用 `selected`（`get_selected()` 是给它用的 getter，别直接调）。
var selected: int = -1: get = get_selected

var _names: Array[String] = []


##
## @param parent       宿主控件（按钮加在它下面；列表也挂在按钮下）
## @param font         中文字体（null = 引擎默认字体，中文会是方框）
## @param font_size    那行字的字号
## @param text_color   那行字的颜色
## @param style_normal / style_hover / style_pressed / style_focus  四个态的底纹
## @param popup_panel  下拉列表那块底板（★ 必须显式给：引擎默认是**深色**，
##                     而这两页是白底、字是深灰 —— 不给的话列表弹出来是一坨黑、
##                     里面的字几乎读不出来。实测踩过。）
## @param row_hover    列表里鼠标停在一项上的底纹（浅色，与白底列表配套）
## @param min_size     按钮最小尺寸
##
func build(parent: Control, font: Font, font_size: int, text_color: Color,
		style_normal: StyleBox, style_hover: StyleBox, style_pressed: StyleBox,
		style_focus: StyleBox, popup_panel: StyleBox, row_hover: StyleBox,
		min_size: Vector2) -> void:
	button = Button.new()
	button.name = "MapSelect"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = min_size
	if font != null:
		button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", font_size)
	# ★ 四个态都用同一个字色：白底按钮上 hover / pressed 换字色只会显得在闪。
	for slot in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(slot, text_color)
	button.add_theme_stylebox_override("normal", style_normal)
	button.add_theme_stylebox_override("hover", style_hover)
	button.add_theme_stylebox_override("pressed", style_pressed)
	button.add_theme_stylebox_override("focus", style_focus)
	# ★ 白底控件上再叠一层引擎默认的悬停浮起 / 焦点外框会很难看
	button.flat = false
	button.pressed.connect(toggle)
	parent.add_child(button)

	popup = PopupMenu.new()
	popup.name = "MapSelectPopup"
	if font != null:
		popup.add_theme_font_override("font", font)
	popup.add_theme_font_size_override("font_size", font_size)
	popup.add_theme_color_override("font_color", text_color)
	# ★★ 列表的配色**必须显式给**（引擎默认是深色 HUD 那一套）：
	#    不给的话，白底页面上弹出来一坨黑、里面的深灰字几乎看不见 —— 实测截图抓到过。
	for slot in ["font_hover_color", "font_focus_color", "font_accelerator_color",
			"font_disabled_color", "font_separator_color"]:
		popup.add_theme_color_override(slot, text_color)
	popup.add_theme_stylebox_override("panel", popup_panel)
	popup.add_theme_stylebox_override("hover", row_hover)
	# ★ 让列表**跟着按钮走**：点了按钮就把列表贴在按钮下边缘弹出来。
	#   不自己算坐标，是因为按钮的位置由 CenterContainer / VBoxContainer 排版决定，
	#   在 build 的那一刻还不知道最终落在哪。
	popup.id_pressed.connect(_on_item_pressed)
	button.add_child(popup)


## 铺选项（会清掉旧的）。`select()` 与 `item_selected` 的语义与 OptionButton 一致。
func set_items(names: Array) -> void:
	_names.clear()
	if popup == null:
		return
	popup.clear()
	for n in names:
		var text := String(n)
		_names.append(text)
		popup.add_item(text)


func item_count() -> int:
	return _names.size()


func get_item_text(index: int) -> String:
	if index < 0 or index >= _names.size():
		return ""
	return _names[index]


func get_selected() -> int:
	return selected


## 选中第 index 项。★ 只改状态与那行字，**不发** `item_selected`
## （与 OptionButton 的 `select()` 一致：代码选中 ≠ 玩家点了它）。
func select(index: int) -> void:
	if index < 0 or index >= _names.size():
		return
	selected = index
	_sync_text()


## 禁用（一张地图都扫不到时用）。⚠️ 禁用时点它不开列表。
func set_disabled(value: bool) -> void:
	if button != null:
		button.disabled = value


func is_disabled() -> bool:
	return button != null and button.disabled


## 按钮上那行字（供测试与排查用；正常情况下它就是当前选项的文字）
func text() -> String:
	return "" if button == null else button.text


## 点按钮：开着就收起来，关着就弹出来（开关式，与设置菜单同一个手感）。
##
## ★ 列表弹出的位置与宽度都由这里定：
##   · 位置 = 按钮**下边缘**贴齐（不自己算 y 偏移：按钮在容器里怎么排是排版的事）；
##   · 宽度 = 至少和按钮一样宽 —— 引擎默认按内容算，中文项会比按钮窄一截，
##     看着像一块补丁。⚠️ 必须在 `popup()` **之前**把 size 定好，
##     否则弹出来会按内容尺寸显示一次再被拉宽（会闪一下）。
func toggle() -> void:
	if popup == null or button == null or button.disabled or _names.is_empty():
		return
	if popup.visible:
		popup.hide()
		return
	popup.reset_size()
	# ★★ 宽度要**两处都设**（实测：只设 size 的话引擎会在弹出来那一刻按内容重算，
	#    列表比按钮窄一大截，看着像块补丁）：
	#    `min_size` 抬住下限（⚠️ PopupMenu 是 Window，没有 `custom_minimum_size`
	#    那个 Control 属性 —— 写错了会直接报 Invalid assignment），`size` 立刻生效。
	var want_w := maxi(int(button.size.x), int(popup.get_contents_minimum_size().x))
	popup.min_size = Vector2i(want_w, 0)
	popup.size.x = want_w
	popup.position = Vector2i(
		int(button.global_position.x), int(button.global_position.y + button.size.y))
	popup.popup()
	# 弹出来之后再确认一次（有的引擎版本会在 popup() 里再算一遍尺寸）
	popup.size.x = want_w


func _on_item_pressed(id: int) -> void:
	selected = id
	_sync_text()
	item_selected.emit(id)


## ★★ 把当前选项的文字写进按钮 —— **这是这个类存在的理由**。
##
## 每次选中 / 铺完选项都调它：按钮的 `text` 永远等于当前选中项，
## 不依赖任何「引擎觉得该重画了」的时机（那正是 OptionButton 出问题的地方）。
func _sync_text() -> void:
	if button == null:
		return
	button.text = get_item_text(selected)
