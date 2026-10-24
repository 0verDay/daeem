## test_ai_order_panel.gd —— AI 队友浮动面板 + 合作大厅「真人 / AI」二选一。
extends "res://tests/test_case.gd"

const AiPanelRes = preload("res://view/ai_order_panel.gd")
const CoopLobbyRes = preload("res://view/coop_lobby.gd")
const CoopLayoutRes = preload("res://view/coop_layout.gd")
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
	_test_lobby_ai_mode(cfg)
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


func _test_lobby_ai_mode(cfg) -> void:
	var lobby = CoopLobbyRes.new()
	root.add_child(lobby)
	lobby.setup(cfg, null)
	lobby.solo_started.connect(_on_solo_started)
	ok(not lobby._ai_mode, "大厅默认真人模式")
	lobby._set_ai_mode(true)
	ok(lobby._ai_mode, "切到 AI 模式")
	ok(lobby._ai_map_btn != null and lobby._ai_map_btn.visible, "AI 模式显示选择地图")
	ok(lobby._ai_diff_btn != null and lobby._ai_diff_btn.visible, "AI 模式显示难度")
	# 模式条放在席位与大厅面板之间：不压右侧大厅面板、也不压右上角返回键。
	ok((lobby._ai_mode_btns[1] as Control).position.x < 1372.0, "AI 模式按钮不压大厅面板")
	ok(lobby._ai_diff_btn.position.x < 1372.0, "难度按钮不压大厅面板 / 返回键")
	if not lobby._room_only_nodes.is_empty():
		ok(not (lobby._room_only_nodes[0] as CanvasItem).visible, "AI 模式隐藏房间列表")
	lobby._cycle_ai_difficulty()
	ok(lobby._ai_diff == "easy" or lobby._ai_diff == "hard", "难度可切换")
	lobby._start_ai_solo()
	ok(not _solo_payload.is_empty(), "★ 大厅发出 solo_started")
	eq(String(_solo_payload.get("difficulty", "")), String(lobby._ai_diff), "开局带难度")
	lobby._set_ai_mode(false)
	ok(not lobby._ai_mode, "切回真人模式")
	lobby.queue_free()


func _on_solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary) -> void:
	_solo_payload = ai_setup.duplicate(true)
