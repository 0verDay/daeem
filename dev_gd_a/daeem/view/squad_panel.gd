## squad_panel.gd —— 右侧「部队 1~6」将领标签列（参考 art_draft/4.png）
##
## 数据来源（本轮改版）：**固定编队槽位** —— 见 view/team_slots.gd。
##   · 槽位在开局按 `world.units` 顺序分配 1..6，之后**永不改号**；
##   · 阵亡将仍占着它那一行（置灰、显示「重生 N 秒」），复活后自动取消置灰；
##   · 新将领补**最小空槽**（阵亡占着的不算空）；6 个槽满了就没有新编号。
##   没有槽位表时才退回旧的「存活队伍」口径。
##
## 规则：
##   · 真正空着的槽显示「…」并置灰、**点了不做任何事**；阵亡槽同样不可点，但保留名字
##   · 每条标签 = 数字（1..6）+ 将领名字 + 「当前编制/编制上限」
##   · 当前编制 = 队长 + 附属兵；上限 = cfg.general_cap_at(该将领序号)，默认 11
##   · ★★ 单击 = **反选**整队（需求：点击代表反选）：
##       没选中 → 把整队**加进**当前选中；已选中 → 把整队**从选中里撤掉**。
##       例：无选中 → 点 1 = 选中 1 → 点 2 = 选中 1+2 → 再点 1 = 只剩 2。
##       ⇒ 点掉最后一支时选中集合为空（这是反选的正常结果，不是 bug）。
##   · ★★ 长按（0.4s）= 跟随该将领视角；双击 = 快速选中（只加不撤）+ 立即跳镜头。
##       三套手势的**状态机在 input_controller**（标签 / 数字键同源），本文件只负责
##       把 PC 的 Button 信号与移动端的触摸事件转给 `input_ctrl.gesture_*()`。
##   · 单击**镜头不动**（需求原话）；跳镜头只属于双击。
##   · 悬停 / 选中：金色泛光从最右竖线向左推进（连续渐变，见 view/troop_row.gd）；
##     选中的键帽亮起、悬停时黯淡（见 troop_row 的 `number_key_state()`）。
##   · 手机端整行 `MOUSE_FILTER_IGNORE`，触摸在 `handle_touch()` 里统一路由
##     （否则 emulate_mouse_from_touch 会让同一次触摸再点一遍）。
##
## ★ 纯表现：只读 world / 槽位表与输入层的选中状态，改选中也只走 input_controller 的接口。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const FactionRes = preload("res://logic/faction.gd")
const TroopRowRes = preload("res://view/troop_row.gd")

var cfg = null
var world = null
var input_ctrl = null
## ★★ 稳定编队槽位（见 view/team_slots.gd）：阵亡将仍占一行，只是置灰；
##   为 null 时退回旧的「存活顺序」。
var team_slots = null
var _font: Font = null

var _rows: Array = []
## 每一槽当前对应的队伍（空槽 / 阵亡槽 = 空数组）：刷新时算好，点击时直接用
var _teams: Array = []
## 每一槽是不是「阵亡置灰」行（仍占位，但不可点 / 不高亮）
var _dead: Array = []
## 每一槽当前显示的数字（1..6）
var _numbers: Array = []

## ★★ 手机端刷新节流（桌面 / 无头恒为 0 = 每帧；见 config 的 ui._mobile_refresh_comment）。
##   `refresh()` 每帧要全表扫 `world.units` + 每队 `world.group_of()`，手机上不必 60Hz。
var _refresh_interval: float = 0.0
var _refresh_accum: float = 0.0
## 刷新过多少次（诊断；测试用它确认手机调度器的槽 2 真的调了部队列表）
var refresh_count: int = 0

## ★★ 手机端：行不吃鼠标，触摸由本文件统一路由（见文件头）。
var _touch_mode: bool = false
## 这一串触摸按在第几槽（1 起；0 = 当前没有标签触摸）
var _touch_slot: int = 0
## 按在标签上的那根手指的 index（多指时其它手指不归标签管）
var _touch_index: int = -1
var _touch_press_pos: Vector2 = Vector2.ZERO
var _touch_cancelled: bool = false
## 上一次按下后是否已收到抬起（用于 `handle_touch` 的返回值：整串触摸都由标签消化）
var _touch_consumed: bool = false


func setup(p_cfg, p_world, p_input, p_font: Font = null, p_team_slots = null) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input
	_font = p_font
	team_slots = p_team_slots
	# ★★ 手机端：刷新节流（桌面 / 无头 _refresh_interval = 0 ⇒ 每帧，行为不变）。
	_refresh_interval = 0.0
	if OS.has_feature("mobile") and cfg != null and cfg.mobile_hud_refresh_hz > 0.0:
		_refresh_interval = 1.0 / cfg.mobile_hud_refresh_hz
	# ★★ 手机端：触摸由 `handle_touch()` 统一路由，行必须鼠标穿透
	#   （否则 emulate_mouse_from_touch 会让同一次触摸再点一遍 Button）。
	_touch_mode = OS.has_feature("mobile")

	name = "SquadPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP          # 面板底下的地图不吃这一片的点击
	# 贴右上：右缘 1896（留 24px），从 y=180 开始避开右上角设置按钮
	UiLayoutRes.apply_rect(self, UiLayoutRes.SQUAD_RECT, true, false)

	for i in UiLayoutRes.SQUAD_SLOTS:
		var row = TroopRowRes.new()
		row.setup(_font, i, cfg)
		row.set_touch_mode(_touch_mode)
		UiLayoutRes.apply_rect(row, UiLayoutRes.squad_slot_local(i))
		# 按下 → 开始长按计时；pressed = 行内抬起（有效单击）；button_up 兜底取消；
		# mouse_exited = 拖出本行（取消这次长按）。
		row.button_down.connect(_on_slot_down.bind(i))
		row.pressed.connect(_on_slot_pressed.bind(i))
		row.button_up.connect(_on_slot_up.bind(i))
		row.mouse_exited.connect(_on_slot_exit.bind(i))
		add_child(row)
		_rows.append(row)
		_teams.append([])
		_dead.append(false)
		_numbers.append(str(i + 1))

	# ★★ 整列 2px 外框（左 / 上 / 下；**右边留 0**）：右边那条是最右竖线 + 泛光起点，
	#   盖上外框会把选中时的亮金线压掉。最后一格加、IGNORE，不吃行点击。
	var frame := Panel.new()
	frame.name = "SquadFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	var fs := UiStyleRes.outline_style(UiStyleRes.line(), 2)
	fs.border_width_right = 0
	frame.add_theme_stylebox_override("panel", fs)
	add_child(frame)

	refresh()


func _process(dt: float) -> void:
	# ★★ 手机端节流（桌面 / 测试每帧；见 config 的 ui._mobile_refresh_comment）。
	if _refresh_interval <= 0.0:
		refresh()
		return
	_refresh_accum += dt
	if _refresh_accum >= _refresh_interval:
		_refresh_accum = 0.0
		refresh()


# ------------------------------------------------------------------
# 刷新（每帧）
# ------------------------------------------------------------------

func refresh() -> void:
	# 诊断计数（测试读）：手机端由 HUD 的槽位驱动，桌面由自己的 `_process` 驱动。
	refresh_count += 1
	if world == null or input_ctrl == null:
		return
	# ★★ 当前正在跟随的将领（没有 → null）：那一行最左侧画「跟随眼睛」。
	var followed = _followed_unit()
	# ★★ 有稳定槽位表：按槽位 1..6 刷新（阵亡行置灰、仍占位）。
	#    没有（老测试 / 2D 路径）才退回旧的「存活队伍」口径。
	if team_slots != null:
		team_slots.sync(world)
		_refresh_from_slots(followed)
		return
	var teams := _collect_teams()
	for i in _rows.size():
		var row = _rows[i]
		_dead[i] = false
		if i < teams.size():
			var team: Array = teams[i]
			var leader = team[0]
			_teams[i] = team
			var cap := _formation_cap(leader, team.size())
			row.set_data(_numbers[i], String(leader.name), "%d/%d" % [team.size(), cap], true)
			row.set_selected(input_ctrl.selected_units.has(leader))
			row.set_following(followed != null and followed == leader)
		else:
			_teams[i] = []
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)
			row.set_following(false)


## 当前跟随的将领（相机替身没有这个接口时返回 null）。
func _followed_unit():
	if input_ctrl == null or not input_ctrl.has_method("following_general"):
		return null
	return input_ctrl.following_general()


## 按稳定槽位刷新：活着的行可点，阵亡的行置灰但仍占位（显示名字 + 重生倒计时）。
func _refresh_from_slots(followed = null) -> void:
	for i in _rows.size():
		var row = _rows[i]
		var slot: int = i + 1
		if not team_slots.has_slot(slot):
			_teams[i] = []
			_dead[i] = false
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)
			row.set_following(false)
			continue
		if team_slots.slot_is_dead(slot):
			# ★ 阵亡：名字 / 状态仍然显示，用 filled=false 让 troop_row 把整行压暗、
			#   鼠标穿透（点不动）。槽位数字不变。
			_teams[i] = []
			_dead[i] = true
			var nm := String(team_slots.slot_name(slot))
			if nm == "":
				nm = "将领"
			var st := String(team_slots.slot_status_text(slot))
			if st == "":
				st = "阵亡"
			row.set_data(_numbers[i], nm, st, false)
			row.set_selected(false)
			row.set_following(false)
			continue
		var u = team_slots.unit_in_slot(slot)
		if u == null:
			_teams[i] = []
			_dead[i] = false
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)
			row.set_following(false)
			continue
		var team: Array = world.group_of(u)
		if team.is_empty():
			team = [u]
		_teams[i] = team
		_dead[i] = false
		var cap := _formation_cap(u, team.size())
		row.set_data(_numbers[i], String(u.name), "%d/%d" % [team.size(), cap], true)
		row.set_selected(input_ctrl.selected_units.has(u))
		row.set_following(followed != null and followed == u)


## 现有队伍：己方**在场的队长**各算一队。
## 顺序 = world.units 的顺序（前三个永远是三个将领，所以部队 1/2/3 就是将领 1/2/3）。
func _collect_teams() -> Array:
	var out: Array = []
	if world == null:
		return out
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if not world.is_team_leader(u):
			continue
		out.append(world.group_of(u))
		if out.size() >= UiLayoutRes.SQUAD_SLOTS:
			break
	return out


## 编制上限：该将领的 `general_index` 对应的上限（默认 11）。
## ★ 队伍人数可能暂时超过上限（老存档 / 招募），此时显示更大的那个，避免「7/5」。
func _formation_cap(leader, count: int) -> int:
	var cap := UiLayoutRes.UNIT_CAP
	# ★ 唯一口径：兵种档位上限 + 大本营等级加成（world.effective_retinue_cap）。
	if world != null and world.has_method("effective_retinue_cap"):
		cap = int(world.effective_retinue_cap(leader))
	elif cfg != null and cfg.has_method("general_cap_at"):
		var idx := int(leader.general_index)
		if idx >= 0:
			cap = int(cfg.general_cap_at(idx))
	return maxi(cap, count)


# ------------------------------------------------------------------
# 手势：PC 的 Button 信号 / 移动端的触摸事件 → input_ctrl.gesture_*()
#
# ★ 单击 / 长按 / 双击的**判定**不在这里：`input_controller` 里有一套状态机，
#   标签与数字键共用（见那里的 `gesture_press / gesture_release / poll_gestures`）。
#   本文件只负责把「哪一槽、按下了 / 抬起了 / 拖走了」告诉它。
# ------------------------------------------------------------------

## 按下：开始长按计时（空槽 / 阵亡槽在刷新时已 `MOUSE_FILTER_IGNORE`，这里再兜一层）。
func _on_slot_down(i: int) -> void:
	if not _slot_usable(i):
		return
	if input_ctrl != null:
		input_ctrl.gesture_press("tag", i + 1)


## 行内抬起 = 一次有效单击（`Button.pressed`）。双击配对与反选都在输入层。
func _on_slot_pressed(i: int) -> void:
	if not _slot_usable(i):
		return
	if input_ctrl != null:
		input_ctrl.gesture_release("tag", i + 1)


## 抬起兜底：`pressed` 没发（鼠标已拖出本行 / 长按后松开）时取消这次按住。
func _on_slot_up(i: int) -> void:
	if input_ctrl != null and input_ctrl.gesture_active_slot("tag") == i + 1:
		input_ctrl.gesture_cancel("tag")


## 鼠标拖出本行：取消尚未触发的长按（不要「按住拖到地图上还在跟」）。
func _on_slot_exit(i: int) -> void:
	if input_ctrl != null and input_ctrl.gesture_active_slot("tag") == i + 1:
		input_ctrl.gesture_cancel("tag")


func _slot_usable(i: int) -> bool:
	return i >= 0 and i < _teams.size() and not (_teams[i] as Array).is_empty()


# ------------------------------------------------------------------
# 移动端触摸（由 HUD 在 GUI 之前转发：见 hud.handle_touch / handle_touch_drag）
# ------------------------------------------------------------------

## 屏幕点落在第几槽（0 起；-1 = 不在任何可用标签上）。
## ★ 只认有队伍的槽；空槽 / 阵亡槽不响应触摸。
func slot_at_screen(global_pos: Vector2) -> int:
	for i in _rows.size():
		if not _slot_usable(i):
			continue
		if _rows[i].get_global_rect().has_point(global_pos):
			return i
	return -1


## @return true = 这一串触摸由标签栏消化（HUD 不再走命令卡 / 科技格的长按逻辑）
## @param now_ms 测试注入时间；-1 = 用 `Time.get_ticks_msec()`
func handle_touch(event: InputEventScreenTouch, now_ms: int = -1) -> bool:
	if not _touch_mode:
		return false
	if event.pressed:
		# 已经有一根手指按在标签上：其它手指的按下不归标签管（也不能打乱这一串）
		if _touch_consumed:
			return event.index == _touch_index
		var i := slot_at_screen(event.position)
		if i < 0:
			return false
		_touch_slot = i + 1
		_touch_index = event.index
		_touch_press_pos = event.position
		_touch_cancelled = false
		_touch_consumed = true
		if input_ctrl != null:
			input_ctrl.gesture_press("tag", _touch_slot, now_ms)
		return true
	# 抬起：只有「从标签上开始」的那根手指才算标签的
	if not _touch_consumed or event.index != _touch_index:
		return false
	var slot := _touch_slot
	var cancelled := _touch_cancelled
	_touch_slot = 0
	_touch_index = -1
	_touch_cancelled = false
	_touch_consumed = false
	if slot > 0 and not cancelled and input_ctrl != null:
		input_ctrl.gesture_release("tag", slot, now_ms)
	return true


## 手指滑走：超过拖动阈值就取消这次按住（长按 / 单击都不再触发）。
func handle_touch_drag(event: InputEventScreenDrag) -> void:
	if not _touch_mode or not _touch_consumed \
			or event.index != _touch_index or _touch_cancelled:
		return
	var limit: float = cfg.touch_pan_min_px if cfg != null else 24.0
	if event.position.distance_to(_touch_press_pos) > limit:
		_touch_cancelled = true
		if input_ctrl != null:
			input_ctrl.gesture_cancel("tag")


# ------------------------------------------------------------------
# 测试钩子（直接驱动输入层的手势状态机，绕过鼠标坐标 / 触摸坐标）
# ------------------------------------------------------------------

func debug_press_slot(i: int, now_ms: int = -1) -> void:
	if _slot_usable(i) and input_ctrl != null:
		input_ctrl.gesture_press("tag", i + 1, now_ms)


func debug_release_slot(i: int, now_ms: int = -1) -> void:
	if _slot_usable(i) and input_ctrl != null:
		input_ctrl.gesture_release("tag", i + 1, now_ms)


# ------------------------------------------------------------------
# 给测试 / 其它 UI 用的小接口
# ------------------------------------------------------------------

func slot_count() -> int:
	return _rows.size()


## 一条标签的文案（给测试）：`"<数字> <名字>\n<当前/上限>"`；空槽是 `"…"`。
## ★ 阵亡行不是空槽：仍返回名字与状态（置灰由 `filled=false` 表达）。
func slot_text(i: int) -> String:
	if i < 0 or i >= _rows.size():
		return ""
	var row = _rows[i]
	if not row.is_filled():
		if i < _dead.size() and bool(_dead[i]):
			return "%s %s\n%s" % [row.number_text(), row.leader_name(), row.formation_text()]
		return "…"
	return "%s %s\n%s" % [row.number_text(), row.leader_name(), row.formation_text()]


## 这一槽是不是「有队伍」的槽（空槽 / 阵亡槽都不可点；阵亡用 `slot_dead` 判）。
func slot_filled(i: int) -> bool:
	if i < 0 or i >= _teams.size():
		return false
	return not (_teams[i] as Array).is_empty()


## 这一槽是不是阵亡置灰行（仍占位）。
func slot_dead(i: int) -> bool:
	if i < 0 or i >= _dead.size():
		return false
	return bool(_dead[i])


func slot_units(i: int) -> Array:
	if i < 0 or i >= _teams.size():
		return []
	return _teams[i]


func slot_button(i: int) -> Button:
	if i < 0 or i >= _rows.size():
		return null
	return _rows[i]


func slot_active(i: int) -> bool:
	if i < 0 or i >= _teams.size():
		return false
	var team: Array = _teams[i]
	if team.is_empty():
		return false
	return input_ctrl.selected_units.has(team[0])


func slot_number(i: int) -> String:
	if i < 0 or i >= _numbers.size():
		return ""
	return _numbers[i]


func slot_formation(i: int) -> String:
	if i < 0 or i >= _rows.size() or not _rows[i].is_filled():
		return ""
	return _rows[i].formation_text()
