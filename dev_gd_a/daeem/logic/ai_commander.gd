## ai_commander.gd —— 阵营指挥官 AI 的控制器（每方一个，只在权威侧存在）。
##
## 它把「经济 / 建造 / 生产 / 军队」串成一个分层调度器（参考 Rusted Warfare 的 25/80/250
## 帧分层，换算成本作的秒制）：
##   · 每帧：校验 + 同步玩家指令 + 推进计时器；
##   · production_interval（默认 1.0s）：**按队补员** + 守军轮换 + 招将；
##   · build_interval（默认 2.5s）：升级 / 科技 / 特化 / 箭塔；
##   · army_interval（默认 0.6s）：回防 + 整备 + 扩张 / 进攻 / 巡逻；
##   · strategic_interval（默认 2.0s）：状态 / 区划归属对账。
##
## ★★ 2026.10.24 重做要点（用户口径：让指挥官「更会玩游戏、更有活人感」）：
##   · 不再用「全族兵力 / 动态上限」的比例做生产闸门（那个比例永远追不上将领增长）；
##   · 每支「将 + 兵」的队先补到自己的规模，守军补满后轮换出门，新队接防；
##   · 扩张 = 派队伍到「AI 认为需要的相邻区划」**中心**读条，拿下一块再换下一块；
##   · 小队占中立、大队打硬目标；光杆司令不出门，掉队的残队回撤整备。
##
## ★★ 状态归属（别混）：
##   · 对外可读的指令 / 资源在 `world.ai_directives` / `world.ai_faction_resources`（进快照）；
##   · 本控制器的计时器 / 预算 / 编组缓存 / 统计只在房主侧（`world.ai_commanders`），
##     客机不创建控制器、不跑 AI。
##
## ★★ 所有动作都走世界公开接口 / `command_processor`；控制器**不直接改** unit / building 字段。
## ★★ 确定性：随机只用 `world.unit_rand()`；候选同分时按 id / 坐标稳定排序。
extends RefCounted

const AiProfileRes = preload("res://logic/ai_profile.gd")
const AiEconomyRes = preload("res://logic/ai_economy.gd")
const AiBuildRes = preload("res://logic/ai_build.gd")
const AiArmyRes = preload("res://logic/ai_army.gd")

var world = null
var cfg = null
var faction: String = ""
var profile: Dictionary = {}

## 计时器（秒）
var army_timer: float = 0.0
var build_timer: float = 0.0
var production_timer: float = 0.0
var strategic_timer: float = 0.0
var retry_timer: float = 0.0
var general_try_timer: float = 5.0
## ★★ 濒死将领再起 / 召回巡检（独立于战略 tick，避免倒地后要等 2 秒才处理）。
var revive_timer: float = 0.0
## ★★ 队伍粘合巡检：将领在走、某个附属兵掉队 / 停下时，**重发整队命令**。
##    绝不单独调一个兵 —— 用户口径：command AI 只能给部队下指令。
var cohesion_next_at: float = 0.0
## ★★ 队伍职能：leader_id -> line / ranged / guerrilla。
##    职能由将领加入顺序轮换；影响招兵编成与行军目标（远程拉开、游击队打空档）。
var team_roles: Dictionary = {}
var role_serial: int = 0
## ★★ 受击后的整队反应冷却：leader_id -> 下次可再决策的时间。
##    第一次挨打立刻判断；同一队在冷却 + 模式锁期间不重复刷命令。
var react_next: Dictionary = {}
## ★★ 2026.10.25：受击即时命令的「模式锁」。
##   react_mode[lid]  = "counter" / "retreat"
##   react_point[lid] = 这次反击的落点（用来识别「还是同一场交火」）
##   react_until[lid] = 模式锁到期时间
##   目的：短时间连续挨打不要每 0.7 秒重新选一次反击 / 撤退，导致队伍来回抽搐。
var react_mode: Dictionary = {}
var react_point: Dictionary = {}
var react_until: Dictionary = {}

## 指令缓存（与 world.ai_directives 同步）
var order_kind: String = "auto"
var order_x: float = -1.0
var order_y: float = -1.0
var order_serial: int = -1

## 军队
var last_orders: Dictionary = {}
var target_zone: int = -1
var next_target_at: float = 0.0
var expand_hold: float = 0.0
var recall_cd: float = 0.0
var defend_until: float = 0.0
## 第一次看到威胁的时刻（-1 = 当前没有威胁）。难度 reaction_delay 用它。
var threat_since: float = -1.0
## ★★ 巡逻：下一次派队时间 / 轮换下标（自主 mode 用）。
var patrol_next_at: float = 0.0
var patrol_index: int = 0
## ★★ 2026.10.25：开局探索状态（只有一支初始部队时用）。
##   phase: "" / "out" / "home" / "rest"；out=在外探索，home=回基地，rest=基地补员。
var explore_leader_id: String = ""
var explore_phase: String = ""
var explore_target: Vector2 = Vector2.ZERO
var explore_until: float = 0.0
var explore_away: bool = false
## ★★ 2026.10.25：闲置部队的「侦察 / 防守驻守」任务。
##    key = 将领 id；value = {pt, zone, kind, reassess_at}。
##    侦察只派满编队；缺编队（有兵但没补满）去前线中心 / 隘口驻守；
##    满编队在没有安全侦察目标时也可以去守备。三者都不占用扩张 / 进攻任务。
##    ★ 都在 `ai_army.gd` 里维护，控制器只负责在改指令时清空。
var scout_missions: Dictionary = {}
var post_missions: Dictionary = {}
## 满编队的防守驻守（没有安全侦察目标 / 侦察名额已满时，去前线中心站岗）。
var guard_missions: Dictionary = {}
## ★★ 2026.10.24：守军是**角色**（谁在基地看家 / 优先补员），不是「唯一的生产者」。
##    它补满 `production.home_team_size` 后会轮换出门，由另一支接防。
##    `AiArmyRes.ensure_garrison()` / `maybe_rotate_garrison()` 维护它。
var garrison_leader_id: String = ""
## ★★ 当前扩张任务：目标区划 + 被派去的队伍 id + 开始时间。
##    `target_zone` 是旧字段（面板 / 测试读它），语义相同：-1 = 没有扩张任务。
var expand_team_ids: Array[String] = []
var expand_started_at: float = 0.0
## ★★ 当前进攻任务（大部队打敌方区划 / 大本营）：目标点、队伍、截止时间。
##    与扩张任务互斥 —— 同一时间只打一个「大战役」，其余队伍巡逻 / 补员。
var assault_active: bool = false
var assault_point: Vector2 = Vector2.ZERO
var assault_team_ids: Array[String] = []
var assault_until: float = 0.0
## 打不下来 / 走不到的扩张目标（本轮内不再选它，避免卡在一个目标上）。
var failed_expand_zones: Dictionary = {}
## 本局「曾经归己方」的区划 id（统计 zones_taken 用；只增不减）。
var _owned_zone_ids: Dictionary = {}
## ★ 本 tick 正在「回撤整备」的队伍 id（调试 / 测试用）：
##   这些队伍兵力不足，但它们的 `has_attack_move` 是**回家**而不是出击，
##   不该被「光杆司令出门」的判据误伤。
var regroup_ids: Dictionary = {}

## 建造
var blocked_tiles: Dictionary = {}
var tech_attempted: Dictionary = {}
var spec_attempted: Dictionary = {}

## 统计 / 状态（给面板与测试）
var stats: Dictionary = {}
var status: String = ""
var status_until: float = 0.0
var production_serial: int = 0

## 难度摊平后的常用值
var income_mult: float = 1.0
## 没有将领时的兜底上限（difficulty.army_cap）。有将领时实际上限走 `force_cap()`。
var army_cap: int = 26


func setup(p_world, p_cfg, p_faction: String, p_profile: Dictionary) -> void:
	world = p_world
	cfg = p_cfg
	faction = p_faction
	profile = p_profile
	income_mult = maxf(0.1, float(profile.get("income_mult", 1.0)))
	army_cap = maxi(1, int(profile.get("army_cap", 26)))
	var iv: Dictionary = profile.get("intervals", {})
	var army_iv := maxf(0.1, float(iv.get("army_interval_sec", 0.6)))
	var build_iv := maxf(0.2, float(iv.get("build_interval_sec", 2.5))) \
		* maxf(0.1, float(profile.get("build_interval_mult", 1.0)))
	var prod_iv := maxf(0.2, float(iv.get("production_interval_sec", 1.0))) \
		* maxf(0.1, float(profile.get("production_interval_mult", 1.0)))
	var strat_iv := maxf(0.5, float(iv.get("strategic_interval_sec", 2.0)))
	var revive_iv := maxf(0.2, float(profile.get("revive", {}).get("interval_sec", 0.75)))
	var cohesion_iv := maxf(0.2, float(profile.get("cohesion", {}).get("interval_sec", 1.2)))
	# 错开各 AI 的第一次决策，避免同一帧叠在一起。
	army_timer = world.unit_rand(faction, 1) * army_iv
	build_timer = world.unit_rand(faction, 2) * build_iv
	production_timer = world.unit_rand(faction, 3) * prod_iv
	strategic_timer = world.unit_rand(faction, 4) * strat_iv
	revive_timer = world.unit_rand(faction, 9) * revive_iv
	cohesion_next_at = world.time + world.unit_rand(faction, 10) * cohesion_iv
	_interval_army = army_iv
	_interval_build = build_iv
	_interval_production = prod_iv
	_interval_strategic = strat_iv
	_interval_revive = revive_iv
	_interval_cohesion = cohesion_iv
	stats = {
		"orders": 0, "order_failures": 0,
		"builds": 0, "build_failures": 0,
		"recruits": 0, "recruit_failures": 0,
		"techs": 0, "specs": 0, "revives": 0, "recalls": 0,
		"rotations": 0, "expands": 0, "assaults": 0,
		"zones_taken": 0, "regroups": 0, "avoids": 0,
		"role_retreats": 0, "counterattacks": 0,
		"scouts": 0, "guards": 0, "zone_guards": 0, "recruit_recalls": 0,
		"explores": 0,
	}
	patrol_index = 0
	var pat: Dictionary = profile.get("patrol", {})
	patrol_next_at = world.time + 2.0 \
		+ world.unit_rand(faction, 8) * maxf(2.0, float(pat.get("interval_sec", 9.0)))
	_refresh_zone_ownership(true)


var _interval_army: float = 0.6
var _interval_build: float = 2.5
var _interval_production: float = 1.0
var _interval_strategic: float = 2.0
var _interval_revive: float = 0.75
var _interval_cohesion: float = 1.2


## ★★ 当前「自然军队容量」：跟着「在场将领」走，而不是一个固定总数。
##
## ⚠️ 2026.10.24 起它**不再是生产闸门**（旧版按它的比例出兵，将领越快越多、上限越高，
##   结果永远追不上，AI 一直停在发展期）。现在的生产闸门是「每队目标规模」
##   （见 `_production_tick` 与 `AiArmyRes.recruit_candidates`）；这个函数只用于
##   面板显示与「不要超过自然容量」的兜底判断。
##
## 本作一个将领就是一支队的队长，每位将领的有效编制 = 兵种档位上限 + 大本营等级加成
## （`world.effective_retinue_cap()`）。所以：
##
##   自然容量 = Σ(1 + 该将领有效编制)          # 1 = 将领自己
##   实际上限 = round(自然容量 × army_cap_ratio) # 难度只乘一个比例
##
## 例：3 位 1 级将领、每人 11 编制 → 自然容量 36；普通 0.8 → 29。
##     10 位 3 级将领、每人 11+4=15 编制 → 自然容量 160；普通 0.8 → 128。
##
## ★ 难度里的 `army_cap` 只在「一个将领都没有」时兜底；有将领时它不会把上限压到
##   低于该将领真实能带的兵 —— 也不会让上限超过自然容量（否则生产会一直撞编制上限）。
func force_cap() -> int:
	if world == null:
		return maxi(1, army_cap)
	var natural := 0
	var leaders := 0
	for u in world.units:
		if not u.alive or String(u.faction) != faction:
			continue
		if not u.is_general():
			continue
		leaders += 1
		natural += 1 + int(world.effective_retinue_cap(u))
	if leaders <= 0:
		return maxi(1, army_cap)
	var ratio := clampf(float(profile.get("army_cap_ratio", 0.8)), 0.1, 1.0)
	var cap := int(round(float(natural) * ratio))
	return clampi(cap, 1, natural)


## ★★ 补将目标：按大本营等级取 [3, 6, 10]，再由大本营的 max_generals 封顶。
## 没有大本营 / 旧配置没有数组时退回 `production.general_target`（默认 2）。
func general_target() -> int:
	var pc: Dictionary = profile.get("production", {})
	var target := maxi(1, int(pc.get("general_target", 2)))
	var lv := 0
	if world != null:
		lv = int(world.base_level_of(faction))
	var arr: Variant = pc.get("general_target_by_base_level", [])
	if lv > 0 and typeof(arr) == TYPE_ARRAY and not (arr as Array).is_empty():
		var a: Array = arr
		target = int(a[clampi(lv - 1, 0, a.size() - 1)])
	if world != null:
		var hard := int(world.base_max_generals(faction))
		if hard > 0:
			target = mini(target, hard)
	return maxi(1, target)


func update(dt: float) -> void:
	if world == null or dt <= 0.0:
		return
	if world.is_neutralized_faction(faction):
		return
	_ensure_team_roles()
	_sync_order()
	army_timer -= dt
	build_timer -= dt
	production_timer -= dt
	strategic_timer -= dt
	revive_timer -= dt
	retry_timer = maxf(0.0, retry_timer - dt)
	general_try_timer = maxf(0.0, general_try_timer - dt)
	if revive_timer <= 0.0:
		revive_timer = _interval_revive
		_revive_tick()
	if strategic_timer <= 0.0:
		strategic_timer = _interval_strategic
		_strategic_tick()
	if production_timer <= 0.0:
		production_timer = _interval_production
		_production_tick()
	if build_timer <= 0.0:
		build_timer = _interval_build
		AiBuildRes.update(self)
	if army_timer <= 0.0:
		army_timer = _interval_army
		# ★ 这里要传**本次决策间隔**，不是帧 dt：army 层只用它推进回防冷却。
		#   传帧 dt 会让 20 秒冷却实际变成几分钟（每 0.6 秒才扣 0.016）。
		AiArmyRes.update(self, _interval_army)


## 玩家改了指令（或开局第一次）→ 丢掉旧的编组缓存，避免把「上一个目标的命令」当成新的。
## ★ 守军角色**不重置**：它是「谁看家」的持续角色，与玩家改指令无关。
func on_directive_changed() -> void:
	last_orders.clear()
	target_zone = -1
	expand_team_ids.clear()
	expand_started_at = 0.0
	assault_active = false
	assault_team_ids.clear()
	assault_until = 0.0
	failed_expand_zones.clear()
	regroup_ids.clear()
	scout_missions.clear()
	post_missions.clear()
	guard_missions.clear()
	react_next.clear()
	react_mode.clear()
	react_point.clear()
	react_until.clear()
	expand_hold = 0.0
	defend_until = 0.0
	threat_since = -1.0
	next_target_at = world.time if world != null else 0.0
	patrol_index = 0
	patrol_next_at = (world.time + 2.0) if world != null else 0.0
	explore_leader_id = ""
	explore_phase = ""
	explore_target = Vector2.ZERO
	explore_until = 0.0
	explore_away = false


func _sync_order() -> void:
	var d: Dictionary = world.ai_directive_of(faction)
	var s := int(d.get("serial", -1))
	if s == order_serial:
		return
	order_serial = s
	order_kind = String(d.get("kind", "auto"))
	order_x = float(d.get("x", -1.0))
	order_y = float(d.get("y", -1.0))
	on_directive_changed()


## ★★ 给新将领分配职能：按 `roles.cycle` 顺序轮换（确定性，不看 RNG）。
func _ensure_team_roles() -> void:
	var roles: Dictionary = profile.get("roles", {})
	var cycle: Array = roles.get("cycle", ["line"])
	if cycle.is_empty():
		cycle = ["line"]
	for u in world.units:
		if u == null or not u.alive or String(u.faction) != faction:
			continue
		if not u.is_general():
			continue
		var id := String(u.id)
		if team_roles.has(id):
			continue
		team_roles[id] = String(cycle[role_serial % cycle.size()])
		role_serial += 1


func team_role_of(leader) -> String:
	if leader == null:
		return ""
	return String(team_roles.get(String(leader.id), "line"))


## 远程队的「前排」= 队里非远程兵的数量（不含远程 / 攻城 / 粮车）。
func frontline_count(leader) -> int:
	if leader == null or not leader.alive:
		return 0
	var n := 0
	for m in world.retinue_of(String(leader.id), true):
		if m == null or not m.alive or m.is_downed():
			continue
		if not cfg.unit_is_ranged(String(m.unit_type)):
			n += 1
	return n


## ★★ 某个单位挨打：找到它所属的队伍，结合**当前任务**重新判断
## 「整队反击」还是「整队撤到安全区」，并立即重发整队命令。
##
## 绝不单独移动挨打的那一个兵 —— 这是「单位与部队脱轨」的正面修法。
##
## @return true = 指挥官接管了这次受击（world 不再走单兵复仇）。
##   即使这次因为冷却 / 没有队伍而不下新命令，也返回 true：队伍继续执行原命令，
##   但**绝不允许**某个兵自己切到单兵复仇状态。
func react_to_attacked(victim, attacker) -> bool:
	if world == null or victim == null or attacker == null:
		return false
	var leader = victim if victim.is_general() else world.unit_by_id(String(victim.leader_id))
	if leader == null or not leader.alive:
		return false
	# 队长倒地：全队正在救援集结，不要再给某个兵切单兵复仇。
	if leader.is_downed():
		return true
	if String(leader.faction) != faction:
		return false
	var lid := String(leader.id)
	var now: float = world.time
	var rc: Dictionary = profile.get("reaction", {})
	var cooldown := maxf(0.2, float(rc.get("cooldown_sec", 2.0)))
	var hold := maxf(cooldown, float(rc.get("mode_hold_sec", 2.8)))
	var base = world.find_base_of(faction)
	var retreating := bool(regroup_ids.get(lid, false))
	if base != null:
		var rally := Vector2(float(base.tx) + 1.5, float(base.ty) + 1.5)
		if bool(leader.has_attack_move) and leader.attack_move_goal.distance_to(rally) < 7.0:
			retreating = true
		# 撤退现在走**普通移动**（不是行军攻击），所以这里也要看 `goal`。
		elif bool(leader.moving) and leader.goal.distance_to(rally) < 7.0:
			retreating = true
	var mode := String(react_mode.get(lid, ""))
	var until := float(react_until.get(lid, 0.0))
	# 1) 硬冷却：短时间连续挨打不再重发即时命令。
	if now < float(react_next.get(lid, 0.0)):
		return true
	# 2) 模式锁：刚决定反击 / 撤退，锁定期内保持原命令。
	if now < until:
		return true
	# 3) 同一场交火：还是同一片攻击者，继续当前反击，不换目标。
	var lock_r := maxf(1.0, float(rc.get("counter_lock_radius", 6.0)))
	if mode == "counter" and bool(leader.has_attack_move) and react_point.has(lid):
		var prev: Vector2 = react_point[lid]
		if leader.attack_move_goal.distance_to(prev) <= lock_r \
				and attacker.pos.distance_to(prev) <= lock_r:
			react_next[lid] = now + cooldown
			react_until[lid] = now + hold
			return true
	# 4) 已经在撤退：继续撤，不因为又挨一下马上回头反击。
	if mode == "retreat" and retreating:
		react_next[lid] = now + cooldown
		react_until[lid] = now + hold
		return true
	react_next[lid] = now + cooldown
	var ours := float(AiArmyRes.team_total(self, leader))
	if ours <= 0.0:
		return false
	var radius := maxf(1.0, float(rc.get("danger_radius", 6.0)))
	# 决策看两处：攻击者身边（打回去要面对多少）和队伍身边（现在被多少贴脸）。
	var enemy_at := AiArmyRes._enemy_strength_near(self, attacker.pos, radius)
	var enemy_near := AiArmyRes._enemy_strength_near(self, leader.pos, radius)
	var enemy := maxf(enemy_at, enemy_near)
	var role := team_role_of(leader)
	var roles: Dictionary = profile.get("roles", {})
	# 侦察队的任务是「看见就回来报」，不是回头打；受击直接退。
	if scout_missions.has(lid):
		_retreat_whole_team(leader)
		return true
	# 远程队前排已经倒光：即使敌人不多也先退，别让远程被贴脸。
	if role == "ranged":
		var rcfg: Dictionary = roles.get("ranged", {})
		if frontline_count(leader) < int(rcfg.get("frontline_min", 1)):
			_retreat_whole_team(leader)
			return true
	# 游击队：被打就换空档，不和正规军纠缠。
	if role == "guerrilla":
		_retreat_whole_team(leader)
		return true
	var counter_ratio := maxf(0.1, float(rc.get("counter_ratio", 1.15)))
	var can_counter := enemy <= ours * counter_ratio
	# 正在撤退时只有明显更弱才回头；否则继续撤。
	if retreating and enemy > ours * maxf(0.1, float(rc.get("retreat_counter_ratio", 0.75))):
		can_counter = false
	if can_counter:
		var pt: Vector2 = attacker.pos
		if role == "ranged":
			pt = AiArmyRes._role_target_point(self, leader, pt)
		# 受击反应优先于侦察 / 驻守 / 守备：这些任务先让位。
		scout_missions.erase(lid)
		post_missions.erase(lid)
		guard_missions.erase(lid)
		# 大规模任务也要让位，否则下一 tick 原来那条「去区划中心 / 打大本营」的命令
		# 会把整队又拉走，表现成队伍在受击点与任务点之间来回抖。
		_drop_team_mission(lid)
		# `_order_team` 会先清掉各成员的单兵反击状态，再发整队行军攻击。
		if AiArmyRes._order_team(self, {"leader": leader, "units": world.group_of(leader)},
				pt, false, true):
			regroup_ids.erase(lid)
			react_mode[lid] = "counter"
			react_point[lid] = pt
			react_until[lid] = now + hold
			stats["counterattacks"] = int(stats.get("counterattacks", 0)) + 1
			note_status("counter")
			return true
		# 追不过去 / 没路：退回安全区，别让队伍原地分裂。
		_retreat_whole_team(leader)
		return true
	_retreat_whole_team(leader)
	return true


func _retreat_whole_team(leader) -> void:
	if leader == null:
		return
	var lid := String(leader.id)
	_drop_team_mission(lid)
	AiArmyRes._retreat_team(self, leader)
	regroup_ids[lid] = true
	var rc: Dictionary = profile.get("reaction", {})
	var cooldown := maxf(0.2, float(rc.get("cooldown_sec", 2.0)))
	react_mode[lid] = "retreat"
	react_point.erase(lid)
	react_until[lid] = world.time + maxf(cooldown, float(rc.get("mode_hold_sec", 2.8)))


## 把一支队伍从扩张 / 进攻任务里摘掉；任务空了就一起清掉，避免下一 tick 又把它拉走。
func _drop_team_mission(lid: String) -> void:
	if expand_team_ids.has(lid):
		expand_team_ids.erase(lid)
		if expand_team_ids.is_empty():
			AiArmyRes._clear_expand(self, true)
	if assault_team_ids.has(lid):
		assault_team_ids.erase(lid)
		if assault_team_ids.is_empty():
			AiArmyRes.clear_assault(self)


## ★★ 濒死将领：能再起就再起；位置太危险 / 太远且没兵时改为「召回」。
##
## 规则与玩家点按钮完全同源：`world.start_revive()` / `world.recall_general()`。
## 再起免费；召回会把旗下残兵静默清掉、将领阵亡并回大本营重生（10 秒，比正常 20 秒短）。
##
## 选召回而不是再起的情形（避免「在敌后光杆站起来」）：
##   · 倒在敌方区划里、身边活着的附属兵 ≤ `recall_escort_threshold`；
##   · 倒在离基地很远的地方、一个兵都没有、附近也没有友军；
##   · 附近有可见敌军，且自己兵少、又没有友军能接应。
## 其余情况：血量回到 `revive.ready_ratio` 就立刻再起。
func _revive_tick() -> void:
	if world == null:
		return
	var downs: Array = []
	for u in world.units:
		if u == null or not u.alive or String(u.faction) != faction:
			continue
		if not u.is_general() or not u.is_downed():
			continue
		if u.is_reviving():
			continue
		downs.append(u)
	if downs.is_empty():
		return
	for u in downs:
		var recalled := false
		if _should_recall(u):
			recalled = world.recall_general(String(u.id), faction)
			if recalled:
				stats["recalls"] = int(stats.get("recalls", 0)) + 1
				note_status("recalling")
		if recalled:
			continue
		if u.revive_ready(cfg):
			if world.start_revive(String(u.id), faction):
				stats["revives"] = int(stats.get("revives", 0)) + 1
				note_status("reviving")


func _should_recall(u) -> bool:
	var rv: Dictionary = profile.get("revive", {})
	var base = world.find_base_of(faction)
	if base == null:
		return false
	var escorts := _living_escorts(u)
	var friends := _friends_near(u, float(rv.get("danger_radius", 6.0)))
	var enemy := AiArmyRes._enemy_strength_near(self, u.pos,
		float(rv.get("danger_radius", 6.0)))
	var z = world.zones.zone_at(int(u.tx), int(u.ty))
	var in_enemy := false
	if z != null:
		var owner := String((z as Dictionary).get("owner", ""))
		in_enemy = owner != "" and not world.accepts_owner(owner, faction)
	var dist: float = u.pos.distance_to(Vector2(float(base.tx) + 0.5, float(base.ty) + 0.5))
	var escort_limit := int(rv.get("recall_escort_threshold", 1))
	var far := float(rv.get("recall_distance_tiles", 7.0))
	if in_enemy and escorts <= escort_limit and friends <= 0:
		return true
	if escorts <= 0 and dist >= far and friends <= 0:
		return true
	if enemy > 0.0 and escorts <= escort_limit and friends <= 0:
		return true
	if enemy > 0.0 and dist >= far and escorts <= escort_limit:
		return true
	return false


func _living_escorts(u) -> int:
	var n := 0
	for m in world.retinue_of(String(u.id), true):
		if m != null and m.alive and not m.is_downed():
			n += 1
	return n


func _friends_near(u, radius: float) -> int:
	var n := 0
	var r2 := maxf(0.0, radius) * maxf(0.0, radius)
	for o in world.units:
		if o == null or o == u or not o.alive or o.is_downed():
			continue
		# 自己的附属兵不算「附近友军」：召回本来就会把它们一起清掉，
		# 不能因为它们站在旁边就误以为有人接应。
		if String(o.leader_id) == String(u.id):
			continue
		if not world.accepts_owner(String(o.faction), faction):
			continue
		if o.pos.distance_squared_to(u.pos) <= r2:
			n += 1
	return n


func _strategic_tick() -> void:
	# 军队上限 / 状态文本这类轻量维护。真正的目标选择在 army 层（它要读战场）。
	# ★ 区划归属统计：每 2 秒对一次账，比在扩张任务里判更可靠
	#   （巡逻队 / 大队顺手站下来的地也要算「打下来了」）。
	_refresh_zone_ownership(false)


## 刷新「曾经归己方」的区划集合；非初始化时把新增的计入 `zones_taken`。
func _refresh_zone_ownership(initial: bool) -> void:
	if world == null or world.zones == null:
		return
	for z in world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != faction:
			continue
		var zid := int(zd.get("id", -1))
		if zid < 0 or _owned_zone_ids.has(zid):
			continue
		_owned_zone_ids[zid] = true
		if not initial:
			stats["zones_taken"] = int(stats.get("zones_taken", 0)) + 1


# ------------------------------------------------------------------
# 生产
# ------------------------------------------------------------------

## ★★ 生产：**按队补员**（2026.10.24 重做）。
##
## 旧版的问题（用户实测）：只有一位「固定生产将领」一路读条，兵力涨到 16，
## 其余将领各带 0 兵在外面巡逻 —— 既没有「招到合适数量就派出去」的节奏，
## 也制造了一堆光杆司令。
##
## 新口径：
##   1. 守军（`AiArmyRes.ensure_garrison`）先补到 `home_team_size`；补满后由
##      `maybe_rotate_garrison()` 换人，老守军变成外勤队出门；
##   2. 其余每支外勤队补到 `field_team_size`（含将领）就停，不再一路招到全族上限；
##   3. 同时读条的将领最多 `max_training_leaders` 个（不是「只有 1 个兵营」，
##      也不会全员读条）；
##   4. 补将前先看有没有「还没装备起来」的队伍：先给现有将领配兵，别急着造新的光杆。
func _production_tick() -> void:
	if retry_timer > 0.0:
		return
	# 1) 守军轮换（补满的守军换下来、由另一支接防）。
	AiArmyRes.ensure_garrison(self)
	AiArmyRes.maybe_rotate_garrison(self)
	# 2) 补将：只有「现有将领都至少有 1 个兵」时才考虑加新将。
	#    ⚠️ 旧版按「兵力 ≥ 上限 × 比例」才补将，而上限又随将领数上涨 ——
	#       结果永远追不上。现在只看「现有队伍是否装备好」。
	# ★ 2026.10.25：现有队伍至少补到「目标 - margin」才加新将，避免半编队旁边又冒光杆。
	# ★★ 2026.10.25：如果现在一支外勤队都没有（只有守军，或守军没成形），
	#   必须优先补一位将领出来当外勤队 —— 否则 `_expand / _scout / _patrol`
	#   全部没有可派的队伍，AI 会从 60 秒后一直闲置到守军补满为止。
	var has_field := not AiArmyRes.field_teams(self).is_empty()
	if world.general_count_of(faction) < general_target() \
			and (AiArmyRes.understaffed_team_count(self) <= 0 or not has_field):
		_try_general_recruit()
	# 3) 按队补员。
	var pc: Dictionary = profile.get("production", {})
	var max_training := maxi(1, int(pc.get("max_training_leaders", 2)))
	var training := AiArmyRes.training_leader_count(self)
	var attempts := maxi(1, int(profile.get("intervals", {}).get("production_attempts", 3)))
	var cands: Array = AiArmyRes.recruit_candidates(self)
	if cands.is_empty():
		return
	# ★★ 2026.10.25：一支「能出门」的外勤队都没有时，补员先补外勤队，
	#   不要再按守军优先把外勤将领晾在 1 个兵上 —— 否则它会一直不够
	#   `min_field_units`，扩张/侦察/巡逻全派不出去，AI 看起来在发呆。
	if AiArmyRes.ready_field_teams(self, AiArmyRes._min_units(self)).is_empty():
		cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var ga := bool(a.get("garrison", false))
			var gb := bool(b.get("garrison", false))
			if ga != gb:
				return not ga
			return float(a.get("prio", 0.0)) > float(b.get("prio", 0.0)))
	for c in cands:
		if attempts <= 0:
			break
		var cd: Dictionary = c
		var leader = cd.get("leader", null)
		if leader == null or not leader.alive:
			continue
		var deficit := int(cd.get("deficit", 0))
		if deficit <= 0:
			continue
		# 已经有两个将领在读条 ⇒ 不再开新坑；但允许继续给「已在读条」的将领排队。
		var was_training: bool = leader.is_training()
		if not was_training and training >= max_training:
			continue
		# 每队自己的排队上限（比全局 queue_max 更紧）：不要一口气排 5 个，
		# 留出「补到目标就出门」的节奏。
		var max_q := maxi(1, int(pc.get("max_queue_per_leader", 3)))
		if int(leader.train_queue_size()) >= max_q:
			continue
		var kind := _pick_kind(leader)
		if kind == "":
			break
		var reason := String(world.can_recruit(kind, String(leader.id), faction))
		if reason != "":
			if reason == "combat" or reason == "zone" or reason == "cap" \
					or reason == "queue_full":
				# 这个将领这一会儿不适合下单（在打架 / 不在己方地 / 满了）：
				# 换下一位候选，不要整体停工。
				continue
			# tier 差一档、兵种表异常：本轮不再试。
			break
		var afford := String(world.can_afford_recruit(kind, String(leader.id)))
		if afford != "":
			if afford == "population":
				# 人口是**区划局部**的：这个将领所在地没人口，换下一位（别的区划可能有）。
				continue
			# 钱是全局的：本轮不再试（换兵种也不会更便宜多少），等下一轮。
			retry_timer = maxf(0.5, float(profile.get("intervals", {}).get("retry_sec", 3.0)))
			break
		if world.start_recruit(kind, String(leader.id), faction):
			stats["recruits"] = int(stats.get("recruits", 0)) + 1
			attempts -= 1
			if not was_training:
				training += 1
			note_status("producing")
		else:
			stats["recruit_failures"] = int(stats.get("recruit_failures", 0)) + 1
			retry_timer = maxf(0.5, float(profile.get("intervals", {}).get("retry_sec", 3.0)))
			break


## 按编成权重抽一个兵种；过滤「没解锁 / 招不了 / 粮车已有」。
func _pick_kind(leader) -> String:
	var pc: Dictionary = profile.get("production", {})
	var role := team_role_of(leader)
	var roles: Dictionary = profile.get("roles", {})
	var rc: Dictionary = roles.get(role, {})
	var comp: Array = rc.get("composition", pc.get("composition", []))
	# ★ 远程队如果前排已经倒光：先补一个抗线兵，再继续抽远程。
	if role == "ranged" and frontline_count(leader) <= 0:
		var front := _first_frontline_kind(comp)
		if front != "":
			return front
	var hq := 0
	for u in world.units:
		if u.alive and String(u.faction) == faction and String(u.unit_type) == "grain_cart":
			hq += 1
	var cands: Array = []
	var total := 0.0
	for item in comp:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var kind := String((item as Dictionary).get("type", ""))
		var w := float((item as Dictionary).get("weight", 0.0))
		if kind == "" or w <= 0.0:
			continue
		if not world.is_unit_recruitable(kind):
			continue
		if not world.unit_recruit_unlocked(faction, kind):
			continue
		if kind == "grain_cart" and hq >= 1:
			continue
		cands.append({"type": kind, "weight": w})
		total += w
	if cands.is_empty() or total <= 0.0:
		# 兜底：表里第一个已解锁的兵种（绝不「一个都不招」）
		for item2 in world.recruit_list():
			if typeof(item2) != TYPE_DICTIONARY:
				continue
			var k2 := String((item2 as Dictionary).get("kind", ""))
			if k2 != "" and world.is_unit_recruitable(k2) and world.unit_recruit_unlocked(faction, k2):
				return k2
		return ""
	production_serial += 1
	var roll: float = float(world.unit_rand("%s|prod" % faction, production_serial)) * total
	var acc := 0.0
	var last := ""
	for c in cands:
		last = String((c as Dictionary).get("type", ""))
		acc += float((c as Dictionary).get("weight", 0.0))
		if roll <= acc:
			return last
	return last


## 远程队的前排优先从编成里挑；编成里没有可招的近战，再扫全兵种表。
func _first_frontline_kind(comp: Array) -> String:
	for item in comp:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var kind := String((item as Dictionary).get("type", ""))
		if kind == "" or kind == "grain_cart":
			continue
		if not cfg.unit_is_ranged(kind) \
				and world.is_unit_recruitable(kind) \
				and world.unit_recruit_unlocked(faction, kind):
			return kind
	for item2 in world.recruit_list():
		if typeof(item2) != TYPE_DICTIONARY:
			continue
		var k2 := String((item2 as Dictionary).get("kind", ""))
		if k2 == "" or k2 == "grain_cart":
			continue
		if not cfg.unit_is_ranged(k2) \
				and world.is_unit_recruitable(k2) \
				and world.unit_recruit_unlocked(faction, k2):
			return k2
	return ""


## 将领不足时，在**己方有人口的区划**补一位（区划招募）。钱不够 / 冷却 / 上限都会被世界拒。
##
## ★★ 不只试基地区划：扩张后新占的区划也有 1 点人口产出，只盯基地会在
##    「基地人口刚被兵吃光 / 基地人口上限低」时永远补不出将。按「基地优先、
##    其余区划按 id 顺序」稳定尝试，找到第一个能招的就入队。
func _try_general_recruit() -> void:
	if general_try_timer > 0.0:
		return
	general_try_timer = 5.0
	var want := general_target()
	if world.general_count_of(faction) >= want:
		return
	# ★★ 不固定在大本营：优先前线 / 被入侵区划，基地只是兜底。
	#    前线招出来的将领一开始没有兵，由 `_avoid_bad_fights()` 的「未成形队伍」规则
	#    在遇敌时整队后撤。
	for zid in _general_recruit_zones():
		for item in world.zone_recruit_list():
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var kind := String((item as Dictionary).get("kind", ""))
			if kind == "":
				continue
			if String(world.can_recruit_zone(kind, zid, faction)) != "":
				continue
			if String(world.can_afford_zone_recruit(kind, zid)) != "":
				continue
			if world.start_zone_recruit(kind, zid, faction):
				stats["generals"] = int(stats.get("generals", 0)) + 1
				note_status("producing")
			return


## 招将的区划顺序：被入侵 > 前线 > 大本营兜底 > 后方。
func _general_recruit_zones() -> Array[int]:
	var rows: Array = []
	var base = world.find_base_of(faction)
	var base_zid := int(base.zone_id) if base != null else -1
	for z in world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != faction:
			continue
		if zd.get("center", null) == null:
			continue
		var zid := int(zd.get("id", -1))
		if zid < 0:
			continue
		var score := _general_recruit_zone_score(zd, zid, base_zid)
		rows.append({"id": zid, "score": score})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := float(a["score"])
		var sb := float(b["score"])
		if absf(sa - sb) > 1e-9:
			return sa > sb
		return int(a["id"]) < int(b["id"]))
	var out: Array[int] = []
	for r in rows:
		out.append(int((r as Dictionary)["id"]))
	return out


func _general_recruit_zone_score(zd: Dictionary, zid: int, base_zid: int) -> float:
	var score := 0.0
	if AiBuildRes._zone_threatened(self, zd):
		score += 100.0
	elif AiBuildRes._zone_is_frontier(self, zd):
		score += 40.0
	else:
		score += 5.0
	if zid == base_zid:
		score += 10.0
	# 有人口才能招；这里只给一点点加权，不让基地因为人口多而永远压过前线。
	score += minf(3.0, float((zd as Dictionary).get("population", 0.0)))
	return score


# ------------------------------------------------------------------
# 对外状态
# ------------------------------------------------------------------

func note_status(text: String) -> void:
	status = text
	status_until = (world.time if world != null else 0.0) + 2.5


func current_status() -> String:
	if world != null and world.time <= status_until and status != "":
		return status
	match order_kind:
		"march":
			return "arrived" if _at_order_point() else "march"
		"mass":
			return "holding"
		"expand":
			return "expanding" if target_zone >= 0 else "expand"
		"auto":
			return "auto"
		_:
			return "develop"


func _at_order_point() -> bool:
	if not _has_order_point():
		return false
	var pt := Vector2(order_x, order_y)
	var n := 0
	for u in world.units:
		if not u.alive or String(u.faction) != faction or u.is_downed():
			continue
		n += 1
		if u.pos.distance_to(pt) > 6.0:
			return false
	return n > 0


func _has_order_point() -> bool:
	if world == null or world.map == null:
		return false
	return world.map.tile_exists(int(floor(order_x)), int(floor(order_y)))


func panel_state() -> Dictionary:
	var d: Dictionary = world.ai_directive_of(faction)
	var pool: Dictionary = AiEconomyRes.pool(self)
	var tx := int(floor(float(d.get("x", -1.0))))
	var ty := int(floor(float(d.get("y", -1.0))))
	var until := float(d.get("until", 0.0))
	var out := {
		"faction": faction,
		"name": world.faction_label_of(faction),
		"kind": "commander",
		"directive": String(d.get("kind", "auto")),
		"target": Vector2i(tx, ty),
		"serial": int(d.get("serial", 0)),
		"hold_left": maxf(0.0, until - world.time) if until > 0.0 else 0.0,
		"army": AiArmyRes.army_count(self),
		"army_cap": force_cap(),
		"army_cap_base": army_cap,
		"general_target": general_target(),
		"generals": world.general_count_of(faction),
		"food": float(pool.get("food", 0.0)),
		"gold": float(pool.get("gold", 0.0)),
		"status": current_status(),
		"reason": String(d.get("reason", "")),
		"roles": team_roles.duplicate(),
		"scouts": scout_missions.size(),
		"posts": post_missions.size(),
		"guards": post_missions.size() + guard_missions.size(),
	}
	return out


## 纯字典（测试 / 确定性 hash 用）：不含对象引用。
func debug_state() -> Dictionary:
	return {
		"faction": faction,
		"order": order_kind,
		"x": order_x,
		"y": order_y,
		"serial": order_serial,
		"target_zone": target_zone,
		"expand_teams": expand_team_ids.duplicate(),
		"garrison": garrison_leader_id,
		"army": AiArmyRes.army_count(self),
		"cap": force_cap(),
		"general_target": general_target(),
		"roles": team_roles.duplicate(),
		"scouts": scout_missions.size(),
		"posts": post_missions.size(),
		"guards": post_missions.size() + guard_missions.size(),
		"stats": stats.duplicate(true),
		"food": AiEconomyRes.food(self),
		"gold": AiEconomyRes.gold(self),
		"time": world.time if world != null else 0.0,
	}
