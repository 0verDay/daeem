## faction_ai.gd —— **阵营性 AI**：附属在某个阵营下的一整套「内政 + 出兵」经营。
##
## 需求原文（逐条对照）：
##   1. 「该类 AI 会附属在某个阵营/势力下，该类 AI 有自己的资源库，其资源会随着其占领区划
##        产出资源而增长」
##      → 资源库是 world 里**独立的一个字典**（`world.resource_pool_for(faction)`，
##        见 world.reset()）。本模块每帧只做一件事：把
##        `zones.production_of(faction) × resource_mult × dt` 加进去 ——
##        口径与玩家那一套**逐条同义**（产能来自地图 zone_list，抢区块 = 抢产能），
##        唯一的差别是 `resource_mult`（难度旋钮）。
##   2. 「该类 AI 会花费资源招募自己的将领 / 升级自己的建筑，并花费资源让将领招募单位，
##        需要有明确的资源规划」
##      → 决策顺序是**固定的四段**（见 `_decide()`）：
##        a. 将领没招满 → 招将领（区划招募，队列挂区划中心）；
##        b. 将领没补满员 → 让将领招兵（队列挂将领自己）；
##        c. 还有闲钱 → 升级自己的建筑（挑**最便宜**的那一栋，先升级后攒大招）；
##        d. 都齐了 → 出兵（见第 3 条）。
##        每一段都走**同一套已有的命令路径**（world.start_zone_recruit /
##        world.start_recruit / world.start_building_upgrade），
##        所以扣费、读条、队列上限、人口这些规则一行都不用重写。
##   3. 「该类 AI 在若干将领招募满员后会派遣这些将领行军攻击某处」
##      → 一旦「招满 generals 个将领，且每个将领都补到 min_retinue」，
##        就按 `min_ready` / `ready_mult` 算出一个派兵比例，
##        对**离目标最近的**那几位将领下达 `order_attack_move`（行军攻击）——
##        目标选「离自己最近的敌方区划中心」，没有敌方区划就选敌方大本营。
##   4. 「该类 AI 可为其提高资源获取倍率以调整难度」
##      → `config.ai.factions[].resource_mult`（1.0 = 与玩家同速，2.0 = 两倍）。
##
## ★★ 状态放在哪：`world.ai_factions[]`，每项一个字典（见 `setup()`）。
##   为什么不单独一个 RefCounted 类：这点状态（资源 + 两个计时器 + 一个目标）
##   不值得一个类型，而且它是**世界状态的一部分**（跟 tech.active_by_faction 同源），
##   将来进快照时就在 world 上，不用再绕一层。
##
## ★ 单机下 AI 是「另一个阵营」，玩家看不见它的资源（也不该看见）——
##   界面读的永远是 `world.resources`（玩家自己那个池子）。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用，
##    见 docs/pitfalls.md 第五节）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")

## 一次决策里最多下几条命令（护栏）。见 `_decide()` 的说明。
const MAX_ORDERS_PER_TICK := 4


## 建出这张图上的全部阵营 AI（由 `world.reset()` 在所有单位就位之后调一次）。
##
## @return Array[Dictionary]，每项：
##   {faction, mult, general_index, recruit_timer, upgrade_timer, attack_timer}
##
## ★ 为什么在这里就把 `general_index` 定下来：将领是**按序号招**的
##   （general_1 / general_2 / …，见 config 的 recruit.zone.list 与
##   `ConfigRes.general_index_of`），而「已经招了几个」是**只增不减**的 ——
##   看当前场上有几个将领也不行（死掉的会重招、序号会撞车）。
## ★ 为什么这里也拦一次玩家席位（`world._setup_ai_factions` 已经拦过了）：
##   那一处拦的是「名单与资源池」，这一处拦的是「**状态表**」——
##   两处判据必须一致，否则会出现「状态表里有这一方、资源池里没有」，
##   而 `_income()` 会直接把 null 当 Dictionary 用（`pool["food"] = ...`）当场报错。
##   这种「两处判据漂开」的错最难查，所以宁可重复一句。
static func setup(world, cfg: ConfigRes) -> Array:
	var out: Array = []
	for e in cfg.ai_factions():
		var entry: Dictionary = e
		var fid := String(entry["id"])
		# ⚠️ 玩家席位不许被 AI 接管（玩家自己那一方的资源池与命令流都是本地输入在写）。
		if FactionRes.is_player_faction(fid):
			push_warning("ai.factions 里写了玩家阵营「%s」，已忽略（AI 不接管玩家席位）" % fid)
			continue
		# ⚠️ 资源池必须已经开好（见 world._setup_ai_factions）——没开就说明名单没对齐，
		#    这一条排在上面那个 continue 之后，所以正常配置永远不会命中。
		if world.resource_pool_for(fid) == null:
			push_warning("ai.factions 里的「%s」没有资源池，已跳过（名单没对齐？）" % fid)
			continue
		out.append({
			"faction": fid,
			"mult": float(entry.get("resource_mult", 1.0)),
			# 下一个要招的将领序号（0 起）。招满 cfg.ai.faction.generals 个就停。
			"general_index": 0,
			"recruit_timer": 0.0,
			"upgrade_timer": 0.0,
			"attack_timer": 0.0,
		})
	return out


## 每帧：先让资源涨（资源增长），再跑决策（花钱 / 出兵）。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if dt <= 0.0 or world.ai_factions.is_empty():
		return
	var fc: Dictionary = cfg.ai_faction_cfg()
	for st in world.ai_factions:
		var faction := String(st["faction"])
		_income(world, st, faction, dt)
		_decide(world, cfg, fc, st, faction, dt)


## ★★ 资源增长：**占领的区划** 的（产能 × 地块数）× `resource_mult` × dt。
##
## 口径与 `world._refresh_production()` 里玩家那一份**逐条同义**：
##   · 走 `zones.production_of(faction)` —— 它已经把区划特化（粮食 / 黄金 +0.5/地块/秒）
##     算进去了，所以 AI 抢到一块特化过的地也一样吃加成；
##   · **不含**科技加成（科技是玩家的那九条，NPC 不启科技 —— 要给它加成请调 resource_mult）。
##
## ★ 难度旋钮只乘在这里：它放大的是「同样几块地，AI 攒钱更快」，
##   而不是「凭空多出地块」——所以地图平衡（谁的地好）仍然是决定性的。
static func _income(world, st: Dictionary, faction: String, dt: float) -> void:
	if world.zones == null:
		return
	var rates: Dictionary = world.zones.production_of(faction)
	var mult: float = float(st.get("mult", 1.0))
	var pool: Dictionary = world.resource_pool_for(faction)
	pool["food"] = float(pool.get("food", 0.0)) + float(rates.get("food", 0.0)) * mult * dt
	pool["gold"] = float(pool.get("gold", 0.0)) + float(rates.get("gold", 0.0)) * mult * dt


## 一帧的决策：资源规划的四段，**按优先级**依次尝试。
##
## ★★ 为什么是「按优先级依次尝试」而不是「每段都跑一遍」：
##   AI 的钱是有限的，四段都要钱。全跑一遍的结果是「每样都买一点、每样都不成形」
##   （典型症状：将领一个没招出来，钱全花在升级上了）。
##   所以这里用 `return` 收口：**这一帧只做最高优先级那件还做得起的事**，
##   剩下的钱留到下一帧继续按优先级花。这就是「明确的资源规划」。
##
## ⚠️ `MAX_ORDERS_PER_TICK` 是护栏：万一某一段的条件恒真（配置写错），
##    也不会在一帧里下几百条命令。
## ★★ 为什么招将会 `return`，而升级**不** `return`（这条路第一版写错过，记在这）：
##
##   「一事一帧」这条规矩要**看对象**：
##     · 招将 / 招兵是**长期动作**（一单读条 10 秒，队列里排着的也算数）——
##       同一帧连下几单会瞬间堆满队列，而且第二单的钱本来是下一帧才该花的；
##     · 升级也占钱，但它**与出兵并不冲突**：一支满员的部队该出发就出发，
##       不会因为「城里正在修墙」就原地等。第一版让升级也 `return` 了，
##       结果是**只要有闲钱，AI 永远在升级、永远不出兵**（实测：attack_timer 一直在被刷）。
##
##   所以这里的收口是：a / b 命中就收工（一帧一件事），c 与 d 都可以在同一帧发生。
static func _decide(world, cfg: ConfigRes, fc: Dictionary, st: Dictionary,
		faction: String, dt: float) -> void:
	# 大本营没了（被打掉）→ 什么都不做，资源照旧攒（以后可以拿它做「投降 / 重建」）。
	if world.find_base_of(faction) == null:
		return
	st["recruit_timer"] = maxf(0.0, float(st.get("recruit_timer", 0.0)) - dt)
	st["upgrade_timer"] = maxf(0.0, float(st.get("upgrade_timer", 0.0)) - dt)
	st["attack_timer"] = maxf(0.0, float(st.get("attack_timer", 0.0)) - dt)

	var max_generals: int = int(fc["generals"])
	var min_retinue: int = int(fc["min_retinue"])
	var generals: Array = _generals_of(world, faction)

	# ---- a) 招将领（没招满，且不在读条）----
	if int(st["general_index"]) < max_generals and float(st["recruit_timer"]) <= 0.0:
		var zone = _recruit_zone(world, faction)
		if zone != null:
			var kind := _general_kind_for(int(st["general_index"]))
			if kind != "" and world.can_recruit_zone(kind, int((zone as Dictionary)["id"]), faction) == "" \
					and world.can_afford_zone_recruit(kind, int((zone as Dictionary)["id"])) == "":
				if world.start_zone_recruit(kind, int((zone as Dictionary)["id"]), faction):
					st["general_index"] = int(st["general_index"]) + 1
					st["recruit_timer"] = float(fc["recruit_cooldown_sec"])
					return

	# ---- b) 让将领招兵（每个将领补到 min_retinue 个）----
	if min_retinue > 0 and float(st["recruit_timer"]) <= 0.0:
		var orders := 0
		for g in generals:
			if orders >= MAX_ORDERS_PER_TICK:
				break
			if g.is_training():
				continue                      # 它已经在造了（队列里排着的也算）
			if g.retinue_size(world) >= min_retinue:
				continue
			var kind2 := _unit_kind_for(world, g)
			if kind2 == "":
				continue
			if world.can_recruit(kind2, String(g.id), faction) != "":
				continue
			if world.can_afford_recruit(kind2, String(g.id)) != "":
				continue
			if world.start_recruit(kind2, String(g.id), faction):
				orders += 1
		if orders > 0:
			st["recruit_timer"] = float(fc["recruit_cooldown_sec"])
			return

	# ---- c) 升级建筑（挑最便宜的那一栋；留出 reserve 不花光）----
	#      ★ 这一段**不 return**：升级与出兵可以同一帧发生（理由见上面那段注释）。
	if float(st["upgrade_timer"]) <= 0.0:
		var b = _pick_upgrade(world, cfg, faction, float(fc["upgrade_reserve_food"]),
			float(fc["upgrade_reserve_gold"]))
		if b != null and world.start_building_upgrade(b.tx, b.ty, faction):
			st["upgrade_timer"] = float(fc["upgrade_cooldown_sec"])

	# ---- d) 出兵：将领招满 + 每个都补满员 → 派一批行军攻击 ----
	if int(st["general_index"]) < max_generals:
		return                                # 还没招满，不谈出兵
	for g in generals:
		if g.retinue_size(world) < min_retinue:
			return                            # 还有将领没满员，不谈出兵
	if float(st["attack_timer"]) > 0.0:
		return
	if generals.size() < int(fc["min_ready"]):
		return
	_launch_attack(world, cfg, fc, generals, faction)
	st["attack_timer"] = _attack_repeat(cfg)


## `ai.faction.attack_repeat_sec` 的安全版（读一次、夹一次）。
## ★ 单独抽出来只是为了让 `_decide()` 最后那段读起来是「规则」而不是「取值」。
static func _attack_repeat(cfg: ConfigRes) -> float:
	return maxf(0.1, float(cfg.ai_faction_cfg()["attack_repeat_sec"]))


## 派兵：按 `ready_mult` 决定这次派几个将领（至少 min_ready 个），
## 挑**离目标最近的**那几位，对它们下达行军攻击命令。
##
## 目标：离这个 AI 最近的**敌方区划中心**；没有敌方区划 → 敌方大本营。
##
## ★ 为什么挑「离目标最近」而不是「全部一起上」：需求要的是「派遣这些将领行军攻击某处」——
##   分兵去打最近的那块地才叫「攻击某处」；全员扑同一个点会让它自己的地盘没人守。
## ★ 用 `order_attack_move`（行军攻击）而不是 `order_move`：
##   路上遇到守军会停下来打（那是 A 键的语义），打完继续走 —— 这正是「行军攻击某处」。
static func _launch_attack(world, cfg: ConfigRes, fc: Dictionary, generals: Array,
		faction: String) -> void:
	var goal: Variant = _attack_target(world, faction)
	if goal == null:
		return
	var goal_tile: Vector2i = goal
	var goal_pt: Vector2 = GridRes.center_of(goal_tile)

	# 派几个：ready_mult 是「准备好的人里派出去几成」，至少 min_ready 个，最多全派。
	var want: int = int(ceil(float(generals.size()) * clampf(float(fc["ready_mult"]), 0.0, 1.0)))
	want = maxi(1, want)
	want = maxi(int(fc["min_ready"]), want)
	want = mini(want, generals.size())

	# 按「离目标近」排序（近的打头，也就先被选中）——不引入随机：AI 要可复现。
	var sorted: Array = generals.duplicate()
	sorted.sort_custom(func(a, b):
		return a.pos.distance_squared_to(goal_pt) < b.pos.distance_squared_to(goal_pt))

	var sent := 0
	for g in sorted:
		if sent >= want:
			break
		# 已经在打的将领不打断（它可能正被玩家的兵缠住）。
		if g.target != null or g.target_building != null:
			continue
		if g.is_training():
			continue
		# ⚠️ 行军攻击**只有一条命令入口**：`order_attack_move` 会写 has_attack_move +
		#    attack_move_goal，combat.gd 每帧按它推进（到点 / 路上打完继续走）。
		#    这里不额外写 settling_* 之类的字段 —— 那些由 order_move 内部统一处理。
		if g.order_attack_move(world, cfg, goal_pt):
			sent += 1


## 攻击目标：离自己最近的**敌方区划中心**（没有中心格的区划跳过），
## 全都没有 → 敌方大本营。
##
## ★ 判据用 `FactionRes.same_side(z.owner, faction)` 取反，而不是写 `z.owner != faction`：
##   空 owner（无主区划）在 same_side 下是「不同方」—— 但无主区划不该是攻击目标
##   （AI 去打一片没人的地毫无意义），所以这里额外要求 `owner != ""`。
static func _attack_target(world, faction: String) -> Variant:
	if world.zones == null:
		return null
	var home: Vector2i = world.home_base_of(faction)
	var best: Variant = null
	var best_d := INF
	for z in world.zones.zones:
		var owner := String((z as Dictionary)["owner"])
		if owner == "" or FactionRes.same_side(owner, faction):
			continue
		var c: Variant = (z as Dictionary).get("center", null)
		if c == null:
			continue
		var d: float = GridRes.octile_distance((c as Vector2i).x - home.x, (c as Vector2i).y - home.y)
		if d < best_d:
			best_d = d
			best = c
	if best != null:
		return best
	# 没有敌方区划中心 → 找一个敌方大本营
	for b in world.building_list:
		if not b.alive or b.type != BuildingRes.TYPE_BASE:
			continue
		if FactionRes.same_side(String(b.owner), faction):
			continue
		var d2: float = GridRes.octile_distance(b.tx - home.x, b.ty - home.y)
		if d2 < best_d:
			best_d = d2
			best = Vector2i(b.tx, b.ty)
	return best


## 这个阵营的将领列表（`kind` 是将领类、还活着）。
##
## ★ 判据走 `unit.is_general()`（= `ConfigRes.general_index_of(kind) >= 0`）：
##   与渲染（描边更粗）、科技血量加成用的是**同一个**判据 —— 不另写一份前缀判断。
static func _generals_of(world, faction: String) -> Array:
	var out: Array = []
	for u in world.units:
		if not u.alive or u.faction != faction:
			continue
		if u.is_general():
			out.append(u)
	return out


## 招将领用的 kind：`general_1` / `general_2` / …（序号 1 起，与 config 的
## `recruit.zone.list` 与 `ConfigRes.general_index_of` 同一套编号）。
static func _general_kind_for(index: int) -> String:
	return "general_%d" % (index + 1)


## 让某个将领招什么兵：**与它自己同类型**的兵（将领 1 是长枪兵就补长枪兵）。
## 表里没有这个 kind 时退回招募表第一条（免得地图改了兵种之后 AI 彻底不招兵）。
static func _unit_kind_for(world, g) -> String:
	var kind := String(g.unit_type)
	if world.is_unit_recruitable(kind):
		return kind
	var lst: Array = world.recruit_list()
	if lst.is_empty():
		return ""
	return String((lst[0] as Dictionary).get("kind", ""))


## 找一个「可以招将领」的区划：优先自己的区划中心，其次自己的任何区划。
##
## ★ 需求里将领是在**区划**里招的（区划 = 兵营，见 config 的 recruit.zone）——
##   所以 AI 也必须先有地才能招将；没地就先靠单位去占（这是有意的先后关系）。
static func _recruit_zone(world, faction: String) -> Variant:
	if world.zones == null:
		return null
	var with_center: Variant = null
	for z in world.zones.zones:
		if String((z as Dictionary)["owner"]) != faction:
			continue
		if (z as Dictionary).get("center", null) != null:
			return z                       # 有中心的优先
		if with_center == null:
			with_center = z
	return with_center


## 挑一栋最值得升级的建筑：**能升级 + 钱够（扣掉 reserve）+ 最便宜**。
##
## @return Building 或 null
##
## ★ 为什么挑最便宜的那一栋：AI 的钱是慢慢攒的，先升级一栋便宜的就是
##   「先形成战斗力再攒大招」；挑最贵的会让它一直攒着不花钱（看起来像坏了）。
## ★ reserve 的语义是「留给招兵 / 招将的钱，不许被升级吃掉」——
##   `ai.faction.upgrade_reserve_*` 默认 0（不预留），调大就是「优先保证兵源」。
static func _pick_upgrade(world, cfg: ConfigRes, faction: String,
		reserve_food: float, reserve_gold: float) -> Variant:
	var pool: Dictionary = world.resource_pool_for(faction)
	var best = null
	var best_cost := INF
	for b in world.building_list:
		if not b.alive or String(b.owner) != faction:
			continue
		if not world.building_can_upgrade(b.type):
			continue
		var cost: Dictionary = world.building_upgrade_cost(b)
		if cost.is_empty():
			continue                      # 满级
		var need_food := float(cost.get("food", 0.0)) + reserve_food
		var need_gold := float(cost.get("gold", 0.0)) + reserve_gold
		if float(pool.get("food", 0.0)) < need_food or float(pool.get("gold", 0.0)) < need_gold:
			continue
		var weight := float(cost.get("food", 0.0)) + float(cost.get("gold", 0.0))
		if weight < best_cost:
			best_cost = weight
			best = b
	return best
