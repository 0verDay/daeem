## test_upgrade.gd —— 建筑升级（大本营「操作」页 + 拖建筑牌到同种建筑上）
##
## ★★ 2026.11.17 口径（用户确认）：
##   · **大本营 + 五种非城墙建筑**（哨塔 / 警戒塔 / 粮田 / 房屋 / 矿脉）可以升级；
##     木墙 / 石墙没有等级表 ⇒ 不能升；
##   · 升级**全部瞬时**：没有读条、没有取消退款，升完**当场补满血**；
##   · 花费：大本营 200/200（config 写在目标行）；其余五种 = **建造消耗**
##     （`upgrade_cost_to` 在目标行没写 cost 时回落到 `building.<type>.cost`）；
##   · 等级上限 = config 等级表条数（大本营 3、其余五种 2），与模型档数一致；
##   · 木墙/石墙/区划中心 `has_upgrade` = false；`building_can_upgrade()` 只对大本营为真
##     （「操作」页只有大本营那一格，其余五种走拖拽）。
extends "res://tests/test_case.gd"

const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const DT := 1.0 / 60.0
const BIG_STEP := 60.0
## 可拖拽升级的五种（与 config.upgrade.levels 里的非 base 键一致）
const UPGRADABLE := ["tower", "watch_tower", "farm", "house", "mine"]

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
	_test_instant_upgrade(cfg)
	_test_hp_refill(cfg)
	_test_base_instant(cfg)
	_test_max_level(cfg)
	_test_upgrade_targets(cfg)
	_test_commands(cfg)
	_test_upgrade_scales_with_tech(cfg)

func _test_config_table(cfg) -> void:
	var w = _quiet(cfg)
	ok(cfg.has_upgrade("base"), "大本营有升级表")
	ok(cfg.has_upgrade(BuildingRes.TYPE_ZONE_CENTER) == false,
		"★ 区划中心没有升级表")
	for t in UPGRADABLE:
		ok(cfg.has_upgrade(t), "★★ %s 有升级表（拖拽升级用）" % t)
		eq(cfg.upgrade_max_level(t), 2, "★★ %s 最多 2 级（与模型档数一致）" % t)
	ok(not cfg.has_upgrade(BuildingRes.TYPE_WALL), "★★ 木墙没有升级表")
	ok(not cfg.has_upgrade(BuildingRes.TYPE_STONE_WALL), "★★ 石墙没有升级表")

	eq(cfg.upgrade_max_level("base"), 3, "★ 大本营最多 3 级（config 里 3 条）")
	eq(cfg.upgrade_max_level("wall"), 1, "★★ 木墙不能升级（最大等级 1）")
	near(cfg.upgrade_hp_mult("base", 1), 1.0, 1e-6, "1 级血量倍率 1.0")
	near(cfg.upgrade_hp_mult("base", 2), 1.5, 1e-6, "★ 2 级血量倍率 1.5")
	near(cfg.upgrade_hp_mult("base", 3), 2.25, 1e-6, "★ 3 级血量倍率 2.25")
	near(cfg.upgrade_hp_mult("tower", 2), 1.5, 1e-6, "★★ 哨塔 2 级也 ×1.5（占位数值）")

	var c1: Dictionary = cfg.upgrade_cost_to("base", 1)
	near(float(c1.get("food", 0.0)), 200.0, 1e-6, "升 2 本要 200 粮食")
	var c2: Dictionary = cfg.upgrade_cost_to("base", 2)
	near(float(c2.get("food", 0.0)), 200.0, 1e-6, "升 3 本与 2 本同价（200 粮食）")

	# ★★ 其余五种：目标行没写 cost ⇒ 自动等于建造消耗
	for t in UPGRADABLE:
		var build_cost: Dictionary = cfg.get_path_value("building.%s.cost" % t)
		var up_cost: Dictionary = cfg.upgrade_cost_to(t, 1)
		near(float(up_cost.get("food", 0.0)), float(build_cost.get("food", 0.0)), 1e-6,
			"★★ %s 的升级粮食 = 建造粮食" % t)
		near(float(up_cost.get("gold", 0.0)), float(build_cost.get("gold", 0.0)), 1e-6,
			"★★ %s 的升级黄金 = 建造黄金（用户口径：升级消耗与建造消耗相同）" % t)
		ok(cfg.upgrade_cost_to(t, 2).is_empty(), "%s 满级后没有价钱" % t)

	# ★★ 全部瞬时：没有读条秒数
	near(cfg.upgrade_time_to("base", 1), 0.0, 1e-6, "★★ 升 2 本没有读条（瞬时）")
	near(cfg.upgrade_time_to("base", 2), 0.0, 1e-6, "★★ 升 3 本没有读条（瞬时）")
	for t in UPGRADABLE:
		near(cfg.upgrade_time_to(t, 1), 0.0, 1e-6, "★★ %s 升级没有读条" % t)

	# 「操作」页那一格：只有大本营（其余五种走拖拽，用户口径）
	ok(w.building_can_upgrade("base"), "world 转发：大本营能升级")
	ok(not w.building_can_upgrade(BuildingRes.TYPE_WALL), "★★ world 转发：木墙不能升级")
	for t in UPGRADABLE:
		ok(not w.building_can_upgrade(t),
			"★ %s 不在「操作」页升级（入口只有拖拽）" % t)

func _test_zone_kind_table(cfg) -> void:
	eq(cfg.zone_kind_list().size(), 3, "★ 三种区划（粮食 / 黄金 / 人口）")
	for want in ["food", "gold", "population"]:
		ok(cfg.has_zone_kind(want), "种类表里有 %s" % want)
	eq(cfg.zone_kind_default(), "population", "★ 地图没写 kind 时算人口区划（用户确认）")
	ok(not cfg.has_zone_kind("none"), "★ 没有「默认区划」这一档了")
	eq(cfg.zone_kind_name("food"), "粮食区划", "种类名字来自 config")
	var pf: Dictionary = cfg.zone_kind_production("food")
	near(float(pf["food"]), 1.5, 1e-6, "★ 粮食区划预设 = 每秒 1.5 粮食")
	near(float(pf["gold"]), 0.0, 1e-6, "粮食区划不产黄金")
	near(float(pf["population"]), 0.15, 1e-6,
		"★ 粮食区划也带 0.15 人口（所有区划都带一份人口产能）")
	var pg: Dictionary = cfg.zone_kind_production("gold")
	near(float(pg["gold"]), 1.2, 1e-6, "★ 黄金区划预设 = 每秒 1.2 黄金（降幅最大）")
	near(float(pg["population"]), 0.15, 1e-6, "★ 黄金区划也带 0.15 人口")
	var pp: Dictionary = cfg.zone_kind_production("population")
	near(float(pp["population"]), 0.4, 1e-6, "★ 人口区划预设 = 每秒 0.4 人口")
	near(float(pp["food"]), 0.8, 1e-6, "★ 人口区划也产粮（每秒 0.8 粮食）")
	near(float(pp["gold"]), 0.0, 1e-6, "人口区划不产黄金")
	for kind_id in ["food", "gold", "population"]:
		ok(float(cfg.zone_kind_production(kind_id)["population"]) > 0.0,
			"★ %s 的预设人口产能 > 0（实际 %s）"
			% [kind_id, cfg.zone_kind_production(kind_id)["population"]])
	eq(cfg.zone_kind_name("banana"), "人口区划", "认不出的种类 → 默认那一档")
	near(float(cfg.zone_kind_production("banana")["population"]), 0.4, 1e-9,
		"认不出的种类 → 拿默认那一档的预设值（人口区划 0.4）")

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


func _test_reject_rules(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var f: String = String(w.my_faction)
	var base = _ready_base(w)
	var tower = _add(w, "tower", f)
	var wall = _player_wall(w)
	ok(base != null and tower != null and wall != null, "（前提）有己方大本营 / 哨塔 / 木墙")
	if base == null or tower == null or wall == null:
		return
	eq(UpgradeRes.can_upgrade(w, base, f), "", "平常状态下大本营可以升级")
	eq(UpgradeRes.can_upgrade(w, tower, f), "", "★★ 自己的哨塔可以升级（拖拽那条路）")
	eq(UpgradeRes.can_upgrade(w, null, f), "type", "不存在的建筑 → type")
	eq(UpgradeRes.can_upgrade(w, wall, f), "type", "★★ 木墙不能升级（没有等级表）")
	var zc = _zone_center(w)
	if zc != null:
		eq(UpgradeRes.can_upgrade(w, zc, f), "type", "★ 区划中心不能升级（没有升级表）")

	# 别人的建筑 / 被中立化
	var foe = _enemy_building(w)
	if foe != null:
		eq(UpgradeRes.can_upgrade(w, foe, f), "owner", "★ 别人的建筑不能升级")
	base.neutralized = true
	eq(UpgradeRes.can_upgrade(w, base, f), "neutralized", "★ 大本营中立化后不能升级")
	base.neutralized = false

	# 钱不够
	_give(w, 0.0, 0.0)
	eq(UpgradeRes.can_upgrade(w, tower, f), "cost", "★ 钱不够 → cost")
	_give(w, 1000.0, 1000.0)

	# 满级
	tower.level = cfg.upgrade_max_level("tower")
	eq(UpgradeRes.can_upgrade(w, tower, f), "max_level", "★ 满级之后不能再升")
	tower.level = 1

	# 还在建造中
	var fresh = _add(w, "watch_tower", f, false)
	if fresh != null:
		ok(fresh.is_under_construction(), "（前提）这栋还在建造中")
		eq(UpgradeRes.can_upgrade(w, fresh, f), "building", "★★ 建造中不能升级 → building")
		fresh.build_total = 0.0
		eq(UpgradeRes.can_upgrade(w, fresh, f), "", "★ 建好之后就能升了")


## 瞬时升级：松手/点下去当场 +1 级，没有读条，扣钱、推 upgrade_done。
func _test_instant_upgrade(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var f: String = String(w.my_faction)
	var tower = _add(w, "tower", f)
	if tower == null:
		ok(false, "（前提）建了一座哨塔")
		return
	var cost: Dictionary = w.building_upgrade_cost(tower)
	var food0: float = float(w.resources["food"])
	var gold0: float = float(w.resources["gold"])
	eq(int(tower.level), 1, "哨塔开局 1 级")

	ok(UpgradeRes.start_upgrade(w, tower, f), "★ 开始升级（瞬时）")
	eq(int(tower.level), 2, "★★ 当场就是 2 级（没有读条）")
	ok(not tower.is_upgrading(), "★★ 不会停在「升级中」")
	near(float(w.resources["food"]), food0 - float(cost.get("food", 0.0)), 1e-6,
		"★ 当场扣粮食")
	near(float(w.resources["gold"]), gold0 - float(cost.get("gold", 0.0)), 1e-6,
		"★ 当场扣黄金")
	near(tower.hp_max, tower.base_hp_max * cfg.upgrade_hp_mult("tower", 2), 1e-3,
		"★ 血量上限 = 基础值 × 2 级倍率")

	var evts: Array = w.tick(DT)
	var done := 0
	var started := 0
	for e in evts:
		var et := String((e as Dictionary).get("type", ""))
		if et == "upgrade_done" and String((e as Dictionary).get("kind", "")) == "building_upgrade":
			done += 1
			eq(String((e as Dictionary).get("faction", "")), f, "★ upgrade_done 带 faction")
		elif et == "upgrade_started":
			started += 1
	eq(done, 1, "★ 推了一条 upgrade_done")
	eq(started, 0, "★★ 瞬时升级**不推** upgrade_started")

	# 再升一次 = 已满级，被拒
	ok(not UpgradeRes.start_upgrade(w, tower, f), "满级后再升被拒")
	eq(int(tower.level), 2, "★★ 上限 2 级：再升也不会超")
	eq(UpgradeRes.can_upgrade(w, tower, f), "max_level", "★★ 满级 → max_level")


## ★★ 升级**当场补满血**（用户口径 2026.11.17；不是按比例带过去）。
func _test_hp_refill(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var f: String = String(w.my_faction)
	var tower = _add(w, "tower", f)
	if tower == null:
		ok(false, "（前提）建了一座哨塔")
		return
	tower.hp = tower.hp_max * 0.4
	near(tower.hp / tower.hp_max, 0.4, 1e-3, "（摆场面）哨塔只剩四成血")
	ok(UpgradeRes.start_upgrade(w, tower, f), "升级哨塔")
	near(tower.hp, tower.hp_max, 1e-3, "★★ 升级后血量**补满**（不是 40%）")
	ok(tower.hp_max > 0.0, "血量上限有效")


## 大本营也瞬时：1→2 不要将领门槛；2→3 要 2 名将领（config.need_generals）。
func _test_base_instant(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	var f: String = String(w.my_faction)
	var base = _ready_base(w)
	if base == null:
		ok(false, "（前提）有大本营")
		return
	base.level = 1
	_ensure_generals(w, 0, f)
	ok(UpgradeRes.start_upgrade(w, base, f), "★ 1 将都不要也能升 2 本")
	eq(int(base.level), 2, "★★ 当场 2 级")
	near(base.hp, base.hp_max, 1e-3, "★★ 升级补满血")
	near(base.hp_max, base.base_hp_max * 1.5, 1e-3, "★ 2 本血量上限 ×1.5")
	eq(w.base_level_of(f), 2, "★ 大本营等级查询当场读到 2")

	# 2 → 3 要 2 名将领
	base.level = 2
	_ensure_generals(w, 1, f)
	eq(UpgradeRes.can_upgrade(w, base, f), "generals",
		"★★ 只有 1 将时不能升 3 本（门槛 2 将）")
	ok(not w.start_building_upgrade(base.tx, base.ty, f), "★ 升级命令被拒")
	eq(int(base.level), 2, "等级没变")
	_ensure_generals(w, 2, f)
	ok(w.start_building_upgrade(base.tx, base.ty, f), "★ 2 将之后可以升 3 本")
	eq(int(base.level), 3, "★★ 当场 3 级")
	near(base.hp_max, base.base_hp_max * 2.25, 1e-3, "★ 3 本血量上限 ×2.25")

	# 重生队列非空 → 不能开新的升级
	var w2 = _quiet(cfg)
	_give(w2, 10000.0, 10000.0)
	var b2 = _ready_base(w2)
	_ensure_generals(w2, 2, String(w2.my_faction))
	if b2 != null:
		b2.enqueue_respawn(w2.units[0], 5.0)
		eq(UpgradeRes.can_upgrade(w2, b2, String(w2.my_faction)), "respawning",
			"★★ 重生队列非空 → 拒因 respawning")
		b2.clear_respawn_queue()
		eq(UpgradeRes.can_upgrade(w2, b2, String(w2.my_faction)), "",
			"★★ 队列清空后恢复可升级")


## 满级封顶：多升几次也停在最高级，钱不会白扣。
func _test_max_level(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 100000.0, 100000.0)
	var f: String = String(w.my_faction)
	var base = _ready_base(w)
	if base == null:
		ok(false, "（前提）有大本营")
		return
	_ensure_generals(w, 6, f)
	for i in 5:
		w.start_building_upgrade(base.tx, base.ty, f)
		w.tick(BIG_STEP)
	eq(int(base.level), cfg.upgrade_max_level("base"), "★ 连点多次也封顶在最高等级")
	near(base.hp_max, base.base_hp_max * cfg.upgrade_hp_mult("base", base.level), 1e-3,
		"满级时的血量上限 = 基础值 × 满级倍率")

	var w2 = _quiet(cfg)
	_give(w2, 100000.0, 100000.0)
	var tower2 = _add(w2, "tower", String(w2.my_faction))
	if tower2 != null:
		for i in 4:
			w2.start_building_upgrade(tower2.tx, tower2.ty, String(w2.my_faction))
		eq(int(tower2.level), 2, "★★ 哨塔封顶在 2 级")


## 拖拽高亮 / 吸附的数据源：同类型 + 己方 + 没满级 + 不在建造中。
func _test_upgrade_targets(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var f: String = String(w.my_faction)
	var tower = _add(w, "tower", f)
	if tower == null:
		ok(false, "（前提）建了一座哨塔")
		return
	var targets: Dictionary = w.building_upgrade_targets("tower", f)
	ok(targets.has(Vector2i(tower.tx, tower.ty)), "★ 自己的哨塔出现在可升级列表里")
	eq(targets[Vector2i(tower.tx, tower.ty)], tower, "★ 列表里就是那栋建筑对象")
	ok(w.building_upgrade_targets("wall", f).is_empty(), "★★ 木墙永远没有可升级目标")
	ok(w.building_upgrade_targets("base", f).is_empty() or
		not w.building_upgrade_targets("base", f).has(Vector2i(-1, -1)),
		"★ 大本营不在拖拽列表（入口是操作页）")

	tower.level = cfg.upgrade_max_level("tower")
	ok(not w.building_upgrade_targets("tower", f).has(Vector2i(tower.tx, tower.ty)),
		"★★ 满级的哨塔不再高亮")
	tower.level = 1

	# 建造中的不算
	var fresh = _add(w, "watch_tower", f, false)
	if fresh != null:
		ok(not w.building_upgrade_targets("watch_tower", f).has(Vector2i(fresh.tx, fresh.ty)),
			"★★ 还在建造中的不出现在可升级列表里")

	# 别人的同种建筑不算
	var foe = _enemy_building(w)
	if foe != null:
		var list: Dictionary = w.building_upgrade_targets(String(foe.type), f)
		ok(not list.has(Vector2i(foe.tx, foe.ty)), "★ 别人的建筑不在可升级列表里")


func _test_commands(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 1000.0, 1000.0)
	var f: String = String(w.my_faction)
	var tower = _add(w, "tower", f)
	if tower == null:
		ok(false, "（前提）建了一座哨塔")
		return
	ok(CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": tower.tx, "ty": tower.ty}),
		"★ building_upgrade 命令被接受（哨塔）")
	eq(int(tower.level), 2, "★★ 命令落下去当场 2 级")

	ok(not CommandRes.apply(w, w.cfg, {"kind": "building_upgrade", "tx": -1, "ty": -1}),
		"越界地块的升级命令被拒")
	var zc = _zone_center(w)
	if zc != null:
		ok(not CommandRes.apply(w, w.cfg,
			{"kind": "building_upgrade", "tx": zc.tx, "ty": zc.ty}),
			"★ 区划中心不能升级（命令被拒）")
	var wall = _player_wall(w)
	if wall != null:
		ok(not CommandRes.apply(w, w.cfg,
			{"kind": "building_upgrade", "tx": wall.tx, "ty": wall.ty}),
			"★★ 木墙不能升级（命令被拒）")

	# 钱不够 → 拒绝事件带 faction
	var w2 = _quiet(cfg)
	_give(w2, 0.0, 0.0)
	var t2 = _add(w2, "tower", String(w2.my_faction))
	if t2 != null:
		ok(not CommandRes.apply(w2, w2.cfg,
			{"kind": "building_upgrade", "tx": t2.tx, "ty": t2.ty}),
			"钱不够时升级命令被拒")
		var got := false
		var got_faction := ""
		var got_building := false
		for e in w2.tick(DT):
			if String((e as Dictionary).get("type", "")) == "upgrade_rejected":
				got = true
				got_faction = String((e as Dictionary).get("faction", "<无>"))
				got_building = (e as Dictionary).get("building", null) != null
		ok(got, "★ 被拒时留了一条 upgrade_rejected 事件")
		ok(got_faction != "<无>", "★★ 被拒事件带上了 faction（实际=%s）" % got_faction)
		ok(got_building, "★ 被拒事件带着那栋建筑")
	ok(not CommandRes.apply(w, w.cfg, {"kind": "not_a_command"}), "未知命令被拒")


func _test_upgrade_scales_with_tech(cfg) -> void:
	var w = _quiet(cfg)
	_give(w, 10000.0, 10000.0)
	# 「建筑加固」是三阶科技：先把大本营拉到 3 级（等级限制由 test_base_limits 专门验）。
	var base = _ready_base(w)
	if base == null:
		return
	var base_hp: float = base.base_hp_max
	base.level = w.cfg.upgrade_max_level("base")
	w.apply_building_level_hp(base)
	instant_tech(w, "building_hp")       # 直接启用，绕开「黄金赤字」规则
	ok(w.is_tech_active("building_hp"), "启用「建筑加固」（+10%）")
	near(base.hp_max, base_hp * cfg.upgrade_hp_mult("base", 3) * 1.1, 1e-3,
		"★ 上限 = 基础 × 等级(2.25) × 科技(1.1)（两者叠加）")
	ok(not w.set_tech_active("building_hp", false), "★ 建筑加固不可取消")
	near(base.hp_max, base_hp * cfg.upgrade_hp_mult("base", 3) * 1.1, 1e-3,
		"★ 取消命令后科技仍然生效（上限保持 2.25 × 1.1）")


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------

func _ensure_generals(w, n: int, faction: String) -> void:
	var idx := 1
	while w.general_count_of(faction) < n and idx < 64:
		var g = w.create_general(faction, idx, 1000 + idx)
		if g == null:
			break
		w.units.append(g)
		idx += 1
	# ★ 只需要「至少 n 名」时也可能已经更多：不从 0 开始删（将领只能加不能减）
	if n == 0:
		return


func _quiet(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world(c)


func _give(w, food: float, gold: float) -> void:
	_no_income(w)
	w.resources["food"] = food
	w.resources["gold"] = gold


func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}
	# 大本营的固定产出也一起关掉（测试专用开关，不影响「有基地」）。
	w.base_bonus_enabled = false
	w.refresh_zone_production()


## 己方大本营 + 把开局那 1 秒建造读条清掉（不然 `can_upgrade` 会报 "building"）。
func _ready_base(w):
	var base = w.find_base_of(String(w.my_faction))
	if base != null:
		base.build_total = 0.0
		base.build_remaining = 0.0
	return base


## 在己方区划的空地上放一栋 `type`（instant = false 时留着建造读条）。
func _add(w, type: String, faction: String, instant: bool = true):
	var t: Vector2i = _own_land(w, faction)
	if t.x < 0:
		return null
	return w.add_building(type, t.x, t.y, faction, true, instant)


## 己方区划里的一块空地（可通行、没有建筑）。
func _own_land(w, faction: String) -> Vector2i:
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.map.terrain.has(x, y):
				continue
			if not w.map.terrain_walkable(x, y):
				continue
			if w.buildings.get_cell(x, y) != null:
				continue
			var z = w.zones.zone_at(x, y)
			if z == null:
				continue
			if String((z as Dictionary).get("owner", "")) != String(faction):
				continue
			return Vector2i(x, y)
	return Vector2i(-1, -1)


func _player_wall(w):
	for b in w.building_list:
		if b.alive and b.type == BuildingRes.TYPE_WALL \
				and String(b.owner) == w.my_faction:
			return b
	# 开局不再自动生成防御阵地 ⇒ 没有就现造一段（与旧版的 `_build_wall_near` 同一条）
	return _add(w, "wall", String(w.my_faction))


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
