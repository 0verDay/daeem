## test_ui_kit.gd —— ★★ 通用 UI 工具件（滚动列表 / 拖动滚动 / 入场淡入 / 徽章部件）
##
## 这几件都是从另一个项目（nsoc）搬过来的**零依赖**工具，目前还没接进任何界面，
## 所以这里断言的是**它们自己的几何与手感**，而不是「某个界面长什么样」：
##   · 橡皮筋是不是真的被阻尼（拖 100px 只走 43px 这种）；
##   · 手感数值是不是真的来自 config.json（而不是抄在代码里的常量）；
##   · 关掉动效总开关时是不是「立刻就位」（而不是「没有反馈」）；
##   · 徽章的配色是不是跟着主题走（不许出现别处那套蓝）。
extends "res://tests/test_case.gd"

const ElasticScrollListRes = preload("res://view/elastic_scroll_list.gd")
const DragScrollHelperRes = preload("res://view/drag_scroll_helper.gd")
const FadeInRes = preload("res://view/fade_in.gd")
const UiWidgetsRes = preload("res://view/ui_widgets.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
const ThemeRes = preload("res://view/theme.gd")


func _initialize() -> void:
	_case_name = "ui_kit"
	_run()


func _run() -> void:
	# ★ 先过一帧再动：`--script` 模式下 `_initialize()` 里 root 还**没就绪**，
	#   此时 `add_child()` 进来的节点要等下一帧才走 `_ready()` ——
	#   而下面要断言的正是 `_ready()` 里建出来的东西（内容层 / 手感参数）。
	#   过完这一帧之后，`add_child()` 会当场触发 `_ready()`（与 test_map_select.gd 同一种写法）。
	await process_frame

	_test_config_tunables()
	_test_config_clamps()
	_test_badge_style_follows_theme()
	_test_badge_node()
	_test_number_badge()
	_test_apply_button_styles()
	_test_scroll_layout()
	_test_rubber_band()
	_test_short_content_never_scrolls()
	_test_settle_switches_with_animation_flag()
	_test_tunables_come_from_config()
	_test_drag_scroll_helper()
	_test_fade_in()

	# 协程自己收尾（`run_all()` 是同步的，会在 await 之前就把「通过 0 项」报出来）。
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# config.json 里的新手感数值
# ------------------------------------------------------------------

func _test_config_tunables() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	near(cfg.scroll_resistance, 0.55, 0.0001, "ui.scroll_resistance 读到了")
	near(cfg.scroll_settle_sec, 0.28, 0.0001, "ui.scroll_settle_sec 读到了")
	near(cfg.scroll_drag_min_px, 18.0, 0.0001, "ui.scroll_drag_min_px 读到了")
	near(cfg.scroll_wheel_step_px, 60.0, 0.0001, "ui.scroll_wheel_step_px 读到了")
	near(cfg.drag_scroll_min_px, 8.0, 0.0001, "ui.drag_scroll_min_px 读到了")
	near(cfg.fade_in_sec, 0.4, 0.0001, "ui.fade_in_sec 读到了")
	ok(cfg.drag_scroll_min_px < cfg.scroll_drag_min_px,
		"★ 原生滚动那条阈值比滚动列表的小（它不存在「把点一下误判成滚动」的问题）")


func _test_config_clamps() -> void:
	# 用**自己这一份**配置实例，把解析出来的字典写坏再重跑一次载入整理 ——
	# 不动磁盘上的 config.json（ConfigRes.load_default() 每次都新建实例）。
	var cfg = require_config()
	if cfg == null:
		return
	var ui: Dictionary = cfg.data["ui"]
	ui["scroll_resistance"] = 0.0
	ui["scroll_settle_sec"] = -5.0
	ui["scroll_drag_min_px"] = "坏值"
	ui["scroll_wheel_step_px"] = -1.0
	ui["drag_scroll_min_px"] = 0.0
	ui["fade_in_sec"] = -2.0
	cfg._cache_scalars()
	ok(cfg.scroll_resistance >= 0.05,
		"★★ 阻力写 0 → 夹到下限（阻尼公式的分子会恒为 0 = 永远拉不动）")
	eq(cfg.scroll_settle_sec, 0.0, "★★ 回弹时长写成负数 → 夹到 0（0 = 立即回弹）")
	near(cfg.scroll_drag_min_px, 18.0, 0.0001, "★ 阈值写成字符串 → 退回兜底 18")
	near(cfg.scroll_wheel_step_px, 1.0, 0.0001, "★ 滚轮步长写成负数 → 夹到 1px")
	near(cfg.drag_scroll_min_px, 1.0, 0.0001, "★ 拖动阈值写成 0 → 夹到 1px")
	eq(cfg.fade_in_sec, 0.0, "★ 淡入时长写成负数 → 夹到 0")


# ------------------------------------------------------------------
# 徽章 / 数字角标 / 按钮底纹
# ------------------------------------------------------------------

func _test_badge_style_follows_theme() -> void:
	var sb: StyleBoxFlat = UiWidgetsRes.badge_style()
	ok(sb != null, "badge_style() 产出一个 StyleBoxFlat")
	if sb == null:
		return
	eq(sb.border_color, ThemeRes.line(), "★★ 描边色就是主题的 line()（金线）")
	ok(sb.border_color.r > sb.border_color.b, "★ 描边是金（R > B）—— 不是别处那套蓝")
	eq(sb.border_width_left, 1, "1px 描边（这套皮肤只有「1px 金线」这一种线）")
	eq(sb.border_width_top, 1, "四条边都是 1px")
	eq(sb.bg_color, ThemeRes.panel_alpha_color(ThemeRes.PANEL_PRESSED_ALPHA, true),
		"★★ 底色来自主题的面板档（半透明暗底，与整套皮肤同源）")
	ok(sb.bg_color.a > 0.2 and sb.bg_color.a < 1.0, "★ 是半透明的（徽章浮在面板上的小标签）")
	ok(sb.corner_radius_top_left <= 3 and sb.corner_radius_bottom_right <= 3,
		"★★ 圆角 ≤ 3px —— 这套皮肤没有圆角化的花边（见 view/theme.gd 文件头）")
	eq(sb.shadow_size, 0, "★★ 不铺阴影")
	ok(sb.content_margin_left > 0.0, "有内边距（文字不贴边）")

	var custom: StyleBoxFlat = UiWidgetsRes.badge_style(ThemeRes.accent(), ThemeRes.warning())
	eq(custom.bg_color, ThemeRes.accent(), "底色可覆盖")
	eq(custom.border_color, ThemeRes.warning(), "描边可覆盖")


func _test_badge_node() -> void:
	var p = UiWidgetsRes.badge("压制")
	root.add_child(p)
	eq(p.mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"★★ 徽章不吃鼠标 —— 挂在按钮上的小标签要是吃事件，那颗按钮就「点不动」")
	eq(p.get_child_count(), 1, "徽章里就是一颗粒子：居中文字")
	var lbl: Label = p.get_child(0)
	eq(lbl.text, "压制", "文字原样放进去")
	eq(lbl.horizontal_alignment, HORIZONTAL_ALIGNMENT_CENTER, "水平居中")
	eq(lbl.vertical_alignment, VERTICAL_ALIGNMENT_CENTER, "垂直居中")
	eq(lbl.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 文字也不吃鼠标")
	eq(lbl.get_theme_font_size("font_size"), UiWidgetsRes.BADGE_FONT_SIZE, "字号默认走小字档")
	eq(UiWidgetsRes.BADGE_FONT_SIZE, UiStyleRes.FS_SMALL,
		"★★ 而且就是 ui_style 那一份（不另起一个字号档）")
	eq(lbl.get_theme_color("font_color"), ThemeRes.text(), "字色是主题正文色")
	ok(is_equal_approx(lbl.anchor_right, 1.0) and is_equal_approx(lbl.anchor_bottom, 1.0),
		"文字铺满徽章（锚点铺满，居中才有意义）")
	p.queue_free()


func _test_number_badge() -> void:
	var p = UiWidgetsRes.number_badge(7)
	root.add_child(p)
	v2_near(p.custom_minimum_size,
		Vector2(UiWidgetsRes.NUMBER_BADGE_SIZE, UiWidgetsRes.NUMBER_BADGE_SIZE), 0.01,
		"数字角标默认是正方形")
	var lbl: Label = p.get_child(0)
	eq(lbl.text, "7", "数字进了角标")
	eq(p.mouse_filter, Control.MOUSE_FILTER_IGNORE, "★ 角标不吃鼠标")

	var big = UiWidgetsRes.number_badge(12, 44.0, 20)
	root.add_child(big)
	v2_near(big.custom_minimum_size, Vector2(44.0, 44.0), 0.01, "★ 边长可覆盖")
	var big_lbl: Label = big.get_child(0)
	eq(big_lbl.get_theme_font_size("font_size"), 20, "★ 字号可覆盖")
	eq(big_lbl.text, "12", "两位数也放得进去")
	p.queue_free()
	big.queue_free()


func _test_apply_button_styles() -> void:
	var b := Button.new()
	root.add_child(b)

	var normal: StyleBoxFlat = UiStyleRes.tab_normal()
	var hover: StyleBoxFlat = UiStyleRes.tab_hover()
	UiWidgetsRes.apply_button_styles(b, {
		"normal": normal,
		"hover": hover,
		"pressed": UiStyleRes.tab_active(),
		"disabled": UiStyleRes.tech_disabled(),
	})
	for slot in ["normal", "hover", "pressed", "disabled"]:
		ok(b.has_theme_stylebox_override(slot), "%s 槽挂上了" % slot)
	ok(b.get_theme_stylebox("normal") == normal,
		"★ 挂的就是**传进去的那一个** StyleBox（不是又新建一份）")
	ok(b.get_theme_stylebox("hover") == hover, "悬停槽同理")
	ok(b.get_theme_stylebox("normal") != b.get_theme_stylebox("hover"),
		"常态与悬停不是同一个底纹")

	# 只给一档时，别的槽不动
	var swapped: StyleBoxFlat = UiStyleRes.tab_plain()
	UiWidgetsRes.apply_button_styles(b, {"normal": swapped})
	ok(b.get_theme_stylebox("normal") == swapped, "第二次调用换掉了 normal")
	ok(b.get_theme_stylebox("hover") == hover, "★ 没给的槽保持原样")
	ok(not b.has_theme_stylebox_override("focus"),
		"★ 没给 focus 就不挂（focus 空框由调用方自己决定）")
	b.queue_free()


# ------------------------------------------------------------------
# 橡皮筋滚动列表
# ------------------------------------------------------------------

func _test_scroll_layout() -> void:
	var list = _make_list(200.0)
	var box: VBoxContainer = list.get_content_box()
	ok(box is VBoxContainer, "★ get_content_box() 给的是 VBoxContainer（调用方直接往里 add_child）")
	var layer: Control = box.get_parent()
	ok(layer != null and layer != list,
		"★ 内容住在中间那一层里（被平移的是它，不是列表自己）")
	ok(layer.mouse_filter != Control.MOUSE_FILTER_STOP,
		"★ 内容层不吃鼠标 —— 拖动由全局 _input 负责，命中还是交给子项")

	list.set_item_separation(12)
	eq(box.get_theme_constant("separation"), 12, "★ set_item_separation() 生效")

	_fill(box, 2, 300.0)
	list._do_layout()
	var expect: float = box.get_combined_minimum_size().y - list.size.y
	near(list.max_scroll(), expect, 0.01, "★ 可滚距离 = 内容高 − 视口高")
	ok(list.max_scroll() > 300.0, "（前提）确实超出视口不少（%.0f px）" % list.max_scroll())
	eq(list.logical_offset(), 0.0, "起手停在顶部（偏移 0）")

	# 内容再长一截 → 重排会重新算（不是只在第一次算完就定死）
	var before: float = list.max_scroll()
	_fill(box, 1, 100.0)
	list._do_layout()
	ok(list.max_scroll() > before,
		"★ 内容长高之后重排会重算可滚距离（%.0f → %.0f px）" % [before, list.max_scroll()])
	list.queue_free()


func _test_rubber_band() -> void:
	var list = _make_list(200.0)
	_fill(list.get_content_box(), 2, 300.0)
	list._do_layout()
	var limit: float = list.max_scroll()
	ok(limit > 0.0, "（前提）内容超出视口 %.0f px" % limit)

	# 顶部过拉：拖了 100px，画面上只走了一部分
	list.scroll_to(-100.0)
	var top: float = list.display_offset()
	ok(top < 0.0 and top > -100.0,
		"★★ 顶部过拉 100px → 画面上只走 %.1fpx（拉过量被阻尼吃掉了一部分）" % top)
	# 公式 f(x) = (x·c·d)/(d + c·x)：d = 视口高、c = config 里的阻力
	var expected: float = (100.0 * list.resistance() * list.size.y) \
		/ (list.size.y + list.resistance() * 100.0)
	near(top, -expected, 0.01,
		"★★ 过拉量就是「橡皮筋公式」算出来的（c=%.2f, d=%.0f）" % [list.resistance(), list.size.y])

	# 合法区间内：1:1，不阻尼
	list.scroll_to(120.0)
	near(list.display_offset(), 120.0, 0.001, "★ 区间内 1:1 跟手（拖动与画面同步）")

	# 底部过拉：同样被阻尼，且到不了「到底 + 全额拉过量」
	list.scroll_to(limit + 100.0)
	var bottom: float = list.display_offset()
	ok(bottom > limit and bottom < limit + 100.0,
		"★★ 底部过拉也被阻尼（%.1f ∈ (%.1f, %.1f)）" % [bottom, limit, limit + 100.0])

	# 拉过头之后再重排 → 夹回边界（内容缩水时不会留一条缝）
	list._do_layout()
	eq(list.logical_offset(), limit, "★★ 重排把越界偏移夹回 [0, max]")
	list.queue_free()


func _test_short_content_never_scrolls() -> void:
	var list = _make_list(400.0)
	_fill(list.get_content_box(), 1, 50.0)
	list._do_layout()
	eq(list.max_scroll(), 0.0, "★ 内容比视口矮 → 可滚距离 0（整件事与它无关）")

	list.scroll_to(-80.0)
	list._do_layout()
	eq(list.logical_offset(), 0.0,
		"★★ 重排会把越界偏移夹回来（视口变高 / 内容缩水之后不会留一条缝）")
	list.queue_free()


func _test_settle_switches_with_animation_flag() -> void:
	var list = _make_list(200.0)
	_fill(list.get_content_box(), 2, 300.0)
	list._do_layout()
	var limit: float = list.max_scroll()

	# 动效开着：建 Tween，且这一刻还没动
	list.scroll_to(-100.0)
	list._settle_to_clamped()
	ok(list._settle_tween != null, "★ 动效开着时回弹建了一个 Tween")
	near(list.logical_offset(), -100.0, 0.01, "★ 建完 Tween 这一刻还没动（进度由 Tween 逐帧推）")
	list._kill_settle_tween()

	# 动效关掉：立刻就位，且不建 Tween
	ThemeRes.set_animations_enabled(false)
	list.scroll_to(-100.0)
	list._settle_to_clamped()
	eq(list.logical_offset(), 0.0,
		"★★ 关掉动效 → 回弹**立刻就位**（关掉动效是「立即到位」，不是「没有反馈」）")
	ok(list._settle_tween == null, "★★ 而且不建 Tween（省掉每帧一次的插值）")
	eq(list.display_offset(), 0.0, "★ 画面上也回到边界（不会停在半路）")
	ThemeRes.set_animations_enabled(true)

	# 时长写成 0 的那一档：同样立刻就位
	var old_settle: float = list._settle_sec
	list._settle_sec = 0.0
	list.scroll_to(limit + 200.0)
	list._settle_to_clamped()
	eq(list.logical_offset(), limit, "★ ui.scroll_settle_sec = 0 → 立即回弹到边界")
	ok(list._settle_tween == null, "★ 也不建 Tween")
	list._settle_sec = old_settle
	list.queue_free()


func _test_tunables_come_from_config() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var list = _make_list(200.0)
	near(list.resistance(), cfg.scroll_resistance, 0.0001,
		"★★ 阻尼系数来自 config.json（不是代码里写死的常量）")
	near(list.settle_sec(), cfg.scroll_settle_sec, 0.0001, "★ 回弹时长同理")
	near(list.drag_min_px(), cfg.scroll_drag_min_px, 0.0001, "★ 滚动阈值同理")
	near(list.wheel_step_px(), cfg.scroll_wheel_step_px, 0.0001, "★ 滚轮步长同理")
	list.queue_free()


# ------------------------------------------------------------------
# 原生 ScrollContainer 的拖动滚动
# ------------------------------------------------------------------

func _test_drag_scroll_helper() -> void:
	var cfg = require_config()
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(200.0, 200.0)
	root.add_child(scroll)

	var starts: Array = []
	var helper = DragScrollHelperRes.new()
	helper.setup(scroll, func(): starts.append(1))
	scroll.add_child(helper)

	eq(scroll.gui_input.get_connections().size(), 1, "★ setup() 之后 gui_input 只接了一条线")
	if cfg != null:
		near(helper.drag_min_px(), cfg.drag_scroll_min_px, 0.0001,
			"★★ 拖动阈值来自 config.json")

	# 按下但不动：只是按压，还不算拖动
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.global_position = Vector2(20.0, 20.0)
	scroll.gui_input.emit(down)
	ok(helper.is_pressing(), "★ 按下之后进入按压态")
	ok(not helper.is_dragging(), "★★ 只按一下不算拖动（阈值以内）")
	ok(starts.is_empty(), "★ 阈值没到之前不回调 on_drag_start")

	# 松开（没拖动过）：退出按压态，且不该吃掉这次释放
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.global_position = Vector2(20.0, 20.0)
	scroll.gui_input.emit(up)
	ok(not helper.is_pressing(), "松开之后退出按压态")
	ok(not helper.is_dragging(), "也没进入拖动态")
	ok(starts.is_empty(), "全程没触发 on_drag_start")

	# ★ 这里**故意不**模拟「超过阈值的拖动」：那条路会调 accept_event()，
	#   而无头测试里没有真正的输入上下文，引擎会报错。
	helper.setup(scroll)
	eq(scroll.gui_input.get_connections().size(), 1, "★ 重复 setup() 不会挂第二条线")
	scroll.queue_free()


# ------------------------------------------------------------------
# 入场淡入
# ------------------------------------------------------------------

func _test_fade_in() -> void:
	var cfg = require_config()

	# 动效关掉：直接就位（不会「先透明、过一会儿才出现」）
	ThemeRes.set_animations_enabled(false)
	var instant = FadeInRes.new()
	root.add_child(instant)
	eq(instant.modulate.a, 1.0, "★★ 关掉动效时入场直接就位")
	instant.queue_free()
	ThemeRes.set_animations_enabled(true)

	# 动效开着：先置 0，交给 Tween 逐帧抬起来
	var animated = FadeInRes.new()
	root.add_child(animated)
	eq(animated.modulate.a, 0.0, "★ 动效开着时先置 0（由 Tween 抬到 1）")
	if cfg != null:
		near(animated.fade_in_sec(), cfg.fade_in_sec, 0.0001,
			"★★ 时长来自 config.json（不是代码里写死的 0.4）")
	ok(animated.fade_in_sec() > 0.0, "（前提）默认时长是正的")

	# 显式给 0 秒：直接显示，不建 Tween
	var manual = FadeInRes.new()
	root.add_child(manual)
	manual.fade_in_self(0.0)
	eq(manual.modulate.a, 1.0, "★ 显式给 0 秒 → 直接显示")

	animated.queue_free()
	manual.queue_free()


# ------------------------------------------------------------------
# 脚手架
# ------------------------------------------------------------------

## 建一个滚动列表并挂到树上（`_ready()` 会建内容层，手感参数也从这里读）。
func _make_list(view_h: float):
	var list = ElasticScrollListRes.new()
	root.add_child(list)
	list.size = Vector2(200.0, view_h)
	return list


## 往列表里塞 count 个指定高度的项。
func _fill(box: VBoxContainer, count: int, item_h: float) -> void:
	for i in count:
		var item := Control.new()
		item.custom_minimum_size = Vector2(100.0, item_h)
		box.add_child(item)
