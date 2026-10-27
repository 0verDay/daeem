## overlay_layer.gd —— 覆盖层的一个**独立绘制层**（目前只用于「静态层」）。
##
## ★★ 为什么要有这一层（2026.10.27，性能）：
##   Godot 的 `CanvasItem` 只在**被 `queue_redraw()` 标脏**时重新走一遍 `_draw()`；
##   一次 `_draw()` 里的所有 `draw_*` 调用会变成该 CanvasItem 的**命令缓冲**，
##   之后每帧由渲染器重放，**不再付脚本侧的录制成本**。
##   而 `overlay_view_3d` 为了画血条 / 拖框 / 编队标识必须每帧 `queue_redraw()` ——
##   于是网格、区划轮廓、占领触发区这些**只随相机与归属变化**的东西被连带重录了一遍。
##   桌面实测：`draw/overlay 1.244 ms/帧`，其中 `ov/capture_area 0.744`、`ov/grid_outline 0.035`。
##
##   ⇒ 把静态部分放进这个**独立的子节点**，只让它在「相机 / 视口 / 区划归属」变化时
##     重新录制；相机静止时这部分成本降到 ~0（命令缓冲照旧由渲染器重放）。
##
## ★ 用 `show_behind_parent = true` 保证它画在**宿主自己的绘制之下**：
##   宿主要每帧画单位血条 / 拖框 / 编队标识（都在静态层之上），
##   而子节点默认是画在父节点之上的。z 序在这里是视觉正确的一部分，不是风格问题。
##
## ★★ 为什么绘制代码在**本文件**里，而不是「宿主算好、调 `node.draw_*()`」：
##   实测（Godot 4.7）`draw_*` 只允许在**它自己**的 `_draw()` 里调用 ——
##   从宿主的 `_draw` 里调 `layer.draw_polygon()` 会报
##   "Drawing is only allowed inside this node's `_draw()`"。
##   所以这里的分工是：宿主只**算几何**（`build_static_layer_data`），本节点只**发绘制**。
##
## ★ 这一层**不接受任何输入**（`MOUSE_FILTER_IGNORE`）：输入全部走 `input_controller`，
##   覆盖层只负责画。
extends Control

## 宿主（`overlay_view_3d`）。只调它的 `build_static_layer_data(self)`，不反向持有别的状态。
var host = null
## 画哪一层：0 = 静态层。留着这个参数是为了将来再加一层（例如「半静态」）时不必改接口。
var which: int = 0

# ---- 由宿主每帧（其实只在重画时）填进来的绘制数据 ----
## 网格线顶点（成对：起点、终点）；空 = 不画
var grid_pts: PackedVector2Array = PackedVector2Array()
var grid_color: Color = Color(1.0, 1.0, 1.0, 0.16)
var grid_width: float = 2.0
## 区划轮廓：每项 `{segs: PackedVector2Array, color: Color}`
var zone_groups: Array = []
var zone_width: float = 2.5
## 占领触发区：每项 `{pts: PackedVector2Array(4), colors: PackedColorArray(4)}`
## （**已由宿主验过面积与凸性** —— 这里只发绘制，不再做任何判定）
var capture_quads: Array = []


func _draw() -> void:
	if host == null:
		return
	if which == 0:
		host.build_static_layer_data(self)
		_draw_static()


func _draw_static() -> void:
	if not grid_pts.is_empty():
		draw_multiline(grid_pts, grid_color, grid_width)
	for entry in zone_groups:
		var segs: PackedVector2Array = entry["segs"]
		if not segs.is_empty():
			draw_multiline(segs, (entry["color"] as Color), zone_width)
	for q in capture_quads:
		draw_polygon(q["pts"], q["colors"])
