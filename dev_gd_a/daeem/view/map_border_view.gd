## map_border_view.gd —— 地图边界的**金线**（贴地的一圈金色细带 + 向内的渐变 + 扫描）
##
## ★ 口径：在**可玩矩形之外** `render.map_border_offset` 格（默认 2 格）画一圈金线，
##   再从线的**内缘**朝地图内侧拉一段 `render.map_border_fade_tiles` 格（默认 0.5 格）的
##   渐变带：透明度 1 → 0。整条线另做一遍**由上往下的扫描**：平时压暗到
##   `map_border_dim_alpha`，被扫掠带扫到时升到 `map_border_scan_alpha`，扫完立刻从头再来。
##   让玩家一眼看出「地图到哪儿为止」。
##   · 位置：整张地图矩形（`world.map.cols × rows`）向外偏移 ⇒ 线落在地面平面**之外**；
##   · 宽度：**世界单位**（不是屏幕像素）⇒ 镜头缩放时跟着变粗变细；
##   · 渐变长度：**格**（默认 0.5 格），方向朝地图内侧；
##   · 扫描方向：从地图**上沿**（世界 −z 那一侧）移向下沿，一遍 `map_border_scan_sec` 秒，循环；
##   · 范围：只挂在游戏内场景（`view/game_scene3d.gd`），两个编辑器都不画。
##
## ★★ 分工：**几何**管「线在哪、多宽、渐变多长」（`_build_mesh`），
##   **shader**（`view/map_border.gdshader`）管「扫描扫到哪儿、那一段多亮」。
##   扫描必须在**片元**里算 —— 网格只有 12 个顶点，而上下两条边整条共用一个 z，
##   顶点级的带子在它们身上插不出「一段光带」（详见那个 shader 的文件头）。
##
## ★★ 为什么是一圈**贴地的四边形带**，而不是屏幕空间矢量或引擎线段图元：
##   · 屏幕空间那套（`view/overlay_view_3d.gd` 的 `draw_multiline`）画不了它 ——
##     线在地面矩形**之外**，那里没有格子、也没有稳定的投影参考点；
##   · `Mesh.PRIMITIVE_LINES` 的线宽恒为 1 **屏幕像素**，做不出「世界单位固定宽度」；
##   ⇒ 用 `SurfaceTool` 拼两圈框（金线本体 + 渐变带）= **1 次 draw call**。
##
## ★ 它是**纯表现**：只读 `world.map.cols` / `rows`，不进快照、不改逻辑、无碰撞。
extends Node3D

const ConfigRes = preload("res://logic/config.gd")
const ShaderRes = preload("res://view/map_border.gdshader")

## 线离地面的高度（世界单位）：唯一的作用是与地面平面错开一点，别共面。
## ★ 取与迷雾层同一档（`ground_view.gd` 把迷雾平面抬了 1.5）。
## ⚠️ 它刻意**不在 config 里**：这是「避免共面」的实现细节，不是可调的手感参数。
const BORDER_Y := 1.5

## 顶点色只用来带 **alpha**（rgb 全 1）：颜色由材质的 albedo 给，
## 于是「金线本体」与「渐变末端」是同一个颜色的两个透明度。
const V_SOLID := Color(1.0, 1.0, 1.0, 1.0)
const V_CLEAR := Color(1.0, 1.0, 1.0, 0.0)

var cfg: ConfigRes = null
var world = null
var palette = null

## 这一圈线的**中心**所在的格坐标矩形（左上角在 (-offset, -offset)，尺寸 = 地图 + 两侧各 offset）。
## 测试与排查读它 —— 它是「线到底画在哪」的唯一答案，别去反推网格。
## ★ 渐变带在它**内侧**再延伸 fade 格（几何见 `_build_mesh`）。
var border_tiles: Rect2 = Rect2()

var _mesh: MeshInstance3D = null
var _mat: ShaderMaterial = null

## ---- 扫描（纯表现，只在装配时读一次 config）----
## ★ 「上」= 世界 z **小**那一侧：相机固定待在 +z 那一侧朝 −z 看 ⇒ z 越小越靠屏幕上方。
var _scan_t: float = 0.0          # 本遍已经走了多少秒
var _scan_period: float = 7.0     # 一遍多少秒
var _scan_half: float = 0.0       # 扫掠带的**半**长（世界单位）
var _z_top: float = 0.0           # 线最靠上（最小 z）的那条边
var _z_bottom: float = 0.0        # 线最靠下（最大 z）的那条边


func setup(p_cfg: ConfigRes, p_world, p_palette) -> void:
	cfg = p_cfg
	world = p_world
	palette = p_palette
	_mesh = MeshInstance3D.new()
	_mesh.name = "MapBorderMesh"
	_mesh.mesh = _build_mesh()
	_scan_period = maxf(0.1, cfg.num("render.map_border_scan_sec", 7.0))
	_scan_half = maxf(0.0, cfg.num("render.map_border_scan_tiles", 4.0)) \
		* palette.cell_size() * 0.5
	_mat = _make_material()
	_mesh.material_override = _mat
	add_child(_mesh)
	sync(0.0)                      # 开局把扫掠带摆在上沿：第一遍从上往下扫


## 每帧推进扫描（纯表现：只改 shader uniform，不动网格、不重建材质）。
##
## ★ 由**上**往下 = 世界 z 从小到大（见 `_z_top` 的说明）。
## ★ 两端各多走一个半宽再折返：扫掠带能**完整地**进来、再完整地出去 ——
##   否则每循环一次都会「半条带子突然凭空出现 / 消失」。
## ★ 与单位 / 旗子那些视图同一条调用方式：由 `game_scene3d._process` 每帧喂 `dt`，
##   暂停时照旧走（本项目口径：暂停冻结逻辑，渲染与相机照旧）。
func sync(dt: float) -> void:
	if _mat == null:
		return
	_scan_t = fmod(_scan_t + maxf(0.0, dt), _scan_period)
	var phase: float = _scan_t / _scan_period
	_mat.set_shader_parameter("scan_z",
		lerpf(_z_top - _scan_half, _z_bottom + _scan_half, phase))


## 金线本体 + 向内的渐变带（合成后是 1 次 draw call）。
##
## ★★ 三条等距轮廓（都按「离地图外沿多少**世界单位**」算，越大 = 离地图越远）：
##      `t_out` = 线的**外**缘、`t_mid` = 线的**内**缘、`t_in` = 渐变的消失端。
##    于是：金线本体 = `t_out…t_mid`（不透明），渐变带 = `t_mid…t_in`（1 → 0）。
##
## ⚠️ `t_in` 夹在 0（= 地图外沿）以上：渐变带**不会越过地图边界**爬到地形上去 ——
##    哪怕 fade 给得比 offset 还大。要在图上看到渐变就往里挪 offset，别指望它翻过边界。
func _build_mesh() -> ArrayMesh:
	var cell: float = palette.cell_size()
	var cols: float = float(world.map.cols)
	var rows: float = float(world.map.rows)
	var off: float = maxf(0.0, cfg.num("render.map_border_offset", 2.0))
	var half: float = maxf(0.1, cfg.num("render.map_border_width", 6.0)) * 0.5
	var fade: float = maxf(0.0, cfg.num("render.map_border_fade_tiles", 0.5)) * cell

	var t_out: float = off * cell + half
	var t_mid: float = maxf(0.0, off * cell - half)
	var t_in: float = maxf(0.0, t_mid - fade)
	border_tiles = Rect2(Vector2(-off, -off), Vector2(cols + off * 2.0, rows + off * 2.0))
	# 扫描的两端 = 线最靠上 / 最靠下的那条边（世界 z）
	_z_top = -t_out
	_z_bottom = rows * cell + t_out

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_ring(st, t_out, t_mid, V_SOLID, V_SOLID)          # ① 金线本体
	if fade > 0.0 and t_mid > t_in:
		_add_ring(st, t_mid, t_in, V_SOLID, V_CLEAR)        # ② 向地图内侧的渐变
	st.index()
	return st.commit()


## 「离地图 rect 外沿 `t` 个世界单位」的那一圈矩形的四个角（世界 XZ；y 由 `BORDER_Y` 统一给）。
func _rect_corners(t: float) -> PackedVector2Array:
	var right: float = float(world.map.cols) * palette.cell_size() + t
	var bottom: float = float(world.map.rows) * palette.cell_size() + t
	return PackedVector2Array([
		Vector2(-t, -t), Vector2(right, -t), Vector2(right, bottom), Vector2(-t, bottom),
	])


## 在「离地图 `t_a`」与「离地图 `t_b`」两圈矩形之间铺一圈框（4 个四边形，1 次 draw call）。
##
## ★★ 相邻两条边在拐角处**共用顶点**（同一圈矩形的同一个角）⇒ 框的拐角是 45° 斜接。为什么必须这样：
##   · 若像「方头拼角」那样让两个四边形在角上重叠，**半透明下会双层叠加** ——
##     角上比边上亮一块（加了渐变之后，这一块会被看成「角上渐变没对齐」）；
##   · 共用顶点同时也保证没有缺口。
## ★ 两端顶点的颜色不同（`c_a` / `c_b`）⇒ 三角形内按世界位置线性插值，就是那条渐变。
func _add_ring(st: SurfaceTool, t_a: float, t_b: float, c_a: Color, c_b: Color) -> void:
	var a: PackedVector2Array = _rect_corners(t_a)
	var b: PackedVector2Array = _rect_corners(t_b)
	for i in 4:
		var j: int = (i + 1) % 4
		_vert(st, a[i], c_a)
		_vert(st, a[j], c_a)
		_vert(st, b[j], c_b)
		_vert(st, a[i], c_a)
		_vert(st, b[j], c_b)
		_vert(st, b[i], c_b)


func _vert(st: SurfaceTool, p: Vector2, c: Color) -> void:
	st.set_color(c)
	st.set_normal(Vector3.UP)
	st.add_vertex(Vector3(p.x, BORDER_Y, p.y))


## 材质：**ShaderMaterial**（扫描要在片元里按世界 z 算，StandardMaterial3D 做不到）。
##
## ★ 颜色与两个透明度值走 uniform（config 的三个键）；扫掠带的位置由 `sync()` 每帧推。
## ★ 渐变不带 uniform：它由**顶点色 alpha** 表达，shader 只把它搬到 ALPHA 上。
func _make_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ShaderRes
	m.set_shader_parameter("line_color",
		ConfigRes.parse_color(cfg.str_val("render.map_border_color", "#ffd166")))
	m.set_shader_parameter("scan_half", _scan_half)
	m.set_shader_parameter("dim_alpha",
		clampf(cfg.num("render.map_border_dim_alpha", 0.45), 0.0, 1.0))
	m.set_shader_parameter("scan_alpha",
		clampf(cfg.num("render.map_border_scan_alpha", 1.0), 0.0, 1.0))
	m.set_shader_parameter("scan_z", _z_top - _scan_half)
	return m
