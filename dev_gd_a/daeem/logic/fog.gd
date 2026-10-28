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

## ★★ C# 视野内核（logic/FogKernel.cs）。加载不到（普通版 Godot）时为 null，
##    自动退回本文件的 GDScript 实现 —— 与 crowd_bridge 的回退是同一条约定。
const KERNEL_PATH := "res://logic/FogKernel.cs"
var kernel = null
## 内核当前按哪张地图建的表（map 对象 identity）；换了就重建
var _kernel_map_ref = null


func _init() -> void:
	var s = load(KERNEL_PATH)
	if s != null:
		kernel = s.new()


## 走 C# 还是 GDScript（config 的 `fog.backend`；内核不可用时一律回退）
func _use_csharp(cfg: ConfigRes) -> bool:
	return kernel != null and cfg != null and String(cfg.fog_backend) == "csharp"

## ---- 权威状态 ----
## ★★ 本帧各**方**的视野掩码："同方代表 id"（`FactionRes.side_of`）→ PackedByteArray
## （长度 = cols × rows，非 0 = 有视野）。
##
## ★ 为什么键是「同方」而不是「阵营」：合作模式要求两名玩家**共享视野**
##   （用户已拍板），而「同一方」这件事在 `FactionRes` 里已经有一套判据。
##   单机时 `side_of(f) == f` ⇒ 键与从前一模一样，**逐位一致**。
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
var _rows: int = 0

## ★★ 只影响**显示**的全图视野（键 = `FactionRes.side_of`）：给观战验收用。
##    AI 的逻辑查询走 `logic_tile_visible()` / `logic_unit_visible()` / `logic_building_visible()`，
##    显示走 `tile_visible()` / `unit_visible()` / `building_visible()`（后者会尊重观战全图标记）。
var _display_reveal: Dictionary = {}

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

## ★★ 2026.10.27：C# 后端专用的**扁平贡献表**（取代 `_contrib` 那套字典，见 `_collect_flat`）。
var _flat_side := PackedInt32Array()
var _flat_tile := PackedInt32Array()
var _flat_radius := PackedFloat64Array()
var _flat_count: int = 0
## 方下标 → 方名（就是 `sight` 的键）。顺序 = 遍历 `world.factions` 去重后的顺序，与旧实现同序。
var _flat_side_ids: Array = []
var _last_flat_side := PackedInt32Array()
var _last_flat_tile := PackedInt32Array()
var _last_flat_radius := PackedFloat64Array()
var _last_flat_count: int = -1
var _last_flat_ids: int = -1
## 「本帧已经用扁平路径采集过」——与 `_fresh` 同一个用途，只是另一条后端。
var _fresh_flat: bool = false
## ★★ 2026.10.28：**版本号闸门**的状态（见 `refresh_needed`）。
##   `map.vision_revision` 在「有人真的换格 / 单位进出场 / 建筑增删 / 归属变动」时 +1，
##   没变就说明贡献格一模一样 —— 连采集都可以不做（0.45ms → 一次整数比较）。
##   ⚠️ 记的是「上一次采集时」的 map 与版本号：换图必须重新比（`reset_cache` 清掉）。
var _seen_map = null
var _seen_rev: int = -1
## ★ 诊断计数器（只有 bench 读）：闸门挡掉了几次采集 / 真正采集了几次。
##   `hits / (hits + collects)` 就是闸门的命中率 —— 判断「这个优化在这一局值不值」的唯一依据。
var stat_gate_hits: int = 0
var stat_collects: int = 0


static func create() -> RefCounted:
	return new()


## 换地图 / 重开一局时清掉与地图绑定的缓存。
func reset_cache() -> void:
	sight = {}
	_sighted = {}
	_display_reveal = {}
	_sector_cache = {}
	_sector_radius = {}
	_contrib = {}
	_last_contrib = {}
	_last_faction_count = -1
	_fresh = false
	# ★ 扁平表的「上一版」也必须作废：换图后旧数组与新的世界不可比。
	_last_flat_count = -1
	_last_flat_ids = -1
	_fresh_flat = false
	_seen_map = null
	_seen_rev = -1
	# ★ 内核的扇区缓存按**地形**存：换图 / 地形变了必须一起清（见 `_ensure_kernel_map`）
	_kernel_map_ref = null
	if kernel != null:
		kernel.ResetCache()


# ------------------------------------------------------------------
# 每帧入口
# ------------------------------------------------------------------

## ★★ 「本帧刚采集过」的一次性标记：`refresh_needed` 采集贡献格之后置位，
##    紧随其后的 `update` 直接复用它那一次采集 —— 免得**同一帧把贡献格采集两遍**
##    （`_collect_contributors` 是 O(单位数 + 建筑数)，1000 单位下这是实打实的一半）。
##    ⚠️ 只在「refresh_needed → update」这条相邻调用上成立：`update` 被**单独调用**时
##    （测试里到处是）标记为假 ⇒ 照旧自己采集，语义与从前**逐位一致**。
##    ⚠️ `reset_cache()` 会把标记清掉（换地图 / 重开一局必须重新采集）。
var _fresh: bool = false

## 这一帧需不需要重算视野？
##
## ★★ 为什么要有它（性能）：单位一帧只挪 0.01~0.015 格，绝大多数帧里
##    「谁站在哪一格」根本没变 —— 那种帧完全不必重算（视野是格粒度的）。
##    判据只有三条，全是 O(单位数 + 建筑数) 的一次遍历：
##      · 有没有「有视野的单位 / 建筑」挪到了新格（或者死了 / 刚出生 / 刚建好）；
##      · 阵营数变了（联机时有人进场）；
##      · 某一方从「一个视野来源都没有」变成有了。
##    `_collect_contributors()` 是 O(单位数 + 建筑数) 的一次遍历 —— `update()` 紧随其后时
##    直接复用它（靠 `_fresh`），于是这一帧总共只采集一次。
func refresh_needed(world) -> bool:
	if world == null or world.cfg == null or not world.cfg.fog_enabled:
		return false
	if world.map == null:
		return false
	# ★★ 2026.10.27：C# 后端走**扁平表**（不建字典，见 `_collect_flat`）。
	if _use_csharp(world.cfg):
		# ★★ 2026.10.28：版本号闸门（见 `_seen_map` 的注释）。
		#   版本号取不到（FakeWorld / 旧 map）时 `_map_rev` 返回 -1 ⇒ 不启用闸门，
		#   退回全量比较 —— 宁可多算一次，不能把迷雾冻住。
		var rev: int = _map_rev(world)
		# ★ 闸门只对「自己维护版本号」的世界生效（真的 WorldRes 有 mark_vision_dirty）。
		#   测试里的 FakeWorld 直接改 `u.tx` / append 建筑，绕过了所有出口 ——
		#   对它必须退回全量比较，否则「检测得到变化」这条约定会在桩对象上失效。
		var gate_ok: bool = bool(world.cfg.fog_revision_gate) and world.has_method("mark_vision_dirty")
		if gate_ok and rev >= 0 and _last_flat_count >= 0 \
				and world.map == _seen_map and rev == _seen_rev:
			if world.cfg.fog_verify_revision:
				# ★ 调试开关：闸门说「没变」时再全量跑一遍。不一致 ⇒ 以全量为准并告警。
				if _refresh_needed_flat(world):
					push_warning("[daeem] fog 版本号闸门漏判：vision_revision 未变，但全量比较发现变化（已按全量重建）")
					return true
			stat_gate_hits += 1
			return false
		return _refresh_needed_flat(world)
	_collect_contributors(world)
	# ★ 标记「本帧已采集」：紧随的 update() 会复用它，不再重复采集（见 `_fresh`）。
	_fresh = true
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


## ★★ 2026.10.27：C# 后端的**扁平贡献表**采集（取代 `_contrib` 那套字典）。
##
## 为什么可以完全不要字典：内核 `BuildSight` 对同一格的贡献是**逐条 OR**，
## 而半径 r1 < r2 时「r1 的扇区」⊆「r2 的扇区」—— 由 OR 的单调性，
## 「不去重、全部 OR」与「同格取最大半径再 OR」结果**逐位相同**。
## ⇒ 每帧 256 次 `dict.get` + `append` + 赋值，变成三次数组写入；
##   变更判定也从「遍历字典比对」变成**原生数组比较**（`==` 走 memcmp）。
##
## ⚠️ 等价前提是「半径越大看得越多」。以后若给扇区加真实遮挡（山后的格子看不见），
##    这条必须重新论证，否则会悄悄改变视野语义。
func _collect_flat(world) -> void:
	_flat_count = 0
	_flat_side_ids.clear()
	var side_of: Dictionary = {}          # 方名 → 方下标
	var side_cache: Dictionary = {}       # 阵营 id → 方名（同一帧内只算一次 side_of）
	# ★ 2026.10.28：阵营 id → 方下标**一张表**。原来每个单位都要走
	#   `_register_side` → `_side_name`（side_cache.get）→ `side_of.get` 两次字典查找。
	var fac_idx: Dictionary = {}
	for f in world.factions:
		var fid0 := String(f)
		fac_idx[fid0] = _register_side(fid0, side_of, side_cache)
	# ★ 地形格换算内联：`terrain.has()` + `terrain.idx()` 每单位两次跨对象方法调用，
	#   而两者都只是「边界判断 + y*cols+x」（见 logic/grid.gd）。
	var terrain = world.map.terrain
	var cols: int = int(terrain.cols)
	var rows: int = int(terrain.rows)
	# 上限 = 单位数 + 建筑数；一次 resize 到底，避免循环里反复扩容。
	var cap: int = world.units.size() + world.building_list.size()
	_flat_side.resize(cap)
	_flat_tile.resize(cap)
	_flat_radius.resize(cap)
	var k := 0
	for u in world.units:
		if u == null or not u.alive:
			continue
		var ux := int(u.tx)
		var uy := int(u.ty)
		if ux < 0 or uy < 0 or ux >= cols or uy >= rows:
			continue
		# ⚠️ 名单之外的阵营（单机时的 "enemy" 守军）也要登记：
		#    它们挪一格同样是「视野变了」，漏掉会让变更判定漏更新。
		var fid := String(u.faction)
		var si: Variant = fac_idx.get(fid, null)
		if si == null:
			si = _register_side(fid, side_of, side_cache)
			fac_idx[fid] = si
		_flat_side[k] = int(si)
		_flat_tile[k] = uy * cols + ux
		_flat_radius[k] = _unit_vision(world.cfg, u)
		k += 1
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		var bx := int(b.tx)
		var by := int(b.ty)
		if bx < 0 or by < 0 or bx >= cols or by >= rows:
			continue
		var bfid := String(b.owner)
		if not _faction_contributes(bfid):
			continue
		var si2: Variant = fac_idx.get(bfid, null)
		if si2 == null:
			si2 = _register_side(bfid, side_of, side_cache)
			fac_idx[bfid] = si2
		_flat_side[k] = int(si2)
		_flat_tile[k] = by * cols + bx
		_flat_radius[k] = _building_vision(world.cfg, b)
		k += 1
	_flat_count = k
	_flat_side.resize(k)
	_flat_tile.resize(k)
	_flat_radius.resize(k)


## 把一个阵营登记进「方表」（同方共用一个下标）并返回它的下标。
func _register_side(faction: String, side_of: Dictionary, side_cache: Dictionary) -> int:
	var sid := _side_name(faction, side_cache)
	var idx: Variant = side_of.get(sid, null)
	if idx != null:
		return int(idx)
	var fresh: int = _flat_side_ids.size()
	side_of[sid] = fresh
	_flat_side_ids.append(sid)
	return fresh


func _side_name(faction: String, side_cache: Dictionary) -> String:
	var s: Variant = side_cache.get(faction, null)
	if s == null:
		s = FactionRes.side_of(faction)
		side_cache[faction] = s
	return String(s)


## 视野版本号（见 `map_data.vision_revision`）。
## 取不到（FakeWorld / 没有这个字段的旧 map）返回 -1 ⇒ 调用方关闭闸门、退回全量比较。
func _map_rev(world) -> int:
	var m = world.map
	if m == null:
		return -1
	var v: Variant = m.get("vision_revision")
	return int(v) if v != null else -1


## 扁平表的变更判定：**原生数组比较**（相等即 memcmp），比遍历字典快一个量级。
##
## ⚠️ 这条判据比旧版更**严**：旧版只比「格集合」，这里连半径与顺序一起比。
##   严的后果只是「多重建一次掩码」，不会漏更新 —— 反过来才是 bug。
func _refresh_needed_flat(world) -> bool:
	# ★ 版本号在**采集之前**记：采集期间若有改动，下一帧会看到版本号变了（宁可多算一次）。
	stat_collects += 1
	_seen_map = world.map
	_seen_rev = _map_rev(world)
	_collect_flat(world)
	_fresh_flat = true
	_fresh = false
	if _last_flat_count < 0 or _last_flat_ids < 0:
		return true
	if _flat_count != _last_flat_count or _flat_side_ids.size() != _last_flat_ids:
		return true
	if _flat_tile != _last_flat_tile:
		return true
	if _flat_radius != _last_flat_radius:
		return true
	if _flat_side != _last_flat_side:
		return true
	return false


## 用扁平表建掩码：**一次内核调用**算完所有方，再按方切片。
func _build_sight_flat(world, cells: int) -> void:
	_ensure_kernel_map(world)
	if _flat_side_ids.is_empty() or _flat_count <= 0:
		sight.clear()
		_snapshot_flat()
		return
	var flat: PackedByteArray = kernel.BuildSight(_flat_side_ids.size(),
		_flat_side, _flat_tile, _flat_radius, _flat_count)
	for si in _flat_side_ids.size():
		sight[String(_flat_side_ids[si])] = flat.slice(si * cells, (si + 1) * cells)
	_snapshot_flat()


## 记下「这一版贡献表」，给下一帧的变更判定当基线（原生数组复制，引擎侧 memcpy）。
func _snapshot_flat() -> void:
	_last_flat_side = _flat_side.duplicate()
	_last_flat_tile = _flat_tile.duplicate()
	_last_flat_radius = _flat_radius.duplicate()
	_last_flat_count = _flat_count
	_last_flat_ids = _flat_side_ids.size()


## 重建所有阵营的视野（每一方**只**并入自己那些来源的扇区，见 `_contrib` 的说明）。##
## ★★ 贡献格的采集：**只有 `refresh_needed` 刚刚采过（同一帧的相邻调用）才复用它**，
##    其余任何情况都**重新收集**（见 `_fresh` 与下面那句）。
##    这一条踩过坑 —— 曾经的写法是「阵营数没变就沿用 `_contrib`」，而 `_contrib`
##    装的是**上一帧**的格子：单位走到新位置后调 `update()`，掩码却还是按旧格子填的
##    （症状 = 「走进视野了，敌人建筑还是不显示」，而且只在**没先问 refresh_needed**
##    的调用路径上出现 —— 游戏主循环先问了，所以手玩看不出来，测试一眼就红）。
##    ★ 所以复用**只允许**发生在「紧邻的一次 refresh_needed 之后」：那一次的 `_contrib`
##      装的就是**当前**世界（不是上一帧），语义与「重新收集」等价。
func update(world) -> void:
	if world == null or world.cfg == null or world.map == null:
		return
	# ★★ 若 `refresh_needed` **刚刚**采集过（同一帧的相邻调用），就用它那一次 ——
	#    否则自己采集。见 `_fresh` 的说明：单独调用 `update` 的路径语义不变。
	var use_cs: bool = _use_csharp(world.cfg)
	if use_cs:
		# ★ 扁平路径（2026.10.27）：与 `_fresh` 同一条约定，只是另一套数据。
		if not _fresh_flat:
			_collect_flat(world)
		_fresh_flat = false
		_fresh = false
	else:
		if _fresh:
			_fresh = false
		else:
			_collect_contributors(world)
		_fresh_flat = false
	var cells: int = world.map.cols * world.map.rows
	_cols = world.map.cols
	_rows = world.map.rows

	# ★★ 2026.10.28（诊断）：把 update 拆成「建掩码 / 记忆清理」两段。
	#   256 单位时 `fog` 整段约 0.55 ms，只看总数分不清是内核建掩码贵、
	#   还是每帧清理「见过的建筑」贵。
	# ⚠️ 用 `world.get("profile_on")` 而不是 `world.profile_on`：`tests/test_fog.gd`
	#   用的是 **FakeWorld 桩对象**（没有这两个字段），直接读属性会抛错并中断 update
	#   （实测：38 条断言全红，表现是「迷雾一片空白」）。`Object.get()` 不存在时返回 null。
	var prof_on: bool = world.get("profile_on") == true
	var _t0: int = Time.get_ticks_usec() if prof_on else 0

	# ★★ 数字循环走 C# 内核（`fog.backend = "csharp"`）；加载不到 / 显式配成 gdscript
	#    时走下面那条老路。两条路的输出**逐位一致**（test_fog 全量断言盯着）。
	if use_cs:
		_build_sight_flat(world, cells)
	else:
		_build_sight_gdscript(world, cells)
	var _t1: int = Time.get_ticks_usec() if prof_on else 0

	_prune_sighted(world)
	if _t0 != 0 and world.has_method("profile_sub"):
		world.profile_sub("fog/build", _t1 - _t0)
		world.profile_sub("fog/prune", Time.get_ticks_usec() - _t1)
	# ★★ 2026.10.27（性能）：用**交换**代替 `_contrib.duplicate(true)` ——
	#    原来每帧把「方 × 贡献格」整张嵌套字典深拷贝一遍，只为留一份给 `refresh_needed` 比对。
	var prev: Dictionary = _last_contrib
	_last_contrib = _contrib
	_contrib = prev
	_last_faction_count = world.factions.size()


## GDScript 版的掩码构建（与迁移前逐行相同）—— 内核不可用 / 配成 gdscript 时走这里。
func _build_sight_gdscript(world, cells: int) -> void:
	for f in world.factions:
		var fid := String(f)
		# ★★ 掩码按**同一方**存（键 = `side_of`）—— 合作的两个玩家落进同一份，
		#    于是「p1 看到的格，p2 也看得见」（用户要的共享视野）。
		#    单机时 side_of(f) == f ⇒ 与从前逐位一致。
		var side := FactionRes.side_of(fid)
		# 1) 整块填 0（PackedByteArray.fill 是引擎侧的一次 memset）
		var mask := PackedByteArray()
		mask.resize(cells)
		mask.fill(0)
		# 2) 把**这一方**每一个贡献格的视野扇区并进来。
		#    ★ OR（`|`）而不是加法：这里要的是布尔量「这一格我看不看得见」，
		#      两支部队都看得见同一格时结果仍然是有视野。
		var mine: Variant = _contrib.get(side, null)
		if typeof(mine) == TYPE_DICTIONARY:
			for idx in (mine as Dictionary).keys():
				var sector := _ensure_sector(world, int(idx), (mine as Dictionary)[idx])
				var n: int = mini(sector.size(), mask.size())
				for i in n:
					if sector[i] != 0:
						mask[i] = 1
		sight[side] = mask


## C# 版的掩码构建已由 `_build_sight_flat()` 取代（2026.10.27）：
## 旧的这条「从 `_contrib` 字典二次打包成三条数组」的路径连同字典一起被删掉了 ——
## 字典去重（同格取最大半径）在数学上等价于「不去重、逐条 OR」（见 `_collect_flat` 的说明），
## 于是 `_build_sight_flat()` 直接吃扁平表，少了两遍字典操作。



## 内核按哪张地图建表（换图 / `reset_cache()` 之后重建一次）。
func _ensure_kernel_map(world) -> void:
	if _kernel_map_ref == world.map:
		return
	_kernel_map_ref = world.map
	var cols: int = int(world.map.cols)
	var rows: int = int(world.map.rows)
	var mountain := PackedByteArray()
	mountain.resize(cols * rows)
	for ty in rows:
		for tx in cols:
			if world.map.is_mountain(tx, ty):
				mountain[ty * cols + tx] = 1
	kernel.SetupMap(cols, rows, mountain)


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
	# ★★ 分桶键是**「同方」的代表阵营**（`FactionRes.side_of`），不是阵营本身 ——
	#    合作模式要求两名玩家**共享视野**（用户已拍板），而「同一方」这件事
	#    在 `FactionRes` 里已经有一套判据（含传递闭包），这里不另发明一份。
	#    ⚠️ 单机时 `side_of(p1) == "p1"` ⇒ 行为与加这个功能之前**逐位一致**。
	#    ⚠️ 名单之外的单位（单机时的 "enemy" 守军）也要有桶：它们挪一格也是
	#       「视野变了」，漏掉会让 refresh_needed 误判成 false（见下面第 1 条）。
	for f in world.factions:
		_side_bucket(String(f))
	# ★★ 2026.10.27（性能）：**每帧一次的「阵营 → 同方代表」缓存**。
	# `FactionRes.side_of()` 不是纯查表：它要沿盟友关系做连通搜索、还会分配一个数组。
	# 原来每个单位、每栋建筑都调一次 —— 256 单位就是每帧 256 次。
	# 同一帧内结果恒定、阵营总数只有几个 ⇒ 缓存一次就够（实测 fog 1.26 → 1.08 ms）。
	var side_cache: Dictionary = {}
	# 1) 单位（含将领与附属兵；阵亡的不给视野）。
	for u in world.units:
		if u == null or not u.alive:
			continue
		var ux := int(u.tx)
		var uy := int(u.ty)
		if not world.map.terrain.has(ux, uy):
			continue
		_dict_max(_bucket_cached(String(u.faction), side_cache), world.map.terrain.idx(ux, uy),
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
		_dict_max(_bucket_cached(String(b.owner), side_cache), world.map.terrain.idx(b.tx, b.ty),
			_building_vision(world.cfg, b))


## `_bucket()` 的缓存版：同一帧内同一个阵营只算一次 `side_of`。
func _bucket_cached(faction: String, side_cache: Dictionary) -> Dictionary:
	var side: Variant = side_cache.get(faction, null)
	if side == null:
		side = FactionRes.side_of(faction)
		side_cache[faction] = side
	return _side_bucket(String(side))


## ★★ 取（必要时新建）**某一方**（= 同方代表阵营）的那张贡献格表。
##
## ⚠️ 桶键是 `FactionRes.side_of(faction)` 而不是 `faction` 本身 —— 这**一处**就是
##   「合作模式两人共享视野」的全部实现（合作要求两个玩家同方，于是他们落进同一个桶）。
##   单机时 `side_of(f)` 就是 `f`，所以这是**纯增量**、不改任何旧行为。
func _bucket(faction: String) -> Dictionary:
	return _side_bucket(FactionRes.side_of(faction))


func _side_bucket(side: String) -> Dictionary:
	var t: Variant = _contrib.get(side, null)
	if typeof(t) == TYPE_DICTIONARY:
		return t
	var fresh := {}
	_contrib[side] = fresh
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
##
## ★★ 查的是**同一方**那一份掩码（`FactionRes.side_of`）—— 这是「共享视野」的另一半。
## ⚠️ 忘了改这一句的症状很隐蔽：**掩码按方存了、查询还按阵营查** ⇒
##   p1（代表 id 恰好等于自己）一切正常，而 p2 永远查不到东西（整屏全黑）。
func tile_visible(faction: String, tx: int, ty: int) -> bool:
	if is_revealed_for_display(faction):
		return tx >= 0 and ty >= 0 and tx < _cols and ty < _rows
	return logic_tile_visible(faction, tx, ty)


## 逻辑视野（AI / 规则用）：不受 `reveal_all_for_display()` 影响。
func logic_tile_visible(faction: String, tx: int, ty: int) -> bool:
	var mask: Variant = sight.get(FactionRes.side_of(faction), null)
	if mask == null:
		return false
	var m: PackedByteArray = mask
	if tx < 0 or ty < 0 or tx >= _cols:
		return false
	var idx: int = ty * _cols + tx
	if idx >= m.size():
		return false                    # 行越界 / 掩码还没按当前地图建好
	return m[idx] != 0


## ★★ 给**观战显示**开这个阵营的全图（不影响 AI 的逻辑视野）。
##    AI 读 `logic_*()`；view/ 读 `*_visible()`，后者会尊重这个标记。
func reveal_all_for_display(faction: String) -> void:
	if faction == "":
		return
	_display_reveal[FactionRes.side_of(faction)] = true


func is_revealed_for_display(faction: String) -> bool:
	return _display_reveal.has(FactionRes.side_of(faction))


## 某个单位对这个阵营该不该画出来？
##   · 同一阵营 → 永远可见（己方部队不会被自己的迷雾盖住）；
##   · 其他阵营 → 只有**当前视野内**才可见（走出视野就消失，需求确认「不保留记忆」）。
func unit_visible(faction: String, u) -> bool:
	if is_revealed_for_display(faction):
		return u != null and u.alive
	return logic_unit_visible(faction, u)


func logic_unit_visible(faction: String, u) -> bool:
	if u == null or not u.alive:
		return false
	if FactionRes.same_side(String(u.faction), faction):
		return true
	return logic_tile_visible(faction, int(u.tx), int(u.ty))


## 某栋建筑对这个阵营该不该画出来？
##   · 无主（owner == ""，例如区划中心）→ 所有人都看得见（它不是谁的秘密）；
##   · 同一阵营 → 永远可见；
##   · 其他阵营 → **当前视野内**，或者**曾经看见过一次**（永久记忆，直到被摧毁）。
func building_visible(faction: String, b) -> bool:
	if is_revealed_for_display(faction):
		return b != null and b.alive
	return logic_building_visible(faction, b)


func logic_building_visible(faction: String, b) -> bool:
	if b == null or not b.alive:
		return false
	var owner := String(b.owner)
	if owner == "" or FactionRes.same_side(owner, faction):
		return true
	if logic_tile_visible(faction, int(b.tx), int(b.ty)):
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
			if logic_tile_visible(fid, int(b.tx), int(b.ty)):
				table[b] = true
		_sighted[fid] = table


## 拆除 / 换主时立即从记忆里剔掉一栋楼（视图与测试可以主动调；不调也会被
## `_prune_sighted` 在下一帧清掉 —— 这里只是让「被摧毁」那一刻不残留一帧）。
func forget_building(b) -> void:
	if b == null:
		return
	for fid in _sighted.keys():
		(_sighted[fid] as Dictionary).erase(b)
