## start_screen.gd —— 开场两页：入场页（白屏）→ 主界面
##
##   入场页：上方标题 DAEEM；屏幕下方「————点击任意处进入游戏————」，呼吸式渐显渐隐
##   主界面：屏幕正中一条**地图选择条** + 它下面的 test 按钮（点它进游戏）
##
## ★★ 地图选择条的选项**不是配出来的、也不是代码里写死的清单**：
##    `logic/map_library.gd` 扫描 `data/maps/` 下每个目录里的地图 JSON，
##    有几张图就有几个选项（地图 json 里的 `name` 当显示名，没写就用目录名；
##    写了 `placeholder: true` 的占位图照样列出，但不会被选成默认图）。
##    所以「以后加一张新图」= 往 data/maps/ 下放个新目录 —— 这个文件一个字都不用动。
##
## ★ 为什么单开一个文件而不是塞进 main.gd：
##   这两页在游戏**开始之前**，生命周期与游戏内场景完全不同（那时 world 还是 null），
##   混在一起会让 main.gd 里到处都是 `if 还在菜单里` 的分支 —— 那正是最容易长出陈年 bug 的写法。
##   ★ 但主循环仍然只有一处：这里没有 _process，只有输入、信号与一条 Tween。
##
## ★ 全部用代码搭 Control 树、不建 .tscn（与 hud.gd 同一个理由）：
##   纯文本、可 diff、无头测试能直接实例化检查；代价是不能在编辑器里可视化调布局。
## ★ 白底是刻意的：这两页不是游戏内 HUD，所以**不**走 ui_style.gd 的深色半透明。
##   文案 / 配色 / 字号 / 位置 / 呼吸节奏全在 data/config.json 的 menu 段里，代码不写文案字面量。
##
## 点击是怎么被收到的（★ 这里踩过一次坑，别再改回去）：
##   整页铺一个 mouse_filter = STOP 的 ColorRect（Background），`gui_input` **接在它身上**。
##   ⚠️ 第一版把处理器接在父节点 StartRoot 上，结果**点不动**：Godot 的 GUI 命中测试只把事件
##      交给鼠标下**最上层**的那个 Control，而 Background 是后 add_child 的、盖在父节点之上，
##      事件到它那里就停了，父节点的 gui_input 永远不会被调用（父节点不是「上一层」）。
##      所以：收事件的那一个节点，必须就是鼠标下最上层的那一个。
##   标题与提示 Label 一律 IGNORE，否则点在字上会被文字吃掉、点不进游戏。
##   CanvasLayer 用 layer = 100，只是保证它画在游戏画面（Hud 那层用的是默认的 1）之上。
##
## ⚠️ 地图选择条（OptionButton）自己**要**吃鼠标（STOP 是它的默认值）：
##   它是主界面上唯一需要「点开、选一项」的控件 —— 一建好就默认选中
##   `logic/map_library.gd` 给的默认地图，所以「不选就按 test」进的那张与按钮上显示的一致。
extends CanvasLayer

const ConfigRes = preload("res://logic/config.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const MapSelectRes = preload("res://view/map_select.gd")

## 入场页被点掉了（main.gd 只需知道这件事，不必知道点的哪个像素）
signal intro_dismissed
## 主界面上的 test 按钮被按了 —— 该进游戏了
## ★ 参数是**玩家选中的地图**：谁建世界（main.gd）谁就该知道建哪一张，
##   而不是自己去猜一个默认值 —— 否则选择条选了第二张图，进去的还是第一张。
signal test_pressed(map_path: String)

const PAGE_INTRO := 0
const PAGE_MENU := 1

## 提示文案呼吸一次（暗 → 亮）的时长（秒）。★ 这是**动画节奏**，不是玩法数值，
## 与 ui_style.gd 的字号常量同一性质，所以留在 view/ 层而不进 config.json。
const BLINK_PHASE_SEC := 1.2

var cfg: ConfigRes = null

var _page: int = PAGE_INTRO
var _font: Font = null

var _root: Control = null
var _bg: ColorRect = null
var _intro: Control = null
var _menu: Control = null
var _title: Label = null
var _click_hint: Label = null
var _map_label: Label = null
## ★ 地图选择条（`view/map_select.gd`：自己画的按钮 + 自己的列表，**不是** OptionButton）
var _map_select = null
var _test_button: Button = null
var _blink_tween: Tween = null

## 选择条当前的选项表（`logic/map_library.gd` 扫出来的），与控件上的顺序一一对应。
## ★ 留一份是为了让 `selected_map_path()` 有**唯一的真相**：选项下标 → 地图路径
##   只在这张表里查，不去反解 OptionButton 上的文字（文字是显示名，可能重复）。
var _maps: Array = []



func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font

	layer = 100
	# ⚠️ StartRoot 自己不收鼠标（IGNORE）：负责收点击的是盖在它上面的 Background，
	#    见文件头那条踩坑记录。这里写 STOP 只会让人误以为「接在根上就行」。
	_root = Control.new()
	_root.name = "StartRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_build_background()
	_build_intro()
	# ★ 先扫地图目录、再搭主界面：选择条的选项就是在 _build_menu 里建出来的。
	#   顺序反过来的话，主界面会先长成「一个选项都没有」的样子，
	#   而那张空列表一旦被建出来就得再刷一次 —— 不如一开始就有数据。
	_maps = MapLibraryRes.list_maps()
	_build_menu()

	show_page(PAGE_INTRO)


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func show_page(page: int) -> void:
	# ⚠️ 这两句不是摆设：CanvasLayer 被 hide() 过（`close()` 走过一次）之后，
	#    **光调本函数不会让它重新显示** —— 页内两层的 visible 都对了、整层却还是隐的，
	#    表现就是「回到菜单了，主界面看得见，但按钮点不动」。详见 `open_menu()`。
	show()
	_page = page
	_intro.visible = (page == PAGE_INTRO)
	_menu.visible = (page == PAGE_MENU)
	if page == PAGE_INTRO:
		start_click_blink()
	else:
		_stop_click_blink()
		# ★ 把透明度放回「不透明」：Tween 被 kill 时会停在那一瞬间的中间值上，
		#   不还原的话这行字会以半透明状态留在那儿 —— 以后拿它当别的文案用就会莫名其妙发灰。
		if _click_hint != null:
			_click_hint.modulate.a = 1.0


func page() -> int:
	return _page


## 进了游戏之后整页收起来。★ 必须是 hide() 而不是只把两个子节点设成不可见：
##   hide() 会让 CanvasLayer 的子节点**连输入带 _process 一起停掉**，
##   白色背景与「点击任意处」的处理器就此彻底下线，游戏里的鼠标事件不会再被这层吃掉。
func close() -> void:
	_stop_click_blink()
	hide()


## ★★ 回到**主界面**（游戏内「设置 → 返回主菜单」走这里）。
##
## 与 `show_page(PAGE_MENU)` 的区别只有一处，但那一处很关键：**它带 `show()`**。
##
## ⚠️ 为什么需要单独一个方法（实测踩到的）：`close()` 里那次 `hide()` 之后，
##    CanvasLayer 整层是隐藏的；而 `show_page()` 只管**页内那两层**（Intro / MainMenu），
##    不会碰整层的可见性。于是「回到菜单」之后：主界面看上去是对的（因为它在隐藏层里），
##    但**鼠标点不到任何东西** —— 白底与主界面都不参与命中测试，test 按钮形同虚设。
##    表现就是「退不回菜单，游戏卡在那一页」。
##    把 `show()` 收进这个语义明确的方法里，而不是散在调用点：
##    凡是「从游戏里回到菜单」都必须走它，@see view/main.gd 的 return_to_menu()。
func open_menu() -> void:
	show()
	show_page(PAGE_MENU)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 整页白底。mouse_filter = STOP 是「点击任意处」能成立的关键。
func _build_background() -> void:
	_bg = ColorRect.new()
	_bg.name = "Background"
	_bg.color = _menu_color("menu.bg", Color.WHITE)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.gui_input.connect(_on_page_gui_input)
	_root.add_child(_bg)


func _build_intro() -> void:
	_intro = Control.new()
	_intro.name = "Intro"
	_intro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_intro)

	# 标题：锚在上边，水平居中（窗口比例一变仍然贴着上边，不会被拉歪）
	_title = _make_label(
		cfg.str_val("menu.title", "DAEEM"),
		int(cfg.num("menu.title_size", 128.0)),
		_menu_color("menu.title_color", Color(0.1, 0.1, 0.1))
	)
	_title.name = "Title"
	_title.anchor_left = 0.0
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = cfg.num("menu.title_top", 200.0)
	_intro.add_child(_title)

	# 提示：锚在**下边**（需求要它在屏幕下方）。
	# ⚠️ 这里踩过一次坑（第一版把提示画到了画面**之外**、完全看不见）：
	#    只写 anchor_bottom = 1.0、把 anchor_top 留在 0 时，控件的上下两条边**各自**算：
	#    y_top 仍是 0 + offset_top，y_bottom 才是屏高 + offset_bottom，
	#    于是 offset_bottom = -110 让底边跑到 1810 之外、文字整个掉出画面。
	#    正确做法是**上下锚都贴底**（anchor_top = anchor_bottom = 1.0），
	#    这时 offset_top 才是「底边距屏幕底多远」，文字在这个位置往**上**长。
	_click_hint = _make_label(
		cfg.str_val("menu.click_text", "————点击任意处进入游戏————"),
		int(cfg.num("menu.click_size", 32.0)),
		_menu_color("menu.click_color", Color(0.27, 0.27, 0.27))
	)
	_click_hint.name = "ClickHint"
	# ★ 横向也必须「左右都贴边」（anchor_left = 0 / anchor_right = 1 + offset 0）：
	#   两个横向锚都留在 0 的话，Label 只会占它最小宽度、贴在屏幕左边缘，
	#   里面的 horizontal_alignment = CENTER 就完全看不出效果（第一版就是这样偏在左边）。
	_click_hint.anchor_top = 1.0
	_click_hint.anchor_bottom = 1.0
	_click_hint.anchor_left = 0.0
	_click_hint.anchor_right = 1.0
	_click_hint.offset_left = 0.0
	_click_hint.offset_right = 0.0
	_click_hint.offset_top = -cfg.num("menu.click_bottom", 110.0)
	_click_hint.offset_bottom = _click_hint.offset_top
	_intro.add_child(_click_hint)


func _build_menu() -> void:
	# 整页居中：主界面本轮只有一个纵向列（地图选择条 + 它下面的 test 按钮）
	_menu = CenterContainer.new()
	_menu.name = "MainMenu"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)

	# ★ 用 VBoxContainer 而不是自己算 y 偏移：需求是「选择条在 test 按钮**上方**」——
	#   这是一条**相对**关系，自己写死两个绝对 y 的话，以后改按钮高度就会让它俩叠在一起。
	#   竖排容器 + 一个间距（menu.map_gap）表达的就是这条关系本身。
	# ★ 对齐方式（实测出来的，改布局前先读这三行）：
	#   VBoxContainer 里的控件默认横向**撑满容器宽度** —— 而容器的宽度由最宽的那个
	#   子控件决定（下拉框 `menu.map_select_width` = 320），所以 test 按钮会被拉到
	#   和选择条一样宽，两个方块看起来才是一组（按钮自己设的 240 只是**最小**宽度）。
	#   ALIGNMENT_CENTER 管的是**竖直**方向（整列在 CenterContainer 里居中）。
	var column := VBoxContainer.new()
	column.name = "MenuColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", cfg.int_val("menu.map_gap", 48))
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu.add_child(column)

	_build_map_row(column)
	_build_test_button(column)


## 地图选择条：一行「地图」标签 + 一个下拉选择框。
##
## ⚠️ 选项来自 `logic/map_library.gd` 扫描 `data/maps/` 的结果，**不写在这里**：
##    清单写进 view 层就等于「加一张图要改代码」，而那正是需求要避免的。
## ⚠️ 一张地图都扫不到时：把选择条禁用、显示 `menu.map_select_empty_text`。
##    这时 test 按钮仍然可用（`selected_map_path()` 会给兜底路径）——
##    菜单不该因为「地图目录空了」而整个点不动，至少还能进游戏看到报错。
##
## ★★ 选择条本身是 `view/map_select.gd`（**自己画的按钮 + 自己的列表**），
##    不是引擎的 `OptionButton` —— 换掉的理由写在那份文件头上（一句话：
##    点开列表之后按钮上那行字会变空白，那是 OptionButton 内部 / 原生列表窗口的毛病）。
func _build_map_row(column: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "MapRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	column.add_child(row)

	_map_label = _make_label(
		cfg.str_val("menu.map_select_label", "地图"),
		cfg.int_val("menu.map_select_label_size", 28),
		_menu_color("menu.map_select_label_color", Color(0.2, 0.2, 0.2))
	)
	_map_label.name = "MapLabel"
	row.add_child(_map_label)

	# 白底 + 与 test 按钮同一个边框色：这两页是白底页面，引擎默认的深色下拉框会很突兀
	var border := _menu_color("menu.map_select_border_color", Color(0.2, 0.2, 0.2))
	var border_w := cfg.int_val("menu.map_select_border_width", 2)
	_map_select = MapSelectRes.new()
	_map_select.build(row, _font, cfg.int_val("menu.map_select_size", 26),
		_menu_color("menu.map_select_color", Color(0.2, 0.2, 0.2)),
		_button_style(Color.WHITE, border, border_w),
		_button_style(Color(0.94, 0.94, 0.94), border, border_w),
		_button_style(Color(0.88, 0.88, 0.88), border, border_w),
		_button_style(Color.WHITE, border, border_w),
		# ★ 下拉列表那块底板：白底 + 同一条边框（引擎默认的深色会让白底页面上的
		#   选项几乎读不出来 —— 实测截图抓到的第二个毛病）
		_button_style(Color.WHITE, border, border_w),
		_button_style(Color(0.94, 0.94, 0.94), border, 0),
		Vector2(cfg.num("menu.map_select_width", 320.0),
			cfg.num("menu.map_select_height", 56.0)))
	_map_select.item_selected.connect(_on_map_selected)

	_refresh_map_options()


## 把 `_maps` 铺进选择条。
##
## ★ 抽成一个函数（而不是在 _build_map_row 里就地铺）：这样「重新扫一遍目录」只需要
##   调它一次 —— 测试与以后可能的「刷新」按钮都走同一条路，不会漂成两份实现。
func _refresh_map_options() -> void:
	if _map_select == null:
		return
	if _maps.is_empty():
		_map_select.set_items([cfg.str_val("menu.map_select_empty_text", "没有可用地图")])
		_map_select.select(0)
		_map_select.set_disabled(true)
		return
	_map_select.set_disabled(false)
	var names: Array = []
	for item in _maps:
		names.append(String((item as Dictionary)["name"]))
	_map_select.set_items(names)
	# ★ 默认选中**默认地图**那一项（`default_map_path()`：跳过占位图的第一张正式图）。
	#   为什么要跟它对齐、而不是无脑选第 0 项：需求只要求「可以选」，但
	#   「什么都不选直接按 test」必须有一个**与按钮上显示的一致**的结果 ——
	#   选择条上高亮着 arena、按下去却进了 frontier 的话，玩家会说「选择条没用」。
	#   找不到（理论上不会）→ 退回第 0 项。
	var default_path := String(MapLibraryRes.default_map_path())
	var index := 0
	for i in _maps.size():
		if String((_maps[i] as Dictionary)["path"]) == default_path:
			index = i
			break
	_map_select.select(index)


func _build_test_button(column: VBoxContainer) -> void:
	_test_button = Button.new()
	_test_button.name = "TestButton"
	_test_button.text = cfg.str_val("menu.test_button_text", "test")
	_test_button.custom_minimum_size = Vector2(
		cfg.num("menu.test_button_width", 240.0),
		cfg.num("menu.test_button_height", 80.0)
	)
	if _font != null:
		_test_button.add_theme_font_override("font", _font)
	_test_button.add_theme_font_size_override("font_size", cfg.int_val("menu.test_button_size", 28))
	_test_button.add_theme_color_override("font_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	_test_button.add_theme_color_override("font_hover_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	_test_button.add_theme_color_override("font_pressed_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	# ★ 两个控件用同一个边框（同一条配色），视觉上才是「一组」而不是两个巧合撞在一起的方块
	var border := _menu_color("menu.map_select_border_color", Color(0.2, 0.2, 0.2))
	var border_w := cfg.int_val("menu.map_select_border_width", 2)
	_test_button.add_theme_stylebox_override("normal", _button_style(Color.WHITE, border, border_w))
	_test_button.add_theme_stylebox_override("hover", _button_style(Color(0.94, 0.94, 0.94), border, border_w))
	_test_button.add_theme_stylebox_override("pressed", _button_style(Color(0.88, 0.88, 0.88), border, border_w))
	# focus 也用白底：白底按钮上再叠一层引擎默认的蓝色焦点框会很难看
	_test_button.add_theme_stylebox_override("focus", _button_style(Color.WHITE, border, border_w))
	_test_button.pressed.connect(_on_test_pressed)
	column.add_child(_test_button)



func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ★ 文字不吃鼠标：否则点在标题 / 提示那几个字上会被 Label 吃掉，
	#   而「点击任意处」恰恰要求点在字上也算数。
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## 白底控件用的边框样式。
##
## ★ 边框色/宽度是**参数**而不是从 config 里就地读：下拉框与 test 按钮必须用同一个值
##   （它们是视觉上的一组），调用方各读一次就会漂成两个数。
func _button_style(fill: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(maxi(0, border_width))
	# 内边距：不然文字会紧贴边框（按钮倒还好，下拉框上的字会顶到左上角）
	s.content_margin_left = 12.0
	s.content_margin_right = 12.0
	return s


## 取 menu.* 下的颜色。★ 用 Config.parse_color 那条路（解析 "#rrggbb" / "rgba(...)"），
##   而不是自己读字符串再 Color() —— 配色写法与全项目保持一致。
func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback


# ------------------------------------------------------------------
# 提示文案的呼吸（渐显渐隐）
# ------------------------------------------------------------------

## 让下方提示「————点击任意处进入游戏————」一直呼吸。
##
## ★ 用 Tween 而不是 `_process`：一条循环 Tween 就够了，而且**暂停时它也会跟着停**
##   （Tween 绑在节点上，节点不处理时就冻结），不必自己算时间。
## ★ 动的是 `modulate:a` 而不是 `visible`：渐隐渐显要的是透明度连续变化，
##   切 visible 只会得到「一闪一闪」。暗端也不设 0（留 alpha_min），否则文字会整个消失。
func start_click_blink() -> void:
	if _click_hint == null:
		return
	_stop_click_blink()

	var lo := clampf(cfg.num("menu.click_alpha_min", 0.15), 0.0, 1.0)
	var hi := clampf(cfg.num("menu.click_alpha_max", 1.0), 0.0, 1.0)
	if hi < lo:
		var tmp := lo
		lo = hi
		hi = tmp

	# ★ 必须从暗端起步：先设成暗，再让 loop 把「暗→亮→暗」跑起来，
	#   否则第一轮会从当前值（亮）开始，看起来像闪了一下才进入节奏。
	_click_hint.modulate.a = lo
	_blink_tween = create_tween().set_loops()
	_blink_tween.tween_property(_click_hint, "modulate:a", hi, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_blink_tween.tween_property(_click_hint, "modulate:a", lo, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_click_blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_blink_tween = null


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

## ★ 接的是 Background（鼠标下最上层的那一个），不是父节点 StartRoot —— 见文件头的踩坑记录。
func _on_page_gui_input(event: InputEvent) -> void:
	if _page != PAGE_INTRO:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		dismiss_intro()


## 入场页 → 主界面。★ 判定与动作分开写，是为了让测试能直接调这个函数
##   模拟「玩家点了一下」，而**不必知道**判定写在 gui_input 的哪个条件里
##   （把判定抄进测试等于测了另一份实现）。
## ⚠️ 但这**不能**代替「点击真的能到达处理器」那条验证：
##   第一版就是处理器接错了节点，而这个函数单独调照样通过，
##   于是测试全绿、游戏里点不动。接线本身必须另外测（见 tests/test_start_flow.gd）。
## @return bool 这一次点击是否真的生效（已经在主界面 / 非左键时为 false）
func dismiss_intro() -> bool:
	if _page != PAGE_INTRO:
		return false
	show_page(PAGE_MENU)
	intro_dismissed.emit()
	return true


func _on_test_pressed() -> void:
	# ★ 按钮只该生效一次：进了游戏之后这一层就隐藏了，正常路径上按不到第二次；
	#   这里再挡一道，是为了让「连点两下」永远不会造出第二个世界。
	if not visible:
		return
	test_pressed.emit(selected_map_path())


## 选择条换了一项。★ 不预载地图、也不建世界：
##   选一张图只是「待会儿按 test 时进哪张」，现在载入等于把一张没人玩的地图读进内存。
## ★ 按钮上那行字**不用在这里管**：`view/map_select.gd` 在它自己那边每次选中都会
##   把文字重新写进按钮（那正是那个类存在的理由 —— 见它的文件头）。
func _on_map_selected(_index: int) -> void:
	pass


# ------------------------------------------------------------------
# 对外状态：选中的地图
# ------------------------------------------------------------------

## 玩家当前选中的地图路径 —— ★ `test_pressed` 带出去的就是它，也是**选择条唯一的作用**。
##
## ★ 兜底规则（两种都不该让主界面点不动）：
##   · 选择条还没选过 / 选中项越界 → `MapLibraryRes.default_map_path()`
##     （正常路径上选不中这种情况不会发生：`_refresh_map_options` 一建好就选中了它）；
##   · 一张图都扫不到（`_maps` 为空）→ 同上，而它自己还会退到 `FALLBACK_MAP_PATH`
##     —— 与选择条上显示的「没有可用地图」一致：按下去会进那张兜底图，
##     载入失败的话 main.gd 会把半成品撤掉、留在菜单上。
func selected_map_path() -> String:
	var index := 0
	if _map_select != null and _map_select.selected >= 0:
		index = _map_select.selected
	if index >= 0 and index < _maps.size():
		return String((_maps[index] as Dictionary)["path"])
	return String(MapLibraryRes.default_map_path())


## 地图选项表（`logic/map_library.gd` 扫出来的那份）。
## ★ 给测试看一眼「选项是不是真的来自目录扫描」，而不是主界面自己编的清单。
func map_options() -> Array:
	return _maps


## 地图选择条那行控件本身（`view/map_select.gd` 造的按钮）—— 给测试量几何 / 点它用。
##
## ⚠️ 它**不能**再用节点路径找（`.../MapRow/MapSelect`）：选择条不是一个 Control 节点了，
##    按钮是 `view/map_select.gd` 内部持有的东西（它自己管文字与列表）。
##    要拿它就问这里 —— 这也是这套拆分的代价与好处：层次变清楚了，路径不再稳定。
func map_select_button() -> Button:
	return _map_select.button if _map_select != null else null


## 选择条上有几项 / 第 i 项叫什么 / 现在选的是第几项 —— **只给测试与排查用**。
## ★ 选择条内部是什么实现（`view/map_select.gd`）不该泄漏出去，所以这里转一层，
##   而不是把 `_map_select` 直接公开出去。
func map_select_item_count() -> int:
	return _map_select.item_count() if _map_select != null else 0


func map_select_item_text(index: int) -> String:
	return _map_select.get_item_text(index) if _map_select != null else ""


func map_select_selected() -> int:
	return _map_select.selected if _map_select != null else -1


## 让选择条选中第 index 项（等价于玩家选了它，但**不发** item_selected ——
## 与 OptionButton.select() 的语义一致）。
func map_select_select(index: int) -> void:
	if _map_select != null:
		_map_select.select(index)

