## test_story_scene.gd —— 演出系统与 3D 场景 / HUD 的接线冒烟测试。
##
## 不验视觉，只验：
##   · 导演能拿到宿主、对话能经 HUD 显示并回报 finished；
##   · 镜头强制移动 / 锁定 / 解锁；
##   · 给资源的飘字 + 播报；
##   · 边界刷新不崩。
extends "res://tests/test_case.gd"

const GameSceneRes = preload("res://view/game_scene3d.gd")
const StoryDirectorRes = preload("res://logic/story/story_director.gd")
const StoryActionsRes = preload("res://logic/story/story_actions.gd")
const ThemeRes = preload("res://view/theme.gd")


func _initialize() -> void:
	_case_name = "test_story_scene"
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

	var game = GameSceneRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "（前提）3D 场景能装起来")
		game.queue_free()
		ThemeRes.set_animations_enabled(prev_anim)
		_quit_case()
		return
	await process_frame

	var d = StoryDirectorRes.new()
	d.host = game
	d.world = game.world
	ok(d.setup(game, game.world, "demo"), "★ 导演 setup 到场景")
	game.story = d
	if game.input_ctrl != null:
		game.input_ctrl.action_gate = func(action: String) -> bool:
			return d.is_input_allowed(action)

	# 对话：导演 → HUD → finished → 导演继续
	d.on_start([{"kind": "dialogue", "text": "场景接线测试"}])
	d.tick(0.0, [])
	ok(game.hud != null and game.hud.has_dialogue(), "★ 对话显示在 HUD 上")
	ok(not d.is_input_allowed("order"), "★ 对话模态：order 被禁止")
	ok(d.advance_dialogue(), "★ 脚本推进对话")
	await process_frame
	ok(not game.hud.has_dialogue(), "★ HUD 对话已结束")
	ok(not d.has_active(), "★ 导演收到 finished 后继续到结束")

	# 镜头：强制移动 / 锁定 / 解锁
	game.story_camera_move(Vector2(5.0, 5.0), 0.0, 0.2, "cubic")
	ok(game.story_camera_locked, "★ 强制镜头会锁镜头")
	near(game.zoom, 0.2, 1e-6, "★ 强制镜头应用缩放")
	game.story_camera_lock(false)
	ok(not game.story_camera_locked, "★ 解锁镜头")

	# 资源：飘字 + 播报
	game.story_resource_gain(12.0, 8.0)
	ok(game.hud.resource_float_count() >= 1, "★ 资源飘字已生成")
	game.story_refresh_boundary()
	ok(true, "★ 边界刷新不崩")

	# 泛光：给本机单位 + 一栋建筑加呼吸泛光，视图层应真正写出实例
	var u = null
	for cand in game.world.units:
		if String(cand.faction) == String(game.world.my_faction) and cand.alive:
			u = cand
			break
	ok(u != null, "（前提）找到本机单位")
	if u != null:
		u.tag = "scene_glow"
		eq(StoryActionsRes.glow_objects(game.world, {
			"targets": {"tag": "scene_glow"}, "period": 1.0,
		}), 1, "★ 场景单位加上泛光")
		game.world.time += 0.4
		game.story_glow.sync(0.0)
		ok(game.story_glow.glow_ring_count >= 1, "★★ 单位地面光环写进视图")
		ok(game.story_glow.glow_ripple_count >= 1, "★★ 单位向外波纹写进视图")
	var b = null
	for cand2 in game.world.building_list:
		if cand2 != null and cand2.alive and String(cand2.type) == "base":
			b = cand2
			break
	ok(b != null, "（前提）找到大本营")
	if b != null:
		eq(StoryActionsRes.glow_objects(game.world, {
			"targets": {"tile": [b.tx, b.ty]}, "period": 1.0,
		}), 1, "★ 大本营加上泛光")
		game.world.time += 0.4
		game.story_glow.sync(0.0)
		ok(game.story_glow.glow_ring_count >= 1, "★★ 建筑地面光环写进视图")
		ok(game.story_glow.glow_shell_count >= 1, "★★ 建筑外壳写进视图")

	game.queue_free()
	await process_frame
	ThemeRes.set_animations_enabled(prev_anim)
	_quit_case()


func _quit_case() -> void:
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)
