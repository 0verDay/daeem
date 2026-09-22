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
const UiStyleRes = preload("res://view/ui_style.gd")
const DetailPanelRes = preload("res://view/detail_panel.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const RecruitQueueRes = preload("res://view/recruit_queue.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const PaletteRes = preload("res://view/palette.gd")
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

	_test_left_column_geometry()


# ---- 左栏几何：1 + 3×3 = 10 个格子（参考图逐像素量出来的，别凭感觉改）----
#
#  参考图 1920×1080 实测：左上第 1 格 40×40 在 (415, 858)，下面 3×3 的格子
#  列 x 415/536/662、行 y 915/970/1025 —— 是本轮改版照着抄的那套结构。
func _test_left_column_geometry() -> void:
	# 上半：就一个格子（将领格）
	eq(UiLayoutRes.ROSTER_DETAIL_H, 40.0, "★ 左栏上半就是一个 40 高的将领格")
	v2_near(UiLayoutRes.roster_cell_avatar_rect().size, Vector2(40.0, 40.0), 0.01,
		"★ 将领格是 40×40（参考图 x 415..454）")
	eq(UiLayoutRes.TROOP_GRID_COLS, 3, "下半是 3 列")
	eq(UiLayoutRes.TROOP_GRID_ROWS, 3, "下半是 3 行")
	eq(UiLayoutRes.TROOP_GRID_SLOTS, 9, "★ 下半 3×3 = 9 格（手玩原话：1333 排列）")
	eq(UiLayoutRes.GRID_PAGE, 9, "单选时滚轮**一次翻一页 = 9 格**（手玩原话）")
	# 每格 40×40，行距 44：3 行共 132，加上上半 40 + 缝 15 = 187 ≤ 内容高 220
	v2_near(UiLayoutRes.troop_avatar_rect(0).size, Vector2(40.0, 40.0), 0.01, "格里的方框 40×40")
	eq(UiLayoutRes.troop_cell_rect(0), Rect2(0, 0, 112, 44), "第 0 格在左上（宽 116 - 内侧 4）")
	eq(UiLayoutRes.troop_cell_rect(1).position.x, UiLayoutRes.TROOP_CELL_W,
		"第 1 格在它右边（列优先 → 行优先）")
	eq(UiLayoutRes.troop_cell_rect(3).position.y, UiLayoutRes.TROOP_CELL_H, "第 3 格换到第二行")
	eq(UiLayoutRes.troop_cell_rect(8).position.y, 2.0 * UiLayoutRes.TROOP_CELL_H, "第 8 格在第三行")
	# 9 格 + 上半那一格都必须落在左栏内容区里（不然会被面板裁掉）
	var bottom := UiLayoutRes.troop_cell_rect(8)
	ok(bottom.position.y + UiLayoutRes.TROOP_AVATAR <= 220.0,
		"★ 第 3 行的方框装得进左栏内容高（%s ≤ 220）" % str(bottom.position.y + UiLayoutRes.TROOP_AVATAR))
	var rightmost := UiLayoutRes.troop_cell_rect(2)
	ok(rightmost.position.x + UiLayoutRes.TROOP_CELL_W - 4.0 <= UiLayoutRes.DETAIL_LEFT_W + 1e-6,
		"★ 第 3 列的格子不越出左栏（%s ≤ %s）" % [
			str(rightmost.position.x + UiLayoutRes.TROOP_CELL_W - 4.0),
			str(UiLayoutRes.DETAIL_LEFT_W)])
	ok(UiLayoutRes.roster_detail_rect().position.y + UiLayoutRes.ROSTER_DETAIL_H
			<= UiLayoutRes.troop_grid_rect().position.y,
		"★ 上半那格与下半网格不重叠（%s ≤ %s）" % [
			str(UiLayoutRes.roster_detail_rect().position.y + UiLayoutRes.ROSTER_DETAIL_H),
			str(UiLayoutRes.troop_grid_rect().position.y)])
	ok(UiLayoutRes.TROOP_NAME_X + UiLayoutRes.TROOP_NAME_W + 8.0 <= UiLayoutRes.TROOP_CELL_W,
		"★ 格子里那一行名字 + 8px 缝仍在本格内，不会压到右边那一格的方框（%s ≤ %s）" % [
			str(UiLayoutRes.TROOP_NAME_X + UiLayoutRes.TROOP_NAME_W + 8.0),
			str(UiLayoutRes.TROOP_CELL_W)])
	# ★★ 这一条是补的回归（手玩报的「第二、三列的文字被挤到第一列去」）：
	#    文字**可写宽度必须真的装得下**「将领名称」四个字（13 号字 = 52px），否则会被截成
	#    两个字，看起来就像「字太小 / 那两列没字」。
	eq(UiLayoutRes.TROOP_NAME_W, 56.0, "★ 名字可写宽度 56（52px 的「将领名称」装得下）")
	ok(UiLayoutRes.TROOP_NAME_W > 52.0, "★ 比参考图量出来的「将领名称」宽度（52）宽一点")
	eq(UiLayoutRes.ROSTER_ID_W, UiLayoutRes.TROOP_NAME_W,
		"★ 左栏上半那一格与下面 9 格用**同一套**文字宽度（看着才是一套东西）")
	eq(UiLayoutRes.ROSTER_CELL_TEXT_X, UiLayoutRes.TROOP_NAME_X, "★ 两段文字左边对齐")
	# ★ 两行文字要**与方框垂直居中**（手玩原话：「对齐其对应左侧头像居中」）：
	#   两行作为一块，上下边距相等；且第二行要落在方框里面。
	var block_top: float = UiLayoutRes.TROOP_NAME_Y - UiStyleRes.FS_SMALL
	var block_bottom: float = UiLayoutRes.TROOP_NAME2_Y
	ok(UiLayoutRes.TROOP_NAME2_Y > UiLayoutRes.TROOP_NAME_Y, "★ 第二行在第一行下面")
	ok(block_top >= 0.0 and block_bottom <= UiLayoutRes.TROOP_AVATAR,
		"★ 两行都落在方框的竖直范围里（%s .. %s ≤ %s）" % [
			str(block_top), str(block_bottom), str(UiLayoutRes.TROOP_AVATAR)])
	near(block_top, UiLayoutRes.TROOP_AVATAR - block_bottom, 2.0,
		"★ 两行作为一块与方框**垂直居中**（上留 %.1f、下留 %.1f）" % [
			block_top, UiLayoutRes.TROOP_AVATAR - block_bottom])
	eq(UiLayoutRes.ROSTER_ID_Y, UiLayoutRes.TROOP_NAME_Y,
		"★ 左栏上半那一格的两行与下面 9 格同一套基线")
	eq(UiLayoutRes.ROSTER_COUNT_X, UiLayoutRes.ROSTER_CELL_TEXT_X,
		"★ 「1/11」与名字同一个左边（参考图里两行左边缘对齐）")
	ok(UiLayoutRes.ROSTER_COUNT_X + UiLayoutRes.ROSTER_COUNT_W <= UiLayoutRes.DETAIL_LEFT_W,
		"★ 「1/11」也不会越出左栏（%s ≤ %s）" % [
			str(UiLayoutRes.ROSTER_COUNT_X + UiLayoutRes.ROSTER_COUNT_W),
			str(UiLayoutRes.DETAIL_LEFT_W)])

	# ★★ 回归（手玩报的：「选中多个单位或将领时，第二、三列的文字会挤到第一列」）：
	#    每一格右边那两行字的左边 = **这一格自己的左边** + 格内的 TROOP_NAME_X。
	#    ⚠️ 上面那几条「常量够不够宽」的断言抓不住这个 bug —— 常量**全是对的**，
	#       错的是画的时候 x 没加「第几列」的偏移（y 加了、x 没加），
	#       所以只有 1 格时看着正常、多选（≥2 格）时三列的字叠在第 1 列上。
	#       ⇒ 必须**逐格比 x**，不能只比常量。
	for gi in UiLayoutRes.TROOP_GRID_SLOTS:
		var gcell := UiLayoutRes.troop_cell_rect(gi)
		var gname := UiLayoutRes.troop_name_rect(gi)
		eq(gname.position.x, gcell.position.x + UiLayoutRes.TROOP_NAME_X,
			"★ 第 %d 格的文字左边 = 本格左边 + %s（不挤到第 1 列）" % [
				gi, str(UiLayoutRes.TROOP_NAME_X)])
		eq(gname.position.y, gcell.position.y, "★ 第 %d 格的文字顶边 = 本格顶边" % gi)
		ok(gname.position.x >= gcell.position.x + UiLayoutRes.TROOP_AVATAR,
			"★ 第 %d 格的文字在本格方框右边（%s ≥ %s）" % [
				gi, str(gname.position.x), str(gcell.position.x + UiLayoutRes.TROOP_AVATAR)])
		ok(gname.position.x + gname.size.x <= gcell.position.x + gcell.size.x + 0.01,
			"★ 第 %d 格的文字不越出本格（%s ≤ %s）" % [
				gi, str(gname.position.x + gname.size.x),
				str(gcell.position.x + gcell.size.x)])
	# 三列的文字左边必须**依次右移**（「都挤到第一列」的反面）
	ok(UiLayoutRes.troop_name_rect(0).position.x < UiLayoutRes.troop_name_rect(1).position.x
			and UiLayoutRes.troop_name_rect(1).position.x < UiLayoutRes.troop_name_rect(2).position.x,
		"★ 三列的文字左边依次右移（列差 = 格宽 %s）" % str(UiLayoutRes.TROOP_CELL_W))
	near(UiLayoutRes.troop_name_rect(1).position.x - UiLayoutRes.troop_name_rect(0).position.x,
		UiLayoutRes.TROOP_CELL_W, 0.01, "★ 相邻两列的文字左边正好差一格宽")
	# 三行同理（第 4 格换行 → 回到第 1 列的 x，但 y 下移一行）
	eq(UiLayoutRes.troop_name_rect(3).position.x, UiLayoutRes.troop_name_rect(0).position.x,
		"★ 第 2 行第 1 列的文字左边与第 1 行第 1 列对齐")
	eq(UiLayoutRes.troop_name_rect(3).position.y - UiLayoutRes.troop_name_rect(0).position.y,
		UiLayoutRes.TROOP_CELL_H, "★ 换行时文字跟着下移一格高")


# ------------------------------------------------------------------
# 二、鼠标：只有「能点的控件」才拦边缘滚屏
# ------------------------------------------------------------------
func _test_hit_test() -> void:
	var vp := Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H)
	var map_middle := Vector2(960.0, 400.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), map_middle),
		"地图空白处不拦鼠标（点击要能落到地图上）")

	# ★ 这一条是重点：详细信息面板里**只有文字的**地方**不能**拦边缘滚屏 ——
	#   否则底栏盖住屏幕下沿，鼠标永远滚不到地图下方（实测撞出来的）。
	#   ⚠️ 第三轮改版之后面板中间那片是**将领头像网格**（能点），所以要拿
	#     面板**左上**（左栏上半只有文字与方块）来验这条，见下一条。
	var detail_text_spot := UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), detail_text_spot),
		"★ 详细信息面板里只有文字的地方不拦边缘滚屏（否则底边永远滚不动）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.FACTION_RECT.get_center()),
		"阵营占位面板同样不拦")

	# ★★ 网格是**能点**的（点一格 = 换展开哪支部队 / 切右栏到某个单位）→ 它要拦边缘滚屏。
	#    它与小地图同一条理由：鼠标停在能点的格子上时不该同时被边缘推着滚屏。
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.troop_cell_global_rect(0).get_center()),
		"★ 详细信息左栏下半那 9 个格子拦边缘滚屏（它是可点的）")

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
	_test_avatar_text_fit(cfg)
	_test_recruit_via_card(main)
	_test_queue_control(cfg)
	_test_queue_cancel_via_click(main)
	_test_auto_select_on_recruit(main)
	_test_order_locked_notice(main)
	_test_right_click_orders(main)
	await _test_box_select(main)
	_test_clicked_unit_detail(main)
	_test_settings_inert(main)
	await _test_command_events_reach_consumer(main)

	# ---- 详细信息面板的内容（第三轮改版：左右两栏 + 提示行；日志整块删掉）----
	main.input_ctrl.select_units([main.world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not main.hud.detail_panel.has_log(), "★ 事件日志整块删掉了（detail_panel 里没有日志栏）")
	ok(main.hud.detail_panel.detail_text().contains("血量"), "右栏数值区显示选中单位的数值")
	eq(main.hud.detail_panel.buff_count(), UiLayoutRes.BUFF_SLOTS, "★ 右栏有 3 个 buff 占位格")
	ok(main.hud.detail_panel.unit_name_text() != "", "右栏写着单位名称")

	# 没选中任何东西：右栏数值区只有「未选中」，左栏上半也收起来
	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(main.hud.detail_panel.detail_text(), "未选中", "★ 没选中时只显示「未选中」（不再有操作提示）")
	eq(main.hud.detail_panel.unit_name_text(), "", "没选中单位时右栏没有名称")
	ok(not main.hud.detail_panel.roster_control().visible, "没选中部队时左栏上半收起来")
	main.input_ctrl.select_units([main.world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not main.hud.detail_panel.detail_text().contains("Shift"),
		"★ 不再显示快捷键提示")

	# ---- 边缘滚屏：HUD 上的判定（真实实例，不只看常量）----
	var card0 := UiLayoutRes.card_cell_rect(0)
	card0.position.x += maxf(0.0, vp.x - UiLayoutRes.DESIGN_W)
	card0.position.y += maxf(0.0, vp.y - UiLayoutRes.DESIGN_H)
	ok(main.hud.blocks_edge_scroll(card0.get_center()), "鼠标在命令卡上 → 不滚屏")
	ok(not main.hud.blocks_edge_scroll(UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)),
		"★ 鼠标在详细信息面板**只有文字**的地方 → 照样滚屏（不然底边滚不动）")
	ok(main.hud.blocks_edge_scroll(UiLayoutRes.troop_cell_global_rect(0).get_center()),
		"★ 鼠标在将领头像网格上 → 不滚屏（那是可点的格子）")
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


# ---- ★ 右栏头像里那个字必须**装得进方框**（手玩报的「字右下对齐」就是这个）----
#
# 症状：方框 40×40，字号却写的是 44 —— 汉字的字面高≈字号，44 的字塞不进去，
#       而 `draw_string` 会被裁到控件矩形里，看起来就是「字被推到右下角、还缺一角」。
# 判据：按方框现算出来的字号，**渲染尺寸**必须 ≤ 方框（留 2px 余量）。
func _test_avatar_text_fit(cfg) -> void:
	var panel = DetailPanelRes.new()
	root.add_child(panel)
	await process_frame
	var font: Font = FontLoaderRes.load_font(cfg)
	ok(font != null, "（前提）拿得到中文字体（拿不到的话整屏是方框，另有用例在管）")
	if font == null:
		panel.queue_free()
		return
	panel.setup(null, font)

	ok(panel._unit_avatar != null, "右栏有头像方框那个控件")
	var f2: Font = panel._unit_avatar.get_theme_default_font()
	ok(f2 != null, "（前提）头像控件能拿到字体")
	if f2 == null:
		panel.queue_free()
		return

	var side: float = UiLayoutRes.UNIT_AVATAR
	eq(side, 100.0, "★ 右栏头像方框 = 100×100（参考图实测 x 806..905、y 860..959）")
	# 「将 / 兵 / 区 / 建」这些实际会出现的字都得装得下，而且要把方框填满（别缩成一小坨）
	for ch in ["将", "兵", "区", "建"]:
		panel.set_unit_avatar_text(ch)
		var size: int = panel._avatar_font_size(f2)
		var sz := f2.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
		ok(sz.x <= side - 4.0 + 0.01 and sz.y <= side - 4.0 + 0.01,
			"★ 头像里的「%s」用 %d 号字，渲染 %.0f×%.0f ≤ 方框 %.0f（装得下才不会被裁到右下角）"
				% [ch, size, sz.x, sz.y, side])
		ok(size > side * 0.6,
			"★ 现算的字号（%d）要把方框**填满**（> %.0f）—— 太小就成了一小坨字" % [
				size, side * 0.6])

	# 真的画了一帧（`_draw` 里出错在无头下不会让测试失败，所以盯一下计数器）
	panel.set_unit_avatar_text("将")
	var before: int = panel.avatar_draw_count()
	panel._unit_avatar.queue_redraw()
	await process_frame
	ok(panel.avatar_draw_count() > before, "★ 头像那一块真的画了一帧（_draw 跑过）")
	panel.queue_free()
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

	# ★ 带修饰键的组合键不许被命令卡吃掉。
	#   为什么单列一条：命令卡在输入链里排在 main / input_controller 的**前面**
	#   （game_scene._unhandled_input 先问 hud），所以 Ctrl+Q（开发者快捷键：全屏）
	#   如果被它吃掉，「切全屏」就会顺手触发 Q 格 —— 单位页按下去 = 招募一个兵。
	#   见 command_card.handle_key 里那段 ctrl/alt/meta 放行。
	ok(not card.handle_key(_key(KEY_Q, true)),
		"★ Ctrl+Q 不被命令卡消费（要让给 main 的全屏快捷键）")
	ok(not card.handle_key(_key(KEY_W, true)),
		"★ Ctrl+W 也不被命令卡消费（同一类组合键一起让出来）")
	# ⚠️ 「Ctrl+Q 归 main 的全屏快捷键消费」那条在 tests/test_view.gd ——
	#    本文件里的 `main` 其实是 root_node.game（游戏内场景），拿不到 main.gd 的根节点。


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
	ok(queue != null, "详细信息右栏里有招募队列控件")
	ok(not queue.showing(), "★ 没在招募时五个格子收起来（需求：将领开始招募时才出现）")

	# ---- 资源不足：命令被拒 + 红字原因 ----
	world.resources["food"] = 10.0
	world.resources["gold"] = 10.0
	card.activate_index(0)
	var evts: Array = world.tick(1.0 / 60.0)
	main._consume_events(evts)                 # 走真实那条「事件 → 文案」的路
	ok(main.hud.notice_active(), "★ 招募被拒 → 出现红字提示（不然玩家以为点坏了）")
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

	# 选中别的单位 → 队列那五格收起来（它只显示「当前展开那支部队」的队列）
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


# ---- 框选：左键拖出矩形 = 选中框内己方单位**所属的部队** ----
#
# 需求原话：「为玩家增加一个框选操作，当玩家框到某些己方单位时，视为选中这些单位
#            所属的部队，如果有多个部队，也一同选中，同时左侧部队 ui 也会显示这些部队
#            被选中，下方详细信息需要分部队显示单位」。
#
# ★ 这一节刻意**把队伍摆到受控的位置上**再用框去框 —— 出生站位是挤在大本营周围的，
#   用真实站位断言「框里有几支队伍」会变成一件碰运气的事。
func _test_box_select(main) -> void:
	var world = main.world
	var cfg = main.cfg
	var g1 = world.unit_by_id("general-1")
	var g2 = world.unit_by_id("general-2")
	var g3 = world.unit_by_id("general-3")
	ok(g1 != null and g2 != null, "框选用例：将领 1 / 2 都在")
	if g1 == null or g2 == null:
		return

	# 框的范围（世界坐标，格）与「摆到框外」的地方
	var lo := Vector2(2.0, 2.0)
	var hi := Vector2(6.0, 6.0)
	var far_lo := Vector2(20.0, 20.0)
	var far_hi := Vector2(24.0, 24.0)

	var t1: Array = world.group_of(g1)
	var t2: Array = world.group_of(g2)
	# 1 队：**队长在框外**，亲兵在框内 —— 框到亲兵也必须把队长带出来
	_place_unit(world, g1, far_lo)
	_place_units_in_rect(world, t1.slice(1), lo, hi)
	# 2 队：只有第一个亲兵在框内，其余在框外（同样要整队被选中）
	_place_unit(world, g2, far_lo + Vector2(0.0, 2.0))
	_place_units_in_rect(world, t2.slice(1, 2), lo, hi)
	_place_units_in_rect(world, t2.slice(2), far_lo, far_hi)
	# 3 队：整支都在框外（不该被选中）
	if g3 != null:
		_place_unit(world, g3, far_lo + Vector2(0.0, 4.0))
		_place_units_in_rect(world, world.group_of(g3).slice(1), far_lo, far_hi)
	# 一个敌人故意放进框里（框选只认自己人）
	var foe = world.spawn_enemy(int(lo.x) + 1, int(lo.y) + 3)
	ok(foe != null, "刷一个敌人放进框里")
	if foe != null:
		_place_unit(world, foe, Vector2(lo.x + 1.5, lo.y + 0.5))

	# ---- 期望值：按需求自己算一遍（框内己方单位 → 各自所属部队的并集）
	var rect := Rect2(lo, hi - lo)
	var in_rect: Array = []
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if rect.has_point(u.pos):
			in_rect.append(u)
	var expect: Dictionary = {}
	for u in in_rect:
		for m in world.group_of(u):
			expect[String(m.id)] = true
	ok(in_rect.size() > 0, "框里确实有己方单位（%d 个）" % in_rect.size())

	# ---- 框选本体（语义入口：起点与终点是世界坐标）
	main.input_ctrl.select_units([])
	var picked: int = main.input_ctrl.box_select(lo, hi)
	eq(picked, in_rect.size(), "★ 框到的是框内的己方单位（敌人不算进去）")
	eq(_sorted_ids(main.input_ctrl.selected_units), _sorted_keys(expect),
		"★ 选中的 = 框内单位**所属部队**的并集（不是「框里的那几个」）")
	ok(main.input_ctrl.selected_units.has(g1),
		"★ 队长在框外，也被一起选中（框到一个亲兵 = 选中整支部队）")
	ok(main.input_ctrl.selected_units.has(g2), "★ 第二支部队也一同选中")
	eq(main.input_ctrl.selected_units.size(), t1.size() + t2.size(),
		"★ 两支**完整**部队（队长 + 全部亲兵），哪怕一半人在框外")
	if g3 != null:
		ok(not main.input_ctrl.selected_units.has(g3), "框外的第三支部队没被选中")
	if foe != null:
		ok(rect.has_point(foe.pos), "（前提）敌人确实站在框里")
		ok(not main.input_ctrl.selected_units.has(foe), "★ 框里的敌人不会被选中")
	ok(main.input_ctrl.selected_building == null and main.input_ctrl.selected_zone == null,
		"框选是「选中单位」这一种，建筑 / 区划的选中被清掉")

	# ---- 左侧部队 UI：被选中的那两支要高亮（同一份 selected_units 的自然结果）
	main.hud.refresh()
	eq(main.hud.squad_panel.slot_active(0), true, "★ 左侧「部队 1」显示为选中")
	eq(main.hud.squad_panel.slot_active(1), true, "★ 左侧「部队 2」也显示为选中")
	if g3 != null:
		eq(main.hud.squad_panel.slot_active(2), false, "没框到的第三支部队不高亮")

	# ---- 下方详细信息（第四轮改版）：
	#      左栏上半 = **当前展开的那一支部队的将领格**；
	#      左栏下半 = 3×3 网格：多选时画**其余**部队的将领，单选时画这支部队的**单位**
	var roster = main.hud.detail_panel.roster_control()
	var grid = main.hud.detail_panel.grid_control()
	ok(roster != null, "详细信息左栏上半有「当前展开的部队」那一格")
	ok(grid != null, "详细信息左栏下半有 3×3 的网格")
	if roster != null and grid != null:
		ok(roster.visible, "选中单位之后左栏上半出现")
		eq(roster.unit_count(), t1.size(), "★ 上半画的是**当前展开那一支**的完整部队")
		eq(roster.leader().id, g1.id, "★ 上半是第 1 支部队（内部状态对得上）")
		eq(roster.leader_name(), String(g1.name),
			"★ 那一格第一行写的是**将领真名**（参考图上写的就是这一行名字）")
		eq(roster.count_text(), "%d/%d" % [t1.size(), UiLayoutRes.UNIT_CAP],
			"★ 写着「现有单位数/编制上限」（y = 编制上限 11）")
		eq(roster.leader_short(), "将",
			"★ 那一格的短字是「将」——**不再额外画一个「将」大方块**（手玩原话）")
		eq(roster.short_name(t1[0]), "将", "★ 队长的短字是「将」（没有头像，用字代替）")
		eq(roster.short_name(t1[1]), "兵", "★ 亲兵的短字是 config 的 short（兵）")

		# ★ 右栏报的是**将领**，不是整队选中时排在最后的那个亲兵
		#   （框选 / 点左侧列表拿到的都是整队；选中列表最后一个往往是亲兵，
		#    不加这条判据的话右栏会写成「亲兵 3」——手玩一眼就能看出来）
		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 整队选中时右栏报的是**将领**（不是排在最后的亲兵）")
		ok(main.hud.detail_panel.detail_text().contains("血量 200"),
			"★ 右栏那些数值也是将领的（满血 200，亲兵是 80）")

		# ★ 「将领名称 1/11」那一行要装得进左栏（参考图里它写在方框右边）
		ok(UiLayoutRes.ROSTER_COUNT_X + 40.0 <= UiLayoutRes.DETAIL_LEFT_W,
			"★ 「将领名称 1/11」那一行装得进左栏")

		# ---- 多选：下半网格 = **只列没被展开的那些**部队的将领（手玩原话：
		#      「被展开的部队不需要在下方的九宫格中显示」「点将领格 = 换展开哪支部队」）----
		ok(grid.visible, "选中部队之后网格出现")
		eq(main.hud.detail_panel.grid_mode(), "leaders", "★ 选中多支部队时网格是**将领模式**")
		eq(grid.troop_count(), 1, "★ 网格只列**没被展开的**那 1 支（展开的那支已在上半）")
		eq(grid.cell_count(), 1, "画了 1 格")
		eq(grid.leader_name(0), String(g2.name), "★ 那一格是第 2 支部队（第 1 支正在上面展开）")
		ok(grid.cell_is_leader(0), "那一格是将领格")
		eq(grid.cell_short(0), String(g2.name).substr(0, 1), "将领格方框里写名字首字")
		# ★ 拖拽（框选）多支部队 → 右栏显示**展开的那一支（序号靠前那支）的将领**
		#   （手玩原话：「若拖拽选中多个部队，则显示展开的部队（序号靠前的部队）的将领」）----
		eq(main.input_ctrl.selection_origin, "drag", "（前提）这一步是通过框选选中的")
		eq(roster.leader().id, g1.id, "（前提）展开的是序号靠前的第 1 支部队")
		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 拖拽选中多个部队 → 右栏显示**展开那支部队的将领**")
		ok(main.hud.detail_panel.detail_text().contains("已选中 2 支部队"),
			"★ 多选时右栏补一行「已选中 N 支部队」")
		# ★ 多选时下半网格只画**其余部队的将领**，不画单位（单位只在单选时出现）
		eq(grid.cell_count(), 1, "★ 多选时下半网格里只有那 1 支没展开的部队")
		ok(grid.unit_at(0) == g2, "★ 那一格画的是将领本人（不是单位）")
		eq(grid.unit_total(), 0, "★ 多选时没有「单位翻页」这回事（页数 = 0）")
		eq(UiLayoutRes.TROOP_GRID_SLOTS, 9,
			"★ 网格正好 9 格（手玩原话：参考图下方是 1333 排列的 9 个格子）")
		ok(UiLayoutRes.TROOP_GRID_SLOTS + 1 == 10,
			"★ 9 格 + 左上展开的那一格 = 10 格，正好对上「玩家部队上限 10 支」（手玩原话）")
		# ★ 两栏比例按参考图逐像素量出来的（左 37.5 : 右 62.5），别凭感觉改
		eq(UiLayoutRes.DETAIL_LEFT_W + UiLayoutRes.DETAIL_GAP + UiLayoutRes.DETAIL_RIGHT_W,
			UiLayoutRes.DETAIL_RECT.size.x - 2.0 * UiLayoutRes.DETAIL_PAD,
			"★ 左栏 + 缝 + 右栏 = 面板内容宽（不然右栏会被裁掉）")
		ok(UiLayoutRes.DETAIL_LEFT_W < UiLayoutRes.DETAIL_RIGHT_W,
			"★ 右栏比左栏宽（参考图里左栏只放一支部队，右栏要放头像+名称+buff+数值）")
		ok(UiLayoutRes.DETAIL_LEFT_W / (UiLayoutRes.DETAIL_LEFT_W + UiLayoutRes.DETAIL_RIGHT_W)
				< 0.40,
			"★ 左栏占不到 40%（参考图实测 37.5%）—— 之前写成 42%~78% 被判「左侧明显大了」")
		# 右栏那几块也必须装得进右栏
		ok(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W
				<= UiLayoutRes.DETAIL_RIGHT_W + 1e-6,
			"★ 「详细信息」方框不越出右栏")
		ok(UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H <= 220.0,
			"★ 「详细信息」方框装得进右栏内容高（220）")
		ok(UiLayoutRes.BUFF_X + float(UiLayoutRes.BUFF_SLOTS)
				* (UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_GAP)
				<= UiLayoutRes.DETAIL_RIGHT_W + 1e-6,
			"★ 三个 buff 不越出右栏")
		# ★★ 右栏那几块照参考图逐像素量的尺寸（手玩报过两次「头像不对」）
		eq(UiLayoutRes.UNIT_AVATAR, 100.0,
			"★ 右栏头像方框 100×100（参考图实测 x 806..905、y 860..959）")
		eq(UiLayoutRes.BUFF_SIZE, 30.0, "★ buff 三格各 30×30（参考图）")
		ok(UiLayoutRes.BUFF_Y >= UiLayoutRes.UNIT_AVATAR_Y
				and UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE
					<= UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR + 1e-6,
			"★ 三个 buff 落在头像的竖直范围内（%s..%s）" % [
				str(UiLayoutRes.BUFF_Y),
				str(UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE)])
		ok(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W <= UiLayoutRes.DETAIL_RIGHT_W,
			"★ 单位名称那一行装得进右栏（%s ≤ %s）" % [
				str(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W),
				str(UiLayoutRes.DETAIL_RIGHT_W)])
		ok(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR
				< UiLayoutRes.DETAIL_BODY_Y,
			"★ 头像在「详细信息」方框上面，不重叠（%s < %s）" % [
				str(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR),
				str(UiLayoutRes.DETAIL_BODY_Y)])

		# ★ 真的让它画一帧：`_draw` 里出错在无头下不会让测试失败（退出码照样是 0），
		#   所以这里盯一下计数器 —— 「控件在、但绘制那段从来没跑过」是最容易漏掉的假绿灯。
		var before_draw: int = roster.draw_count
		var before_grid: int = grid.draw_count
		roster.queue_redraw()
		grid.queue_redraw()
		await process_frame
		ok(roster.draw_count > before_draw, "★ 左栏上半真的画了一帧（_draw 跑过）")
		ok(grid.draw_count > before_grid, "★ 网格真的画了一帧（_draw 跑过）")

		# ---- 点网格那一格 → **只换展开哪一支**，不动选中（需求原话：
		#      「当选中多个部队时，点击左侧的部队头像是将展开的部队切换到该部队，
		#       而不是只选中该部队」）----
		main.hud._on_troop_activated(99)                 # 先喂一个不存在的编号 → 什么都不该变
		eq(roster.leader().id, g1.id, "喂一个不存在的部队编号 → 展开的还是原来那支")
		main.hud._on_troop_activated(2)                  # 第 2 支部队的编号（走 hud 的真实处理）
		eq(roster.leader().id, g2.id, "★ 展开切到了第 2 支部队")
		eq(main.input_ctrl.selected_units.size(), t1.size() + t2.size(),
			"★ 点格子**不改选中**（两支部队仍然都选着，需求原话）")
		ok(main.hud.detail_panel.detail_text().contains("血量"),
			"★ 右栏跟着换成那一支部队的单位数值")
		eq(grid.cell_count(), 1, "★ 展开的那支从网格里消失、换成了另一支")
		eq(grid.leader_name(0), String(g1.name), "★ 网格里现在是第 1 支部队")

		# ---- 点真实的那一格（走控件的命中判定，不是直接调处理函数）----
		var both: Array = []
		both.append_array(world.group_of(g1))
		both.append_array(world.group_of(g2))
		main.input_ctrl.select_units(both)
		main.hud.refresh()
		eq(grid.cell_count(), 1, "（前提）两支部队都选中时，网格里只剩没展开的那 1 支")
		eq(roster.leader().id, g2.id,
			"（前提）展开的仍是上一段记住的那一支（第 2 支）")
		eq(grid.leader_name(0), String(g1.name), "（前提）网格里是没展开的第 1 支")
		var cell0 := UiLayoutRes.troop_cell_rect(0)
		_click_control(grid, cell0.get_center())
		eq(main.input_ctrl.selected_units.size(), t1.size() + t2.size(),
			"★ 点那一格（真实命中判定）**不改选中**：两支部队仍然都选着")
		eq(roster.leader().id, g1.id, "★ 但展开切到了第 1 支部队")
		eq(grid.leader_name(0), String(g2.name), "★ 网格里换成了第 2 支部队")

		# ---- ★★ 单选一支部队：下半网格换成**这支部队的单位**，滚轮翻页看更多
		#      （需求原话：「玩家只选中了单个部队时，上方显示选中的部队的将领，
		#       下方 333 排列显示选中的部队的单位，此时可左右滑动以显示更多的单位」）----
		main.input_ctrl.select_units([g1])
		main.hud.refresh()
		eq(main.hud.detail_panel.grid_mode(), "units",
			"★ 只选中一支部队时，下半网格是**单位模式**（画这支部队的单位）")
		eq(grid.cell_count(), t1.size(), "★ 格数 = 这支部队的单位数（含将领）")
		eq(grid.unit_at(0).id, g1.id, "★ 第 1 格是**将领本人**（参考图里它就是第一个方框）")
		ok(grid.cell_is_leader(0) == false, "单位格不是将领格（点击语义按单位走）")
		eq(grid.cell_short(0), "将", "★ 将领那一格的方框里写「将」")
		eq(grid.cell_name(0), String(g1.name), "格子右边写着单位名")
		eq(grid.unit_at(1).id, t1[1].id, "第 2 格是第 1 个亲兵")

		# 点一格单位（走真实命中判定）→ 右栏切到那个单位，且**不改选中**
		var sel_before2: int = main.input_ctrl.selected_units.size()
		_click_control(grid, UiLayoutRes.troop_cell_rect(1).get_center())
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(t1[1].name),
			"★ 点左栏下半的单位格 → 右栏切到那个单位")
		eq(main.input_ctrl.selected_units.size(), sel_before2,
			"★ 点单位格**不改选中**（命令发给谁不受影响）")
		# 再点回将领那一格 → 右栏回到将领
		_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 点第 1 格（将领）→ 右栏回到将领")

		# 单位塞到 12 个（编制上限 11，这里只为了凑出第二页）→ 滚轮往下翻一页
		for _k in 11:
			var extra = UnitRes.create(main.cfg, "scroll-%d" % _k, "亲兵 s%d" % _k,
				Vector2i(g1.tx, g1.ty), g1.faction, UnitRes.KIND_SUBORDINATE, "", g1.id)
			world.units.append(extra)
		main.input_ctrl.select_units([g1])
		main.hud.refresh()
		eq(grid.unit_total(), t1.size() + 11, "（前提）这支部队的单位多到一页画不下")
		ok(grid.page_count() >= 2, "★ 单位超过 9 个 → 不止一页（一页 9 格）")
		eq(grid.page(), 0, "★ 默认停在第 1 页")
		eq(grid.cell_count(), 9, "★ 第 1 页画满 9 格")
		eq(grid.unit_at(0).id, g1.id, "（前提）第 1 格还是将领")
		var sec_page: int = grid.unit_total() - UiLayoutRes.GRID_PAGE
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = Vector2(60.0, 20.0)
		grid._gui_input(wheel)
		eq(grid.page(), 1, "★ 滚轮往下 = 翻到下一页（一次一页 9 格）")
		eq(grid.cell_count(), sec_page, "第 2 页只剩 %d 个格子的内容" % sec_page)
		ok(grid.unit_at(0).id != g1.id, "第 2 页不再从将领开头")
		grid._gui_input(wheel)
		eq(grid.page(), 1, "★ 已经在最后一页 → 再往下滚也不动")
		var wheel_up := InputEventMouseButton.new()
		wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel_up.pressed = true
		wheel_up.position = Vector2(60.0, 20.0)
		grid._gui_input(wheel_up)
		eq(grid.page(), 0, "★ 滚轮往上 = 翻回上一页")
		eq(grid.unit_at(0).id, g1.id, "翻回第 1 页又是从将领开头")
		grid._gui_input(wheel_up)
		eq(grid.page(), 0, "★ 已经在第一页 → 再往上滚也不动")

		# 换成选中别的部队 → 网格回到第 1 页（新的一批单位）
		main.input_ctrl.select_units([g2])
		main.hud.refresh()
		eq(grid.page(), 0, "★ 换成别的部队 → 翻页回到第 1 页")
		eq(grid.unit_at(0).id, g2.id, "网格里是第 2 支部队的将领")

		# 收尾：把这几个测试单位清掉，别影响后面的用例
		for u6 in world.units.duplicate():
			if String(u6.id).begins_with("scroll-"):
				world.units.erase(u6)

		# ---- ★ 文字截断：格子里那一行名字必须**自己量、自己砍** ----
		#   为什么值得测：`draw_string` 的宽度参数**不保证裁剪**，两格之间又只有 24px 净空
		#   ⇒ 不截断的话第一格的字会盖到第二格的方框上（手玩报的「第二、三列没字」）。
		main.hud.refresh()
		ok(grid.cell_count() > 0, "（前提）网格里有格子可以量")
		var gi := 0
		var cell_name_text: String = grid.cell_name(gi)
		var shown: String = grid._clip_text(main.hud._font, cell_name_text,
			UiLayoutRes.TROOP_NAME_W, UiStyleRes.FS_SMALL)
		ok(shown == cell_name_text
				or main.hud._font.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1,
					UiStyleRes.FS_SMALL).x <= UiLayoutRes.TROOP_NAME_W + 0.01,
			"★ 短名字照原样画（%s）" % shown)
		var long_name := "单位名称单位名称"
		var clipped: String = grid._clip_text(main.hud._font, long_name,
			UiLayoutRes.TROOP_NAME_W, UiStyleRes.FS_SMALL)
		ok(main.hud._font.get_string_size(clipped, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UiStyleRes.FS_SMALL).x <= UiLayoutRes.TROOP_NAME_W + 0.01,
			"★ 名字太长 → 截到可用宽度以内（%s）" % clipped)
		ok(clipped.length() < long_name.length() and clipped.ends_with("…"),
			"★ 截断会加省略号（%s）" % clipped)
		# 左栏上半那一格同理（「将领名称 1/11」两段都不能越过左栏）
		var roster2 = main.hud.detail_panel.roster_control()
		var label_clip: String = roster2._clip_text(main.hud._font, "将领名称将领名称",
			UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL)
		ok(main.hud._font.get_string_size(label_clip, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UiStyleRes.FS_SMALL).x <= UiLayoutRes.ROSTER_ID_W + 0.01,
			"★ 左栏那一格的名字也按 ROSTER_ID_W 截断（%s）" % label_clip)

		# ---- ★★ 文字位置：每一格的字必须画在**它自己那一格**里 ----
		#   手玩报的：「选中多个单位或将领时，第二、三列的文字会挤到第一列」。
		#   根因是文字 x 少了「第几列」的偏移（y 加了、x 没加）。
		#   ⚠️ 那种错**画一帧不会报错**（`_draw` 里画错地方是静默的），
		#      所以这里读控件真正用的那个坐标（`cell_text_origin()`）来钉死它。
		ok(grid.cell_count() >= 2, "（前提）网格里至少 2 格 —— 只有 ≥2 格才看得出串列")
		eq(grid.cell_text_origin(1).x - grid.cell_text_origin(0).x, UiLayoutRes.TROOP_CELL_W,
			"★ 第 2 列的文字左边 = 第 1 列 + 一格宽（不会叠到第 1 列）")
		ok(grid.cell_text_origin(0).x >= UiLayoutRes.TROOP_AVATAR,
			"★ 第 1 列的文字在本格方框右边")
		if grid.cell_count() >= 3:
			eq(grid.cell_text_origin(2).x - grid.cell_text_origin(1).x, UiLayoutRes.TROOP_CELL_W,
				"★ 第 3 列同理：左边 = 第 2 列 + 一格宽")
		eq(grid.cell_text_origin(3).x, grid.cell_text_origin(0).x,
			"★ 换行后回到第 1 列的 x（第 4 格在第 2 行第 1 列）")

	# ---- 框里没有己方单位（非追加）→ 清空选中（与点空地一致）
	main.input_ctrl.box_select(Vector2(0.0, 0.0), Vector2(0.5, 0.5))
	eq(main.input_ctrl.selected_units.size(), 0, "★ 空框 = 清空选中")
	# 空了之后左栏那两段都要收起来
	main.hud.refresh()
	if roster != null and grid != null:
		eq(roster.visible, false, "没选中单位时左栏上半收起来")
		eq(grid.visible, false, "没选中单位时将领头像网格收起来")

	# ---- Shift + 框 = 追加（原来选中的不丢）
	main.input_ctrl.select_units([g1])
	var before_add: int = main.input_ctrl.selected_units.size()
	main.input_ctrl.box_select(lo, hi, true)
	ok(main.input_ctrl.selected_units.has(g1) and main.input_ctrl.selected_units.has(g2),
		"★ Shift + 框 = 追加（两支都在）")
	ok(main.input_ctrl.selected_units.size() >= before_add, "追加不会把原来选中的挤掉")

	# ---- 走**真实事件路径**：按下 → 移动（越过阈值）→ 松手
	#    ★ 位置换算是「视口坐标 ↔ 世界坐标」，用画布变换反算，与游戏里同一条路。
	main.input_ctrl.hover_tile = Vector2i(-1, -1)      # 别让「按下那一下」顺手选中别的东西
	main.input_ctrl.select_units([])
	# 先验「单击那一下用的是事件自己的位置」：把鼠标停在别处，再点在 1 队亲兵身上
	main.input_ctrl.mouse_world = Vector2(0.5, 0.5)
	var some_sub = world.group_of(g1)[1]
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = _world_to_screen(main, some_sub.pos)
	main.input_ctrl.handle_mouse_button(click)
	ok(main.input_ctrl.selected_units.has(g1),
		"★ 左键点击用的是**这次事件**的位置（不是上一帧的鼠标状态）")
	var click_up := InputEventMouseButton.new()
	click_up.button_index = MOUSE_BUTTON_LEFT
	click_up.pressed = false
	click_up.position = click.position
	main.input_ctrl.handle_mouse_button(click_up)

	main.input_ctrl.hover_tile = Vector2i(-1, -1)
	main.input_ctrl.select_units([])
	var a_world := lo
	var b_world := hi
	near(main.input_ctrl._screen_to_logic(_world_to_screen(main, a_world)).x, a_world.x, 0.02,
		"（前提）世界坐标 → 视口坐标 → 世界坐标 能来回换算")
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = _world_to_screen(main, a_world)
	ok(main.input_ctrl.handle_mouse_button(down), "左键按下被处理")
	ok(main.input_ctrl._drag_pending, "按下之后进入「可能是拖框」的待定状态")
	var tiny := InputEventMouseMotion.new()
	tiny.position = down.position + Vector2(2.0, 0.0)
	main.input_ctrl.handle_mouse_motion(tiny)
	ok(not main.input_ctrl.drag_active,
		"★ 只挪了 2px（< ui.drag_select_min_px）→ 还是普通单击，没起框")
	var move := InputEventMouseMotion.new()
	move.position = _world_to_screen(main, b_world)
	main.input_ctrl.handle_mouse_motion(move)
	ok(main.input_ctrl.drag_active, "★ 拖过阈值 → 框选开始（画面上会画那个框）")
	var box: Rect2 = main.input_ctrl.drag_box()
	near(box.position.x, a_world.x, 0.05, "框的起点是按下那一刻的世界坐标")
	ok(box.size.x > 0.0 and box.size.y > 0.0, "框的尺寸跟着鼠标走")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = move.position
	ok(main.input_ctrl.handle_mouse_button(up), "左键抬起被处理（★ 早退会让框永远结束不了）")
	ok(not main.input_ctrl.drag_active, "松手之后框结束")
	eq(_sorted_ids(main.input_ctrl.selected_units), _sorted_keys(expect),
		"★ 走真实事件路径拖出来的框，选中的还是那两支完整部队")

	# Esc：拖到一半放弃，不动已有选中
	main.input_ctrl.handle_mouse_button(down)
	main.input_ctrl.handle_mouse_motion(move)
	ok(main.input_ctrl.drag_active, "（前提）又起了一个框")
	var kept := _sorted_ids(main.input_ctrl.selected_units)
	main.input_ctrl.handle_key(_key(KEY_ESCAPE))
	ok(not main.input_ctrl.drag_active, "★ Esc 放弃这次框选")
	eq(_sorted_ids(main.input_ctrl.selected_units), kept, "★ 放弃框选不会动已有的选中")
	# 收尾：把选中恢复成「1 号将领」并把面板刷一次，别把状态留给后面的用例
	main.input_ctrl.select_units([g1])
	main.hud.refresh()


## 把一组单位摆进某个矩形里（测试用；每个隔开 0.7 格并留出 0.5 格边距，互不重叠）
func _place_units_in_rect(world, units: Array, lo: Vector2, hi: Vector2) -> void:
	var i := 0
	for u in units:
		var col := i % 5
		var row := int(i / 5)
		_place_unit(world, u, lo + Vector2(0.5 + float(col) * 0.7, 0.5 + float(row) * 0.7))
		i += 1


## 把一个单位放到某个世界坐标（格）上，并同步它缓存的地块
func _place_unit(world, u, at: Vector2) -> void:
	u.pos = at
	u.sync_tile(world.map)


## 世界坐标（格）→ 视口坐标（给假鼠标事件用）
func _world_to_screen(main, w: Vector2) -> Vector2:
	return main.input_ctrl.get_viewport().get_canvas_transform() * PaletteRes.to_px(w, main.cfg)


func _sorted_ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(String(u.id))
	out.sort()
	return out


func _sorted_keys(d: Dictionary) -> Array:
	var out: Array = d.keys()
	out.sort()
	return out


# ---- 右栏报的是「玩家点到的那个单位」（手玩第二轮把规则说死了）----
#
# 原话：「默认为左栏展开的那支部队的将领，在地图上通过点击单位选中部队时展示那个单位，
#        如果玩家点击了左栏中展开部队的单位，则切换详情至这个单位，点击其余部队的逻辑亦然」。
#
# ★ 判据是 `input_ctrl.clicked_unit`（**只有地图上一次点选会写它**），
#   不是「选中列表的最后一个」—— 那种判据分不开「点了一个兵」与「框选了一堆」。
func _test_clicked_unit_detail(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	ok(g1 != null, "点选用例：将领 1 在")
	if g1 == null:
		return
	var mates: Array = world.group_of(g1)
	if mates.size() < 2:
		return
	var mate = mates[1]                       # 将领 1 名下的第一个亲兵

	# 1) 地图上点那个**亲兵** → 整队被选中，但右栏报的是这个亲兵
	main.input_ctrl.select_units([])
	main.input_ctrl.mouse_world = mate.pos
	main.input_ctrl.hover_tile = Vector2i(mate.tx, mate.ty)
	main.input_ctrl._on_left_click(false)
	eq(main.input_ctrl.clicked_unit, mate, "★ 地图上点到的那个单位被记下来了")
	ok(main.input_ctrl.selected_units.has(g1), "★ 整队仍然被选中（点一个兵 = 选整队，老行为不变）")
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(mate.name),
		"★ 右栏报的是**玩家点到的那个亲兵**（不是将领）")
	eq(main.hud.detail_panel.roster_control().leader().id, g1.id,
		"★ 左栏上半仍然是那支部队（部队级），不受影响")

	# 2) 框选（拖拽批量选中）→ 右栏退回将领（手玩原话：「当玩家通过拖拽选中部队时，
	#    默认显示该部队的将领」）
	var before: int = main.input_ctrl.selected_units.size()
	main.input_ctrl.box_select(Vector2(0.0, 0.0), Vector2(0.5, 0.5))    # 空框 = 清空
	eq(main.input_ctrl.clicked_unit, null, "★ 框选/清空会把「点到的单位」清掉")
	eq(main.input_ctrl.selection_origin, "drag", "★ 拖拽框选把「怎么选中的」记成 drag")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
		"★ 批量选中（框选 / 点左侧列表）时右栏退回**将领**（不是某个亲兵）")
	ok(before >= 0, "（前一步的选中规模：%d）" % before)

	# 3) 点左栏下半的单位格 → 右栏切到那个单位（且不改选中）
	#    ★ 单选一支时下半网格就是「这支部队的单位」，第 1 格是将领本人
	var roster = main.hud.detail_panel.roster_control()
	var grid = main.hud.detail_panel.grid_control()
	var sel_before: Array = main.input_ctrl.selected_units.duplicate()
	eq(grid.unit_at(1).id, mates[1].id, "（前提）网格第 2 格就是那个亲兵")
	_click_control(grid, UiLayoutRes.troop_cell_rect(1).get_center())
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(mates[1].name),
		"★ 点左栏下半的单位格 → 右栏切到那个单位")
	eq(main.input_ctrl.selection_origin, "click", "★ 点单位格按「单击」那一套走")
	eq(main.input_ctrl.selected_units.size(), sel_before.size(),
		"★ 点单位格**不改选中**（命令发给谁不受影响）")
	ok(roster.visible, "（前提）左栏上半还画着")
	# 点回将领那一格 → 右栏回到将领
	_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
		"★ 点第 1 格（将领）→ 右栏回到将领")

	# 4) 切到别的部队（网格）→ 右栏跟着变成那支部队的将领
	var g2 = world.unit_by_id("general-2")
	if g2 != null:
		var both: Array = []
		both.append_array(world.group_of(g1))
		both.append_array(world.group_of(g2))
		main.input_ctrl.select_units(both)
		main.hud.refresh()
		main.hud._on_troop_activated(2)          # 点网格里那一格（第 2 支部队）
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(g2.name),
			"★ 点其余部队的将领格 → 右栏变成那支部队的将领")

	# 收尾：回到干净状态（后面的用例接着用）
	main.input_ctrl.select_units([g1])
	main.hud.refresh()


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


func _key(code: int, ctrl: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	ev.ctrl_pressed = ctrl
	return ev
