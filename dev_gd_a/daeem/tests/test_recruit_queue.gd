## test_recruit_queue.gd —— 招募队列（将领 = 兵营）
##
## 需求原话（这一套断言的来源）：
##   「为将领招募单位增加消耗：每个单位消耗 50 粮食 50 黄金，同时消耗招募将领的单位
##     所在地的 1 人口，招募时间为 10 秒；招募的表现类似星际争霸 —— 当将领开始招募时，
##     其信息栏内出现五个格子（一个大的、四个小的，代表最多五个单位进入招募队列，
##     正在招募的单位在大格子中显示），同时开始读条；读条完毕后在将领所在格内生成
##     该单位（强制生成在中心，若中心有单位则将中心内的单位排开）」
##   「增加限制条件：将领只能在己方区划内招募单位」
## 手玩补充的两条：
##   「开始招募后将领固定在原地无法行动且无法攻击」
##   「将领阵亡时队列作废，但已扣的粮食 / 黄金 / 人口要退还」
##
## ★ 扣费时机 = **入队即扣**（与星际争霸一致）：否则「排队不要钱」，
##   队列上限（5 个）就失去意义了。
## ★ 生成的**位置**是权威逻辑（格心），所以断言直接对着 pos 与 tile 写。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0
const KIND := "subordinate"


func _initialize() -> void:
	_case_name = "test_recruit_queue"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_zone_restriction(cfg)
	_test_enqueue_pays(cfg)
	_test_reject_reasons(cfg)
	_test_queue_cap(cfg)
	_test_train_timing_and_center_spawn(cfg)
	_test_push_units_aside(cfg)
	_test_rooted_while_training(cfg)
	_test_retinue_locked_while_training(cfg)
	_test_cancel_queue(cfg)
	_test_cancel_then_death(cfg)
	_test_death_refund(cfg)
	_test_population_cap_and_recruit(cfg)
	_test_snapshot_round_trip(cfg)


# ------------------------------------------------------------------
# 一、数值表来自 config.json（代码里不写字面量）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = WorldRes.create(cfg)
	ok(w.is_recruitable(KIND), "config.recruit.list 里亲兵可招募")
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")
	eq(w.recruit_queue_max(), 5, "★ 队列上限 5 个（1 大格 + 4 小格）")
	near(w.recruit_train_sec(KIND), 10.0, 1e-6, "★ 每个单位读条 10 秒")
	near(float(w.recruit_population_cost(KIND)), 1.0, 1e-6, "★ 每个单位吃 1 人口")
	var cost: Dictionary = w.recruit_cost(KIND)
	near(float(cost.get("food", 0.0)), 50.0, 1e-6, "★ 每个单位 50 粮食")
	near(float(cost.get("gold", 0.0)), 50.0, 1e-6, "★ 每个单位 50 黄金")
	eq(w.recruit_short_of(KIND), "兵", "信息栏格子里用 config 的 short（兵）")


# ------------------------------------------------------------------
# 二、只能在己方区划内招募
# ------------------------------------------------------------------
func _test_zone_restriction(cfg) -> void:
	var w = WorldRes.create(cfg)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	ok(g1 != null, "有 general-1")
	if g1 == null:
		return

	eq(w.can_recruit(KIND, g1.id, "p1"), "", "★ 将领站在己方区划里 → 可以招募")
	ok(w.leader_zone_owned(g1), "将领所在区划归它那一方（大本营把出生区划收归己方）")

	# 挪到一个**别人的**区划：随便挑一格不属于 p1 的可通行地
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

	# 把这块地划给己方 → 又能招了（证明判据是「区划归属」而不是「哪一块地」）
	var z = w.zones.zone_at(g1.tx, g1.ty)
	if z != null:
		z["owner"] = "p1"
		eq(w.can_recruit(KIND, g1.id, "p1"), "", "★ 那块地归己方之后就能招募了")


# ------------------------------------------------------------------
# 三、入队即扣费（粮食 / 黄金 / 区划人口）
# ------------------------------------------------------------------
func _test_enqueue_pays(cfg) -> void:
	var w = WorldRes.create(cfg)
	_give(w, 200.0, 200.0)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 5.0
	var before_subs: int = w.retinue_of(g1.id).size()

	ok(w.start_recruit(KIND, g1.id, "p1"), "招募入队成功")
	near(float(w.resources["food"]), 150.0, 1e-4, "★ 入队即扣 50 粮食")
	near(float(w.resources["gold"]), 150.0, 1e-4, "★ 入队即扣 50 黄金")
	near(float(z["population"]), 4.0, 1e-4, "★ 入队即扣 1 人口（从将领所在区划扣）")

	# 队列的形态：大格子里是正在读条的
	eq(g1.train_kind, KIND, "★ 大格子里是刚排进来的那个")
	near(g1.train_total, 10.0, 1e-6, "大格子记录了总读条时间 10 秒")
	near(g1.train_remaining, 10.0, 1e-6, "刚入队时剩余 = 10 秒")
	eq(g1.train_queue.size(), 0, "小格子里还没有排队的")
	eq(g1.train_queue_size(), 1, "队列里一共 1 个")
	ok(g1.is_training(), "★ 将领进入「招募中」状态")
	near(g1.train_progress(), 0.0, 1e-6, "刚入队时进度是 0")
	eq(w.retinue_of(g1.id).size(), before_subs, "★ 入队**不会立刻生成单位**（要读条 10 秒）")
	eq(w.recruit_queue_max(), 5, "上限仍然是 5")
	eq(g1.train_anchor, g1.pos, "★ 记住开招那一刻的位置（读条期间钉在这里）")

	# 第二个进小格子，不再重复占用大格子
	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一个也成功")
	eq(g1.train_queue.size(), 1, "第二个排进小格子")
	eq(g1.train_queue_size(), 2, "队列里一共 2 个")
	near(g1.train_remaining, 10.0, 1e-6, "★ 正在读条的还是第一个（排队的不会抢读条）")


# ------------------------------------------------------------------
# 四、拒因：钱 / 人口 / 队长
# ------------------------------------------------------------------
func _test_reject_reasons(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)

	# 开局资源是 0：钱不够
	eq(w.can_afford_recruit(KIND, g1.id), "cost", "★ 没钱 → 拒因 cost")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "没钱时招募被拒")
	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "recruit_rejected"), 1,
		"被拒会发一条 recruit_rejected 事件（界面靠它显示原因）")
	eq(_last_reject_reason(evts), "cost", "事件里带拒因码 cost")

	# 钱够了但人口不够
	_give(w, 1000.0, 1000.0)
	z["population"] = 0.5
	eq(w.can_afford_recruit(KIND, g1.id), "population", "★ 人口不足 → 拒因 population")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "人口不足时招募被拒")
	eq(g1.train_queue_size(), 0, "被拒的招募不会进队列")

	# 人口够了就能招
	z["population"] = 1.0
	eq(w.can_afford_recruit(KIND, g1.id), "", "人口够 → 可以招")
	ok(w.start_recruit(KIND, g1.id, "p1"), "这次入队成功")

	# 队长不存在 / 不是队长 / 别的阵营
	_leader_reject_checks(cfg)


## （拆出来只是为了让上面那段读起来像规则本身）
func _leader_reject_checks(cfg) -> void:
	var w = WorldRes.create(cfg)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	var sub = w.retinue_of(g1.id)[0]
	eq(w.can_recruit(KIND, "general-99", "p1"), "leader", "队长不存在 → leader")
	eq(w.can_recruit(KIND, sub.id, "p1"), "leader", "★ 亲兵不是队长，不能往它名下招兵")
	eq(w.can_recruit(KIND, g1.id, FactionRes.NPC_FACTION), "faction",
		"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")
	ok(not w.start_recruit(KIND, sub.id, "p1"), "往亲兵名下招募被拒")


# ------------------------------------------------------------------
# 五、队列上限 5（1 正在读条 + 4 排队）
# ------------------------------------------------------------------
func _test_queue_cap(cfg) -> void:
	var w = WorldRes.create(cfg)
	_give(w, 10000.0, 10000.0)
	var g1 = w.unit_by_id("general-1")
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


# ------------------------------------------------------------------
# 六、读条 10 秒 + **强制生成在格心**
# ------------------------------------------------------------------
func _test_train_timing_and_center_spawn(cfg) -> void:
	var w = _quiet_world(cfg)          # 关战斗：这一节只验读条与落点
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var before: int = w.retinue_of(g1.id).size()

	# ★ 把将领挪到「自己的格子里、但不在格心」的位置：这样新兵落在**格心**才看得出来
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
	v2i_eq(Vector2i(fresh.tx, fresh.ty), tile, "★ 生成在**将领所在那一格**")
	v2_near(fresh.pos, GridRes.center_of(tile), 1e-4, "★ 强制生成在格心")
	ok(w.map.terrain_walkable(fresh.tx, fresh.ty), "新兵站在可通行格上")

	# 队列排序：第一个读完之后，第二个才开始读 —— 顺便验「完成事件」
	ok(w.start_recruit(KIND, g1.id, "p1"), "再排两个")
	ok(w.start_recruit(KIND, g1.id, "p1"), "（第二个进小格子）")
	var evs: Array = _tick_collect(w, 10.1)
	eq(w.retinue_of(g1.id).size(), before + 2, "★ 10 秒只完成一个（排队的不抢读条）")
	near(g1.train_remaining, 10.0, 0.2, "第二个这时才刚开始读条")
	eq(_count_events(evs, "unit_recruited"), 1, "★ 读条完成发一条 unit_recruited 事件")
	eq(_count_events(evs, "recruit_queued"), 2, "入队事件也照样交出来（命令事件不丢）")

	_tick_secs(w, 10.2)
	eq(w.retinue_of(g1.id).size(), before + 3, "第三个也生成了")


# ------------------------------------------------------------------
# 七、格心上有单位 → 把它排开
# ------------------------------------------------------------------
func _test_push_units_aside(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var tile := Vector2i(g1.tx, g1.ty)
	var center := GridRes.center_of(tile)

	# 将领让开半格（还在自己那一格里），把一个亲兵正好放在格心上
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
	v2_near(fresh.pos, center, 1e-4, "★ 新兵占住了格心")
	var need: float = cfg.unit_collision_radius * 2.0
	ok(squatter.pos.distance_to(center) >= need - 1e-6,
		"★ 原本站在格心上的单位被排开了（现在离格心 %.3f 格）" % squatter.pos.distance_to(center))
	v2i_eq(Vector2i(squatter.tx, squatter.ty), tile, "被排开的单位还在同一格里（只是让开了格心）")


# ------------------------------------------------------------------
# 八、读条期间：钉在原地、无法行动、无法攻击
# ------------------------------------------------------------------
func _test_rooted_while_training(cfg) -> void:
	var w = WorldRes.create(cfg)              # 这一节要**开着战斗**（验「无法攻击」）
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0

	ok(w.start_recruit(KIND, g1.id, "p1"), "入队成功")
	# 隔离：只留这个将领，再在旁边放一个驻守的敌人当靶子
	w.units = [g1]
	var foe = w.spawn_enemy(g1.tx + 1, g1.ty)
	ok(foe != null, "旁边刷一个敌人")
	if foe == null:
		return
	foe.hold_position = true                 # 别让它跑去打大本营
	var anchor: Vector2 = g1.train_anchor

	# 命令层：招募中的将领不接受 move / attack
	ok(not CommandRes.apply(w, cfg, {"kind": "move", "ids": [g1.id],
		"x": float(g1.tx + 5), "y": float(g1.ty), "faction": "p1"}),
		"★ 招募期间 move 命令不生效")
	ok(not CommandRes.apply(w, cfg, {"kind": "attack", "ids": [g1.id],
		"target_id": foe.id, "faction": "p1"}),
		"★ 招募期间 attack 命令不生效")
	ok(not g1.moving and g1.path.is_empty(), "将领没有被命令带走")

	_tick_secs(w, 3.0)
	v2_near(g1.pos, anchor, 1e-6, "★ 招募期间位置一动不动（碰撞推挤也推不走）")
	ok(g1.target == null and g1.target_building == null, "★ 招募期间不索敌、不还手")
	ok(g1.hp < g1.hp_max, "旁边那个敌人确实在打它（所以「不还手」是有意义的断言）")
	eq(g1.train_kind, KIND, "读条还在继续（没有被打断）")

	# 读条结束之后恢复行动能力
	_tick_secs(w, 8.0)
	ok(not g1.is_training(), "读条结束了")
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g1.id],
		"x": float(g1.tx), "y": float(g1.ty + 2), "faction": "p1"}),
		"★ 读条结束后又能接受 move 命令了")


# ------------------------------------------------------------------
# 九、招募期间**整队**不接受指令：将领与它辖下的部队只警戒
#
# 需求原话：「玩家无法为正在招募单位的将领及其附属队列发布任何指令（移动/攻击），
#            其附属单位只会执行警戒逻辑」。
# 这一节盯四条：
#   1. 锁的是**一整队**（将领本人 + 它名下的亲兵），不是只有将领；
#   2. 别的将领的部队**不受影响**（锁的是那一队，不是全场）；
#   3. 已经开始执行的旧命令要**收队**（「只会执行警戒逻辑」不能带着旧路走）；
#   4. 「只警戒」不是「发呆」：靠近的敌人照样会打；而且队列一取消就解锁。
# ------------------------------------------------------------------
func _test_retinue_locked_while_training(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	_give(w, 1000.0, 1000.0)
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var mates: Array = w.retinue_of(g1.id)
	var other: Array = w.retinue_of(g2.id)
	ok(not mates.is_empty() and not other.is_empty(), "两个将领各带亲兵")

	# ---- 先给整队下一条移动命令（验证招募一开始会「收队」）----
	var squad: Array = [g1.id]
	squad.append_array(_ids(mates))
	var far := GridRes.center_of(Vector2i(g1.tx, g1.ty + 5))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "先给整队下一条移动命令")
	ok(mates[0].moving, "亲兵确实在赶路")

	# ---- 开始招募：整队被锁 + 旧命令收队 ----
	ok(w.start_recruit(KIND, g1.id, "p1"), "将领开始招募")
	ok(not mates[0].moving and mates[0].path.is_empty(),
		"★ 招募一开始，亲兵就**收队**（不再执行旧命令）")
	ok(w.is_order_locked(g1), "将领自己被锁住")
	ok(w.is_order_locked(mates[0]), "★ 它辖下的部队也被锁住")
	ok(not w.is_order_locked(other[0]), "别的将领的部队不受影响")

	# ---- 三条指令（move / attack_move / attack）全被拒 ----
	ok(not CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 整队的 move 命令被拒")
	ok(not CommandRes.apply(w, cfg, {"kind": "attack_move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 整队的 attack_move 命令被拒")
	var foe = w.spawn_enemy(g1.tx + 2, g1.ty)
	if foe != null:
		foe.hold_position = true                   # 别让它跑掉
		ok(not CommandRes.apply(w, cfg, {"kind": "attack", "ids": squad,
			"target_id": foe.id, "faction": "p1"}), "★ 整队的 attack 命令被拒")
	ok(not mates[0].moving and mates[0].path.is_empty(), "被拒之后亲兵还是原地待命")
	ok(mates[0].ordered_target == null and not mates[0].has_attack_move, "也没有留下玩家命令")

	# 界面靠事件显示「这会儿不接受指令」
	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "order_rejected"), 3, "★ 每条被拒的指令都发一条 order_rejected 事件")

	# ---- 锁的是「那一队」：别的将领的部队照旧能下令 ----
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [other[0].id],
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 别的将领的部队照旧能下令")

	# ---- 「只警戒」不是「发呆」：靠近的敌人照样打 ----
	if foe != null:
		for _i in 120:
			w.tick(DT)
		ok(foe.hp < foe.hp_max, "★ 亲兵仍然执行警戒逻辑（自己上去打了，敌人掉了血）")
		ok(g1.target == null, "★ 将领本人还是不动手（读条期间无法攻击）")

	# ---- 取消掉最后一单 → 立刻解锁 ----
	while g1.train_queue_size() > 0:
		w.cancel_recruit(g1.id, 0, "p1")
	ok(not w.is_order_locked(mates[0]), "★ 队列清空之后部队解锁")
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": squad,
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 解锁之后整队又能接受 move 命令")


# ------------------------------------------------------------------
# 十、取消某一格（点信息栏里的格子）：全额退款 + 后方的队列前移
#
# 需求原话：「点击对应的格子取消对应格子上的造兵队列，其后方的造兵队列前移」。
# ★ 为了验「前移」是真的前移（而不是只少了一个），这一节临时往可招募表里
#   加**第二个兵种**：队列变成「亲兵 / 二号 / 亲兵」之后，取消中间那个就能看出
#   谁补了上来。recruit.list 是**每次现读** cfg.data 的，所以这里改得动
#   （那些载入时算好的标量才改不动，见 architecture.md 第一节第 7 条）。
# ------------------------------------------------------------------
func _test_cancel_queue(cfg) -> void:
	var c = require_config()
	if c == null:
		return
	c.combat_enabled = false
	var other := _inject_second_kind(c)
	var w = WorldRes.create(c)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0

	# 排三单：大格子 = 亲兵，两个小格子 = 二号 / 亲兵
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 1 单")
	ok(w.start_recruit(other, g1.id, "p1"), "排第 2 单")
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第 3 单")
	near(float(w.resources["food"]), 850.0, 1e-4, "三单共扣 150 粮食")
	eq(w.recruit_kind_at(g1, 0), KIND, "大格子里是第 1 单")
	eq(w.recruit_kind_at(g1, 1), other, "第 2 单在第 1 个小格")
	eq(w.recruit_kind_at(g1, 2), KIND, "第 3 单在第 2 个小格")
	eq(w.recruit_kind_at(g1, 3), "", "第 3 个小格是空的")

	# ---- 取消**排队的**那一格：只退它，后面的前移 ----
	ok(w.cancel_recruit(g1.id, 1, "p1"), "★ 取消第 2 格成功")
	near(float(w.resources["food"]), 900.0, 1e-4, "★ 只退掉那一格的 50 粮食")
	near(float(z["population"]), 8.0, 1e-4, "★ 人口也退 1（退给同一个区划）")
	eq(g1.train_kind, KIND, "★ 正在读条的还是第 1 单（取消排队的不影响读条）")
	eq(g1.train_queue.size(), 1, "队列里只剩 1 个")
	eq(w.recruit_kind_at(g1, 1), KIND, "★ 原来在第 3 格的现在**前移**到第 1 小格")
	eq(w.recruit_kind_at(g1, 2), "", "后面空出来了")

	# ---- 取消**正在读条**的那一格：下一个前移，而且从头读条 ----
	_tick_secs(w, 6.0)
	near(g1.train_remaining, 4.0, 0.1, "读了 6 秒（为下面验「不继承进度」做准备）")
	ok(w.cancel_recruit(g1.id, 0, "p1"), "★ 取消大格子成功")
	near(float(w.resources["food"]), 950.0, 1e-4, "第 1 单的 50 粮食退回来了")
	eq(g1.train_kind, KIND, "★ 后面那一单前移进了大格子")
	near(g1.train_remaining, 10.0, 1e-6,
		"★ 前移的那个**从头读条**（不继承被取消那单的进度）")
	eq(g1.train_queue.size(), 0, "队列空了")
	ok(g1.is_training(), "★ 还在招（只是换了一单）")

	# 读条走完：只有「没被取消的那一单」会生成
	var before_units: int = w.retinue_of(g1.id).size()
	_tick_secs(w, 10.2)
	eq(w.retinue_of(g1.id).size(), before_units + 1, "★ 被取消的两单永远不会生成")

	# ---- 全部取消之后，将领恢复行动能力 ----
	ok(w.start_recruit(KIND, g1.id, "p1"), "再排一单")
	ok(w.cancel_recruit(g1.id, 0, "p1"), "把它也取消")
	ok(not g1.is_training(), "★ 队列空了 → 不再是「招募中」（将领恢复能动）")
	ok(CommandRes.apply(w, c, {"kind": "move", "ids": [g1.id],
		"x": float(g1.tx), "y": float(g1.ty + 2), "faction": "p1"}),
		"★ 取消掉最后一单之后又能接受 move 命令了")

	# ---- 空格子 / 越界 / 别人的将领：一律被拒，且一分钱不退 ----
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


# ------------------------------------------------------------------
# 十一、取消之后再阵亡：只退**还没取消的**那些（不能重复退）
# ------------------------------------------------------------------
func _test_cancel_then_death(cfg) -> void:
	var w = _quiet_world(cfg)
	_no_income(w)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])

	w.start_recruit(KIND, g1.id, "p1")
	w.start_recruit(KIND, g1.id, "p1")
	near(float(w.resources["food"]), food0 - 100.0, 1e-4, "两单共扣 100 粮食")
	ok(w.cancel_recruit(g1.id, 1, "p1"), "取消排队的第 2 单（先退 50）")
	near(float(w.resources["food"]), food0 - 50.0, 1e-4, "这时只花了 50")

	g1.take_damage(cfg, w, 99999.0, null)
	var evts: Array = w.tick(DT)
	near(float(w.resources["food"]), food0, 1e-4, "★ 阵亡后退还**剩下一单**的 50（不是 100）")
	near(float(w.resources["gold"]), gold0, 1e-4, "★ 黄金同理（不会重复退已取消的那单）")
	near(float(z["population"]), 10.0, 1e-4, "★ 人口也是刚好退满（不会多退）")
	eq(_count_reason(evts, "recruit_cancelled", "leader_died"), 1,
		"阵亡只发一条整队作废的事件（之前那次手动取消是另一条，reason 不同）")


# ------------------------------------------------------------------
# 十二、将领阵亡：队列作废 + 退还粮食 / 黄金 / 人口
# ------------------------------------------------------------------
func _test_death_refund(cfg) -> void:
	var w = _quiet_world(cfg)
	_no_income(w)                             # 这一节要对账，别让区划产出的资源掺进来
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 10.0
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	var units0: int = w.units.size()

	ok(w.start_recruit(KIND, g1.id, "p1"), "排第一个")
	_tick_secs(w, 3.0)                        # 读条到一半（退款要退**整队**）
	ok(w.start_recruit(KIND, g1.id, "p1"), "排第二个")
	near(float(w.resources["food"]), food0 - 100.0, 1e-4, "两单共扣 100 粮食")
	near(float(z["population"]), 8.0, 1e-4, "两单共扣 2 人口")

	g1.take_damage(cfg, w, 99999.0, null)
	ok(not g1.alive, "将领已阵亡")
	var evts: Array = w.tick(DT)

	near(float(w.resources["food"]), food0, 1e-4, "★ 阵亡后退还全部粮食")
	near(float(w.resources["gold"]), gold0, 1e-4, "★ 阵亡后退还全部黄金")
	near(float(z["population"]), 10.0, 1e-4, "★ 阵亡后退还全部人口")
	eq(w.units.size(), units0 - 1, "阵亡的将领被摘出世界")
	eq(w.retinue_of(g1.id).size(), int(cfg.num("unit.subordinate.count", 0.0)),
		"★ 队列作废：**没有**偷偷生成新兵")

	var cancelled := 0
	for e in evts:
		if String(e.get("type", "")) == "recruit_cancelled":
			cancelled += 1
	eq(cancelled, 1, "★ 发一条 recruit_cancelled 事件（带退款额）")
	# 退款只退一次：再跑几帧不会重复退
	_tick_secs(w, 1.0)
	near(float(w.resources["food"]), food0, 1e-4, "退款不会重复发（再跑一秒数字不动）")


# ------------------------------------------------------------------
# 十三、快照：队列是权威状态，客机也要能画出那五个格子
# ------------------------------------------------------------------
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

	var w2 = WorldRes.create(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var g2 = w2.unit_by_id(g1.id)
	ok(g2 != null, "客机侧有同一个将领")
	if g2 != null:
		eq(g2.train_kind, KIND, "★ 应用快照后队列跟着过来")
		ok(g2.is_training(), "客机侧也处于「招募中」")
		near(g2.train_remaining, g1.train_remaining, 0.02, "剩余秒数对齐")
		eq(g2.train_queue.size(), 1, "排队的那一个也过来了")
		v2_near(g2.train_anchor, g2.pos, 1e-6, "钉住的位置取权威位置")

	# 缺字段容忍：不带 tk 的老快照不能把本地队列清掉
	var w3 = _quiet_world(cfg)
	var g3 = w3.unit_by_id("general-1")
	_give(w3, 1000.0, 1000.0)
	w3.zones.zone_at(g3.tx, g3.ty)["population"] = 10.0
	w3.start_recruit(KIND, g3.id, "p1")
	var old_snap := {"units": [{"i": g3.id, "f": "p1", "k": "general", "x": g3.pos.x, "y": g3.pos.y}],
		"buildings": []}
	SnapshotRes.apply_snapshot(w3, cfg, old_snap)
	eq(g3.train_kind, KIND, "★ 老快照没有 tk → 保持本地队列不变（别当成空队列）")


# ------------------------------------------------------------------
# 十三、人口上限与招募的配合
# ------------------------------------------------------------------
##
## 用户需求（两条一起看）：
##   「每个区块都需要有人口上限，如果没有填人口上限则默认为 1；当人口自然增长至上限时停止增长」
##   「将领位于己方地块上招募占位单位时会消耗该区块 1 人口」。
##
## 这一节钉住两者**放在一起**时的行为：人口涨到上限就停、招募扣掉 1 人口之后
## 又能涨回来（但不会越过上限）；上限 0 的区块永远招不了（拒因 population）。
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

	# 上限 0 的区块：永远没有人口 → 在那里招募直接被拒（拒因 population）
	z["population_cap"] = 0.0
	z["population"] = 0.0
	eq(w.can_afford_recruit(KIND, g1.id), "population",
		"★ 上限 0 的区块招不了（人口不足）")


# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

## 关掉战斗的世界（读条 / 落点这类用例不该被敌人搅进来，见 pitfalls 5.11 / 5.34）
func _quiet_world(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return WorldRes.create(c)


func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold


## 把区划产能清零（要「对账」的用例必须调它：否则 tick 期间资源与人口一直在涨）
func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 找一格「属于别人的区划、可通行、没有建筑」的地（区划限制用）
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


## 一组单位的 id（命令里只放 id，不放对象引用）
func _ids(units: Array) -> Array:
	var out: Array = []
	for u in units:
		out.append(u.id)
	return out


## 往可招募表里临时塞第二个兵种（只给「验队列前移」那一个用例用）。
## ★ 它是**每次现读** cfg.data 的，所以这里改得动（载入时算好的标量改不动）。
## ★ 数值走默认：这一节不关心它怎么打，只关心「谁在队列的第几格」。
func _inject_second_kind(cfg) -> String:
	var list = cfg.get_path_value("recruit.list")
	(list as Array).append({
		"kind": "subordinate2", "label": "二号占位", "short": "贰",
		"train_sec": 10, "population_cost": 1, "cost": {"food": 50, "gold": 50},
	})
	return "subordinate2"


func _tick_secs(w, secs: float) -> void:
	var n: int = int(ceil(secs / DT))
	for _i in n:
		w.tick(DT)


## 同上，但把这一段时间里 tick 交出来的事件**收集起来**（验事件时用）
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


## 某类事件里带某个 reason 的有几条（取消 / 阵亡用的是同一个事件类型，靠 reason 分）
func _count_reason(events: Array, type_name: String, reason: String) -> int:
	var n := 0
	for e in events:
		if String(e.get("type", "")) == type_name and String(e.get("reason", "")) == reason:
			n += 1
	return n


## 最后一条 recruit_rejected 的拒因码（没有则空串）
func _last_reject_reason(events: Array) -> String:
	var reason := ""
	for e in events:
		if String(e.get("type", "")) == "recruit_rejected":
			reason = String(e.get("reason", ""))
	return reason
