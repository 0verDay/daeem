## test_recruit_queue.gd —— 招募（★ 2026.11.14 起是**即时**的：没有队列、没有读条）
##
## 文件名保留 `test_recruit_queue`（跑测脚本按文件名遍历，改名要动 runner），
## 但语义已经换成「**拖出一张招募牌 = 兵当场出来**」：
##   · `world.start_recruit()` 扣费后立刻走 `_spawn_from_recruit()`（与「读条完成」同一条路）；
##   · `world.start_zone_recruit()` 立刻走 `_spawn_zone_recruit()`；
##   · 没有 `train_kind` / `train_queue` / `train_remaining`，也没有「取消队列 / 退款」；
##   · 冷却：单位牌本来就没有；将领招募池那条全局冷却与本文件无关（见 test_zone_recruit）。
##
## ⚠️ 别把这里的断言改回「队列」—— 那套字段已经不再被写入了，
##   真写回去只会得到「排进去了却没兵」的假通过。
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
	_test_instant_spawn(cfg)
	_test_reject_reasons(cfg)
	_test_spawn_tiles_distinct(cfg)
	_test_command_path(cfg)
	_test_population_gate(cfg)
	_test_no_refund_on_death(cfg)
	_test_zone_instant(cfg)
	_test_snapshot_round_trip(cfg)

func _test_config_table(cfg) -> void:
	var w = require_world(cfg)
	ok(w.is_recruitable(KIND), "config.recruit.list 里长枪兵可招募")
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")
	# ★ 2026.11.14：`train_sec` 已经从数据里清掉 ⇒ 这个接口恒为 0（保留只为兼容调用点）
	eq(w.recruit_train_sec(KIND), 0.0, "★ 招募是即时的：兵种没有读条时间")
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
	# 挪到敌方区划 → zone 拒因
	var far := _foreign_tile(w, "p1")
	if far.x >= 0:
		g1.pos = GridRes.center_of(far)
		g1.sync_tile(w.map)
		eq(w.can_recruit(KIND, g1.id, "p1"), "zone", "★ 站在敌方区划里 → 拒因 zone")

func _test_instant_spawn(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 200.0, 200.0)
	var g1 = w.unit_by_id("general-1")
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 5.0
	var before_subs: int = w.retinue_of(g1.id).size()
	var fcost: float = _food_of(w, KIND)
	var gcost: float = _gold_of(w, KIND)

	ok(w.start_recruit(KIND, g1.id, "p1"), "招募成功")
	# ★★ 这一条就是本轮改动的核心：**当场生成**，不等读条
	eq(w.retinue_of(g1.id).size(), before_subs + 1,
		"★★ 招募是即时的：兵**当场**出现在将领旗下")
	eq(g1.train_queue_size(), 0, "★★ 没有队列（恒为空）")
	ok(not g1.is_training(), "★★ 也不存在「招募中」状态")
	near(float(w.resources["food"]), 200.0 - fcost, 1e-4, "★ 当场扣粮（= config 里这个兵种的粮价）")
	near(float(w.resources["gold"]), 200.0 - gcost, 1e-4, "★ 黄金也按 config")
	near(float(z["population"]), 4.0, 1e-4, "★ 当场扣 1 人口（从将领所在区划扣）")

	# 新兵：满血、挂在将领名下、就在将领周围一圈以内
	var fresh = w.retinue_of(g1.id)[before_subs]
	ok(fresh != null and fresh.alive, "★ 新兵是活的")
	if fresh != null:
		eq(String(fresh.leader_id), String(g1.id), "★ 新兵挂在招它的将领名下")
		near(fresh.hp, fresh.hp_max, 1e-4, "★ 出生满血")
		var d := Vector2(fresh.pos - g1.pos).length()
		ok(d <= 2.5, "★ 出生在将领周围一圈以内（实际 %.2f 格）" % d)

	# 连招两个也立刻出两个（没有冷却）
	ok(w.start_recruit(KIND, g1.id, "p1"), "再招一个也成功")
	eq(w.retinue_of(g1.id).size(), before_subs + 2, "★★ 连招两个 → 当场两个都在")

func _test_reject_reasons(cfg) -> void:
	var w = require_world(cfg)
	var g1 = _first_general(w)
	ok(g1 != null, "有开局将领")
	if g1 == null:
		return
	var z = w.zones.zone_at(g1.tx, g1.ty)
	var subs_before: int = w.retinue_of(g1.id).size()

	eq(w.can_afford_recruit(KIND, g1.id), "cost", "★ 没钱 → 拒因 cost")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "没钱时招募被拒")
	var evts: Array = w.tick(DT)
	eq(_count_events(evts, "recruit_rejected"), 1,
		"被拒会发一条 recruit_rejected 事件（界面靠它显示原因）")
	eq(_last_reject_reason(evts), "cost", "事件里带拒因码 cost")
	eq(w.retinue_of(g1.id).size(), subs_before, "★★ 被拒时**不会**凭空多出兵")

	_give(w, 1000.0, 1000.0)
	z["population"] = 0.5
	eq(w.can_afford_recruit(KIND, g1.id), "population", "★ 人口不足 → 拒因 population")
	ok(not w.start_recruit(KIND, g1.id, "p1"), "人口不足时招募被拒")
	eq(w.retinue_of(g1.id).size(), subs_before, "被拒的招募不会出生")

	z["population"] = 1.0
	eq(w.can_afford_recruit(KIND, g1.id), "", "人口够 → 可以招")
	ok(w.start_recruit(KIND, g1.id, "p1"), "这次招募成功")
	eq(w.retinue_of(g1.id).size(), subs_before + 1, "成功即出兵")

	# 队长判据 / 防冒充
	var w2 = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w2, 1000.0, 1000.0)
	var g = w2.unit_by_id("general-1")
	var sub = w2.retinue_of(g.id)[0]
	eq(w2.can_recruit(KIND, "general-99", "p1"), "leader", "队长不存在 → leader")
	eq(w2.can_recruit(KIND, sub.id, "p1"), "leader", "★ 附属兵不是队长，不能往它名下招兵")
	eq(w2.can_recruit(KIND, g.id, FactionRes.NPC_FACTION), "faction",
		"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")
	ok(not w2.start_recruit(KIND, sub.id, "p1"), "往附属兵名下招募被拒")

func _test_spawn_tiles_distinct(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 5000.0, 5000.0)
	var g1 = w.unit_by_id("general-1")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var tiles: Array = []
	for _i in 3:
		var before: int = w.retinue_of(g1.id).size()
		if not w.start_recruit(KIND, g1.id, "p1"):
			break
		var subs: Array = w.retinue_of(g1.id)
		if subs.size() <= before:
			break
		tiles.append(Vector2i(int(subs[before].tx), int(subs[before].ty)))
	eq(tiles.size(), 3, "（前提）连招三个都成功了")
	var uniq: Array = []
	for t in tiles:
		if not uniq.has(t):
			uniq.append(t)
	eq(uniq.size(), tiles.size(), "★★ 三个兵落在不同的格子上（不会叠在一起）")

func _test_command_path(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	_give(w, 1000.0, 1000.0)
	var g1 = w.unit_by_id("general-1")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 5.0
	var before: int = w.retinue_of(g1.id).size()
	var okc: bool = CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": KIND, "leader_id": g1.id, "faction": "p1"})
	ok(okc, "★ 走命令路径（recruit）也成功")
	eq(w.retinue_of(g1.id).size(), before + 1,
		"★★ 命令路径同样是即时的（手牌拖拽最终就走这里）")

func _test_population_gate(cfg) -> void:
	var w = require_world(cfg)
	_give(w, 5000.0, 5000.0)
	var g1 = _first_general(w)
	if g1 == null:
		ok(false, "有开局将领")
		return
	var z = w.zones.zone_at(g1.tx, g1.ty)
	z["population"] = 0.0
	ok(not w.start_recruit(KIND, g1.id, "p1"), "没人口时招不出来")
	z["population"] = 1.0
	ok(w.start_recruit(KIND, g1.id, "p1"), "人口够了就能招")

func _test_no_refund_on_death(cfg) -> void:
	# ★ 队列没了 ⇒ 「将领阵亡退款」这条路径也就不存在了：钱是当场花掉的。
	var w = _quiet_world(cfg)
	_no_income(w)
	_give(w, 500.0, 500.0)
	var g1 = w.unit_by_id("general-1")
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 5.0
	var before: int = w.retinue_of(g1.id).size()
	ok(w.start_recruit(KIND, g1.id, "p1"), "（前提）招一个")
	var food_after: float = float(w.resources["food"])
	var subs_after: int = w.retinue_of(g1.id).size()
	eq(subs_after, before + 1, "（前提）兵已经出来了")
	for m in w.retinue_of(String(g1.id), true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	w.tick(DT)
	near(float(w.resources["food"]), food_after, 1e-4,
		"★ 阵亡不会退款（钱是当场花掉的，不是押金）")

func _test_zone_instant(cfg) -> void:
	# ★ 区划招将有「阶数 ≤ 大本营等级」这一关，所以用**正式关卡**（有己方大本营）的世界。
	var w = require_world(cfg)
	_give(w, 9999.0, 9999.0)
	var base = w.find_base_of("p1")
	ok(base != null, "有己方大本营")
	if base == null:
		return
	var zone = w.zones.zone_at(base.tx, base.ty)
	ok(zone != null, "大本营所在的区划")
	if zone == null:
		return
	zone["population"] = 50.0
	# ★ 把大本营等级拉满（否则 1 阶将领也会因 tier 被拒）
	var b = w.find_base_of("p1")
	if b != null:
		b.level = maxi(int(b.level), 3)
	zone["owner"] = "p1"
	var avail: Array = w.general_recruit_available("p1")
	ok(avail.size() > 0, "（前提）还有没招过的将领")
	if avail.is_empty():
		return
	var kind := String(avail[0])
	var before: int = w.units.size()
	var why: String = w.can_recruit_zone(kind, int(zone["id"]), "p1")
	eq(why, "", "（前提）这位将领可以招（拒因：%s）" % why)
	ok(w.start_zone_recruit(kind, int(zone["id"]), "p1"), "★ 区划招将领成功（拒因：%s）" % why)
	eq(w.units.size(), before + 1, "★★ 也是即时的：将领当场出现")
	ok(not w.zone_is_training(zone), "★★ 区划不再进入「读条中」")
	# ★★ 招走之后，招募页那张牌要消失
	var after: Array = w.general_recruit_available("p1")
	eq(after.size(), avail.size() - 1, "★★ 招走一位 ⇒ 可招清单少一位")
	ok(not after.has(kind), "★★ 招走的那位不再出现在招募页")

func _test_snapshot_round_trip(cfg) -> void:
	var w = _quiet_world(cfg)
	var g1 = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	var before: int = w.retinue_of(g1.id).size()
	ok(w.start_recruit(KIND, g1.id, "p1"), "（前提）招一个")
	eq(w.retinue_of(g1.id).size(), before + 1, "（前提）兵已经出来了")

	var snap = SnapshotRes.to_snapshot(w)
	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var g2 = w2.unit_by_id(g1.id)
	ok(g2 != null, "客机侧有同一个将领")
	if g2 == null:
		return
	eq(w2.retinue_of(g2.id).size(), before + 1,
		"★★ 快照往返之后，**已经生出来的兵**也还在（没有队列要同步了）")
	eq(g2.train_queue_size(), 0, "★★ 快照里也没有队列可言")

# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

func _quiet_world(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world_with_escorts(c, ESCORTS_PER_GENERAL)

func _first_general(w):
	for u in w.units:
		if u.alive and u.is_general() and String(u.faction) == "p1":
			return u
	return null

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	w.base_bonus_enabled = false
	w.refresh_zone_production()

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _food_of(w, kind: String) -> float:
	return float((w.recruit_cost(kind) as Dictionary).get("food", 0.0))

func _gold_of(w, kind: String) -> float:
	return float((w.recruit_cost(kind) as Dictionary).get("gold", 0.0))

func _count_events(evts: Array, type_name: String) -> int:
	var n := 0
	for e in evts:
		if typeof(e) == TYPE_DICTIONARY and String((e as Dictionary).get("type", "")) == type_name:
			n += 1
	return n

func _last_reject_reason(evts: Array) -> String:
	var reason := ""
	for e in evts:
		if typeof(e) == TYPE_DICTIONARY \
				and String((e as Dictionary).get("type", "")) == "recruit_rejected":
			reason = String((e as Dictionary).get("reason", ""))
	return reason

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
