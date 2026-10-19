## quit_confirm.gd —— ★ 退出确认浮层（版式移植自 nsoc 的 `scripts/ui/quit_confirm.gd`）
##
## 形态（与 nsoc 一致）：
##   · 全屏半透黑遮罩（55%）：**点空白 = 取消**；
##   · 居中一块大面板（屏宽 70% × 屏高 50%）：**点面板 = 确认退出**；
##   · 打开：淡入 + 0.92→1 缩放；取消：反向播放；
##   · 确认：遮罩先推成**全黑**（0.2s）再发 `confirmed` —— 这就是「缓冲」那一下。
##
## ★★ 与 nsoc 的三处刻意差异：
##   1. **不是 autoload**：本作没有全局单例，且「谁退出」一直只归 `view/main.gd`（流程层）——
##      本文件只发 `confirmed` / `cancelled`，**自己不调 `get_tree().quit()`**；
##   2. **配色走本作暗金**（`menu_theme.quit_panel()`），不搬 nsoc 的白底圆角大卡；
##   3. 额外支持 **Esc = 取消**（nsoc 只有点空白）。
##
## ★ 触发入口（都在 `view/main.gd`）：
##   · 主菜单「选项 → 退出游戏」→ `_on_quit_requested()`；
##   · 安卓返回键（`NOTIFICATION_WM_GO_BACK_REQUEST`）→ `_on_android_back()`
##     （局内先关选项页，再弹本浮层）；
##   · 桌面窗口 X **不拦**（nsoc 原样：`NOTIFICATION_WM_CLOSE_REQUEST` 仍然直接 quit）。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends CanvasLayer

## 玩家点了面板（确认）。★ 真正 quit 由 main.gd 接。
signal confirmed
## 玩家取消了（点空白 / Esc / 重复请求里主动取消）。
signal cancelled

const ConfigRes = preload("res://logic/config.gd")
const ThemeRes = preload("res://view/theme.gd")
const MenuThemeRes = preload("res://view/menu_theme.gd")

## 盖在开场页（100）与 HUD（1）之上。
const LAYER := 200

const DEFAULT_TITLE := "点击面板退出游戏"
const DEFAULT_HINT := "点击空白处或 Esc 取消"
const DEFAULT_TITLE_SIZE := 44
const DEFAULT_HINT_SIZE := 20
const DEFAULT_PANEL_W_RATIO := 0.70
const DEFAULT_PANEL_H_RATIO := 0.50
const DEFAULT_FADE_SEC := 0.18
const DEFAULT_QUIT_FADE_SEC := 0.20
## 全黑之后再**保持**一小会儿才发 confirmed：`process_frame` 有可能在渲染之前就恢复，
## 不留这一小段的话「最后一帧全黑」可能根本没被画出来（用户看到的是界面）。
const DEFAULT_QUIT_HOLD_SEC := 0.10
const DEFAULT_OVERLAY_ALPHA := 0.55

var cfg: ConfigRes = null
var _font: Font = null

var _open: bool = false
var _closing: bool = false
var _tween: Tween = null

var _root: Control = null
var _overlay: ColorRect = null
var _panel: Panel = null
var _title: Label = null
var _hint: Label = null
## 面板像素尺寸（锚点是 0.5 + 半宽半高 offset ⇒ 建好就有这个尺寸；
## 记一份是为了在 layout 还没跑完时也能给 `pivot_offset`）。
var _panel_px: Vector2 = Vector2.ZERO

var _title_text: String = DEFAULT_TITLE
var _hint_text: String = DEFAULT_HINT
var _title_size: int = DEFAULT_TITLE_SIZE
var _hint_size: int = DEFAULT_HINT_SIZE
var _panel_w_ratio: float = DEFAULT_PANEL_W_RATIO
var _panel_h_ratio: float = DEFAULT_PANEL_H_RATIO
var _fade_sec: float = DEFAULT_FADE_SEC
var _quit_fade_sec: float = DEFAULT_QUIT_FADE_SEC
var _quit_hold_sec: float = DEFAULT_QUIT_HOLD_SEC
var _overlay_alpha: float = DEFAULT_OVERLAY_ALPHA


## 由 `view/main.gd` 在 add_child 之后调一次（可以复用同一个实例：
## 关掉之后 `request()` 会重新 build）。
func setup(p_cfg: ConfigRes, p_font: Font) -> void:
	cfg = p_cfg
	_font = p_font
	name = "QuitConfirm"
	layer = LAYER
	visible = false
	_read_config()


func _read_config() -> void:
	if cfg == null:
		return
	_title_text = cfg.str_val("menu.quit_confirm.title", DEFAULT_TITLE)
	_hint_text = cfg.str_val("menu.quit_confirm.hint", DEFAULT_HINT)
	_title_size = cfg.int_val("menu.quit_confirm.title_size", DEFAULT_TITLE_SIZE)
	_hint_size = cfg.int_val("menu.quit_confirm.hint_size", DEFAULT_HINT_SIZE)
	_panel_w_ratio = cfg.num("menu.quit_confirm.panel_w_ratio", DEFAULT_PANEL_W_RATIO)
	_panel_h_ratio = cfg.num("menu.quit_confirm.panel_h_ratio", DEFAULT_PANEL_H_RATIO)
	_fade_sec = cfg.num("menu.quit_confirm.fade_sec", DEFAULT_FADE_SEC)
	_quit_fade_sec = cfg.num("menu.quit_confirm.quit_fade_sec", DEFAULT_QUIT_FADE_SEC)
	_quit_hold_sec = cfg.num("menu.quit_confirm.quit_hold_sec", DEFAULT_QUIT_HOLD_SEC)
	_overlay_alpha = cfg.num("menu.quit_confirm.overlay_alpha", DEFAULT_OVERLAY_ALPHA)


# ------------------------------------------------------------------
# 对外状态 / 动作
# ------------------------------------------------------------------

func is_open() -> bool:
	return _open


## 打开（幂等：已经开着就什么都不做）。
func request() -> void:
	if _open:
		return
	# ★ 上一次「确认退出」之后会把全黑遮罩**留在屏幕上**（等 main quit）。
	#   如果没退出又再次 request（测试 / 或者将来取消了 quit），先把那层全黑拆掉重建。
	if _root != null and is_instance_valid(_root):
		_destroy()
	_build()
	_open = true
	_closing = false
	visible = true
	_play_open()


## 取消（点空白 / Esc）：反向淡出后发 `cancelled`。
func cancel() -> void:
	if not _open or _closing:
		return
	_closing = true
	if not ThemeRes.animations_enabled() or _fade_sec <= 0.0:
		_finish_close(false)
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_overlay, "modulate:a", 0.0, _fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_panel, "scale", Vector2(0.92, 0.92), _fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_panel, "modulate:a", 0.0, _fade_sec)
	_tween = tw
	await tw.finished
	if not is_instance_valid(self):
		return
	_finish_close(false)


## 确认退出：遮罩推成全黑（`quit_fade_sec`）→ **保持 `quit_hold_sec`** → 发 `confirmed`。
##
## ★★ 为什么最后不销毁 UI：那层全黑**必须留到进程真的退出**。
##   之前是「渐黑完成 → 立刻 hide + queue_free → 才 quit」—— 于是最后一帧画的是
##   **底下的界面**（用户实测报的「退出时我看到的还是有界面的」）。
##   现在 confirmed 只把 `_open` 置 false，全黑遮罩保持可见；main quit 之后随进程一起销毁。
func confirm() -> void:
	if not _open or _closing:
		return
	_closing = true
	if not ThemeRes.animations_enabled() or _quit_fade_sec <= 0.0:
		_finish_close(true)
		return
	var tw := create_tween()
	tw.set_parallel(true)
	# ★ 只推遮罩的**颜色 alpha**，不碰 modulate：面板还看得见，但整屏在变黑 ——
	#   这就是「缓冲」那一拍（与 nsoc 直接 quit 的差别）。
	tw.tween_property(_overlay, "color:a", 1.0, _quit_fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_panel, "modulate:a", 0.0, _quit_fade_sec)
	_tween = tw
	await tw.finished
	if not is_instance_valid(self):
		return
	# ★ 再保持一小段全黑：`await` 的恢复点可能早于这一帧的渲染，不留这段的话
	#   「全黑」也许一帧都没画出来。
	if _quit_hold_sec > 0.0:
		await get_tree().create_timer(_quit_hold_sec).timeout
		if not is_instance_valid(self):
			return
	_finish_close(true)


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "QuitRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_overlay = ColorRect.new()
	_overlay.name = "Overlay"
	_overlay.color = Color(0.0, 0.0, 0.0, _overlay_alpha)
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.gui_input.connect(_on_overlay_input)
	_root.add_child(_overlay)

	var vp: Vector2 = _viewport_size()
	var pw: float = maxf(320.0, vp.x * _panel_w_ratio)
	var ph: float = maxf(220.0, vp.y * _panel_h_ratio)
	_panel_px = Vector2(pw, ph)

	_panel = Panel.new()
	_panel.name = "QuitPanel"
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -pw * 0.5
	_panel.offset_right = pw * 0.5
	_panel.offset_top = -ph * 0.5
	_panel.offset_bottom = ph * 0.5
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", MenuThemeRes.quit_panel())
	_panel.gui_input.connect(_on_panel_input)
	_overlay.add_child(_panel)

	# 文字两块：主句 + 一行更暗的提示（提示不是 nsoc 有的，但「点空白取消」不写出来
	# 玩家不会知道 —— 面板本身是「确认」，空白才是「取消」）。
	var center := CenterContainer.new()
	center.name = "QuitCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(center)

	var box := VBoxContainer.new()
	box.name = "QuitBox"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 18)
	center.add_child(box)

	_title = _make_label("QuitTitle", _title_text, _title_size, ThemeRes.text())
	box.add_child(_title)
	_hint = _make_label("QuitHint", _hint_text, _hint_size, ThemeRes.text_dim())
	box.add_child(_hint)


func _make_label(node_name: String, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if _font != null:
		l.add_theme_font_override("font", _font)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


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
# 动效
# ------------------------------------------------------------------

func _play_open() -> void:
	if _overlay == null or _panel == null:
		return
	if not ThemeRes.animations_enabled() or _fade_sec <= 0.0:
		_overlay.modulate.a = 1.0
		_panel.modulate.a = 1.0
		_panel.scale = Vector2.ONE
		return
	_overlay.modulate.a = 0.0
	_panel.modulate.a = 0.0
	_panel.scale = Vector2(0.92, 0.92)
	_panel.pivot_offset = _panel_px * 0.5
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_overlay, "modulate:a", 1.0, _fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "modulate:a", 1.0, _fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "scale", Vector2.ONE, _fade_sec) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_tween = tw


func _finish_close(was_confirmed: bool) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null
	if was_confirmed:
		# ★★ **不销毁**：把遮罩顶成纯黑、面板隐形，保持 visible，直到 main 真的 quit。
		#   否则最后一帧会露出底下的界面（用户实测报过）。
		if _overlay != null and is_instance_valid(_overlay):
			_overlay.color.a = 1.0
			_overlay.modulate.a = 1.0
		if _panel != null and is_instance_valid(_panel):
			_panel.modulate.a = 0.0
		_open = false
		_closing = false
		confirmed.emit()
		return
	_destroy()
	cancelled.emit()


func _destroy() -> void:
	if _root != null and is_instance_valid(_root):
		# ★ 先摘下再 queue_free：queue_free 要到帧末；同一帧里又 request() 的话
		#   旧的（可能是全黑的）子树还挂在上面，会闪一帧。
		var p: Node = _root.get_parent()
		if p != null:
			p.remove_child(_root)
		_root.queue_free()
	_root = null
	_overlay = null
	_panel = null
	_title = null
	_hint = null
	_open = false
	_closing = false
	visible = false


# ------------------------------------------------------------------
# 输入
# ------------------------------------------------------------------

func _on_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_overlay.accept_event()
		cancel()


func _on_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 阻止冒泡到 overlay（panel 是 overlay 的子，事件在 panel 这里就停住）。
		_panel.accept_event()
		confirm()


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventKey:
		var k: InputEventKey = event
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()


# ------------------------------------------------------------------
# 给测试与排查用
# ------------------------------------------------------------------

func overlay() -> ColorRect:
	return _overlay if _overlay != null and is_instance_valid(_overlay) else null


func panel() -> Panel:
	return _panel if _panel != null and is_instance_valid(_panel) else null


func title_label() -> Label:
	return _title if _title != null and is_instance_valid(_title) else null


func hint_label() -> Label:
	return _hint if _hint != null and is_instance_valid(_hint) else null


func fade_sec() -> float:
	return _fade_sec


func quit_fade_sec() -> float:
	return _quit_fade_sec


func quit_hold_sec() -> float:
	return _quit_hold_sec


func panel_size_ratios() -> Vector2:
	return Vector2(_panel_w_ratio, _panel_h_ratio)
