## menu_secondary_panel.gd —— 撑开出来的那块面板（一颗「返回」+ 可选的内容区）
##
## 版式照 nsoc 的 `scripts/ui/secondary_panel.gd`：满铺 + 一颗「返回」按钮。
##
## ★★ 两种用法：
##   · **空面板**（默认）：除了「返回」什么都没有；
##   · **战役菜单**（`with_campaign_menu = true`，给「战役」那颗按钮用）：
##     内容区里放 `view/campaign_menu.gd` —— 左侧战役轮播 + 顶部关卡圆点 +
##     右侧关卡描述 + 长按进入（版式移植自 nsoc 的 CampaignPanel）。
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
## 战役菜单里长按满了某一关（只在 `with_campaign_menu` 时会有）——
## 参数是**数据**（战役 id + 关卡 id），见 view/campaign_menu.gd。
signal level_activated(campaign_id: String, level_id: String)
## 合作大厅：房主点开始 / 客机收到 start（transport 已从 lobby 交出来）。
signal coop_host_started(campaign_id: String, level_id: String, transport)
signal coop_guest_started(payload: Dictionary, transport)

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const CampaignMenuRes = preload("res://view/campaign_menu.gd")
const CampaignMenuDbRes = preload("res://logic/campaign_menu_db.gd")
const CoopLobbyRes = preload("res://view/coop_lobby.gd")

## 兜底淡入淡出时长（与 config.json 的 menu.chrome.transition_sec 一致）
const DEFAULT_FADE_SEC := 0.45
## 兜底边距（与 menu.chrome.expanded_margin 同一档：返回按钮贴在撑开面板的角上）
const DEFAULT_MARGIN := 24.0

var cfg: ConfigRes = null
var _font: Font = null
var _fade_sec: float = DEFAULT_FADE_SEC
var _margin: float = DEFAULT_MARGIN
var _with_campaign_menu: bool = false
var _with_coop_lobby: bool = false
var _built: bool = false
var _back_btn: Button = null
## 内容区那块（`with_campaign_menu` 时才有）
var _campaign_menu = null
## 内容区那块（`with_coop_lobby` 时才有）
var _coop_lobby = null


## @param p_fade_sec 淡入 / 淡出时长（一般传引擎的 `transition_sec`，两边同步）
## @param p_margin  返回按钮离面板上边 / 右边的距离
## @param p_with_campaign_menu 内容区里要不要放战役菜单（左侧轮播 + 关卡圆点 + 描述）
func setup(p_cfg: ConfigRes, p_font: Font, p_fade_sec: float, p_margin: float,
		p_with_campaign_menu: bool = false, p_with_coop_lobby: bool = false) -> void:
	cfg = p_cfg
	_font = p_font
	_fade_sec = maxf(0.0, p_fade_sec)
	_margin = maxf(0.0, p_margin)
	_with_campaign_menu = p_with_campaign_menu
	_with_coop_lobby = p_with_coop_lobby
	_build()


## 「返回」那颗按钮本身 —— 给测试与排查用。
func back_button() -> Button:
	return _back_btn


## 内容区那块战役菜单（`view/campaign_menu.gd`）；空面板时是 null。
func campaign_menu():
	return _campaign_menu


## 内容区那块合作大厅（`with_coop_lobby` 时才有）；给测试与 start_screen 用。
func coop_lobby():
	return _coop_lobby


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
		# ★ 按下态只加亮描边：实心金会把自绘填充盖住（「一按就整块亮金」那种假反馈）
		"pressed": MenuThemeRes.button_fill_latched(),
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
## ★ 位置：整块铺满撑开面板（版式是「左 1/4 轮播 / 顶部关卡条 / 右侧描述」，
##   不是居中一列 —— 见 view/campaign_menu.gd）。
## ★ 内容自己发信号（`view/campaign_menu.gd` 的 `chapter_activated`），
##   这里**只往上传一层**：面板 → 外壳 → view/start_screen.gd → view/main.gd。
##   ⇒ 谁建世界这件事仍然只有一个地方知道（main.gd），本文件不认识任何玩法概念。
func _build_content() -> void:
	if _with_campaign_menu:
		_campaign_menu = CampaignMenuRes.new()
		add_child(_campaign_menu)
		_campaign_menu.setup(cfg, _font, CampaignMenuDbRes.load_campaigns())
		_campaign_menu.chapter_activated.connect(
			func(campaign_id: String, level_id: String):
				level_activated.emit(campaign_id, level_id))
		return
	if _with_coop_lobby:
		_coop_lobby = CoopLobbyRes.new()
		add_child(_coop_lobby)
		_coop_lobby.setup(cfg, _font)
		# 3.png 要把「返回」滑到左上角：按钮归面板所有，位置托管给大厅。
		_coop_lobby.attach_back_button(_back_btn)
		_coop_lobby.host_started.connect(
			func(campaign_id: String, level_id: String, transport):
				coop_host_started.emit(campaign_id, level_id, transport))
		_coop_lobby.guest_started.connect(
			func(payload: Dictionary, transport):
				coop_guest_started.emit(payload, transport))


func _sync_size(origin_panel: Control) -> void:
	if is_instance_valid(origin_panel):
		size = origin_panel.size


func _on_back_pressed() -> void:
	# 合作大厅在 ROOM / MAP 状态下先处理返回（退出房间 / 放弃改图），
	# 只有 LOBBY 才真的收起面板。
	if _coop_lobby != null and _coop_lobby.has_method("handle_back"):
		if bool(_coop_lobby.handle_back()):
			return
	back_pressed.emit()
