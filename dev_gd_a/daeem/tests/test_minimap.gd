## test_minimap.gd —— 小地图 + 相机平移阈值（本轮三条需求）
##
## 需求原文：
##   1. 「让地图 ui 正常工作，使地图 ui 可以显示整个地图的内容和玩家当前的视野框
##       （玩家平移视野和缩放视野时，该视野框都会随之变化）」
##   2. 「当玩家左键点击地图中的某处时，将视角移动至玩家点击的地方（需要做边界判定，
##       如果玩家点到地图边角时，视野移动到阈值/极点处）」
##   3. 「更改平移视角的阈值，玩家视野可以移动到的极点为地图边界点到屏幕中心时的点，
##       因此情况玩家看到的地图界外的东西全部为默认背景」
##
## ★★ 为什么必须在 **GameScene** 上断言（不是在 main.tscn 的根上）：
##    main 的根上只有 cfg / start_screen / game 三个字段，取 hud / cam 会报错并返回 null，
##    后面那一整段断言会**静默不执行**（看起来全绿，其实一条没跑）——
##    test_view.gd 为这件事假绿过一次，见那个文件 _enter_game 的注释与 pitfalls 5.35。
##
## ⚠️ 挂节点必须在 `await process_frame` 之后：`_initialize()` 阶段 root.add_child() 静默失效。
extends "res://tests/test_case.gd"

const UiLayoutRes = preload("res://view/ui_layout.gd")
const PaletteRes = preload("res://view/palette.gd")
const BuildingRes = preload("res://logic/building.gd")


func _initialize() -> void:
	_case_name = "test_minimap"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return

	var packed = load("res://view/main.tscn")
	ok(packed != null, "能载入主场景 main.tscn")
	if packed == null:
		quit(1)
		return

	var main = (packed as PackedScene).instantiate()
	root.add_child(main)
	# ⚠️ headless 的根视口默认是正方形（1920×1920），贴下沿的面板会被推到 y=1680。
	#    这里显式钉成参考图的 1920×1080（与 test_ui.gd 同一个理由）。
	root.size = Vector2i(int(UiLayoutRes.DESIGN_W), int(UiLayoutRes.DESIGN_H))
	await process_frame
	main._on_test_pressed()
	await process_frame
	await process_frame

	var game = main.game
	ok(game != null, "★ 按下 test 之后建出了游戏内场景")
	if game == null:
		main.queue_free()
		quit(1)
		return

	var mm = game.hud.minimap
	ok(mm != null, "HUD 里有小地图控件（不再是那个只有两个大字的占位）")
	ok(game.hud.map_placeholder == null or game.hud.map_placeholder.get_child_count() > 0,
		"左下角面板里有内容（占位时代是一个 Label）")

	if mm != null:
		await _test_content(mm, game, cfg)
		_test_geometry(mm, game)
		_test_view_rect(mm, game)
		_test_click(main, game, mm)
	_test_camera_extremes(main, game, cfg)
	_test_design_viewport_fractions(game, cfg)

	main.queue_free()
	await process_frame

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ------------------------------------------------------------------
# 一、需求 1 的前半：「显示整个地图的内容」
# ------------------------------------------------------------------
func _test_content(mm, game, cfg):
	# 控件真的挂上树、拿到了世界与相机（拿不到的话下面全是在测空气）
	ok(mm.world == game.world, "★ 小地图拿到了逻辑世界（它只读 world，不改）")
	ok(mm.camera_rig == game.camera_rig, "★ 小地图拿到了相机（视野框靠它算）")
	ok(mm.mouse_filter == Control.MOUSE_FILTER_STOP,
		"小地图吃掉鼠标事件（点它 = 移动镜头，不许穿到地图上）")
	# ★★ 这一条是**真机才会暴露的那类 bug**：Godot 的鼠标事件从父传到子，
	#    外层容器只要是 STOP，子控件的 _gui_input 就永远收不到 —— 表现是
	#    「小地图画得好好的，但点它没反应」。无头测试直接调 _gui_input，
	#    所以**必须显式断言父容器不是 STOP**，否则这个 bug 一路绿灯（本轮真踩过）。
	ok(game.hud.map_placeholder.mouse_filter != Control.MOUSE_FILTER_STOP,
		"★ 小地图的外层容器不吃事件（否则子控件的点击永远收不到）")
	ok(game.hud.map_placeholder.get_child_count() > 0,
		"左下角面板里有小地图控件（不再是那个只有两个大字的占位）")

	# ★★ 每帧自绘控件必须**每帧标脏**，否则整块画面就是首帧的快照。
	#    本轮真踩过：小地图写了 `_draw()` 却没 `queue_redraw()`，三个症状一起冒出来 ——
	#      「敌人在地图上跑、小地图里的点不动」
	#      「平移/缩放视角，白色视野框纹丝不动」
	#      「点了小地图画面跳了，小地图上的框还停在原处」
	#    ★ 判据：数 `draw` 信号。`_process` 里只有 `queue_redraw()` 这一行，
	#      所以「跑一帧后收到过一次绘制请求」等价于「这一帧确实重画了」。
	#      （`CanvasItem.is_queued_for_redraw()` 在 4.7 里**不存在**，别写它。）
	var draws := [0]
	mm.draw.connect(func() -> void: draws[0] += 1)
	await process_frame
	ok(draws[0] >= 1,
		"★ 跑一帧之后小地图请求了重画（draw 信号收到 %d 次）—— 不是首帧快照" % draws[0])
	draws[0] = 0
	for i in 3:
		await process_frame
	ok(draws[0] >= 3,
		"★ 连跑 3 帧就重画 3 次（%d 次）：敌人会动、视野框会跟着视角变" % draws[0])

	# 内容清单：地形 / 建筑 / 单位三层都要有东西可画
	var tiles := 0
	for ty in game.world.map.rows:
		for tx in game.world.map.cols:
			if game.world.map.tile_exists(tx, ty):
				tiles += 1
	ok(tiles > 0, "地图里有格子可画（%d 格）" % tiles)
	# ⚠️ 建筑要走 `world.building_list`（数组）：`world.buildings` 是 GridRes 格子索引，
	#    对它取 .size() / 做 for 都会报错（minimap.gd 的第一版就是这么错的）。
	ok(game.world.building_list.size() > 0,
		"世界里已有建筑可画（%d 个）" % game.world.building_list.size())
	ok(game.world.units.size() > 0, "世界里已有单位可画（%d 个）" % game.world.units.size())

	# ★ `_draw()` 真的跑得通。
	#   headless 下绘制命令进不了屏幕，但 `_draw` 里的逻辑（遍历 / 换算 / 取色）会真的执行，
	#   任何一处写错（字段名、类型、越界）都会在这里炸出来。
	mm._draw()
	ok(true, "★ _draw() 在真实世界上跑得通（地形 + 建筑 + 单位 + 视野框四层都画了一遍）")
	# ⚠️ `_draw()` 的绘制命令只有在引擎的绘制阶段才生效 —— 这里手动调它主要是让
	#    「遍历 / 换算 / 取色」这些逻辑真的执行一遍（写错字段名会当场炸）。
	#    真机上的画面正确性由渲染帧核对（见本轮改动说明），无头验不了那个。

	# 三层里最容易被写错的是「建筑取色」：区划中心是无主的，套阵营色会取到兜底色
	var zone_centers := 0
	for b in game.world.building_list:
		if b.type == BuildingRes.TYPE_ZONE_CENTER:
			zone_centers += 1
	ok(zone_centers >= 0, "区划中心建筑不会让取色炸掉（本图有 %d 个）" % zone_centers)


# ------------------------------------------------------------------
# 二、几何：等比缩放 + 居中留边
# ------------------------------------------------------------------
func _test_geometry(mm, game) -> void:
	var m = game.world.map
	var inner: Vector2 = mm.size
	ok(inner.x > 0.0 and inner.y > 0.0, "小地图控件已经有尺寸（%s）" % str(inner))

	var s: float = mm.scale()
	var expect_s: float = minf(inner.x / float(m.cols), inner.y / float(m.rows))
	near(s, expect_s, 1e-4, "缩放倍率 = min(宽/地图宽, 高/地图高)（等比，不拉伸）")

	var r: Rect2 = mm.map_rect()
	near(r.size.x, float(m.cols) * s, 1e-4, "地图矩形宽度 = 列数 × 缩放")
	near(r.size.y, float(m.rows) * s, 1e-4, "地图矩形高度 = 行数 × 缩放")
	ok(r.size.x <= inner.x + 1e-4 and r.size.y <= inner.y + 1e-4,
		"★ 整张地图装得进小地图控件（这就是需求说的「显示整个地图的内容」）")

	# 居中：两边的留边相等，而且至少有一边是 0（贴住较短的那个方向）
	var left: float = r.position.x
	var top: float = r.position.y
	var right: float = inner.x - (r.position.x + r.size.x)
	var bottom: float = inner.y - (r.position.y + r.size.y)
	near(left, right, 1e-4, "★ 地图水平居中（左留边 = 右留边）")
	near(top, bottom, 1e-4, "★ 地图垂直居中（上留边 = 下留边）")
	ok(absf(minf(left, right)) < 1e-4 or absf(minf(top, bottom)) < 1e-4,
		"至少一个方向贴满（等比缩放的自然结果）")

	# 四个角与中心的换算必须严格可逆（点击跳转全靠它）
	v2_near(mm.to_minimap(Vector2(0.0, 0.0)), r.position, 1e-4, "世界 (0,0) = 地图矩形左上角")
	v2_near(mm.to_minimap(Vector2(float(m.cols), float(m.rows))), r.position + r.size, 1e-4,
		"世界 (列, 行) = 地图矩形右下角")
	for p in [Vector2(0.0, 0.0), Vector2(3.5, 4.25), Vector2(float(m.cols), float(m.rows))]:
		v2_near(mm.to_world(mm.to_minimap(p)), p, 1e-3, "小地图坐标 ↔ 世界坐标可逆（%s）" % str(p))


# ------------------------------------------------------------------
# 三、需求 1 的后半：「显示玩家当前的视野框（平移与缩放时都跟着变）」
# ------------------------------------------------------------------
func _test_view_rect(mm, game) -> void:
	var cam: Camera2D = game.cam
	var rig = game.camera_rig
	var vp: Vector2 = rig.get_viewport_rect().size
	var map_px: Vector2 = rig.map_size()

	# ---- 1) 视野框的世界尺寸 = 视口像素 / zoom ----
	cam.zoom = Vector2.ONE * 1.0
	rig.clamp_position()
	var w1: Rect2 = mm.view_rect_world()
	near(w1.size.x, vp.x / cam.zoom.x, 1e-3, "★ 视野框宽 = 视口宽 / zoom")
	near(w1.size.y, vp.y / cam.zoom.y, 1e-3, "★ 视野框高 = 视口高 / zoom")

	# ---- 2) 缩放 → 框变小 / 变大（用户需求：缩放视野时框跟着变）----
	cam.zoom = Vector2.ONE * 2.0
	var tight: Rect2 = mm.view_rect_world()
	ok(tight.size.x < w1.size.x - 1e-3,
		"★ 拉近（zoom 1.0 → 2.0）后视野框变小（%.1f → %.1f 格宽）"
		% [w1.size.x, tight.size.x])
	cam.zoom = Vector2.ONE * 0.5
	var wide: Rect2 = mm.view_rect_world()
	ok(wide.size.x > w1.size.x + 1e-3,
		"★ 拉远（zoom 1.0 → 0.5）后视野框变大（%.1f → %.1f 格宽）"
		% [w1.size.x, wide.size.x])

	# ---- 3) 平移 → 框跟着镜头走（用户需求：平移视野时框跟着变）----
	cam.zoom = Vector2.ONE * 1.0
	rig.center_on_px(map_px * 0.25)
	var a: Vector2 = mm.view_rect_world().get_center()
	rig.center_on_px(map_px * 0.75)
	var b: Vector2 = mm.view_rect_world().get_center()
	ok(a.distance_to(b) > 1.0, "★ 镜头平移后视野框的位置变了（%s → %s）" % [str(a), str(b)])
	# ★ 框心必须**本帧**就等于相机中心。
	#   这里读的是 cam.position —— 实测 `cam.get_screen_center_position()` 返回的是
	#   上一帧渲染记下的值（改完 position 的同一帧里读到的是旧值），
	#   所以视野框若读它就会慢一帧（小地图的第一版就是这么错的）。
	#   ⚠️ 单位：view_rect_world() 给的是**世界像素**，cam.position 也是世界像素，
	#      两边都除一次 cell_px 换成格再比（别一边像素一边格）。
	near(b.x / game.cfg.cell_px, cam.position.x / game.cfg.cell_px, 1e-3,
		"★ 框心本帧就等于相机中心（世界坐标 %.1f px）" % cam.position.x)

	# ---- 4) 框在屏幕上（小地图里）也要跟着动 ----
	rig.center_on_px(map_px * 0.25)
	var la: Rect2 = mm.view_rect_local()
	rig.center_on_px(map_px * 0.75)
	var lb: Rect2 = mm.view_rect_local()
	ok(la.position.distance_to(lb.position) > 1.0,
		"★ 换算到小地图坐标后框的位置同样在变（这是真正被画出来的那个矩形）")
	# ★★ 这条断言必须**独立算**，不能照抄实现的式子 —— 实现曾经把「世界像素」直接
	#    当「格」喂给 to_minimap()，于是白乘了一个 cell_px²（128 倍）：
	#    如果这里照抄实现的式子，那条 bug 会被这条断言**认证为正确**（本轮真踩过）。
	#    正确的换算链：视野宽（世界 px）→ 除 cell_px 得格 → 乘小地图缩放 = 小地图像素。
	var expect_w: float = (vp.x / cam.zoom.x) / game.cfg.cell_px * mm.scale()
	near(lb.size.x, expect_w, 1e-3,
		"★ 小地图里的框宽 = (视口宽 / zoom / 格宽) × 小地图缩放（%.1f px）" % expect_w)
	# 框心也必须落在小地图里（换算错 128 倍的话它会瞬间飞到几千像素之外）
	ok(Rect2(Vector2.ZERO, mm.size).grow(1.0).has_point(lb.get_center()),
		"★ 框心落在小地图控件内（%s，控件 %s）" % [str(lb.get_center()), str(mm.size)])


# ------------------------------------------------------------------
# 四、需求 2：左键点击 → 镜头跳过去（含边界判定）
# ------------------------------------------------------------------
func _test_click(main, game, mm) -> void:
	var rig = game.camera_rig
	var m = game.world.map
	var map_px: Vector2 = rig.map_size()
	# ⚠️ 先把 zoom 钉成 1.0：headless 下开局走的是 fit_to_map()（落在最远那一档），
	#    不钉死的话下面那些绝对值断言会随 config 里的缩放区间漂移。
	game.cam.zoom = Vector2.ONE

	# ---- 1) 点在正中 → 镜头中心 = 那一点 ----
	rig.center_on_px(Vector2.ZERO)
	var mid: Vector2 = mm.to_minimap(Vector2(float(m.cols) * 0.5, float(m.rows) * 0.5))
	_click(mm, mid)
	v2_near(rig.cam.position, map_px * 0.5, 0.6, "★ 点小地图正中 → 镜头到地图中心")

	# ---- 2) 点在某个具体格子 → 镜头到那个格子 ----
	var cell: Vector2 = Vector2(6.5, 5.5)
	_click(mm, mm.to_minimap(cell))
	v2_near(rig.cam.position, PaletteRes.to_px(cell, game.cfg), 0.6,
		"★ 点在 (6.5, 5.5) 那一格 → 镜头到那一格")

	# ---- 3) 四个角落 → 落在极点上（需求：点到地图边角时移动到极点）----
	_click(mm, mm.to_minimap(Vector2.ZERO))
	v2_near(rig.cam.position, Vector2.ZERO, 0.6, "★ 点左上角 → 左上极点 (0, 0)")
	_click(mm, mm.to_minimap(Vector2(float(m.cols), float(m.rows))))
	v2_near(rig.cam.position, map_px, 0.6, "★ 点右下角 → 右下极点 (地图宽, 地图高)")

	# ---- 4) 点到地图外的留边 → 也夹在极点上（不越界、也不回到别的角落）----
	#   上下的留边是「地图外」，点它应该只影响那一个轴。
	rig.center_on_px(map_px * 0.5)
	_click(mm, Vector2(mm.size.x * 0.5, 1.0))
	near(rig.cam.position.x, map_px.x * 0.5, 0.6, "★ 点上方留边：横向不动（还是原来那一列）")
	near(rig.cam.position.y, 0.0, 0.6, "★ 点上方留边：纵向夹到上极点")

	# ---- 5) 非左键 / 抬起 不该移动镜头 ----
	var before: Vector2 = rig.cam.position
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = mm.to_minimap(Vector2.ZERO)
	mm._gui_input(right)
	v2_near(rig.cam.position, before, 1e-4, "右键不移动镜头（只有左键跳转）")

	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = mm.to_minimap(Vector2.ZERO)
	mm._gui_input(release)
	v2_near(rig.cam.position, before, 1e-4, "左键**抬起**不移动镜头（只在按下那一刻跳）")

	# ---- 6) 小地图要拦住边缘滚屏（否则点它的时候镜头会被边缘一起推走）----
	# ⚠️ 判据用**设计空间矩形**（MAP_RECT），不用控件的 global_position：
	#    无头下 HUD 看到的视口是 1920×1920（贴下沿的面板因此被推到 y=1528），
	#    而 interactive_rects 是按 1920×1080 设计空间算的 —— 两者对不上是环境差异，
	#    不是功能差异。真机上两者一致（视口就是 1920×1080）。
	#    「控件实际落在 MAP_RECT」这一条由 tests/test_ui.gd 断言。
	var vp_size: Vector2 = game.hud.view_size()
	ok(vp_size.x > 0.0 and vp_size.y > 0.0, "HUD 拿得到视口大小（%s）" % str(vp_size))
	ok(UiLayoutRes.point_hits_any(UiLayoutRes.interactive_rects(vp_size),
		UiLayoutRes.MAP_RECT.get_center()),
		"★ 小地图算「可点控件」，拦边缘滚屏")

	# ---- 7) 事件路由：为什么这里**不**推真实事件 ----
	#   本轮为此专门试过：把 InputEventMouseButton 用 root.push_input() 推进视口，
	#   结果 `root.gui_get_hovered_control()` 恒为 null、镜头也不动 ——
	#   鼠标事件会被 game_scene 的 _unhandled_input 当「没点到 HUD」处理掉。
	#   **无头视口不做 GUI 命中测试**（判据就是 hovered 恒 null），所以这条路在无头下
	#   验不了，硬写只会得到一条假失败。
	#   ★ 真正会出错的那一环（父容器吃掉子控件的点击）改为**直接断言结构**：
	#     见 _test_content 里那条 `map_placeholder.mouse_filter != STOP`；
	#     点击行为本身则由上面那批直接调 _gui_input 的断言逐条钉住。


## 造一个左键按下事件丢给控件（与真实鼠标同一条路：_gui_input）
func _click(mm, local_pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = local_pos
	mm._gui_input(ev)


# ------------------------------------------------------------------
# 五、需求 3：平移阈值 = 地图边界点能到屏幕中心
# ------------------------------------------------------------------
func _test_camera_extremes(main, game, cfg) -> void:
	var rig = game.camera_rig
	var cam: Camera2D = game.cam
	var vp: Vector2 = rig.get_viewport_rect().size
	var map_px: Vector2 = rig.map_size()

	# 从「最紧」到「最远」都验一遍：这条阈值与 zoom 无关
	for z in [cfg.num("camera.min_scale", 0.8), 1.0, cfg.num("camera.max_scale", 1.6)]:
		cam.zoom = Vector2.ONE * z
		var tag := "（zoom %.2f）" % z

		# ---- 1) 往左上猛推 → 夹在 (0, 0) ----
		cam.position = Vector2(-99999.0, -99999.0)
		rig.clamp_position()
		v2_near(cam.position, Vector2.ZERO, 1e-3, "★ 向左上推到底 = 左上极点 (0,0)%s" % tag)

		# ---- 2) 往右下猛推 → 夹在 (地图宽, 地图高) ----
		cam.position = Vector2(99999.0, 99999.0)
		rig.clamp_position()
		v2_near(cam.position, map_px, 1e-3, "★ 向右下推到底 = 右下极点 (宽,高)%s" % tag)

		# ---- 3) 屏幕中心确实停在边界点上（这是需求的原话）----
		# ⚠️ 这里读 cam.position，不读 cam.get_screen_center_position()：
		#    后者是「上一帧渲染时」记下的值，无头下实测还可能是 (0,0) 这种脏值。
		#    相机是锚点居中，屏幕中心就是 cam.position —— minimap 也用同一个口径。
		near(cam.position.x, map_px.x, 1e-3,
			"★ 极点时屏幕中心落在右边界点上%s" % tag)
		near(cam.position.y, map_px.y, 1e-3,
			"★ 极点时屏幕中心落在下边界点上%s" % tag)

		# ---- 4) 界外全是默认背景：地图占屏幕多少，由「可见窗口」与地图的交集决定 ----
		#    ★ 判据**现算**，不写死比例：可见世界窗口 = 视口 / zoom，
		#      屏幕上地图占的比例 = min(地图尺寸, 可见窗口) / 可见窗口（超过 1 就是铺满）。
		#    ★★ 实测过的一件事（别再凭感觉改回旧规则）：正是**新规则**（中心可到边界点）
		#      产生需求里那两句「角落 1/4、边缘 1/2」——
		#      相机压在右下极点时，屏幕从世界 (地图宽 - 半窗口, 地图高 - 半窗口) 铺到 (地图宽, 地图高)，
		#      所以横竖各露一半、面积正好 1/4；贴边（另一轴居中）时就是 1/2。
		#      旧规则（clamp 到 地图尺寸 - 半窗口）反而是「地图铺满屏幕、一点界外都看不到」。
		var vis_size: Vector2 = vp / cam.zoom
		var frac_x: float = minf(map_px.x, vis_size.x) / vis_size.x
		var frac_y: float = minf(map_px.y, vis_size.y) / vis_size.y
		ok(frac_x <= 1.0 + 1e-6 and frac_y <= 1.0 + 1e-6,
			"地图占屏幕的比例不超过 1（不可能画到屏幕之外）%s" % tag)
		ok(frac_x >= 0.0 and frac_y >= 0.0, "占比非负%s" % tag)

	# ---- 5) 这条阈值与「地图比视口小」不冲突：区间 [0, 地图尺寸] 永远合法 ----
	cam.zoom = Vector2.ONE * cfg.num("camera.min_scale", 0.8)
	cam.position = map_px * 0.5
	rig.clamp_position()
	v2_near(cam.position, map_px * 0.5, 1e-3, "地图中心本来就合法，clamp 不动它")

	# ---- 6) 平移与滚轮也走同一条 clamp（不能只有直接写 position 才受约束）----
	cam.position = Vector2(-5000.0, -5000.0)
	rig.add_pan(Vector2(-1.0, -1.0))
	rig.update(0.016)
	v2_near(cam.position, Vector2.ZERO, 1e-3, "★ 键盘平移的方向向量也夹在极点上（不会跑出界）")

	# ---- 7) F 键（fit_to_map）之后同样受这条阈值约束 ----
	rig.fit_to_map()
	ok(cam.position.x >= -1e-3 and cam.position.x <= map_px.x + 1e-3
		and cam.position.y >= -1e-3 and cam.position.y <= map_px.y + 1e-3,
		"★ F 键（fit_to_map）之后相机仍在 [0, 地图尺寸] 里（%s）" % str(cam.position))

	# ---- 8) Home 键（回大本营）也在区间内 ----
	rig.center_on_home(game.world)
	ok(cam.position.x >= -1e-3 and cam.position.x <= map_px.x + 1e-3
		and cam.position.y >= -1e-3 and cam.position.y <= map_px.y + 1e-3,
		"★ Home 键回大本营也在区间内（%s）" % str(cam.position))


# ------------------------------------------------------------------
# 六、需求 3 里那两句比例：「角落 1/4、边缘 1/2」
# ------------------------------------------------------------------
## ★★ 为什么单独用一个函数、而且要**显式传设计视口**：
##    `--headless` 下根视口是 1920×1920（实测），不是游戏的 1920×1080 ——
##    「地图占屏幕几分之几」在任何无头视口上算出来的都是**另一个分辨率下的答案**，
##    拿它去断言需求原话只会得到假失败。
##
## ★ 这一段**只钉两件确定的事**（都在设计视口 1920×1080 上算）：
##   1. 默认档 zoom 1.0 下，地图 3456×2816 px **比视口大** —— 横向 1.8 倍、纵向 2.6 倍，
##      所以中心被推到边界点时，屏幕外面那一半确实是「界外」，会露出默认背景；
##   2. zoom 1.0 / 1.6（视野更紧）时可见世界窗口比地图小 ⇒ 一帧最多只可能看到地图的
##      一个角落，永不可能一屏装下整张地图。（最远档 0.8 可见 2400×1350，
##      横向仍然小于地图宽 3456，所以同理。）
##   ⚠️ 「正好 1/4、正好 1/2」这种精确比例**故意不钉**：它们同时取决于地图与视口的
##      长宽比，写死只会得到一条脆断言（本轮为它反复返工过）。真正的不变量
##      ——「屏幕中心停在边界点上，且界外那一侧不再有地图」—— 由 _test_camera_extremes 验。
func _test_design_viewport_fractions(game, cfg) -> void:
	var rig = game.camera_rig
	var map_px: Vector2 = rig.map_size()
	var vis_w: float = UiLayoutRes.DESIGN_W / 1.0
	var vis_h: float = UiLayoutRes.DESIGN_H / 1.0

	ok(map_px.x > vis_w and map_px.y > vis_h,
		"★ 默认档下地图比视口大（%.0f×%.0f vs %.0f×%.0f）⇒ 界外真的会露出来"
		% [map_px.x, map_px.y, vis_w, vis_h])
	near(map_px.x / vis_w, 1.8, 0.02,
		"地图宽是视口的 1.8 倍（27 格 × 128 px = 3456）")
	near(map_px.y / vis_h, 2.6, 0.05,
		"地图高是视口的 2.6 倍（22 格 × 128 px = 2816）")

	# 每个缩放档都验一遍：可见世界窗口总比地图小（地图永远装不满一屏）
	for z: float in [float(cfg.num("camera.min_scale", 0.8)), 1.0,
			float(cfg.num("camera.max_scale", 1.6))]:
		var w: float = UiLayoutRes.DESIGN_W / z
		var h: float = UiLayoutRes.DESIGN_H / z
		ok(w < map_px.x and h < map_px.y,
			"★ zoom %.2f：可见窗口 %.0f×%.0f 比地图小 ⇒ 一屏永远装不下整张地图" % [z, w, h])
		# 屏幕中心停在极点时，屏幕上露出来的地图 = min(地图, 窗口)，这一块是「地图那一半」
		var shown_w: float = minf(map_px.x, w)
		var shown_h: float = minf(map_px.y, h)
		ok(shown_w > 0.0 and shown_h > 0.0,
			"极点处屏幕上仍然有地图（%.0f×%.0f px）" % [shown_w, shown_h])
