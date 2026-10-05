## camera_rig.gd —— 相机：键盘平移 / 边缘滚屏 / 以光标为锚点缩放 / F 适应全图
##                   （对应 HTML 版 main.js 的 updateCameraKeyboard / updateCameraEdgeScroll / clampCam / fit）
##
## ★ 相机是**纯表现**，不进快照、不进逻辑（docs/architecture.md 第五节）。
##
## ★★ 坐标约定（HTML 版为这个吃过一次大亏，见 docs/pitfalls.md 3.1）：
##    - 相机数学与所有输入换算一律用**同一套屏幕坐标**
##    - 屏幕 → 世界一律走 Camera2D 自己的换算（`get_screen_center_position()` 等），
##      **不自己手算一遍**。手算就是错位的开始。
##
## 用一个 Control 承载输入：Control 的 mouse_filter 能天然把「鼠标在 HUD 面板上」
## 的情况过滤掉，不会在点侧栏时把地图也滚走。
extends Control

const ConfigRes = preload("res://logic/config.gd")
## ★ 地图的**外接框**只有一个出处（`map_rect`）—— 相机只读它，
##   不自己拿「格数 × 格宽」再算一遍（那样迟早对不上）。
##
## ★★ 走的是 `view/palette2d.gd`（**遗留 2D 栈**的换算），不是新的 3D
##   `view/palette.gd`：本文件是 2D 遗留相机（`Camera2D`），真机在跑的是
##   `view/game_scene3d.gd`。理由与取舍写在 `palette2d.gd` 的文件头。
const Palette2DRes = preload("res://view/palette2d.gd")

signal mouse_world_changed(world_pos: Vector2)

var cfg: ConfigRes = null
var cam: Camera2D = null
var map = null

## 键盘平移（屏幕像素/秒，除 zoom 得到「看起来一样快」的世界速度）
var _pan: Vector2 = Vector2.ZERO
## 鼠标是否停在画布内（离开就停止边缘滚屏）
var _mouse_inside: bool = false
var _mouse_pos: Vector2 = Vector2.ZERO
var _space_held: bool = false
var _edge_scroll_on: bool = true
## ★ 小地图正在被拖着走（由 game_scene 每帧写）。
##
## 为什么必须让它把边缘滚屏压住（实测会撞上）：小地图贴在屏幕左下角，而
## `hud.blocks_edge_scroll()` 里有一条铁律 —— **最外圈 camera.edge_size 之内永远允许滚屏**
## （否则贴边控件会把那一条边缘的地图永久锁死）。于是玩家按住小地图下沿拖动时，
## 边缘滚屏也在推同一台相机：一帧里「跟手 → 被推向最左下 → 又跟手」，
## 画面贴着下沿会明显发抖。拖动期间只留拖动这一条路改相机，松手后边缘滚屏照旧。
var _ui_dragging_camera: bool = false
## 准星（G）：把鼠标世界坐标交给 overlay 画出来核对
var debug_aim: bool = false


func setup(p_cfg: ConfigRes, p_cam: Camera2D, p_map) -> void:
	cfg = p_cfg
	cam = p_cam
	map = p_map
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_edge_scroll_on = cfg.bool_val("camera.edge_scroll", true)
	cam.zoom = Vector2.ONE * cfg.num("camera.start_scale", 1.0)
	fit_to_map()


## ★★ 相机位置 → 「视口中心在地面上看的是哪一格」的**原点修正**。
##
## 为什么需要它（实测踩到的最大一条）：
##   投影把「格 y = 0」固定在**视口中心**（`cfg.proj_zero_y` 的语义），
##   于是 `cam.position = 地图外接框中心` 时，整张地图会**偏到画面下方**
##   （实测：wide 那张图里地图只占了下半屏，上半屏全是背景）。
##   修法是把相机的位置**平移掉「格 y = 0 的投影位置」与「视口中心」之差**：
##       cam.position = 想要的屏幕点 − 格 (0,0) 的投影坐标
##   这样 `center_on_px(某个屏幕点)` 与 `clamp_position()` 的语义都保持不变
##   （夹取范围是屏幕像素），而**地图居中**这件事就对了。
##
## ★ 这个偏移随投影参数变化（pitch / height / fov / 视口尺寸），所以要现算 ——
##   它正是「坐标映射」这条链路的起点：屏幕 → 格 的全部换算都建立在它之上。
func _projection_origin() -> Vector2:
	if cfg == null:
		return Vector2.ZERO
	return Palette2DRes.to_px(Vector2.ZERO, cfg)


func update(dt: float) -> void:
	if cam == null:
		return
	_edge_scroll(dt)
	if _pan.length_squared() > 0.0:
		cam.position += _pan * dt / cam.zoom
	clamp_position()


## 图像尺寸（屏幕像素）—— 透视下它是**地图投影后的外接框尺寸**。
##
## ★★ 为什么不能用「格数 × 格宽」（老写法）：透视之后一格占多少屏幕像素
##    **随位置变化**（近大远小），根本没有「一格 = 多少像素」这个常数。
##    唯一正确的说法是「整张地图投出来占多大一块」⇒ 走 `palette.map_rect()`。
func map_size() -> Vector2:
	return map_bounds().size


## 菱形/透视地图在**屏幕像素**里的外接框（相机夹取 / 小地图用它）。
##
## ★ 与 `palette.map_rect()` **同一个出处**：投影只有一个地方算（palette），
##   相机只是读它 —— 两处各算一遍就会出现「镜头能到的地方与地图不重合」。
func map_bounds() -> Rect2:
	if map == null or cfg == null:
		return Rect2()
	return Palette2DRes.map_rect(cfg, map.cols, map.rows)


## 相机中心可以去的范围（屏幕像素）。
##
## ★★ 透视档选的是**外接框**（绝对定位），理由：
##    地图投出来是一个**梯形**，外接框的角不属于地图 —— 那意味着贴着角时屏幕上有空白。
##    但做成「内接」会把可视范围收得很紧（而且要正确处理梯形内接，代价高）。
##    先按外接框落地，等有真实手感再决定要不要收窄（见 dev_plan_9 的待定项）。
func cam_bounds() -> Rect2:
	return map_bounds()


## ★★ 视野区间（zoom 的下限、上限）—— **唯一**允许读 camera.min_scale / max_scale 的地方。
##
## 为什么必须集中在一个函数里：需求是「把玩家的视野大小固定」，
##   而改 zoom 的途径有三条（滚轮 zoom_at、F 键 fit_to_map、开局 setup→fit_to_map）。
##   三处各写一遍夹取，早晚会出现「F 键能看全图、滚轮看不到」这种自相矛盾的状态。
##
## ⚠️ 语义提醒：Godot 的 zoom 是**放大倍数**（值越大画面越大、看到越少），
##   所以返回的 x = min_scale 是**最远**视野，y = max_scale 是**最紧**视野。
func zoom_limits() -> Vector2:
	return Vector2(
		cfg.num("camera.min_scale", 0.8),
		cfg.num("camera.max_scale", 1.6)
	)


## 把镜头限制在地图范围内。
##
## ★★ 平移阈值（需求原话）：「玩家视野可以移动到的极点为**地图边界点到屏幕中心**时的点，
##    因此玩家看到的地图界外的东西全部为默认背景」。
##    也就是 `cam.position`（= 屏幕中心所在的世界点）只能落在地图的**外接框**里。
##
##    ★ 菱形档的口径修正（重要）：外接框**不再从原点开始**。菱形地图的 AABB
##      实测是 x ∈ [−1991, 2444]（斜放之后左尖跑到负半轴），所以夹取必须用
##      `map_bounds()` 的**上下界**，而不是 `[0, size]` ——
##      用后者会把地图左半边挡在镜头之外（「推到左边界时地图还没看完」）。
##
##    三个可验证的后果（与投影无关，只跟夹取范围有关）：
##      · 贴到某条**边**的极点时，地图占屏幕的 1/2（另一半是界外的默认背景）；
##      · 贴到某个**角**的极点时，地图占屏幕的 1/4；
##      · 这条规则与 zoom 无关 —— 视野远近都不改变「中心能到哪」。
func clamp_position() -> void:
	var b := cam_bounds()
	if b.size == Vector2.ZERO:
		return
	cam.position.x = clampf(cam.position.x, b.position.x, b.end.x)
	cam.position.y = clampf(cam.position.y, b.position.y, b.end.y)


## F：把镜头拉到「能看完整张地图」需要的倍率（并居中）。
##
## ⚠️ 视野固定之后这里**夹得住**：算出来的 0.52 比 min_scale（0.8）还远，
##    所以实际落在「最远」那一档 —— F 键现在等价于「拉到最远」，看不到全图了。
##    要恢复看全图就调低 min_scale（见 config.json 的 camera._comment）。
func fit_to_map() -> void:
	if cam == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var b := map_bounds()
	var size := b.size
	if size.x <= 0.0 or size.y <= 0.0:
		return
	var s: float = minf(vp.x / size.x, vp.y / size.y) * 0.98
	var limits := zoom_limits()
	cam.zoom = Vector2.ONE * clampf(s, limits.x, limits.y)
	# ★★ 让**地图外接框的中心**落在视口中心：
	#    b.get_center() 是「地图中心投影到屏幕上的位置」，而 cam.position 是
	#    「屏幕中心现在对着哪个屏幕坐标」⇒ 要把它减去原点修正。
	cam.position = b.get_center() - _projection_origin()
	clamp_position()


## 把镜头移到某个**屏幕坐标**（`palette.to_px` 的输出）上。
##
## ★ 与 `_projection_origin()` 的减法配套：相机位置 = 屏幕点 − 原点修正。
func center_on_px(p: Vector2) -> void:
	cam.position = p - _projection_origin()
	clamp_position()


## Home：回到大本营
func center_on_home(world) -> void:
	if world == null:
		return
	var t: Vector2i = world.home_base_of(world.my_faction)
	center_on_px(Palette2DRes.to_px(Vector2(float(t.x) + 0.5, float(t.y) + 0.5), cfg))


## 以光标为锚点缩放：光标底下的地面保持不动。
## ⚠️ 夹取走 zoom_limits()：视野固定之后滚轮拉不出区间（见那里的注释）。
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := cam.get_screen_center_position() + (screen_pos - get_viewport_rect().size * 0.5) / cam.zoom
	var limits := zoom_limits()
	var current: float = cam.zoom.x
	var next: float = clampf(current * factor, limits.x, limits.y)
	if absf(next - current) < 1e-6:
		return
	cam.zoom = Vector2.ONE * next
	var after := cam.get_screen_center_position() + (screen_pos - get_viewport_rect().size * 0.5) / cam.zoom
	cam.position += before - after
	clamp_position()


## 键盘平移增量（由 input_controller 累计，这里只负责施加）
func add_pan(dir: Vector2) -> void:
	_pan = dir.normalized() * cfg.num("camera.key_pan_speed", 900.0) if dir.length_squared() > 0.0 else Vector2.ZERO


func _edge_scroll(dt: float) -> void:
	if not _edge_scroll_on or not _mouse_inside or _space_held or _ui_dragging_camera:
		return
	# ★ 用 cfg.camera_edge_size（载入时算好），不用 cfg.num("camera.edge_size")：
	#   这个数每帧读一次，而且 hud.blocks_edge_scroll 读的是**同一个字段**
	#   —— 两处各写一个 44 就会出现「看着在边缘却滚不动」。
	var margin: float = cfg.camera_edge_size
	var max_speed: float = cfg.num("camera.edge_max_speed", 1500.0)
	var vp: Vector2 = get_viewport_rect().size
	var dir := Vector2.ZERO
	# 越贴边滚得越快：归一化后取平方（与 HTML 版一致的手感）
	if _mouse_pos.x < margin:
		dir.x = -_edge_power(margin - _mouse_pos.x, margin)
	elif _mouse_pos.x > vp.x - margin:
		dir.x = _edge_power(_mouse_pos.x - (vp.x - margin), margin)
	if _mouse_pos.y < margin:
		dir.y = -_edge_power(margin - _mouse_pos.y, margin)
	elif _mouse_pos.y > vp.y - margin:
		dir.y = _edge_power(_mouse_pos.y - (vp.y - margin), margin)
	if dir.length_squared() <= 0.0:
		return
	cam.position += (dir * max_speed * dt) / cam.zoom
	clamp_position()


func _edge_power(depth: float, margin: float) -> float:
	var t: float = clampf(depth / maxf(1.0, margin), 0.0, 1.0)
	return t * t


func set_mouse(inside: bool, pos: Vector2) -> void:
	_mouse_inside = inside
	_mouse_pos = pos


func set_space_held(v: bool) -> void:
	_space_held = v


## 小地图是不是正在被拖着走（见 `_ui_dragging_camera` 的注释）。
## ★ 只由 game_scene 每帧喂进来；camera_rig 自己不认识小地图（相机不该知道鼠标在哪按的）。
func set_ui_dragging(v: bool) -> void:
	_ui_dragging_camera = v


func toggle_edge_scroll() -> bool:
	_edge_scroll_on = not _edge_scroll_on
	return _edge_scroll_on


func edge_scroll_enabled() -> bool:
	return _edge_scroll_on


## 小地图拖动是不是正压着边缘滚屏（测试读它；游戏里没人读）
func ui_dragging() -> bool:
	return _ui_dragging_camera
