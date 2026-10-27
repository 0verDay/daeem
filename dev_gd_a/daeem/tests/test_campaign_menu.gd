## test_campaign_menu.gd —— 战役地图 / 章节选中反馈 / 详情与占位兜底。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const CampaignMenuDbRes := preload("res://logic/campaign_menu_db.gd")
const BriefRes := preload("res://logic/campaign_menu_brief.gd")

func _initialize() -> void:
	_case_name = "test_campaign_menu"
	_run()


func _run() -> void:
	await process_frame
	var cfg = require_config()
	if cfg != null:
		_test_data(cfg)
	await _test_pages()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _test_data(cfg) -> void:
	var campaigns := CampaignMenuDbRes.load_campaigns()
	ok(campaigns.size() >= 3, "菜单数据有三份战役")
	if campaigns.size() >= 1:
		var c1: Dictionary = campaigns[0]
		eq(String(c1.get("key", "")), "c1", "第一份是 c1")
		var chapters: Array = c1.get("chapters", [])
		ok(not chapters.is_empty(), "c1 至少有一章")
		if not chapters.is_empty():
			var brief := BriefRes.resolve(cfg, chapters[0])
			ok(not bool(brief.get("placeholder", true)), "c1 第一章不是占位")
			eq((brief.get("entries", []) as Array).size(), 2, "demo/mt 有两个可玩阵营")
			ok(brief.get("map", null) != null, "demo/mt 有地图数据")


func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_page(screen.menu_deck(), "main")
	await _wait_sec(0.9)
	return main


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()


func _test_pages() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var campaign = screen.campaign_panel()
	var detail = screen.campaign_detail_panel()

	screen.main_panel().main_buttons()[0].pressed.emit()
	ok(await _wait_page(deck, "campaign"), "进入战役页")
	eq(campaign.chapter_buttons().size(), 3, "I/II/III 三个章节按钮")
	eq(campaign.selected_chapter(), 0, "默认选中 I")
	ok(campaign.find_child("MapBackdropClip", true, false) == null, "战役底图已移除")
	eq(screen.main_panel().active_index(), 0, "战役页左侧「战役」按钮保持选中")
	ok(screen.main_panel().active_marker() != null, "选中标记层存在")
	if screen.main_panel().active_marker() != null:
		eq(screen.main_panel().active_marker().text(), "战役", "选中标记文字")
		ok(screen.main_panel().active_marker().dash_amount() > 0.99, "选中后左右横线保持")
	ok(campaign.flag_button() != null, "地图中央有旗帜")
	if campaign.flag_button() != null:
		ok(campaign.flag_button().size.x <= 190.0, "关卡旗帜缩成小型按钮")
		eq(campaign.flag_button().kind(), "level", "旗帜是关卡旗帜")
		var cloth: Rect2 = campaign.flag_button()._cloth_rect()
		ok(campaign.flag_button()._has_point(cloth.get_center()), "旗面可点击")
		ok(not campaign.flag_button()._has_point(Vector2(2.0, 2.0)), "透明边距不响应点击")

	var chapter_before: Dictionary = campaign.current_chapter().duplicate(true)
	campaign.chapter_buttons()[1].pressed.emit()
	await process_frame
	eq(campaign.selected_chapter(), 1, "点 II 只切选中")
	eq(campaign.current_chapter(), chapter_before, "点章节不换当前关卡数据")
	eq(campaign.flag_button().kind(), "level", "点章节不换旗帜类型")

	campaign.flag_button().pressed.emit()
	ok(await _wait_page(deck, "detail"), "点旗帜进入详情")
	near(detail.position.x, 1280.0, 1.0, "详情面板在右")
	near(campaign.position.x, 0.0, 1.0, "战役面板左移")
	ok(campaign.is_sidebar_dimmed(), "左移的战役面板有灰层")
	near(screen.main_panel().position.x, -640.0, 1.0, "进详情时主菜单跟着向左滑出")
	ok(not screen.main_panel().visible, "详情页主菜单离场")
	eq(detail.faction_buttons().size(), 2, "详情生成两个阵营按钮")
	ok(detail.detail_title_text() != "", "详情标题非空")
	ok(detail.detail_body_text().contains("main_test"), "详情描述来自数据")
	ok(detail.thumb().has_map(), "详情缩略图有地图")

	# 占位兜底：直接喂一个空章节，应该只有一个禁用按钮
	detail.set_chapter({"name": "占位", "description": "", "campaign_id": "", "level_id": ""})
	await process_frame
	eq(detail.faction_buttons().size(), 1, "占位章节只有一个按钮")
	if detail.faction_buttons().size() == 1:
		var b: Button = detail.faction_buttons()[0]
		ok(b.disabled, "占位章节按钮是禁用态")
		eq(b.text, "暂不可用", "占位章节按钮文案")

	ok(screen.handle_back(), "详情返回被受理")
	ok(await _wait_page(deck, "campaign"), "详情 → 战役")
	ok(not campaign.is_sidebar_dimmed(), "战役回到右侧后灰层关闭")
	near(screen.main_panel().position.x, 0.0, 1.0, "返回战役时主菜单跟着滑回左侧栏")
	ok(screen.main_panel().visible, "战役页主菜单可见且战役按钮选中")
	ok(screen.handle_back(), "战役返回被受理")
	ok(await _wait_page(deck, "main"), "战役 → 主菜单")

	main.queue_free()
	await _wait_sec(0.2)
