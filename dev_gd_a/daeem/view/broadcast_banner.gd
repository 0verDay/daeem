## broadcast_banner.gd —— 左下角小地图**正上方**的播报横幅（当前只有一件事：大本营升级）。
##
## 需求：任何**指挥官阵营**（真人席位 + command AI）开始升级大本营时，向所有玩家播报；
## 取消升级不撤播报，取消后再升会再播一条。
##
## 版式（与左上目标栏 / 结算横幅同一套语言）：
##     [3px 阵营色 | 暗底 + 1px 金线]
##     「红方 正在升级大本营 → 2 级」
##
## ★ 位置：贴左下角，宽度 = 小地图宽度（400），底边离小地图 `ui.broadcast.bottom_gap`。
##   小地图本身贴屏幕底 / 贴左，所以这里也**贴左 + 贴底**：窗口变高变宽都跟得住。
##
## ★ 队列：**最新的在最下面**（靠近小地图），旧的在上面。新通知进来时：
##     · 新的一条从左边滑进来（x: -width → 0，easeOutBack，同时淡入）；
##     · 旧的通知整体上移一格（底部固定，所以看到的是「旧的上移」）；
##     · 到期 / 被 `max_lines` 挤掉的那条向上飘并淡出。
##
## ★ 最多同时堆叠 `ui.broadcast.max_lines` 条（正在退场的那条不算，允许短暂多一行）。
## ★ 几何 / 时长 / 文案全部来自 `data/config.json` 的 `ui.broadcast`，逻辑层不认识它。
## ★ 它**不点**（mouse_filter = IGNORE），也不进 `interactive_rects`。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")

const FS := 15
const TEXT_PAD_X := 14.0
const ACCENT_W := 3.0

var cfg = null
var _font: Font = null

var _width := 400.0
var _bottom_gap := 8.0
var _line_h := 44.0
var _gap := 6.0
var _max_lines := 3
var _hold := 4.0
var _fade := 0.25
var _pop := 0.22
var _move := 0.18
var _exit_rise := 24.0
var _text_fmt := "%s 正在升级大本营 → %d 级"

## 每条播报：
##   {text, color, row, age, exit_start_age, exit_alpha0, exit_y0,
##    x, y, display_y, target_y, alpha, _pos, _alpha_cached}
## ★ `_lines[0]` = **最新**（最下面）；正在退场的旧通知排在末尾。
var _lines: Array = []


func setup(p_cfg, font: Font) -> void:
	cfg = p_cfg
	_font = font
	name = "BroadcastBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_read_config()
	_layout_self()
	visible = false


func _read_config() -> void:
	if cfg == null:
		return
	_width = maxf(120.0, UiLayoutRes.MAP_RECT.size.x)
	_bottom_gap = maxf(0.0, cfg.num("ui.broadcast.bottom_gap", 8.0))
	_line_h = maxf(20.0, cfg.num("ui.broadcast.line_height", 44.0))
	_gap = maxf(0.0, cfg.num("ui.broadcast.gap", 6.0))
	_max_lines = maxi(1, int(cfg.num("ui.broadcast.max_lines", 3.0)))
	_hold = maxf(0.0, cfg.num("ui.broadcast.hold_sec", 4.0))
	_fade = maxf(0.0, cfg.num("ui.broadcast.fade_sec", 0.25))
	_pop = maxf(0.01, cfg.num("ui.broadcast.pop_sec", 0.22))
	_move = maxf(0.01, cfg.num("ui.broadcast.move_sec", 0.18))
	_exit_rise = maxf(0.0, cfg.num("ui.broadcast.exit_rise", 24.0))
	_text_fmt = String(cfg.str_val("ui.broadcast.text_fmt", _text_fmt))


## 贴左下角、底边压在小地图上沿之上 `_bottom_gap`。
## ★ 用 apply_rect(..., false, true)：底部锚点钉在屏幕底，窗口变高时跟着小地图走。
func _layout_self() -> void:
	var h := _stack_height()
	var r := Rect2(
		UiLayoutRes.MAP_RECT.position.x,
		UiLayoutRes.MAP_RECT.position.y - _bottom_gap - h,
		_width, h)
	UiLayoutRes.apply_rect(self, r, false, true)


# ------------------------------------------------------------------
# 对外（HUD / 测试）
# ------------------------------------------------------------------

## 播一条。`text` 由 HUD 用 `ui.broadcast.text_fmt` 拼好；`color` = 阵营主色。
func push(text: String, color: Color) -> void:
	if String(text) == "":
		return
	var anim := ThemeRes.animations_enabled()
	# 满了：先让最旧的一条开始退场（它不算在 max_lines 里了）。
	if _active_count() >= _max_lines:
		var oldest: Dictionary = _oldest_active()
		if not oldest.is_empty():
			if anim:
				_begin_exit(oldest, float(oldest["age"]))
			else:
				_remove_line(oldest)

	var line := _make_line(String(text), color)
	line["x"] = -_width if anim else 0.0
	line["y"] = _bottom_y()
	line["display_y"] = float(line["y"])
	line["alpha"] = 0.0 if anim else 1.0
	# 最新的一条插到最前面 = 最下面。
	_lines.push_front(line)
	_reflow()
	visible = true
	_apply_line(line)
	# 关动画时旧行直接跳到新位置，不留在半路。
	if not anim:
		_apply_all()


## 推进计时 / 动画。`dt` 与 HUD 的 `_process(dt)` 同一个。
func tick(dt: float) -> void:
	if _lines.is_empty():
		return
	var d := maxf(0.0, dt)
	var keep: Array = []
	for line in _lines:
		if _advance(line, d):
			keep.append(line)
		else:
			_free_row(line)
	_lines = keep
	if _lines.is_empty():
		visible = false
		return
	_reflow()
	_apply_all()


func clear() -> void:
	for line in _lines:
		_free_row(line)
	_lines = []
	visible = false


## 当前**显示中**的行数（含正在向上淡出的旧行）。
func line_count() -> int:
	return _lines.size()


## 当前**有效**的堆叠条数（不算正在退场的那条）。
func active_count() -> int:
	return _active_count()


func line_text(i: int) -> String:
	if i < 0 or i >= _lines.size():
		return ""
	return String((_lines[i] as Dictionary).get("text", ""))


func line_color(i: int) -> Color:
	if i < 0 or i >= _lines.size():
		return Color(0, 0, 0, 0)
	return (_lines[i] as Dictionary).get("color", Color.WHITE)


## 这一条当前的透明度（淡入 / 淡出用；测试读它验证计时）。
func line_alpha(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("alpha", 0.0))


## 这一条当前相对横幅左缘的 x（新通知从 -width 滑到 0）。
func line_x(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("x", 0.0))


## 这一条当前的 y（含退场时的上飘位移）。
func line_y(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("display_y", 0.0))


func is_exiting(i: int) -> bool:
	if i < 0 or i >= _lines.size():
		return false
	return float((_lines[i] as Dictionary).get("exit_start_age", -1.0)) >= 0.0


## 把 `ui.broadcast.text_fmt` 套在「阵营名 + 目标等级」上（HUD 调它，测试也调它）。
func format_text(faction_name: String, target_level: int) -> String:
	var s := _text_fmt
	if s == "":
		return "%s → %d 级" % [faction_name, target_level]
	if s.contains("%d"):
		s = s % [faction_name, target_level]
	else:
		s = s % faction_name
	return s


# ------------------------------------------------------------------
# 内部：队列 / 几何
# ------------------------------------------------------------------

func _step() -> float:
	return _line_h + _gap


func _stack_height() -> float:
	return float(_max_lines) * _line_h + float(_max_lines - 1) * _gap


## 最下面一行（最新）的 y。
func _bottom_y() -> float:
	return _stack_height() - _line_h


func _target_y_for(index: int) -> float:
	return _bottom_y() - float(index) * _step()


func _active_count() -> int:
	var n := 0
	for line in _lines:
		if float((line as Dictionary).get("exit_start_age", -1.0)) < 0.0:
			n += 1
	return n


func _oldest_active() -> Dictionary:
	for i in range(_lines.size() - 1, -1, -1):
		var line: Dictionary = _lines[i]
		if float(line.get("exit_start_age", -1.0)) < 0.0:
			return line
	return {}


## 有效行（非退场）从下往上排：index 0 = 最下面、最新的那条。
## 退场行保持自己的 y，不再参与 reflow（它们已经在往上飘）。
func _reflow() -> void:
	var index := 0
	for line in _lines:
		var d: Dictionary = line
		if float(d.get("exit_start_age", -1.0)) >= 0.0:
			continue
		d["target_y"] = _target_y_for(index)
		index += 1


# ------------------------------------------------------------------
# 内部：单条生命周期
# ------------------------------------------------------------------

## 返回 false = 这条已经结束，调用方负责 free。
func _advance(line: Dictionary, dt: float) -> bool:
	var age := float(line.get("age", 0.0)) + dt
	line["age"] = age
	if not ThemeRes.animations_enabled():
		if age >= _hold:
			return false
		line["x"] = 0.0
		line["y"] = float(line.get("target_y", 0.0))
		line["display_y"] = float(line["y"])
		line["alpha"] = 1.0
		return true

	var f := maxf(_fade, 0.0001)
	var exit_start := float(line.get("exit_start_age", -1.0))
	if exit_start >= 0.0:
		return _advance_exit(line, (age - exit_start) / f)

	var normal_exit := _pop + _hold
	if age >= normal_exit:
		_begin_exit(line, normal_exit)
		return _advance_exit(line, (age - normal_exit) / f)

	if age < _pop:
		var p := age / _pop
		var e := _ease_out_back(p)
		line["x"] = -_width * (1.0 - e)
		line["alpha"] = clampf(p, 0.0, 1.0)
	else:
		line["x"] = 0.0
		line["alpha"] = 1.0
	var speed := _step() / _move
	line["y"] = move_toward(float(line.get("y", 0.0)),
		float(line.get("target_y", 0.0)), speed * dt)
	line["display_y"] = float(line["y"])
	return true


func _advance_exit(line: Dictionary, p: float) -> bool:
	var q := clampf(p, 0.0, 1.0)
	var a0 := float(line.get("exit_alpha0", 1.0))
	line["alpha"] = lerpf(a0, 0.0, q)
	line["x"] = 0.0
	var y0 := float(line.get("exit_y0", 0.0))
	line["display_y"] = y0 - _exit_rise * _ease_out_cubic(q)
	return q < 1.0


func _begin_exit(line: Dictionary, at_age: float) -> void:
	line["exit_start_age"] = at_age
	# 正常到期时它已经停稳（alpha=1）；被挤掉时可能还在淡入，从当前值接着退。
	var normal := _pop + _hold
	line["exit_alpha0"] = 1.0 if at_age >= normal else float(line.get("alpha", 1.0))
	line["exit_y0"] = float(line.get("y", 0.0))


func _ease_out_cubic(p: float) -> float:
	return 1.0 - pow(1.0 - p, 3.0)


## 从左往右「弹」进来：先冲过目标位置一点再回弹。
func _ease_out_back(p: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	var q := p - 1.0
	return 1.0 + c3 * q * q * q + c1 * q * q


# ------------------------------------------------------------------
# 内部：控件
# ------------------------------------------------------------------

func _make_line(text: String, color: Color) -> Dictionary:
	var row := Control.new()
	row.name = "BroadcastRow"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.position = Vector2(-_width, _bottom_y())
	row.size = Vector2(_width, _line_h)
	add_child(row)

	var bg := Panel.new()
	bg.name = "Bg"
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line()))
	bg.position = Vector2.ZERO
	bg.size = row.size
	row.add_child(bg)

	var accent := ColorRect.new()
	accent.name = "Accent"
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent.position = Vector2.ZERO
	accent.size = Vector2(ACCENT_W, _line_h)
	accent.color = color
	row.add_child(accent)

	var label := Label.new()
	label.name = "Text"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = true
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", FS)
	label.add_theme_color_override("font_color", UiStyleRes.text())
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.position = Vector2(TEXT_PAD_X, 0.0)
	label.size = Vector2(_width - TEXT_PAD_X * 2.0, _line_h)
	label.text = text
	row.add_child(label)

	return {
		"text": text,
		"color": color,
		"row": row,
		"age": 0.0,
		"exit_start_age": -1.0,
		"exit_alpha0": 1.0,
		"exit_y0": 0.0,
		"x": -_width,
		"y": _bottom_y(),
		"display_y": _bottom_y(),
		"target_y": _bottom_y(),
		"alpha": 1.0,
		"_pos": Vector2(INF, INF),
		"_alpha_cached": -1.0,
	}


func _apply_line(line: Dictionary) -> void:
	var row: Control = line.get("row", null)
	if row == null or not is_instance_valid(row):
		return
	var pos := Vector2(float(line.get("x", 0.0)), float(line.get("display_y", 0.0)))
	var last: Vector2 = line.get("_pos", Vector2(INF, INF))
	if pos.distance_squared_to(last) > 0.0001:
		row.position = pos
		line["_pos"] = pos
	var a := clampf(float(line.get("alpha", 0.0)), 0.0, 1.0)
	if absf(a - float(line.get("_alpha_cached", -1.0))) > 0.002:
		row.modulate = Color(1.0, 1.0, 1.0, a)
		line["_alpha_cached"] = a


func _apply_all() -> void:
	for line in _lines:
		_apply_line(line)


func _remove_line(line: Dictionary) -> void:
	var idx := _lines.find(line)
	if idx >= 0:
		_lines.remove_at(idx)
	_free_row(line)


func _free_row(line: Dictionary) -> void:
	var row = line.get("row", null)
	if row != null and is_instance_valid(row):
		row.queue_free()
