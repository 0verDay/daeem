## level_transition.gd —— 战役过渡页（全屏覆盖，不可取消）。
##
## 版式：左侧地图缩略图 + 右侧关卡简报 + 底部加载进度条 / 「点击进入游戏」呼吸提示。
## 阵营在战役详情页已经选好，本页不再选阵营；`faction` 由 setup 传入。
##
## 加载仍是真实的 `ResourceLoader.load_threaded_request`；进度条落画后才允许点击。
## Esc / 安卓返回被吞掉（`main` 也不会收掉这一页）。
extends CanvasLayer

signal enter_requested(faction: String)
signal cancelled

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const MapPreviewRes = preload("res://view/map_preview.gd")
const LevelBriefRes = preload("res://logic/level_brief.gd")
## 本页也是菜单流程的一页：「点击进入游戏」与菜单按钮同一套点击音。
const SfxRes = preload("res://view/sfx.gd")

const LAYER := 150
const NEXT_SCENE_PATH := "res://view/game_scene3d.gd"
const BREATH_LOW := 0.45
const BREATH_HALF := 0.9

var cfg: ConfigRes = null
var font: Font = null
var campaign = null
var level = null
var faction: String = ""

var _root: Control = null
var _bg: Control = null
var _left_pnl: Panel = null
var _right_pnl: Panel = null
var _preview = null
var _subtitle: Label = null
var _title: Label = null
var _rule: ColorRect = null
var _body: RichTextLabel = null
var _progress: ProgressBar = null
var _hint_hit: Control = null
var _hint_label: Label = null

var _margin: float = 40.0
var _gap: float = 40.0
var _panel_alpha: float = 0.92
var _title_size: int = 38
var _subtitle_size: int = 20
var _body_size: int = 21
var _hint_size: int = 24
var _bar_height: float = 26.0
var _bar_bottom: float = 120.0
var _bar_move_sec: float = 0.35
var _hint_fade_sec: float = 0.25
var _slide_sec: float = 0.42
var _fade_sec: float = 0.35
var _hint_text: String = "————点击进入游戏————"
var _panel_slide_stagger: float = 0.0

var _load_paths: Array = []
var _load_progress: float = 0.0
var _shown_progress: float = 0.0
var _loading_done: bool = false
var _bar_intro_started: bool = false
var _bar_intro_done: bool = false
var _bar_out: bool = false
var _bar_home_y: float = 0.0
var _bar_tween: Tween = null
var _ready_to_enter: bool = false
var _entering: bool = false
var _hint_tween: Tween = null
var _breath_tween: Tween = null
var _intro_started: bool = false
var _intro_tween: Tween = null
var _layout_queued: bool = false


func setup(p_cfg: ConfigRes, p_font: Font, p_campaign, p_level, p_faction: String) -> void:
	cfg = p_cfg
	font = p_font
	campaign = p_campaign
	level = p_level
	faction = p_faction
	name = "LevelTransition"
	layer = LAYER
	SfxRes.mark_menu(self)
	_read_config()
	_build()
	call_deferred("_layout")
	_start_loading()


func _read_config() -> void:
	if cfg == null:
		return
	_margin = cfg.num("menu.campaign_start.margin", 40.0)
	_gap = cfg.num("menu.campaign_start.gap", 40.0)
	_panel_alpha = clampf(cfg.num("menu.campaign_start.panel_alpha", 0.92), 0.3, 1.0)
	_title_size = cfg.int_val("menu.campaign_start.title_size", 38)
	_subtitle_size = cfg.int_val("menu.campaign_start.subtitle_size", 20)
	_body_size = cfg.int_val("menu.campaign_start.body_size", 21)
	_hint_size = cfg.int_val("menu.campaign_start.hint_size", 24)
	_bar_height = cfg.num("menu.campaign_start.bar_height", 26.0)
	_bar_bottom = cfg.num("menu.campaign_start.bar_bottom", 120.0)
	_bar_move_sec = maxf(0.0, cfg.num("menu.campaign_start.bar_move_sec", 0.35))
	_hint_fade_sec = maxf(0.0, cfg.num("menu.campaign_start.hint_fade_sec", 0.25))
	_slide_sec = maxf(0.0, cfg.num("menu.campaign_start.slide_sec", 0.42))
	_fade_sec = maxf(0.0, cfg.num("menu.campaign_start.fade_sec", 0.35))
	_hint_text = cfg.str_val("menu.campaign_start.hint", "————点击进入游戏————")


func _build() -> void:
	_root = Control.new()
	_root.name = "TransitionRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	_root.resized.connect(_on_resized)

	_bg = MenuBackgroundRes.new()
	_bg.name = "Background"
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(_bg)

	_left_pnl = Panel.new()
	_left_pnl.name = "MapPnl"
	_left_pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_pnl.add_theme_stylebox_override("panel", _panel_style())
	_left_pnl.modulate.a = 0.0
	_root.add_child(_left_pnl)

	_preview = MapPreviewRes.new()
	_preview.name = "MapPreview"
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.offset_left = 8.0
	_preview.offset_right = -8.0
	_preview.offset_top = 8.0
	_preview.offset_bottom = -8.0
	_left_pnl.add_child(_preview)

	_right_pnl = Panel.new()
	_right_pnl.name = "InfoPnl"
	_right_pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_pnl.add_theme_stylebox_override("panel", _panel_style())
	_right_pnl.modulate.a = 0.0
	_root.add_child(_right_pnl)

	_subtitle = _make_label("Subtitle", _subtitle_text(), _subtitle_size, ThemeRes.text_dim())
	_subtitle.position = Vector2(26.0, 24.0)
	_subtitle.size = Vector2(600.0, 28.0)
	_right_pnl.add_child(_subtitle)

	_title = _make_label("Title", LevelBriefRes.level_name(level), _title_size, ThemeRes.text())
	_title.position = Vector2(26.0, 54.0)
	_title.size = Vector2(620.0, 54.0)
	_right_pnl.add_child(_title)

	_rule = ColorRect.new()
	_rule.name = "Rule"
	_rule.color = ThemeRes.line()
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rule.position = Vector2(26.0, 116.0)
	_rule.size = Vector2(620.0, 1.0)
	_right_pnl.add_child(_rule)

	_body = RichTextLabel.new()
	_body.name = "Briefing"
	_body.bbcode_enabled = false
	_body.fit_content = false
	_body.scroll_active = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if font != null:
		_body.add_theme_font_override("normal_font", font)
	_body.add_theme_font_size_override("normal_font_size", _body_size)
	_body.add_theme_color_override("default_color", ThemeRes.text_dim())
	_body.position = Vector2(26.0, 132.0)
	_body.size = Vector2(620.0, 600.0)
	_right_pnl.add_child(_body)
	_body.text = LevelBriefRes.briefing_text(level)

	_preview.setup(cfg, level)
	_preview.set_view_faction(faction)

	_progress = ProgressBar.new()
	_progress.name = "Progress"
	_progress.min_value = 0.0
	_progress.max_value = 100.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.add_theme_stylebox_override("background", _bar_bg())
	_progress.add_theme_stylebox_override("fill", _bar_fill())
	_root.add_child(_progress)

	_hint_hit = Control.new()
	_hint_hit.name = "StartHit"
	_hint_hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_hit.gui_input.connect(_on_hint_input)
	_root.add_child(_hint_hit)

	_hint_label = _make_label("StartLabel", "", _hint_size, ThemeRes.text())
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hint_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hint_label.modulate.a = 0.0
	_hint_hit.add_child(_hint_label)


func _panel_style() -> StyleBoxFlat:
	var s := MenuThemeRes.deck_panel()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), _panel_alpha)
	return s


func _bar_bg() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.92)
	s.border_color = ThemeRes.line_soft()
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	return s


func _bar_fill() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.accent()
	s.set_corner_radius_all(2)
	return s


func _make_label(node_name: String, text: String, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func _subtitle_text() -> String:
	var cname := LevelBriefRes.campaign_name(campaign)
	var mode := LevelBriefRes.mode_text(level)
	var fname := faction
	for raw in LevelBriefRes.playable_entries(level):
		var d: Dictionary = raw
		if String(d.get("id", "")) == faction:
			fname = String(d.get("name", faction))
			break
	var parts: Array = []
	if cname != "":
		parts.append(cname)
	if mode != "":
		parts.append(mode)
	if fname != "":
		parts.append(fname)
	return "　·　".join(parts)


# ------------------------------------------------------------------
# 布局
# ------------------------------------------------------------------

func _on_resized() -> void:
	if _layout_queued:
		return
	_layout_queued = true
	call_deferred("_layout_now")


func _layout_now() -> void:
	_layout_queued = false
	_layout()


func _layout() -> void:
	if _root == null or _left_pnl == null or _right_pnl == null:
		return
	var w: float = _root.size.x
	var h: float = _root.size.y
	if w <= 1.0 or h <= 1.0:
		return
	var bar_y: float = h - _bar_bottom
	var content_h: float = maxf(300.0, bar_y - _margin - 40.0)
	var inner_w: float = w - _margin * 2.0 - _gap
	var left_w: float = inner_w * 0.5
	var right_w: float = inner_w - left_w
	var right_x: float = _margin + left_w + _gap
	_left_pnl.position = Vector2(_margin, _margin)
	_left_pnl.size = Vector2(left_w, content_h)
	_right_pnl.position = Vector2(right_x, _margin)
	_right_pnl.size = Vector2(right_w, content_h)
	_body.size = Vector2(right_w - 52.0, content_h - 140.0)
	_rule.size = Vector2(right_w - 52.0, 1.0)
	_title.size = Vector2(right_w - 52.0, 54.0)
	_subtitle.size = Vector2(right_w - 52.0, 28.0)

	_progress.size = Vector2(w - _margin * 2.0, _bar_height)
	_bar_home_y = bar_y
	_hint_hit.position = Vector2(_margin, bar_y - 30.0)
	_hint_hit.size = Vector2(w - _margin * 2.0, 110.0)
	if not _bar_intro_started:
		_start_bar_intro()
	elif _bar_intro_done and not _bar_out:
		_progress.position = Vector2(_margin, bar_y)
	else:
		_progress.position.x = _margin

	if not _intro_started:
		_intro_started = true
		if ThemeRes.animations_enabled() and _slide_sec > 0.0:
			call_deferred("_play_slide")
		else:
			_left_pnl.modulate.a = 1.0
			_right_pnl.modulate.a = 1.0


func _play_slide() -> void:
	if not is_instance_valid(self):
		return
	var lto: Vector2 = _left_pnl.position
	var rto: Vector2 = _right_pnl.position
	_left_pnl.position = lto + Vector2(-_left_pnl.size.x - _margin, 0.0)
	_right_pnl.position = rto + Vector2(_right_pnl.size.x + _margin, 0.0)
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_left_pnl, "position", lto, _slide_sec)
	tw.tween_property(_right_pnl, "position", rto, _slide_sec)
	tw.tween_property(_left_pnl, "modulate:a", 1.0, minf(0.3, _slide_sec))
	tw.tween_property(_right_pnl, "modulate:a", 1.0, minf(0.3, _slide_sec))
	_intro_tween = tw


# ------------------------------------------------------------------
# 加载 / 进度条
# ------------------------------------------------------------------

func _start_loading() -> void:
	_load_paths = [NEXT_SCENE_PATH]
	for p in _load_paths:
		var err: int = ResourceLoader.load_threaded_request(String(p))
		if err != OK:
			push_warning("战役过渡：预加载失败 %s（err=%d）" % [p, err])


func _process(_delta: float) -> void:
	if _loading_done:
		return
	var total := 0.0
	var count := 0
	for p in _load_paths:
		var arr: Array = []
		var status: int = ResourceLoader.load_threaded_get_status(String(p), arr)
		var one := 0.0
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				one = 1.0
			ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				one = 1.0
			_:
				if arr.size() > 0:
					one = clampf(float(arr[0]), 0.0, 1.0)
		total += one
		count += 1
	_load_progress = 1.0 if count == 0 else total / float(count)
	_shown_progress = _load_progress * 100.0
	if _progress != null:
		_progress.value = _shown_progress
	if _load_progress >= 1.0 and _bar_intro_done:
		_finish_loading()


func _start_bar_intro() -> void:
	_bar_intro_started = true
	if _progress == null:
		return
	if _loading_done or _bar_out:
		_bar_intro_done = true
		_progress.visible = false
		return
	if not ThemeRes.animations_enabled() or _bar_move_sec <= 0.0:
		_progress.position = Vector2(_margin, _bar_home_y)
		_bar_intro_done = true
		return
	_progress.position = Vector2(_margin, _root.size.y + _bar_height)
	_bar_tween = create_tween()
	_bar_tween.tween_property(_progress, "position:y", _bar_home_y, _bar_move_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_bar_tween.finished.connect(_on_bar_intro_finished)


func _finish_loading() -> void:
	if _loading_done:
		return
	_loading_done = true
	_bar_out = true
	_progress.value = 100.0
	_hint_label.text = _hint_text
	_hint_label.modulate.a = 0.0
	if not ThemeRes.animations_enabled() or _bar_move_sec <= 0.0:
		_progress.visible = false
		_hint_label.modulate.a = 1.0
		_ready_to_enter = true
		_refresh_hint()
		_start_breathing()
		return
	_bar_tween = create_tween()
	_bar_tween.tween_property(_progress, "position:y", _root.size.y + _progress.size.y,
		_bar_move_sec).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_bar_tween.finished.connect(_on_bar_out_finished)


func _reveal_hint() -> void:
	if _hint_label == null or _entering or not _ready_to_enter:
		return
	if not ThemeRes.animations_enabled() or _hint_fade_sec <= 0.0:
		_hint_label.modulate.a = 1.0
		_start_breathing()
		return
	_hint_label.modulate.a = 0.0
	var tw := create_tween()
	_hint_tween = tw
	tw.tween_property(_hint_label, "modulate:a", 1.0, _hint_fade_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.finished.connect(_on_hint_fade_finished)


func _start_breathing() -> void:
	if _hint_label == null or not _ready_to_enter or _entering:
		return
	if not ThemeRes.animations_enabled():
		_hint_label.modulate.a = 1.0
		return
	if _breath_tween != null and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = create_tween()
	_breath_tween.set_loops()
	_breath_tween.tween_property(_hint_label, "modulate:a", BREATH_LOW, BREATH_HALF) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath_tween.tween_property(_hint_label, "modulate:a", 1.0, BREATH_HALF) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _refresh_hint() -> void:
	if _hint_hit == null:
		return
	_hint_hit.mouse_filter = Control.MOUSE_FILTER_STOP if _ready_to_enter else Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------
# 进入
# ------------------------------------------------------------------

func _on_hint_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	_hint_hit.accept_event()
	SfxRes.play_click()
	_enter()


func _enter() -> void:
	if _entering or not _ready_to_enter:
		return
	_entering = true
	_hint_hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_hint_tweens()
	enter_requested.emit(faction)


func _kill_hint_tweens() -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint_tween = null
	if _breath_tween != null and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = null


## 不可取消：Esc / 安卓返回在 main 与本页都被吞掉。保留给测试/程序化清理。
func cancel() -> void:
	if _entering:
		return
	_entering = true
	_kill_hint_tweens()
	if not ThemeRes.animations_enabled() or _fade_sec <= 0.0:
		cancelled.emit()
		return
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, _fade_sec)
	tw.finished.connect(_on_cancel_fade_finished)


func _on_bar_intro_finished() -> void:
	_bar_tween = null
	_bar_intro_done = true
	if _progress != null:
		_progress.position = Vector2(_margin, _bar_home_y)


func _on_bar_out_finished() -> void:
	_bar_tween = null
	_progress.visible = false
	_ready_to_enter = true
	_refresh_hint()
	_reveal_hint()


func _on_hint_fade_finished() -> void:
	_hint_tween = null
	if not _entering:
		_start_breathing()


func _on_cancel_fade_finished() -> void:
	cancelled.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()


# ------------------------------------------------------------------
# 测试 / 排查
# ------------------------------------------------------------------

func preview():
	return _preview


func selected_faction() -> String:
	return faction


func ready_to_enter() -> bool:
	return _ready_to_enter


func loading_done() -> bool:
	return _loading_done


func progress_value() -> float:
	return _shown_progress


func bar_y() -> float:
	return _bar_home_y


func bar_home_y() -> float:
	return _bar_home_y


func bar_intro_done() -> bool:
	return _bar_intro_done


func bar_offscreen() -> bool:
	return _bar_out


func hint_text() -> String:
	return _hint_label.text if _hint_label != null else ""


func hint_rect() -> Rect2:
	return _hint_hit.get_global_rect() if _hint_hit != null else Rect2()


func map_panel() -> Panel:
	return _left_pnl


func info_panel() -> Panel:
	return _right_pnl


func panel_slide_active() -> bool:
	return _intro_tween != null and _intro_tween.is_valid()


func margin() -> float:
	return _margin


func gap() -> float:
	return _gap
