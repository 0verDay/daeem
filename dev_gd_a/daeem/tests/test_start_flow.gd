## test_start_flow.gd —— ★ 开场流程：白屏入场页 → 主界面 → 游戏内场景
extends "res://tests/test_case.gd"

const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")

const PAGE_INTRO := 0
const PAGE_MENU := 1

const CLICK_CENTER := Vector2(960.0, 540.0)
const CLICK_AT_HINT := Vector2(960.0, 1030.0)

func _initialize() -> void:
	_case_name = "test_start_flow"
	_run()

func _run() -> void:
	await process_frame
	_test_theme_tokens()
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

func _test_theme_tokens() -> void:
	var accent := ThemeRes.accent()
	ok(accent.r > accent.g and accent.g > accent.b and accent.r > 0.5,
		"★ 强调色是**金色**（R>G>B，实测 %.2f,%.2f,%.2f）—— 蓝（#1E98D7）已经退场"
		% [accent.r, accent.g, accent.b])

	eq(UiStyleRes.accent(), accent, "★ 游戏内 HUD 的强调色 = 主题强调色（不是各写一份）")
	eq(MenuThemeRes.text_normal(), ThemeRes.text(), "进入界面的字色也来自主题")

	var top := ThemeRes.bg_top()
	var bottom := ThemeRes.bg_bottom()
	ok(top.get_luminance() < 0.35 and bottom.get_luminance() < 0.35,
		"★ 渐变底两端都是暗色（%.2f / %.2f）" % [top.get_luminance(), bottom.get_luminance()])
	ok(top.get_luminance() > bottom.get_luminance(),
		"★ 上端比下端亮（渐变是「上浅下深」，反了就成了倒过来的天光）")

	var ln := ThemeRes.line()
	ok(ln.r > ln.b, "边框线是金色系（R > B）")
	ok(ln.get_luminance() < ThemeRes.text().get_luminance(),
		"★ 线比字暗（参考图里线只是「勾一个边」，抢了字的亮度就脏了）")

	var hp_high := UiStyleRes.hp_high()
	var hp_low := UiStyleRes.hp_low()
	ok(hp_high.g > hp_high.r and hp_low.r > hp_low.g,
		"★ 血量条仍是「绿 → 红」两档可分（全做成金色等于把「快死了」这条信息抹掉）")
	ok(UiStyleRes.warn().r > UiStyleRes.warn().b, "警告色偏红（提示 / 拒绝用）")

	var panel := UiStyleRes.bg()
	ok(panel.a > 0.5 and panel.a < 1.0,
		"★ HUD 面板仍然半透明（alpha = %.2f）——做成 1.0 会把地图遮死" % panel.a)
	eq(panel.r, ThemeRes.bg_top().r, "面板底色由主题的 bg_top 派生（不是另写一个深灰）")

func _spawn_main() -> Node:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return null
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
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

	var title = menu.get_node_or_null("StartRoot/Intro/Title")
	ok(title != null and String(title.text) == "DAEEM", "入场页上方是标题 DAEEM")
	ok(title != null and title.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"★ 标题不吃鼠标（点了它照样算「任意处」——自绘控件漏了这条就是「点字上没反应」）")
	ok(title != null and title.font != null, "标题挂了字体（不然 DAEEM 也只是一排方框）")
	if title != null:
		ok(title.tracking > 0.0,
			"★ 标题带字距（参考图那排字是拉开的，tracking = %.1f）" % title.tracking)
		var want_w: float = menu.cfg.num("menu.title_rule_width", 460.0)
		ok(title.measured_width() > want_w * 0.5 and title.measured_width() < 1920.0,
			"★ 逐字推进算出来的标题宽度合理（%.0f px）—— 算错会让它偏出屏幕" % title.measured_width())

	var emblem = menu.get_node_or_null("StartRoot/Intro/Emblem")
	ok(emblem is Control, "★ 标题上方有一枚徽记（纯几何自绘，见 view/menu_emblem.gd）")
	ok(emblem != null and emblem.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"★ 徽记不吃鼠标（它是盖在页面上的一个矩形）")
	var rule = menu.get_node_or_null("StartRoot/Intro/TitleRule")
	ok(rule is Control, "★ 标题下面有一条金色分隔线（view/text_marks.gd 的 Rule）")
	var shine = menu.get_node_or_null("StartRoot/Intro/TitleShine")
	ok(shine is Control, "★ 标题上有一层扫光（入场时掠过一次）")
	ok(shine != null and shine.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"★ 扫光不吃鼠标（这是本轮最容易漏的一处：它盖着整块标题）")

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

	ok(not menu.get_node("StartRoot/MainMenu").visible, "入场页阶段主界面不显示")

	var bg = menu.get_node_or_null("StartRoot/Background")
	ok(bg is Control, "整页背景那一层在（StartRoot/Background）")
	ok(bg != null and bg.mouse_filter == Control.MOUSE_FILTER_STOP,
		"★ 收点击的是整页背景那一层（鼠标下最上层）")
	ok(menu.get_node("StartRoot").mouse_filter != Control.MOUSE_FILTER_STOP,
		"★ 父节点 StartRoot 不抢鼠标（抢了会让人误以为接在它上面就能收到）")
	ok(bg != null and bg.is_connected("gui_input", Callable(menu, "_on_page_gui_input")),
		"★ 点击处理器真的接在 Background 上（接错节点 = 游戏里点不动）")
	if bg != null:
		var tex = bg.get("_gradient")
		ok(tex is GradientTexture2D, "★ 背景带一张竖直渐变纹理（view/menu_background.gd 烘的）")
		if tex is GradientTexture2D:
			var gt: GradientTexture2D = tex
			ok(gt.width == 1 and gt.height >= 2,
				"渐变纹理是 1×N 的（一条竖线拉满整屏，实测 %d×%d）" % [gt.width, gt.height])
			var grad: Gradient = gt.gradient
			ok(grad != null, "渐变纹理挂着一份 Gradient（不是一张空图）")
			if grad != null:
				var first: Color = grad.sample(0.0)
				var last: Color = grad.sample(1.0)
				ok(first != last, "★ 渐变**两端不同色**（上 %.2f,%.2f,%.2f → 下 %.2f,%.2f,%.2f）"
					% [first.r, first.g, first.b, last.r, last.g, last.b])
				ok(first.r < 0.30 and first.g < 0.30 and first.b < 0.30,
					"★ 底色是**暗色**（上端 %.2f,%.2f,%.2f）" % [first.r, first.g, first.b])
				ok(first.get_luminance() > last.get_luminance(),
					"★ 上端比下端亮（%.3f > %.3f）——渐变是「上浅下深」"
					% [first.get_luminance(), last.get_luminance()])
				ok(first.get_luminance() + last.get_luminance() > 0.005,
					"★ 又不是纯黑（上端亮度 %.3f）——纯黑会把金线的对比压成一块死板"
					% first.get_luminance())
		var glow_tex = bg.get("_glow")
		ok(glow_tex is ImageTexture, "背景还带一张中心辉光纹理")

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

func _test_entry_flow() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return

	eq(main.game, null, "★ 启动时没有游戏场景（世界不会在菜单背后偷偷跑）")

	await _click_at(CLICK_CENTER)
	eq(int(menu.page()), PAGE_MENU, "已经进到主界面")

	await process_frame

	var button: Button = menu.test_button()
	ok(button is Button, "主界面有一个按钮")
	if button is Button:
		eq((button as Button).text, "test", "按钮文案是 test")
		var area_owner: Control = (button as Control).get_parent().get_parent()
		var area: Rect2 = area_owner.get_global_rect()
		var center: Vector2 = (button as Control).get_global_rect().get_center()
		ok(absf(center.x - area.get_center().x) < 2.0, "test 按钮水平居中")
		ok(area.size.x >= 100.0 and area.size.y >= 100.0, "按钮所在的那一层铺满了可用的窗口（不是缩成一团）")
		var select: Button = menu.map_select_button()
		ok(select is Button, "★ test 按钮上方有一条地图选择条")
		if select is Button:
			ok((select as Control).get_global_rect().end.y
					<= (button as Control).get_global_rect().position.y + 1.0,
				"★ 选择条在 test 按钮上方（需求原文「在其上方」）")

		var camp_btn: Button = menu.campaign_test_button()
		ok(camp_btn is Button, "★ 主界面上有 campaign_test 按钮（战役占位入口）")
		if camp_btn is Button:
			eq(camp_btn.text, "campaign_test", "★ 按钮上那行字就是 campaign_test")
			ok(camp_btn.get_global_rect().position.y
					>= (button as Control).get_global_rect().end.y - 1.0,
				"★ campaign_test 在 test 按钮**下面**（用户原话「就在 test 下面」）")
			var gap_px: float = camp_btn.get_global_rect().position.y \
				- (button as Control).get_global_rect().end.y
			ok(gap_px >= 8.0 and gap_px <= 80.0,
				"★ 两颗按钮挨得比较近（实测间距 %.1f px，期望 8~80）" % gap_px)
			ok(camp_btn.get_parent() == (button as Control).get_parent(),
				"campaign_test 按钮就在 MenuColumn 里（与 test 同一个容器）")

		var orn: Control = menu.menu_ornaments()
		ok(orn != null, "主界面上有标题条那一层（MenuOrnaments）")
		if orn != null:
			var emblem: Control = orn.find_child("MenuEmblem", true, false)
			ok(emblem is Control, "标题条里有徽记")
			ok(emblem != null and emblem.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"★ 徽记不吃鼠标")
			var word: Control = orn.find_child("MenuWordmark", true, false)
			ok(word != null and String(word.text) == menu.cfg.str_val("menu.title", "DAEEM"),
				"标题条里有 DAEEM 字标")
			ok(word != null and word.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"★ 字标不吃鼠标")
			var m_rule: Control = orn.find_child("MenuRule", true, false)
			ok(m_rule is Control, "标题条下面有一条金色细线")
			ok(m_rule != null and m_rule.mouse_filter == Control.MOUSE_FILTER_IGNORE,
				"★ 细线不吃鼠标")
			var outer: Control = orn.get_parent()
			ok(outer != null and String(outer.name) == "MenuOuter",
				"★ 标题条住在 MenuOuter 里（与按钮列同一个竖向列）")
			ok(outer != null and (button as Control).get_parent().get_parent() == outer,
				"★ 按钮列也在同一个 MenuOuter 里（两者是排版上的上下关系）")
			if outer != null:
				ok(orn.get_index() < (button as Control).get_parent().get_index(),
					"★ 标题条在按钮列**之前**（VBox 按顺序从上往下排 ⇒ 它在上方）")
			var lowest: float = 0.0
			for n in [emblem, word, m_rule]:
				if n != null:
					lowest = maxf(lowest, (n as Control).get_global_rect().end.y)
			ok(lowest <= (select as Control).get_global_rect().position.y + 1.0,
				"★ 标题条整体在选择条**上方**（标题底 %.0f ≤ 选择条顶 %.0f）"
				% [lowest, (select as Control).get_global_rect().position.y])
			var gap: float = (select as Control).get_global_rect().position.y - lowest
			ok(gap >= 8.0,
				"★ 标题条与选择条之间留了空隙（%.0f px）——贴在一起会被看成同一块内容" % gap)

		var sb: StyleBox = (select as Control).get_theme_stylebox("normal")
		ok(sb is StyleBoxFlat, "选择条有一个 StyleBoxFlat 底纹")
		if sb is StyleBoxFlat:
			var flat: StyleBoxFlat = sb
			ok(flat.bg_color.a < 0.25,
				"★ 线框按钮是**透明底**（alpha %.2f）——暗底上实心浅底会是一块白斑" % flat.bg_color.a)
			ok(flat.border_color.r > flat.border_color.b, "★ 边框是**金色**（R > B）")
			ok(flat.get_border_width(SIDE_LEFT) >= 1 and flat.get_border_width(SIDE_LEFT) <= 2,
				"★ 边框是**细线**（%d px）——参考图里没有粗线" % flat.get_border_width(SIDE_LEFT))
		var test_sb: StyleBox = (button as Control).get_theme_stylebox("normal")
		if test_sb is StyleBoxFlat:
			ok((test_sb as StyleBoxFlat).bg_color.a < 0.25, "★ test 按钮同样是透明底 + 金线")
		var hover_sb: StyleBox = (button as Control).get_theme_stylebox("hover")
		if hover_sb is StyleBoxFlat:
			ok((hover_sb as StyleBoxFlat).bg_color.a <= 0.001,
				"★ 悬停底纹是**透明底**（那片金交给填充层，叠两层会把金压暗）")
			var hb := hover_sb as StyleBoxFlat
			ok(hb.border_color.r > hb.border_color.b and hb.border_width_left >= 1,
				"★ 但悬停时**线亮着**（鼠标在哪儿要看得出来）")
		ok((button as Control).has_meta(FillButtonRes.META),
			"★ 而且按钮挂着「金色填充层」—— 悬停时金自下而上填进来")

	var test_rect: Rect2 = (button as Control).get_global_rect()
	ok(test_rect.size.x > 1.0 and test_rect.size.y > 1.0, "test 按钮已经排过版（量得到尺寸）")
	await _click_at(test_rect.get_center())

	var game = main.game
	ok(game != null, "按下 test 之后出现了游戏内场景")
	ok(main.get_node_or_null("GameScene") == game, "游戏内场景挂在 main 下的 GameScene 节点上")
	if game != null:
		for node_name in ["Camera3D", "GroundView3D", "UnitView3D", "BuildingView3D",
				"OverlayLayer", "InputController", "Hud"]:
			ok(game.get_node_or_null(node_name) != null, "进游戏后节点树里有 %s" % node_name)
		ok(game.get_node_or_null("Camera3D") is Camera3D,
			"★ 相机是 Camera3D（不是 Camera2D —— 这就是本版与上一版的根本区别）")
		ok(game.world != null, "进游戏后才建出 world")
		ok(game.cfg != null, "游戏内场景拿到了配置")
		ok(game.cam != null, "进游戏后建了相机")
		ok(game.palette != null, "★ 建了 3D 投影助手（「格 ↔ 屏幕」换算的唯一入口）")
		ok(game.interaction != null, "★ 建了交互核心（game_interaction.gd，与渲染无关）")
		ok(game.world.units.size() > 0, "地图里的单位已经存在")
		ok(not (game.world is Node), "★ world 仍然不是 Node（逻辑层与场景树分离）")

	eq(main.game, game, "main 的游戏句柄就是刚建出来的那一个")

	ok(not menu.visible, "★ 进游戏后开场页整层隐藏（白底与点击处理器一起停掉）")
	ok(not menu.is_processing(), "★ 隐藏之后开场页连 _process 也停了（不会有人在背后改状态）")
	eq(menu.get_node("StartRoot/Intro/ClickHint").modulate.a, 1.0,
		"★ 离开入场页时透明度被还原（Tween 被 kill 时会停在中间值上，留着就是一层灰字）")

	if game != null:
		var t0: float = game.world.time
		for i in 20:
			await process_frame
		ok(game.world.time > t0, "进游戏后主循环在推进逻辑（world.time 前进）")

	menu.test_pressed.emit()
	await process_frame
	ok(main.game == game, "★ 再按一次 test 不会建出第二个世界（按钮只生效一次）")

	main.queue_free()
	await process_frame
