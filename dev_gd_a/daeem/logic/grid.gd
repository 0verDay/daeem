extends RefCounted
##
## 网格容器 + 索引换算 + 方向集（对应 HTML 版 js/util.js 的 Grid / DIRS4 / idx / in_bounds）。
##
## 为什么单独一个类：A*、连通性修正、区块 lookup 都按「一维数组 + 索引换算」存，
## 比嵌套数组快一点，也避免越界直接崩。
##
## ⚠️ logic/ 的全部坐标都是「格」，不是像素。像素只在 view/ 里出现，
##    换算只有一个系数（config.json 的 render.cell_px）。见 docs/pitfalls.md 3.1。
##
## ★★ 八方向 vs 四连通（这是本项目**有意偏离** HTML 版规则的一处，见 docs/route.md 第五节）
##   HTML 版是四连通；Godot 版改成八方向，因为四连通在斜向绕障时必然走成阶梯，
##   拉直只能部分补救。开关在 config.json 的 `path.diagonal`。
##
##   四连通那一套**没有删**：`directions(cfg)` 会在 diagonal=false 时返回 DIRS4，
##   所以「四连通行为」永远可以用一次配置切换回来（测试与对照都要靠它）。
##
##   ⚠️ 八方向的代价与启发式**必须成对改**：斜走 1.414 而不是 1，
##      启发式也要从曼哈顿换成 octile，否则 A* 会偏爱斜线、给出明显绕远的路。
##      见 pathfinder.find_path() 与 octile_distance()。

## 四连通方向（上、右、下、左）
const DIRS4: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
]

## 四个对角（只在八方向下使用）
const DIRS4_DIAGONAL: Array[Vector2i] = [
	Vector2i(1, -1),
	Vector2i(1, 1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

## 八方向 = 四连通 + 四对角
const DIRS8: Array[Vector2i] = [
	Vector2i(0, -1),
	Vector2i(1, 0),
	Vector2i(0, 1),
	Vector2i(-1, 0),
	Vector2i(1, -1),
	Vector2i(1, 1),
	Vector2i(-1, 1),
	Vector2i(-1, -1),
]

## 斜向走一步的代价（√2 ≈ 1.414）。直走是 1。
const DIAGONAL_COST := 1.4142135623730951

var cols: int = 0
var rows: int = 0
var data: Array = []


## 当前配置下使用哪套方向。**所有遍历方向的地方都该走这个函数**，
## 这样「切回四连通」只需要改一个配置项，不必翻遍代码。
static func directions(cfg) -> Array[Vector2i]:
	if cfg != null and not cfg.bool_val("path.diagonal", true):
		return DIRS4
	return DIRS8


static func is_diagonal(d: Vector2i) -> bool:
	return d.x != 0 and d.y != 0


## 一步的「距离」权重：直走 1，斜走 √2。
static func step_length(d: Vector2i) -> float:
	return DIAGONAL_COST if is_diagonal(d) else 1.0


## 八方向距离（octile）：与 step_length() 同一套口径，因此是**可采纳的**启发式。
##
## 为什么不能用曼哈顿：八方向下曼哈顿会高估（对角一步覆盖了 2 的曼哈顿距离、
## 却只花 1.414），高估的启发式会让 A* 找到的路径不是最短的。
static func octile_distance(dx: int, dy: int) -> float:
	var ax := absi(dx)
	var ay := absi(dy)
	var straight := absi(ax - ay)
	var diag := mini(ax, ay)
	return float(straight) + float(diag) * DIAGONAL_COST


func _init(p_cols: int = 0, p_rows: int = 0, fill_value: Variant = null) -> void:
	cols = p_cols
	rows = p_rows
	data = []
	data.resize(cols * rows)
	data.fill(fill_value)


func has(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < cols and y < rows


func idx(x: int, y: int) -> int:
	return y * cols + x


func get_cell(x: int, y: int) -> Variant:
	if not has(x, y):
		return null
	return data[y * cols + x]


func set_cell(x: int, y: int, v: Variant) -> bool:
	if not has(x, y):
		return false
	data[y * cols + x] = v
	return true


## 遍历所有格子：fn(x, y, value)
func for_each(fn: Callable) -> void:
	for y in rows:
		for x in cols:
			fn.call(x, y, data[y * cols + x])


func count_where(fn: Callable) -> int:
	var n := 0
	for y in rows:
		for x in cols:
			if fn.call(data[y * cols + x], x, y):
				n += 1
	return n


func clone():
	var g = new(cols, rows)
	g.data = data.duplicate()
	return g


## 连续坐标（格）→ 所在地块。只用于「我在哪个区块 / 谁在射程内」这类判定，
## 不用于移动本身 —— 单位位置是连续浮点，不吸附格心。
static func tile_of(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x), floori(p.y))


## 地块 → 该地块中心（逻辑坐标里就是 +0.5）
static func center_of(t: Vector2i) -> Vector2:
	return Vector2(t.x + 0.5, t.y + 0.5)
