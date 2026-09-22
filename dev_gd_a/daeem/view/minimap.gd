## minimap.gd —— 左下角的小地图（需求：显示整张地图 + 玩家当前的视野框 + 左键跳转/拖动）
##
## 替代原来那个「灰块 + 地图两个大字」的占位（`hud._build_minimap`）。
##
## 四件事，各自只有一条路：
##   1. **画**：整张地图的地形 / 建筑 / 单位，全部由 `_draw()` 一次画完 ——
##      它每帧都在变（单位在走），学 unit_view.gd 那条「一个节点画全部」的做法，
##      而不是每格一个节点（docs/pitfalls.md 2.3）。
##   2. **视野框**：从**相机**读 `zoom` 与 `position`，
##      算出「屏幕现在覆盖世界上的哪一块」，换算成小地图里的白色描边矩形。
##      平移、缩放、F 键、Home 键——任何改相机的途径都会让这个框跟着动，
##      因为这里读的是相机的**当前值**，不是任何一份「谁改了相机」的通知。
##      ★ 画出来的那个矩形是 `view_rect_clipped()`：**裁到地图矩形里**
##      （需求：「让视野框只显示在小地图内的地图 ui 范围内」）——
##      贴边时框的边框因此自动与地图边界重合，不会画到小地图自己的留边上。
##   3. **左键跳转**：把小地图坐标反算回世界坐标，交给 `camera_rig.center_on_px()`。
##      边界判定**不在这里做** —— 相机自己会 clamp（`clamp_position`），
##      所以点到角落 = 走到极点，点到地图外的留边 = 走到最近的那条边界。
##   4. **按住拖动**（需求：「点击小地图后可长按拖动小地图以移动视角」）：
##      按下之后**保持按住**，光标在地图上移到哪、视角就跟到哪（松手即停）。
##      它与第 3 条**共存**：按下那一刻照旧跳一次（单击 = 跳转，老手感不变），
##      之后才升级成拖动态 —— 所以「点一下」与「按住拖」是同一条手势的两端，
##      不存在「单击被判成拖动、所以点不动」的死角。三态见文件末尾「输入」那一节。
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
## 拖动中的视野框：底色更浓 + 描边换成主题蓝（与 ui_style.ACCENT 同一支），
## 玩家一眼能看出「现在按着的是小地图、拖的就是这个框」。
const VIEW_FILL_DRAG := Color(0.12, 0.60, 0.84, 0.32)
const VIEW_LINE_DRAG := Color(0.12, 0.60, 0.84, 1.0)

## 单位点与小方块的尺寸（小地图像素）。地图 27 格宽、控件 400 宽时，
## 1 格 ≈ 14.8 px，所以这些数都在「一格的十分之一」量级 —— 看得出来，又不糊成一片。
const UNIT_R := 2.4
const MIN_BUILDING := 3.0

var cfg: ConfigRes = null
var world = null
var camera_rig = null

## ---- 左键手势的状态（三态，见文件末尾「输入」那一节）----
##   · 都没开        = 空闲
##   · _drag_pending = 左键按着，但还没越过「算拖动」的门槛（此时算单击）
##   · _drag_active  = 已经是拖动态：每帧把镜头跟到光标上
var _drag_pending: bool = false
var _drag_active: bool = false
## 按下那一刻的光标位置与已经按住的秒数（阈值判据见 config.minimap.*）
var _drag_press_pos: Vector2 = Vector2.ZERO
var _drag_press_sec: float = 0.0
## ★ 最近一次**真的收到**的光标位置（局部坐标）。
##   拖动由 `_process` 每帧推进、而不是每次移动事件推进一次 ——
##   这样「按住不动」时状态也不会漏拍；位置本身由事件更新（事件里的 position 就是权威值）。
var _mouse_local: Vector2 = Vector2.ZERO
## ★★ 这一次手势里**收到过移动事件没有**（每次按下都清零）。
##   ⚠️ 它与「_mouse_local 有没有值」是两件事：按下那一刻就会把按下点写进 _mouse_local，
##      所以那个变量永远「有值」—— 用它当判据的话，按住不动时的真实光标位置
##      就永远不会被查一次（表现：按住不动再横划，镜头不跟手）。
var _moved_since_press: bool = false

## ★★ 「按住不动也算长按」那条判据需要知道光标现在在哪，而**按下之后一直没动**
##   的话一个移动事件都不会来。所以这种情况下允许去问引擎要一次真实光标位置。
##
##   ⚠️ 无头测试必须把它关掉（`use_real_mouse_on_hold = false`）：
##      无头下没有真鼠标，`get_local_mouse_position()` 会给一个脏值，
##      于是「按住一秒之后镜头跳到一个没人点过的位置」——
##      测试要验的是「按住 → 进入拖动态」，位置必须由测试自己喂进来。
var use_real_mouse_on_hold: bool = true

## ★★ 「每帧回头确认左键还按着」这条兜底开关（见 `_tick_drag` 开头）。
##   真机上必须开：窗口失焦 / 被切走时抬起事件可能永远收不到，不兜这一下，
##   回来时光标一动镜头就跟着跑，像是卡住了。
##   ⚠️ 无头测试必须关掉：无头下没有真鼠标按键状态（`Input.is_mouse_button_pressed()`
##      恒为 false），开着的话每一次 `_tick_drag` 都会当场把手势收掉。
var verify_button_held: bool = true

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


## ★★ 真正被画出来的那个视野框：`view_rect_local()` 裁到地图矩形里。
##
## 需求原话：「裁剪一下小地图视野选框，让视野框只显示在小地图内的地图 ui 范围内，
##          当视野框移动到边缘时，需要动态调整小地图的边框使其贴合地图 ui 边框」。
##
## 为什么需要裁（不裁会看到什么）：相机允许停在**地图边界点**上（`camera_rig.clamp_position`
## 的规则），所以贴边时视野框有一半在地图之外、画到小地图自己的留边上；
## 而那块留边在小地图里的语义是「这里没有地图」—— 把一个代表视野的亮框画上去，
## 看起来就像小地图外面还有一块地。裁掉之后，框的边框自然与地图那圈的边界重合，
## 也就是需求要的「贴合地图 ui 边框」。
##
## ★ 只裁**视野框**：地形按格铺、建筑在格心、单位位置受地图夹取，本来就落在地图矩形内；
##   而「视野」是唯一一个**语义上允许越界**的东西（它谈的是屏幕覆盖了世界哪一块，
##   屏幕当然能看到界外）。所以这里只收这一处，不去动绘制层的语义。
##
## ★ `intersection()` 的方向性：两个矩形不相交时返回一个**宽或高为负**的矩形
##   （不是零矩形），所以判空要用 `size.x <= 0 || size.y <= 0`，不能只判 `size == ZERO`；
##   而且相机再怎么跑，本控件与地图矩形始终有交集（地图是居中的），所以空集是纯兜底。
##
## ★ 拖动时看到的框跟着光标走，靠的就是这个函数每帧被 `_draw_view_rect()` 重新算一遍
##   —— 不需要任何额外的「框的动画」，裁剪本身让它在贴边时自动停在边界上。
func view_rect_clipped() -> Rect2:
	var view := view_rect_local()
	var bounds := map_rect()
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return Rect2()
	var r := view.intersection(bounds)
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return Rect2()
	return r


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
##
## ★ 拖动由这里每帧推进（`_tick_drag`），不是每个移动事件推进一次：
##   鼠标停在原地不动时事件就没了，而「按住算长按」的那条计时必须照样走。
func _process(dt: float) -> void:
	_tick_drag(dt)
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
## ★★ 画的是 `view_rect_clipped()`（裁到地图矩形里）而不是 `view_rect_local()`：
##   镜头的视野允许越出地图（屏幕能看到界外），但小地图的留边代表「这里没有地图」，
##   亮框画上去会让人以为外面还有地 —— 所以框只在地图范围内出现，
##   贴边时它的边框自然与地图边界重合。理由见 `view_rect_clipped()`。
##
## ★ 拖动中换成主题蓝（更浓）：这是「我现在按着的是小地图」的唯一视觉反馈 ——
##   不然玩家按住拖动时看到画面在动，却分不清是拖小地图还是边缘滚屏在推。
func _draw_view_rect() -> void:
	var r := view_rect_clipped()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	if _drag_active:
		draw_rect(r, VIEW_FILL_DRAG, true)
		draw_rect(r, VIEW_LINE_DRAG, false, VIEW_LINE_W)
		return
	draw_rect(r, VIEW_FILL, true)
	draw_rect(r, VIEW_LINE, false, VIEW_LINE_W)


func _faction_color(faction: String) -> Color:
	if _color_cache.has(faction):
		return _color_cache[faction]
	var c: Color = cfg.faction_color(faction, "main")
	_color_cache[faction] = c
	return c


# ------------------------------------------------------------------
# 输入：左键按下 = 跳过去，按住不放 = 拖着走
# ------------------------------------------------------------------

## ★★ 一条左键手势，三个状态（都关 → pending → active）：
##
##   都没开 ──按下左键──▶ pending（同时**立刻跳一次**：单击 = 跳转，老手感不变）
##   pending ──移动超过 drag_min_px / 按住超过 drag_hold_sec──▶ active（拖着走）
##   pending ──抬起──▶ 都没开（什么都没变，就是一次普通单击跳转）
##   active  ──抬起──▶ 都没开（松手即停，镜头留在当时的位置）
##
## ★ 为什么要「按下即跳」而不是「抬起才跳」：
##   需求要的是「点击跳转」与「长按拖动」**共存**。若把跳转推迟到抬起，
##   玩家会先看到画面不动、松开才跳（手感发虚）；而按下就跳的话，
##   后续的拖动会从**同一个点**继续跟手（按下那一刻镜头已经等于那个点了），
##   两条需求接得上，也不会出现「跳了一下又倒回去」的闪动。
##
## ★ 为什么门槛是「按住够久 **或** 拖得够远」两个判据：
##   只按时间算（字面意义的「长按」）→ 按住不动一秒再横着划，第一段移动会被
##   当成单击抖动丢掉；只按距离算 → 想「按住不动等它开始跟手」就永远等不到。
##   两个判据谁先满足都算，见 config.json 的 minimap._comment。
##
## ★★ 拖动时**用事件里的 position**，不读 `get_global_mouse_position()`：
##   本文件的地图换算全部走局部坐标，而事件给的就是局部坐标（与 `_gui_input`
##   里那条点击跳转同源）；全局坐标还要自己减一次 global_position，
##   多一次换算就多一个对不上的机会。
func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_press(mb.position)
		else:
			_release()
		accept_event()
		return
	if event is InputEventMouseMotion:
		# ★ 只在按着左键时记位置：没按着时的悬停与本控件无关
		#   （大地图的悬停高亮是 input_controller.poll_mouse 那条路，不在这里）。
		if _drag_pending or _drag_active:
			_moved_since_press = true
			_mouse_local = (event as InputEventMouseMotion).position
			accept_event()


## 按下：跳过去 + 进入 pending（等它变成拖动，或者抬起结束）
func _press(local_pos: Vector2) -> void:
	_drag_pending = true
	_drag_active = false
	_drag_press_pos = local_pos
	_drag_press_sec = 0.0
	_mouse_local = local_pos
	_moved_since_press = false
	_jump_to(local_pos)


## 抬起：结束这一次手势（无论是单击还是拖动）
func _release() -> void:
	_drag_pending = false
	_drag_active = false
	_drag_press_sec = 0.0


## 每帧推进：还在按着的时候，判断该不该升级成拖动态、以及把镜头跟到光标上。
##
## ★ 这里是拖动的**唯一**推进点。事件只管「光标在哪」，跟手与否由这一处决定 ——
##   两处都写的话（事件里也跟一次）就会出现「同一帧跟两次、光标一抖镜头多走一格」。
func _tick_drag(dt: float) -> void:
	if not _drag_pending:
		return
	# ★ 兜底：左键已经不在按着了就结束这一次手势。
	#   正常路径是抬起事件（引擎保证发到按下它的那个控件），但**窗口失焦 / 被切走**时
	#   抬起事件可能收不到 —— 不兜这一下，回来时光标一动镜头就跟着跑，像是卡住了。
	if verify_button_held and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_release()
		return
	_drag_press_sec += dt
	_sync_mouse_if_never_moved()
	if not _drag_active and _armed():
		_drag_active = true
	if _drag_active:
		_follow_cursor()


## 这一次手势还从没收到过移动事件时，去问一次引擎「光标现在在哪」。
## ★ 为什么需要它：玩家按住小地图**不动**一秒（这就是最字面的「长按」），
##   期间引擎不会发任何移动事件 —— 不补这一次查询，拖动就会跟到「按下点」上，
##   表现是「按住不动再横划，前半段镜头不理人」。
## ★ 只在「一个移动事件都没来过」时问：一旦有事件，事件里的位置才是权威值
##   （它的坐标系与本控件的局部坐标系严格同源）。
func _sync_mouse_if_never_moved() -> void:
	if _moved_since_press or not use_real_mouse_on_hold:
		return
	_mouse_local = get_local_mouse_position()


## 够不够格算「拖动」：按住够久，或者从按下点算起拖得够远。
## 阈值走 config（`minimap.drag_min_px` / `minimap.drag_hold_sec`），**不在代码里写字面量**。
func _armed() -> bool:
	if cfg == null:
		return false
	var min_px: float = maxf(0.0, cfg.minimap_drag_min_px)
	if min_px > 0.0 and _drag_press_pos.distance_to(_mouse_local) >= min_px:
		return true
	var hold: float = maxf(0.0, cfg.minimap_drag_hold_sec)
	return hold > 0.0 and _drag_press_sec >= hold


## 把镜头跟到光标上。边界**不在这里判**：`center_on_px()` 会走 clamp_position()，
## 所以光标拖出小地图（甚至拖到屏幕上别的区域）时，镜头照旧跟手、只是被夹在
## [0, 地图宽] × [0, 地图高] 的极点上 —— 也就是玩家选的「继续跟手，按极点夹取」。
func _follow_cursor() -> void:
	_jump_to(_mouse_local)


## 小地图局部坐标 → 镜头位置。★ 世界（格）→ 世界（像素）走 palette
## （**唯一**的换算入口，本文件不自己乘 cell_px），点击与拖动共用这一条。
func _jump_to(local_pos: Vector2) -> void:
	if camera_rig == null:
		return
	camera_rig.center_on_px(PaletteRes.to_px(to_world(local_pos), cfg))


# ------------------------------------------------------------------
# 给外面看的两个状态（只读）
# ------------------------------------------------------------------

## 现在是不是「拖着走」的状态（HUD / 测试读它；游戏里 game_scene 用它告诉
## camera_rig「别在这个手势里搞边缘滚屏」——否则按住小地图下沿时镜头会被推着走）。
func is_dragging() -> bool:
	return _drag_active


## 左键还按着（单击正在进行中，可能还没升级成拖动）
func is_pressed_held() -> bool:
	return _drag_pending
