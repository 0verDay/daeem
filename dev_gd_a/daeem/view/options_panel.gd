## options_panel.gd —— 仿 nsoc 的**选项页菜单**（游玩场景 + 主菜单共用）
##
## 结构（与 nsoc 的 SettingsPanelController 同一套交互，配色换成本作的暗底金线）：
##   · 全屏暗色 overlay + 居中面板；
##   · 一级：继续 / 设置 / 退出（退出按钮的文案由调用方给：游戏内「返回主菜单」，
##     主菜单「退出游戏」）；
##   · 二级「设置」：全屏 / 窗口化 + 返回；
##   · 点 overlay 空白处关闭；子页之间 0.15s 横滑 + 淡入淡出；
##   · 打开 / 关闭 = 0.2s 缩放 0.85→1 + 淡入 / 反向。
##
## ★ 只发动作，不自己改窗口 / 拆场景：
##   fullscreen_action / exit_action 由调用方注入（游戏内走 HUD 的信号链，
##   主菜单走 StartScreen 的信号 → main.gd）。
## ★ 所有按钮都挂 fill_button（悬停金 + 按下回弹）；本文件只管这一页的布局与转场。
extends Node

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")
const FillButtonRes = preload("res://view/fill_button.gd")
## ★ 选项页也是「菜单页」：面板子树标记成菜单，里面的按钮才会播点击音（见 sfx.gd）。
const SfxRes = preload("res://view/sfx.gd")

const OPEN_SCALE := Vector2(0.85, 0.85)
const SUBMENU_SLIDE_PX := 30.0

## 打开 / 关闭（给 HUD 把右上角按钮切到常驻满格 / 常态）。
signal opened
signal closed

var cfg: ConfigRes = null
var _font: Font = null
var _style_mode: String = "hud"
var _parent: Control = null

var overlay: ColorRect = null
var panel: Panel = null
var menu_vbox: VBoxContainer = null
var config_vbox: VBoxContainer = null

var resume_button: Button = null
var settings_button: Button = null
var exit_button: Button = null
var fullscreen_button: Button = null
var back_button: Button = null

var _is_open: bool = false
var _settings_open: bool = false
var _menu_offsets: Dictionary = {}
var _config_offsets: Dictionary = {}
var _open_tween: Tween = null
var _submenu_tween: Tween = null

var _resume_label: String = "继续"
var _settings_label: String = "设置"
var _exit_label: String = "返回主菜单"
var _panel_title: String = "设置"
var _back_label: String = "返回"
var _fullscreen_on_text: String = "窗口化"
var _fullscreen_off_text: String = "全屏"
var _resume_action: Callable = Callable()
var _exit_action: Callable = Callable()
var _fullscreen_action: Callable = Callable()
var _can_open: Callable = Callable()

var _panel_w: float = 640.0
var _panel_h: float = 440.0
var _button_w: float = 280.0
var _button_h: float = 64.0
var _gap: float = 14.0
var _title_size: int = 28
var _button_size: int = 24
var _dim_alpha: float = 0.55
var _panel_alpha: float = 0.94
var _open_sec: float = 0.2
var _submenu_sec: float = 0.15
var _panel_bg: Color = Color(0.08, 0.07, 0.05, 0.94)


## @param parent  铺满全屏的 Control（HUD 的 HudRoot / StartScreen 的 StartRoot）
## @param font    中文字体
## @param config  文案 / 回调 / 风格：
##   resume_label, settings_label, exit_label, panel_title,
##   fullscreen_on_text, fullscreen_off_text,
##   resume_action, exit_action, fullscreen_action, can_open,
##   style ("hud" | "menu")
func setup(parent: Control, font: Font, p_cfg: ConfigRes, config: Dictionary = {}) -> void:
	_parent = parent
	_font = font
	cfg = p_cfg
	_style_mode = String(config.get("style", "hud"))
	_resume_label = String(config.get("resume_label", _resume_label))
	_settings_label = String(config.get("settings_label", _settings_label))
	_exit_label = String(config.get("exit_label", _exit_label))
	_panel_title = String(config.get("panel_title", _panel_title))
	_back_label = String(config.get("back_label", _back_label))
	_fullscreen_on_text = String(config.get("fullscreen_on_text", _fullscreen_on_text))
	_fullscreen_off_text = String(config.get("fullscreen_off_text", _fullscreen_off_text))
	if config.has("resume_action") and config["resume_action"] is Callable:
		_resume_action = config["resume_action"]
	if config.has("exit_action") and config["exit_action"] is Callable:
		_exit_action = config["exit_action"]
	if config.has("fullscreen_action") and config["fullscreen_action"] is Callable:
		_fullscreen_action = config["fullscreen_action"]
	if config.has("can_open") and config["can_open"] is Callable:
		_can_open = config["can_open"]

	_read_layout()
	_build_overlay_panel()
	SfxRes.mark_menu(panel)
	_build_menu_page()
	_build_config_page()
	_menu_offsets = _capture_offsets(menu_vbox)
	_config_offsets = _capture_offsets(config_vbox)
	overlay.visible = false
	_refresh_fullscreen()


func _read_layout() -> void:
	_panel_w = maxf(360.0, cfg.num("options.panel_w", 640.0)) if cfg != null else 640.0
	_panel_h = maxf(300.0, cfg.num("options.panel_h", 440.0)) if cfg != null else 440.0
	_button_w = maxf(180.0, cfg.num("options.button_w", 280.0)) if cfg != null else 280.0
	_button_h = maxf(40.0, cfg.num("options.button_h", 64.0)) if cfg != null else 64.0
	_gap = maxf(4.0, cfg.num("options.gap", 14.0)) if cfg != null else 14.0
	_title_size = int(cfg.num("options.title_size", 28.0)) if cfg != null else 28
	_button_size = int(cfg.num("options.button_size", 24.0)) if cfg != null else 24
	_dim_alpha = clampf(cfg.num("options.dim_alpha", 0.55), 0.0, 1.0) if cfg != null else 0.55
	_panel_alpha = clampf(cfg.num("options.panel_alpha", 0.94), 0.0, 1.0) if cfg != null else 0.94
	_open_sec = maxf(0.01, cfg.num("options.open_sec", 0.2)) if cfg != null else 0.2
	_submenu_sec = maxf(0.01, cfg.num("options.submenu_sec", 0.15)) if cfg != null else 0.15
	_panel_bg = ThemeRes.with_alpha(ThemeRes.bg_top(), _panel_alpha)


# ------------------------------------------------------------------
# 构建
# ------------------------------------------------------------------

func _build_overlay_panel() -> void:
	overlay = ColorRect.new()
	overlay.name = "OptionsOverlay"
	overlay.color = Color(0.0, 0.0, 0.0, _dim_alpha)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 200
	_parent.add_child(overlay)
	overlay.gui_input.connect(_on_overlay_input)

	panel = Panel.new()
	panel.name = "OptionsPanelBody"
	panel.set_anchors_preset(Control.PRESET_CENTER, false)
	panel.offset_left = -_panel_w * 0.5
	panel.offset_top = -_panel_h * 0.5
	panel.offset_right = _panel_w * 0.5
	panel.offset_bottom = _panel_h * 0.5
	panel.pivot_offset = Vector2(_panel_w * 0.5, _panel_h * 0.5)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	overlay.add_child(panel)


func _make_panel_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = _panel_bg
	s.border_color = ThemeRes.accent()
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.42)
	s.shadow_size = 14
	s.shadow_offset = Vector2(0.0, 3.0)
	return s


func _build_menu_page() -> void:
	var menu_h: float = 3.0 * _button_h + 2.0 * _gap
	menu_vbox = VBoxContainer.new()
	menu_vbox.name = "OptionsMenuVBox"
	menu_vbox.set_anchors_preset(Control.PRESET_CENTER, false)
	menu_vbox.offset_left = -_button_w * 0.5
	menu_vbox.offset_top = -menu_h * 0.5
	menu_vbox.offset_right = _button_w * 0.5
	menu_vbox.offset_bottom = menu_h * 0.5
	menu_vbox.add_theme_constant_override("separation", int(_gap))
	menu_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(menu_vbox)

	resume_button = _make_button(_resume_label, "ResumeButton")
	resume_button.pressed.connect(_on_resume_pressed)
	menu_vbox.add_child(resume_button)

	settings_button = _make_button(_settings_label, "SettingsPageButton")
	settings_button.pressed.connect(_show_settings_page)
	menu_vbox.add_child(settings_button)

	exit_button = _make_button(_exit_label, "ExitButton")
	exit_button.pressed.connect(_on_exit_pressed)
	menu_vbox.add_child(exit_button)


func _build_config_page() -> void:
	var config_h: float = _panel_h - 100.0
	config_vbox = VBoxContainer.new()
	config_vbox.name = "OptionsConfigVBox"
	config_vbox.set_anchors_preset(Control.PRESET_CENTER, false)
	config_vbox.offset_left = -_button_w * 0.5
	config_vbox.offset_top = -config_h * 0.5
	config_vbox.offset_right = _button_w * 0.5
	config_vbox.offset_bottom = config_h * 0.5
	config_vbox.add_theme_constant_override("separation", int(_gap))
	config_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	config_vbox.visible = false
	panel.add_child(config_vbox)

	var title := Label.new()
	title.name = "OptionsConfigTitle"
	title.text = _panel_title
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", _title_size)
	title.add_theme_color_override("font_color", ThemeRes.accent_bright())
	if _font != null:
		title.add_theme_font_override("font", _font)
	config_vbox.add_child(title)

	var sep := HSeparator.new()
	var line := StyleBoxLine.new()
	line.color = ThemeRes.with_alpha(ThemeRes.line(), 0.8)
	line.thickness = 1
	sep.add_theme_stylebox_override("separator", line)
	config_vbox.add_child(sep)

	fullscreen_button = _make_button(_fullscreen_off_text, "FullscreenButton")
	fullscreen_button.pressed.connect(_on_fullscreen_pressed)
	config_vbox.add_child(fullscreen_button)

	var spacer := Control.new()
	spacer.name = "OptionsConfigSpacer"
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	config_vbox.add_child(spacer)

	back_button = _make_button(_back_label, "BackButton")
	back_button.pressed.connect(_show_menu_page)
	config_vbox.add_child(back_button)


func _make_button(text: String, node_name: String) -> Button:
	var b := Button.new()
	b.name = node_name
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(_button_w, _button_h)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_font_size_override("font_size", _button_size)
	if _font != null:
		b.add_theme_font_override("font", _font)
	FillButtonRes.attach_text(b)
	if _style_mode == "menu":
		b.add_theme_stylebox_override("normal", MenuThemeRes.button_normal())
		b.add_theme_stylebox_override("hover", MenuThemeRes.button_hover_clear())
		b.add_theme_stylebox_override("pressed", MenuThemeRes.button_fill_latched())
		FillButtonRes.set_base_font_color(b, MenuThemeRes.text_normal())
	else:
		b.add_theme_stylebox_override("normal", UiStyleRes.accent_button_clear())
		b.add_theme_stylebox_override("hover", UiStyleRes.accent_button_clear())
		b.add_theme_stylebox_override("pressed", UiStyleRes.accent_button_latched())
		FillButtonRes.set_base_font_color(b, UiStyleRes.text())
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	FillButtonRes.set_panel_color(b, _panel_bg)
	return b


# ------------------------------------------------------------------
# 状态 / 打开关闭
# ------------------------------------------------------------------

func is_open() -> bool:
	return _is_open


func is_settings_page_open() -> bool:
	return _settings_open


func open() -> void:
	if _is_open:
		return
	if _can_open.is_valid() and not bool(_can_open.call()):
		return
	_is_open = true
	overlay.visible = true
	overlay.move_to_front()
	_show_menu_page_instant()
	_refresh_fullscreen()
	_animate_open()
	opened.emit()


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	closed.emit()
	_animate_close()


func _reset_pages_instant() -> void:
	_settings_open = false
	menu_vbox.visible = true
	menu_vbox.modulate.a = 1.0
	_restore_offsets(menu_vbox, _menu_offsets)
	config_vbox.visible = false
	config_vbox.modulate.a = 1.0
	_restore_offsets(config_vbox, _config_offsets)


func _show_menu_page_instant() -> void:
	_reset_pages_instant()


func _show_settings_page() -> void:
	if _settings_open:
		return
	_settings_open = true
	_animate_submenu_swap(menu_vbox, config_vbox, 1)


func _show_menu_page() -> void:
	if not _settings_open:
		return
	_settings_open = false
	_animate_submenu_swap(config_vbox, menu_vbox, -1)


func _on_overlay_input(event: InputEvent) -> void:
	if not _is_open:
		return
	var pressed := false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		pressed = (event as InputEventMouseButton).pressed
	elif event is InputEventScreenTouch:
		pressed = (event as InputEventScreenTouch).pressed
	if not pressed:
		return
	var mp := overlay.get_local_mouse_position()
	if event is InputEventScreenTouch:
		mp = (event as InputEventScreenTouch).position
	if not panel.get_rect().has_point(mp):
		close()


func _on_resume_pressed() -> void:
	if _resume_action.is_valid():
		_resume_action.call()
	else:
		close()


func _on_exit_pressed() -> void:
	close()
	if _exit_action.is_valid():
		_exit_action.call()


# ------------------------------------------------------------------
# 全屏
# ------------------------------------------------------------------

func _on_fullscreen_pressed() -> void:
	if _fullscreen_action.is_valid():
		_fullscreen_action.call()
	_refresh_fullscreen()


## 给 HUD / 测试用：按当前窗口模式刷新「全屏 ⇄ 窗口化」文案。
func refresh_fullscreen() -> void:
	_refresh_fullscreen()


func _refresh_fullscreen() -> void:
	if fullscreen_button == null:
		return
	fullscreen_button.text = _fullscreen_on_text if _is_fullscreen() else _fullscreen_off_text


func _is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


# ------------------------------------------------------------------
# 转场
# ------------------------------------------------------------------

func _animate_open() -> void:
	_kill_open_tween()
	if not ThemeRes.animations_enabled() or _open_sec <= 0.0:
		overlay.modulate.a = 1.0
		panel.scale = Vector2.ONE
		panel.modulate.a = 1.0
		return
	overlay.modulate.a = 0.0
	panel.scale = OPEN_SCALE
	panel.modulate.a = 0.0
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(overlay, "modulate:a", 1.0, _open_sec)
	_open_tween.tween_property(panel, "scale", Vector2.ONE, _open_sec)
	_open_tween.tween_property(panel, "modulate:a", 1.0, _open_sec)


func _animate_close() -> void:
	_kill_open_tween()
	if not ThemeRes.animations_enabled() or _open_sec <= 0.0:
		overlay.visible = false
		overlay.modulate.a = 1.0
		panel.scale = Vector2.ONE
		panel.modulate.a = 1.0
		_reset_pages_instant()
		return
	_open_tween = create_tween()
	_open_tween.set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_open_tween.tween_property(overlay, "modulate:a", 0.0, _open_sec)
	_open_tween.tween_property(panel, "scale", OPEN_SCALE, _open_sec)
	_open_tween.tween_property(panel, "modulate:a", 0.0, _open_sec)
	_open_tween.chain().tween_callback(func():
		overlay.visible = false
		overlay.modulate.a = 1.0
		panel.scale = Vector2.ONE
		panel.modulate.a = 1.0
		_reset_pages_instant())


func _kill_open_tween() -> void:
	if _open_tween != null and _open_tween.is_valid():
		_open_tween.kill()


func _animate_submenu_swap(from_vbox: VBoxContainer, to_vbox: VBoxContainer, dir: int) -> void:
	if _submenu_tween != null and _submenu_tween.is_valid():
		_submenu_tween.kill()

	var from_offsets: Dictionary = _menu_offsets if from_vbox == menu_vbox else _config_offsets
	var to_offsets: Dictionary = _menu_offsets if to_vbox == menu_vbox else _config_offsets
	_restore_offsets(from_vbox, from_offsets)
	_restore_offsets(to_vbox, to_offsets)

	if not ThemeRes.animations_enabled() or _submenu_sec <= 0.0:
		from_vbox.visible = false
		from_vbox.modulate.a = 1.0
		to_vbox.visible = true
		to_vbox.modulate.a = 1.0
		_restore_offsets(to_vbox, to_offsets)
		return

	to_vbox.modulate.a = 0.0
	to_vbox.visible = true
	to_vbox.offset_left = to_offsets.left + SUBMENU_SLIDE_PX * float(dir)
	to_vbox.offset_right = to_offsets.right + SUBMENU_SLIDE_PX * float(dir)

	_submenu_tween = create_tween()
	_submenu_tween.set_parallel(true)
	_submenu_tween.set_trans(Tween.TRANS_QUAD)
	_submenu_tween.tween_property(from_vbox, "modulate:a", 0.0, _submenu_sec).set_ease(Tween.EASE_IN)
	_submenu_tween.tween_property(from_vbox, "offset_left",
		from_offsets.left - SUBMENU_SLIDE_PX * float(dir), _submenu_sec).set_ease(Tween.EASE_IN)
	_submenu_tween.tween_property(from_vbox, "offset_right",
		from_offsets.right - SUBMENU_SLIDE_PX * float(dir), _submenu_sec).set_ease(Tween.EASE_IN)
	_submenu_tween.tween_property(to_vbox, "modulate:a", 1.0, _submenu_sec).set_ease(Tween.EASE_OUT)
	_submenu_tween.tween_property(to_vbox, "offset_left",
		to_offsets.left, _submenu_sec).set_ease(Tween.EASE_OUT)
	_submenu_tween.tween_property(to_vbox, "offset_right",
		to_offsets.right, _submenu_sec).set_ease(Tween.EASE_OUT)
	_submenu_tween.chain().tween_callback(func():
		from_vbox.visible = false
		_restore_offsets(from_vbox, from_offsets)
		_restore_offsets(to_vbox, to_offsets))


static func _capture_offsets(c: Control) -> Dictionary:
	return {
		"left": c.offset_left,
		"top": c.offset_top,
		"right": c.offset_right,
		"bottom": c.offset_bottom,
	}


static func _restore_offsets(c: Control, o: Dictionary) -> void:
	c.offset_left = o.left
	c.offset_top = o.top
	c.offset_right = o.right
	c.offset_bottom = o.bottom
