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
const RecruitQueueRes = preload("res://view/recruit_queue.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const GridRes = preload("res://logic/grid.gd")
const WorldRes = preload("res://logic/world.gd")


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

	# ★ 招募队列：五个格子 = 1 个大格（正在读条）+ 4 个小格（排队）
	eq(UiLayoutRes.QUEUE_SLOTS, 5, "★ 招募队列 5 个格子（1 大 + 4 小，需求原话）")
	eq(UiLayoutRes.queue_cell_rect(0), Rect2(0, 0, 64, 64), "大格子在左上（64×64）")
	eq(UiLayoutRes.queue_cell_rect(1), Rect2(68, 0, 30, 30), "第 1 个小格排在大格右边")
	eq(UiLayoutRes.queue_cell_rect(2), Rect2(102, 0, 30, 30), "第 2 个小格在它右边")
	eq(UiLayoutRes.queue_cell_rect(3), Rect2(68, 34, 30, 30), "第 3 个小格换行")
	eq(UiLayoutRes.queue_cell_rect(4), Rect2(102, 34, 30, 30), "第 4 个小格在右下角")
	var small_last := UiLayoutRes.queue_cell_rect(4)
	ok(small_last.position.x + small_last.size.x <= UiLayoutRes.QUEUE_W + 1e-6
		and small_last.position.y + small_last.size.y <= UiLayoutRes.QUEUE_H + 1e-6,
		"★ 四个小格都落在队列控件的矩形里（否则会被裁掉）")

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

	# ★ 屏幕最外圈永远让路给边缘滚屏（手玩报的 bug：
	#   「鼠标移到将领按钮那边的屏幕边缘，屏幕不会滚动」——
	#   部队列表 x 0..119 整条压着左边缘，于是左边缘那一段永远滚不动）
	var m: float = 44.0
	ok(UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), m),
		"★ 左边缘最外圈算「边缘带」（将领按钮那一列就压在这里）")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 1070.0), m), "下边缘也算边缘带")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 8.0), m), "上边缘也算")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(1914.0, 500.0), m), "右边缘也算")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(960.0, 500.0), m), "屏幕中间不是边缘带")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), 0.0),
		"margin = 0 时整条规则关掉（可配置）")


# ------------------------------------------------------------------
# 三、面板与交互
# ------------------------------------------------------------------
## ★★ 必须走「按下 test 进游戏」这条**真实入口**，然后在 **GameScene** 上断言。
##
## main.tscn 的根挂的是 `main.gd`（只有 `cfg` / `start_screen` / `game` 三个字段），
## 在它上面访问 `hud` / `world` / `cam` 会**报错并直接中止整个函数** ——
## 结果是「面板与交互」这一整节 40 多条断言从来没有真的执行过，而测试照样全绿。
## ⚠️ 这个坑 test_view.gd 早就踩过并写了注释（那里 44 条断言只跑了 19 条），
##    本文件当时没跟着改 —— 同一个坑踩第二次，见 pitfalls 5.35。
func _test_panels(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var root_node = (packed as PackedScene).instantiate()
	root.add_child(root_node)
	await process_frame
	root_node._on_test_pressed()          # 与玩家点一下 test 按钮完全同一条路
	await process_frame
	await process_frame

	var main = root_node.game
	ok(main != null, "★ 按下 test 之后建出了游戏内场景（HUD / world / 相机都在它身上）")
	if main == null:
		root_node.queue_free()
		return

	ok(main.hud != null, "HUD 还在")
	if main.hud == null:
		root_node.queue_free()
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

	# ★ 招募队列控件（五个格子）必须整个装在详细信息面板里 —— 否则会被面板裁掉 / 压到右栏
	var qc = main.hud.detail_panel.queue_control()
	ok(qc != null, "详细信息左栏里有招募队列控件")
	if qc != null:
		v2_near(qc.size, Vector2(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_H), 1.0,
			"队列控件尺寸 = QUEUE_W×QUEUE_H（五个格子刚好装得下）")
		var qc_rect := Rect2(qc.global_position, qc.size)
		ok(UiLayoutRes.DETAIL_RECT.grow(-1.0).encloses(qc_rect),
			"★ 队列控件整个落在详细信息面板里（实际 %s）" % str(qc_rect))
		ok(qc.size_flags_horizontal != Control.SIZE_EXPAND_FILL,
			"队列控件不抢横向空间（正文才该被拉伸）")
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
	_test_queue_control(cfg)
	_test_queue_cancel_via_click(main)
	_test_auto_select_on_recruit(main)
	_test_order_locked_notice(main)
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

	# ★ 手玩报的 bug：左侧「部队 1~10」（将领按钮那一列）压着屏幕左边缘，
	#   于是鼠标推到左边缘那一段**永远滚不动**。现在最外圈一律让路。
	var row_center := UiLayoutRes.squad_slot_rect(2).get_center()
	ok(not main.hud.blocks_edge_scroll(Vector2(6.0, row_center.y)),
		"★ 鼠标在左边缘最外圈（将领按钮那一列）→ 仍然滚屏")
	ok(main.hud.blocks_edge_scroll(row_center),
		"部队行**靠里**的部分照旧拦住边缘滚屏（原来那条行为不变）")

	# ---- 选中单位不再画攻击 / 警戒范围圈 ----
	ok(not main.overlay.has_method("_draw_selected_units"),
		"★ overlay 里已经没有「选中范围圈」那段代码（画范围圈的函数被删掉了）")
	ok(main.cfg.get_path_value("colors.range") == null
		and main.cfg.get_path_value("colors.range_edge") == null,
		"★ config 里的 range / range_edge 配色也一起删了（不留死数据）")

	await _test_anchors(main)

	root_node.queue_free()
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


# ---- 招募：走「命令」这条路（入队即扣费、读条 10 秒）+ 信息栏里的五个格子 ----
#
# ★ 招募的**规则**（消耗 / 人口 / 队列上限 / 10 秒 / 格心生成 / 区划限制 / 阵亡退款）
#   在 tests/test_recruit_queue.gd；这里只验「UI → 命令 → 队列显示」这条接线。
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

	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	var queue = main.hud.detail_panel.queue_control()
	ok(queue != null, "详细信息左栏里有招募队列控件")
	ok(not queue.showing(), "★ 没在招募时五个格子收起来（需求：将领开始招募时才出现）")

	# ---- 资源不足：命令被拒 + 左栏出现红字原因 ----
	world.resources["food"] = 10.0
	world.resources["gold"] = 10.0
	card.activate_index(0)
	var evts: Array = world.tick(1.0 / 60.0)
	main._consume_events(evts)                 # 走真实那条「事件 → 文案」的路
	ok(main.hud.notice_active(), "★ 招募被拒 → 左栏出现红字提示（不然玩家以为点坏了）")
	ok(main.hud.notice_text().contains("不足"),
		"提示文案说明是资源不足（实际：%s）" % main.hud.notice_text())
	eq(world.retinue_of(g1.id).size(), before, "被拒的招募没有生成单位")
	ok(not g1.is_training(), "被拒的招募没有进队列")

	# 提示是**限时**的：过了 ui.notice_sec 秒自己消失
	main.hud._tick_notice(main.cfg.num("ui.notice_sec", 2.0) + 0.1)
	ok(not main.hud.notice_active(), "★ 提示到时自动消失")
	eq(main.hud.notice_text(), "", "消失之后文本也清掉")

	# ---- 资源与人口给足：点 Q 格 → 入队 ----
	world.resources["food"] = 200.0
	world.resources["gold"] = 200.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 5.0
	card.activate_index(0)
	ok(g1.is_training(), "★ 点单位页的 Q 格 → 排进招募队列")
	eq(g1.train_kind, UnitRes.KIND_SUBORDINATE, "大格子里是刚排进去的那个")
	near(float(world.resources["food"]), 150.0, 1e-4, "★ 入队即扣 50 粮食")
	eq(world.retinue_of(g1.id).size(), before, "★ 入队不会立刻生成单位（要读条 10 秒）")
	eq(g1.leader_id, "", "将领自己还是队长")

	main.hud.refresh()
	ok(queue.showing(), "★ 信息栏里出现五个格子")
	eq(queue.slot_count(), 5, "★ 一共五个格子")
	ok(queue.cell_filled(0), "大格子填上了（正在读条的那个）")
	ok(not queue.cell_filled(1), "小格子还是空的")
	ok(queue.cell_label(0).contains("兵"),
		"大格子里写着兵种短名（实际：%s）" % queue.cell_label(0))
	near(queue.progress(), 0.0, 1e-6, "刚入队时读条是 0")

	# ---- 键盘 Q 也走同一条路：第二个排进小格子 ----
	ok(card.handle_key(_key(KEY_Q)), "单位页的 Q 被命令卡吃掉")
	main.hud.refresh()
	eq(g1.train_queue.size(), 1, "★ 第二次招募排进小格子（不抢读条）")
	ok(queue.cell_filled(1), "第 2 个格子（小格）填上了")
	near(queue.progress(), 0.0, 0.05, "★ 排队的不影响正在读条那个的进度")

	# ---- 命令卡切页之后，招募不会串到建筑页上 ----
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)
	eq(g1.train_queue_size(), 2, "切页不会改变队列")

	# 选中别的单位 → 队列那五格收起来（它只显示「当前选中的将领」的队列）
	main.input_ctrl.select_units([])
	main.hud.refresh()
	ok(not queue.showing(), "★ 没选中招募中的将领时五格收起来")

	# 收尾：把这个将领的队列清干净（下一个用例要从「没在招募」开始）
	while g1.train_queue_size() > 0:
		world.cancel_recruit(g1.id, 0, "p1")
	ok(not g1.is_training(), "收尾：队列已清空")


# ---- 点队列格子 = 取消那一格（后方的队列前移）----
#
# 需求原话：「点击对应的格子取消对应格子上的造兵队列，其后方的造兵队列前移」。
# ★ 规则本身（退款 / 前移 / 从头读条）在 tests/test_recruit_queue.gd；
#   这里验的是「点格子 → 取消命令 → 那一格空了」这条接线。
func _test_queue_cancel_via_click(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	var q = main.hud.detail_panel.queue_control()

	# 排两单：大格子（正在读条）+ 第 1 个小格子
	card.activate_index(0)
	card.activate_index(0)
	main.hud.refresh()
	eq(g1.train_queue_size(), 2, "排了两单（1 大 + 1 小）")
	ok(q.showing(), "五格显示出来了")

	# ---- 点第 1 个小格子 → 取消那一格 + 退款 ----
	var food_before: float = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(1).get_center())
	eq(g1.train_queue_size(), 1, "★ 点小格子 = 取消那一格")
	near(float(world.resources["food"]), food_before + 50.0, 1e-4, "★ 取消会退款")
	main.hud.refresh()
	ok(not q.cell_filled(1), "★ 那一格空了（界面下一帧按权威状态重画）")

	# ---- 点空格子 → 什么都不发生 ----
	food_before = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(3).get_center())
	eq(g1.train_queue_size(), 1, "★ 点空格子什么都不发生")
	near(float(world.resources["food"]), food_before, 1e-6, "空格子也不会退钱")

	# ---- 点大格子 → 取消正在读条的那个（读条期间将领一直被钉住）----
	ok(g1.is_training(), "取消排队的那单之后还在读条")
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not g1.is_training(), "★ 取消掉最后一单 → 不再是「招募中」")
	main.hud.refresh()
	ok(not q.showing(), "★ 队列空了 → 五个格子收起来")


# ---- 招募完成时：玩家仍选中着那个将领 → 新兵也一起被选上 ----
#
# 需求原话：「为生成的单位添加一个规则，如果造一个兵结束时玩家仍选中其将领，
#            则这个新兵也会被选中」。
# ★ 「生成」那一步由 tests/test_recruit_queue.gd 验；这里验的是「事件到了之后，
#   UI 会不会把它选上」（game_scene._consume_events → input_ctrl.notify_unit_recruited）。
func _test_auto_select_on_recruit(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	var team_before: int = main.input_ctrl.selected_units.size()

	# 造一个「刚招募出来的新兵」（就是他名下多了一个兵）
	var fresh = UnitRes.create(main.cfg, "auto-r1", "亲兵 9",
		Vector2i(g1.tx, g1.ty), g1.faction, UnitRes.KIND_SUBORDINATE, "", g1.id)
	world.units.append(fresh)

	main._consume_events([{"type": "unit_recruited", "unit": fresh, "leader": g1}])
	eq(main.input_ctrl.selected_units.size(), team_before + 1, "★ 新兵也被选上了")
	ok(main.input_ctrl.selected_units.has(fresh), "★ 新兵在选中列表里")
	ok(fresh.selected, "★ 新兵身上的高亮标志也点亮了")

	# 反例：玩家已经改选别人 → **不打扰他**（需求的前提是「仍选中其将领」）
	main.input_ctrl.select_units([])
	main._consume_events([{"type": "unit_recruited", "unit": fresh, "leader": g1}])
	ok(main.input_ctrl.selected_units.is_empty(), "★ 没选中那个将领时不会把新兵硬塞进选中列表")
	ok(not fresh.selected, "新兵也不该被点亮")

	# 收尾
	world.units.erase(fresh)
	main.input_ctrl.select_units([g1])


## 造一次真实的鼠标左键点击，走控件自己的命中判定（_gui_input）
func _click_control(c: Control, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	c._gui_input(ev)


# ---- 招募期间整队不接受指令 → 左栏红字（不然右键点了没反应看起来就是坏了）----
#
# 需求原话：「玩家无法为正在招募单位的将领及其附属队列发布任何指令（移动/攻击）」。
# ★ 规则本身在 tests/test_recruit_queue.gd 的 _test_retinue_locked_while_training；
#   这里验的是「命令被拒之后玩家看得见一句话」这条反馈链。
func _test_order_locked_notice(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	main.input_ctrl.select_units([g1])
	card.activate_index(0)                       # 排一单 → 整队被锁住
	ok(g1.is_training(), "将领开始招募（整队进入「不接指令」状态）")
	main.hud.show_notice("")                     # 先把提示清掉，免得误判

	# 找一块空地右键过去：命令会发出去，但会被逻辑层拒掉
	var empty := Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			if world.can_build_at(tx, ty):
				empty = Vector2i(tx, ty)
				break
		if empty.x >= 0:
			break
	ok(empty.x >= 0, "找得到一格空地")
	main.input_ctrl.hover_tile = empty
	main.input_ctrl.mouse_world = Vector2(empty.x + 0.5, empty.y + 0.5)
	main.input_ctrl._on_right_click(false)
	var evts: Array = world.tick(1.0 / 60.0)
	main._consume_events(evts)
	ok(main.hud.notice_active(), "★ 指令被拒 → 左栏出现红字提示")
	ok(main.hud.notice_text().contains("招募"),
		"★ 提示说明是「将领正在招募」（实际：%s）" % main.hud.notice_text())
	ok(main.input_ctrl.move_marks.is_empty(),
		"★ 被锁住的队伍不会画「没人会走的移动标记」（不骗玩家）")
	ok(main.input_ctrl.selection_locked(), "选中的整队确实处于「被招募锁住」状态")

	# 亲兵也在锁的范围内：单独拿一个亲兵下令同样被拒
	var mate = world.retinue_of(g1.id)[0]
	ok(not CommandRes.apply(world, main.cfg, {"kind": "move", "ids": [mate.id],
		"x": float(empty.x), "y": float(empty.y), "faction": "p1"}),
		"★ 将领辖下的亲兵也不接受指令")
	# 别的将领照旧能下令
	var g2 = world.unit_by_id("general-2")
	ok(CommandRes.apply(world, main.cfg, {"kind": "move", "ids": [g2.id],
		"x": float(empty.x), "y": float(empty.y), "faction": "p1"}),
		"★ 没在招募的将领照旧能下令")

	# 收尾：清掉队列（后面的用例要在「没在招募」的世界里跑）
	while g1.train_queue_size() > 0:
		world.cancel_recruit(g1.id, 0, "p1")
	main.hud.show_notice("")
	ok(not g1.is_training(), "收尾：队列已清空")


# ---- 招募队列控件（RecruitQueue）：五格的显示与读条 ----
#
# ★ 这里单独构造一个控件、直接喂一个「正在招募」的将领 ——
#   不去动主场景那个世界（它还要给后面的用例用，tick 满 10 秒会把巡逻兵引过来）。
func _test_queue_control(cfg) -> void:
	var w = WorldRes.create(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-1")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	var q = RecruitQueueRes.new()
	root.add_child(q)
	q.setup(w)

	# 默认（没有选中将领）：整块不显示
	ok(not q.showing(), "没喂将领时不显示")
	q.set_leader(g1)
	ok(not q.showing(), "选中的将领没在招募 → 还是不显示（需求：开始招募时才出现）")

	w.start_recruit(UnitRes.KIND_SUBORDINATE, g1.id, "p1")
	w.start_recruit(UnitRes.KIND_SUBORDINATE, g1.id, "p1")
	q.set_leader(g1)
	ok(q.showing(), "★ 开始招募 → 五格出现")
	eq(q.slot_count(), 5, "五个格子")
	eq(q.cell_kind(0), UnitRes.KIND_SUBORDINATE, "大格子是正在读条的那个")
	eq(q.cell_kind(1), UnitRes.KIND_SUBORDINATE, "第 1 个小格子是排队的那个")
	eq(q.cell_kind(2), "", "后面三个小格子是空的")
	ok(q.cell_filled(0) and q.cell_filled(1) and not q.cell_filled(2), "填充状态跟着队列走")

	# 读条推进 → 进度跟着涨（大格子里的那条）
	for _i in 300:
		w.tick(1.0 / 60.0)
	q.set_leader(g1)
	near(q.progress(), 5.0 / 10.0, 0.05, "★ 读条到一半 → 进度条 50%")
	ok(q.cell_label(0).contains("s"), "大格子上写着剩余秒数（实际：%s）" % q.cell_label(0))

	q.queue_free()


# ---- 招募入队会发事件（走的是与建造同一条事件通道）----
#
# 症状有多难查见 pitfalls 5.14：命令是输入事件触发的、跑在两次 tick 之间，
# 而 tick 曾经在**开头**清空 _events —— 命令事件在送到界面前就被丢掉了。
func _test_recruit_queued_event(cfg) -> void:
	var w = WorldRes.create(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-1")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	w.tick(1.0 / 60.0)                  # 把上一帧的残留事件清干净
	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.KIND_SUBORDINATE,
		"leader_id": g1.id, "faction": "p1"}), "招募命令被接受（入队）")
	var events: Array = w.tick(1.0 / 60.0)
	var queued := 0
	for evt in events:
		if String(evt.get("type", "")) == "recruit_queued":
			queued += 1
	eq(queued, 1, "★ 招募入队的事件被下一次 tick 交了出来（命令事件不能在 tick 开头被丢掉）")




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
	# ★ 把「正好站在靶子这一格上」的自己人挪开：
	#   `_pick_unit_at` 的语义是「鼠标底下最近的一个**自己人**」，靶子身上要是
	#   正好叠着一个亲兵（出生站位撞上，实测 general-2-2 就在这一格），
	#   它当然会被拾取到 —— 那条断言验的是「不会选中**敌人**」，不该被叠格搅乱。
	for u in world.units:
		if u != foe and u.tx == foe.tx and u.ty == foe.ty:
			u.pos = GridRes.center_of(Vector2i(foe.tx, foe.ty + 3))
			u.sync_tile(world.map)
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

	# 5) ★ 右键点**区划中心** = 普通移动，不是攻击命令。
	#    中心是无主的中立障碍：它的 owner 是空字符串，`same_side` 那条判据拦不住它，
	#    少了 `is_invulnerable()` 这一道，右键点它会发出一条「攻击」命令 ——
	#    单位走过去对着打不掉的柱子敲到天荒地老（敌人贴脸了都不还手）。
	var center_tile := Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			if world.zone_center_zone_at(tx, ty) != null:
				center_tile = Vector2i(tx, ty)
				break
		if center_tile.x >= 0:
			break
	ok(center_tile.x >= 0, "地图上找得到一个区划中心")
	if center_tile.x >= 0:
		got.clear()
		main.input_ctrl.hover_tile = center_tile
		main.input_ctrl.mouse_world = Vector2(center_tile.x + 0.5, center_tile.y + 0.5)
		main.input_ctrl._on_right_click(false)
		eq(got.size(), 1, "右键点中心也发出了命令")
		eq(String(got[0].get("kind", "")), "move",
			"★ 右键点区划中心 = 普通移动（它不可攻击，不是「敌方建筑」）")
		ok(main.input_ctrl.move_marks.size() == 1, "走的是移动标记那条路")

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

	# 招募走的是同一条路（入队也是一条命令事件）—— 用一个干净的世界验，别动主场景那个
	_test_recruit_queued_event(main.cfg)


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	return ev
