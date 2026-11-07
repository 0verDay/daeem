## objective_panel.gd —— 局内**左上角**的目标栏（战役 / 合作）。
##
## 版式（2026.10.20 修订，参考需求原话）：
##
##     ※目标
##     - 守住 c1（已守 32/120 秒）
##
## ★ 描述是**自由文本**：关卡 JSON 的 `objectives[].desc` 写了就用它；
##   没写时退回「目标标签 + 运行时进度」。自由描述可含 `{held}` / `{sec}` /
##   `{zone}` / `{state}` 占位符，由本文件替换。
## ★ **不再画进度条**：进度信息放进描述里（作者可自由决定写不写）。
## ★ 只有「这一局有目标」时才显示（老路径 / 自由对战没有 objective_state ⇒ 整块隐藏）。
## ★ 几何只在 `view/ui_layout.gd`；文案兜底在 `data/config.json` 的 `coop.objective`。
## ★ 它**不点**（mouse_filter = IGNORE），也不进 `interactive_rects`。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")
const ObjectiveRes = preload("res://logic/objective.gd")

const MEASURE_H := 4096.0
const TITLE_FS := 16
const DESC_FS := 14
const TITLE_GAP := 4.0

var cfg = null
var world = null
var _font: Font = null
var _bg: Panel = null
var _accent: ColorRect = null
var _title: Label = null
var _desc: Label = null
## 上一帧的内容签名：只在「显示的字变了」时重排 / 重绘。
var _sig: String = ""
## 上一帧的目标字典**身份**：剧情目标是整个替换字典的，所以换了字典 = 换了目标
## （即使标题 / 描述字面相同，也要清掉旧的划线）。
var _state_ref: Variant = null
## 刷新过几次（测试读；替代旧版的 `draw_count`）。
var refresh_count: int = 0

## ★★ 打字机：新目标出现时逐字显示；布局按**完整文本**量，所以不会边打边跳。
var _full_title: String = ""
var _full_desc: String = ""
var _text_sig: String = ""
var _typing: bool = false
var _type_t: float = 0.0
var _type_sec: float = 0.035
## ★★ 完成划去：状态变 won 时一条线从左往右划过标题 / 描述。
var _striking: bool = false
var _strike_t: float = 0.0
var _strike_sec: float = 0.32
var _struck_state: String = ""
var _strike_layer = null


func setup(p_cfg, p_world, font: Font) -> void:
	cfg = p_cfg
	world = p_world
	_font = font
	name = "ObjectivePanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	position = UiLayoutRes.OBJECTIVE_RECT.position
	size = UiLayoutRes.OBJECTIVE_RECT.size

	_bg = Panel.new()
	_bg.name = "ObjectiveBg"
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.add_theme_stylebox_override("panel",
		UiStyleRes.panel_style(UiStyleRes.bg(), UiStyleRes.line()))
	add_child(_bg)

	_accent = ColorRect.new()
	_accent.name = "ObjectiveAccent"
	_accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_accent.color = UiStyleRes.accent()
	add_child(_accent)

	_title = _make_label("ObjectiveTitle", TITLE_FS, UiStyleRes.accent())
	add_child(_title)
	_desc = _make_label("ObjectiveDesc", DESC_FS, UiStyleRes.text())
	_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_desc)

	# 划去动效的绘制层（放在文字之后 = 画在文字之上；不接收鼠标）。
	_strike_layer = StrikeLayer.new()
	_strike_layer.name = "ObjectiveStrike"
	_strike_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_strike_layer.labels = [_title, _desc]
	_strike_layer.line_color = UiStyleRes.accent()
	_strike_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_strike_layer)
	_type_sec = maxf(0.0, cfg.num("story.objective.type_sec", 0.035))
	_strike_sec = maxf(0.01, cfg.num("story.objective.strike_sec", 0.32))

	visible = false
	_sync_visibility()
	_relayout()


## 每帧由 HUD 的 shell 刷新调用。
func sync() -> void:
	if not _sync_visibility():
		return
	refresh_count += 1
	var st: Dictionary = _state()
	# ★★ 剧情目标每次 `objective_set` 都**整个换一个字典**；字典身份变了 = 新目标。
	#   放在 `_sig` 提前返回之前：否则新旧目标标题 / 描述完全相同时会漏掉。
	var new_objective := not is_same(st, _state_ref)
	_state_ref = st
	if new_objective:
		_clear_strike()
	var title := title_text()
	var desc := desc_text()
	var state := String(st.get("state", ""))
	var sig := "%s|%s|%s|%s" % [state, desc, title, str(visible)]
	if sig == _sig:
		return
	_sig = sig

	# 文本真的变了才重新打字（状态变 won 时文本不变，只触发划去）。
	var text_sig := title + "\u0001" + desc
	if text_sig != _text_sig:
		_text_sig = text_sig
		_full_title = title
		_full_desc = desc
		_title.text = title
		_desc.text = desc
		# ★★ 新目标出现：旧目标的划线必须**立刻消失**（否则会划在新文字上）。
		#   这里不能只清 `_striking` —— `_relayout()` 里会 queue_redraw，而绘制层
		#   还留着上一目标的 progress=1.0，看上去就是「新目标也被划掉了」。
		_clear_strike()
		# ★★ 2026.11.07：实时计数目标用 `quiet: true` —— 数字每变一次都重播
		#   打字机会闪个不停；这种目标直接显示完整文本。
		if bool(st.get("quiet", false)):
			_finish_typing_now()
		else:
			_start_typewriter()

	if state == ObjectiveRes.STATE_WON and _struck_state != ObjectiveRes.STATE_WON:
		_finish_typing_now()
		_striking = true
		_strike_t = 0.0 if ThemeRes.animations_enabled() else 1.0
		_struck_state = state
		if _strike_layer != null:
			_strike_layer.progress = _strike_t
			_strike_layer.queue_redraw()
	elif state != ObjectiveRes.STATE_WON and _struck_state != "":
		_striking = false
		_strike_t = 0.0
		_struck_state = state
		if _strike_layer != null:
			_strike_layer.progress = 0.0
			_strike_layer.queue_redraw()
	_relayout()


## 清掉划去动效。★ `progress` 必须一起归零：绘制层是独立节点，
##   只清 `_striking` 的话它还会按旧进度把线画在新文字上。
func _clear_strike() -> void:
	_striking = false
	_strike_t = 0.0
	_struck_state = ""
	if _strike_layer != null:
		_strike_layer.progress = 0.0
		_strike_layer.queue_redraw()


func _start_typewriter() -> void:
	_typing = (_full_title.length() + _full_desc.length()) > 0 \
		and ThemeRes.animations_enabled() and _type_sec > 0.0
	_type_t = 0.0
	if not _typing:
		_finish_typing_now()
	else:
		_title.visible_characters = 0
		_desc.visible_characters = 0


func _finish_typing_now() -> void:
	_typing = false
	_title.visible_characters = -1
	_desc.visible_characters = -1


func _apply_typewriter() -> void:
	var total := _full_title.length() + _full_desc.length()
	var n := int(_type_t / maxf(0.0001, _type_sec))
	if n >= total:
		_finish_typing_now()
		return
	var tl := _full_title.length()
	_title.visible_characters = mini(n, tl)
	_desc.visible_characters = clampi(n - tl, 0, _full_desc.length())


func _process(dt: float) -> void:
	if not visible:
		return
	# 动画总开关关掉时：打字 / 划线都直接到终点。
	if not ThemeRes.animations_enabled():
		if _typing:
			_finish_typing_now()
		if _striking and _strike_t < 1.0:
			_strike_t = 1.0
			if _strike_layer != null:
				_strike_layer.progress = 1.0
				_strike_layer.queue_redraw()
		return
	if _typing:
		_type_t += maxf(0.0, dt)
		_apply_typewriter()
	if _striking and _strike_t < 1.0:
		_strike_t = minf(1.0, _strike_t + maxf(0.0, dt) / _strike_sec)
		if _strike_layer != null:
			_strike_layer.progress = _strike_t
			_strike_layer.queue_redraw()


## 目标文字上的划去层：逐行画横线，`progress` 从左往右推进。
##
## ★★ 线的长度**按文字实际占用来量**（`Label.get_character_bounds()`），不是
##   `lbl.size.x` —— 后者是面板内宽，原来会把线一直划到面板尾部（用户 2026.11.07 报的 bug）。
class StrikeLayer extends Control:
	var labels: Array = []
	var progress: float = 0.0
	var line_color: Color = Color.WHITE
	var line_width: float = 2.0

	func _draw() -> void:
		if progress <= 0.0:
			return
		for lbl in labels:
			if lbl == null or not is_instance_valid(lbl) or not lbl.visible or lbl.text == "":
				continue
			for seg in line_segments(lbl):
				var x0: float = float(seg["x0"])
				var y: float = float(seg["y"])
				var w: float = (float(seg["x1"]) - x0) * progress
				if w <= 0.5:
					continue
				draw_line(Vector2(x0, y), Vector2(x0 + w, y), line_color, line_width)

	## 逐行返回文字实际占用的横向范围（坐标已换算到本层）。
	##
	## `get_character_bounds(i)` 用的是 **Label 自己的排版结果**（换行 / 断词都算好了），
	## 所以中英文混排、自动换行都能逐行贴住文字；宽度上限再夹到 Label 宽度
	## （`clip_text` 打开时超出的字不显示，线也不该越界）。
	func line_segments(lbl: Label) -> Array:
		var out: Array = []
		var text: String = lbl.text
		var n: int = text.length()
		if n <= 0:
			return out
		var by_line: Dictionary = {}   # 行顶 y（量化） -> {x0, x1, y_center}
		for i in n:
			var ch: String = text[i]
			if ch == "\n" or ch == "\r":
				continue
			var r: Rect2 = lbl.get_character_bounds(i)
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				continue
			# 同一行的 y 完全相同；量化一下避免浮点噪声把一行拆成两行。
			var key: int = roundi(r.position.y * 4.0)
			if not by_line.has(key):
				by_line[key] = {
					"x0": r.position.x,
					"x1": r.end.x,
					"y": r.position.y + r.size.y * 0.5,
				}
			else:
				var rec: Dictionary = by_line[key]
				rec["x0"] = minf(float(rec["x0"]), r.position.x)
				rec["x1"] = maxf(float(rec["x1"]), r.end.x)
		var keys: Array = by_line.keys()
		keys.sort()
		var limit_x: float = maxf(0.0, lbl.size.x)
		for k in keys:
			var rec2: Dictionary = by_line[k]
			var x0: float = lbl.position.x + maxf(0.0, float(rec2["x0"]))
			var x1: float = lbl.position.x + minf(limit_x, float(rec2["x1"]))
			if x1 - x0 <= 0.5:
				continue
			out.append({"x0": x0, "x1": x1, "y": lbl.position.y + float(rec2["y"])})
		return out


# ------------------------------------------------------------------
# 对外查询（测试 / 排查；界面画的时候也走这几个函数，避免两份文案）
# ------------------------------------------------------------------

## 第一行：`※` + 目标简称（如 `※坚守` / `※攻占`）。
## ★ 简称优先读关卡 `objectives[].short`；没写时按 kind 退到 config 的
##   `coop.objective.hold_short` / `capture_short`。不再固定写「※目标」。
func title_text() -> String:
	if cfg == null:
		return "※目标"
	var st: Dictionary = _state()
	if st.is_empty():
		return String(cfg.str_val("coop.objective.title_prefix", "※")) + "目标"
	# 剧情目标：标题由剧本直接给。
	var story_title := String(st.get("title", "")).strip_edges()
	if story_title != "":
		return String(cfg.str_val("coop.objective.title_prefix", "※")) + story_title
	var short := ""
	if world != null and world.level != null and world.level.has_method("objective_short"):
		short = String(world.level.objective_short(_fid())).strip_edges()
	if short == "":
		var kind := String(st.get("kind", ""))
		if kind == "capture_zone":
			short = String(cfg.str_val("coop.objective.capture_short", "攻占"))
		else:
			short = String(cfg.str_val("coop.objective.hold_short", "坚守"))
	if short == "":
		short = "目标"
	return String(cfg.str_val("coop.objective.title_prefix", "※")) + short


## 第二行（含 `- ` 前缀）：自由描述 / 自动描述。
func desc_text() -> String:
	var st: Dictionary = _state()
	if st.is_empty():
		return ""
	var prefix := "- " if cfg == null else String(cfg.str_val("coop.objective.desc_prefix", "- "))
	# 剧情目标：直接显示剧本给的描述；已完成时在末尾补一句状态。
	var is_story := String(st.get("kind", "")) == "story" \
		or String(st.get("title", "")).strip_edges() != ""
	var story_desc := String(st.get("desc", "")).strip_edges()
	if is_story:
		# 完成状态由划去动效表达，文字本身不再追加「（已完成）」——
		# 否则状态一变文本就变，会重新触发打字机。
		if story_desc == "":
			return ""
		return prefix + story_desc
	var raw := _raw_desc()
	var text := ""
	if raw != "":
		text = _fill_placeholders(raw, st)
		text = _append_status(text, st)
	else:
		text = _auto_desc(st)
	if text == "":
		return ""
	return prefix + text


## 兼容旧接口：进度文字（不再画进度条，但测试 / 其它地方仍可查询）。
func progress_text() -> String:
	var st: Dictionary = _state()
	if st.is_empty():
		return ""
	var state := String(st.get("state", ObjectiveRes.STATE_RUNNING))
	if state == ObjectiveRes.STATE_LOST:
		return "本关失守"
	if String(st.get("kind", "")) == "capture_zone":
		if state == ObjectiveRes.STATE_WON:
			return "已占领"
		return "等待占领"
	return _held_text(st)


func progress_ratio() -> float:
	var st: Dictionary = _state()
	if st.is_empty():
		return 0.0
	if String(st.get("state", "")) == ObjectiveRes.STATE_WON:
		return 1.0
	return ObjectiveRes.progress_ratio(st)


## 状态字（进行中为空；胜利 / 失守给短标签，测试与旧界面共用）。
func state_text() -> String:
	var st: Dictionary = _state()
	if st.is_empty():
		return ""
	match String(st.get("state", ObjectiveRes.STATE_RUNNING)):
		ObjectiveRes.STATE_WON:
			if String(st.get("kind", "")) == "capture_zone":
				return "已占领" if cfg == null else String(cfg.str_val("coop.objective.capture_done", "已占领"))
			return "本关守住！" if cfg == null else String(cfg.str_val("coop.objective.won_text", "本关守住！"))
		ObjectiveRes.STATE_LOST:
			return "失守" if cfg == null else String(cfg.str_val("coop.objective.lost_text", "本关失守"))
	return ""


# ------------------------------------------------------------------
# 排版
# ------------------------------------------------------------------

func _make_label(node_name: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.clip_text = true
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func _relayout() -> void:
	var inner_w: float = UiLayoutRes.OBJECTIVE_RECT.size.x - UiLayoutRes.OBJECTIVE_PAD * 2.0
	var title_h: float = _measure(_title, inner_w)
	var desc_h: float = _measure(_desc, inner_w)
	var gap: float = TITLE_GAP if (title_h > 0.0 and desc_h > 0.0) else 0.0
	var total_h: float = UiLayoutRes.OBJECTIVE_PAD * 2.0 + title_h + gap + desc_h
	total_h = maxf(total_h, UiLayoutRes.OBJECTIVE_RECT.size.y)
	size = Vector2(UiLayoutRes.OBJECTIVE_RECT.size.x, total_h)
	position = UiLayoutRes.OBJECTIVE_RECT.position

	_bg.position = Vector2.ZERO
	_bg.size = size
	_accent.position = Vector2.ZERO
	_accent.size = Vector2(3.0, size.y)

	_title.position = Vector2(UiLayoutRes.OBJECTIVE_PAD, UiLayoutRes.OBJECTIVE_PAD)
	_title.size = Vector2(inner_w, maxf(title_h, 1.0))
	_desc.position = Vector2(UiLayoutRes.OBJECTIVE_PAD,
		UiLayoutRes.OBJECTIVE_PAD + title_h + gap)
	_desc.size = Vector2(inner_w, maxf(desc_h, 1.0))
	if _strike_layer != null:
		_strike_layer.queue_redraw()


## 一个 Label 在 `w` 宽下把所有行画出来需要多高（与 hover_tip 同一套读数）。
## ⚠️ 量的时候必须把 `clip_text` 关掉：开着时 Label 的最小尺寸恒为 (1,1)。
func _measure(l: Label, w: float) -> float:
	if l == null or l.text == "":
		return 0.0
	var want_clip: bool = l.clip_text
	l.clip_text = false
	l.size = Vector2(w, MEASURE_H)
	var h: float = l.get_minimum_size().y
	l.clip_text = want_clip
	return maxf(0.0, h)


# ------------------------------------------------------------------
# 文案
# ------------------------------------------------------------------

func _sync_visibility() -> bool:
	var st: Dictionary = _state()
	var should_show: bool = (
		world != null
		and not st.is_empty()
		and String(st.get("kind", "")) != ""
		and int(st.get("zone", -1)) >= 0
	)
	if visible != should_show:
		visible = should_show
		if should_show:
			_sig = ""
			queue_redraw()
	return should_show


func _state() -> Dictionary:
	if world == null:
		return {}
	# ★ 剧情目标优先：教程的四段目标是顺序出现的，不属于 objective_state 那套
	#   「守住 / 攻占」结算；剧本写进 `world.story_objective` 就显示它。
	var so: Variant = world.story_objective
	if typeof(so) == TYPE_DICTIONARY and not (so as Dictionary).is_empty():
		return so
	var st: Variant = world.objective_state
	return st if typeof(st) == TYPE_DICTIONARY else {}


func _fid() -> String:
	return String(world.my_faction) if world != null else ""


func _raw_desc() -> String:
	if world == null or world.level == null:
		return ""
	if not world.level.has_method("objective_desc"):
		return ""
	return String(world.level.objective_desc(_fid())).strip_edges()


func _zone_label(zid: int) -> String:
	if world != null and world.level != null and world.level.has_method("zone_label"):
		return String(world.level.zone_label(zid))
	return "c%d" % zid


func _auto_desc(st: Dictionary) -> String:
	var kind := String(st.get("kind", ""))
	var zid := int(st.get("zone", -1))
	var zlabel := _zone_label(zid)
	var state := String(st.get("state", ObjectiveRes.STATE_RUNNING))
	if kind == "capture_zone":
		if state == ObjectiveRes.STATE_WON:
			return _capture_text(zlabel, "capture_done", "已占领")
		if state == ObjectiveRes.STATE_LOST:
			return _capture_text(zlabel, "lost_text", "本关失守")
		return _capture_text(zlabel, "capture_pending", "等待占领")
	# hold_zone
	var held := maxi(0, floori(float(st.get("held", 0.0))))
	var sec := maxi(0, floori(float(st.get("sec", 0.0))))
	if state == ObjectiveRes.STATE_WON:
		return _hold_text(zlabel, "won_text", "本关守住！")
	if state == ObjectiveRes.STATE_LOST:
		var fmt_lost := "守住 %s（%s）" if cfg == null else String(cfg.str_val(
			"coop.objective.auto_hold_status_fmt", "守住 %s（%s）"))
		return fmt_lost % [zlabel, _lost_tail(st)]
	if cfg == null:
		return "守住 %s（已守 %d/%d 秒）" % [zlabel, held, sec]
	var fmt := String(cfg.str_val("coop.objective.auto_hold_fmt", "守住 %s（已守 %d/%d 秒）"))
	return fmt % [zlabel, held, sec]


func _capture_text(zlabel: String, key: String, fallback: String) -> String:
	var tail := fallback if cfg == null else String(cfg.str_val("coop.objective." + key, fallback))
	var fmt := "占领 %s（%s）" if cfg == null else String(cfg.str_val(
		"coop.objective.auto_capture_fmt", "占领 %s（%s）"))
	return fmt % [zlabel, tail]


func _hold_text(zlabel: String, key: String, fallback: String) -> String:
	var tail := fallback if cfg == null else String(cfg.str_val("coop.objective." + key, fallback))
	var fmt := "守住 %s（%s）" if cfg == null else String(cfg.str_val(
		"coop.objective.auto_hold_status_fmt", "守住 %s（%s）"))
	return fmt % [zlabel, tail]


## 自由描述里的占位符：`{held}` / `{sec}` / `{zone}` / `{state}`。
func _fill_placeholders(text: String, st: Dictionary) -> String:
	var held := maxi(0, floori(float(st.get("held", 0.0))))
	var sec := maxi(0, floori(float(st.get("sec", 0.0))))
	var out := text
	out = out.replace("{held}", str(held))
	out = out.replace("{sec}", str(sec))
	out = out.replace("{zone}", _zone_label(int(st.get("zone", -1))))
	out = out.replace("{state}", state_text())
	return out


## 自由描述 + 胜负后缀（描述自己没写状态时补上，避免赢了还写着「已守 0/120」）。
func _append_status(text: String, st: Dictionary) -> String:
	var state := String(st.get("state", ObjectiveRes.STATE_RUNNING))
	if state == ObjectiveRes.STATE_WON:
		var won := "本关守住！" if cfg == null else String(cfg.str_val("coop.objective.won_text", "本关守住！"))
		return text + "（%s）" % won
	if state == ObjectiveRes.STATE_LOST:
		var lost := "本关失守" if cfg == null else String(cfg.str_val("coop.objective.lost_text", "本关失守"))
		var reason := ObjectiveRes.reason_label(st)
		var sep := "：" if cfg == null else String(cfg.str_val("coop.objective.reason_sep", "："))
		return text + "（%s%s）" % [lost, (sep + reason) if reason != "" else ""]
	return text


func _lost_tail(st: Dictionary) -> String:
	var lost := "本关失守" if cfg == null else String(cfg.str_val("coop.objective.lost_text", "本关失守"))
	var reason := ObjectiveRes.reason_label(st)
	var sep := "：" if cfg == null else String(cfg.str_val("coop.objective.reason_sep", "："))
	return lost + ((sep + reason) if reason != "" else "")


func _held_text(st: Dictionary) -> String:
	var held := maxi(0, floori(float(st.get("held", 0.0))))
	var sec := maxi(0, floori(float(st.get("sec", 0.0))))
	if cfg == null:
		return "已守 %d / %d 秒" % [held, sec]
	return String(cfg.str_val("coop.objective.held_text", "已守 %d / %d 秒")) % [held, sec]
