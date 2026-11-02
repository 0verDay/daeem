## test_clan_tech.gd —— 派系科技（原生 / 王朝 / 帝国）的**数据 + 效果**回归。
##
## 覆盖三层：
##   1. **表**：原生 9 条不变；王朝 7 条 / 帝国 8 条，槽位是 9 格（空位留占位）；
##      两派共用「速战速决 / 无懈可击」同一个 id；跨派系的科技点不了。
##   2. **效果**：15 条科技逐条验算（移速 / 占领时间 / 远近免伤 / 招募解锁与金转粮 /
##      人口上限与速度 / 队伍攻击 / 脱战免维护 / 建筑产能 / 产能惩罚 / 金耗折扣 /
##      每区划攻防 / 冲锋占位 / 归属转换回满）。
##   3. **AI**：每派的优先级只写自己表里的 id，且 `_try_tech` 只会点自己派系的科技。
##
## ★ 测试里怎么"启用科技"：`world.set_tech_active(id, true, faction)`。
##   ⚠️ 玩家席位有「黄金净收入赤字不许再启用」那条规则 ⇒ 测试世界必须先给这方
##     一点黄金产能（`_pump_gold`），否则第二条就会被拒。AI 阵营不受这条限制。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const GridRes = preload("res://logic/grid.gd")
const TechRes = preload("res://logic/tech.gd")

const DT := 1.0 / 60.0
const TEST_LEVEL := "res://data/campaigns/demo/levels/ai_test_battle.json"

func _initialize() -> void:
	_case_name = "test_clan_tech"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_tables(cfg)
	_test_entries_view(cfg)
	_test_cross_clan_rejected(cfg)
	_test_speed_and_capture(cfg)
	_test_unbreakable(cfg)
	_test_liyue(cfg)
	_test_population_techs(cfg)
	_test_formation(cfg)
	_test_farming(cfg)
	_test_building_income(cfg)
	_test_levy(cfg)
	_test_enclosure(cfg)
	_test_expedition(cfg)
	_test_chivalry(cfg)
	_test_breakthrough(cfg)
	_test_ai_priority(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ==================================================================
# 1) 表
# ==================================================================

func _test_tables(cfg) -> void:
	# ---- 原生：9 条、没有空位（与改动前逐位一致）
	var native: Array = cfg.tech_list_for("native")
	eq(native.size(), 9, "★ 原生派系科技页仍是 9 格")
	eq(native.size(), cfg.tech_list().size(), "★ 原生 = 顶层 tech.list（没另开一份）")
	for i in 9:
		ok(String((native[i] as Dictionary).get("id", "")) != "",
			"★ 原生第 %d 格有科技" % i)

	# ---- 王朝 / 帝国：9 个槽位，空位是占位（位置不能压紧）
	var dy: Array = cfg.tech_list_for("dynasty")
	var dg: Array = cfg.tech_list_for("empire")
	eq(dy.size(), 9, "★★ 王朝科技页也是 9 格（空位留占位）")
	eq(dg.size(), 9, "★★ 帝国科技页也是 9 格")
	var dy_ids := _ids(dy)
	var dg_ids := _ids(dg)
	eq(_count_empty(dy), 2, "★★ 王朝空 2 格（7 条科技）")
	eq(_count_empty(dg), 1, "★★ 帝国空 1 格（8 条科技）")
	eq(_non_empty(dy), 7, "★ 王朝 7 条")
	eq(_non_empty(dg), 8, "★ 帝国 8 条")

	# ---- 两派共用同样两条（同一个 id，定义只有一份）
	ok(dy_ids.has("tech_speed_rush") and dg_ids.has("tech_speed_rush"),
		"★★ 「速战速决」两派共用同一个 id")
	ok(dy_ids.has("tech_unbreakable") and dg_ids.has("tech_unbreakable"),
		"★★ 「无懈可击」两派共用同一个 id")
	eq(int(cfg.tech_tier("tech_speed_rush")), 1, "★ 速战速决是一本")
	eq(int(cfg.tech_tier("tech_unbreakable")), 3, "★ 无懈可击是三本")

	# ---- 行 = 阶：每一格自己的 tier 与它所在的行一致（科技页是列优先 3×3）
	for pair in [["王朝", dy], ["帝国", dg]]:
		var label := String(pair[0])
		var slots: Array = pair[1]
		for i in 9:
			var e: Dictionary = slots[i]
			if String(e.get("id", "")) == "":
				continue
			eq(int(e.get("tier", 0)), i % 3 + 1,
				"★ %s 第 %d 格（第 %d 行）是 %d 本" % [label, i, i % 3 + 1, i % 3 + 1])

	# ---- 每一条都有名字 / 两行文案 / effect（空槽位除外）
	for cid in ["dynasty", "empire"]:
		for e in cfg.tech_list_for(cid):
			var d: Dictionary = e
			var id := String(d.get("id", ""))
			if id == "":
				ok(bool(d.get("empty", false)), "★ 空槽位带 empty 标记")
				continue
			ok(String(d.get("name", "")) != "", "★ %s 有名字" % id)
			ok(String(d.get("line", "")) != "", "★ %s 有格子小字" % id)
			ok(String(d.get("desc", "")) != "", "★ %s 有悬停详情" % id)
			ok(not (d.get("effect", {}) as Dictionary).is_empty(), "★ %s 有效果" % id)
			# 效果键必须是 tech.gd 认识的（否则会被静默丢掉）
			var known: Dictionary = TechRes.default_effects()
			for k in (d.get("effect", {}) as Dictionary).keys():
				ok(known.has(String(k)), "★★ %s 的效果键 %s 是认识的" % [id, k])

	# ---- 每派最多同时 3 条（沿用原生规则）
	eq(cfg.tech_max(), 3, "★ 同时启用上限仍是 3 条")


## 科技页吃的是 `world.tech_entries(faction)`：9 条、空位带 `empty` 且不可点。
func _test_entries_view(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	var dy: Array = w.tech_entries("p1")
	var dg: Array = w.tech_entries("p2")
	eq(dy.size(), 9, "★★ 王朝科技页喂给视图的是 9 格")
	eq(dg.size(), 9, "★★ 帝国 9 格")
	var dy_empty := 0
	for e in dy:
		if bool((e as Dictionary).get("empty", false)):
			dy_empty += 1
			eq(String((e as Dictionary).get("id", "")), "", "★ 空位没有 id")
			ok(not bool((e as Dictionary).get("available", true)),
				"★★ 空位不可点（界面画灰框）")
			eq(String((e as Dictionary).get("name", "")), "", "★ 空位没名字")
	eq(dy_empty, 2, "★★ 王朝 2 个空位")
	# 有科技的格子：有名字 / 有每秒金耗 / 未启用但可点（一本且大本营 1 级）
	var first: Dictionary = dy[0]
	eq(String(first.get("name", "")), "速战速决", "★ 第一格是速战速决")
	ok(float(first.get("gold_per_sec", 0.0)) > 0.0, "★ 带每秒金耗")
	# 三本科技在 1 级大本营时置灰（拒因 tier）
	var third: Dictionary = dy[2]
	eq(String(third.get("id", "")), "tech_unbreakable", "（前提）第三格是无懈可击")
	ok(not bool(third.get("available", true)), "★★ 1 级大本营点不了三本科技")
	eq(String(third.get("reason", "")), "tier", "★ 拒因是 tier")


func _test_cross_clan_rejected(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	# 王朝点不了帝国的科技
	eq(w.tech_can_activate("dg_levy", "p1"), "unknown",
		"★★ 王朝点不了「征召民兵」（不在自己表里）")
	eq(w.tech_can_activate("dg_enclosure", "p1"), "unknown", "★★ 圈地制同理")
	# 帝国点不了王朝的
	eq(w.tech_can_activate("dy_liyue", "p2"), "unknown", "★★ 帝国点不了「礼乐」")
	# 共用的两条两边都能点
	eq(w.tech_can_activate("tech_speed_rush", "p1"), "", "★★ 王朝能点共用的速战速决")
	eq(w.tech_can_activate("tech_speed_rush", "p2"), "", "★★ 帝国也能点同一条")
	# 真点一下也会被拒（不是只有查询层拦）
	ok(not w.set_tech_active("dg_levy", true, "p1"), "★★ 真点也被拒")
	ok(not w.is_tech_active("dg_levy", "p1"), "★★ 状态没变")
	# 空槽位点不了
	ok(not w.set_tech_active("", true, "p1"), "★★ 空槽位点不了")


# ==================================================================
# 2) 速战速决：移速 +10% / 占领时间 −20%
# ==================================================================

func _test_speed_and_capture(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var u = _mk_unit(w, cfg, "spd_u", "dy_spear_guard", "p1")
	if u == null:
		return
	var base: float = u.speed(cfg, null, w)
	near(w.tech_speed_mult("p1"), 1.0, 1e-9, "★ 没启用时移速倍率 = 1")
	ok(w.set_tech_active("tech_speed_rush", true, "p1"), "★ 启用速战速决")
	near(w.tech_speed_mult("p1"), 1.1, 1e-9, "★★ 移速倍率 = 1.1")
	near(u.speed(cfg, null, w), base * 1.1, 1e-6, "★★ 单位实际移速 +10%")
	# 不传 world 的老调用不受影响（老测试 / 老视图保持原值）
	near(u.speed(cfg, null), base, 1e-6, "★ 不传 world 时不算科技（旧调用不变）")

	# 占领时间：同一个区划、同样的进度，快 20% ⇒ 这一帧多读 1/0.8 倍
	near(w.tech_capture_time_mult("p1"), 0.8, 1e-9, "★★ 占领所需时间倍率 = 0.8")
	near(w.tech_capture_time_mult("p2"), 1.0, 1e-9, "★ 帝国没启用 ⇒ 仍是 1.0")


# ==================================================================
# 3) 无懈可击：全单位远近免伤 +10%
# ==================================================================

func _test_unbreakable(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var u = _mk_unit(w, cfg, "def_u", "dy_spear_guard", "p1")
	if u == null:
		return
	eq(w.tech_reduction_add("p1", true), 0.0, "★ 没启用时远程免伤加成 = 0")
	ok(w.set_tech_active("tech_unbreakable", true, "p1"), "★ 启用无懈可击")
	near(w.tech_reduction_add("p1", true), 0.1, 1e-9, "★★ 远程免伤 +10%")
	near(w.tech_reduction_add("p1", false), 0.1, 1e-9, "★★ 近战免伤 +10%")
	# 真的算进伤害：同一击，扣血更少（士气放在高低两档之间 = 士气不影响这一次结算）
	var cfg2 = cfg
	u.armor = 0.0                        # 关掉固定护甲，只看免伤那一份
	u.morale = cfg.morale_vuln_tier + 1.0
	u.hp = u.hp_max
	u.take_damage(cfg2, w, 100.0, null, true, false)
	var with_tech: float = u.hp_max - u.hp
	u.hp = u.hp_max
	w.set_tech_active("tech_unbreakable", false, "p1")
	u.take_damage(cfg2, w, 100.0, null, true, false)
	var without: float = u.hp_max - u.hp
	near(with_tech, 90.0, 1e-4, "★★ 启用后 100 点远程伤害只掉 90")
	near(without, 100.0, 1e-4, "★ 弃用后恢复 100")
	ok(with_tech < without, "★★ 无懈可击真的减伤")


# ==================================================================
# 4) 礼乐：解锁招募阶 + 金转粮
# ==================================================================

func _test_liyue(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	# ★ 保持 1 级大本营：这一节要验「礼乐把阶限制整个解除」。
	_pump_gold(w, false)
	# 1 级大本营时「御林军」（三本）本该锁着
	ok(not w.unit_recruit_unlocked("p1", "dy_royal"),
		"（前提）1 级大本营招不了三本兵")
	ok(w.set_tech_active("dy_liyue", true, "p1"), "★ 启用礼乐")
	ok(w.tech_recruit_tier_unlocked("p1"), "★★ 招募阶限制解除")
	ok(w.unit_recruit_unlocked("p1", "dy_royal"), "★★ 三本兵也能招了")
	eq(w.can_recruit("dy_royal", "", "p1"), "leader", "★ 剩下的拒因只跟将领有关")
	# 金 → 粮：御林军 300 金 ⇒ 粮 += 300 × 1.5（2026.11 单价下调）
	var cost: Dictionary = w.recruit_cost("dy_royal", "p1")
	eq(float(cost.get("gold", -1.0)), 0.0, "★★ 招募不再花金")
	near(float(cost.get("food", 0.0)), 195.0 + 300.0 * 1.5, 1e-4,
		"★★ 300 金全部按 1 金 = 1.5 粮折成粮（195 + 450 = 645）")
	# 帝国没有礼乐 ⇒ 价钱不变
	var dg_cost: Dictionary = w.recruit_cost("dg_champion", "p2")
	near(float(dg_cost.get("gold", 0.0)), 340.0, 1e-6, "★★ 帝国这边价钱不变（冠军骑士 340 金）")
	# 弃用之后一切复原
	w.set_tech_active("dy_liyue", false, "p1")
	near(float(w.recruit_cost("dy_royal", "p1").get("food", 0.0)), 195.0, 1e-6,
		"★ 弃用后粮耗回到 195")


# ==================================================================
# 5) 皇恩浩荡 / 征召民兵：人口上限与速度
# ==================================================================

func _test_population_techs(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var z: Dictionary = w.zones.zones[0]
	z["owner"] = "p1"
	var cap0: float = w.zones.population_cap_of(z)
	near(w.tech_zone_population_cap_add("p1"), 0.0, 1e-9, "★ 没启用时上限加成 = 0")
	ok(w.set_tech_active("dy_grace", true, "p1"), "★ 启用皇恩浩荡")
	near(w.tech_zone_population_cap_add("p1"), 3.0, 1e-9, "★★ 每区划上限 +3")
	near(w.tech_population_mult("p1"), 1.2, 1e-9, "★★ 人口增长速度 +20%")
	# 上限要真的写进区划（走 _refresh_zone_population_bonuses）
	w.tick(DT)
	near(w.zones.population_cap_of(z), cap0 + 3.0, 1e-6, "★★ 区划的实际上限 +3")
	# 没主的区划不加
	var zn: Dictionary = w.zones.zones[1]
	zn["owner"] = ""
	w.tick(DT)
	near(w.tech_zone_population_cap_add("p1"), 3.0, 1e-9, "★ 科技本身仍是 +3")
	w.set_tech_active("dy_grace", false, "p1")
	w.tick(DT)
	near(w.zones.population_cap_of(z), cap0, 1e-6, "★ 弃用后上限回落")


# ==================================================================
# 6) 军形有势：部队里每人 +2% 攻击
# ==================================================================

func _test_formation(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var leader = _mk_unit(w, cfg, "fm_leader", "dy_spear_guard", "p1")
	var m1 = _mk_unit(w, cfg, "fm_m1", "dy_spear_guard", "p1")
	var m2 = _mk_unit(w, cfg, "fm_m2", "dy_archer_guard", "p1")
	if leader == null or m1 == null or m2 == null:
		return
	m1.leader_id = "fm_leader"
	m2.leader_id = "fm_leader"
	eq(w.squad_size_of(m1), 3, "★ 队伍 3 个人")
	near(w.tech_attack_mult(m1), 1.0, 1e-9, "★ 没启用时攻击倍率 = 1")
	ok(w.set_tech_active("dy_formation", true, "p1"), "★ 启用军形有势")
	near(w.tech_attack_mult(m1), 1.06, 1e-9, "★★ 3 人 ⇒ +6% 攻击")
	eq(w.squad_size_of(leader), 3, "★★ 队长数的也是整队（3 个人）")
	near(w.tech_attack_mult(leader), 1.06, 1e-9, "★★ 队长自己也吃（同一队同一个数）")
	eq(w.squad_size_of(_mk_unit(w, cfg, "fm_solo", "dy_spear_guard", "p1")), 1,
		"★ 不属于任何队伍的单位 = 1 个人")
	# 上限 +20%：一队 11 人封顶（不封的话大编队会变成 +60%）
	var ids: Array = []
	for i in 12:
		var extra = _mk_unit(w, cfg, "fm_x%d" % i, "dy_spear_guard", "p1")
		if extra != null:
			extra.leader_id = "fm_leader"
			ids.append(extra)
	near(w.tech_attack_mult(m1), 1.2, 1e-9, "★★ 人数再多也只到 +20%（封顶）")


# ==================================================================
# 7) 屯田制：脱战单位不耗粮
# ==================================================================

func _test_farming(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var u = _mk_unit(w, cfg, "up_u", "dy_spear_guard", "p1")
	if u == null:
		return
	# ★★ 「脱战」= **招募那条判据**（`world.is_out_of_combat`：连续 N 秒没有目标、且没挨打）。
	u.target = null
	u.recruit_idle_timer = float(cfg.recruit_combat_idle_sec) + 1.0
	ok(w.is_out_of_combat(u), "★★ 站够 N 秒没目标 ⇒ 判为脱战")
	eq(w.is_out_of_combat_for_recruit(u), w.is_out_of_combat(u),
		"★★ 招募那边的判据与这儿是同一个函数（不是两份实现）")
	# ⚠️ `test_case.require_config()` 默认把「持续消耗」总闸关掉（老用例要精确对账），
	#    这里必须显式打开，否则维护费恒为 0（这一节测的正是维护费）。
	cfg.upkeep_enabled = true
	w.tick(DT)
	var rate_no_tech: float = float(w._upkeep_food_rate.get("p1", 0.0))
	ok(rate_no_tech > 0.0, "（前提）没科技时要扣维护费（%.4f 粮/秒）" % rate_no_tech)
	ok(w.set_tech_active("dy_farming", true, "p1"), "★ 启用屯田制")
	ok(w.tech_upkeep_idle_exempt("p1"), "★★ 脱战免维护生效")
	u.recruit_idle_timer = float(cfg.recruit_combat_idle_sec) + 1.0
	w.tick(DT)
	var rate_with_tech: float = float(w._upkeep_food_rate.get("p1", 1.0))
	near(rate_with_tech, 0.0, 1e-6, "★★ 脱战单位不再计维护费（%.4f → %.4f）"
		% [rate_no_tech, rate_with_tech])
	# 但**在战斗中**的单位照旧要花钱：有目标 ⇒ 计时清零 ⇒ 不算脱战
	var foe = _mk_unit(w, cfg, "up_foe", "dg_swordsman", "p2")
	if foe != null:
		u.target = foe
		w.tick(DT)                       # 这一帧 `_tick_recruit_idle` 把计时清零
		ok(not w.is_out_of_combat(u), "★★ 有目标 ⇒ 计时清零 ⇒ 不算脱战")
		w.tick(DT)
		var rate_in_combat: float = float(w._upkeep_food_rate.get("p1", 0.0))
		ok(rate_in_combat > 0.0,
			"★★ 有攻击目标的单位仍然要扣粮（屯田制只管脱战，实际 %.4f）" % rate_in_combat)
	cfg.upkeep_enabled = false           # 还原测试默认（后面的用例按老口径对账）


# ==================================================================
# 8) 铁犁牛耕 / 淘金：建筑额外产能
# ==================================================================

func _test_building_income(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	# 造一栋便宜的建筑（粮田）给 p1
	var tile := _open_spot(w, "p1", 1)
	ok(tile.x >= 0, "（前提）找到空地")
	if tile.x < 0:
		return
	var b = w.add_building("farm", tile.x, tile.y, "p1")
	ok(b != null, "（前提）农场建起来了")
	if b == null:
		return
	var food0: float = float(w._flat_resource_bonus("p1").get("food", 0.0))
	var gold0: float = float(w._flat_resource_bonus("p1").get("gold", 0.0))
	ok(w.set_tech_active("dy_plow", true, "p1"), "★ 启用铁犁牛耕")
	near(float(w._flat_resource_bonus("p1").get("food", 0.0)), food0 + 0.15, 1e-6,
		"★★ 这栋建筑多产 0.15 粮/秒")
	ok(w.set_tech_active("dg_goldrush", true, "p2"), "★ 帝国启用淘金")
	# p2 也有建筑吗？没有就自己造一栋
	var t2 := _open_spot(w, "p2", 1)
	if t2.x >= 0:
		var b2 = w.add_building("farm", t2.x, t2.y, "p2")
		if b2 != null:
			near(float(w._flat_resource_bonus("p2").get("gold", 0.0)), gold0 + 0.08, 1e-6,
				"★★ 帝国每栋建筑 +0.08 金/秒")


# ==================================================================
# 9) 征召民兵：产能 −15% / 人口 +25% / 上限 +2
# ==================================================================

func _test_levy(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var food_before: float = float(w.zones.production_of("p2").get("food", 0.0))
	ok(food_before > 0.0, "（前提）帝国至少有一块产粮的区划（%.2f）" % food_before)
	near(w.tech_zone_population_cap_add("p2"), 0.0, 1e-9, "★ 没启用时 +0")
	ok(w.set_tech_active("dg_levy", true, "p2"), "★ 启用征召民兵")
	near(w.tech_zone_population_cap_add("p2"), 2.0, 1e-9, "★★ 每区划上限 +2")
	near(w.tech_population_mult("p2"), 1.25, 1e-9, "★★ 人口速度 +25%")
	# 产能：区划自己的产量不变（惩罚乘在**总产出**那一段）
	near(float(w.zones.production_of("p2").get("food", 0.0)), food_before, 1e-6,
		"★ 区划原产量不动（惩罚在汇总时才乘）")
	var eff: Dictionary = w.tech.effects_of("p2")
	near(float(eff.get("food_production_mult", 0.0)), -0.15, 1e-9,
		"★★ 总粮食产能 −15%")


# ==================================================================
# 10) 圈地制：只有「大本营额外出金」—— **没有折扣**
# ==================================================================

func _test_enclosure(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var gold0: float = float(w._flat_resource_bonus("p2").get("gold", 0.0))
	ok(w.set_tech_active("dg_enclosure", true, "p2"), "★ 启用圈地制")
	near(float(w._flat_resource_bonus("p2").get("gold", 0.0)), gold0 + 0.4, 1e-6,
		"★★ 大本营多产 0.4 金/秒")
	# ★★ 用户确认：圈地制**没有折扣**内容 —— 招募 / 建造 / 升级一律原价。
	var cost: Dictionary = w.recruit_cost("dg_champion", "p2")
	near(float(cost.get("gold", 0.0)), 340.0, 1e-6, "★★ 招募金耗不打折（就是 340）")
	near(float(cost.get("food", 0.0)), 130.0, 1e-6, "★ 粮也不动（冠军骑士 130）")
	# 数据里也不许再有那个键（删干净了，不是「留着但没人读」）
	var eff: Dictionary = cfg.tech_entry("dg_enclosure").get("effect", {})
	ok(not eff.has("gold_cost_mult"), "★★ 圈地制的 effect 里没有 gold_cost_mult")
	ok(not cfg.tech_entry("dg_enclosure").get("desc", "").contains("×0.7"),
		"★★ 详情里也不再写折扣")
	# 升级价也是原价（走同一个 `world.building_upgrade_cost`）
	var base = w.find_base_of("p2")
	if base != null:
		var up: Dictionary = w.building_upgrade_cost(base)
		var raw: Dictionary = cfg.upgrade_cost_to(base.type, base.level)
		eq(float(up.get("gold", 0.0)), float(raw.get("gold", 0.0)),
			"★★ 升级价 = config 原价（没有折扣）")


# ==================================================================
# 11) 远征军：每区划 +2% 攻 / +2% 防御
# ==================================================================

func _test_expedition(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var u = _mk_unit(w, cfg, "ex_u", "dg_swordsman", "p2")
	if u == null:
		return
	eq(w.tech_zone_count("p2"), 1, "（前提）帝国占 1 个区划")
	near(w.tech_attack_mult(u), 1.0, 1e-9, "★ 没启用时攻击倍率 = 1")
	near(w.tech_armor_mult("p2"), 1.0, 1e-9, "★ 没启用时防御倍率 = 1")
	ok(w.set_tech_active("dg_expedition", true, "p2"), "★ 启用远征军")
	near(w.tech_attack_mult(u), 1.02, 1e-9, "★★ 1 个区划 ⇒ 攻击 +2%")
	near(w.tech_armor_mult("p2"), 1.02, 1e-9, "★★ 防御（固定减伤）+2%")
	# 再多占一个区划 ⇒ 翻倍
	w.zones.zones[3]["owner"] = "p2"
	eq(w.tech_zone_count("p2"), 2, "★ 现在占 2 个区划")
	near(w.tech_attack_mult(u), 1.04, 1e-9, "★★ 2 个区划 ⇒ +4%")
	near(w.tech_armor_mult("p2"), 1.04, 1e-9, "★★ 防御也 +4%")
	# 防御真的进伤害计算：护甲 2 × 1.04 = 2.08 ⇒ 100 伤只掉 97.92
	#   ⚠️ 把兵种自带的「近战免伤」（披甲剑士 25%）清零，否则那 25% 会把结果再乘一次。
	u.armor = 2.0
	u.melee_damage_reduction = 0.0
	u.morale = cfg.morale_vuln_tier + 1.0       # 士气放在高低两档之间 = 不影响这次结算
	u.hp = u.hp_max
	u.take_damage(cfg, w, 100.0, null, false, false)
	near(u.hp_max - u.hp, 100.0 - 2.08, 1e-4, "★★ 防御加成进了「等额减免」那一步")


# ==================================================================
# 12) 骑士精神：冲锋命中额外 +100% 伤害
# ==================================================================

func _test_chivalry(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	var e: Dictionary = cfg.tech_entry("dg_chivalry")
	ok(not e.is_empty(), "★ 骑士精神在表里")
	ok(not String(e.get("desc", "")).contains("尚未实装"),
		"★★ 详情里不再写「冲锋尚未实装」")
	ok(w.set_tech_active("dg_chivalry", true, "p2"), "★ 能启用（不报错）")
	var eff: Dictionary = w.tech.effects_of("p2")
	near(float(eff.get("charge_damage_mult", 0.0)), 1.0, 1e-9,
		"★ 聚合里有 charge_damage_mult = 1.0")
	near(w.tech_charge_add("p2"), 1.0, 1e-9,
		"★★ 骑士精神提供 +1.0 的冲锋伤害（加法）")
	# 只作用于冲锋命中：攻击 / 防御 / 移速都不受影响
	var u = _mk_unit(w, cfg, "ch_u", "dg_champion", "p2")
	if u == null:
		return
	near(w.tech_attack_mult(u), 1.0, 1e-9, "★★ 普通攻击不受影响")
	near(w.tech_armor_mult("p2"), 1.0, 1e-9, "★★ 防御不受影响")
	near(w.tech_speed_mult("p2"), 1.0, 1e-9, "★★ 移速不受影响")


# ==================================================================
# 13) 势如破竹：区划转为己方那一刻回满
# ==================================================================

func _test_breakthrough(cfg) -> void:
	var w = _clan_world(cfg)
	if w == null:
		return
	_pump_gold(w)
	ok(w.set_tech_active("dg_breakthrough", true, "p2"), "★ 启用势如破竹")
	ok(w.tech_restore_on_convert("p2"), "★★ 回满效果标记生效")
	# 造一个中立区划 + 一个 p2 单位站在它中心
	var z: Dictionary = w.zones.zones[3]
	z["owner"] = ""
	z["progress_by"] = {"p2": 0.0}
	var center = z.get("center", null)
	if center == null:
		ok(false, "（前提）第 3 区划有中心")
		return
	var u = _mk_unit(w, cfg, "bt_u", "dg_swordsman", "p2")
	if u == null:
		return
	u.pos = GridRes.center_of(center)
	u.sync_tile(w.map)
	u.hp = u.hp_max * 0.4
	u.morale = 20.0
	# 把进度推到差一帧读满
	z["progress_by"]["p2"] = 0.995
	var frames := 0
	while String(z["owner"]) != "p2" and frames < 600:
		w.tick(DT)
		frames += 1
	eq(String(z["owner"]), "p2", "（前提）区划被占下来了")
	near(u.hp, u.hp_max, 1e-6, "★★ 转为己方那一刻血量回满")
	near(u.morale, u.morale_max, 1e-6, "★★ 士气也回满")
	# 别的阵营（王朝）没有这条科技 ⇒ 转换不回满
	ok(not w.tech_restore_on_convert("p1"), "★ 王朝没有这条科技")


# ==================================================================
# 14) AI：每派科技优先级 + 只点自己派系的
# ==================================================================

func _test_ai_priority(cfg) -> void:
	for cid in ["dynasty", "empire"]:
		var block: Dictionary = cfg.clan_commander_ai(cid)
		var build: Dictionary = block.get("build", {})
		var prio: Array = build.get("tech_priority", [])
		ok(not prio.is_empty(), "★★ %s 的 AI 有科技优先级" % cid)
		var mine: Array = _ids(cfg.tech_list_for(cid))
		for id in prio:
			ok(mine.has(String(id)),
				"★★ %s 的优先级里 %s 在自己派系的表里" % [cid, id])
	# 原生的优先级为空（沿用全局 / 表顺序）——原生没有派系块
	ok(cfg.clan_commander_ai("native").is_empty(), "★ 原生没有派系块（AI 不变）")
	# 控制器真的带着这份优先级
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return
	var ov := {}
	for meta in lv.faction_meta:
		ov[String((meta as Dictionary).get("id", ""))] = LevelRes.AI_COMMANDER
	var w = WorldRes.create_from_level(cfg, lv, "p1", lv.seats(), true, ov, {}, -1, true)
	if w == null:
		return
	var ai1 = w.ai_commanders.get("p1", null)
	var ai2 = w.ai_commanders.get("p2", null)
	if ai1 == null or ai2 == null:
		ok(false, "（前提）双方 commander 都在")
		return
	ok((ai1.profile.get("build", {}) as Dictionary).get("tech_priority", []).has("dy_liyue"),
		"★★ 王朝控制器的优先级里是「礼乐」在前")
	ok((ai2.profile.get("build", {}) as Dictionary).get("tech_priority", []).has("dg_enclosure"),
		"★★ 帝国控制器的优先级里是「圈地制」在前")
	# AI 点科技：只会落到自己派系的（另一派的 id 会被拒）
	ok(not w.set_tech_active("dy_farming", true, "p2"), "★★ 帝国点不了王朝的屯田制")


# ==================================================================
# 帮手
# ==================================================================

## see_ai 那一关的世界（p1 = 王朝 / p2 = 帝国），不开 AI。
func _clan_world(cfg):
	var lv = LevelRes.load_level(null, TEST_LEVEL, cfg)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "p1", ["p1", "p2"], false)


## ★ 把测试世界调到「能点科技」的状态：两件事都与效果无关，纯粹是启用门槛。
##   · 玩家席位有「黄金净收入赤字不许启用科技」那条规则 ⇒ 塞一点黄金产能；
##   · 二本 / 三本科技要求大本营等级够（`tech_max_tier`）⇒ 两方大本营升到 3 级。
## @param upgrade true（默认）= 顺便把两方大本营升到 3 级（二本 / 三本科技才点得动）。
##        礼乐那一节要**保持 1 级**（它测的就是「1 级本来招不了三本兵」），所以传 false。
func _pump_gold(w, upgrade: bool = true) -> void:
	for z in w.zones.zones:
		var zd: Dictionary = z
		var own := String(zd.get("owner", ""))
		if own == "p1" or own == "p2":
			(zd["production"] as Dictionary)["gold"] = 20.0
	if upgrade:
		w.debug_upgrade_base_to_level(3, "p1")
		w.debug_upgrade_base_to_level(3, "p2")
	w.tick(DT)
	w.resources["gold"] = 2000.0
	w.ai_faction_resources["p2"] = {"food": 2000.0, "gold": 2000.0}


func _count_alive(w, faction: String) -> int:
	var n := 0
	for u in w.units:
		if u != null and u.alive and String(u.faction) == faction:
			n += 1
	return n


func _ids(slots: Array) -> Array:
	var out: Array = []
	for e in slots:
		var id := String((e as Dictionary).get("id", ""))
		if id != "":
			out.append(id)
	return out


func _non_empty(slots: Array) -> int:
	return _ids(slots).size()


func _count_empty(slots: Array) -> int:
	return slots.size() - _non_empty(slots)


func _mk_unit(w, cfg, id: String, unit_type: String, faction: String):
	var tile := _open_spot(w, faction, 1)
	if tile.x < 0:
		ok(false, "（前提）给 %s 找到落脚格" % id)
		return null
	var u = UnitRes.create(cfg, id, "测", tile, faction, unit_type, "", "", unit_type, -1)
	w.units.append(u)
	return u


## 同一行上连续 `len` 格都可通行（找不到返回 (-1,-1)）。
func _open_spot(w, faction: String, len: int) -> Vector2i:
	for y in w.map.rows:
		var run := 0
		for x in w.map.cols:
			if w.can_build_at(x, y, faction):
				run += 1
				if run >= len:
					return Vector2i(x - len + 1, y)
			else:
				run = 0
	return Vector2i(-1, -1)



