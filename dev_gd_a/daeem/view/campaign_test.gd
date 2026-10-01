## campaign_test.gd —— ★ **单人战役的占位界面**（主界面 `campaign_test` 按钮点进来的那一页）。
##
## 需求原文：「为单人战役加一个占位界面吧，我要通过这个界面进入战役里面测试，
##           就在 test 下面单独放一个 campaign_test 按钮」。
##
## ★★ 它**只是占位**：按 dev_plan_7 5.1，正式的入口（战役选择条 / 关卡列表 / 简报）
##    是后面几轮的事。这一版只做「**能进得去**」最少需要的那几件：
##      · 列关卡 —— 只列**单人**（`mode == "solo"`）的关；合作关要两个席位，这一页给不了；
##      · 选阵营 —— 那一关的 `playable_ids()`，一颗按钮一个；
##      · 开始 —— 发出 `level_chosen`，由 `view/main.gd` 用 `World.create_from_level` 进游戏。
##    ⇒ 所以**没有**：战役简介、简报文本、进度 / 解锁、结算面板、返回列表（挂在 HUD 上）。
##
## ★★ 选项从哪来（这一条是刻意设计的，改之前先读）：
##   **不在本文件里扫目录**。战役数据由 `view/main.gd` 扫好、
##   连同**已经载入好的** `Campaign` 对象一起传进来（`set_campaign()`）——
##   理由与地图选择条同源（`logic/map_library.gd` 的文件头）：
##   「里面有哪些关卡 / 哪些阵营可玩」只该有**一个**来源，而且那一份数据
##   **必须与运行时读到的完全一致**。界面自己再扫一遍就会漂成两份（典型症状：
##   列表上有这一关，点进去却报「关卡读不出来」）。
##
## ⚠️ 它用的是**开场那两页**的白底配色（`menu.*`），不是 `view/ui_style.gd` 的深色 HUD 配色
##   —— 与 `view/start_screen.gd` / `view/map_select.gd` 同一个口径（那是给游戏内 HUD 用的）。
##   `menu.bg` / `menu.map_select_border_color` 这些键与主界面共用，改一处两边一起变。
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

var cfg: ConfigRes = null

var _font: Font = null
var _root: Control = null
var _bg: ColorRect = null
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
	# ⚠️ 根节点不吃鼠标（与 start_screen 同一个口径）：负责收点击的是底下那层白底。
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_bg = ColorRect.new()
	_bg.name = "Background"
	_bg.color = _menu_color("menu.bg", Color.WHITE)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	# ★ STOP：它要吃掉落在空白处的点击 —— 否则那一下会穿到下面去。
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
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
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_title", "单人战役"),
		cfg.int_val("menu.campaign_test_title_size", 40),
		_menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2))))

	# ---- 关卡区 ----
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_levels_label", "关卡"),
		cfg.int_val("menu.campaign_test_label_size", 26),
		_menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2))))
	_level_box = VBoxContainer.new()
	_level_box.name = "LevelBox"
	_level_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_level_box.add_theme_constant_override("separation", 8)
	column.add_child(_level_box)

	# ---- 阵营区 ----
	column.add_child(_make_label(
		cfg.str_val("menu.campaign_test_faction_label", "你的阵营"),
		cfg.int_val("menu.campaign_test_label_size", 26),
		_menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2))))
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

	# ★ 默认开**第一个战役**的第一关（这一版没有战役选择条，见文件头「只是占位」）。
	if not _campaigns.is_empty():
		set_campaign(_campaigns[0])


## 换一个战役（本版只有 main 在开局时调一次；留着是为了以后加战役选择条）。
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


func faction_text(index: int) -> String:
	if index < 0 or index >= _factions.size():
		return ""
	return String(_factions[index])


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
		var b := _make_button(String(_factions[i]),
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
	var border := _menu_color("menu.map_select_border_color", Color(0.2, 0.2, 0.2))
	for child in box.get_children():
		var b := child as Button
		if b == null or not b.name.begins_with(prefix):
			continue
		var idx := int(String(b.name).substr(prefix.length()))
		var on := (idx == selected)
		b.add_theme_stylebox_override("normal", _button_style(
			Color(0.82, 0.82, 0.82) if on else Color.WHITE, border, 3 if on else 2))
		b.add_theme_stylebox_override("hover", _button_style(Color(0.94, 0.94, 0.94), border, 2))
		b.add_theme_stylebox_override("pressed", _button_style(Color(0.88, 0.88, 0.88), border, 2))
		b.add_theme_stylebox_override("focus", _button_style(
			Color(0.82, 0.82, 0.82) if on else Color.WHITE, border, 3 if on else 2))


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
# 小工具（与 view/start_screen.gd 里那几个同名同义 —— 那是**白底那几页**的样式，
# 不共用那份实现：那是 CanvasLayer 的私有方法，而样式本来就只有十几行。
# ⚠️ 改配色 / 边框时两处一起改，判据是同一批 `menu.*` 键。）
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
	var color := _menu_color("menu.test_button_color", Color(0.2, 0.2, 0.2))
	for slot in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(slot, color)
	var border := _menu_color("menu.map_select_border_color", Color(0.2, 0.2, 0.2))
	b.add_theme_stylebox_override("normal", _button_style(Color.WHITE, border, 2))
	b.add_theme_stylebox_override("hover", _button_style(Color(0.94, 0.94, 0.94), border, 2))
	b.add_theme_stylebox_override("pressed", _button_style(Color(0.88, 0.88, 0.88), border, 2))
	b.add_theme_stylebox_override("focus", _button_style(Color.WHITE, border, 2))
	return b


## 白底控件用的边框样式（与 `view/start_screen.gd` 的 `_button_style` 同一个口径）。
func _button_style(fill: Color, border: Color, border_width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = fill
	s.border_color = border
	s.set_border_width_all(maxi(0, border_width))
	s.content_margin_left = 12.0
	s.content_margin_right = 12.0
	return s


## 取 `menu.*` 下的颜色（走 `Config.parse_color`，与全项目的配色写法一致）。
func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback
