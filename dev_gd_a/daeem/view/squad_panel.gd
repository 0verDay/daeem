## squad_panel.gd —— 右侧「部队 1~10」将领标签列（参考 art_draft/4.png）
##
## 数据来源（本轮改版）：**固定编队槽位** —— 见 view/team_slots.gd。
##   · 槽位在开局按 `world.units` 顺序分配 1..10，之后**永不改号**；
##   · 阵亡将仍占着它那一行（置灰、显示「重生 N 秒」），复活后自动取消置灰；
##   · 新将领补**最小空槽**（阵亡占着的不算空）；10 个槽满了就没有新编号。
##   没有槽位表时才退回旧的「存活队伍」口径。
##
## 规则：
##   · 真正空着的槽显示「…」并置灰、**点了不做任何事**；阵亡槽同样不可点，但保留名字
##   · 每条标签 = 数字（1..9，第 10 个写 0）+ 将领名字 + 「当前编制/编制上限」
##   · 当前编制 = 队长 + 附属兵；上限 = cfg.general_cap_at(该将领序号)，默认 11
##   · ★★ 点一条 = **反选**整队（需求：点击代表反选）：
##       没选中 → 把整队**加进**当前选中；已选中 → 把整队**从选中里撤掉**。
##       例：无选中 → 点 1 = 选中 1 → 点 2 = 选中 1+2 → 再点 1 = 只剩 2。
##       ⇒ 点掉最后一支时选中集合为空（这是反选的正常结果，不是 bug）。
##   · 点中的那一支同时成为详情面板「展开」的部队（发 `troop_focused`，见 HUD 的接法）
##   · 点一条**镜头不动**（需求原话）
##   · 悬停 / 选中：金色泛光从最右竖线向左推进（连续渐变，见 view/troop_row.gd）
##
## ★ 纯表现：只读 world / 槽位表与输入层的选中状态，改选中也只走 input_controller 的接口。
extends Control

## ★ 点中某支标签后发出（1 起的**固定槽位**，与「部队 1/2/3」/ 数字键同一口径）：
##   HUD 收到后把详情面板切到这一支（`_on_troop_activated`，只改「展开哪一支」，不动选中）。
signal troop_focused(number: int)

const UiLayoutRes = preload("res://view/ui_layout.gd")
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
## 每一槽当前显示的数字（1..9、0）
var _numbers: Array = []

## ★★ 手机端刷新节流（桌面 / 无头恒为 0 = 每帧；见 config 的 ui._mobile_refresh_comment）。
##   `refresh()` 每帧要全表扫 `world.units` + 每队 `world.group_of()`，手机上不必 60Hz。
var _refresh_interval: float = 0.0
var _refresh_accum: float = 0.0
## 刷新过多少次（诊断；测试用它确认手机调度器的槽 2 真的调了部队列表）
var refresh_count: int = 0


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

	name = "SquadPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP          # 面板底下的地图不吃这一片的点击
	# 贴右上：右缘 1896（留 24px），从 y=180 开始避开右上角设置按钮
	UiLayoutRes.apply_rect(self, UiLayoutRes.SQUAD_RECT, true, false)

	for i in UiLayoutRes.SQUAD_SLOTS:
		var row = TroopRowRes.new()
		row.setup(_font, i, cfg)
		UiLayoutRes.apply_rect(row, UiLayoutRes.squad_slot_local(i))
		row.pressed.connect(_on_slot_pressed.bind(i))
		add_child(row)
		_rows.append(row)
		_teams.append([])
		_dead.append(false)
		_numbers.append(str((i + 1) % 10))

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
	# ★★ 有稳定槽位表：按槽位 1..10 刷新（阵亡行置灰、仍占位）。
	#    没有（老测试 / 2D 路径）才退回旧的「存活队伍」口径。
	if team_slots != null:
		team_slots.sync(world)
		_refresh_from_slots()
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
		else:
			_teams[i] = []
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)


## 按稳定槽位刷新：活着的行可点，阵亡的行置灰但仍占位（显示名字 + 重生倒计时）。
func _refresh_from_slots() -> void:
	for i in _rows.size():
		var row = _rows[i]
		var slot: int = i + 1
		if not team_slots.has_slot(slot):
			_teams[i] = []
			_dead[i] = false
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)
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
			continue
		var u = team_slots.unit_in_slot(slot)
		if u == null:
			_teams[i] = []
			_dead[i] = false
			row.set_data(_numbers[i], "…", "--/--", false)
			row.set_selected(false)
			continue
		var team: Array = world.group_of(u)
		if team.is_empty():
			team = [u]
		_teams[i] = team
		_dead[i] = false
		var cap := _formation_cap(u, team.size())
		row.set_data(_numbers[i], String(u.name), "%d/%d" % [team.size(), cap], true)
		row.set_selected(input_ctrl.selected_units.has(u))


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
# 点击
# ------------------------------------------------------------------

## ★★ 点标签 = **反选**这一整队（需求原话：「点击代表反选」）。
##
## 例（需求给的例子）：无选中 → 点 1 选中 1 → 点 2 选中 1+2 → 再点 1 只剩 2。
## 所以判据只有一条：**这一队的队长现在在不在选中集合里**。
##   · 在  → 把整队从选中里撤掉（`_without_team`）；
##   · 不在 → 把整队并进当前选中（**不是**替换 —— 否则按住 2 会把 1 顶掉）。
##
## ★ 走 `input_ctrl.select_units()` 而不是自己改 `selected_units`：那里是选中集合的
##   唯一入口（会按队伍展开、同步 `u.selected` 渲染标志、清掉区划 / 建筑选中）。
## ★ 只改选中，不动镜头（需求原话：「只选中，镜头不动」）。
func _on_slot_pressed(i: int) -> void:
	var team: Array = _teams[i] if i < _teams.size() else []
	if team.is_empty():
		return                        # 空槽：点了什么也不做
	var leader = team[0]
	var was_selected: bool = input_ctrl.selected_units.has(leader)
	var next: Array = []
	if was_selected:
		next = _without_team(team)
	else:
		next = input_ctrl.selected_units.duplicate()
		for u in team:
			if not next.has(u):
				next.append(u)
	input_ctrl.select_units(next)
	if not was_selected:
		# 新选中的这一支成为详情面板展开的部队（编号 = 槽位 + 1，与标签数字同源）。
		# 反选时不发：HUD 的 `_pick_troop()` 发现「展开的那支已经不在选中里」会自己回退。
		troop_focused.emit(i + 1)


## 把一支队伍**整个**从当前选中里撤掉（反选的「撤」那一步）。
##
## ★ 为什么要按**队伍**过滤、而不是只减掉队长那个对象：
##   选中集合是 `select_units()` 按队伍展开过的，里面除了队长还有全部亲兵；
##   只减队长的话，剩下的亲兵在 `select_units()` 里又会 `expand_to_groups`
##   把队长整个加回来 —— 反选看起来像没生效。
## ★ 顺手丢掉已阵亡的旧成员：它们留在集合里同样会在展开时把队伍带回来。
## ★ 也按 `leader_id` 兜一层：老存档 / 队长换了 id 的残兵不会被漏掉。
func _without_team(team: Array) -> Array:
	var leader = team[0]
	var drop: Dictionary = {}
	for u in team:
		drop[u.id] = true
	var next: Array = []
	for u in input_ctrl.selected_units:
		if u == null or not u.alive:
			continue
		if drop.has(u.id):
			continue
		if u.leader_id != "" and u.leader_id == leader.id:
			continue
		next.append(u)
	return next


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
