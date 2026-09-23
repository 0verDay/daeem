## test_zone_recruit.gd —— 区划招募（点区划中心 → 右下「招募」页签 → 招将领）
##
## 需求原话：「当玩家选中区划中心时，右下角显示招募页签（显示三个占位将领，
##            玩家可以点击以将招募将领加入区划的招募队列中，招募逻辑同招募单位）」。
##
## ★ 这里只钉**逻辑层**这条链：配置表 → 校验（只能自己区划）→ 入队即扣费 →
##   读条 10 秒 → 在**区划中心旁边**生成 → 取消退款 / 前移 → 命令层。
##   「页签怎么切、命令卡里是哪几格」在 tests/test_ui.gd 里验。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")

const DT := 1.0 / 60.0
const KIND := "general_1"
const KIND2 := "general_2"


func _initialize() -> void:
	_case_name = "test_zone_recruit"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_only_own_zone(cfg)
	_test_enqueue_pays(cfg)
	_test_train_and_spawn_near_center(cfg)
	_test_queue_cap_and_cancel(cfg)
	_test_commands(cfg)
	_test_stop_command(cfg)


# ------------------------------------------------------------------
# 一、数值表来自 config.json（代码里不写字面量）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	eq(w.zone_recruit_list().size(), 3, "★ 区划招募表里有三个占位将领")
	ok(w.is_zone_recruitable(KIND), "general_1 在区划招募表里")
	ok(not w.is_unit_recruitable(KIND),
		"★ 区划表里的将领**不能**走「将领招兵」那条路（两张表是分开的）")
	ok(w.is_recruitable(KIND), "但它仍然是「可招募兵种」（短字 / 消耗查表要用）")
	ok(w.is_unit_recruitable(UnitRes.KIND_SUBORDINATE), "亲兵仍然只在单位那张表里")
	eq(w.recruit_short_of(KIND), "将", "格子里写的短字是 config 的 short（将）")
	eq(w.zone_recruit_queue_max(), 5, "★ 区划队列上限 5 个")
	near(w.recruit_train_sec(KIND), 10.0, 1e-6, "★ 每个将领读条 10 秒")
	near(float(w.recruit_population_cost(KIND)), 1.0, 1e-6, "★ 每个将领吃 1 人口")
	var cost: Dictionary = w.recruit_cost(KIND)
	near(float(cost.get("food", 0.0)), 50.0, 1e-6, "★ 每个将领 50 粮食")
	near(float(cost.get("gold", 0.0)), 50.0, 1e-6, "★ 每个将领 50 黄金")
	eq(w.recruit_label_of(KIND), "将领 1", "显示名来自 label")


# ------------------------------------------------------------------
# 二、只能在**属于自己的**区划里招
# ------------------------------------------------------------------
func _test_only_own_zone(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	ok(z != null, "找得到一块己方区划（大本营把出生区划收归己方）")
	if z == null:
		return
	var zid := int(z["id"])
	eq(w.can_recruit_zone(KIND, zid, "p1"), "", "★ 己方区划 → 可以招")

	# 无主 / 别人的区划：拒因是 zone_owner
	var foreign = _foreign_zone(w)
	ok(foreign != null, "地图上找得到一块不属于 p1 的区划")
	if foreign != null:
		eq(w.can_recruit_zone(KIND, int(foreign["id"]), "p1"), "zone_owner",
			"★ 不是自己的区划 → 拒因 zone_owner")
		var food0: float = float(w.resources["food"])
		ok(not w.start_zone_recruit(KIND, int(foreign["id"]), "p1"), "★ 别人的区划招不了")
		near(float(w.resources["food"]), food0, 1e-6, "被拒时一分钱都不扣")
		eq(w.zone_recruit_queue_size(foreign), 0, "被拒时队列里什么都没有")

	eq(w.can_recruit_zone(KIND, 9999, "p1"), "zone_not_found", "没有这个区划 → zone_not_found")
	eq(w.can_recruit_zone(UnitRes.KIND_SUBORDINATE, zid, "p1"), "kind",
		"单位页那张表里的兵种不能在区划里招（拒因 kind）")

	# 把无主那块划给己方 → 又能招了（判据是区划归属，不是「哪一块地」）
	if foreign != null:
		foreign["owner"] = "p1"
		eq(w.can_recruit_zone(KIND, int(foreign["id"]), "p1"), "", "划给己方之后就能招了")


# ------------------------------------------------------------------
# 三、入队即扣费（粮食 / 黄金 / 区划人口）+ 队列形态
# ------------------------------------------------------------------
func _test_enqueue_pays(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 200.0, 200.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var before_units: int = w.units.size()

	var events: Array = []
	ok(w.start_zone_recruit(KIND, zid, "p1"), "区划招募入队成功")
	# ⚠️ 「刚入队」的那几条断言必须在 tick **之前**做：一 tick 就会扣掉一帧的读条时间。
	near(float(z["train_remaining"]), 10.0, 1e-6, "刚入队时剩余 = 10 秒")
	near(w.zone_train_progress(z), 0.0, 1e-6, "刚入队时进度是 0")
	for e in (w.tick(DT) as Array):
		events.append(e)
	near(float(w.resources["food"]), 150.0, 1e-4, "★ 入队即扣 50 粮食")
	near(float(w.resources["gold"]), 150.0, 1e-4, "★ 入队即扣 50 黄金")
	near(float(z["population"]), 4.0, 1e-4, "★ 入队即扣 1 人口（从**这个区划**扣）")
	eq(_count_events(events, "zone_recruit_queued"), 1, "入队发一条 zone_recruit_queued 事件")

	eq(String(z["train_kind"]), KIND, "★ 大格子里是刚排进来的那个")
	near(float(z["train_total"]), 10.0, 1e-6, "记录了总读条时间 10 秒")
	eq(w.zone_recruit_queue_size(z), 1, "队列里一共 1 个")
	ok(w.zone_is_training(z), "★ 这个区划进入「招募中」状态")
	eq(w.units.size(), before_units, "★ 入队不会立刻生成单位（要读条 10 秒）")
	eq(String(z["train_faction"]), "p1", "记下了招募方（读完按它出兵）")

	# 第二个排进小格子，不抢读条
	var remaining_before := float(z["train_remaining"])
	ok(w.start_zone_recruit(KIND2, zid, "p1"), "再排一个也成功")
	eq((z["train_queue"] as Array).size(), 1, "第二个排进小格子")
	eq(w.zone_recruit_queue_size(z), 2, "队列里一共 2 个")
	near(float(z["train_remaining"]), remaining_before, 1e-6, "正在读条的还是第一个")
	eq(w.zone_recruit_kind_at(z, 0), KIND, "第 0 格（大格子）= 第一个")
	eq(w.zone_recruit_kind_at(z, 1), KIND2, "第 1 格（小格子）= 第二个")
	eq(w.zone_recruit_kind_at(z, 2), "", "第 2 格是空的")
	near(w.zone_recruit_eta(z, 1), remaining_before + 10.0, 1e-4,
		"★ ETA：轮到第二个还差「大格子剩余 + 它自己的 10 秒」")


# ------------------------------------------------------------------
# 四、读条 10 秒 → 在**区划中心旁边**生成，而且招出来的是**队长**
# ------------------------------------------------------------------
func _test_train_and_spawn_near_center(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 200.0, 200.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])
	var center: Vector2i = z["center"]
	ok(w.building_at(center.x, center.y) != null,
		"（前提）区划中心那一格上立着中立障碍建筑（所以不能生成在格心）")

	var before_units: int = w.units.size()
	ok(w.start_zone_recruit(KIND, zid, "p1"), "排一单")

	_tick_secs(w, 9.0)
	eq(w.units.size(), before_units, "★ 9 秒时还没出人（要读满 10 秒）")
	ok(w.zone_is_training(z), "这时还在读条")
	ok(w.zone_train_progress(z) > 0.5, "读条进度跟着走（%f）" % w.zone_train_progress(z))

	var events := _tick_collect(w, 1.5)
	eq(w.units.size(), before_units + 1, "★ 读满 10 秒 → 生成 1 名将领")
	eq(_count_events(events, "zone_unit_recruited"), 1, "发一条 zone_unit_recruited 事件")
	ok(not w.zone_is_training(z), "★ 队列空了 → 不再是「招募中」")

	var fresh = w.units[w.units.size() - 1]
	eq(String(fresh.kind), KIND, "招出来的就是表里那个兵种")
	eq(String(fresh.faction), "p1", "属于招募方")
	ok(fresh.alive, "它是活的")
	eq(String(fresh.leader_id), "", "★ 招出来的是**队长**（leader_id 为空）")
	ok(w.is_team_leader(fresh), "★ 它是队长 → 会作为新的一支部队出现在左侧列表里")
	eq(w.retinue_of(fresh.id).size(), 0, "刚招出来的将领名下还没有亲兵")
	ok(String(fresh.id).begins_with("zone-%d-" % zid), "id 里带着区划号（%s）" % fresh.id)

	# 位置：不在中心那一格（那是障碍建筑），但在它旁边一圈内、且是空地
	ok(not (fresh.tx == center.x and fresh.ty == center.y),
		"★ 不生成在区划中心那一格（那里是中立障碍建筑）")
	var cheb: int = maxi(absi(fresh.tx - center.x), absi(fresh.ty - center.y))
	ok(cheb <= 2, "★ 生成在中心**旁边**（切比雪夫距离 %d ≤ 2）" % cheb)
	ok(w.building_at(fresh.tx, fresh.ty) == null, "生成的那一格上没有建筑")


# ------------------------------------------------------------------
# 五、队列上限 5 / 取消某一格（全额退款 + 后方前移 + 从头读条）
# ------------------------------------------------------------------
func _test_queue_cap_and_cancel(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 1000.0, 1000.0)
	var z = _own_zone(w)
	z["population"] = 20.0
	var zid := int(z["id"])

	for i in 5:
		ok(w.start_zone_recruit(KIND, zid, "p1"), "排第 %d 单成功" % (i + 1))
	eq(w.zone_recruit_queue_size(z), 5, "队列满 5 个")
	eq(w.can_recruit_zone(KIND, zid, "p1"), "queue_full", "★ 满了 → 拒因 queue_full")

	var food0: float = float(w.resources["food"])
	ok(not w.start_zone_recruit(KIND, zid, "p1"), "第 6 单被拒")
	near(float(w.resources["food"]), food0, 1e-6, "被拒的那一单不扣钱")
	var evts: Array = w.tick(DT)
	var full_evt := _first_event(evts, "recruit_rejected")
	eq(String(full_evt.get("reason", "")), "queue_full", "拒因码是 queue_full")
	eq(int(full_evt.get("max", 0)), 5, "★ 事件里带着队列上限（界面文案用它）")

	# 取消第 1 个小格子：全额退款 + 后方前移
	var pop0: float = float(z["population"])
	ok(w.cancel_zone_recruit(zid, 1, "p1"), "★ 取消第 1 个小格子")
	near(float(w.resources["food"]), food0 + 50.0, 1e-4, "★ 取消退 50 粮食")
	near(float(z["population"]), pop0 + 1.0, 1e-4, "★ 人口也退还给**这个区划**")
	eq(w.zone_recruit_queue_size(z), 4, "队列少了一个（后方的自动前移）")

	# 取消大格子：队列里的下一个顶上，并且**从头读条**
	var remaining_before := float(z["train_remaining"])
	eq(w.zone_recruit_kind_at(z, 0), KIND, "（前提）大格子里有东西")
	ok(w.cancel_zone_recruit(zid, 0, "p1"), "★ 取消大格子")
	eq(w.zone_recruit_queue_size(z), 3, "再少一个")
	eq(w.zone_recruit_kind_at(z, 0), KIND, "下一个前移进了大格子")
	near(float(z["train_remaining"]), float(z["train_total"]), 1e-4,
		"★ 前移的那一单从头读条（不继承已读掉的时间）")
	ok(remaining_before <= 10.0, "（前提）取消前它确实在读条")

	# 空格子 / 别人的区划：取消被拒
	ok(not w.cancel_zone_recruit(zid, 4, "p1"), "★ 空格子取消被拒（什么都不做）")
	eq(w.zone_recruit_queue_size(z), 3, "空格子取消不改队列")
	var foreign = _foreign_zone(w)
	if foreign != null:
		ok(not w.cancel_zone_recruit(int(foreign["id"]), 0, "p1"),
			"★ 别人的区划里的队列取消不了")


# ------------------------------------------------------------------
# 六、命令层（右下「招募」页的格子 → zone_recruit 命令；队列格子 → zone_recruit_cancel）
# ------------------------------------------------------------------
func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	_give(w, 200.0, 200.0)
	var z = _own_zone(w)
	z["population"] = 5.0
	var zid := int(z["id"])

	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": KIND,
		"zone_id": zid, "faction": "p1"}), "zone_recruit 命令被接受")
	ok(w.zone_is_training(z), "命令真的把它排进了区划的队列")
	ok(CommandRes.apply(w, cfg, {"kind": "zone_recruit_cancel", "zone_id": zid,
		"slot": 0, "faction": "p1"}), "zone_recruit_cancel 命令被接受")
	ok(not w.zone_is_training(z), "取消之后队列空了")

	# 防冒充：不能拿别人的阵营来给自己区划招（owner 与 faction 不同侧 → 拒）
	ok(not CommandRes.apply(w, cfg, {"kind": "zone_recruit", "unit_kind": KIND,
		"zone_id": zid, "faction": "p2"}), "★ 别的阵营不能在这个区划里招")


# ------------------------------------------------------------------
# 七、操作页的「停止」命令（逻辑层这一半）
# ------------------------------------------------------------------
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


# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

## 关掉战斗的世界（读条 / 落点这类用例不该被敌人搅进来，见 pitfalls 5.11 / 5.34）
func _quiet(cfg) -> RefCounted:
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


## 一块**己方**（p1）且有中心的区划（大本营所在的出生区划）
func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != "p1":
			continue
		if z["center"] == null:
			continue
		return z
	return null


## 一块不属于 p1 的区划（中心可有可无）
func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == "p1":
			continue
		return z
	return null


## 一格可通行的空地（没有建筑、没有区划中心）
func _free_tile(w) -> Vector2i:
	for ty in w.map.rows:
		for tx in w.map.cols:
			if not w.can_build_at(tx, ty):
				continue
			if w.zone_center_zone_at(tx, ty) != null:
				continue
			return Vector2i(tx, ty)
	return Vector2i(-1, -1)


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


## 某类事件里的第一条（没有则空字典）
func _first_event(events: Array, type_name: String) -> Dictionary:
	for e in events:
		if String(e.get("type", "")) == type_name:
			return e
	return {}
