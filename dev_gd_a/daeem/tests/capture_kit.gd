extends SceneTree

## 按钮 / 光标「零件定妆照」：用真实控件与主题铺一张规范图。
## 用法：
##   godot --path <项目> --script res://tests/capture_kit.gd -- --prefix kit

var _page: Control = null
var _frame: int = 0
var _prefix: String = "kit"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if String(args[i]) == "--prefix" and i + 1 < args.size():
			_prefix = String(args[i + 1])

	var cfg = load("res://logic/config.gd").load_default()
	var font = load("res://view/font_loader.gd").load_font(cfg)
	var PageRes = load("res://view/menu_page.gd")
	var page: Control = PageRes.new()
	page.size = Vector2(1920, 1080)
	root.add_child(page)
	page.setup_page(cfg, font, "", false)
	_page = page

	# 标题
	_page.add_child(_label("按钮交互规范 · 2026.11.12", Vector2(72, 56), 42,
		load("res://view/theme.gd").text()))
	_page.add_child(_label("悬停 = 瞄准框 / 按下 = 括号内扣 + 1px 内框 / 松开 = 回声环；金色填充只表示已选中",
		Vector2(74, 116), 20, load("res://view/theme.gd").text_dim()))

	var cols := [
		Vector2(220, 220),   # 文字导航
		Vector2(660, 220),   # 动作按钮
		Vector2(1030, 220),  # 列表行
	]
	var heads := ["文字导航  Text Nav", "动作按钮  Action", "列表行  Row"]
	var widths := [380.0, 300.0, 760.0]
	for i in 3:
		_page.add_child(_label(heads[i], Vector2(cols[i].x, 180), 20,
			load("res://view/theme.gd").text_dim()))

	var rows := ["静息", "悬停", "按下", "松开", "已选中", "禁用"]
	for r in rows.size():
		var y: float = 250.0 + 128.0 * float(r)
		_page.add_child(_label(rows[r], Vector2(74, y + 26), 22,
			load("res://view/theme.gd").text_dim()))
		_make_text(cols[0].x, y, widths[0], r)
		_make_block(cols[1].x, y, widths[1], r)
		_make_row(cols[2].x, y, widths[2], r)

	# 光标样张（放页眉右侧，避免和最后一行挤在一起）
	var cy := 64.0
	_page.add_child(_label("光标：静息 = 箭头（热点在尖端） · 可交互 = 金圈点 · 按下收 14%",
		Vector2(1180, 34), 16, load("res://view/theme.gd").text_dim()))
	var cursor = load("res://view/cursor_view.gd").new()
	cursor.setup(cfg)
	_page.add_child(cursor)
	cursor.position = Vector2(1200, cy + 44)
	cursor.set_mode("ui")
	var cursor2 = load("res://view/cursor_view.gd").new()
	cursor2.setup(cfg)
	_page.add_child(cursor2)
	cursor2.position = Vector2(1360, cy + 44)
	cursor2.set_mode("normal")
	_page.add_child(_label("箭头 / 空白处", Vector2(1206, cy + 18), 16,
		load("res://view/theme.gd").text_dim()))
	_page.add_child(_label("点 / 可交互", Vector2(1366, cy + 18), 16,
		load("res://view/theme.gd").text_dim()))

func _label(text: String, pos: Vector2, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var font = load("res://view/font_loader.gd").load_font(
		load("res://logic/config.gd").load_default())
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func _make_text(x: float, y: float, w: float, state: int) -> void:
	var Btn = load("res://view/menu_text_button.gd")
	var b = Btn.new()
	b.setup(_font(), "战役", 36)
	b.position = Vector2(x, y)
	b.size = Vector2(w, 84)
	_page.add_child(b)
	b.size = Vector2(w, 84)
	b._layout_label()
	match state:
		1:
			b._on_hover(true)
		2:
			b._on_hover(true)
			b._armed = true
			b._set_press(true)
		3:
			b._on_hover(false)
		4:
			b.set_selected_immediate(true)
		5:
			b._on_hover(false)
			b.modulate = Color(1, 1, 1, 0.45)


func _font() -> Font:
	return load("res://view/font_loader.gd").load_font(
		load("res://logic/config.gd").load_default())


func _make_block(x: float, y: float, w: float, state: int) -> void:
	var style = load("res://view/menu_theme.gd").block_button()
	if state == 4:
		# 已选中：底纹必须透明，金色填充才看得见（与页签 / 磁贴同一条口径）。
		style = load("res://view/menu_theme.gd").button_hover_clear()
	var b: Button = _page.make_block_button("Block%d" % state, "进入战役", 28, style)
	b.position = Vector2(x, y)
	b.size = Vector2(w, 84)
	_page.add_child(b)
	b.size = Vector2(w, 84)
	var Fill = load("res://view/fill_button.gd")
	match state:
		1:
			b.mouse_entered.emit()
		2:
			b.mouse_entered.emit()
			b.button_down.emit()
		3:
			var a = Fill.animator_of(b)
			if a != null:
				a._start_pulse()
		4:
			Fill.set_latched(b, true, true)
		5:
			b.disabled = true
			b.mouse_entered.emit()


func _make_row(x: float, y: float, w: float, state: int) -> void:
	var style = load("res://view/menu_theme.gd").block_button()
	if state == 4:
		style = load("res://view/menu_theme.gd").button_hover_clear()
	var b: Button = _page.make_block_button("Row%d" % state, "关卡 · main_test", 24, style)
	b.position = Vector2(x, y + 14)
	b.size = Vector2(w, 56)
	_page.add_child(b)
	b.size = Vector2(w, 56)
	var Fill = load("res://view/fill_button.gd")
	match state:
		1:
			b.mouse_entered.emit()
		2:
			b.mouse_entered.emit()
			b.button_down.emit()
		3:
			var a = Fill.animator_of(b)
			if a != null:
				a._start_pulse()
		4:
			Fill.set_latched(b, true, true)
		5:
			b.disabled = true
			b.mouse_entered.emit()


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 120:
		var img: Image = root.get_texture().get_image()
		img.save_png("res://_shot_%s.png" % _prefix)
		print("shot ", _prefix)
		return true
	return false
