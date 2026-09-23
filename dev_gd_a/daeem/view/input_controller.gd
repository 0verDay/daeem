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
## ★★ 选中的**建筑**（纯本地，**不进命令流**）。
##   · `selected_buildings` = 全批（框选建筑时可能有好几个）——左侧 1 + 3×3 按它画，
##     超过 9 个靠滚轮翻页；
##   · `selected_building`  = 其中的**主选中**那一个（右栏正在显示的那个、地图上高亮的那个）。
##     单选时它就是唯一那个 —— 于是老代码读 `selected_building` 仍然拿到「该显示哪个建筑」。
var selected_buildings: Array = []
var selected_building = null
## ★ 玩家**点到的那个单位**（纯本地，只给详细信息右栏用）。
##
## 「选中的部队」是一份集合（点一个兵会把整队带出来、框选会把几支队一起带出来），
## 而参考图要右栏报「**玩家点击的那个单位**」—— 集合本身说不出这句话：
## 一次点选与一次框选出来的 selected_units 长得一模一样。
## 所以这里单独记一笔，并且只有两处写它：
##   · `_on_left_click`（在地图上点了某个单位 —— 此时 origin 记成 "click"）；
##   · `view/hud.gd` 的 `_on_grid_unit_activated`（点了左栏下半的单位格，同样记 "click"）。
## 框选 / 点左侧部队列表 / 按 1-2-3 / 选中建筑或区划时一律清掉（那些不是「点某个单位」）。
##
## ★★ 这份状态唯一的坑就是「谁清它」：以后新增「批量选中」的入口时，
##    必须顺手调 `select_units()`（它自己会清），否则右栏会一直停在上一次点到的那个兵身上。
var clicked_unit = null
## ★★ 这一次「选中单位」是**怎么来的**（纯本地，只给详细信息右栏用）：
##   · `"click"` = 玩家在地图上**单击**了某个单位（`_on_left_click`），
##                 或者点了左栏下半的单位格（view/hud.gd 的 _on_grid_unit_activated）；
##   · `"drag"`  = 其它一切批量选中（框选 / 点左侧部队列表 / 1-2-3 / 清空）。
##
## ★ 为什么需要它（手玩原话）：「右栏的逻辑为，当玩家通过**拖拽**选中部队时，默认显示
##   该部队的将领，若拖拽选中多个部队，则显示展开的部队（序号靠前的部队）的将领，
##   若玩家通过**鼠标单击**选中任意单位以选中部队时，默认显示玩家单击选中的单位」。
##   ⇒ 光看 `clicked_unit` 分不开这两种：拖完一次框，`selected_units` 与点选长得一样，
##     而 `clicked_unit` 已经被 `select_units()` 清掉了（见那里的注释）。
##
## ⚠️ 它只在**选中集合变化**的那几处写：`select_units()` 一律先按批量（"drag"）处理，
##    `_on_left_click` 在它之后把 origin 与 `clicked_unit` 一起写回去。
var selection_origin: String = "drag"
## ★ 选中的**区划**（左键点区划中心 = 看这个区划的详情）。
## 与上面两者互斥：面板「详细信息」只有一个左栏，同一时刻只有一种选中对象。
var selected_zone = null
## 建造模式：'' | 'wall' | 'tower'
var build_type: String = ""
## ★★ 操作页的**命令模式**（右下「操作」页的命令格 → 点一下进这个模式 → 左键点地图下达）。
##
##   '' | 'move' | 'attack' | 'attack_move' | 'stop'
##
## ★ 为什么要有它：需求要「操作为对部队下达的指令（如移动，攻击，行军等）」，
##   而移动 / 攻击 / 行军原本只有右键一条路 —— 让命令卡上的格子**真的能下令**，
##   就需要一个「先选命令、再选目标」的中间状态（与建造模式同一套手感）。
## ★ 与 build_type **互斥**：进命令模式会退出建造模式，反之亦然
##   （同一个左键不可能既是「放建筑」又是「下指令」）。
## ★ 停止是**即刻**的：进模式那一下就把命令发出去（不需要再点地图）。
var order_mode: String = ""

## 供渲染读取的悬停状态
var hover_tile: Vector2i = Vector2i(-1, -1)
var hover_valid: bool = false
var mouse_world: Vector2 = Vector2.ZERO
var move_marks: Array[Vector2] = []
## 行军攻击的目标点（右键双击）。与 move_marks 分开画：那个是绿的，这个是红的。
var attack_marks: Array[Vector2] = []
var debug_aim: bool = false

## ★★ 框选（左键拖出一个矩形）：起点与当前点都是**世界坐标（格）**。
##
## 需求原话：「为玩家增加一个框选操作，当玩家框到某些己方单位时，视为选中这些单位
##            所属的部队，如果有多个部队，也一同选中」。
##
## · `drag_active` 只表示「**已经越过拖拽阈值**、正在拖框」——
##   没越过的左键仍然是普通单击（按下的那一刻就处理掉了，见 `_on_left_click`）；
## · 展开成「所属部队」这件事**不在这一层做**：`select_units()` 会走
##   `world.expand_to_groups()`，那是选中集合的唯一入口（见那里的说明）。
var drag_active: bool = false
var drag_start_world: Vector2 = Vector2.ZERO
var drag_current_world: Vector2 = Vector2.ZERO
## 左键按下之后、还没判定成「点击还是拖框」的那一段
var _drag_pending: bool = false
## 这次拖框是不是追加（Shift + 左键拖）
var _drag_additive: bool = false
## 按下的屏幕坐标（只用来算「移动了多少像素」——阈值是像素口径，与相机缩放无关）
var _drag_press_screen: Vector2 = Vector2.ZERO

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
	selected_buildings = []
	selected_zone = null
	clicked_unit = null
	selection_origin = "drag"
	order_mode = ""
	# 框选那条状态机也归零（重开一局时别留着上一局的半个框）
	_drag_pending = false
	drag_active = false


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
		KEY_ESCAPE:
			if build_type != "":
				set_build_type("")
			elif order_mode != "":
				set_order_mode("")          # 命令模式：Esc = 放弃这次指令
			elif _drag_pending or drag_active:
				_cancel_drag()          # 拖到一半按 Esc = 放弃这次框选（不动已有选中）
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
	# ★★ 左键的**按下与抬起都要接**（框选是「拖出矩形、松手生效」）。
	#   原来这里开头就 `if not event.pressed: return false` —— 那会把左键抬起直接漏掉，
	#   框永远结束不了（表现是「框选根本没反应」）。
	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_begin_drag(event)
			# 单击行为照旧**在按下那一刻**发生（不改老手感、老测试）：
			# 越过阈值之后，松手那一下会用框选结果覆盖掉它。
			_on_left_click(event.shift_pressed)
		else:
			_finish_drag()
		return true
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
		MOUSE_BUTTON_RIGHT:
			# ★ 双击 = 行军攻击（Godot 自己带双击判定，不用手写计时器）
			_on_right_click(event.double_click)
			return true
	return false


## 鼠标移动：只用来推进框选那条状态机（悬停由 `poll_mouse()` 每帧刷）。
##
## ★ 位置换算走 `_screen_to_logic(event.position)`（引擎的画布变换，与
##   `get_global_mouse_position()` 内部同一条路）——见那个函数的注释。
## ★ 阈值判据用的是**屏幕像素**（`event.position`），所以「拖多远才算框选」与缩放无关。
func handle_mouse_motion(event: InputEventMouseMotion) -> bool:
	if not _drag_pending:
		return false
	var moved: float = _drag_press_screen.distance_to(event.position)
	if not drag_active:
		if moved < _drag_threshold_px():
			return false
		drag_active = true
	drag_current_world = _screen_to_logic(event.position)
	local_ui_changed.emit()
	return true


## 视口（屏幕）坐标 → 世界坐标（格）。
##
## ★ 走的是**引擎给的画布变换**，与 `get_global_mouse_position()` 内部是同一条路
##   （`viewport.get_canvas_transform().affine_inverse() * 屏幕坐标`），
##   只是把「视口记录的鼠标位置」换成**这个事件自己带的坐标**。为什么要这样：
##     · 拖拽时事件坐标才是「这一下鼠标真的在哪」，比全局鼠标状态更准；
##     · 框选因此不依赖全局鼠标状态 —— 无头测试能真的把一条拖拽走完并断言结果
##       （造不出真实鼠标移动的场合，`get_global_mouse_position()` 永远是 (0,0)）。
##   ⚠️ 这**不是**自己手算相机数学（那是 pitfalls 3.1 的错位根因），用的是同一个变换。
func _screen_to_logic(screen_pos: Vector2) -> Vector2:
	return PaletteRes.to_logic(get_viewport().get_canvas_transform().affine_inverse() * screen_pos, cfg)


## 「拖多远才算框选」的像素阈值（config 的 `ui.drag_select_min_px`）。
## ★ 读的是 `config.gd` 载入时算好的字段（见 architecture.md 第 7 条）——
##   它在鼠标移动的路径上，而 `num("…")` 每次都要切字符串。
func _drag_threshold_px() -> float:
	return maxf(0.0, cfg.drag_select_min_px)


## 左键按下：对齐「鼠标在哪」，再记下框选的起点。建造模式下不起框（那一下是「放置建筑」）。
##
## ★ 为什么这里要顺手把 `mouse_world` / `hover_tile` 对齐到**这一个事件**上：
##   按下那一刻的点击判定（`_on_left_click`：选中单位 / 建筑 / 区划、放置建筑）读的是
##   这两个字段，而它们平时由 `poll_mouse()` **每帧**刷 —— 两次刷之间按下鼠标时，
##   判定用的就是上一帧的位置（最多差一帧的移动距离）。用事件自己的坐标更准，
##   而且这样「框选的起点」与「这一次点击的落点」永远是同一个点。
func _begin_drag(event: InputEventMouseButton) -> void:
	drag_start_world = _screen_to_logic(event.position)
	mouse_world = drag_start_world
	_sync_hover_from_mouse()
	# 建造模式：这一下是「放置建筑」，不起框。
	# ★ 命令模式（操作页的移动 / 攻击 / 行军）同理：这一下是「下达指令」，
	#   更不能在松手时被一次拖拽框选**改掉选中**（那样命令就发给了另一批单位）。
	if build_type != "" or order_mode != "":
		_drag_pending = false
		drag_active = false
		return
	_drag_pending = true
	_drag_additive = event.shift_pressed
	_drag_press_screen = event.position
	drag_current_world = drag_start_world
	drag_active = false


## 按当前 `mouse_world` 重算 `hover_tile`（口径与 `poll_mouse()` 里那两行**完全一致**：
## 地图外一律是 (-1,-1)，于是「点到地图外」不会被当成点到左上角那一格）。
func _sync_hover_from_mouse() -> void:
	if world == null:
		hover_tile = Vector2i(-1, -1)
		return
	var t := Vector2i(floori(mouse_world.x), floori(mouse_world.y))
	hover_tile = t if world.map.terrain.has(t.x, t.y) else Vector2i(-1, -1)


## 左键松开：真的拖出过框 → 按框选处理；否则什么都不做（单击在按下时已经处理过了）。
func _finish_drag() -> void:
	if not _drag_pending:
		return
	var active := drag_active
	var start := drag_start_world
	var end := drag_current_world
	var additive := _drag_additive
	_drag_pending = false
	drag_active = false
	if not active:
		return
	box_select(start, end, additive)
	local_ui_changed.emit()


## ★★ 框选本体：把矩形（世界坐标，两个角随便哪个在前）里的**己方存活单位**收集起来，
## 再交给 `select_units()` **展开成它们所属的部队**。
##
## 为什么要走 select_units 而不是自己拼 selected_units：
##   · 那里是选中集合的唯一入口，展开规则（`world.expand_to_groups`：队长 + 全部亲兵）
##     只写在一处 —— 框到一个亲兵也等于选中整支部队（用户需求），多支部队一起选中；
##   · 右侧/左侧的 UI（部队列表高亮、详情面板）读的都是同一份 `selected_units`，
##     所以「左侧部队 ui 也会显示这些部队被选中」是这条路的自然结果。
##
## ★ 只认**自己这一方**的活单位（与左键点选一致：敌人的框选不在需求里）。
##
## ★★ 建筑：**框里一个己方单位都没有**时才轮到建筑（用户需求原话：「当玩家划出的框中
##    没有单位只有己方建筑时，则多选建筑」）—— 单位优先，两者不会被同一次框选一起选中。
##    选中结果交给 `select_buildings()`：第一个是主选中，其余在左侧 1 + 3×3 里翻页显示。
##
## @return 这次框到的东西个数（单位优先；没有单位时是建筑数。给测试用）
func box_select(start: Vector2, end_pos: Vector2, additive: bool = false) -> int:
	if world == null:
		return 0
	var rect := Rect2(start, end_pos - start).abs()
	var picked: Array = []
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if rect.has_point(u.pos):
			picked.append(u)
	if picked.is_empty():
		var buildings := _buildings_in_rect(rect)
		if not buildings.is_empty():
			var next_b: Array = selected_buildings.duplicate() if additive else []
			for b in buildings:
				if not next_b.has(b):
					next_b.append(b)
			select_buildings(next_b)
			return buildings.size()
	var next: Array = selected_units.duplicate() if additive else []
	for u in picked:
		if not next.has(u):
			next.append(u)
	select_units(next)
	return picked.size()


## 矩形（世界坐标，格）里的**己方建筑**（大本营 / 城墙 / 箭塔…）。
##
## ★ 只认自己这一方（与框选单位同一条口径）。
## ★ 无敌的**中立**建筑（区划中心，owner = ""）天然被 `same_side` 挡掉；这里再显式写一条，
##   免得以后有人把中心改成「归属某方」时它突然能被框选（与 command_processor 同一条理由）。
## ★ 命中判据 = **建筑所在格的中心**落在框里（与单位那条 `rect.has_point(u.pos)` 同一个口径）。
func _buildings_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	if world == null:
		return out
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if b.is_invulnerable():
			continue
		if not FactionRes.same_side(b.owner, world.my_faction):
			continue
		if rect.has_point(b.center()):
			out.append(b)
	return out


## 正在拖的那个框（世界坐标；`drag_active` 为 false 时不要画它）。
func drag_box() -> Rect2:
	return Rect2(drag_start_world, drag_current_world - drag_start_world).abs()


## 放弃这次框选（Esc）——**不动已有的选中**：拖到一半反悔不该把队伍丢了。
func _cancel_drag() -> void:
	_drag_pending = false
	drag_active = false
	local_ui_changed.emit()



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

	# ★★ 操作页的命令模式：这一下左键**不再改选中**，而是把那道指令下给当前选中的部队
	#    （见 `order_mode` 的说明；右键 / Esc 退出）。
	if order_mode != "":
		_issue_order_click()
		return

	# ★ 区划中心：**先于单位与建筑**判定。
	#   它是中立障碍（任何单位都进不去那一格），所以点它的时候不会有单位挡在上面；
	#   而且它的语义是「看这个区划的详情」，不是「选中一栋建筑」——
	#   先判它，能让「点中心」这条路不受单位命中半径的影响。
	var center_zone = world.zone_center_zone_at(hover_tile.x, hover_tile.y)
	if center_zone != null:
		select_zone(center_zone)
		return

	var hit_unit = _pick_unit_at(mouse_world)
	if hit_unit != null:
		var next: Array = selected_units.duplicate() if additive else []
		if additive and next.has(hit_unit):
			next.erase(hit_unit)
		elif not next.has(hit_unit):
			next.append(hit_unit)
		# ★ 玩家在地图上点到的那个单位（右栏要按它显示）——
		#   必须在 select_units 之后写：那个函数会把 clicked_unit 清掉（见它的注释）。
		#   顺手把 origin 记成 "click"：右栏的显示规则按「拖拽还是单击」分，
		#   见 `selection_origin` 的注释与 view/hud.gd 的 _right_unit。
		select_units(next)
		clicked_unit = hit_unit if not additive else null
		selection_origin = "click"
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
	# ★ 命令模式下右键 = 退出这个模式（与建造模式一致）——不顺手再下一条移动命令，
	#   否则「反悔」会变成「又下了一条命令」。
	if order_mode != "":
		set_order_mode("")
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
		if not selection_locked():
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
	# ⚠️ 无敌建筑（区划中心）不算「敌对建筑」：它是中立障碍，右点点它应该走「普通移动」
	#    （单位走到旁边站住），而不是发一条会被逻辑层拒掉的攻击命令。
	var foe_b = world.building_at(hover_tile.x, hover_tile.y)
	if foe_b != null and foe_b.alive and not foe_b.is_invulnerable() \
			and not FactionRes.same_side(foe_b.owner, world.my_faction):
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
	if not selection_locked():
		move_marks = [mouse_world]
	local_ui_changed.emit()


## 选中的单位是不是**全都被招募锁住了**（将领正在招募 → 它和它辖下的部队都不接指令）。
##
## ★ 判据来自逻辑层（`world.is_order_locked`）—— 这里只是**先问一句**，
##   用来决定「要不要画那个**没人会走的**移动 / 攻击标记」。
##   命令照旧发出去：权威侧才是最终判据（它还会补一条 `order_rejected` 事件，
##   由 game_scene 翻成左栏那行红字）。
## ★ 为什么要多这一问：标记是「我已经收到命令了」的承诺。被锁住的队伍一个都不会动，
##   却给它画一个绿圈，玩家只会以为移动坏了（与「招募被拒却毫无反馈」同一类问题）。
func selection_locked() -> bool:
	if world == null:
		return false
	var alive := 0
	for u in selected_units:
		if not u.alive:
			continue
		alive += 1
		if not world.is_order_locked(u):
			return false
	return alive > 0


## 清掉两种标记（移动 / 行军攻击）—— 每次右键只留最新的那一个
func clear_marks() -> void:
	move_marks = []
	attack_marks = []


# ------------------------------------------------------------------
# 本地状态
# ------------------------------------------------------------------

## ★ 选中一批单位（**批量入口**：点左侧部队列表 / 框选 / 1-2-3 / 新兵自动入列都走这里）。
##
## ★★ 「选中将领时同步选中亲兵」就落在这里 —— **队伍展开放在选中这一步，而不是右键那一步**。
##    为什么这样分：
##      · 选中是**纯本地**状态（不进命令流、不上网），所以展开它不会污染协议；
##      · 右键移动本来就把命令发给「当前选中的全部单位」，
##        于是「同步下达指令」不需要任何额外代码 —— 它就是选中集合的自然结果；
##      · 第 1 轮联机时，命令里永远只带真实的单位 id，服务器盖章那条路不用改。
##    反过来（在右键时展开）会出现：界面上只高亮队长，但命令发给了一堆没显示的兵 ——
##    玩家看不出自己在下令给谁。
##
## ★★ 顺手清掉 `clicked_unit`：能走到这里的一律是「批量选中」（或者清空选中），
##    不是「在地图上点了某一个单位」。不清的话右栏会一直停在上次点到的那个兵身上。
##    ⚠️ 唯一的例外是 `_on_left_click`：它先调这里、再自己把 `clicked_unit` 写回去。
func select_units(units: Array) -> void:
	selected_units = world.expand_to_groups(units)
	selected_building = null
	selected_buildings = []
	selected_zone = null
	clicked_unit = null
	# ★ 批量入口一律记成 "drag"（框选 / 点左侧列表 / 1-2-3 / 清空都是这一类）；
	#   地图上单击那一路会在调完本函数之后自己把它改回 "click"（见 `_on_left_click`）。
	selection_origin = "drag"
	# selected 是逻辑单位上的**渲染标志**（不是权威状态）：由 view 写、view 读
	for u in world.units:
		u.selected = false
	for u in selected_units:
		u.selected = true
	local_ui_changed.emit()


## ★ 选中一个**区划**（左键点它的中心建筑）：左栏显示这个区划的详情。
##
## 与选中单位 / 建筑互斥：三种选中状态同一时刻只有一种（面板只有一个左栏）。
func select_zone(zone) -> void:
	selected_zone = zone
	selected_units = []
	selected_building = null
	selected_buildings = []
	clicked_unit = null
	for u in world.units:
		u.selected = false
	local_ui_changed.emit()


## ★ 选中**一个**建筑（左键点它）：等价于「只选中它一个」的那批。
func select_building(b) -> void:
	select_buildings([] if b == null else [b])


## ★★ 选中一批**建筑**（框选建筑那条路的落点；左键点单个也走这里）。
##
##   · `selected_buildings` = 全批，顺序 = 传进来的顺序（框选时就是 `world.building_list`
##     的顺序，也就是「地图上的先后」）；
##   · `selected_building`  = 第一个 —— **主选中**：右栏显示它、地图上高亮它。
##     玩家点左侧某一格只改这一个（换成那一格的建筑），不动整批（见 view/hud.gd）。
##
## ★ 与选中单位 / 区划互斥：三种选中状态同一时刻只有一种（详细信息面板只有一个左栏）。
## ★ 这里**不设上限**：选中的建筑可能多于一屏，左侧 1 + 3×3 靠滚轮翻页显示（用户需求）。
func select_buildings(list: Array) -> void:
	selected_buildings = []
	for b in list:
		if b != null and not selected_buildings.has(b):
			selected_buildings.append(b)
	selected_building = selected_buildings[0] if not selected_buildings.is_empty() else null
	selected_units = []
	selected_zone = null
	clicked_unit = null
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
		order_mode = ""                 # 两种「模式」互斥（同一个左键不能既放建筑又下指令）
		toast.emit("建造模式：%s（左键放置，右键 / Esc 退出）" % _build_name(t))
	local_ui_changed.emit()


# ------------------------------------------------------------------
# 操作页的命令模式（点「移动 / 攻击 / 行军 / 停止」那一格进来）
# ------------------------------------------------------------------

## 进 / 退出某个命令模式。**点同一格再点一次 = 退出**（与建造模式同一个手感）。
##
## @param m "" | "move" | "attack" | "attack_move"
##        （★ 「停止」没有目标，不走这里 —— 见 `request_stop()`）
## @return 进入之后当前是不是这个模式（false = 这次是「退出」）
func set_order_mode(m: String) -> bool:
	order_mode = "" if m == order_mode else m
	if order_mode != "":
		build_type = ""                # 互斥：进命令模式会退出建造模式
	local_ui_changed.emit()
	return order_mode != ""


## 「停止」：**立刻**对当前选中的部队下达 `stop`（它不需要点地图选目标）。
## @return true = 命令已发出（选中里有活着的单位）
func request_stop() -> bool:
	var ids: Array = []
	for u in selected_units:
		if u.alive:
			ids.append(u.id)
	if ids.is_empty():
		toast.emit("先选中一支部队，才能下达指令")
		return false
	command_issued.emit({"kind": "stop", "ids": ids, "faction": world.my_faction})
	clear_marks()
	order_mode = ""
	local_ui_changed.emit()
	return true


## 命令模式下的左键：把那道指令下给**当前选中的部队**。
##
## ★ 只发命令（可序列化字典），站位 / 结果全在权威侧算 —— 与右键那条路完全同源。
## ★ 「攻击」找不到目标时**留在模式里**并给一句提示：玩家点歪了还能再点一下，
##   不必重新回命令卡点一次（Esc / 右键随时退出）。
func _issue_order_click() -> void:
	var ids: Array = []
	for u in selected_units:
		if u.alive:
			ids.append(u.id)
	if ids.is_empty():
		toast.emit("先选中一支部队，才能下达指令")
		set_order_mode("")
		return

	match order_mode:
		"move":
			command_issued.emit({
				"kind": "move", "ids": ids,
				"x": mouse_world.x, "y": mouse_world.y,
				"faction": world.my_faction,
			})
			clear_marks()
			if not selection_locked():
				move_marks = [mouse_world]
			set_order_mode("")
		"attack_move":
			command_issued.emit({
				"kind": "attack_move", "ids": ids,
				"x": mouse_world.x, "y": mouse_world.y,
				"faction": world.my_faction,
			})
			clear_marks()
			if not selection_locked():
				attack_marks = [mouse_world]
			set_order_mode("")
		"attack":
			var foe = _pick_foe_unit_at(mouse_world)
			if foe != null:
				command_issued.emit({
					"kind": "attack", "ids": ids, "target_id": foe.id,
					"faction": world.my_faction,
				})
				clear_marks()
				set_order_mode("")
				return
			var foe_b = world.building_at(hover_tile.x, hover_tile.y)
			if foe_b != null and foe_b.alive and not foe_b.is_invulnerable() \
					and not FactionRes.same_side(foe_b.owner, world.my_faction):
				command_issued.emit({
					"kind": "attack", "ids": ids,
					"tx": hover_tile.x, "ty": hover_tile.y,
					"faction": world.my_faction,
				})
				clear_marks()
				set_order_mode("")
				return
			toast.emit("这里没有敌人：左键点敌方单位或建筑（右键 / Esc 取消）")
		_:
			set_order_mode("")
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


## 把单位**排进**当前选中将领的招募队列（读条 10 秒后才真的生成）。
##
## ★ 这里只发**命令**（逻辑层是唯一改世界的地方）；命令里只有兵种与队长 id，
##   没有坐标 —— 站位（将领所在格的**中心**）与扣费都由权威侧算。
## ★ 没有选中将领时**不发命令**：命令里必须带 leader_id，硬发只会被逻辑层拒掉，
##   而玩家看不到任何反馈。所以直接返回 false，由调用方（view/hud.gd）给一句提示。
##
## @return true = 命令已发出（不代表已经入队/招出来，落成与否看逻辑层）
func request_recruit(kind: String) -> bool:
	var leader = first_selected_leader()
	if leader == null:
		toast.emit("先选中一个将领，才能把新兵排到它名下")
		return false
	command_issued.emit({
		"kind": "recruit", "unit_kind": kind, "leader_id": leader.id,
		"faction": world.my_faction,
	})
	return true


## 取消招募队列里的某一格（点信息栏里的那五个格子）。
##
## @param slot 0 = 正在读条的大格子；1..4 = 排队的四个小格子（从前往后）
## ★ 与招募一样只发命令：退多少钱、后方的队列怎么前移，都由权威侧算。
func request_recruit_cancel(slot: int) -> bool:
	var leader = first_selected_leader()
	if leader == null:
		toast.emit("先选中一个将领，才能取消它的招募队列")
		return false
	if not leader.is_training():
		return false
	command_issued.emit({
		"kind": "recruit_cancel", "leader_id": leader.id, "slot": slot,
		"faction": world.my_faction,
	})
	return true


## ★★ 区划招募（点区划中心 → 右下「招募」页签 → 点某一格）：把将领排进**那个区划**的队列。
##
## ★ 与 `request_recruit` 的唯一区别是「兵营是谁」：那边把命令发给选中将领，
##   这边发给 `selected_zone`（区划排的是将领，见 world 的区划招募那一段）。
## ★ 没有选中区划时不发命令（命令里必须带 zone_id），返回 false 由调用方给提示。
func request_zone_recruit(kind: String) -> bool:
	var z = selected_zone
	if z == null:
		toast.emit("先点一个区划中心，才能在这个区划里招募")
		return false
	command_issued.emit({
		"kind": "zone_recruit", "unit_kind": kind, "zone_id": int(z["id"]),
		"faction": world.my_faction,
	})
	return true


## 取消区划招募队列里的某一格（点信息栏里的那五个格子）。
##
## @param slot 0 = 正在读条的大格子；1..4 = 排队的四个小格子（从前往后）
func request_zone_recruit_cancel(slot: int) -> bool:
	var z = selected_zone
	if z == null or world == null:
		toast.emit("先点一个区划中心，才能取消它的招募队列")
		return false
	if not world.zone_is_training(z):
		return false
	command_issued.emit({
		"kind": "zone_recruit_cancel", "zone_id": int(z["id"]), "slot": slot,
		"faction": world.my_faction,
	})
	return true


## 招募完成时调（由 view/game_scene.gd 收到 `unit_recruited` 事件后调用）：
## **如果玩家此刻仍然选中着这个将领**，新兵也跟着被选中。
##
## ★ 需求原话：「如果造一个兵结束时玩家仍选中其将领，则这个新兵也会被选中」。
## ★ 为什么放在这里而不是逻辑层：选中是**纯本地**状态（不进命令流、不上网），
##   而「玩家当时选的是谁」只有本地知道。
## ★ 用 select_units(...) 而不是直接往 selected_units 里 append：它会走
##   `world.expand_to_groups()`，于是「将领 + 它辖下的全部亲兵」这条现成的规则
##   自然把新兵带上（新兵的 leader_id 就是它）—— 少一处会漂的重复规则。
func notify_unit_recruited(leader, unit) -> void:
	if leader == null or unit == null:
		return
	if not selected_units.has(leader):
		return              # 玩家已经改选别的了 → 不打扰他（需求的前提就是「仍选中」）
	select_units(selected_units.duplicate() + [unit])


## 拆除在哪：**这一版没有界面入口**。
##
## ★ 按需求「去掉这个拆除逻辑，暂时不绑定按键」：原来 X / Delete 会把选中的建筑拆掉，
##   现在这两个键**不再绑任何东西**（键位可能留给别的功能）。
## ★ 逻辑层那条命令照旧在（`command_processor.apply_demolish`，测试也在直接调它）——
##   要恢复入口只需要在 `handle_key()` 里加回一个 case、再往
##   `command_issued` 里发一条 `{"kind": "demolish", "tx":…, "ty":…}`。


func _build_name(t: String) -> String:
	var v = cfg.get_path_value("building.%s.name" % t)
	return String(v) if typeof(v) == TYPE_STRING else t


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
	# ★ 建筑：先把倒掉的摘出去，再把**主选中**重新指到一个还在的成员上 ——
	#   主选中那一个被打掉时，整批选中不该跟着一起丢（框选了一排墙，中间塌了一段，
	#   剩下的那些仍然是选中的）。
	if not selected_buildings.is_empty():
		var alive_b: Array = []
		for b in selected_buildings:
			if b != null and b.alive:
				alive_b.append(b)
		if alive_b.size() != selected_buildings.size() or not alive_b.has(selected_building):
			selected_buildings = alive_b
			selected_building = alive_b[0] if not alive_b.is_empty() else null
			local_ui_changed.emit()
	# ★ 选中的区划要确认它还在（地图换过 / 世界重建过之后，那个字典可能已经是老的了）
	if selected_zone != null and not _zone_still_exists():
		selected_zone = null
		local_ui_changed.emit()


func _zone_still_exists() -> bool:
	if world == null or world.zones == null:
		return false
	var zid := int(selected_zone.get("id", -1))
	for z in world.zones.zones:
		if z == selected_zone or int(z["id"]) == zid:
			return true
	return false
