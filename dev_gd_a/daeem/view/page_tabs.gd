## page_tabs.gd —— 右下角的**圆盘页签选择器**
##
## ★★ 2026.11.19（用户口径）：页签永远只有 5 个，不再按选中对象增减：
##   · 左上扇区 = 单位      · 右上扇区 = 将领
##   · 左下扇区 = 建筑      · 右下扇区 = 科技
##   · 中心圆   = X（收起手牌 + 取消全部选中；再点一次恢复）
##
## 形状参考「圆环分四象限 + 中心圆」：扇区沿 12 / 3 / 6 / 9 点方向切开。
## 选中某个扇区时，它**沿对角线向外凸起**并填金色；中心 X 选中时中心圆填金。
## 圆盘整体贴屏幕右下角（原页签位置），允许向上扩出旧的 235×94 页签框。
##
## 交互：
##   · 鼠标 / 触摸按到扇区（按角度 + 半径判定）→ 切页；
##   · 悬停扇区会给一层浅金提示；
##   · 键鼠 Tab 切页仍走 `cycle_page()`（X 不参与循环）。
##
## 本控件仍然负责「记当前页 / 把点击抛出去」，内容页由 hud 组装。
extends Control

signal page_changed(page: String)

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 页 id（也是给 hud 用的常量；中文标签在 LABELS 里）
const PAGE_ORDER := "order"       ## 兼容旧引用；圆盘上不再有「操作」页
const PAGE_UNIT := "unit"
const PAGE_BUILD := "build"
const PAGE_GENERAL := "general"
const PAGE_RECRUIT := "recruit"   ## 兼容旧引用；圆盘上不再有「招募」页
const PAGE_TECH := "tech"
const PAGE_CLOSE := "close"

const LABELS := {
	PAGE_ORDER: "操作",
	PAGE_UNIT: "单位",
	PAGE_BUILD: "建筑",
	PAGE_GENERAL: "将领",
	PAGE_RECRUIT: "招募",
	PAGE_TECH: "科技",
	PAGE_CLOSE: "X",
}

## 圆盘永远按这个顺序画 / 命中：左上、右上、左下、右下、中心。
const SECTOR_ORDER := [PAGE_UNIT, PAGE_GENERAL, PAGE_BUILD, PAGE_TECH, PAGE_CLOSE]
const SECTOR_DIRS := {
	PAGE_UNIT: Vector2(-1.0, -1.0),
	PAGE_GENERAL: Vector2(1.0, -1.0),
	PAGE_BUILD: Vector2(-1.0, 1.0),
	PAGE_TECH: Vector2(1.0, 1.0),
	PAGE_CLOSE: Vector2.ZERO,
}
const BULGE := 9.0                # 选中扇区向外凸起的像素
const RING_MARGIN := 6.0
const INNER_RATIO := 0.30         # 中心圆半径 / 外圈半径（2026.11.19 缩小）
const LIFT_SEC := 0.24


## 只用于 `button_at()` / 测试的占位按钮：不参与真实输入（父控件按角度命中）。
class DialButton:
	extends Button

	func _init() -> void:
		text = ""
		flat = true
		focus_mode = Control.FOCUS_NONE
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_theme_stylebox_override("normal", StyleBoxEmpty.new())
		add_theme_stylebox_override("hover", StyleBoxEmpty.new())
		add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
		add_theme_stylebox_override("focus", StyleBoxEmpty.new())


var _dial_buttons: Array[Button] = []
var _labels: Array[Label] = []
var _chars: Array[String] = []
var _font: Font = null

## 当前显示的页（空 = 整块隐藏）。圆盘永远有 5 个扇区，所以正常情况下恒为 5。
var _page_ids: Array[String] = []
var _page: String = ""
var _hover_index: int = -1
## 每个扇区当前的「弹起进度」0..1（选中 = 1，取消 = 0）。中心 X 不用。
var _sector_lift: Array[float] = []
var _sector_tweens: Array = []
## 中心 X 的弹起程度（0=常驻，1=选中 X）与点击波纹（1 → 0）。
var _center_lift: float = 0.0
var _center_tween = null
var _center_pulse: float = 0.0
var _primer_done: bool = false

## 教程引导：让某一页签呼吸高亮；空串 = 关掉。
var _attention_page: String = ""
var _attention_t: float = 0.0


func setup(p_font: Font = null) -> void:
	name = "PageTabs"
	_font = p_font
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, UiLayoutRes.TABS_RECT, true, true)

	# 透明外框：兼容旧的节点查询 / 测试（它不再承担视觉）。
	var frame := Panel.new()
	frame.name = "TabsFrame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	frame_style.set_border_width_all(0)
	frame.add_theme_stylebox_override("panel", frame_style)
	add_child(frame)

	for i in SECTOR_ORDER.size():
		var b := DialButton.new()
		b.name = "TabButton%d" % (i + 1)
		b.size = size
		b.position = Vector2.ZERO
		b.pressed.connect(_on_tab_pressed.bind(i))
		add_child(b)
		_dial_buttons.append(b)

		var l := Label.new()
		l.name = "SectorLabel%d" % (i + 1)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		l.add_theme_color_override("font_color", UiStyleRes.text())
		if _font != null:
			l.add_theme_font_override("font", _font)
		l.visible = false
		add_child(l)
		_labels.append(l)
		_chars.append("")
		_sector_lift.append(0.0)
		_sector_tweens.append(null)

	mouse_exited.connect(_on_mouse_exited)
	set_pages([PAGE_BUILD])
	set_process(true)


# ------------------------------------------------------------------
# 换页 / 切页
# ------------------------------------------------------------------

## 由 hud 调用。圆盘**忽略 ids 的具体顺序**，永远显示固定 5 个扇区；
## `ids` 为空只表示「整块隐藏」（观战 / 剧本隐藏），会清空当前页。
func set_pages(ids: Array, preferred: String = "") -> void:
	if ids.is_empty():
		_page_ids.clear()
		_page = ""
		_center_lift = 0.0
		_center_pulse = 0.0
		if _center_tween != null and is_instance_valid(_center_tween) and (_center_tween as Tween).is_running():
			(_center_tween as Tween).kill()
		_center_tween = null
		for i in _sector_lift.size():
			_sector_lift[i] = 0.0
			var tw0 = _sector_tweens[i]
			if tw0 != null and is_instance_valid(tw0) and (tw0 as Tween).is_running():
				(tw0 as Tween).kill()
			_sector_tweens[i] = null
		_layout()
		queue_redraw()
		return
	_page_ids = []
	for p in SECTOR_ORDER:
		_page_ids.append(String(p))
	var want := String(preferred)
	if not SECTOR_ORDER.has(want):
		want = _page if SECTOR_ORDER.has(_page) else PAGE_BUILD
	if want == _page:
		_layout()
		queue_redraw()
		return
	_apply_page(want)
	page_changed.emit(_page)


## 切页（不在圆盘里的页一律拒掉）。同页不重复发信号。
func select_page(page: String) -> void:
	var p := String(page)
	if not SECTOR_ORDER.has(p) or p == _page:
		return
	_apply_page(p)
	page_changed.emit(_page)


## 只改视觉上的当前页，不发 `page_changed`（X 收起时用，避免递归）。
func set_page_silent(page: String) -> void:
	var p := String(page)
	if not SECTOR_ORDER.has(p):
		return
	if p == _page:
		return
	_apply_page(p)


## 切换当前页并给每个扇区起「弹起 / 回落」动画。
func _apply_page(p: String, animate: bool = true) -> void:
	_page = p
	var instant := not _primer_done or not animate
	for i in SECTOR_ORDER.size():
		if i == 4:
			continue
		var target := 1.0 if String(SECTOR_ORDER[i]) == p else 0.0
		_animate_sector(i, target, instant)
	_animate_center(1.0 if p == PAGE_CLOSE else 0.0, instant)
	_primer_done = true
	_layout()
	queue_redraw()


func _animate_sector(i: int, target: float, instant: bool) -> void:
	if i < 0 or i >= _sector_lift.size():
		return
	var old = _sector_tweens[i]
	if old != null and is_instance_valid(old) and (old as Tween).is_running():
		(old as Tween).kill()
	_sector_tweens[i] = null
	if instant or not is_inside_tree():
		_sector_lift[i] = target
		return
	var from: float = _sector_lift[i]
	if is_equal_approx(from, target):
		return
	var tw := create_tween()
	_sector_tweens[i] = tw
	var cb := func(v: float) -> void:
		if i < _sector_lift.size():
			_sector_lift[i] = v
			_layout()
			queue_redraw()
	# TRANS_BACK 让扇区「弹过头一点再落定」，取消选中时同理反向回落。
	tw.tween_method(cb, from, target, LIFT_SEC) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _animate_center(target: float, instant: bool) -> void:
	if _center_tween != null and is_instance_valid(_center_tween) \
			and (_center_tween as Tween).is_running():
		(_center_tween as Tween).kill()
	_center_tween = null
	if instant or not is_inside_tree():
		_center_lift = target
		return
	var from := _center_lift
	if is_equal_approx(from, target):
		return
	var tw := create_tween()
	_center_tween = tw
	var cb := func(v: float) -> void:
		_center_lift = v
		_layout()
		queue_redraw()
	tw.tween_method(cb, from, target, LIFT_SEC) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Tab / Shift+Tab：X 不参与循环，只在四个内容页之间转。
func cycle_page(dir: int = 1) -> bool:
	var cycle := [PAGE_BUILD, PAGE_UNIT, PAGE_GENERAL, PAGE_TECH]
	var n := cycle.size()
	var idx := cycle.find(_page)
	var next: int = 0 if idx < 0 else (idx + dir) % n
	if next < 0:
		next += n
	var target: String = cycle[next]
	if target == _page:
		return false
	select_page(target)
	return true


func _on_tab_pressed(i: int) -> void:
	if i < 0 or i >= _page_ids.size():
		return
	var p := _page_ids[i]
	if p == PAGE_CLOSE:
		# X 是开关：当前已经是 X 时再点一次也要把信号发出去（hud 会恢复手牌）。
		# ★ 中心圆自己也播一下点击波纹 + 弹起。
		_center_pulse = 1.0
		queue_redraw()
		page_changed.emit(PAGE_CLOSE)
	else:
		select_page(p)


# ------------------------------------------------------------------
# 输入：按角度 + 半径命中扇区（圆盘不能用矩形按钮）
# ------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mi := _index_at(event.position)
		if mi != _hover_index:
			_hover_index = mi
			queue_redraw()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var bi := _index_at(mb.position)
			if bi >= 0:
				_on_tab_pressed(bi)
				accept_event()
		return
	# 触摸：有的平台不模拟鼠标 -> 直接认 ScreenTouch。
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed:
			var ti := _index_at(st.position)
			if ti >= 0:
				_on_tab_pressed(ti)
				accept_event()
	elif event is InputEventScreenDrag:
		var sd := event as InputEventScreenDrag
		var di := _index_at(sd.position)
		if di != _hover_index:
			_hover_index = di
			queue_redraw()


func _on_mouse_exited() -> void:
	if _hover_index != -1:
		_hover_index = -1
		queue_redraw()


func _index_at(local_pos: Vector2) -> int:
	var c := size * 0.5
	var v := local_pos - c
	var d := v.length()
	var inner := _inner_radius()
	var outer := _outer_radius() + BULGE + 3.0
	if d <= inner * 0.92:
		return 4
	if d < inner * 0.92 or d > outer:
		return -1
	if v.x < 0.0:
		return 0 if v.y < 0.0 else 2
	return 1 if v.y < 0.0 else 3


# ------------------------------------------------------------------
# 画圆盘
# ------------------------------------------------------------------

func _outer_radius() -> float:
	return minf(size.x, size.y) * 0.5 - RING_MARGIN


func _inner_radius() -> float:
	return _outer_radius() * INNER_RATIO


func _dir_for(page: String) -> Vector2:
	return SECTOR_DIRS.get(page, Vector2.ZERO)


func _sector_points(page: String, lift: float) -> PackedVector2Array:
	var c := size * 0.5
	var outer := _outer_radius()
	var inner := _inner_radius()
	var a0 := 0.0
	var a1 := 0.0
	match page:
		PAGE_UNIT:      # 左上：π → 3π/2
			a0 = PI
			a1 = 1.5 * PI
		PAGE_GENERAL:   # 右上：3π/2 → 2π
			a0 = 1.5 * PI
			a1 = TAU
		PAGE_BUILD:     # 左下：π/2 → π
			a0 = 0.5 * PI
			a1 = PI
		PAGE_TECH:      # 右下：0 → π/2
			a0 = 0.0
			a1 = 0.5 * PI
		_:
			return PackedVector2Array()
	var pts := PackedVector2Array()
	var seg := 14
	for k in seg + 1:
		var a := lerpf(a0, a1, float(k) / float(seg))
		pts.append(c + Vector2(cos(a), sin(a)) * outer)
	for k in range(seg, -1, -1):
		var a := lerpf(a0, a1, float(k) / float(seg))
		pts.append(c + Vector2(cos(a), sin(a)) * inner)
	if lift > 0.001:
		var off := _dir_for(page) * BULGE * lift
		for i in pts.size():
			pts[i] = pts[i] + off
	return pts


func _draw() -> void:
	var c := size * 0.5
	var inner := _inner_radius()
	var bg := UiStyleRes.bg()

	# 先画四个内容扇区（选中最后画，压在其它扇区上）。
	for i in SECTOR_ORDER.size():
		var page: String = SECTOR_ORDER[i]
		if page == PAGE_CLOSE or page == _page:
			continue
		var pts := _sector_points(page, _sector_lift[i] if i < _sector_lift.size() else 0.0)
		if pts.is_empty():
			continue
		var fill := Color(bg.r, bg.g, bg.b, 0.72)
		if i == _hover_index:
			fill = UiStyleRes.bg_hover()
		draw_colored_polygon(pts, fill)
		var loop := pts
		loop.append(pts[0])
		draw_polyline(loop, UiStyleRes.line_soft(), 2.0, true)

	# 选中的扇区：凸起 + 金色填充。
	if SECTOR_ORDER.has(_page) and _page != PAGE_CLOSE:
		var si := SECTOR_ORDER.find(_page)
		var apts := _sector_points(_page, _sector_lift[si] if si < _sector_lift.size() else 1.0)
		if not apts.is_empty():
			draw_colored_polygon(apts, UiStyleRes.accent())
			var aloop := apts
			aloop.append(apts[0])
			draw_polyline(aloop, UiStyleRes.accent_bright(), 3.0, true)

	# 中心圆 = X。选中 X 时中心圆也会弹起 / 放大一点。
	var center_r := inner * (1.0 + 0.10 * _center_lift)
	var center_hover := _hover_index == 4
	var center_fill := UiStyleRes.accent() if _page == PAGE_CLOSE else (
		UiStyleRes.bg_hover() if center_hover else Color(bg.r, bg.g, bg.b, 0.92))
	var center_line := UiStyleRes.accent_bright() \
		if (_page == PAGE_CLOSE or center_hover) else UiStyleRes.line()
	# 点击 X 的扩散波纹（1 → 0），收起 / 恢复都有反馈。
	if _center_pulse > 0.001:
		var pc := UiStyleRes.accent()
		var pr := center_r + 6.0 + 16.0 * (1.0 - _center_pulse)
		draw_arc(c, pr, 0.0, TAU, 40, Color(pc.r, pc.g, pc.b, 0.85 * _center_pulse), 2.5, true)
		draw_arc(c, pr + 4.0, 0.0, TAU, 40,
			Color(pc.r, pc.g, pc.b, 0.35 * _center_pulse), 1.5, true)
	draw_circle(c, center_r, center_fill)
	draw_arc(c, center_r, 0.0, TAU, 48, center_line, 2.0, true)

	# 教程引导：对应扇区呼吸描边。
	if _attention_page != "":
		var ai := SECTOR_ORDER.find(_attention_page)
		if ai >= 0 and ai < 4:
			var ap := _sector_points(_attention_page, _sector_lift[ai] if ai < _sector_lift.size() else 0.0)
			if not ap.is_empty():
				var aloop := ap
				aloop.append(ap[0])
				var pulse := 0.2 + 0.8 * (0.5 - 0.5 * cos(_attention_t * TAU / 1.4))
				var ac := UiStyleRes.accent()
				draw_polyline(aloop, Color(ac.r, ac.g, ac.b, pulse), 4.0, true)


func _layout() -> void:
	var visible_now := not _page_ids.is_empty()
	var c := size * 0.5
	var outer := _outer_radius()
	var inner := _inner_radius()
	var mid := (inner + outer) * 0.5
	for i in _labels.size():
		var l := _labels[i]
		l.visible = visible_now
		if not visible_now:
			continue
		var page: String = _page_ids[i] if i < _page_ids.size() else SECTOR_ORDER[i]
		var text := String(LABELS.get(page, page))
		_chars[i] = text
		l.text = text
		var active := page == _page
		var lsize := Vector2(64.0, 28.0)
		var pos := c
		var fs := int(UiStyleRes.FS_BODY)
		if page == PAGE_CLOSE:
			var cs := 34.0 * (1.0 + 0.10 * _center_lift)
			lsize = Vector2(cs, cs)
			fs = int(UiStyleRes.FS_BODY) + 2 + int(round(2.0 * _center_lift))
		else:
			var dir := _dir_for(page)
			pos = c + dir.normalized() * mid
			var lift: float = _sector_lift[i] if i < _sector_lift.size() else 0.0
			pos += dir.normalized() * BULGE * lift
		l.size = lsize
		l.position = pos - lsize * 0.5
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_color",
			UiStyleRes.text_on_accent() if active else UiStyleRes.text())


func _process(dt: float) -> void:
	var dirty := false
	if _attention_page != "":
		_attention_t += maxf(0.0, dt)
		dirty = true
	if _center_pulse > 0.0:
		_center_pulse = maxf(0.0, _center_pulse - dt / 0.35)
		dirty = true
	if dirty:
		queue_redraw()


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func page() -> String:
	return _page


func page_count() -> int:
	return _page_ids.size()


func page_id_at(i: int) -> String:
	if i < 0 or i >= _page_ids.size():
		return ""
	return _page_ids[i]


func has_page(page_id: String) -> bool:
	return _page_ids.has(String(page_id))


func is_active(i: int) -> bool:
	if i < 0 or i >= _page_ids.size():
		return false
	return _page_ids[i] == _page


## 第 i 个扇区的占位按钮（真实输入由父控件按角度处理）。
func button_at(i: int) -> Button:
	if i < 0 or i >= _dial_buttons.size():
		return null
	return _dial_buttons[i]


## 第 i 个扇区的文案（越界 = ""）。
func label_at(i: int) -> String:
	if i < 0 or i >= _chars.size():
		return ""
	return _chars[i]


## 第 i 个扇区的文字 Label（圆盘每个扇区一颗 Label）。
func char_labels_at(i: int) -> Array:
	if i < 0 or i >= _labels.size() or not _labels[i].visible:
		return []
	return [_labels[i]]


func button_count() -> int:
	return _dial_buttons.size()


## 教程引导：让某一页签呼吸高亮；空串 = 关掉。不改变当前页。
func set_attention(page_id: String) -> void:
	var p := String(page_id).strip_edges()
	if p != "" and not SECTOR_ORDER.has(p):
		p = ""
	if p == _attention_page:
		return
	_attention_page = p
	_attention_t = 0.0
	queue_redraw()
