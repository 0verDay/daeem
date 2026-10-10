## hud.gd —— 新 UI（UI 改版：**废弃**原来的「顶栏 + 右侧选中面板 + 底部日志」）
##
## 布局逐像素照参考图（1920×1080），几何全部写在 view/ui_layout.gd 里：
##
##   右上 设置（80×160）★ 点它弹出**设置二级菜单**（全屏 / 返回主菜单，见 `_build_settings_menu`）
##   左侧 部队 1~10（10 槽 × 60 高，内容动态生成）
##   左下 小地图（400×400：整张地图 + 视野框，左键点击移动镜头、按住拖动跟手，见 view/minimap.gd）
##   底栏 y 820..1080（★ 详细信息面板本版加高到 260，所以从 820 起）：
##     资源面板 200×56（**本版新增**：粮食 / 黄金**竖着排**两行；下缘压在详细信息面板顶边
##                       y=820 上、左缘与面板对齐 x=400，数值每帧读 `world.resources`，
##                       见 `_build_resource_bar()`）
##     详细信息 1030×260（左栏 = 1 + 3×3 共 10 格；右栏 = 选中单位的头像 / 名称 / 基础数值）
##       ★ 数值那一块现在**只有正文**：顶上那行「详细信息」标题按需求去掉了
##     阵营 / 盾徽 / 旗帜（150 宽，**本轮不做**，只留位置）
##     命令卡 3×3（每格 80，内容随页签实时切换）
##     页签（**按选中对象动态显示**：选中部队 = 操作 / 单位两页；选中区划中心 = 招募；
##           选中大本营 = 科技；选中普通建筑 = **一颗空页签**；什么都没选中 = 建筑 + 科技）
##     ★ 科技页的九格**不是命令卡的内容**：它由 view/tech_grid.gd 画在最上层
##       （同一个 3×3 几何），只有「科技」页才显示 —— 见 _refresh_tech_grid()
##
## ★ 仍然是纯表现：只读 world 与输入层的本地状态，从不改逻辑状态；
##   要改世界只有一条路 —— 让 input_controller 发命令（见 _on_card_entry）。
## ★ 全部用代码搭 Control 树、不建 .tscn：纯文本、可 diff、无头测试能直接实例化检查，
##   代价是不能在编辑器里可视化调布局 —— 原型阶段这个取舍仍然划算。
## ★ 事件翻译（逻辑事件 → 中文一行）**只在这里**做：逻辑层不写 UI 文案。
##
## ★★ 设置二级菜单的两个动作**不由本文件执行**（本轮新增）：
##    「全屏」与「返回主菜单」一个动的是窗口模式、一个动的是整个流程（要销毁本场景），
##    两件都是 view/main.gd 的地盘。所以这里只**发信号**，谁执行见
##    `fullscreen_toggled` / `return_to_menu_requested` 的注释。
extends CanvasLayer

## 设置菜单里点了「全屏 / 窗口化」—— ★ 只是一个请求，真正切窗口模式的是 view/main.gd
## （它同时管着 Ctrl+Q 那条快捷键，两处必须是同一份实现）。
signal fullscreen_toggled
## 设置菜单里点了「返回主菜单」—— ★ 同上：真正拆场景、把开场页放回来的是 view/main.gd。
signal return_to_menu_requested

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const SquadPanelRes = preload("res://view/squad_panel.gd")
const DetailPanelRes = preload("res://view/detail_panel.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")
const CommandCardRes = preload("res://view/command_card.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const TechGridRes = preload("res://view/tech_grid.gd")
const HoverTipRes = preload("res://view/hover_tip.gd")
const MinimapRes = preload("res://view/minimap.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

## 设置二级菜单里有几格（全屏 + 返回主菜单）。
## ★ 与 view/ui_layout.gd 的 `SETTINGS_MENU_SLOTS` 是**同一个数**：那边用它算面板高度
##   （给交互名单与测试用），这边用它算实际高度 —— 两处必须一起改。
const SETTINGS_MENU_SLOTS := 2

var cfg: ConfigRes = null
var world = null
var input_ctrl = null
var camera_rig = null
## ★★ 3D 投影助手（`view/palette.gd` 的实例）：小地图的「视野框 / 点击跳转」要用它
##    （2D 回退已随 2D 栈删除）。由 `setup()` 传进来、再原样转交给小地图。
var palette = null

var squad_panel: Control = null
var detail_panel: PanelContainer = null
var command_card: Control = null
var page_tabs: Control = null
## ★ 科技九格（盖在命令卡上，只有「科技」页才显示）。见 view/tech_grid.gd。
var tech_grid: Control = null
## ★★ 悬停详情面板（本版新增）：住在**命令卡正上方**，水平范围 = **命令卡 + 右边那一列页签**
##    那一整段（左缘对命令卡左缘、右缘对页签列右缘，宽 340），
##    高度按悬停到的文本动态缩放（向上长）。见 view/hover_tip.gd 的文件头。
var hover_tip: Control = null
var settings_button: Button = null
## ★★ 设置二级菜单（点设置按钮弹出来的那一块）：一个竖排容器，里面是
##    「全屏 / 窗口化」与「返回主菜单」两颗按钮。见 `_build_settings_menu`。
var settings_panel: Control = null
var fullscreen_button: Button = null
var return_menu_button: Button = null
## 左下角的小地图（400×400）。★ 变量名仍然是占位时代的 `map_placeholder`：
## 测试（tests/test_ui.gd）按这个名字断言它的位置与尺寸，换名字只会白改一把。
var map_placeholder: Control = null
var minimap: Control = null
var faction_placeholder: PanelContainer = null
## 资源条（粮食 / 黄金，横排）—— 详细信息面板**正上方**那一条。见 `_build_resource_bar()`。
var resource_bar: Panel = null

var _root: Control = null

## 提示行（红字，约 ui.notice_sec 秒）——「招募被拒」这类操作的可见反馈。
## ★ 它不是被删掉的日志栏：只显示**最近一次**被拒的一句话，不保留历史。
var _notice_timer: float = 0.0

## 中文字体（HUD 的 theme 里那一份）——转给需要自己 draw_string 的子控件
## （详细信息左栏的「部队方块 / 将领头像网格」）。主题里没字体时是 null，那边会退回引擎默认字体。
var _font: Font = null

## 详细信息左栏「当前展开的那支部队」的**部队编号**（1 起；0 = 还没定）。
##
## ★ 为什么要记住它：玩家点了下半某一格将领头像之后，左栏上半要一直停在那支部队上，
##   不能每一帧都被「默认第一支」抢回去。部队在 world 里是**算出来的**（没有 Squad 对象），
##   所以这里记的是**编号**（与左侧部队列表同一套口径），每帧按编号重新查那支队伍。
var _detail_troop_number: int = 0


# ------------------------------------------------------------------
# 右下「页签 + 命令卡」：显示哪几页**由当前选中的东西决定**
#
# ★★ 需求原话（这一版的核心）：
#   · 选中部队 / 单位 → 只显示两颗页签：**操作**（对部队下达的指令）+ **单位**（招募单位的页）
#   · **所有建筑都有一颗「操作」页**（第二十四节的需求）：大本营的操作页里是
#     「升级大本营」、城墙 / 箭塔是「升级它们」、区划中心是粮食 / 黄金 / 人口特化
#   · 选中区划中心   → 操作 + **招募**（三个占位将领，点了排进这个区划的招募队列）
#   · 选中大本营     → 操作 + **科技**（九条占位科技，点一下启用 / 再点弃用）
#   · 什么都没选中   → **建筑**（城墙 / 箭塔的建造入口）+ **科技**两页
#     ★ 科技那颗与选中大本营时是**同一页**（同一个 PAGE_TECH、同一套九格）——
#       需求原话：「该科技页签也会同步到选中大本营时的科技页签中」。
#
# ★ 这一层的分工：`_tab_plan()` 说「现在该有哪几页、默认停哪页」，
#   `_rebuild_card()` 说「这一页里有哪些格子」，page_tabs / command_card 什么都不判断；
#   科技九格的内容与显隐由 `_refresh_tech_grid()` 推给 view/tech_grid.gd。
# ------------------------------------------------------------------

## 当前这一屏页签属于哪一类选中（"unit" / "zone" / "base" / "building" / "empty"）。
## ★ 它是「记住玩家上次停在哪一页」的键（见 `_page_memory`）。
## ⚠️ 「什么都没选中」用它自己的 "empty" 这一档：它与选中大本营那档（"base"）
##   页列表不同，记忆必须分开 —— 否则点过大本营（停在科技页）之后，
##   一松开选中就会直接停在科技页，而空手那一屏的默认页是「建筑」。
var _tab_kind: String = ""
## ★★ 悬停面板现在**是谁**弹出来的：来源（"card" / "tech"）+ 格子序号。
## 为什么要记这一对（本轮实测踩到的顺序问题）：`mouse_exited` 与 `mouse_entered`
## **不保证**谁先到 —— 从 A 格移到 B 格时，若 B 的 enter 先到、A 的 exit 后到，
## 光凭「收到 exit 就收面板」会把 B 刚弹出来的面板收掉（表现：面板闪一下就没）。
## 所以 exit 只在**它确实是当前这一格**时才收（见 `_on_hover_out`）。
var _hover_src: String = ""
var _hover_index: int = -1
## ★★ 上一次画命令卡时算出来的**内容签名**（见 `_card_sig()`）。
## `refresh()` 每帧比一次：签名变了就重建 —— 页签组合没变、但「选中的东西」或
## 「选中对象的权威状态」变了，靠的就是这一条（手玩报的「改选箭塔还写着升级城墙」）。
var _card_sig_key: String = ""
## 上一次推给 page_tabs 的配置（kind + 页列表）。每帧比一次，不变就不重推 ——
## 否则每帧都会重建命令卡。
var _tab_key: String = ""
## 每一类选中**上次停在那一页**（kind → page）。
## ★ 为什么要记：玩家切到「单位」页排兵，点一下空地（没选中 → 建筑页），
##   再点回部队时不该被抢回「操作」页 —— 那会让「我刚看的那一页」凭空跳走。
var _page_memory: Dictionary = {}


func setup(p_cfg: ConfigRes, p_world, p_input, theme: Theme, p_camera_rig = null,
		p_palette = null) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input
	camera_rig = p_camera_rig
	# ★★ 投影助手一并收下并转交给小地图（见 `_build_minimap`）：这样小地图一建出来
	#    就拿着完整的 3D 口径，不必等调用方事后再 setup 一次。
	palette = p_palette
	_font = theme.default_font if theme != null else null

	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE     # 空白处的鼠标事件一律穿透给地图
	if theme != null:
		_root.theme = theme
	add_child(_root)

	_build_minimap()
	_build_faction_placeholder()
	# ★ 资源条要在详细信息面板**之前**建：两块在屏幕上上下紧贴，
	#   先建的那块在下层 —— 万一以后谁把资源条调高了，它压住的是面板上沿而不是反过来。
	_build_resource_bar()
	_build_detail_panel()
	_build_command_card()
	_build_page_tabs()
	# ★ 悬停面板最后建（在命令卡 / 科技九格**之上**）：它画在那两块的正上方，
	#   万一以后谁把它的高度调过头，压住的是命令卡的上沿而不是被命令卡压住。
	_build_hover_tip()
	_build_settings_button()
	_build_squad_panel()
	# ★★ 设置二级菜单**最后建**：它是「浮在别的 UI 之上」的临时面板，
	#   比设置按钮还晚挂上树 —— 顺序即层次，省得以后再调 z_index。
	_build_settings_menu()

	_rebuild_card()
	refresh()


func _process(dt: float) -> void:
	refresh()
	_tick_notice(dt)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 左下 400×400 的「地图」= 真的小地图（view/minimap.gd）：
## 整张地图 + 玩家当前的视野框 + 左键点击移动镜头 + **按住拖动跟手移视角**。
##
## ★ 结构是「有底的容器 + 自绘控件」两层：
##   外层的 PanelContainer 只提供与其它面板一致的底板 / 描边，内层的 minimap 控件
##   负责全部绘制与点击。
##   ⚠️ **外层必须是 IGNORE**：Godot 的鼠标事件从父到子传递，父控件只要是 STOP，
##      子控件的 `_gui_input` 永远收不到事件 —— 表现就是「小地图画得好好的，但点它没反应」。
##      容器不需要吃事件（它什么都不做），所以这里直接放行。
##   ⚠️ 内层用 PRESET_FULL_RECT：容器的 content margin 会让它比外层小 8px（主题给的），
##      所以不写任何坐标，让它自己跟着缩。
func _build_minimap() -> void:
	map_placeholder = PanelContainer.new()
	map_placeholder.name = "MapPlaceholder"
	map_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_placeholder.add_theme_stylebox_override("panel", UiStyleRes.panel_style(UiStyleRes.bg_soft()))
	UiLayoutRes.apply_rect(map_placeholder, UiLayoutRes.MAP_RECT, false, true)
	_root.add_child(map_placeholder)

	minimap = MinimapRes.new()
	minimap.name = "Minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_placeholder.add_child(minimap)
	minimap.setup(cfg, world, camera_rig, palette)


## 阵营 / 盾徽 / 旗帜：**本轮不做**，只按参考图把位置与占位文字放上
func _build_faction_placeholder() -> void:
	faction_placeholder = PanelContainer.new()
	faction_placeholder.name = "FactionPlaceholder"
	faction_placeholder.mouse_filter = Control.MOUSE_FILTER_STOP
	var s := UiStyleRes.panel_style()
	s.set_content_margin_all(UiLayoutRes.DETAIL_PAD)
	faction_placeholder.add_theme_stylebox_override("panel", s)
	UiLayoutRes.apply_rect(faction_placeholder, UiLayoutRes.FACTION_RECT, true, true)
	_root.add_child(faction_placeholder)

	var label := Label.new()
	label.text = "阵营\n盾徽\n旗帜"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", UiStyleRes.FS_TITLE)
	label.add_theme_color_override("font_color", UiStyleRes.text_faint())
	faction_placeholder.add_child(label)


## 资源面板：**粮食 / 黄金**两个资源，**竖着排**，落在详细信息面板左段的正上方。
##
## 需求原话：「在详细信息界面上方紧贴地图的地方加上资源显示面板，只需要显示粮食和黄金
##          两个资源，横着显示」→「面板不需要那么长，粮食和黄金栏改为竖着排列」。
##
## ★ 结构（与详细信息的数字区同一套观感）：
##     资源面板（200×56，下缘压在面板顶边 y=820 上、左缘与面板对齐 x=400）
##       ├─ [粮] 粮食 120        ← 20×20 色块（13 号「粮」）+ 右边一行 15 号字
##       └─ [金] 黄金 80         ← 第二行（色块 x 0，文字 x 26；两行 y 5 / 31）
## ★ 数值**每帧**从 `world.resources` 取（见 `_refresh_resource_bar`）：
##   它是权威值（economy.tick 往里累加、招募 / 升级从里扣），界面只在显示层格式化。
## ★ 颜色：底色 / 描边 / 字色全部走 ui_style（与其它面板同一套深色半透明）；
##   两个色块自己定（粮食暖黄、黄金亮金）—— 没有图标素材，用色块 + 一个汉字顶上。
## ★ `mouse_filter = IGNORE`：整块只有字和色块，点不动也不需要拦鼠标
##   （边缘滚屏照样能在它上面工作，见 ui_layout.interactive_rects 的规矩）。
func _build_resource_bar() -> void:
	resource_bar = Panel.new()
	resource_bar.name = "ResourceBar"
	resource_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Panel（不是 PanelContainer）：子控件按**绝对坐标**摆 —— stylebox 的 content margin
	# 只有 PanelContainer 那种容器才会套用，这里用默认那套底板就行。
	resource_bar.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line_soft()))
	UiLayoutRes.apply_rect(resource_bar, UiLayoutRes.RES_BAR_RECT, false, true)
	_root.add_child(resource_bar)

	# 两行（色块 + 文字）：**竖着排**，顺序 = 粮食（上）、黄金（下）
	var rows := [
		{"short": "粮", "color": Color(0.85, 0.72, 0.32), "y": UiLayoutRes.RES_ROW_Y},
		{"short": "金", "color": Color(0.95, 0.80, 0.20), "y": UiLayoutRes.RES_ROW2_Y},
	]
	for r in rows:
		var chip := Label.new()
		chip.name = "ResIcon_" + String(r["short"])
		chip.text = String(r["short"])
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.clip_text = true
		# 色块里那个字用 FS_SMALL（13）：20×20 的方块，13 号字实测宽 13 ≤ 20
		chip.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		chip.add_theme_color_override("font_color", Color(0.10, 0.09, 0.06))
		var cs := StyleBoxFlat.new()
		cs.bg_color = r["color"]
		cs.set_corner_radius_all(3)
		chip.add_theme_stylebox_override("normal", cs)
		resource_bar.add_child(chip)
		chip.position = Vector2(0.0, float(r["y"]))
		# ⚠️ 位置 / 尺寸都在 `add_child` **之后**设（与提示行那条同一个坑）：
		#    进树之前主题里的中文字体还没继承到，Label 会按引擎兜底字体算一次最小高度
		#    并**把 set_size 的结果夹掉**（实测：想在 24 高的条里设 16，被夹成 23 ⇒ 顶出条外）。
		chip.size = Vector2(UiLayoutRes.RES_ICON, UiLayoutRes.RES_ICON)

		var value := Label.new()
		value.name = "ResText_" + String(r["short"])
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value.clip_text = true
		# ★ 数字用 FS_BODY（15）：每行 20 高，15 号字（行高 16）装得下。
		value.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		value.add_theme_color_override("font_color", UiStyleRes.text())
		resource_bar.add_child(value)
		value.position = Vector2(UiLayoutRes.RES_TEXT_X, float(r["y"]))
		value.size = Vector2(UiLayoutRes.RES_TEXT_W, UiLayoutRes.RES_ICON)

	_refresh_resource_bar()


## 资源条上的两个数字：**每帧**从权威值（`world.resources`）重新格式化。
## ★ 取整显示（与命令卡的消耗文案同一口径，见 `_cost_text`）：
##   资源是浮点累加的，直接印会看到「119.99999」。
## ★ `world` 为 null 时按 0 显示 —— 界面不该因为逻辑层还没准备好就报错。
func _refresh_resource_bar() -> void:
	if resource_bar == null:
		return
	var res: Dictionary = {}
	if world != null:
		res = world.resources
	var pairs := [
		{"short": "粮", "key": "food", "label": "粮食"},
		{"short": "金", "key": "gold", "label": "黄金"},
	]
	for p in pairs:
		var l := resource_bar.get_node_or_null("ResText_" + String(p["short"])) as Label
		if l == null:
			continue
		l.text = "%s %d" % [String(p["label"]),
			int(round(float(res.get(String(p["key"]), 0.0))))]


func _build_detail_panel() -> void:
	detail_panel = DetailPanelRes.new()
	_root.add_child(detail_panel)
	# ★ 字体要传进去：详细信息左栏的「部队方块 / 将领头像网格」自己 draw_string，
	#   而 Godot 默认字体没有中文字形（不传就是满屏方框）。
	detail_panel.setup(world, _font)
	detail_panel.queue_cell_activated.connect(_on_queue_cell_activated)
	detail_panel.troop_activated.connect(_on_troop_activated)
	detail_panel.unit_activated.connect(_on_grid_unit_activated)
	detail_panel.building_activated.connect(_on_grid_building_activated)


func _build_command_card() -> void:
	command_card = CommandCardRes.new()
	_root.add_child(command_card)
	command_card.setup()
	command_card.entry_activated.connect(_on_card_entry)
	# ★ 科技九格**后加**（在命令卡之上）：两套内容在屏幕上完全重合，
	#   只有「科技」页时科技那一层才显示（见 _rebuild_card 末尾的 set_visible_page）。
	tech_grid = TechGridRes.new()
	_root.add_child(tech_grid)
	tech_grid.setup()
	tech_grid.cell_activated.connect(_on_tech_cell_activated)


func _build_page_tabs() -> void:
	page_tabs = PageTabsRes.new()
	_root.add_child(page_tabs)
	page_tabs.setup()
	page_tabs.page_changed.connect(_on_page_changed)


## ★★ 悬停详情面板（本版新增）—— 命令卡正上方那块说明。
##
## 需求原话：「为右下角面板中的按钮添加悬停显示，悬停显示显示在右下角面板上方，
##           宽度与右下角面板宽度相同，竖直方向距离你自己定，需要根据悬停详细信息
##           文本动态缩放」。
##
## ★ 两个控件的悬停**共用这一块面板**：命令卡的九格与科技页那九格在屏幕上逐像素
##   重合（换页时看不出换了控件），分成两块就会出现「切页那一刻旧面板还没收掉」。
##
## ★ 接线只有两条：`cell_hovered` → 弹（`_on_hover_in`）、`cell_unhovered` → 收
##   （`_on_hover_out`）。文案由 `_hover_detail()` 现取 —— 本控件不认识任何玩法概念，
##   与 command_card / tech_grid 同一条边界（它们只报「第几格」）。
func _build_hover_tip() -> void:
	hover_tip = HoverTipRes.new()
	_root.add_child(hover_tip)
	# 字体要传进去：面板高度是**量中文文本**算出来的（见 hover_tip 的文件头）
	hover_tip.setup(_font)
	command_card.cell_hovered.connect(_on_hover_in.bind("card"))
	command_card.cell_unhovered.connect(_on_hover_out.bind("card"))
	tech_grid.cell_hovered.connect(_on_hover_in.bind("tech"))
	tech_grid.cell_unhovered.connect(_on_hover_out.bind("tech"))


## 设置：参考图里它是右上角一条实心的强调色（现在是金，见 view/theme.gd）。
##
## ★★ 本轮起它**能点了**（原需求是「点不动」，现改为点开二级菜单）：
##    按下 = 弹出 / 收起 `_build_settings_menu()` 那一块（见 `toggle_settings_menu`）。
## ⚠️ `focus_mode = NONE` 保留：这一按之后焦点别停在按钮上（否则后面按空格 / 回车
##    会再触发一次设置，玩家会以为界面卡了）。
func _build_settings_button() -> void:
	settings_button = Button.new()
	settings_button.name = "SettingsButton"
	settings_button.text = cfg.str_val("settings.title", "设置")
	settings_button.focus_mode = Control.FOCUS_NONE
	settings_button.add_theme_font_size_override("font_size", UiStyleRes.FS_TITLE)
	# ★★ 初始**没有填充**（需求）：四档底纹都用「透明底 + 金线」那一档，
	#   那片金完全交给自绘填充层 —— 鼠标停上去才由下往上填，移开退回去。
	#   ⚠️ 不能再挂 `accent_button()`（那是**实心金**）：实心底会把填充盖住，
	#      观感就是「填充层在文字之上」（用户报的）。
	settings_button.add_theme_stylebox_override("normal", UiStyleRes.accent_button_clear())
	settings_button.add_theme_stylebox_override("hover", UiStyleRes.accent_button_clear())
	settings_button.add_theme_stylebox_override("pressed", UiStyleRes.accent_button_clear())
	settings_button.add_theme_stylebox_override("disabled", UiStyleRes.accent_button_clear())
	settings_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	UiLayoutRes.apply_rect(settings_button, UiLayoutRes.SETTINGS_RECT, true, false)
	settings_button.pressed.connect(toggle_settings_menu)
	# ★★ 悬停填充（一行挂上）：初始是空的，鼠标停上去才填；展开菜单时锁在满格。
	#   ★ 字色从**暖白**起步，金扫上来时由白变黑（`fill_button._sync_text()` 的唯一规则）。
	#     `set_prefer_light` 那行是**历史遗留**（开关已作废）：白字压金读不出来，
	#     正是用户报的「字被金色填充遮挡」，别把它当成「要白字」的口径。
	FillButtonRes.attach_text(settings_button)
	FillButtonRes.set_prefer_light(settings_button, true)
	FillButtonRes.set_base_font_color(settings_button, UiStyleRes.text())
	_root.add_child(settings_button)


## ★★ 设置二级菜单：设定按钮**正下方**那一块，两颗按钮 ——
##    「全屏 / 窗口化」（开关）与「返回主菜单」。
##
## ★ 位置由 `UiLayoutRes.SETTINGS_MENU_RECT` 决定（贴着设置按钮下方、靠屏幕右边），
##   高度 = 菜单里几格 × 每格高 + 间距（见 `_settings_menu_height()`）——
##   以后再加一项，改那个函数（或者干脆让它按内容自适应）即可，不必手调坐标。
## ★ 结构：外层 `PanelContainer`（提供与其它面板一致的底板 / 描边）+ 内层
##   `VBoxContainer`（排版两颗按钮）。⚠️ 外层**必须是 STOP**：这块浮在地图上，
##   点在它身上不该穿到地图去（点穿了就会顺手给单位下一条移动命令）。
## ★ 默认隐藏：进游戏时它不该占着屏幕（`_refresh_fullscreen_label()` 会把文案设对，
##   所以第一次打开时显示的就是当前窗口状态）。
func _build_settings_menu() -> void:
	settings_panel = PanelContainer.new()
	settings_panel.name = "SettingsMenu"
	settings_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	settings_panel.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line()))
	var menu_rect := UiLayoutRes.SETTINGS_MENU_RECT
	menu_rect.size.y = _settings_menu_height(SETTINGS_MENU_SLOTS)
	UiLayoutRes.apply_rect(settings_panel, menu_rect, true, false)
	_root.add_child(settings_panel)

	var column := VBoxContainer.new()
	column.name = "SettingsMenuColumn"
	column.add_theme_constant_override("separation",
		int(UiLayoutRes.SETTINGS_MENU_GAP))
	settings_panel.add_child(column)

	fullscreen_button = _make_settings_item(
		"FullscreenButton", _fullscreen_label(), _on_fullscreen_pressed)
	column.add_child(fullscreen_button)
	return_menu_button = _make_settings_item(
		"ReturnMenuButton", cfg.str_val("settings.menu_text", "返回主菜单"),
		_on_return_menu_pressed)
	column.add_child(return_menu_button)

	_refresh_fullscreen_label()
	settings_panel.hide()


## 菜单里的一颗按钮：字号 / 配色 / 三态底纹都走 ui_style（与页签同一档观感）。
func _make_settings_item(node_name: String, text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(
		UiLayoutRes.SETTINGS_MENU_RECT.size.x, UiLayoutRes.SETTINGS_MENU_ITEM_H)
	b.add_theme_font_size_override("font_size", cfg.int_val("settings.button_size", 14))
	# ★★ 初始**没有填充**（需求）：四档都是「透明底 + 金线」，那片金交给填充层。
	#   ⚠️ 挂 `accent_button()`（实心金）会把填充盖住 —— 那就是「填充层压在文字上」的观感。
	#   按下态也用同一档：这一下由填充自己给反馈（按下时悬停被钉住，金是满的）。
	b.add_theme_stylebox_override("normal", UiStyleRes.accent_button_clear())
	b.add_theme_stylebox_override("hover", UiStyleRes.accent_button_clear())
	b.add_theme_stylebox_override("pressed", UiStyleRes.accent_button_clear())
	b.add_theme_stylebox_override("disabled", UiStyleRes.accent_button_clear())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.pressed.connect(handler)
	# ★★ 悬停填充（一行挂上，见 view/fill_button.gd）。
	#   禁用时它自动换档填**灰** —— 菜单里那两颗在某些状态下不可点，
	#   鼠标停上去也该有「这里暂时不行」的反馈，而不是一点反应都没有。
	#   ★ 字色从暖白起步、金扫上来时由白变黑（与页签栏同一条规则；
	#     `set_prefer_light` 是作废的历史开关，见 view/fill_button.gd）。
	FillButtonRes.attach_text(b)
	FillButtonRes.set_prefer_light(b, true)
	FillButtonRes.set_base_font_color(b, UiStyleRes.text())
	return b


## 设置菜单的高度：N 格 × 每格高 + (N−1) 条格间距。
##
## ★ 为什么要算而不是写死一个数：格数一改（加一项 / 去掉一项），写死的高度就会
##   让最后一项被裁掉一半 —— 那是「界面看着还好、按钮点不到」的经典成因。
func _settings_menu_height(slots: int) -> float:
	var n := maxi(1, slots)
	return float(n) * UiLayoutRes.SETTINGS_MENU_ITEM_H \
		+ float(n - 1) * UiLayoutRes.SETTINGS_MENU_GAP


## 设置按钮被按下：菜单开着就收起来，关着就弹出来。
##
## ★ 做成**开关**而不是「只弹不收」：设置菜单盖着地图右侧，玩家点完设置最常见
##   的下一件事就是「继续玩」—— 再点一下设置就能收掉，比「必须点到别处」直觉。
func toggle_settings_menu() -> void:
	set_settings_menu_open(settings_panel != null and not settings_panel.visible)


## 直接指定设置菜单开 / 关（按钮之外只有测试与「返回主菜单」会用到）。
##
## ★★ 菜单开着 = 那颗按钮处于「**已启用**」那一档（常驻满格 + 更亮一档，
##    见 view/fill_button.gd 与 ui_style.accent_button_latched()）——
##    玩家一眼能看出「设置现在是展开的」，而不必回头看菜单在不在。
func set_settings_menu_open(open: bool) -> void:
	if settings_panel == null:
		return
	if open:
		_refresh_fullscreen_label()
	settings_panel.visible = open
	if settings_button != null:
		FillButtonRes.set_latched(settings_button, open)
		# ★ 两档都是**透明底 + 金线**（那片金由填充层给）：收起 = 空，展开 = 满格。
		settings_button.add_theme_stylebox_override("normal",
			UiStyleRes.accent_button_latched() if open else UiStyleRes.accent_button_clear())


## 「全屏 / 窗口化」这颗按钮现在该写什么 —— 它显示的是**按下去的后果**：
## 现在是窗口 → 写「全屏」；已经是全屏 → 写「窗口化」。
##
## ⚠️ 必须每次打开菜单都刷新（`set_settings_menu_open` 里调）：玩家可能用 Ctrl+Q
##    切过全屏，那时菜单上的字就过期了 —— 而「写着全屏、按下去却是窗口化」是最容易
##    被当成 bug 报上来的那种错。
func _refresh_fullscreen_label() -> void:
	if fullscreen_button != null:
		fullscreen_button.text = _fullscreen_label()


func _fullscreen_label() -> String:
	if _is_fullscreen():
		return cfg.str_val("settings.fullscreen_on_text", "窗口化")
	return cfg.str_val("settings.fullscreen_off_text", "全屏")


## 现在是不是全屏（含独占全屏）——与 view/main.gd 的那条判据同源。
func _is_fullscreen() -> bool:
	var mode: int = DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## 「全屏」被按下 —— ★ 只发信号：切窗口模式的是 view/main.gd
## （它同时管着 Ctrl+Q，两处必须是同一份实现，见那里的 `toggle_fullscreen`）。
func _on_fullscreen_pressed() -> void:
	fullscreen_toggled.emit()


## 「返回主菜单」被按下 —— ★ 同样只发信号：拆游戏场景、把开场页放回来都是
## view/main.gd 的事（本文件只是界面，不该去动兄弟节点）。
func _on_return_menu_pressed() -> void:
	return_to_menu_requested.emit()


func _build_squad_panel() -> void:
	squad_panel = SquadPanelRes.new()
	_root.add_child(squad_panel)
	squad_panel.setup(cfg, world, input_ctrl)


# ------------------------------------------------------------------
# 命令卡的内容（随页签切换）
# ------------------------------------------------------------------

func _on_page_changed(_page: String) -> void:
	_page_memory[_tab_kind] = String(page_tabs.page())
	_rebuild_card()


## 按当前选中对象算出「该显示哪几页」。
## ★ 需求原话见本文件上面那一段与 view/page_tabs.gd 的文件头。
func _tab_plan() -> Dictionary:
	if input_ctrl == null:
		return {"kind": "none", "pages": [], "default": ""}
	# ★★ 敌对的**单位 / 建筑**（本轮新增）：右下角**不给任何页签** ——
	#    只立一颗**空格子**（`PAGE_NONE`：没有标签、对应的命令卡也是空的）。
	#
	#    需求原话：「玩家可以选中敌对单位/建筑（且只能单个选中），但其右下角不会显示
	#              任何页签（有格子，但格子内没东西）」。
	#    ★ 为什么是「一颗空格子」而不是「一列都不画」：
	#      后者与「选中普通建筑」那条路是一致的（那一版也是空页签），而且实测截图里
	#      「整列消失」看起来像界面缺了一块。`PAGE_NONE` 就是为这件事存在的常量
	#      （见 view/page_tabs.gd 的文件头）。
	#    ★★ 它必须排在**所有分支最前面**：敌人的大本营 / 区划中心与自己的长得一样，
	#      落到下面那几条分支里会给出一整页「升级 / 特化 / 招募」——
	#      那是**给敌人下自己的命令**，逻辑层虽然会拒（拒因 faction / zone_owner），
	#      但界面上摆着一颗点了必然被拒的格子，玩家只会以为功能坏了。
	if _selected_enemy_kind() != "":
		return {"kind": "enemy", "pages": [PageTabsRes.PAGE_NONE],
			"default": PageTabsRes.PAGE_NONE}
	# 区划中心（左键点中心 = 看这个区划的详情）→ 「操作」（三个特化）+「招募」
	# ★ 本轮改动：原来这里只有「招募」一页；需求要求所有单位 / 建筑都有操作页，
	#   而区划中心的操作页就是粮食 / 黄金 / 人口特化那一页。
	# ★★ 本次改动：**只有自己 / 友军的区划才给页签**。
	#   `input_controller` 现在把**任何**归属的区划中心都交给 `select_zone`（用户需求：
	#   不论敌友中立都显示区划产能，而不是显示「区划中心的血量」），所以「能不能对它
	#   下命令」这层把关就落在这里 —— 敌方 / 中立区划只给一颗空格子（`PAGE_NONE`），
	#   与「选中敌对建筑」那条路一致（需求：选中敌对对象只立格子、不给任何页签）。
	if input_ctrl.selected_zone != null:
		if not _zone_is_friendly(input_ctrl.selected_zone):
			return {"kind": "zone_center_foreign", "pages": [PageTabsRes.PAGE_NONE],
				"default": PageTabsRes.PAGE_NONE}
		return {"kind": "zone_center",
			"pages": [PageTabsRes.PAGE_ORDER, PageTabsRes.PAGE_RECRUIT],
			"default": PageTabsRes.PAGE_ORDER}
	# ★★ 建筑：**一律有「操作」页**（需求原话：「为所有单位/建筑都添加上『操作』页签」），
	#    默认就停在它上面 —— 升级 / 特化的入口住在那儿。
	#      · 大本营   → 操作 + 科技（升级大本营那一格在操作页；科技照旧）
	#      · 区划中心 → 操作 + 招募（操作页里是粮食 / 黄金 / 人口特化）
	#      · 城墙/箭塔 → 只有操作（升级那一格）
	#    ⚠️ 区划中心在 `_tab_plan` 前面那条 `selected_zone != null` 分支里也会命中
	#      （点中心 = 看区划详情），那条分支同样给「操作 + 招募」。
	if not input_ctrl.selected_buildings.is_empty():
		var b = _primary_building()
		if b != null and b.type == BuildingRes.TYPE_BASE:
			return {"kind": "base", "pages": [PageTabsRes.PAGE_ORDER, PageTabsRes.PAGE_TECH],
				"default": PageTabsRes.PAGE_ORDER}
		if b != null and b.type == BuildingRes.TYPE_ZONE_CENTER:
			return {"kind": "zone_center", "pages": [PageTabsRes.PAGE_ORDER, PageTabsRes.PAGE_RECRUIT],
				"default": PageTabsRes.PAGE_ORDER}
		return {"kind": "building", "pages": [PageTabsRes.PAGE_ORDER],
			"default": PageTabsRes.PAGE_ORDER}
	# 选中部队 / 单位 → 「操作」+「单位」两页（默认操作）
	if not _selected_troops(input_ctrl.selected_units).is_empty():
		return {"kind": "unit", "pages": [PageTabsRes.PAGE_ORDER, PageTabsRes.PAGE_UNIT],
			"default": PageTabsRes.PAGE_ORDER}
	# 什么都没选中 → 「建筑」+「科技」两页（默认建筑）。
	#
	# ★★ 需求原话（本轮）：「当玩家什么都没选中时，原右下角只有一个建筑页签的地方
	#    添加一个科技页签，同时该科技页签也会同步到选中大本营时的科技页签中」。
	#    所以这两页是**同一颗科技页**（同一个 PAGE_TECH、同一套九格内容）——
	#    点大本营看到的那一页与空手看到的那一页是同一页，不是两份实现。
	# ★ 默认停在「建筑」：建造入口是没选中任何东西时最常用的操作，
	#   科技是「看一眼就切回来」的那种页（`_page_memory` 会记住玩家上次停在哪）。
	#
	# ⚠️ kind 写成 "empty" 而**不是** "none"：`_page_memory` 是按 kind 分桶记
	#    「这一类选中上次停在哪一页」的。选中大本营那一类（kind = "base"）只有科技一页，
	#    它在科技页上记住的 "tech" 一旦与空手这一类共用同一个桶，
	#    就会出现「点过大本营之后，空手这一屏直接停在科技页」——
	#    而空手时的默认页是建筑（手玩与测试都按这个前提起步）。
	#    两类选中的页列表不一样，记忆就必须分开。
	return {"kind": "empty",
		"pages": [PageTabsRes.PAGE_BUILD, PageTabsRes.PAGE_TECH],
		"default": PageTabsRes.PAGE_BUILD}


## 每帧把「该显示哪几页」推给 page_tabs。
##
## ★ 页列表没变（比如点完将领 1 又点将领 2）时**什么都不做** ——
##   玩家自己切到「单位」页之后，不该被下一帧抢回「操作」页。
## ★ 换了一类选中时，优先回到这一类**上次停的那一页**（`_page_memory`），
##   没有记录才用它自己的默认页。
func _sync_tabs() -> void:
	if page_tabs == null:
		return
	var plan := _tab_plan()
	var pages: Array = plan["pages"]
	var key := String(plan["kind"])
	for p in pages:
		key += "|" + String(p)
	if key == _tab_key:
		return
	_tab_kind = String(plan["kind"])
	_tab_key = key
	var preferred := String(_page_memory.get(_tab_kind, plan["default"]))
	page_tabs.set_pages(pages, preferred)
	_rebuild_card()


## 现在该显示 / 操作哪个区划的招募队列与招募页：
##   · 点区划中心 → 它是 `selected_zone`；
##   · 万一那栋中心建筑是**从别的路**被选进 `selected_buildings` 的（框选选不到它，
##     见 input_controller.box_select 的过滤），这里也能从它的格子反查出所属区划。
func _recruit_zone():
	if input_ctrl == null or world == null:
		return null
	if input_ctrl.selected_zone != null:
		return input_ctrl.selected_zone
	var b = _primary_building()
	if b != null and b.type == BuildingRes.TYPE_ZONE_CENTER:
		return world.zone_center_zone_at(b.tx, b.ty)
	return null


## ★★ 右栏右上角那块面板显示什么（**三种内容共用一个控件**，见 view/recruit_queue.gd）：
##   ① 建筑升级 / 区划特化的**单条读条**（本轮新增 —— 需求：可以复用招募单位的面板）；
##   ② 区划中心自己的**招募队列**（点中心 → 招募页那套，原本就有）；
##   ③ 都没有 → 收起来。
##
## @param holder 当前主选中的东西：**区划字典**（选中区划详情）或**建筑**（选中建筑）
##
## ★ 优先级是「读条 > 队列」：同一块地方，正在读条的那件事更该被看见。
func _refresh_progress_panel(holder) -> void:
	if holder == null:
		detail_panel.set_queue(null)
		return
	# 选中「区划详情」时，读条挂在区划字典上；选中「建筑」时要分建筑升级 / 它所属区划的特化
	var zone = null
	var b = null
	if typeof(holder) == TYPE_DICTIONARY:
		zone = holder
	else:
		b = holder
		if b.type == BuildingRes.TYPE_ZONE_CENTER:
			zone = world.zone_of_center_building(b)

	# ① 建筑升级读条
	if b != null and b.is_upgrading():
		detail_panel.set_progress_bar(
			"升级%s" % b.display_name(),
			"升 %d 级" % (b.level + 1),
			b.upgrade_progress(), b.upgrade_eta(), true)
		return
	# ② 区划特化读条（做特化 / 取消特化）
	if zone != null and world.zone_spec_busy(zone):
		var is_cancel: bool = world.zone_spec_is_cancel(zone)
		var done := String(zone.get("spec_done", ""))
		var who := String(cfg.spec_entry(done).get("name", done)) if is_cancel else \
			String(cfg.spec_entry(String(zone.get("spec_kind", ""))).get("name", ""))
		detail_panel.set_progress_bar(
			("取消%s" % who) if is_cancel else who,
			("取消特化" if is_cancel else "特化中"),
			world.zone_spec_progress(zone), world.zone_spec_eta(zone),
			not is_cancel)      # ★ 「取消特化」这条读条本身不可再取消
		return
	# ③ 区划中心的招募队列（原本就有的那套）
	var rz = _recruit_zone()
	detail_panel.set_queue(rz, rz != null)


## 按当前页重组命令卡。
##
## 六张表都是**数据驱动 / 固定文案**的，这里不写死兵种名：
##   建筑页 ← config.json 的 building 段里 buildable = true 的那几项（默认是城墙 / 箭塔）
##   单位页 ← config.json 的 recruit.list（现在只有一项：占位单位 = 招募亲兵）
##   招募页 ← config.json 的 recruit.zone.list（三个占位将领，排进**区划**的队列）
##   操作页 ← `_order_entries()`（对当前选中的部队下达的指令）
##   科技页 ← config.json 的 tech.list（九条占位科技）—— ★ 它**不走命令卡**：
##            九格由 view/tech_grid.gd 画（另一套三态样式 + 两行文字），
##            所以这里把命令卡清空、再让科技那一层显示出来。
## 键位按参考图顺序 Q/W/E/A/S/D/Z/X/C 依次分配（第 0 项 = Q）。
##
## ★★ `rebuild_card()` 是**给界面与测试的公开入口**：正常流程里由 `_sync_tabs()` /
##   `_on_page_changed()` / 建筑操作那两条命令流调它；单独留一个公开名是为了
##   「权威状态被**外部**改了」的场合 —— 最典型的是测试：`world.tick()` 推进读条之后，
##   界面那一格还没重画。
func rebuild_card() -> void:
	_rebuild_card()


func _rebuild_card() -> void:
	if command_card == null:
		return
	var entries: Array = []
	var page := String(page_tabs.page()) if page_tabs != null else ""
	match page:
		PageTabsRes.PAGE_BUILD:
			# ★★ 本轮起读 **config.json 的 building 段**（`buildable = true` 的那几项），
			#    不再是写死的 `BuildingRes.DEFS`：编辑器里新加的建筑要真的出现在这一页，
			#    名字 / 说明 / 快捷键也跟着数据走。
			for d in cfg.buildable_building_defs():
				entries.append({
					"type": "build",
					"build_type": String(d.get("id", "")),
					"name": String(d.get("name", "")),
					"desc": "%s（快捷键 %s，也可点这一格）" % [String(d.get("desc", "")),
															String(d.get("hotkey", ""))],
				})
		PageTabsRes.PAGE_UNIT:
			entries = _recruit_entries("recruit", "recruit.list")
		PageTabsRes.PAGE_RECRUIT:
			entries = _recruit_entries("zone_recruit", "recruit.zone.list")
		PageTabsRes.PAGE_ORDER:
			# ★★ 本轮起「操作」页**不只属于部队**：选中建筑时它画的是
			#    升级 / 特化那一套（需求：「为所有单位/建筑都添加上『操作』页签」）。
			entries = _order_entries_for_selection()
	command_card.set_entries(entries)
	# ★★ 记下「这一屏是按哪个签名画的」：`refresh()` 每帧比一次，签名一变就重建
	#    （见 `_card_sig()`）。写在**画完之后**：中间任何一步改了会进签名的状态，
	#    下一帧都会被重新比出来，不会漏。
	_card_sig_key = _card_sig()
	# ★ 换页 = 换了九格的内容（甚至换了**哪一层**在画：科技页是 tech_grid 盖在上面）：
	#   悬停面板必须跟着收起来。
	#   ⚠️ 为什么非显式收不可：鼠标正停在一格上时把那一层**藏起来**（切页会把 tech_grid
	#      整个隐藏），Godot **不会**补发 `mouse_exited` —— 不收的话那块说明会一直挂在
	#      屏幕右上角，看着像界面卡死了。
	_dismiss_hover()
	# ★ 科技那一层只有「科技」页才显示。这一句放在这里（而不是只放在 refresh 里）：
	#   `_rebuild_card` 是「页变了」那一刻同步跑的，玩家切页那一下
	#   **必须立刻**把九格盖上 / 掀开 —— 等到下一帧才变就是肉眼可见的一帧错页。
	_refresh_tech_grid(page == PageTabsRes.PAGE_TECH)


## 把科技九格的内容推给 view/tech_grid.gd。
##
## @param visible 这一屏现在是不是「科技」页 —— 不是的话整块盖起来（命令卡照常画）。
##
## ★★ 它由 `refresh()` **每帧**调用，而**不是**挂在 `_rebuild_card()` 里：
##   `_rebuild_card` 只在「页签组合变了 / 玩家切页」时才跑（`_sync_tabs` 有短路），
##   而科技九格的高亮取决于**权威的启用状态** —— 玩家点一下格子就会变，
##   那时页签组合一点没变。挂在 `_rebuild_card` 里的话，
##   点上去要等下一次切页才看见高亮（实测就是这个症状）。
##   ⚠️ 每帧调不会白花钱：tech_grid 内部比对内容，没变就什么都不做。
##
## ★ 内容**照旧更新**（哪怕这一页没显示）：切回科技页时不会闪一下空白，
##   而且「大本营的科技页」与「空手的科技页」共用这一份数据（同一颗页签、同一套九格）。
func _refresh_tech_grid(visible: bool) -> void:
	if tech_grid == null or world == null:
		return
	tech_grid.set_entries(world.tech_entries())
	tech_grid.set_visible_page(visible)


# ------------------------------------------------------------------
# ★★ 悬停详情面板：内容（本版新增）
#
# 需求原话：「为右下角面板中的按钮添加悬停显示……需要根据悬停详细信息文本动态缩放。
#           目前只需要为**区域的特化，招募的单位 / 将领，科技，建筑**这些内容
#           添加详细信息即可」。
#   ⇒ 这一节只给这四类**格子内容**产出文案；其余（操作页对部队下达的那几条指令：
#     移动 / 攻击 / 行军 / 停止）返回空字典 ⇒ **不弹面板**（而不是弹一块空的）。
#
# ★ 为什么文案在 hud 而不在两个格子控件里：
#   与「拒因码 → 中文」同一条约定（见 recruit_reject_text 那一段）——**界面词只在这
#   一个文件里**。command_card / tech_grid 只报「第几格」，数值与说明在这里按
#   config 与**权威状态**现取，于是不会出现「界面写着旧数值」那种漂移。
# ------------------------------------------------------------------

## 鼠标进入某一格。@param src "card"（命令卡）/"tech"（科技九格）
func _on_hover_in(index: int, src: String) -> void:
	_hover_src = src
	_hover_index = index
	var d := _hover_detail(src, _hover_entry(src, index))
	if d.is_empty():
		# 这一格还没有悬停详情（本版只做了四类内容）—— 收起来，不留一块空面板
		hover_tip.clear()
		return
	hover_tip.show_text(String(d.get("title", "")), String(d.get("body", "")))


## 鼠标离开某一格。★ 只有「确实是我这一格」才收 —— 见 `_hover_src` 那段说明
## （enter / exit 的先后顺序不保证，无脑收会把刚弹出来的面板闪掉）。
func _on_hover_out(index: int, src: String) -> void:
	if src != _hover_src or index != _hover_index:
		return
	_dismiss_hover()


## 收起悬停面板，并清掉「现在是谁弹的」那个记号
func _dismiss_hover() -> void:
	_hover_src = ""
	_hover_index = -1
	if hover_tip != null:
		hover_tip.clear()


## 悬停到的那一格数据。命令卡与科技九格是**两份不同形状**的 entries，所以按来源取。
func _hover_entry(src: String, index: int) -> Dictionary:
	if src == "tech":
		return tech_grid.entry_at(index) if tech_grid != null else {}
	return command_card.entry_at(index) if command_card != null else {}


## 某一格的悬停详情：`{title, body}`；**空字典 = 这一格没有详情**（不弹面板）。
##
## 本版覆盖的四类（就是需求点的那四样）：
##   · **建筑**         → `build`（建筑页的城墙 / 箭塔）+ 建筑那一格升级
##                        （`building_upgrade` / 取消 / 已满级）
##   · **招募单位 / 将领** → `recruit`（单位页：长枪兵 / 长弓兵 / 骑手）+
##                        `zone_recruit`（招募页：将领 1/2/3）
##   · **区域的特化**    → `zone_specialize`
##   · **科技**          → 科技九格（那一份数据没有 `type`，按 `src == "tech"` 分派）
func _hover_detail(src: String, entry: Dictionary) -> Dictionary:
	if entry.is_empty():
		return {}
	if src == "tech":
		return _hover_tech(entry)
	match String(entry.get("type", "")):
		"build":
			return _hover_build(entry)
		"recruit", "zone_recruit":
			return _hover_recruit(entry)
		"zone_specialize":
			return _hover_spec(entry)
		"zone_spec_cancel", "zone_spec_bar_cancel":
			return _hover_spec_cancel(entry)
		"building_upgrade", "building_upgrade_cancel", "building_upgrade_max":
			return _hover_building(entry)
		"revive", "revive_cancel":
			return _hover_revive(entry)
	return {}


## 拼一块悬停详情：`body` 是**多行**文本（每行一个字段），空行自动丢掉。
## ★ 面板按 `HOVER_W`（= 命令卡 240 + 页签列 100 = 340）的宽**折行**（见 view/hover_tip.gd），
##   所以这里只负责「给哪几句」，
##   不管每句多长 —— 长句子不会被裁掉，只会多占几行。
func _hover_text(title: String, lines: Array) -> Dictionary:
	var clean: Array[String] = []
	for l in lines:
		var s := String(l)
		if s != "":
			clean.append(s)
	return {"title": title, "body": "\n".join(clean)}


## 条目里那一小份造价（招募表带过来的；缺了就是空 → `_cost_text` 写「免费」）
func _entry_cost(entry: Dictionary) -> Dictionary:
	var v: Variant = entry.get("cost", {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


## 建筑（建筑页那两格：城墙 / 箭塔）—— 说明 + 血量 + 攻击（箭塔）+ 占地 + 造价 + 快捷键。
## ★ 数值全部来自 `config.json` 的 `building.<type>.*`，与 logic/building.gd 读的是同一份；
##   `tower.hp_max` 在 config 里没写（走建筑的兜底 300），这里也用同一个兜底值。
func _hover_build(entry: Dictionary) -> Dictionary:
	var t := String(entry.get("build_type", ""))
	var lines: Array = []
	lines.append(cfg.str_val("building.%s.desc" % t, ""))
	lines.append("血量上限 %s" % _fmt_num(cfg.num("building.%s.hp_max" % t, 300.0)))
	if t == BuildingRes.TYPE_TOWER:
		lines.append("攻击 %s / 射程 %s 格 / 间隔 %ss" % [
			_fmt_num(cfg.num("building.tower.damage", 0.0)),
			_fmt_num(cfg.num("building.tower.range", 0.0)),
			_fmt_num(cfg.num("building.tower.cooldown", 0.0))])
	lines.append("本体占格 %d%%（居中；本体之外的缝隙走得过去）" % int(round(
		cfg.building_body_scale(t) * 100.0)))
	var cost: Variant = cfg.get_path_value("building.%s.cost" % t)
	lines.append("造价 %s" % _cost_text(cost if typeof(cost) == TYPE_DICTIONARY else {}))
	lines.append("快捷键 %s（也可点这一格进入建造模式）" % cfg.str_val("building.%s.hotkey" % t, ""))
	return _hover_text(String(entry.get("name", "")), lines)


## 招募：单位页那几个兵种（`recruit`）+ 招募页那三个将领（`zone_recruit`）。
##
## ★ 将领与兵种的数值是**同一张表**：都按 `cfg.unit_type_of(kind)` 查兵种
##   （「将领的数值 = 它所属兵种」，见 logic/config.gd 的 unit.* 那一段），
##   两者只差两点：占谁的队列、人口从哪个区划扣。
func _hover_recruit(entry: Dictionary) -> Dictionary:
	var kind := String(entry.get("unit_kind", ""))
	var ut := cfg.unit_type_of(kind)
	# ★ 将领类（general / general_N）有序号：它的数值可能是**这位将领自己的覆盖**
	#   （config 的 unit.general.stats，编辑器里那个「自定 / 跟随」）。
	var gidx: int = ConfigRes.general_index_of(kind)
	var is_zone := String(entry.get("type", "")) == "zone_recruit"
	var lines: Array = []
	lines.append(String(entry.get("desc", "")))
	if cfg.has_unit_type(ut):
		if gidx >= 0:
			# 将领：覆盖 ⊕ 所属兵种（与单位身上用的同一套数据，见 config.gd）
			lines.append("血量 %s" % _fmt_num(cfg.general_hp_at(gidx)))
			var gc: Dictionary = cfg.general_combat_at(gidx)
			lines.append("攻击 %s / 射程 %s 格 / 间隔 %ss" % [
				_fmt_num(float(gc.get("damage", 0.0))),
				_fmt_num(float(gc.get("range", 0.0))),
				_fmt_num(float(gc.get("cooldown_sec", 0.0)))])
			lines.append("速度 %s 格/秒" % _fmt_num(cfg.general_speed_at(gidx)))
		else:
			lines.append("血量 %s" % _fmt_num(cfg.unit_hp_of(ut)))
			var c := cfg.unit_combat_of(ut)
			lines.append("攻击 %s / 射程 %s 格 / 间隔 %ss" % [
				_fmt_num(float(c.get("damage", 0.0))),
				_fmt_num(float(c.get("range", 0.0))),
				_fmt_num(float(c.get("cooldown_sec", 0.0)))])
			lines.append("速度 %s 格/秒" % _fmt_num(cfg.unit_speed_of(ut)))
		lines.append("兵种 %s" % cfg.unit_class_line(ut))
	lines.append("造价 %s" % _cost_text(_entry_cost(entry)))
	var pop := int(entry.get("population_cost", 0))
	if pop > 0:
		lines.append("占用人口 %d（%s）" % [pop,
			"从本区划的人口里扣" if is_zone else "从将领所在区划的人口里扣"])
	var train: float = float(entry.get("train_sec", 0.0))
	if train > 0.0:
		lines.append("读条 %s 秒%s" % [_fmt_num(train),
			"" if is_zone else "（挂在将领名下，读条期间它不能动）"])
	return _hover_text(String(entry.get("name", "")), lines)


## 濒死将领那颗「再起 / 取消再起」（本轮新增）—— 说明 + 造价 + 读条 + 当前状态。
##
## ★ 数值全部取自**权威侧**（`world.revive_*` 与选中的那个将领的实时血量），
##   与界面上那颗格子的文案同一个出处 —— 不会出现「说明写着 10%、格子却要求 15%」。
func _hover_revive(entry: Dictionary) -> Dictionary:
	var leader = input_ctrl.first_selected_leader() if input_ctrl != null else null
	var lines: Array = []
	lines.append(String(entry.get("desc", "")))
	if leader != null and leader.is_downed():
		var pct := int(round(leader.hp_ratio() * 100.0))
		lines.append("当前血量 %d%%（上限 %d%%）" % [
			pct, int(round(cfg.revive_regen_cap_ratio * 100.0))])
		lines.append("回复速度：每 %s 秒回 %d%% 上限（濒死期间只增不减、也不会挨打）" % [
			_fmt_num(cfg.revive_regen_sec), int(round(cfg.revive_regen_ratio * 100.0))])
		if leader.is_reviving():
			lines.append("再起读条中：还剩 %s 秒（进度 %d%%）" % [
				_fmt_num(leader.revive_remaining),
				int(round(leader.revive_progress() * 100.0))])
		else:
			lines.append("再起点：血量 %d%%（现在 %d%%）" % [
				int(round(world.revive_ready_ratio() * 100.0)), pct])
		lines.append("再起造价 %s　读条 %s 秒" % [
			_cost_text(world.revive_cost()), _fmt_num(world.revive_channel_sec())])
		lines.append("★ 再起后血量**保持不变**；它辖下的部队已在向它集结")
	return _hover_text(String(entry.get("name", "再起")), lines)


## 区域的特化（选中区划中心 → 操作页里那几格）—— 说明 + 效果 + 造价 + 读条 + 「只能选一个」。
## ★ 「能做哪几档」由区划种类白名单决定（`config.zone_kind.list[].specs`），
##   操作页上**只画允许的那几格**，所以这里不必再重复一遍限制条件。
func _hover_spec(entry: Dictionary) -> Dictionary:
	var id := String(entry.get("spec", ""))
	var e := cfg.spec_entry(id)
	var lines: Array = []
	lines.append(String(e.get("desc", entry.get("desc", ""))))
	var line := String(e.get("line", ""))
	if line != "":
		lines.append("效果 %s" % line)
	lines.append("造价 %s" % _cost_text(cfg.spec_cost(id)))
	lines.append("读条 %s 秒" % _fmt_num(cfg.spec_time_sec(id)))
	lines.append("一个区划只能选一种特化；选错了可以在操作页取消（取消也要读条，全额退款）")
	return _hover_text(String(entry.get("name", e.get("name", ""))), lines)


## 「取消特化」那两格（读条中 / 已特化）—— 说明 + **这一单是哪一档** + 退款提醒。
## ★ 它同样属于需求点名的「区域的特化」：旁边那两格（粮食 / 黄金特化）有详情，
##   同一排的「取消特化」没有就说不过去。
## ★ 目标区划与操作页画格子用同一条判据（`_recruit_zone()`：选中区划，或从区划中心反查）。
func _hover_spec_cancel(entry: Dictionary) -> Dictionary:
	var lines: Array = [String(entry.get("desc", ""))]
	var z = _recruit_zone()
	if z != null and typeof(z) == TYPE_DICTIONARY:
		var zd: Dictionary = z
		var done := String(zd.get("spec_done", ""))
		var busy := String(zd.get("spec_kind", ""))
		var which := busy if busy != "" else done
		if busy != "":
			var eta: float = world.zone_spec_eta(zd)
			lines.append("%s：%s，还剩 %s 秒" % [
				"正在取消特化" if world.zone_spec_is_cancel(zd) else "正在特化",
				String(cfg.spec_entry(busy).get("name", busy)), _fmt_num(eta)])
		elif done != "":
			lines.append("当前特化：%s（%s）" % [
				String(cfg.spec_entry(done).get("name", done)),
				String(cfg.spec_entry(done).get("line", ""))])
		if which != "":
			lines.append("撤掉之后全额退还：%s" % _cost_text(cfg.spec_cost(which)))
		lines.append("取消特化也要读条（读完才真的撤掉）")
	return _hover_text(String(entry.get("name", "")), lines)


## 建筑「操作」页那几格（升级 / 取消升级 / 已满级）—— 那一格的说明 + 等级 + 血量 + 下一级的上限。
## ★ 目标建筑与操作页画格子用的是**同一条判据**（选中区划时从中心格反查那栋建筑），
##   见 `_building_order_entries`。
func _hover_building(entry: Dictionary) -> Dictionary:
	var b = _primary_building()
	if b == null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	var lines: Array = []
	# ⚠️ 这里**故意不写** `building.<type>.desc`：大本营那句「开局自带，不可建造，不可拆除」
	#    是用户明确要求从界面上撤掉的（见 `_building_text` 的注释）。
	#    建筑的说明只有**建造那一格**（`_hover_build`）才写 —— 那是玩家真正需要它的地方。
	lines.append(String(entry.get("desc", "")))
	if b != null:
		var kind := String(entry.get("type", ""))
		lines.append("当前等级 %d / %d" % [b.level, world.building_max_level(b.type)])
		lines.append("血量 %s / %s" % [_fmt_num(b.hp), _fmt_num(b.hp_max)])
		if kind == "building_upgrade":
			var nxt: int = b.level + 1
			var mult: float = cfg.upgrade_hp_mult(b.type, nxt)
			lines.append("升到 %d 级：血量上限 ×%s ⇒ %s" % [
				nxt, _fmt_num(mult), _fmt_num(b.base_hp_max * mult * b.tech_hp_mult)])
		elif kind == "building_upgrade_cancel":
			lines.append("已经扣掉：%s（取消后全额退还）" % _cost_text(
				{"food": b.upgrade_cost_food, "gold": b.upgrade_cost_gold}))
	return _hover_text(String(entry.get("name", "")), lines)


## 科技九格 —— 说明 + 效果那一行 + 当前启用状态（含「最多几条 / 现在几条」）。
## ★ 状态读的是**权威状态**（`world.is_tech_active`），界面不自己记一份「哪几格亮着」。
func _hover_tech(entry: Dictionary) -> Dictionary:
	var id := String(entry.get("id", ""))
	var lines: Array = []
	lines.append(String(entry.get("desc", "")))
	var line := String(entry.get("line", ""))
	if line != "":
		lines.append("效果 %s" % line)
	var on: bool = world != null and world.is_tech_active(id)
	var max_n: int = world.tech_max_active() if world != null else 0
	var used: int = max_n - (world.tech_remaining_slots() if world != null else 0)
	lines.append("状态 %s（同一时间最多启用 %d 条，现在 %d / %d）" % [
		"已启用" if on else "未启用", max_n, used, max_n])
	lines.append("点这一格 = %s" % ("弃用（把名额让出来）" if on else "启用"))
	return _hover_text(String(entry.get("name", "")), lines)


## 把一张招募表（recruit.list / recruit.zone.list）翻成命令卡的条目。
## @param entry_type 抛给 hud._on_card_entry 的动作类型（"recruit" = 排进将领 / "zone_recruit" = 排进区划）
func _recruit_entries(entry_type: String, cfg_path: String) -> Array:
	var out: Array = []
	var list: Variant = cfg.get_path_value(cfg_path) if cfg != null else null
	if typeof(list) != TYPE_ARRAY:
		return out
	for item in (list as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		out.append({
			"type": entry_type,
			"unit_kind": String(e.get("kind", "")),
			"name": String(e.get("label", e.get("kind", ""))),
			"desc": String(e.get("desc", "")),
			# ★★ 悬停详情要用的三个字段，一并带在条目里（见 `_hover_recruit`）：
			#   两张招募表（recruit.list / recruit.zone.list）字段名一样，
			#   所以「单位页」与「招募页」的详情共用同一段代码，不各写一份。
			"cost": e.get("cost", {}),
			"train_sec": e.get("train_sec", 0.0),
			"population_cost": e.get("population_cost", 0),
		})
	return out


## 「操作」页的四格：对**当前选中的部队**下达的指令（需求原话：「如移动，攻击，行军等」）。
## ★ 前三格是「进命令模式 → 左键点地图 / 点目标」那种两步式（见 input_controller.order_mode）；
##   「停止」不需要目标，点一下当场生效。
## ★ 键位按命令卡的顺序 Q/W/E/A…（第 4 格是 A），与其它页同一套规则。
##
## ★★ 将领**濒死**时，第一格换成「再起 / 取消再起」（本轮新增）——
##   用户原话：「若其血量回复至 10% 及以上，则其操作栏中会出现『再起』按钮，
##   点击后可消耗资源使其脱离濒死状态重新投入战斗」。
##   ⚠️ 只用**一格**：濒死将领不能移动 / 攻击 / 行军，那三格摆着也是点了没用
##      （点了会被逻辑层拒），所以整页只留「再起」这一格。
func _order_entries() -> Array:
	return [
		{"type": "order", "mode": "move", "name": "移动",
			"desc": "点这一格后，左键点地图下达移动命令（遇敌不停）"},
		{"type": "order", "mode": "attack", "name": "攻击",
			"desc": "点这一格后，左键点敌方单位 / 建筑下达攻击命令"},
		{"type": "order", "mode": "attack_move", "name": "行军",
			"desc": "点这一格后，左键点地图下达行军攻击（路上遇敌就停下来打）"},
		{"type": "order", "mode": "stop", "name": "停止",
			"desc": "就地停止，并清掉移动 / 攻击 / 行军攻击（点一下立刻生效）"},
	]


## ★★ 濒死将领的「操作」页（本轮新增）。
##
## 三种状态各一格，互斥（与建筑升级那一套同一种写法）：
##   ① 血量还没回到 `revive.ready_ratio`（默认 10%）→ 一颗**说明用**的格子
##      （名字就叫「再起」，`revive` 类型 + `ready = false`，界面把它画灰）；
##   ② 到 10% 且没在读条 → 真正可点的「再起」（带造价与读条时间）；
##   ③ 正在读条 → 「取消再起」（全额退款）。
##
## ★ 判据**全部来自权威侧**（`unit.revive_ready()` / `world.revive_cost()` /
##   `world.revive_ready_ratio()`）：界面不自己复算一遍「够不够 10%」——
##   那会变成两份规则，一旦漂开就会出现「格子亮着、点下去被拒」这种最恼人的状态。
func _revive_entries(leader) -> Array:
	# ⚠️ 这里**不能用** `:=`：`leader.revive_ready(cfg)` 是动态调用，
	#    返回值没有确定类型（GDScript 会报 "Cannot infer the type of ready variable"）。
	var ready: bool = leader.revive_ready(cfg)
	var cost_text: String = _cost_text(world.revive_cost())
	var channel: String = _fmt_num(world.revive_channel_sec())
	if leader.is_reviving():
		return [{
			"type": "revive_cancel",
			"name": "取消再起",
			"desc": "撤掉正在读条的再起，**全额退还**已经扣掉的%s（%s）" % [cost_text, channel],
			"ready": true,
		}]
	var need_pct := int(round(world.revive_ready_ratio() * 100.0))
	if not ready:
		return [{
			"type": "revive",
			"name": "再起",
			"desc": "血量回复到 %d%% 才能再起（现在 %d%%）—— 濒死期间每秒都在慢慢回血" % [
				need_pct, int(round(leader.hp_ratio() * 100.0))],
			"ready": false,
		}]
	return [{
		"type": "revive",
		"name": "再起",
		"desc": "消耗%s，读条 %s 秒后脱离濒死（**血量保持不变**）重新投入战斗" % [
			cost_text, channel],
		"ready": true,
	}]



## ★★ 「操作」页该画什么：选中建筑时是升级 / 特化那一套，否则是部队的四条指令。
##
## 需求原话：「为所有单位/建筑都添加上『操作』页签，大本营的操作页签中有一个
## 升级大本营选项……箭塔和城墙也有一个升级选项，区划中心有三个特化选项」。
func _order_entries_for_selection() -> Array:
	# ★★ 三种选中要分开判，**不能**只看 `selected_buildings`：
	#   选中「区划中心」时 `input_ctrl.selected_zone` 会被填上，而
	#   `selected_buildings` 会被**清空**（`select_zone` 与 `select_buildings` 互斥）——
	#   只判 `selected_buildings` 的话，区划中心的操作页会掉回部队那四条指令
	#   （实测症状：点区划中心，「操作」页里写着移动 / 攻击 / 行军 / 停止）。
	if input_ctrl.selected_zone != null:
		# 区划中心：从区划反查它那一格的建筑，再按「区划中心」那一套画。
		# ★ 同时把**这个区划**传进去：特化状态要读的正是它，
		#   而不是「中心那栋建筑反查出来的那个区划」（两者在出生区不一定同一块，
		#   实测：大本营与区划中心不在同一格时，反查会得到另一块地 → 界面永远显示「三个特化」）。
		var zc = _zone_center_building_of(input_ctrl.selected_zone)
		return _building_order_entries(zc, input_ctrl.selected_zone)
	if not input_ctrl.selected_buildings.is_empty():
		var out := _building_order_entries(_primary_building())
		if not out.is_empty():
			return out
		return []
	# ★★ 第四种（本轮新增）：选中了**自己那一方的部队** ——
	#   这时要判「选中的将领是不是濒死了」：濒死就把整页换成「再起」那一格。
	#
	# ⚠️ 顺序放在建筑那两支**之后**：三种选中（区划 / 建筑 / 部队）互斥，
	#   而前两支各自 return 了，所以走到这里的一定是「选中部队」这一支。
	#   放到前面去的话，选中区划时 `first_selected_leader()` 可能仍然返回
	#   上一次选中留下的将领（`selected_units` 与 `selected_zone` 是两套字段），
	#   于是区划的操作页会被将领的「再起」顶掉。
	var leader = input_ctrl.first_selected_leader()
	if leader != null and leader.is_downed():
		return _revive_entries(leader)
	return _order_entries()


## 某个区划的**中心建筑**（那一格上立着的中立障碍；找不到 → null）。
##
## ★ 为什么要这一层：选中区划时 `selected_buildings` 是空的，而升级 / 特化那一套
##   是按**建筑类型**分派的（大本营 / 城墙 / 箭塔 / 区划中心各一套）——
##   所以要先从区划的中心格反查出那栋建筑，才能走同一条判据。
func _zone_center_building_of(zone):
	if zone == null or typeof(zone) != TYPE_DICTIONARY or world == null:
		return null
	var c: Variant = (zone as Dictionary).get("center", null)
	if c == null:
		return null
	var t: Vector2i = c
	return world.building_at(t.x, t.y)


## 建筑「操作」页的格子。三种建筑各一套（**数据驱动**，文案与数值都来自 config）：
##   · 大本营 / 城墙 / 箭塔 → **升级**那一格（读条中则换成「取消升级」）
##   · 区划中心            → **这个种类允许的**特化（见 zone_kind.list[].specs，
##                            通常是两格）；已经特化过则换成「取消特化」
##
## ★ 三种状态互斥，所以最多 3 格：
##     ① 读条中（升级 / 特化 / 取消特化）→ 只有「取消」那一格；
##     ② 区划已特化                      → 只有「取消特化」那一格；
##     ③ 平常                            → 升级那一格（建筑）/
##                                          这个种类允许的特化（区划中心）。
##   「读条中不给新的升级请求」这条规则由逻辑层把关（拒因 `busy`），
##   界面只是**不给入口**；两处都做是有意的 —— 界面上摆一颗点了必然被拒的格子，
##   玩家会以为功能坏了。
##
## @param b 要画哪一栋（默认 = `_primary_building()`；选中区划时由调用方从
##          区划的中心格反查出一栋传进来）
## @param sel_zone 选中的那个**区划字典**（区划中心特化状态要读它；null = 用建筑反查）
func _building_order_entries(b = null, sel_zone = null) -> Array:
	# ⚠️ 默认参数是 null，这里**不能**用 `var b = ...` 再赋一次
	#   （那会报「同名变量」）；直接用参数缺省值兜底。
	if b == null:
		b = _primary_building()
	if b == null:
		return []
	# ① 读条中：只有「取消」那一格
	if b.type == BuildingRes.TYPE_ZONE_CENTER:
		var z = sel_zone if sel_zone != null else world.zone_of_center_building(b)
		if z != null and world.zone_spec_busy(z):
			if world.zone_spec_is_cancel(z):
				# 「取消特化」本身在读条：不可取消（需求只说了取消特化要读条，
				# 没有「取消取消」这一说）——给一颗说明用的空格子。
				return []
			return [{
				"type": "zone_spec_bar_cancel",
				"name": "取消特化",
				"desc": "撤掉正在读条的这一单特化，全额退还已经扣掉的粮食与黄金",
			}]
		# ② 已经特化过 → 只能取消特化（需求：特化后的区块无法再次特化）
		if z != null and String(z.get("spec_done", "")) != "":
			var done := String(z.get("spec_done", ""))
			return [{
				"type": "zone_spec_cancel",
				"name": "取消特化",
				"desc": "取消「%s」（**也要读条**，读完退回当初特化花掉的粮食与黄金）"
					% String(cfg.spec_entry(done).get("name", done)),
			}]
		# ③ 平常：**这个种类允许的**特化（只能选一个）
		#
		# ★★ 本轮：白名单按区划种类过滤（需求：粮食区划仅能黄金 / 人口特化…）——
		#   判据只有一处（`config.json` 的 zone_kind.list[].specs，经
		#   `world.zone_spec_choices()` 取），界面**不**自己再写一份名单；
		#   逻辑层（`upgrade.gd can_specialize`）用同一个白名单再挡一次。
		var out: Array = []
		for e in world.zone_spec_choices(z):
			var entry: Dictionary = e
			out.append({
				"type": "zone_specialize",
				"spec": String(entry.get("id", "")),
				"name": String(entry.get("name", entry.get("id", ""))),
				"desc": String(entry.get("desc", "")),
			})
		return out
	# 建筑：升级 / 取消升级
	if not world.building_can_upgrade(b.type):
		return []
	if b.is_upgrading():
		return [{
			"type": "building_upgrade_cancel",
			"name": "取消升级",
			"desc": "取消这次升级，全额退还已经扣掉的粮食与黄金（当前等级不变）",
		}]
	var max_lv: int = world.building_max_level(b.type)
	if b.level >= max_lv:
		return [{
			"type": "building_upgrade_max",
			"name": "已满级",
			"desc": "%s 已经是最高等级（%d 级）" % [b.display_name(), max_lv],
		}]
	return [{
		"type": "building_upgrade",
		"name": "升级%s" % b.display_name(),
		"desc": "升到 %d 级：%s（读条 %s 秒，期间可取消并全额退款）" % [
			b.level + 1, _cost_text(world.building_upgrade_cost(b)),
			_fmt_num(world.building_upgrade_time(b))],
	}]


## 消耗的一行中文（「粮食 100 / 黄金 100」；空的一句「免费」）
func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for k in ["food", "gold"]:
		var v := float(cost.get(k, 0.0))
		if v > 0.0:
			parts.append("%s %s" % ["粮食" if k == "food" else "黄金", _fmt_num(v)])
	return " / ".join(parts) if not parts.is_empty() else "免费"


## 进了某个命令模式之后那句提示（玩家必须知道「接下来点哪儿」）
func _order_hint(mode: String) -> String:
	match mode:
		"move":
			return "左键点地图下达移动命令（右键 / Esc 取消）"
		"attack":
			return "左键点敌方单位 / 建筑（右键 / Esc 取消）"
		"attack_move":
			return "左键点地图下达行军攻击（右键 / Esc 取消）"
		"stop":
			return "就地停止（清掉移动 / 攻击 / 行军攻击）"
	return "左键点地图下达（右键 / Esc 取消）"


## 点了科技九格里的某一格 = **启用 / 弃用**这一条科技（需求：点已启用的 = 弃用）。
##
## ★★ 「点一下是启用还是弃用」由**权威状态**取反决定（`world.is_tech_active`），
##   界面不自己记一份「哪几格亮着」—— 那样一旦两处不一致，玩家会看到
##   「格子是亮的，效果却没生效」这种最难查的坏状态。
## ★ 满了（已启用 3 条）时再点没启用的那一条：**先在本地给一句提示**，
##   同时照发命令（逻辑层也会拒并留一条 `tech_rejected` 事件）。
##   为什么两处都给：本地这句是「点了立刻有反应」（事件要等下一帧 tick 才回来），
##   而逻辑层那条才是权威 —— 万一以后加上「科技有前置条件」，
##   本地那句猜错了也只会多一句提示，不会挡住命令。
func _on_tech_cell_activated(id: String) -> void:
	if input_ctrl == null or world == null or id == "":
		return
	var on: bool = not world.is_tech_active(id)
	if on and world.tech_remaining_slots() <= 0:
		var max_n: int = world.tech_max_active()
		show_notice("最多只能同时启用 %d 个科技：先点一个已启用的弃用" % max_n)
	if not input_ctrl.request_tech_toggle(id, on):
		show_notice("这条科技现在点不了")
		return
	# ★ 立刻按**权威状态**重画一次（下一帧也会重画，但玩家点下去那一下就该看见高亮变化）。
	#   顺序有意如此：先发命令、再由权威状态决定画成什么样 ——
	#   界面永远不自作主张地翻转本地高亮。
	refresh()
	# ★ 悬停面板还开着的话，那两行（「状态 …」「点这一格 = …」）也要跟着变 ——
	#   玩家的鼠标正停在这一格上，不重算的话它要等鼠标移开再移回来才更新（看着像没生效）。
	_refresh_hover()


## 悬停面板还开着时，按**权威状态**重算一次内容。
##
## ★ 只在「点了那一格」这种**状态当场变了**的路径上调（见 `_on_tech_cell_activated`）：
##   悬停进来的那一帧已经取过一次，没必要每帧重量一遍 ——
##   `hover_tip.show_text()` 是真的在排版与量高度（见那个文件的 `_measure()`）。
func _refresh_hover() -> void:
	if hover_tip == null or _hover_src == "":
		return
	var d := _hover_detail(_hover_src, _hover_entry(_hover_src, _hover_index))
	if d.is_empty():
		_dismiss_hover()
		return
	hover_tip.show_text(String(d.get("title", "")), String(d.get("body", "")))


## 命令卡 → 动作。★ 这里只调输入层的接口，自己绝不碰逻辑状态。
func _on_card_entry(entry: Dictionary) -> void:
	if input_ctrl == null:
		return
	match String(entry.get("type", "")):
		"build":
			var t := String(entry.get("build_type", ""))
			if input_ctrl.build_type == t:
				input_ctrl.set_build_type("")        # 再点一次 = 退出建造模式（与 B/T 一致）
			else:
				input_ctrl.set_build_type(t)
		"recruit":
			# ★ 没选中将领时**不发命令**（命令里必须带 leader_id），所以这里要自己给一句
			#   可见反馈 —— 否则玩家点了 Q 什么都没发生，看起来像功能坏了。
			#   逻辑层拒掉的其它原因走事件那条路（见 game_scene._consume_events）。
			if not input_ctrl.request_recruit(String(entry.get("unit_kind", ""))):
				show_notice("先选中一个将领，才能把新兵排到它名下")
		"zone_recruit":
			# 区划招募（点区划中心 → 招募页）：命令里必须带 zone_id，没选中区划就不发。
			if not input_ctrl.request_zone_recruit(String(entry.get("unit_kind", ""))):
				show_notice("先点一个区划中心，才能在这个区划里招募")
		"order":
			# ★ 操作页：前三格进 / 退出命令模式（点同一格再点一次 = 退出），
			#   下一手由 input_controller 接管（左键点地图 / 点目标下达）。
			#   「停止」没有目标：点一下**当场**下达，不进模式（见 request_stop）。
			var mode := String(entry.get("mode", ""))
			var name := String(entry.get("name", ""))
			if mode == "stop":
				if input_ctrl.request_stop():
					show_notice("%s：%s" % [name, _order_hint(mode)])
				else:
					show_notice("先选中一支部队，才能下达指令")
			elif input_ctrl.set_order_mode(mode):
				show_notice("%s：%s" % [name, _order_hint(mode)])
			else:
				show_notice("")
		"building_upgrade":
			_on_building_action(entry)
		"building_upgrade_cancel":
			_on_building_action(entry)
		"zone_specialize":
			_on_building_action(entry)
		"zone_spec_cancel":
			_on_building_action(entry)
		"zone_spec_bar_cancel":
			_on_building_action(entry)
		"revive":
			# ★★ 濒死将领的「再起」（本轮新增）：与「停止」那一格一样，
			#    点一下当场发命令（不需要目标、也不进命令模式）。
			#    ⚠️ 被置灰的那一档（血量还没到 10%）**根本点不到**：
			#       按钮是 disabled 的（见 command_card.set_entries），
			#       这里再判一次只是保险（键盘 / 测试直接调 activate_index 时也走这条路）。
			if not bool(entry.get("ready", true)):
				show_notice(String(entry.get("desc", "现在还不能再起")))
				return
			if input_ctrl.request_revive():
				show_notice("再起：%s" % String(entry.get("desc", "")))
			else:
				show_notice("先选中一个濒死的将领，才能让它再起")
		"revive_cancel":
			if input_ctrl.request_revive_cancel():
				show_notice("已取消再起读条（全额退款）")
			else:
				show_notice("先选中一个正在再起的将领，才能取消")


## ★ 建筑「操作」页那几格 → 命令（升级 / 取消升级 / 特化 / 取消特化）。
##
## ★ 与其它格子同一条约定：这里只调输入层的接口发命令，自己绝不碰逻辑状态。
##   目标（哪栋建筑 / 哪个区划）由**当前选中**决定：命令里带地块坐标或区划 id。
## ★ 被拒时的提示走 `upgrade_rejected` 事件（game_scene → 左栏红字），
##   所以这里不为「钱不够 / 满级」再写一份判断 —— 规则只有逻辑层一份。
func _on_building_action(entry: Dictionary) -> void:
	var t := String(entry.get("type", ""))
	# ★ 目标建筑：选中区划时 `selected_buildings` 是空的（两种选中互斥），
	#   所以要先从区划的中心格反查出那栋建筑 —— 与操作页画格子用的是同一条判据。
	var b = _primary_building()
	if b == null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	if b == null:
		show_notice("先选中一栋建筑")
		return
	match t:
		"building_upgrade":
			input_ctrl.request_building_upgrade(b)
		"building_upgrade_cancel":
			input_ctrl.request_building_upgrade_cancel(b)
		"zone_specialize", "zone_spec_cancel", "zone_spec_bar_cancel":
			# ★ 与操作页画格子用的是同一条判据：选中区划时**优先用选中的那个区划**，
			#   而不是「中心那栋建筑反查出来的区划」（出生区里两者不一定同一块）。
			var z = input_ctrl.selected_zone
			if z == null:
				z = world.zone_of_center_building(b)
			if z == null:
				show_notice("这栋区划中心找不到它所属的区划")
				return
			match t:
				"zone_specialize":
					input_ctrl.request_zone_specialize(z, String(entry.get("spec", "")))
				"zone_spec_cancel":
					input_ctrl.request_zone_spec_cancel(z)
				_:
					input_ctrl.request_zone_spec_bar_cancel(z)
	# ★★ 点完立刻按**权威状态**重画一遍操作页。
	#
	# 为什么必须有这一句（**实测踩到的**）：操作页的内容跟权威状态走
	#   （读条一开始，「升级」那格就该变成「取消升级」；特化一做，三个特化就该并成
	#   「取消特化」一格），而 `_rebuild_card()` 原来只在「页签组合变了」时才跑 ——
	#   点完那一格页签一点没变，于是命令卡还画着旧内容（看着像点了没反应）。
	# ⚠️ 这里**直接调 `_rebuild_card()`**，不走 `refresh()`：
	#   `refresh()` 里那条 `_sync_tabs()` 有「页签组合没变就什么都不做」的短路，
	#   正好会把这次重建吃掉（实测就是这样）。
	_rebuild_card()


## 点了信息栏里那块面板上的某一格 = **取消那一格**（招募队列 = 取消那一单；
## 单条读条 = 取消这次升级 / 退掉这一单特化）。
##
## ★ 队列主人有两种（选中将领 / 选中区划），两条取消命令的形状不同
##   （leader_id vs zone_id），所以这里按当前选中分派 —— 视图不猜，只看选中状态。
## ★★ 本轮新增第三种内容：**单条读条**（建筑升级 / 区划特化，见 view/recruit_queue.gd）。
##   它和「招募队列」共用同一块面板，所以先问面板「你现在是哪一种」
##   （`detail_panel.queue_is_bar()`），再决定发哪条取消命令。
## ★ 这里只发命令（`*_cancel`）：退多少钱、等级怎么变全在权威侧算，
##   界面下一帧按权威状态重画 —— 所以本地不需要自己「删格子」。
func _on_queue_cell_activated(slot: int) -> void:
	if input_ctrl == null or detail_panel == null:
		return
	# ① 单条读条（建筑升级 / 区划特化）
	if detail_panel.queue_is_bar():
		# ★★ 先看「选中的是不是一个区划」——选中区划中心看详情时
		#   `selected_buildings` 是空的（两种选中互斥），`_primary_building()` 会返回 null；
		#   这时那块面板上的读条就是**这个区划**的特化（实测：原来在这里直接
		#   `return` 了，于是「点读条面板撤单」永远没反应）。
		var b = _primary_building()
		if b == null and input_ctrl.selected_zone != null:
			if not input_ctrl.request_zone_spec_bar_cancel(input_ctrl.selected_zone):
				show_notice("这一单不能取消")
			_rebuild_card()
			return
		if b == null:
			show_notice("现在没有可以取消的升级")
			return
		if b.is_upgrading():
			if not input_ctrl.request_building_upgrade_cancel(b):
				show_notice("现在没有可以取消的升级")
			_rebuild_card()
			return
		var z = input_ctrl.selected_zone
		if z == null and b.type == BuildingRes.TYPE_ZONE_CENTER:
			z = world.zone_of_center_building(b)
		if z == null or not input_ctrl.request_zone_spec_bar_cancel(z):
			show_notice("这一单不能取消")
		_rebuild_card()
		return
	# ② 招募队列（原本那套）
	if input_ctrl.selected_zone != null:
		if not input_ctrl.request_zone_recruit_cancel(slot):
			show_notice("现在没有可以取消的招募")
		return
	if not input_ctrl.request_recruit_cancel(slot):
		show_notice("现在没有可以取消的招募")
	_rebuild_card()


## 点了左栏下半网格里的一格**将领** = 把那一支部队换成「当前展开」的那一支，
## 同时右栏切到那支部队的将领。
##
## ★ 需求原话：「若玩家点选下方 1333 排列的将领，则会将展开的部队转换成选中的部队，
##   相应地，展开将领变为选中的部队将领」。
##   ⇒ 这里**只改「展开哪一支」**（记住编号 + 刷一帧），**不碰选中集合**：
##     选中是玩家在地图上 / 左侧列表里做的决定，点一下格子不该把它改掉。
## ★ 编号 → 部队：按**与左侧部队列表完全相同的口径**数一遍己方队长
##   （view/squad_panel.gd 的 _collect_teams 是同一套判据）。
## ⚠️ 编号得**真的在当前选中的部队里**才认（喂 99 这种不存在的编号 → 什么都不变）：
##   以前不查也能跑，是因为 `_pick_troop` 下一帧会退回第一支 —— 但那样
##   「先把展开改成 99、再由 _pick_troop 退回默认」不是本意，干脆在这里就拒掉。
func _on_troop_activated(number: int) -> void:
	if world == null or number <= 0:
		return
	if not _troop_number_selected(number):
		return
	_detail_troop_number = number      # 下一帧就展开它（别被「默认第一支」抢回去）
	refresh()


## 这个部队编号（1 起）现在是不是**选中的**部队之一
func _troop_number_selected(number: int) -> bool:
	for t in _selected_troops(input_ctrl.selected_units):
		if int(t["number"]) == number:
			return true
	return false


## 点了左栏下半网格里的一格**单位**（只有「只选中一支部队」时才是单位格）。
##
## ★ 需求原话：「当玩家只选中了单个部队时……下方 333 排列显示选中的部队的单位」+
##   「点单位格则右栏切到那个单位」。
##   ⇒ 只把右栏切过去（写 `input_ctrl.clicked_unit`），**不动选中集合** ——
##     点一下左栏不该改变「命令发给谁」。顺序的选择手柄留给玩家单击地图那一下。
## ⚠️ 这里写的是与地图点选**同一个** `clicked_unit`，并且顺手把
##   `selection_origin` 记成 "click"：右栏的显示规则是「单击选中 → 显示点到的那个单位，
##   拖拽框选 → 显示展开那支部队的将领」（手玩原话），点左栏的格子属于前者。
func _on_grid_unit_activated(index: int) -> void:
	if input_ctrl == null or world == null:
		return
	var u = _grid_unit_at(index)
	if u == null:
		return
	input_ctrl.clicked_unit = u
	input_ctrl.selection_origin = "click"
	refresh()


## 左栏下半网格里第 index 个格子现在画的是哪个单位（没有 → null）
func _grid_unit_at(index: int):
	if detail_panel == null:
		return null
	var grid = detail_panel.grid_control()
	if grid == null or grid.mode != TroopGridRes.MODE_UNITS:
		return null
	return grid.unit_at(index)


## 点了左栏下半网格里的一格**建筑** = 把「主选中」换成它：
## 右栏详情、左上那一格、地图上的高亮全部跟着走。
##
## ★ 与单位格同一条约定：**点一下左栏不改「选中了哪些」**（这一批仍然是这一批），
##   只改「现在正在看哪一个」—— 所以这里只写 `input_ctrl.selected_building`
##   （它是 `selected_buildings` 里的成员，见 input_controller 里那两个字段的说明）。
func _on_grid_building_activated(index: int) -> void:
	if input_ctrl == null or world == null:
		return
	var b = _grid_building_at(index)
	if b == null:
		return
	input_ctrl.selected_building = b
	refresh()


## 左栏下半网格里第 index 个格子现在画的是哪个建筑（没有 → null）
func _grid_building_at(index: int):
	if detail_panel == null:
		return null
	var grid = detail_panel.grid_control()
	if grid == null or grid.mode != TroopGridRes.MODE_BUILDINGS:
		return null
	return grid.building_at(index)


## 选中的建筑里**主选中**的那一个（右栏显示它）。
## 正常情况就是 `input_ctrl.selected_building`；万一它不在这一批里（不该发生）
## 就退回第一个 —— 总之这一支保证「有选中建筑时一定返回一个非 null 的建筑」。
func _primary_building():
	if input_ctrl == null:
		return null
	var list: Array = input_ctrl.selected_buildings
	var b = input_ctrl.selected_building
	if b != null and list.has(b):
		return b
	return list[0] if not list.is_empty() else null


## 一批建筑 → 左栏那 10 个格子要的数据（短字 / 名字 / 第二行血量）。
## ★ 走这一层组装而不是让 detail_panel 自己去问建筑：网格与那一格都只认这几个字段
##   （建筑没有 `name` 属性，名字得走 `display_name()`）。
func _building_entries(buildings: Array) -> Array:
	var out: Array = []
	for b in buildings:
		out.append({
			"ref": b,
			"name": b.display_name(),
			"short": _building_short(b),
			"sub": "%d/%d" % [int(round(b.hp)), int(round(b.hp_max))],
		})
	return out


# ------------------------------------------------------------------
# 提示行（红字）：操作被拒时的可见反馈
# ------------------------------------------------------------------

## 显示一句话，约 ui.notice_sec 秒后自动消失（空串 = 立刻收起）
func show_notice(text: String) -> void:
	if detail_panel == null:
		return
	if text == "":
		_notice_timer = 0.0
		detail_panel.set_notice("")
		return
	detail_panel.set_notice(text)
	_notice_timer = cfg.num("ui.notice_sec", 2.0)


func _tick_notice(dt: float) -> void:
	if _notice_timer <= 0.0:
		return
	_notice_timer -= dt
	if _notice_timer <= 0.0:
		_notice_timer = 0.0
		if detail_panel != null:
			detail_panel.set_notice("")


## 提示还在不在（测试读它；游戏里没人读）
func notice_active() -> bool:
	return _notice_timer > 0.0


func notice_text() -> String:
	return detail_panel.notice_text() if detail_panel != null else ""


## 招募被拒的**拒因码 → 中文**。★ 这一层翻译只在这里做（逻辑层只给码，不写 UI 文案）。
##
## 拒因码是 logic/world.gd 的 can_recruit / can_afford_recruit / can_recruit_zone 产出的：
##   kind / leader / faction / zone / zone_owner / zone_not_found / queue_full / cost / population
##   / **downed**（★ 本轮新增：将领濒死倒地，不能继续造兵）
## ★ 注意两个「区划」拒因是**不同的话**：
##   · "zone"          将领招募时它是「将领不站在己方区划里」；
##   · "zone_owner"    区划招募时它是「这个区划不属于你」。
##   （"zone_not_found" 才是「没有这个区划」—— 前两者都别拿来当它用。）
## ★ `max_count` 来自事件里的 max（区划招募的队列上限可能与单位那条不同）——
##   没带就用单位那条表的上限。
func recruit_reject_text(reason: String, kind: String, max_count: int = 0) -> String:
	match reason:
		"kind":
			return "这个兵种不在可招募表里"
		"leader":
			return "先选中一个将领，才能把新兵排到它名下"
		"downed":
			return "将领已经倒地濒死：它不能再造兵（在造的那一单已作废并全额退款）"
		"faction":
			return "不能给别的阵营的将领招募"
		"zone":
			return "只能在己方区划内招募（将领现在站的地方不属于你）"
		"zone_owner":
			return "只能在自己区划里招募（这个区划不属于你）"
		"zone_not_found":
			return "找不到这个区划"
		"queue_full":
			var cap: int = max_count if max_count > 0 else world.recruit_queue_max()
			return "招募队列已满（最多 %d 个）" % cap
		"cost":
			var c: Dictionary = world.recruit_cost(kind)
			return "粮食或黄金不足（需要 粮食 %d / 黄金 %d）" % [
				int(round(float(c.get("food", 0.0)))), int(round(float(c.get("gold", 0.0))))]
		"population":
			return "该区划人口不足（需要 %d 人口）" % int(round(world.recruit_population_cost(kind)))
	return "无法招募"


## 指令被拒的**拒因码 → 中文**（与上面那条同一条约定：逻辑层只给码）。
##
## 目前两种拒因（都由 `world.order_lock_reason()` 产出）：
##   · `recruiting` —— 将领正在招募时，**它和它辖下的部队**都不接受移动 / 攻击命令；
##   · ★ `downed`   —— **本轮新增**：将领濒死倒在地上，它自己不接受任何指令。
##   · ★★ `leader_downed` —— **本次修 bug 新增**：**附属兵**在队长濒死期间不接受指令。
##     与上面那条的区别：`downed` 拒的是将领本人，`leader_downed` 拒的是它的部队。
##     用户口径原话：「其旗下部队应当立刻行军攻击至其将领位置以保护他，
##     并且在将领再起前不接受玩家或 ai 的指令」。
func order_reject_text(reason: String) -> String:
	match reason:
		"recruiting":
			return "将领正在招募单位：它和它的部队这会儿只警戒，不接受指令"
		"downed":
			return "将领已经倒地濒死：它自己不能行动，先让它「再起」（它辖下的部队照常能打）"
		"leader_downed":
			return "该部队的主将已经倒地：它们正在赶去保护主将，主将「再起」前不接受指令"
	return "这条指令现在下不了"


## 「再起」被拒的**拒因码 → 中文**（码见 logic/world.gd 的 revive_reject_reason）。
##
## ★ 常规路径下这些码玩家**看不到**：那颗格子在血量不到 10% 时就是灰的（点不动）。
##   但 AI 也会下单（它走同一个入口），而且「资源不够」这一条玩家那颗格子**照样是亮的**
##   ——钱不够的判断在扣费那一步，界面没有提前拦（拦了就等于把规则抄两份）。
##   所以这条翻译是给「钱不够」那一下用的，其余几条是兜底。
func revive_reject_text(reason: String) -> String:
	match reason:
		"leader":
			return "先选中一个将领，才能让它再起"
		"faction":
			return "不能给别的阵营的将领再起"
		"not_downed":
			return "这个将领没有倒地，不需要再起"
		"channeling":
			return "它已经在再起了（想中断就点「取消再起」）"
		"hp":
			return "血量还没回到 %d%%，再起还点不亮" % int(round(world.revive_ready_ratio() * 100.0))
		"cost":
			var c: Dictionary = world.revive_cost()
			return "粮食或黄金不足，再起需要 粮食 %d / 黄金 %d" % [
				int(round(float(c.get("food", 0.0)))), int(round(float(c.get("gold", 0.0))))]
	return "现在不能让它再起"


## 科技被拒的**拒因码 → 中文**（逻辑层只给码：见 logic/tech.gd 的 can_activate）。
##   "limit"    已经启用满了（需求原话：「当玩家启用的科技数到 3 时……会被阻止并提示」）
##   "unknown"  没有这条科技（手改数据 / 旧快照才会有）
func tech_reject_text(reason: String) -> String:
	var max_n: int = world.tech_max_active() if world != null else 3
	match reason:
		"limit":
			return "最多只能同时启用 %d 个科技：先点一个已启用的弃用" % max_n
		"unknown":
			return "没有这条科技"
	return "这条科技现在启用不了"


## 建筑升级 / 区划特化被拒的**拒因码 → 中文**（码见 logic/upgrade.gd 的那几处判定）。
## 与招募 / 科技同一条约定：逻辑层只给码 + **对象**，文案只在这里。
##
## ★★ `busy` 那条文案必须**点名是哪个对象、并说明什么都没发生**（实测报回来的）：
##   玩家原话是「详细信息栏经常显示『这一项正在读条…』，但我什么都没做」。
##   原因有两层：
##     ① 「正在读条」的东西**可能不是玩家自己下的单** —— 敌方 AI 也会升级自己的建筑
##        （实测：样例第一关开局第 0 帧，E1 的城墙就已经在升级了）；
##     ② 旧文案只有一个「这一项」：既不说哪一项、也不说「这一下没有生效」，
##        于是看起来像凭空冒出来的报错。
##   ⇒ 现在带上对象名，并明说「这一下没有生效（没扣资源、也没排队）」。
##
## @param evt 可选：那条 `upgrade_rejected` 事件本身（带 `building` / `zone_id`）。
##        不传也能用（退回旧的那句泛泛文案）。
func upgrade_reject_text(reason: String, evt: Variant = null) -> String:
	match reason:
		"busy":
			var who := _reject_target_name(evt)
			if who != "":
				return "「%s」正在读条：这一下没有生效（没扣资源、也没排队）。等它读完，或者点信息栏那一格取消" % who
			return "这一项正在读条：等它读完，或者点信息栏那一格取消"
		"max_level":
			return "已经是最高等级了"
		"spec_done":
			return "这个区划已经特化过了：先「取消特化」才能换别的"
		"spec":
			return "没有这种特化"
		"kind":
			return "这个种类的区划做不了这种特化（粮食区划只能黄金 / 人口特化，黄金区划只能粮食 / 人口特化，人口区划只能粮食 / 黄金特化）"
		"cost":
			return "粮食或黄金不足"
		"owner":
			return "只能升级自己的建筑"
		"zone":
			return "只能特化属于自己的区划"
		"zone_not_found":
			return "找不到这个区划"
		"type":
			return "这种建筑不能升级"
		"idle":
			return "现在没有可以取消的读条"
	return "这一项现在做不了"


## 被拒的那**一个对象**的人话名字（建筑 → 显示名；区划 → 区划名）。
## ★ 只做「对象 → 名字」这一层翻译，不判断「这是谁的」—— 那属于逻辑层。
func _reject_target_name(evt: Variant) -> String:
	if typeof(evt) != TYPE_DICTIONARY:
		return ""
	var d: Dictionary = evt
	var b = d.get("building", null)
	if b != null and b.has_method("display_name"):
		return String(b.display_name())
	var zid := int(d.get("zone_id", -1))
	if zid >= 0 and world != null:
		var z = world.zone_by_id(zid)
		if z != null:
			var zd: Dictionary = z
			var nm := String(zd.get("name", "")).strip_edges()
			return nm if nm != "" else ("区划 c%d" % zid)
	return ""


# ------------------------------------------------------------------
# 键盘 / 鼠标
# ------------------------------------------------------------------

## 命令卡上的九个字母键（有内容的格优先于其它绑定）。
## 由 view/main.gd 在 input_controller 之前调用。
func handle_key(event: InputEventKey) -> bool:
	if command_card == null:
		return false
	return command_card.handle_key(event)


## 鼠标是不是停在**可点的控件**上（部队行 / 命令卡 / 页签 / 设置）。
##
## ★ 边缘滚屏要给这些地方让路，否则鼠标一移到底栏上镜头就自己跑。
##   但**只有能点的控件**才让路：详细信息面板全是文字，让它也让路的话，
##   底栏盖住屏幕下沿 → 鼠标永远滚不到地图下方（这条是实测撞出来的）。
##
## ★★ 屏幕**最外圈**（config.camera.edge_size 之内）永远不许拦 —— 这一条是补的
##    （手玩报的 bug：「鼠标移到将领按钮那边的屏幕边缘，屏幕不会滚动」）：
##   左侧部队列表是 x 0..119 的控件，整条压着左边缘，于是左边缘那一段永远滚不动。
##   凡贴边的控件都有这个毛病（命令卡压下边缘、设置压上边缘），所以判据写成
##   「先看在不在最外圈」，与 camera_rig 的滚屏触发区同源。
func blocks_edge_scroll(global_pos: Vector2) -> bool:
	var vp := view_size()
	var margin: float = cfg.camera_edge_size if cfg != null else 0.0
	if UiLayoutRes.in_edge_band(vp, global_pos, margin):
		return false
	return UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), global_pos)


## 鼠标是不是停在**底栏**上（详细信息 / 阵营 / 命令卡 / 页签 —— **不含**左下小地图）。
##
## 需求原话：「当鼠标位于下方除地图外的 ui 栏时，应当禁用鼠标滚轮缩放地图，
##            当鼠标移出下边栏，需要恢复」。
##
## ★ 与 `blocks_edge_scroll` 是**两条不同的规则**（别合并，理由见 ui_layout 里
##   `bottom_bar_rects` 的注释）：那条只拦「能点的控件」，这条拦**整条底栏** ——
##   详细信息面板里只有文字的地方不能拦边缘滚屏，但滚轮缩放在那儿照样该停。
## ★ 小地图不算「ui 栏」：鼠标停在它上面时滚轮照旧缩放地图（需求里的「除地图外」）。
## ★ 判据由调用方**每次事件**传进来（game_scene 用的是那一下滚轮自己的坐标）：
##   鼠标一移出底栏，下一下滚动就恢复缩放 —— 没有「记得复位」的状态。
func blocks_wheel_zoom(global_pos: Vector2) -> bool:
	return UiLayoutRes.point_hits_any(UiLayoutRes.bottom_bar_rects(view_size()), global_pos)


## ★★ 当前这一屏「操作」页该画哪几格 —— 用一个**短字符串签名**表达（见 `_card_sig()`）。
##
## 为什么需要它（手玩报的 bug）：「先选中城墙、再改选箭塔，右下角还写着『升级城墙』」——
## `_sync_tabs()` 只在**页签组合**变了时才重建命令卡，而城墙与箭塔属于**同一类选中**
## （kind 都是 building、页都是 [操作]）⇒ 页签那一路察觉不到「换了一栋楼」。
## 同一类问题的另一面：两个**种类不同**的区划中心轮流点（能做哪几档特化不一样）。
##
## 做法：把「与内容有关的那些事实」拼成签名，`refresh()` 每帧比一次，变了就重建。
## ⚠️ 签名只放**便宜、稳定**的字段（枚举字符串 + 地块 / 区划 id + 等级 + 两个布尔），
##    不放对象引用，也**不放读条百分比**（那一格画的是「取消升级」/「取消特化」，
##    与读了几成无关；放进去就变成每变 1% 白重建一次）。
func _card_sig() -> String:
	if input_ctrl == null or page_tabs == null or world == null:
		return ""
	var parts: Array[String] = [String(page_tabs.page())]
	# ① 选中的建筑（选中区划时用「它的中心建筑」代替 —— 与 `_building_order_entries` 同一条判据）
	var b = _primary_building()
	if b == null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	if b != null:
		parts.append("b:%s@%d,%d:lv%d:up%d" % [
			b.type, b.tx, b.ty, b.level, 1 if b.is_upgrading() else 0])
	# ② 选中的那个区划：**种类**决定能做哪几档特化，spec_done / spec_kind 决定
	#    操作页画的是「三档特化」还是「取消特化」那一格
	var z = _recruit_zone()
	if z != null and typeof(z) == TYPE_DICTIONARY:
		var zd: Dictionary = z
		parts.append("z:%d:%s:%s:%s" % [int(zd.get("id", -1)), world.zone_kind_of(zd),
			String(zd.get("spec_done", "")), String(zd.get("spec_kind", ""))])
	# ③ 选中部队 / 什么都没选中这两档**不进签名**：它们的命令卡内容是静态的
	#    （操作页那四条指令写死在 `_order_entries()`、建筑页来自 config.json 的 building 段），
	#    与「选中了哪一支部队」无关 —— 放进去只会每次换选中都白重建一遍。
	#
	# ★★ 唯一的例外是**濒死的将领**（本轮新增）：它的操作页不是那四条静态指令，
	#    而是「再起 / 取消再起 / 血量还没回到 10%」这三态之一，且会**自己变化**
	#    （血量到 10% 那一刻格子要亮起来；读条开始 / 结束也要换字）。
	#    不把它放进签名的话，那两颗格子的字会一直停在生产它的那一帧
	#    （表现：血量明明回到 10% 了，格子还是灰的，直到玩家改选一次）。
	#    ⚠️ 只放**这几个会进文案的判据**，不要把 hp 放进去 —— 濒死期间血量每 3 秒
	#      动一次，放进去等于每 3 秒重建一次命令卡（没必要，格子上不显示具体血量）。
	var ld = input_ctrl.first_selected_leader()
	if ld != null and ld.is_downed():
		parts.append("nd:%s:%d:%d" % [String(ld.id),
			1 if ld.revive_ready(cfg) else 0,
			1 if ld.is_reviving() else 0])
	return "|".join(parts)


## 命令卡的内容变了就重建（每帧按签名比一次，见 `_card_sig()`）。
## ★ 绝大多数帧是空转（签名没变直接返回）——这比「每帧无条件重建」便宜得多，
##   也比「只在切页时重建」正确：**换了一栋同类建筑 / 换了一个种类的区划中心**都算内容变了。
func _refresh_card_if_changed() -> void:
	if _card_sig() == _card_sig_key:
		return
	_rebuild_card()


## 当前设计空间大小（canvas_items + expand 拉伸后可能比 1920×1080 大）
func view_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H)
	return vp.get_visible_rect().size


# ------------------------------------------------------------------
# 每帧刷新文本
# ------------------------------------------------------------------

func refresh() -> void:
	if world == null or input_ctrl == null or detail_panel == null:
		return
	# ★ 资源条先刷（它只读 `world.resources`，与选中了什么无关；每帧一次）
	_refresh_resource_bar()
	# ★★ 页签先按「现在选中了什么」推上去（选中部队 = 操作/单位；选中区划中心 = 招募；
	#    选中大本营 = 科技；选中普通建筑 = 一颗都没有；什么都没选中 = 建筑 + 科技）。
	#    命令卡的内容跟着页签走（page_tabs 发 page_changed → _rebuild_card）。
	_sync_tabs()
	# ★★ 命令卡的内容**每帧按签名比一次**（见 `_card_sig()`）：页签组合没变、但
	#   「选中的东西换了」（城墙 → 箭塔）或者「选中对象的权威状态变了」（开始升级 /
	#   取消升级 / 区划特化到哪一步）时，那一格必须跟着重画 ——
	#   这是手玩报的「改选箭塔，右下角还写着升级城墙」那个 bug 的修法。
	_refresh_card_if_changed()
	# ★ 科技九格每帧刷一次（内容 / 高亮都取决于权威的启用状态，见 _refresh_tech_grid）：
	#   命令卡那条路只在「签名变了」时跑（`_refresh_card_if_changed`），跟不上
	#   「玩家点了一格科技」这种变化。
	_refresh_tech_grid(page_tabs != null and String(page_tabs.page()) == PageTabsRes.PAGE_TECH)
	# ★ 详细信息是**左右两栏**（第三轮改版，见 view/detail_panel.gd 的文件头）：
	#   左栏 = 当前展开的那支部队（上半）+ 选中部队的将领头像网格（下半）
	#   右栏 = 选中单位的头像 / 名称 / buff / 基础数值（★ 数值那块的「详细信息」标题已删）
	# 选中对象的四种互斥情况：敌人 → 区划 → 建筑 → 单位（见下）
	# ★★ 敌人排在最前：它是**唯一**一种「选中了但不给任何操作入口」的对象，
	#    落到下面任何一支都会把敌人当自己人显示（升级按钮、军队编组…）。
	if _selected_enemy_kind() != "":
		_refresh_enemy_detail()
		return
	# ★ 区划这一支：标题那一行写**区划名本身**（不再套「区划「xx」」那层壳），
	#   正文里也不再出现「区划「xx」」那一行（需求：「选中区划中心时去掉『区划[xx]』文本」）。
	if input_ctrl.selected_zone != null:
		detail_panel.set_troops(null, [])
		detail_panel.set_unit_avatar_text("区")
		detail_panel.set_unit_name(_zone_title(input_ctrl.selected_zone))
		# ★★ 本次：当前人口只给**自己 / 友军**的区划看（用户原话：「如果是友军/己方区划，
		#   额外显示其当前人口数量」）—— 敌方与中立区划的「现在有多少人」属于对手的情报。
		detail_panel.set_detail(_zone_text(input_ctrl.selected_zone,
			_zone_is_friendly(input_ctrl.selected_zone)))
		# ★ 右栏右上角那块面板（招募队列 / 单条读条共用，见 _refresh_progress_panel）
		_refresh_progress_panel(input_ctrl.selected_zone)
		return
	if not input_ctrl.selected_buildings.is_empty():
		# ★★ 选中建筑（可能是一整批：框选建筑时，见 input_controller.box_select）：
		#   左栏 = 和部队**同一套 1 + 3×3 版式** —— 左上第 1 格是**主选中**那个建筑
		#   （右栏正在显示它），下面 9 格是其余选中的建筑（超过 9 个滚轮翻页）；
		#   点下面某一格 = 把主选中换成它（右栏与地图高亮跟着变，见 _on_grid_building_activated）。
		var b = _primary_building()
		detail_panel.set_buildings(_building_entries(input_ctrl.selected_buildings), b)
		detail_panel.set_unit_avatar_text(_building_short(b))
		detail_panel.set_unit_name(b.display_name())
		detail_panel.set_detail(_building_text(b))
		# 右栏那块面板：升级 / 特化读条 > 区划中心的招募队列 > 收起来
		_refresh_progress_panel(b)
		return

	# 选中的部队（按「队长」分组，顺序 = 左侧部队列表）：
	# 上半画**当前展开**的那一支的将领格，下半网格两种语义共用（见 detail_panel 文件头）：
	#   · 选中多支 → 画**其余**部队的将领（展开的那支不重复出现）
	#   · 只选中一支 → 画这支部队的**单位**（超 9 个滚轮翻页）
	var troops := _selected_troops(input_ctrl.selected_units)
	var current := _pick_troop(troops)
	var troop = null if current < 0 else troops[current]
	var troop_units: Array = []
	var unit_shorts: Array = []
	if troop != null and troops.size() == 1:
		troop_units = troop.get("units", [])
		unit_shorts = _unit_shorts(troop_units)
	detail_panel.set_troops(troop, _troops_without(troops, current), troop_units, unit_shorts)

	# 右栏：**地图上点到的那个单位优先**，否则是当前展开那支部队的将领
	# （需求原话：「默认为左侧栏中选中的部队将领头像，玩家点地图上某个单位时，
	#            该选中的单位为玩家点击的那个单位」）。
	var shown = _right_unit(troop)
	detail_panel.set_unit_avatar_text("" if shown == null else _unit_short(shown))
	detail_panel.set_unit_name("" if shown == null else String(shown.name))
	detail_panel.set_detail(_unit_text(shown, troops))
	# ★ 招募队列：显示**当前选中的第一个将领**的（选中整队时队长排在最前，
	#   见 input_controller.first_selected_leader）。没选中将领 → 整块收起来。
	detail_panel.set_queue(_queue_leader(troop), false)


## 选中部队分组：[{"leader": 队长, "number": 部队编号, "units": [该队单位…]}]。
##
## ★ 口径必须与左侧部队列表（view/squad_panel.gd）**完全一致**：
##   己方在场、`is_team_leader`、按 `world.units` 的顺序、最多 SQUAD_SLOTS 支。
##   不一致的话网格上写着「部队2」、左边高亮的却是第 3 行 —— 玩家没法把两边对上。
func _selected_troops(units: Array) -> Array:
	var out: Array = []
	if world == null:
		return out
	var index_of: Dictionary = {}
	var n := 0
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if not world.is_team_leader(u):
			continue
		n += 1
		if n > UiLayoutRes.SQUAD_SLOTS:
			break
		if not units.has(u):
			continue
		index_of[u.id] = out.size()
		out.append({"leader": u, "number": n, "units": [u]})
	# 第二遍：把选中列表里的亲兵塞进它们队长那一组（选中列表已经是整队展开过的，
	# 所以这一步只是把「成员」补齐；找不到队长分组的（队长不在列表里）就忽略）。
	for u2 in units:
		if u2 == null or not u2.alive:
			continue
		if world.is_team_leader(u2):
			continue
		var leader = world.team_leader(u2)
		if leader == null or not index_of.has(leader.id):
			continue
		(out[int(index_of[leader.id])]["units"] as Array).append(u2)
	return out


## 「当前展开」的是第几支：优先 `_detail_troop_number`（玩家点的那一支），
## 它不在选中里了就退回第一支；一支都没有 → -1。
func _pick_troop(troops: Array) -> int:
	if troops.is_empty():
		_detail_troop_number = 0
		return -1
	for i in troops.size():
		if int(troops[i]["number"]) == _detail_troop_number:
			return i
	# ★ 记住的那一支已经不在选中里了（玩家改选了别人）→ 忘掉它，
	#   否则「选中 A → 又从左侧列表改选 B」时左栏会一直停在 A 上。
	_detail_troop_number = int(troops[0]["number"])
	return 0


## 下半网格要画的部队 = 选中的部队**去掉正在展开的那一支**。
##
## ★ 手玩原话：「被展开的部队不需要在下方的九宫格中显示」——它已经在上半那一行里了，
##   再列一次只会让人以为那是两支部队。
func _troops_without(troops: Array, skip: int) -> Array:
	var out: Array = []
	for i in troops.size():
		if i == skip:
			continue
		out.append(troops[i])
	return out


## 右栏要显示的单位。手玩把规则说死了（第四轮改版后按「怎么选中的」分）：
##
##   · 玩家**拖拽框选** / 点左侧部队列表 / 按 1-2-3 → 显示**展开那支部队的将领**；
##   · 玩家**鼠标单击地图上的某个单位** → 显示**玩家点到的那个单位**；
##   · 玩家点左栏下半**单位格** → 右栏切到那个单位（hud 那边会顺手记成 "click"）；
##   · 点**其余部队**的将领格（= 换展开）→ 右栏跟着变成那支部队的将领。
##
## 落点：
##   · 「这一次选中是怎么来的」由 `input_ctrl.selection_origin` 记（"click" / "drag"）；
##   · 「点到了谁」由 `input_ctrl.clicked_unit` 记（点地图 / 点左栏单位格都会写它）；
##   · `troop` 是**左栏当前展开**的那一支，所以「点到的是不是展开那支的成员」用
##     `_in_troop()` 一问就知道 —— 是就显示它，不是就退回展开那支的将领。
##
## ⚠️ 为什么不用「选中列表的最后一个」当判据（第一版就是那么写的）：一次点选与一次框选
##   出来的 selected_units 长得一模一样，框选之后右栏会莫名其妙报某个亲兵（实机截图见过）。
func _right_unit(troop):
	var leader = null if troop == null else troop.get("leader", null)
	var clicked = null
	if input_ctrl != null and String(input_ctrl.selection_origin) == "click":
		clicked = input_ctrl.clicked_unit
	if clicked != null and clicked.alive and _in_troop(clicked, troop):
		return clicked
	return leader


## 这个单位是不是**某一支部队的成员**（含它自己就是队长的情况）
func _in_troop(u, troop) -> bool:
	if u == null or troop == null:
		return false
	var units: Array = troop.get("units", [])
	return units.has(u)


## 一串单位在左栏格子方框里的**短字**（与 unit_roster.short_name 同一套口径，
## 由 detail_panel 转交给网格 —— 网格不认识 world，所以短字在这里算好）。
func _unit_shorts(units: Array) -> Array:
	var out: Array = []
	var roster = detail_panel.roster_control() if detail_panel != null else null
	for u in units:
		out.append("" if roster == null else roster.short_name(u))
	return out


## 招募队列跟着哪一位将领：当前展开那支部队的队长（没展开就退回选中列表里第一个队长）
func _queue_leader(troop):
	if troop != null:
		var l = troop.get("leader", null)
		if l != null:
			return l
	return input_ctrl.first_selected_leader() if input_ctrl != null else null


# ------------------------------------------------------------------
# 选中的敌人（敌对单位 / 敌对建筑）
#
# 需求原话：「玩家可以选中敌对单位/建筑（且只能单个选中），但其右下角不会显示任何页签
#            （有格子，但格子内没东西）」。
#
# ★ 这一节只做**显示**：操作入口一个都不给（页签那一列见 `_tab_plan` 的 enemy 分支，
#   命令卡是空的）。所以这里的文案也**不出现任何己方动作**（升级 / 特化 / 招募 / 编队）。
# ------------------------------------------------------------------

## 现在选中的敌人是单位还是建筑（""=没选中敌人）。
##
## ★ 判据只有一处：`input_ctrl.selected_enemy_kind()` —— 单位与建筑在 logic/ 里
##   没有共同基类，那种「靠字段猜类型」的事只该在一个地方做（见那个函数的注释）。
func _selected_enemy_kind() -> String:
	if input_ctrl == null:
		return ""
	return String(input_ctrl.selected_enemy_kind())


## 选中敌人时把详细信息面板刷成「它是什么」。
##
## ★★ 左栏**整块留空**（`set_troops(null, [])`）：左栏那 1 + 3×3 是「选中的己方部队 /
##    建筑」的编组视图，敌人只有**一个**、也进不了编组 —— 填进去只会让玩家以为
##    自己能指挥它。右栏照常报它的名称与数值（那是「看一眼它多硬」该有的信息）。
## ★ 右上角那块面板（招募队列 / 读条）也不给：`set_queue(null)`。
## ★ 选中**敌方的区划中心**时走的是这条路（不是区划详情那一条，见 input_controller
##   `_on_left_click` 里的归属判定）—— 否则玩家能给敌人的区划做特化。
func _refresh_enemy_detail() -> void:
	var e = input_ctrl.selected_enemy
	if e == null:
		return
	detail_panel.set_troops(null, [])
	detail_panel.set_queue(null)
	match _selected_enemy_kind():
		"unit":
			detail_panel.set_unit_avatar_text(_unit_short(e))
			detail_panel.set_unit_name(String(e.name))
			detail_panel.set_detail(_enemy_unit_text(e))
		"building":
			detail_panel.set_unit_avatar_text(_building_short(e))
			detail_panel.set_unit_name(e.display_name())
			detail_panel.set_detail(_enemy_building_text(e))


## 敌对单位的数值（**只有它是什么 + 打得多疼**）。
##
## ★ 与己方的 `_unit_text` 只差一件事：**不写濒死那一段**。
##   濒死是「玩家自己的将领」才有的机制（要读回复进度、判断能不能再起），
##   敌人的将领濒死时对玩家的意义只是「它现在打不了人」，多写三行反而会误导。
##   ⚠️ 也正因为不写那一段，敌人那几行永远是固定的三行 —— 面板不会忽然变高。
func _enemy_unit_text(u) -> String:
	if u == null:
		return "未选中"
	var lines: Array[String] = []
	lines.append("血量 %d / %d" % [int(round(u.hp)), int(round(u.hp_max))])
	# ★ 兵种那一行（「长枪兵 · 近战步兵」这种）——走 `cfg.unit_class_line`，
	#   与单位编辑器 / 其它界面同一处口径（界面不自己拼「步兵 / 骑兵」）。
	var klass := cfg.unit_class_line(String(u.unit_type))
	if klass != "":
		lines.append("兵种 %s · %s" % [cfg.unit_name_of(String(u.unit_type)), klass])
	lines.append("攻击力 %d" % int(u.combat_damage(cfg)))
	lines.append("攻击距离 %d 格 / 间隔 %.1fs" % [
		int(u.combat_range(cfg)), u.combat_cooldown(cfg)])
	return "\n".join(lines)


## 敌对建筑的数值（**只有它是什么 + 有多硬 + 打得多疼**）。
##
## ★★ 与己方的 `_building_text` 的差别（**故意不共用**，因为差的正是「操作性」）：
##   · 不写「等级 N / M」——那是**升级**表的进度，升级是己方动作（玩家对敌人的建筑
##     无能为力，写出来只会让人以为能升它）；
##   · 不写「正在升级：还剩 X 秒」同上（那是敌人自己的内政，与玩家无关）；
##   · 不写区划特化状态 —— 特化那一行本来就是「点自己的区划中心」看的；
##   · 不写「建造中」—— 敌方在建的建筑信息对玩家没有价值。
##   保留的：生命（决定要打多久）、攻击数值（决定站多远打它）、血量保底那句提示。
func _enemy_building_text(b) -> String:
	if b == null:
		return "未选中"
	var lines: Array[String] = []
	lines.append("生命 %d / %d" % [int(round(b.hp)), int(round(b.hp_max))])
	if b.is_attackable(cfg):
		lines.append("伤害 %d　射程 %d 格　间隔 %.1fs" % [
			int(b.attack_damage(cfg)), int(b.attack_range(cfg)), b.attack_cooldown(cfg),
		])
		if b.last_target != null and b.last_target.alive:
			# ★ 它正在打谁 —— 这条对玩家有用（那多半是自己人），所以留着
			lines.append("正在打：%s" % b.last_target.name)
	return "\n".join(lines)


# ------------------------------------------------------------------
# 右栏的文案（区划 / 建筑 / 选中单位的数值）
# ------------------------------------------------------------------

## 区划的标题（右栏「单位名称」那一行显示的）。
## ★★ 本版按需求只写**区划名本身**（用户原话：「选中区划中心时去掉『区划[xx]』文本」）——
##   原来这里写「区划「xx」」、详情正文开头又写一遍，两处都带那层壳，现在都没了。
func _zone_title(z: Dictionary) -> String:
	return String(z["name"])


## 建筑的短字（头像方块里的占位）
func _building_short(b) -> String:
	var n: String = b.display_name()
	return n.substr(0, 1) if n.length() > 0 else "建"


## 选中单位的短字（头像方块里的占位）：将领 = 名字首字，兵种 = 招募表里的 short
func _unit_short(u) -> String:
	if u == null:
		return ""
	if world != null and world.is_recruitable(String(u.kind)):
		return world.recruit_short_of(String(u.kind))
	var n: String = String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"


## 建筑的数值（生命 / 等级 / 箭塔伤害 / 大本营说明）。
##
## ★ 本版按需求**精简**：
##   · **去掉「归属」与「位置」两行**（谁的在建筑描边上一眼就看得出；坐标对玩家没用）；
##   · **大本营那句「（本版不会被打掉：血量保底 1）」也去掉** —— 那是说明锁血机制的
##     注释，不该出现在玩家界面上（用户原话：「大本营中的注释也去掉」）。
## ★★ **等级**那一行保留（需求确认「等级显示在右栏数值里」）：有升级表的建筑写
##   「等级 2 / 3」。
## ★★ 本版又按需求去掉两处（用户原话：「不要显示『升级到 2 级』文本」+
##   「去除大本营的『开局自带，不可建造，不可拆除』文本」）：
##   · **「升级到 N 级：花费（时间）」那两行**（含满级那句「已经是最高等级」）——
##     要花多少钱 / 多久从界面上撤掉，等级本身照旧看得到；
##   · **大本营那句说明**。`config.json` 里 `building.base.desc` 一个字没动
##     （它是地图编辑器那边的数据），只是不再往详情栏里画。
##   ⚠️ 「正在升级：升到 N 级，还剩 X 秒」**留着** —— 那是**进行中**的读条反馈，
##      不是「升级到 N 级」那条花费说明。
func _building_text(b) -> String:
	var lines: Array[String] = []
	lines.append("生命 %d / %d" % [int(round(b.hp)), int(round(b.hp_max))])
	# ★ 建造读条（config 的 build_sec > 0 时才有）：造完之前不开火，这里给一句进行中的反馈
	if b.is_under_construction():
		lines.append("建造中：还剩 %s 秒" % _fmt_num(b.build_eta()))
	if world.building_can_upgrade(b.type):
		var max_lv: int = world.building_max_level(b.type)
		lines.append("等级 %d / %d" % [b.level, max_lv])
		if b.is_upgrading():
			lines.append("正在升级：升到 %d 级，还剩 %s 秒" % [
				b.level + 1, _fmt_num(b.upgrade_eta())])
	# ★ 攻击那一行改成**通用**的（原来是 `type == TYPE_TOWER` 才有）：判据是
	#   config 的 attackable，数值按当前等级取（编辑器里新加的炮塔也看得见自己的数值）。
	if b.is_attackable(cfg):
		lines.append("伤害 %d　射程 %d 格　间隔 %.1fs" % [
			int(b.attack_damage(cfg)), int(b.attack_range(cfg)), b.attack_cooldown(cfg),
		])
		if b.last_target != null and b.last_target.alive:
			lines.append("正在打：%s" % b.last_target.name)
	if b.type == BuildingRes.TYPE_ZONE_CENTER:
		# 区划中心自己没有数值，但它所属**区划的特化**状态要写在这里
		# （点中心时右栏显示的是区划详情那一套，这里是「从网格 / 框选点中它」时的兜底）
		var spec_line := _zone_spec_line(world.zone_of_center_building(b))
		if spec_line != "":
			lines.append(spec_line)
	return "\n".join(lines)


## 一个区划的特化状态那一行（没特化 → ""）。
##   读条中：「正在特化：粮食特化，还剩 3 秒」/「正在取消特化：…，还剩 3 秒」
##   已完成：「特化：粮食特化（本区块粮食 +0.5／地块／秒）」——
##   括号里那句直接取 `config.json` 的 `zone_spec.list[].line`（效果文案跟着数据走）。
func _zone_spec_line(z) -> String:
	if typeof(z) != TYPE_DICTIONARY:
		return ""
	if world.zone_spec_busy(z):
		var is_cancel: bool = world.zone_spec_is_cancel(z)
		var who_id := String(z.get("spec_done", "")) if is_cancel else String(z.get("spec_kind", ""))
		var who := String(cfg.spec_entry(who_id).get("name", who_id))
		return "%s：%s，还剩 %s 秒" % [
			"正在取消特化" if is_cancel else "正在特化", who, _fmt_num(world.zone_spec_eta(z))]
	var done := String(z.get("spec_done", ""))
	if done == "":
		return ""
	var e: Dictionary = cfg.spec_entry(done)
	return "特化：%s（%s）" % [String(e.get("name", done)), String(e.get("line", ""))]


## ★★ 本版按需求**砍成单栏、只留三项数值**（用户原话：「选中部队时在第一列只显示选中的
##   单位血量，攻击力和攻击距离攻击速度，第二列的编制和状态去掉」+
##   「把选中部队时的『已选中x支部队』去掉，把兵种显示也去掉」）：
##
##     血量 200 / 200
##     攻击力 10
##     攻击距离 3 格 / 间隔 1.2s
##
##   · **右栏（第二栏）整块不再出现** —— 编制与状态（含「指定攻击」那几条命令反馈）
##     都按需求去掉了，所以这里返回的文本里**没有 `\t`**，detail_panel 那边自然
##     只填左栏、把右栏 Label 收起来（见 detail_panel.set_detail）。
##   · **「兵种 …（步兵）」那一行也去掉了**（同上，第二条需求）—— 步兵 / 骑兵、
##     远程与额外伤害那套标签不再进详情栏。
##   · **多选时那句「已选中 N 支部队」也去掉了**（同上）—— 选中了几支看左侧部队列表的
##     高亮就知道，详情栏只报**当前这一个单位**的三项数值。
##   · `troops` 这个参数仍然收着（调用方照旧传）：现在文案与它无关，但接口不变，
##     免得以后再要「多选提示」时又去改所有调用点。
##   · 移动速度、所在区块、buff 占位行这些**一律不显示**（要恢复就在这里加回一行）。
##   ⚠️ 每行**最多一行文字**：正文关掉了 autowrap，一行太长会被 `clip_text` 裁掉
##      （版式不散，但说明文案该改短）。
func _unit_text(shown, troops: Array) -> String:
	if shown == null:
		return "未选中"
	var lines: Array[String] = []
	lines.append("血量 %d / %d" % [int(round(shown.hp)), int(round(shown.hp_max))])
	# ★★ 濒死的将领（本轮新增）：右栏这块数值区是玩家唯一能读到「还要等多久」的地方，
	#    所以把状态 / 回复进度 / 再起门槛都写出来（需求要玩家能判断什么时候能再起）。
	if shown.is_downed():
		lines.append("★ 濒死：倒在原地、不会受到伤害，也不能行动")
		lines.append("回复 %d%%（上限 %d%%）· 每 %s 秒 +%d%%" % [
			int(round(shown.hp_ratio() * 100.0)),
			int(round(cfg.revive_regen_cap_ratio * 100.0)),
			_fmt_num(cfg.revive_regen_sec),
			int(round(cfg.revive_regen_ratio * 100.0))])
		if shown.is_reviving():
			lines.append("再起读条中：%d%%（还剩 %s 秒）" % [
				int(round(shown.revive_progress() * 100.0)), _fmt_num(shown.revive_remaining)])
		elif shown.revive_ready(cfg):
			lines.append("可以在「操作」页点「再起」（%s，读条 %s 秒）" % [
				_cost_text(world.revive_cost()), _fmt_num(world.revive_channel_sec())])
		else:
			lines.append("血量回到 %d%% 才能再起" % int(round(world.revive_ready_ratio() * 100.0)))
		lines.append("攻击力 %d（濒死期间不出手）" % int(shown.combat_damage(cfg)))
		return "\n".join(lines)
	lines.append("攻击力 %d" % int(shown.combat_damage(cfg)))
	lines.append("攻击距离 %d 格 / 间隔 %.1fs" % [
		int(shown.combat_range(cfg)), shown.combat_cooldown(cfg)])
	return "\n".join(lines)


## 区划详情（左键点区划中心时显示）：大小 / **种类** / 产能 / 人口。
##
## ★ 本版按需求**精简**：
##   · **去掉「归属」那一行**（点开区划详情的玩家早就知道这块地是谁的；
##     归属在整个底栏里也不再出现）；
##   · 产能**不写单位**（原来写的是「／地块／秒」）——左边那个数是地图编辑器里填的
##     **每地块**产能，括号里的「合计」才是这个区划实际的产出（每地块 × 地块数）。
##     两个数都不带单位（用户原话：「区划产能不需要写单位」）；
##   · ★★ **去掉开头那行「区划「xx」」**（用户原话：「选中区划中心时去掉『区划[xx]』文本」）——
##     区划名只在上方那一行（detail_panel.set_unit_name ← `_zone_title`，见 hud.refresh）
##     里出现一次，详情正文里不再重复；
##   · ★★ **区划种类后面那串「（每地块每秒 …）」不再写**（用户原话：「区划种类后不要加
##     『（每地块每秒xxx）』」）—— 产能下面三行里逐个列着，种类那一行只报名字。
##     ⚠️ 那句文案来自 `config.json` 的 `zone_kind.list[].line`：**数据一个字没动**
##     （它是地图编辑器那边的说明），只是不再往详情栏里画；
##   · ★★ **「人口产能」与「人口」两行合并成一行**（用户原话：「人口产能和人口两个信息
##     合并，变成『人口：x（产能x）』」）：括号里是**每地块**的人口产能（与粮食 / 黄金
##     那两行的口径一致，特化加成也算进去了），括号外是区划现在的人口（向下取整）。
##
## ⚠️ 行的顺序（本版调过一次，别随手挪回去）：
##     大小 → 种类 → **特化状态** → 粮食 → 黄金 → 人口 → 人口上限
##   特化那句原来排在最末。合并之后整屏最多 7 行（84 + 14 = 98px），而数值框的可视高只有
##   88px ⇒ 排在最后的那一行**会被 clip 掉**，被切掉的恰好是「正在特化 / 已完成特化」——
##   最该看见的那一条。所以它上移到产能前面（它本来就属于「种类」那一带的信息）。
##
## ★★ 本次改动（用户需求）：「选中区划中心时（不论是敌是友是中立），不用显示区划中心的
##   血量（区划中心没有血量），可以显示其区划的产能（粮食 / 黄金 / 人口产能 / 人口上限），
##   如果是友军 / 己方区划，额外显示其当前人口数量」。
##   ⇒ 归路上由 `input_controller` 保证「任何归属的中心都走这一条」，
##     这里再用 `show_population` 决定**当前人口**那一行给不给：
##       · true  = 自己 / 友军区划 → 「人口：<现在>（产能 x）」
##       · false = 敌方 / 中立区划 → 「人口产能：x」（只报产能，不报现在有多少人）
##   ⚠️ 人口上限**两种都显示** —— 它是这块地值多少钱的一部分（用户把它列为产能之一），
##     而不像「现在有多少人」那样是对手的情报。
func _zone_text(z: Dictionary, show_population: bool = true) -> String:
	var lines: Array[String] = []
	lines.append("区划大小：%d 个地块" % int(z["tile_count"]))
	# ★★ 本轮新增：**区划种类**那一行（粮食 / 黄金 / 人口区划）——
	#   它决定这个区划能做哪些特化（见 _building_order_entries），玩家必须看得见。
	# ★ 本版**只写种类名**，后面那串每地块产能说明按需求去掉了（见函数头）。
	var kind_entry: Dictionary = world.zones.kind_entry_of(z)
	if not kind_entry.is_empty():
		lines.append("区划种类：%s" % String(kind_entry.get("name", "")))
	# 特化状态那一行（没特化 / 读条中 → 由 _zone_spec_line 决定写什么）。
	# ★ 位置见函数头那段 ⚠️：它必须在产能前面，否则整屏 7 行时会被裁掉。
	var spec_line := _zone_spec_line(z)
	if spec_line != "":
		lines.append(spec_line)
	var prod: Dictionary = z["production"]
	var n := float(z["tile_count"])
	# ★★ 本轮：产能按**特化效果**显示（特化是两种形状，见 UpgradeRes.zone_spec_effect）：
	#   · 粮食 / 黄金特化 = 每地块每秒 +0.5 ⇒ 这里直接加进「每地块产能」那一档；
	#   · 人口特化 = 人口产量 ×1.25 ⇒ 乘在人口产能上。
	#   不这么做的话，玩家做完特化看到的数字纹丝不动，会以为特化没生效。
	var eff: Dictionary = world.zone_spec_effect(z)
	var food := float(prod["food"]) + float(eff["food_per_tile"])
	var gold := float(prod["gold"]) + float(eff["gold_per_tile"])
	var pop := float(prod["population"]) * float(eff["population_mult"])
	var pop_cap := float(world.zones.population_cap_of(z))
	lines.append("粮食产能：%s（合计 %s）" % [
		_fmt_num(food), _fmt_num(food * n)])
	lines.append("黄金产能：%s（合计 %s）" % [
		_fmt_num(gold), _fmt_num(gold * n)])
	# ★ 人口那一行（本版合并了「人口产能」与「人口」两行）：
	#   括号里 = 每地块人口产能（特化后的），括号外 = 当前人口。
	#   ⚠️ 人口显示**永远是整数**（向下取整，用户需求）—— 权威值是浮点（按秒累积），
	#      直接印出小数点会让玩家看到「1.9999998」这种数。
	# ★★ 本次：当前人口只给「自己 / 友军」看；敌占 / 无主区划只报产能（见函数头）。
	if show_population:
		lines.append("人口：%d（产能%s）" % [world.zones.population_floor(z), _fmt_num(pop)])
	else:
		lines.append("人口产能：%s" % _fmt_num(pop))
	# ★ 上限**单列一行**：不然「人口怎么不涨了」在界面上没有任何解释。
	#   （合并后那一行按需求只放「人口 + 产能」，塞不下上限，所以它留在下面这一行。）
	lines.append("人口上限：%s" % _fmt_num(pop_cap))
	return "\n".join(lines)


## 这个区划是不是**自己 / 友军**的（用于「当前人口给不给看」与「给不给操作页签」）。
##
## ★ 判据走 `FactionRes.same_side`（盟友算同一方）—— 与占领 / 资源 / 视界那几处同一套口径。
## ★ 空 owner（无主）恒为 false：`same_side(任何, "")` 为假（见 logic/faction.gd）。
func _zone_is_friendly(z: Dictionary) -> bool:
	if z == null or world == null:
		return false
	return FactionRes.same_side(String(z.get("owner", "")), String(world.my_faction))


## 数字显示：整数就不带小数点；小数最多 3 位、末尾的 0 去掉
## （与地图编辑器 / 导出的 JSON 同一种写法）。
##
## ⚠️ 这里踩过一次（实机刷屏报错）：
##     `E 0:00:28:967 hud.gd:770 @ _fmt_num(): String formatting error:
##      unsupported format character` —— 小数那一路原来写的是 `"%g" % v`，
##     而 **Godot 的 `%` 格式化没有 `%g`**（支持的是 %s %c %d %o %x %X %f %v %%），
##     于是「区划的人口产能不是整数」时每帧都报一次，还连着后面所有取值一起失败。
##   现在用 `%f`（Godot 一定支持）+ 手工去掉尾部的 0 与小数点 —— 结果与原意一致，
##   也不依赖引擎版本对格式符的支持范围。
func _fmt_num(v: float) -> String:
	if is_nan(v) or is_inf(v):
		return "0"
	if absf(v - round(v)) < 1e-9:
		return "%d" % int(round(v))
	var s := "%.3f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


# ------------------------------------------------------------------
# 事件：本版**不再显示**
#
# 按需求把「详细信息」右栏的事件日志整块删掉了，所以这里没有 consume_events /
# push_line / toast / _format_event —— 逻辑层照旧把事件收集进 world.tick() 的返回值
# （那是「逻辑不写 UI」这条边界，测试也在用），只是当前没有任何界面把它们画出来。
#
# ★ 想恢复日志：把 detail_panel 里的日志栏加回来、在这里把事件翻成文案即可，
#   事件本身一条都没少（types 见 logic/world.gd 与 logic/combat.gd 的 push_event）。
# ------------------------------------------------------------------
