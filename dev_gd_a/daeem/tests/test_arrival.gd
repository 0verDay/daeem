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
##   4. 推挤一帧能推走 ~0.25 格，而单位自己一帧只走 0.04 格（1/4 速度下 0.01 格）→
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
##
## ⚠️ 这些用例**特意用 y = 14 这一行**：地图上的区划中心按 6×4 的规律摆在
##    (1,1)…(21,13)，y=13 那一行几乎每隔 4 格就有一根中立障碍柱 ——
##    把一整队人点到那一行，会变成「挤在柱子中间」，验的就不是拥挤收敛而是寻路了。
## ⚠️ 这一套用例特意走 **y = 15** 这一行，避开三样东西：
##    · y=13/14 是**森林**（速度减半，拥挤收敛的时序会变）；
##    · 区划中心按规律摆在 (0,12) / (0,17) / (12,12) / (12,17) 这些点上，
##      挤在柱子之间验的就不是拥挤收敛而是寻路了；
##    · 对家据点摆在 (13~16, 12~15)，地标选在 x≤10 就不会撞上它。
func _test_solo_still_exact(cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]
	w.units = [u]
	var target = GridRes.center_of(Vector2i(10, 15))
	u.stop()
	u.pos = GridRes.center_of(Vector2i(4, 15))
	u.sync_tile(w.map)
	u.order_move(w, cfg, target)
	var n := 0
	var cap: int = frames_at_baseline(cfg, 2000)
	while u.moving and n < cap:
		w.tick(DT)
		n += 1
	v2_near(u.pos, target, 1e-3, "★ 单人点到空地时仍然精确停在点击位置（没有被拥挤逻辑改坏）")
	ok(not u.moving, "单人到达后 moving = false")
	# 朝向应当指向最后的移动方向（向右），而不是被落位逻辑污染
	ok(u.facing.x > 0.9, "★ 单人到达后朝向仍然朝右（%.2f, %.2f）" % [u.facing.x, u.facing.y])


## 拥挤：整队点到同一点，必须在合理时间内全部停下
##
## ★ 先关掉战斗：这一套验的是「到达与推挤」；地图预置的两个巡逻兵会在这几秒里
##   迎上来打起来，那会让单位「一边被打一边挤」、`moving` 永远有真。
## ★ 同时把**区划中心**从世界里摘掉（`_clear_zone_centers`）：
##   它们是中立障碍柱，按 6×4 的规律每隔 4 格一根；一整队人挤在柱子之间时，
##   验的就不是「拥挤收敛」而是「绕柱子」。这一套只看到达与推挤。
##   战斗与障碍本身分别在 test_logic / test_attack_orders 里单独验。
func _test_crowd_settles(cfg) -> void:
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	ok(group.size() >= 6, "世界里至少有 6 个单位（实际 %d）" % group.size())

	var settled := -1
	var moving_unit_frames := 0
	var n := 0
	# ★ 帧预算按速度换算（见 test_case.frames_at_baseline）：速度降到基线 1/4 之后，
	#   同样这段路要 4 倍帧数才走得完。
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
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

	# 移动代价不该爆炸：理想 ≈ 单位数 × 路程/速度
	var ideal = float(group.size()) * 8.0 / (cfg.unit_speed * DT)
	# ⚠️ 阈值是**实测值留了余量**，不是理论值：
	#    当前地图（27×22，p1 大本营在 (7,2)）实测「694 帧 / 6346 单位·帧」，
	#    而 `ideal` 那个式子（按 8 格估）只有 ≈ 2133 —— 它估的是**直线 8 格**，
	#    而这一队从出生点绕到 (6,12) 的实际路程比 8 格长得多（要绕过中央那片山）。
	#    所以阈值按「这个式子的 3.5 倍」给，并且把实测值打进日志：
	#    哪天这条路又变长了，先看这行数字，别急着调阈值。
	ok(settled > 0 and settled < frames_at_baseline(cfg, 1500),
		"★ 停下来的时间在合理范围内（%d 帧 < %d；基线速度下的实测基准是 694）"
		% [settled, frames_at_baseline(cfg, 1500)])
	ok(float(moving_unit_frames) < ideal * 3.5,
		"★ 总移动量没有爆炸（%.0f 单位·帧，8 格理想值 ≈ %.0f，上限 %.0f）"
		% [moving_unit_frames, ideal, ideal * 3.5])

	# 每个单位都要落在目标附近（允许被队友挤开一点，但不能跑到天边）
	#
	# ★ 半径本轮 1.5 → 2.5 格，理由是**测出来的一个两难**（详见 config.json 的 _jam_comment）：
	#   单位速度降到 1/4 之后，「挤不过去就认账」的宽限 jam_giveup_sec 两头不能兼顾 ——
	#   调小（1.6）队伍聚得紧（最远 0.68 格），但**单人绕路会停在离点击处 2 格的地方**
	#   （那是硬 bug，test_logic 的「终点就是点击的精确位置」盯着）；
	#   调大（2.4）绕路正常，极端拥挤下队伍就散到 2.05 格。这里选了保「点哪走哪」。
	#   注意这 12 个单位是**被点到同一个精确坐标**的（合成场景）：实战里 ≥4 个单位
	#   走的是队形落点（unit.formation），各自有槽位，不会全挤一个点。
	var spread := 2.5
	var far := 0
	for u in group:
		if u.pos.distance_to(target) > spread:
			far += 1
	eq(far, 0, "★ 所有单位都落在目标 %.1f 格以内（没有谁被挤到别处）" % spread)


## 停下之后必须**真的静止**：位置与朝向都不再变
func _test_crowd_stays_still(cfg) -> void:
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	var n := 0
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
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
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
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
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)

	# 跑到全部停下，然后统计「每个单位从下令到停下」的帧数上限
	var all_settled := -1
	var n := 0
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
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
	# 这里只验「没有无限拖下去」——换算成基线速度仍是 1200 帧（20 秒）这个很宽松的上限。
	ok(all_settled > 0 and all_settled < frames_at_baseline(cfg, 1200),
		"★ 挤不过去时会认账，不会无限努力（%d 帧 < %d）" % [all_settled, frames_at_baseline(cfg, 1200)])

	# 认账之后不能留下「还在 moving」的状态
	for u in group:
		ok(not u.moving, "结束后 %s 不处于移动状态" % u.id)


## 把世界隔离开「只有玩家这一方的单位」。
##
## ★ 为什么必须有这一步：地图上预置了对家守军（`test_map.json` 的 `units`），
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


## 把地图上的**区划中心**从世界里摘掉（只删建筑，地形保持可通行）。
##
## ★ 为什么这套用例需要它：区划中心是中立障碍柱，按 6×4 的规律每隔 4 格一根；
##   一整队人被点到同一格时，如果那一格紧挨着柱子，就变成「挤在柱子缝里」——
##   验的就不再是「拥挤收敛」，而是「绕柱子 + 拥挤」两件事混在一起。
## ★ 只删建筑、不把格子改成山：那会让整片区域的可达性变小，
##   反而把单位逼到更窄的地方去（实测：改成山之后 1200 帧都停不下来）。
func _clear_zone_centers(w) -> void:
	for b in w.building_list.duplicate():
		if b.type == "zone_center":
			w.remove_building(b, true)
	w.refresh_ownership()
