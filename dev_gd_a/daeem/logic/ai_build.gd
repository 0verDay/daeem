## ai_build.gd —— 指挥官 AI 的建造 / 升级 / 科技 / 区划特化。
##
## 一次 `update(ai)` = 一个「建造尝试」周期（由控制器按 build_interval 调）。
## 顺序：大本营升级 → 科技 → 区划特化 → 箭塔。
##
## ★ 硬约束永远先于评分：钱、前置、上限、地块合法、正在读条。
## ★ 被拒的地块进 `ai.blocked_tiles`，避免每帧重试同一格（那会刷事件、也拖慢）。
## ★ 不直接改 world：建造 / 升级 / 科技都走 `command_processor` 或 world 的公开入口。
extends RefCounted

const CommandRes = preload("res://logic/command_processor.gd")
const FactionRes = preload("res://logic/faction.gd")
const GridRes = preload("res://logic/grid.gd")
const EconomyRes = preload("res://logic/economy.gd")
const AiEconomyRes = preload("res://logic/ai_economy.gd")
const AiArmyRes = preload("res://logic/ai_army.gd")


static func update(ai) -> void:
	_try_base_upgrade(ai)
	_try_tech(ai)
	_try_spec(ai)
	var paused := _defense_paused(ai)
	if paused:
		# 缺编时把钱留给补员；只有区划真被入侵才紧急补城墙。
		if _any_own_threat(ai):
			_try_wall(ai)
		return
	# 防御升级每 4 次建造动作穿插一次；有升级机会时先升级再花在造墙上。
	var do_upgrade := int(ai.stats.get("builds", 0)) % 4 == 0
	if do_upgrade:
		var up: Dictionary = _defense_upgrade_candidate(ai)
		if not up.is_empty():
			var ucost: Dictionary = up.get("cost", {})
			var ugold := float(ucost.get("gold", 0.0))
			var avail: Dictionary = _build_available(ai)
			var gold_now := float(avail.get("gold", 0.0))
			if ugold > 0.0 and gold_now < ugold:
				if gold_now >= ugold * 0.75:
					if float(ai.build_save_until) <= 0.0:
						ai.build_save_until = ai.world.time + 8.0
						return
					if ai.world.time < float(ai.build_save_until):
						return
					ai.build_save_until = 0.0
			else:
				ai.build_save_until = 0.0
				_try_defense_upgrade(ai)
	# 塔优先，其次补墙；升级在上面已经先手。
	_try_tower(ai)
	_try_wall(ai)
	# 钱明显花不完时，同一周期继续补塔 / 补墙 / 升级，别只攒钱。
	if AiEconomyRes.float_excess(ai):
		_try_tower(ai)
		_try_wall(ai)
		if do_upgrade:
			_try_defense_upgrade(ai)


# ------------------------------------------------------------------
# 大本营升级
# ------------------------------------------------------------------

static func _try_base_upgrade(ai) -> void:
	var b = ai.world.find_base_of(ai.faction)
	if b == null or not b.alive:
		return
	if not ai.world.building_can_upgrade(String(b.type)):
		return
	if b.is_upgrading():
		return
	if int(b.level) >= ai.world.building_max_level(String(b.type)):
		return
	var cost: Dictionary = ai.world.building_upgrade_cost(b)
	if not AiEconomyRes.can_afford_above_reserve(ai, cost):
		return
	if not CommandRes.apply(ai.world, ai.cfg, {
			"kind": "building_upgrade", "tx": b.tx, "ty": b.ty, "faction": ai.faction}):
		ai.stats["build_failures"] = int(ai.stats.get("build_failures", 0)) + 1
		return
	ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
	ai.note_status("building")


# ------------------------------------------------------------------
# 科技
# ------------------------------------------------------------------

static func _try_tech(ai) -> void:
	if ai.world.tech == null:
		return
	if ai.world.tech_remaining_slots(ai.faction) <= 0:
		return
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var priority: Array = build_cfg.get("tech_priority", [])
	var candidates: Array = []
	# 先按配置里的优先级，再补表里其余的（避免「优先级表为空 = 永远不点科技」）
	for id in priority:
		candidates.append(String(id))
	for item in ai.world.tech_list():
		if typeof(item) == TYPE_DICTIONARY:
			var tid := String((item as Dictionary).get("id", ""))
			if tid != "" and not candidates.has(tid):
				candidates.append(tid)
	for id2 in candidates:
		if ai.world.is_tech_active(id2, ai.faction):
			continue
		if ai.tech_attempted.has(id2):
			continue
		if String(ai.world.tech_can_activate(id2, ai.faction)) != "":
			continue
		if CommandRes.apply(ai.world, ai.cfg, {
				"kind": "tech_toggle", "tech_id": id2, "on": true, "faction": ai.faction}):
			ai.stats["techs"] = int(ai.stats.get("techs", 0)) + 1
			return
		# 失败（大本营等级 / 槽位刚好变了）：记下来，别每轮重试同一条。
		ai.tech_attempted[id2] = true
		return


# ------------------------------------------------------------------
# 区划特化
# ------------------------------------------------------------------

static func _try_spec(ai) -> void:
	var zones: Variant = ai.world.zones
	if zones == null:
		return
	for z in zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if String(zd.get("spec_done", "")) != "":
			continue
		if ai.world.zone_spec_busy(zd):
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		var zid := int(zd.get("id", -1))
		if zid < 0 or ai.spec_attempted.has(zid):
			continue
		var choices: Array = ai.world.zone_spec_choices(zd)
		if choices.is_empty():
			continue
		var pick := _pick_spec(ai, zd, choices)
		if pick == "":
			continue
		var cost: Dictionary = ai.cfg.spec_cost(pick)
		if not AiEconomyRes.can_afford_above_reserve(ai, cost):
			return
		if ai.world.start_zone_specialize(zid, pick, ai.faction):
			ai.stats["specs"] = int(ai.stats.get("specs", 0)) + 1
			ai.note_status("building")
			return
		ai.spec_attempted[zid] = true
		return


## 按「缺什么补什么」选一档特化（粮食 / 黄金 / 人口）。
## ★ 只有 `zone_kind` 白名单允许的那几档会出现在 choices 里。
static func _pick_spec(ai, zone: Dictionary, choices: Array) -> String:
	var has_food := false
	var has_gold := false
	var has_pop := false
	for c in choices:
		var id := String((c as Dictionary).get("id", ""))
		if id == "food":
			has_food = true
		elif id == "gold":
			has_gold = true
		elif id == "population":
			has_pop = true
	# 人口区划优先人口特化；其余按粮食 / 黄金哪一个更缺。
	var kind := String(ai.world.zone_kind_of(zone))
	if kind == "population" and has_pop:
		return "population"
	if has_food and has_gold:
		return "food" if AiEconomyRes.food(ai) <= AiEconomyRes.gold(ai) else "gold"
	if has_food:
		return "food"
	if has_gold:
		return "gold"
	if has_pop:
		return "population"
	return ""


# ------------------------------------------------------------------
# 箭塔
# ------------------------------------------------------------------

static func _try_tower(ai) -> void:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var hard_max := int(build_cfg.get("tower_hard_max",
		build_cfg.get("tower_max", 24)))
	if hard_max <= 0:
		return
	if _tower_count(ai) >= hard_max:
		return
	if _tower_count(ai) >= _tower_target(ai):
		return
	var cost: Dictionary = {}
	var def_v: Variant = ai.cfg.building_def("tower")
	if typeof(def_v) == TYPE_DICTIONARY:
		var cv: Variant = (def_v as Dictionary).get("cost", {})
		if typeof(cv) == TYPE_DICTIONARY:
			cost = cv
	if not _defense_afford(ai, cost, build_cfg):
		return
	var zone = _pick_tower_zone(ai)
	if zone == null:
		return
	var tile: Variant = _pick_tower_tile(ai, zone)
	if tile == null:
		return
	var t: Vector2i = tile
	if CommandRes.apply(ai.world, ai.cfg, {
			"kind": "build", "build_type": "tower",
			"tx": t.x, "ty": t.y, "faction": ai.faction}):
		ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
		ai.note_status("building")
	else:
		ai.stats["build_failures"] = int(ai.stats.get("build_failures", 0)) + 1
		ai.blocked_tiles[t] = true


static func _try_wall(ai) -> void:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("wall_enabled", true)):
		return
	var hard_max := int(build_cfg.get("wall_hard_max", 100))
	if hard_max <= 0 or _wall_count(ai) >= hard_max:
		return
	var cost: Dictionary = {}
	var def_v: Variant = ai.cfg.building_def("wall")
	if typeof(def_v) == TYPE_DICTIONARY:
		var cv: Variant = (def_v as Dictionary).get("cost", {})
		if typeof(cv) == TYPE_DICTIONARY:
			cost = cv
	if not _defense_afford(ai, cost, build_cfg):
		return
	var zone = _pick_wall_zone(ai)
	if zone == null:
		return
	var missing := _missing_wall_tiles(ai, zone)
	if missing.is_empty():
		return
	var t: Vector2i = missing[0]
	if CommandRes.apply(ai.world, ai.cfg, {
			"kind": "build", "build_type": "wall",
			"tx": t.x, "ty": t.y, "faction": ai.faction}):
		ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
		ai.stats["walls_built"] = int(ai.stats.get("walls_built", 0)) + 1
		ai.note_status("building")
	else:
		ai.stats["build_failures"] = int(ai.stats.get("build_failures", 0)) + 1
		ai.blocked_tiles[t] = true


static func _wall_count(ai) -> int:
	var n := 0
	for b in ai.world.building_list:
		if b.alive and String(b.type) == "wall" and String(b.owner) == ai.faction:
			n += 1
	return n


## 区划中心的 3×3 外圈（8 格）。城墙就把这一圈围起来。
static func _wall_ring_tiles(ai, zone: Dictionary) -> Array:
	var out: Array = []
	var cv: Variant = zone.get("center", null)
	if cv == null:
		return out
	var c: Vector2i = cv
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var t := Vector2i(c.x + dx, c.y + dy)
			if ai.world.map.tile_exists(t.x, t.y):
				out.append(t)
	return out


static func _missing_wall_tiles(ai, zone: Dictionary) -> Array:
	var out: Array = []
	for t in _wall_ring_tiles(ai, zone):
		var tv: Vector2i = t
		if ai.world.building_at(tv.x, tv.y) != null:
			continue
		if not ai.world.can_build_at(tv.x, tv.y, ai.faction):
			continue
		out.append(tv)
	return out


static func _pick_wall_zone(ai):
	var best = null
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		var threatened := _zone_threatened(ai, zd)
		if not threatened and not _zone_is_frontier(ai, zd):
			continue
		var missing := _missing_wall_tiles(ai, zd)
		if missing.is_empty():
			continue
		var score := float(missing.size()) * 5.0
		if threatened:
			score += 100.0
		else:
			score += 30.0
		if score > best_score:
			best_score = score
			best = zd
	return best


## 生产预留：先把下一轮补员 / 补将的钱留住，剩下的才允许造防御建筑。
static func _production_reserve(ai) -> Dictionary:
	var eco: Dictionary = ai.profile.get("economy", {})
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var rf := float(eco.get("reserve_food", 80.0))
	var rg := float(eco.get("reserve_gold", 80.0))
	var under := AiArmyRes.understrength_team_count(ai)
	if under > 0:
		var n := maxi(1, int(build_cfg.get("production_reserve_recruits", 3)))
		var c: Dictionary = AiEconomyRes.cheapest_cost(ai)
		if c.is_empty():
			c = {"food": 50.0, "gold": 50.0}
		rf += float(c.get("food", 0.0)) * float(n)
		rg += float(c.get("gold", 0.0)) * float(n)
	elif ai.world.general_count_of(ai.faction) < ai.general_target():
		var g: Dictionary = _general_cost(ai)
		rf += float(g.get("food", 0.0))
		rg += float(g.get("gold", 0.0))
	return {"food": rf, "gold": rg}


static func _general_cost(ai) -> Dictionary:
	var best: Dictionary = {}
	var best_sum := INF
	for item in ai.world.zone_recruit_list():
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var kind := String((item as Dictionary).get("kind", ""))
		if kind == "":
			continue
		var c: Dictionary = ai.world.recruit_cost(kind)
		var s := float(c.get("food", 0.0)) + float(c.get("gold", 0.0))
		if s < best_sum:
			best_sum = s
			best = c
	if best.is_empty():
		return {"food": 50.0, "gold": 50.0}
	return best


## 扣掉「保命 reserve + 下一轮生产 reserve」后，真正能花在建筑上的资源。
static func _build_available(ai) -> Dictionary:
	var r: Dictionary = _production_reserve(ai)
	return {
		"food": maxf(0.0, AiEconomyRes.food(ai) - float(r.get("food", 0.0))),
		"gold": maxf(0.0, AiEconomyRes.gold(ai) - float(r.get("gold", 0.0))),
	}


## 有队伍缺编时暂停防御建造，先把钱留给补员 / 补将。
static func _defense_paused(ai) -> bool:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("pause_defense_when_understrength", true)):
		return false
	return AiArmyRes.understrength_team_count(ai) > 0


static func _any_own_threat(ai) -> bool:
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) == ai.faction and _zone_threatened(ai, zd):
			return true
	return false


## 防御建筑（塔 / 墙 / 升级）的 affordability：必须留够生产预留。
static func _defense_afford(ai, cost: Dictionary, _build_cfg: Dictionary = {}) -> bool:
	if cost.is_empty():
		return true
	var avail: Dictionary = _build_available(ai)
	for k in cost.keys():
		if float(avail.get(String(k), 0.0)) < float(cost[k]):
			return false
	return true


## 选出当前最该升级的塔 / 墙（只选，不扣钱）。
static func _defense_upgrade_candidate(ai) -> Dictionary:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("defense_upgrade_enabled", true)):
		return {}
	var best = null
	var best_score := -INF
	for b in ai.world.building_list:
		if b == null or not b.alive or String(b.owner) != ai.faction:
			continue
		var bt := String(b.type)
		if bt != "tower" and bt != "wall":
			continue
		if b.is_upgrading():
			continue
		if not ai.world.building_can_upgrade(bt):
			continue
		var max_lv: int = ai.world.building_max_level(bt)
		if int(b.level) >= max_lv:
			continue
		var zid := int(b.zone_id)
		if zid < 0:
			continue
		var zd = ai.world.zone_by_id(zid)
		if zd == null:
			continue
		var threatened := _zone_threatened(ai, zd)
		var front := _zone_is_frontier(ai, zd)
		if not threatened and not front:
			continue
		var deficit: int = max_lv - int(b.level)
		var score := float(deficit) * 10.0
		if threatened:
			score += 100.0
		else:
			score += 30.0
		if bt == "wall" and not _missing_wall_tiles(ai, zd).is_empty():
			score += 8.0
		if bt == "tower":
			score += float(build_cfg.get("defense_upgrade_tower_bonus", 12.0))
		if score > best_score:
			best_score = score
			best = b
	if best == null:
		return {}
	return {"b": best, "cost": ai.world.building_upgrade_cost(best)}


## 升级前线 / 受威胁区划的箭塔和城墙。
static func _try_defense_upgrade(ai) -> void:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("defense_upgrade_enabled", true)):
		return
	var pick: Dictionary = _defense_upgrade_candidate(ai)
	if pick.is_empty():
		return
	var best = pick["b"]
	var cost: Dictionary = pick.get("cost", {})
	if not _defense_afford(ai, cost, build_cfg):
		return
	if CommandRes.apply(ai.world, ai.cfg, {
			"kind": "building_upgrade", "tx": best.tx, "ty": best.ty,
			"faction": ai.faction}):
		ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
		ai.stats["upgrades"] = int(ai.stats.get("upgrades", 0)) + 1
		ai.note_status("building")


static func _tower_count(ai) -> int:
	var n := 0
	for b in ai.world.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == ai.faction:
			n += 1
	return n


static func _tower_count_in_zone(ai, zid: int) -> int:
	var n := 0
	for b in ai.world.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == ai.faction \
				and int(b.zone_id) == zid:
			n += 1
	return n


## ★★ 战略目标：前线多、后方少；被入侵的区划再加码。
## 不再限制「一个区划只能一塔」——每个区划按自己的战略角色算目标数量。
static func _tower_target(ai) -> int:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var hard_max := int(build_cfg.get("tower_hard_max",
		build_cfg.get("tower_max", 24)))
	var total := 0
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		total += _zone_tower_target(ai, zd)
	return mini(total, hard_max)


static func _zone_tower_target(ai, zd: Dictionary) -> int:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var rich := _rich_tower_bonus(ai)
	if _zone_threatened(ai, zd):
		return maxi(0, int(build_cfg.get("tower_threat_towers", 5)) + rich)
	if _zone_is_frontier(ai, zd):
		return maxi(0, int(build_cfg.get("tower_front_towers", 3)) + rich)
	return maxi(0, int(build_cfg.get("tower_rear_towers", 0)))


## 资源浮存越多，允许在前线 / 受威胁区划多补几座塔（不是乱铺）。
static func _rich_tower_bonus(ai) -> int:
	var eco: Dictionary = ai.profile.get("economy", {})
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var cap := maxi(0, int(build_cfg.get("tower_rich_bonus_max", 3)))
	if cap <= 0:
		return 0
	var gold := AiEconomyRes.gold(ai)
	var food := AiEconomyRes.food(ai)
	var gold_line := maxf(100.0, float(eco.get("max_float_gold", 600.0)))
	var food_line := maxf(100.0, float(eco.get("max_float_food", 600.0)))
	var mult := maxf(gold / gold_line, food / food_line)
	if mult >= 3.0:
		return cap
	if mult >= 2.0:
		return mini(cap, 2)
	if mult >= 1.0:
		return mini(cap, 1)
	return 0


## 区划当前是不是被入侵 / 正在被敌对占领。
static func _zone_threatened(ai, zd: Dictionary) -> bool:
	var center: Variant = zd.get("center", null)
	if center == null:
		return false
	var bar: Dictionary = ai.world.zones.capture_bar(zd)
	var st := String(bar.get("state", ""))
	if st == "reading" or st == "frozen":
		var f := String(bar.get("faction", ""))
		if f != "" and not FactionRes.same_side(f, ai.faction):
			return true
	var c: Vector2i = center
	var pt := GridRes.center_of(c)
	var zid := int(zd.get("id", -1))
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var radius := maxf(1.0, float(build_cfg.get("tower_threat_radius", 9.0)))
	var r2 := radius * radius
	for u in ai.world.units:
		if u == null or not u.alive or u.is_downed():
			continue
		if FactionRes.same_side_for_attack(String(u.faction), ai.faction):
			continue
		if ai.world.fog != null and not ai.world.fog.logic_unit_visible(ai.faction, u):
			continue
		# 敌人在这个区划里的任何位置都算入侵；此外中心附近 9 格也算。
		var uz = ai.world.zones.zone_at(int(u.tx), int(u.ty))
		if uz != null and int((uz as Dictionary).get("id", -1)) == zid:
			return true
		if u.pos.distance_squared_to(pt) <= r2:
			return true
	return false


## ★★ 选一个「目标数量还没满」的己方区划。被入侵的区划优先级最高；
## 其次是有缺口的前线；后方目标通常为 0（但配置调大后也能建）。
static func _pick_tower_zone(ai):
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var best = null
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		var zid := int(zd.get("id", -1))
		var desired := _zone_tower_target(ai, zd)
		var current := _tower_count_in_zone(ai, zid)
		var deficit := desired - current
		if deficit <= 0:
			continue
		var threatened := _zone_threatened(ai, zd)
		var score := float(deficit) * 10.0
		if threatened:
			score += 100.0
		elif _zone_is_frontier(ai, zd):
			score += float(build_cfg.get("tower_frontier_bonus", 4.0))
		var c: Vector2i = zd["center"]
		var base = ai.world.find_base_of(ai.faction)
		if base != null:
			score -= Vector2(float(c.x - base.tx), float(c.y - base.ty)).length() * 0.05
		if score > best_score or (is_equal_approx(score, best_score) \
				and (best == null or zid < int((best as Dictionary).get("id", -1)))):
			best_score = score
			best = zd
	return best


static func _zone_is_frontier(ai, zone: Dictionary) -> bool:
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


## 这个区划里「贴着非己方地块」的边界格 —— 箭塔要压的方向。
static func _frontier_tiles(ai, zone: Dictionary) -> Array:
	var out: Array = []
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var owner := String((oz as Dictionary).get("owner", ""))
			if owner == "" or not FactionRes.same_side_for_attack(owner, ai.faction):
				out.append(tv)
				break
	return out


## 已知敌方区划中心（公开信息）；用来判断「哪一侧是敌人」。
static func _enemy_zone_points(ai) -> Array:
	var out: Array = []
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		var owner := String(zd.get("owner", ""))
		if owner == "" or FactionRes.same_side_for_attack(owner, ai.faction):
			continue
		var cv: Variant = zd.get("center", null)
		if cv == null:
			continue
		var ct: Vector2i = cv
		out.append(Vector2(float(ct.x) + 0.5, float(ct.y) + 0.5))
	return out


## ★★ 在一个区划里挑箭塔位置：
##   · 被入侵 ⇒ 尽量贴着中心（2~3 格；1 格留给城墙环），方便补防；
##   · 平时在前线 ⇒ 往「靠敌方的那条边界」压，优先能覆盖更多边界格的位置；
##   · 不做「隔一格 / 最近建过就跳过」的人为限制，位置完全由战术评分决定。
static func _pick_tower_tile(ai, zone: Dictionary) -> Variant:
	var center: Variant = zone.get("center", null)
	if center == null:
		return null
	var c: Vector2i = center
	var zid := int(zone.get("id", -1))
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var threatened := _zone_threatened(ai, zone)
	var dmax := 4 if threatened else 8
	var cover_radius := maxi(1, int(build_cfg.get("tower_cover_radius", 4)))
	var wall_enabled := bool(build_cfg.get("wall_enabled", true))
	var reserve_ring := wall_enabled and (threatened or _zone_is_frontier(ai, zone))
	var frontier := _frontier_tiles(ai, zone)
	var enemy_pts := _enemy_zone_points(ai)
	var pool: Array = []
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		if ai.blocked_tiles.has(tv):
			continue
		var d := maxi(absi(tv.x - c.x), absi(tv.y - c.y))
		if d < 1 or d > dmax:
			continue
		# 1 格环留给城墙，不拿塔去占围墙位。
		if reserve_ring and d <= 1:
			continue
		if not ai.world.can_build_at(tv.x, tv.y, ai.faction):
			continue
		if ai.world.building_at(tv.x, tv.y) != null:
			continue
		# 到最近边界格 / 最近敌方区划中心的距离，以及能覆盖多少边界格。
		var front_edge := 999
		for ft in frontier:
			var fv: Vector2i = ft
			front_edge = mini(front_edge,
				maxi(absi(fv.x - tv.x), absi(fv.y - tv.y)))
		if not threatened and not frontier.is_empty() and front_edge > 4:
			continue
		var enemy_d := 9999.0
		for ep in enemy_pts:
			var ev: Vector2 = ep
			enemy_d = minf(enemy_d, Vector2(float(tv.x) + 0.5,
				float(tv.y) + 0.5).distance_to(ev))
		var coverage := 0
		for ft in frontier:
			var fv: Vector2i = ft
			if maxi(absi(fv.x - tv.x), absi(fv.y - tv.y)) <= cover_radius:
				coverage += 1
		var score := 0.0
		if threatened:
			# 中心附近 + 覆盖边界：补防优先。
			score = -absf(float(d) - 2.0) * 12.0 + float(coverage) * 2.0
			score -= enemy_d * 0.2
		elif not frontier.is_empty():
			# 前线：贴敌方边界，且尽量一塔覆盖多段边。
			score = -float(front_edge) * 15.0 + float(coverage) * 1.0
			score -= enemy_d * 0.4
			score -= absf(float(d) - 3.0) * 0.5
		else:
			score = -float(d) * 3.0
		pool.append({"tile": tv, "score": score})
	if pool.is_empty():
		return null
	pool.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa := float(a["score"])
		var sb := float(b["score"])
		if absf(sa - sb) > 1e-9:
			return sa > sb
		var ta: Vector2i = a["tile"]
		var tb: Vector2i = b["tile"]
		if ta.y != tb.y:
			return ta.y < tb.y
		return ta.x < tb.x)
	return (pool[0] as Dictionary)["tile"]
