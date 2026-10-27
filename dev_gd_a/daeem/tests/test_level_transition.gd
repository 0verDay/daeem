## test_level_transition.gd —— 战役过渡页（两面板 + 加载 + 点击进入 + 不可取消）。
extends "res://tests/test_case.gd"

const CampaignRes := preload("res://logic/campaign.gd")
const LevelTransitionRes := preload("res://view/level_transition.gd")
const FontLoaderRes := preload("res://view/font_loader.gd")

var _entered: Array = []

func _initialize() -> void:
	_case_name = "test_level_transition"
	_run()


func _run() -> void:
	await process_frame
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var campaign = CampaignRes.load_campaign("res://data/campaigns/demo", cfg)
	ok(campaign != null, "（前提）demo 战役载入")
	if campaign == null:
		quit(1)
		return
	var level = campaign.level("mt")
	ok(level != null, "（前提）demo/mt 关载入")
	if level == null:
		quit(1)
		return

	var font := FontLoaderRes.load_font(cfg)
	var tr = LevelTransitionRes.new()
	root.add_child(tr)
	tr.setup(cfg, font, campaign, level, "F1")
	tr.enter_requested.connect(func(f): _entered.append(f))
	await process_frame
	await _wait_sec(0.2)

	eq(tr.selected_faction(), "F1", "过渡页保存详情选的阵营")
	ok(tr.map_panel() != null, "有左侧地图面板")
	ok(tr.find_child("BottomPnl", true, false) == null, "底部进度/提示不再套方形面板")
	ok(tr.info_panel() != null, "有右侧简报面板")
	ok(tr.preview() != null and tr.preview().has_map(), "左侧地图缩略图载入")
	ok(tr.info_panel().size.x > 400.0 and tr.info_panel().size.y > 400.0,
		"右侧简报面板有实际尺寸")
	near(tr.margin(), 40.0, 0.01, "过渡页外边距 40")
	near(tr.gap(), 40.0, 0.01, "左右面板间距 40")
	ok(not tr.ready_to_enter(), "加载完成前不可进入")

	var deadline := Time.get_ticks_msec() + 12000
	while Time.get_ticks_msec() < deadline and not tr.ready_to_enter():
		await process_frame
	ok(tr.ready_to_enter(), "加载完成且进度条落画后可进入")
	ok(tr.loading_done(), "加载完成标记")
	ok(tr.progress_value() >= 99.0, "进度到达 100%")
	ok(tr.hint_text().contains("点击进入"), "底部出现「点击进入」提示")
	ok(tr.hint_rect().size.x > 800.0 and tr.hint_rect().size.y > 60.0,
		"提示命中区铺在底部")

	# Esc 不可取消
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	tr._unhandled_input(ev)
	await process_frame
	ok(is_instance_valid(tr) and not tr._entering, "Esc 不会取消战役过渡")

	tr._enter()
	await process_frame
	eq(_entered.size(), 1, "点击提示发一次 enter_requested")
	if _entered.size() == 1:
		eq(String(_entered[0]), "F1", "进入信号带正确阵营")

	tr.queue_free()
	await process_frame
	await _wait_sec(0.2)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame
