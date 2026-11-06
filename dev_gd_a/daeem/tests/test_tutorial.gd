## test_tutorial.gd —— 新手教程 1（ce_xs_1）的数据 / 剧本 / 21 步流程。
##
## ★ 这里走**纯逻辑**：宿主传 null，对话自动推进；`wait_until` 由测试手动满足。
##   目的是把「关卡数据、剧情目标、人口、扩图、判胜」钉住，不依赖渲染。
extends "res://tests/test_case.gd"

const CampaignLibraryRes = preload("res://logic/campaign_library.gd")
const WorldRes = preload("res://logic/world.gd")
const StoryDirectorRes = preload("res://logic/story/story_director.gd")
const StoryRegistryRes = preload("res://logic/story/story_registry.gd")
const StoryActionsRes = preload("res://logic/story/story_actions.gd")
const MenuLayoutRes = preload("res://view/menu_deck_layout.gd")

const HERO_TAG := "tut_hero"
const RED_GENERAL_TAG := "tut_red_general"
const RED_ARCHER_TAG := "tut_red_archer"


func _initialize() -> void:
	_case_name = "test_tutorial"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_menu(cfg)
	var camp = _load_campaign(cfg)
	if camp == null:
		return
	var lv = camp.level("ce_xs_1")
	ok(lv != null, "★ 教程关卡 ce_xs_1 能载入")
	if lv == null:
		return
	_test_level_data(cfg, lv)
	var w = WorldRes.create_from_level(cfg, lv, "p1", lv.build_roster(cfg, "p1"), true)
	ok(w != null, "★ 教程关卡能建出世界")
	if w == null:
		return
	_test_flow(cfg, w)


func _load_campaign(cfg):
	var option := {}
	for item in CampaignLibraryRes.list_campaigns(cfg):
		if String((item as Dictionary).get("id", "")) == "tutorial":
			option = item
			break
	ok(not option.is_empty(), "★ 战役目录能扫到 tutorial")
	if option.is_empty():
		return null
	return CampaignLibraryRes.load_campaign_by_option(option, cfg)


func _test_menu(cfg) -> void:
	eq(String(cfg.str_val("menu.deck.main.ce_xs_1_button", "")), "ce_xs_1",
		"★ ce_xs_1 按钮文案")
	eq(String(cfg.str_val("menu.deck.main.ce_xs_2_button", "")), "ce_xs_2",
		"★ ce_xs_2 按钮文案")
	var r1 := MenuLayoutRes.screen_ce_xs_1_button(1920.0, 1080.0)
	var r2 := MenuLayoutRes.screen_ce_xs_2_button(1920.0, 1080.0)
	ok(r1.position.x == 40.0 and r2.position.x == 40.0, "★ 两个教程按钮都在左上角")
	ok(r2.position.y > r1.position.y, "★ ce_xs_2 堆在 ce_xs_1 下面")
	ok(StoryRegistryRes.has_script("tutorial"), "★ tutorial 剧本已登记")


func _test_level_data(cfg, lv) -> void:
	eq(String(lv.map_id), "ce_xs_1_a", "★ 初始地图 id")
	ok(String(lv.map_path).ends_with("ce_xs_1_a.json"), "★ A 图路径指向 ce_xs_1_a.json")
	eq(String(lv.map_path).get_file(), "ce_xs_1_a.json", "★ A 图文件正确")
	ok(bool(lv.story_driven), "★★ 教程是剧情关（不要求 objectives[]）")
	eq(String(lv.faction_config("p1").get("clan", "")), "dynasty", "★ 玩家派系 = 王朝")
	ok(lv.objectives.is_empty(), "★ 教程没有静态 objectives")
	# 数据校验：没有 block 级问题（剧情关允许没有 objectives / 大本营）。
	var blocks := 0
	for issue in lv.check(cfg.ai_factions()):
		if String((issue as Dictionary).get("sev", "")) == "block":
			blocks += 1
	eq(blocks, 0, "★★ 教程关卡没有 block 级校验问题")
	# B 图必须存在且比 A 大（扩图步骤要它）。
	var b = load("res://logic/map_data.gd").load_from(
		"res://data/maps/ce_xs_1/ce_xs_1_b.json", cfg)
	ok(b != null, "★ B 图 ce_xs_1_b.json 能载入")
	if b != null:
		ok(int(b.cols) > int(lv.map.cols), "★★ B 图比 A 图大")


func _test_flow(cfg, w) -> void:
	eq(String(w.zone_by_id(0).get("owner", "")), "", "★ c0 开局无主")
	eq(int(w.zone_by_id(0).get("population", 0)), 10, "★ c0 初始人口 10")
	eq(int(w.zone_by_id(0).get("population_cap", 0)), 12, "★ c0 人口上限 12")
	ok(w.find_base_of("p1") == null, "★ 玩家开局没有大本营")

	var d = StoryDirectorRes.new()
	ok(d.setup(null, w, "tutorial", "ce_xs_1"), "★ 教程剧本能装配")
	d.tick(0.016, [])

	var hero = _by_tag(w, HERO_TAG)
	ok(hero != null, "★ 步骤 1：开局生成将领")
	if hero != null:
		eq(String(hero.faction), "p1", "将领属于玩家阵营")
		eq(String(hero.hotkey), "1", "★★ 将领是部队 1")
		ok(not hero.story_locked, "★★ 步骤 3：对话后将领已交给玩家")
	ok(w.story_zone_glow.has(0), "★★ 步骤 6：c0 已加呼吸高亮")
	eq(String(w.story_objective.get("title", "")), "占领区划", "★ 步骤 5：目标标题")
	ok(String(w.story_objective.get("desc", "")).contains("右键地面可移动部队"),
		"★ 步骤 5：目标描述包含移动提示")

	# 7) 玩家占领 c0
	w.zone_by_id(0)["owner"] = "p1"
	d.tick(0.016, [])
	eq(String(w.story_objective.get("title", "")), "招募五队协防军",
		"★★ 步骤 8-10：目标切到招募")
	ok(float(w.resources.get("food", 0.0)) >= 500.0, "★★ 步骤 9：给了 500 粮食")
	ok(not w.story_zone_glow.has(0), "★ 步骤 7：c0 高亮已停")

	# 11) 招满 5 队（真实走 start_recruit：500 粮 + 10 人口）
	ok(hero != null, "（前提）找到教程将领")
	if hero != null:
		hero.recruit_idle_timer = 20.0
		eq(w.can_recruit("dy_guard", String(hero.id), "p1"), "",
			"★★ 教程将领在己方区划里可以招募协防军")
		var placed := 0
		for i in 5:
			if w.start_recruit("dy_guard", String(hero.id), "p1"):
				placed += 1
		eq(placed, 5, "★★ 五队协防军都能排进队列")
		for i in 30:
			w.tick(0.6)
		eq(w.retinue_of(String(hero.id), true).size(), 10,
			"★★ 一次批次生成 10 个协防军单位")
	d.tick(0.016, [])
	eq(String(w.story_objective.get("title", "")), "击败敌军",
		"★★ 步骤 11-15：招满后目标切到击败敌军")
	var red_g = _by_tag(w, RED_GENERAL_TAG)
	var red_a = _by_tag(w, RED_ARCHER_TAG)
	ok(red_g != null and red_a != null, "★★ 步骤 13：红点 = 枪将 + 弓")
	if red_g != null:
		eq(String(red_g.unit_type), "dy_spear_guard", "红点枪将兵种正确")
		eq(String(red_g.name), "协防军枪将", "红点枪将名字正确")
	if red_a != null:
		eq(String(red_a.unit_type), "dy_archer_guard", "红点弓兵种正确")
	ok(bool(w.story_input.get("block_single_right_click", false)),
		"★★ 步骤 16：已阻断单击右键")
	ok(_glow_has(w, RED_GENERAL_TAG) and _glow_has(w, RED_ARCHER_TAG),
		"★★ 步骤 16：两个敌人都在呼吸高亮")

	# 17) 击败两个敌人
	if red_g != null:
		w.story_kill_unit(red_g, true)
	if red_a != null:
		w.story_kill_unit(red_a, true)
	d.tick(0.016, [])
	eq(int(w.map.cols), 18, "★★ 步骤 18：地图扩到 ce_xs_1_b（18 列）")
	ok(not bool(w.story_input.get("block_single_right_click", false)),
		"★ 步骤 17 后恢复单击右键")
	ok(_by_tag(w, "tut_right_general") != null, "★★ 步骤 18：右侧生成枪将")
	ok(_by_tag(w, "tut_right_spear") != null, "★★ 步骤 18：右侧生成枪")
	ok(_by_tag(w, "tut_right_archer") != null, "★★ 步骤 18：右侧生成弓")
	eq(String(w.story_objective.get("title", "")), "占领区划",
		"★★ 步骤 20：目标切到占领右侧区划")
	ok(w.story_zone_glow.has(1), "★★ 步骤 20：右侧区划已加呼吸高亮")

	# 21) 占领右侧区划 → 胜利
	w.zone_by_id(1)["owner"] = "p1"
	d.tick(0.016, [])
	eq(String(w.objective_state.get("state", "")), "won", "★★ 步骤 21：占领后判胜")
	ok(not w.story_zone_glow.has(1), "★ 胜利时右侧高亮已停")


# ------------------------------------------------------------------
func _by_tag(w, tag: String):
	if w == null:
		return null
	for u in w.units:
		if u != null and u.alive and String(u.tag) == tag:
			return u
	return null


func _glow_has(w, tag: String) -> bool:
	var u = _by_tag(w, tag)
	return u != null and not (u.story_glow as Dictionary).is_empty()
