## outcome_overlay.gd —— ★★ 胜利 / 失败结算画面（王冠 + 宝石 / 裂纹 + 横幅 + 三颗按钮）
##
## 需求原文（2026.10.22）：
##   胜利：王冠渐入到屏幕中心 → 宝石渐入并镶嵌到王冠中央 → 王冠下方水平拉开横幅
##         → 横幅表面渐显「胜利」→ 横幅下方呼吸显示「——点击任意处继续——」；
##   失败：王冠渐入 → 破裂（只出现裂纹并整体变暗）→ 横幅拉开 → 渐显「失败」→ 同样的提示；
##   点击任意处 → 提示渐隐、横幅中渐显 观察 / 统计 / 继续（只有「继续」有逻辑：回主菜单）。
##
## ★★ 本文件只做三件事（与 view/quit_confirm.gd 同一条分层）：
##   ① 搭 Control 树（背景 / 王冠 / 宝石 / 横幅 / 文字 / 按钮）；
##   ② 按顺序播 Tween；
##   ③ 发 `continue_pressed` —— **自己不拆场景、不认识 main / world**。
##   真正「回主菜单」是 game_scene3d → main 的流程（见 view/main.gd 的 return_to_menu）。
##
## ★ 图形全部在 view/outcome_art.gd 里自绘（无贴图）：王冠 / 宝石 / 横幅三块只认进度。
##
## ★ 颜色不在这里写死：胜 = theme.accent / accent_bright，负 = theme.warning，
##   与全项目「亮琥珀只给强调、红只给失败」的配色口径一致（见 view/theme.gd）。
##
## ★★ 动效总开关（ThemeRes.animations_enabled）关掉时：所有段直接到位，
##   但「点击任意处 → 按钮出现」这一步仍然保留（那是**交互**，不是动效）。
##
## ⚠️ 跨文件引用只用本文件的 preload 常量（`--script` 下全局 class_name 不可用）。
extends CanvasLayer

## 玩家点了「继续」。★ 只发信号；拆场景 / 回主菜单由 game_scene3d / main 接。
signal continue_pressed
## 三颗按钮已经渐显出来（测试与排查用；正常流程不需要等它）。
signal buttons_shown

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const MenuBackgroundRes = preload("res://view/menu_background.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const OutcomeArtRes = preload("res://view/outcome_art.gd")

## 盖在 HUD（1）之上、退出确认（200）之下。主菜单 / 过渡页此时已经隐藏。
const LAYER := 180

const RESULT_WIN := "win"
const RESULT_LOSE := "lose"

## ---- 兜底值（config 缺键时用；与 data/config.json 的 outcome 段一一对应）----
const DEFAULT_WIN_WORD := "胜利"
const DEFAULT_LOSE_WORD := "失败"
const DEFAULT_HINT := "——点击任意处继续——"
const DEFAULT_BUTTONS := ["观察", "统计", "继续"]
const DEFAULT_WORD_SIZE := 58
const DEFAULT_HINT_SIZE := 24
const DEFAULT_BUTTON_SIZE := 22
const DEFAULT_CROWN_W := 380.0
const DEFAULT_CROWN_H := 250.0
const DEFAULT_GEM_SIZE := 96.0
const DEFAULT_BANNER_W := 760.0
const DEFAULT_BANNER_H := 164.0
const DEFAULT_BANNER_GAP := 34.0
const DEFAULT_BUTTON_W := 150.0
const DEFAULT_BUTTON_H := 48.0
const DEFAULT_BUTTON_GAP := 26.0
const DEFAULT_HINT_GAP := 22.0
const DEFAULT_DIM_ALPHA := 0.86
const DEFAULT_BACKDROP_FADE := 0.30
const DEFAULT_CROWN_FADE := 0.45
const DEFAULT_GEM_FADE := 0.40
const DEFAULT_GEM_RISE := 60.0
const DEFAULT_CRACK_SEC := 0.65
const DEFAULT_BANNER_OPEN := 0.50
const DEFAULT_WORD_FADE := 0.35
const DEFAULT_HINT_FADE := 0.30
const DEFAULT_HINT_OUT := 0.20
const DEFAULT_BUTTONS_FADE := 0.30
const DEFAULT_BREATH_SEC := 1.1
const DEFAULT_BREATH_MIN := 0.35
const DEFAULT_EXIT_FADE := 0.25

var cfg: ConfigRes = null
var font: Font = null

var _result: String = RESULT_WIN
var _open: bool = false
var _closing: bool = false
var _ready_for_click: bool = false
var _buttons_revealed: bool = false

var _root: Control = null
var _bg: Control = null
var _content: Control = null
var _crown = null
var _gem = null
var _banner = null
var _word: Label = null
var _hint: Label = null
var _buttons_box: HBoxContainer = null
var _buttons: Array = []

var _backdrop_tween: Tween = null
var _hint_tween: Tween = null
var _breath_tween: Tween = null
var _exit_tween: Tween = null

## ---- 取自 config 的尺寸 / 时长 ----
var _win_word: String = DEFAULT_WIN_WORD
var _lose_word: String = DEFAULT_LOSE_WORD
var _hint_text: String = DEFAULT_HINT
var _button_labels: Array = DEFAULT_BUTTONS.duplicate()
var _word_size: int = DEFAULT_WORD_SIZE
var _hint_size: int = DEFAULT_HINT_SIZE
var _button_size: int = DEFAULT_BUTTON_SIZE
var _crown_w: float = DEFAULT_CROWN_W
var _crown_h: float = DEFAULT_CROWN_H
var _gem_size: float = DEFAULT_GEM_SIZE
var _banner_w: float = DEFAULT_BANNER_W
var _banner_h: float = DEFAULT_BANNER_H
var _banner_gap: float = DEFAULT_BANNER_GAP
var _button_w: float = DEFAULT_BUTTON_W
var _button_h: float = DEFAULT_BUTTON_H
var _button_gap: float = DEFAULT_BUTTON_GAP
var _hint_gap: float = DEFAULT_HINT_GAP
var _dim_alpha: float = DEFAULT_DIM_ALPHA
var _backdrop_fade: float = DEFAULT_BACKDROP_FADE
var _crown_fade: float = DEFAULT_CROWN_FADE
var _gem_fade: float = DEFAULT_GEM_FADE
var _gem_rise: float = DEFAULT_GEM_RISE
var _crack_sec: float = DEFAULT_CRACK_SEC
var _banner_open: float = DEFAULT_BANNER_OPEN
var _word_fade: float = DEFAULT_WORD_FADE
var _hint_fade: float = DEFAULT_HINT_FADE
var _hint_out: float = DEFAULT_HINT_OUT
var _buttons_fade: float = DEFAULT_BUTTONS_FADE
var _breath_sec: float = DEFAULT_BREATH_SEC
var _breath_min: float = DEFAULT_BREATH_MIN
var _exit_fade: float = DEFAULT_EXIT_FADE


## 由宿主（`view/game_scene3d.gd`）在 add_child 之后调一次。
##
## @param p_result "win" / "lose"（其它值明确报错并退回 win —— 不猜）
func setup(p_cfg: ConfigRes, p_font: Font, p_result: String) -> void:
	cfg = p_cfg
	font = p_font
	if p_result != RESULT_WIN and p_result != RESULT_LOSE:
		push_error("结算画面：result 只能是 win / lose（收到 %s）" % p_result)
		p_result = RESULT_WIN
	_result = p_result
	name = "OutcomeOverlay"
	layer = LAYER
	_read_config()
	_build()
	_open = true
	_play()


# ------------------------------------------------------------------
# 对外状态（测试 / 排查）
# ------------------------------------------------------------------

func is_open() -> bool:
	return _open


func result() -> String:
	return _result


func word_text() -> String:
	return _word.text if _word != null else ""


func hint_text() -> String:
	return _hint.text if _hint != null else ""


func crown():
	return _crown if _crown != null and is_instance_valid(_crown) else null


func gem():
	return _gem if _gem != null and is_instance_valid(_gem) else null


func banner():
	return _banner if _banner != null and is_instance_valid(_banner) else null


func word_label() -> Label:
	return _word if _word != null and is_instance_valid(_word) else null


func hint_label() -> Label:
	return _hint if _hint != null and is_instance_valid(_hint) else null


func buttons() -> Array:
	var out: Array = []
	for b in _buttons:
		if b != null and is_instance_valid(b):
			out.append(b)
	return out


func button_labels() -> Array:
	var out: Array = []
	for b in buttons():
		out.append(String((b as Button).text))
	return out


func buttons_revealed() -> bool:
	return _buttons_revealed


## 现在点屏幕任意处会不会进入「按钮渐显」那一拍。
func ready_for_click() -> bool:
	return _open and _ready_for_click and not _buttons_revealed


## ★ 模拟「玩家点了屏幕任意处」。输入路由与测试都走它，
##   这样判定与动作只有一份（与 start_screen.dismiss_intro 同一条口径）。
## @return bool 这一下是否真的受理了
func accept_click() -> bool:
	if not ready_for_click():
		return false
	_ready_for_click = false
	_buttons_revealed = true
	_reveal_buttons()
	return true


# ------------------------------------------------------------------
# 读配置
# ------------------------------------------------------------------

func _read_config() -> void:
	if cfg == null:
		return
	_win_word = cfg.str_val("outcome.win_word", DEFAULT_WIN_WORD)
	_lose_word = cfg.str_val("outcome.lose_word", DEFAULT_LOSE_WORD)
	_hint_text = cfg.str_val("outcome.hint", DEFAULT_HINT)
	_word_size = cfg.int_val("outcome.word_size", DEFAULT_WORD_SIZE)
	_hint_size = cfg.int_val("outcome.hint_size", DEFAULT_HINT_SIZE)
	_button_size = cfg.int_val("outcome.button_size", DEFAULT_BUTTON_SIZE)
	_crown_w = maxf(80.0, cfg.num("outcome.crown_width", DEFAULT_CROWN_W))
	_crown_h = maxf(60.0, cfg.num("outcome.crown_height", DEFAULT_CROWN_H))
	_gem_size = maxf(24.0, cfg.num("outcome.gem_size", DEFAULT_GEM_SIZE))
	_banner_w = maxf(240.0, cfg.num("outcome.banner_width", DEFAULT_BANNER_W))
	_banner_h = maxf(96.0, cfg.num("outcome.banner_height", DEFAULT_BANNER_H))
	_banner_gap = maxf(0.0, cfg.num("outcome.banner_gap", DEFAULT_BANNER_GAP))
	_button_w = maxf(80.0, cfg.num("outcome.button_w", DEFAULT_BUTTON_W))
	_button_h = maxf(32.0, cfg.num("outcome.button_h", DEFAULT_BUTTON_H))
	_button_gap = maxf(0.0, cfg.num("outcome.button_gap", DEFAULT_BUTTON_GAP))
	_hint_gap = maxf(0.0, cfg.num("outcome.hint_gap", DEFAULT_HINT_GAP))
	_dim_alpha = clampf(cfg.num("outcome.dim_alpha", DEFAULT_DIM_ALPHA), 0.0, 1.0)
	_backdrop_fade = maxf(0.0, cfg.num("outcome.backdrop_fade_sec", DEFAULT_BACKDROP_FADE))
	_crown_fade = maxf(0.0, cfg.num("outcome.crown_fade_sec", DEFAULT_CROWN_FADE))
	_gem_fade = maxf(0.0, cfg.num("outcome.gem_fade_sec", DEFAULT_GEM_FADE))
	_gem_rise = maxf(0.0, cfg.num("outcome.gem_rise_px", DEFAULT_GEM_RISE))
	_crack_sec = maxf(0.0, cfg.num("outcome.crack_sec", DEFAULT_CRACK_SEC))
	_banner_open = maxf(0.0, cfg.num("outcome.banner_open_sec", DEFAULT_BANNER_OPEN))
	_word_fade = maxf(0.0, cfg.num("outcome.word_fade_sec", DEFAULT_WORD_FADE))
	_hint_fade = maxf(0.0, cfg.num("outcome.hint_fade_sec", DEFAULT_HINT_FADE))
	_hint_out = maxf(0.0, cfg.num("outcome.hint_out_sec", DEFAULT_HINT_OUT))
	_buttons_fade = maxf(0.0, cfg.num("outcome.buttons_fade_sec", DEFAULT_BUTTONS_FADE))
	_breath_sec = maxf(0.1, cfg.num("outcome.breath_sec", DEFAULT_BREATH_SEC))
	_breath_min = clampf(cfg.num("outcome.breath_min", DEFAULT_BREATH_MIN), 0.0, 1.0)
	_exit_fade = maxf(0.0, cfg.num("outcome.exit_fade_sec", DEFAULT_EXIT_FADE))
	_button_labels = _read_buttons()


## `outcome.buttons` 必须是三项；缺项用兜底补、多项只取前三项。
func _read_buttons() -> Array:
	var out: Array = []
	var raw: Variant = cfg.get_path_value("outcome.buttons") if cfg != null else null
	if typeof(raw) == TYPE_ARRAY:
		for v in (raw as Array):
			var s := String(v)
			if s != "":
				out.append(s)
			if out.size() >= 3:
				break
	while out.size() < 3:
		out.append(DEFAULT_BUTTONS[out.size()])
	return out


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "OutcomeRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# ★ 铺满整页 + STOP：点按钮之外的地方都归「点击任意处」。
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.gui_input.connect(_on_root_input)
	add_child(_root)

	# 背景：复用进入界面的「渐变底 + 中心辉光」，只把它压成半透明。
	# ★ 它自己 `_ready` 里会把 mouse_filter 设成 STOP；我们是收点击的那一层，
	#   所以必须在那之后改回 IGNORE（见下面那段为什么接 `ready`）。
	_bg = MenuBackgroundRes.new()
	_bg.name = "Backdrop"
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bg.modulate.a = 0.0
	# ★★ `menu_background.gd` 在自己的 `_ready` 里把 mouse_filter 设成 STOP
	#   （它平时是整页的收点击层）。这里必须在 **ready 之后**再改回 IGNORE，
	#   否则它会把「点击任意处」全部吃掉 —— 实测症状就是「点屏幕没反应」。
	#   `ready` 信号在 `_ready` 通知之后发，所以先接、后 add。
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.ready.connect(func() -> void:
		if _bg != null and is_instance_valid(_bg):
			_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE)
	_root.add_child(_bg)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_content = Control.new()
	_content.name = "OutcomeContent"
	_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_content)

	_build_crown()
	_build_gem()
	_build_banner()
	_build_hint()


func _build_crown() -> void:
	_crown = OutcomeArtRes.Crown.new()
	_crown.name = "OutcomeCrown"
	_crown.anchor_left = 0.5
	_crown.anchor_right = 0.5
	_crown.anchor_top = 0.5
	_crown.anchor_bottom = 0.5
	_crown.offset_left = -_crown_w * 0.5
	_crown.offset_right = _crown_w * 0.5
	_crown.offset_top = -_crown_h * 0.5
	_crown.offset_bottom = _crown_h * 0.5
	_crown.modulate.a = 0.0
	_crown.line_color = ThemeRes.accent()
	# 失败时「整体变暗」的目标色：**暗金**（不是近黑）。
	# ★ 别压到 line_soft 那一档：实测截图里王冠会整块消失，只剩几道裂纹，
	#   反而不像「一顶破裂的王冠」。暗金仍能读出轮廓，同时明显比胜利暗一档。
	_crown.dim_color = ThemeRes.line()
	_content.add_child(_crown)


func _build_gem() -> void:
	_gem = OutcomeArtRes.Gem.new()
	_gem.name = "OutcomeGem"
	_gem.anchor_left = 0.5
	_gem.anchor_right = 0.5
	_gem.anchor_top = 0.5
	_gem.anchor_bottom = 0.5
	# 镶嵌位置：王冠中央（相对屏幕中心略往下，落在两条谷线之间）。
	var gem_cy: float = _crown_h * 0.12
	_gem.offset_left = -_gem_size * 0.5
	_gem.offset_right = _gem_size * 0.5
	_gem.offset_top = gem_cy - _gem_size * 0.5
	_gem.offset_bottom = gem_cy + _gem_size * 0.5
	_gem.line_color = ThemeRes.accent_bright()
	_gem.modulate.a = 0.0
	_gem.visible = (_result == RESULT_WIN)
	_content.add_child(_gem)


func _build_banner() -> void:
	_banner = OutcomeArtRes.Banner.new()
	_banner.name = "OutcomeBanner"
	_banner.anchor_left = 0.5
	_banner.anchor_right = 0.5
	_banner.anchor_top = 0.5
	_banner.anchor_bottom = 0.5
	_banner.offset_left = -_banner_w * 0.5
	_banner.offset_right = _banner_w * 0.5
	_banner.offset_top = _crown_h * 0.5 + _banner_gap
	_banner.offset_bottom = _banner.offset_top + _banner_h
	_banner.target_width = _banner_w
	_banner.open_t = 0.0
	_banner.line_color = ThemeRes.line()
	_banner.accent_color = ThemeRes.accent() if _result == RESULT_WIN else ThemeRes.accent_deep()
	_content.add_child(_banner)

	# 字样：横幅**上半部分**（按钮出现后仍留在上方，两者不重叠）
	_word = _make_label("OutcomeWord",
		_win_word if _result == RESULT_WIN else _lose_word,
		_word_size,
		ThemeRes.accent_bright() if _result == RESULT_WIN else ThemeRes.warning())
	_word.anchor_left = 0.0
	_word.anchor_right = 1.0
	_word.anchor_top = 0.0
	_word.anchor_bottom = 0.0
	_word.offset_left = 0.0
	_word.offset_right = 0.0
	# ★ 按钮出现之前，主字在整块横幅里**垂直居中**（否则会留下半块空白的板）。
	#   点击任意处之后，它再上移到横幅上半部分，把下半部分让给三颗按钮。
	_word.offset_top = 0.0
	_word.offset_bottom = _banner_h
	_word.modulate.a = 0.0
	_banner.add_child(_word)

	# 三颗按钮：横幅**下半部分**，水平居中；一开始整排不可见。
	_buttons_box = HBoxContainer.new()
	_buttons_box.name = "OutcomeButtons"
	_buttons_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_buttons_box.offset_top = float(_word_size) * 1.35 + 18.0
	_buttons_box.offset_bottom = -12.0
	_buttons_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_buttons_box.add_theme_constant_override("separation", int(round(_button_gap)))
	_buttons_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_buttons_box.visible = false
	_buttons_box.modulate.a = 0.0
	_banner.add_child(_buttons_box)

	for i in 3:
		var b := _make_button(String(_button_labels[i]), i)
		_buttons_box.add_child(b)
		_buttons.append(b)


func _build_hint() -> void:
	_hint = _make_label("OutcomeHint", _hint_text, _hint_size, ThemeRes.text_dim())
	_hint.anchor_left = 0.0
	_hint.anchor_right = 1.0
	_hint.anchor_top = 0.5
	_hint.anchor_bottom = 0.5
	_hint.offset_left = 0.0
	_hint.offset_right = 0.0
	var hint_top: float = _crown_h * 0.5 + _banner_gap + _banner_h + _hint_gap
	_hint.offset_top = hint_top
	_hint.offset_bottom = hint_top + float(_hint_size) * 1.8
	_hint.modulate.a = 0.0
	_content.add_child(_hint)


func _make_label(node_name: String, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if font != null:
		l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _make_button(text: String, index: int) -> Button:
	var b := Button.new()
	b.name = "OutcomeButton%d" % index
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(_button_w, _button_h)
	b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if font != null:
		b.add_theme_font_override("font", font)
	b.add_theme_font_size_override("font_size", _button_size)
	# ★ 顺序与主菜单一致：先挂填充层，再挂样式（挂样式会写「原字色」）。
	FillButtonRes.attach_text(b)
	FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(b, ThemeRes.bg_bottom())
	b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
	b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
	b.add_theme_stylebox_override("focus", MenuThemeRes.button_normal())
	b.add_theme_stylebox_override("disabled", MenuThemeRes.button_disabled())
	b.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	if index == 2:
		b.pressed.connect(_on_continue_pressed)
	else:
		# 观察 / 统计：用户口径「目前只给继续加逻辑」——
		# 按钮正常显示、可点，但**明确什么都不做**（不是忘了接）。
		b.pressed.connect(func() -> void: pass)
	return b


# ------------------------------------------------------------------
# 动画序列
# ------------------------------------------------------------------

## 整段流程。每一拍都 `await` 自己的 Tween；动效关掉 / 时长为 0 时直接到位。
func _play() -> void:
	if not ThemeRes.animations_enabled():
		_finish_sequence()
		return
	await _fade_backdrop_in()
	if not is_instance_valid(self):
		return
	await _fade_crown_in()
	if not is_instance_valid(self):
		return
	if _result == RESULT_WIN:
		await _embed_gem()
	else:
		await _crack_crown()
	if not is_instance_valid(self):
		return
	await _open_banner()
	if not is_instance_valid(self):
		return
	await _fade_word_in()
	if not is_instance_valid(self):
		return
	await _fade_hint_in()


func _finish_sequence() -> void:
	if _bg != null and is_instance_valid(_bg):
		_bg.modulate.a = _dim_alpha
	if _crown != null and is_instance_valid(_crown):
		_crown.modulate.a = 1.0
		if _result == RESULT_LOSE:
			_crown.set_dim(1.0)
			_crown.set_crack(1.0)
	if _gem != null and is_instance_valid(_gem):
		_gem.visible = (_result == RESULT_WIN)
		_gem.modulate.a = 1.0
		_gem.position = _gem_target_pos()
	if _banner != null and is_instance_valid(_banner):
		_banner.set_open(1.0)
	if _word != null and is_instance_valid(_word):
		_word.modulate.a = 1.0
	if _hint != null and is_instance_valid(_hint):
		_hint.visible = true
		_hint.modulate.a = 1.0
	_ready_for_click = true


func _fade_backdrop_in() -> void:
	if _bg == null or not is_instance_valid(_bg):
		return
	_bg.modulate.a = 0.0
	if _backdrop_fade <= 0.0:
		_bg.modulate.a = _dim_alpha
		return
	_backdrop_tween = create_tween()
	_backdrop_tween.tween_property(_bg, "modulate:a", _dim_alpha, _backdrop_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await _backdrop_tween.finished
	_backdrop_tween = null


func _fade_crown_in() -> void:
	if _crown == null or not is_instance_valid(_crown):
		return
	_crown.modulate.a = 0.0
	if _crown_fade <= 0.0:
		_crown.modulate.a = 1.0
		return
	var tw := create_tween()
	tw.tween_property(_crown, "modulate:a", 1.0, _crown_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw.finished


## 胜利：宝石从王冠下方**渐入并升到**王冠中央（"镶嵌"那一拍）。
func _embed_gem() -> void:
	if _gem == null or not is_instance_valid(_gem):
		return
	_gem.visible = true
	_gem.modulate.a = 0.0
	_gem.position = _gem_start_pos()
	if _gem_fade <= 0.0 and _gem_rise <= 0.0:
		_gem.modulate.a = 1.0
		_gem.position = _gem_target_pos()
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_gem, "modulate:a", 1.0, _gem_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_gem, "position", _gem_target_pos(), _gem_fade) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw.finished
	_gem.position = _gem_target_pos()


## 失败：裂纹逐段出现 + 王冠整体变暗（**不散落** —— 用户口径）。
func _crack_crown() -> void:
	if _crown == null or not is_instance_valid(_crown):
		return
	_crown.set_dim(0.0)
	_crown.set_crack(0.0)
	if _crack_sec <= 0.0:
		_crown.set_dim(1.0)
		_crown.set_crack(1.0)
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_method(Callable(_crown, "set_crack"), 0.0, 1.0, _crack_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(Callable(_crown, "set_dim"), 0.0, 1.0, _crack_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	await tw.finished


func _open_banner() -> void:
	if _banner == null or not is_instance_valid(_banner):
		return
	_banner.set_open(0.0)
	if _banner_open <= 0.0:
		_banner.set_open(1.0)
		return
	var tw := create_tween()
	tw.tween_method(Callable(_banner, "set_open"), 0.0, 1.0, _banner_open) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw.finished


func _fade_word_in() -> void:
	if _word == null or not is_instance_valid(_word):
		return
	_word.modulate.a = 0.0
	if _word_fade <= 0.0:
		_word.modulate.a = 1.0
		return
	var tw := create_tween()
	tw.tween_property(_word, "modulate:a", 1.0, _word_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw.finished


## 提示：先淡入，淡入完成后才允许点击（避免玩家在字还没出来时误触）。
func _fade_hint_in() -> void:
	if _hint == null or not is_instance_valid(_hint):
		return
	_hint.visible = true
	_hint.modulate.a = 0.0
	if _hint_fade <= 0.0:
		_hint.modulate.a = 1.0
		_ready_for_click = true
		_start_breathing()
		return
	_hint_tween = create_tween()
	_hint_tween.tween_property(_hint, "modulate:a", 1.0, _hint_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_hint_tween.tween_callback(_on_hint_faded_in)
	await _hint_tween.finished


func _on_hint_faded_in() -> void:
	if not _open or _buttons_revealed:
		return
	_ready_for_click = true
	_start_breathing()


## 呼吸式渐显渐隐（与 start_screen / level_transition 同一种节奏）。
func _start_breathing() -> void:
	if _hint == null or not is_instance_valid(_hint):
		return
	_stop_breathing()
	if not ThemeRes.animations_enabled() or _breath_sec <= 0.0:
		_hint.modulate.a = 1.0
		return
	_breath_tween = create_tween().set_loops()
	_breath_tween.tween_property(_hint, "modulate:a", _breath_min, _breath_sec) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath_tween.tween_property(_hint, "modulate:a", 1.0, _breath_sec) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_breathing() -> void:
	if _breath_tween != null and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = null


## 主字从「横幅正中」上移到「上半部分」，给按钮让出下半部分。
func _move_word_up() -> void:
	if _word == null or not is_instance_valid(_word):
		return
	var top: float = 10.0
	var bottom: float = top + float(_word_size) * 1.35
	if not ThemeRes.animations_enabled() or _buttons_fade <= 0.0:
		_word.offset_top = top
		_word.offset_bottom = bottom
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_word, "offset_top", top, _buttons_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_word, "offset_bottom", bottom, _buttons_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


## 点击任意处之后：**先**让提示渐隐，**再**让三颗按钮在横幅中渐显。
##
## ★ 顺序不能并排（用户口径：「字样会渐隐，随后……渐显三个按钮」）：
##   两段同时跑的话，观感是「按钮和提示一起换」，而不是「先收掉提示、再露出按钮」。
func _reveal_buttons() -> void:
	_stop_breathing()
	if _hint == null or not is_instance_valid(_hint):
		_show_buttons_now()
		return
	if _hint_tween != null and _hint_tween.is_valid():
		_hint_tween.kill()
	_hint_tween = null
	if not ThemeRes.animations_enabled() or _hint_out <= 0.0:
		_hint.modulate.a = 0.0
		_hint.visible = false
		_show_buttons_now()
		return
	var ht := create_tween()
	ht.tween_property(_hint, "modulate:a", 0.0, _hint_out) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	ht.tween_callback(_show_buttons_now)
	_hint_tween = ht


## 提示收完之后才走这一拍：主字上移 + 按钮渐显。
func _show_buttons_now() -> void:
	if not _open or not is_instance_valid(self):
		return
	if _hint != null and is_instance_valid(_hint):
		_hint.visible = false
	if _buttons_box == null or not is_instance_valid(_buttons_box):
		buttons_shown.emit()
		return
	_move_word_up()
	_buttons_box.visible = true
	if not ThemeRes.animations_enabled() or _buttons_fade <= 0.0:
		_buttons_box.modulate.a = 1.0
		buttons_shown.emit()
		return
	_buttons_box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_buttons_box, "modulate:a", 1.0, _buttons_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void: buttons_shown.emit())


# ------------------------------------------------------------------
# 宝石的位置（相对「王冠中央」）
# ------------------------------------------------------------------

func _gem_target_pos() -> Vector2:
	var vp: Vector2 = _viewport_size()
	return vp * 0.5 + Vector2(-_gem_size * 0.5, _crown_h * 0.12 - _gem_size * 0.5)


func _gem_start_pos() -> Vector2:
	return _gem_target_pos() + Vector2(0.0, _gem_rise)


func _viewport_size() -> Vector2:
	var vp := get_viewport()
	if vp != null:
		var s := vp.get_visible_rect().size
		if s.x > 0.0 and s.y > 0.0:
			return s
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080)))


# ------------------------------------------------------------------
# 输入 / 退出
# ------------------------------------------------------------------

## ★ 触摸兜底：项目默认开着 `emulate_mouse_from_touch`，GUI 那条路已经够用；
##   但这里再收一道 `InputEventScreenTouch`，保证「关掉模拟鼠标 / 某些平台只发触摸」
##   时「点击任意处」仍然成立。按钮出现之后 `accept_click()` 直接返回 false，
##   所以不会抢走「继续」的触摸。
func _input(event: InputEvent) -> void:
	if not _open or _closing:
		return
	if not (event is InputEventScreenTouch):
		return
	if not (event as InputEventScreenTouch).pressed:
		return
	if accept_click():
		get_viewport().set_input_as_handled()


## 点屏幕任意处（左键 / 触摸）。按钮自己会先吃掉事件，所以这里只收到「空白处」。
func _on_root_input(event: InputEvent) -> void:
	if not _open or _closing:
		return
	var pressed := false
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		pressed = mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	if not pressed:
		return
	if accept_click():
		_root.accept_event()


## 三颗按钮里的「继续」。
func _on_continue_pressed() -> void:
	if not _open or _closing:
		return
	_closing = true
	_ready_for_click = false
	_stop_breathing()
	if not ThemeRes.animations_enabled() or _exit_fade <= 0.0:
		_open = false
		continue_pressed.emit()
		return
	_exit_tween = create_tween()
	_exit_tween.tween_property(_root, "modulate:a", 0.0, _exit_fade) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await _exit_tween.finished
	if not is_instance_valid(self):
		return
	_open = false
	continue_pressed.emit()
