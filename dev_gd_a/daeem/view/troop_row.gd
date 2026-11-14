## troop_row.gd —— 右侧「部队 1~5」的一条将领标签（参考 art_draft/hud_balatro_direction_v2.html）
##
## 版式（V2 方向稿的「编队牌」）：
##   ┌─ 左缘内凹 ─┐                                  ┌ 右缘尖角
##   │  ◉ 序号章  将领名字                编制 5/11  ▷
##   │  （盘底血条）                                │
##   └──────────────────────────────────────────────┘
## ★ 序号章是**圆的**（方向稿的 `.seal`，51px），盘底一条 3px 血条（方向稿的
##   `inset 0 -3px var(--green)`）—— 一眼看出这员将领还剩多少血。
## ★ 牌面是「错角编队牌」：左缘中点内凹、右缘中点成尖，下面还压着 3px 牌厚
##   （方向稿的 `box-shadow: 0 5px 0 #0b1116`）⇒ 一列牌像一叠摊开的卡片。
## ★★ 未选中的牌**左缘错位**（方向稿 `margin-left: 14 / 25`）：单数行缩进多一点，
##   选中的那张贴齐左缘 ⇒ 选谁谁的牌往左探出来（`_plate_inset()`）。
##   悬停时从缩进位置滑出（由 `_glow` 驱动），所以「手指扫过一列」是连着的。
##
## ★★ 金色是**左暖右冷**的横向渐变（方向稿 `linear-gradient(110deg,#70501f,#27313a 75%)`）：
##   用顶点色多边形让 GPU 逐片元插值（不是一叠竖带 —— 那样会有明显分格），
##   暖色从左缘（序号章那一侧）往右衰减，`_glow` 控制的是**浓度**而不是宽度。
##   原点在左边之后，序号章看起来就是整张牌的光源。
##
## ★★ 右侧数字键帽的两态：
##   · 已选中 → 键帽**亮起**（实心金 + 亮描边 + 深色数字）；
##   · 已选中且鼠标悬停 → 键帽**黯淡**（深色底 + 淡金描边 + 半透明数字）；
##   · 未选中 / 空槽 → 原来的深色键帽。见 `_draw_seal()` 与 `number_key_state()`。
##
## ★★ 手机端：`set_touch_mode(true)` 后整行鼠标穿透 —— 触摸手势由
##   `squad_panel.handle_touch()` 统一路由，避免同一次触摸被「模拟鼠标」再点一遍。
##
## ★ 继承 Button 是为了保留 `pressed` 信号与 `mouse_entered/exited`，
##   HUD / 测试仍然可以直接 `emit_signal("pressed")`。
extends Button

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")

const FADE_SEC := 0.18
## 牌形（方向稿 `clip-path: polygon(0 0,94% 0,100% 50%,94% 100%,0 100%,3% 50%)`）
const NOTCH := 7.0            # 左缘中点的内凹深度（3% × 238 ≈ 7）
const CHEV := 13.0            # 右缘尖角从肩部探出的长度（100% − 94% ≈ 14）
const LIFT := 3.0             # 牌厚：牌面下方露出的那一条（方向稿是 5，这里留 3 给行距）
## 未选中牌的左缘缩进：单数行多一点（方向稿 `.formation:nth-child(even)` 是 25）
const STAGGER_A := 10.0
const STAGGER_B := 20.0

const NAME_FS := 14
const FORM_FS := 11
const NUM_FS := 22
## ★★ 「跟随眼睛」画在牌的左缘内侧；开启跟随时把文字区右移，避免压住长名字。
const FOLLOW_EYE_X := 6.0
const FOLLOW_EYE_W := 12.0
const FOLLOW_TEXT_GAP := 5.0
## 文字区右端要让开右缘的尖角：从牌宽里减掉这么多
const TEXT_RIGHT_PAD := 17.0

var _font: Font = null
var _slot: int = 0
var _number_text: String = "1"
var _leader_name: String = ""
var _formation_text: String = ""
## 牌右下角那个大字（方向稿 `.digit`）：这支部队有几个人。
var _digit: String = ""
var _filled: bool = false
var _selected: bool = false
var _hover: bool = false
## ★★ 正在跟随这支部队（长按标签 / 数字键触发）：
##   牌左缘画一个眼睛标志；跟随结束（手动动镜头 / 目标阵亡）后刷新会清掉。
var _following: bool = false
## 这员将领的血量比例（画在序号章底部那一条 3px 上）
var _hp: float = 1.0
## ★★ 手机端：行**不吃鼠标**（触摸由 squad_panel.handle_touch 统一路由）。
##   不吃的话 `emulate_mouse_from_touch` 会再触发一次 Button.pressed，同一次触摸被处理两遍。
var _touch_mode: bool = false
var _glow: float = 0.0
var _target: float = 0.0

var _sig: String = ""


func setup(p_font: Font, slot: int, cfg = null) -> void:
	_font = p_font
	_slot = slot
	name = "SquadSlot%d" % (slot + 1)
	focus_mode = Control.FOCUS_NONE
	flat = true
	# ★ 牌厚 / 外泛光要画到行框**外面**（下面那一条 3px）⇒ 不能裁。
	clip_contents = false
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
## @param digit 牌右下角那个大字（方向稿 `.digit`）：这里放「这支部队有几个人」。
func set_data(number_text: String, leader_name: String, formation_text: String,
		filled: bool, digit: String = "") -> void:
	var sig := "%s|%s|%s|%s|%s" % [number_text, leader_name, formation_text,
		str(filled), digit]
	if sig == _sig:
		return
	_sig = sig
	_number_text = number_text
	_leader_name = leader_name
	_formation_text = formation_text
	_digit = digit
	_filled = filled
	mouse_filter = Control.MOUSE_FILTER_STOP if filled else Control.MOUSE_FILTER_IGNORE
	if _touch_mode:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sync_glow_target()
	queue_redraw()


## 序号章盘底那条血条的比例（0..1）。空槽 / 阵亡槽传 0 就只剩空槽底。
func set_hp(ratio: float) -> void:
	var r := clampf(ratio, 0.0, 1.0)
	if is_equal_approx(r, _hp):
		return
	_hp = r
	queue_redraw()


## 手机端：整行改成鼠标穿透（触摸由 squad_panel 的 `handle_touch` 统一处理）。
func set_touch_mode(on: bool) -> void:
	_touch_mode = on
	mouse_filter = Control.MOUSE_FILTER_IGNORE if (on or not _filled) \
		else Control.MOUSE_FILTER_STOP
	if on:
		_hover = false


func set_selected(on: bool) -> void:
	if _selected == on:
		return
	_selected = on
	_sync_glow_target()
	queue_redraw()


## 跟随态：牌左缘显示 / 隐藏眼睛标志。
func set_following(on: bool) -> void:
	if _following == on:
		return
	_following = on
	queue_redraw()


func is_row_following() -> bool:
	return _following


## 悬停态（鼠标进入 / 离开调它；测试也直接调）。
func set_hover(on: bool) -> void:
	if _hover == on:
		return
	_hover = on
	_sync_glow_target()
	queue_redraw()


func is_row_hovered() -> bool:
	return _hover


## 数字键帽的显示状态（给测试断言）：
##   "empty"  = 空槽 / 阵亡（整行压暗）
##   "lit"    = 已选中且未悬停（键帽亮起）
##   "dim"    = 已选中且悬停（键帽黯淡）
##   "normal" = 未选中
func number_key_state() -> String:
	if not _filled:
		return "empty"
	if _selected:
		return "dim" if _hover else "lit"
	return "normal"


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


## 牌面当前的左缘缩进（0 = 贴齐左边；越大 = 这张牌越往右缩）。
## ★ 选中 ⇒ 0（探出来）；未选中 ⇒ 按行号交错；悬停时往 0 滑（`_glow` 驱动）。
func plate_inset() -> float:
	if _selected:
		return 0.0
	var base: float = STAGGER_B if (_slot % 2) == 1 else STAGGER_A
	return maxf(0.0, base * (1.0 - _glow))


func _sync_glow_target() -> void:
	_target = 1.0 if (_selected or _hover) and _filled else 0.0


func _on_mouse_entered() -> void:
	set_hover(true)


func _on_mouse_exited() -> void:
	set_hover(false)


func _process(dt: float) -> void:
	if is_equal_approx(_glow, _target):
		return
	if not ThemeRes.animations_enabled() or FADE_SEC <= 0.0:
		_glow = _target
	else:
		_glow = move_toward(_glow, _target, dt / FADE_SEC)
	queue_redraw()


# ------------------------------------------------------------------
# 绘制
# ------------------------------------------------------------------

func _draw() -> void:
	var inset := plate_inset()
	var w: float = maxf(24.0, size.x - inset)
	var h: float = size.y
	# 整张牌（含内部文字）一起右移，缩进才不会把序号章挤出牌面。
	draw_set_transform(Vector2(inset, 0.0))
	_draw_plate(w, h)
	_draw_seal(h)
	_draw_texts(w, h)
	draw_set_transform(Vector2.ZERO)


## 错角编队牌的六个角（左缘内凹 NOTCH、右缘尖角 CHEV）。
## `off` = 整块下移的量（画「牌厚」那一层用）。
static func _shape(xl: float, xr: float, top: float, bot: float,
		off: float = 0.0) -> PackedVector2Array:
	var mid := (top + bot) * 0.5 + off
	return PackedVector2Array([
		Vector2(xl + notch_for(xl), top + off), Vector2(xr - CHEV, top + off),
		Vector2(xr, mid), Vector2(xr - CHEV, bot + off),
		Vector2(xl + notch_for(xl), bot + off), Vector2(xl, mid),
	])


## 左缘内凹的深度：贴齐左边时 7px；整张牌右移之后按比例收一点，
## 免得缩进把牌头收成一个斜三角。
static func notch_for(xl: float) -> float:
	return NOTCH if xl <= 0.5 else minf(NOTCH, xl * 0.5 + 2.0)


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(pts)
	if not pts.is_empty():
		out.append(pts[0])
	return out


func _draw_plate(w: float, h: float) -> void:
	# ① 牌厚：同一块牌往下压 LIFT，只露出底边那一条（方向稿的 `box-shadow: 0 5px 0`）
	var thick := _shape(0.0, w, 0.0, h, LIFT)
	draw_colored_polygon(thick, Color(0.012, 0.018, 0.026, 1.0))
	draw_polyline(_closed(thick), Color(0.0, 0.0, 0.0, 0.55), 1.0, true)

	# ② 牌面：顶点色多边形 ⇒ 左暖右冷的连续横向渐变
	var shape := _shape(0.0, w, 0.0, h)
	var cols := PackedColorArray()
	for p in shape:
		cols.append(_plate_color(p.x, w))
	draw_polygon(shape, cols)

	# ③ 选中：外侧一圈淡金晕（方向稿 `0 0 12px #f2b54466`）
	if _selected:
		draw_polyline(shape, Color(UiStyleRes.accent(), 0.06), 7.0, true)
		draw_polyline(shape, Color(UiStyleRes.accent(), 0.10), 4.0, true)

	# ④ 描边：选中 = 2px 亮金；悬停 = 1.5px 金；其余 = 1px 灰线
	var rim: Color = UiStyleRes.line_soft()
	var rim_w := 1.0
	if _selected:
		rim = UiStyleRes.accent_bright()
		rim_w = 2.0
	elif _hover:
		rim = UiStyleRes.accent()
		rim_w = 1.5
	draw_polyline(_shape(0.5, w - 0.5, 0.5, h - 0.5), rim, rim_w, true)

	# ⑤ 选中牌内再压一圈 1px 金线（方向稿 `inset 0 0 0 3px #f2b54433`）
	if _selected:
		draw_polyline(_shape(5.0, w - 5.0, 6.0, h - 6.0),
			Color(UiStyleRes.accent(), 0.22), 1.0, true)

	# ★★ 2026.11.14（用户口径）：「将领标签右侧的竖线可以去掉」——
	#   原来这里画的是右缘尖角前的那条「肩线」（`x = w − CHEV + 1` 的 1px 竖线）。
	#   ⚠️ 别把它加回来：那条线在牌面渐变上只是一道突兀的断口，
	#     右缘的尖角本身已经够表达「牌头」了（形状由 `_shape()` 负责）。


## 牌面在 x 处的颜色：左端（t=0）暖，往右按 `pow(1-t,1.6)` 衰减回底色。
##   · 选中：暖色最浓（0.58 的金混进去 ≈ 方向稿的 #70501f）；
##   · 悬停：暖色淡（0.18 × `_glow`）—— 比选中明显弱一档，不然两张牌分不出主次；
##   · 空槽 / 未选中：只剩底色，右端略亮一点点（方向稿 #101820 → #202b35）。
func _plate_color(x: float, w: float) -> Color:
	var t := clampf(x / maxf(1.0, w), 0.0, 1.0)
	var warm := 0.58 if _selected else 0.18 * _glow
	if not _filled:
		warm *= 0.35
	var c := UiStyleRes.bg().lerp(UiStyleRes.accent(), warm * pow(1.0 - t, 1.6))
	c = c.lerp(UiStyleRes.text_dim(), 0.05 * t)
	c.a = 0.94
	return c


## 序号章（方向稿的 `.seal`）：圆形盘面 + 双环 + 盘底 3px 血条。
func _draw_seal(h: float) -> void:
	var s: float = UiLayoutRes.SQUAD_NUM_SIZE
	var cx := UiLayoutRes.SQUAD_NUM_X + s * 0.5
	var cy := h * 0.5
	var r := s * 0.5
	var center := Vector2(cx, cy)
	var state := number_key_state()

	var disc := Color(0.05, 0.068, 0.09, 1.0)
	var ring: Color = Color(UiStyleRes.accent(), 0.8)
	var num_col: Color = UiStyleRes.text()
	if state == "lit":
		disc = UiStyleRes.accent()
		ring = UiStyleRes.accent_bright()
		num_col = UiStyleRes.text_on_accent()
	elif state == "dim":
		disc = Color(0.075, 0.095, 0.12, 1.0)
		ring = Color(UiStyleRes.accent(), 0.45)
		num_col = Color(UiStyleRes.text(), 0.62)
	elif state == "empty":
		num_col.a = 0.40
		ring = Color(UiStyleRes.accent(), 0.5)

	# 外圈一道更暗的环：让金环在亮底图上有边界（不然只是「亮一点的圆」）
	draw_circle(center, r, Color(0.0, 0.0, 0.0, 0.55))
	draw_circle(center, r - 1.5, disc)
	draw_arc(center, r - 1.5, 0.0, TAU, 48, ring, 2.0, true)
	# 亮起时再补一圈内环：实心金盘上多一道暗环才有「压铸」的层次
	if state == "lit":
		draw_arc(center, r - 5.0, 0.0, TAU, 48,
			Color(UiStyleRes.text_on_accent(), 0.22), 1.0, true)

	# 盘底血条：底色是盘面自己压暗的一档，填充色按血量三档（绿 / 黄 / 红）
	var bw := r * 1.24
	var bx := cx - bw * 0.5
	var by := cy + r - 9.0
	draw_rect(Rect2(bx, by, bw, 3.0), Color(0.0, 0.0, 0.0, 0.5), true)
	if _filled and _hp > 0.0:
		draw_rect(Rect2(bx, by, bw * _hp, 3.0), UiStyleRes.hp_bar_color(_hp), true)

	# 数字：贴盘心（baseline 在中心下方约 36% 字高）
	draw_string(_text_font(), Vector2(cx - r, cy + NUM_FS * 0.36), _number_text,
		HORIZONTAL_ALIGNMENT_CENTER, s, NUM_FS, num_col)


func _draw_texts(w: float, h: float) -> void:
	var f := _text_font()
	var text_x: float = UiLayoutRes.SQUAD_TEXT_X
	var text_w: float = maxf(24.0, w - text_x - TEXT_RIGHT_PAD)
	# ★ 跟随中：最左缘画眼睛，文字区让出它的位置
	if _following and _filled:
		text_x = FOLLOW_EYE_X + FOLLOW_EYE_W + FOLLOW_TEXT_GAP
		text_w = maxf(24.0, w - text_x - TEXT_RIGHT_PAD)
		_draw_follow_eye(h)
	# ★ 有右下角大字时再让一截：两行文案不该压到那个数上。
	if _digit != "":
		text_w = maxf(24.0, text_w - 20.0)

	var name_col: Color = UiStyleRes.text()
	var form_col: Color = UiStyleRes.text_dim()
	if not _filled:
		name_col.a = 0.42
		form_col.a = 0.32

	var name_text := _leader_name if _leader_name != "" else "…"
	var form_text := _formation_text if _formation_text != "" else "--/--"
	name_text = _fit(f, name_text, text_w, NAME_FS)
	form_text = _fit(f, form_text, text_w, FORM_FS)
	# ★ 两行**按行高居中**（行高是手机端可调的触摸高度，见 ui_layout.SQUAD_ROW_H）
	var mid := h * 0.5
	draw_string(f, Vector2(text_x, mid - 5.0), name_text,
		HORIZONTAL_ALIGNMENT_LEFT, text_w, NAME_FS, name_col)
	draw_string(f, Vector2(text_x, mid + 14.0), form_text,
		HORIZONTAL_ALIGNMENT_LEFT, text_w, FORM_FS, form_col)

	# 右下角的大字（方向稿 `.digit`）：编制人数。位置与字号都照方向稿 ——
	# 数字块在左边、这个数在右边，一张牌两端各有一个数，中间才是名字。
	if _digit != "":
		var dw := f.get_string_size(_digit, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var dcol: Color = Color(UiStyleRes.accent_bright(), 0.85)
		if _selected:
			dcol = UiStyleRes.accent_bright()
		elif not _filled:
			dcol.a *= 0.4
		draw_string(f, Vector2(w - CHEV - 8.0 - dw, h - 11.0), _digit,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 13, dcol)


func _text_font() -> Font:
	if _font != null:
		return _font
	return get_theme_default_font()


## 「跟随中」的眼睛标志（画在牌左缘内侧）：
##   杏仁形轮廓（上下两条对称曲线）+ 实心瞳孔，全部用自绘图元 —— 不依赖字体里有没有眼睛字形。
##   颜色用亮一档的金（`accent_bright`），在深色牌底与金色泛光上都看得清。
func _draw_follow_eye(h: float) -> void:
	var cx: float = FOLLOW_EYE_X + FOLLOW_EYE_W * 0.5
	var cy: float = h * 0.5
	var rx: float = FOLLOW_EYE_W * 0.5
	var ry: float = FOLLOW_EYE_W * 0.28
	var col: Color = UiStyleRes.accent_bright()
	var steps := 8
	var pts := PackedVector2Array()
	# 上眼睑（左 → 右）
	for i in steps + 1:
		var t: float = float(i) / float(steps)
		pts.append(Vector2(cx - rx + 2.0 * rx * t, cy - ry * sin(PI * t)))
	# 下眼睑（右 → 左；收尾点 = 左上角，闭合成杏仁形）
	for i in range(steps - 1, 0, -1):
		var t: float = float(i) / float(steps)
		pts.append(Vector2(cx - rx + 2.0 * rx * t, cy + ry * sin(PI * t)))
	pts.append(pts[0])
	draw_polyline(pts, col, 1.3, true)
	draw_circle(Vector2(cx, cy), maxf(1.2, ry * 0.55), col)


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
