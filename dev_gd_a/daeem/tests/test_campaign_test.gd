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
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
## ★★ 「金色自下而上填充」那一层（本版新增）：关卡 / 阵营行都挂着它。
const FillButtonRes = preload("res://view/fill_button.gd")

const DEMO_ID := "demo"
## 样例战役第一关的 id（见 data/campaigns/demo/campaign.json 的 levels[]）
const SOLO_LEVEL_ID := "01_beachhead"
## 样例战役第二关（**合作关** —— 它不该出现在战役页的关卡列表里）
const COOP_LEVEL_ID := "02_twin_line"
## ★ 第二个战役（本轮新加的那一个：`data/campaigns/ferry/`）。
##   ⚠️ 它**只是本文件选的一个「另一个战役」样本**，不是产品常量：
##      用例会先检查它确实在扫出来的表里，不在就把那一段跳过（说明数据搬走了），
##      而不是让这一页的用例跟着数据一起红。
const OTHER_CAMPAIGN_ID := "ferry"

## 扫出来的战役表（`_run()` 开头填一次）与它的第一项 —— 「默认开哪一个」由它算出来。
var _campaigns_now: Array = []
var _default_id: String = ""


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
		# ★ 先看数据：这一整页（尤其「默认开哪一个战役」）都要从**扫出来的表**算，
		#   不能写死 demo —— 往 data/campaigns/ 放一个新目录就会把默认值顶掉。
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

	var test_btn: Button = menu.test_button()
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
	# ★ 默认开的是**扫出来的第一项**（`list_campaigns()` 按目录名排序 ⇒ 稳定可预期）。
	#   ⚠️ 这里刻意不写死 demo：往 data/campaigns/ 放一个新目录会把它顶掉，
	#      而「默认跟着数据走」正是这一页该有的行为（写死反而会假红）。
	eq(String(screen.campaign().id), _default_id, "载入的就是扫出来的第一个战役（%s）" % _default_id)
	eq(screen.selected_campaign(), 0, "★ 选择条也停在第一项上（与载入的那个一致）")

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
		# ★★ 按钮上显示的是**数据里的名字**（蓝方 / 红方），不是 id（F1 / F2）——
		#    玩家挑的是「哪一方」，看 id 还得回去对数据。名字只有一个来源：
		#    `logic/level.gd` 的 `faction_name()`（界面不自己拼）。
		eq(screen.faction_text(0), (lv0 as RefCounted).faction_name("F1"),
			"★ 阵营按钮显示数据里的名字（第 1 个 = 蓝方）")
		ok(screen.faction_text(0) != "F1",
			"★ 显示的是名字不是 id（实际「%s」）" % screen.faction_text(0))
		if screen.faction_count() >= 2:
			eq(screen.faction_text(1), (lv0 as RefCounted).faction_name("F2"),
				"★ 第 2 个按钮 = 红方")
			ok(screen.faction_text(1) != "F2", "★ 第 2 个也不是 id")

	# ---- ★★ 这一页的皮肤：与入场页 / 主界面同一套（暗金），不是旧的白底 ----
	# ⚠️ 这一页与主界面**共用** `menu.campaign_test_*` 那批键，所以改皮肤时它最容易漏 ——
	#    漏了的表现是「点进战役页，白底上一排深灰字」（暗底按钮里那份字色看不见）。
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
			# 第一关是**默认选中**的 ⇒ 它应该是「常驻满格的金」那一档；未选中的那些是透明底 + 金线。
			#
			# ★★ 本版口径变更（悬停填充动效那一轮）：那一档金**不再由 StyleBox 画**，
			#   而是由自绘的「金色填充层」常驻满格给（见 view/fill_button.gd）——
			#   它画在底纹**下面**，StyleBox 一旦铺实底就会把整片金盖住。
			#   ⇒ 断言拆成两半：底纹只留描边；「实心金」这件事看填充层的进度与锁定态。
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
				# ★ 字色也要跟着换：实心金底上必须是**能被那片金衬出来**的暗字。
				#   ⚠️ 判据用「够不够暗」（而不是等于某个公式值）：这一页的按钮上
				#      `_make_button` 本来就挂着一支近黑（`text_on_accent`），
				#      填充层登记到的「原色」就是它 —— 再压一次会漂到另一个暗值上。
				#      这里要守住的是**观感**：字够暗、读得出来。
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
# 4) ★★ 战役选择条：选项来自目录扫描 + 点它能真的换战役
#
# 需求原话：「点击选项条后读取相应目录下的战役配置项动态生成选项，玩家可以点击选项
#           切换战役（类似主界面选 test 地图）」。
# 这一节盯的就是那两半：
#   · **选项从哪来** —— 必须等于 `campaign_library.list_campaigns()`（同一份来源，
#     界面不自己编清单；多一个战役目录就多一项）；
#   · **点了真的换** —— 换完关卡列表 / 阵营列表 / 「开始」都跟着换成新战役的。
# ------------------------------------------------------------------
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

	# ---- 选项 = 扫出来的战役表（逐项同名同序）----
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

	# ---- 选择条本身是个真控件（不是只有数据）----
	var bar: Button = screen.campaign_select_button()
	ok(bar is Button, "★ 选择条在界面上真的建出了按钮")
	if bar is Button:
		eq(String(bar.name), "CampaignSelect", "按钮的名字是 CampaignSelect（与地图那条区分开）")
		eq(bar.text, screen.campaign_select_item_text(screen.selected_campaign()),
			"★ 按钮上那行字 = 当前选中的那一项（map_select 每次选中都会重写它）")
		# ★ 与地图选择条同一个部件 ⇒ 同一套「暗底金线」皮肤（含下拉列表底板）。
		# ⚠️ 判据是**颜色值**，不是「与 `menu_theme` 那个对象相等」——实测：
		#    `add_theme_stylebox_override()` 会给每个控件存一份**自己的拷贝**，
		#    `sb == MenuThemeRes.button_normal()` 永远是 false（那是引用比较）。
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
			# ★★ 本版口径变更（填充动效那一轮）：悬停那层金改由自绘填充层给，
			#   底纹只留「透明底 + 亮线」（叠两层会把那片金压暗）。
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
		# ★ 下拉列表挂在按钮下面（同一个部件的做法）。
		#   ⚠️ 本版起按钮下面**不止一个**孩子：还有那层自绘的「金色填充」
		#      （`FillAnimator`，见 view/fill_button.gd）—— 所以按**类型**找它，
		#      不按 `get_child(0)` 的下标找（那条断言会因为多挂一层而假红）。
		var sel_popup: PopupMenu = null
		for child in bar.get_children():
			if child is PopupMenu:
				sel_popup = child as PopupMenu
				break
		ok(sel_popup != null, "★ 下拉列表挂在按钮下面（同一个部件的做法）")
		# ★★ 列表那块底板**必须显式给、而且必须不透明**（引擎默认是浅色 HUD 皮，
		#    在暗金页面上会弹出一块刺眼的白；PopupMenu 是独立窗口，半透明会看到桌面）。
		var popup_style: StyleBox = null
		if sel_popup != null:
			popup_style = sel_popup.get_theme_stylebox("panel")
		ok(popup_style is StyleBoxFlat, "下拉列表有显式底板（不是引擎默认那套）")
		if popup_style is StyleBoxFlat:
			var ps := popup_style as StyleBoxFlat
			eq(ps.bg_color.a, 1.0, "★ 列表底板是**不透明**的（这一条是实测踩过的坑）")
			# ★★ 本版新增：列表也要**风格化**（与「暗底 + 金线」同一件东西），
			#    不是「把引擎默认皮换成纯黑」就算完。
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

	# ---- 位置：在标题金线之下、关卡列表之上（这一页的「选择条 → 内容」顺序）----
	var rule = screen.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn/TitleRuleWrap")
	var level_box = screen.get_node_or_null("CampaignRoot/CampaignCenter/CampaignColumn/LevelBox")
	ok(rule is Control and level_box is Control, "（前提）金线与关卡列表都在")
	if bar is Button and rule is Control and level_box is Control:
		ok(bar.get_global_rect().position.y >= (rule as Control).get_global_rect().end.y - 1.0,
			"★ 选择条在标题金线**下面**")
		ok((level_box as Control).get_global_rect().position.y
				>= bar.get_global_rect().end.y - 1.0,
			"★ 选择条在关卡列表**上面**")

	# ---- ★★ 点它换战役：关卡 / 阵营 / 按钮上的字全跟着换 ----
	var other := -1
	for i in _campaigns_now.size():
		if String((_campaigns_now[i] as Dictionary)["id"]) == OTHER_CAMPAIGN_ID:
			other = i
	if other < 0:
		ok(true, "（跳过）扫出来的表里没有 %s，换战役那一半这次不验" % OTHER_CAMPAIGN_ID)
		main.queue_free()
		await process_frame
		return

	# 走**下拉列表真实的事件**（不是直接调页里的私有函数）：接线断了这一条会红
	#
	# ⚠️ 按**类型**找它，不要写 `bar.get_child(0)`：本版起按钮下面多挂了一层
	#    自绘的「金色填充」（`FillAnimator`，见 view/fill_button.gd），
	#    `get_child(0)` 会取到那一层、转成 PopupMenu 得到 null，接着就是
	#    「Invalid access to property 'id_pressed' on Nil」——本条用例整段作废。
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
	# 关卡列表 = 新战役的单人关条数（不是旧战役的）
	var want_solo := 0
	for lv in want_camp.levels:
		if String((lv as RefCounted).mode) == "solo":
			want_solo += 1
	eq(screen.level_count(), want_solo, "★ 关卡列表换成了新战役的（%d 关）" % want_solo)
	if screen.level_count() >= 1:
		eq(screen.level_text(0), String((screen.level_options()[0] as RefCounted).name),
			"★ 第一关的名字来自新战役")
		# 阵营列表 = **新那一关**的 playable_ids()（换战役最容易漏掉的一处）
		var lv_new = screen.chosen_level()
		if lv_new != null:
			eq(screen.faction_options(), (lv_new as RefCounted).playable_ids(),
				"★ 阵营列表 = 新战役那一关的 playable_ids()")
		ok(screen.can_start(), "★ 换完战役之后「开始」是可用的（不是卡在旧的选中状态上）")

	# ---- 再换回来：来回切都要稳（幂等，不会把下标弄坏）----
	if popup != null:
		popup.id_pressed.emit(0)
		await process_frame
		eq(screen.selected_campaign(), 0, "★ 换回第 0 项，下标正确")
		eq(String(screen.campaign().id), _default_id, "★ 换回来的就是默认那个战役")
		# 越界的下标要被忽略（点空项 / 列表被清空那一档）
		screen.campaign_select_select(99)
		eq(screen.selected_campaign(), 0, "★ 越界的下标被忽略（不会把选中弄坏）")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 5) ★★ 按「开始」真的进了**那一关**
# ------------------------------------------------------------------
func _test_start_enters_the_level() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	# 先记下这一关应该长什么样（从**同一份数据**算出来，不写死数字）
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
		eq(String(game.level_campaign.id), _default_id, "战役 id 就是默认那一个")
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
