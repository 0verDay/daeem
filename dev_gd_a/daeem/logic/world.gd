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
const CrowdBridgeRes = preload("res://logic/crowd/crowd_bridge.gd")

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

## ★ 碰撞后端：C# 群体内核（空间哈希 + 批量接口）的 GDScript 桥。
## 内核加载不到（普通版 Godot / 还没构建）时它会自动退回 logic/collision.gd。
## 见 logic/crowd/crowd_bridge.gd 与 data/config.json 的 unit.collision_backend。
var crowd = null

## 阵营
var my_faction: String = FactionRes.DEFAULT_FACTION
var factions: Array[String] = []
var enemy_faction: String = FactionRes.NPC_FACTION

## 经济
var resources: Dictionary = {"food": 0.0, "gold": 0.0}
var owned_tiles: int = 0
## ★ 当前每秒产出（按占领的区划产能聚合出来；HUD 用来显示「+n/秒」）。
## 每帧在 tick() 里刷新 —— 纯展示用，不参与任何判定。
var production_food: float = 0.0
var production_gold: float = 0.0

## 每个阵营的大本营坐标与将领出生点（复活点、敌人 AI 目标都从这里取）
var faction_bases: Dictionary = {}
var faction_spawns: Dictionary = {}

var time: float = 0.0
## 帧序号：每 tick +1。给「每帧预算一次、当帧有效」的缓存做对齐用
## （例如 crowd_bridge 的警戒索敌结果 —— 在 tick 之外读到上一帧的结果就是 bug）。
var frame_serial: int = 0
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


static func create(p_cfg: ConfigRes, map_path: String = "res://data/test_map.json") -> RefCounted:
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
	production_food = 0.0
	production_gold = 0.0

	buildings = GridRes.new(map.cols, map.rows, null)

	# 碰撞后端（C# 群体内核）。表是懒建的：第一次 tick 时按当前建筑状态编一次。
	crowd = CrowdBridgeRes.new()
	if crowd != null:
		# ⚠️ 弱引用：强引用会形成 world ↔ crowd 的引用循环，两边都永远不释放
		crowd.set_world(self)
		crowd.reset_cache()

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
	# 地图上**预置**的建筑（对家据点这类固定摆设，坐标写在 test_map.json 的 "buildings" 里）。
	# 放在各阵营出生点之后：它们的坐标是手写的，不与出生点抢格；被占住的格子 add_building 会自己拒。
	for p in map.prefab_buildings:
		add_building(String(p["type"]), int(p["x"]), int(p["y"]), String(p["owner"]), true)
	# ★★ 区划中心（地图编辑器给每个区块指定的那一格）：**中立障碍建筑**。
	#    ⚠️⚠️ 必须在**任何单位出生之前**建好（顺序踩过一次，实测）：
	#       单位出生找站位时会避开建筑（`_ring_tile` 里那条 `building_at() != null`），
	#       而中心是在 reset 末尾才建的 —— 于是「先出生的亲兵」正好站在中心那一格上，
	#       开局就有一个兵被卡在不可进入的建筑里（`test_retinue` 抓住的）。
	#    `add_building` 对已占格会拒绝，所以「中心最优先」是这样落地的：
	#      · 中心的格子是**编辑器的硬规则**（导出前 blockers 拦住与大本营叠格的那些）；
	#      · 真出现叠格（手改地图），这里会静默建不出来 —— 但绝不会把已有建筑顶掉。
	_spawn_zone_centers()
	# 地图上**预置**的单位（测试用的守军，写在 test_map.json 的 "units" 里）。
	# id 走 _enemy_serial —— 与调试刷兵同一套序号，永远不会撞名。
	# ⚠️ 顺序：**先建各方的将领与亲兵，再放预置单位**。
	#    `world.units` 的前几个永远是这一方的将领（快捷键 1/2/3 与按序号取将领
	#    的代码都靠这条契约），预置单位插在前面会把它顶掉。
	for f in factions:
		spawn_faction_units(f)
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


## 把地图里每个区块的「区划中心」落成一栋中立障碍建筑（无血量 / 无敌 / 无攻击）。
##
## ★ owner 是**空字符串**：`same_side(任何人, "")` 恒为 false，于是它
##   对谁都阻挡、也不会被索敌 / 被箭塔锁定 / 被拆 —— 见 building.gd 的 TYPE_ZONE_CENTER。
## ★ 建不出来的那一种情况会**报警**：那一格已经被别的建筑占了（大本营 / 预置建筑）。
##   编辑器的导出校验会拦住「中心与大本营叠格」，所以正常流程里见不到这条
##   —— 见到它就意味着地图是手改过的，或是编辑器校验有漏（留一条痕迹，别静默）。
func _spawn_zone_centers() -> void:
	if zones == null:
		return
	for z in zones.zones:
		var c: Variant = z["center"]
		if c == null:
			continue
		var t: Vector2i = c
		if add_building(BuildingRes.TYPE_ZONE_CENTER, t.x, t.y, "", true) == null:
			push_warning("区划「%s」的中心 (%d, %d) 建不出来：那一格已经被别的建筑占了"
				% [String(z["name"]), t.x, t.y])


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
	#
	# ⚠️ 这里**只清理**旧单位，单位的**出生**由 `spawn_faction_units()` 在
	#    「所有建筑（含区划中心）都建好之后」统一做 —— 站位要避开建筑，
	#    而这个函数在 reset() 里跑得比预置建筑 / 区划中心早。
	if factions.size() > 1:
		var kept: Array = []
		for u in units:
			if u.faction != faction:
				kept.append(u)
		units = kept


## 给某一方建出将领 + 亲兵（站位避开建筑与已有单位）。
##
## ★ 必须**在所有建筑都就位之后**调用（见 reset() 的顺序说明）：
##   亲兵的站位规则会跳过「那一格上立着建筑」—— 区划中心要是还没建，
##   亲兵就会挑到中心那一格上，开局直接卡在不可进入的建筑里。
func spawn_faction_units(faction: String) -> void:
	for u in create_generals(faction):
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
	# 将领全部就位之后，再给每个将领配亲兵。
	# ⚠️ `out` 是**本批**的单位（还没进 world.units）—— 传给 create_retinue 用来避让，
	#    否则同一批里的亲兵会互相看不见、两个人都挑到同一格。
	for g in leaders:
		for s in create_retinue(faction, g, out):
			out.append(s)
	return out


## 建立某个将领辖下的亲兵。站位围着将领一圈（就近找可通行的空地）。
##
## ⚠️ 必须**在将领落位之后**调用：亲兵要贴着将领站，将领不在场就没有参照物。
## @param pending 本批已创建、还没入列的单位（用来避开站位撞车）
func create_retinue(faction: String, leader, pending: Array = []) -> Array:
	var out: Array = []
	var count: int = int(cfg.num("unit.subordinate.count", 0.0))
	if count <= 0:
		return out
	var name: String = cfg.unit_name_of(UnitRes.KIND_SUBORDINATE)
	for i in count:
		out.append(UnitRes.create(
			cfg, "%s-%d" % [leader.id, i + 1], "%s %d" % [name, i + 1],
			_ring_tile(leader, faction, i, pending + out), faction,
			UnitRes.KIND_SUBORDINATE, "", leader.id
		))
	return out


## 围着某个队长找一格能站的位置：右、下、左、上、右下…（第 index 个方向）。
##
## ★ 出生与招募**共用这一份**：站位规则只有一处，免得两边慢慢漂开。
##   先用正交方向是有意的 —— 正交邻格比斜角更不容易被墙 / 山挤掉。
##
## ★★ 除了「地形 / 建筑放行」，还必须**避开已经站着人的格子**（同阵营也算）。
##    这一条是加区划中心之后暴露出来的（实测）：
##    3 个将领各带 3 个亲兵、全挤在大本营周围那一圈时，`index` 撞车的两个亲兵
##    （general-2-3 与 general-3-1）都会落到「大本营那一格」上 ——
##    因为原来的判定只看地形与建筑，而大本营格对己方是放行的。
##    症状是「开局有两个兵叠在同一个格子上」（测试里那条「所有单位都不能站在大本营格上」
##    就是为此写的）。
##    ⚠️ 还要看 `pending`：同一批正在创建、**还没进 world.units** 的单位
##       （create_generals 是先在局部数组里攒好、最后才一次性入列的）。
##
## @param pending 本批已占位的单位（可以不传）
func _ring_tile(leader, faction: String, index: int, pending: Array = []) -> Vector2i:
	var ring: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
		Vector2i(2, 0), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(0, -2),
	]
	# 从「第 index 个方向」开始绕一圈：优先那个方向（站位可预测），
	# 被占了 / 走不通就顺延 —— 比「直接落到队长身上叠着」好得多。
	for k in ring.size():
		var off: Vector2i = ring[(index + k) % ring.size()]
		var want := Vector2i(leader.tx + off.x, leader.ty + off.y)
		if not PathfinderRes.passable(map, buildings, cfg, want.x, want.y, faction):
			continue
		if _tile_taken(want, leader, pending):
			continue
		if building_at(want.x, want.y) != null:
			continue        # 那一格上立着建筑（大本营 / 箭塔 / 城墙 / 区划中心）→ 换一格
		return want
	var off0: Vector2i = ring[index % ring.size()]
	var found = PathfinderRes.nearest_reachable(
		map, buildings, cfg, Vector2i(leader.tx, leader.ty),
		Vector2i(leader.tx + off0.x, leader.ty + off0.y), faction, 8, crowd)
	if found != null:
		return found
	return Vector2i(leader.tx, leader.ty)      # 实在没地方就叠在队长身上，靠碰撞分开


## 这一格是不是已经被某个**活着的单位**占着（`except_unit` 不算 —— 兜底就是要叠在它身上）。
## `pending` 是同一批正在创建、还没进 `units` 的那些。
func _tile_taken(tile: Vector2i, except_unit, pending: Array = []) -> bool:
	for u in units:
		if u == except_unit or not u.alive:
			continue
		if u.tx == tile.x and u.ty == tile.y:
			return true
	for u in pending:
		if u == except_unit or not u.alive:
			continue
		if u.tx == tile.x and u.ty == tile.y:
			return true
	return false


# ------------------------------------------------------------------
# 招募（将领自己就是兵营：入队 → 读条 → 在将领所在格**中心**生成）
#
# 需求原话：「每个单位消耗 50 粮食 50 黄金，同时消耗招募将领的单位所在地的 1 人口，
#            招募时间为 10 秒；表现类似星际争霸：信息栏里五个格子（一个大的 +
#            四个小的，代表最多五个单位进入招募队列，正在招募的在大格子里），
#            读条完毕后在将领所在格内生成该单位（强制生成在中心，若中心有单位
#            则将中心内的单位排开）；将领只能在己方区划内招募单位；
#            开始招募后将领固定在原地无法行动且无法攻击。」
#
# ★ 这一整套都在**权威侧**算：命令里只有兵种与队长 id（可序列化），
#   站位 / 扣费 / 退款全在这里 —— 第 1 轮联机时客机不挑格子、也不算钱。
# ------------------------------------------------------------------

## 可招募兵种表（config.json 的 recruit.list）。
## ★ 表在数据里、代码里不写死兵种名 —— 以后加兵种只加 JSON，不改这里。
func recruit_list() -> Array:
	var v: Variant = cfg.get_path_value("recruit.list")
	if typeof(v) != TYPE_ARRAY:
		return []
	return v


## 某个兵种在招募表里的条目（找不到返回空字典）
func recruit_entry(kind: String) -> Dictionary:
	for item in recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return item
	return {}


## 某个兵种能不能招募
func is_recruitable(kind: String) -> bool:
	return not recruit_entry(kind).is_empty()


## 某个兵种的招募消耗。
## ⚠️ 招募是**无条件**扣费（不看 economy.enabled 那个总开关，它只管建造免费）——
##    需求要的是「每个单位消耗 50 粮食 50 黄金」，被总开关静默变成免费就没意义了。
func recruit_cost(kind: String) -> Dictionary:
	var c: Variant = recruit_entry(kind).get("cost", {})
	if typeof(c) == TYPE_DICTIONARY:
		return c
	return {}


## 每个单位的读条时间（秒）
func recruit_train_sec(kind: String) -> float:
	return maxf(0.0, float(recruit_entry(kind).get("train_sec", 0.0)))


## 每个单位要占的人口（从**将领所在区划**扣）
func recruit_population_cost(kind: String) -> float:
	return maxf(0.0, float(recruit_entry(kind).get("population_cost", 0.0)))


## 队列上限（**含**正在读条的那个）：config.recruit.queue_max，默认 5
func recruit_queue_max() -> int:
	return maxi(1, int(cfg.num("recruit.queue_max", 5.0)))


## 信息栏格子里显示的短名（config 的 short；没配就退回 label 的第一个字）
func recruit_short_of(kind: String) -> String:
	var e := recruit_entry(kind)
	var s := String(e.get("short", ""))
	if s != "":
		return s
	var label := String(e.get("label", kind))
	return label.substr(0, 1) if label.length() > 0 else "?"


## 某个兵种的显示名（提示文案用）
func recruit_label_of(kind: String) -> String:
	var e := recruit_entry(kind)
	var label := String(e.get("label", ""))
	return label if label != "" else kind


## 招募校验（**规则**层面）。@return "" = 可以招；否则返回拒因：
##   "kind"       不在可招募表里
##   "leader"     队长不存在 / 已阵亡 / 根本不是队长
##   "faction"    防冒充：不能拿别人家的将领当招募对象
##   "zone"       ★ 将领不在**己方区划**里（本轮新增的限制条件）
##   "queue_full" ★ 队列满了（最多 recruit.queue_max 个，含正在读条的那个）
func can_recruit(kind: String, leader_id: String, faction: String) -> String:
	if not is_recruitable(kind):
		return "kind"
	var leader = unit_by_id(leader_id)
	var reason := leader_reject_reason(leader, faction)
	if reason != "":
		return reason
	if not leader_zone_owned(leader):
		return "zone"
	if leader.train_queue_size() >= recruit_queue_max():
		return "queue_full"
	return ""


## 「这个单位能不能当招募对象」的公共校验（招募 / 取消招募共用）。
## @return "" / "leader" / "faction"
##
## ★ 取消招募**不走** `can_recruit`：那边还管区划与队列上限，而取消是「把已经
##   排上的撤掉」——区划被敌人打回去了也得让人取消，不该被 zone 拦住。
func leader_reject_reason(leader, faction: String) -> String:
	if leader == null or not leader.alive:
		return "leader"
	if not is_team_leader(leader):
		return "leader"
	if not FactionRes.same_side(leader.faction, faction):
		return "faction"
	return ""


## 将领是不是站在**己方区划**里（区划归属 == 它那一方）。
## ★ 无主区划、以及不属于任何区划的格子（地图外沿的 -1）都不算 —— 见 route.md 第十四节。
func leader_zone_owned(leader) -> bool:
	var z = zones.zone_at(leader.tx, leader.ty)
	return z != null and FactionRes.same_side(String(z["owner"]), leader.faction)


## 这个单位现在**不接受玩家指令**吗？
##
## 需求原话：「玩家无法为正在招募单位的将领及其附属队列发布任何指令（移动/攻击），
##            其附属单位只会执行警戒逻辑」。
## 所以被锁住的是**一整队**：将领自己在招募 → 它被锁；它辖下的部队 → 也一起被锁
## （「附属队列」= 它名下那些亲兵）。
##
## ★ 判据只写这一处：命令层（`command_processor`）用它过滤，
##   输入层要用也只问它 —— 两处各写一套「谁被锁住了」迟早会漂开。
## ★ 队长已经不在场（阵亡）的亲兵**不算被锁**：它们已经各自为战了，
##   再拦着玩家就没有道理（`team_leader()` 对这种情况返回 null）。
func is_order_locked(u) -> bool:
	if u == null or not u.alive:
		return false
	if u.is_training():
		return true
	var leader = team_leader(u)
	return leader != null and leader.is_training()


## 钱与人口够不够。@return "" / "cost" / "population"
##
## ★ 与 can_recruit 分开：那边是「规则允不允许」，这边是「付不付得起」——
##   两种拒因给玩家的提示文案不一样（见 view/hud.gd 的 recruit_reject_text）。
func can_afford_recruit(kind: String, leader_id: String) -> String:
	if not EconomyRes.can_afford(resources, recruit_cost(kind)):
		return "cost"
	var pop := recruit_population_cost(kind)
	if pop <= 0.0:
		return ""
	var leader = unit_by_id(leader_id)
	if leader == null:
		return "leader"
	var z = zones.zone_at(leader.tx, leader.ty)
	if z == null or float(z.get("population", 0.0)) < pop:
		return "population"
	return ""


## 招募入队（`recruit` 命令的唯一落点）。
##
## ★★ 三步顺序不能反：**先校验 → 再扣费 → 最后入队**。
##    反了会出现「钱扣了、兵没排上队」这种查不出来的坏状态。
## ★ 扣费时机是**入队即扣**（与星际争霸一致）：否则「排队不要钱」会让玩家
##    先排满再等资源，队列上限就失去意义了。将领阵亡时按记账值退还（见 _release_recruit）。
##
## @return true = 已经入队（**不代表已经生成** —— 要读条 train_sec 秒）
func start_recruit(kind: String, leader_id: String, faction: String) -> bool:
	var reason := can_recruit(kind, leader_id, faction)
	if reason == "":
		reason = can_afford_recruit(kind, leader_id)
	if reason != "":
		push_event({"type": "recruit_rejected", "reason": reason, "kind": kind})
		return false

	var leader = unit_by_id(leader_id)
	var zone = zones.zone_at(leader.tx, leader.ty)
	var pop := recruit_population_cost(kind)
	var cost := recruit_cost(kind)

	# 1) 扣钱（无条件）。校验刚刚过过，这里再判一次返回值只是**保险** ——
	#    扣费失败就一定不能往下走（否则会出现「兵排上了、钱却没扣」）。
	if not EconomyRes.spend(resources, cost):
		push_event({"type": "recruit_rejected", "reason": "cost", "kind": kind})
		return false
	# 2) 扣人口（**同一个区划**：将领站在哪就从哪扣）
	if zone != null and pop > 0.0:
		zone["population"] = maxf(0.0, float(zone["population"]) - pop)
	# 3) 记账：将领阵亡时按这三个数退款（不看「当前队列还在不在」）
	leader.train_cost_food += float(cost.get("food", 0.0))
	leader.train_cost_gold += float(cost.get("gold", 0.0))
	leader.train_cost_pop += pop
	leader.train_zone_id = int(zone["id"]) if zone != null else -1
	# 4) 入队：大格子空着就直接开始读条，否则排到小格子里
	if leader.train_kind == "":
		_start_training(leader, kind)
	else:
		leader.train_queue.append(kind)
	# 5) ★ 读条期间**钉在原地**：先停手（清掉路径 + 玩家命令 + 交战），再记住这个位置。
	#    ⚠️ 顺序不能反：stop() 会清 settled_spot，之后 train_anchor 取的才是最终位置。
	leader.stop()
	leader.train_anchor = leader.pos
	# 6) ★ 它辖下的部队也一起**收队**：招募期间它们「只执行警戒逻辑」（用户需求），
	#    所以已经在跑的那条移动 / 攻击命令要就地取消 —— 不然会出现
	#    「将领立正读条、护卫却按旧命令一路走光」这种自相矛盾的画面。
	#    只有「这一单让队列从空变成非空」时才需要（后面几单只是排队）。
	if leader.train_queue_size() == 1:
		_stop_retinue(leader)
	push_event({"type": "recruit_queued", "leader": leader, "kind": kind})
	return true


## 让某个将领辖下的部队**收队**（清掉路径 / 玩家命令 / 交战）。
## 它们接下来只会跑警戒逻辑（自发索敌 → 靠近 → 开火 → 追太远就放弃）。
func _stop_retinue(leader) -> void:
	for r in retinue_of(leader.id):
		r.stop()


## 让某个兵种进「大格子」开始读条。
##
## ⚠️ 与 `_start_next_in_queue()` 分开写：那个是「从队列里提拔下一个」，
##    它的前提是队列非空；而**第一单**还没进过队列（kind 是刚排进来的）。
##    第一版把两者合并，于是第一单被 pop 出空队列直接吃掉 —— 入队返回 true、
##    队列却永远是空的（测试里 20 多条断言一起红）。
func _start_training(leader, kind: String) -> void:
	leader.train_kind = kind
	leader.train_total = recruit_train_sec(kind)
	leader.train_remaining = leader.train_total


## 把队列里的下一个提到「大格子」里开始读条（队列空 → 变回空闲）。
func _start_next_in_queue(leader) -> void:
	if leader.train_queue.is_empty():
		leader.train_kind = ""
		leader.train_remaining = 0.0
		leader.train_total = 0.0
		return
	_start_training(leader, leader.train_queue.pop_front())


## 每帧推进所有将领的招募读条（world.tick 第 3.5 步）。
##
## ⚠️ 必须在**清理离场单位之前**跑：单机不复活，阵亡的单位会在同一帧被摘出
##    world.units —— 那时再来退款就找不到它了（见 step 4.5 与 pitfalls 5.37）。
## ⚠️ 用**下标**遍历并先把长度取下来：读条完成会往 `units` 里 append 新兵，
##    边遍历边增长数组是自找麻烦（新兵没有队列，但没必要去赌迭代器的行为）。
func _tick_recruitment(dt: float) -> void:
	var n := units.size()
	for i in n:
		var u = units[i]
		if u.train_kind == "" and u.train_queue.is_empty():
			continue
		if not u.alive:
			_release_recruit(u, true, "leader_died")
			continue
		if u.train_kind == "":
			_start_next_in_queue(u)
			continue
		var budget := dt
		var guard := 0
		# ★ 一帧里可能读满好几个（dt 大 / train_sec 小）：把剩下的时间**接着往下算**，
		#   而不是整帧重来或丢掉 —— 否则时间轴会随帧率漂（`tests` 里用 dt = 1 秒跑）。
		while u.train_kind != "" and budget > 0.0 and guard < 64:
			guard += 1
			if u.train_remaining > budget:
				u.train_remaining -= budget
				budget = 0.0
				break
			budget -= u.train_remaining
			u.train_remaining = 0.0
			_spawn_from_recruit(u, u.train_kind)
			_start_next_in_queue(u)


## 读条完成：在**将领所在格的中心**生成这个兵种。
##
## ★ 「强制生成在中心」分两半：先把格心上的**别人**排开（collision.clear_point），
##   再把新兵放在格心上。将领自己不动 —— 它在招募期间是钉住的，所以新兵与它
##   叠在一起时由这一帧末尾的软分离把**新兵**挤开（见 _pin_training_leaders）。
func _spawn_from_recruit(leader, kind: String) -> Variant:
	var tile := Vector2i(leader.tx, leader.ty)
	var center := GridRes.center_of(tile)
	# 排开的距离：两个碰撞圆刚不重叠（与 collision 的最小圆心距同一套口径）
	var need: float = maxf(0.0, cfg.unit_collision_radius) * 2.0
	CollisionRes.clear_point(self, cfg, center, need, leader)

	_recruit_serial += 1
	var u = UnitRes.create(
		cfg, "%s-r%d" % [leader.id, _recruit_serial],
		"%s %d" % [cfg.unit_name_of(kind), retinue_of(leader.id, false).size() + 1],
		tile, leader.faction, kind, "", leader.id
	)
	# ★ 位置**显式**写一次格心：需求要的是「强制生成在中心」，
	#   不能依赖 UnitRes.create 的实现（哪天它改成别处落点就会静默跑偏）。
	u.pos = center
	u.sync_tile(map)
	units.append(u)
	push_event({"type": "unit_recruited", "unit": u, "leader": leader})
	return u


## 结束某个将领的招募（将领阵亡 / 被清场时调）。
##
## @param refund true = 把已经扣掉的粮食 / 黄金 / 人口**退回去**
##        （用户需求：将领阵亡时队列作废，但已扣的费用要退）。
##        退款按记账的累加值走，不看「当前队列里还剩几个」—— 两者在
##        「读条刚完成、下一单还没开始」的那一帧会不一致。
func _release_recruit(leader, refund: bool, reason: String = "") -> void:
	if not leader.is_training() and leader.train_cost_food <= 0.0 \
			and leader.train_cost_gold <= 0.0 and leader.train_cost_pop <= 0.0:
		return
	var food: float = leader.train_cost_food
	var gold: float = leader.train_cost_gold
	var pop: float = leader.train_cost_pop
	var zid: int = leader.train_zone_id
	leader.train_kind = ""
	leader.train_remaining = 0.0
	leader.train_total = 0.0
	leader.train_queue.clear()
	leader.train_cost_food = 0.0
	leader.train_cost_gold = 0.0
	leader.train_cost_pop = 0.0
	leader.train_zone_id = -1
	if refund:
		_refund(leader, food, gold, pop, zid)
	push_event({"type": "recruit_cancelled", "leader": leader, "reason": reason, "slot": -1,
		"refund_food": food, "refund_gold": gold, "refund_pop": pop})


## 退款：把粮食 / 黄金还给阵营、人口还给**当初扣它的那个区划**，
## 并把这一队的记账值减掉（这样将领阵亡时的整队退款不会把已经退过的再退一遍）。
##
## ⚠️ `zid` 必须由调用方传进来：`_release_recruit` 会先把 `train_zone_id` 清掉，
##    若在这里现读 leader.train_zone_id，人口就退不回去了（实测踩过）。
func _refund(leader, food: float, gold: float, pop: float, zid: int) -> void:
	resources["food"] = float(resources.get("food", 0.0)) + food
	resources["gold"] = float(resources.get("gold", 0.0)) + gold
	if pop > 0.0:
		var z = _zone_by_id(zid)
		if z != null:
			z["population"] = float(z.get("population", 0.0)) + pop
	leader.train_cost_food = maxf(0.0, leader.train_cost_food - food)
	leader.train_cost_gold = maxf(0.0, leader.train_cost_gold - gold)
	leader.train_cost_pop = maxf(0.0, leader.train_cost_pop - pop)


# ------------------------------------------------------------------
# 取消招募（点信息栏里那五个格子 → recruit_cancel 命令 → 这里）
# ------------------------------------------------------------------

## 某一格上排的是哪个兵种（"" = 空格子）。0 = 正在读条的大格子，1..4 = 排队的小格子。
func recruit_kind_at(leader, slot: int) -> String:
	if leader == null or slot < 0:
		return ""
	if slot == 0:
		return String(leader.train_kind)
	var k := slot - 1
	if k >= leader.train_queue.size():
		return ""
	return String(leader.train_queue[k])


## 取消某一格上的招募（需求：「点击对应的格子取消对应格子上的造兵队列，
## 其后方的造兵队列前移」）。
##
## @param slot 0 = 正在读条的那个（大格子）；1..4 = 排队的（小格子，从前往后）
## @return true = 取消成功（已按那一格**全额**退款）
##
## ★ 退款是**全额**：取消就是把这一单彻底撤销（与星际争霸一致）。
## ★ 大格子被取消时，队列里的下一个**前移**进大格子，并且**从头读条**（10 秒重新算）——
##   「前移」不等于「继承进度」：继承的话，玩家可以用「招一个 → 取消 → 再招」
##   把已经读掉的时间白嫖过来，队列上限也就没意义了。
## ★ 取消是**纯权威侧**操作：命令里只有队长 id 与格号，扣费 / 退款都在这里算
##   （第 1 轮联机时客机不能自己决定退多少钱）。
func cancel_recruit(leader_id: String, slot: int, faction: String) -> bool:
	var leader = unit_by_id(leader_id)
	var reason := leader_reject_reason(leader, faction)
	if reason != "":
		push_event({"type": "recruit_cancel_rejected", "reason": reason, "slot": slot})
		return false
	var kind := recruit_kind_at(leader, slot)
	if kind == "":
		# 空格子（或格号越界）：什么都不做 —— 界面本来就不该发这种命令
		push_event({"type": "recruit_cancel_rejected", "reason": "empty", "slot": slot})
		return false

	# 1) 先把它从队列里摘掉（后方的自动前移）
	if slot == 0:
		_start_next_in_queue(leader)      # 队列空 → 变回空闲；否则下一个前移并从零读条
	else:
		leader.train_queue.remove_at(slot - 1)

	# 2) 再退款 —— 顺序与招募相反（那边是「先扣再入队」）：这里先摘掉再退，
	#    中途出错也不会出现「退了钱、队列里还留着」。
	var cost := recruit_cost(kind)
	var food := float(cost.get("food", 0.0))
	var gold := float(cost.get("gold", 0.0))
	var pop := recruit_population_cost(kind)
	_refund(leader, food, gold, pop, leader.train_zone_id)
	push_event({"type": "recruit_cancelled", "leader": leader, "reason": "cancelled",
		"slot": slot, "kind": kind,
		"refund_food": food, "refund_gold": gold, "refund_pop": pop})
	return true


## 按 id 找区划（退款要还回**当初扣人口的那个**区划）
func _zone_by_id(zid: int) -> Variant:
	for z in zones.zones:
		if int(z["id"]) == zid:
			return z
	return null


## 招募期间把将领**钉回**开招那一刻的位置（碰撞推挤不许把它挪走）。
##
## ★ 放在 tick 的碰撞消解**之后**：那时推挤已经把位置写回了，这里再把它们摁回去。
## ★ 只钉「正在招募」的将领 —— 普通单位被推走是软分离的正常行为（collision.gd）。
func _pin_training_leaders() -> void:
	for u in units:
		if not u.alive or not u.is_training():
			continue
		if u.pos.distance_squared_to(u.train_anchor) <= 1e-12:
			continue
		u.pos = u.train_anchor
		u.sync_tile(map)


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
		var found = PathfinderRes.nearest_reachable(map, buildings, cfg, spawn, spawn, FactionRes.NPC_FACTION, 20, crowd)
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


## ★ 这一格的**区划中心**所属的区块（不是中心 → null）。
##
## 点选那条路的入口：`input_controller` 用它把「点到中心」翻译成「显示这个区划的详情」。
## 中心格上同时有一栋 `TYPE_ZONE_CENTER` 建筑（中立障碍），所以也可以从
## `building_at()` 拿到它，再从它的格子反查区块 —— 这里包一层省得两处各写一遍。
func zone_center_zone_at(tx: int, ty: int) -> Variant:
	if zones == null:
		return null
	return zones.center_zone_at(tx, ty)


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

# ------------------------------------------------------------------
# 每帧耗时剖析
#
# ★ 为什么这件事放在 world 里而不是测试里：tick() 的分段只有它自己知道，
#   在测试里复刻一遍 tick 就等于维护第二份实现（早晚会漂）。
#
# ★ 默认关闭：关闭时每段只多一次 `if profile_on` 判断，可以忽略。
#   打开后把各阶段的微秒数累加到 profile_us，供 tests/bench_crowd.gd 打印。
#
# ⚠️ 它只读时钟、不参与任何判定，所以不影响确定性（联机时保持关闭即可）。
# ------------------------------------------------------------------

## 打开后才计时（游戏里永远是 false）
var profile_on: bool = false
## 阶段名 → 累计微秒
var profile_us: Dictionary = {}


func profile_reset() -> void:
	profile_us = {}


## 取一个起始时间戳：关闭时返回 0（_prof_done 见到 0 直接返回）
func _prof() -> int:
	if profile_on:
		return Time.get_ticks_usec()
	return 0


func _prof_done(key: String, t0: int) -> void:
	if t0 == 0:
		return
	profile_us[key] = int(profile_us.get(key, 0)) + (Time.get_ticks_usec() - t0)


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
	frame_serial += 1

	# 警戒索敌：每帧**一次**批量算好（内核里按阵营分组，只扫敌对那一组）。
	# ★ 原来是「每个待命单位扫一遍全部单位」的 O(n²)：1000 单位待命时实测 283 ms/帧。
	#   结果按 frame_serial 对齐，只有本帧有效。
	if crowd != null and cfg.combat_enabled:
		crowd.refresh_targets(self, cfg)

	# 1) 区块占领（占位规则）
	var _t_zones := _prof()
	zones.update(cfg, dt, units, factions)

	# 1.5) ★ 区划人口：每个区块各算各的，只按时间涨、不消耗（用户需求）。
	#      与占领**无关**，也不进 HUD 的资源 —— 点开某个区划的中心能看它自己的人口。
	zones.update_population(dt)

	# 2) 建筑归属变化时才重算
	refresh_ownership()
	_prof_done("zones", _t_zones)

	# 3) 资源：★ 按**占领方拥有的各区划**聚合（产能 × 该区划地块数）。
	#    旧实现是「全局按占领地块数 × 1/秒」—— 现在产能由地图数据（地图编辑器）说了算，
	#    所以「抢区块 = 抢产能」。
	var _t_econ := _prof()
	var tiles = zones.owned_tile_count(my_faction)
	if tiles != owned_tiles:
		owned_tiles = tiles
		push_event({"type": "territory_changed", "tiles": tiles, "zones": zones.owned_zone_names(my_faction)})
	var rates: Dictionary = zones.production_of(my_faction)
	production_food = float(rates["food"])
	production_gold = float(rates["gold"])
	EconomyRes.tick(cfg, dt, rates, resources)
	_prof_done("economy", _t_econ)

	# 3.5) ★ 招募读条（将领自己就是兵营）。
	#      ⚠️ 必须跑在下面的「清理离场单位」之前：单机不复活，阵亡的将领会在
	#         同一帧被摘出 world.units，那时退款就找不到它了（见 _release_recruit）。
	var _t_recruit := _prof()
	_tick_recruitment(dt)
	_prof_done("recruit", _t_recruit)

	# 4) 单位：移动 + 战斗 / 警戒
	var _t_units := _prof()
	# 单位循环再拆三段的计时（只在 profile_on 时累加）
	var t_combat := 0
	var t_reclaim := 0
	var t_step := 0
	for ui in units.size():
		var u = units[ui]
		if not u.alive:
			# 阵亡中的单位只跑复活倒计时；复活后本帧就正常参与逻辑
			u.tick_respawn(cfg, self, dt)
			continue
		# ★★ 招募期间将领**钉在原地**（用户需求：固定在原地、无法行动、无法攻击）：
		#    整段单位逻辑（移动 / 索敌 / 开火 / 回位）都跳过。位置由末尾的
		#    _pin_training_leaders() 保证不被碰撞推走。
		if u.is_training():
			continue
		var c0 := _prof()
		CombatRes.tick_frame(self, cfg, u, dt, ui)
		var _c1 := _prof()
	_prof_done("units", _t_units)
	if profile_on:
		profile_us["units/combat"] = int(profile_us.get("units/combat", 0)) + t_combat
		profile_us["units/reclaim"] = int(profile_us.get("units/reclaim", 0)) + t_reclaim
		profile_us["units/step"] = int(profile_us.get("units/step", 0)) + t_step

	# 4.5) 清理离场单位。
	#      ⚠️ 这里**不能**简单地按 alive 过滤：对战模式下阵亡的单位要留在列表里等复活，
	#         一旦被过滤掉就永远活不过来了（见 docs/pitfalls.md 3.8 的姊妹问题）。
	#      ★ 被摘掉的这一批要**在这里**结算招募队列（退款 + 事件）——
	#        下一帧 _tick_recruitment 已经看不到它们了。
	var keep: Array = []
	for u in units:
		if u.alive or u.awaiting_respawn():
			keep.append(u)
		else:
			_release_recruit(u, true, "leader_died")
	units = keep

	# 5) 箭塔开火 + 建筑受击闪光衰减
	var _t_towers := _prof()
	CombatRes.update_towers(self, cfg, dt)
	CombatRes.update_building_effects(self, dt)
	_prof_done("towers", _t_towers)

	# 6) 调试：自动刷敌人
	if debug_auto_spawn:
		enemy_spawn_timer -= dt
		if enemy_spawn_timer <= 0.0:
			spawn_enemy()
			enemy_spawn_timer = cfg.num("debug.spawn_interval_sec", 3.0)

	# 7) 敌人 AI（朝玩家据点推进；被城墙挡住时锁定城墙来拆）
	var _t_ai := _prof()
	EnemyAiRes.update(self, cfg)
	_prof_done("enemy_ai", _t_ai)

	# 8) 收尸：被打光的建筑从地图上摘掉。
	#    放在末尾做，是为了让「本帧已经发生的战斗」都读到同一个世界快照。
	var _t_collect := _prof()
	_collect_destroyed_buildings()
	_prof_done("collect", _t_collect)

	# 8.5) ★ 单位碰撞与局部避让（软分离 + 谁给谁让路）
	#
	# 为什么放在最后：它是**收尾修正**，要在所有移动与战斗都算完之后再摆位置，
	# 否则本帧的移动会把刚摆好的位置又撞开。逻辑层的 `path / moving / goal` 全不动 ——
	# 推挤只改「位置」，不改「意图」。
	#
	# ⚠️ 联机（第 1 轮）：位置是权威状态，所以这一步只能跑在房主侧。
	var _t_col := _prof()
	if crowd != null:
		# 一次打包、一次调用、一次写回：软分离 + 建筑本体推出（见 crowd_bridge.resolve_all）
		crowd.resolve_all(self, cfg)
	else:
		CollisionRes.resolve(self, cfg)
		# 8.6) ★ 建筑本体的硬碰撞：大本营 / 箭塔不再整格挡人之后，
		#      「本体挡敌方」这条规则就落在这里（己方单位不受影响）。
		CollisionRes.resolve_buildings(self, cfg)
	# 8.7) ★ 招募中的将领**钉回**原位：推挤不许把「固定在原地」的将领挪走。
	#      （放在碰撞之后：这一步是覆盖，不是参与推挤）
	_pin_training_leaders()
	_prof_done("collision", _t_col)

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


## 给子阶段累加微秒（只有 profile_on 时会被调用，见 unit.tick_frame）
func profile_sub(key: String, us: int) -> void:
	profile_us[key] = int(profile_us.get(key, 0)) + us


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
