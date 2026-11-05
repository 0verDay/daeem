## test_building_rules.gd —— 2026.11 的三条建筑规则回归：
##   1. 自动索敌优先级：防御建筑 / 大本营 > 墙；资源建筑**永不**自动打（只能手动点）；
##   2. 建筑归属跟随区划（大本营除外）；无主区划由区内建筑先认领；
##   3. 区划内的目标被攻城单位打中 ⇒ 阵地性 AI 整队行军攻击到攻击者处。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const CombatRes = preload("res://logic/combat.gd")
const UnitRes = preload("res://logic/unit.gd")
const GarrisonAiRes = preload("res://logic/garrison_ai.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_building_rules"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_target_priority(cfg)
	_test_zone_ownership(cfg)
	_test_garrison_siege_alert(cfg)


# ------------------------------------------------------------------
# 1) 自动索敌优先级
# ------------------------------------------------------------------
func _test_target_priority(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	ok(g != null, "（前提）有将领")
	if g == null:
		return
	w.units = [g]
	g.stop()
	_clear_enemy_buildings(w)
	var tiles := _free_tiles_near(w, g, 3)
	eq(tiles.size(), 3, "（前提）身边找得到 3 格空地")
	if tiles.size() < 3:
		return
	# ★ 建筑跟随区划：先把这三格所在的区划判给敌方，否则它们会归到玩家名下。
	for t in tiles:
		var z = w.zones.zone_at((t as Vector2i).x, (t as Vector2i).y)
		if z != null:
			(z as Dictionary)["owner"] = "enemy"
	var farm = w.add_building("farm", tiles[0].x, tiles[0].y, "enemy", true, true)
	var wall = w.add_building("wall", tiles[1].x, tiles[1].y, "enemy", true, true)
	var tower = w.add_building("tower", tiles[2].x, tiles[2].y, "enemy", true, true)
	ok(farm != null and wall != null and tower != null, "（前提）资源 / 墙 / 塔都建好")
	if farm == null or wall == null or tower == null:
		return
	ok(CombatRes.acquire_target(w, cfg, g, -1), "★ 有可打目标时能索敌")
	eq(g.target_building, tower, "★★ 自动索敌优先打防御建筑（不是更近的墙 / 资源）")
	# 去掉防御建筑 → 轮到墙
	g.drop_engagement()
	w.remove_building(tower, true)
	ok(CombatRes.acquire_target(w, cfg, g, -1), "★ 没有防御建筑时还能索敌")
	eq(g.target_building, wall, "★★ 没有防御建筑才打墙")
	# 只剩资源建筑 → 自动索敌必须返回空
	g.drop_engagement()
	w.remove_building(wall, true)
	ok(not CombatRes.acquire_target(w, cfg, g, -1), "★★ 只剩资源建筑时**不自动索敌**")
	eq(g.target_building, null, "★★ 资源建筑不会被自动锁定")
	# 手动指定仍然可以打
	ok(g.order_attack_building(w, cfg, farm, true), "★★ 资源建筑仍然接受**手动指定攻击**")
	eq(g.target_building, farm, "手动指定的资源建筑成为目标")


# ------------------------------------------------------------------
# 2) 建筑归属跟随区划
# ------------------------------------------------------------------
func _test_zone_ownership(cfg) -> void:
	var w = require_world(cfg)
	var z = w.zones.zones[0]
	var tiles := _free_tiles_in_zone(w, z, 2)
	eq(tiles.size(), 2, "（前提）区划里有 2 格空地")
	if tiles.size() < 2:
		return
	z["owner"] = "p2"
	var base = w.add_building("base", tiles[0].x, tiles[0].y, "p2", true, true)
	var wall = w.add_building("wall", tiles[1].x, tiles[1].y, "p2", true, true)
	ok(base != null and wall != null, "（前提）大本营与墙建好")
	if base == null or wall == null:
		return
	eq(String(wall.owner), "p2", "（前提）墙属于区划主人")
	z["owner"] = "p1"
	w.refresh_ownership()
	eq(String(wall.owner), "p1", "★★ 区划易主后墙跟随新主人")
	eq(String(base.owner), "p2", "★★ 大本营不跟随区划易主")

	# 无主区划：由区内建筑先认领。
	var z2 = w.zones.zones[1]
	var tiles2 := _free_tiles_in_zone(w, z2, 1)
	eq(tiles2.size(), 1, "（前提）另一个区划有空格")
	if tiles2.is_empty():
		return
	z2["owner"] = ""
	var tower = w.add_building("tower", tiles2[0].x, tiles2[0].y, "p2", true, true)
	ok(tower != null, "（前提）无主区划里的塔建好")
	eq(String(z2.get("owner", "")), "p2", "★★ 无主区划由区内建筑先占")
	eq(String(tower.owner), "p2", "建筑归属就是它认领的区划主人")


# ------------------------------------------------------------------
# 3) 攻城警报：阵地性 AI 整队出击
# ------------------------------------------------------------------
func _test_garrison_siege_alert(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	ok(g != null, "（前提）有将领")
	if g == null:
		return
	var z = w.zones.zone_at(g.tx, g.ty)
	ok(z != null, "（前提）将领站在一个区划里")
	if z == null:
		return
	g.garrison_zone_id = int((z as Dictionary)["id"])
	g.stop()
	# 投石车：敌方单位，放在 6 格外（普通警戒半径之外）。
	var ct := Vector2i(g.tx + 6, g.ty)
	var cat = UnitRes.create(cfg, "cat-test", "投石车", ct, "enemy", "catapult")
	w.units.append(cat)
	ok(bool(cat.siege), "（前提）投石车带攻城标签")
	# 关掉单兵复仇：本用例只验「守军出击」这条独立路径。
	cfg.retaliation_enabled = false
	w.on_unit_attacked(g, cat)
	ok(w.garrison_siege_alerts.has(String(g.id)), "★★ 攻城单位打中区内单位 ⇒ 记下警报")
	GarrisonAiRes.force_next(w)
	GarrisonAiRes.update(w, cfg, DT)
	ok(bool(g.has_attack_move), "★★ 守军整队进入行军攻击状态")
	v2_near(g.attack_move_goal, cat.pos, 0.75, "★★ 目的地就是攻城单位所在处")


# ------------------------------------------------------------------
# helpers
# ------------------------------------------------------------------
func _clear_enemy_buildings(w) -> void:
	for b in w.building_list.duplicate():
		if String(b.owner) != String(w.my_faction):
			w.remove_building(b, true)


func _free_tiles_near(w, u, count: int) -> Array:
	var out: Array = []
	for r in range(1, 5):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var t := Vector2i(int(u.tx) + dx, int(u.ty) + dy)
				if out.has(t):
					continue
				if w.can_build_at(t.x, t.y) and w.zones.zone_at(t.x, t.y) != null:
					out.append(t)
					if out.size() >= count:
						return out
	return out


func _free_tiles_in_zone(w, z: Dictionary, count: int) -> Array:
	var out: Array = []
	for t in (z.get("tiles", []) as Array):
		var tv: Vector2i = t
		if w.can_build_at(tv.x, tv.y):
			out.append(tv)
			if out.size() >= count:
				return out
	return out
