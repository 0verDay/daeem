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

## ★★ 3D 投影助手（`view/palette.gd` 的实例，持有 `Camera3D`）。
##   小地图的「视野框 / 点击跳转」全靠它把屏幕像素换成格 —— 这是**唯一**的路线
##   （2D 遗留路线已随 2D 栈删除；`setup` 时必须给）。
var palette = null
const BuildingRes = preload("res://logic/building.gd")
## ★ 红点性 AI 的「AI 类型」字符串（`reddot`）从这个常量取，不在本文件里再写一遍字面量。
const LevelRes = preload("res://logic/level.gd")
## ★★ 局内「敌 / 友 / 己」三色（本轮新增）：小地图上的单位点 / 建筑块 / 区划都走它
const SideColorRes = preload("res://view/side_color.gd")
## ★ 迷雾掩码按「同方」存（合作模式共享视野），与 `fog.tile_visible()` 同一个键。
##   烘图直接读掩码数组，所以需要这个换算（只用来取 key，不重算任何视野）。
const FactionRes = preload("res://logic/faction.gd")

## 视野框：里面叠一层很淡的白（让「我现在看的是这一块」一眼可见），外面描一圈亮白边。
const VIEW_FILL := Color(1.0, 1.0, 1.0, 0.13)
const VIEW_LINE := Color(1.0, 1.0, 1.0, 0.95)
const VIEW_LINE_W := 2.0
## 拖动中的视野框：底色更浓 + 描边换成主题金（与 ui_style.accent() 同一支），
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
var _c_water: Color
## 阵营 → 主体色。每帧每单位查一次的东西，缓存成一次查表（同 unit_view.gd）
var _color_cache: Dictionary = {}

## ★★ 地形层的烘图（1 像素 / 格）：地形**永不变化**（只有换地图才变），
##   每帧逐格 `draw_rect`（27×22 图 = 594 个矩形）是纯浪费 —— 烘成一张贴图，
##   `_draw` 里一次 `draw_texture_rect` 铺开。⚠️ 地图外的格子烘成**透明**（露出面板底色）。
var _terrain_tex: ImageTexture = null
## 烘图对应的地图签名（列|行|地图对象 id）——变了就重烘（换图 / 重开一局）
var _terrain_sig: String = ""

## ★★ 迷雾层的烘图（1 像素 / 格）：与地形同一条思路。
##   原来每帧逐格 `tile_visible` + `draw_rect`（27×22 = 594 次查询 + 594 个矩形），
##   手机上即使节流到 15Hz 仍是一笔可观的 CPU / draw call。
##   现在只在**掩码真的变了**时重烘一次，`_draw` 里一次 `draw_texture_rect`。
## ★ 掩码（`world.fog.sight`）整块比较：PackedByteArray 的 `==` 是逐字节比较，
##   594 字节（100×100 图也只有 1 万字节）的开销可以忽略；
##   而且它是**精确**的 —— 不像按抽样判据那样可能漏掉局部变化。
## ★ `fog_bake_count` 是纯诊断（排查时看「迷雾有没有被频繁重烘」）。
var _fog_tex: ImageTexture = null
var _fog_img: Image = null
var _fog_mask: PackedByteArray = PackedByteArray()
var _fog_cols: int = -1
var _fog_rows: int = -1
var fog_bake_count: int = 0

## ★★ 手机端：小地图重画节流（桌面 / 无头恒为 0 = 每帧；见 config 的 ui._minimap_hz_comment）
var _refresh_interval: float = 0.0
var _refresh_accum: float = 0.0

## ★★ 红点性 AI 将领的标记 + 生成动效（本轮新增；需求见 config 的 minimap._red_dot_comment）。
##
## 两件事共用一份「红点」判据（`is_red_dot_faction()`）：
##   · **常驻标记**：场上每位红点将领在小地图上画一个红色小菱形（只标将领，不标附属兵）；
##   · **生成动效**：红点 AI 刷出一波时，在**每个出生格**播一个「菱形由大变小 + 淡出」。
##     —— 位置来自 `red_dot_wave` 事件的 `spawns`（logic/red_dot_ai.gd），本文件不猜。
##
## ★★ 显示口径（本轮定稿）：
##   · **常驻标记**只在红点将领**没被观测到**（还在迷雾里）时画 —— 它一旦被
##     我方 / 友方看见，屏幕上就有一个真实的单位了，菱形反而多余；
##   · **生成动效**照旧每次都播（红点刷出来的那一下要能看见“它来了”），与迷雾无关。
##   ⚠️ 两样都**不**参与玩法判定；只影响小地图这一层（大地图照旧走 `fog.*`）。
var _red_dot_fx: Array = []              # 每项 `{pos: Vector2(格), age: float}`
## 常驻菱形的**呼吸**时钟（秒；只由 `_process` 推进，测试可以直接写它）。
var _breath_clock: float = 0.0
## 诊断（测试读它；与 overlay 的 `*_draw_count` 同一个用途）：最近一次 `_draw` 画了几个。
var red_dot_mark_count: int = 0
var red_dot_fx_draw_count: int = 0


func setup(p_cfg: ConfigRes, p_world, p_camera_rig, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	camera_rig = p_camera_rig
	# ★★ 3D 投影助手（`view/palette.gd` 的实例，持有 Camera3D）—— **必需**：
	#    「视野框」与「点击跳转」全靠它把屏幕像素换成格（2D 回退已随 2D 栈删除）。
	palette = p_palette
	mouse_filter = Control.MOUSE_FILTER_STOP      # 点在小地图上 = 移动镜头，不许穿到地图上
	focus_mode = Control.FOCUS_NONE
	_c_grass = cfg.color("grass")
	_c_grass_alt = cfg.color("grass_alt")
	_c_forest = cfg.color("forest")
	_c_mountain = cfg.color("mountain")
	_c_water = cfg.color("water")
	_color_cache = {}
	# 新一局 / 新地图 ⇒ 迷雾烘图作废（贴图缓冲可以复用，尺寸对不上时会重建）
	_fog_mask = PackedByteArray()
	_fog_cols = -1
	_fog_rows = -1
	# 新一局 ⇒ 上一局残留的「红点生成」动效也不能留着（否则一开局就在播上一局的）
	_red_dot_fx = []
	_breath_clock = 0.0
	red_dot_mark_count = 0
	red_dot_fx_draw_count = 0
	# ★ 地形烘图按 NEAREST 采样：1 像素/格 的贴图缩放到小地图尺寸后仍是硬边小方块。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# ★★ 手机端：小地图每帧重画（地形 + 迷雾 + 单位）没必要 60Hz，按上限节流。
	_refresh_interval = 0.0
	if OS.has_feature("mobile") and cfg.mobile_minimap_hz > 0.0:
		_refresh_interval = 1.0 / cfg.mobile_minimap_hz
		# ★ 默认把第一次重画错开一点：HUD 的槽位也在 20Hz 上轮转，
		#   两边同时落在同一帧会把两个重活叠起来（见 `stagger_redraw`）。
		stagger_redraw(0.37)


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


## 整张地图在小地图控件里的**外接框**（留边计算与用例的 bounds 用它）。
func map_rect() -> Rect2:
	if world == null or world.map == null:
		return Rect2()
	return _aabb_of(_map_diamond())


## ★★ 地图的**菱形**在小地图控件里的四个顶点（顺序：右 → 下 → 左 → 上）。
##
## 为什么需要它：主视图现在把地图画成一个斜放的大菱形，小地图若还画成矩形，
## 就会出现「点小地图的角 → 镜头跳到一个不属于地图的点」这种错位
## （实测：点 AABB 左上角，相机夹取把它拉回 (0,0)，与点击意图不符）。
## ★ 小地图的**格子仍然是正放的小方块**（更好读），只有地图的**整体外沿**是菱形 ——
##   这与「一个格子在屏幕上是什么形状」是两件事：前者是地图轮廓，后者才是投影。
func _map_diamond() -> PackedVector2Array:
	if world == null or world.map == null:
		return PackedVector2Array()
	var m = world.map
	var corners: Array = [Vector2(float(m.cols), 0.0), Vector2(float(m.cols), float(m.rows)),
		Vector2(0.0, float(m.rows)), Vector2.ZERO]
	var out := PackedVector2Array()
	for c in corners:
		out.append(to_minimap(c))
	return out


## 一个多边形的轴对齐包围盒
static func _aabb_of(poly: PackedVector2Array) -> Rect2:
	if poly.is_empty():
		return Rect2()
	var mn := poly[0]
	var mx := poly[0]
	for p in poly:
		mn = mn.min(p)
		mx = mx.max(p)
	return Rect2(mn, mx - mn)


## ★ 玩家当前的视野框（**世界像素**口径）。
##
## ★★ 做法：把**视口四角**投到地面上，取它们的轴对齐包围盒。
##    为什么不用「视口 / zoom」那套式子：那假设世界轴对齐，而 3D 相机是斜看的
##    ⇒ 屏幕矩形映射回地面是个**梯形**，只能靠四角求包围盒（略大于真实可见区，
##    这是刻意选的口径：宁可框大，也不能出现「屏幕上看得见、框里没框到」）。
## ⚠️ 相机允许贴到地图边界，所以这个框**会超出地图**（在小地图上就是压在留边上）
##    —— 那是真实情况，照画（裁剪在 `view_rect_local` 那一层做）。
func view_rect_world() -> Rect2:
	var corners3 := _view_corners_logic()
	if corners3.is_empty() or cfg == null:
		return Rect2()
	var mn3: Vector2 = corners3[0]
	var mx3: Vector2 = corners3[0]
	for c in corners3:
		mn3 = mn3.min(c)
		mx3 = mx3.max(c)
	var cell: float = cfg.cell_px
	return Rect2(mn3 * cell, (mx3 - mn3) * cell)


## 视野框在小地图控件里的矩形。
##
## ⚠️ 单位陷阱（本文件真踩过）：`view_rect_world()` 给的是**世界像素**，而
##    `to_minimap()` 收的是**格** —— 直接喂进去会白乘一个 cell_px²。
##    所以换算链永远是：世界像素 →（`palette.to_logic`）→ 格 →（`to_minimap`）→ 小地图像素。
##
## ★★ 菱形档的口径（与正放矩形那版**根本不同**，改之前先读）：
##    世界是斜的 ⇒ 屏幕上那个**矩形视口**映射回世界是个**斜四边形**，
##    而且它既不是轴对齐矩形、也不等于「视口宽 / 格宽」。
##    所以这里**老老实实把视口四角投回格空间**，再取它们的轴对齐包围盒：
##       屏幕四角 --(画布变换的逆)--> 世界像素 --(palette.to_logic)--> 格 --(取 AABB)
##    ★ 包围盒是**略大于**真实可见区域（斜四边形的外接框），这是刻意选的口径：
##      它保证「框里有的，屏幕上不一定看得见」而**不会**出现「屏幕上看得见、框里没框到」——
##      对「我现在看的是哪一块」这个问题，宁可框大一点。
##    ★ 小地图的**地形**仍然正俯视等比（更好读），只有这个框按真实投影算。
func view_rect_local() -> Rect2:
	if camera_rig == null or cfg == null:
		return Rect2()
	var corners := _view_corners_logic()
	if corners.is_empty():
		return Rect2()
	var mn := to_minimap(corners[0])
	var mx := mn
	for p in corners:
		var q := to_minimap(p)
		mn = mn.min(q)
		mx = mx.max(q)
	return Rect2(mn, mx - mn)


## 视口四角在**格空间**里的位置（`view_rect_local` / `view_rect_world` 都用这一份）。
##
## ★ 屏幕像素 → `palette.to_logic()`：那是「从 Camera3D 往地面打射线求交」，
##   **入参就是屏幕像素**，所以**不能**再过一次画布变换。
##   ⚠️ 不许自己按「视口宽 / zoom / 格宽」推 —— 那是**正放**世界才成立的式子。
func _view_corners_logic() -> Array:
	if camera_rig == null or palette == null:
		return []
	var vp: Vector2 = camera_rig.get_viewport_rect().size
	var out: Array = []
	var corners: Array = [Vector2.ZERO, Vector2(vp.x, 0.0), vp, Vector2(0.0, vp.y)]
	for sp: Vector2 in corners:
		var lg = palette.to_logic(sp)
		# ⚠️ 射线打不到地面时（相机贴地平线）跳过这一角，而不是塞一个 (0,0)：
		#    塞零会让包围盒里凭空多出地图左上角，视野框整个错位。
		if lg != null:
			out.append(lg)
	return out


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


## 让下一次重画错开一个节拍（0..1 的比例）。
##
## ★ 用途：HUD 在手机上按 4 槽轮转刷新，小地图如果也从 0 开始累计，
##   它的第一次重画会和 HUD 的第一个槽位落在同一帧 —— 两个重活叠加就是尖峰。
##   把它推到 0.37 个周期的位置，之后两边就自然错开了。
func stagger_redraw(ratio: float) -> void:
	if _refresh_interval <= 0.0:
		return
	_refresh_accum = _refresh_interval * clampf(ratio, 0.0, 0.99)


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
	# ★ 常驻红点菱形的呼吸（纯显示；暂停时不推进 —— 场景暂停时 `_process` 本来也不跑）。
	_breath_clock += maxf(0.0, dt)
	# ★ 红点生成动效：每帧推进；有动效在播时**绕过手机端节流**（否则 10Hz 会一顿一顿的）。
	advance_red_dot_fx(dt)
	if _refresh_interval <= 0.0 or not _red_dot_fx.is_empty():
		queue_redraw()
		return
	_refresh_accum += dt
	if _refresh_accum >= _refresh_interval:
		_refresh_accum = 0.0
		queue_redraw()


# ------------------------------------------------------------------
# 画
# ------------------------------------------------------------------

func _draw() -> void:
	# ★★ 与 overlay 一样：只统计真正的 `_draw` 命令录制（`profile_on` 时才计时）。
	var t0: int = Time.get_ticks_usec() if (world != null and world.profile_on) else 0
	_draw_impl()
	if t0 != 0:
		world.profile_us["draw/minimap"] = int(world.profile_us.get("draw/minimap", 0)) \
			+ (Time.get_ticks_usec() - t0)


func _draw_impl() -> void:
	if cfg == null or world == null or world.map == null:
		return
	_draw_terrain()
	_draw_buildings()
	_draw_units()
	# ★★ 战争迷雾（用户确认：小地图套**同一份**迷雾）：
	#    先画完地形 / 建筑 / 单位，再把没视野的格子盖灰 —— 与大地图上的
	#    fog_view 同一个口径（地形照旧看得见，敌人先被剔除再盖灰）。
	#    顺序也在这一行里：盖在最后 = 盖在那些图元之上。
	_draw_fog()
	# ★★ 红点将领标记 / 生成动效：画在迷雾**之上**（口径：这两样永远可见，见字段说明）。
	_draw_red_dots()
	_draw_view_rect()


## 地形：整层**一次画完** —— 烘成 1 像素/格 的贴图铺到地图矩形上。
## ★★ 为什么不逐格 `draw_rect`：地形**永不变化**（只有换地图才变），而 27×22 图就是
##   594 个 `draw_rect`/帧 —— 见过 `_terrain_texture()` 的注释。
## ★ 地图外的格子（exists = false）在烘图里是**透明**的，露出来的是面板自己的底色，
##   与「地图界外是默认背景」同一条语义。
func _draw_terrain() -> void:
	var m = world.map
	var r := Rect2(origin(), Vector2(float(m.cols), float(m.rows)) * scale())
	draw_texture_rect(_terrain_texture(), r, false)


## 把地形烘成一张 1 像素/格 的 `ImageTexture`（**换地图才重烘**，按签名缓存）。
## ⚠️ 用 NEAREST 过滤（见 `setup`）——扩到小地图尺寸后仍是硬边小方块，不是一团糊。
func _terrain_texture() -> ImageTexture:
	var m = world.map
	var cols: int = int(m.cols)
	var rows: int = int(m.rows)
	var sig := "%d|%d|%d" % [cols, rows, m.get_instance_id()]
	if _terrain_tex != null and sig == _terrain_sig:
		return _terrain_tex
	var img := Image.create(cols, rows, false, Image.FORMAT_RGBA8)
	for ty in rows:
		for tx in cols:
			if not m.tile_exists(tx, ty):
				img.set_pixel(tx, ty, Color(0.0, 0.0, 0.0, 0.0))     # 地图外 = 透明
				continue
			var t := String(m.terrain.get_cell(tx, ty))
			var c: Color = _c_grass if (tx + ty) % 2 == 0 else _c_grass_alt
			if t == "mountain":
				c = _c_mountain
			elif t == "water":
				c = _c_water
			elif t == "forest":
				c = _c_forest
			img.set_pixel(tx, ty, c)
	_terrain_tex = ImageTexture.create_from_image(img)
	_terrain_sig = sig
	return _terrain_tex


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
		# ★ 战争迷雾：看不见的敌方建筑不画（记忆规则见 logic/fog.gd）——
		#   与大地图的 building_view 读的是同一个查询，两边不会各显示一套。
		if not _building_visible(b):
			continue
		var body: float = clampf(b.body_scale(cfg), 0.15, 1.0)
		var side: float = maxf(MIN_BUILDING, s * body)
		var center: Vector2 = o + (Vector2(float(b.tx), float(b.ty)) + Vector2(0.5, 0.5)) * s
		var col: Color
		if b.type == BuildingRes.TYPE_ZONE_CENTER:
			col = cfg.color("zone_center")
		elif b.neutralized:
			col = cfg.side_color_neutral
		elif String(b.owner) == "":
			col = cfg.color("wall") if b.type == BuildingRes.TYPE_WALL else cfg.color("tower")
		else:
			# ★★ 有主建筑：按本机视角的己 / 友 / 敌三色（本轮新增）
			col = SideColorRes.color(cfg, world, String(b.owner), "main")
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
		# ★ 战争迷雾：敌方单位只显示当前视野里的（走出视野就消失，不保留记忆）
		if not _unit_visible(u):
			continue
		var p: Vector2 = o + u.pos * s
		var col: Color = cfg.side_color_neutral if u.neutralized \
			else _faction_color(String(u.faction))
		draw_rect(Rect2(p - Vector2(UNIT_R, UNIT_R), Vector2(UNIT_R, UNIT_R) * 2.0),
			col, true)


## ★★ 迷雾：没视野的格子盖一层灰（与大地图同一份掩码、同一个颜色）。
##
## ★ 现在是**烘成一张 1 像素/格 的贴图**再一次铺开（本轮手机端优化）：
##   原来是每帧 `rows×cols` 次 `tile_visible` + `draw_rect`（594 次查询 + 594 个图元）。
##   迷雾掩码只在实际视野变化时才变，而小地图本身还有 15Hz 节流 ——
##   于是绝大多数重画都是一次 `draw_texture_rect`，CPU 与 draw call 都接近 0。
## ★ 地图外的格子（exists = false）烘成**透明** —— 与 `_draw_terrain()` 同一条规则。
func _draw_fog() -> void:
	if not cfg.fog_enabled or world.fog == null:
		return
	var m = world.map
	var r := Rect2(origin(), Vector2(float(m.cols), float(m.rows)) * scale())
	draw_texture_rect(_fog_texture(), r, false)


## 把迷雾掩码烘成 `cols × rows` 的 RGBA 贴图；掩码没变就复用上一张。
##
## ★ 掩码直接读 `world.fog.sight`（与 `fog.tile_visible()` 是**同一份**数据，
##   键都是 `FactionRes.side_of()`）—— 不经过 `tile_visible()` 的逐格函数调用，
##   烘一次 = 594 次数组下标访问，而不是 594 次跨对象调用。
## ★ 颜色用 `cfg.fog_mask_color`（与大地图的迷雾层同一份）；alpha = 0 表示看得见。
## ★ `ImageTexture.update()` 原地更新，尺寸不变时不重新分配显存（与 ground_view 同一条经验）。
func _fog_texture() -> ImageTexture:
	var m = world.map
	var cols: int = int(m.cols)
	var rows: int = int(m.rows)
	var mask := PackedByteArray()
	var raw: Variant = world.fog.sight.get(FactionRes.side_of(world.my_faction), null)
	if typeof(raw) == TYPE_PACKED_BYTE_ARRAY:
		mask = raw
	# 掩码、尺寸都没变 ⇒ 直接复用（逐字节比较，见字段说明）
	if _fog_tex != null and _fog_cols == cols and _fog_rows == rows and mask == _fog_mask:
		return _fog_tex
	_fog_cols = cols
	_fog_rows = rows
	# ★★ 必须存**独立副本**：`sight` 里的 PackedByteArray 可能与这里共享底层缓冲，
	#    而 `fog.update()` / 测试会对数组做原地写 —— 直接存引用会让「上一份掩码」
	#    跟着变成「当前掩码」，比较永远相等、贴图再也不更新（渲染层最怕的静默失败）。
	_fog_mask = mask.duplicate()
	fog_bake_count += 1
	if _fog_img == null or _fog_img.get_width() != cols or _fog_img.get_height() != rows:
		_fog_img = Image.create(cols, rows, false, Image.FORMAT_RGBA8)
		_fog_tex = ImageTexture.create_from_image(_fog_img)
	var c: Color = cfg.fog_mask_color
	var seen_c := Color(c.r, c.g, c.b, 0.0)
	for ty in rows:
		var base := ty * cols
		for tx in cols:
			if not m.tile_exists(tx, ty):
				_fog_img.set_pixel(tx, ty, seen_c)
				continue
			var idx := base + tx
			var seen: bool = idx < mask.size() and mask[idx] != 0
			_fog_img.set_pixel(tx, ty, seen_c if seen else c)
	if _fog_tex == null:
		_fog_tex = ImageTexture.create_from_image(_fog_img)
	_fog_tex.update(_fog_img)
	return _fog_tex


# ------------------------------------------------------------------
# ★★ 红点性 AI 将领：小地图标记 + 生成动效（本轮新增）
# ------------------------------------------------------------------
#
# 需求原文（两条）：
#   1. 「当游戏中存在红点性 ai 将领时，在小地图上用小的红色菱形标识该红点将领位置」；
#   2. 「当红点性 ai 生成时，在其生成位置播放一个红点菱形由大变小的动效」。
#
# ★ 判据（这一块唯一需要理解的东西）：
#   · 「红点将领」= 它是**将领** + 它属于一个 **AI 类型为 reddot** 的阵营
#     （`world.ai_kind_of()`，与 logic/red_dot_ai.gd 的 setup 同一份数据）；
#     本机操作的席位永远不算（数据把可玩阵营写成 reddot 时也不能把它标成敌人）。
#   · 位置**不在这里猜**：常驻标记读单位的逻辑坐标；生成动效的位置来自
#     `red_dot_wave` 事件的 `spawns`，由 game_scene3d 喂进 `note_red_dot_spawns()`。
#     视图不去扫「新出现的单位」—— 那会把开局就摆好的红点将领也当成刚生成。

## 这一方是不是「红点性 AI」阵营（标记 / 动效的唯一判据）。
func is_red_dot_faction(fid: String) -> bool:
	if fid == "" or world == null:
		return false
	# ★ 本机在操作的席位永远不是「红点」：数据里把可玩阵营写成 `ai: reddot` 时，
	#   运行时会摘掉它的 AI，但 `ai_kind_of()` 仍会回答 reddot
	#   ⇒ 不拦这一下，玩家自己的将领也会被标成红点。
	if String(world.my_faction) == fid:
		return false
	var mine: Variant = world.player_factions
	if typeof(mine) == TYPE_ARRAY and (mine as Array).has(fid):
		return false
	if not world.has_method("ai_kind_of"):
		return false
	return String(world.ai_kind_of(fid)) == LevelRes.AI_REDDOT


## 这一帧该画的**红点将领位置**（逻辑坐标 = 格）。
##
## ★ 纯读、纯计算（不碰绘制 API）⇒ 无头测试可以直接断言它，不需要真的渲染一帧。
## ★★ **只画「还没被观测到」的那些**（本轮口径）：红点将领一旦离开战争迷雾、
##   被我方 / 友方单位看见，它本身就是屏幕上的一个单位了，小地图上不必再给菱形提示；
##   等它重新走进迷雾，菱形自动回来。判据只问 `logic/fog.gd`（盟友共享视野）。
func red_dot_marks() -> Array:
	var out: Array = []
	if world == null:
		return out
	for u in world.units:
		if not u.alive or not u.is_general():
			continue
		if not is_red_dot_faction(String(u.faction)):
			continue
		if _unit_observed(u):
			continue
		out.append(u.pos)
	return out


## 这个单位现在被**我方 / 友方**观测到了吗？
##
## ★ 判据与大地图的单位显示**同源**（`fog.unit_visible`）：迷雾按「同一方」存，
##   盟友的视野也算，正好对应需求里的「被**我方/友方**单位观测到」。
## ★ 没有迷雾（总开关关掉 / 没建 fog）⇒ 一切可见 ⇒ 返回 true（此时不画菱形）。
func _unit_observed(u) -> bool:
	if cfg == null or world == null:
		return false
	if world.fog == null or not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


## 记一次「红点生成」：`points` 是这一波每位将领的**出生格**（格坐标）。
##
## 由 `game_scene3d._consume_events()` 从 `red_dot_wave` 事件的 `spawns` 喂进来 ——
## 本文件既不监听逻辑事件、也不自己扫「新单位」。
func note_red_dot_spawns(points: Array) -> void:
	if points.is_empty():
		return
	for p in points:
		var v := _as_logic_point(p)
		if v.x < 0.0 or v.y < 0.0:
			continue
		_red_dot_fx.append({"pos": v, "age": 0.0})
	queue_redraw()


## 推进一步生成动效（由 `_process` 每帧调）；播完的记录直接摘掉。
func advance_red_dot_fx(dt: float) -> void:
	if _red_dot_fx.is_empty():
		return
	var sec: float = maxf(0.0, float(cfg.minimap_red_dot_spawn_sec)) if cfg != null else 0.0
	if sec <= 0.0:
		_red_dot_fx = []
		return
	if dt <= 0.0:
		return
	var keep: Array = []
	for e in _red_dot_fx:
		var d: Dictionary = e
		d["age"] = float(d.get("age", 0.0)) + dt
		if float(d["age"]) < sec:
			keep.append(d)
	_red_dot_fx = keep


## 还有几个生成动效在播（测试 / 诊断用）。
func red_dot_fx_count() -> int:
	return _red_dot_fx.size()


## 正在播的生成动效**位置**（格坐标；测试 / 诊断用）。
func red_dot_fx_points() -> Array:
	var out: Array = []
	for e in _red_dot_fx:
		out.append((e as Dictionary)["pos"])
	return out


## 生成动效在 `age` 时刻的**半对角线**（由 config 的起始尺寸收到常驻尺寸）。
##
## ★ 曲线是二次 ease-out（前段收得快、尾段贴着常态大小）—— 线性收缩看起来像
##   「匀速缩小」，而需求要的是「砸下来收住」的动效。
func red_dot_fx_radius(age: float) -> float:
	if cfg == null:
		return 0.0
	var sec: float = maxf(1e-6, float(cfg.minimap_red_dot_spawn_sec))
	var t: float = clampf(age / sec, 0.0, 1.0)
	var from: float = maxf(0.0, float(cfg.minimap_red_dot_spawn_from_r))
	var to: float = maxf(0.0, float(cfg.minimap_red_dot_r))
	var k: float = 1.0 - (1.0 - t) * (1.0 - t)
	return lerpf(from, to, k)


## 生成动效在 `age` 时刻的透明度：最后 35% 淡出（收小之后消失，不会「啪」一下不见）。
func red_dot_fx_alpha(age: float) -> float:
	if cfg == null:
		return 0.0
	var sec: float = maxf(1e-6, float(cfg.minimap_red_dot_spawn_sec))
	var t: float = clampf(age / sec, 0.0, 1.0)
	return 1.0 - clampf((t - 0.65) / 0.35, 0.0, 1.0)


## 常驻小红菱形**当前**的半对角线（带呼吸）。
##
## ★ 呼吸是**纯显示**：`r × (1 + amp × sin(2π t / period))`。周期 / 振幅都来自 config；
##   `period <= 0` 或 `amp = 0` 时就是常量 —— 测试与「关掉呼吸」都走这一条。
## ★ 只有**常驻标记**呼吸；生成时的「由大变小」动效保持原样（否则两条缩放曲线打架）。
func red_dot_mark_radius() -> float:
	if cfg == null:
		return 0.0
	var base: float = maxf(0.6, float(cfg.minimap_red_dot_r))
	var period: float = float(cfg.minimap_red_dot_breath_sec)
	var amp: float = clampf(float(cfg.minimap_red_dot_breath_amp), 0.0, 1.0)
	if period <= 0.0 or amp <= 0.0:
		return base
	var phase: float = TAU * _breath_clock / period
	return base * (1.0 + amp * sin(phase))


## 画：先常驻标记，再画生成动效（后画的在上）。
func _draw_red_dots() -> void:
	red_dot_mark_count = 0
	red_dot_fx_draw_count = 0
	if cfg == null or world == null:
		return
	var r: float = red_dot_mark_radius()
	for p in red_dot_marks():
		_draw_diamond(to_minimap(p), r, cfg.minimap_red_dot_color)
		red_dot_mark_count += 1
	for e in _red_dot_fx:
		var d: Dictionary = e
		var age: float = float(d.get("age", 0.0))
		var c: Color = cfg.minimap_red_dot_color
		c.a *= red_dot_fx_alpha(age)
		if c.a <= 0.01:
			continue
		_draw_diamond(to_minimap(d["pos"]), red_dot_fx_radius(age), c)
		red_dot_fx_draw_count += 1


## 一个小菱形（中心 + 半对角线）。
##
## ★ 用 `draw_colored_polygon` 而不是旋转后的 `draw_rect`：4 个点一次画完，
##   也不必为了「菱形」去改画布变换。
## ★ 暗色描边是**另画一个大一圈的菱形垫底**：小地图底色 / 迷雾都很暗，纯红边不够清楚。
func _draw_diamond(center: Vector2, r: float, col: Color) -> void:
	if r <= 0.0:
		return
	var out: Color = cfg.minimap_red_dot_outline if cfg != null else Color(0, 0, 0, 0.55)
	if out.a > 0.0:
		draw_colored_polygon(_diamond_points(center, r + maxf(1.0, r * 0.35)), out)
	draw_colored_polygon(_diamond_points(center, r), col)


## 菱形四个顶点（上 → 右 → 下 → 左）。
func _diamond_points(center: Vector2, r: float) -> PackedVector2Array:
	return PackedVector2Array([
		center + Vector2(0.0, -r),
		center + Vector2(r, 0.0),
		center + Vector2(0.0, r),
		center + Vector2(-r, 0.0),
	])


## 把一个「点」归一成格坐标的 `Vector2`（认 `Vector2` / `Vector2i` / `[x,y]` / `{x,y}`）。
## 认不出来 → `(-1,-1)`（调用方据此跳过，不会在 (0,0) 播一个假动效）。
static func _as_logic_point(p: Variant) -> Vector2:
	var t: int = typeof(p)
	if t == TYPE_VECTOR2:
		return p
	if t == TYPE_VECTOR2I:
		var v2i: Vector2i = p
		return Vector2(float(v2i.x) + 0.5, float(v2i.y) + 0.5)
	if t == TYPE_ARRAY and (p as Array).size() >= 2:
		var a: Array = p
		return Vector2(float(a[0]) + 0.5, float(a[1]) + 0.5)
	if t == TYPE_DICTIONARY:
		var d: Dictionary = p
		return Vector2(float(d.get("x", -1)) + 0.5, float(d.get("y", -1)) + 0.5)
	return Vector2(-1.0, -1.0)


## 视野框：先铺一层淡白，再描一圈亮白边。
## ★★ 画的是 `view_rect_clipped()`（裁到地图矩形里）而不是 `view_rect_local()`：
##   镜头的视野允许越出地图（屏幕能看到界外），但小地图的留边代表「这里没有地图」，
##   亮框画上去会让人以为外面还有地 —— 所以框只在地图范围内出现，
##   贴边时它的边框自然与地图边界重合。理由见 `view_rect_clipped()`。
##
## ★ 拖动中换成主题金（更浓）：这是「我现在按着的是小地图」的唯一视觉反馈 ——
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
	var c: Color = SideColorRes.color(cfg, world, faction, "main")
	_color_cache[faction] = c
	return c


## 这个单位 / 建筑现在该不该画在小地图上（战争迷雾）。
##
## ★ 与 unit_view / building_view 的同名判据完全同源：**只**问 logic/fog.gd，
##   视图不许自己算「多少格算看见」。
## ★ 没建迷雾（无头测试）或总开关关着 → 一律画。
##
## ⚠️ 刻意写成**两个**函数而不是一个带 `is BuildingRes` 判断的：建筑与单位在
##    logic/ 里是两种没有共同基类的 RefCounted，用一个函数接两种参数就只能靠
##    duck typing / `is` 猜，而猜错的代价是「静默走错分支」（例如把建筑当单位查视野）。
##    两个入口各自一行，调用点自己知道手上是什么。
func _unit_visible(u) -> bool:
	if cfg == null or world == null or world.fog == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.unit_visible(world.my_faction, u)


func _building_visible(b) -> bool:
	if cfg == null or world == null or world.fog == null:
		return true
	if not cfg.fog_enabled:
		return true
	return world.fog.building_visible(world.my_faction, b)


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


## 小地图局部坐标 → 镜头位置。
##
## ★★ 把**格坐标**交给相机替身的 `center_on_tile`（`CameraFacade` 有它）。
##   为什么必须这样（实测抓到过真 bug）：原来那条 `center_on_px(格 × cell_px)`
##   把**世界像素**当成了**屏幕像素** —— 在旧的正放 2D 世界里这两个坐标系恰好重合
##   所以「能用」，换成 3D 相机之后不重合 ⇒ 点小地图会落到别的一格（实测最大误差 **15.06 格**）。
##
## ★ 判据：**「格 → 屏幕」这条换算只能由知道相机的那一层做**。
##   小地图手里是格，就该把格交出去；不要在一个不知道相机的地方自己乘 cell_px。
func _jump_to(local_pos: Vector2) -> void:
	if camera_rig == null:
		return
	var tile: Vector2 = to_world(local_pos)
	# ⚠️ `camera_rig` 是无类型引用 ⇒ 只能走 `has_method` 运行时判据：
	#    直接写 `camera_rig.center_on_tile(...)` 会**编译期**报
	#    「Nonexistent function」并把整个文件拖成 Compilation failed（实测踩过）。
	if camera_rig.has_method("center_on_tile"):
		camera_rig.center_on_tile(tile)


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
