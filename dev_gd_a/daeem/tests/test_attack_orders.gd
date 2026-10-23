## test_attack_orders.gd —— 攻击命令（右键点敌人 / 点建筑 / 双击行军攻击）
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

func _test_chase_needs_no_arrival_slot(cfg) -> void:
	# ★ 自由对战只有 #0；用关卡支架凑出两个将领。
	var w = require_world_with_escorts(cfg, 1)
	if w == null:
		return
	var a = w.units[0]
	var b = w.units[1]
	ok(a != null and b != null, "有两个己方单位")
	if a == null or b == null:
		return
	w.units = [a, b]
	var spot := _free_tile(w, a.tx + 6, a.ty)
	var want: Vector2 = GridRes.center_of(spot)
	a.stop()
	var need: float = a.min_unit_distance(cfg)
	a.pos = want + Vector2(need * 0.6, 0.0)
	a.sync_tile(w.map)
	b.stop()
	b.pos = GridRes.center_of(Vector2i(spot.x - 3, spot.y))
	b.sync_tile(w.map)

	ok(not a.moving, "a 已经站定（只有站定的单位才算占位）")

	ok(b.move_to(w, cfg, want, true), "settle=true 的 move_to 被接受")
	ok(b.goal != want, "★ settle=true：落点被占 → 自动换成旁边某个空位（功能没丢）")
	ok(b.goal.distance_to(want) < 3.0, "换出来的空位就在附近")

	ok(b.move_to(w, cfg, want, false), "settle=false 的 move_to 被接受")
	ok(b.goal.distance_to(want) < 1e-9,
		"★★ settle=false（追击）：落点**原样**就是目标点，不去找空位 —— 这是 20 fps 那一刀的修复")

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

	var near_pt: Vector2 = u.pos + Vector2(2.0, 0.5)
	ok(u.chase_to(w, cfg, near_pt), "chase_to 近处目标成功")
	ok(u.path.size() == 1, "★ 近处追击只给一个路点（不建场、不拉直）")
	ok(u.path[0].distance_to(near_pt) < 1e-9, "那个路点就是目标点本身")
	ok(u.moving and u.has_goal, "追击后进入移动状态")

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

	w.tick(DT)
	var after_first: int = CombatRes.repath_calls
	w.tick(DT)
	w.tick(DT)
	ok(after_first >= 1, "锁定目标后第一次追击会算路径")
	ok(CombatRes.repath_calls == after_first,
		"★ 目标没动 → 不重算路径（原来每 repath_sec 就白算一次）")

	e.pos += Vector2(cfg.repath_min_move * 3.0, 0.0)
	u.repath_timer = 0.0
	w.tick(DT)
	ok(CombatRes.repath_calls > after_first,
		"★ 目标挪出 repath_min_move 之后会重算（不是干脆不追了）")

func _test_attack_unit(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
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

func _test_attack_building(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
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
	for i in 5:
		w.tick(DT)
	ok(g.ordered_building == null, "拆完之后命令自动清掉（命令完成）")
	ok(g.target_building == null, "建筑目标也清掉了")

func _test_ordered_building_not_distracted(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	var t := _free_tile(w, g.tx + 5, g.ty)
	var tower = w.add_building("tower", t.x, t.y, "p2")
	var decoy = w.spawn_enemy(t.x - 2, t.y)
	ok(g != null and tower != null and decoy != null, "将领 / 对家箭塔 / 旁边的敌人都在")
	if g == null or tower == null or decoy == null:
		return
	w.units = [g, decoy]
	decoy.hold_position = true           # 让它在原地打，别追着跑

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

	if decoy.alive:
		w.tick(DT)
		ok(g.target == decoy, "★ 命令完成之后才恢复自动索敌（这时才去打旁边的敌人）")

func _test_ordered_target_ignores_leash(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	var e = w.spawn_enemy(g.tx + 10, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true
	CommandRes.apply(w, cfg, {"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"})

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

func _test_attack_move_resumes(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	if g == null:
		return
	w.units = [g]
	g.stop()
	g.pos = GridRes.center_of(Vector2i(4, 13))
	g.sync_tile(w.map)

	var blocker = w.spawn_enemy(7, 13)
	var goal := GridRes.center_of(Vector2i(12, 13))
	ok(blocker != null, "路上放了一个敌人")
	blocker.hold_position = true

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack_move", "ids": [g.id], "x": goal.x, "y": goal.y, "faction": "p1"}),
		"行军攻击命令被接受")
	ok(g.has_attack_move, "★ 行军攻击标记打上了")

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
	for i in 90:
		w.tick(DT)
	ok(not g.has_attack_move, "到了之后行军攻击标记清掉（命令完成）")

func _test_move_cancels_orders(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
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

func _test_players_acquire_buildings(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	if g == null:
		return
	w.units = [g]
	g.stop()
	g.pos = GridRes.center_of(Vector2i(4, 13))
	g.sync_tile(w.map)
	var t := _free_tile(w, 6, 13)
	var tower = w.add_building("tower", t.x, t.y, "p2")
	ok(tower != null, "放了一座对家箭塔")
	if tower == null:
		return
	ok(not FactionRes.same_side(tower.owner, g.faction), "它是敌对建筑")

	w.tick(DT)
	ok(g.target_building == tower,
		"★ 玩家单位会**主动索敌建筑**：站着不动也会锁定射程外的敌方箭塔")

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

func _test_ai_acquires_buildings(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	ok(g != null, "（前提）有己方将领")
	if g == null:
		return
	var ai_side := "ai"
	g.faction = ai_side
	for m in w.retinue_of(String(g.id)):
		m.faction = ai_side
	w.units = [g]
	g.hold_position = true

	var spot := _free_tile(w, 2, w.map.rows - 3)
	g.stop()
	g.pos = GridRes.center_of(spot)
	g.sync_tile(w.map)

	var t := _free_tile(w, g.tx + 2, g.ty)
	var tower = w.add_building("tower", t.x, t.y, "p1")
	ok(tower != null, "在敌方 AI 单位警戒半径内放了一栋玩家箭塔")
	if tower == null:
		return
	var n := 0
	while n < 120:
		w.tick(DT)
		n += 1
	ok(g.target_building == tower,
		"★★ 敌方 AI 单位会**主动检测并锁定**附近的敌方建筑（本次按需求新增）")
	ok(g.target == null, "★ 附近没有敌方单位时，它的目标只有那栋建筑")

func _test_command_guards(cfg) -> void:
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

	ok(CommandRes.apply(w, cfg, {
		"kind": "attack", "ids": [g.id], "target_id": e.id, "faction": "p1"}),
		"自己阵营下达的攻击命令正常生效")

func _free_tile(w, x: int, y: int) -> Vector2i:
	for r in range(0, 8):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var t := Vector2i(x + dx, y + dy)
				if w.can_build_at(t.x, t.y):
					return t
	return Vector2i(x, y)

func _test_leash_no_jitter(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	var e = w.spawn_enemy(g.tx + 2, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true                 # 敌人站着不动：这一节量的是**我方**有没有抽
	g.stop()                               # 让它待命 → 靠**自动索敌**去追（玩家命令会绕开 leash）
	ok(g.pos.distance_to(e.pos) - cfg.unit_radius_of(e.unit_type) <= cfg.aggro_range,
		"（前提）敌人确实在警戒半径内（距离 %.2f ≤ %.2f）" % [
			g.pos.distance_to(e.pos), cfg.aggro_range])

	ok(CombatRes.acquire_target(w, cfg, g, 0), "★ 警戒半径内的敌人被锁上")
	ok(g.anchor != null, "★ 自动索敌会设「追击参照点」")
	v2_near(g.anchor, g.pos, 1e-6, "★ 参照点 = **锁定那一刻**它自己站的位置")

	var keep: Vector2 = g.anchor
	g.anchor = keep - Vector2(5.0, 0.0)
	CombatRes.acquire_target(w, cfg, g, 0)
	v2_near(g.anchor, keep - Vector2(5.0, 0.0), 1e-6,
		"★★ 重复索敌**不会**重置参照点（旧实现就是这里把它抹掉的）")

	ok(g.target == e, "（前提）它现在锁着那个敌人")
	g.anchor = g.pos - Vector2(100.0, 0.0)  # 参照点推远 ⇒ 一定超上限
	CombatRes.update_combat(w, cfg, g)
	ok(g.target == null, "★ 追出上限就放弃")
	ok(g.leash_cd > 0.0, "★★ 放弃之后进入冷却（leash_release_cd = %.2f）" % cfg.leash_release_cd)
	ok(not CombatRes.acquire_target(w, cfg, g, 0),
		"★★★ 冷却期内**不再**把还在警戒半径里的同一个敌人锁上（这就是「抽搐」的断点）")

	g.drop_engagement()
	ok(g.target == null, "（前提）现在没有目标")
	for _i in int(ceil(cfg.leash_release_cd / DT)) + 2:
		w.tick(DT)
	ok(g.leash_cd <= 0.0, "★ 冷却会自己走完")
	ok(g.target != null, "★ 冷却完了会**自己**重新接战（没有变成「永远不接战」）")
	ok(not CombatRes.acquire_target(w, cfg, g, 0),
		"★ 已经锁着目标时 `acquire_target` 直接返回（不重复锁、不会抹平参照点）")

	g.leash_cd = 10.0
	var far := GridRes.center_of(Vector2i(
		clampi(g.tx + 3, 0, w.map.cols - 1), clampi(g.ty + 3, 0, w.map.rows - 1)))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g.id],
		"x": far.x, "y": far.y, "faction": "p1"}), "★ 冷却期内玩家的移动命令照旧生效")
	eq(g.leash_cd, 0.0, "★ 而且新命令会把冷却清掉（它只是自动索敌的节流）")

func _test_leash_anchor_follows_target(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	var e = w.spawn_enemy(g.tx + 2, g.ty)
	if g == null or e == null:
		return
	w.units = [g, e]
	e.hold_position = true
	g.stop()
	ok(CombatRes.acquire_target(w, cfg, g, 0), "（前提）锁上敌人")
	var anchor0: Vector2 = g.anchor

	g.repath_timer = 0.0                    # 这一节的节流判据就是它，先清零
	var moved: Vector2 = e.pos + Vector2(cfg.repath_min_move * 2.0, 0.0)
	CombatRes._refresh_leash_anchor(g, cfg, moved)
	v2_near(g.anchor, moved, 1e-6, "★★ 目标挪过地方之后，参照点跟着它走")
	ok(g.anchor.distance_to(anchor0) > 0.01, "★ 确实动了（不是原地没变）")

	var anchor1: Vector2 = g.anchor
	g.repath_timer = 0.0
	CombatRes._refresh_leash_anchor(g, cfg, Vector2(anchor1.x + 0.01, anchor1.y))
	v2_near(g.anchor, anchor1, 1e-6, "★★ 目标几乎没动 ⇒ 参照点不更新（旧行为不变）")

	g.ordered_target = e
	g.anchor = null
	g.repath_timer = 0.0
	CombatRes._refresh_leash_anchor(g, cfg, moved + Vector2(5.0, 0.0))
	ok(g.anchor == null, "★ 点名目标（anchor 为空）不设参照点 ⇒ 不受追击上限约束")
