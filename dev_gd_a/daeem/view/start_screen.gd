## start_screen.gd —— 开场两页：入场页 → 主界面
##
##   入场页：上方**几何徽记 + 带字距的标题 DAEEM + 金色分隔线**；
##           屏幕下方「————点击任意处进入游戏————」，淡入之后呼吸式渐显渐隐
##   主界面：屏幕正中一条**地图选择条** + 它下面两颗按钮（test / campaign_test）
##
## ★★ 配色与风格（本轮改版：参考图的「暗色渐变底 + 金色细线边框 + 纯几何形状」）：
##   · 底：`view/menu_background.gd`（竖直渐变 + 中心辉光 + 上下金线），**不再有白底**；
##   · 控件：`view/menu_theme.gd`（透明底 + 1px 金线；选定态才是实心金）；
##   · 图形：`view/menu_emblem.gd`（纯 `_draw()` 的几何徽记，零贴图）；
##   · 文字：Label + `view/text_marks.gd` 的两个自绘控件（带字距的标题、金线）。
##   ★ 配色一个都不在本文件里写死：全部来自 `data/config.json` 的 `theme.palette`
##     （经 view/theme.gd）。文案 / 字号 / 位置仍然全部来自 `menu` 段 —— 代码里不写文案字面量。
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
##   ★ 但主循环仍然只有一处：这里没有 _process，只有输入、信号与两条 Tween。
##
## ★ 全部用代码搭 Control 树、不建 .tscn（与 hud.gd 同一个理由）：
##   纯文本、可 diff、无头测试能直接实例化检查；代价是不能在编辑器里可视化调布局。
##
## 点击是怎么被收到的（★ 这里踩过一次坑，别再改回去）：
##   整页铺一个 mouse_filter = STOP 的 `Background`（`view/menu_background.gd`，
##   它同时负责画渐变底），`gui_input` **接在它身上**。
##   ⚠️ 第一版把处理器接在父节点 StartRoot 上，结果**点不动**：Godot 的 GUI 命中测试只把事件
##      交给鼠标下**最上层**的那个 Control，而 Background 是后 add_child 的、盖在父节点之上，
##      事件到它那里就停了，父节点的 gui_input 永远不会被调用（父节点不是「上一层」）。
##      所以：收事件的那一个节点，必须就是鼠标下最上层的那一个。
##   标题与提示 Label 一律 IGNORE，否则点在字上会被文字吃掉、点不进游戏。
##   ★★ 于是本轮新加的东西也必须守这条：自绘控件（标题 / 徽记 / 金线 / 扫光）
##      全部 `mouse_filter = IGNORE`（在各自的文件里设死），
##      否则「点击任意处」会在那些**看不见的矩形**上失效 —— 这是本轮最容易踩的坑。
##   CanvasLayer 用 layer = 100，只是保证它画在游戏画面（Hud 那层用的是默认的 1）之上。
##
## ⚠️ 地图选择条（`view/map_select.gd`）自己**要**吃鼠标（STOP 是它的默认值）：
##   它是主界面上唯一需要「点开、选一项」的控件 —— 一建好就默认选中
##   `logic/map_library.gd` 给的默认地图，所以「不选就按 test」进的那张与按钮上显示的一致。
extends CanvasLayer

const ConfigRes = preload("res://logic/config.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const MapSelectRes = preload("res://view/map_select.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const MenuEmblemRes = preload("res://view/menu_emblem.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 入场页被点掉了（main.gd 只需知道这件事，不必知道点的哪个像素）
signal intro_dismissed
## 主界面上的 test 按钮被按了 —— 该进游戏了
## ★ 参数是**玩家选中的地图**：谁建世界（main.gd）谁就该知道建哪一张，
##   而不是自己去猜一个默认值 —— 否则选择条选了第二张图，进去的还是第一张。
signal test_pressed(map_path: String)

## ★ 玩家按下了 **campaign_test**（单人战役的占位界面，见 `view/campaign_test.gd`）。
##
## ★ 它**不带载荷**：这一页不认识战役数据 —— 谁去扫 `data/campaigns/`、谁去建世界，
##   都由 `view/main.gd` 决定。这正是它与 `test_pressed(map_path)` 的差别：
##   地图是**这一页自己选的**（选择条就住在这里），而战役不是。
signal campaign_test_pressed()

const PAGE_INTRO := 0
const PAGE_MENU := 1

## 提示文案呼吸一次（暗 → 亮）的时长（秒）。★ 这是**动画节奏**，不是玩法数值，
## 与 ui_style.gd 的字号常量同一性质，所以留在 view/ 层而不进 config.json。
const BLINK_PHASE_SEC := 1.2

## 入场页淡入之后、呼吸开始之前的停顿（秒）。★ 让「淡入」与「呼吸」在观感上分成两拍：
##   一边淡入一边呼吸的话，第一眼的印象是「这块字在抖」，而不是「它浮上来」。
const BLINK_START_DELAY := 0.26

## 扫光（参考图那种一道光掠过标题的打光）的时长与两次之间的间隔（秒）。
## ★ 只跑一次：它是**入场**的一部分，不是常驻装饰（常驻会让人一直分神）。
const SHINE_SEC := 1.15
const SHINE_DELAY_SEC := 0.55
## 扫光带的倾斜：0 = 竖直的带，> 0 时带子向右下斜（参考图的掠光是斜的）。
const SHINE_SKEW := 0.34

var cfg: ConfigRes = null

var _page: int = PAGE_INTRO
var _font: Font = null

var _root: Control = null
var _bg: Control = null
var _intro: Control = null
var _menu: Control = null
## ★ 带字距的标题（`view/text_marks.gd` 的 SpacedLabel，**不是** Label）——
##   节点名仍是 "Title"，测试与排查照旧走 `StartRoot/Intro/Title`。
var _title: Control = null
var _click_hint: Label = null
## ★ 选择条左边那个「地图」标签（测试按 `.../MapRowWrap/MapRow/MapLabel` 找它）
var _map_label: Label = null
## 扫光那一条（盖在标题上的同级兄弟；见 `_build_intro` 末尾）
var _shine: Control = null
## ★ 地图选择条（`view/map_select.gd`：自己画的按钮 + 自己的列表，**不是** OptionButton）
var _map_select = null
var _test_button: Button = null
## ★ 主界面第二颗按钮（**单人战役的占位入口**，用它进战役里手玩）。
## 它在 `_test_button` **下面**，间距是 `menu.campaign_test_button_gap`（比 map_gap 小）。
var _campaign_button: Button = null
var _blink_tween: Tween = null
var _shine_tween: Tween = null

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
		start_title_shine()
	else:
		_stop_click_blink()
		_stop_title_shine()
		# ★ 把透明度放回「不透明」：Tween 被 kill 时会停在那一瞬间的中间值上，
		#   不还原的话这行字会以半透明状态留在那儿 —— 以后拿它当别的文案用就会莫名其妙发灰。
		if _click_hint != null:
			_click_hint.modulate.a = 1.0
		# ★ 扫光只在入场页跑；切到主界面时把标题整块收掉 ——
		#   否则它会以「停在半路」的状态继续挂着（它是盖在标题上的一个可见矩形）。
		if _title != null:
			_title.modulate.a = 1.0
		if _shine != null:
			_shine.visible = false
			_shine.modulate.a = 0.0


func page() -> int:
	return _page


## 进了游戏之后整页收起来。★ 必须是 hide() 而不是只把两个子节点设成不可见：
##   hide() 会让 CanvasLayer 的子节点**连输入带 _process 一起停掉**，
##   背景与「点击任意处」的处理器就此彻底下线，游戏里的鼠标事件不会再被这层吃掉。
func close() -> void:
	_stop_click_blink()
	_stop_title_shine()
	hide()


## ★★ 回到**主界面**（游戏内「设置 → 返回主菜单」走这里）。
##
## 与 `show_page(PAGE_MENU)` 的区别只有一处，但那一处很关键：**它带 `show()`**。
##
## ⚠️ 为什么需要单独一个方法（实测踩到的）：`close()` 里那次 `hide()` 之后，
##    CanvasLayer 整层是隐藏的；而 `show_page()` 只管**页内那两层**（Intro / MainMenu），
##    不会碰整层的可见性。于是「回到菜单」之后：主界面看上去是对的（因为它在隐藏层里），
##    但**鼠标点不到任何东西** —— 背景与主界面都不参与命中测试，test 按钮形同虚设。
##    表现就是「退不回菜单，游戏卡在那一页」。
##    把 `show()` 收进这个语义明确的方法里，而不是散在调用点：
##    凡是「从游戏里回到菜单」都必须走它，@see view/main.gd 的 return_to_menu()。
func open_menu() -> void:
	show()
	show_page(PAGE_MENU)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 整页渐变底。★ 它同时是收点击的那一层（mouse_filter = STOP 在 menu_background.gd 里设死）。
## ⚠️ 节点名必须叫 "Background"：`view/main.gd` 的调试与两条测试都按这个名字找它，
##    而「鼠标下最上层是它」这件事靠的是**它铺满整页**，不是靠名字。
func _build_background() -> void:
	_bg = MenuBackgroundRes.new()
	_bg.name = "Background"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.gui_input.connect(_on_page_gui_input)
	_root.add_child(_bg)


func _build_intro() -> void:
	_intro = Control.new()
	_intro.name = "Intro"
	_intro.set_anchors_preset(Control.PRESET_FULL_RECT)
	_intro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_intro)

	# ---- 徽记：贴着标题上方，水平居中（纯几何自绘，见 menu_emblem.gd）----
	var emblem := MenuEmblemRes.new()
	emblem.name = "Emblem"
	var e_size := cfg.num("menu.emblem_size", 150.0)
	emblem.anchor_left = 0.0
	emblem.anchor_right = 1.0
	emblem.offset_left = 0.0
	emblem.offset_right = 0.0
	emblem.offset_top = cfg.num("menu.emblem_top", 66.0)
	emblem.offset_bottom = emblem.offset_top + e_size
	_intro.add_child(emblem)

	# ---- 标题：带字距 + 横向渐变（参考图那种「左白右金」的一排字）----
	# ★ 它是**自绘控件**（SpacedLabel）而不是 Label：Label 没有 letter-spacing。
	#   于是宽度要自己给（`menu.title_width`）—— 逐字推进算出来的总宽在这个宽度里居中，
	#   见 text_marks.gd `_draw()`。
	_title = TextMarksRes.SpacedLabel.new()
	_title.name = "Title"
	_title.text = cfg.str_val("menu.title", "DAEEM")
	_title.font = _font
	_title.font_size = int(cfg.num("menu.title_size", 128.0))
	_title.tracking = cfg.num("menu.title_tracking", 26.0)
	_title.color_from = _menu_color("menu.title_color", ThemeRes.text())
	_title.color_to = _menu_color("menu.title_gold_color", ThemeRes.accent())
	# 标题的宽度留得比字宽（`title_width`，默认 1160）：太窄会把两端的字挤掉。
	_title.anchor_left = 0.0
	_title.anchor_right = 1.0
	_title.offset_left = 0.0
	_title.offset_right = 0.0
	_title.offset_top = cfg.num("menu.title_top", 200.0)
	_title.offset_bottom = _title.offset_top + cfg.num("menu.title_height", 170.0)
	_intro.add_child(_title)

	# ---- 标题下面那条金色分隔线（参考图里标题上下的细线）----
	_build_rule(_intro, "TitleRule",
		cfg.num("menu.title_top", 200.0) + cfg.num("menu.title_height", 170.0)
			+ cfg.num("menu.title_rule_gap", 44.0))

	# ---- 提示：锚在**下边**（需求要它在屏幕下方）。----
	# ⚠️ 这里踩过一次坑（第一版把提示画到了画面**之外**、完全看不见）：
	#    只写 anchor_bottom = 1.0、把 anchor_top 留在 0 时，控件的上下两条边**各自**算：
	#    y_top 仍是 0 + offset_top，y_bottom 才是屏高 + offset_bottom，
	#    于是 offset_bottom = -110 让底边跑到 1810 之外、文字整个掉出画面。
	#    正确做法是**上下锚都贴底**（anchor_top = anchor_bottom = 1.0），
	#    这时 offset_top 才是「底边距屏幕底多远」，文字在这个位置往**上**长。
	_click_hint = _make_label(
		cfg.str_val("menu.click_text", "————点击任意处进入游戏————"),
		int(cfg.num("menu.click_size", 32.0)),
		_menu_color("menu.click_color", ThemeRes.text_dim())
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

	# ---- 扫光：盖在标题上的一条斜向亮带，入场时从左掠过右一次 ----
	# ★ 它是 `_title` 的**同级兄弟**（不是子节点）：SpacedLabel 会把自己画在
	#   （0,0)-(w,h) 里，子节点会被它的绘制顺序影响；做成兄弟、且在**其后** add_child，
	#   绘制顺序就是「标题 → 扫光」，这才是「光在上面掠过」。
	# ★ 它盖住的矩形比标题略宽，但 `mouse_filter = IGNORE` ⇒ 不影响「点击任意处」。
	_shine = Control.new()
	_shine.name = "TitleShine"
	_shine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shine.anchor_left = 0.0
	_shine.anchor_right = 1.0
	_shine.offset_left = 0.0
	_shine.offset_right = 0.0
	_shine.offset_top = _title.offset_top - 24.0
	_shine.offset_bottom = _title.offset_bottom + 24.0
	_shine.draw.connect(_on_shine_draw)
	_intro.add_child(_shine)


func _build_menu() -> void:
	# ★★ 结构（从外到内，测试按节点路径找控件，别随手改名字）：
	#   `MainMenu`（CenterContainer，整页铺满、负责居中）
	#     └ `MenuOuter`（VBox，**把标题条与按钮列竖着连起来**）
	#         ├ `MenuOrnaments`（标题条：徽记 + DAEEM + 金线，自己也是一个 VBox）
	#         ├ 一个下边距（`menu_rule_gap`，标题条与那一列之间的呼吸）
	#         └ `MenuColumn`（VBox：地图选择条 + test + campaign_test）
	#
	# ★★ 为什么标题条与按钮列要放进**同一个 VBox**（而不是各摆各的）：
	#   第一版把标题条锚在屏幕下边、按钮列整页居中，两者互不知情 ——
	#   结果在 1920×1080 上（实测截图）标题条正好落在 campaign_test 底下、贴着字标，
	#   而且窗口比例一变就可能直接压到按钮上（无头 1920×1920 的视口里就是撞上的）。
	#   连成一列之后，「标题在按钮上方」是**排版保证**的，不是靠两个坐标碰巧错开。
	#
	# ★★ 但标题条**不能**直接当 MenuColumn 的孩子：VBox 的 `separation` 作用于
	#   **每一对**相邻子节点，塞进去会让「标题 → 选择条」也吃一份按钮间距
	#   （实测过：想要 48，量出来 268）。所以中间隔一层 MenuOuter，
	#   它自己的 separation 用标题专用的 `menu_rule_gap`。
	_menu = CenterContainer.new()
	_menu.name = "MainMenu"
	_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	_menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_menu)

	# ★ 整块往下推一点（`menu_column_offset`）：CenterContainer 是严格居中的，
	#   而这套版式里「标题 + 选择条 + 两颗按钮」整块居中时，上方会留下一大条空白
	#   （实测截图：内容整体偏上、下半个屏幕全空）。用一个负的上边距把它压下来。
	var pad := MarginContainer.new()
	pad.name = "MenuPad"
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_top",
		cfg.int_val("menu.menu_column_offset", 120))
	_menu.add_child(pad)

	var outer := VBoxContainer.new()
	outer.name = "MenuOuter"
	outer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	outer.add_theme_constant_override("separation",
		cfg.int_val("menu.menu_rule_gap", 40))
	pad.add_child(outer)

	# ---- 标题条：徽记 / 字标 / 金线，竖着摞（VBox 自己管间距）----
	var ornaments := VBoxContainer.new()
	ornaments.name = "MenuOrnaments"
	ornaments.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_theme_constant_override("separation",
		cfg.int_val("menu.menu_title_gap", 22))
	outer.add_child(ornaments)

	# 1) 徽记：★ 用 CenterContainer 包住 —— 自绘控件的宽度是按内容算的，
	#    直接放进 VBox 会被拉满整行（那枚圆环就跑到屏幕左边去了）。
	var emblem_wrap := CenterContainer.new()
	emblem_wrap.name = "MenuEmblemWrap"
	emblem_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_child(emblem_wrap)
	var e_size := cfg.num("menu.menu_emblem_size", 112.0)
	var emblem := MenuEmblemRes.new()
	emblem.name = "MenuEmblem"
	emblem.custom_minimum_size = Vector2(e_size, e_size)
	emblem_wrap.add_child(emblem)

	# 2) 字标（带字距的那排字）
	var word := TextMarksRes.SpacedLabel.new()
	word.name = "MenuWordmark"
	word.text = cfg.str_val("menu.title", "DAEEM")
	word.font = _font
	word.font_size = int(cfg.num("menu.menu_title_size", 44.0))
	word.tracking = cfg.num("menu.menu_title_tracking", 14.0)
	word.color_from = _menu_color("menu.menu_title_color", ThemeRes.text())
	word.color_to = _menu_color("menu.menu_title_gold_color", ThemeRes.accent())
	word.custom_minimum_size = Vector2(0.0, cfg.num("menu.menu_title_height", 58.0))
	# ★ 自绘的 SpacedLabel 是按**控件宽度**居中的，所以必须让它在 VBox 里横向撑满；
	#   而 VBox 对 Control 的默认就是「撑满 + 取最小高度」，这里只需给高度。
	word.size_flags_horizontal = Control.SIZE_FILL
	ornaments.add_child(word)

	# 3) 金线（两端渐隐，宽度固定 ⇒ 用 CenterContainer 居中）
	var rule_wrap := CenterContainer.new()
	rule_wrap.name = "MenuRuleWrap"
	rule_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ornaments.add_child(rule_wrap)
	var rule := TextMarksRes.Rule.new()
	rule.name = "MenuRule"
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.85)
	rule.line_width = 1.0
	rule.fade = 60.0
	rule.custom_minimum_size = Vector2(cfg.num("menu.menu_rule_width", 220.0), 1.0)
	rule_wrap.add_child(rule)

	# ★ 用 VBoxContainer 而不是自己算 y 偏移：需求是「选择条在 test 按钮**上方**」——
	#   这是一条**相对**关系，自己写死两个绝对 y 的话，以后改按钮高度就会让它俩叠在一起。
	#
	# ★★ 间距的口径（两处，别再合并成一个）：
	#   · 列的 `separation` = **两颗按钮之间**的间距
	#     （`menu.campaign_test_button_gap`，48 —— 它们是一类入口，挨近一点才像一组）；
	#   · 「选择条 → test」那一格要更宽（`menu.map_gap`，112 —— 下拉列表弹出来
	#     不能压住按钮），所以**给它单独包一层 MarginContainer 加下边距**，
	#     差值算在 `_build_map_row` 里。
	#   ⚠️ 别再想「往列里插一个垫片 Control 来撑大/缩小某一段」：`separation` 作用于
	#      **每一对**相邻子节点，插进去只会让那一段变成「separation + 垫片 + separation」
	#     （实测：想要 48，量出来 268）。
	# ★ 对齐方式（实测出来的，改布局前先读这三行）：
	#   VBoxContainer 里的控件默认横向**撑满容器宽度** —— 而容器的宽度由最宽的那个
	#   子控件决定（下拉框 `menu.map_select_width` = 320），所以 test 按钮会被拉到
	#   和选择条一样宽，两个方块看起来才是一组（按钮自己设的 240 只是**最小**宽度）。
	#   ALIGNMENT_CENTER 管的是**竖直**方向（整列在 CenterContainer 里居中）。
	var button_gap := cfg.int_val("menu.campaign_test_button_gap", 48)
	var column := VBoxContainer.new()
	column.name = "MenuColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", button_gap)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	outer.add_child(column)

	_build_map_row(column)
	_build_test_button(column)
	_build_campaign_button(column)


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
## ★ 它的样式全部来自 `view/menu_theme.gd`（暗底 + 金线），**包括下拉列表那块底板**：
##   引擎默认的列表是浅色 HUD 皮，在这个暗金界面上弹出来会是一块刺眼的白。
func _build_map_row(column: VBoxContainer) -> void:
	# ★★ 「选择条 → test」要比「test → campaign_test」宽（112 vs 48，见 `_build_menu`
	#    里那段间距口径）。列的 separation 只能是一个值，所以这里**把选择条那一格
	#    包进一层 MarginContainer 补上差值** —— 于是这一格的「占位高度」=
	#    选择条 + (map_gap - separation)，与 test 之间的净间距就正好是 map_gap。
	var wrap := MarginContainer.new()
	wrap.name = "MapRowWrap"
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var extra := maxi(0, cfg.int_val("menu.map_gap", 112)
		- cfg.int_val("menu.campaign_test_button_gap", 48))
	wrap.add_theme_constant_override("margin_bottom", extra)
	column.add_child(wrap)

	var row := HBoxContainer.new()
	row.name = "MapRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	wrap.add_child(row)

	_map_label = _make_label(
		cfg.str_val("menu.map_select_label", "地图"),
		cfg.int_val("menu.map_select_label_size", 28),
		_menu_color("menu.map_select_label_color", ThemeRes.text_dim())
	)
	_map_label.name = "MapLabel"
	row.add_child(_map_label)

	# ★ 四个态 + 列表底板都走 menu_theme：暗底 + 金线，
	#   字色是暖白（`text_normal`）—— 旧白底那版的深灰字在这个底上会看不见。
	#   ⚠️ 下拉列表那块底板（`popup_panel`）**必须不透明**：PopupMenu 是独立窗口，
	#      底下没有渐变背景可透（理由写在 menu_theme.popup_panel 那里）。
	_map_select = MapSelectRes.new()
	_map_select.build(row, _font, cfg.int_val("menu.map_select_size", 26),
		MenuThemeRes.text_normal(),
		MenuThemeRes.button_normal(),
		# ★ 悬停底纹用「透明底」那一档：那片金由自绘填充层给
		#   （0.08 的淡金叠在填充上会把金压暗，观感变成「悬停只亮了一点点」）
		MenuThemeRes.button_hover_clear(),
		MenuThemeRes.button_selected(),
		MenuThemeRes.button_normal(),
		MenuThemeRes.popup_panel(),
		MenuThemeRes.popup_row_hover(),
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
	_test_button.focus_mode = Control.FOCUS_NONE
	_test_button.custom_minimum_size = Vector2(
		cfg.num("menu.test_button_width", 240.0),
		cfg.num("menu.test_button_height", 80.0)
	)
	if _font != null:
		_test_button.add_theme_font_override("font", _font)
	_test_button.add_theme_font_size_override("font_size", cfg.int_val("menu.test_button_size", 28))
	# ★★ 悬停填充（在挂样式之前挂上：样式那一步就要往它身上写「原字色」）
	FillButtonRes.attach_text(_test_button)
	_apply_button_styles(_test_button, false)
	_test_button.pressed.connect(_on_test_pressed)
	column.add_child(_test_button)


## ★ 单人战役的**占位入口**（`campaign_test`）：一颗与 test 同款的按钮，摆在它**下面**。
##
## 为什么要有它：战役的数据与逻辑（M7.0~M7.2）已经能跑，但**正式入口还没做**
## （dev_plan_7 5.1 的战役选择条 / 关卡列表 / 简报是后面几轮的事）——
## 没有入口就只能靠无头脚本开局，手玩验不了。所以先放这颗按钮进
## `view/campaign_test.gd` 那一页（列关卡 + 选阵营 + 开始）。
##
## ★ 两处刻意与 test 按钮不同：
##   1. 它在 test **下面**，两颗之间的间距是 `menu.campaign_test_button_gap`（48，
##      也就是整列的 `separation`）—— 见 `_build_menu` 里那段间距口径；
##   2. 它**不参与**「选了哪张地图」这件事：战役进哪张图由关卡数据说了算
##      （`level.map_id`），与选择条无关。
func _build_campaign_button(column: VBoxContainer) -> void:
	_campaign_button = Button.new()
	_campaign_button.name = "CampaignTestButton"
	_campaign_button.text = cfg.str_val("menu.campaign_test_button_text", "campaign_test")
	_campaign_button.focus_mode = Control.FOCUS_NONE
	_campaign_button.custom_minimum_size = Vector2(
		cfg.num("menu.test_button_width", 240.0),
		cfg.num("menu.test_button_height", 80.0)
	)
	if _font != null:
		_campaign_button.add_theme_font_override("font", _font)
	_campaign_button.add_theme_font_size_override("font_size",
		cfg.int_val("menu.test_button_size", 28))
	# ★★ 悬停填充（同上：必须在 `_apply_button_styles` 之前）
	FillButtonRes.attach_text(_campaign_button)
	_apply_button_styles(_campaign_button, false)
	_campaign_button.pressed.connect(_on_campaign_test_pressed)
	column.add_child(_campaign_button)


## 把「线框 / 选定」那一套样式挂到一颗 Button 上。
##
## ★ 抽成一个函数（而不是两处各挂一遍）：test 与 campaign_test 必须**长得一模一样**
##   （它们是一组入口），抄成两份的话早晚会漂 —— 而那种漂在界面上是看得出「这两颗不是一套」。
## ★ `filled` = 实心金那档（游戏内页签 / 战役页当前选中的行用它）；
##   主界面这两颗按钮都是线框（false）—— 主界面上没有「当前选中」这个概念。
## ⚠️ 字色有三档（暖白 / 近黑 / 暗金灰）：实心金底上必须换成近黑，
##   否则「暖白字压金底」几乎读不出来。
func _apply_button_styles(b: Button, filled: bool) -> void:
	var font_normal := MenuThemeRes.text_on_fill() if filled else MenuThemeRes.text_normal()
	# ★★ 字色走「登记原色」的接口（不是 add_theme_color_override）：
	#   填充动效每帧按「原色 + 当前填充进度」重算这四条，直接写 override 会被盖掉。
	FillButtonRes.set_base_font_color(b, font_normal)
	# ★★ 这两颗按钮的底是**主界面的深色渐变页**（不是实心金块）：
	#   显式告诉填充层，别让它去猜底纹 ——
	#   实测它会扫到 `pressed` 那格的实心金，于是「空鼠标」时也按金字底算，
	#   把白字整块换成近黑（用户报的「test / campaign_test 的字变成黑色了」）。
	#   ★ 字色口径：**白字起步、金扫上来时由白变黑**（与页签栏同一条规则，
	#     见 view/fill_button.gd 的 `_sync_text()`）。
	#     ⚠️ 下面那行 `set_prefer_light` 是**历史遗留**（那个开关已作废）：
	#        它当年代表「压金也保持白字」，而白字压金读不出来 ——
	#        那正是用户报的「test / campaign_test 的字被金色填充遮挡」。
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	FillButtonRes.set_prefer_light(b, not filled)
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	if filled:
		# ★ 实心金那一档：悬停时**再亮一档**（填充层的 done 态）
		b.add_theme_stylebox_override("hover", MenuThemeRes.button_selected_hover())
		b.add_theme_stylebox_override("normal", MenuThemeRes.button_selected())
		b.add_theme_stylebox_override("pressed", MenuThemeRes.button_selected())
		b.add_theme_stylebox_override("focus", MenuThemeRes.button_selected())
		b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
		FillButtonRes.set_latched(b, true)
		return
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	# ★ 悬停底纹用「透明底」那一档：那片金由自绘填充给（0.08 的淡金会把填充压暗）
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	# ★ 按下态仍用**实心金**：这一下要看得出来「按到了」（暗底上只换线色反馈太弱）。
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_selected())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	FillButtonRes.set_latched(b, false)


## 标题下面那条金色分隔线（参考图里标题上下的细线）。
##
## ★ 位置是**算出来的**（标题底 + title_rule_gap），不是又一个绝对坐标 ——
##   改标题字号 / 高度时这条线自己跟着走，不会漂到字上去。
func _build_rule(parent: Control, node_name: String, y: float) -> void:
	var rule := TextMarksRes.Rule.new()
	rule.name = node_name
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.9)
	rule.line_width = cfg.num("menu.title_rule_height", 1.0)
	# 两端渐隐（参考图的线是「中间实、两头化开」的）
	rule.fade = cfg.num("menu.title_rule_fade", 40.0)
	var w := cfg.num("menu.title_rule_width", 460.0)
	rule.anchor_left = 0.5
	rule.anchor_right = 0.5
	rule.offset_left = -w * 0.5
	rule.offset_right = w * 0.5
	rule.offset_top = y
	rule.offset_bottom = y + 1.0
	parent.add_child(rule)


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
##
## ★★ 本轮加了一段「淡入 + 停顿」当**前奏**（见 `intro_fade_sec` / BLINK_START_DELAY）：
##   入场页现在是一整块（徽记 + 标题 + 金线 + 提示）一起浮上来，
##   浮上来之后提示才开始呼吸 —— 于是「首帧就可见」这件事**没有变**
##   （tween 的起点 = 当前值 = 亮端），只是它先落到暗端再呼吸。
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
	_blink_tween = create_tween()
	# 1) 淡入：从暗端升到亮端（这一段时间里整页也在淡入）
	_blink_tween.tween_property(_click_hint, "modulate:a", hi,
		cfg.num("menu.intro_fade_sec", 0.9)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	# 2) 停一拍（呼吸还没开始，让「浮上来」这件事先被看清）
	_blink_tween.tween_interval(BLINK_START_DELAY)
	# 3) 之后是**无限**的呼吸
	_blink_tween.set_loops()
	_blink_tween.tween_property(_click_hint, "modulate:a", lo, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_blink_tween.tween_property(_click_hint, "modulate:a", hi, BLINK_PHASE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_click_blink() -> void:
	if _blink_tween != null and _blink_tween.is_valid():
		_blink_tween.kill()
	_blink_tween = null


# ------------------------------------------------------------------
# 标题的扫光（入场一次）
# ------------------------------------------------------------------

## 一道斜向的亮带从标题左边掠到右边，一次就结束（见 SHINE_SEC / SHINE_DELAY_SEC）。
##
## ★★ 为什么要有它：参考图那排字的「打光感」是这套风格里唯一的动效来源。
##   静态的渐变标题虽然对，但整个入场页就没有任何东西在动 —— 而入场页的职责
##   恰恰是「让玩家知道游戏活着」。
## ★ 它是**盖在标题上的一个空 Control**，自己在 `_draw` 里画那条带子（见 `_on_shine_draw`）：
##   比复制一份文字做遮罩省事得多，而且完全不影响文字本身的绘制。
func start_title_shine() -> void:
	if _shine == null or _title == null:
		return
	_stop_title_shine()
	_shine.visible = true
	# 起点在标题左侧之外，终点在右侧之外（0 → 1 是「带子中心扫过整块标题」的进度）
	_shine.modulate.a = 0.0
	_shine.set_meta("shine_t", 0.0)
	_shine.queue_redraw()
	_shine_tween = create_tween()
	_shine_tween.tween_interval(SHINE_DELAY_SEC)
	_shine_tween.tween_method(_set_shine_t, 0.0, 1.0, SHINE_SEC) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_shine_tween.tween_callback(_stop_title_shine)


func _stop_title_shine() -> void:
	if _shine_tween != null and _shine_tween.is_valid():
		_shine_tween.kill()
	_shine_tween = null
	if _shine != null:
		_shine.visible = false
		_shine.modulate.a = 0.0


func _set_shine_t(t: float) -> void:
	if _shine == null:
		return
	_shine.set_meta("shine_t", t)
	# 带子的亮度：两端淡（进入 / 离开），中段最亮 —— 用 sin 曲线，避免「啪地出现」
	_shine.modulate.a = sin(clampf(t, 0.0, 1.0) * PI)
	_shine.queue_redraw()


## 扫光那一条的画法：一个**斜的**矩形，用一次 `draw_set_transform` 把坐标系歪一下
## （比手算四边形的顶点少一半代码，而且线宽 / 采样都不会出错）。
func _on_shine_draw() -> void:
	if _shine == null:
		return
	var w: float = _shine.size.x
	var h: float = _shine.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var t: float = float(_shine.get_meta("shine_t", 0.0))
	var band_w: float = maxf(40.0, w * 0.10)
	# 带子的中心：从 -band_w 扫到 w + band_w
	var cx: float = -band_w + (w + band_w * 2.0) * t
	_shine.draw_set_transform(Vector2(cx, h * 0.5), SHINE_SKEW, Vector2.ONE)
	var gold := ThemeRes.accent_bright()
	# 三段不同 alpha 的竖条拼出「两头淡」的带子（不引 shader：见 text_marks.gd Rule 的同一条理由）
	var seg := band_w / 3.0
	var alphas := [0.10, 0.22, 0.10]
	for i in 3:
		var a: float = alphas[i]
		_shine.draw_rect(Rect2(-band_w * 0.5 + seg * float(i), -h, seg, h * 2.0),
			ThemeRes.with_alpha(gold, a), true)
	_shine.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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


## ★ 按下了 campaign_test：把「该开战役页了」这件事交给 `view/main.gd`。
##
## ⚠️ 与 `_on_test_pressed` 同一条守卫（`not visible` ⇒ 不生效）：
##    进了游戏之后开场页整层是隐藏的，正常路径上按不到第二次；
##    留着这一道是为了「连点两下」永远不会挂出两页来。
func _on_campaign_test_pressed() -> void:
	if not visible:
		return
	campaign_test_pressed.emit()


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


## ★★ 列表底板当前的**不透明度**（0 = 全透明，1 = 完全不透明）。
##   ★ 给测试看「渐入 / 渐出确实在淡」：`PopupMenu` 是 `Window`，没有 `modulate`
##     可用，所以淡入淡出改的是底板 StyleBox 的 alpha（见 view/map_select.gd）。
func map_select_panel_alpha() -> float:
	return _map_select.panel_alpha() if _map_select != null else 1.0


## ★ 主界面上那颗 **test 按钮** —— 给测试量几何 / 点它用。
##
## ⚠️ 本轮它在树上的**路径变了**（标题条与按钮列现在连成一条 VBox，
##    见 `_build_menu` 的结构图 ⇒ 实际路径是 `StartRoot/MainMenu/MenuPad/MenuOuter/MenuColumn`）。
##    与其让测试去记这条越来越长的路径，不如像 `campaign_test_button()` 那样问这里 ——
##    以后这一列再调整，测试不用跟着改。
func test_button() -> Button:
	return _test_button


## ★ 主界面第二颗按钮（`campaign_test`）本身 —— 给测试量几何 / 点它用。
##
## ⚠️ 它**可以**走节点路径找（`.../MenuColumn/CampaignTestButton`，因为它就是一个
##    `Button` 节点、不在别的类内部）；这个方法留着是为了让测试与
##   `map_select_button()` 的用法对称 —— 也为了以后这一列再改动时，
##   测试不用跟着改路径。
func campaign_test_button() -> Button:
	return _campaign_button


## 主界面标题条那几块（徽记 / 字标 / 金线）—— **只给测试与排查用**。
##
## ★ 为什么要开这个口子：它们住在 `MenuOrnaments`（一个 VBox，见 `_build_menu` 的结构图），
##   而那一层为什么必须与按钮列一起放进同一个 VBox、又为什么不能直接塞进 MenuColumn，
##   写在 `_build_menu` 里。测试要断言「标题条真的在那一列上方、且没有把列撑歪」，
##   光靠节点路径要写一长串，所以这里转一层。
func menu_ornaments() -> Control:
	return _menu.get_node_or_null("MenuPad/MenuOuter/MenuOrnaments") if _menu != null else null


## 入场页标题（`view/text_marks.gd` 的 SpacedLabel，**不是** Label）。
## ★ 给测试用：它是自绘控件，`text` / `tracking` / `measured_width()` 都要从这里读。
func intro_title() -> Control:
	return _title
