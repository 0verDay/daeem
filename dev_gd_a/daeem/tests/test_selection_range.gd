## test_selection_range.gd —— 单位「点选 / 框选」范围（2026.10.22 调松）
##
## 需求：玩家反馈「单位有些太难被选中」⇒ 略微增大**点击**与**框选**范围。
##
## 覆盖：
##   · config 的三个容差（unit.hit_pad / unit.pick_pad_px / ui.box_select_pad_px）；
##   · ★ 点**立牌上半身**也能选中（脚底圆之外 —— 这是「太难选中」的主因）；
##   · ★ 立牌外的 `pick_pad_px` 容差：贴边 1px 还能点中、超出去就点不到；
##   · ★ 框选：选框贴着牌边（扩了 `box_select_pad_px`）也算框到，超出去不算；
##   · 脚底圆仍然有效（旧手感不变），敌人从立牌上也能被点名。
extends "res://tests/test_case.gd"

const InputCtrlRes = preload("res://view/input_controller.gd")
const FactionRes = preload("res://logic/faction.gd")


func _initialize() -> void:
	_case_name = "test_selection_range"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var world = require_world_with_escorts(cfg, 2, "p1")
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

	var ic = InputCtrlRes.new()
	root.add_child(ic)
	ic.setup(cfg, world, null, palette)

	_test_config(cfg)
	# 把所有人先挪到远处，避免「点到别人」干扰下面几条精确判定。
	_scatter_units(world)
	var target = _first_group_unit(world)
	ok(target != null, "（前提）找得到一个带部下的己方单位")
	if target != null:
		_test_click_body(cfg, world, palette, ic, target)
		_test_click_pad(cfg, world, palette, ic, target)
		_test_feet_still_works(cfg, world, palette, ic, target)
		_test_box_pad(cfg, world, palette, ic, target)
	# 敌人：立牌上也能右键点名
	var foe = world.spawn_enemy(5, 5)
	if foe != null:
		_test_enemy_body(cfg, world, palette, ic, foe)

	ic.queue_free()
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 0) config
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	eq(cfg.unit_hit_pad_px, 8.0, "★ 脚底圆容差 = 8px（原来是 6）")
	eq(cfg.unit_pick_pad_px, 4.0, "★ 立牌容差 = 4px")
	eq(cfg.box_select_pad_px, 5.0, "★ 框选容差 = 5px")
	ok(cfg.unit_pick_pad_px > 0.0 and cfg.box_select_pad_px > 0.0,
		"两个新容差都真的开着（0 = 等于没加宽）")


# ------------------------------------------------------------------
# 1) 点立牌上半身（脚底圆之外）
# ------------------------------------------------------------------
func _test_click_body(cfg, world, palette, ic, target) -> void:
	_place(world, target, Vector2(8.5, 8.5))
	var icon: Rect2 = ic._unit_icon_screen_rect(target)
	ok(icon.size.x > 1.0 and icon.size.y > 1.0, "（前提）立牌的屏幕矩形有尺寸")
	var p := Vector2(icon.get_center().x, icon.position.y + icon.size.y * 0.35)
	var world_pt: Vector2 = palette.to_logic(p)
	ok(ic._unit_hit_norm(target, world_pt) > 1.0,
		"（前提）这一点在脚底圆之外（旧判据会漏掉它）")
	var picked = ic._pick_any_unit_at(world_pt)
	eq(picked, target, "★★ 点立牌上半身也能选中（不用再瞄准脚底）")


# ------------------------------------------------------------------
# 2) 立牌容差：贴边 1px 还行、超出去不行
# ------------------------------------------------------------------
func _test_click_pad(cfg, world, palette, ic, target) -> void:
	_place(world, target, Vector2(8.5, 8.5))
	var icon: Rect2 = ic._unit_icon_screen_rect(target)
	# 牌左缘往外 (pad - 1)px：不在牌的精确矩形里，但在扩出来的容差里
	var p_in := Vector2(icon.position.x - cfg.unit_pick_pad_px + 1.0, icon.get_center().y)
	ok(not icon.has_point(p_in), "（前提）这一点在牌的精确矩形之外")
	eq(ic._pick_any_unit_at(palette.to_logic(p_in)), target,
		"★ 牌边外几像素（容差内）仍然点得中")
	# 再往外 3px：超出容差 ⇒ 点不到
	var p_out := Vector2(icon.position.x - cfg.unit_pick_pad_px - 3.0, icon.get_center().y)
	eq(ic._pick_any_unit_at(palette.to_logic(p_out)), null,
		"★ 超出容差就点不到（不会变成一个无限大的命中区）")


# ------------------------------------------------------------------
# 3) 脚底圆仍然有效（旧手感不变）
# ------------------------------------------------------------------
func _test_feet_still_works(cfg, world, palette, ic, target) -> void:
	_place(world, target, Vector2(8.5, 8.5))
	var feet: Vector2 = palette.to_px(target.pos)
	eq(ic._pick_any_unit_at(palette.to_logic(feet)), target, "★ 点脚底照样选中（原判据保留）")
	var feet_norm: float = ic._unit_hit_norm(target, target.pos)
	ok(feet_norm <= 1.0 and feet_norm < 0.01, "脚底正中心几乎就是距离 0（%.4f）" % feet_norm)


# ------------------------------------------------------------------
# 4) 框选：贴着牌边（容差内）也算框到
# ------------------------------------------------------------------
func _test_box_pad(cfg, world, palette, ic, target) -> void:
	_place(world, target, Vector2(8.5, 8.5))
	var icon: Rect2 = ic._unit_icon_screen_rect(target)
	# 一条 1px 宽的竖条，只在牌的左外侧 pad-1 px 处：与**精确**矩形不相交
	var strip := Rect2(
		Vector2(icon.position.x - cfg.box_select_pad_px + 1.0, icon.position.y),
		Vector2(1.0, icon.size.y))
	ok(not strip.intersects(icon), "（前提）窄条压不到牌的精确矩形")
	ic.select_units([])
	eq(ic.box_select_screen(strip), 1, "★ 选框贴着牌边（容差内）也算框到")
	ok(ic.selected_units.has(target), "★ 它（连带整支部队）被选中")

	# 再往左移出容差 → 框不到任何单位
	var miss := Rect2(
		Vector2(icon.position.x - cfg.box_select_pad_px - 4.0, icon.position.y),
		Vector2(1.0, icon.size.y))
	ic.select_units([])
	ic.box_select_screen(miss)
	ok(not ic.selected_units.has(target), "★ 超出容差的空框不会选中它")


# ------------------------------------------------------------------
# 5) 敌人：立牌上也能被点名（右键攻击那条路）
# ------------------------------------------------------------------
func _test_enemy_body(cfg, world, palette, ic, foe) -> void:
	var old_fog: bool = cfg.fog_enabled
	cfg.fog_enabled = false                 # 这条只验拾取几何，不验迷雾
	_place(world, foe, Vector2(12.5, 8.5))
	var icon: Rect2 = ic._unit_icon_screen_rect(foe)
	var p := Vector2(icon.get_center().x, icon.position.y + icon.size.y * 0.35)
	eq(ic._pick_foe_unit_at(palette.to_logic(p)), foe,
		"★ 敌人的立牌上半身也能被右键点名")
	eq(ic._pick_any_unit_at(palette.to_logic(p)), foe,
		"★ 左键点在敌人立牌上也能选中它")
	cfg.fog_enabled = old_fog


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------
func _place(world, u, pos: Vector2) -> void:
	u.pos = pos
	u.sync_tile(world.map)


func _scatter_units(world) -> void:
	var i := 0
	for u in world.units:
		if not u.alive:
			continue
		# 全部挪到地图右下角附近，彼此隔开 1 格
		_place(world, u, Vector2(float(world.map.cols - 2) + float(i % 4) * 1.2,
			float(world.map.rows - 2) + float(i / 4) * 1.2))
		i += 1


func _first_group_unit(world):
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if world.group_of(u).size() > 1:
			return u
	return null
