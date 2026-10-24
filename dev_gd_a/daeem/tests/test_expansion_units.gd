## test_expansion_units.gd —— 本轮新增的四个兵种机制
##
## 覆盖：
##   · 骑士的固定护甲（先减固定值、再算百分比减伤）；
##   · 攻城（投石车）无视目标的近战 / 远程减伤，但不无视护甲；
##   · 投石车的范围伤害（仅敌方、全额、按 1.5 格判定）；
##   · 马弓手的移动射击（边走边打、不停止）；
##   · 粮车的士气光环（半径 3 格、+0.5/秒、多辆不叠加、只影响友方）；
##   · 粮车是纯支援单位（不索敌、不攻击）。
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const ProjectileRes = preload("res://logic/projectile.gd")
const MoraleRes = preload("res://logic/morale.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_expansion_units"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_armor_and_siege(cfg)
	_test_catapult_splash(cfg)
	_test_move_shoot(cfg)
	_test_cart_aura(cfg)
	_test_cart_cannot_attack(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _mk(cfg, id: String, faction: String, unit_type: String, tile: Vector2i = Vector2i.ZERO):
	return UnitRes.create(cfg, id, id, tile, faction, unit_type, "", "", unit_type, -1)


## 固定护甲：20 点伤害 - 6 = 14；再算远程 25% = 10.5；攻城则跳过远程 25%。
func _test_armor_and_siege(cfg) -> void:
	var knight = _mk(cfg, "armor-knight", "p1", UnitRes.UNIT_TYPE_KNIGHT)
	eq(knight.armor, 6.0, "骑士护甲 = 6")
	var hp0: float = knight.hp
	knight.take_damage(cfg, null, 20.0)
	near(knight.hp, hp0 - 14.0, 1e-6, "★ 近战 20 → 先减护甲 6 = 14")
	hp0 = knight.hp
	knight.take_damage(cfg, null, 20.0, null, true)
	near(knight.hp, hp0 - 10.5, 1e-6, "★ 远程 20 → (20-6)×0.75 = 10.5")
	hp0 = knight.hp
	knight.take_damage(cfg, null, 20.0, null, true, true)
	near(knight.hp, hp0 - 14.0, 1e-6, "★ 攻城无视远程 25%，但仍吃护甲 6")

	# 最低 1 点：护甲不会让单位完全免疫。
	hp0 = knight.hp
	knight.take_damage(cfg, null, 3.0)
	near(knight.hp, hp0 - 1.0, 1e-6, "★ 伤害低于护甲时仍受 1 点")

	# 马弓手无护甲，但远程减伤 25%。
	var archer = _mk(cfg, "armor-archer", "p1", UnitRes.UNIT_TYPE_HORSE_ARCHER)
	eq(archer.armor, 0.0, "马弓手护甲 = 0")
	hp0 = archer.hp
	archer.take_damage(cfg, null, 20.0, null, true)
	near(archer.hp, hp0 - 15.0, 1e-6, "★ 马弓手远程 20 → ×0.75 = 15")

	# 器械不吃「对骑兵 / 步兵」加成：长枪兵（对骑兵 +25%）打投石车不加伤。
	ok(cfg.unit_class_of(UnitRes.UNIT_TYPE_CATAPULT) == "siege",
		"投石车大类 = siege（任何 attack_vs_class 都打不到它）")


## 投石车：1.5 格内所有敌人全额受伤，友军 / 圈外敌人不受影响。
func _test_catapult_splash(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	cfg.combat_enabled = false
	w.units = []
	var cat = _mk(cfg, "cat", "p1", UnitRes.UNIT_TYPE_CATAPULT, Vector2i(5, 5))
	cat.pos = Vector2(5.5, 5.5)
	var main = _mk(cfg, "cat-main", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(8, 5))
	main.pos = Vector2(8.5, 5.5)
	var near = _mk(cfg, "cat-near", "p2", UnitRes.UNIT_TYPE_LONGBOWMAN, Vector2i(9, 5))
	near.pos = Vector2(9.2, 5.5)          # 离主目标 0.7 格（< 1.5）
	var far = _mk(cfg, "cat-far", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(12, 5))
	far.pos = Vector2(12.5, 5.5)          # 离主目标 4 格（> 1.5）
	var ally = _mk(cfg, "cat-ally", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(8, 6))
	ally.pos = Vector2(8.5, 6.5)          # 离主目标 1 格，但同阵营
	w.units = [cat, main, near, far, ally]

	var main_hp: float = main.hp
	var near_hp: float = near.hp
	var far_hp: float = far.hp
	var ally_hp: float = ally.hp
	ProjectileRes.spawn(w, cfg, "p1", cat, cat.pos, main, false,
		cfg.unit_combat_of(UnitRes.UNIT_TYPE_CATAPULT)["damage"], 1.5, true)
	eq(w.projectiles.size(), 1, "生成一枚投石车投掷物")
	ProjectileRes.update(w, cfg, 10.0)
	near(main.hp, main_hp - 60.0, 1e-6, "★ 主目标吃全额 60")
	near(near.hp, near_hp - 60.0, 1e-6, "★ 半径内另一个敌人也吃全额 60")
	near(far.hp, far_hp, 1e-6, "圈外敌人不受伤")
	near(ally.hp, ally_hp, 1e-6, "★ 友军不受伤（仅敌方）")


## 马弓手：有移动命令、正在沿路走时，对射程内敌人开火但**不停止**。
func _test_move_shoot(cfg) -> void:
	cfg.combat_enabled = true
	var w = require_world(cfg)
	if w == null:
		return
	w.units = []
	var archer = _mk(cfg, "ms-archer", "p1", UnitRes.UNIT_TYPE_HORSE_ARCHER, Vector2i(5, 5))
	archer.pos = Vector2(5.5, 5.5)
	archer.moving = true
	archer.has_goal = true
	var route: Array[Vector2] = [Vector2(10.5, 5.5)]
	archer.path = route
	var foe = _mk(cfg, "ms-foe", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(8, 5))
	foe.pos = Vector2(8.2, 5.5)           # 2.7 格：在马弓手 3.5 射程内
	w.units = [archer, foe]
	CombatRes.update_unit(w, cfg, archer, DT, -1)
	ok(archer.moving, "★ 开火后仍在移动（移动射击不 stop）")
	ok(archer.attack_cd > 0.0, "★ 这一帧确实开火了（攻击进入冷却）")
	eq(w.projectiles.size(), 1, "★ 射出一枚投掷物")
	ok(archer.path.size() > 0, "移动路径还在")


## 粮车光环：半径 3 格、+0.5/秒；多辆取最大值；只给同一边。
func _test_cart_aura(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	w.units = []
	var cart = _mk(cfg, "aura-cart", "p1", UnitRes.UNIT_TYPE_GRAIN_CART, Vector2i(5, 5))
	cart.pos = Vector2(5.5, 5.5)
	var mate = _mk(cfg, "aura-mate", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(6, 5))
	mate.pos = Vector2(6.5, 5.5)
	var foe = _mk(cfg, "aura-foe", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(6, 6))
	foe.pos = Vector2(6.5, 6.5)
	w.units = [cart, mate, foe]
	w._refresh_morale_aura(cfg)
	ok(w.morale_aura_bonus.has(cart.id), "★ 粮车覆盖自己（在圈内）")
	ok(w.morale_aura_bonus.has(mate.id), "★ 粮车覆盖 3 格内友军")
	ok(not w.morale_aura_bonus.has(foe.id), "★ 不覆盖敌人")
	near(float(w.morale_aura_bonus.get(mate.id, 0.0)), 0.5, 1e-6, "光环 +0.5/秒")

	# 第二辆粮车叠在同一片区域：仍然只算 0.5（不叠加）。
	var cart2 = _mk(cfg, "aura-cart2", "p1", UnitRes.UNIT_TYPE_GRAIN_CART, Vector2i(5, 6))
	cart2.pos = Vector2(5.5, 6.5)
	w.units.append(cart2)
	w._refresh_morale_aura(cfg)
	near(float(w.morale_aura_bonus.get(mate.id, 0.0)), 0.5, 1e-6,
		"★ 两辆粮车对同一支部队不叠加")

	# 实测士气：把 zones 拿掉（没有区划升降），只留光环 → 1 秒 +0.5。
	w.zones = null
	mate.morale = 50.0
	MoraleRes.tick_unit(w, cfg, mate, 1.0)
	near(mate.morale, 50.5, 1e-6, "★ 1 秒后士气 +0.5（与其它来源相加）")


## 粮车不攻击：警戒索敌 / 直接开火都不该产生伤害。
func _test_cart_cannot_attack(cfg) -> void:
	cfg.combat_enabled = true
	var w = require_world(cfg)
	if w == null:
		return
	w.units = []
	var cart = _mk(cfg, "sup-cart", "p1", UnitRes.UNIT_TYPE_GRAIN_CART, Vector2i(5, 5))
	cart.pos = Vector2(5.5, 5.5)
	var foe = _mk(cfg, "sup-foe", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(6, 5))
	foe.pos = Vector2(6.2, 5.5)
	w.units = [cart, foe]
	ok(not CombatRes.acquire_target(w, cfg, cart, 0), "★ 粮车不自动索敌")
	var hp0: float = foe.hp
	CombatRes.attack_unit(w, cfg, cart, foe)
	near(foe.hp, hp0, 1e-6, "★ 粮车直接开火也造不成伤害")
