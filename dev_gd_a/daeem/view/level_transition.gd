## level_transition.gd —— ★★ 战役过渡画面（仿 nsoc 的章节入口 + 街亭双选）
##
## 布局（用户口径：战场缩略图在左、文本在右；进度条 + 点击进入提示；
##       多可玩阵营时，**阵营选项是描述面板下方的两块独立面板**）：
##   ┌────────────────────────────┬──────────────────────────────┐
##   │                            │  战役名 · 模式（小字）       │
##   │       战场缩略图           │  关卡名（大字）              │
##   │  （地形/区划线/目标区/     │  ─────────────               │
##   │    大本营/出生点）         │  简报正文（描述面板）        │
##   │                            ├───────────────┬──────────────┤
##   │                            │   [阵营 1]    │   [阵营 2]   │
##   └────────────────────────────┴───────────────┴──────────────┘
##   ────────────────────── 进度条 ──────────────────────────────
##   进度条先从屏幕下方缓动升起到位；真实加载进度实时填满；满后下滑出画面；
##   **完全移出画面之后**才允许点进入；提示文字也是**从那一刻起**才淡入
##   （「————作为X进入游戏————」/「请选择阵营」，淡入完再呼吸）。
##   ⚠️ 别把「提示淡入」和「进度条下滑」写成同时开始：EASE_OUT 的淡入前 1/3 就亮到
##      九成，条还在画面里时字已经能看见了（用户实测报回来的就是这个）。
##
## ★★ 多可玩阵营：**阵营选项不是描述面板里的按钮**，而是 N 块独立的 `Panel`，
##   在描述面板**下方水平并排**（用户口径）。边界与上面两块对齐 ——
##   左右 = 描述面板的左右，底边 = 左面板（缩略图）的底边，间距一律用同一个 `gap`；
##   描述面板只装「标题 + 简报」，高度按 `desc_ratio` 分，且**装得下自己的简报**。
##   面板默认不选（必须选一张），选中 = **琥珀金边加粗** + 琥珀淡底；
##   底部提示在未选时是「请选择阵营」且不可点。
##   仿的是 nsoc 街亭的「双检阅面板 + 互斥单选 + 底部提示」，选中态用主题的琥珀金。
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
## 阵营面板行的**最小**高度（面板本身不设最小尺寸：真正的高度由 `_layout()` 分）。
const DEFAULT_FACTION_ROW_MIN_HEIGHT := 148.0
const DEFAULT_FACTION_NAME_SIZE := 28
const DEFAULT_FACTION_GOAL_SIZE := 18
## 描述面板占「右列可用高度（扣掉一个 gap）」的比例 —— **只在下方还有阵营面板时生效**。
## 剩下的全给阵营面板行；两者都还要装得下自己的内容（见 `_layout()`）。
## ★ 0.76 是按用户口径「阵营选择的面板竖直方向压缩一段」定的（1080 高下约 216px）。
const DEFAULT_DESC_RATIO := 0.76
## 描述面板的最小高度：窗口再矮也不能把它压没（用户口径：边界要能看出一块面板）。
const MIN_DESC_HEIGHT := 170.0
## 面板滑入（用户口径：过渡界面的**所有**面板**同时**滑入）：同一帧起跑、同一时长。
## 左面板从左边滑进来、描述面板从右边滑进来、阵营面板自下而上升起。
const DEFAULT_PANEL_SLIDE_SEC := 0.42
## 相邻面板的错开时长 —— **默认 0 = 全部同时**（用户口径）；留这个键只是给以后调手感用。
const DEFAULT_PANEL_SLIDE_STAGGER := 0.0
## 滑入时同时从透明淡到不透明的时长（比位移短：先看得见轮廓，再滑到位）。
const PANEL_FADE_SEC := 0.30
## 描述面板内容四周的留白（标题 / 简报离面板边）。
const INFO_PAD := 26.0
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
## 描述面板里的那一列（标题 / 细线 / 简报）。★ 阵营面板**不在**它里面，见 `_faction_row`。
var _info_box: VBoxContainer = null
## ★★ 阵营面板行：描述面板下方、水平并排的 N 块独立面板（多可玩阵营时才建）。
var _faction_row: Control = null
var _preview = null
var _subtitle: Label = null
var _title: Label = null
var _rule: ColorRect = null
var _body: RichTextLabel = null
var _progress: ProgressBar = null
var _hint_hit: Control = null
var _hint_label: Label = null

var _entries: Array = []
## [{panel: Panel, id: String}] —— 每块阵营面板。
var _panels: Array = []
var _selected: String = ""

var _margin: float = DEFAULT_MARGIN
var _gap: float = DEFAULT_GAP
var _left_ratio: float = DEFAULT_LEFT_RATIO
var _panel_alpha: float = DEFAULT_PANEL_ALPHA
var _title_size: int = DEFAULT_TITLE_SIZE
var _subtitle_size: int = DEFAULT_SUBTITLE_SIZE
var _body_size: int = DEFAULT_BODY_SIZE
var _faction_row_min: float = DEFAULT_FACTION_ROW_MIN_HEIGHT
var _faction_name_size: int = DEFAULT_FACTION_NAME_SIZE
var _faction_goal_size: int = DEFAULT_FACTION_GOAL_SIZE
var _desc_ratio: float = DEFAULT_DESC_RATIO
var _panel_slide_sec: float = DEFAULT_PANEL_SLIDE_SEC
var _panel_slide_stagger: float = DEFAULT_PANEL_SLIDE_STAGGER
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
## 面板滑入：只播一次（排版**定稿**之后）；`_intro_active` 期间
## **位置归 Tween 管** —— `_layout()` 不许再写 position，否则窗口一变化就把动画掰回终点。
var _intro_started: bool = false
var _intro_active: bool = false
var _intro_tween: Tween = null
## 排版定稿判定：上一遍量到的「简报需要多高」/ 是否已稳定 / 已经排了几遍。
## 见 `_layout()` 里 `need` 的说明 —— 首帧那个数不可信，会导致滑入结束时尺寸突变。
var _layout_natural: float = -1.0
var _layout_settled: bool = false
var _layout_passes: int = 0


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
	# ★ 阵营行的下限夹一下：配成 0 的话描述面板会吃掉整列、阵营面板就没了。
	_faction_row_min = clampf(
		cfg.num("menu.transition.faction_row_min_height", DEFAULT_FACTION_ROW_MIN_HEIGHT),
		60.0, 600.0)
	_faction_name_size = cfg.int_val("menu.transition.faction_name_size", DEFAULT_FACTION_NAME_SIZE)
	_faction_goal_size = cfg.int_val("menu.transition.faction_goal_size", DEFAULT_FACTION_GOAL_SIZE)
	_desc_ratio = clampf(cfg.num("menu.transition.desc_ratio", DEFAULT_DESC_RATIO), 0.4, 0.88)
	_panel_slide_sec = maxf(0.0, cfg.num("menu.transition.panel_slide_sec", DEFAULT_PANEL_SLIDE_SEC))
	_panel_slide_stagger = maxf(
		0.0, cfg.num("menu.transition.panel_slide_stagger", DEFAULT_PANEL_SLIDE_STAGGER))
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
	# ★ 先透明：排版要两遍才定稿（首帧量的简报高度不可信），这期间别让错误的尺寸闪出来。
	#   滑入时从 0 淡到 1；动效关掉则 `_show_panels_now()` 直接亮出来。
	_left_pnl.modulate.a = 0.0
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
	_right_pnl.modulate.a = 0.0
	_root.add_child(_right_pnl)

	_info_box = VBoxContainer.new()
	_info_box.name = "InfoBox"
	_info_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_info_box.offset_left = INFO_PAD
	_info_box.offset_right = -INFO_PAD
	_info_box.offset_top = INFO_PAD
	_info_box.offset_bottom = -INFO_PAD
	_info_box.add_theme_constant_override("separation", 10)
	_info_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_right_pnl.add_child(_info_box)

	_subtitle = _make_label("Subtitle", _subtitle_text(), _subtitle_size, ThemeRes.text_dim())
	_info_box.add_child(_subtitle)
	_title = _make_label("Title", LevelBriefRes.level_name(level), _title_size, ThemeRes.text())
	_info_box.add_child(_title)
	_rule = ColorRect.new()
	_rule.name = "Rule"
	_rule.color = ThemeRes.line()
	_rule.custom_minimum_size = Vector2(0, 1)
	_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info_box.add_child(_rule)
	_body = _make_body(LevelBriefRes.briefing_text(level), _body_size, ThemeRes.text_dim())
	_body.name = "Briefing"
	_info_box.add_child(_body)

	if _entries.size() > 1:
		# ★★ 阵营面板行：**挂在 `_root` 上，不是描述面板的子里**（用户口径：
		#   把两个选项从描述面板里抽出来）。位置/尺寸全由 `_layout()` 给，
		#   于是它的左右边 = 描述面板的左右边、底边 = 左面板的底边。
		# ⚠️ 用普通 `Control` 而不是 `HBoxContainer`：容器会把每块取整到整像素，
		#   最后一块的右边界就会比描述面板差零点几像素（见 `_layout_faction_panels`）。
		_faction_row = Control.new()
		_faction_row.name = "FactionRow"
		_faction_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(_faction_row)
		for raw in _entries:
			_build_faction_panel(raw)
	elif _entries.size() == 1:
		var e: Dictionary = _entries[0]
		var line := _make_label("FactionLine",
			"出战：%s　（%s）" % [String(e["name"]), String(e["goal"])],
			_faction_goal_size, ThemeRes.text_dim())
		_info_box.add_child(line)
		var spacer := Control.new()
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_info_box.add_child(spacer)

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


## 一块**阵营面板**（不是按钮）：底/边/影与其他面板同一套，左侧一条本阵营色的竖条，
## 里面两行字（阵营名 / 目标）垂直居中；点整块面板即选中。
func _build_faction_panel(raw: Dictionary) -> void:
	var fid := String(raw["id"])
	var pnl := Panel.new()
	pnl.name = "FactionPanel_%s" % fid
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	pnl.gui_input.connect(_on_faction_panel_input.bind(fid))
	# 与两块大面板一样：先透明，等排版定稿后跟滑入一起淡入。
	pnl.modulate.a = 0.0
	_faction_row.add_child(pnl)

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

	var name_lbl := _make_label("Name", String(raw["name"]), _faction_name_size, ThemeRes.text())
	var goal_lbl := _make_label("Goal", String(raw["goal"]), _faction_goal_size, ThemeRes.text_dim())
	# 面板吃满整行高度（行高由 `_layout()` 给），所以两行字**垂直居中**，
	# 而不是钉在面板顶部（那样面板越高，下面越空）。
	var wrap := VBoxContainer.new()
	wrap.name = "PanelText"
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

	_panels.append({"panel": pnl, "id": fid})
	_apply_panel_style(pnl, fid)


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
##   一两千像素高的最小值（实测 104 个字报 1463px），把描述面板顶到装不下；
##   `RichTextLabel(fit_content=true)` 的最小高度按**实际换行后**的内容算，
##   而 `_layout()` 正是拿它来量「描述面板至少要有多高」。
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
	var right_x: float = _margin + left_w + _gap

	# ★ 先按「描述面板吃满整列」排一次：要拿**最终宽度**去量简报换行后的高度
	#   （RichTextLabel 的最小高度是按当前宽度算的，宽度还是 0 时会量出一个天文数字）。
	_right_pnl.size = Vector2(right_w, content_h)
	var desc_h: float = content_h
	var row_h: float = 0.0
	# ★★ 「简报要占多高」这个数**首帧不可信**：容器还没把宽度分给简报控件，
	#    RichTextLabel 在宽度 0 时按「逐字换行」报一个天文数字。于是首帧描述面板
	#    吃满、阵营行只剩最小值；下一遍排版量准了再改 —— 画面上就是
	#    「滑入到位时阵营选项突然向上跳、还变大」。所以：**连续两遍量到同一个数才算定稿**，
	#    定稿之前不写尺寸、也不起滑入（见下面 `_layout_settled`）。
	var need: float = _desc_natural_height()
	if _faction_row != null:
		var avail: float = maxf(0.0, content_h - _gap)
		var min_row: float = minf(_faction_row_min, avail * 0.45)
		var desc_lo: float = minf(MIN_DESC_HEIGHT, avail - min_row)
		var desc_hi: float = maxf(desc_lo, avail - min_row)
		desc_h = avail * _desc_ratio
		# ★ 描述面板不能比它自己的内容还矮：否则简报会画到下面的阵营面板上。
		desc_h = maxf(desc_h, need)
		desc_h = clampf(desc_h, desc_lo, desc_hi)
		row_h = maxf(0.0, avail - desc_h)

	# ★ 三块的目标位置（滑入动画的终点也是这里）。
	#   阵营行紧贴描述面板下方、左右与它同宽 ⇒ 外边界与上面两块**逐边对齐**
	#   （左右 = 描述面板，底边 = 左面板）。
	var left_pos := Vector2(_margin, _margin)
	var right_pos := Vector2(right_x, _margin)
	var row_pos := Vector2(right_x, _margin + desc_h + _gap)

	_left_pnl.size = Vector2(left_w, content_h)
	_right_pnl.size = Vector2(right_w, desc_h)
	if _faction_row != null:
		_faction_row.size = Vector2(right_w, row_h)

	if not _intro_active:
		# 正常排版 / 滑入结束之后：位置一律以这里为准（唯一真相）。
		_left_pnl.position = left_pos
		_right_pnl.position = right_pos
		if _faction_row != null:
			_faction_row.position = row_pos
			_layout_faction_panels(right_w, row_h)
	# ★ 滑入进行中则**什么都不写**：位置归 `_play_panel_slide()` 的 Tween 管，
	#   这里再写一次就会把动画掰回终点（窗口在这 0.4s 内被缩放时才走得到）。

	# ★ 排版是否定稿（见上面 `need` 的说明）：没定稿就再排一遍，定稿后才播滑入。
	var natural_moved: bool = absf(need - _layout_natural) > 0.5
	_layout_natural = need
	if _faction_row != null and natural_moved and _layout_passes < 6:
		_layout_passes += 1
		_layout_settled = false
		call_deferred("_layout")
	else:
		# 定稿：计数清零 —— 之后窗口尺寸再变，还能重新迭代（最多 6 遍）。
		_layout_passes = 0
		_layout_settled = true

	if _layout_settled and not _intro_started:
		_intro_started = true
		if ThemeRes.animations_enabled() and _panel_slide_sec > 0.0:
			# ★ 延后一帧再起动画：这一遍排版刚把尺寸/位置算好，Tween 要读的是「终点」。
			call_deferred("_play_panel_slide")
		else:
			# 动效关掉：面板一开始是透明的（等滑入才亮），这里直接亮出来。
			_show_panels_now()

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


## 描述面板「按内容算」至少要多高（标题 + 细线 + 简报 + 上下留白）。
## ★ 只在多可玩阵营、下方还有阵营面板时才用得上：单阵营时描述面板本来就吃满整列。
func _desc_natural_height() -> float:
	if _info_box == null:
		return 0.0
	return _info_box.get_combined_minimum_size().y + INFO_PAD * 2.0


## 把 N 块阵营面板**手工**摆进面板行：等宽、间距 = gap、第一块贴左、最后一块贴右。
## ⚠️ 不用 `HBoxContainer`：容器会把每块取整到整像素，总宽差下来的那零点几像素
##   全留给最右边 —— 最后一块的右边界就与描述面板差 0.5~1 px，用户口径（边界对齐）就不成立了。
func _layout_faction_panels(row_w: float, row_h: float) -> void:
	var n: int = _panels.size()
	if n <= 0:
		return
	var cell: float = maxf(0.0, (row_w - _gap * float(n - 1)) / float(n))
	for i in n:
		var pnl: Panel = _panels[i]["panel"]
		pnl.position = Vector2(float(i) * (cell + _gap), 0.0)
		pnl.size = Vector2(cell, row_h)


## ★★ 面板滑入（用户口径：过渡界面的**所有**面板**在同一时间**滑入）。
##   左面板从左边、描述面板从右边、阵营面板自下而上，全部同一帧起跑、同一时长；
##   位移用 EASE_OUT，同时从透明淡到不透明。
## ★ 只在排版**定稿**之后播一次（`_layout()` 里 deferred 调进来）——
##   定稿之前尺寸还会变，先播就会在到位时「向上吸附 + 变大」。
## ★ 播完把每块面板**钉在捕获到的终点**上（不再重算），再跑一次 `_layout()` 兜尺寸。
func _play_panel_slide() -> void:
	if not is_instance_valid(self) or _root == null:
		return
	if not ThemeRes.animations_enabled() or _panel_slide_sec <= 0.0:
		return
	var items := _slide_items()
	if items.is_empty():
		return
	_intro_active = true
	var tw := create_tween()
	tw.set_parallel(true)
	var delay := 0.0
	for it in items:
		var pnl: Control = it["panel"]
		pnl.position = it["from"]
		pnl.modulate.a = 0.0
		tw.tween_property(pnl, "position", it["to"], _panel_slide_sec) \
			.set_delay(delay).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(pnl, "modulate:a", 1.0, minf(PANEL_FADE_SEC, _panel_slide_sec)) \
			.set_delay(delay)
		delay += _panel_slide_stagger
	_intro_tween = tw
	await tw.finished
	if not is_instance_valid(self):
		return
	_intro_tween = null
	# ★ 收尾：位置/不透明度**直接写回捕获的终点**（浮点 Tween 落点不会比排版值差半像素，
	#   但写回来能保证「到位的最后一帧」与「排版值」完全一致，不会有一帧吸附）。
	for it in items:
		var pnl: Control = it["panel"]
		pnl.position = it["to"]
		pnl.modulate.a = 1.0
	_intro_active = false
	# ★ 定稿后的这次 `_layout()` 不会改尺寸（`need` 已稳定）—— 只是把尺寸再兜一遍。
	_layout()


## 动效关掉 / 不能播滑入时，把面板直接亮出来（构建时它们先透明，
## 免得「首帧那个还没量准的排版」在屏幕上闪一下）。
func _show_panels_now() -> void:
	for c in _all_panels():
		(c as Control).modulate.a = 1.0


func _all_panels() -> Array:
	var arr: Array = []
	if _left_pnl != null:
		arr.append(_left_pnl)
	if _right_pnl != null:
		arr.append(_right_pnl)
	for e in _panels:
		arr.append(e["panel"])
	return arr


## 每块面板的滑入参数：`to` = 当前排版给的位置（终点），`from` = 屏幕外那一侧（起点）。
func _slide_items() -> Array:
	var items: Array = []
	if _left_pnl != null:
		var to_left := _left_pnl.position
		items.append({
			"panel": _left_pnl,
			"to": to_left,
			"from": to_left + Vector2(-(_left_pnl.size.x + _margin), 0.0),
		})
	if _right_pnl != null:
		var to_right := _right_pnl.position
		items.append({
			"panel": _right_pnl,
			"to": to_right,
			"from": to_right + Vector2(_right_pnl.size.x + _margin, 0.0),
		})
	if _faction_row != null:
		for e in _panels:
			var pnl: Panel = e["panel"]
			# 局部坐标（父节点是阵营面板行）：从行底下方升上来。
			var to_panel := pnl.position
			items.append({
				"panel": pnl,
				"to": to_panel,
				"from": to_panel + Vector2(0.0, _faction_row.size.y + _gap),
			})
	return items


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

func _on_faction_panel_input(event: InputEvent, fid: String) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	select_faction(fid)


## 选中一块阵营面板（幂等；同一块再点保持选中，不取消 —— 与街亭一致）。
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
	for e in _panels:
		var d: Dictionary = e
		_apply_panel_style(d["panel"], String(d["id"]))
	_refresh_hint()
	return true


## 阵营面板的样式：**底 / 边 / 影与其他面板完全同一套**（它们是并列的面板，不是卡片），
## 选中按用户配色方案来：**琥珀金只给「当前选中」** —— 所以选中态是
## 琥珀淡底 + 亮琥珀 2px 边；阵营身份靠左边那条本阵营色竖条，不靠大面积染色。
func _apply_panel_style(pnl: Panel, fid: String) -> void:
	var on: bool = fid == _selected
	var s := _make_panel_style()
	if on:
		s.bg_color = ThemeRes.with_alpha(ThemeRes.accent(), 0.14)
		s.border_color = ThemeRes.accent_bright()
		s.set_border_width_all(2)
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
	# 玩家可能在滑入那 0.4s 里就按了 Esc：先把滑入停住，再整页淡出
	# （否则面板还会在淡出的同时继续往里滑，看起来像画面在抖）。
	if _intro_tween != null and _intro_tween.is_valid():
		_intro_tween.kill()
	_intro_tween = null
	_intro_active = false
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


func faction_panel_count() -> int:
	return _panels.size()


func faction_panel(i: int) -> Panel:
	if i < 0 or i >= _panels.size():
		return null
	return _panels[i]["panel"]


## 阵营面板行（多可玩阵营时才存在；单阵营为 null）。
func faction_row() -> Control:
	return _faction_row


## 两块大面板：左边缩略图 / 右边描述（测试要对齐关系直接量它们的 `get_global_rect()`）。
func map_panel() -> Panel:
	return _left_pnl


func info_panel() -> Panel:
	return _right_pnl


## 描述面板「按内容算」至少要多高（测试：面板高度不许比它矮）。
func desc_natural_height() -> float:
	return _desc_natural_height()


## 面板滑入动效是否已经在跑 / 是否已经播过（测试用）。
func panel_slide_active() -> bool:
	return _intro_active


func panel_slide_started() -> bool:
	return _intro_started


## 外留白 / 面板间距（测试量对齐时用同一份数值）。
func margin() -> float:
	return _margin


func gap() -> float:
	return _gap


func hint_text() -> String:
	return _hint_label.text if _hint_label != null else ""


func hint_rect() -> Rect2:
	return _hint_hit.get_global_rect() if _hint_hit != null else Rect2()
