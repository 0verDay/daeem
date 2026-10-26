## test_building_defense.gd —— 建筑对远程伤害免伤 90%（2026.10.26）
##
## 口径：
##   · 投掷物 → 建筑 = 远程伤害 → 只吃 10%（`building.<type>.ranged_reduction`，缺省 0.9）；
##   · 近战 → 建筑 = 全额；
##   · 投石车（攻城 / `u.siege`）→ 自己的伤害标签，**不算远程**，全额；
##   · 所有建筑（木墙 / 哨塔 / 石墙 / 警戒塔 / 大本营）都吃这一条。
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const ProjectileRes = preload("res://logic/projectile.gd")
const CombatRes = preload("res://logic/combat.gd")

func _initialize() -> void:
	_case_name = "test_building_defense"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_take_damage(cfg)
	_test_projectile_path(cfg)
	_test_attack_building_path(cfg)

func _test_config(cfg) -> void:
	for t in ["wall", "tower", "stone_wall", "watch_tower", "base"]:
		near(cfg.building_ranged_reduction(t), 0.9, 1e-6,
			"★ %s 的远程免伤 = 90%%" % t)
	near(cfg.building_max_hp("stone_wall"), 700.0, 1e-6, "石墙血量 700")
	near(cfg.building_max_hp("watch_tower"), 550.0, 1e-6, "警戒塔血量 550")
	var wt: Dictionary = cfg.building_attack_of("watch_tower", 1)
	near(float(wt.get("damage", 0.0)), 16.0, 1e-6, "警戒塔攻击 16")
	near(float(wt.get("range", 0.0)), 4.0, 1e-6, "警戒塔射程 4")

func _test_take_damage(cfg) -> void:
	var w = require_world(cfg)
	var base = w.find_base_of("p1")
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	base.hp = base.hp_max
	base.take_damage(cfg, 100.0, null, true)
	near(base.hp_max - base.hp, 10.0, 1e-4, "★★ 投掷物 → 建筑只掉 10%（100 → 10）")
	base.hp = base.hp_max
	base.take_damage(cfg, 100.0, null, false)
	near(base.hp_max - base.hp, 100.0, 1e-4, "★ 近战 → 建筑全额 100")
	base.hp = base.hp_max
	base.take_damage(cfg, 100.0, null, true, true)
	near(base.hp_max - base.hp, 100.0, 1e-4, "★★ 攻城标签（ignore_reduction）→ 全额 100")

func _test_projectile_path(cfg) -> void:
	var w = require_world(cfg)
	var base = w.find_base_of("p1")
	if base == null:
		ok(false, "（前提）有大本营")
		return
	base.hp = base.hp_max
	var p = ProjectileRes.spawn(w, cfg, "p1", null, base.center(), base, true, 100.0)
	ProjectileRes._impact(w, cfg, p)
	near(base.hp_max - base.hp, 10.0, 1e-4,
		"★★ 投掷物命中建筑时确实按远程结算（100 → 10）")
	base.hp = base.hp_max
	var ps = ProjectileRes.spawn(w, cfg, "p1", null, base.center(), base, true,
		100.0, 0.0, true)
	ProjectileRes._impact(w, cfg, ps)
	near(base.hp_max - base.hp, 100.0, 1e-4,
		"★★ 带攻城标签的投掷物不受 90% 减免（100 → 100）")

func _test_attack_building_path(cfg) -> void:
	var w = require_world(cfg)
	var base = w.find_base_of("p1")
	if base == null:
		ok(false, "（前提）有大本营")
		return
	var tile := Vector2i(base.tx + 1, base.ty)
	# 长弓兵：远程，但不是攻城。
	var bow = UnitRes.create(cfg, "bow-test", "长弓兵", tile, "p1", "longbowman")
	ok(bow != null and bool(bow.ranged) and not bool(bow.siege), "（前提）长弓兵是普通远程")
	if bow != null:
		base.hp = base.hp_max
		CombatRes.attack_building(w, cfg, bow, base)
		ok(not w.projectiles.is_empty(), "长弓兵打建筑会生成投掷物")
		if not w.projectiles.is_empty():
			var bp = w.projectiles[w.projectiles.size() - 1]
			ok(not bool(bp.ignore_reduction), "普通远程的投掷物不带攻城标签")
			ProjectileRes._impact(w, cfg, bp)
			near(base.hp_max - base.hp, float(cfg.building_damage) * 0.1, 1e-4,
				"★★ 长弓兵每发只打掉 building_damage 的 10%")
	# 投石车：远程 + 攻城标签。
	var cat = UnitRes.create(cfg, "cat-test", "投石车", tile, "p1", "catapult")
	ok(cat != null and bool(cat.ranged) and bool(cat.siege), "（前提）投石车是攻城远程")
	if cat != null:
		base.hp = base.hp_max
		CombatRes.attack_building(w, cfg, cat, base)
		var cp = w.projectiles[w.projectiles.size() - 1]
		ok(bool(cp.ignore_reduction), "★★ 投石车的投掷物带攻城标签")
		ProjectileRes._impact(w, cfg, cp)
		near(base.hp_max - base.hp, float(cfg.building_damage), 1e-4,
			"★★ 投石车对建筑仍是全额 building_damage")
