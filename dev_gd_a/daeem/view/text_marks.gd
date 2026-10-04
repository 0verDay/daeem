## text_marks.gd —— 进入界面用的两种**自绘**文字 / 线条控件
##
## 需求（参考图）：「暗色色渐变底 + 金色细线边框 + 纯几何形状组合图标」。
## 其中两件事 Label / ColorRect 做不出来，必须自己画：
##   1. **带字距的标题**（参考图里那排拉开的字）：Godot 的 Label 没有 letter-spacing，
##      用空格去凑会变成「首尾各多一块空白」且字距不可控；
##   2. **金色的细线**（参考图的装饰线 + 金线边框）：`draw_line` 画出来的 1px 线
##      在任何缩放下都是**真的 1 像素**，而 ColorRect 的 1px 会跟着 canvas_items 拉伸
##      变粗（0.8 倍缩放下会糊成一条 2px 的灰带）。
##
## ★ 两者都不吃鼠标（mouse_filter = IGNORE）：进入界面的点击是**整页**收的
##   （见 view/start_screen.gd 文件头那条踩坑记录），文字与线都不许把点击吃掉。
##
## ⚠️ 本文件里所有颜色都是从外面传进来的（调用方读 theme.gd）：
##   这样「谁知道主题」这件事只有一个答案 —— 控件只管画。
extends RefCounted


## 一行金色的细线（标题上下的分隔线、底部那条收尾线）。
##
## ⚠️ 它**不参与容器排版**：调用方要自己给 position / size
##   （进入界面的版式是「按设计空间锚点摆」，不是流式布局 ——
##    流式布局在 16:9 之外的窗口比例下会把参考图的版式拉歪）。
class Rule extends Control:
	## 线的颜色（一般传 theme.line()）
	var line_color: Color = Color(0.54, 0.46, 0.25, 1.0)
	## 线宽（像素）。设计稿上是 1；想更重可以调，但**不要**超过 2 —— 参考图里没有粗线。
	var line_width: float = 1.0
	## 两端的渐隐（像素）。0 = 一条实心线；> 0 时两端各有一段淡出，
	## 看着像参考图里那种「中间实、两头化开」的线。
	var fade: float = 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 0.0 or h <= 0.0:
			return
		var y: float = h * 0.5
		if fade <= 0.0 or w <= fade * 2.0:
			draw_line(Vector2(0.0, y), Vector2(w, y), line_color, line_width)
			return
		# 三段：左渐入 → 中间实心 → 右渐出。
		# ★ 用几段不同 alpha 的短线拼（而不是 shader）：线条是 UI 上最不起眼的东西，
		#   为它引一个 ShaderMaterial 不值得，而且 shader 在无头测试里更难断言。
		var steps := 8
		var seg: float = fade / float(steps)
		for i in steps:
			var a: float = float(i + 1) / float(steps)
			var c := Color(line_color.r, line_color.g, line_color.b, line_color.a * a)
			var x0: float = seg * float(i)
			draw_line(Vector2(x0, y), Vector2(x0 + seg, y), c, line_width)
			var x1: float = w - seg * float(i + 1)
			draw_line(Vector2(x1, y), Vector2(x1 + seg, y), c, line_width)
		draw_line(Vector2(fade, y), Vector2(w - fade, y), line_color, line_width)


## 带**字距**的一行字（参考图的标题就是这么排的）。
##
## ★★ 为什么不用 Label + 空格：
##   `"D A E E M"` 会在**每个字之后**都塞一个空格 ⇒ 末尾多出一格空白，
##   居中时整排会往左偏半个字距；而且空格的宽度由字体决定，做不到「想要 26px 就是 26px」。
##   这里逐字推进：`x += 字宽 + tracking`，最后一个字后面**不加**字距，
##   于是总宽 = 各字宽之和 + tracking × (字数 − 1)，居中就是几何居中。
##
## ⚠️ 宽度（`w`）**要调用方给**（版式常量在 config.json 的 menu.title_* 里）：
##   不给就自己量（见 `measured_width()`），但那样每个窗口比例下都可能要重量一次。
class SpacedLabel extends Control:
	## 要画的字（一般 = config 里的 menu.title）
	var text: String = ""
	## 字体（null = 引擎默认字体 —— 中文会变方框，调用方务必给）
	var font: Font = null
	## 字号
	var font_size: int = 64
	## 字距（像素）
	var tracking: float = 0.0
	## 主体颜色（左端）
	var color_from: Color = Color(0.91, 0.89, 0.84, 1.0)
	## 右端颜色。★ 与 color_from 不同时，整排字是**横向渐变**的
	## （参考图里那个标题就是左白右金）—— 这是这套风格里唯一的「给文字上色」手段。
	var color_to: Color = Color(0.85, 0.70, 0.37, 1.0)
	## 阴影颜色（alpha = 0 就不画）。★ 暗底上的亮字需要一点点阴影才不糊：
	## 参考图的标题也有一层很淡的暗边。
	var shadow_color: Color = Color(0.0, 0.0, 0.0, 0.35)
	var shadow_offset: Vector2 = Vector2(0.0, 3.0)

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 逐字推进算出来的总宽（不改控件尺寸，只报数）。
	## ★ 给测试与调用方用：`w` 是按设计稿定的，实际量出来差太多就说明字距 / 字号漂了。
	func measured_width() -> float:
		if text.is_empty():
			return 0.0
		var total := 0.0
		for i in text.length():
			total += _char_advance(i)
		return total + tracking * float(maxi(0, text.length() - 1))

	## 第 i 个字的推进量（像素）。没有字体时退回「按字号估」——
	## 估法只影响版式（不会崩），真机上永远走有字体那条路。
	func _char_advance(i: int) -> float:
		var ch := text.substr(i, 1)
		if font != null:
			return font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		return float(font_size) * 0.62

	func _draw() -> void:
		if text.is_empty() or font == null:
			return
		var total: float = measured_width()
		# 居中：控件给多宽就按多宽居中（版式常量给的是设计稿上的位置与宽度）
		var x: float = (size.x - total) * 0.5
		# ★ 基线要**按字体自己的 ascent 算**，不能按字号估（"字高 = 字号" 是错的）：
		#   块的中心 = ascent 与 descent 的中点 ⇒ baseline = 中心 + (ascent − descent) / 2。
		var ascent: float = font.get_ascent(font_size)
		var descent: float = font.get_descent(font_size)
		var baseline: float = size.y * 0.5 + (ascent - descent) * 0.5
		var n: int = text.length()
		for i in n:
			var ch := text.substr(i, 1)
			# 第 i 个字的颜色 = 从 color_from 到 color_to 的横向渐变（按它在整排里的位置取）
			var t: float = 0.0 if n <= 1 else float(i) / float(n - 1)
			var c: Color = color_from.lerp(color_to, t)
			var pos := Vector2(x, baseline)
			if shadow_color.a > 0.0:
				draw_string(font, pos + shadow_offset, ch,
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, shadow_color)
			draw_string(font, pos, ch, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, c)
			x += _char_advance(i) + tracking
