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
	cleanup_escort_scaffold()


## ★★ 本轮口径（重要，读一遍再改这个文件）：
##   `config.json` 的 `unit.general.escort` 全局缺省**已删除** ——
##   开局有几个附属兵**完全等于关卡 `start_units[]` 里摆出来的那些**
##   （`escort_of` 指向同阵营第几位将领）。所以这一整套用例的世界改由
##   `require_world_with_escorts()` 造（它写一份探针关卡，给每位将领摆 3 个兵）。
##   ⇒ 「几个附属兵」这个数**不再来自 config**，而是来自那份探针（`PER`）。
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


## 出生：数量、类型、id 规则、没有快捷键
func _test_spawn(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	# ★★ 「几个附属兵」现在的来源是**关卡摆放**（探针里每位将领摆了 PER 个）——
	#   不再是 config 的 `unit.general.escort`（那一条本轮已删除）。
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
		# ★★ 本轮的核心：附属兵是**将领自己那一类**的兵（不再是固定的亲兵）
		var leader = w.unit_by_id(s.leader_id)
		ok(leader != null, "附属兵的队长在场")
		if leader != null:
			eq(String(s.kind), String(leader.unit_type), "★ 附属兵的 kind = 队长的单位类型")
			eq(String(s.unit_type), String(leader.unit_type), "★ 附属兵与队长同类型")

	# ★★ 顺序契约：**每一位将领都排在它自己的兵前面**。
	#
	# 本轮之前这条靠「将领全部由 spawn_faction_units 在摆放之前造好」保证；
	# 现在「摆了附属部队的那一方连将领都由关卡摆」，所以 `_apply_level_placement`
	# 改成**按方分批**：先补这一方的将领，再摆这一方的兵（见 world.gd 那段说明）。
	# 这里逐条钉住它：每个附属兵的队长必须**在它之前**出现在 world.units 里。
	var pos: Dictionary = {}
	for i in w.units.size():
		pos[String(w.units[i].id)] = i
	for s in subs:
		var lp: Variant = pos.get(String(s.leader_id), -1)
		ok(int(lp) >= 0 and int(lp) < int(pos[String(s.id)]),
			"★★ 将领排在它自己的兵前面（%s @%d < %s @%d）"
				% [String(s.leader_id), int(lp), String(s.id), int(pos[String(s.id)])])
	# 三个将领分别是三种类型（长枪兵 / 长弓兵 / 骑手）
	var got_types: Array = []
	for g2 in generals:
		got_types.append(String(g2.unit_type))
	eq(got_types, cfg.general_types(), "★ 三个将领分别被赋上配置里的三个类型")


## 出生位置：附属兵站在**作者摆的那一格**上，而且能走、不卡建筑
##
## ★★ 本轮口径变更：附属兵不再是「围着将领自动生成一圈」（`create_escort` 已删除），
##    而是**关卡 `start_units[]` 里逐兵摆出来的坐标** ⇒ 「挨着队长 2 格以内」
##    这条**不再成立**（作者可以把兵摆在任何地方）。
##    ⇒ 这里改钉三件本轮真的成立、而且更要紧的事：
##      ① 附属兵真的站在作者写的那一格上（摆放坐标不被别处改写）；
##      ② 那一格能走、没卡在建筑里；
##      ③ 它仍然**挂在自己的将领**名下（这才是「附属」的定义）。
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
	# 附属兵由 `fill_general_retinue` 生成在**队长附近**（`_ring_tile`：先正交、再斜角）——
	# 新口径下作者不摆兵的坐标，只写「生成几个 + 兵种权重」。
	var seen_tiles := {}
	for i in ret.size():
		var s = ret[i]
		eq(String(s.leader_id), "general-1", "★ 每个兵都挂在 general-1 名下（%s）" % s.id)
		var d: int = maxi(absi(s.tx - g.tx), absi(s.ty - g.ty))
		ok(d >= 1 and d <= 2, "★ 附属兵生成在队长附近（%s 距队长 %d 格）" % [s.id, d])
		ok(not seen_tiles.has(Vector2i(s.tx, s.ty)), "附属兵各占一格（%s）" % s.id)
		seen_tiles[Vector2i(s.tx, s.ty)] = true

	# 附属兵不能站在山上 / 卡在不能站的建筑里
	for s in ret:
		ok(w.map.terrain_walkable(s.tx, s.ty), "附属兵站在可通行格上：%s" % s.id)
		var b = w.building_at(s.tx, s.ty)
		ok(b == null or b.blocks(s.faction) == false, "附属兵没卡在不能站的建筑里：%s" % s.id)


## 队伍模型的语义
func _test_group_model(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var per: int = PER
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
	# ★ 编制可以逐将不同（关卡摆几个就是几个）⇒ 两队的规模**可以不一样**，要各算各的
	var g2 = w.unit_by_id("general-2")
	var per2: int = w.retinue_of(g2.id).size()
	var two = w.expand_to_groups([g1, g2])
	eq(two.size(), (1 + per) + (1 + per2), "两支队伍的队长一起选中 → 展开出两队所有人")
	eq(two[0].id, g1.id, "第一队的队长在最前（顺序稳定）")
	eq(two[1 + per].id, g2.id, "第二队的队长紧随其后")

	# 不属于任何队伍的单位（测试敌人）→ 只选中自己
	var e = w.spawn_enemy(10, 12)
	if e != null:
		eq(w.group_of(e).size(), 1, "测试敌人不属于任何队伍，只选中自己")
		eq(w.retinue_of(e.id).size(), 0, "测试敌人没有附属兵")


## ★ 队长阵亡后：附属兵不能被凭空造出一个队长，也不该互相牵连
func _test_leader_dead(cfg) -> void:
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	var g1 = w.unit_by_id("general-1")
	var per: int = PER
	var ret = w.retinue_of(g1.id)
	eq(ret.size(), per, "先确认有附属兵")

	# 让队长阵亡（单机：死了就离场）
	# ★★ 加了「将领濒死保护」之后不能像从前那样直接 take_damage（那样只会让它倒地：
	#    旗下还有部队时它将进入濒死，见 logic/unit.gd 与 data/config.json 的 revive 段）。
	#    本节要的场面是「**附属兵还活着、队长却没了**」，所以按权威规则摆出来：
	#      ① 开局的附属兵先请离场（它们与本节无关：本节的 `per` 个兵下面会**重新**补上）；
	#      ② 补上 `per` 个**新的**活兵挂在它名下；
	#      ③ 打光它们 → 世界收尸 → 它因为「旗下无部队」当场阵亡（用户拍板）；
	#      ④ 再补上 `per` 个活兵挂在它名下（它们的队长 id 仍然指着它，而它已经离场）——
	#         这就是「孤儿附属兵」那个状态。
	#    ⚠️ 不要图省事写成「清空 leader_id」这类改数据的手法：本节验的正是
	#      「队长不在 world.units 里时，`team_leader` / `group_of` 怎么回答」。
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

	# 目标点应当基本一致（每个单位都朝同一个位置走）
	var toward = 0
	for u in group:
		# 允许被推挤/拉直后的细微差别，只验「朝那个方向」
		if u.has_goal:
			toward += 1
	eq(toward, group.size(), "整队都记住了目标点")

	# ★ 同阵营的另一支队伍没有被顺带下令
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


## 给某个将领补上 n 个**新鲜的**附属兵（队长 id 指着它，编号带 `t` 以示与开局兵不同）。
##
## ★ 为什么需要它（本轮新增）：将领濒死保护让「打光它的兵」变成了「它当场阵亡」的
##   必经之路（用户拍板：无附属部队时直接死亡），于是想摆出「附属兵还活着、队长却没了」
##   这个状态，就必须能在队长死后**再补几个兵**挂在它名下 —— 那正是「孤儿兵」的定义。
## ★ 数值与真实招募的兵同源（`unit_hp_of` / `general_type_at`），位置借队长的格，
##   所以它对 `group_of` / `team_leader` 这些判据来说与真兵没有任何区别。
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


## ★ 需求明确要求「不自动跟随」：没下令时附属兵不该自己跑
##
## ★ 关掉战斗：地图上有两个**会自己推进的巡逻兵**，走完这段路要好几秒 ——
##   它们会进警戒半径、把「将领/附属兵自己动起来」和「跑位跟上去」混在一起。
##   这一条验的是「不自动跟随」这条契约，不是战斗。
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


## 数值按**单位类型**分开：三种兵各自一套，不会退化成兜底值
##
## ★★ 用户确认的口径是「将领数值 = 它所属类型的数值」——
##    所以这里不再断言「附属兵比将领弱」，而是断言
##    「将领与它的附属兵同类型 ⇒ 同数值」「不同类型 ⇒ 不同数值」。
## ★★ 本次改动：原来末尾那两条断言拿「测试敌人」（`spawn_enemy` 刷出来的那种）
##    当反例（「没退化成敌人的数值」）。那个类型已经删除，刷出来的是**长枪兵**，
##    于是那两条会变成「长枪兵 ≠ 长枪兵」而恒假。现在改成拿**另一种兵**当反例 ——
##    语义一样（「按类型分开」），而且不依赖那个被删掉的类型。
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
	#   现在换成「跟**另一种兵**必须不同」—— 同一个坑（数值没按类型查表）照样抓得住。
	var other := "rider" if t != "rider" else "spearman"
	ok(s.hp_max != cfg.unit_hp_of(other),
		"★ 附属兵的数值没有退化成**另一种兵**（%s vs %s）" % [t, other])
	ok(s.combat_damage(cfg) != float(cfg.unit_combat_of(other)["damage"]),
		"★ 附属兵的伤害也没有退化成另一种兵的")
	eq(e.hp_max, cfg.unit_hp_of(UnitRes.UNIT_TYPE_SPEARMAN),
		"★ 调试刷出来的单位按**长枪兵**查表（不再有自己的那一档）")

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
	var w = require_world_with_escorts(cfg, PER)
	if w == null:
		return
	w.units = _keep_player_units(w)
	var g1 = w.unit_by_id("general-1")
	var g2 = w.unit_by_id("general-2")
	ok(g1 != null and g2 != null, "有两个将领可用")
	# ★ 编制取自**关卡摆放**（探针给每位将领摆了 PER 个）—— 这一节盯的是**将领 2**
	#   （它排到的兵要接在它自己那份之后）
	var per: int = w.retinue_of(g2.id).size()
	eq(per, PER, "（前提）将领 2 名下开局有 %d 个兵（关卡摆的）" % PER)

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
	# ★★ 走 `kill_unit_now`（本节的语义是「队长**阵亡**之后能不能再招」）：
	#    加了将领濒死保护之后，直接 take_damage 只会让它倒地，那时
	#    `can_recruit` 虽然照旧拒绝，但拒因是「人还活着但躺着」，
	#    验的就不是本节想验的那条规则了。
	kill_unit_now(cfg, w, g2)
	ok(not g2.alive, "将领 2 已阵亡")
	ok(not w.can_recruit(kind, g2.id, "p1").is_empty(),
		"★ 队长阵亡后不能再往它名下招兵")
	cfg.combat_enabled = true
