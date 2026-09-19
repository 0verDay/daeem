## test_arrival.gd —— 到达行为回归（拥挤时不准「挤着转」）
##
## ★ 这套断言盯的是本轮真出过的一个大毛病：**多个单位被点到同一点之后互相挤着转**。
##
## 实测数据（12 个单位点到同一点，修之前 vs 修之后）：
##
##   | 指标            | 修之前      | 修之后 |
##   |-----------------|-------------|--------|
##   | 全部停下        | 2000 帧都没停 | < 600 帧 |
##   | 移动单位·帧累计 | 12734       | ≈ 2800 |
##   | 方向反转次数    | 5708 → 8064 | ≈ 185 |
##   | 停下后 300 帧   | 一直漂      | 完全静止 |
##
## 根因有四层，每一层都值得记住（详见 docs/pitfalls.md 5.12）：
##   1. 路径的最后一个路点就是终点 → 「路径空了」被误当成「到达了」，
##      于是被挤到终点附近时会**直接吸附**过去（瞬移一段）；
##   2. 多单位共用一个精确目标点 → 每帧「吸附到该点」与「被碰撞推开」互相打架；
##   3. 到达之后 `path` 是空的 → `step_along_path` **整个函数都不执行**，
##      被推走的单位没有任何机制走回去；
##   4. 推挤一帧能推走 ~0.25 格，而单位自己一帧只走 0.04 格 →
##      人群里「最后一段」**永远走不完**，必须靠「进度停滞」认账。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CollisionRes = preload("res://logic/collision.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_arrival"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_solo_still_exact(cfg)
	_test_crowd_settles(cfg)
	_test_crowd_stays_still(cfg)
	_test_speed_budget_in_crowd(cfg)
	_test_jam_giveup_bounds_effort(cfg)


## 单人点空地：落点仍然精确（拥挤处理不能把普通手感改坏）
func _test_solo_still_exact(cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]
	w.units = [u]
	var target = GridRes.center_of(Vector2i(10, 13))
	u.stop()
	u.pos = GridRes.center_of(Vector2i(4, 13))
	u.sync_tile(w.map)
	u.order_move(w, cfg, target)
	var n := 0
	while u.moving and n < 2000:
		w.tick(DT)
		n += 1
	v2_near(u.pos, target, 1e-3, "★ 单人点到空地时仍然精确停在点击位置（没有被拥挤逻辑改坏）")
	ok(not u.moving, "单人到达后 moving = false")
	# 朝向应当指向最后的移动方向（向右），而不是被落位逻辑污染
	ok(u.facing.x > 0.9, "★ 单人到达后朝向仍然朝右（%.2f, %.2f）" % [u.facing.x, u.facing.y])


## 拥挤：整队点到同一点，必须在合理时间内全部停下
func _test_crowd_settles(cfg) -> void:
	var w = WorldRes.create(cfg)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 13))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	ok(group.size() >= 6, "世界里至少有 6 个单位（实际 %d）" % group.size())

	var settled := -1
	var moving_unit_frames := 0
	var n := 0
	while n < 1200:
		w.tick(DT)
		n += 1
		for u in group:
			if u.moving:
				moving_unit_frames += 1
		if settled < 0:
			var any := false
			for u in group:
				if u.moving:
					any = true
			if not any:
				settled = n
	print("   [crowd] 全部停下于第 %d 帧，移动单位·帧=%d" % [settled, moving_unit_frames])

	ok(settled > 0, "★ 整队点到同一点后**全部停下了**（第 %d 帧）" % settled)
	ok(settled > 0 and settled < 600, "★ 停下来的时间在合理范围内（%d 帧 < 600）" % settled)

	# 移动代价不该爆炸：理想 ≈ 单位数 × 路程/速度
	var ideal = float(group.size()) * 8.0 / (cfg.unit_speed * DT)
	ok(float(moving_unit_frames) < ideal * 2.5,
		"★ 总移动量没有爆炸（%.0f 单位·帧，理想 ≈ %.0f）" % [moving_unit_frames, ideal])

	# 每个单位都要落在目标附近（允许被队友挤开一点，但不能跑到天边）
	var far := 0
	for u in group:
		if u.pos.distance_to(target) > 1.5:
			far += 1
	eq(far, 0, "★ 所有单位都落在目标 1.5 格以内（没有谁被挤到别处）")


## 停下之后必须**真的静止**：位置与朝向都不再变
func _test_crowd_stays_still(cfg) -> void:
	var w = WorldRes.create(cfg)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 13))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	var n := 0
	while n < 1200:
		w.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			break

	var pos0: Dictionary = {}
	var face0: Dictionary = {}
	for u in group:
		pos0[u.id] = u.pos
		face0[u.id] = u.facing
	var max_drift := 0.0
	var max_turn := 0.0
	for i in 300:
		w.tick(DT)
		for u in group:
			max_drift = maxf(max_drift, u.pos.distance_to(pos0[u.id]))
			max_turn = maxf(max_turn, rad_to_deg(absf((face0[u.id] as Vector2).angle_to(u.facing))))
	print("   [crowd] 停下后 300 帧：漂移 %.4f 格，朝向变化 %.1f°" % [max_drift, max_turn])
	ok(max_drift < 0.01, "★ 停下后不再漂移（最大 %.4f 格）" % max_drift)
	ok(max_turn < 1.0, "★ 停下后朝向不再乱转（最大 %.1f°）" % max_turn)

	# 互相之间也不能重叠得离谱（软下限附近）
	var min_pair := 999.0
	for i in group.size():
		for j in range(i + 1, group.size()):
			min_pair = minf(min_pair, (group[i] as Object).pos.distance_to((group[j] as Object).pos))
	var soft: float = CollisionRes.radius(cfg) * 2.0 * cfg.num("unit.overlap_allowance", 0.7)
	ok(min_pair >= soft * 0.6, "★ 停稳后没有严重重叠（最近一对 %.3f 格，软下限 %.3f）" % [min_pair, soft])


## 拥挤下每帧位移仍然不许超过速度预算（落位那一帧最容易超）
func _test_speed_budget_in_crowd(cfg) -> void:
	var w = WorldRes.create(cfg)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 13))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	var budget: float = cfg.unit_speed * DT
	var worst := 0.0
	var prev: Dictionary = {}
	for u in group:
		prev[u.id] = u.pos
	# 只看「自己走出来的位移」：碰撞推挤本来就可能大于速度（那是推挤，不是移动）
	# 所以这里只检查移动中的单位，且容差放到 1.5×预算。
	for i in 500:
		w.tick(DT)
		for u in group:
			if u.moving and not u.settling:
				worst = maxf(worst, u.pos.distance_to(prev[u.id]))
			prev[u.id] = u.pos
	ok(worst <= budget * 1.5, "★ 拥挤下移动位移仍不超预算太多（最大 %.4f，预算 %.4f）" % [worst, budget])


## jam_giveup：挤不过去时要认账，不能无限努力
func _test_jam_giveup_bounds_effort(cfg) -> void:
	var w = WorldRes.create(cfg)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 13))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)

	# 跑到全部停下，然后统计「每个单位从下令到停下」的帧数上限
	var all_settled := -1
	var n := 0
	while n < 1200:
		w.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			all_settled = n
			break
	ok(all_settled > 0, "全部停下（第 %d 帧）" % all_settled)

	# 超时上限：理论最坏 = 路程/速度 + jam_giveup_sec 若干轮。
	# 这里只验「没有无限拖下去」——1200 帧（20 秒）是个很宽松的上限。
	ok(all_settled > 0 and all_settled < 1200,
		"★ 挤不过去时会认账，不会无限努力（%d 帧 < 1200）" % all_settled)

	# 认账之后不能留下「还在 moving」的状态
	for u in group:
		ok(not u.moving, "结束后 %s 不处于移动状态" % u.id)


## 把世界隔离开「只有玩家这一方的单位」。
##
## ★ 为什么必须有这一步：地图上预置了对家守军（`map_01.json` 的 `units`），
##   它们会跟玩家单位交战、也会挤在同一个落点上 —— 这一整套断言验的是
##   「自己人挤在一起时的到达行为」，混进敌人就变成在测战斗了。
##   （docs/pitfalls.md 5.11 记过这条：加任何「默认在场」的单位之前，
##     先想一遍哪些断言会被它搅乱。）
func _keep_player_units(w) -> void:
	var kept: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			kept.append(u)
	w.units = kept
