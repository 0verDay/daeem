## test_retinue.gd —— 队伍的**附属兵**与「整队」模型
##
## 需求（本轮改写后）：「将『亲兵』这个单位去除」+「将领也暂时用这三个单位类型做出区分」——
##   于是「将领带一批附属单位」这件事**原样保留**，只是附属兵从固定的亲兵
##   换成了**将领自己那一类的兵**（长枪兵将领带长枪兵、长弓兵将领带长弓兵…）。
##
## 这套断言盯四件事：
##   1. 出生：数量对、与队长同类型、挨着队长、有队长 id、没有快捷键
##   2. 队伍模型：group_of / expand_to_groups / retinue_of 的语义（含队长阵亡后的行为）
##   3. 选中同步：点队伍里**任何一个**都展开成整队
##   4. 下令同步：一条 move 命令带全队 id → 全队都进入移动
##
## ★ 第 3 条落地在 view/input_controller.select_units()，
##   第 4 条则是「选中集合的自然结果」（右键就是给选中集合下令）——
##   所以这两条要在测试里分开验：一个是逻辑层的 group_of，一个是选择层的展开。
##
## ★ 兵种标签（步兵 / 骑兵 / 远程）本身不在这个文件里 —— 见 tests/test_unit_types.gd。
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
	_test_stats_are_per_type(cfg)
	_test_recruit(cfg)


## 出生：数量、类型、id 规则、没有快捷键
func _test_spawn(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = cfg.general_escort_count()
	ok(per > 0, "配置里附属兵数量大于 0（不然整套测试没有意义）")
	var generals = _kind(w, UnitRes.KIND_GENERAL)
	eq(generals.size(), 3, "3 个将领")

	var subs: Array = []
	for u in w.units:
		if u.leader_id != "":
			subs.append(u)
	eq(subs.size(), 3 * per, "每个将领带 %d 个附属兵" % per)

	for g in generals:
		eq(w.retinue_of(g.id).size(), per, "%s 辖下有 %d 个附属兵" % [g.id, per])
		eq(g.leader_id, "", "将领自己没有队长")
		ok(w.is_team_leader(g), "将领是队长")

	for s in subs:
		ok(s.leader_id != "", "附属兵有队长 id")
		ok(s.id.begins_with(s.leader_id), "附属兵 id 以队长 id 开头（%s ← %s）" % [s.id, s.leader_id])
		eq(s.hotkey, "", "附属兵没有快捷键")
		eq(s.faction, FactionRes.DEFAULT_FACTION, "附属兵与队长同阵营")
		# ★★ 本轮的核心：附属兵是**将领自己那一类**的兵（不再是固定的亲兵）
		var leader = w.unit_by_id(s.leader_id)
		ok(leader != null, "附属兵的队长在场")
		if leader != null:
			eq(String(s.kind), String(leader.unit_type), "★ 附属兵的 kind = 队长的单位类型")
			eq(String(s.unit_type), String(leader.unit_type), "★ 附属兵与队长同类型")

	# 每个将领先全部入列，附属兵跟在后面（快捷键 1/2/3 与按序号取将领的代码都靠这个顺序）
	var first_three = []
	for i in 3:
		first_three.append(w.units[i].kind)
	eq(first_three, [UnitRes.KIND_GENERAL, UnitRes.KIND_GENERAL, UnitRes.KIND_GENERAL],
		"★ world.units 前三个永远是将领（顺序契约）")
	# 三个将领分别是三种类型（长枪兵 / 长弓兵 / 骑手）
	var got_types: Array = []
	for g2 in generals:
		got_types.append(String(g2.unit_type))
	eq(got_types, cfg.general_types(), "★ 三个将领分别被赋上配置里的三个类型")


## 出生位置：挨着队长（不能被挤到地图另一头）
func _test_spawn_near_leader(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g = w.unit_by_id("general-1")
	ok(g != null, "有 general-1")
	if g == null:
		return
	var ret = w.retinue_of(g.id)
	ok(ret.size() > 0, "general-1 有附属兵")
	var max_dist := 0
	for s in ret:
		max_dist = maxi(max_dist, maxi(absi(s.tx - g.tx), absi(s.ty - g.ty)))
	ok(max_dist <= 2, "★ 附属兵都出生在将领 2 格以内（实测最远 %d 格）" % max_dist)

	# 附属兵不能站在大本营那一格 / 山上
	for s in ret:
		ok(w.map.terrain_walkable(s.tx, s.ty), "附属兵站在可通行格上：%s" % s.id)
		var b = w.building_at(s.tx, s.ty)
		ok(b == null or b.blocks(s.faction) == false, "附属兵没卡在不能站的建筑里：%s" % s.id)


## 队伍模型的语义
func _test_group_model(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = cfg.general_escort_count()
	var g1 = w.unit_by_id("general-1")
	var sub0 = w.retinue_of(g1.id)[0]

	# 从队长出发
	var from_leader = w.group_of(g1)
	eq(from_leader.size(), 1 + per, "group_of(队长) = 队长 + %d 附属兵" % per)
	eq(from_leader[0].id, g1.id, "★ 队长排在队伍第一个（界面与下令都以它为首）")

	# 从附属兵出发：必须也得到整队（这是「点任何一个 = 选整队」的基础）
	var from_sub = w.group_of(sub0)
	eq(from_sub.size(), 1 + per, "★ group_of(附属兵) 也得到整队")
	eq(from_sub[0].id, g1.id, "★ 从附属兵出发时，队长仍在第一个")

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
	var e = w.spawn_enemy(10, 12)
	if e != null:
		eq(w.group_of(e).size(), 1, "测试敌人不属于任何队伍，只选中自己")
		eq(w.retinue_of(e.id).size(), 0, "测试敌人没有附属兵")


## ★ 队长阵亡后：附属兵不能被凭空造出一个队长，也不该互相牵连
func _test_leader_dead(cfg) -> void:
	var w = WorldRes.create(cfg)
	var per: int = cfg.general_escort_count()
	var g1 = w.unit_by_id("general-1")
	var ret = w.retinue_of(g1.id)
	eq(ret.size(), per, "先确认有附属兵")

	# 让队长阵亡（单机：死了就离场）
	g1.take_damage(cfg, w, 9999.0, null)
	ok(not g1.alive, "队长已阵亡")
	w.tick(DT)
	ok(w.unit_by_id(g1.id) == null, "队长已离场")

	# ★ 这两个语义很容易搞混，所以分开断言：
	#   retinue_of(默认) 非空 —— 队长死了，附属兵还活着；
	#   team_leader(附属兵) 为 null —— 队长查不到了。
	#   （第一版把这条写反了，断言写的是「retinue_of 返回空」，结果假失败 ——
	#     顺带发现原来的 retinue_of 只有「活着」一种口径，查不了「原来跟着谁」。）
	ok(w.retinue_of(g1.id).size() > 0, "队长阵亡但附属兵还活着 → retinue_of 仍非空")
	eq(w.retinue_of(g1.id, false).size(), per, "retinue_of(alive_only=false) 数得出原来有几个")

	# 剩下的附属兵：各自算各自（点它就只选它自己），不会凭空多出一个队长
	var orphan = null
	for u in w.units:
		if u.leader_id == g1.id:
			orphan = u
			break
	ok(orphan != null, "还有留下的附属兵")
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
##
## ★★ 必须先把「会打架的东西」清干净（关战斗 + 清掉地图预置的敌人）：
##    这一节验的是**移动命令的同步**，而战斗会合法地把单位从这条命令上拉走 ——
##    `combat.update_combat()` 在够不着敌人时会 `move_to(敌人的位置)` 去追。
##    当前地图上那两个巡逻兵会朝玩家据点推进，**正好穿过这队人要走的那条路**，
##    于是有一个附属兵在 n≈235 被拽去追击、追丢之后就地停住，
##    以「整队都到达了目标附近（3/4）」的形式报失败 —— 那看起来像移动坏了，
##    其实是战斗在正常工作（同一个坑 test_arrival 的拥挤用例里也踩过）。
func _test_group_move_actually_works(cfg) -> void:
	var was_combat: bool = cfg.combat_enabled
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	w.units = _keep_player_units(w)
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
	cfg.combat_enabled = was_combat


## 只留玩家这一方的单位（战斗用例之外的「纯移动」断言都要先过这一道）
func _keep_player_units(w) -> Array:
	var kept: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			kept.append(u)
	return kept


## ★ 需求明确要求「不自动跟随」：没下令时附属兵不该自己跑
##
## ★ 关掉战斗：地图上有两个**会自己推进的巡逻兵**，走完这段路要好几秒 ——
##   它们会进警戒半径、把「将领/附属兵自己动起来」和「跑位跟上去」混在一起。
##   这一条验的是「不自动跟随」这条契约，不是战斗。
func _test_does_not_follow_on_its_own(cfg) -> void:
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var ret = w.retinue_of(g1.id)
	ok(ret.size() > 0, "有附属兵")
	for s in ret:
		s.stop()
	g1.stop()

	# 只给队长下令，附属兵不动
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
	eq(moved, 0, "★ 只命令队长时，附属兵不会自己跟上去（「不自动跟随」是需求）")
	# 它们待在原地（允许被推挤挪一点，但不该跑到队长那边）
	var near_target = 0
	for s in ret:
		if s.pos.distance_to(target) < 2.0:
			near_target += 1
	eq(near_target, 0, "附属兵没有跑到队长的目标点去")


## 数值按**单位类型**分开：三种兵各自一套，而且都不会退化成测试敌人的数值
##
## ★★ 用户确认的口径是「将领数值 = 它所属类型的数值」——
##    所以这里不再断言「附属兵比将领弱」，而是断言
##    「将领与它的附属兵同类型 ⇒ 同数值」「不同类型 ⇒ 不同数值」「谁都不等于测试敌人」。
func _test_stats_are_per_type(cfg) -> void:
	var w = WorldRes.create(cfg)
	var g1 = w.unit_by_id("general-1")
	var s = w.retinue_of(g1.id)[0]
	var e = w.spawn_enemy(10, 12)
	ok(e != null, "有测试敌人可比")

	var t := String(s.unit_type)
	ok(cfg.has_unit_type(t), "附属兵的类型 %s 在 config.unit.types 里" % t)
	eq(s.hp_max, cfg.unit_hp_of(t), "附属兵血量走 config.unit.types.<类型>.hp_max")
	eq(s.combat_damage(cfg), float(cfg.unit_combat_of(t)["damage"]), "附属兵伤害走 config")
	eq(s.combat_range(cfg), float(cfg.unit_combat_of(t)["range"]), "附属兵射程走 config")
	eq(s.combat_cooldown(cfg), float(cfg.unit_combat_of(t)["cooldown_sec"]), "附属兵攻击间隔走 config")

	# ★ 将领 = 同一套数值（用户口径：完全按对应兵种数值）
	eq(String(s.unit_type), String(g1.unit_type), "（前提）附属兵与将领同类型")
	eq(g1.hp_max, s.hp_max, "★ 将领血量 = 同类型附属兵的血量")
	eq(g1.combat_damage(cfg), s.combat_damage(cfg), "★ 将领伤害 = 同类型附属兵的伤害")
	eq(g1.combat_range(cfg), s.combat_range(cfg), "★ 将领射程 = 同类型附属兵的射程")

	# 体积：每个类型都有自己的半径，而且都远小于一格
	ok(cfg.unit_radius_of(t) > 0.0, "附属兵体积是正数")
	ok(cfg.unit_radius_of(t) < 0.5, "附属兵体积仍远小于一格")

	# ★ 这一条是「加第三种兵种」最容易踩的坑：
	#   老代码写的是「是将领吗？不是就当敌人」，于是新兵种会静默拿到敌人的数值。
	ok(s.hp_max != e.hp_max, "★ 附属兵没有退化成测试敌人的数值")
	ok(s.combat_damage(cfg) != e.combat_damage(cfg), "★ 附属兵的伤害也没有退化成敌人的")

	# 三个类型之间也必须是**不同**的（否则「按类型区分」这件事没有意义）
	var types: Array = cfg.general_types()
	var seen_hp: Dictionary = {}
	for tt in types:
		seen_hp[cfg.unit_hp_of(String(tt))] = true
	eq(seen_hp.size(), types.size(), "★ 三个类型的血量互不相同（类型真的分开了）")


func _kind(world, kind: String) -> Array:
	var out: Array = []
	for u in world.units:
		if u.kind == kind:
			out.append(u)
	return out


# ------------------------------------------------------------------
# ★ 招募（单位页的命令卡 → recruit 命令 → world.start_recruit）
#
# 需求原话：「单位页显示可招募的单位，单位招募时在选择的对应将领处生成」。
# 本轮的三个可招募兵种 = 长枪兵 / 长弓兵 / 骑手（见 config.recruit.list）。
# 这一节只验**队伍模型那一半**：谁能当招募对象（队长 / 附属兵 / 阵亡），
# 以及新兵最终挂在**正确那个将领**名下、类型是**招的那个兵种**。
# ★ 招募本身（50 粮 / 50 金 / 1 人口、10 秒读条、队列 5 格、格心生成、
#   区划限制、阵亡退款）在 tests/test_recruit_queue.gd —— 别在这里重复。
# ------------------------------------------------------------------
func _test_recruit(cfg) -> void:
	# 这一节要 tick 满 10 秒（读条），所以关掉战斗与场上的敌人：
	# 地图预置的巡逻兵会推进过来、把附属兵打死，人数断言就不可靠了（见 pitfalls 5.34）
	cfg.combat_enabled = false
	var w = WorldRes.create(cfg)
	w.units = _keep_player_units(w)
	var per: int = cfg.general_escort_count()
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	ok(g1 != null and g2 != null, "有两个将领可用")

	# 三个兵种都可招；表里没有的不能招
	for tt in cfg.general_types():
		ok(w.is_recruitable(String(tt)), "config.recruit.list 里 %s 可招募" % tt)
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")

	var kind := String(cfg.general_types()[0])          # 长枪兵

	# 钱 / 人口给足：这一节验的不是钱（那是 test_recruit_queue 的事）
	w.resources["food"] = 1000.0
	w.resources["gold"] = 1000.0
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	w.zones.zone_at(g2.tx, g2.ty)["population"] = 10.0

	# ---- 被拒的命令不能生成单位 ----
	var before: int = _kind(w, kind).size()
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": kind, "leader_id": "", "faction": "p1"}),
		"★ 没有 leader_id 的招募命令被拒（命令里必须有队长 id）")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": "nope", "leader_id": g1.id, "faction": "p1"}),
		"不在可招募表里的兵种被拒")
	ok(not CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": kind, "leader_id": "general-99", "faction": "p1"}),
		"队长不存在时被拒")
	eq(_kind(w, kind).size(), before, "★ 被拒的命令一个单位都没生成")

	# ---- 谁不能当招募对象 ----
	var sub = w.retinue_of(g1.id)[0]
	ok(not w.can_recruit(kind, sub.id, "p1").is_empty(),
		"★ 附属兵不是队长，不能往它名下招兵")
	var e2 = w.spawn_enemy(10, 12)
	if e2 != null:
		ok(not w.can_recruit(kind, e2.id, "p1").is_empty(),
			"不能把兵招到敌方单位名下")
		# 敌方阵营也不能借招募命令去使唤我方的将领
		ok(not w.can_recruit(kind, g1.id, FactionRes.NPC_FACTION).is_empty(),
			"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")
		w.units.erase(e2)          # 读条期间别让它来搅局

	# ---- 正常招募：排到将领 2 名下（不是将领 1）----
	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": kind, "leader_id": g2.id, "faction": "p1"}),
		"选中将领 2 之后，招募命令被接受（入队）")
	eq(g2.train_kind, kind, "★ 队列排在将领 2 名下")
	ok(not g1.is_training(), "★ 将领 1 名下没有队列（没招错人）")
	eq(w.retinue_of(g2.id).size(), per, "★ 入队不会立刻生成单位（要读条 10 秒）")

	# ---- 读条走完才生成，且生成在**同一个将领**名下 ----
	for _i in 601:
		w.tick(DT)
	eq(w.retinue_of(g2.id).size(), per + 1, "★ 10 秒后将领 2 名下多了一个兵")
	eq(w.retinue_of(g1.id).size(), per, "★ 将领 1 名下一个不多")

	var fresh = w.retinue_of(g2.id)[per]        # 新兵排在最后
	eq(fresh.kind, kind, "招出来的就是招的那个兵种")
	eq(String(fresh.unit_type), kind, "★ 新兵的类型 = 招的兵种（不是队长那一类）")
	eq(fresh.hp_max, cfg.unit_hp_of(kind), "新兵数值走这个兵种那一档")
	eq(fresh.leader_id, g2.id, "新兵挂在将领 2 名下")
	ok(w.unit_by_id(fresh.id) == fresh, "新兵 id 唯一、能按 id 查回来（%s）" % fresh.id)
	ok(fresh.id.begins_with(g2.id), "新兵 id 以队长 id 开头（%s）" % fresh.id)
	eq(fresh.faction, FactionRes.DEFAULT_FACTION, "新兵与队长同阵营")
	ok(w.map.terrain_walkable(fresh.tx, fresh.ty), "新兵站在可通行格上")
	var b0 = w.building_at(fresh.tx, fresh.ty)
	ok(b0 == null or not b0.blocks(fresh.faction), "新兵没卡在不能站的建筑里")

	# ---- 另外两个兵种也能招（三个都能排进同一个将领的队列）----
	for i in range(1, cfg.general_types().size()):
		var other := String(cfg.general_types()[i])
		ok(CommandRes.apply(w, cfg, {
			"kind": "recruit", "unit_kind": other, "leader_id": g2.id, "faction": "p1"}),
			"将领 2 名下也能排 %s" % other)
	for _i in 1210:
		w.tick(DT)
	eq(w.retinue_of(g2.id).size(), per + cfg.general_types().size(),
		"★ 三个兵种各招一个之后，名下多了 %d 个" % cfg.general_types().size())

	# ---- 连续招募：id 不重复、人数线性增长 ----
	var now_n: int = w.retinue_of(g2.id).size()
	for i in 2:
		CommandRes.apply(w, cfg, {
			"kind": "recruit", "unit_kind": kind, "leader_id": g2.id, "faction": "p1"})
	for _i in 1201:
		w.tick(DT)
	eq(w.retinue_of(g2.id).size(), now_n + 2, "连招 2 次 → 名下多了 2 个")
	var ids := {}
	for s in w.retinue_of(g2.id):
		ids[s.id] = true
	eq(ids.size(), w.retinue_of(g2.id).size(), "★ 连续招募的 id 不重复（序号不回退）")

	# ---- 队长阵亡后不能再招 ----
	g2.take_damage(cfg, w, 99999.0, null)
	ok(not g2.alive, "将领 2 已阵亡")
	ok(not w.can_recruit(kind, g2.id, "p1").is_empty(),
		"★ 队长阵亡后不能再往它名下招兵")
	cfg.combat_enabled = true
