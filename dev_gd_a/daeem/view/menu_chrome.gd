## menu_chrome.gd —— 主界面的「版式外壳」（仿 nsoc 的主菜单）
##
## 三块（位置与尺寸全来自 `data/config.json` 的 `menu.chrome` 段）：
##   · `ProfilePnl`   左上：头像（`res://icon.svg`，**Godot 图标**当占位）+ 名字 / 资金两行；
##   · `LeftNavPnl`   左侧竖直居中：成长 / 备战 / 好友 / 藏品 / 自定义（五颗，文字**竖排**）；
##   · `RightSidePnl` 右下：上排「战役 / 演义」，下排「合作模式」。
##
## ★★ 点任意一块 → 那一块**撑满全屏**、其余两块滑出屏幕外（机制在 `view/panel_expand.gd`），
##   撑开后挂上一块面板（见 `view/menu_secondary_panel.gd`）：
##     · 「战役」那颗 → 面板内容区里是**地图选择条 + test + campaign_test**
##       （`view/battle_entries.gd`，从主界面正中那一列搬过来的）；
##     · 其余各块 → 面板是空的（只有一颗「返回」）。
##
## ★ 本文件只管**版式与点击**：不认识玩法、也不建世界 —— 内容区发上来的两个信号
##   只往上传一层（start_screen → main.gd），谁建世界仍然只有 main.gd 知道。
##
## ★ 按钮的四态与悬停填充都复用现成的工厂（`menu_theme` 出样式、`fill_button` 出那片金），
##   与正中那一列按钮是同一套观感。这里没有把它抽成公共函数，是因为那一列按用户要求
##   「暂时不动」—— 为了共用去改它不划算，等它要改的时候再合并。
extends Control

## 内容区里那颗 test 被按了（面板 → 外壳 → start_screen → main.gd，见下）
signal test_pressed(map_path: String)
## 内容区里那颗 campaign_test 被按了
signal campaign_test_pressed()

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const PanelExpandRes = preload("res://view/panel_expand.gd")
const MenuSecondaryPanelRes = preload("res://view/menu_secondary_panel.gd")

## 头像素材：Godot 图标（用户指定的占位；与 nsoc 用的是同一个文件）
const AVATAR_PATH := "res://icon.svg"

## 侧边栏五颗按钮的节点名（与 nsoc 同名，方便两边对着读；config 里的条数更多时后面按序号命名）
const NAV_BTN_NAMES := ["GrowBtn", "PrepareBtn", "FriendBtn", "CollectionBtn", "CustomBtn"]
## 右下上排 / 下排的节点名（nsoc 那颗「演武切磋」在本作里是「合作模式」）
const SIDE_TOP_NAMES := ["CampaignBtn", "JourneyBtn"]
const SIDE_BOTTOM_NAME := "CoopBtn"

## 兜底文案（config 读不到时用；值与 data/config.json 一致）
const DEFAULT_NAV_ITEMS := ["成长", "备战", "好友", "藏品", "自定义"]
const DEFAULT_SIDE_TOP_ITEMS := ["战役", "演义"]
const DEFAULT_SIDE_BOTTOM_ITEM := "合作模式"

var cfg: ConfigRes = null
var _font: Font = null

## 三块面板。★ **add_child 的先后就是叠放顺序**（后加的在上）。
var _profile: Panel = null
var _nav: Panel = null
var _side: Panel = null
## 撑开 / 让路的引擎（`view/panel_expand.gd`）
var _expand = null
var _nav_buttons: Array = []
var _side_buttons: Array = []
var _avatar: TextureRect = null
var _name_label: Label = null
var _money_label: Label = null
var _profile_tween: Tween = null
## ★ 「战役」那颗按钮（内容区里放战斗测试入口的就是它）——
##   见 `_make_secondary_panel()`：只有它撑开的面板带内容。
var _battle_btn: Button = null
## 这一轮是哪颗控件触发的撑开（决定面板里放不放内容）。
var _pending_btn: Control = null


func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	name = "MenuChrome"
	# ⚠️ 必须用 `set_anchors_and_offsets_preset`（而不是 `set_anchors_preset`）：
	#   本节点是**先 add_child、再 setup()** 的，也就是说设锚点时它已经在树上、尺寸还是 0。
	#   那种状态下 `set_anchors_preset(PRESET_FULL_RECT)` 会把 offset 算成「保持当前 0 尺寸」
	#   ⇒ 整块外壳的 size 停在 (0,0)，里面三块面板的锚点全部塌到 0 附近（位置变成负的、点不到）。
	#   这个函数会连 offset 一起设成「铺满父节点」，与在不在树上无关。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 外壳自己不吃鼠标：吃的只有那三块面板与里面的按钮（与 start_screen 的根节点同一条口径）
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_profile()
	_build_left_nav()
	_build_right_side()

	_expand = PanelExpandRes.new()
	_expand.name = "PanelExpand"
	add_child(_expand)
	_expand.setup(self, Callable(self, "_make_secondary_panel"),
		cfg.num("menu.chrome.transition_sec", 0.45),
		cfg.num("menu.chrome.transition_fade_sec", 0.15),
		cfg.num("menu.chrome.expanded_margin", 24.0))
	_expand.intro_sec = cfg.num("menu.chrome.intro_sec", 0.55)
	# ★ 面板挂上来的那一刻把它内容区的信号接过来（面板是每次撑开新建、收起销毁的）
	_expand.expanded.connect(_on_panel_expanded)
	# 让路方向照 nsoc：左上与左侧向左滑出、右下向右滑出
	_expand.add_target(_profile, -1)
	_expand.add_target(_nav, -1)
	_expand.add_target(_side, 1)
	# ★ 抄初始状态要等一帧（layout 跑完才有真的 position/size）—— 引擎里处理
	_expand.attach()


# ------------------------------------------------------------------
# 对外接口
# ------------------------------------------------------------------

## 登记一块「撑开时要让路、但不属于本外壳」的界面（主界面正中那一列）。
## @param dir 0 = 只淡出不移位（那一列整页居中，往哪边滑都别扭）
func add_avoid_target(node: Control, dir: int = 0) -> void:
	if _expand == null or node == null:
		return
	_expand.add_target(node, dir)


## ★ 首次进入主界面：三块面板从屏幕外滑入（见 `view/panel_expand.gd` 的 `play_intro()`）。
## 由 `view/start_screen.gd` 在「入场页的 logo 缓动落位之后」调一次。
func play_intro() -> void:
	if _expand != null:
		_expand.play_intro()


func profile_panel() -> Control:
	return _profile


func left_nav_panel() -> Control:
	return _nav


func right_side_panel() -> Control:
	return _side


## 侧边栏五颗按钮（按界面从上到下的顺序）
func nav_buttons() -> Array:
	return _nav_buttons


## 右下三颗按钮（上排两颗、下排一颗，按这个顺序）
func side_buttons() -> Array:
	return _side_buttons


func avatar() -> TextureRect:
	return _avatar


func name_label() -> Label:
	return _name_label


func money_label() -> Label:
	return _money_label


## 撑开 / 让路的引擎（测试要问它 `is_expanded()` / `secondary_panel()`）
func expand_engine():
	return _expand


# ------------------------------------------------------------------
# 左上：个人资料
# ------------------------------------------------------------------

func _build_profile() -> void:
	var x := cfg.num("menu.chrome.profile.x", 20.0)
	var y := cfg.num("menu.chrome.profile.y", 20.0)
	var w := cfg.num("menu.chrome.profile.w", 320.0)
	var h := cfg.num("menu.chrome.profile.h", 100.0)
	var pad := cfg.num("menu.chrome.profile.pad", 12.0)

	_profile = _make_panel("ProfilePnl")
	_profile.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	_profile.position = Vector2(x, y)
	_profile.size = Vector2(w, h)
	# ★ 资料面板**自己吃点击**（与 nsoc 一致：点它也会撑开一块面板），
	#   所以面板 STOP、里面所有子控件 IGNORE —— 点哪都算点在这块面板上，
	#   不必像 nsoc 那样再叠一层透明 Button。
	_profile.mouse_filter = Control.MOUSE_FILTER_STOP
	_profile.gui_input.connect(_on_profile_input)

	var box := HBoxContainer.new()
	box.name = "HBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	box.offset_left = pad
	box.offset_top = pad
	box.offset_right = -pad
	box.offset_bottom = -pad
	box.add_theme_constant_override("separation", 12)
	_profile.add_child(box)

	var av_size := cfg.num("menu.chrome.profile.avatar", 76.0)
	_avatar = TextureRect.new()
	_avatar.name = "Avatar"
	_avatar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_avatar.custom_minimum_size = Vector2(av_size, av_size)
	_avatar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# 与 nsoc 一样的两个参数：不管素材多大都按框缩放、保持比例居中（图标是正方形，不会变形）
	_avatar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_avatar.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_avatar.texture = load(AVATAR_PATH)
	box.add_child(_avatar)

	var info := VBoxContainer.new()
	info.name = "InfoVBox"
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	info.add_theme_constant_override("separation", 4)
	box.add_child(info)

	_name_label = _make_label("NameLbl",
		cfg.str_val("menu.chrome.profile.name", "Administrator"),
		cfg.int_val("menu.chrome.profile.name_size", 22), MenuThemeRes.text_normal())
	info.add_child(_name_label)
	_money_label = _make_label("MoneyLbl",
		cfg.str_val("menu.chrome.profile.money", "资金：666"),
		cfg.int_val("menu.chrome.profile.money_size", 18), MenuThemeRes.text_dim())
	info.add_child(_money_label)


## 资料面板上的点击：按下缩一下（0.98，照 nsoc），松开时撑开这块面板。
## ★ 松开那一下要**还在面板里**才算 —— 按住拖出去松手不算点，这与 Button 的语义一致。
func _on_profile_input(event: InputEvent) -> void:
	if _expand == null or _expand.is_busy() or _expand.is_expanded():
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or _profile == null:
		return
	_profile_scale(mb.pressed)
	if not mb.pressed and Rect2(Vector2.ZERO, _profile.size).has_point(mb.position):
		_pending_btn = _profile
		_expand.expand(_profile, _profile)


func _profile_scale(pressed: bool) -> void:
	if _profile == null:
		return
	if _profile_tween != null and _profile_tween.is_valid():
		_profile_tween.kill()
	var target: Vector2 = Vector2(0.98, 0.98) if pressed else Vector2.ONE
	if not ThemeRes.animations_enabled():
		_profile.scale = target
		return
	_profile_tween = create_tween()
	_profile_tween.tween_property(_profile, "scale", target, 0.08)


# ------------------------------------------------------------------
# 左侧：导航
# ------------------------------------------------------------------

func _build_left_nav() -> void:
	var x := cfg.num("menu.chrome.nav.x", 20.0)
	var w := cfg.num("menu.chrome.nav.w", 120.0)
	var h := cfg.num("menu.chrome.nav.h", 800.0)
	var pad_x := cfg.num("menu.chrome.nav.pad_x", 10.0)
	var pad_y := cfg.num("menu.chrome.nav.pad_y", 16.0)
	var gap := cfg.int_val("menu.chrome.nav.gap", 12)

	_nav = _make_panel("LeftNavPnl")
	# 竖直居中：上下锚都放在 0.5，靠 offset 把 h 摊在中心两侧（与 nsoc 同一做法）
	_nav.anchor_top = 0.5
	_nav.anchor_bottom = 0.5
	_nav.offset_left = x
	_nav.offset_right = x + w
	_nav.offset_top = -h * 0.5
	_nav.offset_bottom = h * 0.5

	var box := _make_box("VBox", _nav, pad_x, pad_y)
	box.add_theme_constant_override("separation", gap)

	var items: Array = _string_list("menu.chrome.nav.items", DEFAULT_NAV_ITEMS)
	var font_size := cfg.int_val("menu.chrome.nav.font_size", 28)
	var last_ratio := cfg.num("menu.chrome.nav.last_ratio", 1.5)
	for i in items.size():
		var node_name: String = NAV_BTN_NAMES[i] if i < NAV_BTN_NAMES.size() else "NavBtn%d" % i
		var b := _make_menu_button(node_name, _stacked(String(items[i])), font_size)
		# 五颗平分高度；**最后一颗按 last_ratio 更高**（nsoc 的「自定义」比前四颗高一半）
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		if i == items.size() - 1:
			b.size_flags_stretch_ratio = last_ratio
		b.pressed.connect(_on_nav_pressed.bind(b))
		box.add_child(b)
		_nav_buttons.append(b)


func _on_nav_pressed(btn: Button) -> void:
	if _expand != null:
		_pending_btn = btn
		_expand.expand(_nav, btn)


# ------------------------------------------------------------------
# 右下：进入游戏的三个入口
# ------------------------------------------------------------------

func _build_right_side() -> void:
	var right := cfg.num("menu.chrome.side.right", 40.0)
	var bottom := cfg.num("menu.chrome.side.bottom", 30.0)
	var w := cfg.num("menu.chrome.side.w", 450.0)
	var h := cfg.num("menu.chrome.side.h", 270.0)
	var pad := cfg.num("menu.chrome.side.pad", 20.0)
	var gap := cfg.int_val("menu.chrome.side.gap", 16)
	var font_size := cfg.int_val("menu.chrome.side.font_size", 28)

	_side = _make_panel("RightSidePnl")
	# 右下角：四个锚都贴右下，靠负 offset 让开边距（与 nsoc 同一做法）
	_side.anchor_left = 1.0
	_side.anchor_top = 1.0
	_side.anchor_right = 1.0
	_side.anchor_bottom = 1.0
	_side.offset_left = -right - w
	_side.offset_top = -bottom - h
	_side.offset_right = -right
	_side.offset_bottom = -bottom

	var box := _make_box("VBox", _side, pad, pad)
	box.add_theme_constant_override("separation", gap)

	# 上排：两颗并排（各占一半宽、撑满高）
	var row := HBoxContainer.new()
	row.name = "TopRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", gap)
	box.add_child(row)
	var top_items: Array = _string_list("menu.chrome.side.top_items", DEFAULT_SIDE_TOP_ITEMS)
	for i in top_items.size():
		var node_name: String = SIDE_TOP_NAMES[i] if i < SIDE_TOP_NAMES.size() else "SideTopBtn%d" % i
		var b := _make_menu_button(node_name, String(top_items[i]), font_size)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.size_flags_vertical = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_side_pressed.bind(b))
		row.add_child(b)
		_side_buttons.append(b)
		# ★ 上排第一颗 = 「战役」：它撑开的那块面板里放战斗测试入口（见 `_make_secondary_panel`）
		if i == 0:
			_battle_btn = b

	# 下排：一颗通栏
	var bottom_item := cfg.str_val("menu.chrome.side.bottom_item", DEFAULT_SIDE_BOTTOM_ITEM)
	var b2 := _make_menu_button(SIDE_BOTTOM_NAME, bottom_item, font_size)
	b2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b2.pressed.connect(_on_side_pressed.bind(b2))
	box.add_child(b2)
	_side_buttons.append(b2)


func _on_side_pressed(btn: Button) -> void:
	if _expand != null:
		_pending_btn = btn
		_expand.expand(_side, btn)


# ------------------------------------------------------------------
# 零件
# ------------------------------------------------------------------

## 一块外壳面板：加进本节点、挂上 `chrome_panel` 底板。
func _make_panel(node_name: String) -> Panel:
	var p := Panel.new()
	p.name = node_name
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", MenuThemeRes.chrome_panel())
	add_child(p)
	return p


## 面板里那个「按内边距铺满」的 VBox。
func _make_box(node_name: String, parent: Control, pad_x: float, pad_y: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = node_name
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	box.offset_left = pad_x
	box.offset_right = -pad_x
	box.offset_top = pad_y
	box.offset_bottom = -pad_y
	parent.add_child(box)
	return box


## 一颗进入界面风格的按钮：四态走 menu_theme、悬停那片金由 fill_button 自绘。
## ⚠️ 顺序不能换：`attach_text()` 必须在挂样式**之前**（挂样式那一步会往它身上写「原字色」）。
func _make_menu_button(node_name: String, text: String, font_size: int) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", font_size)
	FillButtonRes.attach_text(b)
	UiWidgetsRes.apply_button_styles(b, {
		"normal": MenuThemeRes.button_normal(),
		"hover": MenuThemeRes.button_hover_clear(),
		"pressed": MenuThemeRes.button_selected(),
		"disabled": MenuThemeRes.button_disabled(),
	})
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	return b


func _make_label(node_name: String, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 把两个字**竖排**（nsoc 的侧边栏就是这么排的：一个字一行，读起来像一块竖牌）。
## ★ 「怎么排」是**呈现**：config 里存的是「成长」，换行在这里加。
static func _stacked(label: String) -> String:
	var out := ""
	for i in label.length():
		if i > 0:
			out += "\n"
		out += label.substr(i, 1)
	return out


## 读一组字符串（config 里的 `["成长", "备战", ...]`）。
## ★ 数组的顺序**就是界面上的顺序** —— 想换顺序改 JSON，不必碰代码。
## ⚠️ 读不到 / 写成空数组时退回 `fallback`（默认那几条）：宁可显示默认的五个入口，
##   也不要让侧边栏整个消失 —— 那种「一片空白」比「文案不对」难查得多。
func _string_list(path: String, fallback: Array) -> Array:
	var v: Variant = cfg.get_path_value(path) if cfg != null else null
	var out: Array = []
	if typeof(v) == TYPE_ARRAY:
		for item in (v as Array):
			var s := String(item)
			if s != "":
				out.append(s)
	return out if not out.is_empty() else fallback


## 造那块面板（引擎撑开之后调它）。
##
## ★ 内容只在**「战役」那颗**撑开时有（地图选择条 + test + campaign_test）；
##   其余各块（资料 / 侧边栏五键 / 演义 / 合作模式）撑开的都是空面板。
func _make_secondary_panel():
	var with_entries: bool = _pending_btn != null and _pending_btn == _battle_btn
	var p = MenuSecondaryPanelRes.new()
	p.setup(cfg, _font, _expand.transition_sec, _expand.margin, with_entries)
	return p


## 面板挂上来了：把它内容区的两个信号往上接一层。
## ★ 面板每次撑开都是新的、收起就销毁 ⇒ 连接跟着它一起消失，不会越连越多。
func _on_panel_expanded() -> void:
	var p = _expand.secondary_panel()
	if p == null:
		return
	if p.has_signal("test_pressed"):
		p.test_pressed.connect(func(path: String): test_pressed.emit(path))
	if p.has_signal("campaign_test_pressed"):
		p.campaign_test_pressed.connect(func(): campaign_test_pressed.emit())


## 当前撑开面板里那块「战斗测试入口」（`view/battle_entries.gd`）—— 没展开 / 空面板时是 null。
## ★ 给测试用：地图选择条 / test / campaign_test 现在住在面板里，测试要先展开「战役」再问这里。
func battle_entries():
	if _expand == null:
		return null
	var p = _expand.secondary_panel()
	if p == null or not p.has_method("entries"):
		return null
	return p.entries()
