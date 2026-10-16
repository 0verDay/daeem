## battle_entries.gd —— 「战斗测试入口」那一块：**地图选择条 + test + campaign_test**
##
## 它原来长在主界面正中那一列里（`view/start_screen.gd`），现在整块搬进
## 「战役」按钮撑开的那块面板（`view/menu_secondary_panel.gd` 的内容区）。
##
## ★★ 为什么做成**自包含**的一块（而不是让 start_screen 建好再塞进面板）：
##   这几个控件的所有状态（选中的地图 / 选项表 / 按钮）都只属于「这一屏」——
##   面板一关就该跟着消失，不该留在主界面上当隐藏状态（那正是搬迁前的形态）。
##   ⇒ 面板开时建、关时随面板一起销毁；`selected_map_path()` 之类的读法也归这里。
##
## ★★ 选项**不是配出来的、也不是代码里写死的清单**：`logic/map_library.gd` 扫
##   `data/maps/` 下的每个目录，有几张图就有几个选项（地图 json 里的 `name` 当显示名）。
##   ⇒ 加一张新图 = 往 data/maps/ 下放个新目录，这个文件一个字都不用动。
##
## ★ 信号与访问器沿用搬迁前的名字与语义（`test_pressed(map_path)` / `map_select_button()` …），
##   于是 `view/main.gd` 那侧一行都不用改，测试也只需要先打开面板。
extends VBoxContainer

## 该进游戏了。★ 参数是**玩家选中的地图**：谁建世界（main.gd）谁就该知道建哪一张。
signal test_pressed(map_path: String)
## 按下了 campaign_test（单人战役的占位界面，见 view/campaign_test.gd）。
## ★ 它**不带载荷**：这块控件不认识战役数据 —— 谁去扫 data/campaigns/、谁去建世界，都由 main.gd 决定。
signal campaign_test_pressed()

const ConfigRes = preload("res://logic/config.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const MapSelectRes = preload("res://view/map_select.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")

var cfg: ConfigRes = null
var _font: Font = null

## ★ 选择条左边那个「地图」标签（测试按 `.../MapRowWrap/MapRow/MapLabel` 找它）
var _map_label: Label = null
## ★ 地图选择条（`view/map_select.gd`：自己画的按钮 + 自己的列表，**不是** OptionButton）
var _map_select = null
var _test_button: Button = null
var _campaign_button: Button = null
## 选择条当前的选项表（`logic/map_library.gd` 扫出来的），与控件上的顺序一一对应。
## ★ 留一份是为了让 `selected_map_path()` 有**唯一的真相**：选项下标 → 地图路径
##   只在这张表里查，不去反解按钮上的文字（文字是显示名，可能重复）。
var _maps: Array = []


func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	name = "BattleEntries"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 先扫地图目录、再搭界面：选择条的选项就是在 `_build_map_row` 里建出来的。
	_maps = MapLibraryRes.list_maps()

	var button_gap := cfg.int_val("menu.campaign_test_button_gap", 48)
	add_theme_constant_override("separation", button_gap)
	alignment = BoxContainer.ALIGNMENT_CENTER
	_build_map_row()
	_build_test_button()
	_build_campaign_button()


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

## 地图选项表（扫出来的那份）—— 给测试看「选项是不是真的来自目录扫描」。
func map_options() -> Array:
	return _maps


## 地图选择条那行控件本身 —— 给测试量几何 / 点它用。
## ⚠️ 它**不能**用节点路径找：选择条不是一个 Control 节点，按钮是 `view/map_select.gd`
##    内部持有的东西（它自己管文字与列表）。
func map_select_button() -> Button:
	return _map_select.button if _map_select != null else null


func test_button() -> Button:
	return _test_button


func campaign_test_button() -> Button:
	return _campaign_button


## 玩家当前选中的地图路径 —— ★ `test_pressed` 带出去的就是它，也是**选择条唯一的作用**。
##
## ★ 兜底规则（两种都不该让入口点不动）：
##   · 选择条还没选过 / 选中项越界 → `MapLibraryRes.default_map_path()`；
##   · 一张图都扫不到 → 同上，而它自己还会退到 `FALLBACK_MAP_PATH`。
func selected_map_path() -> String:
	var index := 0
	if _map_select != null and _map_select.selected >= 0:
		index = _map_select.selected
	if index >= 0 and index < _maps.size():
		return String((_maps[index] as Dictionary)["path"])
	return String(MapLibraryRes.default_map_path())


# ---- 选择条的只读口（**只给测试与排查用**：内部实现不泄漏出去）----

func map_select_item_count() -> int:
	return _map_select.item_count() if _map_select != null else 0


func map_select_item_text(index: int) -> String:
	return _map_select.get_item_text(index) if _map_select != null else ""


func map_select_selected() -> int:
	return _map_select.selected if _map_select != null else -1


## 让选择条选中第 index 项（等价于玩家选了它，但**不发** item_selected）。
func map_select_select(index: int) -> void:
	if _map_select != null:
		_map_select.select(index)


## ★ 列表底板当前的**不透明度**（0 = 全透明，1 = 完全不透明）。
## 给测试看「渐入 / 渐出确实在淡」：PopupMenu 是 Window，没有 modulate 可用，
## 所以淡入淡出改的是底板 StyleBox 的 alpha（见 view/map_select.gd）。
func map_select_panel_alpha() -> float:
	return _map_select.panel_alpha() if _map_select != null else 1.0


# ------------------------------------------------------------------
# 搭界面（与搬迁前逐字一致，只是父节点换成了本控件）
# ------------------------------------------------------------------

## 地图选择条：一行「地图」标签 + 一个下拉选择框。
##
## ★★ 「选择条 → test」要比「test → campaign_test」宽（`menu.map_gap` 112 vs
##    列间距 48，见 `_build_menu` 的间距口径）。列的 separation 只能是一个值，
##    所以这里把选择条那一格包进一层 MarginContainer 补上差值。
func _build_map_row() -> void:
	var wrap := MarginContainer.new()
	wrap.name = "MapRowWrap"
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var extra := maxi(0, cfg.int_val("menu.map_gap", 112)
		- cfg.int_val("menu.campaign_test_button_gap", 48))
	wrap.add_theme_constant_override("margin_bottom", extra)
	add_child(wrap)

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

	# ★ 四个态 + 列表底板都走 menu_theme：暗底 + 金线，字色是暖白。
	#   ⚠️ 下拉列表那块底板（`popup_panel`）**必须不透明**：PopupMenu 是独立窗口。
	_map_select = MapSelectRes.new()
	_map_select.build(row, _font, cfg.int_val("menu.map_select_size", 26),
		MenuThemeRes.text_normal(),
		MenuThemeRes.button_normal(),
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
## ★ 抽成一个函数：「重新扫一遍目录」只需要调它一次，测试与以后的「刷新」走同一条路。
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
	#   为什么跟它对齐、而不是无脑选第 0 项：「什么都不选直接按 test」必须有一个
	#   **与按钮上显示的一致**的结果 —— 选择条上高亮着 A、按下去却进了 B 的话，
	#   玩家会说「选择条没用」。
	var default_path := String(MapLibraryRes.default_map_path())
	var index := 0
	for i in _maps.size():
		if String((_maps[i] as Dictionary)["path"]) == default_path:
			index = i
			break
	_map_select.select(index)


func _build_test_button() -> void:
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
	# ★★ 悬停填充（必须在挂样式之前：样式那一步就要往它身上写「原字色」）
	FillButtonRes.attach_text(_test_button)
	_apply_button_styles(_test_button, false)
	_test_button.pressed.connect(_on_test_pressed)
	add_child(_test_button)


## ★ 单人战役的**占位入口**：一颗与 test 同款的按钮，摆在它**下面**。
##
## 为什么要有它：战役的数据与逻辑已经能跑，但正式入口还没做 —— 没有入口就只能靠无头脚本开局，
## 手玩验不了。所以先放这颗按钮进 `view/campaign_test.gd` 那一页（列关卡 + 选阵营 + 开始）。
##
## ★ 它**不参与**「选了哪张地图」这件事：战役进哪张图由关卡数据说了算（`level.map_id`）。
func _build_campaign_button() -> void:
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
	FillButtonRes.attach_text(_campaign_button)
	_apply_button_styles(_campaign_button, false)
	_campaign_button.pressed.connect(_on_campaign_test_pressed)
	add_child(_campaign_button)


## 把「线框」那一套样式挂到一颗 Button 上。
##
## ★ `filled` = 实心金那一档（游戏内页签 / 战役页当前选中的行用它）；
##   这里两颗按钮都是线框（false）—— 这一屏上没有「当前选中」这个概念。
## ⚠️ 字色走「登记原色」的接口（不是 add_theme_color_override）：填充动效每帧按
##   「原色 + 当前填充进度」重算，直接写 override 会被盖掉。
func _apply_button_styles(b: Button, filled: bool) -> void:
	var font_normal := MenuThemeRes.text_on_fill() if filled else MenuThemeRes.text_normal()
	FillButtonRes.set_base_font_color(b, font_normal)
	# ★★ 这两颗按钮的底是**面板的深色底**（不是实心金块）：显式告诉填充层，
	#   别让它去猜底纹 —— 猜的话会扫到 `pressed` 那格的实心金，
	#   于是「空鼠标」时也按金字底算，把白字整块换成近黑。
	FillButtonRes.set_panel_color(b, ThemeRes.bg_top())
	FillButtonRes.set_prefer_light(b, not filled)
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	if filled:
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
	# ★ 按下态仍用**实心金**：这一下要看得出来「按到了」（暗底上只换线色反馈太弱）
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_selected())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	FillButtonRes.set_latched(b, false)


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## 取 menu.* 下的颜色。★ 用 Config.parse_color 那条路（解析 "#rrggbb" / "rgba(...)"）。
func _menu_color(path: String, fallback: Color) -> Color:
	var v: Variant = cfg.get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return ConfigRes.parse_color(String(v), fallback)
	return fallback


# ------------------------------------------------------------------
# 信号
# ------------------------------------------------------------------

## ★ 按钮只该生效一次：面板收起之后这一块就销毁了，正常路径上按不到第二次；
##   这里再挡一道，是为了让「连点两下」永远不会造出第二个世界。
func _on_test_pressed() -> void:
	if not is_visible_in_tree():
		return
	test_pressed.emit(selected_map_path())


func _on_campaign_test_pressed() -> void:
	if not is_visible_in_tree():
		return
	campaign_test_pressed.emit()


## 选择条换了一项。★ 不预载地图、也不建世界：
## 选一张图只是「待会儿按 test 时进哪张」，现在载入等于把一张没人玩的地图读进内存。
func _on_map_selected(_index: int) -> void:
	pass
