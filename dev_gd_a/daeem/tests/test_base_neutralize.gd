## test_base_neutralize.gd —— 大本营被击毁 ⇒ 该阵营整体中立化
##
## 口径（已确认）：
##   · 保留归属（faction / owner 不变、区划归属与产出不变）；
##   · 单位 / 建筑停摆变灰：不再移动、索敌、攻击、反击、开火、升级；
##   · 玩家也不能再指挥它们（is_order_locked / order_lock_reason）。
extends "res://tests/test_case.gd"

const SnapshotRes = preload("res://logic/snapshot.gd")
const CombatRes = preload("res://logic/combat.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_base_neutralize"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_kill_base_neutralizes(cfg)
	_test_neutral_units_are_inert(cfg)
	_test_neutral_buildings_do_not_fire(cfg)
	_test_snapshot_round_trip(cfg)

# ------------------------------------------------------------------
# 击毁大本营 → 单位 / 建筑中立化、只发一次事件
# ------------------------------------------------------------------

func _test_kill_base_neutralizes(cfg) -> void:
	var w = _world(cfg)
	var b = w.find_base_of("p1")
	ok(b != null, "（前提）有己方大本营")
	if b == null:
		return
	# 先留一栋己方建筑，验证「残余建筑」也会被中立化
	var wall = _add_own_building(w, "wall")
	ok(wall != null, "（前提）己方多了一栋城墙")
	var hp: float = b.hp_max
	ok(b.take_damage(w.cfg, hp + 1.0, null), "★ 大本营被打到 0 血（不再锁血）")
	ok(not b.alive, "大本营标记为倒下")

	var events: Array = w.tick(DT)
	ok(w.find_base_of("p1") == null, "★ 大本营已经从场上移除")
	ok(w.is_neutralized_faction("p1"), "★ 该阵营进入中立化")
	var n_evt := 0
	for e in events:
		if String((e as Dictionary).get("type", "")) == "faction_neutralized":
			n_evt += 1
	eq(n_evt, 1, "★ faction_neutralized 只发一次")

	for u in w.units:
		if String(u.faction) != "p1":
			continue
		ok(u.neutralized, "单位中立化：%s" % String(u.id))
	if wall != null:
		ok(wall.neutralized, "★ 残余建筑也中立化（保留 owner）")
		eq(String(wall.owner), "p1", "建筑归属没变（区划归属不变）")

	# 重复调用不会重复处理
	w.neutralize_faction("p1")
	eq(w.neutralized_factions.size(), 1, "重复中立化只记一次")

# ------------------------------------------------------------------
# 中立单位：不移动 / 不索敌 / 不反击 / 不接受指令
# ------------------------------------------------------------------

func _test_neutral_units_are_inert(cfg) -> void:
	var w = _world(cfg)
	var b = w.find_base_of("p1")
	if b == null:
		return
	var g = null
	for u in w.units:
		if u.alive and u.is_general() and String(u.faction) == "p1":
			g = u
			break
	ok(g != null, "（前提）找得到将领")
	if g == null:
		return

	w.neutralize_faction("p1")
	ok(g.neutralized, "将领中立化")
	ok(not g.moving and g.path.is_empty(), "★ 路径清空、当场停住")
	ok(g.target == null and g.target_building == null, "★ 交战目标清空")
	eq(g.garrison_zone_id, -1, "★ 驻防 AI 摘掉")
	ok(w.is_order_locked(g), "★ 中立化单位不接受指令")
	eq(w.order_lock_reason(g), "neutralized", "拒因码 = neutralized")

	# 玩家命令层也会过滤它
	ok(not g.order_move(w, w.cfg, g.pos + Vector2(1.0, 0.0), true),
		"（逻辑层）它已不再接受移动命令")

# ------------------------------------------------------------------
# 中立建筑不再开火
# ------------------------------------------------------------------

func _test_neutral_buildings_do_not_fire(cfg) -> void:
	var w = _world(cfg)
	w.cfg.combat_enabled = true
	var tower = _add_own_building(w, "tower")
	ok(tower != null, "（前提）建好一座箭塔")
	if tower == null:
		return
	var e = w.spawn_enemy(tower.tx + 1, tower.ty)
	ok(e != null, "（前提）射程内有敌人")
	if e == null:
		return
	w.projectiles = []
	tower.neutralized = true
	CombatRes.update_towers(w, w.cfg, DT)
	eq(w.projectiles.size(), 0, "★ 中立化箭塔不开火")

	tower.neutralized = false
	CombatRes.update_towers(w, w.cfg, DT)
	ok(w.projectiles.size() >= 1, "（对照）同一座塔没中立化时会开火")

# ------------------------------------------------------------------
# 快照：nz 字段往返
# ------------------------------------------------------------------

func _test_snapshot_round_trip(cfg) -> void:
	var w = _world(cfg)
	w.neutralize_faction("p1")
	var u = null
	for x in w.units:
		if String(x.faction) == "p1":
			u = x
			break
	ok(u != null, "（前提）有一个中立化单位")
	if u == null:
		return
	ok(u.neutralized, "（前提）它已中立化")
	var snap: Dictionary = SnapshotRes.to_snapshot(w)
	var su: Array = snap.get("units", [])
	var found := false
	for d in su:
		if String((d as Dictionary).get("i", "")) == String(u.id):
			found = true
			eq(int((d as Dictionary).get("nz", 0)), 1, "快照带 nz = 1")
	ok(found, "快照里有这个单位")

	u.neutralized = false
	SnapshotRes.apply_snapshot(w, cfg, snap)
	ok(u.neutralized, "★ 应用快照后恢复中立化状态")

# ------------------------------------------------------------------
# 辅助
# ------------------------------------------------------------------

func _world(cfg) -> RefCounted:
	var c = require_config()
	if c == null:
		c = cfg
	else:
		c.combat_enabled = false
	return require_world_with_escorts(c, 3, "p1")

func _add_own_building(w, type: String):
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.can_build_at(x, y):
				continue
			var b = w.add_building(type, x, y, "p1", true, true)
			if b != null:
				return b
	return null
