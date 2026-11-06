## notice_stack.gd —— 左下角小地图正上方的**通知栈**：播报 + 对话共用。
##
## ★★ 为什么把对话和播报做成同一类：
##   用户口径「对话和播报可以是一类的，对话出现时播报向上移位」。
##   两者都是「从下往上堆叠的左下横幅」，只是行高 / 生命周期 / 交互不同：
##     · 播报：固定行高、到期自动上浮淡出、不接收鼠标；
##     · 对话：按文本量高、模态、打字机、点击 / 空格推进、定时自动推进。
##
## ★ 队列顺序：**最新的在最下面**（`_lines[0]`）。
##   对话占最下面那一行；对话期间的播报插在它**上面**（不会把对话框顶走）。
##
## ★ 多段对话：同一时刻只显示**一条未读对话**；推进后它上浮淡出，下一条从下面出现。
##
## ★ 这个文件是 `view/broadcast_banner.gd` 的泛化实现；后者保留为兼容入口
##   （现有 HUD / 测试仍 preload broadcast_banner）。
##
## ⚠️ 它**不点地图**：播报行 mouse_filter = IGNORE；对话行 = STOP（只吃自己那块）。
##   全屏模态盾由 HUD 负责（`hud.set_story_shield`）。
extends Control

signal dialogue_started(id: int)
signal dialogue_finished(id: int)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")

const FS := 15
const TEXT_PAD_X := 14.0
const ACCENT_W := 3.0


func _init() -> void:
	# 让子类 / 测试在 new() 之后、setup() 之前也能安全访问字段。
	pass


var cfg = null
var _font: Font = null

# ---- 播报（沿用旧 broadcast_banner 的配置）----
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

# ---- 对话（story.dialogue）----
var _d_type_sec := 0.03
var _d_auto_sec := 4.0
var _d_history_max := 5
var _d_min_h := 64.0
var _d_max_h := 220.0
var _d_font_size := 18
var _d_pad_x := 16.0
var _d_pad_y := 12.0
var _d_exit_rise := 48.0

## 每条通知（最新在前）：
##   {kind, text, color, height, row, age, exit_start_age, exit_alpha0, exit_y0,
##    x, y, display_y, target_y, alpha, _pos, _alpha_cached,
##    id, opts, type_done, type_accum, auto_accum, auto_sec, type_sec}
var _lines: Array = []

## 等待中的对话（同一时刻只有一条未读）。
var _dialogue_queue: Array = []
var _active_dialogue: Variant = null
var _dialogue_serial: int = 0
var _auto_advance_pending: bool = false
## ★ 对话退场动画结束前不推进下一条，避免「下一条盖在正在上移的旧对话上」。
var _pending_finished_id: int = -1


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
	# 播报
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
	# 对话
	_d_type_sec = maxf(0.0, cfg.num("story.dialogue.type_sec", 0.03))
	_d_auto_sec = float(cfg.num("story.dialogue.auto_sec", 4.0))
	_d_history_max = maxi(1, int(cfg.num("story.dialogue.history_max", 5.0)))
	_d_min_h = maxf(24.0, cfg.num("story.dialogue.min_height", 64.0))
	_d_max_h = maxf(_d_min_h, cfg.num("story.dialogue.max_height", 220.0))
	_d_font_size = maxi(8, int(cfg.num("story.dialogue.font_size", 18.0)))
	_d_pad_x = maxf(0.0, cfg.num("story.dialogue.pad_x", 16.0))
	_d_pad_y = maxf(0.0, cfg.num("story.dialogue.pad_y", 12.0))
	_d_exit_rise = maxf(0.0, cfg.num("story.dialogue.exit_rise", 48.0))


## 贴左下角、底边压在小地图上沿之上 `_bottom_gap`。
func _layout_self() -> void:
	var h := _stack_height()
	var r := Rect2(
		UiLayoutRes.MAP_RECT.position.x,
		UiLayoutRes.MAP_RECT.position.y - _bottom_gap - h,
		_width, h)
	UiLayoutRes.apply_rect(self, r, false, true)


# ------------------------------------------------------------------
# 对外：播报
# ------------------------------------------------------------------

## 播一条（大本营升级 / 演出提示）。`text` 由调用方拼好；`color` = 强调色。
func push(text: String, color: Color) -> void:
	if String(text) == "":
		return
	var anim := ThemeRes.animations_enabled()
	if _active_broadcast_count() >= _max_lines:
		var oldest: Dictionary = _oldest_active_broadcast()
		if not oldest.is_empty():
			if anim:
				_begin_exit(oldest, float(oldest["age"]))
			else:
				_remove_line(oldest)

	var line := _make_broadcast_row(String(text), color)
	line["x"] = -_width if anim else 0.0
	line["y"] = _bottom_y()
	line["display_y"] = float(line["y"])
	line["alpha"] = 0.0 if anim else 1.0
	_lines.insert(_broadcast_insert_index(), line)
	_reflow()
	# 纵向直接落到目标位置（新行只做**水平**滑入，与旧版一致）。
	var ty := float(line.get("target_y", line.get("y", 0.0)))
	line["y"] = ty
	line["display_y"] = ty
	_layout_self()
	visible = true
	_apply_line(line)
	if not anim:
		_apply_all()


## 把 `ui.broadcast.text_fmt` 套在「阵营名 + 目标等级」上（HUD / 测试调它）。
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
# 对外：对话
# ------------------------------------------------------------------

## 压入一条对话。返回对话 id。
## opts：{auto_sec?: float, type_sec?: float, skippable?: bool}
func push_dialogue(text: String, opts: Dictionary = {}) -> int:
	_dialogue_serial += 1
	var id := _dialogue_serial
	var item := {
		"id": id,
		"text": String(text),
		"opts": opts.duplicate(true),
	}
	if _active_dialogue == null:
		_start_dialogue(item)
	else:
		_dialogue_queue.append(item)
	return id


## 推进当前对话。返回 true = 真的推进 / 结束了一条；false = 只是补全了逐字。
func advance_dialogue() -> bool:
	if _active_dialogue == null:
		return false
	var row: Dictionary = _active_dialogue
	if not bool(row.get("type_done", true)):
		_complete_typing(row)
		return false
	_finish_dialogue_row(row)
	return true


## ★★ 点击对话：**一步快速通过** —— 正在打字就先补全，然后立刻结束这条。
##   键盘 Space / Enter 仍走 `advance_dialogue()` 的两步（补全 → 下一条）。
func fast_forward_dialogue() -> bool:
	if _active_dialogue == null:
		return false
	var row: Dictionary = _active_dialogue
	if not bool(row.get("type_done", true)):
		_complete_typing(row)
	_finish_dialogue_row(row)
	return true


## 清掉当前对话 + 队列（跳过演出 / 关场景时用）。
func clear_dialogue() -> void:
	_dialogue_queue.clear()
	_pending_finished_id = -1
	var keep: Array = []
	for line in _lines:
		var d: Dictionary = line
		if String(d.get("kind", "")) == "dialogue":
			_free_row(d)
		else:
			keep.append(d)
	_lines = keep
	_active_dialogue = null
	_reflow()
	_layout_self()
	visible = _has_any_row()
	_apply_all()


func has_dialogue() -> bool:
	return _active_dialogue != null


func dialogue_active() -> bool:
	return _active_dialogue != null


func dialogue_typing() -> bool:
	return _active_dialogue != null and not bool((_active_dialogue as Dictionary).get("type_done", true))


func dialogue_text() -> String:
	return String((_active_dialogue as Dictionary).get("text", "")) if _active_dialogue != null else ""


func dialogue_id() -> int:
	return int((_active_dialogue as Dictionary).get("id", -1)) if _active_dialogue != null else -1


## 当前对话行（测试 / HUD 读）→ Dictionary 或 null。
func dialogue_row() -> Variant:
	return _active_dialogue


# ------------------------------------------------------------------
# 每帧
# ------------------------------------------------------------------

func tick(dt: float) -> void:
	if _lines.is_empty() and _dialogue_queue.is_empty():
		return
	var d := maxf(0.0, dt)
	_auto_advance_pending = false

	# ① 先推进活跃对话的打字机 / 自动计时（不在这里增删行）。
	if _active_dialogue != null:
		_tick_dialogue(_active_dialogue, d)

	# ② 再推进每一行的生命周期（退场 / 播报到期）。
	var keep: Array = []
	for line in _lines:
		var row: Dictionary = line
		if _advance_row(row, d):
			keep.append(row)
		else:
			_free_row(row)
	_lines = keep

	# ★ 退场动画已经走完：这时才通知导演 / 起下一条对话。
	if _pending_finished_id >= 0 and not _has_line_id(_pending_finished_id):
		var fid := _pending_finished_id
		_pending_finished_id = -1
		_auto_advance_pending = false
		_emit_finished_and_next(fid)

	# ③ 自动推进（可能在 ① 里被请求）。
	if _auto_advance_pending and _active_dialogue != null:
		advance_dialogue()

	# ④ 队列里还有对话、当前没有活跃对话 → 起下一条。
	#    ⚠️ 退场动画还没走完（`_pending_finished_id >= 0`）时**不能起**，
	#       否则新对话会盖在正在上移的旧对话上。
	if _pending_finished_id < 0 and _active_dialogue == null and not _dialogue_queue.is_empty():
		_start_dialogue(_dialogue_queue.pop_front())

	if _lines.is_empty():
		visible = false
		return
	_trim_dialogue_history()
	_reflow()
	_layout_self()
	_apply_all()


func clear() -> void:
	for line in _lines:
		_free_row(line)
	_lines = []
	_dialogue_queue.clear()
	_pending_finished_id = -1
	_active_dialogue = null
	visible = false


func line_count() -> int:
	return _lines.size()


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


func line_alpha(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("alpha", 0.0))


func line_x(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("x", 0.0))


func line_y(i: int) -> float:
	if i < 0 or i >= _lines.size():
		return 0.0
	return float((_lines[i] as Dictionary).get("display_y", 0.0))


func is_exiting(i: int) -> bool:
	if i < 0 or i >= _lines.size():
		return false
	return float((_lines[i] as Dictionary).get("exit_start_age", -1.0)) >= 0.0


## 键盘推进（HUD 在把按键交给 input_controller 之前调用）。
## 空格 / 回车 = 推进对话；返回 true = 这个键被吃掉了。
func handle_key(event: InputEventKey) -> bool:
	if _active_dialogue == null or not event.pressed or event.echo:
		return false
	var k := event.keycode
	if k == KEY_SPACE or k == KEY_ENTER or k == KEY_KP_ENTER:
		advance_dialogue()
		return true
	return false


# ------------------------------------------------------------------
# 内部：队列 / 几何
# ------------------------------------------------------------------

func _has_any_row() -> bool:
	return not _lines.is_empty()


func _step() -> float:
	return _line_h + _gap


## 整个栈的高度：所有行高 + 行间距；但至少保留 `ui.broadcast` 的 max_lines 高度
## （这样没有对话时，旧 broadcast_banner 的屏幕位置与行为完全不变）。
func _stack_height() -> float:
	var min_h: float = float(_max_lines) * _line_h + float(_max_lines - 1) * _gap
	var h := 0.0
	for line in _lines:
		h += float((line as Dictionary).get("height", _line_h))
	if not _lines.is_empty():
		h += float(_lines.size() - 1) * _gap
	return maxf(min_h, h)


## 最下面一行（最新）的 y。
func _bottom_y() -> float:
	if _lines.is_empty():
		# ★ 空栈时按「下一条是播报」算（旧 broadcast_banner 的固定底边）。
		#   对话行插入后会立刻用 target_y 校正（见 `_start_dialogue`）。
		return _stack_height() - _line_h
	return _stack_height() - float((_lines[0] as Dictionary).get("height", _line_h))


func _target_y_for(index: int) -> float:
	var y := _bottom_y()
	for i in index:
		if i < 0 or i >= _lines.size():
			break
		y -= float((_lines[i] as Dictionary).get("height", _line_h)) + _gap
	return y


func _active_count() -> int:
	var n := 0
	for line in _lines:
		if float((line as Dictionary).get("exit_start_age", -1.0)) < 0.0:
			n += 1
	return n


func _active_broadcast_count() -> int:
	var n := 0
	for line in _lines:
		var d: Dictionary = line
		if String(d.get("kind", "")) == "broadcast" \
				and float(d.get("exit_start_age", -1.0)) < 0.0:
			n += 1
	return n


func _oldest_active_broadcast() -> Dictionary:
	for i in range(_lines.size() - 1, -1, -1):
		var line: Dictionary = _lines[i]
		if String(line.get("kind", "")) != "broadcast":
			continue
		if float(line.get("exit_start_age", -1.0)) < 0.0:
			return line
	return {}


func _broadcast_insert_index() -> int:
	# 有活跃对话时，播报插在它上面（对话永远占最下面）。
	if _active_dialogue != null:
		var idx: int = _lines.find(_active_dialogue)
		if idx >= 0:
			return idx + 1
	return 0


## 有效行（非退场）从下往上排：index 0 = 最下面、最新的那条。
func _reflow() -> void:
	var index := 0
	for line in _lines:
		var d: Dictionary = line
		if float(d.get("exit_start_age", -1.0)) >= 0.0:
			continue
		d["target_y"] = _target_y_for(index)
		index += 1


# ------------------------------------------------------------------
# 内部：单行生命周期
# ------------------------------------------------------------------

## 返回 false = 这条已经结束，调用方负责 free。
func _advance_row(line: Dictionary, dt: float) -> bool:
	if String(line.get("kind", "")) == "dialogue":
		var age_d := float(line.get("age", 0.0)) + dt
		line["age"] = age_d
		var e0 := float(line.get("exit_start_age", -1.0))
		if e0 >= 0.0:
			return _advance_exit(line, (age_d - e0) / maxf(_fade, 0.0001))
		return true

	# 播报：沿用旧逻辑
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
	var rise := float(line.get("exit_rise", _exit_rise))
	line["display_y"] = y0 - rise * _ease_out_cubic(q)
	return q < 1.0


func _begin_exit(line: Dictionary, at_age: float) -> void:
	line["exit_start_age"] = at_age
	var normal := _pop + _hold
	line["exit_alpha0"] = 1.0 if at_age >= normal else float(line.get("alpha", 1.0))
	line["exit_y0"] = float(line.get("y", 0.0))
	# 对话比播报抬得更高：让玩家清楚看到「这条正在离开」，而不是被下一条盖住。
	line["exit_rise"] = _d_exit_rise if String(line.get("kind", "")) == "dialogue" else _exit_rise


func _ease_out_cubic(p: float) -> float:
	return 1.0 - pow(1.0 - p, 3.0)


func _ease_out_back(p: float) -> float:
	var c1 := 1.70158
	var c3 := c1 + 1.0
	var q := p - 1.0
	return 1.0 + c3 * q * q * q + c1 * q * q


# ------------------------------------------------------------------
# 内部：对话状态机
# ------------------------------------------------------------------

func _start_dialogue(item: Dictionary) -> void:
	var id := int(item.get("id", 0))
	var row := _make_dialogue_row(id, String(item.get("text", "")),
		item.get("opts", {}))
	_lines.insert(0, row)
	_active_dialogue = row
	visible = true
	_reflow()
	var ty := float(row.get("target_y", row.get("y", 0.0)))
	row["y"] = ty
	row["display_y"] = ty
	_layout_self()
	_apply_all()
	dialogue_started.emit(id)


func _tick_dialogue(row: Dictionary, dt: float) -> void:
	row["age"] = float(row.get("age", 0.0)) + dt
	if not bool(row.get("type_done", false)):
		var text := String(row.get("text", ""))
		var total := text.length()
		# ★ 用**这一行自己的** type_sec（剧本 / 测试可以逐步覆盖），不是全局默认。
		var type_sec := float(row.get("type_sec", _d_type_sec))
		if total <= 0 or not ThemeRes.animations_enabled() or type_sec <= 0.0:
			_complete_typing(row)
			return
		row["type_accum"] = float(row.get("type_accum", 0.0)) + dt
		var chars := int(float(row["type_accum"]) / type_sec)
		if chars >= total:
			_complete_typing(row)
		else:
			var label = row.get("label", null)
			if label != null and is_instance_valid(label):
				label.visible_characters = chars
		return
	# 打字完成 → 自动推进计时
	var auto_sec := float(row.get("auto_sec", _d_auto_sec))
	if auto_sec > 0.0:
		row["auto_accum"] = float(row.get("auto_accum", 0.0)) + dt
		if float(row["auto_accum"]) >= auto_sec:
			_auto_advance_pending = true


func _complete_typing(row: Dictionary) -> void:
	row["type_done"] = true
	row["auto_accum"] = 0.0
	var label = row.get("label", null)
	if label != null and is_instance_valid(label):
		label.visible_characters = -1


func _finish_dialogue_row(row: Dictionary) -> void:
	_active_dialogue = null
	var id := int(row.get("id", -1))
	if ThemeRes.animations_enabled():
		_begin_exit(row, float(row.get("age", 0.0)))
		# ★ 先等这条**上移淡出**完，再发 finished / 起下一条。
		#   否则下一条会立刻出现在同一个位置，看起来像被覆盖。
		_pending_finished_id = id
		_reflow()
		_layout_self()
		_apply_all()
	else:
		_remove_line(row)
		_emit_finished_and_next(id)


func _emit_finished_and_next(id: int) -> void:
	dialogue_finished.emit(id)
	if _active_dialogue == null and not _dialogue_queue.is_empty():
		_start_dialogue(_dialogue_queue.pop_front())
	else:
		_reflow()
		_layout_self()
		_apply_all()


func _has_line_id(id: int) -> bool:
	for line in _lines:
		if int((line as Dictionary).get("id", -1)) == id:
			return true
	return false


func _trim_dialogue_history() -> void:
	var count := 0
	for d in _lines:
		if String((d as Dictionary).get("kind", "")) == "dialogue" and d != _active_dialogue:
			count += 1
	while count > _d_history_max:
		# 最旧的对话在数组末尾；从后往前找第一条非活跃对话。
		var removed := false
		for i in range(_lines.size() - 1, -1, -1):
			var row: Dictionary = _lines[i]
			if String(row.get("kind", "")) == "dialogue" and row != _active_dialogue:
				_lines.remove_at(i)
				_free_row(row)
				count -= 1
				removed = true
				break
		if not removed:
			break


func _on_dialogue_gui_input(event: InputEvent, row: Dictionary) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if row == _active_dialogue:
				fast_forward_dialogue()
				accept_event()
				return


# ------------------------------------------------------------------
# 内部：控件
# ------------------------------------------------------------------

func _make_broadcast_row(text: String, color: Color) -> Dictionary:
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
		"kind": "broadcast",
		"text": text,
		"color": color,
		"height": _line_h,
		"row": row,
		"label": label,
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


func _make_dialogue_row(id: int, text: String, opts: Dictionary) -> Dictionary:
	var h := _measure_dialogue_height(text)
	var row := Control.new()
	row.name = "DialogueRow"
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.position = Vector2.ZERO
	row.size = Vector2(_width, h)
	row.z_index = 2
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
	accent.size = Vector2(ACCENT_W, h)
	accent.color = UiStyleRes.accent()
	row.add_child(accent)

	var label := Label.new()
	label.name = "Text"
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.clip_text = true
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.add_theme_font_size_override("font_size", _d_font_size)
	label.add_theme_color_override("font_color", UiStyleRes.text())
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.position = Vector2(ACCENT_W + _d_pad_x, _d_pad_y)
	label.size = Vector2(_width - ACCENT_W - _d_pad_x * 2.0, h - _d_pad_y * 2.0)
	label.text = text
	var total := text.length()
	var anim := ThemeRes.animations_enabled()
	var type_sec := float(opts.get("type_sec", _d_type_sec))
	if anim and type_sec > 0.0 and total > 0:
		label.visible_characters = 0
	else:
		label.visible_characters = -1
	row.add_child(label)
	row.gui_input.connect(_on_dialogue_gui_input.bind(row))

	return {
		"kind": "dialogue",
		"id": id,
		"text": text,
		"color": UiStyleRes.accent(),
		"height": h,
		"row": row,
		"label": label,
		"opts": opts.duplicate(true),
		"age": 0.0,
		"type_done": not (anim and type_sec > 0.0 and total > 0),
		"type_sec": type_sec,
		"type_accum": 0.0,
		"auto_sec": float(opts.get("auto_sec", _d_auto_sec)),
		"auto_accum": 0.0,
		"exit_start_age": -1.0,
		"exit_alpha0": 1.0,
		"exit_y0": 0.0,
		"x": 0.0,
		"y": _bottom_y(),
		"display_y": _bottom_y(),
		"target_y": _bottom_y(),
		"alpha": 1.0,
		"_pos": Vector2(INF, INF),
		"_alpha_cached": -1.0,
	}


func _measure_dialogue_height(text: String) -> float:
	var text_w: float = maxf(40.0, _width - ACCENT_W - _d_pad_x * 2.0)
	var text_h := float(_d_font_size) * 1.4
	if _font != null:
		var sz: Vector2 = _font.get_multiline_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, text_w, _d_font_size)
		text_h = sz.y
	else:
		var per_line: int = maxi(1, int(text_w / maxf(1.0, float(_d_font_size) * 0.75)))
		var lines: int = maxi(1, int(ceil(float(text.length()) / float(per_line))))
		text_h = float(lines) * float(_d_font_size) * 1.4
	return clampf(text_h + _d_pad_y * 2.0 + 8.0, _d_min_h, _d_max_h)


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
	var idx: int = _lines.find(line)
	if idx >= 0:
		_lines.remove_at(idx)
	_free_row(line)


func _free_row(line: Dictionary) -> void:
	var row = line.get("row", null)
	if row != null and is_instance_valid(row):
		row.queue_free()
	if _active_dialogue == line:
		_active_dialogue = null
