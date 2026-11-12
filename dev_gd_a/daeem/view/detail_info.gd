## detail_info.gd —— 左下角详情牌的**上半**：头像 / 名字 / 副标题 / 三格数值
##
## 版式照 art_draft/hud_balatro_direction_v2.html 的 `.hero-head` + `.hero-stats`：
##
##   ┌ 头像（五边形裁角） 名字（18）             编制 5/11 ┐   ← 右侧小徽标
##   │  ▭ 底部血条        副标题（11 / 次要色）            │
##   └────────────────────────────────────────────────────┘
##   ┌──────────┬──────────┬──────────┐
##   │ 编 制    │ 血 量    │ 攻 击    │   ← 三格：9 号字带字距的标题 + 18 号数值
##   │ 5/11     │ 92%      │ 12       │      第一格数值用绿色（方向稿 `.hero-stat:first-child b`）
##   └──────────┴──────────┴──────────┘
##
## ★ 多队态（只显示头部）时高度会被压到 ~88，数值三格自动不画（见 `_draw()`）。
## ★ 这里只**画**，数值由 hud 组装好递进来（`set_stats()`）—— 与旧版 `detail_info`
##   「只排版、不解释数据」的分工一致。
extends Control

const UiStyleRes = preload("res://view/ui_style.gd")
const UiTextRes = preload("res://view/ui_text.gd")

const PORTRAIT := Rect2(14.0, 10.0, 63.0, 69.0)
const TEXT_X := 89.0
const TITLE_FS := 18
const SUB_FS := 11
const BADGE_FS := 10
const BADGE_TRACK := 1.1
const STAT_FS := 18
const STAT_LABEL_FS := 9
const STAT_LABEL_TRACK := 1.4
## 头部底边那条金线（方向稿 `.hero-head{border-bottom}`）的 y（相对本控件）
const HEAD_RULE_Y := 88.0

var _font: Font = null
var _icon_text := ""
var _title := ""
var _subtitle := ""
var _badge := ""
var _hp_ratio := 1.0
var _show_hp := false
var _stats: Array = []


func setup(p_font: Font = null) -> void:
	_font = p_font
	name = "DetailInfo"
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_header(icon_text: String, title: String, subtitle: String,
		hp_ratio: float = 1.0, show_hp: bool = false, badge: String = "") -> void:
	if icon_text == _icon_text and title == _title and subtitle == _subtitle \
			and is_equal_approx(hp_ratio, _hp_ratio) and show_hp == _show_hp \
			and badge == _badge:
		return
	_icon_text = icon_text
	_title = title
	_subtitle = subtitle
	_hp_ratio = hp_ratio
	_show_hp = show_hp
	_badge = badge
	queue_redraw()


## 三格数值：[{label:"编制", value:"5/11", hot:true}, ...]（hot 的那一格数值用绿色）
func set_stats(stats: Array) -> void:
	if _stats == stats:
		return
	_stats = stats.duplicate()
	queue_redraw()


func stat_count() -> int:
	return _stats.size()


func _draw() -> void:
	_draw_header()
	if not _stats.is_empty() and size.y >= HEAD_RULE_Y + 40.0:
		_draw_stats()


# ------------------------------------------------------------------
# 头部
# ------------------------------------------------------------------

func _draw_header() -> void:
	var f := _font if _font != null else get_theme_default_font()
	var focus_number := _is_focus_number()
	if focus_number:
		_draw_focus_number(f)
	else:
		_draw_portrait(f)
	if f == null:
		return
	var text_x := 68.0 if focus_number else TEXT_X
	var tw := maxf(40.0, size.x - text_x - 16.0)
	var title := String(_title)
	if _badge != "":
		tw -= UiTextRes.tracked_width(f, _badge, BADGE_FS, BADGE_TRACK) + 10.0
	title = UiTextRes.fit(f, title, tw, TITLE_FS)
	draw_string(f, Vector2(text_x, 44.0), title, HORIZONTAL_ALIGNMENT_LEFT, tw,
		TITLE_FS, UiStyleRes.text())
	if _subtitle != "":
		var sub := UiTextRes.fit(f, _subtitle, tw, SUB_FS)
		draw_string(f, Vector2(text_x, 64.0), sub, HORIZONTAL_ALIGNMENT_LEFT, tw,
			SUB_FS, UiStyleRes.text_dim())
	if _badge != "":
		var bw := UiTextRes.tracked_width(f, _badge, BADGE_FS, BADGE_TRACK)
		UiTextRes.tracked(self, f, Vector2(size.x - 14.0 - bw, 26.0), _badge,
			BADGE_FS, Color(UiStyleRes.accent(), 0.85), BADGE_TRACK)
	# 头部底边那条金线：把「身份」与下面的数值格分开
	var ry: float = minf(HEAD_RULE_Y, size.y - 2.0)
	draw_line(Vector2(14.0, ry), Vector2(size.x - 14.0, ry),
		Color(UiStyleRes.accent(), 0.40), 1.0)


func _is_focus_number() -> bool:
	return _badge.begins_with("已选") and _icon_text.is_valid_int()


func _draw_focus_number(f: Font) -> void:
	var r := Rect2(12.0, 12.0, 49.0, 52.0)
	draw_rect(r, UiStyleRes.bg_empty(), true)
	draw_rect(r, UiStyleRes.accent(), false, 2.0)
	draw_rect(Rect2(r.position.x + 2.0, r.end.y - 5.0, r.size.x - 4.0, 3.0),
		UiStyleRes.hp_high(), true)
	if f != null:
		UiTextRes.centered(self, f, r, _icon_text, 24, UiStyleRes.text())


## 五边形裁角的头像（方向稿 `clip-path: polygon(0 0,100% 0,100% 78%,50% 100%,0 78%)`）
func _draw_portrait(f: Font) -> void:
	var outer := _pentagon(PORTRAIT)
	draw_colored_polygon(outer, Color(0.10, 0.13, 0.17, 1.0))
	# 内圈暗环（方向稿 `inset 0 0 0 4px #111920`）：整块按比例缩 4px
	var c := PORTRAIT.get_center()
	var inner := _scale_poly(outer, c, 1.0 - 8.0 / PORTRAIT.size.x, 1.0 - 8.0 / PORTRAIT.size.y)
	draw_colored_polygon(inner, Color(0.048, 0.063, 0.083, 1.0))
	draw_polyline(outer + PackedVector2Array([outer[0]]), UiStyleRes.accent(), 2.0, true)
	if f != null:
		UiTextRes.centered(self, f, Rect2(PORTRAIT.position + Vector2(0, -6),
			Vector2(PORTRAIT.size.x, PORTRAIT.size.y)), _icon_text, 27, UiStyleRes.text())
	if _show_hp:
		# 头像底部那一条血条：贴在五边形的「肩」上方，宽度让开两道斜边
		var bar := Rect2(PORTRAIT.position.x + 12.0, PORTRAIT.position.y + 50.0,
			PORTRAIT.size.x - 24.0, 4.0)
		draw_rect(bar, UiStyleRes.hp_bar_bg(), true)
		var w := bar.size.x * clampf(_hp_ratio, 0.0, 1.0)
		if w > 0.0:
			draw_rect(Rect2(bar.position, Vector2(w, bar.size.y)),
				UiStyleRes.hp_bar_color(_hp_ratio), true)


static func _pentagon(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(r.position.x, r.position.y),
		Vector2(r.end.x, r.position.y),
		Vector2(r.end.x, r.position.y + r.size.y * 0.78),
		Vector2(r.position.x + r.size.x * 0.5, r.end.y),
		Vector2(r.position.x, r.position.y + r.size.y * 0.78),
	])


static func _scale_poly(pts: PackedVector2Array, c: Vector2, sx: float,
		sy: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(Vector2(c.x + (p.x - c.x) * sx, c.y + (p.y - c.y) * sy))
	return out


# ------------------------------------------------------------------
# 三格数值
# ------------------------------------------------------------------

func _draw_stats() -> void:
	var f := _font if _font != null else get_theme_default_font()
	var gap := 6.0
	var x0 := 14.0
	var y0 := 96.0
	var n: int = clampi(_stats.size(), 1, 4)
	var total := size.x - 2.0 * x0
	var bw := (total - gap * float(n - 1)) / float(n)
	for i in n:
		var st: Dictionary = _stats[i]
		var r := Rect2(x0 + float(i) * (bw + gap), y0, bw, 46.0)
		draw_rect(r, Color(0.043, 0.058, 0.078, 1.0), true)
		draw_rect(r, UiStyleRes.line_soft(), false, 1.0)
		# 格子底部压一条更暗的厚度边（与编队牌同一种「卡片」语言）
		draw_rect(Rect2(r.position.x + 1.0, r.end.y - 3.0, r.size.x - 2.0, 2.0),
			Color(0.016, 0.024, 0.033, 0.9), true)
		if f == null:
			continue
		UiTextRes.tracked(self, f, Vector2(r.position.x + 9.0, r.position.y + 17.0),
			String(st.get("label", "")), STAT_LABEL_FS,
			Color(UiStyleRes.text_faint(), 0.95), STAT_LABEL_TRACK)
		var hot := bool(st.get("hot", false))
		var col: Color = UiStyleRes.hp_high() if hot else UiStyleRes.text()
		var value := UiTextRes.fit(f, String(st.get("value", "")), r.size.x - 18.0, STAT_FS)
		draw_string(f, Vector2(r.position.x + 9.0, r.position.y + 39.0), value,
			HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 18.0, STAT_FS, col)
