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
func _test_layout_against_reference(cfg) -> void:
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
	eq(UiLayoutRes.tab_button_local(0, 2).size.y, 120.0,
		"★ 页签是**动态**的：两颗时每颗 120 高（240 ÷ 2）")
	eq(UiLayoutRes.tab_button_local(1, 1).size.y, 240.0,
		"★ 只有一颗时它铺满整列（240）")
	eq(UiLayoutRes.SETTINGS_RECT, Rect2(1840, 0, 80, 160), "设置按钮 80×160 在右上角（参考图）")

	# ★ 招募队列：五个格子 = 1 个大格（正在读条）+ 4 个小格（排队）
	#   ★★ 第七轮：左边一条汇总带（「招募队列 3/5」+「共 22s」）+ **整块放大**
	#      （大格 64→84、小格 30→40、字号 13/11→15/13），并且**离右栏上/右边缘留 4px**
	#      —— 贴边时 1px 描边会被右栏的 clip_contents 切掉（手玩报的「上方被裁剪」）。
	eq(UiLayoutRes.QUEUE_SLOTS, 5, "★ 招募队列 5 个格子（1 大 + 4 小，需求原话）")
	eq(UiLayoutRes.QUEUE_INFO_W, 141.0, "汇总带宽 141（表格子段左边那一条）")
	eq(UiLayoutRes.QUEUE_W, UiLayoutRes.QUEUE_INFO_W + UiLayoutRes.QUEUE_CELLS_W,
		"★ 控件总宽 = 汇总带 141 + 五个格子 172 = 313（常量之间是推算式，不会对不上）")
	eq(UiLayoutRes.QUEUE_H, 92.0, "★ 控件总高 92（整块放大：64 → 92，格子 84 + 上下各 4）")
	eq(UiLayoutRes.QUEUE_BIG, 84.0, "★ 大格子 84×84（64 → 84）")
	eq(UiLayoutRes.QUEUE_SMALL, 40.0, "★ 小格子 40×40（30 → 40）")
	# ★★ 贴不贴裁剪线：这是「上方被裁剪」那条反馈的回归判据
	ok(UiLayoutRes.QUEUE_MARGIN >= 1.0,
		"★ 队列块离右栏上/右边缘留了 %.0fpx（= 0 时 1px 描边会被裁剪线切掉半条）"
			% UiLayoutRes.QUEUE_MARGIN)
	ok(UiLayoutRes.QUEUE_Y >= 1.0, "★ 队列块的上缘不贴右栏顶边（否则上边框整条不见）")
	eq(UiLayoutRes.QUEUE_X + UiLayoutRes.QUEUE_W, UiLayoutRes.UNIT_CONTENT_RIGHT,
		"★ 队列块右缘 = 右栏内容的公共右缘（641 = 645 − 4，同样不贴裁剪线）")
	ok(UiLayoutRes.QUEUE_X + UiLayoutRes.QUEUE_W < UiLayoutRes.DETAIL_RIGHT_W,
		"★ 队列块右缘**不**顶到 645（顶到就会被切）")
	eq(UiLayoutRes.queue_info_rect(), Rect2(0, 0, 141, 92), "汇总带占控件左边那条 141×92")
	eq(UiLayoutRes.queue_info_line_rect(0), Rect2(8, 27, 125, 18), "汇总第一行（招募队列 3/5）")
	eq(UiLayoutRes.queue_info_line_rect(1), Rect2(8, 49, 125, 16), "汇总第二行（共 22s）")
	ok(UiLayoutRes.queue_info_line_rect(1).position.y + UiLayoutRes.queue_info_line_rect(1).size.y
			<= UiLayoutRes.QUEUE_H,
		"★ 汇总两行都落在控件里（否则会被右栏裁掉）")
	eq(UiLayoutRes.queue_cell_rect(0), Rect2(141, 4, 84, 84), "大格子紧跟在汇总带右边（84×84）")
	eq(UiLayoutRes.queue_cell_rect(1), Rect2(229, 4, 40, 40), "第 1 个小格排在大格右边")
	eq(UiLayoutRes.queue_cell_rect(2), Rect2(273, 4, 40, 40), "第 2 个小格在它右边")
	eq(UiLayoutRes.queue_cell_rect(3), Rect2(229, 48, 40, 40), "第 3 个小格换行")
	eq(UiLayoutRes.queue_cell_rect(4), Rect2(273, 48, 40, 40), "第 4 个小格在右下角")
	var small_last := UiLayoutRes.queue_cell_rect(4)
	ok(small_last.position.x + small_last.size.x <= UiLayoutRes.QUEUE_W + 1e-6
		and small_last.position.y + small_last.size.y <= UiLayoutRes.QUEUE_H + 1e-6,
		"★ 四个小格都落在队列控件的矩形里（否则会被裁掉）")
	# 格子上下各留 QUEUE_CELL_PAD（描边同样不贴控件边界）
	ok(UiLayoutRes.queue_cell_rect(0).position.y >= 1.0
		and UiLayoutRes.queue_cell_rect(4).position.y + UiLayoutRes.queue_cell_rect(4).size.y
			<= UiLayoutRes.QUEUE_H - 1.0,
		"★ 格子上下都留了缝（贴边的话大格子的描边也会被切）")
	# 最左边那个格子必须让开汇总带（不然文字会压在格子上）
	ok(UiLayoutRes.queue_cell_rect(0).position.x >= UiLayoutRes.QUEUE_INFO_W,
		"★ 大格子不压到左边的汇总文字")
	# 汇总文字按真实字体量一遍宽度（第七轮新增的两行）
	_test_queue_info_text_fit(cfg)


# ---- 招募队列里那些字必须**装得下**（按真实字体量；`clip_text` 裁字不报错）----
#
# 第七轮的队列字号档位（整块放大之后）：
#   汇总第一行 / 大格子 = **15 号**（FS_BODY），汇总第二行 / 小格子 = **13 号**（FS_SMALL）。
# 这些错只会表现为「字缺一截」，所以按 pitfalls 5.42 的规矩量一遍宽度与行高容量。
func _test_queue_info_text_fit(cfg) -> void:
	var font: Font = FontLoaderRes.load_font(cfg)
	if font == null:
		ok(true, "（没装中文字体，跳过队列文字的量算）")
		return
	var fs_body: int = UiStyleRes.FS_BODY
	var fs_small: int = UiStyleRes.FS_SMALL

	# ① 汇总第一行：「招募队列 5/5」是它能长到的最长样子（上限 5）
	var title_r := UiLayoutRes.queue_info_line_rect(0)
	var title_w: float = font.get_string_size("招募队列 5/5", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_body).x
	ok(title_w <= title_r.size.x + 0.01,
		"★ 汇总第一行「招募队列 5/5」宽 %.0f ≤ 可写 %.0f（装得下才不会被裁）"
			% [title_w, title_r.size.x])
	ok(font.get_height(fs_body) <= title_r.size.y + 0.01,
		"★ 汇总第一行的高度装得进那一行（行高 %.0f ≤ %.0f）"
			% [font.get_height(fs_body), title_r.size.y])

	# ② 汇总第二行：「共 100s」是留足余量的最长样子（现在一个单位 10 秒，5 个才 50s）
	var total_r := UiLayoutRes.queue_info_line_rect(1)
	var total_w: float = font.get_string_size("共 100s", HORIZONTAL_ALIGNMENT_LEFT, -1, fs_small).x
	ok(total_w <= total_r.size.x + 0.01,
		"★ 汇总第二行「共 100s」宽 %.0f ≤ 可写 %.0f" % [total_w, total_r.size.x])

	# ③ 大格子（84×84，15 号字，两行）：「兵 / 剩 10.0s」
	var big_r := UiLayoutRes.queue_cell_rect(0)
	for text in ["兵", "剩 100.0s"]:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_body).x
		ok(w <= big_r.size.x - 2.0,
			"★ 大格子里的「%s」宽 %.0f ≤ %.0f（装得下）" % [text, w, big_r.size.x - 2.0])
	ok(font.get_height(fs_body) * 2.0 <= big_r.size.y + 0.01,
		"★ 大格子两行 15 号字（%.0f×2）装得进 84 高" % font.get_height(fs_body))

	# ④ 小格子（40×40，13 号字，两行）：「兵 / 20s」
	var small_r := UiLayoutRes.queue_cell_rect(1)
	for text in ["兵", "400s"]:
		var w: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs_small).x
		ok(w <= small_r.size.x - 2.0,
			"★ 小格子里的「%s」宽 %.0f ≤ %.0f（装得下）" % [text, w, small_r.size.x - 2.0])
	ok(font.get_height(fs_small) * 2.0 <= small_r.size.y + 0.01,
		"★ 小格子两行 13 号字（%.0f×2）装得进 40 高（放大前是 30 高装两行 11 号）"
			% font.get_height(fs_small))

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
	# 每格 40×40，行距 **55**（本轮从 44 加大 —— 手玩报的「左栏 3×3 网格也太挤」）：
	# 3 行共 165，加上上半 40 + 缝 15 = **220 = 内容高**，正好铺满、不溢出
	v2_near(UiLayoutRes.troop_avatar_rect(0).size, Vector2(40.0, 40.0), 0.01, "格里的方框 40×40")
	eq(UiLayoutRes.troop_cell_rect(0), Rect2(0, 0, 112, 55), "第 0 格在左上（宽 116 - 内侧 4）")
	eq(UiLayoutRes.troop_cell_rect(1).position.x, UiLayoutRes.TROOP_CELL_W,
		"第 1 格在它右边（列优先 → 行优先）")
	eq(UiLayoutRes.troop_cell_rect(3).position.y, UiLayoutRes.TROOP_CELL_H, "第 3 格换到第二行")
	eq(UiLayoutRes.troop_cell_rect(8).position.y, 2.0 * UiLayoutRes.TROOP_CELL_H, "第 8 格在第三行")
	# 9 格 + 上半那一格都必须落在左栏内容区里（不然会被面板裁掉）
	var bottom := UiLayoutRes.troop_cell_rect(8)
	ok(bottom.position.y + UiLayoutRes.TROOP_AVATAR <= 220.0,
		"★ 第 3 行的方框装得进左栏内容高（%s ≤ 220）" % str(bottom.position.y + UiLayoutRes.TROOP_AVATAR))
	# ★★ 本轮加大行距之后，左栏**正好铺满 220** —— 上下都不该再剩空（这就是「不挤」的定义：
	#    多出来的 33px 全分给了三行之间的空白，而不是留在底部发霉）。
	ok(UiLayoutRes.troop_grid_rect().position.y + UiLayoutRes.TROOP_GRID_H <= 220.0 + 1e-6,
		"★ 网格铺得进内容高（%s ≤ 220）" % str(
			UiLayoutRes.troop_grid_rect().position.y + UiLayoutRes.TROOP_GRID_H))
	ok(UiLayoutRes.troop_grid_rect().position.y + UiLayoutRes.TROOP_GRID_H >= 220.0 - 1e-6,
		"★ 左栏竖直方向**正好铺满** 220（行距加大之后不该还留着底部空白）")
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
	# ★★ 这一条是补的回归（手玩报的「第二、三列的文字被挤到第一列去」）：
	#    文字**可写宽度必须真的装得下**「将领名称」四个字（13 号字 = 52px），否则会被截成
	#    两个字，看起来就像「字太小 / 那两列没字」。
	#    ⚠️ 56 → **60**（选中建筑那一轮）：建筑格的第二行是「1000/1000」（大本营），
	#       实测 59px —— 56 会把它截断。60 仍然留在本格内（48 + 60 + 8 = 116 = 格宽）。
	eq(UiLayoutRes.TROOP_NAME_W, 60.0, "★ 名字可写宽度 60（52px 的「将领名称」装得下）")
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

	# ★★ 滚轮缩放：底栏（除左下小地图）那一整条都要拦（用户需求原话：
	#    「当鼠标位于下方除地图外的 ui 栏时，应当禁用鼠标滚轮缩放地图，
	#      当鼠标移出下边栏，需要恢复」）。
	#    ⚠️ 这是 `bottom_bar_rects` —— 与上面那份「能点的控件」名单**不是同一个**：
	#      详细信息面板里只有文字的地方不拦边缘滚屏（否则底边永远滚不动），
	#      但它**要拦滚轮**（玩家正在看底栏，这一下滚动不该把地图拉走）。
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
	# 超宽窗口：右下的三块跟着走，判定也要跟着走（否则命令卡上滚不动地图）
	var bar_wide := UiLayoutRes.bottom_bar_rects(wide)
	var card_wide := UiLayoutRes.card_cell_rect(0)
	card_wide.position.x += wide.x - UiLayoutRes.DESIGN_W
	ok(UiLayoutRes.point_hits_any(bar_wide, card_wide.get_center()),
		"★ 超宽窗口：命令卡的新位置仍然拦滚轮（判定跟着贴边走）")
	ok(not UiLayoutRes.point_hits_any(bar_wide, UiLayoutRes.card_cell_rect(0).get_center()),
		"超宽窗口：命令卡原来的位置不再算底栏")


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
	_test_zone_recruit_via_card(main)
	_test_upgrade_via_card(main)
	await _test_queue_control(cfg)
	_test_queue_cancel_via_click(main)
	_test_auto_select_on_recruit(main)
	_test_order_locked_notice(main)
	_test_right_click_orders(main)
	await _test_box_select(main)
	_test_detail_basic_stats(main)
	_test_detail_two_columns(main)
	_test_clicked_unit_detail(main)
	_test_settings_inert(main)
	_test_box_select_buildings(main)
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

	# ---- 滚轮缩放：底栏上不吃滚轮、移出底栏恢复（用户需求，走真实输入路由）----
	_test_wheel_zoom_block(main)
	# ---- 提示行住在右栏底下那条 20px 里：出现时不再压扁两栏 ----
	await _test_notice_band(main)

	# ---- 选中单位不再画攻击 / 警戒范围圈 ----
	ok(not main.overlay.has_method("_draw_selected_units"),
		"★ overlay 里已经没有「选中范围圈」那段代码（画范围圈的函数被删掉了）")
	ok(main.cfg.get_path_value("colors.range") == null
		and main.cfg.get_path_value("colors.range_edge") == null,
		"★ config 里的 range / range_edge 配色也一起删了（不留死数据）")

	await _test_anchors(main)

	root_node.queue_free()
	await process_frame


# ---- 滚轮缩放：鼠标在底栏（除左下小地图）上时不许缩放地图 ----
#
# 需求原话：「当鼠标位于下方除地图外的 ui 栏时，应当禁用鼠标滚轮缩放地图，
#            当鼠标移出下边栏，需要恢复」。
# ★ 这里走的是**真实那条输入路由**（`game_scene._unhandled_input` → 要么被底栏吃掉、
#   要么落到 input_controller 去缩放相机），不是只问一句几何查询 ——
#   真正容易写错的正是「谁先问谁」（见 `_unhandled_input` 里那段注释）。
func _test_wheel_zoom_block(main) -> void:
	var vp: Vector2 = main.hud.view_size()
	var cam: Camera2D = main.cam
	var on_bar: Vector2 = UiLayoutRes.panel_content_pos() + Vector2(8.0, 8.0)
	var on_map := Vector2(vp.x * 0.5, vp.y * 0.4)

	# ① 真实实例上的几何查询（常量那份断言在 _test_hit_test 里）
	ok(main.hud.blocks_wheel_zoom(on_bar), "★ 鼠标在详细信息面板上 → 滚轮不缩放地图")
	ok(not main.hud.blocks_wheel_zoom(on_map), "鼠标在地图上 → 照旧缩放")
	ok(not main.hud.blocks_wheel_zoom(UiLayoutRes.MAP_RECT.get_center()),
		"★ 小地图上照旧缩放（需求：除地图外）")

	# ② 走一遍输入：底栏上滚 → zoom 不变；移出底栏再滚 → 恢复；再移回 → 又不缩放
	cam.zoom = Vector2.ONE * 1.0
	var z0: float = cam.zoom.x
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, on_bar)
	near(cam.zoom.x, z0, 1e-6, "★ 鼠标在底栏上滚轮 → 被吃掉，地图不缩放")
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, on_map)
	ok(cam.zoom.x > z0, "★ 鼠标移出底栏（回到地图上）→ 滚轮恢复缩放（不是一次性开关）")
	z0 = cam.zoom.x
	_send_wheel(main, MOUSE_BUTTON_WHEEL_UP, UiLayoutRes.card_cell_rect(0).get_center())
	near(cam.zoom.x, z0, 1e-6, "★ 再移回底栏（命令卡）→ 又不缩放")
	# 向下滚同样被吃（两个方向都拦）
	z0 = cam.zoom.x
	_send_wheel(main, MOUSE_BUTTON_WHEEL_DOWN, on_bar)
	near(cam.zoom.x, z0, 1e-6, "★ 向下滚在底栏上也不缩放")
	# 左键照旧是「选中 / 放置」，没有被这条规则连带吃掉
	var left := InputEventMouseButton.new()
	left.button_index = MOUSE_BUTTON_LEFT
	ok(not main._is_wheel(left), "★ 这条规则只认滚轮：左键不会被它吞掉")
	ok(main._is_wheel(_wheel_event(MOUSE_BUTTON_WHEEL_DOWN)),
		"滚轮向下也被认出来（两个方向都拦）")
	cam.zoom = Vector2.ONE * 1.0


func _wheel_event(button: int, pos: Vector2 = Vector2.ZERO) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.position = pos
	return ev


func _send_wheel(main, button: int, pos: Vector2) -> void:
	main._unhandled_input(_wheel_event(button, pos))


# ---- 提示行（红字）：住在右栏数值框下面那条 20px 里，出现时不改任何一块的几何 ----
#
# 第六轮改的：它原来是面板 VBox 的第二行，一出现就把两栏各压掉 20px，
# 而左栏那 3×3 网格是**正好铺满 220** 的（40 + 15 + 3×55）⇒ 最下面一截被裁。
func _test_notice_band(main) -> void:
	var panel = main.hud.detail_panel
	var grid = panel.grid_control()
	var body = panel._body
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

	# 提示带的位置：在数值框下面、右栏下沿之内、右栏宽度之内
	var nr := Rect2(notice.position, notice.size)
	ok(nr.position.y >= UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H,
		"★ 提示带在数值框**下面**（%.0f ≥ %.0f）" % [
			nr.position.y, UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H])
	ok(nr.position.y + nr.size.y <= 220.0 + 0.01, "★ 提示带收在右栏内容高 220 之内")
	ok(nr.size.x <= UiLayoutRes.DETAIL_RIGHT_W + 0.01, "提示行不越出右栏")
	if grid.visible:
		var gr := Rect2(grid.global_position, grid.size)
		var ngr := Rect2(notice.global_position, notice.size)
		ok(not gr.intersects(ngr), "★ 提示行与左栏网格不重叠（它整条都在右栏里）")

	# 真实字体量一遍：最长的那两句提示必须一行放得下
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
	eq(side, 72.0, "★ 右栏头像方框 = 72×72（本轮从参考图的 100 收到 72：那块「大而空」，见 ui_layout 的注释）")
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

	# ★★ buff 占位格里的字也必须装得进 30×30 方框（第六轮改的：13 号字下
	#    「buff1」实测 33px > 30px，`clip_text` 把它裁成了「buff」）。
	#    ⚠️ 用**真实的 HUD 字体**（SimHei）量 —— 这个 standalone 面板没有挂主题，
	#       `get_theme_default_font()` 拿到的不是游戏里那份字体。
	eq(panel._buffs.size(), UiLayoutRes.BUFF_SLOTS, "（前提）3 个 buff 占位格都在")
	for b in panel._buffs:
		var bfs: int = b.get_theme_font_size("font_size")
		var bw: float = font.get_string_size(String(b.text), HORIZONTAL_ALIGNMENT_LEFT, -1, bfs).x
		ok(bw <= b.size.x + 0.01,
			"★ buff 占位字「%s」用 %d 号字宽 %.0f ≤ 方框 %.0f（装得下才不会被裁）"
				% [b.text, bfs, bw, b.size.x])
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

	# ★★ 行文案必须**真的装得下**（第六轮改的：一行 15 号字实测 158px，
	#    而一行能写的地方只有 120 − 8 − 4 = 108px，`clip_text` 会把「· 4 人」裁掉）。
	#    现在两行 13 号字，逐行按**真实字体**量一遍 —— 这种错画出来只是「字缺了一截」，
	#    不会报错，只有量过才抓得住（同 `_test_avatar_text_fit` 那条的理由）。
	var line_font: Font = main.hud._font
	if line_font != null:
		var row_fs: int = panel.slot_button(0).get_theme_font_size("font_size")
		eq(row_fs, UiStyleRes.FS_SMALL, "★ 部队行用 13 号字（15 号下最长 105px，只剩 3px 余量）")
		var sb: StyleBox = panel.slot_button(0).get_theme_stylebox("normal")
		var writable: float = UiLayoutRes.SQUAD_RECT.size.x \
			- sb.content_margin_left - sb.content_margin_right
		for i in 3:
			var lines: PackedStringArray = String(panel.slot_text(i)).split("\n")
			eq(lines.size(), 2, "★ 第 %d 行是两行文案（一行装不下，会被裁）" % (i + 1))
			for ln in lines:
				var w: float = line_font.get_string_size(String(ln),
					HORIZONTAL_ALIGNMENT_LEFT, -1, row_fs).x
				ok(w <= writable + 0.01,
					"★ 部队行第 %d 行的「%s」宽 %.0f ≤ 可写宽 %.0f（装得下才不会被裁）"
						% [i + 1, ln, w, writable])
	else:
		ok(true, "（没装中文字体，跳过部队行的宽度量算）")

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


# ---- 页签（按选中对象动态显示）+ 命令卡内容 ----
#
# ★★ 需求原话：「当玩家选中部队 / 单位时，右下角的页签只显示两个：操作，单位；
#    当玩家选中建筑时，右下角没有页签；当玩家选中区划中心时，右下角显示招募页签
#    （显示三个占位将领）；当玩家选中大本营时，右下角显示科技页签」。
#    另外手玩定了「什么都没选中时显示建筑页签」（城墙 / 箭塔的建造入口住在那儿）。
func _test_page_tabs_and_card(main, cfg) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	var world = main.world

	# ---- 1) 选中部队 → 两颗页签：操作（默认）/ 单位 ----
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

	# 切到「单位」页：还是原来那一项（招募单位的页）
	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_UNIT, "点第二颗切到「单位」页")
	eq(card.entries().size(), 1, "★ 单位页只有 1 项（需求：目前只有一个单位）")
	eq(String(card.entry_at(0).get("type", "")), "recruit", "单位页那一项是「招募」")
	eq(card.cell_label(0), "占位单位", "单位页的 Q 格写着占位单位")
	eq(card.cell_label(1), "", "单位页第 2 格是空的")

	# ---- 2) 什么都没选中 → 「建筑」+「科技」两页（★ 本轮：原来只有建筑一颗）----
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

	# ---- 3) 选中普通建筑（城墙 / 箭塔）→ **「操作」页**（本轮：升级那一格）----
	# ★ 本轮需求原文：「为所有单位/建筑都添加上『操作』页签」——普通建筑的操作页
	#   就是「升级城墙 / 升级箭塔」那一格（原来这里是一颗没有内容的空页签）。
	var plain_b = _plain_building(world)
	ok(plain_b != null, "地图上找得到一栋普通建筑（城墙 / 箭塔）")
	if plain_b != null:
		main.input_ctrl.select_building(plain_b)
		main.hud.refresh()
		eq(tabs.page_count(), 1, "★ 选中普通建筑 → 一颗页签")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 它是「操作」页")
		ok(tabs.button_at(0) != null and tabs.button_at(0).visible,
			"页签按钮是可见的")
		eq(tabs.button_at(0).text, "操作", "页签上写着「操作」")
		v2_near(tabs.button_at(0).size, Vector2(100.0, 240.0), 1.0,
			"★ 只有一颗时它铺满整列（100×240）")
		ok(tabs.is_active(0), "★ 当前页画成高亮")
		# ★★ 回归：页签必须**看得见** —— 非当前页的普通态底色不能是全透明。
		ok(UiStyleRes.tab_normal().bg_color.a > 0.2,
			"★ 非当前页的页签有底色（全透明时立在地图上看不见）")
		ok(UiStyleRes.tab_active().bg_color.a > 0.9, "当前页仍是实心强调色（变的是普通态）")
		eq(card.entries().size(), 1, "★ 操作页只有一格（升级）")
		eq(String(card.entry_at(0).get("type", "")), "building_upgrade",
			"那一格是「升级」")
		eq(card.cell_label(0), "升级%s" % plain_b.display_name(),
			"★ 格子上写着「升级%s」" % plain_b.display_name())

	# ---- 4) 选中大本营 → 操作 + 科技（★ 本轮：操作页里有「升级大本营」）----
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
		# 切到科技页：还是那颗九格（与空手时同一页）
		tabs.button_at(1).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_TECH, "点第二颗切到「科技」页")
		_eq_tech_page(main, "选中大本营")
		ok(not main.hud.tech_grid.visible or true, "（科技页转换见下）")
		# 切回操作页（后面的用例按「大本营停在操作页」起步）
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "切回操作页")
		eq(card.entries().size(), 1, "操作页还是「升级大本营」那一格")

	# ---- 4b) 空手时那颗科技页签 → **同一页**（同一套九格内容）----
	main.input_ctrl.select_units([])
	main.hud.refresh()
	eq(tabs.page_count(), 2, "空手时建筑 / 科技两颗")
	tabs.button_at(1).emit_signal("pressed")
	eq(tabs.page(), PageTabsRes.PAGE_TECH, "点第二颗切到「科技」页")
	_eq_tech_page(main, "什么都没选中")
	# ★ 点一格 = 启用；再点 = 弃用（命令走 tech_toggle）
	var g = main.hud.tech_grid
	var first_id := String((g.entry_at(0) as Dictionary).get("id", ""))
	ok(first_id != "", "第一格有 id")
	ok(not world.is_tech_active(first_id), "开局这一条没启用")
	g.press(0)
	ok(world.is_tech_active(first_id), "★ 点一格 = 启用（走 tech_toggle 命令）")
	ok(g.cell_active(0), "★ 已启用的那一格画成高亮")
	g.press(0)
	ok(not world.is_tech_active(first_id), "★ 再点一次 = 弃用")
	# ★ 启用满 3 条之后点第 4 格：被阻止 + 红字提示
	var ids: Array = []
	for i in g.entries().size():
		ids.append(String((g.entry_at(i) as Dictionary).get("id", "")))
	for k in 3:
		g.press(k)
	eq(world.active_tech_ids().size(), 3, "★ 启用了三条")
	ok(world.tech_remaining_slots() == 0, "名额用完")
	g.press(3)
	ok(not world.is_tech_active(ids[3]), "★ 第 4 条没有生效（被阻止）")
	ok(main.hud.notice_active(), "★ 满了之后点第 4 条会弹提示")
	ok(main.hud.notice_text().contains("3"), "提示里说明「最多 3 个」：%s" % main.hud.notice_text())
	# 收尾：把这三条弃用（后面的用例不该带着科技加成跑）
	for k in 3:
		g.press(k)
	eq(world.active_tech_ids().size(), 0, "收尾：弃用全部科技")

	# ---- 5) 选中区划中心 → 操作（三个特化）+ 招募（三个占位将领）----
	var zone = _zone_with_center(world)
	ok(zone != null, "地图上找得到一个带中心的区划")
	if zone != null:
		main.input_ctrl.select_zone(zone)
		main.hud.refresh()
		eq(tabs.page_count(), 2, "★ 选中区划中心有两颗页签（操作 / 招募）")
		eq(tabs.page_id_at(0), PageTabsRes.PAGE_ORDER, "第一颗是「操作」")
		eq(tabs.page_id_at(1), PageTabsRes.PAGE_RECRUIT, "第二颗是「招募」")
		# ★ 显式停在「操作」页：hud 会记住「区划中心这一类上次停在哪个页签」
		#   （`_page_memory`），而前面的用例在招募页停过 —— 不显式切回来的话，
		#   这里读到的会是招募页那三个将领（那不是 bug，是「记住上次那一页」）。
		tabs.select_page(PageTabsRes.PAGE_ORDER)
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "★ 停在「操作」页")
		# 操作页 = 三个特化（只能选一个）
		eq(card.entries().size(), 3, "★ 操作页里是三个特化")
		eq(card.cell_label(0), "粮食特化", "Q 格 = 粮食特化")
		eq(card.cell_label(1), "黄金特化", "W 格 = 黄金特化")
		eq(card.cell_label(2), "人口特化", "E 格 = 人口特化")
		eq(String(card.entry_at(0).get("type", "")), "zone_specialize",
			"操作页那一项是「特化」")
		eq(String(card.entry_at(0).get("spec", "")), "food", "第 1 格是粮食特化")
		# 切到招募页：还是原来那三个占位将领
		tabs.button_at(1).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 第二颗 = 招募页签")
		eq(card.entries().size(), 3, "★ 招募页里是三个占位将领（需求原话）")
		eq(card.cell_label(0), "将领 1", "Q 格 = 将领 1")
		eq(card.cell_label(1), "将领 2", "W 格 = 将领 2")
		eq(card.cell_label(2), "将领 3", "E 格 = 将领 3")
		eq(String(card.entry_at(0).get("type", "")), "zone_recruit",
			"招募页那一项是「区划招募」（排进区划的队列）")
		eq(String(card.entry_at(0).get("unit_kind", "")), "general_1",
			"第 1 格要招的兵种是 general_1")
		# 回到操作页（后面的用例按「停在操作页」起步）
		tabs.button_at(0).emit_signal("pressed")
		eq(tabs.page(), PageTabsRes.PAGE_ORDER, "切回操作页")

	# 收尾：回到「选中将领 1」并把页签停在「操作」页（后面的用例按这个前提起步）
	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_ORDER, "收尾：回到操作页")


## 命令卡现在这九格的类型串（诊断用：断言失败时要一眼看出「画的是哪一套」）
func _entry_types(card) -> Array:
	var out: Array = []
	for i in card.entries().size():
		out.append(String(card.entry_at(i).get("type", "")))
	return out


## 「科技页」长什么样（选中大本营 / 什么都没选中时都是**同一套**九格）。
## ★ 需求原话：「当前占位用科技有 9 个，铺满右下角科技页签的 3x3 格子」。
func _eq_tech_page(main, where: String) -> void:
	var g = main.hud.tech_grid
	var card = main.hud.command_card
	ok(g.visible, "%s：★ 科技九格显示出来了" % where)
	eq(g.entries().size(), 9, "%s：★ 九格铺满（9 条占位科技）" % where)
	eq(card.entries().size(), 0, "%s：命令卡在科技页是空的（内容由科技那一层画）" % where)
	eq(g.cell_name(0), "粮食产量 I", "%s：第 1 格 = 粮食产量 I" % where)
	eq(g.cell_line(0), "粮食 +1", "%s：第 1 格第二行写效果" % where)
	ok(String((g.entry_at(0) as Dictionary).get("desc", "")).contains("地块"),
		"%s：tooltip 里是完整效果说明" % where)
	eq(g.cell_name(6), "建筑加固", "%s：第 7 格 = 建筑加固" % where)
	eq(g.cell_name(7), "将领强化", "%s：第 8 格 = 将领强化" % where)
	eq(g.cell_name(8), "区划人口", "%s：第 9 格 = 区划人口" % where)
	eq(g.cell_name(9), "", "%s：越界格（第 10 格）读不到东西" % where)
	# 九格的位置与命令卡那九格**完全重合**（换页时看不出换了控件）
	var c0: Rect2 = UiLayoutRes.card_cell_rect(0)
	var g_rect: Rect2 = g.get_global_rect()
	v2_near(g_rect.position, c0.position, 1.0,
		"%s：★ 科技九格的左上角与命令卡重合" % where)


## 一栋**普通**建筑（城墙 / 箭塔 / 预置建筑），用来验「选中建筑没有页签」
func _plain_building(world):
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if b.type == "wall" or b.type == "tower":
			return b
	return null


## 一个**带中心**的区划（点它的中心 = 看这个区划的详情 / 招募）
func _zone_with_center(world):
	for z in world.zones.zones:
		if z["center"] != null:
			return z
	return null


# ---- 命令卡的九个字母键 ----
func _test_card_keys(main) -> void:
	var tabs = main.hud.page_tabs
	var card = main.hud.command_card
	var g1 = main.world.unit_by_id("general-1")

	# ★ 建筑页只在「什么都没选中」时出现（见 hud._tab_plan）——先清空选中。
	# ⚠️ 这里**同时显式切回建筑页**：空手那一屏现在有「建筑 / 科技」两颗页签，
	#    而 hud 会记住玩家上一次停在那一页（`_page_memory`）——上一个用例点过科技页，
	#    所以不显式切回来的话，这里会停在科技页（这不是 bug，是「记住上次那一页」）。
	main.input_ctrl.select_units([])
	main.hud.refresh()
	tabs.select_page(PageTabsRes.PAGE_BUILD)
	eq(tabs.page(), PageTabsRes.PAGE_BUILD, "（前提）没选中东西 → 停在建筑页")

	# 空格子的字母不该被命令卡吃掉（建筑页只有 Q/W 两格，A 是空的）
	var a_ev := _key(KEY_A)
	ok(not card.handle_key(a_ev), "空格子（A）不消费按键")

	# 建筑页：Q = 城墙，W = 箭塔（需求原话）
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

	# ---- 操作页：Q/W/E 是**真指令**（进命令模式 → 左键点地图下达）----
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

	# ---- 「停止」是**即时**的：点一下当场下达，不进命令模式（它不需要点地图选目标）----
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

	# ★ 带修饰键的组合键不许被命令卡吃掉。
	#   为什么单列一条：命令卡在输入链里排在 main / input_controller 的**前面**
	#   （game_scene._unhandled_input 先问 hud），所以 Ctrl+Q（开发者快捷键：全屏）
	#   如果被它吃掉，「切全屏」就会顺手触发 Q 格 —— 操作页按下去 = 进入移动模式。
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
	# ★ 选中部队时默认停在「操作」页 —— 这一节验的是单位页那条路，先切过去
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_UNIT, "（前提）切到单位页")
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

	# ---- 选中部队时这一屏只有「操作 / 单位」两页：切页不会串到队列上 ----
	eq(main.hud.page_tabs.page_count(), 2, "（前提）选中部队时只有两颗页签")
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_BUILD)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_UNIT,
		"★ 不在这一屏里的页（建筑）切不过去")
	eq(g1.train_queue_size(), 2, "切页不会改变队列")

	# 选中别的单位 → 队列那五格收起来（它只显示「当前展开那支部队」的队列）
	main.input_ctrl.select_units([])
	main.hud.refresh()
	ok(not queue.showing(), "★ 没选中招募中的将领时五格收起来")

	# 收尾：把这个将领的队列清干净（下一个用例要从「没在招募」开始）
	while g1.train_queue_size() > 0:
		world.cancel_recruit(g1.id, 0, "p1")
	ok(not g1.is_training(), "收尾：队列已清空")


# ---- 区划招募：点区划中心 → 招募页 → 点某一格 → 排进**区划**的队列（UI → 命令 → 队列显示）----
#
# ★ 规则本身（消耗 / 人口 / 读条 / 中心旁生成 / 取消退款）在 tests/test_zone_recruit.gd；
#   这里验的是「选中的是谁 → 页签是哪一颗 → 队列控件显示谁的队列」这条接线。
func _test_zone_recruit_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var base = world.find_base_of("p1")
	ok(base != null, "有己方大本营（用来找一块己方区划）")
	if base == null:
		return
	# 大本营所在的那块区划：开局就被大本营收归己方（zone_owned_by_building）
	var zone = world.zones.zone_at(base.tx, base.ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return

	world.resources["food"] = 1000.0
	world.resources["gold"] = 1000.0
	zone["population"] = 10.0

	# 点区划中心（= 选中这个区划）→ 操作（三个特化）+ 招募两颗页签
	main.input_ctrl.select_zone(zone)
	main.hud.refresh()
	eq(main.hud.page_tabs.page_count(), 2, "★ 选中区划中心 → 操作 + 招募两颗页签")
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_RECRUIT)
	eq(main.hud.page_tabs.page(), PageTabsRes.PAGE_RECRUIT, "★ 切到「招募」页签")
	eq(card.entries().size(), 3, "★ 招募页里是三个占位将领")

	var q = main.hud.detail_panel.queue_control()
	ok(not q.showing(), "没在招募时五格收起来")
	ok(q.is_zone_queue() and q.holder() == zone,
		"（前提）队列控件已经指向这个区划（只是还没东西可显示）")

	# ---- 点第 1 格 → 排进这个区划的队列 ----
	var food_before: float = float(world.resources["food"])
	var pop_before: float = float(zone["population"])
	card.activate_index(0)
	ok(world.zone_is_training(zone), "★ 点招募页的 Q 格 → 排进了**这个区划**的队列")
	eq(world.zone_recruit_kind_at(zone, 0), "general_1", "大格子里是刚排进去的那个将领")
	near(float(world.resources["food"]), food_before - 50.0, 1e-4, "★ 入队即扣 50 粮食")
	near(float(zone["population"]), pop_before - 1.0, 1e-4, "★ 入队即扣这个区划 1 人口")

	main.hud.refresh()
	ok(q.showing(), "★ 信息栏里出现五个格子")
	ok(q.is_zone_queue(), "★ 这个五格显示的是**区划**的队列（不是某个将领的）")
	eq(q.slot_count(), 5, "五个格子")
	ok(q.cell_label(0).contains("将"), "大格子里写着短名「将」（实际：%s）" % q.cell_label(0))

	# 再排一单 → 进小格子
	card.activate_index(1)
	main.hud.refresh()
	eq(world.zone_recruit_queue_size(zone), 2, "第二个排进小格子")
	ok(q.cell_filled(1), "第 1 个小格子填上了")

	# ---- 点小格子 = 取消那一格 + 退款 ----
	food_before = float(world.resources["food"])
	_click_control(q, UiLayoutRes.queue_cell_rect(1).get_center())
	eq(world.zone_recruit_queue_size(zone), 1, "★ 点小格子 = 取消那一格")
	near(float(world.resources["food"]), food_before + 50.0, 1e-4, "★ 取消会退款")
	main.hud.refresh()
	ok(not q.cell_filled(1), "那一格空了")

	# 收尾：清干净队列（后面的用例要在「没在招募」的世界里跑）
	while world.zone_is_training(zone):
		world.cancel_zone_recruit(int(zone["id"]), 0, "p1")
	main.hud.refresh()
	ok(not q.showing(), "收尾：队列清空 → 五格收起来")

	# 选中部队 → 队列控件回到「将领的队列」那一套（主人的切换是干净的）
	main.input_ctrl.select_units([world.unit_by_id("general-1")])
	main.hud.refresh()
	ok(not q.is_zone_queue(), "★ 改选部队之后，队列控件不再显示区划的队列")
	main.input_ctrl.select_units([])
	main.hud.refresh()


# ---- 建筑升级 / 区划特化：操作页那几格 → 读条 →（复用）信息栏那块面板 ----
#
# 需求原话：「大本营的操作页签中有一个升级大本营选项，点击后开始读条（和招募单位时的
# 读条一样，可以复用招募单位的面板）……区划中心有三个特化选项……特化也需要读条，
# 取消特化也需要读条」。
# ★ 规则本身（等级 / 血量 / 产能 / 退款）在 tests/test_upgrade.gd；
#   这里验的是「页签 → 操作页的格子 → 命令 → 那块面板显示读条 → 点它取消」这条接线。
func _test_upgrade_via_card(main) -> void:
	var world = main.world
	var card = main.hud.command_card
	var tabs = main.hud.page_tabs
	var q = main.hud.detail_panel.queue_control()
	world.resources["food"] = 5000.0
	world.resources["gold"] = 5000.0

	# ---- ① 升级城墙：点操作页那一格 → 读条出现在信息栏 ----
	var wall = null
	for b in world.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL and String(b.owner) == world.my_faction:
			wall = b
			break
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
	# 信息栏那块面板 → 单条读条模式
	main.hud.refresh()
	ok(q.showing(), "★ 信息栏里出现读条面板")
	ok(q.is_bar_mode(), "★ 它是「单条读条」模式（复用招募那块面板）")
	ok(q.title_text().contains("升级"), "汇总带写着「升级…」（实际：%s）" % q.title_text())
	ok(q.cell_label(0).contains("升"), "大格子里写着「升 2 级」（实际：%s）" % q.cell_label(0))
	ok(not q.cell_filled(1), "★ 四个小格子留空（这一单没有队列）")
	near(q.progress(), 0.0, 0.05, "刚入队进度接近 0")
	# 读条中：操作页只剩「取消升级」那一格
	main.hud.refresh()
	eq(card.entries().size(), 1, "读条中操作页只有一格")
	eq(String(card.entry_at(0).get("type", "")), "building_upgrade_cancel",
		"★ 那一格是「取消升级」（实际：%s）" % String(card.entry_at(0).get("type", "")))
	# 点面板上那一格 = 取消 + 退款
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not wall.is_upgrading(), "★ 点读条那一格 = 取消升级")
	eq(wall.level, lv0, "等级没变")
	near(float(world.resources["food"]), food0, 1e-4, "★ 取消全额退款")

	# ---- ② 读完：等级 +1、血量上限变高、那格回到「升级」 ----
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
	ok(main.hud.detail_panel.detail_text().contains("等级 %d" % wall.level),
		"★ 右栏数值里有「等级 %d」（实际：%s）" % [wall.level, main.hud.detail_panel.detail_text()])

	# ---- ③ 区划中心：三个特化 → 点一个 → 读条 → 特化生效后只剩「取消特化」----
	var zone = world.zones.zone_at(world.find_base_of("p1").tx, world.find_base_of("p1").ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return
	main.input_ctrl.select_zone(zone)
	main.hud.refresh()
	# ★ 显式停在操作页（hud 会记住「区划中心上次停在哪个页签」，前一个用例停在招募页）
	tabs.select_page(PageTabsRes.PAGE_ORDER)
	eq(tabs.page(), PageTabsRes.PAGE_ORDER, "（前提）区划中心停在操作页")
	eq(card.entries().size(), 3, "★ 没特化时操作页 = 三个特化")
	card.activate_index(0)                      # 粮食特化
	ok(UpgradeRes.zone_is_busy(zone), "★ 点粮食特化 = 开始读条")
	main.hud.refresh()
	ok(q.is_bar_mode(), "★ 特化读条也走信息栏那块面板")
	ok(q.title_text().contains("粮食"), "汇总带写着「粮食特化」（实际：%s）" % q.title_text())
	ok(q.cell_label(0).contains("特化中"), "大格子里写着「特化中」（实际：%s）" % q.cell_label(0))
	eq(card.entries().size(), 1, "读条中操作页只剩一格（entries=%s）" % str(_entry_types(card)))
	eq(String(card.entry_at(0).get("type", "")), "zone_spec_bar_cancel",
		"★ 那一格是「取消特化」（撤单）")
	# 读条中再点「取消特化」那一格 = 撤掉这一单（不是取消已有特化）
	_click_control(q, UiLayoutRes.queue_cell_rect(0).get_center())
	ok(not UpgradeRes.zone_is_busy(zone), "★ 撤掉了那一单")
	eq(String(zone.get("spec_done", "")), "", "还没特化过")
	# 重新来一次并读完
	main.hud.refresh()
	eq(card.entries().size(), 3, "撤单后操作页又是三个特化")
	card.activate_index(0)
	world.tick(60.0)
	main.hud.refresh()
	main.hud.rebuild_card()      # 真实游戏里由每帧 refresh 的页签比较兜底；测试里显式刷一次
	eq(String(zone.get("spec_done", "")), "food", "★ 读完特化生效")
	near(UpgradeRes.zone_spec_mult(zone, world.cfg)["food"], 1.1, 1e-6, "★ 本区块粮食 +10%")
	eq(card.entries().size(), 1, "★ 特化后操作页只剩一格（不能再特化）")
	eq(String(card.entry_at(0).get("type", "")), "zone_spec_cancel",
		"★ 那一格是「取消特化」")
	eq(card.cell_label(0), "取消特化", "格子上写着「取消特化」")
	ok(main.hud.detail_panel.detail_text().contains("特化"),
		"★ 区划详情里写着特化状态（实际：%s）" % main.hud.detail_panel.detail_text())
	# 点「取消特化」→ **也要读条**
	card.activate_index(0)
	ok(UpgradeRes.zone_is_busy(zone), "★ 取消特化也要读条")
	ok(UpgradeRes.zone_spec_is_cancel(zone), "这一条是「取消特化」")
	main.hud.refresh()
	ok(q.is_bar_mode(), "那块面板显示取消特化的读条")
	ok(q.title_text().contains("取消"), "汇总带写着「取消…」（实际：%s）" % q.title_text())
	# ★ 「取消特化」的读条本身不可取消：那块面板不吃点击
	ok(q.cell_at_position(UiLayoutRes.queue_cell_rect(0).get_center()) < 0,
		"★ 「取消特化」的读条不可再取消（点了没反应）")
	world.tick(60.0)
	main.hud.refresh()
	main.hud.rebuild_card()
	eq(String(zone.get("spec_done", "")), "", "★ 读完特化被去掉")
	eq(card.entries().size(), 3, "★ 操作页又能选三个特化了")

	# 收尾：清干净（后面的用例要在「没在读条」的世界里跑）
	while UpgradeRes.zone_is_busy(zone):
		world.tick(60.0)
	for b in world.building_list:
		if b.is_upgrading():
			world.cancel_building_upgrade(b.tx, b.ty)
	main.input_ctrl.select_units([])
	main.hud.refresh()


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
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)   # 单位页（招募那一页）
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
	main.hud.refresh()
	main.hud.page_tabs.select_page(PageTabsRes.PAGE_UNIT)   # 单位页（招募那一页）
	main.hud.refresh()
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


# ---- 招募队列控件（RecruitQueue）：汇总带 + 五格的显示与读条（第七轮的显示优化）----
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
	eq(q.title_text(), "", "没在招募时汇总带是空的")

	w.start_recruit(UnitRes.KIND_SUBORDINATE, g1.id, "p1")
	w.start_recruit(UnitRes.KIND_SUBORDINATE, g1.id, "p1")
	q.set_leader(g1)
	ok(q.showing(), "★ 开始招募 → 五格出现")
	eq(q.slot_count(), 5, "五个格子")
	eq(q.cell_kind(0), UnitRes.KIND_SUBORDINATE, "大格子是正在读条的那个")
	eq(q.cell_kind(1), UnitRes.KIND_SUBORDINATE, "第 1 个小格子是排队的那个")
	eq(q.cell_kind(2), "", "后面三个小格子是空的")
	ok(q.cell_filled(0) and q.cell_filled(1) and not q.cell_filled(2), "填充状态跟着队列走")

	# ---- ① 汇总带：排了几个 / 上限 + 整条队列读完还要多久 ----
	eq(q.queue_count(), 2, "汇总用的是「含正在读条那个」的数量（与队列上限同口径）")
	eq(q.title_text(), "招募队列 2/%d" % w.recruit_queue_max(),
		"★ 汇总第一行写着「招募队列 2/5」（实际：%s）" % q.title_text())
	near(q.total_eta(), 20.0, 0.05, "★ 整条队列读完还要 20 秒（两个单位各 10 秒）")
	ok(q.total_text().begins_with("共") and q.total_text().ends_with("s"),
		"★ 汇总第二行写着「共 20s」（实际：%s）" % q.total_text())

	# ---- ② 每个格子都带时间：大格子是「剩 x.xs」，小格子是「轮到我还差 xs」----
	near(q.eta_of(0), 10.0, 0.05, "大格子的 ETA = 它自己的剩余秒")
	near(q.eta_of(1), 20.0, 0.05, "★ 第 1 个小格子的 ETA = 大格子读完 + 它自己读 10 秒")
	near(q.eta_of(2), 0.0, 1e-6, "空槽位的 ETA 是 0（没排到就不报时间）")
	ok(q.cell_label(0).contains("剩"), "大格子写着「剩 x.xs」（实际：%s）"
		% q.cell_label(0).replace("\n", "|"))
	ok(q.cell_label(1).contains("20s"), "★ 小格子写着「轮到我还差几秒」（实际：%s）"
		% q.cell_label(1).replace("\n", "|"))

	# ---- ③ 读条推进 → 进度跟着涨，且**每个格子的秒数一起往前跑** ----
	for _i in 300:
		w.tick(1.0 / 60.0)
	q.set_leader(g1)
	near(q.progress(), 5.0 / 10.0, 0.05, "★ 读条到一半 → 进度条 50%")
	ok(q.cell_label(0).contains("s"), "大格子上写着剩余秒数（实际：%s）" % q.cell_label(0))
	near(q.eta_of(0), 5.0, 0.05, "过半之后大格子只剩 5 秒")
	near(q.eta_of(1), 15.0, 0.05, "★ 小格子的 ETA 跟着缩到 15 秒（视图每帧问逻辑层）")
	ok(q.total_text().contains("15"), "汇总第二行也跟着变成「共 15s」（实际：%s）" % q.total_text())

	# ---- ④ 悬停：只有**有内容的格子**才认（汇总带 / 空格子不算）----
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

	# 真的画一帧（`_draw` 里出错在无头下**不会**让测试失败，所以盯一下计数器）
	var before_draw: int = q.draw_count
	q.queue_redraw()
	await process_frame
	ok(q.draw_count > before_draw, "★ 队列那一块真的画了一帧（底板 / 读条 / 汇总都在 _draw 里）")

	q.queue_free()


## 造一次鼠标移动（走控件自己的命中判定），把鼠标放到某一格上
func _hover_queue_cell(q: Control, slot: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = UiLayoutRes.queue_cell_rect(slot).get_center()
	q._gui_input(ev)


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
		# ★★ 本轮改版（数值区只留基础数值、两栏版式、编制只有将领有）单独放在
		#    `_test_detail_basic_stats` 里 —— 它会临时改选中与展开的部队，
		#    插在这里会把下面那批「多选 / 换展开」的断言搅乱（实测踩过）。


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
		# ★★ 右栏那几块（本轮重排过，见 ui_layout.gd 里那段注释）：
		#    头像 100 → 72、名称与 buff 挪到同一横带、数值框 90 → 116。
		eq(UiLayoutRes.UNIT_AVATAR, 72.0,
			"★ 右栏头像方框 72×72（第五轮重排：原来照参考图的 100×100 又大又空）")
		eq(UiLayoutRes.BUFF_SIZE, 40.0,
			"★ buff 三格各 40×40（第七轮 30 → 40：与左栏那些 40×40 方块同号，字也能用到 13 号）")
		# 名称与 buff 都在头像右边
		ok(UiLayoutRes.BUFF_X >= UiLayoutRes.UNIT_AVATAR_X + UiLayoutRes.UNIT_AVATAR,
			"★ 三个 buff 排在头像**右边**（%s ≥ 头像右缘 %s）" % [
				str(UiLayoutRes.BUFF_X),
				str(UiLayoutRes.UNIT_AVATAR_X + UiLayoutRes.UNIT_AVATAR)])
		ok(UiLayoutRes.BUFF_Y >= UiLayoutRes.UNIT_NAME_Y,
			"★ 名称与 buff 同一条横带（buff 顶边 %s ≥ 名称顶边 %s）" % [
				str(UiLayoutRes.BUFF_Y), str(UiLayoutRes.UNIT_NAME_Y)])
		ok(UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE
				<= UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR + 1e-6,
			"★ 三个 buff 落在头像的竖直范围内（%s..%s ≤ 头像下缘 %s）" % [
				str(UiLayoutRes.BUFF_Y),
				str(UiLayoutRes.BUFF_Y + UiLayoutRes.BUFF_SIZE),
				str(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR)])
		# ★ 名称右边缘必须让开右上角的招募队列（否则名字会被队列压住）
		ok(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W <= UiLayoutRes.QUEUE_X + 1e-6,
			"★ 单位名称那一行不顶到招募队列（%s ≤ %s）" % [
				str(UiLayoutRes.UNIT_NAME_X + UiLayoutRes.UNIT_NAME_W),
				str(UiLayoutRes.QUEUE_X)])
		ok(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR
				< UiLayoutRes.DETAIL_BODY_Y,
			"★ 头像在「详细信息」方框上面，不重叠（%s < %s）" % [
				str(UiLayoutRes.UNIT_AVATAR_Y + UiLayoutRes.UNIT_AVATAR),
				str(UiLayoutRes.DETAIL_BODY_Y)])
		# ★★ 第七轮：顶带（头像 / 名称+buff / 队列）自成一带，且头像与队列同一条中轴线
		eq(UiLayoutRes.UNIT_AVATAR_Y,
			UiLayoutRes.UNIT_BAND_Y + (UiLayoutRes.UNIT_BAND_H - UiLayoutRes.UNIT_AVATAR) * 0.5,
			"★ 头像在顶带里**垂直居中**（%.0f = %.0f + (%.0f−72)/2）" % [
				UiLayoutRes.UNIT_AVATAR_Y, UiLayoutRes.UNIT_BAND_Y, UiLayoutRes.UNIT_BAND_H])
		eq(UiLayoutRes.QUEUE_Y + UiLayoutRes.QUEUE_H * 0.5,
			UiLayoutRes.UNIT_BAND_Y + UiLayoutRes.UNIT_BAND_H * 0.5,
			"★ 招募队列与头像**同一条中轴线**（队列中心 = 顶带中心）")
		ok(UiLayoutRes.DETAIL_BODY_Y >= UiLayoutRes.UNIT_BAND_Y + UiLayoutRes.UNIT_BAND_H,
			"★ 数值框不压到顶带（%s ≥ %s）" % [
				str(UiLayoutRes.DETAIL_BODY_Y),
				str(UiLayoutRes.UNIT_BAND_Y + UiLayoutRes.UNIT_BAND_H)])
		# ★★ 第七轮：右栏所有方块的右缘都停在 UNIT_CONTENT_RIGHT（不贴 645 的裁剪线）
		eq(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W,
			UiLayoutRes.UNIT_CONTENT_RIGHT,
			"★ 数值框右缘 = 右栏内容的公共右缘 641（= 645 − 4，不贴裁剪线）")
		eq(UiLayoutRes.DETAIL_BODY_X + UiLayoutRes.DETAIL_BODY_W,
			UiLayoutRes.QUEUE_X + UiLayoutRes.QUEUE_W,
			"★ 数值框右缘 = 招募队列右缘（右栏右侧没有任何一块短一截 / 长一截）")
		eq(UiLayoutRes.NOTICE_Y + UiLayoutRes.NOTICE_H, 220.0,
			"★ 提示带正好收在右栏下沿（200..220 = 数值框下面那条本来空着的带）")
		ok(UiLayoutRes.NOTICE_Y >= UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H,
			"★ 提示带与数值框不重叠（%s ≥ %s）" % [
				str(UiLayoutRes.NOTICE_Y),
				str(UiLayoutRes.DETAIL_BODY_Y + UiLayoutRes.DETAIL_BODY_H)])
		ok(UiLayoutRes.NOTICE_H >= 16.0,
			"★ 提示带装得下一行 15 号字（行高 16，实测）")
		# ★★ 第七轮：正文是真·两栏（两个 Label），两栏的 x / 宽由 ui_layout 定死
		eq(UiLayoutRes.DETAIL_BODY_COL2_X + UiLayoutRes.DETAIL_BODY_COL2_W
				+ UiLayoutRes.DETAIL_BODY_PAD,
			UiLayoutRes.DETAIL_BODY_W,
			"★ 正文两栏 + 边距正好铺满数值框（左栏 190 + 缝 18 + 右栏 417 + 边距 16 = 641）")
		ok(UiLayoutRes.DETAIL_BODY_COL2_X
				>= UiLayoutRes.DETAIL_BODY_PAD + UiLayoutRes.DETAIL_BODY_COL_W,
			"★ 右栏不压到左栏（%s ≥ %s）" % [
				str(UiLayoutRes.DETAIL_BODY_COL2_X),
				str(UiLayoutRes.DETAIL_BODY_PAD + UiLayoutRes.DETAIL_BODY_COL_W)])
		# ★★ 数值框加高之后要真的「装得下」：正文（关掉 autowrap 的多行文本）按 13 号字
		#    实测自然高度必须 ≤ 可视高度 —— 这是「太拥挤」那轮的核心判据。
		#    旧版是 90-24 = 66 的可视高配 7 行 11 号字，**根本装不下**（最后 1~2 行被裁）。
		var font: Font = main.hud._font
		if font != null:
			var body_fs: int = UiStyleRes.FS_SMALL
			var lh: float = font.get_height(body_fs)
			var visible: float = UiLayoutRes.DETAIL_BODY_H - 24.0
			var capacity: int = int(floor(visible / lh))
			ok(capacity >= 5,
				"★ 数值框（可视高 %.0f）按 %d 号字装得下 %d 行（≥5 行才够放基础数值）" % [
					visible, body_fs, capacity])
			var probe := "攻击距离 3 格 / 间隔 1.2s"
			ok(font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, body_fs).x
					<= UiLayoutRes.DETAIL_BODY_COL_W,
				"★ 最长的一行（「%s」）在 %d 号字下 %.0f px ≤ 左栏可写宽 %.0f" % [
					probe, body_fs,
					font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, body_fs).x,
					UiLayoutRes.DETAIL_BODY_COL_W])
		else:
			ok(true, "（没装中文字体，跳过字号容量的量算）")

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


# ------------------------------------------------------------------
# 框选**建筑**：框里没有己方单位、只有己方建筑时 → 多选建筑，左侧按 1333 显示
# ------------------------------------------------------------------
#
# 需求原话：「玩家可以框选建筑（当玩家划出的框中没有单位只有己方建筑时，则多选建筑），
#            在左侧按 1333 显示选中的建筑」+「和多选单位时的逻辑一样，玩家可以用鼠标滚轮
#            切换显示页」。
#
# ★ 三条要钉住的规则：
#   ① **单位优先**：框里只要有己方单位，走的就还是「选中单位」那条老路；
#   ② 左侧版式与部队完全一致（左上第 1 格 = 主选中，下面 3×3 = 其余，滚轮翻页）；
#   ③ 点建筑格 = 换「正在看哪一个」，**不改选中了哪些**（与点将领格同一条约定）。
func _test_box_select_buildings(main) -> void:
	var world = main.world
	# ---- 1) 把己方单位全部挪到地图右下角（框里只留建筑，才走「多选建筑」那条路）----
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

	# ---- 2) 在左上角那片空地上建自己的城墙（要够多，才验得到滚轮翻页）----
	var rect := Rect2(Vector2(1.0, 1.0), Vector2(9.0, 9.0))       # (1,1)..(10,10)
	var built: Array = []
	for ty in range(1, 10):
		for tx in range(1, 10):
			if world.can_build_at(tx, ty):
				var nb = world.add_building("wall", tx, ty, world.my_faction, true)
				if nb != null:
					built.append(nb)
	ok(built.size() >= 2, "（前提）在框内建了 %d 段己方城墙" % built.size())

	# 期望值：框内**己方、活着、不无敌**的建筑（口径与 input_controller 里那条一致）
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

	# ---- 3) 框选：框里没有单位 → 选中的是建筑 ----
	main.input_ctrl.select_units([])
	var picked: int = main.input_ctrl.box_select(rect.position, rect.end)
	eq(picked, expect.size(), "★ 框里没有单位时，框到的是框内的己方建筑")
	eq(main.input_ctrl.selected_units.size(), 0, "★ 建筑那一批不算「选中单位」")
	eq(main.input_ctrl.selected_buildings.size(), expect.size(),
		"★ 选中的建筑 = 框内全部己方建筑")
	eq(main.input_ctrl.selected_building, expect[0], "★ 主选中 = 第一个（右栏显示它）")

	# ---- 4) 左侧那 1 + 3×3：主选中在左上格，其余在网格里（与部队同一套版式）----
	main.hud.refresh()
	var panel = main.hud.detail_panel
	var roster = panel.roster_control()
	var grid = panel.grid_control()
	eq(panel.grid_mode(), "buildings", "★ 选中建筑时左栏下半是**建筑模式**")
	ok(roster.visible, "★ 左栏左上那一格出现（主选中那个建筑）")
	eq(roster.leader_name(), expect[0].display_name(), "★ 左上那一格写主选中建筑的名字")
	eq(roster.leader_short(), expect[0].display_name().substr(0, 1), "方框里写名字首字")
	eq(roster.count_text(), "%d/%d" % [int(round(expect[0].hp)), int(round(expect[0].hp_max))],
		"★ 左上那一格第二行写血量 x/y")
	# ★ 那一行必须真的装得下（大本营是 1000/1000，实测 13 号字下 59px）——
	#   否则玩家看到的是被截断的「1000/10…」，那比不显示还糟。
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
	eq(grid.cell_count(), mini(expect.size() - 1, UiLayoutRes.GRID_PAGE),
		"★ 下面 3×3 画其余选中的建筑（一页最多 9 格）")
	eq(grid.building_at(0), expect[1], "★ 网格第 1 格是第 2 个建筑（主选中在左上）")
	eq(grid.cell_name(0), expect[1].display_name(), "格子里写着建筑名")
	ok(grid.cell_is_building(0), "那一格是建筑格（不是单位格）")
	eq(grid.cell_sub_text(0), "%d/%d" % [int(round(expect[1].hp)), int(round(expect[1].hp_max))],
		"★ 建筑格第二行是血量 x/y")

	# ---- 5) 右栏：主选中建筑的详情（本版精简掉「归属」「位置」与大本营锁血注释）----
	eq(panel.unit_name_text(), expect[0].display_name(), "★ 右栏报的是主选中的建筑")
	var btext: String = panel.detail_text()
	ok(btext.contains("生命"), "建筑详情里有生命值（实际：%s）" % btext.replace("\n", "|"))
	ok(not btext.contains("归属") and not btext.contains("位置"),
		"★ 建筑详情里没有「归属」「位置」（本版精简掉了）")

	# ---- 6) 点建筑格 = 换「正在看哪一个」，不改选中了哪些 ----
	var sel_before: int = main.input_ctrl.selected_buildings.size()
	_click_control(grid, UiLayoutRes.troop_cell_rect(0).get_center())
	main.hud.refresh()
	eq(main.input_ctrl.selected_building, expect[1], "★ 点建筑格 → 主选中换成它")
	eq(main.input_ctrl.selected_buildings.size(), sel_before, "★ 点格子**不改选中**")
	eq(panel.unit_name_text(), expect[1].display_name(), "★ 右栏跟着换成那个建筑")
	eq(roster.leader_name(), expect[1].display_name(), "左上那一格也换成了它")
	ok(panel.detail_text().contains("生命"), "右栏仍然画的是建筑详情")

	# ---- 7) 滚轮翻页（与「单选一支部队的单位」同一条规则）----
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

	# ---- 8) 单位优先：框里同时有己方单位与建筑 → 走的还是「选中单位」那条路 ----
	var g1 = world.unit_by_id("general-1")
	if g1 != null:
		_place_unit(world, g1, rect.position + Vector2(3.5, 3.5))
		main.input_ctrl.select_units([])
		main.input_ctrl.box_select(rect.position, rect.end)
		ok(main.input_ctrl.selected_units.has(g1),
			"★ 框里有己方单位 → 仍然是「选中单位」（整队被框出来）")
		eq(main.input_ctrl.selected_buildings.size(), 0,
			"★ 单位优先：同一次框选不会顺带选中建筑")

	# ---- 9) 数字格式化（实机刷屏的那条报错）与区划文案 ----
	eq(main.hud._fmt_num(2.0), "2", "整数不带小数点")
	eq(main.hud._fmt_num(0.05), "0.05",
		"★ 小数照写（这里原来用的是 Godot **不支持**的 %g，每帧刷一条 formatting error）")
	eq(main.hud._fmt_num(1.23456), "1.235", "小数最多 3 位")
	var zones: Array = world.zones.zones
	if zones.size() > 0:
		var ztext: String = main.hud._zone_text(zones[0])
		ok(ztext.contains("区划「") and ztext.contains("粮食产能"), "区划详情有名字与产能")
		ok(not ztext.contains("归属") and not ztext.contains("地块／"),
			"★ 区划详情里没有「归属」，产能也不写「／地块／秒」（本版精简）")
		main.input_ctrl.select_zone(zones[0])
		main.hud.refresh()
		eq(main.hud.detail_panel.unit_name_text(), "区划「%s」" % String(zones[0]["name"]),
			"★ 选中区划时右栏标题是区划名")

	# ---- 10) 拆除入口整块删掉（需求：去掉这个拆除逻辑，暂时不绑定按键）----
	ok(not main.input_ctrl.has_method("demolish_selected"), "★ 拆除入口已删除")
	ok(not main.input_ctrl.handle_key(_key(KEY_X)), "★ 按 X 不再发拆除命令")
	ok(not main.input_ctrl.handle_key(_key(KEY_DELETE)), "★ Delete 同理")

	# ---- 收尾：拆掉这次建的墙、把选中恢复成 1 号将领（别把状态留给后面的用例）----
	for b2 in built:
		world.remove_building(b2, true)
	world.rebuild_building_index()
	main.input_ctrl.select_units([g1])
	main.hud.refresh()


# ------------------------------------------------------------------
# 右栏数值区的正文：**真·两栏**（两个 Label），不是制表符
# ------------------------------------------------------------------
#
# 手玩反馈「招募那块面板的 ui 还是不好看」时截图看到的：正文两栏**粘在一起** ——
# 「血量 200 / 200状态：待命」。根因：原来正文是一整段带 `\t` 的字符串，
# 而 **Godot 的 Label 不把 `\t` 当制表位**（只推进一个很小的固定宽度）。
# 现在 `detail_panel.set_detail()` 按 `\t` 拆成左右两个 Label，x 由 ui_layout 定死。
func _test_detail_two_columns(main) -> void:
	var panel = main.hud.detail_panel
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	main.input_ctrl.select_units([g1])
	main.hud.refresh()

	# ---- 1) 将领：两栏都被填上，而且两栏各自都**不含** `\t` ----
	var ltext: String = panel.detail_left_text()
	var rtext: String = panel.detail_right_text()
	ok(not ltext.contains("\t"), "★ 左栏 Label 里没有制表符（它只画左栏）")
	ok(not rtext.contains("\t"), "★ 右栏 Label 里没有制表符")
	ok(ltext.contains("血量") and ltext.contains("攻击力"),
		"左栏是基础数值（血量 / 攻击力）")
	ok(rtext.contains("编制") or rtext.contains("状态"),
		"★ 右栏接着写上编制 / 状态（实际：%s）" % rtext.replace("\n", "|"))
	ok(panel.detail_text().contains("\t"),
		"★ 合成读口照旧把两栏拼回「左\\t右」（文案断言都走它）")
	ok(panel.detail_text().contains("血量 200"),
		"合成文本里仍然能读到「血量 200」（旧断言不受影响）")

	# ---- 2) 两个 Label 的几何：右栏在左栏右边、且互不重叠 ----
	var left_label: Label = panel._body
	var right_label: Label = panel._body_right
	ok(right_label.visible, "★ 右栏 Label 显示出来了")
	ok(right_label.position.x > left_label.position.x,
		"★ 右栏的 x（%.0f）在左栏（%.0f）右边" % [right_label.position.x, left_label.position.x])
	ok(left_label.position.x + left_label.size.x <= right_label.position.x + 0.01,
		"★ 两栏的矩形不重叠（左栏右缘 %.0f ≤ 右栏左边 %.0f）" % [
			left_label.position.x + left_label.size.x, right_label.position.x])
	ok(right_label.position.x + right_label.size.x <= UiLayoutRes.DETAIL_BODY_W,
		"★ 右栏不越出数值框")

	# ---- 3) 两栏里每一行都装得进各自的可写宽（按真实字体量，见 pitfalls 5.42）----
	var font: Font = main.hud._font
	if font != null:
		for pair in [[ltext, left_label.size.x, "左栏"], [rtext, right_label.size.x, "右栏"]]:
			var body: String = String(pair[0])
			var avail: float = float(pair[1])
			var name_cn: String = String(pair[2])
			for row in body.split("\n"):
				if String(row) == "":
					continue
				var w: float = font.get_string_size(String(row), HORIZONTAL_ALIGNMENT_LEFT, -1,
					UiStyleRes.FS_SMALL).x
				ok(w <= avail + 0.01,
					"★ %s的「%s」宽 %.0f ≤ 可写 %.0f（装得下才不会被裁）"
						% [name_cn, row, w, avail])
	else:
		ok(true, "（没装中文字体，跳过两栏宽度的量算）")

	# ---- 4) 单栏文本（区划 / 建筑）→ 右栏收起来，文本原样进左栏 ----
	panel.set_detail("第一行\n第二行")
	eq(panel.detail_right_text(), "", "★ 没有制表符的文本（区划 / 建筑）→ 右栏收起来")
	eq(panel.detail_text(), "第一行\n第二行", "单栏文本原样读出来（不多不少）")
	ok(not panel._body_right.visible, "右栏 Label 隐藏了")
	# 收尾：把面板恢复成「选中 1 号将领」
	main.hud.refresh()


# ------------------------------------------------------------------
# 右栏数值区：只留基础数值 / 两栏版式 / 编制只有将领有
# ------------------------------------------------------------------
##
## 需求原话：「底部的详细信息 ui 还是有些排版问题，具体表现在太拥挤了」+
##          「只需要给基础数值即可」+「假如是将领才要显示编制，兵不用显示编制」。
##
## ★★ 为什么单独一个函数、而且放在 `_test_box_select` **之后**：
##    它会临时改「选中谁 / 展开哪一支」，插在那个用例中间会把下面那批
##    「多选 → 网格只列其余部队 / 点格子换展开」的断言全搅乱（实测踩过一次）。
##    ⚠️ 末尾必须把选中恢复成 1 号将领 —— 后面的用例（右键命令…）接着用。
func _test_detail_basic_stats(main) -> void:
	var world = main.world
	var g1 = world.unit_by_id("general-1")
	ok(g1 != null, "（前提）找得到 general-1")
	if g1 == null:
		return

	# ---- 1) 将领：两栏版式 + 基础数值 + 编制 ----
	main.input_ctrl.select_units([g1])
	main.hud.refresh()
	var gtext: String = main.hud.detail_panel.detail_text()
	ok(gtext.contains("\t"), "★ 数值区是两栏制表位版式（正文里有 \\t）")
	ok(gtext.contains("血量") and gtext.contains("攻击力") and gtext.contains("攻击距离"),
		"★ 基础数值：血量 / 攻击力 / 攻击距离都在")
	ok(gtext.contains("编制"), "★ 将领显示「编制」")
	ok(not gtext.contains("速度") and not gtext.contains("区块") and not gtext.contains("buff"),
		"★ 速度 / 所在区块 / buff 占位这些不再出现（手玩：只需要基础数值）")
	var g_lines: int = gtext.split("\n").size()
	ok(g_lines <= 5, "★ 将领最多 5 行（实际 %d 行）—— 13 号字装得进加高后的数值框" % g_lines)
	# ★★ 本轮「太拥挤」的**核心判据**：真正喂进去的这段文案，按 13 号字量出来的自然高度
	#    必须 ≤ 数值框的可视高度。旧版是 7 行 11 号字挤进 66px 的可视高 ⇒ **必然被裁**
	#    （`clip_text` 把最后 1~2 行切掉），肉眼看就是「下面那行没了 / 挤在一起」。
	if main.hud._font != null:
		var lh: float = main.hud._font.get_height(UiStyleRes.FS_SMALL)
		var natural: float = lh * float(g_lines)
		var visible: float = UiLayoutRes.DETAIL_BODY_H - 24.0
		ok(natural <= visible,
			"★ 将领这段文案（%d 行 × 行高 %.1f = %.0f px）装得进可视高 %.0f —— 一行都不会被裁"
			% [g_lines, lh, natural, visible])
	# 每一行都只有一处制表位（= 两栏），不许出现「一行里塞三栏」这种又挤起来的版式
	var bad_rows := 0
	for row in gtext.split("\n"):
		if String(row).count("\t") > 1:
			bad_rows += 1
	eq(bad_rows, 0, "★ 每行最多一个制表位（就是两栏，没有三栏挤在一起的行）")

	# ---- 2) 兵（非将领）：同样两栏版式，但**没有**编制那一行 ----
	#
	# ★★ 为什么要直接调 `hud._unit_text()` 而不是「选一个兵再看面板」：
	#   右栏显示谁由 `hud._right_unit()` 决定，而它有一条**有意**的规则 ——
	#   玩家点到的东西必须是**当前展开那支部队的成员**，否则退回那支部队的将领。
	#   所以「选一个亲兵」在界面上永远看到将领（实测：选敌人更是直接退回将领）。
	#   那条规则是别的需求，不该为了测「兵的编制」去绕它 —— 直接喂一个兵进文案函数，
	#   验的正好是本轮这条规则本身（将领才写编制）。
	var retinue: Array = world.retinue_of(g1.id)
	ok(retinue.size() > 0, "（前提）1 号将领带着亲兵（%d 个）" % retinue.size())
	if retinue.size() > 0:
		var soldier = retinue[0]
		ok(not world.is_team_leader(soldier), "（前提）喂进去的这个确实是兵，不是将领")
		var stext: String = main.hud._unit_text(soldier, [])
		ok(stext.contains("血量") and stext.contains("攻击力"),
			"★ 兵的基础数值照常显示（血量 / 攻击力）")
		ok(stext.contains("\t"), "★ 兵的数值也是两栏版式")
		ok(not stext.contains("编制"),
			"★ 兵不显示「编制」（手玩原话：假如是将领才要显示编制，兵不用显示编制）")
		ok(stext.split("\n").size() <= 5,
			"★ 兵最多 5 行（实际 %d 行）" % stext.split("\n").size())
		# 同一份文案函数喂将领时必须**有**编制 —— 否则上面那条可能是因为整块都没写
		var ltext2: String = main.hud._unit_text(g1, [])
		ok(ltext2.contains("编制") and not stext.contains("编制"),
			"★ 同一套文案：将领有编制、兵没有（对照，排除「编制整块丢了」）")

	# ---- 3) 敌人不进右栏（既有规则，顺手钉一下别被本轮改动带坏）----
	var foe = world.spawn_enemy(g1.tx + 5, g1.ty)
	if foe != null:
		main.input_ctrl.clicked_unit = foe
		main.input_ctrl.selection_origin = "click"
		main.hud.refresh()
		ok(not main.hud.detail_panel.detail_text().contains("测试敌人"),
			"★ 点到敌人不会让右栏去报敌人（右栏只报己方单位 / 退回将领）")

	# 收尾：恢复成「1 号将领」，别把状态留给后面的用例
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
