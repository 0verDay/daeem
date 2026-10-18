## test_press_fx.gd —— 所有按钮统一的「按下压缩 / 回弹 / 亮边」动效
##
## 盯三件事：
##   1. fill_button.attach() 会自动挂上 PressFx（所有 Button 同一份逻辑）；
##   2. 按下 → 缩小 + 亮边；松手 → 回弹到 100%，pivot / scale 都还原；
##   3. 动效总开关关掉时：不缩放，只留静态亮边。
extends "res://tests/test_case.gd"

const FillButtonRes = preload("res://view/fill_button.gd")
const PressFxRes = preload("res://view/press_fx.gd")
const ThemeRes = preload("res://view/theme.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "press_fx"
	run_all(_cases)


func _cases() -> void:
	_test_auto_attach()
	_test_press_down_up()
	_test_fast_tap()
	_test_rapid_repress()
	_test_animations_off()
	_test_manual_api()


func _new_button() -> Button:
	var b := Button.new()
	b.size = Vector2(100.0, 60.0)
	root.add_child(b)
	return b


func _test_auto_attach() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(anim != null, "（前提）fill_button 挂上了")
	var fx = PressFxRes.of(b)
	ok(fx != null, "★★ fill_button.attach() 自动挂上 PressFx（所有按钮统一）")
	if fx == null:
		b.queue_free()
		return
	eq(b.get_node_or_null("PressFx"), fx, "按钮下面只有一层 PressFx")
	eq(PressFxRes.attach(b), fx, "重复 attach() 返回同一个动效节点（不会挂两层）")
	eq(PressFxRes.of(b), fx, "of() 取回的是同一个节点")
	eq(int(fx.press_count), 0, "还没按过")
	b.queue_free()


func _test_press_down_up() -> void:
	var b := _new_button()
	FillButtonRes.attach_text(b)
	var fx = PressFxRes.of(b)
	ok(fx != null, "（前提）按下动效存在")
	if fx == null:
		b.queue_free()
		return

	b.button_down.emit()
	ok(bool(fx.press_active), "★ 按下后 press_active = true")
	ok(bool(fx.press_held), "★ 按下后处于按住态")
	eq(int(fx.press_count), 1, "★ 按下计数 +1")
	ok(b.scale.x < 1.0, "★ 按下当帧就缩了一点（%.4f）" % b.scale.x)
	var s0: float = b.scale.x

	fx._process(DT * 2.0)
	ok(b.scale.x < s0, "★ 继续压缩（%.4f → %.4f）" % [s0, b.scale.x])
	ok(float(fx.press_edge_last) > 0.0, "★ 按下亮边出现")

	var s1: float = b.scale.x
	b.button_up.emit()
	ok(not bool(fx.press_held), "★ 松手后离开按住态")
	fx._process(DT * 2.0)
	ok(b.scale.x > s1, "★ 松手开始回弹（%.4f → %.4f）" % [s1, b.scale.x])

	fx._process(0.3)
	near(b.scale.x, 1.0, 0.001, "★ 回弹结束 = 100%")
	near(float(fx.press_scale_last), 1.0, 0.001, "★ 诊断刻度也回到 100%")
	ok(not bool(fx.press_active), "★ 回弹结束 press_active = false")
	ok(float(fx.press_edge_last) <= 0.001, "★ 亮边完全淡出")
	near(b.pivot_offset.x, 0.0, 0.001, "★ pivot_offset 还原（x）")
	near(b.pivot_offset.y, 0.0, 0.001, "★ pivot_offset 还原（y）")
	b.queue_free()


func _test_fast_tap() -> void:
	var b := _new_button()
	FillButtonRes.attach_text(b)
	var fx = PressFxRes.of(b)
	if fx == null:
		b.queue_free()
		return
	# 极快点按：down / up 在同一帧，也要留下「按过」的视觉痕迹
	b.button_down.emit()
	b.button_up.emit()
	ok(b.scale.x < 1.0, "★ 极快点按当帧仍有压缩（%.4f）" % b.scale.x)
	fx._process(0.3)
	near(b.scale.x, 1.0, 0.001, "★ 极快点按之后同样复位")
	b.queue_free()


func _test_rapid_repress() -> void:
	var b := _new_button()
	FillButtonRes.attach_text(b)
	var fx = PressFxRes.of(b)
	if fx == null:
		b.queue_free()
		return
	# 在上一轮回弹还没结束时再按：不能用「过冲后的比例」当新的 100%
	for _k in 3:
		b.button_down.emit()
		fx._process(0.02)
		b.button_up.emit()
		fx._process(0.02)
	fx._process(0.5)
	near(b.scale.x, 1.0, 0.001, "★★ 连续快速点按之后仍是 100%（不会越点越大）")
	near(b.pivot_offset.x, 0.0, 0.001, "★ 连续快速点按后 pivot 仍还原")
	eq(int(fx.press_count), 3, "★ 三次按下都记到了")
	b.queue_free()


func _test_animations_off() -> void:
	ThemeRes.set_animations_enabled(false)
	var b := _new_button()
	FillButtonRes.attach_text(b)
	var fx = PressFxRes.of(b)
	if fx == null:
		ThemeRes.set_animations_enabled(true)
		b.queue_free()
		return
	b.button_down.emit()
	near(b.scale.x, 1.0, 1e-6, "★★ 关掉动效：按住**不缩放**")
	ok(float(fx.press_edge_last) > 0.0, "★★ 但仍有静态亮边（不是没反馈）")
	ok(bool(fx.press_held), "★ 按住态照旧记录")
	b.button_up.emit()
	near(b.scale.x, 1.0, 1e-6, "★ 松手仍不缩放")
	ok(not bool(fx.press_active), "★ 松手立刻清掉")
	ok(float(fx.press_edge_last) <= 0.001, "★ 亮边也立刻清掉")
	ThemeRes.set_animations_enabled(true)
	b.queue_free()


func _test_manual_api() -> void:
	# 自绘可点控件将来可以用同一套 API；这里验证 press/release 入口
	var c := Control.new()
	c.size = Vector2(80.0, 40.0)
	root.add_child(c)
	var fx = PressFxRes.attach(c)
	ok(fx != null, "★ Control 也能挂 PressFx")
	if fx == null:
		c.queue_free()
		return
	PressFxRes.press(c)
	ok(bool(fx.press_active), "★ PressFx.press() 生效")
	c.scale = Vector2.ONE
	PressFxRes.release(c)
	fx._process(0.3)
	ok(not bool(fx.press_active), "★ PressFx.release() 收尾")
	c.queue_free()
