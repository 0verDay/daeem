## story_director.gd —— 战役演出导演（**纯逻辑**，不碰 Node / 输入 / 视图）。
##
## ★★ 职责：
##   1. 读战役剧本（`logic/story/campaigns/<id>.gd`）注册的触发器；
##   2. 每帧检查触发器，命中后把一段线性步骤塞进演出队列；
##   3. 按顺序执行步骤（等待 / 输入锁 / 镜头 / 边界 / 给资源 / 击杀 / 摧毁 / 对话 / 换图）；
##   4. 维护**输入锁栈**（多段演出叠加时取交集，最严格）；
##   5. 处理跳过（可跳过的演出才允许 Esc）。
##
## ★★ 与视图的分工（这是本文件最重要的边界）：
##   · 本文件只改**世界状态**（资源 / 单位 / 建筑 / 地图边界 / 换图）与导演自己的锁；
##   · 镜头 / 对话 / 资源飘字 / 黑屏 / 视图重建全部通过 `host.story_*()` 交给
##     `view/game_scene3d.gd`。于是本文件可以在无头测试里用 fake host 单独跑。
##
## ⚠️ 跨文件引用只用 preload 常量（`--script` 下全局 class_name 不可用）。
extends RefCounted

const Consts = preload("res://logic/story/story_consts.gd")
const TriggersRes = preload("res://logic/story/story_triggers.gd")
const ActionsRes = preload("res://logic/story/story_actions.gd")
const RegistryRes = preload("res://logic/story/story_registry.gd")


## 宿主（`game_scene3d` / fake host）。可提供的方法：
##   story_show_dialogue(token:int, text:String, opts:Dictionary)
##   story_clear_dialogue()
##   story_camera_move(point:Vector2, sec:float, zoom:float, ease:String)
##   story_camera_lock(on:bool)
##   story_camera_follow(point:Vector2)
##   story_refresh_boundary()
##   story_expand_map(map_id:String, opts:Dictionary, token:int)
##   story_resource_gain(food:float, gold:float)
## 没有实现的方法会被**安全跳过**（纯逻辑测试只关心世界效果）。
var host = null
var world = null

## 注册的触发器：{kind, params, steps, opts, fired, last_time}
var _triggers: Array = []
## 演出队列（每项 {id, steps, skippable}）
var _queue: Array = []
## 当前演出（null = 空闲）
var _active: Variant = null
## 本机收到的命令（由 `game_scene3d._on_command` 转发，下一次 tick 消费）
var _pending_commands: Array = []
## 输入锁栈：每项 {id:String, allow:Dictionary}
var _locks: Array = []
var _serial: int = 0
var _start_tick_done: bool = false


# ------------------------------------------------------------------
# 生命周期
# ------------------------------------------------------------------

## @param campaign_id 战役 id（目录名；剧本注册表按它找）
func setup(p_host, p_world, campaign_id: String, _level_id: String = "") -> bool:
	host = p_host
	world = p_world
	var script: GDScript = RegistryRes.script_for(campaign_id)
	if script == null:
		return false
	# 剧本约定：static func build(director, world)
	script.build(self, world)
	return true


## 每帧推进。`events` 是 `world.tick()` 这一帧产出的事件数组。
func tick(dt: float, events: Array = []) -> void:
	_check_triggers(events)
	if _active == null:
		_start_next()
		return
	_advance_active(maxf(0.0, dt))


## 当前有没有演出在跑（含等待对话 / 换图）。
func has_active() -> bool:
	return _active != null


## 当前演出的 id（没有 → -1）。
func active_id() -> int:
	return int((_active as Dictionary).get("id", -1)) if _active != null else -1


## 当前步骤是不是在等玩家操作（`wait_until`）。供 UI / 测试判断。
func waiting_for_player() -> bool:
	if _active == null:
		return false
	var a: Dictionary = _active
	if String(a.get("waiting", "")) != "":
		return false
	var steps: Array = a.get("steps", [])
	var idx := int(a.get("index", 0))
	if idx < 0 or idx >= steps.size():
		return false
	var step: Dictionary = steps[idx]
	return String(step.get("kind", "")) == Consts.STEP_WAIT_UNTIL


# ------------------------------------------------------------------
# 触发器注册（剧本 API）
# ------------------------------------------------------------------

func on_start(steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_START, {}, steps, opts)


func on_time(sec: float, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_TIME, {"sec": sec}, steps, opts)


func on_zone_owner(zone: int, owner: String, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_ZONE_OWNER, {"zone": zone, "owner": owner}, steps, opts)


func on_event(type: String, filter: Variant, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_EVENT, {"type": type, "filter": filter}, steps, opts)


func on_unit_dead(filter: Variant, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_UNIT_DEAD, {"filter": filter}, steps, opts)


func on_building_destroyed(filter: Variant, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_BUILDING_DESTROYED, {"filter": filter}, steps, opts)


func on_command(kind: String, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_COMMAND, {"kind": kind}, steps, opts)


func on_condition(condition: Callable, steps: Array, opts: Dictionary = {}) -> void:
	add_trigger(Consts.TRIGGER_CONDITION, {"condition": condition}, steps, opts)


## 通用注册入口。`opts`：{once: bool = true, cooldown: float = 0.0, skippable: bool = true, id: String}
func add_trigger(kind: String, params: Dictionary, steps: Array, opts: Dictionary = {}) -> void:
	_serial += 1
	_triggers.append({
		"kind": kind,
		"params": params.duplicate(true),
		"steps": steps.duplicate(true),
		"once": bool(opts.get("once", true)),
		"cooldown": maxf(0.0, float(opts.get("cooldown", 0.0))),
		"skippable": bool(opts.get("skippable", true)),
		"id": String(opts.get("id", "trigger-%d" % _serial)),
		"fired": false,
		"last_time": -1e30,
	})


## 由 `game_scene3d._on_command` 转发；下一次 tick 参与 `on_command` 匹配。
func notify_command(cmd: Dictionary) -> void:
	_pending_commands.append(cmd.duplicate(true))


# ------------------------------------------------------------------
# 输入锁
# ------------------------------------------------------------------

## 当前输入是否允许某个动作。多个锁取**交集**（都允许才允许）。
func is_input_allowed(action: String) -> bool:
	for it in _locks:
		var lock: Dictionary = it
		var allow: Dictionary = lock.get("allow", {})
		if not bool(allow.get(action, false)):
			return false
	return true


## 往锁栈里压一把锁。同名 id 会更新 allow（不会叠两把）。
## @param persist true = 演出结束 / 跳过时不自动释放（由后续步骤显式 unlock）
func lock_input(id: String, allow: Variant, persist: bool = false) -> String:
	var lid := id.strip_edges()
	if lid == "":
		_serial += 1
		lid = "__auto_%d" % _serial
	var allow_d: Dictionary = Consts.normalize_allow(allow)
	var found := false
	for it in _locks:
		var lock: Dictionary = it
		if String(lock.get("id", "")) == lid:
			lock["allow"] = allow_d
			found = true
			break
	if not found:
		_locks.append({"id": lid, "allow": allow_d})
	if _active != null:
		var created: Dictionary = (_active as Dictionary).get("created_locks", {})
		if persist:
			# 同一 id 从「自动释放」改成「持久」时，别再在演出结束时删掉它。
			created.erase(lid)
		else:
			created[lid] = true
	return lid


## 释放一把锁。`id == ""` = 释放当前演出创建的全部锁。
func unlock_input(id: String = "") -> void:
	var lid := id.strip_edges()
	if lid == "":
		if _active != null:
			var created: Dictionary = (_active as Dictionary).get("created_locks", {})
			for k in created.keys():
				_remove_lock(String(k))
			created.clear()
		return
	_remove_lock(lid)


func _remove_lock(id: String) -> void:
	for i in range(_locks.size() - 1, -1, -1):
		if String((_locks[i] as Dictionary).get("id", "")) == id:
			_locks.remove_at(i)


func lock_ids() -> Array:
	var out: Array = []
	for it in _locks:
		out.append(String((it as Dictionary).get("id", "")))
	return out


# ------------------------------------------------------------------
# 跳过
# ------------------------------------------------------------------

func can_skip() -> bool:
	if _active == null:
		return false
	var a: Dictionary = _active
	if not bool(a.get("skippable", true)):
		return false
	if String(a.get("waiting", "")) == "map":
		return false
	var steps: Array = a.get("steps", [])
	# ★ 只要**整段演出里**有一步是「必须玩家操作才能过」的，整段都不许跳过
	#   （否则玩家可以在进入那一步之前按 Esc 把整段跳掉，等于绕过了强制操作）。
	for step in steps:
		if typeof(step) == TYPE_DICTIONARY \
				and (step as Dictionary).has("skippable") \
				and not bool((step as Dictionary).get("skippable", true)):
			return false
	return true


## ★ 脚本 / 玩家操作推进当前对话（立即结束这一条，不等计时 / 点击）。
## 返回 true = 当前确实有一条对话在等。
func advance_dialogue() -> bool:
	if _active == null:
		return false
	var a: Dictionary = _active
	if String(a.get("waiting", "")) != "dialogue":
		return false
	if _has_host("story_advance_dialogue"):
		host.story_advance_dialogue()
	else:
		on_dialogue_finished(int(a.get("dialogue_token", -1)))
	return true


## 请求跳过当前演出。返回 true = 已经跳过。
func request_skip() -> bool:
	if not can_skip():
		return false
	_finish_active(true)
	return true


# ------------------------------------------------------------------
# 内部：演出队列 / 步骤
# ------------------------------------------------------------------

func _start_next() -> void:
	if _active != null or _queue.is_empty():
		return
	var perf: Dictionary = _queue.pop_front()
	perf["index"] = 0
	perf["created_locks"] = {}
	perf["camera_lock"] = false
	perf["wait_timer"] = 0.0
	perf["waiting"] = ""
	perf["dialogue_token"] = -1
	perf["map_token"] = -1
	perf["step_data"] = {}
	_active = perf
	# 立即执行第一步（wait / lock / dialogue…），不必等到下一帧。
	_advance_active(0.0)


func _advance_active(dt: float) -> void:
	if _active == null:
		return
	var a: Dictionary = _active
	# 等待宿主回调（对话 / 换图）：不推进。
	if String(a.get("waiting", "")) != "":
		return
	# 计时等待：到点后先做这一步的收尾（镜头移动结束后的 lock/follow），再**跨过这一步**。
	var timer: float = float(a.get("wait_timer", 0.0))
	if timer > 0.0:
		timer -= dt
		a["wait_timer"] = timer
		if timer > 0.0:
			return
		# ★ 关键：wait / camera_move 是「当前这一步」在等；到点后必须 index+1，
		#   否则下一轮会重新执行同一个 wait，永远停在这里。
		var step_data: Dictionary = a.get("step_data", {})
		if bool(step_data.get("after_wait", false)):
			_after_wait_camera(a, step_data)
		a["index"] = int(a.get("index", 0)) + 1
		a["step_data"] = {}
	# ★ 到这里时 timer 已经归零；再检查一次步骤范围（可能刚好结束）。
	var steps_now: Array = a.get("steps", [])
	if int(a.get("index", 0)) >= steps_now.size():
		_finish_active(false)
		return

	var steps: Array = a.get("steps", [])
	var guard := 0
	while _active != null and String(a.get("waiting", "")) == "" and int(a.get("wait_timer", 0.0)) <= 0.0:
		guard += 1
		if guard > 512:
			push_error("演出步骤连续执行超过 512 步，已中止（可能是 wait_until 条件恒真）")
			_finish_active(false)
			return
		var idx := int(a.get("index", 0))
		if idx < 0 or idx >= steps.size():
			_finish_active(false)
			return
		var step: Dictionary = steps[idx]
		var res: String = _execute_step(a, step)
		if res == "end":
			_finish_active(false)
			return
		if res == "wait" or res == "wait_dialogue" or res == "wait_map":
			return
		# continue：下一步
		a["index"] = idx + 1
		a["step_data"] = {}
		# 循环继续（a / steps 仍然有效；_active 可能被 _execute_step 改掉）
		a = _active
		if a == null:
			return
		steps = a.get("steps", [])


## 执行一步。返回：
##   "continue" = 立刻继续下一步
##   "wait" / "wait_dialogue" / "wait_map" = 停在这里等
##   "end" = 结束整段演出
func _execute_step(a: Dictionary, step: Dictionary) -> String:
	var kind := String(step.get("kind", ""))
	match kind:
		Consts.STEP_WAIT:
			var sec := maxf(0.0, float(step.get("sec", step.get("duration", 0.0))))
			if sec <= 0.0:
				return "continue"
			a["wait_timer"] = sec
			return "wait"

		Consts.STEP_LOCK_INPUT:
			lock_input(String(step.get("id", "")), step.get("allow", null),
				bool(step.get("persist", false)))
			return "continue"

		Consts.STEP_UNLOCK_INPUT:
			unlock_input(String(step.get("id", "")))
			return "continue"

		Consts.STEP_CAMERA_MOVE:
			return _step_camera_move(a, step)

		Consts.STEP_CAMERA_LOCK:
			_camera_lock(a, bool(step.get("persist", false)))
			return "continue"

		Consts.STEP_CAMERA_UNLOCK:
			_camera_unlock(a)
			return "continue"

		Consts.STEP_CAMERA_FOLLOW:
			# ★ 传的是**目标描述**而不是解析后的点：单位会移动，宿主每帧自己解析。
			_camera_lock(a, bool(step.get("persist", false)))
			if _has_host("story_camera_follow"):
				host.story_camera_follow(step.get("target", null))
			return "continue"

		Consts.STEP_MAP_BOUNDARY:
			return _step_boundary(step, false)

		Consts.STEP_MAP_BOUNDARY_EXPAND:
			return _step_boundary(step, true)

		Consts.STEP_MAP_EXPAND:
			return _step_map_expand(a, step)

		Consts.STEP_GRANT_RESOURCES:
			# ★ 本机玩家专用：即使剧本写了别的阵营，也只在**本机席位**上加。
			var fid := String(world.my_faction) if world != null else ""
			var food := float(step.get("food", 0.0))
			var gold := float(step.get("gold", 0.0))
			if world != null:
				world.grant_resources(fid, food, gold)
			if _has_host("story_resource_gain"):
				host.story_resource_gain(food, gold)
			return "continue"

		Consts.STEP_KILL_UNITS:
			ActionsRes.kill_units(world, step.get("targets", []), bool(step.get("silent", false)))
			return "continue"

		Consts.STEP_DESTROY_BUILDINGS:
			ActionsRes.destroy_buildings(world, step.get("targets", []), bool(step.get("silent", false)))
			return "continue"

		Consts.STEP_DIALOGUE:
			return _step_dialogue(a, step)

		Consts.STEP_SPAWN_RED_DOT:
			ActionsRes.spawn_red_dot(world, step)
			return "continue"

		Consts.STEP_SPAWN_UNIT:
			ActionsRes.spawn_units(world, step)
			return "continue"

		Consts.STEP_SPAWN_BUILDING:
			ActionsRes.spawn_building(world, step)
			return "continue"

		Consts.STEP_GLOW_OBJECT:
			ActionsRes.glow_objects(world, step)
			return "continue"

		Consts.STEP_GLOW_ZONE:
			ActionsRes.glow_zones(world, step)
			return "continue"

		Consts.STEP_STOP_GLOW:
			ActionsRes.stop_glow(world, step)
			return "continue"

		Consts.STEP_GLOW_COMMAND_CARD:
			if _has_host("story_glow_command_card"):
				host.story_glow_command_card(String(step.get("unit_kind", "")).strip_edges())
			return "continue"

		Consts.STEP_GUIDE_SELECTION:
			if _has_host("story_guide_selection"):
				host.story_guide_selection(step)
			return "continue"

		Consts.STEP_GUIDE_CLEAR:
			if _has_host("story_guide_clear"):
				host.story_guide_clear(String(step.get("id", "")).strip_edges())
			return "continue"

		Consts.STEP_OBJECTIVE_SET:
			ActionsRes.set_story_objective(world, step)
			return "continue"

		Consts.STEP_OBJECTIVE_DONE:
			ActionsRes.finish_story_objective(world)
			return "continue"

		Consts.STEP_INPUT_POLICY:
			ActionsRes.set_input_policy(world, step)
			return "continue"

		Consts.STEP_UNIT_CONTROL:
			ActionsRes.set_unit_control(world, step)
			return "continue"

		Consts.STEP_SET_VAR:
			ActionsRes.set_story_var(world, step)
			return "continue"

		Consts.STEP_OUTCOME:
			var result := String(step.get("result", "win")).strip_edges()
			if _has_host("story_outcome"):
				host.story_outcome(result)
			elif world != null:
				world.force_outcome(result, String(step.get("reason", "")))
			return "continue"

		Consts.STEP_WAIT_UNTIL:
			var cond: Callable = step.get("condition", Callable())
			if cond.is_valid() and bool(cond.call()):
				return "continue"
			# 每帧轮询；wait_timer 保持 0，下一帧继续。
			return "wait"

		Consts.STEP_CALL:
			var fn: Callable = step.get("fn", Callable())
			if fn.is_valid():
				fn.call()
			return "continue"

		Consts.STEP_END:
			return "end"

		_:
			push_warning("演出：不认识的步骤 kind「%s」，已跳过" % kind)
			return "continue"
	return "continue"


func _step_camera_move(a: Dictionary, step: Dictionary) -> String:
	var point: Vector2 = ActionsRes.resolve_point(world, step.get("target", null))
	if point.x < 0.0:
		push_warning("演出：镜头移动目标解析失败：%s" % str(step.get("target", null)))
		return "continue"
	var sec := maxf(0.0, float(step.get("sec", _camera_default_sec())))
	var zoom := float(step.get("zoom", -1.0))
	var ease := String(step.get("ease", _camera_default_ease()))
	var lock_after := bool(step.get("lock", true))
	var follow := bool(step.get("follow", false))
	var persist := bool(step.get("persist", false))
	_camera_lock(a, persist)
	if _has_host("story_camera_move"):
		host.story_camera_move(point, sec, zoom, ease)
	# 移动结束后：保持锁定 / 跟随 / 还给玩家（在 `_after_wait_camera` 里落）。
	var data := {
		"after_wait": true,
		"lock_after": lock_after,
		"follow": follow,
		"persist": persist,
		"point": point,
		"target": step.get("target", null),
	}
	if sec <= 0.0:
		_after_wait_camera(a, data)
		a["step_data"] = {}
		return "continue"
	a["step_data"] = data
	a["wait_timer"] = sec
	return "wait"


func _after_wait_camera(a: Dictionary, data: Dictionary) -> void:
	var follow := bool(data.get("follow", false))
	var lock_after := bool(data.get("lock_after", true))
	if follow:
		if _has_host("story_camera_follow"):
			host.story_camera_follow(data.get("target", null))
		return
	if lock_after:
		return
	# 不保持锁定：把镜头还给玩家。
	# ★ `persist` 只在「保持锁定」时有意义；lock=false 时一律交还，否则会永久锁死。
	_camera_unlock(a)


func _step_boundary(step: Dictionary, expand_only: bool) -> String:
	if world == null or world.map == null:
		return "continue"
	var full := bool(step.get("full", false))
	var target := Rect2i(0, 0, int(world.map.cols), int(world.map.rows))
	if not full:
		target = ActionsRes.parse_rect(step.get("rect", null))
		if target.size.x <= 0 or target.size.y <= 0:
			push_warning("演出：map_boundary 缺少合法 rect / full")
			return "continue"
	if expand_only:
		var cur: Rect2i = world.map.active_rect
		if not ActionsRes.rect_contains(target, cur):
			push_error("演出：map_boundary_expand 不允许缩小边界（当前 %s，目标 %s）"
				% [str(cur), str(target)])
			return "continue"
	if full:
		world.reset_boundary()
	else:
		world.set_boundary(target)
	if _has_host("story_refresh_boundary"):
		host.story_refresh_boundary()
	return "continue"


func _step_map_expand(a: Dictionary, step: Dictionary) -> String:
	var map_id := String(step.get("map", "")).strip_edges()
	if map_id == "":
		push_error("演出：map_expand 缺少 map")
		return "continue"
	_serial += 1
	var token := _serial
	a["waiting"] = "map"
	a["map_token"] = token
	var opts := {
		"fade_sec": float(step.get("fade_sec", -1.0)),
		"focus": step.get("focus", null),
		"boundary": step.get("boundary", null),
		"path": String(step.get("path", "")).strip_edges(),
	}
	if not _has_host("story_expand_map"):
		# 无宿主（纯逻辑测试）：只换世界地图，不重建视图；直接继续下一步。
		var path := String(opts.get("path", ""))
		if path == "":
			path = "res://data/maps/%s/map.json" % map_id
		if world != null:
			world.swap_map(path)
		a["waiting"] = ""
		return "continue"
	host.story_expand_map(map_id, opts, token)
	return "wait_map"


func _step_dialogue(a: Dictionary, step: Dictionary) -> String:
	var text := String(step.get("text", ""))
	_serial += 1
	var token := _serial
	# 对话是模态：只允许「推进对话 / 跳过演出」。
	lock_input("__dialogue__", [Consts.ACT_DIALOGUE, Consts.ACT_SKIP], true)
	a["waiting"] = "dialogue"
	a["dialogue_token"] = token
	if not _has_host("story_show_dialogue"):
		# 无宿主（纯逻辑测试）：直接跳过这一步，避免挂死。
		_remove_lock("__dialogue__")
		a["waiting"] = ""
		return "continue"
	host.story_show_dialogue(token, text, step)
	return "wait_dialogue"


func _camera_lock(a: Dictionary, persist: bool) -> void:
	if _has_host("story_camera_lock"):
		host.story_camera_lock(true)
	if not persist:
		a["camera_lock"] = true


func _camera_unlock(a: Dictionary) -> void:
	if _has_host("story_camera_lock"):
		host.story_camera_lock(false)
	a["camera_lock"] = false


func _finish_active(skipped: bool) -> void:
	if _active == null:
		return
	var a: Dictionary = _active
	# 对话：清掉对话框与模态锁。
	if String(a.get("waiting", "")) == "dialogue":
		if _has_host("story_clear_dialogue"):
			host.story_clear_dialogue()
	_remove_lock("__dialogue__")
	# 本演出创建的输入锁（persist 的没有记进来）。
	var created: Dictionary = a.get("created_locks", {})
	for k in created.keys():
		_remove_lock(String(k))
	created.clear()
	# 镜头锁（persist 的没有记）。
	if bool(a.get("camera_lock", false)) and _has_host("story_camera_lock"):
		host.story_camera_lock(false)
	a["camera_lock"] = false
	a["waiting"] = ""
	_active = null
	# 跳过 / 正常结束都不撤销世界效果（资源 / 击杀 / 摧毁 / 边界 / 换图）。
	if skipped:
		pass


# ------------------------------------------------------------------
# 内部：宿主回调
# ------------------------------------------------------------------

## 对话框推进 / 自动到期后由宿主调用。
func on_dialogue_finished(token: int) -> void:
	if _active == null:
		return
	var a: Dictionary = _active
	if String(a.get("waiting", "")) != "dialogue":
		return
	if int(a.get("dialogue_token", -1)) != token:
		return
	_remove_lock("__dialogue__")
	a["waiting"] = ""
	a["index"] = int(a.get("index", 0)) + 1
	a["step_data"] = {}
	_advance_active(0.0)


## 换图完成后由宿主调用（ok = false 时仍然继续下一段，不卡死）。
func on_map_expanded(token: int, ok: bool) -> void:
	if _active == null:
		return
	var a: Dictionary = _active
	if String(a.get("waiting", "")) != "map":
		return
	if int(a.get("map_token", -1)) != token:
		return
	if not ok:
		push_warning("演出：换图失败，已跳过该步骤")
	a["waiting"] = ""
	a["index"] = int(a.get("index", 0)) + 1
	a["step_data"] = {}
	_advance_active(0.0)


# ------------------------------------------------------------------
# 内部：触发器检查
# ------------------------------------------------------------------

func _check_triggers(events: Array) -> void:
	var cmds: Array = _pending_commands
	_pending_commands = []

	for it in _triggers:
		var tr: Dictionary = it
		if bool(tr.get("fired", false)) and bool(tr.get("once", true)):
			continue
		var cooldown: float = float(tr.get("cooldown", 0.0))
		if cooldown > 0.0 and world != null \
				and float(world.time) - float(tr.get("last_time", -1e30)) < cooldown:
			continue

		var params: Dictionary = tr.get("params", {})
		var hit := false
		match String(tr.get("kind", "")):
			Consts.TRIGGER_START:
				hit = not _start_tick_done
			Consts.TRIGGER_TIME:
				hit = world != null and float(world.time) >= float(params.get("sec", 0.0))
			Consts.TRIGGER_ZONE_OWNER:
				hit = _zone_owner_matches(int(params.get("zone", -1)),
					String(params.get("owner", "")))
			Consts.TRIGGER_EVENT:
				hit = _any_event_matches(events, String(params.get("type", "")),
					params.get("filter", null))
			Consts.TRIGGER_UNIT_DEAD:
				hit = _any_event_matches_types(events, [Consts.EV_KILL, Consts.EV_LEADER_DOWNED],
					params.get("filter", null))
			Consts.TRIGGER_BUILDING_DESTROYED:
				hit = _any_event_matches_types(events, [Consts.EV_BUILDING_DOWN],
					params.get("filter", null))
			Consts.TRIGGER_COMMAND:
				var want := String(params.get("kind", ""))
				for cmd in cmds:
					if typeof(cmd) != TYPE_DICTIONARY:
						continue
					if want == "" or String((cmd as Dictionary).get("kind", "")) == want:
						hit = true
						break
			Consts.TRIGGER_CONDITION:
				var c: Callable = params.get("condition", Callable())
				hit = c.is_valid() and bool(c.call())
			_:
				continue

		if not hit:
			continue
		tr["fired"] = true
		tr["last_time"] = float(world.time) if world != null else 0.0
		_serial += 1
		_queue.append({
			"id": _serial,
			"steps": (tr.get("steps", []) as Array).duplicate(true),
			"skippable": bool(tr.get("skippable", true)),
		})
		if _active == null:
			_start_next()

	_start_tick_done = true


func _zone_owner_matches(zone: int, owner: String) -> bool:
	if world == null or world.zones == null or zone < 0:
		return false
	var z = world.zone_by_id(zone)
	if z == null:
		return false
	return String(z.get("owner", "")) == owner


func _any_event_matches(events: Array, type_filter: String, filter: Variant) -> bool:
	for e in events:
		if TriggersRes.event_matches(world, e, type_filter, filter):
			return true
	return false


func _any_event_matches_types(events: Array, types: Array, filter: Variant) -> bool:
	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var t := String((e as Dictionary).get("type", ""))
		if not types.has(t):
			continue
		if TriggersRes.event_matches(world, e, t, filter):
			return true
	return false


# ------------------------------------------------------------------
# 内部：工具
# ------------------------------------------------------------------

func _has_host(method: String) -> bool:
	return host != null and host.has_method(method)


func _camera_default_sec() -> float:
	if host != null:
		var c = host.get("cfg")
		if c != null:
			return float(c.num("story.camera.move_sec", 1.2))
	return 1.2


func _camera_default_ease() -> String:
	if host != null:
		var c = host.get("cfg")
		if c != null:
			return String(c.str_val("story.camera.ease", "cubic"))
	return "cubic"
