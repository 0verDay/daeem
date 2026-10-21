## buff_tip.gd —— buff 方块的**悬停浮窗**（贴在方块下缘）
##
## ★ 需求：给动态 buff 加「悬停浮窗」，样式与右下角按钮的悬停详情面板同一套
##   （深色半透明底 + 淡金描边 + 标题 / 正文，高度按内容长）。
##
## ★ 几何：
##   · 宽固定 `BUFF_TIP_W`（230）；
##   · 位置由 view/buff_bar.gd 定：x = 那个 buff 方块的左缘，y = 方块下缘 + 6；
##   · 高度 = 上下留白 + 标题高 + 缝 + 正文折行后的实际高 ⇒ 内容越多越高。
##   ⚠️ 它**向下长**：buff 上方是名称 / 头像，放不下。
##
## ★ 纯显示：`MOUSE_FILTER_IGNORE`。它一旦吃鼠标，就会把光标从 buff 方块上「抢走」，
##   底下的 `mouse_exited` 立刻把浮窗收掉（与 hover_tip.gd 同一个坑）。
extends Panel

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 量高度时先给 Label 一个「肯定够大」的高度（只读最小尺寸）
const MEASURE_H := 4096.0

var _font: Font = null
var _title: Label = null
var _body: Label = null
var _content_h: float = 0.0
var _showing: bool = false


func setup(p_font: Font = null) -> void:
	name = "BuffTip"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 与命令卡那块悬停面板同一套底板（浮在地图 / 面板上，所以底色更实一点）。
	add_theme_stylebox_override("panel", UiStyleRes.hover_panel())
	clip_contents = true
	# 画在 detail_panel 右栏的其它块之上（buff_bar 被摆到最后一个子节点，这里再加一道保险）。
	z_index = 20

	_font = p_font if p_font != null else ThemeDB.fallback_font

	_title = Label.new()
	_title.name = "BuffTipTitle"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.clip_text = true
	_title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_title.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_title.add_theme_color_override("font_color", UiStyleRes.text())
	if _font != null:
		_title.add_theme_font_override("font", _font)
	add_child(_title)

	_body = Label.new()
	_body.name = "BuffTipBody"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.clip_text = true
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	_body.add_theme_color_override("font_color", UiStyleRes.text_dim())
	if _font != null:
		_body.add_theme_font_override("font", _font)
	add_child(_body)

	clear()


## 显示：`title` = buff 名，`body` = 多行说明（`\n` 分隔）。
## 两个都空 → 收起（不留一块空面板）。
func show_text(title: String, body: String) -> void:
	if title == "" and body == "":
		clear()
		return
	_title.text = title
	_body.text = body
	_showing = true
	visible = true
	_relayout()


func clear() -> void:
	if _title != null:
		_title.text = ""
	if _body != null:
		_body.text = ""
	_content_h = 0.0
	_showing = false
	size = Vector2.ZERO
	visible = false


func _relayout() -> void:
	var inner_w: float = UiLayoutRes.BUFF_TIP_W - 2.0 * UiLayoutRes.BUFF_TIP_PAD
	var title_h: float = _measure(_title, inner_w)
	var body_h: float = _measure(_body, inner_w)
	var gap: float = 4.0 if (title_h > 0.0 and body_h > 0.0) else 0.0
	_content_h = 2.0 * UiLayoutRes.BUFF_TIP_PAD + title_h + gap + body_h
	size = Vector2(UiLayoutRes.BUFF_TIP_W, _content_h)

	_title.position = Vector2(UiLayoutRes.BUFF_TIP_PAD, UiLayoutRes.BUFF_TIP_PAD)
	_title.size = Vector2(inner_w, maxf(title_h, 1.0))
	_body.position = Vector2(UiLayoutRes.BUFF_TIP_PAD,
		UiLayoutRes.BUFF_TIP_PAD + title_h + gap)
	_body.size = Vector2(inner_w, maxf(body_h, 1.0))


## 一个 Label 在 `w` 宽下把所有行画出来需要多高（px）。
## ★ 只认 `get_minimum_size()`：它和绘制走同一套排版；`Font.get_multiline_string_size`
##   会少算中文行的行高（命令卡那块面板踩过，见 hover_tip.gd 的注释）。
func _measure(l: Label, w: float) -> float:
	if l.text == "":
		return 0.0
	var want_clip: bool = l.clip_text
	l.clip_text = false
	l.size = Vector2(w, MEASURE_H)
	var h: float = l.get_minimum_size().y
	l.clip_text = want_clip
	return maxf(0.0, h)


# ------------------------------------------------------------------
# 给测试读的小接口
# ------------------------------------------------------------------

func showing() -> bool:
	return _showing


func title_text() -> String:
	return "" if _title == null else _title.text


func body_text() -> String:
	return "" if _body == null else _body.text


func content_height() -> float:
	return _content_h
