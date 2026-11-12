## test_button_style.gd —— 2026.11.12「瞄准框」按钮语言 / 文字按钮松手确认的用例。
##
## 只测状态与信号，不测像素：
##   · fill_button 挂上后，按钮上会多一层 Reticle，状态跟着 glow / press / pulse / 灰档走；
##   · 文字导航按钮**按下不发**、松手且指针仍在按钮内才发；按下后移出 = 取消。
extends "res://tests/test_case.gd"

const FillButtonRes = preload("res://view/fill_button.gd")
const TextButtonRes = preload("res://view/menu_text_button.gd")
const ThemeRes = preload("res://view/theme.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "button_style"
	run_all(_cases)


func _cases() -> void:
	_test_reticle_attached()
	_test_reticle_follows_states()
	_test_text_press_on_release()
	_test_text_press_cancel()


func _new_button() -> Button:
	var b := Button.new()
	b.size = Vector2(240, 80)
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(b)
	return b


func _reticle_of(b: Button) -> Control:
	var c = b.get_node_or_null("Reticle")
	return c


func _test_reticle_attached() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	ok(anim != null, "（前提）fill_button 挂上了")
	var r := _reticle_of(b)
	ok(r != null, "★ 按钮上多了一层 Reticle（瞄准框）")
	ok(FillButtonRes.reticle_style(), "默认走新的瞄准框语言")
	if r != null:
		eq(r.mouse_filter, Control.MOUSE_FILTER_IGNORE, "瞄准框层不吃鼠标事件")
		ok(not r.show_behind_parent, "★ 瞄准框画在按钮**上面**（否则会被底纹盖住）")
	b.queue_free()


func _test_reticle_follows_states() -> void:
	var b := _new_button()
	var anim := FillButtonRes.attach_text(b)
	var r := _reticle_of(b)
	if r == null:
		ok(false, "（前提）没有 Reticle 层")
		b.queue_free()
		return

	b.mouse_entered.emit()
	for i in 12:
		anim._process(DT)
	ok(anim.glow() > 0.5, "悬停：泛光进度涨起来（%.2f）" % anim.glow())
	ok(r.glow > 0.5, "★ 瞄准框收到悬停强度（%.2f）" % r.glow)

	b.button_down.emit()
	for i in 12:
		anim._process(DT)
	ok(anim.press_amount() > 0.5, "按住：按下进度涨起来（%.2f）" % anim.press_amount())
	ok(r.press > 0.5, "★ 瞄准框收到按下进度（%.2f）" % r.press)

	b.button_up.emit()
	for i in 12:
		anim._process(DT)
	ok(anim.press_amount() <= 0.001, "松开：按下进度归零")

	b.pressed.emit()
	anim._process(DT)
	ok(r.pulse >= 0.0, "★ 松手回声环交给瞄准框层（pulse=%.2f）" % r.pulse)

	b.disabled = true
	anim._process(DT)
	ok(r.grey, "禁用 ⇒ 瞄准框换灰档")

	b.disabled = false
	b.queue_free()


func _test_text_press_on_release() -> void:
	var t := TextButtonRes.new()
	t.setup(null, "战役", 36)
	t.size = Vector2(300, 84)
	root.add_child(t)
	t.size = Vector2(300, 84)
	var fired: Array = [0]
	t.pressed.connect(func(): fired[0] += 1)

	_input(t, true, t.size * 0.5)
	eq(fired[0], 0, "★ 按下**不**发 pressed（旧实现在按下当帧就发）")
	ok(t._armed, "按下会进入「压住」态（松手才确认）")
	_input(t, false, t.size * 0.5)
	eq(fired[0], 1, "★ 松手且仍在按钮内 ⇒ 发一次 pressed")

	t.queue_free()


func _test_text_press_cancel() -> void:
	var t := TextButtonRes.new()
	t.setup(null, "合作", 36)
	t.size = Vector2(300, 84)
	root.add_child(t)
	t.size = Vector2(300, 84)
	var fired: Array = [0]
	t.pressed.connect(func(): fired[0] += 1)

	_input(t, true, t.size * 0.5)
	t._on_hover(false)          # 按住后指针移出
	_input(t, false, t.size * 0.5)
	eq(fired[0], 0, "★ 按住后移出再松手 = 取消（不发 pressed）")

	t.queue_free()


func _input(t, pressed: bool, pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	t._gui_input(ev)
