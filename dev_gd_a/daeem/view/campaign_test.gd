## campaign_test.gd —— ★ **单人战役的占位界面**（主界面 `campaign_test` 按钮点进来的那一页）。
##
## 需求原文：「为单人战役加一个占位界面吧，我要通过这个界面进入战役里面测试，
##           就在 test 下面单独放一个 campaign_test 按钮」。
##
## ★★ 它**只是占位**：按 dev_plan_7 5.1，正式的入口（关卡列表 / 简报 / 进度）
##    是后面几轮的事。这一版做的是「**能进得去 + 能换战役**」：
##      · 选战役 —— ★ 一条**战役选择条**（`view/map_select.gd`，与主界面选地图同一个部件），
##        选项来自 `campaign_library.list_campaigns()` 扫 `data/campaigns/` 的结果，
##        **加一个战役目录就多一项，不改代码**（需求原话：「点击选项条后读取相应目录下的
##        战役配置项动态生成选项，玩家可以点击选项切换战役 —— 类似主界面选 test 地图」）；
##      · 列关卡 —— 只列**单人**（`mode == "solo"`）的关；合作关要两个席位，这一页给不了；
##      · 选阵营 —— 那一关的 `playable_ids()`，一颗按钮一个；
##      · 开始 —— 发出 `level_chosen`，由 `view/main.gd` 用 `World.create_from_level` 进游戏。
##    ⇒ 所以**没有**：战役简介、简报文本、进度 / 解锁、结算面板（挂在 HUD 上）。
##
## ★★ 选项从哪来（这一条是刻意设计的，改之前先读）：
##   **不在本文件里扫目录**。战役数据由 `view/main.gd` 扫好、
##   连同**已经载入好的** `Campaign` 对象一起传进来（`setup()` 的 `campaigns` 参数 +
##   `set_campaign()`）——理由与地图选择条同源（`logic/map_library.gd` 的文件头）：
##   「里面有哪些关卡 / 哪些阵营可玩」只该有**一个**来源，而且那一份数据
##   **必须与运行时读到的完全一致**。界面自己再扫一遍就会漂成两份（典型症状：
##   列表上有这一关，点进去却报「关卡读不出来」）。
##   ⇒ 选择条只是把 main 给的那张表**显示出来**，并记住「玩家选了第几项」。
##
## ⚠️ 它与开场那两页共用同一套**暗底金线**配色（`view/menu_theme.gd` + `theme.gd`），
##   不是 `view/ui_style.gd` 那套「浮在地图上的深色 HUD」（那是给游戏内用的）。
##   `menu.campaign_test_*` 那些键与主界面共用，改一处两边一起变。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##   见 docs/pitfalls.md 第五节）。
extends CanvasLayer

## 玩家选定了「哪一关 + 用哪一方」并按了开始。
## ★ 载荷是**数据**而不是「你去开哪一关」：这一层不认识 `world`，也不认识 `game_scene`，
##   谁去建世界由 `view/main.gd` 决定（它才知道游戏场景怎么挂）。
signal level_chosen(campaign, level, faction: String)
## 点了「返回」（回主界面）。
signal back_pressed()

## ★ 与开场页同一层（都是开场性质的整页）：100 = `view/start_screen.gd` 的 layer。
const LAYER := 100

const ConfigRes = preload("res://logic/config.gd")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const TextMarksRes = preload("res://view/text_marks.gd")
## ★★ 战役选择条与主界面那条地图选择条是**同一个部件**（自绘按钮 + PopupMenu）——
##    需求原话就是「类似主界面选 test 地图」。为什么不用引擎的 `OptionButton`、
##    以及「列表底板必须显式给」那个坑，都写在那份文件的文件头里，别再写第二份。
const SelectBarRes = preload("res://view/map_select.gd")
## ★★ 悬停时「金色自下而上填进来」+「选中的那一行常驻满格并增亮」
##   （见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

var cfg: ConfigRes = null

var _font: Font = null
var _root: Control = null
var _bg: Control = null
#: ★ 战役选择条（`view/map_select.gd`：自己画的按钮 + 自己的列表）
var _select = null
#: 关卡区那几块（换战役时整段重建）
var _level_box: VBoxContainer = null
#: 阵营区那几块（换关卡时整段重建）
var _faction_box: VBoxContainer = null
#: 「开始」那颗按钮（换战役 / 换关卡都会重新建它，所以要留着引用）
var _start_button: Button = null
#: 正在载入那一关（见 `_on_start_pressed`）
var _loading: bool = false

#: 当前战役（`logic/campaign.gd` 的 `Campaign`；null = 一个都没有）
var _campaign = null
#: ★ 当前选中的战役**下标**（`_campaigns` 的下标；-1 = 没得选）。
#:
#: ⚠️ 为什么不直接读选择条的 `selected`：那个属性现在**是坏的**
#:    （`view/map_select.gd`：`var selected: int = -1: get = get_selected`，
#:     而 `get_selected()` 返回的又是 `selected` 自己 ⇒ 读它永远得到 -1）。
#:    本页**记自己的那一份**，免得跟着一起坏；那条 bug 是另一个问题，没在这次改动里动它。
var _campaign_index: int = -1
#: 当前载入好的战役（`campaign_library.list_campaigns()` 的结果，由 main 传进来）
var _campaigns: Array = []
#: 当前战役里**可选**的关卡（只含单人关，按战役里的顺序）
var _levels: Array = []
#: 当前选中的关卡下标（`_levels` 的下标；-1 = 没得选）
var _level_index: int = -1
#: 这一关可玩的阵营 id（`level.playable_ids()`）
var _factions: Array = []
#: 当前选中的阵营下标（`_factions` 的下标；-1 = 没得选）
var _faction_index: int = -1


## 搭出整页。由 `view/main.gd` 在按下 campaign_test 时调一次。
##
## @param campaigns `campaign_library.list_campaigns(cfg)` 的结果（每项是个选项字典）
## @param cfg       全局配置（文案与配色都在 `menu.campaign_test_*`）
## @param font      中文字体（null = 引擎默认字体，中文会是方框）
func setup(campaigns: Array, p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	_campaigns = campaigns

	layer = LAYER
	_root = Control.new()
	_root.name = "CampaignRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ⚠️ 根节点不吃鼠标（与 start_screen 同一个口径）：负责收点击的是底下那层背景。
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bg = MenuBackgroundRes.new()
	_bg.name = "Background"
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ STOP：它要吃掉落在空白处的点击 —— 否则那一下会穿到下面去。
	#   ⚠️ mouse_filter 由 `menu_background.gd` 在 _ready 里设成 STOP
	#   （与 start_screen 用的是同一个类、同一套保证）。
	_root.add_child(_bg)

	# 整页居中：一列（标题 / 关卡 / 阵营 / 开始 / 返回）
	var center := CenterContainer.new()
	center.name = "CampaignCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var column := VBoxContainer.new()
	column.name = "CampaignColumn"
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", cfg.int_val("menu.campaign_test_gap", 20))
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(column)

	# ---- 标题 ----
	# ★ 字色走 menu_theme（暖白 = 主题的 text）——「暗底 + 金线」之后，
	#   旧那份写死的深灰（#333）在这个底上等于看不见。
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_title", "单人战役"),
		cfg.int_val("menu.campaign_test_title_size", 40),
		MenuThemeRes.text_normal()))

	# ---- 标题下那条金色细线（与入场页 / 主界面同一个装饰语言：金线 + 纯几何）----
	# ★ 它是一条**固定宽度**的 Rule，所以得包一层 CenterContainer 才能在 VBox 里居中
	#   （Rule 是自绘 Control，自己不参与「按内容撑开」）。
	var rule_wrap := CenterContainer.new()
	rule_wrap.name = "TitleRuleWrap"
	rule_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(rule_wrap)
	var rule := TextMarksRes.Rule.new()
	rule.name = "TitleRule"
	rule.line_color = ThemeRes.with_alpha(ThemeRes.line(), 0.9)
	rule.line_width = 1.0
	rule.fade = 40.0
	rule.custom_minimum_size = Vector2(280.0, 1.0)
	rule_wrap.add_child(rule)

	# ---- ★ 战役选择条（标题 + 金线下面、关卡列表上面）----
	_build_campaign_row(column)

	# ---- 关卡区 ----
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_levels_label", "关卡"),
		cfg.int_val("menu.campaign_test_label_size", 26),
		MenuThemeRes.text_dim()))
	_level_box = VBoxContainer.new()
	_level_box.name = "LevelBox"
	_level_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_box.add_theme_constant_override("separation", 8)
	column.add_child(_level_box)

	# ---- 阵营区 ----
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_faction_label", "你的阵营"),
		cfg.int_val("menu.campaign_test_label_size", 26),
		MenuThemeRes.text_dim()))
	_faction_box = VBoxContainer.new()
	_faction_box.name = "FactionBox"
	_faction_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_faction_box.add_theme_constant_override("separation", 8)
	column.add_child(_faction_box)

	# ---- 开始 + 返回 ----
	_start_button = _make_button(
		cfg.str_val("menu.campaign_test_start_text", "开始"),
		cfg.int_val("menu.campaign_test_row_size", 24),
		Vector2(cfg.num("menu.campaign_test_row_width", 360.0),
			cfg.num("menu.campaign_test_row_height", 56.0)))
	_start_button.name = "StartButton"
	_start_button.pressed.connect(_on_start_pressed)
	column.add_child(_start_button)

	var back := _make_button(
		cfg.str_val("menu.campaign_test_back_text", "返回"),
		cfg.int_val("menu.campaign_test_back_size", 20),
		Vector2(cfg.num("menu.campaign_test_back_width", 120.0),
			cfg.num("menu.campaign_test_back_height", 44.0)))
	back.name = "BackButton"
	back.pressed.connect(_on_back_pressed)
	column.add_child(back)

	# ★★ 默认开**第一个战役**的第一关（用户确认：永远默认第一个，不记上次）。
	#   `list_campaigns()` 按目录名排序，所以「第一个」是稳定可预期的。
	#   ⚠️ 也正因如此，**测试里的默认战役必须从这份表算出来**，不能写死 demo
	#      （往 data/campaigns/ 放一个新目录就会把默认值顶掉 —— 那正是这一页该有的行为）。
	if not _campaigns.is_empty():
		_refresh_campaign_options()


## ★ 战役选择条：一行「战役」标签 + 一个下拉选择框。
##
## ★★ 选项来自 `_campaigns`（= `main.gd` 扫出来的 `list_campaigns()` 结果），
##    **不写在这里**：清单写进 view 层就等于「加一个战役要改代码」，
##    而那正是需求要避免的（「读取相应目录下的战役配置项动态生成选项」）。
## ⚠️ 一个战役都扫不到时：把选择条禁用并显示兜底文案，**不**让整页崩掉
##    （与地图选择条同一套兜底：`setup()` 会跳过 `set_campaign`，于是「开始」是禁用的）。
##
## ★ 样式全部来自 `view/menu_theme.gd`（暗底 + 金线），**包括下拉列表那块底板**：
##   引擎默认的列表是浅色 HUD 皮，在这个暗金界面上弹出来会是一块刺眼的白。
func _build_campaign_row(column: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "CampaignRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 16)
	column.add_child(row)

	row.add_child(_make_label(
		cfg.str_val("menu.campaign_select_label", "战役"),
		cfg.int_val("menu.campaign_select_label_size", 28),
		_menu_color("menu.campaign_select_label_color", ThemeRes.text_dim())))

	_select = SelectBarRes.new()
	_select.build(row, _font, cfg.int_val("menu.campaign_select_size", 26),
		MenuThemeRes.text_normal(),
		MenuThemeRes.button_normal(),
		# ★ 悬停底纹用「透明底」那一档：那片金由自绘填充层给（见 view/fill_button.gd）
		MenuThemeRes.button_hover_clear(),
		MenuThemeRes.button_selected(),
		MenuThemeRes.button_normal(),
		MenuThemeRes.popup_panel(),
		MenuThemeRes.popup_row_hover(),
		Vector2(cfg.num("menu.campaign_select_width", 360.0),
			cfg.num("menu.campaign_select_height", 56.0)),
		"CampaignSelect")
	_select.item_selected.connect(_on_campaign_selected)


## 把 `_campaigns` 铺进选择条，并**按第一项载入那个战役**。
##
## ★ 抽成一个函数（而不是在 _build_campaign_row 里就地铺）：这样「换一批战役重铺」
##   只需要调它一次 —— 测试与以后可能的「刷新」按钮都走同一条路，不会漂成两份实现。
## ★ 载入第 0 个战役走的是 `_on_campaign_selected(0)`（**与玩家点第 0 项同一条路**），
##   而不是自己再拼一遍「载入 + 建列表 + 同步按钮文字」—— 那样就成第二份实现了。
## ★★ 这么写还有个实测原因（别改成「先 `select(0)` 再载入」）：按钮上那行字的同步
##   必须发生在**载入之后**，否则那一次 `select()` 会**静默不生效** —— 页面照样能开、
##   不报错，但按钮上一直是空的（探针里能看到 `_sync_text` 压根没被调到）。
##   现在这个顺序有回归断言钉着（`tests/test_campaign_test.gd` 的 `_test_campaign_selector`）。
func _refresh_campaign_options() -> void:
	if _select == null:
		return
	if _campaigns.is_empty():
		_select.set_items([cfg.str_val("menu.campaign_select_empty_text", "没有可用战役")])
		_select.select(0)
		_select.set_disabled(true)
		return
	_select.set_disabled(false)
	var names: Array = []
	for item in _campaigns:
		names.append(String((item as Dictionary)["name"]))
	_select.set_items(names)
	_on_campaign_selected(0)


## 换一个战役：载入它的配置 + 重建关卡 / 阵营两个列表。
##
## ★ 两条路都走这里，**不许各写一份**：
##   · 选择条的事件（`_on_campaign_selected` → 本函数）；
##   · 代码直接切（测试 / 以后的「返回列表」）。
## `option` 是 `campaign_library.list_campaigns()` 里的一项（字典）。
## ⚠️ 本函数**只管数据**（载入 + 建列表），不碰选择条上那行字：
##    同步那一步在 `_on_campaign_selected()` 里显式收口（理由见 `_sync_campaign_text`）。
##    ⇒ 要「按 id 直接切」的调用方请用 `campaign_select_select()` / 走选择条，
##      别绕过它直接调本函数（否则选择条上的字会与真正载入的战役对不上）。
func set_campaign(option: Dictionary) -> void:
	_campaign = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	_rebuild_levels()


## 这一页现在按下去会发生什么（`view/main.gd` 与测试都读它，别另算一份）。
func can_start() -> bool:
	if _loading or _campaign == null:
		return false
	if _level_index < 0 or _faction_index < 0:
		return false
	return true


# ------------------------------------------------------------------
# 对外状态（测试与「返回列表」这类外部调用走这几个，别去摸私有字段）
# ------------------------------------------------------------------

func campaign():
	return _campaign


## 战役选项表（`campaign_library.list_campaigns()` 扫出来的那份，由 main 传进来）。
## ★ 给测试看一眼「选项是不是真的来自目录扫描」，而不是这一页自己编的清单。
func campaign_options() -> Array:
	return _campaigns


## 现在选中的战役下标（`_campaigns` 的下标；-1 = 没得选）。
func selected_campaign() -> int:
	return _campaign_index


## 战役选择条那行控件本身（`view/map_select.gd` 造的按钮）—— 给测试量几何 / 点它用。
## ⚠️ 与主界面 `map_select_button()` 同一个理由：按钮在那个部件内部，
##    节点路径不再稳定（`.../CampaignRow/CampaignSelect` 只是按钮的名字，不是保证）。
func campaign_select_button() -> Button:
	return _select.button if _select != null else null


## 选择条里铺了几项（★ 等于扫出来的战役数；「没有可用战役」那条兜底不算）。
func campaign_select_item_count() -> int:
	return _select.item_count() if _select != null else 0


## 第 index 项那行字（战役的**显示名**）。
func campaign_select_item_text(index: int) -> String:
	return _select.get_item_text(index) if _select != null else ""


## 让选择条选中第 index 项。★ **会真的切过去**（与玩家点它同一条路）。
##   注意这与 `map_select.select()` 那种「只改状态、不发信号」不是一回事：
##   在这里「选中」就等于「载入」。
func campaign_select_select(index: int) -> void:
	if _select != null:
		_select.select(index)
	_on_campaign_selected(index)


## 可选的单人关卡（`logic/level.gd` 的 Level 数组）。
func level_options() -> Array:
	return _levels


func level_count() -> int:
	return _levels.size()


## 第 i 关的显示名（越界返回 ""）。
func level_text(index: int) -> String:
	if index < 0 or index >= _levels.size():
		return ""
	return String((_levels[index] as RefCounted).name)


func selected_level() -> int:
	return _level_index


## 这一关可玩的阵营 id 列表。
func faction_options() -> Array:
	return _factions


func faction_count() -> int:
	return _factions.size()


## 第 i 个阵营按钮上**显示的字**（越界 → ""）。
##
## ★★ 显示的是**数据里的名字**（样例第一关 = 「蓝方」/「红方」），不是 id（`F1` / `F2`）——
##    玩家要挑的是「哪一方」，看 id 还得回去对数据。
##    ⚠️ 名字只有**一个来源**：`logic/level.gd` 的 `faction_name(fid)`
##       （关卡 `factions[].name` 优先，其次地图，最后退回 id）。界面**不自己拼**。
func faction_text(index: int) -> String:
	if index < 0 or index >= _factions.size():
		return ""
	var fid := String(_factions[index])
	var lv = chosen_level()
	if lv != null and (lv as RefCounted).has_method("faction_name"):
		return String((lv as RefCounted).faction_name(fid))
	return fid


func selected_faction() -> int:
	return _faction_index


func start_button() -> Button:
	return _start_button


## 选第 i 关（越界忽略）。★ 选中之后**阵营列表会跟着重建** —— 不同关卡可玩的阵营不同。
func select_level(index: int) -> void:
	if index < 0 or index >= _levels.size():
		return
	_level_index = index
	_rebuild_factions()


func select_faction(index: int) -> void:
	if index < 0 or index >= _factions.size():
		return
	_faction_index = index
	_sync_row_styles()


## 现在选中的阵营 id（没得选 → ""）。
func chosen_faction() -> String:
	if _faction_index < 0 or _faction_index >= _factions.size():
		return ""
	return String(_factions[_faction_index])


## 现在选中的关卡（`Level`；没得选 → null）。
func chosen_level():
	if _level_index < 0 or _level_index >= _levels.size():
		return null
	return _levels[_level_index]


# ------------------------------------------------------------------
# 搭列表
# ------------------------------------------------------------------

## 重建「关卡」那一列：只列**单人**关。
##
## ⚠️ 为什么滤掉合作关：合作要**两个**玩家席位（`players[]` 恰好 2 项），
##    这一页给不了第二个席位 —— 列出来点进去只会得到「席位不够」的半成品。
##    合作入口是 dev_plan_7 5.2 的事（合作大厅 + 网络层）。
func _rebuild_levels() -> void:
	_levels = []
	_level_index = -1
	_faction_index = -1
	_factions = []
	if _level_box != null:
		for child in _level_box.get_children():
			child.queue_free()
	if _faction_box != null:
		for child in _faction_box.get_children():
			child.queue_free()

	if _campaign != null:
		for lv in _campaign.levels:
			if String((lv as RefCounted).mode) == "solo":
				_levels.append(lv)

	if _levels.is_empty():
		# 一个单人关都没有：给一行兜底文字，并把「开始」禁掉
		# （一关都没有的战役 `load_campaign` 本来就返回 null，所以这里还有
		#   「有战役、但那几关全是合作关」这一档）。
		if _level_box != null:
			_level_box.add_child(_make_label(
				cfg.str_val("menu.campaign_test_empty_text", "没有单人关卡"),
				cfg.int_val("menu.campaign_test_row_size", 24),
				_menu_color("menu.campaign_test_info_color", Color(0.4, 0.4, 0.4))))
		_sync_start_button()
		return

	# 一行一关：显示名 + 模式 / 目标（`Level.summary()` 就是干这个的，逻辑层已经算好）
	for i in _levels.size():
		var lv = _levels[i]
		var text := "%s　%s" % [String(lv.name), String(lv.summary())]
		var b := _make_button(text, cfg.int_val("menu.campaign_test_row_size", 24),
			Vector2(cfg.num("menu.campaign_test_row_width", 360.0),
				cfg.num("menu.campaign_test_row_height", 56.0)))
		b.name = "LevelButton%d" % i
		b.pressed.connect(_on_level_button.bind(i))
		_level_box.add_child(b)

	# 默认选第一关（于是阵营列表立刻有内容，玩家一进来就能按开始）
	select_level(0)


## 重建「阵营」那一列：这一关 `playable_ids()` 里的每一个。
func _rebuild_factions() -> void:
	_factions = []
	_faction_index = -1
	if _faction_box != null:
		for child in _faction_box.get_children():
			child.queue_free()
	var lv = chosen_level()
	if lv != null:
		for fid in (lv as RefCounted).playable_ids():
			_factions.append(String(fid))
	if _factions.is_empty():
		if _faction_box != null:
			_faction_box.add_child(_make_label(
				cfg.str_val("menu.campaign_test_empty_text", "没有单人关卡"),
				cfg.int_val("menu.campaign_test_row_size", 24),
				_menu_color("menu.campaign_test_info_color", Color(0.4, 0.4, 0.4))))
		_sync_start_button()
		return
	for i in _factions.size():
		# ★ 按钮上写**显示名**（蓝方 / 红方），点下去选中仍是**阵营 id**
		#   （`chosen_faction()` 返回 id —— 谁去建世界由 id 决定）。
		var b := _make_button(faction_text(i),
			cfg.int_val("menu.campaign_test_row_size", 24),
			Vector2(cfg.num("menu.campaign_test_row_width", 360.0),
				cfg.num("menu.campaign_test_row_height", 56.0)))
		b.name = "FactionButton%d" % i
		b.pressed.connect(_on_faction_button.bind(i))
		_faction_box.add_child(b)
	# 默认选第一个可玩阵营
	_faction_index = 0
	_sync_row_styles()
	_sync_start_button()


## 把「选中」这件事画在按钮上（选中的那颗用压下去的底色 + 更亮的边框）。
##
## ★ 为什么要自己画：`Button` 没有「单选组」这种东西，而这一页是两颗**一行行选**
##   的列表（不是下拉）。判据只有 `_level_index` / `_faction_index` 两处，
##   所以「哪个高亮」也只在**这里**算一次，别在别处再判一遍。
func _sync_row_styles() -> void:
	_style_row_box(_level_box, "LevelButton", _level_index)
	_style_row_box(_faction_box, "FactionButton", _faction_index)


func _style_row_box(box: VBoxContainer, prefix: String, selected: int) -> void:
	if box == null:
		return
	for child in box.get_children():
		var b := child as Button
		if b == null or not b.name.begins_with(prefix):
			continue
		var idx := int(String(b.name).substr(prefix.length()))
		var on := (idx == selected)
		# ★ 选中的那一行用**实心金**（与页签的当前页、设置按钮同一档观感）：
		#   暗底上「更粗的边框」已经不足以表示选中了（线本来就细）。
		#   ⚠️ 实心金底上的字要换成近黑（`text_on_fill`），否则暖白压金几乎读不出来。
		# ★★ 「选中」= 填充层的**常驻满格**（`set_latched`）：底色改由那层金给
		#    （它比 `button_selected()` 的那支金**更亮一档** —— 需求要的「启用后亮度变大」），
		#    于是底纹只留描边、不再画实心块（否则会把填充整个盖住）。
		FillButtonRes.set_latched(b, on)
		FillButtonRes.set_base_font_color(b,
			MenuThemeRes.text_on_fill() if on else MenuThemeRes.text_normal())
		# ★★ 底是本页的深色渐变（不是实心金块）：显式告知填充层。
		#   ⚠️ 不告知的话填充层会去扫底纹槽，扫到「金字底」那一档、把白字整块换成近黑 ——
		#      用户报的「主页面 test / campaign_test 按钮的字变成黑色」有一部分就是这条。
		#   ★ 字色口径：**未选中的那几行是白字起步、金扫上来时由白变黑**（与页签栏同一条规则）；
		#     选中那一行的原色本来就是近黑（`text_on_fill()`），它压在常驻满格的金上正好。
		#     `set_prefer_light` 是作废的历史开关，见 view/fill_button.gd。
		FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
		FillButtonRes.set_prefer_light(b, not on)
		if on:
			b.add_theme_stylebox_override("normal", MenuThemeRes.button_fill_latched())
			b.add_theme_stylebox_override("hover", MenuThemeRes.button_fill_latched())
			b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
			b.add_theme_stylebox_override("focus", MenuThemeRes.button_fill_latched())
		else:
			b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
			b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
			b.add_theme_stylebox_override("pressed", MenuThemeRes.button_selected())
			b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())


func _sync_start_button() -> void:
	if _start_button == null:
		return
	_start_button.disabled = not can_start()
	_start_button.text = cfg.str_val("menu.campaign_test_loading_text", "载入中…") \
		if _loading else cfg.str_val("menu.campaign_test_start_text", "开始")


# ------------------------------------------------------------------
# 交互
# ------------------------------------------------------------------

func _on_level_button(index: int) -> void:
	select_level(index)


func _on_faction_button(index: int) -> void:
	select_faction(index)


## ★ 选择条换了一项：**这就是「切换战役」的全部接线**。
##
## ★ 做两件事：把那一项**载入出来**（并重建关卡 / 阵营两个列表），
##   然后把「现在选中的是第几项」同步到选择条上那行字。
## ⚠️ 越界的下标直接忽略：`_refresh_campaign_options` 也会走这条（传 0），
##   而「一个战役都没有」时那一项是兜底文案，绝不能真的去载入它。
func _on_campaign_selected(index: int) -> void:
	if index < 0 or index >= _campaigns.size():
		return
	_campaign_index = index
	set_campaign(_campaigns[index] as Dictionary)
	_sync_campaign_text()


## ★★ 把「当前选中的是第几项」写回选择条上那行字，**这一步必须排在载入之后**。
##
## 不变量：**按钮上那行字 == 真正载入的那个战役**（`_campaign_index` 是唯一判据）。
## ⚠️ 实测（探针 + 回归断言）：把这次 `select()` 挪到 `set_campaign()` **之前**，
##    它会静默不生效 —— 页面照样能开、不报错，但按钮上一直是空的。
##    所以同步这一步**单独成函数、显式放在最后**，别合进上面那几句里。
func _sync_campaign_text() -> void:
	if _select == null or _campaign_index < 0:
		return
	_select.select(_campaign_index)


func _on_back_pressed() -> void:
	if _loading:
		return                          # 正在建世界，别再叠一次
	back_pressed.emit()


## ★★ 按「开始」：**先把按钮切成「载入中…」，等一帧再真的建世界**。
##
## 为什么不能直接建（实测会看到的东西）：`World.create_from_level()` 是**同步**的
## （载地图、建 14 个区划、出生十几支部队 + 三个 AI 阵营），那一帧里界面**一帧都没画过**
## —— 玩家看到的是「按下去之后卡住」，而不是「正在载入」。
## `await process_frame` 让它先画出「载入中…」那一帧，再去做重活。
##
## ⚠️ 等这一帧期间必须**挡住重复触发**：`_loading` 既是文字开关也是重入闸门
##   （`can_start()` 会因此返回 false，于是「开始」禁用、返回也点不动）。
func _on_start_pressed() -> void:
	if not can_start():
		return
	_loading = true
	_sync_start_button()
	await get_tree().process_frame
	if not is_inside_tree():
		return                          # 这一帧里被拆掉了（比如玩家退了主菜单）
	var camp = _campaign
	var lv = chosen_level()
	var fid := chosen_faction()
	_loading = false
	_sync_start_button()
	if camp == null or lv == null or fid == "":
		return
	level_chosen.emit(camp, lv, fid)


# ------------------------------------------------------------------
# 小工具（与 view/start_screen.gd 里那几个同名同义 —— 那是 CanvasLayer 的私有方法，
# 不共用那份实现：而样式本来就只有十几行。
# ★ 但**样式来源只有一个**：`view/menu_theme.gd`（暗底 + 金线），
#   本文件不再自己拼 StyleBox，免得这套皮肤在这里漂成第二份。
# ⚠️ 改配色时改 theme.gd / menu_theme.gd，不要改这里。）
# ------------------------------------------------------------------

func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# ★ 文字不吃鼠标：点在字上要算点在那颗按钮上（这条与 start_screen 同一个理由）
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


func _make_button(text: String, size: int, min_size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = min_size
	b.focus_mode = Control.FOCUS_NONE
	if _font != null:
		b.add_theme_font_override("font", _font)
	b.add_theme_font_size_override("font_size", size)
	# ★★ 悬停填充（在挂样式之前挂上：`_sync_row_styles` 就要往它身上写「原字色」）
	FillButtonRes.attach_text(b)
	# ★ 字色走 menu_theme（线框按钮上是暖白、实心金底上是近黑）——
	#   旧那份写死的深灰在暗底上读不出来（这正是「白底 → 暗底」改版会漏掉的那类地方）。
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	# ★★ 底是本页的深色渐变：显式告知填充层（见 `_sync_row_styles` 里那段说明）。
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	FillButtonRes.set_prefer_light(b, true)
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	# ★ 悬停底纹用「透明底」那一档：那片金由自绘填充给
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_selected())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	return b


## 取 `menu.*` 下的颜色（走 `Config.parse_color`，与全项目的配色写法一致）。
## ★ 现在只用于 `campaign_test_info_color` 这类**本页专属**的文案色；
##   按钮 / 底色 / 边框一律走 `view/menu_theme.gd`（那才是「暗底金线」的唯一样式来源）。
func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback
