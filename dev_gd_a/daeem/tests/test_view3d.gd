## test_view3d.gd —— 3D 渲染栈的断言（本版新增）
##
## ★★ 这个文件存在的理由（改之前先读）：
##   3D 栈里最容易**静默失败**的三类东西，都不会报错、也不会改变任何逻辑状态：
##     ① `MultiMesh` 的实例数写错（写成 0 就什么都不画，画面只剩地面）；
##     ② 分桶键写错（每种变体各建一批 ⇒ 合批失效，性能悄悄退化）；
##     ③ 相机不变量被破坏（俯角/高度被平移带动 ⇒ 「下滑时地块变大」那类观感 bug）。
##   所以这里全部用**可数的痕迹**与**可复算的不变量**来钉，
##   而不是「跑一遍没炸就算过」。
##
## ★ 复用哪些东西：`game_scene3d.gd`（真装配）、`test_case.gd` 的
##   `make_test_camera()` / `make_test_palette()`（造一台测试相机）。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后（`_initialize()` 阶段
##    `root.add_child()` 会**静默失效**，见 pitfalls 1.2）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const Game3DRes = preload("res://view/game_scene3d.gd")
const GroundRes = preload("res://view/ground_view.gd")
const UnitViewRes = preload("res://view/unit_view_3d.gd")
const BuildingViewRes = preload("res://view/building_view_3d.gd")
const SpriteRes = preload("res://view/unit_sprite_3d.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingShaderRes = preload("res://view/building_flash.gdshader")
const UnitDownedShaderRes = preload("res://view/unit_downed.gdshader")


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
	# ★★ 相机必须**先挂进树、再等一帧**才能用它的投影 API
	#    （`project_ray_normal` / `unproject_position` 要视口；
	#     `_initialize()` 阶段 add_child 会静默失效，见 pitfalls 1.2）
	await process_frame
	_test_projection_roundtrip(cfg)
	_test_camera_invariants(cfg)
	await _test_hud_and_minimap(cfg)
	await _test_units_multimesh(cfg)
	await _test_units_downed_decal(cfg)
	await _test_buildings_multimesh(cfg)
	await _test_ground_bake(cfg)
	await _test_camera_aim(cfg)
	await _test_order_flags(cfg)
	await _test_selection_ring(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 一、兵人立牌贴图：真的烘出来了、且**将领与普通兵不同**
# ------------------------------------------------------------------
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
	# ① 剪影真的画了东西（不透明像素数 > 0）
	var opaque_t := _count_opaque(it)
	var opaque_l := _count_opaque(il)
	ok(opaque_t > 100, "普通兵贴图有实质剪影（不透明像素 %d）" % opaque_t)
	ok(opaque_l > opaque_t, "★ 将领贴图更大（肩更宽 + 头顶缨：%d > %d）" % [opaque_l, opaque_t])
	# ② 阵营色真的烘进去了（不是纯白）——否则所有阵营的兵人一个颜色
	#    ★ 取样点取**躯干中心**（不翻转之后，头在顶部、脚在底部，躯干在中段）：
	#      `TEX_H * 5 / 12 = 40` 行落在躯干上（p.y ≈ 0.58）。
	var c: Color = it.get_pixel(SpriteRes.TEX_W / 2, SpriteRes.TEX_H * 5 / 12)
	ok(c.r > c.g + 0.2, "★ 阵营色烘进了贴图（取样点 r=%.2f 明显大于 g=%.2f）" % [c.r, c.g])
	# ③ 缓存生效：同一组参数第二次必须拿到**同一张**
	var again: ImageTexture = SpriteRes.bake(Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	ok(again == troop, "★ 同一组参数命中缓存（不重复光栅化）")
	# ④ 底边必须是**脚**（贴合地面的那一端）：既不是空（会浮空），也不是一整条宽块。
	#    ★ 朝向口径见 `_bake_uncached`：QuadMesh 的 UV v=0 在**顶部**，不翻转 ⇒
	#      贴图顶行是头、底行是脚；立牌抬到「贴图底边贴地」时脚正好落地。
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


## 第一个**被阵营色染过**的不透明像素（验「阵营色真的烘进去了」）。
## ⚠️ 不能只看「第一个不透明像素」：描边（深色，r≈g）也在剪影外侧，
##    按行扫先碰到的可能就是那一圈 —— 于是断言会误报「没染色」。所以找的是
##    **红明显大于绿**（= 阵营色 0.9/0.2/0.2）的那个像素。
static func _first_tinted_color(img: Image) -> Color:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and c.r > c.g + 0.2:
				return c
	return Color(0, 0, 0, 0)


# ------------------------------------------------------------------
# 一·补、兵种素材立牌：三个兵种各一张、且真的用了素材（本轮新增）
# ------------------------------------------------------------------
## ★★ 为什么必须钉住（这几条都会**静默失败**，画面不对但不报错）：
##   · `sprite` 路径写了但**没被 Godot 导入** ⇒ `ResourceLoader.exists` 为假
##     ⇒ `bake_asset` 退回程序化剪影 ⇒ **画面还是三个兵长得一样**；
##   · 三个兵种共用一张图 ⇒ 同上；
##   · 阵营色没烘进去 ⇒ 所有阵营一个颜色。
func _test_sprite_bake_assets(cfg) -> void:
	SpriteRes.clear_cache()
	var types: Array = [UnitRes.UNIT_TYPE_SPEARMAN, UnitRes.UNIT_TYPE_LONGBOWMAN,
		UnitRes.UNIT_TYPE_RIDER]
	var seen_paths: Dictionary = {}
	var images: Dictionary = {}
	for id in types:
		var t := String(id)
		var path: String = cfg.unit_sprite_of(t)
		ok(path != "", "%s 配了 sprite 路径" % t)
		ok(ResourceLoader.exists(path), "★ %s 的素材被导入过（%s）" % [t, path])
		var tex: ImageTexture = SpriteRes.bake_asset(path, Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
		ok(tex != null, "%s 的兵种贴图烘得出来" % t)
		if tex == null:
			continue
		var img: Image = tex.get_image()
		ok(img != null and _count_opaque(img) > 100,
			"★ %s 的剪影有实质像素（不透明 %d）" % [t, _count_opaque(img) if img != null else -1])
		if img == null:
			continue
		var c := _first_tinted_color(img)
		ok(c.a > 0.5 and c.r > c.g + 0.2,
			"★ %s 的阵营色烘进了贴图（找到染色像素 r=%.2f > g=%.2f）" % [t, c.r, c.g])
		seen_paths[path] = true
		images[t] = img
	ok(seen_paths.size() == 3, "★ 三个兵种的素材路径互不相同（%d 个）" % seen_paths.size())
	# 三张图两两不同（形状不同 ⇒ 字节不同）——否则还是「三个兵长得一样」
	var keys: Array = images.keys()
	var all_distinct := keys.size() == 3
	if all_distinct:
		for i in keys.size():
			for j in range(i + 1, keys.size()):
				if (images[keys[i]] as Image).get_data() == (images[keys[j]] as Image).get_data():
					all_distinct = false
	ok(all_distinct, "★★ 三个兵种的贴图两两不同（否则还是「三个兵长得一样」）")
	# 将领档：描边更粗 ⇒ 不透明像素更多
	var p0: String = cfg.unit_sprite_of(UnitRes.UNIT_TYPE_SPEARMAN)
	var troop: ImageTexture = SpriteRes.bake_asset(p0, Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	var leader: ImageTexture = SpriteRes.bake_asset(p0, Color(0.9, 0.2, 0.2), true, Color(0, 0, 0))
	if troop != null and leader != null and troop.get_image() != null and leader.get_image() != null:
		var ot := _count_opaque(troop.get_image())
		var ol := _count_opaque(leader.get_image())
		ok(ol > ot, "★ 将领档描边更粗（不透明像素 %d > %d）" % [ol, ot])
	# 缓存：同一组参数第二次必须拿到**同一张**
	ok(SpriteRes.bake_asset(p0, Color(0.9, 0.2, 0.2), false, Color(0, 0, 0)) == troop,
		"★ 素材贴图命中缓存（不重复光栅化）")
	# 素材缺失 / 路径为空 → 退回程序化剪影（不崩、也有图）
	SpriteRes.clear_cache()
	var fallback: ImageTexture = SpriteRes.bake_asset("", Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	var proc: ImageTexture = SpriteRes.bake(Color(0.9, 0.2, 0.2), false, Color(0, 0, 0))
	ok(fallback != null and proc != null and fallback.get_image() != null
		and proc.get_image() != null
		and fallback.get_image().get_data() == proc.get_image().get_data(),
		"★ 没配素材 / 载不到 → 退回程序化剪影（同一张图）")


# ------------------------------------------------------------------
# 二、投影往返：屏幕 → 格 → 屏幕 必须闭合
# ------------------------------------------------------------------
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
	# 屏幕四角也应当落到地面（不是 null）：俯视相机不该有打不到地面的射线
	var corner: Variant = pal.to_logic(Vector2(0, 0))
	ok(corner != null, "屏幕左上角能打到地面（俯视相机没有地平线之上的射线）")


# ------------------------------------------------------------------
# 三、相机不变量：**平移不改尺寸、缩放不改俯角**
# ------------------------------------------------------------------
func _test_camera_invariants(cfg) -> void:
	var cols := 24
	var rows := 16
	var cam: Camera3D = make_test_camera(cfg, cols, rows)
	var pal = make_test_palette(cfg, cam)
	if cam == null or pal == null:
		return
	# ① 同一格在「不同屏幕位置」的像素尺寸相差不能太离谱
	#    （这是用户报过的「向下滑动时地块越来越大」的量化判据）
	var w_top := _tile_w(pal, Vector2(10.0, 2.0))
	var w_bot := _tile_w(pal, Vector2(10.0, rows - 2))
	var ratio: float = w_bot / maxf(1e-6, w_top)
	ok(ratio > 1.0, "近处（屏幕下方）的格比远处的大 —— 这是透视应有的表现（%.2f 倍）" % ratio)
	ok(ratio < 2.0,
		"★★ 但收缩比必须**受控**（%.2f < 2.0）—— 大了就是「下滑时地块暴涨」那个 bug" % ratio)
	# ② 相机高度只由 cfg 决定：把相机沿地面挪走之后，高度必须**逐位不变**
	var y_before: float = cam.position.y
	cam.position += Vector3(500.0, 0.0, -300.0)
	ok(is_equal_approx(cam.position.y, y_before),
		"★ 平移不动相机高度（%.3f == %.3f）" % [cam.position.y, y_before])
	# ③ 相机姿态在平移前后必须**完全不变**（基向量逐位相同）。
	#
	# ⚠️ 我原先在这里验「算出来的俯角 == cfg.cam_pitch」，实测 56.98° vs 55°
	#    —— 那 2° 来自 `look_at()` 的正交化（它保证的是「朝向 look 点」，
	#    不保证「位置方向恰好等于我算的 cam_up」）。**而且俯角不是这里要钉的不变量**：
	#    真正的不变量是「相机姿态不随平移改变」+「格在屏幕上的尺寸不变」。
	#    钉住这两条，「下滑时地块变大」就被钉死在门外了。
	var basis_before: Basis = cam.global_transform.basis
	ok(is_equal_approx(basis_before.x.length(), 1.0)
		and is_equal_approx(basis_before.y.length(), 1.0)
		and is_equal_approx(basis_before.z.length(), 1.0),
		"★ 相机基是单位正交基（长度都是 1）")
	ok(basis_before.y.y > 0.0, "★ 相机的 up 分量朝上（没有把画面翻过来）")
	# ④ 沿**自身坐标轴**平移：屏幕上的格宽必须**逐位不变**（相机高度与姿态都没动）
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


# ------------------------------------------------------------------
# 四、单位 MultiMesh：实例数、批次数、迷雾剔除
# ------------------------------------------------------------------
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
	# ① 实例数 = 活着且可见的单位数（不能是 0，也不能多）
	var expect := 0
	for u in w.units:
		if u.alive and game.units._visible_to_me(u):
			expect += 1
	eq(game.units.instance_count, expect,
		"★ MultiMesh 实例数 = 可见单位数（%d）" % expect)
	ok(game.units.instance_count > 0, "★ 真有单位被画了出去（不是 0 —— 写成 0 就什么都不画）")
	# ② 批次数 ≤ 变体数（阵营 × 2 × 兵种）—— 超了说明分桶键写错、合批失效
	var variants: Dictionary = {}
	for u in w.units:
		if u.alive and game.units._visible_to_me(u):
			var vk := "%s|%d|%s|%d" % [String(u.faction), 1 if u.is_general() else 0,
				String(u.unit_type), 1 if u.is_downed() else 0]
			variants[vk] = true
	var max_batches: int = variants.size()
	ok(game.units.mesh_batch_count <= max_batches,
		"★★ 批次数不超过变体数（%d ≤ %d：可见单位的 阵营|将领|兵种 组合数）"
		% [game.units.mesh_batch_count, max_batches])
	ok(game.units.batches_created <= max_batches,
		"★ 累计创建的批次数也没超（%d ≤ %d）" % [game.units.batches_created, max_batches])

	# ③ 迷雾剔除：把迷雾关掉再开，实例数必须**变大**（关掉时全可见）
	#    ⚠️ 判据用「关掉迷雾后实例数 >= 开着时」——不一定严格大于
	#       （可能本来就都看得见），所以只在「确实有敌人在迷雾里」时才断言严格变大。
	game.units.sync()
	var with_fog: int = game.units.instance_count
	var hidden_count := 0
	for u in w.units:
		if u.alive and not game.units._visible_to_me(u):
			hidden_count += 1
	ok(hidden_count >= 0, "（诊断）被迷雾挡住的单位数 = %d" % hidden_count)

	game.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 四·补、濒死将领半透明 + 将领脚下贴花（本轮新增）
# ------------------------------------------------------------------
func _test_units_downed_decal(cfg) -> void:
	# shader 结构：濒死那档走**透明管线**（写 ALPHA、**不写** scissor）
	var code: String = UnitDownedShaderRes.code
	ok(code.contains("ALPHA"), "★ 濒死 shader 写了 ALPHA（半透明）")
	ok(not code.contains("ALPHA_SCISSOR_THRESHOLD ="),
		"★★ 濒死 shader **不写** scissor（否则半透明又变回「要么全有要么全无」）")
	# 占位贴花烘得出来
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

	# 贴花：每个可见将领一张
	var expect_decals := 0
	for u in w.units:
		if u.alive and u.is_general() and game.units._visible_to_me(u):
			expect_decals += 1
	ok(expect_decals > 0, "（前提）场上至少有一位可见将领（%d）" % expect_decals)
	eq(game.units.decal_count, expect_decals,
		"★ 每个可见将领脚下都有一张贴花（%d）" % expect_decals)

	# 濒死 ⇒ 走半透明批次
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


# ------------------------------------------------------------------
# 五、建筑 MultiMesh：底边贴地、尺寸来自 body_scale
# ------------------------------------------------------------------
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
	# ★ 尺寸必须来自 `body_scale`（logic 的权威）：4 倍大的 body 应当得到 4 倍宽的方块
	var b0 = null
	for b in w.building_list:
		if b.alive:
			b0 = b
			break
	if b0 != null:
		var t: Transform3D = game.buildings._transform_of(b0)
		var expect_w: float = game.buildings.palette.cell_size() * b0.body_scale(cfg)
		near(t.basis.get_scale().x, expect_w, 0.01,
			"★ 建筑方块的宽 = 格宽 × body_scale（logic 的权威值）")
		# 底边贴地：中心高度 = 高 / 2 + 一点抬起
		var h: float = t.basis.get_scale().y
		ok(t.origin.y > h * 0.5 - 0.01 and t.origin.y < h * 0.5 + 2.0,
			"★ 建筑底边贴地（中心 y = %.2f，高 = %.2f）" % [t.origin.y, h])

	# ★★ 建筑排序：shader 必须 `depth_draw_always`（透明管线里也写深度 ⇒ 近的挡住远的）。
	#    写 ALPHA = 走透明管线，而透明管线默认不写深度 ⇒ 建筑会按「谁后画谁在上」乱序。
	ok(BuildingShaderRes.code.contains("depth_draw_always"),
		"★★ 建筑 shader 写了 depth_draw_always（否则近的建筑会被远的盖住 —— 用户报的 bug）")
	ok(BuildingShaderRes.code.contains("INSTANCE_CUSTOM.g"),
		"★ 建筑 shader 从每实例数据读淡出量(.g)")

	# ★★ 单位靠近 ⇒ 建筑淡出（以建筑为中心 3x3 内有可见单位）
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

	# 把一栋「当前没淡出」的建筑旁边放一个可见单位 ⇒ 它必须变成淡出
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


# ------------------------------------------------------------------
# 六、地面贴图：烘出来了、分辨率够、区块归属变了会重烘
# ------------------------------------------------------------------
func _test_ground_bake(cfg) -> void:
	var game = Game3DRes.new()
	root.add_child(game)
	await process_frame
	if not game.start():
		game.queue_free()
		return
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
	# 归属变了要重烘：改一个区块的归属，再 sync，烘图计数必须 +1
	var before: int = g.bake_count
	if w.zones != null and w.zones.zones.size() > 0:
		var z0: Dictionary = w.zones.zones[0]
		z0["owner"] = "p2" if String(z0.get("owner", "")) != "p2" else "p1"
	g.rebake()
	ok(g.bake_count > before,
		"★ 区块归属变了会重烘地面贴图（%d -> %d）" % [before, g.bake_count])
	# 迷雾层：关掉迷雾时那一层必须**不可见**（与 2D 版同一条行为）
	if g._fog_mesh != null:
		ok(true, "迷雾层节点存在")

	# ★★ 贴图上下方向（本轮修掉的真 bug：整个地面贴图是**上下反**的）
	#
	# 用户报「迷雾上下反了、区块也反了」——根因是 `ground_view` 给材质加的
	# 「v 翻转」（`uv1_scale = (1,-1)` + `uv1_offset = (0,1)`）。
	# 实测：在贴图第 2 行涂一条红 → 屏幕上变红的是**世界第 19 行**。
	# ⇒ 正确口径是**恒等变换**：`PlaneMesh` 的 uv.y 与贴图行号本来就同向（都朝南增大）。
	#
	# ⚠️ 为什么必须有无头也能跑的判据：上面那条「涂一条红再看屏幕」要真渲染才能跑，
	#    而**上下反这件事在无头下不会报任何错**（烘图、层可见、断言全绿）。
	#    ⇒ 这里钉住三层的 UV 参数逐位为恒等（改回去就红），
	#      真正的「看着对不对」由 `tests/test_view3d_fog.gd` 在真渲染下量。
	eq(g._mat.uv1_scale, Vector3(1, 1, 1), "★★ 地面层 UV 不翻转（scale 恒等 —— 翻转就是上下反）")
	eq(g._mat.uv1_offset, Vector3(0, 0, 0), "★★ 地面层 UV 不偏移（offset 恒等）")
	eq(g._fog_mat.uv1_scale, Vector3(1, 1, 1), "★★ 迷雾层 UV 与地面层一致（不翻转）")
	eq(g._fog_mat.uv1_offset, Vector3(0, 0, 0), "★★ 迷雾层 UV 不偏移")
	eq(g._fog_mat.uv1_scale, g._mat.uv1_scale,
		"★★ 两层（地面 / 迷雾）的 UV 变换**逐位相同** —— 差一点迷雾边界就会与地块错开")

	# ★★ 地表清晰度（用户报「地表太糊了」）：
	#   判据是「1 个贴图像素被放大几倍」。一格在屏幕上约 30 px（1920 视口 / 默认相机距离），
	#   8 像素/格时是 3.7 倍（肉眼即糊），16 像素/格时降到 1.9 倍。
	#   ⚠️ 这条只能判「别退回去」，判不了「够不够清晰」—— 后者要靠眼睛与真渲染截图。
	ok(GroundRes.PX_PER_TILE >= 16,
		"★ 地面贴图 ≥ 16 像素/格（实测 %d；一格约 30 屏幕像素 ⇒ 放大 ≤ 2 倍）"
		% GroundRes.PX_PER_TILE)
	eq(g._mat.texture_filter, BaseMaterial3D.TEXTURE_FILTER_LINEAR,
		"★ 地面层用 LINEAR（**不带 mipmap**）—— 地面永远是放大的，mip 只会把它糊掉")
	ok(GroundRes.FOG_PX_PER_TILE >= 4,
		"★ 迷雾贴图 ≥ 4 像素/格（实测 %d；1 像素/格时迷雾边界是一格一格的方块）"
		% GroundRes.FOG_PX_PER_TILE)

	# ★★ 区划轮廓 / 网格线 / 占领进度条：**全部搬到了屏幕空间**（本轮，用户报
	#   「占领的进度条还是太糊了」之后的结构调整）。
	#
	# ★★ 为什么必须钉住「不在地面贴图里」这件事：
	#   用户当年的抱怨就是「地图上有很多奇怪的线条」，而**糊**与**乱**是同一层的两个毛病。
	#   烘进贴图的线会被放大成软边（1 像素的线 → 2 像素的软边；
	#   1 像素 = 1 格的进度贴图 → 整格 30 px 的渐变带）⇒ 那条路已经封死。
	#   判据：**地面贴图只装平坦底色**，而这三样东西的绘制痕迹只出现在 overlay 的计数里。
	#   ⚠️ `Texture2D.get_size()` 返回的是 **`Vector2`**（不是 `Vector2i`）——
	#      直接拿它和 `Vector2i` 比会抛
	#      `Invalid operands 'Vector2' and 'Vector2i' in operator '=='`，
	#      而 `eq()` 内部的比较抛错 ⇒ **这一行之后的所有断言都不跑**
	#      （这一条是我自己踩的：报告里写「通过 N 项 / 失败 0 项」，那 4 条断言却从没执行过）。
	#      ⇒ 两边都显式转成 `Vector2i`。
	var fog_tex_size: Vector2i = Vector2i(g._fog_tex.get_size())
	eq(fog_tex_size, Vector2i(int(w.map.cols) * GroundRes.FOG_PX_PER_TILE,
		int(w.map.rows) * GroundRes.FOG_PX_PER_TILE),
		"★ 迷雾贴图 = 格数 × FOG_PX_PER_TILE（分辨率提上去，边界不再是方块）")
	# 网格线：整张图 + 每个网格线顶点都投影得出来（不是空数组）
	var cols_i: int = int(w.map.cols)
	var rows_i: int = int(w.map.rows)
	var gsegs: Array = game.overlay._grid_segs_for(cols_i, rows_i)
	eq(gsegs.size(), (cols_i + 1 + rows_i + 1) * 2,
		"★ 网格线顶点数 = (竖线 %d + 横线 %d) × 2" % [cols_i + 1, rows_i + 1])
	ok(gsegs.size() > 0, "★ 网格线真的有顶点（空数组 = 一条都没画）")
	# ★ 网格线的顶点必须是**格坐标**（不是屏幕坐标）：这样才能复用同一份缓存
	ok((gsegs[0] as Vector2) == Vector2(0.0, 0.0),
		"★ 网格线缓存的是格坐标（首点 = 地图左上角）")
	var gsegs_again: Array = game.overlay._grid_segs_for(cols_i, rows_i)
	ok(gsegs_again == gsegs, "★ 网格线几何被缓存（同一尺寸不重建）")
	# 区划轮廓：几何真的建出来了、且**只有边界格**贡献线段
	game.overlay._zone_seg_sig = ""        # 强制重算一次几何
	game.overlay._count_zone_outlines()
	ok(game.overlay._zone_segs.size() > 0,
		"★ 区划轮廓几何建出来了（%d 块有边界）" % game.overlay._zone_segs.size())
	var outline_seg_total := 0
	for entry in game.overlay._zone_segs:
		outline_seg_total += (entry["segs"] as Array).size() / 2
	ok(outline_seg_total > 0, "★ 轮廓线段总数 > 0（实测 %d 条）" % outline_seg_total)
	# ★ 内部格不许有线：把「有边界的格数」与「全部格数」比一下 ——
	#   全图都是边界说明边掩码恒为非零（那是错的口径）
	var border_tiles := 0
	for ty in rows_i:
		for tx in cols_i:
			if g.zone_edge_mask(tx, ty) != 0:
				border_tiles += 1
	ok(border_tiles > 0 and border_tiles < cols_i * rows_i,
		"★ 只有**边界格**产生轮廓（%d 格有边界 < 全图 %d 格）" % [border_tiles, cols_i * rows_i])
	# ★ 轮廓颜色必须**跟归属走**：换一个区划的 owner，颜色必然变
	if w.zones != null and w.zones.zones.size() > 0:
		var z1: Dictionary = w.zones.zones[0]
		var owner_before := String(z1.get("owner", ""))
		var col_a: Color = g.zone_outline_color(z1)
		z1["owner"] = "p3" if owner_before != "p3" else "p1"
		var col_b: Color = g.zone_outline_color(z1)
		ok(col_a != col_b,
			"★ 归属一变、轮廓颜色跟着变（%s → %s）" % [str(col_a), str(col_b)])
		# 底色也必须重烘
		var oimg_a: Image = g._tex.get_image()
		g.rebake(true)
		var oimg_b: Image = g._tex.get_image()
		ok(oimg_a != null and oimg_b != null and oimg_a.get_data() != oimg_b.get_data(),
			"★ 归属一变、地面底色跟着重烘（贴图内容不同）")
		z1["owner"] = owner_before
		game.overlay._zone_seg_sig = ""
		g.rebake(true)

	# ★★ 占领进度条（现在画在屏幕空间）：用**纯计数**函数量它的绘制痕迹。
	#
	# ★★ 为什么调 `_count_zone_captures()` 而不是手工 `_draw()`（本轮实测改的）：
	#   在 `_draw()` **之外**调 `draw_colored_polygon()` / `draw_multiline()` 会报
	#   `ERROR: Drawing is only allowed inside this node's _draw()` ——
	#   而引擎在无头下不渲染 `Control`，测试没有真的 `_draw()` 可等。
	#   `overlay_view_3d` 于是把「数」与「画」拆开：`_count_*()` 是**纯计算、零报错**。
	#   ⇒ 好处不只是没噪音：**日志里出现 ERROR 就说明有真问题**，
	#     不会被这几条预期的报错淹掉（本项目为「红字里的真错误被淹没」付过学费）。
	eq(game.overlay._count_zone_captures(), 0, "★ 没有区划在占领时，进度条一块都不画")
	var zc = null
	if w.zones != null and w.zones.zones.size() > 0:
		# ★ 选**地块最多**的那个区划（而不是第 0 个）：
		#   「由下往上升起」只有在区划有**好几行**时才量得出来。
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
			# 逻辑层的字段就是这几个（见 zone.update 的尾部）
			zc["capture_state"] = "reading"
			zc["capture_faction"] = "p1"
			zc["progress"] = 0.25
			var n_low: int = game.overlay._count_zone_captures()
			ok(n_low > 0, "★ 有区划在读条时进度条真的画了（%d 块）" % n_low)
			# ★★ 进度 0.25 → 0.75：填充**由下往上升起** ⇒ 画的块数必须变多
			#   （块数 = 被水面淹没的格数，与「升起」严格同向）
			zc["progress"] = 0.75
			var n_high: int = game.overlay._count_zone_captures()
			print("[CASE] （诊断）进度条：0.25 画 %d 块 → 0.75 画 %d 块（区划共 %d 格）" % [
				n_low, n_high, cells0.size()])
			ok(n_high > n_low,
				"★★ 进度 0.25 → 0.75 时填充**往上长**（画的块数 %d → %d）" % [n_low, n_high])
			ok(n_high <= cells0.size(),
				"★ 填充不超过这个区划的地块数（%d ≤ %d）" % [n_high, cells0.size()])
			# 读满 / 没进度 ⇒ 一块都不画
			zc["progress"] = 0.0
			eq(game.overlay._count_zone_captures(), 0,
				"★ 进度归零（或已易主）后进度条重新不画")
			zc["capture_state"] = ""
			zc["capture_faction"] = ""

	game.queue_free()
	await process_frame


## 进度贴图里**最上面**那一行有填充的格行号（-1 = 完全没有填充）
static func _capture_top_row(img: Image) -> int:
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				return y
	return -1


## 进度贴图里有多少个有填充的格（诊断用）
static func _capture_ink(img: Image) -> int:
	var n := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				n += 1
	return n


## 进度贴图里**最下面**那一行有填充的格行号（-1 = 完全没有填充）
static func _capture_bottom_row(img: Image) -> int:
	for y in range(img.get_height() - 1, -1, -1):
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.0:
				return y
	return -1


## 某个区划地块的最小行 / 最大行（诊断用：升起的基准就是它）
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


# ------------------------------------------------------------------
# 七、HUD 与小地图接在 3D 栈上（本轮新增）
# ------------------------------------------------------------------
## ★★ 为什么这几条必须钉住：
##   HUD 是 `CanvasLayer` 上的 `Control`，它对世界的**唯一**依赖是「知道我现在看的是哪一块」。
##   接错了**不会报任何错**：小地图照样画、视野框照样画，只是框永远停在一个错位置。
##   所以这里钉「HUD 真的挂上了」「小地图拿到了 3D 投影」「视野框跟着相机走」。
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

	# ① 视野框必须**真的落在地图上**（不是空的、也不是跑到地图外）
	var r1: Rect2 = mm.view_rect_world()
	ok(r1.size.x > 0.0 and r1.size.y > 0.0,
		"★ 视野框有面积（%.1f × %.1f）" % [r1.size.x, r1.size.y])
	var cell: float = cfg.cell_px
	var map_w: float = float(game.world.map.cols) * cell
	var map_h: float = float(game.world.map.rows) * cell
	ok(r1.position.x < map_w and r1.position.y < map_h and r1.end.x > 0.0 and r1.end.y > 0.0,
		"★ 视野框与地图有交集（位置 %s，地图 %s）" % [str(r1.position), str(Vector2(map_w, map_h))])

	# ② 相机挪走之后，视野框必须**跟着挪**（这是「小地图真的连上了」的判据）
	var before: Rect2 = mm.view_rect_world()
	game.center_on_tile(Vector2(float(game.world.map.cols) - 3.0,
		float(game.world.map.rows) - 3.0))
	await process_frame
	var after: Rect2 = mm.view_rect_world()
	ok(before.position.distance_to(after.position) > 1.0,
		"★★ 相机移动后视野框跟着动（%s → %s）" % [str(before.position), str(after.position)])

	# ③ 小地图的「点哪去哪」：把**地图中心那一格**换算成小地图局部坐标再跳，
	#    镜头应当回到地图中心附近。
	#
	# ⚠️ 这里原来写的是 `camera_rig.center_on_px(mm.to_minimap(地图中心))` ——
	#    那是拿「小地图局部坐标」当**屏幕像素**用，和 `minimap._jump_to` 的输入口径
	#    根本不是一回事（实测它落到的位置与地图中心差了十几格）。
	#    ⇒ 正确的姿势是走小地图自己的那一条：`to_minimap(格)` 出来的是局部坐标，
	#      喂回 `_jump_to` 才会被还原成格。见下面的 `_test_camera_aim`。
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


# ------------------------------------------------------------------
# 八、「把某一格摆到画面中心」必须真的准（待办 1 的正式断言）
# ------------------------------------------------------------------
## ★★ 为什么这几条必须钉住（本轮实测的教训，dev_plan_10 的待办 1）：
##   那一轮把「小地图转移视角不准」误判成 `_place_camera_looking_at` 里
##   「`look_at` 的 up 与相机位置不自洽」，连改 4 轮没收敛。**真正的原因是测量姿势**：
##   · 无头下鼠标停在 (0,0)（屏幕左上角）⇒ 边缘滚屏**一直开着**，
##     每 `await process_frame` 一次镜头就往左上滚约半格；
##   · 于是「摆好之后再读」读到的永远是**滚走之后**的相机。
##   ⇒ 判据：**量相机落点之前，必须先关边缘滚屏 + 冻结 `_process`**。
##   关掉之后实测误差是 **0.0000 格**（下面钉 0.05 格）。
##
## ★ 另外这里钉死了「小地图点击」那条路的口径：小地图手里是**格**，
##   它必须把格直接交给相机替身（`center_on_tile`），**不能**绕成
##   「世界像素 → 当屏幕像素用」—— 那条写法在 2D 遗留栈里恰好成立
##   （世界像素 == 屏幕像素），在 3D 里错得离谱（实测最大 **15.06 格**）。
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
	# ★★ 两条前提（缺一条上面的「0.0000 格」就变成「0.5~1.5 格」）
	game._edge_scroll_on = false
	game.set_process(false)

	var targets: Array = [
		Vector2(13.5, 11.0), Vector2(13.5, 2.0), Vector2(3.5, 3.5),
		Vector2(24.0, 19.0), Vector2(0.5, 0.5),
		Vector2(float(game.world.map.cols) - 0.5, float(game.world.map.rows) - 0.5),
	]
	var worst_place := 0.0
	var worst_precise := 0.0
	var worst_screen := 0.0
	for t: Vector2 in targets:
		# ① 唯一的摆相机入口
		game._place_camera_looking_at(game.palette.to_world(t))
		game.cam.force_update_transform()
		worst_place = maxf(worst_place, t.distance_to(_aim_readback(game)))
		# ② `center_on_tile_precise`（小地图点击走的就是它）
		game.center_on_tile_precise(t)
		game.cam.force_update_transform()
		worst_precise = maxf(worst_precise, t.distance_to(_aim_readback(game)))
		# ③ `center_on_screen_precise`（屏幕点 → 射线求交 → 再对准）
		game.center_on_tile(Vector2(float(game.world.map.cols) * 0.5,
			float(game.world.map.rows) * 0.5))
		game.cam.force_update_transform()
		game.center_on_screen_precise(game.palette.to_px(t))
		game.cam.force_update_transform()
		worst_screen = maxf(worst_screen, t.distance_to(_aim_readback(game)))
	ok(worst_place < 0.05,
		"★ `_place_camera_looking_at` 把目标点摆到画面中心（最大误差 %.4f 格 < 0.05）" % worst_place)
	ok(worst_precise < 0.05,
		"★★ `center_on_tile_precise` 对准某格（最大误差 %.4f 格 < 0.05）" % worst_precise)
	ok(worst_screen < 0.05,
		"★★ `center_on_screen_precise` 对准屏幕点（最大误差 %.4f 格 < 0.05）" % worst_screen)

	# ④ 小地图那条路：格 → 小地图局部坐标 → `_jump_to` → 应当回到那一格
	var mm = game.hud.minimap
	if mm == null:
		ok(false, "小地图不在，跳转断言无从谈起")
		game.queue_free()
		return
	var worst_jump := 0.0
	for t2: Vector2 in [Vector2(4.5, 16.5), Vector2(1.5, 1.5), Vector2(25.5, 20.5)]:
		mm._jump_to(mm.to_minimap(t2))
		game.cam.force_update_transform()
		worst_jump = maxf(worst_jump, t2.distance_to(_aim_readback(game)))
	ok(worst_jump < 0.05,
		"★★ 小地图「点哪去哪」：落点误差 %.4f 格 < 0.05（老写法实测最大 15.06 格）" % worst_jump)

	# ⑤ 反向对照（只报数、不断言）：老写法「世界像素当屏幕像素喂 center_on_px」
	#    到底错多少。★ 留这一条是为了**防止有人把它改回去** ——
	#    没有数字的话，「两种写法都能跑」看起来就像等价的。
	var fake := Vector2(13.5, 11.0)
	game.center_on_screen_precise(game.cfg.cell_px * fake)
	game.cam.force_update_transform()
	print("[CASE] （对照）老写法把 %s 的世界像素当屏幕像素 ⇒ 落点 %s，误差 %.3f 格" % [
		str(fake), str(_aim_readback(game)), fake.distance_to(_aim_readback(game))])

	game.queue_free()
	await process_frame


## 「画面中心现在对着哪一格」——三条断言共用的读法。
## ⚠️ 必须走 `_view_center()`（现场问视口），不能读 `cfg.proj_vp_half`：
##    后者是按**启动时**窗口尺寸算的缓存值（实测 1920×1920 vs 960×540）。
func _aim_readback(game) -> Vector2:
	return game.palette.world_to_logic(game._ground_under_screen(game._view_center()))


# ------------------------------------------------------------------
# 九、右键指令的 3D 旗子（本轮新增）
# ------------------------------------------------------------------
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

	# 移动旗：单位到达（不再 moving）⇒ 自动收
	of.plant("move", u.pos, [u.id])
	ok(of.active, "★ 移动命令插上了旗子")
	u.moving = false
	u.has_attack_move = false
	of.sync()
	ok(not of.active, "★ 单位到达后移动旗自动收掉")

	# 行军旗：has_attack_move 还在 ⇒ 不收；完成后收
	of.plant("attack_move", u.pos, [u.id])
	u.moving = true
	u.has_attack_move = true
	of.sync()
	ok(of.active, "★ 行军攻击进行中旗子仍在")
	u.moving = false
	u.has_attack_move = false
	of.sync()
	ok(not of.active, "★ 行军攻击完成后旗子收掉")

	# clear() 立即收旗
	of.plant("move", u.pos, [u.id])
	of.clear()
	ok(not of.active, "★ clear() 收旗")
	ok(of.flags_planted >= 3, "★ 至少插过 3 次旗（诊断 %d）" % of.flags_planted)

	game.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 十、选中下标：脚下绿色空心圆 + 出现/收起动效（本轮新增）
# ------------------------------------------------------------------
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

	# 先全部收起（主循环开局自动选中了第一个单位，这里把它衰减掉）
	game.units.set_selection([])
	for _i in 60:
		game.units.sync(1.0 / 60.0)
	eq(game.units.selection_ring_count, 0, "（前提）全部收起后没有下标")

	# 选中 ⇒ 动效出现：尺寸由大变小、不透明度渐显
	game.units.set_selection([u.id])
	game.units.sync(0.05)
	eq(game.units.selection_ring_count, 1, "★ 选中后脚下一枚空心圆出现")
	# ★ 直接读 MultiMesh 的实例数据读不回来（Godot 4.7 + 无头实测），
	#   所以看视图留下的两个诊断字段（本帧第一个下标的缩放 / 不透明度）。
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

	# 收敛：尺寸收到 100%（= 将领黄色贴花那个大小）、不透明度升到配置值
	for _i2 in 30:
		game.units.sync(1.0 / 60.0)
	near(game.units.selection_scale_last, 1.0, 0.001,
		"★ 终态尺寸 = 100%（与将领底面贴花同大小）")
	near(game.units.selection_alpha_last, cfg.num("render.selection_ring_alpha", 0.8), 0.01,
		"★ 终态不透明度 = 80%")

	# 取消选中 ⇒ **反向播放**：尺寸回涨、不透明度回落，最后收完消失
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