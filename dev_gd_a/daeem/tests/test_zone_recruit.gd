## test_zone_recruit.gd —— 区划招募：固定九宫格 / 阶数 / 唯一性 / 开局将领 #0
##
## 口径（2026.10 改版）：
##   · 招募页固定列出 #1-9（不再随机抽 3 张手牌）；
##   · #1-3 = 1 阶、#4-6 = 2 阶、#7-9 = 3 阶；大本营等级 ≥ tier 才能招；
##   · 每位将领每方只能拥有一次（永久唯一；取消队列会释放名额）；
##   · 自由对战只给「本机操作的玩家阵营 + 有大本营」各一位 #0（kind = general_0），
##     #0 不可招募、不在九宫格里；
##   · 关卡摆放的 general_1..9 自动视为已拥有。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_zone_recruit"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_fixed_roster_and_tiers(cfg)
	_test_starting_general_zero(cfg)
	_test_uniqueness(cfg)
	_test_enqueue_pays_and_cooldown(cfg)
	_test_cancel_frees_slot(cfg)
	_test_train_and_spawn_near_center(cfg)
	_test_queue_cap_and_cancel(cfg)
	_test_commands(cfg)
	_test_stop_command(cfg)
	_test_level_starting_generals_owned(cfg)

# ------------------------------------------------------------------
# 1) 配置：9 条招募项 + 10 位将领档 + tier
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	eq(w.zone_recruit_list().size(), 9, "★ 区划招募表里有九名将领")
	eq(cfg.general_types().size(), 10, "★ 将领名册 10 位（#0 + #1-9）")
	eq(cfg.general_name_at(9), "将领 0", "★ #0 的名字")
	eq(cfg.general_type_at(9), UnitRes.UNIT_TYPE_SPEARMAN, "★ #0 是长枪兵型")
	eq(cfg.general_cap_at(9), 11, "★ #0 编制上限 11")
	eq(w.general_recruit_roster("p1").size(), 9, "★ 招募阵容固定 9 位")
	for i in 9:
		var kind := "general_%d" % (i + 1)
		var want_tier := 1 if i < 3 else (2 if i < 6 else 3)
		eq(w.general_recruit_tier(kind), want_tier, "%s 是 %d 阶" % [kind, want_tier])
	eq(w.recruit_short_of("general_4"), "将", "格子里写的短字仍是「将」")
	eq(w.zone_recruit_queue_max(), 5, "★ 区划队列上限 5 个")
	near(w.recruit_train_sec("general_4"), 10.0, 1e-6, "★ 每个将领读条 10 秒")
	near(float(w.recruit_population_cost("general_4")), 1.0, 1e-6, "★ 每个将领吃 1 人口")
	near(float(w.recruit_cost("general_1").get("food", 0.0)), 200.0, 1e-6, "★ 将领 1 200 粮食（造价 ×2）")
	near(w.general_recruit_cooldown_of("general_9"), 45.0, 1e-6, "★ 将领 9 冷却 45 秒")

# ------------------------------------------------------------------
# 2) 固定阵容 + 阶数门槛
# ------------------------------------------------------------------
func _test_fixed_roster_and_tiers(cfg) -> void:
	var w = _quiet(cfg)
	_set_base_level(w, 1)
	for i in 9:
		var kind := "general_%d" % (i + 1)
		var st: Dictionary = w.general_recruit_state("p1", kind)
		if i < 3:
			ok(bool(st["ready"]), "★ 1 级大本营：一阶 %s 可招募" % kind)
		else:
			eq(String(st["reason"]), "tier", "★ 1 级大本营：%s 阶数不足" % kind)
			eq(int(st["tier"]), 2 if i < 6 else 3, "阶数 = %d" % int(st["tier"]))

	_set_base_level(w, 2)
	for i in 9:
		var kind := "general_%d" % (i + 1)
		var st2: Dictionary = w.general_recruit_state("p1", kind)
		if i < 6:
			ok(bool(st2["ready"]), "★ 2 级大本营：%s 已解锁" % kind)
		else:
			eq(String(st2["reason"]), "tier", "★ 2 级大本营：三阶仍锁")

	_set_base_level(w, 3)
	for i in 9:
		var kind := "general_%d" % (i + 1)
		var st3: Dictionary = w.general_recruit_state("p1", kind)
		ok(bool(st3["ready"]), "★ 3 级大本营：%s 已解锁" % kind)
		eq(String(st3["reason"]), "", "无拒因")

	# 无大本营 → level 0 → 全部锁
	var w2 = require_world(cfg)
	var base2 = w2.find_base_of("p1")
	if base2 != null:
		w2.remove_building(base2, true)
	var st4: Dictionary = w2.general_recruit_state("p1", "general_1")
	eq(String(st4["reason"]), "tier", "★ 没有大本营 → 一阶也锁")

# ------------------------------------------------------------------
# 3) 开局将领 #0
# ------------------------------------------------------------------
func _test_starting_general_zero(cfg) -> void:
	var w = _quiet(cfg)
	var zeros: Array = []
	for u in w.units:
		if int(u.general_index) == 9:
			zeros.append(u)
	eq(zeros.size(), 1, "★★ 自由对战玩家阵营有且只有 1 位 #0")
	if zeros.is_empty():
		return
	var g = zeros[0]
	eq(String(g.kind), "general_0", "★ kind = general_0")
	eq(String(g.id), "general-0", "★ id = general-0")
	eq(String(g.name), "将领 0", "★ 名字「将领 0」")
	eq(String(g.unit_type), UnitRes.UNIT_TYPE_SPEARMAN, "★ 长枪兵型")
	eq(String(g.hotkey), "1", "★ 快捷键 1")
	ok(g.is_general(), "★ is_general() 为真")
	ok(not w.general_recruit_roster("p1").has("general_0"), "★ #0 不在招募九宫格里")
	ok(String(g.general_trait) == "" and String(g.aura_trait_id) == "",
		"★ 词条已停用：#0 没有特性")

	# 没有大本营的玩家阵营 → 不生成 #0
	var w2 = require_world(cfg)
	var base2 = w2.find_base_of("p1")
	if base2 != null:
		w2.remove_building(base2, true)
	w2.units.clear()
	w2.spawn_faction_units("p1")
	ok(w2.units.is_empty(), "★★ 没有大本营 → 不再生成 #0")

	# 非玩家阵营 → 不生成 #0
	var w3 = require_world(cfg)
	w3.units.clear()
	w3.spawn_faction_units("p2")
	ok(w3.units.is_empty(), "★ AI / 非玩家阵营不自动生成 #0")

# ------------------------------------------------------------------
# 4) 唯一性：入队即占用、取消释放、永久阵亡不释放
# ------------------------------------------------------------------
func _test_uniqueness(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 5000.0, 5000.0)
	var z = _own_zone(w)
	ok(z != null, "（前提）有己方区划")
	if z == null:
		return
	z["population"] = 100.0
	var zid := int(z["id"])
	var kind := "general_1"

	ok(not w.general_recruit_owned("p1", kind), "（前提）一开始未拥有")
	ok(w.start_zone_recruit(kind, zid, "p1"), "★ 招 #1 入队")
	ok(w.general_recruit_owned("p1", kind), "★★ 入队即标记为已拥有")
	eq(String(w.general_recruit_state("p1", kind)["reason"]), "owned",
		"★ 九宫格里 #1 显示「已拥有」")
	eq(w.can_recruit_zone(kind, zid, "p1"), "owned", "★ 同一位不能再招")
	ok(not w.start_zone_recruit(kind, zid, "p1"), "★★ 重复招募被拒")

	# 取消 → 释放名额
	_clear_cooldown(w)
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "取消队列里的 #1")
	ok(not w.general_recruit_owned("p1", kind), "★★ 取消后释放唯一名额")
	eq(w.can_recruit_zone(kind, zid, "p1"), "", "★ 可以重新招募")

	# 招出来之后永久阵亡，仍然不能再招
	_clear_cooldown(w)
	ok(w.start_zone_recruit(kind, zid, "p1"), "重新招 #1")
	_tick_secs(w, 11.0)
	var fresh = w.units[w.units.size() - 1]
	ok(w.general_recruit_owned("p1", kind), "（前提）已拥有")
	var base = w.find_base_of("p1")
	if base != null:
		w.remove_building(base, true)       # 没有大本营 → 永久阵亡
	fresh.take_damage(w.cfg, w, fresh.hp + 999999.0, null)
	w.tick(DT)
	ok(w.unit_by_id(fresh.id) == null, "★ 将领永久阵亡")
	ok(w.general_recruit_owned("p1", kind), "★★ 永久阵亡后仍然不能再招募（永远唯一）")

# ------------------------------------------------------------------
# 5) 入队扣费 / 全局冷却 / 已拥有
# ------------------------------------------------------------------
func _test_enqueue_pays_and_cooldown(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var kind := "general_1"
	var cost: Dictionary = w.recruit_cost(kind)
	var cd: float = w.general_recruit_cooldown_of(kind)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])

	ok(w.start_zone_recruit(kind, zid, "p1"), "区划招募入队成功")
	near(float(z["train_remaining"]), 10.0, 1e-6, "刚入队时剩余 = 10 秒")
	near(w.zone_train_progress(z), 0.0, 1e-6, "刚入队时进度是 0")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-4,
		"★ 入队即扣粮食")
	near(float(w.resources["gold"]), gold0 - float(cost.get("gold", 0.0)), 1e-4,
		"★ 入队即扣黄金")
	near(float(z["population"]), 4.0, 1e-4, "★ 人口从本区划扣")
	ok(w.general_recruit_owned("p1", kind), "★ 已拥有")
	near(w.general_recruit_cooldown_left("p1"), cd, 1e-6, "★ 全局冷却 = 该将的属性")
	eq(String(w.general_recruit_state("p1", "general_2")["reason"]), "cooldown",
		"★ 冷却中其他未拥有的将领也显示冷却")
	eq(String(z.get("train_trait", "")), "", "★ 词条已停用：队列里没有特性")

# ------------------------------------------------------------------
# 6) 取消：退款 + 解冻 + 释放唯一名额
# ------------------------------------------------------------------
func _test_cancel_frees_slot(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var kind := "general_1"
	var food0: float = float(w.resources["food"])
	ok(w.start_zone_recruit(kind, zid, "p1"), "（前提）排队")
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "★ 取消成功")
	near(float(w.resources["food"]), food0, 1e-4, "★ 全额退款")
	near(w.general_recruit_cooldown_left("p1"), 0.0, 1e-6, "★ 取消解除冷却")
	ok(not w.general_recruit_owned("p1", kind), "★★ 取消释放唯一名额")
	ok(not w.cancel_zone_recruit(zid, 0, "p1"), "空格子取消被拒")

# ------------------------------------------------------------------
# 7) 读条 → 出兵：identity / 已拥有 / 无词条
# ------------------------------------------------------------------
func _test_train_and_spawn_near_center(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 500.0, 500.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var center: Vector2i = z["center"]
	var kind := "general_1"
	var before: int = w.units.size()
	ok(w.start_zone_recruit(kind, zid, "p1"), "排一单")
	_tick_secs(w, 9.0)
	eq(w.units.size(), before, "★ 9 秒时还没出人")
	var evts := _tick_collect(w, 1.5)
	eq(w.units.size(), before + 1, "★ 读满 10 秒 → 生成 1 名将领")
	eq(_count_events(evts, "zone_unit_recruited"), 1, "发一条 zone_unit_recruited 事件")
	var fresh = w.units[w.units.size() - 1]
	eq(String(fresh.kind), kind, "招出来的就是 #1")
	eq(String(fresh.faction), "p1", "属于招募方")
	eq(String(fresh.leader_id), "", "★ 招出来的是队长")
	ok(String(fresh.id).begins_with("zone-%d-" % zid), "id 里带着区划号")
	ok(not (fresh.tx == center.x and fresh.ty == center.y), "不生成在中心格")
	ok(maxi(absi(fresh.tx - center.x), absi(fresh.ty - center.y)) <= 2,
		"★ 生成在中心旁边")
	ok(w.general_recruit_owned("p1", kind), "★ 出兵后仍然已拥有")
	ok(String(fresh.general_trait) == "" and String(fresh.aura_trait_id) == "",
		"★★ 词条已停用：招出来的将领没有特性")

# ------------------------------------------------------------------
# 8) 队列上限 / 取消任意一格
# ------------------------------------------------------------------
func _test_queue_cap_and_cancel(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 5000.0, 5000.0)
	var z = _own_zone(w)
	z["population"] = 100.0
	var zid := int(z["id"])

	var kinds: Array = []
	for i in 5:
		_clear_cooldown(w)
		var k := _kind_at(w, i)
		ok(w.start_zone_recruit(k, zid, "p1"), "排第 %d 单成功" % (i + 1))
		kinds.append(k)
	eq(w.zone_recruit_queue_size(z), 5, "队列满 5 个")
	_clear_cooldown(w)
	var extra := _kind_at(w, 5)
	eq(w.can_recruit_zone(extra, zid, "p1"), "queue_full", "★ 满了 → queue_full")

	var cancel_kind: String = w.zone_recruit_kind_at(z, 1)
	var cancel_cost: Dictionary = w.recruit_cost(cancel_kind)
	var food0: float = float(w.resources["food"])
	ok(w.cancel_zone_recruit(zid, 1, "p1"), "★ 取消第 1 个小格子")
	near(float(w.resources["food"]), food0 + float(cancel_cost.get("food", 0.0)), 1e-4,
		"★ 取消退全额粮食")
	ok(not w.general_recruit_owned("p1", cancel_kind), "★ 取消释放那一格的唯一名额")
	eq(w.zone_recruit_queue_size(z), 4, "队列少了一个")

	# 大格子取消 → 下一个前移，仍然占用各自的名额
	var next_kind: String = w.zone_recruit_kind_at(z, 1)
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "★ 取消大格子")
	eq(w.zone_recruit_queue_size(z), 3, "再少一个")
	ok(w.general_recruit_owned("p1", next_kind), "★ 前移的那一单仍然已拥有")

# ------------------------------------------------------------------
# 9) 命令层
# ------------------------------------------------------------------
func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 10.0
	var zid := int(z["id"])
	var kind := _first_ready_kind(w)

	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": kind,
		"zone_id": zid, "faction": "p1"}), "zone_recruit 命令被接受")
	ok(w.zone_is_training(z), "命令真的把它排进了区划的队列")
	ok(w.general_recruit_cooldown_left("p1") > 0.0, "★ 命令路径同样起冷却")
	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit_cancel", "zone_id": zid,
		"slot": 0, "faction": "p1"}), "zone_recruit_cancel 命令被接受")
	ok(not w.zone_is_training(z), "取消之后队列空了")
	near(w.general_recruit_cooldown_left("p1"), 0.0, 1e-6, "★ 命令路径取消也会解除冷却")

	ok(not CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": kind,
		"zone_id": zid, "faction": "p2"}), "★ 别的阵营不能在这个区划里招")

# ------------------------------------------------------------------
# 10) stop 命令走通（#0 开局将）
# ------------------------------------------------------------------
func _test_stop_command(cfg) -> void:
	var w = _quiet(cfg)
	var g0 = w.unit_by_id("general-0")
	ok(g0 != null, "★ 有开局将领 general-0")
	if g0 == null:
		return
	var spot := _free_tile(w)
	ok(spot.x >= 0, "找得到一格空地")
	if spot.x < 0:
		return
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g0.id],
		"x": float(spot.x) + 0.5, "y": float(spot.y) + 0.5, "faction": "p1"}),
		"先下一条移动命令（前提）")
	ok(g0.moving, "（前提）它正在移动")
	ok(CommandRes.apply(w, cfg, {"kind": "stop", "ids": [g0.id], "faction": "p1"}),
		"★ stop 命令被接受")
	ok(not g0.moving and g0.path.is_empty(), "停止之后不再移动")
	ok(not CommandRes.apply(w, cfg, {"kind": "stop", "ids": [g0.id], "faction": "p2"}),
		"★ 防冒充：别的阵营停不了我的单位")

# ------------------------------------------------------------------
# 11) 关卡开局摆放的 general_1..9 → 已拥有
# ------------------------------------------------------------------
func _test_level_starting_generals_owned(cfg) -> void:
	var w = require_world_with_escorts(cfg, 1)
	if w == null:
		return
	for kind in ["general_1", "general_2", "general_3"]:
		ok(w.general_recruit_owned("p1", kind), "★ 关卡摆放的 %s 视为已拥有" % kind)
		eq(String(w.general_recruit_state("p1", kind)["reason"]), "owned",
			"%s 在九宫格里置灰" % kind)

# ------------------------------------------------------------------
# 辅助（独立 config / 世界，不依赖真实收入）
# ------------------------------------------------------------------
func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	var w = require_world(c)
	_set_base_level(w, w.cfg.upgrade_max_level("base"))
	return w

func _set_base_level(w, lv: int) -> void:
	var b = w.find_base_of("p1")
	if b != null:
		b.level = clampi(lv, 1, w.cfg.upgrade_max_level("base"))
		w.apply_building_level_hp(b)

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == "p1" and z["center"] != null:
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

func _kind_at(w, i: int) -> String:
	var hand: Array = w.general_recruit_roster("p1")
	if i < 0 or i >= hand.size():
		return ""
	return String(hand[i])

func _first_ready_kind(w) -> String:
	for k in w.general_recruit_roster("p1"):
		if bool(w.general_recruit_state("p1", String(k))["ready"]):
			return String(k)
	return ""

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
