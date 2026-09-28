## hover_tip.gd —— 右下角按钮的**悬停详情面板**（住在命令卡正上方）
##
## ★★ 需求原话：「为右下角面板中的按钮添加悬停显示，悬停显示显示在右下角面板上方，
##   宽度与右下角面板宽度相同，竖直方向距离你自己定，需要根据悬停详细信息文本
##   动态缩放」。
##
## 分工（与 command_card / tech_grid 同一条边界）：
##   · 「鼠标停在哪一格」由那两个控件报上来（`cell_hovered` / `cell_unhovered`）；
##   · 「这一格要写什么」由 **hud** 决定（它才认识 config、世界状态与中文文案，
##     见 `hud._hover_detail`）—— 本控件**只负责排版与画**，不认识任何玩法概念；
##   · 几何（宽度 / 下缘 / 留白）全部来自 `view/ui_layout.gd`，本文件不写坐标字面量。
##
## ★ 高度是**算出来的**，这是「动态缩放」那一条的落点：
##   宽 = `HOVER_W`（340 = 命令卡 + 右边那一列页签那一整段，见 ui_layout 的 HOVER_W 注释），
##   下缘 = `HOVER_BOTTOM`（命令卡顶边 − 8px），
##   高度 = 上下留白 + 标题实际高度 + 缝 + **正文折行后的实际高度** ⇒ 文字越多越高，
##   而且是**向上长**（下缘钉住），所以永远不会盖住命令卡、也不会掉出屏幕下沿。
##
## ★★ 高度**只问 Label 自己**（`get_minimum_size()`），不许自己拿字体量 ——
##   这条是开窗截图才发现的坑，写在 `_measure()` 上面那段注释里（8 行正文矮 21px、
##   最后两行整条看不见）。别再改回 `Font.get_multiline_string_size()`。
##
## ⚠️ 本控件是 `MOUSE_FILTER_IGNORE`：它只是「画出来的一张说明」。
##   一旦吃鼠标，会有两个坏结果：① 挡住底下的地图点击；② 它自己在鼠标下方时，
##   光标下的那一格会被判成「已离开」⇒ `mouse_exited` 立刻把面板收掉（闪一下就没）。
extends Panel

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")

## 量高度时先给 Label 一个「肯定够大」的高度（只用它的**最小尺寸**那一个读数）
const MEASURE_H := 4096.0

var _font: Font = null
var _title: Label = null
var _body: Label = null
## 上一次算出来的**内容高度**（未夹到 MIN/MAX 之前的那一个）——测试用它钉「按文本缩放」
var _content_h: float = 0.0
var _showing: bool = false


func setup(p_font: Font = null) -> void:
	name = "HoverTip"
	# ★ IGNORE：理由见文件头（吃鼠标会把悬停链自己掐断）
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", UiStyleRes.hover_panel())
	# ★ 兜底：面板被 HOVER_MAX_H 夹过时，正文 Label 也跟着夹（见 _relayout），
	#   这里再上一层保险 —— 任何情况下都不许有字画到面板底板之外。
	clip_contents = true
	# ★ 字体拿不到时退回引擎兜底字体：中文会变方框，但**版式不会散**
	#   （高度为 0 会让面板薄成一条线，那比方框更难看出问题）。
	_font = p_font if p_font != null else ThemeDB.fallback_font

	_title = Label.new()
	_title.name = "HoverTitle"
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.clip_text = true
	_title.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_title.add_theme_font_size_override("font_size", UiStyleRes.FS_BODY)
	_title.add_theme_color_override("font_color", UiStyleRes.TEXT)
	# ★ 字体**显式**设在两个 Label 上（不靠主题继承）：量高度和画字必须是同一个字体，
	#   否则「量出来的行数」与「画出来的行数」会对不上（那正是下面那个坑的同类问题）。
	if _font != null:
		_title.add_theme_font_override("font", _font)
	add_child(_title)

	_body = Label.new()
	_body.name = "HoverBody"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.clip_text = true
	_body.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	# 正文**自动折行**（一行太长时按宽度折，而不是被裁掉）
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	_body.add_theme_color_override("font_color", UiStyleRes.TEXT_DIM)
	if _font != null:
		_body.add_theme_font_override("font", _font)
	add_child(_body)

	clear()


# ------------------------------------------------------------------
# 内容（由 hud 喂）
# ------------------------------------------------------------------

## 显示一块说明。`title` = 那一格的名字，`body` = 多行正文（`\n` 分隔，每行一个字段）。
## ★ 两个都是空串时直接收起来 —— 界面上不留一块空面板。
func show_text(title: String, body: String) -> void:
	if title == "" and body == "":
		clear()
		return
	_title.text = title
	_body.text = body
	_showing = true
	visible = true
	_relayout()


## 收起来（换页 / 鼠标移开 / 换了一格时都由 hud 调它）
func clear() -> void:
	if _title != null:
		_title.text = ""
	if _body != null:
		_body.text = ""
	_content_h = 0.0
	_showing = false
	# ⚠️ 收起时**同时清掉尺寸**（回到 0 高），免得测试 / 截图里读到一个「已经不显示
	#    却还占着 240×120」的幽灵矩形。
	size = Vector2.ZERO
	visible = false


# ------------------------------------------------------------------
# 排版：宽度固定、高度按文本算
# ------------------------------------------------------------------

func _relayout() -> void:
	var inner_w: float = UiLayoutRes.HOVER_W - 2.0 * UiLayoutRes.HOVER_PAD
	var title_h: float = _measure(_title, inner_w)
	var body_h: float = _measure(_body, inner_w)
	var gap: float = UiLayoutRes.HOVER_TITLE_GAP if (title_h > 0.0 and body_h > 0.0) else 0.0
	_content_h = 2.0 * UiLayoutRes.HOVER_PAD + title_h + gap + body_h

	# 贴右下角（anchor_right / anchor_bottom）：改窗口大小它跟着命令卡走
	var r: Rect2 = UiLayoutRes.hover_rect(_content_h)
	UiLayoutRes.apply_rect(self, r, true, true)

	# ⚠️ 面板可能被 HOVER_MAX_H 夹过（文案长到离谱）⇒ 正文 Label 也要跟着夹，
	#    否则字会画到面板底板之外（`clip_contents` 是第二道保险）。
	var body_box: float = maxf(0.0, r.size.y - 2.0 * UiLayoutRes.HOVER_PAD - title_h - gap)

	# ⚠️ 子控件的位置 / 尺寸在**进树之后**设：进树之前主题里的中文字体还没继承到，
	#    Label 会按引擎兜底字体算一次最小尺寸并把 set_size 夹掉（与资源条那条同一个坑）。
	_title.position = Vector2(UiLayoutRes.HOVER_PAD, UiLayoutRes.HOVER_PAD)
	_title.size = Vector2(inner_w, maxf(title_h, 1.0))
	_body.position = Vector2(UiLayoutRes.HOVER_PAD, UiLayoutRes.HOVER_PAD + title_h + gap)
	_body.size = Vector2(inner_w, minf(body_h, body_box))


## 一个 Label 在 `w` 宽下**把所有行都画出来**需要多高（px）。
##
## ★★ 为什么只认这个读数（开窗截图踩出来的）：
##   `Font.get_multiline_string_size(text, ..., w, ...)` 每一行只按 `font.get_height()`
##   算（13 号 = 14px），而 **Label 真正排一行用的是「这一行形状化之后的高度」** ——
##   中文行实测 ≈16.6px。两者差 5%，于是 8 行的正文被算成 112px、真正要 133px：
##   面板矮了 21px，**最后两行整条看不见**（测试全绿，只有截图能看出来）。
##   `Label.get_minimum_size()` 走的是**和绘制同一套**的排版结果，所以这才是对的读数。
##
## ⚠️ 量的时候必须把 `clip_text` 关掉：开着时 Label 的最小尺寸恒为 (1,1)
##   （实现上是「开了 clip 就不报自己的折行高度」），关掉才拿得到折行后的真实高度。
##   量完立刻关回去（面板被 HOVER_MAX_H 夹过时要靠它裁掉多出来的行）。
func _measure(l: Label, w: float) -> float:
	if l.text == "":
		return 0.0
	var want_clip: bool = l.clip_text
	l.clip_text = false
	l.size = Vector2(w, MEASURE_H)     # 宽度先摆好：折行是按当前宽度算的
	var h: float = l.get_minimum_size().y
	l.clip_text = want_clip
	return maxf(0.0, h)


# ------------------------------------------------------------------
# 给测试 / hud 用的小接口
# ------------------------------------------------------------------

## 现在显示着没有
func showing() -> bool:
	return _showing


func title_text() -> String:
	return "" if _title == null else _title.text


func body_text() -> String:
	return "" if _body == null else _body.text


## 上次算出来的内容高度（**未夹到 MIN / MAX 之前**的那个数）——
## 测试钉「文字越多越高」用它是稳的（不受 MIN_H 兜底影响）。
func content_height() -> float:
	return _content_h


## 正文折行之后一共几行 / 其中画得出来几行。
## ★★ 这两个数是那个坑的**回归判据**：`visible < lines` 就意味着面板矮了、末尾被裁了。
func body_lines() -> int:
	return 0 if _body == null else _body.get_line_count()


func body_visible_lines() -> int:
	return 0 if _body == null else _body.get_visible_line_count()
