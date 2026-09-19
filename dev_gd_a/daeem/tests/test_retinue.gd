## test_retinue.gd —— 亲兵（附属单位）与「队伍」
##
## 需求：将领 1 带一批附属单位，出生在它旁边；
##       选中将领时同步选中这些单位；右键移动会同步给它们下达指令。
##
## 这套断言盯四件事：
##   1. 出生：数量对、挨着队长、有队长 id、没有快捷键
##   2. 队伍模型：group_of / expand_to_groups / retinue_of 的语义（含队长阵亡后的行为）
##   3. 选中同步：点队伍里**任何一个**都展开成整队
##   4. 下令同步：一条 move 命令带全队 id → 全队都进入移动
##
## ★ 第 3 条落地在 view/input_controller.select_units()，
##   第 4 条则是「选中集合的自然结果」（右键就是给选中集合下令）——
##   所以这两条要在测试里分开验：一个是逻辑层的 group_of，一个是选择层的展开。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_retinue"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_spawn(cfg)
	_test_spawn_near_leader(cfg)
	_test_group_model(cfg)
	_test_leader_dead(cfg)
	_test_move_command_hits_whole_group(cfg)
	_test_group_move_actually_works(cfg)
	_test_does_not_follow_on_its_own(cfg)
	_test_stats_are_per_kind(cfg)
	_test_recruit(cfg)


## 出生：数量、id 规则、没有快捷键
func _test_spawn(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = int(cfg.num("unit.subordinate.count", 0.0))
	ok(per > 0, "配置里亲兵数量大于 0（不然整套测试没有意义）")
	var generals = _kind(w, UnitRes.KIND_GENERAL)
	var subs = _kind(w, UnitRes.KIND_SUBORDINATE)
	eq(generals.size(), 3, "3 个将领")
	eq(subs.size(), 3 * per, "每个将领带 %d 个亲兵" % per)

	for g in generals:
		eq(w.retinue_of(g.id).size(), per, "%s 辖下有 %d 个亲兵" % [g.id, per])
		eq(g.leader_id, "", "将领自己没有队长")
		ok(w.is_team_leader(g), "将领是队长")

	for s in subs:
		eq(s.kind, UnitRes.KIND_SUBORDINATE, "亲兵 kind")
		ok(s.leader_id != "", "亲兵有队长 id")
		ok(s.id.begins_with(s.leader_id), "亲兵 id 以队长 id 开头（%s ← %s）" % [s.id, s.leader_id])
		eq(s.hotkey, "", "亲兵没有快捷键")
		eq(s.faction, FactionRes.DEFAULT_FACTION, "亲兵与队长同阵营")

	# 每个将领先全部入列，亲兵跟在后面（快捷键 1/2/3 与按序号取将领的代码都靠这个顺序）
	var first_three = []
	for i in 3:
		first_three.append(w.units[i].kind)
	eq(first_three, [UnitRes.KIND_GENERAL, UnitRes.KIND_GENERAL, UnitRes.KIND_GENERAL],
		"★ world.units 前三个永远是将领（顺序契约）")


## 出生位置：挨着队长（不能被挤到地图另一头）
func _test_spawn_near_leader(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g = w.unit_by_id("general-1")
	ok(g != null, "有 general-1")
	if g == null:
		return
	var ret = w.retinue_of(g.id)
	ok(ret.size() > 0, "general-1 有亲兵")
	var max_dist := 0
	for s in ret:
		max_dist = maxi(max_dist, maxi(absi(s.tx - g.tx), absi(s.ty - g.ty)))
	ok(max_dist <= 2, "★ 亲兵都出生在将领 2 格以内（实测最远 %d 格）" % max_dist)

	# 亲兵不能站在大本营那一格 / 山上
	for s in ret:
		ok(w.map.terrain_walkable(s.tx, s.ty), "亲兵站在可通行格上：%s" % s.id)
		var b = w.building_at(s.tx, s.ty)
		ok(b == null or b.blocks(s.faction) == false, "亲兵没卡在不能站的建筑里：%s" % s.id)


## 队伍模型的语义
func _test_group_model(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = int(cfg.num("unit.subordinate.count", 0.0))
	var g1 = w.unit_by_id("general-1")
	var sub0 = w.retinue_of(g1.id)[0]

	# 从队长出发
	var from_leader = w.group_of(g1)
	eq(from_leader.size(), 1 + per, "group_of(队长) = 队长 + %d 亲兵" % per)
	eq(from_leader[0].id, g1.id, "★ 队长排在队伍第一个（界面与下令都以它为首）")

	# 从亲兵出发：必须也得到整队（这是「点任何一个 = 选整队」的基础）
	var from_sub = w.group_of(sub0)
	eq(from_sub.size(), 1 + per, "★ group_of(亲兵) 也得到整队")
	eq(from_sub[0].id, g1.id, "★ 从亲兵出发时，队长仍在第一个")

	# expand_to_groups：去重、顺序稳定
	var mixed = [g1, sub0, g1]
	var expanded = w.expand_to_groups(mixed)
	eq(expanded.size(), 1 + per, "★ expand_to_groups 会去重并展开成整队")

	# 两个不同队伍混在一起 → 两支队伍都展开
	var g2 = w.unit_by_id("general-2")
	var two = w.expand_to_groups([g1, g2])
	eq(two.size(), 2 * (1 + per), "两支队伍的队长一起选中 → 展开出两队所有人")
	eq(two[0].id, g1.id, "第一队的队长在最前（顺序稳定）")
	eq(two[1 + per].id, g2.id, "第二队的队长紧随其后")

	# 不属于任何队伍的单位（测试敌人）→ 只选中自己
	var e = w.spawn_enemy(20, 12)
	if e != null:
		eq(w.group_of(e).size(), 1, "测试敌人不属于任何队伍，只选中自己")
		eq(w.retinue_of(e.id).size(), 0, "测试敌人没有亲兵")


## ★ 队长阵亡后：亲兵不能被凭空造出一个队长，也不该互相牵连
func _test_leader_dead(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = int(cfg.num("unit.subordinate.count", 0.0))
	var g1 = w.unit_by_id("general-1")
	var ret = w.retinue_of(g1.id)
	eq(ret.size(), per, "先确认有亲兵")

	# 让队长阵亡（单机：死了就离场）
	g1.take_damage(cfg, w, 9999.0, null)
	ok(not g1.alive, "队长已阵亡")
	w.tick(DT)
	ok(w.unit_by_id(g1.id) == null, "队长已离场")

	# ★ 这两个语义很容易搞混，所以分开断言：
	#   retinue_of(默认) 非空 —— 队长死了，亲兵还活着；
	#   team_leader(亲兵) 为 null —— 队长查不到了。
	#   （第一版把这条写反了，断言写的是「retinue_of 返回空」，结果假失败 ——
	#     顺带发现原来的 retinue_of 只有「活着」一种口径，查不了「原来跟着谁」。）
	ok(w.retinue_of(g1.id).size() > 0, "队长阵亡但亲兵还活着 → retinue_of 仍非空")
	eq(w.retinue_of(g1.id, false).size(), per, "retinue_of(alive_only=false) 数得出原来有几个亲兵")

	# 剩下的亲兵：各自算各自（点它就只选它自己），不会凭空多出一个队长
	var orphan = null
	for u in w.units:
		if u.leader_id == g1.id:
			orphan = u
			break
	ok(orphan != null, "还有留下的亲兵")
	if orphan != null:
		eq(w.team_leader(orphan), null, "队长不在场 → team_leader 返回 null")
		eq(w.group_of(orphan).size(), 1, "★ 队长没了就只选中自己（不会凭空造队长）")


## ★ 一条 move 命令覆盖整队（「右键移动同步下达指令」的逻辑层那一半）
func _test_move_command_hits_whole_group(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var group = w.group_of(g1)
	var ids: Array = []
	for u in group:
		ids.append(u.id)

	var target := GridRes.center_of(Vector2i(4, 13))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": ids, "x": target.x, "y": target.y, "faction": "p1"}),
		"整队的 move 命令被接受")

	var moving := 0
	for u in group:
		if u.moving:
			moving += 1
	eq(moving, group.size(), "★ 整队 %d 个单位都进入了移动状态" % group.size())

	# 目标点应当基本一致（每个单位都朝同一个位置走）
	var toward = 0
	for u in group:
		# 允许被推挤/拉直后的细微差别，只验「朝那个方向」
		if u.has_goal:
			toward += 1
	eq(toward, group.size(), "整队都记住了目标点")

	# 队伍之外的单位不该被顺带命令
	var g2 = w.unit_by_id("general-2")
	ok(not g2.moving, "★ 同阵营的另一支队伍没有被顺带下令")


## 端到端：整队真的都走过去（不是「下了令但原地不动」）
func _test_group_move_actually_works(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var group = w.group_of(g1)
	var start_tiles: Array = []
	for u in group:
		start_tiles.append(Vector2i(u.tx, u.ty))

	var target := GridRes.center_of(Vector2i(6, 13))
	var ids: Array = []
	for u in group:
		ids.append(u.id)
	CommandRes.apply(w, cfg, {"kind": "move", "ids": ids, "x": target.x, "y": target.y, "faction": "p1"})

	var n := 0
	while n < 3000:
		w.tick(DT)
		n += 1
		var all_done := true
		for u in group:
			if u.moving:
				all_done = false
		if all_done:
			break

	# 每个单位都要离目标够近（允许被队友挤开半格）
	var arrived = 0
	var moved = 0
	for i in group.size():
		var u = group[i]
		var before_tile: Vector2i = start_tiles[i]
		if u.tx != before_tile.x or u.ty != before_tile.y:
			moved += 1
		var d: float = u.pos.distance_to(target)
		if d <= 1.6:
			arrived += 1
	eq(moved, group.size(), "★ 整队都离开出发点了（没有谁原地不动）")
	eq(arrived, group.size(), "★ 整队都到达了目标附近（%d/%d）" % [arrived, group.size()])


## ★ 需求明确要求「不自动跟随」：没下令时亲兵不该自己跑
func _test_does_not_follow_on_its_own(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var ret = w.retinue_of(g1.id)
	ok(ret.size() > 0, "有亲兵")
	for s in ret:
		s.stop()
	g1.stop()

	# 只给队长下令，亲兵不动
	var target := GridRes.center_of(Vector2i(4, 13))
	CommandRes.apply(w, cfg, {"kind": "move", "ids": [g1.id], "x": target.x, "y": target.y, "faction": "p1"})
	var n := 0
	while g1.moving and n < 3000:
		w.tick(DT)
		n += 1

	var moved = 0
	for s in ret:
		if s.moving:
			moved += 1
	eq(moved, 0, "★ 只命令队长时，亲兵不会自己跟上去（「不自动跟随」是需求）")
	# 它们待在原地（允许被推挤挪一点，但不该跑到队长那边）
	var near_target = 0
	for s in ret:
		if s.pos.distance_to(target) < 2.0:
			near_target += 1
	eq(near_target, 0, "亲兵没有跑到队长的目标点去")


## 数值按 kind 分开：亲兵既不是将领也不是测试敌人
func _test_stats_are_per_kind(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g = w.unit_by_id("general-1")
	var s = w.retinue_of(g.id)[0]
	var e = w.spawn_enemy(20, 12)
	ok(e != null, "有测试敌人可比")

	eq(s.hp_max, cfg.num("unit.subordinate.hp_max", 0.0), "亲兵血量走 config.unit.subordinate.hp_max")
	ok(s.hp_max < g.hp_max, "★ 亲兵比将领弱（%.0f < %.0f）" % [s.hp_max, g.hp_max])
	ok(s.hp_max > e.hp_max, "★ 亲兵比测试敌人强（%.0f > %.0f）" % [s.hp_max, e.hp_max])

	eq(s.combat_damage(cfg), cfg.num("unit.subordinate.damage", 0.0), "亲兵伤害走 config")
	ok(s.combat_damage(cfg) < g.combat_damage(cfg), "亲兵伤害低于将领")
	eq(s.combat_range(cfg), cfg.num("unit.subordinate.range", 0.0), "亲兵射程走 config")
	eq(s.combat_cooldown(cfg), cfg.num("unit.subordinate.cooldown_sec", 0.0), "亲兵攻击间隔走 config")

	# 体积：亲兵比将领小（一眼能看出主次），但仍然远小于一格
	ok(cfg.unit_radius_of(UnitRes.KIND_SUBORDINATE) < cfg.unit_radius_of(UnitRes.KIND_GENERAL),
		"亲兵体积小于将领")
	ok(cfg.unit_radius_of(UnitRes.KIND_SUBORDINATE) > 0.0, "亲兵体积是正数")
	ok(cfg.unit_radius_of(UnitRes.KIND_SUBORDINATE) < 0.5, "亲兵体积仍远小于一格")

	# ★ 这一条是「加第三种兵种」最容易踩的坑：
	#   老代码写的是「是将领吗？不是就当敌人」，于是亲兵会静默拿到敌人的数值。
	ok(s.hp_max != e.hp_max, "★ 亲兵没有退化成测试敌人的数值")
	ok(s.combat_damage(cfg) != e.combat_damage(cfg), "★ 亲兵的伤害也没有退化成敌人的")


func _kind(world, kind: String) -> Array:
	var out: Array = []
	for u in world.units:
		if u.kind == kind:
			out.append(u)
	return out


# ------------------------------------------------------------------
# ★ 招募（UI 改版新增：单位页的命令卡 → recruit 命令 → world.recruit_unit）
#
# 需求原话：「单位页显示可招募的单位，单位招募时在选择的对应将领处生成，
#            暂时用占位单位代替（即单位页目前只有一个单位）」
# 所以这套断言盯四件事：
#   1. 谁能招：只有**在场上、自己这一方、且是队长**的单位名下能招
#   2. 招在哪：挨着队长（复用出生时那套站位），且不能卡进墙 / 山里
#   3. 招出来是什么：config.recruit.list 里的兵种（数值仍走 unit.<kind>）
#   4. 命令这条路：被拒的命令**不能偷偷生成单位**，成功的一定有事件（UI 日志靠它）
# ------------------------------------------------------------------
func _test_recruit(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = int(cfg.num("unit.subordinate.count", 0.0))
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	ok(g1 != null and g2 != null, "有两个将领可用")

	ok(w.is_recruitable(UnitRes.KIND_SUBORDINATE), "config.recruit.list 里亲兵可招募")
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")

	# ---- 被拒的命令不能生成单位 ----
	var before: int = _kind(w, UnitRes.KIND_SUBORDINATE).size()
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.KIND_SUBORDINATE, "leader_id": "", "faction": "p1"}),
		"★ 没有 leader_id 的招募命令被拒（命令里必须有队长 id）")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": "nope", "leader_id": g1.id, "faction": "p1"}),
		"不在可招募表里的兵种被拒")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.KIND_SUBORDINATE, "leader_id": "general-99", "faction": "p1"}),
		"队长不存在时被拒")
	eq(_kind(w, UnitRes.KIND_SUBORDINATE).size(), before, "★ 被拒的命令一个单位都没生成")

	# ---- 正常招募：招到将领 2 名下 ----
	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": UnitRes.KIND_SUBORDINATE, "leader_id": g2.id, "faction": "p1"}),
		"选中将领 2 之后，招募命令被接受")
	eq(w.retinue_of(g2.id).size(), per + 1, "★ 将领 2 名下多了一个兵")
	eq(w.retinue_of(g1.id).size(), per, "★ 将领 1 名下一个不多（没招错人）")

	var fresh = w.retinue_of(g2.id)[per]        # 新兵排在最后
	eq(fresh.kind, UnitRes.KIND_SUBORDINATE, "招出来的就是「占位单位」（亲兵那一套数值）")
	eq(fresh.leader_id, g2.id, "新兵挂在将领 2 名下")
	ok(w.unit_by_id(fresh.id) == fresh, "新兵 id 唯一、能按 id 查回来（%s）" % fresh.id)
	ok(fresh.id.begins_with(g2.id), "新兵 id 以队长 id 开头（%s）" % fresh.id)
	eq(fresh.faction, FactionRes.DEFAULT_FACTION, "新兵与队长同阵营")
	ok(maxi(absi(fresh.tx - g2.tx), absi(fresh.ty - g2.ty)) <= 2, "★ 新兵挨着队长生成（2 格以内）")
	ok(w.map.terrain_walkable(fresh.tx, fresh.ty), "新兵站在可通行格上")
	var b0 = w.building_at(fresh.tx, fresh.ty)
	ok(b0 == null or not b0.blocks(fresh.faction), "新兵没卡在不能站的建筑里")

	# ---- 事件：UI 的日志靠它 ----
	var evts: Array = w.tick(DT)
	var recruited := 0
	for e in evts:
		if String(e.get("type", "")) == "unit_recruited":
			recruited += 1
	eq(recruited, 1, "★ 招募会发一条 unit_recruited 事件")

	# ---- 谁不能当招募对象 ----
	var sub = w.retinue_of(g1.id)[0]
	ok(not w.can_recruit(UnitRes.KIND_SUBORDINATE, sub.id, "p1").is_empty(),
		"★ 亲兵不是队长，不能往它名下招兵")
	var e2 = w.spawn_enemy(20, 12)
	if e2 != null:
		ok(not w.can_recruit(UnitRes.KIND_SUBORDINATE, e2.id, "p1").is_empty(),
			"不能把兵招到敌方单位名下")
		# 敌方阵营也不能借招募命令去使唤我方的将领
		ok(not w.can_recruit(UnitRes.KIND_SUBORDINATE, g1.id, FactionRes.NPC_FACTION).is_empty(),
			"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")

	# ---- 连招：id 不重复、人数线性增长 ----
	for i in 2:
		CommandRes.apply(w, cfg, {
			"kind": "recruit", "unit_kind": UnitRes.KIND_SUBORDINATE, "leader_id": g2.id, "faction": "p1"})
	eq(w.retinue_of(g2.id).size(), per + 3, "连招 3 次 → 名下多了 3 个")
	var ids := {}
	for s in w.retinue_of(g2.id):
		ids[s.id] = true
	eq(ids.size(), w.retinue_of(g2.id).size(), "★ 连续招募的 id 不重复（序号不回退）")

	# ---- 队长阵亡后不能再招 ----
	g2.take_damage(cfg, w, 99999.0, null)
	ok(not g2.alive, "将领 2 已阵亡")
	ok(not w.can_recruit(UnitRes.KIND_SUBORDINATE, g2.id, "p1").is_empty(),
		"★ 队长阵亡后不能再往它名下招兵")
