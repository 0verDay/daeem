## map_select.gd —— ★ 那条**下拉选择条**（自绘按钮 + 自己的列表，不用 OptionButton）
##
## 需求原文（地图那份）：「在其上方加一个选择条，可以在其中选择地图……游戏会根据地图目录下
##           的文件自动给出新的选项」。选项从哪来（`logic/map_library.gd` 扫 `data/maps/`）
## 与本文件无关 —— 这里只管「怎么把它显示出来、怎么让玩家选」。
##
## ★★ 用户后来要求「战役选择也照这条做」（原话：「点击选项条后读取相应目录下的战役配置项
##    动态生成选项……类似主界面选 test 地图」）⇒ 本文件从「地图选择条」**升格成一个通用部件**，
##    两个界面共用同一份实现（`view/campaign_test.gd` 用的就是它）。
##    加 `node_name` 参数只是为了让两处的节点名各自可读（`MapSelect` / `CampaignSelect`）——
##    **行为一个字没变**，地图那条路走的还是同名默认值。
##    ⚠️ 这份文件与那个类的**名字**仍叫 map_select / `MapSelect`（改名要同步改
##      `view/start_screen.gd` 与两个测试文件，收益只是好看一点）——改名前先看这里。
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
##   （进入界面走的是 view/menu_theme.gd 的「暗底 + 金线」，与游戏内 HUD 那套不同；样式只有一个来源）。
extends RefCounted

## ★ 选了某一项（`index` 是新选中项）。★ 与 OptionButton 的同名信号语义一致。
signal item_selected(index: int)

## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
##   ★ 本文件**仍然是「不自己造样式」的**：填充动效不是样式，它是「按钮怎么响应鼠标」，
##     与传进来的那套 StyleBox 正交 —— 所以它留在**部件内部**（每个用它的界面都该有）。
const FillButtonRes = preload("res://view/fill_button.gd")
## ★ 只有一处用到它：下拉列表里「鼠标停在哪一项」那行字要取最亮的那支金。
const ThemeRes = preload("res://view/theme.gd")

## 放选项与那行字的按钮（`start_screen` 需要它来摆位置、加进容器）
var button: Button = null
## 宿主界面节点（`build()` 传进来的 parent）：补间的挂点之一（见 `_tween_host`）。
var _host: Node = null
## 下拉列表（挂在按钮下面，由本类创建与开关）
var popup: PopupMenu = null

## 当前选中项（-1 = 没有任何选项）。★ 与 OptionButton 同名。
##
## ⚠️⚠️ **这个属性现在是坏的，别读它**：`get = get_selected` 而 `get_selected()` 又
##    `return selected` —— 自引用，读出来永远是 -1（实测：`select(1)` 之后
##    `bar.selected` 仍是 -1，但**按钮上那行字是对的**，所以从界面上看不出来）。
##    ✅ 要读就用 **`get_selected()`**（它是普通方法调用，返回的是真值）。
##    ✅ `view/campaign_test.gd` 干脆自己记了一份下标（`_campaign_index`），不碰这里。
##    ❌ 没在这次改动里修它：修了会动到 `view/start_screen.gd` 与
##       `tests/test_map_select.gd`（它现在有一批断言是**按坏行为**写绿的），
##       属于另一件事 —— 要修请连那批断言一起重写，别只改这两行。
var selected: int = -1: get = get_selected

var _names: Array[String] = []


# ------------------------------------------------------------------
# ★★ 下拉列表的「缓动展开 / 缓动收缩」（本版需求）
#
#   需求原话：「点击选项条时，下拉条要缓动展开；在列表出现时点击选项条或点击空白处时，
#             要缓动收缩」。
#
# ★ 为什么不能用 `popup.popup()` + `popup.hide()` 直接了事：那两个是**瞬发**的
#   （引擎直接把窗口显示 / 隐藏），没有任何过渡可挂。所以这里自己做补间。
#
# ⚠️⚠️ 三个实测踩到的坑（4.7 的属性名与直觉不同，别照抄别的引擎 / Godot 3 的经验）：
#   ① `PopupMenu` 是 **Window**，不是 Control ⇒ **没有** `pivot_offset` / `scale`
#      （写上去直接报 "Invalid assignment"）。所以「展开」只能用
#      **位置 + 高度**做：窗口上沿钉在按钮下沿不动，高度从很薄长到全高 ——
#      观感就是「从按钮下沿往下展开」。淡入靠 `modulate:a`（Window 有它）。
#   ② `PopupMenu` **没有** `popup_hide_on_focus_loss` 这个属性 —— 它失焦就自己
#      `hide()`。所以「点空白处」的收缩只能靠 **`popup_hide` 信号**接回来：
#      引擎刚把它藏起来、`popup_hide` 就发出来，我们在那一帧把窗口**重新显示**
#      并淡出 + 收薄（观感仍是「缓动收缩」）。
#   ③ 收缩途中引擎可能再发一次 `popup_hide`（甚至同一帧两次）⇒ 用 `_closing` 挡重入，
#      否则两条补间同时改同一个窗口，屏幕上就是一串抖动。
# ------------------------------------------------------------------

## 展开 / 收缩的时长（秒）。★ 收缩比展开短一点：玩家已经决定关掉它了。
const POPUP_OPEN_TIME := 0.16
const POPUP_CLOSE_TIME := 0.12
## 展开时起点比终点**高多少像素**（收缩时反过来收回去）。
##
## ★ 这是本版能做到的「从选项条背后滑出来」：`Window` 没有 `z_index`（动不了层次）、
##   高度又被内容最小高夹住（动不了大小），所以只能靠「一点点位移 + 淡入」模拟。
##   ⚠️ 别把这个值调大：超过一个选项条的高度，列表就会从选项条**上面**冒出来，
##      观感立刻变成「从天上掉下来」。
const POPUP_OPEN_RISE := 14

## 当前在跑的补间（null = 没有）。见上面那三条 ⚠️。
var _tween: Tween = null## 正在收缩吗（收缩途中别再收一次：`popup_hide` 可能连发）。
var _closing: bool = false
## 这一下关闭是「玩家选中了某一项」吗（见 `_on_popup_hide`）。
var _chose_item: bool = false
## 正在**我们自己**主动 `hide()` 吗（用来认领 `popup_hide` 那一下，见 `_finish_collapse`）。
var _hiding_self: bool = false
## 列表底板的**原样**（淡入淡出时从它复制，见 `_apply_panel_alpha`）。
var _panel_base: StyleBox = null
## 当前的不透明度（0..1）。Window 没有 modulate，只能自己记着改底板。
var _alpha: float = 1.0


##
## @param parent       宿主控件（按钮加在它下面；列表也挂在按钮下）
## @param font         中文字体（null = 引擎默认字体，中文会是方框）
## @param font_size    那行字的字号
## @param text_color   那行字的颜色
## @param style_normal / style_hover / style_pressed / style_focus  四个态的底纹
## @param popup_panel  下拉列表那块底板（★ 必须显式给：引擎默认是**深色**，
##                     而引擎默认那份与进入界面的暗金底**不是一套** —— 不给的话
##                     列表弹出来会和按钮对不上（浅底配暖白字尤其读不出来）。实测踩过。）
## @param row_hover    列表里鼠标停在一项上的底纹（淡金底，与暗底列表配套）
## @param min_size     按钮最小尺寸
## @param node_name    按钮的节点名（默认 `MapSelect`；战役页传 `CampaignSelect`）。
##                     ★ 它只是**给人和测试看**的名字，不影响任何行为。
##
func build(parent: Control, font: Font, font_size: int, text_color: Color,
		style_normal: StyleBox, style_hover: StyleBox, style_pressed: StyleBox,
		style_focus: StyleBox, popup_panel: StyleBox, row_hover: StyleBox,
		min_size: Vector2, node_name: String = "MapSelect") -> void:
	_host = parent
	button = Button.new()
	button.name = node_name if node_name != "" else "MapSelect"
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = min_size
	if font != null:
		button.add_theme_font_override("font", font)
	button.add_theme_font_size_override("font_size", font_size)
	button.add_theme_stylebox_override("normal", style_normal)
	button.add_theme_stylebox_override("hover", style_hover)
	button.add_theme_stylebox_override("pressed", style_pressed)
	button.add_theme_stylebox_override("focus", style_focus)
	# ★ 再叠一层引擎默认的悬停浮起 / 焦点外框会很难看
	button.flat = false
	button.pressed.connect(toggle)
	parent.add_child(button)
	# ★★ 挂填充动效**必须在四档底纹都设好之后**（顺序要紧）：
	#   填充层要按「这颗按钮**底纹的底色**」来决定字色选哪一档
	#    （见 fill_button._panel_color）。底纹还没设完就挂，它会读到引擎默认那一格，
	#    于是**字色当场选错**（实测：下拉选择条的字一度变成暗色）。
	#    每帧会重算、下一帧能自愈，但没必要留那一帧的错色。
	#   ★ 四个态都用同一个字色（`text_color`）：暗底按钮上 hover / pressed 换字色
	#     只会显得在闪。⚠️ 走 `set_base_font_color`（填充动效的接口），
	#     不是直接写 `add_theme_color_override` —— 填满时那行字由填充层按进度算。
	FillButtonRes.attach_text(button)
	FillButtonRes.set_base_font_color(button, text_color)
	# ★★ 告诉填充层「这颗按钮下面是什么」：选择条是**透明底**，它真正坐在
	#    进入界面那层深色渐变页底上。让填充层去猜底纹会猜错
	#    （实测：它扫到了 `pressed` 那一格的实心金，于是空鼠标时也按「金字底」算，
	#      字色当场选成暗色 —— 用户看到的就是「选择条上的字变灰了」）。
	FillButtonRes.set_panel_color(button, Color(0.0, 0.0, 0.0, 0.0))

	popup = PopupMenu.new()
	popup.name = "MapSelectPopup"
	# ★★ 把列表改成**游戏内嵌窗口**（不再是一个独立的 OS 窗口）。
	#
	# 为什么内嵌（用户需求：「列表固定渲染在选择条那一层下面，视觉上从它背后滑出来」）：
	#   独立 OS 窗口**永远在所有游戏画布之上**，没法跟游戏画面讲层次；内嵌之后它变成
	#   画在游戏视口里的子窗口，于是「父节点先画、子节点后画」这条规则生效 ——
	#   ⚠️ 它就是**按钮的子节点**，所以它画在按钮**之后**（= 在按钮上方）。
	#   ⇒ 想要「从选项条背后滑出来」，靠的不是 z 序：`Window`（含 PopupMenu）
	#     **没有** `z_index`，写上去直接报 Invalid assignment（实测）。真正的做法是
	#     **让展开动画只从列表顶端那一小段开始露**：起点让列表上沿 = 按钮下沿、
	#     高度接近 0，再往下长 —— 那块始终在按钮下沿之下，看起来就是从选项条背后
	#     抽出来的。见 `expand()`。
	#
	# ⚠️ 内嵌是**视口级**开关（`Viewport.gui_embed_subwindows`），会影响本视口里
	#   所有子窗口。本工程的子窗口只有这几条下拉列表（都由本文件造），所以是安全的；
	#   顺带还修掉了独立窗口那一堆麻烦（抢焦点、隐藏时补间不推进、
	#   `show()` 报 "already active"）。
	var vp := parent.get_viewport()
	if vp != null:
		vp.gui_embed_subwindows = true
	if font != null:
		popup.add_theme_font_override("font", font)
	popup.add_theme_font_size_override("font_size", font_size)
	popup.add_theme_color_override("font_color", text_color)
	# ★★ 列表的配色**必须显式给**（引擎默认是浅色 HUD 那一套）：
	#    不给的话，暗底页面上会弹出一坨浅色、里面的暖白字几乎看不见 —— 实测截图抓到过。
	#   ⚠️ 这里**不含** `font_hover_color` / `font_focus_color`：那两档要更亮（见下面）。
	for slot in ["font_accelerator_color", "font_disabled_color", "font_separator_color"]:
		popup.add_theme_color_override(slot, text_color)
	popup.add_theme_stylebox_override("panel", popup_panel)
	# ★ 留一份「原样的底板」：淡入淡出时从它复制（见 `_apply_panel_alpha`）——
	#   直接用传进来的那一份会被改掉（那是调用方 `menu_theme` 的静态对象，
	#   改它等于把全项目的下拉列表都改了）。
	_panel_base = popup_panel
	_alpha = 1.0
	popup.add_theme_stylebox_override("hover", row_hover)
	# ★ 鼠标停在某一项上时，那行字也要**更亮**：列表是独立窗口里的一行字，
	#   没有别的东西帮它强调「鼠标在这儿」（只靠底纹的话，深色底上反馈偏弱）。
	#   判据仍是**有对比**：刻意用 `accent_bright`（同一支金的最亮档），不是换一种色。
	popup.add_theme_color_override("font_hover_color", ThemeRes.accent_bright())
	popup.add_theme_color_override("font_focus_color", ThemeRes.accent_bright())
	# ★ 让列表**跟着按钮走**：点了按钮就把列表贴在按钮下边缘弹出来。
	#   不自己算坐标，是因为按钮的位置由 CenterContainer / VBoxContainer 排版决定，
	#   在 build 的那一刻还不知道最终落在哪。
	popup.id_pressed.connect(_on_item_pressed)
	# ★★ 缓动展开 / 收缩的接线（见上面那一节注释）：
	#   · `popup_hide` 是「引擎把它藏起来了」的通知（点空白处失焦、按 Esc 都会发）——
	#     我们在这一帧把它重新显示出来播收缩动画，观感就是「缓动收缩」；
	#   · `close_requested` 是引擎更明确的「请求关闭」（例如选中一项之后）。
	#     ⚠️ 它有时候会和 `popup_hide` 一起发，所以两条路都走 `collapse()`，
	#        由里面的 `_closing` 挡重入。
	popup.popup_hide.connect(_on_popup_hide)
	popup.close_requested.connect(collapse)
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


## ★★ 列表底板当前的**不透明度**（0 = 全透明，1 = 完全不透明）。
##
## ★ 为什么要暴露它：`PopupMenu` 是 `Window`，**没有** `modulate` 这类属性
##   （实测报 Invalid assignment），所以「渐入渐出」只能改底板 StyleBox 的 alpha
##   （见 `_set_panel_alpha`）。测试要看「确实在淡」，只能从这里读。
func panel_alpha() -> float:
	return _alpha


## 按钮上那行字（供测试与排查用；正常情况下它就是当前选项的文字）
func text() -> String:
	return "" if button == null else button.text


## 点按钮：开着就收起来，关着就弹出来（开关式，与设置菜单同一个手感）。
##
## ★ 两条路都走**补间**：展开 `expand()`、收缩 `collapse()`（见文件里那一节注释）。
func toggle() -> void:
	if popup == null or button == null or button.disabled or _names.is_empty():
		return
	if popup.visible or _closing:
		collapse()
		return
	expand()


## ★★ 缓动展开：把列表贴在按钮**下沿**，从**很薄**长到全高（上沿不动）+ 淡入。
##
## ★ 位置与宽度都在 `popup()` **之前**定好（理由见下面那段注释）。
## ★ 幂等：已经开着就直接返回（重复调不会叠两条补间）。
func expand() -> void:
	if popup == null or button == null or popup.visible:
		return
	_closing = false
	popup.reset_size()
	# ★★ 位置与宽度都在显示**之前**定好。
	#   ⚠️ 顺序要紧：`popup()` / `show()` 会让引擎按内容重算窗口尺寸，
	#      先显示再设会看到一帧「比按钮窄一大截」的补丁宽度（实测踩过）。
	#   宽度要**两处都设**（`min_size` 抬下限 + `size` 立刻生效）：
	#      ⚠️ PopupMenu 是 Window，**没有** `custom_minimum_size` 那个 Control 属性。
	var want_w := maxi(int(button.size.x), int(popup.get_contents_minimum_size().x))
	popup.min_size = Vector2i(want_w, 0)
	popup.size.x = want_w
	# ★ 终点：窗口上沿 = 按钮**下沿**（内嵌之后这是视口坐标，与按钮同一套）
	var to_pos := Vector2i(
		int(button.global_position.x), int(button.global_position.y + button.size.y))
	# ★★ 起点：从**稍微靠上**一点开始（只偏 `POPUP_OPEN_RISE` 像素）。
	#   为什么不是「整块上移一个窗口高」：那样列表会先整块出现在选项条上方
	#   （盖住选项条），观感是「从上面掉下来」。偏一点点 + 同时淡入，
	#   才是「从选项条背后滑出来」那一下。
	#
	#   ⚠️⚠️ 试过但**做不到**的两件事（别再来回试）：
	#     ① `Window`（含 PopupMenu）**没有** `z_index` —— 写上去直接报 Invalid assignment。
	#        所以「让列表真的画在选项条那一层**下面**」在引擎这一侧办不到；
	#        能做的只有「动起来像从那里出来」（起点偏移 + 淡入）。
	#     ② **高度动不了**：窗口高度被内容最小高夹住（实测设 8 立刻变回 86），
	#        所以「像抽屉一样从薄到厚长出来」也做不到 —— 只有 `content_scale`
	#        能把内容压扁，那会把文字一起压变形，观感更差。
	var from_pos := Vector2i(to_pos.x, to_pos.y - POPUP_OPEN_RISE)
	popup.position = from_pos
	# ★ 先淡到全透明（改的是底板 StyleBox 的 alpha，见 `_set_panel_alpha`），
	#   再显示 —— 否则会有一帧是完整大小、完全不透明的闪烁。
	_alpha = 0.0
	_apply_panel_alpha()
	popup.popup()
	# ★★ 显示之后必须**再把 min_size.y 放开一次**：`popup()` 会按内容把它顶回去。
	popup.min_size = Vector2i(want_w, 0)
	popup.position = from_pos

	_kill_tween()
	# ★★ 补间挂在**宿主界面节点**上，不是挂在 popup 上 —— 见 `_tween_host()` 的说明。
	_tween = _tween_host().create_tween()
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(popup, "position", to_pos, POPUP_OPEN_TIME)
	_tween.tween_method(_set_panel_alpha, 0.0, 1.0, POPUP_OPEN_TIME)


## ★★ 缓动收缩：滑回选项条下沿 + 淡出，**跑完才真正隐藏**。
##
## ⚠️ 不能直接 `popup.hide()`：那是瞬发的，玩家看不到任何过渡（需求要的就是过渡）。
## ⚠️ `_closing` 挡住重入：引擎的 `popup_hide` / `close_requested` 可能在同一帧都来。
func collapse() -> void:
	# ⚠️ 这里**不能**要求 `popup.visible`：`_on_popup_hide` 那条路进来时引擎刚把它藏了，
	#   而 `show()` 之后 `visible` 未必已同步 —— 卡在这条判据上会让收缩整个失效。
	if popup == null or _closing:
		return
	_closing = true
	_kill_tween()
	var to_pos := Vector2i(
		int(button.global_position.x), int(button.global_position.y + button.size.y))
	# ★ 同一条路的反向：往上收 `POPUP_OPEN_RISE` 像素 + 淡出。
	var from_pos := Vector2i(to_pos.x, to_pos.y - POPUP_OPEN_RISE)
	popup.position = to_pos
	_tween = _tween_host().create_tween()
	_tween.set_parallel(true)
	_tween.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(popup, "position", from_pos, POPUP_CLOSE_TIME)
	_tween.tween_method(_set_panel_alpha, _alpha, 0.0, POPUP_CLOSE_TIME)
	# ★ 收尾：把 `set_parallel(false)` 打开、再排一步 0 秒的「等一帧」，
	#   然后 `tween_callback` —— 这样回调**在上一段补间之后**才跑。
	#   ⚠️ 不能在同一条并行补间上直接挂 `finished`：实测那个回调会在
	#      **创建补间的那一帧**就触发（表现为收缩动画一帧都没播、窗口直接隐藏、
	#      位置却已经跳到终点），正是用户报的「点空白处不缓动」。
	_tween.set_parallel(false)
	_tween.tween_interval(0.001)
	_tween.tween_callback(_finish_collapse)


## ★★ 补间挂在**谁**身上。
##
## 本类（`map_select.gd`）是 `RefCounted`，**不是 Node** —— 所以不能拿 `self` 当宿主。
## 用**按钮**：它一直在场景树里，补间按帧推进。
##
## ⚠️⚠️ 绝不能挂 `popup.create_tween()`（挂到 PopupMenu 这个 Window 自己身上）：
##   它是个**独立窗口**，被 `hide()` 之后就不在「处理中」了 —— 收缩动画挂在它身上
##   会**当场结束**（实测：`finished` 在同一个信号回调里就发了，窗口位置直接跳到终点、
##   连一帧过渡都没有 —— 正是用户报的「点空白处不缓动」）。
func _tween_host() -> Node:
	if button != null and is_instance_valid(button):
		return button
	if _host != null and is_instance_valid(_host):
		return _host
	return null


func _finish_collapse() -> void:
	_closing = false
	_chose_item = false
	if popup != null:
		# ★ 这一下是我们自己关的（不是玩家点空白处）：打标后同步隐藏 ——
		#   `hide()` 会**同步**抛 `popup_hide`，那个回调要靠这个标认出来。
		_hiding_self = true
		popup.hide()
		_hiding_self = false
		# ★ 还原成不透明：下一次展开要从干净状态开始（展开时也会再置一次，双保险）。
		_alpha = 1.0
		_apply_panel_alpha()


## ★★ 展开 / 收缩的「淡入淡出」。
##
## ⚠️⚠️ `PopupMenu` 是 **Window**：它**没有** `modulate` / `opacity` 这类属性
##   （实测报 "Invalid assignment of property 'modulate'"）。所以淡入淡出只能
##   改**列表底板那块 StyleBox 的 alpha** —— 每帧新建一个 StyleBoxFlat 顶上
##   （只在 0.16 秒的动画里发生，代价可以忽略）。
##
## @param a  0 = 全透明，1 = 不透明
func _set_panel_alpha(a: float) -> void:
	_alpha = clampf(a, 0.0, 1.0)
	_apply_panel_alpha()


func _apply_panel_alpha() -> void:
	if popup == null or _panel_base == null:
		return
	var sb: StyleBoxFlat = _panel_base.duplicate() as StyleBoxFlat
	if sb == null:
		return
	sb.bg_color = Color(sb.bg_color.r, sb.bg_color.g, sb.bg_color.b,
		sb.bg_color.a * _alpha)
	sb.border_color = Color(sb.border_color.r, sb.border_color.g, sb.border_color.b,
		sb.border_color.a * _alpha)
	# ⚠️ 用**局部**的 key（第三个参数 false = 不设成「项目级」主题覆盖）：
	#   设成全局会把这份临时 StyleBox 挂到整个项目上，越滚越多。
	popup.add_theme_stylebox_override("panel", sb)


## ★★ 「引擎要把它关掉」那一下（点空白处失焦、按 Esc、选中一项都会发 `popup_hide`）。
##
## ⚠️⚠️ `popup_hide` **不代表窗口此刻已经不可见**：实测它有时在窗口还 visible 的时候就发。
##   所以这里**必须先看 `visible` 再决定要不要 `show()`** —— 无条件 `show()` 会撞上
##   引擎的 "Can't make active a Viewport that is already active"（用户报的那条报错）。
##   · 已经不可见 → 它本来就在收，交给 `collapse()`（`visible=false` 时它会自己跳过）；
##   · 还可见      → 直接播收缩动画即可（视觉上就是「从原地缓动收掉」）。
func _on_popup_hide() -> void:
	if _hiding_self:
		# 我们自己收的那一下（见 `_finish_collapse`）—— 别再动它。
		return
	if _closing or popup == null:
		return
	if _chose_item:
		# 选中一项：直接收掉，不重播、不重新显示。
		_chose_item = false
		_alpha = 1.0
		_apply_panel_alpha()
		return
	if not popup.visible:
		# 引擎已经把它藏了：这一下没法播动画了，保持关闭状态即可。
		#   ⚠️ 不能 `show()` 回来 —— 那正是上面那条引擎报错的来源。
		return
	collapse()


## 补间没跑完就被新的一条顶掉是常事（手快连点）—— 先杀掉旧的，
## 否则两条补间同时改同一个窗口，屏幕上就是一串抖动。
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


func _on_item_pressed(id: int) -> void:
	# ★ 先打标：引擎紧接着会 hide + 发 `popup_hide`，那一下不该再弹回来（见 `_on_popup_hide`）。
	_chose_item = true
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
