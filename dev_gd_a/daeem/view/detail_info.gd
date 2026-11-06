## detail_info.gd —— 新详细信息面板**右列**：图标 / 部队名 / 单位名 + 信息分组
##
## 分组由 hud 组装好递进来（不在这里判断兵种 / 建筑）：
##   {"label": "属性", "type": "text", "h": 38, "lines": ["步兵 / 近战"]}
##   {"label": "将领特性", "type": "traits", "h": 74, "traits": [{"name","desc"}]}
##   {"label": "单位特性", "type": "columns", "h": 90, "columns": [["a","b"],["c"]]}
##   {"label": "特性", "type": "traits2", "h": 164, "general": [...], "unit_lines": [...]}
extends Control

const UiStyleRes = preload("res://view/ui_style.gd")
const HpBarRes = preload("res://view/hp_bar.gd")
const BuffTipRes = preload("res://view/buff_tip.gd")

const ICON_S := 72.0
const ICON_X := 8.0
## 图标顶与右侧信息框顶同高（面板 y=849）。
const ICON_Y := 11.0
## 与单位图标/右侧边等距：图标右缘 80，信息框左缘 105.5 → 25.5；
## 框右缘 394，面板右缘 616.5（信息控件 x=197）→ 25.5。
## 垂直：面板顶 820/底 1080，图标顶/框顶 849、框底 1051 → 29/29。
const DETAIL_X := 105.5
const DETAIL_W := 288.5
const DETAIL_Y := 11.0
const DETAIL_H := 202.0

var _font: Font = null
var _icon_text := ""
var _title := ""
var _subtitle := ""
var _hp_ratio := 1.0
var _show_hp := false
var _groups: Array = []
var _trait_rects: Array = []
var _tip: Panel = null
var _hover_trait := -1


func setup(p_font: Font = null) -> void:
	_font = p_font
	name = "DetailInfo"
	mouse_filter = Control.MOUSE_FILTER_STOP
	_tip = BuffTipRes.new()
	add_child(_tip)
	_tip.setup(_font)
	_tip.z_index = 20
	_tip.visible = false


func set_header(icon_text: String, title: String, subtitle: String,
		hp_ratio: float = 1.0, show_hp: bool = false) -> void:
	_icon_text = icon_text
	_title = title
	_subtitle = subtitle
	_hp_ratio = hp_ratio
	_show_hp = show_hp
	queue_redraw()


func set_groups(groups: Array) -> void:
	_groups = groups
	_trait_rects.clear()
	_hover_trait = -1
	if _tip != null:
		_tip.clear()
	queue_redraw()


func _draw() -> void:
	# 图标
	var ip := Vector2(ICON_X, ICON_Y)
	draw_rect(Rect2(ip, Vector2(ICON_S, ICON_S)), Color(0.067, 0.094, 0.133, 1.0), true)
	draw_rect(Rect2(ip, Vector2(ICON_S, ICON_S)), UiStyleRes.line(), false, 1.0)
	if _font != null:
		_draw_centered(_icon_text, Rect2(ip, Vector2(ICON_S, ICON_S)), 38, UiStyleRes.text())
	if _show_hp:
		HpBarRes.draw(self, Rect2(ip, Vector2(ICON_S, ICON_S)), _hp_ratio)

	# 部队名（17px，宽度不超过图标 72px）/ 单位名
	var cx := ICON_X + ICON_S * 0.5
	if _font != null:
		var t := _clip(_title, 17, 76.0)
		_draw_centered(t, Rect2(ICON_X, ICON_Y + 78.0, ICON_S, 24.0), 17, UiStyleRes.text())
		# ★ 单位名过长时**换行**，不加省略号（例：乂字军披甲剑士）。
		var sub_lines := _wrap_balanced(_subtitle, 13, 84.0)
		var sy := ICON_Y + 102.0
		for line in sub_lines:
			_draw_centered(line, Rect2(ICON_X - 6.0, sy, ICON_S + 12.0, 16.0), 13,
				UiStyleRes.text_dim())
			sy += 16.0

	# 信息框
	var box := Rect2(DETAIL_X, DETAIL_Y, DETAIL_W, DETAIL_H)
	draw_rect(box, Color(0.039, 0.059, 0.086, 1.0), true)
	draw_rect(box, UiStyleRes.line_soft(), false, 1.0)

	# ★ 从上往下紧凑排列：不再把整组在中段垂直居中。
	var y := DETAIL_Y
	_trait_rects.clear()
	for gi in _groups.size():
		var g: Dictionary = _groups[gi]
		var h := float(g.get("h", 38.0))
		if gi > 0:
			draw_line(Vector2(DETAIL_X + 12.0, y), Vector2(DETAIL_X + DETAIL_W - 14.0, y),
				UiStyleRes.line_soft(), 1.0)
		_draw_group(g, y, h)
		y += h


func _draw_group(g: Dictionary, y: float, h: float) -> void:
	var label := String(g.get("label", ""))
	var lx := DETAIL_X + 12.0
	var cx := DETAIL_X + 76.0
	if _font != null:
		var lcy := y + h * 0.5 if h <= 74.0 else y + 16.0
		if String(g.get("type", "")) == "text" and (g.get("lines", []) as Array).size() > 1 \
				and not bool(g.get("center", false)):
			lcy = y + 16.0
		if bool(g.get("center", false)):
			lcy = y + h * 0.5
		draw_string(_font, Vector2(lx, lcy + 4.0), label, HORIZONTAL_ALIGNMENT_LEFT,
			-1, 11, UiStyleRes.text_faint())
	match String(g.get("type", "text")):
		"traits":
			var traits: Array = g.get("traits", [])
			if traits.is_empty():
				if _font != null:
					draw_string(_font, Vector2(cx, y + h * 0.5 + 5.0), "无",
						HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyleRes.text_faint())
				return
			var xx := cx
			var baseline := y + h * 0.5 + 5.0
			for t in traits:
				var name := String((t as Dictionary).get("name", ""))
				if name == "":
					continue
				if _font == null:
					continue
				var w := _font.get_string_size(name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
				draw_string(_font, Vector2(xx, baseline), name, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 15, UiStyleRes.accent())
				draw_dashed_line(Vector2(xx, baseline + 3.0), Vector2(xx + w, baseline + 3.0),
					Color(UiStyleRes.accent().r, UiStyleRes.accent().g, UiStyleRes.accent().b, 0.5),
					1.0, 2.0, true)
				_trait_rects.append({"rect": Rect2(xx, baseline - 15.0, w, 20.0),
					"name": name, "desc": String((t as Dictionary).get("desc", ""))})
				xx += w + 18.0
		"columns":
			var cols: Array = g.get("columns", [])
			var top := y + 16.0
			var base_off := 4.0
			if bool(g.get("center", false)):
				var max_lines := 1
				for c0 in cols:
					max_lines = maxi(max_lines, (c0 as Array).size())
				top = y + (h - float(max_lines) * 20.0) * 0.5
				base_off = 14.0
			for ci in cols.size():
				var lines: Array = cols[ci]
				var colx := cx + ci * 104.0
				var ly := top
				for line in lines:
					if _font != null:
						draw_string(_font, Vector2(colx, ly + base_off), String(line),
							HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyleRes.text_dim())
					ly += 20.0
		"traits2":
			var general: Array = g.get("general", [])
			var unit_lines: Array = g.get("unit_lines", [])
			var top2 := y + 14.0
			if bool(g.get("center", false)):
				top2 = y + (h - 50.0) * 0.5
			if _font != null:
				draw_string(_font, Vector2(cx, top2 + 4.0), "将领特性",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyleRes.text_faint())
				draw_string(_font, Vector2(cx + 110.0, top2 + 4.0), "单位特性",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UiStyleRes.text_faint())
			var xx2 := cx
			if general.is_empty() and _font != null:
				draw_string(_font, Vector2(cx, top2 + 30.0), "无",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyleRes.text_faint())
			for t2 in general:
				var name2 := String((t2 as Dictionary).get("name", ""))
				if name2 == "" or _font == null:
					continue
				var w2 := _font.get_string_size(name2, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
				draw_string(_font, Vector2(xx2, top2 + 30.0), name2,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 15, UiStyleRes.accent())
				draw_dashed_line(Vector2(xx2, top2 + 33.0), Vector2(xx2 + w2, top2 + 33.0),
					Color(UiStyleRes.accent().r, UiStyleRes.accent().g, UiStyleRes.accent().b, 0.5),
					1.0, 2.0, true)
				_trait_rects.append({"rect": Rect2(xx2, top2 + 18.0, w2, 20.0),
					"name": name2, "desc": String((t2 as Dictionary).get("desc", ""))})
				xx2 += w2 + 18.0
			var ly2 := top2 + 30.0
			if unit_lines.is_empty() and _font != null:
				draw_string(_font, Vector2(cx + 110.0, ly2), "无",
					HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyleRes.text_faint())
			for line2 in unit_lines:
				if _font != null:
					draw_string(_font, Vector2(cx + 110.0, ly2), String(line2),
						HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UiStyleRes.text_dim())
				ly2 += 20.0
		_:
			var lines2: Array = g.get("lines", [])
			var centered := h <= 38.0
			var yy := y + h * 0.5 + 5.0 if centered else y + 16.0 + 4.0
			if bool(g.get("center", false)) and not centered:
				var n := lines2.size()
				yy = y + (h - float(maxi(0, n - 1)) * 22.0) * 0.5 + 6.0
			for line in lines2:
				if _font != null:
					draw_string(_font, Vector2(cx, yy), String(line),
						HORIZONTAL_ALIGNMENT_LEFT, DETAIL_X + DETAIL_W - cx - 10.0,
						15 if centered else 13, UiStyleRes.text())
				yy += 22.0


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var idx := -1
		for i in _trait_rects.size():
			if (_trait_rects[i]["rect"] as Rect2).has_point(mm.position):
				idx = i
				break
		if idx != _hover_trait:
			_hover_trait = idx
			if idx < 0:
				if _tip != null:
					_tip.clear()
			else:
				var d: Dictionary = _trait_rects[idx]
				var body := String(d.get("desc", ""))
				if body == "":
					body = "来自将领，对将领本人及旗下所有单位生效。"
				else:
					body += "\n来自将领，对将领本人及旗下所有单位生效。"
				_tip.show_text(String(d.get("name", "")), body)
				var r: Rect2 = d["rect"]
				var tx := clampf(r.position.x - 30.0, 0.0, maxf(0.0, size.x - 230.0))
				var ty := r.position.y + r.size.y + 6.0
				if ty + _tip.size.y > size.y:
					ty = maxf(0.0, r.position.y - _tip.size.y - 6.0)
				_tip.position = Vector2(tx, ty)
		accept_event()
	elif event is InputEventMouseButton:
		accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover_trait = -1
		if _tip != null:
			_tip.clear()


## 两行均衡换行：优先找「两行都放得下、左右宽度差最小」的切点。
## 例：乂字军披甲剑士（7 字）→ 乂字军披 / 甲剑士，而不是 6+1。
func _wrap_balanced(text: String, size: int, maxw: float) -> Array:
	if _font == null or text == "":
		return []
	if _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= maxw:
		return [text]
	var best: Array = []
	var best_diff := 1e20
	for s in range(text.length() - 1, 0, -1):
		var a := text.substr(0, s)
		var b := text.substr(s)
		var wa := _font.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var wb := _font.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		if wa <= maxw and wb <= maxw:
			var diff := absf(wa - wb)
			if diff < best_diff:
				best_diff = diff
				best = [a, b]
	if not best.is_empty():
		return best
	return _wrap(text, size, maxw)


## 按字符宽度换行（中文没有空格；英文单词也按字符兜底）。
func _wrap(text: String, size: int, maxw: float) -> Array:
	var out: Array = []
	if _font == null or text == "":
		return out
	var line := ""
	for i in text.length():
		var ch := text.substr(i, 1)
		var probe := line + ch
		if _font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > maxw and line != "":
			out.append(line)
			line = ch
		else:
			line = probe
	if line != "":
		out.append(line)
	return out


func _clip(text: String, size: int, maxw: float) -> String:
	if _font == null or text == "":
		return text
	if _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= maxw:
		return text
	var out := text
	while out.length() > 0:
		out = out.substr(0, out.length() - 1)
		if _font.get_string_size(out + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= maxw:
			return out + "…"
	return "…"


func _draw_centered(text: String, rect: Rect2, font_size: int, color: Color) -> void:
	if _font == null or text == "":
		return
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline := rect.position.y + rect.size.y * 0.5 + float(font_size) * 0.5 - 2.0
	draw_string(_font, Vector2(rect.position.x + (rect.size.x - w) * 0.5, baseline),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
