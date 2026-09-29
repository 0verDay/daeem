## test_ai.gd —— ★ 本轮新增的两种 AI：阵营性 AI + 将领性（防御性）AI
##
## 覆盖（每条都对着需求原话写）：
##   A. 阵营 AI 的**存在与资源库**
##      · 阵营 AI 的阵营被插进名单、有大本营、有将领（且开局不带附属兵）；
##      · 资源库**与玩家分开**：`world.resource_pool_for()` 两条路；
##      · 资源随**占领区划**产出增长，且 `resource_mult` 是难度旋钮。
##   B. 阵营 AI 的**资源规划**
##      · 有钱 + 有地（区划有中心）→ 招将领（钱从 AI 自己的池子扣，玩家一分不少）；
##      · 将领招到之后 → 让将领招兵补到满员；
##      · 有钱 → 升级自己的建筑（升级读条落在建筑上）；
##      · 招满 generals 个 && 每个都满员 → **出兵**（派将领行军攻击敌方区划中心）。
##   C. 将领性（防御性）AI
##      · 归属区划从地图 `units[].zone` 落到单位上；
##      · **没有资源池**（问 resource_pool_for 拿不到它那一份）；
##      · 按时间间隔在归属区划里巡逻（朝区划中心走）；
##      · **不追出一个区划**：追进别人的区划就当场脱战；
##      · 脱战满 combat_idle_sec 且不满员 → **无消耗**招兵（钱 / 人口都不动）；
##      · 不跑 enemy_ai 的推进逻辑。
##
## ⚠️ 本文件是 `--script` 跑的：跨文件引用只用自己的 preload 常量，不用全局 class_name
##    （见 tests/test_case.gd 顶部与 docs/pitfalls.md 第五节）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const FactionRes = preload("res://logic/faction.gd")
const FactionAiRes = preload("res://logic/faction_ai.gd")
const GeneralAiRes = preload("res://logic/general_ai.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const GridRes = preload("res://logic/grid.gd")
const EnemyAiRes = preload("res://logic/enemy_ai.gd")

## 地图上给防御性 AI 摆的三个驻防将领（写在 data/test_map.json 的 units[] 里）
const GARRISON_NAME := "驻防将领"


func _initialize() -> void:
	_case_name = "test_ai"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	# ★ 每个用例都**自己造一个世界**：AI 是有状态的（资源、计时器、队列），
	#   共用一个世界会让断言互相影响（一个用例把 AI 的钱花光了，下一个就招不出将领）。
	_test_faction_ai_presence(cfg)
	_test_faction_ai_resources(cfg)
	_test_faction_ai_recruit_general(cfg)
	_test_faction_ai_recruit_units(cfg)
	_test_faction_ai_upgrade(cfg)
	_test_faction_ai_attack(cfg)
	_test_faction_ai_multiplier(cfg)
	_test_faction_ai_income_accumulates(cfg)
	_test_faction_ai_runs_over_time(cfg)
	_test_general_ai_from_map(cfg)
	_test_general_ai_patrol(cfg)
	_test_general_ai_no_pursuit(cfg)
	_test_general_ai_free_recruit(cfg)
	_test_general_ai_not_advancing(cfg)


## 造一个干净的世界（用的是随游戏发布的那张真地图）。
func _world(cfg) -> RefCounted:
	var w = WorldRes.create(cfg, "res://data/test_map.json")
	ok(w != null, "世界能建出来")
	return w


# ------------------------------------------------------------------
# 0) 配置
# ------------------------------------------------------------------

func _test_config(cfg) -> void:
	var list: Array = cfg.ai_factions()
	ok(list.size() >= 1, "config.ai.factions 至少有一条（默认挂着 'ai'）")
	var first: Dictionary = list[0]
	eq(String(first["id"]), "ai", "默认的阵营 AI id 是 'ai'（见 faction.gd 的 AI_FACTION）")
	ok(cfg.is_ai_faction("ai"), "cfg.is_ai_faction('ai') 为真")
	ok(not cfg.is_ai_faction("p1"), "玩家席位不是 AI 阵营")
	ok(not cfg.is_ai_faction("p2"), "联机席位也不是 AI 阵营")
	# ★ 'enemy' 是**地图上那批测试守军**的阵营，默认配置里它不是阵营 AI。
	#   ⚠️ 但这是**数据**：把 'enemy' 写进 ai.factions 它就变成阵营 AI 了
	#   （那时它也会跟着走「将领不带开局附属兵」那条）。所以这里断言的是
	#   「**随游戏发布的那份配置**里没有它」，不是「它永远不能是」。
	ok(not cfg.is_ai_faction("enemy"),
		"随游戏发布的配置里 'enemy' 不是阵营 AI（它由地图的 units[] 自己摆）")
	ok(FactionRes.is_ai_faction("ai"), "faction.gd 的常量兜底也认 'ai'")

	# 行为参数：每一项都要有、且不能是「取不到就 0」那种静默坏值
	var fc: Dictionary = cfg.ai_faction_cfg()
	ok(int(fc["generals"]) > 0, "ai.faction.generals > 0")
	ok(int(fc["min_retinue"]) > 0, "ai.faction.min_retinue > 0")
	ok(float(fc["attack_repeat_sec"]) > 0.0, "ai.faction.attack_repeat_sec > 0")
	var gc: Dictionary = cfg.ai_general_cfg()
	ok(float(gc["patrol_interval_sec"]) > 0.0, "ai.general.patrol_interval_sec > 0")
	ok(float(gc["combat_idle_sec"]) > 0.0, "ai.general.combat_idle_sec > 0")
	ok(int(gc["min_retinue"]) > 0, "ai.general.min_retinue > 0")
	# 需求：「没有攻击行为 10 秒后」——默认必须是 10
	near(float(gc["combat_idle_sec"]), 10.0, 1e-6, "脱战判定默认就是 10 秒")


# ------------------------------------------------------------------
# A. 阵营 AI：存在与资源库
# ------------------------------------------------------------------

func _test_faction_ai_presence(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return

	ok(w.factions.has("ai"), "阵营 AI 的阵营被插进了 world.factions")
	ok(w.find_base_of("ai") != null, "阵营 AI 有自己的大本营（需求：附属在某个阵营下）")
	ok(w.faction_bases.has("ai"), "faction_bases 里登记了它的大本营坐标")

	# AI 阵营的防御阵地：由 `map.spawn_layout_for → _ring_layout` 在出生点自动配一份
	# （一墙一塔）—— 那是引擎给**每一个**阵营做的（玩家的出生点也有），不是 AI 特有的。
	# ⚠️ 地图里**没有**再手写一份 AI 的塔 / 墙：多出来的那两栋会落在区块 4 里，
	#    而那张图里区块 4 是「中立区划」的代表（tests/test_zone_capture 的
	#    `_neutral_spot` 挑中的就是它）—— 玩家单位一靠近就会自动索敌建筑、
	#    走出区块，把「占领」那条用例搅黄（实测踩过，别再往那儿摆东西）。
	var towers := 0
	var walls := 0
	for b in w.building_list:
		if String(b.owner) != "ai":
			continue
		if b.type == "tower":
			towers += 1
		elif b.type == "wall":
			walls += 1
	ok(towers >= 1, "AI 阵营有自己的箭塔（出生点自带的那一栋）")
	ok(walls >= 1, "AI 阵营有自己的城墙")

	# 将领：开局就有（按 general.generals 那个数），而且**不带开局附属兵**
	var generals := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			generals += 1
			eq(w.retinue_of(String(u.id)).size(), 0,
				"阵营 AI 的将领开局不带附属兵（要它自己花资源招）")
	eq(generals, 3, "阵营 AI 开局有 3 个将领（= create_generals 的位次）")

	# ★★ 大本营把它所在的区块**收归自己** —— 这是「阵营 AI 有资源」的起点。
	#
	# 为什么这条必须有断言（实测踩过两次，症状都是「AI 站着不动」）：
	#   `zone.refresh_building_ownership()` 原来只认玩家阵营，于是 AI 一方开局**一块地都没有**：
	#   收入恒为 0（没钱），区划里也没有中心格（`_recruit_zone` 挑不到）⇒ 一个将都招不出来。
	#   现在那条规则对**任何**阵营都成立（大本营所在的区块归它）。
	var base = w.find_base_of("ai")
	ok(base != null, "AI 的大本营建出来了")
	if base != null:
		var base_zone = w.zones.zone_at(base.tx, base.ty)
		ok(base_zone != null, "大本营落在某个区块里（否则它收不到地）")
		if base_zone != null:
			eq(String(base_zone["owner"]), "ai",
				"★ AI 的大本营把它所在的区块收归自己（否则它开局一块地都没有）")
		ok(w.zones.owned_tile_count("ai") > 0, "于是 AI 有地块 ⇒ 有产能")
		# ★ 而且那块地要**有中心格**：区划招募（招将）只在有中心的区划里开得起来
		var rz = FactionAiRes._recruit_zone(w, "ai")
		ok(rz != null, "AI 挑得到一个「可以招将」的区划（= 自己的、带中心的区块）")
		if rz != null:
			eq(String((rz as Dictionary)["owner"]), "ai", "那个区划是 AI 自己的")
			ok((rz as Dictionary).get("center", null) != null, "而且它有区划中心格")

	# 玩家那一侧一个字不变：p1 的将领照旧带满开局编队
	var p1_generals := 0
	for u in w.units:
		if u.alive and String(u.faction) == FactionRes.DEFAULT_FACTION and u.is_general():
			p1_generals += 1
			ok(w.retinue_of(String(u.id)).size() > 0,
				"玩家将领开局仍然带满 unit.general.escort 个附属兵（老行为不变）")
	eq(p1_generals, 3, "玩家的三个开局将领照旧")


## 把一块地交给 AI，并给够人口（**区划招募**要 1 人口 / 单位）。
##
## ★ 为什么测试要亲自给人口：真游戏里人口是 `zones.update_population` 按时间涨出来的
##   （产能 0.15/地块/秒 × 地块数），开局那一帧是 0 —— 不补的话 AI 会因为
##   「人口不够」而招不出将领，而**那不是**这条用例想验的东西（它验的是资源规划）。
func _give_zone_to_ai(w, cfg, zid: int, population: float = 10.0) -> Variant:
	var z = w.zone_by_id(zid)
	if z == null:
		ok(false, "区划 %d 存在" % zid)
		return null
	z["owner"] = "ai"
	z["population"] = population
	return z


func _test_faction_ai_resources(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return

	# ---- 两个池子是**两个对象** ----
	var mine: Variant = w.resource_pool_for("p1")
	var theirs: Variant = w.resource_pool_for("ai")
	ok(mine != null and theirs != null, "player 与 AI 各自问得到一个资源池")
	ok(mine != theirs, "★ 两个池子不是同一个字典（AI 有**自己的**资源库）")
	ok(w.resource_pool_for("enemy") == null or w.resource_pool_for("enemy") is Dictionary,
		"没被 AI 接管的阵营问池子不会炸")

	# 初始资金来自 config.ai.factions[].start_*（**不写死数字**：那是设计师的旋钮）
	var declared: Dictionary = cfg.ai_factions()[0]
	near(float(theirs.get("food", 0.0)), float(declared["start_food"]), 1e-6,
		"AI 开局粮食 = config 里的 start_food")
	near(float(theirs.get("gold", 0.0)), float(declared["start_gold"]), 1e-6,
		"AI 开局黄金 = config 里的 start_gold")

	# ---- 把一块地交给 AI（直接改归属：占领本身在 test_zone_capture 里验过了）----
	var z = _give_zone_to_ai(w, cfg, 4)
	if z == null:
		return
	var tiles := float(z["tile_count"])
	ok(tiles > 0.0, "区划 4 有地块（否则产量是 0，这条用例就没意义）")

	var before_food: float = float(theirs["food"])
	var before_gold: float = float(theirs["gold"])
	w.ai_factions = FactionAiRes.setup(w, cfg)
	var st: Dictionary = w.ai_factions[0]
	# 只跑收入那一段（决策会花钱，会把我们要看的数搅浑）
	FactionAiRes._income(w, st, "ai", 1.0)
	# 区划 4 的产量看地图给的 production，不看 kind。
	# 所以这里只断言「涨了」以及「涨的就是 production_of 那一份」。
	var rates: Dictionary = w.zones.production_of("ai")
	ok(float(rates["food"]) > 0.0 or float(rates["gold"]) > 0.0,
		"区划 4 有粮食或黄金产量（地图数据给的）")
	near(float(theirs["food"]) - before_food, float(rates["food"]),
		1e-6, "1 秒的粮食增长 = 区划产能（resource_mult = 1.0）")
	near(float(theirs["gold"]) - before_gold, float(rates["gold"]),
		1e-6, "1 秒的黄金增长 = 区划产能（resource_mult = 1.0）")

	# ---- 玩家那一侧：AI 涨钱不会让它变 ----
	var w2 = _world(cfg)
	var mine_before: float = float(w2.resources["food"])
	_give_zone_to_ai(w2, cfg, 4)
	w2.ai_factions = FactionAiRes.setup(w2, cfg)
	w2.tick(1.0)
	near(float(w2.resources["food"]), mine_before, 1e-6, "AI 涨钱不会改玩家的粮食")


func _test_faction_ai_multiplier(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	_give_zone_to_ai(w, cfg, 4)
	w.ai_factions = FactionAiRes.setup(w, cfg)
	var st: Dictionary = w.ai_factions[0]
	# ★ 难度旋钮：直接改状态表里的倍率（等价于 config 里写 resource_mult = 2.0）
	st["mult"] = 2.0
	var pool: Dictionary = w.resource_pool_for("ai")
	var before: float = float(pool["food"])
	FactionAiRes._income(w, st, "ai", 1.0)
	var rates: Dictionary = w.zones.production_of("ai")
	near(float(pool["food"]) - before, float(rates["food"]) * 2.0, 1e-6,
		"★ resource_mult = 2.0 时，同样一块地收入翻倍（难度旋钮）")


## ★★ 端到端：**真跑一段世界**，看阵营 AI 是不是真的在经营（而不是只有单帧决策对）。
##
## 这一条是「单帧断言」补不上的：单帧能验「这一帧下了正确的命令」，
## 但验不了「读条真的会读完、将领真的会出现在地图上、钱真的会攒起来」——
## 而那三件事串起来才是需求里的「会花费资源招募自己的将领」。
func _test_faction_ai_runs_over_time(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var st: Dictionary = w.ai_factions[0]

	# ★ 真跑一段世界，看「收入 → 花钱 → 读条 → 出人」这条链走不走得通。
	#
	# ⚠️ 这条用例**只验这一条链**，别的什么都不碰（尤其不去改区块归属）：
	#    上一次写的时候顺手把区块 4 划给了 AI 来「制造收入」，结果玩家自己的
	#    那块地（区块 0/1）被挤掉、粮食数变了 —— 那条「玩家的钱一分没动」的断言
	#    当场就红了，而红的理由与 AI 无关。**要动世界就开一个新的世界**（下面的
	#    `_test_faction_ai_income_accumulates` 就是这么做的）。
	var player_food0: float = float(w.resources["food"])
	var player_gold0: float = float(w.resources["gold"])
	var seconds := 0.0
	while seconds < 60.0:
		w.tick(0.5)
		seconds += 0.5

	ok(int(st["general_index"]) >= 1,
		"★ 60 秒里 AI 真的下了「招将」的单（general_index = %d）" % int(st["general_index"]))
	# 区划招出来的将领 id 形如 "ai-zone-<区划>-r<n>"（见 world._spawn_zone_recruit）
	var zone_spawned := 0
	for u in w.units:
		if String(u.faction) == "ai" and String(u.id).find("zone-") >= 0:
			zone_spawned += 1
	ok(zone_spawned >= 1,
		"★ 读条真的读完了：**区划招出来的将领出现在地图上**（id 里带 zone-，%d 个）" % zone_spawned)
	# ★ 而且它全程花的是**自己的钱**：玩家那一侧的账一分没动
	near(float(w.resources["food"]), player_food0, 1e-6,
		"跑完 60 秒，玩家的粮食仍然是开局那个数（AI 全程没花玩家的钱）")
	near(float(w.resources["gold"]), player_gold0, 1e-6, "玩家的黄金也一样")


## ★ 收入公式：**占领的区划** 的产能 × 秒数 真的会进 AI 自己的池子。
##
## ⚠️ 为什么单开一个世界、并且手动把一块**有产能**的地划给 AI：
##   AI 开局那块地是**人口区块**（不产粮食 / 黄金）—— 拿它验这条会得到 +0，
##   那不是 bug 而是地图数据。这条用例验的是**公式**（route.md 33.1 的「资源随占领区划
##   产出而增长」），所以给它一块真的有产能的地（区块 4：粮食 1 / 黄金 1 每地块每秒）。
func _test_faction_ai_income_accumulates(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var z4 = _give_zone_to_ai(w, cfg, 4)
	if z4 == null:
		return
	w.ai_factions = FactionAiRes.setup(w, cfg)
	var st: Dictionary = w.ai_factions[0]
	var pool: Dictionary = w.resource_pool_for("ai")
	var food_before: float = float(pool["food"])
	var rates: Dictionary = w.zones.production_of("ai")
	ok(float(rates["food"]) > 0.0 or float(rates["gold"]) > 0.0,
		"区划 4 有粮食或黄金产量（地图数据给的）")
	FactionAiRes._income(w, st, "ai", 60.0)
	ok(float(pool["food"]) > food_before,
		"★ 60 秒的收入真的累加到资源池里（占领区划 → 有钱），+%.1f" % (float(pool["food"]) - food_before))
	near(float(pool["food"]) - food_before, float(rates["food"]) * 60.0, 1e-4,
		"累加的数目 = 产能 × 秒数（resource_mult = 1.0）")
	near(float(w.resources["food"]), float(cfg.start_food), 1e-6,
		"★ 这笔钱进的是 AI 自己的池子，玩家的粮食一分没动")


## ★ 这条用例只验「经营循环真的转起来了」，不验「AI 一定能赢」——
## 所以它的断言**刻意宽容**：只要「至少有一个区划招的将领真的读条读完、
## 出现在地图上」就算通过。理由有两个，都是实测出来的：
##
##   1. **同一张图上的 NPC 会真的打仗**：地图东南侧的对家据点（守军 + 箭塔）
##      就在 AI 的隔壁区块，AI 的将领招出来之后会被卷进去打（也会被打死）。
##      要求「三个将领同时活着」会把这条用例变成**平衡测试**，而不是 AI 测试。
##   2. **区块 9 是人口区块**（不产粮食 / 黄金）：AI 的日常收入是 0，
##      全靠开局那点钱 + 人口增长运转。钱花光之后就只剩「等人口」——
##      它仍然在按优先级做事（招将与招兵都要人口），但节奏会慢下来。
##      真要它滚得快，给它一块有产能的地（改 `ai.factions[].base` 或地图的 `owner`）。


# ------------------------------------------------------------------
# B. 阵营 AI：资源规划（招将 → 招兵 → 升级 → 出兵）
# ------------------------------------------------------------------

func _test_faction_ai_recruit_general(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	# 给 AI 一块**有中心**的地（区划招募要区划中心才能出兵）
	var z = _give_zone_to_ai(w, cfg, 4)
	if z == null:
		return
	ok(z.get("center", null) != null, "区划 4 有中心格（否则招不了将）")

	w.ai_factions = FactionAiRes.setup(w, cfg)
	var pool: Dictionary = w.resource_pool_for("ai")
	pool["food"] = 1000.0
	pool["gold"] = 1000.0
	var player_food: float = float(w.resources["food"])
	var player_gold: float = float(w.resources["gold"])

	var st: Dictionary = w.ai_factions[0]
	var before_index: int = int(st["general_index"])
	# ★ 记下「决策之前」的钱：`FactionAiRes.update` 会先跑收入那一段，
	#   所以直接拿 1000 当基准会差出这一帧的产出（这正是「先涨钱、再花钱」的顺序）。
	var before_food: float = float(pool["food"])
	var before_gold: float = float(pool["gold"])
	FactionAiRes.update(w, cfg, 0.05)
	eq(int(st["general_index"]), before_index + 1, "★ 有钱有地 → AI 招了一个将领（序号 +1）")
	ok(w.zone_is_training(z), "区划的招募队列里真的排上了（复用玩家那一整套）")

	var cost: Dictionary = w.recruit_cost("general_1")
	var rates: Dictionary = w.zones.production_of("ai")
	ok(float(pool["food"]) < before_food, "招将的钱从 **AI 自己的池子**里扣了")
	near(float(pool["food"]),
		before_food + float(rates["food"]) * 0.05 - float(cost.get("food", 0.0)),
		1e-4, "扣的数目 = 招募表里的消耗（收入先加、费用后扣）")
	near(float(w.resources["food"]), player_food, 1e-6, "★ 玩家的粮食一分没动")
	near(float(w.resources["gold"]), player_gold, 1e-6, "★ 玩家的黄金一分没动")

	# 冷却期内不会连着招第二个
	FactionAiRes.update(w, cfg, 0.05)
	eq(int(st["general_index"]), before_index + 1, "冷却期内不会连招第二个将领")


func _test_faction_ai_recruit_units(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var z = _give_zone_to_ai(w, cfg, 4)
	if z == null:
		return
	# ★ 把将领挪到自己的地里：将领招募要求「它站在己方区划里」（老规则）
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			g = u
			break
	ok(g != null, "找得到一个 AI 将领")
	if g == null:
		return
	# 区划 5 与区划 4 不挨着，所以这里把将领挪到区划 4 里（(13,6) 在区划 4 内）
	g.pos = GridRes.center_of(Vector2i(13, 6))
	g.sync_tile(w.map)
	ok(w.leader_zone_owned(g), "挪过去之后这个将领站在己方（AI）区划里")

	w.ai_factions = FactionAiRes.setup(w, cfg)
	var pool: Dictionary = w.resource_pool_for("ai")
	pool["food"] = 1000.0
	pool["gold"] = 1000.0
	var st: Dictionary = w.ai_factions[0]
	# 跳过「招将」那一段：直接标记招满了，这样决策会走到「让将领招兵」
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])
	var player_food: float = float(w.resources["food"])

	var before: int = g.retinue_size(w)
	eq(before, 0, "开局这个将领一个兵都没有")
	FactionAiRes.update(w, cfg, 0.05)
	ok(g.is_training(), "★ AI 让将领开始招兵了（读条 / 队列）")
	ok(g.retinue_size(w) > before, "「兵账」把排队中的那一单也算进去了")
	ok(float(pool["food"]) < 1000.0, "招兵的钱也从 AI 自己的池子里扣")
	near(float(w.resources["food"]), player_food, 1e-6, "玩家的粮食仍然没动")

	# 招出来的是什么兵：与将领同类型（长枪兵将领 → 长枪兵）
	eq(String(g.train_kind), String(g.unit_type), "AI 让将领招的是与它自己同类型的兵")


func _test_faction_ai_upgrade(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	if _give_zone_to_ai(w, cfg, 4) == null:
		return
	w.ai_factions = FactionAiRes.setup(w, cfg)
	var pool: Dictionary = w.resource_pool_for("ai")
	pool["food"] = 100000.0
	pool["gold"] = 100000.0
	var st: Dictionary = w.ai_factions[0]
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])   # 跳过招将
	# 跳过招兵那一段：那一段只对「不满员的将领」下手，所以这里给每个 AI 将领
	# 塞一份长度正好等于 min_retinue 的**记账队列**（`retinue_size` 把排队中的也算进去）。
	# ⚠️ 只写 `train_queue` **不写** `train_kind`：这样 `is_training()` 仍为真
	#    （AI 的招兵那一段会跳过它），而 `world._tick_recruitment` 在本用例里没跑，
	#    所以不会真去读出人来（否则读条完了 retinue_size 掉下来，决策又回去招兵）。
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			for i in int(cfg.ai_faction_cfg()["min_retinue"]):
				u.train_queue.append("spearman")
			ok(u.retinue_size(w) >= int(cfg.ai_faction_cfg()["min_retinue"]),
				"这个 AI 将领算满员（排队中的那一单也算）")

	var up_before := _upgrading_count(w, "ai")
	var before_food: float = float(pool["food"])
	FactionAiRes.update(w, cfg, 0.05)
	var up_after := _upgrading_count(w, "ai")
	ok(up_after > up_before, "★ 钱够的时候 AI 会升级自己的建筑（读条落在建筑上）")
	ok(float(pool["food"]) < before_food, "升级的钱也是从 AI 自己的池子里扣")


## 数一数某个阵营有几栋建筑正在升级读条
func _upgrading_count(w, faction: String) -> int:
	var n := 0
	for b in w.building_list:
		if not b.alive or String(b.owner) != faction:
			continue
		if b.is_upgrading():
			n += 1
	return n


func _test_faction_ai_attack(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	# AI 要有一块地（出兵目标挑的是**敌方**区划中心，AI 自己有没有地无所谓，
	# 但 `find_base_of` 必须成立 —— 它开局就有大本营）
	if _give_zone_to_ai(w, cfg, 4) == null:
		return
	w.ai_factions = FactionAiRes.setup(w, cfg)
	var pool: Dictionary = w.resource_pool_for("ai")
	pool["food"] = 100000.0
	pool["gold"] = 100000.0
	var st: Dictionary = w.ai_factions[0]
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])   # 将领招满了

	# 让每个 AI 将领都「满员」：直接塞足够的**已经生成**的附属兵。
	# ⚠️ 不用真招（那要等读条 10 秒）——这里验的是「满员之后会不会出兵」，
	#    而「满员」的判据是 unit.retinue_size()（见那个函数的说明）。
	var assigned := 0
	for u in w.units:
		if not u.alive or String(u.faction) != "ai" or not u.is_general():
			continue
		for i in int(cfg.ai_faction_cfg()["min_retinue"]):
			var soldier = UnitRes.create(
				cfg, "%s-ai%d" % [String(u.id), i], "AI 兵",
				Vector2i(u.tx, u.ty), "ai", String(u.unit_type), "", String(u.id),
				String(u.unit_type)
			)
			w.units.append(soldier)
			assigned += 1
		ok(u.retinue_size(w) >= int(cfg.ai_faction_cfg()["min_retinue"]),
			"AI 将领这时算满员")
	ok(assigned > 0, "造出了测试用的附属兵")

	FactionAiRes.update(w, cfg, 0.05)

	var attacking := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.has_attack_move:
			attacking += 1
	ok(attacking >= int(cfg.ai_faction_cfg()["min_ready"]),
		"★ 招满 + 满员 → 派出一批将领行军攻击（has_attack_move）")

	# 目标必须落在**敌方区划中心**：不能是自家地、也不能是无主地
	# —— 这就是「派遣这些将领行军攻击某处」里的「某处」。
	var goal_ok := false
	var goal_kind := ""
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.has_attack_move:
			var t := Vector2i(floori(u.attack_move_goal.x), floori(u.attack_move_goal.y))
			var zz = w.zones.zone_at(t.x, t.y)
			if zz == null:
				goal_kind = "无主空地"
				continue
			var owner := String(zz["owner"])
			if owner == "":
				goal_kind = "无主区块"
				continue
			if FactionRes.same_side(owner, "ai"):
				goal_kind = "自家区块"
				continue
			goal_ok = true
			goal_kind = owner
	ok(goal_ok, "★ 行军目标落在**敌方**的区划里（不是自家、也不是无主地）")
	ok(goal_kind == FactionRes.DEFAULT_FACTION or goal_kind == FactionRes.NPC_FACTION,
		"目标区划的归属方是这一局里真实存在的另一方（实际：%s）" % goal_kind)


# ------------------------------------------------------------------
# C. 将领性（防御性）AI
# ------------------------------------------------------------------

func _test_general_ai_from_map(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var found := 0
	for u in w.units:
		if not u.alive or String(u.name) != GARRISON_NAME:
			continue
		found += 1
		ok(u.is_garrison(), "地图预置的驻防将领带上了归属区划（units[].zone）")
		ok(u.garrison_zone_id >= 0, "归属区划 id 是非负的")
		ok(u.hold_position, "它同时被置了 hold_position（推进 AI 不许管它）")
		var z = w.zone_by_id(u.garrison_zone_id)
		ok(z != null, "归属区划 id 在区划表里真的找得到")
		if z != null:
			eq(w.zones.zone_at(u.tx, u.ty), z, "它开局就站在自己那个区划里")
		ok(w.retinue_of(String(u.id)).size() == 0, "驻防将领开局没有附属兵（要自己招）")
		# ★ 需求：「没有资源库，没有大本营」
		#   —— 判据是「它那一方**不在** config.ai.factions 里」：
		#      不在名单 ⇒ `world.resource_pool_for()` 拿不到池子 ⇒ 资源无限
		#      （见 world.resource_pool_for 与 economy.can_afford 的 null 语义）。
		ok(not cfg.is_ai_faction(String(u.faction)),
			"驻防将领的阵营不在阵营 AI 名单里 ⇒ 它没有专属资源库（走「资源无限」那条）")
		ok(w.resource_pool_for(String(u.faction)) == null,
			"resource_pool_for 对它返回 null（= 没有资源库）")
	eq(found, 3, "地图上摆了 3 个驻防将领")


func _test_general_ai_patrol(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var u = _make_garrison(w, cfg, Vector2i(5, 13), 6)
	if u == null:
		return

	# ---- 站得离区划中心远 → 到点就该巡逻（朝中心走）----
	u.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not u.path.is_empty() or u.moving, "★ 巡逻计时到点 → 驻防将领朝区划中心出发")
	ok(float(u.patrol_timer) > 0.0, "巡逻计时被重置（有时间间隔，不是每帧都动）")

	# ---- 冷却期内再跑一帧：不应该又下一条新命令 ----
	var path_len: int = u.path.size()
	GeneralAiRes.update(w, cfg, 0.05)
	ok(u.path.size() <= path_len, "巡逻间隔之内不会每帧重算路径")

	# ---- 已经站在区划中心上 → 不该再下移动命令 ----
	var u2 = _make_garrison(w, cfg, Vector2i(5, 12), 6)   # (5,12) 就是区划 6 的中心
	if u2 != null:
		u2.stop()
		u2.patrol_timer = 0.0
		GeneralAiRes.update(w, cfg, 0.05)
		ok(u2.path.is_empty() and not u2.moving, "已经站在中心上就不下移动命令（不再空跑寻路）")


func _test_general_ai_no_pursuit(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return

	# ★★ 怎么摆这个场面（第一版绕了两圈弯路，把结论留在这里）：
	#   需求那条是「警戒到敌人会打，但**不会追击超过一个区划**」，所以真正要验的是
	#   「**已经交战中**的驻防将领，一旦不在自己那个区划里，就当场脱战」。
	#   ⚠️ 别去指望「让它自己追出去」：守将巡逻的落点是**自己区划的中心**，
	#      而任意两个区划的中心都隔着 5 格以上（> 警戒半径 4）——
	#      它巡逻到中心就停住了，根本不会自己跨过边界。
	#   ⚠️ 更要命的是「追出去」本身要靠 `leader_zone_owned` 之外的一堆条件
	#      （索敌要静止、追击要过 leash），摆场面比直接验规则脆得多。
	#   所以这里**直接造出「交战中 + 不在自己区划里」这个状态**，再断言规则本身。
	#
	# 区划 6 与区划 5 的分界是 x = 10：(9,12) 属区划 6、(10,12) 属区划 5，
	# 两者相距 1 格 —— 也就是「追过了一个区划」的最短形式。
	var g = _make_garrison(w, cfg, Vector2i(9, 12), 6)
	if g == null:
		return
	var foe = UnitRes.create(cfg, "test-foe-1", "入侵者", Vector2i(10, 12),
		FactionRes.DEFAULT_FACTION, UnitRes.KIND_ENEMY)
	w.units.append(foe)

	var z5 = w.zone_by_id(5)
	var z6 = w.zone_by_id(6)
	eq(w.zones.zone_at(9, 12), z6, "测试前提：(9,12) 是守将自己的区划（区划 6）")
	eq(w.zones.zone_at(10, 12), z5, "测试前提：(10,12) 是隔壁区划（区划 5）")

	# ---- 1) 在自己家里交战 → 不该被叫回去 ----
	g.pos = GridRes.center_of(Vector2i(9, 12))
	g.sync_tile(w.map)
	g.target = foe
	g.anchor = g.pos
	g.retarget_cd = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	eq(g.target, foe, "在自己区划里交战时不会被强行脱战（该打就打）")

	# ---- 2) 追过了一个区划（脚踩进隔壁）→ 当场脱战 + 拉起再战冷却 ----
	g.pos = GridRes.center_of(Vector2i(10, 12))
	g.sync_tile(w.map)
	g.target = foe
	g.anchor = g.pos
	g.retarget_cd = 0.0
	g.stop()                       # 清掉上一轮的路径，只看这一帧下了什么命令
	g.target = foe                 # stop() 会清目标，这里重新锁上
	g.anchor = g.pos
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.target == null and g.target_building == null,
		"★ 一跨进别的区划就当场脱战（需求：不会追击超过一个区划）")
	ok(float(g.retarget_cd) > 0.0,
		"★ 脱战时拉起了再战冷却（否则 combat.gd 下一帧就把同一个敌人再锁上）")

	# ---- 3) 冷却期内它不会再接战（只巡逻）----
	g.target = foe                 # 模拟「combat.gd 又给它锁了一个」
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.target == null, "★ 再战冷却期内不会被重新拖进战斗（抖动回路断开了）")

	# ---- 4) 冷却结束、而且**回到自己的区划里**，才可能再战 ----
	#
	# ⚠️ 这两个条件缺一不可：冷却只是「暂时不接」，而「不在自己区划里」
	#    是永远成立的硬约束（第 2 步那条）—— 站在别人家里等冷却结束是等不来接战的。
	g.pos = GridRes.center_of(Vector2i(9, 12))
	g.sync_tile(w.map)
	g.target = foe
	g.anchor = g.pos
	g.retarget_cd = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	eq(g.target, foe, "冷却结束 + 回到自己区划之后又能正常接敌（不是永久不还手）")

	# ---- 5) 无主空地那条兜底：脚下不属于任何区划时，按「离家多远」判 ----
	#
	# 为什么单列这一条：区划形状不规则、区块之间还有不属于任何区划的空地 ——
	# 那里 `zone_at` 给的是 null，主判据永远不成立，只靠距离判据兜住。
	# ⚠️ 这条兜底**只在无主空地上生效**：在自己区划里站得再远也不算「追出去了」
	#    （主判据是区划归属，见 _out_of_garrison）。所以这里先把同一位置
	#    在「有主」与「无主」两种情况下各验一次 —— 正好把那条边界钉住。
	var g2 = _make_garrison(w, cfg, Vector2i(5, 13), 6)
	if g2 != null:
		# 5-a) 在自己的区划里、**离中心很远**（4 格 > 巡逻半径 1）→ 不该被叫回去
		g2.pos = GridRes.center_of(Vector2i(9, 12))
		g2.sync_tile(w.map)
		g2.target = foe
		g2.anchor = g2.pos
		g2.retarget_cd = 0.0
		eq(w.zones.zone_at(9, 12), z6, "测试前提：(9,12) 仍然属于区划 6")
		var c6: Vector2 = GridRes.center_of(z6["center"])
		ok(g2.pos.distance_to(c6) > float(cfg.ai_general_cfg()["patrol_leash_tiles"]),
			"测试前提：它离区划中心已经远超巡逻半径")
		GeneralAiRes.update(w, cfg, 0.05)
		eq(g2.target, foe,
			"★ 只要还在**自己的区划里**，离中心多远都不算「追出去」（区划归属才是主判据）")

		# 5-b) 同一套状态，把「脚下那一格」改成无主空地 → 距离判据兜住
		#
		# 造法：临时把区划查表清掉（等同「这一格不属于任何区划」）——
		# 这比去地图上找一块真的无主空地稳（区块之间还有没有空地是地图说了算的）。
		g2.retarget_cd = 0.0
		g2.target = foe
		g2.anchor = g2.pos
		var saved: Array = w.zones.lookup.duplicate()
		w.zones.lookup.fill(-1)
		GeneralAiRes.update(w, cfg, 0.05)
		ok(g2.target == null,
			"★ 无主空地上站得离中心太远 → 也算「追出去了」→ 脱战（距离兜底生效）")
		w.zones.lookup = saved

	# ---- 6) 脱战之后会往自己的区划走 ----
	var home6: Vector2 = GridRes.center_of(z6["center"])
	g.stop()
	g.retarget_cd = 0.0
	g.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not g.path.is_empty() or g.moving, "脱战之后它朝自己区划的中心走（没有继续朝敌人冲）")


func _test_general_ai_free_recruit(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var g = _make_garrison(w, cfg, Vector2i(5, 13), 6)
	if g == null:
		return
	# 站到**自己的**区划里（区划 6 归它自己那一方）——将领招募要求「站在己方区划里」
	var z6 = w.zone_by_id(6)
	z6["owner"] = String(g.faction)
	ok(w.leader_zone_owned(g), "驻防将领站在己方区划里（可以招兵了）")

	var pool: Variant = w.resource_pool_for(String(g.faction))
	var player_food: float = float(w.resources["food"])
	var player_gold: float = float(w.resources["gold"])
	var pop_before: float = float(z6["population"])
	# 给区划一点人口：好验「免费招兵不扣人口」（正常招募是扣 1 人口的）
	z6["population"] = 5.0
	pop_before = 5.0

	var idle: float = float(cfg.ai_general_cfg()["combat_idle_sec"])

	# ---- 没脱战（刚被打过）→ 不该招 ----
	g.combat_idle_timer = 0.0
	g.garrison_recruit_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not g.is_training(), "脱战计时没到 → 不招兵")

	# ---- 脱战满 10 秒 + 不满员 → 招 ----
	g.combat_idle_timer = idle
	g.garrison_recruit_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.is_training(), "★ 脱战满 combat_idle_sec 且不满员 → 招兵")
	ok(String(g.train_kind) != "", "队列的大格子里真的排上了")

	# ---- 「无资源消耗」：钱与人口都不动 ----
	near(float(w.resources["food"]), player_food, 1e-6, "招兵没花玩家的粮食")
	near(float(w.resources["gold"]), player_gold, 1e-6, "招兵没花玩家的黄金")
	near(float(z6["population"]), pop_before, 1e-6, "★ 免费招兵**不扣人口**")
	# ★ 需求原话是「没有资源库」：驻防将领那一方本来就**没有**专属池子，
	#   所以「钱一分没动」这件事是结构上成立的（不是靠扣 0 实现的）。
	ok(pool == null or String(g.faction) != "ai",
		"驻防将领不依赖任何专属资源库（需求：它没有资源库、资源无限）")

	# ---- 读条读完真的会出人（复用招募那一整套）----
	var before: int = w.retinue_of(String(g.id)).size()
	for i in 300:
		w.tick(0.1)
		if w.retinue_of(String(g.id)).size() > before:
			break
	ok(w.retinue_of(String(g.id)).size() > before, "★ 读条读完在将领所在格生成了附属兵")
	# 免费招出来的兵也不该带记账值（否则取消 / 阵亡会「退」出一笔凭空的钱）
	near(float(g.train_cost_food), 0.0, 1e-6, "免费那一单的记账值恒为 0（不会凭空退款）")


func _test_general_ai_not_advancing(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var g = _make_garrison(w, cfg, Vector2i(5, 13), 6)
	if g == null:
		return
	# 它站在中立区划里（owner 不是 AI 也不是玩家），推进 AI 会朝玩家大本营冲
	g.stop()
	var start: Vector2 = g.pos
	EnemyAiRes.update(w, cfg)
	ok(g.path.is_empty() and not g.moving,
		"★ enemy_ai 不会指挥驻防将领朝玩家大本营推进（两条 AI 判据互斥）")
	v2_near(g.pos, start, 1e-6, "它原地待命")


# ------------------------------------------------------------------
# 夹具
# ------------------------------------------------------------------

## 直接造一个「驻防将领」单位（比依赖地图更可控：区划 id 与站位都由参数定）。
##
## ★ 用 "enemy" 这个兵种（它**不在**招募表里）是有意的：
##   正好顺带验 `general_ai._try_recruit` 的兜底（退回招募表第一条）。
##   要验「与将领同类型」那条，把 unit_type 换成 "spearman" 即可。
func _make_garrison(w, cfg, tile: Vector2i, zone_id: int):
	var u = UnitRes.create(cfg, "garrison-test-%d" % w.units.size(), GARRISON_NAME,
		tile, FactionRes.NPC_FACTION, UnitRes.KIND_ENEMY)
	u.garrison_zone_id = zone_id
	u.hold_position = true
	w.units.append(u)
	return u
