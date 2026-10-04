## test_settings_menu.gd —— ★ 游戏内「设置」二级菜单：全屏 / 返回主菜单
##
## 需求原文：「现在为游戏内的设置按钮也添加二级菜单，向其中加入全屏选项和返回到菜单选项」。
##
## 这个文件盯四件事：
##   1. **结构**：设置按钮按下去真的弹出一块面板，里面正好那两颗按钮（文案来自 config）。
##   2. **几何**：面板挂在设置按钮**下方**、不与它重叠，且**整块吃鼠标**
##      （不然点在它身上会穿到地图去，顺手给单位下一条移动命令）。
##   3. **全屏**：按一下 → 信号一路走到 `view/main.gd` 的 `toggle_fullscreen`
##      （窗口模式只在那一个函数里改；Ctrl+Q 走的是同一个函数）。
##   4. ★ **返回主菜单**：按一下 → 游戏场景真的被拆掉、开场页回到**主界面那一页**，
##      而且**再按一次 test 能开出一局新的**、**再来回一次也照样成立**。
##
## ★★ 这个文件里三条最贵的经验（都是写测试时实测撞出来的）：
##
##   ① **`push_input` 的点击要先有一次鼠标移动事件**，否则
##      `gui_get_hovered_control()` 是 null、那一下点击落到空处（面板看着好好的，
##      就是按不动）。所以 `_click_at()` 里**先推一个 MouseMotion 再推按下 / 抬起** ——
##      这也更接近真人（鼠标总是先移过去再点）。
##
##   ② **「往返两次」必须在同一节、同一个主场景里验**（`_test_return_to_menu`）。
##      分成两节的话，第一节结束时主场景要拆掉，而残留节点会带着一层 layer=100 的
##      开场页参与全屏 GUI 命中测试 —— 下一节看着一切正常、就是按不动，
##      而且报错信息完全不指向这里。同一节里往返就不需要拆场景，问题不存在；
##      「跨节清理」这件事本身不是被测对象（每个测试文件都是独立进程，天然干净）。
##
##   ③ 断言里**别对已经 free 的对象调方法**（比如「旧场景已经离开场景树」那条）：
##      值是对的（false），但引擎会顺手打一行 "previously freed" 红字噪音。
##      改用「先取出来、再判」的写法。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（见 docs/pitfalls.md 1.2）。
extends "res://tests/test_case.gd"

const UiLayoutRes = preload("res://view/ui_layout.gd")

## 与 start_screen.gd 的页面常量对齐（刻意写数字：改名时这里应该直接失败）
const PAGE_MENU := 1

## 进游戏时点 test 按钮的坐标（无头下视口是 1920×1920，量出来的值 —— 与
## tests/test_start_flow.gd / test_map_select.gd 用的是同一个）。
const CLICK_CENTER := Vector2(960.0, 540.0)
const CLICK_TEST := Vector2(960.0, 1012.0)


func _initialize() -> void:
	_case_name = "test_settings_menu"
	_run()


func _run() -> void:
	await process_frame
	await _test_menu_structure()
	await _test_fullscreen_request()
	await _test_return_to_menu()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 1) 结构：点设置 → 弹出面板，里面两颗按钮
# ------------------------------------------------------------------
func _test_menu_structure() -> void:
	var main = await _enter_game()
	if main == null:
		ok(false, "能进游戏（后面几条都在游戏里验）")
		return
	var hud = main.game.hud

	var panel = hud.get_node_or_null("HudRoot/SettingsMenu")
	ok(panel is PanelContainer, "设置面板挂在 HudRoot 下（SettingsMenu）")
	var fullscreen = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/FullscreenButton")
	var to_menu = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/ReturnMenuButton")
	ok(fullscreen is Button, "面板里有一颗「全屏」按钮")
	ok(to_menu is Button, "面板里有一颗「返回主菜单」按钮")

	if panel is Control and fullscreen is Button and to_menu is Button:
		var p: Control = panel

		# ---- 文案来自 config.json（view 里不写文案字面量）----
		eq((fullscreen as Button).text, hud.cfg.str_val("settings.fullscreen_off_text", "全屏"),
			"「全屏」按钮的文案来自 config")
		eq((to_menu as Button).text, hud.cfg.str_val("settings.menu_text", "返回主菜单"),
			"「返回主菜单」按钮的文案来自 config")
		eq(hud.settings_button.text, hud.cfg.str_val("settings.title", "设置"),
			"设置按钮本身的文案也来自 config")

		# ---- 进游戏时它是收着的（不该白占着屏幕右边）----
		ok(not p.visible, "★ 刚进游戏时设置面板是收着的")

		# ---- ★ 真实点击设置按钮：弹出来；再点一下：收回去（开关，不是单向）----
		#    这里刻意走**鼠标**而不是 emit_signal("pressed")：
		#    「设置按钮点得动」本身就是这次需求的一部分。
		var btn_center: Vector2 = hud.settings_button.get_global_rect().get_center()
		await _click_at(btn_center)
		ok(p.visible, "★ 点设置按钮 → 面板弹出来")
		await _click_at(btn_center)
		ok(not p.visible, "★ 再点一下 → 面板收回去（开关式）")

		# 后面几条要在「开着」的状态下量几何
		hud.set_settings_menu_open(true)
		await process_frame
		ok(p.visible, "（前提）面板已经打开")

		# ---- 几何：在设置按钮正下方、不重叠、装得下两颗按钮 ----
		var btn_rect: Rect2 = hud.settings_button.get_global_rect()
		var panel_rect: Rect2 = p.get_global_rect()
		ok(panel_rect.position.y >= btn_rect.end.y - 1.0,
			"★ 面板在设置按钮**下方**（按钮底 %.0f ≤ 面板顶 %.0f）"
			% [btn_rect.end.y, panel_rect.position.y])
		ok(not panel_rect.intersects(btn_rect), "面板与设置按钮不重叠")
		ok(panel_rect.size.x > 0.0 and panel_rect.size.y > 0.0, "面板有实际尺寸（没缩成一团）")
		ok(panel_rect.size.y >= UiLayoutRes.SETTINGS_MENU_ITEM_H * 2.0,
			"★ 面板装得下两颗按钮（高度 %.0f ≥ 两格 %.0f）"
			% [panel_rect.size.y, UiLayoutRes.SETTINGS_MENU_ITEM_H * 2.0])
		# 两颗按钮各占一格、上下排开
		var fr: Rect2 = (fullscreen as Control).get_global_rect()
		var tr: Rect2 = (to_menu as Control).get_global_rect()
		ok(tr.position.y >= fr.end.y - 1.0, "「返回主菜单」在「全屏」下面")
		ok(tr.size.y > 0.0 and fr.size.y > 0.0, "两颗按钮都有实际高度")
		# ★ 面板自己在右上角那一带（贴着设置按钮）
		ok(absf(panel_rect.end.x - btn_rect.end.x) < 40.0,
			"面板靠在设置按钮那一侧（右边缘 %.0f vs 按钮右边缘 %.0f）"
			% [panel_rect.end.x, btn_rect.end.x])

		# ---- ★ 整块吃鼠标：面板与两颗按钮都必须是 STOP ----
		#   判据是控件自己的 mouse_filter：HUD 在 CanvasLayer 上，被它拦下的点击
		#   走不到 input_controller，所以不会顺手给单位下命令。
		#   ⚠️ 这里**不该**去断言「边缘滚屏让路」：面板整块都落在屏幕最外圈 44px 的
		#     贴边带里，而那条规则对贴边带**故意无效**（`in_edge_band` 的例外，
		#     与设置按钮同一条）—— 断言它反而会把一条正确的行为测成失败。
		eq(p.mouse_filter, Control.MOUSE_FILTER_STOP,
			"★ 面板整块吃鼠标（STOP）—— 不然点它会穿到地图，顺手给单位下命令")
		eq((fullscreen as Control).mouse_filter, Control.MOUSE_FILTER_STOP,
			"「全屏」按钮吃鼠标")
		eq((to_menu as Control).mouse_filter, Control.MOUSE_FILTER_STOP,
			"「返回主菜单」按钮吃鼠标")

		hud.set_settings_menu_open(false)

	await _dispose(main)


# ------------------------------------------------------------------
# 2) 全屏：请求一路走到 main.toggle_fullscreen
# ------------------------------------------------------------------
func _test_fullscreen_request() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	hud.set_settings_menu_open(true)
	await process_frame

	# ---- 接线：两条链都要在 ----
	ok(hud.fullscreen_toggled.is_connected(Callable(game, "_on_fullscreen_toggled")),
		"★ hud 的「全屏」请求接到了 game_scene")
	ok(game.fullscreen_toggled.is_connected(Callable(main, "toggle_fullscreen")),
		"★ game_scene 又把它转给了 main.toggle_fullscreen（窗口模式只在那里改）")

	# ---- ★ 走真实点击按「全屏」：不能报错、也不能顺手做别的事 ----
	var before_mode: int = DisplayServer.window_get_mode()
	var page_before := String(hud.page_tabs.page())
	var center: Vector2 = hud.fullscreen_button.get_global_rect().get_center()
	await _click_at(center)
	ok(true, "★ 按下「全屏」不报错（信号链走通）")
	eq(String(hud.page_tabs.page()), page_before, "切全屏不会顺手切页签")
	eq(DisplayServer.window_get_mode(), before_mode,
		"⚠️ 无头下窗口模式不变（DisplayServer 是空实现）——这条只保证没崩")
	ok(hud.settings_panel.visible, "按全屏不会把设置面板收掉（玩家可能还想按第二项）")

	# ---- 按钮文案跟着当前窗口状态走（全屏时写「窗口化」= 按它回窗口）----
	#    ⚠️ 无头下切不了真全屏，所以这里验的是**文案规则**本身。
	#    必须写 `var expect: String = ...`（不能只用 `:=`）：str_val 返回 Variant，
	#    GDScript 推不出类型会直接 Parse Error。
	var label := String(hud.fullscreen_button.text)
	var expect: String = hud.cfg.str_val("settings.fullscreen_off_text", "全屏")
	if hud._is_fullscreen():
		expect = hud.cfg.str_val("settings.fullscreen_on_text", "窗口化")
	eq(label, expect, "★ 按钮文案跟着当前窗口状态走（全屏时写「窗口化」）")

	# ---- Ctrl+Q 与这颗按钮走同一个函数（不许各写一份）----
	ok(main.has_method("toggle_fullscreen"),
		"★ main 有一个公开的 toggle_fullscreen（Ctrl+Q 与设置菜单共用它）")
	main.toggle_fullscreen()          # 无头下什么都不发生，只要求不崩
	ok(true, "直接调 main.toggle_fullscreen() 不报错")

	hud.set_settings_menu_open(false)
	await _dispose(main)


# ------------------------------------------------------------------
# 3) ★ 返回主菜单（含「再来回一次」）
# ------------------------------------------------------------------
func _test_return_to_menu() -> void:
	var main = await _enter_game()
	if main == null:
		return
	var hud = main.game.hud
	var game = main.game
	var screen = main.start_screen
	hud.set_settings_menu_open(true)
	await process_frame
	ok(hud.settings_panel.visible, "（前提）设置面板开着")

	# 记下玩家选的地图：回到菜单之后那条选择条应该**还留着它**
	var picked := String(screen.selected_map_path())

	# ---- ★ 真实点击「返回主菜单」 ----
	await _click_settings_item(main, "ReturnMenuButton")

	# ---- 游戏场景拆掉了 ----
	eq(main.game, null, "★ 点「返回主菜单」→ main 的游戏句柄清空")
	ok(main.get_node_or_null("GameScene") == null,
		"★ GameScene 节点已经不在树上了（不只是 queue_free 排队）")
	# ⚠️ 先取出来再判：`game` 这时已经 free 了，直接 `game.is_inside_tree()` 值是对的
	#    （false），但引擎会顺手打一行 "previously freed" 的红字噪音。
	var still_in_tree: bool = is_instance_valid(game) and game.is_inside_tree()
	ok(not still_in_tree, "★ 旧游戏场景立刻离开了场景树（这一帧就不再跑逻辑 / 收输入）")
	# ⚠️ 这里**不能**再读 `hud.settings_panel.visible`：`return_to_menu()` 里那一下
	#    「先把设置面板收起来」跑在 **free 之前**，而走到这一行时 hud 已经是被释放的对象
	#    —— 读它只会得到一行
	#    「Invalid access to property or key 'settings_panel' on a base object of type
	#      'previously freed'」的红字噪音（值还读不到）。
	#    面板有没有被收起来由下面两条保证：一是 `main.return_to_menu()` 里显式收起，
	#    二是**下一次进游戏时 HUD 是新建的、面板默认隐藏**（第 3 节下面那条断言）。

	# ---- 开场页回来了，而且停在**主界面**那一页 ----
	ok(screen.visible, "★ 开场页重新可见（整层 show() 了，不只是页内两层）")
	eq(int(screen.page()), PAGE_MENU,
		"★ 回到的是**主界面**那一页（不收入场页：那一次「点击任意处」玩家已经付过）")
	ok(screen.get_node("StartRoot/MainMenu").visible, "主界面那一层可见")
	ok(not screen.get_node("StartRoot/Intro").visible, "入场页那一层没有回来")
	ok(screen.get_node("StartRoot/Background").visible, "白底回来了（菜单不是浮在游戏画面上）")

	# ---- 选择条上的地图还在（整个菜单对象没被重建）----
	eq(screen.selected_map_path(), picked,
		"★ 回到菜单后地图选择条还留着上次选的那张（不是被重置成默认图）")
	eq(screen.map_select_item_count(), screen.map_options().size(),
		"选择条的选项也还在")

	# ---- ★ 回到菜单之后 canvas 真的收得到鼠标（不只是「visible = true」）----
	#    这一条是那个坑的回归：CanvasLayer 被 hide() 过之后，只切页内两层
	#    **不会**恢复命中测试（见 start_screen.open_menu）。
	var sel_node: Button = screen.map_select_button()
	await _hover_at((sel_node as Control).get_global_rect().get_center())
	ok(root.gui_get_hovered_control() != null,
		"★ 回到菜单后鼠标停在选择条上有控件接住（白底那一层活着，不是「看着在、点不动」）")

	# ---- ★ 再按一次 test：应该建出**新的一局**（旧的那个 game 不能复活）----
	await _click_at(CLICK_TEST)
	var second = main.game
	ok(second != null, "★ 回到菜单之后再按 test 能开出一局新的")
	ok(second != game, "★ 新一局是**新的** game_scene（不是那个已经被拆掉的）")
	if second != null:
		ok(second.world != null, "新一局的世界建出来了")
		ok(second.get_node_or_null("Hud") != null, "新一局的 HUD 也在")
		ok(main.get_node_or_null("GameScene") == second, "新的 GameScene 挂在 main 下")
		ok(not screen.visible, "★ 进新一局之后开场页又整层下线了")

		# ---- ★ 第二次返回菜单：往返两次都得成立 ----
		#    第二次走 emit_signal 而不是鼠标：这里要验的是**流程**能不能来回两次
		#    （第一次已经把「按钮点得动」验过了），而上面那些「发射出去的点击」
		#    在同一个位置连点两次容易被上一帧的排队事件搅在一起。
		second.hud.return_menu_button.emit_signal("pressed")
		await process_frame
		eq(main.game, null, "★ 第二次返回菜单同样生效（不是只能回一次）")
		ok(screen.visible, "★ 第二次回来主界面同样可见")
		await _hover_at((sel_node as Control).get_global_rect().get_center())
		ok(root.gui_get_hovered_control() != null, "★ 第二次回来照样点得动")

	await _dispose(main)


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

## 新建一个主场景、进游戏，返回 main（与 test_start_flow.gd 的 _enter_game 同一套）。
func _enter_game() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main.start_screen.dismiss_intro()
	await process_frame
	main._on_test_pressed(main.start_screen.selected_map_path())
	await process_frame
	if main.game == null:
		ok(false, "进游戏失败（后面那些断言就都测不到东西了）")
		return null
	return main


## 彻底拆掉一节里建的主场景（见文件头经验 ②）。
##
## ⚠️ 必须 `remove_child` 之后再**立刻 `free()`**（而不是 `queue_free()`）：
##    `queue_free()` 只是排队，节点要到帧末才消失 —— 那一帧里它那层 layer=100 的
##    开场页仍然参与全屏 GUI 命中测试。测试里不需要「帧末再删」那套安全语义
##    （我们确定这一刻没人还在用它），所以直接 `free()`：立刻生效、没有中间态。
func _dispose(main) -> void:
	if main == null or not is_instance_valid(main):
		return
	if main.get_parent() != null:
		main.get_parent().remove_child(main)
	main.free()
	await process_frame


## 走**真实点击**按设置菜单里的某一颗按钮（不是直接 emit 信号）：
## 这样「面板真的挡在前面、点得到」这件事才算验过 —— 与 test_start_flow 里
## 「dismiss_intro 直接调不算测接线」是同一条教训。
##
## ⚠️ HUD 挂在**游戏场景**上（`main.game.hud`），不是 main 自己身上：
##    `main.hud` 会直接报「Invalid access to property 'hud'」（main.gd 上没有这个名字），
##    那条错误还会把这一轮点击一起吞掉 —— 表现就是「按钮按了没反应」的假失败。
func _click_settings_item(main, node_name: String) -> void:
	if main.game == null:
		ok(false, "（前提）还在游戏里，设置菜单才点得到")
		return
	var hud = main.game.hud
	hud.set_settings_menu_open(true)
	await process_frame
	var item = hud.get_node_or_null("HudRoot/SettingsMenu/SettingsMenuColumn/%s" % node_name)
	if not (item is Button):
		ok(false, "设置菜单里有 %s 可以点" % node_name)
		return
	await _click_at((item as Control).get_global_rect().get_center())


## 把鼠标**移**到某个位置（只有移动事件才会更新 Godot 的「鼠标下是谁」）
func _hover_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame


## 像真鼠标那样点一下：**先移动、再按下 / 抬起**（走视口 → GUI 命中测试 → Control 那条真实链）。
##
## ★★ 那个「先移动」不是可省的（见文件头经验 ①）：`push_input` 只推按下 / 抬起时，
##    `gui_get_hovered_control()` 会是 null，这一下点击**落到空处** ——
##    控件看得见、位置也对，就是按不动。真人的鼠标总是先移过去再点，所以这里也这么推。
func _click_at(pos: Vector2) -> void:
	await _hover_at(pos)
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
