## test_melee_building.gd —— 回归：近战单位「到了终点却在建筑旁徘徊、不打它」（本轮修的 bug）
##
## ★★ 症状（用户报的）：把一个近战单位派到**靠近敌方建筑**的点，它到了之后在
##   「路径终点」与「建筑旁」之间来回徘徊、就是不拆那座建筑。
##
## ★★ 根因：移动命令走完会在落点 `settled_goal` 站定（`has_settled_goal = true`）。
##   之后它自动锁定那座建筑、走过去 —— 可**同一帧** `tick_frame` 紧接着调
##   `reclaim_settled_spot`，把「没在动 + 离旧落点很远」的单位又拽回旧落点
##   ⇒ 再去打 ⇒ 又被拽回 …… 无限来回。
##   修法：**自动索敌到目标时**（`combat.acquire_target`）`clear_settled_spot()`。
##   ⚠️ 只在自动索敌处清；敌人 AI 的 `set_building_target`（拆挡路的墙）不清 ——
##      那条路依赖「拆完继续赶路」（test_building_body 的「从箭塔缝穿过去」钉着它）。
##
## ★ 两条断言：机制层（自动索敌清落点）+ 端到端（进射程后会持续打、不跑回旧落点）。
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


## 一、机制：**自动索敌到目标时**必须放弃「走回旧落点」
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
	# 假装它刚走完移动命令、在落点站定（这就是出 bug 的前提状态）
	m.settled_goal = m.pos
	m.has_settled_goal = true
	ok(CombatRes.acquire_target(w, cfg, m, -1), "（前提）自动索敌锁到了它")
	ok(not m.has_settled_goal,
		"★ 自动索敌到目标后作废旧落点（否则 reclaim 会把它拽回去 → 来回徘徊）")


## 二、端到端：派到靠近敌方建筑的点 → 到点后持续攻击，而不是来回徘徊
func _test_no_pacing(cfg) -> void:
	var w = require_world(cfg)
	var m = _melee_of(w)
	ok(m != null, "（前提）有一个近战单位")
	if m == null:
		return
	m.hp = 100000.0
	w.units = [m]                      # 只留它一个（别的将领去拆塔会干扰判据）

	# 在近战单位旁边找一格建敌方箭塔
	var tt: Vector2i = _free_tile_near(w, int(m.tx) + 3, int(m.ty))
	ok(tt.x >= 0, "（前提）找得到建塔的空格")
	if tt.x < 0:
		return
	var tower = w.add_building("tower", tt.x, tt.y, "p2", false, true)
	ok(tower != null, "（前提）敌方箭塔建好了")
	if tower == null:
		return

	# 把「移动命令的终点」放在离塔**最远的、仍在警戒半径内**的那一格 —— 复现用户场景：
	#   终点与建筑之间有一段距离 ⇒ 一旦被 reclaim 拽回去，离塔就会明显超出射程。
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

	# ① 先跑到它**第一次进入射程**（这时才开始真正打 —— 观察窗口从这一刻算起，
	#    不能把「还在落点」也计进去，否则量到的永远是落点距离）
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

	# ② 进入射程后再跑 2 秒：它应当**留在射程内持续打**，而不是被拽回旧落点
	#    ★ 抓 bug 的判据：修之前它会跑回终点（离塔 ≈ 落点距离 3~4 格），远大于射程。
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


# ------------------------------------------------------------------
# 帮助函数
# ------------------------------------------------------------------
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


## 在 (cx,cy) 周围找到「离它最远、但仍 ≤ aggro 格」的可站格（抓 bug 用：终点要够远）
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
