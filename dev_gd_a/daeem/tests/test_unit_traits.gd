## test_unit_traits.gd —— 兵种特性（长枪兵 / 长弓兵 / 骑手）
##
## 覆盖：config 的 traits 解析（含写错的键）/ 单位出生时抄到身上 / 近战与远程两条伤害路
##       （攻击加成、对远程减伤、与士气免伤的加算与封顶）/ 详情栏两列的文案行 / 将领继承。
##
## ★ 需求原文：
##   长枪兵：对骑兵伤害 +25%（攻击）
##   长弓兵：对步兵伤害 +10%（攻击）
##   骑手：  对步兵伤害 +25%（攻击）、对远程减伤 +25%（防御）
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const ProjectileRes = preload("res://logic/projectile.gd")
const HudRes = preload("res://view/hud.gd")
const ConfigRes = preload("res://logic/config.gd")

const ESCORTS_PER_GENERAL := 2


func _initialize() -> void:
	_case_name = "test_unit_traits"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_unit_fields(cfg)
	_test_melee_attack(cfg)
	_test_ranged_reduction(cfg)
	_test_ranged_impact(cfg)
	_test_detail_rows(cfg)
	_test_general_traits(cfg)
	cleanup_escort_scaffold()

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


## 造一个游离单位（不进 world —— 伤害 / 行文案都只依赖单位自身）。
func _mk(cfg, id: String, unit_type: String, faction: String = "p1"):
	return UnitRes.create(cfg, id, "测", Vector2i.ZERO, faction, unit_type, "", "", unit_type, -1)


# ------------------------------------------------------------------
# 1) config：特性表的形状
# ------------------------------------------------------------------
func _test_config(cfg) -> void:
	var spear: Dictionary = cfg.unit_traits_of(UnitRes.UNIT_TYPE_SPEARMAN)
	var spear_atk: Dictionary = spear.get("attack_vs_class", {})
	eq(int(float(spear_atk.get("cavalry", 0.0)) * 100.0), 25,
		"★ 长枪兵：对骑兵伤害 +25%")
	ok(not spear_atk.has("infantry"), "长枪兵对步兵没有加成")
	near(float(spear.get("ranged_reduction", 0.0)), 0.0, 1e-9, "长枪兵没有对远程减伤")

	var bow: Dictionary = cfg.unit_traits_of(UnitRes.UNIT_TYPE_LONGBOWMAN)
	eq(int(float((bow.get("attack_vs_class", {}) as Dictionary).get("infantry", 0.0)) * 100.0), 10,
		"★ 长弓兵：对步兵伤害 +10%")
	near(float(bow.get("ranged_reduction", 0.0)), 0.0, 1e-9, "长弓兵没有对远程减伤")

	var rider: Dictionary = cfg.unit_traits_of(UnitRes.UNIT_TYPE_RIDER)
	eq(int(float((rider.get("attack_vs_class", {}) as Dictionary).get("infantry", 0.0)) * 100.0), 25,
		"★ 骑手：对步兵伤害 +25%")
	near(float(rider.get("ranged_reduction", 0.0)), 0.25, 1e-9,
		"★ 骑手：对远程减伤 +25%")

	near(cfg.damage_reduction_cap, 0.75, 1e-9, "减伤封顶默认 75%（50% 士气 + 25% 特性）")
	ok(cfg.damage_reduction_cap > 0.0 and cfg.damage_reduction_cap < 1.0, "封顶在 (0, 1)")

	# ★ 大类 id → 显示名（HUD 拼「对骑兵伤害」用的就是这一条，参数是大类 id 本身）
	eq(cfg.class_display_name(ConfigRes.CLASS_CAVALRY), "骑兵", "大类 id → 显示名：cavalry = 骑兵")
	eq(cfg.class_display_name(ConfigRes.CLASS_INFANTRY), "步兵", "大类 id → 显示名：infantry = 步兵")
	eq(cfg.class_display_name("nope"), "nope", "未知大类 id 原样返回（不静默变成步兵）")

	eq(cfg.unit_traits_of("no_such_type").size(), 0, "查不到的类型没有特性（空字典）")

	# ★ 写错的大类键 / 写错类型的值要在载入时被洗掉，而不是留一条永远匹配不上的规则。
	#   ⚠️ 必须**深拷**一份 data：直接共用同一个字典会把上面这张真表也改掉，
	#      后面的用例就全乱了（这条踩过一次，别写成 `cfg2.data = cfg.data`）。
	var cfg2 = ConfigRes.new()
	cfg2.data = cfg.data.duplicate(true)
	cfg2.data["unit"]["types"]["spearman"]["traits"] = {
		"attack_vs_class": {"nope": 0.5, "cavalry": "x"},
		"ranged_reduction": "0.9",
	}
	cfg2._cache_scalars()
	var bad: Dictionary = cfg2.unit_traits_of(UnitRes.UNIT_TYPE_SPEARMAN)
	eq((bad.get("attack_vs_class", {}) as Dictionary).size(), 0,
		"★ 写错的大类 id / 非数字的值在载入时被丢掉（不静默生效）")
	near(float(bad.get("ranged_reduction", 0.0)), 0.0, 1e-9, "★ 非数字的 ranged_reduction 被丢掉")
	# （前提）上面的深拷确实没有污染真表
	eq(int(float((cfg.unit_traits_of(UnitRes.UNIT_TYPE_SPEARMAN)
		.get("attack_vs_class", {}) as Dictionary).get("cavalry", 0.0)) * 100.0),
		25, "（前提）临时改写的是副本，真表还是 +25%")


# ------------------------------------------------------------------
# 2) 单位出生时把特性抄到身上
# ------------------------------------------------------------------
func _test_unit_fields(cfg) -> void:
	var spear = _mk(cfg, "t_spear", UnitRes.UNIT_TYPE_SPEARMAN)
	near(spear.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY), 1.25, 1e-9,
		"长枪兵打骑兵的倍率 = 1.25")
	near(spear.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.0, 1e-9,
		"长枪兵打步兵的倍率 = 1.0")
	near(spear.attack_multiplier_vs_class(""), 1.0, 1e-9, "空大类（例如建筑）= 1.0")
	near(spear.ranged_damage_reduction, 0.0, 1e-9, "长枪兵没有远程减伤")

	var bow = _mk(cfg, "t_bow", UnitRes.UNIT_TYPE_LONGBOWMAN)
	near(bow.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.10, 1e-9,
		"长弓兵打步兵的倍率 = 1.10")
	near(bow.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY), 1.0, 1e-9,
		"长弓兵打骑兵没有加成")

	var rider = _mk(cfg, "t_rider", UnitRes.UNIT_TYPE_RIDER)
	near(rider.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.25, 1e-9,
		"骑手打步兵的倍率 = 1.25")
	near(rider.ranged_damage_reduction, 0.25, 1e-9, "骑手的对远程减伤 = 25%")


# ------------------------------------------------------------------
# 3) 近战：攻击加成真的进了伤害
# ------------------------------------------------------------------
func _test_melee_attack(cfg) -> void:
	var spear = _mk(cfg, "a_spear", UnitRes.UNIT_TYPE_SPEARMAN, "p1")
	var rider = _mk(cfg, "d_rider", UnitRes.UNIT_TYPE_RIDER, "p2")
	var bow = _mk(cfg, "d_bow", UnitRes.UNIT_TYPE_LONGBOWMAN, "p2")
	spear.morale = 90.0
	rider.morale = 90.0
	bow.morale = 90.0

	var hp0: float = rider.hp
	CombatRes.attack_unit(null, cfg, spear, rider)
	near(hp0 - rider.hp, spear.combat_damage(cfg) * 1.25, 1e-3,
		"★ 长枪兵打骑兵：伤害 ×1.25（%.1f）" % (hp0 - rider.hp))

	var hp1: float = bow.hp
	CombatRes.attack_unit(null, cfg, spear, bow)
	near(hp1 - bow.hp, spear.combat_damage(cfg), 1e-3,
		"长枪兵打步兵：伤害不加成")

	var bow2 = _mk(cfg, "a_bow", UnitRes.UNIT_TYPE_LONGBOWMAN, "p1")
	bow2.morale = 90.0
	var spear2 = _mk(cfg, "d_spear", UnitRes.UNIT_TYPE_SPEARMAN, "p2")
	spear2.morale = 90.0
	# 远程单位走投掷物；这里只验算「投掷物里的伤害」= 伤害 × 对步兵的倍率，
	# 命中结算由下面 _test_ranged_impact 单独验。
	near(bow2.combat_damage(cfg) * bow2.attack_multiplier_vs_class(String(spear2.unit_class)),
		bow2.combat_damage(cfg) * 1.10, 1e-3, "长弓兵打步兵的投掷物伤害 ×1.10")
	ok(spear2.hp == spear2.hp_max, "（前提）远程开火不改目标的血（命中才结算）")


# ------------------------------------------------------------------
# 4) 受击：对远程减伤（含与士气免伤的加算 / 封顶 / 易伤）
# ------------------------------------------------------------------
func _test_ranged_reduction(cfg) -> void:
	var rider = _mk(cfg, "r_rider", UnitRes.UNIT_TYPE_RIDER, "p2")
	rider.hp_max = 1000.0
	rider.hp = 1000.0
	rider.morale = cfg.morale_mid_tier        # 中间档：士气不参与

	rider.take_damage(cfg, null, 100.0, null, true)
	var trait_red: float = rider.ranged_damage_reduction
	near(1000.0 - rider.hp, 100.0 * (1.0 - trait_red), 1e-3,
		"★ 骑手受到远程伤害：×(1 - %.2f)（少受 %d%%）" % [trait_red, roundi(trait_red * 100.0)])

	rider.hp = 1000.0
	rider.take_damage(cfg, null, 100.0, null, false)
	near(1000.0 - rider.hp, 100.0, 1e-3, "★ 同一击按近战结算：不减伤（特性只挡远程）")

	# 加算 + 封顶：士气高位免伤 + 特性，按 combat.damage_reduction_cap 截断
	# ★ 数值全部从 cfg 读：buff 编辑器改了士气免伤 / 封顶之后，这条用例不该跟着红。
	var morale_red: float = cfg.morale_damage_reduction
	var combined: float = minf(morale_red + trait_red, cfg.damage_reduction_cap)
	rider.hp = 1000.0
	rider.morale = cfg.morale_high_tier
	rider.take_damage(cfg, null, 100.0, null, true)
	near(1000.0 - rider.hp, 100.0 * (1.0 - combined), 1e-3,
		"★ 士气免伤 %d%% + 对远程 %d%% = %d%%（封顶 %d%%）：受到 %.1f 点"
		% [roundi(morale_red * 100.0), roundi(trait_red * 100.0),
			roundi(combined * 100.0), roundi(cfg.damage_reduction_cap * 100.0),
			100.0 * (1.0 - combined)])

	# 把封顶调低 → 两条来源相加后按封顶截断（证明 cap 真的被读）
	var old_cap: float = cfg.damage_reduction_cap
	cfg.damage_reduction_cap = 0.5
	var capped: float = minf(morale_red + trait_red, 0.5)
	rider.hp = 1000.0
	rider.take_damage(cfg, null, 100.0, null, true)
	near(1000.0 - rider.hp, 100.0 * (1.0 - capped), 1e-3,
		"★ 封顶调成 50%% 后，叠加被截到 %d%%" % roundi(capped * 100.0))
	cfg.damage_reduction_cap = old_cap

	# 易伤不进加法：先吃远程减伤，再 ×(1 + 易伤)
	rider.hp = 1000.0
	rider.morale = cfg.morale_vuln_tier
	rider.take_damage(cfg, null, 100.0, null, true)
	near(1000.0 - rider.hp,
		100.0 * (1.0 - minf(trait_red, cfg.damage_reduction_cap))
			* (1.0 + cfg.morale_vulnerability), 1e-3,
		"★ 低士气（易伤）：对远程减伤照吃，易伤再乘一次")

	# 非骑手：远程减伤为 0，只有士气那一条
	var spear = _mk(cfg, "r_spear", UnitRes.UNIT_TYPE_SPEARMAN, "p2")
	spear.hp_max = 1000.0
	spear.hp = 1000.0
	spear.morale = cfg.morale_high_tier
	spear.take_damage(cfg, null, 100.0, null, true)
	var spear_red: float = minf(morale_red, cfg.damage_reduction_cap)
	near(1000.0 - spear.hp, 100.0 * (1.0 - spear_red), 1e-3,
		"长枪兵：远程也只吃士气免伤（%d%%）" % roundi(spear_red * 100.0))


# ------------------------------------------------------------------
# 5) 投掷物命中：确实按「远程」传进 take_damage
# ------------------------------------------------------------------
func _test_ranged_impact(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var bow = _mk(cfg, "p_bow", UnitRes.UNIT_TYPE_LONGBOWMAN, "p1")
	bow.morale = 90.0
	var rider = _mk(cfg, "p_rider", UnitRes.UNIT_TYPE_RIDER, "p2")
	rider.morale = 90.0
	rider.hp_max = 1000.0
	rider.hp = 1000.0

	var p = ProjectileRes.new()
	p.target = rider
	p.source = bow
	p.damage = bow.combat_damage(cfg)   # 24：长弓兵打骑兵没有加成
	p.target_is_building = false
	ProjectileRes._impact(w, cfg, p)
	near(1000.0 - rider.hp, 24.0 * 0.75, 1e-3,
		"★ 投掷物命中骑手：按远程结算（24 × 0.75）")

	var spear = _mk(cfg, "p_spear", UnitRes.UNIT_TYPE_SPEARMAN, "p2")
	spear.morale = 90.0
	spear.hp_max = 1000.0
	spear.hp = 1000.0
	p.target = spear
	p.damage = bow.combat_damage(cfg) * bow.attack_multiplier_vs_class(String(spear.unit_class))
	ProjectileRes._impact(w, cfg, p)
	near(1000.0 - spear.hp, 24.0 * 1.10, 1e-3,
		"★ 投掷物命中步兵：长弓兵的 +10% 已算在投掷物伤害里")

	# ★★ 真正的装配路径（不是手算）：attack_unit 生成投掷物时，`damage` 字段里
	#    已经乘过了「对目标兵种大类」的倍率 —— 这是「攻击侧一处收口」的落点。
	w.projectiles.clear()
	var bow2 = _mk(cfg, "p_bow2", UnitRes.UNIT_TYPE_LONGBOWMAN, "p1")
	bow2.morale = 90.0
	CombatRes.attack_unit(w, cfg, bow2, spear)
	eq(w.projectiles.size(), 1, "★ 远程开火生成一枚投掷物（装配路径）")
	if not w.projectiles.is_empty():
		near(float(w.projectiles[0].damage), bow2.combat_damage(cfg) * 1.10, 1e-3,
			"★ 投掷物里的伤害已经乘过对步兵的 +10%（%.2f）" % float(w.projectiles[0].damage))
	w.projectiles.clear()


# ------------------------------------------------------------------
# 6) 详情栏：攻击 / 防御两列的小字行
# ------------------------------------------------------------------
func _test_detail_rows(cfg) -> void:
	var hud = HudRes.new()
	hud.cfg = cfg
	var spear = _mk(cfg, "h_spear", UnitRes.UNIT_TYPE_SPEARMAN)
	var bow = _mk(cfg, "h_bow", UnitRes.UNIT_TYPE_LONGBOWMAN)
	var rider = _mk(cfg, "h_rider", UnitRes.UNIT_TYPE_RIDER)
	spear.morale = cfg.morale_mid_tier
	bow.morale = cfg.morale_mid_tier
	rider.morale = cfg.morale_mid_tier

	eq(hud._attack_bonus_lines(spear), ["对骑兵伤害 +25%"], "★ 左列：长枪兵「对骑兵伤害 +25%」")
	eq(hud._attack_bonus_lines(bow), ["对步兵伤害 +10%"], "★ 左列：长弓兵「对步兵伤害 +10%」")
	eq(hud._attack_bonus_lines(rider), ["对步兵伤害 +25%"], "★ 左列：骑手「对步兵伤害 +25%」")

	eq(hud._defense_bonus_lines(spear), [], "右列：长枪兵没有防御特性（士气中档）")
	var trait_line: String = "对远程减伤 +%d%%" % roundi(rider.ranged_damage_reduction * 100.0)
	eq(hud._defense_bonus_lines(rider), [trait_line],
		"★ 右列：骑手「%s」" % trait_line)

	rider.morale = cfg.morale_high_tier
	var morale_line: String = "士气免伤 +%d%%" % roundi(cfg.morale_damage_reduction * 100.0)
	eq(hud._defense_bonus_lines(rider), [trait_line, morale_line],
		"★ 右列：特性在前、士气在后（两条都显示）")

	var rows: Dictionary = hud._unit_detail_rows(rider)
	var left_txt: String = hud._rows_text({"left": rows["left"], "right": []})
	var right_txt: String = hud._rows_text({"left": [], "right": rows["right"]})
	ok(left_txt.contains("对步兵伤害 +25%"), "★ 详细信息左列有攻击特性（%s）" % left_txt.replace("\n", "|"))
	ok(right_txt.contains("对远程减伤 +25%"), "★ 详细信息右列有防御特性（%s）" % right_txt.replace("\n", "|"))
	ok(left_txt.find("攻击") < left_txt.find("对步兵伤害 +25%"),
		"★ 攻击特性排在「攻击」那一行下面（当前位置 = 攻击增益）")

	hud.free()


# ------------------------------------------------------------------
# 7) 将领按所属兵种继承特性（与「将领数值 = 兵种数值」同口径）
# ------------------------------------------------------------------
func _test_general_traits(cfg) -> void:
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")     # 长枪兵
	var g2 = w.unit_by_id("general-2")     # 长弓兵
	var g3 = w.unit_by_id("general-3")     # 骑手
	ok(g1 != null and g2 != null and g3 != null, "（前提）三位将领都在")
	if g1 == null or g2 == null or g3 == null:
		return

	near(g1.attack_multiplier_vs_class(ConfigRes.CLASS_CAVALRY), 1.25, 1e-9,
		"★ 将领 1（长枪兵）：对骑兵 +25%")
	near(g2.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.10, 1e-9,
		"★ 将领 2（长弓兵）：对步兵 +10%")
	near(g3.attack_multiplier_vs_class(ConfigRes.CLASS_INFANTRY), 1.25, 1e-9,
		"★ 将领 3（骑手）：对步兵 +25%")
	near(g3.ranged_damage_reduction, 0.25, 1e-9, "★ 将领 3（骑手）：对远程减伤 +25%")

	# 附属兵也与将领同类型 ⇒ 同一套特性
	var ret: Array = w.retinue_of(g3.id)
	ok(not ret.is_empty(), "（前提）general-3 有附属兵")
	if not ret.is_empty():
		near(ret[0].ranged_damage_reduction, 0.25, 1e-9, "骑手将的附属兵也有对远程减伤")
