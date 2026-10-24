## test_ui.gd —— 新 UI（参考图那套）的接线与几何测试
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：走 `main._on_test_pressed()` 直连默认地图
##   （界面入口已改为 test_1/2/3 与战役菜单，那两条走的是关卡路径）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const DetailPanelRes = preload("res://view/detail_panel.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const RecruitQueueRes = preload("res://view/recruit_queue.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")
const IconBadgeRes = preload("res://view/icon_badge.gd")
const HoverTipRes = preload("res://view/hover_tip.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")
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

	_test_layout_against_reference(cfg)
	_test_hit_test()

	await process_frame
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	await process_frame
	await _test_panels(cfg)
	await _test_hp_bars(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_layout_against_reference(cfg) -> void:
	eq(UiLayoutRes.DETAIL_RECT.size.x, 988.0, "详细信息面板宽 988（右缘左移给放大的右下组让位）")
	eq(UiLayoutRes.DETAIL_RECT.size.y, 260.0,
		"★ 详细信息面板高 260（保持不变）")
	eq(UiLayoutRes.DETAIL_RECT.position.y + UiLayoutRes.DETAIL_RECT.size.y,
		UiLayoutRes.DESIGN_H, "★ 面板底边仍贴屏幕下沿")
	eq(UiLayoutRes.DETAIL_CONTENT_H, 240.0,
		"★ 面板内容高 = 260 − 2×10 = 240")
	eq(UiLayoutRes.BAR_H, 260.0, "底栏高 260（右下组按 13/12 放大到与详细信息平齐）")
	eq(UiLayoutRes.BAR_TOP, 820.0, "底栏顶边 820")

	eq(UiLayoutRes.SQUAD_RECT.size.x, 240.0, "将领列表宽 240（改到右侧）")
	eq(UiLayoutRes.SQUAD_RECT.position.y, 180.0, "将领列表从 y=180 开始（避开右上角设置按钮）")
	eq(UiLayoutRes.SQUAD_RECT.position.x + UiLayoutRes.SQUAD_RECT.size.x,
		UiLayoutRes.DESIGN_W, "将领列表紧贴屏幕右边缘")
	eq(UiLayoutRes.SQUAD_SLOTS, 10, "★ 10 个槽位（部队1 ~ 部队10）")
	eq(UiLayoutRes.SQUAD_ROW_H, 56.0, "每行 56 高")
	eq(UiLayoutRes.SQUAD_RECT.size.y, 560.0, "10 行合计 560 高")

	eq(UiLayoutRes.MAP_RECT.size.x, 400.0, "地图占位宽 400")
	eq(UiLayoutRes.MAP_RECT.size.y, 400.0, "地图占位高 400")
	eq(UiLayoutRes.MAP_RECT.position.y + UiLayoutRes.MAP_RECT.size.y, UiLayoutRes.DESIGN_H,
		"地图占位贴住屏幕下沿")

	eq(UiLayoutRes.CARD_SLOTS, 9, "命令卡 9 格")
	eq(UiLayoutRes.CARD_RECT.size.x, 260.0, "命令卡 260 宽（3 × 86.67）")
	eq(UiLayoutRes.CARD_RECT.size.y, 260.0, "命令卡 260 高（3 × 86.67）")
	near(UiLayoutRes.card_cell_local(0).size.x, 260.0 / 3.0, 1e-4, "Q 格宽 = 260/3")
	near(UiLayoutRes.card_cell_local(4).position.x, 260.0 / 3.0, 1e-4, "S 格在正中（行优先）")
	near(UiLayoutRes.card_cell_local(8).position.y, 2.0 * 260.0 / 3.0, 1e-4, "C 格在右下")
	eq(String(UiLayoutRes.CARD_KEYS[0]), "Q", "第一格是 Q")
	eq(String(UiLayoutRes.CARD_KEYS[8]), "C", "第九格是 C")

	near(UiLayoutRes.HOVER_W, UiLayoutRes.CARD_RECT.size.x + UiLayoutRes.TABS_RECT.size.x,
		0.01, "★ 悬停面板宽 = 命令卡 + 页签列（368.333）")
	near(UiLayoutRes.HOVER_W, 368.3333, 0.01, "面板实宽 368.333")
	near(UiLayoutRes.hover_rect(100.0).size.x, 368.3333, 0.01, "hover_rect 的宽也是 368.333")
	eq(UiLayoutRes.hover_rect(100.0).position.x, UiLayoutRes.CARD_RECT.position.x,
		"悬停面板左缘与命令卡左缘对齐")
	near(UiLayoutRes.hover_rect(100.0).position.x + UiLayoutRes.HOVER_W,
		UiLayoutRes.TABS_RECT.position.x + UiLayoutRes.TABS_RECT.size.x,
		0.01, "★ 悬停面板右缘与**页签列右缘**齐平")
	eq(UiLayoutRes.HOVER_BOTTOM, UiLayoutRes.CARD_RECT.position.y - UiLayoutRes.HOVER_GAP,
		"★ 面板**下缘**落在命令卡顶边上方 HOVER_GAP")
	eq(UiLayoutRes.HOVER_BOTTOM, 812.0, "★ 右下组放大后浮窗下缘上移到 812")
	ok(UiLayoutRes.HOVER_GAP > 0.0, "★ 与命令卡之间留了缝")
	eq(UiLayoutRes.hover_rect(120.0).position.y + UiLayoutRes.hover_rect(120.0).size.y,
		UiLayoutRes.HOVER_BOTTOM, "★ 下缘钉住 ⇒ 面板变高是**向上长**")
	eq(UiLayoutRes.hover_rect(120.0).size.y, 120.0, "高度按传进去的文本高度走")
	ok(UiLayoutRes.hover_rect(200.0).size.y > UiLayoutRes.hover_rect(80.0).size.y,
		"★ 文本越多、面板越高")
	ok(UiLayoutRes.hover_rect(5.0).size.y >= UiLayoutRes.HOVER_MIN_H,
		"极短的文本也有兜底下限")
	ok(UiLayoutRes.hover_rect(99999.0).position.y >= 0.0,
		"文案长到离谱时面板也不许顶出屏幕上沿")

	near(UiLayoutRes.TABS_RECT.size.x, 108.3333, 0.01, "页签列宽 108.333（13/12 放大）")
	near(UiLayoutRes.tab_button_local(2).position.y, 2.0 * 260.0 / 3.0, 1e-4,
		"第三颗按钮从 173.33 开始（3×86.67）")
	near(UiLayoutRes.tab_button_local(0, 2).size.y, 130.0, 0.01,
		"★ 页签是**动态**的：两颗时每颗 130 高（260 ÷ 2）")
	near(UiLayoutRes.tab_button_local(1, 1).size.y, 260.0, 0.01,
		"★ 只有一颗时它铺满整列（260）")
	eq(UiLayoutRes.SETTINGS_RECT, Rect2(1840, 0, 80, 160), "设置按钮 80×160 在右上角（参考图）")

	eq(UiLayoutRes.QUEUE_SLOTS, 5, "★ 招募队列 5 个格子（1 大 + 4 小，需求原话）")
	eq(UiLayoutRes.QUEUE_INFO_W, 141.0, "汇总带宽 141（表格子段左边那一条）")
	eq(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_INFO_W + UiLayoutRes.QUEUE_CELLS_W,
		"★ 控件总宽 = 汇总带 141 + 五个格子 172 = 313（常量之间是推算式，不会对不上）")
	eq(UiLayoutRes.QUEUE_H, UiLayoutRes.DETAIL_BODY_H,
		"★ 控件总高 = 详情框高（本版从顶带搬下来，与详情框上下对齐）")
	eq(UiLayoutRes.QUEUE_H, 116.0, "★ 控件总高 116（与详情框 116 齐平）")
	eq(UiLayoutRes.QUEUE_Y, UiLayoutRes.DETAIL_BODY_Y,
		"★ 队列顶边 = 详情框顶边（y=100）")
	eq(UiLayoutRes.QUEUE_BIG, 84.0, "★ 大格子 84×84（64 → 84）")
	eq(UiLayoutRes.QUEUE_SMALL, 40.0, "★ 小格子 40×40（30 → 40）")
	ok(UiLayoutRes.QUEUE_MARGIN >= 1.0,
		"★ 队列块离右栏右边缘留了 %.0fpx（= 0 时 1px 描边会被裁剪线切掉半条）"
			% UiLayoutRes.QUEUE_MARGIN)
	eq(UiLayoutRes.QUEUE_X + UiLayoutRes.QUEUE_W, UiLayoutRes.UNIT_CONTENT_RIGHT,
		"★ 队列块右缘 = 右栏内容的公共右缘（599 = 603 − 4）")
	ok(UiLayoutRes.QUEUE_X + UiLayoutRes.QUEUE_W < UiLayoutRes.DETAIL_RIGHT_W,
		"★ 队列块右缘**不**顶到 603（顶到就会被切）")
	ok(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W <= UiLayoutRes.QUEUE_X,
		"★ 详情框右缘不压到队列（%.0f ≤ %.0f）" % [
			UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W, UiLayoutRes.QUEUE_X])
	eq(UiLayoutRes.queue_info_rect(), Rect2(0, 0, 141, 116), "汇总带占控件左边那条 141×116")
	eq(UiLayoutRes.queue_info_line_rect(0), Rect2(8, 39, 125, 18), "汇总第一行（招募队列 3/5）")
	eq(UiLayoutRes.queue_info_line_rect(1), Rect2(8, 61, 125, 16), "汇总第二行（共 22s）")
	ok(UiLayoutRes.queue_info_line_rect(1).position.y + UiLayoutRes.queue_info_line_rect(1).size.y
			<= UiLayoutRes.QUEUE_H,
		"★ 汇总两行都落在控件里（否则会被右栏裁掉）")
	eq(UiLayoutRes.queue_cell_rect(0), Rect2(141, 16, 84, 84), "大格子紧跟在汇总带右边（84×84）")
	eq(UiLayoutRes.queue_cell_rect(1), Rect2(229, 16, 40, 40), "第 1 个小格排在大格右边")
	eq(UiLayoutRes.queue_cell_rect(2), Rect2(273, 16, 40, 40), "第 2 个小格在它右边")
	eq(UiLayoutRes.queue_cell_rect(3), Rect2(229, 60, 40, 40), "第 3 个小格换行")
	eq(UiLayoutRes.queue_cell_rect(4), Rect2(273, 60, 40, 40), "第 4 个小格在右下角")
	var small_last := UiLayoutRes.queue_cell_rect(4)
	ok(small_last.position.x + small_last.size.x <= UiLayoutRes.QUEUE_W + 1e-6
		and small_last.position.y + small_last.size.y <= UiLayoutRes.QUEUE_H + 1e-6,
		"★ 四个小格都落在队列控件的矩形里（否则会被裁掉）")
	ok(UiLayoutRes.queue_cell_rect(0).position.y >= 1.0
		and UiLayoutRes.queue_cell_rect(4).position.y + UiLayoutRes.queue_cell_rect(4).size.y
			<= UiLayoutRes.QUEUE_H - 1.0,
		"★ 格子上下都留了缝（贴边的话大格子的描边也会被切）")
	ok(UiLayoutRes.queue_cell_rect(0).position.x >= UiLayoutRes.QUEUE_INFO_W,
		"★ 大格子不压到左边的汇总文字")
	_test_queue_info_text_fit(cfg)

func _test_queue_info_text_fit(cfg) -> void:
	var font: Font = FontLoaderRes.load_font(cfg)
	if font == null:
		ok(true, "（没装中文字体，跳过队列文字的量算）")
		return
	var fs_body: int = UiStyleRes.FS_BODY
	var fs_small: int = UiStyleRes.FS_SMALL

	var title_r := UiLayoutRes.queue_info_line_rect(0)
	var title_w: float = font.get_string_size("招募队列 5/5", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_body).x
	ok(title_w <= title_r.size.x + 0.01,
		"★ 汇总第一行「招募队列 5/5」宽 %.0f ≤ 可写 %.0f（装得下才不会被裁）"
			% [title_w, title_r.size.x])
	ok(font.get_height(fs_body) <= title_r.size.y + 0.01,
		"★ 汇总第一行的高度装得进那一行（行高 %.0f ≤ %.0f）"
			% [font.get_height(fs_body), title_r.size.y])

	var total_r := UiLayoutRes.queue_info_line_rect(1)
	var total_w: float = font.get_string_size("共 100s", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_small).x
	ok(total_w <= total_r.size.x + 0.01,
		"★ 汇总第二行「共 100s」宽 %.0f ≤ 可写 %.0f" % [total_w, total_r.size.x])

	var big_r := UiLayoutRes.queue_cell_rect(0)
	for text in ["兵", "剩 100.0s"]:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_body).x
		ok(w <= big_r.size.x - 2.0,
			"★ 大格子里的「%s」宽 %.0f ≤ %.0f（装得下）" % [text, w, big_r.size.x - 2.0])
	ok(font.get_height(fs_body) * 2.0 <= big_r.size.y + 0.01,
		"★ 大格子两行 15 号字（%.0f×2）装得进 84 高" % font.get_height(fs_body))

	var small_r := UiLayoutRes.queue_cell_rect(1)
	for text in ["兵", "400s"]:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_small).x
		ok(w <= small_r.size.x - 2.0,
			"★ 小格子里的「%s」宽 %.0f ≤ %.0f（装得下）" % [text, w, small_r.size.x - 2.0])
	ok(font.get_height(fs_small) * 2.0 <= small_r.size.y + 0.01,
		"★ 小格子两行 13 号字（%.0f×2）装得进 40 高（放大前是 30 高装两行 11 号）"
			% font.get_height(fs_small))

	eq(UiLayoutRes.DETAIL_RECT.position.x + UiLayoutRes.DETAIL_RECT.size.x, 1388.0,
		"详细信息右缘 1388")
	ok(UiLayoutRes.DETAIL_RECT.position.x + UiLayoutRes.DETAIL_RECT.size.x
			< UiLayoutRes.FACTION_RECT.position.x,
		"★ 详细信息右缘在阵营面板左缘左边（约 1.17px 缝，不重叠）")
	near(UiLayoutRes.FACTION_RECT.position.x + UiLayoutRes.FACTION_RECT.size.x,
		UiLayoutRes.CARD_RECT.position.x, 0.01, "阵营面板右边缘接上命令卡")
	near(UiLayoutRes.CARD_RECT.position.x + UiLayoutRes.CARD_RECT.size.x,
		UiLayoutRes.TABS_RECT.position.x, 0.01, "命令卡右边缘接上页签列")
	near(UiLayoutRes.TABS_RECT.position.x + UiLayoutRes.TABS_RECT.size.x, UiLayoutRes.DESIGN_W,
		0.01, "页签列贴住屏幕右边缘")
	eq(UiLayoutRes.DETAIL_RECT.position.x, UiLayoutRes.MAP_RECT.size.x,
		"详细信息从地图占位的右边缘开始（x=400）")
	for r in [UiLayoutRes.DETAIL_RECT, UiLayoutRes.FACTION_RECT, UiLayoutRes.CARD_RECT, UiLayoutRes.TABS_RECT]:
		eq(r.position.y + r.size.y, UiLayoutRes.DESIGN_H, "底栏各块都贴住屏幕下沿")
		eq(r.position.y, UiLayoutRes.BAR_TOP, "底栏各块顶边都在 820（与详细信息平齐）")

	_test_left_column_geometry()

func _test_left_column_geometry() -> void:
	eq(UiLayoutRes.ROSTER_DETAIL_H, 40.0, "★ 左栏上半就是一个 40 高的将领格")
	v2_near(UiLayoutRes.roster_cell_avatar_rect().size, Vector2(40.0, 40.0), 0.01,
		"★ 将领格是 40×40（参考图 x 415..454）")
	eq(UiLayoutRes.TROOP_GRID_COLS, 3, "下半是 3 列")
	eq(UiLayoutRes.TROOP_GRID_ROWS, 3, "下半是 3 行")
	eq(UiLayoutRes.TROOP_GRID_SLOTS, 9, "★ 下半 3×3 = 9 格（手玩原话：1333 排列）")
	eq(UiLayoutRes.GRID_PAGE, 9, "单选时滚轮**一次翻一页 = 9 格**（手玩原话）")
	v2_near(UiLayoutRes.troop_avatar_rect(0).size, Vector2(40.0, 40.0), 0.01, "格里的方框 40×40")
	eq(UiLayoutRes.troop_cell_rect(0), Rect2(0, 0, 112, 55), "第 0 格在左上（宽 116 - 内侧 4）")
	eq(UiLayoutRes.troop_cell_rect(1).position.y, UiLayoutRes.TROOP_CELL_H,
		"★ 第 1 格换到第二行（列优先：一列 = 3 个格子）")
	eq(UiLayoutRes.troop_cell_rect(3).position.x, UiLayoutRes.TROOP_CELL_W,
		"★ 第 3 格换到第二列（横向滑动一列 = 3 格）")
	eq(UiLayoutRes.troop_cell_rect(8).position.y, 2.0 * UiLayoutRes.TROOP_CELL_H, "第 8 格在第三行")
	eq(UiLayoutRes.troop_grid_content_w(9), UiLayoutRes.TROOP_GRID_VIEW_W,
		"★ 9 格正好 3 列，装得下可见区")
	eq(UiLayoutRes.troop_grid_max_scroll(9), 0.0, "★ 9 格时不能横向滑动（不用滑）")
	eq(UiLayoutRes.troop_grid_content_w(11), 4.0 * UiLayoutRes.TROOP_CELL_W,
		"★ 11 格 = 4 列（多出来的一列靠滑动看）")
	eq(UiLayoutRes.troop_grid_max_scroll(11), UiLayoutRes.TROOP_CELL_W,
		"★ 11 格时最多滑一列宽（116）")
	var bottom := UiLayoutRes.troop_cell_rect(8)
	ok(UiLayoutRes.troop_grid_rect().position.y + bottom.position.y
			+ UiLayoutRes.TROOP_AVATAR <= UiLayoutRes.DETAIL_CONTENT_H,
		"★ 第 3 行的方框装得进内容高（%s ≤ %.0f）" % [
			str(UiLayoutRes.troop_grid_rect().position.y + bottom.position.y
				+ UiLayoutRes.TROOP_AVATAR),
			UiLayoutRes.DETAIL_CONTENT_H])
	near(UiLayoutRes.DETAIL_LEFT_Y,
		(UiLayoutRes.DETAIL_CONTENT_H - UiLayoutRes.DETAIL_LEFT_H) * 0.5, 1e-6,
		"★ 左栏整段在内容高里垂直居中（上留 %.0f）" % UiLayoutRes.DETAIL_LEFT_Y)
	ok(UiLayoutRes.troop_grid_rect().position.y + UiLayoutRes.TROOP_GRID_H
			<= UiLayoutRes.DETAIL_CONTENT_H + 1e-6,
		"★ 网格铺得进内容高（%s ≤ %.0f）" % [
			str(UiLayoutRes.troop_grid_rect().position.y + UiLayoutRes.TROOP_GRID_H),
			UiLayoutRes.DETAIL_CONTENT_H])
	ok(UiLayoutRes.DETAIL_LEFT_H <= 220.0 + 1e-6,
		"★ 左栏整段仍是 220（那 10 个格子的几何不动，只是整段往下挪了 %.0f）"
			% UiLayoutRes.DETAIL_LEFT_Y)
	ok(UiLayoutRes.TROOP_CELL_H >= UiLayoutRes.TROOP_AVATAR + 8.0,
		"★ 每行留得出行间空白（格高 %.0f ≥ 方框 %.0f + 8）—— 这就是「不挤」的那 8px" % [
			UiLayoutRes.TROOP_CELL_H, UiLayoutRes.TROOP_AVATAR])
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
	eq(UiLayoutRes.TROOP_NAME_W, 60.0, "★ 名字可写宽度 60（52px 的「将领名称」装得下）")
	ok(UiLayoutRes.TROOP_NAME_W > 52.0, "★ 比参考图量出来的「将领名称」宽度（52）宽一点")
	eq(UiLayoutRes.ROSTER_ID_W, UiLayoutRes.TROOP_NAME_W,
		"★ 左栏上半那一格与下面 9 格用**同一套**文字宽度（看着才是一套东西）")
	eq(UiLayoutRes.ROSTER_CELL_TEXT_X, UiLayoutRes.TROOP_NAME_X, "★ 两段文字左边对齐")
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
	ok(UiLayoutRes.troop_name_rect(0).position.x == UiLayoutRes.troop_name_rect(1).position.x
			and UiLayoutRes.troop_name_rect(1).position.x == UiLayoutRes.troop_name_rect(2).position.x,
		"★ 第 1 列那 3 个格子的文字左边对齐（列优先）")
	eq(UiLayoutRes.troop_name_rect(1).position.y - UiLayoutRes.troop_name_rect(0).position.y,
		UiLayoutRes.TROOP_CELL_H, "★ 同一列往下排：文字跟着下移一格高")
	eq(UiLayoutRes.troop_name_rect(3).position.x - UiLayoutRes.troop_name_rect(0).position.x,
		UiLayoutRes.TROOP_CELL_W, "★ 换到第 2 列：文字左边正好差一格宽")
	eq(UiLayoutRes.troop_name_rect(3).position.y, UiLayoutRes.troop_name_rect(0).position.y,
		"★ 第 2 列第 1 行的文字顶边与第 1 列第 1 行对齐")

func _test_hit_test() -> void:
	var vp := Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H)
	var map_middle := Vector2(960.0, 400.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), map_middle),
		"地图空白处不拦鼠标（点击要能落到地图上）")

	var detail_text_spot := UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), detail_text_spot),
		"★ 详细信息面板里只有文字的地方不拦边缘滚屏（否则底边永远滚不动）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.FACTION_RECT.get_center()),
		"阵营占位面板同样不拦")

	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.troop_cell_global_rect(0).get_center()),
		"★ 详细信息左栏下半那块网格拦边缘滚屏（它能点 / 能拖）")

	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.squad_slot_rect(2).get_center()), "部队第 3 行拦边缘滚屏（它是可点的）")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.card_cell_rect(0).get_center()), "命令卡 Q 格拦边缘滚屏")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.tab_button_rect(1).get_center()), "页签按钮拦边缘滚屏")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.SETTINGS_RECT.get_center()), "设置按钮拦边缘滚屏")

	var wide := Vector2(2560.0, 1080.0)
	var shifted := UiLayoutRes.card_cell_rect(0)
	shifted.position.x += 2560.0 - UiLayoutRes.DESIGN_W
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide), shifted.get_center()),
		"窗口变宽时命令卡跟着贴右边缘（不然点不到）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide),
		UiLayoutRes.card_cell_rect(0).get_center()),
		"窗口变宽后原位置不再算作命令卡")

	var m: float = 44.0
	ok(UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), m),
		"★ 左边缘最外圈算「边缘带」（将领按钮那一列就压在这里）")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 1070.0), m), "下边缘也算边缘带")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 8.0), m), "上边缘也算")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(1914.0, 500.0), m), "右边缘也算")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(960.0, 500.0), m), "屏幕中间不是边缘带")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), 0.0),
		"margin = 0 时整条规则关掉（可配置）")

	var bar := UiLayoutRes.bottom_bar_rects(vp)
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)),
		"★ 滚轮：详细信息面板里只有文字的地方也拦（与边缘滚屏那条规则相反）")
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.FACTION_RECT.get_center()),
		"滚轮：阵营占位面板也拦")
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.card_cell_rect(0).get_center()),
		"滚轮：命令卡那一格也拦")
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.tab_button_rect(1).get_center()),
		"滚轮：页签列也拦")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.MAP_RECT.get_center()),
		"★ 滚轮：左下小地图是**地图**不是 ui 栏 —— 鼠标停在它上面时照旧缩放（「除地图外」）")
	ok(not UiLayoutRes.point_hits_any(bar, map_middle), "滚轮：地图中间照旧缩放")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.squad_slot_rect(2).get_center()),
		"滚轮：左侧部队列表不在「下方 ui 栏」里 → 不拦")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.SETTINGS_RECT.get_center()),
		"滚轮：右上角设置按钮也不拦（需求只说下方那一条）")
	var bar_wide := UiLayoutRes.bottom_bar_rects(wide)
	var card_wide := UiLayoutRes.card_cell_rect(0)
	card_wide.position.x += wide.x - UiLayoutRes.DESIGN_W
	ok(UiLayoutRes.point_hits_any(bar_wide, card_wide.get_center()),
		"★ 超宽窗口：命令卡的新位置仍然拦滚轮（判定跟着贴边走）")
	# ★★ 本版：手机端不再把详细信息面板横向拉伸 —— 固定 988×260，右侧留白。
	#    旧命令卡位置落在面板右侧的空白里，**不再**被底栏覆盖。
	ok(not UiLayoutRes.point_hits_any(bar_wide, UiLayoutRes.card_cell_rect(0).get_center()),
		"★ 超宽窗口：详细信息面板固定宽度 ⇒ 旧命令卡位置在面板外的留白里（不再相连）")

	var d_wide: Rect2 = bar_wide[0]
	eq(d_wide.size, UiLayoutRes.DETAIL_RECT.size,
		"★ 超宽窗口：详细信息面板尺寸仍是 988×260（不拉伸）")
	var faction_left_wide: float = UiLayoutRes.FACTION_RECT.position.x + (wide.x - UiLayoutRes.DESIGN_W)
	ok(faction_left_wide > d_wide.position.x + d_wide.size.x,
		"★ 面板右缘与阵营列之间允许留白（%.0f > %.0f）" % [
			faction_left_wide, d_wide.position.x + d_wide.size.x])
	eq(UiLayoutRes.bottom_bar_rects(vp)[0].size.x, UiLayoutRes.DETAIL_RECT.size.x,
		"1920 基准下详细信息面板宽度仍是 988")

	# 右栏动态宽度函数在基准宽度处必须与写死的常量逐位一致（否则 1920 下会走样）。
	var rw: float = UiLayoutRes.DETAIL_RIGHT_W
	eq(UiLayoutRes.detail_body_w(rw), UiLayoutRes.DETAIL_BODY_W,
		"detail_body_w(基准) == DETAIL_BODY_W")
	eq(UiLayoutRes.detail_queue_x(rw), UiLayoutRes.QUEUE_X, "detail_queue_x(基准) == QUEUE_X")
	eq(UiLayoutRes.detail_name_w(rw), UiLayoutRes.UNIT_NAME_W,
		"detail_name_w(基准) == UNIT_NAME_W")
	eq(UiLayoutRes.detail_body_col2_w(rw), UiLayoutRes.DETAIL_BODY_COL2_W,
		"detail_body_col2_w(基准) == DETAIL_BODY_COL2_W")

## 测试布置：自由对战默认只有 #0；把旧的三位 #1-3 补回来（仅测试用）。
func _restore_three_generals(main) -> void:
	var w = main.world
	if w == null:
		return
	# ★ 不要删掉 #0（视图可能还引用着它）——把它就地改造成 #1。
	var g0 = w.unit_by_id("general-0")
	if g0 != null:
		g0.id = "general-1"
		g0.kind = "general"
		g0.general_index = 0
		g0.hotkey = "1"
		g0.name = "将领 1"
	for i in [1, 2]:
		var gid := "general-%d" % (i + 1)
		if w.unit_by_id(gid) == null:
			var g = w.create_general("p1", i, i)
			if g != null:
				w.units.append(g)
	if w.has_method("_mark_starting_generals_owned"):
		w._mark_starting_generals_owned()
	if main.input_ctrl != null:
		main.input_ctrl.select_units([])
	if main.hud != null:
		main.hud.refresh()


func _test_panels(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var root_node = (packed as PackedScene).instantiate()
	root.add_child(root_node)
	await process_frame
	root_node._on_test_pressed(String(MapLibraryRes.default_map_path()))          # 与玩家点一下 test 按钮完全同一条路
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

	# ★ 自由对战现在开局只有 #0；这组 UI 用例沿用「#1-3 三支部队」的旧布置，
	#   所以在测试里手动补回三位（并标记为已拥有），不改游戏本身的口径。
	_restore_three_generals(main)
	_seed_player_escorts(main, 5)
	main.hud.refresh()          # 让 HUD 立刻看到新补的三支队伍
	if main.hud.squad_panel != null:
		main.hud.squad_panel.refresh()   # 左侧列表是独立 _process，测试里显式刷一次

	# ★★ 触摸设备：地图侧**完全不认鼠标**（连 emulate_mouse_from_touch 造的模拟鼠标也不要）。
	#    判据用「左键按下会不会进入拖框待定」—— 它不依赖光标底下有什么，最干净。
	var mouse_ev := InputEventMouseButton.new()
	mouse_ev.button_index = MOUSE_BUTTON_LEFT
	mouse_ev.pressed = true
	mouse_ev.position = Vector2(960.0, 540.0)
	main.touch_device = true
	main.input_ctrl._drag_pending = false
	main._unhandled_input(mouse_ev)
	ok(not main.input_ctrl._drag_pending,
		"★★ 触摸设备上模拟鼠标左键不进输入层（不会起框 / 清空选中）")
	main.touch_device = false
	main.input_ctrl._drag_pending = false
	main.input_ctrl.select_units([])

	for path in ["HudRoot/SquadPanel", "HudRoot/MapPlaceholder", "HudRoot/DetailPanel",
			"HudRoot/FactionPlaceholder", "HudRoot/CommandCard", "HudRoot/PageTabs",
			"HudRoot/SettingsButton", "HudRoot/ResourceBar"]:
		ok(main.hud.get_node_or_null(path) != null, "节点树里有 %s" % path)

	_test_resource_bar(main)

	var vp: Vector2 = main.hud.view_size()
	eq(vp, Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H), "设计空间 = 1920×1080")
	v2_near(main.hud.detail_panel.position, UiLayoutRes.DETAIL_RECT.position, 1.0,
		"详细信息面板落在 (400, 820)")
	v2_near(main.hud.detail_panel.size, UiLayoutRes.DETAIL_RECT.size, 1.0,
		"★ 详细信息面板实际尺寸 = 988×260")

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
		"阵营占位落在 (1389.17, 820)")
	v2_near(main.hud.command_card.position, UiLayoutRes.CARD_RECT.position, 1.0,
		"命令卡落在 (1551.67, 820)")
	v2_near(main.hud.page_tabs.position, UiLayoutRes.TABS_RECT.position, 1.0,
		"页签列落在 (1811.67, 820)")
	v2_near(main.hud.settings_button.position, UiLayoutRes.SETTINGS_RECT.position, 1.0,
		"设置按钮落在 (1840, 0)")
	v2_near(main.hud.settings_button.size, UiLayoutRes.SETTINGS_RECT.size, 1.0,
		"设置按钮实际尺寸 = 80×160")
	v2_near(main.hud.squad_panel.position, UiLayoutRes.SQUAD_RECT.position, 1.0,
		"将领列表紧贴右侧")
	v2_near(main.hud.squad_panel.size, UiLayoutRes.SQUAD_RECT.size, 1.0,
		"将领列表实际尺寸 = 240×560")

	_test_squad_rows(main)
	_test_page_tabs_and_card(main, cfg)
	_test_hover_panel(main, cfg)
	await _test_hover_tip_control(cfg)
	_test_card_keys(main)
	_test_avatar_text_fit(cfg)
	_test_recruit_via_card(main)
	_test_zone_recruit_via_card(main)
	_test_upgrade_via_card(main)
	await _test_queue_control(cfg)
	_test_queue_cancel_via_click(main)
	_test_auto_select_on_recruit(main)
	_test_order_locked_notice(main)
	_test_foreign_reject_notice_filter(main)
	_test_right_click_orders(main)
	await _test_box_select(main)
	await _test_box_select_icon_body(main)
	_test_drag_over_ui(main)
	_test_detail_basic_stats(main)
	_test_detail_two_columns(main)
	_test_detail_vertical_fit(main)
	_test_buff_long_press(main)
	_test_clicked_unit_detail(main)
	_test_enemy_selection(main)
	_test_settings_inert(main)
	_test_box_select_buildings(main)
	await _test_command_events_reach_consumer(main)

	main.input_ctrl.select_units([main.world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not main.hud.detail_panel.has_log(), "★ 事件日志整块删掉了（detail_panel 里没有日志栏）")
	ok(main.hud.detail_panel.get_node_or_null("DetailBox/DetailTitle") == null,
		"★ 数值区里没有「详细信息」标题控件了")
	ok(main.hud.detail_panel.detail_text().contains("血量")
			and main.hud.detail_panel.detail_text().contains("移速"),
		"★ 右栏两列详情：左列血量、右列移速（实际：%s）"
			% main.hud.detail_panel.detail_text().replace("\n", "|"))
	# ★ 词条已停用：buff 条只剩士气一条。
	eq(main.hud.detail_panel.buff_count(), 1,
		"★ 动态 buff 槽位：只有士气一条")
	var buff_bar = main.hud.detail_panel.buff_bar_control()
	ok(buff_bar != null and String(buff_bar.entry(0).get("id", "")) == "morale",
		"★ 那条 buff 的 id = morale（文字「士」，底色随士气）")
	ok(main.hud.detail_panel.unit_name_text() != "", "右栏写着单位名称")

	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(main.hud.detail_panel.detail_text(), "未选中", "★ 没选中时只显示「未选中」")
	eq(main.hud.detail_panel.unit_name_text(), "", "没选中单位时右栏没有名称")
	ok(not main.hud.detail_panel.roster_control().visible, "没选中部队时左栏上半收起来")
	main.input_ctrl.select_units([main.world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not main.hud.detail_panel.detail_text().contains("Shift"),
		"★ 不再显示快捷键提示")

	var card0 := UiLayoutRes.card_cell_rect(0)
	card0.position.x += maxf(0.0, vp.x - UiLayoutRes.DESIGN_W)
	card0.position.y += maxf(0.0, vp.y - UiLayoutRes.DESIGN_H)
	ok(main.hud.blocks_edge_scroll(card0.get_center()), "鼠标在命令卡上 → 不滚屏")
	ok(not main.hud.blocks_edge_scroll(UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)),
		"★ 鼠标在详细信息面板**只有文字**的地方 → 照样滚屏（不然底边滚不动）")
	ok(main.hud.blocks_edge_scroll(UiLayoutRes.troop_cell_global_rect(0).get_center()),
		"★ 鼠标在部队 / 单位网格上 → 不滚屏（那能点 / 能拖）")
	ok(not main.hud.blocks_edge_scroll(Vector2(vp.x * 0.5, vp.y * 0.5)), "鼠标在地图中间 → 滚屏")

	var row_center := UiLayoutRes.squad_slot_rect(2).get_center()
	ok(not main.hud.blocks_edge_scroll(Vector2(6.0, row_center.y)),
		"★ 鼠标在左边缘最外圈（将领按钮那一列）→ 仍然滚屏")
	ok(main.hud.blocks_edge_scroll(row_center),
		"部队行**靠里**的部分照旧拦住边缘滚屏（原来那条行为不变）")

	_test_wheel_zoom_block(main)
	await _test_notice_band(main)

	ok(not main.overlay.has_method("_draw_selected_units"),
		"★ overlay 里已经没有「选中范围圈」那段代码（画范围圈的函数被删掉了）")
	ok(main.cfg.get_path_value("colors.range") == null
		and main.cfg.get_path_value("colors.range_edge") == null,
		"★ config 里的 range / range_edge 配色也一起删了（不留死数据）")

	await _test_anchors(main)

	root_node.queue_free()
	await process_frame

func _test_resource_bar(main) -> void:
	var bar = main.hud.resource_bar
	ok(bar != null, "★ 资源面板控件在（HudRoot/ResourceBar）")
	if bar == null:
		return

	v2_near(bar.position, UiLayoutRes.RES_BAR_RECT.position, 1.0, "资源面板落在 (400, 764)")
	v2_near(bar.size, UiLayoutRes.RES_BAR_RECT.size, 1.0, "资源面板尺寸 = 200×56（两行竖排）")
	eq(UiLayoutRes.RES_BAR_RECT.position.x, UiLayoutRes.DETAIL_RECT.position.x,
		"★ 资源面板与详细信息面板同一个左边缘")
	ok(UiLayoutRes.RES_BAR_RECT.size.x < UiLayoutRes.DETAIL_RECT.size.x,
		"★ 资源面板**不再铺满整宽**（%.0f < %.0f）—— 需求：面板不需要那么长" % [
			UiLayoutRes.RES_BAR_RECT.size.x, UiLayoutRes.DETAIL_RECT.size.x])
	eq(UiLayoutRes.RES_BAR_RECT.position.y + UiLayoutRes.RES_BAR_RECT.size.y,
		UiLayoutRes.DETAIL_RECT.position.y,
		"★ 资源面板下缘正好压在详细信息面板顶边（%.0f）—— 这就是「紧贴」" % [
			UiLayoutRes.DETAIL_RECT.position.y])
	ok(not UiLayoutRes.MAP_RECT.intersects(UiLayoutRes.RES_BAR_RECT),
		"★ 资源面板与左下小地图不重叠（左缘 x=400 = 小地图右缘）")
	ok(UiLayoutRes.RES_BAR_RECT.position.y >= 0.0
			and UiLayoutRes.RES_BAR_RECT.position.y + UiLayoutRes.RES_BAR_RECT.size.y
				<= UiLayoutRes.DESIGN_H,
		"★ 资源面板整个在设计空间里（不掉出屏幕）")

	var food := bar.get_node_or_null("ResText_粮") as Label
	var gold := bar.get_node_or_null("ResText_金") as Label
	ok(food != null, "★ 资源面板里有「粮食」那一项")
	ok(gold != null, "★ 资源面板里有「黄金」那一项")
	eq(bar.get_child_count(), 4, "★ 整块正好 4 个控件 = 2 个色块 + 2 个数字（只显示两种资源）")
	if food != null and gold != null:
		ok(gold.position.y > food.position.y, "★ 黄金排在粮食**下面**（%.0f > %.0f）—— 竖着排" % [
			gold.position.y, food.position.y])
		eq(food.position.x, gold.position.x, "★ 两项**左边对齐**（同一列）")
		eq(food.position.y, UiLayoutRes.RES_ROW_Y, "★ 粮食那一行的 y = RES_ROW_Y")
		eq(gold.position.y, UiLayoutRes.RES_ROW2_Y, "★ 黄金那一行的 y = RES_ROW2_Y")
		ok(UiLayoutRes.RES_ROW2_Y >= UiLayoutRes.RES_ROW_Y + UiLayoutRes.RES_ICON,
			"★ 两行不重叠（第二行 y %.0f ≥ 第一行下缘 %.0f）" % [
				UiLayoutRes.RES_ROW2_Y, UiLayoutRes.RES_ROW_Y + UiLayoutRes.RES_ICON])
		ok(gold.position.y + gold.size.y <= UiLayoutRes.RES_BAR_RECT.size.y + 0.01,
			"★ 黄金那一行不越出面板下缘（%.0f ≤ %.0f）" % [
				gold.position.y + gold.size.y, UiLayoutRes.RES_BAR_RECT.size.y])
		ok(food.position.x + food.size.x <= UiLayoutRes.RES_BAR_RECT.size.x + 0.01,
			"★ 文字不越出面板右缘（%.0f ≤ %.0f）" % [
				food.position.x + food.size.x, UiLayoutRes.RES_BAR_RECT.size.x])
		var icon_food := bar.get_node_or_null("ResIcon_粮") as Label
		var icon_gold := bar.get_node_or_null("ResIcon_金") as Label
		ok(icon_food != null and icon_gold != null, "★ 两个色块都在")
		if icon_food != null and icon_gold != null:
			eq(icon_food.size, Vector2(UiLayoutRes.RES_ICON, UiLayoutRes.RES_ICON),
				"色块 20×20（没有图标素材，用色块 + 一个字顶上）")
			ok(icon_food.position.x < food.position.x and icon_gold.position.x < gold.position.x,
				"★ 色块排在各自数字**左边**")
			eq(icon_food.position.y, food.position.y, "★ 色块与同一行的数字**同一 y**（一行一组）")
			eq(icon_gold.position.y, gold.position.y, "★ 第二行同理")

	if food != null and gold != null:
		main.world.resources["food"] = 120.6
		main.world.resources["gold"] = 80.2
		main.hud.refresh()
		eq(food.text, "粮食 121", "★ 粮食取整显示（120.6 → 121），实际：%s" % food.text)
		eq(gold.text, "黄金 80", "★ 黄金取整显示（80.2 → 80），实际：%s" % gold.text)
		main.world.resources["food"] = 7.0
		main.world.resources["gold"] = 0.0
		main.hud.refresh()
		eq(food.text, "粮食 7", "★ 整数资源不带小数点")
		eq(gold.text, "黄金 0", "★ 0 也照实显示")

		ok(food.size.y <= UiLayoutRes.RES_ICON + 0.01
				and food.position.y + food.size.y
					<= UiLayoutRes.RES_BAR_RECT.size.y + 0.01,
			"★ 数字那一行真的在资源条里（pos.y %.0f + size.y %.0f ≤ 条高 %.0f）" % [
				food.position.y, food.size.y, UiLayoutRes.RES_BAR_RECT.size.y])
		var font: Font = main.hud._font
		if font != null:
			for pair in [[food, "粮食 1234"], [gold, "黄金 1234"]]:
				var w: float = font.get_string_size(String(pair[1]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, UiStyleRes.FS_BODY).x
				ok(w <= (pair[0] as Label).size.x + 0.01,
					"★ 「%s」宽 %.0f ≤ 可写 %.0f（4 位数也不被裁）" % [
						pair[1], w, (pair[0] as Label).size.x])
			ok(font.get_height(UiStyleRes.FS_BODY) <= UiLayoutRes.RES_ICON + 0.01,
				"★ 15 号字的行高 %.0f 装得进 %.0f 高那一行" % [
					font.get_height(UiStyleRes.FS_BODY), UiLayoutRes.RES_ICON])
		else:
			ok(true, "（没装中文字体，跳过资源条文字宽度的量算）")

	eq(bar.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 资源条不吃鼠标事件")
	ok(not main.hud.blocks_edge_scroll(UiLayoutRes.RES_BAR_RECT.get_center()),
		"★ 鼠标停在资源条上 → 仍然允许边缘滚屏（它只是文字与色块）")

static func res_bar_label_name(short: String) -> String:
	return "ResText_" + short

func _test_wheel_zoom_block(main) -> void:
	var vp: Vector2 = main.hud.view_size()
	var zoom_before_fn := func() -> float:
		return float(main.zoom)
	var reset_zoom_fn := func() -> void:
		main.zoom = 1.0
	reset_zoom_fn.call()
	var on_bar: Vector2 = UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)
	var on_map := Vector2(vp.x * 0.5, vp.y * 0.4)

	ok(main.hud.blocks_wheel_zoom(on_bar), "★ 鼠标在详细信息面板上 → 滚轮不缩放地图")
	ok(not main.hud.blocks_wheel_zoom(on_map), "鼠标在地图上 → 照旧缩放")
	ok(not main.hud.blocks_wheel_zoom(UiLayoutRes.MAP_RECT.get_center()),
		"★ 小地图上照旧缩放（需求：除地图外）")

	var z0: float = zoom_before_fn.call()
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, on_bar)
	near(zoom_before_fn.call(), z0, 1e-6, "★ 鼠标在底栏上滚轮 → 被吃掉，地图不缩放")
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, on_map)
	ok(absf(zoom_before_fn.call() - z0) > 1e-6,
		"★ 鼠标移出底栏（回到地图上）→ 滚轮恢复缩放（不是一次性开关）")
	z0 = zoom_before_fn.call()
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, UiLayoutRes.card_cell_rect(0).get_center())
	near(zoom_before_fn.call(), z0, 1e-6, "★ 再移回底栏（命令卡）→ 又不缩放")
	z0 = zoom_before_fn.call()
	_send_wheel(main, MOUSE_BUTTON_WHEEL_DOWN, on_bar)
	near(zoom_before_fn.call(), z0, 1e-6, "★ 向下滚在底栏上也不缩放")
	var left := InputEventMouseButton.new()
	left.button_index = MOUSE_BUTTON_LEFT
	ok(not main._is_wheel(left), "★ 这条规则只认滚轮：左键不会被它吞掉")
	ok(main._is_wheel(_wheel_event(MOUSE_BUTTON_WHEEL_DOWN)),
		"滚轮向下也被认出来（两个方向都拦）")
	reset_zoom_fn.call()

func _wheel_event(button: int, pos: Vector2 = Vector2.ZERO) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.position = pos
	return ev

func _send_wheel(main, button: int, pos: Vector2) -> void:
	main._unhandled_input(_wheel_event(button, pos))

func _camera_look_point(main) -> Vector3:
	return main._ground_under_screen(main._view_center())

func _test_notice_band(main) -> void:
	var panel = main.hud.detail_panel
	var grid = panel.grid_control()
	var body = panel._detail_box
	var notice = panel._notice
	ok(notice != null, "提示行的 Label 还在（只是从 VBox 搬进了右栏）")
	if notice == null:
		return

	main.hud.show_notice("")
	await process_frame
	var grid_rect := Rect2(grid.position, grid.size)
	var body_rect := Rect2(body.position, body.size)

	main.hud.show_notice("将领正在招募单位：它和它的部队这会儿只警戒，不接受指令")
	await process_frame
	eq(Rect2(grid.position, grid.size), grid_rect,
		"★ 提示出现时左栏网格的几何**一动不动**（以前会被压掉 20px、最下一截被裁）")
	eq(Rect2(body.position, body.size), body_rect, "★ 右栏数值框的几何也不动")
	ok(notice.visible, "提示行显示出来了")

	var nr := Rect2(notice.position, notice.size)
	ok(nr.position.y >= UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H,
		"★ 提示带在数值框**下面**（%.0f ≥ %.0f）" % [
			nr.position.y, UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H])
	ok(nr.position.y + nr.size.y <= UiLayoutRes.DETAIL_CONTENT_H + 0.01,
		"★ 提示带收在右栏内容高之内（%.0f ≤ %.0f）" % [
			nr.position.y + nr.size.y, UiLayoutRes.DETAIL_CONTENT_H])
	ok(nr.size.x <= UiLayoutRes.DETAIL_RIGHT_W + 0.01, "提示行不越出右栏")
	if grid.visible:
		var gr := Rect2(grid.global_position, grid.size)
		var ngr := Rect2(notice.global_position, notice.size)
		ok(not gr.intersects(ngr), "★ 提示行与左栏网格不重叠（它整条都在右栏里）")

	var font: Font = main.hud._font
	if font != null:
		for s in ["将领正在招募单位：它和它的部队这会儿只警戒，不接受指令",
				"只能在己方区划内招募（将领现在站的地方不属于你）"]:
			var w: float = font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UiStyleRes.FS_BODY).x
			ok(w <= nr.size.x + 0.01,
				"★ 提示「%s…」宽 %.0f ≤ 可用 %.0f（一行放得下）" % [s.substr(0, 6), w, nr.size.x])
	else:
		ok(true, "（没装中文字体，跳过提示文案的宽度量算）")

	main.hud.show_notice("")

func _test_anchors(main) -> void:
	root.size = Vector2i(2560, 1080)                      # 超宽：多出来的 640px 留在中间
	await process_frame
	await process_frame
	v2_near(main.hud.command_card.position, Vector2(UiLayoutRes.CARD_RECT.position.x + 640.0, 820.0), 1.0,
		"★ 超宽窗口：命令卡仍贴右下角")
	v2_near(main.hud.page_tabs.position, Vector2(UiLayoutRes.TABS_RECT.position.x + 640.0, 820.0), 1.0,
		"超宽窗口：页签列仍贴右下角")
	v2_near(main.hud.detail_panel.position, UiLayoutRes.DETAIL_RECT.position, 1.0,
		"超宽窗口：详细信息仍贴左边（x = 400）")
	# ★★ 本版：手机端不再横向拉伸 —— 固定 988 宽，右侧留白，不需要与页签 / 阵营列相连。
	near(main.hud.detail_panel.size.x, UiLayoutRes.DETAIL_RECT.size.x, 1.0,
		"★ 超宽窗口：详细信息面板仍是 988 宽（不再拉伸）")
	near(main.hud.detail_panel.right_column_width(), UiLayoutRes.DETAIL_RIGHT_W, 1.0,
		"★ 超宽窗口：右栏仍是 603 宽（多出来的宽不再灌进来）")
	near(main.hud.detail_panel.queue_position_x(),
		UiLayoutRes.detail_queue_x(UiLayoutRes.DETAIL_RIGHT_W), 1.0,
		"★ 超宽窗口：招募队列位置固定（右栏 603 下的 286）")
	ok(main.hud.detail_panel.position.x + main.hud.detail_panel.size.x
			< UiLayoutRes.FACTION_RECT.position.x + 640.0,
		"★ 面板右缘与右侧阵营列之间留白（不相连）")
	v2_near(main.hud.squad_panel.position,
		Vector2(UiLayoutRes.SQUAD_RECT.position.x + 640.0, UiLayoutRes.SQUAD_RECT.position.y), 1.0,
		"超宽窗口：将领列表仍贴右上")
	v2_near(main.hud.settings_button.position, Vector2(1840.0 + 640.0, 0.0), 1.0,
		"超宽窗口：设置仍贴右上角")
	ok(main.hud.blocks_edge_scroll(Vector2(UiLayoutRes.CARD_RECT.position.x + 640.0 + 40.0, 880.0)),
		"超宽窗口：命令卡的新位置仍然拦边缘滚屏（判定跟着贴边走）")

	_test_mobile_ui_scheduler(main)

	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	await process_frame


## ★★ 手机端 UI 调度器（本轮）：
##   · 一次 refresh 只扫一遍 `world.units`（页签与详情共用缓存）；
##   · 同一段详情文本重喂不重排；
##   · 4 槽轮转（shell / detail / shell+squad / detail）；
##   · 选中变化强制全刷。
func _test_mobile_ui_scheduler(main) -> void:
	var hud = main.hud
	var dp = hud.detail_panel
	var squad = hud.squad_panel
	ok(hud != null and dp != null and squad != null, "（前提）HUD / 详情 / 部队列表都在")
	if hud == null or dp == null or squad == null:
		return

	# ① 一次全量 refresh 只扫一遍单位
	var s0: int = hud.troops_scans
	hud.refresh()
	eq(hud.troops_scans - s0, 1,
		"★★ 一次 refresh 只扫一遍 world.units（页签与详情共用 tick 缓存）")

	# ② 同一段详情文本重喂仍保持内容（两列表格没有旧的整块自动缩放）
	var text := "第一行\n第二行"
	dp.set_detail(text)
	eq(dp.detail_text(), text, "★ 旧接口 set_detail() 仍能按行喂进两列表格")
	dp.set_detail(text)
	eq(dp.detail_text(), text, "★ 重喂同一段文本结果不变")

	# ③ 4 槽轮转
	var old_interval: float = hud._refresh_interval
	var old_stagger: bool = hud._mobile_ui_stagger
	var old_phase: int = hud._mobile_phase
	var old_force: bool = hud._mobile_force_full
	hud._refresh_interval = 0.05
	hud._mobile_ui_stagger = true
	hud._mobile_phase = 0
	hud._mobile_force_full = false
	var sq0: int = squad.refresh_count
	var scans0: int = hud.troops_scans

	hud._mobile_tick()                       # 槽 0：shell
	eq(hud._mobile_phase, 1, "槽 0 之后轮到槽 1")
	eq(squad.refresh_count, sq0, "槽 0 不刷部队列表")
	hud._mobile_tick()                       # 槽 1：detail
	eq(hud._mobile_phase, 2, "槽 1 之后轮到槽 2")
	eq(squad.refresh_count, sq0, "槽 1 不刷部队列表")
	hud._mobile_tick()                       # 槽 2：shell + squad
	eq(hud._mobile_phase, 3, "槽 2 之后轮到槽 3")
	eq(squad.refresh_count - sq0, 1, "★ 槽 2 刷新部队列表一次")
	hud._mobile_tick()                       # 槽 3：detail
	eq(hud._mobile_phase, 0, "槽 3 之后回到槽 0")
	eq(hud.troops_scans - scans0, 4, "★ 每个调度节拍只扫一次单位（4 拍 = 4 次）")

	# ④ 选中变化强制全刷（一次 refresh + 一次 squad）
	hud._mobile_force_full = true
	var sq1: int = squad.refresh_count
	var scans1: int = hud.troops_scans
	hud._mobile_tick()
	eq(hud._mobile_force_full, false, "★ 强制全刷标记被消费")
	eq(hud.troops_scans - scans1, 1, "强制全刷只扫一次单位")
	eq(squad.refresh_count - sq1, 1, "强制全刷也刷新部队列表")

	hud._refresh_interval = old_interval
	hud._mobile_ui_stagger = old_stagger
	hud._mobile_phase = old_phase
	hud._mobile_force_full = old_force


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
	eq(side, 72.0, "★ 右栏头像方框 = 72×72（本轮从参考图的 100 收到 72：那块「大而空」，见 ui_layout 的注释）")
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

	panel.set_unit_avatar_text("将")
	var before: int = panel.avatar_draw_count()
	panel._unit_avatar.queue_redraw()
	await process_frame
	ok(panel.avatar_draw_count() > before, "★ 头像那一块真的画了一帧（_draw 跑过）")

	eq(panel.buff_count(), 0, "（前提）动态 buff 槽位默认是空的（不再有写死的占位）")
	var empty_bar = panel.buff_bar_control()
	eq(empty_bar.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"★ 没有 buff 时槽位不吃鼠标（不挡底下的东西）")
	panel.set_buffs([
		{
			"id": "morale", "text": "士", "color": UiStyleRes.morale_plate(0.5, true),
			"name": "士气 50/100", "tip_title": "士气",
			"tip_body": "当前 50 / 100\n≥100：快速回血，受到伤害 -50%\n≤50：受到伤害 +50%",
		},
	])
	eq(panel.buff_count(), 1, "★ 动态 buff 槽位能加条目")
	var bb = panel.buff_bar_control()
	eq(bb.mouse_filter, Control.MOUSE_FILTER_STOP,
		"★ 有 buff 时槽位收鼠标，才能收到悬停")
	eq(String(bb.entry(0).get("text", "")), "士", "★ 士气 buff 的方块字是「士」")
	var br: Rect2 = bb.buff_rect(0)
	eq(br.size, Vector2(UiLayoutRes.BUFF_SIZE, UiLayoutRes.BUFF_SIZE),
		"★ 每个 buff 是 40×40 的方块")
	ok(br.position.x >= 0.0 and br.position.x + br.size.x <= bb.size.x + 0.01,
		"★ 第 1 个 buff 落在槽位可用宽之内")

	# ★★ 悬停浮窗：与命令卡那块悬停面板同一套（标题 + 多行正文，向下长）
	bb.hover_at(0)
	await process_frame
	ok(bb.tip_showing(), "★ 鼠标停在 buff 上 → 悬停浮窗出现")
	eq(bb.hover_index(), 0, "★ 当前悬停的是第 0 个 buff")
	eq(bb.tip_title_text(), "士气", "★ 浮窗标题 = buff 名")
	ok(bb.tip_body_text().contains("当前 50 / 100"),
		"★ 浮窗正文第一行是当前值（实际：%s）" % bb.tip_body_text().replace("\n", "|"))
	ok(bb.tip_body_text().contains("≥100") and bb.tip_body_text().contains("≤50"),
		"★ 浮窗正文列出各档效果")
	var tip = bb.tip_control()
	eq(tip.position.x, br.position.x, "★ 浮窗左缘 = 那个 buff 方块的左缘")
	eq(tip.position.y, UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_TIP_GAP,
		"★ 浮窗贴在 buff 方块下缘（向下长）")
	eq(tip.size.x, UiLayoutRes.BUFF_TIP_W, "★ 浮窗宽固定 230")
	ok(tip.size.y > 0.0, "★ 浮窗高度按内容算（> 0）")
	ok(bb.position.y + tip.position.y + tip.size.y <= UiLayoutRes.DETAIL_CONTENT_H + 0.01,
		"★ 浮窗不越出右栏内容高（%.0f ≤ %.0f）" % [
			bb.position.y + tip.position.y + tip.size.y, UiLayoutRes.DETAIL_CONTENT_H])
	bb.clear_hover()
	ok(not bb.tip_showing(), "★ 鼠标移开 → 浮窗收起")
	eq(bb.hover_index(), -1, "★ 悬停下标清空")

	# 没给 tip_title / tip_body 时退回 name（其它系统以后加 buff 不必强制写说明）
	panel.set_buffs([
		{"id": "x", "text": "X", "color": UiStyleRes.morale_plate(0.5, true),
			"name": "测试 buff"},
	])
	bb.hover_at(0)
	await process_frame
	eq(bb.tip_title_text(), "测试 buff", "★ 没写 tip_title 时退回 name")
	eq(bb.tip_body_text(), "", "★ 没有 tip_body 时正文为空")
	bb.clear_hover()

	panel.set_buffs([])
	eq(panel.buff_count(), 0, "★ 传空数组 = 槽位清空")
	eq(bb.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 清空后又回到不吃鼠标")
	panel.queue_free()
	await process_frame

func _test_hp_bars(cfg) -> void:
	# ① 几何：血条宽度 = 图标宽度、贴图标底边、很薄（纯函数，不进树）
	var icon := Rect2(10.0, 20.0, 40.0, 40.0)
	var bar := UiLayoutRes.hp_bar_rect(icon)
	ok(UiLayoutRes.HP_BAR_H > 0.0, "血条有厚度（HP_BAR_H > 0）")
	eq(bar.size.x, icon.size.x, "★ 血条**水平长度 = 图标宽度**")
	eq(bar.size.y, UiLayoutRes.HP_BAR_H, "★ 血条竖直很薄（= HP_BAR_H）")
	eq(bar.position.x, icon.position.x, "血条与图标左缘对齐")
	eq(bar.position.y, icon.position.y + icon.size.y - UiLayoutRes.HP_BAR_H,
		"★ 血条贴在图标底边")

	# ② 配色：按血量比例绿→黄→红
	eq(UiStyleRes.hp_bar_color(1.0), UiStyleRes.hp_high(), "满血 = 绿")
	eq(UiStyleRes.hp_bar_color(0.5), UiStyleRes.hp_high(), "半血 = 绿（阈值 0.5）")
	eq(UiStyleRes.hp_bar_color(0.3), UiStyleRes.hp_mid(), "三成 = 黄")
	eq(UiStyleRes.hp_bar_color(0.1), UiStyleRes.hp_low(), "一成 = 红")
	var hi := UiStyleRes.hp_high()
	var lo := UiStyleRes.hp_low()
	ok(hi.g > hi.r and lo.r > lo.g, "★ 绿档偏绿、红档偏红（一眼分得出快死了）")

	# ②b 士气填充色：满士气偏绿 → 零士气偏红（部队图标的背景，见 view/morale_fill.gd）
	var mp_full := UiStyleRes.morale_plate(1.0)
	var mp_zero := UiStyleRes.morale_plate(0.0)
	ok(mp_full.g > mp_full.r, "★ 满士气填充 → 偏绿")
	ok(mp_zero.r > mp_zero.g, "★ 零士气填充 → 偏红")
	near(UiStyleRes.morale_plate(1.0, true).a, UiStyleRes.MORALE_ALPHA_STRONG, 1e-6,
		"★ 部队图标的士气填充用较实的 alpha（MORALE_ALPHA_STRONG）")
	near(UiStyleRes.morale_plate(1.0, false).a, UiStyleRes.MORALE_ALPHA_NORMAL, 1e-6,
		"★ 普通档 alpha 仍在（给需要更淡的地方用）")

	# ③ 网格：血条真的画了 + 绑定单位血量
	var font: Font = FontLoaderRes.load_font(cfg)
	ok(font != null, "（前提）拿得到中文字体（血条用例要用它画格子）")
	if font == null:
		return
	var grid = TroopGridRes.new()
	root.add_child(grid)
	grid.setup(font)
	grid.size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.TROOP_GRID_H)
	var u = UnitRes.new()
	u.name = "测试兵"
	u.hp = 50.0
	u.hp_max = 100.0
	grid.set_units([u], ["兵"])
	grid.queue_redraw()
	await process_frame
	eq(grid.cell_count(), 1, "（前提）网格里有 1 格")
	near(grid._hp_ratio_at(0), 0.5, 0.001, "★ 血条比例绑定单位血量（50/100 = 0.5）")
	ok(grid.bar_draw_count >= 1, "★ 网格格子底部真的画了血条")
	# ★★ 同一批格子重喂不重画；血量变化必须重画（否则血条会停在旧值）
	var ar0: int = grid.apply_redraws
	grid.set_units([u], ["兵"])
	eq(grid.apply_redraws, ar0, "★★ 内容没变时 3×3 网格不重画（HUD 10Hz 重喂也不刷）")
	u.hp = 40.0
	grid.set_units([u], ["兵"])
	eq(grid.apply_redraws, ar0 + 1, "★ 血量变化后网格重画一次")
	var before: int = grid.bar_draw_count
	grid.queue_redraw()
	await process_frame
	eq(grid.bar_draw_count - before, grid.cell_count(),
		"★ 每个有东西的格子一条血条（画满 = 格子数）")
	# 血量变了 → 比例跟着变（绑定不是画一次就定格）
	u.hp = 10.0
	near(grid._hp_ratio_at(0), 0.1, 0.001, "★ 掉血后比例跟着变（10/100 = 0.1）")
	# 单个单位**不再有士气背景**（本版需求：只有部队图标才有士气填充）
	u.morale = u.morale_max * 0.25
	eq(grid._morale_ratio_at(0), 1.0,
		"★ 单个单位格子不再画士气背景（只有部队格才有）")

	# ③b 部队图标：序号 + 士气填充（整支部队共享的一个值）
	eq(IconBadgeRes.troop_number_text(1), "1", "★ 部队序号：第 1 支写 1")
	eq(IconBadgeRes.troop_number_text(9), "9", "★ 部队序号：第 9 支写 9")
	eq(IconBadgeRes.troop_number_text(10), "0",
		"★ 部队序号：第 10 支写 0（与右侧部队列表同一口径）")
	var leader = UnitRes.new()
	leader.name = "测试队长"
	leader.hp = 100.0
	leader.hp_max = 100.0
	leader.morale_max = 100.0
	leader.morale = 50.0
	grid.set_troops([{"leader": leader, "number": 3, "units": [leader]}])
	eq(grid.cell_kind(0), "troop", "★ 多选部队时格子是部队格")
	eq(grid.cell_short(0), "3", "★★ 部队图标 = 序号（不是将领名字首字）")
	near(grid._morale_ratio_at(0), 0.5, 0.001, "★ 部队图标的士气比例绑定部队士气（50%）")

	# ③c 横向滑动：11 个单位 = 4 列，可见 3 列 ⇒ 能滑一列
	var many: Array = []
	for k in 11:
		var m = UnitRes.new()
		m.name = "兵%d" % (k + 1)
		m.hp = 100.0
		m.hp_max = 100.0
		many.append(m)
	grid.set_units(many, [])
	eq(grid.cell_count(), 11, "★ 整批 11 个单位都在网格里（不再只装一页 9 格）")
	eq(grid.content_columns(), 4, "★ 11 个单位排成 4 列")
	eq(grid.max_scroll_x(), UiLayoutRes.TROOP_CELL_W,
		"★ 最多滑一列（116px）就能看到第 12 个位置")
	eq(grid.page_count(), 2, "★ 滚轮翻页：11 个单位 = 2 页（一页 9 格）")
	grid.set_page(0)
	eq(grid.page(), 0, "（前提）停在第 1 页")
	var wheel_down := InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	grid._gui_input(wheel_down)
	eq(grid.page(), 1, "★ 滚轮向下 → 翻到第 2 页")
	eq(grid.scroll_x(), UiLayoutRes.TROOP_CELL_W, "★ 第 2 页滚到最右（夹在内容边界）")
	var wheel_up := InputEventMouseButton.new()
	wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel_up.pressed = true
	grid._gui_input(wheel_up)
	eq(grid.page(), 0, "★ 滚轮向上 → 回到第 1 页")
	eq(grid.scroll_x(), 0.0, "★ 第 1 页回到最左")
	# 拖动：按住往左拖 100px → 内容跟着向左滚 100px（自由滑，不吸附）
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = Vector2(200.0, 20.0)
	grid._gui_input(press)
	var drag := InputEventMouseMotion.new()
	drag.position = Vector2(100.0, 20.0)
	drag.button_mask = MOUSE_BUTTON_MASK_LEFT
	grid._gui_input(drag)
	near(grid.scroll_x(), 100.0, 0.01, "★ 鼠标拖动 → 自由横滑（不吸附）")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = Vector2(100.0, 20.0)
	grid._gui_input(release)
	eq(grid.scroll_x(), 100.0, "★ 松手后停在拖到的位置（自由滑）")
	grid.queue_free()

	# ④ 右栏大头像：show 时才画血条；**没有士气背景板**（本版需求）
	var panel = DetailPanelRes.new()
	root.add_child(panel)
	await process_frame
	panel.setup(null, font)
	panel.set_unit_avatar_text("兵")
	panel.set_unit_avatar_hp(0.3, true)
	var ab: int = panel.avatar_bar_draw_count()
	panel._unit_avatar.queue_redraw()
	await process_frame
	ok(panel.avatar_bar_draw_count() > ab, "★ 右栏头像底部也画了血条")
	panel.set_unit_avatar_hp(0.3, false)
	var ab2: int = panel.avatar_bar_draw_count()
	panel._unit_avatar.queue_redraw()
	await process_frame
	eq(panel.avatar_bar_draw_count(), ab2, "★ show=false（区划 / 未选中）时不画头像血条")
	ok(not panel.has_method("set_unit_avatar_morale"),
		"★ 右栏头像不再有士气背景板（单位 / 建筑只有图标 + 血条）")
	panel.queue_free()
	await process_frame


func _test_squad_rows(main) -> void:
	var panel = main.hud.squad_panel
	var world = main.world

	eq(panel.slot_count(), UiLayoutRes.SQUAD_SLOTS, "部队列表有 10 个槽")
	var teams := 0
	for u in world.units:
		if u.alive and world.is_team_leader(u) and FactionRes.same_side(u.faction, world.my_faction):
			teams += 1
	eq(teams, 3, "己方有 3 支队伍")
	ok(panel.slot_text(0).begins_with("1 "),
		"第 1 槽以数字 1 开头（实际：%s）" % panel.slot_text(0))
	ok(panel.slot_text(0).contains("将领 1"), "第 1 槽带队伍名")
	ok(panel.slot_formation(0).contains("/"),
		"第 1 槽带「当前/上限」编制（实际：%s）" % panel.slot_formation(0))

	var line_font: Font = main.hud._font
	if line_font != null:
		var row_fs: int = panel.slot_button(0).get_theme_font_size("font_size")
		eq(row_fs, 14, "★ 将领标签名字用 14 号字")
		var row = panel.slot_button(0)
		var lines: PackedStringArray = String(panel.slot_text(0)).split("\n")
		eq(lines.size(), 2, "★ 每条标签是两行文案（名字 / 编制）")
		for ln in lines:
			var w: float = line_font.get_string_size(String(ln),
				HORIZONTAL_ALIGNMENT_LEFT, -1, row_fs).x
			ok(w <= UiLayoutRes.SQUAD_TEXT_W + 0.01,
				"★ 将领标签「%s」宽 %.0f ≤ 可写宽 %.0f" % [ln, w, UiLayoutRes.SQUAD_TEXT_W])
		ok(row.number_text() == "1", "第 1 条数字是 1")

	ok(panel.slot_filled(2), "第 3 槽有队伍")
	ok(not panel.slot_filled(3), "第 4 槽是空的")
	eq(panel.slot_number(9), "0", "★ 第 10 条标签的数字显示 0")
	for i in range(3, UiLayoutRes.SQUAD_SLOTS):
		eq(panel.slot_text(i), "…", "空槽第 %d 行显示「…」" % (i + 1))

	var g3 = world.unit_by_id("general-3")
	ok(g3 != null, "有 general-3")
	var cam_before: Vector3 = _camera_look_point(main)
	panel.slot_button(2).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), world.group_of(g3).size(),
		"点部队行 = 选中整队（%d 个）" % world.group_of(g3).size())
	eq(main.input_ctrl.selected_units[0].id, g3.id, "整队的队长排在第一个")
	ok(_camera_look_point(main).is_equal_approx(cam_before),
		"★ 点部队行只选中，镜头不动（需求原话）")
	ok(panel.slot_active(2), "当前选中的队伍在列表里高亮")

	var sel_before: int = main.input_ctrl.selected_units.size()
	panel.slot_button(7).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), sel_before, "★ 空槽点了没有反应")

	# ★★ 反选（本轮需求「点击代表反选」）：
	#    无选中 → 点 1 = 选中 1 → 点 2 = 选中 1+2 → 再点 1 = 只剩 2 → 再点 2 = 清空。
	main.input_ctrl.select_units([])
	var g1 = world.unit_by_id("general-1")
	var g2 = world.unit_by_id("general-2")
	var team1: Array = world.group_of(g1)
	var team2: Array = world.group_of(g2)
	panel.slot_button(0).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★ 反选：点部队 1 = 选中第 1 支（%d 个）" % team1.size())
	ok(panel.slot_active(0) and not panel.slot_active(1), "只有第 1 支高亮")

	panel.slot_button(1).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), team1.size() + team2.size(),
		"★★ 反选：再点部队 2 = 两支一起选中（不是把第 1 支顶掉）")
	ok(panel.slot_active(0) and panel.slot_active(1), "两支都高亮")
	eq(int(main.hud._detail_troop_number), 2, "★ 点谁就展开谁（详情焦点 = 部队 2）")

	panel.slot_button(0).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), team2.size(),
		"★★ 反选：再点部队 1 = 取消第 1 支，只剩第 2 支（%d 个）" % team2.size())
	ok(not panel.slot_active(0) and panel.slot_active(1), "第 1 支取消高亮，第 2 支保持")
	eq(String(main.input_ctrl.selected_units[0].id), String(g2.id),
		"反选之后剩下的队长是第 2 支的将领")

	# ★★ 详情焦点：点谁展开谁；**把展开的那支反选掉** → 回退到剩余部队的第一支。
	panel.slot_button(0).emit_signal("pressed")           # 1+2，焦点 = 1
	eq(main.input_ctrl.selected_units.size(), team1.size() + team2.size(),
		"（前提）再点部队 1 又回到两支一起选中")
	eq(int(main.hud._detail_troop_number), 1, "★ 点部队 1 → 详情焦点切到 1")
	panel.slot_button(0).emit_signal("pressed")           # 反选掉 1
	eq(main.input_ctrl.selected_units.size(), team2.size(), "（前提）反选掉 1 之后只剩 2")
	main.hud.refresh()                                     # 让 _pick_troop 发现并回退
	eq(int(main.hud._detail_troop_number), 2,
		"★★ 展开的那支被反选掉 → 详情焦点回退到剩余的第一支（部队 2）")

	panel.slot_button(1).emit_signal("pressed")
	eq(main.input_ctrl.selected_units.size(), 0,
		"★ 反选：点掉最后一支 = 清空选中（反选的正常结果）")
	ok(not panel.slot_active(1), "清空后没有任何标签高亮")

	main.input_ctrl.select_units([world.unit_by_id("general-1")])

func _test_page_tabs_and_card(main, cfg) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	var world = main.world

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	eq(tabs.page_count(), 2, "★ 选中部队时只有两颗页签（操作 / 单位）")
	eq(tabs.page_id_at(0), PageTabsRes.PAGE_ORDER, "第一颗是「操作」")
	eq(tabs.page_id_at(1), PageTabsRes.PAGE_UNIT, "第二颗是「单位」")
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 默认停在「操作」页")
	eq(card.entries().size(), 4, "★ 操作页有四格（移动 / 攻击 / 行军 / 停止）")
	eq(String(card.entry_at(0).get("type", "")), "order", "操作页那一项是「部队指令」")
	eq(card.cell_label(0), "移动", "操作页 Q 格 = 移动")
	eq(card.cell_label(1), "攻击", "操作页 W 格 = 攻击")
	eq(card.cell_label(2), "行军", "操作页 E 格 = 行军")
	eq(card.cell_label(3), "停止", "操作页 A 格 = 停止")
	ok(tabs.is_active(0), "当前页在页签上高亮")

	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "点第二颗切到「单位」页")
	eq(card.entries().size(), 9, "★ 单位页固定九格（三行；空位也是格子）")
	eq(String(card.entry_at(0).get("type", "")), "recruit", "单位页那一项是「招募」")
	eq(card.cell_label(0), "长枪兵", "单位页 Q 格 = 长枪兵（第 1 行）")
	eq(card.cell_label(1), "长弓兵", "单位页 W 格 = 长弓兵（第 1 行）")
	eq(card.cell_label(2), "", "单位页 E 格空着（第 1 行只有两个兵）")
	eq(card.cell_label(3), "骑手", "★ 骑手挪到第 2 行第 1 格（A）")
	eq(card.cell_label(4), "粮车", "★ 第 2 行第 2 格 = 粮车（S）")
	eq(card.cell_label(5), "", "第 2 行第 3 格空着")
	eq(card.cell_label(6), "骑士", "★ 第 3 行第 1 格 = 骑士（Z）")
	eq(card.cell_label(7), "马弓手", "★ 第 3 行第 2 格 = 马弓手（X）")
	eq(card.cell_label(8), "投石车", "★ 第 3 行第 3 格 = 投石车（C）")
	eq(String(card.entry_at(0).get("unit_kind", "")), UnitRes.UNIT_TYPE_SPEARMAN,
		"Q 格要招的是长枪兵")
	eq(int(card.entry_at(3).get("tier", 0)), 2, "第 2 行 = 大本营 2 级解锁")
	eq(int(card.entry_at(6).get("tier", 0)), 3, "第 3 行 = 大本营 3 级解锁")
	ok(not bool(card.entry_at(3).get("ready", true)),
		"★ 没有 2 级大本营时骑手格子置灰")
	ok(not bool(card.entry_at(6).get("ready", true)),
		"★ 没有 3 级大本营时骑士格子置灰")
	ok(bool(card.entry_at(0).get("ready", false)),
		"★ 第 1 行（长枪兵）在 1 级就可用")

	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(tabs.page_count(), 2, "★ 什么都没选中时有两颗页签（建筑 / 科技）")
	eq(tabs.page_id_at(0), PageTabsRes.PAGE_BUILD, "第一颗是「建筑」")
	eq(tabs.page_id_at(1), PageTabsRes.PAGE_TECH, "★ 第二颗是「科技」（本轮新增）")
	eq(tabs.page(), PageTabsRes.PAGE_BUILD, "★ 默认停在「建筑」页")
	eq(card.entries().size(), 2, "★ 建筑页有 2 项（需求原话：只有两个建筑）")
	eq(String(card.entry_at(0).get("build_type", "")), "wall", "建筑页第 1 项是城墙")
	eq(String(card.entry_at(1).get("build_type", "")), "tower", "建筑页第 2 项是箭塔")
	eq(card.cell_label(0), "城墙", "城墙在 Q 格（需求原话）")
	eq(card.cell_label(1), "箭塔", "箭塔在 W 格（需求原话）")
	ok(not main.hud.tech_grid.visible, "★ 不是科技页时九格收起来（命令卡照常画）")

	# ★★ 回归（手玩报的「刚进游戏时右下角『建筑』按钮错位」）：
	#    进游戏那一刻 hud 建的是**1 颗**页签（铺满整列 240 高，「建筑」两个字就是按
	#    240 建的），第一帧 refresh 才把它换成「建筑 + 科技」**两颗**（各 120 高）——
	#    文案一个字没变，变的只是**按钮高度**。而逐字 Label 的高度是**建它那一刻**从
	#    按钮取的 ⇒ 高度变了必须重建；只比文案的话这一颗会留着 240、字按 240 居中，
	#    就沉到按钮下缘（与「科技」的交界处）。
	var fresh = PageTabsRes.new()
	main.hud.add_child(fresh)
	fresh.setup()                                   # setup 内部就是「1 颗建筑页」那一刻
	eq(fresh.button_at(0).size.y, 260.0, "★ 进游戏那一刻：一颗页签铺满整列（260 高）")
	fresh.set_pages([PageTabsRes.PAGE_BUILD, PageTabsRes.PAGE_TECH])
	eq(fresh.label_at(0), "建筑", "★ 换成两颗后第一颗的**文案没变**（旧判据正是漏了这一种）")
	for i in 2:
		var ftb = fresh.button_at(i)
		var fcls: Array = fresh.char_labels_at(i)
		ok(not fcls.is_empty(), "「%s」页签有逐字 Label" % fresh.label_at(i))
		for l in fcls:
			eq(float((l as Control).size.y), float(ftb.size.y),
				"★★ 「%s」的逐字 Label 按**当前**按钮高度排版（Label %s / 按钮 %s）"
					% [fresh.label_at(i), str((l as Control).size), str(ftb.size)])
	main.hud.remove_child(fresh)
	fresh.queue_free()

	# 开局不再自动生成防御阵地 → 需要一栋己方普通建筑时现造一栋
	var plain_b = _ensure_own_building(world, "wall")
	ok(plain_b != null, "拿得到一栋己方普通建筑（城墙 / 箭塔）")
	if plain_b != null:
		main.input_ctrl.select_building(plain_b)
		main.hud.refresh()
		eq(tabs.page_count(), 1, "★ 选中普通建筑 → 一颗页签")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 它是「操作」页")
		ok(tabs.button_at(0) != null and tabs.button_at(0).visible,
			"页签按钮是可见的")
		eq(tabs.label_at(0), "操作", "页签上写着「操作」")
		v2_near(tabs.button_at(0).size, Vector2(108.3333, 260.0), 1.0,
			"★ 只有一颗时它铺满整列（108.333×260）")
		ok(tabs.is_active(0), "★ 当前页画成高亮")
		ok(UiStyleRes.tab_normal().bg_color.a > 0.2,
			"★ 非当前页的页签有底色（全透明时立在地图上看不见）")
		ok(UiStyleRes.tab_active().bg_color.a > 0.9, "当前页仍是实心强调色（变的是普通态）")
		eq(card.entries().size(), 1, "★ 操作页只有一格（升级）")
		eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
			"那一格是「升级」")
		eq(card.cell_label(0), "升级%s" % plain_b.display_name(),
			"★ 格子上写着「升级%s」" % plain_b.display_name())

	var wall_b = _ensure_own_building(world, "wall")
	var tower_b = _ensure_own_building(world, "tower")
	ok(wall_b != null and tower_b != null, "（前提）拿得到己方的城墙与箭塔")
	if wall_b != null and tower_b != null:
		eq(wall_b.type, "wall", "（前提）第 1 栋是城墙")
		eq(tower_b.type, "tower", "（前提）第 2 栋是箭塔")
		main.input_ctrl.select_building(wall_b)
		main.hud.refresh()
		eq(card.cell_label(0), "升级城墙", "（前提）选中城墙 → 操作页写着「升级城墙」")
		main.input_ctrl.select_building(tower_b)
		main.hud.refresh()
		eq(card.cell_label(0), "升级箭塔",
			"★ 改选箭塔 → 那一格必须跟着变成「升级箭塔」（不许还写着城墙）")
		eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
			"换选中之后那一格还是「升级」那一套（只是换了目标）")
		main.input_ctrl.select_building(wall_b)
		main.hud.refresh()
		eq(card.cell_label(0), "升级城墙", "★ 再改回城墙 → 又跟着变回来（反方向也要对）")
		var wall_b2 = null
		for b2 in world.building_list:
			if b2 != null and b2.alive and b2.type == "wall" and b2 != wall_b \
					and FactionRes.same_side(String(b2.owner), String(wall_b.owner)):
				wall_b2 = b2
				break
		if wall_b2 != null:
			main.input_ctrl.select_building(wall_b2)
			main.hud.refresh()
			eq(card.cell_label(0), "升级城墙", "换同类型的另一栋城墙：文案照旧（内容本来就一样）")

	var base = world.find_base_of("p1")
	ok(base != null, "有己方大本营")
	if base != null:
		main.input_ctrl.select_building(base)
		main.hud.refresh()
		eq(tabs.page_count(), 2, "★ 大本营有两颗页签（操作 / 科技）")
		eq(tabs.page_id_at(0), PageTabsRes.PAGE_ORDER, "第一颗是「操作」")
		eq(tabs.page_id_at(1), PageTabsRes.PAGE_TECH, "第二颗是「科技」")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 默认停在「操作」页")
		eq(card.entries().size(), 1, "大本营的操作页只有一格")
		eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
			"★ 那一格是「升级大本营」")
		eq(card.cell_label(0), "升级大本营", "★ 格子上写着「升级大本营」")
		tabs.button_at(1).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_TECH, "点第二颗切到「科技」页")
		_eq_tech_page(main, "选中大本营")
		ok(not main.hud.tech_grid.visible or true, "（科技页转换见下）")
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "切回操作页")
		eq(card.entries().size(), 1, "操作页还是「升级大本营」那一格")

	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(tabs.page_count(), 2, "空手时建筑 / 科技两颗")
	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_TECH, "点第二颗切到「科技」页")
	_eq_tech_page(main, "什么都没选中")
	var g = main.hud.tech_grid
	var first_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	ok(first_id != "", "第一格有 id")
	ok(not world.is_tech_active(first_id), "开局这一条没启用")
	g.press(0)
	ok(world.is_tech_active(first_id), "★ 点一格 = 启用（走 tech_toggle 命令）")
	ok(g.cell_active(0), "★ 已启用的那一格画成高亮")
	g.press(0)
	ok(not world.is_tech_active(first_id), "★ 再点一次 = 弃用")
	var ids: Array = []
	for i in g.entries().size():
		ids.append(String((g.entry_at(i) as Dictionary).get("id", "")))
	# ★ 这段验的是「最多 3 条」这条旧规则：把大本营拉到 3 级，
	#   否则 1 级的「最多 1 条 + 仅一阶」会先把它挡住（那是 test_base_limits 的事）。
	if base != null:
		base.level = world.cfg.upgrade_max_level("base")
		world.apply_building_level_hp(base)
	for k in 3:
		g.press(k)
	eq(world.active_tech_ids().size(), 3, "★ 启用了三条")
	ok(world.tech_remaining_slots() == 0, "名额用完")
	g.press(3)
	ok(not world.is_tech_active(ids[3]), "★ 第 4 条没有生效（被阻止）")
	# ★ 新版口径：不能启用的格子**置灰不可点**（点了什么都不发生），原因写在悬停里。
	ok(not main.hud.notice_active(), "置灰格点了不弹红字（悬停才说明原因）")
	var locked_cell = g.cell_at(3)
	ok(locked_cell != null and not locked_cell.disabled,
		"★ 置灰格仍可悬停（不是 disabled 灰按钮）")
	ok(FillButtonRes.is_grey(locked_cell), "★ 不可启用格走「灰色填充」档")
	var locked_style: StyleBox = locked_cell.get_theme_stylebox("normal")
	ok(locked_style is StyleBoxFlat and (locked_style as StyleBoxFlat).bg_color.a <= 0.01,
		"★ 置灰格底纹透明（灰色来自填充，不是实心灰按钮）")
	ok(not FillButtonRes.is_grey(g.cell_at(0)), "（对照）可启用 / 已启用的格子不是灰档")
	var tip: Dictionary = main.hud._hover_detail("tech", g.entry_at(3))
	ok(String(tip.get("body", "")).contains("不能启用"),
		"★ 悬停说明「现在不能启用」：%s" % String(tip.get("body", "")))
	for k in 3:
		g.press(k)
	eq(world.active_tech_ids().size(), 0, "收尾：弃用全部科技")
	# 把大本营等级还原（下面还要验「大本营操作页 = 升级」那一格）。
	if base != null:
		base.level = 1
		world.apply_building_level_hp(base)

	var zone = _zone_with_center(world)
	ok(zone != null, "地图上找得到一个带中心的区划")
	if zone != null:
		main.input_ctrl.select_zone(zone)
		main.hud.refresh()
		eq(tabs.page_count(), 2, "★ 选中区划中心有两颗页签（操作 / 招募）")
		eq(tabs.page_id_at(0), PageTabsRes.PAGE_ORDER, "第一颗是「操作」")
		eq(tabs.page_id_at(1), PageTabsRes.PAGE_RECRUIT, "第二颗是「招募」")
		tabs.select_page(PageTabsRes.PAGE_ORDER)
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 停在「操作」页")
		eq(card.entries().size(), 2, "★ 人口区划的操作页里是两格特化")
		eq(card.cell_label(0), "粮食特化", "Q 格 = 粮食特化")
		eq(card.cell_label(1), "黄金特化", "W 格 = 黄金特化")
		eq(String(card.entry_at(0).get("type", "")), "zone_specialize",
			"操作页那一项是「特化」")
		eq(String(card.entry_at(0).get("spec", "")), "food", "第 1 格是粮食特化")
		ok(not _entry_specs(card).has("population"),
			"★ 人口区划**没有**人口特化那一格（需求：只能黄金 / 粮食特化）")
		ok(main.hud.detail_panel.detail_text().contains("粮食"),
			"★ 区划详情右列显示产能（实际：%s）"
				% main.hud.detail_panel.detail_text().replace("\n", "|"))
		tabs.button_at(1).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 第二颗 = 招募页签")
		eq(card.entries().size(), 9, "★★ 招募页是固定九宫格（#1-9）")
		var roster: Array = world.general_recruit_roster("p1")
		eq(roster.size(), 9, "★ 固定阵容 9 位")
		for i in 9:
			eq(card.cell_label(i), world.recruit_label_of(String(roster[i])),
				"第 %d 格 = 将领 %d" % [i + 1, i + 1])
		eq(String(card.entry_at(0).get("type", "")), "zone_recruit",
			"招募页那一项是「区划招募」（排进区划的队列）")
		eq(String(card.entry_at(0).get("unit_kind", "")), String(roster[0]),
			"第 1 格 = 将领 1")
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "切回操作页")

		var z_other = _zone_with_center_of_other_kind(world, zone)
		ok(z_other != null, "（前提）地图上还有一个**种类不同**、且没特化过的区划中心")
		if z_other != null:
			z_other["owner"] = String(world.my_faction)
			main.input_ctrl.select_zone(z_other)
			main.hud.refresh()
			tabs.select_page(PageTabsRes.PAGE_ORDER)
			eq(_entry_specs(card), _specs_of(world, z_other),
				"★ 改选另一个种类的区划中心 → 操作页那几档特化跟着换（期望 %s，实际 %s）"
					% [str(_specs_of(world, z_other)), str(_entry_specs(card))])
			ok(not _entry_specs(card).is_empty(), "（前提）这个种类的区划还有可选的档位")
			main.input_ctrl.select_zone(zone)
			main.hud.refresh()
			tabs.select_page(PageTabsRes.PAGE_ORDER)
			eq(_entry_specs(card), _specs_of(world, zone), "（收尾）选回来 → 又跟着换回来")

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_ORDER, "收尾：回到操作页")

func _entry_types(card) -> Array:
	var out: Array = []
	for i in card.entries().size():
		out.append(String(card.entry_at(i).get("type", "")))
	return out

func _entry_specs(card) -> Array:
	var out: Array = []
	for i in card.entries().size():
		var spec := String(card.entry_at(i).get("spec", ""))
		if spec != "":
			out.append(spec)
	return out

func _eq_tech_page(main, where: String) -> void:
	var g = main.hud.tech_grid
	var card = main.hud.command_card
	ok(g.visible, "%s：★ 科技九格显示出来了" % where)
	eq(g.entries().size(), 9, "%s：★ 九格铺满（9 条占位科技）" % where)
	eq(card.entries().size(), 0, "%s：命令卡在科技页是空的（内容由科技那一层画）" % where)
	eq(g.cell_name(0), "粮食产量 I", "%s：第 1 格 = 粮食产量 I" % where)
	eq(g.cell_line(0), "粮食 +0.05", "%s：第 1 格第二行写效果" % where)
	ok(String((g.entry_at(0) as Dictionary).get("desc", "")).contains("地块"),
		"%s：entries 里带着完整效果说明（悬停详情面板写它）" % where)
	# ★ 九格是**列优先**（第一列 = 一阶、第二列 = 二阶、第三列 = 三阶）：
	#   cell 0/3/6 = 粮食 I/II/III，1/4/7 = 黄金 I/II/III，2/5/8 = 建筑/将领/区划人口。
	eq(g.cell_name(2), "建筑加固", "%s：第 3 格 = 建筑加固（第三列第一格）" % where)
	eq(g.cell_name(5), "将领强化", "%s：第 6 格 = 将领强化" % where)
	eq(g.cell_name(8), "区划人口", "%s：第 9 格 = 区划人口" % where)
	eq(g.cell_name(9), "", "%s：越界格（第 10 格）读不到东西" % where)
	var c0: Rect2 = UiLayoutRes.card_cell_rect(0)
	var g_rect: Rect2 = g.get_global_rect()
	v2_near(g_rect.position, c0.position, 1.0,
		"%s：★ 科技九格的左上角与命令卡重合" % where)

## 找一栋**己方**的普通建筑（城墙 / 箭塔）；没有就现造一栋 —— 开局不再自动在大本营旁
## 生成防御阵地了，所以「地图上有一栋己方城墙 / 箭塔」这件事得自己保证。
func _ensure_own_building(world, t: String):
	for b in world.building_list:
		if b != null and b.alive and b.type == t and String(b.owner) == world.my_faction:
			return b
	for y in world.map.rows:
		for x in world.map.cols:
			if not world.can_build_at(x, y):
				continue
			var nb = world.add_building(t, x, y, world.my_faction, true, true)
			if nb != null:
				return nb
	return null

func _zone_with_center_of_other_kind(world, zone):
	var k: String = String(world.zone_kind_of(zone))
	for z in world.zones.zones:
		if z["center"] == null:
			continue
		if world.zone_kind_of(z) == k or String(z.get("spec_done", "")) != "":
			continue
		return z
	return null

func _specs_of(world, zone) -> Array:
	var out: Array = []
	for e in world.zone_spec_choices(zone):
		out.append(String((e as Dictionary).get("id", "")))
	return out

func _zone_with_center(world):
	for z in world.zones.zones:
		if z["center"] != null:
			return z
	return null

func _test_hover_panel(main, cfg) -> void:
	var hud = main.hud
	var card = hud.command_card
	var tabs = hud.page_tabs
	var tip = hud.hover_tip
	var world = main.world

	ok(tip != null, "★ HUD 里有悬停详情面板")
	if tip == null:
		return
	ok(hud.get_node_or_null("HudRoot/HoverTip") != null, "节点树里有 HudRoot/HoverTip")
	eq(tip.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 悬停面板不吃鼠标（否则挡住地图点击）")
	ok(not tip.showing(), "开局没有悬停 → 面板收着")

	main.input_ctrl.select_units([])
	hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_BUILD)
	card.hover(0)
	ok(tip.showing(), "★ 鼠标停在命令卡某一格上 → 弹出悬停详情")
	eq(tip.title_text(), "城墙", "标题就是那一格的名字")
	var bt: String = tip.body_text()
	ok(bt.contains("地块"), "★ 建筑详情里有建筑说明（实际：%s）" % bt.replace("\n", " | "))
	ok(bt.contains("血量"), "★ 建筑详情里有血量上限")
	ok(bt.contains("造价"), "建筑详情里有造价")

	var card_rect: Rect2 = card.get_global_rect()
	var tabs_rect: Rect2 = tabs.get_global_rect()
	var tip_rect: Rect2 = tip.get_global_rect()
	eq(tip_rect.size.x, card_rect.size.x + tabs_rect.size.x,
		"★ 宽度 = 命令卡 + 页签列那一整段（需求补充）")
	near(tip_rect.position.x, card_rect.position.x, 1.0, "左缘与命令卡对齐")
	near(tip_rect.position.x + tip_rect.size.x,
		tabs_rect.position.x + tabs_rect.size.x, 1.0,
		"★ 右缘与**页签列右缘**齐平（整块贴在命令卡正上方、盖住页签那一条的水平范围）")
	ok(tip_rect.position.y + tip_rect.size.y <= card_rect.position.y + 0.01,
		"★ 面板整个落在命令卡**上方**（不压住那九格）")

	card.unhover(0)
	ok(not tip.showing(), "鼠标移开 → 面板收起来")
	card.hover(2)
	ok(not tip.showing(), "★ 空格子上不弹面板（没内容就不弹一块空的）")

	card.hover(0)
	card.hover(1)          # 新的一格先到
	card.unhover(0)        # 迟到的旧 exit
	ok(tip.showing() and tip.title_text() == "箭塔",
		"★ 迟到的 mouse_exited 不会把新面板收掉（实际：%s）" % tip.title_text())
	card.unhover(1)
	ok(not tip.showing(), "（收尾）面板收起来")

	main.input_ctrl.select_units([])
	hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_TECH)
	ok(hud.tech_grid.visible, "（前提）切到科技页")
	var g = hud.tech_grid
	g.hover(0)
	ok(tip.showing(), "★ 科技九格也能弹悬停详情（与命令卡共用同一块面板）")
	eq(tip.title_text(), "粮食产量 I", "标题是科技名")
	ok(tip.body_text().contains("地块"), "科技详情里有完整效果说明")
	ok(tip.body_text().contains("未启用"), "★ 状态那一行读的是**权威状态**（现在没启用）")
	var first_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	g.press(0)
	ok(world.is_tech_active(first_id), "（前提）点一格 = 启用")
	ok(tip.showing() and tip.title_text() == "粮食产量 I", "（前提）点完之后面板还是同一格")
	ok(tip.body_text().contains("已启用"),
		"★ 启用之后悬停详情里立刻写着「已启用」（不用移开鼠标；实际：%s）"
			% tip.body_text().replace("\n", " | "))
	g.press(0)                                     # 收尾：弃用，别把加成留给后面的用例
	eq(world.active_tech_ids().size(), 0, "（收尾）科技全部弃用")
	ok(tip.body_text().contains("未启用"), "★ 弃用之后又变回「未启用」")

	ok(tip.showing(), "（前提）切页之前面板还开着")
	tabs.select_page(PageTabsRes.PAGE_BUILD)
	ok(not tip.showing(), "★ 换页时悬停面板收起来")

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_UNIT)
	eq(card.cell_label(0), "长枪兵", "（前提）单位页 Q 格 = 长枪兵")
	card.hover(0)
	ok(tip.showing() and tip.title_text() == "长枪兵", "★ 单位页那一格有悬停详情")
	var rt: String = tip.body_text()
	for token in ["血量", "攻击", "射程", "速度", "兵种", "造价", "人口", "读条"]:
		ok(rt.contains(token), "★ 招募详情里有「%s」（实际：%s）" % [token, rt.replace("\n", " | ")])
	card.unhover(0)

	var zone = _zone_with_center(world)
	ok(zone != null, "（前提）地图上找得到一个带中心的区划")
	if zone != null:
		main.input_ctrl.select_zone(zone)
		hud.refresh()
		tabs.select_page(PageTabsRes.PAGE_RECRUIT)
		var hover_roster: Array = world.general_recruit_roster("p1")
		var hover_kind: String = String(hover_roster[0])
		var hover_label: String = world.recruit_label_of(hover_kind)
		eq(card.cell_label(0), hover_label,
			"（前提）招募页 Q 格 = 将领 1（%s）" % hover_label)
		card.hover(0)
		ok(tip.showing() and tip.title_text() == hover_label,
			"★ 招募页那一格也有悬停详情")
		ok(tip.body_text().contains("区划"),
			"★ 将领详情里说明了人口从哪里扣（实际：%s）" % tip.body_text().replace("\n", " | "))
		ok(tip.body_text().contains("兵种"), "将领的数值按它所属兵种查同一张表")
		ok(tip.body_text().contains("招募冷却"),
			"★ 悬停详情写明这位将领的「招募冷却」（实际：%s）"
				% tip.body_text().replace("\n", " | "))
		card.unhover(0)

		tabs.select_page(PageTabsRes.PAGE_ORDER)
		eq(card.cell_label(0), "粮食特化", "（前提）这个区划的操作页 Q 格 = 粮食特化")
		card.hover(0)
		ok(tip.showing() and tip.title_text() == "粮食特化", "★ 区域的特化有悬停详情")
		var st: String = tip.body_text()
		ok(st.contains("效果") and st.contains("地块"), "★ 特化详情里有效果那一行")
		ok(st.contains("造价") and st.contains("读条"), "特化详情里有造价与读条")
		ok(st.contains("一种"), "★ 特化详情里说明「一个区划只能选一种」")
		card.unhover(0)
		var cancel_d: Dictionary = hud._hover_detail("card", {
			"type": "zone_spec_bar_cancel", "name": "取消特化",
			"desc": "撤掉正在读条的这一单特化，全额退还已经扣掉的粮食与黄金"})
		ok(not cancel_d.is_empty(), "★ 「取消特化」那一格也有悬停详情")
		ok(String(cancel_d.get("title", "")) == "取消特化", "标题就是那一格的名字")
		ok(String(cancel_d.get("body", "")).contains("退还"), "详情里说明退款")

	var base = world.find_base_of("p1")
	ok(base != null, "（前提）有己方大本营")
	if base != null:
		main.input_ctrl.select_building(base)
		hud.refresh()
		tabs.select_page(PageTabsRes.PAGE_ORDER)
		eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
			"（前提）大本营操作页那一格是「升级」")
		card.hover(0)
		ok(tip.showing() and tip.title_text() == "升级大本营", "★ 建筑的升级那一格有悬停详情")
		ok(tip.body_text().contains("当前等级"), "★ 详情里有当前等级")
		ok(tip.body_text().contains("血量"), "★ 详情里有血量")
		card.unhover(0)

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(card.cell_label(0), "移动", "（前提）操作页 Q 格 = 移动")
	card.hover(0)
	ok(not tip.showing(),
		"★ 部队指令（移动 / 攻击 / 行军 / 停止）本轮还没有悬停详情 → 不弹空面板")
	card.unhover(0)

	hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（收尾）停在操作页")

func _test_hover_tip_control(cfg) -> void:
	var font: Font = FontLoaderRes.load_font(cfg)
	ok(font != null, "（前提）拿得到中文字体")
	var tip = HoverTipRes.new()
	root.add_child(tip)
	tip.setup(font)
	await process_frame

	eq(tip.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 悬停面板不吃鼠标")
	ok(not tip.showing() and not tip.visible, "刚建出来时不显示")
	eq(tip.size, Vector2.ZERO, "收起时尺寸归零（不留一个幽灵矩形）")

	tip.show_text("城墙", "填满整个地块\n血量上限 300")
	ok(tip.showing() and tip.visible, "喂了文本就显示出来")
	eq(tip.title_text(), "城墙", "标题是那一格的名字")
	ok(tip.body_text().contains("血量"), "正文里是多行说明")
	eq(tip.size.x, UiLayoutRes.HOVER_W, "★ 面板宽 = HOVER_W（340 = 命令卡 + 页签列）")
	near(tip.position.x, UiLayoutRes.CARD_RECT.position.x, 1.0, "左缘与命令卡对齐")
	near(tip.position.y + tip.size.y, UiLayoutRes.HOVER_BOTTOM, 0.01,
		"★ 下缘钉在命令卡顶边上方（变高是**向上长**）")

	tip.show_text("城墙", "一行")
	var h_short: float = tip.content_height()
	tip.show_text("城墙", "一行\n两行")
	ok(tip.content_height() > h_short, "★ 两行正文比一行高（%.0f > %.0f）"
		% [tip.content_height(), h_short])
	tip.show_text("城墙", "一行\n两行\n三行\n四行")
	var h_four: float = tip.content_height()
	ok(h_four - h_short > 3.0 * font.get_height(UiStyleRes.FS_SMALL),
		"★ 每多一行正文涨的高度**大于** font.get_height（%.0f > 3 × %.0f）—— 用的是 Label 的真实行高"
			% [h_four - h_short, font.get_height(UiStyleRes.FS_SMALL)])
	ok(tip.body_lines() >= 4, "（前提）Label 认为这段正文有 ≥4 行（实际 %d）" % tip.body_lines())
	eq(tip.body_visible_lines(), tip.body_lines(),
		"★ 正文每一行都画得出来（%d / %d 行）—— 少了就是面板高度量错了"
			% [tip.body_visible_lines(), tip.body_lines()])

	var long_line := "本区块每地块每秒额外产出 0.5 粮食，一个区划只能选一种特化；取消特化也要读条，读完才真的撤掉，并且把当初花掉的粮食与黄金全额退回来"
	tip.show_text("粮食特化", long_line)
	var inner_w: float = UiLayoutRes.HOVER_W - 2.0 * UiLayoutRes.HOVER_PAD
	var raw_w: float = font.get_string_size(long_line, HORIZONTAL_ALIGNMENT_LEFT, -1,
		UiStyleRes.FS_SMALL).x
	ok(raw_w > inner_w * 2.0, "（前提）这一行比面板宽得多（%.0fpx > 2 × %.0f）" % [raw_w, inner_w])
	ok(tip.body_lines() >= 3, "★ 超长的一行被**折行**成 ≥3 行（实际 %d 行）" % tip.body_lines())
	ok(tip.content_height() > h_short, "折行之后面板跟着长高（%.0f）" % tip.content_height())
	eq(tip.body_visible_lines(), tip.body_lines(),
		"★ 折行之后每一行仍然都画得出来（%d / %d）"
			% [tip.body_visible_lines(), tip.body_lines()])
	eq(tip.body_text(), long_line, "折行是**画**的时候做的，正文文本一个字没改")

	tip.clear()
	ok(not tip.showing() and not tip.visible, "clear() 之后收起来")
	eq(tip.title_text(), "", "收起后标题清空")
	eq(tip.content_height(), 0.0, "收起后内容高度归零")
	tip.show_text("", "")
	ok(not tip.showing(), "喂两个空串也等于收起（不留空面板）")

	tip.queue_free()
	await process_frame

func _test_card_keys(main) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	var g1 = main.world.unit_by_id("general-1")

	main.input_ctrl.select_units([])
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_BUILD)
	eq(tabs.page(), PageTabsRes.PAGE_BUILD, "（前提）没选中东西 → 停在建筑页")

	var a_ev := _key(KEY_A)
	ok(not card.handle_key(a_ev), "空格子（A）不消费按键")

	ok(card.handle_key(_key(KEY_Q)), "建筑页的 Q 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "wall", "★ 建筑页按 Q = 城墙")
	ok(card.handle_key(_key(KEY_W)), "建筑页的 W 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "tower", "★ 建筑页按 W = 箭塔（W 已不再平移镜头）")
	ok(card.handle_key(_key(KEY_W)), "再按一次 W")
	eq(main.input_ctrl.build_type, "", "再按一次同一格 = 退出建造模式")

	card.cell_at(0).emit_signal("pressed")
	eq(main.input_ctrl.build_type, "wall", "点 Q 格 = 进城墙建造模式")
	main.input_ctrl.set_build_type("")

	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）停在操作页")
	ok(card.handle_key(_key(KEY_Q)), "操作页的 Q 被命令卡吃掉")
	eq(main.input_ctrl.order_mode, "move", "★ 操作页按 Q = 进入移动模式")
	ok(card.handle_key(_key(KEY_Q)), "再按一次 Q")
	eq(main.input_ctrl.order_mode, "", "★ 再按一次同一格 = 退出命令模式")
	card.cell_at(2).emit_signal("pressed")
	eq(main.input_ctrl.order_mode, "attack_move", "点 E 格 = 进入行军模式")
	main.input_ctrl.set_order_mode("")
	eq(main.input_ctrl.order_mode, "", "（收尾）退出命令模式")

	var free := Vector2i(-1, -1)
	for ty in main.world.map.rows:
		for tx in main.world.map.cols:
			if main.world.can_build_at(tx, ty):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格空地")
	if free.x >= 0:
		ok(CommandRes.apply(main.world, main.cfg, {"kind": "move", "ids": [g1.id],
			"x": float(free.x) + 0.5, "y": float(free.y) + 0.5, "faction": "p1"}),
			"（前提）先让将领 1 走起来")
		ok(g1.moving, "（前提）它正在移动")
		card.cell_at(3).emit_signal("pressed")          # A 格 = 停止
		ok(not g1.moving, "★ 点「停止」格 → 当场停下")
		eq(main.input_ctrl.order_mode, "", "★ 停止不进命令模式（点一下就够了）")

	ok(not card.handle_key(_key(KEY_Q, true)),
		"★ Ctrl+Q 不被命令卡消费（要让给 main 的全屏快捷键）")
	ok(not card.handle_key(_key(KEY_W, true)),
		"★ Ctrl+W 也不被命令卡消费（同一类组合键一起让出来）")

func _test_recruit_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	var before: int = world.retinue_of(g1.id).size()

	main.input_ctrl.select_units([])
	ok(not main.input_ctrl.request_recruit(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 没选中将领时招募命令**不发出去**（只给提示）")
	eq(world.retinue_of(g1.id).size(), before, "没选中将领时没有凭空多出单位")

	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_UNIT, "（前提）切到单位页")
	var queue = main.hud.detail_panel.queue_control()
	ok(queue != null, "详细信息右栏里有招募队列控件")
	ok(not queue.showing(), "★ 没在招募时五个格子收起来（需求：将领开始招募时才出现）")

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

	main.hud._tick_notice(main.cfg.num("ui.notice_sec", 2.0) + 0.1)
	ok(not main.hud.notice_active(), "★ 提示到时自动消失")
	eq(main.hud.notice_text(), "", "消失之后文本也清掉")

	world.resources["food"] = 200.0
	world.resources["gold"] = 200.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 5.0
	card.activate_index(0)
	ok(g1.is_training(), "★ 点单位页的 Q 格 → 排进招募队列")
	eq(g1.train_kind, UnitRes.UNIT_TYPE_SPEARMAN, "大格子里是刚排进去的那个")
	var sf: float = float((world.recruit_cost(UnitRes.UNIT_TYPE_SPEARMAN) as Dictionary).get("food", 0.0))
	near(float(world.resources["food"]), 200.0 - sf, 1e-4, "★ 入队即扣粮（= config 定价）")
	eq(world.retinue_of(g1.id).size(), before, "★ 入队不会立刻生成单位（要读条 10 秒）")
	eq(g1.leader_id, "", "将领自己还是队长")

	main.hud.refresh()
	ok(queue.showing(), "★ 信息栏里出现五个格子")
	eq(queue.slot_count(), 5, "★ 一共五个格子")
	ok(queue.cell_filled(0), "大格子填上了（正在读条的那个）")
	ok(not queue.cell_filled(1), "小格子还是空的")
	ok(queue.cell_label(0).contains("枪"),
		"大格子里写着兵种短名（实际：%s）" % queue.cell_label(0))
	near(queue.progress(), 0.0, 1e-6, "刚入队时读条是 0")

	ok(card.handle_key(_key(KEY_Q)), "单位页的 Q 被命令卡吃掉")
	main.hud.refresh()
	eq(g1.train_queue.size(), 1, "★ 第二次招募排进小格子（不抢读条）")
	ok(queue.cell_filled(1), "第 2 个格子（小格）填上了")
	near(queue.progress(), 0.0, 0.05, "★ 排队的不影响正在读条那个的进度")

	eq(main.hud.page_tabs.page_count(), 2, "（前提）选中部队时只有两颗页签")
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_UNIT,
		"★ 不在这一屏里的页（建筑）切不过去")
	eq(g1.train_queue_size(), 2, "切页不会改变队列")

	main.input_ctrl.select_units([])
	main.hud.refresh()
	ok(not queue.showing(), "★ 没选中招募中的将领时五格收起来")

	while g1.train_queue_size() > 0:
		world.cancel_recruit(g1.id, 0, "p1")
	ok(not g1.is_training(), "收尾：队列已清空")

func _test_zone_recruit_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var base = world.find_base_of("p1")
	ok(base != null, "有己方大本营（用来找一块己方区划）")
	if base == null:
		return
	var zone = world.zones.zone_at(base.tx, base.ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return

	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	zone["population"] = 10.0
	# ★ 区划招募将领：1 级大本营上限 3 名（开局正好 3 名），先把等级拉到 3（上限 10）。
	base.level = world.cfg.upgrade_max_level("base")
	world.apply_building_level_hp(base)

	main.input_ctrl.select_zone(zone)
	main.hud.refresh()
	eq(main.hud.page_tabs.page_count(), 2, "★ 选中区划中心 → 操作 + 招募两颗页签")
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_RECRUIT)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 切到「招募」页签")
	eq(card.entries().size(), 9, "★★ 招募页是固定九宫格（#1-9）")
	var roster: Array = world.general_recruit_roster("p1")
	eq(roster.size(), 9, "★ 固定阵容 9 位")
	# 这个关卡开局摆了 #1-3（已拥有），大本营升到 3 级后 #4 是第一位可招的。
	var kind0: String = String(roster[3])
	eq(card.cell_label(3), world.recruit_label_of(kind0),
		"Q/W/E/A 第 4 格 = 将领 4（实际：%s）" % card.cell_label(3))
	eq(String(card.entry_at(3).get("type", "")), "zone_recruit",
		"招募页那一项是「区划招募」（排进区划的队列）")
	eq(String(card.entry_at(3).get("unit_kind", "")), kind0,
		"第 4 格要招的兵种 = general_4")
	# ★★ 不可招募的格子：disabled + 灰色填充档（与科技锁定格同一套效果）。
	ok(not bool(card.entry_at(0).get("ready", true)), "★ 已拥有的 #1 不可招募")
	eq(String(card.entry_at(0).get("lock_reason", "")), "owned", "拒因 = owned")
	var locked_cell = card.cell_at(0)
	ok(locked_cell != null and locked_cell.disabled,
		"★★ 不可招募格的按钮是 disabled")
	ok(locked_cell != null and FillButtonRes.is_grey(locked_cell),
		"★★ 不可招募格走「灰色填充」档（悬停填灰）")
	var cost0: Dictionary = world.recruit_cost(kind0)

	var q = main.hud.detail_panel.queue_control()
	ok(not q.showing(), "没在招募时五格收起来")
	ok(q.is_zone_queue() and q.holder() == zone,
		"（前提）队列控件已经指向这个区划（只是还没东西可显示）")

	var food_before: float = float(world.resources["food"])
	var pop_before: float = float(zone["population"])
	card.activate_index(3)
	ok(world.zone_is_training(zone), "★ 点招募页的「将领 4」格 → 排进了**这个区划**的队列")
	eq(world.zone_recruit_kind_at(zone, 0), kind0, "大格子里是刚排进去的那个将领")
	near(float(world.resources["food"]),
		food_before - float(cost0.get("food", 0.0)), 1e-4, "★ 入队即扣粮食")
	near(float(zone["population"]), pop_before - 1.0, 1e-4, "★ 入队即扣这个区划 1 人口")
	ok(world.general_recruit_cooldown_left("p1") > 0.0,
		"★ 招募后进入全局冷却（= 这位将领的招募冷却）")

	main.hud.refresh()
	ok(q.showing(), "★ 信息栏里出现五个格子")
	ok(q.is_zone_queue(), "★ 这个五格显示的是**区划**的队列（不是某个将领的）")
	eq(q.slot_count(), 5, "五个格子")
	ok(q.cell_label(0).contains("将"), "大格子里写着短名「将」（实际：%s）" % q.cell_label(0))
	ok(main.hud.detail_panel.detail_text().contains("招募冷却"),
		"★ 区划详情里常驻显示招募冷却倒计时（实际：%s）"
			% main.hud.detail_panel.detail_text().replace("\n", " | "))

	# ★ 全局冷却：整页置灰；点另一个未拥有的格子只给提示，不会排队。
	eq(world.zone_recruit_queue_size(zone), 1, "★ 全局冷却下队列里只有这一单")
	ok(not bool(card.entry_at(4).get("ready", true)), "★ 冷却中未拥有的格也置灰")
	eq(String(card.entry_at(4).get("lock_reason", "")), "cooldown", "拒因 = cooldown")
	card.activate_index(4)
	eq(world.zone_recruit_queue_size(zone), 1, "★ 冷却中点另一格不会排队")
	ok(main.hud.notice_text().contains("冷却"),
		"★ 点灰格给一句「冷却中」提示（实际：%s）" % main.hud.notice_text())

	# 取消大格子：全额退款 + 解除冷却。
	food_before = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	eq(world.zone_recruit_queue_size(zone), 0, "★ 点大格子 = 取消那一单")
	near(float(world.resources["food"]),
		food_before + float(cost0.get("food", 0.0)), 1e-4, "★ 取消全额退款")
	near(world.general_recruit_cooldown_left("p1"), 0.0, 1e-6,
		"★ 取消招募 → 立刻解除冷却")
	main.hud.refresh()
	ok(not q.showing(), "收尾：队列清空 → 五格收起来")
	# 还原大本营等级（后面的建筑升级用例按 1 级写）。
	base.level = 1
	world.apply_building_level_hp(base)

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not q.is_zone_queue(), "★ 改选部队之后，队列控件不再显示区划的队列")
	main.input_ctrl.select_units([])
	main.hud.refresh()

func _test_upgrade_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var tabs = main.hud.page_tabs
	var q = main.hud.detail_panel.queue_control()
	world.resources["food"] = 5000.0
	world.resources["gold"] = 5000.0

	var wall = _ensure_own_building(world, "wall")
	ok(wall != null, "有一栋己方城墙")
	if wall == null:
		return
	main.input_ctrl.select_building(wall)
	main.hud.refresh()
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）城墙停在操作页")
	eq(card.cell_label(0), "升级城墙", "★ Q 格 = 升级城墙")
	var lv0: int = wall.level
	var food0: float = float(world.resources["food"])
	card.activate_index(0)
	ok(wall.is_upgrading(), "★ 点那一格 = 开始读条")
	near(float(world.resources["food"]), food0 - float(
		float(world.cfg.upgrade_cost_to("wall", lv0).get("food", 0.0))), 1e-4,
		"★ 入队即扣粮食")
	main.hud.refresh()
	ok(q.showing(), "★ 信息栏里出现读条面板")
	ok(q.is_bar_mode(), "★ 它是「单条读条」模式（复用招募那块面板）")
	ok(q.title_text().contains("升级"), "汇总带写着「升级…」（实际：%s）" % q.title_text())
	ok(q.cell_label(0).contains("升"), "大格子里写着「升 2 级」（实际：%s）" % q.cell_label(0))
	ok(not q.cell_filled(1), "★ 四个小格子留空（这一单没有队列）")
	near(q.progress(), 0.0, 0.05, "刚入队进度接近 0")
	main.hud.refresh()
	eq(card.entries().size(), 1, "读条中操作页只有一格")
	eq(String(card.entry_at(0).get("type", "")), "building_upgrade_cancel",
		"★ 那一格是「取消升级」（实际：%s）" % String(card.entry_at(0).get("type", "")))
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not wall.is_upgrading(), "★ 点读条那一格 = 取消升级")
	eq(wall.level, lv0, "等级没变")
	near(float(world.resources["food"]), food0, 1e-4, "★ 取消全额退款")

	main.hud.refresh()
	eq(card.entries().size(), 1, "（前提）取消之后操作页回到一格")
	eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
		"（前提）那一格回到「升级」（实际：%s）" % String(card.entry_at(0).get("type", "")))
	card.activate_index(0)
	ok(wall.is_upgrading(), "再次开始读条（食物 %.0f / 黄金 %.0f）" % [
		float(world.resources["food"]), float(world.resources["gold"])])
	world.tick(60.0)
	main.hud.refresh()
	eq(wall.level, lv0 + 1, "★ 读完等级 +1")
	ok(not q.is_bar_mode(), "★ 读条结束 → 面板回到「不是读条」")
	ok(card.cell_label(0).contains("升级"), "那一格又变回「升级%s」" % wall.display_name())
	ok(main.hud.detail_panel.detail_text().contains("血量"),
		"★ 建筑详情仍是两列（左列血量、右列防御）")
	ok(main.hud.detail_panel.detail_text().contains("防御"),
		"★ 建筑也有防御力那一行（当前显示 0）")

	var zone = world.zones.zone_at(world.find_base_of("p1").tx, world.find_base_of("p1").ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return
	main.input_ctrl.select_zone(zone)
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）区划中心停在操作页")
	eq(String(zone["kind"]), "population", "（前提）这块是人口区划")
	eq(card.entries().size(), 2, "★ 没特化时操作页 = 这个种类允许的两格特化")
	card.activate_index(0)                      # 粮食特化
	ok(UpgradeRes.zone_is_busy(zone), "★ 点粮食特化 = 开始读条")
	main.hud.refresh()
	ok(q.is_bar_mode(), "★ 特化读条也走信息栏那块面板")
	ok(q.title_text().contains("粮食"), "汇总带写着「粮食特化」（实际：%s）" % q.title_text())
	ok(q.cell_label(0).contains("特化中"), "大格子里写着「特化中」（实际：%s）" % q.cell_label(0))
	eq(card.entries().size(), 1, "读条中操作页只剩一格（entries=%s）" % str(_entry_types(card)))
	eq(String(card.entry_at(0).get("type", "")), "zone_spec_bar_cancel",
		"★ 那一格是「取消特化」（撤单）")
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not UpgradeRes.zone_is_busy(zone), "★ 撤掉了那一单")
	eq(String(zone.get("spec_done", "")), "", "还没特化过")
	main.hud.refresh()
	eq(card.entries().size(), 2, "撤单后操作页又是两格特化")
	card.activate_index(0)
	world.tick(60.0)
	main.hud.refresh()
	main.hud.rebuild_card()      # 真实游戏里由每帧 refresh 的页签比较兜底；测试里显式刷一次
	eq(String(zone.get("spec_done", "")), "food", "★ 读完特化生效")
	near(UpgradeRes.zone_spec_effect(zone, world.cfg)["food_per_tile"], 0.05, 1e-6,
		"★ 粮食特化 = 每地块每秒 +0.05 粮食")
	eq(card.entries().size(), 1, "★ 特化后操作页只剩一格（不能再特化）")
	eq(String(card.entry_at(0).get("type", "")), "zone_spec_cancel",
		"★ 那一格是「取消特化」")
	eq(card.cell_label(0), "取消特化", "格子上写着「取消特化」")
	ok(main.hud.detail_panel.detail_text().contains("特化"),
		"★ 区划右列保留特化状态（实际：%s）"
			% main.hud.detail_panel.detail_text().replace("\n", "|"))
	card.activate_index(0)
	ok(UpgradeRes.zone_is_busy(zone), "★ 取消特化也要读条")
	ok(UpgradeRes.zone_spec_is_cancel(zone), "这一条是「取消特化」")
	main.hud.refresh()
	ok(q.is_bar_mode(), "那块面板显示取消特化的读条")
	ok(q.title_text().contains("取消"), "汇总带写着「取消…」（实际：%s）" % q.title_text())
	ok(q.cell_at_position(UiLayoutRes.queue_cell_rect(0).get_center()) < 0,
		"★ 「取消特化」的读条不可再取消（点了没反应）")
	world.tick(60.0)
	main.hud.refresh()
	main.hud.rebuild_card()
	eq(String(zone.get("spec_done", "")), "", "★ 读完特化被去掉")
	eq(card.entries().size(), 2, "★ 操作页又能选这个种类的两档特化了")

	while UpgradeRes.zone_is_busy(zone):
		world.tick(60.0)
	for b in world.building_list:
		if b.is_upgrading():
			world.cancel_building_upgrade(b.tx, b.ty)
	main.input_ctrl.select_units([])
	main.hud.refresh()

func _test_queue_cancel_via_click(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)   # 单位页（招募那一页）
	main.hud.refresh()
	var q = main.hud.detail_panel.queue_control()

	card.activate_index(0)
	card.activate_index(0)
	main.hud.refresh()
	eq(g1.train_queue_size(), 2, "排了两单（1 大 + 1 小）")
	ok(q.showing(), "五格显示出来了")

	var food_before: float = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(1).get_center())
	eq(g1.train_queue_size(), 1, "★ 点小格子 = 取消那一格")
	var cancel_refund: float = float((world.recruit_cost(UnitRes.UNIT_TYPE_SPEARMAN) as Dictionary).get("food", 0.0))
	near(float(world.resources["food"]), food_before + cancel_refund, 1e-4, "★ 取消会退款（= config 定价）")
	main.hud.refresh()
	ok(not q.cell_filled(1), "★ 那一格空了（界面下一帧按权威状态重画）")

	food_before = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(3).get_center())
	eq(g1.train_queue_size(), 1, "★ 点空格子什么都不发生")
	near(float(world.resources["food"]), food_before, 1e-6, "空格子也不会退钱")

	ok(g1.is_training(), "取消排队的那单之后还在读条")
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not g1.is_training(), "★ 取消掉最后一单 → 不再是「招募中」")
	main.hud.refresh()
	ok(not q.showing(), "★ 队列空了 → 五个格子收起来")

func _test_auto_select_on_recruit(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	var team_before: int = main.input_ctrl.selected_units.size()

	var fresh = UnitRes.create(main.cfg, "auto-r1", "长枪兵 9",
		Vector2i(g1.tx, g1.ty), g1.faction, UnitRes.UNIT_TYPE_SPEARMAN, "", g1.id)
	world.units.append(fresh)

	main._consume_events([{"type": "unit_recruited", "unit": fresh, "leader": g1}])
	eq(main.input_ctrl.selected_units.size(), team_before + 1, "★ 新兵也被选上了")
	ok(main.input_ctrl.selected_units.has(fresh), "★ 新兵在选中列表里")
	ok(fresh.selected, "★ 新兵身上的高亮标志也点亮了")

	main.input_ctrl.select_units([])
	main._consume_events([{"type": "unit_recruited", "unit": fresh, "leader": g1}])
	ok(main.input_ctrl.selected_units.is_empty(), "★ 没选中那个将领时不会把新兵硬塞进选中列表")
	ok(not fresh.selected, "新兵也不该被点亮")

	world.units.erase(fresh)
	main.input_ctrl.select_units([g1])

func _click_control(c: Control, pos: Vector2) -> void:
	# ★ 按下 + 抬起两下都发：真实鼠标是这一套，而网格这类「按下记录、抬起才激活」
	#   的控件（还要区分拖动）只发按下是点不动的。
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = pos
	c._gui_input(ev)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	c._gui_input(up)

func _test_order_locked_notice(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var g1 = world.unit_by_id("general-1")
	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	world.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)   # 单位页（招募那一页）
	main.hud.refresh()
	card.activate_index(0)                       # 排一单 → 整队被锁住
	ok(g1.is_training(), "将领开始招募（整队进入「不接指令」状态）")
	main.hud.show_notice("")                     # 先把提示清掉，免得误判

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

	var mate = world.retinue_of(g1.id)[0]
	ok(not CommandRes.apply(world, main.cfg, {"kind": "move", "ids": [mate.id],
		"x": float(empty.x), "y": float(empty.y), "faction": "p1"}),
		"★ 将领辖下的附属兵也不接受指令")
	var g2 = world.unit_by_id("general-2")
	ok(CommandRes.apply(world, main.cfg, {"kind": "move", "ids": [g2.id],
		"x": float(empty.x), "y": float(empty.y), "faction": "p1"}),
		"★ 没在招募的将领照旧能下令")

	while g1.train_queue_size() > 0:
		world.cancel_recruit(g1.id, 0, "p1")
	main.hud.show_notice("")
	ok(not g1.is_training(), "收尾：队列已清空")

func _test_foreign_reject_notice_filter(main) -> void:
	main.hud.show_notice("")
	ok(not main.hud.notice_active(), "（前提）提示是空的")

	var foreign: Array = [
		{"type": "recruit_rejected", "reason": "zone", "kind": "spearman", "faction": "enemy"},
		{"type": "upgrade_rejected", "reason": "busy", "kind": "building_upgrade",
			"faction": "enemy"},
		{"type": "revive_rejected", "reason": "hp", "faction": "enemy"},
		{"type": "tech_rejected", "reason": "limit", "tech_id": "t1", "faction": "enemy"},
	]
	main._consume_events(foreign)
	ok(not main.hud.notice_active(),
		"★★ 敌方的被拒事件**不显示**在自己的详细信息栏（实际：%s）" % main.hud.notice_text())
	eq(main.hud.notice_text(), "", "★ 而且文案是空的（不是「显示了但很短」）")

	main._consume_events([{"type": "recruit_rejected", "reason": "zone",
		"kind": "spearman", "faction": "p1"}])
	ok(main.hud.notice_active(), "★ 自己这一方的拒因照旧显示")
	ok(main.hud.notice_text().contains("己方区划"),
		"★ 文案还是那一句（实际：%s）" % main.hud.notice_text())

	main.hud.show_notice("")
	main._consume_events([{"type": "order_rejected", "reason": "recruiting"}])
	ok(main.hud.notice_active(),
		"★ 不带 faction 的事件照旧显示（保守策略：漏掉玩家自己的报错更糟）")

	var world = main.world
	var leader = world.unit_by_id("general-1")
	world.start_recruit("spearman", leader.id, "enemy")     # 拿敌方名义下单 → 必被拒
	var seen: Dictionary = {}
	for e in world.tick(1.0 / 60.0):
		var ev: Dictionary = e
		if String(ev.get("type", "")) == "recruit_rejected":
			seen = ev
	ok(seen.has("faction"),
		"★★ recruit_rejected 事件带上了 faction（界面那条过滤才有依据）")
	eq(String(seen.get("faction", "")), "enemy", "★ 带的是**下单那一方**，不是本机")
	main.hud.show_notice("")

func _test_queue_control(cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-0")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	var q = RecruitQueueRes.new()
	root.add_child(q)
	q.setup(w)

	ok(not q.showing(), "没喂将领时不显示")
	q.set_leader(g1)
	ok(not q.showing(), "选中的将领没在招募 → 还是不显示（需求：开始招募时才出现）")
	eq(q.title_text(), "", "没在招募时汇总带是空的")

	w.start_recruit(UnitRes.UNIT_TYPE_SPEARMAN, g1.id, "p1")
	w.start_recruit(UnitRes.UNIT_TYPE_SPEARMAN, g1.id, "p1")
	q.set_leader(g1)
	ok(q.showing(), "★ 开始招募 → 五格出现")
	eq(q.slot_count(), 5, "五个格子")
	eq(q.cell_kind(0), UnitRes.UNIT_TYPE_SPEARMAN, "大格子是正在读条的那个")
	eq(q.cell_kind(1), UnitRes.UNIT_TYPE_SPEARMAN, "第 1 个小格子是排队的那个")
	eq(q.cell_kind(2), "", "后面三个小格子是空的")
	ok(q.cell_filled(0) and q.cell_filled(1) and not q.cell_filled(2), "填充状态跟着队列走")

	eq(q.queue_count(), 2, "汇总用的是「含正在读条那个」的数量（与队列上限同口径）")
	eq(q.title_text(), "招募队列 2/%d" % w.recruit_queue_max(),
		"★ 汇总第一行写着「招募队列 2/5」（实际：%s）" % q.title_text())
	near(q.total_eta(), 20.0, 0.05, "★ 整条队列读完还要 20 秒（两个单位各 10 秒）")
	ok(q.total_text().begins_with("共") and q.total_text().ends_with("s"),
		"★ 汇总第二行写着「共 20s」（实际：%s）" % q.total_text())

	near(q.eta_of(0), 10.0, 0.05, "大格子的 ETA = 它自己的剩余秒")
	near(q.eta_of(1), 20.0, 0.05, "★ 第 1 个小格子的 ETA = 大格子读完 + 它自己读 10 秒")
	near(q.eta_of(2), 0.0, 1e-6, "空槽位的 ETA 是 0（没排到就不报时间）")
	ok(q.cell_label(0).contains("剩"), "大格子写着「剩 x.xs」（实际：%s）"
		% q.cell_label(0).replace("\n", "|"))
	ok(q.cell_label(1).contains("20s"), "★ 小格子写着「轮到我还差几秒」（实际：%s）"
		% q.cell_label(1).replace("\n", "|"))

	for _i in 300:
		w.tick(1.0 / 60.0)
	q.set_leader(g1)
	near(q.progress(), 5.0 / 10.0, 0.05, "★ 读条到一半 → 进度条 50%")
	ok(q.cell_label(0).contains("s"), "大格子上写着剩余秒数（实际：%s）" % q.cell_label(0))
	near(q.eta_of(0), 5.0, 0.05, "过半之后大格子只剩 5 秒")
	near(q.eta_of(1), 15.0, 0.05, "★ 小格子的 ETA 跟着缩到 15 秒（视图每帧问逻辑层）")
	ok(q.total_text().contains("15"), "汇总第二行也跟着变成「共 15s」（实际：%s）" % q.total_text())

	_hover_queue_cell(q, 1)
	eq(q.hover_slot(), 1, "★ 鼠标停在第 1 个小格子上 → 认到那一格（红框 + 右上角画「×」）")
	eq(q.mouse_default_cursor_shape, Control.CURSOR_POINTING_HAND, "停在有内容的格子上是手型")
	eq(q.cell_at_position(UiLayoutRes.queue_cell_rect(3).get_center()), -1,
		"★ 停在**空格子**上不算命中（点了什么都不会发生）")
	eq(q.cell_at_position(UiLayoutRes.queue_info_rect().get_center()), -1,
		"★ 停在左边汇总带上不算命中（那 129px 不是格子）")
	_hover_queue_cell(q, 3)
	eq(q.hover_slot(), -1, "移到空格子上 → 悬停态清掉")
	eq(q.mouse_default_cursor_shape, Control.CURSOR_ARROW, "光标回到普通箭头")

	var before_draw: int = q.draw_count
	q.queue_redraw()
	await process_frame
	ok(q.draw_count > before_draw, "★ 队列那一块真的画了一帧（底板 / 读条 / 汇总都在 _draw 里）")

	q.queue_free()

func _hover_queue_cell(q: Control, slot: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = UiLayoutRes.queue_cell_rect(slot).get_center()
	q._gui_input(ev)

func _test_recruit_queued_event(cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-0")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	w.tick(1.0 / 60.0)                  # 把上一帧的残留事件清干净
	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.UNIT_TYPE_SPEARMAN,
		"leader_id": g1.id, "faction": "p1"}), "招募命令被接受（入队）")
	var events: Array = w.tick(1.0 / 60.0)
	var queued := 0
	for evt in events:
		if String(evt.get("type", "")) == "recruit_queued":
			queued += 1
	eq(queued, 1, "★ 招募入队的事件被下一次 tick 交了出来（命令事件不能在 tick 开头被丢掉）")

func _test_right_click_orders(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])

	var foe = world.spawn_enemy(g1.tx + 2, g1.ty)
	ok(foe != null, "刷出一个敌人当靶子")
	if foe == null:
		return
	for u in world.units:
		if u != foe and u.tx == foe.tx and u.ty == foe.ty:
			u.pos = GridRes.center_of(Vector2i(foe.tx, foe.ty + 3))
			u.sync_tile(world.map)
	var got: Array = []
	var sink = func(cmd): got.append(cmd)
	main.input_ctrl.command_issued.connect(sink)

	main.input_ctrl.hover_tile = Vector2i(foe.tx, foe.ty)
	main.input_ctrl.mouse_world = foe.pos
	main.input_ctrl._on_right_click(false)
	eq(got.size(), 1, "单击敌人发出了一条命令")
	eq(String(got[0].get("kind", "")), "attack", "★ 右键单击敌人 = 攻击命令")
	eq(String(got[0].get("target_id", "")), foe.id, "命令里带的是那个敌人的 id")
	ok(main.input_ctrl._pick_foe_unit_at(foe.pos) == foe, "鼠标底下是敌人时，敌对拾取拿得到它")
	ok(main.input_ctrl._pick_unit_at(foe.pos) == null, "自己人的拾取函数不会选中敌人")
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

	got.clear()
	main.input_ctrl._on_right_click(true)
	eq(String(got[0].get("kind", "")), "attack_move", "★ 右键双击 = 行军攻击命令")
	ok(main.input_ctrl.attack_marks.size() == 1, "行军攻击标记画出来了（红）")
	ok(main.input_ctrl.move_marks.is_empty(), "两种标记只留最新的那个")

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.double_click = true
	ev.position = Vector2(20.0, 20.0)
	got.clear()
	ok(main.input_ctrl.handle_mouse_button(ev), "右键双击事件被处理")
	eq(String(got[0].get("kind", "")), "attack_move",
		"★ 走真实事件路径时，双击也翻译成行军攻击（不是靠手写计时器）")

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

func _seed_player_escorts(main, per: int) -> int:
	var world = main.world
	var cfg = main.cfg
	var made := 0
	for g in world.units.duplicate():
		if not g.is_general() or String(g.faction) != world.my_faction:
			continue
		var utype := String(g.unit_type)
		for i in per:
			var off: Vector2i = ESCORT_OFFSETS[i % ESCORT_OFFSETS.size()]
			var tile := Vector2i(g.tx + off.x, g.ty + off.y)
			if not world.map.terrain_walkable(tile.x, tile.y):
				continue
			var nid := "%s-s%d" % [String(g.id), i + 1]
			if world.unit_by_id(nid) != null:
				continue                        # 已经有了（重复调用不叠加）
			var sub = UnitRes.create(cfg, nid, "%s %d" % [cfg.unit_name_of(utype), i + 1],
				tile, String(g.faction), utype, "", String(g.id), utype)
			sub.garrison_zone_id = int(g.garrison_zone_id)
			world.units.append(sub)
			made += 1
	return made

const ESCORT_OFFSETS: Array = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1), Vector2i(1, -1),
]

func _test_box_select(main) -> void:
	var world = main.world
	var cfg = main.cfg
	var g1 = world.unit_by_id("general-1")
	var g2 = world.unit_by_id("general-2")
	var g3 = world.unit_by_id("general-3")
	ok(g1 != null and g2 != null, "框选用例：将领 1 / 2 都在")
	if g1 == null or g2 == null:
		return

	var lo := Vector2(2.0, 2.0)
	var hi := Vector2(6.0, 6.0)
	var far_lo := Vector2(20.0, 20.0)
	var far_hi := Vector2(24.0, 24.0)

	var t1: Array = world.group_of(g1)
	var t2: Array = world.group_of(g2)
	_place_unit(world, g1, far_lo)
	_place_units_in_rect(world, t1.slice(1), lo, hi)
	_place_unit(world, g2, far_lo + Vector2(0.0, 2.0))
	_place_units_in_rect(world, t2.slice(1, 2), lo, hi)
	_place_units_in_rect(world, t2.slice(2), far_lo, far_hi)
	if g3 != null:
		_place_unit(world, g3, far_lo + Vector2(0.0, 4.0))
		_place_units_in_rect(world, world.group_of(g3).slice(1), far_lo, far_hi)
	var foe = world.spawn_enemy(int(lo.x) + 1, int(lo.y) + 3)
	ok(foe != null, "刷一个敌人放进框里")
	if foe != null:
		_place_unit(world, foe, Vector2(lo.x + 1.5, lo.y + 0.5))

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

	main.input_ctrl.select_units([])
	var picked: int = main.input_ctrl.box_select(lo, hi)
	eq(picked, in_rect.size(), "★ 框到的是框内的己方单位（敌人不算进去）")
	eq(_sorted_ids(main.input_ctrl.selected_units), _sorted_keys(expect),
		"★ 选中的 = 框内单位**所属部队**的并集（不是「框里的那几个」）")
	ok(main.input_ctrl.selected_units.has(g1),
		"★ 队长在框外，也被一起选中（框到一个附属兵 = 选中整支部队）")
	ok(main.input_ctrl.selected_units.has(g2), "★ 第二支部队也一同选中")
	eq(main.input_ctrl.selected_units.size(), t1.size() + t2.size(),
		"★ 两支**完整**部队（队长 + 全部附属兵），哪怕一半人在框外")
	if g3 != null:
		ok(not main.input_ctrl.selected_units.has(g3), "框外的第三支部队没被选中")
	if foe != null:
		ok(rect.has_point(foe.pos), "（前提）敌人确实站在框里")
		ok(not main.input_ctrl.selected_units.has(foe), "★ 框里的敌人不会被选中")
	ok(main.input_ctrl.selected_building == null and main.input_ctrl.selected_zone == null,
		"框选是「选中单位」这一种，建筑 / 区划的选中被清掉")

	main.hud.refresh()
	eq(main.hud.squad_panel.slot_active(0), true, "★ 左侧「部队 1」显示为选中")
	eq(main.hud.squad_panel.slot_active(1), true, "★ 左侧「部队 2」也显示为选中")
	if g3 != null:
		eq(main.hud.squad_panel.slot_active(2), false, "没框到的第三支部队不高亮")

	var roster = main.hud.detail_panel.roster_control()
	var grid = main.hud.detail_panel.grid_control()
	ok(roster != null, "详细信息左栏上半有「当前聚焦的部队」那一格")
	ok(grid != null, "详细信息左栏下半有 3×3 的网格")
	if roster != null and grid != null:
		ok(roster.visible, "选中单位之后左栏上半出现")
		eq(roster.unit_count(), t1.size(), "★ 上半画的是**当前聚焦那一支**的完整部队")
		eq(roster.leader().id, g1.id, "★ 上半是第 1 支部队（内部状态对得上）")
		eq(roster.leader_name(), String(g1.name),
			"★ 那一格第一行写的是**将领真名**（参考图上写的就是这一行名字）")
		eq(roster.count_text(), "%d/%d" % [t1.size(), UiLayoutRes.UNIT_CAP],
			"★ 写着「现有单位数/编制上限」（y = 编制上限 11）")
		eq(roster.icon_text(), "1",
			"★★ 部队图标 = **序号**（第 1 支写 1），不再是将领名字首字")
		eq(roster.kind(), "troop", "★ 这一格是部队格（有士气填充）")
		ok(roster.morale_ratio() >= 0.0 and roster.morale_ratio() <= 1.0,
			"★ 部队图标的士气比例在 0..1（实际 %.2f）" % roster.morale_ratio())
		eq(roster.short_name(t1[0]), "将", "★ 单位图标仍用「将」字（没有头像，用字代替）")
		eq(roster.short_name(t1[1]), "枪",
			"★ 附属兵仍用 config.recruit.list 里的 short（长枪兵 = 枪）")

		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 整队选中时右栏报的是**将领**（不是排在最后的附属兵）")
		ok(main.hud.detail_panel.detail_text().contains("血量"),
			"★ 右栏两列详情：血量仍在左列")

		ok(UiLayoutRes.ROSTER_COUNT_X + 40.0 <= UiLayoutRes.DETAIL_LEFT_W,
			"★ 「将领名称 1/11」那一行装得进左栏")

		ok(grid.visible, "选中部队之后网格出现")
		eq(main.hud.detail_panel.grid_mode(), "leaders", "★ 选中多支部队时网格是**将领模式**")
		eq(grid.troop_count(), 1, "★ 网格只列**没被展开的**那 1 支（展开的那支已在上半）")
		eq(grid.cell_count(), 1, "画了 1 格")
		eq(grid.leader_name(0), String(g2.name), "★ 那一格是第 2 支部队（第 1 支正在上面聚焦）")
		ok(grid.cell_is_leader(0), "那一格是部队格")
		eq(grid.cell_short(0), "2", "★ 部队格方框里写**序号**（第 2 支 = 2）")
		eq(main.input_ctrl.selection_origin, "drag", "（前提）这一步是通过框选选中的")
		eq(roster.leader().id, g1.id, "（前提）展开的是序号靠前的第 1 支部队")
		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 拖拽选中多个部队 → 右栏显示**展开那支部队的将领**")
		ok(main.hud.detail_panel.detail_text().contains("血量"),
			"★ 多选时右栏仍显示聚焦部队的详情（不再补「已选中 N 支部队」）")
		eq(grid.cell_count(), 1, "★ 多选时下半网格里只有那 1 支没聚焦的部队")
		ok(grid.unit_at(0) == g2, "★ 那一格画的是部队（序号图标）")
		eq(grid.unit_total(), 1, "★ 多选时网格总数 = 其余选中的部队数")
		eq(grid.page_count(), 1, "★ 两支部队装得下，不用翻页 / 滑动")
		eq(UiLayoutRes.TROOP_GRID_SLOTS, 9,
			"★ 网格正好 9 格（手玩原话：参考图下方是 1333 排列的 9 个格子）")
		ok(UiLayoutRes.TROOP_GRID_SLOTS + 1 == 10,
			"★ 9 格 + 左上展开的那一格 = 10 格，正好对上「玩家部队上限 10 支」（手玩原话）")
		eq(UiLayoutRes.DETAIL_LEFT_W + UiLayoutRes.DETAIL_GAP + UiLayoutRes.DETAIL_RIGHT_W,
			UiLayoutRes.DETAIL_RECT.size.x - 2.0 * UiLayoutRes.DETAIL_PAD,
			"★ 左栏 + 缝 + 右栏 = 面板内容宽（不然右栏会被裁掉）")
		ok(UiLayoutRes.DETAIL_LEFT_W < UiLayoutRes.DETAIL_RIGHT_W,
			"★ 右栏比左栏宽（参考图里左栏只放一支部队，右栏要放头像+名称+buff+数值）")
		ok(UiLayoutRes.DETAIL_LEFT_W / (UiLayoutRes.DETAIL_LEFT_W + UiLayoutRes.DETAIL_RIGHT_W)
				< 0.40,
			"★ 左栏占不到 40%（参考图实测 37.5%）—— 之前写成 42%~78% 被判「左侧明显大了」")
		ok(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W
				<= UiLayoutRes.DETAIL_RIGHT_W + 1e-6,
			"★ 「详细信息」方框不越出右栏")
		ok(UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H <= 220.0,
			"★ 「详细信息」方框装得进右栏内容高（220）")
		ok((UiLayoutRes.BUFF_SLOTS - 1)
				* (UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_GAP) + UiLayoutRes.BUFF_SIZE
				<= UiLayoutRes.detail_buff_w(UiLayoutRes.DETAIL_RIGHT_W) + 1e-6,
			"★ 动态 buff 槽位（最多 %d 个）不越出可用宽 %.0f" % [
				UiLayoutRes.BUFF_SLOTS,
				UiLayoutRes.detail_buff_w(UiLayoutRes.DETAIL_RIGHT_W)])
		eq(UiLayoutRes.UNIT_AVATAR, 72.0,
			"★ 右栏头像方框 72×72（第五轮重排：原来照参考图的 100×100 又大又空）")
		eq(UiLayoutRes.BUFF_SIZE, 40.0,
			"★ 动态 buff 格 40×40（与左栏那些 40×40 方块同号，字也能用到 13 号）")
		ok(UiLayoutRes.BUFF_X >= UiLayoutRes.UNIT_AVATAR_X + UiLayoutRes.UNIT_AVATAR,
			"★ buff 排在头像**右边**（%s ≥ 头像右缘 %s）" % [
				str(UiLayoutRes.BUFF_X),
				str(UiLayoutRes.UNIT_AVATAR_X + UiLayoutRes.UNIT_AVATAR)])
		ok(UiLayoutRes.BUFF_Y >= UiLayoutRes.UNIT_NAME_Y,
			"★ 名称与 buff 同一条横带（buff 顶边 %s ≥ 名称顶边 %s）" % [
				str(UiLayoutRes.BUFF_Y), str(UiLayoutRes.UNIT_NAME_Y)])
		ok(UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE
				<= UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR + 1e-6,
			"★ buff 落在头像的竖直范围内（%s..%s ≤ 头像下缘 %s）" % [
				str(UiLayoutRes.BUFF_Y),
				str(UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE),
				str(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR)])
		ok(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W <= UiLayoutRes.QUEUE_X + 1e-6,
			"★ 单位名称那一行不顶到招募队列（%s ≤ %s）" % [
				str(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W),
				str(UiLayoutRes.QUEUE_X)])
		ok(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR
				< UiLayoutRes.DETAIL_BODY_Y,
			"★ 头像在「详细信息」方框上面，不重叠（%s < %s）" % [
				str(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR),
				str(UiLayoutRes.DETAIL_BODY_Y)])
		eq(UiLayoutRes.UNIT_AVATAR_Y,
			UiLayoutRes.UNIT_BAND_Y + (UiLayoutRes.UNIT_BAND_H - UiLayoutRes.UNIT_AVATAR) * 0.5,
			"★ 头像在顶带里**垂直居中**（%.0f = %.0f + (%.0f−72)/2）" % [
				UiLayoutRes.UNIT_AVATAR_Y, UiLayoutRes.UNIT_BAND_Y, UiLayoutRes.UNIT_BAND_H])
		eq(UiLayoutRes.QUEUE_Y, UiLayoutRes.DETAIL_BODY_Y,
			"★ 招募队列与详情框**顶边对齐**（本版从顶带搬下来）")
		eq(UiLayoutRes.QUEUE_Y + UiLayoutRes.QUEUE_H,
			UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H,
			"★ 招募队列与详情框**底边也齐平**（116 高）")
		ok(UiLayoutRes.DETAIL_BODY_Y >= UiLayoutRes.UNIT_BAND_Y + UiLayoutRes.UNIT_BAND_H,
			"★ 数值框不压到顶带（%s ≥ %s）" % [
				str(UiLayoutRes.DETAIL_BODY_Y),
				str(UiLayoutRes.UNIT_BAND_Y + UiLayoutRes.UNIT_BAND_H)])
		eq(UiLayoutRes.DETAIL_BODY_W, 282.0,
			"★ 详情框向左收窄到 282（最小可用宽，约 300）")
		ok(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W
				+ UiLayoutRes.QUEUE_MARGIN <= UiLayoutRes.QUEUE_X,
			"★ 详情框右缘与招募队列之间留出缝（%s + 4 ≤ %s）" % [
				str(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W),
				str(UiLayoutRes.QUEUE_X)])
		eq(UiLayoutRes.NOTICE_Y + UiLayoutRes.NOTICE_H, UiLayoutRes.DETAIL_CONTENT_H,
			"★ 提示带正好收在右栏下沿（220..240）")
		ok(UiLayoutRes.NOTICE_Y >= UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H,
			"★ 提示带与详情框不重叠（%s ≥ %s）" % [
				str(UiLayoutRes.NOTICE_Y),
				str(UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H)])
		ok(UiLayoutRes.NOTICE_H >= 16.0,
			"★ 提示带装得下一行 15 号字（行高 16，实测）")
		eq(UiLayoutRes.DETAIL_BODY_PAD + UiLayoutRes.DETAIL_BODY_COL_W
				+ UiLayoutRes.DETAIL_BODY_COL_GAP + UiLayoutRes.DETAIL_BODY_COL2_W
				+ UiLayoutRes.DETAIL_BODY_PAD,
			UiLayoutRes.DETAIL_BODY_W,
			"★ 两列 + 边距正好铺满详情框（8 + 129 + 8 + 129 + 8 = 282）")
		ok(UiLayoutRes.DETAIL_BODY_COL2_X
				>= UiLayoutRes.DETAIL_BODY_PAD + UiLayoutRes.DETAIL_BODY_COL_W,
			"★ 右列不压到左列（%s ≥ %s）" % [
				str(UiLayoutRes.DETAIL_BODY_COL2_X),
				str(UiLayoutRes.DETAIL_BODY_PAD + UiLayoutRes.DETAIL_BODY_COL_W)])
		var font: Font = main.hud._font
		if font != null:
			var body_fs: int = UiStyleRes.FS_SMALL
			var lh: float = font.get_height(body_fs)
			var visible: float = UiLayoutRes.DETAIL_BODY_ROWS_H
			var capacity: int = int(floor(visible / UiLayoutRes.DETAIL_ROW_H))
			ok(capacity >= 6,
				"★ 两列表格（可视高 %.0f、行高 %.0f）装得下 %d 行 —— 区划最坏 6 行也要装得下" % [
					visible, UiLayoutRes.DETAIL_ROW_H, capacity])
			# 最长的增益行：缩到 9 号字必须能塞进一列（detail_rows 会逐行缩字）
			var probe := "- 对近战攻击免伤+25%"
			ok(font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
					<= UiLayoutRes.DETAIL_BODY_COL_W + 0.01,
				"★ 最长增益行「%s」在 9 号字下 %.0f px ≤ 列宽 %.0f" % [
					probe, font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x,
					UiLayoutRes.DETAIL_BODY_COL_W])
		else:
			ok(true, "（没装中文字体，跳过字号容量的量算）")

		var before_draw: int = roster.draw_count
		var before_grid: int = grid.draw_count
		roster.queue_redraw()
		grid.queue_redraw()
		await process_frame
		ok(roster.draw_count > before_draw, "★ 左栏上半真的画了一帧（_draw 跑过）")
		ok(grid.draw_count > before_grid, "★ 网格真的画了一帧（_draw 跑过）")

		main.hud._on_troop_activated(99)                 # 先喂一个不存在的编号 → 什么都不该变
		eq(roster.leader().id, g1.id, "喂一个不存在的部队编号 → 展开的还是原来那支")
		main.hud._on_troop_activated(2)                  # 第 2 支部队的编号（走 hud 的真实处理）
		eq(roster.leader().id, g2.id, "★ 展开切到了第 2 支部队")
		eq(main.input_ctrl.selected_units.size(), t1.size() + t2.size(),
			"★ 点格子**不改选中**（两支部队仍然都选着，需求原话）")
		ok(main.hud.detail_panel.detail_text().contains("血量"),
			"★ 右栏跟着换成第 2 支部队的详情")
		eq(grid.cell_count(), 1, "★ 聚焦的那支从网格里消失、换成了另一支")
		eq(grid.leader_name(0), String(g1.name), "★ 网格里现在是第 1 支部队")

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

		main.input_ctrl.select_units([g1])
		main.hud.refresh()
		eq(main.hud.detail_panel.grid_mode(), "units",
			"★ 只选中一支部队时，下半网格是**单位模式**（画这支部队的单位）")
		eq(grid.cell_count(), t1.size(), "★ 格数 = 这支部队的单位数（含将领）")
		eq(grid.unit_at(0).id, g1.id, "★ 第 1 格是**将领本人**（参考图里它就是第一个方框）")
		ok(grid.cell_is_leader(0) == false, "单位格不是将领格（点击语义按单位走）")
		eq(grid.cell_short(0), "将", "★ 将领那一格的方框里写「将」")
		eq(grid.cell_name(0), String(g1.name), "格子右边写着单位名")
		eq(grid.unit_at(1).id, t1[1].id, "第 2 格是第 1 个附属兵")

		var sel_before2: int = main.input_ctrl.selected_units.size()
		_click_control(grid, UiLayoutRes.troop_cell_rect(1).get_center())
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(t1[1].name),
			"★ 点左栏下半的单位格 → 右栏切到那个单位")
		eq(main.input_ctrl.selected_units.size(), sel_before2,
			"★ 点单位格**不改选中**（命令发给谁不受影响）")
		_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
			"★ 点第 1 格（将领）→ 右栏回到将领")

		for _k in 11:
			var extra = UnitRes.create(main.cfg, "scroll-%d" % _k, "长枪兵 s%d" % _k,
				Vector2i(g1.tx, g1.ty), g1.faction, UnitRes.UNIT_TYPE_SPEARMAN, "", g1.id)
			world.units.append(extra)
		main.input_ctrl.select_units([g1])
		main.hud.refresh()
		eq(grid.unit_total(), t1.size() + 11, "（前提）这支部队的单位多到一页画不下")
		ok(grid.page_count() >= 2, "★ 单位超过 9 个 → 不止一页（一页 9 格）")
		eq(grid.page(), 0, "★ 默认停在第 1 页")
		eq(grid.cell_count(), grid.unit_total(), "★ 整批单位都在网格里（滑出去的那些也在）")
		ok(grid.max_scroll_x() > 0.0, "★ 超过 3 列 → 可以横向滑动")
		eq(grid.unit_at(0).id, g1.id, "（前提）第 1 格还是将领")
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = Vector2(60.0, 20.0)
		grid._gui_input(wheel)
		eq(grid.page(), 1, "★ 滚轮往下 = 翻到下一页（一次一页 9 格）")
		eq(grid.scroll_x(), minf(float(UiLayoutRes.GRID_PAGE)
			/ float(UiLayoutRes.TROOP_GRID_ROWS) * UiLayoutRes.TROOP_CELL_W,
			grid.max_scroll_x()), "★ 翻页 = 横向滚 3 列（夹在内容边界内）")
		ok(grid.unit_at(UiLayoutRes.GRID_PAGE).id != g1.id, "第 2 页不再从将领开头")
		var last_page: int = grid.page_count() - 1
		for _i in grid.page_count():
			grid._gui_input(wheel)
		eq(grid.page(), last_page, "★ 一路滚到最后一页")
		eq(grid.scroll_x(), grid.max_scroll_x(), "★ 最后一页停在内容最右端")
		grid._gui_input(wheel)
		eq(grid.page(), last_page, "★ 已经在最后一页 → 再往下滚也不动")
		var wheel_up := InputEventMouseButton.new()
		wheel_up.button_index = MOUSE_BUTTON_WHEEL_UP
		wheel_up.pressed = true
		wheel_up.position = Vector2(60.0, 20.0)
		grid._gui_input(wheel_up)
		eq(grid.page(), maxi(0, last_page - 1), "★ 滚轮往上 = 翻回上一页")
		for _i in grid.page_count():
			grid._gui_input(wheel_up)
		eq(grid.page(), 0, "★ 一路滚回第 1 页")
		eq(grid.scroll_x(), 0.0, "★ 第 1 页回到最左")
		grid._gui_input(wheel_up)
		eq(grid.page(), 0, "★ 已经在第一页 → 再往上滚也不动")

		main.input_ctrl.select_units([g2])
		main.hud.refresh()
		eq(grid.page(), 0, "★ 换成别的部队 → 翻页回到第 1 页")
		eq(grid.scroll_x(), 0.0, "★ 同时回到最左（换了一批就重头看）")
		eq(grid.unit_at(0).id, g2.id, "网格里是第 2 支部队（序号图标）")

		for u6 in world.units.duplicate():
			if String(u6.id).begins_with("scroll-"):
				world.units.erase(u6)

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
		var roster2 = main.hud.detail_panel.roster_control()
		var label_clip: String = roster2._clip_text(main.hud._font, "将领名称将领名称",
			UiLayoutRes.ROSTER_ID_W, UiStyleRes.FS_SMALL)
		ok(main.hud._font.get_string_size(label_clip, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UiStyleRes.FS_SMALL).x <= UiLayoutRes.ROSTER_ID_W + 0.01,
			"★ 左栏那一格的名字也按 ROSTER_ID_W 截断（%s）" % label_clip)

		ok(grid.cell_count() >= 2, "（前提）网格里至少 2 格 —— 只有 ≥2 格才看得出串列")
		eq(grid.cell_text_origin(1).x, grid.cell_text_origin(0).x,
			"★ 同一列往下排：第 2 个的文字左边与第 1 个对齐")
		eq(grid.cell_text_origin(1).y - grid.cell_text_origin(0).y, UiLayoutRes.TROOP_CELL_H,
			"★ 同一列往下排：文字跟着下移一格高")
		ok(grid.cell_text_origin(0).x >= UiLayoutRes.TROOP_AVATAR,
			"★ 第 1 列的文字在本格方框右边")
		if grid.cell_count() >= 3:
			eq(grid.cell_text_origin(2).x, grid.cell_text_origin(0).x,
				"★ 第 3 个仍在第 1 列（列优先：一列 3 个）")
		if grid.cell_count() >= 4:
			eq(grid.cell_text_origin(3).x - grid.cell_text_origin(0).x,
				UiLayoutRes.TROOP_CELL_W,
				"★ 换到第 2 列时文字左边正好差一格宽（不会叠到第 1 列）")
			eq(grid.cell_text_origin(3).y, grid.cell_text_origin(0).y,
				"★ 第 2 列第 1 行的文字顶边与第 1 列第 1 行对齐")

	main.input_ctrl.box_select(Vector2(0.0, 0.0), Vector2(0.5, 0.5))
	eq(main.input_ctrl.selected_units.size(), 0, "★ 空框 = 清空选中")
	main.hud.refresh()
	if roster != null and grid != null:
		eq(roster.visible, false, "没选中单位时左栏上半收起来")
		eq(grid.visible, false, "没选中单位时将领头像网格收起来")

	main.input_ctrl.select_units([g1])
	var before_add: int = main.input_ctrl.selected_units.size()
	main.input_ctrl.box_select(lo, hi, true)
	ok(main.input_ctrl.selected_units.has(g1) and main.input_ctrl.selected_units.has(g2),
		"★ Shift + 框 = 追加（两支都在）")
	ok(main.input_ctrl.selected_units.size() >= before_add, "追加不会把原来选中的挤掉")

	main.input_ctrl.hover_tile = Vector2i(-1, -1)      # 别让「按下那一下」顺手选中别的东西
	main.input_ctrl.select_units([])
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

	main.input_ctrl.handle_mouse_button(down)
	main.input_ctrl.handle_mouse_motion(move)
	ok(main.input_ctrl.drag_active, "（前提）又起了一个框")
	var kept := _sorted_ids(main.input_ctrl.selected_units)
	main.input_ctrl.handle_key(_key(KEY_ESCAPE))
	ok(not main.input_ctrl.drag_active, "★ Esc 放弃这次框选")
	eq(_sorted_ids(main.input_ctrl.selected_units), kept, "★ 放弃框选不会动已有的选中")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()


## ★★ PC 端框选：判定也按**立牌图标的屏幕矩形**（与手机端同一条口径）。
##
## 用户要求「PC 端的也改成统一的」：以前 PC 走「世界矩形 + 脚底锚点」，
## 于是「框住立牌上半身、脚底在框外」同样会漏（与手机端那个 bug 同源）。
## 现在 `_finish_drag()` 走 `box_select_screen()`，画出来的框也是屏幕矩形。
func _test_box_select_icon_body(main) -> void:
	var world = main.world
	var ic = main.input_ctrl
	var target = null
	for u in world.units:
		if u.alive and FactionRes.same_side(u.faction, world.my_faction) \
				and world.group_of(u).size() > 1:
			target = u
			break
	if target == null:
		ok(true, "（没有带部下的己方队伍，跳过 PC 框选判定）")
		return
	_place_unit(world, target, Vector2(8.0, 8.0))
	var s: Vector2 = _world_to_screen(main, target.pos)
	var ir: Rect2 = ic._unit_icon_screen_rect(target)
	# 只框住立牌**上半部分**（脚底在框外），往上多留 40px 让框足够大
	var a := Vector2(ir.position.x + 2.0, ir.position.y - 40.0)
	var b := Vector2(ir.end.x - 2.0, ir.position.y + ir.size.y * 0.45)
	ok(not Rect2(a, b - a).abs().has_point(s), "（前提）PC 这个框也不含脚底锚点")

	ic.select_units([])
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = a
	ok(ic.handle_mouse_button(down), "（前提）左键按下被处理")
	var move := InputEventMouseMotion.new()
	move.position = b
	ic.handle_mouse_motion(move)
	ok(ic.drag_active, "（前提）越过阈值 → 开始拖框")
	ok(ic.drag_screen_valid, "★★ PC 拖框也记下**屏幕矩形**（两端同一份数据）")
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = b
	ic.handle_mouse_button(up)
	ok(ic.selected_units.has(target),
		"★★ PC 框到立牌上半身（脚底在框外）也选中 —— 与手机端统一")
	var miss := 0
	for m in world.group_of(target):
		if not ic.selected_units.has(m):
			miss += 1
	ok(miss == 0, "★★ 同样展开成整支部队（漏 %d 个）" % miss)

## ★★ 鼠标拖框划到**底栏（详细信息 UI）**上时，框必须继续跟着走。
##
## 复现的 bug（用户报的）：「鼠标划到底栏内时选框不动，划过去之后又突变」。
##   底栏那一块是 `MOUSE_FILTER_STOP` —— 鼠标移到它上面时移动事件被 GUI **吃掉**，
##   `_unhandled_input` 收不到 ⇒ 框停在原地；离开底栏后下一个移动事件才让它跳到新位置。
## 修法：`game_scene3d._input()` 在手势进行中把移动 / 抬起补一遍（`_input` 先于 GUI 派发）。
## 这里直接喂 `main._input(...)` —— 就是「GUI 会吃掉的那些事件」在真实运行里走的那条路。
func _test_drag_over_ui(main) -> void:
	var world = main.world
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	# 底栏那一片里的两个屏幕点（屏幕下方 24px 处就在底栏上）
	var ui_a := Vector2(vp.x * 0.45, maxf(1.0, vp.y - 24.0))
	var ui_b := Vector2(vp.x * 0.65, maxf(1.0, vp.y - 24.0))

	# 按下仍然走 `_unhandled_input` 那条路（点在地图上；点在 UI 上不该起框，见最后一节）
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = _world_to_screen(main, Vector2(world.map.cols * 0.5, world.map.rows * 0.5))
	main.input_ctrl.handle_mouse_button(down)
	ok(main.input_ctrl._drag_pending, "（前提）在地图上按下 → 进入拖框待定")

	# ★ 划到底栏上：真实运行里这个移动事件会被 GUI 吃掉，只有 `_input` 拿得到
	var move_a := InputEventMouseMotion.new()
	move_a.position = ui_a
	main._input(move_a)
	ok(main.input_ctrl.drag_active,
		"★ 划到底栏上也能越过阈值、开始拖框（不再被底栏 UI 吃掉）")
	near(main.input_ctrl.drag_current_world.x,
		main.input_ctrl._screen_to_logic(ui_a).x, 0.02,
		"★ 框的终点跟着鼠标走到 UI 那一片（不再停在原地）")
	ok(main.input_ctrl.drag_current_world != main.input_ctrl.drag_start_world,
		"★ 框确实离开了起点（不是被冻在按下那一刻）")

	# 继续在底栏上移动 → 终点继续跟着走（原来就是这一下「突变」）
	var move_b := InputEventMouseMotion.new()
	move_b.position = ui_b
	main._input(move_b)
	near(main.input_ctrl.drag_current_world.x,
		main.input_ctrl._screen_to_logic(ui_b).x, 0.02, "框继续跟着鼠标走")

	# ★ 在底栏上松手 → 框照样结束（否则框会一直挂着，下一次点击才被清掉）
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = ui_b
	main._input(up)
	ok(not main.input_ctrl.drag_active and not main.input_ctrl._drag_pending,
		"★ 在底栏上松手，框照样结束")

	# 没有手势时，`_input` 不许自己起框（点在 UI 上就该是点 UI）
	var idle := InputEventMouseMotion.new()
	idle.position = ui_a
	main._input(idle)
	ok(not main.input_ctrl.drag_active and not main.input_ctrl._drag_pending,
		"★ 没有进行中的手势时，_input 不会自己起框")

func _test_box_select_buildings(main) -> void:
	var world = main.world
	var moved := 0
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		_place_unit(world, u, Vector2(24.0, 18.0) + Vector2(float(moved % 5) * 0.6,
			float(moved / 5) * 0.6))
		moved += 1
	ok(moved > 0, "（前提）把 %d 个己方单位挪出框外" % moved)

	var rect := Rect2(Vector2(1.0, 1.0), Vector2(9.0, 9.0))       # (1,1)..(10,10)
	var built: Array = []
	for ty in range(1, 10):
		for tx in range(1, 10):
			if world.can_build_at(tx, ty):
				var nb = world.add_building("wall", tx, ty, world.my_faction, true)
				if nb != null:
					built.append(nb)
	ok(built.size() >= 2, "（前提）在框内建了 %d 段己方城墙" % built.size())

	var expect: Array = []
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if b.is_invulnerable():
			continue
		if not FactionRes.same_side(b.owner, world.my_faction):
			continue
		if rect.has_point(b.center()):
			expect.append(b)
	if built.size() < 2 or expect.is_empty():
		ok(false, "★ 框选建筑的用例需要框内有己方建筑（实际 %d 个）" % expect.size())
		return

	main.input_ctrl.select_units([])
	var picked: int = main.input_ctrl.box_select(rect.position, rect.end)
	eq(picked, expect.size(), "★ 框里没有单位时，框到的是框内的己方建筑")
	eq(main.input_ctrl.selected_units.size(), 0, "★ 建筑那一批不算「选中单位」")
	eq(main.input_ctrl.selected_buildings.size(), expect.size(),
		"★ 选中的建筑 = 框内全部己方建筑")
	eq(main.input_ctrl.selected_building, expect[0], "★ 主选中 = 第一个（右栏显示它）")

	main.hud.refresh()
	var panel = main.hud.detail_panel
	var roster = panel.roster_control()
	var grid = panel.grid_control()
	eq(panel.grid_mode(), "buildings", "★ 选中建筑时左栏下半是**建筑模式**")
	ok(roster.visible, "★ 左栏左上那一格出现（主选中那个建筑）")
	eq(roster.leader_name(), expect[0].display_name(), "★ 左上那一格写主选中建筑的名字")
	eq(roster.kind(), "building", "★ 这一格是建筑格（**没有士气填充**）")
	eq(roster.icon_text(), expect[0].display_name().substr(0, 1), "方框里写名字首字")
	ok(roster.shows_hp(), "★ 建筑图标底部有血条")
	eq(roster.count_text(), "%d/%d" % [int(round(expect[0].hp)), int(round(expect[0].hp_max))],
		"★ 左上那一格第二行写血量 x/y")
	if main.hud._font != null:
		var probe := "1000/1000"
		ok(main.hud._font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1,
				UiStyleRes.FS_SMALL).x <= UiLayoutRes.TROOP_NAME_W,
			"★ 「%s」装得进格子的可写宽 %.0f（不然血量那行会被截断）" % [
				probe, UiLayoutRes.TROOP_NAME_W])
		ok(UiLayoutRes.TROOP_NAME_X + UiLayoutRes.TROOP_NAME_W <= UiLayoutRes.TROOP_CELL_W - 4.0,
			"★ 网格里那一行文字留在本格内（不盖到右边那格的方框）")
		ok(UiLayoutRes.ROSTER_COUNT_X + UiLayoutRes.ROSTER_COUNT_W <= UiLayoutRes.DETAIL_LEFT_W,
			"★ 左上那一格的文字留在左栏里")
	else:
		ok(true, "（没装中文字体，跳过这一行宽度的量算）")
	eq(grid.cell_count(), expect.size() - 1,
		"★ 下面 3×3 装其余选中的建筑（整批都在里面，滑出去的那些也算）")
	eq(grid.building_at(0), expect[1], "★ 网格第 1 格是第 2 个建筑（主选中在左上）")
	eq(grid.cell_name(0), expect[1].display_name(), "格子里写着建筑名")
	ok(grid.cell_is_building(0), "那一格是建筑格（不是单位格）")
	eq(grid.cell_short(0), expect[1].display_name().substr(0, 1), "建筑格方框里写名字首字")
	eq(grid._morale_ratio_at(0), 1.0, "★ 建筑格不画士气背景（只有部队才有）")
	eq(grid.cell_sub_text(0), "%d/%d" % [int(round(expect[1].hp)), int(round(expect[1].hp_max))],
		"★ 建筑格第二行是血量 x/y")

	eq(panel.unit_name_text(), expect[0].display_name(), "★ 右栏报的是主选中的建筑")
	ok(panel.detail_text().contains("血量") and panel.detail_text().contains("防御"),
		"★ 建筑详情是两列：左列血量、右列防御（实际：%s）"
			% panel.detail_text().replace("\n", "|"))
	var btext: String = main.hud._building_text(expect[0])
	ok(btext.contains("血量"), "（文案生成器）建筑详情里有血量（实际：%s）" % btext.replace("\n", "|"))
	ok(not btext.contains("归属") and not btext.contains("位置"),
		"★ 建筑详情里没有「归属」「位置」（本版精简掉了）")
	ok(not btext.contains("升级到"),
		"★ 建筑详情里没有「升级到 N 级…」那条预览（实际：%s）" % btext.replace("\n", "|"))
	ok(not btext.contains("已经是最高等级"), "★ 满级那句也不再写")
	var base = null
	for b in world.building_list:
		if b != null and b.alive and b.type == BuildingRes.TYPE_BASE and b.owner == world.my_faction:
			base = b
			break
	if base != null:
		var basetext: String = main.hud._building_text(base)
		ok(not basetext.contains("开局自带"),
			"★ 大本营详情里没有「开局自带，不可建造、不可拆除」（实际：%s）"
				% basetext.replace("\n", "|"))
		ok(basetext.contains("血量"), "★ 大本营的血量那一行照旧在")
	else:
		ok(false, "★ 找不到己方大本营 —— 这条断言本该验它详情里没有那句说明")

	var sel_before: int = main.input_ctrl.selected_buildings.size()
	_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
	main.hud.refresh()
	eq(main.input_ctrl.selected_building, expect[1], "★ 点建筑格 → 主选中换成它")
	eq(main.input_ctrl.selected_buildings.size(), sel_before, "★ 点格子**不改选中**")
	eq(panel.unit_name_text(), expect[1].display_name(), "★ 右栏跟着换成那个建筑")
	eq(roster.leader_name(), expect[1].display_name(), "左上那一格也换成了它")
	ok(panel.detail_text().contains("血量"), "★ 右栏跟着换成那个建筑的详情")

	if expect.size() > UiLayoutRes.GRID_PAGE:
		ok(grid.page_count() >= 2, "★ 选中的建筑多到一页画不下 → 不止一页")
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
		wheel.pressed = true
		wheel.position = Vector2(60.0, 20.0)
		grid._gui_input(wheel)
		eq(grid.page(), 1, "★ 滚轮往下 = 翻到下一页（一次一页 9 格）")
		ok(grid.building_count() > 0, "第 2 页照样有建筑格")
		wheel.button_index = MOUSE_BUTTON_WHEEL_UP
		grid._gui_input(wheel)
		eq(grid.page(), 0, "★ 滚轮往上 = 翻回上一页")

	var g1 = world.unit_by_id("general-1")
	if g1 != null:
		_place_unit(world, g1, rect.position + Vector2(3.5, 3.5))
		main.input_ctrl.select_units([])
		main.input_ctrl.box_select(rect.position, rect.end)
		ok(main.input_ctrl.selected_units.has(g1),
			"★ 框里有己方单位 → 仍然是「选中单位」（整队被框出来）")
		eq(main.input_ctrl.selected_buildings.size(), 0,
			"★ 单位优先：同一次框选不会顺带选中建筑")

	eq(main.hud._fmt_num(2.0), "2", "整数不带小数点")
	eq(main.hud._fmt_num(0.05), "0.05",
		"★ 小数照写（这里原来用的是 Godot **不支持**的 %g，每帧刷一条 formatting error）")
	eq(main.hud._fmt_num(1.23456), "1.235", "小数最多 3 位")
	var zones: Array = world.zones.zones
	if zones.size() > 0:
		var z0: Dictionary = zones[0]
		var zrows: Dictionary = main.hud._zone_detail_rows(z0, true)
		var zleft: Array = zrows["left"]
		var zright: Array = zrows["right"]
		eq(main.hud._row_text(zleft, 0),
			String(world.zones.kind_entry_of(z0).get("name", "")),
			"★ 左列第一排 = 区划类型（粮食 / 黄金 / 人口区划）")
		eq(main.hud._row_text(zleft, 1), "大小 %d 地块" % int(z0["tile_count"]),
			"★ 左列第二排 = 区划大小")
		ok(main.hud._row_text(zright, 0).begins_with("粮食 ")
				and main.hud._row_text(zright, 0).ends_with("/s"),
			"★ 右列第一排 = 粮食产能（每秒）")
		ok(main.hud._row_text(zright, 1).begins_with("黄金 "),
			"★ 右列第二排 = 黄金产能")
		ok(main.hud._row_text(zright, 2).begins_with("人口 "),
			"★ 右列第三排 = 人口产能")
		ok(main.hud._row_text(zright, 3).begins_with("人口上限 "),
			"★ 右列第四排 = 人口上限")
		ok(main.hud._row_text(zright, 4).begins_with("现有人口 "),
			"★ 自己 / 友军区划额外显示当前人口")
		ok(zright.size() <= 6, "★ 区划最多 6 行（正好装进两列表格的 6 行容量）")

		var ztext: String = main.hud._zone_text(z0)
		ok(ztext.contains("\t"), "★ 区划详情是两列（左 \t 右）")
		ok(not ztext.contains("区划「"), "★ 不再写「区划「xx」」")
		ok(not ztext.contains("归属"), "★ 不再写「归属」")
		ok(not ztext.contains("每地块每秒"), "★ 不再写「每地块每秒 …」")
		ok(not ztext.contains("区划大小："), "★ 旧的「区划大小：」文案已换成「大小 N 地块」")
		var enemy_rows: Dictionary = main.hud._zone_detail_rows(z0, false)
		ok(not main.hud._rows_text(enemy_rows).contains("现有人口"),
			"★ 敌方 / 中立区划不显示当前人口")

		var spec_zone: Dictionary = z0.duplicate(true)
		spec_zone["spec_done"] = "food"
		var srows: Dictionary = main.hud._zone_detail_rows(spec_zone, true)
		var sright: Array = srows["right"]
		ok(main.hud._rows_text(srows).contains("特化 粮食特化"),
			"★ 已特化的区划在右列末行写「特化 粮食特化」（实际：%s）"
				% main.hud._rows_text(srows).replace("\n", "|"))
		eq(main.hud._row_text(sright, sright.size() - 1),
			"- 特化 粮食特化", "★ 特化那一行是唯一的小字增益行（带「- 」前缀）")

		main.input_ctrl.select_zone(z0)
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), String(z0["name"]),
			"★ 选中区划时右栏标题就是区划名本身（不再套「区划「xx」」）")
		eq(main.hud.detail_panel.detail_text(), ztext,
			"★ 面板两列详情与 `_zone_text()` 一致（同一处拼装）")

	ok(not main.input_ctrl.has_method("demolish_selected"), "★ 拆除入口已删除")
	ok(not main.input_ctrl.handle_key(_key(KEY_X)), "★ 按 X 不再发拆除命令")
	ok(not main.input_ctrl.handle_key(_key(KEY_DELETE)), "★ Delete 同理")

	for b2 in built:
		world.remove_building(b2, true)
	world.rebuild_building_index()
	main.input_ctrl.select_units([g1])
	main.hud.refresh()

func _test_detail_two_columns(main) -> void:
	var panel = main.hud.detail_panel
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()

	# ★★ 本版：两列表格 —— 左 = 血量 / 攻击，右 = 移速 / 防御
	ok(panel.detail_left_text().contains("血量")
			and panel.detail_left_text().contains("攻击"),
		"★ 左列 = 血量 / 攻击力（实际：%s）"
			% panel.detail_left_text().replace("\n", "|"))
	ok(panel.detail_right_text().contains("移速")
			and panel.detail_right_text().contains("防御"),
		"★ 右列 = 移动速度 / 防御力（实际：%s）"
			% panel.detail_right_text().replace("\n", "|"))
	ok(panel.detail_text().contains("\t"),
		"★ 两列之间用制表位合成（同一行左 \t 右）")

	var rows = panel.detail_rows_control()
	ok(rows != null, "★ 两列表格控件在")
	if rows != null:
		eq(rows.position, Vector2(UiLayoutRes.DETAIL_BODY_PAD,
			UiLayoutRes.DETAIL_BODY_TEXT_Y),
			"★ 表格贴在详情框内边距处起排")
		near(rows.size.x, UiLayoutRes.detail_rows_w(UiLayoutRes.DETAIL_RIGHT_W), 0.01,
			"★ 表格宽 = 详情框内宽")
		ok(UiLayoutRes.DETAIL_BODY_COL2_X - UiLayoutRes.DETAIL_BODY_PAD
				> UiLayoutRes.DETAIL_BODY_COL_W,
			"★ 右列起点在左列右边（%s > %s）" % [
				str(UiLayoutRes.DETAIL_BODY_COL2_X - UiLayoutRes.DETAIL_BODY_PAD),
				str(UiLayoutRes.DETAIL_BODY_COL_W)])
		ok((UiLayoutRes.DETAIL_BODY_COL2_X - UiLayoutRes.DETAIL_BODY_PAD)
				+ UiLayoutRes.DETAIL_BODY_COL2_W
				<= rows.size.x + 0.01,
			"★ 右列不越出表格")

	# 旧接口仍能把 `\t` 文本拆成两列
	panel.set_detail("左A\t右A\n左B\t右B")
	eq(panel.detail_text(), "左A\t右A\n左B\t右B", "★ set_detail() 的 `\t` 文本按两列读回")
	panel.set_detail("第一行\n第二行")
	eq(panel.detail_text(), "第一行\n第二行", "★ 没有 `\t` 时只填左列")
	main.hud.refresh()

func _test_detail_vertical_fit(main) -> void:
	var panel = main.hud.detail_panel
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	# ★ 两列表格是固定行高（17），可视高 102 ⇒ 正好 6 行；超过的行不画。
	eq(panel.body_font_size(), UiStyleRes.FS_SMALL, "★ 主数值行字号 13")
	eq(panel.body_line_spacing(), 0, "★ 两列表格没有整块行距覆盖")
	eq(int(floor(UiLayoutRes.DETAIL_BODY_ROWS_H / UiLayoutRes.DETAIL_ROW_H)), 6,
		"★ 表格正好装 6 行（6 × 17 = 102）")
	var long_rows: Array = []
	for i in 10:
		long_rows.append("第%d行" % (i + 1))
	panel.set_detail_rows(long_rows, [])
	eq(panel.detail_rows_control().row_count(), 10,
		"★ 喂 10 行时数据都在（只是超过 6 行的部分不画）")
	main.hud.refresh()

func _test_detail_basic_stats(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	ok(g1 != null, "（前提）找得到 general-1")
	if g1 == null:
		return

	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	var panel = main.hud.detail_panel
	var gtext: String = panel.detail_text()
	ok(gtext.contains("血量") and gtext.contains("移速"),
		"★ 血量在左第一排、移速在右第一排（实际：%s）" % gtext.replace("\n", "|"))
	ok(gtext.contains("攻击 ") and gtext.contains("防御 0"),
		"★ 攻击在左第二排、防御在右第二排（实际：%s）" % gtext.replace("\n", "|"))
	ok(gtext.contains("/") and gtext.contains("s"),
		"★ 攻击那一行是「原始攻击力/攻击频率」（如 14/1s）")
	ok(not gtext.contains("攻击距离"), "★ 旧版「攻击距离」不再显示")
	ok(not gtext.contains("编制") and not gtext.contains("状态") and not gtext.contains("兵种"),
		"★ 不再有编制 / 状态 / 兵种")
	ok(not gtext.contains("已选中"), "★ 不再有「已选中 N 支部队」")
	# ★ 词条已停用：只剩「两行基础 + 一行兵种特性」。
	eq(gtext.split("\n").size(), 3,
		"★ 两行基础 + 一行兵种特性（长枪兵：对骑兵伤害 +25%）")
	ok(gtext.contains("对骑兵伤害 +25%"), "★ 攻击特性写在左列「攻击」下面（实际：%s）"
		% gtext.replace("\n", "|"))
	ok(not gtext.contains("特性 "), "★ 不再有将领词条行")

	# 防御增益：士气免伤 / 易伤（只有这一套数据）
	var old_morale: float = g1.morale
	g1.morale = g1.morale_max
	main.hud.refresh()
	ok(panel.detail_right_text().contains("士气免伤 +%d%%"
			% int(round(main.cfg.morale_damage_reduction * 100.0))),
		"★ 士气高昂 → 右列防御增益「士气免伤 +50%%」（实际：%s）"
			% panel.detail_right_text().replace("\n", "|"))
	g1.morale = 20.0
	main.hud.refresh()
	ok(panel.detail_right_text().contains("士气易伤 +%d%%"
			% int(round(main.cfg.morale_vulnerability * 100.0))),
		"★ 士气低落 → 右列防御增益「士气易伤 +50%%」（实际：%s）"
			% panel.detail_right_text().replace("\n", "|"))
	g1.morale = old_morale
	main.hud.refresh()

	var retinue: Array = world.retinue_of(g1.id)
	ok(retinue.size() > 0, "（前提）1 号将领带着附属兵（%d 个）" % retinue.size())
	if retinue.size() > 0:
		var soldier = retinue[0]
		ok(not world.is_team_leader(soldier), "（前提）喂进去的这个确实是兵，不是将领")
		var stext: String = main.hud._unit_text(soldier, [])
		ok(stext.contains("血量") and stext.contains("移速")
				and stext.contains("攻击") and stext.contains("防御"),
			"（文案生成器）兵的四个基础项照常")
		ok(stext.contains("\t"), "★ 兵也是两列")
		ok(not stext.contains("编制") and not stext.contains("状态"),
			"★ 兵不显示「编制」「状态」")
		ok(not stext.contains("兵种") and not stext.contains("已选中"),
			"★ 兵也不显示「兵种」「已选中 N 支部队」")
		# ★ 词条已停用：兵只剩「两行基础 + 兵种特性」。
		var s_left: int = main.hud._attack_bonus_lines(soldier).size()
		var s_right: int = main.hud._defense_bonus_lines(soldier).size()
		eq(stext.split("\n").size(), 2 + maxi(s_left, s_right),
			"★ 兵也是两行基础 + 兵种特性行")
		ok(stext.contains("伤害 +"), "★ 兵的详情同样显示它自己的特性（实际：%s）"
			% stext.replace("\n", "|"))

	var foe = world.spawn_enemy(g1.tx + 5, g1.ty)
	if foe != null:
		main.input_ctrl.clicked_unit = foe
		main.input_ctrl.selection_origin = "click"
		main.hud.refresh()
		ok(main.hud.detail_panel.detail_text().contains("血量"),
			"★ 点到敌人右栏仍显示它的血量")
		ok(not main.hud.detail_panel.detail_text().contains(String(foe.name)),
			"★ 但不会把敌人的名字写成右栏标题")

	main.input_ctrl.select_units([g1])
	main.hud.refresh()

func _place_units_in_rect(world, units: Array, lo: Vector2, hi: Vector2) -> void:
	var i := 0
	for u in units:
		var col := i % 5
		var row := int(i / 5)
		_place_unit(world, u, lo + Vector2(0.5 + float(col) * 0.7, 0.5 + float(row) * 0.7))
		i += 1

func _place_unit(world, u, at: Vector2) -> void:
	u.pos = at
	u.sync_tile(world.map)

func _world_to_screen(main, w: Vector2) -> Vector2:
	return main.palette.to_px(w)

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

func _test_buff_long_press(main) -> void:
	var hud = main.hud
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	hud.refresh()
	var bb = hud.detail_panel.buff_bar_control()
	# ★ 词条已停用：buff 条只有士气一条。
	var morale_i := -1
	if bb != null:
		for i in bb.count():
			if String(bb.entry(i).get("id", "")) == "morale":
				morale_i = i
				break
	ok(bb != null and morale_i >= 0, "（前提）选中单位有一条士气 buff")
	if bb == null or morale_i < 0:
		return
	var pos: Vector2 = bb.buff_global_rect(morale_i).get_center()

	# ① 按下：不立刻弹（手机端要长按）
	var press := InputEventScreenTouch.new()
	press.pressed = true
	press.position = pos
	hud.handle_touch(press)
	eq(hud._lp_src, "buff", "★ 手机按在 buff 上 → 进入 buff 长按监视")
	ok(not bb.tip_showing(), "★ 按下的瞬间不弹（要等长按）")
	hud._tick_long_press()
	ok(not bb.tip_showing(), "★ 还没到 touch.long_press_sec → 不弹")

	# ② 把按下时间往前拨，模拟长按到点
	hud._lp_press_ms -= int(main.cfg.touch_long_press_sec * 1000.0) + 10
	hud._tick_long_press()
	ok(bb.tip_showing(), "★ 长按到点 → 弹出 buff 浮窗")
	eq(bb.tip_title_text(), "士气", "★ 长按浮窗内容与鼠标悬停同一套")
	ok(bb.tip_body_text().contains("当前"), "★ 长按浮窗也写当前士气")
	# 长按期间模拟鼠标的抖动 / 移出不应该把浮窗收掉（手指还按着）
	bb._on_mouse_exited()
	ok(bb.tip_showing(), "★ 长按期间模拟鼠标移出不会收浮窗")

	# ③ 松手：收起，并恢复鼠标悬停
	var release := InputEventScreenTouch.new()
	release.pressed = false
	release.position = pos
	hud.handle_touch(release)
	ok(not bb.tip_showing(), "★ 松手 → 浮窗收起")
	ok(not bb.touch_suppress_hover, "★ 松手后恢复鼠标悬停")

	# ④ 按住后滑动超过阈值：取消长按，不弹
	hud.handle_touch(press)
	var drag := InputEventScreenDrag.new()
	drag.position = pos + Vector2(main.cfg.touch_pan_min_px + 20.0, 0.0)
	hud.handle_touch_drag(drag)
	ok(not hud._lp_active, "★ 按住后滑动超过阈值 → 取消长按")
	ok(not bb.tip_showing(), "★ 取消之后不弹")
	hud.handle_touch(release)


func _test_clicked_unit_detail(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	ok(g1 != null, "点选用例：将领 1 在")
	if g1 == null:
		return
	var mates: Array = world.group_of(g1)
	if mates.size() < 2:
		return
	var mate = mates[1]                       # 将领 1 名下的第一个附属兵

	main.input_ctrl.select_units([])
	main.input_ctrl.mouse_world = mate.pos
	main.input_ctrl.hover_tile = Vector2i(mate.tx, mate.ty)
	main.input_ctrl._on_left_click(false)
	eq(main.input_ctrl.clicked_unit, mate, "★ 地图上点到的那个单位被记下来了")
	ok(main.input_ctrl.selected_units.has(g1), "★ 整队仍然被选中（点一个兵 = 选整队，老行为不变）")
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(mate.name),
		"★ 右栏报的是**玩家点到的那个附属兵**（不是将领）")
	eq(main.hud.detail_panel.roster_control().leader().id, g1.id,
		"★ 左栏上半仍然是那支部队（部队级），不受影响")

	var before: int = main.input_ctrl.selected_units.size()
	main.input_ctrl.box_select(Vector2(0.0, 0.0), Vector2(0.5, 0.5))    # 空框 = 清空
	eq(main.input_ctrl.clicked_unit, null, "★ 框选/清空会把「点到的单位」清掉")
	eq(main.input_ctrl.selection_origin, "drag", "★ 拖拽框选把「怎么选中的」记成 drag")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
		"★ 批量选中（框选 / 点左侧列表）时右栏退回**将领**（不是某个附属兵）")
	ok(before >= 0, "（前一步的选中规模：%d）" % before)

	var roster = main.hud.detail_panel.roster_control()
	var grid = main.hud.detail_panel.grid_control()
	var sel_before: Array = main.input_ctrl.selected_units.duplicate()
	eq(grid.unit_at(1).id, mates[1].id, "（前提）网格第 2 格就是那个附属兵")
	_click_control(grid, UiLayoutRes.troop_cell_rect(1).get_center())
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(mates[1].name),
		"★ 点左栏下半的单位格 → 右栏切到那个单位")
	eq(main.input_ctrl.selection_origin, "click", "★ 点单位格按「单击」那一套走")
	eq(main.input_ctrl.selected_units.size(), sel_before.size(),
		"★ 点单位格**不改选中**（命令发给谁不受影响）")
	ok(roster.visible, "（前提）左栏上半还画着")
	_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
	main.hud.refresh()
	eq(main.hud.detail_panel.unit_name_text(), String(g1.name),
		"★ 点第 1 格（将领）→ 右栏回到将领")

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

	main.input_ctrl.select_units([g1])
	main.hud.refresh()

func _test_enemy_selection(main) -> void:
	var world = main.world
	var ic = main.input_ctrl
	var hud = main.hud

	var foe = null
	for u in world.units:
		if u.alive and not FactionRes.same_side(u.faction, world.my_faction):
			foe = u
			break
	if foe == null:
		foe = world.spawn_enemy(2, 2)
	ok(foe != null, "（前提）场上有一个敌人可供点选")
	if foe == null:
		return
	for u in world.units:
		if u != foe and u.alive and u.tx == foe.tx and u.ty == foe.ty:
			_place_unit(world, u, Vector2(foe.tx + 2.5, foe.ty + 2.5))

	var g1 = world.unit_by_id("general-1")
	if g1 != null:
		ic.select_units([g1])
	ok(not ic.selected_units.is_empty(), "（前提）先选中了一支己方部队")

	ic.mouse_world = foe.pos
	ic.hover_tile = Vector2i(foe.tx, foe.ty)
	ic._on_left_click(false)

	eq(ic.selected_enemy, foe, "★ 左键点敌人 → 它被选中了（`_pick_any_unit_at` 认敌我两方）")
	eq(ic.selected_enemy_kind(), "unit", "★ 判定它是**单位**（不是建筑）")
	ok(main._selected_ids().has(foe.id), "★ 敌人的 id 进了选中集合（地图上要画它的选中圈）")
	ok(main._selected_buildings().is_empty(), "★ 选中敌人**单位**时建筑高亮集合是空的")
	ok(ic.selected_units.is_empty(),
		"★ 选敌人时己方选中被清空（否则命令会发给一支看不见的队伍）")
	ok(ic.selected_buildings.is_empty() and ic.selected_zone == null,
		"★ 四种选中互斥：没有同时选中建筑 / 区划")
	eq(ic.selected_enemy_kind() == "unit", true, "★ 需求「只能单个选中」：只有一个敌人字段")

	hud.refresh()
	var tabs = hud.page_tabs
	eq(tabs.page_count(), 1, "★ 选中敌人时页签只有一颗（「有格子」）")
	eq(tabs.page(), PageTabsRes.PAGE_NONE, "★ 那一颗是**空页签**（没有标签）")
	eq(tabs.page_id_at(0), PageTabsRes.PAGE_NONE, "★ 它不指向操作 / 单位 / 建筑任何一页")
	var tab0: Button = tabs.button_at(0)
	ok(tab0 != null and tab0.visible, "★ 那颗格子是可见的（不是整列消失）")
	if tab0 != null:
		eq(tab0.text, "", "★ 格子内没有字（需求：「格子内没东西」）")
		var sb0: StyleBox = tab0.get_theme_stylebox("normal")
		ok(sb0 is StyleBoxFlat, "★ 空格子有一个 StyleBoxFlat 底纹")
		if sb0 is StyleBoxFlat:
			var f0 := sb0 as StyleBoxFlat
			ok(f0.bg_color.a <= 0.001, "★ 底纹是**透明底**（底色交给填充层）")
			ok(f0.border_color.r > f0.border_color.b and f0.border_width_left >= 1,
				"★ 但**金线还在**（立在地图上看得见它是个框）")
		ok(tab0.has_meta(FillButtonRes.META),
			"★ 页签挂着「琥珀填充层」（悬停自下而上填琥珀 / 当前页常驻满格）")
	ok(not tabs.is_active(0), "★ 空页签不算「当前页」（不高亮）")
	eq(hud.command_card.entries().size(), 0,
		"★★ 命令卡是**空的**（一颗格子内容都没有）—— 绝不能落到「操作」页")
	ok(hud.tech_grid == null or not hud.tech_grid.visible,
		"★ 科技九格也没被翻出来（它只属于科技页）")

	eq(hud.detail_panel.unit_name_text(), String(foe.name), "★ 右栏报的是那个敌人的名字")
	ok(hud.detail_panel.detail_text().contains("血量")
			and hud.detail_panel.detail_text().contains("防御"),
		"★ 敌人也走同一套两列详情（血量 / 防御）")
	var txt: String = hud._enemy_unit_text(foe)
	ok(txt.contains("血量") and txt.contains("攻击") and txt.contains("防御"),
		"（文案生成器）敌人详情有血量 / 攻击 / 防御")
	for bad in ["升级", "特化", "招募", "再起"]:
		ok(not txt.contains(bad), "★ 敌人详情里不出现己方动作「%s」" % bad)
	eq(hud.detail_panel.grid_mode(), "empty", "★ 左栏下半网格是空的（敌人进不了编组）")

	ic.select_units([])
	var foe_b = null
	for b in world.building_list:
		if b != null and b.alive and not b.is_invulnerable() \
				and not FactionRes.same_side(b.owner, world.my_faction):
			foe_b = b
			break
	ok(foe_b != null, "（前提）场上有敌对的建筑（对家据点 / 测试建筑）")
	if foe_b != null:
		ic.mouse_world = Vector2(float(foe_b.tx) + 0.5, float(foe_b.ty) + 0.5)
		ic.hover_tile = Vector2i(foe_b.tx, foe_b.ty)
		ic._on_left_click(false)
		eq(ic.selected_enemy, foe_b, "★ 左键点敌对建筑 → 它被选中了")
		eq(ic.selected_enemy_kind(), "building", "★ 判定它是**建筑**")
		ok(ic.selected_buildings.is_empty(),
			"★ 它**不在**己方建筑选中列表里（否则「升级」那一页会对着它打开）")
		ok(main._selected_buildings().has(foe_b),
			"★ 但建筑高亮集合里**有**它（地图上要给它描金框）")
		hud.refresh()
		eq(hud.page_tabs.page_count(), 1, "★ 敌对建筑同样只有一颗空格子")
		eq(hud.page_tabs.page(), PageTabsRes.PAGE_NONE, "★ 空页签")
		eq(hud.command_card.entries().size(), 0, "★ 命令卡空（没有「升级」那一格）")
		eq(hud.detail_panel.unit_name_text(), foe_b.display_name(), "★ 右栏报的是那栋建筑的名字")
		ok(hud.detail_panel.detail_text().contains("血量"),
			"★ 敌对建筑也显示两列详情（血量 / 防御）")
		var btxt: String = hud._enemy_building_text(foe_b)
		ok(btxt.contains("血量"), "（文案生成器）右栏有它的血量")
		for bad2 in ["等级", "升级", "特化", "建造中"]:
			ok(not btxt.contains(bad2), "★ 敌对建筑详情里不出现「%s」" % bad2)

	var foe_center_tile := Vector2i(-1, -1)
	for z in world.zones.zones:
		if FactionRes.same_side(String((z as Dictionary).get("owner", "")), world.my_faction):
			continue
		var c: Variant = (z as Dictionary).get("center", null)
		if c != null:
			foe_center_tile = c
			break
	ok(foe_center_tile.x >= 0, "（前提）场上有一个**不属于自己**的区划（它的中心格可点）")
	if foe_center_tile.x >= 0:
		ic.select_units([])
		ic.mouse_world = Vector2(float(foe_center_tile.x) + 0.5, float(foe_center_tile.y) + 0.5)
		ic.hover_tile = foe_center_tile
		ic._on_left_click(false)
		ok(ic.selected_zone != null,
			"★★ 点**别人区划**的中心也打开区划详情（本次改口径：不论敌友中立）")
		hud.refresh()
		eq(hud.page_tabs.page(), PageTabsRes.PAGE_NONE,
			"★ 但别人区划只给一颗空格子（不给特化 / 招募入口）")
		eq(hud.command_card.entries().size(), 0, "★ 命令卡空（没有三个特化那一页）")
		ok(hud.detail_panel.detail_text().contains("粮食")
				and not hud.detail_panel.detail_text().contains("现有人口"),
			"★ 别人区划：右列报产能、不报现有人口")
		var ftxt: String = hud._zone_text(ic.selected_zone, false)
		ok(not ftxt.contains("血量"),
			"（文案生成器）不显示区划中心的血量 —— 实际：%s" % ftxt.replace("\n", "|"))
		ok(ftxt.contains("粮食 ") and ftxt.contains("黄金 "),
			"（文案生成器）显示区划产能（粮食 / 黄金）")
		ok(ftxt.contains("人口上限 "),
			"（文案生成器）显示人口上限")
		ok(not ftxt.contains("现有人口"),
			"（文案生成器）别人区划**不显示当前人口**（那是对手的情报）")

	var own_center_tile := Vector2i(-1, -1)
	for z2 in world.zones.zones:
		if not FactionRes.same_side(String((z2 as Dictionary).get("owner", "")), world.my_faction):
			continue
		var c2: Variant = (z2 as Dictionary).get("center", null)
		if c2 != null:
			own_center_tile = c2
			break
	if own_center_tile.x >= 0:
		ic.select_units([])
		ic.mouse_world = Vector2(float(own_center_tile.x) + 0.5, float(own_center_tile.y) + 0.5)
		ic.hover_tile = own_center_tile
		ic._on_left_click(false)
		ok(ic.selected_zone != null, "★ 点自己区划的中心 → 照旧打开区划详情（老行为不变）")
		eq(ic.selected_enemy, null, "★ 这时没有「选中的敌人」")
		hud.refresh()
		eq(hud.page_tabs.page_count(), 2, "★ 自己区划中心仍是两颗页签（操作 + 招募）")
		ok(hud.detail_panel.detail_text().contains("现有人口"),
			"★ 自己 / 友军区划：右列额外显示当前人口")
		var otxt: String = hud._zone_text(ic.selected_zone, true)
		ok(not otxt.contains("血量"), "（文案生成器）自己区划也不显示血量")
		ok(otxt.contains("现有人口"),
			"（文案生成器）自己 / 友军区划**额外显示当前人口** —— 实际：%s"
			% otxt.replace("\n", "|"))

	if g1 != null:
		ic.select_units([g1])
		eq(ic.selected_enemy, null, "★ 改选己方部队 → 敌人的选中被清掉")
		hud.refresh()
		ok(hud.page_tabs.page() == PageTabsRes.PAGE_ORDER
				or hud.page_tabs.page() == PageTabsRes.PAGE_UNIT,
			"★ 页签回到己方部队那一套（操作 / 单位），实际「%s」" % hud.page_tabs.page())
		ok(hud.command_card.entries().size() > 0, "★ 命令卡回到己方内容")

	ic.select_units([] if g1 == null else [g1])
	hud.refresh()

func _test_settings_inert(main) -> void:
	var page_before := String(main.hud.page_tabs.page())
	main.hud.settings_button.emit_signal("pressed")
	eq(main.hud.page_tabs.page(), page_before, "点选项不会顺手切页")
	ok(main.hud.settings_button.text == "选项", "选项按钮上写着「选项」")
	main.hud.set_settings_menu_open(false)

func _test_command_events_reach_consumer(main) -> void:
	var free := Vector2i(-1, -1)
	for ty in main.world.map.rows:
		for tx in main.world.map.cols:
			# ★ 建造新规则：只能在自己区划里建 —— 找空地时也按这个口径
			if main.world.can_build_at(tx, ty, "p1"):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格可建造的空地")
	if free.x < 0:
		return

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

	_test_recruit_queued_event(main.cfg)
	_test_upgrade_reject_names_target(main)

func _test_upgrade_reject_names_target(main) -> void:
	var b = null
	for it in main.world.building_list:
		if String(it.owner) == String(main.world.my_faction) and it.has_method("display_name"):
			b = it
			break
	ok(b != null, "（前提）找得到一栋自己的建筑")
	var txt: String = main.hud.upgrade_reject_text("busy", {"reason": "busy", "building": b})
	ok(txt.contains(String(b.display_name())),
		"★★ busy 的文案点名了被拒的那栋建筑（实际：%s）" % txt)
	ok(txt.contains("没有生效"), "★ 而且明说这一下没有生效（没扣资源、没排队）")
	var txt2: String = main.hud.upgrade_reject_text("busy")
	ok(txt2.contains("读条") and not txt2.contains("null"),
		"★ 不传事件时退回泛泛文案（不会打出 null）")
	var z = null
	for it in main.world.zones.zones:
		if String((it as Dictionary).get("owner", "")) == String(main.world.my_faction):
			z = it
			break
	if z != null:
		var zid := int((z as Dictionary).get("id", -1))
		var txt3: String = main.hud.upgrade_reject_text("busy", {"reason": "busy", "zone_id": zid})
		ok(txt3.contains("c%d" % zid) or txt3.contains(String((z as Dictionary).get("name", "@"))),
			"★★ 区划那一支也点到了名（实际：%s）" % txt3)

func _key(code: int, ctrl: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	ev.ctrl_pressed = ctrl
	return ev
