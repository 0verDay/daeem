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
##     直到归属翻过来才换下一个目标（不会走一半又换目标）。
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
	match String(ai.order_kind):
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
			out.append({"leader": u, "units": g, "size": g.size()})
		else:
			var l = ai.world.unit_by_id(String(u.leader_id))
			if l == null or not l.alive:
				out.append({"leader": u, "units": [u], "size": 1})
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
	return best


## ★★ 守军轮换：守军补到 `home_team_size` 且基地里还有一支「至少 1 个兵」的队
## ⇒ 换它接防，老守军变成外勤队（下一步会被扩张 / 巡逻 / 进攻逻辑挑走）。
##
## @return true = 这一 tick 真的换人了
static func maybe_rotate_garrison(ai) -> bool:
	var home = ensure_garrison(ai)
	if home == null:
		return false
	var pc: Dictionary = ai.profile.get("production", {})
	var ec: Dictionary = ai.profile.get("expand", {})
	var target := maxi(1, _i(pc, "home_team_size", 6))
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
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


## 还没补到「能出门」规模的队伍数（补将前要看它：先装备好现有将领，别急着加光杆）。
static func understrength_team_count(ai) -> int:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
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
	var rally := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	for t in leader_teams(ai):
		var leader = t["leader"]
		if leader.target != null or leader.target_building != null:
			continue
		if leader.is_downed():
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
		_order_team(ai, t, pt, true)


static func _mass(ai) -> void:
	var pt := Vector2(float(ai.order_x), float(ai.order_y))
	if not _has_order_point(ai):
		var base = ai.world.find_base_of(ai.faction)
		if base == null:
			return
		pt = Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	var all := leader_teams(ai)
	# 至少留一位将领看家（否则生产会停）；只有一位时只能带上。
	var home = ensure_garrison(ai)
	var keep_home := home != null and all.size() >= 2
	for t in all:
		if keep_home and (t["leader"] as Object) == home:
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
	var pick: Variant = _pick_expand_zone(ai)
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
	var required := _required_units_for_zone(ai, zd)
	var chosen := _pick_mission_teams(ai, pt, required, force)
	if chosen.is_empty():
		return false
	ai.target_zone = int(zd.get("id", -1))
	ai.expand_team_ids.clear()
	for t in chosen:
		ai.expand_team_ids.append(String((t["leader"] as Object).id))
	ai.expand_started_at = ai.world.time
	for t2 in chosen:
		_order_team(ai, t2, pt, true)
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
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	var alive: Array = []
	var total := 0
	for id in ai.expand_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed():
			continue
		if not u.is_general():
			continue
		# ★ 单支队伍掉到「不能出门」的规模 ⇒ 从任务里剔除，交给 `_regroup` 带回整备；
		#   不能因为它还在 id 列表里就继续把光杆司令往区划中心送。
		if team_total(ai, u) < min_units:
			continue
		alive.append({"leader": u, "units": ai.world.group_of(u)})
		total += team_total(ai, u)
	if alive.is_empty() or total < min_units:
		# 队伍被打残了：放弃这一块，让它们先回去整备（`_regroup` 会接管）。
		_clear_expand(ai, true)
		return false
	# ★ 占领途中敌人增援到明显多于我方：别让小队继续往中心送，先撤。
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var enemy := _enemy_strength_near(ai, pt, threat_radius)
	if float(total) < enemy * avoid_ratio:
		_clear_expand(ai, true)
		return false
	for t in alive:
		_order_team(ai, t, pt, true)
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
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
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
	ai.regroup_ids.clear()
	_regroup(ai)
	# ★ 小股 / 中等队伍看到成规模敌军就撤，不硬碰硬（进攻任务除外：那是主动凑够人才打的）。
	_avoid_bad_fights(ai)
	if _continue_assault(ai):
		_patrol(ai)
		return
	if _expand(ai, false):
		_patrol(ai)
		return
	if _attack_if_ready(ai):
		_patrol(ai)
		return
	_patrol(ai)


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
	var squad_units := maxi(2, _i(ec, "squad_units", 3))
	var base = ai.world.find_base_of(ai.faction)
	if base == null:
		return
	var rally := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	for t in field_teams(ai):
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		var lid := String(leader.id)
		if ai.assault_team_ids.has(lid):
			continue
		var ours := float(team_total(ai, leader))
		if ours <= 0.0:
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
		_order_team(ai, t, rally, true)
		ai.stats["avoids"] = int(ai.stats.get("avoids", 0)) + 1
		ai.note_status("regroup")


## ★★ 掉到「出门规模以下」的队伍：在自己的领地里就地补员；在领地外 / 无人区就回撤。
##
## 这是「光杆司令到处巡逻」的正面修法：0~2 个兵的队伍不会被任何战略逻辑派出去，
## 已经在外面的会被叫回最近的己方区划中心（路上边撤边招）；已经在己方人口区里的
## 则先停住旧命令、等生产把它补起来。
static func _regroup(ai) -> void:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	var home = ensure_garrison(ai)
	var base = ai.world.find_base_of(ai.faction)
	var rally := Vector2.ZERO
	if base != null:
		rally = Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
	for t in field_teams(ai):
		var leader = t["leader"]
		if leader == null or not leader.alive or leader.is_downed():
			continue
		if team_total(ai, leader) >= min_units:
			continue
		if leader == home:
			continue
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
		if ai.world.fog != null and not ai.world.fog.unit_visible(ai.faction, u):
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
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	var threat_radius := maxf(0.0, float(pc.get("threat_radius", 7.0)))
	var avoid_ratio := maxf(0.1, float(pc.get("avoid_enemy_ratio", 1.25)))
	var squad_units := maxi(2, _i(ec, "squad_units", 3))
	var ts: Array = []
	for t in ready_field_teams(ai, min_units):
		var leader = t["leader"]
		var lid := String((leader as Object).id)
		if ai.expand_team_ids.has(lid) or ai.assault_team_ids.has(lid):
			continue
		ts.append(t)
	# ★ 只有守军一支队伍时：允许它（读条中 / 空闲）去基地附近巡逻，
	#   但基地附近已经有敌人时不允许 —— 守家优先。
	var home_only := false
	if ts.is_empty() and bool(pc.get("home_when_alone", true)):
		var home = ensure_garrison(ai)
		var base = ai.world.find_base_of(ai.faction)
		if home != null and base != null and team_total(ai, home) >= min_units:
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
	var base = ai.world.find_base_of(ai.faction)
	if base != null:
		# 基地外围四个点（不要正好压在基地格上）
		pts.append(Vector2(float(base.tx) + 3.5, float(base.ty) + 1.5))
		pts.append(Vector2(float(base.tx) - 1.5, float(base.ty) + 3.5))
		pts.append(Vector2(float(base.tx) - 3.5, float(base.ty) - 1.5))
		pts.append(Vector2(float(base.tx) + 1.5, float(base.ty) - 3.5))
	for z in ai.world.zones.zones:
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		var c: Variant = zd.get("center", null)
		if c == null:
			continue
		var ct: Vector2i = c
		pts.append(Vector2(float(ct.x) + 1.5, float(ct.y) + 1.5))
	return pts


## ★★ 大部队的「硬目标」档：凑够 `assault_units` 才主动打最近敌方目标（区划 / 大本营）。
## 小队由 `_expand()` 负责占中立 / 薄弱的敌方区划。
static func _attack_if_ready(ai) -> bool:
	if bool(ai.assault_active):
		return true                      # 已有任务：交给 `_continue_assault()` 推进
	var ec: Dictionary = ai.profile.get("expand", {})
	var required := maxi(2, _i(ec, "assault_units", 10))
	var ready := ready_field_teams(ai, maxi(2, _i(ec, "min_field_units", 3)))
	var total := 0
	for t in ready:
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
		ai.assault_team_ids.append(String((t2["leader"] as Object).id))
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
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	for id in ai.assault_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed() or not u.is_general():
			continue
		# 单支队伍掉到不能出门的规模 ⇒ 从任务里剔除（交给 `_regroup`）。
		if team_total(ai, u) < min_units:
			continue
		alive.append({"leader": u, "units": ai.world.group_of(u)})
		total += team_total(ai, u)
	if alive.is_empty() or total < min_units:
		clear_assault(ai)
		return false
	# ★ 进攻途中敌人越聚越多：如果已经明显多于我方，就放弃这一轮，
	#   不要拿大部队去硬填一个更大的兵团（下一 tick 重新评估 / 补员）。
	var threat_radius := maxf(0.0, float(ec.get("threat_radius", 6.0)))
	var avoid_ratio := maxf(0.1, float(ec.get("avoid_enemy_ratio", 1.35)))
	var enemy := _enemy_strength_near(ai, ai.assault_point, threat_radius)
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
	for id in ai.assault_team_ids:
		var u = ai.world.unit_by_id(String(id))
		if u == null or not u.alive or u.is_downed():
			continue
		_order_team(ai, {"leader": u, "units": ai.world.group_of(u)}, pt, true)


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
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	var squad := maxi(min_units, _i(ec, "squad_units",
		_i(ec, "min_squad_units", min_units)))
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
	if owner == "":
		return maxi(min_units, maxi(squad, need_from_enemy))
	return maxi(min_units, maxi(enemy_min, need_from_enemy + 1))


## 从「已经能出门」的外勤队里挑一支（或几支）去 pt。
##
## @param required 目标想要的**总人数**（含将领）
## @param force    true = 玩家强制：凑不够也把现有的能派队派出去
## @return 选中的队伍数组（`{leader, units}`）；凑不够且 force=false → 空数组
static func _pick_mission_teams(ai, pt: Vector2, required: int, force: bool) -> Array:
	var ec: Dictionary = ai.profile.get("expand", {})
	var min_units := maxi(2, _i(ec, "min_field_units", 3))
	var assault_units := maxi(min_units, _i(ec, "assault_units", 10))
	var ts := ready_field_teams(ai, min_units)
	if ts.is_empty() and force:
		# ★ 玩家直接下令「扩张」时，如果还没有任何外勤队（开局只有一位将领），
		#   允许把守军本身派出去 —— 这是明确意图，不能因为「要留人看家」而原地不动。
		#   自主模式（force=false）仍然绝不派走守军。
		for t0 in leader_teams(ai):
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
	var ts := field_teams(ai)
	if ts.is_empty():
		ts = leader_teams(ai)
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
		if ai.world.fog != null and not ai.world.fog.unit_visible(ai.faction, u):
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
static func _order_team(ai, team: Dictionary, pt: Vector2, keep: bool = true) -> bool:
	var leader = team["leader"]
	if leader == null or not leader.alive or leader.is_downed():
		return false
	var reissue := maxf(1.0, float(ai.profile.get("march", {}).get("reissue_sec", 6.0)))
	var last: Dictionary = ai.last_orders.get(String(leader.id), {})
	if not last.is_empty():
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
	var ok: bool = CommandProcessorRes.order_group_attack_move(ai.world, ai.cfg, units, pt)
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
