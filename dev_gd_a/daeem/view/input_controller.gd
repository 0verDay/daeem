## input_controller.gd —— ★ 输入 → 命令（唯一允许读鼠标的地方）
##                          （对应 HTML 版 main.js 的 bindInput / orderMove / pickAt）
##
## 职责边界（docs/architecture.md 3.1）：
##   本文件把玩家意图变成**可序列化的命令字典**，交给 command_processor 执行；
##   `select` 是**纯本地**的（选中列表不进命令流、不上网）。
##
## ★ 本文件不改逻辑状态：想改世界只有一条路 —— 发命令。
##   第 1 轮联机时，唯一的变化是命令不再直接进 command_processor，
##   而是先发给服务器、盖章后再回来；**logic/ 一行都不用改**。
##
## ★★ 坐标换算（HTML 版为这个吃过一次大亏）：
##   屏幕 → 世界一律走 `get_global_mouse_position()`（Camera2D 自己算），
##   世界（像素）→ 世界（格）走 palette.to_logic()。
##   **绝不自己手算屏幕坐标**，那是错位的开始。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")

## 产出命令（由 view/main.gd 消费并执行）
signal command_issued(cmd: Dictionary)
## 纯本地 UI 状态变化（选中、建造模式…），只影响渲染
signal local_ui_changed()
## 提示气泡
signal toast(text: String)

var cfg: ConfigRes = null
var world = null
var camera_rig = null

## 选中列表（纯本地，**不进命令流**）
var selected_units: Array = []
var selected_building = null
## 建造模式：'' | 'wall' | 'tower'
var build_type: String = ""

## 供渲染读取的悬停状态
var hover_tile: Vector2i = Vector2i(-1, -1)
var hover_valid: bool = false
var mouse_world: Vector2 = Vector2.ZERO
var move_marks: Array[Vector2] = []
## 行军攻击的目标点（右键双击）。与 move_marks 分开画：那个是绿的，这个是红的。
var attack_marks: Array[Vector2] = []
var debug_aim: bool = false

## 暂停 / 区块名显示（纯本地开关）
var paused: bool = false
var show_zone_names: bool = true


func setup(p_cfg: ConfigRes, p_world, p_camera_rig) -> void:
	cfg = p_cfg
	world = p_world
	camera_rig = p_camera_rig
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	selected_units = []
	selected_building = null


## 每帧更新一次「鼠标在哪、指向哪个地块」——渲染要用，且**只有这里**读鼠标位置
func poll_mouse() -> void:
	if world == null:
		return
	mouse_world = PaletteRes.to_logic(get_global_mouse_position(), cfg)
	var t := Vector2i(floori(mouse_world.x), floori(mouse_world.y))
	var inside: bool = world.map.terrain.has(t.x, t.y)
	var changed: bool = (t != hover_tile) or (inside != hover_valid)
	hover_tile = t if inside else Vector2i(-1, -1)
	if build_type != "":
		hover_valid = inside and world.can_build_at(t.x, t.y)
	else:
		hover_valid = inside


# ------------------------------------------------------------------
# 键盘
# ------------------------------------------------------------------
## @return true 表示这个事件被消费了（不再往下传）
func handle_key(event: InputEventKey) -> bool:
	if not event.pressed or event.echo:
		return false
	var k := event.keycode

	# 1/2/3：快速选中将领
	for i in 3:
		if k == KEY_1 + i:
			select_general_by_hotkey(str(i + 1))
			return true

	match k:
		KEY_B:
			set_build_type("wall" if build_type != "wall" else "")
			return true
		KEY_T:
			set_build_type("tower" if build_type != "tower" else "")
			return true
		KEY_X, KEY_DELETE:
			demolish_selected()
			return true
		KEY_ESCAPE:
			if build_type != "":
				set_build_type("")
			else:
				select_units([])
			return true
		KEY_N:
			show_zone_names = not show_zone_names
			local_ui_changed.emit()
			return true
		KEY_P:
			paused = not paused
			toast.emit("已暂停" if paused else "继续")
			return true
		KEY_E:
			# 调试：刷一个测试敌人（命令流走 spawn_enemy，与联机同一条路）
			command_issued.emit({"kind": "spawn_enemy", "faction": FactionRes.NPC_FACTION})
			return true
		KEY_G:
			debug_aim = not debug_aim
			toast.emit("坐标准星：开" if debug_aim else "坐标准星：关")
			return true
		KEY_F:
			camera_rig.fit_to_map()
			return true
		KEY_HOME:
			camera_rig.center_on_home(world)
			return true
	return false


# ------------------------------------------------------------------
# 鼠标
# ------------------------------------------------------------------
func handle_mouse_button(event: InputEventMouseButton) -> bool:
	if not event.pressed:
		return false
	# 缩放方向（已按实测钉住，别凭直觉改）：
	#   向上滚 = 放大（拉近）→ zoom **乘** zoom_step
	#   向下滚 = 缩小（拉远）→ zoom **除** zoom_step
	#
	# ★ Godot 的 `Camera2D.zoom` 语义是**放大倍数**：值越大，画面里的东西越大。
	#   ⚠️ 这里来回错过两次，两次都是「凭直觉写、靠眼睛猜」：
	#      第一次整体反了；第二次我把「Godot 里 zoom 越小画面越大」当结论照抄，又反了一次。
	#   可靠的验证只有两条：跑 tests/test_view.gd 的 `_test_zoom_direction`
	#   （它真的构造滚轮事件、读回 zoom 数值），或者手玩一次看画面是拉近还是拉远。
	var step: float = cfg.num("camera.zoom_step", 1.12)
	match event.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			camera_rig.zoom_at(event.position, step)
			return true
		MOUSE_BUTTON_WHEEL_DOWN:
			camera_rig.zoom_at(event.position, 1.0 / step)
			return true
		MOUSE_BUTTON_LEFT:
			_on_left_click(event.shift_pressed)
			return true
		MOUSE_BUTTON_RIGHT:
			# ★ 双击 = 行军攻击（Godot 自己带双击判定，不用手写计时器）
			_on_right_click(event.double_click)
			return true
	return false


## 左键：建造模式下放置；否则选中单位 / 建筑
func _on_left_click(additive: bool) -> void:
	if world == null or hover_tile.x < 0:
		return
	if build_type != "":
		# ★ 只发意图，不放结果：落成与否由 command_processor 判定
		command_issued.emit({
			"kind": "build", "build_type": build_type,
			"tx": hover_tile.x, "ty": hover_tile.y,
			"faction": world.my_faction,
		})
		return

	var hit_unit = _pick_unit_at(mouse_world)
	if hit_unit != null:
		var next: Array = selected_units.duplicate() if additive else []
		if additive and next.has(hit_unit):
			next.erase(hit_unit)
		elif not next.has(hit_unit):
			next.append(hit_unit)
		select_units(next)
		return

	var hit_building = world.building_at(hover_tile.x, hover_tile.y)
	if hit_building != null:
		select_building(hit_building)
		return

	if not additive:
		select_units([])


## 右键：
##   · **单击敌人 / 建筑** → 优先攻击它（`attack` 命令）
##   · **双击任意位置** → 行军攻击到该点（`attack_move`，等价于 SC2 的按 A 攻击）
##   · 单击空地        → 普通移动（`move`，遇敌不停）
func _on_right_click(double_click: bool = false) -> void:
	if build_type != "":
		set_build_type("")
		return
	if selected_units.is_empty() or hover_tile.x < 0:
		return
	var ids: Array = []
	for u in selected_units:
		if u.alive:
			ids.append(u.id)
	if ids.is_empty():
		return

	# ★ 双击：行军攻击（到点，路上遇敌就打）
	if double_click:
		command_issued.emit({
			"kind": "attack_move", "ids": ids,
			"x": mouse_world.x, "y": mouse_world.y,
			"faction": world.my_faction,
		})
		clear_marks()
		attack_marks = [mouse_world]
		local_ui_changed.emit()
		return

	# 单击：鼠标底下是敌对单位 → 点名打它
	var foe = _pick_foe_unit_at(mouse_world)
	if foe != null:
		command_issued.emit({
			"kind": "attack", "ids": ids, "target_id": foe.id,
			"faction": world.my_faction,
		})
		clear_marks()
		local_ui_changed.emit()
		return

	# 单击：鼠标底下是敌对建筑 → 点名拆它（命令里只带地块，不带对象引用）
	var foe_b = world.building_at(hover_tile.x, hover_tile.y)
	if foe_b != null and foe_b.alive and not FactionRes.same_side(foe_b.owner, world.my_faction):
		command_issued.emit({
			"kind": "attack", "ids": ids, "tx": hover_tile.x, "ty": hover_tile.y,
			"faction": world.my_faction,
		})
		clear_marks()
		local_ui_changed.emit()
		return

	# 否则就是普通移动：点到哪走到哪（**遇敌不停**，这是它和行军攻击的区别）
	command_issued.emit({
		"kind": "move", "ids": ids,
		"x": mouse_world.x, "y": mouse_world.y,
		"faction": world.my_faction,
	})
	clear_marks()
	move_marks = [mouse_world]
	local_ui_changed.emit()


## 清掉两种标记（移动 / 行军攻击）—— 每次右键只留最新的那一个
func clear_marks() -> void:
	move_marks = []
	attack_marks = []


# ------------------------------------------------------------------
# 本地状态
# ------------------------------------------------------------------

## 选中一批单位。
##
## ★★ 「选中将领时同步选中亲兵」就落在这里 —— **队伍展开放在选中这一步，而不是右键那一步**。
##    为什么这样分：
##      · 选中是**纯本地**状态（不进命令流、不上网），所以展开它不会污染协议；
##      · 右键移动本来就把命令发给「当前选中的全部单位」，
##        于是「同步下达指令」不需要任何额外代码 —— 它就是选中集合的自然结果；
##      · 第 1 轮联机时，命令里永远只带真实的单位 id，服务器盖章那条路不用改。
##    反过来（在右键时展开）会出现：界面上只高亮队长，但命令发给了一堆没显示的兵 ——
##    玩家看不出自己在下令给谁。
func select_units(units: Array) -> void:
	selected_units = world.expand_to_groups(units)
	selected_building = null
	# selected 是逻辑单位上的**渲染标志**（不是权威状态）：由 view 写、view 读
	for u in world.units:
		u.selected = false
	for u in selected_units:
		u.selected = true
	local_ui_changed.emit()


func select_building(b) -> void:
	selected_building = b
	selected_units = []
	for u in world.units:
		u.selected = false
	local_ui_changed.emit()


func select_general_by_hotkey(key: String) -> void:
	for u in world.units:
		if u.alive and FactionRes.same_side(u.faction, world.my_faction) and u.hotkey == key:
			select_units([u])
			camera_rig.center_on_px(PaletteRes.to_px(u.pos, cfg))
			return
	toast.emit("没有快捷键 %s 的将领" % key)


func set_build_type(t: String) -> void:
	build_type = t
	if t != "":
		toast.emit("建造模式：%s（左键放置，右键 / Esc 退出）" % _build_name(t))
	local_ui_changed.emit()


# ------------------------------------------------------------------
# 招募（UI 改版：单位页的命令卡走这条路）
# ------------------------------------------------------------------

## 选中列表里的第一个**队长**（界面上的「对应将领」）。
##
## 为什么在选中列表里找，而不是单独记一个「当前将领」：
##   选中将领时整队（将领 + 亲兵）都会被选中，而队长永远排在队伍第一个
##   （world.group_of() 的顺序契约），所以这里直接取第一个队长就是玩家看到的那个将领。
func first_selected_leader() -> Variant:
	if world == null:
		return null
	for u in selected_units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if world.is_team_leader(u):
			return u
	return null


## 招募一个单位到当前选中的将领名下。
##
## ★ 这里只发**命令**（逻辑层是唯一改世界的地方）；命令里只有兵种与队长 id，
##   没有坐标 —— 站位由 world.recruit_unit() 在权威侧算。
## ★ 没有选中将领时**不发命令**：命令里必须带 leader_id，硬发只会被逻辑层拒掉，
##   而玩家看不到任何反馈。所以直接给一句提示。
##
## @return true = 命令已发出（不代表已经招出来，落成与否看逻辑层）
func request_recruit(kind: String) -> bool:
	var leader = first_selected_leader()
	if leader == null:
		toast.emit("先选中一个将领，才能把新兵招到它名下")
		return false
	command_issued.emit({
		"kind": "recruit", "unit_kind": kind, "leader_id": leader.id,
		"faction": world.my_faction,
	})
	return true


func _build_name(t: String) -> String:
	var v = cfg.get_path_value("building.%s.name" % t)
	return String(v) if typeof(v) == TYPE_STRING else t


## 拆除选中的建筑（X / Delete）—— 命令里只放地块，不放对象引用（要可序列化）
func demolish_selected() -> void:
	if selected_building == null:
		toast.emit("先选中一个建筑")
		return
	command_issued.emit({
		"kind": "demolish", "tx": selected_building.tx, "ty": selected_building.ty,
		"faction": world.my_faction,
	})
	selected_building = null
	local_ui_changed.emit()


## 命中判定：世界坐标 → 最近的、半径内的、**自己这一方**的单位
##
## ★ 只看自己这一方的：重叠时 pickAt 只该选得中自己的单位
##   （HTML 版专门为这条写过回归测试）。
func _pick_unit_at(world_pos: Vector2) -> Variant:
	var best = null
	var best_d := INF
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		var r: float = cfg.unit_radius_of(u.kind) + cfg.num("unit.hit_pad", 6.0) / cfg.cell_px
		var d: float = world_pos.distance_to(u.pos)
		if d <= r and d < best_d:
			best_d = d
			best = u
	return best


## 命中判定：世界坐标 → 最近的、半径内的**敌对**单位（右键点它 = 优先攻击）
## 与 _pick_unit_at 正好互补：那边的判据是 same_side，这边是「不是同一方」。
func _pick_foe_unit_at(world_pos: Vector2) -> Variant:
	var best = null
	var best_d := INF
	for u in world.units:
		if not u.alive:
			continue
		if FactionRes.same_side(u.faction, world.my_faction):
			continue
		var r: float = cfg.unit_radius_of(u.kind) + cfg.num("unit.hit_pad", 6.0) / cfg.cell_px
		var d: float = world_pos.distance_to(u.pos)
		if d <= r and d < best_d:
			best_d = d
			best = u
	return best


## 清理已经阵亡的选中项（由 main 每帧调一次）
func drop_dead_selection() -> void:
	var alive: Array = []
	for u in selected_units:
		if u.alive:
			alive.append(u)
	if alive.size() != selected_units.size():
		select_units(alive)
	if selected_building != null and not selected_building.alive:
		select_building(null)
