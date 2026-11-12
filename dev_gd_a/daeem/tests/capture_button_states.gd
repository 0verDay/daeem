extends SceneTree

## 按钮 / 光标「状态定妆照」：不依赖真实鼠标（窗口 DPI 会让 warp 偏移），
## 直接把真实控件摆到各状态再截图。
## 用法：
##   godot --path <项目> --script res://tests/capture_button_states.gd -- --prefix pose

var _scene: Node = null
var _frame: int = 0
var _stage: String = "boot"
var _stage_t0: int = 0
var _prefix: String = "pose"
var _ready_done: bool = false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if String(args[i]) == "--prefix" and i + 1 < args.size():
			_prefix = String(args[i + 1])
	var packed: PackedScene = load("res://view/main.tscn")
	_scene = packed.instantiate()
	root.add_child(_scene)


func _enter(s: String) -> void:
	_stage = s
	_stage_t0 = Time.get_ticks_msec()
	_ready_done = false


func _elapsed() -> int:
	return Time.get_ticks_msec() - _stage_t0


func _shot(name: String) -> void:
	var img: Image = root.get_texture().get_image()
	img.save_png("res://_shot_%s_%s.png" % [_prefix, name])
	print("shot ", name)


func _pause_cursor(pos: Vector2, mode: String, pressed: bool = false) -> void:
	var mc = _scene.start_screen.menu_cursor()
	if mc == null:
		return
	mc.set_process(false)
	mc.view.visible = true
	mc.view.set_cursor_pos(pos)
	mc.view.set_mode(mode)
	mc.view.set_pressed(pressed)


func _hover_text(b, on: bool) -> void:
	b._on_hover(on)


func _press_text(b, on: bool) -> void:
	if on:
		b._armed = true
		b._set_press(true)
	else:
		b._armed = false
		b._set_press(false)


func _process(_delta: float) -> bool:
	_frame += 1
	var mp = null
	if _scene.start_screen.menu_deck() != null:
		mp = _scene.start_screen.menu_deck().menu_main()
	match _stage:
		"boot":
			if _frame == 8:
				DisplayServer.window_move_to_foreground()
				var theme = load("res://view/theme.gd")
				theme.set_animations_enabled(false)
				_scene.start_screen.dismiss_intro()
				theme.set_animations_enabled(true)
				_enter("idle")
		"idle":
			if _elapsed() > 700:
				_pause_cursor(Vector2(520, 830), "ui")
				_shot("idle")
				_enter("hover")
		"hover":
			var b = mp.main_buttons()[0]
			if not _ready_done:
				_ready_done = true
				_hover_text(b, true)
				_pause_cursor(Vector2(1488, 482), "normal")
			if _elapsed() > 450:
				_shot("hover")
				_enter("press")
		"press":
			var b = mp.main_buttons()[0]
			if not _ready_done:
				_ready_done = true
				_press_text(b, true)
				_pause_cursor(Vector2(1488, 482), "normal", true)
			if _elapsed() > 170:
				_shot("press")
				_enter("release")
		"release":
			var b = mp.main_buttons()[0]
			if not _ready_done:
				_ready_done = true
				_press_text(b, false)
				_hover_text(b, false)
				mp.set_active(0)
			if _elapsed() > 260:
				_shot("selected")
				# 主菜单上「战役」不会同时是选中态（选中只在战役页的侧栏里），
				# 拍完选中样张就清掉，后面的实景图才是真实可达的状态。
				mp.set_active(-1)
				_enter("bottom_hover")
		"bottom_hover":
			var bb = mp.bottom_buttons()[1]
			if not _ready_done:
				_ready_done = true
				bb.mouse_entered.emit()
				_pause_cursor(bb.get_global_rect().get_center() + Vector2(70, 0), "normal")
			if _elapsed() > 420:
				_shot("bottom_hover")
				_enter("bottom_press")
		"bottom_press":
			var bb = mp.bottom_buttons()[1]
			if not _ready_done:
				_ready_done = true
				bb.button_down.emit()
				_pause_cursor(bb.get_global_rect().get_center() + Vector2(70, 0),
					"normal", true)
			if _elapsed() > 150:
				_shot("bottom_press")
				bb.button_up.emit()
				_enter("bottom_release")
		"bottom_release":
			if not _ready_done:
				_ready_done = true
				var bb = mp.bottom_buttons()[1]
				var a = load("res://view/fill_button.gd").animator_of(bb)
				if a != null:
					a._start_pulse()
			if _elapsed() > 110:
				_shot("bottom_release")
				_enter("bottom_latched")
		"bottom_latched":
			var bb = mp.bottom_buttons()[1]
			if not _ready_done:
				_ready_done = true
				load("res://view/fill_button.gd").set_latched(bb, true, true)
				bb.mouse_exited.emit()
			if _elapsed() > 260:
				_shot("bottom_latched")
				load("res://view/fill_button.gd").set_latched(bb, false, true)
				_enter("disabled")
		"disabled":
			var bb = mp.bottom_buttons()[0]
			if not _ready_done:
				_ready_done = true
				bb.disabled = true
				bb.mouse_entered.emit()
				_pause_cursor(bb.get_global_rect().get_center() + Vector2(70, 0), "normal")
			if _elapsed() > 350:
				_shot("disabled")
				bb.disabled = false
				bb.mouse_exited.emit()
				return true
	return false
