## test_touch.gd —— ★ 手机端触摸手势：手势 → 命令 / 相机
##
## 对应 view/touch_controller.gd（识别）+ view/input_controller.gd 的 touch_* 策略。
## ★ 全部走**和游戏同一条路**：构造真的触摸事件（InputEventScreenTouch / Drag）喂进
##   touch_controller，命令落到 input_controller.command_issued 上断言 —— 不另开捷径。
## ⚠️ 屏幕坐标一律用 `palette.to_px(单位位置)` 现算，再让 touch_controller 用
##   `palette.to_logic()` 反算回去（与游戏里「格 ↔ 屏幕」同一台相机导出）。
extends "res://tests/test_case.gd"

const FactionRes = preload("res://logic/faction.gd")

## 假的相机替身：只记录平移（touch_controller 拖视野走它）。
class FakeCam extends RefCounted:
	var pans: Array[Vector2] = []
	func pan_screen(delta: Vector2) -> void:
		pans.append(delta)
	func zoom_at(_screen_pos: Vector2, _factor: float) -> void:
		pass
	func center_on_px(_screen_pos: Vector2) -> void:
		pass

## 假 HUD：只回答「这一点在不在 UI 上」（touch_controller 用它判手势起点）。
class FakeHud extends RefCounted:
	var ui: Rect2 = Rect2()
	func point_hits_ui(pos: Vector2) -> bool:
		return ui.has_point(pos)


var _cmds: Array = []


func _initialize() -> void:
	_case_name = "test_touch"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var world = require_world_with_escorts(cfg, 3, "p1")
	if world == null:
		quit(1)
		return
	await process_frame

	var cols: int = int(world.map.cols)
	var rows: int = int(world.map.rows)
	var cam := make_test_camera(cfg, cols, rows)
	if cam == null:
		quit(1)
		return
	cam.force_update_transform()
	var palette := make_test_palette(cfg, cam)
	if palette == null:
		quit(1)
		return
	await process_frame

	_test_mouse_suppress(cfg, world, palette)
	_test_single_tap_select(cfg, world, palette)
	_test_tap_order_and_double(cfg, world, palette)
	_test_tap_own_unit_still_orders(cfg, world, palette)
	_test_single_finger_pan(cfg, world, palette)
	_test_tap_move_tolerance(cfg, world, palette)
	await _test_long_press_pan(cfg, world, palette)
	_test_two_finger_box(cfg, world, palette)
	_test_two_finger_box_screen_rect(cfg, world, palette)
	_test_box_select_screen_and_group(cfg, world, palette)
	_test_two_finger_switches_from_pan(cfg, world, palette)
	_test_starts_on_ui_ignored(cfg, world, palette)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 搭一套 input_controller + touch_controller（共用同一台 palette）
# ------------------------------------------------------------------

func _new_ic(cfg, world, palette) -> Object:
	var cls = script_at("res://view/input_controller.gd")
	if cls == null:
		return null
	var ic = cls.new()
	root.add_child(ic)
	ic.setup(cfg, world, FakeCam.new(), palette)
	ic.command_issued.connect(_on_cmd)
	return ic


func _new_touch(cfg, palette, ic, hud = null) -> Object:
	var cls = script_at("res://view/touch_controller.gd")
	if cls == null:
		return null
	var t = cls.new()
	t.setup(cfg, palette, ic, ic.camera_rig, hud)
	return t


func _on_cmd(cmd: Dictionary) -> void:
	_cmds.append(cmd)


func _has_kind(kind: String) -> bool:
	for c in _cmds:
		if String((c as Dictionary).get("kind", "")) == kind:
			return true
	return false


func _last_kind() -> String:
	if _cmds.is_empty():
		return ""
	return String((_cmds.back() as Dictionary).get("kind", ""))


# ------------------------------------------------------------------
# 事件夹具
# ------------------------------------------------------------------

func _down(t, index: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = true
	t.handle_touch(e)


func _up(t, index: int, pos: Vector2) -> void:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = false
	t.handle_touch(e)


func _drag(t, index: int, pos: Vector2) -> void:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	t.handle_drag(e)


## 找一个**干净的**己方单位（不站在区划中心 / 建筑那一格上，免得单击选中变成选中区划）
func _find_clean_unit(world):
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		var t := Vector2i(floori(u.pos.x), floori(u.pos.y))
		if world.zone_center_zone_at(t.x, t.y) != null:
			continue
		if world.building_at(t.x, t.y) != null:
			continue
		return u
	return null


func _my_units(world) -> Array:
	var out: Array = []
	for u in world.units:
		if u.alive and FactionRes.same_side(u.faction, world.my_faction):
			out.append(u)
	return out


# ------------------------------------------------------------------
# 用例
# ------------------------------------------------------------------

## 手指按下时 `suppresses_mouse()` 必须为真（否则同一次触摸会被走两遍）。
func _test_mouse_suppress(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var p: Vector2 = palette.to_px(Vector2(5.0, 5.0))
	ok(not t.suppresses_mouse(), "没触摸时不丢弃鼠标")
	_down(t, 0, p)
	ok(t.is_active(), "手指按下 = is_active()")
	ok(t.suppresses_mouse(), "★ 手指按下时丢弃模拟鼠标（免得一次点击走两遍）")
	_up(t, 0, p)
	ok(t.suppresses_mouse(), "★ 松手后短时间内仍然丢弃（touch 与模拟 mouse 可能同帧送达）")
	ok(not t.is_active(), "松手后 is_active() 为假")


## 没有选中时，单击己方单位 → 选中它。
func _test_single_tap_select(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	_cmds.clear()
	var u = _find_clean_unit(world)
	if u == null:
		ok(true, "（这张图上没有适合单击的干净单位，跳过）")
		return
	ic.select_units([])
	var scr: Vector2 = palette.to_px(u.pos)
	_down(t, 0, scr)
	_up(t, 0, scr)
	ok(ic.selected_units.has(u), "★ 没选中时单击己方单位 → 选中它")


## 已有选中：单击空地 = move；双击同一点 = attack_move（行军）。
func _test_tap_order_and_double(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var mine := _my_units(world)
	ok(not mine.is_empty(), "（前提）这一局有己方单位")
	if mine.is_empty():
		return
	ic.select_units([mine[0]])

	# 地图中心附近（with_ai = false，那里没有敌人 ⇒ 单击 = 移动）
	var target := Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5)
	var scr: Vector2 = palette.to_px(target)

	_cmds.clear()
	_down(t, 0, scr)
	_up(t, 0, scr)
	ok(_last_kind() == "move", "★ 已选中时单击空地 → move 命令（实际 %s）" % _last_kind())

	# 同一点紧接着再点一下 = 双击 = 行军
	_cmds.clear()
	_down(t, 0, scr)
	_up(t, 0, scr)
	_down(t, 0, scr)
	_up(t, 0, scr)
	ok(_has_kind("attack_move"), "★ 双击同一点 → attack_move（行军）命令")


## ★★ 已有选中时，点地图上的**己方单位** = 下移动命令，**不改选**（问题 2 的回归）。
func _test_tap_own_unit_still_orders(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var mine := _my_units(world)
	if mine.size() < 2:
		ok(true, "（己方单位不足两个，跳过）")
		return
	var a = mine[0]
	var b = mine[1]
	ic.select_units([a])
	var sel_before = ic.selected_units.size()
	var scr: Vector2 = palette.to_px(b.pos)
	_cmds.clear()
	_down(t, 0, scr)
	_up(t, 0, scr)
	ok(_last_kind() == "move",
		"★★ 已选中时点地图上的己方单位 = 下移动命令（不再变成「改选」）")
	ok(ic.selected_units.size() == sel_before and ic.selected_units.has(a),
		"★★ 而且选中没有被改掉（选中后点击一直是移动 / 行军）")


## 单指拖动（起点不在 UI 上）= 拖动视野：相机收到平移、且不下任何命令、**不动选中**。
func _test_single_finger_pan(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var fake = ic.camera_rig
	# ★ 先选中一个单位：拖视野**绝对不能**把它弄丢（问题 5 的回归）。
	var u = _find_clean_unit(world)
	if u != null:
		ic.select_units([u])
	var sel_before = ic.selected_units.size()
	_cmds.clear()

	var start: Vector2 = palette.to_px(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))
	_down(t, 0, start)
	_drag(t, 0, start + Vector2(40.0, 0.0))     # 越过阈值 → 进入拖动视野
	ok(ic.is_panning(), "★ 拖过阈值后进入拖动视野（is_panning 为真，压住边缘滚屏）")
	_drag(t, 0, start + Vector2(90.0, 0.0))     # 真的平移
	ok(fake.pans.size() > 0, "★ 单指拖动 → 相机收到平移")
	_up(t, 0, start + Vector2(90.0, 0.0))
	ok(not ic.is_panning(), "松手后结束拖动视野")
	ok(_cmds.is_empty(), "拖视野不下任何命令")
	ok(sel_before > 0, "（前提）拖动前确实有选中的单位")
	ok(ic.selected_units.size() == sel_before, "★★ 拖视野不改变选中（问题 5：拖动绝不碰选中）")


## 单击容差：小幅移动的快速点击仍算单击；移动超过容差又没到拖动阈值的，什么都不做。
func _test_tap_move_tolerance(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var u = _find_clean_unit(world)
	if u == null:
		ok(true, "（没有合适单位，跳过）")
		return
	ic.select_units([u])
	var scr: Vector2 = palette.to_px(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))

	# ① 小幅移动（< tap_max_move_px）仍算单击 → move（问题 3 的回归：单击不再被误判成拖动）
	_cmds.clear()
	_down(t, 0, scr)
	_drag(t, 0, scr + Vector2(8.0, 0.0))
	_up(t, 0, scr + Vector2(8.0, 0.0))
	ok(_last_kind() == "move", "★ 小幅移动的快速点击仍算单击（→ move，而不是拖动）")

	# ② 移动超过单击容差、又没到拖动阈值 → 什么都不做（不误发命令、也不平移）
	var fake = ic.camera_rig
	var pans_before = fake.pans.size()
	_cmds.clear()
	_down(t, 0, scr)
	_drag(t, 0, scr + Vector2(20.0, 0.0))    # 20 ∈ (tap_max_move 18, pan_min 24)
	_up(t, 0, scr + Vector2(20.0, 0.0))
	ok(_cmds.is_empty(), "★★ 移动超过单击容差、又没到拖动阈值 → 不误发命令")
	ok(fake.pans.size() == pans_before, "★ 也没有被当成拖动")


## ★「长按拖动」：按住超过 pan_hold_sec 后，即使还没怎么移动也进入拖动视野。
func _test_long_press_pan(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var fake = ic.camera_rig
	var start: Vector2 = palette.to_px(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))
	_down(t, 0, start)
	# 按住超过「长按拖动」阈值（用**墙钟**等，让 touch_controller 自己按时间判定）。
	# ⚠️ 不要用 `create_timer(秒)`：它记的是**引擎帧时间**，而 `_press_ms` /
	#    `held_ms` 记的是 `Time.get_ticks_msec()`（墙钟）。--script 模式下第一帧的
	#    delta 可能很大（装载），两者会错开，于是这条用例**约一半概率变红**（实测）。
	var press_ms: int = Time.get_ticks_msec()
	var hold_ms: int = int((cfg.touch_pan_hold_sec + 0.08) * 1000.0)
	while Time.get_ticks_msec() - press_ms < hold_ms:
		await process_frame
	# 小幅移动（远小于 pan_min_px）——因为已经长按，应判定为拖动（问题 5 的「长按拖动」）
	_drag(t, 0, start + Vector2(6.0, 0.0))
	ok(ic.is_panning(), "★★ 长按后小幅移动 = 进入拖动视野")
	_drag(t, 0, start + Vector2(12.0, 0.0))
	ok(fake.pans.size() > 0, "★ 长按拖动 → 相机平移")
	_up(t, 0, start + Vector2(12.0, 0.0))
	ok(not ic.is_panning(), "松手后结束拖动视野")


## ★★ 反斜对角线（右手在上、左手在下）：选框必须按**屏幕矩形**画，两个角 = 两指本身。
##
## 这是用户报的那个 bug 的回归：
##   旧实现只存世界坐标、由 overlay 投影四个角。相机是**透视**的，世界轴对齐矩形的远端边
##   投影回来会缩进 ⇒ 右上 / 左下这两个角离手指一截。
##   现在触摸框选额外记一份屏幕矩形（`drag_screen_box`），overlay 优先按它画。
func _test_two_finger_box_screen_rect(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	ic.select_units([])
	# 两指取「屏幕上」的右上 / 左下（故意跨过另一条对角线）
	var s0: Vector2 = palette.to_px(Vector2(4.0, 4.0))
	var s1: Vector2 = palette.to_px(Vector2(9.0, 9.0))
	var a := Vector2(s1.x, s0.y)                     # 右、上
	var b := Vector2(s0.x, s1.y)                     # 左、下
	_down(t, 0, a)
	_down(t, 1, b)
	_drag(t, 1, b)
	ok(ic.drag_active, "（前提）反斜对角双指 → 进入框选")
	ok(ic.drag_screen_valid, "★★ 触摸框选记下了屏幕矩形（overlay 按它画，不再投影世界四边形）")
	var r: Rect2 = ic.drag_screen_box
	near(r.position.x, minf(a.x, b.x), 0.01, "屏幕矩形左缘 = 两指里靠左那只（不是屏幕盒子的左上角）")
	near(r.position.y, minf(a.y, b.y), 0.01, "屏幕矩形上缘 = 两指里靠上那只")
	near(r.end.x, maxf(a.x, b.x), 0.01, "屏幕矩形右缘 = 两指里靠右那只")
	near(r.end.y, maxf(a.y, b.y), 0.01, "屏幕矩形下缘 = 两指里靠下那只")
	# 也就是说：右上角 = a、左下角 = b —— 两个角**逐像素**在手指上
	ok((Vector2(r.end.x, r.position.y) - a).length() < 0.01,
		"★★ 选框右上角就是右上那只手指")
	ok((Vector2(r.position.x, r.end.y) - b).length() < 0.01,
		"★★ 选框左下角就是左下那只手指")
	_up(t, 1, b)
	ok(not ic.drag_screen_valid, "★ 松手之后屏幕矩形作废（下一帧起按普通框选画）")
	_up(t, 0, a)


## 双指滑动 = 框选（选框两个角 = 两指当前位置）。
func _test_two_finger_box(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var mine := _my_units(world)
	if mine.is_empty():
		ok(true, "（没有己方单位，跳过框选）")
		return
	ic.select_units([])

	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for u in mine:
		mn = Vector2(minf(mn.x, u.pos.x), minf(mn.y, u.pos.y))
		mx = Vector2(maxf(mx.x, u.pos.x), maxf(mx.y, u.pos.y))
	var f0: Vector2 = palette.to_px(mn - Vector2(0.6, 0.6))
	var f1: Vector2 = palette.to_px(mx + Vector2(0.6, 0.6))

	_down(t, 0, f0)
	_down(t, 1, f1)
	ok(ic.drag_active or true, "（两指按下，等待滑动触发框选）")
	_drag(t, 1, f1)                              # 两指矩形够大 → 真正开始框选
	ok(ic.drag_active, "★ 双指张开后进入框选态（overlay 会画出选框、相机冻住）")
	_up(t, 1, f1)
	ok(ic.selected_units.size() > 0, "★ 双指框选 → 选中的己方单位 = 框内那些")
	_up(t, 0, f0)


## ★★ 框选：判定按**图标的屏幕矩形**（不是脚底那个点），并且框到一个兵 = 整支部队。
##
## 用户报的 bug：「框到了单个单位，有概率不会选中这个单位所在的整个部队」。
## 根因：单位是**立牌**（从脚底锚点 `u.pos` 向上约 `QUAD_W×QUAD_H_RATIO` 格），而旧判定只问
##   「脚底那个点」在不在框里 —— 玩家框住的是**看见的牌**，锚点在框外时就被漏掉；
##   「有概率」取决于框画得多高。漏了单位，自然连带它的整支部队都没选中。
## 修法：`box_select_screen()` 按 `_unit_icon_screen_rect(u)`（立牌的屏幕矩形）判相交。
func _test_box_select_screen_and_group(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var mine := _my_units(world)
	if mine.is_empty():
		ok(true, "（没有己方单位，跳过框选判定）")
		return
	ic.select_units([])

	# 挑一个「有部下」的单位当目标（没有就随便挑一个）
	var target = mine[0]
	for u in mine:
		if world.group_of(u).size() > 1:
			target = u
			break
	var s: Vector2 = palette.to_px(target.pos)

	# ---- ① 小框套住脚底（20×20，反斜对角 = 右手在上、左手在下）----
	var a := s + Vector2(10.0, -10.0)     # 手指 0：右、上
	var b := s + Vector2(-10.0, 10.0)     # 手指 1：左、下
	_drag_box(t, ic, a, b)
	ok(ic.selected_units.has(target), "★★ 框住脚底 → 选中")

	# 画框里**每一个**己方单位（按其图标的屏幕矩形判）都必须被选中
	var inside: Array = []
	var missing := 0
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if ic.drag_screen_box.intersects(ic._unit_icon_screen_rect(u)):
			inside.append(u)
			if not ic.selected_units.has(u):
				missing += 1
	ok(inside.size() > 0, "（前提）这个框里至少框到一个己方单位（%d 个）" % inside.size())
	ok(missing == 0, "★★ 框里看到的己方单位全被选中（漏 %d 个）" % missing)
	ok(absf(ic._unit_icon_screen_rect(target).end.y - s.y) < 0.5,
		"★ 立牌的屏幕矩形**下边 = 脚底锚点**（牌是从脚底往上长的）")

	# 整支部队
	var group: Array = world.group_of(target)
	var miss_group := 0
	for m in group:
		if not ic.selected_units.has(m):
			miss_group += 1
	ok(group.size() >= 1, "（前提）查得到它所在的队伍（%d 个）" % group.size())
	ok(miss_group == 0,
		"★★ 框到一个兵 = 整支部队（%d 个）都被选中（漏 %d 个）" % [group.size(), miss_group])

	# 反向：选中集合里**不该有**「框外、又不属于框内任何部队」的单位
	var allowed: Dictionary = {}
	for u in inside:
		for m in world.group_of(u):
			allowed[m.id] = true
	var extra := 0
	for u in ic.selected_units:
		if not allowed.has(u.id):
			extra += 1
	ok(extra == 0, "★★ 没有「框外且不属于框内部队」的单位被选中（多 %d 个）" % extra)

	# ---- ② 只框住「立牌上半部分」（脚底在框外）----
	#   这是旧口径（判脚底锚点）必漏、而新口径（判图标矩形）必中的形态。
	#   框往上多留 40px，保证两指矩形够大（> box_min_px）且明显不含脚底。
	var ir: Rect2 = ic._unit_icon_screen_rect(target)
	var pad := 2.0
	var a2 := Vector2(ir.position.x + pad, ir.position.y - 40.0)
	var b2 := Vector2(ir.end.x - pad, ir.position.y + ir.size.y * 0.45)
	var body_box := Rect2(a2, b2 - a2).abs()
	ic.select_units([])
	ok(not body_box.has_point(s), "（前提）这个框**不含**脚底锚点（只框住立牌上半部分）")
	ok(body_box.size.length() >= cfg.touch_box_min_px, "（前提）框够大，会真的开始框选")
	_drag_box(t, ic, a2, b2)
	ok(ic.selected_units.has(target),
		"★★ 框到**立牌上半部分**（脚底在框外）也选中 —— 修「框住了却没选中」")
	var miss2 := 0
	for m in world.group_of(target):
		if not ic.selected_units.has(m):
			miss2 += 1
	ok(miss2 == 0, "★★ 这一下同样展开成整支部队（漏 %d 个）" % miss2)


## 走一遍「双指按下 → 滑一下 → 松手」的完整手势，返回这次画出来的屏幕框。
func _drag_box(t, ic, a: Vector2, b: Vector2) -> Rect2:
	_down(t, 0, a)
	_down(t, 1, b)
	_drag(t, 1, b)
	var r: Rect2 = ic.drag_screen_box
	_up(t, 1, b)
	_up(t, 0, a)
	return r


## ★★ 第一根手指已经开始拖视野后，第二根手指落下 = 立刻切成框选（问题 3 的回归）。
func _test_two_finger_switches_from_pan(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var t = _new_touch(cfg, palette, ic)
	var start: Vector2 = palette.to_px(Vector2(float(world.map.cols) * 0.5, float(world.map.rows) * 0.5))
	_down(t, 0, start)
	# 第一指先拖超过阈值 → 进入拖视野（相机真的开始动）
	_drag(t, 0, start + Vector2(40.0, 0.0))
	ok(ic.is_panning(), "（前提）第一指已经在拖视野")
	var f1 := start + Vector2(120.0, 80.0)
	_down(t, 1, f1)
	ok(not ic.is_panning(), "★★ 第二根手指落下 → 停掉拖视野（双指一律框选）")
	_drag(t, 1, f1)
	ok(ic.drag_active, "★★ 双指框选开始（不会被先前那次拖视野吃掉）")
	_up(t, 1, f1)
	_up(t, 0, start + Vector2(40.0, 0.0))


## 起点在 UI 上的手势一律不算（交给 GUI / 按钮）。
func _test_starts_on_ui_ignored(cfg, world, palette) -> void:
	var ic = _new_ic(cfg, world, palette)
	var hud := FakeHud.new()
	hud.ui = Rect2(0.0, 0.0, 600.0, 600.0)
	var t = _new_touch(cfg, palette, ic, hud)
	_cmds.clear()
	ic.select_units([])
	var scr := Vector2(100.0, 100.0)             # 落在假 HUD 的 ui 矩形里
	_down(t, 0, scr)
	_up(t, 0, scr)
	ok(ic.selected_units.is_empty(), "★ 起点在 UI 上的单击不改变选中（交给 GUI）")
	ok(_cmds.is_empty(), "起点在 UI 上的单击不下任何命令")

	# 同一位置拖动也不该平移视野
	var fake = ic.camera_rig
	_down(t, 0, scr)
	_drag(t, 0, scr + Vector2(120.0, 0.0))
	_up(t, 0, scr + Vector2(120.0, 0.0))
	ok(fake.pans.is_empty(), "★ 起点在 UI 上的拖动不平移视野")
