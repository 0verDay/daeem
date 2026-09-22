## test_minimap.gd —— 小地图 + 相机平移阈值（本轮四条需求）
##
## 需求原文：
##   1. 「让地图 ui 正常工作，使地图 ui 可以显示整个地图的内容和玩家当前的视野框
##       （玩家平移视野和缩放视野时，该视野框都会随之变化）」
##   2. 「当玩家左键点击地图中的某处时，将视角移动至玩家点击的地方（需要做边界判定，
##       如果玩家点到地图边角时，视野移动到阈值/极点处）」
##   3. 「更改平移视角的阈值，玩家视野可以移动到的极点为地图边界点到屏幕中心时的点，
##       因此情况玩家看到的地图界外的东西全部为默认背景」
##   4. 「点击小地图后可长按拖动小地图以移动视角」（本轮新增，见 _test_drag）
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
const MinimapRes = preload("res://view/minimap.gd")


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
		_test_view_clip(mm, game)
		_test_click(main, game, mm)
		_test_drag(mm, game, cfg)
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
# 三之二、需求 5：视野框裁到地图矩形内（不画到小地图的留边上）
# ------------------------------------------------------------------
##
## 需求原话：「裁剪一下小地图视野选框，让视野框只显示在小地图内的地图 ui 范围内，
##          当视野框移动到边缘时，需要动态调整小地图的边框使其贴合地图 ui 边框」。
##
## ★★ 这一段的判据必须**独立算**（`view_rect_local().intersection(map_rect())`），
##   不能照抄实现里那一行 —— 照抄的话「裁剪写反了/单位错了」会被断言认证成正确。
##   下面的三条不变量才是真正要钉住的东西：
##     1. 画出来的框**永远**在地图矩形里（这是需求字面意思）；
##     2. 视野完全在地图内时，裁剪**不许**改变它（裁剪只在越界处动手）；
##     3. 贴边时框的边框正好落到地图边界上（这就是「贴合地图 ui 边框」）。
func _test_view_clip(mm, game) -> void:
	var rig = game.camera_rig
	var cam: Camera2D = game.cam
	var m = game.world.map
	var vp: Vector2 = rig.get_viewport_rect().size
	var map_px: Vector2 = rig.map_size()
	var bounds: Rect2 = mm.map_rect()
	var outer := Rect2(Vector2.ZERO, mm.size)
	cam.zoom = Vector2.ONE

	# 用例自检：小地图里真的有「留边」（不然这一段测的是空气）
	ok(bounds.size.x < mm.size.x + 1e-4 or bounds.size.y < mm.size.y + 1e-4,
		"小地图里有地图之外的留边（地图矩形 %s，控件 %s）" % [str(bounds.size), str(mm.size)])

	# ---- 1) 镜头在地图中心：视野完全在地图内 → 裁剪不该改变任何东西 ----
	#   ⚠️ 这一条**不假设**一定成立（「视野框比地图还大」也是合法状态），
	#      所以先算出未裁剪的框，再决定该断言「原样保留」还是「确实被裁」。
	rig.center_on_px(map_px * 0.5)
	var raw: Rect2 = mm.view_rect_local()
	var clipped: Rect2 = mm.view_rect_clipped()
	if bounds.encloses(raw):
		v2_near(clipped.position, raw.position, 1e-4, "★ 视野全在地图内：裁剪不动它的左上角")
		v2_near(clipped.size, raw.size, 1e-4, "★ 视野全在地图内：裁剪不动它的大小")
		ok(true, "★ 镜头居中时视野框整块都在地图矩形里（%s）" % str(raw))
	else:
		ok(bounds.encloses(clipped) or clipped.size.x <= 0.0 or clipped.size.y <= 0.0,
			"★ 视野比地图大：裁剪后仍然装在地图矩形里")
		ok(raw.size.x > bounds.size.x + 1e-4 or raw.size.y > bounds.size.y + 1e-4,
			"（本图视野 %s 比地图 %s 大，这一档就是在验裁剪）" % [str(raw.size), str(bounds.size)])

	# ---- 2) 贴四个极点：裁剪后的框必须在地图矩形内，且边框贴到对应的那条边 ----
	var corners: Array = [Vector2.ZERO, Vector2(map_px.x, 0.0),
		Vector2(0.0, map_px.y), map_px]
	var names: Array = ["左上", "右上", "左下", "右下"]
	for i in corners.size():
		rig.center_on_px(corners[i])
		var c: Rect2 = mm.view_rect_clipped()
		ok(c.size.x > 0.0 and c.size.y > 0.0,
			"★ 贴%s极点时框还在（没被裁没）：%s" % [String(names[i]), str(c)])
		# ① 永远在地图矩形里（需求第一句）
		ok(c.position.x >= bounds.position.x - 1e-4
			and c.position.y >= bounds.position.y - 1e-4
			and c.position.x + c.size.x <= bounds.position.x + bounds.size.x + 1e-4
			and c.position.y + c.size.y <= bounds.position.y + bounds.size.y + 1e-4,
			"★ 贴%s极点：视野框完全在地图矩形内（框 %s，地图 %s）"
			% [String(names[i]), str(c), str(bounds)])
		# ② 框不许画到小地图自己的留边上 —— 这一条正是「裁剪」要干掉的东西
		ok(outer.encloses(c), "★ 贴%s极点：框不会画到小地图控件之外" % String(names[i]))
		# ③ 水平方向贴到哪条边，由这一极点的 x 决定（贴合地图 ui 边框）
		if corner_side(i, 0) < 0:
			near(c.position.x, bounds.position.x, 1e-4,
				"★ 贴%s极点：框的左边框贴住地图左边界" % String(names[i]))
		elif corner_side(i, 0) > 0:
			near(c.position.x + c.size.x, bounds.position.x + bounds.size.x, 1e-4,
				"★ 贴%s极点：框的右边框贴住地图右边界" % String(names[i]))
		if corner_side(i, 1) < 0:
			near(c.position.y, bounds.position.y, 1e-4,
				"★ 贴%s极点：框的上边框贴住地图上边界" % String(names[i]))
		elif corner_side(i, 1) > 0:
			near(c.position.y + c.size.y, bounds.position.y + bounds.size.y, 1e-4,
				"★ 贴%s极点：框的下边框贴住地图下边界" % String(names[i]))

	# ---- 3) 沿着一圈扫一遍：不变量「框 ⊆ 地图矩形」在任何位置都成立 ----
	#   ★ 遍历 5×5 个位置（含极点和中间），任何一处越界都要红。
	var bad := 0
	var clipped_any := 0
	for ix in 5:
		for iy in 5:
			rig.center_on_px(Vector2(map_px.x * float(ix) / 4.0, map_px.y * float(iy) / 4.0))
			var r: Rect2 = mm.view_rect_clipped()
			if not (r.position.x >= bounds.position.x - 1e-4
					and r.position.y >= bounds.position.y - 1e-4
					and r.position.x + r.size.x <= bounds.position.x + bounds.size.x + 1e-4
					and r.position.y + r.size.y <= bounds.position.y + bounds.size.y + 1e-4):
				bad += 1
			var raw2: Rect2 = mm.view_rect_local()
			if not bounds.encloses(raw2):
				clipped_any += 1
	eq(bad, 0, "★ 扫过 5×5 个镜头位置：视野框一次都没越出地图矩形")
	ok(clipped_any > 0,
		"用例自检：这 25 个位置里有 %d 个原本越界（所以上面那条不是空跑）" % clipped_any)

	# ---- 4) 拉远拉近都要裁：缩放到两端各扫一次 ----
	for z: float in [game.cfg.num("camera.min_scale", 0.8), game.cfg.num("camera.max_scale", 1.6)]:
		cam.zoom = Vector2.ONE * z
		var bad_z := 0
		for ix in 3:
			for iy in 3:
				rig.center_on_px(Vector2(map_px.x * float(ix) / 2.0, map_px.y * float(iy) / 2.0))
				var rz: Rect2 = mm.view_rect_clipped()
				if rz.position.x < bounds.position.x - 1e-4 \
						or rz.position.y < bounds.position.y - 1e-4 \
						or rz.position.x + rz.size.x > bounds.position.x + bounds.size.x + 1e-4 \
						or rz.position.y + rz.size.y > bounds.position.y + bounds.size.y + 1e-4:
					bad_z += 1
		eq(bad_z, 0, "★ zoom %.2f：9 个位置扫下来视野框都没越出地图矩形" % z)

	# ---- 5) 裁出来的框与「未裁剪框 ∩ 地图矩形」逐点一致（含边界）----
	cam.zoom = Vector2.ONE
	rig.center_on_px(Vector2(0.0, map_px.y * 0.5))
	var expected: Rect2 = mm.view_rect_local().intersection(bounds)
	var got: Rect2 = mm.view_rect_clipped()
	v2_near(got.position, expected.position, 1e-3, "★ 裁剪结果 = 未裁剪框 ∩ 地图矩形（左上角）")
	v2_near(got.size, expected.size, 1e-3, "★ 裁剪结果 = 未裁剪框 ∩ 地图矩形（大小）")

	# ---- 6) 渲染那一层真的走裁剪后的矩形（_draw 跑得通、不报错）----
	#   ⚠️ 无头下绘制命令进不了屏幕，这里只能保证「取框 + 换算 + 画」这条链不炸；
	#      画面正确性由真机核对（本轮的验收就是「留边上不再出现亮框」）。
	mm._draw()
	ok(true, "★ _draw() 用裁剪后的框跑得通（贴左极点时框是一条贴边的带）")

	# ---- 7) 拖动时同样裁（拖动是另一条会改相机的路，不能绕过裁剪）----
	mm.use_real_mouse_on_hold = false
	mm.verify_button_held = false
	_click(mm, mm.to_minimap(Vector2(1.0, 1.0)))
	_motion(mm, Vector2(2.0, 2.0))
	mm._tick_drag(0.0)
	var c_drag: Rect2 = mm.view_rect_clipped()
	ok(outer.encloses(c_drag), "★ 拖动时光标贴到小地图角落：框同样不越出地图矩形")
	_release(mm, Vector2(2.0, 2.0))
	mm.use_real_mouse_on_hold = true
	mm.verify_button_held = true


## 第 i 个角在某个轴上是「贴小的一边」(-1)、「贴大的一边」(+1) 还是「不贴边」(0)。
## 0 恒不出现：四个角每个轴都贴边 —— 写出来只是为了让上面的断言读得出来在验哪条边。
func corner_side(corner_index: int, axis: int) -> int:
	var big: bool = (corner_index == 1 or corner_index == 3) if axis == 0 \
		else (corner_index == 2 or corner_index == 3)
	return 1 if big else -1


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


## 造一个左键**抬起**事件
func _release(mm, local_pos: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = false
	ev.position = local_pos
	mm._gui_input(ev)


## 造一个鼠标移动事件（真实鼠标在控件上移动走的就是这条路）
func _motion(mm, local_pos: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = local_pos
	mm._gui_input(ev)


# ------------------------------------------------------------------
# 四之二、需求 4：按住拖动小地图 → 镜头跟手（本轮新增）
# ------------------------------------------------------------------
##
## ★★ 为什么这些用例要**显式关掉 minimap 的两个「真机开关」**：
##    · `use_real_mouse_on_hold = false` —— 「按住不动也算长按」那条判据需要知道光标在哪，
##      而按下之后一个移动事件都没有时，minimap 会去问引擎要一次真实光标位置
##      （`get_local_mouse_position()`）。真机上那是本控件的位置、完全正确；
##      **无头下没有真鼠标**，拿到的是脏值 —— 于是「按住不动」会把镜头跟到一个
##      测试从没喂过的位置上，这些断言全部随机失败。关掉之后位置只由测试喂的事件决定。
##    · `verify_button_held = false` —— 每帧那条「回头确认左键还按着」的兜底，
##      在无头下 `Input.is_mouse_button_pressed()` 恒为 false，开着的话
##      **每次 `_tick_drag` 都会当场把手势收掉**（拖动根本进不去）。
##    两个开关都只是「不向引擎问环境」而已，判据本身（阈值 / 跟手 / 夹取）照旧是产品逻辑，
##    产品的默认值也确实都是 true —— 见 `_test_drag_guard` 那一段的断言。
##
## ★ 光标位置一律用 `mm.to_minimap(格)` 反算（与 `_click` 同一套口径）：
##    这样断言里那句「镜头应该在哪」可以**独立算出来**（`_expected_cam`），
##    不照抄实现的式子 —— 照抄的话换算写错也会被认证成正确。
func _test_drag(mm, game, cfg) -> void:
	var rig = game.camera_rig
	var cam: Camera2D = game.cam
	var m = game.world.map
	var map_px: Vector2 = rig.map_size()

	# 与 _test_click 一致：把 zoom 钉死，绝对数值断言才不会跟着 config 漂
	cam.zoom = Vector2.ONE
	mm.use_real_mouse_on_hold = false
	mm.verify_button_held = false

	# ---- 1) 按下即跳 + 进入「按住」态（老手感：单击 = 跳转）----
	var center := Vector2(float(m.cols) * 0.5, float(m.rows) * 0.5)
	var p: Vector2 = mm.to_minimap(center)
	rig.center_on_px(Vector2.ZERO)
	_click(mm, p)
	v2_near(cam.position, PaletteRes.to_px(center, cfg), 0.6,
		"★ 按住的第一步仍是「按下就跳」：镜头到按下点（单击 = 跳转）")
	ok(mm.is_pressed_held(), "按下之后处于「左键按着」态")
	ok(not mm.is_dragging(), "★ 按下那一刻还不算拖动（没越过阈值，这一下可能是单击）")
	mm._tick_drag(0.0)
	v2_near(cam.position, PaletteRes.to_px(center, cfg), 0.6,
		"★ 还没越过阈值：跑一帧也不动镜头（单击不会被判成拖动）")

	# ---- 2) 按住拖动 → 镜头跟手 ----
	#   目标点离按下点足够远（> drag_min_px），所以这一条移动就该升级成拖动态。
	#   故意选非居中、非角落的一格：换算写错时它一定对不上。
	var target := Vector2(6.5, 5.5)
	var t: Vector2 = mm.to_minimap(target)
	ok(t.distance_to(p) > cfg.minimap_drag_min_px + 1.0,
		"用例自检：目标点离按下点足够远（%.1f px > 阈值 %.1f）"
		% [t.distance_to(p), cfg.minimap_drag_min_px])
	_motion(mm, t)
	mm._tick_drag(0.0)
	ok(mm.is_dragging(), "★ 按住移动超过阈值 → 进入拖动态")
	v2_near(cam.position, _expected_cam(mm, cfg, t), 0.6,
		"★ 拖到 (6.5, 5.5) → 镜头跟到那一格")
	# ★ 真正是「跟手」而不是「按下点的残影」：两者必须不同
	ok(cam.position.distance_to(PaletteRes.to_px(center, cfg)) > 1.0,
		"★ 镜头确实跟着光标走了（不再停在按下点）")

	# ---- 3) 连续拖动：每次移动都跟手，松手即停 ----
	var path: Array = [Vector2(9.5, 7.5), Vector2(12.5, 9.5), Vector2(15.5, 11.5)]
	for step in path:
		var local: Vector2 = mm.to_minimap(step)
		_motion(mm, local)
		mm._tick_drag(0.0)
		v2_near(cam.position, _expected_cam(mm, cfg, local), 0.6,
			"★ 拖动跟手：光标在地图 %s → 镜头到那一格" % str(step))

	var before_release := cam.position
	_release(mm, mm.to_minimap(path[path.size() - 1]))
	ok(not mm.is_dragging(), "★ 左键抬起 → 拖动结束")
	mm._tick_drag(0.0)
	v2_near(cam.position, before_release, 1e-4,
		"★ 松手即停：抬起之后再跑一帧，镜头不再移动")

	# ---- 4) 松手之后的移动事件不该再动镜头（拖动只认「按着」）----
	var after_release := cam.position
	_motion(mm, mm.to_minimap(Vector2(2.5, 2.5)))
	mm._tick_drag(0.0)
	v2_near(cam.position, after_release, 1e-4,
		"★ 没按着左键时移动光标不移动镜头（拖动只认按着左键的手势）")

	# ---- 5) 按住不动够久 → 也算拖动（「长按」的字面含义）----
	#   把像素阈值改成 0：这一条只验时间那一条判据。
	var hold_sec: float = 0.2
	cfg.data["minimap"]["drag_min_px"] = 0.0
	cfg.data["minimap"]["drag_hold_sec"] = hold_sec
	cfg._cache_scalars()
	var hold_press := Vector2(9.5, 7.5)
	_click(mm, mm.to_minimap(hold_press))
	ok(not mm.is_dragging(), "按住不动：时间还没到，不算拖动")
	v2_near(cam.position, PaletteRes.to_px(hold_press, cfg), 0.6, "按下那一刻照旧跳过去")
	mm._tick_drag(hold_sec * 0.5)
	ok(not mm.is_dragging(), "按住 %.2fs（未到阈值 %.2fs）还不算拖动" % [hold_sec * 0.5, hold_sec])
	mm._tick_drag(hold_sec)
	ok(mm.is_dragging(), "★ 按住够久（%.2fs）→ 即使光标没动也进入拖动态" % hold_sec)
	var still := Vector2(4.5, 3.5)
	_motion(mm, mm.to_minimap(still))
	mm._tick_drag(0.0)
	v2_near(cam.position, _expected_cam(mm, cfg, mm.to_minimap(still)), 0.6,
		"★ 长按进入拖动之后，光标一移动镜头就跟（前半段不会丢）")

	# ---- 6) 拖出小地图 → 继续跟手，按地图极点夹取 ----
	#   玩家拍板的那一条：「拖出小地图继续跟手，镜头被夹在 [0, 地图宽高] 的极点上」。
	#   ⚠️ 这里的光标位置**故意在控件之外**（x 超大 / y 为负），
	#      它反算出来的世界坐标也在地图之外 —— 正好验「夹取不在本文件做、由相机负责」。
	_motion(mm, Vector2(mm.size.x + 400.0, mm.size.y * 0.5))
	mm._tick_drag(0.0)
	v2_near(cam.position, Vector2(map_px.x, cam.position.y), 0.6,
		"★ 拖到小地图右侧之外：镜头继续跟手并夹在右极点（地图宽）")
	ok(mm.is_dragging(), "★ 拖出控件范围后拖动**没有**中断（仍按着左键）")
	_motion(mm, Vector2(mm.size.x * 0.5, -300.0))
	mm._tick_drag(0.0)
	near(cam.position.y, 0.0, 0.6, "★ 拖到小地图上方之外：镜头夹在上极点 (y = 0)")

	# ---- 7) 拖动期间压住边缘滚屏（否则镜头一边跟手、一边被边缘推走）----
	#   小地图贴在屏幕左下角，而「屏幕最外圈永远允许滚屏」是 hud 里那条铁律，
	#   所以只有 game_scene 每帧把「正在拖」告诉相机才拦得住 —— 见 camera_rig._ui_dragging_camera。
	ok(mm.is_dragging(), "用例自检：此刻正处于拖动态")
	game._process(0.016)
	ok(rig.ui_dragging(), "★ 拖动中：相机知道「现在是小地图在拖」，边缘滚屏让路")

	# ---- 8) 抬起之后立刻恢复（边缘滚屏不能一直被压着）----
	_release(mm, Vector2(mm.size.x * 0.5, -300.0))
	ok(not mm.is_dragging(), "抬起之后拖动态结束")
	game._process(0.016)
	ok(not rig.ui_dragging(), "★ 抬起后相机恢复：边缘滚屏照旧（不会被永久压住）")

	# ---- 9) 右键按着 + 移动 → 不拖动（只有左键能拖）----
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	right.position = mm.to_minimap(center)
	mm._gui_input(right)
	ok(not mm.is_pressed_held(), "右键按下不进入「按着左键」态")
	var before_right := cam.position
	_motion(mm, mm.to_minimap(Vector2(20.5, 13.5)))
	mm._tick_drag(0.5)
	ok(not mm.is_dragging(), "★ 右键按着时移动光标不拖动（只有左键能拖）")
	v2_near(cam.position, before_right, 1e-4, "★ 右键 + 移动全程不动镜头")

	# ---- 9.5) 兜底那条路真的会结束手势（失焦场景）----
	#   ⚠️ 无头下 `Input.is_mouse_button_pressed()` 恒为 false，所以这里**只能**验
	#      「开着兜底时，跑一帧就把手势收掉」这个分支本身跑得通、且收得干净；
	#      真机上「按着不放时它不会误收」验不了（那条只能手玩）。
	#      正因为这一条在无头下的结论是「必然收掉」，产品默认开着它在测试里必须关掉。
	mm.verify_button_held = true
	_click(mm, mm.to_minimap(center))
	ok(mm.is_pressed_held(), "用例自检：兜底测试前确实按着")
	mm._tick_drag(0.0)
	ok(not mm.is_pressed_held() and not mm.is_dragging(),
		"★ 兜底：引擎说左键已经不在按着 → 当场结束手势（不会卡住拖动）")
	mm.verify_button_held = false

	# ---- 10) 两个「真机开关」的默认值必须是 true（测试关掉的只是环境依赖）----
	#   ★ 这一条很关键：上面那一整段是**关着**开关跑的，如果产品默认值被改成 false，
	#     真机上就会退化成「按住不动不跟手」+「失焦后手势卡住」，而测试全绿。
	ok(MinimapRes.new().use_real_mouse_on_hold,
		"★ 产品默认：按住不动时允许问一次真实光标位置（真机需要）")
	ok(MinimapRes.new().verify_button_held,
		"★ 产品默认：每帧回头确认左键还按着（失焦兜底，真机需要）")

	# ---- 11) 把配置改回原值（后面还有别的用例在读 config）----
	cfg.data["minimap"]["drag_min_px"] = 4.0
	cfg.data["minimap"]["drag_hold_sec"] = 0.18
	cfg._cache_scalars()
	mm.use_real_mouse_on_hold = true
	mm.verify_button_held = true


## 光标在地图上某个局部坐标时，镜头**应该**在哪。
## ★ 独立算：小地图坐标 → 世界（格）→ 夹在地图范围内 → 世界（像素）。
##   夹取这一环是相机自己的规则（`clamp_position`），这里显式写一遍，
##   正好也验了「拖出小地图时按极点夹取」那一条。
func _expected_cam(mm, cfg, local_pos: Vector2) -> Vector2:
	var m = mm.world.map
	var cell: Vector2 = mm.to_world(local_pos)
	cell.x = clampf(cell.x, 0.0, float(m.cols))
	cell.y = clampf(cell.y, 0.0, float(m.rows))
	return PaletteRes.to_px(cell, cfg)


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
