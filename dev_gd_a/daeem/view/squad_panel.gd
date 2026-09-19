## squad_panel.gd —— 左侧「部队1 ~ 部队10」列表
##
## 数据来源（需求确认）：世界里的**现有队伍** —— 将领 + 它辖下的亲兵。
## 队伍在逻辑层是**算出来的**（world.group_of），没有 Squad 对象、没有队伍表，
## 所以这里每帧重算一遍即可（单位只有几十个，代价可以忽略）。
##
## 规则（需求确认）：
##   · 不足 10 支队伍的空槽显示「…」并置灰、**点了不做任何事**（参考图就是这么画的）
##   · 每行显示「编号 + 队伍名 + 人数」，当前选中的那队高亮
##   · 点一行 = 选中整队，**镜头不动**
##
## ★ 纯表现：只读 world 与输入层的选中状态，改选中也只走 input_controller 的接口。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const FactionRes = preload("res://logic/faction.gd")

var cfg = null
var world = null
var input_ctrl = null

var _rows: Array[Button] = []
## 每一槽当前对应的队伍（空槽 = 空数组）：刷新时算好，点击时直接用
var _teams: Array = []


func setup(p_cfg, p_world, p_input) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input

	name = "SquadPanel"
	mouse_filter = Control.MOUSE_FILTER_STOP          # 面板底下的地图不吃这一片的点击
	UiLayoutRes.apply_rect(self, UiLayoutRes.SQUAD_RECT)

	# 半透明底板：列表压在地图上，没有底纹时字会糊在地形里
	var backdrop := Panel.new()
	backdrop.name = "SquadBackdrop"
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	backdrop.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.BG_SOFT, UiStyleRes.LINE_SOFT, 0))
	UiLayoutRes.apply_rect(backdrop, Rect2(Vector2.ZERO, UiLayoutRes.SQUAD_RECT.size))
	add_child(backdrop)

	for i in UiLayoutRes.SQUAD_SLOTS:
		var b := Button.new()
		b.name = "SquadSlot%d" % (i + 1)
		b.focus_mode = Control.FOCUS_NONE             # 别让空格 / 回车又触发一次
		b.clip_text = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
		_row_style(b, UiStyleRes.row_empty())
		UiLayoutRes.apply_rect(b, UiLayoutRes.squad_slot_local(i))
		b.pressed.connect(_on_slot_pressed.bind(i))
		add_child(b)
		_rows.append(b)
		_teams.append([])

	refresh()


func _process(_dt: float) -> void:
	refresh()


# ------------------------------------------------------------------
# 刷新（每帧）
# ------------------------------------------------------------------

func refresh() -> void:
	if world == null or input_ctrl == null:
		return
	var teams := _collect_teams()
	for i in _rows.size():
		var b := _rows[i]
		if i < teams.size():
			var team: Array = teams[i]
			var leader = team[0]
			_teams[i] = team
			b.text = "部队%d　%s · %d 人" % [i + 1, String(leader.name), team.size()]
			b.add_theme_color_override("font_color", UiStyleRes.TEXT)
			var active: bool = input_ctrl.selected_units.has(leader)
			if active:
				_row_style(b, UiStyleRes.row_active())
			else:
				_row_style(b, UiStyleRes.row_normal())
		else:
			_teams[i] = []
			b.text = "…"
			b.add_theme_color_override("font_color", UiStyleRes.TEXT_FAINT)
			_row_style(b, UiStyleRes.row_empty())


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


func _row_style(b: Button, normal: StyleBoxFlat) -> void:
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", UiStyleRes.row_hover())
	b.add_theme_stylebox_override("pressed", UiStyleRes.row_hover())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


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


func slot_text(i: int) -> String:
	if i < 0 or i >= _rows.size():
		return ""
	return _rows[i].text


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
