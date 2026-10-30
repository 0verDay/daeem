## test_menu_glow_fade.gd —— 泛光的渐显 / 渐隐。
##
## 1) 入场：主菜单四角泛光从 0 渐显到 1（不是一下点亮）；
## 2) 切页：上一页渐隐、当前聚焦页渐显（主菜单 → 战役 → 详情 → 返回都走一遍）；
## 3) 顶部半圆泛光归同一组，但标题文字本身不跟着变淡；
## 4) 动效关闭：直接到位，不留半透明的中间态。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const ThemeRes := preload("res://view/theme.gd")


func _initialize() -> void:
	_case_name = "test_menu_glow_fade"
	_run()


func _run() -> void:
	await process_frame
	await _test_intro_fade()
	await _test_page_switch()
	await _test_animations_off()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 入场
# ------------------------------------------------------------------

func _test_intro_fade() -> void:
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.2)
	var screen = main.start_screen
	var mp = screen.main_panel()
	ok(mp != null, "主菜单面板存在")
	if mp == null:
		main.queue_free()
		return

	ok(screen.dismiss_intro(), "入场页被点击受理")
	await process_frame
	var art = screen.art()
	ok(art != null, "左侧雕版控件存在")
	if ThemeRes.animations_enabled():
		near(mp.glow_alpha(), 0.0, 0.05, "入场开头：四角泛光是灭的")
		await _wait_sec(0.14)
		# ★ 用户口径：落位期间只做「logo/游戏名右移 + 面板渐显」，
		#   四角泛光与左侧雕版整段都不许露。
		near(mp.glow_alpha(), 0.0, 0.02, "落位中途：四角泛光仍然全灭")
		near(art.modulate.a, 0.0, 0.02, "落位中途：左侧雕版一点不露")

	await _wait_start_page(screen, 1)
	# 落位刚结束：两者**同时**从 0 起步，而不是其中一个已经满了
	if ThemeRes.animations_enabled() and art != null:
		await _wait_sec(0.12)
		var g1: float = mp.glow_alpha()
		var a1: float = art.modulate.a
		ok(g1 > 0.02 and g1 < 0.98, "落位刚结束：四角泛光正在渐显（%f）" % g1)
		ok(a1 > 0.02 and a1 < 0.98, "落位刚结束：左侧雕版正在渐显（%f）" % a1)
		near(a1, g1, 0.02, "泛光与雕版同一条曲线（同时渐显，不是一先一后）")

	await _wait_sec(0.9)
	near(mp.glow_alpha(), 1.0, 0.01, "入场收尾：四角泛光到满")
	near(mp.corner_glow().modulate.a, 1.0, 0.01, "入场收尾：右上角泛光到满")
	for i in 3:
		near(mp.corner_glow_at(i).modulate.a, 1.0, 0.01,
			"入场收尾：第 %d 块角泛光到满" % i)
	if art != null:
		near(art.modulate.a, 1.0, 0.01, "入场收尾：左侧雕版到满")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 切页
# ------------------------------------------------------------------

func _test_page_switch() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var deck = screen.menu_deck()
	var mp = screen.main_panel()
	var campaign = screen.campaign_panel()
	var detail = screen.campaign_detail_panel()
	var art = screen.art()

	near(mp.glow_alpha(), 1.0, 0.01, "主菜单：四角泛光满亮")
	near(campaign.glow_alpha(), 0.0, 0.01, "主菜单：战役页泛光全灭")

	# 主菜单 → 战役
	mp.main_buttons()[0].pressed.emit()
	if ThemeRes.animations_enabled():
		await _wait_sec(0.08)
		var mid: float = mp.glow_alpha()
		ok(mid > 0.0 and mid < 1.0, "切战役：上一页泛光正在渐隐（%f）" % mid)
		# ★ 左侧雕版必须**跟着主面板一起横移**（不是原地淡出）：
		#   它的右缘始终贴着主面板的左缘 ⇒ x == 主面板.x − 雕版宽
		if art != null:
			near(art.position.x, mp.position.x - art.size.x, 2.0,
				"切战役：雕版右缘贴着主面板左缘（一起左移）")
			ok(art.position.x < -1.0, "切战役：雕版确实已经往左移了（%f）" % art.position.x)
	ok(await _wait_page(deck, "campaign"), "进入战役页")
	await _wait_sec(0.15)
	if art != null:
		near(art.position.x, -art.size.x, 2.0, "战役页：雕版整幅滑出屏幕左边")
		near(art.modulate.a, 1.0, 0.01, "战役页：雕版不是靠淡出藏起来的（透明度仍是 1）")
	near(mp.glow_alpha(), 0.0, 0.01, "战役页：上一页泛光已灭")
	near(mp.corner_glow().modulate.a, 0.0, 0.01, "战役页：右上角泛光也灭")
	for i in 3:
		near(mp.corner_glow_at(i).modulate.a, 0.0, 0.01, "战役页：四角泛光全灭：%d" % i)
	near(campaign.glow_alpha(), 1.0, 0.01, "战役页：当前页泛光满亮")

	# 顶部半圆泛光归这一组，但标题文字自己不跟着变淡
	var hdr = campaign.glow_header()
	near(hdr.glow_alpha(), 1.0, 0.01, "战役页：标题半圆光满亮")
	near(hdr.modulate.a, 1.0, 0.01, "战役页：标题控件本身不被压暗")

	# 战役 → 详情
	campaign.flag_buttons()[0].pressed.emit()
	ok(await _wait_page(deck, "detail"), "进入详情页")
	await _wait_sec(0.15)
	near(campaign.glow_alpha(), 0.0, 0.01, "详情页：战役页泛光已灭")
	near(detail.glow_alpha(), 1.0, 0.01, "详情页：当前页泛光满亮")

	# 详情 → 战役 → 主菜单
	ok(screen.handle_back(), "详情页返回被受理")
	ok(await _wait_page(deck, "campaign"), "回到战役页")
	await _wait_sec(0.15)
	near(campaign.glow_alpha(), 1.0, 0.01, "回到战役页：泛光重新渐显")
	near(detail.glow_alpha(), 0.0, 0.01, "回到战役页：详情页泛光已灭")

	ok(screen.handle_back(), "战役页返回被受理")
	ok(await _wait_page(deck, "main"), "回到主菜单")
	await _wait_sec(0.15)
	near(mp.glow_alpha(), 1.0, 0.01, "回到主菜单：四角泛光重新渐显")
	near(campaign.glow_alpha(), 0.0, 0.01, "回到主菜单：战役页泛光已灭")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 动效关闭
# ------------------------------------------------------------------

func _test_animations_off() -> void:
	ThemeRes.set_animations_enabled(false)
	var main = await _spawn_main_instant()
	if main != null:
		var screen = main.start_screen
		var deck = screen.menu_deck()
		deck.goto_campaign()
		eq(deck.current_page(), "campaign", "动效关闭：goto_campaign 同步到位")
		near(screen.main_panel().glow_alpha(), 0.0, 0.001, "动效关闭：上一页泛光瞬间熄灭")
		near(screen.campaign_panel().glow_alpha(), 1.0, 0.001, "动效关闭：当前页泛光瞬间点亮")
		deck.goto_main()
		eq(deck.current_page(), "main", "动效关闭：回主菜单同步到位")
		near(screen.main_panel().glow_alpha(), 1.0, 0.001, "动效关闭：主菜单泛光瞬间点亮")
		near(screen.campaign_panel().glow_alpha(), 0.0, 0.001, "动效关闭：战役页泛光瞬间熄灭")
		main.queue_free()
		await process_frame
	ThemeRes.set_animations_enabled(true)


# ------------------------------------------------------------------
# 脚手架
# ------------------------------------------------------------------

func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.15)
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_start_page(screen, 1)
	# ★ 落位结束后，泛光与雕版还要 0.6s（menu.plate.fade_in_sec）才渐显到满 ——
	#   这里必须等它走完，否则后面「主菜单：四角泛光满亮」读到的是中间值。
	await _wait_sec(0.8)
	return main


func _spawn_main_instant():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	var screen = main.start_screen
	screen.dismiss_intro()
	await process_frame
	return main


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


## 等入场页切到主菜单（start_screen 的 page，不是 deck 的 page）。
func _wait_start_page(screen, page: int, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if int(screen.page()) == page:
			return true
		await process_frame
	return int(screen.page()) == page


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()
