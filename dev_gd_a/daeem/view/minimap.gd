## minimap.gd —— 左下角的小地图（需求：显示整张地图 + 玩家当前的视野框 + 左键点击跳转）
##
## 替代原来那个「灰块 + 地图两个大字」的占位（`hud._build_minimap`）。
##
## 三件事，各自只有一条路：
##   1. **画**：整张地图的地形 / 建筑 / 单位，全部由 `_draw()` 一次画完 ——
##      它每帧都在变（单位在走），学 unit_view.gd 那条「一个节点画全部」的做法，
##      而不是每格一个节点（docs/pitfalls.md 2.3）。
##   2. **视野框**：从**相机**读 `zoom` 与 `position`，
##      算出「屏幕现在覆盖世界上的哪一块」，换算成小地图里的白色描边矩形。
##      平移、缩放、F 键、Home 键——任何改相机的途径都会让这个框跟着动，
##      因为这里读的是相机的**当前值**，不是任何一份「谁改了相机」的通知。
##   3. **左键跳转**：把小地图坐标反算回世界坐标，交给 `camera_rig.center_on_px()`。
##      边界判定**不在这里做** —— 相机自己会 clamp（`clamp_position`），
##      所以点到角落 = 走到极点，点到地图外的留边 = 走到最近的那条边界。
##
## ★ 只读逻辑状态 + 只写相机（相机是纯表现，见 architecture.md 第五节）。
##   本文件不碰 world 的任何字段，也不发命令。
##
## ★★ 坐标系：本控件左上角 = 小地图左上角，局部坐标 (0,0)..(size)。
##   地图等比缩放后**居中**（地图不是正方形，硬拉伸会让地形比例失真）：
##     scale   = min(控件宽 / 地图宽, 控件高 / 地图高)   ← 世界（格）→ 小地图（px）
##     origin  = 居中留边后的左上角
##   于是「小地图坐标 = origin + 世界坐标(格) × scale」，反算就是减 origin 再除 scale。
extends Control

const ConfigRes = preload("res://logic/config.gd")
const PaletteRes = preload("res://view/palette.gd")
const BuildingRes = preload("res://logic/building.gd")

## 视野框：里面叠一层很淡的白（让「我现在看的是这一块」一眼可见），外面描一圈亮白边。
const VIEW_FILL := Color(1.0, 1.0, 1.0, 0.13)
const VIEW_LINE := Color(1.0, 1.0, 1.0, 0.95)
const VIEW_LINE_W := 2.0

## 单位点与小方块的尺寸（小地图像素）。地图 27 格宽、控件 400 宽时，
## 1 格 ≈ 14.8 px，所以这些数都在「一格的十分之一」量级 —— 看得出来，又不糊成一片。
const UNIT_R := 2.4
const MIN_BUILDING := 3.0

var cfg: ConfigRes = null
var world = null
var camera_rig = null

## 地形配色（与 terrain_view.gd 同一份 colors.*，两边一眼对得上）
var _c_grass: Color
var _c_grass_alt: Color
var _c_forest: Color
var _c_mountain: Color
## 阵营 → 主体色。每帧每单位查一次的东西，缓存成一次查表（同 unit_view.gd）
var _color_cache: Dictionary = {}


func setup(p_cfg: ConfigRes, p_world, p_camera_rig) -> void:
	cfg = p_cfg
	world = p_world
	camera_rig = p_camera_rig
	mouse_filter = Control.MOUSE_FILTER_STOP      # 点在小地图上 = 移动镜头，不许穿到地图上
	focus_mode = Control.FOCUS_NONE
	_c_grass = cfg.color("grass")
	_c_grass_alt = cfg.color("grass_alt")
	_c_forest = cfg.color("forest")
	_c_mountain = cfg.color("mountain")
	_color_cache = {}


# ------------------------------------------------------------------
# 几何：世界（格） ↔ 小地图（局部像素）
# ------------------------------------------------------------------

## 世界（格）→ 小地图（px）的倍率。**等比**，取宽高里较小的那个，保证整张图装得下。
func scale() -> float:
	if world == null or world.map == null:
		return 1.0
	var m = world.map
	var cols: int = maxi(1, int(m.cols))
	var rows: int = maxi(1, int(m.rows))
	return minf(size.x / float(cols), size.y / float(rows))


## 地图在小地图控件里的左上角（居中之后的留边）
func origin() -> Vector2:
	if world == null or world.map == null:
		return Vector2.ZERO
	var s := scale()
	var m = world.map
	return Vector2(
		(size.x - float(m.cols) * s) * 0.5,
		(size.y - float(m.rows) * s) * 0.5)


## 世界坐标（格）→ 小地图局部坐标
func to_minimap(world_pos: Vector2) -> Vector2:
	return origin() + world_pos * scale()


## 小地图局部坐标 → 世界坐标（格）。左键跳转用。
func to_world(local_pos: Vector2) -> Vector2:
	var s := maxf(1e-6, scale())
	return (local_pos - origin()) / s


## 整张地图在小地图控件里的矩形（画地形时按格铺，这里只用来画外框）
func map_rect() -> Rect2:
	if world == null or world.map == null:
		return Rect2()
	var s := scale()
	return Rect2(origin(), Vector2(float(world.map.cols), float(world.map.rows)) * s)


## ★ 玩家当前的视野框（世界坐标，格）。
##
## ★★ 为什么读 `cam.position` 而不是 `cam.get_screen_center_position()`（实测踩过）：
##   后者返回的是**上一帧渲染时**记下的屏幕中心 —— 刚改完 `cam.position` 的那一帧里，
##     `cam.position` = (864, 704) 而 `get_screen_center_position()` = (772.5, 260.5)（旧值），
##     于是视野框要等下一帧才挪。本控件与点击都要求「本帧就一致」，
##     所以这里读 `cam.position`（相机是锚点居中，屏幕中心就是它）。
##   ⚠️ 这也意味着：**别**给相机开 `position_smoothing` ——
##     一开，`cam.position` 就变成「目标点」而不是「屏幕中心」，两者会差一段平滑距离，
##     这个框会跑到画面之外（真要开平滑，这里得跟着改成读平滑后的值）。
##
## 视野大小 = 视口像素 / zoom（zoom 是放大倍数：越大看到的越少）。
## ⚠️ 相机现在允许跑到地图边界上（clamp 到 [0, 地图宽]），所以这个框**会超出地图**，
##    在小地图上就是压在留边上 —— 那是真实情况，照画。
func view_rect_world() -> Rect2:
	if camera_rig == null or camera_rig.cam == null:
		return Rect2()
	var cam: Camera2D = camera_rig.cam
	var vp: Vector2 = camera_rig.get_viewport_rect().size
	var zoom: Vector2 = cam.zoom
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		return Rect2()
	var half: Vector2 = Vector2(vp.x / zoom.x, vp.y / zoom.y) * 0.5
	var center: Vector2 = cam.position
	return Rect2(center - half, half * 2.0)


## 视野框在小地图控件里的矩形。
##
## ⚠️ 单位陷阱（本文件真踩过）：`view_rect_world()` 给的是**世界像素**，而
##    `to_minimap()` 收的是**格** —— 直接喂进去会白乘一个 cell_px²，
##    框虽然还在（两处都放大了同样的倍数），但数值完全不对、稍微一改动就会跑飞。
##    所以这里先除 cell_px 换成格，再交给 to_minimap，最后把**格的尺寸**乘 scale。
func view_rect_local() -> Rect2:
	var w := view_rect_world()
	var cell: float = maxf(1e-6, cfg.cell_px)
	var p := to_minimap(w.position / cell)          # 世界像素 → 格 → 小地图像素
	return Rect2(p, (w.size / cell) * scale())


# ------------------------------------------------------------------
# 每帧重画
# ------------------------------------------------------------------

## ★★ 为什么必须有这个 `_process`（这是本轮最大的一个 bug，症状有三个）：
##
##   本控件是**自绘**的（`_draw()` 一次画完地形 / 建筑 / 单位 / 视野框），
##   而 Godot 的 `_draw()` 只在「节点第一次可见」和「被 `queue_redraw()` 标脏」时执行 ——
##   **不会每帧自动重画**。少了这一行，小地图就是一张首帧的快照：
##     · 敌人在大地图上跑，小地图里那个红点永远钉在出生位置；
##     · 平移 / 缩放视角，白色视野框纹丝不动（它只是在首帧画下的一个矩形）；
##     · 点击小地图后画面确实跳了，但小地图上的框还停在原处。
##   三个症状是同一个根因，所以修法也只有一处：每帧标脏。
##
##   对照：overlay.gd 走 `overlay.queue_redraw()`（由 game_scene 每帧调），
##   unit_view.gd 在 `sync()` 里 queue_redraw —— 都是同一个道理，
##   区别只是本控件由主循环直接驱动（game_scene 不需要再多一行接线）。
##
## ⚠️ 成本：`_draw()` 里是 594 格地形 + 建筑 + 单位 + 一个矩形。
##   地形其实**不会变**（只有换地图才变），真到了要省这点开销的时候，
##   可以像 unit_view.gd 那样把「节点第一次画」与「每帧只画动态层」拆成两个 CanvasItem；
##   现在 1000 单位实机都在跑，这点画量不值得提前优化。
func _process(_dt: float) -> void:
	queue_redraw()


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	if cfg == null or world == null or world.map == null:
		return
	_draw_terrain()
	_draw_buildings()
	_draw_units()
	_draw_view_rect()


## 地形：一格一个小方块。地图外的格子（exists = false）**不画** ——
## 露出来的是面板自己的底色，与「地图界外是默认背景」同一条语义。
func _draw_terrain() -> void:
	var s := scale()
	var o := origin()
	var m = world.map
	for ty in m.rows:
		for tx in m.cols:
			if not m.tile_exists(tx, ty):
				continue
			var t := String(m.terrain.get_cell(tx, ty))
			var c: Color = _c_grass if (tx + ty) % 2 == 0 else _c_grass_alt
			if t == "mountain":
				c = _c_mountain
			elif t == "forest":
				c = _c_forest
			draw_rect(Rect2(o + Vector2(float(tx), float(ty)) * s, Vector2(s, s)), c, true)


## 建筑：按各自本体的**占地比例**画（城墙填满一格、大本营 / 箭塔内缩），
## 与大地图上的观感一致；颜色取阵营主色，区划中心用它的品红。
##
## ⚠️ 遍历的是 `world.building_list`（数组），**不是** `world.buildings` ——
##    后者是 GridRes（格子索引，供寻路/碰撞用），对它做 `for` 会在运行时报
##    「Unable to iterate on object of type 'Object'」，而且 `_draw` 里的报错
##    不会让测试失败（只打红字），很容易悄悄留着一个画不出来的小地图。
func _draw_buildings() -> void:
	var s := scale()
	var o := origin()
	for b in world.building_list:
		if not b.alive:
			continue
		var body: float = clampf(b.body_scale(cfg), 0.15, 1.0)
		var side: float = maxf(MIN_BUILDING, s * body)
		var center: Vector2 = o + (Vector2(float(b.tx), float(b.ty)) + Vector2(0.5, 0.5)) * s
		var col: Color
		if b.type == BuildingRes.TYPE_ZONE_CENTER:
			col = cfg.color("zone_center")
		elif b.type == BuildingRes.TYPE_WALL:
			col = cfg.color("wall")
		else:
			col = cfg.faction_color(b.owner, "main")
		draw_rect(Rect2(center - Vector2(side, side) * 0.5, Vector2(side, side)), col, true)


## 单位：敌我双方各一个小点，按阵营配色。
## ⚠️ 用 draw_rect 而不是 draw_circle：unit_view.gd 实测过 draw_circle 不参与 2D 合批
##    （1000 个单位 = 997 个 draw call），而小地图上 4~5 px 的方块与圆点肉眼无差。
func _draw_units() -> void:
	var o := origin()
	var s := scale()
	for u in world.units:
		if not u.alive:
			continue
		var p: Vector2 = o + u.pos * s
		draw_rect(Rect2(p - Vector2(UNIT_R, UNIT_R), Vector2(UNIT_R, UNIT_R) * 2.0),
			_faction_color(String(u.faction)), true)


## 视野框：先铺一层淡白，再描一圈亮白边。
## 边界可以超出小地图，超出的部分由控件自己的裁剪负责（不需要手动 intersect）。
func _draw_view_rect() -> void:
	var r := view_rect_local()
	draw_rect(r, VIEW_FILL, true)
	draw_rect(r, VIEW_LINE, false, VIEW_LINE_W)


func _faction_color(faction: String) -> Color:
	if _color_cache.has(faction):
		return _color_cache[faction]
	var c: Color = cfg.faction_color(faction, "main")
	_color_cache[faction] = c
	return c


# ------------------------------------------------------------------
# 输入：左键点击 → 镜头跳过去
# ------------------------------------------------------------------

## ★ 需求：「当玩家左键点击地图中的某处时，将视角移动至玩家点击的地方（需要做边界判定）」。
##
## 边界判定不在本文件做：`camera_rig.center_on_px()` 会走 clamp_position()，
## 而那条规则正是「屏幕中心可以被推到地图边界点上」——
## 于是点到角落 = 走到角落的极点，点到小地图的留边（地图外）也自然落在极点上。
func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if camera_rig == null:
		return
	# 世界（格）→ 世界（像素）走 palette（**唯一**的换算入口，本文件不自己乘 cell_px）
	camera_rig.center_on_px(PaletteRes.to_px(to_world(mb.position), cfg))
	accept_event()
