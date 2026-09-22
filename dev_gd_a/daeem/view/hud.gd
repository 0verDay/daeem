## hud.gd —— 新 UI（UI 改版：**废弃**原来的「顶栏 + 右侧选中面板 + 底部日志」）
##
## 布局逐像素照参考图（1920×1080），几何全部写在 view/ui_layout.gd 里：
##
##   右上 设置（80×160，点不动）
##   左侧 部队 1~10（10 槽 × 60 高，内容动态生成）
##   左下 小地图（400×400：整张地图 + 视野框，左键点击移动镜头，见 view/minimap.gd）
##   底栏 y 840..1080：
##     详细信息 1030×240（左栏 = 1 + 3×3 共 10 格；右栏 = 选中单位的头像 / 名称 / 数值）
##     阵营 / 盾徽 / 旗帜（150 宽，**本轮不做**，只留位置）
##     命令卡 3×3（每格 80，内容随页签实时切换）
##     单位 / 建筑 / 科技（单位、建筑切页；**科技点不动**）
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

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const SquadPanelRes = preload("res://view/squad_panel.gd")
const DetailPanelRes = preload("res://view/detail_panel.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")
const CommandCardRes = preload("res://view/command_card.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const MinimapRes = preload("res://view/minimap.gd")

var cfg: ConfigRes = null
var world = null
var input_ctrl = null
var camera_rig = null

var squad_panel: Control = null
var detail_panel: PanelContainer = null
var command_card: Control = null
var page_tabs: Control = null
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
## 整张地图 + 玩家当前的视野框 + 左键点击移动镜头。
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


func _build_command_card() -> void:
	command_card = CommandCardRes.new()
	_root.add_child(command_card)
	command_card.setup()
	command_card.entry_activated.connect(_on_card_entry)


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
	_rebuild_card()


## 按当前页重组命令卡。
##
## 两张表都是**数据驱动**的，这里不写死名字：
##   建筑页 ← logic/building.gd 的 DEFS 里 buildable = true 的那几项（城墙 / 箭塔）
##   单位页 ← config.json 的 recruit.list（现在只有一项：占位单位 = 招募亲兵）
## 键位按参考图顺序 Q/W/E/A/S/D/Z/X/C 依次分配（第 0 项 = Q）。
func _rebuild_card() -> void:
	if command_card == null:
		return
	var entries: Array = []
	var page := String(page_tabs.page()) if page_tabs != null else PageTabsRes.PAGE_UNIT
	if page == PageTabsRes.PAGE_BUILD:
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
	elif page == PageTabsRes.PAGE_UNIT:
		var list: Variant = cfg.get_path_value("recruit.list") if cfg != null else null
		if typeof(list) == TYPE_ARRAY:
			for item in (list as Array):
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var e: Dictionary = item
				entries.append({
					"type": "recruit",
					"unit_kind": String(e.get("kind", "")),
					"name": String(e.get("label", e.get("kind", ""))),
					"desc": String(e.get("desc", "")),
				})
	command_card.set_entries(entries)


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


## 点了信息栏里招募队列的某一格 = **取消那一格**（后方的队列自动前移）。
##
## ★ 这里只发命令（`recruit_cancel`）：退多少钱、队列怎么前移全在权威侧算，
##   界面下一帧按权威状态重画 —— 所以本地不需要自己「删格子」。
func _on_queue_cell_activated(slot: int) -> void:
	if input_ctrl == null:
		return
	if not input_ctrl.request_recruit_cancel(slot):
		show_notice("现在没有可以取消的招募")


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
## 拒因码是 logic/world.gd 的 can_recruit / can_afford_recruit 产出的：
##   kind / leader / faction / zone / queue_full / cost / population
func recruit_reject_text(reason: String, kind: String) -> String:
	match reason:
		"kind":
			return "这个兵种不在可招募表里"
		"leader":
			return "先选中一个将领，才能把新兵排到它名下"
		"faction":
			return "不能给别的阵营的将领招募"
		"zone":
			return "只能在己方区划内招募（将领现在站的地方不属于你）"
		"queue_full":
			return "招募队列已满（最多 %d 个）" % world.recruit_queue_max()
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
	# ★ 详细信息是**左右两栏**（第三轮改版，见 view/detail_panel.gd 的文件头）：
	#   左栏 = 当前展开的那支部队（上半）+ 选中部队的将领头像网格（下半）
	#   右栏 = 选中单位的头像 / 名称 / buff / 数值
	# 选中对象的三种互斥情况：区划 → 建筑 → 单位（见 refresh 里的分支）
	if input_ctrl.selected_zone != null:
		detail_panel.set_troops(null, [])
		detail_panel.set_unit_avatar_text("区")
		detail_panel.set_unit_name(_zone_title(input_ctrl.selected_zone))
		detail_panel.set_detail(_zone_text(input_ctrl.selected_zone))
		detail_panel.set_queue(null)
		return
	if input_ctrl.selected_building != null:
		var b = input_ctrl.selected_building
		detail_panel.set_troops(null, [])
		detail_panel.set_unit_avatar_text(_building_short(b))
		detail_panel.set_unit_name(b.display_name())
		detail_panel.set_detail(_building_text(b))
		detail_panel.set_queue(null)
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
	detail_panel.set_queue(_queue_leader(troop))


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


## 建筑的数值（生命 / 箭塔伤害 / 位置…）
func _building_text(b) -> String:
	var lines: Array[String] = []
	lines.append("归属：%s" % FactionRes.faction_name(b.owner))
	lines.append("生命 %d / %d" % [int(round(b.hp)), int(round(b.hp_max))])
	if b.type == BuildingRes.TYPE_TOWER:
		lines.append("伤害 %d　射程 %d 格　间隔 %.1fs" % [
			int(b.tower_damage(cfg)), int(b.tower_range(cfg)), b.tower_cooldown(cfg),
		])
		if b.last_target != null and b.last_target.alive:
			lines.append("正在打：%s" % b.last_target.name)
	if b.type == BuildingRes.TYPE_BASE:
		lines.append("开局自带，不可建造、不可拆除")
		lines.append("（本版不会被打掉：血量保底 1）")
	lines.append("位置 (%d, %d)" % [b.tx, b.ty])
	return "\n".join(lines)


## 右栏数值区的正文。
##
## ★ 本轮改版把「队伍人数 / 合计生命 / 指定攻击 / 状态」那些汇总行**删掉了**
##   （手玩要求），改成只报**当前这个单位**的数值；多选时补一行「已选中 N 个单位」，
##   否则玩家在框选之后右栏看起来像只选中了一个。
func _unit_text(shown, troops: Array) -> String:
	if shown == null:
		return "未选中"
	var lines: Array[String] = []
	if troops.size() > 1 or (troops.size() == 1 and (troops[0]["units"] as Array).size() > 1):
		lines.append("已选中 %d 支部队" % troops.size())
	lines.append("血量 %d / %d" % [int(round(shown.hp)), int(round(shown.hp_max))])
	lines.append("攻击力 %d　攻击距离 %d 格　间隔 %.1fs" % [
		int(shown.combat_damage(cfg)), int(shown.combat_range(cfg)), shown.combat_cooldown(cfg),
	])
	lines.append("编制 %d/%d　警戒 %d 格　速度 %.1f 格/秒" % [
		_retinue_size(shown), UiLayoutRes.UNIT_CAP,
		int(shown.aggro_range(cfg)), cfg.unit_speed_of(shown.kind),
	])
	lines.append("所在区块 %s" % _zone_name_at(shown.tx, shown.ty))
	lines.append("buff：%s（占位，暂无效果）" % "、".join(_buff_names()))
	if shown.ordered_target != null and shown.ordered_target.alive:
		lines.append("★ 指定攻击：%s（%d 血）" % [
			shown.ordered_target.name, int(round(shown.ordered_target.hp))])
	elif shown.ordered_building != null and shown.ordered_building.alive:
		lines.append("★ 指定拆除：%s（%d 血）" % [
			shown.ordered_building.display_name(), int(round(shown.ordered_building.hp))])
	elif shown.has_attack_move:
		lines.append("★ 行军攻击中（遇敌即战，打完继续）")
	if shown.target != null and shown.target.alive:
		lines.append("交战中：%s（%d 血）" % [shown.target.name, int(round(shown.target.hp))])
	elif shown.target_building != null and shown.target_building.alive:
		lines.append("正在拆：%s（%d 血）" % [
			shown.target_building.display_name(), int(round(shown.target_building.hp))])
	else:
		lines.append("状态：%s" % ("移动中" if shown.moving else "待命"))
	return "\n".join(lines)


## 一个将领辖下的亲兵数（不是将领自己 → 0）
func _retinue_size(u) -> int:
	if world == null or u == null or not world.is_team_leader(u):
		return 0
	return world.retinue_of(u.id).size()


## buff 占位名（与 view/detail_panel.gd 的 BUFF_PLACEHOLDERS 同一份口径）
func _buff_names() -> Array:
	return DetailPanelRes.BUFF_PLACEHOLDERS.duplicate()


## 区划详情（左键点区划中心时显示）：
## 区划名 / 大小 / 产能 / 人口 —— 用户点名要的四样。
##
## ★ 产能是「每地块每秒」，所以这里同时给出**每地块**与**整个区划**两个数：
##   前者是地图编辑器里填的那个值，后者才是它实际贡献的产出（产能 × 地块数）。
func _zone_text(z: Dictionary) -> String:
	var lines: Array[String] = []
	var owner := String(z["owner"])
	lines.append("区划「%s」" % String(z["name"]))
	lines.append("归属：%s" % (FactionRes.faction_name(owner) if owner != "" else "无主"))
	lines.append("区划大小：%d 个地块" % int(z["tile_count"]))
	var prod: Dictionary = z["production"]
	var n := float(z["tile_count"])
	lines.append("粮食产能：%s／地块／秒（合计 %.1f/秒）"
		% [_fmt_num(float(prod["food"])), float(prod["food"]) * n])
	lines.append("黄金产能：%s／地块／秒（合计 %.1f/秒）"
		% [_fmt_num(float(prod["gold"])), float(prod["gold"]) * n])
	lines.append("人口产能：%s／地块／秒" % _fmt_num(float(prod["population"])))
	# ★ 人口显示**永远是整数**（向下取整，用户需求）—— 权威值是浮点（按秒累积），
	#   直接印出小数点会让玩家看到「1.9999998」这种数。
	# ★ 上限一并显示：不然「人口怎么不涨了」在界面上没有任何解释。
	lines.append("人口：%d（上限 %s）" % [
		world.zones.population_floor(z), _fmt_num(world.zones.population_cap_of(z)),
	])
	return "\n".join(lines)


## 数字显示：整数就不带小数点（与地图编辑器 / 导出的 JSON 同一种写法）
func _fmt_num(v: float) -> String:
	return ("%d" % int(round(v))) if absf(v - round(v)) < 1e-9 else ("%g" % v)


## 某个地块属于哪个区块（单位数值里那一行「所在区块」用）
func _zone_name_at(tx: int, ty: int) -> String:
	var z = world.zones.zone_at(tx, ty)
	if z == null:
		return "无"
	var owner := String(z["owner"])
	if owner == "":
		return "%s（无主）" % String(z["name"])
	return "%s（%s）" % [String(z["name"]), FactionRes.faction_name(owner)]


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

