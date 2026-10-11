## palette.gd —— 配色、坐标换算与 3D 地面投影的**唯一**入口
##
## ★★ 两条铁律（HTML 版为这两件事吃过两次大亏，见 docs/pitfalls.md 3.1）：
##
##   1. **逻辑坐标是「格」**，`logic/` 里一格不改；世界/屏幕坐标只出现在 `view/`。
##   2. **换算只有一处**：正向（格 → 屏幕）与逆向（屏幕 → 格）必须由**同一个相机**
##      导出。本项目为此吃过一次大亏（HTML 版「画用一套、鼠标换算用另一套」）。
##
## ---------------------------------------------------------------------------
## ★★ 3D 地面平面投影（本版，取代之前的 2D 仿射/菱形/手算透视）
##
##   世界模型：地面是 **y = 0 的水平平面**，逻辑格 (x, y) → 世界点 (x·cell, 0, y·cell)。
##   镜头是一台**真实的 `Camera3D`**（固定俯角，只平移 + 缩放）。
##   于是：
##       · 格 → 屏幕 = `Camera3D.unproject_position(世界点)`
##       · 屏幕 → 格 = `Camera3D.project_ray_normal(屏幕点)` 与地面求交
##   ★★ 为什么必须交给引擎（这三条是本版最重要的取舍）：
##       之前那版用**手算的透视公式**，出过两个真问题：
##         ① 「向下滑动时地块越来越大」—— 手算的深度项让收缩过强；
##         ② 拖框起点在相机移动时自己漂 —— 起点是格坐标，每次重投影都要用同一条链路。
##       交给引擎之后，投影/求交/相机数学**只有一份实现**，不存在「算得不一样」。
##
##   ★ 「精确正交」的等价性：相机 **不俯仰旋转**（`rotation = (0,0,0)`）、镜头沿自身
##     坐标轴的平移 = 沿地面平移 ⇒ 同一个格在任何高度看到的屏幕位置**完全相同**
##     （实测验证见 tests/test_view.gd 的「平移不改变投影」）。这样「相机在同一高度」
##     这件事不需要额外保证 —— 它是这台相机的物理事实。
## ---------------------------------------------------------------------------
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")


## 从配置造一份投影助手。`cam` 是**当前**那台活动相机（切场景会换）。
static func create(p_cfg: ConfigRes, p_cam: Camera3D) -> RefCounted:
	var p = new()
	p.cfg = p_cfg
	p.cam = p_cam
	return p


var cfg: ConfigRes = null
var cam: Camera3D = null


# ------------------------------------------------------------------
# 格 ↔ 世界 ↔ 屏幕
# ------------------------------------------------------------------

## 逻辑坐标（格）→ 3D 世界坐标（y = 0 的地面）
func to_world(logic_pos: Vector2) -> Vector3:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return Vector3(logic_pos.x * c, 0.0, logic_pos.y * c)


## 3D 世界坐标 → 逻辑坐标（格）；只取地面上的 x / z（y 被忽略）
func world_to_logic(w: Vector3) -> Vector2:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return Vector2(w.x / c, w.z / c)


## 逻辑坐标（格）→ **屏幕像素**（视口坐标，左上角为原点）
##
## ★ UI 类的元素（字 / 血条 / 标记）都用它定位：3D 相机把世界投到屏幕上，
##   那些元素在 `CanvasLayer` 上按屏幕坐标画，天然 1:1、且不会跟着地面倾斜。
func to_px(logic_pos: Vector2) -> Vector2:
	if cam == null:
		return Vector2.ZERO
	return cam.unproject_position(to_world(logic_pos))


## 屏幕像素 → 逻辑坐标（格）：**从相机往地面打一条射线求交**。
##
## ★ 这是输入层唯一的口径（点选、拖框、建造预览、悬停格全走它）。
## ⚠️ 射线与地面平行/朝上时**没有交点**（相机贴着地平线看）——那时返回 `null`，
##   调用方必须处理（本项目的地面相机永远是俯视的，正常不会发生）。
func to_logic(screen_px: Vector2) -> Variant:
	if cam == null:
		return null
	var origin: Vector3 = cam.project_ray_origin(screen_px)
	var dir: Vector3 = cam.project_ray_normal(screen_px)
	# 地面是 y = 0：origin.y + t·dir.y = 0
	if absf(dir.y) < 1e-9:
		return null
	var t: float = -origin.y / dir.y
	if t <= 0.0:
		return null
	return world_to_logic(origin + dir * t)


## 一个地块在地面上的四个世界坐标角点（顺序：左上 → 右上 → 右下 → 左下）
##
## ★ 3D 里「一个地块」就是一个 1×1 格的水平方块；画线框 / 高亮 / 建造预览都用它。
func tile_corners_world(tx: int, ty: int) -> PackedVector3Array:
	return PackedVector3Array([
		to_world(Vector2(float(tx), float(ty))),
		to_world(Vector2(float(tx + 1), float(ty))),
		to_world(Vector2(float(tx + 1), float(ty + 1))),
		to_world(Vector2(float(tx), float(ty + 1))),
	])


## 整张地图的世界矩形（相机夹取 / 地面网格尺寸用它）
func map_world_rect(cols: int, rows: int) -> Rect2:
	var c: float = cfg.cell_px if cfg != null else 128.0
	return Rect2(Vector2.ZERO, Vector2(float(cols) * c, float(rows) * c))


## 一个格在世界里占多少长度（= 格宽；给 3D 网格尺寸用）
func cell_size() -> float:
	return cfg.cell_px if cfg != null else 128.0


# ------------------------------------------------------------------
# 配色（内层循环查表用）
# ------------------------------------------------------------------

## 一种地形的颜色（`TerrainView` 那种「按种类查一次表」的写法）
func terrain_color(kind: String) -> Color:
	match kind:
		"mountain":
			return cfg.color("mountain")
		"forest":
			return cfg.color("forest")
		_:
			return cfg.color("grass")


## 阵营主色
func faction_color(faction: String) -> Color:
	return cfg.faction_color(faction, "main")


## 一个地块在屏幕上的**四个角**（顺序：左上 → 右上 → 右下 → 左下）
##
## ★★ 3D 版为什么还留着这个「2D 式」的接口：它表示「**地面上一格的轮廓**」，
##    用途是**屏幕空间的 UI**（建造预览的高亮框、拖框、`test_view` 的几何断言）。
##    ⚠️ 它不是「一格的贴图矩形」—— 那个由 `ground_view.gd` 的烘图负责。
##    ★ 透视下它**不是矩形**（是梯形），所以返回值是四个点而不是 `Rect2`：
##      任何「只投中心再套一个矩形」的写法在 3D 下都是错的。
func tile_poly(tx: int, ty: int) -> PackedVector2Array:
	return PackedVector2Array([
		to_px(Vector2(float(tx), float(ty))),
		to_px(Vector2(float(tx + 1), float(ty))),
		to_px(Vector2(float(tx + 1), float(ty + 1))),
		to_px(Vector2(float(tx), float(ty + 1))),
	])


## 建筑本体在地面上的**四个角**（中心 + `body_scale` 的半宽 / 半高）
##
## ★ 尺寸**只有一个来源**：logic 的 `building.body_scale()`（墙体 1.0 = 填满整格，
##   大本营 / 箭塔 0.6 = 居中留边）。这里不许再写一套内缩量。
func building_poly(b) -> PackedVector2Array:
	var half: float = b.body_scale(cfg) * 0.5
	var c: Vector2 = b.center()
	return quad_poly(c.x - half, c.y - half, c.x + half, c.y + half)


## 一个**格坐标矩形**（x0..x1, y0..y1）在地面上的四个角
func quad_poly(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([
		to_px(Vector2(x0, y0)),
		to_px(Vector2(x1, y0)),
		to_px(Vector2(x1, y1)),
		to_px(Vector2(x0, y1)),
	])


## 颜色混合：把 over 以 alpha 叠在 base 上
static func mix(base: Color, over: Color, t: float) -> Color:
	return base.lerp(over, clampf(t, 0.0, 1.0))
