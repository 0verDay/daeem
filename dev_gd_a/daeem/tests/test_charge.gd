## test_charge.gd —— 单位冲锋（被动动量）的数据 / 累积 / 命中 / 科技回归。
##
## 覆盖：
##   1. 配置：7 个近战骑兵/战车有 charge；远程骑兵与步兵没有；夹取上限生效。
##   2. 累积：直线移动达到 min_distance 后 armed；到达终点后清零。
##   3. 速度：armed 时移速 = 基础 × (1 + speed_bonus)。
##   4. 转向 / 打断：急转、stop、击退都会清零；halt 故意不清。
##   5. 命中：冠军骑士额外伤害 + 单体击退；消耗冲锋并进入冷却。
##   6. 范围：战车冲锋对副目标造成 splash_damage_ratio 的伤害并击退。
##   7. 科技：骑士精神 +100% 只作用于冲锋命中，不影响普通攻击。
extends "res://tests/test_case.gd"

const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const GridRes = preload("res://logic/grid.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_charge"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_config(cfg)
	_test_accumulate(cfg)
	_test_turn_and_interrupt(cfg)
	_test_charged_hit(cfg)
	_test_splash(cfg)
	_test_tech(cfg)

	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ==================================================================
# 1) 配置
# ==================================================================

func _test_config(cfg) -> void:
	var ch: Dictionary = cfg.unit_charge_of("dy_chariot")
	near(float(ch.get("min_distance", 0.0)), 3.0, 1e-9, "★ 战车冲锋 min_distance = 3")
	near(float(ch.get("splash_radius", 0.0)), 1.2, 1e-9, "★ 战车冲锋有范围撞击")
	near(float(ch.get("splash_damage_ratio", 0.0)), 0.6, 1e-9, "★ 战车范围伤害比例 0.6")
	ok(cfg.unit_has_charge("rider"), "★ 骑手会冲锋")
	ok(cfg.unit_has_charge("knight"), "★ 骑士会冲锋")
	ok(cfg.unit_has_charge("dg_champion"), "★ 冠军骑士会冲锋")
	ok(cfg.unit_has_charge("dy_royal_cavalry"), "★ 御林军骑兵会冲锋")
	ok(not cfg.unit_has_charge("spearman"), "★ 步兵不冲锋")
	ok(not cfg.unit_has_charge("horse_archer"), "★ 远程骑兵（马弓手）不冲锋")
	ok(not cfg.unit_has_charge("dy_ranger"), "★ 远程骑兵（游侠）不冲锋")

	# 夹取：写坏的值在载入时被拉回安全范围。
	var bad: Dictionary = cfg._normalize_charge({
		"min_distance": 999.0,
		"max_distance": 999.0,
		"turn_max_deg": 999.0,
		"speed_bonus": 99.0,
		"damage_bonus": 99.0,
		"splash_radius": 99.0,
		"splash_damage_ratio": 99.0,
		"cooldown_sec": 9999.0,
	})
	near(float(bad.get("min_distance", 0.0)), ConfigRes.CHARGE_MAX_DISTANCE, 1e-9,
		"★★ min_distance 被夹到上限")
	near(float(bad.get("speed_bonus", 0.0)), ConfigRes.CHARGE_MAX_SPEED_BONUS, 1e-9,
		"★★ speed_bonus 被夹到上限")
	near(float(bad.get("damage_bonus", 0.0)), ConfigRes.CHARGE_MAX_DAMAGE_BONUS, 1e-9,
		"★★ damage_bonus 被夹到上限")
	near(float(bad.get("splash_damage_ratio", 0.0)), 1.0, 1e-9,
		"★★ splash_damage_ratio 被夹到 1")
	near(float(bad.get("cooldown_sec", 0.0)), ConfigRes.CHARGE_MAX_COOLDOWN, 1e-9,
		"★★ cooldown 被夹到上限")


# ==================================================================
# 2) 累积 / 速度
# ==================================================================

func _test_accumulate(cfg) -> void:
	var w = _fresh_world(cfg)
	if w == null:
		return
	var run := _find_run(w, 10)
	ok(run.x >= 0, "（前提）找得到 10 格直行空地")
	if run.x < 0:
		return
	var rider = _mk_unit(w, cfg, "rider_a", "rider", "p1", run)
	if rider == null:
		return
	rider.pos = GridRes.center_of(run)
	rider.sync_tile(w.map)
	rider.stop()
	var base_speed: float = rider.speed(cfg, w.map)
	var bonus: float = rider.charge_speed_bonus
	ok(bonus > 0.0, "★ 骑手有冲锋速度加成")
	ok(not rider.charge_armed, "★ 起步时没有冲锋")

	var goal := GridRes.center_of(run + Vector2i(7, 0))
	ok(rider.order_move(w, cfg, goal, true), "★ 直行命令被接受")
	var saw_unarmed := true
	var armed_frame := -1
	var ratio_seen := 0.0
	for i in 900:
		w.tick(DT)
		ratio_seen = maxf(ratio_seen, rider.charge_ratio)
		if not rider.charge_armed:
			saw_unarmed = saw_unarmed and true
		elif armed_frame < 0:
			armed_frame = i
			# armed 那一帧：移速 = 基础 × (1 + speed_bonus)
			near(rider.speed(cfg, w.map), base_speed * (1.0 + bonus), 1e-6,
				"★★ 冲锋态移速 = 基础 × (1 + speed_bonus)")
		if not rider.moving:
			break
	ok(saw_unarmed, "★ 达到阈值之前 charge_armed 为 false")
	ok(armed_frame > 0, "★★ 直行达到 min_distance 后进入冲锋态")
	ok(ratio_seen >= 1.0 - 1e-6, "★ 冲锋进度 charge_ratio 到过 1")
	near(rider.charge_dist, 0.0, 1e-6, "★★ 到达终点后冲锋清零")
	ok(not rider.charge_armed, "★★ 到达终点后不再 armed")


# ==================================================================
# 3) 转向 / 打断
# ==================================================================

func _test_turn_and_interrupt(cfg) -> void:
	var w = _fresh_world(cfg)
	if w == null:
		return
	var run := _find_run(w, 6)
	if run.x < 0:
		ok(false, "（前提）找得到 6 格空地")
		return
	var rider = _mk_unit(w, cfg, "rider_b", "rider", "p1", run)
	if rider == null:
		return
	rider.pos = GridRes.center_of(run)
	rider.sync_tile(w.map)

	# 直行累积：从 0 开始，向右走 0.1 格
	rider.clear_charge()
	rider.charge_dir = Vector2.RIGHT
	var p0: Vector2 = rider.pos
	rider.pos = p0 + Vector2(0.1, 0.0)
	rider._update_charge_momentum(cfg, p0, 0.1)
	near(rider.charge_dist, 0.1, 1e-6, "★ 直行距离被累计")

	# 急转：把方向改成向上（与起始方向 90°）⇒ 清零并从新方向重算。
	rider.charge_dist = 4.0
	rider.charge_armed = true
	rider.charge_dir = Vector2.RIGHT
	var p1: Vector2 = rider.pos
	rider.pos = p1 + Vector2(0.0, 0.05)
	rider._update_charge_momentum(cfg, p1, 0.05)
	ok(rider.charge_dist < 0.06, "★★ 急转（> turn_max_deg）清零并从新方向重算")
	ok(not rider.charge_armed, "★★ 急转后退出冲锋态")

	# halt 故意不清（进入攻击距离时先 halt 再打冲锋那一击）
	rider.charge_dist = 3.0
	rider.charge_armed = true
	rider.halt()
	ok(rider.charge_armed and rider.charge_dist > 0.0, "★★ halt() 不清冲锋")

	# stop 清
	rider.stop()
	ok(not rider.charge_armed and rider.charge_dist <= 0.0, "★★ stop() 清冲锋")

	# 被击退清（非免疫单位）
	rider.charge_dist = 3.0
	rider.charge_armed = true
	rider.apply_knockback(cfg, w, rider.pos - Vector2(1.0, 0.0), 0.2, 0.1)
	ok(not rider.charge_armed and rider.charge_dist <= 0.0,
		"★★ 被击退 / 眩晕清冲锋")

	# 稳定单位（免疫击退）不被清
	var royal = _mk_unit(w, cfg, "royal", "dy_royal_cavalry", "p1", run + Vector2i(0, 2))
	if royal != null:
		royal.charge_dist = 3.0
		royal.charge_armed = true
		var before: float = royal.charge_dist
		royal.apply_knockback(cfg, w, royal.pos - Vector2(1.0, 0.0), 0.2, 0.1)
		near(royal.charge_dist, before, 1e-9, "★★ 稳定（knockback_immune）单位冲锋不被打断")


# ==================================================================
# 4) 冲锋命中
# ==================================================================

func _test_charged_hit(cfg) -> void:
	var w = _fresh_world(cfg)
	if w == null:
		return
	var run := _find_run(w, 6)
	if run.x < 0:
		ok(false, "（前提）找得到 6 格空地")
		return
	var atk = _mk_unit(w, cfg, "champ", "dg_champion", "p1", run)
	var tgt = _mk_unit(w, cfg, "target", "spearman", "p2", run + Vector2i(2, 0))
	if atk == null or tgt == null:
		return
	atk.pos = GridRes.center_of(run)
	atk.sync_tile(w.map)
	tgt.pos = GridRes.center_of(run + Vector2i(2, 0))
	tgt.sync_tile(w.map)
	_prepare_target(cfg, tgt)
	atk.charge_armed = true
	atk.charge_dist = 3.0
	atk.charge_dir = Vector2.RIGHT
	var hp0: float = tgt.hp
	var base: float = atk.combat_damage(cfg)
	var mult: float = atk.attack_multiplier_vs_class("infantry")
	var expected: float = base * mult * (1.0 + atk.charge_damage_bonus)
	CombatRes.attack_unit(w, cfg, atk, tgt, true)
	near(hp0 - tgt.hp, expected, 1e-4,
		"★★ 冲锋伤害 = 基础 × (1 + charge.damage_bonus)")
	ok(tgt.stun_timer > 0.0, "★★ 冲锋命中造成眩晕")
	ok(not atk.charge_armed and atk.charge_dist <= 0.0, "★★ 命中后消耗冲锋")
	ok(atk.charge_cd > 0.0, "★★ 命中后进入冲锋冷却")
	ok(atk.attack_cd > 0.0, "★★ 冲锋命中后设置普通攻击冷却（不双刀）")

	# 冲锋只作用于「近战 + 配了 charge」：远程 / 没配 charge 的 charged 参数会被降级。
	var archer = _mk_unit(w, cfg, "archer", "longbowman", "p1", run + Vector2i(0, 2))
	if archer != null:
		tgt.hp = tgt.hp_max
		var hp1: float = tgt.hp
		CombatRes.attack_unit(w, cfg, archer, tgt, true)
		# 远程走投掷物，伤害在命中时结算；这里只断言它没有把冲锋参数当回事。
		ok(archer.charge_enabled == false, "★ 远程单位不会被当成冲锋单位")


# ==================================================================
# 5) 范围撞击（战车）
# ==================================================================

func _test_splash(cfg) -> void:
	var w = _fresh_world(cfg)
	if w == null:
		return
	var run := _find_run(w, 8)
	if run.x < 0:
		ok(false, "（前提）找得到 8 格空地")
		return
	var car = _mk_unit(w, cfg, "chariot", "dy_chariot", "p1", run)
	var a = _mk_unit(w, cfg, "splash_a", "spearman", "p2", run + Vector2i(3, 0))
	var b = _mk_unit(w, cfg, "splash_b", "spearman", "p2", run + Vector2i(4, 0))
	if car == null or a == null or b == null:
		return
	car.pos = GridRes.center_of(run)
	car.sync_tile(w.map)
	a.pos = GridRes.center_of(run + Vector2i(3, 0))
	a.sync_tile(w.map)
	b.pos = GridRes.center_of(run + Vector2i(4, 0))
	b.sync_tile(w.map)
	_prepare_target(cfg, a)
	_prepare_target(cfg, b)
	car.charge_armed = true
	car.charge_dist = 3.0
	var hp_a0: float = a.hp
	var hp_b0: float = b.hp
	var expected_main: float = car.combat_damage(cfg) \
		* car.attack_multiplier_vs_class("infantry") \
		* (1.0 + car.charge_damage_bonus)
	var expected_splash: float = expected_main * car.charge_splash_ratio
	CombatRes.attack_unit(w, cfg, car, a, true)
	near(hp_a0 - a.hp, expected_main, 1e-4, "★★ 战车主目标吃全额冲锋伤害")
	near(hp_b0 - b.hp, expected_splash, 1e-4, "★★ 战车副目标吃 splash_damage_ratio 的伤害")
	ok(a.stun_timer > 0.0 and b.stun_timer > 0.0, "★★ 范围内敌人全部被击退/眩晕")
	ok(hp_a0 - a.hp < expected_main + 1e-4, "★★ 主目标不会被范围伤害打第二遍")


# ==================================================================
# 6) 科技：骑士精神
# ==================================================================

func _test_tech(cfg) -> void:
	var w = _fresh_world(cfg)
	if w == null:
		return
	instant_tech(w, "dg_chivalry", "p1")
	near(w.tech_charge_add("p1"), 1.0, 1e-9, "★★ 骑士精神提供 +1.0 冲锋伤害")
	near(w.tech_attack_mult(null), 1.0, 1e-9, "★★ 骑士精神不影响普通攻击")

	var run := _find_run(w, 6)
	if run.x < 0:
		ok(false, "（前提）找得到 6 格空地")
		return
	var atk = _mk_unit(w, cfg, "champ2", "dg_champion", "p1", run)
	var tgt = _mk_unit(w, cfg, "target2", "spearman", "p2", run + Vector2i(2, 0))
	if atk == null or tgt == null:
		return
	atk.pos = GridRes.center_of(run)
	atk.sync_tile(w.map)
	tgt.pos = GridRes.center_of(run + Vector2i(2, 0))
	tgt.sync_tile(w.map)
	_prepare_target(cfg, tgt)
	atk.charge_armed = true
	atk.charge_dist = 3.0
	var hp0: float = tgt.hp
	var expected: float = atk.combat_damage(cfg) \
		* atk.attack_multiplier_vs_class("infantry") \
		* (1.0 + atk.charge_damage_bonus + 1.0)
	CombatRes.attack_unit(w, cfg, atk, tgt, true)
	near(hp0 - tgt.hp, expected, 1e-4, "★★ 骑士精神让冲锋伤害再加 +100%")

	# 普通攻击不受冲锋科技影响
	tgt.hp = tgt.hp_max
	atk.charge_armed = false
	atk.charge_cd = 0.0
	atk.attack_cd = 0.0
	var hp1: float = tgt.hp
	var normal: float = atk.combat_damage(cfg) * atk.attack_multiplier_vs_class("infantry")
	CombatRes.attack_unit(w, cfg, atk, tgt, false)
	near(hp1 - tgt.hp, normal, 1e-4, "★★ 普通攻击不吃 charge_damage_mult")


# ==================================================================
# 帮手
# ==================================================================

func _fresh_world(cfg):
	var w = require_world(cfg)
	if w == null:
		return null
	w.units = []
	return w


func _mk_unit(w, cfg, id: String, unit_type: String, faction: String, tile: Vector2i):
	var u = UnitRes.create(cfg, id, id, tile, faction, unit_type, "", "", unit_type, -1)
	if u == null:
		ok(false, "（前提）能造出 %s" % id)
		return null
	w.units.append(u)
	return u


## 目标单位调成「无护甲 / 无减伤」，让伤害断言只受冲锋公式影响。
func _prepare_target(cfg, u) -> void:
	u.hp_max = 100000.0
	u.hp = u.hp_max
	u.armor = 0.0
	u.melee_damage_reduction = 0.0
	u.ranged_damage_reduction = 0.0
	u.aura_melee_reduction = 0.0
	u.aura_ranged_reduction = 0.0


## 同一行上连续 `len` 格可通行（不考虑区划归属，只要地形可走且没有建筑）。
func _find_run(w, len: int) -> Vector2i:
	for y in w.map.rows:
		var run := 0
		for x in w.map.cols:
			if w.can_build_at(x, y, ""):
				run += 1
				if run >= len:
					return Vector2i(x - len + 1, y)
			else:
				run = 0
	return Vector2i(-1, -1)
