## test_ai_order_panel.gd —— AI 队友浮动面板 + 合作会话（AI 模式）开局参数。
extends "res://tests/test_case.gd"

const AiPanelRes = preload("res://view/ai_order_panel.gd")
const CoopSessionRes = preload("res://view/coop_session.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const LevelRes = preload("res://logic/level.gd")

const COOP_LEVEL := "res://data/campaigns/demo/levels/02_twin_line.json"

var _solo_payload: Dictionary = {}

func _initialize() -> void:
	_case_name = "test_ai_order_panel"
	_run()


func _run() -> void:
	root.size = Vector2i(1920, 1080)
	await process_frame
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_panel(cfg)
	_test_session_ai_mode(cfg)
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _make_world(cfg):
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true,
		{"F2": LevelRes.AI_COMMANDER}, {"F2": {"difficulty": "normal"}}, 77)


func _test_panel(cfg) -> void:
	var w = _make_world(cfg)
	ok(w != null, "面板测试世界")
	if w == null:
		return
	var panel = AiPanelRes.new()
	panel.name = "AiPanel"
	root.add_child(panel)
	panel.setup(cfg, null)
	panel.bind_world(w)
	ok(panel.visible, "★ 有 commander 时面板可见")
	eq(String(panel._faction), "F2", "面板绑定 F2")
	ok(panel._buttons.size() == 4, "四个指令按钮")
	# 模拟场景层：面板只发信号，由 game_scene 转成 ai_order 命令。
	panel.order_requested.connect(func(order: String, fid: String):
		w.set_ai_directive(fid, order, -1.0, -1.0, "F1"))
	panel._on_order("develop")
	eq(String(w.ai_directive_of("F2").get("kind", "")), "develop", "面板 develop 发出")
	panel._on_order("march")
	eq(String(panel._pick_mode), "march", "面板进入 march 选点提示")
	panel.set_pick_mode("")
	panel.sync()
	ok(String(panel._lbl_directive.text).contains("指令"), "面板有指令状态行")
	ok(String(panel._lbl_army.text).contains("部队"), "面板有部队状态行")
	# 不压住右侧部队列表（SQUAD_RECT.x = 1680）与底栏（y = 820）
	ok(panel.position.x + panel.size.x <= 1680.0, "面板不覆盖右侧部队列表")
	ok(panel.position.y + panel.size.y <= 820.0, "面板不覆盖底部命令卡")
	panel._toggle_collapsed()
	ok(panel.size.y <= 60.0, "折叠后高度变小")
	panel._toggle_collapsed()
	# 没有 commander 的世界：面板自己隐藏
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	var w2 = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true)
	panel.world = w2
	panel.sync()
	ok(not panel.visible, "没有 commander 时面板隐藏")
	panel.queue_free()


func _test_session_ai_mode(cfg) -> void:
	var session = CoopSessionRes.new()
	root.add_child(session)
	session.setup(cfg)
	session.solo_started.connect(_on_solo_started)
	eq(session.mode(), "idle", "合作会话默认 idle")
	session.enter_ai_mode()
	ok(session.is_ai(), "★ 切到 AI 模式")
	ok(not session.current_entry().is_empty(), "AI 模式有默认合作地图")
	session.start()
	ok(not _solo_payload.is_empty(), "★ 会话发出 solo_started")
	eq(String(_solo_payload.get("difficulty", "")), "normal", "AI 队友固定普通难度")
	session.leave_all()
	ok(session.mode() == "idle" and not session.is_ai(), "离开后回到 idle")
	session.queue_free()


func _on_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary) -> void:
	_solo_payload = ai_setup.duplicate(true)
