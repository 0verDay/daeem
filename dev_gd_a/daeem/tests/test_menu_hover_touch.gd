## test_menu_hover_touch.gd —— 移动端「没有悬停」这条口径
##
## 触屏按下去时引擎会模拟一次 `mouse_entered`，但松开**不补** `mouse_exited`。
## 于是如果照桌面那套走：横线一直亮、角泛光一直亮、填充按钮一直满金。
## 这里钉的就是「移动端把悬停与点击并成同一件事」：
##   · 悬停事件在移动端**不产生任何视觉**；
##   · 按住 = 原来悬停的样子，松开 = 回去；
##   · 强制熄灯（侧栏灰层）走 `set_lit(false)`，移动端也熄得掉。
##
## ★ 断言全部走纯函数 / 直接调用，不需要真实输入事件、不跑帧。
extends "res://tests/test_case.gd"

const TextButtonRes = preload("res://view/menu_text_button.gd")
const GlowRes = preload("res://view/menu_corner_glow.gd")
const CornerRes = preload("res://view/menu_corner_button.gd")
const ThemeRes = preload("res://view/theme.gd")

const BASE_DASH := 0.42

var _made: Array = []


func _initialize() -> void:
	_case_name = "menu_hover_touch"
	run_all(_cases)


func _cases() -> void:
	# 动画关掉：dash / hot 直接到位，好断言（与 test_menu_emblem 同一条路）
	var prev_anim: bool = ThemeRes.animations_enabled()
	ThemeRes.set_animations_enabled(false)
	_test_switch()
	_test_text_button_mobile()
	_test_text_button_desktop()
	_test_glow_mobile()
	_test_glow_desktop()
	_test_corner_lit()
	_test_force_off()
	ThemeRes.set_animations_enabled(prev_anim)
	ThemeRes.set_hover_enabled(true)
	_free_all()


func _free_all() -> void:
	for n in _made:
		if is_instance_valid(n):
			n.free()
	_made.clear()


func _text_button(text: String = "战役"):
	var b = TextButtonRes.new()
	_made.append(b)
	b.setup(null, text, 44)
	b.size = Vector2(360, 88)
	return b


func _glow():
	var g = GlowRes.new()
	_made.append(g)
	g.size = Vector2(240, 240)
	return g


func _press(btn, down: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = down
	btn._gui_input(ev)


# ------------------------------------------------------------------
# 开关
# ------------------------------------------------------------------

func _test_switch() -> void:
	ThemeRes.set_hover_enabled(false)
	ok(not ThemeRes.hover_enabled(), "能关掉悬停（移动端口径）")
	ThemeRes.set_hover_enabled(true)
	ok(ThemeRes.hover_enabled(), "能打开悬停（桌面口径）")
	ThemeRes.set_hover_enabled(false)


# ------------------------------------------------------------------
# 战役 / 合作 / 演义：左右横线
# ------------------------------------------------------------------

func _test_text_button_mobile() -> void:
	var b = _text_button()
	near(b.dash_amount(), BASE_DASH, 0.0001, "初始横线是短的")
	# 模拟触屏按下时引擎补发的那次 mouse_entered：移动端必须**什么都不发生**
	b.mouse_entered.emit()
	near(b.dash_amount(), BASE_DASH, 0.0001, "移动端悬停不点亮横线")
	# 按下 → 亮；松开 → 回去
	_press(b, true)
	near(b.dash_amount(), 1.0, 0.0001, "移动端按住 = 点亮横线（悬停与点击合并）")
	_press(b, false)
	near(b.dash_amount(), BASE_DASH, 0.0001, "移动端松手 = 横线回短")


func _test_text_button_desktop() -> void:
	ThemeRes.set_hover_enabled(true)
	var b = _text_button("合作")
	b.mouse_entered.emit()
	near(b.dash_amount(), 1.0, 0.0001, "桌面：悬停点亮横线")
	b.mouse_exited.emit()
	near(b.dash_amount(), BASE_DASH, 0.0001, "桌面：移开熄灭")
	ThemeRes.set_hover_enabled(false)


# ------------------------------------------------------------------
# 四角泛光
# ------------------------------------------------------------------

func _test_glow_mobile() -> void:
	var g = _glow()
	g.set_hover(true)
	near(g.hot(), 0.0, 0.0001, "移动端：hover 事件**点不亮**泛光（等不到 exit，会一直亮）")
	ok(not g.is_hovered(), "移动端：泛光不认为自己被悬停")
	g.set_lit(true)
	near(g.hot(), 1.0, 0.0001, "移动端：按下点亮泛光")
	g.set_lit(false)
	near(g.hot(), 0.0, 0.0001, "移动端：松开熄灭")


func _test_glow_desktop() -> void:
	ThemeRes.set_hover_enabled(true)
	var g = _glow()
	g.set_hover(true)
	near(g.hot(), 1.0, 0.0001, "桌面：悬停点亮泛光")
	g.set_hover(false)
	near(g.hot(), 0.0, 0.0001, "桌面：移开熄灭")
	ThemeRes.set_hover_enabled(false)


# ------------------------------------------------------------------
# 四角图标：亮金判定
# ------------------------------------------------------------------

func _test_corner_lit() -> void:
	# 移动端：只看「按住」，悬停不算
	ok(not CornerRes.lit_for(true, false, false), "移动端：悬停不点亮图标")
	ok(CornerRes.lit_for(false, true, false), "移动端：按住点亮图标")
	ok(not CornerRes.lit_for(false, false, false), "移动端：没按就是白的")
	# 桌面：只看悬停
	ok(CornerRes.lit_for(true, false, true), "桌面：悬停点亮图标")
	ok(not CornerRes.lit_for(false, true, true), "桌面：按住但没悬停不点亮")


# ------------------------------------------------------------------
# 强制熄灯（侧栏灰层）
# ------------------------------------------------------------------

func _test_force_off() -> void:
	# 移动端把泛光点亮之后，侧栏灰层那条「强行熄灯」必须依然有效
	var g = _glow()
	g.set_lit(true)
	near(g.hot(), 1.0, 0.0001, "先点亮")
	g.set_lit(false)
	near(g.hot(), 0.0, 0.0001, "移动端：set_lit(false) 熄得掉（set_hover 熄不掉）")
