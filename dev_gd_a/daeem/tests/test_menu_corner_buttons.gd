## test_menu_corner_buttons.gd —— 主菜单四角的图标按钮（载入 / 好友 / 设置）。
##
## 只测「看起来对、点得到、不打架」：落位镜像、不压到底部动作条、
## 各自那面角的泛光跟着悬停亮灭、点击不发跳转、侧栏灰层落下时被盖住。
extends "res://tests/test_case.gd"

const MainScene := preload("res://view/main.tscn")
const CornerButtonRes := preload("res://view/menu_corner_button.gd")
const LayoutRes := preload("res://view/menu_deck_layout.gd")

var _clicks: Array = []


func _initialize() -> void:
	_case_name = "test_menu_corner_buttons"
	_run()


func _run() -> void:
	await process_frame
	await _test_layout()
	await _test_hover_and_click()
	await _test_sidebar_dim()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_main():
	var main = MainScene.instantiate()
	root.add_child(main)
	await process_frame
	await _wait_sec(0.15)
	var screen = main.start_screen
	screen.dismiss_intro()
	await _wait_page(screen.menu_deck(), "main")
	await _wait_sec(0.9)
	return main


func _test_layout() -> void:
	var main = await _spawn_main()
	if main == null:
		ok(false, "主场景能建出来")
		return
	var screen = main.start_screen
	var mp = screen.main_panel()

	eq(mp.corner_buttons().size(), 3, "四角另有三颗图标按钮")
	eq(mp.corner_glows().size(), 3, "每颗都带一块角泛光")

	# 图标 / tooltip / 可点
	eq(mp.corner_button(mp.CORNER_LOAD).icon_kind, CornerButtonRes.ICON_LOAD,
		"左上角是载入图标")
	eq(mp.corner_button(mp.CORNER_FRIENDS).icon_kind, CornerButtonRes.ICON_FRIENDS,
		"左下角是好友图标")
	eq(mp.corner_button(mp.CORNER_SETTINGS).icon_kind, CornerButtonRes.ICON_SETTINGS,
		"右下角是设置图标")
	eq(mp.corner_button(mp.CORNER_LOAD).tooltip_text, "载入", "载入按钮的 tooltip")
	eq(mp.corner_button(mp.CORNER_FRIENDS).tooltip_text, "好友", "好友按钮的 tooltip")
	eq(mp.corner_button(mp.CORNER_SETTINGS).tooltip_text, "设置", "设置按钮的 tooltip")
	for i in 3:
		var b: Button = mp.corner_button(i)
		eq(b.mouse_filter, Control.MOUSE_FILTER_STOP, "角按钮自己吃点击：%d" % i)
		ok(b.get_theme_stylebox("normal") is StyleBoxEmpty, "角按钮没有边框：%d" % i)
		eq(b.icon_rect.size, Vector2(56.0, 56.0), "图标仍是 56×56：%d" % i)
		eq(b.get_global_rect().size,
			Vector2(LayoutRes.MAIN_CORNER_HIT, LayoutRes.MAIN_CORNER_HIT),
			"触发区是 180×180 的贴角方框：%d" % i)
	eq(mp.exit_button().mouse_filter, Control.MOUSE_FILTER_IGNORE,
		"退出 X 仍然交给右上角三角命中区")

	# 落位：左上与退出 X 左右镜像、上下同高
	var panel: Rect2 = mp.get_global_rect()
	var er: Rect2 = mp.exit_button().get_global_rect()
	var lr: Rect2 = _icon_rect(mp, mp.CORNER_LOAD)
	near(lr.position.y, er.position.y, 1.0, "载入与退出 X 同高")
	near(lr.position.x - panel.position.x, panel.end.x - er.end.x, 1.0,
		"载入与退出 X 左右镜像")
	near(lr.position.x - panel.position.x, LayoutRes.MAIN_CORNER_INSET, 1.0,
		"载入离面板左边 40px")

	# 下排：贴「不含底部动作条」的内容区底边，再往上 40px
	var base_y: float = mp.bottom_buttons()[0].get_global_rect().position.y
	var fr: Rect2 = _icon_rect(mp, mp.CORNER_FRIENDS)
	var sr: Rect2 = _icon_rect(mp, mp.CORNER_SETTINGS)
	near(base_y, panel.end.y - LayoutRes.MAIN_BOTTOM_H, 1.0,
		"底部动作条顶边 = 内容区底边")
	near(fr.end.y, base_y - LayoutRes.MAIN_CORNER_INSET, 1.0,
		"好友贴在内容区底边上方 40px")
	near(sr.end.y, fr.end.y, 1.0, "好友与设置同底")
	near(fr.position.x - panel.position.x, LayoutRes.MAIN_CORNER_INSET, 1.0,
		"好友离面板左边 40px")
	near(panel.end.x - sr.end.x, LayoutRes.MAIN_CORNER_INSET, 1.0,
		"设置离面板右边 40px")

	# 不打架：图标不压底部动作条 / 主按钮 / 退出 X
	for i in 3:
		var br: Rect2 = _icon_rect(mp, i)
		var hits_bottom := false
		for j in mp.bottom_buttons().size():
			if mp.bottom_buttons()[j].get_global_rect().intersects(br):
				hits_bottom = true
		ok(not hits_bottom, "角按钮不压 自定义/备战：%d" % i)
		var hits_main := false
		for j in mp.main_buttons().size():
			if mp.main_buttons()[j].get_global_rect().intersects(br):
				hits_main = true
		ok(not hits_main, "角按钮不压 战役/合作/演义：%d" % i)
		ok(not br.intersects(er), "角按钮不压退出 X：%d" % i)

	# 三角命中：只有贴角的半边能点，另一半让给面板正文
	var hit_corners := [LayoutRes.CORNER_TOP_LEFT, LayoutRes.CORNER_BOTTOM_LEFT,
		LayoutRes.CORNER_BOTTOM_RIGHT]
	for i in 3:
		var b: Button = mp.corner_button(i)
		var s: float = b.size.x
		var c: int = hit_corners[i]
		ok(b._has_point(_corner_point(c, s, 0.12, true)), "第 %d 颗：贴角处能点" % i)
		ok(not b._has_point(_corner_point(c, s, 0.12, false)),
			"第 %d 颗：远离角的另一半点不到" % i)
		# 图标中心一定落在三角里，否则看得见却点不到
		var icon_center: Vector2 = b.icon_rect.position + b.icon_rect.size * 0.5
		ok(LayoutRes.corner_has_point(b.size, c, icon_center),
			"第 %d 颗：图标中心在命中区内" % i)
		# 三颗主按钮 / 底部动作条的中心都不该被三角吃掉
		for j in mp.main_buttons().size():
			var p: Vector2 = mp.main_buttons()[j].get_global_rect().get_center()
			ok(not b._has_point(p - b.get_global_rect().position),
				"第 %d 颗不挡主按钮 %d" % [i, j])
		for j in mp.bottom_buttons().size():
			var p2: Vector2 = mp.bottom_buttons()[j].get_global_rect().get_center()
			ok(not b._has_point(p2 - b.get_global_rect().position),
				"第 %d 颗不挡底部按钮 %d" % [i, j])

	# 泛光：各自一面角、压在按钮之下、贴片已生成
	var corners := [LayoutRes.CORNER_TOP_LEFT, LayoutRes.CORNER_BOTTOM_LEFT,
		LayoutRes.CORNER_BOTTOM_RIGHT]
	for i in 3:
		var g: Control = mp.corner_glow_at(i)
		var gr: Rect2 = g.get_global_rect()
		eq(g.corner, corners[i], "第 %d 块泛光对着自己的角" % i)
		eq(gr.size, Vector2(LayoutRes.MAIN_CORNER_GLOW, LayoutRes.MAIN_CORNER_GLOW),
			"第 %d 块泛光 240×240" % i)
		ok(g.get("_tex") != null, "第 %d 块泛光贴片已生成" % i)
		ok(_z_of(g) < _z_of(mp.corner_button(i)), "泛光压在按钮之下：%d" % i)
		ok(_z_of(g) > _z_of(mp.background()), "泛光压在底板之上：%d" % i)
		ok(not g.is_hovered(), "初始不亮：%d" % i)
	# 右上角那只（退出 X 的泛光）还是原来的
	eq(mp.corner_glow().corner, LayoutRes.CORNER_TOP_RIGHT, "右上角泛光仍是右上")

	main.queue_free()
	await process_frame


func _test_hover_and_click() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var mp = screen.main_panel()
	_clicks.clear()
	mp.load_pressed.connect(func(): _clicks.append("load"))
	mp.friends_pressed.connect(func(): _clicks.append("friends"))
	mp.settings_pressed.connect(func(): _clicks.append("settings"))

	for i in 3:
		var b: Button = mp.corner_button(i)
		var g: Control = mp.corner_glow_at(i)
		await _hover_at(_icon_rect(mp, i).get_center())
		ok(b.is_hovered(), "鼠标进按钮：%d" % i)
		ok(g.is_hovered(), "悬停点亮自己的角泛光：%d" % i)
		await _hover_at(b.get_global_rect().get_center() + Vector2(0.0, 260.0))
		ok(not g.is_hovered(), "移开后泛光熄灭：%d" % i)
		near(g.hot(), 0.0, 0.001, "移开后回到初始强度：%d" % i)

	# 点击只发信号，页面不动（点图标中心）
	await _click_at(_icon_rect(mp, mp.CORNER_LOAD).get_center())
	await _click_at(_icon_rect(mp, mp.CORNER_FRIENDS).get_center())
	await _click_at(_icon_rect(mp, mp.CORNER_SETTINGS).get_center())
	await _wait_sec(0.15)
	eq(_clicks, ["load", "friends", "settings"], "三颗按钮各发一次信号")
	eq(screen.menu_deck().current_page(), "main", "点击角按钮不跳页")

	# 方框里「远离角」的那一半：真的点不到、也不亮（用完是干净的，不挡别的东西）
	var load_btn: Button = mp.corner_button(mp.CORNER_LOAD)
	var box: Rect2 = load_btn.get_global_rect()
	var far_pt: Vector2 = box.position \
		+ _corner_point(LayoutRes.CORNER_TOP_LEFT, box.size.x, 0.12, false)
	await _hover_at(far_pt)
	ok(not load_btn.is_hovered(), "三角外悬停：按钮不亮")
	ok(not mp.corner_glow_at(mp.CORNER_LOAD).is_hovered(), "三角外悬停：泛光也不亮")
	var before := _clicks.size()
	await _click_at(far_pt)
	eq(_clicks.size(), before, "点三角外不发信号")

	var near_pt: Vector2 = box.position \
		+ _corner_point(LayoutRes.CORNER_TOP_LEFT, box.size.x, 0.12, true)
	await _click_at(near_pt)
	eq(_clicks.size(), before + 1, "点贴角处才发信号")

	# 底部动作条不归角按钮：点「自定义」中心不该冒出任何角按钮信号
	var before2 := _clicks.size()
	await _click_at(mp.bottom_buttons()[0].get_global_rect().get_center())
	await _wait_sec(0.1)
	eq(_clicks.size(), before2, "底部动作条的点击不被角按钮吞掉")

	main.queue_free()
	await process_frame


func _test_sidebar_dim() -> void:
	var main = await _spawn_main()
	if main == null:
		return
	var screen = main.start_screen
	var mp = screen.main_panel()
	_clicks.clear()
	mp.load_pressed.connect(func(): _clicks.append("load"))

	var b: Button = mp.corner_button(mp.CORNER_LOAD)
	await _hover_at(b.get_global_rect().get_center())
	ok(mp.corner_glow_at(mp.CORNER_LOAD).is_hovered(), "灰层前泛光亮着")

	mp.set_sidebar_dimmed(true, false)
	await process_frame
	ok(mp.sidebar_dim().visible, "灰层可见")
	ok(not mp.corner_glow_at(mp.CORNER_LOAD).is_hovered(), "灰层落下时泛光强制熄灭")
	await _click_at(b.get_global_rect().get_center())
	await _wait_sec(0.15)
	eq(_clicks.size(), 0, "侧栏位点不到角按钮")

	mp.set_sidebar_dimmed(false, false)
	await process_frame
	await _click_at(b.get_global_rect().get_center())
	await _wait_sec(0.15)
	eq(_clicks.size(), 1, "灰层抬起后又能点到")

	main.queue_free()
	await process_frame


## 合成后的绘制层号（z_index 默认相对父节点累加），用来判断谁画在谁上面。
func _z_of(n: CanvasItem) -> int:
	if n == null:
		return 0
	var base: int = _z_of(n.get_parent() as CanvasItem) if n.z_as_relative else 0
	return base + n.z_index


## 图标那 56×56 的全局矩形（控件本身现在占的是 180×180 的三角触发框）。
func _icon_rect(mp, index: int) -> Rect2:
	var b: Button = mp.corner_button(index)
	return Rect2(b.get_global_rect().position + b.icon_rect.position, b.icon_rect.size)


## 三角方框里的一对采样点：`toward=true` 取贴角那端，否则取方框的对角那端。
func _corner_point(corner: int, s: float, f: float, toward: bool) -> Vector2:
	var lo: float = f * s
	var hi: float = (1.0 - f) * s
	var is_left: bool = corner == LayoutRes.CORNER_TOP_LEFT \
		or corner == LayoutRes.CORNER_BOTTOM_LEFT
	var is_top: bool = corner == LayoutRes.CORNER_TOP_LEFT \
		or corner == LayoutRes.CORNER_TOP_RIGHT
	var cx: float = lo if is_left else hi
	var cy: float = lo if is_top else hi
	if toward:
		return Vector2(cx, cy)
	return Vector2(hi if is_left else lo, hi if is_top else lo)


func _hover_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame
	await process_frame


func _click_at(pos: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	root.push_input(motion, true)
	await process_frame
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	root.push_input(up, true)
	await process_frame
	await process_frame


func _wait_sec(sec: float) -> void:
	var deadline := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await process_frame


func _wait_page(deck, page: String, timeout_ms: int = 8000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if deck.current_page() == page and not deck.is_busy():
			return true
		await process_frame
	return deck.current_page() == page and not deck.is_busy()
