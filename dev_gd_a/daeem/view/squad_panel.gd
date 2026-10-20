## squad_panel.gd —— 右侧「部队 1~10」将领标签列（参考 art_draft/4.png）
##
## 数据来源（需求确认）：世界里的**现有队伍** —— 将领 + 它辖下的亲兵。
## 队伍在逻辑层是**算出来的**（world.group_of），没有 Squad 对象、没有队伍表，
## 所以这里每帧重算一遍即可（单位只有几十个，代价可以忽略）。
##
## 规则：
##   · 不足 10 支队伍的空槽显示「…」并置灰、**点了不做任何事**
##   · 每条标签 = 数字（1..9，第 10 个写 0）+ 将领名字 + 「当前编制/编制上限」
##   · 当前编制 = 队长 + 附属兵；上限 = cfg.general_cap_at(该将领序号)，默认 11
##   · 点一条 = 选中整队，**镜头不动**
##   · 悬停 / 选中：金色泛光从最右竖线向左推进（见 view/troop_row.gd）
##
## ★ 纯表现：只读 world 与输入层的选中状态，改选中也只走 input_controller 的接口。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const FactionRes = preload("res://logic/faction.gd")
const TroopRowRes = preload("res://view/troop_row.gd")

var cfg = null
var world = null
var input_ctrl = null
var _font: Font = null

var _rows: Array = []
## 每一槽当前对应的队伍（空槽 = 空数组）：刷新时算好，点击时直接用
var _teams: Array = []
## 每一槽当前显示的数字（1..9、0）
var _numbers: Array = []

## ★★ 手机端刷新节流（桌面 / 无头恒为 0 = 每帧；见 config 的 ui._mobile_refresh_comment）。
##   `refresh()` 每帧要全表扫 `world.units` + 每队 `world.group_of()`，手机上不必 60Hz。
var _refresh_interval: float = 0.0
var _refresh_accum: float = 0.0
## 刷新过多少次（诊断；测试用它确认手机调度器的槽 2 真的调了部队列表）
var refresh_count: int = 0


func setup(p_cfg, p_world, p_input, p_font: Font = null) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input
	_font = p_font
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
	var teams := _collect_teams()
	for i in _rows.size():
		var row = _rows[i]
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
	if cfg != null and cfg.has_method("general_cap_at"):
		var idx := int(leader.general_index)
		if idx >= 0:
			cap = int(cfg.general_cap_at(idx))
	return maxi(cap, count)


# ------------------------------------------------------------------
# 点击
# ------------------------------------------------------------------

func _on_slot_pressed(i: int) -> void:
	var team: Array = _teams[i] if i < _teams.size() else []
	if team.is_empty():
		return                        # 空槽：点了什么也不做
	# ★ 只选中，不动镜头（需求原话：「只选中，镜头不动」）
	input_ctrl.select_units(team)


# ------------------------------------------------------------------
# 给测试 / 其它 UI 用的小接口
# ------------------------------------------------------------------

func slot_count() -> int:
	return _rows.size()


## 一条标签的文案（给测试）：`"<数字> <名字>\n<当前/上限>"`；空槽是 `"…"`。
func slot_text(i: int) -> String:
	if i < 0 or i >= _rows.size():
		return ""
	var row = _rows[i]
	if not row.is_filled():
		return "…"
	return "%s %s\n%s" % [row.number_text(), row.leader_name(), row.formation_text()]


## 这一槽是不是「有队伍」的槽（空槽点了没反应）
func slot_filled(i: int) -> bool:
	if i < 0 or i >= _teams.size():
		return false
	return not (_teams[i] as Array).is_empty()


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
