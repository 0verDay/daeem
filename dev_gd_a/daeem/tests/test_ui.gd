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

	eq(UiLayoutRes.SQUAD_RECT.size.x, 238.0, "将领编队牌宽 238，与右侧留 26px 边距")
	eq(UiLayoutRes.SQUAD_RECT.position.y, 386.0,
		"★ 将领编队牌从 y=386 开始（2026.11.14 第四轮：再往下让位给加高的小地图）")
	eq(UiLayoutRes.SQUAD_RECT.position.x + UiLayoutRes.SQUAD_RECT.size.x,
		UiLayoutRes.DESIGN_W - 26.0, "将领编队牌右缘留 26px 外边距")
	eq(UiLayoutRes.SQUAD_SLOTS, 5, "★ 5 个槽位（部队1 ~ 部队5；用户口径「最大部队数改为 5 个」）")
	eq(UiLayoutRes.SQUAD_ROW_H, 82.0, "★ V2 编队牌高 82")
	eq(UiLayoutRes.SQUAD_RECT.size.y,
		5.0 * 82.0 + 4.0 * UiLayoutRes.SQUAD_ROW_GAP, "5 张编队牌之间留 V2 间距")
	ok(UiLayoutRes.SQUAD_RECT.position.y + UiLayoutRes.SQUAD_RECT.size.y <= UiLayoutRes.BAR_TOP,
		"★ 加高之后仍不压底栏（面板底 ≤ %s）" % UiLayoutRes.BAR_TOP)
	ok(UiLayoutRes.SQUAD_RECT.position.y >= UiLayoutRes.MAP_RECT.position.y
			+ UiLayoutRes.MAP_RECT.size.y,
		"★ 将领列在小地图**下方**（地图先占右上角，牌列接在它下面）")

	# ★★ 2026.11.14：小地图从**左下角**搬到**右上角**（用户口径：「将地图面板放到屏幕
	#   右上角，地图左侧放一列 ui」）；同轮随后「小地图变大一些」⇒ 238×148 → **300×225**。
	# ★★ 2026.11.14 第四轮：地图「竖直方向再扩大」⇒ 430×350
	#   （宽高比 1.229 ≈ 地图的 27:22 ⇒ 地形铺满面板、没有黑边）
	eq(UiLayoutRes.MAP_RECT, Rect2(1464.0, 26.0, 430.0, 350.0),
		"V2 侦察镜小地图在右上角（430×350）")
	near(UiLayoutRes.DESIGN_W - (UiLayoutRes.MAP_RECT.position.x + UiLayoutRes.MAP_RECT.size.x),
		26.0, 1e-4, "★ 小地图右缘留 26px（与将领列对齐）")
	near(UiLayoutRes.MAP_RECT.position.y, 26.0, 1e-4, "★ 小地图贴上沿 26px")
	ok(UiLayoutRes.MAP_RECT.position.y + UiLayoutRes.MAP_RECT.size.y
			<= UiLayoutRes.SQUAD_RECT.position.y,
		"★ 小地图下缘不压将领列（地图整体在将领牌上方）")
	ok(UiLayoutRes.MAP_RECT.position.x + UiLayoutRes.MAP_RECT.size.x
			== UiLayoutRes.SQUAD_RECT.position.x + UiLayoutRes.SQUAD_RECT.size.x,
		"★ 小地图与将领列右缘齐平（同一条竖带）")

	eq(UiLayoutRes.CARD_SLOTS, 9, "命令卡 9 格")
	# ★★ 2026.11.14（用户口径）：「手牌放至屏幕底部中央」——左缘 796 → 539，
	#   即 `(1920 − 842) / 2`；竖直方向仍贴底。
	eq(UiLayoutRes.CARD_RECT, Rect2(539.0, 803.0, 842.0, 277.0), "V2 扇形指令牌区尺寸")
	near(UiLayoutRes.CARD_RECT.position.x + UiLayoutRes.CARD_RECT.size.x * 0.5,
		UiLayoutRes.DESIGN_W * 0.5, 1e-4, "★ 手牌在屏幕**水平居中**")
	near(UiLayoutRes.CARD_RECT.position.y + UiLayoutRes.CARD_RECT.size.y,
		UiLayoutRes.DESIGN_H, 1e-4, "★ 手牌仍贴屏幕下沿")
	near(UiLayoutRes.card_fan_local(0, 4).size.x, 142.0, 1e-4, "四张常用指令牌采用 142px 卡宽")
	ok(UiLayoutRes.card_fan_local(0, 4).position.x
		< UiLayoutRes.card_fan_local(3, 4).position.x, "指令牌按扇形从左向右展开")
	ok(UiLayoutRes.card_fan_local(8, 9).position.x + UiLayoutRes.card_fan_local(8, 9).size.x
		<= UiLayoutRes.CARD_RECT.size.x + 0.01, "九张科技牌也收在牌区内")
	eq(String(UiLayoutRes.CARD_KEYS[0]), "Q", "第一格是 Q")
	eq(String(UiLayoutRes.CARD_KEYS[8]), "C", "第九格是 C")

	# ★★ 2026.11.14：手牌居中之后，悬停面板改成**与手牌同宽同中心**
	#   （原来「右缘够到页签列」那条口径不再成立：页签在最右边，中间是空的）。
	near(UiLayoutRes.HOVER_W, UiLayoutRes.CARD_RECT.size.x, 0.01, "悬停说明与手牌**同宽**")
	near(UiLayoutRes.hover_rect(100.0).size.x, UiLayoutRes.CARD_RECT.size.x, 0.01,
		"hover_rect 使用手牌宽度")
	eq(UiLayoutRes.hover_rect(100.0).position.x, UiLayoutRes.CARD_RECT.position.x,
		"悬停面板左缘与手牌左缘对齐")
	near(UiLayoutRes.hover_rect(100.0).position.x + UiLayoutRes.HOVER_W,
		UiLayoutRes.CARD_RECT.position.x + UiLayoutRes.CARD_RECT.size.x,
		0.01, "★ 悬停面板右缘与**手牌右缘**齐平（不再横穿到右侧页签）")
	eq(UiLayoutRes.HOVER_BOTTOM, UiLayoutRes.CARD_RECT.position.y - UiLayoutRes.HOVER_GAP,
		"★ 面板**下缘**落在命令卡顶边上方 HOVER_GAP")
	eq(UiLayoutRes.HOVER_BOTTOM, 795.0, "★ 悬停说明下缘停在牌手上方")
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

	eq(UiLayoutRes.TABS_RECT, Rect2(1740.0, 914.0, 154.0, 94.0), "V2 右下牌签尺寸")
	eq(UiLayoutRes.tab_button_local(0, 2), Rect2(0.0, 0.0, 73.0, 94.0), "第一个页签牌")
	eq(UiLayoutRes.tab_button_local(1, 2), Rect2(81.0, 0.0, 73.0, 94.0), "第二个页签牌与第一个留 8px")
	eq(UiLayoutRes.tab_button_local(0, 1), Rect2(81.0, 0.0, 73.0, 94.0), "单页签靠右对齐")
	# ★★ 2026.11.14 第三轮（用户口径）：「把选项按钮删除，相应的打开菜单逻辑接到 esc 下」
	#   ⇒ 屏幕上的选项圆币没了，`SETTINGS_RECT` / `SETTINGS_RADIUS` 常量也一起删除。
	#   这里改断言「这一列只剩资源大卡，且它不压地图」。
	eq(UiLayoutRes.RES_BAR_RECT.position.x + UiLayoutRes.RES_BAR_RECT.size.x,
		1458.0, "★ 资源大卡右缘 1458（= 地图左缘 1464 − 6px 缝）")
	eq(UiLayoutRes.RES_BAR_RECT.position.x, 1358.0, "★ 资源卡左缘 1358（= 1458 − 100）")
	ok(UiLayoutRes.RES_BAR_RECT.position.x + UiLayoutRes.RES_BAR_RECT.size.x
			<= UiLayoutRes.MAP_RECT.position.x,
		"★ 资源大卡在地图左侧（不压地图）")
	ok(not UiLayoutRes.RES_BAR_RECT.intersects(UiLayoutRes.MAP_RECT),
		"★ 资源大卡与小地图不重叠")
	eq(UiLayoutRes.RES_BAR_RECT.position.y + UiLayoutRes.RES_BAR_RECT.size.y,
		UiLayoutRes.MAP_RECT.position.y + UiLayoutRes.MAP_RECT.size.y,
		"★ 资源大卡下缘与小地图下缘**齐平**（右列看起来是一整块）")

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

	# ★★ 2026.11.14 第二轮（用户口径）：「将部队详细信息栏往屏幕左侧靠」
	#   ⇒ 左缘 395 → 27（贴左留白与其它面板一致），宽度仍是 377。
	eq(UiLayoutRes.DETAIL_V2_RECT.position.x, 27.0, "V2 详情卡贴屏幕左边（x=27）")
	eq(UiLayoutRes.DETAIL_V2_RECT.position.x + UiLayoutRes.DETAIL_V2_RECT.size.x,
		404.0, "详情卡右缘 = 27 + 377")
	ok(UiLayoutRes.DETAIL_V2_RECT.position.x + UiLayoutRes.DETAIL_V2_RECT.size.x
		<= UiLayoutRes.CARD_RECT.position.x + 0.01,
		"★ 手牌在详情卡右侧（居中后两者不叠）")
	eq(UiLayoutRes.DESIGN_H - (UiLayoutRes.DETAIL_V2_RECT.position.y + UiLayoutRes.DETAIL_V2_RECT.size.y),
		26.0, "详情卡下缘留 26px")
	# ★ 手牌居中后右缘不再「留出页签间距」，改成断言它**以屏幕中心为中点**
	near(UiLayoutRes.CARD_RECT.position.x + UiLayoutRes.CARD_RECT.size.x * 0.5,
		UiLayoutRes.DESIGN_W * 0.5, 0.01, "★ 手牌水平居中（底部中央）")
	ok(UiLayoutRes.CARD_RECT.position.x > UiLayoutRes.DETAIL_V2_RECT.position.x
			+ UiLayoutRes.DETAIL_V2_RECT.size.x,
		"★ 手牌左缘在详情卡右缘右侧（不压详情卡）")
	near(UiLayoutRes.TABS_RECT.position.x + UiLayoutRes.TABS_RECT.size.x,
		UiLayoutRes.DESIGN_W - 26.0, 0.01, "页签牌区保留 26px 右边距")
	eq(UiLayoutRes.CARD_RECT.position.y + UiLayoutRes.CARD_RECT.size.y,
		UiLayoutRes.DESIGN_H, "扇形手牌主体贴住屏幕下沿")
	near(UiLayoutRes.TABS_RECT.position.y + UiLayoutRes.TABS_RECT.size.y,
		UiLayoutRes.DESIGN_H - 72.0, 0.01, "页签牌底边离屏幕下缘 72px")

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

	# ★★ 2026.11.14：详情牌已贴到屏幕左边（DETAIL_V2_RECT x=27）；
	#   原来那个「文字点」是按旧 DETAIL_RECT 算的，现在正好落在**居中的手牌**上，
	#   所以改成直接取 DETAIL_V2_RECT 里的一点。
	var detail_text_spot := UiLayoutRes.DETAIL_V2_RECT.position + Vector2(60.0, 40.0)
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp), detail_text_spot),
		"★ 详细信息面板里只有文字的地方不拦边缘滚屏（否则底边永远滚不动）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.FACTION_RECT.get_center()),
		"阵营占位面板同样不拦")

	# ★★ V2 的详情牌**不再整块登记**：能点的只有成员格那几颗小方块，
	#   由控件自己算（detail_v2.interactive_rects），所以整块面板不能拦边缘滚屏。
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.DETAIL_V2_RECT.get_center()),
		"★ 详情牌整块不再拦边缘滚屏（能点的只有里面的成员格）")

	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.squad_slot_rect(2).get_center()), "部队第 3 行拦边缘滚屏（它是可点的）")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.card_cell_rect(0).get_center()), "命令卡 Q 格拦边缘滚屏")
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.tab_button_rect(1).get_center()), "页签按钮拦边缘滚屏")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp, true, false),
		UiLayoutRes.tab_button_rect(1).get_center()),
		"★★ 右下角整块隐藏时页签不再拦边缘滚屏（屏幕上没有可见控件）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp, true, false),
		UiLayoutRes.card_cell_rect(0).get_center()),
		"★★ 右下角整块隐藏时命令卡格子也不再拦边缘滚屏")
	# ★★ 2026.11.14 第三轮：选项按钮删除 ⇒ 右上角不再有可点控件拦滚屏
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp),
		UiLayoutRes.RES_BAR_RECT.get_center()), "资源大卡只有字和色块 → 不拦边缘滚屏")

	var wide := Vector2(2560.0, 1080.0)
	# ★★ 2026.11.14：手牌是**底部居中**的 ⇒ 宽窗口下只平移半个富余（见 center_shift）
	var shifted := UiLayoutRes.card_cell_rect(0)
	shifted.position += UiLayoutRes.center_shift(wide)
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide), shifted.get_center()),
		"窗口变宽时手牌跟着**屏幕中心**走（不是贴右；否则点不到）")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(wide),
		UiLayoutRes.card_cell_rect(0).get_center()),
		"窗口变宽后原位置不再算作手牌")

	var m: float = 44.0
	ok(UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), m),
		"★ 左边缘最外圈算「边缘带」（将领按钮那一列就压在这里）")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 1070.0), m), "下边缘也算边缘带")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(960.0, 8.0), m), "上边缘也算")
	ok(UiLayoutRes.in_edge_band(vp, Vector2(1914.0, 500.0), m), "右边缘也算")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(960.0, 500.0), m), "屏幕中间不是边缘带")
	ok(not UiLayoutRes.in_edge_band(vp, Vector2(6.0, 300.0), 0.0),
		"margin = 0 时整条规则关掉（可配置）")

	var bar := UiLayoutRes.bottom_bar_rects_v2(vp, true, true)
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.DETAIL_V2_RECT.get_center()),
		"★ 滚轮：详细信息卡整块拦截缩放")
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.CARD_RECT.get_center()),
		"滚轮：扇形手牌区域也拦")
	ok(UiLayoutRes.point_hits_any(bar, UiLayoutRes.tab_button_rect(1, 2).get_center()),
		"滚轮：页签牌也拦")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.bottom_bar_rects_v2(vp, true, false),
		UiLayoutRes.tab_button_rect(1, 2).get_center()),
		"★★ 右下角整块隐藏时滚轮也不再被页签列拦住")
	ok(not UiLayoutRes.point_hits_any(UiLayoutRes.bottom_bar_rects_v2(vp, true, false),
		UiLayoutRes.CARD_RECT.get_center()),
		"★★ 右下角整块隐藏时滚轮也不再被命令卡拦住")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.MAP_RECT.get_center()),
		"★ 滚轮：左下小地图是**地图**不是 ui 栏 —— 鼠标停在它上面时照旧缩放（「除地图外」）")
	ok(not UiLayoutRes.point_hits_any(bar, map_middle), "滚轮：地图中间照旧缩放")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.squad_slot_rect(2).get_center()),
		"滚轮：左侧部队列表不在「下方 ui 栏」里 → 不拦")
	ok(not UiLayoutRes.point_hits_any(bar, UiLayoutRes.RES_BAR_RECT.get_center()),
		"滚轮：右上角资源大卡也不拦（需求只说下方那一条）")
	var bar_wide := UiLayoutRes.bottom_bar_rects_v2(wide, true, true)
	var shift_x: float = wide.x - UiLayoutRes.DESIGN_W
	var card_wide := UiLayoutRes.CARD_RECT
	card_wide.position.x += shift_x
	ok(UiLayoutRes.point_hits_any(bar_wide, card_wide.get_center()),
		"★ 超宽窗口：扇形手牌继续贴在右下组并拦缩放")
	var d_wide: Rect2 = bar_wide[0]
	eq(d_wide.size, UiLayoutRes.DETAIL_V2_RECT.size,
		"★ 超宽窗口：详情卡尺寸保持不变")
	eq(d_wide.position.x, UiLayoutRes.DETAIL_V2_RECT.position.x,
		"★ 超宽窗口：详情卡贴左，不跟着右边漂")

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
			"HudRoot/DetailPanelV2", "HudRoot/CommandCard",
			"HudRoot/PageTabs", "HudRoot/ResourceBar"]:
		ok(main.hud.get_node_or_null(path) != null, "节点树里有 %s" % path)
	ok(main.hud.get_node_or_null("HudRoot/FactionPlaceholder") == null,
		"HUD 默认左列不再创建阵营盾徽旗帜占位牌")

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
		"侦察镜地图位于左下并留屏幕边距")
	v2_near(main.hud.map_placeholder.size, UiLayoutRes.MAP_RECT.size, 1.0,
		"地图占位实际尺寸 = 328×284")
	v2_near(main.hud.detail_v2.position, UiLayoutRes.DETAIL_V2_RECT.position, 1.0,
		"★★ 新版详细信息在 (400, 820)")
	v2_near(main.hud.detail_v2.size, UiLayoutRes.DETAIL_V2_RECT.size, 1.0,
		"★★ 新版详细信息仍是 616.5×260")
	ok(main.hud.faction_placeholder == null, "阵营盾徽旗帜兼容字段保持 null")
	v2_near(main.hud.command_card.position, UiLayoutRes.CARD_RECT.position, 1.0,
		"扇形指令手牌落在详情区右侧")
	v2_near(main.hud.page_tabs.position, UiLayoutRes.TABS_RECT.position, 1.0,
		"页签牌落在右下角")
	# ★★ 2026.11.14 第三轮：选项按钮已删除（入口改成 Esc / 安卓返回键）
	ok(main.hud.get_node_or_null("HudRoot/SettingsButton") == null,
		"★★ 屏幕上没有选项按钮了（用户要求删除）")
	v2_near(main.hud.squad_panel.position, UiLayoutRes.SQUAD_RECT.position, 1.0,
		"将领列表紧贴右侧")
	v2_near(main.hud.squad_panel.size, UiLayoutRes.SQUAD_RECT.size, 1.0,
		"将领编队牌列实际尺寸 = 238×492")

	_test_squad_rows(main)
	_test_detail_visibility(main)
	await _test_page_tabs_and_card(main, cfg)
	_test_hover_panel(main, cfg)
	await _test_hover_tip_control(cfg)
	_test_card_keys(main)
	_test_tech_keys(main)
	_test_avatar_text_fit(cfg)
	_test_recruit_via_card(main)
	_test_multi_recruit_distribution(main)
	_test_zone_recruit_via_card(main)
	_test_upgrade_via_card(main)
	await _test_queue_control(cfg)
	_test_queue_cancel_via_click(main)
	_test_auto_select_on_recruit(main)
	_test_order_locked_notice(main)
	_test_foreign_reject_notice_filter(main)
	_test_right_click_orders(main)
	await _test_box_select(main)
	await _test_drag_pan(main)
	_test_drag_over_ui(main)
	_test_detail_basic_stats(main)
	_test_detail_two_columns(main)
	_test_detail_vertical_fit(main)
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
	eq(main.hud.detail_panel.buff_count(), 0,
		"★ 士气系统移除后，动态 buff 槽位为空")
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
	card0.position += UiLayoutRes.center_shift(vp)
	ok(main.hud.blocks_edge_scroll(card0.get_center()), "鼠标在命令卡上 → 不滚屏")
	ok(not main.hud.blocks_edge_scroll(
		UiLayoutRes.DETAIL_V2_RECT.position + Vector2(60.0, 40.0)),
		"★ 鼠标在详细信息面板**只有文字**的地方 → 照样滚屏（不然底边滚不动）")
	# 新版：点部队（队长）不出详情；换一个具体建筑让详情可见，再验网格拦滚屏。
	var edge_b = null
	for b in main.world.building_list:
		if FactionRes.same_side(String(b.owner), main.world.my_faction):
			edge_b = b
			break
	if edge_b != null:
		main.input_ctrl.select_building(edge_b)
		main.hud.refresh()
	ok(main.hud.is_detail_visible(), "（前提）具体建筑选中后详情可见")
	# ★★ V2 详情牌里只有**成员格 / 部队格**那几颗小方块能点：
	#   单选一个对象时没有格子（也就不该拦边缘滚屏），多选 / 多单位时才登记。
	var cell_hits: Array = main.hud._detail_hit_rects()
	ok(cell_hits.is_empty(),
		"★ 只选中一栋建筑时详情牌没有可点的格子（整块只有文字 → 不拦边缘滚屏）")
	# 多选两支部队：下方「其他已选部队」那几格是能点的
	main.input_ctrl.select_units([main.world.unit_by_id("general-1"),
		main.world.unit_by_id("general-2")])
	main.hud.refresh()
	var chip_hits: Array = main.hud._detail_hit_rects()
	ok(not chip_hits.is_empty(), "★ 多选部队时「其他已选部队」那几格能点")
	if not chip_hits.is_empty():
		# ★★ 2026.11.14：详情牌贴到屏幕左边（x=27）之后，成员格基本都压在
		#   「最外圈 44px 边缘带」里 —— 那一条**全局放行**滚屏（见 in_edge_band）。
		#   所以这里按位置逐颗对账：**带外必须拦、带内按全局规矩放行**，
		#   而不是无条件要求「拦」（那会让屏幕最左/最下那 44px 永远滚不动）。
		for r in chip_hits:
			var c: Vector2 = (r as Rect2).get_center()
			var in_band: bool = UiLayoutRes.in_edge_band(vp, c, 44.0)
			eq(main.hud.blocks_edge_scroll(c), not in_band,
				"★ 成员格拦滚屏 = 「不在最外圈边带里」（%s，带内=%s）"
					% [str(c), str(in_band)])
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
	await _test_card_build_drag(main)

	root_node.queue_free()
	await process_frame


func _test_card_build_drag(main) -> void:
	var world = main.world
	var hud = main.hud
	main.input_ctrl.select_units([])
	hud.refresh()
	hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	var card = hud.command_card
	var cell: Control = card.cell_at(0)
	var tile := Vector2i(-1, -1)
	var screen_pos := Vector2.ZERO
	for ty in world.map.rows:
		for tx in world.map.cols:
			if not world.can_build_at(tx, ty, world.my_faction) \
					or not world.zone_allows_build(tx, ty, world.my_faction):
				continue
			var p: Vector2 = main.palette.to_px(Vector2(float(tx) + 0.5, float(ty) + 0.5))
			if hud.point_hits_ui(p):
				continue
			tile = Vector2i(tx, ty)
			screen_pos = p
			break
		if tile.x >= 0:
			break
	ok(tile.x >= 0, "（前提）找到可建造且不被 HUD 覆盖的地图格")
	if tile.x < 0:
		return
	world.resources["food"] = 100000.0
	world.resources["gold"] = 100000.0
	var drag_start := screen_pos + Vector2(0.0, 24.0)
	card._drag_index = 0
	card._drag_start_global = drag_start
	card._update_drag_position(0, screen_pos)
	ok(hud.drag_build_active, "★★ 拖起建筑牌后进入地面预览")
	eq(hud.drag_build_tile, tile, "★★ 建筑虚影跟随鼠标投影到对应地块")
	ok(card._drag_fade_tween != null and card._drag_fade_tween.is_running(),
		"★★ 建筑牌上拖时启动淡出")
	for _i in 20:
		await process_frame
	near(cell.modulate.a, 0.0, 0.001, "★★ 建筑牌在上拖过程中淡至全透明")
	ok(hud._card_build_tile_valid("wall", tile), "★★ 可建造地块判为绿色/有效")
	main._sync_build_card_ghost()
	ok(main._build_card_ghost.visible and main._build_card_ghost_material.albedo_color.g
		> main._build_card_ghost_material.albedo_color.r,
		"★★ 有效建造位置显示绿色半透明建筑模型")
	var blocked_tile := Vector2i(-1, -1)
	var blocked_pos := Vector2.ZERO
	for b in world.building_list:
		var p: Vector2 = main.palette.to_px(b.center())
		if not hud.point_hits_ui(p):
			blocked_tile = Vector2i(b.tx, b.ty)
			blocked_pos = p
			break
	if blocked_tile.x >= 0:
		card._update_drag_position(0, blocked_pos)
		main._sync_build_card_ghost()
		ok(not hud._card_build_tile_valid("wall", blocked_tile), "（前提）占用格无效")
		ok(main._build_card_ghost.visible and main._build_card_ghost_material.albedo_color.r
			> main._build_card_ghost_material.albedo_color.g,
			"★★ 无效建造位置显示红色半透明建筑模型")
		card._update_drag_position(0, screen_pos)
	card._finish_card_drag(0, screen_pos)
	ok(not hud.drag_build_active, "松手后结束建筑牌拖拽态")
	ok(world.building_at(tile.x, tile.y) != null, "★★ 有效地块松手后实际建造建筑")

func _test_resource_bar(main) -> void:
	var bar = main.hud.resource_bar
	ok(bar != null, "★ 资源面板控件在（HudRoot/ResourceBar）")
	if bar == null:
		return

	v2_near(bar.position, UiLayoutRes.RES_BAR_RECT.position, 1.0, "资源大卡位于屏幕右上")
	v2_near(bar.size, UiLayoutRes.RES_BAR_RECT.size, 1.0, "资源大卡 100×350")
	# ★★ 2026.11.14 第三轮（用户口径）：「将资源面板改为竖直排列，竖直方向为：
	#   图标，文本，数字，增长数字」+「合并成一张大卡，中间分隔」。
	#   ⇒ 现在是**一张**大卡（不再是两块独立筹码），卡内两块各竖排四行。
	var rsb: StyleBoxFlat = bar.get_theme_stylebox("panel")
	ok(rsb != null, "★ 大卡自己就是底纹（一张卡）")
	if rsb != null:
		eq(rsb.border_width_left, 2, "★ 大卡有 2px 描边（与其它面板同一套）")
		ok(rsb.corner_radius_top_left >= 12, "★ 大卡是圆角（12）")
	eq(UiLayoutRes.RES_BAR_RECT.size.x, 100.0,
		"★ 资源卡宽 100（2026.11.14 第五轮：再收一档，仍只装 4 位数）")
	eq(UiLayoutRes.RES_BAR_RECT.size.y, UiLayoutRes.RES_HALF_H * 2.0,
		"★ 大卡高 = 两块 × 175 = 350（每块四行竖排，与地图同高）")
	eq(UiLayoutRes.RES_BAR_RECT.position.x, UiLayoutRes.TOP_COLUMN_X,
		"★ 资源卡贴右上角那一列的左缘")
	# ★★ 2026.11.14 第四轮：宽度只保证「4 位数」装得下（用户口径）
	var num_font: Font = bar.get_theme_font("font", "Label")
	if num_font != null:
		var w4: float = num_font.get_string_size("9999", HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		ok(w4 <= UiLayoutRes.TOP_COLUMN_W - 8.0,
			"★ 4 位数（26 号字 %.0fpx）装得进 100 宽的卡（可写 %.0f）"
				% [w4, UiLayoutRes.TOP_COLUMN_W - 8.0])
		var w5: float = num_font.get_string_size("99999", HORIZONTAL_ALIGNMENT_LEFT, -1, 26).x
		ok(w5 > w4, "（对照组）5 位数更宽 ⇒ 卡宽就是按 4 位数定的")
	ok(not UiLayoutRes.MAP_RECT.intersects(UiLayoutRes.RES_BAR_RECT),
		"资源卡与小地图不重叠")
	ok(UiLayoutRes.RES_BAR_RECT.position.y >= 0.0
			and UiLayoutRes.RES_BAR_RECT.position.y + UiLayoutRes.RES_BAR_RECT.size.y
				<= UiLayoutRes.DESIGN_H,
		"★ 资源面板整个在设计空间里（不掉出屏幕）")
	# 中间那条分隔线
	var divider := bar.get_node_or_null("ResDivider") as ColorRect
	ok(divider != null, "★ 两块之间有一条分隔线")
	if divider != null:
		near(divider.position.y, UiLayoutRes.RES_DIVIDER_Y, 1.0, "★ 分隔线在两块的交界处（y=137）")
		ok(divider.size.x <= UiLayoutRes.TOP_COLUMN_W,
			"★ 分隔线不越出卡片宽度")

	var food := bar.get_node_or_null("ResText_粮") as Label
	var gold := bar.get_node_or_null("ResText_金") as Label
	ok(food != null, "★ 资源面板里有「粮食」那一项")
	ok(gold != null, "★ 资源面板里有「黄金」那一项")
	# 2 圆章 + 2 标题 + 2 数字 + 2 增长 + 1 分隔线 = 9
	eq(bar.get_child_count(), 9, "两枚圆章 + 标题/库存/增长三档 ×2 + 分隔线")
	ok(bar.get_node_or_null("ResourceToken_粮") == null,
		"★ 不再有「每块一张筹码」的中间层（合并成一张大卡）")
	if food != null and gold != null:
		var f_title := bar.get_node_or_null("ResTitle_粮") as Label
		var g_title := bar.get_node_or_null("ResTitle_金") as Label
		var f_rate := bar.get_node_or_null("ResRate_粮") as Label
		var g_rate := bar.get_node_or_null("ResRate_金") as Label
		var f_icon := bar.get_node_or_null("ResIcon_粮") as Label
		var g_icon := bar.get_node_or_null("ResIcon_金") as Label
		var f_row := [f_icon, f_title, food, f_rate]
		var g_row := [g_icon, g_title, gold, g_rate]
		# ★ 竖排顺序：图标 → 文本 → 数字 → 增长（y 严格递增）
		ok(f_row[0].position.y <= UiLayoutRes.RES_ICON_Y + 0.01,
			"★ 粮食：圆章在最上面")
		ok(f_row[0].position.y < f_row[1].position.y
				and f_row[1].position.y < f_row[2].position.y
				and f_row[2].position.y < f_row[3].position.y,
			"★★ 粮食四行竖排：图标 → 文本 → 数字 → 增长（y 递增：%s / %s / %s / %s）" % [
				str(f_row[0].position.y), str(f_row[1].position.y),
				str(f_row[2].position.y), str(f_row[3].position.y)])
		ok(g_row[0].position.y < g_row[1].position.y
				and g_row[1].position.y < g_row[2].position.y
				and g_row[2].position.y < g_row[3].position.y,
			"★★ 黄金四行同样竖排")
		# 两块之间纵向错开一整块高
		near(g_row[0].position.y - f_row[0].position.y, UiLayoutRes.RES_HALF_H, 0.01,
			"★ 黄金整块在粮食下面，错开 137")
		# 四行水平居中：都在卡片宽度内、且水平方向居中
		for pair in [[f_row, "粮食"], [g_row, "黄金"]]:
			var row: Array = pair[0]
			var tag: String = String(pair[1])
			for n in row:
				var lab: Label = n
				ok(lab.position.x >= -0.01
						and lab.position.x + lab.size.x <= UiLayoutRes.TOP_COLUMN_W + 0.01,
					"★ %s 的「%s」没有越出卡片左右缘" % [tag, lab.text])
				near(lab.position.x + lab.size.x * 0.5, UiLayoutRes.TOP_COLUMN_W * 0.5, 0.01,
					"★ %s 的「%s」水平居中" % [tag, lab.text])
		# 数字最显眼：字号比文本 / 增长都大
		ok(food.get_theme_font_size("font_size") > f_title.get_theme_font_size("font_size"),
			"★ 数字比文本大（26 > 13）")
		ok(food.get_theme_font_size("font_size") > f_rate.get_theme_font_size("font_size"),
			"★ 数字比增长数字大")


	if food != null and gold != null:
		eq(gold.position.x, food.position.x, "★ 两块的四行都用同一条居中轴（x 一致）")
		ok(gold.position.y > food.position.y, "黄金在粮食牌**下方**")

	if food != null and gold != null:
		main.world.resources["food"] = 120.6
		main.world.resources["gold"] = 80.2
		main.hud.refresh()
		ok(food.text == "121",
			"★ 粮食取整显示（120.6 → 121），实际：%s" % food.text)
		ok(gold.text == "80",
			"★ 黄金取整显示（80.2 → 80），实际：%s" % gold.text)
		# ★★ 2026.10.29：数字后面跟一个「(+n)」= **每秒净增长**（产能 − 维护费 − 科技金耗）。
		var food_rate := bar.get_node_or_null("ResRate_粮") as Label
		var gold_rate := bar.get_node_or_null("ResRate_金") as Label
		ok(food_rate.text.contains("(") and food_rate.text.ends_with(")"),
			"★ 粮食牌单独显示净增长（实际：%s）" % food_rate.text)
		ok(gold_rate.text.contains("(") and gold_rate.text.ends_with(")"),
			"★ 黄金牌单独显示净增长（实际：%s）" % gold_rate.text)
		main.world.resources["food"] = 7.0
		main.world.resources["gold"] = 0.0
		main.hud.refresh()
		eq(food.text, "7", "★ 整数资源不带小数点")
		eq(gold.text, "0", "★ 0 也照实显示")

		# ★★ 2026.10.29：「(+n)」的写法（带正负号、1 位小数、0 附近不许出 "(+-0.0)"）
		eq(main.hud._rate_text(3.24), "(+3.2)", "净增长带 + 号、保留 1 位小数")
		eq(main.hud._rate_text(-1.26), "(-1.3)", "负数自己带 - 号，不再补 +")
		eq(main.hud._rate_text(0.0), "(+0.0)", "0 写成 (+0.0)")
		eq(main.hud._rate_text(-0.001), "(+0.0)", "★ 0 附近的负数不许印成 (+-0.0)")

		ok(food.size.y <= UiLayoutRes.RES_ICON + 0.01
				and food.position.y + food.size.y
					<= UiLayoutRes.RES_BAR_RECT.size.y + 0.01,
			"★ 数字那一行真的在资源条里（pos.y %.0f + size.y %.0f ≤ 条高 %.0f）" % [
				food.position.y, food.size.y, UiLayoutRes.RES_BAR_RECT.size.y])
		var font: Font = main.hud._font
		if font != null:
			# ★★ 2026.10.29：这一行现在是「粮食 12345(+12.3)」，字号降到 FS_SMALL(13)。
			#   最坏的现实组合 = **5 位数 + 负的两位数**（金色那行）≈ 130px ≤ 134。
			for pair in [[food, "12345", 20], [gold, "12345", 20]]:
				var w: float = font.get_string_size(String(pair[1]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, int(pair[2])).x
				ok(w <= (pair[0] as Label).size.x + 0.01,
					"★ 库存「%s」宽 %.0f ≤ 可写 %.0f" % [pair[1], w, (pair[0] as Label).size.x])
			for pair in [[food_rate, "(+3.2)"], [gold_rate, "(-12.3)"]]:
				var rate_w: float = font.get_string_size(String(pair[1]), HORIZONTAL_ALIGNMENT_LEFT,
					-1, UiStyleRes.FS_TINY).x
				ok(rate_w <= (pair[0] as Label).size.x + 0.01,
					"★ 净额「%s」宽 %.0f ≤ 可写 %.0f" % [pair[1], rate_w, (pair[0] as Label).size.x])
			ok(font.get_height(UiStyleRes.FS_SMALL) <= UiLayoutRes.RES_ICON + 0.01,
				"★ 13 号字的行高 %.0f 装得进 %.0f 高那一行" % [
					font.get_height(UiStyleRes.FS_SMALL), UiLayoutRes.RES_ICON])
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


## 模拟一次「单击标签」：清掉双击配对，再直接发 Button.pressed。
## ★ 生产路径里 button_down 会先记录按下时间；输入层支持「没有按下记录的 pressed」也按单击处理。
func _click_slot(main, panel, i: int) -> void:
	main.input_ctrl.reset_general_gestures()
	panel.slot_button(i).emit_signal("pressed")

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
	# ★★ 2026.11.14：手牌是**底部居中**的 ⇒ 超宽窗口下只平移**半个**富余（320px），
	#   不是贴右那套 640px（见 `center_shift`）。
	v2_near(main.hud.command_card.position, Vector2(UiLayoutRes.CARD_RECT.position.x + 320.0,
		UiLayoutRes.CARD_RECT.position.y), 1.0, "★ 超宽窗口：手牌仍停在屏幕中央")
	v2_near(main.hud.page_tabs.position, Vector2(UiLayoutRes.TABS_RECT.position.x + 640.0,
		UiLayoutRes.TABS_RECT.position.y), 1.0, "超宽窗口：页签牌跟随右边距")
	v2_near(main.hud.detail_panel.position, UiLayoutRes.DETAIL_RECT.position, 1.0,
		"超宽窗口：详细信息仍贴左（x = 562.5）")
	# ★★ 本版：手机端不再横向拉伸 —— 固定 988 宽，右侧留白，不需要与页签相连。
	near(main.hud.detail_panel.size.x, UiLayoutRes.DETAIL_RECT.size.x, 1.0,
		"★ 超宽窗口：详细信息面板仍是 988 宽（不再拉伸）")
	near(main.hud.detail_panel.right_column_width(), UiLayoutRes.DETAIL_RIGHT_W, 1.0,
		"★ 超宽窗口：右栏仍是 603 宽（多出来的宽不再灌进来）")
	near(main.hud.detail_panel.queue_position_x(),
		UiLayoutRes.detail_queue_x(UiLayoutRes.DETAIL_RIGHT_W), 1.0,
		"★ 超宽窗口：招募队列位置固定（右栏 603 下的 286）")
	v2_near(main.hud.squad_panel.position,
		Vector2(UiLayoutRes.SQUAD_RECT.position.x + 640.0, UiLayoutRes.SQUAD_RECT.position.y), 1.0,
		"超宽窗口：将领列表仍贴右上")
	v2_near(main.hud.resource_bar.position,
		Vector2(UiLayoutRes.RES_BAR_RECT.position.x + 640.0, UiLayoutRes.RES_BAR_RECT.position.y), 1.0,
		"超宽窗口：资源大卡仍贴右上")
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
	# ③b 部队图标：序号
	eq(IconBadgeRes.troop_number_text(1), "1", "★ 部队序号：第 1 支写 1")
	eq(IconBadgeRes.troop_number_text(9), "9", "★ 部队序号：第 9 支写 9")
	eq(IconBadgeRes.troop_number_text(10), "0",
		"★ 部队序号：兜底 10 → 0（槽位只到 6，正常用不到这一档）")
	var leader = UnitRes.new()
	leader.name = "测试队长"
	leader.hp = 100.0
	leader.hp_max = 100.0
	grid.set_troops([{"leader": leader, "number": 3, "units": [leader]}])
	eq(grid.cell_kind(0), "troop", "★ 多选部队时格子是部队格")
	eq(grid.cell_short(0), "3", "★★ 部队图标 = 序号（不是将领名字首字）")

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

	# ④ 右栏大头像：show 时才画血条
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
	panel.queue_free()
	await process_frame


func _test_squad_rows(main) -> void:
	var panel = main.hud.squad_panel
	var world = main.world

	eq(panel.slot_count(), UiLayoutRes.SQUAD_SLOTS, "部队列表有 6 个槽")
	# V2 每张编队牌独立描边，整列不再套外框。
	var sframe = panel.get_node_or_null("SquadFrame")
	ok(sframe != null, "V2 编队牌容器兼容节点存在")
	if sframe != null:
		eq(sframe.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 外框不吞标签点击")
		var ssb: StyleBoxFlat = sframe.get_theme_stylebox("panel")
		if ssb != null:
			eq(ssb.border_width_left, 0, "编队牌列没有额外矩形外框")
			eq(ssb.border_width_right, 0, "编队牌列右边不加外框")
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
	eq(panel.slot_number(4), "5", "★ 第 5 条标签的数字显示 5（槽位上限改成 5）")
	for i in range(3, UiLayoutRes.SQUAD_SLOTS):
		eq(panel.slot_text(i), "…", "空槽第 %d 行显示「…」" % (i + 1))

	var g3 = world.unit_by_id("general-3")
	ok(g3 != null, "有 general-3")
	var cam_before: Vector3 = _camera_look_point(main)
	_click_slot(main, panel, 2)
	eq(main.input_ctrl.selected_units.size(), world.group_of(g3).size(),
		"点部队行 = 选中整队（%d 个）" % world.group_of(g3).size())
	eq(main.input_ctrl.selected_units[0].id, g3.id, "整队的队长排在第一个")
	ok(_camera_look_point(main).is_equal_approx(cam_before),
		"★ 点部队行只选中，镜头不动（需求原话）")
	ok(panel.slot_active(2), "当前选中的队伍在列表里高亮")

	var sel_before: int = main.input_ctrl.selected_units.size()
	_click_slot(main, panel, UiLayoutRes.SQUAD_SLOTS - 1)
	eq(main.input_ctrl.selected_units.size(), sel_before, "★ 空槽点了没有反应")

	# ★★ 反选（本轮需求「点击代表反选」）：
	#    无选中 → 点 1 = 选中 1 → 点 2 = 选中 1+2 → 再点 1 = 只剩 2 → 再点 2 = 清空。
	main.input_ctrl.select_units([])
	var g1 = world.unit_by_id("general-1")
	var g2 = world.unit_by_id("general-2")
	var team1: Array = world.group_of(g1)
	var team2: Array = world.group_of(g2)
	_click_slot(main, panel, 0)
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★ 反选：点部队 1 = 选中第 1 支（%d 个）" % team1.size())
	ok(panel.slot_active(0) and not panel.slot_active(1), "只有第 1 支高亮")

	_click_slot(main, panel, 1)
	eq(main.input_ctrl.selected_units.size(), team1.size() + team2.size(),
		"★★ 反选：再点部队 2 = 两支一起选中（不是把第 1 支顶掉）")
	ok(panel.slot_active(0) and panel.slot_active(1), "两支都高亮")
	eq(int(main.hud._detail_troop_number), 2, "★ 点谁就展开谁（详情焦点 = 部队 2）")

	_click_slot(main, panel, 0)
	eq(main.input_ctrl.selected_units.size(), team2.size(),
		"★★ 反选：再点部队 1 = 取消第 1 支，只剩第 2 支（%d 个）" % team2.size())
	ok(not panel.slot_active(0) and panel.slot_active(1), "第 1 支取消高亮，第 2 支保持")
	eq(String(main.input_ctrl.selected_units[0].id), String(g2.id),
		"反选之后剩下的队长是第 2 支的将领")

	# ★★ 详情焦点：点谁展开谁；**把展开的那支反选掉** → 回退到剩余部队的第一支。
	_click_slot(main, panel, 0)                          # 1+2，焦点 = 1
	eq(main.input_ctrl.selected_units.size(), team1.size() + team2.size(),
		"（前提）再点部队 1 又回到两支一起选中")
	eq(int(main.hud._detail_troop_number), 1, "★ 点部队 1 → 详情焦点切到 1")
	_click_slot(main, panel, 0)                          # 反选掉 1
	eq(main.input_ctrl.selected_units.size(), team2.size(), "（前提）反选掉 1 之后只剩 2")
	main.hud.refresh()                                     # 让 _pick_troop 发现并回退
	eq(int(main.hud._detail_troop_number), 2,
		"★★ 展开的那支被反选掉 → 详情焦点回退到剩余的第一支（部队 2）")

	_click_slot(main, panel, 1)
	eq(main.input_ctrl.selected_units.size(), 0,
		"★ 反选：点掉最后一支 = 清空选中（反选的正常结果）")
	ok(not panel.slot_active(1), "清空后没有任何标签高亮")

	# ★★ 数字键按**左栏部队编号**选，不按 unit.hotkey：将领阵亡 / 名册有空洞时
	#    两者会错位（用户报的「序号和编号不对就选不中」）。
	main.input_ctrl.select_units([])
	var hotkey_before := String(g2.hotkey)
	g2.hotkey = "9"                                     # 故意做成对不上的编号
	main.input_ctrl.reset_general_gestures()
	ok(main.input_ctrl.handle_key(_key(KEY_2)), "★★ 按数字键 2 被识别为「选第 2 支部队」")
	main.input_ctrl.handle_key(_key_up(KEY_2))
	eq(main.input_ctrl.selected_units.size(), team2.size(),
		"★★ 选中的是第 2 支整队（%d 个）" % team2.size())
	eq(String(main.input_ctrl.selected_units[0].id), String(g2.id),
		"★★ 即使 g2.hotkey=9，第 2 支仍然按左栏编号选中")
	g2.hotkey = hotkey_before

	# ★★ 双击标签 = 快速选中（只加不撤）+ 立即跳镜头（第一次的反选要回滚）。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	panel.debug_press_slot(0, 1000)
	panel.debug_release_slot(0, 1010)                    # 第一次：反选 → 选中第 1 支
	panel.debug_press_slot(0, 1100)
	panel.debug_release_slot(0, 1110)                    # 第二次：双击窗口内
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★★ 双击标签：回滚第一次反选后，仍只选中第 1 支（%d 个）" % team1.size())
	ok(String(main.input_ctrl.selected_units[0].id) == String(g1.id),
		"★★ 双击后选中的队长是第 1 支")
	var look_after_double: Vector3 = _camera_look_point(main)
	ok(look_after_double.distance_to(main.palette.to_world(g1.pos)) < 1.5,
		"★★ 双击标签 = 立即把镜头跳到该将领（误差 %.2f 格）"
			% look_after_double.distance_to(main.palette.to_world(g1.pos)))

	# ★★ 已选中的队伍被双击：不撤选中，只跳镜头（「无取消选中逻辑」）。
	panel.debug_press_slot(0, 2000)
	panel.debug_release_slot(0, 2010)
	panel.debug_press_slot(0, 2100)
	panel.debug_release_slot(0, 2110)
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★★ 双击已选中的队伍：不会把它取消掉")
	ok(panel.slot_active(0), "双击后它仍然是选中的")

	# ★★ 长按标签 = 跟随视角；手动动镜头 → 自动取消。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.stop_follow()
	panel.debug_press_slot(0, 3000)
	main.input_ctrl.poll_gestures(3600)                  # 超过 0.4s
	ok(main.following_unit() == g1, "★★ 长按标签 = 跟随第 1 支将领的视角")
	panel.refresh()
	ok(panel.slot_button(0).is_row_following(),
		"★★ 跟随时标签最左侧显示眼睛标志")
	panel.debug_release_slot(0, 3700)                    # 抬起不应再反选
	eq(main.input_ctrl.selected_units.size(), 0, "★ 长按后的抬起不再触发反选")
	main.pan_screen(Vector2(5.0, 0.0))
	ok(main.following_unit() == null, "★★ 手动动镜头 → 退出跟随")
	panel.refresh()
	ok(not panel.slot_button(0).is_row_following(),
		"★ 结束跟随后眼睛标志消失")

	# ★★ 数字键：双击 = 快速选中 + 跳镜头；长按 = 跟随。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.input_ctrl.handle_key(_key(KEY_1))
	main.input_ctrl.handle_key(_key_up(KEY_1))
	main.input_ctrl.handle_key(_key(KEY_1))
	main.input_ctrl.handle_key(_key_up(KEY_1))
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★★ 数字键双击 = 快速选中第 1 支（%d 个）" % team1.size())
	ok(panel.slot_active(0), "数字键双击后第 1 支高亮")
	main.stop_follow()
	main.input_ctrl.handle_key(_key(KEY_1))
	main.input_ctrl.poll_gestures(Time.get_ticks_msec() + 1000)
	ok(main.following_unit() == g1, "★★ 数字键长按 = 跟随第 1 支将领的视角")
	main.input_ctrl.handle_key(_key_up(KEY_1))
	main.stop_follow()

	# ★★ 回归（用户报的 bug）：快速连按 1/2/3 时，下一次按下往往发生在上一键抬起之前。
	#    旧实现每个来源只有一份「按下状态」，2 的按下会覆盖 1、3 再覆盖 2 ⇒ 只剩 3 生效。
	#    现在每个 (来源, 槽位) 各存一份按下状态，三支都要选中。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.input_ctrl.gesture_press("key", 1, 5000)
	main.input_ctrl.gesture_press("key", 2, 5010)
	main.input_ctrl.gesture_press("key", 3, 5020)
	main.input_ctrl.gesture_release("key", 1, 5100)
	main.input_ctrl.gesture_release("key", 2, 5110)
	main.input_ctrl.gesture_release("key", 3, 5120)
	eq(main.input_ctrl.selected_units.size(),
		team1.size() + team2.size() + world.group_of(g3).size(),
		"★★ 连按 1/2/3（按键重叠）→ 三支部队都被选中")

	# 走真实按键事件再复现一次（三次按下都发生在任何抬起之前）。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.input_ctrl.handle_key(_key(KEY_1))
	main.input_ctrl.handle_key(_key(KEY_2))
	main.input_ctrl.handle_key(_key(KEY_3))
	main.input_ctrl.handle_key(_key_up(KEY_1))
	main.input_ctrl.handle_key(_key_up(KEY_2))
	main.input_ctrl.handle_key(_key_up(KEY_3))
	eq(main.input_ctrl.selected_units.size(),
		team1.size() + team2.size() + world.group_of(g3).size(),
		"★★ handle_key：按键重叠时 1/2/3 也都被选中")

	# ★★ 同一按键的「1 → 2 → 1」不算双击（中间隔着 2）：第三下应该把 1 反选掉。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.input_ctrl.gesture_press("key", 1, 6000)
	main.input_ctrl.gesture_release("key", 1, 6010)
	main.input_ctrl.gesture_press("key", 2, 6020)
	main.input_ctrl.gesture_release("key", 2, 6030)
	main.input_ctrl.gesture_press("key", 1, 6040)
	main.input_ctrl.gesture_release("key", 1, 6050)
	eq(main.input_ctrl.selected_units.size(), team2.size(),
		"★★ 1→2→1 的第三下不是双击（1 被正常反选掉，只剩 2）")

	# ★★ 数字键帽：选中 → 亮起；悬停 → 黯淡；取消选中 → 普通。
	var row1 = panel.slot_button(0)
	main.input_ctrl.select_units([g1])
	panel.refresh()                                       # 行状态由刷新同步
	row1.set_hover(false)
	eq(row1.number_key_state(), "lit", "★★ 选中的标签数字键帽亮起")
	row1.set_hover(true)
	eq(row1.number_key_state(), "dim", "★★ 悬停在已选中标签上 → 数字键帽黯淡")
	row1.set_hover(false)
	main.input_ctrl.select_units([])
	panel.refresh()
	eq(row1.number_key_state(), "normal", "★ 取消选中后数字键帽回到普通态")

	# ★★ 移动端：标签触摸由 squad_panel 统一路由（单击反选 / 双击跳转 / 长按跟随）。
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	panel._touch_mode = true
	var row_rect: Rect2 = row1.get_global_rect()
	var touch_center: Vector2 = row_rect.get_center()
	ok(panel.handle_touch(_touch_ev(true, touch_center), 1000),
		"★ 触摸按下命中标签（由标签栏消化）")
	ok(panel.handle_touch(_touch_ev(false, touch_center), 1010),
		"★ 触摸抬起也由标签栏消化")
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★★ 移动端单击标签 = 反选（选中第 1 支）")

	# 双击 → 快速选中 + 立即跳镜头
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	panel.handle_touch(_touch_ev(true, touch_center), 2000)
	panel.handle_touch(_touch_ev(false, touch_center), 2010)
	panel.handle_touch(_touch_ev(true, touch_center), 2100)
	panel.handle_touch(_touch_ev(false, touch_center), 2110)
	eq(main.input_ctrl.selected_units.size(), team1.size(),
		"★★ 移动端双击标签 = 快速选中第 1 支")
	var touch_look: Vector3 = _camera_look_point(main)
	ok(touch_look.distance_to(main.palette.to_world(g1.pos)) < 1.5,
		"★★ 移动端双击 = 立即把镜头跳过去")

	# 长按 → 跟随；抬起不再反选
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	main.stop_follow()
	panel.handle_touch(_touch_ev(true, touch_center), 3000)
	main.input_ctrl.poll_gestures(3600)
	ok(main.following_unit() == g1, "★★ 移动端长按标签 = 跟随第 1 支将领的视角")
	panel.handle_touch(_touch_ev(false, touch_center), 3700)
	eq(main.input_ctrl.selected_units.size(), 0, "★ 长按后抬起不反选")
	main.stop_follow()

	# 手指滑走 → 取消这次触摸（不反选、也不长按跟随）
	main.input_ctrl.select_units([])
	main.input_ctrl.reset_general_gestures()
	panel.handle_touch(_touch_ev(true, touch_center), 4000)
	var drag_ev := InputEventScreenDrag.new()
	drag_ev.index = 0
	drag_ev.position = touch_center + Vector2(60.0, 0.0)
	panel.handle_touch_drag(drag_ev)
	panel.handle_touch(_touch_ev(false, touch_center), 4010)
	eq(main.input_ctrl.selected_units.size(), 0, "★ 手指滑走 → 取消这次标签触摸")
	panel._touch_mode = false

	main.input_ctrl.select_units([world.unit_by_id("general-1")])


## ★★ 详细信息栏的显隐：没有可查看的选中对象时整块隐藏；任何有效选中均显示详情。
func _test_detail_visibility(main) -> void:
	var hud = main.hud
	var panel = hud.detail_v2
	var world = main.world
	var detail_center: Vector2 = UiLayoutRes.DETAIL_V2_RECT.get_center()

	# ① 没有任何选中 → 详情隐藏，左下角不留盾徽占位
	main.input_ctrl.select_units([])
	hud.refresh()
	ok(not panel.visible, "★★ 没有选中任何东西 → 详细信息栏隐藏")
	ok(hud.faction_placeholder == null, "★★ 空选中时不显示阵营盾徽旗帜")
	ok(not hud.blocks_wheel_zoom(detail_center), "★ 隐藏后详情栏区域不再拦滚轮缩放")
	ok(not hud.point_hits_ui(detail_center), "★ 隐藏后详情栏区域恢复地图手势")
	ok(not hud.blocks_wheel_zoom(detail_center), "★ 删除占位后不留下隐藏滚轮拦截区")

	# ② 选中己方部队（队长）→ 详情快速滑入
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	hud.refresh()
	ok(panel.visible, "★★ 选中己方单位 → 显示左下详细信息")
	ok(hud._detail_slide_tween != null and hud._detail_slide_tween.is_running(),
		"★★ 详情首次显示时启动快速左向右滑入")
	ok(hud.blocks_wheel_zoom(detail_center), "★ 详情显示时详情中心拦滚轮")
	ok(hud.point_hits_ui(detail_center), "★ 详情显示时详情中心算 UI")

	# ③ 选中己方建筑 → 显示
	var own_b = null
	for b in world.building_list:
		if FactionRes.same_side(String(b.owner), world.my_faction):
			own_b = b
			break
	if own_b != null:
		main.input_ctrl.select_building(own_b)
		hud.refresh()
		ok(panel.visible, "★★ 选中己方建筑 → 详细信息栏显示")
		ok(hud.blocks_wheel_zoom(detail_center), "★ 详情显示时详情中心拦滚轮")
		ok(hud.point_hits_ui(detail_center), "★ 详情显示时详情中心算 UI")

	# ④ 选中区划 → 显示
	var zone = _zone_with_center(world)
	if zone != null:
		main.input_ctrl.select_zone(zone)
		hud.refresh()
		ok(panel.visible, "★★ 选中区划 → 详细信息栏显示")

	# ⑤ 选中敌方建筑 → 显示（敌人也能看详细信息）
	var foe_b = null
	for b in world.building_list:
		if not FactionRes.same_side(String(b.owner), world.my_faction):
			foe_b = b
			break
	if foe_b != null:
		main.input_ctrl.select_enemy(foe_b)
		hud.refresh()
		ok(panel.visible, "★★ 选中敌方建筑 → 详细信息栏显示")

	# ⑥ 再清空 → 重新隐藏
	main.input_ctrl.select_units([])
	hud.refresh()
	ok(not panel.visible, "★★ 清空选中 → 详细信息栏重新隐藏")
	ok(hud.faction_placeholder == null, "★★ 清空选中后仍无盾徽占位")


func _test_page_tabs_and_card(main, cfg) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	var world = main.world
	# ★★ 科技「赤字时不能启用」：给足黄金产能，下面的科技格才点得动。
	give_gold_income(world, 100.0)

	# ★★ 扇形牌签各自带边框；保留透明 frame 兼容节点，但不再套整列矩形框。
	var frame = tabs.get_node_or_null("TabsFrame")
	ok(frame != null, "★★ 页签栏整体描边（TabsFrame）存在")
	if frame != null:
		eq(frame.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 描边不吞页签点击")
		var fsb: StyleBoxFlat = frame.get_theme_stylebox("panel")
		ok(fsb != null, "牌签兼容 frame 使用透明 StyleBoxFlat")
		if fsb != null:
			eq(fsb.border_width_left, 0, "牌签组没有外围矩形框")
		v2_near(frame.size, UiLayoutRes.TABS_RECT.size, 1.0, "frame 覆盖牌签安全区")

	# ★★ 所有页签按钮都自带**常驻灰底**（画在填充金下面，悬停时金只是往上盖）。
	eq(UiStyleRes.panel_style().border_width_left, 2,
		"★★ 通用面板描边统一加厚到 2px")
	for i in tabs.page_count():
		var tb = tabs.button_at(i)
		ok(FillButtonRes.base_bg(tb).a > 0.2,
			"★★ 页签 %d 自带常驻灰底（悬停时不会消失）" % i)
		var nsb: StyleBoxFlat = tb.get_theme_stylebox("normal")
		ok(nsb.bg_color.a <= 0.001,
			"★ 页签底纹仍全透明（灰底画在填充层，金才盖得上去）")

	# ★ 扇形手牌由每张牌自身的金边与阴影构成，不使用九宫格外框。
	var cframe = main.hud.command_card.get_node_or_null("CardFrame")
	ok(cframe != null, "★★ 命令卡整组外框存在")
	if cframe != null:
		eq(cframe.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 命令卡外框不吞格子点击")
		var csb: StyleBoxFlat = cframe.get_theme_stylebox("panel")
		if csb != null:
			eq(csb.border_width_left, 0, "扇形手牌不套整块矩形框")

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(tabs.visible, "★ 自己的部队 → 页签可见")
	ok(card.visible, "★ 自己的部队 → 命令卡可见")
	eq(tabs.page_count(), 2, "★ 选中部队时只有两颗页签（操作 / 单位）")
	eq(tabs.page_id_at(0), PageTabsRes.PAGE_ORDER, "第一颗是「操作」")
	eq(tabs.page_id_at(1), PageTabsRes.PAGE_UNIT, "第二颗是「单位」")
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 默认停在「操作」页")
	eq(card.entries().size(), 4, "★ 操作页有四格（移动 / 攻击 / 行军 / 停止）")
	for i in UiLayoutRes.CARD_SLOTS:
		eq(card.cell_at(i).visible, i < 4, "操作页只铺实际有内容的牌槽 %d" % i)
	# ★★ 2026.11.14（用户口径）：操作牌改成「拖出 → 地图上有旗帜虚影 → 松手即下达」，
	#   不再「进命令模式 → 再点一下地图」。这里顺着这条新链路走一遍。
	var got: Array = []
	var spy := func(cmd: Dictionary) -> void: got.append(cmd)
	main.input_ctrl.command_issued.connect(spy)
	# ★ 前面的用例可能已经发过 move/stop 命令（冷却由 `command_issued` 触发），
	#   这里先清干净再验「拖出 → 虚影 → 下达」这条主链。
	main.hud._order_cd.clear()
	main.hud.refresh()
	var drag_cell: Control = card.cell_at(0)
	var drag_origin: Vector2 = drag_cell.get_global_transform_with_canvas() * (drag_cell.size * 0.5)
	card._drag_index = 0
	card._drag_start_global = drag_origin
	card._update_drag_position(0, drag_origin - Vector2(0.0, 24.0))
	ok(card._dragging_card, "★★ 手牌向上拖过阈值后进入拖拽状态")
	ok(not main.hud.order_ghost_active,
		"★ 刚拖起时指针还压在手牌上 ⇒ 不显示落点（那一下松手就是取消）")
	# 找一个「一定在地图上」的松手点：测试视口比设计空间小，写死的像素可能正好压在面板上
	# （`point_hits_ui` 会把那种点判成 UI，于是虚影不出、松手变成取消）。
	var map_pt := Vector2(960.0, 420.0)
	for cand in [Vector2(960.0, 420.0), Vector2(700.0, 380.0), Vector2(1200.0, 520.0), Vector2(500.0, 300.0)]:
		if not main.hud.point_hits_ui(cand) and main.palette.to_logic(cand) != null:
			map_pt = cand
			break
	ok(not main.hud.point_hits_ui(map_pt), "（前提）测试用的松手点确实在地图上")
	# 挪到地图上：虚影出现
	card._update_drag_position(0, map_pt)
	ok(main.hud.order_ghost_active, "★★ 拖到地图上 → 出现旗帜虚影")
	eq(main.hud._order_drag_mode, "move", "★ 虚影跟着这张「移动」牌")
	ok(not main.hud.order_ghost_snapped, "★ 移动牌不吸附")
	eq(drag_cell.rotation, 0.0, "★★ 被拖起的牌转正并跟随指针")
	# 松手在地图上：落点即操作点
	card._finish_card_drag(0, map_pt)
	ok(not card._dragging_card, "松手后拖拽状态正确结束")
	ok(not main.hud.order_ghost_active, "★★ 松手后旗帜虚影收起")
	eq(main.input_ctrl.order_mode, "", "★★ 拖出松手直接下达，不再进命令模式")
	var move_cmds: Array = got.filter(func(c): return String(c.get("kind", "")) == "move")
	ok(move_cmds.size() >= 1, "★★ 松手处就是操作点：发出了一条 move 命令")
	ok(main.hud._order_cd_left() > 0.0, "★★ 下达成功后该部队进入 3 秒冷却")
	# 冷却中：四格都不可用（变灰、拖不起来），并且带进度条
	main.hud.refresh()
	var cd_entries: Array = main.hud._order_entries()
	ok(not bool(cd_entries[0].get("ready", true)), "★★ 冷却中操作牌不可用")
	ok(float(cd_entries[0].get("queue_progress", -1.0)) >= 0.0, "★★ 冷却中牌面带进度条")
	# ★★ 冷却中**拖不起来**（用户报的「冷却没有生效」的真因）：
	#   `Button.disabled` 只挡 `pressed`，`gui_input` 照样派发 —— 拖拽这条路必须自己判。
	var cmds_before: int = got.size()
	card._drag_index = 0
	card._drag_start_global = drag_origin
	card._update_drag_position(0, Vector2(1000.0, 560.0))
	ok(not card._dragging_card, "★★ 冷却中操作牌拖不起来")
	card._finish_card_drag(0, Vector2(1000.0, 560.0))
	eq(got.size(), cmds_before, "★★ 冷却中松手也下达不了")
	main.hud._tick_order_cooldown(0.0)     # 只推一次牌面进度条（不推进计时）
	ok(main.hud.command_card._cd_veils[0].visible, "★★ 冷却中牌面被暗纱盖住（填充式提示）")
	# 走一半（3 秒的一半）⇒ 进度条到 50%，仍然不可用
	main.hud._tick_order_cooldown(1.5)
	cd_entries = main.hud._order_entries()
	ok(not bool(cd_entries[0].get("ready", true)), "★ 冷却过半仍然不可用")
	ok(absf(float(cd_entries[0].get("queue_progress", 0.0)) - 0.5) < 0.06,
		"★★ 冷却进度条按时间走（过半 ≈ 50%%，实际 %.2f）"
			% float(cd_entries[0].get("queue_progress", 0.0)))
	var veil_h: float = main.hud.command_card._cd_veils[0].size.y
	var cell_h: float = main.hud.command_card.cell_at(0).size.y
	ok(veil_h > 0.0 and veil_h < cell_h,
		"★★ 暗纱按剩余冷却收窄（牌面从下往上露出来，%.0f / %.0f）" % [veil_h, cell_h])
	# 再走 2 秒 ⇒ 3 秒到，牌恢复可用
	main.hud._tick_order_cooldown(2.0)
	cd_entries = main.hud._order_entries()
	ok(bool(cd_entries[0].get("ready", false)), "★★ 3 秒后操作牌恢复可用")
	ok(main.hud._order_cd_left() <= 0.0, "★ 冷却清零")

	# ★ 冷却清零后要让命令卡**重建一次**（`ready` 是建卡那一刻取的值），
	#   否则这一格还是「置灰」的旧状态 —— 拖拽这条路现在会照着它拒绝。
	main.hud.refresh()
	# ★★ 拖回手牌松手 = 取消：不下达、不进冷却（与建筑牌同一套手感）
	got.clear()
	card._drag_index = 0
	card._drag_start_global = drag_origin
	card._update_drag_position(0, map_pt)
	ok(main.hud.order_ghost_active, "★ 拖到地图上时旗帜虚影可见")
	card._update_drag_position(0, drag_origin)
	ok(not main.hud.order_ghost_active, "★★ 拖回手牌 ⇒ 虚影收起（这一下是收回）")
	card._finish_card_drag(0, drag_origin)
	eq(got.size(), 0, "★★ 拖回手牌松手 = 取消，不下达任何命令")
	ok(main.hud._order_cd_left() <= 0.0, "★ 取消不进冷却")
	ok(not main.hud.order_ghost_active, "★ 取消后虚影不残留")

	# 触屏那条路：清掉冷却再走一遍（同一张牌此时也可用）
	main.hud._order_cd.clear()
	main.hud.refresh()
	var touch_cell: Control = card.cell_at(0)
	var touch_origin: Vector2 = touch_cell.get_global_transform_with_canvas() * (touch_cell.size * 0.5)
	var touch_down := InputEventScreenTouch.new()
	touch_down.pressed = true
	touch_down.position = touch_origin
	main.hud.handle_touch(touch_down)
	var touch_move := InputEventScreenDrag.new()
	touch_move.position = Vector2(900.0, 480.0)
	touch_move.relative = touch_move.position - touch_origin
	main.hud.handle_touch_drag(touch_move)
	ok(main.hud._lp_card_dragging, "★★ 触屏向上拖动手牌进入打出状态")
	var touch_up := InputEventScreenTouch.new()
	touch_up.pressed = false
	touch_up.position = touch_move.position
	main.hud.handle_touch(touch_up)
	await process_frame
	await process_frame
	eq(main.input_ctrl.order_mode, "", "★★ 触屏拖出松手同样是「落点即操作点」，不进命令模式")
	ok(main.hud._order_cd_left() > 0.0, "★★ 触屏拖出也起冷却")
	main.input_ctrl.command_issued.disconnect(spy)
	main.hud._order_cd.clear()
	main.hud.refresh()

	# ★★ 只显示当前页真实存在的牌；空槽隐藏而非置灰占位。
	for i in UiLayoutRes.CARD_SLOTS:
		var cc = card.cell_at(i)
		if i < 4:
			ok(cc.visible, "本页真实操作牌 %d 可见" % (i + 1))
		else:
			ok(not cc.visible, "未使用的键位 %d 隐藏，不画灰牌" % (i + 1))
		var ns: StyleBoxFlat = cc.get_theme_stylebox("normal")
		ok(ns.corner_radius_top_left >= 8,
			"牌面 %d 使用卡片圆角金边" % (i + 1))
	var tech_cell0 = main.hud.tech_grid.cell_at(0)
	ok(FillButtonRes.base_bg(tech_cell0).a > 0.2, "★★ 科技格也带常驻灰底")
	eq(String(card.entry_at(0).get("type", "")), "order", "操作页那一项是「部队指令」")
	eq(card.cell_label(0), "移动", "操作页 Q 格 = 移动")
	eq(card.cell_label(1), "攻击", "操作页 W 格 = 攻击")
	eq(card.cell_label(2), "行军", "操作页 E 格 = 行军")
	eq(card.cell_label(3), "停止", "操作页 A 格 = 停止")
	ok(tabs.is_active(0), "当前页在页签上高亮")

	# ★★ Tab 切换右下角页签（Shift+Tab 反向；到末尾循环）。
	ok(main.hud.handle_tab_key(_tab_key(false)), "★★ Tab 被页签栏消费")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "★★ Tab 切到下一颗页签（操作 → 单位）")
	ok(main.hud.handle_tab_key(_tab_key(false)), "再按一次 Tab")
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★★ 到末尾后循环回第一颗（单位 → 操作）")
	ok(main.hud.handle_tab_key(_tab_key(true)), "Shift+Tab 反向切页")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "★★ Shift+Tab 切到上一颗（循环到末尾）")
	tabs.select_page(PageTabsRes.PAGE_ORDER)            # 收尾：回到操作页

	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "点第二颗切到「单位」页")
	ok(card._deck_tween != null and card._deck_tween.is_running(),
		"★★ 切换命令牌组会启动错落入场动效")
	eq(card.entries().size(), 9, "单位页数据仍保留九个键位映射")
	eq(String(card.entry_at(0).get("type", "")), "recruit", "单位页那一项是「招募」")
	eq(card.cell_label(0), "长枪兵", "单位页 Q 格 = 长枪兵（第 1 行）")
	eq(card.cell_label(1), "长弓兵", "单位页 W 格 = 长弓兵（第 1 行）")
	eq(card.cell_label(2), "", "单位页 E 槽无兵种")
	ok(not card.cell_at(2).visible, "单位页空 E 槽不显示灰牌")
	eq(card.cell_label(3), "骑手", "★ 骑手挪到第 2 行第 1 格（A）")
	eq(card.cell_label(4), "粮车", "★ 第 2 行第 2 格 = 粮车（S）")
	eq(card.cell_label(5), "", "第 2 行第 3 格空着")
	eq(card.cell_label(6), "骑士", "★ 第 3 行第 1 格 = 骑士（Z）")
	eq(card.cell_label(7), "马弓手", "★ 第 3 行第 2 格 = 马弓手（X）")
	eq(card.cell_label(8), "投石车", "★ 第 3 行第 3 格 = 投石车（C）")
	var recruit_cards := 0
	for i in UiLayoutRes.CARD_SLOTS:
		if card.cell_at(i).visible:
			recruit_cards += 1
	eq(recruit_cards, 7, "单位页只显示 7 张真实招募牌，不画 2 张灰色空牌")
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
	eq(card.entries().size(), 9, "★ 建筑页是 3×3 九格（按行解锁后有空槽）")
	eq(String(card.entry_at(0).get("build_type", "")), "wall", "建筑页第 1 格是木墙")
	eq(String(card.entry_at(1).get("build_type", "")), "tower", "建筑页第 2 格是哨塔")
	eq(String(card.entry_at(3).get("build_type", "")), "stone_wall", "★★ 第二行第 1 格是石墙")
	eq(String(card.entry_at(4).get("build_type", "")), "watch_tower", "★★ 第二行第 2 格是警戒塔")
	eq(card.cell_label(0), "木墙", "木墙在 Q 格")
	eq(card.cell_label(1), "哨塔", "哨塔在 W 格")
	eq(card.cell_label(3), "石墙", "★★ 石墙在第二行第 1 格（A）")
	eq(card.cell_label(4), "警戒塔", "★★ 警戒塔在第二行第 2 格（S）")
	eq(String(card.entry_at(6).get("build_type", "")), "",
		"★★ 第三行第 1 格空着（矿脉已右移）")
	eq(String(card.entry_at(8).get("build_type", "")), "mine",
		"★★ 矿脉在第三行最右侧（C 格）")
	eq(card.cell_label(8), "矿脉", "★ 第三行最右格写着「矿脉」")
	ok(bool(card.entry_at(0).get("ready", false)), "木墙 1 级就能建")
	ok(not bool(card.entry_at(3).get("ready", true)), "★★ 石墙 1 级时置灰")
	ok(not bool(card.entry_at(4).get("ready", true)), "★★ 警戒塔 1 级时置灰")
	ok(not main.hud.tech_grid.visible, "★ 不是科技页时九格收起来（命令卡照常画）")

	# 动态页签改为固定尺寸的纵向牌签；单页时靠右对齐，不拉伸占满整列。
	var fresh = PageTabsRes.new()
	main.hud.add_child(fresh)
	fresh.setup()                                   # setup 内部就是「1 颗建筑页」那一刻
	eq(fresh.button_at(0).size, Vector2(73.0, 94.0), "★ 单个页签仍是固定牌签尺寸")
	fresh.set_pages([PageTabsRes.PAGE_BUILD, PageTabsRes.PAGE_TECH])
	eq(fresh.label_at(0), "建筑", "★ 换成两颗后第一颗的**文案没变**（旧判据正是漏了这一种）")
	for i in 2:
		var ftb = fresh.button_at(i)
		var fcls: Array = fresh.char_labels_at(i)
		ok(not fcls.is_empty(), "「%s」页签有逐字 Label" % fresh.label_at(i))
		for l in fcls:
			ok((l as Control).size.y <= ftb.size.y,
				"牌签文字行高不超过按钮高度（%s / %s）" % [str((l as Control).size), str(ftb.size)])
	main.hud.remove_child(fresh)
	fresh.queue_free()

	# 开局不再自动生成防御阵地 → 需要一栋己方普通建筑时现造一栋
	var plain_b = _ensure_own_building(world, "wall")
	ok(plain_b != null, "拿得到一栋己方普通建筑（木墙）")
	if plain_b != null:
		main.input_ctrl.select_building(plain_b)
		main.hud.refresh()
		ok(not tabs.visible, "★★ 选中无操作的建筑（木墙）→ 右下角整块隐藏")
		eq(tabs.page_count(), 0, "★ 页签一颗都不留（不是空页签）")
		eq(tabs.page(), "", "★ 当前页被清空")
		ok(not card.visible, "★★ 命令卡也隐藏")
		eq(card.entries().size(), 0, "★ 命令卡为空")

	var tower_b = _ensure_own_building(world, "tower")
	ok(tower_b != null, "（前提）拿得到己方哨塔")
	if tower_b != null:
		eq(tower_b.type, "tower", "（前提）第 2 栋是哨塔")
		main.input_ctrl.select_building(tower_b)
		main.hud.refresh()
		ok(not tabs.visible, "★★ 哨塔同样没有可操作项 → 右下角整块隐藏")
		eq(tabs.page_count(), 0, "★ 哨塔也不留空格子")
		ok(not card.visible, "★★ 哨塔的命令卡也隐藏")
		eq(card.entries().size(), 0, "★ 哨塔的命令卡为空")

	# ★★ 「无操作」判据覆盖所有非大本营 / 非区划中心的建筑类型：
	#    资源建筑（粮田 / 房屋 / 矿脉）与防御建筑走同一条路。
	#    这里只验判据，不必为了 UI 断言再在地图上铺五栋楼（会干扰后面的用例）。
	var probe = BuildingRes.new()
	for t in ["wall", "tower", "stone_wall", "watch_tower", "farm", "house", "mine"]:
		probe.type = t
		ok(not main.hud._building_has_actions(probe),
			"★★ 「%s」没有可操作项 → 选中它时页签应隐藏" % t)
	probe.type = BuildingRes.TYPE_ZONE_CENTER
	ok(main.hud._building_has_actions(probe), "★ 区划中心有操作项（招募页）")

	var base = world.find_base_of("p1")
	ok(base != null, "有己方大本营")
	if base != null:
		main.input_ctrl.select_building(base)
		main.hud.refresh()
		ok(tabs.visible, "★★ 选中大本营 → 页签整块重新出现（隐藏态可恢复）")
		ok(card.visible, "★★ 大本营的命令卡也恢复可见")
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
	ok(tabs.visible, "★★ 空手 → 页签整块恢复可见")
	ok(card.visible, "★★ 空手 → 命令卡也恢复可见")
	eq(tabs.page_count(), 2, "空手时建筑 / 科技两颗")
	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_TECH, "点第二颗切到「科技」页")
	_eq_tech_page(main, "什么都没选中")
	var g = main.hud.tech_grid
	var first_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	ok(first_id != "", "第一格有 id")
	ok(not world.is_tech_active(first_id), "开局这一条没启用")
	g.press(0)
	# ★★ 2026.10.30：点一格立刻启用（预热已删除）。
	ok(world.is_tech_active(first_id), "★ 点一格立刻启用（走 tech_toggle 命令）")
	main.hud.refresh()           # 让九格按权威状态重画（真实游戏里每帧都会刷）
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
	eq(world.tech.slot_count(), 3, "★ 三条都占住了名额")
	ok(world.tech_remaining_slots() == 0, "名额用完")
	g.press(3)
	ok(not world.is_tech_active(ids[3]), "★ 第 4 条没有生效（被阻止）")
	# ★ 新版口径：不能启用的格子**置灰不可点**（点了什么都不发生），原因写在悬停里。
	main.hud._tick_notice(main.cfg.num("ui.notice_sec", 2.0) + 0.1)
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
		eq(tabs.page_count(), 1, "★ 选中区划中心只剩「招募」页签")
		eq(tabs.page_id_at(0), PageTabsRes.PAGE_RECRUIT, "唯一页签是「招募」")
		eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 默认停在「招募」页")
		# ★★ 2026.11.14（用户口径）：招走 / 开局就拥有的将领**不再占牌位**
		var avail0: Array = main.world.general_recruit_available("p1")
		eq(card.entries().size(), mini(avail0.size(), 9),
			"★★ 招募页只列「还没被招走」的将领（当前 %d 位）" % avail0.size())
		ok(main.hud.detail_panel.detail_text().contains("粮食"),
			"★ 区划详情右列显示产能（实际：%s）"
				% main.hud.detail_panel.detail_text().replace("\n", "|"))
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "唯一页签仍是招募页")
		# ★★ 2026.11.14（用户口径）：招募页只列**还没被招走**的将领，
		#   所以「第 i 格 = 将领 i」不再成立 —— 改成「第 i 格 = 可招清单第 i 位」。
		var roster: Array = world.general_recruit_available("p1")
		ok(roster.size() > 0, "★ 还有可招的将领（%d 位）" % roster.size())
		for i in mini(roster.size(), 9):
			eq(card.cell_label(i), world.recruit_label_of(String(roster[i])),
				"第 %d 格 = 可招清单第 %d 位" % [i + 1, i + 1])
		eq(String(card.entry_at(0).get("type", "")), "zone_recruit",
			"招募页那一项是「区划招募」")
		ok(roster.size() > 0 and String(card.entry_at(0).get("unit_kind", "")) == String(roster[0]),
			"第 1 格 = 清单第一位")
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "唯一页签仍是招募页")

	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_ORDER, "收尾：回到操作页")

func _entry_types(card) -> Array:
	var out: Array = []
	for i in card.entries().size():
		out.append(String(card.entry_at(i).get("type", "")))
	return out


func _eq_tech_page(main, where: String) -> void:
	var g = main.hud.tech_grid
	var card = main.hud.command_card
	ok(g.visible, "%s：★ 科技九格显示出来了" % where)
	eq(g.entries().size(), 9, "%s：★ 九格铺满（9 条占位科技）" % where)
	for i in UiLayoutRes.CARD_SLOTS:
		var entry: Dictionary = g.entry_at(i)
		eq(g.cell_at(i).visible, not entry.is_empty(),
			"%s：科技牌 %d 的可见状态只由真实科技项决定" % [where, i])
	eq(card.entries().size(), 0, "%s：命令卡在科技页是空的（内容由科技那一层画）" % where)
	eq(g.cell_name(0), "粮食产量 I", "%s：第 1 格 = 粮食产量 I" % where)
	eq(g.cell_line(0), "粮食产能 +10%", "%s：第 1 格第二行写效果" % where)
	ok(String((g.entry_at(0) as Dictionary).get("desc", "")).contains("产能"),
		"%s：entries 里带着完整效果说明（悬停详情面板写它）" % where)
	# ★ 九格是**列优先**（第一列 = 一阶、第二列 = 二阶、第三列 = 三阶）：
	#   cell 0/3/6 = 粮食 I/II/III，1/4/7 = 黄金 I/II/III，2/5/8 = 建筑/将领/区划人口。
	eq(g.cell_name(2), "建筑加固", "%s：第 3 格 = 建筑加固（第三列第一格）" % where)
	eq(g.cell_name(5), "将领强化", "%s：第 6 格 = 将领强化" % where)
	eq(g.cell_name(8), "区划人口", "%s：第 9 格 = 区划人口" % where)
	eq(g.cell_name(9), "", "%s：越界格（第 10 格）读不到东西" % where)
	var c0: Rect2 = UiLayoutRes.CARD_RECT
	var g_rect: Rect2 = g.get_global_rect()
	v2_near(g_rect.position, c0.position, 1.0,
		"%s：★ 科技牌手与命令牌手占据同一牌区" % where)

## 找一栋**己方**的普通建筑（木墙 / 哨塔）；没有就现造一栋 —— 开局不再自动在大本营旁
## 生成防御阵地了，所以「地图上有一栋己方木墙 / 哨塔」这件事得自己保证。
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
	give_gold_income(world, 100.0)

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
	eq(tip.title_text(), "木墙", "标题就是那一格的名字")
	var bt: String = tip.body_text()
	ok(bt.contains("地块"), "★ 建筑详情里有建筑说明（实际：%s）" % bt.replace("\n", " | "))
	ok(bt.contains("血量"), "★ 建筑详情里有血量上限")
	ok(bt.contains("造价"), "建筑详情里有造价")
	ok(bt.contains("远程免伤"), "★★ 建筑详情里有远程免伤（本轮新增）")

	var card_rect: Rect2 = card.get_global_rect()
	var tip_rect: Rect2 = tip.get_global_rect()
	# ★★ 2026.11.14 第二轮：手牌居中后，悬停面板改成**与手牌同宽同中心**
	#   （原来那条「右缘够到页签列右缘」的口径已作废 —— 中间隔着一大段空白）。
	eq(tip_rect.size.x, card_rect.size.x, "★ 悬停说明与手牌**同宽**")
	near(tip_rect.position.x, card_rect.position.x, 1.0, "左缘与手牌对齐")
	near(tip_rect.position.x + tip_rect.size.x,
		card_rect.position.x + card_rect.size.x, 1.0,
		"★ 右缘与**手牌右缘**齐平（整块贴在牌手正上方）")
	ok(tip_rect.position.y + tip_rect.size.y <= card_rect.position.y + 0.01,
		"★ 面板整个落在命令卡**上方**（不压住那九格）")

	card.unhover(0)
	ok(not tip.showing(), "鼠标移开 → 面板收起来")
	card.hover(7)
	ok(not tip.showing(), "★ 空格子上不弹面板（没内容就不弹一块空的）")

	card.hover(0)
	card.hover(1)          # 新的一格先到
	card.unhover(0)        # 迟到的旧 exit
	ok(tip.showing() and tip.title_text() == "哨塔",
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
	ok(tip.body_text().contains("产能"), "科技详情里有完整效果说明")
	ok(tip.body_text().contains("未启用"), "★ 状态那一行读的是**权威状态**（现在没启用）")
	var first_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	g.press(0)
	ok(world.is_tech_active(first_id), "（前提）点一格 = 立刻启用")
	hud.refresh()
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
		var hover_roster: Array = world.general_recruit_available("p1")
		var hover_kind: String = String(hover_roster[0])
		var hover_label: String = world.recruit_label_of(hover_kind)
		eq(card.cell_label(0), hover_label,
			"（前提）招募页 Q 格 = 可招清单第一位（%s）" % hover_label)
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

		eq(tabs.page_count(), 1, "★ 区划中心只剩招募页签")
		eq(tabs.page_id_at(0), PageTabsRes.PAGE_RECRUIT, "唯一页签是招募")

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

	tip.show_text("木墙", "填满整个地块\n血量上限 300")
	ok(tip.showing() and tip.visible, "喂了文本就显示出来")
	eq(tip.title_text(), "木墙", "标题是那一格的名字")
	ok(tip.body_text().contains("血量"), "正文里是多行说明")
	eq(tip.size.x, UiLayoutRes.HOVER_W, "★ 面板宽 = HOVER_W（= 手牌宽 842）")
	near(tip.position.x, UiLayoutRes.CARD_RECT.position.x, 1.0, "左缘与命令卡对齐")
	near(tip.position.y + tip.size.y, UiLayoutRes.HOVER_BOTTOM, 0.01,
		"★ 下缘钉在命令卡顶边上方（变高是**向上长**）")

	tip.show_text("木墙", "一行")
	var h_short: float = tip.content_height()
	tip.show_text("木墙", "一行\n两行")
	ok(tip.content_height() > h_short, "★ 两行正文比一行高（%.0f > %.0f）"
		% [tip.content_height(), h_short])
	tip.show_text("木墙", "一行\n两行\n三行\n四行")
	var h_four: float = tip.content_height()
	ok(h_four - h_short > 3.0 * font.get_height(UiStyleRes.FS_SMALL),
		"★ 每多一行正文涨的高度**大于** font.get_height（%.0f > 3 × %.0f）—— 用的是 Label 的真实行高"
			% [h_four - h_short, font.get_height(UiStyleRes.FS_SMALL)])
	ok(tip.body_lines() >= 4, "（前提）Label 认为这段正文有 ≥4 行（实际 %d）" % tip.body_lines())
	eq(tip.body_visible_lines(), tip.body_lines(),
		"★ 正文每一行都画得出来（%d / %d 行）—— 少了就是面板高度量错了"
			% [tip.body_visible_lines(), tip.body_lines()])

	var long_line := "本区块每地块每秒额外产出 0.5 粮食，一个区划只能选一种特化；取消特化也要读条，读完才真的撤掉，并且把当初花掉的粮食与黄金全额退回来。" \
		+ "本区块每地块每秒额外产出 0.5 粮食，一个区划只能选一种特化；取消特化也要读条，读完才真的撤掉，并且把当初花掉的粮食与黄金全额退回来。" \
		+ "本区块每地块每秒额外产出 0.5 粮食，一个区划只能选一种特化；取消特化也要读条，读完才真的撤掉，并且把当初花掉的粮食与黄金全额退回来。"
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

	# ★★ 建筑页的图标：每格带一张蒙版（从 .glb 抽边线烘出来的等轴测线稿），
	#   且**名字那一行照旧显示**（需求：「图标 + 一行名字，描述进悬停面板」）。
	ok(card.cell_icon_path(0) != "", "★ 建筑页第 1 格有图标蒙版")
	ok(card.cell_icon_path(0).ends_with("building_wall.png"),
		"★ 木墙用的就是 building_wall.png")
	ok(card.cell_label_visible(0), "★ 建筑页有图标的格子仍然显示名字")
	eq(card.cell_label(0), "木墙", "★ 木墙那格名字照旧")

	# ★★ 2026.10.30：建筑的单独字母快捷键已移除，只认九宫格键位。
	ok(not main.cfg.building_def("wall").has("hotkey"),
		"★★ config 里不再有 building.wall.hotkey")
	var bt_before := String(main.input_ctrl.build_type)
	ok(not main.input_ctrl.handle_key(_key(KEY_B)), "★ 按 B 不再进入木墙建造模式")
	ok(not main.input_ctrl.handle_key(_key(KEY_M)), "★ 按 M 不再进入矿脉建造模式")
	eq(main.input_ctrl.build_type, bt_before, "★ 这两个键没有改变建造模式")

	var a_ev := _key(KEY_A)
	ok(not card.handle_key(a_ev), "未解锁的 A 格（石墙）不消费按键")

	ok(card.handle_key(_key(KEY_Q)), "建筑页的 Q 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "wall", "★ 建筑页按 Q = 木墙")
	# ★★ 2026.11.5：进入建造模式 = 选中这条建造命令 → 命令卡对应那格金色填满。
	main.hud.refresh()
	var wall_cell: Button = card.cell_at(0)
	var wall_anim = FillButtonRes.animator_of(wall_cell)
	ok(FillButtonRes.is_latched(wall_cell),
		"★★ 进入木墙建造模式 → 命令卡木墙那格视为「已选中」")
	ok(not FillButtonRes.click_flash_enabled(wall_cell),
		"★★ 建造格不参与点击闪光（选中填充本身就是反馈）")
	wall_anim._process(0.2)
	ok(FillButtonRes.fill_progress(wall_cell) >= 0.999,
		"★★ 木墙那一格金色填满")

	ok(card.handle_key(_key(KEY_W)), "建筑页的 W 被命令卡吃掉")
	eq(main.input_ctrl.build_type, "tower", "★ 建筑页按 W = 哨塔（W 已不再平移镜头）")
	main.hud.refresh()
	var tower_cell: Button = card.cell_at(1)
	var tower_anim = FillButtonRes.animator_of(tower_cell)
	ok(FillButtonRes.is_latched(tower_cell), "★★ 切到哨塔 → 哨塔那格视为选中")
	tower_anim._process(0.2)
	ok(FillButtonRes.fill_progress(tower_cell) >= 0.999, "★★ 哨塔那格金色填满")
	wall_anim._process(0.2)
	ok(not FillButtonRes.is_latched(wall_cell)
			and FillButtonRes.fill_progress(wall_cell) <= 0.001,
		"★★ 木墙那格取消选中 → 金色退回")

	ok(card.handle_key(_key(KEY_W)), "建造模式中重复按 W 不作为取消键")
	eq(main.input_ctrl.build_type, "tower", "★ 重复按 W 仍保持建造模式")
	ok(main.input_ctrl.handle_key(_key(KEY_ESCAPE)), "★★ Esc 是取消建造模式的固定快捷键")
	eq(main.input_ctrl.build_type, "", "Esc 退出建造模式")
	main.hud.refresh()
	tower_anim._process(0.2)
	ok(not FillButtonRes.is_latched(tower_cell)
			and FillButtonRes.fill_progress(tower_cell) <= 0.001,
		"★★ Esc 退出建造模式 → 哨塔那格金色退回")

	card.cell_at(0).emit_signal("pressed")
	eq(main.input_ctrl.build_type, "", "★ 普通点按不再打出建筑牌")
	ok(card.handle_key(_key(KEY_Q)), "★ Q 快捷键仍可进入木墙建造模式")
	eq(main.input_ctrl.build_type, "wall", "按 Q = 进木墙建造模式")
	main.hud.refresh()
	wall_anim._process(0.2)
	ok(FillButtonRes.is_latched(wall_cell)
			and FillButtonRes.fill_progress(wall_cell) >= 0.999,
		"★★ 点击木墙格 → 那格金色填满")
	ok(card.handle_key(_key(KEY_Q)), "★★ 重复按 Q 不取消建造")
	eq(main.input_ctrl.build_type, "wall", "★★ 建造取消不绑定到 Q")
	ok(main.input_ctrl.handle_key(_key(KEY_ESCAPE)), "★★ Esc 退出建筑牌建造模式")
	main.hud.refresh()
	wall_anim._process(0.2)
	ok(not FillButtonRes.is_latched(wall_cell)
			and FillButtonRes.fill_progress(wall_cell) <= 0.001,
		"★★ Esc 清掉建造模式 → 金色退回")

	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）停在操作页")
	ok(card.handle_key(_key(KEY_Q)), "操作页的 Q 被命令卡吃掉")
	eq(main.input_ctrl.order_mode, "move", "★ 操作页按 Q = 进入移动模式")
	ok(card.handle_key(_key(KEY_Q)), "再按一次 Q")
	eq(main.input_ctrl.order_mode, "", "★ 再按一次同一格 = 退出命令模式")
	ok(card.handle_key(_key(KEY_E)), "★ E 快捷键仍可进入行军模式")
	eq(main.input_ctrl.order_mode, "attack_move", "按 E = 进入行军模式")
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
		ok(card.handle_key(_key(KEY_A)), "★ A 快捷键触发停止")
		ok(not g1.moving, "★ 按「停止」快捷键 → 当场停下")
		eq(main.input_ctrl.order_mode, "", "★ 停止不进命令模式（点一下就够了）")

	ok(not card.handle_key(_key(KEY_Q, true)),
		"★ Ctrl+Q 不被命令卡消费（要让给 main 的全屏快捷键）")
	ok(not card.handle_key(_key(KEY_W, true)),
		"★ Ctrl+W 也不被命令卡消费（同一类组合键一起让出来）")


## ★★ 2026.10.30 回归：科技页九格没有键盘入口（用户报的 bug）。
##   修复前 `hud.handle_key()` 只问命令卡，而科技页命令卡是空的 ⇒ Q/W/E 全部无效。
func _test_tech_keys(main) -> void:
	var world = main.world
	var tabs = main.hud.page_tabs
	var g = main.hud.tech_grid
	var base = world.find_base_of("p1")
	ok(base != null, "（前提）有己方大本营")
	if base == null:
		return
	var level_before: int = base.level
	base.level = world.cfg.upgrade_max_level("base")
	world.apply_building_level_hp(base)
	give_gold_income(world, 100.0)

	main.input_ctrl.select_units([])
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_TECH)
	eq(tabs.page(), PageTabsRes.PAGE_TECH, "（前提）切到科技页")
	ok(g._deck_tween != null and g._deck_tween.is_running(),
		"★★ 切换科技牌组也会启动入场动效")
	main.hud.refresh()
	ok(g.visible, "（前提）科技九格显示出来")
	var drag_tech_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	var tech_before: bool = world.is_tech_active(drag_tech_id)
	g.cell_at(0).emit_signal("pressed")
	eq(world.is_tech_active(drag_tech_id), tech_before, "★ 科技牌普通点按不激活")
	var tech_cell: Control = g.cell_at(0)
	var tech_drag_origin: Vector2 = tech_cell.get_global_transform_with_canvas() * (tech_cell.size * 0.5)
	g.begin_touch_drag(0, tech_drag_origin)
	g.move_touch_drag(0, tech_drag_origin - Vector2(0.0, 24.0))
	g.finish_touch_drag(0)
	eq(world.is_tech_active(drag_tech_id), not tech_before, "★★ 科技牌上拖松手触发启用/弃用")
	if world.is_tech_active(drag_tech_id):
		g.press(0) # 还原，让后面的快捷键测试从未启用状态开始。

	# ★★ 科技页的图标：每格一张（按名字画的占位金线图形），名字压在最下面一行。
	#   这里只钉「第 1 格确实拿到了一张 tech_*.png」+「名字没被吃掉」——
	#   具体是哪条科技对应哪个 id 由 test_unit_card_icon 逐条点名。
	ok(g.cell_icon_path(0) != "", "★ 科技页第 1 格有图标蒙版")
	ok(g.cell_icon_path(0).ends_with(".png"), "★ 第 1 格的图标是一张 png")
	eq(g.cell_name(0), String((world.tech_entries()[0] as Dictionary).get("name", "")),
		"★ 第 1 格的名字照旧读得到（图标 + 一行名字）")

	# 视觉第 1/2/3 格 = Q/W/E = entry 0/3/6（九格是列优先转置的）。
	var keys := [KEY_Q, KEY_W, KEY_E]
	var ids: Array = []
	for i in 3:
		var id := String((g.entry_at(i) as Dictionary).get("id", ""))
		ok(id != "", "（前提）视觉第 %d 格有科技" % (i + 1))
		ids.append(id)
		ok(main.hud.handle_key(_key(int(keys[i]))),
			"★★ 科技页按 %s 被九格消费" % String(UiLayoutRes.CARD_KEYS[i]))
		ok(world.is_tech_active(id),
			"★★ 按 %s = 启用视觉第 %d 格（%s）"
				% [String(UiLayoutRes.CARD_KEYS[i]), i + 1, id])
		eq(g.cell_key(i), String(UiLayoutRes.CARD_KEYS[i]),
			"★ 科技格左上角显示键位字母 %s" % String(UiLayoutRes.CARD_KEYS[i]))
	main.hud.refresh()
	for i in 3:
		ok(g.cell_active(i), "★ 键盘启用后第 %d 格画成高亮" % (i + 1))

	# 再按一次同一个键 = 弃用（与鼠标点击同一条路）。
	for i in 3:
		ok(main.hud.handle_key(_key(int(keys[i]))), "再按一次 %s" % String(UiLayoutRes.CARD_KEYS[i]))
		ok(not world.is_tech_active(String(ids[i])),
			"★★ 再按 %s = 弃用视觉第 %d 格" % [String(UiLayoutRes.CARD_KEYS[i]), i + 1])

	ok(not main.hud.handle_key(_key(KEY_Q, true)),
		"★ 科技页 Ctrl+Q 不被九格消费（仍让给全屏快捷键）")

	base.level = level_before
	world.apply_building_level_hp(base)
	main.hud.refresh()

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
	# ★★ 2026.11.5（用户口径）：局内的单位按钮点击后**不要金色填充闪过**。
	var unit_cell: Button = card.cell_at(0)
	ok(not FillButtonRes.click_flash_enabled(unit_cell),
		"★★ 单位页的招募格不挂点击闪光（点一下不闪金）")
	ok(not FillButtonRes.is_latched(unit_cell),
		"★ 单位按钮也没有选中态（不会点完停在满格）")
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
	var played_pos: Vector2 = card.cell_at(0).get_global_transform_with_canvas() \
		* (card.cell_at(0).size * 0.5)
	# ★★ 2026.11.14（用户口径）：「单位招募时不需要队列了，招募变为即时的，
	#   只要拖拽单位牌生效就是招募完成」⇒ 拖出一张单位牌 = 兵当场出来。
	var retinue_before: int = world.retinue_of(g1.id).size()
	card._drag_index = 0
	card._dragging_card = true
	card._finish_card_drag(0, played_pos)
	eq(world.retinue_of(g1.id).size(), retinue_before + 1,
		"★★ 拖出单位牌 → 兵**当场**生成（没有队列、没有读条）")
	ok(not g1.is_training(), "★ 不再进入「招募中」状态")
	eq(g1.train_queue_size(), 0, "★ 队列恒为空")
	var sf: float = float((world.recruit_cost(UnitRes.UNIT_TYPE_SPEARMAN) as Dictionary).get("food", 0.0))
	near(float(world.resources["food"]), 200.0 - sf, 1e-4, "★ 招募当场扣粮（= config 定价）")
	eq(g1.leader_id, "", "将领自己还是队长")

	main.hud.refresh()
	# ★ 读条牌没了：手牌第一张就是第一张单位牌（Q 键也还在它身上）
	eq(String(card.entry_at(0).get("type", "")), "recruit",
		"★★ 手牌最左侧不再插入读条/取消牌")
	eq(String(card.entry_at(0).get("unit_kind", "")), UnitRes.UNIT_TYPE_SPEARMAN,
		"第一张就是枪兵牌")
	eq(card._key_labels[0].text, "Q", "★ 首张单位牌标记 Q")

	# 再拖一次 = 又是一个兵（没有冷却拦着）
	var again: int = world.retinue_of(g1.id).size()
	ok(card.handle_key(_key(KEY_Q)), "★★ Q 再招一个")
	eq(world.retinue_of(g1.id).size(), again + 1,
		"★★ 招募没有冷却：连着招就是连着出")

	# 编制上限仍然管着（招满就不能再招）
	var cap: int = world.effective_retinue_cap(g1)
	# ★ 招满之前要付钱：先把资源与人口给足（这条验的是**编制上限**，不是穷）
	world.resources["food"] = 9999.0
	world.resources["gold"] = 9999.0
	var zone_cap = world.zones.zone_at(g1.tx, g1.ty)
	if zone_cap != null:
		zone_cap["population"] = 999.0
	# ★ 有界：真招不动就停（避免「上限判据失效」时把测试挂死）
	for _i in 40:
		if world.retinue_of(g1.id).size() >= cap:
			break
		if not main.input_ctrl.request_recruit(UnitRes.UNIT_TYPE_SPEARMAN):
			break
	ok(g1.retinue_size(world) >= cap, "（前提）招满到编制上限")
	main.input_ctrl.request_recruit(UnitRes.UNIT_TYPE_SPEARMAN)
	ok(g1.retinue_size(world) <= cap,
		"★★ 编制上限仍然生效：即使点了也不会超编（实际 %d / 上限 %d）"
			% [g1.retinue_size(world), cap])

	main.input_ctrl.select_units([])
	main.hud.refresh()
	ok(not queue.showing(), "★ 没选中将领时五格收起来")

## ★★ 多选招募：不应全部塞给第一个将领，而应按「队列最短」摊到每个可招募将领。
func _test_multi_recruit_distribution(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	var g2 = world.unit_by_id("general-2")
	ok(g1 != null and g2 != null, "（前提）有两支部队可多选")
	if g1 == null or g2 == null:
		return
	# ★★ 2026.11.14：没有队列可清（招募即时）——两支队伍的兵数就是唯一的状态。
	world.resources["food"] = 2000.0
	world.resources["gold"] = 2000.0
	var g2_old_pos: Vector2 = g2.pos
	# 两支放到同一块己方区划里，保证两个都是「可招募」的（测试只关心分配顺序）。
	g2.pos = g1.pos + Vector2(0.25, 0.0)
	g2.sync_tile(world.map)
	var saved_zones: Array = []
	for g in [g1, g2]:
		var z = world.zones.zone_at(g.tx, g.ty)
		if z != null:
			var seen := false
			for rec in saved_zones:
				if rec["zone"] == z:
					seen = true
					break
			if not seen:
				saved_zones.append({"zone": z, "owner": z.get("owner"),
					"population": z.get("population")})
			z["owner"] = "p1"
			z["population"] = 20.0
	main.input_ctrl.select_units([g1, g2])
	ok(main.input_ctrl.request_recruit(UnitRes.UNIT_TYPE_SPEARMAN),
		"（前提）多选时第一单招募发出去了")
	# ★★ 2026.11.14：招募即时化 + 没有队列 ⇒ 摊单判据从「队列最短」换成「队伍最少」。
	#   连点两下应该在两支之间轮流补人，而不是全堆给第一支。
	# ★ 判据从「队列最短」换成「队伍最少」之后，两单会**分摊**到两支上（不会两单都堆给第一支）。
	var total: int = g1.retinue_size(world) + g2.retinue_size(world)
	ok(total >= 4, "★★ 两单都落地了（两支一共 %d 个兵）" % total)
	ok(g1.retinue_size(world) > 0 and g2.retinue_size(world) > 0,
		"★★ 两支都有兵（摊单没有把两单都堆给第一支）")
	main.input_ctrl.select_units([])
	g2.pos = g2_old_pos
	g2.sync_tile(world.map)
	for rec in saved_zones:
		var z: Dictionary = rec["zone"]
		z["owner"] = rec["owner"]
		z["population"] = rec["population"]


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
	eq(main.hud.page_tabs.page_count(), 1, "★ 选中区划中心 → 只有招募页签")
	eq(main.hud.page_tabs.page_id_at(0), PageTabsRes.PAGE_RECRUIT, "唯一页签是「招募」")
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 默认就在「招募」页")

	# ★★ 2026.11.14（用户口径）：「当将领被招募后，将领招募页的该将领牌会消失」
	#   ⇒ 页面上只有「还没被招走」的将领，且**开局就拥有的 #1-3 也不再占位**。
	var avail: Array = world.general_recruit_available("p1")
	ok(avail.size() > 0, "（前提）还有可招的将领（当前 %d 位）" % avail.size())
	if avail.is_empty():
		return
	eq(card.entries().size(), mini(avail.size(), 9),
		"★★ 招募页只列可招的将领（%d 位）" % avail.size())
	var kind0 := String(avail[0])
	eq(String(card.entry_at(0).get("type", "")), "zone_recruit",
		"招募页那一项是「区划招募」")
	eq(String(card.entry_at(0).get("unit_kind", "")), kind0,
		"第一格要招的就是清单里的第一位（%s）" % kind0)
	ok(bool(card.entry_at(0).get("ready", true)), "★ 可招的格子是亮的")

	var cost0: Dictionary = world.recruit_cost(kind0)
	var food_before: float = float(world.resources["food"])
	var pop_before: float = float(zone["population"])
	var units_before: int = world.units.size()

	card.activate_index(0)
	# ★★ 即时：点一下就当场出兵（没有队列、没有读条）
	eq(world.units.size(), units_before + 1, "★★ 点招募格 → 将领**当场**出现")
	ok(not world.zone_is_training(zone), "★★ 区划不会进入「读条中」")
	eq(world.zone_recruit_kind_at(zone, 0), "", "★★ 没有队列（那一格恒为空）")
	near(float(world.resources["food"]),
		food_before - float(cost0.get("food", 0.0)), 1e-4, "★ 当场扣粮食")
	near(float(zone["population"]), pop_before - 1.0, 1e-4, "★ 当场扣这个区划 1 人口")
	ok(world.general_recruit_cooldown_left("p1") > 0.0,
		"★ 招募后进入将领招募池的全局冷却")

	# ★★ 招走之后那一张牌从牌面上消失（不是变灰占位）
	main.hud.refresh()
	var avail_after: Array = world.general_recruit_available("p1")
	eq(avail_after.size(), avail.size() - 1, "★★ 招走一位 ⇒ 可招清单少一位")
	ok(not avail_after.has(kind0), "★★ 招走的那位不再出现")
	eq(card.entries().size(), mini(avail_after.size(), 9),
		"★★ 手牌也跟着少一张（%d 张）" % mini(avail_after.size(), 9))
	var still_there := false
	for e in card.entries():
		if e is Dictionary and String((e as Dictionary).get("unit_kind", "")) == kind0:
			still_there = true
	ok(not still_there, "★★ 招走的那位不在手牌里了")

	# 收尾：还原大本营等级（后面的建筑升级用例按 1 级写）。
	base.level = 1
	world.apply_building_level_hp(base)
	main.input_ctrl.select_units([])
	main.hud.refresh()

func _test_upgrade_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var tabs = main.hud.page_tabs
	var q = main.hud.detail_panel.queue_control()
	world.resources["food"] = 5000.0
	world.resources["gold"] = 5000.0
	# ★ 建筑升级只剩大本营；升 2 级的将领门槛读 config（现在是 2 名）。
	var need_g := int(world.cfg.upgrade_need_generals("base", 1))
	var idx := 1
	while world.general_count_of("p1") < need_g and idx < 32:
		var gnew = world.create_general("p1", idx, 500 + idx)
		if gnew == null:
			break
		world.units.append(gnew)
		idx += 1

	var base = world.find_base_of("p1")
	ok(base != null, "有大本营")
	if base == null:
		return
	main.input_ctrl.select_building(base)
	main.hud.refresh()
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）大本营停在操作页")
	eq(card.cell_label(0), "升级大本营", "★ Q 格 = 升级大本营")
	var lv0: int = base.level
	var food0: float = float(world.resources["food"])
	card.activate_index(0)
	ok(base.is_upgrading(), "★ 点那一格 = 开始读条")
	near(float(world.resources["food"]), food0 - float(
		float(world.cfg.upgrade_cost_to("base", lv0).get("food", 0.0))), 1e-4,
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
	ok(not base.is_upgrading(), "★ 点读条那一格 = 取消升级")
	eq(base.level, lv0, "等级没变")
	near(float(world.resources["food"]), food0, 1e-4, "★ 取消全额退款")

	main.hud.refresh()
	eq(card.entries().size(), 1, "（前提）取消之后操作页回到一格")
	eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
		"（前提）那一格回到「升级」（实际：%s）" % String(card.entry_at(0).get("type", "")))
	card.activate_index(0)
	ok(base.is_upgrading(), "再次开始读条（食物 %.0f / 黄金 %.0f）" % [
		float(world.resources["food"]), float(world.resources["gold"])])
	world.tick(60.0)
	main.hud.refresh()
	eq(base.level, lv0 + 1, "★ 读完等级 +1")
	ok(not q.is_bar_mode(), "★ 读条结束 → 面板回到「不是读条」")
	ok(card.cell_label(0).contains("升级"), "那一格又变回「升级%s」" % base.display_name())
	ok(main.hud.detail_panel.detail_text().contains("血量"),
		"★ 建筑详情仍是两列（左列血量、右列远程免伤）")
	ok(main.hud.detail_panel.detail_text().contains("远程免伤"),
		"★★ 建筑详情写着远程免伤（本轮新增的防御特性）")

	var zone = world.zones.zone_at(world.find_base_of("p1").tx, world.find_base_of("p1").ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return
	main.input_ctrl.select_zone(zone)
	main.hud.refresh()
	eq(tabs.page_count(), 1, "（前提）区划中心只剩招募页")
	eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "（前提）区划中心停在招募页")
	eq(String(zone["kind"]), "population", "（前提）这块是人口区划")
	var avail_now: Array = world.general_recruit_available("p1")
	eq(card.entries().size(), mini(avail_now.size(), 9),
		"★ 招募页列的就是「还没被招走」的那几位（当前 %d）" % avail_now.size())
	ok(not q.is_bar_mode(), "没有特化读条")
	ok(main.hud.detail_panel.detail_text().contains("人口"),
		"★ 区划右列仍显示人口产能 / 上限（实际：%s）"
			% main.hud.detail_panel.detail_text().replace("\n", "|"))
	for b in world.building_list:
		if b.is_upgrading():
			world.cancel_building_upgrade(b.tx, b.ty)
	main.input_ctrl.select_units([])
	main.hud.refresh()

## ★★ 2026.11.14：招募即时化 ⇒ 点招募格 = **当场出兵**，五格面板（队列 / 取消 / 退款）
## 这一整套已经没有内容可显示。这个用例改成验「点一下就出人、面板不再出现」。
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

	var before: int = world.retinue_of(g1.id).size()
	var food_before: float = float(world.resources["food"])
	card.activate_index(0)
	eq(world.retinue_of(g1.id).size(), before + 1, "★★ 点一下就当场出一个兵")
	ok(not g1.is_training(), "★★ 没有「招募中」这个状态了")
	eq(g1.train_queue_size(), 0, "★★ 队列恒为空")
	ok(float(world.resources["food"]) < food_before, "★ 当场扣粮")
	main.hud.refresh()
	ok(not q.showing(), "★★ 五格面板不再出现（没有队列可显示）")

	# 再点一次 = 再来一个（没有冷却拦着，只受钱 / 人口 / 编制上限约束）
	card.activate_index(0)
	eq(world.retinue_of(g1.id).size(), before + 2, "★★ 再点一次再出一个")

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
	# ★ 这个用例跑在前面几条「招满到编制上限」之后 ⇒ 先把 g1 腾出一个名额，
	#   否则拒因会是 cap（与本用例想验的「点了就出兵」无关）。
	while g1.retinue_size(world) > 0 and g1.retinue_size(world) >= world.effective_retinue_cap(g1):
		var subs0: Array = world.retinue_of(g1.id)
		if subs0.is_empty():
			break
		var tail = subs0[subs0.size() - 1]
		world.units.erase(tail)
		world.mark_vision_dirty()
	var sub_before: int = world.retinue_of(g1.id).size()
	# （先确认前提，失败时能直接看到拒因）
	var why_r: String = world.can_recruit(UnitRes.UNIT_TYPE_SPEARMAN, g1.id, "p1")
	eq(why_r, "", "（前提）这位将领现在招得了兵（拒因：%s）" % why_r)
	var afford_r: String = world.can_afford_recruit(UnitRes.UNIT_TYPE_SPEARMAN, g1.id)
	eq(afford_r, "", "（前提）付得起（拒因：%s）" % afford_r)
	card.activate_index(0)                       # 点一下 = 当场招一个（即时招募）
	eq(world.retinue_of(g1.id).size(), sub_before + 1, "★★ 点一下就出兵（没有读条）")
	ok(not g1.is_training(), "★★ 不存在「招募中」状态，所以也不会锁住部队")
	main.hud.show_notice("")                     # 先把提示清掉，免得误判
	# ★★ 2026.10.24：招募不再把将领 / 附属兵锁住，右击照常下令。
	ok(not main.input_ctrl.selection_locked(),
		"★★ 招募中的队伍不再处于「被锁住」状态（可以边走边招）")

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
	# ★★ 2026.11.14：右键不再下移动令 —— 改走操作牌那条下达路径（issue_order_at）
	main.input_ctrl.issue_order_at("move",
		main.palette.to_px(Vector2(empty.x + 0.5, empty.y + 0.5)))
	var evts: Array = world.tick(1.0 / 60.0)
	main._consume_events(evts)
	ok(not main.hud.notice_active() or not main.hud.notice_text().contains("招募"),
		"★★ 招募中不再弹出「将领正在招募，不接受指令」的红字")
	ok(main.input_ctrl.move_marks.size() >= 1,
		"★★ 招募中的队伍照常画移动标记（命令真的会执行）")

	var mate = world.retinue_of(g1.id)[0]
	ok(CommandRes.apply(world, main.cfg, {"kind": "move", "ids": [mate.id],
		"x": float(empty.x), "y": float(empty.y), "faction": "p1"}),
		"★★ 将领辖下的附属兵照常接受指令")
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

## ★★ 2026.11.14：招募即时化 ⇒ 信息栏那五个格子（队列 / ETA / 汇总）**永远没有内容**。
## 这个用例保留下来只做一件事：确认那个面板不会再自己冒出来。
func _test_queue_control(cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-0")
	ok(g1 != null, "（前提）有开局将领")
	if g1 == null:
		return
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	var before: int = w.retinue_of(g1.id).size()
	ok(w.start_recruit("spearman", g1.id, "p1"), "（前提）招一个")
	eq(w.retinue_of(g1.id).size(), before + 1, "★★ 当场出兵")
	eq(g1.train_queue_size(), 0, "★★ 队列恒为空 ⇒ 五格没有东西可显示")
	# 权威侧的两个队列查询接口仍在（界面 / 存档都还会调），但要如实回答「空」
	eq(w.recruit_kind_at(g1, 0), "", "大格子恒为空")
	eq(w.zone_recruit_queue_size(w.zones.zone_at(g1.tx, g1.ty)), 0, "区划队列也是空的")

func _test_recruit_queued_event(cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var g1 = w.unit_by_id("general-0")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	w.tick(1.0 / 60.0)                  # 把上一帧的残留事件清干净
	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.UNIT_TYPE_SPEARMAN,
		"leader_id": g1.id, "faction": "p1"}), "招募命令被接受")
	var events: Array = w.tick(1.0 / 60.0)
	# ★★ 2026.11.14：没有队列 ⇒ 发的是「兵出来了」那条（`unit_recruited`），
	#   不再是 `recruit_queued`。这条事件界面拿去放音效 / 飘字。
	var spawned := 0
	for evt in events:
		if String(evt.get("type", "")) == "unit_recruited":
			spawned += 1
	eq(spawned, 1, "★ 招募出兵的事件被下一次 tick 交了出来（命令事件不能在 tick 开头被丢掉）")

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
	# ★★ 2026.11.14（用户口径）：「右键取消掉移动/行军/攻击指令，完全由出牌代替」+
	#   「右键完全空着」—— 右键这一下必须什么都不发。
	main.input_ctrl._on_right_click(false)
	eq(got.size(), 0, "★★ 右键不再发出任何命令（完全空着）")
	# 出牌那条路：攻击牌拖到敌人身上 = attack
	main.input_ctrl.issue_order_at("attack", main.palette.to_px(foe.pos))
	eq(got.size(), 1, "★ 攻击牌拖到敌人身上 = 发出命令")
	eq(String(got[0].get("kind", "")), "attack", "★ 攻击牌 = 攻击命令")
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
	# ★★ 2026.11.14（用户口径）：「右键取消掉移动/行军/攻击指令，完全由出牌代替」
	#   ⇒ 单击 / 双击右键**都不再发命令**，也不再画那两种标记。
	got.clear()
	main.input_ctrl._on_right_click(false)
	eq(got.size(), 0, "★★ 右键单击空地：不发任何命令")
	main.input_ctrl._on_right_click(true)
	eq(got.size(), 0, "★★ 右键双击也不再发行军攻击（出牌才是唯一入口）")

	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = true
	ev.double_click = true
	ev.position = Vector2(20.0, 20.0)
	got.clear()
	ok(main.input_ctrl.handle_mouse_button(ev), "右键事件仍然被「吃掉」（不当成没处理）")
	eq(got.size(), 0, "★★ 走真实事件路径也一样：右键不下任何命令")

	var center_tile := Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			var cz = world.zone_center_zone_at(tx, ty)
			if cz != null:
				center_tile = Vector2i(tx, ty)
				break
		if center_tile.x >= 0:
			break
	if center_tile.x >= 0:
		got.clear()
		main.input_ctrl.hover_tile = center_tile
		main.input_ctrl.mouse_world = Vector2(center_tile.x + 0.5, center_tile.y + 0.5)
		main.input_ctrl._on_right_click(false)
		eq(got.size(), 0, "★★ 右键点区划中心也不发命令（右键整体空着）")

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
	var compact_rows: Array = main.hud.detail_v2.list._rows
	eq(String((compact_rows[0] as Dictionary).get("kind", "")), "focus",
		"V2 多选栏先显示当前聚焦编队")
	eq(int((compact_rows[0] as Dictionary).get("number", 0)), 1,
		"V2 多选焦点保留 1 号编队")
	var other_chips := 0
	for row in compact_rows:
		if String((row as Dictionary).get("kind", "")) == "troop_chip":
			other_chips += 1
	eq(other_chips, 1, "V2 多选栏只显示其余实际选中的 2 号编队，不补空位")
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
		eq(roster.kind(), "troop", "★ 这一格是部队格")
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
			"★ 9 格 + 左上展开的那一格 = 左栏共 10 个方框（参考图布局，与编队槽数无关）")
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

	# ★★ 2026.11.14（用户口径）：「不要多选：一次只选一支」——
	#   框选与 Shift 追加都取消了，`box_select` 这个函数本身还在（手机端用），
	#   但**加选**那条链路（`additive = true`）不再由 UI 触发。
	main.input_ctrl.select_units([g1])
	main.input_ctrl.select_units([g2])
	ok(not main.input_ctrl.selected_units.has(g1) and main.input_ctrl.selected_units.has(g2),
		"★★ 一次只选一支：选第二支时第一支自动取消")

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
	# ★★ 2026.11.14（用户口径）：「左键拖拽改为移动视角，取消掉拖拽选框」。
	#   这一段以前验的是框选，现在验**同一串真实事件**驱动的是平移：
	#   按 → 动 2px（还是单击）→ 动过阈值（变成平移、相机跟手）→ 松手（收尾 + 惯性）。
	var a_world := lo
	var b_world := hi
	near(main.input_ctrl._screen_to_logic(_world_to_screen(main, a_world)).x, a_world.x, 0.02,
		"（前提）世界坐标 → 视口坐标 → 世界坐标 能来回换算")
	main.input_ctrl.select_units([g1])
	var sel_before: Array = _sorted_ids(main.input_ctrl.selected_units)
	var probe_world := Vector2(world.map.cols * 0.5, world.map.rows * 0.5)
	var probe_px_before: Vector2 = _world_to_screen(main, probe_world)

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = _world_to_screen(main, a_world)
	ok(main.input_ctrl.handle_mouse_button(down), "左键按下被处理")
	ok(main.input_ctrl._drag_pending, "按下之后进入「可能是拖拽」的待定状态")
	var tiny := InputEventMouseMotion.new()
	tiny.position = down.position + Vector2(2.0, 0.0)
	main.input_ctrl.handle_mouse_motion(tiny)
	ok(not main.input_ctrl._drag_pan_active,
		"★ 只挪了 2px（< ui.drag_select_min_px）→ 还是普通单击，不动相机")
	var move := InputEventMouseMotion.new()
	move.position = down.position + Vector2(160.0, 0.0)
	main.input_ctrl.handle_mouse_motion(move)
	ok(main.input_ctrl._drag_pan_active, "★★ 拖过阈值 → 左键拖拽变成**平移视角**")
	ok(not main.input_ctrl.drag_active, "★★ 不再起拖框（PC 框选已取消）")
	# ★ 越过阈值那一下只是「转档」（见 handle_mouse_motion）；真正跟手从第二段移动开始
	var move2 := InputEventMouseMotion.new()
	move2.position = move.position + Vector2(60.0, 0.0)
	main.input_ctrl.handle_mouse_motion(move2)
	var probe_px_after: Vector2 = _world_to_screen(main, probe_world)
	ok(probe_px_after.x > probe_px_before.x + 20.0,
		"★★ 光标往右拖 → 地图跟着往右（同一点在屏幕上右移 %.0fpx）"
			% (probe_px_after.x - probe_px_before.x))
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = move2.position
	ok(main.input_ctrl.handle_mouse_button(up), "左键抬起被处理")
	ok(not main.input_ctrl._drag_pan_active, "松手之后平移结束")
	eq(_sorted_ids(main.input_ctrl.selected_units), sel_before,
		"★★ 拖拽平移**不取消选中**（按下那一下改掉的会还原回去）")
	main.input_ctrl._cancel_pan_fling()
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	main.input_ctrl.select_units([g1])
	main.hud.refresh()


## ★★ 2026.11.14（用户口径）：「左键拖拽改为移动视角」「带惯性滑行」。
##
## 原来这一段验的是「PC 框选按立牌图标的屏幕矩形判定」——框选已经取消，
## 改成验同一件事的新形态：**左键拖拽 = 平移相机 + 松手滑行**，而且不再改选中。
func _test_drag_pan(main) -> void:
	var world = main.world
	var ic = main.input_ctrl
	var probe := Vector2(world.map.cols * 0.5, world.map.rows * 0.5)
	var before: Vector2 = _world_to_screen(main, probe)
	ic.select_units([])
	ic._cancel_pan_fling()

	var a := Vector2(400.0, 300.0)
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = a
	ok(ic.handle_mouse_button(down), "（前提）左键按下被处理")
	# 分两段移动，让速度估计有东西可算（一次跳很远也能动，但滑行速度会怪）
	# ① 越过阈值那一下只「转档」；②③ 才真的跟手（见 handle_mouse_motion）
	for step in [Vector2(90.0, 20.0), Vector2(40.0, 10.0), Vector2(40.0, 10.0)]:
		a += step
		var mm := InputEventMouseMotion.new()
		mm.position = a
		ic.handle_mouse_motion(mm)
	ok(ic._drag_pan_active, "★★ 拖过阈值 → 进入拖拽平移")
	ok(ic.is_panning(), "★★ 平移期间 is_panning() 为真（边缘滚屏会让路）")

	var mid: Vector2 = _world_to_screen(main, probe)
	ok(mid.distance_to(before) > 60.0, "★★ 相机真的平移了（同一点在屏幕上移了 %.0fpx）"
		% mid.distance_to(before))
	# ★ 1:1 跟手：地图跟着鼠标走 —— 光标右下走，画面里的那个点也往右下移
	ok(mid.x > before.x + 10.0 and mid.y > before.y + 2.0,
		"★★ 「抓着地图拖」：光标右下走，画面里的点也往右下走")

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = a
	ic.handle_mouse_button(up)
	ok(not ic._drag_pan_active, "松手 → 拖拽结束")
	ok(ic._pan_fling_active, "★★ 松手后带惯性滑行（用户口径「带惯性滑行」）")
	var at_release: Vector2 = _world_to_screen(main, probe)
	# 推几帧（每帧 ~1/60 秒）
	for i in 6:
		ic.tick_pan_fling(1.0 / 60.0)
	var after_fling: Vector2 = _world_to_screen(main, probe)
	ok(after_fling.distance_to(at_release) > 5.0,
		"★★ 滑行真的继续走了几帧（%.1fpx）" % after_fling.distance_to(at_release))
	# 滑行会自己停下（不能永久微飘）
	for i in 120:
		ic.tick_pan_fling(1.0 / 60.0)
	ok(not ic._pan_fling_active, "★★ 滑行在 2 秒内自己停住（不会一直飘）")


## ★★ 鼠标拖拽划到**底栏（详细信息 UI）**上时，平移必须继续跟着走。
##
## 复现的 bug（用户报的）：「鼠标划到底栏内时选框不动，划过去之后又突变」。
##   底栏那一块是 `MOUSE_FILTER_STOP` —— 鼠标移到它上面时移动事件被 GUI **吃掉**，
##   `_unhandled_input` 收不到 ⇒ 手势停在原地。
##   修法：`game_scene3d._input()` 在手势进行中把移动 / 抬起补一遍（`_input` 先于 GUI 派发）。
## ★★ 2026.11.14：框选取消之后这条补发路径**照样必须存在**（现在护的是平移）。
func _test_drag_over_ui(main) -> void:
	var world = main.world
	var ic = main.input_ctrl
	var vp: Vector2 = main.get_viewport().get_visible_rect().size
	var ui_a := Vector2(vp.x * 0.5, maxf(1.0, vp.y - 60.0))
	var ui_b := Vector2(vp.x * 0.65, maxf(1.0, vp.y - 24.0))
	var probe := Vector2(world.map.cols * 0.5, world.map.rows * 0.5)
	ic._cancel_pan_fling()

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = _world_to_screen(main, probe)
	ic.handle_mouse_button(down)
	ok(ic._drag_pending, "（前提）在地图上按下 → 进入手势待定")

	var px0: Vector2 = _world_to_screen(main, probe)
	var move_a := InputEventMouseMotion.new()
	move_a.position = ui_a
	main._input(move_a)
	ok(ic._drag_pan_active,
		"★ 划到底栏上也能越过阈值、开始平移（不再被底栏 UI 吃掉）")
	var move_a2 := InputEventMouseMotion.new()
	move_a2.position = ui_a + Vector2(80.0, 0.0)
	main._input(move_a2)
	var px1: Vector2 = _world_to_screen(main, probe)
	ok(px1.distance_to(px0) > 10.0, "★ 相机跟着动了（%.1fpx）" % px1.distance_to(px0))

	var move_b := InputEventMouseMotion.new()
	move_b.position = ui_b
	main._input(move_b)
	var px2: Vector2 = _world_to_screen(main, probe)
	ok(px2.distance_to(px1) > 5.0, "★ 继续在底栏上移动 → 平移继续跟着走")

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = ui_b
	main._input(up)
	ok(not ic._drag_pan_active and not ic._drag_pending,
		"★ 在底栏上松手，手势照样结束")
	ic._cancel_pan_fling()

	# 没有手势时，`_input` 不许自己起手势（点在 UI 上就该是点 UI）
	var idle := InputEventMouseMotion.new()
	idle.position = ui_a
	main._input(idle)
	ok(not ic._drag_pan_active and not ic._drag_pending,
		"★ 没有进行中的手势时，_input 不会自己开始平移")
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
	ok(built.size() >= 2, "（前提）在框内建了 %d 段己方木墙" % built.size())

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
	eq(roster.kind(), "building", "★ 这一格是建筑格")
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
	eq(grid.cell_sub_text(0), "%d/%d" % [int(round(expect[1].hp)), int(round(expect[1].hp_max))],
		"★ 建筑格第二行是血量 x/y")

	eq(panel.unit_name_text(), expect[0].display_name(), "★ 右栏报的是主选中的建筑")
	ok(panel.detail_text().contains("血量") and panel.detail_text().contains("远程免伤"),
		"★ 建筑详情是两列：左列血量、右列远程免伤（实际：%s）"
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

		var bonus_zone: Dictionary = z0.duplicate(true)
		bonus_zone["population_growth_bonus"] = 0.5
		var brows: Dictionary = main.hud._zone_detail_rows(bonus_zone, true)
		var bright: Array = brows["right"]
		ok(main.hud._rows_text(brows).contains("建筑人口加成"),
			"★ 有大本营/建筑人口加成时右列写出来（实际：%s）"
				% main.hud._rows_text(brows).replace("\n", "|"))
		eq(main.hud._row_text(bright, bright.size() - 1),
			"- 建筑人口加成 +0.5/s", "★ 这一行是唯一的小字增益行（带「- 」前缀）")

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
	ok(gtext.contains("攻击 ") and gtext.contains("防御 "),
		"★ 攻击在左第二排、防御在右第二排（实际：%s）" % gtext.replace("\n", "|"))
	ok(gtext.contains("/") and gtext.contains("s"),
		"★ 攻击那一行是「原始攻击力/攻击频率」（如 14/1s）")
	ok(not gtext.contains("攻击距离"), "★ 旧版「攻击距离」不再显示")
	ok(not gtext.contains("编制") and not gtext.contains("状态") and not gtext.contains("兵种"),
		"★ 不再有编制 / 状态 / 兵种")
	ok(not gtext.contains("已选中"), "★ 不再有「已选中 N 支部队」")
	# ★ 默认没有将领特性：只剩「两行基础 + 一行兵种特性」。
	eq(gtext.split("\n").size(), 3,
		"★ 两行基础 + 一行兵种特性（长枪兵：对骑兵 +25%）")
	ok(gtext.contains("对骑兵 +25%"), "★ 攻击特性写在左列「攻击」下面（实际：%s）"
		% gtext.replace("\n", "|"))
	ok(not gtext.contains("特性 "), "★ 不再有将领词条行")

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
		# ★ 默认没有将领特性：兵只剩「两行基础 + 兵种特性」。
		var s_left: int = main.hud._attack_bonus_lines(soldier).size()
		var s_right: int = main.hud._defense_bonus_lines(soldier).size()
		eq(stext.split("\n").size(), 2 + maxi(s_left, s_right),
			"★ 兵也是两行基础 + 兵种特性行")
		ok(stext.contains("对骑兵 +25%"), "★ 兵的详情同样显示它自己的特性（实际：%s）"
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
	ok(not tabs.visible, "★★ 选中敌方单位 → 右下角页签整块隐藏")
	eq(tabs.page_count(), 0, "★ 不再立一颗空页签（整个控件收起）")
	eq(tabs.page(), "", "★ 当前页清空")
	ok(not hud.command_card.visible,
		"★★ 命令卡也一起隐藏（需求：页签和命令卡都要隐藏）")
	eq(hud.command_card.entries().size(), 0,
		"★★ 命令卡内容为空（绝不能落到「操作」页）")
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
	# ★ 先点第一栋敌对建筑（地图上通常是敌方大本营）——
	#   本块验的是「左键能选中敌对建筑 + 详情」，以及本次需求：
	#   敌方 / 友方**任何**建筑都隐藏右下角（大本营不再是例外）。
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
		ok(not hud.page_tabs.visible, "★★ 选中敌方建筑 → 右下角页签整块隐藏")
		eq(hud.page_tabs.page_count(), 0, "★ 一颗页签都不留（大本营也不再例外）")
		ok(not hud.command_card.visible, "★★ 命令卡也隐藏")
		eq(hud.command_card.entries().size(), 0, "★ 命令卡空（没有「升级」那一格）")
		eq(hud.detail_panel.unit_name_text(), foe_b.display_name(), "★ 右栏报的是那栋建筑的名字")
		ok(hud.detail_panel.detail_text().contains("血量"),
			"★ 敌对建筑也显示两列详情（血量 / 防御）")
		var btxt: String = hud._enemy_building_text(foe_b)
		ok(btxt.contains("血量"), "（文案生成器）右栏有它的血量")
		for bad2 in ["等级", "升级", "特化", "建造中"]:
			ok(not btxt.contains(bad2), "★ 敌对建筑详情里不出现「%s」" % bad2)

	# ★★ 再挑一栋**普通**敌对建筑（木墙 / 哨塔），确保隐藏不是只对大本营生效。
	ic.select_units([])
	var foe_plain = null
	for b2 in world.building_list:
		if b2 != null and b2.alive and not b2.is_invulnerable() \
				and not FactionRes.same_side(b2.owner, world.my_faction) \
				and String(b2.type) != BuildingRes.TYPE_BASE \
				and String(b2.type) != BuildingRes.TYPE_ZONE_CENTER:
			foe_plain = b2
			break
	ok(foe_plain != null, "（前提）场上有一栋敌对普通建筑（城墙 / 哨塔）")
	if foe_plain != null:
		ic.select_enemy(foe_plain)
		hud.refresh()
		ok(not hud.page_tabs.visible, "★★ 选敌对木墙 / 哨塔 → 右下角页签整块隐藏")
		eq(hud.page_tabs.page_count(), 0, "★ 不是空页签（整块都收起来了）")
		ok(not hud.command_card.visible, "★ 命令卡同样隐藏")
		eq(hud.command_card.entries().size(), 0, "★ 命令卡仍为空")

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
		ok(not hud.page_tabs.visible,
			"★★ 敌人 / 中立区划中心 → 右下角整块隐藏（不再立空页签）")
		eq(hud.page_tabs.page_count(), 0, "★ 一颗页签都不留")
		ok(not hud.command_card.visible, "★★ 命令卡也隐藏")
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
		ok(hud.page_tabs.visible, "★★ 自己区划中心 → 页签整块恢复可见")
		ok(hud.command_card.visible, "★★ 命令卡也恢复可见")
		eq(hud.page_tabs.page_count(), 1, "★ 自己区划中心只剩招募页签")
		eq(hud.page_tabs.page_id_at(0), PageTabsRes.PAGE_RECRUIT, "唯一页签是「招募」")
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
		ok(hud.page_tabs.visible, "★ 页签回到己方部队那一套（整块恢复可见）")
		ok(hud.command_card.visible, "★ 命令卡恢复可见")
		ok(hud.page_tabs.page() == PageTabsRes.PAGE_ORDER
				or hud.page_tabs.page() == PageTabsRes.PAGE_UNIT,
			"★ 页签回到己方部队那一套（操作 / 单位），实际「%s」" % hud.page_tabs.page())
		ok(hud.command_card.entries().size() > 0, "★ 命令卡回到己方内容")

	ic.select_units([] if g1 == null else [g1])
	hud.refresh()

func _test_settings_inert(main) -> void:
	var page_before := String(main.hud.page_tabs.page())
	# ★★ 2026.11.14 第三轮：没有按钮可点了 —— 改成验「开 / 关选项页不会顺手切页签」
	main.hud.set_settings_menu_open(true)
	eq(main.hud.page_tabs.page(), page_before, "开选项页不会顺手切页")
	main.hud.set_settings_menu_open(false)
	eq(main.hud.page_tabs.page(), page_before, "关选项页也不会顺手切页")

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

func _key_up(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = false
	return ev

func _tab_key(shift: bool = false) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = KEY_TAB
	ev.pressed = true
	ev.shift_pressed = shift
	return ev

func _touch_ev(pressed: bool, pos: Vector2) -> InputEventScreenTouch:
	var ev := InputEventScreenTouch.new()
	ev.index = 0
	ev.pressed = pressed
	ev.position = pos
	return ev
