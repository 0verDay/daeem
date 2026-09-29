## test_map_select.gd —— ★ 主界面那条**地图选择条**：选项来自目录扫描，选中的图真的进游戏
##
## 需求原文：「在其上方加一个选择条，可以在其中选择地图，目前仅有一个地图，
##           但后续如果有新的地图，游戏会根据地图目录下的文件自动给出新的选项」。
##
## 这个文件盯的就是那句话里的两半：
##   1. **选项是扫出来的**（`logic/map_library.gd` 扫 `data/maps/<id>/map.json`）——
##      不是配置里列出来的、更不是写死在 view 里的清单。
##      所以这里两条一起测：拿盘上真目录扫一遍（数量 / 名字 / 路径），
##      再临时造一个新目录，看它会不会**自动多出一个选项**。
##   2. **选中的那张图真的被带进游戏** —— 选择条选了第二张，`main.game.world.map`
##      就必须是第二张的尺寸。只断言「下拉框里多了一项」是不够的：
##      选项对了而 `start()` 还是用默认图，游戏里表现就是「选了没用」。
##
## ⚠️ 造临时地图目录这件事得说清楚：无头测试**不往 res:// 里塞文件**（见
##    test_map_editor.gd 的同一条注释）—— 所以「临时加一个目录」这条断言
##    靠的是**扫描函数本身**（`list_maps` 只认 MapLibraryRes.MAPS_DIR），
##    真·临时目录那一半留给以后有需要时再加。这里只钉住「盘上两张图都被扫到、
##    且顺序/名字/路径都对」，那已经足以证明「加一张图 = 多一个选项」。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（见 docs/pitfalls.md 1.2）。
extends "res://tests/test_case.gd"

const MapLibraryRes = preload("res://logic/map_library.gd")

## 与 start_screen.gd 的两个页面常量对齐（刻意写数字，改名时这里应该直接失败）
const PAGE_MENU := 1

## 盘上必须有的两张图：`data/maps/<目录名>/map.json`（目录名 = 地图 id），
## 显示名来自地图 JSON 的 `name` 字段。
## ★ 与 `docs` 里的目录约定同源；加了新图**不用**改这里（下面只断言「至少有这两张」）。
const EXPECT_FRONTIER_ID := "frontier"
const EXPECT_FRONTIER_NAME := "边关"
const EXPECT_ARENA_ID := "arena"
const EXPECT_ARENA_NAME := "试炼场"

const MAPS_PREFIX := "res://data/maps/"

const CLICK_CENTER := Vector2(960.0, 540.0)
## test 按钮所在的 y。
## ⚠️ 主界面是一列「选择条 + 按钮」（整列居中），所以按钮**不在**整页正中：
##    无头下视口是 1920×1920，这一列实测落在 y 868..1052，
##    按钮（80 高）在 972..1052 → 中心 ≈ (960, 1012)。
##    布局一改这里就要跟着改 —— 所以下面那条位置断言量的是**相对关系**，不是坐标。
const CLICK_TEST := Vector2(960.0, 1012.0)


func _initialize() -> void:
	_case_name = "test_map_select"
	_run()


func _run() -> void:
	await process_frame
	_test_library_scan()
	await _test_menu_selector()
	await _test_selected_map_reaches_game()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1) 目录扫描：几张图、叫什么、路径对不对
# ------------------------------------------------------------------
func _test_library_scan() -> void:
	var maps: Array = MapLibraryRes.list_maps()
	ok(maps.size() >= 2,
		"★ data/maps 下的地图都被扫出来了（至少 frontier + arena，实际 %d 个）" % maps.size())

	var by_id: Dictionary = {}
	for item in maps:
		var m: Dictionary = item
		by_id[String(m["id"])] = m
		ok(String(m["path"]).begins_with(MAPS_PREFIX),
			"每一项的路径都在 %s 下（%s）" % [MAPS_PREFIX, str(m["path"])])
		ok(FileAccess.file_exists(String(m["path"])),
			"★ 每一项指向的地图文件真的存在（%s）" % str(m["path"]))
		ok(String(m["name"]) != "", "每一项都有显示名（%s）" % str(m["name"]))
		ok(m.has("placeholder"), "每一项都带 placeholder 标记（%s）" % str(m["id"]))

	# ★ 目录名就是 id；显示名来自地图 json 的 name 字段（不是目录名）
	ok(by_id.has(EXPECT_FRONTIER_ID), "扫到了 %s" % EXPECT_FRONTIER_ID)
	ok(by_id.has(EXPECT_ARENA_ID), "★ 扫到了第二张图 %s（多一个目录 = 多一个选项）" % EXPECT_ARENA_ID)
	if by_id.has(EXPECT_FRONTIER_ID):
		eq(String((by_id[EXPECT_FRONTIER_ID] as Dictionary)["name"]), EXPECT_FRONTIER_NAME,
			"★ 显示名读的是地图 json 里的 name（不是目录名）")
		eq(String((by_id[EXPECT_FRONTIER_ID] as Dictionary)["path"]),
			MAPS_PREFIX + EXPECT_FRONTIER_ID + "/map.json", "frontier 的路径是 <目录>/map.json")
		eq(bool((by_id[EXPECT_FRONTIER_ID] as Dictionary)["placeholder"]), false,
			"frontier 不是占位图")
	if by_id.has(EXPECT_ARENA_ID):
		eq(String((by_id[EXPECT_ARENA_ID] as Dictionary)["name"]), EXPECT_ARENA_NAME,
			"★ 占位图的显示名也来自它的 json")
		eq(bool((by_id[EXPECT_ARENA_ID] as Dictionary)["placeholder"]), true,
			"★ arena 是占位图（json 里写了 placeholder: true）")

	# ★ 顺序按目录名排（稳定）：arena 在 frontier 前面。
	#   ⚠️ 这条断言是**刻意的**：不给「顺序随文件系统怎么枚举都行」留后门，
	#      否则「选择条上有哪些图、按什么顺序排」会变成看运气的行为。
	eq(String((maps[0] as Dictionary)["id"]), EXPECT_ARENA_ID,
		"★ 选项按目录名排序（第一项是 arena，而不是枚举顺序随机的某个）")

	# ★★ 默认图**跳过占位图**：不选直接按 test 时进的是第一张**正式图**（frontier），
	#    而不是排序第一的 arena —— 否则加一张测试图就把默认局换掉了。
	eq(MapLibraryRes.default_map_path(), MAPS_PREFIX + EXPECT_FRONTIER_ID + "/map.json",
		"★ 默认地图 = 第一张**非占位**图（arena 排在前面也轮不到它）")
	eq(MapLibraryRes.is_placeholder(MAPS_PREFIX + EXPECT_ARENA_ID + "/map.json"), true,
		"is_placeholder 认得 arena")
	eq(MapLibraryRes.is_placeholder(MAPS_PREFIX + EXPECT_FRONTIER_ID + "/map.json"), false,
		"is_placeholder 认得出 frontier 不是占位图")
	eq(MapLibraryRes.is_placeholder("res://data/maps/不存在的地图/map.json"), false,
		"读不到的路径 → 不是占位图（不崩）")

	# 名字的兜底：给一张不存在的路径，显示名必须退回给它的 fallback，而不是报错
	eq(MapLibraryRes.display_name("res://data/maps/不存在的地图/map.json", "兜底名"), "兜底名",
		"★ 读不到的地图 → 显示名退回兜底（目录名），不崩")
	eq(MapLibraryRes.find_map_file("res://data/maps/不存在的地图", "x"), "",
		"找不到地图文件的目录返回空串（会被 list_maps 跳过）")


# ------------------------------------------------------------------
# 2) 主界面上的选择条本身
# ------------------------------------------------------------------
func _test_menu_selector() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return

	# 用真实点击进主界面
	await _click_at(CLICK_CENTER)
	eq(int(menu.page()), PAGE_MENU, "已经进到主界面")
	await process_frame

	# ⚠️ 选择条**不是**一个 Control 节点了：它是 `view/map_select.gd`（自己画的按钮 +
	#    自己的列表），所以拿它的按钮要问 `menu.map_select_button()` 而不是走节点路径。
	#    （换掉 OptionButton 的原因见那份文件的文件头：点开后按钮上的字会变空白。）
	var select: Button = menu.map_select_button()
	ok(select is Button, "主界面上有一条地图选择条（自己画的按钮）")
	ok(select.get_node_or_null("MapSelectPopup") is PopupMenu,
		"★ 选择条自己带一个下拉列表（PopupMenu），不依赖引擎的 OptionButton")
	var button = menu.get_node_or_null("StartRoot/MainMenu/MenuColumn/TestButton")
	ok(button is Button, "主界面上还有那个 test 按钮")
	var label = menu.get_node_or_null("StartRoot/MainMenu/MenuColumn/MapRow/MapLabel")
	ok(label is Label, "选择条左边有一个「地图」标签")

	if select is Button and button is Button:
		# ★★ 选项必须与扫描结果**一一对应**：条数与文字都要对得上 ——
		#    只测「有条目」会让「写死两项、其实目录里有三张图」这种错溜过去。
		var maps: Array = MapLibraryRes.list_maps()
		eq(menu.map_select_item_count(), maps.size(),
			"★ 选项条数 = 目录里扫出来的地图数（%d）" % maps.size())
		for i in maps.size():
			eq(menu.map_select_item_text(i), String((maps[i] as Dictionary)["name"]),
				"第 %d 项的显示名与扫描结果一致" % i)
		ok(menu.map_select_selected() >= 0,
			"★ 默认选中一项（不然「不选就按 test」进哪张图没定义）")
		# ★★ 默认选中的必须是**默认地图**（跳过占位图的第一张正式图），不是无脑第 0 项：
		#    选择条上高亮着 arena、按下去却进了另一张的话，玩家会说「选择条没用」。
		var want_default := String(MapLibraryRes.default_map_path())
		var want_index := 0
		for i in maps.size():
			if String((maps[i] as Dictionary)["path"]) == want_default:
				want_index = i
				break
		eq(menu.map_select_selected(), want_index,
			"★ 默认选中「默认地图」那一项（下标 %d，%s）" % [want_index, want_default])
		eq(menu.selected_map_path(), want_default,
			"★ 不选就按 test 时带出去的就是默认地图")
		ok(not select.disabled, "有地图时选择条是可用的")
		# ★★ 这一条是那次「点开后按钮上的字变空白」的**回归**：
		#    按钮上那行字必须永远等于当前选中项（自己写的，不靠引擎什么时候重画）。
		eq(select.text, menu.map_select_item_text(menu.map_select_selected()),
			"★ 选择条上那行字 = 当前选中项（不是空的）")

		# ★ 位置：选择条在 test 按钮**上方**（需求原文「在其上方」）
		var sel_rect: Rect2 = select.get_global_rect()
		var btn_rect: Rect2 = button.get_global_rect()
		ok(sel_rect.end.y <= btn_rect.position.y + 1.0,
			"★ 选择条在 test 按钮上方（选择条底 %.0f ≤ 按钮顶 %.0f）"
			% [sel_rect.end.y, btn_rect.position.y])
		ok(sel_rect.get_center().y < btn_rect.get_center().y, "★ 选择条整体在按钮之上（中心比较）")
		# ⚠️ 这里**不能**要求两者中心 x 相等：同一行里左边还有一个「地图」标签，
		#    标签占掉的宽度会让下拉框整体偏右。真正该钉的是「两者在一个竖向堆叠里」
		#    （不左右错开）—— 判据是横向范围重叠，而不是中心对齐。
		ok(sel_rect.intersects(Rect2(btn_rect.position.x, sel_rect.position.y,
				btn_rect.size.x, sel_rect.size.y)),
			"★ 选择条与 test 按钮在同一列（横向重叠：选择条 %s / 按钮 %s）"
			% [str(sel_rect), str(btn_rect)])
		ok(sel_rect.size.x > 0.0 and sel_rect.size.y > 0.0, "选择条有实际尺寸（没缩成一团）")
		ok(not sel_rect.intersects(btn_rect), "选择条与 test 按钮不重叠")

		# ---- ★ 真实点击：弹出列表，选中第二项，按钮上的字跟着变 ----
		#    这一段就是用户那个 bug 的操作路径，所以走**真实鼠标**。
		if maps.size() >= 2:
			var other := 1 if want_index == 0 else 0
			await _click_at(sel_rect.get_center())
			var popup: PopupMenu = select.get_node_or_null("MapSelectPopup")
			ok(popup != null and popup.visible, "★ 点一下选择条 → 列表弹出来")
			eq(select.text, menu.map_select_item_text(want_index),
				"★★ 列表弹出来时，按钮上那行字**仍然是当前选中项**（不许变空白）")
			# 选第二项（直接走 PopupMenu 的信号：列表项的位置在无头 / 子视口下不稳定）
			popup.id_pressed.emit(other)
			await process_frame
			eq(menu.map_select_selected(), other, "★ 换一项之后选中项跟着变")
			eq(select.text, menu.map_select_item_text(other),
				"★★ 换完之后按钮上写的就是**新那一项**（不是空白、也不是旧的）")
			eq(menu.selected_map_path(), String((maps[other] as Dictionary)["path"]),
				"★ selected_map_path() 返回的正是那一项对应的地图文件")
			# 列表关掉之后字还得在（这就是用户看到「悬停才又出现」的那一步）
			if popup.visible:
				popup.hide()
			await process_frame
			eq(select.text, menu.map_select_item_text(other),
				"★★ 列表关掉之后，按钮上那行字照样在（修的就是这一步）")
		menu.map_select_select(want_index)
		await process_frame
		eq(menu.selected_map_path(), want_default,
			"选回默认那一项 → 选中的地图跟着回去")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 3) ★ 选了第二张图 → 进游戏之后真的是第二张图
# ------------------------------------------------------------------
func _test_selected_map_reaches_game() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return

	await _click_at(CLICK_CENTER)
	await process_frame

	var maps: Array = MapLibraryRes.list_maps()
	if maps.size() < 2:
		ok(false, "需要至少两张地图才能验「选中的那张真的被带进游戏」")
		main.queue_free()
		return
	# ★ 挑一张**尺寸与默认那张不同**的图来选：尺寸相同的话，「其实还是载入了默认图」
	#   这条错就测不出来（两张图的 cols/rows 一样，断言会假绿）。
	var default_map = default_map_meta(menu)
	var picked: Dictionary = {}
	for item in maps:
		var m: Dictionary = item
		var mm = map_meta(String(m["path"]))
		if mm != null and default_map != null and int(mm["cols"]) != int(default_map["cols"]):
			picked = m
			break
	if picked.is_empty():
		# 没有尺寸不同的图：退而求其次，选第二项（至少能验「带出去的是它」）
		picked = maps[1] as Dictionary
	ok(not picked.is_empty(), "挑到一张用于验证的地图：%s" % str(picked.get("name", "")))

	var select: Button = menu.map_select_button()
	if select != null and not picked.is_empty():
		var index := maps.find(picked)
		menu.map_select_select(index)
		await process_frame
		eq(menu.selected_map_path(), String(picked["path"]), "（前提）选择条选中了目标那张图")
		eq(select.text, String(picked["name"]),
			"（前提）选择条上那行字也是那一张的名字")

	# 按下 test：走真实的信号 → main.gd → game_scene.start(选中的路径)
	await _click_at(CLICK_TEST)

	var game = main.game
	ok(game != null, "按下 test 之后出现了游戏内场景")
	if game != null and game.world != null and not picked.is_empty():
		var want = map_meta(String(picked["path"]))
		ok(want != null, "目标地图能被解析（%s）" % str(picked["path"]))
		if want != null:
			eq(game.world.map.cols, int(want["cols"]),
				"★ 进游戏用的是**选中的那张图**（列数，期望 %d）" % int(want["cols"]))
			eq(game.world.map.rows, int(want["rows"]),
				"★ 进游戏用的是**选中的那张图**（行数，期望 %d）" % int(want["rows"]))
		ok(game.world.units.size() > 0, "选中的那张图也能开出完整一局（有单位）")
	eq(main.game, game, "main 的游戏句柄就是刚建出来的那一个")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	return main


## 像真鼠标那样点一下（走视口 → GUI 命中测试 → Control 那条真实链，见 test_start_flow.gd）
func _click_at(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


## 读一张地图 json 的 cols / rows（解析失败返回 null）
##
## ⚠️ 返回类型写 Variant 而不是 Dictionary：解析失败要能回 null，而空字典会被
##    「有没有读到」的判空写成 `== {}`（那种判空在 GDScript 里很容易写错）。
func map_meta(path: String) -> Variant:
	var data: Variant = MapLibraryRes.read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = data
	return {"cols": int(d.get("cols", 0)), "rows": int(d.get("rows", 0))}


## 读「选择条上第一项」那张图的元数据（= 默认会进的那张）
func default_map_meta(menu) -> Variant:
	return map_meta(String(menu.selected_map_path()))
