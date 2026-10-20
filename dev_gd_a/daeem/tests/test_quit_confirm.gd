## test_quit_confirm.gd —— ★ 退出确认浮层（版式移植自 nsoc 的 quit_confirm）
##
## 覆盖：
##   1. 结构：半透遮罩 / 居中大面板 / 两行字 / 暗底金线；
##   2. 尺寸：面板 = 屏宽 70% × 屏高 50%（比例来自 config），且居中；
##   3. 交互：点空白 = 取消、点面板 = 确认、Esc = 取消、重复 request 只有一份；
##   4. 动效总开关关掉时一帧到位；
##   5. main 的接线：主菜单「退出游戏」→ 浮层（不直接退）；安卓返回三档
##      （取消浮层 / 先关选项页 / 再弹浮层）；**测试里绝不确认 main 上那个实例**。
extends "res://tests/test_case.gd"

const QuitConfirmRes = preload("res://view/quit_confirm.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const MapLibraryRes = preload("res://logic/map_library.gd")
const ThemeRes = preload("res://view/theme.gd")

var _cfg = null


func _initialize() -> void:
	_case_name = "test_quit_confirm"
	_run()

func _run() -> void:
	await process_frame
	_cfg = require_config()
	if _cfg != null:
		# ★ 本文件只测行为，不测过渡曲线：关掉动效 → open / cancel / confirm 一步到位。
		#   （每个测试文件是独立进程，改静态开关不会影响别的套件。）
		ThemeRes.set_animations_enabled(false)
		await _test_structure_and_geometry()
		await _test_interactions()
		await _test_quit_fade()
		await _test_main_wiring()
		ThemeRes.set_animations_enabled(true)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _spawn_confirm():
	var font: Font = FontLoaderRes.load_font(_cfg)
	var qc = QuitConfirmRes.new()
	root.add_child(qc)
	qc.setup(_cfg, font)
	return qc


# ------------------------------------------------------------------
# 1. 结构与几何
# ------------------------------------------------------------------

func _test_structure_and_geometry() -> void:
	var qc = _spawn_confirm()
	ok(qc != null, "浮层能实例化")
	if qc == null:
		return
	ok(not qc.is_open(), "（前提）刚建好时是关着的")
	ok(qc.overlay() == null, "关着的时候没有 UI（第一次 request 才 build）")

	qc.request()
	await process_frame
	ok(qc.is_open(), "★ request() 之后是打开状态")
	var overlay: ColorRect = qc.overlay()
	var panel: Panel = qc.panel()
	ok(overlay != null, "★ 建出了全屏遮罩")
	ok(panel != null, "★ 建出了居中面板")
	if overlay == null or panel == null:
		qc.queue_free()
		return

	# 遮罩：铺满视口、半透黑、吃鼠标。
	var vp_size: Vector2 = root.get_visible_rect().size
	ok(overlay.get_global_rect().size.x >= vp_size.x - 1.0
			and overlay.get_global_rect().size.y >= vp_size.y - 1.0,
		"★ 遮罩铺满整个视口（%.0f×%.0f）" % [vp_size.x, vp_size.y])
	eq(overlay.mouse_filter, Control.MOUSE_FILTER_STOP, "遮罩吃鼠标（点空白要能取消）")
	near(overlay.color.a, _cfg.num("menu.quit_confirm.overlay_alpha", 0.55), 0.02,
		"★ 遮罩是半透黑（alpha %.2f）" % overlay.color.a)
	ok(overlay.color.r < 0.05 and overlay.color.g < 0.05 and overlay.color.b < 0.05,
		"遮罩颜色是黑色")

	# 面板：比例 + 居中 + 暗底金线。
	var ratios: Vector2 = qc.panel_size_ratios()
	near(panel.size.x, vp_size.x * ratios.x, 3.0,
		"★ 面板宽 = 屏宽 × %.2f（实际 %.0f）" % [ratios.x, panel.size.x])
	near(panel.size.y, vp_size.y * ratios.y, 3.0,
		"★ 面板高 = 屏高 × %.2f（实际 %.0f）" % [ratios.y, panel.size.y])
	var panel_center := panel.get_global_rect().get_center()
	near(panel_center.x, vp_size.x * 0.5, 3.0, "★ 面板水平居中")
	near(panel_center.y, vp_size.y * 0.5, 3.0, "★ 面板垂直居中")
	eq(panel.mouse_filter, Control.MOUSE_FILTER_STOP, "面板吃鼠标（点它 = 确认）")

	var sb: StyleBox = panel.get_theme_stylebox("panel")
	ok(sb is StyleBoxFlat, "面板有 StyleBoxFlat 底纹")
	if sb is StyleBoxFlat:
		var flat := sb as StyleBoxFlat
		ok(flat.bg_color.get_luminance() < 0.35,
			"★ 面板是**暗底**（移植的是版式，配色留在本作暗蓝灰皮肤）")
		ok(flat.border_color.r > flat.border_color.b,
			"★ 边框是**暗金细线**（R > B）")
		ok(flat.get_border_width(SIDE_LEFT) >= 1, "有 1px 细线描边")
		ok(flat.shadow_size > 0, "面板带阴影（浮在遮罩上）")

	# 两行字：主句 + 提示，且提示更暗。
	var title: Label = qc.title_label()
	var hint: Label = qc.hint_label()
	ok(title != null and hint != null, "面板里有两行字（主句 + 提示）")
	if title != null and hint != null:
		eq(title.text, _cfg.str_val("menu.quit_confirm.title", ""),
			"★ 主句文案来自 config（%s）" % title.text)
		eq(hint.text, _cfg.str_val("menu.quit_confirm.hint", ""),
			"★ 提示文案来自 config（%s）" % hint.text)
		ok(hint.get_theme_color("font_color").get_luminance()
				< title.get_theme_color("font_color").get_luminance(),
			"★ 提示比主句更暗（主次分得开）")

	# 根节点不吃鼠标（吃的只有遮罩与面板）。
	var root_ctrl: Control = qc.get_node_or_null("QuitRoot")
	ok(root_ctrl != null, "浮层里有一个 QuitRoot")
	if root_ctrl != null:
		eq(root_ctrl.mouse_filter, Control.MOUSE_FILTER_IGNORE,
			"★ 根节点 IGNORE（否则会把面板的点击也算成空白）")

	# 幂等：再 request 一次不会建第二份。
	var before: int = qc.get_child_count()
	qc.request()
	await process_frame
	eq(qc.get_child_count(), before, "★ 重复 request() 只有一份 UI（幂等）")

	qc.cancel()
	await process_frame
	ok(not qc.is_open(), "取消之后回到关闭状态")
	qc.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 2. 交互：点空白 / 点面板 / Esc
# ------------------------------------------------------------------

func _test_interactions() -> void:
	# ---- 点空白 = 取消 ----
	var qc = _spawn_confirm()
	var cancelled := [0]
	qc.cancelled.connect(func(): cancelled[0] += 1)
	qc.request()
	await process_frame
	var vp: Vector2 = root.get_visible_rect().size
	await _click_at(Vector2(8.0, vp.y * 0.5))
	ok(cancelled[0] == 1, "★ 点面板外的空白 → cancelled 发了一次")
	ok(not qc.is_open(), "点空白之后浮层关掉")
	qc.queue_free()
	await process_frame

	# ---- 点面板 = 确认 ----
	qc = await _spawn_confirm()
	var confirmed := [0]
	qc.confirmed.connect(func(): confirmed[0] += 1)
	qc.request()
	await process_frame
	var panel: Panel = qc.panel()
	if panel != null:
		await _click_at(panel.get_global_rect().get_center())
	ok(confirmed[0] == 1, "★ 点面板 → confirmed 发了一次")
	ok(not qc.is_open(), "点面板之后逻辑上关掉")
	eq(cancelled[0], 1, "那一次确认没有误发 cancelled")
	var ov_after = qc.overlay()
	ok(ov_after != null, "★ 动效关掉时，确认后同样保留全黑遮罩（不露出界面）")
	if ov_after != null:
		near(ov_after.color.a, 1.0, 0.001, "遮罩是纯黑")
	qc.queue_free()
	await process_frame

	# ---- Esc = 取消 ----
	qc = _spawn_confirm()
	var esc_cancelled := [0]
	qc.cancelled.connect(func(): esc_cancelled[0] += 1)
	qc.request()
	await process_frame
	var k := InputEventKey.new()
	k.keycode = KEY_ESCAPE
	k.pressed = true
	qc._unhandled_input(k)
	ok(esc_cancelled[0] == 1, "★ Esc → cancelled 发了一次")
	ok(not qc.is_open(), "Esc 之后浮层关掉")
	qc.queue_free()
	await process_frame

	# ---- 关着的时候按 Esc 不该有任何反应 ----
	qc = _spawn_confirm()
	var quiet := [0]
	qc.cancelled.connect(func(): quiet[0] += 1)
	qc._unhandled_input(k)
	eq(quiet[0], 0, "★ 没打开时 Esc 不发信号")
	qc.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 3. 动效路径：打开淡入 + 确认之后**先渐黑再发 confirmed**
# ------------------------------------------------------------------

func _test_quit_fade() -> void:
	ThemeRes.set_animations_enabled(true)
	var qc = _spawn_confirm()
	var hits := [0]
	qc.confirmed.connect(func(): hits[0] += 1)
	qc.request()
	# 打开动画第一帧：还没到全不透明。
	await process_frame
	ok(qc.is_open(), "（前提）动效开着也能打开")
	var ov = qc.overlay()
	ok(ov != null, "（前提）遮罩建出来了")
	if ov != null:
		ok(ov.modulate.a < 0.99,
			"★ 打开时遮罩**从透明淡入**（首帧 alpha %.2f）" % ov.modulate.a)

	# 确认：先播 0.2s 渐黑，**这一刻还不会发 confirmed**。
	qc.confirm()
	await process_frame
	ok(qc.is_open(), "★ 点确认之后浮层还在（正在渐黑）")
	eq(hits[0], 0, "★ 渐黑期间 confirmed 还没发（这就是「缓冲」那一拍）")

	# 渐黑**确实作用在遮罩的颜色 alpha 上**（不是只把面板淡出）：
	#   起始 0.55 → 中途应该更大。
	var mid_deadline: int = Time.get_ticks_msec() + 80
	while Time.get_ticks_msec() < mid_deadline:
		await process_frame
	var ov_mid = qc.overlay()
	if ov_mid != null:
		ok(ov_mid.color.a > 0.55 and ov_mid.color.a <= 1.0,
			"★ 渐黑中遮罩颜色 alpha 在变大（%.2f）" % ov_mid.color.a)

	var deadline: int = Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline and hits[0] == 0:
		await process_frame
	eq(hits[0], 1, "★ 渐黑 + 全黑保持走完才发 confirmed")
	ok(not qc.is_open(), "发完之后逻辑上已经关闭")

	# ★★ 关键回归：confirmed 之后**遮罩仍在、且是纯黑**（等到 main quit 才一起销毁）。
	#   否则最后一帧会露出底下的界面 —— 用户实测报的「退出时我看到的还是有界面的」。
	var ov_end = qc.overlay()
	ok(ov_end != null, "★★ 确认之后遮罩**不销毁**（保持到进程退出）")
	if ov_end != null:
		near(ov_end.color.a, 1.0, 0.001, "★★ 最后一帧遮罩是**纯黑**（alpha %.2f）" % ov_end.color.a)
		near(ov_end.modulate.a, 1.0, 0.001, "遮罩自身没有被淡出（modulate 仍是 1）")
	ok(qc.visible, "★★ CanvasLayer 仍然可见（全黑铺在整屏上）")
	var pnl = qc.panel()
	if pnl != null:
		near(pnl.modulate.a, 0.0, 0.001, "面板已经隐形（只剩全黑）")

	# 再次 request 会重建（不会把「上次留下的全黑」当成新浮层）。
	qc.request()
	await process_frame
	ok(qc.is_open(), "★ 确认之后（如果没退出）再次 request 能重新打开")
	var ov_new = qc.overlay()
	if ov_new != null:
		near(ov_new.color.a, 0.55, 0.02,
			"★ 重建之后遮罩回到半透（不是上次的全黑）")

	qc.queue_free()
	await process_frame
	ThemeRes.set_animations_enabled(false)


# ------------------------------------------------------------------
# 4. main 的接线
# ------------------------------------------------------------------

func _test_main_wiring() -> void:
	var packed = load("res://view/main.tscn")
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	ok(main.start_screen != null, "（前提）主界面能起来")
	eq(bool(ProjectSettings.get_setting("application/config/quit_on_go_back", true)), false,
		"★ 项目设置关掉了 quit_on_go_back（否则引擎会抢在通知之前退出）")

	# ---- 主菜单「退出游戏」→ 浮层，不直接 quit ----
	main._on_quit_requested()
	await process_frame
	var qc = main.get_node_or_null("QuitConfirm")
	ok(qc != null, "★ 点「退出游戏」之后挂出了 QuitConfirm")
	if qc == null:
		main.queue_free()
		return
	ok(qc.is_open(), "★ 它是打开状态（游戏没有直接退）")
	ok(is_instance_valid(main), "★ main 还在（这条路径绝不直接 get_tree().quit）")

	# ---- 浮层开着时按安卓返回 = 取消 ----
	main._on_android_back()
	await process_frame
	ok(not qc.is_open(), "★ 浮层开着时按返回 → 先取消它")
	ok(is_instance_valid(main), "取消之后 main 仍然在")

	# ---- 主菜单再按返回（走**真正的通知入口**）= 重新弹 ----
	main._notification(Node.NOTIFICATION_WM_GO_BACK_REQUEST)
	await process_frame
	ok(qc.is_open(), "★ 主菜单收到安卓返回通知 → 弹退出确认")
	main._on_android_back()            # 收掉，别留给后面的用例
	await process_frame

	# ---- 局内：返回键先关选项页，第二次才弹退出确认 ----
	main._on_test_pressed(String(MapLibraryRes.default_map_path()))
	await process_frame
	ok(main.game != null, "（前提）能进一局")
	if main.game != null:
		var hud = main.game.hud
		ok(hud != null and hud.options_panel != null, "（前提）局内有选项页")
		if hud != null and hud.options_panel != null:
			hud.options_panel.open()
			await process_frame
			ok(hud.options_panel.is_open(), "（前提）选项页开着")
			main._on_android_back()
			await process_frame
			ok(not hud.options_panel.is_open(), "★★ 局内第一次返回：先关选项页")
			ok(not qc.is_open(), "★ 这一下**不**弹退出确认")
			main._on_android_back()
			await process_frame
			ok(qc.is_open(), "★★ 选项页已经关了，再按返回才弹退出确认")
			main._on_android_back()
			await process_frame
			ok(not qc.is_open(), "再按一次返回 = 取消浮层")

	ok(is_instance_valid(main), "★ 整条安卓返回链路走完，main 仍然活着（没误退出）")
	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _click_at(pos: Vector2) -> void:
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
