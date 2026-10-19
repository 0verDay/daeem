## menu_chrome.gd —— 主界面的「版式外壳」（仿 nsoc 的主菜单）
##
## 三块（位置与尺寸全来自 `data/config.json` 的 `menu.chrome` 段）：
##   · `ProfilePnl`   左上：头像（`res://icon.svg`，**Godot 图标**当占位）+ 名字 / 资金两行；
##   · `LeftNavPnl`   左侧竖直居中：成长 / 备战 / 好友 / 藏品 / 自定义（五颗，文字**竖排**）；
##   · `RightSidePnl` 右下：上排「战役 / 演义」，下排「合作模式」。
##
## ★★ 点任意一块 → 那一块**撑满全屏**、其余两块滑出屏幕外（机制在 `view/panel_expand.gd`），
##   撑开后挂上一块面板（见 `view/menu_secondary_panel.gd`）：
##     · 「战役」那颗 → 面板内容区里是**战役菜单**（`view/campaign_menu.gd`：
##       左侧战役轮播 + 顶部关卡圆点 + 右侧关卡描述 + 长按进入，版式移植自 nsoc）；
##     · 其余各块 → 面板是空的（只有一颗「返回」）。
##
## ★ 本文件只管**版式与点击**：不认识玩法、也不建世界 —— 内容区发上来的
##   `level_activated(campaign_id, level_id)` 只往上传一层（start_screen → main.gd），
##   谁载入战役、谁建世界仍然只有 main.gd 知道。
##
## ★ 按钮的四态与悬停填充都复用现成的工厂（`menu_theme` 出样式、`fill_button` 出那片金），
##   与正中那一列按钮是同一套观感。这里没有把它抽成公共函数，是因为那一列按用户要求
##   「暂时不动」—— 为了共用去改它不划算，等它要改的时候再合并。
extends Control

## 战役菜单里长按满了某一关（面板 → 外壳 → start_screen → main.gd，见下）
signal level_activated(campaign_id: String, level_id: String)
## 合作大厅的两条开局路径（transport 已从 lobby 交出来）。
signal coop_host_started(campaign_id: String, level_id: String, transport)
signal coop_guest_started(payload: Dictionary, transport)
## ★ 首次进主界面的「三块面板滑入 + 子控件淡入」全部走完。
## 入口页落位刚切页时，正中那一列的按钮**还在 alpha 0**（面板展开层统一先清零再淡入），
## 但 Button 是吃鼠标的 —— 不等这一段结束就放行，快速点击会点到看不见的 test_1 直接开局。
signal intro_finished

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
## 「合作模式」那颗按钮（M12.4：内容区里放大厅）。
var _coop_btn: Button = null
## 这一轮是哪颗控件触发的撑开（决定面板里放不放内容）。
var _pending_btn: Control = null
## ★★ 当前**锁在满格**的那颗入口按钮（本轮新增）。
##
## 口径（用户报的「点一下立刻满、随后自己退回去」）：
##   · 按下 → 锁住（`set_latched(true)`）⇒ 那片金按 `FILL_TIME` **正向**填满后**停住**；
##   · 面板收起（`view/panel_expand.gd` 的 `reversed`）→ 解除 ⇒ 按 `DRAIN_TIME` **反向**渐出。
## 为什么必须锁：面板一撑开，外壳会把按钮的 `mouse_filter` 压成 IGNORE（让路 / 防留洞），
##   于是 `_hovered` 被自愈清掉 —— 不锁的话金会**在面板还开着的时候就退回去**。
var _latch_btn: Button = null


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
	# ★★ 收起（点「返回」/ 反向转场跑完）= 「返回」发生了 ⇒ 解除入口按钮的那个常驻满格，
	#   让那片金走反向渐出。接在 `reversed` 上而不是 `reverse()` 的入口：反向要**看得见**，
	#   等转场结束、按钮重新可见时再解除，动画才不会被藏在转场里。
	_expand.reversed.connect(_on_panel_reversed)
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
## ★ 滑入 + 子控件淡入全部跑完才发 `intro_finished`（那一列按钮到这时才真的看得见）。
func play_intro() -> void:
	if _expand == null:
		intro_finished.emit()
		return
	await _expand.play_intro()
	intro_finished.emit()


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
	if _expand == null or _expand.is_busy():
		return
	_latch_origin(btn)
	_pending_btn = btn
	_expand.expand(_nav, btn)


## ★★ 把「谁被点开了」锁成常驻满格（同一时刻只有一颗）。
##
## 为什么要在这里做而不是交给 `fill_button` 自己：只有外壳知道「这一下是**打开一个面板**、
##   而不是一次普通的按下」。面板开着期间按钮要一直亮着；面板收起由 `_on_panel_reversed` 解除。
func _latch_origin(btn: Button) -> void:
	_latch_btn = btn
	for b in _nav_buttons:
		FillButtonRes.set_latched(b, b == btn)
	for b in _side_buttons:
		FillButtonRes.set_latched(b, b == btn)


## 面板收起 = 「返回」：解除常驻 ⇒ 那片金按 `DRAIN_TIME` 反向渐出（用户要的第二段动画）。
##
## ★ 顺带**清一次悬停**：转场期间外壳把 `mouse_filter` 压成 IGNORE 又还原，
##   `fill_button._sync_hover_filter()` 会按**鼠标坐标**把悬停算回来 —— 手机端那个坐标是
##   `emulate_mouse_from_touch` 留下的模拟鼠标（还停在当初点的那颗按钮上）⇒ 不清理的话
##   「返回之后那颗按钮又自己亮起来」。桌面不受影响（真实的鼠标早就不在那儿了）。
func _on_panel_reversed() -> void:
	FillButtonRes.clear_hover_in(self)
	_latch_btn = null
	for b in _nav_buttons:
		FillButtonRes.set_latched(b, false)
	for b in _side_buttons:
		FillButtonRes.set_latched(b, false)


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
	_coop_btn = b2


func _on_side_pressed(btn: Button) -> void:
	if _expand == null or _expand.is_busy():
		return
	_latch_origin(btn)
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
		# ★★ 按下态**不能**用实心金（`button_selected()`）：那是「一按就整块亮金」的来历
		#   ——底纹是瞬时的、那片自绘金还在按 FILL_TIME 慢慢涨，两者叠在一起就是
		#   用户报的「点一下立刻满填充，随后又自己退回去」。按下只加亮描边，
		#   填充**全部**交给填充层（正向填满 → 面板开着期间锁住 → 收起时反向渐出）。
		"pressed": MenuThemeRes.button_fill_latched(),
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
## ★ 内容只在**「战役」那颗**撑开时有（战役菜单：轮播 / 关卡圆点 / 描述 / 长按进入）；
##   其余各块（资料 / 侧边栏五键 / 演义 / 合作模式）撑开的都是空面板。
func _make_secondary_panel():
	var with_campaign_menu: bool = _pending_btn != null and _pending_btn == _battle_btn
	var with_coop_lobby: bool = _pending_btn != null and _pending_btn == _coop_btn
	var p = MenuSecondaryPanelRes.new()
	p.setup(cfg, _font, _expand.transition_sec, _expand.margin,
		with_campaign_menu, with_coop_lobby)
	return p


## 面板挂上来了：把它内容区的信号往上接一层。
## ★ 面板每次撑开都是新的、收起就销毁 ⇒ 连接跟着它一起消失，不会越连越多。
func _on_panel_expanded() -> void:
	var p = _expand.secondary_panel()
	if p == null:
		return
	if p.has_signal("level_activated"):
		p.level_activated.connect(
			func(campaign_id: String, level_id: String):
				level_activated.emit(campaign_id, level_id))
	if p.has_signal("coop_host_started"):
		p.coop_host_started.connect(
			func(campaign_id: String, level_id: String, transport):
				coop_host_started.emit(campaign_id, level_id, transport))
	if p.has_signal("coop_guest_started"):
		p.coop_guest_started.connect(
			func(payload: Dictionary, transport):
				coop_guest_started.emit(payload, transport))


## 打开「合作模式」面板（test_2 按钮用；等价于点右下角那颗）。
func open_coop_panel() -> void:
	if _coop_btn != null:
		_on_side_pressed(_coop_btn)


## 当前撑开面板里那块合作大厅（`view/coop_lobby.gd`）—— 没展开 / 不是合作面板时是 null。
func coop_lobby():
	if _expand == null:
		return null
	var p = _expand.secondary_panel()
	if p == null or not p.has_method("coop_lobby"):
		return null
	return p.coop_lobby()


## 当前撑开面板里那块战役菜单（`view/campaign_menu.gd`）—— 没展开 / 空面板时是 null。
## ★ 给测试用：轮播 / 关卡圆点 / 描述面板现在住在「战役」面板里，测试要先展开「战役」再问这里。
func campaign_menu():
	if _expand == null:
		return null
	var p = _expand.secondary_panel()
	if p == null or not p.has_method("campaign_menu"):
		return null
	return p.campaign_menu()


## ★★ 把撑开的面板**立刻**收回初始态（不播动画）。
##
## 为什么需要：从战役菜单长按进入游戏时，整层菜单只是 `hide()` 了，面板还停在撑开态；
##   而「返回主菜单」之后玩家该看到的是**主界面**，不是一块开着的面板。
##   收回动画在隐藏层里没人看得见，所以直接一步到位（也避免 Tween 在隐藏期间跑一半）。
func reset_secondary_panel() -> void:
	if _expand != null:
		_expand.collapse_instant()
