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
	ok(w.find_base_of("p1") != null, "（前提）有大本营")
	var tile := Vector2i(-1, -1)
	# ★★ 2026.11.19：城墙不再有建造锚点；这里随便拿一个己方地块验证命令必被拒。
	var base = w.find_base_of("p1")
	if base != null:
		tile = Vector2i(int(base.tx), int(base.ty))
	eq(w.build_anchors_for("stone_wall", "p1").size(), 0,
		"★★ 石墙没有建造锚点（局内不能建造）")
	ok(tile.x >= 0, "（前提）拿到一个己方地块用于验证拒因")
	if tile.x < 0:
		return
	var before := _count_type(w, "stone_wall")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "build", "build_type": "stone_wall",
		"tx": tile.x, "ty": tile.y, "faction": "p1"}),
		"★★ 石墙不能在局内建造（只能由战役编辑器预置）")
	var evts: Array = w.tick(0.01)
	eq(_reject_reason(evts, "build_rejected"), "wall_preplaced",
		"★★ 拒因码 = wall_preplaced（比 base_level 更根本）")
	eq(_count_type(w, "stone_wall"), before, "★ 被拒时没有偷偷建出来")

	w.debug_upgrade_base_to_level(2, "p1")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "build", "build_type": "stone_wall",
		"tx": tile.x, "ty": tile.y, "faction": "p1"}),
		"★★ 即使 2 级大本营也不能建石墙")
	w.tick(0.01)
	eq(_count_type(w, "stone_wall"), before, "★ 等级够了也还是建不出来")
	# 警戒塔 = 非城墙建筑：落在建造点位上。
	var tower_anchors: Array = w.build_anchors_for("watch_tower", "p1")
	ok(not tower_anchors.is_empty(), "（前提）还有空着的建造点位建警戒塔")
	if tower_anchors.is_empty():
		return
	var tile3: Vector2i = tower_anchors[0]["tile"]
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
