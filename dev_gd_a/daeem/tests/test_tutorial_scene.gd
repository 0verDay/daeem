## test_tutorial_scene.gd —— 教程 1 与真实 3D 场景 / HUD 的接线冒烟。
##
## 不验完整 21 步（那在 test_tutorial.gd 里走纯逻辑），只验：
##   · `game.start_level()` 能开 tutorial 关卡并自动装上剧本；
##   · 对话能经 HUD 推进；
##   · 左上角目标面板显示剧情目标；
##   · 协防军按钮高亮接口能挂到命令卡上。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuDeckRes = preload("res://view/menu_deck.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")


func _initialize() -> void:
	_case_name = "test_tutorial_scene"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	await process_frame
	var prev_anim := ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(false)
	await _test_menu(cfg)

	var option := {}
	for item in CampaignLibraryRes.list_campaigns(cfg):
		if String((item as Dictionary).get("id", "")) == "tutorial":
			option = item
			break
	ok(not option.is_empty(), "（前提）找到 tutorial 战役")
	if option.is_empty():
		ThemeRes.set_animations_enabled(prev_anim)
		_quit_case()
		return
	var camp = CampaignLibraryRes.load_campaign_by_option(option, cfg)
	var level = camp.level("ce_xs_1") if camp != null else null
	ok(level != null, "（前提）找到 ce_xs_1 关卡")
	if level == null:
		ThemeRes.set_animations_enabled(prev_anim)
		_quit_case()
		return

	var game = GameSceneRes.new()
	root.add_child(game)
	await process_frame
	ok(game.start_level(camp, level, "p1"), "★★ 教程关能进 3D 场景")
	await process_frame
	ok(game.story != null, "★★ 场景自动装上教程剧本")
	ok(game.world.story_objective.is_empty(), "（前提）剧情目标还没出现（先等对话）")

	# 推完开场两条对话（无动画时是同步的，这里仍按帧循环几次）。
	for i in 8:
		if game.hud != null and game.hud.has_dialogue():
			game.hud.advance_dialogue()
		await process_frame

	ok(not game.world.story_objective.is_empty(), "★★ 目标面板拿到剧情目标")
	if not game.world.story_objective.is_empty():
		eq(String(game.world.story_objective.get("title", "")), "占领区划",
			"★★ 第一个剧情目标是占领区划")
		eq(game.hud.objective_panel.title_text(), "※占领区划",
			"★★ 左上角目标面板显示剧情目标")
	ok(game.world.story_zone_glow.has(0), "★★ c0 呼吸高亮状态已写入世界")
	var hero = null
	for u in game.world.units:
		if u != null and String(u.tag) == "tut_hero":
			hero = u
			break
	ok(hero != null, "★★ 开局将领已生成")
	if hero != null:
		ok(not hero.story_locked, "★★ 对话后将领已经可控")

	# ★★ 控制权移交引导：没选中部队时，该将领应带引导泛光。
	ok(not game.story_guide.is_empty(), "★★ 将领引导状态已建立")
	if hero != null:
		eq(String(hero.story_glow.get("id", "")), "tut_guide_hero",
			"★★ 没选中部队时将领带引导泛光")
		game.input_ctrl.select_units([hero])
		await process_frame
		ok(game.story_guide.is_empty(), "★★ 选中部队后将领引导自动收掉")
		ok((hero.story_glow as Dictionary).is_empty(), "★★ 选中后引导泛光已清除")

	# ★★ 招募引导：没选中 → 己方部队发光；选中后没在单位页 → 单位页签高亮。
	game.input_ctrl.select_units([])
	await process_frame
	game.story_guide_selection({
		"targets": {"faction": "p1"}, "tab": "unit", "id": "tut_guide_recruit",
	})
	if hero != null:
		eq(String(hero.story_glow.get("id", "")), "tut_guide_recruit",
			"★★ 招募阶段没选中时己方部队发光")
	game.input_ctrl.select_units([hero] if hero != null else [])
	await process_frame
	await process_frame
	ok(game.hud.page_tabs.has_page("unit"), "（前提）选中单位后出现「单位」页")
	eq(String(game.hud.page_tabs.page()), "order", "（前提）当前不在单位页")
	eq(String(game.hud.page_tabs._attention_page), "unit",
		"★★ 没在单位页时页签呼吸高亮")
	var any_attention := false
	for p in game.hud.page_tabs._attention_borders:
		if p != null and p.visible:
			any_attention = true
			break
	ok(any_attention, "★★ 单位页签的呼吸描边真的显示")
	ok(game.hud.page_tabs._attention_t > 0.0, "★★ 页签呼吸在推进（没有每帧被重置）")
	game.hud.page_tabs.select_page("unit")
	await process_frame
	ok(game.story_guide.is_empty(), "★★ 选中单位页后招募引导自动收掉")
	eq(String(game.hud.page_tabs._attention_page), "", "★★ 单位页签高亮已关闭")
	game.input_ctrl.select_units([])

	# 命令卡高亮接口（教程第 10 步会用同一个方法）。
	game.hud.set_command_card_glow("dy_guard")
	eq(String(game.hud.command_card.glow_kind), "dy_guard",
		"★★ 协防军按钮高亮能挂到命令卡")
	ok(game.hud.command_card._glow_ripples.size() > 0,
		"★★ 命令卡方形波纹层已建立")
	game.hud.set_command_card_glow("")

	# 空 desc 的剧情目标只显示标题，不能 fallback 成「守住 …」。
	game.world.story_objective = {
		"kind": "story", "zone": 0, "title": "占领区划", "desc": "", "state": "running",
	}
	eq(game.hud.objective_panel.desc_text(), "",
		"★★ 空描述的剧情目标不显示「守住 …」")
	game.hud.objective_panel.sync()

	# ★★ 目标面板：打字机 + 完成划去。
	ThemeRes.set_animations_enabled(true)
	game.world.story_objective = {
		"kind": "story", "zone": 0, "title": "测试目标",
		"desc": "完整描述文本", "state": "running",
	}
	var panel = game.hud.objective_panel
	panel.sync()
	ok(panel._typing, "★★ 新目标触发了打字机")
	eq(panel._title.visible_characters, 0, "★★ 打字机从第一个字开始")
	panel._process(0.1)
	ok(panel._title.visible_characters > 0 or panel._desc.visible_characters > 0,
		"★★ 打字机逐字推进")
	game.world.story_objective["state"] = "won"
	panel.sync()
	ok(panel._striking, "★★ 目标完成触发划去动效")
	panel._process(1.0)
	ok(panel._strike_t >= 1.0, "★★ 划去动画走到终点")
	await process_frame   # 真渲染一帧，确保划线层的 _draw 不报错
	ThemeRes.set_animations_enabled(false)

	game.queue_free()
	await process_frame
	ThemeRes.set_animations_enabled(prev_anim)
	_quit_case()


func _test_menu(cfg) -> void:
	var deck = MenuDeckRes.new()
	root.add_child(deck)
	deck.position = Vector2.ZERO
	deck.size = Vector2(1920, 1080)
	deck.setup(cfg, FontLoaderRes.load_font(cfg))
	deck.finish_intro(true)
	await process_frame
	var b1: Control = deck.get_node_or_null("CeXs1Btn")
	var b2: Control = deck.get_node_or_null("CeXs2Btn")
	ok(b1 != null and b2 != null, "★★ 主菜单有 ce_xs_1 / ce_xs_2 两个按钮")
	if b1 != null:
		ok(b1.visible, "★★ ce_xs_1 在主菜单可见")
		eq(_btn_text(b1), "ce_xs_1", "★★ ce_xs_1 按钮文案")
	if b2 != null:
		ok(b2.visible, "★★ ce_xs_2 在主菜单可见")
		eq(_btn_text(b2), "ce_xs_2", "★★ ce_xs_2 按钮文案")
	deck.queue_free()
	await process_frame


## MenuTextButton 的文案在子 Label「Text」里（控件本身没有 text 属性）。
func _btn_text(b: Control) -> String:
	var lab: Label = b.get_node_or_null("Text") as Label
	return String(lab.text) if lab != null else ""


func _quit_case() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
