## buff_bar.gd —— 详细信息顶部的**动态 buff 槽位**
##
## ★ 需求：去掉原来三个写死的「buff1/2/3」占位；以后由系统**动态**往里加 buff
##   （当前游戏里第一条就是士气系统给单位挂的「士气」buff）。
##
## ★ 每个 buff = 一个 40×40 文字方块（与左栏那些图标格同号）：
##   · 底色由调用方给（士气 buff = 绿→红的士气色）；
##   · 方块里写一个字（士气 =「士」）；
##   · 一横行从左往右排，`BUFF_GAP` 为格距；超出可用宽的部分不画。
##
## ★★ 悬停浮窗：鼠标停在某个 buff 方块上 → 方块描边变金，下缘弹出说明面板
##   （view/buff_tip.gd，与右下角按钮的悬停详情面板同一套底板）。
##   条目里可带 `tip_title` / `tip_body`；没有时退回 `name` / 空。
##
## ★★ 手机端没有悬停：由 HUD 的长按监视（`hud.handle_touch`）在按住
##   `touch.long_press_sec` 秒后调 `hover_at(i)`；按下期间 `touch_suppress_hover = true`
##   挡住模拟鼠标的「立刻弹」，松手 / 拖动取消时由 HUD 调 `clear_hover()`。
##
## ★ 纯显示：不读 world、不碰任何状态。HUD 每帧把
##   `[{id, text, color, name, tip_title, tip_body}]` 递进来。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const BuffTipRes = preload("res://view/buff_tip.gd")

var font: Font = null

## 当前画出来的 buff：见文件头的条目格式
var _entries: Array = []
## 上一次应用的**内容快照**：HUD 以 10Hz 重喂同一批 buff 时不要反复重画。
var _sig: String = "#none#"
## 鼠标停在第几个 buff 上（-1 = 没停在任何 buff 上）
var _hover: int = -1
## ★★ 手机端：手指按下期间**先别弹**（长按到点后由 HUD 调 `hover_at()`）。
##   与 command_card / tech_grid 的 `touch_suppress_hover` 同一条约定。
var touch_suppress_hover: bool = false
## 悬停浮窗（本控件的子节点；z_index 高，画在详情框 / 队列之上）
var _tip: Control = null
## 画过几帧（测试用）
var draw_count: int = 0


func setup(p_font: Font = null) -> void:
	font = p_font
	name = "BuffBar"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 不能裁剪：悬停浮窗要画到方块下面（40px 高之外）。
	#   方块本身在 `_draw` 里按可用宽跳过，不会溢出去。
	clip_contents = false
	custom_minimum_size = Vector2(0.0, UiLayoutRes.BUFF_SIZE)
	mouse_entered.connect(_update_hover)
	mouse_exited.connect(_on_mouse_exited)

	_tip = BuffTipRes.new()
	add_child(_tip)
	_tip.setup(font)
	_tip.visible = false


## 设置这一排 buff（空数组 = 一个都不画）。
func set_buffs(entries: Array) -> void:
	var next: Array = []
	for e in entries:
		if not (e is Dictionary):
			continue
		var d: Dictionary = e
		next.append({
			"id": String(d.get("id", "")),
			"text": String(d.get("text", "")),
			"color": d.get("color", UiStyleRes.bg_empty()),
			"name": String(d.get("name", "")),
			"tip_title": String(d.get("tip_title", "")),
			"tip_body": String(d.get("tip_body", "")),
		})
	# ★ 空 → 不吃鼠标（别挡住底下的东西）；有 buff → 收鼠标，才能收到悬停。
	mouse_filter = Control.MOUSE_FILTER_IGNORE if next.is_empty() \
		else Control.MOUSE_FILTER_STOP
	if next.is_empty():
		_hover = -1
		_tip.clear()

	var sig := _signature(next)
	if sig == _sig:
		return
	_sig = sig
	_entries = next
	if _hover < 0 or _hover >= _entries.size():
		_hover = -1
		_tip.clear()
	else:
		_refresh_tip()
	queue_redraw()


func _signature(entries: Array) -> String:
	var parts: PackedStringArray = []
	for e in entries:
		var d: Dictionary = e
		var c: Color = d.get("color", Color.BLACK)
		parts.append("%s|%s|%s|%s|%s|%s" % [
			String(d.get("id", "")), String(d.get("text", "")),
			c.to_html(), String(d.get("name", "")),
			String(d.get("tip_title", "")), String(d.get("tip_body", "")),
		])
	return "\n".join(parts)


func count() -> int:
	return _entries.size()


## 第 i 个 buff 的数据（没有 → 空字典）
func entry(i: int) -> Dictionary:
	if i < 0 or i >= _entries.size():
		return {}
	return _entries[i]


## 第 i 个 buff 的方块矩形（相对本控件；测试与悬停命中都可读）
func buff_rect(i: int) -> Rect2:
	var step := UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_GAP
	return Rect2(float(i) * step, 0.0, UiLayoutRes.BUFF_SIZE, UiLayoutRes.BUFF_SIZE)


## 第 i 个 buff 的**屏幕**矩形（手机长按命中用）
func buff_global_rect(i: int) -> Rect2:
	var r := buff_rect(i)
	r.position += global_position
	return r


# ------------------------------------------------------------------
# 悬停
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover()


func _update_hover() -> void:
	# 长按期间由 HUD 的 `hover_at()` 控制显隐：模拟鼠标的抖动 / 移出不要把它收掉。
	if touch_suppress_hover:
		return
	var p := get_local_mouse_position()
	var idx := -1
	for i in _entries.size():
		if buff_rect(i).has_point(p):
			idx = i
			break
	_set_hover(idx)


func _on_mouse_exited() -> void:
	# 长按期间手指轻微移出方块不该收浮窗；真正的收起由 HUD 在松手 / 拖动取消时调 clear_hover()。
	if touch_suppress_hover:
		return
	_set_hover(-1)


func _set_hover(idx: int) -> void:
	var next: int = idx if idx >= 0 and idx < _entries.size() else -1
	if next == _hover:
		return
	_hover = next
	queue_redraw()
	_refresh_tip()


## 按当前 `_hover` 显示 / 收起浮窗。标题为空且正文为空 → 收起。
func _refresh_tip() -> void:
	if _hover < 0 or _hover >= _entries.size():
		_tip.clear()
		return
	var e: Dictionary = _entries[_hover]
	var title := String(e.get("tip_title", ""))
	if title == "":
		title = String(e.get("name", ""))
	var body := String(e.get("tip_body", ""))
	if title == "" and body == "":
		_tip.clear()
		return
	var r := buff_rect(_hover)
	_tip.position = Vector2(r.position.x,
		UiLayoutRes.BUFF_SIZE + UiLayoutRes.BUFF_TIP_GAP)
	_tip.show_text(title, body)


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	if _entries.is_empty():
		return
	var f: Font = font
	if f == null:
		f = get_theme_default_font()
	for i in _entries.size():
		var r := buff_rect(i)
		if r.position.x >= size.x:
			break
		var e: Dictionary = _entries[i]
		draw_rect(r, e.get("color", UiStyleRes.bg_empty()), true)
		# 悬停：金边 + 2px（和页签 / 命令卡的悬停金是同一套语言）
		var hot: bool = i == _hover
		draw_rect(r, UiStyleRes.accent() if hot else UiStyleRes.line(), false,
			2.0 if hot else 1.0)
		var text := String(e.get("text", ""))
		if text != "" and f != null:
			_draw_centered(f, text, r, UiStyleRes.text(), UiStyleRes.FS_BODY)


## 在一个矩形里居中画一行字（draw_string 的 pos 是基线）
func _draw_centered(f: Font, text: String, r: Rect2, color: Color, size: int) -> void:
	var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var baseline: float = r.position.y + r.size.y * 0.5 + float(size) * 0.5 - 2.0
	draw_string(f, Vector2(r.position.x + (r.size.x - w) * 0.5, baseline), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


# ------------------------------------------------------------------
# 给测试读的小接口
# ------------------------------------------------------------------

func hover_index() -> int:
	return _hover


func tip_control() -> Control:
	return _tip


func tip_showing() -> bool:
	return _tip != null and _tip.showing()


func tip_title_text() -> String:
	return "" if _tip == null else _tip.title_text()


func tip_body_text() -> String:
	return "" if _tip == null else _tip.body_text()


## 测试 / 手机长按用：直接悬停第 i 个（-1 = 收起）
func hover_at(i: int) -> void:
	_set_hover(i)


func clear_hover() -> void:
	_set_hover(-1)
