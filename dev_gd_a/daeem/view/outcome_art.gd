## outcome_art.gd —— 结算画面的三块**纯自绘**图形：王冠 / 宝石 / 横幅
##
## 为什么不用贴图（与 view/menu_emblem.gd 同一条口径）：
##   · 参考图本身是线稿，本作 UI 也只有三种视觉手段：暗底、1px 金线、几何图形；
##   · 贴图在 1920×1080 / 手机 / 不同窗口比例下都要另做一套，而线稿画法随 `size` 缩放；
##   · 全部是 `_draw()`，无头测试也能直接实例化、数「画过几帧」。
##
## ★★ 三个类都只负责「画自己」，不认识结算流程、不认识按钮：
##   · `Crown` —— 王冠线稿 + 裂纹；`dim_t` 让它整体变暗（失败用）；
##   · `Gem`   —— 菱形宝石（四边 + 内部刻面）；
##   · `Banner` —— 从中心向左右拉开的横幅底板（宽度由 `open_t` 控制）。
##   流程与动效在 view/outcome_overlay.gd；这里只暴露「进度」和颜色。
##
## ⚠️ 为什么拆成一个文件里的三个类：它们共享同一套「归一化坐标 → 控件像素」的
##   换算与描边口径；分成三个文件会让那几行抄三遍（本项目最怕两份实现）。
##   调用方式：`const OutcomeArtRes = preload(...)` → `OutcomeArtRes.Crown.new()`。
extends RefCounted


# ==================================================================
# 王冠
# ==================================================================

class Crown extends Control:
	## ★ 内层类看不到外层文件的常量（GDScript 口径），所以三个类各自 preload 一次。
	const ThemeRes = preload("res://view/theme.gd")

	## 参考图的三峰王冠：左外尖 → 左谷 → 中峰 → 右谷 → 右外尖 → 右下底 → 左下底。
	## 坐标都是 0~1（相对本控件），由 `_scaled()` 换算成像素。
	var POINTS := PackedVector2Array([
		Vector2(0.12, 0.94),   # 左下底
		Vector2(0.02, 0.53),   # 左外尖
		Vector2(0.28, 0.69),   # 左谷
		Vector2(0.50, 0.03),   # 中峰
		Vector2(0.72, 0.69),   # 右谷
		Vector2(0.98, 0.53),   # 右外尖
		Vector2(0.88, 0.94),   # 右下底
	])

	## 失败时的裂纹：每条都是独立折线（从主裂纹分叉出去）。
	## ★ 只出现裂纹、不散落（用户口径）；`crack_t` 从 0 到 1 时逐段画出来。
	var CRACKS := [
		# 主裂纹：从王冠上半部一路裂到底边
		PackedVector2Array([
			Vector2(0.50, 0.14),
			Vector2(0.47, 0.30),
			Vector2(0.55, 0.43),
			Vector2(0.50, 0.56),
			Vector2(0.57, 0.70),
			Vector2(0.54, 0.82),
		]),
		# 左分叉
		PackedVector2Array([
			Vector2(0.47, 0.30),
			Vector2(0.36, 0.38),
			Vector2(0.31, 0.50),
		]),
		# 右分叉
		PackedVector2Array([
			Vector2(0.55, 0.43),
			Vector2(0.67, 0.49),
			Vector2(0.73, 0.61),
		]),
	]

	const LINE_WIDTH := 2.2
	## 裂纹的「缝」宽度与高光宽度：先用深色把王冠线切断，再压一条浅色断口。
	## ★ 高光刻意压得比较低（0.55 不透明度、1.0px）：失败时王冠本来就变暗了，
	##   裂纹再画成亮白就会出现「只剩几道白线、王冠看不见」的观感（实测截图）。
	const CRACK_GAP_WIDTH := 4.5
	const CRACK_LINE_WIDTH := 1.0
	## ★★ 裂纹整体下移量（相对王冠高度，0~1；用户口径：裂纹偏上，往下放一点）。
	##   0.12 = 250px 高的王冠上约 30px，主裂纹末端正好落到王冠底边。
	const CRACK_Y_OFFSET := 0.12

	## 金色线（胜利 / 失败**渐入时都是** theme.accent；失败随后再降到 `dim_color`）
	var line_color: Color = ThemeRes.accent()
	## 变暗之后的目标色（默认暖灰；结算层会按结果覆盖成暗金 / 更暗的灰）
	var dim_color: Color = Color(0.46, 0.44, 0.40, 1.0)
	## 0 = 原始亮度，1 = 整体变暗（失败时随裂纹一起推进）
	var dim_t: float = 0.0
	## 0 = 没有裂纹，1 = 裂纹全部出现
	var crack_t: float = 0.0
	## 画过几帧（测试用：`_draw()` 里出错不会让测试失败，所以盯一下它真的跑了）
	var draw_count: int = 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		queue_redraw()

	func set_dim(t: float) -> void:
		dim_t = clampf(t, 0.0, 1.0)
		queue_redraw()

	func set_crack(t: float) -> void:
		crack_t = clampf(t, 0.0, 1.0)
		queue_redraw()

	## 当前实际描边色（测试与排查用）。
	func current_line_color() -> Color:
		return line_color.lerp(dim_color, dim_t)

	func _draw() -> void:
		draw_count += 1
		if size.x < 4.0 or size.y < 4.0:
			return
		var pts := _scaled(POINTS)
		var closed := pts.duplicate()
		closed.append(pts[0])
		var col := current_line_color()

		# 1) 一层很淡的宽光晕：让金线在暗底上有「微微发光」的厚度。
		#    失败变暗之后不再发光（dim_t 越高越弱）。
		var glow := dim_t * 0.9
		if glow < 1.0:
			var gc := Color(col.r, col.g, col.b, 0.10 * (1.0 - glow))
			draw_polyline(closed, gc, LINE_WIDTH * 6.0, true)

		# 2) 主描边
		draw_polyline(closed, col, LINE_WIDTH, true)

		# 3) 裂纹（只画到 `crack_t` 的进度）
		if crack_t > 0.0:
			_draw_cracks(pts)

	## 把 0~1 坐标换算成当前控件像素。
	## @param y_offset 额外的纵向偏移（0~1，只有裂纹用得到）
	func _scaled(norm: PackedVector2Array, y_offset: float = 0.0) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in norm:
			out.append(Vector2(p.x * size.x, (p.y + y_offset) * size.y))
		return out

	## 逐段揭示裂纹：总长度 × crack_t = 这一帧允许画多长。
	func _draw_cracks(_crown_pts: PackedVector2Array) -> void:
		var total := 0.0
		for line in CRACKS:
			var pts: PackedVector2Array = _scaled(line, CRACK_Y_OFFSET)
			for i in range(pts.size() - 1):
				total += pts[i].distance_to(pts[i + 1])
		if total <= 0.0:
			return
		var budget: float = total * crack_t
		var gap_col := Color(0.04, 0.05, 0.07, 0.92)
		var lit_col := ThemeRes.with_alpha(ThemeRes.text(), 0.55)
		for line in CRACKS:
			var pts: PackedVector2Array = _scaled(line, CRACK_Y_OFFSET)
			for i in range(pts.size() - 1):
				if budget <= 0.0:
					return
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				var seg: float = a.distance_to(b)
				if seg <= 0.0001:
					continue
				var frac: float = minf(1.0, budget / seg)
				var endp: Vector2 = a.lerp(b, frac)
				# 深色缝：把金线切断，看起来才是「裂开」而不是「画了条线」
				draw_line(a, endp, gap_col, CRACK_GAP_WIDTH, true)
				# 浅色断口：暗底上真正看得见的那一笔
				draw_line(a + Vector2(0.0, -1.0), endp + Vector2(0.0, -1.0),
					lit_col, CRACK_LINE_WIDTH, true)
				budget -= seg


# ==================================================================
# 宝石（菱形）
# ==================================================================

class Gem extends Control:
	const ThemeRes = preload("res://view/theme.gd")

	var OUTER := PackedVector2Array([
		Vector2(0.50, 0.02),
		Vector2(0.96, 0.38),
		Vector2(0.50, 0.98),
		Vector2(0.04, 0.38),
	])

	## 内部刻面：台面横线 + 从四个顶点收向台面的两条棱线。
	## ★ 只画线、不画宝石的「实体」，与参考图的线稿一致；
	##   内部只垫一层很淡的金色（alpha 0.12），让它在王冠中央有点体积。
	var FACETS := [
		PackedVector2Array([Vector2(0.04, 0.38), Vector2(0.96, 0.38)]),
		PackedVector2Array([Vector2(0.04, 0.38), Vector2(0.30, 0.38)]),
		PackedVector2Array([Vector2(0.50, 0.02), Vector2(0.30, 0.38)]),
		PackedVector2Array([Vector2(0.50, 0.02), Vector2(0.70, 0.38)]),
		PackedVector2Array([Vector2(0.96, 0.38), Vector2(0.70, 0.38)]),
		PackedVector2Array([Vector2(0.30, 0.38), Vector2(0.50, 0.98)]),
		PackedVector2Array([Vector2(0.70, 0.38), Vector2(0.50, 0.98)]),
	]

	const LINE_WIDTH := 1.8

	var line_color: Color = ThemeRes.accent_bright()
	var draw_count: int = 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		queue_redraw()

	func _draw() -> void:
		draw_count += 1
		if size.x < 4.0 or size.y < 4.0:
			return
		var outer := _scaled(OUTER)
		# 很淡的体积感：压在刻面线下面，不盖住线
		draw_colored_polygon(outer, ThemeRes.accent_alpha(0.12))
		var closed := outer.duplicate()
		closed.append(outer[0])
		draw_polyline(closed, line_color, LINE_WIDTH, true)
		for line in FACETS:
			draw_polyline(_scaled(line), line_color, LINE_WIDTH * 0.8, true)

	func _scaled(norm: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		for p in norm:
			out.append(Vector2(p.x * size.x, p.y * size.y))
		return out


# ==================================================================
# 横幅（从中心向左右拉开）
# ==================================================================

class Banner extends Control:
	const ThemeRes = preload("res://view/theme.gd")

	var line_color: Color = ThemeRes.line()
	var accent_color: Color = ThemeRes.accent()
	## 最终宽度（屏幕像素）。`open_t` 从 0 到 1 时只画其中一段。
	var target_width: float = 0.0
	var open_t: float = 0.0
	var draw_count: int = 0

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		queue_redraw()

	func set_open(t: float) -> void:
		open_t = clampf(t, 0.0, 1.0)
		queue_redraw()

	func current_width() -> float:
		return maxf(0.0, target_width * open_t)

	func _draw() -> void:
		draw_count += 1
		if size.x < 4.0 or size.y < 4.0:
			return
		var w: float = current_width()
		if w <= 0.5:
			return
		var h: float = size.y
		var x: float = (size.x - w) * 0.5
		# 1) 一层很淡的投影：横幅是「压在地图上」的一块板
		draw_rect(Rect2(x + 1.0, 5.0, maxf(0.0, w - 2.0), maxf(0.0, h - 1.0)),
			Color(0.0, 0.0, 0.0, 0.35), true)
		# 2) 底板：近不透明的面板层底色
		var rect := Rect2(x + 0.5, 0.5, maxf(0.0, w - 1.0), maxf(0.0, h - 1.0))
		draw_rect(rect, ThemeRes.with_alpha(ThemeRes.bg_bottom(), 0.95), true)
		# 3) 1px 金线边框
		draw_rect(rect, line_color, false, 1.0)
		# 4) 上下两条内嵌的强调线（只在拉开到足够宽时出现）
		if w > 48.0:
			var inset: float = 10.0
			var line_a := ThemeRes.with_alpha(accent_color, 0.55)
			draw_line(Vector2(x + inset, 7.0), Vector2(x + w - inset, 7.0), line_a, 1.0, true)
			draw_line(Vector2(x + inset, h - 7.0), Vector2(x + w - inset, h - 7.0),
				ThemeRes.with_alpha(accent_color, 0.25), 1.0, true)
		# 5) 两端的小菱形端饰
		if w > 36.0:
			_draw_end_diamond(Vector2(x + 8.0, h * 0.5), 5.0)
			_draw_end_diamond(Vector2(x + w - 8.0, h * 0.5), 5.0)

	func _draw_end_diamond(center: Vector2, r: float) -> void:
		var pts := PackedVector2Array([
			center + Vector2(0.0, -r),
			center + Vector2(r, 0.0),
			center + Vector2(0.0, r),
			center + Vector2(-r, 0.0),
		])
		var closed := pts.duplicate()
		closed.append(pts[0])
		draw_polyline(closed, accent_color, 1.0, true)
