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
	# ★★ 三个测试战役：简单 / 中等 / 困难，各自指向 demo 里那一关。
	for lid in ["ai_test_easy", "ai_test_normal", "ai_test_hard"]:
		var ch := _find_chapter(campaigns, lid)
		ok(not ch.is_empty(), "★ 菜单里有 %s 这一章" % lid)
		if ch.is_empty():
			continue
		var brief := BriefRes.resolve(cfg, ch)
		ok(not bool(brief.get("placeholder", true)), "%s 不是占位" % lid)
		eq((brief.get("entries", []) as Array).size(), 2,
			"%s 有两个可玩阵营（上方 / 下方）" % lid)
		ok(brief.get("map", null) != null, "%s 有地图数据" % lid)


func _find_chapter(campaigns: Array, level_id: String) -> Dictionary:
	for raw in campaigns:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		for item in ((raw as Dictionary).get("chapters", []) as Array):
			if typeof(item) == TYPE_DICTIONARY \
					and String((item as Dictionary).get("level_id", "")) == level_id:
				return item
	return {}


func _find_flag(flags: Array, subtitle: String):
	for f in flags:
		if f != null and String((f as Object).subtitle_text()) == subtitle:
			return f
	return null


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
	ok(campaign.find_child("MapBackdropClip", true, false) == null, "战役底图已移除")
	eq(screen.main_panel().active_index(), 0, "战役页左侧「战役」按钮保持选中")
	ok(screen.main_panel().active_marker() != null, "选中标记层存在")
	if screen.main_panel().active_marker() != null:
		eq(screen.main_panel().active_marker().text(), "战役", "选中标记文字")
		ok(screen.main_panel().active_marker().dash_amount() > 0.99, "选中后左右横线保持")

	# ★★ 一面旗 = 一个真实战役（c1 main_test + 三个测试战役）。
	var flags: Array = campaign.flag_buttons()
	ok(flags.size() >= 4, "战役地图上至少 4 面旗（实际 %d）" % flags.size())
	for f in flags:
		eq(String((f as Object).kind()), "level", "每面旗都是关卡旗")
		ok((f as Control).size.x <= 190.0, "关卡旗帜是小型按钮")

	var main_flag = _find_flag(flags, "main_test")
	ok(main_flag != null, "有 main_test 的旗子")
	if main_flag != null:
		var cloth: Rect2 = main_flag._cloth_rect()
		ok(main_flag._has_point(cloth.get_center()), "旗面可点击")
		ok(not main_flag._has_point(Vector2(2.0, 2.0)), "透明边距不响应点击")
		main_flag.pressed.emit()
		ok(await _wait_page(deck, "detail"), "点 main_test 旗进入详情")
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

	# ★★ 三个测试战役：点「简单」旗 → 详情里两个阵营按钮，文案带上下。
	var easy_flag = _find_flag(flags, "简单")
	ok(easy_flag != null, "有「简单」测试战役的旗子")
	if easy_flag != null:
		easy_flag.pressed.emit()
		ok(await _wait_page(deck, "detail"), "点简单旗进入详情")
		eq(detail.faction_buttons().size(), 2, "测试战役详情有两个阵营按钮")
		ok(detail.detail_body_text().contains("简单"), "详情描述写明难度")
		var names: Array = []
		for fb in detail.faction_buttons():
			var nl = (fb as Control).get_node_or_null("FactionName")
			if nl != null:
				names.append(String(nl.get("text")))
		var joined := " ".join(names)
		ok(joined.contains("上方"), "阵营按钮包含「上方」（%s）" % joined)
		ok(joined.contains("下方"), "阵营按钮包含「下方」（%s）" % joined)
		ok(screen.handle_back(), "测试战役详情返回被受理")
		ok(await _wait_page(deck, "campaign"), "测试战役详情 → 战役")

	ok(screen.handle_back(), "战役返回被受理")
	ok(await _wait_page(deck, "main"), "战役 → 主菜单")

	main.queue_free()
	await _wait_sec(0.2)
