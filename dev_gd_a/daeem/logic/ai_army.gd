## ai_army.gd —— 指挥官 AI 的军队层：编队、整备、行军、驻守、扩张、回防。
##
## 一个「队」= 将领 + 它辖下的附属兵（`world.group_of(leader)`）。★ 不把附属兵从将领身边拆走：
## 本作的编制、招募、濒死救援都挂在队长 id 上，拆开会让上面那些系统对不上。
##
## ★★ 2026.10.24 重做（用户口径：让指挥官「更会玩游戏、更有活人感」）：
##   · **按队活动**：每支「将 + 兵」的小队先补到合适规模再出门，不再让一支部队一路
##     招到全族上限、其余将领光杆巡逻；
##   · **守军轮换**：基地常驻 1 支守军补员；它补到 `home_team_size` 后轮换出门，
##     由另一支（至少有 1 个兵）接替守军，形成「补员 → 出征 → 新队接防」的循环；
##   · **小队占中立、大队打硬目标**：≥`squad_units` 的小队去占无主 / 无守军区划；
##     ≥`enemy_zone_min_units` 才打敌方区划；≥`assault_units` 才打敌方大本营。
##     打硬目标时可以临时合并多支小队（同一条行军命令）；
##   · **光杆司令不出门**：低于 `min_field_units` 的队伍不巡逻、不扩张、不进攻；
##     在己方领地外掉到这么少的队伍会**回撤**到最近的己方区划中心整备（边撤边招）；
##   · **扩张盯住区划中心**：选中目标后一直把队伍派到区划中心 3×3 内读条，
##     直到归属翻过来才换下一个目标（不会走一半又换目标）；
##   · **闲置部队有活干**（2026.10.25）：缺编队（有 1~2 个兵）去己方前线区划
##     中心 / 隘口驻守；满编队去敌方 / 中立边界外侧侦察，顺路占没有守军的空区划。
##     侦察看到接近自己规模的敌军就整队撤；没有安全侦察目标时，满编队去前线守备。
##
## 四条玩家指令仍然在这里落地：
##   · march   —— 行军攻击到玩家点选的目标点，到达后驻守；目标是敌方区划中心时自然读条占领。
##   · develop —— 不主动出击；军队留在基地区划附近，受威胁时回防。
##   · expand  —— 优先夺取与己方领土相邻、按经济需求评分最高的中立 / 敌方区划：
##                派队伍去区划中心读条，拿下一块再找下一块。
##   · mass    —— 全军集结到玩家点选的集结点，驻守补员，不主动扩张。
## `auto` 是自主模式：守军补员 → 小队占中立 → 大队打硬目标 → 余队巡逻。
##
## ★ 所有移动命令都走 `CommandProcessor.order_group_attack_move`：
##   它与玩家「选中整队 + 点地图」是同一条路（队形、通行判定都在里面），
##   于是 AI 不会绕过任何玩法规则。
extends RefCounted

const CommandProcessorRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")
const GridRes = preload("res://logic/grid.gd")


static func update(ai, dt: float) -> void:
	if ai.world == null or ai.world.zones == null:
		return
	ai.recall_cd = maxf(0.0, ai.recall_cd - dt)
	# 回防期间不再执行原指令（否则每帧「回防 → 又被指令拉走」来回抖）
	if ai.world.time < ai.defend_until:
		return
	# ★ 守军角色每帧校验一次：阵亡 / 离开基地区划时立刻换人，
	#   不然生产与「谁看家」会各说各话。
	ensure_garrison(ai)
	if _defense_tick(ai):
		return
	var order := String(ai.order_kind)
	match order:
		"march":
			_march(ai)
		"mass":
			_mass(ai)
		"expand":
			_expand(ai, true)
		"auto":
			_auto(ai)
		_:
			_develop(ai)
	# ★★ 缺编队的防守驻守：自主 / 玩家扩张时都要做。
	#    `march` / `mass` 是玩家明确要全军动起来，不能拿弱队去占中心。
	#    `auto` 的前线 / 区划守备已经在 `_auto()` 里、巡逻之前分配好；
	#    这里只补弱队驻守，避免重复抢队伍。
	if order == "auto":
		_assign_defensive_posts(ai)
	elif order == "expand":
		_assign_defensive_posts(ai)
		_assign_ready_guards(ai)
		_assign_zone_guards(ai)
	# `auto` 已经在 `_auto()` 里做过补员回撤；玩家「扩张 / 发展」下也要补兵优先。
	if order == "expand" or order == "develop":
		ai.regroup_ids.clear()
		_recall_understrength_for_recruit(ai)
	_cohesion_tick(ai)


## ★★ 队伍粘合：将领在移动、某个附属兵却停下 / 掉队（且不在战斗）时，
## **重发整队命令**。绝不单独给某一个兵下令 —— 用户口径：command AI 只能给部队下指令。
static func _cohesion_tick(ai) -> void:
	var cc: Dictionary = ai.profile.get("cohesion", {})
	if not bool(cc.get("enabled", true)):
		return
	if ai.world == null or ai.world.time < float(ai.cohesion_next_at):
		return
	ai.cohesion_next_at = ai.world.time \
		+ maxf(0.2, float(cc.get("interval_sec", 1.2)))
	var max_d := maxf(1.0, float(cc.get("max_distance_tiles", 4.0)))
	# ★★ 2026.10.25：守军也纳入粘合巡检 —— 守军附属兵追出去同样算脱轨。
	for t in leader_teams(ai):
		var leader = t.get("leader", null)
		if leader == null or not leader.alive or leader.is_downed():
			continue
		# 受击即时命令的冷却 / 模式锁期间不要重发整队命令。
		if _react_locked(ai, String((leader as Object).id)):
			continue
		# 将领本身在战斗：不要把整队从交战里拽出来，但后方掉队的兵还是要拉上来。
		if leader.target != null or leader.target_building != null:
			_pull_stragglers(ai, t, leader, max_d)
			continue
		var leader_move := bool(leader.has_attack_move) or bool(leader.moving)
		var goal: Vector2 = leader.pos
		if bool(leader.has_attack_move):
			goal = leader.attack_move_goal
		elif bool(leader.moving):
			# 普通移动：`leader.goal` 是它的**队形槽位**，整队目标点记在 `last_orders` 里。
			# 用槽位重发会让全队每次粘合都整体偏移一次。
			var lo: Dictionary = ai.last_orders.get(String(leader.id), {})
			goal = lo.get("pt", leader.goal)
		var need := false
		for m in (t.get("units", []) as Array):
			if m == null or m == leader or not m.alive or m.is_downed():
				continue
			# ★★ 2026.10.25：正在打自己目标的兵也可能脱轨。
			#   以前这里直接 `continue`，于是一个兵自己追出去、队伍走了也不管。
			#   现在只要它离队超过 1.5 倍阈值（或将领在移动且它已掉出阈值）就重发整队命令，
			#   `_order_team` 会先清掉它的单兵反击状态再拉回队伍。
			if m.target != null or m.target_building != null:
				var gap: float = m.pos.distance_to(leader.pos)
				if gap > max_d * 1.5 or (leader_move and gap > max_d):
					need = true
					break
				continue
			if String(m.rescue_leader_id) != "" or bool(m.returning_home):
				continue
			if m.pos.distance_to(leader.pos) > max_d:
				need = true
				break
			# 将领走、兵却停了；或将领停、兵还在走（旧命令残留）。
			if leader_move and not bool(m.has_attack_move):
				need = true
				break
			if not leader_move and bool(m.has_attack_move):
				need = true
				break
			# 都在走，但目标点不是同一个：说明兵还在执行上一条旧命令。
			if leader_move and bool(m.has_attack_move) \
					and m.attack_move_goal.distance_to(goal) > 1.5:
				need = true
				break
		if not need:
			continue
		# ★ 重发**整队**命令；force 绕过去重，否则「同一目标、刚下过」会被跳过。
		# ★ 撤退 / 回撤是普通移动，粘合时也必须保持「移动」而不是切成行军攻击，
		#   否则队伍会在回家路上被沿途敌人反复拖住。
		if bool(leader.has_attack_move):
			_order_team(ai, t, goal, false, true)
		else:
			_move_team(ai, t, goal, true)


## 将领已经在交战、不能重发整队命令时，只把后方掉队的成员拉向将领。
## 这是「前面的部队还在打，后面的兵却停住」的补丁：不打断将领当前目标。
static func _pull_stragglers(ai, team: Dictionary, leader, max_d: float) -> void:
	var stuck: Array = []
	for m in (team.get("units", []) as Array):
		if m == null or m == leader or not m.alive or m.is_downed():
			continue
		if String(m.rescue_leader_id) != "" or bool(m.returning_home):
			continue
		var gap: float = m.pos.distance_to(leader.pos)
		var fighting: bool = m.target != null or m.target_building != null
		# 正在打而且离得不算远：让它继续打，别把兵从局部交火里拽出来。
		if fighting and gap <= max_d * 1.5:
			continue
		# 只要它停了（哪怕还挂着旧的 attack_move 目标），在将领交战时都要拉上来。
		var inactive := not bool(m.moving)
		if gap > max_d or inactive:
			stuck.append(m)
	if stuck.is_empty():
		return
	for u in stuck:
		if u.has_method("is_retaliating") and u.is_retaliating():
			u.clear_retaliation()
	var ok: bool = CommandProcessorRes.order_group_formation(
		ai.world, ai.cfg, stuck, leader.pos, false)
	if ok:
		ai.stats["orders"] = int(ai.stats.get("orders", 0)) + 1


## ★★ 受击即时命令的冷却 / 模式锁是否仍在生效。
## 这期间其它战略逻辑（巡逻 / 扩张 / 守备 / 粘合 / 回撤）不要抢方向盘，
## 否则会出现「刚反击又撤退、刚撤退又反击」的抽搐。
static func _react_locked(ai, lid: String) -> bool:
	if ai == null or ai.world == null:
		return false
	var t: float = ai.world.time
	return t < float(ai.react_next.get(lid, 0.0)) \
		or t < float(ai.react_until.get(lid, 0.0))


## ★★ 2026.10.25：开局 60 秒「扩张期」。
static func is_early_game(ai) -> bool:
	if ai == null or ai.world == null:
		return false
	var eg: Dictionary = ai.profile.get("early_game", {})
	if not bool(eg.get("enabled", true)):
		return false
	return ai.world.time < maxf(0.0, float(eg.get("until_sec", 60.0)))


## 当前「能出门」的最低队伍人数：开局 1，之后恢复正常 `min_field_units`。
static func _min_units(ai) -> int:
	var eg: Dictionary = ai.profile.get("early_game", {})
	if is_early_game(ai):
		return maxi(1, _i(eg, "min_field_units", 1))
	var ec: Dictionary = ai.profile.get("expand", {})
	return maxi(2, _i(ec, "min_field_units", 3))


## 当前「去占无守军区划」的最低规模：开局 1，之后恢复 `squad_units`。
static func _squad_units(ai) -> int:
	var eg: Dictionary = ai.profile.get("early_game", {})
	if is_early_game(ai):
		return maxi(1, _i(eg, "min_squad_units", 1))
	var ec: Dictionary = ai.profile.get("expand", {})
	return maxi(2, _i(ec, "squad_units", 3))


# ------------------------------------------------------------------
# 编队 / 队伍规模
# ------------------------------------------------------------------

## 所有「活着的队长」各成一队；队长已阵亡的散兵各算一队（避免他们永远不动）。
static func teams(ai) -> Array:
	var out: Array = []
	for u in ai.world.units:
		if not u.alive or String(u.faction) != ai.faction:
			continue
		if u.is_downed():
			continue
		if String(u.leader_id) == "":
			var g: Array = ai.world.group_of(u)
			out.append({"leader": u, "units": g, "size": g.size(),
				"role": String(ai.team_roles.get(String(u.id), ""))})
		else:
			var l = ai.world.unit_by_id(String(u.leader_id))
			if l == null or not l.alive:
				out.append({"leader": u, "units": [u], "size": 1, "role": ""})
	return out


## 只保留「真正的将领」当队长的队伍（散兵不参与战略决策）。
static func leader_teams(ai) -> Array:
	var out: Array = []
	for t in teams(ai):
		var leader = t["leader"]
		if leader != null and leader.is_general():
			out.append(t)
	return out


## 这支队伍的附属兵数（不含将领本人）。
static func team_escorts(ai, leader) -> int:
	if leader == null or not leader.alive:
		return 0
	return ai.world.retinue_of(String(leader.id), true).size()


## 队伍总人数（含将领本人）。
static func team_total(ai, leader) -> int:
	if leader == null or not leader.alive:
		return 0
	return 1 + team_escorts(ai, leader)


## 队伍总人数 + 还在队列里的人数（生产决策要按「补完之后」算，否则会超招）。
static func team_projected(ai, leader) -> int:
	if leader == null or not leader.alive:
		return 0
	return team_total(ai, leader) + int(leader.train_queue_size())


static func _role_of(ai, leader) -> String:
	if leader == null:
		return ""
	return String(ai.team_roles.get(String(leader.id), "line"))


## 远程队的行军落点：停在目标 `standoff_tiles` 外，靠射程输出。
static func _role_target_point(ai, leader, pt: Vector2) -> Vector2:
	if _role_of(ai, leader) != "ranged":
		return pt
	var roles: Dictionary = ai.profile.get("roles", {})
	var rc: Dictionary = roles.get("ranged", {})
	var standoff := maxf(0.0, float(rc.get("standoff_tiles", 4.5)))
	if standoff <= 0.0:
		return pt
	var dir: Vector2 = leader.pos - pt
	if dir.length_squared() < 0.0001:
		var base = ai.world.find_base_of(ai.faction)
		if base != null:
			dir = Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5) - pt
	if dir.length_squared() < 0.0001:
		dir = Vector2.LEFT
	return _clamp_map_point(ai, pt + dir.normalized() * standoff)


## 把整队拉回大本营（**普通移动**，不是行军攻击：撤退路上不该停下来打）。
static func _retreat_team(ai, leader) -> void:
	if leader == null or not leader.alive:
		return
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return
	var rally := _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	# force=false：已经在去同一个集结点就不要再刷一次命令（否则每 tick 重置路径会抽搐）。
	_move_team(ai, {"leader": leader, "units": ai.world.group_of(leader)},
		rally, false)
	var lid := String(leader.id)
	ai.regroup_ids[lid] = true
	# 撤退时立即放弃侦察 / 驻守任务，下一轮再重新评估（避免回家路上又被任务拉回去）。
	ai.scout_missions.erase(lid)
	ai.post_missions.erase(lid)
	ai.guard_missions.erase(lid)
	ai.stats["role_retreats"] = int(ai.stats.get("role_retreats", 0)) + 1
	ai.note_status("retreating")


static func _my_zone_ids(ai) -> Dictionary:
	var ids: Dictionary = {}
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if FactionRes.same_side_for_attack(String(zd.get("owner", "")), ai.faction):
			ids[int(zd.get("id", -1))] = true
	return ids


## ★ 游击队目标：与己方相邻、守军很少 / 没有守军的边界区划。
static func _pick_guerrilla_zone(ai) -> Variant:
	var my_ids := _my_zone_ids(ai)
	if my_ids.is_empty():
		return null
	var roles: Dictionary = ai.profile.get("roles", {})
	var gc: Dictionary = roles.get("guerrilla", {})
	var max_enemy := maxf(0.0, float(gc.get("max_enemy_strength", 3.0)))
	var threat_radius := maxf(0.0, float(ai.profile.get("expand", {}).get("threat_radius", 6.0)))
	var best: Variant = null
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		var zid := int(zd.get("id", -1))
		if my_ids.has(zid) or ai.failed_expand_zones.has(zid):
			continue
		var owner := String(zd.get("owner", ""))
		if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null or not _adjacent_to_mine(ai, zd, my_ids):
			continue
		var ct: Vector2i = cv
		var center := GridRes.center_of(ct)
		var enemy := _enemy_strength_near(ai, center, threat_radius)
		if enemy > max_enemy:
			continue
		var prod: Dictionary = zd.get("production", {})
		var score := 4.0 - enemy * 2.0
		if owner == "":
			score += 2.0
		score += float(prod.get("food", 0.0)) + float(prod.get("gold", 0.0))
		# 同分按区划 id 稳定选择。
		if score > best_score or (is_equal_approx(score, best_score) \
				and (best == null or zid < int((best as Dictionary).get("id", -1)))):
			best_score = score
			best = zd
	return best


## 某个职能、已经能出门的队伍（按队总人数从多到少、id 稳定排序）。
static func _role_teams(ai, role: String, min_units: int) -> Array:
	var out: Array = []
	for t in field_teams(ai):
		if _role_of(ai, t["leader"]) != role:
			continue
		if team_total(ai, t["leader"]) < min_units:
			continue
		out.append(t)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := team_total(ai, a["leader"])
		var sb := team_total(ai, b["leader"])
		if sa != sb:
			return sa > sb
		return String((a["leader"] as Object).id) < String((b["leader"] as Object).id))
	return out


## 基地区划 id（没有大本营 / 没有区划 → -1）。
static func _base_zone_id(ai) -> int:
	var b = ai.world.find_base_of(ai.faction)
	if b == null:
		return -1
	return int(b.zone_id)


## ★★ 选定 / 取回「守军」将领：优先当前 id；失效（阵亡 / 不在基地区划）时重选。
##
## 守军是**角色**不是「唯一能招募的人」：它负责看家、优先补员；补满后由
## `maybe_rotate_garrison()` 换人，它自己变成外勤队出去。
## 选人规则：基地区划内、活着的真将领，兵最多的优先（基地防守更稳），同分按 id。
static func ensure_garrison(ai):
	# ★★ 2026.10.25：开局 60 秒不强制「大本营区划必须有一支守军」。
	#   否则将领刚走出基地、下一 tick 就被抓回去，表现成走到一半又整体回城。
	if is_early_game(ai) \
			and not bool((ai.profile.get("early_game", {}) as Dictionary).get("require_garrison", false)):
		ai.garrison_leader_id = ""
		return null
	var bz := _base_zone_id(ai)
	if bz < 0:
		ai.garrison_leader_id = ""
		return null
	var cur = ai.world.unit_by_id(String(ai.garrison_leader_id)) \
		if String(ai.garrison_leader_id) != "" else null
	if cur != null and cur.alive and not cur.is_downed() and cur.is_general():
		var zc = ai.world.zones.zone_at(cur.tx, cur.ty)
		if zc != null and int((zc as Dictionary).get("id", -1)) == bz:
			return cur
	var best = null
	var best_e := -1
	for u in ai.world.units:
		if not u.alive or String(u.faction) != ai.faction:
			continue
		if u.is_downed() or not u.is_general():
			continue
		if String(u.leader_id) != "":
			continue
		var zz = ai.world.zones.zone_at(u.tx, u.ty)
		if zz == null or int((zz as Dictionary).get("id", -1)) != bz:
			continue
		var e := team_escorts(ai, u)
		if e > best_e or (e == best_e and (best == null or String(u.id) < String(best.id))):
			best_e = e
			best = u
	ai.garrison_leader_id = "" if best == null else String(best.id)
	if best != null:
		ai.scout_missions.erase(String(best.id))
		ai.post_missions.erase(String(best.id))
		ai.guard_missions.erase(String(best.id))
	return best


## ★★ 守军轮换：守军补到 `home_team_size` 且基地里还有一支「至少 1 个兵」的队
## ⇒ 换它接防，老守军变成外勤队（下一步会被扩张 / 巡逻 / 进攻逻辑挑走）。
##
## @return true = 这一 tick 真的换人了
static func maybe_rotate_garrison(ai) -> bool:
	if is_early_game(ai) \
			and not bool((ai.profile.get("early_game", {}) as Dictionary).get("require_garrison", false)):
		return false
	var home = ensure_garrison(ai)
	if home == null:
		return false
	var pc: Dictionary = ai.profile.get("production", {})
	var ec: Dictionary = ai.profile.get("expand", {})
	var target := maxi(1, _i(pc, "home_team_size", 6))
	var min_units := _min_units(ai)
	# ★★ 2026.10.24：读条中的守军**也可以被换下来去巡逻 / 扩张**。
	#   只要它已经有「能出门」的规模、且基地里有一支能接防的队伍，就轮换；
	#   不要求它先补满 home_team_size（那会让读条中的将领永远钉在家里）。
	var training_dispatch: bool = bool(pc.get("dispatch_training_home", true)) \
		and home.is_training() and team_total(ai, home) >= min_units
	if team_projected(ai, home) < target and not training_dispatch:
		return false
	var bz := _base_zone_id(ai)
	if bz < 0:
		return false
	var min_replace := maxi(0, _i(pc, "min_garrison_replace_escorts", 1))
	var best = null
	var best_e := -1
	for u in ai.world.units:
		if not u.alive or String(u.faction) != ai.faction:
			continue
		if u.is_downed() or not u.is_general() or u == home:
			continue
		if String(u.leader_id) != "":
			continue
		var zz = ai.world.zones.zone_at(u.tx, u.ty)
		if zz == null or int((zz as Dictionary).get("id", -1)) != bz:
			continue
		# ★ 接替者必须是**还没补满**的队伍：否则「满编队 ↔ 满编队」会每秒互换守军，
		#   永远没人出门，还刷一堆轮换事件。
		if team_projected(ai, u) >= target:
			continue
		var e := team_escorts(ai, u)
		if e < min_replace:
			continue
		if e > best_e or (e == best_e and (best == null or String(u.id) < String(best.id))):
			best_e = e
			best = u
	if best == null:
		return false
	ai.garrison_leader_id = String(best.id)
	ai.scout_missions.erase(String(best.id))
	ai.post_missions.erase(String(best.id))
	ai.guard_missions.erase(String(best.id))
	# 老守军身上的旧命令缓存清掉：它现在要去接一个出征 / 巡逻任务，
	# 不清的话 `_order_team` 可能把它上一条「回家」的命令当成新的而跳过。
	ai.last_orders.erase(String(home.id))
	ai.stats["rotations"] = int(ai.stats.get("rotations", 0)) + 1
	ai.note_status("rotating")
	return true


## 留守将领（兼容旧接口名）：现在就是守军。
static func home_leader(ai):
	return ensure_garrison(ai)


## 出去打仗的队（不含守军；只认真将领）。
static func field_teams(ai) -> Array:
	var home = ensure_garrison(ai)
	var out: Array = []
	for t in leader_teams(ai):
		if home != null and (t["leader"] as Object) == home:
			continue
		out.append(t)
	return out


## 已经可以出门的外勤队（总人数 ≥ min_units）。
static func ready_field_teams(ai, min_units: int) -> Array:
	var out: Array = []
	for t in field_teams(ai):
		if team_total(ai, t["leader"]) >= min_units:
			out.append(t)
	return out


## ★★ 生产候选：己方区划内、还没补到「本队目标规模」的将领（守军优先）。
##
## 返回数组元素：{leader, deficit, escorts, garrison, prio}，已按 prio 降序排好。
## ★ 这里是「按队补员」的唯一入口：控制器只照这个表下单，不再自己挑一个
##   固定兵营一路招到上限。
static func recruit_candidates(ai) -> Array:
	var home = ensure_garrison(ai)
	var pc: Dictionary = ai.profile.get("production", {})
	var home_size := maxi(1, _i(pc, "home_team_size", 6))
	var field_size := maxi(1, _i(pc, "field_team_size", 4))
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_escorts := maxi(1, _i(ec, "min_field_units", 3) - 1)
	var base = ai.world.find_base_of(ai.faction)
	var base_pt := Vector2.ZERO
	if base != null:
		base_pt = Vector2(float(base.tx), float(base.ty))
	var out: Array = []
	for u in ai.world.units:
		if not u.alive or String(u.faction) != ai.faction:
			continue
		if u.is_downed() or not u.is_general():
			continue
		if String(u.leader_id) != "":
			continue
		# 只有站在己方区划里才能下单（与 `can_recruit` 的 zone 判据一致）。
		var z = ai.world.zones.zone_at(u.tx, u.ty)
		if z == null or not FactionRes.same_side_for_attack(
				String((z as Dictionary).get("owner", "")), ai.faction):
			continue
		var is_home: bool = home != null and u == home
		var target_size := home_size if is_home else field_size
		var projected := team_projected(ai, u)
		var deficit := target_size - projected
		if deficit <= 0:
			continue
		var escorts := team_escorts(ai, u)
		var prio := 0.0
		if is_home:
			prio += 100.0
		if escorts <= 0:
			prio += 60.0
		elif escorts < min_escorts:
			prio += 40.0
		prio += float(mini(deficit, 6)) * 2.0
		prio -= u.pos.distance_to(base_pt) * 0.1
		out.append({
			"leader": u, "deficit": deficit, "escorts": escorts,
			"garrison": is_home, "prio": prio,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa := float(a.get("prio", 0.0))
		var pb := float(b.get("prio", 0.0))
		if absf(pa - pb) > 1e-6:
			return pa > pb
		return String((a["leader"] as Object).id) < String((b["leader"] as Object).id))
	return out


## ★★ 当前「钱能解决」的补员缺口总数。
##
## 只统计：己方区划内、脱战、没到编制上限、队列没满、且**区划人口够**的候选。
## 这些兵是现在/马上能造出来的，所以建造（塔 / 墙 / 升级 / 特化）不能抢这笔预算。
## 被人口 / 战斗卡住的候选不算：那种情况下再怎么留钱也造不出来，不能因此把 AI 锁死。
static func pending_recruit_units(ai) -> int:
	if ai == null or ai.world == null:
		return 0
	var kind := _probe_recruit_kind(ai)
	if kind == "":
		return 0
	var n := 0
	for c in recruit_candidates(ai):
		if typeof(c) != TYPE_DICTIONARY:
			continue
		var cd: Dictionary = c
		var leader = cd.get("leader", null)
		if leader == null or not leader.alive:
			continue
		var lid := String(leader.id)
		if String(ai.world.can_recruit(kind, lid, ai.faction)) != "":
			continue
		if String(ai.world.can_afford_recruit(kind, lid)) == "population":
			continue
		n += maxi(0, int(cd.get("deficit", 0)))
	return n


## 预算估算用的「最便宜可招兵种」——**不消耗 RNG**。
## 不能用 `ai._pick_kind()`：那是真正的生产决策，会推进 `production_serial`
## 并抽 `unit_rand`；拿它来算预算会把随机序列改掉（确定性测试会漂）。
static func _probe_recruit_kind(ai) -> String:
	var best := ""
	var best_sum := INF
	for item in ai.world.recruit_list():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var kind := String((item as Dictionary).get("kind", ""))
		if kind == "" or not ai.world.is_unit_recruitable(kind):
			continue
		if not ai.world.unit_recruit_unlocked(ai.faction, kind):
			continue
		var c: Dictionary = ai.world.recruit_cost(kind)
		var s := float(c.get("food", 0.0)) + float(c.get("gold", 0.0))
		if s < best_sum:
			best_sum = s
			best = kind
	return best


## ★★ 2026.10.25：还没补到「接近本队目标规模」的队伍数。
##
## 旧版补将前只看 `understrength_team_count()`（< min_field_units），
## 于是一支 6 人目标的队伍只带 3 个兵时也算「齐了」，AI 会继续招新将领，
## 结果一堆半编队 + 新光杆。现在补将前要求现有队伍至少到「目标 - 2」：
## 外勤 6→4、守军 8→6。先把现有将领武装好，再考虑加新将。
static func understaffed_team_count(ai) -> int:
	var pc: Dictionary = ai.profile.get("production", {})
	var home_size := maxi(1, _i(pc, "home_team_size", 8))
	var field_size := maxi(1, _i(pc, "field_team_size", 6))
	var margin := maxi(0, _i(pc, "general_recruit_team_margin", 2))
	var home = ensure_garrison(ai)
	var n := 0
	for t in leader_teams(ai):
		var leader = t["leader"]
		var target := home_size if home != null and leader == home else field_size
		var need := maxi(2, target - margin)
		if team_projected(ai, leader) < need:
			n += 1
	return n


## 还没补到「能出门」规模的队伍数（补将前要看它：先装备好现有将领，别急着加光杆）。
static func understrength_team_count(ai) -> int:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var n := 0
	for t in leader_teams(ai):
		if team_total(ai, t["leader"]) < min_units:
			n += 1
	return n


## 正在读条的将领数（同时读条上限用）。
static func training_leader_count(ai) -> int:
	var n := 0
	for t in leader_teams(ai):
		var leader = t["leader"]
		if leader != null and leader.is_training():
			n += 1
	return n


static func army_count(ai) -> int:
	var n := 0
	for u in ai.world.units:
		if u.alive and String(u.faction) == ai.faction and not u.is_downed():
			n += 1
	return n


# ------------------------------------------------------------------
# 指令行为
# ------------------------------------------------------------------

static func _develop(ai) -> void:
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return
	var rally := _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	for t in leader_teams(ai):
		var leader = t["leader"]
		if leader == null or leader.is_downed():
			continue
		if _react_locked(ai, String(leader.id)):
			continue
		if leader.target != null or leader.target_building != null:
			continue
		var d: float = leader.pos.distance_to(rally)
		if d > 9.0:
			_order_team(ai, t, rally, false)


static func _march(ai) -> void:
	if not _has_order_point(ai):
		_develop(ai)
		return
	var pt := Vector2(float(ai.order_x), float(ai.order_y))
	var ts := field_teams(ai)
	if ts.is_empty():
		ts = leader_teams(ai)
	for t in ts:
		if _react_locked(ai, String((t["leader"] as Object).id)):
			continue
		_order_team(ai, t, pt, true)


static func _mass(ai) -> void:
	var pt := Vector2(float(ai.order_x), float(ai.order_y))
	if not _has_order_point(ai):
		var base = ai.world.find_base_of(ai.faction)
		if base == null:
			return
		pt = _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	var all := leader_teams(ai)
	# 至少留一位将领看家（否则生产会停）；只有一位时只能带上。
	var home = ensure_garrison(ai)
	var keep_home := home != null and all.size() >= 2
	for t in all:
		if keep_home and (t["leader"] as Object) == home:
			continue
		if _react_locked(ai, String((t["leader"] as Object).id)):
			continue
		_order_team(ai, t, pt, true)


## ★★ 扩张：把队伍派到「AI 认为需要的相邻区划」的中心读条。
##
## @param force true = 玩家直接下令「扩张」：凑不够理想规模也先派现有能派的队；
##              false = 自主模式：凑不够就继续补员 / 巡逻，不白送。
## @return true = 已有一个进行中的扩张任务（或这一帧真的开了一个）
static func _expand(ai, force: bool = false) -> bool:
	if _continue_expand(ai):
		return true
	if ai.world.time < ai.next_target_at:
		return false
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	# ★ 游击队优先：只挑「与己方相邻、守军很少 / 没有守军」的边界区划。
	var guerrilla_target := false
	var pick: Variant = null
	if not force:
		var guerrillas := _role_teams(ai, "guerrilla", min_units)
		if not guerrillas.is_empty():
			pick = _pick_guerrilla_zone(ai)
			guerrilla_target = pick != null
	if pick == null:
		pick = _pick_expand_zone(ai)
	if pick == null:
		# 没有可扩张的区划：玩家强制扩张时退到「打最近敌方目标」；
		# 自主模式交给 `_attack_if_ready()`（它要求更大的规模，避免小队伍送死）。
		if force:
			return _expand_fallback_attack(ai)
		return false
	var zd: Dictionary = pick
	var cv: Variant = zd.get("center", null)
	if cv == null:
		return false
	var center: Vector2i = cv
	var pt := GridRes.center_of(center)
	var threat_radius0 := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var target_defended := _enemy_strength_near(ai, pt, threat_radius0) > 0.0
	var chosen: Array = []
	if guerrilla_target:
		chosen = _role_teams(ai, "guerrilla", min_units)
		if not chosen.is_empty():
			chosen = [chosen[0]]
	else:
		var required := _required_units_for_zone(ai, zd)
		for t in _pick_mission_teams(ai, pt, required, force):
			# 游击队不参加正面扩张 / 硬目标；它们只打空档。
			if _role_of(ai, t["leader"]) != "guerrilla":
				chosen.append(t)
	# ★★ 2026.10.25：没有「达到出门规模」的外勤队时，允许一支小队伍去占
	#   **完全无守军的无主区划**。否则新招的外勤将领会一直卡在 1~2 个兵、
	#   既不能扩张也不能侦察，AI 会从 60 秒后一直闲置到它补满。
	#   有守军的敌方区划仍然必须凑够 `_required_units_for_zone`，不走这条。
	if chosen.is_empty() and not guerrilla_target \
			and String(zd.get("owner", "")) == "" and not target_defended:
		var boot: Variant = _pick_bootstrap_team(ai)
		if boot != null:
			chosen.append(boot)
	if chosen.is_empty():
		return false
	ai.target_zone = int(zd.get("id", -1))
	ai.expand_team_ids.clear()
	for t in chosen:
		var lid := String((t["leader"] as Object).id)
		ai.expand_team_ids.append(lid)
		ai.scout_missions.erase(lid)
		ai.post_missions.erase(lid)
		ai.guard_missions.erase(lid)
	ai.expand_started_at = ai.world.time
	for t2 in chosen:
		var op := pt
		if target_defended:
			op = _role_target_point(ai, t2["leader"], pt)
		_order_team(ai, t2, op, true)
	ai.stats["expands"] = int(ai.stats.get("expands", 0)) + 1
	ai.note_status("expanding")
	return true


## 继续一个进行中的扩张任务：目标还值得打、队伍还在、就持续压到区划中心。
static func _continue_expand(ai) -> bool:
	if int(ai.target_zone) < 0:
		return false
	var ec: Dictionary = ai.profile.get("expand", {})
	var timeout := maxf(10.0, float(ec.get("expand_timeout_sec", 75.0)))
	if ai.expand_started_at >= 0.0 and ai.world.time - ai.expand_started_at > timeout:
		# 走不到 / 打不下来：拉黑这一块，先去拿别的，避免全军卡死在同一个目标。
		ai.failed_expand_zones[int(ai.target_zone)] = true
		_clear_expand(ai, true)
		return false
	var z = ai.world.zone_by_id(int(ai.target_zone))
	if z == null:
		_clear_expand(ai)
		return false
	var zd: Dictionary = z
	if not _zone_worth_taking(ai, zd):
		# 归属已经翻过来（或目标失效）：结束任务。
		# ⚠️ `zones_taken` 由控制器每 2 秒对一次账统一统计（巡逻 / 大队顺手占下的也算），
		#   不在这一处重复 +1。
		_clear_expand(ai, true)
		return false
	var cv: Variant = zd.get("center", null)
	if cv == null:
		_clear_expand(ai)
		return false
	var center: Vector2i = cv
	var pt := GridRes.center_of(center)
	var min_units := _min_units(ai)
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var enemy_at_center := _enemy_strength_near(ai, pt, threat_radius)
	# ★★ 区划里的守军已经被清空：占领只看「有没有人站在中心」，不要求队伍还满编。
	#    旧逻辑会在队伍被打到 min_units 以下时直接放弃任务，于是「杀光守军却没人占领」。
	var undefended := enemy_at_center <= 0.0
	var alive: Array = []
	var total := 0
	for id in ai.expand_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed():
			continue
		if not u.is_general():
			continue
		var role := _role_of(ai, u)
		# 游击队：敌人一多就整队撤回，换空档；不要硬碰。
		if role == "guerrilla":
			var gc: Dictionary = (ai.profile.get("roles", {}) as Dictionary).get("guerrilla", {})
			if enemy_at_center > maxf(0.0, float(gc.get("max_enemy_strength", 3.0))):
				_retreat_team(ai, u)
				_clear_expand(ai, true)
				return false
		# 远程队：前排倒光、附近还有敌人 ⇒ 整队后撤，不要被贴脸。
		if role == "ranged":
			var rc: Dictionary = (ai.profile.get("roles", {}) as Dictionary).get("ranged", {})
			var need_front := int(rc.get("frontline_min", 1))
			if enemy_at_center > 0.0 and ai.frontline_count(u) < need_front:
				_retreat_team(ai, u)
				_clear_expand(ai, true)
				return false
		# ★ 单支队伍掉到「不能出门」的规模 ⇒ 从任务里剔除，交给 `_regroup` 带回整备；
		#   但目标已经没人防守时例外：一个活着的将也能站中心读条。
		if team_total(ai, u) < min_units and not undefended:
			continue
		alive.append({"leader": u, "units": ai.world.group_of(u)})
		total += team_total(ai, u)
	if alive.is_empty():
		# 队伍被打残了：放弃这一块，让它们先回去整备（`_regroup` 会接管）。
		_clear_expand(ai, true)
		return false
	if total < min_units and not undefended:
		_clear_expand(ai, true)
		return false
	# ★ 占领途中敌人增援到明显多于我方：别让小队继续往中心送，先撤。
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	if float(total) < enemy_at_center * avoid_ratio:
		_clear_expand(ai, true)
		return false
	for t in alive:
		var op := pt
		if not undefended:
			op = _role_target_point(ai, t["leader"], pt)
		_order_team(ai, t, op, true)
	ai.note_status("expanding")
	return true


static func _clear_expand(ai, delay: bool = false) -> void:
	ai.target_zone = -1
	ai.expand_team_ids.clear()
	ai.expand_started_at = 0.0
	if delay:
		var ec: Dictionary = ai.profile.get("expand", {})
		ai.next_target_at = ai.world.time + maxf(0.0, float(ec.get("next_target_delay_sec", 4.0)))


## 玩家强制扩张、但没有可占的相邻区划 ⇒ 打最近敌方目标（规模不够也派，
## 因为这是玩家的明确意图；仍然拒绝光杆司令）。
static func _expand_fallback_attack(ai) -> bool:
	var pt: Variant = _nearest_enemy_target(ai)
	if pt == null:
		return false
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var chosen := _pick_mission_teams(ai, pt, min_units, true)
	if chosen.is_empty():
		return false
	for t in chosen:
		_order_team(ai, t, pt, true)
	ai.stats["assaults"] = int(ai.stats.get("assaults", 0)) + 1
	ai.note_status("assault")
	return true


## ★★ 自主模式：守军轮换 → 打残的队伍回撤 → 继续进攻 / 扩张 → 发起新任务 → 巡逻。
##
## ★ 同一时间只跑一个「大战役」（进攻或扩张）：其余队伍照常巡逻 / 补员，
##   不会出现「一队在打、其余全部立正」的旧观感。
static func _auto(ai) -> void:
	ensure_garrison(ai)
	maybe_rotate_garrison(ai)
	# ★ 开局探索：必须在巡逻 / 守备之前接管唯一一支初始部队。
	_early_explore_tick(ai)
	ai.regroup_ids.clear()
	_regroup(ai)
	# ★★ 2026.10.25：缺兵但不在己方人口区 / 野外的队伍，先回最近的人口区补员。
	#   否则「资源富足」也没用 —— 将领不在己方区划里根本下不了招募单。
	_recall_understrength_for_recruit(ai)
	# ★ 小股 / 中等队伍看到成规模敌军就撤，不硬碰硬（进攻任务除外：那是主动凑够人才打的）。
	_avoid_bad_fights(ai)
	# 同一时间只跑一个「大战役」；其余队伍照常侦察 / 巡逻。
	if not _continue_assault(ai):
		if not _expand(ai, false):
			_attack_if_ready(ai)
	# ★★ 已经在敌方 / 中立区划里、周围敌人清空但没任务的队伍，直接去中心占。
	#    `_expand()` 只从「与己方相邻」的区划里选；追击队深入后目标可能不再相邻，
	#    需要这一条把「人已经站在区划里」的情况收口。
	_capture_cleared_zone_tick(ai)
	# ★★ 闲置满编队去边界外侧侦察；`_patrol` 会跳过已接侦察任务的队伍。
	_scout_tick(ai)
	# ★★ 2026.10.25：先把闲置满编队铺到前线 / 暴露区划，再让剩下的巡逻。
	#   顺序必须在 `_patrol()` 之前 —— 旧版先巡逻，队伍已经在往大本营走，
	#   守备分配看到 `moving` 就跳过，最后全挤在基地 / 中场。
	_assign_ready_guards(ai)
	_assign_zone_guards(ai)
	_patrol(ai)


## ★★ 2026.10.25：队伍已经站进敌方 / 中立区划、附近敌人清空，却没有任务：
## 直接把它派到区划中心读条。旧逻辑只认「与己方相邻的扩张目标」，
## 追击到深处的队伍即使把守军打光，也会原地站着不占。
static func _capture_cleared_zone_tick(ai) -> void:
	var ec: Dictionary = ai.profile.get("expand", {})
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	for t in field_teams(ai):
		var leader = t.get("leader", null)
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if ai.regroup_ids.has(lid) or ai.scout_missions.has(lid) \
				or ai.post_missions.has(lid) or ai.guard_missions.has(lid) \
				or ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		# 正在打 / 正在走的队伍先让它完成当前动作；停在原地且无目标的才接管。
		if leader.target != null or leader.target_building != null or bool(leader.moving):
			continue
		var z = ai.world.zones.zone_at(leader.tx, leader.ty)
		if z == null:
			continue
		var zd: Dictionary = z
		if not _zone_worth_taking(ai, zd):
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		var center: Vector2i = cv
		var pt := GridRes.center_of(center)
		if _enemy_strength_near(ai, pt, threat_radius) > 0.0:
			continue
		_order_team(ai, t, pt, true, true)
		ai.note_status("capturing")


## 这支队伍是不是正在执行「已进入空区划、去中心占领」的本地任务。
## 其它调度（侦察 / 守备 / 巡逻）看到它就不要抢方向盘。
static func _is_capturing_cleared_zone(ai, leader) -> bool:
	if leader == null or not leader.alive or not bool(leader.has_attack_move):
		return false
	var z = ai.world.zones.zone_at(leader.tx, leader.ty)
	if z == null:
		return false
	var zd: Dictionary = z
	if not _zone_worth_taking(ai, zd):
		return false
	var cv: Variant = zd.get("center", null)
	if cv == null:
		return false
	var center: Vector2i = cv
	return leader.attack_move_goal.distance_to(GridRes.center_of(center)) < 2.5


## ★★ 2026.10.25：这支队伍是不是「开局探索队」。
## 开局没有「守军」概念时，按 id 稳定地选一支初始将领当探索队。
static func _first_alive_general(ai):
	var best = null
	for u in ai.world.units:
		if u == null or not u.alive or u.is_downed() or not u.is_general():
			continue
		# ⚠️ 必须限定自己的阵营：开局没有守军时这里若扫到别家的将领，
		#    p2 的探索队会选中 p1 的将，造成 p1/p2 行为完全不对等。
		if String(u.faction) != ai.faction:
			continue
		if String(u.leader_id) != "":
			continue
		if best == null or String(u.id) < String(best.id):
			best = u
	return best


static func _is_early_explorer(ai, lid: String) -> bool:
	return ai != null and String(ai.explore_leader_id) == lid \
		and String(ai.explore_phase) != ""


static func _stop_early_explore(ai) -> void:
	ai.explore_leader_id = ""
	ai.explore_phase = ""
	ai.explore_target = Vector2.ZERO
	ai.explore_until = 0.0
	ai.explore_away = false


## ★★ 2026.10.25：开局探索。
##
## 开局只有一支初始部队时，旧逻辑会把它当守军，在基地周围巡逻点之间
## 左上右下来回走。这里改成：
##   出去探一圈（普通移动，不主动进攻）→ 回基地补员休整 → 再出去；
## 直到第二支将领出现 / 超过 `early_explore.until_sec`。
##
## 探索期间它不参加巡逻 / 扩张 / 进攻 / 守备；回到基地的 `rest` 阶段正常补员。
## @return true = 这一 tick 探索队由本函数接管
static func _early_explore_tick(ai) -> bool:
	var ecfg: Dictionary = ai.profile.get("early_explore", {})
	if not bool(ecfg.get("enabled", true)):
		return false
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return false
	var now: float = ai.world.time
	var until_sec := maxf(1.0, float(ecfg.get("until_sec", 90.0)))
	# 第二支将领出现 / 开局探索窗口结束：交回正常军队逻辑。
	if now > until_sec or int(ai.world.general_count_of(ai.faction)) >= 2:
		if String(ai.explore_phase) != "":
			_stop_early_explore(ai)
		return false
	var leader = null
	if String(ai.explore_leader_id) != "":
		leader = ai.world.unit_by_id(String(ai.explore_leader_id))
	if leader == null or not leader.alive or leader.is_downed():
		# 开局没有强制守军，`ensure_garrison()` 会返回 null；直接选初始将领。
		leader = ensure_garrison(ai)
		if leader == null or not leader.alive or leader.is_downed():
			leader = _first_alive_general(ai)
		if leader == null or not leader.alive or leader.is_downed():
			_stop_early_explore(ai)
			return false
		ai.explore_leader_id = String(leader.id)
	var lid := String(leader.id)
	var min_escorts := maxi(0, _i(ecfg, "min_escorts", 1))
	var ec: Dictionary = ai.profile.get("expand", {})
	# 开局探索不要求先补到正常出门规模：`min_escorts=0` 时光杆将领也能出去探路。
	var min_units := maxi(1, min_escorts + 1)
	if team_escorts(ai, leader) < min_escorts or team_total(ai, leader) < min_units:
		if String(ai.explore_phase) != "":
			_stop_early_explore(ai)
		return false
	var base_pt := _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	var near_base: bool = leader.pos.distance_to(base_pt) <= 5.0
	var team := {"leader": leader, "units": ai.world.group_of(leader)}
	var phase := String(ai.explore_phase)
	if phase == "":
		# 只让「开局唯一一支」去探；已经有别的外勤队就交给正常逻辑。
		var others := 0
		for t in field_teams(ai):
			if String((t["leader"] as Object).id) != lid:
				others += 1
		if others > 0:
			return false
		var target: Variant = _pick_explore_target(ai, leader)
		if target == null:
			return false
		ai.explore_phase = "out"
		ai.explore_target = target
		ai.explore_until = now + maxf(4.0, float(ecfg.get("hold_sec", 16.0)))
		ai.explore_away = false
		_move_team(ai, team, ai.explore_target, true)
		ai.stats["explores"] = int(ai.stats.get("explores", 0)) + 1
		ai.note_status("exploring")
		return true
	if phase == "out":
		if not near_base:
			ai.explore_away = true
		# 门口已经打起来了：停止开局探索，交给正常防守 / 回撤逻辑，
		# 不要在「出门探索 ↔ 回基地」之间来回。
		if near_base:
			var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
			if leader.target != null or _enemy_strength_near(ai, leader.pos, threat_radius) > 0.0:
				_stop_early_explore(ai)
				return false
		if now >= float(ai.explore_until):
			ai.explore_phase = "home"
			ai.explore_until = now + maxf(4.0, float(ecfg.get("hold_sec", 16.0)) * 0.5)
			_move_team(ai, team, base_pt, true)
			return true
		# ★★ 到了一个探索点不要立刻回基地：换下一个远处的点继续探，
		#    直到 60 秒窗口结束或没有可探索的点。旧逻辑「到点 → 回家 → 休整 →
		#    再出门」会在基地门口形成明显的反复进出。
		if leader.pos.distance_to(ai.explore_target) <= 3.0:
			var next: Variant = _pick_explore_target(ai, leader)
			if next != null and (next as Vector2).distance_to(ai.explore_target) > 4.0:
				ai.explore_target = next
				ai.explore_until = now + maxf(4.0, float(ecfg.get("hold_sec", 16.0)))
				_move_team(ai, team, ai.explore_target, true)
				ai.stats["explores"] = int(ai.stats.get("explores", 0)) + 1
				ai.note_status("exploring")
				return true
			ai.explore_phase = "home"
			ai.explore_until = now + maxf(4.0, float(ecfg.get("hold_sec", 16.0)) * 0.5)
			_move_team(ai, team, base_pt, true)
			return true
		if not bool(leader.moving) and not bool(leader.has_attack_move) \
				and leader.target == null and leader.target_building == null:
			_move_team(ai, team, ai.explore_target, true)
		return true
	if phase == "home":
		if near_base:
			ai.explore_phase = "rest"
			ai.explore_away = false
			ai.explore_until = now + maxf(2.0, float(ecfg.get("rest_sec", 8.0)))
			return true
		# 还没到基地：超时也继续往回走，不能停在半路进入休整。
		if now >= float(ai.explore_until) or (
				not bool(leader.moving) and not bool(leader.has_attack_move) \
				and leader.target == null and leader.target_building == null):
			ai.explore_until = now + maxf(4.0, float(ecfg.get("hold_sec", 16.0)) * 0.5)
			_move_team(ai, team, base_pt, true)
		return true
	if phase == "rest":
		if now >= float(ai.explore_until):
			ai.explore_phase = ""
			ai.explore_target = Vector2.ZERO
			ai.explore_away = false
		return true
	return false


## 开局探索目标：优先用侦察选点（空区划会顺手占）；没有就挑最近的
## 非己方区划中心。只用普通移动，不主动进攻。
static func _pick_explore_target(ai, leader) -> Variant:
	var ecfg: Dictionary = ai.profile.get("early_explore", {})
	var max_d := maxf(4.0, float(ecfg.get("max_distance_tiles", 22.0)))
	var start_d := maxf(3.0, float(ecfg.get("min_start_distance_tiles", 6.0)))
	var pick: Variant = _pick_scout_target(ai, leader)
	if pick != null and typeof(pick) == TYPE_DICTIONARY:
		var pv: Variant = (pick as Dictionary).get("pt", null)
		# 太近的目标会让「出门」变成原地转一圈，直接换更远的。
		if pv != null and leader.pos.distance_to(pv) >= start_d:
			return pv
	var avoid_ratio := maxf(0.1, float(ecfg.get("avoid_ratio", 1.0)))
	var ec: Dictionary = ai.profile.get("expand", {})
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var ours := float(team_total(ai, leader))
	var best: Variant = null
	var best_d := INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) == ai.faction:
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		var ct: Vector2i = cv
		var pt := GridRes.center_of(ct)
		var d: float = leader.pos.distance_to(pt)
		if d < start_d or d > max_d or d >= best_d:
			continue
		var enemy := _enemy_strength_near(ai, pt, threat_radius)
		if enemy > 0.0 and enemy > ours * avoid_ratio:
			continue
		best_d = d
		best = pt
	return best


## ★★ 小股部队不跟成规模的敌人硬碰硬：附近可见敌军明显多于自己时，先撤回基地 / 己方区划整备。
##
## ★ 只作用于**没有在执行主动进攻任务**的外勤队：`assault_team_ids` 里的队伍是为打硬目标
##   凑出来的，继续执行；扩张任务的队伍如果被压回来，就从任务里摘掉（让别的队继续或重选目标）。
## ★ 阈值分两档：小队（≤ `expand.squad_units`）用较保守的 `expand.avoid_enemy_ratio`，
##   大队用更宽的 1.75 —— 6 个人遇到 7 个敌人不必掉头，3 个人遇到 4 个就该走。
static func _avoid_bad_fights(ai) -> void:
	var ec: Dictionary = ai.profile.get("expand", {})
	var radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var squad_units := _squad_units(ai)
	var min_units := _min_units(ai)
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return
	var rally := _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	for t in field_teams(ai):
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid):
			continue
		var role := _role_of(ai, leader)
		var enemy_now := _enemy_strength_near(ai, leader.pos, radius)
		var ours := float(team_total(ai, leader))
		if ours <= 0.0:
			continue
		var idle_cfg: Dictionary = ai.profile.get("idle", {})
		# ★★ 侦察队：只躲不打。看到「接近或超过自己」的兵力就整队撤，
		#    把情报带回去比换掉几个兵更重要。
		if ai.scout_missions.has(lid) and enemy_now > 0.0:
			var scout_ratio := maxf(0.1, float(idle_cfg.get("scout_avoid_ratio", 0.9)))
			if enemy_now >= ours * scout_ratio:
				_retreat_team(ai, leader)
				ai.expand_team_ids.erase(lid)
				ai.assault_team_ids.erase(lid)
				ai.stats["avoids"] = int(ai.stats.get("avoids", 0)) + 1
				continue
		# ★★ 驻守中的缺编队：站住不动，只有敌人明显更多时才撤。
		#    这一条让「驻守」有意义，同时不拿 1~2 个兵去送。
		if ai.post_missions.has(lid) and ours < float(min_units) and enemy_now > 0.0:
			var post_ratio := maxf(0.1, float(idle_cfg.get("post_avoid_ratio", 1.25)))
			if enemy_now > ours * post_ratio:
				_retreat_team(ai, leader)
				ai.expand_team_ids.erase(lid)
				ai.assault_team_ids.erase(lid)
				ai.stats["avoids"] = int(ai.stats.get("avoids", 0)) + 1
			continue
		if role == "guerrilla" and enemy_now > 0.0:
			var gc: Dictionary = (ai.profile.get("roles", {}) as Dictionary).get("guerrilla", {})
			var ours_g := float(team_total(ai, leader))
			if enemy_now >= ours_g * maxf(0.1, float(gc.get("avoid_ratio", 0.9))):
				_retreat_team(ai, leader)
				ai.expand_team_ids.erase(lid)
				ai.assault_team_ids.erase(lid)
				continue
		if role == "ranged" and enemy_now > 0.0:
			var rc: Dictionary = (ai.profile.get("roles", {}) as Dictionary).get("ranged", {})
			if ai.frontline_count(leader) < int(rc.get("frontline_min", 1)):
				_retreat_team(ai, leader)
				ai.expand_team_ids.erase(lid)
				ai.assault_team_ids.erase(lid)
				continue
		# ★★ 未成形的部队（前线刚招出来的将领、被打残的小队）：遇敌先退，
		#    不要拿一两个人去填线。整队撤回基地补员。
		if ours < float(min_units) and enemy_now > 0.0:
			_retreat_team(ai, leader)
			ai.expand_team_ids.erase(lid)
			ai.assault_team_ids.erase(lid)
			continue
		if ai.assault_team_ids.has(lid):
			continue
		var enemy := _enemy_strength_near(ai, leader.pos, radius)
		if enemy <= 0.0:
			continue
		# 小队（≤ squad_units）：只要敌人**更多**就撤，不赌以少打多；
		# 大队：敌人要明显更多（≥ 1.75×）才撤，避免 6 打 7 也掉头。
		var too_many := false
		if ours <= float(squad_units):
			too_many = enemy > ours
		else:
			too_many = enemy >= ours * maxf(ratio, 1.75)
		if not too_many:
			continue
		# 太危险：如果它在扩张任务里，先从任务里摘掉（别让 `_continue_expand` 又把它压回去）。
		if ai.expand_team_ids.has(lid):
			ai.expand_team_ids.erase(lid)
			if ai.expand_team_ids.is_empty():
				_clear_expand(ai, true)
		ai.regroup_ids[lid] = true
		# 开局探索队只撤不打：用普通移动回基地，不切成行军攻击。
		if _is_early_explorer(ai, lid):
			_retreat_team(ai, leader)
		else:
			_order_team(ai, t, rally, true)
		ai.stats["avoids"] = int(ai.stats.get("avoids", 0)) + 1
		ai.note_status("regroup")


## ★★ 掉到「出门规模以下」的队伍：在自己的领地里就地补员；在领地外 / 无人区就回撤。
##
## 这是「光杆司令到处巡逻」的正面修法：0~2 个兵的队伍不会被任何战略逻辑派出去，
## 已经在外面的会被叫回最近的己方区划中心（路上边撤边招）；已经在己方人口区里的
## 则先停住旧命令、等生产把它补起来。
static func _regroup(ai) -> void:
	var min_units := _min_units(ai)
	var base = ai.world.find_base_of(ai.faction)
	var rally := Vector2.ZERO
	if base != null:
		rally = _clamp_map_point(ai, Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5))
	# ★★ 2026.10.25：守军也一起巡检。常规期守军如果只有 1~2 人却还挂着旧的
	#   行军命令，会一直「走到一半又回家」；这里直接把它的旧命令停掉等补员。
	for t in leader_teams(ai):
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		# 受击即时命令 / 开局探索优先：不要让 `_regroup` 把它再改一次。
		if _react_locked(ai, String(leader.id)) or _is_early_explorer(ai, String(leader.id)):
			continue
		# ★★ 已经接到扩张 / 进攻任务的小队即使掉到 min_units 以下，也交给
		#   `_continue_expand / _continue_assault` 决定（无守军时允许残队占中心）。
		#   否则 `_regroup` 会把它们往基地拉，和扩张命令每帧互相覆盖，
		#   表现就是「在目标与基地之间来回抽搐、永远占不下来」。
		if ai.expand_team_ids.has(String(leader.id)) or ai.assault_team_ids.has(String(leader.id)):
			continue
		if team_total(ai, leader) >= min_units:
			continue
		# ★ 驻守中的缺编队：允许它继续往己方前线中心 / 隘口走，不要每秒被 `_regroup` 叫停。
		#   任务失效（区划丢了 / 点没了）时才落回原来的「就地补员 / 回撤」。
		if ai.post_missions.has(String(leader.id)):
			if _post_still_valid(ai, String(leader.id)):
				continue
			ai.post_missions.erase(String(leader.id))
		var z = ai.world.zones.zone_at(leader.tx, leader.ty)
		var in_own := z != null and FactionRes.same_side_for_attack(
			String((z as Dictionary).get("owner", "")), ai.faction)
		if in_own:
			# 已经在己方区划里、而且这块地有人口 ⇒ 就地补员（生产会选到它）。
			# ★ 但它可能还挂着上一条「去打某个点」的旧命令：那会让它一边缺兵一边往前冲。
			#   先停住（走命令层，不直接改字段），再让生产把它补起来。
			if float((z as Dictionary).get("population", 0.0)) >= 1.0:
				if leader.has_attack_move or leader.moving or leader.target != null:
					_stop_team(ai, leader)
				continue
		if base == null:
			continue
		ai.regroup_ids[String(leader.id)] = true
		_order_team(ai, t, rally, true)
		ai.stats["regroups"] = int(ai.stats.get("regroups", 0)) + 1
		ai.note_status("regroup")


## ★★ 2026.10.25：缺兵但**不在己方人口区 / 在野外**的队伍，回最近的人口区补员。
##
## 这是「资源很富足却不补兵」的直接修法：招募只能在**己方区划**里下单，
## 将领跑到中立 / 敌方区划后，钱再多也下不了单。这里把「还没补到目标规模」
## 的外勤队叫回最近的有人口己方区划；已经在己方人口区的队伍不折腾。
##
## ★ 不抢正在打硬目标 / 扩张的队伍：那两种任务有自己的节奏，打一半拉回来会白送。
## ★ 用 `regroup_ids` 标记，巡逻 / 侦察 / 守备 / 出征都会跳过它。
static func _recall_understrength_for_recruit(ai) -> void:
	# 开局扩张期：小队伍正在外面探索 / 占区划，不要按常规「没补满就回城」把她们拽回来。
	if is_early_game(ai):
		return
	var pc: Dictionary = ai.profile.get("production", {})
	var field_size := maxi(1, _i(pc, "field_team_size", 6))
	var max_recalls := maxi(1, _i(pc, "max_recruit_recalls", 2))
	var probe_kind := _probe_recruit_kind(ai)
	if probe_kind == "":
		return
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return
	var recalled := 0
	for t in field_teams(ai):
		if recalled >= max_recalls:
			break
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		if ai.regroup_ids.has(lid):
			continue
		if leader.target != null or leader.target_building != null:
			continue
		var z = ai.world.zones.zone_at(leader.tx, leader.ty)
		var in_own := z != null and FactionRes.same_side_for_attack(
			String((z as Dictionary).get("owner", "")), ai.faction)
		if team_projected(ai, leader) >= field_size:
			continue
		var pop_cost := maxf(0.0, ai.world.recruit_population_cost(probe_kind))
		# 已经在己方人口区：生产会选到它，不要来回跑。
		if in_own and float((z as Dictionary).get("population", 0.0)) >= pop_cost:
			continue
		var reason := String(ai.world.can_recruit(probe_kind, lid, ai.faction))
		if reason == "cap" or reason == "queue_full" or reason == "kind" \
				or reason == "tier" or reason == "leader" or reason == "faction":
			continue
		var dest: Variant = _recruit_destination(ai, leader, pop_cost)
		if dest == null:
			continue
		var pt: Vector2 = (dest as Dictionary).get("pt", leader.pos)
		if leader.pos.distance_to(pt) <= 2.0:
			continue
		# 回撤补员优先于侦察 / 驻守 / 守备：这些任务先让位。
		ai.scout_missions.erase(lid)
		ai.post_missions.erase(lid)
		ai.guard_missions.erase(lid)
		ai.regroup_ids[lid] = true
		if _move_team(ai, t, pt):
			ai.stats["recruit_recalls"] = int(ai.stats.get("recruit_recalls", 0)) + 1
			ai.note_status("regroup")
			recalled += 1


## 最近的有人口的己方区划中心；没有人口区时退回大本营。
static func _recruit_destination(ai, leader, pop_cost: float) -> Variant:
	var base = ai.world.find_base_of(ai.faction)
	var ec: Dictionary = ai.profile.get("expand", {})
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var best: Variant = null
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		if float(zd.get("population", 0.0)) < pop_cost:
			continue
		var ct: Vector2i = cv
		var pt := GridRes.center_of(ct)
		var score := 0.0
		if base != null and int(zd.get("id", -1)) == int(base.zone_id):
			score += 100.0
		score -= leader.pos.distance_to(pt) * 0.3
		if _zone_capture_threatened(ai, zd):
			score -= 80.0
		score -= _enemy_strength_near(ai, pt, threat_radius) * 8.0
		if score > best_score + 1e-6:
			best_score = score
			best = {"pt": pt, "zone": int(zd.get("id", -1))}
	if best != null:
		return best
	if base != null:
		return {"pt": GridRes.center_of(Vector2i(int(base.tx), int(base.ty))),
			"zone": int(base.zone_id)}
	return null


## 让一支队伍**停住**（清掉路径 / 玩家命令 / 交战目标），走命令层。
## 用于「兵力掉到出门规模以下、又已经在己方区划里」的队伍：先停手，等补员。
static func _stop_team(ai, leader) -> void:
	if leader == null or not leader.alive:
		return
	var ids: Array = [String(leader.id)]
	for m in ai.world.retinue_of(String(leader.id), true):
		ids.append(String(m.id))
	CommandProcessorRes.apply(ai.world, ai.cfg, {
		"kind": "stop", "ids": ids, "faction": ai.faction,
	})
	ai.last_orders.erase(String(leader.id))
	ai.regroup_ids[String(leader.id)] = true
	ai.post_missions.erase(String(leader.id))
	ai.guard_missions.erase(String(leader.id))


## 某个点周围看得见的敌对**兵力估值**（将领算 2，普通兵算 1）。
## ★ 用「可见」而不是全图：公平视野；看不见的大部队不该被 AI 开天眼躲开。
static func _enemy_strength_near(ai, pt: Vector2, radius: float) -> float:
	var n := 0.0
	var r2 := maxf(0.0, radius) * maxf(0.0, radius)
	for u in ai.world.units:
		if not u.alive or u.is_downed():
			continue
		if FactionRes.same_side_for_attack(String(u.faction), ai.faction):
			continue
		if ai.world.fog != null and not ai.world.fog.logic_unit_visible(ai.faction, u):
			continue
		if u.pos.distance_squared_to(pt) <= r2:
			n += 2.0 if u.is_general() else 1.0
	return n


## 这个巡逻 / 行军点对「我方这么多人的队伍」是不是**太危险**（敌人成规模）。
static func _point_too_dangerous(ai, pt: Vector2, our_strength: float,
		radius: float, avoid_ratio: float) -> bool:
	if our_strength <= 0.0:
		return true
	var enemy := _enemy_strength_near(ai, pt, radius)
	return enemy > 0.0 and enemy >= our_strength * maxf(0.1, avoid_ratio)


## ★★ 巡逻：只派「已经能出门」的外勤队，优先派**最久没动**的那几支。
##
## 旧版按 `patrol_index` 盲轮换，且一次只派一支 —— 10 支队伍时每支要等 90 秒才动一下，
## 观感就是「一堆队伍站在刚打下来的区划中心不动」。现在：
##   · 一次最多派 `patrol.max_teams` 支（默认 2）；
##   · 选队按「上次命令时间」从旧到新排（从没动过的优先）；
##   · 巡逻点从 `patrol_index` 往后找第一个离它 **≥ 4 格**、且不会让小队撞上
##     成规模敌军的点（`patrol.threat_radius` / `patrol.avoid_enemy_ratio`）。
##   · ★ 正在读条的将领**照常可以巡逻**：这里不看 `is_training()`。
##     只有守军一支队伍时，允许它在基地附近巡逻（`patrol.home_when_alone`），
##     但基地周围已经有敌人时不允许（先守家）。
static func _patrol(ai) -> void:
	var pc: Dictionary = ai.profile.get("patrol", {})
	if not bool(pc.get("enabled", true)):
		return
	if ai.world.time < ai.patrol_next_at:
		return
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var threat_radius := maxf(0.0, float(pc.get("threat_radius", 7.0)))
	var avoid_ratio := maxf(0.1, float(pc.get("avoid_enemy_ratio", 1.25)))
	var squad_units := _squad_units(ai)
	var ts: Array = []
	for t in ready_field_teams(ai, min_units):
		var leader = t["leader"]
		var lid := String((leader as Object).id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		# 已接侦察 / 驻守任务的队伍不参与普通巡逻（否则会被巡逻点拉走）。
		if ai.scout_missions.has(lid) or ai.post_missions.has(lid) \
				or ai.guard_missions.has(lid) or ai.regroup_ids.has(lid):
			continue
		ts.append(t)
	# ★ 只有守军一支队伍时：允许它（读条中 / 空闲）去基地附近巡逻，
	#   但基地附近已经有敌人时不允许 —— 守家优先。
	var home_only := false
	if ts.is_empty() and bool(pc.get("home_when_alone", true)):
		var home = ensure_garrison(ai)
		var base = ai.world.find_base_of(ai.faction)
		if home != null and base != null and team_total(ai, home) >= min_units \
				and not _is_early_explorer(ai, String(home.id)):
			var base_pt := Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5)
			if _enemy_strength_near(ai, base_pt, threat_radius) <= 0.0:
				ts.append({"leader": home, "units": ai.world.group_of(home)})
				home_only = true
	if ts.is_empty():
		ai.patrol_next_at = ai.world.time + 2.0
		return
	var pts := _patrol_points(ai)
	if pts.is_empty():
		return
	# 只有守军时只在基地环上巡逻，不把它派到远处的区划中心。
	if home_only and pts.size() > 4:
		pts = pts.slice(0, 4)
	# 最久没下过命令的队伍优先（没有记录的当作最旧）。
	ts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la = a["leader"]
		var lb = b["leader"]
		var ta: float = float((ai.last_orders.get(String((la as Object).id), {}) as Dictionary).get("t", -INF))
		var tb: float = float((ai.last_orders.get(String((lb as Object).id), {}) as Dictionary).get("t", -INF))
		if absf(ta - tb) > 1e-6:
			return ta < tb
		return String((la as Object).id) < String((lb as Object).id))
	var max_teams := maxi(1, _i(pc, "max_teams", 2))
	var sent := 0
	var tried := 0
	while sent < max_teams and tried < ts.size() * 2 and tried < 32:
		var team: Dictionary = ts[tried % ts.size()]
		tried += 1
		var leader = team["leader"]
		var ours := float(team_total(ai, leader))
		var team_ratio := avoid_ratio if ours <= float(squad_units) else maxf(avoid_ratio, 1.75)
		var pick: Variant = _pick_patrol_point(ai, leader.pos, pts, ai.patrol_index,
			ours, threat_radius, team_ratio)
		if pick == null:
			continue
		var pd: Dictionary = pick
		ai.patrol_index = (int(pd.get("index", 0)) + 1) % pts.size()
		var pt: Vector2 = pd.get("point", leader.pos)
		if _order_team(ai, team, pt, true):
			sent += 1
	if sent > 0:
		ai.patrol_next_at = ai.world.time + maxf(2.0, float(pc.get("interval_sec", 5.0)))
		ai.note_status("patrol")
	else:
		# 都在巡逻点上 / 都被去重拦住了 / 都太危险：过两秒再看，别卡死在同一次调用里。
		ai.patrol_next_at = ai.world.time + 2.0


## 从 pts[index] 起找一个离 `from` 至少 4 格、且**不会撞上成规模敌军**的点。
static func _pick_patrol_point(ai, from: Vector2, pts: Array, start_index: int,
		our_strength: float, threat_radius: float, avoid_ratio: float) -> Variant:
	var n := pts.size()
	for k in n:
		var idx := (start_index + k) % n
		var pt: Vector2 = pts[idx]
		if from.distance_to(pt) < 4.0:
			continue
		if _point_too_dangerous(ai, pt, our_strength, threat_radius, avoid_ratio):
			continue
		return {"point": pt, "index": idx}
	return null


static func _patrol_points(ai) -> Array:
	var pts: Array = []
	# ★★ 2026.10.25：不再把「基地外围四个点」放进普通巡逻。
	#   那四个点只在基地门口，队伍会在左上右下之间反复进出大本营区划，
	#   看起来没有任何战略目的。巡逻只走己方各区划中心（含前线）；
	#   只有大本营一个区划时，中心就是基地格，队伍不会来回绕圈。
	for z in ai.world.zones.zones:
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		var c: Variant = zd.get("center", null)
		if c == null:
			continue
		var ct: Vector2i = c
		pts.append(_clamp_map_point(ai, Vector2(float(ct.x) + 1.5, float(ct.y) + 1.5)))
	return pts


# ------------------------------------------------------------------
# ★★ 2026.10.25：闲置部队调度 —— 缺编队驻守 / 满编队侦察
# ------------------------------------------------------------------

## 缺编队的防守驻守：只占己方前线区划中心 / 隘口，不出境侦察。
##
## ★ 只处理「低于 min_field_units、但至少有 `min_escorts_to_post` 个兵」的队伍：
##   光杆司令仍然留在后方补员（用户口径：至少 1 个兵的底线）。
## ★ 驻守是**持续任务**，不是一次巡逻：`_regroup()` 会跳过有效的驻守任务，
##   只有区划丢了 / 敌人明显更多 / 到了重新评估时间才会解除。
static func _assign_defensive_posts(ai) -> void:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	if not bool(idle_cfg.get("enabled", true)) \
			or not bool(idle_cfg.get("guard_enabled", true)):
		return
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var min_escorts := maxi(0, _i(idle_cfg, "min_escorts_to_post", 1))
	var max_posts := maxi(1, _i(idle_cfg, "max_posts", 4))
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var post_ratio := maxf(0.1, float(idle_cfg.get("post_avoid_ratio", 1.25)))
	# 1) 校验已有任务：队伍补满了 / 区划丢了 / 敌人太多 → 解除。
	for lid in ai.post_missions.keys().duplicate():
		var u = ai.world.unit_by_id(String(lid))
		if u == null or not u.alive or u.is_downed():
			ai.post_missions.erase(lid)
			continue
		if team_total(ai, u) >= min_units:
			ai.post_missions.erase(lid)
			continue
		# 掉编到缺编：如果之前是满编守备任务，转成缺编驻守。
		ai.guard_missions.erase(String(lid))
		if not _post_still_valid(ai, String(lid)):
			ai.post_missions.erase(lid)
			continue
		var ours := float(team_total(ai, u))
		var enemy := _enemy_strength_near(ai, u.pos, threat_radius)
		if enemy > 0.0 and enemy > ours * post_ratio:
			ai.post_missions.erase(lid)
	# 2) 给还没任务的缺编队找岗位。
	var count: int = ai.post_missions.size()
	if count >= max_posts:
		return
	for t in field_teams(ai):
		if count >= max_posts:
			break
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if ai.post_missions.has(lid):
			continue
		if team_total(ai, leader) >= min_units:
			continue
		# 从满编掉成缺编：撤掉满编守备任务，改走缺编驻守。
		ai.guard_missions.erase(lid)
		if team_escorts(ai, leader) < min_escorts:
			continue
		if ai.regroup_ids.has(lid):
			continue
		if leader.target != null or leader.target_building != null:
			continue
		var pick: Variant = _pick_defensive_post(ai, leader)
		if pick == null:
			continue
		var pd: Dictionary = pick
		var pt: Vector2 = pd.get("pt", leader.pos)
		ai.post_missions[lid] = {
			"pt": pt,
			"zone": int(pd.get("zone", -1)),
			"kind": String(pd.get("kind", "center")),
			"reassess_at": ai.world.time \
				+ maxf(4.0, float(idle_cfg.get("post_reassess_sec", 20.0))),
		}
		if leader.pos.distance_to(pt) <= 1.75:
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
			continue
		if _order_team(ai, t, pt, true, true):
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
		else:
			# 走不过去：先撤掉任务，下一轮再找别的点。
			ai.post_missions.erase(lid)


## 驻守任务是否还有效（区划仍归己方、点还在图内、没到重新评估时间）。
static func _post_still_valid(ai, lid: String) -> bool:
	var mv: Variant = ai.post_missions.get(lid, null)
	if typeof(mv) != TYPE_DICTIONARY:
		return false
	var m: Dictionary = mv
	if ai.world.time >= float(m.get("reassess_at", INF)):
		return false
	var zid := int(m.get("zone", -1))
	var z = ai.world.zone_by_id(zid)
	if z == null:
		return false
	if String((z as Dictionary).get("owner", "")) != ai.faction:
		return false
	var pt: Vector2 = m.get("pt", Vector2.ZERO)
	if not ai.world.map.tile_exists(int(floor(pt.x)), int(floor(pt.y))):
		return false
	return true


## 给一支缺编队挑驻守点：受威胁区划中心 > 前线区划中心 > 前线隘口。
static func _pick_defensive_post(ai, leader) -> Variant:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	var ec: Dictionary = ai.profile.get("expand", {})
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var guard_radius := maxf(0.5, float(idle_cfg.get("guard_radius_tiles", 2.5)))
	var post_ratio := maxf(0.1, float(idle_cfg.get("post_avoid_ratio", 1.25)))
	var ours := float(team_total(ai, leader))
	var best: Variant = null
	var best_score := -INF
	var best_id := 1 << 30
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		var zid := int(zd.get("id", -1))
		var threatened := _zone_capture_threatened(ai, zd)
		var frontier := _zone_is_frontier_local(ai, zd)
		if not threatened and not frontier:
			continue
		var cv: Vector2i = zd["center"]
		var pt := GridRes.center_of(cv)
		var enemy := _enemy_strength_near(ai, pt, threat_radius)
		if enemy > 0.0 and enemy > ours * post_ratio:
			continue
		if _friendly_near(ai, pt, guard_radius, String(leader.id)):
			continue
		if _post_near(ai, pt, guard_radius):
			continue
		var score := 40.0
		if threatened:
			score += 100.0
		if _zone_has_enemy_neighbor(ai, zd):
			score += 25.0
		score -= leader.pos.distance_to(pt) * 0.2
		if score > best_score + 1e-6 \
				or (absf(score - best_score) <= 1e-6 and zid < best_id):
			best_score = score
			best_id = zid
			best = {"pt": pt, "zone": zid, "kind": "center"}
	# 中心都有人了：改守前线隘口（可通行邻格很少的边境格）。
	if bool(idle_cfg.get("choke_enabled", true)):
		for z2 in ai.world.zones.zones:
			if typeof(z2) != TYPE_DICTIONARY:
				continue
			var zd2: Dictionary = z2
			if String(zd2.get("owner", "")) != ai.faction:
				continue
			if not _zone_is_frontier_local(ai, zd2):
				continue
			var zid2 := int(zd2.get("id", -1))
			for t in _frontier_choke_tiles(ai, zd2):
				var tv: Vector2i = t
				var pt2 := GridRes.center_of(tv)
				var enemy2 := _enemy_strength_near(ai, pt2, threat_radius)
				if enemy2 > 0.0 and enemy2 > ours * post_ratio:
					continue
				if _friendly_near(ai, pt2, guard_radius, String(leader.id)):
					continue
				if _post_near(ai, pt2, guard_radius):
					continue
				var score2 := 30.0
				if _zone_capture_threatened(ai, zd2):
					score2 += 60.0
				if _zone_has_enemy_neighbor(ai, zd2):
					score2 += 20.0
				score2 -= leader.pos.distance_to(pt2) * 0.2
				if score2 > best_score + 1e-6 \
						or (absf(score2 - best_score) <= 1e-6 and zid2 < best_id):
					best_score = score2
					best_id = zid2
					best = {"pt": pt2, "zone": zid2, "kind": "choke"}
	return best


## 满编队的防守驻守：侦察名额满了 / 目标太危险时，别让队伍在后方站着，
## 去自家前线区划中心 / 隘口当哨兵（不主动出境）。
static func _assign_ready_guards(ai) -> void:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	if not bool(idle_cfg.get("enabled", true)) \
			or not bool(idle_cfg.get("guard_enabled", true)):
		return
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var max_guards := maxi(0, _i(idle_cfg, "max_ready_guards", 3))
	if max_guards <= 0:
		return
	# 开局扩张期先向外探索 / 占区划，不把队伍铺去守备。
	var eg: Dictionary = ai.profile.get("early_game", {})
	if is_early_game(ai) and bool(eg.get("disable_guards", true)):
		return
	var home = ensure_garrison(ai)
	# 1) 校验已有守备任务。
	for lid in ai.guard_missions.keys().duplicate():
		var u = ai.world.unit_by_id(String(lid))
		if u == null or not u.alive or u.is_downed():
			ai.guard_missions.erase(lid)
			continue
		if home != null and u == home:
			ai.guard_missions.erase(lid)
			continue
		# 玩家直接接管了这支队伍：撤掉 AI 守备任务，别和玩家抢方向盘。
		if u.has_method("has_active_player_order") and u.has_active_player_order():
			ai.guard_missions.erase(lid)
			continue
		if ai.expand_team_ids.has(String(lid)) or ai.assault_team_ids.has(String(lid)) \
				or ai.scout_missions.has(String(lid)) or ai.post_missions.has(String(lid)) \
				or ai.regroup_ids.has(String(lid)):
			ai.guard_missions.erase(lid)
			continue
		if team_total(ai, u) < min_units:
			ai.guard_missions.erase(lid)
			continue
		if not _guard_still_valid(ai, String(lid)):
			ai.guard_missions.erase(lid)
	# 2) 给「没有任何移动 / 攻击任务」的满编队找岗位。
	# ★ 只数「前线守备」；`kind == "zone"` 是区划布防，走单独的 `max_zone_guards`。
	var count := 0
	for lid in ai.guard_missions.keys():
		var mv: Variant = ai.guard_missions.get(lid, null)
		if typeof(mv) == TYPE_DICTIONARY \
				and String((mv as Dictionary).get("kind", "")) != "zone":
			count += 1
	if count >= max_guards:
		return
	for t in ready_field_teams(ai, min_units):
		if count >= max_guards:
			break
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if home != null and leader == home:
			continue
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		if ai.guard_missions.has(lid) or ai.scout_missions.has(lid) \
				or ai.post_missions.has(lid) or ai.regroup_ids.has(lid):
			continue
		# ★ 玩家直接命令优先；普通巡逻 / 旧移动命令可以被守备预占（force 重发）。
		if leader.has_method("has_active_player_order") and leader.has_active_player_order():
			continue
		if leader.target != null or leader.target_building != null:
			continue
		var pick: Variant = _pick_defensive_post(ai, leader)
		if pick == null:
			continue
		var pd: Dictionary = pick
		var pt: Vector2 = pd.get("pt", leader.pos)
		ai.guard_missions[lid] = {
			"pt": pt,
			"zone": int(pd.get("zone", -1)),
			"kind": String(pd.get("kind", "center")),
			"reassess_at": ai.world.time \
				+ maxf(4.0, float(idle_cfg.get("post_reassess_sec", 20.0))),
		}
		if leader.pos.distance_to(pt) <= 1.75:
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
			continue
		if _order_team(ai, t, pt, true, true):
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
		else:
			ai.guard_missions.erase(lid)


## ★★ 2026.10.25：区划布防 —— 把闲置满编队铺到**可能被偷袭**的己方区划。
##
## 与 `_assign_ready_guards()` 的分工：
##   · 前者只守「当前前线 / 受威胁区划」的中心 / 隘口；
##   · 这里补的是「边境 / 侧翼但暂时没敌人」的区划 —— 每个区划最多一队，
##     不让所有队伍都挤在大本营、中场或同一个前线中心。
##
## 任务写进 `guard_missions`，`kind = "zone"`，走单独的 `max_zone_guards` 名额；
## 前线守备仍按 `max_ready_guards` 计数，互不挤占。
static func _assign_zone_guards(ai) -> void:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	if not bool(idle_cfg.get("enabled", true)) \
			or not bool(idle_cfg.get("guard_enabled", true)) \
			or not bool(idle_cfg.get("zone_guard_enabled", true)):
		return
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var max_zone := maxi(0, _i(idle_cfg, "max_zone_guards", 4))
	if max_zone <= 0:
		return
	var eg: Dictionary = ai.profile.get("early_game", {})
	if is_early_game(ai) and bool(eg.get("disable_guards", true)):
		return
	var radius := maxf(0.5, float(idle_cfg.get("zone_guard_radius_tiles", 3.0)))
	var avoid_ratio := maxf(0.1, float(idle_cfg.get("zone_guard_avoid_ratio", 1.35)))
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var home = ensure_garrison(ai)
	# 1) 校验已有区划布防任务。
	var count := 0
	for lid in ai.guard_missions.keys().duplicate():
		var mv: Variant = ai.guard_missions.get(lid, null)
		if typeof(mv) != TYPE_DICTIONARY:
			ai.guard_missions.erase(lid)
			continue
		var m: Dictionary = mv
		if String(m.get("kind", "")) != "zone":
			continue
		var u = ai.world.unit_by_id(String(lid))
		if u == null or not u.alive or u.is_downed() or team_total(ai, u) < min_units:
			ai.guard_missions.erase(lid)
			continue
		if home != null and u == home:
			ai.guard_missions.erase(lid)
			continue
		# 玩家直接接管了这支队伍：撤掉 AI 区划布防任务。
		if u.has_method("has_active_player_order") and u.has_active_player_order():
			ai.guard_missions.erase(lid)
			continue
		if ai.expand_team_ids.has(String(lid)) or ai.assault_team_ids.has(String(lid)) \
				or ai.scout_missions.has(String(lid)) or ai.post_missions.has(String(lid)) \
				or ai.regroup_ids.has(String(lid)):
			ai.guard_missions.erase(lid)
			continue
		if not _guard_still_valid(ai, String(lid)):
			ai.guard_missions.erase(lid)
			continue
		var ours := float(team_total(ai, u))
		var enemy := _enemy_strength_near(ai, u.pos, threat_radius)
		if enemy > 0.0 and enemy > ours * avoid_ratio:
			ai.guard_missions.erase(lid)
			continue
		count += 1
	if count >= max_zone:
		return
	# 2) 给闲置满编队找「没被覆盖的暴露区划」。
	for t in ready_field_teams(ai, min_units):
		if count >= max_zone:
			break
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if home != null and leader == home:
			continue
		if ai.guard_missions.has(lid) or ai.scout_missions.has(lid) \
				or ai.post_missions.has(lid) or ai.regroup_ids.has(lid):
			continue
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		# ★ 玩家直接命令优先；普通巡逻 / 旧移动命令可以被区划布防预占。
		if leader.has_method("has_active_player_order") and leader.has_active_player_order():
			continue
		if leader.target != null or leader.target_building != null:
			continue
		var pick: Variant = _pick_zone_guard(ai, leader, radius, avoid_ratio, threat_radius)
		if pick == null:
			continue
		var pd: Dictionary = pick
		var pt: Vector2 = pd.get("pt", leader.pos)
		ai.guard_missions[lid] = {
			"pt": pt,
			"zone": int(pd.get("zone", -1)),
			"kind": "zone",
			"reassess_at": ai.world.time \
				+ maxf(5.0, float(idle_cfg.get("zone_guard_reassess_sec", 25.0))),
		}
		if leader.pos.distance_to(pt) <= 1.75:
			ai.stats["zone_guards"] = int(ai.stats.get("zone_guards", 0)) + 1
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
			continue
		if _order_team(ai, t, pt, true, true):
			ai.stats["zone_guards"] = int(ai.stats.get("zone_guards", 0)) + 1
			ai.stats["guards"] = int(ai.stats.get("guards", 0)) + 1
			ai.note_status("guarding")
			count += 1
		else:
			ai.guard_missions.erase(lid)


## 挑一个「可能被偷袭、且附近没有己方队伍」的己方区划中心。
static func _pick_zone_guard(ai, leader, radius: float, avoid_ratio: float,
		threat_radius: float) -> Variant:
	var base = ai.world.find_base_of(ai.faction)
	var ours := float(team_total(ai, leader))
	var best: Variant = null
	var best_score := -INF
	var best_id := 1 << 30
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		var zid := int(zd.get("id", -1))
		# 大本营区划由守军负责，不占区划布防名额。
		if base != null and zid == int(base.zone_id):
			continue
		var captured := _zone_capture_threatened(ai, zd)
		var enemy_neighbor := _zone_has_enemy_neighbor(ai, zd)
		var frontier := _zone_is_frontier_local(ai, zd)
		if not captured and not enemy_neighbor and not frontier:
			continue
		var ct: Vector2i = cv
		var pt := GridRes.center_of(ct)
		var enemy := _enemy_strength_near(ai, pt, threat_radius)
		if enemy > 0.0 and enemy > ours * avoid_ratio:
			continue
		if _friendly_near(ai, pt, radius, String(leader.id)):
			continue          # 这个区划已经有队伍了：一区一队
		if _post_near(ai, pt, radius):
			continue
		var score := 0.0
		if captured:
			score += 120.0
		if enemy_neighbor:
			score += 70.0
		if frontier:
			score += 35.0
		score += enemy * 8.0
		score -= leader.pos.distance_to(pt) * 0.25
		if score > best_score + 1e-6 \
				or (absf(score - best_score) <= 1e-6 and zid < best_id):
			best_score = score
			best_id = zid
			best = {"pt": pt, "zone": zid, "kind": "zone"}
	return best


static func _guard_still_valid(ai, lid: String) -> bool:
	var mv: Variant = ai.guard_missions.get(lid, null)
	if typeof(mv) != TYPE_DICTIONARY:
		return false
	var m: Dictionary = mv
	if ai.world.time >= float(m.get("reassess_at", INF)):
		return false
	var zid := int(m.get("zone", -1))
	var z = ai.world.zone_by_id(zid)
	if z == null:
		return false
	if String((z as Dictionary).get("owner", "")) != ai.faction:
		return false
	var pt: Vector2 = m.get("pt", Vector2.ZERO)
	if not ai.world.map.tile_exists(int(floor(pt.x)), int(floor(pt.y))):
		return false
	return true


## 区划中心是不是正被敌方读条（只读公开的区划状态）。
static func _zone_capture_threatened(ai, zd: Dictionary) -> bool:
	if ai.world.zones == null:
		return false
	var bar: Dictionary = ai.world.zones.capture_bar(zd)
	var st := String(bar.get("state", ""))
	if st != "reading" and st != "frozen":
		return false
	var f := String(bar.get("faction", ""))
	return f != "" and not FactionRes.same_side_for_attack(f, ai.faction)


static func _zone_is_frontier_local(ai, zone: Dictionary) -> bool:
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var owner := String((oz as Dictionary).get("owner", ""))
			if owner == "" or not FactionRes.same_side_for_attack(owner, ai.faction):
				return true
	return false


static func _zone_has_enemy_neighbor(ai, zone: Dictionary) -> bool:
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var owner := String((oz as Dictionary).get("owner", ""))
			if owner != "" and not FactionRes.same_side_for_attack(owner, ai.faction):
				return true
	return false


## 前线隘口：贴着非己方地块、且周围可通行格很少的己方格。
static func _frontier_choke_tiles(ai, zone: Dictionary) -> Array:
	var out: Array = []
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	var threshold := maxi(1, _i(idle_cfg, "choke_max_passable_neighbors", 3))
	var zid := int(zone.get("id", -1))
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		if not ai.world.map.terrain_walkable(tv.x, tv.y):
			continue
		if ai.world.building_at(tv.x, tv.y) != null:
			continue
		var outside := false
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			if not ai.world.map.tile_exists(n.x, n.y):
				continue
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var od: Dictionary = oz
			if int(od.get("id", -1)) == zid:
				continue
			var owner := String(od.get("owner", ""))
			if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
				continue
			if ai.world.map.terrain_walkable(n.x, n.y):
				outside = true
		if not outside:
			continue
		var passable := 0
		for d2 in GridRes.DIRS8:
			var n2: Vector2i = tv + d2
			if ai.world.map.tile_exists(n2.x, n2.y) \
					and ai.world.map.terrain_walkable(n2.x, n2.y):
				passable += 1
		if passable <= threshold:
			out.append(tv)
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y != b.y:
			return a.y < b.y
		return a.x < b.x)
	return out


static func _friendly_near(ai, pt: Vector2, radius: float, except_id: String) -> bool:
	var r2 := maxf(0.0, radius) * maxf(0.0, radius)
	for u in ai.world.units:
		if u == null or not u.alive or u.is_downed():
			continue
		if String(u.id) == except_id:
			continue
		# 同一支队的附属兵也算「自己」，不能因为护卫站在旁边就判定中心已经有人守。
		if except_id != "" and String(u.leader_id) == except_id:
			continue
		if not FactionRes.same_side_for_attack(String(u.faction), ai.faction):
			continue
		if u.pos.distance_squared_to(pt) <= r2:
			return true
	return false


static func _post_near(ai, pt: Vector2, radius: float) -> bool:
	for dict in [ai.post_missions, ai.guard_missions]:
		for mv in (dict as Dictionary).values():
			if typeof(mv) != TYPE_DICTIONARY:
				continue
			var m: Dictionary = mv
			var p: Vector2 = m.get("pt", Vector2.ZERO)
			if p.distance_to(pt) <= radius:
				return true
	return false


## 满编队的侦察：去敌方 / 中立边界外侧找敌军和建筑；看到接近自己规模的
## 敌军就整队撤。顺路发现没有守军的空区划时，会去中心读条占领。
static func _scout_tick(ai) -> void:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	if not bool(idle_cfg.get("enabled", true)) \
			or not bool(idle_cfg.get("scout_enabled", true)):
		return
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var max_scouts := maxi(1, _i(idle_cfg, "max_scouts", 2))
	var hold_sec := maxf(0.5, float(idle_cfg.get("scout_hold_sec", 6.0)))
	var reassign_sec := maxf(hold_sec, float(idle_cfg.get("scout_reassign_sec", 16.0)))
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var scout_ratio := maxf(0.1, float(idle_cfg.get("scout_avoid_ratio", 0.9)))
	var home = ensure_garrison(ai)
	# 1) 校验已有侦察任务。
	for lid in ai.scout_missions.keys().duplicate():
		var u = ai.world.unit_by_id(String(lid))
		if u == null or not u.alive or u.is_downed():
			ai.scout_missions.erase(lid)
			continue
		if home != null and u == home:
			ai.scout_missions.erase(lid)
			continue
		if ai.expand_team_ids.has(String(lid)) or ai.assault_team_ids.has(String(lid)) \
				or ai.post_missions.has(String(lid)) or ai.guard_missions.has(String(lid)) \
				or ai.regroup_ids.has(String(lid)):
			ai.scout_missions.erase(lid)
			continue
		if team_total(ai, u) < min_units:
			ai.scout_missions.erase(lid)
			continue
		var mv: Variant = ai.scout_missions.get(lid, null)
		if typeof(mv) != TYPE_DICTIONARY:
			ai.scout_missions.erase(lid)
			continue
		var m: Dictionary = mv
		var zid := int(m.get("zone", -1))
		var z = ai.world.zone_by_id(zid)
		if z == null:
			ai.scout_missions.erase(lid)
			continue
		var owner := String((z as Dictionary).get("owner", ""))
		if bool(m.get("capture", false)) \
				and FactionRes.same_side_for_attack(owner, ai.faction):
			ai.scout_missions.erase(lid)       # 空区划已经拿下了
			continue
		var pt: Vector2 = m.get("pt", u.pos)
		var ours := float(team_total(ai, u))
		var enemy := _enemy_strength_near(ai, u.pos, threat_radius)
		if enemy > 0.0 and enemy >= ours * scout_ratio:
			_retreat_team(ai, u)
			ai.stats["avoids"] = int(ai.stats.get("avoids", 0)) + 1
			continue
		if u.pos.distance_to(pt) <= 1.75:
			var hold_until := float(m.get("hold_until", 0.0))
			if hold_until <= 0.0:
				m["hold_until"] = ai.world.time + hold_sec
			elif ai.world.time >= hold_until:
				ai.scout_missions.erase(lid)
			continue
		if ai.world.time - float(m.get("started_at", ai.world.time)) >= reassign_sec:
			ai.scout_missions.erase(lid)
	# 2) 给还没任务的满编队派侦察。
	var count: int = ai.scout_missions.size()
	if count >= max_scouts:
		return
	var teams: Array = []
	for t in ready_field_teams(ai, min_units):
		var leader = t["leader"]
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid) \
				or _is_capturing_cleared_zone(ai, leader):
			continue
		if home != null and leader == home:
			continue
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		if ai.scout_missions.has(lid) or ai.post_missions.has(lid) \
				or ai.guard_missions.has(lid) or ai.regroup_ids.has(lid):
			continue
		if leader.target != null or leader.target_building != null:
			continue
		teams.append(t)
	teams.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la = a["leader"]
		var lb = b["leader"]
		var ra := _scout_role_rank(ai, la)
		var rb := _scout_role_rank(ai, lb)
		if ra != rb:
			return ra < rb
		var ta: float = float((ai.last_orders.get(String((la as Object).id), {}) as Dictionary).get("t", -INF))
		var tb: float = float((ai.last_orders.get(String((lb as Object).id), {}) as Dictionary).get("t", -INF))
		if absf(ta - tb) > 1e-6:
			return ta < tb
		return String((la as Object).id) < String((lb as Object).id))
	for t2 in teams:
		if count >= max_scouts:
			break
		var leader2 = t2["leader"]
		var lid2 := String(leader2.id)
		var pick: Variant = _pick_scout_target(ai, leader2)
		if pick == null:
			continue
		var pd: Dictionary = pick
		var pt2: Vector2 = pd.get("pt", leader2.pos)
		if _order_team(ai, t2, pt2, true, true):
			ai.scout_missions[lid2] = {
				"pt": pt2,
				"zone": int(pd.get("zone", -1)),
				"capture": bool(pd.get("capture", false)),
				"started_at": ai.world.time,
				"hold_until": 0.0,
			}
			ai.stats["scouts"] = int(ai.stats.get("scouts", 0)) + 1
			ai.note_status("scouting")
			count += 1


## 侦察选队的偏好：游击队（骑手 / 马弓）> 远程（马弓）> 正面队。
static func _scout_role_rank(ai, leader) -> int:
	match _role_of(ai, leader):
		"guerrilla":
			return 0
		"ranged":
			return 1
		_:
			return 2


## 给侦察队挑一个边界外侧的点。空区划（无守军）优先，其次敌方区划的外沿。
static func _pick_scout_target(ai, leader) -> Variant:
	var idle_cfg: Dictionary = ai.profile.get("idle", {})
	var ec: Dictionary = ai.profile.get("expand", {})
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var scout_ratio := maxf(0.1, float(idle_cfg.get("scout_avoid_ratio", 0.9)))
	var max_dist := maxf(4.0, float(idle_cfg.get("scout_max_distance_tiles", 18.0)))
	var capture_empty := bool(idle_cfg.get("scout_capture_empty", true))
	var advance := maxf(0.5, float(idle_cfg.get("scout_advance_tiles", 2.0)))
	var ours := float(team_total(ai, leader))
	var my_ids := _my_zone_ids(ai)
	var candidates: Array = []
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var own: Dictionary = z
		if String(own.get("owner", "")) != ai.faction:
			continue
		if not _zone_is_frontier_local(ai, own):
			continue
		for az in _adjacent_zones(ai, own):
			if typeof(az) != TYPE_DICTIONARY:
				continue
			var adj: Dictionary = az
			var zid := int(adj.get("id", -1))
			if my_ids.has(zid):
				continue
			var owner := String(adj.get("owner", ""))
			if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
				continue
			var cv: Variant = adj.get("center", null)
			if cv == null:
				continue
			var center: Vector2i = cv
			var pt := Vector2.ZERO
			var capture := false
			var score := 0.0
			if owner == "":
				var ep := _enemy_strength_near(ai, GridRes.center_of(center), threat_radius)
				if capture_empty and ep <= 0.0 and zid != int(ai.target_zone) \
						and _zone_worth_taking(ai, adj):
					pt = GridRes.center_of(center)
					capture = true
					score = 90.0
				else:
					continue
			else:
				var pv: Variant = _enemy_frontier_point(ai, own, adj, advance)
				if pv == null:
					continue
				pt = pv
				var ep2 := _enemy_strength_near(ai, pt, threat_radius)
				if ep2 > 0.0 and ep2 >= ours * scout_ratio:
					continue
				score = 70.0 - ep2 * 3.0
			var d: float = leader.pos.distance_to(pt)
			if d > max_dist:
				continue
			score -= d * 0.35
			if _point_too_dangerous(ai, pt, ours, threat_radius, scout_ratio):
				continue
			if _scout_target_taken(ai, pt, 5.0):
				continue
			candidates.append({"pt": pt, "zone": zid, "capture": capture,
				"score": score})
	if candidates.is_empty():
		return null
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := float(a.get("score", 0.0))
		var sb := float(b.get("score", 0.0))
		if absf(sa - sb) > 1e-6:
			return sa > sb
		var za := int(a.get("zone", -1))
		var zb := int(b.get("zone", -1))
		if za != zb:
			return za < zb
		var pa: Vector2 = a.get("pt", Vector2.ZERO)
		var pb: Vector2 = b.get("pt", Vector2.ZERO)
		if pa.y != pb.y:
			return pa.y < pb.y
		return pa.x < pb.x)
	return candidates[0]


## 敌方区划的外沿点：从「己方边境格 → 敌方边境格」再往里推进 `advance` 格。
static func _enemy_frontier_point(ai, own: Dictionary, enemy_zone: Dictionary,
		advance: float) -> Variant:
	var target_id := int(enemy_zone.get("id", -1))
	var best: Variant = null
	var best_score := -INF
	for t in (own.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			if not ai.world.map.tile_exists(n.x, n.y):
				continue
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null or int((oz as Dictionary).get("id", -1)) != target_id:
				continue
			if not ai.world.map.terrain_walkable(n.x, n.y):
				continue
			var raw := Vector2(float(n.x) + 0.5 + float(d.x) * advance,
				float(n.y) + 0.5 + float(d.y) * advance)
			var pt := _clamp_map_point(ai, raw)
			var tile: Vector2i = ai.world.map.nearest_walkable(int(floor(pt.x)),
				int(floor(pt.y)), 4)
			if tile.x < 0 or tile.y < 0:
				continue
			pt = Vector2(float(tile.x) + 0.5, float(tile.y) + 0.5)
			# 优先靠近敌方区划中心的方向，但不要真的走到中心。
			var ecv: Variant = enemy_zone.get("center", null)
			var score := 0.0
			if ecv != null:
				var ect: Vector2i = ecv
				score -= Vector2(float(tile.x - ect.x), float(tile.y - ect.y)).length() * 0.05
			if score > best_score or best == null:
				best_score = score
				best = pt
	return best


static func _adjacent_zones(ai, zone: Dictionary) -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	var zid := int(zone.get("id", -1))
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			if not ai.world.map.tile_exists(n.x, n.y):
				continue
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var od: Dictionary = oz
			var oid := int(od.get("id", -1))
			if oid == zid or seen.has(oid):
				continue
			seen[oid] = true
			out.append(od)
	return out


static func _scout_target_taken(ai, pt: Vector2, radius: float) -> bool:
	for mv in ai.scout_missions.values():
		if typeof(mv) != TYPE_DICTIONARY:
			continue
		var m: Dictionary = mv
		var p: Vector2 = m.get("pt", Vector2.ZERO)
		if p.distance_to(pt) <= radius:
			return true
	return false


## ★★ 大部队的「硬目标」档：凑够 `assault_units` 才主动打最近敌方目标（区划 / 大本营）。
## 小队由 `_expand()` 负责占中立 / 薄弱的敌方区划。
static func _attack_if_ready(ai) -> bool:
	if bool(ai.assault_active):
		return true                      # 已有任务：交给 `_continue_assault()` 推进
	var ec: Dictionary = ai.profile.get("expand", {})
	var required := maxi(2, _i(ec, "assault_units", 10))
	var ready := ready_field_teams(ai, _min_units(ai))
	var total := 0
	for t in ready:
		# 游击队不去硬目标：它们只打没有防备的边界。
		if _role_of(ai, t["leader"]) == "guerrilla":
			continue
		var tlid := String((t["leader"] as Object).id)
		if ai.regroup_ids.has(tlid) or _react_locked(ai, tlid) \
				or _is_early_explorer(ai, tlid):
			continue
		total += team_total(ai, t["leader"])
	if total < required:
		return false
	var pt: Variant = _nearest_enemy_target(ai)
	if pt == null:
		return false
	# 目标周围看得见的敌军越多，要求的规模越大（别拿 10 个人冲 20 个人的基地）。
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var enemy := _enemy_strength_near(ai, pt, threat_radius)
	required = maxi(required, int(ceil(enemy * avoid_ratio)) + 2)
	if total < required:
		return false
	ai.assault_active = true
	ai.assault_point = pt
	ai.assault_team_ids.clear()
	for t2 in ready:
		if _role_of(ai, t2["leader"]) == "guerrilla":
			continue
		var alid := String((t2["leader"] as Object).id)
		if ai.regroup_ids.has(alid) or _react_locked(ai, alid) \
				or _is_early_explorer(ai, alid):
			continue
		ai.assault_team_ids.append(alid)
		ai.scout_missions.erase(alid)
		ai.post_missions.erase(alid)
		ai.guard_missions.erase(alid)
	# 目标可能很深：给一个上限，避免「追一个打不掉的目标」无限拖住全军。
	ai.assault_until = ai.world.time + maxf(20.0, float(ec.get("assault_timeout_sec", 90.0)))
	_issue_assault_orders(ai)
	ai.stats["assaults"] = int(ai.stats.get("assaults", 0)) + 1
	ai.note_status("assault")
	return true


## 继续进攻任务：队伍还在、目标还有效、没超时就持续压向目标点。
static func _continue_assault(ai) -> bool:
	if not bool(ai.assault_active):
		return false
	if ai.world.time > ai.assault_until:
		clear_assault(ai)
		return false
	# 目标已经被打掉 / 不再是最近敌方目标 ⇒ 结束这一轮（下一 tick 重新选）。
	var now_pt: Variant = _nearest_enemy_target(ai)
	if now_pt == null or (now_pt as Vector2).distance_to(ai.assault_point) > 4.0:
		clear_assault(ai)
		return false
	var alive: Array = []
	var total := 0
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var enemy := _enemy_strength_near(ai, ai.assault_point, threat_radius)
	# ★★ 目标守军已经清空：残队也继续压上去拆建筑 / 站中心，不要因为掉编就整轮放弃。
	var undefended := enemy <= 0.0
	for id in ai.assault_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed() or not u.is_general():
			continue
		# 远程队前排倒光、附近还有敌人 ⇒ 整队后撤（整队命令）。
		if _role_of(ai, u) == "ranged":
			var rc: Dictionary = (ai.profile.get("roles", {}) as Dictionary).get("ranged", {})
			if enemy > 0.0 and ai.frontline_count(u) < int(rc.get("frontline_min", 1)):
				_retreat_team(ai, u)
				continue
		# 单支队伍掉到不能出门的规模 ⇒ 从任务里剔除（交给 `_regroup`）；
		# 目标已经没人防守时例外。
		if team_total(ai, u) < min_units and not undefended:
			continue
		alive.append({"leader": u, "units": ai.world.group_of(u)})
		total += team_total(ai, u)
	if alive.is_empty() or (total < min_units and not undefended):
		clear_assault(ai)
		return false
	# ★ 进攻途中敌人越聚越多：如果已经明显多于我方，就放弃这一轮，
	#   不要拿大部队去硬填一个更大的兵团（下一 tick 重新评估 / 补员）。
	if float(total) < enemy * avoid_ratio:
		clear_assault(ai)
		return false
	ai.assault_team_ids.clear()
	for t in alive:
		ai.assault_team_ids.append(String((t["leader"] as Object).id))
	_issue_assault_orders(ai)
	ai.note_status("assault")
	return true


static func _issue_assault_orders(ai) -> void:
	var pt: Vector2 = ai.assault_point
	var ec: Dictionary = ai.profile.get("expand", {})
	var enemy := _enemy_strength_near(ai, pt, maxf(0.0, float(ec.get("threat_radius", 6.0))))
	for id in ai.assault_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed():
			continue
		var op := pt
		if enemy > 0.0:
			op = _role_target_point(ai, u, pt)
		_order_team(ai, {"leader": u, "units": ai.world.group_of(u)}, op, true)


static func clear_assault(ai) -> void:
	ai.assault_active = false
	ai.assault_team_ids.clear()
	ai.assault_until = 0.0


# ------------------------------------------------------------------
# 目标选择
# ------------------------------------------------------------------

## ★★ 扩张目标：与己方区划相邻、还没归己方（或盟友）的区划；
## 按「经济需求 + 产能 + 敌方归属 + 守备 + 距离」评分。
##
## 「AI 认为需要」的落点在这里：
##   · 当前粮食 / 黄金收入离目标越远，对应产能的区划加分越多；
##   · 己方区划平均人口越满，人口区划越值得拿（更多人口 = 更多招募）；
##   · 无主区划优先（+2），敌方区划只加少量「削弱对手」分；
##   · 视距内守军越多越扣分（不送死）；离基地越远越扣分。
static func _pick_expand_zone(ai) -> Variant:
	var my_ids: Dictionary = {}
	for z in ai.world.zones.zones:
		if typeof(z) == TYPE_DICTIONARY:
			var zd0: Dictionary = z
			if FactionRes.same_side_for_attack(String(zd0.get("owner", "")), ai.faction):
				my_ids[int(zd0.get("id", -1))] = true
	if my_ids.is_empty():
		return null
	var ec: Dictionary = ai.profile.get("expand", {})
	var target_food := maxf(0.5, float(ec.get("target_food_income", 4.0)))
	var target_gold := maxf(0.5, float(ec.get("target_gold_income", 4.0)))
	var target_pop := clampf(float(ec.get("target_population_ratio", 0.35)), 0.0, 1.0)
	var defender_w := maxf(0.0, float(ec.get("defender_weight", 0.8)))
	var dist_w := maxf(0.0, float(ec.get("distance_weight", 0.15)))
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var income: Dictionary = ai.world.zones.production_of(ai.faction)
	var food_need := clampf(1.0 - float(income.get("food", 0.0)) / target_food, 0.0, 1.0)
	var gold_need := clampf(1.0 - float(income.get("gold", 0.0)) / target_gold, 0.0, 1.0)
	var pop_need := clampf(1.0 - _owned_population_ratio(ai) / maxf(0.01, target_pop), 0.0, 1.0)
	var base = ai.world.find_base_of(ai.faction)
	var best = null
	var best_id := 1 << 30
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		var zid := int(zd.get("id", -1))
		if my_ids.has(zid):
			continue
		if ai.failed_expand_zones.has(zid):
			continue
		var owner := String(zd.get("owner", ""))
		if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		if not _adjacent_to_mine(ai, zd, my_ids):
			continue
		var prod: Dictionary = zd.get("production", {})
		var score := 5.0
		score += float(prod.get("food", 0.0)) * (0.8 + 1.6 * food_need)
		score += float(prod.get("gold", 0.0)) * (0.8 + 1.6 * gold_need)
		score += float(prod.get("population", 0.0)) * (0.5 + 1.0 * pop_need)
		# 同种类区划再给一点「缺什么补什么」的方向性
		var kind := String(zd.get("kind", ""))
		if kind == "food":
			score += 1.0 * food_need
		elif kind == "gold":
			score += 1.0 * gold_need
		elif kind == "population":
			score += 1.0 * pop_need
		score += 2.0 if owner == "" else 0.5
		var c: Vector2i = cv
		# ★ 用「中心周围 threat_radius 内的可见敌军兵力」而不是只看中心 3×3：
		#   小股部队不该因为目标中心恰好没人，就一头撞进旁边的大部队。
		var enemy_strength := _enemy_strength_near(ai, GridRes.center_of(c), threat_radius)
		score -= enemy_strength * defender_w
		if base != null:
			score -= Vector2(float(c.x - base.tx), float(c.y - base.ty)).length() * dist_w
		if score > best_score + 1e-6 or (absf(score - best_score) <= 1e-6 and zid < best_id):
			best_score = score
			best_id = zid
			best = zd
	return best


## 己方所有区划的「当前人口 / 人口上限」平均值（0~1）。
static func _owned_population_ratio(ai) -> float:
	var total := 0.0
	var cap := 0.0
	for z in ai.world.zones.zones:
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		total += float(zd.get("population", 0.0))
		cap += maxf(0.0, float(zd.get("population_cap", 0.0)))
	if cap <= 0.0:
		return 0.0
	return clampf(total / cap, 0.0, 1.0)


## 这个区划要派多少人去占：无主 / 无守军 → 小队；敌方 / 有守军 → 大一点的队。
## ★ 守军按「中心周围 threat_radius 内的可见敌军兵力估值」算（将领算 2），
##   再乘 `avoid_enemy_ratio` 留出安全余量；小股部队不会被派去硬碰大部队。
static func _required_units_for_zone(ai, zd: Dictionary) -> int:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var squad := maxi(min_units, _squad_units(ai))
	var enemy_min := maxi(squad, _i(ec, "enemy_zone_min_units", 7))
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var c: Variant = zd.get("center", null)
	var enemy := 0.0
	if c != null:
		var ct: Vector2i = c
		enemy = _enemy_strength_near(ai, GridRes.center_of(ct), threat_radius)
	var need_from_enemy := int(ceil(enemy * avoid_ratio)) + 1
	var owner := String(zd.get("owner", ""))
	# ★★ 2026.10.25：敌方区划里的守军已经被清空时，不再硬卡 `enemy_zone_min_units`。
	#   否则「附近敌人打光了」也永远要 7 人，小队不会去站中心，区划永远占不下来。
	if owner == "" or enemy <= 0.0:
		return maxi(min_units, maxi(squad, need_from_enemy))
	return maxi(min_units, maxi(enemy_min, need_from_enemy + 1))


## 没有满编外勤队时，挑一支「最小的、但能动的」外勤队去占空无主区划。
## 只用于 `_expand()` 的无主 / 无守军目标，不用于敌方区划。
static func _pick_bootstrap_team(ai):
	for t in field_teams(ai):
		var leader = t.get("leader", null)
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if _react_locked(ai, lid) or _is_early_explorer(ai, lid):
			continue
		if ai.regroup_ids.has(lid) or ai.scout_missions.has(lid) \
				or ai.post_missions.has(lid) or ai.guard_missions.has(lid) \
				or ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		if team_total(ai, leader) >= 1:
			return t
	return null


## 从「已经能出门」的外勤队里挑一支（或几支）去 pt。
##
## @param required 目标想要的**总人数**（含将领）
## @param force    true = 玩家强制：凑不够也把现有的能派队派出去
## @return 选中的队伍数组（`{leader, units}`）；凑不够且 force=false → 空数组
static func _pick_mission_teams(ai, pt: Vector2, required: int, force: bool) -> Array:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := _min_units(ai)
	var assault_units := maxi(min_units, _i(ec, "assault_units", 10))
	var ts: Array = []
	for t0 in ready_field_teams(ai, min_units):
		var mlid := String((t0["leader"] as Object).id)
		# 正在回撤补员 / 受击即时命令锁定中的队伍不参加新的出击任务。
		if ai.regroup_ids.has(mlid) or _react_locked(ai, mlid) \
				or _is_early_explorer(ai, mlid):
			continue
		ts.append(t0)
	if ts.is_empty() and force:
		# ★ 玩家直接下令「扩张」时，如果还没有任何外勤队（开局只有一位将领），
		#   允许把守军本身派出去 —— 这是明确意图，不能因为「要留人看家」而原地不动。
		#   自主模式（force=false）仍然绝不派走守军。
		for t0 in leader_teams(ai):
			var flid := String((t0["leader"] as Object).id)
			if _react_locked(ai, flid) or _is_early_explorer(ai, flid):
				continue
			if team_total(ai, t0["leader"]) >= min_units:
				ts.append(t0)
	if ts.is_empty():
		return []
	var hard := required >= assault_units
	ts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var la = a["leader"]
		var lb = b["leader"]
		var da: float = (la as Object).pos.distance_to(pt)
		var db: float = (lb as Object).pos.distance_to(pt)
		var sa := team_total(ai, la)
		var sb := team_total(ai, lb)
		if hard:
			if sa != sb:
				return sa > sb
			if absf(da - db) > 1e-6:
				return da < db
		else:
			if absf(da - db) > 1e-6:
				return da < db
			if sa != sb:
				return sa > sb
		return String((la as Object).id) < String((lb as Object).id))
	var out: Array = []
	var total := 0
	for t in ts:
		var leader = t["leader"]
		out.append({"leader": leader, "units": ai.world.group_of(leader)})
		total += team_total(ai, leader)
		if total >= required:
			break
	if total < min_units:
		out.clear()
		return out
	# ★★ 小股部队不硬碰：目标附近可见敌军成规模时，要求「凑够人数」才出发。
	#   自主模式（force=false）凑不够就返回空，让队伍继续补员 / 巡逻；
	#   玩家强制（force=true）仍然派现有的队 —— 那是明确意图。
	if not force:
		var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
		var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
		var enemy := _enemy_strength_near(ai, pt, threat_radius)
		var need := int(ceil(enemy * avoid_ratio)) + 1
		if total < maxi(required, need):
			return []
	if total < required and not force:
		return []
	return out


static func _zone_worth_taking(ai, z: Dictionary) -> bool:
	var owner := String(z.get("owner", ""))
	if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
		return false
	return z.get("center", null) != null


static func _adjacent_to_mine(ai, zone: Dictionary, my_ids: Dictionary) -> bool:
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			if my_ids.has(int((oz as Dictionary).get("id", -1))):
				return true
	return false


## 最近的敌方目标点：已知敌方大本营 > 敌方区划中心 > 敌方建筑。
static func _nearest_enemy_target(ai) -> Variant:
	var base = ai.world.find_base_of(ai.faction)
	var from := Vector2.ZERO
	if base != null:
		from = Vector2(float(base.tx), float(base.ty))
	var best: Variant = null
	var best_d := INF
	if ai.world.fog != null and ai.world.fog.has_method("known_buildings"):
		for b in ai.world.fog.known_buildings(ai.faction):
			if b == null or not b.alive:
				continue
			if FactionRes.same_side_for_attack(String(b.owner), ai.faction):
				continue
			if String(b.type) != "base":
				continue
			var p := Vector2(float(b.tx), float(b.ty))
			var d: float = from.distance_to(p)
			if d < best_d:
				best_d = d
				best = p
	if best != null:
		return best
	# 区划归属是公开信息：找最近的敌方区划中心
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		var owner := String(zd.get("owner", ""))
		if owner == "" or FactionRes.same_side_for_attack(owner, ai.faction):
			continue
		var c: Variant = zd.get("center", null)
		if c == null:
			continue
		var ct: Vector2i = c
		var d2: float = from.distance_to(Vector2(float(ct.x), float(ct.y)))
		if d2 < best_d:
			best_d = d2
			best = GridRes.center_of(ct)
	# 3) 连敌方区划都没有（残局）：退到最近的已知敌方建筑。
	if best == null and ai.world.fog != null and ai.world.fog.has_method("known_buildings"):
		for b in ai.world.fog.known_buildings(ai.faction):
			if b == null or not b.alive:
				continue
			if FactionRes.same_side_for_attack(String(b.owner), ai.faction):
				continue
			var p2 := Vector2(float(b.tx) + 0.5, float(b.ty) + 0.5)
			var d3: float = from.distance_to(p2)
			if d3 < best_d:
				best_d = d3
				best = p2
	return best


# ------------------------------------------------------------------
# 回防
# ------------------------------------------------------------------

static func _defense_tick(ai) -> bool:
	if ai.recall_cd > 0.0:
		return false
	var threat: Variant = _find_threat(ai)
	if threat == null:
		ai.threat_since = -1.0
		return false
	# 难度反应延迟：第一次看到威胁先等一会儿再回防（不给「瞬间全图反应」）。
	var delay := maxf(0.0, float(ai.profile.get("reaction_delay_sec", 0.0)))
	if ai.threat_since < 0.0:
		ai.threat_since = ai.world.time
	if ai.world.time - ai.threat_since < delay:
		return false
	ai.threat_since = -1.0
	var td: Dictionary = threat
	var pt: Vector2 = td["point"]
	var all_defend: bool = bool(td.get("all", false))
	var dc: Dictionary = ai.profile.get("defense", {})
	var ratio := 1.0 if all_defend else clampf(float(dc.get("recall_ratio", 0.35)), 0.1, 1.0)
	# 回防也只派「达到当前出门规模」的队伍：常规期不拿 1~2 人队去填线。
	var min_units := _min_units(ai)
	var ts := ready_field_teams(ai, min_units)
	if ts.is_empty():
		# 没有外勤队时，守军自己可以回防（守军规模也达标才派）。
		var home = ensure_garrison(ai)
		if home != null and team_total(ai, home) >= min_units:
			ts.append({"leader": home, "units": ai.world.group_of(home)})
	if ts.is_empty():
		return false
	ts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: Vector2 = (a["leader"] as Object).pos
		var pb: Vector2 = (b["leader"] as Object).pos
		var da: float = pa.distance_to(pt)
		var db: float = pb.distance_to(pt)
		if absf(da - db) > 0.001:
			return da < db
		return String((a["leader"] as Object).id) < String((b["leader"] as Object).id))
	var want := maxi(1, int(ceil(float(ts.size()) * ratio)))
	var sent := 0
	for t in ts:
		if sent >= want:
			break
		var dlid := String((t["leader"] as Object).id)
		# 正在执行受击即时命令 / 开局探索的队伍不抢去回防。
		if _react_locked(ai, dlid) or _is_early_explorer(ai, dlid):
			continue
		ai.scout_missions.erase(dlid)
		ai.post_missions.erase(dlid)
		ai.guard_missions.erase(dlid)
		_order_team(ai, t, pt, false)
		sent += 1
	ai.defend_until = ai.world.time + maxf(1.0, float(dc.get("hold_sec", 8.0)))
	ai.recall_cd = maxf(1.0, float(dc.get("recall_cooldown_sec", 20.0)))
	ai.note_status("defending")
	return true


## 找威胁：可见敌人靠近大本营 / 己方区划中心，或己方区划中心正被敌方读条。
## 返回 {point: Vector2, all: bool} 或 null。
static func _find_threat(ai) -> Variant:
	var dc: Dictionary = ai.profile.get("defense", {})
	var radius := maxf(1.0, float(dc.get("threat_radius", 10.0)))
	var base = ai.world.find_base_of(ai.faction)
	var base_pt := Vector2.ZERO
	if base != null:
		base_pt = Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5)
	var low_hp := false
	if base != null:
		low_hp = float(base.hp) <= float(base.hp_max) * float(dc.get("base_low_hp_ratio", 0.45))
	var best: Variant = null
	var best_d := INF
	# 1) 可见敌方单位
	for u in ai.world.units:
		if not u.alive or FactionRes.same_side_for_attack(String(u.faction), ai.faction):
			continue
		if ai.world.fog != null and not ai.world.fog.logic_unit_visible(ai.faction, u):
			continue
		var p: Vector2 = u.pos
		var d: float = p.distance_to(base_pt)
		if d <= radius and d < best_d:
			best_d = d
			best = p
	# 2) 己方区划中心被敌方读条（区划状态是公开信息）
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		var cs := String(zd.get("capture_state", ""))
		if cs != "reading" and cs != "frozen":
			continue
		var cf := String(zd.get("capture_faction", ""))
		if cf == "" or FactionRes.same_side_for_attack(cf, ai.faction):
			continue
		var c: Variant = zd.get("center", null)
		if c == null:
			continue
		var ct: Vector2i = c
		best = GridRes.center_of(ct)
		best_d = 0.0
		break
	if best == null:
		return null
	return {"point": best, "all": low_hp}


# ------------------------------------------------------------------
# 下命令 + 去重
# ------------------------------------------------------------------

## 给一队下「行军攻击」；已经在去同一个点 / 已在目标半径内且没在交战 → 不重复下。
## ★ 招募中的将领**不再被跳过**：2026.10.24 起可以边移动边招募。
## ★★ 把任意目标点夹进地图内（0.5 .. cols-0.5 / rows-0.5）。
##    这是「AI 部队跑到地图外」的最后一道保险：基地贴边时 `base + 1.5`、
##    巡逻环 `base ± 3.5`、区划中心 +1.5 都可能算出界。
static func _clamp_map_point(ai, pt: Vector2) -> Vector2:
	if ai == null or ai.world == null or ai.world.map == null:
		return pt
	var max_x := maxf(0.5, float(ai.world.map.cols) - 0.5)
	var max_y := maxf(0.5, float(ai.world.map.rows) - 0.5)
	return Vector2(clampf(pt.x, 0.5, max_x), clampf(pt.y, 0.5, max_y))


static func _order_team(ai, team: Dictionary, pt: Vector2, keep: bool = true,
		force: bool = false) -> bool:
	var leader = team["leader"]
	if leader == null or not leader.alive or leader.is_downed():
		return false
	# ★ 所有 AI 目标点都在这里过一道地图边界，绝不把 move 目标发到图外。
	pt = _clamp_map_point(ai, pt)
	var reissue := maxf(1.0, float(ai.profile.get("march", {}).get("reissue_sec", 6.0)))
	var last: Dictionary = ai.last_orders.get(String(leader.id), {})
	if not force and not last.is_empty():
		var lp: Vector2 = last.get("pt", Vector2(-9999.0, -9999.0))
		var lt: float = float(last.get("t", -999.0))
		if lp.distance_to(pt) < 0.75 and ai.world.time - lt < reissue:
			return false
		# 已经站在那里、也没有敌人 → 不再下命令（驻守）
		if keep and leader.pos.distance_to(pt) <= 1.5 \
				and leader.target == null and leader.target_building == null:
			return false
	var units: Array = team.get("units", [])
	if units.is_empty():
		return false
	# ★★ 2026.10.25：整队命令必须能压过**单兵受击反击**。
	#   `unit.order_attack_move(player=false)` 会拒绝「正在反击」的单位；
	#   不先清掉的话，挨打的那个兵会继续追自己的目标，队形从这里散开。
	for u in units:
		if u == null or not u.alive or u.is_downed():
			continue
		if u.has_method("is_retaliating") and u.is_retaliating():
			u.clear_retaliation()
	var ok: bool = CommandProcessorRes.order_group_attack_move(ai.world, ai.cfg, units, pt)
	if ok:
		ai.last_orders[String(leader.id)] = {"pt": pt, "t": ai.world.time}
		ai.stats["orders"] = int(ai.stats.get("orders", 0)) + 1
	else:
		ai.stats["order_failures"] = int(ai.stats.get("order_failures", 0)) + 1
	return ok


## 整队**普通移动**（撤退 / 回撤补员 / 粘合回位用）：路上遇敌**不停**。
## 与 `_order_team()`（行军攻击）分开，是为了让「撤」和「打」在命令层就不同。
static func _move_team(ai, team: Dictionary, pt: Vector2, force: bool = false) -> bool:
	var leader = team["leader"]
	if leader == null or not leader.alive or leader.is_downed():
		return false
	pt = _clamp_map_point(ai, pt)
	var reissue := maxf(1.0, float(ai.profile.get("march", {}).get("reissue_sec", 6.0)))
	var last: Dictionary = ai.last_orders.get(String(leader.id), {})
	if not force and not last.is_empty():
		var lp: Vector2 = last.get("pt", Vector2(-9999.0, -9999.0))
		var lt: float = float(last.get("t", -999.0))
		if lp.distance_to(pt) < 0.75 and ai.world.time - lt < reissue:
			return false
	var units: Array = team.get("units", [])
	if units.is_empty():
		return false
	for u in units:
		if u == null or not u.alive or u.is_downed():
			continue
		if u.has_method("is_retaliating") and u.is_retaliating():
			u.clear_retaliation()
	var ok: bool = CommandProcessorRes.order_group_formation(ai.world, ai.cfg, units, pt, false)
	if ok:
		ai.last_orders[String(leader.id)] = {"pt": pt, "t": ai.world.time}
		ai.stats["orders"] = int(ai.stats.get("orders", 0)) + 1
	else:
		ai.stats["order_failures"] = int(ai.stats.get("order_failures", 0)) + 1
	return ok


static func _has_order_point(ai) -> bool:
	if ai.world == null or ai.world.map == null:
		return false
	var x := int(floor(float(ai.order_x)))
	var y := int(floor(float(ai.order_y)))
	return ai.world.map.tile_exists(x, y)


# ------------------------------------------------------------------
# 小工具
# ------------------------------------------------------------------

static func _i(d: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = d.get(key, null)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return fallback
