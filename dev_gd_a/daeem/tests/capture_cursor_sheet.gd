extends SceneTree

## 光标样张：箭头 / 金圈点 / 按住，6× 放大 + 实际大小对照。
## 用法：godot --path <项目> --script res://tests/capture_cursor_sheet.gd

var _frame: int = 0


func _initialize() -> void:
	var cfg = load("res://logic/config.gd").load_default()
	var theme = load("res://view/theme.gd")
	var font = load("res://view/font_loader.gd").load_font(cfg)

	var bg := ColorRect.new()
	bg.color = theme.menu_bg()
	bg.size = Vector2(1920, 1080)
	root.add_child(bg)

	root.add_child(_label(font, "光标：平时是箭头，能点时是点", Vector2(80, 62), 48, theme.text()))
	root.add_child(_label(font,
		"与游戏内共用 view/cursor_view.gd；菜单只映射两档状态（ui / normal）",
		Vector2(82, 132), 20, theme.text_dim()))

	# 6× 大样
	var big := [
		["ui", Vector2(140, 280), "静息 · 箭头", "18px，热点在箭尖；深色描边保证压在画 / 面板上都看得见"],
		["normal", Vector2(760, 300), "可交互 · 金圈点", "8.2px 金环 + 3.9px 深色垫 + 2.4px 实心点；热点在圆心"],
		["pressed", Vector2(1380, 300), "按住 · 收 14%", "左键按下时整体缩到 0.86，松手回弹"],
	]
	for item in big:
		var mode: String = item[0]
		var pos: Vector2 = item[1]
		var c = load("res://view/cursor_view.gd").new()
		c.setup(cfg)
		c.set_cursor_scale(6.0)
		print("cursor scale=", c._scale)
		root.add_child(c)
		c.position = pos
		if mode == "pressed":
			c.set_mode("normal")
			c.set_pressed(true)
			c._press = 1.0
		else:
			c.set_mode(mode)
		root.add_child(_label(font, item[2], pos + Vector2(-60, 250), 30, theme.accent_bright()))
		root.add_child(_label(font, item[3], pos + Vector2(-60, 292), 18, theme.text_dim()))

	# 实际大小
	var y := 760.0
	var line := ColorRect.new()
	line.color = theme.with_alpha(theme.line(), 0.6)
	line.position = Vector2(80, y - 30)
	line.size = Vector2(1760, 1)
	root.add_child(line)
	root.add_child(_label(font, "实际大小（100%）", Vector2(80, y), 20, theme.text_dim()))

	var small_arrow = load("res://view/cursor_view.gd").new()
	small_arrow.setup(cfg)
	root.add_child(small_arrow)
	small_arrow.position = Vector2(120, y + 70)
	small_arrow.set_mode("ui")
	root.add_child(_label(font, "箭头 · 空白处 / 不可点", Vector2(150, y + 58), 18, theme.text()))

	var small_dot = load("res://view/cursor_view.gd").new()
	small_dot.setup(cfg)
	root.add_child(small_dot)
	small_dot.position = Vector2(520, y + 70)
	small_dot.set_mode("normal")
	root.add_child(_label(font, "点 · 悬停可交互控件", Vector2(545, y + 58), 18, theme.text()))

	# 一截真实菜单：点是压在「备战」上的样子
	root.add_child(_label(font, "压在按钮上的样子（1×）", Vector2(900, y), 20, theme.text_dim()))
	var panel := ColorRect.new()
	panel.color = theme.with_alpha(theme.bg_top(), 0.55)
	panel.position = Vector2(900, y + 34)
	panel.size = Vector2(940, 150)
	root.add_child(panel)
	root.add_child(_label(font, "备  战", Vector2(1140, y + 96), 34, theme.text()))
	var real = load("res://view/cursor_view.gd").new()
	real.setup(cfg)
	root.add_child(real)
	real.position = Vector2(1268, y + 108)
	real.set_mode("normal")

	root.add_child(_label(font,
		"系统光标只在菜单显示期间隐藏；进游戏 / 窗口失焦 / 指针移出窗口 都会立刻还原。",
		Vector2(80, 1000), 20, theme.text_dim()))


func _label(font: Font, text: String, pos: Vector2, fs: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.position = pos
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", color)
	return l


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 90:
		var img: Image = root.get_texture().get_image()
		img.save_png("res://_shot_cursor_sheet.png")
		print("shot cursor sheet")
		return true
	return false
