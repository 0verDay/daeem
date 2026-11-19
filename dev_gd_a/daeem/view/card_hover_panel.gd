## card_hover_panel.gd —— **手牌悬停面板**：鼠标停在某张手牌 / 科技牌上时，
## 在那张牌的**左侧或右侧**浮出来的一块说明。
##
## ★★ 需求原话（2026.11.19）：「为卡牌添加悬停面板，位置为卡牌左侧或右侧或左右都有；
##   悬停时可以遮挡其他卡牌，但不可遮挡其他卡牌的悬停逻辑」；
##   内容按卡类分四档：单位（名称 + 造价 + 标签 + 简述）/ 建筑（名称 + 造价 + 简述）/
##   将领（名称 + 造价 + 特性 + 简述）/ 科技（名称 + 简述）。
##
## ★ 几何：
##   · 宽固定 300（`UiLayoutRes.CARD_HOVER_PANEL_W`），高按内容 90~220；
##   · 位置由 `ui_layout.card_hover_panel_position()` 定：卡在左半边 → 放左侧，
##     右半边 → 放右侧；竖直方向对齐牌的**视觉中心**，再夹进屏幕；
##   · 与牌留 26px 净距，面板的背牌 / 投影 / 金色菱形都在这段缝里
##     ⇒ **永远不盖住被悬停的那张牌**（只允许盖别的牌）。
##
## ★ 为什么纯自绘：牌面要复用详情牌那一套（切角 / 两层错位背牌 / 竖向渐变 /
##   2px 黄铜边 / 内圈金线，见 `detail_v2.draw_plate`），用控件拼会对不齐。
##
## ★ 出现时机**不在这里**：hud 会先等牌把抬起 / 放大播完（`CARD_HOVER_SHOW_DELAY`），
##   再调 `show_card()`；本控件只负责「淡入 + 从卡那侧滑出 10px」这一段。
##
## ★ 为什么 `MOUSE_FILTER_IGNORE`：它只是「画出来的一块说明」。一旦吃鼠标，
##   被它盖住的那张牌就再也收不到 `mouse_entered` —— 正是需求里
##   「不可遮挡其他卡牌的悬停逻辑」要避免的。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const UiTextRes = preload("res://view/ui_text.gd")
const DetailV2Res = preload("res://view/detail_v2.gd")
const ThemeRes = preload("res://view/theme.gd")

const PAD := 15.0
## 抬头：卡名基线 / 金线 y
const NAME_BASE := 31.0
const RULE_Y := 45.0
const NAME_FS := 19
## 类别胶囊（近战·骑兵 / 建筑 / 将领 / 科技）
const TAG_FS := 10
const TAG_TRACK := 0.8
const TAG_H := 18.0
## 造价格：标签 9 号带字距 + 数值 17 号亮金
const COST_BASE := 72.0
const COST_LABEL_FS := 9
const COST_LABEL_TRACK := 1.6
const COST_VALUE_FS := 17
const DIVIDER_Y := 93.0
## 说明段落
const DESC_FS := 12
const DESC_LH := 18.0
const DESC_MAX_LINES := 6
const BOTTOM_PAD := 14.0
## 特性胶囊（只有将领有）
const CAP_FS := 9
const CAP_TRACK := 1.6
const CHIP_FS := 10
const CHIP_H := 19.0
const CHIP_GAP := 6.0
const CHIP_PAD_X := 7.5
## 置灰原因（warn 红，贴底一行）
const NOTE_FS := 11
## 指向卡牌的小菱形
const CONNECTOR_R := 5.0
const CONNECTOR_OUT := 11.0
## 将领特性面板（右侧那块）的行排版：特性名 13 号 + 说明 11 号
const ROW_NAME_FS := 13
const ROW_DESC_FS := 11
const ROW_DESC_LH := 15.0
## 特性面板的小标题（「将 军 特 性」那一行，替代大卡名）
const ROWS_CAP_FS := 10
const ROWS_CAP_TRACK := 2.0
const ROWS_CAP_Y := 25.0
const ROWS_RULE_Y := 37.0
const ROWS_TOP := 52.0

var _font: Font = null
## 现在这块面板上写着什么（全部由 hud 喂进来，本控件不认识任何玩法概念）：
##   { name, tag, cost: [{label, value}], traits: [String], desc, note, rows }
## `rows` = 将领特性面板的条目 `[{name, desc}]`（有它时走「特性列表面板」那套排版）。
var _data: Dictionary = {}
## 被说明的那张牌的**最终屏幕矩形**（悬停姿势）——菱形指向它的视觉中心。
var _card_rect := Rect2()
## 面板在卡的哪一侧：-1 = 左侧（主面板），+1 = 右侧（将领特性面板）。
var _side := -1
## 面板宽度：主面板 300 / 特性面板 236（`setup` 时定死）。
var _panel_w := UiLayoutRes.CARD_HOVER_PANEL_W
var _showing: bool = false
var _tag_style: StyleBoxFlat = null
var _chip_style: StyleBoxFlat = null
## 出现动画（淡入 + 从外侧滑入 10px）；换内容时会被掐掉。
var _appear_tween: Tween = null
## 出现动画的时长 / 滑出距离。
const APPEAR_SEC := 0.14
const APPEAR_SLIDE := 10.0


func setup(p_font: Font = null, p_w: float = UiLayoutRes.CARD_HOVER_PANEL_W) -> void:
	name = "CardHoverPanel"
	# ★ 只显示、不吃鼠标：理由见文件头。
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★ 压过手牌：牌自身的 z 最高 22（命令卡 CARD_SLOTS*2+4），这里取 30。
	#   详情牌 5 / 旧的左下悬停牌 6 也都在它下面。
	z_index = 30
	# 菱形画在矩形外面 —— 不能裁。
	clip_contents = false
	_font = p_font if p_font != null else ThemeDB.fallback_font
	_panel_w = p_w
	_tag_style = _make_tag_style()
	_chip_style = _make_chip_style()
	# 宽度是固定的（高度等 `show_card` 按内容算）—— 这样 `_draw` / 测试随时读得到宽度。
	size = Vector2(_panel_w, 0.0)
	clear()


# ------------------------------------------------------------------
# 内容（由 hud 喂）
# ------------------------------------------------------------------

## 显示一张卡的悬停说明。
##   @param d         见 `_data` 的字段说明
##   @param card_rect 这张牌**悬停姿势**的屏幕矩形（`command_card.cell_pose_rect(i, true)`）
##   @param view_size 当前视口尺寸（定位 / 夹边用）
##   @param side      -1 = 牌的左侧（主面板）/ +1 = 牌的右侧（将领特性面板）
func show_card(d: Dictionary, card_rect: Rect2, view_size: Vector2,
		side: int = -1) -> void:
	var was_visible: bool = _showing
	_kill_appear()
	_data = d.duplicate(true)
	_card_rect = card_rect
	_side = side
	_showing = true
	size = Vector2(_panel_w, measure_height())
	var home := UiLayoutRes.card_hover_panel_position(card_rect, size.y, view_size,
		_panel_w, _side)
	visible = true
	if not was_visible and ThemeRes.animations_enabled():
		# 从**外侧**滑入 10px + 淡入：起点比落点更远离牌 ⇒ 整段动画里都不会压到原卡。
		#   （若从卡那侧滑出，起点与牌的净距只剩 16px，背牌 / 菱形会短暂探进牌里。）
		position = Vector2(home.x + float(_side) * APPEAR_SLIDE, home.y)
		modulate.a = 0.0
		_appear_tween = create_tween()
		_appear_tween.set_parallel(true)
		_appear_tween.tween_property(self, "position:x", home.x, APPEAR_SEC) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_appear_tween.tween_property(self, "modulate:a", 1.0, APPEAR_SEC)
	else:
		position = home
		modulate.a = 1.0
	queue_redraw()


## 收起来（换牌 / 换页 / 拖牌 / 鼠标移开时由 hud 调）
func clear() -> void:
	_kill_appear()
	_data = {}
	_card_rect = Rect2()
	_showing = false
	visible = false
	modulate.a = 1.0


func _kill_appear() -> void:
	if _appear_tween != null:
		if _appear_tween.is_valid():
			_appear_tween.kill()
		_appear_tween = null


# ------------------------------------------------------------------
# 没字的内容访问器（画 + 量高 + 测试都走这几个）
# ------------------------------------------------------------------

func _name() -> String:
	return String(_data.get("name", ""))


func _tag() -> String:
	return String(_data.get("tag", ""))


func _cost() -> Array:
	var v: Variant = _data.get("cost", [])
	return v if typeof(v) == TYPE_ARRAY else []


func _traits() -> Array:
	var v: Variant = _data.get("traits", [])
	return v if typeof(v) == TYPE_ARRAY else []


func _desc() -> String:
	return String(_data.get("desc", ""))


func _note() -> String:
	return String(_data.get("note", ""))


## 胶囊那一行的小标题：将领是「特 性」，大本营升级 / 建造操作是「结 果」。
func _caption() -> String:
	return String(_data.get("caption", "特 性"))


## 将领特性面板的条目 `[{name, desc}]`（空 = 普通卡说明面板）。
func _rows() -> Array:
	var v: Variant = _data.get("rows", [])
	return v if typeof(v) == TYPE_ARRAY else []


func _desc_lines() -> PackedStringArray:
	if _font == null or _desc().strip_edges() == "":
		return PackedStringArray()
	return UiTextRes.wrap(_font, _desc(), size.x - 2.0 * PAD, DESC_FS, DESC_MAX_LINES)


## 面板高度：内容到哪、牌就长到哪。
func measure_height() -> float:
	# ★ 特性列表面板（只有将领卡右侧那块）走另一套排版。
	if not _rows().is_empty():
		return _measure_rows()
	var y := RULE_Y
	if not _cost().is_empty():
		y = DIVIDER_Y + 10.0
	else:
		y = RULE_Y + 14.0
	y += float(_lines_of(_desc()).size()) * DESC_LH
	if not _traits().is_empty():
		y += 22.0 + CHIP_H
	if _note() != "":
		y += 20.0
	return y + BOTTOM_PAD


## 特性列表面板的高度：小标题 + 每条「名字 + 说明折行」。
func _measure_rows() -> float:
	var y := ROWS_TOP
	for row in _rows():
		var d := String((row as Dictionary).get("desc", ""))
		y += 19.0 + float(_row_desc_lines(d).size()) * ROW_DESC_LH + 8.0
	return y + 10.0


func _row_desc_lines(text: String) -> PackedStringArray:
	if _font == null or text.strip_edges() == "":
		return PackedStringArray()
	return UiTextRes.wrap(_font, text, _panel_w - 2.0 * PAD, ROW_DESC_FS, 3)


## 与 `_desc_lines()` 同一条折行规则，但宽度取当前面板宽（`show_card` 之前 size 还没定）。
func _lines_of(text: String) -> PackedStringArray:
	if _font == null or text.strip_edges() == "":
		return PackedStringArray()
	return UiTextRes.wrap(_font, text, _panel_w - 2.0 * PAD, DESC_FS, DESC_MAX_LINES)


# ------------------------------------------------------------------
# 牌面
# ------------------------------------------------------------------

func _draw() -> void:
	# 牌面与左下详情牌同一份画法（切角 / 两层背牌 / 渐变 / 黄铜边 / 内圈金线）
	DetailV2Res.draw_plate(self, size.x, size.y)
	if _font == null:
		return
	# ★ 将领特性面板（牌右侧那块）：没有卡名 / 造价，只有「小标题 + 每条特性」。
	if not _rows().is_empty():
		_draw_rows()
		return
	var w := size.x
	var inner := w - 2.0 * PAD

	# ① 卡名
	draw_string(_font, Vector2(PAD, NAME_BASE), UiTextRes.fit(_font, _name(), inner, NAME_FS),
		HORIZONTAL_ALIGNMENT_LEFT, inner, NAME_FS, UiStyleRes.text())

	# ② 类别胶囊（右对齐）
	var tag := _tag()
	if tag != "":
		var tw := UiTextRes.tracked_width(_font, tag, TAG_FS, TAG_TRACK)
		var bw := tw + 15.0
		var r := Rect2(w - PAD - bw, 15.0, bw, TAG_H)
		draw_style_box(_tag_style, r)
		UiTextRes.tracked(self, _font, Vector2(r.position.x + CHIP_PAD_X, r.position.y + 13.5),
			tag, TAG_FS, UiStyleRes.accent_bright(), TAG_TRACK)

	# ③ 金线：整条淡 + 左端 34px 亮头
	draw_line(Vector2(PAD, RULE_Y), Vector2(w - PAD, RULE_Y), Color(UiStyleRes.accent(), 0.23), 1.0)
	draw_line(Vector2(PAD, RULE_Y), Vector2(PAD + 34.0, RULE_Y),
		Color(UiStyleRes.accent(), 0.82), 1.0)

	# ④ 造价格
	var cost := _cost()
	if not cost.is_empty():
		var cx := PAD
		for i in cost.size():
			var cell: Dictionary = cost[i]
			var lbl := String(cell.get("label", ""))
			var val := String(cell.get("value", ""))
			var lw := UiTextRes.tracked(self, _font, Vector2(cx, COST_BASE), lbl,
				COST_LABEL_FS, UiStyleRes.text_faint(), COST_LABEL_TRACK)
			draw_string(_font, Vector2(cx + lw + 8.0, COST_BASE + 1.0), val,
				HORIZONTAL_ALIGNMENT_LEFT, -1, COST_VALUE_FS, UiStyleRes.accent_bright())
			cx += lw + 8.0 + _font.get_string_size(val, HORIZONTAL_ALIGNMENT_LEFT, -1,
				COST_VALUE_FS).x + 24.0
			if i < cost.size() - 1:
				draw_line(Vector2(cx - 13.0, COST_BASE - 12.0),
					Vector2(cx - 13.0, COST_BASE + 4.0), Color(UiStyleRes.line_soft(), 0.9), 1.0)
		draw_line(Vector2(PAD, DIVIDER_Y), Vector2(w - PAD, DIVIDER_Y),
			Color(UiStyleRes.line_soft(), 0.85), 1.0)

	# ⑤ 说明段落
	var lines := _desc_lines()
	var top := DIVIDER_Y + 10.0 if not cost.is_empty() else RULE_Y + 14.0
	for i in lines.size():
		draw_string(_font, Vector2(PAD, top + 12.0 + float(i) * DESC_LH), lines[i],
			HORIZONTAL_ALIGNMENT_LEFT, inner, DESC_FS, UiStyleRes.text_dim())
	var y := top + float(lines.size()) * DESC_LH

	# ⑥ 特性胶囊（将领）
	var traits := _traits()
	if not traits.is_empty():
		UiTextRes.tracked(self, _font, Vector2(PAD, y + 15.0), _caption(), CAP_FS,
			Color(UiStyleRes.text_faint(), 0.95), CAP_TRACK)
		var chy := y + 22.0
		var cx2 := PAD
		for tr in traits:
			var text := String(tr)
			if text == "":
				continue
			var tw2 := UiTextRes.tracked_width(_font, text, CHIP_FS, 0.4)
			var bw2 := minf(inner, tw2 + 15.0)
			if cx2 + bw2 > PAD + inner + 0.5:
				break
			var r2 := Rect2(cx2, chy, bw2, CHIP_H)
			draw_style_box(_chip_style, r2)
			UiTextRes.tracked(self, _font, Vector2(r2.position.x + CHIP_PAD_X, r2.position.y + 13.5),
				UiTextRes.fit(_font, text, bw2 - 2.0 * CHIP_PAD_X, CHIP_FS),
				CHIP_FS, UiStyleRes.accent_bright(), 0.4)
			cx2 += bw2 + CHIP_GAP
		y = chy + CHIP_H

	# ⑦ 置灰原因（warn 色）
	if _note() != "":
		draw_string(_font, Vector2(PAD, y + 13.0), UiTextRes.fit(_font, "· " + _note(),
			inner, NOTE_FS), HORIZONTAL_ALIGNMENT_LEFT, inner, NOTE_FS, UiStyleRes.warn())

	# ⑧ 指向卡牌的小菱形（画在牌面外，靠缝里的那 26px）
	_draw_connector()


## 将领特性面板的牌面：小标题 + 每条「特性名 / 一句说明」。
func _draw_rows() -> void:
	var w := size.x
	var inner := w - 2.0 * PAD
	# 小标题（替代大卡名 —— 这是主面板的附属块，不该抢主面板的抬头）
	UiTextRes.tracked(self, _font, Vector2(PAD, ROWS_CAP_Y), "将 领 特 性", ROWS_CAP_FS,
		Color(UiStyleRes.text_faint(), 0.95), ROWS_CAP_TRACK)
	draw_line(Vector2(PAD, ROWS_RULE_Y), Vector2(w - PAD, ROWS_RULE_Y),
		Color(UiStyleRes.accent(), 0.23), 1.0)
	draw_line(Vector2(PAD, ROWS_RULE_Y), Vector2(PAD + 34.0, ROWS_RULE_Y),
		Color(UiStyleRes.accent(), 0.82), 1.0)
	var y := ROWS_TOP
	for row in _rows():
		var nm := String((row as Dictionary).get("name", ""))
		var ds := String((row as Dictionary).get("desc", ""))
		if nm != "":
			draw_string(_font, Vector2(PAD, y + 15.0), UiTextRes.fit(_font, nm, inner, ROW_NAME_FS),
				HORIZONTAL_ALIGNMENT_LEFT, inner, ROW_NAME_FS, UiStyleRes.accent_bright())
		y += 19.0
		var lines := _row_desc_lines(ds)
		for i in lines.size():
			draw_string(_font, Vector2(PAD, y + 11.0 + float(i) * ROW_DESC_LH), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, inner, ROW_DESC_FS, UiStyleRes.text_dim())
		y += float(lines.size()) * ROW_DESC_LH + 8.0
	_draw_connector()


## 金色小菱形 + 一小段引线，指向被悬停那张牌的视觉中心。
func _draw_connector() -> void:
	if _card_rect.size == Vector2.ZERO:
		return
	var cy: float = _card_rect.get_center().y - global_position.y
	cy = clampf(cy, PAD, maxf(PAD, size.y - PAD))
	var dir := 1.0 if _side < 0 else -1.0     # 卡在右边 → 从右边缘往外画
	var edge := size.x if dir > 0.0 else 0.0
	var col := UiStyleRes.accent()
	draw_line(Vector2(edge, cy), Vector2(edge + dir * 6.0, cy), Color(col, 0.5), 1.0)
	var cx: float = edge + dir * CONNECTOR_OUT
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx, cy - CONNECTOR_R), Vector2(cx + CONNECTOR_R, cy),
		Vector2(cx, cy + CONNECTOR_R), Vector2(cx - CONNECTOR_R, cy),
	]), Color(col, 0.92))


func _make_tag_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(UiStyleRes.accent(), 0.09)
	s.border_color = Color(UiStyleRes.accent(), 0.38)
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	return s


func _make_chip_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.20, 0.16, 0.09, 0.96)
	s.border_color = Color(UiStyleRes.accent(), 0.58)
	s.set_border_width_all(1)
	return s


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

func showing() -> bool:
	return _showing


func title_text() -> String:
	return _name()


func tag_text() -> String:
	return _tag()


func cost() -> Array:
	return _cost().duplicate(true)


func traits() -> Array:
	return _traits().duplicate()


## 特性列表面板的条目数（普通卡面板 = 0）
func row_count() -> int:
	return _rows().size()


func row_name(i: int) -> String:
	if i < 0 or i >= _rows().size():
		return ""
	return String((_rows()[i] as Dictionary).get("name", ""))


func row_desc(i: int) -> String:
	if i < 0 or i >= _rows().size():
		return ""
	return String((_rows()[i] as Dictionary).get("desc", ""))


func caption_text() -> String:
	return _caption()


func paragraph_text() -> String:
	return _desc()


func note_text() -> String:
	return _note()


func side() -> int:
	return _side


func card_rect() -> Rect2:
	return _card_rect


## 面板**含装饰**的实际占位：牌身 + 背牌 / 投影（约 12px）+ 指向卡的菱形（16px）。
## ★ 测试用它断言「不压原卡」；也提醒以后改数值的人：缝隙不是白留的。
func occupied_rect() -> Rect2:
	var r := Rect2(position, size)
	var grow := UiLayoutRes.CARD_HOVER_PANEL_GAP - 2.0
	if _side < 0:
		r = r.grow_individual(0.0, 0.0, grow, 0.0)
	else:
		r = r.grow_individual(grow, 0.0, 0.0, 0.0)
	return r
