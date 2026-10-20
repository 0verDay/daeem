## test_coop_objective.gd —— 合作 M12.1：顶部目标条的数据、几何与 HUD 接线。
##
## 不截图：只验「标题 / 进度 / 胜负原因」和「真的画过一帧」。
extends "res://tests/test_case.gd"

const CampaignRes = preload("res://logic/campaign.gd")
const WorldRes = preload("res://logic/world.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const ObjectivePanelRes = preload("res://view/objective_panel.gd")
const UiLayoutRes = preload("res://view/ui_layout.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")

const DEMO_DIR := "res://data/campaigns/demo"
const LEVEL_ID := "02_twin_line"

func _initialize() -> void:
	_case_name = "test_coop_objective"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	await _test_panel_data(cfg)
	await _test_mt_capture_pending(cfg)
	await _test_hud_wiring(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _test_panel_data(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	ok(camp != null, "（前提）样例战役能载入")
	if camp == null:
		return
	var lv = camp.level(LEVEL_ID)
	ok(lv != null, "（前提）合作关能载入")
	if lv == null:
		return
	var w = WorldRes.create_from_level(cfg, lv, "F1", lv.coop_roster(), true)
	ok(w != null, "（前提）合作关世界能建出来")
	if w == null:
		return

	var panel = ObjectivePanelRes.new()
	root.add_child(panel)
	panel.setup(cfg, w, FontLoaderRes.load_font(cfg))
	await process_frame

	ok(panel.visible, "★ 有目标时目标栏显示")
	v2_near(panel.position, UiLayoutRes.OBJECTIVE_RECT.position, 1.0,
		"目标栏在左上角 (20,16)")
	ok(panel.size.x >= UiLayoutRes.OBJECTIVE_RECT.size.x - 1.0,
		"目标栏宽度至少 560（实际 %s）" % str(panel.size))
	eq(panel.title_text(), "※坚守", "★ 第一行是「※」+ 目标简称「坚守」")
	ok(panel.desc_text().contains("守住"), "第二行写「守住 …」")
	ok(panel.desc_text().contains("c1"), "第二行带区划名 c1")
	ok(panel.desc_text().begins_with("- "), "第二行以「- 」开头")
	ok(panel.desc_text().contains("已守"), "开局描述里带「已守 …」进度")
	near(panel.progress_ratio(), 0.0, 0.001, "开局进度 0")
	ok(panel.state_text() == "", "进行中不显示状态字")

	# ★ 简称 / 描述可被关卡数据覆盖（objectives[].short / desc）
	w.level.objectives[0]["short"] = "死守"
	panel.sync()
	eq(panel.title_text(), "※死守", "★ objectives[].short 覆盖目标简称")
	w.level.objectives[0].erase("short")
	w.level.objectives[0]["desc"] = "剩余 {held}/{sec} 秒（{zone}）"
	panel.sync()
	eq(panel.desc_text(), "- 剩余 0/120 秒（c1）", "★ 自由描述 + 占位符替换")
	w.level.objectives[0].erase("desc")
	panel.sync()

	w.objective_state["held"] = 60.0
	panel.sync()
	near(panel.progress_ratio(), 0.5, 0.001, "★ 守到 60/120 秒时进度 = 0.5")
	ok(panel.desc_text().contains("60"), "描述里的进度跟着走到 60")

	w.objective_state["held"] = 120.0
	w.objective_state["state"] = ObjectiveRes.STATE_WON
	panel.sync()
	eq(panel.state_text(), "本关守住！", "★ 胜利状态字")
	near(panel.progress_ratio(), 1.0, 0.001, "胜利时进度满")
	ok(panel.desc_text().contains("本关守住"), "★ 胜利后描述里写「本关守住」")

	w.objective_state["state"] = ObjectiveRes.STATE_LOST
	w.objective_state["reason"] = ObjectiveRes.R_OBJECTIVE_LOST
	panel.sync()
	ok(panel.desc_text().contains("目标区划失守"),
		"★ 失败时描述里写原因「目标区划失守」")
	ok(panel.state_text().contains("失守"), "★ 失败状态字")

	panel.sync()
	await process_frame
	ok(panel.refresh_count > 0, "★ 目标栏真的刷新过（不需要截图）")

	# 没有目标（自由对战 / 老路径）→ 整块隐藏
	w.objective_state = {}
	panel.sync()
	ok(not panel.visible, "没有 objective_state 时目标条隐藏")

	panel.queue_free()


## ★★ 回归（用户报的 bug）：main_test（`demo` 的 `mt`）选 **F2** 时，目标条一进关就写「已占领」。
##
## 那一关 F2 的目标是「占领囊关东门」（c8），而 c8 开局归 `sj`（F1 的盟友）。
## 修好之后：第一行仍是「※攻占」，但进度写「等待占领」、右侧没有状态字、进度是 0。
func _test_mt_capture_pending(cfg) -> void:
	var camp = CampaignRes.load_campaign(DEMO_DIR, cfg)
	var lv = camp.level("mt") if camp != null else null
	ok(lv != null, "（前提）mt 关卡能载入")
	if lv == null:
		return
	var w = WorldRes.create_from_level(cfg, lv, "F2", lv.build_roster(cfg, "F2"), true)
	ok(w != null, "（前提）mt 选 F2 能建出世界")
	if w == null:
		return

	var panel = ObjectivePanelRes.new()
	root.add_child(panel)
	panel.setup(cfg, w, FontLoaderRes.load_font(cfg))
	await process_frame

	ok(panel.visible, "★ 选 F2 进 mt：目标栏显示")
	eq(panel.title_text(), "※攻占", "第一行是「※攻占」")
	ok(panel.desc_text().contains("占领"), "描述是「占领 …」")
	ok(panel.desc_text().contains("囊关东门"), "描述带区划名（囊关东门）")
	eq(panel.progress_text(), "等待占领", "★★ 开局写「等待占领」（原 bug：这里写「已占领」）")
	ok(panel.desc_text().contains("等待占领"), "★★ 描述里是「等待占领」")
	eq(panel.state_text(), "", "★★ 开局没有「已占领」状态字（原 bug 的症状）")
	near(panel.progress_ratio(), 0.0, 0.001, "开局进度 0（不是满条）")
	panel.queue_free()


func _test_hud_wiring(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var main_node = (packed as PackedScene).instantiate()
	root.add_child(main_node)
	await process_frame
	main_node._on_level_entry_pressed("demo", LEVEL_ID)
	await process_frame
	await process_frame
	var game = main_node.game
	ok(game != null, "★ 合作关能从主流程进游戏")
	if game == null:
		main_node.queue_free()
		return
	ok(game.hud != null, "HUD 建出来了")
	if game.hud == null:
		main_node.queue_free()
		return
	var panel = game.hud.objective_panel
	ok(panel != null, "★ HUD 里挂了目标条")
	if panel != null:
		ok(panel.visible, "★ 进合作关之后目标栏显示")
		eq(panel.title_text(), "※坚守", "HUD 里的第一行是「※坚守」")
		ok(panel.desc_text().contains("守住"), "HUD 里的描述是「守住 …」")
		ok(game.hud.get_node_or_null("HudRoot/ObjectivePanel") != null,
			"节点树里有 HudRoot/ObjectivePanel")
	main_node.queue_free()
