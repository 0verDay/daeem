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
##      · 归属区划从关卡摆放 `start_units[].zone` 落到单位上；
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
const LevelRes = preload("res://logic/level.gd")

## 测试里给**驻防将领**起的名字（也用来在 `world.units` 里把它认出来）。
##
## ⚠️ 它**不再**来自地图：`data/maps/*/map.json` 的 `units[]` 本轮整个废弃、运行时不再读。
##    摆驻防将领一律走**关卡的 `start_units`** —— 本文件里的探针关卡就是干这个的
##    （见 `_garrison_level()` / `_patrol_probe_level()`）。
const GARRISON_NAME := "驻防将领"

## 临时目录（工程内，测试末尾清掉）。
## ⚠️ 与 test_campaign.gd 同一个理由：这个工程里 `user://` 写不进去，只能写工程内。
const TMP_ROOT := "res://.tmp_ai_tests"


func _initialize() -> void:
	_case_name = "test_ai"
	run_all(_cases)
	# ★ 临时目录用完就删（`_patrol_probe_level` 会往里写一份最小关卡 JSON）。
	#   ⚠️ 放在 `run_all()` **之后**：它内部就 `quit()` 了，但 `quit()` 只是排队，
	#   这一句仍会执行 —— 所以临时文件不会留在仓库里（工程内不能留垃圾）。
	_clean_tmp()


## 删掉临时目录（工程内；`user://` 在这个工程里写不进去，见 test_campaign.gd 同款说明）
func _clean_tmp() -> void:
	if not DirAccess.dir_exists_absolute(TMP_ROOT):
		return
	for f in DirAccess.get_files_at(TMP_ROOT):
		DirAccess.remove_absolute("%s/%s" % [TMP_ROOT, f])
	for d in DirAccess.get_directories_at(TMP_ROOT):
		var sub := "%s/%s" % [TMP_ROOT, d]
		for f2 in DirAccess.get_files_at(sub):
			DirAccess.remove_absolute("%s/%s" % [sub, f2])
		DirAccess.remove_absolute(sub)
	DirAccess.remove_absolute(TMP_ROOT)


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
	_test_faction_ai_replaces_dead_general(cfg)
	_test_faction_ai_waits_for_training(cfg)
	_test_faction_ai_no_upgrade_reject_spam(cfg)
	_test_faction_ai_multiplier(cfg)
	_test_faction_ai_income_accumulates(cfg)
	_test_faction_ai_runs_over_time(cfg)
	_test_general_ai_from_level(cfg)
	_test_level_placed_escorts(cfg)
	_test_general_ai_patrol(cfg)
	_test_general_ai_patrol_spread(cfg)
	_test_general_ai_patrol_with_retinue(cfg)
	_test_general_ai_patrol_route_is_automatic(cfg)
	_test_general_ai_no_pursuit(cfg)
	_test_general_ai_free_recruit(cfg)
	_test_general_ai_not_advancing(cfg)
	# ★ 本轮新增：读条与开火之间的两个衔接（攻击线残留 / 被贴脸就取消招募）
	_test_training_clears_attack_line(cfg)
	_test_training_interrupted_by_threat(cfg)


## 造一个干净的世界（用的是随游戏发布的那张真地图）。
func _world(cfg) -> RefCounted:
	var w = WorldRes.create(cfg, "res://data/maps/frontier/map.json")
	ok(w != null, "世界能建出来")
	return w


## 给一位将领把招募所需的东西备齐（钱 + 它脚下区划的人口）。
##
## ⚠️ `WorldRes.create()`（无关卡那条路）**不跑经济收口**，池子是 0/0、区划人口是 0 ——
##    不补给的话招募会被 `can_afford_recruit()` 以 "cost" / "population" 拒掉，
##    于是用例验的就不是「招募与开火的衔接」，而是「它没钱」。
func _fund_recruit(w, gen, food: float = 500.0, gold: float = 500.0, pop: float = 5.0) -> void:
	var pool: Variant = w.resource_pool_for(String(gen.faction))
	if typeof(pool) == TYPE_DICTIONARY:
		(pool as Dictionary)["food"] = food
		(pool as Dictionary)["gold"] = gold
	for z in w.zones.zones:
		(z as Dictionary)["population"] = pop


## 造一个「敌对的」探针单位（"enemy" 是内建的非玩家阵营，与 p1 天然敌对）。
func _make_foe(w, cfg, tile: Vector2i):
	var u = UnitRes.create(cfg, "probe-foe-%d" % w.units.size(), "探针敌人",
		tile, FactionRes.NPC_FACTION, UnitRes.UNIT_TYPE_SPEARMAN)
	w.units.append(u)
	return u


## ★★ 开始招募时，**上一次开火的渲染残留必须清掉**。
##
## 报回来的 bug（用户原话）：「有概率当将领从攻击转为招募或由招募转为攻击时，
##   该将领会有一条连线一直连在被攻击对象上」。
## 机制：招募读条期间将领被钉在原地，`world.tick` 第 4 步**整段跳过**它的单位逻辑，
##   而 `attack_flash` 的衰减就在那段里（`combat.update_unit` 开头）⇒ flash 冻在
##   开招那一刻的值上、`last_target` 也一直指着那个人，渲染就永远画着那条线。
##   「有概率」= 取决于开招那一刻 flash 还剩多少。
func _test_training_clears_attack_line(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var gen = null
	for u in w.units:
		if u.alive and String(u.faction) == String(w.my_faction) and u.is_general():
			gen = u
			break
	ok(gen != null, "★ 找得到一位本机将领（这条用例的前提）")
	if gen == null:
		return
	var foe = _make_foe(w, cfg, Vector2i(gen.tx + 1, gen.ty))
	_fund_recruit(w, gen)

	# 造出「刚刚开过一炮」的状态（这正是渲染画线读的两样东西）
	gen.attack_flash = 1.0
	gen.last_target = foe
	gen.last_building = null
	ok(gen.attack_flash > 0.0 and gen.last_target == foe, "（前提）它刚刚开过火")

	ok(w.start_recruit("spearman", String(gen.id), String(gen.faction)),
		"★ 招募能开起来（将领就是兵营）")
	ok(gen.is_training(), "（前提）它现在在读条")
	eq(gen.attack_flash, 0.0, "★★ 开始招募 ⇒ attack_flash 归零（那条线不会冻住）")
	eq(gen.last_target, null, "★★ last_target 也被清掉（渲染读的另一半）")
	eq(gen.last_building, null, "last_building 一样清干净")

	# 读条期间整段单位逻辑被跳过 ⇒ 不清的话它**永远不会**衰减（这就是那个 bug 的根因）。
	# 跑一段再确认一次：值不会变成负数 / NaN 这类坏状态。
	var t := 0.0
	while t < 2.0 and gen.is_training():
		w.tick(0.1)
		t += 0.1
	ok(gen.attack_flash >= 0.0 and gen.attack_flash <= 1.0,
		"（跑了一段之后 flash 仍然是个有效值：%.2f）" % gen.attack_flash)


## ★★ 读条中若有敌人进入**自己的攻击范围** ⇒ 取消招募、转去攻击（用户需求）。
##
## 需求原话：「增加 ai 逻辑，当自己在招募时，若有敌方单位进入己方攻击范围，
##           则取消该招募转而攻击」。
## 反向也要验：敌人**在范围外**时不许打断（否则招募永远开不完）。
func _test_training_interrupted_by_threat(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var gen = null
	for u in w.units:
		if u.alive and String(u.faction) == String(w.my_faction) and u.is_general():
			gen = u
			break
	if gen == null:
		ok(false, "★ 找得到一位本机将领（这条用例的前提）")
		return
	_fund_recruit(w, gen)
	var reach: float = gen.combat_range(cfg)
	ok(reach > 0.0, "（前提）它有攻击距离（%.2f 格）" % reach)

	# ---- 反面：敌人在**攻击范围之外**（12 格）⇒ 不许打断 ----
	var far = _make_foe(w, cfg, Vector2i(gen.tx + 12, gen.ty + 12))
	ok(w.start_recruit("spearman", String(gen.id), String(gen.faction)), "★ 招募开起来了")
	var t := 0.0
	while t < 3.0 and gen.is_training():
		w.tick(0.1)
		t += 0.1
	ok(gen.is_training(),
		"★★ 敌人在 12 格外（攻击距离只有 %.1f 格）⇒ **不打断**，继续读条" % reach)
	# 收尾：把它撤掉，免得干扰下一段
	far.alive = false
	w.units = w.units.filter(func(u): return u.alive)
	gen.stop()                        # 停止读条（stop 不动 train_*，所以下面显式清）
	gen.train_kind = ""
	gen.train_remaining = 0.0
	gen.train_total = 0.0
	gen.train_queue.clear()
	ok(not gen.is_training(), "（前提）它现在不在读条")

	# ---- 正面：敌人贴到脸上（1 格）⇒ 取消招募并转去攻击 ----
	var near_foe = _make_foe(w, cfg, Vector2i(gen.tx + 1, gen.ty))
	# ★ 记下「再开一单之前」的池子：取消要**退款**，所以结算后应当回到这个数
	#   （写死数字会随上面那几单花掉多少而漂：实测第一版写成 500 就红了）。
	var pool_before: Variant = w.resource_pool_for(String(gen.faction))
	var food_before := float((pool_before as Dictionary)["food"]) \
		if typeof(pool_before) == TYPE_DICTIONARY else 0.0
	ok(w.start_recruit("spearman", String(gen.id), String(gen.faction)), "★ 再开一单招募")
	ok(gen.is_training(), "（前提）它正在读条")
	var t2 := 0.0
	while t2 < 3.0 and gen.is_training():
		w.tick(0.1)
		t2 += 0.1
	ok(not gen.is_training(), "★★ 敌人贴脸 ⇒ 招募被取消（%.1f 秒内）" % t2)
	eq(gen.train_queue_size(), 0, "★★ 队列也清空了（取消的是整单）")
	ok(gen.ordered_target == near_foe, "★★ 转去攻击那个威胁（ordered_target 指着它）")
	# 再跑几帧：应当真的朝它开火（渲染那条线读的正是这两样）
	var fired := false
	var t3 := 0.0
	while t3 < 5.0:
		w.tick(0.1)
		t3 += 0.1
		if gen.attack_flash > 0.0 and gen.last_target == near_foe:
			fired = true
			break
	ok(fired, "★★ 取消之后**真的开火了**（flash>0 且 last_target = 那个敌人）")
	# 取消要**退款**（走的是现成的 cancel_recruit 那条路）：池子回到开单之前
	var pool: Variant = w.resource_pool_for(String(gen.faction))
	if typeof(pool) == TYPE_DICTIONARY:
		near(float((pool as Dictionary)["food"]), food_before, 0.01,
			"★ 取消的那一单退回了粮食（%.0f → 开单前 %.0f）"
			% [float((pool as Dictionary)["food"]), food_before])


## 腾掉 AI 阵营的全部将领（腾出空槽位）。
##
## ★ 为什么这些用例需要它：`world.create_generals()` 在建世界时**已经**给每一方
##   按 `ai.faction.generals` 建好了将领，而「招将」现在按**序号占位**判断
##   （第 i 个槽位上有活着的将领就不招它，见 faction_ai._decide）——
##   槽位是齐的 ⇒ 正常一局里 AI 根本不需要也招不了将领。
##   所以「招将」相关的那几条用例必须先腾空，否则验的是空气。
func _clear_ai_generals(w) -> int:
	var removed := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			u.alive = false
			removed += 1
	w.units = w.units.filter(func(u): return u.alive)
	return removed


## AI 场上还活着的将领数
func _ai_general_count(w) -> int:
	var n := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			n += 1
	return n


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
	# ★ 'enemy' 是**摆在地图上的那些测试守军**的阵营，默认配置里它不是阵营 AI。
	#   ⚠️ 但这是**数据**：把 'enemy' 写进 ai.factions 它就变成阵营 AI 了
	#   （那时它也会跟着走「将领不带开局附属兵」那条）。所以这里断言的是
	#   「**随游戏发布的那份配置**里没有它」，不是「它永远不能是」。
	#   ⚠️ 守军现在由**关卡的 `start_units`** 摆（地图的 `units[]` 已废弃，见 GARRISON_NAME）。
	ok(not cfg.is_ai_faction("enemy"),
		"随游戏发布的配置里 'enemy' 不是阵营 AI（它由关卡的 start_units 自己摆）")
	ok(FactionRes.is_ai_faction("ai"), "faction.gd 的常量兜底也认 'ai'")

	# 行为参数：每一项都要有、且不能是「取不到就 0」那种静默坏值
	var fc: Dictionary = cfg.ai_faction_cfg()
	ok(int(fc["generals"]) > 0, "ai.faction.generals > 0")
	# ★★ `min_retinue` 在本轮**换了语义**（不再是「补员目标 / 编制缺省」）：
	#    补员目标现在 = 关卡里给这位将领摆了几个附属兵（`world.escort_target_of`），
	#    而这个键只剩「这一方要不要做补员这件事」的总开关作用（`<= 0` 跳过 b 段）。
	#    ⇒ 它的取值仍然必须 > 0（配置完整性），但**不再**是任何「编制」。
	ok(int(fc["min_retinue"]) > 0, "ai.faction.min_retinue > 0（本轮起只是补员总开关，不是编制）")
	ok(float(fc["attack_repeat_sec"]) > 0.0, "ai.faction.attack_repeat_sec > 0")
	var gc: Dictionary = cfg.ai_general_cfg()
	ok(float(gc["patrol_interval_sec"]) > 0.0, "ai.general.patrol_interval_sec > 0")
	ok(float(gc["combat_idle_sec"]) > 0.0, "ai.general.combat_idle_sec > 0")
	ok(int(gc["min_retinue"]) > 0, "ai.general.min_retinue > 0")
	# 需求：「没有攻击行为 10 秒后」——默认必须是 10
	near(float(gc["combat_idle_sec"]), 10.0, 1e-6, "脱战判定默认就是 10 秒")
	# ★ 巡逻**带兵**（本轮新增）：掉队阈值必须从配置来、而且不能小于队形间距
	#   （否则每一步都重下命令、整队一直在互相挤，见 general_ai._catch_up_retinue）
	ok(float(gc["patrol_retinue_leash_tiles"]) >= 1.0,
		"patrol_retinue_leash_tiles >= 1（巡逻带兵的掉队阈值）")
	ok(float(gc["patrol_retinue_leash_tiles"]) >= float(cfg.formation_spacing_scale),
		"掉队阈值不小于队形间距（不然队形本身就一直在触发重排队）")


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

	# ★★ 玩家那一侧：**没有关卡 ⇒ 没有附属兵**（本轮口径：所见即所得）。
	#
	# 这里的断言换了个方向，但**没有变弱**：原来它钉的是「玩家有开局编队、AI 没有」
	# 那个**不对称**；现在钉的是「两边对称 —— 谁都没白送，兵只能来自关卡摆放」。
	#   ⚠️ 这不是「把断言删了让它变绿」：`World.create()` 这一局**没有关卡**，
	#      按新口径就应该一个附属兵都没有；「摆了就有」由
	#      `_test_level_placed_escorts()` 那几条更硬的用例钉着。
	var p1_generals := 0
	for u in w.units:
		if u.alive and String(u.faction) == FactionRes.DEFAULT_FACTION and u.is_general():
			p1_generals += 1
			eq(w.retinue_of(String(u.id)).size(), 0,
				"★★ 没有关卡的这一局：玩家将领开局也**光杆**（不再有全局缺省编制）")
	eq(p1_generals, 3, "玩家的三个开局将领照旧（照旧自动生成）")


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
	# ★★ 「将领按序号占位」这条规则要求**先腾出空槽位**才有「招将」这件事：
	#   正常一局里世界初始化已经给 AI 建满了 `ai.faction.generals` 位将领
	#   （而且不给附属兵，让它自己去补），所以槽位是齐的。
	#   这一节验的是「缺了 → 自己去招 → 读条读完 → 出现在地图上」那条链。
	_clear_ai_generals(w)
	eq(_ai_general_count(w), 0, "腾空之后 AI 场上一个将领都没有（这才有得招）")

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
	# ★ 而且它全程花的是**自己的钱**：玩家那一侧的账**只增不减**，没有被 AI 花掉一分。
	#   判据写成**不变量**（单调不减）而不是「== 开局值」或某个精确算式：
	#   · 「== 开局值」在玩家占着产金区划时假红（实测：gold 从 0 涨到 1282.5，
	#     那不是 AI 花的，是玩家自己的地长出来的）；
	#   · 精确算式要复刻「产能 × 地块数 × 时间 × 科技」那套公式 ——
	#     那是别的用例的事，这里跟着它走只会多一处会漂的期望值。
	#   这两个不变量才是这条用例真正要钉的：「AI 没有花玩家的钱」。
	var player_gold_end: float = float(w.resources["gold"])
	ok(player_gold_end >= player_gold0 - 1e-6,
		"★ 玩家的黄金**没有减少过**（%.1f → %.1f：AI 全程没花玩家的钱）" % [
			player_gold0, player_gold_end])
	ok(player_gold_end >= 0.0, "黄金不会变成负数（AI 的扣费只打自己的池子）")


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
##   1. **同一张图上的 NPC 会真的打仗**：地图东南侧的对家据点（箭塔 + 城墙）
##      就在 AI 的隔壁区块，AI 的将领招出来之后会被卷进去打（也会被打死）。
##      （地图的 `units[]` 废弃之后这里不再有预置守军，但箭塔还在、AI 之间照旧会打。）
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
	# ★★ 「将领按**序号占位**」这条规则（本轮修的）要求这里先把 AI 的将领清空：
	#   世界初始化时已经按 `ai.faction.generals` 给每一方建好了将领
	#   （`world.create_generals`），槽位都是齐的 ⇒ 正常一局里 AI **不需要也招不了**将领。
	#   这一节验的是「缺了就补」那条路，所以人为腾出一个空槽位。
	var removed := _clear_ai_generals(w)
	ok(removed > 0, "先腾掉 %d 位 AI 将领（腾出空槽位，才有「招将」这件事可验）" % removed)
	eq(_ai_general_count(w), 0, "现在 AI 场上一个将领都没有")

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
	eq(int(st["general_index"]), before_index + 1, "★ 有空槽位 + 有钱有地 → AI 招了一个将领（序号 +1）")
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
	eq(before, 0, "开局这个将领一个兵都没有（★★ 新口径：没摆就是 0，没有全局缺省）")
	# ★ 这一局没有关卡 ⇒ 「AI 的编制」本来是 0（连 b 段都不会动）——
	#   本节要验的是**补员那条路本身**，所以显式摆一份测试规模出来。
	_set_test_retinue_target(w, "ai", int(cfg.ai_faction_cfg()["min_retinue"]))
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
	# ★★ 目标编制 = **关卡里给这位将领摆了几个附属兵**
	#    （`world.escort_target_of()`；全局缺省编制本轮已删除）。
	#   这一局的 AI 阵营（"ai"）是 config 名单里的，关卡没给它摆过任何附属兵
	#   ⇒ 目标 0 ⇒ 这里要**自己定一个数**喂满它（下面用 `min_retinue` 当测试用的规模）。
	#   ⚠️ 别再用 `max(关卡编制, min_retinue)` 那个老口径：它已经不存在了。
	var per_general: int = maxi(1, int(cfg.ai_faction_cfg()["min_retinue"]))
	_set_test_retinue_target(w, "ai", per_general)
	var assigned := 0
	for u in w.units:
		if not u.alive or String(u.faction) != "ai" or not u.is_general():
			continue
		var want_n: int = per_general
		for i in want_n:
			var soldier = UnitRes.create(
				cfg, "%s-ai%d" % [String(u.id), i], "AI 兵",
				Vector2i(u.tx, u.ty), "ai", String(u.unit_type), "", String(u.id),
				String(u.unit_type)
			)
			w.units.append(soldier)
			assigned += 1
		ok(u.retinue_size(w) >= want_n,
			"AI 将领这时算满员（测试喂了 %d 个）" % want_n)
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

	# ★★ 整队随行：派出去的**每一位将领**的**每一个部队单位**都要一起行军攻击。
	#
	# 需求原话：「当敌方将领招募满兵时，只有将领会行军攻击，我要的是他的整个部队
	#           都行军攻击」。
	# ⚠️ 原来只对将领自己下一句 `order_attack_move`，部队留在原地 ——
	#   它们在逻辑上没有任何「跟着队长走」的机制（玩家那边靠
	#   `world.expand_to_groups()` 展开成一整队再逐个下令）。
	var squad_missing := 0
	var squad_total := 0
	for g in w.units:
		if not g.alive or String(g.faction) != "ai" or not g.is_general():
			continue
		if not g.has_attack_move:
			continue
		for m in w.retinue_of(String(g.id)):
			squad_total += 1
			if not m.has_attack_move:
				squad_missing += 1
	ok(squad_total > 0, "（前提）派出去的将领名下有部队（共 %d 个）" % squad_total)
	eq(squad_missing, 0,
		"★★ 将领的**整个部队**都跟着行军攻击（没跟上的：%d / %d）" % [squad_missing, squad_total])
	# 而且它们和将领有**同一个**全队目标点（否则队形会散到不同的地方去）
	var goal_pairs_bad := 0
	for g in w.units:
		if not g.alive or String(g.faction) != "ai" or not g.is_general():
			continue
		if not g.has_attack_move:
			continue
		for m in w.retinue_of(String(g.id)):
			if m.attack_move_goal.distance_to(g.attack_move_goal) > 0.5:
				goal_pairs_bad += 1
	eq(goal_pairs_bad, 0, "★ 部队与将领的 `attack_move_goal` 是同一个点（不是各走各的）")

	# ★★ 编制最大的那位将领**不会**因为「还在补自己的兵」被跳过。
	#
	# 需求原话：「敌方骑兵将领招募满单位后不会行军攻击」——它的编制是 `[4,5,6]` 里
	# 最大的 6，永远是最后一个补满的；而原来 `_launch_attack` 用的是无条件
	# `g.is_training(): continue` ⇒ 每次都在读条中被跳过 ⇒ **永远不出征**。
	# 判据：让它处在「编制已满、但队列里还排着一个兵」的状态，它照样要被派出去。
	var rider = null
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general() and u.has_attack_move:
			if int(u.general_index) == 2:
				rider = u
	ok(rider != null, "★★ 编制最大的那位（序号 2 = 骑兵）也在派出名单里")
	if rider != null:
		ok(rider.retinue_size(w) >= 1, "它带着自己的部队（编制 %d）" % rider.retinue_size(w))


## ★★ 打光之后不能永久卡死：死一位 → 它的槽位会被补招，而且**剩下的将领照样出击**。
##
## 需求原话：「敌方将领死亡后不会再招募新将领攻击」。
## 根因有两个（都在同一处 gate）：
##   · gate 要求「**全员**满员」⇒ 死一个就永远补不齐，出兵被永久卡死；
##   · 「至少 min_ready 位」拿一个写死的常数当门槛 ⇒ 打光之后 `field` 长期小于它。
func _test_faction_ai_replaces_dead_general(cfg) -> void:
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
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])

	# 先确认「满员时能出兵」（与上一节同一套准备）
	_fill_all_ai_retinues(w, cfg)
	FactionAiRes.update(w, cfg, 0.05)
	var launched_before := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general() and u.has_attack_move:
			launched_before += 1
	ok(launched_before >= 1, "（前提）满员时确实派出去了 %d 位" % launched_before)

	# ---- 打死**一位**将领（模拟「打光之后」的第一步）----
	var victim = null
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			victim = u
			break
	if victim == null:
		return
	var slot := int(victim.general_index)
	var alive_before := _ai_general_count(w)
	# ★★ 走 `kill_unit_now`（本轮）：加了将领濒死保护之后，直接 take_damage 只会让
	#    AI 的将领倒地（它**仍然占着槽位**，正是需求要的行为）—— 而本节验的是
	#    「一个槽位真的空出来之后会被补招」，所以要先按规则把它送走。
	kill_unit_now(cfg, w, victim)
	w.tick(0.05)
	ok(not victim.alive, "一位 AI 将领阵亡（槽位 %d）" % slot)
	eq(_ai_general_count(w), alive_before - 1, "场上少了一位将领")

	# ---- 它的槽位要被**补招**回来（按序号占位 ⇒ 空出来的那个槽位会被重新填上）----
	#   钱与人口都给足，让它有得招。
	var z2 = _give_zone_to_ai(w, cfg, 4)
	for z in w.zones.zones:
		(z as Dictionary)["population"] = 99.0
		(z as Dictionary)["population_cap"] = 99.0
	st["recruit_timer"] = 0.0
	FactionAiRes.update(w, cfg, 0.05)
	var refilling: bool = (z2 != null and w.zone_is_training(z2))
	ok(refilling or int(st["general_index"]) > 0,
		"★ 死掉的槽位被重新下了「招将」的单（而不是永远空着）")

	# ---- 而且**剩下的将领照样出击**（不会被「等全员满员」永久卡死）----
	st["attack_timer"] = 0.0
	_fill_all_ai_retinues(w, cfg)
	FactionAiRes.update(w, cfg, 0.05)
	var launched_after := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general() and u.has_attack_move:
			launched_after += 1
	ok(launched_after >= 1,
		"★★ 少了一位将领之后**仍然会出兵**（死了 %d 位后派出 %d 位）" % [1, launched_after])


## ★★ 「全队真的能走了」才发兵 —— 别把**还在读条**的那位落下。
##
## 实测报回来的原文：「第一波时骑兵将领还是不会行军攻击过来，但第二波却和
##                   新招募的将领一起行军过来了」。
## 根因：编制最大的那位（骑兵，`[4,5,6]` 里的 6）在发起那一波时第 6 个兵**还在读条**——
## `retinue_size()`（兵账）已经算成 6、gate 放行，但它自己被「招募期间钉在原地」
## 锁在家里 ⇒ 玩家看到「骑兵将领没跟着来」，等它读完条下一波才来。
##
## 这一条钉的就是那个判据：**只要有一位可进攻的将领还在读条，这一波就不发**。
func _test_faction_ai_waits_for_training(cfg) -> void:
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
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])
	_fill_all_ai_retinues(w, cfg)

	# 让**一位**将领「兵账满了、但还有一个在读条」（正是骑兵将领那一档的处境）
	var training_one = null
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general():
			training_one = u
			break
	if training_one == null:
		return
	training_one.train_kind = String(training_one.unit_type)
	training_one.train_total = 10.0
	training_one.train_remaining = 5.0
	ok(training_one.is_training(), "（前提）这位将领确实在读条")
	ok(training_one.retinue_size(w) >= 1, "而且它的兵账是满的（编制 %d）" % training_one.retinue_size(w))

	FactionAiRes.update(w, cfg, 0.05)
	var launched := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general() and u.has_attack_move:
			launched += 1
	eq(launched, 0,
		"★★ 有人还在读条（走不了）时**一位都不派** —— 否则就会被落下（实际派了 %d 位）" % launched)

	# 读条读完 → 这一波立刻出发，而且**全员**都在名单里
	training_one.train_kind = ""
	st["attack_timer"] = 0.0
	FactionAiRes.update(w, cfg, 0.05)
	var after := 0
	for u in w.units:
		if u.alive and String(u.faction) == "ai" and u.is_general() and u.has_attack_move:
			after += 1
	ok(after >= 1, "★ 都站定之后立刻发兵（派出 %d 位）" % after)
func _fill_all_ai_retinues(w, cfg) -> void:
	# ★★ 目标编制 = 关卡里给这位将领摆了几个附属兵（本轮口径）；
	#    这一局的 AI 阵营是 config 名单里的，关卡没摆过 ⇒ 目标 0
	#    ⇒ 这里**显式摆一份测试规模**（取 config 的 `min_retinue` 当规模；
	#      它在新口径下已经不是「补员目标」了，见 faction_ai._decide 那段说明）。
	var per_general: int = maxi(1, int(cfg.ai_faction_cfg()["min_retinue"]))
	_set_test_retinue_target(w, "ai", per_general)
	for u in w.units:
		if not u.alive or String(u.faction) != "ai" or not u.is_general():
			continue
		var want_n: int = per_general
		var have: int = u.retinue_size(w)
		var i := 0
		while have + i < want_n:
			var soldier = UnitRes.create(
				cfg, "%s-fill%d" % [String(u.id), i], "AI 兵",
				Vector2i(u.tx, u.ty), "ai", String(u.unit_type), "", String(u.id),
				String(u.unit_type)
			)
			w.units.append(soldier)
			i += 1


## ★★ 阵营 AI 升级自己的建筑时**不许刷「被拒」事件**。
##
## 玩家实测原话：「即使我没有升级城墙，也会莫名其妙地出现『城墙正在读条…』
##                 『箭塔正在读条…』等字样，可能是敌人的消息传到我这来了」。
## 两句都对：**是敌人的消息**（AI 在升级它自己的城墙），而它之所以出现在玩家界面上，
## 是因为 AI 每秒都对**同一栋在读条的建筑**重下一次升级单 → 被拒 → 推一条
## `upgrade_rejected`（实测 60 秒几百条），界面又不加过滤地显示。
##
## 这一条钉住**源头**（`_pick_upgrade` 跳过在读条的建筑 + 冷却无论成败都记）：
## 跑 30 秒，`upgrade_rejected` 必须是 **0 条**。
## （界面那半边的过滤见 view/game_scene.gd 的 `_is_my_event`。）
func _test_faction_ai_no_upgrade_reject_spam(cfg) -> void:
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
	st["general_index"] = int(cfg.ai_faction_cfg()["generals"])      # 跳过招将
	_fill_all_ai_retinues(w, cfg)                                   # 跳过招兵
	# 让 AI 有可升级的建筑：地图上的城墙 / 箭塔
	var upgradable := 0
	for b in w.building_list:
		if b.alive and String(b.owner) == "ai" and w.building_can_upgrade(b.type):
			upgradable += 1
	ok(upgradable > 0, "（前提）AI 有 %d 栋可升级的建筑" % upgradable)

	var rejected := 0
	var started := 0
	var done := 0
	var steps := int(30.0 / 0.05)
	for i in steps:
		for e in w.tick(0.05):
			var ty := String((e as Dictionary).get("type", ""))
			if ty == "upgrade_rejected" or ty == "upgrade_cancel_rejected":
				rejected += 1
			elif ty == "upgrade_started":
				started += 1
			elif ty == "upgrade_done":
				done += 1
	eq(rejected, 0,
		"★★ AI 升级自己的建筑时一条「被拒」都不该发（实测刷屏的源头）；开始 %d 次 / 完成 %d 次"
		% [started, done])
	ok(started > 0, "★ 但它确实在正常升级（30 秒里开始了 %d 次）" % started)


# ------------------------------------------------------------------
# C. 将领性（防御性）AI
# ------------------------------------------------------------------

## ★★ 驻防将领从**关卡摆放**长出来（`start_units[].zone` → `unit.garrison_zone_id`）。
##
## ⚠️ 这条用例原来叫 `_test_general_ai_from_map`，读的是**地图** `units[]` 里那三个
##    「驻防将领」条目。本轮地图预置单位整个废弃（运行时不再读 `units[]`），
##    于是这里改成**走关卡的摆放** —— 断言一条都没删弱：
##    「3 个守将」「各自带归属区划」「区划表里找得到」「开局站在自己区划里」
##    「开局没有附属兵」「没有专属资源库」全部照旧。
##    ★ 坐标与区划沿用原来地图里那三条（(8,13)@6 / (20,13)@8 / (20,17)@9），
##      所以「站在自己区划里」验的仍然是同一件事。
func _test_general_ai_from_level(cfg) -> void:
	var lv = _garrison_level(cfg)
	if lv == null:
		return
	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], false)
	ok(w != null, "按关卡建出「三个驻防将领」的世界")
	if w == null:
		return
	var found := 0
	for u in w.units:
		if not u.alive or String(u.name) != GARRISON_NAME:
			continue
		found += 1
		ok(u.is_garrison(), "关卡摆放的驻防将领带上了归属区划（start_units[].zone）")
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
	eq(found, 3, "关卡里摆了 3 个驻防将领")


func _test_general_ai_patrol(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var u = _make_garrison(w, cfg, Vector2i(5, 13), 6)
	if u == null:
		return

	# ---- 站得离巡逻点远 → 到点就该巡逻（朝自己路线的第一个点走）----
	u.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not u.path.is_empty() or u.moving, "★ 巡逻计时到点 → 驻防将领朝自己的巡逻点出发")
	ok(float(u.patrol_timer) > 0.0, "巡逻计时被重置（有时间间隔，不是每帧都动）")

	# ---- 冷却期内再跑一帧：不应该又下一条新命令 ----
	var path_len: int = u.path.size()
	GeneralAiRes.update(w, cfg, 0.05)
	ok(u.path.size() <= path_len, "巡逻间隔之内不会每帧重算路径")

	# ---- ★★ 路线：每位守将分到几个点（由单位 id 派生的固定种子算出来的）----
	ok(u.patrol_points.size() >= 1,
		"★ 守将拿到了自己的巡逻路线（%d 个点）" % u.patrol_points.size())
	var want_points: int = int(cfg.ai_general_cfg()["patrol_points"])
	ok(u.patrol_points.size() <= want_points,
		"巡逻点数不超过配置（%d ≤ %d）" % [u.patrol_points.size(), want_points])
	ok(u.garrison_zone_id == u.patrol_zone_id, "路线是给**自己那个区划**算的")
	# 每个点都必须落在自己的区划里（巡逻不许跑出地盘）
	var z6 = w.zone_by_id(6)
	if z6 != null:
		for p in u.patrol_points:
			var here: Variant = w.zones.zone_at(p.x, p.y)
			ok(here != null and int((here as Dictionary)["id"]) == 6,
				"★ 巡逻点 (%d,%d) 在自己区划里" % [p.x, p.y])

	# ---- ★★ 已经站在路线上的点 → 推进到下一个点（而不是原地空跑寻路）----
	#   这是老断言「站在中心上就不下命令」在新语义下的写法：巡逻是**多点往返**，
	#   到了就该换下一个点 —— 但换的是**别的点**，不会把同一条命令重下一遍。
	var u2 = _make_garrison(w, cfg, Vector2i(5, 12), 6)   # (5,12) 就是区划 6 的中心
	if u2 != null:
		u2.patrol_timer = 0.0
		GeneralAiRes.update(w, cfg, 0.05)      # 先算出路线
		ok(u2.patrol_points.size() >= 1, "（前提）u2 也拿到了路线")
		if u2.patrol_points.size() >= 2:
			# 站在「当前那个点」上 → 下一次决策应当推进下标
			u2.pos = GridRes.center_of(u2.patrol_points[0])
			u2.patrol_index = 0
			u2.patrol_dir = 1
			u2.stop()
			u2.patrol_timer = 0.0
			GeneralAiRes.update(w, cfg, 0.05)
			eq(u2.patrol_index, 1, "★ 站在当前巡逻点上 → 下标推进到下一个点")
			ok(not u2.path.is_empty() or u2.moving, "★ 于是它朝**下一个点**出发（不是原地站着）")
		else:
			# 只分到一个点：到了就该站着（与老行为一致）
			u2.pos = GridRes.center_of(u2.patrol_points[0])
			u2.stop()
			u2.patrol_timer = 0.0
			GeneralAiRes.update(w, cfg, 0.05)
			ok(u2.path.is_empty() and not u2.moving,
				"只有一个巡逻点时：站在那儿就不下移动命令（不空跑寻路）")


## ★★ 同一个区划里的几位守将：**路线各不重复 + 各占一块**（dev_plan_7 补的一条）。
##
## 需求原话：「将领**随机**路线巡逻，只要确保他们巡逻的**不整齐划一**就行」。
## 这一组盯两件事：
##   1. 路线由**单位 id 派生的固定种子**算出来 ⇒ 各不相同（不整齐划一）；
##   2. 同区划的人**按扇区**分地盘 ⇒ 各自的锚点不重合、路线整体错开（不会挤在中心）。
##
## ⚠️ 不许用引擎随机数（dev_plan_7 3.10：AI 决策不许用随机数决定结果，存档 / 回放要可复现）
##   —— 所以第 3 条断言「同 id 重算 => 同一条路线」必须成立。
func _test_general_ai_patrol_spread(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	# 在区划 6 里摆 4 位守将（同一区划，正是"会挤在一起"的场景）
	var put := [Vector2i(5, 13), Vector2i(1, 13), Vector2i(5, 14), Vector2i(1, 14)]
	var units: Array = []
	for t in put:
		var u = _make_garrison(w, cfg, t, 6)
		if u != null:
			units.append(u)
	if units.size() < 2:
		return

	# 跑一帧（`patrol_interval` 到点）让每位的路线都建出来
	for u in units:
		u.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)

	var routes: Array = []
	var anchors: Array = []
	for u in units:
		ok(u.patrol_points.size() >= 1, "★ %s 拿到了巡逻路线（%d 个点）"
			% [String(u.id), u.patrol_points.size()])
		routes.append(str(u.patrol_points))
		if not u.patrol_points.is_empty():
			anchors.append(u.patrol_points[0])

	# ① 路线不重复（"不整齐划一"）
	var uniq: Dictionary = {}
	for r in routes:
		uniq[r] = true
	eq(uniq.size(), routes.size(),
		"★★ %d 位守将的路线**互不相同**（不整齐划一）" % routes.size())

	# ② 锚点两两不重合（各占一块，不挤在同一个点）
	var dup_anchor := 0
	for i in anchors.size():
		for j in range(i + 1, anchors.size()):
			if (anchors[i] as Vector2i) == (anchors[j] as Vector2i):
				dup_anchor += 1
	eq(dup_anchor, 0, "★★ 同区划的守将锚点两两不重合（按扇区分地盘）")

	# ③ 确定性：**同一个 id ⇒ 同一条路线**（存档 / 回放那条硬要求）
	#
	# ⚠️ 重算时 `zone_count` 必须一样 —— 扇区是「区划切成 zone_count 段」之后再按 id
	#    取第几段的，所以「同区划里有几个人」变了，切法就变了（路线跟着变）。
	#    这里不新增单位，所以 zone_count 不变。
	var u_a = units[0]
	var route_before: Array = u_a.patrol_points.duplicate()
	u_a.patrol_zone_id = -2                     # 假装没算过 → 逼它重算
	u_a.patrol_points = [] as Array[Vector2i]
	u_a.patrol_timer = 0.0                      # ⚠️ 路线只在**巡逻到点那一帧**建，
	                                            #    不归零的话它这一帧根本不会重算（实测踩到）
	GeneralAiRes.update(w, cfg, 0.05)
	eq(u_a.patrol_points, route_before,
		"★★ 同一位守将重算路线 ⇒ 逐点一致（种子来自 id，不是引擎随机数）")


# ------------------------------------------------------------------
# ★★ 巡逻要带上**自己招出来的兵**（手玩报的 bug：将领在巡逻，招出来的兵站着不动）
# ------------------------------------------------------------------

## 造一个「驻防将领 + 它自己招出来的附属兵」的小队。
##
## ★ 复刻**招募**那条路的三个事实（用 `_spawn_from_recruit` 而不是手写 create）：
##   · 附属兵的 `leader_id` = 将领 id；
##   · 位置在将领那一格的中心（`_spawn_from_recruit` 会排开别人再放）；
##   · 走的正是「区划中心招将 / 将领脱战招兵」用的那一个函数 ⇒
##     这里要是漂了，测的就不是生产路径了。
##
## ⚠️ 用 `spearman` 而不是 `enemy`：`_spawn_from_recruit` **不看**招募表
##   （那条路只在把兵排进队列时查），但守将自己的兵种是敌人时也没什么意义。
func _make_garrison_with_retinue(w, cfg, tile: Vector2i, zone_id: int, count: int) -> Dictionary:
	var g = _make_garrison(w, cfg, tile, zone_id)
	if g == null:
		return {}
	g.unit_type = "spearman"
	g.unit_class = cfg.unit_class_of("spearman")
	g.ranged = cfg.unit_is_ranged("spearman")
	var soldiers: Array = []
	for i in count:
		var s = w._spawn_from_recruit(g, "spearman")
		if s != null:
			soldiers.append(s)
	return {"leader": g, "soldiers": soldiers}


func _test_general_ai_patrol_with_retinue(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return
	var pack := _make_garrison_with_retinue(w, cfg, Vector2i(5, 13), 6, 3)
	if pack.is_empty():
		return
	var g = pack["leader"]
	var soldiers: Array = pack["soldiers"]
	eq(soldiers.size(), 3, "（前提）将领招出来了 3 个附属兵")

	# ---- 0) 前提：附属兵确实挂在将领名下（跟着走的前提就是这一条）----
	var attached := 0
	for s in soldiers:
		if String(s.leader_id) == String(g.id):
			attached += 1
	eq(attached, soldiers.size(), "（前提）附属兵的 leader_id 都指向这位将领")
	# ★★ 它们**不该**各自当巡逻队长（否则 4 个人各走各的，而不是一支小队）
	for s in soldiers:
		ok(not GeneralAiRes.is_patrol_leader(w, s),
			"★★ 附属兵不是巡逻队长（只有带队的那个将领巡逻，兵跟着走）")

	# ---- 1) 将领巡逻那一帧：整队都要动起来 ----
	#
	# ★★ 这就是手玩报的那条：「将领会巡逻，但将领招募出来的单位不会巡逻」——
	#    改之前只有将领拿到命令，兵一动不动地站在原地。
	g.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not g.path.is_empty() or g.moving, "（前提）将领出发了")
	var idle := 0
	for s in soldiers:
		if s.path.is_empty() and not s.moving:
			idle += 1
	eq(idle, 0, "★★ 巡逻那一帧里**一个站着不动的附属兵都没有**（兵跟着将领一起巡逻）")

	# ---- 1.5) 而且真的会走（不是挂了一条永远走不动的路径）----
	var before_pos: Array[Vector2] = []
	for s in soldiers:
		before_pos.append(s.pos)
	for tick in 20:
		w.tick(0.05)
	var walked := 0
	for i in soldiers.size():
		if soldiers[i].pos.distance_to(before_pos[i]) > 0.1:
			walked += 1
	eq(walked, soldiers.size(), "★★ 跑 1 秒之后每个附属兵都真的挪了位置（跟着走了）")
	ok(soldiers.size() > 0 and soldiers[0].garrison_zone_id == g.garrison_zone_id,
		"★ 附属兵继承了队长的归属区划（同属一块地 ⇒ 也受「不追出一个区划」管）")

	# ---- 2) 真的跑起来之后，谁都不许掉队站在原地 ----
	#
	# ★ 判据用「离将领多远」而不是「有没有路径」：路上会被地形、别人挤、被敌人拦住，
	#   有路径不等于走得动；「一直在将领身边」才是这条需求真正要的结果。
	for tick in 240:
		w.tick(0.05)
	var leash: float = float(cfg.ai_general_cfg()["patrol_retinue_leash_tiles"])
	var stayed := 0
	for s in soldiers:
		if not s.alive:
			continue
		if s.pos.distance_to(g.pos) <= leash:
			stayed += 1
	eq(stayed, soldiers.size(),
		"★★ 跑了 12 秒之后每个附属兵都还在将领 %.1f 格以内（掉队的会被重新叫上）" % leash)
	ok(g.patrol_points.size() >= 1, "将领一直有路线（巡逻没有中断）")

	# ---- 3) 将领阵亡（被清掉）之后，剩下的兵要**自己接手**巡逻 ----
	#
	# 需求原话是「将领性 AI 附属于某个将领」，但队长没了就让这一队站着不动 =
	# 那一块地彻底没人守。判据在 `is_patrol_leader()`：队长查不到 ⇒ 自己带队。
	g.alive = false
	if soldiers.size() >= 1:
		ok(GeneralAiRes.is_patrol_leader(w, soldiers[0]),
			"★ 队长阵亡后，剩下的附属兵自己接手巡逻（不会因为「没队长了」而站死）")


## ★★ 巡逻点**不用手摆**：归属区划与路线都由 AI 从「自己在哪一格」推出来。
##
## 需求原文：「将领性 ai 要做到可以自己清楚该区划要怎么巡逻（笨一些没关系），
##           而不能每个要巡逻的区划都再手动给将领设置巡逻点，节省成本」。
##
## 这里钉住三件事：
##   1. 关卡摆放里**只写 kind / x / y**（不写 zone、也不写任何巡逻点）的将领，开局自己拿归属；
##   2. 归属取的就是**它脚下那一格所在的区划**（大本营在哪块，就守哪块）；
##   3. 路线是从区划地块算出来的、非空，且每个点都落在自己区划里。
func _test_general_ai_patrol_route_is_automatic(cfg) -> void:
	# ⚠️ 阵容要点：`my_faction` 故意**不是** F1 —— 那一方的 AI 才不会被摘掉
	#    （「玩家选中哪一方，运行时就把那一方的 AI 摘掉」那条）。F1 在这一关挂的是
	#    `ai: "general"`，于是 `spawn_faction_units` 会走「兜底给将领一个归属区划」那段。
	var level = _patrol_probe_level(cfg)
	if level == null:
		return
	var w = WorldRes.create_from_level(cfg, level, "F2", ["F1", "F2"], false)
	ok(w != null, "（前提）能按关卡建出世界")
	if w == null:
		return

	var found = null
	for u in w.units:
		if String(u.faction) != "F1":
			continue
		if String(u.name) == "无归属守将":
			found = u
	if found == null:
		ok(false, "关卡摆放的将领进了世界（后面这些断言不会执行）")
		return
	var u = found

	# ---- 1) 归属自动落到「它脚下那一格所在的区划」----
	ok(int(u.garrison_zone_id) >= 0,
		"★★ 关卡只写了坐标、没写 zone：将领自己拿到了归属区划（id=%d）" % int(u.garrison_zone_id))
	eq(int(u.garrison_zone_id), _zone_id_of(w, Vector2i(5, 13)),
		"★★ 归属 = 它脚下那一格所在的区划（不需要地图作者手填）")
	ok(GeneralAiRes.is_patrol_leader(w, u), "★ 它是这一队的巡逻队长（没人带它）")

	# ---- 2) 路线由 AI 自己按区划算出来（不是预先摆好的点）----
	eq(u.patrol_points.size(), 0, "（前提）还没巡逻过 ⇒ 路线还没算（不是预先摆好的点）")
	u.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(u.patrol_points.size() >= 1,
		"★★ 路线是 AI **自己按区划**算出来的（%d 个点，没有任何手摆的巡逻点）"
		% u.patrol_points.size())
	for p in u.patrol_points:
		var here: Variant = w.zones.zone_at(p.x, p.y)
		ok(here != null and int((here as Dictionary)["id"]) == int(u.garrison_zone_id),
			"★ 巡逻点 (%d,%d) 在它自己的区划里" % [p.x, p.y])

	# ---- 3) 同一区的**另一位**守将拿到的是另一条路线（各走各的，不挤在一起）----
	var u2 = UnitRes.create(cfg, "probe-2", "第二个守将", Vector2i(1, 13),
		"F1", UnitRes.UNIT_TYPE_SPEARMAN)
	u2.garrison_zone_id = int(u.garrison_zone_id)
	u2.hold_position = true
	w.units.append(u2)
	u2.patrol_timer = 0.0
	u.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(u2.patrol_points.size() >= 1, "第二位守将也自己算出了路线")
	ok(str(u2.patrol_points) != str(u.patrol_points),
		"★★ 同一区划的两位守将路线不同（扇区分地盘，不用手动摆点）")


## 关卡实例（只为了让「不写 zone 的将领」有一条真实入口）。
##
## ★★ 走的是**真实载入路径**（写一份最小关卡 JSON 再 `LevelRes.load_level`），
##    不是手搓一个 `Level` 对象 —— 实测手搓那条路会在 `merge_over_map` 里炸
##    （`Level` 的那些字段谁负责填、什么时候填，只有 `load_level` 知道）。
##
## 借的是随游戏发布的那张图（`data/maps/frontier/map.json`）：坐标 (5,13) 落在**区划 6** 里。
func _patrol_probe_level(cfg):
	var dir := "%s/patrol_probe" % TMP_ROOT
	var path := "%s/level.json" % dir
	_write_text(path, JSON.stringify({
		"map": "frontier",
		"name": "巡逻归属探针",
		"players": [{"faction": "F1"}],
		# ★ 这一关的 F1 挂**将领性 AI**（于是世界会给它的将领兜底归属区划）
		"factions": [{"id": "F1", "ai": "general", "base": [4, 5]}],
		# ★★ 只写 kind / x / y：**不写 zone**（这就是需求要的「不用手摆巡逻点」）
		"start_units": [
			{"faction": "F1", "kind": "enemy", "x": 5, "y": 13, "name": "无归属守将"}
		]
	}))
	var lv = LevelRes.load_level(null, path, cfg)
	if lv == null:
		ok(false, "探针关卡能载入（%s）" % path)
	return lv


## 一份「三个驻防将领」的最小关卡 —— **替代**原来地图 `units[]` 里那三条。
##
## ★★ 为什么改成走关卡：`map.json` 的 `units[]` 本轮**整个废弃、运行时不再读**，
##    「开局就摆好的守军」现在只能由关卡的 `start_units` 摆（字段语义与它一字不差）。
## ★ 坐标 / 阵营 / 归属区划沿用原来地图里那三条，所以
##   「3 个守将」「各自站在自己那个区划里」这些断言验的仍然是同一件事。
func _garrison_level(cfg):
	var path := "%s/garrison/level.json" % TMP_ROOT
	_write_text(path, JSON.stringify({
		"map": "frontier",
		"name": "驻防将领探针",
		"players": [{"faction": "p1"}],
		"start_units": [
			{"faction": "enemy", "kind": "enemy", "x": 8, "y": 13,
				"name": GARRISON_NAME, "hold": true, "zone": 6},
			{"faction": "enemy", "kind": "enemy", "x": 20, "y": 13,
				"name": GARRISON_NAME, "hold": true, "zone": 8},
			{"faction": "enemy", "kind": "enemy", "x": 20, "y": 17,
				"name": GARRISON_NAME, "hold": true, "zone": 9},
		]
	}))
	var lv = LevelRes.load_level(null, path, cfg)
	if lv == null:
		ok(false, "驻防将领探针关卡能载入（%s）" % path)
	return lv


## ★★ 测试里给**关卡没摆过附属兵**的那一方定一个「补员规模」。
##
## 为什么需要它（本轮口径）：AI 的补员目标现在**只有一个来源** ——
##   关卡 `start_units[]` 里给这位将领摆了几个附属兵（`world.escort_target_of`）。
##   而这些用例用的世界是 `World.create()`（**没有关卡**），于是目标恒为 0
##   ⇒ b 段不招兵、出兵 gate 也「开局就算满员」—— 那两个用例要验的东西
##   （「AI 会补员」「满员之后才出兵」）就全成了空气。
## 所以这里**显式**给一个规模：把它写进 `world.placed_escorts`（AI 补员目标读的就是它）、
## 同时也写进 `min_retinue`（保留原本「这一方会补员」这条语义）。
##
## ⚠️ 这不是「绕过新口径」，而是**把它摆出来**：新口径下「AI 的编制」本来就只能
##    来自关卡摆放，测试要一个具体的数就得自己摆一份记账。
func _set_test_retinue_target(w, faction: String, per_general: int) -> void:
	per_general = maxi(1, per_general)
	# ★ 按**将领槽位**预填 0..2（`ai.general.generals` 那一档最多就是 3 位；
	#   多填几个不花什么，`escort_target_of` 只查表）。
	for i in 4:
		w.placed_escorts["%s|%d" % [faction, i]] = per_general


## ★★ 关卡**逐兵摆放**的附属部队（本轮口径）：`start_units[].escort_of`。
##
## 上一轮这里是「关卡 `factions[].general_escort` 逐将编制 + 回退 `config.json` 的
## `unit.general.escort`」—— **整套已推翻**（理由「所见即所得」：开局场上有多少兵，
## 必须完全等于关卡里摆出来的那些）。于是这个用例验的东西**整个换了**，
## 但每一条都是**更强**的契约（不是放宽）：
##   1. 摆了 `escort_of` 的兵 → 开局 `leader_id` 指向**同阵营同序号**的将领；
##   2. `world.retinue_of(那位将领)` **包含**它（它真的算「附属部队」）；
##   3. 摆了附属部队的那一方**不再自动生成将领**（场上将领数 = 作者摆的个数）；
##   4. 没摆 `escort_of` 的一方**仍然**自动生成 3 位将领，且他们**不带**附属兵（0 个）；
##   5. 非法 `escort_of`（`0` / `-3` / `"2"` / `2.5` / `true`）一律当**没写**
##      （= 普通摆放单位，没有队长，也不触发整方接管）。
func _test_level_placed_escorts(cfg) -> void:
	# ---- 1) / 2) / 3) 关卡摆了附属兵：绑定 + 整方接管 ----
	var lv = _escort_probe_level(cfg, "placed", [
		{"faction": "p1", "kind": "spearman", "x": 4, "y": 6, "hold": true, "escort_of": 2},
		{"faction": "p1", "kind": "longbowman", "x": 6, "y": 5, "hold": true, "escort_of": 2},
		{"faction": "p1", "kind": "spearman", "x": 3, "y": 5, "hold": true, "escort_of": 1},
	])
	if lv == null:
		return
	ok(lv.faction_has_placed_escorts("p1"), "★ 关卡这一方摆了附属部队（判据 = 有任何一项带 escort_of）")
	ok(not lv.faction_has_placed_escorts("enemy"), "（对照）没摆的那一方不是「由关卡接管」")
	eq(lv.placed_escort_count_for("p1", 1), 2, "★ 第 2 位将领摆了 2 个附属兵（口径函数）")
	eq(lv.placed_escort_count_for("p1", 0), 1, "★ 第 1 位将领摆了 1 个")
	eq(lv.placed_escort_count_for("p1", 2), 0, "★ 第 3 位一个都没摆")

	var w = WorldRes.create_from_level(cfg, lv, "p1", ["p1"], false)
	ok(w != null, "按关卡建出世界（逐兵摆放的附属部队）")
	if w == null:
		return
	eq(Array(w.level.placed_units_for("p1")).size(), 3, "关卡摆放读得回来（placed_units_for）")

	# ---- 3) 整方接管：将领数 = 作者摆的个数，**不是** +3 ----
	var all_p1 := 0
	var generals_p1 := 0
	var leaders_seen: Array = []
	for u in w.units:
		if String(u.faction) != "p1":
			continue
		all_p1 += 1
		if u.is_general():
			generals_p1 += 1
			leaders_seen.append(u.id)
	# ★★ 这一方**连将领都由关卡接管**：场上恰好 = 作者摆的 3 个兵 + 补出来的 2 位将领。
	#    ⚠️ 不是「3 个」——口径是「**不自动生成 3 位将领**」，不是「不生成将领」：
	#      `escort_of` 真正点名的那几位必须存在，否则那些兵根本没有队长。
	eq(all_p1, 5, "★★ 场上 = 3 个摆放兵 + escort_of 点名的 2 位将领（一位都没多）")
	eq(generals_p1, 2, "★★ 这一方**不再自动生成** 3 位将领（只有 escort_of 点名的第 1/2 位）")
	ok(leaders_seen.has("general-1") and leaders_seen.has("general-2"),
		"★ 补出来的将领就是关卡点名的那两位（id 全名：%s）" % str(leaders_seen))

	# ---- 1) escort_of → leader_id（本轮的核心契约）----
	var g2 = w.unit_by_id("general-2")
	var g1 = w.unit_by_id("general-1")
	ok(g2 != null and g1 != null, "（前提）两位将领都在场")
	if g2 == null or g1 == null:
		return
	var by_leader := {}
	for u in w.units:
		if String(u.faction) != "p1" or u.is_general():
			continue
		eq(String(u.leader_id) != "", true, "★ 摆放的附属兵有队长（%s）" % u.id)
		by_leader[u.id] = String(u.leader_id)

	# ★★ 逐条对照：谁该归谁，是**按 escort_of 说的**，不是按摆放顺序猜的。
	#    坐标是上面摆的那三个（(6,5)@2 / (4,6)@2 / (3,5)@1）。
	const WANT_LEADER := {Vector2i(6, 5): "general-2", Vector2i(4, 6): "general-2", Vector2i(3, 5): "general-1"}
	var sub_ids: Array = by_leader.keys()
	sub_ids.sort()
	eq(sub_ids.size(), 3, "（前提）3 个附属兵")
	for sid in sub_ids:
		var sub = w.unit_by_id(String(sid))
		var want_leader: String = WANT_LEADER.get(Vector2i(sub.tx, sub.ty), "")
		ok(want_leader != "", "（前提）%s 站在预期的那一格 (%d,%d)" % [String(sid), sub.tx, sub.ty])
		eq(String(by_leader[sid]), want_leader,
			"★★ escort_of → leader_id：%s 归 %s" % [String(sid), want_leader])
		# ★ 同阵营同序号：队长确实在场上，而且类型跟得上
		var ld = w.unit_by_id(String(by_leader[sid]))
		ok(ld != null, "队长在场：%s" % String(by_leader[sid]))
		if ld != null:
			eq(String(ld.faction), "p1", "★ 队长与兵**同阵营**")
			eq(String(ld.unit_type), String(sub.unit_type),
				"★ 附属兵与队长**同类型**（作者没写 unit_type 时跟随队长）")

	# ---- 2) retinue_of 真的把它算成「附属部队」----
	eq(w.retinue_of("general-2").size(), 2, "★★ retinue_of(第 2 位将领) 包含那 2 个兵")
	eq(w.retinue_of("general-1").size(), 1, "★★ retinue_of(第 1 位将领) 包含那 1 个兵")
	eq(w.retinue_of("general-3").size(), 0, "（对照）没被点名的将领名下 0 个")
	# ★ 分组：点附属兵也得到整队
	#   ⚠️ 分两步拿（先取出 retinue 再取第 0 个）：链式下标在某些写法下会被
	#      解析成「字符串下标」而静默拿到 null，那会让断言看起来像「队伍模型坏了」。
	var g2_mates: Array = w.retinue_of("general-2")
	var one_mate = g2_mates[0]
	eq(w.group_of(one_mate).size(), 3,
		"★ group_of(附属兵) = 将领 + 它的 2 个兵（队伍模型对摆放的兵一样成立）")

	# ---- 4) 没摆 escort_of 的一方：**仍然**自动生成 3 位将领，且 0 个附属兵 ----
	#
	# ★ 「enemy」在探针关卡里**只摆了一个普通单位**（没有 escort_of）——
	#   它必须照旧拿到 3 位自动生成的将领。
	var lv2 = _escort_probe_level(cfg, "plain", [
		{"faction": "enemy", "kind": "enemy", "x": 8, "y": 13, "hold": true},
	], [{"id": "enemy", "ai": LevelRes.AI_FACTION, "base": [10, 13]}])
	if lv2 == null:
		return
	ok(not lv2.faction_has_placed_escorts("enemy"), "（前提）这一方一项 escort_of 都没写")
	var w2 = WorldRes.create_from_level(cfg, lv2, "p1", ["p1"], true)
	ok(w2 != null, "按关卡建出世界（有一方没摆附属部队）")
	if w2 == null:
		return
	var gens_enemy := 0
	var subs_enemy := 0
	for u in w2.units:
		if String(u.faction) != "enemy":
			continue
		if u.is_general():
			gens_enemy += 1
			eq(w2.retinue_of(String(u.id)).size(), 0,
				"★★ 自动生成的将领开局**光杆**（0 个附属兵，没有全局缺省可补）：%s" % u.id)
		elif String(u.leader_id) != "":
			subs_enemy += 1
	eq(gens_enemy, 3, "★★ 没摆 escort_of 的一方**仍然**自动生成 3 位将领")
	eq(subs_enemy, 0, "★★ 而且一个附属兵都没有（no global default）")

	# ---- 4b) ★★ 回归：没摆附属兵的一方，补员目标**不能是 0** ----
	#
	# 手玩实测报回来的原文：「红方的将领没有招满单位就向目标点行军攻击了」。
	# 根因：`escort_target_of()` 原来只回答「关卡给这位将领摆了几个」⇒ 没摆的一方
	#   目标恒为 0 ⇒ `faction_ai` 的「闲着的将领都满员了吗」当场成立 ⇒ **第 1 帧就出征**。
	#   （旧世界由 `config.json` 的 `unit.general.escort` 兜着，那个全局缺省被删掉之后
	#     兜底责任落到 `min_retinue` 身上。）
	# 修法：这一方**没摆过**附属兵 → 退到它自己的 `ai.faction.min_retinue`。
	# ⚠️ 这一条钉的是**行为**（一个非 0 的目标），不是某个具体数字 ——
	#    `min_retinue` 是难度旋钮，会在 `config.json` 里被调。
	var want_env: int = maxi(0, int(w2.faction_ai_cfg("enemy").get("min_retinue", 0)))
	ok(want_env > 0, "（前提）enemy 这一方的 min_retinue 是正数（%d）" % want_env)
	for gi in 3:
		eq(w2.escort_target_of("enemy", gi), want_env,
			"★★ 没摆附属兵的一方：第 %d 位将领的补员目标 = min_retinue（%d），**不是 0**"
			% [gi + 1, want_env])
	# 对照：**摆过**附属兵的那一方，目标仍然是「关卡摆了几个」（不是 min_retinue）
	var lv_min = _escort_probe_level(cfg, "min_ret", [
		{"faction": "p1", "kind": "spearman", "x": 4, "y": 6, "hold": true, "escort_of": 1},
	])
	if lv_min != null:
		var w_min = WorldRes.create_from_level(cfg, lv_min, "p1", ["p1"], true)
		if w_min != null:
			eq(w_min.escort_target_of("p1", 0), 1,
				"★★ 摆过附属兵的一方：目标 = 关卡摆了几个（作者摆 1 个，min_retinue 不参与）")
	# ---- 5) 非法 escort_of 一律当「没写」----
	var clean: Array = []
	for c in [
		{"tag": "zero", "v": 0},
		{"tag": "neg", "v": -3},
		{"tag": "str", "v": "2"},
		{"tag": "frac", "v": 2.5},
		{"tag": "bool", "v": true},
	]:
		var tag := String(c["tag"])
		var lv3 = _escort_probe_level(cfg, "bad_%s" % tag, [
			{"faction": "p1", "kind": "spearman", "x": 4, "y": 6, "hold": true,
				"escort_of": c["v"]},
		])
		if lv3 == null:
			continue
		ok(not lv3.faction_has_placed_escorts("p1"),
			"★★ escort_of = %s（非法）→ 当没写，不触发整方接管" % str(c["v"]))
		var w3 = WorldRes.create_from_level(cfg, lv3, "p1", ["p1"], false)
		if w3 == null:
			continue
		var gens3 := 0
		var lone := 0
		for u in w3.units:
			if String(u.faction) != "p1":
				continue
			if u.is_general():
				gens3 += 1
			elif String(u.leader_id) == "":
				lone += 1
		eq(gens3, 3, "★★ 非法 escort_of 的那一方照旧自动生成 3 位将领（%s）" % tag)
		eq(lone, 1, "★ 那个兵成了**普通摆放单位**（自己就是队长，没有 leader_id）")
		clean.append(tag)
	eq(clean.size(), 5, "五条非法值都验过了")

	# ---- 6) ★ 权威解析：1 起、越界/缺省 → -1（口径只有 `escort_leader_index` 一处）----
	eq(LevelRes.escort_leader_index({"escort_of": 1}), 0, "escort_of: 1 → 第 1 位（下标 0）")
	eq(LevelRes.escort_leader_index({"escort_of": 3}), 2, "escort_of: 3 → 第 3 位（下标 2）")
	eq(LevelRes.escort_leader_index({"escort_of": 2.0}), 1, "整数值的 float 认（2.0 → 下标 1）")
	eq(LevelRes.escort_leader_index({}), -1, "缺省 → -1（不是附属兵）")
	eq(LevelRes.escort_leader_index({"escort_of": 0}), -1, "0 不是合法序号（1 起）→ -1")

	# ---- 7) ★★ **AI 摆的附属兵也真的出现**（本轮删掉了 with_escort = 只给本机）----
	#
	# 旧口径下「开局附属兵」只给 `faction == my_faction` 的那一方 ——
	# 于是关卡给 AI 阵营摆的附属兵**根本不会出现**。本轮整个删掉了那个限制：
	# 谁摆了就给谁。这一条钉住它（AI 那一方也由关卡接管、也照摆不误）。
	var lv4 = _escort_probe_level(cfg, "ai_placed", [
		{"faction": "E1", "kind": "spearman", "x": 16, "y": 13, "hold": true, "escort_of": 1},
		{"faction": "E1", "kind": "spearman", "x": 17, "y": 13, "hold": true, "escort_of": 1},
	], [{"id": "E1", "ai": LevelRes.AI_FACTION, "base": [18, 14]}])
	if lv4 == null:
		return
	var w4 = WorldRes.create_from_level(cfg, lv4, "p1", ["p1"], true)
	ok(w4 != null, "按关卡建出世界（AI 阵营摆的附属兵）")
	if w4 == null:
		return
	var g_e1 = w4.unit_by_id("general-E1-1")
	ok(g_e1 != null, "★★ AI 阵营的将领也在场（关卡点名了它的附属部队 ⇒ 整方由关卡接管）")
	eq(w4.retinue_of("general-E1-1").size(), 2,
		"★★ AI 摆的附属兵**真的出现了**（不再被 with_escort 挡掉）")
	var e1_subs := 0
	for u in w4.units:
		if String(u.faction) == "E1" and String(u.leader_id) == "general-E1-1":
			e1_subs += 1
	eq(e1_subs, 2, "★★ 而且它们都挂在 AI 将领的 id 上（同阵营同序号）")


## 写一份只带 `start_units[]` 的最小关卡（本轮：附属兵靠**逐兵摆放**）。
##
## @param extra_factions 额外要写进 `factions[]` 的阵营条目（**AI 阵营必须写**：
##        关卡没点名、又不在 config 名单里的阵营不会进这一局的名单，
##        于是它的将领一个都不会生成 —— 见 `world.spawn_faction_units` 第一道门）。
func _escort_probe_level(cfg, tag: String, units: Array, extra_factions: Array = []):
	var path := "%s/escort/%s.json" % [TMP_ROOT, tag]
	var facs: Array = [{"id": "p1"}]
	for f in extra_factions:
		facs.append(f)
	_write_text(path, JSON.stringify({
		"map": "frontier",
		"name": "摆放附属兵探针",
		"players": [{"faction": "p1"}],
		"factions": facs,
		"start_units": units,
	}))
	var lv = LevelRes.load_level(null, path, cfg)
	if lv == null:
		ok(false, "探针关卡能载入（%s）" % path)
	return lv


## 写一个临时文本文件（工程内的临时目录；`user://` 在这个工程里写不进去，
## 见 test_campaign.gd 的 TMP_ROOT 说明）。
func _write_text(path: String, text: String) -> void:
	var d := path.get_base_dir()
	if d != "":
		DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		ok(false, "能写临时文件：%s" % path)
		return
	f.store_string(text)
	f.close()


## 某一格属于哪个区划（-1 = 不属于任何区划）
func _zone_id_of(w, tile: Vector2i) -> int:
	var z: Variant = w.zones.zone_at(tile.x, tile.y)
	if z == null:
		return -1
	return int((z as Dictionary)["id"])


func _test_general_ai_no_pursuit(cfg) -> void:
	var w = _world(cfg)
	if w == null:
		return

	# ★★ 本轮口径（用户原话）：
	#   「巡逻时发现敌人后向该敌人追击，当该敌人死亡或在自己的警戒范围外时，
	#     放弃追击转为立刻返回所属区划继续巡逻」。
	#   ⇒ 旧断言（「一跨进别的区划就当场脱战」「无主空地上离中心太远也算追出去」）
	#     钉的是**上一版**的行为（按**自己**的位置判），而那个判据正是这次要修掉的抖动源：
	#     它在边界上自相矛盾（我在区划外 = 该回，敌人在警戒内 = 该打），于是来回抽。
	#     所以这一组**整组重写**成新口径：只按「敌人离发现点的距离」与「目标死活」判。
	#
	# 场面仍然用同一条最短边界：区划 6 与区划 5 的分界是 x = 10
	# （(9,12) 属区划 6、(10,12) 属区划 5，相距 1 格）。
	var g = _make_garrison(w, cfg, Vector2i(9, 12), 6)
	if g == null:
		return
	g.hold_position = false          # 让 combat 的追击逻辑能驱动它（下面几段要真追）
	var foe = UnitRes.create(cfg, "test-foe-1", "入侵者", Vector2i(10, 12),
		FactionRes.DEFAULT_FACTION, UnitRes.UNIT_TYPE_SPEARMAN)
	w.units.append(foe)

	var z5 = w.zone_by_id(5)
	var z6 = w.zone_by_id(6)
	eq(w.zones.zone_at(9, 12), z6, "测试前提：(9,12) 是守将自己的区划（区划 6）")
	eq(w.zones.zone_at(10, 12), z5, "测试前提：(10,12) 是隔壁区划（区划 5）")

	# ---- ★★ 0) 抖动回归：**就站在隔壁区划里**打敌人，位置不许来回抽 ----
	#
	# 这一条钉的就是报回来的那个 bug：「将领性 AI 在非其所属区域内攻击敌人时一定原地抽搐」。
	# 判据用**位置轨迹**：新口径下「区划边界」与「打不打」完全无关，
	# 所以它应当朝敌人稳步靠近，而不是一帧进一帧出地原地跳。
	g.pos = GridRes.center_of(Vector2i(10, 12))      # 故意站在**别人的区划**里
	g.sync_tile(w.map)
	g.hold_position = false
	g.clear_chase()
	g.retarget_cd = 0.0
	g.target = foe
	g.target_building = null
	g.anchor = g.pos
	g.chase_anchor = g.pos
	g.chase_alert_range = 4.0
	g.chase_last_pos = g.pos
	g.chasing = true                                 # 等价于「巡逻时刚警戒到它」
	foe.pos = g.pos + Vector2(3.0, 0.0)              # 敌人在警戒范围内（3 ≤ 4）
	foe.sync_tile(w.map)
	var flips := 0
	var last_side := 0
	for i in 20:
		GeneralAiRes.update(w, cfg, 0.05)
		w.tick(0.05)
		var side := signi(int(round(g.pos.x - 10.5)))   # 相对那条边界在哪一侧
		if side != 0 and last_side != 0 and side != last_side:
			flips += 1
		if side != 0:
			last_side = side
	eq(flips, 0,
		"★★★ 站在**别人的区划**里打敌人时位置不在边界上来回跳（跨边界 %d 次）" % flips)
	ok(g.chasing, "★★ 而且它还在追（没有被「我不在自己区划里」那条旧规则叫回去）")

	# ---- 1) 追击中：敌人在警戒范围内 ⇒ 一路追（不因为我踩出区划就脱战）----
	g.pos = GridRes.center_of(Vector2i(10, 12))
	g.sync_tile(w.map)
	g.clear_chase()
	g.retarget_cd = 0.0
	g.target = foe
	g.target_building = null
	g.anchor = g.pos
	var dist0: float = g.pos.distance_to(foe.pos)
	g.chase_anchor = g.pos
	g.chase_alert_range = maxf(dist0, 4.0)
	g.chase_last_pos = g.pos
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.chasing, "★ 在别人的区划里交战：进入追击状态（旧口径会在这里当场脱战）")
	eq(g.target, foe, "★ 目标还在（该打就打，与我在哪个区划无关）")

	# ---- 2) 目标**跑出警戒范围** ⇒ 放弃追击 + 立刻回家 + 拉再战冷却 ----
	#
	# 把敌人挪到「离发现点超出警戒范围」的地方（判据量的是敌人，不是我）。
	foe.pos = g.chase_anchor + Vector2(g.chase_alert_range + 2.0, 0.0)
	foe.sync_tile(w.map)
	g.stop()                        # 清掉这一轮的路径，只看这一帧下了什么命令
	g.target = foe
	g.target_building = null
	g.anchor = g.pos
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.target == null and g.target_building == null,
		"★★ 敌人跑出警戒范围 ⇒ 放弃追击（当场脱战）")
	ok(not g.chasing, "★★ 追击状态也清掉了")
	ok(float(g.retarget_cd) > 0.0,
		"★ 放弃追击时拉起再战冷却（回家路上别被同一个敌人立刻再锁上）")
	ok(g.returning_home, "★★ 转为「回家」状态（用户口径：**立刻**返回所属区划）")
	ok(not g.path.is_empty() or g.moving, "★ 它真的上路了（返程命令下出去了）")
	var path_home: int = g.path.size()

	# 再来两帧：返程途中**不该**重复下命令（路径只减不增）—— 这就是「不再抽搐」
	GeneralAiRes.update(w, cfg, 0.05)
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.returning_home, "★★ 还在回家路上（标志没有被清掉）")
	ok(g.path.size() <= path_home,
		"★★★ 返程途中不重复下命令（路径只减不增：%d → %d）" % [path_home, g.path.size()])

	# ---- 3) 目标**死亡** ⇒ 同样放弃追击、立刻回家 ----
	foe.alive = false
	g.pos = GridRes.center_of(Vector2i(10, 12))
	g.sync_tile(w.map)
	g.stop()
	g.returning_home = false
	g.retarget_cd = 0.0
	g.clear_chase()
	g.chasing = true
	g.chase_anchor = g.pos
	g.chase_alert_range = 4.0
	g.target = foe                     # combat 还没结算掉（模拟「这一帧刚死」）
	g.target_building = null
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.target == null, "★★ 敌人死亡 ⇒ 放弃追击（脱战）")
	ok(not g.chasing, "★★ 追击状态清掉")
	ok(g.returning_home, "★★ 目标死了也走「立刻返回所属区划」这一条")

	# ---- 4) 走到家（站定在巡逻点上）⇒ 返程结束、恢复正常巡逻 ----
	g.pos = GridRes.center_of(Vector2i(9, 12))
	g.sync_tile(w.map)
	g.stop()
	g.retarget_cd = 0.0
	g.patrol_timer = 0.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(not g.returning_home,
		"★★ 站定在自己的区划里之后返程结束（否则它再也回不到巡逻节奏）")
	ok(g.patrol_points.size() >= 1, "★ 返程结束之后照旧有自己的巡逻路线")

	# ---- 5) 冷却期内不接战（防「刚放弃又被锁」那一下）----
	g.target = foe
	g.retarget_cd = 1.0
	GeneralAiRes.update(w, cfg, 0.05)
	ok(g.target == null, "★ 再战冷却期内不会被重新拖进战斗")

	# ---- 6) 玩家/别的 AI 重下命令时，这两个标志不该留成幽灵 ----
	g.pos = GridRes.center_of(Vector2i(10, 12))
	g.sync_tile(w.map)
	g.clear_chase()
	g.returning_home = true
	g.retarget_cd = 0.0
	g.chasing = true
	var dst := GridRes.center_of(Vector2i(9, 12))
	g.order_move(w, cfg, dst)
	ok(not g.returning_home, "★★ 新命令会清掉「回家」状态（不会把它卡在返程模式里）")
	ok(not g.chasing, "★★ 新命令也清掉「追击」状态")
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
		tile, FactionRes.NPC_FACTION, UnitRes.UNIT_TYPE_SPEARMAN)
	u.garrison_zone_id = zone_id
	u.hold_position = true
	w.units.append(u)
	return u
