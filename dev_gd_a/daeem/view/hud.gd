## hud.gd —— 新 UI（UI 改版：**废弃**原来的「顶栏 + 右侧选中面板 + 底部日志」）
##
## 布局逐像素照参考图（1920×1080），几何全部写在 view/ui_layout.gd 里：
##
##   右上 设置（80×160，点不动）
##   左侧 部队 1~10（10 槽 × 60 高，内容动态生成）
##   左下 地图占位（400×400，本轮只画个灰块 —— 真小地图以后单独做）
##   底栏 y 840..1080：
##     详细信息 1030×240（左 = 选中对象的信息，右 = 阵营 + 资源）
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
const CommandCardRes = preload("res://view/command_card.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")

var cfg: ConfigRes = null
var world = null
var input_ctrl = null

var squad_panel: Control = null
var detail_panel: PanelContainer = null
var command_card: Control = null
var page_tabs: Control = null
var settings_button: Button = null
var map_placeholder: PanelContainer = null
var faction_placeholder: PanelContainer = null

var _root: Control = null


func setup(p_cfg: ConfigRes, p_world, p_input, theme: Theme) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input

	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE     # 空白处的鼠标事件一律穿透给地图
	if theme != null:
		_root.theme = theme
	add_child(_root)

	_build_map_placeholder()
	_build_faction_placeholder()
	_build_detail_panel()
	_build_command_card()
	_build_page_tabs()
	_build_settings_button()
	_build_squad_panel()

	_rebuild_card()
	refresh()


func _process(_dt: float) -> void:
	refresh()


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 左下 400×400 的「地图」：本轮**只占位**（真小地图要画地形/建筑/单位 + 视野框 + 点击跳转）
func _build_map_placeholder() -> void:
	map_placeholder = PanelContainer.new()
	map_placeholder.name = "MapPlaceholder"
	map_placeholder.mouse_filter = Control.MOUSE_FILTER_STOP
	map_placeholder.add_theme_stylebox_override("panel", UiStyleRes.panel_style(UiStyleRes.BG_SOFT))
	UiLayoutRes.apply_rect(map_placeholder, UiLayoutRes.MAP_RECT, false, true)
	_root.add_child(map_placeholder)

	var label := Label.new()
	label.text = "地图"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", UiStyleRes.FS_BIG)
	label.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
	map_placeholder.add_child(label)


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
	detail_panel.setup()


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
			input_ctrl.request_recruit(String(entry.get("unit_kind", "")))


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
## ★ 边缘滚屏必须给这些地方让路，否则鼠标一移到底栏上镜头就自己跑。
##   但**只有能点的控件**才让路：详细信息面板全是文字，让它也让路的话，
##   底栏盖住屏幕下沿 → 鼠标永远滚不到地图下方（这条是实测撞出来的）。
func blocks_edge_scroll(global_pos: Vector2) -> bool:
	return UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(view_size()), global_pos)


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
	detail_panel.set_detail(_selection_text())
	detail_panel.set_status(_status_text())


## 右栏资源行：**只留阵营 + 粮食 + 黄金**（产出速率是本地算出来的展示值）。
## 己方地块 / 区块 / 建造模式 / 暂停都不再显示（按需求砍掉）。
func _status_text() -> String:
	var me := FactionRes.faction_name(world.my_faction)
	return "%s\n粮食 %.1f（+%.1f/秒）　黄金 %.1f（+%.1f/秒）" % [
		me, float(world.resources["food"]), world.production_food,
		float(world.resources["gold"]), world.production_gold,
	]


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
	lines.append("人口：%.1f（每个区划各算各的，只涨不减）" % float(z.get("population", 0.0)))
	return "\n".join(lines)


## 数字显示：整数就不带小数点（与地图编辑器 / 导出的 JSON 同一种写法）
func _fmt_num(v: float) -> String:
	return ("%d" % int(round(v))) if absf(v - round(v)) < 1e-9 else ("%g" % v)


## 左栏：**只显示选中对象本身的信息**（区划 / 建筑 / 部队），不再挂操作提示。
func _selection_text() -> String:
	# ★ 区划（左键点它的中心建筑）：显示区划名 / 大小 / 产能 / 人口
	var z = input_ctrl.selected_zone
	if z != null:
		return _zone_text(z)

	var b = input_ctrl.selected_building
	if b != null:
		var lines: Array[String] = []
		lines.append("%s（%s）" % [b.display_name(), FactionRes.faction_name(b.owner)])
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

	var units: Array = input_ctrl.selected_units
	if units.is_empty():
		return "未选中"

	var lines2: Array[String] = []

	# ★ 队伍：选中队长时会把亲兵一起选中，所以这里要「按队伍汇总」显示，
	#   否则左栏会变成一长串单位名，玩家看不出这是一支队。
	if units.size() == 1:
		var u = units[0]
		lines2.append("%s（%s）" % [u.name, FactionRes.faction_name(u.faction)])
		lines2.append("生命 %d / %d" % [int(round(u.hp)), int(round(u.hp_max))])
		lines2.append("伤害 %d　攻击距离 %d 格　间隔 %.1fs" % [
			int(u.combat_damage(cfg)), int(u.combat_range(cfg)), u.combat_cooldown(cfg),
		])
		lines2.append("警戒半径 %d 格　速度 %.1f 格/秒" % [int(u.aggro_range(cfg)), cfg.unit_speed_of(u.kind)])
		lines2.append("所在区块 %s" % _zone_name_at(u.tx, u.ty))
		# ★ 玩家下达的攻击命令要能看见（右键点敌人 / 点建筑 / 双击行军攻击）
		if u.ordered_target != null and u.ordered_target.alive:
			lines2.append("★ 指定攻击：%s（%d 血）" % [u.ordered_target.name, int(round(u.ordered_target.hp))])
		elif u.ordered_building != null and u.ordered_building.alive:
			lines2.append("★ 指定拆除：%s（%d 血）" % [
				u.ordered_building.display_name(), int(round(u.ordered_building.hp)),
			])
		elif u.has_attack_move:
			lines2.append("★ 行军攻击中（遇敌即战，打完继续）")
		if u.target != null and u.target.alive:
			lines2.append("交战中：%s（%d 血）" % [u.target.name, int(round(u.target.hp))])
		elif u.target_building != null and u.target_building.alive:
			lines2.append("正在拆：%s（%d 血）" % [u.target_building.display_name(), int(round(u.target_building.hp))])
		else:
			lines2.append("状态：%s" % ("移动中" if u.moving else "待命"))
	else:
		# 找出这一坨里有没有队长 / 是不是同一支队
		var leader = null
		var retinue := 0
		for u2 in units:
			if world.is_team_leader(u2):
				leader = u2
			elif u2.leader_id != "":
				retinue += 1
		if leader != null:
			lines2.append("队伍：%s + %d 名亲兵" % [leader.name, retinue])
			lines2.append("合计生命 %d　（队长 %d / %d）" % [
				_total_hp(units), int(round(leader.hp)), int(round(leader.hp_max)),
			])
		else:
			lines2.append("已选中 %d 个单位" % units.size())
			lines2.append("合计生命 %d" % _total_hp(units))
		var moving_count := 0
		for u3 in units:
			if u3.moving:
				moving_count += 1
		lines2.append("移动中 %d / %d" % [moving_count, units.size()])
		# ★ 玩家下达的攻击命令也要能看见。
		#   注意：**整队选中**（选中将领时会带上亲兵）走的就是这一支，
		#   所以这一段不是可选的美化 —— 少了它，右键点敌人之后左栏什么都不显示。
		var shown := false
		for u4 in units:
			if u4.ordered_target != null and u4.ordered_target.alive:
				lines2.append("★ 指定攻击：%s（%d 血）" % [
					u4.ordered_target.name, int(round(u4.ordered_target.hp)),
				])
				shown = true
				break
			if u4.ordered_building != null and u4.ordered_building.alive:
				lines2.append("★ 指定拆除：%s（%d 血）" % [
					u4.ordered_building.display_name(), int(round(u4.ordered_building.hp)),
				])
				shown = true
				break
		if not shown:
			for u5 in units:
				if u5.has_attack_move:
					lines2.append("★ 行军攻击中（遇敌即战，打完继续）")
					break
	return "\n".join(lines2)


## 选中单位的生命合计（队伍汇总用）
func _total_hp(units: Array) -> int:
	var total := 0.0
	for u in units:
		total += u.hp
	return int(round(total))


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

