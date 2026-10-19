## test_start_flow.gd —— ★ 开场流程：白屏入场页 → 主界面 → 游戏内场景
extends "res://tests/test_case.gd"

const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const StartScreenRes = preload("res://view/start_screen.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")

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
	await _test_boot_fade()
	await _test_fast_click_during_intro()
	await _test_intro_record_race()
	await _test_mid_morph_return()
	await _test_entry_flow()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## 等页面真的就位。
## ★ 现在「点击被受理」与「切页」之间还有一段**落位动画**（徽标 / 标题 / 金线缓动到主界面，
##   见 view/start_screen.gd 的 `_play_intro_morph()`），所以点完不能当场读 `page()`。
##   ⚠️ 这里**不**再等外壳的滑入动画：那一段不影响本文件的断言（它们量的是主界面那一列，
##      它是 `dir = 0` 的目标、位置不动，只是淡入）。
func _wait_page(menu, want: int) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and int(menu.page()) != want:
		await process_frame
	await process_frame


## 等战役过渡画面挂出来。
func _wait_transition(main):
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and main.level_transition() == null:
		await process_frame
	return main.level_transition()


## 等过渡画面加载完 + 提示可点。
func _wait_transition_ready(tr) -> void:
	var deadline: int = Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
		await process_frame

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


## 按**时间**等（Tween 是时间驱动的；`--script` 下帧率不锁 60）。
func _wait_sec(seconds: float) -> void:
	var deadline: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
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
		# ★ 「受理点击」与「切页」之间现在还有一段落位动画（见 start_screen.dismiss_intro），
		#   所以要等页面真的就位，不能再当场读 page()。
		await _wait_page(menu, PAGE_MENU)
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
		await _wait_page(menu, PAGE_MENU)
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


## ★★ 开局「从全黑淡入」那一层（用户要求：开始界面也要有渐入动画）。
func _test_boot_fade() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return
	var bf = menu.boot_fade()
	ok(bf != null, "★ 启动时有一层「从全黑淡入」的遮罩")
	if bf != null:
		near(bf.color.a, 1.0, 0.001, "遮罩起始是全不透明（alpha %.2f）" % bf.color.a)
		ok(bf.color.get_luminance() < 0.02, "遮罩是黑色（不是白闪）")
		eq(bf.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"淡入期间不挡点击（玩家可以直接点掉入场页）")
		var vp: Vector2 = root.get_visible_rect().size
		ok(bf.size.x >= vp.x - 1.0 and bf.size.y >= vp.y - 1.0,
			"遮罩铺满整个视口（%.0f×%.0f）" % [vp.x, vp.y])
		# 淡入中途：透明度应该已经小于 1。
		await _wait_sec(0.15)
		var bf_mid = menu.boot_fade()
		ok(bf_mid != null and bf_mid.modulate.a < 1.0,
			"★ 0.15s 时遮罩正在淡出（modulate %.2f）"
			% (bf_mid.modulate.a if bf_mid != null else -1.0))
	# 等它彻底消失。
	var deadline: int = Time.get_ticks_msec() + int(menu.boot_fade_sec() * 1000.0) + 2000
	while Time.get_ticks_msec() < deadline and menu.boot_fade() != null:
		await process_frame
	ok(menu.boot_fade() == null, "★ 淡入结束后遮罩被移除（不会一直压着一层黑）")

	# 没跑完就 close()：必须一起收掉，否则从游戏回菜单会看到一层残留黑幕。
	var ss = StartScreenRes.new()
	root.add_child(ss)
	ss.setup(menu.cfg, FontLoaderRes.load_font(menu.cfg))
	ok(ss.boot_fade() != null, "（前提）新开一页时淡入层在")
	ss.close()
	ok(ss.boot_fade() == null, "★★ close() 会把没跑完的淡入层收掉")
	ss.queue_free()
	await process_frame

	# 动效总开关关掉 ⇒ 不建这一层（与其他动效同一条口径）。
	ThemeRes.set_animations_enabled(false)
	var ss2 = StartScreenRes.new()
	root.add_child(ss2)
	ss2.setup(menu.cfg, FontLoaderRes.load_font(menu.cfg))
	ok(ss2.boot_fade() == null, "★ 动效关掉时不建淡入层（瞬间显示）")
	ss2.queue_free()
	ThemeRes.set_animations_enabled(true)

	main.queue_free()
	await process_frame


## ★★ 快速点击不能点到「还没显示出来的 test 按钮」。
## 未修复时：落位动画期间 `_menu` 是「显示但 alpha 0」，按钮仍然吃鼠标 ⇒
## 一点就直接开局，`close()` 把动画掐断，回菜单时 logo 与三颗 test 全停在 alpha 0。
func _test_fast_click_during_intro() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return

	menu.dismiss_intro()
	await process_frame
	ok(menu.menu_blocked(), "★ 落位动画期间，正中的按钮被明确挡住")
	var buttons: Array = menu.test_buttons()
	ok(not buttons.is_empty(), "（前提）有 test 按钮")
	if buttons.is_empty():
		main.queue_free()
		return
	var tb: Button = buttons[0]
	var center: Vector2 = tb.get_global_rect().get_center()
	ok(center != Vector2.ZERO, "（前提）按钮已经有排版位置（%.0f,%.0f）" % [center.x, center.y])
	# 在按钮所在位置点一下 —— 此时它还看不见。
	await _click_at(center)
	eq(main.game, null, "★★ 落位/淡入期间点 test **不会**开局")

	await _wait_page(menu, PAGE_MENU)
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and menu.menu_blocked():
		await process_frame
	ok(not menu.menu_blocked(), "★ 外壳首次淡入结束后，按钮解除封锁")
	eq(main.game, null, "★★ 整段动画走完仍然没有误开局")
	var mm = menu.get_node_or_null("StartRoot/MainMenu")
	ok(mm != null, "主界面还在")
	if mm != null:
		near(mm.modulate.a, 1.0, 0.001, "★★ 主界面整列是不透明的（logo 与按钮都在）")
	var tb2: Button = menu.test_buttons()[0]
	near(tb2.modulate.a, 1.0, 0.001, "★★ test_1 也回到不透明（不会落位后消失）")

	main.queue_free()
	await process_frame


## ★★ 回归（本轮）：入场落位期间 `panel_expand.attach()` 抄到的 `MainMenu` 初值
##   不能是 alpha 0。用户报的「点得太快 → 图标移动到目标后消失，三颗 test 也没了」：
##   `attach()` 等一帧才抄初值，而这一帧里落位动画已经为了量矩形把主菜单压成 alpha 0；
##   `play_intro()` 又把 dir=0 的目标「还原」成那个 0 ⇒ 永久不可见。
func _test_intro_record_race() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return
	var eng = menu.menu_chrome().expand_engine()
	# 构造竞态：alpha 已经是 0，而 attach 这会才抄初值。
	menu._menu.modulate.a = 0.0
	eng._initial.clear()
	eng._record_all()
	var rec: Variant = eng._initial.get(menu._menu, null)
	ok(rec != null, "（前提）MainMenu 被登记为「让路」目标")
	if typeof(rec) == TYPE_DICTIONARY:
		near(((rec as Dictionary)["modulate"] as Color).a, 1.0, 1e-4,
			"★★ dir=0 目标的初值透明度被钉成 1（不会被瞬态 0 污染）")

	# 走一遍真实流程：点一下、等落位 + 外壳淡入全部结束。
	menu._menu.modulate.a = 1.0
	ok(menu.dismiss_intro(), "点击受理")
	await _wait_page(menu, PAGE_MENU)
	var deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < deadline and menu.menu_blocked():
		await process_frame
	await process_frame
	near(menu._menu.modulate.a, 1.0, 1e-4, "★★ 落位结束后主菜单没有停在 alpha 0")
	var tb: Array = menu.test_buttons()
	ok(not tb.is_empty(), "（前提）test 按钮还在")
	if not tb.is_empty():
		near((tb[0] as Button).modulate.a, 1.0, 1e-4, "★★ test_1 没有消失")

	# ★ 再验一次「滑入被强行打断」的兜底：`_kill_tween()` 必须补终态，不能停在 alpha 0。
	eng.play_intro()
	await process_frame
	ok(eng._intro_running, "（前提）第二次滑入动画正在跑")
	eng._kill_tween()
	var tb2: Array = menu.test_buttons()
	ok(not tb2.is_empty(), "（前提）test 按钮还在")
	if not tb2.is_empty():
		near((tb2[0] as Button).modulate.a, 1.0, 1e-4,
			"★★ 滑入被打断时，子控件被补回不透明（不会永久消失）")

	main.queue_free()
	await process_frame


## ★★ 落位动画中途被 close()/open_menu() 打断（例如误开局后返回菜单）：
## 主界面整列必须被 show_page(PAGE_MENU) 兜回不透明，否则回来是一块空界面。
func _test_mid_morph_return() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var menu = main.start_screen
	if menu == null:
		main.queue_free()
		return
	menu.dismiss_intro()
	await process_frame
	menu.close()
	await process_frame
	menu.open_menu()
	await process_frame
	eq(int(menu.page()), PAGE_MENU, "回菜单后停在第 1 页")
	var mm = menu.get_node_or_null("StartRoot/MainMenu")
	ok(mm != null, "主界面节点还在")
	if mm != null:
		near(mm.modulate.a, 1.0, 0.001, "★★ 整列被兜回不透明（不会停在 alpha 0）")
	ok(not menu.menu_blocked(), "★ 回菜单后按钮可用")
	for b in menu.test_buttons():
		near((b as Button).modulate.a, 1.0, 0.001, "test 按钮 %s 也是不透明的" % (b as Button).name)
	ok(menu.boot_fade() == null, "回菜单时没有残留的开局黑幕")
	main.queue_free()
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
	await _wait_page(menu, PAGE_MENU)
	eq(int(menu.page()), PAGE_MENU, "已经进到主界面")

	await process_frame

	# ★★ 主界面正中现在是**三颗 test_1 / test_2 / test_3**（各自直连一关）；
	#    旧的「地图选择条 + test + campaign_test」三件套已经从界面上移除。
	var buttons: Array = menu.test_buttons()
	ok(buttons.size() == 3, "★ 主界面正中正好有三颗 test 按钮（实际 %d）" % buttons.size())
	if buttons.size() != 3:
		main.queue_free()
		return

	for i in buttons.size():
		var b: Button = buttons[i]
		ok(b is Button, "第 %d 颗是 Button" % i)
		eq(b.text, "test_%d" % (i + 1), "★ 第 %d 颗的文案是 test_%d" % [i + 1, i + 1])
		ok(b.get_parent() != null and b.get_parent().name == "MenuColumn",
			"它住在 MenuColumn 里（主界面正中那一列）")
		ok(absf(b.get_global_rect().get_center().x
				- b.get_parent().get_global_rect().get_center().x) < 2.0,
			"★ 第 %d 颗水平居中" % (i + 1))
		if i > 0:
			var prev: Button = buttons[i - 1]
			var gap_px: float = b.get_global_rect().position.y - prev.get_global_rect().end.y
			ok(gap_px >= 8.0 and gap_px <= 80.0,
				"★ 第 %d 颗紧挨着上一颗（间距 %.1f px）" % [i + 1, gap_px])

	var button: Button = buttons[0]
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
			"★ 标题条住在 MenuOuter 里")
		ok(button.get_parent() != null and button.get_parent().get_parent() == outer,
			"★★ 按钮列与标题条在同一个 MenuOuter 里（「标题在上、按钮在下」是排版保证的）")
		ok(orn.get_global_rect().end.y <= button.get_global_rect().position.y + 1.0,
			"★ 标题条在按钮列**上方**")

	var sb: StyleBox = (button as Control).get_theme_stylebox("normal")
	ok(sb is StyleBoxFlat, "test 按钮有一个 StyleBoxFlat 底纹")
	if sb is StyleBoxFlat:
		var flat: StyleBoxFlat = sb
		ok(flat.bg_color.a < 0.25,
			"★ 线框按钮是**透明底**（alpha %.2f）——暗底上实心浅底会是一块白斑" % flat.bg_color.a)
		ok(flat.border_color.r > flat.border_color.b, "★ 边框是**金色**（R > B）")
		ok(flat.get_border_width(SIDE_LEFT) >= 1 and flat.get_border_width(SIDE_LEFT) <= 2,
			"★ 边框是**细线**（%d px）——参考图里没有粗线" % flat.get_border_width(SIDE_LEFT))
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
	# ★★ 首次进主界面时，正中那一列要等外壳的滑入 + 淡入跑完才允许点
	#   （否则会点到 alpha 0 的按钮 —— 用户报的「快速点击后图标与 test 全消失」）。
	var ready_deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < ready_deadline and menu.menu_blocked():
		await process_frame
	ok(not menu.menu_blocked(), "（前提）按钮已经解除封锁，可以点了")
	await _click_at(test_rect.get_center())

	# ★★ 点 test_1 之后先进**战役过渡画面**（缩略图 + 简报 + 阵营选择 + 进度 + 点击进入）。
	var tr = await _wait_transition(main)
	ok(tr != null, "★★ 点 test_1 之后先出现战役过渡画面（不再直接开局）")
	eq(main.game, null, "★ 过渡画面阶段还没有建世界")
	if tr == null:
		main.queue_free()
		return
	ok(tr.faction_card_count() == 2, "★ 第一关有两个可玩阵营 → 两张阵营卡")
	tr.select_faction("F1")
	await _wait_transition_ready(tr)
	ok(tr.ready_to_enter(), "（前提）过渡画面加载完、阵营已选")
	await _click_at(tr.hint_rect().get_center())
	var enter_deadline: int = Time.get_ticks_msec() + 4000
	while Time.get_ticks_msec() < enter_deadline and main.game == null:
		await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "按下 test_1、在过渡画面点「进入」之后出现了游戏内场景")
	ok(main.get_node_or_null("GameScene") == game, "游戏内场景挂在 main 下的 GameScene 节点上")
	if game != null:
		# ★★ test_1 直连 demo / 01_beachhead：按下去就该真的进那一关（不是随便开一张图）。
		ok(game.level_playing != null, "★ 这一局是从**关卡**开的（不是裸地图）")
		if game.level_playing != null:
			eq(String(game.level_playing.id), "01_beachhead",
				"★★ test_1 进的就是它配的那一关（01_beachhead）")
		eq(game.world.my_faction, "F1", "★ 默认用第一个可玩阵营（F1）")
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

	menu.level_entry_pressed.emit("demo", "01_beachhead")
	await process_frame
	ok(main.game == game, "★ 再按一次 test 不会建出第二个世界（按钮只生效一次）")

	main.queue_free()
	await process_frame
