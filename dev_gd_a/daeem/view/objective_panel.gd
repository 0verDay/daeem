## objective_panel.gd —— 局内**顶部居中**的目标条（战役 / 合作）。
##
## 显示什么（全部从权威状态读，视图不自己算）：
##   · 标题：「守住 c1」/「占领 c1」
##   · 进度：「已守 92 / 120 秒」+ 一根进度条（`ObjectiveRes.progress_ratio`）
##   · 结算：胜利「本关守住！」/ 失败「本关失守：目标区划失守」
##
## ★★ 为什么要有它（本轮 M12.1）：`view/` 之前**完全没有**读 `world.objective_state`，
##   合作关玩家既看不到「守到哪了」，也不知道自己为什么输。规则在 logic/objective.gd
##   已经完整，缺的只是这一块显示。
##
## ★ 几何只在 `view/ui_layout.gd`（本文件不写坐标字面量）；文案在
##   `data/config.json` 的 `coop.objective` 段。
## ★ 它**不点**（mouse_filter = IGNORE），也不进 `interactive_rects` —— 鼠标停在
##   上面照样允许边缘滚屏，与「详细信息面板只有文字的地方让路」同一条规矩。
extends Control

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ObjectiveRes = preload("res://logic/objective.gd")

var cfg = null
var world = null
var _font: Font = null
## 上一帧画的内容签名：只在「显示的数变了」时重画（与 HUD 的签名刷法同一条思路）。
var _sig: String = ""
## `_draw()` 跑过几次 —— 测试用它证明「真的画了一帧」（不需要截图）。
var draw_count: int = 0


func setup(p_cfg, p_world, font: Font) -> void:
	cfg = p_cfg
	world = p_world
	_font = font
	name = "ObjectivePanel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiLayoutRes.apply_top_center(self, UiLayoutRes.OBJECTIVE_RECT)
	visible = false
	_sync_visibility()


## 每帧由 HUD 的 shell 刷新调用。
func sync() -> void:
	if not _sync_visibility():
		return
	var st: Dictionary = _state()
	var sig := "%s|%s|%s|%s|%s|%s" % [
		String(st.get("kind", "")), str(int(st.get("zone", -1))),
		str(floori(float(st.get("held", 0.0)) * 10.0)), str(floori(float(st.get("sec", 0.0)))),
		String(st.get("state", "")), String(st.get("reason", "")),
	]
	if sig != _sig:
		_sig = sig
		queue_redraw()


# ------------------------------------------------------------------
# 对外查询（测试 / 排查；界面画的时候也走这几个函数，避免两份文案）
# ------------------------------------------------------------------

func title_text() -> String:
	if world == null or world.level == null:
		return ""
	var st: Dictionary = _state()
	if st.is_empty():
		return ""
	var z := int(st.get("zone", -1))
	var zlabel := "c%d" % z
	if world.level.has_method("zone_label"):
		zlabel = String(world.level.zone_label(z))
	var kind := String(st.get("kind", ""))
	var prefix := "占领" if kind == "capture_zone" else "守住"
	if cfg != null:
		prefix = String(cfg.str_val(
			"coop.objective.capture_prefix" if kind == "capture_zone"
				else "coop.objective.hold_prefix", prefix))
	return "%s %s" % [prefix, zlabel]


func progress_text() -> String:
	var st: Dictionary = _state()
	if st.is_empty():
		return ""
	var state := String(st.get("state", ObjectiveRes.STATE_RUNNING))
	if state == ObjectiveRes.STATE_LOST:
		var label := ObjectiveRes.reason_label(st)
		var sep := "：" if cfg == null else String(cfg.str_val("coop.objective.reason_sep", "："))
		var lost := "本关失守" if cfg == null else String(cfg.str_val("coop.objective.lost_text", "本关失守"))
		return lost + (sep + label if label != "" else "")
	if state == ObjectiveRes.STATE_WON:
		if String(st.get("kind", "")) == "capture_zone":
			return "已占领" if cfg == null else String(cfg.str_val("coop.objective.capture_done", "已占领"))
		return _held_text(st)
	if String(st.get("kind", "")) == "capture_zone":
		return "等待占领" if cfg == null else String(cfg.str_val("coop.objective.capture_pending", "等待占领"))
	return _held_text(st)


func progress_ratio() -> float:
	var st: Dictionary = _state()
	if st.is_empty():
		return 0.0
	# ★ 胜利时永远画满：`capture_zone` 的 `sec` 是 0，按 held/sec 会算成 0。
	if String(st.get("state", "")) == ObjectiveRes.STATE_WON:
		return 1.0
	return ObjectiveRes.progress_ratio(st)


## 标题右边那一小块状态字（进行中为空）。
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
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	draw_count += 1
	if not visible or world == null:
		return
	var w: float = size.x
	var h: float = size.y
	# 底板 + 1px 金线：与底栏那些面板同一套观感（半透明，不压死地图）
	draw_rect(Rect2(0, 0, w, h), UiStyleRes.bg(), true)
	draw_rect(Rect2(0, 0, w, h), UiStyleRes.line(), false, 1.0)
	# 左侧一小条金色：让「目标」在屏幕上方一眼能认出来（不是又一块普通面板）
	draw_rect(Rect2(0, 0, 3.0, h), UiStyleRes.accent(), true)

	if _font == null:
		return
	var pad: float = UiLayoutRes.OBJECTIVE_PAD
	var title := _fit(title_text(), w - pad * 2.0 - 86.0, UiStyleRes.FS_TITLE)
	draw_string(_font, Vector2(pad, 26.0), title,
		HORIZONTAL_ALIGNMENT_LEFT, w - pad * 2.0, UiStyleRes.FS_TITLE, UiStyleRes.text())

	var state := state_text()
	if state != "":
		var state_color := UiStyleRes.accent_bright()
		if String(_state().get("state", "")) == ObjectiveRes.STATE_LOST:
			state_color = UiStyleRes.warn()
		draw_string(_font, Vector2(pad, 26.0), state,
			HORIZONTAL_ALIGNMENT_RIGHT, w - pad * 2.0, UiStyleRes.FS_SMALL, state_color)

	var ptxt := _fit(progress_text(), w - pad * 2.0, UiStyleRes.FS_SMALL)
	var pcolor := UiStyleRes.text_dim()
	var st: Dictionary = _state()
	if String(st.get("state", "")) == ObjectiveRes.STATE_LOST:
		pcolor = UiStyleRes.warn()
	elif String(st.get("state", "")) == ObjectiveRes.STATE_WON:
		pcolor = UiStyleRes.accent_bright()
	draw_string(_font, Vector2(pad, 46.0), ptxt,
		HORIZONTAL_ALIGNMENT_LEFT, w - pad * 2.0, UiStyleRes.FS_SMALL, pcolor)

	# 进度条：底 + 1px 描边 + 填充（比例只读 ObjectiveRes，不在视图里再算一份）
	var bar := Rect2(pad, UiLayoutRes.OBJECTIVE_BAR_Y,
		w - pad * 2.0, UiLayoutRes.OBJECTIVE_BAR_H)
	draw_rect(bar, UiStyleRes.bg_empty(), true)
	draw_rect(bar, UiStyleRes.line_soft(), false, 1.0)
	var ratio := progress_ratio()
	var fill_color := UiStyleRes.accent()
	if String(st.get("state", "")) == ObjectiveRes.STATE_LOST:
		fill_color = UiStyleRes.warn()
	elif String(st.get("state", "")) == ObjectiveRes.STATE_WON:
		fill_color = UiStyleRes.accent_bright()
	var fw: float = maxf(0.0, (bar.size.x - 2.0) * ratio)
	if fw > 0.0:
		draw_rect(Rect2(bar.position + Vector2(1, 1), Vector2(fw, bar.size.y - 2.0)),
			fill_color, true)


# ------------------------------------------------------------------
# 内部
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
			queue_redraw()
	return should_show


func _state() -> Dictionary:
	if world == null:
		return {}
	var st: Variant = world.objective_state
	return st if typeof(st) == TYPE_DICTIONARY else {}


func _held_text(st: Dictionary) -> String:
	var held := maxi(0, floori(float(st.get("held", 0.0))))
	var sec := maxi(0, floori(float(st.get("sec", 0.0))))
	if cfg == null:
		return "已守 %d / %d 秒" % [held, sec]
	return String(cfg.str_val("coop.objective.held_text", "已守 %d / %d 秒")) % [held, sec]


## 单行裁剪：宽度不够时截断并补「…」（与 detail_panel 的 _clip_text 同一个目的；
## 这里不依赖那个控件，目标条的字很少、开销可以忽略）。
func _fit(text: String, max_w: float, font_size: int) -> String:
	if _font == null or max_w <= 0.0:
		return text
	if _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return text
	var s := text
	while s.length() > 1:
		s = s.substr(0, s.length() - 1)
		if _font.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
			return s + "…"
	return "…"
