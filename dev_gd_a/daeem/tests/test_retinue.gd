## test_retinue.gd —— 队伍的**附属兵**与「整队」模型
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
	cleanup_escort_scaffold()

const PER := 3

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

func _test_spawn(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var per: int = PER
	var generals = _kind(w, UnitRes.KIND_GENERAL)
	eq(generals.size(), 3, "3 个将领（escort_of 点名了 1/2/3 位，于是三位都被补出来）")

	var subs: Array = []
	for u in w.units:
		if u.leader_id != "":
			subs.append(u)
	eq(subs.size(), per * 3, "三位将领一共带 %d 个附属兵（= 关卡摆了几个就是几个）" % (per * 3))

	for g in generals:
		eq(w.retinue_of(g.id).size(), per, "%s 辖下有 %d 个附属兵" % [g.id, per])
		eq(g.leader_id, "", "将领自己没有队长")
		ok(w.is_team_leader(g), "将领是队长")

	for s in subs:
		ok(s.leader_id != "", "附属兵有队长 id")
		eq(s.hotkey, "", "附属兵没有快捷键")
		eq(s.faction, FactionRes.DEFAULT_FACTION, "附属兵与队长同阵营")
		var leader = w.unit_by_id(s.leader_id)
		ok(leader != null, "附属兵的队长在场")
		if leader != null:
			eq(String(s.kind), String(leader.unit_type), "★ 附属兵的 kind = 队长的单位类型")
			eq(String(s.unit_type), String(leader.unit_type), "★ 附属兵与队长同类型")

	var pos: Dictionary = {}
	for i in w.units.size():
		pos[String(w.units[i].id)] = i
	for s in subs:
		var lp: Variant = pos.get(String(s.leader_id), -1)
		ok(int(lp) >= 0 and int(lp) < int(pos[String(s.id)]),
			"★★ 将领排在它自己的兵前面（%s @%d < %s @%d）"
				% [String(s.leader_id), int(lp), String(s.id), int(pos[String(s.id)])])
	var got_types: Array = []
	for g2 in generals:
		got_types.append(String(g2.unit_type))
	# ★ 名册本轮扩到 9 位（后 6 位只在招募池里）；开局只造前 3 位。
	eq(got_types, cfg.general_types().slice(0, generals.size()),
		"★ 三个开局将领分别被赋上名册里的前三个类型")

func _test_spawn_near_leader(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g = w.unit_by_id("general-1")
	ok(g != null, "有 general-1")
	if g == null:
		return
	var ret = w.retinue_of(g.id)
	eq(ret.size(), PER, "general-1 名下有 %d 个附属兵（按规格生成的）" % PER)
	var seen_tiles := {}
	for i in ret.size():
		var s = ret[i]
		eq(String(s.leader_id), "general-1", "★ 每个兵都挂在 general-1 名下（%s）" % s.id)
		var d: int = maxi(absi(s.tx - g.tx), absi(s.ty - g.ty))
		ok(d >= 1 and d <= 2, "★ 附属兵生成在队长附近（%s 距队长 %d 格）" % [s.id, d])
		ok(not seen_tiles.has(Vector2i(s.tx, s.ty)), "附属兵各占一格（%s）" % s.id)
		seen_tiles[Vector2i(s.tx, s.ty)] = true

	for s in ret:
		ok(w.map.terrain_walkable(s.tx, s.ty), "附属兵站在可通行格上：%s" % s.id)
		var b = w.building_at(s.tx, s.ty)
		ok(b == null or b.blocks(s.faction) == false, "附属兵没卡在不能站的建筑里：%s" % s.id)

func _test_group_model(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var per: int = PER
	var sub0 = w.retinue_of(g1.id)[0]

	var from_leader = w.group_of(g1)
	eq(from_leader.size(), 1 + per, "group_of(队长) = 队长 + %d 附属兵" % per)
	eq(from_leader[0].id, g1.id, "★ 队长排在队伍第一个（界面与下令都以它为首）")

	var from_sub = w.group_of(sub0)
	eq(from_sub.size(), 1 + per, "★ group_of(附属兵) 也得到整队")
	eq(from_sub[0].id, g1.id, "★ 从附属兵出发时，队长仍在第一个")

	var mixed = [g1, sub0, g1]
	var expanded = w.expand_to_groups(mixed)
	eq(expanded.size(), 1 + per, "★ expand_to_groups 会去重并展开成整队")

	var g2 = w.unit_by_id("general-2")
	var per2: int = w.retinue_of(g2.id).size()
	var two = w.expand_to_groups([g1, g2])
	eq(two.size(), (1 + per) + (1 + per2), "两支队伍的队长一起选中 → 展开出两队所有人")
	eq(two[0].id, g1.id, "第一队的队长在最前（顺序稳定）")
	eq(two[1 + per].id, g2.id, "第二队的队长紧随其后")

	var e = w.spawn_enemy(10, 12)
	if e != null:
		eq(w.group_of(e).size(), 1, "测试敌人不属于任何队伍，只选中自己")
		eq(w.retinue_of(e.id).size(), 0, "测试敌人没有附属兵")

func _test_leader_dead(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var per: int = PER
	var ret = w.retinue_of(g1.id)
	eq(ret.size(), per, "先确认有附属兵")

	for m in ret:
		m.alive = false
	w.units = w.units.filter(func(u): return u.alive)
	_attach_mates(cfg, w, g1, per)
	for _m in w.retinue_of(g1.id, true):
		_m.take_damage(cfg, w, _m.hp + 999999.0, null)
	w.tick(DT)
	g1.take_damage(cfg, w, 999999.0, null)
	ok(not g1.alive, "队长已阵亡")
	_attach_mates(cfg, w, g1, per)
	w.tick(DT)
	ok(w.unit_by_id(g1.id) == null, "队长已离场")

	ok(w.retinue_of(g1.id).size() > 0, "队长阵亡但附属兵还活着 → retinue_of 仍非空")
	eq(w.retinue_of(g1.id, false).size(), per, "retinue_of(alive_only=false) 数得出原来有几个")

	var orphan = null
	for u in w.units:
		if u.leader_id == g1.id:
			orphan = u
			break
	ok(orphan != null, "还有留下的附属兵")
	if orphan != null:
		eq(w.team_leader(orphan), null, "队长不在场 → team_leader 返回 null")
		eq(w.group_of(orphan).size(), 1, "★ 队长没了就只选中自己（不会凭空造队长）")

func _test_move_command_hits_whole_group(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
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

	var toward = 0
	for u in group:
		if u.has_goal:
			toward += 1
	eq(toward, group.size(), "整队都记住了目标点")

	var g2 = w.unit_by_id("general-2")
	ok(not g2.moving, "★ 同阵营的另一支队伍没有被顺带下令")

func _test_group_move_actually_works(cfg) -> void:
	var was_combat: bool = cfg.combat_enabled
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		cfg.combat_enabled = was_combat
		return
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

func _keep_player_units(w) -> Array:
	var kept: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			kept.append(u)
	return kept

func _attach_mates(cfg, w, leader, n: int) -> Array:
	var out: Array = []
	var utype: String = cfg.general_type_at(int(leader.general_index))
	for i in n:
		var m = UnitRes.create(cfg, "%s-t%d" % [leader.id, i + 1], "补兵%d" % (i + 1),
			Vector2i(leader.tx, leader.ty), leader.faction, utype, "", String(leader.id),
			utype, int(leader.general_index))
		w.units.append(m)
		out.append(m)
	return out

func _test_does_not_follow_on_its_own(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var ret = w.retinue_of(g1.id)
	ok(ret.size() > 0, "有附属兵")
	for s in ret:
		s.stop()
	g1.stop()

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
	var near_target = 0
	for s in ret:
		if s.pos.distance_to(target) < 2.0:
			near_target += 1
	eq(near_target, 0, "附属兵没有跑到队长的目标点去")

func _test_stats_are_per_type(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var s = w.retinue_of(g1.id)[0]
	var e = w.spawn_enemy(10, 12)
	ok(e != null, "（本次口径）调试刷兵现在刷的是长枪兵")

	var t := String(s.unit_type)
	ok(cfg.has_unit_type(t), "附属兵的类型 %s 在 config.unit.types 里" % t)
	eq(s.hp_max, cfg.unit_hp_of(t), "附属兵血量走 config.unit.types.<类型>.hp_max")
	eq(s.combat_damage(cfg), float(cfg.unit_combat_of(t)["damage"]), "附属兵伤害走 config")
	eq(s.combat_range(cfg), float(cfg.unit_combat_of(t)["range"]), "附属兵射程走 config")
	# ★ 词条已停用：不再继承光环，攻击间隔就是兵种基础值。
	eq(s.combat_cooldown(cfg), float(cfg.unit_combat_of(t)["cooldown_sec"]),
		"附属兵攻击间隔走 config")

	eq(String(s.unit_type), String(g1.unit_type), "（前提）附属兵与将领同类型")
	# ★★ 2026.10.29：将领比同类型附属兵**更抗打**（血量 × 倍率、护甲 + 加成），
	#    攻击按 `general_damage_mult`（默认 1.0 ⇒ 与附属兵相同）。
	near(g1.hp_max, s.hp_max * cfg.general_hp_mult, 1e-6,
		"★ 将领血量 = 同类型附属兵 × 将领倍率")
	near(g1.combat_damage(cfg), s.combat_damage(cfg) * cfg.general_damage_mult, 1e-6,
		"★ 将领伤害 = 同类型附属兵 × 将领攻击倍率")
	ok(g1.armor > s.armor, "★ 将领护甲比附属兵高（+%s）" % cfg.general_armor_bonus)
	eq(g1.combat_range(cfg), s.combat_range(cfg), "★ 将领射程 = 同类型附属兵的射程")

	ok(cfg.unit_radius_of(t) > 0.0, "附属兵体积是正数")
	ok(cfg.unit_radius_of(t) < 0.5, "附属兵体积仍远小于一格")

	var other := "rider" if t != "rider" else "spearman"
	ok(s.hp_max != cfg.unit_hp_of(other),
		"★ 附属兵的数值没有退化成**另一种兵**（%s vs %s）" % [t, other])
	ok(s.combat_damage(cfg) != float(cfg.unit_combat_of(other)["damage"]),
		"★ 附属兵的伤害也没有退化成另一种兵的")
	eq(e.hp_max, cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 调试刷出来的单位按**长枪兵**查表（不再有自己的那一档）")

	# ★ 这里要的是「兵种表里的三种」，不是将领名册（名册本轮扩到了 9 位）。
	var types: Array = cfg.general_types().slice(0, 3)
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


## 单位页那张表（recruit.list）里的兵种 kind —— 与将领名册是两张表，别混用。
func _unit_kinds(world) -> Array:
	var out: Array = []
	for item in world.recruit_list():
		out.append(String((item as Dictionary).get("kind", "")))
	return out

func _test_recruit(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	w.units = _keep_player_units(w)
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	ok(g1 != null and g2 != null, "有两个将领可用")
	var per: int = w.retinue_of(g2.id).size()
	eq(per, PER, "（前提）将领 2 名下开局有 %d 个兵（关卡摆的）" % PER)
	# ★★ 单位页第 2 / 3 行要 2 / 3 级大本营：这里把己方大本营设成 3 级，
	#    才能把七个兵种各招一遍（行号门槛本身在 test_base_limits 里单独验）。
	var base = w.find_base_of("p1")
	if base != null:
		base.level = 3

	# ★ 单位页能招的是 recruit.list 的七个兵种（不是将领名册 —— 名册本轮扩到 9 位）。
	var unit_kinds: Array = _unit_kinds(w)
	for tt in unit_kinds:
		ok(w.is_recruitable(String(tt)), "config.recruit.list 里 %s 可招募" % tt)
	ok(not w.is_recruitable("nope"), "表里没有的兵种不能招募")

	var kind := String(unit_kinds[0])          # 长枪兵

	# ★ 2026.10.25：全部造价 ×2 —— 七个兵种各招一遍要 1240 粮 / 960 金，
	#   原来的 1000/1000 已经不够（投石车招不出来）。这里给足，本用例验的是编制归属。
	w.resources["food"] = 5000.0
	w.resources["gold"] = 5000.0
	w.zones.zone_at(g1.tx, g1.ty)["population"] = 10.0
	w.zones.zone_at(g2.tx, g2.ty)["population"] = 10.0

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

	var sub = w.retinue_of(g1.id)[0]
	ok(not w.can_recruit(kind, sub.id, "p1").is_empty(),
		"★ 附属兵不是队长，不能往它名下招兵")
	var e2 = w.spawn_enemy(10, 12)
	if e2 != null:
		ok(not w.can_recruit(kind, e2.id, "p1").is_empty(),
			"不能把兵招到敌方单位名下")
		ok(not w.can_recruit(kind, g1.id, FactionRes.NPC_FACTION).is_empty(),
			"★ 防冒充：别的阵营不能拿我方将领的 id 招兵")
		w.units.erase(e2)          # 读条期间别让它来搅局

	ok(CommandRes.apply(w, cfg, {
		"kind": "recruit", "unit_kind": kind, "leader_id": g2.id, "faction": "p1"}),
		"选中将领 2 之后，招募命令被接受（入队）")
	eq(g2.train_kind, kind, "★ 队列排在将领 2 名下")
	ok(not g1.is_training(), "★ 将领 1 名下没有队列（没招错人）")
	eq(w.retinue_of(g2.id).size(), per, "★ 入队不会立刻生成单位（要读条 10 秒）")

	for _i in 601:
		w.tick(DT)
	eq(w.retinue_of(g2.id).size(), per + 1, "★ 10 秒后将领 2 名下多了一个兵")
	eq(w.retinue_of(g1.id).size(), PER,
		"★ 将领 1 名下一个不多（它自己名下的兵是关卡摆的那 %d 个）" % PER)

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

	for i in range(1, unit_kinds.size()):
		var other := String(unit_kinds[i])
		ok(CommandRes.apply(w, cfg, {
			"kind": "recruit", "unit_kind": other, "leader_id": g2.id, "faction": "p1"}),
			"将领 2 名下也能排 %s" % other)
		# 一单一单等它读完（队列上限 5；七单一起排会撞上限）。
		for _j in int(ceil((float(w.recruit_train_sec(other)) + 0.2) / DT)):
			w.tick(DT)
	eq(w.retinue_of(g2.id).size(), per + unit_kinds.size(),
		"★ 七个兵种各招一个之后，名下多了 %d 个" % unit_kinds.size())

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

	kill_unit_now(cfg, w, g2)
	ok(not g2.alive, "将领 2 已阵亡")
	ok(not w.can_recruit(kind, g2.id, "p1").is_empty(),
		"★ 队长阵亡后不能再往它名下招兵")
	cfg.combat_enabled = true
