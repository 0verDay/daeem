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


## 把镜头限制在地图范围内（地图比视口小时直接居中）
func clamp_position() -> void:
	var vp: Vector2 = get_viewport_rect().size / cam.zoom
	var size := map_size()
	var half := vp * 0.5
	if size.x <= vp.x:
		cam.position.x = size.x * 0.5
	else:
		cam.position.x = clampf(cam.position.x, half.x, size.x - half.x)
	if size.y <= vp.y:
		cam.position.y = size.y * 0.5
	else:
		cam.position.y = clampf(cam.position.y, half.y, size.y - half.y)


## F：缩到能看完整张地图（并居中）
func fit_to_map() -> void:
	if cam == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var size := map_size()
	var s: float = minf(vp.x / size.x, vp.y / size.y) * 0.98
	cam.zoom = Vector2.ONE * clampf(s, cfg.num("camera.min_scale", 0.18), cfg.num("camera.max_scale", 1.6))
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


## 以光标为锚点缩放：光标底下的地面保持不动
func zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := cam.get_screen_center_position() + (screen_pos - get_viewport_rect().size * 0.5) / cam.zoom
	var lo: float = cfg.num("camera.min_scale", 0.18)
	var hi: float = cfg.num("camera.max_scale", 1.6)
	var current: float = cam.zoom.x
	var next: float = clampf(current * factor, lo, hi)
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
	if not _edge_scroll_on or not _mouse_inside or _space_held:
		return
	var margin: float = cfg.num("camera.edge_size", 44.0)
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


func toggle_edge_scroll() -> bool:
	_edge_scroll_on = not _edge_scroll_on
	return _edge_scroll_on


func edge_scroll_enabled() -> bool:
	return _edge_scroll_on
