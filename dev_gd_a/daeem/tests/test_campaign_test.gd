## test_campaign_test.gd —— ★ **单人战役的占位界面**（主界面 `campaign_test` 按钮 → 进战役）。
##
## 盯的是「不写就会静默错」的那一类：
##   · 主界面上那颗按钮真的在（文案对、在 test **下面**、与它同一列）；
##   · 按它**挂着的那一页**能打开（`view/campaign_test.gd`），再按「返回」能收掉；
##   · 关卡列表列的是**单人关**（合作关在这条路上给不了第二个席位 ⇒ 不许列出来）；
##   · ★★ 阵营列表 = **那一关的 `playable_ids()`**（换关要跟着换，默认选第一个可玩）；
##   · 按「开始」→ 真的用 `World.create_from_level` 进了游戏，而且世界就是**那一关**的
##     （objective / enemies / 席位都对得上）—— 这条是整页存在的唯一理由；
##   · ★ 老路径（地图选择条 → test）一个字没变：`campaign_screen` 不参与。
##
## ⚠️ 语言约定见 tests/test_case.gd（`--script` 下全局 class_name 不可用；只用 preload 常量）。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const CampaignRes = preload("res://logic/campaign.gd")
const ObjectiveRes = preload("res://logic/objective.gd")

const DEMO_ID := "demo"
## 样例战役第一关的 id（见 data/campaigns/demo/campaign.json 的 levels[]）
const SOLO_LEVEL_ID := "01_beachhead"
## 样例战役第二关（**合作关** —— 它不该出现在战役页的关卡列表里）
const COOP_LEVEL_ID := "02_twin_line"


func _initialize() -> void:
	_case_name = "test_campaign_test"
	# ⚠️★ 本文件有 `await`（要等场景树排版、要按一帧画「载入中…」），
	#   所以**不能**用基类的 `run_all()` —— 它是同步调用的：`cases.call()` 只会启动
	#   那个协程、`await` 之后的部分还没跑，它就已经把结果打印掉并 `quit()` 了
	#   （实测症状：只跑出第一个 await 之前的 3 条断言，然后安静退出）。
	#   照 `tests/test_start_flow.gd` 的写法：自己在协程末尾收口 + quit。
	_run()


func _run() -> void:
	# 等一帧：`_initialize()` 阶段场景树还没就绪（add_child 会静默失效）
	await process_frame

	var cfg = require_config()
	if cfg != null:
		if _assert_demo_exists():
			await _test_button_on_menu()
			await _test_open_and_back()
			await _test_level_and_faction_lists()
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


## 前提：样例战役必须在（它是这一整页的数据来源）。
## ⚠️ 不在就**直接失败**，不要 skip —— 这条用例的价值全在「样例战役能被界面读出来」上。
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
	# ⚠️ 本文件 extends SceneTree（不是 Node）⇒ 挂节点要用 `root.add_child`，
	#    直接写 `add_child()` 会 Parse Error（"not found in base self"）。
	root.add_child(main)
	await process_frame
	# 主界面那一页：点掉入场页（与 test_start_flow 的走法一致）
	var menu = main.start_screen
	if menu != null:
		await process_frame
		menu.show_page(1)
		await process_frame
	return main


# ------------------------------------------------------------------
# 1) 主界面上那颗按钮
# ------------------------------------------------------------------
func _test_button_on_menu() -> void:
	var main = await _spawn_main()
	if main == null or main.start_screen == null:
		ok(false, "主界面能起来")
		return
	var menu = main.start_screen

	var test_btn: Button = menu.get_node_or_null("StartRoot/MainMenu/MenuColumn/TestButton")
	var camp_btn: Button = menu.campaign_test_button()
	ok(test_btn is Button, "（前提）主界面上有 test 按钮")
	ok(camp_btn is Button, "★ 主界面上有 campaign_test 按钮（战役占位入口）")
	if camp_btn is Button:
		eq(camp_btn.text, "campaign_test", "★ 按钮文案是 campaign_test（用户指定的字）")
		ok(not camp_btn.disabled, "它一开始就是可点的（不依赖选了哪张地图）")
		if test_btn is Button:
			ok(camp_btn.get_global_rect().position.y
					>= (test_btn as Control).get_global_rect().end.y - 1.0,
				"★ 它在 test 按钮**下面**（用户原话「就在 test 下面」）")
			# 与 test 同一个容器：这样它两才是视觉上的一组
			ok(camp_btn.get_parent() == (test_btn as Control).get_parent(),
				"它与 test 按钮住在同一个容器里（同一列的相邻两项）")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 2) 打开 / 返回
# ------------------------------------------------------------------
func _test_open_and_back() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	eq(main.campaign_screen, null, "（前提）一开始没有战役页")

	# ★ 走**真实按钮回调**这条路（不是直接调 main 的私有函数）：
	#   按钮上的 pressed 接线断了的话，这一条会红。
	main.start_screen.campaign_test_button().pressed.emit()
	await process_frame
	var screen = main.campaign_screen
	ok(screen != null, "★ 按了 campaign_test 之后出现了战役页")
	if screen == null:
		main.queue_free()
		return
	eq(String(screen.name), "CampaignTestScreen", "它挂在 main 下的 CampaignTestScreen 上")
	ok(main.get_node_or_null("CampaignTestScreen") == screen, "★ 它确实挂在 main 上（不是野节点）")
	ok(screen.campaign() != null, "★ 页里挂着一份**真的载入出来**的战役（不是选项表）")
	eq(String(screen.campaign().id), DEMO_ID, "载入的就是样例战役 demo")

	# 再按一次不该挂出第二页（幂等）
	main._on_campaign_test_pressed()
	await process_frame
	ok(main.campaign_screen == screen, "★ 连点两下按钮不会挂出第二页（幂等）")

	# 「返回」收掉那一页（走按钮回调）
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


# ------------------------------------------------------------------
# 3) 关卡列表 + 阵营列表
# ------------------------------------------------------------------
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

	# ---- 关卡：只列单人关，顺序 = campaign.json 的 levels[] 顺序 ----
	var campaign = screen.campaign()
	var solo_ids: Array = []
	for lv in campaign.levels:
		if String((lv as RefCounted).mode) == "solo":
			solo_ids.append(String((lv as RefCounted).id))
	eq(screen.level_count(), solo_ids.size(),
		"★ 关卡条数 = 战役里**单人关**的条数（%d）" % solo_ids.size())
	ok(solo_ids.has(SOLO_LEVEL_ID), "（前提）样例战役里有单人关 %s" % SOLO_LEVEL_ID)
	eq(screen.level_text(0), String(campaign.level(SOLO_LEVEL_ID).name),
		"第一项就是那一关的显示名")
	# 关卡按钮真的在树上（不是只存在数据里）
	var level_btn: Button = screen.get_node_or_null(
		"CampaignRoot/CampaignCenter/CampaignColumn/LevelBox/LevelButton0")
	ok(level_btn is Button, "★ 关卡列表在界面上真的建出了按钮")
	if level_btn is Button:
		ok(level_btn.text.contains(String(campaign.level(SOLO_LEVEL_ID).name)),
			"按钮上那行字带着关卡名")
		ok(level_btn.text.contains("单人"), "★ 按钮上标着模式（单人）")
		ok(level_btn.text.contains("守住"), "★ 按钮上带着目标一句话（Level.summary()）")

	# ---- 阵营：= 这一关的 playable_ids() ----
	var lv0 = screen.chosen_level()
	ok(lv0 != null, "默认选中了第一关")
	if lv0 != null:
		eq(screen.faction_options(), (lv0 as RefCounted).playable_ids(),
			"★ 阵营列表 = 这一关的 playable_ids()（同一份来源，界面不自己编）")
		ok(screen.faction_count() >= 1, "至少有一个可玩阵营（%d 个）" % screen.faction_count())
		eq(screen.selected_faction(), 0, "★ 默认选中第一个可玩阵营（一进来就能按开始）")
		eq(screen.chosen_faction(), String((lv0 as RefCounted).playable_ids()[0]),
			"取出来的就是第一个可玩阵营的 id")
	eq(screen.level_count() >= 1 and screen.faction_count() >= 1, true,
		"（前提）这一页有得选，下面的断言才有意义")
	ok(screen.can_start(), "★ 选好了关卡与阵营 → 可以开始")
	ok(not screen.start_button().disabled, "「开始」按钮不是禁用的")

	# ---- 换一关：阵营列表跟着重建 ----
	# 样例战役只有一个单人关，所以这里改**直接换阵营**来验「选中状态会跟着走」
	if screen.faction_count() >= 1:
		screen.select_faction(0)
		eq(screen.selected_faction(), 0, "选阵营之后下标跟着变")
	# 越界的选择要被忽略（不许把下标弄成 -1 或越界）
	screen.select_level(99)
	eq(screen.selected_level(), 0, "★ 越界的关卡下标被忽略（不会把选中弄没）")
	screen.select_faction(99)
	eq(screen.selected_faction(), 0, "★ 越界的阵营下标被忽略")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 4) ★★ 按「开始」真的进了**那一关**
# ------------------------------------------------------------------
func _test_start_enters_the_level() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	# 先记下这一关应该长什么样（从**同一份数据**算出来，不写死数字）
	var campaign = CampaignRes.load_campaign("res://data/campaigns/%s" % DEMO_ID)
	var level = campaign.level(SOLO_LEVEL_ID)

	main._on_campaign_test_pressed()
	await process_frame
	var screen = main.campaign_screen
	if screen == null:
		ok(false, "战役页能打开")
		main.queue_free()
		return

	eq(main.game, null, "（前提）按开始之前没有游戏场景")
	# ★ 走按钮回调（与玩家点一下「开始」同一条路）
	screen.select_level(0)
	screen.select_faction(0)
	var want_faction = screen.chosen_faction()
	screen.start_button().pressed.emit()
	# ⚠️ 「开始」里有一个 `await process_frame`（先画「载入中…」那一帧，见那份文件的注释），
	#    所以要等两帧：一帧给 await，一帧给场景装配。
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★ 按「开始」之后出现了游戏内场景")
	if game == null:
		main.queue_free()
		return

	# ★★ 世界就是**这一关**的（这是整页存在的唯一理由）
	ok(game.world != null, "进游戏后才建出 world")
	# ⚠️ 比 **id** 而不是比对象：`CampaignRes.load_campaign()` 每次都新建一份
	#    `Level`（地图 / 配置各自一份），而 GDScript 的 `==` 对 RefCounted 比的是**引用**
	#    —— 拿本文件自己载入的那一份去比 `game.level_playing` 会**假红**。
	ok(game.level_playing != null, "★ 记下了「这一局是从关卡开的」")
	if game.level_playing != null:
		eq(String(game.level_playing.id), SOLO_LEVEL_ID,
			"★ 这一局从**选中的那一关**开的（game.level_playing）")
		eq(int(game.level_playing.objective_zone()), int(level.objective_zone()),
			"而且就是界面上那一关（目标区划对得上）")
	ok(game.level_campaign != null, "★ 也记下了是哪个战役")
	if game.level_campaign != null:
		eq(String(game.level_campaign.id), DEMO_ID, "战役 id 就是 demo")
	eq(String(game.world.level.id), SOLO_LEVEL_ID, "★ world 挂的关卡就是它")
	eq(game.world.my_faction, want_faction, "★ 本机席位 = 界面上选的那一方")
	eq(game.world.player_factions, [want_faction], "★ 单人关的席位就一个（关卡 players[] 说了算）")
	# 目标：与关卡数据一致（不是「没有目标」的空状态）
	var st: Dictionary = game.world.objective_state
	eq(String(st["kind"]), "hold_zone", "★ 战役路径进游戏时**目标已经在位**（HUD 第一帧就读得到）")
	eq(int(st["zone"]), int(level.objective_zone()), "目标区划就是关卡里写的那个")
	near(float(st["sec"]), float(level.objective_hold_sec()), 0.001, "守住秒数也一致")
	eq(String(st["state"]), ObjectiveRes.STATE_RUNNING, "开局是 running（样例数据是合法的）")
	# 开幕挑选中的那个单位在（`selected_units` 是 input_controller 上的**数组字段**）
	ok(game.input_ctrl != null, "输入控制器建出来了")
	if game.input_ctrl != null:
		ok(not (game.input_ctrl.selected_units as Array).is_empty(),
			"★ 开局就选中了一个单位（与老路径同一条收尾）")

	# ★ 战役页在进游戏时被收掉了（不留一层白底压在上面）
	ok(main.campaign_screen == null, "★ 进游戏之后战役页收掉了")
	ok(not main.start_screen.visible, "开场页整层下线了（白底与点击处理器一起停）")

	# ---- 收尾：返回主菜单这条老路仍然通 ----
	main.return_to_menu()
	await process_frame
	ok(main.game == null, "★ 返回主菜单拆掉了游戏场景")
	ok(main.start_screen.visible, "回到主界面（开场页又被显示出来了）")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 5) 合作关不出现在这一页（这条路上给不了第二个席位）
# ------------------------------------------------------------------
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


# ------------------------------------------------------------------
# 6) 老路径一个字没变
# ------------------------------------------------------------------
func _test_old_path_untouched() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	# 按「地图选择条 → test」那条老路：战役页**不该**被牵进来
	main._on_test_pressed(main.start_screen.selected_map_path())
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


## 小工具：`game.level_playing` 是不是 null（写成函数只是因为断言里读三层属性太长）。
func game_level_is_null(game) -> bool:
	return game.level_playing == null
