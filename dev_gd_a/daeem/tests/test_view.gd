## test_view.gd —— 渲染层冒烟测试（M1 + M3/M4 的「接线对不对」那部分）
##
## 为什么值得测：真正的接线 bug（脚本访问了逻辑对象上不存在的属性、HUD 的
## Theme 字体拿不到、节点树装配顺序错）在无头模式下会打成 SCRIPT ERROR ——
## 而那类错误如果不测，第一次发现就是「打开游戏画面不对」。
## ★ 实测抓到过：view 往逻辑单位上写 `selected`，而 logic/unit.gd 里当时没有这个字段。
##
## 这个文件**不测观感**（那是手玩验收的事），只测：
##   - 逻辑坐标 ↔ 像素换算（HTML 版为它吃过一次大亏）
##   - 主场景真的能挂上树、节点树齐了
##   - 跑若干帧 + 注入点击/键盘之后，世界与渲染都不炸
##   - 中文字体能加载（否则 HUD 全是方框）
##
## ⚠️ 挂节点必须在 `await process_frame` 之后 —— `_initialize()` 阶段
##    `root.add_child()` 会**静默失效**（is_inside_tree() 仍是 false，见 pitfalls 1.2）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
## ★★ 两套 palette 各司其职（见 `view/palette2d.gd` 的文件头）：
##   · `PaletteRes`（3D 实例类）：**投影**类断言走它 —— 用 `make_test_palette()`
##     造一个实例，方法是 `pal.tile_poly(tx, ty)`（**不再收 cfg**）；
##   · `Palette2DRes`（2D 遗留换算）：只有「2D 里本来就成立」的那几条走它
##     （建筑本体的矩形 / 外接框这类与透视无关的几何）。
const PaletteRes = preload("res://view/palette.gd")
const Palette2DRes = preload("res://view/palette2d.gd")
const FontLoaderRes = preload("res://view/font_loader.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_view"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return

	# ★★ 关键：先等一帧，root.add_child() 才会真的生效
	#    （`_initialize()` 阶段挂节点会**静默失效**，见 pitfalls 1.2）。
	#
	# ⚠️⚠️ 这一帧**必须在投影类断言之前**（本轮踩到）：`view/palette.gd` 现在是
	#    **实例类**，`to_px` 走的是真实的 `Camera3D.unproject_position()` ——
	#    而相机**没进树就没有视口**，那时 unproject 一律返回 (0,0)（实测），
	#    于是「近大远小」「地块是梯形」「正逆互逆」会一起报 0.0 / -nan，
	#    看起来像投影坏了，其实只是相机没有视口。
	await process_frame

	_test_palette(cfg)
	_test_font(cfg)
	_test_zone_outline(cfg)

	await _test_scene_tree(cfg)
	await _test_frames_and_input(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 坐标换算：逻辑坐标一律是「格」，像素只在 view/ 出现
# ------------------------------------------------------------------
func _test_palette(cfg) -> void:
	# ★★ 投影类断言一律走**3D 实例**（`view/palette.gd` 已经是实例类，
	#    方法不再收 cfg —— 它自己持有 cfg 与那台 `Camera3D`）。
	#    相机用测试脚手架造（`make_test_camera` 会先喂视口尺寸，再摆好俯角/距离）。
	var cam := make_test_camera(cfg, cfg.cols, cfg.rows)
	var pal := make_test_palette(cfg, cam)
	ok(pal != null, "★ 造得出 palette 实例（3D：它持有 Camera3D）")
	if pal == null:
		return

	# ★★ 透视投影：断言按**定义**写（而不是照抄 to_px 的公式）——
	#    照抄的话「实现和期望一起错」也会绿（这个文件为这种事返工过，见 pitfalls 3.1）。
	#    ★★ 参考图那条口径的判据（最该钉住的一条）：**近大远小**。
	#       屏幕**下方**（离镜头近）的同一格，必须比屏幕**上方**的同一格占更多像素。
	var near_tile: PackedVector2Array = pal.tile_poly(10, 20)   # 靠近镜头（格 y 大）
	var far_tile: PackedVector2Array = pal.tile_poly(10, 2)     # 远离镜头
	var near_h: float = absf(near_tile[3].y - near_tile[0].y)
	var far_h: float = absf(far_tile[3].y - far_tile[0].y)
	ok(near_h > far_h * 1.05,
		"★★ 近大远小：近处的格子比远处的高（%.1f > %.1f px）" % [near_h, far_h])
	ok(near_h / far_h > 1.05, "★ 收缩比可测（%.2f 倍）" % (near_h / far_h))

	# 格线仍然横平竖直
	#
	# ★★ 这里有个**反直觉但正确**的性质（第一版预期待错了，实测才发现）：
	#    横边**严格水平**（相机没有绕竖轴转），但竖边**不是竖直的** ——
	#    它们是「从镜头发出去的一族透视线」，全部交于**同一个灭点**。
	#    所以越靠地图左右两侧的格子，竖边的倾斜越明显；只有 x 恰好在灭点正上方的
	#    那一列才是竖直的。这正是参考图里那种「竖线收敛」的观感。
	var t0: PackedVector2Array = pal.tile_poly(5, 4)
	ok(t0.size() == 4, "tile_poly 返回 4 个顶点")
	if t0.size() == 4:
		near(t0[0].y, t0[1].y, 1e-3, "★ 地块的上边是**水平**的（相机没绕竖轴转）")
		near(t0[2].y, t0[3].y, 1e-3, "★ 地块的下边是**水平**的")
		# ★★ 竖边**共同交于一个灭点** —— 这才是「相机没绕竖轴转」的严格形式。
		#
		# ⚠️⚠️ 这里返工过（写下来免得下次又踩）：老断言拿 `cfg.proj_vp_half`
		#    （视口中心）当灭点，判「上边中心比下边中心更靠屏幕中轴」。
		#    那是**2D 仿射投影**的灭点口径，对**真 3D 相机**不成立 ——
		#    实测这台相机（pitch 55°、FOV 40°、看向地图中心）的灭点在
		#    y ≈ 1500（**屏幕下方**，视口只有 1080 高），于是左右两侧的格子
		#    分别倒向它，倾斜方向**正好相反**，那条 `tilt_a * tilt_b > 0` 必然红。
		#    ⇒ 正确的判据不是「朝屏幕中轴收敛」，而是「**所有竖边共灭点**」：
		#      它等价于「相机沿 x 轴对齐」，而且与灭点落在哪里无关。
		var vp: Variant = _edge_intersection(t0[0], t0[3], t0[1], t0[2])
		ok(vp != null, "★ 地块的两条竖边不平行 ⇒ 交出一个灭点")
		var q_a: PackedVector2Array = pal.tile_poly(2, 4)
		var q_b: PackedVector2Array = pal.tile_poly(24, 4)
		var vp_a: Variant = _edge_intersection(q_a[0], q_a[3], q_a[1], q_a[2])
		var vp_b: Variant = _edge_intersection(q_b[0], q_b[3], q_b[1], q_b[2])
		if vp != null and vp_a != null and vp_b != null:
			var vpv: Vector2 = vp
			# ★ 远处（格 y 小）与近处（格 y 大）的格子，竖边指向**同一个**灭点
			v2_near(vp_a, vpv, 1.0, "★ 左侧格子的竖边指向同一个灭点")
			v2_near(vp_b, vpv, 1.0, "★ 右侧格子的竖边指向同一个灭点（两侧没有反向）")
			# ★ 灭点在屏幕**上方**（y 越小越高）：俯视时镜头朝下，
			#   远处的格线向上收敛 ⇒ 灭点跑到画面之上。
			#   ⚠️ 判据里**不能**用 `cfg.proj_vp_half`：那是上一版「手算透视」留下的
			#     配置字段，本版改由**真实 Camera3D** 承担投影之后它**不再被赋值**
			#     （于是它停在默认 540，而真正的视口高是测试里那台相机的视口）。
			#     改用「屏幕中心 = 相机看向的地面点的投影」自己算，口径才自洽。
			var vp_center: Vector2 = pal.to_px(Vector2(13.5, 11.0))
			ok(vpv.y < vp_center.y,
				"★ 灭点在屏幕中心**上方**（俯视：竖边向上收敛，实测 y = %.1f，中心 %.1f）"
				% [vpv.y, vp_center.y])
		# 近的那条边必须比远的那条边**长**（梯形 —— 参考图里墙就是这个形状）
		var top_w: float = absf(t0[1].x - t0[0].x)
		var bot_w: float = absf(t0[2].x - t0[3].x)
		ok(bot_w > top_w, "★ 地块是**梯形**：下边（近）比上边（远）长（%.1f > %.1f）"
			% [bot_w, top_w])

	# 正逆必须严格互逆（这一对就是「画在哪」与「点到哪」的同一份口径）
	var p := Vector2(2.0, 3.0)
	var px: Vector2 = pal.to_px(p)
	v2_near(pal.to_logic(px), p, 1e-3, "★ to_logic 是 to_px 的逆")
	# 多个点都要互逆（含边界与远处 —— 透视的除法最容易在远处出问题）
	for q: Vector2 in [Vector2(0.0, 0.0), Vector2(26.9, 21.9), Vector2(13.5, 0.1),
			Vector2(0.1, 21.5), Vector2(6.5, 5.5)]:
		v2_near(pal.to_logic(pal.to_px(q)), q, 1e-2,
			"★ 互逆（格 %s）" % str(q))

	# ★★ 回退契约：俯角 90°（正俯视）时，投影退化成仿射（远近一样大）。
	var flat = ConfigRes.load_default()
	ok(flat != null, "能再载入一份配置（回退口径用）")
	if flat != null:
		flat.cam_pitch = PI * 0.5
		flat.set_viewport_size(flat.proj_vp_w, flat.proj_vp_h)
		# ★ 换一份配置 = 换一台相机（palette 实例持有的是**那台 3D 相机**）
		var flat_pal := make_test_palette(flat, make_test_camera(flat, flat.cols, flat.rows))
		var f1: PackedVector2Array = flat_pal.tile_poly(10, 20)
		var f2: PackedVector2Array = flat_pal.tile_poly(10, 2)
		var h1: float = absf(f1[3].y - f1[0].y)
		var h2: float = absf(f2[3].y - f2[0].y)
		near(h1, h2, 0.5, "★ 俯角 90°（正俯视）时远近格高相同 ⇒ 退化成仿射")
		# 俯角 90° 时地块是矩形（不是梯形）
		var wt: float = absf(f1[1].x - f1[0].x)
		var wb: float = absf(f1[2].x - f1[3].x)
		near(wt, wb, 0.5, "★ 俯角 90° 时上下边等长 ⇒ 地块是矩形")

	# 地图外接框 = 四个角投影的极值（相机夹取用它）
	#
	# ★★ 3D 版没有 `map_rect` / `map_poly` 这一对静态函数了：外接框由
	#    **四个角各自投影**（`tile_poly` 的四个顶点）取 AABB 得到 ——
	#    透视下地图是梯形，所以「先算矩形再套」那种写法本来就不成立。
	var mr := _aabb_of(pal.tile_poly(0, 0))
	mr = mr.merge(_aabb_of(pal.tile_poly(3, 0)))
	mr = mr.merge(_aabb_of(pal.tile_poly(3, 2)))
	mr = mr.merge(_aabb_of(pal.tile_poly(0, 2)))
	ok(mr.size.x > 0.0 and mr.size.y > 0.0, "地图外接框非退化")
	for v in pal.tile_poly(0, 0):
		ok(mr.grow(0.5).has_point(v), "★ 外接框真的套住了地图的角点")

	# ★ 单位半径：透视下**随位置变化**（近大远小）——
	#   取「屏幕下方」与「屏幕上方」各一点比一比。
	#
	# ★★ 半径必须走**实例 API**（3D 投影）：逻辑半径（格）→ 屏幕像素这一步
	#    在透视下随位置变化，2D 的「半径 × cell_px」是个**常数**（近远一样大），
	#    拿它比等于什么都没验（实测：两边都是 11.52 px，断言必红）。
	#    这里照 `unit_view` 的口径写：屏幕半径 = 1 格在该处的屏幕跨度 × 逻辑半径。
	var near_pos := Vector2(10.0, 20.0)     # 离镜头近
	var far_pos := Vector2(10.0, 2.0)       # 离镜头远
	var span_near := _cell_span_px(pal, near_pos)
	var span_far := _cell_span_px(pal, far_pos)
	var u_rad: float = cfg.unit_radius_of(UnitRes.UNIT_TYPE_SPEARMAN)
	var r_near: float = u_rad * span_near.y
	var r_far: float = u_rad * span_far.y
	ok(span_near.y > 0.0 and span_far.y > 0.0, "★ 单位所在的两格都能投到屏幕上（跨度非零）")
	ok(r_near > r_far, "★★ 单位半径也随透视缩放（近 %.2f px > 远 %.2f px）" % [r_near, r_far])

	# ★★ 透视档下这三个是**恒等**（字 / 血条天然 1:1，不需要反向补偿）
	near(Palette2DRes.screen_metric(cfg, 10.0), 10.0, 1e-9, "screen_metric 是恒等（世界像素 == 屏幕像素）")
	near(Palette2DRes.comp_scale(cfg), 1.0, 1e-9, "comp_scale = 1（不需要补偿）")
	v2_near(Palette2DRes.comp_extent(cfg, Vector2(12.0, 5.0)), Vector2(12.0, 5.0), 1e-9,
		"comp_extent 是恒等")

	# 建筑块：城墙填满整格，其它内缩；内缩比例只有一处来源（body_scale）
	var w0 = require_world(cfg)
	var base_b = w0.find_base_of("p1")
	ok(base_b != null, "取得到大本营建筑")
	if base_b != null:
		var base_poly := Palette2DRes.building_poly(base_b, cfg)
		ok(base_poly.size() == 4, "建筑本体是一个四边形")
		var base_mid := Palette2DRes.rect_of(base_poly).get_center()
		v2_near(base_mid, Palette2DRes.to_px(base_b.center(), cfg), 2.0,
			"★ 建筑块与格心同心（外接框中心 = 投影后的格心）")
		# 大本营的块必须比整格**小**（body_scale 0.6）
		var tile_r := Palette2DRes.tile_rect(base_b.tx, base_b.ty, cfg)
		var base_r := Palette2DRes.rect_of(base_poly)
		ok(base_r.size.x < tile_r.size.x + 1e-3, "大本营比整格窄（内缩留出地面）")
		var wall = w0.add_building("wall", base_b.tx + 1, base_b.ty, "p1")
		if wall != null:
			var wp := Palette2DRes.building_poly(wall, cfg)
			var wq := Palette2DRes.tile_poly(wall.tx, wall.ty, cfg)
			near(Palette2DRes.rect_of(wp).size.x, Palette2DRes.rect_of(wq).size.x, 0.5,
				"★ 城墙填满整格（宽度与地块一致）")


## 一组点的轴对齐外接框（3D 版没有 `palette.map_rect`，用它取代）
func _aabb_of(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)


## 两条**线段所在直线**的交点；平行（或退化）时返回 null。
##
## ★ 用来求「竖边族的灭点」：同一台未绕竖轴转的相机，所有竖边都在同一族射线上，
##   任意两条的交点都相同。平行（正俯视 90°）时灭点在无穷远，返回 null 是对的 ——
##   那种情况下竖边本来就该严格竖直，调用方不该断言「交出一个点」。
func _edge_intersection(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2) -> Variant:
	var d1 := a2 - a1
	var d2 := b2 - b1
	var den := d1.cross(d2)
	if absf(den) < 1e-9:
		return null
	var t: float = (b1 - a1).cross(d2) / den
	return a1 + d1 * t


## 某一格在屏幕上的**横 / 纵跨度**（像素）：取相邻格心的投影差分。
##
## ★ 2D 里「一格 = cell_px 像素」是个常数；透视下它随位置变化 ——
##   这正是「单位半径也近大远小」的来源，所以半径要按它算（见上面的断言）。
func _cell_span_px(pal, cell: Vector2) -> Vector2:
	var p0: Vector2 = pal.to_px(cell)
	var px: Vector2 = pal.to_px(cell + Vector2(1.0, 0.0))
	var py: Vector2 = pal.to_px(cell + Vector2(0.0, 1.0))
	return Vector2(p0.distance_to(px), p0.distance_to(py))


# ------------------------------------------------------------------
# 中文字体
# ------------------------------------------------------------------
func _test_font(cfg) -> void:
	var font = FontLoaderRes.load_font(cfg)
	ok(font != null, "能载入中文字体（拷过 tools/setup-font.ps1？）")
	if font != null:
		ok(font.has_char("军".unicode_at(0)), "字体真的有中文字形（军）")
		ok(font.has_char("城".unicode_at(0)), "字体真的有中文字形（城）")
	var theme = FontLoaderRes.build_theme(cfg, 15)
	if font != null:
		ok(theme != null and theme.default_font != null, "能做出带中文字体的 Theme")
	else:
		ok(theme == null, "没有字体时 build_theme 返回 null（不崩，退回引擎默认字体）")


# ------------------------------------------------------------------
# 节点树：主场景真的能挂上树
# ------------------------------------------------------------------
## 建主场景 → 点 test 进游戏 → 返回**游戏内场景**（GameScene）。
##
## ⚠️⚠️ 必须在 game 上断言，**不能**在 main 根上断言。`main.tscn` 的根挂的是 `main.gd`，
##   它只有 `cfg` / `start_screen` / `game` 三个字段 —— 在上面访问
##   `world` / `cam` / `input_ctrl` / `hud` 会**报错并返回 null**，
##   于是后面那些断言全部静默不执行（`ok(null != null)` 该红也没红，因为整段根本没跑到）。
##   这个文件就这样假绿了很久：44 处断言里只有 19 处真的执行 —— 实测发现的。
func _enter_game(packed):
	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	# 走真实入口：按下「test」才建游戏内场景（与玩家点一下按钮完全同一条路）
	# ⚠️ 现在必须把**选中的地图**传进去：`_on_test_pressed(map_path)` 的入参就是
	#    `test_pressed` 信号带出来的那个值（见 view/main.gd）。不传 = 调用失败、
	#    `main.game` 永远是 null，而后面那些断言会变成「在等一个不会发生的事」——
	#    实测的后果是整套测试卡住不退出（某些用例在循环等关卡加载完）。
	#    下面这一行与「玩家在下拉框里选了哪张」用同一个读法（start_screen 里唯一那处）。
	main._on_test_pressed(main.start_screen.selected_map_path())
	await process_frame
	return main


func _test_scene_tree(cfg) -> void:
	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		return
	ok(packed is PackedScene, "main.tscn 是 PackedScene（裸脚本不行，实测会启动失败）")

	var main = await _enter_game(packed)
	ok(main != null, "主场景能实例化")
	if main == null:
		return
	ok(main.is_inside_tree(), "主场景真的挂上树了（await process_frame 之后）")

	var game = main.game
	ok(game != null, "★ 按下 test 之后建出了游戏内场景（在 main 根上找 world 是找不到的）")
	if game == null:
		main.queue_free()
		return

	ok(game.world != null, "游戏内场景建出了逻辑世界")
	ok(game.cfg != null, "游戏内场景载入了配置")
	ok(game.cam != null, "游戏内场景建了相机")

	# 渲染节点齐了。★ 3D 版：世界内容直接住在场景根下（**没有** ContentRoot 了）。
	#
	# ⚠️ 这一块原来钉的是 2.5D 那套「ContentRoot 压扁 + 谁在根下 / 谁不在」。
	#    入口切到 3D 之后：
	#      · `ContentRoot` / `Camera2D` / `CameraRig` **本来就不该存在**；
	#      · 而「内容根不缩放 / 不旋转」那条**结构断言**在 3D 下**没有对应物**
	#        —— 3D 里根本不存在「把世界压扁的父节点」这个概念，
	#        相机姿态由 `Camera3D` 自己的基向量表达（见 `game_scene3d._place_camera_looking_at`）。
	#    ⇒ 所以这一段不是「换个节点名」，而是**整块换成 3D 的结构断言**：
	#      钉住「四个渲染层都挂上了」「相机是 3D 的」「HUD 不吃世界变换」。
	for node_name in ["Camera3D", "GroundView3D", "UnitView3D", "BuildingView3D",
			"OverlayLayer", "InputController", "Hud"]:
		ok(game.get_node_or_null(node_name) != null, "节点树里有 %s" % node_name)
	# ★★ 3D 场景最关键的结构事实：**相机不是世界内容的父节点**。
	#    为什么必须钉：把相机挂成内容的父节点，会让「平移相机」与「平移世界」
	#    变成同一件事，于是相机高度随平移改变 —— 那正是用户报过的
	#    「向下滑动时地块越来越大」。3D 版把相机与内容**并列**挂在根下。
	var cam3: Camera3D = game.get_node_or_null("Camera3D")
	if cam3 != null:
		ok(cam3.get_parent() == game, "★ 相机与内容**并列**挂在根下（不是内容的父节点）")
		for node_name in ["GroundView3D", "UnitView3D", "BuildingView3D"]:
			var n = game.get_node_or_null(node_name)
			ok(n != null and n.get_parent() == game, "%s 与相机并列（相机不是它的父节点）" % node_name)

	# 相机是纯表现：不该进快照
	#
	# ⚠️ 这里原本是 `game.cam.zoom.x > 0.0` —— 那是 `Camera2D` 专属属性。
	#    入口切 3D 之后 `game.cam` 是 `Camera3D`，读 `.zoom` 会**抛错并中断整段**
	#    （实测：358 行之后含 2.5D 补偿那几条全都不执行，而文件仍报「0 失败」）。
	#    换成 3D 下等价的那条：相机确实是一台配好的透视相机。
	ok(game.cam is Camera3D and game.cam.fov > 0.0 and game.cam.fov < 180.0,
		"相机是配好的 Camera3D（fov 合法）")

	# 逻辑与渲染是两棵树：world 不是 Node
	ok(not (game.world is Node), "★ world 不是 Node（逻辑层与场景树分离）")

	# ★ unit_view 现在是「一个 CanvasItem 画全部」：1000 单位也不该有子节点
	# ★★ 3D 版：单位是**一个 MultiMeshInstance3D** 画全部 ⇒ 它的实例都塞在
	#    `multimesh` 里，**不该**每单位一个子节点。
	#    ⚠️ 这与 2D 版那条「一个 CanvasItem 画全部、不持有子节点」是**同一个意图换了工具**：
	#      2D 靠一个 CanvasItem 的自绘，3D 靠 MultiMesh 的逐实例变换。
	var uv = game.unit_view
	ok(uv != null, "unit_view 存在（3D 版是 units 的别名）")
	if uv != null:
		# ★ 只数「单位批次」节点（名字以 `Units_` 开头）；将领贴花层 / 选中下标层是**额外的
		#   辅助层**（各一个节点），不算「每单位一个节点」。
		var unit_batches := 0
		for ch in uv.get_children():
			if String(ch.name).begins_with("Units_"):
				unit_batches += 1
		ok(unit_batches <= 4,
			"★ unit_view 不为每个单位建节点（只有每变体一个 Units_* 批次，实测 %d 个）"
			% unit_batches)

	# ★★ 2.5D 的补偿组（2D 口径）：真的进过、而且**画完已经复位**。
	#
	# 为什么要单独断言这两条（**2D 栈**）：`draw_set_transform` 是「进去 → 画 → 复位」的
	#   成对操作，漏了复位**不会报错、也不会让任何测试变红**，只会让后面每一个图元歪着画。
	#
	# ⚠️⚠️ 但这三条**在 3D 入口下没有意义、而且会静默中断整段**（本轮审计抓到）：
	#   `game.unit_view` 在 3D 里是 `MultiMeshInstance3D` —— **不是**自绘的 `CanvasItem`
	#   ⇒ 它没有 `comp_group_count` / `comp_reset_ok` / `icon_draw_count` 这些计数器，
	#   读它们会抛 `Invalid access to property or key 'comp_reset_ok'`
	#   ⇒ `_test_scene_tree()` **从这一行起整体中断**，后面的断言一条都不跑
	#     （`test_view` 报告「通过 N 项 / 失败 0 项」）。
	#   ⇒ 3D 的等价可数痕迹是**「单位层的实例数 = 可见单位数」**，
	#     已经由上面那句 `_assert_unit_multimesh(game)` 钉住了。
	#   ★ 判据：**「自绘 CanvasItem 的计数器」只属于 2D 栈**，3D 里换成 MultiMesh 的实例数。
	game.unit_view.set_selection([game.world.units[0].id])
	_assert_unit_multimesh(game)

	# ★ 遗留 2D 栈里补偿是**恒等**（世界像素 == 屏幕像素，字 / 血条天然 1:1）——
	#   这一条量的是 `palette2d.gd` 那套换算本身，与当前入口是 2D 还是 3D **无关**
	#   （它只吃 cfg），所以照留。
	near(Palette2DRes.comp_scale(game.cfg), 1.0, 1e-9,
		"★ 遗留 2D 栈：comp_scale 恒为 1（不需要反向补偿）")
	near(Palette2DRes.screen_metric(game.cfg, 7.0), 7.0, 1e-9,
		"★ 遗留 2D 栈：screen_metric 恒等")

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# 跑帧 + 注入输入：世界推进、渲染同步都不炸
# ------------------------------------------------------------------
func _test_frames_and_input(cfg) -> void:
	var packed = load("res://view/main.tscn")
	var main = await _enter_game(packed)
	var game = main.game
	if game == null:
		ok(false, "进游戏失败：拿不到 GameScene（后面这些断言全都不会执行）")
		main.queue_free()
		return

	var world = game.world
	var t0: float = world.time
	for i in 30:
		await process_frame

	# headless 下 delta 可能极小，但 world.time 必须**前进**（tick 真的在跑）
	ok(world.time > t0, "跑 30 帧后世界时间前进（主循环真的在推进逻辑）")

	# 注入一次「选中 + 下令移动」：走的是命令这条路
	#
	# ★ 注意这里是**整队**选中：将领带附属兵，选中队长时会把附属兵一起带上，
	#   所以选中数不是 1 而是「1 + 附属兵数」。这正是需求要的行为，断言照实写。
	var u = world.units[0]
	var group_size: int = world.group_of(u).size()
	game.input_ctrl.select_units([u])
	eq(game.input_ctrl.selected_units.size(), group_size,
		"★ 选中将领 1 会同步选中整队（1 + %d 个附属兵）" % (group_size - 1))
	ok(u.selected, "选中后逻辑单位的 selected 标志被置上（view 写的是存在的字段）")
	var sub_selected := 0
	for su in game.input_ctrl.selected_units:
		if su.leader_id == u.id:
			sub_selected += 1
	eq(sub_selected, group_size - 1, "整队里的附属兵也都被选中了")

	var before = u.pos
	# ★ 命令要下给**整队**：这正是「右键移动同步给附属兵下达指令」那条需求，
	#   所以这里把选中列表里所有 id 都带上（input_controller 就是这么做的）
	var all_ids: Array = []
	for su in game.input_ctrl.selected_units:
		all_ids.append(su.id)
	game._on_command({
		"kind": "move", "ids": all_ids,
		"x": before.x + 3.0, "y": before.y,
		"faction": world.my_faction,
	})
	ok(u.moving, "move 命令让单位进入移动状态")
	var sub_moving := 0
	for su in world.retinue_of(u.id):
		if su.moving:
			sub_moving += 1
	eq(sub_moving, world.retinue_of(u.id).size(), "★ 附属兵也收到了同一条移动命令（都进入移动状态）")
	for i in 120:
		await process_frame
	ok(u.pos.distance_to(before) > 0.05, "跑 120 帧后单位真的动了（命令 → 逻辑 → 渲染这条线通了）")

	# 建造命令 + 拆除命令（走同一条命令流）
	var free = Vector2i(-1, -1)
	for ty in world.map.rows:
		for tx in world.map.cols:
			if world.can_build_at(tx, ty):
				free = Vector2i(tx, ty)
				break
		if free.x >= 0:
			break
	ok(free.x >= 0, "找得到一格可建造的空地")
	if free.x >= 0:
		# ★ 建造现在要花钱（economy.enabled = true，箭塔 50 粮 / 50 金）——
		#   不给钱的话命令会因 cost 被拒（本次经济调参的连带改动）。
		world.resources["food"] = 1000.0
		world.resources["gold"] = 1000.0
		ok(CommandRes.apply(world, cfg, {"kind": "build", "build_type": "tower", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"建造命令落成")
		await process_frame
		ok(world.building_at(free.x, free.y) != null, "建筑在渲染前就已经在逻辑里了")
		ok(CommandRes.apply(world, cfg, {"kind": "demolish", "tx": free.x, "ty": free.y, "faction": "p1"}),
			"拆除命令生效")
		await process_frame

	# 刷一个敌人 + 跑一会儿：覆盖「有战斗、有事件、HUD 要翻译事件」这条路径
	CommandRes.apply(world, cfg, {"kind": "spawn_enemy", "faction": "enemy"})
	ok(world.alive_units_of("enemy").size() >= 1, "调试刷敌人成功")
	for i in 60:
		await process_frame
	ok(game.hud != null, "HUD 还在（翻译事件不会炸）")

	_test_zoom_direction(cfg, game)
	_test_fixed_view_range(cfg, game)
	_test_fullscreen_hotkey(main)

	main.queue_free()
	await process_frame


# ------------------------------------------------------------------
# Ctrl+Q：开发者全屏快捷键（全屏 ↔ 窗口）
# ------------------------------------------------------------------
## ⚠️ 无头（--headless）下 DisplayServer 是空实现，改不了真实窗口模式 ——
##    所以这里验的是**按键归谁消费**（路由），不是窗口真的变了。
##    真机上「按一下切全屏」= 这条路由 + main._handle_window_hotkey 里那几行。
func _test_fullscreen_hotkey(main) -> void:
	ok(main._handle_window_hotkey(_key_event(KEY_Q, true)),
		"★ Ctrl+Q 被 main 的全屏快捷键消费")
	ok(not main._handle_window_hotkey(_key_event(KEY_Q, false)),
		"单独按 Q **不**触发全屏（它仍然是命令卡的键）")
	ok(not main._handle_window_hotkey(_key_event(KEY_F, true)),
		"别的键 + Ctrl 也不触发全屏")
	# 再按一次 Ctrl+Q 必须能切回来（不是单向的）
	ok(main._handle_window_hotkey(_key_event(KEY_Q, true)),
		"★ Ctrl+Q 是**切换**（再按一次仍然被消费，不是单向）")


func _key_event(code: int, ctrl: bool) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.pressed = true
	ev.ctrl_pressed = ctrl
	return ev


# ------------------------------------------------------------------
# 滚轮缩放方向（第一版写反过，所以钉一条回归）
# ------------------------------------------------------------------
## 滚轮缩放方向 + 上下限（**3D 版**）。
##
## ★ 这一条**保住的是需求**，不是实现：滚轮向上放大、向下缩小、且上下限夹得住。
##   载体从 `Camera2D.zoom` 换成了 3D 的「相机距离倍率」`game.zoom`
##   （值越大 = 相机越远 = 看到越多 ⇒ 与 zoom 的语义**相反**，所以比较方向也相反）。
##
## ⚠️ 原来这里写的是 `var cam: Camera2D = game.cam`。入口切 3D 之后它会在**赋值那一行**
##    抛 `Trying to assign value of type 'Camera3D' to a variable of type 'Camera2D'`，
##    把整个函数中断 —— 而文件仍报「0 失败」（与 pitfalls 10.7 同款：**整段中断不产生失败**）。
func _test_zoom_direction(cfg, game) -> void:
	var input_ctrl = game.input_ctrl
	var center := Vector2(400.0, 300.0)

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	up.position = center
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	down.position = center

	var z0: float = game.zoom
	ok(input_ctrl.handle_mouse_button(up), "滚轮向上被消费")
	# ⚠️ 方向说明（我第一版把这行写成 `<` 并因此报了 4 条假红）：
	#    `input_controller` 对 WHEEL_UP 传 `camera.zoom_step`（**> 1**）、
	#    对 WHEEL_DOWN 传它的倒数 —— 而 3D 的 `game.zoom` 是**相机距离倍率**
	#    （越大 = 相机越远 = 画面越小）。⇒ 向上滚时这个倍率**变大**。
	#    ★ 语义差异：「zoom」在 2D 里是放大倍数、在 3D 里是距离倍数，方向天然相反。
	ok(game.zoom < z0, "★ 向上滚 = 拉近（相机距离倍率变小；方向按实测核准）")

	var z1: float = game.zoom
	ok(input_ctrl.handle_mouse_button(down), "滚轮向下被消费")
	ok(game.zoom > z1, "★ 向下滚 = 拉远（相机距离倍率变大）")

	# 上下限必须被夹住（不能无限拉近 / 拉远）
	# ★ 数值钉住 `game_scene3d.ZOOM_MIN` / `ZOOM_MAX`（需求：视野缩到原来的一半 ⇒ 0.35/3.0 各 ×0.5）。
	for i in 60:
		input_ctrl.handle_mouse_button(up)
	ok(game.zoom >= 0.175 - 1e-6, "★ 一直往上滚 = 夹在距离下限（最紧视野）")
	for i in 120:
		input_ctrl.handle_mouse_button(down)
	ok(game.zoom <= 1.5 + 1e-6, "★ 一直往下滚 = 夹在距离上限（最远视野）")


## 视野固定：最远视野确实比最紧视野看到更多（需求：给玩家一个缩放上限 + 下限）。
##
## ★ 判据用**相机距离的比值**（与窗口大小 / 格宽无关，换窗口、改 cell_px 都不用重算）。
##   3D 版不读 `camera_rig.zoom_limits()`（那是 2D 的 `CameraRig` 节点，3D 场景里没有）。
func _test_fixed_view_range(cfg, game) -> void:
	var input_ctrl = game.input_ctrl
	var center := Vector2(400.0, 300.0)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_WHEEL_UP
	up.pressed = true
	up.position = center
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	down.pressed = true
	down.position = center

	for i in 60:
		input_ctrl.handle_mouse_button(up)
	var z_tight: float = game.zoom
	for i in 120:
		input_ctrl.handle_mouse_button(down)
	var z_wide: float = game.zoom
	# 向上滚 60 次 = 一路拉近（实测方向）⇒ z_tight 装的就是最紧那一端
	ok(z_wide > z_tight,
		"★ 最远视野确实比最紧视野看得多（距离 %.3f -> %.3f）" % [z_tight, z_wide])
	# 需求那条：两端之间要拉开足够差距（否则「缩放」形同虚设）
	ok(z_wide / maxf(1e-6, z_tight) >= 2.0,
		"★ 缩放区间足够宽（最远 / 最紧 = %.2f ≥ 2.0）" % (z_wide / maxf(1e-6, z_tight)))
func _test_zone_outline(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var zv = script_at("res://view/zone_view.gd").new()
	# ⚠️ 不挂到 root 上：这里在 `_initialize()` 阶段，「挂节点必须等一帧」那条坑
	#    （见文件头 + pitfalls 1.2）会让 add_child 静默失效。视图的几何与取色
	#    都不依赖场景树，所以直接建出来用（同 test_fog.gd 的 InputController 写法）。
	zv.setup(cfg, w, null, 12)

	# 1) 参数从 config 来（config.json 的 colors.zone_*）
	var stroke_w: float = cfg.num("colors.zone_stroke_width", 3.0)
	var owned_w: float = cfg.num("colors.zone_stroke_width_owned", 2.5)
	var halo_delta: float = cfg.num("colors.zone_halo_delta", 2.0)
	near(zv._w_stroke, stroke_w, 1e-6, "描边线宽来自 config（colors.zone_stroke_width）")
	near(zv._w_stroke_owned, owned_w, 1e-6, "有主区划线宽来自 config")
	near(zv._halo_delta, halo_delta, 1e-6, "光晕宽度来自 config")
	ok(stroke_w >= 2.5, "★ 主线线宽 >= 2.5px（「加粗」：原来的固定 1px 太细）")
	ok(halo_delta > 0.0, "光晕比主线更宽（否则「外圈光晕」根本不外扩）")
	eq(zv._c_stroke, Color(1, 1, 1, 1), "★ 无主区划的描边是**纯白不透明**（不是 10% 白）")
	near(zv._c_stroke.a, 1.0, 1e-6, "主线的 alpha = 1（「清晰」的一半在这里）")
	ok(zv._c_halo.a > 0.0 and zv._c_halo.a < 1.0, "光晕是半透明白（叠在主线下面，不是又一条实心线）")

	# 2) 轮廓几何：每块区划都有自己的边（没有地块明细的老地图走包围盒）
	#
	# ★★ 菱形档的口径变化：这里**不再有几何缓存**（老版本缓存 `_edges_by_zone`）。
	#    原因写在 zone_view.gd 文件头：线段坐标现在由投影决定（`tile_poly`），
	#    换角度就得全部作废，且斜线没法像矩形那样合并 —— 于是改成每帧现算，
	#    成本靠「只遍历区块自己的地块 + 同格只处理一次」压住。
	#    所以这一节改成直接验**分组后的结果**（那正是真正被画出去的东西）。
	var zones: Array = w.zones.zones
	ok(zones.size() > 0, "世界上有区划")
	var groups_pre: Dictionary = zv._outline_groups()
	ok((groups_pre["neutral"] as PackedVector2Array).size() >= 8,
		"★ 无主区划的轮廓算得出来（至少两块地共边 = 8 个端点）")
	var pre_neutral: PackedVector2Array = groups_pre["neutral"]
	ok(pre_neutral.size() % 2 == 0,
		"线段数组是成对的端点（%d 个点 = %d 段）" % [pre_neutral.size(), int(pre_neutral.size() / 2)])

	# ★★ 轮廓点必须落在**这一块区划的地块**上：抽第一块区划，把它所有地块的菱形
	#    收成一个包围盒，断言它的轮廓点都在盒内（错投影 / 错地块的 bug 会当场红）。
	var probe_zone: Dictionary = zones[0]
	var zr: Rect2 = zv._zone_rect(probe_zone)
	ok(zr.size.x > 0.0 and zr.size.y > 0.0, "区块在屏幕上有一个非退化的外接框")
	var q_first := Palette2DRes.tile_poly(int(probe_zone["x0"]), int(probe_zone["y0"]), cfg)
	ok(zr.grow(4.0).has_point(q_first[0]),
		"★ 外接框真的套住了这一区块的地块（菱形顶点落在框内）")

	# 3) 有主区划的颜色 = **该阵营自己的**主色（分工合作时不能串色）
	var p1_color: Color = cfg.faction_color("p1", "main")
	var p2_color: Color = cfg.faction_color("p2", "main")
	eq(zv._stroke_color_owned("p1"), p1_color, "★ 有主区划用 p1 的阵营主色描边")
	eq(zv._stroke_color_owned("p2"), p2_color, "★★ 第二个玩家阵营用它自己的颜色（不是「谁先占谁定色」）")
	ok(p1_color != p2_color, "两个阵营的主色确实不同（否则上一条测了个寂寞）")

	# 4) 画一遍不炸（draw_multiline / draw_polygon 的参数用错会直接报错）
	#
	# ★ 为什么这仍然是必要的：`_draw()` 里的错误**不会让测试失败**（只打红字），
	#   所以「跑得通」这件事只有显式调一次才能变成断言。
	# ⚠️ 但**不能在 `_draw()` 之外调 `_draw()`**：Godot 会报
	#   「Drawing is only allowed inside this node's `_draw()`」并且什么都不画
	#   （实测）。所以这里只调 `draw_shapes(ci)` —— 它接受一个 CanvasItem 参数，
	#   本来就设计成「由子节点在自己的 _draw 里调」，是合法的绘制入口。
	zv.draw_shapes(zv)
	ok(zv.draw_count >= 0, "draw_shapes 跑得通（%d 次绘制命令）" % zv.draw_count)

	# 5) ★★ 分组：按**阵营 id** 分，而不是「有主 / 无主」两档
	#    （单机下把两个阵营合成一组也看不出来，合作模式里就会串色）
	(zones[0] as Dictionary)["owner"] = "p1"
	if zones.size() >= 2:
		(zones[1] as Dictionary)["owner"] = "p2"
	var groups: Dictionary = zv._outline_groups()
	var owned: Dictionary = groups["owned"]
	ok(owned.has("p1"), "★ p1 的区划进了 p1 这一组")
	ok(owned.has("p2"), "★★ p2 的区划进了 p2 这一组（不是和 p1 合成一组）")
	ok((groups["neutral"] as PackedVector2Array).size() > 0, "还有无主区划走纯白那一组")
	var p1_segs: PackedVector2Array = owned.get("p1", PackedVector2Array())
	var p2_segs: PackedVector2Array = owned.get("p2", PackedVector2Array())
	ok(p1_segs.size() > 0 and p2_segs.size() > 0, "两组各自都有自己的线段")
	# 恢复成「全部无主」，免得影响后面 / 别的用例看到的场面
	(zones[0] as Dictionary)["owner"] = ""
	if zones.size() >= 2:
		(zones[1] as Dictionary)["owner"] = ""

	# 收尾：这个节点**没挂进场景树**（见上面那条注释），所以用 free() 立刻释放 ——
	# queue_free() 对不在树上的节点不会生效，会留到退出时由引擎报「还在泄漏」。
	zv.free()
	zv = null



## 3D 版取代「手动调一次 `_draw()` 看它炸不炸」的断言。
##
## ★ 为什么需要等价物：`_draw()` 里的错误**不会让测试失败**（只打红字），
##   所以 2D 版才要「真跑一遍」。3D 版没有 `_draw()`，
##   等价的可数痕迹是「这一帧真的把单位写进了 MultiMesh」——
##   写 0 个（比如分桶键拼错）就是「一个单位都看不见」。
func _assert_unit_multimesh(game) -> void:
	var uv = game.unit_view
	if uv == null:
		ok(false, "单位层存在")
		return
	uv.sync()
	var expect := 0
	for u in game.world.units:
		if u.alive and uv._visible_to_me(u):
			expect += 1
	eq(uv.instance_count, expect, "★ 单位层实例数 = 可见单位数（%d）" % expect)
	ok(uv.instance_count > 0, "★ 真有单位被写进 MultiMesh（写 0 个 = 一个都看不见）")
	ok(uv.mesh_batch_count <= 8,
		"★ 批次数受控（%d ≤ 8：每种「阵营 × 将领」变体一个批次）" % uv.mesh_batch_count)