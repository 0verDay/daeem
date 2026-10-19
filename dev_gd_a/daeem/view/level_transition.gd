## level_transition.gd —— ★★ 战役过渡画面（仿 nsoc 的章节入口 + 街亭双选）
##
## 布局（用户口径：战场缩略图在左、文本在右；进度条 + 点击进入提示）：
##   ┌──────────────────────────────┬─────────────────────────────┐
##   │                              │  战役名 · 模式（小字）      │
##   │        战场缩略图            │  关卡名（大字）             │
##   │  （地形/区划线/目标区/       │  ─────────────              │
##   │    大本营/出生点）           │  简报正文                   │
##   │                              │  [阵营卡]（多可玩阵营时）   │
##   └──────────────────────────────┴─────────────────────────────┘
##   ────────────────────── 进度条 ──────────────────────────────
##   进度条先从屏幕下方缓动升起到位；真实加载进度实时填满；满后下滑出画面；
##   **完全移出画面之后**才允许点进入；提示文字也是**从那一刻起**才淡入
##   （「————作为X进入游戏————」/「请选择阵营」，淡入完再呼吸）。
##   ⚠️ 别把「提示淡入」和「进度条下滑」写成同时开始：EASE_OUT 的淡入前 1/3 就亮到
##      九成，条还在画面里时字已经能看见了（用户实测报回来的就是这个）。
##
## ★★ 多可玩阵营：右侧正文下方出现 N 张**可点选**的阵营卡（默认不选，必须选一张），
##   选中 = 金边加粗；底部提示在未选时是「请选择阵营」且不可点。
##   仿的是 nsoc 街亭的「双检阅面板 + 互斥单选 + 底部提示」，只把蓝色选中态换成暗金。
##
## ★ 加载：真实的 `ResourceLoader.load_threaded_request`（战斗场景脚本），
##   进度条**直接显示真实进度**（不做追赶 / 不做最短展示时长）。
##
## ★ 只发信号，不建世界：
##   `enter_requested(faction)` → main 调 `_on_campaign_level_chosen`（流程只在 main）。
##   `cancelled`（Esc）→ main 收回本层。
extends CanvasLayer

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const MapPreviewRes = preload("res://view/map_preview.gd")
const LevelBriefRes = preload("res://logic/level_brief.gd")

signal enter_requested(faction: String)
signal cancelled

## 盖在开场页（100）之上、退出确认（200）之下。
const LAYER := 150

const DEFAULT_MARGIN := 40.0
const DEFAULT_GAP := 22.0
const DEFAULT_LEFT_RATIO := 0.58
const DEFAULT_PANEL_ALPHA := 0.88
const DEFAULT_TITLE_SIZE := 38
const DEFAULT_SUBTITLE_SIZE := 20
const DEFAULT_BODY_SIZE := 21
const DEFAULT_CARD_HEIGHT := 68.0
const DEFAULT_CARD_NAME_SIZE := 24
const DEFAULT_CARD_GOAL_SIZE := 17
const DEFAULT_BAR_HEIGHT := 26.0
const DEFAULT_BAR_BOTTOM := 34.0
## 进度条「升起到位 / 下滑出画」的时长（两段共用；见 `_start_bar_intro` / `_finish_loading`）。
const DEFAULT_BAR_MOVE_SEC := 0.35
const DEFAULT_HINT_SIZE := 24
## 进度条**完全落画之后**，提示文字淡入的时长（见 `_reveal_hint`）。
const DEFAULT_HINT_FADE_SEC := 0.25
const DEFAULT_FADE_SEC := 0.35
const BREATH_LOW := 0.45
const BREATH_HALF := 0.9

const NEXT_SCENE_PATH := "res://view/game_scene3d.gd"

var cfg: ConfigRes = null
var font: Font = null
var campaign = null
var level = null

var _root: Control = null
var _bg: Control = null
var _left_pnl: Panel = null
var _right_pnl: Panel = null
var _preview = null
var _subtitle: Label = null
var _title: Label = null
var _rule: ColorRect = null
var _body: RichTextLabel = null
var _cards_box: VBoxContainer = null
var _progress: ProgressBar = null
var _hint_hit: Control = null
var _hint_label: Label = null

var _entries: Array = []
var _cards: Array = []
var _selected: String = ""

var _margin: float = DEFAULT_MARGIN
var _gap: float = DEFAULT_GAP
var _left_ratio: float = DEFAULT_LEFT_RATIO
var _panel_alpha: float = DEFAULT_PANEL_ALPHA
var _title_size: int = DEFAULT_TITLE_SIZE
var _subtitle_size: int = DEFAULT_SUBTITLE_SIZE
var _body_size: int = DEFAULT_BODY_SIZE
var _card_height: float = DEFAULT_CARD_HEIGHT
var _card_name_size: int = DEFAULT_CARD_NAME_SIZE
var _card_goal_size: int = DEFAULT_CARD_GOAL_SIZE
var _bar_height: float = DEFAULT_BAR_HEIGHT
var _bar_bottom: float = DEFAULT_BAR_BOTTOM
var _bar_move_sec: float = DEFAULT_BAR_MOVE_SEC
var _hint_size: int = DEFAULT_HINT_SIZE
var _hint_fade_sec: float = DEFAULT_HINT_FADE_SEC
## 点「进入」现在交给 main 做黑屏转场（要跨「收掉本页 → 建游戏」存活），
## `_fade_sec` 只剩 Esc 取消那条路在用。
var _fade_sec: float = DEFAULT_FADE_SEC

var _load_paths: Array = []
var _load_progress: float = 0.0
## 显示值 = 真实进度（本轮改：不再追帧，也不再设最短展示时长）。
var _shown_progress: float = 0.0
var _loading_done: bool = false
## 进度条的「到位 y」（入场 / 出画都从它出发）。
var _bar_home_y: float = 0.0
## 入场动画是否已经开始 / 已经到位（加载可能在入场途中就满了）。
var _bar_intro_started: bool = false
var _bar_intro_done: bool = false
var _bar_tween: Tween = null
var _bar_out: bool = false
var _ready_to_enter: bool = false
var _entering: bool = false
var _hint_tween: Tween = null
var _breath_tween: Tween = null
var _layout_queued: bool = false


## @param p_campaign 已载入的战役（只用来读显示名）
## @param p_level    已载入的关卡（读简报 / 可玩阵营 / 目标 / 地图）
func setup(p_cfg: ConfigRes, p_font: Font, p_campaign, p_level) -> void:
	cfg = p_cfg
	font = p_font
	campaign = p_campaign
	level = p_level
	name = "LevelTransition"
	layer = LAYER
	_read_config()
	_entries = LevelBriefRes.playable_entries(level)
	if _entries.size() == 1:
		_selected = String((_entries[0] as Dictionary)["id"])
	_build()
	_start_loading()
	call_deferred("_layout")


func _read_config() -> void:
	if cfg == null:
		return
	_margin = cfg.num("menu.transition.margin", DEFAULT_MARGIN)
	_gap = cfg.num("menu.transition.gap", DEFAULT_GAP)
	_left_ratio = clampf(cfg.num("menu.transition.left_ratio", DEFAULT_LEFT_RATIO), 0.3, 0.8)
	_panel_alpha = clampf(cfg.num("menu.transition.panel_alpha", DEFAULT_PANEL_ALPHA), 0.2, 1.0)
	_title_size = cfg.int_val("menu.transition.title_size", DEFAULT_TITLE_SIZE)
	_subtitle_size = cfg.int_val("menu.transition.subtitle_size", DEFAULT_SUBTITLE_SIZE)
	_body_size = cfg.int_val("menu.transition.body_size", DEFAULT_BODY_SIZE)
	_card_height = cfg.num("menu.transition.card_height", DEFAULT_CARD_HEIGHT)
	_card_name_size = cfg.int_val("menu.transition.card_name_size", DEFAULT_CARD_NAME_SIZE)
	_card_goal_size = cfg.int_val("menu.transition.card_goal_size", DEFAULT_CARD_GOAL_SIZE)
	_bar_height = cfg.num("menu.transition.bar_height", DEFAULT_BAR_HEIGHT)
	_bar_bottom = cfg.num("menu.transition.bar_bottom", DEFAULT_BAR_BOTTOM)
	_bar_move_sec = maxf(0.0, cfg.num("menu.transition.bar_move_sec", DEFAULT_BAR_MOVE_SEC))
	_hint_size = cfg.int_val("menu.transition.hint_size", DEFAULT_HINT_SIZE)
	_hint_fade_sec = maxf(0.0, cfg.num("menu.transition.hint_fade_sec", DEFAULT_HINT_FADE_SEC))
	_fade_sec = cfg.num("menu.transition.fade_sec", DEFAULT_FADE_SEC)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

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
	_left_pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	_left_pnl.add_theme_stylebox_override("panel", _make_panel_style())
	_root.add_child(_left_pnl)

	_preview = MapPreviewRes.new()
	_preview.name = "MapPreview"
	_preview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview.offset_left = 10
	_preview.offset_right = -10
	_preview.offset_top = 10
	_preview.offset_bottom = -10
	_left_pnl.add_child(_preview)

	_right_pnl = Panel.new()
	_right_pnl.name = "InfoPnl"
	_right_pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	_right_pnl.add_theme_stylebox_override("panel", _make_panel_style())
	_root.add_child(_right_pnl)

	var pad := 26.0
	var box := VBoxContainer.new()
	box.name = "InfoBox"
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = pad
	box.offset_right = -pad
	box.offset_top = pad
	box.offset_bottom = -pad
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_pnl.add_child(box)

	_subtitle = _make_label("Subtitle", _subtitle_text(), _subtitle_size, ThemeRes.text_dim())
	box.add_child(_subtitle)
	_title = _make_label("Title", LevelBriefRes.level_name(level), _title_size, ThemeRes.text())
	box.add_child(_title)
	_rule = ColorRect.new()
	_rule.name = "Rule"
	_rule.color = ThemeRes.line()
	_rule.custom_minimum_size = Vector2(0, 1)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_rule)
	_body = _make_body(LevelBriefRes.briefing_text(level), _body_size, ThemeRes.text_dim())
	_body.name = "Briefing"
	box.add_child(_body)

	if _entries.size() > 1:
		_cards_box = VBoxContainer.new()
		_cards_box.name = "FactionCards"
		_cards_box.add_theme_constant_override("separation", 10)
		_cards_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_cards_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(_cards_box)
		for raw in _entries:
			_build_card(raw)
	elif _entries.size() == 1:
		var e: Dictionary = _entries[0]
		var line := _make_label("FactionLine",
			"出战：%s　（%s）" % [String(e["name"]), String(e["goal"])],
			_card_goal_size, ThemeRes.text_dim())
		box.add_child(line)
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(spacer)

	_progress = ProgressBar.new()
	_progress.name = "Progress"
	_progress.min_value = 0.0
	_progress.max_value = 100.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress.add_theme_stylebox_override("background", _make_bar_bg())
	_progress.add_theme_stylebox_override("fill", _make_bar_fill())
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

	_preview.setup(cfg, level)
	# ★ 单可玩阵营在 setup 里已经自动选中 ⇒ 缩略图直接按三色；多阵营先灰着，等选卡。
	_preview.set_view_faction(_selected)
	_layout()


func _build_card(raw: Dictionary) -> void:
	var fid := String(raw["id"])
	var pnl := Panel.new()
	pnl.name = "FactionCard_%s" % fid
	pnl.custom_minimum_size = Vector2(0, _card_height)
	pnl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	pnl.gui_input.connect(_on_card_input.bind(fid))
	_cards_box.add_child(pnl)

	var strip := ColorRect.new()
	strip.name = "Strip"
	strip.color = _faction_color(fid)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strip.anchor_bottom = 1.0
	strip.offset_left = 0
	strip.offset_right = 6
	strip.offset_top = 0
	strip.offset_bottom = 0
	pnl.add_child(strip)

	var name_lbl := _make_label("Name", String(raw["name"]), _card_name_size, ThemeRes.text())
	var goal_lbl := _make_label("Goal", String(raw["goal"]), _card_goal_size, ThemeRes.text_dim())
	# 卡片会吃掉右栏剩余高度（两张卡平分），所以两行字**垂直居中**，
	# 而不是钉在卡片顶部（那样卡片越高，下面越空）。
	var wrap := VBoxContainer.new()
	wrap.name = "CardText"
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.offset_left = 20
	wrap.offset_right = -20
	wrap.offset_top = 8
	wrap.offset_bottom = -8
	wrap.alignment = BoxContainer.ALIGNMENT_CENTER
	wrap.add_theme_constant_override("separation", 4)
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pnl.add_child(wrap)
	wrap.add_child(name_lbl)
	wrap.add_child(goal_lbl)

	_cards.append({"panel": pnl, "id": fid})
	_apply_card_style(pnl, fid)


func _make_label(node_name: String, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


## 简报正文。★ 用 `RichTextLabel` 而不是 `Label`：
##   带 `autowrap` 的 `Label` 在 VBox 里被问最小尺寸时会按「很窄的一列」报一个
##   一两千像素高的最小值（实测 104 个字报 1463px），把下面的阵营卡顶出面板；
##   `RichTextLabel(fit_content=false)` 的最小高度只按一行算，多余空间由容器给。
func _make_body(text: String, size: int, color: Color) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = false
	r.fit_content = true
	r.scroll_active = false
	r.text = text
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if font != null:
		r.add_theme_font_override("normal_font", font)
	r.add_theme_font_size_override("normal_font_size", size)
	r.add_theme_color_override("default_color", color)
	return r


func _subtitle_text() -> String:
	var cname := LevelBriefRes.campaign_name(campaign)
	var mode := LevelBriefRes.mode_text(level)
	if cname == "":
		return mode
	return "%s　·　%s" % [cname, mode]


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
	var bar_top: float = h - _margin - _bar_height - _bar_bottom
	var content_h: float = maxf(160.0, bar_top - _margin - 18.0)
	var inner_w: float = w - _margin * 2.0 - _gap
	var left_w: float = inner_w * _left_ratio
	var right_w: float = inner_w - left_w

	_left_pnl.position = Vector2(_margin, _margin)
	_left_pnl.size = Vector2(left_w, content_h)
	_right_pnl.position = Vector2(_margin + left_w + _gap, _margin)
	_right_pnl.size = Vector2(right_w, content_h)

	var bar_y: float = h - _margin - _bar_height
	_bar_home_y = bar_y
	_progress.size = Vector2(w - _margin * 2.0, _bar_height)
	_hint_hit.position = Vector2(_margin, bar_y)
	_hint_hit.size = _progress.size
	if not _bar_intro_started:
		_start_bar_intro()
	elif _bar_intro_done and not _bar_out:
		# 已到位 / 没有动画：跟随窗口尺寸
		_progress.position = Vector2(_margin, bar_y)
	else:
		# 入场中 / 出画中：y 归 Tween 管，这里只对齐 x
		_progress.position.x = _margin


# ------------------------------------------------------------------
# 加载 / 进度条
# ------------------------------------------------------------------

## 进度条从屏幕下方缓动升到 `_bar_home_y`。
## ★ 只在第一次排版时启动；加载可能在它跑完之前就 100% —— 那也要等它到位再下滑。
func _start_bar_intro() -> void:
	_bar_intro_started = true
	if _progress == null:
		return
	# 加载/出画已经结束（例如动效关掉时一帧就完成）⇒ 不要再把条升起来。
	if _loading_done or _bar_out:
		_bar_intro_done = true
		_progress.visible = false
		return
	if not ThemeRes.animations_enabled() or _bar_move_sec <= 0.0:
		_progress.position = Vector2(_margin, _bar_home_y)
		_bar_intro_done = true
		return
	_progress.position = Vector2(_margin, _root.size.y + _bar_height)
	_progress.visible = true
	_bar_tween = create_tween()
	_bar_tween.tween_property(_progress, "position:y", _bar_home_y, _bar_move_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await _bar_tween.finished
	if not is_instance_valid(self):
		return
	_bar_tween = null
	_bar_intro_done = true
	_progress.position = Vector2(_margin, _bar_home_y)


func _start_loading() -> void:
	_load_paths = [NEXT_SCENE_PATH]
	for p in _load_paths:
		var err: int = ResourceLoader.load_threaded_request(String(p))
		if err != OK:
			push_warning("过渡画面：预加载失败 %s（err=%d）" % [p, err])


func _process(_delta: float) -> void:
	if _loading_done:
		return
	var total: float = 0.0
	var count: int = 0
	for p in _load_paths:
		var arr: Array = []
		var status: int = ResourceLoader.load_threaded_get_status(String(p), arr)
		var one: float = 0.0
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
	# ★★ 实时：直接显示真实进度（不再用 180%/s 追帧，也没有 min_show_sec 保底时长）。
	_shown_progress = _load_progress * 100.0
	_progress.value = _shown_progress
	# 必须等入场升到位才开始「满 → 下滑」：否则加载一瞬间完成时，玩家看不到升起的条。
	if _load_progress >= 1.0 and _bar_intro_done:
		_finish_loading()


func _finish_loading() -> void:
	if _loading_done:
		return
	_loading_done = true
	_bar_out = true
	_progress.value = 100.0
	# ★★ 用户口径：提示必须在进度条**完全落画之后**才出现。
	#   所以整段下滑期间 alpha 钉死在 0（文本可以先写好，反正看不见）；
	#   条出画之后再走 `_reveal_hint()` 从头淡入。
	_hint_label.text = _compose_hint()
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
	await _bar_tween.finished
	if not is_instance_valid(self):
		return
	_bar_tween = null
	_progress.visible = false
	# ★★ 只有**完全移出画面**之后才允许进入（用户口径；也是没有保底时长之后的唯一门槛）。
	_ready_to_enter = true
	_refresh_hint()
	# ★★ 提示从这一刻开始淡入；淡入结束后才交给呼吸循环，两个 Tween 不抢同一条 alpha。
	await _reveal_hint()


## 进度条出画之后，把提示文字从透明淡入到 1（然后再开始呼吸）。
## ★ 单独一个函数是为了让「淡入」和「呼吸」严格串行：同时跑两个 Tween 写
##   `modulate:a` 的话，呼吸的第一段会把刚亮起来的字又压暗。
func _reveal_hint() -> void:
	if _hint_label == null:
		return
	# 淡入途中玩家已经点进入 / 按 Esc（或本层正在被收）：不要再起呼吸。
	if _entering or not _ready_to_enter:
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
	await tw.finished
	_hint_tween = null
	if not is_instance_valid(self):
		return
	if _entering:
		return
	_start_breathing()


func _start_breathing() -> void:
	if _hint_label == null or not _ready_to_enter or _entering:
		return
	# 动效总开关关掉 = 立刻到位：不呼吸，免得提示自己忽明忽暗。
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


func _compose_hint() -> String:
	if _entries.size() > 1 and _selected == "":
		return "————请选择阵营————"
	if _selected == "":
		return "————点击进入游戏————"
	var name := _selected_name()
	return "————作为%s进入游戏————" % name


func _selected_name() -> String:
	for raw in _entries:
		var d: Dictionary = raw
		if String(d["id"]) == _selected:
			return String(d["name"])
	return _selected


func _refresh_hint() -> void:
	if _hint_label == null:
		return
	_hint_label.text = _compose_hint()
	var can_enter: bool = _ready_to_enter and _selected != ""
	_hint_hit.mouse_filter = Control.MOUSE_FILTER_STOP if can_enter else Control.MOUSE_FILTER_IGNORE


# ------------------------------------------------------------------
# 阵营选择
# ------------------------------------------------------------------

func _on_card_input(event: InputEvent, fid: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	select_faction(fid)


## 选中一张阵营卡（幂等；同一张再点保持选中，不取消 —— 与街亭一致）。
func select_faction(fid: String) -> bool:
	var found := false
	for raw in _entries:
		if String((raw as Dictionary)["id"]) == fid:
			found = true
			break
	if not found:
		return false
	_selected = fid
	# ★★ 缩略图的「敌 / 友 / 己」随选择实时切换（未选时是灰的，见 map_preview）。
	if _preview != null:
		_preview.set_view_faction(fid)
	for e in _cards:
		var d: Dictionary = e
		_apply_card_style(d["panel"], String(d["id"]))
	_refresh_hint()
	return true


func _apply_card_style(pnl: Panel, fid: String) -> void:
	var on: bool = fid == _selected
	var c := _faction_color(fid)
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_top(), 0.92)
	if on:
		s.bg_color = ThemeRes.with_alpha(c, 0.16)
	s.border_color = ThemeRes.accent_bright() if on else ThemeRes.line_soft()
	s.set_border_width_all(2 if on else 1)
	s.set_corner_radius_all(2)
	pnl.add_theme_stylebox_override("panel", s)


func _faction_color(fid: String) -> Color:
	if level != null:
		var raw := String(level.faction_colors.get(fid, "")).strip_edges()
		if raw != "":
			return ConfigRes.parse_color(raw, ThemeRes.accent())
	if cfg != null:
		return cfg.faction_color(fid, "main")
	return ThemeRes.accent()


# ------------------------------------------------------------------
# 进入 / 取消
# ------------------------------------------------------------------

func _on_hint_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	_hint_hit.accept_event()
	_enter()


func _enter() -> void:
	if _entering or not _ready_to_enter or _selected == "":
		return
	_entering = true
	_hint_hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_kill_hint_tweens()
	# ★★ 黑屏转场由 main 统一负责（`_on_level_transition_enter`）：它必须跨
	#   「收掉本页 → 建游戏场景」存活，所以那一层不能建在这里。
	#   本页自己再淡出会把背后的菜单露出来，和黑屏打架 —— 这里只负责立刻发信号。
	#   Esc 取消不走黑屏，仍在 `cancel()` 里做一次本页淡出。
	enter_requested.emit(_selected)


## 收掉提示身上的两个 Tween（淡入 / 呼吸），让它停在当前 alpha 上。
## ★ 只 kill 不重置：紧接着要么整页被黑屏盖住（点进入），要么整页淡出（Esc），
##   都不会让玩家盯着一层停在半透明的字。
func _kill_hint_tweens() -> void:
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint_tween = null
	if _breath_tween != null and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = null


func cancel() -> void:
	if _entering:
		return
	_entering = true
	_kill_hint_tweens()
	if not ThemeRes.animations_enabled() or _fade_sec <= 0.0:
		cancelled.emit()
		return
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, _fade_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	if not is_instance_valid(self):
		return
	cancelled.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		cancel()


# ------------------------------------------------------------------
# 样式
# ------------------------------------------------------------------

func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), _panel_alpha)
	s.border_color = ThemeRes.line()
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	s.shadow_size = 12
	return s


func _make_bar_bg() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.92)
	s.border_color = ThemeRes.line_soft()
	s.set_border_width_all(1)
	s.set_corner_radius_all(2)
	return s


func _make_bar_fill() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = ThemeRes.accent()
	s.set_corner_radius_all(2)
	return s


# ------------------------------------------------------------------
# 给测试 / 排查用
# ------------------------------------------------------------------

func preview():
	return _preview


func selected_faction() -> String:
	return _selected


func ready_to_enter() -> bool:
	return _ready_to_enter


func loading_done() -> bool:
	return _loading_done


func progress_value() -> float:
	return _progress.value if _progress != null else 0.0


## 进度条当前 y / 它应该在的 y（测试：入场与出画）。
func bar_y() -> float:
	return _progress.position.y if _progress != null else 0.0


func bar_home_y() -> float:
	return _bar_home_y


func bar_intro_done() -> bool:
	return _bar_intro_done


## 进度条是否已经完全移出画面（允许进入的唯一门槛）。
func bar_offscreen() -> bool:
	if _progress == null or not _progress.visible:
		return true
	return _progress.position.y >= _root.size.y


func faction_card_count() -> int:
	return _cards.size()


func faction_card(i: int) -> Panel:
	if i < 0 or i >= _cards.size():
		return null
	return _cards[i]["panel"]


func hint_text() -> String:
	return _hint_label.text if _hint_label != null else ""


func hint_rect() -> Rect2:
	return _hint_hit.get_global_rect() if _hint_hit != null else Rect2()
