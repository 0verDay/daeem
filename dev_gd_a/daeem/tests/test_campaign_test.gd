## test_campaign_test.gd —— ★ **单人战役的占位界面**（主界面 `campaign_test` 按钮 → 进战役）。
extends "res://tests/test_case.gd"
## ★ 这些用例只需要「一张能开局的图」：地图选择条已经搬进「战役」面板（见
##   view/battle_entries.gd），所以直接问逻辑层要默认地图（与面板默认选中的是同一张）。
const MapLibraryRes = preload("res://logic/map_library.gd")

const MainScene := preload("res://view/main.tscn")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")

const DEMO_ID := "demo"
const SOLO_LEVEL_ID := "01_beachhead"
const COOP_LEVEL_ID := "02_twin_line"
const OTHER_CAMPAIGN_ID := "ferry"

var _campaigns_now: Array = []
var _default_id: String = ""

func _initialize() -> void:
	_case_name = "test_campaign_test"
	_run()

func _run() -> void:
	await process_frame

	var cfg = require_config()
	if cfg != null:
		_campaigns_now = CampaignLibraryRes.list_campaigns(cfg)
		_default_id = String((_campaigns_now[0] as Dictionary)["id"]) \
			if not _campaigns_now.is_empty() else ""
		if _assert_demo_exists():
			await _test_button_on_menu()
			await _test_open_and_back()
			await _test_level_and_faction_lists()
			await _test_campaign_selector()
			await _test_start_enters_the_level()
			await _test_coop_level_hidden()
			await _test_old_path_untouched()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _assert_demo_exists() -> bool:
	var c = CampaignRes.load_campaign("res://data/campaigns/%s" % DEMO_ID)
	var ok_now := c != null
	ok(ok_now, "（前提）样例战役 demo 能被载入（这一页的数据来源）")
	return ok_now

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

func _test_button_on_menu() -> void:
	var main = await _spawn_main()
	if main == null or main.start_screen == null:
		ok(false, "主界面能起来")
		return
	var menu = main.start_screen

	# ★★ 这两个入口现在住在**「战役」按钮撑开的那块面板**里（见 view/battle_entries.gd），
	#    它们已经从主界面正中那一列搬走了 —— 先把面板撑开再找它们。
	var entries = await open_battle_panel(menu)
	ok(entries != null, "（前提）「战役」面板里有测试入口")
	if entries == null:
		main.queue_free()
		return

	var test_btn: Button = entries.test_button()
	var camp_btn: Button = entries.campaign_test_button()
	ok(test_btn is Button, "（前提）面板里有 test 按钮")
	ok(camp_btn is Button, "★ 面板里有 campaign_test 按钮（战役占位入口）")
	if camp_btn is Button:
		eq(camp_btn.text, "campaign_test", "★ 按钮文案是 campaign_test（用户指定的字）")
		ok(not camp_btn.disabled, "它一开始就是可点的（不依赖选了哪张地图）")
		if test_btn is Button:
			ok(camp_btn.get_global_rect().position.y
					>= (test_btn as Control).get_global_rect().end.y - 1.0,
				"★ 它在 test 按钮**下面**（用户原话「就在 test 下面」）")
			ok(camp_btn.get_parent() == (test_btn as Control).get_parent(),
				"它与 test 按钮住在同一个容器里（同一个 VBox 的相邻两项）")

	main.queue_free()
	await process_frame

func _test_open_and_back() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	eq(main.campaign_screen, null, "（前提）一开始没有战役页")

	# ★★ campaign_test 按钮现在住在**「战役」按钮撑开的那块面板**里（view/battle_entries.gd）——
	#   先把面板撑开，再按它（它照样打开战役占位页）。
	var entries = await open_battle_panel(main.start_screen)
	ok(entries != null and entries.campaign_test_button() is Button,
		"（前提）「战役」面板里有 campaign_test 按钮")
	if entries != null:
		entries.campaign_test_button().pressed.emit()
	await process_frame
	var screen = main.campaign_screen
	ok(screen != null, "★ 按了 campaign_test 之后出现了战役页")
	if screen == null:
		main.queue_free()
		return
	eq(String(screen.name), "CampaignTestScreen", "它挂在 main 下的 CampaignTestScreen 上")
	ok(main.get_node_or_null("CampaignTestScreen") == screen, "★ 它确实挂在 main 上（不是野节点）")
	ok(screen.campaign() != null, "★ 页里挂着一份**真的载入出来**的战役（不是选项表）")
	eq(String(screen.campaign().id), _default_id, "载入的就是扫出来的第一个战役（%s）" % _default_id)
	eq(screen.selected_campaign(), 0, "★ 选择条也停在第一项上（与载入的那个一致）")

	main._on_campaign_test_pressed()
	await process_frame
	ok(main.campaign_screen == screen, "★ 连点两下按钮不会挂出第二页（幂等）")

	var back: Button = screen.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn/BackButton")
	ok(back is Button, "战役页上有一颗「返回」")
	if back is Button:
		back.pressed.emit()
		await process_frame
		ok(main.campaign_screen == null, "★ 点「返回」之后战役页被收掉了")
		ok(main.start_screen != null and main.start_screen.visible,
			"主界面还在（返回之后不会被丢在空白页上）")

	main.queue_free()
	await process_frame

func _test_level_and_faction_lists() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	main._on_campaign_test_pressed()
	await process_frame
	var screen = main.campaign_screen
	if screen == null:
		ok(false, "战役页能打开")
		main.queue_free()
		return

	var campaign = screen.campaign()
	var solo_ids: Array = []
	for lv in campaign.levels:
		if String((lv as RefCounted).mode) == "solo":
			solo_ids.append(String((lv as RefCounted).id))
	eq(screen.level_count(), solo_ids.size(),
		"★ 关卡条数 = 战役里**单人关**的条数（%d）" % solo_ids.size())
	ok(not solo_ids.is_empty(), "（前提）默认战役里有单人关（这一页才有得测）")
	if solo_ids.is_empty():
		main.queue_free()
		return
	var lv0_id := String(solo_ids[0])
	var lv0_data = campaign.level(lv0_id)
	var level_btn: Button = screen.get_node_or_null(
		"CampaignRoot/CampaignCenter/CampaignColumn/LevelBox/LevelButton0")
	ok(level_btn is Button, "★ 关卡列表在界面上真的建出了按钮")
	if level_btn is Button:
		ok(level_btn.text.contains(String(lv0_data.name)), "第一项就是那一关的显示名")
		ok(level_btn.text.contains("单人"), "★ 按钮上标着模式（单人）")
		ok(level_btn.text.contains(String(lv0_data.objective_label()).substr(0, 1)),
			"★ 按钮上带着目标一句话（Level.summary()）")

	var lv0 = screen.chosen_level()
	ok(lv0 != null, "默认选中了第一关")
	if lv0 != null:
		eq(screen.faction_options(), (lv0 as RefCounted).playable_ids(),
			"★ 阵营列表 = 这一关的 playable_ids()（同一份来源，界面不自己编）")
		ok(screen.faction_count() >= 1, "至少有一个可玩阵营（%d 个）" % screen.faction_count())
		eq(screen.selected_faction(), 0, "★ 默认选中第一个可玩阵营（一进来就能按开始）")
		eq(screen.chosen_faction(), String((lv0 as RefCounted).playable_ids()[0]),
			"取出来的就是第一个可玩阵营的 id")
		eq(screen.faction_text(0), (lv0 as RefCounted).faction_name("F1"),
			"★ 阵营按钮显示数据里的名字（第 1 个 = 蓝方）")
		ok(screen.faction_text(0) != "F1",
			"★ 显示的是名字不是 id（实际「%s」）" % screen.faction_text(0))
		if screen.faction_count() >= 2:
			eq(screen.faction_text(1), (lv0 as RefCounted).faction_name("F2"),
				"★ 第 2 个按钮 = 红方")
			ok(screen.faction_text(1) != "F2", "★ 第 2 个也不是 id")

	var camp_bg = screen.get_node_or_null("CampaignRoot/Background")
	ok(camp_bg is Control, "战役页的背景那一层在")
	ok(camp_bg != null and camp_bg.get("_gradient") is GradientTexture2D,
		"★ 它用的是**渐变暗底**（与入场页同一个类），不是一块纯色 / 白底")
	var camp_theme := ThemeRes.bg_top()
	ok(camp_theme.get_luminance() < 0.35,
		"★ 主题底色是暗的（亮度 %.2f）" % camp_theme.get_luminance())
	if level_btn is Button:
		var lv_sb: StyleBox = level_btn.get_theme_stylebox("normal")
		ok(lv_sb is StyleBoxFlat, "关卡按钮有一个 StyleBoxFlat 底纹")
		if lv_sb is StyleBoxFlat:
			var is_selected: bool = screen.selected_level() == 0
			var glow := FillButtonRes.animator_of(level_btn)
			ok(glow != null, "★ 关卡按钮挂着「金色填充层」（悬停填金 / 选中常驻满格）")
			if is_selected:
				ok(lv_sb.border_color.r > lv_sb.border_color.b,
					"★ 选中那一关的框是**金色系**（R > B）")
				ok(glow != null and glow.latched(),
					"★ 默认选中的那一关是**锁定态**（金一直亮着，一眼看出选中了哪一关）")
				ok(glow != null and glow.fill() > 0.99,
					"★ 而且填充是**满格**的（那支金 = 实心金的观感）")
				var lv_font: Color = level_btn.get_theme_color("font_color")
				ok(lv_font.get_luminance() < 0.35,
					"★ 实心金底上的字是暗字（L=%.3f；暖白 L=0.89 压金几乎读不出来）"
					% lv_font.get_luminance())
				ok(lv_font.get_luminance() < MenuThemeRes.text_normal().get_luminance() * 0.5,
					"★ 而且比常态的暖白明显更暗（换过字色，不是照旧）")
				ok((level_btn.get_theme_color("font_color") as Color).get_luminance() < 0.35,
					"★ 而且确实够暗（不是暖白）")
			else:
				ok(lv_sb.bg_color.a < 0.3,
					"未选中的关卡是透明底 + 金线")
	eq(screen.level_count() >= 1 and screen.faction_count() >= 1, true,
		"（前提）这一页有得选，下面的断言才有意义")
	ok(screen.can_start(), "★ 选好了关卡与阵营 → 可以开始")
	ok(not screen.start_button().disabled, "「开始」按钮不是禁用的")

	if screen.faction_count() >= 1:
		screen.select_faction(0)
		eq(screen.selected_faction(), 0, "选阵营之后下标跟着变")
	screen.select_level(99)
	eq(screen.selected_level(), 0, "★ 越界的关卡下标被忽略（不会把选中弄没）")
	screen.select_faction(99)
	eq(screen.selected_faction(), 0, "★ 越界的阵营下标被忽略")

	main.queue_free()
	await process_frame

func _test_campaign_selector() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	main._on_campaign_test_pressed()
	await process_frame
	var screen = main.campaign_screen
	if screen == null:
		ok(false, "战役页能打开")
		main.queue_free()
		return

	var want: Array = []
	for o in _campaigns_now:
		want.append(String((o as Dictionary)["name"]))
	eq(screen.campaign_select_item_count(), _campaigns_now.size(),
		"★ 选择条的项数 = 扫出来的战役数（%d）" % _campaigns_now.size())
	for i in _campaigns_now.size():
		eq(screen.campaign_select_item_text(i), String(want[i]),
			"第 %d 项就是那个战役的显示名（%s）" % [i, String(want[i])])
	ok(screen.campaign_select_item_count() >= 2,
		"★ 至少两个战役可选（样例 demo + 新加的 ferry）—— 否则「切换」这条根本没法验")

	var bar: Button = screen.campaign_select_button()
	ok(bar is Button, "★ 选择条在界面上真的建出了按钮")
	if bar is Button:
		eq(String(bar.name), "CampaignSelect", "按钮的名字是 CampaignSelect（与地图那条区分开）")
		eq(bar.text, screen.campaign_select_item_text(screen.selected_campaign()),
			"★ 按钮上那行字 = 当前选中的那一项（map_select 每次选中都会重写它）")
		var sb: StyleBox = bar.get_theme_stylebox("normal")
		ok(sb is StyleBoxFlat, "选择条底纹是 StyleBoxFlat（menu_theme 造的）")
		if sb is StyleBoxFlat:
			var sbf := sb as StyleBoxFlat
			ok(sbf.bg_color.a <= 0.001,
				"★ 常态是**透明底 + 金线**（menu_theme.button_normal 那一档），不是浅色实底")
			eq(sbf.border_color, ThemeRes.line(), "金线用的是主题的 line()")
			ok(sbf.border_width_left >= 1, "有一圈边框（不是光秃秃的字）")
		var sb_hover: StyleBox = bar.get_theme_stylebox("hover")
		if sb_hover is StyleBoxFlat:
			ok((sb_hover as StyleBoxFlat).bg_color.a <= 0.001,
				"★ 悬停底纹是**透明底**（金交给填充层）")
			ok((sb_hover as StyleBoxFlat).border_color.r > (sb_hover as StyleBoxFlat).border_color.b,
				"★ 悬停时线是亮的金（鼠标在哪儿要看得出来）")
		var sb_pressed: StyleBox = bar.get_theme_stylebox("pressed")
		if sb_pressed is StyleBoxFlat:
			eq((sb_pressed as StyleBoxFlat).bg_color, ThemeRes.accent(),
				"★ 按下/选中是**实心金**（menu_theme.button_selected 那一档）")
		eq(bar.get_theme_color("font_color"), MenuThemeRes.text_normal(),
			"字色走 menu_theme（暖白），不是写死的深灰")
		ok(bar.get_child_count() >= 1, "（前提）选择条下面挂着东西（下拉列表 / 填充层）")
		var sel_popup: PopupMenu = null
		for child in bar.get_children():
			if child is PopupMenu:
				sel_popup = child as PopupMenu
				break
		ok(sel_popup != null, "★ 下拉列表挂在按钮下面（同一个部件的做法）")
		var popup_style: StyleBox = null
		if sel_popup != null:
			popup_style = sel_popup.get_theme_stylebox("panel")
		ok(popup_style is StyleBoxFlat, "下拉列表有显式底板（不是引擎默认那套）")
		if popup_style is StyleBoxFlat:
			var ps := popup_style as StyleBoxFlat
			eq(ps.bg_color.a, 1.0, "★ 列表底板是**不透明**的（这一条是实测踩过的坑）")
			ok(ps.bg_color.r <= ps.bg_color.b + 0.05,
				"★ 底是**暗冷色**（与页面底板同源，不是一块纯黑）")
			ok(ps.border_color.r > ps.border_color.b,
				"★ 而且有**金色描边**（与线框按钮同一条线）")
			ok(ps.border_width_left >= 1, "★ 描边宽度 ≥ 1")
		if sel_popup != null:
			var row_hover := sel_popup.get_theme_stylebox("hover")
			ok(row_hover is StyleBoxFlat, "列表行也有显式的悬停底纹")
			if row_hover is StyleBoxFlat:
				ok((row_hover as StyleBoxFlat).bg_color.a > 0.0,
					"★ 悬停那行**有底色**（独立窗口里只靠字色变亮不够）")
				ok((row_hover as StyleBoxFlat).bg_color.r
						> (row_hover as StyleBoxFlat).bg_color.b,
					"★ 而且底色是**金系**（R > B）")
			ok(sel_popup.get_theme_color("font_hover_color")
					!= sel_popup.get_theme_color("font_color"),
				"★ 悬停那行字也更亮（鼠标停在哪一项要看得出来）")

	var rule = screen.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn/TitleRuleWrap")
	var level_box = screen.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn/LevelBox")
	ok(rule is Control and level_box is Control, "（前提）金线与关卡列表都在")
	if bar is Button and rule is Control and level_box is Control:
		ok(bar.get_global_rect().position.y >= (rule as Control).get_global_rect().end.y - 1.0,
			"★ 选择条在标题金线**下面**")
		ok((level_box as Control).get_global_rect().position.y
				>= bar.get_global_rect().end.y - 1.0,
			"★ 选择条在关卡列表**上面**")

	var other := -1
	for i in _campaigns_now.size():
		if String((_campaigns_now[i] as Dictionary)["id"]) == OTHER_CAMPAIGN_ID:
			other = i
	if other < 0:
		ok(true, "（跳过）扫出来的表里没有 %s，换战役那一半这次不验" % OTHER_CAMPAIGN_ID)
		main.queue_free()
		await process_frame
		return

	var popup: PopupMenu = null
	for child in bar.get_children():
		if child is PopupMenu:
			popup = child as PopupMenu
			break
	ok(popup != null, "（前提）选择条下面挂着下拉列表")
	if popup == null:
		main.queue_free()
		return
	popup.id_pressed.emit(other)
	await process_frame
	var want_camp = CampaignRes.load_campaign(
		"res://data/campaigns/%s" % OTHER_CAMPAIGN_ID)
	ok(want_camp != null, "（前提）%s 能被载入" % OTHER_CAMPAIGN_ID)
	if want_camp == null:
		main.queue_free()
		await process_frame
		return
	eq(screen.selected_campaign(), other, "★ 选择条的下标跟着走")
	eq(bar.text, screen.campaign_select_item_text(other), "★ 按钮上那行字换成了新战役")
	ok(screen.campaign() != null, "★ 换完挂着的是一份真的载入出来的战役")
	if screen.campaign() != null:
		eq(String(screen.campaign().id), OTHER_CAMPAIGN_ID, "★ 换的就是那一个战役")
	var want_solo := 0
	for lv in want_camp.levels:
		if String((lv as RefCounted).mode) == "solo":
			want_solo += 1
	eq(screen.level_count(), want_solo, "★ 关卡列表换成了新战役的（%d 关）" % want_solo)
	if screen.level_count() >= 1:
		eq(screen.level_text(0), String((screen.level_options()[0] as RefCounted).name),
			"★ 第一关的名字来自新战役")
		var lv_new = screen.chosen_level()
		if lv_new != null:
			eq(screen.faction_options(), (lv_new as RefCounted).playable_ids(),
				"★ 阵营列表 = 新战役那一关的 playable_ids()")
		ok(screen.can_start(), "★ 换完战役之后「开始」是可用的（不是卡在旧的选中状态上）")

	if popup != null:
		popup.id_pressed.emit(0)
		await process_frame
		eq(screen.selected_campaign(), 0, "★ 换回第 0 项，下标正确")
		eq(String(screen.campaign().id), _default_id, "★ 换回来的就是默认那个战役")
		screen.campaign_select_select(99)
		eq(screen.selected_campaign(), 0, "★ 越界的下标被忽略（不会把选中弄坏）")

	main.queue_free()
	await process_frame

func _test_start_enters_the_level() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var campaign = CampaignRes.load_campaign("res://data/campaigns/%s" % _default_id)
	var level = campaign.level(SOLO_LEVEL_ID)
	ok(campaign != null and level != null,
		"（前提）默认战役 %s 里有单人关 %s" % [_default_id, SOLO_LEVEL_ID])
	if campaign == null or level == null:
		main.queue_free()
		return

	main._on_campaign_test_pressed()
	await process_frame
	var screen = main.campaign_screen
	if screen == null:
		ok(false, "战役页能打开")
		main.queue_free()
		return

	eq(main.game, null, "（前提）按开始之前没有游戏场景")
	screen.select_level(0)
	screen.select_faction(0)
	var want_faction = screen.chosen_faction()
	screen.start_button().pressed.emit()
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★ 按「开始」之后出现了游戏内场景")
	if game == null:
		main.queue_free()
		return

	ok(game.world != null, "进游戏后才建出 world")
	ok(game.level_playing != null, "★ 记下了「这一局是从关卡开的」")
	if game.level_playing != null:
		eq(String(game.level_playing.id), SOLO_LEVEL_ID,
			"★ 这一局从**选中的那一关**开的（game.level_playing）")
		eq(int(game.level_playing.objective_zone()), int(level.objective_zone()),
			"而且就是界面上那一关（目标区划对得上）")
	ok(game.level_campaign != null, "★ 也记下了是哪个战役")
	if game.level_campaign != null:
		eq(String(game.level_campaign.id), _default_id, "战役 id 就是默认那一个")
	eq(String(game.world.level.id), SOLO_LEVEL_ID, "★ world 挂的关卡就是它")
	eq(game.world.my_faction, want_faction, "★ 本机席位 = 界面上选的那一方")
	eq(game.world.player_factions, [want_faction], "★ 单人关的席位就一个（关卡 players[] 说了算）")
	var st: Dictionary = game.world.objective_state
	eq(String(st["kind"]), "hold_zone", "★ 战役路径进游戏时**目标已经在位**（HUD 第一帧就读得到）")
	eq(int(st["zone"]), int(level.objective_zone()), "目标区划就是关卡里写的那个")
	near(float(st["sec"]), float(level.objective_hold_sec()), 0.001, "守住秒数也一致")
	eq(String(st["state"]), ObjectiveRes.STATE_RUNNING, "开局是 running（样例数据是合法的）")
	ok(game.input_ctrl != null, "输入控制器建出来了")
	if game.input_ctrl != null:
		ok((game.input_ctrl.selected_units as Array).is_empty(),
			"★ 开局不选中任何单位（进游戏第一眼是「未选中」）")

	ok(main.campaign_screen == null, "★ 进游戏之后战役页收掉了")
	ok(not main.start_screen.visible, "开场页整层下线了（白底与点击处理器一起停）")

	main.return_to_menu()
	await process_frame
	ok(main.game == null, "★ 返回主菜单拆掉了游戏场景")
	ok(main.start_screen.visible, "回到主界面（开场页又被显示出来了）")

	main.queue_free()
	await process_frame

func _test_coop_level_hidden() -> void:
	var campaign = CampaignRes.load_campaign("res://data/campaigns/%s" % DEMO_ID)
	ok(campaign != null and campaign.level(COOP_LEVEL_ID) != null,
		"（前提）样例战役里有合作关 %s（它才是这条断言的反面样本）" % COOP_LEVEL_ID)

	var main = await _spawn_main()
	if main == null:
		return
	main._on_campaign_test_pressed()
	await process_frame
	var screen = main.campaign_screen
	if screen == null:
		ok(false, "战役页能打开")
		main.queue_free()
		return
	for i in screen.level_count():
		ok(not String((screen.level_options()[i] as RefCounted).id) == COOP_LEVEL_ID,
			"★ 合作关不在这一页的关卡列表里（第 %d 项）" % i)
	main.queue_free()
	await process_frame

func _test_old_path_untouched() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	ok(main.game != null, "★ 老路径（按 test）照样能进游戏")
	ok(main.campaign_screen == null, "★ 老路径不会挂出战役页")
	if main.game != null:
		ok(main.game.world != null, "老路径建出了 world")
		eq(game_level_is_null(main.game), true,
			"★ 老路径上 game.level_playing 是 null（这一局不是从关卡开的）")
		eq(String(main.game.world.objective_state.get("kind", "")), "",
			"★ 老路径上没有目标（空状态 ⇒ 一个玩法行为都不受影响）")
	main.queue_free()
	await process_frame

func game_level_is_null(game) -> bool:
	return game.level_playing == null
