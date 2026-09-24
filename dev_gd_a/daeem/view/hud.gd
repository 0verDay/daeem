## hud.gd —— 新 UI（UI 改版：**废弃**原来的「顶栏 + 右侧选中面板 + 底部日志」）
##
## 布局逐像素照参考图（1920×1080），几何全部写在 view/ui_layout.gd 里：
##
##   右上 设置（80×160，点不动）
##   左侧 部队 1~10（10 槽 × 60 高，内容动态生成）
##   左下 小地图（400×400：整张地图 + 视野框，左键点击移动镜头、按住拖动跟手，见 view/minimap.gd）
##   底栏 y 840..1080：
##     详细信息 1030×240（左栏 = 1 + 3×3 共 10 格；右栏 = 选中单位的头像 / 名称 / 数值）
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
extends CanvasLayer

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
const MinimapRes = preload("res://view/minimap.gd")

var cfg: ConfigRes = null
var world = null
var input_ctrl = null
var camera_rig = null

var squad_panel: Control = null
var detail_panel: PanelContainer = null
var command_card: Control = null
var page_tabs: Control = null
## ★ 科技九格（盖在命令卡上，只有「科技」页才显示）。见 view/tech_grid.gd。
var tech_grid: Control = null
var settings_button: Button = null
## 左下角的小地图（400×400）。★ 变量名仍然是占位时代的 `map_placeholder`：
## 测试（tests/test_ui.gd）按这个名字断言它的位置与尺寸，换名字只会白改一把。
var map_placeholder: Control = null
var minimap: Control = null
var faction_placeholder: PanelContainer = null

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
## 上一次推给 page_tabs 的配置（kind + 页列表）。每帧比一次，不变就不重推 ——
## 否则每帧都会重建命令卡。
var _tab_key: String = ""
## 每一类选中**上次停在那一页**（kind → page）。
## ★ 为什么要记：玩家切到「单位」页排兵，点一下空地（没选中 → 建筑页），
##   再点回部队时不该被抢回「操作」页 —— 那会让「我刚看的那一页」凭空跳走。
var _page_memory: Dictionary = {}


func setup(p_cfg: ConfigRes, p_world, p_input, theme: Theme, p_camera_rig = null) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input
	camera_rig = p_camera_rig
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
	_build_detail_panel()
	_build_command_card()
	_build_page_tabs()
	_build_settings_button()
	_build_squad_panel()

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
	map_placeholder.add_theme_stylebox_override("panel", UiStyleRes.panel_style(UiStyleRes.BG_SOFT))
	UiLayoutRes.apply_rect(map_placeholder, UiLayoutRes.MAP_RECT, false, true)
	_root.add_child(map_placeholder)

	minimap = MinimapRes.new()
	minimap.name = "Minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_placeholder.add_child(minimap)
	minimap.setup(cfg, world, camera_rig)


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
	label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
	faction_placeholder.add_child(label)


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


## 设置：参考图里它是右上角一条实心蓝。**点不动**（需求）——
## 所以这里不接任何处理函数，但仍然让它吃掉点击（不穿到地图上）。
func _build_settings_button() -> void:
	settings_button = Button.new()
	settings_button.name = "SettingsButton"
	settings_button.text = "设置"
	settings_button.focus_mode = Control.FOCUS_NONE
	settings_button.add_theme_font_size_override("font_size", UiStyleRes.FS_TITLE)
	settings_button.add_theme_color_override("font_color", UiStyleRes.TEXT_ON_ACCENT)
	settings_button.add_theme_color_override("font_hover_color", UiStyleRes.TEXT_ON_ACCENT)
	settings_button.add_theme_color_override("font_pressed_color", UiStyleRes.TEXT_ON_ACCENT)
	settings_button.add_theme_stylebox_override("normal", UiStyleRes.accent_button())
	settings_button.add_theme_stylebox_override("hover", UiStyleRes.accent_button_hover())
	settings_button.add_theme_stylebox_override("pressed", UiStyleRes.accent_button_hover())
	settings_button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	UiLayoutRes.apply_rect(settings_button, UiLayoutRes.SETTINGS_RECT, true, false)
	_root.add_child(settings_button)


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
	# 区划中心（左键点中心 = 看这个区划的详情）→ 「操作」（三个特化）+「招募」
	# ★ 本轮改动：原来这里只有「招募」一页；需求要求所有单位 / 建筑都有操作页，
	#   而区划中心的操作页就是粮食 / 黄金 / 人口特化那一页。
	if input_ctrl.selected_zone != null:
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
##   建筑页 ← logic/building.gd 的 DEFS 里 buildable = true 的那几项（城墙 / 箭塔）
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
			for key in BuildingRes.DEFS.keys():
				var d: Dictionary = BuildingRes.DEFS[key]
				if not bool(d.get("buildable", false)):
					continue
				entries.append({
					"type": "build",
					"build_type": String(d.get("id", key)),
					"name": String(d.get("name", key)),
					"desc": "%s（快捷键 %s，也可点这一格）" % [String(d.get("desc", "")), String(d.get("hotkey", ""))],
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
		})
	return out


## 「操作」页的四格：对**当前选中的部队**下达的指令（需求原话：「如移动，攻击，行军等」）。
## ★ 前三格是「进命令模式 → 左键点地图 / 点目标」那种两步式（见 input_controller.order_mode）；
##   「停止」不需要目标，点一下当场生效。
## ★ 键位按命令卡的顺序 Q/W/E/A…（第 4 格是 A），与其它页同一套规则。
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
##   · 区划中心            → 粮食 / 黄金 / 人口特化三格；已经特化过则换成「取消特化」
##
## ★ 三种状态互斥，所以最多 3 格：
##     ① 读条中（升级 / 特化 / 取消特化）→ 只有「取消」那一格；
##     ② 区划已特化                      → 只有「取消特化」那一格；
##     ③ 平常                            → 升级那一格（建筑）/ 三个特化（区划中心）。
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
		# ③ 平常：三个特化（只能选一个）
		var out: Array = []
		var spec_path: Variant = cfg.get_path_value("zone_spec.list")
		if typeof(spec_path) == TYPE_ARRAY:
			for item in (spec_path as Array):
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var e: Dictionary = item
				out.append({
					"type": "zone_specialize",
					"spec": String(e.get("id", "")),
					"name": String(e.get("name", e.get("id", ""))),
					"desc": String(e.get("desc", "")),
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
## 目前唯一的拒因是 `recruiting`：将领正在招募时，**它和它辖下的部队**都不接受
## 移动 / 攻击命令（用户需求），而玩家右键点下去什么都没发生看起来就是坏了。
func order_reject_text(reason: String) -> String:
	match reason:
		"recruiting":
			return "将领正在招募单位：它和它的部队这会儿只警戒，不接受指令"
	return "这条指令现在下不了"


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
## 与招募 / 科技同一条约定：逻辑层只给码，文案只在这里。
func upgrade_reject_text(reason: String) -> String:
	match reason:
		"busy":
			return "这一项正在读条：等它读完，或者点信息栏那一格取消"
		"max_level":
			return "已经是最高等级了"
		"spec_done":
			return "这个区划已经特化过了：先「取消特化」才能换别的"
		"spec":
			return "没有这种特化"
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


## ★★ 当前这一屏「操作」页该画哪几格 —— 用一个**短字符串签名**表达。
##
## 为什么需要它（本轮踩到的）：操作页的内容不只取决于「页签 + 选中了谁」，
## 还取决于**选中对象的权威状态**（建筑在不在读条 / 区划特化到哪一步 / 满没满级）。
## 而 `_rebuild_card()` 原来只在「页签组合变了」时才跑 ——
## 于是「点读条面板取消升级」之后，那一格还写着「升级城墙」，
## 要等下一次切页才更新（看着像点了没反应）。
##
## 做法：把「与内容有关的那些事实」拼成签名，`refresh()` 每帧比一次，变了就重建。
## ⚠️ 签名只放**便宜、稳定**的字段（枚举字符串 + 两个计数），不放对象引用。
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
	# ★★ 页签先按「现在选中了什么」推上去（选中部队 = 操作/单位；选中区划中心 = 招募；
	#    选中大本营 = 科技；选中普通建筑 = 一颗都没有；什么都没选中 = 建筑 + 科技）。
	#    命令卡的内容跟着页签走（page_tabs 发 page_changed → _rebuild_card）。
	_sync_tabs()
	# ★ 科技九格每帧刷一次（内容 / 高亮都取决于权威的启用状态，见 _refresh_tech_grid）：
	#   命令卡那条路只在「页签组合变了」时跑，跟不上「玩家点了一格科技」这种变化。
	# ★★ 命令卡的内容还跟**权威状态**走（建筑在不在读条 / 区划特化到哪一步 / 满没满级），
	#   而状态是**点一下那一格**就变的 —— 所以在那条命令流里显式重建一次
	#   （见 `_on_building_action`）。`refresh()` 只负责「页签 / 选中变了」那一路。
	_refresh_tech_grid(page_tabs != null and String(page_tabs.page()) == PageTabsRes.PAGE_TECH)
	# ★ 详细信息是**左右两栏**（第三轮改版，见 view/detail_panel.gd 的文件头）：
	#   左栏 = 当前展开的那支部队（上半）+ 选中部队的将领头像网格（下半）
	#   右栏 = 选中单位的头像 / 名称 / buff / 数值
	# 选中对象的三种互斥情况：区划 → 建筑 → 单位（见 refresh 里的分支）
	if input_ctrl.selected_zone != null:
		detail_panel.set_troops(null, [])
		detail_panel.set_unit_avatar_text("区")
		detail_panel.set_unit_name(_zone_title(input_ctrl.selected_zone))
		detail_panel.set_detail(_zone_text(input_ctrl.selected_zone))
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
# 右栏的文案（区划 / 建筑 / 选中单位的数值）
# ------------------------------------------------------------------

## 区划的标题（右栏「单位名称」那一行显示的）
func _zone_title(z: Dictionary) -> String:
	return "区划「%s」" % String(z["name"])


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
## ★★ 本轮新增：**等级**那一行（需求确认「等级显示在右栏数值里」）——
##   有升级表的建筑写「等级 2 / 3」，同时把「升到下一级要什么」写清楚，
##   于是「为什么这一格点了没反应（满级 / 钱不够）」在界面上有据可查。
func _building_text(b) -> String:
	var lines: Array[String] = []
	lines.append("生命 %d / %d" % [int(round(b.hp)), int(round(b.hp_max))])
	if world.building_can_upgrade(b.type):
		var max_lv: int = world.building_max_level(b.type)
		lines.append("等级 %d / %d" % [b.level, max_lv])
		if b.is_upgrading():
			lines.append("正在升级：升到 %d 级，还剩 %s 秒" % [
				b.level + 1, _fmt_num(b.upgrade_eta())])
		elif b.level < max_lv:
			lines.append("升级到 %d 级：%s（%s 秒）" % [
				b.level + 1, _cost_text(world.building_upgrade_cost(b)),
				_fmt_num(world.building_upgrade_time(b))])
		else:
			lines.append("已经是最高等级")
	if b.type == BuildingRes.TYPE_TOWER:
		lines.append("伤害 %d　射程 %d 格　间隔 %.1fs" % [
			int(b.tower_damage(cfg)), int(b.tower_range(cfg)), b.tower_cooldown(cfg),
		])
		if b.last_target != null and b.last_target.alive:
			lines.append("正在打：%s" % b.last_target.name)
	if b.type == BuildingRes.TYPE_ZONE_CENTER:
		# 区划中心自己没有数值，但它所属**区划的特化**状态要写在这里
		# （点中心时右栏显示的是区划详情那一套，这里是「从网格 / 框选点中它」时的兜底）
		var spec_line := _zone_spec_line(world.zone_of_center_building(b))
		if spec_line != "":
			lines.append(spec_line)
	if b.type == BuildingRes.TYPE_BASE:
		lines.append("开局自带，不可建造、不可拆除")
	return "\n".join(lines)


## 一个区划的特化状态那一行（没特化 → ""）。
##   读条中：「正在特化：粮食特化，还剩 3 秒」/「正在取消特化：…，还剩 3 秒」
##   已完成：「特化：粮食特化（本区块粮食 +10%）」
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


## ★★ 数值区改成**两栏制表位**（本轮，手玩原话：「只需要给基础数值即可」）。
##   制表符 `\t` 从 fs 列跳到下一栏（`\t` 的宽度由字体自己定，实测 fs=13 时落在 ~212px），
##   右栏正文因此长这样（不是「左右两栏控件」，就是一个 Label 里的两栏文本）：
##
##     血量 200 / 200        编制 3 / 11          ← 将领才有右栏（★ 手玩原话）
##     攻击力 10             状态：待命
##     攻击距离 3 格 / 间隔 1.2s
##
##   ★ 手玩拍板的取舍：
##     · **只留基础数值**：血量 / 攻击力 / 攻击距离 / 间隔 / 编制；
##       移动速度、所在区块、buff 占位行、行军攻击这些**一律不显示**（要恢复就在这里加回一行）。
##     · **编制只给将领看**（「假如是将领才要显示编制，兵不用显示编制」）——
##       判据是 `world.is_team_leader()`，亲兵那一行右栏留空。
##   ⚠️ 每行**最多一行文字**：正文关掉了 autowrap，多出来的换行只能是制表位带来的两栏，
##      否则版式会散（见 detail_panel 里 _body 的注释）。
##   ⚠️ 「指定攻击」那一行要留着（tests/test_ui.gd 断言它在）：它是命令的**可见反馈**，
##      玩家下了指定攻击必须能在界面上看见目标。
func _unit_text(shown, troops: Array) -> String:
	if shown == null:
		return "未选中"
	var left: Array[String] = []
	var right: Array[String] = []
	if troops.size() > 1 or (troops.size() == 1 and (troops[0]["units"] as Array).size() > 1):
		left.append("已选中 %d 支部队" % troops.size())
	left.append("血量 %d / %d" % [int(round(shown.hp)), int(round(shown.hp_max))])
	left.append("攻击力 %d" % int(shown.combat_damage(cfg)))
	left.append("攻击距离 %d 格 / 间隔 %.1fs" % [
		int(shown.combat_range(cfg)), shown.combat_cooldown(cfg)])
	# 编制：★ 只有将领才有「编制」（它辖下的亲兵上限），亲兵自己不显示
	if world.is_team_leader(shown):
		right.append("编制 %d / %d" % [_retinue_size(shown), UiLayoutRes.UNIT_CAP])
	# 状态（含两条命令反馈）——`指定攻击` 那一条必须留着，见上面的注释
	if shown.ordered_target != null and shown.ordered_target.alive:
		right.append("★ 指定攻击：%s" % shown.ordered_target.name)
	elif shown.ordered_building != null and shown.ordered_building.alive:
		right.append("★ 指定拆除：%s" % shown.ordered_building.display_name())
	elif shown.has_attack_move:
		right.append("★ 行军攻击中")
	elif shown.target != null and shown.target.alive:
		right.append("交战中：%s" % shown.target.name)
	elif shown.target_building != null and shown.target_building.alive:
		right.append("正在拆：%s" % shown.target_building.display_name())
	else:
		right.append("状态：%s" % ("移动中" if shown.moving else "待命"))
	return _two_columns(left, right)


## 把两栏文本拼成「左栏 + \t + 右栏」的若干行；某一栏不够长就留空（制表位照样对齐）。
func _two_columns(left: Array, right: Array) -> String:
	var n: int = maxi(left.size(), right.size())
	var out: PackedStringArray = []
	for i in n:
		var l: String = String(left[i]) if i < left.size() else ""
		var r: String = String(right[i]) if i < right.size() else ""
		out.append("%s\t%s" % [l, r] if r != "" else l)
	return "\n".join(out)


## 一个将领辖下的亲兵数（不是将领自己 → 0）
func _retinue_size(u) -> int:
	if world == null or u == null or not world.is_team_leader(u):
		return 0
	return world.retinue_of(u.id).size()


## 区划详情（左键点区划中心时显示）：区划名 / 大小 / 产能 / 人口。
##
## ★ 本版按需求**精简**：
##   · **去掉「归属」那一行**（点开区划详情的玩家早就知道这块地是谁的；
##     归属在整个底栏里也不再出现）；
##   · 产能**不写单位**（原来写的是「／地块／秒」）——左边那个数是地图编辑器里填的
##     **每地块**产能，括号里的「合计」才是这个区划实际的产出（每地块 × 地块数）。
##     两个数都不带单位（用户原话：「区划产能不需要写单位」）。
func _zone_text(z: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("区划「%s」" % String(z["name"]))
	lines.append("区划大小：%d 个地块" % int(z["tile_count"]))
	var prod: Dictionary = z["production"]
	var n := float(z["tile_count"])
	var food := float(prod["food"])
	var gold := float(prod["gold"])
	# ★★ 本轮：产能按**特化倍率**显示（有特化时写成「2（+10% → 2.2）」那一套）——
	#   不然玩家做完特化看到的数字纹丝不动，会以为特化没生效。
	var mult: Dictionary = world.zone_spec_mult(z)
	var f_mult := float(mult["food"])
	var g_mult := float(mult["gold"])
	var p_mult := float(mult["population"])
	lines.append("粮食产能：%s（合计 %s）" % [
		_fmt_num(food * f_mult), _fmt_num(food * f_mult * n)])
	lines.append("黄金产能：%s（合计 %s）" % [
		_fmt_num(gold * g_mult), _fmt_num(gold * g_mult * n)])
	lines.append("人口产能：%s" % _fmt_num(float(prod["population"]) * p_mult))
	# 特化状态那一行（没特化 / 读条中 → 由 _zone_spec_line 决定写什么）
	var spec_line := _zone_spec_line(z)
	if spec_line != "":
		lines.append(spec_line)
	# ★ 人口显示**永远是整数**（向下取整，用户需求）—— 权威值是浮点（按秒累积），
	#   直接印出小数点会让玩家看到「1.9999998」这种数。
	# ★ 上限一并显示：不然「人口怎么不涨了」在界面上没有任何解释。
	lines.append("人口：%d（上限 %s）" % [
		world.zones.population_floor(z), _fmt_num(world.zones.population_cap_of(z)),
	])
	return "\n".join(lines)


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
