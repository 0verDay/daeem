## test_start_flow.gd —— ★ 开场流程：白屏入场页 → 主界面 → 游戏内场景
##
## 为什么值得测：这三页之间是**时序**关系，而时序 bug 是这轮改动里最容易出的那一类 ——
##   - 启动时就不该有 world（否则世界在菜单背后偷偷 tick）
##   - 点一下只该走一步（点进主界面不会顺手把游戏也建出来）
##   - 进了游戏之后开场页必须**整层下线**：白底还在的话，鼠标会被那层吃掉，
##     底下的地图就变成「看得见、点不动」
##
## ★ 这个文件里最贵的一条教训（第一版就是这么翻车的）：
##   当时测试全绿、**游戏里却点不动**。原因是处理器接错了节点 —— Godot 的 GUI 命中测试
##   只把事件交给鼠标下最上层的那个 Control，接在父节点上是收不到的。
##   而当时的测试直接调 dismiss_intro()，等于绕开了整条输入链 —— 接线错了也照样通过。
##   所以现在两件事分开测：
##     1. `_test_intro_click_wiring` 走**真实视口输入**（Viewport.push_input），
##        断言点到哪儿都能进主界面；接错节点这条断言会直接失败。
##     2. `dismiss_intro()` 的判定（非左键 / 重复点不生效）另外单独测。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（见 docs/pitfalls.md 1.2）。
extends "res://tests/test_case.gd"

## 与 start_screen.gd 的两个页面常量对齐。★ 刻意写数字而**不是**去 load 那个脚本取常量：
##   常量万一被改名，这里应该直接失败，而不是跟着一起改、把页面切换测成永远通过。
const PAGE_INTRO := 0
const PAGE_MENU := 1

## 点两个位置：正中央，以及「提示文字所在的那一行」。
## ★ 后者是关键 —— 第一次修 bug 时把文字设成了吃鼠标，点在字上就点不进去。
##   这里点的是文字所在的**区域**，不是文字的像素（Label 一律 IGNORE，事件会落到最上层那层）。
const CLICK_CENTER := Vector2(960.0, 540.0)
const CLICK_AT_HINT := Vector2(960.0, 1030.0)


func _initialize() -> void:
	_case_name = "test_start_flow"
	_run()


func _run() -> void:
	await process_frame
	await _test_page_switching()
	await _test_intro_click_wiring()
	await _test_entry_flow()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## 新建一个主场景并挂上树，返回它的 start_screen
func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	return main


## 像真鼠标那样点一下：走视口 → GUI 命中测试 → Control.gui_input 这条真实链
## ★ 用 Viewport.push_input 而**不是** Input.parse_input_event：实测（4.7.2 无头）
##   parse_input_event 能到 Node._unhandled_input，但**不会**进 Control 的 gui_input
##   （gui_get_hovered_control() 一直是 null）—— 用它写出来的点击测试永远是假绿。
##   push_input(事件, true) 才会真的走 GUI 命中测试。
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


# ------------------------------------------------------------------
# 1) 两页各自长什么样（观感不测，测「有没有这一层、锚在哪、吃不吃鼠标」）
# ------------------------------------------------------------------
func _test_page_switching() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	ok(menu != null, "启动就搭出了开场页（start_screen）")
	if menu == null:
		main.queue_free()
		return

	eq(int(menu.page()), PAGE_INTRO, "启动停在第 0 页（入场页）")
	eq(menu.layer, 100, "开场页画在游戏画面之上（Hud 用的是默认的 1）")
	ok(menu.visible, "入场页可见")

	# ---- 标题 ----
	var title = menu.get_node_or_null("StartRoot/Intro/Title")
	ok(title != null and title.text == "DAEEM", "入场页上方是标题 DAEEM")
	ok(title != null and title.mouse_filter == Control.MOUSE_FILTER_IGNORE, "标题不吃鼠标（点在字上也照样进）")
	ok(title != null and title.get_theme_font("font") != null, "标题挂了字体（中文不会变方框）")

	# ---- 下方提示：文案 / 位置 / 呼吸 ----
	# ★ 破折号是中文全角「—」，前后各四个，与需求原文逐字一致
	const EXPECT_TEXT := "————点击任意处进入游戏————"
	var hint = menu.get_node_or_null("StartRoot/Intro/ClickHint")
	ok(hint != null and hint.text == EXPECT_TEXT, "下方提示是「————点击任意处进入游戏————」")
	ok(hint != null and hint.mouse_filter == Control.MOUSE_FILTER_IGNORE, "提示文字不吃鼠标")
	if hint != null:
		var r: Rect2 = hint.get_global_rect()
		var screen_h: float = root.get_visible_rect().size.y
		var screen_w: float = root.get_visible_rect().size.x
		ok(hint.visible and r.position.y > 0.0 and r.end.y < screen_h,
			"★ 提示真的落在画面**之内**（y %.0f..%.0f，屏高 %.0f）—— "
			% [r.position.y, r.end.y, screen_h]
			+ "锚点写错会把它推到画面外面，看不见但也不报错")
		ok(r.get_center().y > screen_h * 0.6,
			"★ 提示在屏幕**下方**（y 中心 %.0f > %.0f）" % [r.get_center().y, screen_h * 0.6])
		ok(hint.anchor_top == 1.0 and hint.anchor_bottom == 1.0,
			"★ 提示上下锚都贴底（只写 anchor_bottom 会让它跑到屏幕下面去）")
		ok(absf(r.get_center().x - screen_w * 0.5) < 2.0, "提示水平居中")

	# ★ 呼吸：暗端 → 亮端 → 暗端，一直在跑（动的是 modulate.a，不是 visible 的开关）
	var lo: float = menu.cfg.num("menu.click_alpha_min", 0.15)
	var hi: float = menu.cfg.num("menu.click_alpha_max", 1.0)
	ok(lo < hi, "呼吸的暗端比亮端暗（config.json 的 menu.click_alpha_* 写反了？）")
	ok(hi > 0.5, "亮端足够亮（不然文字看着像半透明残影）")
	ok(lo > 0.0, "★ 暗端不是 0：否则文字会整个消失，看起来像在闪")
	var alpha0: float = hint.modulate.a
	var seen_max: float = alpha0
	var seen_min: float = alpha0
	for i in 120:
		await process_frame
		seen_max = maxf(seen_max, hint.modulate.a)
		seen_min = minf(seen_min, hint.modulate.a)
	ok(seen_max > seen_min + 0.05, "★ 提示的透明度真的在变（渐显渐隐跑起来了）")
	ok(seen_max <= hi + 1e-3, "透明度不超过亮端")
	ok(seen_min >= lo - 1e-3, "透明度不低于暗端")

	# 主界面在入场页阶段**不该可见**：它虽然已经搭好，但要点掉入场页才出现
	ok(not menu.get_node("StartRoot/MainMenu").visible, "入场页阶段主界面不显示")

	# ---- 白底 / 收点击的那一层 ----
	var bg = menu.get_node_or_null("StartRoot/Background")
	ok(bg is ColorRect and (bg as ColorRect).color == Color.WHITE, "入场页是白底")
	# ★★ 收点击的必须是 Background 自己，而且只有它：
	#    Godot 的 GUI 命中测试只把事件交给鼠标下最上层的那个 Control，
	#    Background 盖在父节点 StartRoot 之上，接在父节点上就永远收不到（第一版的 bug）。
	ok(bg != null and bg.mouse_filter == Control.MOUSE_FILTER_STOP,
		"★ 收点击的是整页白底那一层（鼠标下最上层）")
	ok(menu.get_node("StartRoot").mouse_filter != Control.MOUSE_FILTER_STOP,
		"★ 父节点 StartRoot 不抢鼠标（抢了会让人误以为接在它上面就能收到）")
	ok(bg != null and bg.is_connected("gui_input", Callable(menu, "_on_page_gui_input")),
		"★ 点击处理器真的接在 Background 上（接错节点 = 游戏里点不动）")

	# 处理器本身的判定（接线由上面那条断言保证；这里只确认它认左键、不认别的键）
	if bg != null:
		var right := InputEventMouseButton.new()
		right.button_index = MOUSE_BUTTON_RIGHT
		right.pressed = true
		right.position = CLICK_CENTER
		menu._on_page_gui_input(right)
		eq(int(menu.page()), PAGE_INTRO, "直接喂给处理器一个右键：不算「任意处」")
		var left := InputEventMouseButton.new()
		left.button_index = MOUSE_BUTTON_LEFT
		left.pressed = true
		left.position = CLICK_CENTER
		menu._on_page_gui_input(left)
		eq(int(menu.page()), PAGE_MENU, "直接喂给处理器一个左键：切到主界面")
		ok(not menu.get_node("StartRoot/Intro").visible, "切到主界面后入场页收起")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 2) ★ 真实点击：点哪儿都能进主界面（这条就是第一版漏掉的）
# ------------------------------------------------------------------
func _test_intro_click_wiring() -> void:
	for pos in [CLICK_CENTER, CLICK_AT_HINT]:
		var main = await _spawn_main()
		if main == null:
			return
		var menu = main.start_screen
		if menu == null:
			main.queue_free()
			return
		eq(int(menu.page()), PAGE_INTRO, "点之前停在第 0 页（%s）" % str(pos))
		await _click_at(pos)
		eq(int(menu.page()), PAGE_MENU,
			"★ 在 %s 点一下就进入主界面（点击真的被那一层收到了）" % str(pos))
		ok(not menu.get_node("StartRoot/Intro").visible, "入场页收起（%s）" % str(pos))
		eq(main.game, null, "★ 点一下只走一步：这时还没有建游戏")
		main.queue_free()
		await process_frame

	# 判定本身：非左键不生效、重复点不生效（这两条与「接线对不对」无关，单独测）
	var main2 = await _spawn_main()
	if main2 == null:
		return
	var menu2 = main2.start_screen
	if menu2 != null:
		var mid := InputEventMouseButton.new()
		mid.button_index = MOUSE_BUTTON_MIDDLE
		mid.pressed = true
		mid.position = CLICK_CENTER
		Input.parse_input_event(mid)
		await process_frame
		eq(int(menu2.page()), PAGE_INTRO, "中键点击不算「任意处」")
		ok(menu2.dismiss_intro(), "左键点击生效")
		ok(not menu2.dismiss_intro(), "已经在主界面时再点一次不再生效（切页只发生一次）")
	main2.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 3) 按 test → 进游戏内场景
# ------------------------------------------------------------------
func _test_entry_flow() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return

	eq(main.game, null, "★ 启动时没有游戏场景（世界不会在菜单背后偷偷跑）")

	# 用真实点击进主界面
	await _click_at(CLICK_CENTER)
	eq(int(menu.page()), PAGE_MENU, "已经进到主界面")

	# 页面刚切过来时容器还没排过版（按钮 rect 还是 (0,0)），等一帧才量得到真实位置
	await process_frame

	var button = menu.get_node_or_null("StartRoot/MainMenu/TestButton")
	ok(button is Button, "主界面有一个按钮")
	if button is Button:
		eq((button as Button).text, "test", "按钮文案是 test")
		# ⚠️ 参照物是**装着它的那一层**（MainMenu），不是 root.get_visible_rect()：
		#    无头下视口高宽会被压成正方形（1920×1920），拿视口当基准会测出一条假失败。
		#    真正的居中保证是 MainMenu 铺满整页 + CenterContainer 居中，所以对着它测。
		var area_owner: Control = (button as Control).get_parent()
		var area: Rect2 = area_owner.get_global_rect()
		var center: Vector2 = (button as Control).get_global_rect().get_center()
		ok(absf(center.x - area.get_center().x) < 2.0, "test 按钮水平居中")
		ok(absf(center.y - area.get_center().y) < 2.0, "test 按钮垂直居中")
		ok(area.size.x >= 100.0 and area.size.y >= 100.0, "按钮所在的那一层铺满了可用的窗口（不是缩成一团）")

	# 真实点击 test 按钮（白底之上它是最上层，事件该落到它自己身上）
	await _click_at(Vector2(960.0, 960.0))

	var game = main.game
	ok(game != null, "按下 test 之后出现了游戏内场景")
	# ⚠️ 游戏内节点都住在 GameScene 下面（main 只多挂了一个 StartScreen），
	#    所以要从 game 里找，不能在 main 根上找 —— 找不到就等于这几行白测。
	ok(main.get_node_or_null("GameScene") == game, "游戏内场景挂在 main 下的 GameScene 节点上")
	if game != null:
		for node_name in ["Camera2D", "TerrainView", "ZoneView", "BuildingView", "UnitView",
				"Overlay", "CameraRig", "InputController", "Hud"]:
			ok(game.get_node_or_null(node_name) != null, "进游戏后节点树里有 %s" % node_name)
		ok(game.world != null, "进游戏后才建出 world")
		ok(game.cfg != null, "游戏内场景拿到了配置")
		ok(game.cam != null, "进游戏后建了相机")
		ok(game.world.units.size() > 0, "地图里的单位已经存在")
		ok(not (game.world is Node), "★ world 仍然不是 Node（逻辑层与场景树分离）")

	eq(main.game, game, "main 的游戏句柄就是刚建出来的那一个")

	# ★ 开场页必须**整层下线**：留一层白底盖着，地图就是「看得见、点不动」
	ok(not menu.visible, "★ 进游戏后开场页整层隐藏（白底与点击处理器一起停掉）")
	ok(not menu.is_processing(), "★ 隐藏之后开场页连 _process 也停了（不会有人在背后改状态）")
	eq(menu.get_node("StartRoot/Intro/ClickHint").modulate.a, 1.0,
		"★ 离开入场页时透明度被还原（Tween 被 kill 时会停在中间值上，留着就是一层灰字）")

	# 跑几帧：进游戏之后主循环真的在推进
	if game != null:
		var t0: float = game.world.time
		for i in 20:
			await process_frame
		ok(game.world.time > t0, "进游戏后主循环在推进逻辑（world.time 前进）")

	# 重复按 test 只该有一次效果
	menu.test_pressed.emit()
	await process_frame
	ok(main.game == game, "★ 再按一次 test 不会建出第二个世界（按钮只生效一次）")

	main.queue_free()
	await process_frame
