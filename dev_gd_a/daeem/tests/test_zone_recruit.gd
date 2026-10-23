## test_zone_recruit.gd —— 区划招募（点区划中心 → 右下「招募」页签 → 招将领）
##
## 本轮（将领招募池）口径：
##   · 池 = config.recruit.zone.list 的 9 名占位将领；每个玩家一套三个槽位；
##   · 招走一名 → 三名全部重抽，且招走的那位在本次「盒」里不再出现；
##   · 招募冷却**全局**：招到任意一名后整方锁 N 秒（N = 该将的 recruit_cooldown_sec），
##     入队即开始，取消即解除；
##   · 取消会把那位**放回池子**（不永久损失）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_zone_recruit"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_pool_hand(cfg)
	_test_only_own_zone(cfg)
	_test_enqueue_pays_and_cooldown(cfg)
	_test_cooldown_tick_and_cancel(cfg)
	_test_train_and_spawn_near_center(cfg)
	_test_queue_cap_and_cancel(cfg)
	_test_pool_removal_and_box_reset(cfg)
	_test_commands(cfg)
	_test_stop_command(cfg)

func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	eq(w.zone_recruit_list().size(), 9, "★ 区划招募池里有九名占位将领")
	ok(w.general_recruit_pool_enabled(), "★ 招募池启用")
	eq(w.general_recruit_hand_size(), 3, "★ 一手三名（命令卡 Q/W/E）")
	for i in 9:
		ok(w.is_zone_recruitable("general_%d" % (i + 1)), "general_%d 在招募池里" % (i + 1))
	ok(not w.is_unit_recruitable("general_1"),
		"★ 池里的将领**不能**走「将领招兵」那条路（两张表是分开的）")
	ok(w.is_recruitable("general_4"), "但它仍然是「可招募兵种」（短字 / 消耗查表要用）")
	ok(w.is_unit_recruitable(UnitRes.UNIT_TYPE_SPEARMAN), "长枪兵仍然只在单位那张表里")
	eq(w.recruit_short_of("general_4"), "将", "格子里写的短字是 config 的 short（将）")
	eq(w.zone_recruit_queue_max(), 5, "★ 区划队列上限 5 个")
	near(w.recruit_train_sec("general_4"), 10.0, 1e-6, "★ 每个将领读条 10 秒")
	near(float(w.recruit_population_cost("general_4")), 1.0, 1e-6, "★ 每个将领吃 1 人口")
	near(float(w.recruit_cost("general_1").get("food", 0.0)), 100.0, 1e-6, "★ 将领 1 100 粮食")
	near(float(w.recruit_cost("general_1").get("gold", 0.0)), 100.0, 1e-6, "★ 将领 1 100 黄金")
	near(float(w.recruit_cost("general_4").get("food", 0.0)), 120.0, 1e-6, "★ 将领 4 120 粮食")
	near(float(w.recruit_cost("general_4").get("gold", 0.0)), 120.0, 1e-6, "★ 将领 4 120 黄金")
	near(float(w.recruit_cost("general_9").get("food", 0.0)), 160.0, 1e-6, "★ 将领 9 160 粮食")
	near(float(w.recruit_cost("general_9").get("gold", 0.0)), 200.0, 1e-6, "★ 将领 9 200 黄金")
	eq(w.recruit_label_of("general_1"), "将领 1", "显示名来自 label")
	eq(w.recruit_label_of("general_9"), "将领 9", "第 9 位的显示名")
	near(w.general_recruit_cooldown_of("general_1"), 20.0, 1e-6, "★ 将领 1 招募冷却 20 秒")
	near(w.general_recruit_cooldown_of("general_4"), 25.0, 1e-6, "★ 将领 4 招募冷却 25 秒")
	near(w.general_recruit_cooldown_of("general_9"), 45.0, 1e-6, "★ 将领 9 招募冷却 45 秒")

func _test_pool_hand(cfg) -> void:
	var w = _quiet(cfg)
	var hand: Array = w.general_recruit_slots("p1")
	eq(hand.size(), 3, "★ 开局就抽好一手三名")
	var seen: Dictionary = {}
	for item in hand:
		var k := String(item)
		ok(w.is_zone_recruitable(k), "%s 在池里" % k)
		ok(not seen.has(k), "同一手不重复：%s" % k)
		seen[k] = true
	near(w.general_recruit_cooldown_left("p1"), 0.0, 1e-6, "开局没有招募冷却")
	near(w.general_recruit_cooldown_total("p1"), 0.0, 1e-6, "总冷却也是 0")
	eq(w.general_recruit_slots("p1").size(), 3, "读槽位不会把这一手抽掉")

func _test_only_own_zone(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	ok(z != null, "找得到一块己方区划（大本营把出生区划收归己方）")
	if z == null:
		return
	var zid := int(z["id"])
	var kind := _kind_at(w, 0)
	ok(kind != "", "（前提）手牌里有一张")
	eq(w.can_recruit_zone(kind, zid, "p1"), "", "★ 己方区划 + 手牌里的一位 → 可以招")

	var off := _kind_not_in_hand(w)
	ok(off != "", "找得到一位不在当前手牌里的将领")
	eq(w.can_recruit_zone(off, zid, "p1"), "pool",
		"★ 不在三个槽位里的将领 → 拒因 pool")

	var foreign = _foreign_zone(w)
	ok(foreign != null, "地图上找得到一块不属于 p1 的区划")
	if foreign != null:
		eq(w.can_recruit_zone(kind, int(foreign["id"]), "p1"), "zone_owner",
			"★ 不是自己的区划 → 拒因 zone_owner")
		var food0: float = float(w.resources["food"])
		ok(not w.start_zone_recruit(kind, int(foreign["id"]), "p1"), "★ 别人的区划招不了")
		near(float(w.resources["food"]), food0, 1e-6, "被拒时一分钱都不扣")
		eq(w.zone_recruit_queue_size(foreign), 0, "被拒时队列里什么都没有")

	eq(w.can_recruit_zone(kind, 9999, "p1"), "zone_not_found", "没有这个区划 → zone_not_found")
	eq(w.can_recruit_zone(UnitRes.UNIT_TYPE_SPEARMAN, zid, "p1"), "kind",
		"单位页那张表里的兵种不能在区划里招（拒因 kind）")

	if foreign != null:
		foreign["owner"] = "p1"
		eq(w.can_recruit_zone(kind, int(foreign["id"]), "p1"), "", "划给己方之后就能招了")

func _test_enqueue_pays_and_cooldown(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var before_units: int = w.units.size()

	var hand: Array = w.general_recruit_slots("p1")
	var kind := String(hand[0])
	var cost: Dictionary = w.recruit_cost(kind)
	var cd: float = w.general_recruit_cooldown_of(kind)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])

	ok(w.start_zone_recruit(kind, zid, "p1"), "区划招募入队成功")
	near(float(z["train_remaining"]), 10.0, 1e-6, "刚入队时剩余 = 10 秒")
	near(w.zone_train_progress(z), 0.0, 1e-6, "刚入队时进度是 0")
	eq(_count_events(w._events, "zone_recruit_queued"), 1,
		"入队发一条 zone_recruit_queued 事件")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-4,
		"★ 入队即扣粮食")
	near(float(w.resources["gold"]), gold0 - float(cost.get("gold", 0.0)), 1e-4,
		"★ 入队即扣黄金")
	near(float(z["population"]), 4.0, 1e-4, "★ 入队即扣 1 人口（从**这个区划**扣）")

	eq(String(z["train_kind"]), kind, "★ 大格子里是刚排进来的那个")
	near(float(z["train_total"]), 10.0, 1e-6, "记录了总读条时间 10 秒")
	eq(w.zone_recruit_queue_size(z), 1, "队列里一共 1 个")
	ok(w.zone_is_training(z), "★ 这个区划进入「招募中」状态")
	eq(w.units.size(), before_units, "★ 入队不会立刻生成单位（要读条 10 秒）")
	eq(String(z["train_faction"]), "p1", "记下了招募方（读完按它出兵）")

	# ★★ 冠军招募冷却：入队即开始，且是**这位将领自己的**「招募冷却」。
	near(w.general_recruit_cooldown_left("p1"), cd, 1e-4,
		"★ 入队即进入全局冷却（= 这位将领的招募冷却）")
	near(w.general_recruit_cooldown_total("p1"), cd, 1e-4, "总时长也记下来了")

	# ★★ 招走一名 → 三名全部重抽，且这一位在本次「盒」里消失。
	var hand2: Array = w.general_recruit_slots("p1")
	eq(hand2.size(), 3, "★ 重抽后仍是三名")
	ok(not hand2.has(kind), "★ 招走的那位不在新手牌里")
	ok(not _available(w).has(kind), "★ 也不在本次盒里（招走即出池）")

	# 再招（哪怕是新手牌里另一位）会被全局冷却挡住。
	var food1: float = float(w.resources["food"])
	eq(w.can_recruit_zone(String(hand2[0]), zid, "p1"), "cooldown",
		"★ 冷却中 → 拒因 cooldown")
	ok(not w.start_zone_recruit(String(hand2[0]), zid, "p1"), "★ 冷却中再招被拒")
	near(float(w.resources["food"]), food1, 1e-6, "被拒的那一单不扣钱")
	var evts: Array = w.tick(DT)
	var rej := _first_event(evts, "recruit_rejected")
	eq(String(rej.get("reason", "")), "cooldown", "拒因码是 cooldown")
	ok(float(rej.get("cooldown", 0.0)) > 0.0, "★ 事件里带着剩余冷却（界面文案用它）")

func _test_cooldown_tick_and_cancel(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var kind := _kind_at(w, 0)
	var cost: Dictionary = w.recruit_cost(kind)
	var cd: float = w.general_recruit_cooldown_of(kind)
	ok(w.start_zone_recruit(kind, zid, "p1"), "先排一单（前提）")

	_tick_secs(w, 5.0)
	near(w.general_recruit_cooldown_left("p1"), cd - 5.0, 0.2,
		"★ 冷却按真实时间往下走")
	near(w.general_recruit_cooldown_total("p1"), cd, 1e-4, "总时长不变（界面画「已过 / 总」）")

	# ★ 取消：退钱 + 解冻 + 把这位放回池子。
	var food0: float = float(w.resources["food"])
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "取消大格子成功")
	near(w.general_recruit_cooldown_left("p1"), 0.0, 1e-6,
		"★ 取消招募 → 立刻解除冷却")
	near(float(w.resources["food"]), food0 + float(cost.get("food", 0.0)), 1e-4,
		"★ 取消全额退款")
	ok(_available(w).has(kind), "★ 取消的那位回到池子里（不永久损失）")
	eq(w.can_recruit_zone(_kind_at(w, 0), zid, "p1"), "",
		"★ 解冻之后可以接着招（新一手）")

func _test_train_and_spawn_near_center(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 500.0, 500.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var center: Vector2i = z["center"]
	var kind := _kind_at(w, 0)
	var cd: float = w.general_recruit_cooldown_of(kind)
	ok(w.building_at(center.x, center.y) != null,
		"（前提）区划中心那一格上立着中立障碍建筑（所以不能生成在格心）")

	var before_units: int = w.units.size()
	ok(w.start_zone_recruit(kind, zid, "p1"), "排一单")

	_tick_secs(w, 9.0)
	eq(w.units.size(), before_units, "★ 9 秒时还没出人（要读满 10 秒）")
	ok(w.zone_is_training(z), "这时还在读条")
	ok(w.zone_train_progress(z) > 0.5, "读条进度跟着走（%f）" % w.zone_train_progress(z))

	var events := _tick_collect(w, 1.5)
	eq(w.units.size(), before_units + 1, "★ 读满 10 秒 → 生成 1 名将领")
	eq(_count_events(events, "zone_unit_recruited"), 1, "发一条 zone_unit_recruited 事件")
	ok(not w.zone_is_training(z), "★ 队列空了 → 不再是「招募中」")

	var fresh = w.units[w.units.size() - 1]
	eq(String(fresh.kind), kind, "招出来的就是手牌里那位")
	eq(String(fresh.faction), "p1", "属于招募方")
	ok(fresh.alive, "它是活的")
	eq(String(fresh.leader_id), "", "★ 招出来的是**队长**（leader_id 为空）")
	ok(w.is_team_leader(fresh), "★ 它是队长 → 会作为新的一支部队出现在左侧列表里")
	eq(w.retinue_of(fresh.id).size(), 0, "刚招出来的将领名下还没有附属兵")
	ok(String(fresh.id).begins_with("zone-%d-" % zid), "id 里带着区划号（%s）" % fresh.id)

	ok(not (fresh.tx == center.x and fresh.ty == center.y),
		"★ 不生成在区划中心那一格（那里是中立障碍建筑）")
	var cheb: int = maxi(absi(fresh.tx - center.x), absi(fresh.ty - center.y))
	ok(cheb <= 2, "★ 生成在中心**旁边**（切比雪夫距离 %d ≤ 2）" % cheb)
	ok(w.building_at(fresh.tx, fresh.ty) == null, "生成的那一格上没有建筑")

	ok(w.general_recruit_cooldown_left("p1") > 0.0,
		"★ 将领已经出场，但冷却还在走（冷却不因读条完成而清零）")
	ok(w.general_recruit_cooldown_left("p1") <= cd, "冷却当然不会超过它自己的总时长")
	ok(not w.general_recruit_slots("p1").has(kind), "招走的那位仍然不在新手牌里")

func _test_queue_cap_and_cancel(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 5000.0, 5000.0)
	var z = _own_zone(w)
	z["population"] = 100.0
	var zid := int(z["id"])

	# ★ 全局冷却会让「连续排 5 单」在真实玩法里做不到；这里逐次把冷却清零，
	#   模拟「第一单还在读条、冷却先到期」的场面，专门验队列上限 / 取消 / 退款。
	var kinds: Array = []
	for i in 5:
		_clear_cooldown(w)
		var k := _kind_at(w, 0)
		ok(w.start_zone_recruit(k, zid, "p1"), "排第 %d 单成功" % (i + 1))
		kinds.append(k)
	eq(w.zone_recruit_queue_size(z), 5, "队列满 5 个")

	_clear_cooldown(w)
	eq(w.can_recruit_zone(_kind_at(w, 0), zid, "p1"), "queue_full",
		"★ 满了 → 拒因 queue_full")
	var food0: float = float(w.resources["food"])
	ok(not w.start_zone_recruit(_kind_at(w, 0), zid, "p1"), "第 6 单被拒")
	near(float(w.resources["food"]), food0, 1e-6, "被拒的那一单不扣钱")
	var evts: Array = w.tick(DT)
	var full_evt := _first_event(evts, "recruit_rejected")
	eq(String(full_evt.get("reason", "")), "queue_full", "拒因码是 queue_full")
	eq(int(full_evt.get("max", 0)), 5, "★ 事件里带着队列上限（界面文案用它）")

	var pop0: float = float(z["population"])
	var cancel_kind: String = w.zone_recruit_kind_at(z, 1)
	var cancel_cost: Dictionary = w.recruit_cost(cancel_kind)
	ok(w.cancel_zone_recruit(zid, 1, "p1"), "★ 取消第 1 个小格子")
	near(float(w.resources["food"]),
		food0 + float(cancel_cost.get("food", 0.0)), 1e-4, "★ 取消退全额粮食")
	near(float(z["population"]), pop0 + 1.0, 1e-4, "★ 人口也退还给**这个区划**")
	eq(w.zone_recruit_queue_size(z), 4, "队列少了一个（后方的自动前移）")

	ok(not w.cancel_zone_recruit(zid, 4, "p1"), "★ 空格子取消被拒（什么都不做）")
	eq(w.zone_recruit_queue_size(z), 4, "空格子取消不改队列")

	var remaining_before := float(z["train_remaining"])
	eq(w.zone_recruit_kind_at(z, 0), String(kinds[0]), "（前提）大格子里有东西")
	var next_kind: String = w.zone_recruit_kind_at(z, 1)
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "★ 取消大格子")
	eq(w.zone_recruit_queue_size(z), 3, "再少一个")
	eq(w.zone_recruit_kind_at(z, 0), next_kind, "下一个前移进了大格子")
	near(float(z["train_remaining"]), float(z["train_total"]), 1e-4,
		"★ 前移的那一单从头读条（不继承已读掉的时间）")
	ok(remaining_before <= 10.0, "（前提）取消前它确实在读条")

	var foreign = _foreign_zone(w)
	if foreign != null:
		ok(not w.cancel_zone_recruit(int(foreign["id"]), 0, "p1"),
			"★ 别人的区划里的队列取消不了")

func _test_pool_removal_and_box_reset(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 100000.0, 100000.0)
	var z = _own_zone(w)
	z["population"] = 1000.0
	var zid := int(z["id"])

	# 招 7 次（模拟每次读条都立刻完成，专门验「盒抽」）。
	for i in 7:
		_clear_cooldown(w)
		var k := _kind_at(w, 0)
		ok(w.start_zone_recruit(k, zid, "p1"), "第 %d 次招募成功" % (i + 1))
		# 模拟读条立刻完成：把这单从区划队列里清掉（不关心人口 / 退款）。
		z["train_kind"] = ""
		z["train_queue"] = []
		z["train_remaining"] = 0.0
		z["train_total"] = 0.0
		var avail: Array = _available(w)
		if i < 6:
			ok(not avail.has(k), "第 %d 次招走后，这位在本次盒里消失" % (i + 1))
		else:
			ok(avail.has(k),
				"★ 第 7 次招走后池子不足一手 → 整池重置（这位回到池里）")
		eq(w.general_recruit_slots("p1").size(), 3, "每次重抽都还是三名")

func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 10.0
	var zid := int(z["id"])
	var kind := _kind_at(w, 0)

	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": kind,
		"zone_id": zid, "faction": "p1"}), "zone_recruit 命令被接受")
	ok(w.zone_is_training(z), "命令真的把它排进了区划的队列")
	ok(w.general_recruit_cooldown_left("p1") > 0.0, "★ 命令路径同样起冷却")
	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit_cancel", "zone_id": zid,
		"slot": 0, "faction": "p1"}), "zone_recruit_cancel 命令被接受")
	ok(not w.zone_is_training(z), "取消之后队列空了")
	near(w.general_recruit_cooldown_left("p1"), 0.0, 1e-6,
		"★ 命令路径取消也会解除冷却")

	ok(not CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": kind,
		"zone_id": zid, "faction": "p2"}), "★ 别的阵营不能在这个区划里招")

func _test_stop_command(cfg) -> void:
	var w = _quiet(cfg)
	var g1 = w.unit_by_id("general-1")
	ok(g1 != null, "有 general-1")
	if g1 == null:
		return
	var spot := _free_tile(w)
	ok(spot.x >= 0, "找得到一格空地")
	if spot.x < 0:
		return
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g1.id],
		"x": float(spot.x) + 0.5, "y": float(spot.y) + 0.5, "faction": "p1"}),
		"先下一条移动命令（前提）")
	ok(g1.moving, "（前提）它正在移动")
	ok(CommandRes.apply(w, cfg, {"kind": "stop", "ids": [g1.id], "faction": "p1"}),
		"★ stop 命令被接受")
	ok(not g1.moving, "★ 停止之后不再移动")
	ok(g1.path.is_empty(), "路径也清空了")
	ok(not CommandRes.apply(w, cfg, {"kind": "stop", "ids": [g1.id], "faction": "p2"}),
		"★ 防冒充：别的阵营停不了我的单位")

func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	var w = require_world(c)
	# 区划招募的旧用例默认「将领想招几个招几个」；1 级大本营现在最多 3 名（开局正好 3 名），
	# 所以把这些用例的大本营拉到 3 级（上限 10）。上限规则由 test_base_limits.gd 专门验。
	var b = w.find_base_of("p1")
	if b != null:
		b.level = w.cfg.upgrade_max_level("base")
		w.apply_building_level_hp(b)
	return w

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != "p1":
			continue
		if z["center"] == null:
			continue
		return z
	return null

func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == "p1":
			continue
		return z
	return null

func _free_tile(w) -> Vector2i:
	for ty in w.map.rows:
		for tx in w.map.cols:
			if not w.can_build_at(tx, ty):
				continue
			if w.zone_center_zone_at(tx, ty) != null:
				continue
			return Vector2i(tx, ty)
	return Vector2i(-1, -1)

## 当前手牌里第 i 位（越界 → ""）
func _kind_at(w, i: int) -> String:
	var hand: Array = w.general_recruit_slots("p1")
	if i < 0 or i >= hand.size():
		return ""
	return String(hand[i])

func _kind_not_in_hand(w) -> String:
	var hand: Array = w.general_recruit_slots("p1")
	for item in w.zone_recruit_list():
		var k := String((item as Dictionary).get("kind", ""))
		if k != "" and not hand.has(k):
			return k
	return ""

## 本次「盒」里还没被招走的 kind（测试直接看权威状态；不给游戏加测试专用接口）
func _available(w) -> Array:
	var st: Dictionary = w.general_recruit_pools["p1"]
	return st.get("available", [])

## 把当前全局冷却清零（模拟「时间过去了」；只有队列上限 / 盒抽用例需要）
func _clear_cooldown(w) -> void:
	var st: Dictionary = w.general_recruit_pools["p1"]
	st["cooldown"] = 0.0
	st["cooldown_total"] = 0.0
	st["cooldown_kind"] = ""
	st["cooldown_zone"] = -1

func _tick_secs(w, secs: float) -> void:
	var n: int = int(ceil(secs / DT))
	for _i in n:
		w.tick(DT)

func _tick_collect(w, secs: float) -> Array:
	var out: Array = []
	var n: int = int(ceil(secs / DT))
	for _i in n:
		for e in (w.tick(DT) as Array):
			out.append(e)
	return out

func _count_events(events: Array, type_name: String) -> int:
	var n := 0
	for e in events:
		if String(e.get("type", "")) == type_name:
			n += 1
	return n

func _first_event(events: Array, type_name: String) -> Dictionary:
	for e in events:
		if String(e.get("type", "")) == type_name:
			return e
	return {}
