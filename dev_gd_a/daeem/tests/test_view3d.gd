## test_view3d.gd —— 3D 渲染栈的断言（本版新增）
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const Game3DRes = preload("res://view/game_scene3d.gd")
const GroundRes = preload("res://view/ground_view.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")
const BuildingViewRes = preload("res://view/building_view_3d.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingShaderRes = preload("res://view/building_flash.gdshader")
const UnitDownedShaderRes = preload("res://view/unit_downed.gdshader")
const Overlay3DRes = preload("res://view/overlay_view_3d.gd")
const OrderFlagRes = preload("res://view/order_flag_view_3d.gd")
## ★★ 局内敌/友/己三色（本轮新增）
const SideColorRes = preload("res://view/side_color.gd")

func _initialize() -> void:
	_case_name = "test_view3d"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_sprite_bake(cfg)
	_test_sprite_bake_assets(cfg)
	await process_frame
	_test_projection_roundtrip(cfg)
	_test_camera_invariants(cfg)
	await _test_hud_and_minimap(cfg)
	await _test_units_multimesh(cfg)
	await _test_units_downed_decal(cfg)
	await _test_buildings_multimesh(cfg)
	await _test_zone_flag(cfg)
	await _test_ground_bake(cfg)
	await _test_camera_aim(cfg)
	await _test_order_flags(cfg)
	await _test_selection_ring(cfg)
	await _test_grid_near_clip(cfg)
	await _test_capture_area(cfg)
	await _test_aura_range(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_sprite_bake(cfg) -> void:
	SpriteRes.clear_cache()
	var troop: ImageTexture = SpriteRes.bake(Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	var leader: ImageTexture = SpriteRes.bake(Color(0.9, 0.2, 0.2), true, Color(0, 0, 0))
	ok(troop != null and leader != null, "兵人贴图烘得出来（普通 / 将领）")
	if troop == null or leader == null:
		return
	var it: Image = troop.get_image()
	var il: Image = leader.get_image()
	ok(it != null and il != null, "贴图拿得到 Image（可逐像素验）")
	if it == null or il == null:
		return
	var opaque_t := _count_opaque(it)
	var opaque_l := _count_opaque(il)
	ok(opaque_t > 100, "普通兵贴图有实质剪影（不透明像素 %d）" % opaque_t)
	ok(opaque_l > opaque_t, "★ 将领贴图更大（肩更宽 + 头顶缨：%d > %d）" % [opaque_l, opaque_t])
	var c: Color = it.get_pixel(SpriteRes.TEX_W / 2, SpriteRes.TEX_H * 5 / 12)
	ok(c.r > c.g + 0.2, "★ 阵营色烘进了贴图（取样点 r=%.2f 明显大于 g=%.2f）" % [c.r, c.g])
	var again: ImageTexture = SpriteRes.bake(Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	ok(again == troop, "★ 同一组参数命中缓存（不重复光栅化）")
	var bottom_row_opaque := 0
	for x in SpriteRes.TEX_W:
		if it.get_pixel(x, SpriteRes.TEX_H - 1).a > 0.5:
			bottom_row_opaque += 1
	ok(bottom_row_opaque > 0 and bottom_row_opaque < SpriteRes.TEX_W / 2,
		"★ 贴图最底一行是**脚**（%d 个不透明像素：> 0 不浮空、< 半宽也不是一整条）"
			% bottom_row_opaque)

static func _count_opaque(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				n += 1
	return n

static func _first_tinted_color(img: Image) -> Color:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and c.r > c.g + 0.2:
				return c
	return Color(0, 0, 0, 0)

func _test_sprite_bake_assets(cfg) -> void:
	SpriteRes.clear_cache()
	var types: Array = [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN,
		UnitRes.UNIT_TYPE_RIDER, UnitRes.UNIT_TYPE_GRAIN_CART, UnitRes.UNIT_TYPE_KNIGHT,
		UnitRes.UNIT_TYPE_HORSE_ARCHER, UnitRes.UNIT_TYPE_CATAPULT]
	var seen_paths: Dictionary = {}
	var images: Dictionary = {}
	for id in types:
		var t := String(id)
		var path: String = cfg.unit_sprite_of(t)
		var tint: String = cfg.unit_sprite_tint_of(t)
		ok(path != "", "%s 配了 sprite 路径" % t)
		ok(ResourceLoader.exists(path), "★ %s 的素材被导入过（%s）" % [t, path])
		var tex: ImageTexture = SpriteRes.bake_asset(path, Color(0.9, 0.2, 0.2), false,
			Color(0.9, 0.2, 0.2), tint)
		ok(tex != null, "%s 的立牌贴图烘得出来" % t)
		if tex == null:
			continue
		var img: Image = tex.get_image()
		ok(img != null and _count_opaque(img) > 100,
			"★ %s 的剪影有实质像素（不透明 %d）" % [t, _count_opaque(img) if img != null else -1])
		if img == null:
			continue
		if tint == "art":
			ok(_has_greyish(img), "★★ %s 是 art 档：原画的灰色留在贴图里（没被阵营色刷掉）" % t)
			ok(_count_near(img, Color(0.9, 0.2, 0.2), 0.08) > 10,
				"★ %s 的 art 描边是阵营色" % t)
		else:
			ok(_count_near(img, Color(0.9, 0.2, 0.2), 0.05) > _count_opaque(img) / 3,
				"★ %s 是 faction 档：字/形状被阵营色填满" % t)
		seen_paths[path] = true
		images[t] = img
	ok(seen_paths.size() == types.size(),
		"★ 七个兵种的素材路径互不相同（%d 个）" % seen_paths.size())
	ok(cfg.unit_sprite_tint_of(UnitRes.UNIT_TYPE_SPEARMAN) == "art", "长枪兵 = art（保留原画）")
	ok(cfg.unit_sprite_tint_of(UnitRes.UNIT_TYPE_LONGBOWMAN) == "art", "长弓兵 = art")
	ok(cfg.unit_sprite_tint_of(UnitRes.UNIT_TYPE_RIDER) == "faction", "骑手 = faction（单字占位）")
	ok(cfg.unit_sprite_tint_of("general") == "art",
		"★ 将领跟随所属兵种（general → 长枪兵 = art）")
	var keys: Array = images.keys()
	var all_distinct := keys.size() == types.size()
	if all_distinct:
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				if (images[keys[i]] as Image).get_data() == (images[keys[j]] as Image).get_data():
					all_distinct = false
	ok(all_distinct, "★★ 七个兵种的贴图两两不同（否则还是「长得一样」）")
	var p0: String = cfg.unit_sprite_of(UnitRes.UNIT_TYPE_SPEARMAN)
	var faction := Color(0.9, 0.2, 0.2)
	var troop: ImageTexture = SpriteRes.bake_asset(p0, faction, false, faction, "art")
	var leader: ImageTexture = SpriteRes.bake_asset(p0, faction, true, faction, "art")
	if troop != null and leader != null and troop.get_image() != null and leader.get_image() != null:
		var ot := _count_opaque(troop.get_image())
		var ol := _count_opaque(leader.get_image())
		ok(ol > ot, "★ 将领档描边更粗（不透明像素 %d > %d）" % [ol, ot])
	ok(SpriteRes.bake_asset(p0, faction, false, faction, "art") == troop,
		"★ 素材贴图命中缓存（不重复光栅化）")
	# ★★ 选中档：**整圈描边换成金色**（用户二轮口径：不是「阵营色外再套一圈」）
	var sel_col := Color(0.949, 0.710, 0.267)     # #f2b544
	var picked: ImageTexture = SpriteRes.bake_asset(p0, faction, false, faction, "art",
		true, sel_col)
	if picked != null and picked.get_image() != null and troop != null \
			and troop.get_image() != null:
		var n_unsel := _count_opaque(troop.get_image())
		var n_sel := _count_opaque(picked.get_image())
		ok(absi(n_sel - n_unsel) <= 40,
			"★ 选中档的几何不变、只换描边颜色（%d ≈ %d）" % [n_sel, n_unsel])
		ok(_count_near(picked.get_image(), sel_col, 0.06) > 10,
			"★★ 选中档的描边是金色")
		ok(_count_near(picked.get_image(), faction, 0.05) < 10,
			"★★ 选中后阵营色描边被**替换**掉了（没有残留的红边）")
		ok(picked != troop, "选中 / 未选中是两张不同的贴图")
	SpriteRes.clear_cache()
	var fallback: ImageTexture = SpriteRes.bake_asset("", faction, false, faction, "art")
	var proc: ImageTexture = SpriteRes.bake(faction, false, faction)
	ok(fallback != null and proc != null and fallback.get_image() != null
		and proc.get_image() != null
		and fallback.get_image().get_data() == proc.get_image().get_data(),
		"★ 没配素材 / 载不到 → 退回程序化剪影（同一张图）")


## 贴图里有没有「灰阶原画色」（r≈g≈b 且够亮）——用来钉「art 档保留原画」。
static func _has_greyish(img: Image) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.9 and absf(c.r - c.g) < 0.03 and absf(c.g - c.b) < 0.03 and c.r > 0.4:
				return true
	return false


## 与 `want` 每个通道都相差不超过 `tol` 的像素个数。
## ⚠️ 门槛是 a > 0.5 而不是「不透明」：默认描边带 OUTLINE_ALPHA = 0.72 的 alpha。
static func _count_near(img: Image, want: Color, tol: float) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and absf(c.r - want.r) <= tol and absf(c.g - want.g) <= tol \
					and absf(c.b - want.b) <= tol:
				n += 1
	return n

func _test_projection_roundtrip(cfg) -> void:
	var cam: Camera3D = make_test_camera(cfg, 24, 16)
	ok(cam != null, "造得出测试相机")
	if cam == null:
		return
	var pal = make_test_palette(cfg, cam)
	ok(pal != null, "造得出 palette 实例")
	if pal == null:
		return
	var worst := 0.0
	for sp: Vector2 in [Vector2(960, 540), Vector2(300, 300), Vector2(1600, 800),
			Vector2(960, 100), Vector2(960, 1000)]:
		var lg = pal.to_logic(sp)
		if lg == null:
			continue
		var back: Vector2 = pal.to_px(lg)
		worst = maxf(worst, back.distance_to(sp))
	ok(worst < 0.05, "★ 投影往返自洽（最大误差 %.4f px < 0.05）" % worst)
	var corner: Variant = pal.to_logic(Vector2(0, 0))
	ok(corner != null, "屏幕左上角能打到地面（俯视相机没有地平线之上的射线）")

func _test_camera_invariants(cfg) -> void:
	var cols := 24
	var rows := 16
	var cam: Camera3D = make_test_camera(cfg, cols, rows)
	var pal = make_test_palette(cfg, cam)
	if cam == null or pal == null:
		return
	var w_top := _tile_w(pal, Vector2(10.0, 2.0))
	var w_bot := _tile_w(pal, Vector2(10.0, rows - 2))
	var ratio: float = w_bot / maxf(1e-6, w_top)
	ok(ratio > 1.0, "近处（屏幕下方）的格比远处的大 —— 这是透视应有的表现（%.2f 倍）" % ratio)
	ok(ratio < 2.0,
		"★★ 但收缩比必须**受控**（%.2f < 2.0）—— 大了就是「下滑时地块暴涨」那个 bug" % ratio)
	var y_before: float = cam.position.y
	cam.position += Vector3(500.0, 0.0, -300.0)
	ok(is_equal_approx(cam.position.y, y_before),
		"★ 平移不动相机高度（%.3f == %.3f）" % [cam.position.y, y_before])
	var basis_before: Basis = cam.global_transform.basis
	ok(is_equal_approx(basis_before.x.length(), 1.0)
		and is_equal_approx(basis_before.y.length(), 1.0)
		and is_equal_approx(basis_before.z.length(), 1.0),
		"★ 相机基是单位正交基（长度都是 1）")
	ok(basis_before.y.y > 0.0, "★ 相机的 up 分量朝上（没有把画面翻过来）")
	var w_a := _tile_w(pal, Vector2(10.0, 8.0))
	var origin_before: Vector3 = cam.global_transform.origin
	cam.global_transform.origin = origin_before + Vector3(400.0, 0.0, 0.0)
	var w_b := _tile_w(pal, Vector2(10.0, 8.0))
	near(w_b, w_a, 0.01,
		"★★ 平移不动「格在屏幕上占多大」（%.4f == %.4f）—— 这就是「下滑时地块不变大」的保证"
		% [w_b, w_a])
	cam.global_transform.origin = origin_before

func _tile_w(pal, tile: Vector2) -> float:
	var a: Vector2 = pal.to_px(tile)
	var b: Vector2 = pal.to_px(tile + Vector2(1.0, 0.0))
	return a.distance_to(b)

func _test_units_multimesh(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	ok(game.start(), "3D 游戏场景装得起来")
	if game.world == null:
		game.queue_free()
		return
	await process_frame
	await process_frame

	var w = game.world
	var expect := 0
	for u in w.units:
		if u.alive and game.units._visible_to_me(u):
			expect += 1
	eq(game.units.instance_count, expect,
		"★ MultiMesh 实例数 = 可见单位数（%d）" % expect)
	ok(game.units.instance_count > 0, "★ 真有单位被画了出去（不是 0 —— 写成 0 就什么都不画）")
	var variants: Dictionary = {}
	for u in w.units:
		if u.alive and game.units._visible_to_me(u):
			var vk := "%s|%d|%s|%d|%d" % [String(u.faction), 1 if u.is_general() else 0,
				String(u.unit_type),
				1 if game.units._selection_set.has(String(u.id)) else 0,
				1 if u.is_downed() else 0]
			variants[vk] = true
	var max_batches: int = variants.size()
	ok(game.units.mesh_batch_count <= max_batches,
		"★★ 批次数不超过变体数（%d ≤ %d：可见单位的 阵营|将领|兵种 组合数）"
		% [game.units.mesh_batch_count, max_batches])
	ok(game.units.batches_created <= max_batches,
		"★ 累计创建的批次数也没超（%d ≤ %d）" % [game.units.batches_created, max_batches])

	game.units.sync()
	var with_fog: int = game.units.instance_count
	var hidden_count := 0
	for u in w.units:
		if u.alive and not game.units._visible_to_me(u):
			hidden_count += 1
	ok(hidden_count >= 0, "（诊断）被迷雾挡住的单位数 = %d" % hidden_count)

	# ★★ 选中一个可见单位 → 批次键多一段「是否选中 = 1」（金描边是另一张贴图）
	var pick = null
	for u3 in w.units:
		if u3.alive and game.units._visible_to_me(u3):
			pick = u3
			break
	if pick != null:
		game.units.set_selection([String(pick.id)])
		game.units.sync()
		var sel_key := ""
		for k in game.units._batches.keys():
			var ps: PackedStringArray = String(k).split("|")
			if ps.size() == 5 and ps[3] == "1":
				sel_key = String(k)
		ok(sel_key != "", "★★ 选中单位落在带「选中 = 1」的批次里（金描边贴图）")
		ok(sel_key.begins_with(String(pick.faction) + "|"),
			"★ 选中批次的阵营段对得上（%s）" % sel_key)
		game.units.set_selection([])
		game.units.sync()
		ok(game.units.instance_count == expect,
			"★ 取消选中后实例数不变（只是换个批次）")

	game.queue_free()
	await process_frame

func _test_units_downed_decal(cfg) -> void:
	var code: String = UnitDownedShaderRes.code
	ok(code.contains("ALPHA"), "★ 濒死 shader 写了 ALPHA（半透明）")
	ok(not code.contains("ALPHA_SCISSOR_THRESHOLD ="),
		"★★ 濒死 shader **不写** scissor（否则半透明又变回「要么全有要么全无」）")
	var dt: ImageTexture = SpriteRes.decal_texture()
	ok(dt != null and dt.get_image() != null, "★ 将领占位贴花烘得出来")
	if dt != null and dt.get_image() != null:
		ok(_count_opaque(dt.get_image()) > 50,
			"★ 贴花有实质像素（不透明 %d）" % _count_opaque(dt.get_image()))

	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	await process_frame
	await process_frame
	var w = game.world
	game.set_process(false)
	game.units.sync()

	var expect_decals := 0
	for u in w.units:
		if u.alive and u.is_general() and game.units._visible_to_me(u):
			expect_decals += 1
	ok(expect_decals > 0, "（前提）场上至少有一位可见将领（%d）" % expect_decals)
	eq(game.units.decal_count, expect_decals,
		"★ 每个可见将领脚下都有一张贴花（%d）" % expect_decals)

	var g = null
	for u2 in w.units:
		if u2.alive and u2.is_general() and game.units._visible_to_me(u2):
			g = u2
			break
	if g != null:
		eq(game.units.downed_count, 0, "（前提）一开始没有濒死将领")
		g.downed = true
		game.units.sync()
		ok(game.units.downed_count >= 1,
			"★ 濒死将领计入 downed_count（%d）" % game.units.downed_count)
		var has_downed_batch := false
		for k in game.units._batches.keys():
			if String(k).ends_with("|1"):
				has_downed_batch = true
		ok(has_downed_batch, "★ 濒死将领落在单独的批次（键以 |1 结尾）")
		g.downed = false
		game.units.sync()
		eq(game.units.downed_count, 0, "★ 站起来后 downed_count 归零")

	game.queue_free()
	await process_frame

func _test_buildings_multimesh(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	await process_frame
	await process_frame

	var w = game.world
	game.buildings.sync()
	ok(game.buildings.instance_count > 0,
		"★ 建筑真的画了出去（%d 栋）" % game.buildings.instance_count)
	ok(game.buildings.mesh_batch_count <= game.buildings.instance_count,
		"★ 建筑批次数不超过建筑数（%d ≤ %d）"
		% [game.buildings.mesh_batch_count, game.buildings.instance_count])
	for mt in BuildingViewRes.BUILDING_MODELS:
		ok(game.buildings._model_meshes.get(mt, null) != null,
			"★★ 模型类型 %s 的网格已加载（否则该类型静默不画）" % mt)
	for mt in BuildingViewRes.BUILDING_MOVING_MODELS:
		ok(game.buildings._moving_meshes.get(mt, null) != null,
			"★★ 可动部件 %s 的网格已加载（旗面，否则旗子静默不画）" % mt)
	var b0 = null
	for b in w.building_list:
		if b.alive:
			b0 = b
			break
	if b0 != null:
		var t: Transform3D = game.buildings._transform_of(b0)
		var sz: Vector3 = t.basis.get_scale()
		var expect_w: float = game.buildings.palette.cell_size() * b0.body_scale(cfg)
		near(sz.x, expect_w, 0.01,
			"★ 建筑方块的宽 = 格宽 × body_scale（logic 的权威值）")
		var bottom: float
		if game.buildings._uses_model(String(b0.type)):
			near(sz.y, expect_w, 0.01, "★ 模型等比缩放（高 = 宽 = 格宽 × body_scale）")
			bottom = t.origin.y
		else:
			bottom = t.origin.y - sz.y * 0.5
		near(bottom, 0.6, 0.01,
			"★ 建筑底边贴地（底边 y = %.2f，类型 %s）" % [bottom, String(b0.type)])

	ok(BuildingShaderRes.code.contains("depth_draw_always"),
		"★★ 建筑 shader 写了 depth_draw_always（否则近的建筑会被远的盖住 —— 用户报的 bug）")
	ok(BuildingShaderRes.code.contains("INSTANCE_CUSTOM.g"),
		"★ 建筑 shader 从每实例数据读淡出量(.g)")
	ok(BuildingShaderRes.code.contains("NORMAL") and BuildingShaderRes.code.contains("shade"),
		"★★ 建筑 shader 走假光照（读 NORMAL 算 shade ⇒ 有立体感）")

	game.set_process(false)         # 冻住主循环，让计数确定
	game.buildings.sync()
	var marked: Dictionary = game.buildings._fade_marked_tiles()
	var expect_fade := 0
	for b2 in w.building_list:
		if b2.alive and game.buildings._visible_to_me(b2) \
				and game.buildings.should_fade(b2, marked):
			expect_fade += 1
	eq(game.buildings.faded_last_frame, expect_fade,
		"★ 淡出的建筑数 = 「3x3 内有可见单位」的建筑数（%d）" % expect_fade)

	var target = null
	for b3 in w.building_list:
		if b3.alive and game.buildings._visible_to_me(b3) \
				and not game.buildings.should_fade(b3, marked):
			target = b3
			break
	if target != null:
		var mover = null
		for u2 in w.units:
			if u2.alive and game.buildings._unit_visible(u2):
				mover = u2
				break
		if mover != null:
			mover.pos = Vector2(float(target.tx) + 1.5, float(target.ty) + 0.5)   # 紧邻一格
			mover.sync_tile(w.map)
			ok(game.buildings.should_fade(target, game.buildings._fade_marked_tiles()),
				"★ 单位站到建筑旁边一格 ⇒ 该建筑要淡出（3x3 判定）")
			mover.pos = Vector2(float(target.tx) + 5.5, float(target.ty) + 0.5)   # 离 5 格
			mover.sync_tile(w.map)
			ok(not game.buildings.should_fade(target, game.buildings._fade_marked_tiles()),
				"★ 单位离建筑 5 格 ⇒ 不淡出")
		else:
			ok(false, "找不到可见单位来验淡出")
	var fa: float = cfg.num("render.building_fade_alpha", 0.3)
	ok(fa > 0.0 and fa < 1.0, "★ 建筑淡出的 alpha 在 (0,1) 之间（%.2f）" % fa)

	game.queue_free()
	await process_frame

func _test_zone_flag(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	await process_frame
	await process_frame
	var w = game.world

	var b = null
	for bb in w.building_list:
		if bb.alive and String(bb.type) == "zone_center":
			b = bb
			break
	ok(b != null, "地图里有区划中心建筑")
	if b == null:
		game.queue_free()
		await process_frame
		return
	var z: Variant = w.zone_by_id(int(b.zone_id))
	ok(z != null, "★ 区划中心能反查到它的区划（zone_id）")
	if z == null:
		game.queue_free()
		await process_frame
		return

	z["owner"] = ""
	z["capture_state"] = ""
	z["capture_faction"] = ""
	z["progress"] = 0.0
	eq(float(game.buildings.zone_flag_state(b)["progress"]), 0.0,
		"★ 无人占领 ⇒ progress = 0（不画旗子）")
	game.buildings.sync()
	var base_flags: int = game.buildings.flag_instance_count

	z["capture_state"] = "reading"
	z["capture_faction"] = "p1"
	z["progress"] = 0.5
	near(float(game.buildings.zone_flag_state(b)["progress"]), 0.5, 1e-6,
		"★ 占领中 ⇒ progress = 占领进度（0.5）")
	var t0: Transform3D = game.buildings._flag_transform(b, 0.0)
	var t1: Transform3D = game.buildings._flag_transform(b, 1.0)
	ok(t1.origin.y > t0.origin.y, "★ 旗面随进度从杆底升到杆顶（y 变大）")
	var k: float = game.buildings.palette.cell_size() * b.body_scale(cfg)
	near(t0.origin.y, 0.6 + 0.12 * k, 0.01, "★ progress 0 时旗面底边在杆底")
	near(t1.origin.y, 0.6 + (1.02 - 0.32) * k, 0.01, "★ progress 1 时旗面升到「杆顶 − 旗高」")
	game.buildings.sync()
	eq(game.buildings.flag_instance_count, base_flags + 1,
		"★ 该区划转为占领中 ⇒ 恰好多画一面旗")

	z["owner"] = "p1"
	z["capture_state"] = ""
	near(float(game.buildings.zone_flag_state(b)["progress"]), 1.0, 1e-6,
		"★ 已被占领 ⇒ 旗子升到顶（progress = 1）")

	game.queue_free()
	await process_frame

func _test_ground_bake(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	game.set_process(false)
	await process_frame
	await process_frame

	var g = game.ground
	var w = game.world
	eq(g.baked_tiles, int(w.map.cols) * int(w.map.rows),
		"★ 地面贴图烘的格数 = 全图格数（%d）" % (int(w.map.cols) * int(w.map.rows)))
	var img: Image = g._tex.get_image() if g._tex != null else null
	ok(img != null, "地面贴图拿得到 Image")
	if img != null:
		eq(img.get_width(), int(w.map.cols) * GroundRes.PX_PER_TILE,
			"★ 贴图宽 = 格数 × 每格像素（%d）" % GroundRes.PX_PER_TILE)
		ok(img.get_width() > int(w.map.cols),
			"★ 分辨率高于「1 像素 = 1 格」（否则放大后必糊，实测过）")
	var before: int = g.bake_count
	if w.zones != null and w.zones.zones.size() > 0:
		var z0: Dictionary = w.zones.zones[0]
		z0["owner"] = "p2" if String(z0.get("owner", "")) != "p2" else "p1"
	g.rebake()
	ok(g.bake_count > before,
		"★ 区块归属变了会重烘地面贴图（%d -> %d）" % [before, g.bake_count])
	if g._fog_mesh != null:
		ok(true, "迷雾层节点存在")

	# ★★ 迷雾：精确检测 / 脏格重绘 / 限频（本轮修「大地图迷雾延迟高」）
	#   旧实现抽 18 个固定格当签名；这里专门翻一个**旧抽样序列之外**的格，
	#   证明「非抽样格变化」也会立刻触发重烘（旧版在 100×100 图上漏检率 >96%）。
	if w.fog != null and g._fog_tex != null \
			and w.fog.sight.has(FactionRes.side_of(String(w.my_faction))):
		var cols_i: int = int(w.map.cols)
		var rows_i: int = int(w.map.rows)
		var cells_i: int = cols_i * rows_i
		var side := FactionRes.side_of(String(w.my_faction))
		var mask0: PackedByteArray = w.fog.sight[side]
		var sampled := {}
		for si in 16:
			sampled[Vector2i((si * 7) % cols_i, (si * 3) % rows_i)] = true
		sampled[Vector2i(0, 0)] = true
		sampled[Vector2i(cols_i - 1, rows_i - 1)] = true
		var flip := -1
		for i in cells_i:
			var tx: int = i % cols_i
			var ty: int = i / cols_i
			if not w.map.tile_exists(tx, ty):
				continue
			if sampled.has(Vector2i(tx, ty)):
				continue
			flip = i
			break
		ok(flip >= 0, "（前提）找到一格「旧抽样序列之外」的迷雾格")

		# 强制全量烘：脏格表清空 ⇒ 全图刷一遍。
		g.rebake_fog(true)
		eq(g.fog_painted_tiles, cells_i, "★★ 强制重烘 = 全图刷一遍（%d 格）" % cells_i)

		var gcfg = g.cfg
		var old_min: float = gcfg.fog_rebake_min_sec
		gcfg.fog_rebake_min_sec = 0.0
		var bakes: int = g.fog_bake_count
		var mask1: PackedByteArray = mask0.duplicate()
		mask1[flip] = 1 if mask1[flip] == 0 else 0
		w.fog.sight[side] = mask1
		g.rebake_fog()
		ok(g.fog_bake_count == bakes + 1,
			"★★ 非抽样格变了也会立刻重烘（旧版在大图上 ≥96%% 会漏检）")
		eq(g.fog_painted_tiles, 1, "★★ 脏格重绘：只重画变化的那 1 格")
		g.rebake_fog()
		eq(g.fog_bake_count, bakes + 1, "★★ 掩码没变 ⇒ 不重烘")

		# 限频：窗口内先不烘，窗口过了必须补上（变化不能被吃掉）。
		gcfg.fog_rebake_min_sec = 0.1
		g._fog_last_bake_msec = Time.get_ticks_msec()
		var mask2: PackedByteArray = mask1.duplicate()
		mask2[flip] = 1 if mask2[flip] == 0 else 0
		w.fog.sight[side] = mask2
		g.rebake_fog()
		eq(g.fog_bake_count, bakes + 1, "★ 0.1s 限频窗口内先不重烘")
		g._fog_last_bake_msec = Time.get_ticks_msec() - 200
		g.rebake_fog()
		eq(g.fog_bake_count, bakes + 2, "★★ 窗口过了补上（变化没被吃掉）")

		# 还原（后续用例还要用这张贴图 / 这份掩码）。
		gcfg.fog_rebake_min_sec = old_min
		w.fog.sight[side] = mask0
		g.rebake_fog(true)

	eq(g._mat.uv1_scale, Vector3(1, 1, 1), "★★ 地面层 UV 不翻转（scale 恒等 —— 翻转就是上下反）")
	eq(g._mat.uv1_offset, Vector3(0, 0, 0), "★★ 地面层 UV 不偏移（offset 恒等）")
	eq(g._fog_mat.uv1_scale, Vector3(1, 1, 1), "★★ 迷雾层 UV 与地面层一致（不翻转）")
	eq(g._fog_mat.uv1_offset, Vector3(0, 0, 0), "★★ 迷雾层 UV 不偏移")
	eq(g._fog_mat.uv1_scale, g._mat.uv1_scale,
		"★★ 两层（地面 / 迷雾）的 UV 变换**逐位相同** —— 差一点迷雾边界就会与地块错开")

	ok(GroundRes.PX_PER_TILE >= 16,
		"★ 地面贴图 ≥ 16 像素/格（实测 %d；一格约 30 屏幕像素 ⇒ 放大 ≤ 2 倍）"
		% GroundRes.PX_PER_TILE)
	eq(g._mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_LINEAR,
		"★ 地面层用 LINEAR（**不带 mipmap**）—— 地面永远是放大的，mip 只会把它糊掉")
	ok(GroundRes.FOG_PX_PER_TILE >= 4,
		"★ 迷雾贴图 ≥ 4 像素/格（实测 %d；1 像素/格时迷雾边界是一格一格的方块）"
		% GroundRes.FOG_PX_PER_TILE)

	var fog_tex_size: Vector2i = Vector2i(g._fog_tex.get_size())
	eq(fog_tex_size, Vector2i(int(w.map.cols) * GroundRes.FOG_PX_PER_TILE,
		int(w.map.rows) * GroundRes.FOG_PX_PER_TILE),
		"★ 迷雾贴图 = 格数 × FOG_PX_PER_TILE（分辨率提上去，边界不再是方块）")
	var cols_i: int = int(w.map.cols)
	var rows_i: int = int(w.map.rows)
	var gsegs: Array = game.overlay._grid_segs_for(cols_i, rows_i)
	eq(gsegs.size(), (cols_i + 1 + rows_i + 1) * 2,
		"★ 网格线顶点数 = (竖线 %d + 横线 %d) × 2" % [cols_i + 1, rows_i + 1])
	ok(gsegs.size() > 0, "★ 网格线真的有顶点（空数组 = 一条都没画）")
	ok((gsegs[0] as Vector2) == Vector2(0.0, 0.0),
		"★ 网格线缓存的是格坐标（首点 = 地图左上角）")
	var gsegs_again: Array = game.overlay._grid_segs_for(cols_i, rows_i)
	ok(gsegs_again == gsegs, "★ 网格线几何被缓存（同一尺寸不重建）")
	game.overlay._zone_seg_sig = ""        # 强制重算一次几何
	game.overlay._count_zone_outlines()
	ok(game.overlay._zone_segs.size() > 0,
		"★ 区划轮廓几何建出来了（%d 块有边界）" % game.overlay._zone_segs.size())
	var outline_seg_total := 0
	for entry in game.overlay._zone_segs:
		outline_seg_total += (entry["segs"] as Array).size() / 2
	ok(outline_seg_total > 0, "★ 轮廓线段总数 > 0（实测 %d 条）" % outline_seg_total)
	var border_tiles := 0
	for ty in rows_i:
		for tx in cols_i:
			if g.zone_edge_mask(tx, ty) != 0:
				border_tiles += 1
	ok(border_tiles > 0 and border_tiles < cols_i * rows_i,
		"★ 只有**边界格**产生轮廓（%d 格有边界 < 全图 %d 格）" % [border_tiles, cols_i * rows_i])
	if w.zones != null and w.zones.zones.size() > 0:
		var z1: Dictionary = w.zones.zones[0]
		var owner_before := String(z1.get("owner", ""))
		# ★★ 本轮起区划颜色是「敌 / 友 / 己」三色（见 view/side_color.gd）——
		#    所以这里必须翻到**不同的一方**才看得出变化（两个敌对阵营收到的红是同一个色）。
		var self_fid := String(w.my_faction)
		var enemy_fid := "enemy" if self_fid != "enemy" else "p2"
		z1["owner"] = self_fid
		var col_a: Color = g.zone_outline_color(z1)
		z1["owner"] = enemy_fid
		var col_b: Color = g.zone_outline_color(z1)
		ok(col_a != col_b,
			"★ 归属一变（己方 → 敌方）、轮廓颜色跟着变（%s → %s）" % [str(col_a), str(col_b)])
		# ★ 内容有没有真的变：比**烘图缓冲**的字节快照。
		#   缓冲复用之后 `_tex` 是同一个对象，`get_image()` 也不一定跟着刷新
		#   （旧写法其实是在比「有没有新建一个贴图对象」，不是比内容）。
		#   ★ 本轮起颜色只有「己/友/敌」三档 ⇒ 两次快照必须取在**不同的一方**上。
		z1["owner"] = self_fid
		g.rebake(true)
		var data_a: PackedByteArray = g._bake_img.get_data().duplicate()
		z1["owner"] = enemy_fid
		g.rebake(true)
		var data_b: PackedByteArray = g._bake_img.get_data().duplicate()
		ok(not data_a.is_empty() and not data_b.is_empty() and data_a != data_b,
			"★ 归属一变、地面底色跟着重烘（贴图内容不同）")
		z1["owner"] = owner_before
		game.overlay._zone_seg_sig = ""
		g.rebake(true)

	# ★★ 2026.10.29：占领进度条的多边形三角化保护。
	ok(game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(0, 10)])),
		"★ 正常三角形可以交给 draw_colored_polygon")
	ok(not game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(0, 0), Vector2(5, 5), Vector2(10, 10)])),
		"★★ 共线三角形被挡掉（triangulation failed 的一种）")
	ok(not game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(0, 0), Vector2(0, 0), Vector2(10, 10)])),
		"★★ 重合点被挡掉")
	ok(not game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(NAN, 0), Vector2(10, 0), Vector2(0, 10)])),
		"★★ NaN 顶点被挡掉")
	ok(not game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(INF, 0), Vector2(10, 0), Vector2(0, 10)])),
		"★★ INF 顶点被挡掉")
	ok(not game.overlay._valid_screen_triangle(
			PackedVector2Array([Vector2(0, 0), Vector2(1.0e7, 0), Vector2(0, 10)])),
		"★★ 坐标爆掉的三角形被挡掉")

	eq(game.overlay._count_zone_captures(), 0, "★ 没有区划在占领时，进度条一块都不画")
	var zc = null
	if w.zones != null and w.zones.zones.size() > 0:
		for zz2 in w.zones.zones:
			if zc == null or int((zz2 as Dictionary).get("tile_count", 0)) \
					> int((zc as Dictionary).get("tile_count", 0)):
				zc = zz2
	if zc != null:
		var cells0: Array = (zc as Dictionary).get("tiles", [])
		var row_lo: int = _capture_min_row(zc)
		var row_hi: int = _capture_max_row(zc)
		ok(cells0.size() > 1 and row_hi > row_lo,
			"★ 选中用来量进度的区划有 %d 格、跨 %d 行（≥2 行才量得出「升起」）"
			% [cells0.size(), row_hi - row_lo + 1])
		if not cells0.is_empty():
			zc["capture_state"] = "reading"
			zc["capture_faction"] = "p1"
			zc["progress"] = 0.25
			var n_low: int = game.overlay._count_zone_captures()
			ok(n_low > 0, "★ 有区划在读条时进度条真的画了（%d 块）" % n_low)
			zc["progress"] = 0.75
			var n_high: int = game.overlay._count_zone_captures()
			print("[CASE] （诊断）进度条：0.25 画 %d 块 → 0.75 画 %d 块（区划共 %d 格）" % [
				n_low, n_high, cells0.size()])
			ok(n_high > n_low,
				"★★ 进度 0.25 → 0.75 时填充**往上长**（画的块数 %d → %d）" % [n_low, n_high])
			ok(n_high <= cells0.size(),
				"★ 填充不超过这个区划的地块数（%d ≤ %d）" % [n_high, cells0.size()])
			zc["progress"] = 0.0
			eq(game.overlay._count_zone_captures(), 0,
				"★ 进度归零（或已易主）后进度条重新不画")
			zc["capture_state"] = ""
			zc["capture_faction"] = ""

	game.queue_free()
	await process_frame

static func _capture_top_row(img: Image) -> int:
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				return y
	return -1

static func _capture_ink(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				n += 1
	return n

static func _capture_bottom_row(img: Image) -> int:
	for y in range(img.get_height() - 1, -1, -1):
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				return y
	return -1

static func _capture_min_row(z) -> int:
	var mn := 1 << 20
	for t in (z as Dictionary).get("tiles", []):
		mn = mini(mn, (t as Vector2i).y)
	return mn

static func _capture_max_row(z) -> int:
	var mx := -(1 << 20)
	for t in (z as Dictionary).get("tiles", []):
		mx = maxi(mx, (t as Vector2i).y)
	return mx

func _test_hud_and_minimap(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，后面的 HUD 断言无从谈起")
		game.queue_free()
		return
	await process_frame
	await process_frame

	ok(game.hud != null, "★ HUD 挂进了 3D 场景（CanvasLayer，不吃 3D 变换）")
	if game.hud == null:
		game.queue_free()
		return
	var mm = game.hud.minimap
	ok(mm != null, "★ HUD 里有小地图")
	if mm == null:
		game.queue_free()
		return
	ok(mm.palette != null, "★★ 小地图拿到了 3D 投影助手（否则视野框会停在错位置）")

	var r1: Rect2 = mm.view_rect_world()
	ok(r1.size.x > 0.0 and r1.size.y > 0.0,
		"★ 视野框有面积（%.1f × %.1f）" % [r1.size.x, r1.size.y])
	var cell: float = cfg.cell_px
	var map_w: float = float(game.world.map.cols) * cell
	var map_h: float = float(game.world.map.rows) * cell
	ok(r1.position.x < map_w and r1.position.y < map_h and r1.end.x > 0.0 and r1.end.y > 0.0,
		"★ 视野框与地图有交集（位置 %s，地图 %s）" % [str(r1.position), str(Vector2(map_w, map_h))])

	var before: Rect2 = mm.view_rect_world()
	game.center_on_tile(Vector2(float(game.world.map.cols) - 3.0,
		float(game.world.map.rows) - 3.0))
	await process_frame
	var after: Rect2 = mm.view_rect_world()
	ok(before.position.distance_to(after.position) > 1.0,
		"★★ 相机移动后视野框跟着动（%s → %s）" % [str(before.position), str(after.position)])

	game.center_on_tile(Vector2(2.0, 2.0))
	await process_frame
	var mid_tile := Vector2(float(game.world.map.cols) * 0.5, float(game.world.map.rows) * 0.5)
	mm._jump_to(mm.to_minimap(mid_tile))
	game.cam.force_update_transform()
	var look: Vector2 = game.palette.world_to_logic(game._ground_under_screen(game._view_center()))
	near(look.distance_to(mid_tile), 0.0, 0.05,
		"★ 小地图跳到地图中心：落点 %s ≈ %s" % [str(look), str(mid_tile)])

	game.queue_free()
	await process_frame

func _test_camera_aim(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，对准断言无从谈起")
		game.queue_free()
		return
	await process_frame
	await process_frame
	game._edge_scroll_on = false
	game.set_process(false)

	var cols: float = float(game.world.map.cols)
	var rows: float = float(game.world.map.rows)
	var targets: Array = [
		Vector2(13.5, 11.0), Vector2(13.5, 2.0), Vector2(3.5, 3.5),
		Vector2(24.0, 19.0), Vector2(0.5, 0.5),
		Vector2(cols - 0.5, rows - 0.5),
	]
	# ① `_place_camera_looking_at` 是**不夹取**的原始摆位：任何格都必须精确落到画面中心
	var worst_place := 0.0
	for t: Vector2 in targets:
		game._place_camera_looking_at(game.palette.to_world(t))
		game.cam.force_update_transform()
		worst_place = maxf(worst_place, t.distance_to(_aim_readback(game)))
	ok(worst_place < 0.05,
		"★ `_place_camera_looking_at` 把目标点摆到画面中心（最大误差 %.4f 格 < 0.05）" % worst_place)

	# ② ★★ 相机夹取的口径（2026.10.20 用户口径）：**镜头中心可以到达地图矩形内任意一点**，
	#    包括四个角 —— 左右能一直推到「地图的左 / 右边界落在屏幕正中间」。
	#    ★ 旧口径是「可见区域越出地图 ≤ margin 格」，最远视野下角根本到不了屏幕中心；
	#      现在只夹「中心在不在图内」（见 game_scene3d.clamp_look_point）。
	#    ★ 目标点里特意放一个地图外的 (-40,-40)：夹取必须把它拉回来。
	var worst_in := -INF
	var worst_reach := 0.0
	for z: float in [Game3DRes.ZOOM_MIN, 0.2, Game3DRes.ZOOM_MAX]:
		game.zoom = z
		for t4: Vector2 in [Vector2(0.0, 0.0), Vector2(cols, 0.0),
				Vector2(0.0, rows), Vector2(cols, rows),
				Vector2(cols * 0.5, rows * 0.5), Vector2(-40.0, -40.0)]:
			game.center_on_tile_precise(t4)
			game.cam.force_update_transform()
			var look: Vector2 = _aim_readback(game)
			worst_in = maxf(worst_in, maxf(-look.x, look.x - cols))
			worst_in = maxf(worst_in, maxf(-look.y, look.y - rows))
			var want := Vector2(clampf(t4.x, 0.0, cols), clampf(t4.y, 0.0, rows))
			worst_reach = maxf(worst_reach, want.distance_to(look))
	ok(worst_in <= 0.05,
		"★★ 镜头中心始终留在地图矩形内（最大越界 %.2f 格）" % worst_in)
	ok(worst_reach < 0.05,
		"★★ 四个角都能被对准（最大误差 %.3f 格）—— 旧口径最远视野下差 8 格" % worst_reach)
	# ★ 用户口径的**直接**验证：最远视野下把中心推到地图左 / 右边界，边界必须落在屏幕正中。
	game.zoom = Game3DRes.ZOOM_MAX
	var vp_size: Vector2 = game.get_viewport().get_visible_rect().size
	game.center_on_tile_precise(Vector2(0.0, rows * 0.5))
	game.cam.force_update_transform()
	var edge_left: Vector2 = game.palette.to_px(Vector2(0.0, rows * 0.5))
	ok(absf(edge_left.x - vp_size.x * 0.5) < 2.0,
		"★★ 地图左边界能停在屏幕正中（偏 %.1f px）" % (edge_left.x - vp_size.x * 0.5))
	game.center_on_tile_precise(Vector2(cols, rows * 0.5))
	game.cam.force_update_transform()
	var edge_right: Vector2 = game.palette.to_px(Vector2(cols, rows * 0.5))
	ok(absf(edge_right.x - vp_size.x * 0.5) < 2.0,
		"★★ 地图右边界也能停在屏幕正中（偏 %.1f px）" % (edge_right.x - vp_size.x * 0.5))
	game.zoom = Game3DRes.ZOOM_MAX

	# ③ 两个「对准」入口都会**经过夹取** ⇒ 先在最近视野下量**精度**：
	#    ★ 目标都在地图内，夹取不会挪动它们（新口径下最远视野也一样可达）。
	game.zoom = Game3DRes.ZOOM_MIN
	var worst_precise := 0.0
	for t: Vector2 in targets:
		game.center_on_tile_precise(t)
		game.cam.force_update_transform()
		worst_precise = maxf(worst_precise, t.distance_to(_aim_readback(game)))
	ok(worst_precise < 0.05,
		"★★ `center_on_tile_precise` 对准某格（最大误差 %.4f 格 < 0.05）" % worst_precise)

	# ④ `center_on_screen_precise` 走的是「屏幕点 → 格 → 对准」这条路 ⇒ 在最远视野下
	#    它与 `center_on_tile_precise` 对**同一个目标点**必须落在同一处（含被夹取到
	#    区间边界的那些角）—— 量的是这条路的换算，夹取已经被 ② 量过，不再重量一遍。
	#    ⚠️ 必须在最远视野下测：最近视野里相机贴着地图中心，南边的角会跑到**相机背后**，
	#       而「点在相机背后」时 `to_px` 给的是不可用的坐标（引擎口径）。
	game.zoom = Game3DRes.ZOOM_MAX
	var worst_screen := 0.0
	for t: Vector2 in targets:
		game.center_on_tile_precise(t)
		game.cam.force_update_transform()
		var want: Vector2 = _aim_readback(game)
		game.center_on_tile(Vector2(cols * 0.5, rows * 0.5))
		game.cam.force_update_transform()
		game.center_on_screen_precise(game.palette.to_px(t))
		game.cam.force_update_transform()
		worst_screen = maxf(worst_screen, want.distance_to(_aim_readback(game)))
	ok(worst_screen < 0.05,
		"★★ `center_on_screen_precise` 与 `center_on_tile_precise` 同一落点（最大差 %.4f 格 < 0.05）" % worst_screen)

	var mm = game.hud.minimap
	if mm == null:
		ok(false, "小地图不在，跳转断言无从谈起")
		game.queue_free()
		return
	# ★ 同样在最近视野下量「点哪去哪」：那一档的夹取 = 旧的「中心留在地图矩形内」，
	#   角落附近那几个目标点才可达 —— 在最远视野下它们会被夹取挪开（那是需求，不是 bug）。
	game.zoom = Game3DRes.ZOOM_MIN
	var worst_jump := 0.0
	for t2: Vector2 in [Vector2(4.5, 16.5), Vector2(1.5, 1.5), Vector2(25.5, 20.5)]:
		mm._jump_to(mm.to_minimap(t2))
		game.cam.force_update_transform()
		worst_jump = maxf(worst_jump, t2.distance_to(_aim_readback(game)))
	ok(worst_jump < 0.05,
		"★★ 小地图「点哪去哪」：落点误差 %.4f 格 < 0.05（老写法实测最大 15.06 格）" % worst_jump)
	game.zoom = Game3DRes.ZOOM_MAX

	var fake := Vector2(13.5, 11.0)
	game.center_on_screen_precise(game.cfg.cell_px * fake)
	game.cam.force_update_transform()
	print("[CASE] （对照）老写法把 %s 的世界像素当屏幕像素 ⇒ 落点 %s，误差 %.3f 格" % [
		str(fake), str(_aim_readback(game)), fake.distance_to(_aim_readback(game))])

	game.queue_free()
	await process_frame

func _aim_readback(game) -> Vector2:
	return game.palette.world_to_logic(game._ground_under_screen(game._view_center()))

func _test_order_flags(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	await process_frame
	await process_frame
	var w = game.world
	var of = game.order_flags
	ok(of != null, "★ 3D 场景建了指令旗视图（order_flags）")
	if of == null:
		game.queue_free()
		return
	var u = null
	for x in w.units:
		if x.alive:
			u = x
			break
	if u == null:
		ok(false, "找不到单位来验旗子")
		game.queue_free()
		return
	game.set_process(false)

	var cell: float = cfg.cell_px
	var fall_h: float = cell * cfg.num("render.order_flag_fall_height", 0.15)
	var fall_sec: float = maxf(0.001, cfg.num("render.order_flag_fall_sec", 0.22))
	var impact_sec: float = maxf(0.001, cfg.num("render.order_flag_impact_sec", 0.55))
	var fade_sec: float = maxf(0.001, cfg.num("render.order_flag_fade_sec", 1.0))
	var icon_in: float = maxf(0.001, cfg.num("render.order_flag_icon_fade_in_sec", 0.6))
	var color_sec: float = maxf(0.001, cfg.num("render.order_flag_attack_color_sec", 0.6))
	var move_c: Color = ConfigRes.parse_color(cfg.str_val("render.flag_move_color", "#4cd964"))
	var attack_c: Color = ConfigRes.parse_color(cfg.str_val("render.flag_attack_color", "#e6c200"))

	# ---- 移动：离地一点点生成 → 下落 → 落地 ----
	of.plant("move", u.pos)
	ok(of.active and of.phase == "fall", "★ 移动命令插旗（下落阶段）")
	ok(of.fall_offset_last > 0.0 and of.fall_offset_last < cell * 0.3,
		"★ 旗帜只在落点上方一点点生成（%.1f 世界单位，< 0.3 格）" % of.fall_offset_last)
	near(of.fall_offset_last, fall_h, 0.001, "★ 生成高度来自 config（%.2f 格）" % cfg.num("render.order_flag_fall_height", 0.15))
	var y0: float = of.fall_offset_last
	of.sync(fall_sec * 0.5)
	ok(of.fall_offset_last < y0 and of.fall_offset_last > 0.0,
		"★ 旗帜正在下落（%.1f → %.1f）" % [y0, of.fall_offset_last])
	ok(not of.icon_visible_last, "★ 移动命令没有红色交叉图标")
	ok(of.cloth_color_last.is_equal_approx(move_c), "★ 移动命令旗色是绿色")

	of.sync(fall_sec * 0.5)
	eq(of.phase, "settle", "★ 落地后进入压缩/渐隐阶段")
	ok(of.ripple_alpha_last > 0.0, "★ 落地点生成波纹")
	var r0: float = of.ripple_radius_last
	var a0: float = of.ripple_alpha_last
	# ★ 回弹现在只有 0.08s（与下落合计 0.2s）⇒ 取样点必须按 impact_sec 的比例走，
	#   不能再写死 0.05s（0.05/0.08 已经进回弹段，断言「压缩」会假红）。
	of.sync(impact_sec * 0.15)
	ok(of.ripple_radius_last > r0, "★ 波纹向外扩散")
	ok(of.ripple_alpha_last < a0, "★ 波纹同时渐隐")
	ok(of.scale_y_last < 1.0, "★ 落地后旗帜先压缩（%.3f）" % of.scale_y_last)

	of.sync(impact_sec * 0.35)
	ok(of.scale_y_last > 1.0, "★ 压缩后回弹过冲（%.3f）" % of.scale_y_last)
	of.sync(impact_sec * 0.6)
	near(of.scale_y_last, 1.0, 0.001, "★ 回弹后复位到 100%")
	ok(of.alpha_last < 1.0, "★ 落地后开始渐隐")
	of.sync(fade_sec + 0.1)
	ok(not of.active, "★ 渐隐结束自动收旗")
	ok(not of.icon_visible_last, "★ 动画结束后图标也收起")

	# ---- 行军：不重播插下动画，只做变黄 + 红图标渐入 + 黄色波纹；图标完全出现后才渐隐 ----
	of.plant("attack_move", u.pos)
	eq(of.phase, "settle", "★ 行军命令直接出现在落点（不再播放下落）")
	near(of.fall_offset_last, 0.0, 1e-6, "★ 行军旗帜不从上方落下")
	near(of.scale_y_last, 1.0, 1e-6, "★ 行军旗帜不做压缩/回弹")
	ok(of.ripple_alpha_last > 0.0, "★ 行军命令立刻出现波纹")
	ok(of.ripple_color_last.is_equal_approx(attack_c),
		"★ 行军波纹是黄色（不是绿旗色）")
	ok(not of.icon_visible_last and of.icon_alpha_last == 0.0,
		"★ 行军图标从透明开始渐入")
	ok(of.icon_y_last > cell * 0.5, "★ 图标在杆顶正上方")
	# 先在「颜色渐变中段 / 图标渐入中段」取一个两边都还没到终点的时刻
	var t_mid: float = minf(color_sec, icon_in) * 0.5
	of.sync(t_mid)
	ok(of.icon_visible_last and of.icon_alpha_last > 0.0 and of.icon_alpha_last < 1.0,
		"★ 行军图标正在渐入（%.3f）" % of.icon_alpha_last)
	ok(of.cloth_color_last.r > move_c.r + 0.05 and of.cloth_color_last.b < move_c.b - 0.05,
		"★ 行军旗色由绿向黄渐变")
	ok(absf(of.alpha_last - 1.0) < 1e-6,
		"★ 图标没完全出现前旗帜保持不透明")
	near(of.scale_y_last, 1.0, 1e-6, "★ 行军全程不做压缩/回弹（%.3f）" % of.scale_y_last)
	of.sync(maxf(0.0, icon_in - of.elapsed_last))
	near(of.icon_alpha_last, 1.0, 0.001, "★ 图标完全出现")
	ok(absf(of.alpha_last - 1.0) < 1e-6, "★ 图标刚完全出现时旗帜还没开始渐隐")
	# 渐变与渐入时长可能不同：再推进到两者都完成的时刻
	of.sync(maxf(0.0, maxf(color_sec, icon_in) - of.elapsed_last))
	ok(of.cloth_color_last.is_equal_approx(attack_c), "★ 旗色已渐变到黄色")
	var fade_start: float = icon_in
	of.sync(maxf(0.0, fade_start + 0.05 - of.elapsed_last))
	ok(of.alpha_last < 1.0, "★ 图标完全出现之后旗帜才开始渐隐")
	ok(of.icon_alpha_last < 1.0, "★ 图标与旗帜一起渐出")
	of.sync(fade_sec + 0.1)
	ok(not of.active, "★ 行军插旗动效走完也自动收旗")

	# ---- 新规则：部队是否到达 / 停下不再决定收旗 ----
	of.plant("move", u.pos)
	u.moving = false
	u.has_attack_move = false
	of.sync(0.0)
	ok(of.active, "★ 部队停下不再立即收旗（动效自己走完）")
	of.clear()
	ok(not of.active, "★ clear() 立即收旗")

	# ---- 替换：每道新命令只留最新一面 ----
	var planted_before: int = of.flags_planted
	of.plant("move", u.pos)
	of.plant("attack_move", u.pos)
	eq(of.flags_planted, planted_before + 2, "★ 新命令替换旧旗（诊断计数 +2）")
	ok(of.active and of.kind == "attack_move", "★ 当前旗子是最新的行军命令")
	of.clear()

	# ---- 程序化图标 / 波纹贴图 ----
	var tex: ImageTexture = OrderFlagRes.icon_texture(0.05)
	ok(tex != null and tex.get_image() != null, "★ 红色交叉图标（程序化矢量）烘得出来")
	if tex != null and tex.get_image() != null:
		var img: Image = tex.get_image()
		var n: int = img.get_width()
		ok(_count_opaque(img) > 1000,
			"★ 图标有实体像素（不透明 %d）" % _count_opaque(img))
		ok(img.get_pixel(n / 2, n / 2).a > 0.5, "★ 图标中心是两个长对角线的交叉点")
		ok(img.get_pixel(n / 2, n / 8).a < 0.1, "★ 图标顶部中央是空的（X 形，不是方块）")
		ok(img.get_pixel(int(n * 0.135), int(n * 0.815)).a > 0.5,
			"★ 左下那条短斜线画出来了")
		ok(img.get_pixel(int(n * 0.865), int(n * 0.815)).a > 0.5,
			"★ 右下那条短斜线画出来了")
	var rt: ImageTexture = OrderFlagRes.ripple_texture()
	ok(rt != null and _count_opaque(rt.get_image()) > 100,
		"★ 落地波纹（程序化圆环）烘得出来")

	ok(of.flags_planted >= 5, "★ 至少插过 5 次旗（诊断 %d）" % of.flags_planted)

	game.queue_free()
	await process_frame

func _test_selection_ring(cfg) -> void:
	var rt: ImageTexture = SpriteRes.selection_ring_texture()
	ok(rt != null and rt.get_image() != null, "★ 选中下标（空心圆）贴图烘得出来")
	if rt != null and rt.get_image() != null:
		var im: Image = rt.get_image()
		var nn := im.get_width()
		ok(_count_opaque(im) > 30, "★ 圆环有实质像素（不透明 %d）" % _count_opaque(im))
		ok(im.get_pixel(nn / 2, nn / 2).a < 0.1, "★ 圆环中心是**空的**（空心圆）")

	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
	await process_frame
	await process_frame
	var w = game.world
	game.set_process(false)
	var u = null
	for x in w.units:
		if x.alive and game.units._visible_to_me(x):
			u = x
			break
	if u == null:
		ok(false, "找不到可见单位验选中下标")
		game.queue_free()
		return

	game.units.set_selection([])
	for _i in 60:
		game.units.sync(1.0 / 60.0)
	eq(game.units.selection_ring_count, 0, "（前提）全部收起后没有下标")

	game.units.set_selection([u.id])
	game.units.sync(0.05)
	eq(game.units.selection_ring_count, 1, "★ 选中后脚下一枚空心圆出现")
	var s0: float = game.units.selection_scale_last
	var a0: float = game.units.selection_alpha_last
	ok(s0 > 1.0 and s0 < game.units._sel_scale_from,
		"★ 动效起步：尺寸在 100%%~150%% 之间（%.3f）" % s0)
	ok(a0 > 0.0 and a0 < cfg.num("render.selection_ring_alpha", 0.8),
		"★ 动效起步：不透明度在 0~80%% 之间（%.3f）" % a0)
	game.units.sync(0.05)
	var s1: float = game.units.selection_scale_last
	var a1: float = game.units.selection_alpha_last
	ok(s1 < s0, "★ 动效：尺寸由大到小（%.3f → %.3f）" % [s0, s1])
	ok(a1 > a0, "★ 动效：不透明度渐显（%.3f → %.3f）" % [a0, a1])

	for _i2 in 30:
		game.units.sync(1.0 / 60.0)
	near(game.units.selection_scale_last, 1.0, 0.001,
		"★ 终态尺寸 = 100%（与将领底面贴花同大小）")
	near(game.units.selection_alpha_last, cfg.num("render.selection_ring_alpha", 0.8), 0.01,
		"★ 终态不透明度 = 80%")

	game.units.set_selection([])
	game.units.sync(1.0 / 60.0)
	eq(game.units.selection_ring_count, 1, "★ 取消选中的第一帧还在反向播")
	ok(game.units.selection_scale_last > 1.0,
		"★ 反向：尺寸开始回涨（%.3f）" % game.units.selection_scale_last)
	ok(game.units.selection_alpha_last < cfg.num("render.selection_ring_alpha", 0.8),
		"★ 反向：不透明度开始回落（%.3f）" % game.units.selection_alpha_last)
	for _i3 in 30:
		game.units.sync(1.0 / 60.0)
	eq(game.units.selection_ring_count, 0, "★ 反向收完、下标消失")

	game.queue_free()
	await process_frame

func _test_grid_near_clip(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，裁剪断言无从谈起")
		game.queue_free()
		return
	await process_frame
	await process_frame
	game.set_process(false)
	var ov = game.overlay
	var cols: int = int(game.world.map.cols)
	var rows: int = int(game.world.map.rows)

	game.zoom = 0.1
	game.center_on_tile(Vector2(float(cols) * 0.5, float(rows) * 0.5))
	game.cam.force_update_transform()
	var behind := 0
	for x in range(0, cols + 1):
		for yy: float in [0.0, float(rows)]:
			var wp := Vector3(float(x) * cfg.cell_px, 0.0, yy * cfg.cell_px)
			if game.cam.is_position_behind(wp):
				behind += 1
	ok(behind > 0, "（前提）近视角下确有 %d 个网格局点在相机后方" % behind)

	ok(rows > 14, "（前提）地图够高（%d 行），近端才会越到相机后方" % rows)
	var pair: PackedVector2Array = ov._project_segments([Vector2(13.0, 0.0), Vector2(13.0, float(rows))])
	eq(pair.size(), 2, "★ 跨相机平面的竖线仍投出 2 个点（保留可见段、丢掉不可见段）")
	if pair.size() == 2:
		ok(pair[0].y < 0.0, "★ 远端（地图上缘）在屏幕上方（y=%.0f）" % pair[0].y)
		ok(pair[1].y > 0.0, "★★ 近端被裁后投在屏幕**下方**（y=%.0f；修前是镜像到上方的 −17191）"
			% pair[1].y)
		ok(not is_nan(pair[0].x) and not is_nan(pair[1].x), "★ 裁出来的点不是 NaN")

	var near_row: PackedVector2Array = ov._project_segments(
		[Vector2(0.0, float(rows)), Vector2(float(cols), float(rows))])
	ok(near_row.is_empty(), "★ 整段在相机后方的线被丢掉（不画）")

	game.zoom = 0.3
	game.center_on_tile(Vector2(float(cols) * 0.5, float(rows) * 0.5))
	game.cam.force_update_transform()
	var all_pts: PackedVector2Array = ov._project_segments(ov._grid_segs_for(cols, rows))
	eq(all_pts.size(), (cols + 1 + rows + 1) * 2,
		"★ 远视角下网格线一条都不裁（%d 个端点）" % all_pts.size())

	game.queue_free()
	await process_frame

func _test_capture_area(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，占领触发区断言无从谈起")
		game.queue_free()
		return
	await process_frame
	await process_frame
	game.set_process(false)
	var ov = game.overlay

	eq(ov._capture_area_color(""), Overlay3DRes.CAPTURE_AREA_NEUTRAL,
		"★ 中立区块的触发区描边 = 白灰")
	eq(ov._capture_area_color("p1"), SideColorRes.color(cfg, game.world, "p1"),
		"★ 己方区块的描边 = 本机视角的「己方」色（蓝；本轮统一配色）")
	eq(ov._capture_area_color("p2"), cfg.side_color_enemy,
		"★ 敌方区块的描边 = 红（默认图里 p2 与 p1 不同方）")
	ok(ov._capture_area_color("p1") != ov._capture_area_color(""),
		"中立与有主的颜色不同（需求要的「随势力变色」）")

	var with_center := 0
	for z in game.world.zones.zones:
		if (z as Dictionary).get("center", null) != null:
			with_center += 1
	eq(with_center, game.world.zones.zones.size(),
		"★ 每个区块都有中心（没有的由 zone._ensure_centers() 装配时补）")
	ok(with_center > 1, "有中心的区块不止一个（否则下面的剔除断言没意义）")

	var z0: Dictionary = game.world.zones.zones[0]
	var c0: Vector2i = z0["center"]
	game.zoom = Game3DRes.ZOOM_MAX
	game.center_on_tile(Vector2(c0) + Vector2(0.5, 0.5))
	game.cam.force_update_transform()
	var on_center: int = ov._visible_capture_areas().size()
	ok(on_center >= 1 and on_center <= with_center,
		"★ 只画屏幕内的触发区（对准某中心时 %d 块 ≤ 有中心的 %d 块）" % [on_center, with_center])

	game.zoom = Game3DRes.ZOOM_MIN
	game.center_on_tile(Vector2(0.5, 0.5))
	game.cam.force_update_transform()
	var zoomed: int = ov._visible_capture_areas().size()
	ok(zoomed < with_center,
		"★★ 拉近到最紧 + 贴角 → 屏幕外的触发区被剔除（%d < %d）" % [zoomed, with_center])
	game.zoom = Game3DRes.ZOOM_MAX

	# ★★ 静态层缓存（本轮手机端优化）：相机不动 ⇒ 一次投影都不该重做。
	#   ⚠️ 无头下 Control 的 `_draw()` 不会跑，所以直接调缓存重建入口。
	game.cam.force_update_transform()
	ov._refresh_static_projection()
	var rebuilds: int = ov.static_rebuild_count
	ov._refresh_static_projection()
	eq(ov.static_rebuild_count, rebuilds,
		"★★ 相机静止时静态层缓存不重建（%d 次）" % rebuilds)
	game.center_on_tile(Vector2(float(game.world.map.cols) * 0.5,
		float(game.world.map.rows) * 0.5))
	game.cam.force_update_transform()
	ov._refresh_static_projection()
	ok(ov.static_rebuild_count > rebuilds,
		"★ 相机移动后静态层缓存重建（%d → %d）" % [rebuilds, ov.static_rebuild_count])
	ok(not ov._grid_screen.is_empty(), "静态层缓存里有网格线顶点")
	ok(not ov._zone_screen.is_empty(), "静态层缓存里有区划轮廓顶点")

	game.queue_free()
	await process_frame


## ★★ 粮车光环范围：只在选中时画、按地面投影、半径来自逻辑字段。
func _test_aura_range(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		ok(false, "3D 场景起不来，光环范围断言无从谈起")
		game.queue_free()
		return
	await process_frame
	await process_frame
	game.set_process(false)
	var ov = game.overlay
	var w = game.world
	var g = null
	for u in w.units:
		if u.alive and u.is_general() and String(u.faction) == String(w.my_faction):
			g = u
			break
	ok(g != null, "（前提）找得到一位己方将领")
	if g == null:
		game.queue_free()
		await process_frame
		return

	var cart = UnitRes.create(cfg, "aura-ring-cart", "粮车",
		Vector2i(g.tx, g.ty), String(w.my_faction), UnitRes.UNIT_TYPE_GRAIN_CART,
		"", String(g.id), UnitRes.UNIT_TYPE_GRAIN_CART, -1)
	cart.pos = g.pos + Vector2(1.0, 0.0)
	w.units.append(cart)
	game.cam.force_update_transform()

	ov.set_selection([])
	eq(ov._aura_range_loops().size(), 0, "★ 没选中粮车 → 不画光环范围")
	ov.set_selection([g.id])
	eq(ov._aura_range_loops().size(), 0, "★ 选中别的单位 → 不画粮车范围")

	ov.set_selection([cart.id])
	var loops: Array = ov._aura_range_loops()
	eq(loops.size(), 1, "★ 选中粮车 → 画一圈范围")
	if loops.is_empty():
		game.queue_free()
		await process_frame
		return
	var loop: Dictionary = loops[0]
	near(float(loop["radius"]), 3.0, 1e-6, "半径来自粮车的 morale_aura_radius = 3 格")
	var pts: PackedVector2Array = loop["points"]
	eq(pts.size(), Overlay3DRes.AURA_RANGE_SEGMENTS + 1, "★ 圆周采样 + 闭合点")
	if pts.size() >= 2:
		v2_near(pts[0], pts[pts.size() - 1], 0.01, "★ 首尾闭合（画出来是一整圈）")
	# 任取一个采样角：它必须是**地面点的投影**，不是屏幕空间的正圆。
	var idx := 7
	var ang: float = TAU * float(idx) / float(Overlay3DRes.AURA_RANGE_SEGMENTS)
	var expected: Vector2 = ov.palette.to_px(
		cart.pos + Vector2(cos(ang), sin(ang)) * float(loop["radius"]))
	v2_near(pts[idx], expected, 0.01, "★ 每个采样点都走地面投影（贴地椭圆）")
	near((loop["color"] as Color).a, Overlay3DRes.AURA_RANGE_ALPHA, 1e-6,
		"细线带固定透明度")

	ov.set_selection([cart.id, g.id])
	eq(ov._aura_range_loops().size(), 1, "★ 多选时每辆粮车各一圈（别的单位不多画）")

	game.queue_free()
	await process_frame
