## world.gd —— 世界容器：持有 map / buildings / zones / units / 经济，推进 tick()
##               （对应 HTML 版 main.js 的 state 对象 + update(dt) 主循环）
##
## ★ 这是**唯一**拥有真实状态的地方（见 docs/architecture.md 第五节）。
##   view/ 只读它、并且只通过 command_processor 改它。
##
## 本轮固定单机：factions = ['player']。但阵营相关的地方一律写成「按 faction 比较」，
## 不写死 'player' —— 第 1 轮加联机时这里不用改（命令 / 快照边界已经留好）。
##
## ⚠️ 逻辑层不用信号、不在遍历中改集合（见 docs/pitfalls.md 2.5）：
##    本帧发生的事件都进 `_events`，tick() 末尾统一收口，view/ 只读。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const MapDataRes = preload("res://logic/map_data.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const UnitRes = preload("res://logic/unit.gd")
const ZoneRes = preload("res://logic/zone.gd")
const EconomyRes = preload("res://logic/economy.gd")
const CombatRes = preload("res://logic/combat.gd")
const EnemyAiRes = preload("res://logic/enemy_ai.gd")
const CollisionRes = preload("res://logic/collision.gd")

var cfg: ConfigRes = null
var map: MapDataRes = null

## 建筑：Grid 存「每格最多一个」+ 数组存权威列表 + (tx,ty) → Building 查询
var buildings: GridRes = null
var building_list: Array = []
var _building_at: Dictionary = {}
## 建造 / 拆除时 +1，用于「按需重算区块归属」而不是每帧算
var building_revision: int = 0
var last_ownership_revision: int = -1

var zones: ZoneRes = null
var units: Array = []

## 阵营
var my_faction: String = FactionRes.DEFAULT_FACTION
var factions: Array[String] = []
var enemy_faction: String = FactionRes.NPC_FACTION

## 经济
var resources: Dictionary = {"food": 0.0, "gold": 0.0}
var owned_tiles: int = 0

## 每个阵营的大本营坐标与将领出生点（复活点、敌人 AI 目标都从这里取）
var faction_bases: Dictionary = {}
var faction_spawns: Dictionary = {}

var time: float = 0.0
## 对战规则总开关 —— **本轮永远是 false**。第 1 轮联机时才置 true。
##
## ★ 存在的理由（见 docs/pitfalls.md 3.8）：HTML 版的复活一开始泄漏进了单机，
##   死了的测试敌人 8 秒后又站起来。开关不是为了联机，是为了「单机行为不被改写」。
var pvp_enabled: bool = false

var _events: Array = []
var _enemy_serial: int = 0
## 招募序号：只用来生成**永不重复**的 id（`general-1-r3`）。
## 为什么不用「现有亲兵数 + 1」：那个数会因为阵亡 / 离场而回退，回退就会撞名。
var _recruit_serial: int = 0
var enemy_spawn_timer: float = 0.0
var debug_auto_spawn: bool = false


static func create(p_cfg: ConfigRes, map_path: String = "res://data/map_01.json") -> RefCounted:
	var w = new()
	w.cfg = p_cfg
	w.map = MapDataRes.load_from(map_path, p_cfg)
	if w.map == null:
		push_error("World.create：地图载入失败（%s）" % map_path)
		return null
	w.reset()
	return w


## 回到干净的开局状态（单机 always only 'player'）
func reset(p_my_faction: String = "", p_roster: Array = []) -> void:
	building_list = []
	_building_at = {}
	building_revision = 0
	last_ownership_revision = -1
	units = []
	_events = []
	_enemy_serial = 0
	enemy_spawn_timer = 0.0
	debug_auto_spawn = false
	time = 0.0
	owned_tiles = 0

	buildings = GridRes.new(map.cols, map.rows, null)

	my_faction = p_my_faction if p_my_faction != "" else FactionRes.DEFAULT_FACTION
	factions = []
	if p_roster.is_empty():
		factions.append(my_faction)
	else:
		for f in p_roster:
			factions.append(String(f))

	resources = {"food": cfg.start_food, "gold": cfg.start_gold}
	faction_bases = {}
	faction_spawns = {}

	zones = ZoneRes.build_from_map(map, cfg, factions)

	var primary: String = factions[0] if factions.size() > 0 else my_faction
	apply_faction_layout(my_faction, primary)
	# 单机名单只有我这一方；联机时这里要为名单里每一方都建出基地与部队
	for f in factions:
		if f != my_faction:
			apply_faction_layout(f, primary)
	# 地图上**预置**的建筑（对家据点这类固定摆设，坐标写在 map_01.json 的 "buildings" 里）。
	# 放在各阵营出生点之后：它们的坐标是手写的，不与出生点抢格；被占住的格子 add_building 会自己拒。
	for p in map.prefab_buildings:
		add_building(String(p["type"]), int(p["x"]), int(p["y"]), String(p["owner"]), true)
	# 地图上**预置**的单位（测试用的守军，写在 map_01.json 的 "units" 里）。
	# id 走 _enemy_serial —— 与调试刷兵同一套序号，永远不会撞名。
	for p in map.prefab_units:
		_enemy_serial += 1
		var pu = UnitRes.create(
			cfg, "enemy-%d" % _enemy_serial, String(p["name"]),
			Vector2i(int(p["x"]), int(p["y"])), String(p["faction"]), String(p["kind"])
		)
		pu.hold_position = bool(p["hold"])
		units.append(pu)
	# 出生点的大本营也会把所在区块直接收归己方（zone_owned_by_building）；
	# 这一条在「开局第一帧之前」就该成立，否则 HUD 上的领地会在第一次 tick 前闪一下空
	refresh_ownership()


## 建立 / 重建「某一方」的基地与部队。
##
## 做四件事（顺序有讲究）：
##   1. 算这一方的出生点（大本营 + 将领站位 + 防御阵地）—— map.spawn_layout_for
##   2. 拆掉**这一方旧的**大本营（重建时会走这里，不能留下孤儿建筑，见 pitfalls 3.10）
##   3. 建新的大本营（+ 防御阵地），并把坐标记进 faction_bases
##   4. 建这一方的将领（多阵营时**追加**，不整体替换 —— 否则房主为 p2 建基地时
##      会把 p1 的部队全顶掉，变成「双方基地都在、但地图上只有一方的兵」）
func apply_faction_layout(faction: String, primary: String = "") -> void:
	if map == null:
		return
	var prim: String = primary if primary != "" else (factions[0] if factions.size() > 0 else faction)
	var layout: Dictionary = map.spawn_layout_for(faction, prim)
	var base_tile: Vector2i = layout["base"]
	faction_spawns[faction] = layout["spawns"]
	faction_bases[faction] = base_tile

	# 2) 清掉需要重建的旧大本营（force = true：大本营也要能清掉，这是内部重建）
	#
	# ⚠️⚠️「谁是孤儿」的判据必须是**owner 不在当前名单里**，不是「owner == DEFAULT_FACTION」。
	#    原来写的是后者，在 DEFAULT_FACTION 还是 'player' 时凑巧能用（单机那一座不在
	#    联机名单里）；改成 'p1' 之后，p1 既是默认阵营**又在名单里** ——
	#    于是轮到 p2 建基地时，把 p1 刚立好的基地当成孤儿删掉了
	#    （症状：p1 有 `faction_bases` 记录、却没有任何建筑，`find_base_of("p1")` 是 null）。
	var is_primary := (faction == prim)
	for b in building_list.duplicate():
		if b.type != BuildingRes.TYPE_BASE:
			continue
		var stale: bool = (b.owner == faction)
		if not is_primary and not factions.has(b.owner):
			# 单机阶段先按默认阵营建出来的那一座，被别的阵营接管后成了孤儿
			# （owner 已经不在名单里 → 谁都不该留着它）
			stale = true
		if stale:
			remove_building(b, true)

	# 3) 大本营 + 防御阵地（silent：不写日志、不逐个重算区块归属）
	add_building(BuildingRes.TYPE_BASE, base_tile.x, base_tile.y, faction, true)
	for d in (layout["defenses"] as Array):
		add_building(String(d["type"]), int(d["x"]), int(d["y"]), faction, true)
	building_revision += 1

	# 4) 将领（多阵营时追加本阵营的，保留其他阵营的）
	var fresh: Array = create_generals(faction)
	if factions.size() > 1:
		var kept: Array = []
		for u in units:
			if u.faction != faction:
				kept.append(u)
		units = kept
	for u in fresh:
		units.append(u)


## 建立某一阵营的将领。站位取该阵营自己的出生点，退回地图默认站位，最后退回大本营。
##
## 每个将领还会带上若干**亲兵**（附属单位）—— 见 create_retinue()。
## ⚠️ 顺序有讲究：**将领先全部入列，亲兵跟在后面**。
##    这样 world.units 里前几个永远是将领（快捷键 1/2/3 与按序号取将领的代码都靠它），
##    亲兵的 id 也统一是 `general-1-1`（队长 1 的第 1 个兵）这种可读格式。
func create_generals(faction: String) -> Array:
	var names = ["将领 1", "将领 2", "将领 3"]
	var spawns: Array = faction_spawns.get(faction, [])
	var out: Array = []
	var prefix = "general" if faction == FactionRes.DEFAULT_FACTION else "general-%s" % faction
	var leaders: Array = []
	for i in names.size():
		var tile: Vector2i = map.base
		if i < spawns.size():
			tile = spawns[i]
		elif i < map.general_spawns.size():
			tile = map.general_spawns[i]
		var g = UnitRes.create(cfg, "%s-%d" % [prefix, i + 1], names[i], tile, faction, UnitRes.KIND_GENERAL, str(i + 1))
		out.append(g)
		leaders.append(g)
	# 将领全部就位之后，再给每个将领配亲兵
	for g in leaders:
		for s in create_retinue(faction, g):
			out.append(s)
	return out


## 建立某个将领辖下的亲兵。站位围着将领一圈（就近找可通行的空地）。
##
## ⚠️ 必须**在将领落位之后**调用：亲兵要贴着将领站，将领不在场就没有参照物。
func create_retinue(faction: String, leader) -> Array:
	var out: Array = []
	var count: int = int(cfg.num("unit.subordinate.count", 0.0))
	if count <= 0:
		return out
	var name: String = cfg.unit_name_of(UnitRes.KIND_SUBORDINATE)
	for i in count:
		out.append(UnitRes.create(
			cfg, "%s-%d" % [leader.id, i + 1], "%s %d" % [name, i + 1],
			_ring_tile(leader, faction, i), faction,
			UnitRes.KIND_SUBORDINATE, "", leader.id
		))
	return out


## 围着某个队长找一格能站的位置：右、下、左、上、右下…（第 index 个方向）。
##
## ★ 出生与招募**共用这一份**：站位规则只有一处，免得两边慢慢漂开。
##   先用正交方向是有意的 —— 正交邻格比斜角更不容易被墙 / 山挤掉。
func _ring_tile(leader, faction: String, index: int) -> Vector2i:
	var ring: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
		Vector2i(2, 0), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(0, -2),
	]
	var off: Vector2i = ring[index % ring.size()]
	var want := Vector2i(leader.tx + off.x, leader.ty + off.y)
	if PathfinderRes.passable(map, buildings, cfg, want.x, want.y, faction):
		return want
	var found = PathfinderRes.nearest_reachable(map, buildings, cfg, Vector2i(leader.tx, leader.ty), want, faction, 8)
	if found != null:
		return found
	return Vector2i(leader.tx, leader.ty)      # 实在没地方就叠在队长身上，靠碰撞分开


# ------------------------------------------------------------------
# 招募（UI 改版新增：单位页的命令卡 → recruit 命令 → 这里）
# ------------------------------------------------------------------

## 可招募兵种表（config.json 的 recruit.list）。
## ★ 表在数据里、代码里不写死兵种名 —— 以后加兵种只加 JSON，不改这里。
func recruit_list() -> Array:
	var v: Variant = cfg.get_path_value("recruit.list")
	if typeof(v) != TYPE_ARRAY:
		return []
	return v


## 某个兵种能不能招募
func is_recruitable(kind: String) -> bool:
	for item in recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return true
	return false


## 某个兵种的招募消耗（走 economy，enabled = false 时形同免费，与建筑一样）
func recruit_cost(kind: String) -> Dictionary:
	for item in recruit_list():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if String(d.get("kind", "")) != kind:
			continue
		var c: Variant = d.get("cost", {})
		if typeof(c) == TYPE_DICTIONARY:
			return c
	return {}


## 招募校验。@return "" = 可以招；否则返回拒因（"kind" / "leader" / "faction"）。
##
## ★ 先校验、再扣钱、最后才生成 —— 顺序反了会出现「钱扣了、兵没出来」。
func can_recruit(kind: String, leader_id: String, faction: String) -> String:
	if not is_recruitable(kind):
		return "kind"
	var leader = unit_by_id(leader_id)
	if leader == null or not leader.alive:
		return "leader"
	if not is_team_leader(leader):
		return "leader"
	if not FactionRes.same_side(leader.faction, faction):
		return "faction"
	return ""


## 把新兵招到某个**在场将领**名下。
##
## 为什么放在 world 而不是 view：
##   · 站位要在权威侧算（第 1 轮联机时客机不能自己挑格子），
##   · 「挨着队长、不能卡在墙里」这套规则与出生时完全一样 —— 直接复用 _ring_tile()。
##
## @param kind 兵种（必须出现在 recruit.list 里）
## @param leader_id 队长的 id（命令里只带 id，**不传对象引用** —— 命令必须可序列化）
## @return 新单位；校验不过返回 null（并留下一条 recruit_rejected 事件说明原因）
func recruit_unit(kind: String, leader_id: String, faction: String) -> Variant:
	var reason := can_recruit(kind, leader_id, faction)
	if reason != "":
		push_event({"type": "recruit_rejected", "reason": reason, "kind": kind})
		return null
	var leader = unit_by_id(leader_id)
	_recruit_serial += 1
	var index: int = retinue_of(leader.id, false).size()
	var u = UnitRes.create(
		cfg, "%s-r%d" % [leader.id, _recruit_serial],
		"%s %d" % [cfg.unit_name_of(kind), index + 1],
		_ring_tile(leader, leader.faction, index), leader.faction, kind, "", leader.id
	)
	units.append(u)
	push_event({"type": "unit_recruited", "unit": u, "leader": leader})
	return u


## 刷一个测试敌人（调试用）。
## ★ id 必须在权威侧生成：HTML 版的客机用自己的随机数算 id，会导致快照对齐时单位错位/闪烁。
##   第 1 轮联机时，客机要请房主代为生成 —— 这里把「权威生成 id」这件事先固定下来。
func spawn_enemy(tx: int = -1, ty: int = -1) -> Variant:
	if map == null:
		return null
	var spawn = Vector2i(map.cols - 1, 3)      # 默认从地图右侧（北侧隘口附近）出现
	if tx >= 0 and ty >= 0:
		spawn = Vector2i(tx, ty)
	var open = spawn
	if not PathfinderRes.passable(map, buildings, cfg, spawn.x, spawn.y, FactionRes.NPC_FACTION):
		var found = PathfinderRes.nearest_reachable(map, buildings, cfg, spawn, spawn, FactionRes.NPC_FACTION, 20)
		if found == null:
			push_event({"type": "spawn_failed", "tile": spawn})
			return null
		open = found
	_enemy_serial += 1
	var e = UnitRes.create(cfg, "enemy-%d" % _enemy_serial, "测试敌人", open, FactionRes.NPC_FACTION, UnitRes.KIND_ENEMY)
	units.append(e)
	push_event({"type": "enemy_spawned", "unit": e})
	return e


# ------------------------------------------------------------------
# 建筑
# ------------------------------------------------------------------

## 在某格放一个建筑。**每个地块最多一个**。
## silent = true 时不写日志、不重算区块归属（批量布置出生点时用）。
func add_building(type: String, tx: int, ty: int, owner: String, silent: bool = false) -> Variant:
	if not map.terrain.has(tx, ty):
		return null
	if buildings.get_cell(tx, ty) != null:
		return null
	var z = zones.zone_at(tx, ty)
	var zone_id: int = int(z["id"]) if z != null else -1
	var b = BuildingRes.create(cfg, type, tx, ty, owner, zone_id)
	buildings.set_cell(tx, ty, b)
	_building_at[Vector2i(tx, ty)] = b
	building_list.append(b)
	building_revision += 1
	if not silent:
		refresh_ownership()
		push_event({"type": "building_built", "building": b})
	return b


## 某格上的建筑（没有则 null）
func building_at(tx: int, ty: int) -> Variant:
	return _building_at.get(Vector2i(tx, ty), null)


## 重新建立格子 → 建筑的查询表（拆除 / 整表替换后调用）
func rebuild_building_index() -> void:
	_building_at = {}
	buildings = GridRes.new(map.cols, map.rows, null)
	for b in building_list:
		if b.alive:
			buildings.set_cell(b.tx, b.ty, b)
			_building_at[Vector2i(b.tx, b.ty)] = b


## 把建筑从地图上摘掉（战斗摧毁、玩家拆除都走这里）。
##
## @param force 是否允许移除**大本营**。
##   false（默认）→ 大本营不可拆：这是「玩家不能拆自家大本营」的规则，
##                  也是对战里「大本营只能被打掉、不能被拆除」的保证。
##   true          → 内部重建 / 战斗摧毁专用。
##                   ⚠️ 战斗摧毁必须传 true，否则会出现「基地被打到 0 血、胜负已判，
##                      但它还站在地图上」的坏状态（见 docs/pitfalls.md 3.9）。
##
## ⚠️ 这里**不检查 b.alive**：take_damage 在血量归零时就已经把它标成 not alive 了，
##    「收尸」要摘掉的正是这种已经死掉的建筑。第一版在开头写了
##    `if not b.alive: return false`，于是被打死的城墙永远留在建筑表与格子网格里
##    （那一格永远不可通行、敌人就卡在墙前，而且死建筑还会一直被收尸逻辑反复扫到）。
func remove_building(b, force: bool = false) -> bool:
	if b == null:
		return false
	if b.type == BuildingRes.TYPE_BASE and not force:
		return false
	b.alive = false
	buildings.set_cell(b.tx, b.ty, null)
	_building_at.erase(Vector2i(b.tx, b.ty))
	var i: int = building_list.find(b)
	if i >= 0:
		building_list.remove_at(i)
	building_revision += 1
	return true


## 该地块能不能建造
func can_build_at(tx: int, ty: int) -> bool:
	if not map.terrain.has(tx, ty):
		return false
	if not map.terrain_walkable(tx, ty):
		return false
	if PathfinderRes.occupied(buildings, tx, ty):
		return false
	return true


## 建筑归属变了就重算区块归属（不每帧算）
func refresh_ownership() -> void:
	if building_revision == last_ownership_revision:
		return
	last_ownership_revision = building_revision
	zones.refresh_building_ownership(cfg, building_list, factions)


# ------------------------------------------------------------------
# 每帧推进
# ------------------------------------------------------------------

## 推进一帧**权威逻辑**。
##
## ⚠️ 第 1 轮联机时，只有房主该调它：客机的 update 必须被冻结，
##    否则两份状态各自漂移，几秒后就会出现「我看到的位置和实际位置不一样」。
##
## ★ 事件在**末尾**收口（见函数最后一段）：两次 tick 之间由命令产生的事件
##   （建造 / 拆除 / 招募 / 刷敌人）必须跟着下一次 tick 一起交出去。
##   以前是在开头 `_events = []`，于是命令事件在送到 HUD 之前就被丢掉了 ——
##   症状是「建好了没有日志、招募了没有提示」，而逻辑本身是对的，很难查。
func tick(dt: float) -> Array:
	if dt <= 0.0:
		return _events
	time += dt

	# 1) 区块占领（占位规则）
	zones.update(cfg, dt, units, factions)

	# 2) 建筑归属变化时才重算
	refresh_ownership()

	# 3) 资源：按己方占领地块数实时增长（「己方」= my_faction，不是写死的 'player'）
	var tiles = zones.owned_tile_count(my_faction)
	if tiles != owned_tiles:
		owned_tiles = tiles
		push_event({"type": "territory_changed", "tiles": tiles, "zones": zones.owned_zone_names(my_faction)})
	EconomyRes.tick(cfg, dt, tiles, resources)

	# 4) 单位：移动 + 战斗 / 警戒
	for u in units:
		if not u.alive:
			# 阵亡中的单位只跑复活倒计时；复活后本帧就正常参与逻辑
			u.tick_respawn(cfg, self, dt)
			continue
		CombatRes.update_unit(self, cfg, u, dt)
		# 站定后被推离落点就自己走回去（必须在 step 之前：先决定要不要回位）
		u.reclaim_settled_spot(self, cfg)
		if not u.path.is_empty():
			u.step_along_path(self, cfg, dt)

	# 4.5) 清理离场单位。
	#      ⚠️ 这里**不能**简单地按 alive 过滤：对战模式下阵亡的单位要留在列表里等复活，
	#         一旦被过滤掉就永远活不过来了（见 docs/pitfalls.md 3.8 的姊妹问题）。
	var keep: Array = []
	for u in units:
		if u.alive or u.awaiting_respawn():
			keep.append(u)
	units = keep

	# 5) 箭塔开火 + 建筑受击闪光衰减
	CombatRes.update_towers(self, cfg, dt)
	CombatRes.update_building_effects(self, dt)

	# 6) 调试：自动刷敌人
	if debug_auto_spawn:
		enemy_spawn_timer -= dt
		if enemy_spawn_timer <= 0.0:
			spawn_enemy()
			enemy_spawn_timer = cfg.num("debug.spawn_interval_sec", 3.0)

	# 7) 敌人 AI（朝玩家据点推进；被城墙挡住时锁定城墙来拆）
	EnemyAiRes.update(self, cfg)

	# 8) 收尸：被打光的建筑从地图上摘掉。
	#    放在末尾做，是为了让「本帧已经发生的战斗」都读到同一个世界快照。
	_collect_destroyed_buildings()

	# 8.5) ★ 单位碰撞与局部避让（软分离 + 谁给谁让路）
	#
	# 为什么放在最后：它是**收尾修正**，要在所有移动与战斗都算完之后再摆位置，
	# 否则本帧的移动会把刚摆好的位置又撞开。逻辑层的 `path / moving / goal` 全不动 ——
	# 推挤只改「位置」，不改「意图」。
	#
	# ⚠️ 联机（第 1 轮）：位置是权威状态，所以这一步只能跑在房主侧。
	CollisionRes.resolve(self, cfg)
	# 8.6) ★ 建筑本体的硬碰撞：大本营 / 箭塔不再整格挡人之后，
	#      「本体挡敌方」这条规则就落在这里（己方单位不受影响）。
	CollisionRes.resolve_buildings(self, cfg)

	# 9) 胜负判定（大本营被打掉 / 超时比血量）
	check_victory(dt)

	# 10) 事件收口：本帧的事件 + **两次 tick 之间由命令产生的事件**（建造 / 拆除 / 招募…）
	#     一起交出去，然后清空。
	#
	# ⚠️ 清空只能放在这里（末尾），不能放在开头：命令是输入事件触发的，它在两帧之间跑，
	#    开头清空就等于把它们在送到 HUD 之前丢掉 —— 表现是「建好了却没日志」。
	var out := _events
	_events = []
	return out


## 把本帧被打光的建筑摘掉（战斗摧毁必须 force = true，见 remove_building 的注释）
##
## 放在 tick() 末尾做，是为了让「本帧已经发生的战斗」都读到同一个世界快照。
## 判据用 `alive == false` 而不是 `hp <= 0`：take_damage 在血量归零时就已经
## 把它标成 not alive 了，hp 只是给渲染看血条用的。
func _collect_destroyed_buildings() -> void:
	var removed := false
	for b in building_list.duplicate():
		if b.alive:
			continue
		remove_building(b, true)
		removed = true
	if removed:
		refresh_ownership()
	# 防御性兜底：单位手里还攥着一栋已经不在场的建筑时，让它松手，
	# 否则它会一直朝一个空气格「拆」下去（表现为站着不动）。
	# ⚠️ 用 drop_engagement() 而不是只把 target_building 置空：玩家点名的那个建筑
	#    也要跟着清掉，不然 ui 上会一直显示「指定拆除：某某」而它早没了。
	for u in units:
		if u.target_building != null and not u.target_building.alive:
			if u.ordered_building == u.target_building:
				u.ordered_building = null
			u.drop_engagement()


# ------------------------------------------------------------------
# 胜负（对战用；单机永远不判 —— 大本营本来就打不掉）
# ------------------------------------------------------------------

func check_victory(_dt: float) -> void:
	if not pvp_enabled:
		return
	var present = spawned_factions()
	var alive_list: Array[String] = []
	for f in present:
		if find_base_of(f) != null:
			alive_list.append(f)
	if present.size() >= 2 and alive_list.size() <= 1:
		push_event({"type": "match_over", "winner": alive_list[0] if alive_list.size() > 0 else ""})


## 某阵营当前的大本营建筑（没有则 null）
func find_base_of(faction: String) -> Variant:
	for b in building_list:
		if b.alive and b.type == BuildingRes.TYPE_BASE and b.owner == faction:
			return b
	return null


## **在场**的玩家阵营 = 已经为它建出基地的那些。
##
## ★ 分母必须是「在场的阵营」，不是「名单里的席位」：
##   HTML 版线上事故——名单有 8 个席位但只有房主进了房间，用名单当分母会得出
##   「8 个玩家只剩 1 个活着」，于是第 0 帧就判 P1 获胜，一打开页面就显示"P1 赢了"。
##   见 docs/pitfalls.md 与 porting.md 的搬运清单。
func spawned_factions() -> Array[String]:
	var out: Array[String] = []
	for f in factions:
		if faction_bases.has(f):
			out.append(f)
	return out


## 某阵营的大本营坐标（复活点 / 敌人 AI 目标都从这里取）
func home_base_of(faction: String) -> Vector2i:
	if faction_bases.has(faction):
		return faction_bases[faction]
	if faction_bases.has(my_faction):
		return faction_bases[my_faction]
	return map.base


# ------------------------------------------------------------------
# 事件（逻辑 → 表现的唯一通道）
# ------------------------------------------------------------------

## 记录本帧发生的一件事。view/ 每帧取走并显示（逻辑层不认识 UI）
func push_event(evt: Dictionary) -> void:
	_events.append(evt)


## 按 id 找单位
func unit_by_id(id: String) -> Variant:
	for u in units:
		if u.id == id:
			return u
	return null


## 某一方还活着的单位
func alive_units_of(faction: String) -> Array:
	var out: Array = []
	for u in units:
		if u.alive and u.faction == faction:
			out.append(u)
	return out


# ------------------------------------------------------------------
# 队伍（队长 + 亲兵）
#
# ★ 这里没有 Squad 类，也没有队伍表 —— 队伍是**算出来的**：
#     队长 = 没有 leader_id 的那个单位；队员 = leader_id 指向队长的那些单位。
#   好处是单位死了不需要通知谁、队长换了也不需要维护映射；
#   坏处是每次都要遍历一遍 units —— 单位只有几十个，代价可以忽略。
# ------------------------------------------------------------------

## 某个单位的队长 id：自己就是队长时返回自己的 id。
## 队长已经不在场时仍然返回它记录的 leader_id（调用方用 team_leader() 判在场）。
func leader_of(u) -> String:
	if u == null:
		return ""
	if u.leader_id != "":
		return u.leader_id
	return u.id


## 某个单位的队长单位（自己就是队长 / 队长已阵亡时返回 null）
func team_leader(u) -> Variant:
	if u == null or u.leader_id == "":
		return null
	var leader = unit_by_id(u.leader_id)
	if leader == null or not leader.alive:
		return null
	return leader


## ★ 把「选中一个单位」展开成整队：队长 + 它辖下所有还活着的亲兵。
##
## 规则（手玩定的）：
##   · 点队伍里**任何一个** → 整队一起被选中（亲兵有队长时先补上队长，再把队长的队员都带上）
##   · 队长已经阵亡 → 剩下的亲兵各算各的（只选中自己），不会凭空造出一个队长
##   · 不属于任何队伍的单位（测试敌人）→ 只选中自己
##
## @return Array 单位数组（去重，队长排在第一个）
func group_of(u) -> Array:
	if u == null:
		return []
	# 先找到队长（自己就是队长的话就是自己）
	var leader = u
	var maybe = team_leader(u)
	if maybe != null:
		leader = maybe
	var out: Array = []
	if leader.alive:
		out.append(leader)
	for other in units:
		if other == leader:
			continue
		if not other.alive:
			continue
		if other.leader_id != "" and other.leader_id == leader.id:
			out.append(other)
	return out


## 把一个选中列表按队伍展开并去重（顺序保持稳定：先来的队伍在前）
func expand_to_groups(selected: Array) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for u in selected:
		for member in group_of(u):
			if seen.has(member.id):
				continue
			seen[member.id] = true
			out.append(member)
	return out


## 某个单位是不是队长（自己不带 leader_id）
func is_team_leader(u) -> bool:
	return u != null and u.leader_id == ""


## 某个队长辖下的亲兵。
##
## @param alive_only true（默认）= 只要还活着的（正常玩法用）；
##        false = 连阵亡但还没被清掉的也算上 —— **查「原来跟着谁」时必须传 false**。
##   ⚠️ 这两个语义容易混：队长刚阵亡时，`retinue_of(id)` 仍然是**非空**的
##      （亲兵还活着），只是它们的队长查不到了（team_leader 返回 null）。
func retinue_of(leader_id: String, alive_only: bool = true) -> Array:
	var out: Array = []
	for u in units:
		if u.leader_id != leader_id:
			continue
		if alive_only and not u.alive:
			continue
		out.append(u)
	return out


## 资源文本（HUD 用；保留一位小数）
func resource_text() -> String:
	return "粮食 %.1f　黄金 %.1f" % [float(resources["food"]), float(resources["gold"])]


## 每帧是否要重画（占区块进度、受击闪光这类都靠每帧重绘体现）
func needs_continuous_redraw() -> bool:
	return true
