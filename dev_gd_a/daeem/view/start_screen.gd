## start_screen.gd —— 开场两页：入场页（白屏）→ 主界面
##
##   入场页：上方标题 DAEEM；屏幕下方「————点击任意处进入游戏————」，呼吸式渐显渐隐
##   主界面：屏幕正中的 test 按钮（点它进当前测试用的游戏内场景）
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
extends CanvasLayer

const ConfigRes = preload("res://logic/config.gd")

## 入场页被点掉了（main.gd 只需知道这件事，不必知道点的哪个像素）
signal intro_dismissed
## 主界面上的 test 按钮被按了 —— 该进游戏了
signal test_pressed

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
var _test_button: Button = null
var _blink_tween: Tween = null


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
	_build_menu()

	show_page(PAGE_INTRO)


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func show_page(page: int) -> void:
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
	# 整页居中：主界面本轮没有别的 UI，只有正中一个 test 按钮
	_menu = CenterContainer.new()
	_menu.name = "MainMenu"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)

	_test_button = Button.new()
	_test_button.name = "TestButton"
	_test_button.text = cfg.str_val("menu.test_button_text", "test")
	_test_button.custom_minimum_size = Vector2(
		cfg.num("menu.test_button_width", 240.0),
		cfg.num("menu.test_button_height", 80.0)
	)
	if _font != null:
		_test_button.add_theme_font_override("font", _font)
	_test_button.add_theme_font_size_override("font_size", int(cfg.num("menu.test_button_size", 28.0)))
	_test_button.add_theme_color_override("font_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	_test_button.add_theme_color_override("font_hover_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	_test_button.add_theme_color_override("font_pressed_color", _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2)))
	_test_button.add_theme_stylebox_override("normal", _button_style(Color.WHITE))
	_test_button.add_theme_stylebox_override("hover", _button_style(Color(0.94, 0.94, 0.94)))
	_test_button.add_theme_stylebox_override("pressed", _button_style(Color(0.88, 0.88, 0.88)))
	# focus 也用白底：白底按钮上再叠一层引擎默认的蓝色焦点框会很难看
	_test_button.add_theme_stylebox_override("focus", _button_style(Color.WHITE))
	_test_button.pressed.connect(_on_test_pressed)
	_menu.add_child(_test_button)


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


func _button_style(fill: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2))
	s.set_border_width_all(2)
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
	test_pressed.emit()
