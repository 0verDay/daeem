## test_map_select.gd —— 地图选择条（`view/map_select.gd`）与「直连一张地图开局」这条底层路径。
##
## ★★ 本轮界面改版之后，地图选择条**不再挂在主界面 / 战役面板上**（那两处换成了
##   test_1/2/3 与战役菜单）。但它本身仍是一个**独立部件**（`view/map_select.gd`），
##   测试按「把它单独装到一个宿主里」来验，不依赖任何一页界面。
##
## ★ `main._on_test_pressed(map_path)` 也仍然在：它是测试 / 截图脚本「随便开一张图」的入口
##   （库里几十处这么用），本文件顺带钉住「选中的那张图真的被带进 world」。
extends "res://tests/test_case.gd"

const MapLibraryRes = preload("res://logic/map_library.gd")
const MapSelectRes = preload("res://view/map_select.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")

const EXPECT_FRONTIER_ID := "frontier"
const EXPECT_FRONTIER_NAME := "边关"
const EXPECT_ARENA_ID := "arena"
const EXPECT_ARENA_NAME := "试炼场"

const MAPS_PREFIX := "res://data/maps/"

func _initialize() -> void:
	_case_name = "test_map_select"
	_run()

func _run() -> void:
	await process_frame
	_test_library_scan()
	await _test_selector_widget()
	await _test_selected_map_reaches_game()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

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

	eq(String((maps[0] as Dictionary)["id"]), EXPECT_ARENA_ID,
		"★ 选项按目录名排序（第一项是 arena，而不是枚举顺序随机的某个）")

	eq(MapLibraryRes.default_map_path(), MAPS_PREFIX + EXPECT_FRONTIER_ID + "/map.json",
		"★ 默认地图 = 第一张**非占位**图（arena 排在前面也轮不到它）")
	eq(MapLibraryRes.is_placeholder(MAPS_PREFIX + EXPECT_ARENA_ID + "/map.json"), true,
		"is_placeholder 认得 arena")
	eq(MapLibraryRes.is_placeholder(MAPS_PREFIX + EXPECT_FRONTIER_ID + "/map.json"), false,
		"is_placeholder 认得出 frontier 不是占位图")
	eq(MapLibraryRes.is_placeholder("res://data/maps/不存在的地图/map.json"), false,
		"读不到的路径 → 不是占位图（不崩）")

	eq(MapLibraryRes.display_name("res://data/maps/不存在的地图/map.json", "兜底名"), "兜底名",
		"★ 读不到的地图 → 显示名退回兜底（目录名），不崩")
	eq(MapLibraryRes.find_map_file("res://data/maps/不存在的地图", "x"), "",
		"找不到地图文件的目录返回空串（会被 list_maps 跳过）")


## 把选择条单独装起来（不经过任何一页界面）。
func _spawn_selector():
	var cfg = require_config()
	if cfg == null:
		return null
	var font := FontLoaderRes.load_font(cfg)
	var host := CenterContainer.new()
	host.name = "MapSelectHost"
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	await process_frame

	var sel = MapSelectRes.new()
	sel.build(host, font, 26, MenuThemeRes.text_normal(),
		MenuThemeRes.button_normal(),
		MenuThemeRes.button_hover_clear(),
		MenuThemeRes.button_fill_latched(),
		MenuThemeRes.button_normal(),
		MenuThemeRes.popup_panel(),
		MenuThemeRes.popup_row_hover(),
		Vector2(320.0, 56.0))
	var maps: Array = MapLibraryRes.list_maps()
	var names: Array = []
	for item in maps:
		names.append(String((item as Dictionary)["name"]))
	sel.set_items(names)
	var want_default := String(MapLibraryRes.default_map_path())
	var want_index := 0
	for i in maps.size():
		if String((maps[i] as Dictionary)["path"]) == want_default:
			want_index = i
			break
	sel.select(want_index)
	await process_frame
	return {"sel": sel, "host": host, "maps": maps, "default_index": want_index}

func _test_selector_widget() -> void:
	var ctx = await _spawn_selector()
	if ctx == null:
		return
	var sel = ctx["sel"]
	var maps: Array = ctx["maps"]
	var want_index: int = int(ctx["default_index"])
	var host: Control = ctx["host"]
	var select: Button = sel.button

	ok(select is Button, "选择条建出了按钮（自己画的，不是 OptionButton）")
	ok(select.get_node_or_null("MapSelectPopup") is PopupMenu,
		"★ 选择条自己带一个下拉列表（PopupMenu），不依赖引擎的 OptionButton")
	eq(sel.item_count(), maps.size(),
		"★ 选项条数 = 目录里扫出来的地图数（%d）" % maps.size())
	for i in maps.size():
		eq(sel.get_item_text(i), String((maps[i] as Dictionary)["name"]),
			"第 %d 项的显示名与扫描结果一致" % i)
	eq(sel.selected, want_index,
		"★ 默认选中「默认地图」那一项（下标 %d）" % want_index)
	ok(not select.disabled, "有地图时选择条是可用的")
	eq(select.text, sel.get_item_text(want_index),
		"★ 选择条上那行字 = 当前选中项（不是空的）")
	ok(select.size.x > 0.0 and select.size.y > 0.0, "选择条有实际尺寸（没缩成一团）")
	ok(host.is_ancestor_of(select), "它挂在测试给的宿主里")

	if maps.size() >= 2:
		var other := 1 if want_index == 0 else 0
		var rect := select.get_global_rect()
		await _click_at(rect.get_center())
		var popup: PopupMenu = select.get_node_or_null("MapSelectPopup")
		ok(popup != null and popup.visible, "★ 点一下选择条 → 列表弹出来")
		eq(select.text, sel.get_item_text(want_index),
			"★★ 列表弹出来时，按钮上那行字**仍然是当前选中项**（不许变空白）")
		popup.id_pressed.emit(other)
		await process_frame
		eq(sel.selected, other, "★ 换一项之后选中项跟着变")
		eq(select.text, sel.get_item_text(other),
			"★★ 换完之后按钮上写的就是**新那一项**（不是空白、也不是旧的）")
		if popup.visible:
			popup.hide()
		await process_frame
		eq(select.text, sel.get_item_text(other),
			"★★ 列表关掉之后，按钮上那行字照样在（修的就是这一步）")
		await _test_popup_easing(sel, select)

		sel.select(want_index)
		await process_frame
		eq(sel.selected, want_index, "选回默认那一项 → 选中项跟着回去")
		eq(select.text, sel.get_item_text(want_index), "按钮上的字也回到默认那一项")

	host.queue_free()
	await process_frame

func _test_popup_easing(sel, select: Button) -> void:
	var popup: PopupMenu = select.get_node_or_null("MapSelectPopup")
	ok(popup != null, "（前提）下拉列表还在")
	if popup == null:
		return
	if popup.visible:
		popup.collapse()
		for i in 30:
			await process_frame
	ok(not popup.visible, "（前提）起手是关着的")

	var rect := select.get_global_rect()
	var target_y := int(rect.position.y + rect.size.y)

	await _click_at(rect.get_center())
	var p_open := popup.position.y
	var a_open: float = sel.panel_alpha()
	await process_frame
	await process_frame
	var p_2 := popup.position.y
	var a_2: float = sel.panel_alpha()
	ok(popup.visible, "★ 点一下选择条 → 列表弹出来")
	ok(p_open < target_y and p_2 > p_open,
		"★★ 展开时从选项条下沿**往下滑**（起点 %d → %d，终点 %d）"
		% [p_open, p_2, target_y])
	ok(a_open < a_2,
		"★★ 同时**淡入**（面板 alpha %.2f → %.2f）—— 这就是「渐入」" % [a_open, a_2])

	for i in 30:
		await process_frame
	ok(absf(float(popup.position.y - target_y)) <= 2.0,
		"★★ 缓动结束时停在按钮下沿（%d ≈ %d）" % [popup.position.y, target_y])
	ok(sel.panel_alpha() > 0.99, "★ 结束时完全不透明")

	await _click_at(rect.get_center())
	var c_a1: float = sel.panel_alpha()
	await process_frame
	await process_frame
	var c_a2: float = sel.panel_alpha()
	ok(c_a2 < c_a1, "★★ 再点一下 → 底板**逐渐淡出**（alpha %.2f → %.2f）" % [c_a1, c_a2])
	for i in 30:
		await process_frame
	ok(not popup.visible, "★ 收缩跑完才真正隐藏")

	await _click_at(rect.get_center())
	for i in 30:
		await process_frame
	ok(popup.visible, "（前提）又弹出来了")
	popup.popup_hide.emit()
	var b_1 := popup.position.y
	await process_frame
	await process_frame
	ok(popup.visible,
		"★★ 点空白处之后列表**没有立刻消失**（先播收缩动画）")
	ok(popup.position.y <= b_1,
		"★★ 而且位置在往回收（%d → %d）" % [b_1, popup.position.y])
	for i in 30:
		await process_frame
	ok(not popup.visible, "★ 收缩跑完才隐藏（点空白处这条路）")


# ------------------------------------------------------------------
# 「直连一张地图开局」这条底层路径（测试 / 截图脚本用）
# ------------------------------------------------------------------

func _test_selected_map_reaches_game() -> void:
	var maps: Array = MapLibraryRes.list_maps()
	if maps.size() < 2:
		ok(false, "需要至少两张地图才能验「选中的那张真的被带进游戏」")
		return
	var picked: Dictionary = {}
	for item in maps:
		var m: Dictionary = item
		var mm = map_meta(String(m["path"]))
		var dm = map_meta(String(MapLibraryRes.default_map_path()))
		if mm != null and dm != null and int(mm["cols"]) != int(dm["cols"]):
			picked = m
			break
	if picked.is_empty():
		picked = maps[1] as Dictionary
	ok(not picked.is_empty(), "挑到一张用于验证的地图：%s" % str(picked.get("name", "")))

	var main = await _spawn_main()
	if main == null:
		return
	main._on_test_pressed(String(picked["path"]))
	await process_frame

	var game = main.game
	ok(game != null, "按下入口之后出现了游戏内场景")
	if game != null and game.world != null:
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

func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	if main.start_screen != null:
		main.start_screen.show_page(1)
		await process_frame
	return main

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

func map_meta(path: String) -> Variant:
	var data: Variant = MapLibraryRes.read_json(path)
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var d: Dictionary = data
	return {"cols": int(d.get("cols", 0)), "rows": int(d.get("rows", 0))}
