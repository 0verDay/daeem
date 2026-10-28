## broadcast_banner.gd —— 屏幕**上方居中**的播报横幅（当前只有一件事：大本营升级）。
##
## 需求：任何**指挥官阵营**（真人席位 + command AI）开始升级大本营时，向所有玩家播报；
## 取消升级不撤播报，取消后再升会再播一条。
##
## 版式（与左上目标栏 / 结算横幅同一套语言）：
##     [3px 阵营色 | 暗底 + 1px 金线]
##     「红方 正在升级大本营 → 2 级」
##
## ★ 最多同时堆叠 `ui.broadcast.max_lines` 条（满了挤掉最旧的一条），每条各自计时淡出。
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

var _width := 460.0
var _top := 16.0
var _line_h := 44.0
var _gap := 6.0
var _max_lines := 3
var _hold := 4.0
var _fade := 0.25
var _text_fmt := "%s 正在升级大本营 → %d 级"

## 每条播报：{"text": String, "color": Color, "t": 已显示秒数}
var _lines: Array = []
## 复用的行控件（最多 _max_lines 组）
var _slots: Array = []


func setup(p_cfg, font: Font) -> void:
	cfg = p_cfg
	_font = font
	name = "BroadcastBanner"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_read_config()
	_build_slots()
	_layout_self()
	visible = false


func _read_config() -> void:
	if cfg == null:
		return
	_width = maxf(160.0, cfg.num("ui.broadcast.width", 460.0))
	_top = maxf(0.0, cfg.num("ui.broadcast.top", 16.0))
	_line_h = maxf(20.0, cfg.num("ui.broadcast.line_height", 44.0))
	_gap = maxf(0.0, cfg.num("ui.broadcast.gap", 6.0))
	_max_lines = maxi(1, int(cfg.num("ui.broadcast.max_lines", 3.0)))
	_hold = maxf(0.0, cfg.num("ui.broadcast.hold_sec", 4.0))
	_fade = maxf(0.0, cfg.num("ui.broadcast.fade_sec", 0.25))
	_text_fmt = String(cfg.str_val("ui.broadcast.text_fmt", _text_fmt))


## 顶部居中：用 UiLayoutRes.apply_top_center（锚点钉 50%，窗口变宽也不会跑偏）。
func _layout_self() -> void:
	var h := float(_max_lines) * _line_h + float(_max_lines - 1) * _gap
	var r := Rect2(UiLayoutRes.DESIGN_W * 0.5 - _width * 0.5, _top, _width, h)
	UiLayoutRes.apply_top_center(self, r)


func _build_slots() -> void:
	for i in _max_lines:
		var row := Control.new()
		row.name = "BroadcastRow%d" % i
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.position = Vector2(0.0, float(i) * (_line_h + _gap))
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
		row.add_child(label)

		row.visible = false
		_slots.append({"row": row, "bg": bg, "accent": accent, "label": label})


# ------------------------------------------------------------------
# 对外（HUD / 测试）
# ------------------------------------------------------------------

## 播一条。`text` 由 HUD 用 `ui.broadcast.text_fmt` 拼好；`color` = 阵营主色。
func push(text: String, color: Color) -> void:
	if String(text) == "":
		return
	while _lines.size() >= _max_lines:
		_lines.pop_front()
	_lines.append({"text": String(text), "color": color, "t": 0.0})
	visible = true
	_sync_slots()


## 推进计时：淡入 → 停留 → 淡出 → 移除。`dt` 与 HUD 的 `_process(dt)` 同一个。
func tick(dt: float) -> void:
	if _lines.is_empty():
		return
	var total := _hold + _fade * 2.0
	if not ThemeRes.animations_enabled():
		total = _hold
	var keep: Array = []
	for e in _lines:
		e["t"] = float(e["t"]) + maxf(0.0, dt)
		if float(e["t"]) < total:
			keep.append(e)
	_lines = keep
	visible = not _lines.is_empty()
	_sync_slots()


func clear() -> void:
	_lines = []
	visible = false
	_sync_slots()


func line_count() -> int:
	return _lines.size()


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
	return _alpha_for(float((_lines[i] as Dictionary).get("t", 0.0)))


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
# 内部
# ------------------------------------------------------------------

func _alpha_for(t: float) -> float:
	if not ThemeRes.animations_enabled():
		return 1.0
	if _fade <= 0.0:
		return 1.0
	if t < _fade:
		return clampf(t / _fade, 0.0, 1.0)
	var out_start := _hold + _fade
	if t > out_start:
		return clampf(1.0 - (t - out_start) / _fade, 0.0, 1.0)
	return 1.0


func _sync_slots() -> void:
	for i in _slots.size():
		var slot: Dictionary = _slots[i]
		var row: Control = slot["row"]
		if i >= _lines.size():
			row.visible = false
			continue
		var e: Dictionary = _lines[i]
		var a := _alpha_for(float(e.get("t", 0.0)))
		var c: Color = e.get("color", UiStyleRes.accent())
		row.visible = true
		row.modulate = Color(1.0, 1.0, 1.0, a)
		var label: Label = slot["label"]
		label.text = String(e.get("text", ""))
		(slot["accent"] as ColorRect).color = c
