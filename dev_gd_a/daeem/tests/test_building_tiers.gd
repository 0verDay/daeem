## test_building_tiers.gd —— 建筑页第二行（石墙 / 警戒塔）要 2 级大本营（2026.10.26）
extends "res://tests/test_case.gd"

const CommandRes = preload("res://logic/command_processor.gd")

func _initialize() -> void:
	_case_name = "test_building_tiers"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_unlock_by_base_level(cfg)
	_test_build_command_gate(cfg)

func _test_config(cfg) -> void:
	eq(cfg.building_tier("wall"), 1, "木墙第 1 行")
	eq(cfg.building_tier("tower"), 1, "哨塔第 1 行")
	eq(cfg.building_tier("stone_wall"), 2, "★★ 石墙第 2 行")
	eq(cfg.building_tier("watch_tower"), 2, "★★ 警戒塔第 2 行")

func _test_unlock_by_base_level(cfg) -> void:
	var w = require_world(cfg)
	ok(w.building_unlocked("p1", "wall"), "1 级大本营：木墙可建")
	ok(w.building_unlocked("p1", "tower"), "1 级大本营：哨塔可建")
	ok(not w.building_unlocked("p1", "stone_wall"), "★★ 1 级大本营：石墙未解锁")
	ok(not w.building_unlocked("p1", "watch_tower"), "★★ 1 级大本营：警戒塔未解锁")
	eq(w.debug_upgrade_base_to_level(2, "p1"), "", "（摆场面）把大本营拉到 2 级")
	ok(w.building_unlocked("p1", "stone_wall"), "★★ 2 级大本营：石墙解锁")
	ok(w.building_unlocked("p1", "watch_tower"), "★★ 2 级大本营：警戒塔解锁")

func _test_build_command_gate(cfg) -> void:
	var w = require_world(cfg)
	w.resources["food"] = 10000.0
	w.resources["gold"] = 10000.0
	var base = w.find_base_of("p1")
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	var tile := _free_growth_tile(w, base.tx + 2, base.ty)
	ok(tile.x >= 0, "（前提）大本营附近有可建造的空地")
	if tile.x < 0:
		return
	var before := _count_type(w, "stone_wall")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "build", "build_type": "stone_wall",
		"tx": tile.x, "ty": tile.y, "faction": "p1"}),
		"★★ 1 级大本营不能建石墙")
	var evts: Array = w.tick(0.01)
	eq(_reject_reason(evts, "build_rejected"), "base_level", "★★ 拒因码 = base_level")
	eq(_count_type(w, "stone_wall"), before, "★ 被拒时没有偷偷建出来")

	w.debug_upgrade_base_to_level(2, "p1")
	var tile2 := _free_growth_tile(w, base.tx + 2, base.ty)
	ok(tile2.x >= 0, "（前提）2 级后还有空地")
	if tile2.x < 0:
		return
	ok(CommandRes.apply(w, cfg, {
		"kind": "build", "build_type": "stone_wall",
		"tx": tile2.x, "ty": tile2.y, "faction": "p1"}),
		"★★ 2 级大本营可以建石墙")
	eq(_count_type(w, "stone_wall"), before + 1, "★ 石墙真的建出来了")
	var tile3 := _free_growth_tile(w, base.tx + 2, base.ty)
	ok(tile3.x >= 0, "（前提）还有空地建警戒塔")
	if tile3.x < 0:
		return
	ok(CommandRes.apply(w, cfg, {
		"kind": "build", "build_type": "watch_tower",
		"tx": tile3.x, "ty": tile3.y, "faction": "p1"}),
		"★★ 2 级大本营可以建警戒塔")

func _reject_reason(events: Array, type: String) -> String:
	for e in events:
		if String((e as Dictionary).get("type", "")) == type:
			return String((e as Dictionary).get("reason", ""))
	return ""

func _count_type(w, type: String) -> int:
	var n := 0
	for b in w.building_list:
		if b != null and b.alive and String(b.type) == type:
			n += 1
	return n

func _free_growth_tile(w, x: int, y: int) -> Vector2i:
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if r > 0 and absi(dx) != r and absi(dy) != r:
					continue
				var tx := x + dx
				var ty := y + dy
				if not w.map.tile_exists(tx, ty):
					continue
				if not w.can_build_at(tx, ty):
					continue
				if not w.zone_allows_build(tx, ty, "p1"):
					continue
				return Vector2i(tx, ty)
	return Vector2i(-1, -1)
