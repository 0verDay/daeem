## ui_text.gd —— 自绘文本的两个小工具（字距 / 宽度）
##
## ★ 为什么需要它：方向稿里那些「属性 / 编制 / 将领特性」的小标题带**字距**
##   （`letter-spacing: .14em`），那是这套皮肤观感的一半。Godot 的 `draw_string()`
##   没有字距参数，只能一字一字画 —— 于是抽到这里，别让每个面板各抄一遍。
##
## ⚠️ 只做「画」和「量」两件事，不持有状态：调用方自己管字体与重绘。
extends RefCounted


## 画一行带字距的文本。
##   @param tracking 每个字之后额外加的空隙（px）；0 = 与 `draw_string()` 等价
##   @return 这一行的实际宽度（含字距），方便调用方接着往下排
static func tracked(ci: CanvasItem, font: Font, pos: Vector2, text: String,
		font_size: int, color: Color, tracking: float = 1.0) -> float:
	if font == null or text == "":
		return 0.0
	if tracking <= 0.0:
		ci.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
		return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var x := pos.x
	for i in text.length():
		var ch := text.substr(i, 1)
		ci.draw_string(font, Vector2(x, pos.y), ch, HORIZONTAL_ALIGNMENT_LEFT,
			-1, font_size, color)
		x += font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + tracking
	return x - pos.x - tracking


## 带字距那一行的宽度（不画，只量）。
static func tracked_width(font: Font, text: String, font_size: int,
		tracking: float = 1.0) -> float:
	if font == null or text == "":
		return 0.0
	var base := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	if tracking <= 0.0:
		return base
	return base + tracking * float(maxi(0, text.length() - 1))


## 单行裁剪：宽度不够时截断并补「…」。
static func fit(font: Font, text: String, max_w: float, font_size: int) -> String:
	if font == null or max_w <= 0.0:
		return text
	if font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
		return text
	var s := text
	while s.length() > 1:
		s = s.substr(0, s.length() - 1)
		if font.get_string_size(s + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= max_w:
			return s + "…"
	return "…"


## 居中画一行字（`rect` 的中心）。
static func centered(ci: CanvasItem, font: Font, rect: Rect2, text: String,
		font_size: int, color: Color) -> void:
	if font == null or text == "":
		return
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	var baseline := rect.position.y + rect.size.y * 0.5 + float(font_size) * 0.36
	ci.draw_string(font, Vector2(rect.position.x + (rect.size.x - w) * 0.5, baseline),
		text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
