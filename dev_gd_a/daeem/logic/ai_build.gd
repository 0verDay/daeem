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


static func update(ai) -> void:
	_try_base_upgrade(ai)
	_try_tech(ai)
	_try_spec(ai)
	_try_tower(ai)


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
	var max_towers: int = int(build_cfg.get("tower_max", 4))
	if max_towers <= 0:
		return
	if _tower_count(ai) >= max_towers:
		return
	var cost: Dictionary = {}
	var def_v: Variant = ai.cfg.building_def("tower")
	if typeof(def_v) == TYPE_DICTIONARY:
		var cv: Variant = (def_v as Dictionary).get("cost", {})
		if typeof(cv) == TYPE_DICTIONARY:
			cost = cv
	if not AiEconomyRes.can_afford_above_reserve(ai, cost):
		return
	var zone = _pick_frontier_zone(ai)
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


static func _tower_count(ai) -> int:
	var n := 0
	for b in ai.world.building_list:
		if b.alive and String(b.type) == "tower" and String(b.owner) == ai.faction:
			n += 1
	return n


## 选一块「己方、且与敌方 / 中立区划相邻」的区划；优先没有箭塔的。
static func _pick_frontier_zone(ai):
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
		if _zone_has_tower(ai, int(zd.get("id", -1))):
			continue
		if not _zone_is_frontier(ai, zd):
			continue
		var score: float = 1.0
		var build_cfg: Dictionary = ai.profile.get("build", {})
		score += float(build_cfg.get("tower_frontier_bonus", 4.0))
		# 靠近基地的区划加分（更容易守）
		var base = ai.world.find_base_of(ai.faction)
		if base != null:
			var c: Variant = zd.get("center", null)
			if c != null:
				var ct: Vector2i = c
				score -= Vector2(float(ct.x - base.tx), float(ct.y - base.ty)).length() * 0.1
		if score > best_score:
			best_score = score
			best = zd
	return best


static func _zone_has_tower(ai, zid: int) -> bool:
	for b in ai.world.building_list:
		if not b.alive or String(b.type) != "tower":
			continue
		if int(b.zone_id) == zid and String(b.owner) == ai.faction:
			return true
	return false


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


## 在区划里挑一格能建箭塔的位置：离中心 2~5 格、可通行、没建筑、没被黑名单。
static func _pick_tower_tile(ai, zone: Dictionary) -> Variant:
	var center: Variant = zone.get("center", null)
	if center == null:
		return null
	var c: Vector2i = center
	var best: Variant = null
	var best_score := -INF
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		if ai.blocked_tiles.has(tv):
			continue
		var d := maxi(absi(tv.x - c.x), absi(tv.y - c.y))
		if d < 2 or d > 5:
			continue
		if not ai.world.can_build_at(tv.x, tv.y, ai.faction):
			continue
		if ai.world.building_at(tv.x, tv.y) != null:
			continue
		# 离中心越近越好（守塔）；同一距离取坐标小的（确定性）
		var score := -float(d) * 10.0 - float(tv.x) * 0.001 - float(tv.y) * 0.0001
		if score > best_score:
			best_score = score
			best = tv
	return best
