## test_healing.gd —— 回血：己方区划缓慢回血 + 粮车回血光环（可叠加）
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0


func _initialize() -> void:
	_case_name = "test_healing"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_aura(cfg)
	_test_zone(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


func _mk(cfg, id: String, faction: String, unit_type: String):
	return UnitRes.create(cfg, id, id, Vector2i.ZERO, faction, unit_type, "", "", unit_type, -1)


func _test_config(cfg) -> void:
	near(cfg.heal_zone_regen, 1.0, 1e-9, "区划回血 = 1 血/秒")
	near(cfg.unit_heal_aura_radius_of(UnitRes.UNIT_TYPE_GRAIN_CART), 3.0, 1e-9, "粮车光环半径 3 格")
	near(cfg.unit_heal_aura_rate_of(UnitRes.UNIT_TYPE_GRAIN_CART), 2.0, 1e-9, "粮车光环 2 血/秒")
	var cart = _mk(cfg, "cfg-cart", "p1", UnitRes.UNIT_TYPE_GRAIN_CART)
	near(cart.heal_aura_radius, 3.0, 1e-9, "招出来的粮车带半径 3")
	near(cart.heal_aura_rate, 2.0, 1e-9, "招出来的粮车带 2 血/秒")


func _test_aura(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	w.zones = null                            # 隔离：只看粮车光环
	var cart = _mk(cfg, "heal-cart", "p1", UnitRes.UNIT_TYPE_GRAIN_CART)
	cart.pos = Vector2(5.5, 5.5)
	var mate = _mk(cfg, "heal-mate", "p1", UnitRes.UNIT_TYPE_SPEARMAN)
	mate.pos = Vector2(6.5, 5.5)
	var foe = _mk(cfg, "heal-foe", "p2", UnitRes.UNIT_TYPE_SPEARMAN)
	foe.pos = Vector2(6.5, 6.5)
	for u in [cart, mate, foe]:
		u.hp_max = 200.0
		u.hp = 100.0
	w.units = [cart, mate, foe]

	w._tick_healing(cfg, DT)
	near(mate.hp, 102.0, 1e-6, "★ 粮车每秒给 1 格内友军回 2 血")
	near(foe.hp, 100.0, 1e-6, "★ 不治疗敌人")
	near(cart.hp, 102.0, 1e-6, "粮车自己的光环也治疗自己")

	# 两辆粮车：叠加（不是取最大值）
	var cart2 = _mk(cfg, "heal-cart2", "p1", UnitRes.UNIT_TYPE_GRAIN_CART)
	cart2.pos = Vector2(5.5, 6.5)
	cart2.hp_max = 200.0
	cart2.hp = 100.0
	w.units.append(cart2)
	mate.hp = 100.0
	w._tick_healing(cfg, DT)
	near(mate.hp, 104.0, 1e-6, "★ 两辆粮车叠加：每秒 4 血")

	# 封顶
	mate.hp = 199.5
	w._tick_healing(cfg, DT)
	near(mate.hp, 200.0, 1e-6, "回血封顶 hp_max")

	# 濒死单位不参与回血（再起状态机自己管）
	mate.downed = true
	mate.hp = 100.0
	w._tick_healing(cfg, DT)
	near(mate.hp, 100.0, 1e-6, "★ 濒死单位不会被光环回血")
	mate.downed = false


func _test_zone(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var g = w.unit_by_id("general-1")
	var z = w.zones.zone_at(int(g.tx), int(g.ty)) if (w.zones != null and g != null) else null
	if typeof(z) != TYPE_DICTIONARY:
		ok(true, "（跳过：出生点不在区划内）")
		return
	var zz: Dictionary = z
	if not FactionRes.same_side(String(zz.get("owner", "")), String(w.my_faction)):
		ok(true, "（跳过：出生点不在己方区划内）")
		return
	w.units = [g]
	g.hp_max = 200.0
	g.hp = 100.0
	w._tick_healing(cfg, DT)
	near(g.hp, 101.0, 1e-6, "★ 在己方区划内每秒回 1 血")

	# 区划 + 粮车光环叠加（1 + 2 = 3）
	var cart = _mk(cfg, "zone-cart", String(w.my_faction), UnitRes.UNIT_TYPE_GRAIN_CART)
	cart.pos = g.pos + Vector2(1.0, 0.0)
	cart.hp_max = 200.0
	cart.hp = 100.0
	w.units = [g, cart]
	g.hp = 100.0
	w._tick_healing(cfg, DT)
	near(g.hp, 103.0, 1e-6, "★ 区划回血 + 粮车光环叠加：每秒 3 血")

	# 敌方区划不回血
	var old_owner := String(zz.get("owner", ""))
	zz["owner"] = "p2"
	w.units = [g]
	g.hp = 100.0
	w._tick_healing(cfg, DT)
	near(g.hp, 100.0, 1e-6, "★ 敌方区划内不享受区划回血")
	zz["owner"] = old_owner

	# 濒死单位跳过
	g.downed = true
	g.hp = 100.0
	w.units = [g]
	w._tick_healing(cfg, DT)
	near(g.hp, 100.0, 1e-6, "★ 濒死单位不会被区划回血")
	g.downed = false
