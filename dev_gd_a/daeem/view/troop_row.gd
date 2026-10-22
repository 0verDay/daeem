## troop_row.gd —— 右侧「部队 1~10」的一条将领标签（参考 art_draft/4.png）
##
## 版式（从右到左）：
##   最右竖线（泛光起点）→ 数字块（第几部队；第 10 个写 0）
##   → 灰色分隔线 → 左侧两行：将领名字 / 当前编制（当前/上限）
##
## ★ 悬停 / 选中：金色泛光**从最右竖线向左**推进（与旧版「自下而上」相反）。
##   本控件自己画，不挂 `fill_button` —— 它的渐变是竖向的，且绑定 Button.text；
##   这里要的是横向泛光 + 数字块 / 分隔线，自己画反而更简单、也不会影响别的按钮。
##
## ★★ 泛光是**连续渐变**，不是一叠竖带（用户报「有明显分格」之后改的）：
##   见 `_draw_glow()` —— 用顶点色多边形让 GPU 逐片元插值，与 `overlay_view_3d.gd`
##   里「区划中心占领触发区」的内向渐变描边同一手法。
##
## ★ 继承 Button 是为了保留 `pressed` 信号与 `mouse_entered/exited`，
##   HUD / 测试仍然可以直接 `emit_signal("pressed")`。
extends Button

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")

const FADE_SEC := 0.18
## ★★ 泛光的亮度参数（见 `_draw_glow()`）：
##   · `GLOW_ALPHA` = 贴着最右金线那一端的峰值 alpha；
##   · `GLOW_STOPS` = 亮度曲线的取样点（0 = 推进到的最左端，1 = 右缘）；
##   · `GLOW_CURVE` = 衰减指数（>1 ⇒ 越靠左越暗得越快，观感更接近光晕而不是一层平铺）。
const GLOW_ALPHA := 0.34
const GLOW_STOPS := [0.0, 0.25, 0.5, 0.75, 1.0]
const GLOW_CURVE := 1.7
const NAME_FS := 14
const FORM_FS := 12
const NUM_FS := 20

var _font: Font = null
var _slot: int = 0
var _number_text: String = "1"
var _leader_name: String = ""
var _formation_text: String = ""
var _filled: bool = false
var _selected: bool = false
var _hover: bool = false
var _glow: float = 0.0
var _target: float = 0.0

var _num_color := Color(0.10, 0.11, 0.12, 0.95)
var _row_color := Color(0.055, 0.065, 0.075, 0.72)
var _sig: String = ""


func setup(p_font: Font, slot: int, cfg = null) -> void:
	_font = p_font
	_slot = slot
	name = "SquadSlot%d" % (slot + 1)
	focus_mode = Control.FOCUS_NONE
	flat = true
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(UiLayoutRes.SQUAD_RECT.size.x, UiLayoutRes.SQUAD_ROW_H)
	size = custom_minimum_size
	add_theme_font_size_override("font_size", NAME_FS)
	# Button 自己的底纹 / 文字全部不要；内容由 `_draw()` 画。
	add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	add_theme_color_override("font_color", Color(0, 0, 0, 0))
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	set_process(true)
	queue_redraw()


## 每帧刷新时喂数据；`filled=false` = 空槽（数字仍显示，内容变淡、不可点）。
func set_data(number_text: String, leader_name: String, formation_text: String,
		filled: bool) -> void:
	var sig := "%s|%s|%s|%s" % [number_text, leader_name, formation_text, str(filled)]
	if sig == _sig:
		return
	_sig = sig
	_number_text = number_text
	_leader_name = leader_name
	_formation_text = formation_text
	_filled = filled
	mouse_filter = Control.MOUSE_FILTER_STOP if filled else Control.MOUSE_FILTER_IGNORE
	_sync_glow_target()
	queue_redraw()


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_sync_glow_target()
	queue_redraw()


func is_selected() -> bool:
	return _selected


func is_filled() -> bool:
	return _filled


func number_text() -> String:
	return _number_text


func leader_name() -> String:
	return _leader_name


func formation_text() -> String:
	return _formation_text


func glow() -> float:
	return _glow


func _sync_glow_target() -> void:
	_target = 1.0 if (_selected or _hover) and _filled else 0.0


func _on_mouse_entered() -> void:
	_hover = true
	_sync_glow_target()
	queue_redraw()


func _on_mouse_exited() -> void:
	_hover = false
	_sync_glow_target()
	queue_redraw()


func _process(dt: float) -> void:
	if is_equal_approx(_glow, _target):
		return
	if not ThemeRes.animations_enabled() or FADE_SEC <= 0.0:
		_glow = _target
	else:
		_glow = move_toward(_glow, _target, dt / FADE_SEC)
	queue_redraw()


func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	# 行底：很淡；空槽再淡一点
	var bg := _row_color
	if not _filled:
		bg.a *= 0.45
	draw_rect(Rect2(0, 0, w, h), bg, true)
	# 行与行之间一条极淡的分隔
	draw_line(Vector2(0, h - 1), Vector2(w, h - 1),
		Color(UiStyleRes.line_soft(), 0.35), 1.0)

	# ① 泛光：从最右竖线向左推进
	if _glow > 0.001 and _filled:
		_draw_glow(w, h)

	# ② 最右竖线（泛光起点）
	var edge := UiLayoutRes.SQUAD_EDGE_X
	var edge_col := UiStyleRes.accent() if (_selected or _hover) else UiStyleRes.accent_dim()
	draw_rect(Rect2(edge, 5.0, 2.0, h - 10.0), edge_col, true)
	if _glow > 0.001:
		draw_rect(Rect2(edge - 2.0, 5.0, 1.0, h - 10.0),
			Color(edge_col, 0.35 * _glow), true)

	# ③ 数字块
	var nr := Rect2(UiLayoutRes.SQUAD_NUM_X, (h - UiLayoutRes.SQUAD_NUM_SIZE) * 0.5,
		UiLayoutRes.SQUAD_NUM_SIZE, UiLayoutRes.SQUAD_NUM_SIZE)
	draw_rect(nr, _num_color, true)
	draw_rect(nr, Color(UiStyleRes.line_soft(), 0.75), false, 1.0)

	# ④ 灰色分隔线
	draw_line(Vector2(UiLayoutRes.SQUAD_DIVIDER_X, 7.0),
		Vector2(UiLayoutRes.SQUAD_DIVIDER_X, h - 7.0),
		Color(UiStyleRes.text_faint(), 0.55), 1.0)

	var f: Font = _font if _font != null else get_theme_default_font()
	if f == null:
		return
	var name_col: Color = UiStyleRes.text()
	var form_col: Color = UiStyleRes.text_dim()
	if not _filled:
		name_col.a = 0.40
		form_col.a = 0.30

	var name_text := _leader_name if _leader_name != "" else "…"
	var form_text := _formation_text if _formation_text != "" else "--/--"
	name_text = _fit(f, name_text, UiLayoutRes.SQUAD_TEXT_W, NAME_FS)
	form_text = _fit(f, form_text, UiLayoutRes.SQUAD_TEXT_W, FORM_FS)
	# 名字与编制都**右对齐**（右缘落在灰线左边），与数字块形成一条整齐的竖边。
	draw_string(f, Vector2(UiLayoutRes.SQUAD_TEXT_X, 22.0), name_text,
		HORIZONTAL_ALIGNMENT_RIGHT, UiLayoutRes.SQUAD_TEXT_W, NAME_FS, name_col)
	draw_string(f, Vector2(UiLayoutRes.SQUAD_TEXT_X, 42.0), form_text,
		HORIZONTAL_ALIGNMENT_RIGHT, UiLayoutRes.SQUAD_TEXT_W, FORM_FS, form_col)

	# 数字（贴数字块中心）：泛光只改底板/右缘，**不把白字改成黑字**。
	var num_col: Color = UiStyleRes.text()
	if not _filled:
		num_col.a = 0.40
	draw_string(f, Vector2(nr.position.x, nr.position.y + 31.0), _number_text,
		HORIZONTAL_ALIGNMENT_CENTER, nr.size.x, NUM_FS, num_col)


## 金色泛光：从最右竖线向左推进的**连续横向渐变**（右强左弱）。
##
## ★★ why not 「14 条竖带」：每条竖带是一块**同透明度**的矩形，带与带之间是硬边 ——
##   屏幕上就是十几级台阶（用户报的「明显的分格」）。这里改成**顶点色多边形**
##   （与 `overlay_view_3d.gd` 里占领触发区描边的 `draw_polygon(pts, colors)` 同一手法）：
##   三角形内的顶点色由 GPU **逐片元插值**，颜色连续，没有台阶。
## ★ 分段（`GLOW_STOPS`）只用来表达**非线性亮度曲线**；相邻两段在接缝处共用同一个
##   端点颜色 ⇒ 接缝既没有色差、也没有缝（两段在 x 上首尾相接，不会叠加两层 alpha）。
## ★ 推进动画照旧：`_glow` 0→1 时，整条渐变从右缘的 0 宽长到满宽（`span`）。
func _draw_glow(w: float, h: float) -> void:
	var span: float = w * _glow
	if span <= 0.5:
		return
	var base := UiStyleRes.accent()
	var x0: float = w - span
	for i in GLOW_STOPS.size() - 1:
		var t0: float = GLOW_STOPS[i]
		var t1: float = GLOW_STOPS[i + 1]
		var xa: float = x0 + span * t0
		var xb: float = x0 + span * t1
		var ca := Color(base, _glow_alpha_at(t0))
		var cb := Color(base, _glow_alpha_at(t1))
		draw_polygon(PackedVector2Array([
			Vector2(xa, 1.0), Vector2(xb, 1.0),
			Vector2(xb, h - 1.0), Vector2(xa, h - 1.0),
		]), PackedColorArray([ca, cb, cb, ca]))


## 泛光在「离右缘 t（0..1）」处的 alpha：`t = 1`（金线那一端）最亮，往左按曲线衰减到 0。
static func _glow_alpha_at(t: float) -> float:
	return GLOW_ALPHA * pow(clampf(t, 0.0, 1.0), GLOW_CURVE)


## 单行裁剪：宽度不够时截断并补「…」（与 detail_panel 的 _clip_text 同一个目的）。
func _fit(f: Font, text: String, max_w: float, fs: int) -> String:
	if f == null or max_w <= 0.0:
		return text
	if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
		return text
	var s := text
	while s.length() > 1:
		s = s.substr(0, s.length() - 1)
		if f.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= max_w:
			return s + "…"
	return "…"
