## test_loadout.gd —— 备战页的「出战配置」+ 新四位将领的数据 / 机制。
##
## ★★ 2026.11 用户口径（这个文件逐条钉住）：
##   1. 每个派系各一套名额：零阶 1、一阶 3、二阶 3、三阶 3；
##   2. 长按设为出战；某阶已满 → 顶掉该阶**最早选中**的那位（FIFO）；
##   3. 合作模式：零阶那位 = 开局将领；一/二/三阶选中的 9 位 = 区划招募九宫格；
##   4. 出战派系 = 合作模式里扮演的派系（写进关卡 `factions[].clan`）；
##   5. 新四位将领是**独立兵种对象**，数值 = 编辑器 = 游戏内（全局倍率已删除）；
##   6. 每条特性只做一件事；一位将领可以带多条（如子刹 = 铁壁 + 稳定）。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const LoadoutRes = preload("res://logic/loadout.gd")
const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const GridRes = preload("res://logic/grid.gd")

const DT := 1.0 / 60.0
const COOP_LEVEL := "res://data/campaigns/demo/levels/dscj.json"

func _initialize() -> void:
	_case_name = "test_loadout"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	LoadoutRes.reset()
	_test_new_generals(cfg)
	_test_quota_fifo(cfg)
	_test_payload(cfg)
	_test_random_payload(cfg)
	_test_apply_to_level(cfg)
	_test_coop_recruit_pool(cfg)
	_test_aura_traits(cfg)
	_test_melee_splash(cfg)
	_test_charge_aura(cfg)
	_test_capture_aura(cfg)
	_test_recruit_discount(cfg)

# ------------------------------------------------------------------
# 1) 四位新将领的数据
# ------------------------------------------------------------------
func _test_new_generals(cfg) -> void:
	eq(cfg.general_count(), 14, "★★ 名册 14 位（原 10 + 4 新）")
	# kind 映射：下标 10/11/12/13 → general_11..general_14
	eq(LoadoutRes.kind_of(10), "general_11", "下标 10 → general_11")
	eq(LoadoutRes.kind_of(11), "general_12", "下标 11 → general_12")
	eq(LoadoutRes.kind_of(12), "general_13", "下标 12 → general_13")
	eq(LoadoutRes.kind_of(13), "general_14", "下标 13 → general_14")
	eq(LoadoutRes.kind_of(9), "general_0", "★ 第 10 档仍是 general_0（没有 general_10）")

	var specs := [
		{"i": 10, "type": "dy_lord_ranger", "name": "王朝游侠", "tier": 1,
			"fac": ["dynasty"], "hp": 180.0, "armor": 1.0, "dmg": 16.0,
			"cd": 1.2, "spd": 0.7, "vis": 10.0, "sec": 8.0,
			"traits": ["ranged_guard", "formation_breaker"]},
		{"i": 11, "type": "dy_lord_zisha", "name": "子刹", "tier": 3,
			"fac": ["dynasty"], "hp": 1000.0, "armor": 7.0, "dmg": 50.0,
			"cd": 1.0, "spd": 0.8, "vis": 12.0, "sec": 10.0,
			"traits": ["arrow_wall", "steadfast", "crushing_blow"]},
		{"i": 12, "type": "dg_lord_rider", "name": "帝国骑手", "tier": 1,
			"fac": ["empire"], "hp": 200.0, "armor": 2.0, "dmg": 22.0,
			"cd": 0.8, "spd": 1.0, "vis": 12.0, "sec": 10.0,
			"traits": ["capture_expert"]},
		{"i": 13, "type": "dg_lord_ajikede", "name": "阿吉诃德", "tier": 3,
			"fac": ["empire"], "hp": 350.0, "armor": 5.0, "dmg": 30.0,
			"cd": 1.0, "spd": 0.8, "vis": 9.0, "sec": 8.0,
			"traits": ["call_to_arms", "new_knighthood"]},
	]
	for s in specs:
		var i: int = int(s["i"])
		eq(cfg.general_type_at(i), String(s["type"]), "★ #%d 的类型 = %s" % [i, s["type"]])
		eq(cfg.general_name_at(i), String(s["name"]), "★ #%d 的名字 = %s" % [i, s["name"]])
		eq(cfg.general_tier_at(i), int(s["tier"]), "★ #%d 的阶" % i)
		eq(cfg.general_factions_at(i), s["fac"], "★ #%d 只属于自己的派系" % i)
		eq(cfg.general_traits_at(i), s["traits"],
			"★★ #%d 带 %d 条特性（一个将领可以有多个特性）" % [i, (s["traits"] as Array).size()])
		near(cfg.general_hp_at(i), float(s["hp"]), 1e-6, "★★ #%d 血量 = %s（编辑器 = 游戏内）"
			% [i, str(s["hp"])])
		near(cfg.general_armor_at(i), float(s["armor"]), 1e-6, "★★ #%d 护甲 = %s"
			% [i, str(s["armor"])])
		var c: Dictionary = cfg.general_combat_at(i)
		near(float(c.get("damage", 0.0)), float(s["dmg"]), 1e-6, "★ #%d 攻击" % i)
		near(float(c.get("cooldown_sec", 0.0)), float(s["cd"]), 1e-6, "★ #%d 攻速" % i)
		near(cfg.general_speed_at(i), float(s["spd"]), 1e-6, "★ #%d 移速" % i)
		near(cfg.general_vision_at(i), float(s["vis"]), 1e-6, "★ #%d 视野" % i)
		near(cfg.general_recruit_sec(i), float(s["sec"]), 1e-6, "★ #%d 招兵读条" % i)

	# 独立兵种：贴图 / 大类 / 远近
	eq(cfg.unit_name_of("dy_lord_ranger"), "王朝游侠", "王朝游侠的兵种名")
	eq(cfg.unit_class_of("dy_lord_ranger"), "cavalry", "…骑兵")
	ok(cfg.unit_is_ranged("dy_lord_ranger"), "…远程")
	eq(cfg.unit_name_of("dy_lord_zisha"), "子刹", "子刹的兵种名")
	ok(not cfg.unit_is_ranged("dy_lord_zisha"), "子刹是近战")
	eq(cfg.unit_name_of("dg_lord_rider"), "帝国骑手", "帝国骑手的兵种名")
	eq(cfg.unit_name_of("dg_lord_ajikede"), "阿吉诃德", "阿吉诃德的兵种名")

	# 「攻击造成范围伤害和击退」现在是特性「横扫」的光环效果（兵种本身没有）
	ok(cfg.unit_has_charge("dy_lord_zisha"), "★ 子刹会冲锋")
	near(cfg.unit_splash_radius_of("dy_lord_zisha"), 0.0, 1e-9,
		"★ 兵种本身没有范围伤害（能力归特性）")
	var sweep: Dictionary = cfg.general_trait_def("crushing_blow").get("melee_splash", {})
	near(float(sweep.get("radius", 0.0)), 1.0, 1e-9, "★★ 「横扫」：攻击有范围伤害（半径 1）")
	near(float(sweep.get("knockback", 0.0)), 0.5, 1e-9, "★★ 「横扫」：并把敌人击退 0.5 格")

	# 新特性：六条（每条只做一件事）都在池里
	for tid in ["steadfast", "arrow_wall", "formation_breaker",
			"capture_expert", "call_to_arms", "new_knighthood"]:
		ok(not cfg.general_trait_def(tid).is_empty(), "特性池里有 %s" % tid)
	near(float(cfg.general_trait_def("ranged_guard").get("ranged_reduction", 0.0)), 0.25, 1e-9,
		"★ 王朝游侠的「远程抵抗」：远程免伤 25%（复用基础特性）")
	near(float((cfg.general_trait_def("formation_breaker").get("attack_vs_class", {}) as Dictionary)
		.get("infantry", 0.0)), 0.5, 1e-9, "★ 王朝游侠的「破阵」：步兵特攻 +50%")
	near(float(cfg.general_trait_def("arrow_wall").get("ranged_reduction", 0.0)), 0.5, 1e-9,
		"★ 子刹的「铁壁」：远程免伤 50%")
	ok(bool(cfg.general_trait_def("steadfast").get("knockback_immune", false)),
		"★ 子刹的「稳定」：免疫击退")
	near(float(cfg.general_trait_def("capture_expert").get("capture_speed_bonus", 0.0)), 0.4, 1e-9,
		"★ 帝国骑手的「占领专家」：占领速度 +40%")
	near(float(cfg.general_trait_def("call_to_arms").get("recruit_cavalry_discount", 0.0)),
		0.25, 1e-9, "★ 阿吉诃德的「一呼百应」：招募骑兵 -25%")
	near(float(cfg.general_trait_def("new_knighthood").get("charge_damage_bonus", 0.0)),
		1.0, 1e-9, "★ 阿吉诃德的「新骑士精神」：近战骑兵冲锋额外伤害 +100%")
	# ★★ 2026.11：一个特性名只对应一个效果（不允许一条特性塞两个不相干效果）
	#   ★ 读**原始**配置（洗过的字典所有键都带默认值）。
	for tid in cfg.general_trait_ids():
		var raw: Variant = cfg.get_path_value("unit.general_traits.%s" % String(tid))
		var d: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
		var keys: Array = []
		for k in ["speed_bonus", "attack_speed_bonus", "melee_reduction", "ranged_reduction",
				"attack_vs_class", "knockback_immune", "capture_speed_bonus",
				"recruit_cavalry_discount", "charge_damage_bonus", "melee_splash"]:
			if d.has(k):
				keys.append(k)
		ok(keys.size() <= 1, "★★ 特性「%s」只有一个效果键（实际 %s）"
			% [cfg.general_trait_name(String(tid)), str(keys)])

	# 合作专用招募表：4 条，造价按需求
	for row in [["general_11", 100.0, 100.0], ["general_12", 300.0, 300.0],
			["general_13", 100.0, 100.0], ["general_14", 250.0, 250.0]]:
		var e: Dictionary = cfg.coop_recruit_entry(String(row[0]))
		ok(not e.is_empty(), "★★ 合作招募表里有 %s" % row[0])
		near(float((e.get("cost", {}) as Dictionary).get("food", 0.0)), float(row[1]), 1e-9,
			"…%s 粮价" % row[0])
		near(float((e.get("cost", {}) as Dictionary).get("gold", 0.0)), float(row[2]), 1e-9,
			"…%s 金价" % row[0])
	# ★ 不进对战 / 战役的招募表
	for row in cfg.get_path_value("recruit.zone.list"):
		var k := String((row as Dictionary).get("kind", ""))
		ok(k != "general_11" and k != "general_12" and k != "general_13" and k != "general_14",
			"★★ recruit.zone.list 里没有新将领（对战 / 战役不招它们）")

# ------------------------------------------------------------------
# 2) 名额 / FIFO / 每派系各一套
# ------------------------------------------------------------------
func _test_quota_fifo(cfg) -> void:
	LoadoutRes.reset()
	LoadoutRes.ensure_defaults(cfg)
	for fid in ["dynasty", "empire"]:
		eq(LoadoutRes.tier_count(fid, 0, cfg), 1, "%s：零阶 1 位" % fid)
		eq(LoadoutRes.tier_count(fid, 1, cfg), 3, "%s：一阶 3 位" % fid)
		eq(LoadoutRes.tier_count(fid, 2, cfg), 3, "%s：二阶 3 位" % fid)
		eq(LoadoutRes.tier_count(fid, 3, cfg), 3, "%s：三阶 3 位" % fid)
		ok(not LoadoutRes.is_selected(fid, 10), "★ 默认不选新将领（王朝游侠）")
	ok(LoadoutRes.is_selected("dynasty", 0), "默认勾满：王朝里有一阶将领 1")

	# 同阶已满 → 顶掉**最早选中**的那位（王朝一阶：0,1,2 → 选 10 顶掉 0）
	var before := LoadoutRes.selected("dynasty")
	var res := LoadoutRes.toggle("dynasty", 10, cfg)
	ok(bool(res.get("on", false)), "★ 长按新将领 → 设为出战")
	eq(int(res.get("evicted", -1)), 0, "★★ 一阶已满 → 顶掉最早选中的将领 1（下标 0）")
	ok(LoadoutRes.is_selected("dynasty", 10), "…新的王朝游侠在列")
	ok(not LoadoutRes.is_selected("dynasty", 0), "…将领 1 被取消")
	eq(LoadoutRes.tier_count("dynasty", 1, cfg), 3, "★★ 一阶仍然正好 3 位（不超员）")
	# 再选一位（重新勾上将领 1）→ 一阶已满 ⇒ 顶掉此刻最早的将领 2（下标 1）
	res = LoadoutRes.toggle("dynasty", 0, cfg)
	ok(bool(res.get("on", false)), "★ 重新选将领 1")
	eq(int(res.get("evicted", -1)), 1, "★★ 一阶已满 → 顶掉此刻最早的那位（将领 2 / 下标 1）")
	eq(LoadoutRes.tier_count("dynasty", 1, cfg), 3, "★★ 一阶仍然正好 3 位（不超员）")
	# 取消：不顶别人
	res = LoadoutRes.toggle("dynasty", 0, cfg)
	ok(not bool(res.get("on", false)), "★ 再点同一位 = 取消出战")
	eq(int(res.get("evicted", -1)), -1, "…取消不顶掉别人")
	eq(LoadoutRes.tier_count("dynasty", 1, cfg), 2, "…一阶剩 2 位")

	# 每派系各一套：帝国的勾选不受王朝影响
	eq(LoadoutRes.tier_count("empire", 1, cfg), 3, "★★ 帝国的一阶仍是满员 3 位")
	ok(LoadoutRes.is_selected("empire", 0), "…帝国的将领 1 还在")
	var dyn_now := LoadoutRes.selected("dynasty")
	ok(dyn_now != before, "王朝的队列确实变了（与帝国无关）")

	# 清掉后重新默认
	LoadoutRes.reset()
	LoadoutRes.ensure_defaults(cfg)
	eq(LoadoutRes.selected("empire").size(), 10, "★ 默认勾满是 10 位（1 + 3 + 3 + 3）")

# ------------------------------------------------------------------
# 3) 出战配置 payload
# ------------------------------------------------------------------
func _test_payload(cfg) -> void:
	LoadoutRes.reset()
	LoadoutRes.ensure_defaults(cfg)
	LoadoutRes.set_faction("dynasty")
	var p: Dictionary = LoadoutRes.payload_for("dynasty", cfg)
	eq(String(p.get("clan", "")), "dynasty", "★ payload 带派系")
	eq(String(p.get("starter", "")), "general_0", "★ 零阶那位 = 开局将领 general_0")
	var pool: Array = p.get("pool", [])
	eq(pool.size(), 9, "★★ 九宫格 = 一/二/三阶各 3 位")
	eq(String(pool[0]), "general_1", "…第一位是一阶将领 1")
	eq(String(pool[8]), "general_9", "…第九位是三阶将领 9")
	ok(not pool.has("general_0"), "★ 零阶不进九宫格")

## ★★ 2026.11：ai_test 敌方 AI 的「随机一套备战配置」。
func _test_random_payload(cfg) -> void:
	for fid in LoadoutRes.FACTIONS:
		var before := LoadoutRes.selected(fid)
		var a: Dictionary = LoadoutRes.random_payload_for(fid, cfg, 20261105)
		var b: Dictionary = LoadoutRes.random_payload_for(fid, cfg, 20261105)
		eq(a, b, "★★ %s：同一 seed 的随机配置可复现" % fid)
		eq(String(a.get("clan", "")), fid, "★ %s：派系写对" % fid)
		var starter := String(a.get("starter", ""))
		var si := ConfigRes.general_index_of(starter)
		ok(si >= 0 and cfg.general_in_faction(si, fid), "★ %s：零阶将领属于本派系" % fid)
		eq(cfg.general_tier_at(si), 0, "★ %s：starter 是零阶" % fid)
		var pool: Array = a.get("pool", [])
		eq(pool.size(), 9, "★★ %s：随机池 = 9 位" % fid)
		var per_tier: Dictionary = {1: 0, 2: 0, 3: 0}
		for k in pool:
			var idx := ConfigRes.general_index_of(String(k))
			ok(idx >= 0 and cfg.general_in_faction(idx, fid),
				"★ %s：池里 %s 属于本派系" % [fid, String(k)])
			if idx >= 0:
				var t: int = cfg.general_tier_at(idx)
				per_tier[t] = int(per_tier.get(t, 0)) + 1
		for t2 in [1, 2, 3]:
			eq(int(per_tier.get(t2, 0)), 3, "★★ %s：%d 阶随机 3 位" % [fid, t2])
		# 不污染玩家自己的备战选择。
		eq(LoadoutRes.selected(fid), before, "★ %s：随机配置不改玩家 _sel" % fid)


# ------------------------------------------------------------------
# 4) 写进关卡：派系 + 开局将领
# ------------------------------------------------------------------
func _test_apply_to_level(cfg) -> void:
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	ok(lv != null, "（前提）合作关卡能载入")
	if lv == null:
		return
	var before_units: int = lv.start_units.size()
	LoadoutRes.reset()
	LoadoutRes.ensure_defaults(cfg)
	LoadoutRes.set_faction("dynasty")
	var p: Dictionary = LoadoutRes.payload_for("dynasty", cfg)
	LoadoutRes.apply_to_level(lv, "F1", p)

	# 派系写进去了（解析后的数据 + raw 两份都要）
	var clan := ""
	for e in lv.faction_meta:
		if String((e as Dictionary).get("id", "")) == "F1":
			clan = String((e as Dictionary).get("clan", ""))
	eq(clan, "dynasty", "★★ 出战派系写进 factions[].clan")
	var raw_clan := ""
	for e in lv.raw.get("factions", []):
		if String((e as Dictionary).get("id", "")) == "F1":
			raw_clan = String((e as Dictionary).get("clan", ""))
	eq(raw_clan, "dynasty", "★★ raw 也写了（房主要把它发给客机）")

	# 开局将领：F1 只剩一位 general_0，且不再带 unit_type
	var generals: Array = []
	for u in lv.start_units:
		if String((u as Dictionary).get("faction", "")) != "F1":
			continue
		if ConfigRes.general_index_of(String((u as Dictionary).get("kind", ""))) >= 0:
			generals.append(u)
	eq(generals.size(), 1, "★★ F1 的开局将领只剩一位（其余进九宫格）")
	if generals.size() == 1:
		var g: Dictionary = generals[0]
		eq(String(g.get("kind", "")), "general_0", "★★ 这位就是零阶将领 general_0")
		ok(not g.has("unit_type"),
			"★★ 不带 unit_type（否则会被按兵种重造成「骑手数值 + 将领 0 名字」）")
		ok(g.has("escort_count") or g.has("name"), "★ 保留关卡作者写的附属规格 / 名字")
	eq(lv.start_units.size(), before_units,
		"★ dscj 里 F1 原本 1 位将领 → 替换后条目数不变（1 进 1 出）")

	# 别的阵营原样（df 的 34 条守将一条不少）
	var df_units := 0
	for u in lv.start_units:
		if String((u as Dictionary).get("faction", "")) == "df":
			df_units += 1
	eq(df_units, 34, "★ 其它阵营的摆放一点没动（df 的 34 条）")

	# raw 与解析后一致
	eq((lv.raw.get("start_units", []) as Array).size(), lv.start_units.size(),
		"★★ raw.start_units 与 level.start_units 同长")

# ------------------------------------------------------------------
# 5) 合作世界：九宫格 = 选择 / 新将领用合作表
# ------------------------------------------------------------------
func _test_coop_recruit_pool(cfg) -> void:
	var lv = LevelRes.load_level(null, COOP_LEVEL, cfg)
	if lv == null:
		return
	LoadoutRes.reset()
	LoadoutRes.ensure_defaults(cfg)
	LoadoutRes.set_faction("empire")
	var p: Dictionary = LoadoutRes.payload_for("empire", cfg)
	LoadoutRes.apply_to_level(lv, "F1", p)
	var pools: Dictionary = {"F1": p.get("pool", [])}
	var w = WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true, {}, {}, -1, false, pools)
	ok(w != null, "（前提）合作世界能建出来")
	if w == null:
		return
	var roster: Array = w.general_recruit_roster("F1")
	eq(roster.size(), 9, "★★ 九宫格 = 出战配置里的 9 位")
	eq(String(roster[0]), "general_1", "…顺序仍是一阶在前")
	# 帝国选中的 9 位里不含「阿吉诃德」（默认没选）
	ok(not roster.has("general_14"), "★★ 没选中的新将领不在九宫格里")

	# 换个选择了新将领的配置 → 它就出现；entry 来自 coop_list
	LoadoutRes.toggle("empire", 13, cfg)      # 选阿吉诃德（三阶，顶掉最早的三阶）
	var p2: Dictionary = LoadoutRes.payload_for("empire", cfg)
	var lv2 = LevelRes.load_level(null, COOP_LEVEL, cfg)
	LoadoutRes.apply_to_level(lv2, "F1", p2)
	var w2 = WorldRes.create_from_level(cfg, lv2, "F1", ["F1", "F2"], true, {}, {}, -1, false,
		{"F1": p2.get("pool", [])})
	ok(w2 != null, "（前提）第二个合作世界")
	if w2 != null:
		ok(w2.general_recruit_roster("F1").has("general_14"), "★★ 选中后阿吉诃德进九宫格")
		var e: Dictionary = w2.recruit_entry("general_14", "F1")
		ok(not e.is_empty(), "★★ 它的招募条目来自合作专用表")
		near(float((e.get("cost", {}) as Dictionary).get("food", 0.0)), 250.0, 1e-9,
			"…造价 250 粮")
		# 非合作的路由（没有 pool 覆盖）不会给它条目 / 也不能招
		var w3 = require_world(cfg)
		if w3 != null:
			ok(not w3.general_recruit_roster("p1").has("general_14"),
				"★★ 普通对局九宫格里没有它（不进对战 / 战役招募表）")
			ok(not w3.is_zone_recruitable("general_14", "p1"),
				"★★ 普通对局也不能招它")

	# 开局将领 = 零阶那位
	var g0 = w.unit_by_id("general-F1-0")
	ok(g0 != null, "★★ 开局将领存在")
	if g0 != null:
		eq(g0.general_index, 9, "★★ 它就是名册第 10 项（零阶将领 #0）")

# ------------------------------------------------------------------
# 6) 光环字段：稳定 / 占领 / 招募折扣 / 冲锋
# ------------------------------------------------------------------
func _test_aura_traits(cfg) -> void:
	LoadoutRes.reset()
	var w = require_world(cfg)
	var u = UnitRes.create(cfg, "aura_zisha", "测", Vector2i.ZERO, "p1", "dy_lord_zisha",
		"", "", "dy_lord_zisha", 11)
	u.set_general_traits(cfg, ["arrow_wall", "steadfast", "crushing_blow"])
	eq(u.aura_traits, ["arrow_wall", "steadfast", "crushing_blow"],
		"★★ 子刹同时享受三条特性")
	ok(u.aura_knockback_immune, "★★ 子刹光环：稳定")
	near(u.aura_ranged_reduction, 0.5, 1e-9, "★ 子刹光环：远程免伤 50%")
	near(u.melee_splash_radius(), 1.0, 1e-9, "★★ 子刹光环：横扫（范围伤害半径 1）")
	near(u.melee_knock_distance(), 0.5, 1e-9, "★ …击退 0.5 格")
	# 光环里的「稳定」真的让击退失效
	var before_pos: Vector2 = u.pos
	ok(not u.apply_knockback(cfg, w, u.pos + Vector2(-1.0, 0.0), 0.5, 0.25),
		"★★ 稳定：击退被拒绝")
	eq(u.pos, before_pos, "…位置没有变")

	var u2 = UnitRes.create(cfg, "aura_rider", "测", Vector2i.ZERO, "p1", "dg_lord_rider",
		"", "", "dg_lord_rider", 12)
	u2.set_general_traits(cfg, ["capture_expert"])
	near(u2.aura_capture_speed_bonus, 0.4, 1e-9, "★ 帝国骑手光环：占领速度 +40%")

	var u3 = UnitRes.create(cfg, "aura_aj", "测", Vector2i.ZERO, "p1", "dg_lord_ajikede",
		"", "", "dg_lord_ajikede", 13)
	u3.set_general_traits(cfg, ["call_to_arms", "new_knighthood"])
	near(u3.aura_recruit_cavalry_discount, 0.25, 1e-9, "★ 阿吉诃德光环：招募折扣")
	near(u3.aura_charge_damage_bonus, 1.0, 1e-9, "★ 阿吉诃德光环：冲锋额外伤害")

# ------------------------------------------------------------------
# 7) 子刹的普通攻击：范围伤害 + 击退
# ------------------------------------------------------------------
func _test_melee_splash(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var atk = UnitRes.create(cfg, "splash_a", "测", Vector2i(5, 5), "p1", "dy_lord_zisha",
		"", "", "dy_lord_zisha", 11)
	atk.set_general_traits(cfg, ["crushing_blow"])
	var main = UnitRes.create(cfg, "splash_m", "测", Vector2i(6, 5), "p2", "spearman",
		"", "", "spearman", -1)
	var side = UnitRes.create(cfg, "splash_s", "测", Vector2i(7, 5), "p2", "spearman",
		"", "", "spearman", -1)
	for x in [atk, main, side]:
		w.units.append(x)
	main.armor = 0.0
	side.armor = 0.0
	main.hp = 1e9
	side.hp = 1e9
	var m0: float = main.hp
	var s0: float = side.hp
	var side_pos: Vector2 = side.pos
	CombatRes.attack_unit(w, cfg, atk, main, false)
	var d_main: float = m0 - main.hp
	var d_side: float = s0 - side.hp
	near(d_main, atk.combat_damage(cfg), 1e-6, "★ 主目标吃全额伤害")
	ok(d_side > 0.0, "★★ 子刹的普通攻击会溅射到旁边的敌人（%.1f）" % d_side)
	near(d_side, d_main, 1e-6, "★★ 溅射也是全额伤害（与远程溅射同口径）")
	ok(side.pos.distance_to(side_pos) > 0.05, "★★ 旁边的敌人也被击退")

	# ★★ 2026.11：横扫是**光环** —— 旗下部队也获得范围伤害 + 击退
	var minion = UnitRes.create(cfg, "splash_minion", "测", Vector2i(10, 10), "p1",
		UnitRes.UNIT_TYPE_SPEARMAN, "", atk.id, UnitRes.UNIT_TYPE_SPEARMAN, -1)
	minion.inherit_general_aura(cfg, atk)
	near(minion.melee_splash_radius(), 1.0, 1e-9, "★★ 附属兵继承「横扫」的范围伤害")
	near(minion.melee_knock_distance(), 0.5, 1e-9, "★★ …和击退")

# ------------------------------------------------------------------
# 8) 冲锋光环：只放大「额外伤害」那一部分，且只对近战骑兵
# ------------------------------------------------------------------
func _test_charge_aura(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var atk = UnitRes.create(cfg, "chg_a", "测", Vector2i(5, 5), "p1", "dg_lord_ajikede",
		"", "", "dg_lord_ajikede", 13)
	var plain = UnitRes.create(cfg, "chg_p", "测", Vector2i(5, 6), "p1", "dg_lord_ajikede",
		"", "", "dg_lord_ajikede", 13)
	var t1 = UnitRes.create(cfg, "chg_t1", "测", Vector2i(6, 5), "p2", "spearman",
		"", "", "spearman", -1)
	var t2 = UnitRes.create(cfg, "chg_t2", "测", Vector2i(6, 6), "p2", "spearman",
		"", "", "spearman", -1)
	for x in [atk, plain, t1, t2]:
		w.units.append(x)
	atk.set_general_traits(cfg, ["new_knighthood"])
	# 护甲先清零 —— 固定减伤会让「比例」对不上（这里只看光环那一层）。
	t1.armor = 0.0
	t2.armor = 0.0
	atk.charge_damage_bonus = 0.6
	plain.charge_damage_bonus = 0.6
	t1.hp = 1e9
	t2.hp = 1e9
	var hp1: float = t1.hp
	CombatRes.attack_unit(w, cfg, plain, t1, true)
	var dmg_plain: float = hp1 - t1.hp
	var hp2: float = t2.hp
	CombatRes.attack_unit(w, cfg, atk, t2, true)
	var dmg_aura: float = hp2 - t2.hp
	near(dmg_aura / maxf(1e-9, dmg_plain), (1.0 + 0.6 * 2.0) / (1.0 + 0.6), 1e-6,
		"★★ 冲锋额外伤害 +100% ⇒ 总额外伤害翻倍（基础 ×1.6 → ×2.2）")

	# 步兵不吃这条（只有**近战骑兵**）：给长枪兵硬开冲锋 + 光环，伤害不该翻倍。
	var inf = UnitRes.create(cfg, "chg_inf", "测", Vector2i(5, 7), "p1", "spearman",
		"", "", "spearman", -1)
	var t3 = UnitRes.create(cfg, "chg_t3", "测", Vector2i(6, 7), "p2", "spearman",
		"", "", "spearman", -1)
	w.units.append(inf)
	w.units.append(t3)
	inf.charge_enabled = true
	inf.charge_damage_bonus = 0.0
	inf.aura_charge_damage_bonus = 1.0
	t3.armor = 0.0
	t3.hp = 1e9
	var hp3: float = t3.hp
	CombatRes.attack_unit(w, cfg, inf, t3, true)
	var dmg_inf: float = hp3 - t3.hp
	near(dmg_inf, inf.combat_damage(cfg) * inf.attack_multiplier_vs_class("infantry")
		* float(w.tech_attack_mult(inf)), 1e-6,
		"★ 步兵即使带光环也不吃冲锋加成（只限近战骑兵）")

# ------------------------------------------------------------------
# 9) 占领速度光环：在场才生效、同方取最大值
# ------------------------------------------------------------------
func _neutral_spot(w, cfg) -> Dictionary:
	for z in w.zones.zones:
		if String(z["owner"]) != "":
			continue
		var c: Variant = z["center"]
		if c == null:
			continue
		var center: Vector2i = c
		var r: int = maxi(0, int(cfg.zone_capture_radius_tiles))
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := Vector2i(center.x + dx, center.y + dy)
				if w.can_build_at(t.x, t.y):
					return {"zone": z, "tile": t}
	return {}

func _progress(z: Dictionary, faction: String) -> float:
	var by: Dictionary = z.get("progress_by", {})
	return float(by.get(faction, 0.0))

func _test_capture_aura(cfg) -> void:
	var w_plain = require_world(cfg)
	var w_aura = require_world(cfg)
	if w_plain == null or w_aura == null:
		return
	var spot1 := _neutral_spot(w_plain, cfg)
	var spot2 := _neutral_spot(w_aura, cfg)
	if spot1.is_empty() or spot2.is_empty():
		ok(false, "(前提) 有中立区块可占")
		return
	var t1: Vector2i = spot1["tile"]
	var t2: Vector2i = spot2["tile"]
	var a = UnitRes.create(cfg, "cap_plain", "测", t1, "p1", "spearman", "", "", "spearman", -1)
	var b = UnitRes.create(cfg, "cap_aura", "测", t2, "p1", "spearman", "", "", "spearman", -1)
	b.aura_capture_speed_bonus = 0.4
	for pair in [[w_plain, a], [w_aura, b]]:
		var w = pair[0]
		var u = pair[1]
		u.pos = GridRes.center_of(Vector2i(u.tx, u.ty))
		w.units.append(u)
	var z1: Dictionary = spot1["zone"]
	var z2: Dictionary = spot2["zone"]
	for i in 60:
		w_plain.tick(DT)
		w_aura.tick(DT)
	var p1 := _progress(z1, "p1")
	var p2 := _progress(z2, "p1")
	ok(p2 > p1, "★★ 带「占领速度 +40%」的那一方读条更快（%.4f vs %.4f）" % [p2, p1])
	near(p2 / maxf(1e-9, p1), 1.4, 0.02, "★★ 速度正好快 40%（时间 ÷1.4）")

# ------------------------------------------------------------------
# 10) 招募折扣：只对骑兵、只对这位将领的队列
# ------------------------------------------------------------------
func _test_recruit_discount(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var leader = UnitRes.create(cfg, "disc_leader", "测", Vector2i(5, 5), "p1", "dg_lord_ajikede",
		"", "", "dg_lord_ajikede", 13)
	leader.set_general_traits(cfg, ["call_to_arms"])
	var plain_leader = UnitRes.create(cfg, "disc_plain", "测", Vector2i(6, 6), "p1", "dg_lord_ajikede",
		"", "", "dg_lord_ajikede", 13)
	var base: Dictionary = w.recruit_cost_for("rider", "p1", plain_leader)
	var disc: Dictionary = w.recruit_cost_for("rider", "p1", leader)
	near(float(disc.get("food", 0.0)), float(base.get("food", 0.0)) * 0.75, 1e-6,
		"★★ 骑兵招募粮食 -25%")
	near(float(disc.get("gold", 0.0)), float(base.get("gold", 0.0)) * 0.75, 1e-6,
		"★★ 骑兵招募黄金 -25%")
	var base_i: Dictionary = w.recruit_cost_for("spearman", "p1", plain_leader)
	var disc_i: Dictionary = w.recruit_cost_for("spearman", "p1", leader)
	near(float(disc_i.get("food", 0.0)), float(base_i.get("food", 0.0)), 1e-6,
		"★ 步兵不打折")
	# 别的将领（没有这条光环）也不打折
	var other = UnitRes.create(cfg, "disc_other", "测", Vector2i(7, 7), "p1", "spearman",
		"", "", "spearman", -1)
	near(float(w.recruit_cost_for("rider", "p1", other).get("food", 0.0)),
		float(base.get("food", 0.0)), 1e-6, "★ 没有光环的将领不打折")
