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


func update(dt: float) -> void:
	if cam == null:
		return
	_edge_scroll(dt)
	if _pan.length_squared() > 0.0:
		cam.position += _pan * dt / cam.zoom
	clamp_position()


## 图像尺寸（世界单位）
func map_size() -> Vector2:
	return Vector2(map.cols, map.rows) * cfg.cell_px


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
##    也就是 `cam.position`（= 屏幕中心所在的世界点）只能落在 [0, 地图宽] × [0, 地图高]。
##
##    三个可验证的后果：
##      · 贴到某条**边**的极点时，地图占屏幕的 1/2（另一半是界外的默认背景）；
##      · 贴到某个**角**的极点时，地图占屏幕的 1/4；
##      · 这条规则与 zoom 无关 —— 视野远近都不改变「中心能到哪」，只改变看得见多少。
##
## ⚠️ 与旧行为的区别（旧的是「地图铺满屏幕、界外一点都看不到」）：
##    旧分支是 `clampf(pos, half, size - half)`，现在两极都放开到 0 / size。
##    **不需要**再写「地图比视口小就居中」那条分支了：`size.x - half.x` 在这种情形下
##    本来就小于 `half.x`，区间左右颠倒；而现在的区间是 [0, size]，永远合法，
##    且它的语义（中心可以推到边界上）对大地图 / 小地图是同一条。
func clamp_position() -> void:
	var size := map_size()
	cam.position.x = clampf(cam.position.x, 0.0, size.x)
	cam.position.y = clampf(cam.position.y, 0.0, size.y)


## F：把镜头拉到「能看完整张地图」需要的倍率（并居中）。
##
## ⚠️ 视野固定之后这里**夹得住**：算出来的 0.52 比 min_scale（0.8）还远，
##    所以实际落在「最远」那一档 —— F 键现在等价于「拉到最远」，看不到全图了。
##    要恢复看全图就调低 min_scale（见 config.json 的 camera._comment）。
func fit_to_map() -> void:
	if cam == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var size := map_size()
	var s: float = minf(vp.x / size.x, vp.y / size.y) * 0.98
	var limits := zoom_limits()
	cam.zoom = Vector2.ONE * clampf(s, limits.x, limits.y)
	cam.position = size * 0.5
	clamp_position()


## 把镜头移到某个世界（像素）位置
func center_on_px(p: Vector2) -> void:
	cam.position = p
	clamp_position()


## Home：回到大本营
func center_on_home(world) -> void:
	if world == null:
		return
	var t: Vector2i = world.home_base_of(world.my_faction)
	center_on_px(Vector2(float(t.x) + 0.5, float(t.y) + 0.5) * cfg.cell_px)


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
