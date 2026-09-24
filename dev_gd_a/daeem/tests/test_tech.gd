## test_tech.gd —— 科技模块（右下「科技」页签 → 3×3 九格 → 启用 / 弃用）
##
## 需求原话：
##   「当玩家什么都没选中时，原右下角只有一个建筑页签的地方添加一个科技页签，
##     同时该科技页签也会同步到选中大本营时的科技页签中」；
##   「当前占位用科技有 9 个，铺满右下角科技页签的 3x3 格子」；
##   「玩家同一时间仅可启用三个占位科技，玩家需要通过点击科技以启用科技，
##     当玩家启用的科技数到 3 时，玩家再启用科技会被阻止并提示，
##     玩家可以点击已启用的科技以弃用科技」。
##
## ★ 这里钉**逻辑层**这条链：表（config.json → logic/tech.gd）→ 启用 / 弃用的规则
##   → 上限 3 与拒因 → 三类效果（每地块加产量 / 血量倍率 / 人口增长倍率）→ 命令层。
##   「页签显示哪几颗、九格画成什么样」在 tests/test_ui.gd 里验。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")

const DT := 1.0 / 60.0
## 三条互不相干的科技：加粮食 / 建筑血量 / 人口增长
const T_FOOD := "food_1"
const T_FOOD2 := "food_2"
const T_GOLD := "gold_1"
const T_BUILDING := "building_hp"
const T_LEADER := "leader_hp"
const T_POP := "zone_population"


func _initialize() -> void:
	_case_name = "test_tech"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_toggle_basics(cfg)
	_test_limit_three(cfg)
	_test_food_and_gold_bonus(cfg)
	_test_hp_bonus(cfg)
	_test_population_bonus(cfg)
	_test_commands(cfg)


# ------------------------------------------------------------------
# 一、表来自 config.json（代码里不写死科技名 / 数值）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	eq(w.tech_list().size(), 9, "★ 表里有 9 条占位科技（铺满 3×3 九格）")
	eq(w.tech_max_active(), 3, "★ 同一时间最多启用 3 条（config.tech.max_active）")
	var ids: Array = []
	for e in w.tech_list():
		ids.append(String((e as Dictionary).get("id", "")))
	eq(ids.size(), 9, "九条都有 id")
	for want in ["food_1", "food_2", "food_3", "gold_1", "gold_2", "gold_3",
			"building_hp", "leader_hp", "zone_population"]:
		ok(ids.has(want), "表里有 %s" % want)
	# 每一条都要能拿到「名字 + 第二行小字 + tooltip」——九格上要写这些
	var missing: Array = []
	for e2 in w.tech_list():
		var d: Dictionary = e2
		if String(d.get("name", "")) == "" or String(d.get("line", "")) == "" \
				or String(d.get("desc", "")) == "":
			missing.append(String(d.get("id", "?")))
	eq(missing.size(), 0, "★ 九条都配齐了 name / line / desc（缺的：%s）" % str(missing))

	# 九格的显示数据（视图直接拿它画）
	var entries: Array = w.tech_entries()
	eq(entries.size(), 9, "★ tech_entries() 给出九格")
	eq(String((entries[0] as Dictionary).get("id", "")), "food_1", "第 1 格 = 粮食产量 I")
	ok(not bool((entries[0] as Dictionary).get("active", true)), "开局一条都没启用")


# ------------------------------------------------------------------
# 二、点一下 = 启用；再点一下 = 弃用
# ------------------------------------------------------------------
func _test_toggle_basics(cfg) -> void:
	var w = _quiet(cfg)
	ok(not w.is_tech_active(T_FOOD), "开局 food_1 没启用")
	# 走命令层（与界面同一条路），不是直接调 world
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": true}),
		"★ tech_toggle(on) 命令被接受")
	ok(w.is_tech_active(T_FOOD), "启用之后是启用状态")
	eq(w.active_tech_ids().size(), 1, "启用列表里有 1 条")
	eq(w.tech_remaining_slots(), 2, "还剩 2 个名额")
	# 取「九格数据」时这一格要标成 active（界面就靠它画高亮）
	var act := false
	for e in w.tech_entries():
		if String((e as Dictionary).get("id", "")) == T_FOOD:
			act = bool((e as Dictionary).get("active", false))
	ok(act, "★ tech_entries() 里这一格标成 active（界面按它画高亮）")

	# 重复启用同一条：状态不变，也不占第二个名额
	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": true}),
		"重复启用同一条返回 false（状态没变）")
	eq(w.active_tech_ids().size(), 1, "★ 重复启用不会占用第二个名额")

	# 弃用（界面上就是「再点一下已启用的那一格」）
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD, "on": false}),
		"★ tech_toggle(off) 命令被接受")
	ok(not w.is_tech_active(T_FOOD), "★ 弃用之后不再是启用状态")
	eq(w.active_tech_ids().size(), 0, "启用列表空了")
	eq(w.tech_remaining_slots(), 3, "名额全回来了")
	# 不带 on 的命令 = 「切换」（玩家点格子的语义）
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD}),
		"不带 on 的 tech_toggle = 切换（点一下格子的语义）")
	ok(w.is_tech_active(T_FOOD), "切换之后启用了")
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_FOOD}),
		"再切换一次")
	ok(not w.is_tech_active(T_FOOD), "★ 第二次切换 = 弃用")

	# 不存在的科技：命令层直接拒（不写事件、不改状态）
	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": "nope", "on": true}),
		"不存在的科技 id 被拒")
	ok(not w.is_tech_active("nope"), "不存在的科技不会进启用列表")


# ------------------------------------------------------------------
# 三、★ 最多 3 条：第 4 条被阻止并留一条事件（界面翻成红字提示）
# ------------------------------------------------------------------
func _test_limit_three(cfg) -> void:
	var w = _quiet(cfg)
	for id in [T_FOOD, T_FOOD2, T_GOLD]:
		ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": id, "on": true}),
			"启用第 %d 条" % (w.active_tech_ids().size()))
	eq(w.active_tech_ids().size(), 3, "★ 三条都启用了")
	eq(w.tech_remaining_slots(), 0, "名额用完")
	ok(w.tech.can_activate(T_BUILDING) == "limit", "★ 第 4 条被规则判为 limit")
	# ★ 世界那一层也要给出同一个答案（界面提示 / 逻辑落点读的都是 world）
	ok(not w.is_tech_active(T_BUILDING), "第 4 条现在没启用")
	eq(w.tech_remaining_slots(), 0, "world.tech_remaining_slots() 也是 0")

	# 第 4 条：命令被拒 + 一条 tech_rejected 事件（拒因 limit）
	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_BUILDING, "on": true}),
		"第 4 条的命令被拒")
	var evts: Array = w.tick(DT)
	var got_reject := false
	for e in evts:
		if String((e as Dictionary).get("type", "")) == "tech_rejected" \
				and String((e as Dictionary).get("reason", "")) == "limit":
			got_reject = true
	ok(got_reject, "★ 第 4 条被阻止，并留了一条 tech_rejected(limit) 给界面提示")
	ok(not w.is_tech_active(T_BUILDING), "★ 第 4 条没有生效")
	eq(w.active_tech_ids().size(), 3, "启用数仍然是 3")

	# 弃用一条 → 第 4 条就能启用了
	ok(w.set_tech_active(T_GOLD, false), "弃用中间那一条")
	ok(w.set_tech_active(T_BUILDING, true), "★ 腾出名额之后第 4 条可以启用")
	ok(w.is_tech_active(T_BUILDING), "它现在生效")
	eq(w.active_tech_ids().size(), 3, "又是 3 条")

	# 重开一局：科技必须清零（带着上一局的启用状态重开会静默改变开局数值）
	w.reset()
	eq(w.active_tech_ids().size(), 0, "★ reset() 之后一条科技都没启用")


# ------------------------------------------------------------------
# 四、粮食 / 黄金：+n／地块／秒
# ------------------------------------------------------------------
func _test_food_and_gold_bonus(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)                       # 先把区划产能清零，只留科技那一份
	# ★ 先跑一帧：`owned_tiles` / `production_food` 是 tick() 里的权威值，
	#   reset() 之后它们还是 0（那是「本帧还没算过」的状态，不是「没有领地」）。
	w.tick(DT)
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	var tiles: int = int(w.owned_tiles)
	ok(tiles > 0, "开局有己方占领地块（大本营把出生区划收归己方）")
	if tiles <= 0:
		return
	var f0: float = w.production_food
	var g0: float = w.production_gold

	ok(w.set_tech_active(T_FOOD, true), "启用「粮食产量 I」")
	# 状态一变就要立刻反映在产量上（不等到下一帧）
	near(w.production_food, f0 + 1.0 * float(tiles), 1e-6,
		"★ 粮食 +1/地块/秒（%d 地块 → +%d/秒）" % [tiles, tiles])
	near(w.production_gold, g0, 1e-6, "黄金不受影响")

	# 再叠一条 +2：加产量是**求和**（+1 +2 = +3）
	ok(w.set_tech_active(T_FOOD2, true), "再启用「粮食产量 II」")
	near(w.production_food, f0 + 3.0 * float(tiles), 1e-6,
		"★ 两条叠加 = +3/地块/秒（加产量求和）")

	# 真跑一帧：资源按这个速率涨
	var before: float = float(w.resources["food"])
	w.tick(1.0)
	near(float(w.resources["food"]) - before, w.production_food, 1e-3,
		"★ 一秒钟涨的量 = HUD 上显示的那个「+n/秒」")

	# 黄金那条
	w.resources["gold"] = 0.0
	ok(w.set_tech_active(T_GOLD, true), "启用「黄金产量 I」")
	near(w.production_gold, g0 + 1.0 * float(tiles), 1e-6,
		"★ 黄金 +1/地块/秒")

	# 弃用之后回到原样
	w.set_tech_active(T_FOOD, false)
	w.set_tech_active(T_FOOD2, false)
	near(w.production_food, f0, 1e-6, "★ 弃用之后粮食加成归零")
	w.set_tech_active(T_GOLD, false)
	near(w.production_gold, g0, 1e-6, "弃用之后黄金加成归零")


# ------------------------------------------------------------------
# 五、血量倍率：建筑 +10% / 将领 +10%（**实时生效**，已有的也一起变）
# ------------------------------------------------------------------
func _test_hp_bonus(cfg) -> void:
	var w = _quiet(cfg)
	var base = w.find_base_of("p1")
	var wall = _player_wall(w)
	var leader = w.unit_by_id("general-1")
	var sub = _first_retinue(w)
	ok(base != null, "有己方大本营")
	ok(wall != null, "有一栋己方城墙（大本营旁的防御阵地）")
	ok(leader != null, "有将领 general-1")
	ok(sub != null, "有亲兵（用来验「只加将领、不加亲兵」）")
	if base == null or wall == null or leader == null or sub == null:
		return

	var base_max: float = base.hp_max
	var wall_max: float = wall.hp_max
	var leader_max: float = leader.hp_max
	var sub_max: float = sub.hp_max
	# 让城墙先掉 1/4 血：+10% 之后它应当**仍然是 3/4 血**（按比例缩放，不是加满）
	wall.hp = wall_max * 0.75
	var wall_hp: float = wall.hp

	ok(w.set_tech_active(T_BUILDING, true), "启用「建筑加固」")
	near(base.hp_max, base_max * 1.1, 1e-3, "★ 已建好的大本营血量上限 +10%")
	near(wall.hp_max, wall_max * 1.1, 1e-3, "★ 已建好的城墙血量上限 +10%")
	near(wall.hp / wall.hp_max, wall_hp / wall_max, 1e-6,
		"★ 当前血量按比例缩放（残血的墙不会因为加成变成满血）")
	near(leader.hp_max, leader_max, 1e-6, "只启用建筑那一条时，将领血量不变")

	ok(w.set_tech_active(T_LEADER, true), "启用「将领强化」")
	near(leader.hp_max, leader_max * 1.1, 1e-3, "★ 将领血量上限 +10%")
	near(sub.hp_max, sub_max, 1e-6, "★ 亲兵不吃这一条（需求只写将领）")
	near(base.hp_max, base_max * 1.1, 1e-3, "建筑那一条仍在生效（两条互不影响）")

	# 再刷一帧：倍率没变的时候**不许**把血量重复放大（粘性）
	w.tick(DT)
	near(leader.hp_max, leader_max * 1.1, 1e-3, "★ 反复推进不会重复放大血量")
	near(base.hp_max, base_max * 1.1, 1e-3, "建筑同理")

	# 新造的建筑也要当场带上加成（否则「刚造好的墙比开局那座脆」）
	var nb = _build_wall_near(w)
	ok(nb != null, "找得到一格空地，能造一栋新墙")
	if nb != null:
		near(nb.hp_max, float(w.cfg.num("building.wall.hp_max", 300.0)) * 1.1, 1e-3,
			"★ 新造的建筑当场带上 +10%")

	# 弃用之后回到 1.0，且血量的**比例**保持
	var ratio_before: float = leader.hp / leader.hp_max
	w.set_tech_active(T_LEADER, false)
	near(leader.hp_max, leader_max, 1e-3, "★ 弃用之后将领上限回到基础值")
	near(leader.hp / leader.hp_max, ratio_before, 1e-6, "弃用同样按比例缩放当前血量")
	w.set_tech_active(T_BUILDING, false)
	near(base.hp_max, base_max, 1e-3, "弃用之后大本营血量上限回到基础值")
	near(wall.hp_max, wall_max, 1e-3, "弃用之后城墙血量上限回到基础值")


# ------------------------------------------------------------------
# 六、★ 区划人口产量 +10%（只加玩家占领的区划，加的是增长速度、不是上限）
# ------------------------------------------------------------------
func _test_population_bonus(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	var theirs = _foreign_zone(w)
	ok(mine != null, "有一块己方区划")
	ok(theirs != null, "有一块别人（无主 / 敌方）的区划")
	if mine == null or theirs == null:
		return

	# 造一个干净的局面：两块地的产能与人口都一样，上限给足
	for z in [mine, theirs]:
		(z["production"] as Dictionary)["population"] = 2.0
		z["population"] = 0.0
		z["population_cap"] = 1000.0
	var n_mine := float(mine["tile_count"])
	var n_theirs := float(theirs["tile_count"])

	# 没科技：两块地都按「产能 × 地块数」涨
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0 * n_mine, 1e-6, "没科技时己方区划按基础速度涨")
	near(float(theirs["population"]), 2.0 * n_theirs, 1e-6, "没科技时别人区划按基础速度涨")

	# 启用科技：己方 ×1.1，别人**不变**
	for z in [mine, theirs]:
		z["population"] = 0.0
	ok(w.set_tech_active(T_POP, true), "启用「区划人口」")
	near(w.tech_population_mult(), 1.1, 1e-6, "★ 人口增长倍率变成 1.1")
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0 * n_mine * 1.1, 1e-6,
		"★ 己方区划人口涨得快 10%")
	near(float(theirs["population"]), 2.0 * n_theirs, 1e-6,
		"★ 别人（无主 / 敌方）的区划**不受**加成")

	# 走一帧真正的 tick 也是同一条路（防止「只测了直接调」这种漏接）
	for z in [mine]:
		z["population"] = 0.0
	w.tick(1.0)
	near(float(mine["population"]), 2.0 * n_mine * 1.1, 1e-3, "★ world.tick 里同样生效")

	# 上限不受科技影响：涨到 cap 就停
	mine["population"] = float(mine["population_cap"]) - 0.001
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), float(mine["population_cap"]), 1e-6,
		"★ 科技加的是速度，不是上限：涨到 population_cap 就停")

	# 弃用 → 回到基础速度
	mine["population"] = 0.0
	ok(w.set_tech_active(T_POP, false), "弃用「区划人口」")
	near(w.tech_population_mult(), 1.0, 1e-6, "倍率回到 1.0")
	w.zones.update_population(1.0, w.my_faction, w.tech_population_mult())
	near(float(mine["population"]), 2.0 * n_mine, 1e-6, "★ 弃用之后回到基础速度")


# ------------------------------------------------------------------
# 七、命令层：形状与拒因（界面只发这一条命令）
# ------------------------------------------------------------------
func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	# 不带 on = 切换
	ok(CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": T_POP}), "切换命令")
	ok(w.is_tech_active(T_POP), "切换 = 启用")
	# 效果会**立刻**落进 world.tech_effects（不等到下一帧 tick）
	near(w.tech_population_mult(), 1.1, 1e-6, "★ 命令生效后当帧就能读到加成")
	# 空 id
	ok(not CommandRes.apply(w, w.cfg, {"kind": "tech_toggle", "tech_id": ""}),
		"空 id 的命令被拒")
	# 未知 kind 照旧被拒（命令入口的总开关没被改坏）
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

## 一张干净的图：关掉战斗、清零区划产能之外的副作用不动（与其它逻辑测试同一套做法）
func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return WorldRes.create(c)


func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 一块**己方**（p1）区划
func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != w.my_faction:
			continue
		return z
	return null


## 一块**不属于**本地玩家的区划（无主 / 敌方）
func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == w.my_faction:
			continue
		return z
	return null


## 己方的一栋城墙（大本营旁的防御阵地，地图预置）
func _player_wall(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL \
				and String(b.owner) == w.my_faction:
			return b
	return null


func _first_retinue(w):
	for u in w.units:
		if u.alive and u.leader_id != "" and String(u.faction) == w.my_faction:
			return u
	return null


## 在某块空地上造一栋己方城墙（用来验「新建筑当场带加成」）
func _build_wall_near(w):
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.can_build_at(x, y):
				continue
			var b = w.add_building(BuildingRes.TYPE_WALL, x, y, w.my_faction, true)
			if b != null:
				return b
	return null
