## test_recruit_queue.gd —— 招募队列（将领 = 兵营）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0
const KIND := "spearman"

const ESCORTS_PER_GENERAL := 3

func _initialize() -> void:
	_case_name = "test_recruit_queue"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_zone_restriction(cfg)
	_test_enqueue_pays(cfg)
	_test_reject_reasons(cfg)
	_test_queue_cap(cfg)
	_test_train_timing_and_nearby_spawn(cfg)
	_test_spawn_avoids_occupied_tile(cfg)
	_test_mobile_while_training(cfg)
	_test_damage_pauses_training(cfg)
	_test_retinue_not_locked_while_training(cfg)
	_test_cancel_queue(cfg)
	_test_recruit_eta(cfg)
	_test_cancel_then_death(cfg)
	_test_death_refund(cfg)
	_test_population_cap_and_recruit(cfg)
	_test_snapshot_round_trip(cfg)

func _test_config_table(cfg) -> void:
	var w = require_world(cfg)
	ok(w.is_recruitable(KIND), "config.recruit.list 里长枪兵可招募")
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")
	eq(w.recruit_queue_max(), 5, "★ 队列上限 5 个（1 大格 + 4 小格）")
	near(w.recruit_train_sec(KIND), 10.0, 1e-6, "★ 区划招募仍读每个单位的 train_sec")
	near(w.recruit_batch_sec(), 10.0, 1e-6, "★ 单位页批次读条固定 10 秒")
	near(float(w.recruit_population_cost(KIND)), 1.0, 1e-6, "★ 每个单位吃 1 人口")
	var cost: Dictionary = w.recruit_cost(KIND)
	ok(float(cost.get("food", 0.0)) > 0.0, "★ 长枪兵要粮食（数值以 config 为准，别写死）")
	near(float(cost.get("gold", 0.0)), 0.0, 1e-6, "★ 长枪兵不吃黄金")
	eq(w.recruit_short_of(KIND), "枪", "信息栏格子里用 config 的 short（长枪兵 = 枪）")

func _test_zone_restriction(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	ok(g1 != null, "有 general-1")
	if g1 == null:
		return

	eq(w.can_recruit(KIND, g1.id, "p1"), "", "★ 将领站在己方区划里 → 可以招募")
	ok(w.leader_zone_owned(g1), "将领所在区划归它那一方（大本营把出生区划收归己方）")

	var spot := _foreign_tile(w, "p1")
	ok(spot.x >= 0, "地图上找得到一格不属于 p1 的区划地块")
	if spot.x >= 0:
		g1.pos = GridRes.center_of(spot)
		g1.sync_tile(w.map)
		ok(not w.leader_zone_owned(g1), "站到别人的区划里之后不再算己方区划")
		eq(w.can_recruit(KIND, g1.id, "p1"), "zone", "★ 不在己方区划内 → 拒因是 zone")
		var food0: float = float(w.resources["food"])
		ok(not w.start_recruit(KIND, g1.id, "p1"), "★ 区划不对时招募命令被拒")
		near(float(w.resources["food"]), food0, 1e-6, "被拒时**一分钱都不扣**")
		eq(g1.train_queue_size(), 0, "被拒时队列里什么都没有")

	var z = w.zones.zone_at(g1.tx, g1.ty)
	if z != null:
		z["owner"] = "p1"
		eq(w.can_recruit(KIND, g1.id, "p1"), "", "★ 那块地归己方之后就能招募了")

func _test_enqueue_pays(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 200.0, 200.0)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 5.0
	var before_subs: int = w.retinue_of(g1.id).size()
	var fcost: float = _food_of(w, KIND)

	ok(w.start_recruit(KIND, g1.id, "p1"), "招募入队成功")
	near(float(w.resources["food"]), 200.0 - fcost, 1e-4, "★ 入队即扣粮（= config 里这个兵种的粮价）")
	near(float(w.resources["gold"]), 200.0 - _gold_of(w, KIND), 1e-4, "★ 黄金也按 config")
	near(float(z["population"]), 4.0, 1e-4, "★ 入队即扣 1 人口（从将领所在区划扣）")

	eq(g1.train_kind, KIND, "★ 大格子里是刚排进来的那个")
	near(g1.train_total, 10.0, 1e-6, "大格子记录了总读条时间 10 秒")
	near(g1.train_remaining, 10.0, 1e-6, "刚入队时剩余 = 10 秒")
	eq(g1.train_queue.size(), 0, "小格子里还没有排队的")
	eq(g1.train_queue_size(), 1, "队列里一共 1 个")
	ok(g1.is_training(), "★ 将领进入「招募中」状态")
	near(g1.train_progress(), 0.0, 1e-6, "刚入队时进度是 0")
	eq(w.retinue_of(g1.id).size(), before_subs, "★ 入队**不会立刻生成单位**（要读条 10 秒）")
	eq(w.recruit_queue_max(), 5, "上限仍然是 5")
	eq(g1.train_anchor, g1.pos, "★ 记录下单时的位置（历史字段；招募已不再因此钉住）")

	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一个也成功")
	eq(g1.train_queue.size(), 1, "第二个排进小格子")
	eq(g1.train_queue_size(), 2, "队列里一共 2 个")
	near(g1.train_remaining, 10.0, 1e-6, "★ 正在读条的还是第一个（排队的不会抢读条）")

func _test_reject_reasons(cfg) -> void:
	var w = require_world(cfg)
	var g1 = _first_general(w)
	ok(g1 != null, "有开局将领")
	if g1 == null:
		return
	var z = w.zones.zone_at(g1.tx, g1.ty)

	eq(w.can_afford_recruit(KIND, g1.id), "cost", "★ 没钱 → 拒因 cost")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "没钱时招募被拒")
	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "recruit_rejected"), 1,
		"被拒会发一条 recruit_rejected 事件（界面靠它显示原因）")
	eq(_last_reject_reason(evts), "cost", "事件里带拒因码 cost")

	_give(w, 1000.0, 1000.0)
	z["population"] = 0.5
	eq(w.can_afford_recruit(KIND, g1.id), "population", "★ 人口不足 → 拒因 population")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "人口不足时招募被拒")
	eq(g1.train_queue_size(), 0, "被拒的招募不会进队列")

	z["population"] = 1.0
	eq(w.can_afford_recruit(KIND, g1.id), "", "人口够 → 可以招")
	ok(w.start_recruit(KIND, g1.id, "p1"), "这次入队成功")

	_leader_reject_checks(cfg)

func _leader_reject_checks(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	var sub = w.retinue_of(g1.id)[0]
	eq(w.can_recruit(KIND, "general-99", "p1"), "leader", "队长不存在 → leader")
	eq(w.can_recruit(KIND, sub.id, "p1"), "leader", "★ 附属兵不是队长，不能往它名下招兵")
	eq(w.can_recruit(KIND, g1.id, FactionRes.NPC_FACTION), "faction",
		"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")
	ok(not w.start_recruit(KIND, sub.id, "p1"), "往附属兵名下招募被拒")

func _test_queue_cap(cfg) -> void:
	var w = require_world(cfg)
	_give(w, 10000.0, 10000.0)
	var g1 = _first_general(w)
	ok(g1 != null, "有开局将领")
	if g1 == null:
		return
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 100.0

	for i in w.recruit_queue_max():
		ok(w.start_recruit(KIND, g1.id, "p1"), "第 %d 个排进队列" % (i + 1))
	eq(g1.train_queue_size(), 5, "★ 队列里最多 5 个（1 大 + 4 小）")
	eq(g1.train_queue.size(), 4, "★ 小格子里最多 4 个")
	eq(w.can_recruit(KIND, g1.id, "p1"), "queue_full", "★ 队列满了 → 拒因 queue_full")
	var food_before: float = float(w.resources["food"])
	ok(not w.start_recruit(KIND, g1.id, "p1"), "第 6 个被拒")
	near(float(w.resources["food"]), food_before, 1e-6, "被拒的第 6 个不扣钱")
	eq(g1.train_queue_size(), 5, "队列还是 5 个")

func _test_train_timing_and_nearby_spawn(cfg) -> void:
	var w = _quiet_world(cfg)          # 关战斗：这一节只验读条与落点
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var before: int = w.retinue_of(g1.id).size()

	var tile := Vector2i(g1.tx, g1.ty)
	g1.pos = GridRes.center_of(tile) + Vector2(0.3, 0.0)
	g1.sync_tile(w.map)

	ok(w.start_recruit(KIND, g1.id, "p1"), "入队成功")
	_tick_secs(w, 5.0)
	near(g1.train_remaining, 5.0, 0.05, "★ 读条 5 秒后剩 5 秒")
	near(g1.train_progress(), 0.5, 0.02, "读条进度约 50%")
	eq(w.retinue_of(g1.id).size(), before, "读条没完之前不生成单位")

	_tick_secs(w, 5.1)
	eq(g1.train_kind, "", "读条完毕：大格子空出来")
	ok(not g1.is_training(), "队列空了 → 不再是招募中")
	eq(w.retinue_of(g1.id).size(), before + 1, "★ 10 秒后生成了 1 个单位")

	var fresh = w.retinue_of(g1.id)[before]
	eq(fresh.kind, KIND, "生成的就是招募的那个兵种")
	eq(fresh.leader_id, g1.id, "新兵挂在将领名下")
	ok(w.map.terrain_walkable(fresh.tx, fresh.ty), "★ 新兵站在可通行格上")
	ok(fresh.pos.distance_to(g1.pos) <= 1.5,
		"★ 新兵生成在将领周围（距将领 %.2f 格）" % fresh.pos.distance_to(g1.pos))

	# ★★ 批次队列：中途加单不打断、也不延长读条；10 秒后**一起**生成。
	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一个")
	_tick_secs(w, 4.0)
	near(g1.train_remaining, 6.0, 0.1, "加单不会重置批次读条（还是同一批的剩余时间）")
	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一个（第二个进小格子）")
	near(g1.train_remaining, 6.0, 0.1, "★ 中途加单不延长读条")
	var evs: Array = _tick_collect(w, 6.1)
	# before = 函数开头；前面单批已经出了 1 个，所以这一批 2 个之后是 before + 3。
	eq(w.retinue_of(g1.id).size(), before + 3, "★ 读条结束一次性生成队列里全部 2 个单位")
	eq(g1.train_kind, "", "批次结束：大格子清空")
	eq(g1.train_queue.size(), 0, "批次结束：小格子清空")
	ok(not g1.is_training(), "队列空了 → 不再是招募中")
	eq(_count_events(evs, "unit_recruited"), 2, "★ 一次读条发 2 条 unit_recruited 事件")
	# 第一次加单的 recruit_queued 已被前面那 4 秒的 tick 收走，这里只看到第二次加单的那条。
	eq(_count_events(evs, "recruit_queued"), 1, "入队事件也照样交出来（命令事件不丢）")

	ok(w.start_recruit(KIND, g1.id, "p1"), "批次结束后再点一次 = 开始新的一批")
	near(g1.train_remaining, 10.0, 0.1, "★ 新批次重新读 10 秒")
	_tick_secs(w, 10.2)
	eq(w.retinue_of(g1.id).size(), before + 4, "新批次也正常出兵")

func _test_spawn_avoids_occupied_tile(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var tile := Vector2i(g1.tx, g1.ty)
	var center := GridRes.center_of(tile)

	g1.pos = center + Vector2(0.35, 0.0)
	g1.sync_tile(w.map)
	var squatter = w.retinue_of(g1.id)[0]
	squatter.pos = center
	squatter.sync_tile(w.map)
	var before: int = w.retinue_of(g1.id).size()

	ok(w.start_recruit(KIND, g1.id, "p1"), "入队成功")
	_tick_secs(w, 10.2)

	eq(w.retinue_of(g1.id).size(), before + 1, "生成了 1 个新兵")
	var fresh = w.retinue_of(g1.id)[before]
	ok(Vector2i(fresh.tx, fresh.ty) != Vector2i(squatter.tx, squatter.ty),
		"★ 新兵不会和占住格心的单位叠在同一格")
	ok(fresh.pos.distance_to(g1.pos) <= 1.5,
		"★ 新兵仍在将领周围（距将领 %.2f 格）" % fresh.pos.distance_to(g1.pos))
	ok(squatter.pos.distance_to(center) < 0.5,
		"★ 站在格心上的单位没有被无缘无故推开（它不在新兵的落点上）")

func _test_mobile_while_training(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var before: int = w.retinue_of(g1.id).size()
	var start: Vector2 = g1.pos

	ok(w.start_recruit(KIND, g1.id, "p1"), "入队成功")
	ok(not w.is_order_locked(g1), "★★ 招募不再锁住将领本人")
	ok(not w.is_order_locked(w.retinue_of(g1.id)[0]), "★★ 招募也不再锁住附属兵")

	var dest: Vector2 = start + Vector2(3.0, 0.0)
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g1.id],
		"x": dest.x, "y": dest.y, "faction": "p1"}),
		"★★ 招募期间 move 命令照样生效（可以边走边招）")
	_tick_secs(w, 1.2)
	ok(g1.pos.distance_to(start) > 0.2, "★★ 将领真的带兵走开了（不再被钉在原地）")
	ok(g1.is_training(), "★★ 移动期间读条没有被打断 / 取消")

	# 让这一单立刻读完：验证「在将领**当前**位置周围生成」。
	g1.train_remaining = 0.05
	_tick_secs(w, 0.2)
	eq(w.retinue_of(g1.id).size(), before + 1, "移动中也能读完并生成 1 个新兵")
	var fresh = w.retinue_of(g1.id)[before]
	ok(fresh.pos.distance_to(g1.pos) <= 1.5,
		"★★ 新兵生成在将领当前位置周围（距当前将领 %.2f 格）" % fresh.pos.distance_to(g1.pos))
	# ★★ 新兵不能一出生就脱队：它应当立刻接上将领当前的移动命令。
	ok(fresh.moving or fresh.has_goal, "★★ 新兵立刻继承将领的移动命令（不会站在原地脱队）")
	near(fresh.goal.distance_to(g1.goal), 0.0, 0.2,
		"★★ 新兵的行军目标 = 将领当前的 goal")

func _test_damage_pauses_training(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var before: int = w.retinue_of(g1.id).size()

	ok(w.start_recruit(KIND, g1.id, "p1"), "入队成功")
	_tick_secs(w, 2.0)
	var left: float = g1.train_remaining
	ok(left < 10.0 and left > 0.0, "（前提）已经读了一部分")

	# ★ 直接造成伤害：受击清零脱战计时 ⇒ 读条暂停（不清队列、不退款）。
	g1.take_damage(cfg, w, 5.0, null)
	eq(w.can_recruit(KIND, g1.id, "p1"), "combat", "★ 受击后「脱战」不成立，不能再下单")
	_tick_secs(w, 4.0)
	near(g1.train_remaining, left, 1e-4, "★★ 战斗中读条暂停（进度一点没涨）")
	eq(g1.train_queue_size(), 1, "★★ 暂停不会清队列")
	ok(g1.is_training(), "★★ 仍然在招募状态（只是暂停）")

	# 再站 6.2 秒（累计脱战 > 10 秒）⇒ 从暂停处继续。
	_tick_secs(w, 6.2)
	ok(g1.train_remaining < left - 1e-4, "★★ 脱战后从暂停处继续读条")
	eq(w.retinue_of(g1.id).size(), before, "（还没读完，先不生成）")
	_tick_secs(w, 10.0)
	eq(w.retinue_of(g1.id).size(), before + 1, "★ 脱战后这一单正常读完")

func _test_retinue_not_locked_while_training(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	_give(w, 1000.0, 1000.0)
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var mates: Array = w.retinue_of(g1.id)
	var other: Array = w.retinue_of(g2.id)
	ok(not mates.is_empty() and not other.is_empty(), "两个将领各带附属兵")

	var squad: Array = [g1.id]
	squad.append_array(_ids(mates))
	var far := GridRes.center_of(Vector2i(g1.tx, g1.ty + 5))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "先给整队下一条移动命令")
	ok(mates[0].moving, "附属兵确实在赶路")

	ok(w.start_recruit(KIND, g1.id, "p1"), "将领开始招募")
	ok(mates[0].moving and not mates[0].path.is_empty(),
		"★★ 招募一开始，附属兵**不会**被强制收队（旧行为已移除）")
	ok(not w.is_order_locked(g1), "★ 将领本人不再被锁")
	ok(not w.is_order_locked(mates[0]), "★★ 它辖下的部队也不再被锁")
	ok(not w.is_order_locked(other[0]), "别的将领的部队照旧不受影响")

	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★★ 整队的 move 命令照常接受")
	ok(CommandRes.apply(w, cfg, {"kind": "attack_move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★★ 整队的 attack_move 命令照常接受")
	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "order_rejected"), 0,
		"★★ 不会再出现「招募中拒令」的报错事件")
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [other[0].id],
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 别的将领的部队同样能下令")

	# 清空队列后一切照旧（没有「解锁」这个状态变化了，因为本来就没锁）。
	while g1.train_queue_size() > 0:
		w.cancel_recruit(g1.id, 0, "p1")
	ok(not w.is_order_locked(mates[0]), "★ 队列清空后仍然可指挥")
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 整队照常接受命令")

func _test_cancel_queue(cfg) -> void:
	var c = require_config()
	if c == null:
		return
	c.combat_enabled = false
	var other := _inject_second_kind(c)
	var w = require_world(c)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var g1 = _first_general(w)
	ok(g1 != null, "有开局将领")
	if g1 == null:
		return
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0

	var kf: float = _food_of(w, KIND)
	var of: float = _food_of(w, other)
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 1 单")
	ok(w.start_recruit(other, g1.id, "p1"), "排第 2 单")
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 3 单")
	near(float(w.resources["food"]), 1000.0 - (2.0 * kf + of), 1e-4, "三单共扣粮（长枪 ×2 + 二号）")
	eq(w.recruit_kind_at(g1, 0), KIND, "大格子里是第 1 单")
	eq(w.recruit_kind_at(g1, 1), other, "第 2 单在第 1 个小格")
	eq(w.recruit_kind_at(g1, 2), KIND, "第 3 单在第 2 个小格")
	eq(w.recruit_kind_at(g1, 3), "", "第 3 个小格是空的")

	ok(w.cancel_recruit(g1.id, 1, "p1"), "★ 取消第 2 格成功")
	near(float(w.resources["food"]), 1000.0 - 2.0 * kf, 1e-4, "★ 只退掉那一格（二号）的粮")
	near(float(z["population"]), 8.0, 1e-4, "★ 人口也退 1（退给同一个区划）")
	eq(g1.train_kind, KIND, "★ 正在读条的还是第 1 单（取消排队的不影响读条）")
	eq(g1.train_queue.size(), 1, "队列里只剩 1 个")
	eq(w.recruit_kind_at(g1, 1), KIND, "★ 原来在第 3 格的现在**前移**到第 1 小格")
	eq(w.recruit_kind_at(g1, 2), "", "后面空出来了")

	_tick_secs(w, 6.0)
	near(g1.train_remaining, 4.0, 0.1, "读了 6 秒（为下面验「不继承进度」做准备）")
	ok(w.cancel_recruit(g1.id, 0, "p1"), "★ 取消大格子成功")
	near(float(w.resources["food"]), 1000.0 - kf, 1e-4, "第 1 单的粮退回来了")
	eq(g1.train_kind, KIND, "★ 后面那一单前移进了大格子")
	near(g1.train_remaining, 4.0, 1e-6,
		"★ 取消单格**不重置**批次读条（还是原来的 4 秒剩余）")
	eq(g1.train_queue.size(), 0, "队列空了")
	ok(g1.is_training(), "★ 还在招（只是少了一个单位）")

	var before_units: int = w.retinue_of(g1.id).size()
	_tick_secs(w, 10.2)
	eq(w.retinue_of(g1.id).size(), before_units + 1, "★ 被取消的两单永远不会生成")

	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一单")
	ok(w.cancel_recruit(g1.id, 0, "p1"), "把它也取消")
	ok(not g1.is_training(), "★ 队列空了 → 不再是「招募中」（将领恢复能动）")
	ok(CommandRes.apply(w, c, {"kind": "move", "ids": [g1.id],
		"x": float(g1.tx), "y": float(g1.ty + 2), "faction": "p1"}),
		"★ 取消掉最后一单之后又能接受 move 命令了")

	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一单（下面要验被拒时不退钱）")
	var food_before: float = float(w.resources["food"])
	ok(not w.cancel_recruit(g1.id, 3, "p1"), "★ 空格子（第 3 小格）点了不做事")
	ok(not w.cancel_recruit(g1.id, 99, "p1"), "越界的格号被拒")
	ok(not w.cancel_recruit(g1.id, -1, "p1"), "负数格号被拒")
	ok(not w.cancel_recruit("general-99", 0, "p1"), "队长不存在的取消被拒")
	ok(not w.cancel_recruit(g1.id, 0, FactionRes.NPC_FACTION),
		"★ 防冒充：别的阵营不能取消我方将领的招募")
	near(float(w.resources["food"]), food_before, 1e-6, "★ 被拒的取消一分钱都不退")
	eq(g1.train_queue_size(), 1, "被拒的取消也不会动队列")

	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "recruit_cancel_rejected"), 5,
		"★ 被拒的取消各发一条带拒因的事件（空格子 / 越界 ×2 / 队长不存在 / 防冒充）")
	eq(_count_reason(evts, "recruit_cancelled", "cancelled"), 1,
		"（这一帧只交出了之前那次**成功**取消的事件）")

func _test_recruit_eta(cfg) -> void:
	var c = require_config()
	if c == null:
		return
	c.combat_enabled = false
	var slow_kind := "testkind_slow"
	(c.get_path_value("recruit.list") as Array).append({
		"kind": slow_kind, "label": "慢兵", "short": "慢",
		"train_sec": 25, "population_cost": 1, "cost": {"food": 10, "gold": 10},
	})
	var w = require_world(c)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var g1 = _first_general(w)
	ok(g1 != null, "有开局将领")
	if g1 == null:
		return
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0

	near(w.recruit_eta(g1, 0), 0.0, 1e-6, "没在招募时 ETA 是 0")
	near(w.recruit_eta(null, 0), 0.0, 1e-6, "null 将领也返回 0（视图不必先判空）")
	near(w.recruit_eta(g1, -1), 0.0, 1e-6, "负数格号返回 0")

	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 1 单（长枪兵）")
	ok(w.start_recruit(slow_kind, g1.id, "p1"), "排第 2 单（慢兵）")
	# ★★ 批次队列：所有单位在同一条 10 秒读条结束时一起出来。
	near(w.recruit_eta(g1, 0), 10.0, 1e-6, "★ 大格子 = 批次剩余秒（10）")
	near(w.recruit_eta(g1, 1), 10.0, 1e-6,
		"★ 第 1 小格也是同一批的剩余秒（不按兵种 train_sec 累加）")
	near(w.recruit_eta(g1, 2), 0.0, 1e-6, "空槽位是 0")
	near(w.recruit_eta(g1, 4), 0.0, 1e-6, "最后一格空着也是 0")

	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 3 单（长枪兵）")
	near(w.recruit_eta(g1, 1), 10.0, 1e-6, "加单不延长批次：ETA 仍是最初的 10")
	near(w.recruit_eta(g1, 2), 10.0, 1e-6, "★ 第 2 小格同样是同一批剩余秒")

	_tick_secs(w, 4.0)
	near(w.recruit_eta(g1, 0), 6.0, 0.05, "读了 4 秒 → 大格子还剩 6 秒")
	near(w.recruit_eta(g1, 1), 6.0, 0.05, "★ 第 1 小格跟着缩到 6（同一批）")
	near(w.recruit_eta(g1, 2), 6.0, 0.05, "★ 第 2 小格也跟着缩到 6")

	ok(w.cancel_recruit(g1.id, 0, "p1"), "取消大格子（长枪兵）")
	eq(g1.train_kind, slow_kind, "（前提）慢兵前移进了大格子")
	near(w.recruit_eta(g1, 0), 6.0, 0.05, "★ 前移不重置批次：仍是原来的 6 秒")
	eq(w.recruit_kind_at(g1, 1), KIND, "（前提）原来第 2 小格的长枪兵前移到第 1 小格")
	near(w.recruit_eta(g1, 1), 6.0, 0.05, "★ 前移之后所有格子的 ETA 仍是 6")
	near(w.recruit_eta(g1, 2), 0.0, 1e-6, "后面那格空出来了")

	while g1.train_queue_size() > 0:
		w.cancel_recruit(g1.id, 0, "p1")
	near(w.recruit_eta(g1, 0), 0.0, 1e-6, "收尾：队列空了 → ETA 全 0")

func _test_cancel_then_death(cfg) -> void:
	var w = _quiet_world(cfg)
	_no_income(w)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	var kf: float = _food_of(w, KIND)

	w.start_recruit(KIND, g1.id, "p1")
	w.start_recruit(KIND, g1.id, "p1")
	near(float(w.resources["food"]), food0 - 2.0 * kf, 1e-4, "两单共扣粮（×2）")
	ok(w.cancel_recruit(g1.id, 1, "p1"), "取消排队的第 2 单（先退一单）")
	near(float(w.resources["food"]), food0 - kf, 1e-4, "这时只花了一单")

	var evts: Array = _kill_leader_keep_queue(cfg, w, g1)
	evts.append_array(w.tick(DT))
	near(float(w.resources["food"]), food0, 1e-4, "★ 阵亡后退还**剩下一单**的 60（不是 120）")
	near(float(w.resources["gold"]), gold0, 1e-4, "★ 黄金同理（不会重复退已取消的那单）")
	near(float(z["population"]), 10.0, 1e-4, "★ 人口也是刚好退满（不会多退）")
	eq(_count_reason(evts, "recruit_cancelled", "leader_died"), 1,
		"阵亡只发一条整队作废的事件（之前那次手动取消是另一条，reason 不同）")
	ok(not g1.alive, "★ 将领确实阵亡了")

func _test_death_refund(cfg) -> void:
	var w = _quiet_world(cfg)
	_no_income(w)                             # 这一节要对账，别让区划产出的资源掺进来
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])

	ok(w.start_recruit(KIND, g1.id, "p1"), "排第一个")
	_tick_secs(w, 3.0)
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第二个")
	near(float(w.resources["food"]), food0 - 2.0 * _food_of(w, KIND), 1e-4, "两单共扣粮（×2）")
	near(float(z["population"]), 8.0, 1e-4, "两单共扣 2 人口")

	var evts: Array = _kill_leader_keep_queue(cfg, w, g1)
	evts.append_array(w.tick(DT))
	ok(not g1.alive, "将领已阵亡")

	ok(w.unit_by_id(g1.id) == null, "阵亡的将领被摘出世界（按 id 查不到它了）")
	near(float(w.resources["food"]), food0, 1e-4, "★ 阵亡后退还全部粮食")
	near(float(w.resources["gold"]), gold0, 1e-4, "★ 阵亡后退还全部黄金")
	near(float(z["population"]), 10.0, 1e-4, "★ 阵亡后退还全部人口")
	ok(w.retinue_of(g1.id).size() <= ESCORTS_PER_GENERAL,
		"★ 队列作废：**没有**偷偷生成新兵（名下数量不超过开局摆的那 %d 个）" % ESCORTS_PER_GENERAL)

	var cancelled := 0
	for e in evts:
		if String(e.get("type", "")) == "recruit_cancelled":
			cancelled += 1
	eq(cancelled, 1, "★ 发一条 recruit_cancelled 事件（带退款额）")
	_tick_secs(w, 1.0)
	near(float(w.resources["food"]), food0, 1e-4, "退款不会重复发（再跑一秒数字不动）")

func _test_snapshot_round_trip(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	w.start_recruit(KIND, g1.id, "p1")
	w.start_recruit(KIND, g1.id, "p1")
	_tick_secs(w, 2.0)

	var snap = SnapshotRes.to_snapshot(w)
	var su: Dictionary = {}
	for s in (snap["units"] as Array):
		var entry: Dictionary = s
		if String(entry.get("i", "")) == g1.id:
			su = entry
	eq(String(su.get("tk", "")), KIND, "★ 快照带着「正在读条的兵种」")
	ok(float(su.get("tr", 0.0)) > 0.0, "★ 快照带着剩余秒数")
	ok(typeof(su.get("tq", null)) == TYPE_ARRAY and (su["tq"] as Array).size() == 1,
		"★ 快照带着排队的那一个（tq）")

	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var g2 = w2.unit_by_id(g1.id)
	ok(g2 != null, "客机侧有同一个将领")
	if g2 != null:
		eq(g2.train_kind, KIND, "★ 应用快照后队列跟着过来")
		ok(g2.is_training(), "客机侧也处于「招募中」")
		near(g2.train_remaining, g1.train_remaining, 0.02, "剩余秒数对齐")
		eq(g2.train_queue.size(), 1, "排队的那一个也过来了")
		v2_near(g2.train_anchor, g2.pos, 1e-6, "历史字段 train_anchor 取权威位置（不再参与位移）")

	var w3 = _quiet_world(cfg)
	var g3 = _first_general(w3)
	ok(g3 != null, "（快照）有将领")
	if g3 == null:
		return
	_give(w3, 1000.0, 1000.0)
	w3.zones.zone_at(g3.tx, g3.ty)["population"] = 10.0
	w3.start_recruit(KIND, g3.id, "p1")
	var old_snap := {"units": [{"i": g3.id, "f": "p1", "k": "general", "x": g3.pos.x, "y": g3.pos.y}],
		"buildings": []}
	SnapshotRes.apply_snapshot(w3, cfg, old_snap)
	eq(g3.train_kind, KIND, "★ 老快照没有 tk → 保持本地队列不变（别当成空队列）")

func _test_population_cap_and_recruit(cfg) -> void:
	var w = _quiet_world(cfg)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)
	ok(z != null, "将领站的那个区划找得到")
	if z == null:
		return
	z["owner"] = "p1"
	z["population_cap"] = 3.0
	z["population"] = 0.0
	z["production"] = {"food": 0.0, "gold": 0.0, "population": 50.0}

	w.tick(1.0)
	near(w.zones.population_of(z), 3.0, 1e-6, "★ 人口涨到上限 3 就停住")
	w.tick(2.0)
	near(w.zones.population_of(z), 3.0, 1e-6, "继续跑时间也不会超过上限")

	ok(w.start_recruit(KIND, g1.id, "p1"), "人口满的时候可以招募")
	near(w.zones.population_of(z), 2.0, 1e-4, "★ 招募扣掉将领所在区块 1 人口")
	w.tick(1.0)
	near(w.zones.population_of(z), 3.0, 1e-6, "★ 扣掉的那 1 人口会涨回来，但仍停在上限")

	z["population_cap"] = 0.0
	z["population"] = 0.0
	eq(w.can_afford_recruit(KIND, g1.id), "population",
		"★ 上限 0 的区块招不了（人口不足）")

func _quiet_world(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world_with_escorts(c, ESCORTS_PER_GENERAL)

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _food_of(w, kind: String) -> float:
	return float((w.recruit_cost(kind) as Dictionary).get("food", 0.0))

func _gold_of(w, kind: String) -> float:
	return float((w.recruit_cost(kind) as Dictionary).get("gold", 0.0))

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	w.base_bonus_enabled = false
	w.refresh_zone_production()

func _kill_leader_keep_queue(cfg, w, leader) -> Array:
	var evts: Array = []
	for m in w.retinue_of(String(leader.id), true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	evts.append_array(w.tick(1.0 / 60.0))     # 收尸：活兵清零（队列还在 → 它进濒死）
	leader.die_now(cfg, w, "test_kill")
	evts.append_array(w.tick(1.0 / 60.0))     # 世界把阵亡的它摘出去 + 队列作废退款
	return evts

func _foreign_tile(w, my_faction: String) -> Vector2i:
	for ty in w.map.rows:
		for tx in w.map.cols:
			var z = w.zones.zone_at(tx, ty)
			if z == null:
				continue
			if FactionRes.same_side(String(z["owner"]), my_faction):
				continue
			if not w.map.terrain_walkable(tx, ty):
				continue
			if w.building_at(tx, ty) != null:
				continue
			return Vector2i(tx, ty)
	return Vector2i(-1, -1)

func _ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(u.id)
	return out

func _inject_second_kind(cfg) -> String:
	var list = cfg.get_path_value("recruit.list")
	(list as Array).append({
		"kind": "testkind2", "label": "二号占位", "short": "贰",
		"train_sec": 10, "population_cost": 1, "cost": {"food": 50, "gold": 50},
	})
	return "testkind2"

## 取世界里第 idx 位将领（按 id 排序）。默认地图开局将领是 `general-0`，
## 不能硬编码 `general-1` —— 那是「带附属兵的探针关卡」才有的 id。
func _first_general(w, idx: int = 0):
	var gs: Array = []
	for u in w.units:
		if u.is_general():
			gs.append(u)
	gs.sort_custom(func(a, b) -> bool: return String(a.id) < String(b.id))
	if idx < 0 or idx >= gs.size():
		return null
	return gs[idx]

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

func _count_reason(events: Array, type_name: String, reason: String) -> int:
	var n := 0
	for e in events:
		if String(e.get("type", "")) == type_name and String(e.get("reason", "")) == reason:
			n += 1
	return n

func _last_reject_reason(events: Array) -> String:
	var reason := ""
	for e in events:
		if String(e.get("type", "")) == "recruit_rejected":
			reason = String(e.get("reason", ""))
	return reason
