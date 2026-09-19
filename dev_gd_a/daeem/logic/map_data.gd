extends RefCounted
##
## 载入 map_01.json + 连通性修正（对应 HTML 版 js/map.js）。
##
## 地形用字符串网格存（'grass' / 'forest' / 'mountain'），**不是** TileMapLayer 的属性。
## 理由见 docs/pitfalls.md 2.2：换一张图集/改一个图块属性不该悄悄改变玩法。
## TileMapLayer 只负责“画”。
##
## ★★ 两张网格，别混起来：
##   · exists  —— 这个地块**存不存在**。0 = 地图外（虚线格），一律不可通行。
##                地图编辑器（tools/map_editor）拖出来的非矩形地图就靠它表示形状；
##                手写的老地图里没有这个字段 → 默认**全部存在**（行为一字不变）。
##   · terrain —— 存在的地块是什么地形（草地 / 森林 / 山地）。
##   判定通行性的唯一入口是 terrain_walkable()：不存在 → 不可通行。
##
## 生成顺序（有讲究，别调换）：
##   1. 读 layout 铺地形（不存在的地块也拿一个地形值，但以 exists 为准）
##   2. 连通性修正：从大本营四连通走不到的「可通行格」直接变成山
##      → 保证寻路永远不会出现「看着能走其实走不到」
##   3. 之后才把大本营**建筑**放进建筑表（它是建筑，不是地形）
##

const TERRAIN_GRASS := "grass"
const TERRAIN_FOREST := "forest"
const TERRAIN_MOUNTAIN := "mountain"

## ⚠️ 跨文件引用只用**自己文件里的 preload 常量**：命令行 `--script` 下全局 class_name
##    表不可用，写 `GridRes` / `Config` 作类型会直接 Parse Error（见 docs/pitfalls.md 第五节）。
const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")

## 图例：'.' 草地　'^' 森林　'#' 山地（'B' 兼容旧文件，本轮 map_01.json 不用它）
const LAYOUT_LEGEND := {
	".": TERRAIN_GRASS,
	"^": TERRAIN_FOREST,
	"#": TERRAIN_MOUNTAIN,
	"B": TERRAIN_GRASS,
}

var terrain: GridRes = null
## 哪个地块真的存在（true）/ 是地图外（false）—— 地图编辑器导出的非矩形地图靠它。
## 老地图没有 exists 字段时全部为 true（行为与加这个字段之前一字不差）。
var exists: GridRes = null
var cols: int = 0
var rows: int = 0
## 大本营坐标（单机 = 地图中心；P1 的出生点）
var base: Vector2i = Vector2i.ZERO
## ★ 各阵营自己的大本营（地图编辑器「阵营」页签划出来的）：{"player": Vector2i, "p1": …}。
##
## 与上面那个单数 `base` 的关系（别搞混）：
##   · `faction_bases` 有这一方 → 就用它（编辑器里明确指定的，优先）；
##   · 没有 → `spawn_layout_for` 退回老行为：主阵营用 `base`（地图中心），
##     其他阵营按序号轮流用 `pvp_points`。
## 老地图没有这个字段 → 空字典 → **行为与加这个功能之前一字不差**。
var faction_bases: Dictionary = {}
## 阵营表（地图编辑器给：id / 名字 / 颜色）。游戏逻辑**不读**它，留着给 UI 与工具用。
var factions_meta: Array = []
## 将领开局站位（单机用，也是 P1 的）
var general_spawns: Array[Vector2i] = []
## 多玩家起点（本轮不用，第 1 轮联机用）
var pvp_points: Array[Vector2i] = []
## 地图上**预置**的建筑：每项 {"type": String, "x": int, "y": int, "owner": String}。
##
## 用途：摆「对家的小据点」这类固定摆设（测试 / 剧情），坐标与归属全部写在 map json 里，
## 代码里不写死任何坐标。world.reset() 会在各阵营出生点建好之后把它们放上去
## （silent = true，不刷事件；最后统一 refresh_ownership()）。
##
## ★ 归属只影响「挡谁 / 打谁」，**不会**替它抢占区块：zone.refresh_building_ownership()
##   只认 is_player_faction 的阵营，所以 "enemy" 的据点不会把区块吃掉（玩家照样能占领）。
var prefab_buildings: Array[Dictionary] = []
## 地图上**预置**的单位：每项 {"kind": String, "x": int, "y": int, "faction": String,
##                            "name": String, "hold": bool}。
##
## 用途：摆「测试用的敌方守军」这类固定单位。`hold = true` 的单位**不执行推进 AI**
## （不会朝玩家据点行军），而是原地驻守、有人靠近就迎战 —— 拿来当靶子/测试用最省事。
## 只有 kind 目前只支持 "enemy"（测试敌人）；以后要放别的兵种，往这里加即可。
var prefab_units: Array[Dictionary] = []
## 被连通性修正“封成山”的孤岛格数（测试与日志会看它）
var sealed_islands: int = 0

## 区块网格（地图编辑器给）：每格一个区块 id（-1 = 不属于任何区块），行 × 列。
## 老地图没有这个字段 → 空数组 → zone.build_from_map 走「6×4 均分」的老路。
## 名字表：id → 名字（编辑器导出的 zone_list 里那一列）。
var zones_grid: Array = []
var zones_names: Dictionary = {}


static func load_from(path: String, cfg: ConfigRes):
	var m = new()
	if not m._load(path, cfg):
		return null
	return m


func _load(path: String, cfg: ConfigRes) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("打不开地图文件：%s" % path)
		return false
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("map json 不是合法 JSON 对象：%s" % path)
		return false
	var d: Dictionary = parsed

	cols = int(d.get("cols", cfg.cols))
	rows = int(d.get("rows", cfg.rows))
	terrain = GridRes.new(cols, rows, TERRAIN_GRASS)
	# 先假定处处存在，再按 exists 覆盖 —— 老地图没有这个字段时就是「整张矩形」
	exists = GridRes.new(cols, rows, true)
	_read_exists(d.get("exists", null))

	var layout: Array = d.get("layout", [])
	for y in rows:
		var row := ""
		if y < layout.size():
			row = String(layout[y])
		for x in cols:
			var ch := "."
			if x < row.length():
				ch = row.substr(x, 1)
			terrain.set_cell(x, y, LAYOUT_LEGEND.get(ch, TERRAIN_GRASS))

	base = _read_point(d.get("base", null), Vector2i(cols / 2, rows / 2))
	general_spawns.clear()
	for p in _read_points(d.get("general_spawns", [])):
		general_spawns.append(p)
	pvp_points.clear()
	for p in _read_points(d.get("pvp_points", [])):
		pvp_points.append(p)
	_read_faction_bases(d.get("faction_bases", null))
	factions_meta = d.get("factions", []) if d.get("factions", []) is Array else []
	prefab_buildings = _read_buildings(d.get("buildings", []))
	prefab_units = _read_units(d.get("units", []))
	_read_zones(d.get("zones", null), d.get("zone_list", null))

	forest_mult = cfg.unit_forest_mult
	diagonal = cfg.bool_val("path.diagonal", true)
	dirs = GridRes.DIRS8 if diagonal else GridRes.DIRS4

	# 连通性修正（顺序见文件头注释）
	sealed_islands = _seal_unreachable()
	return true


## 读各阵营的大本营：`faction_bases: {"player": [12, 8], "p1": {"x": 4, "y": 4}}`。
##
## 两种写法都认（数组 / 字典）——手写地图时两种都有人用。
## 宽容点都跟别处一致：越界坐标丢掉（留一个图外的点位，建基地时会去找不存在的格子），
## 缺字段 → 空字典 → `spawn_layout_for` 走老行为。
func _read_faction_bases(v: Variant) -> void:
	faction_bases = {}
	if typeof(v) != TYPE_DICTIONARY:
		return
	var d: Dictionary = v
	for key in d.keys():
		var fid := String(key).strip_edges()
		if fid == "":
			continue
		var p := _read_point(d[key], Vector2i(-1, -1))
		if p.x < 0 or p.y < 0 or p.x >= cols or p.y >= rows:
			push_warning("地图里「%s」的大本营越界，已跳过：%s" % [fid, str(d[key])])
			continue
		faction_bases[fid] = p


## 读区块网格 + 名字表（地图编辑器导出的地图才有）。
##
## 缺字段 / 格式不认识 → 两张都留空 → zone 走「均分」的老路（行为与加这个字段之前一致）。
## 网格原样存起来（不在这里翻译成区块对象：那是 logic/zone.gd 的事，
## 地图只管「地图长什么样」，不管「区块怎么被占领」）。
func _read_zones(grid_v: Variant, list_v: Variant) -> void:
	zones_grid = []
	zones_names = {}
	if typeof(grid_v) != TYPE_ARRAY:
		return
	zones_grid = grid_v
	if typeof(list_v) != TYPE_ARRAY:
		return
	for item in (list_v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var z: Dictionary = item
		var zid := int(z.get("id", -1))
		if zid < 0:
			continue
		var name := String(z.get("name", "")).strip_edges()
		if name != "":
			zones_names[zid] = name


## 读 exists 网格：地图编辑器导出的是 `[[1,1,0,...], ...]`（1 = 存在，0 = 地图外）。
## 三种写法都认，免得手改地图时踩坑：
##   · 二维数组 [[1,0],[1,1]]      ← 编辑器导出的形式
##   · 字符串数组 ["10", "11"]     ← 手写地图更省地方（'1'/'0'、'#'/'.' 都行）
##   · 扁平数组 [1,0,1,1]          ← 按行铺开（编辑器不会这么写，但认了没坏处）
## 缺字段 / 格式不认识 → 什么都不改（保持「处处存在」= 老地图的行为）。
func _read_exists(v: Variant) -> void:
	if typeof(v) != TYPE_ARRAY or (v as Array).is_empty():
		return
	var data: Array = v
	var first: Variant = data[0]
	# 第一项是数组 / 字符串 → 逐行读；否则按「按行铺开的扁平数组」读
	# ⚠️ 不能靠「第一项是数字」来判断是扁平数组：扁平数组的第一项也可能是数组形式
	#    （比如 [[0,1]] 这种一行的写法），所以这里只看**首项的类型**：
	#    是行容器就按行读，不是就按扁平读。
	if typeof(first) == TYPE_ARRAY or typeof(first) == TYPE_STRING:
		_read_exists_rows(data)
		return
	for y in rows:
		for x in cols:
			var idx: int = y * cols + x
			if idx < data.size():
				exists.set_cell(x, y, _truthy_flag(data[idx]))


## 二维（或字符串行）形式：一行一行读；行数 / 列数不够时缺的部分保持「存在」。
func _read_exists_rows(data: Array) -> void:
	for y in mini(rows, data.size()):
		var row_v: Variant = data[y]
		if typeof(row_v) == TYPE_STRING:
			var line := String(row_v)
			for x in mini(cols, line.length()):
				exists.set_cell(x, y, _truthy_flag(line.substr(x, 1)))
		elif typeof(row_v) == TYPE_ARRAY:
			var row_arr: Array = row_v
			for x in mini(cols, row_arr.size()):
				exists.set_cell(x, y, _truthy_flag(row_arr[x]))


## 0 / "0" / false / 空 → 不存在；其余 → 存在
static func _truthy_flag(v: Variant) -> bool:
	if typeof(v) == TYPE_BOOL:
		return v
	if typeof(v) == TYPE_STRING:
		var t := String(v).strip_edges().to_lower()
		return not (t == "" or t == "0" or t == "false" or t == "no")
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v) != 0
	return false


func _read_point(v: Variant, fallback: Vector2i) -> Vector2i:
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 2:
		var a := v as Array
		return Vector2i(int(a[0]), int(a[1]))
	# 字典写法 {"x": 4, "y": 4}：手写地图时有人爱这么写（faction_bases 里尤其常见）
	if typeof(v) == TYPE_DICTIONARY:
		var d: Dictionary = v
		if d.has("x") and d.has("y"):
			return Vector2i(int(d["x"]), int(d["y"]))
	return fallback


func _read_points(v: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) == TYPE_ARRAY and (item as Array).size() >= 2:
			var a := item as Array
			out.append(Vector2i(int(a[0]), int(a[1])))
	return out


## 读地图上预置的建筑。每项要 {type, x, y, owner}：
##   · type 是建筑定义里的 id（wall / tower / base，见 logic/building.gd 的 DEFS）
##   · owner 缺省 = "enemy"（测试敌人的那一方）
##   · 越界 / 缺字段 / 落在山上的项会被**跳过**（world.add_building 自己会拒），
##     但坐标越界的项在这里就先丢，免得留一堆"看起来配了、其实没建出来"的谜团
##     —— tests/test_building_body.gd 会断言每一条都真的建出来了。
func _read_buildings(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var b: Dictionary = item
		var t := String(b.get("type", ""))
		if t == "":
			continue
		var x := int(b.get("x", -1))
		var y := int(b.get("y", -1))
		if x < 0 or y < 0 or x >= cols or y >= rows:
			push_warning("地图预置建筑越界，已跳过：(%d, %d) %s" % [x, y, t])
			continue
		out.append({"type": t, "x": x, "y": y, "owner": String(b.get("owner", "enemy"))})
	return out


## 读地图上预置的单位。每项要 {x, y}，可选 {kind, faction, name, hold}：
##   · kind 缺省 "enemy"（测试敌人）—— 目前只支持它
##   · faction 缺省 "enemy"；name 缺省 "测试敌人"
##   · hold = true → 不执行推进 AI（原地驻守）
## 坐标越界 / 落在山上的项在这里就丢掉（world 那边建不出来），
## tests/test_building_body.gd 会断言每一条都真的建出来了。
func _read_units(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var u: Dictionary = item
		var x := int(u.get("x", -1))
		var y := int(u.get("y", -1))
		if x < 0 or y < 0 or x >= cols or y >= rows:
			push_warning("地图预置单位越界，已跳过：(%d, %d)" % [x, y])
			continue
		if not terrain_walkable(x, y):
			push_warning("地图预置单位落在不可通行的地形上，已跳过：(%d, %d)" % [x, y])
			continue
		out.append({
			"kind": String(u.get("kind", "enemy")),
			"x": x, "y": y,
			"faction": String(u.get("faction", "enemy")),
			"name": String(u.get("name", "测试敌人")),
			"hold": bool(u.get("hold", false)),
		})
	return out


## 从大本营做一次四连通 BFS（只看地形），把走不到的「可通行格」变成山。
## 返回被封闭的格数。返回 0 表示地图本来就是一张连通图。
##
## ★ 不存在的格子（地图外）本来就走不了，也不该被改成山：
##   “不存在”与“山”是两件事，前者由 exists 管，后者由 terrain 管（见文件头）。
func _seal_unreachable() -> int:
	var reachable := flood_fill_terrain(base)
	var sealed := 0
	for y in rows:
		for x in cols:
			if not tile_exists(x, y):
				continue
			if String(terrain.get_cell(x, y)) == TERRAIN_MOUNTAIN:
				continue
			if not reachable.has(terrain.idx(x, y)):
				terrain.set_cell(x, y, TERRAIN_MOUNTAIN)
				sealed += 1
	return sealed


## 只看地形的 BFS（与 Pathfinder.reachable_tiles 的区别：那个会把建筑/阵营算进去）
##
## ★ 方向集与对角守卫**必须与 A* 完全一致**（见 pathfinder.find_path）：
##   连通性修正把「走不到的孤岛」变成山，如果这里用的方向集比 A* 更宽，
##   就会留下「BFS 说能到、A* 到不了」的格子 —— 表现是单位走到一半停下发呆。
func flood_fill_terrain(from: Vector2i) -> Dictionary:
	var seen := {}
	if not terrain.has(from.x, from.y):
		return seen
	seen[terrain.idx(from.x, from.y)] = true
	var queue: Array[Vector2i] = [from]
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in dirs:
			var nx: int = c.x + d.x
			var ny: int = c.y + d.y
			if not terrain.has(nx, ny):
				continue
			var ni := terrain.idx(nx, ny)
			if seen.has(ni):
				continue
			if terrain_walkable(nx, ny) == false:
				continue
			# 对角不许从两个障碍的尖角之间穿过去（与 A* 的同名守卫一致）
			if diagonal and GridRes.is_diagonal(d):
				if not (terrain_walkable(c.x + d.x, c.y) and terrain_walkable(c.x, c.y + d.y)):
					continue
			seen[ni] = true
			queue.append(Vector2i(nx, ny))
	return seen


## 这个格子在不在地图里（编辑器里的虚线格 = 不存在）。
func tile_exists(x: int, y: int) -> bool:
	if not terrain.has(x, y):
		return false
	if exists == null:
		return true          # 理论上不会发生（_load 里一定建了 exists）
	return bool(exists.get_cell(x, y))


## ★ 通行性的唯一入口：地图外的格子与山一样不可通行。
func terrain_walkable(x: int, y: int) -> bool:
	if not terrain.has(x, y):
		return false
	if not tile_exists(x, y):
		return false
	return String(terrain.get_cell(x, y)) != TERRAIN_MOUNTAIN


## 移动消耗倍率：森林更「贵」（A* 的代价用）
func terrain_cost(x: int, y: int) -> float:
	if String(terrain.get_cell(x, y)) == TERRAIN_FOREST:
		return 1.0 / maxf(0.001, forest_mult)
	return 1.0


## 森林减速倍率（来自 config.json 的 unit.forest_mult）
var forest_mult: float = 0.5

## 是否八方向（来自 config.json 的 path.diagonal）。
## 连通性修正与出生点搜索都要跟 A* 用同一套「怎么算走得到」。
var diagonal: bool = true
## 当前生效的方向集（惰性算一次）
var dirs: Array[Vector2i] = GridRes.DIRS8


func is_forest(x: int, y: int) -> bool:
	return String(terrain.get_cell(x, y)) == TERRAIN_FOREST


# ------------------------------------------------------------------
# 出生点布局
# ------------------------------------------------------------------

## 取某点位附近**最近的可行走格**（切比雪夫环从内向外扩）。
## 为什么需要：出生点是写死的，而地形会变；把大本营放到山上会让寻路/建造直接坏掉。
func nearest_walkable(x: int, y: int, max_radius: int = 8) -> Vector2i:
	if _walkable_or_negative(x, y):
		return Vector2i(x, y)
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var px := x + dx
				var py := y + dy
				if _walkable_or_negative(px, py):
					return Vector2i(px, py)
	return Vector2i(-1, -1)


func _walkable_or_negative(x: int, y: int) -> bool:
	return terrain.has(x, y) and terrain_walkable(x, y)


## 某一方的出生点：大本营 + 3 个将领站位 + 防御阵地（城墙 + 箭塔）。
##
## ★ 判定顺序（**这张地图说了算**，不再看 'player' 这种标签）：
##   1. 地图在 `faction_bases` 里给这一方指定过大本营 → 就用它（最高优先级）；
##   2. 没指定 → 主阵营用地图中心的 `base`、其他阵营按序号轮流用 `pvp_points`。
##
## ★ 阵营 id 只有一套（'p1'…'p8' / 'enemy'，见 logic/faction.gd）：
##   单机 / 房主就是 'p1'。**不再有 'player' 这个别名** ——
##   以前单机找 'player'、地图里划的却是 p1/p2，两边对不上，
##   表现就是「地图里明明给 p1 划了大本营，单机却用默认点位」。
##   ⚠️ 因此老地图里写的 "player" 大本营不会被识别（那是 p1 的旧写法）。
func spawn_layout_for(faction: String, primary: String) -> Dictionary:
	# 1) 地图指定过这一方的大本营 → 就用它
	if faction_bases.has(faction):
		var want: Vector2i = faction_bases[faction]
		var wb := nearest_walkable(want.x, want.y)
		return _ring_layout(wb if wb.x >= 0 else want)

	var is_primary := faction == "" or faction == primary
	if is_primary:
		# 主阵营（单机 / 房主）没被地图特别指定时：用地图中心的 base + 原版将领站位
		var b := nearest_walkable(base.x, base.y)
		if b.x < 0:
			b = base
		var spawns: Array[Vector2i] = []
		for s in general_spawns:
			var w := nearest_walkable(s.x, s.y)
			spawns.append(w if w.x >= 0 else b)
		return {"base": b, "spawns": spawns, "defenses": []}

	# 其他玩家：按阵营序号从 pvp_points 稳定取点（不依赖 base，避免双方重合）
	var n := 2
	var digits := faction.replace("p", "")
	if digits.is_valid_int():
		n = maxi(2, int(digits))
	var p := Vector2i.ZERO
	if pvp_points.size() > 0:
		p = pvp_points[(n - 1) % pvp_points.size()]
	var bb := nearest_walkable(p.x, p.y)
	if bb.x < 0:
		bb = base
	return _ring_layout(bb)


## 大本营 + 围着它站一圈的将领站位 + 防御阵地。
##
## 抽出来是因为「地图指定的阵营大本营」与「pvp_points 兜底的那种」用的是同一套摆法 ——
## 两份实现迟早会漂移，而这是**双方开局站位**，漂了就是「一边三个将领挤在一格」。
func _ring_layout(bb: Vector2i) -> Dictionary:
	# 将领围着大本营站（不挤在同一格）
	var ring: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0),
		Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1),
	]
	var ring_spawns: Array[Vector2i] = []
	for i in 3:
		var o: Vector2i = ring[i % ring.size()]
		var w2 := nearest_walkable(bb.x + o.x, bb.y + o.y)
		ring_spawns.append(w2 if w2.x >= 0 else bb)

	# 防御阵地：大本营正上方一段城墙 + 旁边一座箭塔。
	# 让开局有点「阵地感」，也顺带验证「城墙/箭塔按阵营归属」在多玩家下成立。
	var defenses: Array[Dictionary] = []
	var wall_at := Vector2i(bb.x, bb.y - 1)
	if _walkable_or_negative(wall_at.x, wall_at.y):
		defenses.append({"type": "wall", "x": wall_at.x, "y": wall_at.y})
	var tower_at := Vector2i(bb.x + 2, bb.y)
	if _walkable_or_negative(tower_at.x, tower_at.y):
		defenses.append({"type": "tower", "x": tower_at.x, "y": tower_at.y})

	return {"base": bb, "spawns": ring_spawns, "defenses": defenses}
