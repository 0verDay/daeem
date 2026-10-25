## test_coop_entry.gd —— M12.4：主界面的合作入口。
##
## 现在主界面正中是 test_1 / ai_test / ai_test_2 / ai_test_battle / ai_test_hz：
##   · ai_test_hz 是「合作 + AI 队友」直开入口：玩家第 1 席位（F1），commander 接管第 2 席位（F2）；
##   · 它**不**打开合作大厅，也不先选地图 —— 关卡就是 demo / dscj（合作关）。
##   · 合作大厅本身仍然是右下角「合作模式」那颗按钮 / `open_coop_panel()` 的入口，
##     这里顺手把大厅的版式契约继续钉住（原来那段断言不能因为 test_2 删了就丢掉）。
extends "res://tests/test_case.gd"

const StartScreenRes = preload("res://view/start_screen.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")

func _initialize() -> void:
	_case_name = "test_coop_entry"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	root.size = Vector2i(1920, 1080)
	var screen = StartScreenRes.new()
	root.add_child(screen)
	await process_frame
	screen.setup(cfg, FontLoaderRes.load_font(cfg))
	screen.show_page(1)
	await _wait(10)

	var buttons: Array = screen.test_buttons()
	eq(buttons.size(), 5,
		"（前提）主界面是五颗按钮（test_1 + ai_test / ai_test_2 + ai_test_battle / ai_test_hz）")
	if buttons.size() < 5:
		screen.queue_free()
		quit(1)
		return

	# ---- 1) ai_test_battle：direct 入口只发 direct_level_requested（不进过渡画面） ----
	var direct_calls: Array = []
	screen.direct_level_requested.connect(func(cid: String, lid: String):
		direct_calls.append({"campaign": cid, "level": lid}))
	var battle: Button = null
	for b in buttons:
		if String((b as Button).text) == "ai_test_battle":
			battle = b
	ok(battle != null, "★ 找得到 ai_test_battle 那颗按钮")
	if battle != null:
		battle.pressed.emit()
	await _wait(5)
	eq(direct_calls.size(), 1, "★★ 按 ai_test_battle 只发一次直开请求")
	if direct_calls.size() == 1:
		eq(String((direct_calls[0] as Dictionary).get("campaign", "")), "demo",
			"★ 直开局：战役 = demo")
		eq(String((direct_calls[0] as Dictionary).get("level", "")), "ai_test_battle",
			"★★ 直开局：关卡 = ai_test_battle（玩家 p2 vs p1 commander）")

	# ---- 2) ai_test_hz 的数据：合作 + AI 队友，且指向 demo / dscj ----
	var hz_entry: Dictionary = {}
	for item in screen._test_entries():
		if String((item as Dictionary).get("label", "")) == "ai_test_hz":
			hz_entry = item
	ok(not hz_entry.is_empty(), "★ 主界面有 ai_test_hz 按钮")
	eq(String(hz_entry.get("campaign", "")), "demo", "★ ai_test_hz 指向 demo 战役")
	eq(String(hz_entry.get("level", "")), "dscj", "★★ ai_test_hz 用 dscj 关卡（地图 = dscj）")
	ok(bool(hz_entry.get("coop_ai", false)),
		"★★ ai_test_hz 带 coop_ai 标记（玩家 p1 + commander p2）")

	# ---- 3) 按下去 = 直接发 coop_solo_started，不打开合作大厅 ----
	var coop_calls: Array = []
	screen.coop_solo_started.connect(
		func(cid: String, lid: String, ai_setup: Dictionary):
			coop_calls.append({"campaign": cid, "level": lid, "ai": ai_setup}))
	var target: Button = null
	for b in buttons:
		if String((b as Button).text) == "ai_test_hz":
			target = b
	ok(target != null, "★ 找得到 ai_test_hz 那颗按钮")
	if target != null:
		target.pressed.emit()
	await _wait(5)
	eq(coop_calls.size(), 1, "★★ 按 ai_test_hz 只发一次合作 AI 队友开局请求")
	if coop_calls.size() == 1:
		var call: Dictionary = coop_calls[0]
		eq(String(call.get("campaign", "")), "demo", "★ 合作 AI 队友局：战役 = demo")
		eq(String(call.get("level", "")), "dscj", "★★ 合作 AI 队友局：关卡 = dscj")
		ok(String((call.get("ai", {}) as Dictionary).get("difficulty", "")) != "",
			"★ 带了 AI 难度（没有难度参数 start_coop_solo 会退回 normal）")
	ok(screen._chrome != null and screen._chrome.coop_lobby() == null,
		"★★ ai_test_hz 不打开合作大厅（直接本地开局）")

	# ---- 4) 合作大厅本身还在：手动打开，继续钉版式 ----
	screen.open_coop_panel()
	var lobby = null
	for i in 120:
		await process_frame
		if screen._chrome != null:
			lobby = screen._chrome.coop_lobby()
		if lobby != null:
			break
	ok(screen._chrome != null, "（前提）主界面外壳在")
	ok(lobby != null, "★ 合作大厅还能从合作模式入口打开")
	if lobby != null:
		ok(lobby.find_child("RoomList", true, false) != null, "大厅里有房间列表")
		ok(lobby.find_child("CodeEdit", true, false) != null, "大厅里有房间码输入框")
		ok(lobby.find_child("ActionBtn", true, false) != null, "大厅里有进入 / 创建按钮")
		ok(lobby.find_child("RoomPanel", true, false) != null, "大厅里有房间配置面板")
		ok(lobby.find_child("MapPanel", true, false) != null, "大厅里有地图选择面板")
		var lp = lobby.find_child("LobbyPanel", true, false)
		ok(lp != null, "大厅面板在")
		if lp != null:
			v2_near((lp as Control).global_position, Vector2(1372, 140), 2.0,
				"★ 大厅面板右缘与返回按钮对齐（宽度 500）")
		var back = lobby.get_parent().find_child("BackBtn", true, false)
		ok(back != null, "大厅返回按钮在")
		if back != null:
			await _wait(5)
			near((back as Control).global_position.x, 1712.0, 2.0,
				"★ 大厅返回按钮与战役面板同一距离（不贴屏幕边）")
			near((back as Control).global_position.y, 48.0, 2.0,
				"★ 返回按钮上方也留出战菜单同样的边距")
			if lp != null:
				near((lp as Control).global_position.x + (lp as Control).size.x,
					(back as Control).global_position.x + (back as Control).size.x, 2.0,
					"★ 大厅面板右缘 == 返回按钮右缘")

	screen.queue_free()
	await process_frame
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _wait(frames: int) -> void:
	for i in frames:
		await process_frame
