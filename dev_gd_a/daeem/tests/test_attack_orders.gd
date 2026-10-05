## test_attack_orders.gd —— 攻击命令（右键点敌人 / 点建筑 / 双击行军攻击）
##
## 需求原话：
##   「左键/数字键选中己方单位后，右键单击敌人/建筑 → 优先攻击该敌人/建筑，
##     右键双击 → 行军攻击至该地点（逻辑等同于星际争霸2的按 a 攻击）」
##   「给己方单位增加索敌建筑的机制」
##
## 这套断言盯六件事：
##   1. 点名攻击单位：真的会一路追上去把它打掉（**不受追击上限约束**）
##   2. 点名攻击建筑：靠近 → 拆（复用「先靠近再打」那条路）
##   3. 行军攻击：走到目标点；路上遇敌就停下来打，**打完了继续走**
##   4. 普通移动 / 停止会取消攻击命令（明确命令优先）
##   5. 索敌建筑：玩家阵营的单位会主动打敌方建筑；NPC 敌人**不会**（它们的建筑目标由 AI 指定）
##   6. 命令校验：不能拿自己人当靶子、不能空指向、别的阵营不能借 id 指挥我的单位
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const CollisionRes = preload("res://logic/collision.gd")
const FactionRes = preload("res://logic/faction.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CombatRes = preload("res://logic/combat.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_attack_orders"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_attack_unit(cfg)
	_test_attack_building(cfg)
	_test_ordered_building_not_distracted(cfg)
	_test_ordered_target_ignores_leash(cfg)
	_test_attack_move_resumes(cfg)
	_test_move_cancels_orders(cfg)
	_test_players_acquire_buildings(cfg)
	_test_npc_does_not_acquire_buildings(cfg)
	_test_ai_acquires_buildings(cfg)
	_test_command_guards(cfg)
	_test_chase_needs_no_arrival_slot(cfg)
	_test_chase_direct_line(cfg)
	_test_chase_repath_gate(cfg)
	_test_leash_no_jitter(cfg)
	_test_leash_anchor_follows_target(cfg)


# ------------------------------------------------------------------
# 8. ★★ 追击不为「落点空位」买单（行军攻击 20 fps 的头号原因）
#
# 追击的落点永远是**敌人脚下那一格**，而敌人就站在那儿 —— 于是每次追击寻路都会
# 命中 `_arrival_congested`，白跑一遍 `_find_arrival_slot`：
#   全图可达掩码（C# 内核约 0.5 ms）+ 十几个候选点各扫一遍 1000 个单位（约 226 µs）。
# 索敌是批量算的，几百个单位**同一帧**首次锁定目标 → 单帧 200+ ms。
#
# 这套断言盯住「分流没有被改回去」：
#   `move_to(settle = true)`  = 站到某个点上 → 被占时要换空位（功能仍在）
#   `move_to(settle = false)` = 向某个点靠近（追击）→ 落点原样保留
# ------------------------------------------------------------------
func _test_chase_needs_no_arrival_slot(cfg) -> void:
	var w = require_world(cfg)
	var a = w.units[0]
	var b = w.units[1]
	ok(a != null and b != null, "有两个己方单位")
	if a == null or b == null:
		return
	# 只留这两个，避免附属兵把它们挤走
	w.units = [a, b]
	var spot := _free_tile(w, a.tx + 6, a.ty)
	var want: Vector2 = GridRes.center_of(spot)
	a.stop()
	# ⚠️ 堵的人要**偏开落点心**一点：正压在落点心上时，`_find_arrival_slot`
	#    的候选圈（半径 step*1.5）整个落在「离它 < need」的范围里，
	#    于是一个空位都挑不出来、原样返回原点 —— 那是另一回事，测不出分流。
	var need: float = a.min_unit_distance(cfg)
	a.pos = want + Vector2(need * 0.6, 0.0)
	a.sync_tile(w.map)
	b.stop()
	b.pos = GridRes.center_of(Vector2i(spot.x - 3, spot.y))
	b.sync_tile(w.map)

	# a 站定在 want 旁边 → want 对 b 来说是「被别人占着的落点」
	ok(not a.moving, "a 已经站定（只有站定的单位才算占位）")

	ok(b.move_to(w, cfg, want, true), "settle=true 的 move_to 被接受")
	ok(b.goal != want, "★ settle=true：落点被占 → 自动换成旁边某个空位（功能没丢）")
	ok(b.goal.distance_to(want) < 3.0, "换出来的空位就在附近")

	ok(b.move_to(w, cfg, want, false), "settle=false 的 move_to 被接受")
	ok(b.goal.distance_to(want) < 1e-9,
		"★★ settle=false（追击）：落点**原样**就是目标点，不去找空位 —— 这是 20 fps 那一刀的修复")


# ------------------------------------------------------------------
# 9. ★★ 近距离追击走直线：既不建距离场，也不拉直
#
# 每个**不同的敌人所在格**都要一张新距离场（一次全图 Dijkstra），而 LRU 只有 4 张；
# 几百个单位同帧锁定目标 = 同帧几十次 Dijkstra（实测单帧 21.5 ms）。
# ------------------------------------------------------------------
func _test_chase_direct_line(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	ok(u != null, "有一个单位")
	if u == null:
		return
	w.units = [u]
	var spot := _free_tile(w, u.tx, u.ty)
	u.stop()
	u.pos = GridRes.center_of(spot)
	u.sync_tile(w.map)

	# 近处、直线可切 → 路径就是那一个点
	var near_pt: Vector2 = u.pos + Vector2(2.0, 0.5)
	ok(u.chase_to(w, cfg, near_pt), "chase_to 近处目标成功")
	ok(u.path.size() == 1, "★ 近处追击只给一个路点（不建场、不拉直）")
	ok(u.path[0].distance_to(near_pt) < 1e-9, "那个路点就是目标点本身")
	ok(u.moving and u.has_goal, "追击后进入移动状态")

	# 隔一堵墙 → 必须退回真正的寻路（不能穿墙）
	# ⚠️ 墙必须是**敌方**的：己方的墙同阵营可通行，挡不住自己（判定基准是 same_side）。
	var wall_tile := Vector2i(spot.x + 1, spot.y)
	var wall = w.add_building("wall", wall_tile.x, wall_tile.y, "enemy")
	ok(wall != null, "在中间放一堵敌方的城墙")
	ok(not PathfinderRes.passable(w.map, w.buildings, cfg, wall_tile.x, wall_tile.y, u.faction),
		"那堵墙对本方不可通行")
	var through: Vector2 = GridRes.center_of(Vector2i(spot.x + 2, spot.y))
	ok(u.chase_to(w, cfg, through), "chase_to 隔墙目标仍然给出命令")
	var straight: bool = u.path.size() == 1 and u.path[0].distance_to(through) < 1e-9
	ok(not straight, "★ 直线被墙挡住时不走直线（退回距离场 / A*）")
	var bad := 0
	var prev: Vector2 = u.pos
	for p in u.path:
		if not PathfinderRes.segment_clear(w.map, w.buildings, cfg, prev, p, u.faction):
			bad += 1
		prev = p
	ok(bad == 0, "★ 绕墙路径的每一段都不穿墙（没有为了省事放弃安全）")


# ------------------------------------------------------------------
# 10. ★★ 目标没挪地方就不重算路径
#
# 原来是无条件「每 repath_sec 秒重算一次」：1000 个单位在打**站着不动**的目标
# （墙 / 建筑 / 站定的单位）时，每秒 3000+ 次完整寻路全是白费。
# ------------------------------------------------------------------
func _test_chase_repath_gate(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	var e = w.spawn_enemy(u.tx + 3, u.ty)
	ok(u != null and e != null, "有一个单位和它旁边的敌人")
	if u == null or e == null:
		return
	w.units = [u, e]
	e.hold_position = true                 # 站定不动
	u.stop()
	CombatRes.repath_calls = 0
	u.target = e
	u.reset_repath()

	# 目标不动：第一次要算，之后 repath_sec 之内不该再算
	w.tick(DT)
	var after_first: int = CombatRes.repath_calls
	w.tick(DT)
	w.tick(DT)
	ok(after_first >= 1, "锁定目标后第一次追击会算路径")
	ok(CombatRes.repath_calls == after_first,
		"★ 目标没动 → 不重算路径（原来每 repath_sec 就白算一次）")

	# 目标真的挪了地方 → 必须重算
	e.pos += Vector2(cfg.repath_min_move * 3.0, 0.0)
	u.repath_timer = 0.0
	w.tick(DT)
	ok(CombatRes.repath_calls > after_first,
		"★ 目标挪出 repath_min_move 之后会重算（不是干脆不追了）")


# ------------------------------------------------------------------
# 1. 点名攻击单位：一路追上去打掉
# ------------------------------------------------------------------
func _test_attack_unit(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	var e = w.spawn_enemy(g.tx + 4, g.ty)
	ok(g != null and e != null, "有将领 1 和一个敌人")
	if g == null or e == null:
		return
	w.units = [g, e]                     # 隔离：只留这两个，别让附属兵/守军搅乱
	e.hold_position = true               # 靶子别跑
	var hp0: float = e.hp

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"}),
		"右键点敌人的攻击命令被接受")
	ok(g.ordered_target == e, "★ 命令记在 ordered_target 上（玩家点名的目标）")
	ok(g.target == e, "当前交战目标也切成了它")

	var n := 0
	while n < 1200 and e.alive:
		w.tick(DT)
		n += 1
	ok(not e.alive, "★ 点名目标被打掉了（用了 %d 帧）" % n)
	ok(e.hp < hp0, "靶子确实掉了血（%.0f → %.0f）" % [hp0, e.hp])


# ------------------------------------------------------------------
# 2. 点名攻击建筑：靠近 → 拆
# ------------------------------------------------------------------
func _test_attack_building(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	# ★ 先把这张图自带的建筑（对家据点的城墙 / 箭塔）清掉：
	#   「拆完之后 `target_building` 要清空」这条断言会被**别的**敌方建筑搅乱 ——
	#   将领拆穿目标墙之后站在 (15,8)，而对家据点就在 (19,7) 一带，
	#   自动索敌会立刻锁上那一段墙（实测就是这样假失败的）。
	for b in w.building_list.duplicate():
		if b.owner == "enemy":
			w.remove_building(b, true)
	w.refresh_ownership()
	var t := _free_tile(w, g.tx + 4, g.ty)
	var wall = w.add_building("wall", t.x, t.y, "p2")     # 对家城墙：不还手，断言干净
	ok(g != null and wall != null, "有将领 1 和对家城墙")
	if g == null or wall == null:
		return
	w.units = [g]
	var hp0: float = wall.hp

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "tx": wall.tx, "ty": wall.ty, "faction": "p1"}),
		"右键点建筑的攻击命令被接受")
	ok(g.ordered_building == wall, "★ 命令记在 ordered_building 上")
	ok(g.target_building == wall, "当前建筑目标也切成了它")

	var n := 0
	while n < frames_at_baseline(cfg, 1500) and wall.alive:
		w.tick(DT)
		n += 1
	ok(not wall.alive, "★ 点名的建筑被拆掉了（用了 %d 帧）" % n)
	# 命令的清理发生在「目标没了」之后的那一帧（收尸在 tick 末尾），所以再跑几帧再断言
	for i in 5:
		w.tick(DT)
	ok(g.ordered_building == null, "拆完之后命令自动清掉（命令完成）")
	ok(g.target_building == null, "建筑目标也清掉了")


# ------------------------------------------------------------------
# 2.5 ★ 回归（手玩报的 bug）：点名拆建筑时**只打这一个**，不能被旁边的敌人拽走
#
# 症状：右键点敌方箭塔 → 单位走到箭塔附近 → 随机打周围的敌人，箭塔反而没人管。
# 根因：单位走到地方会 `halt()`（moving 变 false），而警戒分支是「静止就索敌」，
#       于是每一次「刚站定」都把旁边的敌人认成新目标，玩家点名的建筑被顶掉了。
# 修法：`ordered_building` 还活着时，这一帧**不做任何自动索敌**（见 combat.update_unit）。
# ------------------------------------------------------------------
func _test_ordered_building_not_distracted(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	var t := _free_tile(w, g.tx + 5, g.ty)
	var tower = w.add_building("tower", t.x, t.y, "p2")
	# 就在箭塔旁边放一个敌人：它会打我们（AI 索敌单位），但我们**不许**还手打它
	var decoy = w.spawn_enemy(t.x - 2, t.y)
	ok(g != null and tower != null and decoy != null, "将领 / 对家箭塔 / 旁边的敌人都在")
	if g == null or tower == null or decoy == null:
		return
	w.units = [g, decoy]
	decoy.hold_position = true           # 让它在原地打，别追着跑

	# ★★ 给将领补足血量：这一节验的是**「点名的建筑不会被旁边的敌人顶掉」**这条瞄准规则，
	#    不是数值平衡。而本轮将领的数值改成「= 它所属兵种那一套」之后
	#    （长枪兵 160 血 / 20 伤害，原来 200 血 / 26 伤害），单个将领已经打不过
	#    「箭塔 + 旁边一个敌人」的合击 —— 它会先阵亡，于是箭塔永远拆不掉，
	#    这条断言就会因为**和它要验的东西无关**的原因假失败。
	#    （同类做法在本项目里已有先例：test_zone_capture / test_building_body 也这样借血。）
	g.hp_max = 5000.0
	g.hp = 5000.0

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "tx": tower.tx, "ty": tower.ty, "faction": "p1"}),
		"点名拆那座箭塔")

	var hit_decoy := 0
	var frames := 0
	while frames < frames_at_baseline(cfg, 1200) and tower.alive:
		w.tick(DT)
		frames += 1
		if g.last_target == decoy:
			hit_decoy += 1
	ok(hit_decoy == 0,
		"★★ 全程没有把火力转到旁边那个敌人上（%d 帧里 %d 次）" % [frames, hit_decoy])
	ok(not tower.alive, "★ 点名的箭塔被拆掉了（%.1f 秒）" % (float(frames) * DT))
	ok(g.target == null and g.target_building == null, "拆完之后不残留交战目标")

	# 命令完成之后，警戒才重新接管：这时旁边还有敌人，它应当自己去打
	if decoy.alive:
		w.tick(DT)
		ok(g.target == decoy, "★ 命令完成之后才恢复自动索敌（这时才去打旁边的敌人）")


# ------------------------------------------------------------------
# 3. 玩家点名的目标不受追击上限约束
# ------------------------------------------------------------------
## 警戒自己找到的目标，追出 leash_range 就会放弃；玩家点名的目标必须一路追。
func _test_ordered_target_ignores_leash(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	var e = w.spawn_enemy(g.tx + 10, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true
	CommandRes.apply(w, cfg, {"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"})

	# 追到「远远超出 leash」为止：这条要量的不是「有没有打死」，而是**有没有放弃**
	var leash: float = g.leash_range(cfg)
	var start: Vector2 = g.pos
	var max_dist := 0.0
	var n := 0
	while n < frames_at_baseline(cfg, 600) and e.alive:
		w.tick(DT)
		n += 1
		max_dist = maxf(max_dist, g.pos.distance_to(start))
	ok(g.anchor == null, "点名攻击不设 anchor（追击上限的参照点）—— 这条就是不受 leash 的机制")
	ok(max_dist > leash,
		"★ 一路追出了追击上限还没放弃（最远 %.1f 格 > leash %.1f 格）" % [max_dist, leash])


# ------------------------------------------------------------------
# 4. 行军攻击：路上遇敌就打，打完了继续走
# ------------------------------------------------------------------
func _test_attack_move_resumes(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	if g == null:
		return
	w.units = [g]
	g.stop()
	g.pos = GridRes.center_of(Vector2i(4, 13))
	g.sync_tile(w.map)

	# 路上（离起点 3 格）放一个敌人，目标点在 8 格外
	var blocker = w.spawn_enemy(7, 13)
	var goal := GridRes.center_of(Vector2i(12, 13))
	ok(blocker != null, "路上放了一个敌人")
	blocker.hold_position = true

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack_move", "ids": [g.id], "x": goal.x, "y": goal.y, "faction": "p1"}),
		"行军攻击命令被接受")
	ok(g.has_attack_move, "★ 行军攻击标记打上了")

	# 跑到「打过一架、并最终到达目标点」
	var engaged := false
	var n := 0
	while n < 3000:
		w.tick(DT)
		n += 1
		if g.target == blocker or g.last_target == blocker:
			engaged = true
		if not g.moving and g.pos.distance_to(goal) < 1.6:
			break
	ok(engaged, "★ 路上遇到敌人时停下来打了（交战过）")
	ok(not blocker.alive, "挡路的敌人被打掉了")
	ok(g.pos.distance_to(goal) < 1.6,
		"★ 打完之后**继续走**到了目标点（距目标 %.3f 格）" % g.pos.distance_to(goal))
	# 到点之后还要再跑一帧才会把「行军攻击」标记收掉（判定在 tick 的决策分支里）
	for i in 90:
		w.tick(DT)
	ok(not g.has_attack_move, "到了之后行军攻击标记清掉（命令完成）")


# ------------------------------------------------------------------
# 5. 普通移动 / 停止会取消攻击命令
# ------------------------------------------------------------------
func _test_move_cancels_orders(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	var e = w.spawn_enemy(g.tx + 3, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true

	CommandRes.apply(w, cfg, {"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"})
	ok(g.ordered_target == e, "先点一个目标")
	ok(g.order_move(w, cfg, GridRes.center_of(Vector2i(g.tx - 4, g.ty))), "再下一条普通移动命令")
	ok(g.ordered_target == null and g.target == null, "★ 普通移动把点名目标清掉了")

	CommandRes.apply(w, cfg, {"kind": "attack_move", "ids": [g.id], "x": 3.0, "y": 13.0, "faction": "p1"})
	ok(g.has_attack_move, "行军攻击标记打上了")
	g.order_move(w, cfg, GridRes.center_of(Vector2i(g.tx - 3, g.ty)))
	ok(not g.has_attack_move, "★ 普通移动也把行军攻击清掉了")

	CommandRes.apply(w, cfg, {"kind": "attack_move", "ids": [g.id], "x": 3.0, "y": 13.0, "faction": "p1"})
	g.stop()
	ok(not g.has_attack_move and g.ordered_target == null, "「停止」同样清掉所有攻击命令")


# ------------------------------------------------------------------
# 6. 索敌建筑：玩家会，NPC 不会
# ------------------------------------------------------------------
func _test_players_acquire_buildings(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	if g == null:
		return
	w.units = [g]
	g.stop()
	g.pos = GridRes.center_of(Vector2i(4, 13))
	g.sync_tile(w.map)
	# 在警戒半径内（4 格）放一座对家箭塔
	var t := _free_tile(w, 6, 13)
	var tower = w.add_building("tower", t.x, t.y, "p2")
	ok(tower != null, "放了一座对家箭塔")
	if tower == null:
		return
	ok(not FactionRes.same_side(tower.owner, g.faction), "它是敌对建筑")

	w.tick(DT)
	ok(g.target_building == tower,
		"★ 玩家单位会**主动索敌建筑**：站着不动也会锁定射程外的敌方箭塔")

	# 附近同时有敌方单位时，优先打单位（不是建筑）
	var e = w.spawn_enemy(g.tx + 2, g.ty)
	if e != null:
		e.hold_position = true
		g.stop()                     # 先站住（警戒只在静止时索敌；这里也顺带清掉旧目标）
		w.tick(DT)
		ok(g.target == e, "★ 有敌方单位时优先打单位，而不是建筑")


func _test_npc_does_not_acquire_buildings(cfg) -> void:
	var w = require_world(cfg)
	var e = w.spawn_enemy(4, 13)
	if e == null:
		return
	w.units = [e]
	e.hold_position = true
	var t := _free_tile(w, 6, 13)
	var tower = w.add_building("tower", t.x, t.y, FactionRes.DEFAULT_FACTION)
	ok(tower != null, "玩家箭塔放好了")
	var n := 0
	while n < 120:
		w.tick(DT)
		n += 1
	ok(e.target_building == null,
		"★ 纯 `enemy_ai` 测试敌人**仍然不会**自动索敌建筑（它要一路推向据点；" +
		"顺手拆路边建筑会把它钉在半路）")
	ok(e.target == null, "附近没有玩家单位时它谁也不打")


## ★★ 本次新增：AI 阵营对建筑的索敌（用户需求原话：「当我在敌方部队附近建造建筑时，
##   敌方不会有想打掉这个建筑……需要为敌方 ai 添加检测和攻击周围环境中敌人的逻辑」）。
##
## 验的是**放开之后真正生效的那一类单位**：不是 `enemy_ai` 的测试敌人（见上一节，
## 它被明确排除），而是有驻防归属 / 非 NPC 的 AI 单位 —— 也就是战役里的敌方阵营部队。
## 判据与上面那条 NPC 用例**成对**：一条钉住「谁不看建筑」，一条钉住「谁看建筑」。
func _test_ai_acquires_buildings(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	ok(g != null, "（前提）有己方将领")
	if g == null:
		return
	# 把将领的阵营改成**非 NPC 的敌方 AI 阵营**：这正是「敌军 AI」在数据里的样子
	# （`config.ai.factions[].id` 默认叫 `ai`，与 `enemy_ai` 的测试敌人 `enemy` 不是一族）。
	var ai_side := "ai"
	g.faction = ai_side
	for m in w.retinue_of(String(g.id)):
		m.faction = ai_side
	w.units = [g]
	g.hold_position = true

	# ★ 先把它挪到**远离自家大本营**的空地：大本营本身也是「敌方建筑」，
	#   站在自家基地旁边的话最近建筑永远是它（实测：第一版就是这么假失败的 ——
	#   它去锁了 (7,2) 的大本营而不是我放的箭塔）。要验的是「会主动找建筑」，
	#   所以场景里**只留一栋可打建筑**最干净。
	var spot := _free_tile(w, 2, w.map.rows - 3)
	g.stop()
	g.pos = GridRes.center_of(spot)
	g.sync_tile(w.map)

	# 在它警戒半径内放一栋**玩家**的箭塔（`my_faction` 是 p1）
	var t := _free_tile(w, g.tx + 2, g.ty)
	var tower = w.add_building("tower", t.x, t.y, "p1")
	ok(tower != null, "在敌方 AI 单位警戒半径内放了一栋玩家箭塔")
	if tower == null:
		return
	# 场景里只留这栋塔与它自己：把世界里的建筑表按「这栋塔 + 大本营」收口太绕，
	# 所以直接断言「它锁上的是**我放的那栋**」——最近建筑若不是它，这条就会红。
	var n := 0
	while n < 120:
		w.tick(DT)
		n += 1
	ok(g.target_building == tower,
		"★★ 敌方 AI 单位会**主动检测并锁定**附近的敌方建筑（本次按需求新增）")
	ok(g.target == null, "★ 附近没有敌方单位时，它的目标只有那栋建筑")


# ------------------------------------------------------------------
# 7. 命令校验
# ------------------------------------------------------------------
func _test_command_guards(cfg) -> void:
	# ★ 这一节要验「不能把自己人当攻击目标」，所以它必须有**一个自己人**可指 ——
	#   用带附属兵的世界（`require_world_with_escorts`），别再用光杆将领的
	#   `require_world()`：那一个 `retinue_of` 恒为空，取 `[0]` 会直接下标越界
	#   （实测：本次改动之前它一直是**假通过**的 —— 前面某个用例留下的状态让它拿到了兵）。
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	if g == null:
		ok(false, "（前提）找得到 general-1")
		return
	var mates: Array = w.retinue_of(g.id)
	if mates.is_empty():
		ok(false, "（前提）general-1 名下有附属兵")
		return
	var mate = mates[0]
	var e = w.spawn_enemy(g.tx + 4, g.ty)
	if e == null:
		return
	w.units = [g, e]

	ok(not CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": mate.id, "faction": "p1"}),
		"不能把**自己人**当攻击目标")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "tx": -1, "ty": -1, "faction": "p1"}),
		"指向空地 / 越界地块的攻击命令被拒")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": "nobody", "faction": "p1"}),
		"指向不存在的单位的攻击命令被拒")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "enemy"}),
		"★ 防冒充：别的阵营不能借我的单位 id 下命令")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "attack_move", "ids": [g.id], "x": 100.0, "y": 100.0, "faction": "enemy"}),
		"★ 防冒充：行军攻击同样按阵营过滤")

	# 正常路径仍然通
	ok(CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"}),
		"自己阵营下达的攻击命令正常生效")


## 找一格空地（避开建筑与山）
func _free_tile(w, x: int, y: int) -> Vector2i:
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := Vector2i(x + dx, y + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(x, y)


# ------------------------------------------------------------------
# 7. ★★ 追击上限（leash）不该把「自动索敌」变成原地抽搐（本轮修的 bug）
#
# 玩家实测报回来的现象：「当我的单位在区划边界时，要追击的敌方单位会在原地抽搐」。
# 根因：参照点 `anchor` 原来在**每次 `acquire_target`** 里都被重置成当前位置 →
#   「离参照点超没超上限」在刚锁定那一刻必然不成立（距离 0），
#   于是「锁定 → 走一格 → 超上限 → 放弃 → 下一帧又锁上」一帧一放一锁 = 抽搐。
#   （区划边界最容易看到：驻防将领正好在那条线上被 general_ai 叫回、又被重新锁定。）
#
# 修法两条（都在 combat.gd）：
#   ① 参照点只在**真正锁定那一刻**设一次，之后由 `_refresh_leash_anchor()` 跟着目标挪；
#   ② 因为上限放弃之后拉一段 `combat.leash_release_cd` 冷却，期间不再自动锁定。
# ------------------------------------------------------------------
func _test_leash_no_jitter(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-1")
	# ⚠️ 距离必须**真的在警戒半径内**：`aggro_range` 默认只有 4 格，
	#    而 `acquire_target` 判的是「距离 − 目标半径 ≤ aggro」—— 放远了这一节前提就不成立
	#    （实测踩到：放在 +5 格时距离 5.0 > 4，第一句就锁不上，看起来像「索敌坏了」）。
	var e = w.spawn_enemy(g.tx + 2, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true                 # 敌人站着不动：这一节量的是**我方**有没有抽
	g.stop()                               # 让它待命 → 靠**自动索敌**去追（玩家命令会绕开 leash）
	ok(g.pos.distance_to(e.pos) - cfg.unit_radius_of(e.unit_type) <= cfg.aggro_range,
		"（前提）敌人确实在警戒半径内（距离 %.2f ≤ %.2f）" % [
			g.pos.distance_to(e.pos), cfg.aggro_range])

	# ---- ① 锁定那一刻：参照点 = 它自己站的位置 ----
	ok(CombatRes.acquire_target(w, cfg, g, 0), "★ 警戒半径内的敌人被锁上")
	ok(g.anchor != null, "★ 自动索敌会设「追击参照点」")
	v2_near(g.anchor, g.pos, 1e-6, "★ 参照点 = **锁定那一刻**它自己站的位置")

	# ---- ② 参照点不该在「同一次交战的再一次索敌」里被重置 ----
	#     把参照点人为推远（模拟「已经追出去 5 格」），单位自己**不动**，再索敌一次：
	#     旧实现会把 anchor 重置成当前位置（距离又变回 0 ⇒ 上限形同不存在）。
	#     ★ 单位必须留在警戒半径内，否则 `acquire_target` 会因为「没东西可锁」而直接返回，
	#       那验的就不是这一条了。
	var keep: Vector2 = g.anchor
	g.anchor = keep - Vector2(5.0, 0.0)
	CombatRes.acquire_target(w, cfg, g, 0)
	v2_near(g.anchor, keep - Vector2(5.0, 0.0), 1e-6,
		"★★ 重复索敌**不会**重置参照点（旧实现就是这里把它抹掉的）")

	# ---- ③ 超出上限 → 放弃 + 拉冷却（而不是下一帧又锁上）----
	ok(g.target == e, "（前提）它现在锁着那个敌人")
	g.anchor = g.pos - Vector2(100.0, 0.0)  # 参照点推远 ⇒ 一定超上限
	CombatRes.update_combat(w, cfg, g)
	ok(g.target == null, "★ 追出上限就放弃")
	ok(g.leash_cd > 0.0, "★★ 放弃之后进入冷却（leash_release_cd = %.2f）" % cfg.leash_release_cd)
	ok(not CombatRes.acquire_target(w, cfg, g, 0),
		"★★★ 冷却期内**不再**把还在警戒半径里的同一个敌人锁上（这就是「抽搐」的断点）")

	# ---- ④ 冷却走完 → 恢复自动索敌 ----
	#     ★ 真实流程：冷却结束后的下一帧，`update_unit` 那一支（「没有 target 才索敌」）
	#       会自己把还在警戒半径里的敌人重新锁上 —— 这里就验证那一件事：
	#       先清掉目标（模拟「刚放弃」），再跑几帧，看它会不会自己接战。
	g.drop_engagement()
	ok(g.target == null, "（前提）现在没有目标")
	for _i in int(ceil(cfg.leash_release_cd / DT)) + 2:
		w.tick(DT)
	ok(g.leash_cd <= 0.0, "★ 冷却会自己走完")
	ok(g.target != null, "★ 冷却完了会**自己**重新接战（没有变成「永远不接战」）")
	# ★ 顺带钉住新加的契约：已经锁着目标时不再重复索敌（否则参照点会被抹平 —— 见 combat.gd）
	ok(not CombatRes.acquire_target(w, cfg, g, 0),
		"★ 已经锁着目标时 `acquire_target` 直接返回（不重复锁、不会抹平参照点）")

	# ---- ⑤ 冷却不拦玩家命令 ----
	g.leash_cd = 10.0
	var far := GridRes.center_of(Vector2i(
		clampi(g.tx + 3, 0, w.map.cols - 1), clampi(g.ty + 3, 0, w.map.rows - 1)))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g.id],
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 冷却期内玩家的移动命令照旧生效")
	eq(g.leash_cd, 0.0, "★ 而且新命令会把冷却清掉（它只是自动索敌的节流）")


# ------------------------------------------------------------------
# 8. ★★ 参照点跟着目标挪（移动目标不该把参照点永远落在原处）
# ------------------------------------------------------------------
## 目标挪过地方之后，参照点要跟着走 —— 于是「追击上限」量的是**我掉队多远**，
## 而不是「我离当初站的那个点多远」（后者会让长距离追击永远判超上限）。
##
## ⚠️ 目标**不动**时这条判据永不通过 ⇒ 参照点永不更新 ⇒ 与修复前**逐位一致**
##    （这正是 `test_attack_orders` 里其它追击用例仍然绿的原因，也是这个修法安全的地方）。
func _test_leash_anchor_follows_target(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-2")
	var e = w.spawn_enemy(g.tx + 2, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true
	g.stop()
	ok(CombatRes.acquire_target(w, cfg, g, 0), "（前提）锁上敌人")
	var anchor0: Vector2 = g.anchor

	# 目标挪出 repath_min_move 格 → 参照点跟着它走
	g.repath_timer = 0.0                    # 这一节的节流判据就是它，先清零
	var moved: Vector2 = e.pos + Vector2(cfg.repath_min_move * 2.0, 0.0)
	CombatRes._refresh_leash_anchor(g, cfg, moved)
	v2_near(g.anchor, moved, 1e-6, "★★ 目标挪过地方之后，参照点跟着它走")
	ok(g.anchor.distance_to(anchor0) > 0.01, "★ 确实动了（不是原地没变）")

	# 目标**没怎么动** → 参照点不动（这条保证「站着不动的目标」行为逐位不变）
	var anchor1: Vector2 = g.anchor
	g.repath_timer = 0.0
	CombatRes._refresh_leash_anchor(g, cfg, Vector2(anchor1.x + 0.01, anchor1.y))
	v2_near(g.anchor, anchor1, 1e-6, "★★ 目标几乎没动 ⇒ 参照点不更新（旧行为不变）")

	# 玩家点名的目标（anchor == null）永远不设参照点
	g.ordered_target = e
	g.anchor = null
	g.repath_timer = 0.0
	CombatRes._refresh_leash_anchor(g, cfg, moved + Vector2(5.0, 0.0))
	ok(g.anchor == null, "★ 点名目标（anchor 为空）不设参照点 ⇒ 不受追击上限约束")
