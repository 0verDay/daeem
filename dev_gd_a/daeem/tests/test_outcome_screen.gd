## test_outcome_screen.gd —— 胜利 / 失败结算画面（本轮新增）
##
## 盯四件事：
##   1. 两种结果各自的**终态**（文案、宝石 / 裂纹、横幅拉开、提示可点）；
##   2. 「点击任意处 → 提示渐隐、三颗按钮渐显」这条交互（不是自动出现）；
##   3. 游戏内的 Ctrl+1 / Ctrl+3 / Ctrl+W / Ctrl+L：Ctrl+1 加资源、Ctrl+3 升大本营，Ctrl+W / Ctrl+L
##      **改写目标状态** + 弹出结算 + 停战；
##   4. `level_end` 事件（单机 / 合作客机都走它）也能弹出结算。
##
## ★ 动效在本文件里统一关掉（`ThemeRes.set_animations_enabled(false)`）：
##   无头下等 Tween 既慢又不稳定；这里验的是**状态与接线**，观感交给
##   `tests/bench_outcome_shot.gd` 的真实渲染截图。
extends "res://tests/test_case.gd"

const OutcomeOverlayRes = preload("res://view/outcome_overlay.gd")
const GameSceneRes = preload("res://view/game_scene3d.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const ThemeRes = preload("res://view/theme.gd")

var _continue_hits: int = 0


func _initialize() -> void:
	_case_name = "test_outcome_screen"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	ThemeRes.set_animations_enabled(false)
	await _test_win_overlay(cfg)
	await _test_lose_overlay(cfg)
	await _test_game_hotkeys(cfg)
	await _test_level_end_event(cfg)
	await _test_main_return_flow(cfg)
	ThemeRes.set_animations_enabled(true)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _new_overlay(cfg, result: String):
	var o = OutcomeOverlayRes.new()
	root.add_child(o)
	o.setup(cfg, FontLoaderRes.load_font(cfg), result)
	return o


func _test_win_overlay(cfg) -> void:
	var o = _new_overlay(cfg, "win")
	await process_frame
	ok(o.is_open(), "setup 之后结算层是打开的")
	eq(o.result(), "win", "结果是 win")
	eq(o.word_text(), String(cfg.str_val("outcome.win_word", "胜利")), "横幅主字是「胜利」")
	ok(o.hint_text().contains("点击任意处"), "横幅下方有「点击任意处」提示")
	ok(o.ready_for_click(), "★ 提示出现后可以点击任意处")
	ok(not o.buttons_revealed(), "★ 三颗按钮一开始不出现（等玩家点一下）")
	eq(o.button_labels(), ["观察", "统计", "继续"], "三颗按钮从左到右是 观察 / 统计 / 继续")
	eq(o.buttons().size(), 3, "确实建了三颗按钮")
	ok(o.banner() != null and o.banner().current_width() > 1.0, "★ 横幅已经拉到位")
	ok(o.crown() != null and o.crown().modulate.a > 0.99, "★ 王冠已经渐入")
	ok(o.gem() != null and o.gem().visible and o.gem().modulate.a > 0.99,
		"★ 胜利时宝石出现并且不透明")
	ok(o.hint_label() != null and o.hint_label().modulate.a > 0.99, "提示文字完全不透明")
	# ★ `draw_count` 只在 `_draw()` 里加：无头下也能证明这三块真的被画过
	#   （`_draw` 里出错不会让测试失败，所以必须盯一眼）。
	await process_frame
	ok(int(o.crown().draw_count) > 0, "★ 王冠真的画过（draw_count > 0）")
	ok(int(o.gem().draw_count) > 0, "★ 宝石真的画过")
	ok(int(o.banner().draw_count) > 0, "★ 横幅真的画过")

	# ---- 点击任意处 → 提示渐隐、按钮渐显（★ 走真实 GUI 命中测试，不是直接调函数）----
	ok(o._root.size.x > 100.0 and o._root.size.y > 100.0, "结算根铺满视口（能做命中测试）")
	eq(o._root.mouse_filter, Control.MOUSE_FILTER_STOP, "结算根是 STOP（收点击）")
	eq(o._bg.mouse_filter, Control.MOUSE_FILTER_IGNORE, "背景层不吃点击（否则点不到结算根）")
	_continue_hits = 0
	o.continue_pressed.connect(func() -> void: _continue_hits += 1)
	await _click_at(Vector2(120.0, 120.0))
	ok(o.buttons_revealed(), "★ 点屏幕空白处被受理（GUI 接线真的通）")
	ok(not o.ready_for_click(), "同一下点击不会再次受理")
	ok(o.buttons()[0].visible and o.buttons()[2].visible, "★ 三颗按钮可见")
	ok(o.hint_label().modulate.a < 0.01, "★ 提示文字已渐隐")
	ok(not o.accept_click(), "按钮出现之后再点空白处不会重复受理")

	# ---- 观察 / 统计暂时无逻辑；继续发信号（★ 继续走真实按钮点击）----
	o.buttons()[0].pressed.emit()
	o.buttons()[1].pressed.emit()
	eq(_continue_hits, 0, "观察 / 统计点了不触发继续（本轮只接继续）")
	ok(o.is_open(), "观察 / 统计不会关闭结算层")
	var continue_btn: Button = o.buttons()[2]
	await _click_at(continue_btn.get_global_rect().get_center())
	eq(_continue_hits, 1, "★ 继续按钮的真实点击会发 continue_pressed")
	ok(not o.is_open(), "继续之后结算层关闭")

	o.queue_free()
	await process_frame


func _test_lose_overlay(cfg) -> void:
	var o = _new_overlay(cfg, "lose")
	await process_frame
	eq(o.result(), "lose", "结果是 lose")
	eq(o.word_text(), String(cfg.str_val("outcome.lose_word", "失败")), "横幅主字是「失败」")
	ok(o.crown() != null, "失败时也有王冠")
	ok(o.crown().crack_t > 0.99, "★ 王冠已经全部裂开（crack_t = 1）")
	ok(o.crown().dim_t > 0.99, "★ 王冠整体变暗（dim_t = 1）")
	ok(o.gem() == null or not o.gem().visible, "★ 失败时没有宝石")
	ok(o.banner() != null and o.banner().current_width() > 1.0, "失败时横幅也会拉开")
	ok(o.ready_for_click(), "失败时同样可以点击任意处")
	ok(o.accept_click(), "失败时的点击被受理")
	ok(o.buttons_revealed() and o.buttons().size() == 3, "失败时三颗按钮同样出现")
	# 视觉口径：失败主字用 warning 红（不是胜利金）。
	eq(o.word_label().get_theme_color("font_color"), ThemeRes.warning(),
		"★ 失败主字是 warning 红")
	o.queue_free()
	await process_frame


func _test_game_hotkeys(cfg) -> void:
	var game = GameSceneRes.new()
	root.add_child(game)
	ok(game.start(String(MapLibraryRes.default_map_path())), "能开一局（快捷键测试的地基）")
	await process_frame

	# ---- Ctrl+1 = 粮食 / 黄金 +1000（★ 走真实键盘事件）----
	# 先停掉产出：否则等待两帧的收入会让「正好 +1000」这条断言漂。
	for z in game.world.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	var food0: float = float(game.world.resources["food"])
	var gold0: float = float(game.world.resources["gold"])
	await _press_ctrl_key(KEY_1)
	near(float(game.world.resources["food"]), food0 + 1000.0, 1e-4,
		"★ Ctrl+1 → 粮食 +1000")
	near(float(game.world.resources["gold"]), gold0 + 1000.0, 1e-4,
		"★ Ctrl+1 → 黄金 +1000")
	ok(game.hud.notice_text().contains("1000"),
		"★ 加资源时给一句开发者提示（实际：%s）" % game.hud.notice_text())
	ok(not game.outcome_open(), "Ctrl+1 不会触发结算（只是加资源）")

	# ---- Ctrl+3 = 本机阵营大本营立即升到 3 级 ----
	var base = game.world.find_base_of(game.world.my_faction)
	ok(base != null, "（前提）本机阵营有大本营")
	if base != null:
		await _press_ctrl_key(KEY_3)
		eq(int(base.level), 3, "★ Ctrl+3 → 大本营当场 3 级")
		eq(game.world.base_level_of(game.world.my_faction), 3,
			"★ 权威等级查询也读到 3")
		ok(game.hud.notice_text().contains("3 级"),
			"★ Ctrl+3 给一句开发者提示（实际：%s）" % game.hud.notice_text())
		ok(not game.outcome_open(), "Ctrl+3 不会触发结算")

	# ---- Ctrl+W = 立即胜利（★ 走真实键盘事件，不是直接调 handler）----
	await _press_ctrl_key(KEY_W)
	ok(game.outcome_open(), "★ Ctrl+W 之后本局进入结算（停战）")
	eq(game.outcome_result, "win", "★ 结算结果是 win")
	eq(String(game.world.objective_state.get("state", "")), "won",
		"★ Ctrl+W 同时把目标状态改写成 won（不只是弹画面）")
	var ov = game.outcome_overlay()
	ok(ov != null and ov.result() == "win", "★ 结算层真的挂出来了，且是胜利")
	ok(game.hud != null and not game.hud.visible, "结算时 HUD 隐藏（整屏画面）")

	# ---- 停战：世界时间不再前进 ----
	var t0: float = game.world.time
	for i in 3:
		await process_frame
	eq(game.world.time, t0, "★ 结算期间世界冻结（时间不再前进）")

	# ---- 已经结算之后 Ctrl+L 不再改判 ----
	await _press_ctrl_key(KEY_L)
	eq(String(game.world.objective_state.get("state", "")), "won",
		"★ 已经结算之后 Ctrl+L 不会改判")
	eq(game.outcome_result, "win", "结算结果保持 win")

	# ---- 继续：走 game 的既有回主菜单信号 ----
	# ★ 用数组当计数器：GDScript 的 lambda 按**值**捕获局部变量，
	#   直接写 `menu_hits += 1` 外面永远是 0（数组是引用类型，改它的元素才对外可见）。
	var menu_hits: Array = [0]
	game.return_to_menu_requested.connect(func() -> void: menu_hits[0] += 1)
	ov.buttons()[2].pressed.emit()
	eq(int(menu_hits[0]), 1, "★ 继续按钮最终发的是 return_to_menu_requested（main 接的就是它）")

	game.queue_free()
	await process_frame


## 真实的 Ctrl+字母 键盘事件：走 `root.push_input`，验证快捷键**接线**真的通。
func _press_ctrl_key(keycode: Key) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = keycode
	ev.ctrl_pressed = true
	root.push_input(ev, true)
	await process_frame
	await process_frame


## 真实的鼠标点击（与 tests/test_start_flow.gd 同一个口径）：
## 走 `root.push_input`，让 GUI 自己做命中测试 —— 直接调 `accept_click()` 测不到
## 「点击到底有没有到达那一层」这个接线问题（start_screen 第一版就栽在这里）。
func _click_at(pos: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


## ★ 端到端：主场景里点「继续」，真的拆掉游戏场景、把主界面放回来。
##   （信号通了不等于流程通了 —— 这条是「main.gd 接没接」的验收。）
func _test_main_return_flow(cfg) -> void:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景（端到端回主菜单）")
	if packed == null:
		return
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	var game = main.game
	ok(game != null, "端到端：真的进了游戏")
	if game == null:
		main.queue_free()
		return

	await _press_ctrl_key(KEY_W)

	var ov = game.outcome_overlay()
	ok(ov != null and ov.ready_for_click(), "端到端：结算画面已经可以点击")
	if ov != null:
		# 先点空白处让三颗按钮出现，再点「继续」（与玩家真实操作顺序一致）。
		await _click_at(Vector2(120.0, 120.0))
		ok(ov.buttons_revealed(), "端到端：点空白处之后按钮出现")
		await process_frame
		var continue_btn: Button = ov.buttons()[2]
		await _click_at(continue_btn.get_global_rect().get_center())
	ok(main.game == null, "★ 点「继续」之后 main 拆掉了游戏场景")
	ok(main.start_screen != null and main.start_screen.visible,
		"★ 回到主界面（开场页那一层重新 show 出来）")
	eq(int(main.start_screen.page()), 1, "回到的是主界面那一页（不是入场页）")

	main.queue_free()
	await process_frame


func _test_level_end_event(cfg) -> void:
	var game = GameSceneRes.new()
	root.add_child(game)
	ok(game.start(String(MapLibraryRes.default_map_path())), "能开一局（事件测试的地基）")
	await process_frame

	# 单机 tick 出来 / 合作客机收到的事件，都是这一条形状。
	game._consume_events([{
		"type": "level_end",
		"result": "lose",
		"reason": "base_destroyed",
	}])
	ok(game.outcome_open(), "★ level_end 事件会弹出结算画面")
	eq(game.outcome_result, "lose", "★ 事件里的 result 原样落到结算结果")
	var ov = game.outcome_overlay()
	ok(ov != null and ov.result() == "lose", "结算层是失败画面")

	# 同一条事件再来一次不会长出第二层。
	var first = ov
	game._consume_events([{
		"type": "level_end",
		"result": "win",
		"reason": "",
	}])
	ok(game.outcome_overlay() == first, "★ 重复的 level_end 不会叠出第二层结算")
	eq(game.outcome_result, "lose", "第一层的结果不会被后来者改掉")

	game.queue_free()
	await process_frame
