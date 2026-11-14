## detail_v2.gd —— 左下角详细信息牌（D6 / V2 方向稿）
##
## 结构照 art_draft/hud_balatro_direction_v2.html 的 `.hero-stack`：
##
##   背后压着两张错位的牌（`.hero-stack:before/:after`）→ 一张切角的主牌：
##   ┌────────────────────────────────────────────┐
##   │ 上半 detail_info：头像 + 名字 + 三格数值      │ ← 高度 146（多队态 88，没有数值格）
##   ├────────────────────────────────────────────┤
##   │ 下半 detail_list：成员格 + 特性 / 数值        │ ← 高度 114（多队态 172）
##   └────────────────────────────────────────────┘
##
## ★ 上下两块的**高度由状态决定**：多队态只留头部（第一行是「当前部队成员」），
##   所以 `_apply_zone()` 会把 list 拉高、info 压扁 —— 子控件自己不判断状态。
## ★ 旧 detail_panel 仍然存在（隐藏、全透明），继续喂数据给旧测试 / 兼容接口；
##   本控件只负责**显示与点击**，不判断选中规则。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const DetailListRes = preload("res://view/detail_list.gd")
const DetailInfoRes = preload("res://view/detail_info.gd")

signal unit_selected(unit)
signal entry_selected(entry)

## 面板几何：**只认 `ui_layout.DETAIL_V2_RECT`**（单一来源，别再在这里抄一份）。
##
## ★★ 2026.11.14：用户要求「将部队详细信息栏往屏幕左侧靠」⇒ 左缘 395 → 27
##   （贴左留白与其它面板一致），尺寸仍是 377×260。
##   ⚠️ 以前这里另有一份 `PANEL_RECT`，而 `ui_layout.DETAIL_V2_RECT`（拿去算
##     「滚轮缩放在不在底栏上」）又是另一份 —— 两处不同步就会出现
##     「看得见但点不中 / 点在空白处却被吞掉」。现在只留 ui_layout 那一份。
##
## 单队 / 单个对象：头部（含数值三格）占上面 146
const HEAD_ZONE_H := 146.0
## 多队：只留头部，剩下的全给「成员 + 其他已选」
const MULTI_HEAD_H := 88.0
## 主牌的切角（方向稿 `clip-path: polygon(0 0,96% 0,100% 7%,100% 100%,4% 100%,0 94%)`）
const CUT_X := 15.0
const CUT_TOP := 18.0
const CUT_BOT := 16.0

var list: Control = null
var info: Control = null
var _notice: Label = null
var _notice_bg: ColorRect = null


func setup(world, p_font: Font = null) -> void:
	name = "DetailPanelV2"
	mouse_filter = Control.MOUSE_FILTER_STOP
	UiLayoutRes.apply_rect(self, UiLayoutRes.DETAIL_V2_RECT, false, true)
	z_index = 5

	info = DetailInfoRes.new()
	info.setup(p_font)
	add_child(info)

	list = DetailListRes.new()
	list.setup(world, p_font)
	add_child(list)
	list.unit_selected.connect(_on_unit_selected)
	list.entry_selected.connect(_on_entry_selected)

	# 红字提示（操作被拒的一句话）：压成牌底的一条「纸条」，平时不占位。
	# ★ 自带深色底：提示出现时它会临时盖住页脚最后一行，有底才不会两行字糊在一起。
	_notice_bg = ColorRect.new()
	_notice_bg.name = "DetailNoticeBg"
	_notice_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice_bg.color = Color(0.07, 0.035, 0.035, 0.94)
	add_child(_notice_bg)

	_notice = Label.new()
	_notice.name = "DetailNotice"
	_notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_notice.clip_text = true
	_notice.add_theme_font_size_override("font_size", 10)
	_notice.add_theme_color_override("font_color", UiStyleRes.warn())
	_notice.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.02, 0.95))
	_notice.add_theme_constant_override("outline_size", 3)
	if p_font != null:
		_notice.add_theme_font_override("font", p_font)
	add_child(_notice)
	_notice.visible = false
	_notice_bg.visible = false

	_apply_zone(false)
	visible = false


## 上下两块的尺寸随状态走（见文件头）。
func _apply_zone(multi: bool) -> void:
	var head: float = MULTI_HEAD_H if multi else HEAD_ZONE_H
	var w: float = UiLayoutRes.DETAIL_V2_RECT.size.x
	var h: float = UiLayoutRes.DETAIL_V2_RECT.size.y
	info.position = Vector2(0.0, 0.0)
	info.size = Vector2(w, head)
	list.position = Vector2(0.0, head)
	list.size = Vector2(w, h - head)
	_notice_bg.position = Vector2(10.0, h - 30.0)
	_notice_bg.size = Vector2(w - 20.0, 20.0)
	_notice.position = _notice_bg.position
	_notice.size = _notice_bg.size
	queue_redraw()


func set_roster(troops: Array, focused_number: int, selected_unit) -> void:
	if list != null:
		list.set_roster(troops, focused_number, selected_unit)
	_apply_zone(troops.size() > 1)


func set_small_entries(entries: Array, primary, kind: String) -> void:
	if list != null:
		list.set_small_entries(entries, primary, kind)
	_apply_zone(false)


func set_header(icon_text: String, title: String, subtitle: String,
		hp_ratio: float = 1.0, show_hp: bool = false, badge: String = "") -> void:
	if info != null:
		info.set_header(icon_text, title, subtitle, hp_ratio, show_hp, badge)


## 三格数值：[{label, value, hot}]
func set_stats(stats: Array) -> void:
	if info != null:
		info.set_stats(stats)


## 把 hud 组装好的分组拆成「特性胶囊」与「短行」两摞交给下半块。
##   · traits / traits2 的将领特性 → 胶囊（悬停出浮窗）
##   · text / columns / traits2 的单位行 → 右列短行
##   · stats 组忽略（数值走 `set_stats()`）
func set_info_groups(groups: Array) -> void:
	if list == null:
		return
	var traits: Array = []
	var lines: Array = []
	var traits_label := ""
	var lines_label := ""
	for g in groups:
		var d: Dictionary = g
		var label := String(d.get("label", ""))
		match String(d.get("type", "text")):
			"traits":
				for t in d.get("traits", []):
					traits.append((t as Dictionary).duplicate())
				if traits_label == "":
					traits_label = label
			"traits2":
				for t2 in d.get("general", []):
					traits.append((t2 as Dictionary).duplicate())
				if traits_label == "" and not (d.get("general", []) as Array).is_empty():
					traits_label = label
				for line in d.get("unit_lines", []):
					lines.append(String(line))
				if lines_label == "" and not (d.get("unit_lines", []) as Array).is_empty():
					lines_label = label
			"columns":
				for col in d.get("columns", []):
					for line2 in col:
						lines.append(String(line2))
				if lines_label == "" and not (d.get("columns", []) as Array).is_empty():
					lines_label = label
			"stats":
				pass
			_:
				for line3 in d.get("lines", []):
					lines.append(String(line3))
				if lines_label == "" and not (d.get("lines", []) as Array).is_empty():
					lines_label = label
	list.set_traits(traits, traits_label)
	list.set_lines(lines, lines_label)


func set_notice(text: String) -> void:
	if _notice != null:
		_notice.text = text
		_notice.visible = text != ""
	if _notice_bg != null:
		_notice_bg.visible = text != ""


func _on_unit_selected(u) -> void:
	unit_selected.emit(u)


func _on_entry_selected(e: Dictionary) -> void:
	entry_selected.emit(e)


## 真正能点的区域（**面板局部坐标**）：下半块那几颗成员格 / 部队格。
## ★ hud 用它拦**边缘滚屏**（见 ui_layout.interactive_rects 的注释）。
func interactive_rects() -> Array:
	var out: Array = []
	if list == null:
		return out
	for r in list.interactive_rects():
		var rr: Rect2 = r
		out.append(Rect2(rr.position + list.position, rr.size))
	return out


# ------------------------------------------------------------------
# 牌面
# ------------------------------------------------------------------

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	var plate := _plate(w, h, Vector2.ZERO)
	# ① 投影
	var shadow := PackedVector2Array()
	for p in plate:
		shadow.append(p + Vector2(5.0, 7.0))
	draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.30))
	# ② 背后两张错位的牌（方向稿 `.hero-stack:before/:after`）：往右下探出去，
	#    所以它们比主牌「多出」一条边 —— 主牌压在上面时就是两层纸的厚度。
	for i in 2:
		var off := Vector2(10.0 - 4.0 * float(i), 8.0 - 3.0 * float(i))
		var back := _plate(w, h, off)
		draw_colored_polygon(back, Color(0.10, 0.125, 0.15, 0.92) if i == 0
			else Color(0.075, 0.095, 0.115, 0.92))
		draw_polyline(_closed(back), Color(UiStyleRes.line_soft(), 0.55), 1.0, true)
	# ③ 主牌：竖向渐变（顶浅底深）+ 2px 黄铜边
	var cols := PackedColorArray()
	var top := Color(0.105, 0.135, 0.165, 0.96)
	var bot := Color(0.034, 0.046, 0.060, 0.96)
	for p in plate:
		cols.append(top.lerp(bot, clampf(p.y / maxf(1.0, h), 0.0, 1.0)))
	draw_polygon(plate, cols)
	draw_polyline(_closed(plate), Color(UiStyleRes.accent(), 0.55), 2.0, true)
	# ④ 内圈 1px 金线（方向稿 `.hero:before{inset:6px; border:1px solid #ddbe6a4d}`）
	var inner := PackedVector2Array()
	for p in _plate(w - 12.0, h - 12.0, Vector2(6.0, 6.0)):
		inner.append(p)
	draw_polyline(_closed(inner), Color(UiStyleRes.accent(), 0.22), 1.0, true)


## 切角矩形（左上 / 右下是直角，右上 / 左下切一刀 —— 方向稿的 clip-path）
static func _plate(w: float, h: float, off: Vector2) -> PackedVector2Array:
	return PackedVector2Array([
		off,
		off + Vector2(w - CUT_X, 0.0),
		off + Vector2(w, CUT_TOP),
		off + Vector2(w, h),
		off + Vector2(CUT_X, h),
		off + Vector2(0.0, h - CUT_BOT),
	])


static func _closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array(pts)
	if not pts.is_empty():
		out.append(pts[0])
	return out
