## test_story_director.gd —— 演出导演：触发器 / 队列 / 锁 / 跳过 / 世界效果。
##
## 不建场景：用一个 fake host 记录「导演请求视图做什么」，
## 世界效果（资源 / 击杀 / 摧毁 / 边界）直接在 `require_world()` 造的世界里验。
extends "res://tests/test_case.gd"

const StoryDirectorRes = preload("res://logic/story/story_director.gd")
const StoryActionsRes = preload("res://logic/story/story_actions.gd")
const StoryConsts = preload("res://logic/story/story_consts.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const GridRes = preload("res://logic/grid.gd")


class FakeHost extends RefCounted:
	var cfg = null
	var dialogues: Array = []
	var cleared: int = 0
	var camera_moves: Array = []
	var camera_lock_calls: Array = []
	var camera_follows: Array = []
	var boundary_refresh: int = 0
	var expand_calls: Array = []
	var resource_gains: Array = []
	## 模拟「高亮部队」引导是否正在生效（导演据此决定对话锁放不放开 order）。
	var guide_focus: bool = false

	func _init(p_cfg = null) -> void:
		cfg = p_cfg

	func story_show_dialogue(token: int, text: String, opts: Dictionary) -> void:
		dialogues.append({"token": token, "text": text, "opts": opts})

	func story_clear_dialogue() -> void:
		cleared += 1

	func story_guide_unit_focus() -> bool:
		return guide_focus

	func story_camera_move(point: Vector2, sec: float, zoom: float, ease: String) -> void:
		camera_moves.append({"point": point, "sec": sec, "zoom": zoom, "ease": ease})

	func story_camera_lock(on: bool) -> void:
		camera_lock_calls.append(on)

	func story_camera_follow(spec) -> void:
		camera_follows.append(spec)

	func story_refresh_boundary() -> void:
		boundary_refresh += 1

	func story_expand_map(map_id: String, opts: Dictionary, token: int) -> void:
		expand_calls.append({"map": map_id, "opts": opts, "token": token})

	func story_resource_gain(food: float, gold: float) -> void:
		resource_gains.append([food, gold])


func _initialize() -> void:
	_case_name = "test_story_director"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_triggers(cfg)
	_test_locks(cfg)
	_test_skip(cfg)
	_test_dialogue_modal(cfg)
	_test_skip_dialogue_chain(cfg)
	_test_actions(cfg)
	_test_boundary(cfg)
	_test_camera_steps(cfg)


# ------------------------------------------------------------------
# 触发器
# ------------------------------------------------------------------

func _test_triggers(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var host = FakeHost.new(cfg)
	var d = StoryDirectorRes.new()
	d.host = host
	d.world = w

	var calls: Array = []
	d.on_start([{"kind": "call", "fn": func() -> void: calls.append("start")}])
	d.tick(0.0, [])
	eq(calls, ["start"], "★ on_start 第一帧触发")

	w.time = 1.0
	d.on_time(1.0, [{"kind": "call", "fn": func() -> void: calls.append("time")}])
	d.tick(0.0, [])
	eq(calls, ["start", "time"], "★ on_time 在 world.time 到点后触发")

	var z = w.zones.zones[0]
	var owner := String(z.get("owner", ""))
	if owner == "":
		owner = "p1"
	z["owner"] = owner
	d.on_zone_owner(int(z["id"]), owner,
		[{"kind": "call", "fn": func() -> void: calls.append("zone")}])
	d.tick(0.0, [])
	eq(calls, ["start", "time", "zone"], "★ on_zone_owner 按归属触发")

	var u = w.create_general("p1", 0, 900)
	ok(u != null, "（前提）造一个将领")
	if u != null:
		u.tag = "old_captain"
		w.units.append(u)
		d.on_unit_dead({"tag": "old_captain"},
			[{"kind": "call", "fn": func() -> void: calls.append("dead")}])
		d.tick(0.0, [{"type": "kill", "unit": u}])
		eq(calls, ["start", "time", "zone", "dead"], "★ on_unit_dead 按 tag 匹配 kill 事件")

	d.on_command("move", [{"kind": "call", "fn": func() -> void: calls.append("cmd")}])
	d.notify_command({"kind": "move"})
	d.tick(0.0, [])
	eq(calls, ["start", "time", "zone", "dead", "cmd"], "★ on_command 匹配命令")

	var once_count := [0]
	d.on_condition(func() -> bool: return true,
		[{"kind": "call", "fn": func() -> void: once_count[0] += 1}])
	d.tick(0.0, [])
	d.tick(0.0, [])
	eq(int(once_count[0]), 1, "★ 默认 once = 只触发一次")


func _test_locks(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var d = StoryDirectorRes.new()
	d.host = FakeHost.new(cfg)
	d.world = w
	ok(d.is_input_allowed("camera"), "没锁时全部允许")
	d.lock_input("a", ["camera", "dialogue"])
	ok(d.is_input_allowed("camera"), "★ 锁 a 允许 camera")
	ok(not d.is_input_allowed("order"), "★ 锁 a 不允许 order")
	d.lock_input("b", ["camera"])
	ok(d.is_input_allowed("camera"), "★ 两把锁都允许 camera ⇒ 允许")
	ok(not d.is_input_allowed("dialogue"), "★ 取交集：a 允许但 b 不允许 ⇒ 不允许")
	d.lock_input("a", ["order"])
	ok(not d.is_input_allowed("camera"), "★ 同名锁更新 allow，不叠两把")
	ok(not d.is_input_allowed("order"), "★★ 取交集：b 不允许 order ⇒ 仍然不允许")
	d.unlock_input("b")
	ok(d.is_input_allowed("order"), "解锁 b 后 order 仍允许")
	ok(not d.is_input_allowed("camera"), "解锁 b 后 camera 仍被 a 禁止")
	d.unlock_input("a")
	ok(d.is_input_allowed("camera"), "全部解锁后恢复")
	d.lock_input("full", null)
	ok(not d.is_input_allowed("order"), "★ 不写 allow = 锁定全部玩法输入")
	ok(d.is_input_allowed("dialogue"), "★ 全锁仍允许推进对话")
	ok(d.is_input_allowed("skip"), "★ 全锁仍允许跳过")
	d.unlock_input("full")


func _test_skip(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var d = StoryDirectorRes.new()
	d.host = FakeHost.new(cfg)
	d.world = w
	d.on_start([{"kind": "wait", "sec": 10.0}], {"skippable": false})
	d.tick(0.0, [])
	ok(d.has_active(), "（前提）不可跳过演出在跑")
	ok(not d.request_skip(), "★★ skippable=false 时跳过被拒绝")
	ok(d.has_active(), "拒绝后演出还在")
	# 换一段可跳过的
	d = StoryDirectorRes.new()
	d.host = FakeHost.new(cfg)
	d.world = w
	d.on_start([
		{"kind": "lock_input", "id": "opening", "allow": ["camera"]},
		{"kind": "wait", "sec": 10.0},
	])
	d.tick(0.0, [])
	ok(not d.is_input_allowed("order"), "（前提）锁生效")
	ok(d.request_skip(), "★ 可跳过演出可以跳过")
	ok(not d.has_active(), "跳过之后演出结束")
	ok(d.is_input_allowed("order"), "★★ 跳过释放本演出的输入锁")


func _test_dialogue_modal(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var host = FakeHost.new(cfg)
	var d = StoryDirectorRes.new()
	d.host = host
	d.world = w
	d.on_start([{"kind": "dialogue", "text": "测试对话"}])
	d.tick(0.0, [])
	eq(host.dialogues.size(), 1, "★ 对话交给宿主")
	ok(d.is_input_allowed("dialogue"), "★ 对话期间允许推进")
	ok(d.is_input_allowed("select"), "★★ 对话期间允许选中（高亮部队时能点选）")
	ok(not d.is_input_allowed("order"), "★★ 对话是模态：order 被禁止")
	ok(not d.is_ui_blocked_except_dialogue(), "★★ 只剩对话锁时不算 UI 被挡（高亮期间撤盾）")
	var token := int((host.dialogues[0] as Dictionary).get("token", -1))
	d.on_dialogue_finished(token)
	ok(not d.has_active(), "对话结束后演出继续到结束")
	ok(d.is_input_allowed("order"), "对话结束后模态锁释放")

	# ★★ 高亮部队期间开的对话：不仅允许选中，还放开移动 / 攻击指令（order）。
	var host2 = FakeHost.new(cfg)
	host2.guide_focus = true
	var d2 = StoryDirectorRes.new()
	d2.host = host2
	d2.world = w
	d2.on_start([{"kind": "dialogue", "text": "高亮对话"}])
	d2.tick(0.0, [])
	ok(d2.is_input_allowed("select"), "★★ 高亮部队的对话允许选中")
	ok(d2.is_input_allowed("order"), "★★ 高亮部队的对话不锁移动 / 攻击")
	ok(not d2.is_input_allowed("recruit"), "★★ 招募仍被对话锁挡住")


## ★★ 2026.11.07：点击左侧对话框 = 跳过这一串连续对话。
func _test_skip_dialogue_chain(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var host = FakeHost.new(cfg)
	var d = StoryDirectorRes.new()
	d.host = host
	d.world = w
	var calls: Array = []
	d.on_start([
		{"kind": "dialogue", "text": "第一句"},
		{"kind": "dialogue", "text": "第二句"},
		{"kind": "dialogue", "text": "第三句"},
		{"kind": "call", "fn": func() -> void: calls.append("after")},
	])
	d.tick(0.0, [])
	eq(host.dialogues.size(), 1, "（前提）只弹出第一句")
	ok(d.skip_dialogue_chain(), "★★ 点击对话框跳过这一波对话")
	eq(host.cleared, 1, "★★ 宿主收到清对话回调")
	eq(host.dialogues.size(), 1, "★★ 后面紧接着的对话不再弹出")
	eq(calls, ["after"], "★★ 跳到非对话步骤后正常继续")
	ok(not d.has_active(), "跳过对话后这一段演出正常结束")
	ok(d.is_input_allowed("order"), "★★ 跳过对话后输入锁释放")

	# 跳过只覆盖「这一波」：遇到 wait 就恢复，后面的新对话照常弹。
	var host2 = FakeHost.new(cfg)
	var d2 = StoryDirectorRes.new()
	d2.host = host2
	d2.world = w
	d2.on_condition(func() -> bool: return true, [
		{"kind": "dialogue", "text": "开头对话"},
		{"kind": "dialogue", "text": "同一波的第二句"},
		{"kind": "wait", "sec": 0.5},
		{"kind": "dialogue", "text": "等待之后的新对话"},
	])
	d2.tick(0.0, [])
	eq(host2.dialogues.size(), 1, "（前提）第一句弹出")
	ok(d2.skip_dialogue_chain(), "★★ 跳过这一波对话")
	eq(host2.dialogues.size(), 1, "★★ 同一波的第二句不再弹出")
	d2.tick(0.6, [])
	eq(host2.dialogues.size(), 2, "★★ wait 结束后的新对话照常弹出")
	if host2.dialogues.size() >= 2:
		eq(String((host2.dialogues[1] as Dictionary).get("text", "")), "等待之后的新对话",
			"★★ 恢复后弹出的是 wait 之后那条")


# ------------------------------------------------------------------
# 世界效果
# ------------------------------------------------------------------

func _test_actions(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	# 清掉资源，方便对账
	var pool: Variant = w.resource_pool_for(w.my_faction)
	if typeof(pool) == TYPE_DICTIONARY:
		(pool as Dictionary)["food"] = 0.0
		(pool as Dictionary)["gold"] = 0.0
	var host = FakeHost.new(cfg)
	var d = StoryDirectorRes.new()
	d.host = host
	d.world = w
	d.on_start([{"kind": "grant_resources", "food": 120.0, "gold": 40.0}])
	d.tick(0.0, [])
	if typeof(pool) == TYPE_DICTIONARY:
		near(float((pool as Dictionary).get("food", 0.0)), 120.0, 1e-4, "★ 给粮食")
		near(float((pool as Dictionary).get("gold", 0.0)), 40.0, 1e-4, "★ 给黄金")
	eq(host.resource_gains.size(), 1, "★ 宿主收到资源飘字回调")

	# 单位：tag / 静默 / 正常
	var u1 = w.create_general("p1", 0, 901)
	if u1 != null:
		u1.tag = "kill_me"
		w.units.append(u1)
		var n := StoryActionsRes.kill_units(w, [{"tag": "kill_me"}], false)
		eq(n, 1, "★ 按 tag 强制击杀")
		ok(not u1.alive, "目标已死")
		var evs: Array = w.tick(0.016)
		ok(_has_event(evs, "kill"), "★ 正常击杀推 kill 事件")

	var u2 = w.create_general("p1", 1, 902)
	if u2 != null:
		u2.tag = "silent_kill"
		w.units.append(u2)
		var n2 := StoryActionsRes.kill_units(w, [{"tag": "silent_kill"}], true)
		eq(n2, 1, "★ 静默击杀")
		ok(not u2.alive, "静默目标已死")
		var evs2: Array = w.tick(0.016)
		ok(not _has_event_type_unit(evs2, "kill", u2), "★★ 静默击杀不推 kill 事件")

	# 建筑：正常 / 静默 / 大本营拒绝
	var tower = _free_building(w, "tower", "p1", "north_gate")
	ok(tower != null, "（前提）造一栋塔")
	if tower != null:
		var nb := StoryActionsRes.destroy_buildings(w, [{"tag": "north_gate"}], false)
		eq(nb, 1, "★ 按 tag 摧毁建筑")
		ok(w.building_list.find(tower) < 0, "正常摧毁后会收尸")
		var evs3: Array = w.tick(0.016)
		ok(_has_event(evs3, "building_down"), "★ 正常摧毁推 building_down")

	var tower2 = _free_building(w, "tower", "p1", "silent_gate")
	if tower2 != null:
		var nb2 := StoryActionsRes.destroy_buildings(w, [{"tag": "silent_gate"}], true)
		eq(nb2, 1, "★ 静默摧毁")
		ok(w.building_list.find(tower2) < 0, "静默摧毁会移除")
		var evs4: Array = w.tick(0.016)
		ok(not _has_event_type_building(evs4, "building_down", tower2),
			"★★ 静默摧毁不推 building_down")

	var base = w.find_base_of(w.my_faction)
	if base != null:
		ok(not w.story_destroy_building(base, false), "★★ 拒绝强制摧毁大本营")
		ok(base.alive, "大本营还在")


func _test_boundary(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var inside := Rect2i(0, 0, 5, 5)
	w.set_boundary(inside)
	var in_tile := _first_walkable_inside(w, inside)
	ok(in_tile.x >= 0, "（前提）边界内有可通行格")
	if in_tile.x >= 0:
		ok(PathfinderRes.passable(w.map, w.buildings, cfg, in_tile.x, in_tile.y, w.my_faction),
			"边界内可通行")
	var out := _first_walkable_outside(w, inside)
	if out.x >= 0:
		ok(not PathfinderRes.passable(w.map, w.buildings, cfg, out.x, out.y, w.my_faction),
			"★★ 边界外不可通行")
		ok(not w.can_build_at(out.x, out.y, w.my_faction), "★★ 边界外不能建造")
	w.reset_boundary()
	if out.x >= 0:
		ok(PathfinderRes.passable(w.map, w.buildings, cfg, out.x, out.y, w.my_faction),
			"恢复整图后可通行")
	# 扩大 / 缩小
	w.set_boundary(Rect2i(2, 2, 4, 4))
	ok(w.tile_in_boundary(5, 5), "（前提）5,5 在边界内")
	var d = StoryDirectorRes.new()
	d.host = FakeHost.new(cfg)
	d.world = w
	d.on_start([{"kind": "map_boundary_expand", "rect": [1, 1, 6, 6]}])
	d.tick(0.0, [])
	ok(w.tile_in_boundary(1, 1), "★ 扩边界允许包含旧矩形的扩展")
	d = StoryDirectorRes.new()
	d.host = FakeHost.new(cfg)
	d.world = w
	d.on_start([{"kind": "map_boundary_expand", "rect": [2, 2, 2, 2]}])
	d.tick(0.0, [])
	ok(w.tile_in_boundary(1, 1), "★★ 缩边界被拒绝，旧边界保持不变")


func _test_camera_steps(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var host = FakeHost.new(cfg)
	var d = StoryDirectorRes.new()
	d.host = host
	d.world = w
	var base = w.find_base_of(w.my_faction)
	if base == null:
		return
	d.on_start([
		{"kind": "camera_move", "target": {"base": w.my_faction}, "sec": 0.0,
			"zoom": 0.2, "lock": false},
	])
	d.tick(0.0, [])
	eq(host.camera_moves.size(), 1, "★ camera_move 交给宿主")
	ok(host.camera_moves[0]["point"].x >= 0.0, "★ 镜头目标解析成逻辑点")
	ok(host.camera_lock_calls.has(true), "★ 移动开始时锁镜头")
	ok(host.camera_lock_calls.has(false), "★ lock=false 时移动结束交还镜头")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _has_event(events: Array, type: String) -> bool:
	for e in events:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("type", "")) == type:
			return true
	return false


func _has_event_type_unit(events: Array, type: String, u) -> bool:
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if String(d.get("type", "")) == type and d.get("unit", null) == u:
			return true
	return false


func _has_event_type_building(events: Array, type: String, b) -> bool:
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = e
		if String(d.get("type", "")) == type and d.get("building", null) == b:
			return true
	return false


func _free_building(w, type: String, owner: String, tag: String):
	var r: Rect2i = Rect2i(0, 0, w.map.cols, w.map.rows)
	for y in r.size.y:
		for x in r.size.x:
			if w.building_at(x, y) != null:
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			if not w.can_build_at(x, y, ""):
				continue
			var b = w.add_building(type, x, y, owner, true, true, tag)
			if b != null:
				return b
	return null


func _first_walkable_inside(w, inside: Rect2i) -> Vector2i:
	for y in w.map.rows:
		for x in w.map.cols:
			if not inside.has_point(Vector2i(x, y)):
				continue
			if w.map.terrain_walkable(x, y) and w.building_at(x, y) == null:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _first_walkable_outside(w, inside: Rect2i) -> Vector2i:
	for y in w.map.rows:
		for x in w.map.cols:
			if inside.has_point(Vector2i(x, y)):
				continue
			if w.map.terrain_walkable(x, y):
				return Vector2i(x, y)
	return Vector2i(-1, -1)
