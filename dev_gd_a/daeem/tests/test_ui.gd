## test_ui.gd —— 新 UI（参考图那套）的接线与几何测试
##
## 为什么值得测：
##   · 参考图给的是**像素稿**（还专门标了「详细信息 1030×240」）。几何一旦被人手改坏，
##     肉眼看「差不多大」是看不出来的 —— 只有断言能发现。
##   · 几条**需求原话**必须钉住：点部队行「只选中、镜头不动」、命令卡「随页签实时切换」、
##     「科技点不动」、「设置点不动」、空槽显示「…」。
##   · 无头也能跑 = 这套 UI 不依赖真实窗口（headless 视口就是工程设置的那一个）。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（见 pitfalls 1.2）。
extends "res://tests/test_case.gd"

const UiLayoutRes = preload("res://view/ui_layout.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")
const CommandRes = preload("res://logic/command_processor.gd")


func _initialize() -> void:
	_case_name = "test_ui"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return

	_test_layout_against_reference()
	_test_hit_test()

	await process_frame
	# ⚠️ headless 的根视口默认是**正方形**（实测 1920×1920），于是「贴下沿」的面板
	#    会被推到 y=1680，几何断言就全假了。这里显式把设计空间钉成参考图的尺寸。
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	await process_frame
	await _test_panels(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 一、几何：逐条对着参考图
# ------------------------------------------------------------------
func _test_layout_against_reference() -> void:
	# 参考图上直接标了「详细信息 1030×240」
	eq(UiLayoutRes.DETAIL_RECT.size.x, 1030.0, "详细信息面板宽 1030（参考图标注）")
	eq(UiLayoutRes.DETAIL_RECT.size.y, 240.0, "详细信息面板高 240（参考图标注）")
	eq(UiLayoutRes.BAR_H, 240.0, "底栏高 240")

	# 左侧部队列表：宽 120，从 y=40 起，10 行 × 60
	eq(UiLayoutRes.SQUAD_RECT.size.x, 120.0, "部队列表宽 120（参考图 x 0..119）")
	eq(UiLayoutRes.SQUAD_RECT.position.y, 40.0, "部队列表从 y=40 开始")
	eq(UiLayoutRes.SQUAD_SLOTS, 10, "★ 10 个槽位（部队1 ~ 部队10）")
	eq(UiLayoutRes.SQUAD_ROW_H, 60.0, "每行 60 高")
	eq(UiLayoutRes.SQUAD_RECT.size.y, 600.0, "10 行合计 600 高")

	# 左下地图占位：400×400，贴屏幕下沿
	eq(UiLayoutRes.MAP_RECT.size.x, 400.0, "地图占位宽 400")
	eq(UiLayoutRes.MAP_RECT.size.y, 400.0, "地图占位高 400")
	eq(UiLayoutRes.MAP_RECT.position.y + UiLayoutRes.MAP_RECT.size.y, UiLayoutRes.DESIGN_H,
		"地图占位贴住屏幕下沿")

	# 命令卡：3×3，每格 80
	eq(UiLayoutRes.CARD_SLOTS, 9, "命令卡 9 格")
	eq(UiLayoutRes.CARD_RECT.size.x, 240.0, "命令卡 3 列 × 80")
	eq(UiLayoutRes.CARD_RECT.size.y, 240.0, "命令卡 3 行 × 80")
	eq(UiLayoutRes.card_cell_local(0), Rect2(0, 0, 80, 80), "Q 格在左上")
	eq(UiLayoutRes.card_cell_local(4), Rect2(80, 80, 80, 80), "S 格在正中（行优先）")
	eq(UiLayoutRes.card_cell_local(8), Rect2(160, 160, 80, 80), "C 格在右下")
	eq(String(UiLayoutRes.CARD_KEYS[0]), "Q", "第一格是 Q")
	eq(String(UiLayoutRes.CARD_KEYS[8]), "C", "第九格是 C")

	# 页签列与设置
	eq(UiLayoutRes.TABS_RECT.size.x, 100.0, "页签列宽 100")
	eq(UiLayoutRes.tab_button_local(2).position.y, 160.0, "第三颗按钮从 160 开始（3×80）")
	eq(UiLayoutRes.SETTINGS_RECT, Rect2(1840, 0, 80, 160), "设置按钮 80×160 在右上角（参考图）")

	# ★ 底栏四块必须严丝合缝：参考图是靠 1px 分隔线排的，留缝或多一块都不对
	eq(UiLayoutRes.DETAIL_RECT.position.x + UiLayoutRes.DETAIL_RECT.size.x,
		UiLayoutRes.FACTION_RECT.position.x, "详细信息右边缘接上阵营面板")
	eq(UiLayoutRes.FACTION_RECT.position.x + UiLayoutRes.FACTION_RECT.size.x,
		UiLayoutRes.CARD_RECT.position.x, "阵营面板右边缘接上命令卡")
	eq(UiLayoutRes.CARD_RECT.position.x + UiLayoutRes.CARD_RECT.size.x,
		UiLayoutRes.TABS_RECT.position.x, "命令卡右边缘接上页签列")
	eq(UiLayoutRes.TABS_RECT.position.x + UiLayoutRes.TABS_RECT.size.x, UiLayoutRes.DESIGN_W,
		"页签列贴住屏幕右边缘")
	eq(UiLayoutRes.DETAIL_RECT.position.x, UiLayoutRes.MAP_RECT.size.x,
		"详细信息从地图占位的右边缘开始（x=400）")
	for r in [UiLayoutRes.DETAIL_RECT, UiLayoutRes.FACTION_RECT, UiLayoutRes.CARD_RECT, UiLayoutRes.TABS_RECT]:
		eq(r.position.y, UiLayoutRes.BAR_TOP, "底栏各块顶边都在 y=840")
		eq(r.position.y + r.size.y, UiLayoutRes.DESIGN_H, "底栏各块都贴住屏幕下沿")


# ------------------------------------------------------------------
# 二、鼠标：只有「能点的控件」才拦边缘滚屏
# ------------------------------------------------------------------
func _test_hit_test() -> void:
	var vp := Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H)
	var map_middle := Vector2(960.0, 400.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), map_middle),
		"地图空白处不拦鼠标（点击要能落到地图上）")

	# ★ 这一条是重点：详细信息面板只有文字，**不能**拦边缘滚屏 ——
	#   否则底栏盖住屏幕下沿，鼠标永远滚不到地图下方（实测撞出来的）。
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.DETAIL_RECT.get_center()),
		"★ 详细信息面板不拦边缘滚屏（否则底边永远滚不动）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.FACTION_RECT.get_center()),
		"阵营占位面板同样不拦")

	# 能点的：部队行 / 命令卡 / 页签 / 设置
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.squad_slot_rect(2).get_center()), "部队第 3 行拦边缘滚屏（它是可点的）")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.card_cell_rect(0).get_center()), "命令卡 Q 格拦边缘滚屏")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.tab_button_rect(1).get_center()), "页签按钮拦边缘滚屏")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.SETTINGS_RECT.get_center()), "设置按钮拦边缘滚屏")

	# 窗口比例变化（canvas_items + expand）时，贴右下的东西要跟着右下角走
	var wide := Vector2(2560.0, 1080.0)
	var shifted := UiLayoutRes.card_cell_rect(0)
	shifted.position.x += 2560.0 - UiLayoutRes.DESIGN_W
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide), shifted.get_center()),
		"窗口变宽时命令卡跟着贴右边缘（不然点不到）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide),
		UiLayoutRes.card_cell_rect(0).get_center()),
		"窗口变宽后原位置不再算作命令卡")


# ------------------------------------------------------------------
# 三、面板与交互
# ------------------------------------------------------------------
func _test_panels(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame

	ok(main.hud != null, "HUD 还在")
	if main.hud == null:
		return

	# ---- 节点树 ----
	for path in ["HudRoot/SquadPanel", "HudRoot/MapPlaceholder", "HudRoot/DetailPanel",
			"HudRoot/FactionPlaceholder", "HudRoot/CommandCard", "HudRoot/PageTabs",
			"HudRoot/SettingsButton"]:
		ok(main.hud.get_node_or_null(path) != null, "节点树里有 %s" % path)

	# ---- 几何真的落到控件上了（设计空间已在 _run 里钉成 1920×1080）----
	var vp: Vector2 = main.hud.view_size()
	eq(vp, Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H), "设计空间 = 1920×1080")
	v2_near(main.hud.detail_panel.position, UiLayoutRes.DETAIL_RECT.position, 1.0,
		"详细信息面板落在 (400, 840)")
	v2_near(main.hud.detail_panel.size, UiLayoutRes.DETAIL_RECT.size, 1.0,
		"★ 详细信息面板实际尺寸 = 1030×240（参考图标注）")
	v2_near(main.hud.map_placeholder.position, UiLayoutRes.MAP_RECT.position, 1.0,
		"地图占位落在 (0, 680)")
	v2_near(main.hud.map_placeholder.size, UiLayoutRes.MAP_RECT.size, 1.0,
		"地图占位实际尺寸 = 400×400")
	v2_near(main.hud.faction_placeholder.position, UiLayoutRes.FACTION_RECT.position, 1.0,
		"阵营占位落在 (1430, 840)")
	v2_near(main.hud.command_card.position, UiLayoutRes.CARD_RECT.position, 1.0,
		"命令卡落在 (1580, 840)")
	v2_near(main.hud.page_tabs.position, UiLayoutRes.TABS_RECT.position, 1.0,
		"页签列落在 (1820, 840)")
	v2_near(main.hud.settings_button.position, UiLayoutRes.SETTINGS_RECT.position, 1.0,
		"设置按钮落在 (1840, 0)")
	v2_near(main.hud.settings_button.size, UiLayoutRes.SETTINGS_RECT.size, 1.0,
		"设置按钮实际尺寸 = 80×160")
	v2_near(main.hud.squad_panel.position, UiLayoutRes.SQUAD_RECT.position, 1.0,
		"部队列表落在 (0, 40)")
	v2_near(main.hud.squad_panel.size, UiLayoutRes.SQUAD_RECT.size, 1.0,
		"部队列表实际尺寸 = 120×600")

	_test_squad_rows(main)
	_test_page_tabs_and_card(main, cfg)
	_test_card_keys(main)
	_test_recruit_via_card(main)
	_test_right_click_orders(main)
	_test_settings_inert(main)
	await _test_command_events_reach_consumer(main)

	# ---- 详细信息面板的内容（右栏只剩阵营 + 资源；日志整块删掉）----
	var status: String = main.hud.detail_panel.status_text()
	ok(status.contains("粮食"), "右栏资源行里有粮食")
	ok(status.contains("黄金"), "右栏资源行里有黄金")
	ok(not status.contains("地块"), "★ 右栏不再显示己方地块")
	ok(not status.contains("区块"), "★ 右栏不再显示区块")
	ok(not status.contains("建造"), "★ 右栏不再显示建造模式")
	ok(not status.contains("暂停"), "★ 右栏不再显示暂停状态")
	ok(not main.hud.detail_panel.has_log(), "★ 事件日志整块删掉了（detail_panel 里没有日志栏）")
	ok(main.hud.detail_panel.detail_text().contains("将领"), "左栏显示选中单位的信息")

	# 左栏也不再挂操作提示：没选中时只有「未选中」四个字
	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(main.hud.detail_panel.detail_text(), "未选中", "★ 左栏没选中时只显示「未选中」（不再有操作提示）")
	main.input_ctrl.select_units([main.world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not main.hud.detail_panel.detail_text().contains("Shift"),
		"★ 左栏不再显示快捷键提示")

	# ---- 边缘滚屏：HUD 上的判定（真实实例，不只看常量）----
	var card0 := UiLayoutRes.card_cell_rect(0)
	card0.position.x += maxf(0.0, vp.x - UiLayoutRes.DESIGN_W)
	card0.position.y += maxf(0.0, vp.y - UiLayoutRes.DESIGN_H)
	ok(main.hud.blocks_edge_scroll(card0.get_center()), "鼠标在命令卡上 → 不滚屏")
	ok(not main.hud.blocks_edge_scroll(UiLayoutRes.DETAIL_RECT.get_center()),
		"鼠标在详细信息面板上 → 照样滚屏（不然底边滚不动）")
	ok(not main.hud.blocks_edge_scroll(Vector2(vp.x * 0.5, vp.y * 0.5)), "鼠标在地图中间 → 滚屏")

	# ---- 选中单位不再画攻击 / 警戒范围圈 ----
	ok(not main.overlay.has_method("_draw_selected_units"),
		"★ overlay 里已经没有「选中范围圈」那段代码（画范围圈的函数被删掉了）")
	ok(main.cfg.get_path_value("colors.range") == null
		and main.cfg.get_path_value("colors.range_edge") == null,
		"★ config 里的 range / range_edge 配色也一起删了（不留死数据）")

	await _test_anchors(main)

	main.queue_free()
	await process_frame


# ---- 贴边：窗口比例变了以后，底栏与右侧那一列必须还贴着右下角 ----
func _test_anchors(main) -> void:
	root.size = Vector2i(2560, 1080)                      # 超宽：多出来的 640px 留在中间
	await process_frame
	await process_frame
	v2_near(main.hud.command_card.position, Vector2(1580.0 + 640.0, 840.0), 1.0,
		"★ 超宽窗口：命令卡仍贴右下角")
	v2_near(main.hud.page_tabs.position, Vector2(1820.0 + 640.0, 840.0), 1.0,
		"超宽窗口：页签列仍贴右下角")
	v2_near(main.hud.detail_panel.position, UiLayoutRes.DETAIL_RECT.position, 1.0,
		"超宽窗口：详细信息仍贴左边（x = 400）")
	v2_near(main.hud.squad_panel.position, UiLayoutRes.SQUAD_RECT.position, 1.0,
		"超宽窗口：部队列表仍在左上")
	v2_near(main.hud.settings_button.position, Vector2(1840.0 + 640.0, 0.0), 1.0,
		"超宽窗口：设置仍贴右上角")
	ok(main.hud.blocks_edge_scroll(Vector2(1580.0 + 640.0 + 40.0, 880.0)),
		"超宽窗口：命令卡的新位置仍然拦边缘滚屏（判定跟着贴边走）")

	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	await process_frame


# ---- 部队列表：10 槽 / 动态生成 / 空槽「…」/ 点击只选中 ----
func _test_squad_rows(main) -> void:
	var panel = main.hud.squad_panel
	var world = main.world

	eq(panel.slot_count(), UiLayoutRes.SQUAD_SLOTS, "部队列表有 10 个槽")
	# 现在世界上有 3 支队伍（3 个将领各带亲兵）
	var teams := 0
	for u in world.units:
		if u.alive and world.is_team_leader(u) and FactionRes.same_side(u.faction, world.my_faction):
			teams += 1
	eq(teams, 3, "己方有 3 支队伍")
	ok(panel.slot_text(0).begins_with("部队1"), "第 1 槽写着「部队1」（实际：%s）" % panel.slot_text(0))
	ok(panel.slot_text(0).contains("将领 1"), "第 1 槽带队伍名")
	ok(panel.slot_text(0).contains("人"), "第 1 槽带人数")
	ok(panel.slot_filled(2), "第 3 槽有队伍")
	ok(not panel.slot_filled(3), "第 4 槽是空的")
	for i in range(3, UiLayoutRes.SQUAD_SLOTS):
		eq(panel.slot_text(i), "…", "空槽第 %d 行显示「…」" % (i + 1))

	# 点第 3 槽 = 选中将领 3 的整队；★ 镜头不动
	var g3 = world.unit_by_id("general-3")
	ok(g3 != null, "有 general-3")
	var cam_before: Vector2 = main.cam.position
	panel.slot_button(2).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), world.group_of(g3).size(),
		"点部队行 = 选中整队（%d 个）" % world.group_of(g3).size())
	eq(main.input_ctrl.selected_units[0].id, g3.id, "整队的队长排在第一个")
	eq(main.cam.position, cam_before, "★ 点部队行只选中，镜头不动（需求原话）")
	ok(panel.slot_active(2), "当前选中的队伍在列表里高亮")

	# 空槽点了什么也不做
	var sel_before: int = main.input_ctrl.selected_units.size()
	panel.slot_button(7).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), sel_before, "★ 空槽点了没有反应")

	# 回到将领 1（后面的用例要靠它）
	main.input_ctrl.select_units([world.unit_by_id("general-1")])


# ---- 页签切页 + 命令卡内容 ----
func _test_page_tabs_and_card(main, cfg) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	eq(tabs.button_count(), 3, "页签有 3 颗按钮（单位 / 建筑 / 科技）")

	# 默认停在「单位」页：此时命令卡只有一项（占位单位）
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "默认页是「单位」")
	eq(card.entries().size(), 1, "★ 单位页只有 1 项（需求：目前只有一个单位）")
	eq(String(card.entry_at(0).get("type", "")), "recruit", "单位页那一项是「招募」")
	eq(card.cell_label(0), "占位单位", "单位页的 Q 格写着占位单位")
	eq(card.cell_label(1), "", "单位页第 2 格是空的")

	# 切到「建筑」页：城墙 / 箭塔各占一格
	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_BUILD, "点「建筑」切到建筑页")
	eq(card.entries().size(), 2, "★ 建筑页有 2 项（需求原话：只有两个建筑）")
	eq(String(card.entry_at(0).get("build_type", "")), "wall", "建筑页第 1 项是城墙")
	eq(String(card.entry_at(1).get("build_type", "")), "tower", "建筑页第 2 项是箭塔")
	eq(card.cell_label(0), "城墙", "城墙在 Q 格（需求原话）")
	eq(card.cell_label(1), "箭塔", "箭塔在 W 格（需求原话）")
	ok(tabs.is_active(1), "当前页在页签上高亮")

	# ★ 科技点不动：点它既不改页，也不改命令卡
	var page_before := String(tabs.page())
	var entries_before: int = card.entries().size()
	tabs.button_at(2).emit_signal("pressed")
	eq(tabs.page(), page_before, "★「科技」点不动（点了不改页）")
	eq(card.entries().size(), entries_before, "★「科技」点不动（命令卡也不变）")

	# 切回单位页
	tabs.button_at(0).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "点「单位」切回单位页")
	eq(card.entries().size(), 1, "切回去之后命令卡跟着换回来了")


# ---- 命令卡的九个字母键 ----
func _test_card_keys(main) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card

	# 空格子的字母不该被命令卡吃掉（要交回原来那套快捷键 / 什么都不做）
	var a_ev := _key(KEY_A)
	ok(not card.handle_key(a_ev), "空格子（A）不消费按键")

	# 建筑页：Q = 城墙，W = 箭塔（需求原话）
	tabs.select_page(PageTabsRes.PAGE_BUILD)
	ok(card.handle_key(_key(KEY_Q)), "建筑页的 Q 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "wall", "★ 建筑页按 Q = 城墙")
	ok(card.handle_key(_key(KEY_W)), "建筑页的 W 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "tower", "★ 建筑页按 W = 箭塔（W 已不再平移镜头）")
	# 再按一次同一格 = 退出建造模式（与 B / T 的行为一致）
	ok(card.handle_key(_key(KEY_W)), "再按一次 W")
	eq(main.input_ctrl.build_type, "", "再按一次同一格 = 退出建造模式")

	# 鼠标点格子走同一条路
	card.cell_at(0).emit_signal("pressed")
	eq(main.input_ctrl.build_type, "wall", "点 Q 格 = 进城墙建造模式")
	main.input_ctrl.set_build_type("")
	tabs.select_page(PageTabsRes.PAGE_UNIT)


# ---- 招募：走「命令」这条路 ----
func _test_recruit_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	var per: int = int(main.cfg.num("unit.subordinate.count", 0.0))
	var before: int = world.retinue_of(g1.id).size()

	# 没有选中将领时不发命令，只提示
	main.input_ctrl.select_units([])
	ok(not main.input_ctrl.request_recruit(UnitRes.KIND_SUBORDINATE),
		"★ 没选中将领时招募命令**不发出去**（只给提示）")
	eq(world.retinue_of(g1.id).size(), before, "没选中将领时没有凭空多出单位")

	# 选中将领 1 再点单位页的 Q 格
	main.input_ctrl.select_units([g1])
	card.activate_index(0)
	eq(world.retinue_of(g1.id).size(), before + 1, "★ 选中将领后招募 → 将领 1 名下多了一个兵")
	var fresh = world.retinue_of(g1.id)[before]
	eq(fresh.leader_id, g1.id, "新兵挂在被选中的将领名下")
	ok(world.unit_by_id(fresh.id) == fresh, "新兵真的进了 world.units")

	# 键盘 Q 也走同一条路
	ok(card.handle_key(_key(KEY_Q)), "单位页的 Q 被命令卡吃掉")
	eq(world.retinue_of(g1.id).size(), before + 2, "键盘 Q 同样能招募")

	# 命令卡切页之后，招募不会串到建筑页上
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	eq(world.retinue_of(g1.id).size(), before + 2, "切到建筑页不会再多出单位")
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)

	# 列表要跟着动（人数 + 人数文案）
	main.hud.squad_panel.refresh()
	ok(main.hud.squad_panel.slot_text(0).contains("%d 人" % (before + 3)),
		"部队列表的人数跟着招募走（实际：%s）" % main.hud.squad_panel.slot_text(0))


# ---- 右键：点敌人 = 攻击、双击 = 行军攻击、点空地 = 移动 ----
#
# 需求原话：「右键单击敌人/建筑 → 优先攻击该敌人/建筑，右键双击 → 行军攻击至该地点」。
# 这里验的是**输入层翻译**（哪个手势发出哪条命令），命令本身的效果在 test_attack_orders.gd。
func _test_right_click_orders(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])

	# 旁边放一个敌人当靶子（也顺便验证「拾取敌方单位」与「拾取自己单位」是两套判据）
	var foe = world.spawn_enemy(g1.tx + 2, g1.ty)
	ok(foe != null, "刷出一个敌人当靶子")
	if foe == null:
		return
	var got: Array = []
	var sink = func(cmd): got.append(cmd)
	main.input_ctrl.command_issued.connect(sink)

	# 1) 单击敌人 → attack
	main.input_ctrl.hover_tile = Vector2i(foe.tx, foe.ty)
	main.input_ctrl.mouse_world = foe.pos
	main.input_ctrl._on_right_click(false)
	eq(got.size(), 1, "单击敌人发出了一条命令")
	eq(String(got[0].get("kind", "")), "attack", "★ 右键单击敌人 = 攻击命令")
	eq(String(got[0].get("target_id", "")), foe.id, "命令里带的是那个敌人的 id")
	ok(main.input_ctrl._pick_foe_unit_at(foe.pos) == foe, "鼠标底下是敌人时，敌对拾取拿得到它")
	ok(main.input_ctrl._pick_unit_at(foe.pos) == null, "自己人的拾取函数不会选中敌人")
	# 左栏要能看见这条命令（不然玩家不知道单位在打谁）——趁命令还在，先验这一条
	main.hud.refresh()
	ok(main.hud.detail_panel.detail_text().contains("指定攻击"),
		"★ 左栏显示「指定攻击：…」（命令可见）")

	# 2) 单击空地 → move
	got.clear()
	var empty := Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			if world.can_build_at(tx, ty) and absi(tx - g1.tx) + absi(ty - g1.ty) > 3:
				empty = Vector2i(tx, ty)
				break
		if empty.x >= 0:
			break
	ok(empty.x >= 0, "找得到一格用来点右键的空地")
	main.input_ctrl.hover_tile = empty
	main.input_ctrl.mouse_world = Vector2(empty.x + 0.5, empty.y + 0.5)
	main.input_ctrl._on_right_click(false)
	eq(String(got[0].get("kind", "")), "move", "右键单击空地 = 普通移动")
	ok(main.input_ctrl.move_marks.size() == 1, "移动标记画出来了（绿）")

	# 3) 双击空地 → attack_move
	got.clear()
	main.input_ctrl._on_right_click(true)
	eq(String(got[0].get("kind", "")), "attack_move", "★ 右键双击 = 行军攻击命令")
	ok(main.input_ctrl.attack_marks.size() == 1, "行军攻击标记画出来了（红）")
	ok(main.input_ctrl.move_marks.is_empty(), "两种标记只留最新的那个")

	# 4) 走**真实事件路径**：双击必须是 Godot 事件里带的 double_click 标志
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.double_click = true
	ev.position = Vector2(20.0, 20.0)
	got.clear()
	ok(main.input_ctrl.handle_mouse_button(ev), "右键双击事件被处理")
	eq(String(got[0].get("kind", "")), "attack_move",
		"★ 走真实事件路径时，双击也翻译成行军攻击（不是靠手写计时器）")

	main.input_ctrl.command_issued.disconnect(sink)


# ---- 设置点不动 ----
func _test_settings_inert(main) -> void:
	var page_before := String(main.hud.page_tabs.page())
	eq(main.hud.settings_button.pressed.get_connections().size(), 0,
		"★ 设置按钮没接任何处理函数（点不动，需求原话）")
	main.hud.settings_button.emit_signal("pressed")
	eq(main.hud.page_tabs.page(), page_before, "点设置不会顺手切页")
	ok(main.hud.settings_button.text == "设置", "设置按钮上写着「设置」")


# ---- 命令产生的事件必须能被下一次 tick 取到（回归：tick 曾经在开头清空 _events）----
#
# 症状有多难查：逻辑全对、画面也全对，只是「建好了却没有事件」。
# 原因：命令是输入事件触发的，跑在两次 tick 之间；tick 一开头 `_events = []`
# 就把它们丢了。现在改成**末尾收口**，这里直接对着 world 的事件流钉住
# —— UI 上的日志虽然按需求删掉了，但这条边界（也喂给将来的日志 / 联机）不能坏。
func _test_command_events_reach_consumer(main) -> void:
	var free := Vector2i(-1, -1)
	for ty in main.world.map.rows:
		for tx in main.world.map.cols:
			if main.world.can_build_at(tx, ty):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格可建造的空地")
	if free.x < 0:
		return

	# 先跑一帧把上一帧的残留事件清干净，再看这一次命令产生的事件
	main.world.tick(1.0 / 60.0)
	ok(CommandRes.apply(main.world, main.cfg, {
		"kind": "build", "build_type": "wall", "tx": free.x, "ty": free.y, "faction": "p1"}),
		"建造命令被接受")
	var events: Array = main.world.tick(1.0 / 60.0)
	var built := 0
	for evt in events:
		if String(evt.get("type", "")) == "building_built":
			built += 1
	eq(built, 1, "★ 建造事件被下一次 tick 交了出来（命令事件不能在 tick 开头被丢掉）")

	# 招募同样要有事件（走的是同一条路）
	var g1 = main.world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	main.input_ctrl.request_recruit(UnitRes.KIND_SUBORDINATE)
	var events2: Array = main.world.tick(1.0 / 60.0)
	var recruited := 0
	for evt in events2:
		if String(evt.get("type", "")) == "unit_recruited":
			recruited += 1
	eq(recruited, 1, "★ 招募事件也被下一次 tick 交了出来")


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev
