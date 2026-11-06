## detail_list.gd —— 新详细信息面板**左列**：部队 / 单位 / 其他选中对象的小按钮列表
##
## ★ 与旧 `troop_grid` 的区别：
##   · 部队行是**可展开**的（默认折叠；选中单位所属的部队会自动展开）；
##   · 选中行复用右侧将领标签的**横向泛光**，方向相反：部队列表从**左缘向右**渐隐；
##   · 列表可以滚轮 / 拖拽上下滚动；列表外圈是**金色描边**；
##   · 部队图标在招募时显示**批次进度金填充**（整条队列共用一个读条）；
##   · 其他选中（建筑 / 区划 / 敌方）是同样的小按钮行，没有部队大按钮。
extends Control

const UiStyleRes = preload("res://view/ui_style.gd")
const HpBarRes = preload("res://view/hp_bar.gd")

signal unit_selected(unit)
signal entry_selected(entry)

const TROOP_H := 54
const UNIT_H := 36
const ENTRY_H := 40
const ICON_CELL := 54
const TROOP_ICON := 40
const SCROLL_STEP := 48.0
## ★ 与 view/troop_row.gd 的右侧将领标签同一组泛光参数；方向相反（列表从左向右）。
const GLOW_ALPHA := 0.34
const GLOW_STOPS := [0.0, 0.25, 0.5, 0.75, 1.0]
const GLOW_CURVE := 1.7

var world = null
var _font: Font = null

var _rows: Array = []
var _expanded_number: int = 0
var _last_selected_unit_id: String = ""
var _selected_unit = null
var _selected_entry = null
var _selected_troop_number: int = 0
var _scroll: float = 0.0
var _content_h: float = 0.0
var _hover_row: int = -1
var _pressed_row: int = -1
var _dragging: bool = false
var _drag_moved: bool = false
var _drag_last_y: float = 0.0


func setup(p_world, p_font: Font = null) -> void:
	world = p_world
	_font = p_font
	name = "DetailList"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	set_process(false)


func set_roster(troops: Array, focused_number: int, selected_unit) -> void:
	_selected_unit = selected_unit
	_selected_entry = null
	_selected_troop_number = focused_number
	# ★ 一次只展开一支：选中单位换到另一支部队时，展开那一支、收起其它。
	var sel_troop := 0
	if selected_unit != null:
		for t in troops:
			var l = (t as Dictionary).get("leader", null)
			if l == null:
				continue
			if l == selected_unit or (world != null and world.team_leader(selected_unit) == l):
				sel_troop = int((t as Dictionary).get("number", 0))
				break
	var uid := "" if selected_unit == null else str(selected_unit.get_instance_id())
	if sel_troop != 0 and uid != _last_selected_unit_id:
		_expanded_number = sel_troop
	_last_selected_unit_id = uid
	# 原先展开的那支不在列表里了 → 收起
	var still_there := false
	for t in troops:
		if int((t as Dictionary).get("number", 0)) == _expanded_number:
			still_there = true
			break
	if _expanded_number != 0 and not still_there:
		_expanded_number = 0

	_rows.clear()
	for t in troops:
		var d: Dictionary = t
		var leader = d.get("leader", null)
		if leader == null:
			continue
		var number := int(d.get("number", 0))
		var units: Array = [leader]
		if world != null and world.has_method("retinue_of"):
			for u in world.retinue_of(String(leader.id), true):
				if u != leader:
					units.append(u)
		var expanded := (number == _expanded_number)
		_rows.append({"kind": "troop", "leader": leader, "number": number,
			"units": units, "expanded": expanded})
		if expanded:
			for u in units:
				_rows.append({"kind": "unit", "unit": u, "leader": leader, "number": number})
	_layout()
	queue_redraw()


func set_small_entries(entries: Array, primary, kind: String) -> void:
	_selected_unit = null
	_expanded_number = 0
	_last_selected_unit_id = ""
	_selected_troop_number = 0
	_rows.clear()
	_selected_entry = primary
	for e in entries:
		if e is Dictionary:
			var d: Dictionary = (e as Dictionary).duplicate()
			d["kind"] = "entry"
			d["entry_kind"] = kind
			_rows.append(d)
	_scroll = 0.0
	_layout()
	queue_redraw()


func _layout() -> void:
	var y := 0.0
	for r in _rows:
		r["y"] = y
		match String(r.get("kind", "")):
			"troop":
				r["h"] = TROOP_H
			"unit":
				r["h"] = UNIT_H
			_:
				r["h"] = ENTRY_H
		y += float(r["h"])
	_content_h = y
	_scroll = clampf(_scroll, 0.0, maxf(0.0, _content_h - size.y))


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	# 列表深底；金边最后画（否则会被整行背景盖掉上/左/右/下四段）
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.055, 0.078, 0.114, 1.0), true)
	if _rows.is_empty():
		if _font != null:
			draw_string(_font, Vector2(12.0, 28.0), "未选中", HORIZONTAL_ALIGNMENT_LEFT,
				size.x - 24.0, 13, UiStyleRes.text_faint())
		_draw_frame()
		return

	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var y := float(r.get("y", 0.0)) - _scroll
		var h := float(r.get("h", 0.0))
		if y + h < 1.0 or y > size.y - 1.0:
			continue
		match String(r.get("kind", "")):
			"troop":
				_draw_troop(r, y, h, i)
			"unit":
				_draw_unit(r, y, h, i)
			_:
				_draw_entry(r, y, h, i)
	_draw_frame()


## 2px 金边压在行背景之上，保证四边完整。
func _draw_frame() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), UiStyleRes.accent(), false, 2.0)


## 与右侧将领标签同一条横向泛光，但方向相反：**从左缘向右**渐隐。
## ★ 连续渐变用顶点色多边形（troop_row 同一手法），不是一叠竖带。
func _draw_row_glow(rect: Rect2, strength: float = 1.0) -> void:
	var reach := clampf(strength, 0.0, 1.0)
	if reach <= 0.001:
		return
	var span := rect.size.x * reach
	if span <= 0.5:
		return
	var base := UiStyleRes.accent()
	var x0 := rect.position.x
	for i in GLOW_STOPS.size() - 1:
		var t0: float = GLOW_STOPS[i]
		var t1: float = GLOW_STOPS[i + 1]
		var xa := x0 + span * t0
		var xb := x0 + span * t1
		# 与 troop_row 相反：t=0 是列表左缘（最亮），向右 t=1 渐隐。
		var ca := Color(base, GLOW_ALPHA * pow(1.0 - t0, GLOW_CURVE))
		var cb := Color(base, GLOW_ALPHA * pow(1.0 - t1, GLOW_CURVE))
		draw_polygon(PackedVector2Array([
			Vector2(xa, rect.position.y + 1.0), Vector2(xb, rect.position.y + 1.0),
			Vector2(xb, rect.position.y + rect.size.y - 1.0),
			Vector2(xa, rect.position.y + rect.size.y - 1.0),
		]), PackedColorArray([ca, cb, cb, ca]))


func _draw_troop(r: Dictionary, y: float, h: float, row_i: int) -> void:
	var leader = r.get("leader", null)
	var rect := Rect2(0.0, y, size.x, h)
	var hovered := (row_i == _hover_row)
	var pressed := (row_i == _pressed_row)
	var bg := Color(0.086, 0.118, 0.157, 1.0)
	if hovered:
		bg = Color(0.11, 0.15, 0.20, 1.0)
	if pressed:
		bg = Color(0.18, 0.15, 0.09, 1.0)
	draw_rect(rect, bg, true)
	if hovered or pressed:
		_draw_row_glow(rect, 1.0 if pressed else 0.62)
		draw_rect(Rect2(0.0, y, 2.0, h), UiStyleRes.accent(), true)
	draw_line(Vector2(0.0, y + h - 1.0), Vector2(size.x, y + h - 1.0), UiStyleRes.line_soft(), 1.0)
	# 图标格：54×54，里面 40×40，四边各 7
	var ix := 7.0
	var iy := y + (h - ICON_CELL) / 2.0 + 7.0
	draw_rect(Rect2(ix, iy, TROOP_ICON, TROOP_ICON), Color(0.067, 0.094, 0.133, 1.0), true)
	var progress := 0.0
	if leader != null and leader.has_method("train_progress"):
		if String(leader.train_kind) != "" or not leader.train_queue.is_empty():
			progress = clampf(float(leader.train_progress()), 0.0, 1.0)
	if progress > 0.0:
		var fh := (TROOP_ICON - 2.0) * progress
		draw_rect(Rect2(ix + 1.0, iy + TROOP_ICON - 1.0 - fh, TROOP_ICON - 2.0, fh),
			Color(0.659, 0.478, 0.133, 1.0), true)
		draw_line(Vector2(ix + 1.0, iy + TROOP_ICON - 1.0 - fh),
			Vector2(ix + TROOP_ICON - 1.0, iy + TROOP_ICON - 1.0 - fh),
			UiStyleRes.accent_bright(), 1.0)
	draw_rect(Rect2(ix, iy, TROOP_ICON, TROOP_ICON),
		UiStyleRes.accent() if progress > 0.0 else UiStyleRes.line(), false, 1.0)
	if _font != null:
		_draw_centered_outlined(str(int(r.get("number", 0))), Rect2(ix, iy, TROOP_ICON, TROOP_ICON),
			22, UiStyleRes.text())
	# 血条
	if leader != null and leader.has_method("hp_ratio"):
		HpBarRes.draw(self, Rect2(ix, iy, TROOP_ICON, TROOP_ICON), float(leader.hp_ratio()))
	# 部队名 / 编制
	var name := _troop_name(int(r.get("number", 0)))
	var units: Array = r.get("units", [])
	var cap := 0
	if world != null and world.has_method("effective_retinue_cap"):
		cap = int(world.effective_retinue_cap(leader))
	if cap <= 0:
		cap = units.size()
	if _font != null:
		draw_string(_font, Vector2(ICON_CELL + 8.0, y + 34.0), name,
			HORIZONTAL_ALIGNMENT_LEFT, size.x - ICON_CELL - 40.0, 13, UiStyleRes.text())
		var ct := "%d/%d" % [units.size(), cap]
		var ct_w := _font.get_string_size(ct, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		draw_string(_font, Vector2(size.x - 8.0 - ct_w, y + 34.0), ct,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyleRes.text_dim())


func _draw_unit(r: Dictionary, y: float, h: float, row_i: int) -> void:
	var u = r.get("unit", null)
	var selected: bool = (u != null and u == _selected_unit)
	var rect := Rect2(0.0, y, size.x, h)
	if selected:
		draw_rect(rect, Color(0.086, 0.118, 0.157, 1.0), true)
		_draw_row_glow(rect, 1.0)
		draw_rect(Rect2(0.0, y, 2.0, h), UiStyleRes.accent(), true)
	elif row_i == _hover_row:
		draw_rect(rect, Color(0.086, 0.118, 0.157, 1.0), true)
		_draw_row_glow(rect, 0.55)
	# 24 图标居中在同一个 54 列里
	var ix := (ICON_CELL - 24.0) / 2.0
	var iy := y + 6.0
	draw_rect(Rect2(ix, iy, 24.0, 24.0), Color(0.067, 0.094, 0.133, 1.0), true)
	draw_rect(Rect2(ix, iy, 24.0, 24.0),
		UiStyleRes.accent_bright() if selected else UiStyleRes.line_soft(), false, 1.0)
	if _font != null and u != null:
		var ch := _unit_short(u)
		_draw_centered(ch, Rect2(ix, iy, 24.0, 24.0), 13, UiStyleRes.text())
		if u.has_method("hp_ratio"):
			HpBarRes.draw(self, Rect2(ix, iy, 24.0, 24.0), float(u.hp_ratio()))
		draw_string(_font, Vector2(ICON_CELL + 8.0, y + 24.0), String(u.name),
			HORIZONTAL_ALIGNMENT_LEFT, size.x - ICON_CELL - 30.0, 13,
			UiStyleRes.text() if selected else UiStyleRes.text_dim())
		if u == r.get("leader", null):
			draw_string(_font, Vector2(size.x - 18.0, y + 24.0), "将",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiStyleRes.accent())


func _draw_entry(r: Dictionary, y: float, h: float, row_i: int) -> void:
	var ref = r.get("ref", null)
	var selected: bool = (ref != null and ref == _selected_entry)
	var rect := Rect2(0.0, y, size.x, h)
	if selected:
		draw_rect(rect, Color(0.086, 0.118, 0.157, 1.0), true)
		_draw_row_glow(rect, 1.0)
		draw_rect(Rect2(0.0, y, 2.0, h), UiStyleRes.accent(), true)
	elif row_i == _hover_row:
		draw_rect(rect, Color(0.086, 0.118, 0.157, 1.0), true)
		_draw_row_glow(rect, 0.55)
	draw_line(Vector2(0.0, y + h - 1.0), Vector2(size.x, y + h - 1.0), UiStyleRes.line_soft(), 1.0)
	# ★ 区划招将的读条（没有单独的「停招」行）：贴着行底，从左向右推进。
	var prog := clampf(float(r.get("progress", 0.0)), 0.0, 1.0)
	if prog > 0.0:
		draw_rect(Rect2(0.0, y + h - 3.0, size.x, 3.0), Color(0.12, 0.10, 0.06, 1.0), true)
		draw_rect(Rect2(0.0, y + h - 3.0, size.x * prog, 3.0), UiStyleRes.accent_bright(), true)
	var ix := (ICON_CELL - 24.0) / 2.0
	var iy := y + 8.0
	draw_rect(Rect2(ix, iy, 24.0, 24.0), Color(0.067, 0.094, 0.133, 1.0), true)
	draw_rect(Rect2(ix, iy, 24.0, 24.0),
		UiStyleRes.accent_bright() if selected else UiStyleRes.line_soft(), false, 1.0)
	if _font != null:
		_draw_centered(String(r.get("short", "?")), Rect2(ix, iy, 24.0, 24.0), 13, UiStyleRes.text())
		draw_string(_font, Vector2(ICON_CELL + 8.0, y + 25.0), String(r.get("name", "")),
			HORIZONTAL_ALIGNMENT_LEFT, size.x - ICON_CELL - 8.0, 13,
			UiStyleRes.text() if selected else UiStyleRes.text_dim())
		var sub := String(r.get("sub", ""))
		if sub != "":
			var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(_font, Vector2(size.x - 8.0 - sw, y + 25.0), sub,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyleRes.text_dim())


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_scroll = clampf(_scroll - SCROLL_STEP, 0.0, maxf(0.0, _content_h - size.y))
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_scroll = clampf(_scroll + SCROLL_STEP, 0.0, maxf(0.0, _content_h - size.y))
			queue_redraw()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_dragging = true
				_drag_moved = false
				_drag_last_y = mb.position.y
				_pressed_row = _row_at(mb.position)
				queue_redraw()
			else:
				if _dragging and not _drag_moved:
					_activate_at(mb.position)
				_dragging = false
				_drag_moved = false
				_pressed_row = -1
				queue_redraw()
			accept_event()
			return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _dragging and (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			var dy := mm.position.y - _drag_last_y
			if absf(dy) > 0.5:
				_drag_moved = true
				_pressed_row = -1
			_drag_last_y = mm.position.y
			_scroll = clampf(_scroll - dy, 0.0, maxf(0.0, _content_h - size.y))
			queue_redraw()
		else:
			_set_hover(mm.position)
		accept_event()
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_dragging = true
			_drag_moved = false
			_drag_last_y = st.position.y
			_pressed_row = _row_at(st.position)
			queue_redraw()
		else:
			if _dragging and not _drag_moved:
				_activate_at(st.position)
			_dragging = false
			_drag_moved = false
			_pressed_row = -1
			queue_redraw()
		accept_event()
		return
	if event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		var dy2 := sd.position.y - _drag_last_y
		if absf(dy2) > 0.5:
			_drag_moved = true
		_drag_last_y = sd.position.y
		_scroll = clampf(_scroll - dy2, 0.0, maxf(0.0, _content_h - size.y))
		queue_redraw()
		accept_event()
		return


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_row = -1
		_pressed_row = -1
		_dragging = false
		queue_redraw()


func _row_at(pos: Vector2) -> int:
	var yy := pos.y + _scroll
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var y := float(r.get("y", 0.0))
		var h := float(r.get("h", 0.0))
		if yy >= y and yy < y + h:
			return i
	return -1


func _set_hover(pos: Vector2) -> void:
	var i := _row_at(pos)
	if i != _hover_row:
		_hover_row = i
		queue_redraw()


func _activate_at(pos: Vector2) -> void:
	var i := _row_at(pos)
	if i < 0:
		return
	var r: Dictionary = _rows[i]
	match String(r.get("kind", "")):
		"troop":
			var n := int(r.get("number", 0))
			# ★ 一次只能展开一支：点开的这支替换掉之前那支，再点一次收起。
			_expanded_number = 0 if _expanded_number == n else n
			# 就地重建（保留队列 / 选中态）
			var troops: Array = []
			for row in _rows:
				if String(row.get("kind", "")) == "troop":
					troops.append({"number": int(row.get("number", 0)),
						"leader": row.get("leader", null)})
			set_roster(troops, _selected_troop_number, _selected_unit)
		"unit":
			var u = r.get("unit", null)
			if u != null:
				unit_selected.emit(u)
		_:
			entry_selected.emit(r)


func _troop_name(number: int) -> String:
	var names := ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
	if number >= 1 and number < names.size():
		return "部队" + names[number]
	return "部队"


func _unit_short(u) -> String:
	if u == null:
		return "?"
	if world != null and world.has_method("recruit_short_of"):
		var s := String(world.recruit_short_of(String(u.unit_type)))
		if s != "":
			return s
	var n := String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"


func _draw_centered(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	if _font == null or text == "":
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline := rect.position.y + rect.size.y * 0.5 + float(font_size) * 0.5 - 2.0
	draw_string(_font, Vector2(rect.position.x + (rect.size.x - w) * 0.5, baseline),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)


func _draw_centered_outlined(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	if _font == null or text == "":
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline := rect.position.y + rect.size.y * 0.5 + float(font_size) * 0.5 - 2.0
	var pos := Vector2(rect.position.x + (rect.size.x - w) * 0.5, baseline)
	draw_string_outline(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 2,
		Color(0.08, 0.06, 0.03, 0.95))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
