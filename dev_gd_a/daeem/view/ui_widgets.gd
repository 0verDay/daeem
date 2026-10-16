## ui_widgets.gd —— 「造节点」的那一层 UI 工厂
##
## ★ 三个工厂的分工（配色都从 `view/theme.gd` 取，谁都不许自己写死颜色）：
##   · `view/ui_style.gd`   —— 游戏内 HUD 的 StyleBox（面板 / 部队行 / 命令格 / 页签）
##   · `view/menu_theme.gd` —— 进入界面的 StyleBox（按钮 / 弹出列表 / 分隔线）
##   · 本文件               —— 上面两个只**产出 StyleBox**；这里是**产出节点**的那一层：
##     一个徽章 = 底 + 居中文字，一次调用建好，省得每个调用点各拼一遍。
##
## ★ 形状口径跟着这套皮肤走（见 `view/theme.gd` 文件头：只有「渐变暗底 / 1px 金线 /
##   几何图形」三件事）⇒ 这里的件一律**不铺阴影**，圆角只取 2px（= `menu_theme.gd` 里
##   已有的那一档，不是另开一种圆角）。
##
## ⚠️ 颜色参数的默认值是**哨兵**（alpha < 0 = 没给），不是 `ThemeRes.text()` 这类表达式 ——
##   GDScript 的默认参数只能是常量表达式，取不到运行时值；进函数再补默认值
##   （与 `ui_style.panel_style` 同一种写法）。
extends RefCounted

const ThemeRes = preload("res://view/theme.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 徽章默认字号 = HUD 的小字档（★ 不另写一个数字：字号只有 ui_style 那一份）。
const BADGE_FONT_SIZE := UiStyleRes.FS_SMALL
## 小方框那一档的圆角（与 menu_theme 的弹出面板同一档）。
const BADGE_RADIUS := 2
const BADGE_PAD := 4.0
## 数字角标（费用 / 数量这类小方块里的数）默认尺寸与字号。
const NUMBER_BADGE_SIZE := 30.0
const NUMBER_BADGE_FONT_SIZE := 14
## `apply_button_styles()` 认的槽（给了哪一档就挂哪一档）。
const APPLY_SLOTS: Array[String] = ["normal", "hover", "pressed", "disabled", "focus"]


## 徽章底：半透明暗底 + 1px 金线 + 小圆角，**不铺阴影**。
static func badge_style(bg_color: Color = Color(-1, -1, -1, -1),
		border_color: Color = Color(-1, -1, -1, -1)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = (ThemeRes.panel_alpha_color(ThemeRes.PANEL_PRESSED_ALPHA, true)
		if bg_color.a < 0.0 else bg_color)
	s.border_color = ThemeRes.line() if border_color.a < 0.0 else border_color
	s.set_border_width_all(1)
	s.set_corner_radius_all(BADGE_RADIUS)
	s.set_content_margin_all(BADGE_PAD)
	return s


## 文字徽章（效果名 / 状态名这类小标签）：底 + 居中文字。
##
## ★ 整颗徽章 `mouse_filter = IGNORE`：它是**装饰**，不该吃掉底下按钮的点击与悬停
##   （挂在按钮上的小标签要是吃掉事件，那颗按钮就变成"点不动"）。
static func badge(text: String, font_size: int = BADGE_FONT_SIZE,
		text_color: Color = Color(-1, -1, -1, -1)) -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", badge_style())
	p.add_child(_centered_label(text, font_size,
		ThemeRes.text() if text_color.a < 0.0 else text_color))
	return p


## 数字角标：正方形小方框里放一个数（费用 / 数量 …）。
## @param size_px 方框边长；字号单独给，换大小不必跟着改字号。
static func number_badge(value: int, size_px: float = NUMBER_BADGE_SIZE,
		font_size: int = NUMBER_BADGE_FONT_SIZE) -> Panel:
	var p := badge(str(value), font_size)
	p.custom_minimum_size = Vector2(size_px, size_px)
	return p


## 一次挂好一颗按钮的几档底纹（`styles` 里没给的槽保持原样）。
## ★ 只管 stylebox 槽；字色 / 字号不在这里（那是 `font_color_*` / `font_size` 那组 override）。
static func apply_button_styles(btn: Button, styles: Dictionary) -> void:
	for slot in APPLY_SLOTS:
		if styles.has(slot):
			btn.add_theme_stylebox_override(slot, styles[slot])


## 内部：铺满父节点、水平垂直居中、且不吃鼠标的一颗粒子。
static func _centered_label(text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	return lbl
