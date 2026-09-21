## troop_grid.gd —— 详细信息左栏**下半**：其余选中部队的将领头像网格
##
## 参考图上那一块 3 列 × 4 行的格子（手玩原话：「下方的 1333 排列的格子就是能选中的
## 最多的部队量」，所以格数 = 3 × 4 = 12）：
##   每格 = 小将领头像 24×24 + 右边两行小字（「将领名」/「x/y」）；
##   正在交战的那一格描红（与 unit_roster / recruit_queue 同一套调色板）。
##
## ★★ **被展开的那一支部队不在这里**（手玩原话：「被展开的部队不需要在下方的九宫格中显示」
##    —— 它已经画在上面那一行里了）。递进来的 `troops` 就是「选中部队 - 展开的那一支」。
##
## ★ 交互（需求原话：「玩家可以靠点击下方的将领头像以更换此展开详细部队信息的部队」）：
##   点一格 → `troop_activated(编号)`；**这一层只报「点了第几号」**，
##   「把左栏上半换成那一支」由 hud.gd 决定（视图不碰选中状态，也**不改选中**）。
##
## ★ 纯表现：部队分组与人数都由外面（hud → detail_panel）算好递进来，
##   这里只读；没得画时整块收起来。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 点了第 i 格（带的是**部队编号**，1 起；拿不到编号时是 0）。只有非空格子才会发。
signal troop_activated(number: int)

## 中文字体（Godot 默认字体没有 CJK 字形 —— 不传就会画成方框）
var font: Font = null

## 递进来的部队：[{"leader": 队长单位, "number": 部队编号(0=没有), "units": [该队单位…]}]
var _troops: Array = []
## 鼠标停在第几格（-1 = 没停在任何**非空**格子上）
var _hover: int = -1
## 画过几帧（给测试用：无头下 `_draw` 里的错误不会让测试失败，所以盯一下它真的跑了）
var draw_count: int = 0


func setup(p_font: Font = null) -> void:
	font = p_font
	name = "TroopGrid"
	# 要能点（换展开哪支部队），所以这里收鼠标；不可见时收不到事件，平时不挡别处。
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	custom_minimum_size = Vector2(UiLayoutRes.DETAIL_LEFT_W, UiLayoutRes.TROOP_GRID_H)
	visible = false


# ------------------------------------------------------------------
# 刷新（每帧由 detail_panel 喂）
# ------------------------------------------------------------------

## @param troops 要画的部队（= 选中部队**去掉正在展开的那一支**）
func set_troops(troops: Array) -> void:
	_troops = troops
	visible = not troops.is_empty()
	if _hover >= _troops.size():
		_hover = -1
	queue_redraw()


# ------------------------------------------------------------------
# 状态（给渲染与测试读）
# ------------------------------------------------------------------

## 列出几支部队（最多 TROOP_GRID_SLOTS 格，多出来的画不下）
func troop_count() -> int:
	return _troops.size()


## 画了几格
func cell_count() -> int:
	return mini(_troops.size(), UiLayoutRes.TROOP_GRID_SLOTS)


## 第 i 格是不是「有部队」的格子
func cell_filled(i: int) -> bool:
	return i >= 0 and i < _troops.size() and i < UiLayoutRes.TROOP_GRID_SLOTS


func leader_at(i: int) -> Variant:
	if not cell_filled(i):
		return null
	return _troops[i].get("leader", null)


## 第 i 格里的将领（队长）名字
func leader_name(i: int) -> String:
	var l = leader_at(i)
	return "" if l == null else String(l.name)


## 第 i 格的「x/y」文字（x = 该部队现有单位数，含将领；y = 编制上限）
func count_text(i: int) -> String:
	if not cell_filled(i):
		return ""
	var units: Array = _troops[i].get("units", [])
	return "%d/%d" % [units.size(), UiLayoutRes.UNIT_CAP]


## 某个点落在哪一格上（只有**非空**格子才算命中；空格 / 外面 → -1）
func cell_at_position(p: Vector2) -> int:
	for i in cell_count():
		if UiLayoutRes.troop_cell_rect(i).has_point(p):
			return i
	return -1


# ------------------------------------------------------------------
# 点击
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var s := cell_at_position(event.position)
		if s != _hover:
			_hover = s
			mouse_default_cursor_shape = (Control.CURSOR_POINTING_HAND if s >= 0
				else Control.CURSOR_ARROW)
			queue_redraw()
		return
	if event is InputEventMouseButton and event.pressed \
			and event.button_index == MOUSE_BUTTON_LEFT:
		var hit := cell_at_position(event.position)
		if hit >= 0:
			# 只抛「点了第几号部队」；换展开由 hud.gd 决定（见文件头）
			troop_activated.emit(int(_troops[hit].get("number", 0)))
			accept_event()


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	if _troops.is_empty():
		return
	var f: Font = font
	if f == null:
		f = get_theme_default_font()
	for i in cell_count():
		_draw_cell(i, f)


## 一格：底 + 描边 + 将领头像 + 右边两行小字（将领名 / x/y）
func _draw_cell(i: int, f: Font) -> void:
	var cell := UiLayoutRes.troop_cell_rect(i)
	var leader = leader_at(i)
	var units: Array = _troops[i].get("units", [])

	draw_rect(cell, UiStyleRes.BG_EMPTY, true)

	# 头像：与附属单位方块同一套画法
	# ⚠️ 描边只看「交战 / 鼠标悬停」——**不再有「当前展开」那种蓝框**：
	#    被展开的那一支根本不在这个网格里（手玩原话），这里再标一次只会让人误解。
	var av := UiLayoutRes.troop_avatar_rect(i)
	draw_rect(av, UiStyleRes.BG_PRESSED, true)
	var edge: Color = UiStyleRes.LINE
	if _in_combat(leader):
		edge = UiStyleRes.WARN
	elif i == _hover:
		edge = UiStyleRes.ACCENT_DIM
	draw_rect(av, edge, false, 2.0 if edge != UiStyleRes.LINE else 1.0)
	_draw_centered(f, _leader_short(leader), av, UiStyleRes.TEXT, UiStyleRes.FS_SMALL)

	# 右边两行：名字 / x/y（参考图里格子是 40×40 方框 + 右边两行字，行距 41px）
	var text_x := av.position.x + av.size.x + 8.0
	var number := int(_troops[i].get("number", 0))
	var name_text := _leader_name_text(leader, number)
	draw_string(f, Vector2(text_x, cell.position.y + 15.0), name_text,
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.TROOP_NAME_W, UiStyleRes.FS_SMALL,
		UiStyleRes.TEXT_DIM)
	draw_string(f, Vector2(text_x, cell.position.y + 32.0),
		"%d/%d" % [units.size(), UiLayoutRes.UNIT_CAP],
		HORIZONTAL_ALIGNMENT_LEFT, UiLayoutRes.TROOP_NAME_W, UiStyleRes.FS_TINY,
		UiStyleRes.TEXT_FAINT)


## 格子里写的将领名：「将领 1」拿不到名字时退回「将领N」
func _leader_name_text(leader, number: int) -> String:
	var n := "" if leader == null else String(leader.name)
	if n == "":
		return "将领%d" % number if number > 0 else "部队"
	return n


## 头像方块里的短字：名字首字（没有名字就写「将」）
func _leader_short(leader) -> String:
	var n := "" if leader == null else String(leader.name)
	return n.substr(0, 1) if n.length() > 0 else "将"


## 把一个单位现在在不在交战（打人 / 拆建筑都算）—— 只读，不改
func _in_combat(u) -> bool:
	if u == null:
		return false
	if u.target != null and u.target.alive:
		return true
	if u.target_building != null and u.target_building.alive:
		return true
	return false


## 在一个矩形里居中画一行字（draw_string 的 pos 是**基线**）
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	if text == "":
		return
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline := r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
