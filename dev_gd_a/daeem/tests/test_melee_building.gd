## test_melee_building.gd —— 回归：近战单位「到了终点却在建筑旁徘徊、不打它」（本轮修的 bug）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const CombatRes = preload("res://logic/combat.gd")

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_melee_building"
	_run()

func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	_test_acquire_clears_settle(cfg)
	_test_no_pacing(cfg)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)

func _test_acquire_clears_settle(cfg) -> void:
	var w = require_world(cfg)
	var m = _melee_of(w)
	ok(m != null, "（前提）有一个近战单位")
	if m == null:
		return
	var tt: Vector2i = _farthest_standable_within(w, Vector2i(int(m.tx), int(m.ty)), cfg.aggro_range)
	ok(tt.x >= 0, "（前提）旁边找得到一格建敌方建筑")
	if tt.x < 0:
		return
	var tower = w.add_building("tower", tt.x, tt.y, "p2", false, true)
	ok(tower != null, "（前提）敌方箭塔建好了")
	m.settled_goal = m.pos
	m.has_settled_goal = true
	ok(CombatRes.acquire_target(w, cfg, m, -1), "（前提）自动索敌锁到了它")
	ok(not m.has_settled_goal,
		"★ 自动索敌到目标后作废旧落点（否则 reclaim 会把它拽回去 → 来回徘徊）")

func _test_no_pacing(cfg) -> void:
	var w = require_world(cfg)
	var m = _melee_of(w)
	ok(m != null, "（前提）有一个近战单位")
	if m == null:
		return
	m.hp = 100000.0
	w.units = [m]                      # 只留它一个（别的将领去拆塔会干扰判据）

	var tt: Vector2i = _free_tile_near(w, int(m.tx) + 3, int(m.ty))
	ok(tt.x >= 0, "（前提）找得到建塔的空格")
	if tt.x < 0:
		return
	var tower = w.add_building("tower", tt.x, tt.y, "p2", false, true)
	ok(tower != null, "（前提）敌方箭塔建好了")
	if tower == null:
		return

	var dest_tile: Vector2i = _farthest_standable_within(w, tt, cfg.aggro_range)
	ok(dest_tile.x >= 0, "（前提）找得到终点空格")
	if dest_tile.x < 0:
		return
	var dest: Vector2 = GridRes.center_of(dest_tile)
	var dest_d: float = dest.distance_to(tower.center())
	ok(dest_d <= cfg.aggro_range and dest_d >= 2.5,
		"（前提）终点在警戒半径内且离塔足够远（%.2f 格）" % dest_d)

	var reach: float = m.combat_range(cfg) + tower.body_half(cfg)
	var hp0: float = tower.hp
	ok(m.order_move(w, cfg, dest), "（前提）移动命令下达成功")

	var in_range := false
	for i in 2400:
		w.tick(DT)
		if m.pos.distance_to(tower.center()) <= reach:
			in_range = true
			break
	ok(in_range, "★ 到点后走向建筑、进入射程")
	if not in_range:
		return
	eq(m.target_building, tower, "★ 进射程时锁定的就是那座建筑")

	var worst := 0.0
	var damaged := false
	for i in 120:
		w.tick(DT)
		worst = maxf(worst, m.pos.distance_to(tower.center()))
		if tower.hp < hp0:
			damaged = true
	ok(damaged, "★ 真的打到了那座建筑（掉血）")
	ok(worst <= reach + 0.6,
		"★ 进射程后不再跑回旧落点（离塔最远 %.2f 格 ≤ 射程 %.2f + 0.6）" % [worst, reach])

func _melee_of(w):
	for u in w.units:
		if not u.ranged:
			return u
	return null

func _free_tile_near(w, cx: int, cy: int) -> Vector2i:
	for r in range(0, 9):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue
				var t := Vector2i(cx + dx, cy + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(-1, -1)

func _farthest_standable_within(w, tile: Vector2i, aggro: float) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := -1.0
	for ring in range(2, int(ceil(aggro)) + 1):
		for dx in range(-ring, ring + 1):
			for dy in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var t := Vector2i(tile.x + dx, tile.y + dy)
				if not w.can_build_at(t.x, t.y):
					continue
				var d: float = GridRes.center_of(t).distance_to(GridRes.center_of(tile))
				if d <= aggro and d > best_d:
					best_d = d
					best = t
	return best
