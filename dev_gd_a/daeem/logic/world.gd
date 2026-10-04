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
## ★ 只为「默认地图路径」这一处常量（`FALLBACK_MAP_PATH`）：地图目录是唯一源头，
##   这里不重复写 `res://data/maps/...` 字符串。
const MapLibraryRes = preload("res://logic/map_library.gd")
## ★ 战役 / 关卡（本轮新增）：`create_from_level()` 用它。**只读数据**，不含任何玩法规则。
const CampaignRes = preload("res://logic/campaign.gd")
const LevelRes = preload("res://logic/level.gd")
const ObjectiveRes = preload("res://logic/objective.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const UnitRes = preload("res://logic/unit.gd")
const ZoneRes = preload("res://logic/zone.gd")
const EconomyRes = preload("res://logic/economy.gd")
const TechRes = preload("res://logic/tech.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")
const CombatRes = preload("res://logic/combat.gd")
const EnemyAiRes = preload("res://logic/enemy_ai.gd")
const FactionAiRes = preload("res://logic/faction_ai.gd")
const GeneralAiRes = preload("res://logic/general_ai.gd")
const CollisionRes = preload("res://logic/collision.gd")
const CrowdBridgeRes = preload("res://logic/crowd/crowd_bridge.gd")
const FogRes = preload("res://logic/fog.gd")

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
## ★★ `resources` 是**本地玩家那一方**的资源池（HUD 读它、招募扣它）。
##    NPC / AI 阵营各有**自己的一份**，存在 `ai_resources` 里 ——
##    见 `resource_pool_for(faction)`。两边绝不互相挪用。
var resources: Dictionary = {"food": 0.0, "gold": 0.0}
## ★★ **每个玩家席位各一份**资源池："faction" → {"food": float, "gold": float}（本轮新增）。
##
## 合作模式要「p1、p2 各自的钱」（用户已拍板：资源各自独立）。
## ★ 关键设计：**本机席位那一份与 `resources` 是同一个字典对象**（不是副本）——
##   于是 HUD（读 `world.resources`）与扣费（走 `resource_pool_for()`）天然看到同一份数，
##   不需要任何「同步」代码（那种同步迟早会漏一处）。
## ★ `resources` 因此保留为「本机席位那一份」的别名，`view/` 一个字都不用改。
var player_resources: Dictionary = {}
## ★★ **本机负责的席位**（`reset()` 的 `roster`；空 = 单机只有 `my_faction` 一个）。
## 合作模式下是两个人（两个席位都在本机跑）。
## ★ 它是「谁的基地要建 / 谁的钱包要开」的判据 —— 见 `resource_pool_for()`。
var player_seats: Array[String] = []
## ★★ **本机玩家真正在操作**的那一方（= `my_faction`，只有一个）。
##
## ⚠️ 它与 `player_seats` 在「一关两个可玩阵营、选一个来玩」时**不一样**：
##   没被选中的那一方虽然也在本地席位名单里（它的基地要建出来），
##   但**本机不操作它** ⇒ 它照样可以被阵营 AI 接管（关卡写了 `ai` 的话）。
## ★ 判据：「**谁的 AI 要摘掉**」看这一份（`_setup_ai_factions` / `faction_ai.setup`）；
##   「谁的大本营 / 钱包算本地的」看 `player_seats`。
var player_factions: Array[String] = []
## ★★ 各 NPC / AI 阵营自己的资源池："faction" → {"food": float, "gold": float}。
##
## 为什么必须分开（这是「阵营 AI 有自己的资源库」那条需求的落点）：
##   招募与升级的**扣费代码只有一处**（`start_recruit` / `start_zone_recruit` 里的
##   `EconomyRes.spend`），它们原本写死了 `resources` —— 于是「AI 招一个兵」
##   会从**玩家**兜里掏钱，而「玩家招一个兵」在 AI 的循环里又会去掏 AI 的。
##   现在两处都走 `resource_pool_for(faction)`：谁下单就扣谁的钱。
## ★ 玩家阵营**不在**这张表里（它走 `resources`）—— `resource_pool_for` 里那条分支
##   是唯一判据，别在别处再判一次「是不是玩家」。
var ai_resources: Dictionary = {}
## 阵营 AI 的状态表（见 logic/faction_ai.gd 的 setup）：
## 每项 {faction, mult, general_index, recruit_timer, upgrade_timer, attack_timer}。
var ai_factions: Array = []
## ★★ 这一局挂的关卡（`logic/level.gd` 的 Level；**null = 不做战役**）。
##
## ★ 它只有一个用途：让 AI / 目标在运行时能问「关卡数据里写了什么」
##   （`level_attack_target()` / `level_ai_cfg()`）。
## ★ 为什么挂在 world 上而不是塞进 cfg：`config.json` 是**全局**的，
##   而「这一关给哪一方挂什么 AI、往哪打」是**每一关自己的数据**（1.3.4 那条拍板）。
var level = null
## ★ `create_from_level()` 算好的「合并后地图 + AI 名单」（`level.merge_over_map()` 的返回值）。
## ★ 它只是一份**缓存**：`reset()` 单独被调用（老路径）时它是空的，那时现算一次。
var _merged: Dictionary = {}
## ★★ 合并之后的 AI 名单（关卡优先 + 全局 config 兜底）：
## 每项 {id, ai, base, resource_mult, start_food, start_gold, attack_target,
##       faction_ai, general_ai, from_level}。
## ★ `ai == "general"` 的那些**只挂将领性 AI**（靠单位上的 `garrison_zone_id` 驱动），
##   不进 `ai_factions` 状态表；`ai == "none"` 的整条不进这份名单。
var ai_roster_cfg: Array = []
## ★★ 关卡摆放的**附属兵归属表**（本轮口径的唯一落点）：
## `"<faction>|<将领序号 0 起>"` → 该方在关卡 `start_units[]` 里摆给这一位将领的
## **附属兵数量**。
##
## ★ 它由 `_apply_placement_escorts()` 在 `_apply_level_placement()` 里填好，
##   `reset()` 开头**清空**（不清的话上一关的编制会漏给下一关，
##   那是「重开一局数值不对」这类最难查的事故）。
## ★★ 为什么要有这张表，而不是每次去扫 `level.start_units`：
##   读它的是 **AI 的补员目标**（`escort_target_of()`，一帧一次、每方每位将领一次），
##   而 `start_units` 可能有几百项 —— 扫表是 O(单位数 × 将领数)。
##   ⚠️ 键里的序号是**0 起**（与 `unit.general_index` 同规），不是 JSON 里的 1 起。
var placed_escorts: Dictionary = {}
## ★★ 这一方**在关卡里摆过附属部队**吗（`fid → true`）—— 与 `placed_escorts` 同一次缓存。
##
## ★ 用途只有一个：`escort_target_of()` 判断「关卡没给这位将领摆过兵」时，
##   补员目标该退到哪儿（见那个函数的说明）——**不能**每次都去问 `level`
##   （AI 每帧都要问，那是 O(单位数) 的一次扫描）。
var faction_escort_placed: Dictionary = {}
## ★★ 目标与胜负（`logic/objective.gd` 的状态）。
## ★ 空字典 / `kind == ""` ⇒ 这一局没有目标（不做战役的老路径），
##   `objective.update()` 每帧只多一次判断，**一个玩法行为都不受影响**。
var objective_state: Dictionary = {}
## ★ 这一局有没有建阵营 AI（`create()` 的 `with_ai`，见那里的说明）。
## ⚠️ 它只在 `reset()` 里读一次 —— 中途改它不会补建 / 拆掉已经建好的 AI 阵营。
var with_ai: bool = true
var owned_tiles: int = 0
## ★ 当前每秒产出（按占领的区划产能聚合出来；HUD 用来显示「+n/秒」）。
## 每帧在 tick() 里刷新 —— 纯展示用，不参与任何判定。
var production_food: float = 0.0
var production_gold: float = 0.0

## ★★ 科技（logic/tech.gd）：启用状态 + 效果聚合。
## ★ 它是**世界状态**（谁启用了哪几条），不是界面状态 ——
##   界面每帧读它画九格的高亮，命令层只调 `set_tech_active()`。
var tech: TechRes = null
## 本帧「加产量」那一份（启用中的每地块加成 / 血量倍率 / 人口增长倍率）。
## 每帧在 tick() 里按 `tech.effects_of()` 重算；**每次都是新字典**，别留着当缓存。
var tech_effects: Dictionary = {}
## 科技启用状态每变一次 +1（`set_tech_active` 里加）。
## ★ 血量倍率靠它决定「要不要重刷一遍所有建筑与单位」——**不是每帧刷**：
##   那一步要遍历全部对象，而启用状态几秒才变一次（见 tick 第 0 步）。
var tech_revision: int = 0
var _tech_hp_revision: int = -1

## 每个阵营的大本营坐标与将领出生点（复活点、敌人 AI 目标都从这里取）
var faction_bases: Dictionary = {}
var faction_spawns: Dictionary = {}

var time: float = 0.0
## 帧序号：每 tick +1。给「每帧预算一次、当帧有效」的缓存做对齐用
## （例如 crowd_bridge 的警戒索敌结果 —— 在 tick 之外读到上一帧的结果就是 bug）。
var frame_serial: int = 0

## ★★ 战争迷雾（logic/fog.gd）：**按阵营算「谁能看见哪一格」** + 「见过一次的敌方建筑」。
##
## ★ 它是**世界状态的一部分，但不是玩法状态**：战斗 / 索敌 / 寻路 / 占领全都不看它，
##   view/ 每帧读它决定「画什么」（灰色遮罩、看不见的敌人不画、点不到）。
## ★ 为什么不进快照：它是**派生**数据（同一份权威状态算出来的结果），
##   而快照只发「结果」不发「过程」—— 联机时各端按同一份状态各算一遍即可。
## ★ `my_faction` 那一方的视野就是玩家看到的（上屏的那个阵营由 game_scene 定）。
var fog: FogRes = null

## 对战规则总开关 —— **本轮永远是 false**。第 1 轮联机时才置 true。
##
## ★ 存在的理由（见 docs/pitfalls.md 3.8）：HTML 版的复活一开始泄漏进了单机，
##   死了的测试敌人 8 秒后又站起来。开关不是为了联机，是为了「单机行为不被改写」。
var pvp_enabled: bool = false

var _events: Array = []
## ★ 目标结算播报去重（本轮新增）：结算之后 world **继续 tick**，
##   不记一笔就会每帧发一条 `level_end`。值 = 已经播报过的状态（"won"/"lost"；""= 还没结算）。
var _objective_reported: String = ""
var _enemy_serial: int = 0
## 招募序号：只用来生成**永不重复**的 id（`general-1-r3`）。
## 为什么不用「现有附属兵数 + 1」：那个数会因为阵亡 / 离场而回退，回退就会撞名。
var _recruit_serial: int = 0
var enemy_spawn_timer: float = 0.0
var debug_auto_spawn: bool = false


## ★★ `with_ai`：这一局要不要建**阵营 AI**（`config.ai.factions`；默认**要**）。
##
## ★ 为什么需要一个开关（不是「可有可无的方便参数」）：
##   开了 AI，世界上就多了**一整个阵营**（三个将领 + 一座大本营 + 它的资源池）——
##   任何「数一数场上有几个将领 / 几个单位 / 谁站在哪一格」的断言都会跟着变。
##   而单机游戏当然要开着它；测试与基准却常常要一个「只有玩家 + 地图摆设」的干净世界
##   （它们验的是移动 / 碰撞 / 迷雾，不是 AI）。
## ★ 传 false 时，世界与「加 AI 之前」**逐位一致**（`ai_factions` 为空、
##   `reset()` 里那段 AI 设置整段跳过）。这也是加这个开关的唯一目的 ——
##   让「不开 AI」是一条真的什么都没发生的路，而不是「开了但没跑」。
static func create(p_cfg: ConfigRes, map_path: String = MapLibraryRes.FALLBACK_MAP_PATH,
		with_ai: bool = true) -> RefCounted:
	var w = new()
	w.cfg = p_cfg
	w.with_ai = with_ai
	# ★ 迷雾对象先建出来（哪怕地图载入失败）：view/ 每帧都会问它「这一格看得见吗」，
	#   留一个 null 就等于让每个调用点都要判空（那种判空迟早会漏一处）。
	w.fog = FogRes.create()
	w.map = MapDataRes.load_from(map_path, p_cfg)
	if w.map == null:
		push_error("World.create：地图载入失败（%s）" % map_path)
		return null
	w.fog.reset_cache()
	w.reset()
	return w


## ★★ 从**一关**造一个世界（本轮新增）—— 战役的入口；`create()` 是「按一张图直接开一局」。
##
## 与 `create()` 的差别只有一处：**挂上 `level`**，于是 `reset()` 会依次应用
##   关卡覆盖层（大本营 / 阵营 / 区块归属 / AI 名单）→ 关卡摆放（`start_units` /
##   `start_buildings`）→ 目标与胜负（`objective.setup`）。
##
## @param cfg      配置
## @param level    `logic/level.gd` 的 Level（**必须非 null**）
## @param my_faction 本机席位（房主 = `players[0]`，客机 = `players[1]`）
## @param roster   本局的玩家席位；**空数组 = 用关卡 `players[]` 的顺序**（见下）
## @param with_ai  要不要建阵营 AI（与 `create()` 同一个开关）
##
## ★★ `roster` 的顺序就是**席位顺序**（房主第 1 个、客机第 2 个），这是拍板第 18 项。
##    ⚠️ 传空数组时用 `level.seats()`（单人战役 / 单机跑一关的正常调用）；
##       联机时**必须显式传**（客机只操作自己那一个席位，而它可能是 p2）。
##
## ★★ **「玩家选中哪一方，运行时就把那一方的 AI 摘掉」**（拍板第 13 项）：
##    落点在 `reset()` → `_setup_ai_factions()` 里那条 `player_factions.has(fid)` ——
##    所以这里只要把 roster 传对，摘 AI 这件事就自动成立（**唯一的一处判据**）。
##
## ⚠️ `with_ai = false` 且 `level == null` 时新状态必须是「空且不影响任何旧行为」——
##    这条契约由 `_apply_level()` / `_apply_level_placement()` / `ObjectiveRes.setup()`
##    三处的「level == null 直接返回」共同保证（tests/test_logic.gd 的 383 项是回归）。
static func create_from_level(cfg: ConfigRes, level, my_faction: String,
		roster: Array = [], with_ai: bool = true) -> RefCounted:
	if level == null:
		push_error("World.create_from_level：level 是 null（请改用 create()）")
		return null
	if String(level.map_path) == "" or level.map == null:
		push_error("World.create_from_level：这一关的地图载入失败（map = 「%s」）" % String(level.map_id))
		return null

	var w = new()
	w.cfg = cfg
	w.with_ai = with_ai
	w.fog = FogRes.create()
	w.level = level
	# ★★ 关卡覆盖层在这里**先合并出地图**（返回新对象，不改关卡自己那份 `level.map`）：
	#    于是 `reset()` 里那一段「建基地 / 分地 / 摆建筑」读到的都是合并后的数据，
	#    而**覆盖规则的实现仍然只有一处**（`logic/level.gd` 的 `merge_over_map`）。
	var merged: Dictionary = level.merge_over_map(cfg.ai_factions())
	w._merged = merged
	w.map = merged["map"]
	if w.map == null:
		push_error("World.create_from_level：地图载入失败（%s）" % String(level.map_path))
		return null
	w.fog.reset_cache()

	var seats: Array = roster
	if seats.is_empty():
		seats = level.seats()
	var me := my_faction
	if me == "" and not seats.is_empty():
		me = String(seats[0])
	w.reset(me, seats)
	return w


## 回到干净的开局状态（单机 always only 'player'）
func reset(p_my_faction: String = "", p_roster: Array = []) -> void:
	building_list = []
	_building_at = {}
	building_revision = 0
	last_ownership_revision = -1
	units = []
	_events = []
	_objective_reported = ""
	_enemy_serial = 0
	# ★★ 关卡摆的附属兵归属表也是**上一局的数据**：必须在 `_apply_level_placement()`
	#    之前清掉（下面那一段清理全都在摆放之前，这里跟着它们走 ——
	#     放到后面会把这一局刚填好的表一起抹掉）。
	placed_escorts = {}
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
	# ★★ 本地这一侧的两个概念（**别把它们当成一件事**）：
	#    · `player_seats`   = 「本局由**本机**负责的席位」= roster。
	#      合作模式下是两个人（p1 + p2 都在本地跑），单机是 1 个；
	#      选边关里**还带着敌人那一边**（它的家也要建出来）—— 所以它**不等于**「玩家阵营」。
	#      它决定「谁的大本营要建出来、谁的钱包要开出来」。
	#    · `player_factions` = 「本机**在操作**的那些席位」（= `player_seats` 里**没有**
	#      被 AI 接管的那几个）。
	#      合作模式两个都是（AI 一个都不建）；选边关只有你选的那一个。
	#      它决定「谁的家算玩家的家」「目标归谁」「谁的 AI 要摘掉」。
	#
	# ⚠️ `player_factions` **必须等 `_apply_level()` 之后再算**：判断「某一方是不是
	#    被 AI 接管」要看关卡那份 AI 名单（`ai_roster_cfg`）——
	#    只有 `my_faction` 与 cfg / map 可查，而关卡点名的 AI 阵营要等合并完才知道。
	#
	# ★★ 为什么要有 `player_seats` 这一层（实测踩到）：「选边关」里 roster 是
	#    `[我选的那一方, 敌人那一方]`（两边的家都要建出来），但敌人那一方**本机不操作**、
	#    由它自己的 AI 指挥。少了这一层就没法同时表达「它的家要建」与「它不是玩家」，
	#    于是要么它没家（一进关就 `objective_never_held`），要么它被算成玩家
	#    （它的家被拆会连累玩家判负、目标判定也会把它算进去）。
	player_seats = []
	for f in factions:
		player_seats.append(String(f))
	# ★★ 关卡覆盖层（本轮新增）：**在盟友表之前**应用 ——
	#    因为关卡可以覆盖 `zones[].owner`，而「NPC 阵营要不要进名单」那一条正是
	#    看地图的区块归属（`_map_declares_owner`）。顺序反了会出现
	#    「关卡给 enemy 划了地，但 enemy 没进名单 ⇒ 那些地保持无主」。
	_apply_level()
	# ★★ `player_factions`：本机**在操作**的那些席位 —— `player_seats` 减去
	#    「本局由 AI 接管」的那几个（判据是**组装期**的 `ai_kind_of()`，见那个函数的说明）。
	#    · 合作模式（两个真人，都没配 ai）⇒ 两个都在；
	#    · 选边关（两边都配了 ai，我选一个）⇒ 只剩我选的那一个。
	#    ⚠️ 用 `_is_ai_piloted()` 不行：它把 `my_faction` 排除了，于是「另一个可玩阵营」
	#      也会被算成玩家（它的家被拆会连累玩家判负、目标判定也会把它算进去）。
	player_factions = []
	for f in player_seats:
		if ai_kind_of(String(f)) != LevelRes.AI_NONE:
			continue                        # 这一方这一局归 AI 管 ⇒ 不是「玩家的家」
		player_factions.append(String(f))
	# 兜底：一个都不剩时至少把本机席位算进来（否则「玩家的家」会一个都没有）
	if player_factions.is_empty() and my_faction != "":
		player_factions.append(my_faction)
	# ★★ 关卡 / 战役数据里的**阵营颜色**（本轮新增）：必须在下面那句 `set_allies` 之前、
	#    在所有阵营确定之后登记 —— `view/` 里所有取色都走 `cfg.faction_color()`，
	#    漏了这一步战役的自定义阵营 id 会一片品红（见 `_register_level_colors`）。
	_register_level_colors()
	# ★★ 阵营归属（盟友）——**地图数据**说了算（`map.json` 的 `allies`，
	#    见 logic/faction.gd 那一大段说明与 logic/map_data.gd 的 `_read_allies`）。
	#
	# ★ 为什么在这里注入（而不是建 world 时一次性设好）：
	#   `FactionRes` 的盟友表是 **static**（查询在每帧每单位的路径上），
	#   而「换一张图 / 重开一局」必须把它换掉 —— 放在 reset 里，与地图数据同生命周期。
	# ★ 必须在**任何索敌 / 占领 / 建东西之前**（下面 zones.build_from_map 会读名单，
	#   而占领判定要问「站着的算几方人」）—— 所以紧跟在名单确立之后。
	# ★ 顺序上也在 `_setup_ai_factions()` 之前：那一句会往名单里加 AI 阵营，
	#   而盟友表只按**名字**查表，与名单里有没有它无关（认不出来的 id 天然无效）。
	# ★★ 关卡写了 `allies` 就用关卡的（`level.effective_allies()` 里那条口径）——
	#    这就是「覆盖规则只有一处实现」那一句在盟友上的落点。
	FactionRes.set_allies(_effective_allies())
	# ★★ NPC 阵营（"enemy"）要不要进名单：**看地图里有没有它名下的区块**
	#    （`zone_list[].owner`，见 map_data 的 zones_owners）。
	#
	# 为什么必须进名单：区块归属只认名单里的阵营（`zone._faction_known`），
	#   而「将领性 AI 在**己方区划**里招兵」那条要求（`leader_zone_owned`）意味着
	#   那些驻防将领脚下得真有属于自己的地。名单里没有 "enemy" ⇒
	#   地图写 `"owner": "enemy"` 的区块会被当成认不出来的 id 而**保持无主**，
	#   于是驻防将领永远招不了兵（一个很安静的错：AI 看起来「就是不招人」）。
	#
	# ⚠️ 反过来也重要：地图里**一个 enemy 区块都没有时，绝不把 "enemy" 塞进名单** ——
	#   名单是「谁参与这一局」，多塞一个会改变「在场的阵营」这个分母
	#   （联机时 `spawned_factions()` 判胜负用；单机的区块占领也用）。
	#   所以判据是**地图数据**，不是「有没有敌人」这种模糊的东西。
	if not factions.has(FactionRes.NPC_FACTION) and _map_declares_owner(map, FactionRes.NPC_FACTION):
		factions.append(FactionRes.NPC_FACTION)

	# ★★ 科技：**重开一局必须从零开始**（带着上一局的启用状态重开会静默改变开局数值）。
	#    先建好 tech（下面建建筑时就要它算血量倍率），再清空启用状态。
	tech = TechRes.new()
	tech.setup(cfg)
	tech.reset()
	tech_effects = {}
	# ★ 版本号归零（-1 表示「还没刷过」）：这样下面那次收口的 _apply_tech_effects()
	#   一定会跑，预置建筑也一起对齐。
	tech_revision = 0
	_tech_hp_revision = -1

	# ★★ 战争迷雾：重开一局要把「上一局看见过哪些敌方建筑」彻底忘掉
	#    （不清的话，新开一局的对家据点会**开局就显示出来** —— 那是上一局的记忆）。
	#    ⚠️ 必须在建任何建筑 / 单位**之前**清，否则下面出生点的建筑会先把视野算进去。
	if fog == null:
		fog = FogRes.create()
	fog.reset_cache()

	_reset_player_pools()
	ai_resources = {}
	ai_factions = []
	faction_bases = {}
	faction_spawns = {}

	# ★★ AI 阵营（config.ai.factions）：**在世界开始建东西之前**先把它们插进名单，
	#    并给它们登记大本营点位。
	#    ⚠️ 顺序不能挪到后面：`zones.build_from_map` 要按名单建「每阵营一份占领进度」，
	#       而下面那一段出生点循环要按名单给每一方建基地 —— 名单晚了 AI 就没地没基地。
	#    ⚠️ `set_faction_base` 必须在 `apply_faction_layout` 之前（见 map_data 那条注释）。
	_setup_ai_factions()

	zones = ZoneRes.build_from_map(map, cfg, factions)

	# ★★ 地图给的**开局归属**（`zone_list[].owner`，本轮新增）：NPC / AI 阵营一开始
	#    就有的地。⚠️ 必须排在各阵营的基地之前 —— 否则大本营落地时那一块还算无主，
	#    会被 `refresh_building_ownership` 按「无主区块 + 玩家建筑」而收给玩家
	#    （见 zone.gd 的 apply_initial_ownership）。
	zones.apply_initial_ownership(map, factions)

	var primary: String = factions[0] if factions.size() > 0 else my_faction
	apply_faction_layout(my_faction, primary)
	# 单机名单只有我这一方；联机时这里要为名单里每一方都建出基地与部队
	for f in factions:
		if f != my_faction:
			apply_faction_layout(f, primary)
	# 地图上**预置**的建筑（对家据点这类固定摆设，坐标写在 `data/maps/<id>/map.json`
	# 的 "buildings" 里）。
	# 放在各阵营出生点之后：它们的坐标是手写的，不与出生点抢格；被占住的格子 add_building 会自己拒。
	for p in map.prefab_buildings:
		add_building(String(p["type"]), int(p["x"]), int(p["y"]), String(p["owner"]), true, true)
	# ★★ 区划中心（地图编辑器给每个区块指定的那一格）：**中立障碍建筑**。
	#    ⚠️⚠️ 必须在**任何单位出生之前**建好（顺序踩过一次，实测）：
	#       单位出生找站位时会避开建筑（`_ring_tile` 里那条 `building_at() != null`），
	#       而中心是在 reset 末尾才建的 —— 于是「先出生的附属兵」正好站在中心那一格上，
	#       开局就有一个兵被卡在不可进入的建筑里（`test_retinue` 抓住的）。
	#    `add_building` 对已占格会拒绝，所以「中心最优先」是这样落地的：
	#      · 中心的格子是**编辑器的硬规则**（导出前 blockers 拦住与大本营叠格的那些）；
	#      · 真出现叠格（手改地图），这里会静默建不出来 —— 但绝不会把已有建筑顶掉。
	_spawn_zone_centers()
	# ★★ 各方的将领与附属兵。顺序是**死的契约**：
	#    `world.units` 的前几个永远是这一方的将领 —— 快捷键 1/2/3 与「按序号取将领」
	#    的代码都靠它，所以任何「开局就在场的单位」都只能**排在后面**。
	#
	# ⚠️ 地图预置单位（`map.json` 的 `units[]`）**本轮整个废弃、运行时不再读**：
	#    要摆开局的守军 / 靶子，一律用**关卡的 `start_units`**（见下面的
	#    `_apply_level_placement()`，字段语义与老的 `units[]` 一字不差）。
	#    所以这里**只剩**「各方自己的将领与附属兵」这一段。
	for f in factions:
		spawn_faction_units(f)
	# 出生点的大本营也会把所在区块直接收归己方（zone_owned_by_building）；
	# 这一条在「开局第一帧之前」就该成立，否则 HUD 上的领地会在第一次 tick 前闪一下空
	refresh_ownership()
	# ★ 科技的收口：开局还没启用任何科技，这一句把「有没有加成」在任何对象
	#   （含预置建筑）上都对齐一次，并把每秒产出先算出来 ——
	#   于是 HUD 在第一次 tick 之前读到的是正确的「+n/秒」而不是 0。
	tech_effects = tech.effects_of(my_faction)
	_tech_hp_revision = tech_revision
	_apply_tech_effects()
	# ⚠️ 上面那句会顺手刷新 `owned_tiles`（它是「+n/秒」的乘数），
	#    但 reset() 的契约是「刚 reset 完 = 还没跑过 tick ⇒ 领地数是 0」
	#    （tests/test_logic.gd 钉着这一条：开局没有己方地块）。
	#    所以这里把它放回 0 —— 第一次 tick 会立刻算出真值。
	owned_tiles = 0

	# ★★ 关卡的**开局摆放**：`start_units` / `start_buildings`
	#    **追加**在地图预置建筑与各方将领**之后**（覆盖规则：追加，不是替换）。
	#
	# ★★ 这是「开局就摆好的守军 / 靶子」**唯一**的入口（本轮把地图的 `units[]` 废弃了）：
	#    字段语义与老的 `map.json` 的 `units[]` 一字不差（kind / faction / hold / zone / name）。
	#
	# ⚠️ 顺序（三个「之前 / 之后」都不能挪）：
	#    · 在 `_spawn_zone_centers()` **之后** —— 中心是中立障碍，摆放不许压在它上面
	#      （编辑器的导出校验第 5 条会拦，这里靠 add_building / 站位避让兜底）；
	#    · 在 `spawn_faction_units()` **之后** —— `world.units` 的前几个必须还是各方将领
	#      （快捷键 1/2/3 与按序号取将领的代码都靠这条契约）；
	#    · `start_buildings` 在 `start_units` **之前**（单位找站位时要避开建筑）。
	var placement_from := units.size()
	_apply_level_placement()
	# ★★ 关卡摆放进来的守将也要有归属（本轮收口）——
	#   顺序是死的：`_apply_level_placement` **必须**先跑，否则这些单位还没进 `units`。
	#   ⚠️ `from` 用**摆放之前**的长度：只扫这一批新造的，别回头去碰前面
	#      `spawn_faction_units()` 造出来的将领与附属兵（那些的归属另有出处：
	#      将领由 `spawn_faction_units()` 收尾兜底、附属兵继承队长）。
	for lf in factions:
		if _is_garrison_ai(String(lf)):
			_assign_garrison_zones(String(lf), placement_from)

	# ★★ 迷雾收口：所有建筑与单位都就位之后算一次视野 ——
	#    于是「进游戏第一帧之前」玩家屏上就已经是正确的迷雾，
	#    而不是先整屏灰一下、等第一次 tick 才亮起来。
	#    （与上面那句 tech 收口同一个道理：HUD / 渲染在 tick 之前就会读到这些值。）
	fog.update(self)

	# ★★ 阵营 AI 的状态表（本轮新增）：**所有单位都就位之后**才建。
	#    它只需要「阵营 id + 参数」，本身不扫描世界 —— 但放在这里有个好处：
	#    与上面那句 fog 收口一起，构成「reset 结束时一切都是热的」这条契约
	#    （第一帧 tick 之前 HUD / 测试读到的东西都是对的）。
	#
	# ⚠️ **必须看 `with_ai`**：不开 AI 的世界里 `ai_resources` 是空的，
	#    状态表要是建了出来，`faction_ai.update()` 就会去要一个不存在的资源池
	#    （实测症状：`_income` 里 "Trying to assign value of type 'Nil' to a
	#    variable of type 'Dictionary'"，而它只在 tick 里才炸）。
	#    这一句与 `_setup_ai_factions()` 开头那个 `if not with_ai: return` 是**一对**。
	ai_factions = [] if not with_ai else FactionAiRes.setup(self, cfg)

	# ★★ 目标与胜负（本轮新增）：与上面那两句**同一处收口** ——
	#    「reset 结束 = 一切是热的」这条契约要继续成立：HUD 在第一帧 tick 之前
	#    读到的目标进度 / 状态就必须是对的（不是先画一个 0/180 再等第一次 tick）。
	#
	# ★★ `defend` = **本机自己在操作的那些席位**（判定「谁的家算玩家的家」「目标归谁」用它）。
	#
	# ⚠️⚠️ 判据是 `player_factions`（本机**在操作**的那一方），**不是** `player_seats`
	#    （本机负责建基地的那几个）。两者在「选边关」里**不一样**：
	#    选红方时 `player_seats = [F2, F1]`（两边的家都要建出来），但 F1 是**敌人**、
	#    由它自己的 AI 指挥 —— 把它也算进 `defend` 会出两个静默的错（实测）：
	#      ① 「占领 c1」的判据变成「c1 归 F2 **或 F1**」⇒ 开局第一帧就判胜；
	#      ② F1 的大本营被算成「玩家的家」⇒ 它被拆会连累玩家判负。
	#
	# ★ 第三个参数 `my_faction` = 本机在操作的那一方，它决定**打哪条目标**
	#    （一关可以配两条：蓝方守住 c1 / 红方占领 c1）。
	var defend: Array = []
	for f in player_factions:
		if ai_kind_of(String(f)) != LevelRes.AI_NONE:
			continue
		defend.append(String(f))
	if defend.is_empty():
		defend = [my_faction]
	objective_state = ObjectiveRes.setup(self, level, defend, my_faction)


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
		if add_building(BuildingRes.TYPE_ZONE_CENTER, t.x, t.y, "", true, true) == null:
			push_warning("区划「%s」的中心 (%d, %d) 建不出来：那一格已经被别的建筑占了"
				% [String(z["name"]), t.x, t.y])


## 地图里有没有把这个阵营写成某个区块的开局归属（`zone_list[].owner`）。
##
## ★ 用途只有一个：决定 NPC 阵营（"enemy"）要不要进这一局的阵营名单
##   （见 `reset()` 里那段说明：名单是关键判据，不能凭感觉塞）。
static func _map_declares_owner(map, fid: String) -> bool:
	if map == null or fid == "":
		return false
	for _zid in (map.zones_owners as Dictionary).keys():
		if String(map.zones_owners[_zid]) == fid:
			return true
	return false


## ★★ 建立这一局里**全部的阵营 AI**（config.json 的 `ai.factions`）。
##
## 做三件事（顺序有讲究）：
##   1. 给每一方登记**大本营点位**（`_register_config_bases`）——
##      ⚠️ 必须在 `apply_faction_layout()` 之前（否则会先按兜底点位建一座、再重建）；
##   2. 把这些阵营**插进名单**（`factions`）—— 它们要被建基地、要能被单位占领区划、
##      要能当索敌对象；没有名单就没有这一切；
##   3. 给每一方开一个**自己的资源池**（`ai_resources`）并放进初始资金。
##
## ★ 为什么资源池在 reset 里开、而不是在 faction_ai 里懒建：
##   它是**权威状态**（与 `resources` 同一层），要有确定的初值 ——
##   懒建的池子第一次读到 0 还是 100 取决于谁先跑，那种不确定性最难查。
##
## ⚠️ 已经存在的阵营（地图里划过的 p2、或者上一条 AI 已经加过的）**不重复加**：
##   重复 append 会让「建基地」那一段对同一方跑两遍（第二遍会把第一座的部队清掉）。
##
## ★★ 为什么第 2、3 件事要挂在 `with_ai` 开关后面（见 `create()`）：
##   开了 AI，世界上就**多了三个将领、一整个阵营、几块地**——
##   任何「数一数场上有几个单位 / 几个将领 / 谁站在哪」的断言都会跟着变。
##   而那条信息（开没开 AI）只有调用方知道，所以开关必须一路传到这里，
##   由它决定「这一局要不要把 AI 插进来」。
func _setup_ai_factions() -> void:
	# ★★ 合并后的 AI 名单（本轮新增）：**关卡显式写了 `ai` 的阵营优先**，
	#    其余照旧吃 `config.json` 的 `ai.factions` —— 一个入口，见 `_apply_level()`。
	#    ⚠️ 必须在 `_register_config_bases()` 之前算：它要用来回答「哪几方该进这一局」。
	ai_roster_cfg = _merged_ai_roster()
	# ★★ 大本营点位**先登记**，而且**不看 with_ai**（见 `_register_config_bases` 的说明）：
	#    「这一方从哪开局」是布局数据，与「它有没有 AI 脑子」是两件事。
	# ★ 登记的是**合并后**那份名单：关卡给了点位就用关卡的（`level.merge_over_map` 已经
	#   把它们写进 `map.faction_bases` 了），这里只兜底 `config.ai.factions[].base`。
	_register_config_bases()
	if not with_ai:
		return
	for e in ai_roster_cfg:
		var entry: Dictionary = e
		var fid := String(entry["id"])
		if fid == "":
			continue
		# ⚠️ **本机在操作的那一方**不在这里管：它的钱走 `player_resources`
		#    （`_reset_player_pools` 已经开好了）。
		if fid == my_faction:
			continue
		# ★★ **只有「本局真的有 AI 在管」的那几方才开 AI 池**。两种：
		#    · 阵营性 AI（`_is_ai_piloted`）—— 招将 / 招兵 / 出兵都从这里扣钱；
		#    · 将领性（守家）AI（`_is_garrison_ai`）—— 它的「脱战无消耗招兵」也走
		#      `resource_pool_for()`，池子是 null 的话招募会被判「付不起」而静默失败
		#      （实测：蓝方 15 个单位卡在原地不动）。
		#    ⚠️ 这两条之外**不开池**：玩家自己那一方的池子必须留给 `player_resources`
		#      （「谁的订单扣谁的钱」这条判据的唯一性就靠它）。
		#    ⚠️⚠️ **本机在操作的那一方是例外**：它可能因为「另一半时间由 AI 接管」
		#      而在这份名单里（选边关两边都写着 `ai`），但本局它是**玩家** ——
		#      绝不能给它开 AI 池（实测：选了红方之后 `resource_pool_for(F2)` 返回的是
		#      AI 池而不是 `world.resources`，HUD / 扣费两边就分家了）。
		if fid != my_faction and (ai_kind_of(fid) != LevelRes.AI_NONE):
			ai_resources[fid] = {
				"food": float(entry.get("start_food", 0.0)),
				"gold": float(entry.get("start_gold", 0.0)),
			}
		# 只有**阵营性 AI** 才建状态表（`ai: "general"` / `"none"` 跳过）
		if fid == my_faction or not _is_ai_piloted(fid):
			continue
		if String(entry.get("ai", LevelRes.AI_FACTION)) != LevelRes.AI_FACTION:
			continue
		# ★★ 走到这里的就是「**本局要挂阵营 AI 的那一方**」。两种来源：
		#    ① 本机没在操作的参展阵营（NPC / 敌人）；
		#    ② ★ **本机席位里、但玩家没选中的那一方**（一关两个可玩阵营时）——
		#       它的基地照样要建出来（席位该有的都有），但脑子交给 AI。
		#    两种情况都要：进名单 + 开 AI 资源池。
		if not factions.has(fid):
			factions.append(fid)

	# ★ 状态表在**所有单位就位之后**才建（见 reset 末尾的收口那一句）：
	#   这里只把名单与钱准备好。
	ai_factions = []


## ★★ 合并后的 AI 名单：关卡写了 `ai` 的阵营优先，其余照旧吃 `config.json`。
##
## ⚠️ 关卡合并的**唯一实现**在 `logic/level.gd` 的 `merged_ai_factions()` ——
##    这里只是「有 level 就问它、没有就用 config」的那一层分发，**不重复实现**合并规则
##    （两处实现必然漂开，那是这一整套里最容易出的错）。
##
## ★★ 有 `level` 时，**纯来自 `config.json` 的那一条会被过滤掉**（见下）：
##    「这一关有哪些阵营」是**关卡数据**说了算的（1.3.4 / 1.3.5 的口径）——
##    否则「往全局 config 里加一个 AI 阵营」会悄悄改变**已有战役的每一关**，
##    而关卡作者根本没碰过那些文件。
##    · `source == "level"`：关卡显式写的 → 留；
##    · `source == "map"`：地图上划过的阵营（这一局的布局）→ 留；
##    · `source == "config"`：只有全局配置提过它 → **丢掉**（要做战役就该在关卡里点名）。
##    ⚠️ 想让 config 里那个阵营**别来**这一关，关卡写 `{"id": "…", "ai": "none"}` 也行
##      —— 那是「明确关掉」，与「什么都没提」在下面这两条分支里结果一样，
##      但意图写在了数据里（样例战役就是这么关掉 config 那个 "ai" 的）。
func _merged_ai_roster() -> Array:
	# `create_from_level()` 已经把「合并后的地图 + AI 名单」算过一次了（存在 `_merged`）：
	# 直接复用它，避免同一个 reset 里再复制一遍地图的网格（那是白花的开销）。
	var cached: Variant = _merged.get("ai", null)
	if typeof(cached) == TYPE_ARRAY and not (cached as Array).is_empty():
		return _keep_level_sourced(cached)
	if level != null:
		return _keep_level_sourced(level.merged_ai_factions(cfg.ai_factions()))
	var config_ai: Array = cfg.ai_factions()
	var out: Array = []
	for item in config_ai:
		var e: Dictionary = item
		out.append({
			"id": String(e.get("id", "")),
			"ai": LevelRes.AI_FACTION,
			"base": e.get("base", Vector2i(-1, -1)),
			"resource_mult": float(e.get("resource_mult", 1.0)),
			"start_food": float(e.get("start_food", 0.0)),
			"start_gold": float(e.get("start_gold", 0.0)),
			"attack_target": null,
			"faction_ai": null,
			"general_ai": null,
			"from_level": false,
		})
	return out


## ★★ 把**关卡覆盖层**写进这一局（由 `reset()` 在名单确立之后、盟友表之前调）。
##
## 做三件事：
##   1. `level.merge_over_map(cfg.ai_factions())` 得到**合并后的地图**（新对象）与 AI 名单，
##      **唯一的合并实现**在 `logic/level.gd`（这里不重复实现覆盖规则）；
##   2. 把关卡给的 AI 阵营**插进名单**（它们要被建基地、要能占区划、要能当索敌对象）；
##   3. 记住 `ai_roster_cfg`（AI 参数覆盖与进攻目标都从它读）。
##
## ★★ 合并后的地图在 `create_from_level()` 里就已经换上了（它要在 `reset()` 之前生效）；
##    这里只**再算一遍 AI 名单**与补名单 —— 两处必须用同一个 level，
##    所以 `create_from_level()` 与 `reset()` 之间不能换 level。
##
## ⚠️ `level == null` 时**一个字段都不动** —— 这是「不做战役的老路径逐位不变」那条
##    硬要求在本函数里的落点。
func _apply_level() -> void:
	if level == null or map == null:
		return
	# `create_from_level()` 已经把合并结果算过一次（`_merged`）；`reset()` 被单独调用
	# （不带 level 的老路径不走这里）时才现算一次。
	var merged: Dictionary = _merged
	if typeof(merged.get("ai", null)) != TYPE_ARRAY or (merged["ai"] as Array).is_empty():
		merged = level.merge_over_map(cfg.ai_factions())
		_merged = merged
	ai_roster_cfg = _keep_level_sourced(merged["ai"])
	# ★★ 关卡**点名过的**阵营一律进这一局的名单（与 `config.ai.factions` 那一条同源，
	#    但用的是关卡数据 —— 所以关卡可以点名一个地图与 config 里都没有的阵营）。
	#
	# ⚠️⚠️ **包括 `ai: none` 的那些**：`ai: none` 的语义是「这一方这一局不动」，
	#    不是「这一方不存在」—— 它照样可能有**开局归属的地**（`zones[].owner`）
	#    或**开局摆放的单位**（`start_units[].faction`）。
	#    漏掉它的后果很安静：`zone.apply_initial_ownership` 只认名单里的阵营，
	#    于是写给它那几块地会**保持无主**（AI 于是没有产出、也就永远不出兵）。
	for e in level.faction_meta:
		var fid := String((e as Dictionary).get("id", ""))
		if fid == "" or factions.has(fid):
			continue
		factions.append(fid)
	for e2 in ai_roster_cfg:
		var fid2 := String((e2 as Dictionary).get("id", ""))
		if fid2 == "" or factions.has(fid2):
			continue
		if String((e2 as Dictionary).get("ai", LevelRes.AI_NONE)) == LevelRes.AI_NONE:
			continue                        # 只靠玩家 / 摆放驱动的那一方不用进名单（下一轮再加）
		factions.append(fid2)


## ★★ 只留「关卡 / 地图」来的那几条（`source != "config"`），见 `_merged_ai_roster` 的说明。
static func _keep_level_sourced(roster: Array) -> Array:
	var out: Array = []
	for item in roster:
		var it: Dictionary = item
		if String(it.get("source", "config")) == "config":
			continue
		out.append(it)
	return out


## ★★ 把**关卡 / 战役数据里的阵营颜色**登记到 config 上（由 `reset()` 在所有阵营确定之后调）。
##
## 为什么需要这一步（实测踩到）：配色表 `colors.faction.*` 里只有**内置**阵营 id
## （`p1`~`p8` / `enemy` / `ai`），而战役可以用**自己的** id（样例战役是 `F1` / `E1`）。
## 不登记的话 `cfg.faction_color("F1")` 会一路退到兜底的**品红** ——
## 症状是「整个战场一片紫、右边那些紫单位还在打我」（玩家就是这么报的）。
##
## ★ 只认**认得出来**的颜色（`"#rrggbb"` / `"rgba(...)"`）；写错的那些**跳过并警告**，
##   然后按内置配色顺序（`p1` / `p2` / …）兜底补一个 —— 宁可颜色不是设计者想要的那个，
##   也不要整场一片紫（那看起来像渲染坏了，实际只是少写一个字段）。
##
## ⚠️ `level == null` 的老路径**一个颜色都不登记**：内置 `p1`/`enemy`/… 照旧走配色表，
##   行为逐位不变（这是「不做战役的老路径不受影响」那一条在配色上的落点）。
func _register_level_colors() -> void:
	cfg.clear_faction_colors()
	if level == null:
		return
	# 颜色来源在**载入关卡时**就抄好了（`level.faction_colors`：先战役、后关卡，
	# 关卡优先）。这里只是把它登记到 cfg 上 —— 运行时不回头去问那个 Campaign 对象
	# （`Level` 不持有它，那是个引用环，见 `logic/level.gd` 的 `playable` 注释）。
	# 数据里写了的颜色：登记上去（认不出来的会自己返回 false，落到下面那次兜底）
	var ids: Array = level.faction_colors.keys()
	ids.sort()                                  # 顺序稳定（同一份数据每次跑结果一样）
	for fid in ids:
		var col := String(level.faction_colors[fid]).strip_edges()
		if col == "":
			continue
		if not cfg.register_faction_color(String(fid), col):
			push_warning("阵营「%s」的颜色「%s」认不出来（写成 #rrggbb 或 rgba(...)），已按内置配色兜底"
				% [fid, col])

	# 还没颜色的（数据里没写 / 写错了）：按内置配色顺序补一个，**并留一条痕迹**。
	# ★ 判据是「这一局真的在场」（`factions`），不是「关卡数据里提过」——
	#   地图划过的阵营、config 里的 AI 阵营也可能上场，它们同样需要颜色。
	var idx := 0
	for f in factions:
		var fid2 := String(f)
		if cfg.has_faction_color(fid2):
			continue
		var fallback_id := FactionRes.FACTION_ROSTER[idx % FactionRes.FACTION_ROSTER.size()]
		idx += 1
		var c := cfg.faction_color(fallback_id, "main")
		# ⚠️⚠️ `to_html(true)` —— **必须带 `#`**：`Config.parse_color()` 只认
		#   `"#rrggbb"` / `rgba(...)` 这两种写法，裸的 `"ffd166"` 它会判成「认不出来」，
		#   于是这次兜底登记会**静默失败**（`register_faction_color` 返回 false 而我第一版
		#   没看返回值）—— 症状与「忘了登记颜色」一模一样：整场还是品红。
		#   实测踩到：调试时 `登记完 F1 -> has=false`。
		var hex: String = "#" + c.to_html(false)
		var ok_reg := cfg.register_faction_color(fid2, hex, hex, hex)
		if not ok_reg:
			push_warning("阵营「%s」的兜底颜色「%s」也没登记上（配色表可能坏了）" % [fid2, hex])
		push_warning("阵营「%s」没有颜色（数据里没写或写错了），暂时按内置配色描一份：%s" % [fid2, hex])
		push_warning("阵营「%s」没有颜色（数据里没写或写错了），暂时按内置配色描一份：%s" % [fid2, hex])


## 这一局的盟友关系：关卡写了就用关卡的，没写就用地图的。
func _effective_allies() -> Array:
	if level != null:
		return level.effective_allies()
	if map != null:
		return map.allies
	return []


## ★★ 玩家席位的资源池（本轮新增）：**每个席位一份**，互不挪用。
##
## ★ 本机席位那一份**就是** `resources` 这个对象本身（不是副本）——
##   `resource_pool_for()` 返回它、HUD 读 `resources`、快照发它，三者天然是同一份数，
##   不需要任何「同步」代码（那种同步迟早会漏一处，而漏掉的表现是「钱对不上」）。
##
## ★ 非本机席位（合作模式的客机）**照样要开池子**：房主侧替它执行命令时要扣它的钱。
##   ⚠️ 两边都从 `cfg.start_food` / `cfg.start_gold` 起手 —— 与单机完全一致
##      （「资源各自独立」说的是**之后**各花各的，不是开局给的不一样）。
func _reset_player_pools() -> void:
	resources = {"food": cfg.start_food, "gold": cfg.start_gold}
	player_resources = {}
	for f in player_seats:
		if String(f) == my_faction:
			player_resources[String(f)] = resources
		else:
			player_resources[String(f)] = {
				"food": float(cfg.start_food),
				"gold": float(cfg.start_gold),
			}


## ★★ 关卡的开局摆放：`start_buildings` + `start_units`（**追加**在地图的预置之后）。
##
## 建筑先于单位（单位出生要找站位、要避开建筑 —— 与 reset 里那两段的顺序同理）。
##
## ⚠️ 单位的**语义与老的 `map.json` 的 `units[]` 完全一致**（那套本轮已废弃，
##    这里就是它**唯一**的入口；解析在 `level._read_start_units`）：
##    · `hold = true` → 不执行推进 AI（原地驻守）；
##    · `zone >= 0` → 交给**将领性 AI**（在自己区划里巡逻、脱战无消耗招兵），
##      ★ 同时置 `hold_position`：那条推进 AI 就不该再管它了 ——
##        两边都管会让守将「一边巡逻一边朝玩家家跑」（route.md 33.3：两者判据必须互斥）。
func _apply_level_placement() -> void:
	if level == null:
		return
	for b in level.start_buildings:
		var bd: Dictionary = b
		add_building(String(bd["type"]), int(bd["x"]), int(bd["y"]),
			String(bd["owner"]), true, true)

	# ==============================================================
	# ★★ 关卡摆放的分批规则（本轮新增，顺序是**不变量**，别改）
	# ==============================================================
	#
	# 不变量：**一位将领必须排在「它自己的兵」前面**（`world.units` 里）。
	#   原来这条靠「将领全部由 `spawn_faction_units()` 在摆放之前造好」来保证，
	#   而本轮之后「摆了附属部队的那一方**连将领都由关卡摆**」——
	#   将领与兵在 `start_units[]` 里的先后是**作者的自由**，
	#   直接按作者顺序建就会破坏不变量（兵排在将前面 → 队伍归并 / 快捷键的语义坏了）。
	# ⇒ 所以这里**按方分批**处理每一方：
	#     ① 先补这一方的将领（`_ensure_placed_generals`）——
	#        只有「这一方摆了附属部队」时才补，且只补 `escort_of` 真正点名的那几位
	#        （作者自己摆了的将领不重复建）；
	#     ② 再按作者顺序摆这一方的**其余单位**，`escort_of` 的那几个
	#        在这一步把 `leader_id` 指向①里那位将领的运行时 id。
	#   于是「将领在它自己的兵前面」在**每一方内部**都成立，
	#   而全局顺序仍然是「各方先入列顺序，再是摆放」。
	#
	# ⚠️ 没摆附属部队的那一方整段跳过：它的将领已由 `spawn_faction_units()` 造好，
	#    这一方的摆放单位照旧只是「追加在后面」（老行为一字不变）。
	_cache_placed_escorts()
	var done: Dictionary = {}
	for u in level.start_units:
		var ud: Dictionary = u
		var fid := String(ud["faction"])
		if fid == "" or done.has(fid):
			continue
		done[fid] = true
		_place_faction_units(fid, level.placed_units_for(fid))


## ★★ 把关卡 `start_units[]` 里的附属兵**数成一张表**：`"<fid>|<序号 0 起>"` → 个数。
##
## ★ 读它的是 AI 的补员目标（`escort_target_of()`，一帧一次、每方每位将领一次），
##   而 `start_units` 可能有几百项 —— 每次现扫是 O(单位数 × 将领数)。
## ★ 在 `_apply_level_placement()` 的**建单位之前**调一次（那时 `level.start_units`
##   已经解析完，而 `placed_escorts` 在 `reset()` 开头刚被清空）。
## ⚠️ 只统计 `escort_of >= 1` 的那些（= 真正的附属兵）；普通摆放单位不进表。
func _cache_placed_escorts() -> void:
	placed_escorts = {}
	faction_escort_placed = {}
	if level == null:
		return
	for u in level.start_units:
		var ud: Dictionary = u
		var ei := LevelRes.escort_leader_index(ud)
		if ei < 0:
			continue
		var fid := String(ud.get("faction", ""))
		var key := "%s|%d" % [fid, ei]
		placed_escorts[key] = int(placed_escorts.get(key, 0)) + 1
		faction_escort_placed[fid] = true


## 把**某一方**在关卡里摆的单位全部建出来（先将领、后其余 —— 见上面的分批说明）。
##
## ★★ 关卡里**摆出来的将领**用 `create_general()` 造（不是普通的摆放单位）：
##    只有这样才能拿到 **canonical 的运行时 id**（`general-1` / `general-F1-2`…）——
##    而 `escort_of` 的映射（`escort_of_index()`）算的就是这个 id。
##    第一版按普通单位造（id = `level-N`），于是附属兵算出来的队长 id **谁都不认识**，
##    场上表现为「将领与它的兵各站各的」（实测：样例战役 F1 的 15 个兵全挂空）。
##    ⚠️ 名字（`name`）/ 坐标（`x,y`）仍然**以关卡数据为准**（作者摆在哪、叫什么就是什么）。
##
## @param placed 这一方在 `start_units[]` 里的那几条（`level.placed_units_for(fid)`）
func _place_faction_units(fid: String, placed: Array) -> void:
	_ensure_placed_generals(fid, placed)
	for u in placed:
		var ud: Dictionary = u
		var kind := String(ud["kind"])
		var tile := Vector2i(int(ud["x"]), int(ud["y"]))
		var uname := String(ud.get("name", ""))
		if uname == "":
			uname = kind
		var pu = null
		var is_placed_general := ConfigRes.general_index_of(kind) >= 0
		if is_placed_general:
			# ★ 作者自己摆的将领：canonical id + 那个 id 对应的将领槽位。
			var gi_g := int(ud.get("general_index", 1)) - 1
			var utype_g := String(ud.get("unit_type", ""))
			var pg = create_general(fid, gi_g)
			if pg != null:
				# ⚠️ 只有「没写 `unit_type`」时才用 config 那一档的类型（写了就以作者为准，
				#    否则 id 与槽位对得上、兵种却被换掉，读的人会以为数据没生效）。
				if utype_g != "" and utype_g != String(pg.unit_type):
					pg = UnitRes.create(cfg, pg.id, uname, tile, fid, kind,
						str(gi_g + 1), "", utype_g, gi_g)
				else:
					pg.name = uname
					pg.pos = GridRes.center_of(tile)
					pg.tx = tile.x
					pg.ty = tile.y
				pu = pg
		if pu == null:
			# ★★ 附属兵（`escort_of >= 1`）：队长 id 在这一步落定 —— 这就是
			#    「`escort_of` → 运行时 `leader_id`」的**那一行**（见 `escort_of_index`）。
			var ei := LevelRes.escort_leader_index(ud)
			var leader_id := ""
			var leader = null
			if ei >= 0:
				leader_id = escort_of_index(fid, ei)
				leader = unit_by_id(leader_id) if leader_id != "" else null
				if leader == null:
					push_warning("关卡摆放的附属兵 (%d,%d) 的 escort_of = %d 指向的将领不在场，已按普通单位摆放"
						% [int(ud["x"]), int(ud["y"]), ei + 1])
			# ★★ 附属兵的**类型跟随队长**（与老 `create_escort` 同一条口径：
			#    「长枪兵将领带长枪兵」）。作者没填 `unit_type` 时这一步才生效；
			#    填了就以作者为准（沿用「摆放单位自带类型」这条老行为）。
			var utype := String(ud.get("unit_type", ""))
			if utype == "" and leader != null:
				utype = String(leader.unit_type)
			# ★★ 附属兵**不吃将领的数值覆盖**：`general_index` 传 `-1`。
			#    它只是个兵 —— 把 `general_index` 传成将领的序号会让它套上
			#    `unit.general.stats` 那一份覆盖（血量 / 伤害白白变强），
			#    而老 `create_escort` 造的兵**从来就没有**覆盖（那一个参数用的默认值 -1）。
			var gi := -1
			if ei < 0:
				gi = int(ud.get("general_index", 1)) - 1
			_enemy_serial += 1
			pu = UnitRes.create(
				cfg, "level-%d" % _enemy_serial, uname,
				tile, fid, kind, "", leader_id, utype, gi
			)
			# ★ 归属区划**继承队长**（与老 `create_escort` / `_spawn_from_recruit` 同一条口径）：
			#   队长有归属 ⇒ 兵也有（跟着队长巡逻、受同一个区划约束）；
			#   队长没有 ⇒ 兵也没有（`-1`）。⚠️ 只在作者没显式写 `zone` 时继承。
			if leader != null and int(ud.get("zone", -1)) < 0:
				pu.garrison_zone_id = int(leader.garrison_zone_id)
		pu.hold_position = bool(ud.get("hold", false))
		var gz := int(ud.get("zone", -1))
		if gz >= 0:
			pu.garrison_zone_id = gz
			pu.hold_position = true
		if String(ud.get("ai", LevelRes.AI_NONE)) == LevelRes.AI_GENERAL:
			# ★ `ai: "general"` **必须**同时给 `zone`（校验第 12 条会拦）。
			#   这里再兜一次：真漏写了也不让它变成「有 AI 脑子但没有归属」的怪物。
			if pu.garrison_zone_id < 0:
				push_warning("关卡摆放的将领 (%d,%d) 挂了将领性 AI 却没有 zone，已按不挂处理"
					% [int(ud["x"]), int(ud["y"])])
		# ★★ **玩家的单位不许自带 AI**（本轮新增，与 `_assign_garrison_zones` 开头那条是一对）：
		#   本机在操作的那一方，摆在关卡里的单位**一律不带归属区划 / 不置 hold_position** ——
		#   数据里写了 `zone` / `ai: general` 也不带。上面那几句已经把 AI 状态挂上了，
		#   这里**最后撤掉**（放在最末，于是「将领」与「普通单位」两条路都被覆盖）。
		#
		#   为什么必须在**这里**也拦一道（有实测）：关卡的 `start_units[]` 是**数据**，
		#   而「这一方这一局归谁操作」是**运行时**才知道的 —— 同一份数据，玩家选它时
		#   那些单位是玩家的兵，玩家不选它时才该由 AI 接管。只在 `_assign_garrison_zones`
		#   里拦拦不住这条路（那条只管「没写 zone 的兜底」，显式写了 zone 的走这里）。
		#   ⚠️ 判据与那一条**必须是同一份口径**（`_is_player_piloted`），改一处就一起改。
		if _is_player_piloted(fid):
			if int(pu.garrison_zone_id) >= 0 or pu.hold_position:
				pu.garrison_zone_id = -1
				pu.hold_position = false
		units.append(pu)


## ★★ **这一方由关卡接管时**，把作者点名要用、却没自己摆的将领补出来。
##
## 判据（与 `spawn_faction_units` 里那条**同一份口径**）：
## 这一方在 `start_units[]` 里**有任何一项带 `escort_of`** ⇒ 整方由关卡接管 ⇒
## 运行时不再自动生成 3 位将领，这里只补 `escort_of` 真正点名的那几位
## （第 1 位 / 第 2 位 / …，序号**不连续也没关系**：要哪一位补哪一位）。
##
## ⚠️ 作者**自己摆了的**将领不重复建：按 `kind` 的将领序号去重
##    （`general_index` 由 `_read_start_units` 按 kind 补齐，
##      所以「摆了 kind: general_3」就说明第 3 位有人了）。
## ⚠️ 没摆附属部队的那一方**整段不进来**：它的 3 位将领由 `spawn_faction_units()`
##    照旧自动生成（这就是口径第 5 条的后半句）。
func _ensure_placed_generals(fid: String, placed: Array) -> void:
	if not level.faction_has_placed_escorts(fid):
		return
	var have: Dictionary = {}
	var want: Dictionary = {}
	for u in placed:
		var ud: Dictionary = u
		var ei := LevelRes.escort_leader_index(ud)
		if ei >= 0:
			want[ei] = true
		elif ConfigRes.general_index_of(String(ud.get("kind", ""))) >= 0:
			have[int(ud.get("general_index", 1)) - 1] = true
	var indices: Array = want.keys()
	indices.sort()
	for i in indices:
		var idx := int(i)
		if have.has(idx):
			continue
		var g = create_general(fid, idx)
		if g != null:
			units.append(g)


## ★★ **运行时**一位将领的 id 前缀（`general` = 默认那一方，其余 `general-<faction>`）。
##
## ★★ 它是「`escort_of` → `leader_id`」这套映射的**基石**，所以收成**一处**：
##    `create_generals` / `create_general`（造 id）与 `escort_of_index`（算 id）
##    必须用同一个前缀 —— 两边各写一份的话，改了命名规则就会「附属兵挂不上队长」，
##    而那种错在场上表现为「几个兵自己站着」，极难联想到 id 拼写。
static func general_id_prefix(fid: String) -> String:
	return "general" if fid == FactionRes.DEFAULT_FACTION else "general-%s" % fid


## ★★ `escort_of` → **该将领的运行时 id**（本轮映射的出口）。
##
## @param fid   阵营 id（编制与将领都是**按方**的）
## @param index 将领序号，**0 起**（与 `unit.general_index` 同规）
## @return `general-<fid>-<index+1>`（默认那一方是 `general-<index+1>`）；
##         序号 < 0 或阵营为空 → `""`（= 没有这位将领）
##
## ★ 造 id 的规则**不在这里重复实现**：它就是 `create_general` 用的那一条
##   （`general_id_prefix()` + 序号），所以「谁是谁」不会两处漂开。
func escort_of_index(fid: String, index: int) -> String:
	if fid == "" or index < 0:
		return ""
	return "%s-%d" % [general_id_prefix(fid), index + 1]


## ★★ **这一方第 `index` 位将领（0 起）的目标编制** —— AI 的补员目标与「满员」判据都读它。
##
## 两个来源，按**这一方有没有在关卡里摆过附属部队**分：
##
##   · 摆过（`faction_escort_placed[fid]`）→ **关卡摆了几个就是几个**。
##     这让作者「摆了 0 个」变成一条明确的指令（别擅自给它补兵），
##     `ai.faction.min_retinue` 在这条路上**不参与**。
##
##   · 没摆过 → 退到这一方的 `ai.faction.min_retinue`（config 打底、关卡可覆盖），
##     0 或负数时才真的是 0。
##
## ★★ 为什么必须有第二条（实测回归，2026-10 手玩报回来的）：
##    只有第一条时，**没摆附属兵的一方**（最典型的就是**自由对战 / 自动生成将领**的
##    AI，以及作者故意只摆了将领的关卡）目标编制恒为 **0** ⇒ `faction_ai` 的
##    「闲着的将领都满员了吗」当场成立 ⇒ **AI 一个兵都不招、开局第 1 帧就出征**。
##    症状就是玩家报的那句「红方的将领没有招满单位就向目标点行军攻击了」。
##    旧世界里那件事由 `config.json` 的 `unit.general.escort` 兜着，
##    那个全局缺省被删掉之后，兜底责任落在 `min_retinue` 身上 —— 它本来就是这个语义
##    （「至少补到几个」），只是以前被 `max(编制, min_retinue)` 埋在下面看不出来。
##
## ⚠️ `index < 0`（非将领）→ 0：没有「这位将领」，也就没有目标编制。
func escort_target_of(fid: String, index: int) -> int:
	if fid == "" or index < 0:
		return 0
	if faction_escort_placed.has(fid):
		var n: Variant = placed_escorts.get("%s|%d" % [fid, index], 0)
		return int(n)
	# 这一方没摆过附属部队 → 用这一方的 min_retinue 当目标（0 / 负数 = 不要求补员）
	return maxi(0, int(faction_ai_cfg(fid).get("min_retinue", 0)))


## ★★ **这一关（整份关卡数据）里有没有摆过任何附属部队**（`escort_of`）。
##
## ⚠️ 它**不是**「该不该按关卡编制」的判据（那是 `world.level != null`）：
##    两者在「有关卡、但谁都没摆附属兵」这一档上都是 false，
##    而那一档**仍然应该听关卡的**（关卡作者写的 `min_retinue` 要生效）。
##    留这个函数是因为它读起来比「去翻两张私有表」清楚，也方便测试与排查。
func has_placed_escorts() -> bool:
	return not faction_escort_placed.is_empty()


## ★ 建出**一位**将领（第 `index` 位，0 起）——`create_generals` 的单件版。
##
## ★★ 为什么要拆出单件版：本轮之后「摆了附属部队的那一方」的将领是**按需补**的
##    （只补 `escort_of` 真正点名的那几位，见 `_ensure_placed_generals`），
##    所以「一次造 3 位」那条路不能复用。两条路共用这一个函数 ⇒ 名字 / 类型 /
##    数值覆盖 / id 规则**只有一份**。
func create_general(faction: String, index: int):
	var spawns: Array = faction_spawns.get(faction, [])
	# ★★ 名字与类型都走 config：
	#   · `cfg.general_name_at(i)` = 编辑器里给这位将领起的名字（没写 → 原来的「将领 N」）；
	#   · `cfg.general_type_at(i)` = unit.general.types[i]。
	#   ⚠️ 名字在这里读一次**存进单位**（`unit.name`）—— 部队列表、右栏都读它。
	var gname: String = cfg.general_name_at(index)
	if gname == "":
		gname = "将领 %d" % (index + 1)
	var tile: Vector2i = map.base
	if index < spawns.size():
		tile = spawns[index]
	elif index < map.general_spawns.size():
		tile = map.general_spawns[index]
	var unit_type: String = cfg.general_type_at(index)
	# ★ 最后那个参数 = **第几位将领**：它决定套不套 unit.general.stats 里那份数值覆盖
	return UnitRes.create(cfg, "%s-%d" % [general_id_prefix(faction), index + 1], gname, tile,
		faction, UnitRes.KIND_GENERAL, str(index + 1), "", unit_type, index)


## 建立某一阵营的**开局 3 位将领**。站位取该阵营自己的出生点，退回地图默认站位，
## 最后退回大本营。
##
## ★★ 将领 = **带单位类型的队长**（不是一种兵种，见 config.json 的 unit._general_comment）：
##   · 第 i 个将领的类型取 `cfg.general_type_at(i)` —— 于是「将领 1 = 长枪兵、
##     将领 2 = 长弓兵、将领 3 = 骑手」（用户需求）；它的血量 / 伤害 / 射程 / 速度
##     也全部等于那个类型的数值（`UnitRes.create` 里按 unit_type 查表）。
##   · ★★ **开局不带任何附属兵**（本轮口径变更）：编制不再有全局缺省，
##     开局有几个兵完全等于关卡 `start_units[]` 里摆了几个
##     （见 `create_escort` 已删除的说明与 `spawn_faction_units` 的判据）。
## ⚠️ 顺序有讲究：**将领先全部入列，附属兵跟在后面**。
##    这样 world.units 里前几个永远是将领（快捷键 1/2/3 与按序号取将领的代码都靠它），
##    而**关卡摆的**附属兵也不再破坏这条（见 `_place_faction_units` 的分批规则）。
func create_generals(faction: String) -> Array:
	var out: Array = []
	for i in 3:
		var g = create_general(faction, i)
		if g != null:
			out.append(g)
	return out


## ⚠️ 这里原先有两条**本轮整个删掉**的东西：
##   · `escort_count_at(fid, index)` —— 开局编制的唯一口径（关卡 `factions[].general_escort`
##     优先、没写回退 `config.json` 的 `unit.general.escort`）；
##   · `create_escort(faction, leader, pending)` —— 按那个编制**自动生成**附属兵。
## 新口径下两条都**没有存在意义**：开局附属兵完全由关卡 `start_units[].escort_of`
## 逐兵摆出来（映射见 `escort_of_index()`），「这一方第 i 位将领该带几个」这个问题
## 只由 `escort_target_of()` 回答（= 关卡里摆了几个），AI 的补员目标读的也是它。


## ★★ 某一方的阵营 AI 参数（**关卡按阵营覆盖**的唯一入口）。
##
## = `config.json` 的 `ai.faction` 打底，关卡那一方的 `faction_ai` **逐键覆盖**。
##
## ★ 为什么要按阵营分开：难度旋钮 = 资源倍率 + **该方自己的** AI 参数
##   （dev_plan_7 1.3.4）—— 一只 AI 一个节奏，而不是全局一套。
## ★ 白名单式的读取：只认 config 里**定义过**的那些键，关卡写多出来的键**不进结果** ——
##   免得一个拼错的键静默地什么都不做（那是「配了但没生效」这类最难查的问题）。
func faction_ai_cfg(faction: String) -> Dictionary:
	var out := cfg.ai_faction_cfg().duplicate(true)
	var ov: Variant = _ai_override_of(faction)
	if typeof(ov) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = ov
	for k in out.keys():
		if src.has(k):
			out[k] = src[k]
	return out


## 这一方的**将领性 AI** 参数（关卡覆盖 → 全局 `ai.general`）。
func general_ai_cfg(faction: String) -> Dictionary:
	var out := cfg.ai_general_cfg().duplicate(true)
	for e in ai_roster_cfg:
		var it: Dictionary = e
		if String(it.get("id", "")) != faction:
			continue
		var ov: Variant = it.get("general_ai", null)
		if typeof(ov) != TYPE_DICTIONARY:
			return out
		var src: Dictionary = ov
		for k in out.keys():
			if src.has(k):
				out[k] = src[k]
		return out
	return out


## 这一方在关卡数据里的 `faction_ai` 覆盖（没有 → null）。
func _ai_override_of(faction: String) -> Variant:
	for e in ai_roster_cfg:
		var it: Dictionary = e
		if String(it.get("id", "")) == faction:
			return it.get("faction_ai", null)
	return null


## 这一方在合并名单里的那一条（没有 → null）。
func ai_entry_for(faction: String) -> Variant:
	for e in ai_roster_cfg:
		var it: Dictionary = e
		if String(it.get("id", "")) == faction:
			return it
	return null


## 这一方的难度倍数（`resource_mult`；没有 → 1.0）。
func resource_mult_of(faction: String) -> float:
	var e: Variant = ai_entry_for(faction)
	if e == null:
		return 1.0
	return float((e as Dictionary).get("resource_mult", 1.0))


## ★★ 这一方的**行军攻击目标**（关卡写了才有；没写 → null，由 AI 退回现状挑选逻辑）。
##
## 返回的是**目标格**（Vector2i），四种 `attack_target.kind` 都在这里解析：
##
## | kind | 载荷 | 目标点怎么算 |
## |---|---|---|
## | `zone` | `zone` | 该区划的**中心格**（与现有 `_attack_target()` 取的是同一种点）|
## | `point` | `x`,`y` | 直接是这一格 |
## | `building` | `x`,`y` | 这一格上的建筑（先靠近再拆）|
## | `base` | `faction` | 某一方的大本营所在格 |
## | 不写 | — | **现状**（AI 自己挑最近的敌方区划中心 → 敌方大本营）|
##
## ⚠️⚠️ **不可达就返回 null**（由调用方退回现状挑选逻辑）：`attack_target` 解析出来的
##    目标必须过一遍「能不能走到」——否则会出现「AI 对着一个走不到的点原地发呆」
##    （这类症状在 HTML 版出现过，见 dev_plan_7 3.3 第 2 条）。
##    「可达」的判据用 `PathfinderRes.nearest_reachable()`：它找不到任何能站的格子就返回 null。
func level_attack_target(faction: String) -> Variant:
	var e: Variant = ai_entry_for(faction)
	if e == null:
		return null
	var spec: Variant = (e as Dictionary).get("attack_target", null)
	if typeof(spec) != TYPE_DICTIONARY:
		return null
	var tile: Variant = _resolve_attack_tile(spec as Dictionary)
	if tile == null:
		return null
	var t: Vector2i = tile
	if map == null or buildings == null:
		return t
	# ⚠️ 不可达 → null（退回现状）。判据与寻路同一套：nearest_reachable 找不到就返回 null。
	var ok = PathfinderRes.nearest_reachable(
		map, buildings, cfg, t, t, faction, 3, crowd)
	if ok == null:
		return null
	return t


## 把一条 `attack_target` 配置解析成目标格（不做可达性判断 —— 那一步在 `level_attack_target`）。
## 解析不出来（区划没有中心 / 那格没有建筑 / 那一方没有大本营）→ null。
func _resolve_attack_tile(spec: Dictionary) -> Variant:
	var kind := String(spec.get("kind", ""))
	if kind == LevelRes.TARGET_POINT or kind == LevelRes.TARGET_BUILDING:
		var x := int(spec.get("x", -1))
		var y := int(spec.get("y", -1))
		if x < 0 or y < 0:
			return null
		if kind == LevelRes.TARGET_BUILDING:
			# 「这一格上的建筑」：没有建筑就解析不出来（数据写错了，退回现状比原地发呆好）
			if building_at(x, y) == null:
				return null
		return Vector2i(x, y)
	if kind == LevelRes.TARGET_ZONE:
		var zid := int(spec.get("zone", -1))
		if zones == null or zid < 0:
			return null
		var z = zone_by_id(zid)
		if z == null:
			return null
		var c: Variant = (z as Dictionary).get("center", null)
		if c == null:
			return null
		return c
	if kind == LevelRes.TARGET_BASE:
		var fid := String(spec.get("faction", ""))
		if fid == "":
			return null
		var b = find_base_of(fid)
		if b == null:
			return null
		return Vector2i(int(b.tx), int(b.ty))
	return null


## ★★ 把配置给的大本营点位登记进地图（**不看 `with_ai`**）。
##
## ★ 为什么这一段不能跟着 AI 开关一起关掉（实测踩过，症状很隐蔽）：
##   `map.spawn_layout_for()` 对「地图没指定大本营、又不是主阵营」的一方会走
##   `pvp_points` 兜底；那张表在这张地图上是空的 ⇒ 大本营落到 **(0,0)**。
##   而 (0,0) 正好是区块 11 的中心格 —— 于是那栋**中立障碍建筑建不出来**，
##   玩家在那一块地上永远点不开区划详情（只有一条 push_warning 的痕迹）。
##   所以：**只要这一方会进名单，就必须有基地点位**，与它有没有 AI 无关。
##
## ★ 玩家席位（p1…p8）也照登记：地图里写过的阵营基地优先（`set_faction_base`
##   会覆盖，而配置里的值本来就是照地图抄的）；配置里没写的玩家席位不动。
func _register_config_bases() -> void:
	if map == null:
		return
	# ★★ 遍历的是**合并后**的名单（`_setup_ai_factions` 里算好的 `ai_roster_cfg`）：
	#    关卡显式写了大本营的那些**已经**由 `level.merge_over_map()` 写进 `map.faction_bases`
	#    （那里是覆盖规则的唯一实现）；这里补的是「config 给了点位、关卡没提」的那一档。
	for e in ai_roster_cfg:
		var entry: Dictionary = e
		var fid := String(entry.get("id", ""))
		if fid == "":
			continue
		var base: Vector2i = entry.get("base", Vector2i(-1, -1))
		if base.x >= 0 and base.y >= 0:
			map.set_faction_base(fid, base)


## ★★ 某一方的资源池：**玩家那一方**走 `resources`，其余（NPC / AI）走 `ai_resources`。
##
## ★ 这是「谁下单、扣谁的钱」的**唯一判据** ——
##   招募（将领 / 区划）与退款、以及 AI 的升级扣费全部问它，
##   所以「AI 招兵花玩家的钱」这类串味在结构上就不可能发生。
## ★ 为什么返回的是**可变字典**而不是副本：调用方（EconomyRes.spend / tick）就是要就地扣钱。
##   返回副本会让扣费静默失效（一个最难发现的错）。
##
## ★★ 返回 **null = 「这一方没有资源池」= 资源无限**（不是「没钱」）。
##
## 这条语义来自需求里将领性（防御性）AI 那句：「其没有资源库，没有大本营……
## 会无资源消耗地招募单位（**或者可以认定该类 AI 资源无限**）」。
## 于是：
##   · `EconomyRes.can_afford(null, cost)` 这类查询在调用方要**当作通过**
##     （见 `can_afford_recruit` / `can_afford_zone_recruit` 里的判空）；
##   · `EconomyRes.spend(null, cost)` 是空操作 —— 它先过 `can_afford`（null 上取不到键
##     ⇒ 有消耗就判不过 ⇒ 直接返回 false），所以根本不扣任何东西。
## ⚠️ 玩家那一方**永远有池子**（`resources`），所以「null = 无限」不会被玩家走到；
##    而 NPC 阵营本来就不该有预算 —— 漏建池子不该表现为「这个 AI 一动也不动」。
func resource_pool_for(faction: String) -> Variant:
	# ★★ **被 AI 接管的本地席位**（一关两个可玩阵营、玩家选了另一个）：
	#    它的钱走 **AI 池**（`ai_resources`），不是玩家池 ——
	#    否则「AI 下单扣谁的钱」就说不清了（它会在玩家钱包与 AI 池之间来回切）。
	#    ⚠️ 判定顺序不能反：这一段必须排在下面那条 `player_factions` 之前，
	#       否则未选中的那一方会先被当成玩家、拿到一个由本地输入在写的钱包。
	if _is_ai_piloted(faction) and not player_factions.has(faction):
		return ai_resources.get(faction, null)
	# ★★ 本地席位（本机负责的那几个）：**每个席位各一份**（合作模式每人一个钱包）。
	#    ⚠️ 判据用 `player_seats`（本机的 roster）而不是 `is_player_faction`：
	#       后者认的是 p1…p8 这一整张常量表 —— 单机时如果一个测试把 enemy 当成
	#       「本地席位」跑，那条判据会给它一个不存在的池子。
	#    ⚠️ 本机席位那一份与 `resources` 是**同一个字典对象**（见 reset 的说明），
	#       所以这里直接返回它就等于「HUD 看到的钱」。
	if player_seats.has(faction):
		var mine: Variant = player_resources.get(faction, null)
		if typeof(mine) == TYPE_DICTIONARY:
			return mine
		return resources
	return ai_resources.get(faction, null)


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

	# 3) 大本营 + 防御阵地（silent：不写日志、不逐个重算区块归属；
	#    ★ instant：**开局自带的东西一律直接完工** —— 建造读条只属于玩家下达的建造命令，
	#      否则开局的大本营要先傻站几秒（而 config 里 build_sec 默认就是 0，两者不冲突）
	add_building(BuildingRes.TYPE_BASE, base_tile.x, base_tile.y, faction, true, true)
	for d in (layout["defenses"] as Array):
		add_building(String(d["type"]), int(d["x"]), int(d["y"]), faction, true, true)
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


## 给某一方建出**将领**（站位避开建筑与已有单位）。
##
## ★ 必须**在所有建筑都就位之后**调用（见 reset() 的顺序说明）。
##
## ★★ 这里**不再有任何开局附属兵**（本轮口径变更）：`create_escort()` 整个删掉了。
##    理由「所见即所得」—— 开局场上有多少兵，必须**完全等于**关卡 `start_units[]`
##    里摆出来的那些。于是：
##      · 关卡摆了那一方的附属部队（`escort_of`）⇒ 那一方**整个跳过**本函数
##        （连 3 位将领都归作者摆，见下面的判据）；
##      · 关卡没摆 ⇒ 本函数照旧造 3 位将领，而他们**光杆**（0 个附属兵，
##        不再有任何「全局缺省编制」可补）。
##
## ★★ 判据是 `level.faction_has_placed_escorts(faction)`（= 这一方在关卡
##    `start_units[]` 里**有任何一项带 `escort_of`**）：
##    摆了就整方由关卡接管 —— 将领与附属兵**都不自动生成**。
##    ⚠️ 用它而不是「这一方有没有摆单位」：「摆了一个守将」是既有的、与附属兵
##       无关的用法（驻防将领就靠它），拿它当接管判据会连带删掉三位将领。
##    ⚠️ `level == null`（不做战役 / 绝大多数测试）⇒ 照旧自动生成 3 位。
##
## ★★ 还有一条**与 AI 无关**的历史约束（保留）：不开 AI 的那一局
##    （`with_ai = false`：测试 / 基准）里，NPC 阵营**一个将领都不建**。
##    理由：把 NPC 阵营加进名单之后，一个**只有玩家 + 地图摆设**的干净世界就会多出
##    三个将领、三份招募状态、以及「它们站在哪一格」这一整套副作用 ——
##    而那一整套断言（「开局 3 个将领」「场上有 22 个单位」）在几十个测试里都有，
##    它们验的是移动 / 碰撞 / 迷雾，不是 AI。
##    ⚠️ 注意这里跳掉的只是**将领**：NPC 的**地**（zone_list[].owner）与**大本营**
##       照旧成立（那两样是「这一局的布局」，与 AI 开关无关）。
##    于是「把 enemy 写进名单」在两种世界里只差「它有没有军队」，
##    而两支军队的有无正好由 with_ai 决定 —— 这就是那个开关的定义。
func spawn_faction_units(faction: String) -> void:
	if not with_ai and not FactionRes.is_player_faction(faction):
		return
	# ★★ 这一方在关卡里摆了附属部队 ⇒ **整方由关卡接管**：这里什么都不造。
	#    （将领由 `_apply_level_placement()` 按 `escort_of` / `general_index` 补出来，
	#      附属兵由作者逐兵摆好 —— 见那个函数里的分批说明。）
	#
	# ⚠️ 判据与「谁在操作这一方」「是不是 AI 驱动」**全都无关**：
	#    这就是本轮口径第 3 条 —— 谁摆了附属兵就给谁（AI 摆的也照样出现），
	#    于是原来那句 `with_escort = (faction == my_faction)` 与传给
	#    `create_generals` 的那个参数**整个删掉了**。
	if level != null and level.faction_has_placed_escorts(faction):
		return
	# ★ 记下「本函数造出来的那一段是从哪开始的」：下面兜底归属区划时只许扫这一段，
	#   不许回头扫前面 `reset()` 已经放好的单位（理由见 `_assign_garrison_zones` 的 `from`）。
	var created_from: int = units.size()
	for u in create_generals(faction):
		units.append(u)
	# ★★ 挂**将领性（守家）AI** 的那一方：给每位将领一个**归属区划**。
	#
	# 为什么需要这一步（实测）：`logic/general_ai.gd` 的一切行为都以
	#   `garrison_zone_id >= 0` 为前提 —— 巡逻、警戒、脱战招兵全在「自己的区划里」。
	#   而它平时只由**关卡的摆放**（`start_units[].zone`）赋值，于是「一整个阵营
	#   挂 `ai: "general"`」这种配置下，它的将领一个归属区划都没有
	#   ⇒ 那一方**从头到尾一动不动**（实测：选红方时蓝方 18 个单位站着不动，
  #     区划归属还从 3 块掉到 2 块 —— 完全没有守家行为）。
	# ⇒ 兜底取「它出生那一格所在的区划」当归属（大本营落在哪块地，就守哪块地）。
	#   ⚠️ 已经有归属的（关卡显式写了 `zone`）绝不动它。
	#
	# ★★ **「选边关」里再加一条**：如果这一局的目标是「攻占某个区划」（`capture_zone`），
	#    那守方 AI 的归属就取**那个区划** —— 它是设计者指定的争夺点，守方当然要守那儿。
	#    实测（不加这一条）：守方 AI 的归属取的是它大本营所在的 a1，于是它**离开 c1**
	#    往北去打对手的家，把目标区划空着 ⇒ 玩家选红方时**27 秒**就白捡了胜利，
	#    而选蓝方时红方 AI 又一路平推（两边都不对）。
	if _is_garrison_ai(faction):
		_assign_garrison_zones(faction, created_from)


## ★★ 给「挂将领性 AI 的那一方」中**还没有归属区划的带队单位**兜底一个归属（本轮收口）。
##
## 为什么要这一步（实测）：`logic/general_ai.gd` 的一切行为都以 `garrison_zone_id >= 0`
##   为前提 —— 巡逻、警戒、脱战招兵全在「自己的区划里」。而它平时只由**关卡的
##   摆放**（`start_units[].zone`）赋值，于是「一整个阵营挂 `ai: "general"`」这种配置下，
##   它的将领一个归属区划都没有 ⇒ 那一方**从头到尾一动不动**。
##
## ★★ 「不用手摆巡逻点」也落在这一句上（需求原话）：归属取**它脚下那一格所在的区划**
##   （`_zone_id_at`）—— 摆在哪块地就守哪块地，**巡逻路线再由区划自己算**
##   （见 `general_ai._build_route`）。关卡里写 `zone` 仍然是优先的（显式覆盖）。
##
## ★★ `from` = 从第几个单位开始扫，**必须是「这一批新造出来的单位」的起点，不能是 0**。
##   理由：这一步会**无条件**给扫到的带队单位安上归属 + `hold_position = true`，
##   而一个单位只要有了归属，`enemy_ai`（推进 AI）就不该再管它了 ——
##   「没写 `zone` 的推进型单位」被这一步收编就会当场变成**原地不动**，
##   症状是「这张图上的敌人突然不来了」，而且只在引擎侧看得见。
##   （★ 本轮把地图 `units[]` 废弃之后，会被「误收编」的候选只剩**各方的将领**：
##     它们由 `spawn_faction_units()` 自己的收尾处理，各调用点传的 `from` 都排在
##     那一段之后 —— 这条约束仍然要留着，改顺序 / 加摆放入口时先看这里。）
##   所以调用点一律传「本方这一轮**新造出来**的那些单位」的起点。
##
## ★★ 只给**带队的那些**兜底（`leader_id == ""`）：
##   巡逻是「一个队长带队、兵跟着走」（见 `general_ai.is_patrol_leader`），
##   给附属兵也安上归属不但没用，还会让巡逻计数把同一块地数成好几个人。
func _assign_garrison_zones(faction: String, from: int) -> void:
	# ★★ **本机在操作的那一方，永远不许被将领性 AI 接管**（本轮新增，见 `_is_player_piloted`）。
	#   这一条是「基本原则」在引擎侧的落点：**玩家的单位不许自带 AI** ——
	#   数据写错了（比如把守军写成玩家的阵营又挂了 `zone` / `ai: "general"`）也不该发生。
	if _is_player_piloted(faction):
		return
	var anchor := _objective_zone_for_ai()
	for i in range(maxi(0, from), units.size()):
		var u = units[i]
		if String(u.faction) != faction:
			continue
		if String(u.leader_id) != "":
			continue
		if int(u.garrison_zone_id) >= 0:
			continue
		u.garrison_zone_id = anchor if anchor >= 0 else _zone_id_at(u.tx, u.ty)
		u.hold_position = true


## ★★ 这一方这一局是不是**本机在操作**的（= 玩家的单位）。
##
## 用途只有一处：上面那些「给 AI 的归属区划」必须**绕开玩家** —— 玩家的单位一旦拿到
## `garrison_zone_id`（`unit.is_garrison()` 就会为真），将领性 AI 就有权指挥它：
## 巡逻、警戒、脱战招兵全都会作用在**玩家自己的部队**上。实测症状：
## 关卡里把守军写成玩家阵营 + `zone`，玩家选那一方时那些单位就带着 AI 状态
## （探针：6/6 都挂着 `garrison_zone_id`），指挥权与 AI 的输入会互相覆盖。
##
## ★★ 判据**只有 `my_faction`**（本机正在操作的那一方）—— 单机 / 房主都是它。
##   ❌ **不要**把 `player_seats` 也算进来（试过，是错的）：选边关的 roster 是
##      `[我选的那一方, 敌人那一方]`（两边的家都要建），把整份名单排掉会把**由 AI 接管的
##      那一边**也一起排掉 ⇒ 它的将领拿不到归属区划 ⇒ 那一方一动不动、一波兵都不出。
##      实测（渡口争夺）：玩家选 F1 时 F2 全场只剩 **4** 个单位、150 秒都摸不到目标。
##   ✅ 那一边本来就该由 AI 接管（数据里写了 `ai: "faction"` / 单位的 `zone`），
##      所以这里**只**保护玩家自己那一方。
func _is_player_piloted(faction: String) -> bool:
	return faction != "" and faction == my_faction


## 这一方虽然挂着 AI，但**开局照样给附属兵**吗？
##
## ★★ 为什么需要这一条（实测）：一关可以有两个**可玩**阵营（玩家选一个、另一个
##    由盟友 AI 接管）。那种 AI 友军与 `config.ai.factions` 里的 NPC 敌人**不是一回事**：
##      · NPC 敌人（E1）要自己经营 ⇒ 开局不给兵，「招满再出兵」那个阶段才存在；
##      · AI 友军（F1 / F2 里没被选中的那一个）是**我方战线**，它要是也光杆开局，
##        几十秒内就被敌人推平 —— 而「守住某个区划」的目标正是靠这一线撑着。
##        实测症状：AI 友军只有 3 个光杆将领，目标区划 c1 当场丢掉 ⇒ 一进关就输。
##
## 判据 = **战役里标了 `playable`**（= 关卡设计者把它当玩家席位摆的那几个）。
##   ⚠️ 用「它在 `level.players[]` 里吗」**不行**：样例第一关的 `players[]` 只声明了
##      F1 一个席位（F2 是靠「可玩 + 关卡点名挂 AI」补进 roster 的），于是选 F1 时
##      盟友 F2 拿不到附属兵 —— 两个选择的难度会不对称（实测：一边 18 个单位、
##      另一边 3 个）。
##   ⚠️ 用「它在 `player_seats` 里吗」也不行：那个名单来自本局 roster，


## 这一局里，这一方是不是由**阵营性 AI** 驱动的（= 开局不给白送的附属兵）。
##
## ★ 判据的两层（顺序不能反）：
##   1. `ai_roster_cfg`（**关卡点名优先 + config 兜底**合并出来的那一份）里，
##      这一方的 `ai` 字段是不是 `"faction"`；
##   2. 名单里的条目**没有 `ai` 字段**时（config 的 `ai.factions` 与地图登记的条目
##      都是这个形状）→ 它在名单里就说明是 AI 驱动的，退回 `cfg.is_ai_faction()`。
##
## ⚠️ 两层都要有：只查 (1) 会让 `config.ai.factions` 的阵营漏判；
##   只查 (2) 就是原来那个 bug（关卡点名的阵营查不到）。
## 这一方的 AI 指派是 `ai: "general"`（将领性 / 守家 AI）吗？
##
## ★ 用途：给这一方的将领兜底一个**归属区划**（见 `spawn_faction_units` 的收尾）——
##   `logic/general_ai.gd` 的行为全部以 `garrison_zone_id >= 0` 为前提。
func _is_garrison_ai(faction: String) -> bool:
	if faction == "" or faction == my_faction:
		return false
	return ai_kind_of(faction) == LevelRes.AI_GENERAL


## (x, y) 这一格属于哪个区划（不属于任何区划 / 地图外 → -1）。
func _zone_id_at(tx: int, ty: int) -> int:
	if zones == null or map == null:
		return -1
	if not map.tile_exists(tx, ty):
		return -1
	for z in zones.zones:
		var zd: Dictionary = z
		for t in (zd.get("tiles", []) as Array):
			var p: Vector2i = t
			if p.x == tx and p.y == ty:
				return int(zd.get("id", -1))
	return -1


## ★ 这一局「守方 AI 该守哪个区划」——只对**攻占类**目标有意义。
##
## 判据：目标里只要有一条 `capture_zone`（= 有人在攻它），那个区划就是**争夺点**，
## 守方 AI（`ai: "general"` 那一方）的归属取它。
##
## ⚠️ 没有攻占类目标时返回 -1（调用方退回「按出生格所在区划」的老口径）——
##    `hold_zone` 那类关卡（守方就是玩家自己）不受影响。
func _objective_zone_for_ai() -> int:
	if level == null:
		return -1
	for o in level.objectives:
		var d: Dictionary = o
		if String(d.get("kind", "")) == LevelRes.OBJ_CAPTURE_ZONE:
			return int(d.get("zone", -1))
	return -1


func _is_ai_piloted(faction: String) -> bool:
	# ★★ **本机自己操作的那一方永远不算「被 AI 驱动」** —— 哪怕关卡数据里给它写了
	#    `ai: "faction"`。这正是「玩家选中哪一方，运行时就把那一方的 AI 摘掉」
	#    那条拍板在**这里**的落点（另一处落点是 `_setup_ai_factions` 的 continue）。
	#
	#  ⚠️ 为什么必须在**判据**这一层拦，而不是只在建 AI 名单时拦（实测踩到）：
	#     一关两个可玩阵营时，两边在数据里都写着 `ai: "faction"`（这样没被选中的
	#     那一边才会自己动）。如果这里照数据算，玩家选中的那一方也会被当成「AI 驱动」
	#     ⇒ `spawn_faction_units` 那条 `with_escort = not _is_ai_piloted(...)`
	#     就不给玩家**开局附属兵**了 —— 症状是「选中 F1 进关，自己只有 3 个光杆将领」
	#     （实测：F1 全程 3 个单位，26 秒就被 E1 推平）。
	if faction != "" and faction == my_faction:
		return false
	return ai_kind_of(faction) == LevelRes.AI_FACTION


## 这一方在这一局的 AI 指派（关卡点名优先，其余退回全局 config）。
##
## @return "faction" / "general" / "none"
##
## ★★ 为什么要按**组装期**的口径回答（实测踩到）：`my_faction` = 本机在操作的那一方。
##    「谁该被 AI 接管」在组装期与开局后**不一样**：
##      · 组装期：`my_faction` 是本机操作的 ⇒ **不**算 AI；**其余每一方**（包括
##        roster 里那些「另一个可玩阵营」）都按**它们自己的 AI 指派**算；
##      · 开局后：把 `my_faction`（本地输入在写的钱包）从 `player_factions` 里去掉。
##    `_is_ai_piloted()` 是**开局后**的判据（它里面把 `my_faction` 排除了）——
##    直接拿它回答组装期的问题会得出「没被选中的那一方也不受 AI 管」，
##    于是它拿到开局附属兵、也不建 AI 状态表 ⇒ 它站着发呆（实测：选红方时蓝方
##    18 个单位不动，区划归属从 3 块掉到 2 块）。
func ai_kind_of(faction: String) -> String:
	if faction == "":
		return LevelRes.AI_NONE
	for e in ai_roster_cfg:
		var it: Dictionary = e
		if String(it.get("id", "")) != faction:
			continue
		if it.has("ai"):
			# 关卡点名过：`"faction"` / `"general"` / `"none"` 照写读
			return String(it.get("ai", ""))
		# 名单里有、但没写 `ai`（config / 地图来的）⇒ 就是阵营性 AI
		return LevelRes.AI_FACTION
	# 不在名单里：退回全局 config（向后兼容那一条）
	if cfg != null and cfg.is_ai_faction(faction):
		return LevelRes.AI_FACTION
	return LevelRes.AI_NONE


## 围着某个队长找一格能站的位置：右、下、左、上、右下…（第 index 个方向）。
##   · `escort_count_at(fid, index)` —— 开局编制的唯一口径（关卡 `factions[].general_escort`
##     优先、没写回退 `config.json` 的 `unit.general.escort`）；
##   · `create_escort(faction, leader, pending)` —— 按那个编制**自动生成**附属兵。
## 新口径下两条都**没有存在意义**：开局附属兵完全由关卡 `start_units[].escort_of`
## 逐兵摆出来（映射见 `escort_of_index()`），「这一方第 i 位将领该带几个」这个问题
## 只由 `escort_target_of()` 回答（= 关卡里摆了几个），AI 的补员目标读的也是它。
##
## ⚠️ 注：`_ring_tile()` / `ring_offsets()` **留着** —— 招募（`_spawn_from_recruit`）
##    还在用同一条站位规则（「出生与招募共用这一份」那条约定没变）。


## 围着某个队长找一格能站的位置：右、下、左、上、右下…（第 index 个方向）。
##
## ★ 出生与招募**共用这一份**：站位规则只有一处，免得两边慢慢漂开。
##   先用正交方向是有意的 —— 正交邻格比斜角更不容易被墙 / 山挤掉。
##
## ★★ 除了「地形 / 建筑放行」，还必须**避开已经站着人的格子**（同阵营也算）。
##    这一条是加区划中心之后暴露出来的（实测）：
##    3 个将领各带 3 个附属兵、全挤在大本营周围那一圈时，`index` 撞车的两个兵
##    （general-2-3 与 general-3-1）都会落到「大本营那一格」上 ——
##    因为原来的判定只看地形与建筑，而大本营格对己方是放行的。
##    症状是「开局有两个兵叠在同一个格子上」（测试里那条「所有单位都不能站在大本营格上」
##    就是为此写的）。
##    ⚠️ 还要看 `pending`：同一批正在创建、**还没进 world.units** 的单位
##       （create_generals 是先在局部数组里攒好、最后才一次性入列的）。
##
## @param pending 本批已占位的单位（可以不传）
func _ring_tile(leader, faction: String, index: int, pending: Array = []) -> Vector2i:
	var ring := ring_offsets()
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


## 围着某一格找站位的**方向表**：右、下、左、上、四个斜角，再往外一圈。
##
## ★ 出生站位（`_ring_tile`，将领配附属兵）与区划招募的出兵格（`_zone_spawn_tile`）
##   **共用这一张表** —— 两处各写一份「先正交、后斜角」迟早会漂开，
##   而它本来就是同一条规则（「围着某个格子就近找一格能站人的地方」）。
static func ring_offsets() -> Array[Vector2i]:
	return [
		Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1),
		Vector2i(2, 0), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(0, -2),
	]


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

## 可招募兵种表（config.json 的 recruit.list）—— 右下「单位」页那一张。
## ★ 表在数据里、代码里不写死兵种名 —— 以后加兵种只加 JSON，不改这里。
func recruit_list() -> Array:
	var v: Variant = cfg.get_path_value("recruit.list")
	if typeof(v) != TYPE_ARRAY:
		return []
	return v


## ★★ 区划招募表（config.json 的 recruit.zone.list）—— 点区划中心时「招募」页那一张。
##
## 与上面那张是**两张独立的表**，别合并：
##   · `recruit.list`      → 将领当兵营：兵排进**被选中那个将领**的队列；
##   · `recruit.zone.list` → 区划当兵营：将领排进**那个区划**的队列（见 zone.gd 的字段说明）。
func zone_recruit_list() -> Array:
	var v: Variant = cfg.get_path_value("recruit.zone.list")
	if typeof(v) != TYPE_ARRAY:
		return []
	return v


## 某个兵种在**两张表里任意一张**的条目（找不到返回空字典）。
##
## ★ 查「短名 / 消耗 / 读条」这类**显示与计费**信息时走它（两张表字段完全一样）；
##   判「能不能招」时**不要**用它 —— 那要先分清是「将领招兵」还是「区划招将」，
##   分别走 is_unit_recruitable / is_zone_recruitable（否则单位页能招出将领来）。
func recruit_entry(kind: String) -> Dictionary:
	for item in recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return item
	for item in zone_recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return item
	return {}


## 某个兵种能不能被**将领**招募（单位页那张表）
func is_unit_recruitable(kind: String) -> bool:
	for item in recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return true
	return false


## 某个兵种能不能被**区划**招募（区划中心「招募」页那张表）
func is_zone_recruitable(kind: String) -> bool:
	for item in zone_recruit_list():
		if typeof(item) == TYPE_DICTIONARY and String((item as Dictionary).get("kind", "")) == kind:
			return true
	return false


## 这个兵种是不是「可招募的」（两张表任意一张里有它）。
## ★ 视图用它决定短字怎么取：招出来的将领也走招募表的 `short`（将）。
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


## 区划招募队列的上限（config.recruit.zone.queue_max；没配就退回单位那张表的上限）
func zone_recruit_queue_max() -> int:
	var v: Variant = cfg.get_path_value("recruit.zone.queue_max")
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return maxi(1, int(v))
	return recruit_queue_max()


## 第 slot 格**还要等多久**才轮到自己出人（秒）。0 = 正在读条的大格子；1..n = 排队的小格子（从前往后）。
##
## ★★ 为什么这条查询必须在**逻辑层**（而不是让 view 自己乘 train_sec）：
##    「排队的每一单各自读条多久、什么时候轮到我」是**玩法规则** ——
##    见 `_start_next_in_queue()` / `_start_training()`：一单读满就把它顶上大格子，
##    而大格子的读条时间取**它自己兵种**的 `train_sec`。视图只负责画，
##    不许自己推这条时间轴（与 pitfalls 5.20「把规则收回逻辑层」同一条规矩）。
##
## ★ 空槽位（还没排到这一格 / 下标越界）返回 0；将领不在招募同样返回 0。
## ★ 与 `train_remaining` 的关系：大格子 = 它自己的剩余秒；第 k 个小格子 =
##   大格子读完 + 它前面每一单各自的 train_sec（前移后**从头读条**也自然落在这条公式里）。
func recruit_eta(leader, slot: int) -> float:
	if leader == null or slot < 0:
		return 0.0
	var eta := maxf(0.0, float(leader.train_remaining))
	if slot == 0:
		return eta
	var q: Array = leader.train_queue
	if slot - 1 >= q.size():
		return 0.0
	for i in slot:
		eta += recruit_train_sec(String(q[i]))
	return eta


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
	if not is_unit_recruitable(kind):
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
## @return "" / "leader" / "faction" / "downed"
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
	# ★★ 濒死的将领**不能再招募**（本轮修 bug）。
	#
	# 需求/规则：进濒死时它的招募队列**整个作废并退款**（见 `enter_near_death`），
	#   所以「已经排上的」那一条不归这里管；这一句管的是**新的下单** ——
	#   它倒在原地连动都动不了，还能继续造兵的话就成了「无限续命的血包」：
	#   只要队列里还挂着人，它旗下的部队就永远不为空，全灭判定永远不成立。
	#   （实测报回来的现象：一个旗下什么都没有的濒死将领，最后又造出来一个兵。）
	# ⚠️ 判据放在这里 = 招募（将领当兵营）与**区划招募**两条路一起被挡住
	#    （`can_recruit_zone` 也走本函数）。
	if leader.is_downed():
		return "downed"
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
## （「附属队列」= 它名下那些附属兵）。
##
## ★ 判据只写这一处：命令层（`command_processor`）用它过滤，
##   输入层要用也只问它 —— 两处各写一套「谁被锁住了」迟早会漂开。
## ★ 队长已经不在场（阵亡）的附属兵**不算被锁**：它们已经各自为战了，
##   再拦着玩家就没有道理（`team_leader()` 对这种情况返回 null）。
##
## ★★ 濒死的将领（本轮新增）：它自己**被锁**（倒在原地，不能动也不能打）。
##   ⚠️ 但**只锁它自己**，不锁它辖下的部队 —— 需求里那支援军正是要照常行动
##      （它们得能走去救它、也能被玩家指挥）。所以这一条与招募那条不同：
##      招募锁整队，濒死只锁将领本人。判据落在**调用方传进来的那个单位**上。
func is_order_locked(u) -> bool:
	if u == null or not u.alive:
		return false
	if u.is_downed():
		return true
	if u.is_training():
		return true
	var leader = team_leader(u)
	return leader != null and leader.is_training()


## 这个单位现在不接受指令的**原因码**（"" = 可以下令）。
##
## ★ 为什么要单独给码（而不是让命令层猜）：`note_order_rejected` 要把拒因**报给玩家**
##   （界面按码翻中文，见 view/hud.gd 的 order_reject_text）——
##   「将领正在招募」和「将领倒在地上」给玩家的下一步动作完全不同。
func order_lock_reason(u) -> String:
	if u == null or not u.alive:
		return "dead"
	if u.is_downed():
		return "downed"
	if u.is_training():
		return "recruiting"
	var leader = team_leader(u)
	if leader != null and leader.is_training():
		return "recruiting"
	return ""


# ------------------------------------------------------------------
# ★★ 将领濒死 / 再起（本轮新增，config.json 的 revive 段）
#
# 分工（与招募那一套逐条对齐）：
#   · 规则（还允不允许、要多少钱、读条多久）在这里；
#   · 状态（回复计时 / 读条剩余）在 unit 自己身上（见 unit.gd 那组字段的说明）；
#   · 界面只发命令（command_processor 的 revive / revive_cancel）。
#
# ★★ 为什么「进濒死」要 world 来判而不是 unit 自己：判据是「旗下还有没有部队」，
#    那要看整个 world.units（unit 不能 preload world，会形成循环依赖）。
# ------------------------------------------------------------------

## 旗下还有没有存活部队（含队列里在读条 / 排队的兵）。
##
## ★ 口径与 `unit.retinue_size()` 一致，但这里只要「有没有」——
##   濒死判定每帧都要跑，不必去数总数。
func has_living_retinue(leader) -> bool:
	if leader == null:
		return false
	if not retinue_of(String(leader.id), true).is_empty():
		return true
	return leader.train_queue_size() > 0


## ★★ 试着让一个刚被打到 0 血的将领进入濒死。
##
## @return true = 已经进入濒死；false = **旗下已经一个兵都没有 ⇒ 调用方应当让它直接死**
##         （用户拍板：「无附属部队时直接死亡，不进濒死」）。
##
## ★ 进入濒死时会做两件额外的事：
##   1. 给这一方推一条 `leader_downed` 事件（界面播报 / 测试盯它）；
##   2. **把旗下部队叫回来**：解除它们现有的所有命令，改成行军攻击到**倒下点**
##      （用户原话：「其附属兵会先解除当前玩家给予的或现有的所有命令，
##      立刻行军攻击至其将领处」）。
##      ⚠️ 目标是**固定点**（`downed_anchor`）：用户拍板「将领濒死后无法移动，
##        视作倒在原地」——所以不需要跟踪一个会动的目标，走现成的
##        `order_group_attack_move` 就够了（与阵营 AI 派兵同一条路）。
##
## ★★ 顺序有讲究（本轮修 bug 时定了下来）：
##   1. **先判「旗下还有没有部队」** —— 用**队列还没作废时**的状态。
##      为什么：那一单兵**已经付过钱、也快出来了**，它当然算「这一位将领的部队」，
##      所以「队列里那一单撑着 ⇒ 将领因此没能当场死」是对的；
##   2. **队列整个作废并全额退款**（reason = `leader_downed`）——
##      它都倒下了，不能继续造兵（见下面那段实测记录）；
##   3. 进濒死。
##   ⇒ 净效果：只要「打光活兵**或**退款取消在造的兵」里**还有一条**能给出援军，
##     它就进濒死；两条都不成立时才 `return false`，由调用方让它直接死。
func enter_near_death(leader) -> bool:
	if leader == null or not leader.alive:
		return false
	if leader.downed:
		return true                   # 已经倒着了（重复调用不该再叫一次援军）
	if not has_living_retinue(leader):
		return false
	# ★★ 招募队列**整个作废并退款**（本轮修 bug）。
	#
	# 实测报回来的现象：「一个濒死的将领没有任何单位，最后还是招募了一个单位出来，
	#   我把这个单位打死之后这个将领才死」——根因就是队列没停：
	#   `_tick_recruitment` 只看 `alive`（濒死者**仍然 alive**），于是读条照走、兵照出，
	#   而那个兵又算「旗下有部队」⇒ 全灭判定永远不成立，将领靠「一直在造兵」续命。
	# ⇒ 倒下就是「停止一切生产」：撤回这一单并**全额退款**（与将领阵亡那一套同一条路，
	#   见 `_release_recruit`），于是「旗下部队全灭」那条判据又能正常生效了。
	# ⚠️ 这一步必须放在 `has_living_retinue` **之后**：上一句已经用「队列还在」的
	#   事实决定过「它能不能进濒死」了，这里只是把那一单**换成退款**。
	_release_recruit(leader, true, "leader_downed")
	leader.enter_near_death(cfg.revive_regen_sec)
	push_event({"type": "leader_downed", "unit": leader, "faction": String(leader.faction)})
	rally_retinue_to_leader(leader)
	return true


## 让某个将领辖下的存活部队**立刻向它（的倒下点）行军攻击**。
##
## ★ 走 `command_processor.order_group_attack_move`：与玩家「选中整队点地图」、
##   阵营 AI「派一批将领出征」、驻防将领巡逻是**同一条**路径（队形落点、通行判定
##   都在它里面）—— 自己写一遍循环迟早会漂开。
## ★ 已经贴着倒下点站着的兵会被它自动跳过（命令层内部判距离），不必在这里特判。
func rally_retinue_to_leader(leader) -> void:
	if leader == null:
		return
	var mates: Array = retinue_of(String(leader.id), true)
	if mates.is_empty():
		return
	var cmd: GDScript = load("res://logic/command_processor.gd")
	if cmd == null:
		return
	cmd.order_group_attack_move(self, cfg, mates, leader.downed_anchor)


## 「再起」要花多少（config.json 的 revive.cost；缺字段 = 免费）。
func revive_cost() -> Dictionary:
	return cfg.revive_cost


## 「再起」的读条秒数（config.json 的 revive.channel_sec；0 = 瞬发）。
func revive_channel_sec() -> float:
	return cfg.revive_channel_sec


## 让将领脱离濒死所需的最低血量比例（config.json 的 revive.ready_ratio，默认 10%）。
func revive_ready_ratio() -> float:
	return cfg.revive_ready_ratio


## 某个单位现在**能不能**开始再起。@return "" = 可以；否则是拒因码：
##   "leader"  / "dead"     找不到人 / 已经真的死了（死人不该走这条路）
##   "not_downed"           它没有濒死（根本没倒，或者已经再起过了）
##   "channeling"           ★ 已经在读条了（这时该走 cancel，不是再来一单）
##   "hp"                   血量还没回到 10%（界面那颗格子就是靠它置灰的）
##   "faction"              防冒充：不能替别人家的将领再起
##   "cost"                 粮食 / 黄金不够
## ★ 顺序有讲究：先「是不是这个人 / 是不是这一方」再「状态对不对」——
##   否则客机拿别人的将领 id 会先收到一条「血量不够」这种莫名其妙的原因。
func revive_reject_reason(leader, faction: String = "") -> String:
	if leader == null or not leader.alive:
		return "leader"
	if faction != "" and not FactionRes.same_side(String(leader.faction), faction):
		return "faction"
	if not leader.is_general():
		return "not_downed"
	if not leader.downed:
		return "not_downed"
	if leader.revive_remaining > 0.0:
		return "channeling"
	if not leader.revive_ready(cfg):
		return "hp"
	if not EconomyRes.can_afford(resource_pool_for(String(leader.faction)), revive_cost()):
		return "cost"
	return ""


## ★★ 开始「再起」：**先校验 → 再扣费 → 最后开始读条**（与招募三步同序）。
##
## ★★ 用户拍板的两条口径都落在这一句 `leader.start_revive(cfg)` 上：
##   · 从这一刻起该将领**被视为单位** —— 全灭判定**暂停**
##     （`unit.tick_near_death()` 里判 `revive_remaining > 0`），所以读条不会因为它
##     手下的兵死光而中断；
##   · 读条读完**不改血量**（几点血就是几点血，见 `unit._finish_revive`）。
##
## ★ 钱从**这一方自己的池子**里出（`resource_pool_for`：AI 花自己的钱；
##   池子为 null = 这一方没有资源库 = 资源无限，见那个函数）。与招募同一条语义。
func start_revive(leader_id: String, faction: String = "") -> bool:
	var leader = unit_by_id(leader_id)
	var reason := revive_reject_reason(leader, faction)
	if reason != "":
		push_event({"type": "revive_rejected", "reason": reason, "unit": leader,
			"faction": String(leader.faction) if leader != null else faction})
		return false
	var cost := revive_cost()
	var pool: Variant = resource_pool_for(String(leader.faction))
	if not EconomyRes.spend(pool, cost):
		push_event({"type": "revive_rejected", "reason": "cost", "unit": leader,
			"faction": String(leader.faction)})
		return false
	leader.start_revive(cfg)
	push_event({"type": "revive_started", "unit": leader, "faction": String(leader.faction)})
	return true


## 取消读条中的「再起」并**全额退还**已经扣掉的那笔钱。
##
## @return true = 确实撤掉了一单（false = 它没在读条，或找不到人）。
## ★ 只有「正在读条」才退钱：没读条时点取消不该凭空造出一笔资源。
##   ⚠️ 退还走 `_refund`（它按**这一方自己的池子**退，池子为 null 时什么都不做）——
##      与「取消招募」共用同一条路，不另写一份扣/退实现。
func cancel_revive(leader_id: String, faction: String = "") -> bool:
	var leader = unit_by_id(leader_id)
	if leader == null or not leader.alive or not leader.is_reviving():
		return false
	if faction != "" and not FactionRes.same_side(String(leader.faction), faction):
		return false
	var cost := revive_cost()
	leader.cancel_revive()
	_refund(leader, float(cost.get("food", 0.0)), float(cost.get("gold", 0.0)), 0.0, -1)
	push_event({"type": "revive_cancelled", "unit": leader, "faction": String(leader.faction)})
	return true



## 钱与人口够不够。@return "" / "cost" / "population"
##
## ★ 与 can_recruit 分开：那边是「规则允不允许」，这边是「付不付得起」——
##   两种拒因给玩家的提示文案不一样（见 view/hud.gd 的 recruit_reject_text）。
## ★ 钱从**下单那一方自己的池子**里看（见 resource_pool_for）：AI 招兵不该看玩家的钱。
## ★ 池子是 null（这一方没有资源库，例如驻防将领那一方）→ **钱这一项当作无限**，
##   判据与理由见 `resource_pool_for` 的说明。
func can_afford_recruit(kind: String, leader_id: String) -> String:
	var leader = unit_by_id(leader_id)
	if leader == null:
		return "leader"
	var pool: Variant = resource_pool_for(String(leader.faction))
	if pool != null and not EconomyRes.can_afford(pool, recruit_cost(kind)):
		return "cost"
	var pop := recruit_population_cost(kind)
	if pop <= 0.0:
		return ""
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
## @param free ★★ true = **无资源消耗**招兵（本轮新增，将领性 / 防御性 AI 专用）。
##   需求原文：「该类 AI 在脱战……会无资源消耗地招募单位（或者可以认定该类 AI 资源无限）」。
##   跳过的是**全部计价**（粮食 / 黄金 / 人口都不扣、也不记账），
##   保留的是**其余全部规则**（读条 train_sec、队列上限、出生在格心、
##   读条期间钉在原地、队列取消/阵亡退款）。
##   ⚠️ 不记账这一点很关键：`train_cost_*` 留在 0，
##      所以「取消队列 / 将领阵亡」那两条退款路径一分钱都退不出来（不会凭空造钱）。
##   ⚠️ 区划归属（`leader_zone_owned`）**照旧要过** —— 免费不等于可以在别人家里造兵。
##
## @return true = 已经入队（**不代表已经生成** —— 要读条 train_sec 秒）
func start_recruit(kind: String, leader_id: String, faction: String,
		free: bool = false) -> bool:
	var reason := can_recruit(kind, leader_id, faction)
	if reason == "" and not free:
		reason = can_afford_recruit(kind, leader_id)
	if reason != "":
		# ★★ 必须带上 `faction`（下单那一方）—— 与 `upgrade_rejected` / `revive_rejected`
		#    同一条约定，理由也一样：**阵营 AI 也会下单**（`faction_ai` 每帧重试），
		#    不带 faction 的话界面那条 `_is_my_event()` 会把它当成玩家自己的报错，
		#    于是玩家一直看到「只能在己方区划内招募…」这种**别人的**红字
		#    （而且 AI 每帧重试 ⇒ 提示被反复续期、永远不消失。实测报回来的正是这个）。
		push_event({"type": "recruit_rejected", "reason": reason, "kind": kind,
			"faction": faction})
		return false

	var leader = unit_by_id(leader_id)
	var zone = zones.zone_at(leader.tx, leader.ty)
	var pop := recruit_population_cost(kind)
	var cost := recruit_cost(kind)
	# 免费那一档：人口与钱都不动（下面每一处扣费都看这个开关）
	if free:
		pop = 0.0
		cost = {}

	# 1) 扣钱（无条件）。校验刚刚过过，这里再判一次返回值只是**保险** ——
	#    扣费失败就一定不能往下走（否则会出现「兵排上了、钱却没扣」）。
	#
	# ★★ 钱从**下单那一方自己的池子**里扣（本轮改动）：原来是写死的 `resources`，
	#    于是「AI 让将领招兵」会掏玩家的兜。见 resource_pool_for 的说明。
	#
	# ⚠️ 这里**不要**写 `pool == null → return false`：池子是 null 的语义是
	#    「这一方没有资源库 = 资源无限」（见 resource_pool_for），
	#    而 `EconomyRes.spend(null, cost)` 自己会把「有消耗的 cost」判成扣不动、
	#    对空 cost 直接通过 —— 两条语义都不必在这里再抄一遍。
	var pool: Variant = resource_pool_for(String(leader.faction))
	if not EconomyRes.spend(pool, cost):
		push_event({"type": "recruit_rejected", "reason": "cost", "kind": kind,
			"faction": faction})
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


## ★★ 读条中的将领**被贴脸就取消招募、转去迎战**（本轮新增，用户需求）。
##
## 需求原话：「增加 ai 逻辑，当自己在招募时，若有敌方单位进入己方攻击范围，
##           则取消该招募转而攻击」。
##
## 为什么要有它：招募读条期间将领被**钉在原地**、不能动也不能还手（用户更早的需求），
## 于是敌兵贴到脸上时它只是个活靶子 —— 继续把 10 秒的读条走完等于白送一位将领。
##
## 实现要点（每一条都是刻意的）：
##   · 判据是**自己的攻击范围**（`cfg.unit_range_of`）而不是索敌半径 `aggro_range`：
##     需求说的是「进入攻击范围」，也就是「现在就能打到它」；
##   · 距离扣掉目标体积（与 `combat.gd` 的索敌同一口径）—— 允许「半个身子进射程」；
##   · 只认**能被攻击的敌方单位**（`is_attackable()`：濒死将领不算，与 combat 一致），
##     并且走 `same_side_for_attack()`（盟友不算敌人）；
##   · 取消用 `cancel_recruit(..., slot = 0)`：那是**正在读条**的那一单，
##     它会退回已扣的粮食 / 黄金 / 人口（`_refund()`），并让队列里的下一单前移 ——
##     ⚠️ 这里**只用现成的命令路径**，不自己拼一份「取消」逻辑（两份必然漂开）。
##
## @return true = 这一帧确实取消了招募（调用方据此让它继续参与战斗）
func _interrupt_training_if_threatened(u) -> bool:
	if not u.is_training():
		return false
	var threat = _nearest_threat_in_attack_range(u)
	if threat == null:
		return false
	if not cancel_recruit(String(u.id), 0, String(u.faction)):
		return false                   # 取消被拒（理论上不会）：维持原状，下一帧再看
	# ★ 顺手把「上一次开火的残留」清掉：它这一帧就要去打新目标，
	#   不清的话会有一条线从它连到**旧目标**（与 `_start_training` 里那一手同一个理由）。
	u.clear_attack_fx()
	# ★ 直接点名这个威胁当目标：不然它这一帧还要等一次「索敌冷却」才动手，
	#   而贴脸的敌人一秒都不该等。`ordered_target` 是玩家命令那一档，
	#   与 `combat.gd` 的自动索敌同一个消费方式（下一帧就走「有目标」那条路）。
	u.ordered_target = threat
	u.reset_repath()
	push_event({"type": "recruit_interrupted", "unit": u, "target": threat})
	return true


## 找一位将领**攻击范围内**最近的敌方单位（没有 → null）。
##
## ⚠️ 与 `combat.gd` 的索敌口径刻意保持一致（距离扣目标体积、跳过濒死、认盟友）：
##    两处判据漂开的表现是「AI 说没人、combat 说有人」这种最难查的不一致。
func _nearest_threat_in_attack_range(u) -> Variant:
	# ★ 走 `u.combat_range(cfg)`（不是 `cfg.unit_combat_of(...)["range"]`）：
	#   它会先看**将领自己的数值覆盖**（`unit.general.stats`）—— 那一位将领的射程
	#   与它兵种的射程本来就可能是两回事，判据要跟「它真能打到多远」一致。
	var reach: float = u.combat_range(cfg)
	if reach <= 0.0:
		return null
	var best = null
	var best_d := INF
	for other in units:
		if other == u or not other.is_attackable():
			continue
		if FactionRes.same_side_for_attack(String(other.faction), String(u.faction)):
			continue
		var d: float = u.pos.distance_to(other.pos) - cfg.unit_radius_of(other.unit_type)
		if d <= reach and d < best_d:
			best_d = d
			best = other
	return best


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
	# ★★ 开始读条 ⇒ 把「上一次开火的渲染残留」清掉（本轮修的 bug）。
	#    为什么要在这里清（实测报回来的症状：**有概率**有一条攻击线一直连在被攻击对象上）：
	#      读条期间将领被钉在原地、`world.tick` 第 4 步**整段跳过**它的单位逻辑，
	#      而 `attack_flash` 的衰减就在那段里（`combat.update_unit` 开头）⇒
	#      flash **冻在开招那一刻的值上**、`last_target` 也一直指着那个人，
	#      渲染（`view/overlay.gd` 的 `_draw_attack_lines`）就永远画着那条线。
	#      说「有概率」是因为它取决于开招那一刻 flash 还剩多少：
	#      刚开过火（flash ≈ 1）就开招 ⇒ 线一直留着；脱战一会儿再开招 ⇒ 看不出问题。
	#    ⚠️ 逆方向（读条 → 攻击）也靠这一手：不清的话恢复战斗后那条线会从
	#      「旧目标」跳一下才回到新目标（残留的 `last_target` 一直指着旧的那位）。
	leader.clear_attack_fx()


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
		# ★★ 濒死的将领**停止招募**（本轮修 bug，第二道保险）：
		#    正常路径上 `world.enter_near_death()` 已经把队列撤掉了（并退款），
		#    所以走到这里时它通常已经 `train_kind == ""`、上面那句就 continue 了。
		#    这一句是给「别的路径让它进了濒死」（测试摆场面、以后新加的效果）兜底的 ——
		#    少了它就会出现实测报回来的那个现象：**一个旗下什么都没有的濒死将领
		#    又造出来一个兵，靠那个兵续命**（`has_living_retinue` 一直是真）。
		if u.is_downed():
			_release_recruit(u, true, "leader_downed")
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
		tile, leader.faction, kind, "", leader.id, kind
	)
	# ★ 位置**显式**写一次格心：需求要的是「强制生成在中心」，
	#   不能依赖 UnitRes.create 的实现（哪天它改成别处落点就会静默跑偏）。
	u.pos = center
	u.sync_tile(map)
	# ★★ 归属区划**继承队长**（本轮新增，跟着招兵那条路一起做的）：
	#   · 有归属的队长（驻防将领）招出来的兵 ⇒ 归同一块地：它跟着队长巡逻
	#     （命令在 `general_ai._patrol_group` 里整队下），也因为同属一块地而受
	#     「不追出一个区划」那条硬约束管着；
	#   · 队长没有归属（玩家 / 阵营 AI 的将领）⇒ 兵也没有（`-1`，行为一点不变）。
	u.garrison_zone_id = int(leader.garrison_zone_id)
	units.append(u)
	# ★ 科技「将领血量 +10%」：区划招募出来的将领**自己就是队长**，走将领那一档
	#   （附属兵走 1.0 = 不加），与 world._apply_tech_effects 同一套判据。
	u.apply_hp_bonus(_tech_hp_mult_for(u))
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


## 退款：把粮食 / 黄金还给**下单那一方自己的池子**、人口还给**当初扣它的那个区划**，
## 并把这一队的记账值减掉（这样将领阵亡时的整队退款不会把已经退过的再退一遍）。
##
## ★★ 退给谁：`leader.faction` 那一方的池子（见 `resource_pool_for`）——
##    原来是写死的 `resources`，于是「AI 的将领阵亡退钱」会把钱退进**玩家**的账上。
##    ⚠️ 免费那一档（`start_recruit(free = true)`）记账值恒为 0，所以这里加 0 = 空操作。
##
## ⚠️ `zid` 必须由调用方传进来：`_release_recruit` 会先把 `train_zone_id` 清掉，
##    若在这里现读 leader.train_zone_id，人口就退不回去了（实测踩过）。
func _refund(leader, food: float, gold: float, pop: float, zid: int) -> void:
	var pool: Variant = resource_pool_for(String(leader.faction))
	if pool != null:
		pool["food"] = float(pool.get("food", 0.0)) + food
		pool["gold"] = float(pool.get("gold", 0.0)) + gold
	if pop > 0.0:
		var z = _zone_by_id(zid)
		if z != null:
			z["population"] = float(z.get("population", 0.0)) + pop
	leader.train_cost_food = maxf(0.0, leader.train_cost_food - food)
	leader.train_cost_gold = maxf(0.0, leader.train_cost_gold - gold)
	leader.train_cost_pop = maxf(0.0, leader.train_cost_pop - pop)


# ------------------------------------------------------------------
# 区划招募（点区划中心 → 右下「招募」页签 → 把将领排进**区划**的队列）
#
# 需求原话：「当玩家选中区划中心时，右下角显示招募页签（显示三个占位将领，玩家可以
#            点击以将招募将领加入区划的招募队列中，招募逻辑同招募单位）」。
#
# ★ 与「将领自己就是兵营」那套的**唯一区别**是**队列挂在哪**：
#     · 将领招募：队列挂在 unit（train_* 字段），出兵在将领所在格的格心；
#     · 区划招募：队列挂在**区划字典**（zone.gd 的 train_* 字段），出兵在区划中心旁边的空地。
#   计费 / 读条 / 上限 / 退款 / 取消这一整套规则**完全一致**，
#   所以这里的每个函数都能与上面那条逐个对照着读（别各自发明一套）。
#
# ★ 校验 → 扣费 → 入队 这三步的顺序与将领招募一致（反了会出现「钱扣了、兵没排上」）。
# ------------------------------------------------------------------

## 按 id 找区划（公开版；退款 / 招募都要它）
func zone_by_id(zid: int) -> Variant:
	return _zone_by_id(zid)


## 这个区划现在是不是「正在招募」（在读条，或还有排队的）
func zone_is_training(zone) -> bool:
	if typeof(zone) != TYPE_DICTIONARY:
		return false
	if String((zone as Dictionary).get("train_kind", "")) != "":
		return true
	return not ((zone as Dictionary).get("train_queue", []) as Array).is_empty()


## 队列里一共有几个（含正在读条的那个）
func zone_recruit_queue_size(zone) -> int:
	if typeof(zone) != TYPE_DICTIONARY:
		return 0
	var d: Dictionary = zone
	var n: int = (d.get("train_queue", []) as Array).size()
	if String(d.get("train_kind", "")) != "":
		n += 1
	return n


## 正在读条那个的进度（0~1；没在读条时 0）—— 与 unit.train_progress() 同一套口径，
## 视图只读它、不自己算（pitfalls 5.20）。
func zone_train_progress(zone) -> float:
	if typeof(zone) != TYPE_DICTIONARY:
		return 0.0
	var d: Dictionary = zone
	var total := float(d.get("train_total", 0.0))
	if String(d.get("train_kind", "")) == "" or total <= 0.0:
		return 0.0
	return clampf(1.0 - float(d.get("train_remaining", 0.0)) / total, 0.0, 1.0)


## 某一格上排的是哪个兵种（"" = 空格子）。0 = 正在读条的大格子，1..4 = 排队的小格子。
func zone_recruit_kind_at(zone, slot: int) -> String:
	if typeof(zone) != TYPE_DICTIONARY or slot < 0:
		return ""
	var d: Dictionary = zone
	if slot == 0:
		return String(d.get("train_kind", ""))
	var q: Array = d.get("train_queue", [])
	var k := slot - 1
	if k >= q.size():
		return ""
	return String(q[k])


## 第 slot 格**还要等多久**才轮到自己出人（秒）—— 与 recruit_eta 逐条同义。
func zone_recruit_eta(zone, slot: int) -> float:
	if typeof(zone) != TYPE_DICTIONARY or slot < 0:
		return 0.0
	var d: Dictionary = zone
	var eta := maxf(0.0, float(d.get("train_remaining", 0.0)))
	if slot == 0:
		return eta
	var q: Array = d.get("train_queue", [])
	if slot - 1 >= q.size():
		return 0.0
	for i in slot:
		eta += recruit_train_sec(String(q[i]))
	return eta


## 区划招募的**规则**校验。@return "" = 可以招；否则是拒因码：
##   "kind"        不在区划招募表里
##   "zone_not_found"  没有这个区划
##   "zone_owner"  ★ 这个区划**不属于你**（只能在自己区划里招）
##   "queue_full"  队列满了
##
## ⚠️ 「没有这个区划」用 `zone_not_found` 而**不是** `zone`：后者是**将领招募**那条路
##    的拒因（「将领不站在己方区划里」），两者的中文提示完全不同 ——
##    挤在同一个码上会让玩家看到一句驴唇不对马嘴的红字。
func can_recruit_zone(kind: String, zone_id: int, faction: String) -> String:
	if not is_zone_recruitable(kind):
		return "kind"
	var z = _zone_by_id(zone_id)
	if z == null:
		return "zone_not_found"
	if not FactionRes.same_side(String(z["owner"]), faction):
		return "zone_owner"
	if zone_recruit_queue_size(z) >= zone_recruit_queue_max():
		return "queue_full"
	return ""


## 区划招募付不付得起（人口从**这个区划**扣）。@return "" / "cost" / "zone_not_found" / "population"
##
## ★ 钱看**这个区划的归属方**（= 下单那一方）自己的池子 —— 与将领招募那条同义：
##   谁的地、谁的钱。见 `resource_pool_for`。
## ★ 池子是 null → 钱这一项当作无限（判据与理由见 `resource_pool_for`）。
func can_afford_zone_recruit(kind: String, zone_id: int) -> String:
	var z = _zone_by_id(zone_id)
	if z == null:
		return "zone_not_found"
	var pool: Variant = resource_pool_for(String((z as Dictionary)["owner"]))
	if pool != null and not EconomyRes.can_afford(pool, recruit_cost(kind)):
		return "cost"
	var pop := recruit_population_cost(kind)
	if pop <= 0.0:
		return ""
	if float((z as Dictionary).get("population", 0.0)) < pop:
		return "population"
	return ""


## 区划招募入队（`zone_recruit` 命令的唯一落点）。@return true = 已入队（还没生成）
##
## ★★ `faction` 同时决定**钱从哪个池子出**：正常情况它就是这一方自己的区划
##    （`can_recruit_zone` 已经拦过 `zone_owner`），所以「区划归属 == 下单方」这条
##    在扣费之前就成立了。这里用 `faction` 而不是 `z.owner`，是为了让
##    「谁点的、扣谁的」这件事在代码上是一句话，不依赖上面那条校验。
func start_zone_recruit(kind: String, zone_id: int, faction: String) -> bool:
	var reason := can_recruit_zone(kind, zone_id, faction)
	if reason == "":
		reason = can_afford_zone_recruit(kind, zone_id)
	if reason != "":
		# ★ 走**同一个事件类型**（recruit_rejected）：界面那条「拒因码 → 中文」的通道
		#   只写一处，这里多带一个 max（队列上限的文案要用它）。
		push_event({"type": "recruit_rejected", "reason": reason, "kind": kind,
			"zone_id": zone_id, "max": zone_recruit_queue_max(), "faction": faction})
		return false

	var z = _zone_by_id(zone_id)
	var pop := recruit_population_cost(kind)
	var cost := recruit_cost(kind)

	# ★ 钱从下单那一方的池子里扣（与 start_recruit 同一条；null = 无资源库 = 无限）
	var pool: Variant = resource_pool_for(faction)
	if not EconomyRes.spend(pool, cost):
		push_event({"type": "recruit_rejected", "reason": "cost", "kind": kind,
			"zone_id": zone_id, "faction": faction})
		return false
	if pop > 0.0:
		z["population"] = maxf(0.0, float(z["population"]) - pop)
	z["train_cost_food"] = float(z.get("train_cost_food", 0.0)) + float(cost.get("food", 0.0))
	z["train_cost_gold"] = float(z.get("train_cost_gold", 0.0)) + float(cost.get("gold", 0.0))
	z["train_cost_pop"] = float(z.get("train_cost_pop", 0.0)) + pop
	if String(z.get("train_kind", "")) == "":
		# 队列原本是空的 → 这一单立刻开读条，并**记下招募方**（读完按它出兵）
		z["train_faction"] = faction
		_start_zone_training(z, kind)
	else:
		(z["train_queue"] as Array).append(kind)
	push_event({"type": "zone_recruit_queued", "zone_id": zone_id, "kind": kind})
	return true


## 让某个兵种进区划的「大格子」开始读条。
func _start_zone_training(zone, kind: String) -> void:
	zone["train_kind"] = kind
	zone["train_total"] = recruit_train_sec(kind)
	zone["train_remaining"] = zone["train_total"]


## 把区划队列里的下一个提到大格子（队列空 → 变回空闲）
func _start_next_zone_queue(zone) -> void:
	var q: Array = zone.get("train_queue", [])
	if q.is_empty():
		zone["train_kind"] = ""
		zone["train_remaining"] = 0.0
		zone["train_total"] = 0.0
		return
	var next := String(q.pop_front())
	zone["train_queue"] = q
	_start_zone_training(zone, next)


## 每帧推进各区划的招募读条（world.tick 里跟在将领招募后面）。
## ★ 与 _tick_recruitment 用同一套「一帧可能读满好几单」的预算算法：
##   把剩下的时间接着往下算，而不是整帧丢给下一帧（否则时间轴会随帧率漂）。
func _tick_zone_recruitment(dt: float) -> void:
	if zones == null:
		return
	for z in zones.zones:
		if not zone_is_training(z):
			continue
		if String(z.get("train_kind", "")) == "":
			_start_next_zone_queue(z)
			continue
		var budget := dt
		var guard := 0
		while String(z.get("train_kind", "")) != "" and budget > 0.0 and guard < 64:
			guard += 1
			var left := maxf(0.0, float(z.get("train_remaining", 0.0)))
			if left > budget:
				z["train_remaining"] = left - budget
				budget = 0.0
				break
			budget -= left
			z["train_remaining"] = 0.0
			_spawn_zone_recruit(z, String(z["train_kind"]))
			_start_next_zone_queue(z)


## 读条完成：在**区划中心格旁边的最近空地**生成这名将领。
##
## ★ 生成的是**一条新单位**，而且它 `leader_id` 为空 ⇒ 它自己就是队长：
##   会作为新的一支部队出现在左侧部队列表里，之后也能拿它当招募对象
##   （需求要的是「招募将领」，不是一个挂在别人名下的兵）。
func _spawn_zone_recruit(zone, kind: String) -> Variant:
	var faction := String(zone.get("train_faction", ""))
	if faction == "":
		faction = String(zone["owner"])
	if faction == "":
		faction = my_faction
	var tile := _zone_spawn_tile(zone, faction)
	_recruit_serial += 1
	# ★★ id 要带阵营前缀（本轮新增）：玩家与 AI **可能在同一个区划 id 上各招一个将领**
	#    （AI 抢下玩家原来的地、或者两个 AI 各自招将），而 `_recruit_serial` 是全局的，
	#    光靠它虽然不会重复，但「zone-3-r1」这种 id 一眼看不出是谁的 ——
	#    出问题时（谁家的将领、谁的队列）这一眼就是全部线索。
	#    ⚠️ 玩家那一方**保持原样**（前缀是空串）：测试与界面都钉着 `zone-<id>-r<n>` 这个格式。
	var prefix := "" if FactionRes.is_player_faction(faction) else "%s-" % faction
	var u = UnitRes.create(
		cfg, "%szone-%d-r%d" % [prefix, int(zone["id"]), _recruit_serial],
		recruit_label_of(kind), tile, faction, kind, "", "", "",
		ConfigRes.general_index_of(kind)          # ★ 第几位将领（决定套不套它的数值覆盖）
	)
	units.append(u)
	# ★ 区划招募出来的将领自己就是队长 → 吃「将领血量 +10%」（用同一个判据函数）
	u.apply_hp_bonus(_tech_hp_mult_for(u))
	push_event({"type": "zone_unit_recruited", "zone_id": int(zone["id"]), "unit": u})
	return u


## 区划招募的出兵格：**区划中心那一格的旁边**最近的一格空地。
##
## ★ 为什么不是格心（与将领招募不同）：中心那一格上立着**中立障碍建筑**
##   （任何单位都进不去），生成在格心会当场把人卡在建筑里。
##   所以围着中心按同一张方向表就近找第一个能站人的格子，找不到才退回「最近可达格」。
func _zone_spawn_tile(zone, faction: String) -> Vector2i:
	var base := Vector2i(map.cols / 2, map.rows / 2)
	var c: Variant = zone.get("center", null)
	if c != null:
		base = c
	else:
		var tiles: Array = zone.get("tiles", [])
		if not tiles.is_empty():
			base = tiles[0]
	for off in ring_offsets():
		var want := Vector2i(base.x + off.x, base.y + off.y)
		if not PathfinderRes.passable(map, buildings, cfg, want.x, want.y, faction):
			continue
		if building_at(want.x, want.y) != null:
			continue
		if _tile_taken(want, null, []):
			continue
		return want
	var found = PathfinderRes.nearest_reachable(map, buildings, cfg, base, base, faction, 8, crowd)
	if found != null:
		return found
	return base


## 取消区划招募里的某一格（点信息栏那五格 → zone_recruit_cancel 命令 → 这里）。
## ★ 与 cancel_recruit 逐条同义：全额退款、后方前移、前移那一单从头读条；
##   区别只有「格子属于区划」以及**不看区划归属之外的东西**（区划易主也允许取消自己排的单）。
func cancel_zone_recruit(zone_id: int, slot: int, faction: String) -> bool:
	var z = _zone_by_id(zone_id)
	if z == null:
		push_event({"type": "recruit_cancel_rejected", "reason": "zone", "slot": slot})
		return false
	if not FactionRes.same_side(String(z["owner"]), faction):
		push_event({"type": "recruit_cancel_rejected", "reason": "zone_owner", "slot": slot})
		return false
	var kind := zone_recruit_kind_at(z, slot)
	if kind == "":
		push_event({"type": "recruit_cancel_rejected", "reason": "empty", "slot": slot})
		return false

	# 1) 先从队列里摘掉（后方的自动前移）
	if slot == 0:
		_start_next_zone_queue(z)
	else:
		(z["train_queue"] as Array).remove_at(slot - 1)

	# 2) 再退款（顺序与招募相反：先摘掉再退，中途出错也不会「退了钱、队列里还留着」）
	var cost := recruit_cost(kind)
	var food := float(cost.get("food", 0.0))
	var gold := float(cost.get("gold", 0.0))
	var pop := recruit_population_cost(kind)
	_refund_zone(z, food, gold, pop)
	push_event({"type": "recruit_cancelled", "zone_id": zone_id, "reason": "cancelled",
		"slot": slot, "kind": kind,
		"refund_food": food, "refund_gold": gold, "refund_pop": pop})
	return true


## 退款（区划版）：粮食 / 黄金还给**这个区划的归属方**、人口还给**同一个区划**，
## 并把记账值减掉（这样将来「区划被摧毁时整队退款」不会把已经退过的再退一遍）。
##
## ★ 归属方用下单时记下的 `train_faction`，没有就退回当前 owner ——
##   与 `_spawn_zone_recruit` 取 faction 的**同一套兜底顺序**（两处必须一致，
##   否则会出现「下单记的是 p1、退款退给了别人」）。
func _refund_zone(zone, food: float, gold: float, pop: float) -> void:
	var faction := String(zone.get("train_faction", ""))
	if faction == "":
		faction = String(zone["owner"])
	var pool: Variant = resource_pool_for(faction)
	if pool != null:
		pool["food"] = float(pool.get("food", 0.0)) + food
		pool["gold"] = float(pool.get("gold", 0.0)) + gold
	if pop > 0.0:
		zone["population"] = float(zone.get("population", 0.0)) + pop
	zone["train_cost_food"] = maxf(0.0, float(zone.get("train_cost_food", 0.0)) - food)
	zone["train_cost_gold"] = maxf(0.0, float(zone.get("train_cost_gold", 0.0)) - gold)
	zone["train_cost_pop"] = maxf(0.0, float(zone.get("train_cost_pop", 0.0)) - pop)


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
## 被**钉住**的将领（招募读条中 / 濒死倒地）拉回原位：推挤不许把它们挪走。
##
## 两种「钉住」的共同点是「位置在这个机制里是语义的一部分」，所以放在同一个函数里：
##   · **招募读条中**：位置取自开招那一刻记下的 `train_anchor`（用户需求：
##     「将领固定在原地、无法行动、无法攻击」）；
##   · **濒死**：位置取自倒下点 `downed_anchor`（用户拍板：「将领濒死后无法移动，
##     视作倒在原地」）—— 附属兵的行军目标也是它，所以这里被推走会直接让援军走错地方。
##
## ⚠️ 必须跑在碰撞消解**之后**：这一步是覆盖，不是参与推挤。
func _pin_training_leaders() -> void:
	for u in units:
		if not u.alive:
			continue
		var anchor: Vector2
		if u.is_training():
			anchor = u.train_anchor
		elif u.is_downed():
			anchor = u.downed_anchor
		else:
			continue
		if u.pos.distance_squared_to(anchor) <= 1e-12:
			continue
		u.pos = anchor
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
	else:
		# ★★ **不传坐标时**先自己挑一个能站人的默认点（本轮修）。
		#
		# 为什么必须挑（实测踩到）：`nearest_reachable()` 的 BFS 是从**目标**往外扩散，
		#   但它的可达性 region 是从 **from** 算出来的 —— `from` 本身落在山上时
		#   region 一个格子都没有，于是它**结构上只能返回 null**。
		#   而默认点 `(cols-1, 3)` 是硬编码的「地图右边缘」，`frontier` 那张图最后一列
		#   **整列是山**（`layout` 每行都以 `.#####` 结尾）⇒ `spawn_enemy()` 在真地图上
		#   永远刷不出兵（`CommandRes.apply({"kind":"spawn_enemy"})` 恒为 false，
		#   症状是「调试刷兵没反应」；`tests/test_view.gd` 那条断言一直红）。
		# ★ 挑法：从右往左、从上往下扫，取第一格可通行的 —— 保住「从地图右侧出现」
		#   这个既有意图（北侧隘口附近），只是不再假定最右那一列能站人。
		spawn = _first_passable_spawn(spawn, FactionRes.NPC_FACTION)
		if spawn.x < 0:
			push_event({"type": "spawn_failed", "tile": Vector2i(map.cols - 1, 3)})
			return null
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


## 从 `hint` 出发找一格**可通行**的位置：同一个 x 上从上往下、然后 x 逐列往左退。
##
## ★ 为什么需要它：`spawn_enemy()` 的默认点是「地图右边缘」，而地图右边缘完全可能是
##   山 / 墙（`frontier` 就是整列山）—— 那种坐标喂给 `nearest_reachable()` 只会拿到 null
##   （它从不可通行的起点算不出可达区域）。
## ★ 只做**有限**扫描（`max_cols` 列），找不到就返回 `(-1,-1)` 让调用方报失败 ——
##   不要在刷一个调试敌人的路径上扫全图。
func _first_passable_spawn(hint: Vector2i, faction: String, max_cols: int = 8) -> Vector2i:
	for dx in max_cols:
		var x: int = hint.x - dx
		if x < 0:
			break
		for y in map.rows:
			if PathfinderRes.passable(map, buildings, cfg, x, y, faction):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


# ------------------------------------------------------------------
# 建筑
# ------------------------------------------------------------------

## 在某格放一个建筑。**每个地块最多一个**。
## silent = true 时不写日志、不重算区块归属（批量布置出生点时用）。
## instant = true 时**跳过建造读条**（开局自带的大本营 / 防御阵地 / 区划中心用）。
##   ★ 为什么要有这个参数：`building.<type>.build_sec` 是**玩家建造**的读条时间
##     （编辑器里那一栏），开局摆好的东西不该等几秒才生效。
func add_building(type: String, tx: int, ty: int, owner: String, silent: bool = false,
		instant: bool = false) -> Variant:
	if not map.terrain.has(tx, ty):
		return null
	if buildings.get_cell(tx, ty) != null:
		return null
	var z = zones.zone_at(tx, ty)
	var zone_id: int = int(z["id"]) if z != null else -1
	var b = BuildingRes.create(cfg, type, tx, ty, owner, zone_id)
	# ★ 建造读条（config 的 build_sec；0 = 瞬发 = 与从前逐位一致）
	if not instant:
		b.start_construction(cfg.building_build_sec(type))
	buildings.set_cell(tx, ty, b)
	_building_at[Vector2i(tx, ty)] = b
	building_list.append(b)
	building_revision += 1
	# ★ 科技的「建筑血量 +10%」在这里就地补上（**粘性**：倍率没变时是空操作）。
	#   为什么落在这里而不是每帧刷：新建的建筑必须当场带上加成，
	#   否则「刚造好的墙比开局那座脆」——那是玩家一眼就看得出的不一致。
	if FactionRes.same_side(owner, my_faction):
		b.apply_hp_bonus(float(tech_effects.get("building_hp_mult", 1.0)))
	# ★ 新建建筑一律是 1 级：等级倍率显式落一次（`apply_level_mult` 是粘性的，
	#   不落的话它会停在默认的 1.0，与配置里 1 级的倍率不一致时就错了）。
	b.apply_level_mult(b.level_mult_from(cfg))
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
	# ★ 建筑离场 → 它的升级读条作废（**不退款**：钱花在这栋楼上了，楼没了就是没了 ——
	#   见 logic/upgrade.gd 的 cancel_upgrade_on_removed）。
	UpgradeRes.cancel_upgrade_on_removed(b)
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
# 建筑升级 + 区划特化（规则在 logic/upgrade.gd，这里只做转发与「落效果」）
#
# ★ 命令流：右下「操作」页 → input_controller.request_*() → {kind: building_upgrade /
#   building_upgrade_cancel / zone_specialize / zone_spec_cancel}
#   → command_processor → **这里**。视图每帧读下面这几个查询决定那一页画哪几格。
#
# ★ 为什么要这一层转发（而不是让命令层直接调 upgrade.gd）：
#   `upgrade.gd` 是纯规则（不持有 world），而命令里带的是**地块坐标 / 区划 id** ——
#   「坐标 → 建筑」这一步只有 world 能做（`building_at`），所以解析放在这里。
# ------------------------------------------------------------------

## 建筑类型在 config 里有没有升级表（区划中心没有 → 它的操作页只有特化）
func building_can_upgrade(type: String) -> bool:
	return cfg.has_upgrade(type)


## 这个建筑最多能到几级（= config 里那张等级表的条数）
func building_max_level(type: String) -> int:
	return cfg.upgrade_max_level(type)


## 这个建筑升到下一级要花的钱 / 读条秒数（已经满级 → 空字典 / 0）
func building_upgrade_cost(b) -> Dictionary:
	if b == null:
		return {}
	return cfg.upgrade_cost_to(b.type, b.level)


func building_upgrade_time(b) -> float:
	if b == null:
		return 0.0
	return cfg.upgrade_time_to(b.type, b.level)


## 开始升级某个建筑（`building_upgrade` 命令的落点；按**地块**定位）。
func start_building_upgrade(tx: int, ty: int, faction: String = "") -> bool:
	var b = building_at(tx, ty)
	var f := _tech_faction(faction)
	return UpgradeRes.start_upgrade(self, b, f)


## 取消某个建筑**读条中的**升级（全额退款）。
func cancel_building_upgrade(tx: int, ty: int, faction: String = "") -> bool:
	var b = building_at(tx, ty)
	var f := _tech_faction(faction)
	return UpgradeRes.cancel_upgrade(self, b, f)


## 开始区划特化（`zone_specialize` 命令的落点；按**区划 id** 定位）。
func start_zone_specialize(zone_id: int, spec_id: String, faction: String = "") -> bool:
	var f := _tech_faction(faction)
	return UpgradeRes.start_specialize(self, _zone_by_id(zone_id), spec_id, f)


## 发起「取消特化」读条（把已经生效的特化去掉，读完退款）。
func cancel_zone_specialize(zone_id: int, faction: String = "") -> bool:
	var f := _tech_faction(faction)
	return UpgradeRes.cancel_spec(self, _zone_by_id(zone_id), f)


## 撤掉区划上**读条中的**那一单特化（放弃 + 退款）。
func cancel_zone_spec_bar(zone_id: int, faction: String = "") -> bool:
	var f := _tech_faction(faction)
	return UpgradeRes.cancel_spec_bar(self, _zone_by_id(zone_id), f)


## 点区划中心时那个区划（HUD 用它把「选中的建筑」翻成「要特化的区划」）。
func zone_of_center_building(b):
	if b == null or b.type != BuildingRes.TYPE_ZONE_CENTER:
		return null
	return zone_center_zone_at(b.tx, b.ty)


## 区划现在的特化效果（HUD 显示「粮食 +0.5／地块／秒」用；没特化 → 加 0 / 倍率 1.0）
func zone_spec_effect(zone) -> Dictionary:
	return UpgradeRes.zone_spec_effect(zone, cfg)


## 这个区划的**种类** id（"food" / "gold" / "population"）—— 界面上显示名字用。
func zone_kind_of(zone) -> String:
	if zone == null or typeof(zone) != TYPE_DICTIONARY:
		return cfg.zone_kind_default() if cfg != null else ""
	if zones != null:
		return zones.kind_of(zone)
	return UpgradeRes.zone_kind_of(zone, cfg)


## 这个种类的区划现在能选哪几档特化（界面只画这几格，逻辑层还会再挡一次）
func zone_spec_choices(zone) -> Array:
	return UpgradeRes.spec_choices(zone, cfg)


## 区划的特化读条进度 / 剩余秒数（视图只读这两个，不自己算）
func zone_spec_progress(zone) -> float:
	return UpgradeRes.zone_spec_progress(zone, cfg)


func zone_spec_eta(zone) -> float:
	return UpgradeRes.zone_spec_eta(zone, cfg)


func zone_spec_busy(zone) -> bool:
	return UpgradeRes.zone_is_busy(zone)


func zone_spec_is_cancel(zone) -> bool:
	return UpgradeRes.zone_spec_is_cancel(zone)


## ★ 升级读完时把新等级的**血量上限倍率**落到这栋建筑上（由 upgrade.gd 调）。
## ★ 为什么要有这个入口：`upgrade.gd` 不认识 config 之外的算法，
##   而「上限 = 基础 × 等级 × 科技」这条唯一的算法在 building.refresh_hp_max() 里。
func apply_building_level_hp(b) -> void:
	if b == null:
		return
	b.apply_level_mult(b.level_mult_from(cfg))


## ★ 区划特化读完（或取消特化读完）时调：把「每秒产出」立刻重算一遍。
##
## ★ 为什么必须有这一句（**实测踩到的**）：`production_food / production_gold` 原本只在
##   `tick()` 的资源那一段刷新，而特化是在**同一帧更早**完成的
##   （`UpgradeRes.tick` 排在资源那一步**之前**）—— 于是「特化刚生效的那一帧」
##   这两个数还是旧值，界面上的「+n/秒」要等下一帧才跟上。
##   与科技那条（`set_tech_active` 里也调 `_refresh_production`）是同一条约定：
##   **效果一变，展示数当场跟上**。
func refresh_zone_production() -> void:
	_refresh_production()


# ------------------------------------------------------------------
# 科技（logic/tech.gd 是规则，这里是权威状态的持有者与落点）
#
# ★★ 需求原话：「玩家同一时间仅可启用三个占位科技……当玩家启用的科技数到 3 时，
#    玩家再启用科技会被阻止并提示；玩家可以点击已启用的科技以弃用科技」。
#
# ★ 命令流：右下九格 → input_controller.request_tech_toggle() → {kind: tech_toggle}
#   → command_processor → **这里**。视图不自己记「谁启用了」，每帧读这几个查询。
# ------------------------------------------------------------------

## 科技表现在有几条（= 命令卡九格的条目数；表在 config.json 的 tech.list）
func tech_list() -> Array:
	if tech != null:
		return tech.list()
	if cfg != null:
		return cfg.tech_list()
	return []


## 某个科技的条目（名字 / 第二行小字 / 悬停详情 / 效果）
func tech_entry(id: String) -> Dictionary:
	return tech.entry(id) if tech != null else {}


## 某一方现在启用的科技 id 数组（默认 = 本地玩家）
func active_tech_ids(faction: String = "") -> Array:
	if tech == null:
		return []
	return tech.active_ids(_tech_faction(faction))


## 这条科技现在启用了没有
func is_tech_active(id: String, faction: String = "") -> bool:
	return tech != null and tech.is_active(id, _tech_faction(faction))


## 还能再启用几条（界面显示「2/3」这类用；满了就是 0）
func tech_remaining_slots(faction: String = "") -> int:
	return tech.remaining_slots(_tech_faction(faction)) if tech != null else 0


## 同一时间最多启用几条
func tech_max_active() -> int:
	return tech.max_active() if tech != null else 3


## ★★ 科技页九格的**显示数据**（名字 / 第二行小字 / 悬停详情 / 是否已启用）。
##
## 为什么在逻辑层拼好给视图（而不是让 view 自己去查 config + 状态）：
##   「谁启用了哪几条」是**权威状态**，而视图只该读、不该自己把两处状态拼起来 ——
##   拼法一旦有两份（比如以后加「研究中有进度」），高亮就会和实际效果不一致。
##   视图拿到的是纯数据（无对象引用），也顺带满足「将来要过网络」那条约束。
##
## @return Array[Dictionary]，每项 {id, name, line, desc, active}，顺序 = 九格顺序
func tech_entries(faction: String = "") -> Array:
	var f := _tech_faction(faction)
	var active: Array = tech.active_ids(f) if tech != null else []
	var out: Array = []
	for item in tech_list():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var id := String(e.get("id", ""))
		out.append({
			"id": id,
			"name": String(e.get("name", id)),
			"line": String(e.get("line", "")),
			"desc": String(e.get("desc", "")),
			"active": active.has(id),
		})
	return out


## ★ 点一下某条科技（`tech_toggle` 命令的唯一落点）：
##   没启用 → 启用；已启用 → 弃用。启用满 3 条时再启用会被拒，并留一条事件给界面。
##
## @return true = 状态真的变了（被拒时返回 false，并在 `tech_rejected` 事件里带上拒因）
##
## ★ 为什么拒因走**事件**而不是返回值：命令层与界面之间隔着 tick 的事件收口
##   （view/game_scene._consume_events 是唯一把事件翻成中文的地方）——
##   与 recruit_rejected / order_rejected 完全同一条通道。
## ★ 效果改动**立即落地**：产量 / 人口是每帧读的（下一帧自然生变），
##   但血量是「建的时候写死的」，所以这里要显式刷一次（见 _apply_tech_effects）。
func set_tech_active(id: String, on: bool, faction: String = "") -> bool:
	if tech == null:
		return false
	var f := _tech_faction(faction)
	# ⚠️ 先算「现在是不是启用着」：弃用与启用两条路的拒因不一样 ——
	#    已启用的那条**不占新名额**（点它是弃用），不能被 limit 拦住。
	var was: bool = tech.is_active(id, f)
	if on and not was:
		var reason := tech.can_activate(id, f)
		if reason != "":
			# ★ 带上 `f`（解析出来的那一方，不是可能为空的形参）—— 阵营 AI 也会走
			#   `set_tech_active()`，不带阵营的话界面会把 AI 的「名额满了」当成玩家的报错。
			push_event({"type": "tech_rejected", "reason": reason, "tech_id": id, "faction": f})
			return false
	var changed: bool = tech.set_active(id, on, f)
	if not changed:
		return false
	tech_revision += 1
	_apply_tech_effects()
	push_event({"type": "tech_changed", "tech_id": id, "active": tech.is_active(id, f)})
	return true


## 点一下（切换）—— 界面的唯一入口：`tech_toggle` 命令带的是 on/off，
## 而玩家点格子那一下就是「切换」，所以这里包一层。
func toggle_tech(id: String, faction: String = "") -> bool:
	if tech == null:
		return false
	return set_tech_active(id, not tech.is_active(id, _tech_faction(faction)), faction)


## 本帧的科技加成（启用状态变了之后 tick 里会重算；别留着当缓存用）
func tech_bonus() -> Dictionary:
	return tech_effects


## 己方区划「人口自然增长速度」的科技倍率（1.0 = 没加成）——传给 zones.update_population
func tech_population_mult() -> float:
	return float(tech_effects.get("zone_population_mult", 1.0))


## 阵营口径统一走这里：空串 = 本地玩家那一方。
## ★ 内部一律用**真身**（`my_faction`）存，调用方传 "" / "p1" / "player" 都能对上 ——
##   与 zones.refresh_building_ownership 的 same_side 是同一套宽容度。
func _tech_faction(faction: String) -> String:
	return faction if faction != "" else my_faction


## ★★ 把科技的效果落到世界上的**对象**身上 —— 需要显式刷的只有「血量上限倍率」
## （产量由 `_refresh_production()` 顺手算；人口是每帧读倍率的，不用在这里动）。
##
## 「粘性」的含义：对象自己记住上一次施加的倍率，倍率没变就**什么都不做**
##   （所以反复调它是安全的）；倍率变了才按比例缩放当前血量。
## 为什么是「按比例缩放当前血量」而不是「血量直接乘倍率」：
##   一块被打掉一半的城墙在 +10% 之后应当还是「剩一半」。
## 上限本身从**基础值**重算（`base_hp_max × 倍率`，见 building / unit 里的字段说明）：
##   启用 / 弃用反复切换都不会累积误差，弃用后能精确回到原值。
func _apply_tech_effects() -> void:
	if tech == null:
		return
	tech_effects = tech.effects_of(my_faction)
	var b_mult: float = float(tech_effects.get("building_hp_mult", 1.0))
	for b in building_list:
		if b.alive and FactionRes.same_side(b.owner, my_faction):
			b.apply_hp_bonus(b_mult)
	for u in units:
		if not u.alive or not FactionRes.same_side(u.faction, my_faction):
			continue
		u.apply_hp_bonus(_tech_hp_mult_for(u))
	# ★ 产量那一份也要当场重算：玩家点一下「粮食 +3」就该在图上的「+n/秒」里看见，
	#   而不是等下一帧 tick（人口是每帧读倍率的，不用在这里动）。
	_refresh_production()


## 某个单位该吃的**将领血量**科技倍率（将领 = 队长 = `leader_id` 为空的那一个）。
## ★ 需求原文只写了「玩家将领血量 +10%」，所以附属兵一律返回 1.0（不加）。
##   判据集中在这里一处：开局将领 / 区划招募的占位将领（自己就是队长）/ 以后新加的
##   单位类型都走它 —— 两处各写一套「谁是将领」迟早会漂开。
func _tech_hp_mult_for(u) -> float:
	if u == null or u.leader_id != "":
		return 1.0
	return float(tech_effects.get("leader_hp_mult", 1.0))


## ★★ 重算「每秒产出」这两个展示数（tick 与科技状态变化都会调）。
##
## 口径（与 economy.gd 的文件头一致）：
##   产出 = 己方各区划的（产能 × 该区划地块数）之和  +  科技加成
## 科技加成 = 启用中的「每地块每秒」加成之和 × **己方占领地块数**。
##
## ⚠️ 加成只进 `production_*`（资源累加与 HUD 那个「+n/秒」），
##   **不改区划自己的 production** —— 区划产能是地图给的静态数据，
##   点开区划详情看到的那个数不该被科技改写。
## ⚠️ `owned_tiles` 也在这里刷新（**不在 tick 之外保留旧值**）：
##   科技一启用就要看到正确的「+n/秒」，而那时 `owned_tiles` 可能还是 0。
##   ⚠️ 但**不要**把它挪进 `reset()` / 世界构造：`owned_tiles` 的旧契约是
##      「tick 里算出来的数，reset 之后是 0」，tests/test_logic.gd 有断言钉着它。
##      reset 末尾那次 `_apply_tech_effects()` 会走到这里把 0 覆盖成真实值 ——
##      为了同时满足两边，`reset()` 里显式把它放回 0（见那里的注释）。
func _refresh_production() -> void:
	if zones == null:
		return
	# ★★ 本机席位那一份（HUD 读的就是它；`owned_tiles` / `production_*` 都是它的量）。
	_accumulate_production(my_faction, true)
	# ★★ 其余玩家席位**各算各的**（合作模式：p1、p2 各自的钱，用户已拍板）。
	#    ⚠️ 不含本机席位那一份（上面刚算过）；也不含 AI —— AI 的收入走
	#       `faction_ai._income()`，它有自己的 `resource_mult` 旋钮（难度）。
	for f in player_factions:
		var fid := String(f)
		if fid == my_faction:
			continue
		_accumulate_production(fid, false)


## 给某一方算一帧的**产出速率**（玩家席位专用；AI 的收入在 `faction_ai._income()` 里）。
##
## @param local true = 这一方是**本机席位**（顺手把 `owned_tiles` / `production_*` 刷新）
##
## ★ 科技加成只加在**本机席位**那一份上：科技是「本机玩家启用的那九条」
##   （`tech.effects_of(my_faction)`），不是每人一份 —— 与「AI 不吃科技」同一条口径。
## ⚠️ 本函数**只算速率、不加钱**：加钱是 `tick()` 里那一次 `EconomyRes.tick(cfg, dt, …)`
##   （玩家席位每个各加一次）—— 与单机那条路**同一个函数**，所以「每秒加多少」
##   的口径只有一处实现，不会出现两份算法慢慢漂开。
func _accumulate_production(faction: String, local: bool) -> Dictionary:
	var rates: Dictionary = zones.production_of(faction)
	var tiles: int = zones.owned_tile_count(faction)
	var food := float(rates["food"])
	var gold := float(rates["gold"])
	if local:
		owned_tiles = tiles
		food += float(tech_effects.get("food_per_tile_per_sec", 0.0)) * float(tiles)
		gold += float(tech_effects.get("gold_per_tile_per_sec", 0.0)) * float(tiles)
		production_food = food
		production_gold = gold
	return {"food": food, "gold": gold}


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
## ★ 建筑建造读条（config 的 `building.<type>.build_sec`；0 = 瞬发 = 与从前一致）。
##
## 读条期间这栋楼**不开火**（还没有战斗力），但已经在图上、也照常能被打 ——
## 「边造边挨打」是即时战略里正常的取舍，这里不做额外的免伤。
## ⚠️ 它只跑一次（一栋楼只有一次建造），与 upgrade.gd 那条升级读条互不相干。
func _tick_construction(dt: float) -> void:
	for b in building_list:
		if not b.alive or not b.is_under_construction():
			continue
		b.build_remaining = maxf(0.0, b.build_remaining - dt)
		if b.build_remaining <= 0.0:
			b.finish_construction()
			push_event({"type": "building_ready", "building": b})


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

	# 0) ★ 科技加成：每帧重算一次聚合值（九条各查一次表、几条加法），产量 / 人口读它。
	tech_effects = tech.effects_of(my_faction)
	#    ⚠️ 血量那一步是**按版本号**触发的，不是每帧跑：它要遍历所有建筑与单位，
	#       而且「新对象补一次加成」已经落在各出生点（见 apply_hp_bonus 的注释）。
	if tech_revision != _tech_hp_revision:
		_tech_hp_revision = tech_revision
		_apply_tech_effects()

	# 1) 区块占领（占位规则）
	var _t_zones := _prof()
	zones.update(cfg, dt, units, factions)

	# 1.5) ★ 区划人口：每个区块各算各的，只按时间涨、不消耗（用户需求）。
	#      与占领**无关**，也不进 HUD 的资源 —— 点开某个区划的中心能看它自己的人口。
	#      ★ 科技「区划人口产量 +10%」加的是**己方占领区划**的自然增长速度
	#        （用户确认的口径：production.population × 地块数），只影响涨得多快，
	#        上限 population_cap 不变。
	zones.update_population(dt, my_faction, tech_population_mult())

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
	_refresh_production()
	# ★★ 本机席位的钱（与加战役之前**同一行**、同一个函数 —— 单机行为逐位不变）
	EconomyRes.tick(cfg, dt, {"food": production_food, "gold": production_gold}, resources)
	# ★★ 其余**本地席位**各加各的（合作模式：每人一个钱包，用户已拍板）。
	#    ⚠️ 判据是 `player_seats`（本机负责的那几个），不是 `player_factions`：
	#       一关两个可玩阵营时，没被选中的那一方**在本机席位里、但不本机操作** ——
	#       它的钱走 AI 池（`faction_ai._income` + `ai_resources`），不能在这里加。
	#    ⚠️ 用 `player_seats` 也保证了单机逐位不变：
	#       老路径 roster 为空 ⇒ `player_seats == [my_faction]` ⇒ 这一段一次都不跑。
	for f in player_seats:
		var pfid := String(f)
		if pfid == my_faction:
			continue
		if _is_ai_piloted(pfid):
			continue
		var ppos: Variant = player_resources.get(pfid, null)
		if typeof(ppos) != TYPE_DICTIONARY:
			continue
		var prate: Dictionary = _accumulate_production(pfid, false)
		EconomyRes.tick(cfg, dt, prate, ppos)
	_prof_done("economy", _t_econ)

	# 3.5) ★ 招募读条（将领自己就是兵营）。
	#      ⚠️ 必须跑在下面的「清理离场单位」之前：单机不复活，阵亡的将领会在
	#         同一帧被摘出 world.units，那时退款就找不到它了（见 _release_recruit）。
	var _t_recruit := _prof()
	_tick_recruitment(dt)
	# ★ 区划招募（区划 = 兵营，招将领）走同一段预算：与上面那条一样，
	#   必须在「清理离场单位」之前跑完（它要在本帧内把读完的那一单落成单位）。
	_tick_zone_recruitment(dt)
	# ★★ 建筑升级 + 区划特化的读条（读完在**本帧内**落效果：等级 +1 / 特化生效）。
	#    与招募同一套「一帧可能读满好几单」的预算算法，见 logic/upgrade.gd 的 tick()。
	UpgradeRes.tick(self, dt)
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
		#
		# ★★ 但在跳过**之前**先看一眼「有没有敌人进了它的攻击范围」（本轮新增）：
		#    有 ⇒ **取消招募、转去迎战**（用户需求原话：「当自己在招募时，若有敌方单位
		#    进入己方攻击范围，则取消该招募转而攻击」）。理由很直白：读条期间将领
		#    不能动也不能还手，是活靶子 —— 被贴脸时继续读条等于白送一位将领。
		#    ⚠️ 必须放在 `is_training()` 这一支**里面**（而不是循环外）：
		#       取消之后要**立刻接着**跑这一帧的正常单位逻辑（索敌 / 开火），
		#       放到外面的话它会白等一帧，而那正是「贴脸了还在读条」的那一帧。
		if u.is_training():
			if _interrupt_training_if_threatened(u) and not u.is_training():
				pass                      # 已取消：往下走，这一帧就参与战斗
			else:
				continue
		# ★★ 濒死的将领（本轮新增）**不要**在这里另开一支：它这一帧只跑「濒死状态机」
		#    （缓慢回复 / 全灭判定 / 再起读条，见 unit.tick_near_death），而那一支
		#    已经由下面 `CombatRes.tick_frame` → `update_unit` 的第一句接管了。
		#    ⚠️⚠️ 在这里再写一次 `if u.is_downed(): u.tick_near_death(...); continue`
		#      会让回复与全灭判定**每帧跑两遍**（实测：每 3 秒 1% 变成每 2 秒 1%，
		#      而且读条会提前读完）—— 这是本轮踩到的最隐蔽的一个坑。
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
	#    ★★ 前面先走一段「建筑建造读条」（config 的 building.<type>.build_sec；默认 0 = 瞬发）：
	#       排在开火**之前**，于是「这一帧读完的那栋楼」本帧就能开火 ——
	#       与招募 / 升级那两条读条「读完在本帧内落效果」是同一条约定。
	var _t_towers := _prof()
	_tick_construction(dt)
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

	# 7.5) ★★ 两种新 AI（本轮新增，见 logic/faction_ai.gd 与 logic/general_ai.gd）：
	#   · 阵营 AI —— 自己的资源库（占领区划产出）× resource_mult，
	#     按「招将 → 招兵 → 升级 → 出兵」的优先级花钱；
	#   · 将领性（防御性）AI —— 归属区划内巡逻 / 不追出一个区划 / 脱战无消耗招兵。
	#
	# ★ 为什么排在 enemy_ai **之后**、碰撞消解**之前**：
	#   它们都会调 `order_move` / `order_attack_move` / `move_to`（要寻路），
	#   而寻路要读本帧的 crowd 缓存 —— 位置这一步在下面第 8.5 步才落定，
	#   所以这里下命令、下面那一帧就按新路径走，顺序与玩家命令完全一致。
	# ★ 与 enemy_ai 的判据互斥：驻防将领被 enemy_ai 跳过（它只认 hold_position=false
	#   且不在 garrison 里的 NPC 单位），所以不会出现「两边同时指挥同一个单位」。
	var _t_ai2 := _prof()
	FactionAiRes.update(self, cfg, dt)
	GeneralAiRes.update(self, cfg, dt)
	_prof_done("ai", _t_ai2)

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

	# 8.8) ★★ 战争迷雾：本帧所有位置都定下来之后，重算「谁能看见哪一格」。
	#
	# ★ 为什么排在最后、而不是单位逻辑之前：迷雾是**只读派生物**（不影响任何玩法判定），
	#   所以它只该读「这一帧结束时的世界」。放在前面会让刚走出一格视野的单位
	#   晚一帧才被迷雾更新（观感上就是「视野框跟不上部队」）。
	# ★ 换地形的系统（全在 `map.terrain` 里改过之后调 `rebuild_terrain_masks()`）要让
	#   迷雾重算，必须调 `fog.reset_cache()` —— 视野扇区是**按地形缓存**的。
	# ★ 没有变化就整段跳过（见 fog.refresh_needed）：这是 1000 单位下的性能前提。
	var _t_fog := _prof()
	if fog != null and (fog.sight.is_empty() or fog.refresh_needed(self)):
		fog.update(self)
	_prof_done("fog", _t_fog)

	# 9) 胜负判定（大本营被打掉 / 超时比血量）
	check_victory(dt)

	# 9.5) ★★ 目标与胜负（本轮新增）：**目标最后判** ——
	#   这样「这一帧刚守满 hold_sec」能立刻结算，而不是等下一帧
	#   （用户拍板：「跨过阈值的那一帧生效」）。
	#   ⚠️ 没有目标的一局（`level == null`）在这里是**一次字典判断**，什么都不做。
	var _t_obj := _prof()
	if not objective_state.is_empty():
		ObjectiveRes.update(self, cfg, objective_state, dt)
		# 结算的那一帧发一条 `level_end`（界面拿它播报一次；逻辑层不写文案）。
		# ⚠️ 靠 `_objective_reported` 去重：结算之后 world **继续 tick**（不做冻结），
		#    不记一笔就会每帧发一条，界面上的提示会刷屏。
		var st := String(objective_state.get("state", ObjectiveRes.STATE_RUNNING))
		if _objective_reported == "" and ObjectiveRes.is_over(objective_state):
			_objective_reported = st
			push_event({
				"type": "level_end",
				"result": "win" if st == ObjectiveRes.STATE_WON else "lose",
				"reason": String(objective_state.get("reason", "")),
			})
	_prof_done("objective", _t_obj)

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
# 队伍（队长 + 附属兵）
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


## ★ 把「选中一个单位」展开成整队：队长 + 它辖下所有还活着的附属兵。
##
## 规则（手玩定的）：
##   · 点队伍里**任何一个** → 整队一起被选中（附属兵有队长时先补上队长，再把队长的队员都带上）
##   · 队长已经阵亡 → 剩下的附属兵各算各的（只选中自己），不会凭空造出一个队长
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


## 某个队长辖下的附属兵。
##
## @param alive_only true（默认）= 只要还活着的（正常玩法用）；
##        false = 连阵亡但还没被清掉的也算上 —— **查「原来跟着谁」时必须传 false**。
##   ⚠️ 这两个语义容易混：队长刚阵亡时，`retinue_of(id)` 仍然是**非空**的
##      （附属兵还活着），只是它们的队长查不到了（team_leader 返回 null）。
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
