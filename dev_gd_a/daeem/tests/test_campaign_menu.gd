## test_campaign_menu.gd —— ★ 战役菜单（样式移植自 nsoc 的 CampaignPanel）与两条入口。
##
## 覆盖：
##   1. 数据源 `data/campaigns_menu.json`（战役#2/3 占位、c1 只有 main_test）；
##   2. 「战役」面板里的版式（左 1/4 轮播 / 顶部关卡圆点 / 右侧描述 / 底部提示）；
##   3. 轮播翻战役 → 关卡圆点与描述跟着换；
##   4. 占位关卡「长按没有任何逻辑」（activate_chapter 返回 false、不进游戏）；
##   5. main_test 长按 → 用第一个可玩阵营（F1）进游戏；
##   6. 回主菜单之后面板已经收回（不残留撑开态）。
extends "res://tests/test_case.gd"

const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

const MAIN_CAMPAIGN_KEY := "c1"
const MAIN_CHAPTER_NAME := "main_test"
const MAIN_CAMPAIGN_ID := "demo"
const MAIN_LEVEL_ID := "mt"

var _menu_data: Array = []

func _initialize() -> void:
	_case_name = "test_campaign_menu"
	_run()

func _run() -> void:
	await process_frame
	var cfg = require_config()
	if cfg != null:
		_menu_data = CampaignMenuDbRes.load_campaigns()
		_test_data()
		_test_test_entries(cfg)
		await _test_panel_layout()
		await _test_carousel_switches_chapters()
		await _test_placeholder_is_inert()
		await _test_main_test_enters_game()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_main():
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	var menu = main.start_screen
	if menu != null:
		await process_frame
		menu.show_page(1)
		await process_frame
	return main


# ------------------------------------------------------------------
# 1. 数据源
# ------------------------------------------------------------------

func _test_data() -> void:
	eq(_menu_data.size(), 3, "★ 菜单数据里有三个战役（c1 + 战役#2/3）")
	if _menu_data.is_empty():
		return
	eq(String((_menu_data[0] as Dictionary)["name"]), "测试战役", "第一个是真战役 c1")
	eq(String((_menu_data[0] as Dictionary)["key"]), MAIN_CAMPAIGN_KEY, "它的 key 是 c1")
	var ch1: Array = (_menu_data[0] as Dictionary)["chapters"]
	eq(ch1.size(), 1, "★ c1 里只有一关（用户要求：只加 main_test）")
	if not ch1.is_empty():
		eq(String((ch1[0] as Dictionary)["name"]), MAIN_CHAPTER_NAME,
			"★ 那一关的名字就是 main_test")
		eq(String((ch1[0] as Dictionary)["campaign_id"]), MAIN_CAMPAIGN_ID,
			"它指向 demo 战役")
		eq(String((ch1[0] as Dictionary)["level_id"]), MAIN_LEVEL_ID, "关卡 id 是 mt")
		ok(not CampaignMenuDbRes.is_placeholder_chapter(ch1[0]),
			"它不是占位关（两个 id 都填了）")

	eq(String((_menu_data[1] as Dictionary)["name"]), "战役#2", "第二个是占位战役#2")
	eq(String((_menu_data[2] as Dictionary)["name"]), "战役#3", "第三个是占位战役#3")
	eq(((_menu_data[1] as Dictionary)["chapters"] as Array).size(), 4,
		"战役#2 有 4 个占位关")
	eq(((_menu_data[2] as Dictionary)["chapters"] as Array).size(), 5,
		"战役#3 有 5 个占位关")
	var ch2: Dictionary = ((_menu_data[1] as Dictionary)["chapters"] as Array)[0]
	eq(String(ch2["name"]), "关卡#1", "占位关叫「关卡#1」")
	ok(CampaignMenuDbRes.is_placeholder_chapter(ch2), "★ 占位关被认出来（没有真关卡）")

	# 数据文件缺失 / 写坏 → 兜底非空（界面不该空白）。
	var fallback: Array = CampaignMenuDbRes.load_campaigns("res://data/__missing__.json")
	ok(not fallback.is_empty(), "★ 数据文件读不到时也有兜底项（面板不会一片空白）")
	eq(fallback.size(), 1, "兜底只有一个战役")


## 主界面正中那三颗 test_1/2/3 配的关卡**真的能载入**（它们不在菜单数据里，在 config 里）。
func _test_test_entries(cfg) -> void:
	var raw: Variant = cfg.get_path_value("menu.test_entries")
	ok(typeof(raw) == TYPE_ARRAY, "config 里有 menu.test_entries（三颗 test 按钮的数据）")
	if typeof(raw) != TYPE_ARRAY:
		return
	var entries: Array = raw
	eq(entries.size(), 3, "★ 三颗按钮 = 三条数据")
	var campaigns: Array = CampaignLibraryRes.list_campaigns(cfg)
	for item in entries:
		var d: Dictionary = item
		var label := String(d.get("label", ""))
		var cid := String(d.get("campaign", ""))
		var lid := String(d.get("level", ""))
		ok(label.begins_with("test_"), "按钮文案以 test_ 开头（%s）" % label)
		var option: Dictionary = {}
		for c in campaigns:
			if String((c as Dictionary).get("id", "")) == cid:
				option = c
		ok(not option.is_empty(), "战役 %s 能被扫出来（%s 指向它）" % [cid, label])
		if option.is_empty():
			continue
		var camp = CampaignLibraryRes.load_campaign_by_option(option, cfg)
		ok(camp != null, "战役 %s 能载入" % cid)
		if camp == null:
			continue
		var lv = camp.level(lid)
		ok(lv != null, "★ 关卡 %s / %s 真的存在（否则按下去只会警告、不进游戏）" % [cid, lid])
		if lv != null:
			ok(not lv.playable_ids().is_empty(), "它有可玩阵营（默认会取第一个）")


# ------------------------------------------------------------------
# 2. 版式
# ------------------------------------------------------------------

func _test_panel_layout() -> void:
	var main = await _spawn_main()
	if main == null or main.start_screen == null:
		ok(false, "主界面能起来")
		return
	var menu = main.start_screen
	var cm = await open_campaign_panel(menu)
	ok(cm != null, "★★ 「战役」面板里有战役菜单（view/campaign_menu.gd）")
	if cm == null:
		main.queue_free()
		return

	eq(cm.campaign_count(), 3, "菜单里铺了三个战役")
	eq(cm.carousel().page_name(1), "测试战役", "轮播中间那张 = 当前战役")
	eq(cm.carousel().page_name(0), "战役#3", "上面那张 = 循环到的上一个战役（战役#3）")
	eq(cm.carousel().page_name(2), "战役#2", "下面那张 = 下一个战役（战役#2）")

	eq(cm.chapter_count(), 1, "★ 当前战役只有一关（main_test）")
	eq(cm.chapter_dot_count(), 1, "顶部关卡圆点数 = 关卡数")
	eq(cm.desc_title_text(), "main_test", "★ 描述面板标题 = 当前关卡名")
	ok(cm.desc_body_text().contains("main_test"), "★ 描述正文来自数据（写的是 main_test）")
	eq(cm.footer_text(), cfg_str(menu, "menu.campaign_menu.footer", ""),
		"★ 底部那行提示来自 config（长按进入关卡）")

	var campaign_pnl: Control = cm.get_node("CampaignPnl")
	var chapter_pnl: Control = cm.get_node("ChapterPnl")
	var desc_pnl: Control = cm.get_node("DescPnl")
	ok(campaign_pnl != null and chapter_pnl != null and desc_pnl != null,
		"三块面板都在（左侧轮播 / 顶部关卡条 / 右侧描述）")
	if campaign_pnl != null and chapter_pnl != null and desc_pnl != null:
		var left_w: float = campaign_pnl.get_global_rect().size.x
		var right_w: float = chapter_pnl.get_global_rect().size.x
		ok(left_w > 1.0 and left_w < right_w * 0.5,
			"★ 左侧轮播占左边约 1/4（%.0f px）" % left_w)
		ok(chapter_pnl.get_global_rect().end.y <= desc_pnl.get_global_rect().position.y + 1.0,
			"★ 关卡圆点那一条在描述面板**上方**")
		ok(desc_pnl.get_global_rect().size.x > left_w,
			"★ 描述面板占了右侧的大块面积")
		# 面板自带的「返回」不能被内容盖住（内容根是 IGNORE，三块面板的矩形也不与它相交）。
		var back: Button = null
		var p = menu.menu_chrome().expand_engine().secondary_panel()
		if p != null and p.has_method("back_button"):
			back = p.back_button()
		ok(back is Button, "撑开的面板里有「返回」")
		if back is Button:
			var back_rect: Rect2 = (back as Control).get_global_rect()
			ok(not back_rect.intersects(chapter_pnl.get_global_rect()),
				"★ 关卡条不与「返回」重叠（右上角让出来了）")
			ok(cm.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"★ 战役菜单根节点不吃鼠标（否则点「返回」会被它吃掉）")

	# 样式：卡片 / 面板是暗底金线（不是 nsoc 的白卡片）。
	var card_sb: StyleBox = null
	var track: Node = cm.carousel().get_child(0)
	if track != null and track.get_child_count() > 0:
		var page: Node = track.get_child(0)
		if page is Control:
			card_sb = (page as Control).get_theme_stylebox("panel")
	ok(card_sb is StyleBoxFlat, "轮播卡片有 StyleBoxFlat 底纹")
	if card_sb is StyleBoxFlat:
		var cs := card_sb as StyleBoxFlat
		ok(cs.bg_color.get_luminance() < 0.35,
			"★ 卡片是**暗底**（移植的是版式，配色留在本作暗金皮肤）")
		ok(cs.border_color.r > cs.border_color.b, "★ 卡片边框是金色（R > B）")
	ok(ThemeRes.bg_top().get_luminance() < 0.35, "主题底色仍然是暗的")
	ok(MenuThemeRes.campaign_dot(true).bg_color != MenuThemeRes.campaign_dot(false).bg_color,
		"★ 选中 / 未选中的关卡圆点是两种颜色")

	ok(cm.long_press_duration() >= 1.0, "★ 长按进关需要按住 ≥1 秒（不会一点就进）")
	var dots: Array = (cm.get_node("ChapterPnl").get_node("ChapterBox") as Control).get_children()
	ok(dots.size() == 1, "圆点容器里确实建出了 1 个点")

	main.queue_free()
	await process_frame


func cfg_str(menu, path: String, fallback: String) -> String:
	if menu == null or menu.cfg == null:
		return fallback
	return menu.cfg.str_val(path, fallback)


# ------------------------------------------------------------------
# 3. 轮播翻页 → 圆点 / 描述跟着换
# ------------------------------------------------------------------

func _test_carousel_switches_chapters() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var cm = await open_campaign_panel(main.start_screen)
	if cm == null:
		ok(false, "战役菜单能打开")
		main.queue_free()
		return

	cm.carousel().select_campaign(1)
	eq(cm.current_campaign_name(), "战役#2", "★ 切到战役#2")
	eq(cm.chapter_count(), 4, "★ 关卡数跟着换成 4")
	eq(cm.chapter_dot_count(), 4, "★ 顶部圆点也换成 4 个")
	eq(cm.desc_title_text(), "关卡#1", "描述标题换成战役#2 的第一关")
	ok(cm.is_current_placeholder(), "★ 战役#2 的第一关是占位关")

	cm.carousel().select_campaign(2)
	eq(cm.current_campaign_name(), "战役#3", "切到战役#3")
	eq(cm.chapter_dot_count(), 5, "战役#3 有 5 个圆点")
	eq(cm.desc_title_text(), "关卡#1", "仍然是第一关")

	cm.select_chapter(3)
	eq(cm.current_chapter_index(), 3, "选第 4 关")
	eq(cm.desc_title_text(), "关卡#4", "描述标题跟着换")
	cm.select_chapter(99)
	eq(cm.current_chapter_index(), 3, "★ 越界的关卡下标被忽略")

	cm.carousel().select_campaign(0)
	eq(cm.current_campaign_name(), "测试战役", "切回 c1")
	eq(cm.chapter_count(), 1, "c1 只有一关")
	eq(cm.current_chapter_index(), 0, "★ 切战役之后关卡索引复位到 0")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 4. 占位关：长按没有任何逻辑
# ------------------------------------------------------------------

func _test_placeholder_is_inert() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var cm = await open_campaign_panel(main.start_screen)
	if cm == null:
		main.queue_free()
		return

	cm.carousel().select_campaign(1)
	ok(cm.is_current_placeholder(), "（前提）当前是占位关")
	var emitted: Array = []
	cm.chapter_activated.connect(func(cid: String, lid: String): emitted.append([cid, lid]))
	var activated: bool = cm.activate_chapter(0)
	eq(activated, false, "★ 占位关 activate_chapter 返回 false（没有可进入的关卡）")
	eq(emitted.size(), 0, "★ 而且不发 chapter_activated 信号")
	# ★ 走一遍**长按**那条路：进度走满之后同样什么都不该发生（不发信号 / 不进游戏）。
	cm._start_long_press(Vector2(120.0, 120.0))
	cm._process(cm.long_press_duration() + 0.2)
	eq(emitted.size(), 0, "★★ 占位关长按走满之后也不发信号")
	await process_frame
	eq(main.game, null, "★★ 占位关不会进游戏（用户要求：触发进入逻辑后没有任何逻辑）")
	ok(main.start_screen.visible, "主界面还在（没有被丢进空场景）")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 5. main_test 长按 → 用第一个可玩阵营进游戏
# ------------------------------------------------------------------

func _test_main_test_enters_game() -> void:
	var campaign = CampaignRes.load_campaign("res://data/campaigns/%s" % MAIN_CAMPAIGN_ID)
	var level = campaign.level(MAIN_LEVEL_ID) if campaign != null else null
	ok(campaign != null and level != null,
		"（前提）%s / %s 能载入" % [MAIN_CAMPAIGN_ID, MAIN_LEVEL_ID])
	if campaign == null or level == null:
		return
	var want_faction := String(level.playable_ids()[0])

	var main = await _spawn_main()
	if main == null:
		return
	eq(main.game, null, "（前提）进游戏之前没有游戏场景")

	var cm = await open_campaign_panel(main.start_screen)
	if cm == null:
		ok(false, "战役菜单能打开")
		main.queue_free()
		return
	ok(not cm.is_current_placeholder(), "（前提）c1 的第一关是真关卡")

	# ★★ 走**真实的长按那条路**（不是直接调 activate_chapter）：按住不动，
	#    进度走满 → 发 chapter_activated → main 载入那一关。
	cm._start_long_press(Vector2(160.0, 160.0))
	cm._process(cm.long_press_duration() + 0.2)
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★★ 长按 main_test 之后出现了游戏内场景")
	if game == null:
		main.queue_free()
		return
	ok(game.level_playing != null, "★ 记下了「这一局从关卡开的」")
	if game.level_playing != null:
		eq(String(game.level_playing.id), MAIN_LEVEL_ID, "★ 用的就是 main_test 指向的那一关（mt）")
	ok(game.level_campaign != null, "★ 也记下了是哪份战役")
	if game.level_campaign != null:
		eq(String(game.level_campaign.id), MAIN_CAMPAIGN_ID, "战役就是 demo")
	eq(String(game.world.level.id), MAIN_LEVEL_ID, "★ world 挂的关卡就是它")
	eq(game.world.my_faction, want_faction,
		"★★ 阵营 = 第一个可玩阵营（%s；nsoc 样式里没有选阵营这一步）" % want_faction)
	ok(not main.start_screen.visible, "开场页整层下线了")

	# 回主菜单：面板必须已经收回（不能还停在撑开态）。
	main.return_to_menu()
	await process_frame
	eq(main.game, null, "★ 返回主菜单拆掉了游戏场景")
	ok(main.start_screen.visible, "主界面又显示出来了")
	var engine = main.start_screen.menu_chrome().expand_engine()
	ok(not engine.is_expanded(), "★★ 回主菜单之后战役面板已经收回（不会残留撑开态）")
	eq(main.start_screen.campaign_menu(), null, "面板内容也跟着销毁了")

	main.queue_free()
	await process_frame
