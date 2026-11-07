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
		ok(game.story_glow.get_node_or_null("StoryGlowRings") == null,
			"★★ 不再有常驻地面光环层（用户 2026.11.07 要求）")
		ok(game.story_glow.glow_ripple_count >= 1,
			"★★ 单位持续向外扩散的圆环（圈数 %d）" % game.story_glow.glow_ripple_count)
		ok(game.story_glow.glow_ripple_count <= 1,
			"★★ 圆环最多 1 圈（用户 2026.11.07：波纹再少一些）")
		# 单圈是一波一波的：采样两个多周期，确认最多 1 圈，但确实还会周期出现。
		var saw_ring: bool = int(game.story_glow.glow_ripple_count) >= 1
		var max_rings: int = int(game.story_glow.glow_ripple_count)
		for _i in 60:
			game.world.time += 0.1
			game.story_glow.sync(0.0)
			saw_ring = saw_ring or game.story_glow.glow_ripple_count >= 1
			max_rings = maxi(max_rings, game.story_glow.glow_ripple_count)
		ok(max_rings <= 1, "★★ 波纹始终不超过 1 圈（实际最多 %d）" % max_rings)
		ok(saw_ring, "★★ 圆环仍会周期出现（不是彻底没了）")
		StoryActionsRes.stop_glow(game.world, {"targets": {"tag": "scene_glow"}})
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
		ok(game.story_glow.glow_ripple_count >= 1,
			"★★ 建筑持续向外扩散的圆环（圈数 %d）" % game.story_glow.glow_ripple_count)
		ok(game.story_glow.glow_ripple_count <= 1,
			"★★ 建筑的圆环也最多 1 圈")
		ok(game.story_glow.glow_shell_count >= 1, "★★ 建筑外壳写进视图")

	# ★★ 2026.11.07：高亮部队 + 对话 → 不整屏挡地图（能点选）；点击对话框跳过这一波对话。
	if u != null:
		game.story_guide_selection({"targets": {"tag": "scene_glow"}, "id": "scene_skip_guide"})
		ok(game._story_unit_guide_focus(), "（前提）部队高亮引导生效")
		var skipped: Array = []
		# start 触发器只会响一次（第一段演出已经用过），这里用一个恒真条件挂第二段。
		d.on_condition(func() -> bool: return true, [
			{"kind": "dialogue", "text": "跳过测试一"},
			{"kind": "dialogue", "text": "跳过测试二"},
			{"kind": "call", "fn": func() -> void: skipped.append(true)},
		])
		d.tick(0.0, [])
		await process_frame
		await process_frame
		ok(game.hud.has_dialogue(), "（前提）对话在屏上")
		ok(game.hud.story_shield == null or not game.hud.story_shield.visible,
			"★★ 高亮部队期间不整屏挡地图（能点选单位）")
		ok(game.input_ctrl._action_ok("select"), "★★ 高亮部队的对话允许选中")
		ok(game.input_ctrl._action_ok("order"), "★★ 高亮部队的对话不锁移动 / 攻击")
		ok(not game.input_ctrl._action_ok("recruit"), "★★ 招募仍被对话锁挡住")
		# 选中高亮部队后引导收掉；这条对话还在时仍要能移动（锁在对话开始时就放开了）。
		game.input_ctrl.select_units([u])
		game._sync_story_guide()
		await process_frame
		ok(game.story_guide.is_empty(), "★★ 选中高亮部队后引导收掉")
		ok(game.input_ctrl._action_ok("order"), "★★ 引导收掉后、对话还在时仍不锁移动")
		ok(game.hud.story_shield == null or not game.hud.story_shield.visible,
			"★★ 选完人盾也不重新盖上")
		# ★★ 走真实鼠标事件：曾经 `_on_dialogue_gui_input` 绑定的是控件、参数却写成
		#   Dictionary，点击会报类型错误、对话框怎么点都没反应。这里必须点真的。
		var banner = game.hud.broadcast_banner
		var row: Control = (banner.dialogue_row() as Dictionary)["row"]
		var pt: Vector2 = row.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = pt
		motion.global_position = pt
		# ★ 用**视口本地坐标**送入：headless 下窗口只有 64×64，默认按窗口坐标
		#   会被 stretch 缩放成屏幕外，点不到对话框（真实鼠标由引擎自己换算）。
		root.push_input(motion, true)
		await process_frame
		var press := InputEventMouseButton.new()
		press.position = pt
		press.global_position = pt
		press.button_index = MOUSE_BUTTON_LEFT
		press.pressed = true
		root.push_input(press, true)
		var release := InputEventMouseButton.new()
		release.position = pt
		release.global_position = pt
		release.button_index = MOUSE_BUTTON_LEFT
		release.pressed = false
		root.push_input(release, true)
		await process_frame
		ok(not game.hud.has_dialogue(), "★★ 这一波对话被跳过（第二句不再弹出）")
		eq(skipped, [true], "★★ 跳过对话后演出继续到下一步")
		game.story_guide_clear()

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
