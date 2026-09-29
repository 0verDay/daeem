## fog.gd —— 战争迷雾（视野计算 + 敌方建筑「见过一次就记住」）
##
## 需求原文（用户）：
##   1. 迷雾用**灰色遮罩**显示；**所有地形默认全图可见** —— 只有两种区域：
##      有视野 / 没视野，**没有「未探索 = 全黑」那一档**
##      （用户确认：「你可以理解为探过一遍全图后的星际争霸战争迷雾」）；
##   2. 没发现敌方建筑就看不见它；**看见过一次之后就一直显示**，
##      再被迷雾盖住也不消失，只有**被摧毁**才消失；
##   3. 每个单位 / 建筑有**视野范围**（数值在 config.json，可被单位编辑器改）；
##   4. 视野会被**山脉**阻断，其他地形不阻断。
##
## ★★ 这个模块**只算「谁能看见哪一格」**，一行显示代码都没有：
##   · 灰色遮罩怎么画 → view/fog_view.gd；
##   · 谁该被画出来 → view/unit_view.gd / building_view.gd / minimap.gd 读这里的
##     `unit_visible()` / `building_visible()` / `tile_visible()`；
##   · 「迷雾里的敌人不可选中 / 不可点名攻击」→ view/input_controller.gd 同样读上面三个查询。
##
## ★★ 迷雾**不影响任何玩法判定**（战斗 / 索敌 / 寻路 / 占领全都不看它）：
##   它是「玩家能看见什么」，不是「世界里发生了什么」。所以：
##   · 不需要按阵营分别推进逻辑（一份权威状态照旧）；
##   · 不进快照（派生数据，联机时各自按同一份权威状态算一遍就行）。
##
## ---- 两种「记住」的区别（这是需求里最容易搞混的一处）----
##   · **地形**：永远画（迷雾只是盖一层灰）；
##   · **敌方建筑**：进过视野就永久记住（`_sighted`），直到它被摧毁；
##   · **敌方单位**：只显示当前视野里的（走出视野就消失，不保留记忆 —— 用户确认）。
##   所以本模块只维护一份「已知敌方建筑」的记忆，单位没有对应的状态。
##
## ---- 性能：为什么是「按贡献格整块并入」而不是「每单位扫一遍圆」----
##   1000 单位 × 半径 8 的圆（约 200 格）逐格做视线判定 = 每帧 20 万次射线，
##   GDScript 下这是几十毫秒的量级（整个逻辑帧的预算）。
##   于是这里做两件事：
##     1. **按格缓存视野扇区**（`_sector_cache`）：地形是静态的、视线只由地形决定，
##        所以「站在这一格能看见哪些格」是可以缓存并复用的 —— 一格算一次，
##        之后每帧只是把缓存里那串 PackedByteArray 并进本阵营的视野掩码（一次 OR 扫描）；
##     2. **没变化就不重算**（`refresh_needed`）：只有「有视野的单位死了 / 挪到了新格 /
##        新建筑出现」才重建。单位一帧只走 0.01~0.015 格，绝大多数帧什么都不用做。
##   ⚠️ 缓存跟着地图实例走：换图（world.map 换了）必须调 `reset_cache()`。
##
## ⚠️ 跨文件引用只用**自己文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##    见 docs/pitfalls.md 第五节）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const FactionRes = preload("res://logic/faction.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const BuildingRes = preload("res://logic/building.gd")

## 视野半径的防呆上限（格）。写一个 500 的视野不该让一帧里算 100 万格 ——
## 100×100 的地图对角线也只有 141，所以这个上限不会挡住任何合理的配置。
const MAX_VISION := 160.0

## DDA 的步数护栏（防止病态数值把一帧卡死；正常一条视线只有几十步）。
const LOS_GUARD := 4096

## ---- 权威状态 ----
## 本帧各阵营的视野掩码："faction" → PackedByteArray（长度 = cols × rows，非 0 = 有视野）。
## ★ 每帧 `update()` 里**整块重建**（填 0 再一次 OR 扫描），不做增量：
##   重建是 O(格数) 的纯内存操作（27×22 只有 594 字节），比维护增量便宜也更不容易错。
var sight: Dictionary = {}
## 各阵营**已知的敌方建筑**："faction" → {Building: true}。
##
## ★★ 键是**建筑对象本身**，不是它的 id —— 这一条踩过一次：
##   `Building` 上**没有** `id` 字段（它的 `def()["id"]` 是**类型**，比如 "tower"），
##   用 `b.id` 当键会直接报 "Invalid access to property or key 'id'"，
##   而且 `def()["id"]` 更不能当身份用（两座箭塔的 id 都是 "tower"，会互相顶掉）。
##   GDScript 的 Dictionary 对 Object 是按**引用**哈希的，对象本身就是一个完美的身份。
##   只增不减，除非那栋楼被摧毁（`_prune_sighted`）。
var _sighted: Dictionary = {}

## 格掩码的列数（`tile_visible()` 要把 (tx, ty) 换成 idx）。
## ★ `update()` 每次按当前地图对齐 —— 缓存是跟着地图走的，换图必须 `reset_cache()`。
var _cols: int = 0

## ---- 本地缓存（可以随时丢，丢了只是重算一遍）----
## 格索引 → 视野扇区 PackedByteArray（站在那一格能看见哪些格）。
var _sector_cache: Dictionary = {}
## 格索引 → 算这条扇区时用的半径（半径变大就要重算）。
var _sector_radius: Dictionary = {}
## ★★ 本帧的「谁从哪几格产生视野」："faction" → {格索引: 半径}。
##
##   为什么按阵营分开存（这里踩过一个真实的大坑）：
##   最初收集成**一张全局表**、再拿它去填**每个阵营**的掩码 —— 于是
##   「p1 的视野」把敌人的视野也算了进去：p1 的单位站在左边、敌人的单位站在右边，
##   p1 的地图上却整条走廊全亮着（症状是「迷雾好像没生效，只是颜色淡了一点」）。
##   视野必须**按阵营各算各的**，所以贡献格从收集那一步就是分开的。
var _contrib: Dictionary = {}
## 上一次更新时的贡献格快照（同样按阵营）：用来判断这一帧要不要重建。
var _last_contrib: Dictionary = {}
## 上一次更新时的阵营数（联机有人进场 / 名单变化都要重建）。
var _last_faction_count: int = 0


static func create() -> RefCounted:
	return new()


## 换地图 / 重开一局时清掉与地图绑定的缓存。
func reset_cache() -> void:
	sight = {}
	_sighted = {}
	_sector_cache = {}
	_sector_radius = {}
	_contrib = {}
	_last_contrib = {}
	_last_faction_count = -1


# ------------------------------------------------------------------
# 每帧入口
# ------------------------------------------------------------------

## 这一帧需不需要重算视野？
##
## ★★ 为什么要有它（性能）：单位一帧只挪 0.01~0.015 格，绝大多数帧里
##    「谁站在哪一格」根本没变 —— 那种帧完全不必重算（视野是格粒度的）。
##    判据只有三条，全是 O(单位数 + 建筑数) 的一次遍历：
##      · 有没有「有视野的单位 / 建筑」挪到了新格（或者死了 / 刚出生 / 刚建好）；
##      · 阵营数变了（联机时有人进场）；
##      · 某一方从「一个视野来源都没有」变成有了。
##    `_collect_contributors()` 是 O(单位数 + 建筑数) 的一次遍历 —— 与 `update()` 里那次
##    同量级，所以「先问一次再算」总共两次遍历，可以忽略。
func refresh_needed(world) -> bool:
	if world == null or world.cfg == null or not world.cfg.fog_enabled:
		return false
	if world.map == null:
		return false
	_collect_contributors(world)
	if _last_faction_count < 0 or world.factions.size() != _last_faction_count:
		return true
	if _contrib.size() != _last_contrib.size():
		return true
	for fid in _contrib.keys():
		var cur: Variant = _last_contrib.get(fid, null)
		if typeof(cur) != TYPE_DICTIONARY:
			return true
		var table: Dictionary = _contrib[fid]
		if table.size() != (cur as Dictionary).size():
			return true
		for idx in table.keys():
			if not (cur as Dictionary).has(idx):
				return true
	return false


## 重建所有阵营的视野（每一方**只**并入自己那些来源的扇区，见 `_contrib` 的说明）。
##
## ★★ 每次进来都**重新收集**贡献格（不是「上一步 refresh_needed 收集过了就复用」）：
##    这一条踩过坑 —— 曾经的写法是「阵营数没变就沿用 `_contrib`」，而 `_contrib`
##    装的是**上一帧**的格子：单位走到新位置后调 `update()`，掩码却还是按旧格子填的
##    （症状 = 「走进视野了，敌人建筑还是不显示」，而且只在**没先问 refresh_needed**
##    的调用路径上出现 —— 游戏主循环先问了，所以手玩看不出来，测试一眼就红）。
##    收集是 O(单位数 + 建筑数) 的一次遍历（每帧本来也要空转这么多），不值得为省它引入
##    一条「必须按某种顺序调用」的隐式契约。
func update(world) -> void:
	if world == null or world.cfg == null or world.map == null:
		return
	_collect_contributors(world)
	var cells: int = world.map.cols * world.map.rows
	_cols = world.map.cols

	for f in world.factions:
		var fid := String(f)
		# 1) 整块填 0（PackedByteArray.fill 是引擎侧的一次 memset）
		var mask := PackedByteArray()
		mask.resize(cells)
		mask.fill(0)
		# 2) 把**这一方**每一个贡献格的视野扇区并进来。
		#    ★ OR（`|`）而不是加法：这里要的是布尔量「这一格我看不看得见」，
		#      两支部队都看得见同一格时结果仍然是有视野。
		var mine: Variant = _contrib.get(fid, null)
		if typeof(mine) == TYPE_DICTIONARY:
			for idx in (mine as Dictionary).keys():
				var sector := _ensure_sector(world, int(idx), (mine as Dictionary)[idx])
				var n: int = mini(sector.size(), mask.size())
				for i in n:
					if sector[i] != 0:
						mask[i] = 1
		sight[fid] = mask

	_prune_sighted(world)
	_last_contrib = _contrib.duplicate(true)
	_last_faction_count = world.factions.size()


## 收集「每一方从哪几格产生视野」：单位 + 建筑各占一格。
##
## ★★ `_contrib` 是**按阵营分开**的："faction" → {格索引: 半径}。
##    这里踩过一个真实的坑：最初收集成**一张全局表**、再拿它去填**每个阵营**的掩码，
##    于是「p1 的视野」把敌人的视野也算了进去 —— p1 的单位在左边、敌人在右边，
##    p1 的地图上却整条走廊全亮，看着像「迷雾只是颜色淡了一点」。
##    视野必须**按阵营各算各的**，所以贡献格从收集这一步就是分开的。
##
## ★ 同一方、同一格的多个单位只算一次（用它们里面**最大的**那个视野）：
##   这是纯优化，但也是正确的 —— 视野是「站在这一格能看见什么」，
##   与站在这一格的是几个人无关。
##
## ★★ `_contrib` 是**复用的成员字典**（每帧 clear 而不新建）：
##    1000 单位下每帧新建一个字典就是白花花的垃圾回收。
func _collect_contributors(world) -> void:
	_contrib.clear()
	for f in world.factions:
		_contrib[String(f)] = {}
	# 1) 单位（含将领与附属兵；阵亡的不给视野）。
	#    ⚠️ 阵营**不在名单里**的单位（单机时的 "enemy" 守军）也要收集：
	#      它们挪一格也是「视野变了」，漏掉会让 refresh_needed 误判成 false。
	for u in world.units:
		if u == null or not u.alive:
			continue
		var ux := int(u.tx)
		var uy := int(u.ty)
		if not world.map.terrain.has(ux, uy):
			continue
		_dict_max(_bucket(String(u.faction)), world.map.terrain.idx(ux, uy),
			_unit_vision(world.cfg, u))
	# 2) 建筑（自己的建筑也是眼睛 —— 用户确认「自己的建筑也给视野」）
	#    ★ 区划中心（中立障碍）不算：它不属于任何阵营，见 `_faction_contributes`。
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if not world.map.terrain.has(b.tx, b.ty):
			continue
		if not _faction_contributes(String(b.owner)):
			continue
		_dict_max(_bucket(String(b.owner)), world.map.terrain.idx(b.tx, b.ty),
			_building_vision(world.cfg, b))


## 取（必要时新建）某一方的那张贡献格表。
func _bucket(faction: String) -> Dictionary:
	var t: Variant = _contrib.get(faction, null)
	if typeof(t) == TYPE_DICTIONARY:
		return t
	var fresh := {}
	_contrib[faction] = fresh
	return fresh


## 一个单位的视野半径。
##
## ★★ 这里**直接读单位自己身上那个数**，不再每次去查 config：
##   · `Unit.create()` 已经把 `cfg.unit_vision_of(unit_type)`（含将领的覆盖）抄进了
##     `u.vision`，与 hp_max / unit_class 同一个口径 —— 迷雾每帧都要读它，
##     不该变成「每帧每单位一次 JSON 下潜」；
##   · 老单位 / 测试里手工 new 出来的单位可能没有这个字段 → 退回查表，
##     再退回 `fog.vision_default`（漏配一个类型不该让它变成瞎子）。
func _unit_vision(cfg: ConfigRes, u) -> float:
	var v: Variant = u.vision
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return maxf(0.0, float(v))
	return cfg.unit_vision_of(String(u.unit_type))


## 一栋建筑的视野半径（与 `_unit_vision` **完全对称**的一处）。
##
## ★ `Building.create()` 已经把 `cfg.building_vision_of(type)` 抄进 `b.vision`
##   （每个建筑类型自己一个值，没写就退回 `fog.vision_building`）。
## ⚠️ 手工 new 出来的建筑（测试里可能这么干）没有那个字段 → 退回按类型查表。
func _building_vision(cfg: ConfigRes, b) -> float:
	var v: Variant = b.vision
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return maxf(0.0, float(v))
	return cfg.building_vision_of(String(b.type))


## 这个 owner 会不会产生视野（空 = 中立障碍 / 无主，不算任何人的眼睛）。
##
## ★ 为什么不做成「只算玩家阵营」：迷雾按阵营算（联机时每一方各算各的），
##   而 enemy / p2 这些不是玩家阵营的**也要有视野** —— 将来服务端要用它做
##   视野裁剪（谁该收到哪一条单位状态）。所以判据是「有没有归属」，不是「是不是玩家」。
func _faction_contributes(owner: String) -> bool:
	return owner != ""


static func _dict_max(d: Dictionary, key: int, value: float) -> void:
	var cur: Variant = d.get(key, null)
	if cur == null or value > float(cur):
		d[key] = value


# ------------------------------------------------------------------
# 视野扇区（按格缓存）
# ------------------------------------------------------------------

## 取「站在 idx 这一格、半径为 radius」时能看见哪些格。
##
## ★ 缓存键只有格索引，而半径可能不同（长弓兵 10 / 长枪兵 8 站在同一格）——
##   所以记下算这一份时用的半径：新半径**更大**才重算（更小的直接复用超集，
##   反正并进掩码时是 OR，多余的那几格由更远处那道栅栏解释得通吗？
##   ⚠️ 不行，会多看见 —— 所以只在**更大**时重算，更小时直接复用。
##   同一格里同时站着视野 8 与 10 的单位时，按 10 算 —— 那是真的有人看得见，
##   而「谁看得见」是布尔量，本来就不区分是谁看见的。）
func _ensure_sector(world, idx: int, radius: float) -> PackedByteArray:
	var r: float = clampf(radius, 0.0, MAX_VISION)
	var cached: Variant = _sector_cache.get(idx, null)
	if cached != null and float(_sector_radius.get(idx, -1.0)) >= r - 1e-6:
		return cached
	var sector := compute_sector(world.map, idx, r)
	_sector_cache[idx] = sector
	_sector_radius[idx] = r
	return sector


## 算一格视野。
##
## @param map  必须提供 cols / rows / terrain（GridRes）与 `is_mountain()`。
## @param idx  格索引（`terrain.idx(tx, ty)`）。
## @param radius 视野半径（格）。
## @return PackedByteArray：长度 = cols × rows，非 0 = 站在这一格看得见那一格。
##
## ★ 起点格自己也标为可见（单位站在山上时也要能看见自己站的地方）。
## ★ 只遍历半径以内的格（半径之外一律 0）—— 视野是有限半径，不是全图。
static func compute_sector(map, idx: int, radius: float) -> PackedByteArray:
	var cols: int = map.cols
	var rows: int = map.rows
	var out := PackedByteArray()
	out.resize(cols * rows)
	out.fill(0)
	if idx < 0 or idx >= cols * rows:
		return out
	var ox: int = idx % cols
	var oy: int = idx / cols
	var r: float = clampf(radius, 0.0, MAX_VISION)
	var ri: int = int(ceilf(r))
	out[idx] = 1
	for dy in range(-ri, ri + 1):
		var ty: int = oy + dy
		if ty < 0 or ty >= rows:
			continue
		for dx in range(-ri, ri + 1):
			var tx: int = ox + dx
			if tx < 0 or tx >= cols:
				continue
			var ti: int = ty * cols + tx
			if out[ti] != 0:
				continue                    # 起点自己
			# 距离按**格心到格心**算：与「视野半径 8 = 看到 8 格远」的直觉一致
			var ddx: float = float(dx)
			var ddy: float = float(dy)
			if ddx * ddx + ddy * ddy > r * r + 1e-6:
				continue
			# ★★ 视线：从格心到格心画一条直线，中间**穿过的格子**里有山 → 看不见。
			#    判据走 DDA（枚举线段真正擦到的每一格），与 pathfinder.segment_clear
			#    同一套几何 —— 半格偏移、正好穿过格点这些情况在两个地方的解释一致。
			if _los_blocked(map, ox, oy, tx, ty):
				continue
			out[ti] = 1
	return out


## 从 (ox,oy) 到 (tx,ty) 的**直线中间**有没有山？
##
## ★ 只检查**中间的格子**（不含起点、不含终点）：山脉**自己那格**是看得见的
##   （否则玩家永远看不到地图上那片山 —— 它会被自己挡住），
##   而山**后面**的格子在同一个循环里就过不去了。
##
## ★ 正好穿过格点（t_max_x == t_max_y）时两侧都算「擦到」：
##   与 A* 的「不许从两个障碍的尖角之间斜穿」是同一条几何直觉。
static func _los_blocked(map, ox: int, oy: int, tx: int, ty: int) -> bool:
	if ox == tx and oy == ty:
		return false
	# 从格心出发到格心
	var x0: float = float(ox) + 0.5
	var y0: float = float(oy) + 0.5
	var dx: float = float(tx) + 0.5 - x0
	var dy: float = float(ty) + 0.5 - y0
	if absf(dx) < 1e-9 and absf(dy) < 1e-9:
		return false
	var cx: int = ox
	var cy: int = oy
	var step_x: int = 1 if dx > 0.0 else -1
	var step_y: int = 1 if dy > 0.0 else -1
	var t_delta_x: float = absf(1.0 / dx) if absf(dx) > 1e-12 else INF
	var t_delta_y: float = absf(1.0 / dy) if absf(dy) > 1e-12 else INF
	var t_max_x: float = ((float(cx + 1) - x0) * t_delta_x) if dx > 0.0 else ((x0 - float(cx)) * t_delta_x)
	var t_max_y: float = ((float(cy + 1) - y0) * t_delta_y) if dy > 0.0 else ((y0 - float(cy)) * t_delta_y)
	if absf(dx) <= 1e-12:
		t_max_x = INF
	if absf(dy) <= 1e-12:
		t_max_y = INF

	var guard := 0
	while guard < LOS_GUARD:
		guard += 1
		if t_max_x > 1.0 and t_max_y > 1.0:
			return false                    # 已经走到终点，中间没有山
		if t_max_x < t_max_y:
			cx += step_x
			t_max_x += t_delta_x
			if cx == tx and cy == ty:
				return false
			if map.is_mountain(cx, cy):
				return true
		elif t_max_y < t_max_x:
			cy += step_y
			t_max_y += t_delta_y
			if cx == tx and cy == ty:
				return false
			if map.is_mountain(cx, cy):
				return true
		else:
			# 正好穿过格点：两侧都擦到了，任意一侧是山就算被挡
			if map.is_mountain(cx + step_x, cy) or map.is_mountain(cx, cy + step_y):
				return true
			cx += step_x
			cy += step_y
			t_max_x += t_delta_x
			t_max_y += t_delta_y
			if cx == tx and cy == ty:
				return false
			if map.is_mountain(cx, cy):
				return true
	return false


# ------------------------------------------------------------------
# 查询（view/ 与测试读的就是这几个）
# ------------------------------------------------------------------

## 这一格对某阵营有视野吗？（越界 / 未知阵营 / 还没算过 → false）
func tile_visible(faction: String, tx: int, ty: int) -> bool:
	var mask: Variant = sight.get(faction, null)
	if mask == null:
		return false
	var m: PackedByteArray = mask
	if tx < 0 or ty < 0 or tx >= _cols:
		return false
	var idx: int = ty * _cols + tx
	if idx >= m.size():
		return false                    # 行越界 / 掩码还没按当前地图建好
	return m[idx] != 0


## 某个单位对这个阵营该不该画出来？
##   · 同一阵营 → 永远可见（己方部队不会被自己的迷雾盖住）；
##   · 其他阵营 → 只有**当前视野内**才可见（走出视野就消失，需求确认「不保留记忆」）。
func unit_visible(faction: String, u) -> bool:
	if u == null or not u.alive:
		return false
	if FactionRes.same_side(String(u.faction), faction):
		return true
	return tile_visible(faction, int(u.tx), int(u.ty))


## 某栋建筑对这个阵营该不该画出来？
##   · 无主（owner == ""，例如区划中心）→ 所有人都看得见（它不是谁的秘密）；
##   · 同一阵营 → 永远可见；
##   · 其他阵营 → **当前视野内**，或者**曾经看见过一次**（永久记忆，直到被摧毁）。
func building_visible(faction: String, b) -> bool:
	if b == null or not b.alive:
		return false
	var owner := String(b.owner)
	if owner == "" or FactionRes.same_side(owner, faction):
		return true
	if tile_visible(faction, int(b.tx), int(b.ty)):
		return true
	return is_building_sighted(faction, b)


## 这一栋敌方建筑**被这个阵营发现过**吗（`update()` 里顺手登记）。
func is_building_sighted(faction: String, b) -> bool:
	if b == null:
		return false
	var table: Variant = _sighted.get(faction, null)
	if typeof(table) != TYPE_DICTIONARY:
		return false
	return (table as Dictionary).has(b)


## 这个阵营**已知的敌方建筑**（数组；顺序 = 发现顺序，只增不减）。
## 给测试与排查工具用：视图侧真正读的是 `building_visible()`。
func known_buildings(faction: String) -> Array:
	var out: Array = []
	var table: Variant = _sighted.get(faction, null)
	if typeof(table) != TYPE_DICTIONARY:
		return out
	for b in (table as Dictionary).keys():
		out.append(b)
	return out


# ------------------------------------------------------------------
# 「见过一次就记住」的登记与清理
# ------------------------------------------------------------------

## 把**这一帧有视野的敌方建筑**记进各阵营的记忆表；顺手把已经没了的清掉。
##
## ★★ 这一段就是需求第 2 条的全部实现：
##   · 登记：有视野 → 写进 `_sighted`（之后 `building_visible()` 一票通过）；
##   · 清理：**只**因为「它不存在了（被摧毁）」—— 迷雾重新盖住**不**算理由，
##     所以这里没有任何「看不见就删」的分支（删了就成了星际2里的普通建筑消失效果）。
func _prune_sighted(world) -> void:
	for f in world.factions:
		var fid := String(f)
		var table: Dictionary = _sighted.get(fid, {})
		# 1) 先忘掉「不再值得记住」的：被摧毁、或者**换主之后已经不算敌方的**。
		#
		# ⚠️ 这里踩过一次：第一版只判「它还在世界的建筑表里吗」，于是**换主**的建筑
		#    会永远留在记忆表里（它明明已经变成自己的了，却还挂在「已知敌方建筑」里，
		#    并且在 `known_buildings()` / 将来的小地图提示里一直出现）。
		#    判据必须是「它现在是不是**这一方的敌方**建筑」，不是「它还在不在」。
		for b in table.keys():
			if b == null or not b.alive:
				table.erase(b)
				continue
			var own := String(b.owner)
			if own == "" or FactionRes.same_side(own, fid):
				table.erase(b)              # 变成自己的 / 变成无主的 → 不再需要记忆
		# 2) 这一帧看得见的敌方建筑 → 记下来
		for b in world.building_list:
			if b == null or not b.alive:
				continue
			var owner := String(b.owner)
			if owner == "" or FactionRes.same_side(owner, fid):
				continue                    # 自己的 / 无主的：不需要记忆（本来就一直看得见）
			if tile_visible(fid, int(b.tx), int(b.ty)):
				table[b] = true
		_sighted[fid] = table


## 拆除 / 换主时立即从记忆里剔掉一栋楼（视图与测试可以主动调；不调也会被
## `_prune_sighted` 在下一帧清掉 —— 这里只是让「被摧毁」那一刻不残留一帧）。
func forget_building(b) -> void:
	if b == null:
		return
	for fid in _sighted.keys():
		(_sighted[fid] as Dictionary).erase(b)
