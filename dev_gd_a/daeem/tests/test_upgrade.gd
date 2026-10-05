## test_upgrade.gd —— 建筑升级 + 区划特化（右下「操作」页签里那几格）
##
## ★★ 需求原话（本轮改版后）：
##   「粮食特化 = 每地块每秒额外产 0.5 粮食，黄金特化 = 每地块每秒额外产 0.5 黄金，
##     人口特化 = 当前区划人口产量 +25%」；
##   「粮食区划仅能进行黄金和人口特化，黄金区划仅能进行粮食和人口特化，
##     人口区划仅能进行粮食和黄金特化」；
##   （读条 / 只能选一个 / 取消特化那几条规则不变：「特化后的区块无法再次特化，
##     但选中特化后的区块可以在操作面板中选择『取消特化』去除其特化，同理，
##     特化也需要读条，取消特化也需要读条」。）
##   ★ 历史：旧版三档都是「本区块产量 +10%」的倍率 —— 那套断言已经全部改掉。
##
## ★ 这里钉**逻辑层**这条链：config 表 → 判定（种类白名单 / 等级上限 / 读条占用 /
##   归属 / 费用）→ 入队即扣费 → 读条 → 落效果（等级与血量 / 本区块产能）→
##   取消与退款 → 命令层。
##   「页签有哪几颗、操作页画哪几格、信息栏那块面板显示什么」在 tests/test_ui.gd 里验。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const DT := 1.0 / 60.0
## 读条一整条（config 里最长的是大本营 3 级的 20 秒）——**一步走完**，
## 靠的是 upgrade.tick 里那套「一帧可能读满好几单」的预算算法。
const BIG_STEP := 60.0


func _initialize() -> void:
	_case_name = "test_upgrade"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_zone_kind_table(cfg)
	_test_reject_rules(cfg)
	_test_upgrade_flow(cfg)
	_test_cancel_refund(cfg)
	_test_upgrade_scales_with_tech(cfg)
	_test_specialize_flow(cfg)
	_test_spec_stacks_with_tech(cfg)
	_test_cancel_spec(cfg)
	_test_commands(cfg)


# ------------------------------------------------------------------
# 一、表来自 config.json（代码里不写死等级 / 数值）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	ok(cfg.has_upgrade("base"), "大本营有升级表")
	ok(cfg.has_upgrade("wall"), "城墙有升级表")
	ok(cfg.has_upgrade("tower"), "箭塔有升级表")
	ok(not cfg.has_upgrade(BuildingRes.TYPE_ZONE_CENTER),
		"★ 区划中心**没有**升级表（它走特化那三个选项）")
	eq(cfg.upgrade_max_level("base"), 3, "★ 大本营最多 3 级（config 里 3 条）")
	eq(cfg.upgrade_max_level("wall"), 3, "城墙最多 3 级")
	near(cfg.upgrade_hp_mult("base", 1), 1.0, 1e-6, "1 级血量倍率 1.0")
	near(cfg.upgrade_hp_mult("base", 2), 1.5, 1e-6, "★ 2 级血量倍率 1.5")
	near(cfg.upgrade_hp_mult("base", 3), 2.25, 1e-6, "★ 3 级血量倍率 2.25")
	var c1: Dictionary = cfg.upgrade_cost_to("base", 1)
	near(float(c1.get("food", 0.0)), 100.0, 1e-6, "升到 2 级要 100 粮食")
	near(cfg.upgrade_time_to("base", 1), 10.0, 1e-6, "升到 2 级读条 10 秒")
	var c2: Dictionary = cfg.upgrade_cost_to("base", 2)
	near(float(c2.get("food", 0.0)), 200.0, 1e-6, "★ 升到 3 级更贵（200 粮食）")
	near(cfg.upgrade_time_to("base", 2), 20.0, 1e-6, "★ 升到 3 级读条更久（20 秒）")
	ok(cfg.upgrade_cost_to("base", 3).is_empty(), "3 级（最高级）没有 next 的价钱")
	near(cfg.upgrade_time_to("base", 3), 0.0, 1e-6, "最高级没有 next 的读条")

	# 特化表
	eq(cfg.spec_list().size(), 3, "★ 三个特化（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_spec(want), "特化表里有 %s" % want)
	# ★★ 粮食 / 黄金特化是「每地块每秒**加** 0.25」，人口特化是「**倍率** +12.5%」——
	#    两种形状不同，所以断言分两条写（旧的 `effect.food == 0.1` 那套已经作废）。
	#    ⚠️ 数值本次下调过：0.5 → 0.25、+25% → +12.5%（与区划基础产量同比例，
	#    见 data/config.json 的 zone_spec._comment）。
	near(float(cfg.spec_entry("food").get("effect", {}).get("food_per_tile", 0.0)), 0.25, 1e-6,
		"★ 粮食特化 = 每地块每秒额外 0.25 粮食")
	near(float(cfg.spec_entry("gold").get("effect", {}).get("gold_per_tile", 0.0)), 0.25, 1e-6,
		"★ 黄金特化 = 每地块每秒额外 0.25 黄金")
	near(float(cfg.spec_entry("population").get("effect", {}).get("population_mult", 0.0)), 0.125, 1e-6,
		"★ 人口特化 = 本区划人口产量 +12.5%")
	near(cfg.spec_time_sec("food"), 10.0, 1e-6, "★ 特化读条 10 秒")
	var sc: Dictionary = cfg.spec_cost("food")
	near(float(sc.get("food", 0.0)), 50.0, 1e-6, "特化要 50 粮食")
	near(float(sc.get("gold", 0.0)), 50.0, 1e-6, "特化要 50 黄金")
	ok(w.building_can_upgrade("base"), "world 转发：大本营能升级")
	ok(not w.building_can_upgrade(BuildingRes.TYPE_ZONE_CENTER), "world 转发：区划中心不能升级")


# ------------------------------------------------------------------
# 一之二、区划种类表（config.json 的 zone_kind 段）—— 本轮新增
# ------------------------------------------------------------------
##
## 需求原话：「游戏中有三种区划，粮食区划，黄金区划，人口区划；粮食区划产量为每地块每秒
## 产 1 粮食，黄金区划产量为每地块每秒产 1 黄金，人口区划是每地块每秒产 0.15 人口」；
## 「粮食区划仅能进行黄金和人口特化，黄金区划仅能进行粮食和人口特化，
## 人口区划仅能进行粮食和黄金特化」。
## 用户另外确认：「没有默认区划了，所有区划默认值都改为人口区划」（所以只有三种，
## 地图没写 kind 的区划算 population）。
func _test_zone_kind_table(cfg) -> void:
	eq(cfg.zone_kind_list().size(), 3, "★ 三种区划（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_zone_kind(want), "种类表里有 %s" % want)
	eq(cfg.zone_kind_default(), "population", "★ 地图没写 kind 时算人口区划（用户确认）")
	ok(not cfg.has_zone_kind("none"), "★ 没有「默认区划」这一档了")
	eq(cfg.zone_kind_name("food"), "粮食区划", "种类名字来自 config")
	# 预设产能：这是**编辑器选种类时同步进数字输入框**的数，不是游戏里的兜底
	# ★★ 本次：三种预设**全部 ×0.5**（与游戏里的基础产量同比例下调）。
	var pf: Dictionary = cfg.zone_kind_production("food")
	near(float(pf["food"]), 0.5, 1e-6, "★ 粮食区划预设 = 每地块每秒 0.5 粮食")
	near(float(pf["gold"]), 0.0, 1e-6, "粮食区划不产黄金")
	near(float(pf["population"]), 0.05, 1e-6,
		"★ 粮食区划也带 0.05 人口（所有区划都带一份人口产能）")
	var pg: Dictionary = cfg.zone_kind_production("gold")
	near(float(pg["gold"]), 0.5, 1e-6, "★ 黄金区划预设 = 每地块每秒 0.5 黄金")
	near(float(pg["population"]), 0.05, 1e-6, "★ 黄金区划也带 0.05 人口")
	var pp: Dictionary = cfg.zone_kind_production("population")
	near(float(pp["population"]), 0.075, 1e-6, "★ 人口区划预设 = 每地块每秒 0.075 人口")
	# ★★ 三种区划**都带一份人口产能**（人口是通用资源，谁都要）——
	#    这里只钉「都 > 0」而不是「都 ≥ 某个具体下限」：那个下限是本轮定过又下调的
	#    数值，钉死它等于每次调配平都要改这条断言（口径本身没变）。
	for kind_id in ["food", "gold", "population"]:
		ok(float(cfg.zone_kind_production(kind_id)["population"]) > 0.0,
			"★ %s 的预设人口产能 > 0（实际 %s）"
			% [kind_id, cfg.zone_kind_production(kind_id)["population"]])
	# ★ 特化白名单（三条需求原文逐条钉住）
	ok(cfg.zone_kind_allows_spec("food", "gold"), "粮食区划能做黄金特化")
	ok(cfg.zone_kind_allows_spec("food", "population"), "粮食区划能做人口特化")
	ok(not cfg.zone_kind_allows_spec("food", "food"), "★ 粮食区划**不能**做粮食特化")
	ok(cfg.zone_kind_allows_spec("gold", "food"), "黄金区划能做粮食特化")
	ok(cfg.zone_kind_allows_spec("gold", "population"), "黄金区划能做人口特化")
	ok(not cfg.zone_kind_allows_spec("gold", "gold"), "★ 黄金区划**不能**做黄金特化")
	ok(cfg.zone_kind_allows_spec("population", "food"), "人口区划能做粮食特化")
	ok(cfg.zone_kind_allows_spec("population", "gold"), "人口区划能做黄金特化")
	ok(not cfg.zone_kind_allows_spec("population", "population"), "★ 人口区划**不能**做人口特化")
	# 认不出来的 kind → 退回默认那一档（手改地图写错时不该崩、也不该多出产量）
	eq(cfg.zone_kind_name("banana"), "人口区划", "认不出的种类 → 默认那一档")
	near(float(cfg.zone_kind_production("banana")["population"]), 0.075, 1e-9,
		"认不出的种类 → 拿默认那一档的预设值")

	# 发布地图的区块种类：**由设计师在编辑器里定**（当前：11 个人口 + a2 粮食 + f2 黄金）。
	#
	# ★ 这里**不再**断言「全部是人口区划」——那是「默认全赋上人口区划」那一轮的事实，
	#   之后设计师按需要把 a2 / f2 改成了粮食 / 黄金区划（用户确认：这是他自己改的）。
	#   地图是设计师手里的东西：把某一版的具体分布写死进断言，改一次图就集体假失败
	#   （同一条教训见 tests/test_smoke.gd 里那句「别再往测试里塞坐标」）。
	#   所以这一节钉的是**读取路径**，而不是那一版数据：
	#     ① 每个区块的种类都认得出来（写错一个 kind 会红）；
	#     ② world 转发的种类 == 区块自己那两个字段（转发/兜底逻辑没漂）。
	#   分布本身只打印出来（一眼看得到当前是什么，但不构成断言）。
	var w = _quiet(cfg)
	var kinds: Dictionary = {}
	var unknown: Array = []
	for z in w.zones.zones:
		var k := String(z["kind"])
		kinds[k] = int(kinds.get(k, 0)) + 1
		if not cfg.has_zone_kind(k):
			unknown.append("%s=%s" % [String(z["name"]), k])
		eq(w.zone_kind_of(z), w.zones.kind_of(z),
			"world 转发的种类 = 区块自己那一格（%s）" % String(z["name"]))
	ok(unknown.is_empty(),
		"★ 发布地图的每个区块都是表里认识的种类（认不出的：%s）" % str(unknown))
	print("   [kinds] 发布地图的区划种类分布：%s（共 %d 块）" % [str(kinds), w.zones.zones.size()])
	eq(w.zone_kind_of(w.zones.zones[0]), w.zones.kind_of(w.zones.zones[0]),
		"world 转发的种类查询（第一个区块）")


# ------------------------------------------------------------------
# 二、判定：谁不能升级（拒因码）
# ------------------------------------------------------------------
func _test_reject_rules(cfg) -> void:
	var w = _quiet(cfg)
	_no_income(w)
	# ★ 先把资源给足：`_no_income` 只清产能、不动资源，而新建世界的资源是 0
	#   （`resource.start_food / start_gold` 都是 0）—— 不给钱的话第一条断言就会
	#   落到 `cost` 上，看着像「判定坏了」。
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var base = w.find_base_of("p1")
	var wall = _player_wall(w)
	ok(base != null, "有己方大本营")
	ok(wall != null, "有己方城墙")
	if base == null or wall == null:
		return
	var f: String = String(w.my_faction)
	eq(UpgradeRes.can_upgrade(w, base, f), "", "平常状态下大本营可以升级")
	eq(UpgradeRes.can_upgrade(w, null, f), "type", "不存在的建筑 → type")
	var zc = _zone_center(w)
	if zc != null:
		eq(UpgradeRes.can_upgrade(w, zc, f), "type", "★ 区划中心不能升级（没有升级表）")
	# 归属：不是自己这一方
	var foe = _enemy_building(w)
	if foe != null:
		eq(UpgradeRes.can_upgrade(w, foe, f), "owner", "★ 别人的建筑不能升级")
	# 钱不够
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	eq(UpgradeRes.can_upgrade(w, base, f), "cost", "★ 钱不够 → cost")
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	# 满级
	base.level = cfg.upgrade_max_level("base")
	eq(UpgradeRes.can_upgrade(w, base, f), "max_level", "★ 满级之后不能再升")
	base.level = 1
	# 读条中
	ok(w.start_building_upgrade(base.tx, base.ty), "开始一次升级")
	eq(UpgradeRes.can_upgrade(w, wall, f), "", "读条中的是**大本营**，城墙照样能升")
	eq(UpgradeRes.can_upgrade(w, base, f), "busy", "★ 读条中再升同一栋 → busy")


# ------------------------------------------------------------------
# 三、升级全流程：扣费 → 读条 → 完成（等级 + 血量）
# ------------------------------------------------------------------
func _test_upgrade_flow(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var wall = _player_wall(w)
	ok(wall != null, "有己方城墙")
	if wall == null:
		return
	var lv0: int = wall.level
	var hp0: float = wall.hp_max
	var cost: Dictionary = w.building_upgrade_cost(wall)
	var food0: float = float(w.resources["food"])
	eq(lv0, 1, "城墙开局 1 级")

	# 走命令层（与界面同一条路）
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": wall.tx, "ty": wall.ty}),
		"★ building_upgrade 命令被接受")
	ok(wall.is_upgrading(), "★ 开始读条（is_upgrading）")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-6,
		"★ 入队即扣粮食")
	near(wall.upgrade_progress(), 0.0, 1e-6, "刚入队时进度是 0")
	near(wall.upgrade_eta(), w.building_upgrade_time(wall), 1e-6, "剩余时间 = 整条读条")
	eq(UpgradeRes.can_upgrade(w, wall, w.my_faction), "busy", "读条中拒绝新的升级请求")

	# 读条一半：还没升级
	var half: float = maxf(0.01, wall.upgrade_total * 0.5)
	w.tick(half)
	eq(wall.level, lv0, "★ 读条没读完时等级不变")
	near(wall.upgrade_progress(), 0.5, 0.02, "进度条走到一半")
	near(wall.hp_max, hp0, 1e-6, "血量上限也还没变")

	# 读完
	w.tick(BIG_STEP)
	ok(not wall.is_upgrading(), "★ 读条结束")
	eq(wall.level, lv0 + 1, "★ 等级 +1")
	var mult: float = cfg.upgrade_hp_mult("wall", wall.level)
	near(wall.hp_max, wall.base_hp_max * mult, 1e-3, "★ 血量上限 = 基础值 × 等级倍率")

	# 当前血量按比例：先打掉一半再升一级，升完还是半血
	var w2 = _quiet(cfg)
	var wall2 = _player_wall(w2)
	_give(w2, 1000.0, 1000.0)
	wall2.hp = wall2.hp_max * 0.5
	w2.start_building_upgrade(wall2.tx, wall2.ty)
	w2.tick(BIG_STEP)
	near(wall2.hp / wall2.hp_max, 0.5, 1e-3, "★ 升级按比例带血（半血的墙升完还是半血）")

	# 升级事件（逻辑层给，界面拿去提示）
	var w3 = _quiet(cfg)
	var wall3 = _player_wall(w3)
	_give(w3, 1000.0, 1000.0)
	w3.start_building_upgrade(wall3.tx, wall3.ty)
	var evts: Array = w3.tick(BIG_STEP)
	var done := false
	for e in evts:
		if String((e as Dictionary).get("type", "")) == "upgrade_done" \
				and String((e as Dictionary).get("kind", "")) == "building_upgrade":
			done = true
	ok(done, "★ 升级完成留了一条 upgrade_done 事件")

	# 满级封顶：再点会被拒（界面那一格那时会画成「已满级」）
	var w4 = _quiet(cfg)
	var base4 = w4.find_base_of("p1")
	_give(w4, 100000.0, 100000.0)
	for i in 5:
		w4.start_building_upgrade(base4.tx, base4.ty)
		w4.tick(BIG_STEP)
	eq(base4.level, cfg.upgrade_max_level("base"), "★ 连点多次也封顶在最高等级")
	near(base4.hp_max, base4.base_hp_max * cfg.upgrade_hp_mult("base", base4.level), 1e-3,
		"满级时的血量上限 = 基础值 × 满级倍率")


# ------------------------------------------------------------------
# 四、取消升级：全额退款、等级不变
# ------------------------------------------------------------------
func _test_cancel_refund(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var wall = _player_wall(w)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	w.start_building_upgrade(wall.tx, wall.ty)
	w.tick(DT * 10)
	ok(wall.is_upgrading(), "还在读条中")
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade_cancel",
		"tx": wall.tx, "ty": wall.ty}), "★ building_upgrade_cancel 命令被接受")
	ok(not wall.is_upgrading(), "★ 读条被取消")
	eq(wall.level, 1, "等级没变")
	near(float(w.resources["food"]), food0, 1e-6, "★ 粮食全额退回")
	near(float(w.resources["gold"]), gold0, 1e-6, "★ 黄金全额退回")
	eq(UpgradeRes.can_cancel_upgrade(wall, w.my_faction), "idle", "没有读条时不能取消")

	# 建筑被打掉：读条作废（不退款 —— 钱花在这栋楼上了）
	var w2 = _quiet(cfg)
	var wall2 = _player_wall(w2)
	_give(w2, 1000.0, 1000.0)
	w2.start_building_upgrade(wall2.tx, wall2.ty)
	ok(wall2.is_upgrading(), "在建的墙在读条")
	w2.remove_building(wall2, true)
	ok(not wall2.is_upgrading(), "★ 建筑离场 → 升级读条作废")


# ------------------------------------------------------------------
# 五、升级与科技叠加（上限 = 基础 × 等级 × 科技）
# ------------------------------------------------------------------
func _test_upgrade_scales_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var wall = _player_wall(w)
	var base_hp: float = wall.base_hp_max
	ok(w.set_tech_active("building_hp", true), "启用「建筑加固」（+10%）")
	near(wall.hp_max, base_hp * 1.1, 1e-3, "科技生效：基础 × 1.1")
	w.start_building_upgrade(wall.tx, wall.ty)
	w.tick(BIG_STEP)
	near(wall.hp_max, base_hp * 1.1 * cfg.upgrade_hp_mult("wall", 2), 1e-3,
		"★ 上限 = 基础 × 等级(1.5) × 科技(1.1)（两者叠加）")
	w.set_tech_active("building_hp", false)
	near(wall.hp_max, base_hp * cfg.upgrade_hp_mult("wall", 2), 1e-3,
		"★ 弃用科技后只剩等级那一份（精确回到 1.5 倍）")


# ------------------------------------------------------------------
# 六、特化全流程：只能选一个、读完生效、只影响本区块
# ------------------------------------------------------------------
func _test_specialize_flow(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	# ★ 地图上默认**只有出生区**是己方（大本营把它收归己方），
	#   所以「只影响本区块」这条要自己再认领一块地（模拟玩家占了第二块）。
	#   ⚠️ 不能按「有没有中心」筛：这张图上 14 个区划**每个都有中心**。
	var other = null
	for z in w.zones.zones:
		if z != mine:
			_claim(w, z)
			other = z
			break
	ok(mine != null, "有己方区划（大本营把它收归己方）")
	ok(other != null, "还有第二块己方区划（用来验「只影响本区块」）")
	if mine == null or other == null:
		return
	_give(w, 1000.0, 1000.0)
	# ⚠️ 产能必须在 `_give` **之后**配（`_give` 会清掉所有区划的产能）
	for z in [mine, other]:
		z["production"] = {"food": 2.0, "gold": 3.0, "population": 1.0}
	var n_mine := float(mine["tile_count"])
	var n_other := float(other["tile_count"])
	var f: String = String(w.my_faction)
	var zid := int(mine["id"])

	eq(UpgradeRes.can_specialize(w, mine, "food", f), "", "平常状态下可以做粮食特化")
	eq(UpgradeRes.can_specialize(w, mine, "nope", f), "spec", "不存在的特化 → spec")
	eq(UpgradeRes.can_specialize(w, null, "food", f), "zone", "没有区划 → zone")
	# ★★ 本轮：种类白名单（发布地图的区划都是人口区划 → 只能做粮食 / 黄金特化）
	eq(String(mine["kind"]), "population", "（前提）这一块是人口区划")
	eq(UpgradeRes.can_specialize(w, mine, "population", f), "kind",
		"★ 人口区划做不了人口特化（拒因 kind）")
	eq(UpgradeRes.spec_choices(mine, cfg).size(), 2,
		"★ 人口区划的操作页只有两格特化（粮食 / 黄金）")
	var foreign = _foreign_zone(w)
	if foreign != null:
		eq(UpgradeRes.can_specialize(w, foreign, "food", f), "zone",
			"★ 不是自己的区划不能特化")

	var food0: float = float(w.resources["food"])
	ok(CommandRes.apply(w, w.cfg, {"kind": "zone_specialize", "zone_id": zid, "spec": "food"}),
		"★ zone_specialize 命令被接受")
	ok(UpgradeRes.zone_is_busy(mine), "★ 开始读条")
	eq(String(mine.get("spec_done", "")), "", "读条中还没生效（spec_done 还是空的）")
	near(float(w.resources["food"]), food0 - float(cfg.spec_cost("food").get("food", 0.0)), 1e-6,
		"★ 入队即扣粮食")
	eq(UpgradeRes.can_specialize(w, mine, "gold", f), "busy", "★ 读条中拒绝别的特化")
	near(UpgradeRes.zone_spec_progress(mine, cfg), 0.0, 1e-6, "刚入队进度 0")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6,
		"★ 读条还没读完 → 加成还没生效")

	# 读条一半：还没生效
	w.tick(5.0)
	near(UpgradeRes.zone_spec_progress(mine, cfg), 0.5, 0.05, "读条走到一半")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6, "一半时加成仍未生效")

	# 读完
	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "★ 读条结束")
	eq(String(mine.get("spec_done", "")), "food", "★ 特化生效（spec_done = food）")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.25, 1e-6,
		"★ 粮食特化 = 每地块每秒 +0.25 粮食")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["gold_per_tile"], 0.0, 1e-6,
		"黄金不受粮食特化影响")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["population_mult"], 1.0, 1e-6,
		"人口倍率不受粮食特化影响")

	# 产能：本区块每地块 +0.25（加在它自己的产能上），别的区块不变
	var rates: Dictionary = w.zones.production_of(f)
	near(float(rates["food"]), (2.0 + 0.25) * n_mine + 2.0 * n_other, 1e-3,
		"★ 粮食产出 = 本区块（2 + 0.25）× 地块 + 别的区块不变")
	near(float(rates["gold"]), 3.0 * n_mine + 3.0 * n_other, 1e-3, "黄金产出不变")

	# 只能选一个：已特化 → 别的特化被拒（命令也不该生效）
	eq(UpgradeRes.can_specialize(w, mine, "gold", f), "spec_done",
		"★ 特化过的区块无法再次特化（spec_done）")
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "zone_specialize", "zone_id": zid, "spec": "gold"}),
		"★ 换一个特化的命令也走不通")
	eq(String(mine.get("spec_done", "")), "food", "★ 还是原来的粮食特化")

	# 人口特化同样只加本区块的增长速度（★ 本轮：×1.25 的倍率形状，不是每地块加产量）
	#
	# ⚠️ 资源直接写（不用 `_give()`）：本段要的正是产能，而 `_give()` 会把它清掉。
	# ⚠️ 人口特化只能由**粮食区划 / 黄金区划**做（人口区划做不了自己的特化），
	#    所以这里先把它的种类改成粮食区划。
	var w2 = _quiet(cfg)
	w2.resources["food"] = 1000.0
	w2.resources["gold"] = 1000.0
	var z2 = _own_zone(w2)
	var z3 = null
	for z in w2.zones.zones:
		if z != z2:
			_claim(w2, z)
			z3 = z
			break
	ok(z3 != null, "（人口特化那条用例也要第二块己方区划）")
	if z3 == null:
		return
	z2["kind"] = "food"
	eq(UpgradeRes.can_specialize(w2, z2, "population", w2.my_faction), "",
		"★ 粮食区划可以做人口特化")
	for z in [z2, z3]:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 2.0}
		z["population"] = 0.0
		z["population_cap"] = 1000.0
	# ★ 断言「配好了」：这一段的期望值全靠这两块地的产能，配错了要一眼看出来
	near(float((z2["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）本区块人口产能 2")
	near(float((z3["production"] as Dictionary)["population"]), 2.0, 1e-6,
		"（前提）另一块地人口产能 2")
	ok(w2.start_zone_specialize(int(z2["id"]), "population"), "（前提）人口特化入队")
	w2.tick(BIG_STEP)
	eq(String(z2.get("spec_done", "")), "population", "人口特化生效")
	near(UpgradeRes.zone_spec_effect(z2, cfg)["population_mult"], 1.125, 1e-6,
		"★ 人口特化 = 人口产量 ×1.125")
	# ★ 把两块地都归零，再各跑一秒 —— 这样算的是「一秒钟涨了多少」，与 tick 期间
	#   已经涨过的量无关（tick 里本来也会按秒推进人口）。
	z2["population"] = 0.0
	z3["population"] = 0.0
	w2.zones.update_population(1.0, w2.my_faction, w2.tech_population_mult())
	near(float(z2["population"]), 2.0 * float(z2["tile_count"]) * 1.125, 1e-3,
		"★ 本区块人口涨快 12.5%")
	near(float(z3["population"]), 2.0 * float(z3["tile_count"]), 1e-3,
		"★ 别的区块不受影响")

	# 特化跟着地块走：区划易主后特化**保留**
	mine["owner"] = "p2"
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.25, 1e-6,
		"★ 区划易主后特化保留（谁占谁吃加成）")
	mine["owner"] = f


# ------------------------------------------------------------------
# 七、特化与科技叠加
# ------------------------------------------------------------------
func _test_spec_stacks_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	var mine = _own_zone(w)
	if mine == null:
		ok(false, "有己方区划")
		return
	_give(w, 1000.0, 1000.0)
	# ⚠️ 产能必须在 `_give` **之后**配 —— `_give` 会清掉所有区划的产能
	mine["production"] = {"food": 1.0, "gold": 0.0, "population": 0.0}
	# ★ 先记下「没有特化时的产能」：免得把「产能表里还有别的区块」这种事算漏
	var base: float = float(w.zones.production_of(w.my_faction)["food"])
	var tiles_n := float(mine["tile_count"])
	near(base, 1.0 * tiles_n, 1e-3, "（前提）只有本区块的产能")
	w.start_zone_specialize(int(mine["id"]), "food")
	w.tick(BIG_STEP)
	near(w.production_food, base + 0.25 * tiles_n, 1e-3,
		"★ 只有特化时：本区块每地块 +0.25 粮食")
	# 科技：每地块加产量（乘的是**占领地块数**，不是产能）—— 与特化是**同一口径**的加法
	ok(w.set_tech_active("food_1", true), "再启用科技「粮食 +1/地块/秒」")
	var tiles: int = int(w.owned_tiles)
	near(w.production_food, base + 0.25 * tiles_n + 1.0 * float(tiles), 1e-3,
		"★ 特化（每地块 +0.25）与科技（每地块 +1）相加，都乘在占领地块数上")


# ------------------------------------------------------------------
# 八、取消特化：也要读条，读完去掉特化并退款
# ------------------------------------------------------------------
func _test_cancel_spec(cfg) -> void:
	# ★★ 这一段**不做粮食对账**（只验特化 / 取消 / 退款这条链），所以把产能清零，
	#    并且**对黄金对账**：粮食特化本身会给区划加 0.25 粮食／地块／秒
	#    （旧的「×1.1 倍率」乘在 0 产能上还是 0，所以从前不需要这条讲究）。
	#    黄金那边没有任何加成，读条跑 60 秒也一动不动，「扣了多少 / 退了多少」才算得准。
	var w = _quiet(cfg)
	_no_income(w)
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	var mine = _own_zone(w)
	var f: String = String(w.my_faction)
	var cost: Dictionary = cfg.spec_cost("food")
	var gold0: float = float(w.resources["gold"])
	ok(w.start_zone_specialize(int(mine["id"]), "food"), "（前提）粮食特化入队")
	near(float(w.resources["gold"]), gold0 - float(cost.get("gold", 0.0)), 1e-6,
		"★ 入队即扣 50 黄金")
	w.tick(BIG_STEP)
	eq(String(mine.get("spec_done", "")), "food", "先做一次粮食特化")

	# 取消特化：**也要读条**
	ok(CommandRes.apply(w, w.cfg, {"kind": "zone_spec_cancel", "zone_id": int(mine["id"])}),
		"★ zone_spec_cancel 命令被接受")
	ok(UpgradeRes.zone_is_busy(mine), "★ 取消特化也要读条")
	ok(UpgradeRes.zone_spec_is_cancel(mine), "这一条读条标成「取消特化」")
	eq(String(mine.get("spec_done", "")), "food",
		"★ 读条期间特化**仍然生效**（读完才去掉）")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.25, 1e-6, "加成还在")
	w.tick(BIG_STEP)
	ok(not UpgradeRes.zone_is_busy(mine), "读条结束")
	eq(String(mine.get("spec_done", "")), "", "★ 特化被去掉")
	near(UpgradeRes.zone_spec_effect(mine, cfg)["food_per_tile"], 0.0, 1e-6, "加成没了")
	near(float(w.resources["gold"]), gold0, 1e-6, "★ 读完退回当初特化花掉的黄金")

	# 没特化过 → 没什么可取消
	eq(UpgradeRes.can_cancel_spec(mine, f), "idle", "没特化过时不能取消特化")

	# 读条中的那一单可以撤掉（退款），撤掉之后**特化还在**
	var w2 = _quiet(cfg)
	_no_income(w2)
	w2.resources["food"] = 1000.0
	w2.resources["gold"] = 1000.0
	var z2 = _own_zone(w2)
	var food2: float = float(w2.resources["food"])
	ok(w2.start_zone_specialize(int(z2["id"]), "gold"), "（前提）黄金特化入队")
	w2.tick(2.0)
	ok(CommandRes.apply(w2, w2.cfg, {"kind": "zone_spec_bar_cancel", "zone_id": int(z2["id"])}),
		"★ zone_spec_bar_cancel 命令被接受")
	ok(not UpgradeRes.zone_is_busy(z2), "读条被撤掉")
	eq(String(z2.get("spec_done", "")), "", "★ 那一单没生效（没特化）")
	near(float(w2.resources["food"]), food2, 1e-6, "★ 撤单全额退款")

	# 「取消特化」那条读条**不可再取消**（没有「取消取消」）
	var w3 = _quiet(cfg)
	_no_income(w3)
	w3.resources["food"] = 1000.0
	w3.resources["gold"] = 1000.0
	var z3 = _own_zone(w3)
	ok(w3.start_zone_specialize(int(z3["id"]), "food"), "（前提）粮食特化入队")
	w3.tick(BIG_STEP)
	ok(w3.cancel_zone_specialize(int(z3["id"])), "（前提）发起取消特化")
	eq(UpgradeRes.can_cancel_spec_bar(z3, w3.my_faction), "idle",
		"（取消特化的读条不算「可撤单的特化读条」）")
	ok(UpgradeRes.zone_spec_is_cancel(z3), "它还是「取消特化」那条读条")
	w3.tick(BIG_STEP)
	eq(String(z3.get("spec_done", "")), "", "读完还是把特化去掉了")


# ------------------------------------------------------------------
# 九、命令层：形状与拒因
# ------------------------------------------------------------------
func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var base = w.find_base_of("p1")
	# 不存在的地块
	ok(not CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": -1, "ty": -1}),
		"越界地块的升级命令被拒")
	# 区划中心的升级命令（没有升级表）
	var zc = _zone_center(w)
	if zc != null:
		ok(not CommandRes.apply(w, w.cfg,
			{"kind": "building_upgrade", "tx": zc.tx, "ty": zc.ty}),
			"★ 区划中心不能升级（命令被拒）")
	# 钱不够：留一条 upgrade_rejected 事件给界面
	w.resources["food"] = 0.0
	w.resources["gold"] = 0.0
	ok(not CommandRes.apply(w, w.cfg,
		{"kind": "building_upgrade", "tx": base.tx, "ty": base.ty}),
		"钱不够时升级命令被拒")
	var got := false
	var got_faction := ""
	var got_building := false
	for e in w.tick(DT):
		if String((e as Dictionary).get("type", "")) == "upgrade_rejected":
			got = true
			got_faction = String((e as Dictionary).get("faction", "<无>"))
			got_building = (e as Dictionary).get("building", null) != null
	ok(got, "★ 被拒时留了一条 upgrade_rejected 事件（界面拿去显示红字）")
	# ★★ 事件必须带 `faction` 与对象：界面要靠前者**过滤掉别人的报错**
	#   （实测 bug：阵营 AI 也会升级自己的建筑，它的被拒事件被界面当成玩家的消息显示，
	#    于是玩家看到「城墙正在读条…」这种别人的消息刷屏）。
	ok(got_faction != "<无>",
		"★★ 被拒事件带上了 faction（界面才能只显示自己这一方的）实际=%s" % got_faction)
	ok(got_building, "★ 被拒事件带着那栋建筑（`busy` 的文案要点名是哪个对象）")
	# 未知命令照旧被拒
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")


# ------------------------------------------------------------------
# 小工具（与其它逻辑测试同一套做法）
# ------------------------------------------------------------------

func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world(c)


func _give(w, food: float, gold: float) -> void:
	# ★ 顺手清掉区划产能：这一组用例全都要**对账**（扣了多少 / 退了多少），
	#   而读条动辄跑 60 秒 —— 不清产能的话资源一路在涨，断言根本算不准。
	_no_income(w)
	w.resources["food"] = food
	w.resources["gold"] = gold


## 把区划产能清零：**要对账的用例必须先调它** —— 否则 tick 期间粮食 / 黄金一直在涨，
## 「扣了多少 / 退了多少」这类断言算不准（读条动不动就跑 60 秒）。
func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 把某一块区划划归玩家（测试要「两块己方区划」时用）——地图上默认只有出生区一块。
func _claim(w, zone) -> void:
	zone["owner"] = w.my_faction


func _own_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) == w.my_faction:
			return z
	return null


func _foreign_zone(w):
	for z in w.zones.zones:
		if String(z["owner"]) != w.my_faction:
			return z
	return null


func _player_wall(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL \
				and String(b.owner) == w.my_faction:
			return b
	return null


func _zone_center(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_ZONE_CENTER:
			return b
	return null


func _enemy_building(w):
	for b in w.building_list:
		if b.alive and String(b.owner) != "" and String(b.owner) != w.my_faction:
			return b
	return null
