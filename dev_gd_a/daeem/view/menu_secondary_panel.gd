## menu_secondary_panel.gd —— 撑开出来的那块面板（一颗「返回」+ 可选的内容区）
##
## 版式照 nsoc 的 `scripts/ui/secondary_panel.gd`：满铺 + 一颗「返回」按钮。
##
## ★★ 两种用法：
##   · **空面板**（默认）：除了「返回」什么都没有；
##   · **战斗测试面板**（`with_battle_entries = true`，给「战役」那颗按钮用）：
##     内容区里放 `view/battle_entries.gd` —— 地图选择条 + test + campaign_test。
##     这三样原来长在主界面正中那一列里，现在整块搬到这里（只由本面板拥有）。
##
## 生命周期（由 `view/panel_expand.gd` 驱动）：
##   · `setup()`     —— 造出「返回」与内容（由工厂在实例化之后、挂上树之前调用）；
##   · `attach()`    —— 挂到已经撑开的那块面板里，跟着它的尺寸，并淡入；
##   · `detach_with_fade()` —— 与父面板的收回同步淡出，完了自己销毁；
##   · `back_pressed` —— 「返回」被按下（引擎接过去做反向转场）。
##
## ★ 整棵子树带 `transition_skip` 元数据：这是与 panel_expand 的约定 ——
##   「我自己的淡入淡出归我自己管」，别把我算进它那一批按 alpha 淡出的子控件里。
extends Control

signal back_pressed
## 内容区里那颗 test 被按了（只在 `with_battle_entries` 时会有）—— 见 view/battle_entries.gd
signal test_pressed(map_path: String)
## 内容区里那颗 campaign_test 被按了
signal campaign_test_pressed()

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const BattleEntriesRes = preload("res://view/battle_entries.gd")

## 兜底淡入淡出时长（与 config.json 的 menu.chrome.transition_sec 一致）
const DEFAULT_FADE_SEC := 0.45
## 兜底边距（与 menu.chrome.expanded_margin 同一档：返回按钮贴在撑开面板的角上）
const DEFAULT_MARGIN := 24.0

var cfg: ConfigRes = null
var _font: Font = null
var _fade_sec: float = DEFAULT_FADE_SEC
var _margin: float = DEFAULT_MARGIN
var _with_battle_entries: bool = false
var _built: bool = false
var _back_btn: Button = null
## 内容区那块（`with_battle_entries` 时才有）
var _entries = null


## @param p_fade_sec 淡入 / 淡出时长（一般传引擎的 `transition_sec`，两边同步）
## @param p_margin  返回按钮离面板上边 / 右边的距离
## @param p_with_battle_entries 内容区里要不要放「地图选择条 + test + campaign_test」
func setup(p_cfg: ConfigRes, p_font: Font, p_fade_sec: float, p_margin: float,
		p_with_battle_entries: bool = false) -> void:
	cfg = p_cfg
	_font = p_font
	_fade_sec = maxf(0.0, p_fade_sec)
	_margin = maxf(0.0, p_margin)
	_with_battle_entries = p_with_battle_entries
	_build()


## 「返回」那颗按钮本身 —— 给测试与排查用。
func back_button() -> Button:
	return _back_btn


## 内容区那块（`view/battle_entries.gd`）；空面板时是 null。
func entries():
	return _entries


func _build() -> void:
	if _built:
		return
	_built = true
	# ★ 与 panel_expand 的约定：我自己的淡入淡出归我自己管
	set_meta("transition_skip", true)
	# ⚠️ 这里用 `set_anchors_and_offsets_preset`：`set_anchors_preset` 在「已在树上、尺寸为 0」
	#   的那一刻会把 offset 算成保持 0 尺寸（见 view/menu_chrome.gd 里那条同样的说明）。
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 吃掉底下的一切点击：撑开之后这块面板说了算
	mouse_filter = Control.MOUSE_FILTER_STOP

	var w: float = cfg.num("menu.chrome.back_w", 160.0) if cfg != null else 160.0
	var h: float = cfg.num("menu.chrome.back_h", 80.0) if cfg != null else 80.0
	var text: String = cfg.str_val("menu.chrome.back_text", "返回") if cfg != null else "返回"
	var font_size: int = cfg.int_val("menu.chrome.back_font_size", 28) if cfg != null else 28

	_back_btn = Button.new()
	_back_btn.name = "BackBtn"
	_back_btn.text = text
	_back_btn.focus_mode = Control.FOCUS_NONE
	if _font != null:
		_back_btn.add_theme_font_override("font", _font)
	_back_btn.add_theme_font_size_override("font_size", font_size)
	# 贴右上角（锚在右上，offset 往左/下让出边距）—— 与 nsoc 的 160×80 同尺寸
	_back_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	_back_btn.offset_left = -_margin - w
	_back_btn.offset_top = _margin
	_back_btn.offset_right = -_margin
	_back_btn.offset_bottom = _margin + h

	# 样式与外壳上那些按钮同一套（menu_theme 四态 + fill_button 的悬停金）
	FillButtonRes.attach_text(_back_btn)
	UiWidgetsRes.apply_button_styles(_back_btn, {
		"normal": MenuThemeRes.button_normal(),
		"hover": MenuThemeRes.button_hover_clear(),
		"pressed": MenuThemeRes.button_selected(),
		"disabled": MenuThemeRes.button_disabled(),
	})
	FillButtonRes.set_base_font_color(_back_btn, MenuThemeRes.text_normal())
	FillButtonRes.set_panel_color(_back_btn, ThemeRes.bg_top())
	_back_btn.add_theme_color_override("font_disabled_color", MenuThemeRes.text_disabled())
	_back_btn.pressed.connect(_on_back_pressed)
	add_child(_back_btn)

	_build_content()


## 挂到已经撑开的那块面板里，跟着它的尺寸，并淡入。
##
## ★ 父面板的 `size` 是**被 Tween 直接写**的（它不是 Container），
##   所以子节点的尺寸不会自动刷新 —— 这里手动同步一次，并监听它后续的变化。
##   （nsoc 的 `SecondaryPanel.attach()` 同一条理由。）
func attach(origin_panel: Control) -> void:
	if origin_panel == null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	origin_panel.add_child(self)
	size = origin_panel.size
	origin_panel.resized.connect(_sync_size.bind(origin_panel))
	modulate.a = 0.0
	if _fade_sec <= 0.0 or not ThemeRes.animations_enabled():
		modulate.a = 1.0
		return
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, _fade_sec) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## 与父面板的收回同步淡出，完了销毁自己。
func detach_with_fade(duration: float) -> void:
	if _back_btn != null:
		# 收回途中不许再点「返回」（连点会把反向转场触发两次）
		_back_btn.disabled = true
	if duration <= 0.0 or not ThemeRes.animations_enabled():
		queue_free()
		return
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	if is_instance_valid(self):
		queue_free()


## 往面板里填内容：只有「战役」那颗按钮撑开的那块才有内容。
##
## ★ 位置：把内容放进一个铺满面板的 `CenterContainer` ⇒ 它在整块面板里居中
##   （搬迁前它是长在主界面正中的，观感一致）。
## ★ 内容自己发信号（`view/battle_entries.gd` 的 `test_pressed` / `campaign_test_pressed`），
##   这里**只往上传一层**：面板 → 外壳 → view/start_screen.gd → view/main.gd。
##   ⇒ 谁建世界这件事仍然只有一个地方知道（main.gd），本文件不认识任何玩法概念。
func _build_content() -> void:
	if not _with_battle_entries:
		return
	var wrap := CenterContainer.new()
	wrap.name = "ContentCenter"
	wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(wrap)

	_entries = BattleEntriesRes.new()
	wrap.add_child(_entries)
	_entries.setup(cfg, _font)
	_entries.test_pressed.connect(func(path: String): test_pressed.emit(path))
	_entries.campaign_test_pressed.connect(func(): campaign_test_pressed.emit())


func _sync_size(origin_panel: Control) -> void:
	if is_instance_valid(origin_panel):
		size = origin_panel.size


func _on_back_pressed() -> void:
	back_pressed.emit()
