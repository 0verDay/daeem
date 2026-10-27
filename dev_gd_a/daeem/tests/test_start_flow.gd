## test_start_flow.gd —— 入场页 → 新主菜单 → 战役 → 详情 → 过渡 → 游戏。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")

func _initialize() -> void:
	_case_name = "test_start_flow"
	_run()


func _run() -> void:
	await process_frame
	await _test_main_layout()
	await _test_campaign_entry()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.2)
	return main


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_until(cond: Callable, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await process_frame
	return cond.call()


func _test_main_layout() -> void:
	var main = await _spawn_main()
	ok(main != null and main.start_screen != null, "主场景建出 StartScreen")
	if main == null or main.start_screen == null:
		return
	var screen = main.start_screen
	eq(int(screen.page()), 0, "启动停在入场页")
	ok(screen.dismiss_intro(), "点击入场页被受理")
	await _wait_until(func(): return int(screen.page()) == 1)
	eq(int(screen.page()), 1, "入场页切到主菜单")
	await _wait_sec(0.2)

	var mp = screen.main_panel()
	ok(mp != null, "主菜单面板存在")
	if mp != null:
		near(mp.position.x, 1280.0, 1.0, "主菜单面板在右侧（x≈1280）")
		eq(mp.main_buttons().size(), 3, "三颗主按钮：战役/合作/演义")
		eq(mp.bottom_buttons().size(), 2, "底部两颗：自定义/备战")
		ok(mp.main_buttons()[0].size.y <= 90.0, "主按钮竖直方向缩小")
		ok(mp.bottom_buttons()[0].size.y <= 130.0, "底部按钮竖直方向缩小")
		near(mp.main_buttons()[0].dash_amount(), 0.42, 0.05, "主按钮初始有短横线")
		mp.main_buttons()[0].mouse_entered.emit()
		await _wait_sec(0.22)
		ok(mp.main_buttons()[0].dash_amount() > 0.9, "悬停时左右横线渐显")
		mp.main_buttons()[0].mouse_exited.emit()
		await _wait_sec(0.22)
		near(mp.main_buttons()[0].dash_amount(), 0.42, 0.05, "移出后回到短横线")
		ok(mp.exit_button() != null, "右上角有退出 X")
		near(mp.content_alpha(), 1.0, 0.01, "入场落位后主面板内容已显示")

	var coop = screen.coop_start_panel()
	var campaign = screen.campaign_panel()
	ok(campaign != null and not campaign.visible, "主菜单页战役面板隐藏")
	ok(coop != null and not coop.visible, "主菜单页合作面板隐藏")

	# 演义 / 自定义 / 备战：不跳转
	mp.main_buttons()[2].pressed.emit()
	await process_frame
	eq(int(screen.page()), 1, "演义按钮不跳转")
	mp.bottom_buttons()[0].pressed.emit()
	mp.bottom_buttons()[1].pressed.emit()
	await process_frame
	eq(int(screen.page()), 1, "自定义/备战不跳转")

	ok(mp.corner_glow() != null, "主菜单右上角有泛光层")
	ok(mp.exit_button().get_theme_stylebox("normal") is StyleBoxEmpty, "退出按钮没有边框")
	ok(mp.corner_hit()._has_point(Vector2(130.0, 10.0)), "右上角三角形内可触发")
	ok(not mp.corner_hit()._has_point(Vector2(10.0, 130.0)), "三角形外不可触发")
	mp.corner_hit().mouse_entered.emit()
	ok(mp.corner_glow().is_hovered(), "悬停右上角三角区点亮泛光")
	mp.corner_hit().mouse_exited.emit()
	ok(not mp.corner_glow().is_hovered(), "移出三角区后泛光恢复")
	near(mp.corner_glow().hot(), 0.0, 0.001, "移出后回到初始强度")
	ok(mp.corner_glow().size.x <= 250.0, "泛光范围已缩小")

	# X → 退出确认；随后取消
	mp.corner_hit().pressed.emit()
	await process_frame
	ok(main._quit_confirm != null and main._quit_confirm.is_open(), "X 打开退出确认")
	if main._quit_confirm != null:
		main._quit_confirm.cancel()
	await _wait_sec(0.5)
	ok(main._quit_confirm == null or not main._quit_confirm.is_open(), "退出确认可取消")

	main.queue_free()
	await process_frame


func _test_campaign_entry() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_until(func(): return int(screen.page()) == 1)
	await _wait_sec(0.2)

	var mp = screen.main_panel()
	mp.main_buttons()[0].pressed.emit()
	await _wait_until(func(): return screen.menu_deck().current_page() == "campaign")
	eq(screen.menu_deck().current_page(), "campaign", "点战役进入战役地图页")
	var campaign = screen.campaign_panel()
	near(campaign.position.x, 640.0, 1.0, "战役面板占右 2/3（x≈640）")
	near(mp.position.x, 0.0, 1.0, "主菜单左移到左侧栏")
	ok(mp.is_sidebar_dimmed(), "左移的主菜单进入灰层状态")
	ok(mp.sidebar_dim() != null and mp.sidebar_dim().mouse_filter == Control.MOUSE_FILTER_STOP,
		"灰层用 STOP 挡住侧栏点击")
	eq(campaign.chapter_buttons().size(), 3, "右侧 I/II/III 三个章节按钮")
	campaign.chapter_buttons()[1].pressed.emit()
	await process_frame
	eq(campaign.selected_chapter(), 1, "章节按钮只切换选中高亮")
	eq(mp.active_index(), 0, "战役页左侧「战役」按钮保持满金选中")

	var flag = campaign.flag_button()
	ok(flag != null, "战役地图中央有旗帜")
	flag.pressed.emit()
	await _wait_until(func(): return screen.menu_deck().current_page() == "detail")
	eq(screen.menu_deck().current_page(), "detail", "点旗帜进入战役详情")
	var detail = screen.campaign_detail_panel()
	near(detail.position.x, 1280.0, 1.0, "详情面板在右侧（x≈1280）")
	eq(detail.faction_buttons().size(), 2, "demo/mt 有两个可玩阵营按钮")
	ok(detail.detail_title_text() != "", "详情有标题")
	ok(detail.detail_body_text().contains("main_test"), "详情描述来自关卡/章节数据")
	ok(campaign.is_sidebar_dimmed(), "战役面板左移后进入灰层状态")

	# 点蓝方 → 战役过渡（阵营已定）
	detail.faction_buttons()[0].pressed.emit()
	await _wait_until(func(): return main.level_transition() != null, 8000)
	var tr = main.level_transition()
	ok(tr != null, "点阵营打开战役过渡")
	if tr == null:
		main.queue_free()
		return
	eq(tr.selected_faction(), "F1", "过渡页记住详情里选的阵营")
	ok(tr.map_panel() != null and tr.info_panel() != null, "过渡页有地图/简报两块面板")
	ok(screen.menu_input_blocked(), "过渡页盖住时菜单输入被锁")
	ok(not screen.handle_back(), "过渡期间菜单返回不生效")
	eq(screen.menu_deck().current_page(), "detail", "过渡期间菜单仍停在详情页背景")
	await _wait_until(func(): return tr.ready_to_enter(), 12000)
	ok(tr.ready_to_enter(), "加载完成且进度条落画后可点击进入")
	ok(tr.hint_text() != "", "过渡页有进入提示")
	tr._enter()
	await _wait_until(func(): return main.game != null, 12000)
	ok(main.game != null, "点击进入后建出游戏场景")
	if main.game != null:
		ok(not screen.visible, "进游戏后菜单整层隐藏")
		await _wait_sec(1.0)
	main.queue_free()
	await _wait_sec(0.8)
