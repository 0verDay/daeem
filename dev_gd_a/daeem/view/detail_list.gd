## detail_list.gd —— 左下角详情牌的**下半**：成员格 + 特性 / 数值
##
## 版式照 art_draft/hud_balatro_direction_v2.html：
##
## 单队 / 单个对象（`.mini-roster` + `.traits`）：
##   [将][枪][盾][弓][车]                      ← 34×34 成员格：选中的那一格抬起变金
##   将 领 特 性                              单位特性
##   [对骑兵+25%] [远程减伤+10%]              对骑兵 +25%（将）
##
## 多队（`.selection-head` 下面的两段）：
##   当 前 部 队 成 员
##   [将][枪][盾][弓][车]
##   其 他 已 选 部 队　·　点序号切换
##   ① 子剡 · 羽林营 5/11   ② 阿吉 · 弓骑队 4/11   …
##
## ★ `_rows` 仍然是「这一层现在有哪些行」的**唯一真相**（几何也写在里面），
##   `_row_at` / `_activate_at` / 悬停都读它；点击照旧发 `unit_selected` / `entry_selected`。
##   kind 沿用旧值（focus / members / troop_chip / unit / entry）—— 测试直接读它们。
##
## ★ 特性胶囊仍是**悬停出浮窗**（`buff_tip.gd`，与 buff 方块同一套浮窗）。
extends Control

const UiStyleRes = preload("res://view/ui_style.gd")
const UiTextRes = preload("res://view/ui_text.gd")
const BuffTipRes = preload("res://view/buff_tip.gd")

signal unit_selected(unit)
signal entry_selected(entry)

## 成员格（方向稿 `.mini-roster span{width:34px;height:34px}`）
const CELL := 34.0
const CELL_GAP := 6.0
## 抬起量：选中的那一格往上挪（方向稿 `.on{transform:translateY(-3px)}`）
const CELL_LIFT := 3.0
const CAP_FS := 9
const CAP_TRACK := 1.6
const LINE_FS := 10
const LINE_STEP := 13.0
const CHIP_FS := 10
const CHIP_H := 18.0
const CHIP_GAP := 5.0
const LEFT_X := 14.0
## 单队态：成员格在上，特性 / 数值**页脚钉在牌底**（方向稿 `.traits{bottom:16px}`）
const CELLS_Y := 7.0
const CAP_Y := 66.0
const INFO_Y := 74.0
## 多队态
const M_CAP_A_Y := 14.0
const M_CELLS_Y := 20.0
const M_CAP_B_Y := 68.0
const M_CHIPS_Y := 74.0
const M_CHIP_H := 34.0
const M_CHIP_GAP := 6.0

var world = null
var _font: Font = null

var _rows: Array = []
var _mode: String = "single"
var _traits: Array = []
var _lines: Array = []
var _traits_label := "将领特性"
var _lines_label := "单位特性"
var _selected_unit = null
var _selected_entry = null
var _selected_troop_number: int = 0
var _hover_row: int = -1
var _pressed_row: int = -1
var _tip: Panel = null
var _trait_rects: Array = []
var _hover_trait: int = -1


func setup(p_world, p_font: Font = null) -> void:
	world = p_world
	_font = p_font
	name = "DetailList"
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	set_process(false)
	_tip = BuffTipRes.new()
	add_child(_tip)
	_tip.setup(_font)
	_tip.z_index = 30
	_tip.visible = false


# ------------------------------------------------------------------
# 数据
# ------------------------------------------------------------------

func set_roster(troops: Array, focused_number: int, selected_unit) -> void:
	_selected_unit = selected_unit
	_selected_entry = null
	_selected_troop_number = focused_number
	_rows.clear()
	var multi := troops.size() > 1
	if multi:
		_mode = "multi"
		var focus: Dictionary = {}
		for t in troops:
			var d: Dictionary = t
			if int(d.get("number", 0)) == focused_number:
				focus = d
		if focus.is_empty() and not troops.is_empty():
			focus = troops[0]
		if focus.is_empty():
			_layout_multi([])
			return
		var frow: Dictionary = focus.duplicate()
		frow["kind"] = "focus"
		_rows.append(frow)
		_rows.append({"kind": "members", "units": (focus.get("units", []) as Array).duplicate()})
		for t in troops:
			var d2: Dictionary = t
			if int(d2.get("number", 0)) == int(focus.get("number", 0)):
				continue
			var c: Dictionary = d2.duplicate()
			c["kind"] = "troop_chip"
			_rows.append(c)
		_layout_multi(_rows)
		queue_redraw()
		return
	# 单队：一格一个单位（将领排首位）
	_mode = "single"
	var units: Array = []
	if not troops.is_empty():
		var t0: Dictionary = troops[0]
		var leader = t0.get("leader", null)
		if leader != null:
			units.append(leader)
			if world != null and world.has_method("retinue_of"):
				for u in world.retinue_of(String(leader.id), true):
					if u != leader:
						units.append(u)
			if units.size() == 1:
				for u2 in (t0.get("units", []) as Array):
					if u2 != leader:
						units.append(u2)
	for i in units.size():
		var u = units[i]
		_rows.append({"kind": "unit", "unit": u, "number": int(_selected_troop_number),
			"leader": (troops[0].get("leader", null) if not troops.is_empty() else null),
			"is_leader": i == 0})
	_layout_cells()
	queue_redraw()


func set_small_entries(entries: Array, primary, kind: String) -> void:
	_selected_unit = null
	_selected_entry = primary
	_selected_troop_number = 0
	_rows.clear()
	_mode = "entry"
	for e in entries:
		if e is Dictionary:
			var d: Dictionary = (e as Dictionary).duplicate()
			d["kind"] = "entry"
			d["entry_kind"] = kind
			_rows.append(d)
	_layout_cells()
	queue_redraw()


## 将领特性（悬停出浮窗的胶囊）：[{name, desc}]
func set_traits(traits: Array, label: String = "将领特性") -> void:
	_traits = traits
	_traits_label = label if label != "" else "将领特性"
	queue_redraw()


## 单位特性 / 数值那些短行（右列，10 号字）
func set_lines(lines: Array, label: String = "单位特性") -> void:
	_lines = lines
	_lines_label = label if label != "" else "单位特性"
	queue_redraw()


# ------------------------------------------------------------------
# 布局
# ------------------------------------------------------------------

## 单队 / 单个对象：成员格从左往右排，超出的收成一个「+N」格。
func _layout_cells() -> void:
	# ★ 只有一格时不画成员条（`_draw_single` 里同一条判断）⇒ 也不留可点区域。
	var max_cells := _max_cells() if _rows.size() > 1 else 0
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		if i < max_cells:
			r["x"] = LEFT_X + float(i) * (CELL + CELL_GAP)
			r["y"] = CELLS_Y
			r["w"] = CELL
			r["h"] = CELL
		else:
			r["x"] = -1000.0
			r["y"] = -1000.0
			r["w"] = 0.0
			r["h"] = 0.0


func _max_cells() -> int:
	var avail := maxf(CELL, size.x - 2.0 * LEFT_X)
	var n := int(floor((avail + CELL_GAP) / (CELL + CELL_GAP)))
	return maxi(1, n)


func _layout_multi(rows: Array) -> void:
	var chips: Array = []
	for r in rows:
		if String((r as Dictionary).get("kind", "")) == "troop_chip":
			chips.append(r)
	for r in rows:
		var d: Dictionary = r
		match String(d.get("kind", "")):
			"focus", "members":
				# 这两行只提供内容（名字 / 成员），自己不占可点区域
				d["x"] = 0.0
				d["w"] = 0.0
				d["y"] = -1000.0
				d["h"] = 0.0
	var gap := M_CHIP_GAP
	var cols := 3
	var cw := (size.x - 2.0 * LEFT_X - gap * float(cols - 1)) / float(cols)
	for i in chips.size():
		var d2: Dictionary = chips[i]
		var col := i % cols
		var row := int(i / cols)
		d2["x"] = LEFT_X + float(col) * (cw + gap)
		d2["w"] = cw
		d2["y"] = M_CHIPS_Y + float(row) * (M_CHIP_H + gap)
		d2["h"] = M_CHIP_H


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	var f := _font if _font != null else get_theme_default_font()
	_trait_rects.clear()
	if _rows.is_empty():
		if f != null:
			UiTextRes.tracked(self, f, Vector2(LEFT_X, 24.0), "未选中", CAP_FS,
				UiStyleRes.text_faint(), CAP_TRACK)
		return
	if _mode == "multi":
		_draw_multi(f)
	else:
		_draw_single(f)


func _draw_multi(f: Font) -> void:
	var members: Array = []
	for r in _rows:
		var d: Dictionary = r
		if String(d.get("kind", "")) == "members":
			members = d.get("units", [])
	# ① 当前部队成员
	_cap(f, Vector2(LEFT_X, M_CAP_A_Y), "当前部队成员")
	_draw_units_row(members, M_CELLS_Y)
	# ② 其他已选部队
	var chips: Array = []
	for r in _rows:
		if String((r as Dictionary).get("kind", "")) == "troop_chip":
			chips.append(r)
	if chips.is_empty():
		return
	_cap(f, Vector2(LEFT_X, M_CAP_B_Y), "其他已选部队 · 点序号切换")
	for i in _rows.size():
		var d2: Dictionary = _rows[i]
		if String(d2.get("kind", "")) != "troop_chip":
			continue
		_draw_troop_chip(d2, i, f)


## 单队 / 单个对象：成员格 + 信息区（左 = 将领特性胶囊，右 = 单位特性 / 数值）
func _draw_single(f: Font) -> void:
	var units: Array = []
	var entries: Array = []
	for r in _rows:
		var d: Dictionary = r
		if String(d.get("kind", "")) == "unit":
			units.append(d.get("unit", null))
		elif String(d.get("kind", "")) == "entry":
			entries.append(d)
	# ★ 只有一个格子时不画成员条：那和上面的头像重复，还白占一行。
	if entries.size() > 1:
		_draw_entries_row(entries, CELLS_Y, f)
	elif entries.is_empty() and units.size() > 1:
		_draw_units_row(units, CELLS_Y)
	# 信息区固定在同一个页脚位置（有没有成员条都一样：跳来跳去更难看）
	var cap_y: float = CAP_Y
	var info_y: float = INFO_Y
	var has_traits := not _traits.is_empty()
	var has_lines := not _lines.is_empty()
	if not has_traits and not has_lines:
		return
	# 信息区顶上一条淡金细线：让「特性 / 数值」读起来是这张牌的页脚，
	# 而不是悬在半空、看着像少画了一行。
	draw_line(Vector2(LEFT_X, cap_y - 12.0), Vector2(size.x - LEFT_X, cap_y - 12.0),
		Color(UiStyleRes.accent(), 0.18), 1.0)
	var full_w := size.x - 2.0 * LEFT_X
	# 只有一种内容时**通栏**（另一半留白会让整块看起来像少画了一列）
	if not (has_traits and has_lines):
		if has_traits:
			_cap(f, Vector2(LEFT_X, cap_y), _traits_label)
			_draw_trait_chips(f, LEFT_X, info_y, full_w)
		else:
			_cap(f, Vector2(LEFT_X, cap_y), _lines_label)
			_draw_lines(f, LEFT_X, info_y + 2.0, full_w)
		return
	var col_w := (full_w - 16.0) * 0.5
	var right_x := LEFT_X + col_w + 16.0
	_cap(f, Vector2(LEFT_X, cap_y), _traits_label)
	_draw_trait_chips(f, LEFT_X, info_y, col_w)
	_cap(f, Vector2(right_x, cap_y), _lines_label)
	_draw_lines(f, right_x, info_y + 2.0, col_w)


## 带字距的小标题（方向稿 `.section-cap`）
func _cap(f: Font, pos: Vector2, text: String) -> void:
	if f == null:
		return
	UiTextRes.tracked(self, f, pos, text, CAP_FS, Color(UiStyleRes.text_faint(), 0.95),
		CAP_TRACK)


## 成员格：34×34，选中的那一格抬起 + 变金；将领那一格用金色描边（方向稿 `.member.leader`）
func _draw_units_row(units: Array, y: float) -> void:
	if units.is_empty():
		return
	var max_cells := _max_cells()
	var shown := units.size()
	# 多出来的人收成最后一格的「+N」
	var overflow := 0
	if shown > max_cells:
		overflow = shown - (max_cells - 1)
		shown = max_cells - 1
	for i in shown:
		var u = units[i]
		var sel: bool = u != null and u == _selected_unit
		var is_leader: bool = i == 0
		var rect := Rect2(LEFT_X + float(i) * (CELL + CELL_GAP),
			y - (CELL_LIFT if sel else 0.0), CELL, CELL)
		_draw_cell(rect, _short(u), sel, is_leader,
			(float(u.hp_ratio()) if (u != null and u.has_method("hp_ratio")) else -1.0))
	if overflow > 0:
		var r2 := Rect2(LEFT_X + float(shown) * (CELL + CELL_GAP), y, CELL, CELL)
		_draw_cell(r2, "+%d" % overflow, false, false, -1.0)


func _draw_entries_row(entries: Array, y: float, f: Font) -> void:
	var max_cells := _max_cells()
	for i in mini(entries.size(), max_cells):
		var d: Dictionary = entries[i]
		var ref = d.get("ref", null)
		var sel: bool = ref != null and ref == _selected_entry
		var rect := Rect2(LEFT_X + float(i) * (CELL + CELL_GAP),
			y - (CELL_LIFT if sel else 0.0), CELL, CELL)
		var hp := -1.0
		if ref != null and ref.has_method("hp_ratio"):
			hp = float(ref.hp_ratio())
		_draw_cell(rect, String(d.get("short", "?")), sel, false, hp, f)
	if entries.size() > max_cells and f != null:
		var r2 := Rect2(LEFT_X + float(max_cells - 1) * (CELL + CELL_GAP), y, CELL, CELL)
		_draw_cell(r2, "+%d" % (entries.size() - max_cells + 1), false, false, -1.0, f)


func _draw_cell(rect: Rect2, text: String, selected: bool, leader: bool,
		hp: float, f: Font = null) -> void:
	var face := Color(0.043, 0.058, 0.078, 1.0)
	if selected:
		face = face.lerp(UiStyleRes.accent(), 0.55)
	draw_rect(rect, face, true)
	var border: Color = UiStyleRes.line_soft()
	var bw := 1.0
	if selected:
		border = UiStyleRes.accent_bright()
		bw = 2.0
	elif leader:
		border = Color(UiStyleRes.accent(), 0.65)
		bw = 1.5
	draw_rect(rect, border, false, bw)
	var font := f if f != null else (_font if _font != null else get_theme_default_font())
	UiTextRes.centered(self, font, Rect2(rect.position, Vector2(rect.size.x, rect.size.y - 3.0)),
		text, 13, UiStyleRes.text_on_accent() if selected else UiStyleRes.text())
	if hp >= 0.0:
		var bar := Rect2(rect.position.x + 3.0, rect.end.y - 5.0, rect.size.x - 6.0, 2.0)
		draw_rect(bar, UiStyleRes.hp_bar_bg(), true)
		var w := bar.size.x * clampf(hp, 0.0, 1.0)
		if w > 0.0:
			draw_rect(Rect2(bar.position, Vector2(w, bar.size.y)),
				UiStyleRes.hp_bar_color(hp), true)


## 将领特性胶囊：一行一个框，超出列宽就换行（最多两行）
func _draw_trait_chips(f: Font, x0: float, y0: float, max_w: float) -> void:
	if f == null:
		return
	var cx := x0
	var cy := y0
	for t in _traits:
		var name := String((t as Dictionary).get("name", ""))
		if name == "":
			continue
		var tw := UiTextRes.tracked_width(f, name, CHIP_FS, 0.4)
		var w := minf(max_w, tw + 12.0)
		if cx + w > x0 + max_w + 0.5:
			cx = x0
			cy += CHIP_H + 4.0
		if cy + CHIP_H > size.y - 2.0:
			return
		var r := Rect2(cx, cy, w, CHIP_H)
		draw_rect(r, Color(0.20, 0.16, 0.09, 0.95), true)
		draw_rect(r, Color(UiStyleRes.accent(), 0.55), false, 1.0)
		draw_string(f, Vector2(r.position.x + 6.0, r.position.y + 13.0),
			UiTextRes.fit(f, name, w - 12.0, CHIP_FS), HORIZONTAL_ALIGNMENT_LEFT,
			w - 12.0, CHIP_FS, UiStyleRes.accent_bright())
		_trait_rects.append({"rect": r, "name": name,
			"desc": String((t as Dictionary).get("desc", ""))})
		cx += w + CHIP_GAP


func _draw_lines(f: Font, x0: float, y0: float, max_w: float) -> void:
	if f == null:
		return
	var y := y0
	for line in _lines:
		if y > size.y - 2.0:
			return
		draw_string(f, Vector2(x0, y), UiTextRes.fit(f, String(line), max_w, LINE_FS),
			HORIZONTAL_ALIGNMENT_LEFT, max_w, LINE_FS, UiStyleRes.text_dim())
		y += LINE_STEP


## 其他已选部队的一格：序号圆章 + 名字 + 「当前/上限」
func _draw_troop_chip(d: Dictionary, row_i: int, f: Font) -> void:
	var rect := Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)),
		float(d.get("w", 0.0)), float(d.get("h", 0.0)))
	if rect.size.x <= 1.0:
		return
	var hovered := row_i == _hover_row or row_i == _pressed_row
	draw_rect(rect, Color(0.055, 0.072, 0.098, 1.0) if hovered
		else Color(0.043, 0.058, 0.078, 1.0), true)
	draw_rect(rect, UiStyleRes.accent() if hovered else UiStyleRes.line_soft(),
		false, 1.0)
	var number := int(d.get("number", 0))
	var leader = d.get("leader", null)
	var badge := Rect2(rect.position.x + 4.0, rect.position.y + 4.0, 26.0, 26.0)
	var center := badge.get_center()
	var selected := number == _selected_troop_number
	draw_circle(center, 13.0, UiStyleRes.accent() if selected
		else Color(0.02, 0.03, 0.04, 1.0))
	draw_arc(center, 12.0, 0.0, TAU, 32,
		UiStyleRes.accent_bright() if selected else Color(UiStyleRes.accent(), 0.6),
		1.0, true)
	UiTextRes.centered(self, f, badge, str(number), 13,
		UiStyleRes.text_on_accent() if selected else UiStyleRes.text())
	if f == null or leader == null:
		return
	var tx := rect.position.x + 34.0
	var tw := rect.size.x - 38.0
	draw_string(f, Vector2(tx, rect.position.y + 15.0),
		UiTextRes.fit(f, String(leader.name), tw, 10), HORIZONTAL_ALIGNMENT_LEFT,
		tw, 10, UiStyleRes.text())
	var units: Array = d.get("units", [])
	var cap := 0
	if world != null and world.has_method("effective_retinue_cap"):
		cap = int(world.effective_retinue_cap(leader))
	if cap <= 0:
		cap = units.size()
	draw_string(f, Vector2(tx, rect.position.y + 28.0), "%d/%d" % [units.size(), cap],
		HORIZONTAL_ALIGNMENT_LEFT, tw, 9, UiStyleRes.text_dim())


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressed_row = _row_at(mb.position)
				queue_redraw()
			else:
				var i := _row_at(mb.position)
				if i >= 0 and i == _pressed_row:
					_activate_at(i)
				_pressed_row = -1
				queue_redraw()
			accept_event()
			return
		accept_event()
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_set_hover(mm.position)
		_update_trait_tip(mm.position)
		accept_event()
		return
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			_pressed_row = _row_at(st.position)
			queue_redraw()
		else:
			var i2 := _row_at(st.position)
			if i2 >= 0 and i2 == _pressed_row:
				_activate_at(i2)
			_pressed_row = -1
			queue_redraw()
		accept_event()
		return


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_row = -1
		_pressed_row = -1
		_hide_tip()
		queue_redraw()


func _row_at(pos: Vector2) -> int:
	for i in _rows.size():
		var r: Dictionary = _rows[i]
		var w := float(r.get("w", 0.0))
		if w <= 1.0:
			continue
		var rect := Rect2(float(r.get("x", 0.0)), float(r.get("y", 0.0)), w,
			float(r.get("h", 0.0)))
		if rect.has_point(pos):
			return i
	return -1


func _set_hover(pos: Vector2) -> void:
	var i := _row_at(pos)
	if i != _hover_row:
		_hover_row = i
		queue_redraw()


func _activate_at(i: int) -> void:
	if i < 0 or i >= _rows.size():
		return
	var r: Dictionary = _rows[i]
	match String(r.get("kind", "")):
		"unit":
			var u = r.get("unit", null)
			if u != null:
				unit_selected.emit(u)
		"troop_chip":
			var leader = r.get("leader", null)
			if leader != null:
				unit_selected.emit(leader)
		"entry":
			entry_selected.emit(r)
		_:
			pass


## 特性胶囊的悬停浮窗
func _update_trait_tip(pos: Vector2) -> void:
	var idx := -1
	for i in _trait_rects.size():
		if (_trait_rects[i]["rect"] as Rect2).has_point(pos):
			idx = i
			break
	if idx == _hover_trait:
		return
	_hover_trait = idx
	if idx < 0:
		_hide_tip()
		return
	var d: Dictionary = _trait_rects[idx]
	var body := String(d.get("desc", ""))
	if body == "":
		body = "来自将领，对将领本人及旗下所有单位生效。"
	else:
		body += "\n来自将领，对将领本人及旗下所有单位生效。"
	_tip.show_text(String(d.get("name", "")), body)
	var r: Rect2 = d["rect"]
	var tx := clampf(r.position.x, 0.0, maxf(0.0, size.x - 230.0))
	var ty := r.position.y - _tip.size.y - 6.0
	if ty < 0.0:
		ty = r.end.y + 6.0
	_tip.position = Vector2(tx, ty)


func _hide_tip() -> void:
	_hover_trait = -1
	if _tip != null:
		_tip.clear()


# ------------------------------------------------------------------
# 给测试 / 其它 UI 用的小接口
# ------------------------------------------------------------------

func mode() -> String:
	return _mode


func trait_count() -> int:
	return _traits.size()


func line_count() -> int:
	return _lines.size()


func row_count() -> int:
	return _rows.size()


## 真正能点的格子（成员格 / 其他部队格 / 条目格）在**本控件内**的矩形。
## ★ 给 hud 的 `blocks_edge_scroll` 用：面板里只有文字的地方不该拦边缘滚屏。
func interactive_rects() -> Array:
	var out: Array = []
	for r in _rows:
		var w := float((r as Dictionary).get("w", 0.0))
		var h := float((r as Dictionary).get("h", 0.0))
		if w <= 1.0 or h <= 1.0:
			continue
		var d: Dictionary = r
		out.append(Rect2(float(d.get("x", 0.0)), float(d.get("y", 0.0)), w, h))
	return out


func _short(u) -> String:
	if u == null:
		return "?"
	# ★ 与 hud._unit_short 同一条口径：只有**真正能招募的兵种**才用招募表里的短字；
	#   将领（不可招募）用名字首字 —— 否则将领也会被写成「枪」（它的 unit_type 是长枪）。
	if world != null and world.has_method("is_recruitable") \
			and world.is_recruitable(String(u.kind)):
		var s := String(world.recruit_short_of(String(u.kind)))
		if s != "":
			return s
	var n := String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"
