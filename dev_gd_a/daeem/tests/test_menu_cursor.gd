## test_menu_cursor.gd —— 菜单光标（箭头 / 点）的纯判定用例。
##
## 只测「鼠标底下什么算可交互」这一条：不创建 CanvasLayer、不动真实系统光标，
## 于是无头也能跑。视觉部分（箭头 / 圆点 / 按下缩放）在 view/cursor_view.gd，
## 不在这里断言像素。
extends "res://tests/test_case.gd"

const MenuCursorRes = preload("res://view/menu_cursor.gd")
const ConfigRes = preload("res://logic/config.gd")


func _initialize() -> void:
	_case_name = "menu_cursor"
	run_all(_cases)


func _cases() -> void:
	_test_interactive()
	_test_visible_and_filter()
	_test_text_input()
	_test_supported()


func _test_interactive() -> void:
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)

	var b := Button.new()
	b.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(b)
	ok(MenuCursorRes.is_interactive(b), "普通 Button 可交互（光标变点）")

	b.disabled = true
	ok(not MenuCursorRes.is_interactive(b), "禁用 Button 不可交互（光标仍是箭头）")
	b.disabled = false

	var lab := Label.new()
	lab.mouse_filter = Control.MOUSE_FILTER_STOP
	lab.mouse_default_cursor_shape = Control.CURSOR_ARROW
	host.add_child(lab)
	ok(not MenuCursorRes.is_interactive(lab), "自绘 Label 没声明手型 ⇒ 不算可交互")

	lab.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	ok(MenuCursorRes.is_interactive(lab),
		"声明了手型光标的自绘控件（文字按钮 / 列表行）算可交互")

	ok(not MenuCursorRes.is_interactive(null), "null ⇒ 不可交互")

	host.queue_free()


func _test_visible_and_filter() -> void:
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)

	var b := Button.new()
	host.add_child(b)
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ok(not MenuCursorRes.is_interactive(b), "MOUSE_FILTER_IGNORE ⇒ 不收事件，不算可交互")

	b.mouse_filter = Control.MOUSE_FILTER_STOP
	b.visible = false
	ok(not MenuCursorRes.is_interactive(b), "隐藏的控件不算可交互")

	b.visible = true
	ok(MenuCursorRes.is_interactive(b), "可见 + STOP ⇒ 可交互")

	host.queue_free()


func _test_text_input() -> void:
	var host := Control.new()
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(host)

	var e := LineEdit.new()
	e.mouse_filter = Control.MOUSE_FILTER_STOP
	host.add_child(e)
	ok(MenuCursorRes.is_interactive(e), "文本输入也算可交互（虽然光标不是手型）")

	host.queue_free()


func _test_supported() -> void:
	var cfg = ConfigRes.load_default()
	ok(cfg != null, "（前提）config.json 读得出来")
	if cfg == null:
		return
	# 无头 / 桌面：没有 mobile 特征，custom_cursor 默认开 ⇒ 菜单光标受支持。
	ok(not OS.has_feature("mobile"), "（前提）测试跑在非 mobile 平台")
	ok(MenuCursorRes.supported(cfg), "custom_cursor = true ⇒ 菜单接管系统光标")
	cfg.custom_cursor_enabled = false
	ok(not MenuCursorRes.supported(cfg), "custom_cursor = false ⇒ 回到系统光标（排查开关）")
	cfg.custom_cursor_enabled = true
