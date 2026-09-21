## crowd_bridge.gd —— logic 与 C# 群体内核之间的**唯一**接口
##
## 职责只有三件：
##   1. 把 world 的静态信息（地形 / 按阵营的格级阻挡 / 建筑本体）编成整块 Packed 表，
##      **只在 building_revision 变化时**重编（不是每帧）；
##   2. 每帧把 1000 个单位的位置/阵营/权重编成 4 条 Packed 数组，**一次**调进内核；
##   3. 把结果写回单位对象。
##
## ★ 为什么接口按「批」划：实测 1000 次跨语言小调用 = 518 µs/帧，
##   1 次批量调用 = 4.8 µs/帧（差 108 倍）。任何「每个单位调一次 C#」的写法都是白干。
##
## ★★ 为什么还需要回退：C# 程序集只有 .NET(mono) 版引擎才加载。用普通版 Godot 打开
##    这个工程时内核是 null —— 那时**退回 GDScript 实现**，游戏照样能跑（只是慢）。
##    这也是「同一行为两套实现」的对照组：bench 里可以两边各跑一遍比位置。
##
## ⚠️ 逻辑层仍然不碰 Node：本文件与内核都是纯逻辑，只是换了个语言。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CollisionRes = preload("res://logic/collision.gd")
const FactionRes = preload("res://logic/faction.gd")
## ★ 给「每单位」的循环变量加类型：无类型时 u.pos / u.kind / u.path 都是**动态属性查找**，
##   而这里的打包循环每帧要跑 1000 次 × 五六次访问。
##   （unit.gd 不 preload 本文件，所以不是循环依赖 —— 见 combat.gd 里那条同类说明。）
const UnitRes = preload("res://logic/unit.gd")

const KERNEL_PATH := "res://logic/crowd/CrowdKernel.cs"

## C# 内核实例；加载不到就是 null（普通版引擎 / 还没构建）
var kernel = null

## 反向引用本桥所属的 world —— **必须是弱引用**。
##
## ★ 为什么要它：`pathfinder.reachable_tiles()` 这类**静态**工具函数手里只有
##   map/buildings，够不着内核。让桥自己记住 world，它们就能通过桥问到内核，
##   而不必把 world 参数一路加进每个寻路函数的签名里。
##
## ⚠️⚠️ 必须是 `WeakRef`，不能直接存 world：world 持有 crowd，crowd 再强引用 world
##    就是**引用循环**——RefCounted 的环永远不会被释放（每个 World.create() 都漏一整套
##    world + 单位）。实测就是这么发现的：bench 退出时报
##    「1021 ObjectDB instances were leaked」（1000 个单位 + 世界 + 桥）。
var world_ref = null


func set_world(w) -> void:
	world_ref = weakref(w) if w != null else null


## 取回本桥所属的 world（世界已经释放时返回 null）
func world_here():
	if world_ref == null:
		return null
	return world_ref.get_ref()

## 表的重建时机
var _map_ref = null
var _revision: int = -1
var _faction_list: Array = []
var _faction_index: Dictionary = {}

## 每帧复用的 Packed 缓冲（不每帧新建，避免无谓分配）
var _xy := PackedFloat64Array()
var _fac := PackedInt32Array()
var _wgt := PackedFloat64Array()
var _alive := PackedByteArray()
var _buf_n: int = 0

## ---- 警戒索敌（每帧一次批量算好，见 refresh_targets）----
var _tgt_xy := PackedFloat64Array()
var _tgt_alive := PackedByteArray()
var _tgt_side := PackedInt32Array()
var _tgt_aggro := PackedFloat64Array()
var _tgt_radius := PackedFloat64Array()
## 本次打包进内核的**原始单位下标**（见 refresh_targets 的说明：只打包会被问到的那些）
var _tgt_unit := PackedInt32Array()
## 本帧哪些阵营有人在索敌（按阵营下标标记，每帧重置）
var _side_scans := PackedByteArray()
var _target_idx := PackedInt32Array()
var _targets_ready: bool = false
## 这份结果属于哪一帧（用 world.frame_serial 对齐，避免缓存在 tick 之外被误用）
var _targets_serial: int = -1

## 距离场缓存：key = "阵营下标:目标格:building_revision" → PackedFloat64Array。
##
## ★ 为什么要缓存：群编时 1000 个单位的目标是**同一个格**，所以一次 Dijkstra 够全队用
##   （A* 是每个单位一次，实测 19 ms/次 → 17 秒的命令帧冻结）。
##   换目标（点别处 / 阵型槽位）才会再建一张；LRU 只留最近几张，避免内存无上限。
const FIELD_CACHE_MAX := 4
var _field_cache: Dictionary = {}
var _field_order: Array = []
## ★ 诊断计数器（只有基准读）：建场次数 / 建场累计微秒。见 _field_for 的注释。
var field_builds: int = 0
var field_build_us: int = 0

## 每格地形代价（共享，只有换地图才重算）
var _move_cost := PackedFloat64Array()


func _init() -> void:
	var s = load(KERNEL_PATH)
	if s != null:
		kernel = s.new()


## 内核可用吗（测试与 bench 用它区分「跑的是哪一套」）
func available() -> bool:
	return kernel != null


## 换世界 / 重开时清掉缓存，下次调用重建
func reset_cache() -> void:
	_map_ref = null
	_revision = -1
	_faction_list = []
	_faction_index = {}
	_field_cache = {}
	_field_order = []
	_move_cost = PackedFloat64Array()


# ------------------------------------------------------------------
# 每帧入口（world.tick 只调这两个）
# ------------------------------------------------------------------

## 一帧的碰撞（**一次打包、一次调用、一次写回**）。
##
## 语义 = 先跑 units 之间的软分离，再把单位从建筑本体里推出来（与 world.tick 原来的
## 两步调用一模一样，顺序也没变），只是把「打包 1000 单位的数组」这件事从两次压到一次。
func resolve_all(world, cfg: ConfigRes) -> Dictionary:
	if kernel == null or not _use_csharp(cfg):
		var a := CollisionRes.resolve(world, cfg)
		var b := CollisionRes.resolve_buildings(world, cfg)
		return {"pairs": int(a["pairs"]), "pushed": int(b["pushed"])}
	_sync_tables(world, cfg)
	_pack(world, cfg)
	if _buf_n <= 0:
		return {"pairs": 0, "pushed": 0}
	var out: PackedFloat64Array = kernel.ResolveAll(
		_xy, _fac, _wgt, _alive, _buf_n,
		CollisionRes.radius(cfg),
		clampf(cfg.unit_overlap_allowance, 0.0, 1.0),
		maxf(0.0, cfg.unit_collision_slack),
		maxi(1, cfg.unit_collision_iterations)
	)
	_unpack(world, out)
	return {"pairs": kernel.StatsPairs, "pushed": kernel.StatsPushed}


## 单位之间的软分离。@return Dictionary {"pairs":…, "pushed":…}（与 logic/collision.gd 同口径）
func resolve(world, cfg: ConfigRes) -> Dictionary:
	if kernel == null or not _use_csharp(cfg):
		return CollisionRes.resolve(world, cfg)
	_sync_tables(world, cfg)
	_pack(world, cfg)
	if _buf_n <= 0:
		return {"pairs": 0, "pushed": 0}
	var out: PackedFloat64Array = kernel.Resolve(
		_xy, _fac, _wgt, _alive, _buf_n,
		CollisionRes.radius(cfg),
		clampf(cfg.unit_overlap_allowance, 0.0, 1.0),
		maxf(0.0, cfg.unit_collision_slack),
		maxi(1, cfg.unit_collision_iterations)
	)
	_unpack(world, out)
	return {"pairs": kernel.StatsPairs, "pushed": kernel.StatsPushed}


## 建筑本体的硬碰撞（大本营 / 箭塔）。@return Dictionary {"pushed":…}
func resolve_buildings(world, cfg: ConfigRes) -> Dictionary:
	if kernel == null or not _use_csharp(cfg):
		return CollisionRes.resolve_buildings(world, cfg)
	_sync_tables(world, cfg)
	_pack(world, cfg)
	if _buf_n <= 0:
		return {"pushed": 0}
	var out: PackedFloat64Array = kernel.ResolveBodies(
		_xy, _fac, _alive, _buf_n,
		CollisionRes.radius(cfg),
		maxi(1, cfg.unit_collision_iterations)
	)
	_unpack(world, out)
	return {"pushed": kernel.StatsPushed}


## 走 C# 还是走 GDScript（config 可切，方便两边对照与回退）
func _use_csharp(cfg: ConfigRes) -> bool:
	if not cfg.unit_collision_enabled:
		return false
	return cfg.unit_collision_backend == "csharp"


## 每帧一次的警戒索敌（`combat.acquire_target` 的批量版）。
##
## ★★ 为什么必须有它：GDScript 版是每个**待命**单位扫一遍 world.units = O(n²)，
##    1000 单位全部待命时实测 **283 ms/帧（4 fps）**，而「常态」下单位大部分时间在待命。
##    这里按阵营分组（在 C# 里），每个单位只扫敌对那一组：
##    场上没有敌人时内层循环一次都不进。
##
## 结果按 `world.frame_serial` 对齐，只在**当帧**有效（tick 之外读到就返回空）。
func refresh_targets(world, cfg: ConfigRes) -> void:
	_targets_ready = false
	_targets_serial = -1
	if kernel == null or not _use_csharp(cfg) or world == null:
		return
	var n: int = world.units.size()
	if n <= 0:
		return
	_sync_tables(world, cfg)

	if _tgt_xy.size() < n * 2:
		_tgt_xy.resize(n * 2)
	if _tgt_alive.size() < n:
		_tgt_alive.resize(n)
	if _tgt_side.size() < n:
		_tgt_side.resize(n)
	if _tgt_aggro.size() < n:
		_tgt_aggro.resize(n)
	if _tgt_radius.size() < n:
		_tgt_radius.resize(n)
	if _tgt_unit.size() < n:
		_tgt_unit.resize(n)
	if _target_idx.size() < n:
		_target_idx.resize(n)

	# ★★ 只打包「这一帧真的会被问到」的单位 —— 但要注意**两个方向**：
	#    · **索敌方**：只有没在赶路（或行军攻击中）的单位才会索敌（与 combat.update_unit 同口径）；
	#    · **目标方**：一个阵营只要有人在索敌，**别的阵营**的活单位就都可能被它锁定，
	#      必须一起打包 —— 漏掉它们会出现「正在移动的敌人打不到」这种错（实测被
	#      test_logic 的「警戒半径内的敌人被锁定」当场抓住：第一版只打包了索敌方）。
	#    所以：只要本帧有 ≥2 个阵营在索敌，或者某单位的阵营与唯一的索敌方不同，
	#    它就得进数组。
	#    单阵营（大多数情况）时「正在赶路的自己人」既不是索敌方也不可能是目标 → 整个跳过，
	#    移动场景下这就是全部 1000 个单位。
	var alive_n := 0
	var scan_count := 0
	var only_scan_side := -1
	var m := 0
	for i in n:
		var u: UnitRes = world.units[i]
		if not u.alive:
			continue
		alive_n += 1
		if u.moving and not u.has_attack_move:
			continue
		var f: String = String(u.faction)
		if not _faction_index.has(f):
			_add_faction(f)
			_rebuild_all_tables(world, cfg)
		var si: int = int(_faction_index[f])
		if _side_scans.size() <= si:
			_side_scans.resize(si + 1)
		if _side_scans[si] == 0:
			_side_scans[si] = 1
			scan_count += 1
			only_scan_side = si
		_tgt_unit[m] = i
		_tgt_xy[m * 2] = u.pos.x
		_tgt_xy[m * 2 + 1] = u.pos.y
		_tgt_alive[m] = 1
		_tgt_side[m] = si
		_tgt_aggro[m] = cfg.aggro_range
		_tgt_radius[m] = cfg.unit_radius_of(u.kind)
		m += 1

	# 第二遍：把「可能被锁定的敌人」也补进去。
	# 全部活单位都已经在第一遍里了（所有人都在索敌）→ 这一次循环都省掉。
	#
	# ★★ 注意：这一遍是**追加**到打包数组末尾的，所以**打包顺序 ≠ 单位顺序**
	#    （第一遍跳过了在赶路的单位，它们的下标可能夹在中间）。
	#    下面写回结果时必须把这一点考虑进去 —— 见 packed_in_order。
	var packed_in_order: bool = (m == n)
	if m < alive_n and scan_count > 0:
		for i in n:
			var u2: UnitRes = world.units[i]
			if not u2.alive:
				continue
			if not (u2.moving and not u2.has_attack_move):
				continue                       # 索敌方：第一遍已经放进去了
			var f2: String = String(u2.faction)
			# ⚠️ 必须和第一遍一样「没登记过就补登记」：写 -1 的话内核会把 -1 折叠成 0 号桶，
			#    也就是**和阵营 0 撞成同一方** —— 那个敌人就永远索不到，
			#    调用方会退回去扫建筑（表现就是「错过近处的敌人去打远处的墙」）。
			if not _faction_index.has(f2):
				_add_faction(f2)
				_rebuild_all_tables(world, cfg)
			var si2: int = int(_faction_index[f2])
			var can_be_target: bool = scan_count >= 2 or si2 != only_scan_side
			if not can_be_target:
				continue
			_tgt_unit[m] = i
			_tgt_xy[m * 2] = u2.pos.x
			_tgt_xy[m * 2 + 1] = u2.pos.y
			_tgt_alive[m] = 1
			_tgt_side[m] = si2
			_tgt_aggro[m] = cfg.aggro_range
			_tgt_radius[m] = cfg.unit_radius_of(u2.kind)
			m += 1
	_side_scans.fill(0)

	if m <= 0:
		_target_idx.fill(-1)
		return

	var res: PackedInt32Array = kernel.AcquireTargets(
		_tgt_xy, _tgt_alive, _tgt_side, _tgt_aggro, _tgt_radius, m)
	if packed_in_order:
		# 第一遍就按单位顺序打包了全部单位 → 打包下标 == 单位下标，可以直接用
		_target_idx = res
	else:
		# ★★ 必须把**打包下标**翻译回**真实单位下标**。
		#    内核返回的是「第 k 个被打包的单位」的下标，而 _tgt_unit[k] 才是它在
		#    world.units 里的位置。
		#    ⚠️⚠️ 判据只能是「**第一遍就打包了全部单位**」，不能图快写 `if m == n`：
		#        m 是**两遍之后**的总数，第二遍会把第一遍跳过的单位追加到末尾 ——
		#        于是 `m == n` 完全可能在「顺序已经被打乱」时成立。
		#        实测症状（手玩报的「新生成的友军单位有的会攻击其他友军」）：
		#        某个自己人读到了**敌方那一格**的结果，而那一格的目标正是一个自己人；
		#        `combat.acquire_target` 信任内核结果，拿到就直接锁定 → 自己人打自己人。
		#        （复现与回归见 tests/test_csharp_bridge.gd 的 _test_no_friendly_fire：
		#          只要有一个「在赶路的自己人」夹在站定的自己人中间就会中招。）
		#    ⚠️ 改这里之前先想清楚：_tgt_unit 是「打包下标 → 单位下标」的唯一映射。
		_target_idx.fill(-1)
		for k in m:
			var packed_hit: int = res[k]
			if packed_hit >= 0:
				_target_idx[_tgt_unit[k]] = _tgt_unit[packed_hit]
	_targets_ready = true
	_targets_serial = world.frame_serial


## 本帧的索敌结果对第 i 个单位是否可用（序号必须与当前帧一致）
func targets_ready(world) -> bool:
	return _targets_ready and world != null and _targets_serial == world.frame_serial


## 第 i 个单位本帧的索敌结果（没有则 null）
func target_at(world, i: int) -> Variant:
	if i < 0 or i >= _target_idx.size() or i >= world.units.size():
		return null
	var j: int = _target_idx[i]
	if j < 0 or j >= world.units.size():
		return null
	return world.units[j]


# ------------------------------------------------------------------
# 1. 建表（只在 revision 变化时）
# ------------------------------------------------------------------

func _sync_tables(world, cfg: ConfigRes) -> void:
	if world.map != _map_ref:
		_map_ref = world.map
		_revision = -1                      # 换图 → 一切重来
		_rebuild_factions(world)
		_build_terrain(world)
		_build_move_cost(world)
		_field_cache = {}
		_field_order = []
	if world.building_revision != _revision:
		_revision = world.building_revision
		_build_faction_tiles(world, cfg)
		_build_bodies(world, cfg)
		_build_pathing_buildings(world, cfg)
		_field_cache = {}                   # 建筑变了 → 旧的距离场作废
		_field_order = []


## 阵营 → 下标。内核里所有按阵营的查表都用这个下标。
func _rebuild_factions(world) -> void:
	_faction_list = []
	_faction_index = {}
	for f in world.factions:
		_add_faction(String(f))
	for u in world.units:
		_add_faction(String(u.faction))
	for b in world.building_list:
		_add_faction(String(b.owner))
	_add_faction(FactionRes.DEFAULT_FACTION)
	_add_faction(FactionRes.NPC_FACTION)


func _add_faction(f: String) -> void:
	# 空 owner（区划中心那种中立建筑）不需要自己的阵营下标：它只挡别人，不会被当成单位
	if f == "" or _faction_index.has(f):
		return
	_faction_index[f] = _faction_list.size()
	_faction_list.append(f)


func _build_terrain(world) -> void:
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	var blocked := PackedByteArray()
	blocked.resize(cols * rows)
	# ★ 直接读两张网格的原始数组，不逐格调 terrain_walkable()：
	#   那个函数每格要做 has + tile_exists + String 比较三次函数调用，1 万格就是 3 万次。
	var cells: Array = world.map.terrain.data
	var exists: Array = world.map.exists.data
	var n: int = mini(cells.size(), exists.size())
	for i in n:
		var walkable: bool = bool(exists[i]) and String(cells[i]) != "mountain"
		blocked[i] = 0 if walkable else 1
	kernel.SetupTerrain(cols, rows, blocked)


## 按阵营的格级阻挡表：GDScript 只遍历**建筑**（几十个）算出「每格的建筑阻挡掩码」，
## 整张按阵营的表交给 C# 一遍填完。
##
## ★★ 为什么不是在这里逐格调 passable()：那是 factionCount × cols × rows 次调用
##    （100×100 × 2 阵营 = 2 万次，实测 ~70 ms），而它在**每次建/拆建筑之后**都要重跑 ——
##    也就是每盖一堵墙卡一下。改成几十次建筑遍历 + C# 一遍填充。
func _build_faction_tiles(world, cfg: ConfigRes) -> void:
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	var n: int = cols * rows
	var nf: int = _faction_list.size()
	var blocker := PackedInt32Array()
	blocker.resize(n)

	for b in world.building_list:
		if not b.alive:
			continue
		if b.tx < 0 or b.ty < 0 or b.tx >= cols or b.ty >= rows:
			continue
		var m := 0
		for fi in nf:
			# ★ 这里用的是**格级**阻挡（blocks），不是本体阻挡（body_blocks）——
			#   城墙整格挡敌方、大本营/箭塔整格对谁都不封，两者的差别就是这条。
			if b.blocks(_faction_list[fi]):
				m |= 1 << fi
		if m != 0:
			blocker[b.ty * cols + b.tx] = m

	kernel.SetupTileBlockers(nf, blocker)


## 建筑本体表：每格一个下标 + 中心/半边长 + 「挡哪些阵营」的位掩码。
## 不挡任何阵营的本体不进表（对应 collision.gd 里 `body_blocks()` 直接返回 false 的那些）。
func _build_bodies(world, cfg: ConfigRes) -> void:
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	var at := PackedInt32Array()
	at.resize(cols * rows)
	at.fill(-1)
	var cx := PackedFloat64Array()
	var cy := PackedFloat64Array()
	var half := PackedFloat64Array()
	var mask := PackedInt32Array()

	for b in world.building_list:
		if not b.alive:
			continue
		if b.tx < 0 or b.ty < 0 or b.tx >= cols or b.ty >= rows:
			continue
		var m := 0
		for fi in _faction_list.size():
			if b.body_blocks(_faction_list[fi]):
				m |= 1 << fi
		if m == 0:
			continue
		at[b.ty * cols + b.tx] = cx.size()
		cx.append(float(b.tx) + 0.5)
		cy.append(float(b.ty) + 0.5)
		half.append(b.body_half(cfg))
		mask.append(m)

	kernel.SetupBodies(at, cx, cy, half, mask)


# ------------------------------------------------------------------
# 2. 打包 / 3. 写回
# ------------------------------------------------------------------

## 把单位编成 4 条 Packed 数组。位置用 double（GDScript 的 float 是 64 位，
## 而 unit.pos 是 Vector2 的 32 位 —— 中间量按 double 走才不会和 GDScript 版差出误差）。
func _pack(world, cfg: ConfigRes) -> void:
	var n: int = world.units.size()
	if _xy.size() < n * 2:
		_xy.resize(n * 2)
	if _fac.size() < n:
		_fac.resize(n)
	if _wgt.size() < n:
		_wgt.resize(n)
	if _alive.size() < n:
		_alive.resize(n)

	var moving_w: float = maxf(0.0, cfg.unit_push_moving_weight)
	var idle_w: float = maxf(0.0, cfg.unit_push_idle_weight)

	for i in n:
		var u: UnitRes = world.units[i]
		_xy[i * 2] = u.pos.x
		_xy[i * 2 + 1] = u.pos.y
		var f: String = String(u.faction)
		if not _faction_index.has(f):
			# 出现了没登记过的阵营（联机换阵营 / 新刷的兵）：立刻补表，别让它查到 -1
			_add_faction(f)
			_rebuild_all_tables(world, cfg)
		_fac[i] = int(_faction_index[f])
		_alive[i] = 1 if u.alive else 0
		# ★ 权重口径必须与 collision.gd 的 _weight() 一字不差
		if u.settling or (u.moving and not u.path.is_empty()):
			_wgt[i] = moving_w
		else:
			_wgt[i] = idle_w
	_buf_n = n


func _rebuild_all_tables(world, cfg: ConfigRes) -> void:
	_build_faction_tiles(world, cfg)
	_build_bodies(world, cfg)


## 把内核算出来的位置写回去。只在真的变了的时候 sync_tile（它每帧 1000 次也不算贵，
## 但没必要为没动的单位做）。
func _unpack(world, out: PackedFloat64Array) -> void:
	var n: int = world.units.size()
	for i in n:
		var u: UnitRes = world.units[i]
		var nx: float = out[i * 2]
		var ny: float = out[i * 2 + 1]
		if absf(u.pos.x - nx) > 1e-9 or absf(u.pos.y - ny) > 1e-9:
			u.pos = Vector2(nx, ny)
			u.sync_tile(world.map)


# ------------------------------------------------------------------
# 寻路：距离场（把「一次命令 = N 次 A*」压成「一次命令 = 1 次 Dijkstra」）
# ------------------------------------------------------------------

## 每格地形代价（与 map.terrain_cost 一致）。只有换地图才重算。
func _build_move_cost(world) -> void:
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	_move_cost = PackedFloat64Array()
	_move_cost.resize(cols * rows)
	for y in rows:
		for x in cols:
			_move_cost[y * cols + x] = world.map.terrain_cost(x, y)


## 建筑相关的寻路数据：按阵营的「建筑惩罚」标记 + 每格是否有活建筑。
## ★ 惩罚只加在**本体真的挡这个阵营**的格子上（与 pathfinder._building_penalty 同口径）。
func _build_pathing_buildings(world, cfg: ConfigRes) -> void:
	var cols: int = world.map.cols
	var rows: int = world.map.rows
	var n: int = cols * rows
	var nf: int = _faction_list.size()
	var penalty := PackedByteArray()
	penalty.resize(nf * n)
	var has_b := PackedByteArray()
	has_b.resize(n)

	for b in world.building_list:
		if not b.alive:
			continue
		if b.tx < 0 or b.ty < 0 or b.tx >= cols or b.ty >= rows:
			continue
		var idx: int = b.ty * cols + b.tx
		has_b[idx] = 1
		for fi in nf:
			if b.body_blocks(_faction_list[fi]):
				penalty[fi * n + idx] = 1

	kernel.SetupPathing(
		_move_cost, penalty, cfg.path_building_penalty, has_b,
		cfg.path_diagonal,
		cfg.path_diagonal_corner_cut,
		CollisionRes.radius(cfg)
	)


## 阵营字符串 → 下标（未知返回 -1）
func faction_index(f: String) -> int:
	return int(_faction_index.get(f, -1))


## 团队移动的地块路线：走距离场（一次建场全队共用），内核不可用时回退 A*。
##
## @return Array[Vector2i]（不含起点、含终点）/ 空数组（原地）/ null（不可达）
func tile_path(world, cfg: ConfigRes, from: Vector2i, to: Vector2i, faction: String) -> Variant:
	if kernel == null or not _use_csharp(cfg):
		return PathfinderRes.find_path(world.map, world.buildings, cfg, from, to, faction)
	var map = world.map
	if not map.terrain.has(from.x, from.y) or not map.terrain.has(to.x, to.y):
		return null
	if from == to:
		var empty: Array[Vector2i] = []
		return empty

	_sync_tables(world, cfg)
	var fi: int = faction_index(faction)
	if fi < 0:
		return PathfinderRes.find_path(map, world.buildings, cfg, from, to, faction)

	var goal_idx: int = map.terrain.idx(to.x, to.y)
	var field := _field_for(fi, goal_idx, world)
	kernel.SetDescendFaction(fi)
	var idxs: PackedInt32Array = kernel.DescendPath(
		field, map.terrain.idx(from.x, from.y), goal_idx,
		4 * (map.cols + map.rows) + 8
	)
	if idxs.is_empty():
		return null
	var cols: int = map.cols
	var out: Array[Vector2i] = []
	for i in idxs:
		out.append(Vector2i(i % cols, i / cols))
	return out


## 群编用：全队共用**一张**距离场，每个单位各自的落点靠它拼出来。
##
## 路线 = 顺场下降(from → field_tile) ++ 反向(顺场下降(to → field_tile))
##   · 前半段：从自己的位置走到「全队的目标点」；
##   · 后半段：从全队目标点走出去到自己的槽位（把「下降」倒过来走）。
## 两半都是场里的合法一步，所以拼起来的路线每一段都合法
## （对角守卫在正反两个方向上判定的是同一对格子，是几何对称的）。
##
## ★ 为什么必须共用一张场：队形让每个单位的落点都不同，如果各建各的场，
##   1000 个单位就是 1000 次 Dijkstra —— 那正是「一次命令 = N 次寻路」的老毛病。
func tile_path_via(world, cfg: ConfigRes, from: Vector2i, to: Vector2i,
		field_tile: Vector2i, faction: String) -> Variant:
	if kernel == null or not _use_csharp(cfg):
		return PathfinderRes.find_path(world.map, world.buildings, cfg, from, to, faction)
	var map = world.map
	if not map.terrain.has(from.x, from.y) or not map.terrain.has(to.x, to.y):
		return null
	if from == to:
		var empty: Array[Vector2i] = []
		return empty

	_sync_tables(world, cfg)
	var fi: int = faction_index(faction)
	if fi < 0:
		return PathfinderRes.find_path(map, world.buildings, cfg, from, to, faction)

	var anchor_idx: int = map.terrain.idx(field_tile.x, field_tile.y)
	var goal_idx: int = map.terrain.idx(to.x, to.y)
	var field := _field_for(fi, anchor_idx, world)
	kernel.SetDescendFaction(fi)
	var cols: int = map.cols
	var guard: int = 4 * (map.cols + map.rows) + 8

	var out: Array[Vector2i] = []
	if from != field_tile:
		var head: PackedInt32Array = kernel.DescendPath(field, map.terrain.idx(from.x, from.y), anchor_idx, guard)
		if head.is_empty():
			return null
		for i in head:
			out.append(Vector2i(i % cols, i / cols))
	if to != field_tile:
		var tail: PackedInt32Array = kernel.DescendPath(field, goal_idx, anchor_idx, guard)
		if tail.is_empty():
			return null
		# 反向：从全队目标点走出去到自己的槽位。末尾那个 anchor 与前半段的末点重合，跳过。
		for k in range(tail.size() - 1, -1, -1):
			var i2: int = tail[k]
			out.append(Vector2i(i2 % cols, i2 / cols))
	if out.is_empty():
		return null
	return out


## 取（或建）一张距离场。key 里带 building_revision，所以建筑一变就自然作废
## （_sync_tables 里还会整表清一次，避免旧场一直占着 LRU）。
##
## ★★ 诊断：`field_builds` / `field_build_us` 记录建场次数与总耗时。
##    为什么必须盯着它：**建一张场是一次全图 Dijkstra**，而 LRU 只有 4 张。
##    追击时每个敌人所在格都是一张新场 —— 60 个敌人就把 4 格的 LRU 冲垮，
##    于是一帧里几十上百次 Dijkstra，实机行军攻击直接掉到 20 fps。
func _field_for(fi: int, goal_idx: int, world) -> PackedFloat64Array:
	var key := "%d:%d:%d" % [fi, goal_idx, world.building_revision]
	if _field_cache.has(key):
		return _field_cache[key]
	var _t_build := Time.get_ticks_usec()
	var field: PackedFloat64Array = kernel.BuildField(fi, goal_idx)
	field_build_us += Time.get_ticks_usec() - _t_build
	field_builds += 1
	while _field_order.size() >= FIELD_CACHE_MAX:
		var oldest = _field_order.pop_front()
		_field_cache.erase(oldest)
	_field_cache[key] = field
	_field_order.append(key)
	return field


## 按阵营可达的格子掩码（1 = 可达）。对应 pathfinder.reachable_tiles()。
## 内核不可用时返回空数组，调用方自己回退。
func reachable_mask(world, cfg: ConfigRes, from: Vector2i, faction: String) -> PackedByteArray:
	if kernel == null or not _use_csharp(cfg):
		return PackedByteArray()
	if not world.map.terrain.has(from.x, from.y):
		return PackedByteArray()
	_sync_tables(world, cfg)
	var fi: int = faction_index(faction)
	if fi < 0:
		return PackedByteArray()
	return kernel.ReachableMask(fi, world.map.terrain.idx(from.x, from.y))


## 直线是否全程可切（对应 pathfinder.segment_clear）。
## @return bool，或 null = 内核不可用（调用方回退到 GDScript 的 DDA）
func segment_clear_here(cfg: ConfigRes, a: Vector2, b: Vector2, faction: String) -> Variant:
	if kernel == null or not _use_csharp(cfg):
		return null
	var w = world_here()
	if w == null:
		return null
	_sync_tables(w, cfg)
	var fi: int = faction_index(faction)
	if fi < 0:
		return null
	return kernel.SegmentClear(fi, a.x, a.y, b.x, b.y)


## 同上，但用桥自己记住的 world —— 供 `pathfinder` 那些**静态**工具函数调用
## （它们手里只有 map/buildings，够不着内核；见 world_ref 的说明）。
func reachable_mask_here(cfg: ConfigRes, from: Vector2i, faction: String) -> PackedByteArray:
	var w = world_here()
	if w == null:
		return PackedByteArray()
	return reachable_mask(w, cfg, from, faction)
