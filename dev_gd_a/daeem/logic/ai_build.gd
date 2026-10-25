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
	# ★★ 2026.10.25 资源顺序：部队发展（生产预留）> 升本 > 建造建筑。
	#   只要大本营还有下一级可升，就先尝试升本；这一轮没升成（钱不够）就
	#   **攒钱**，不把余钱花到科技 / 特化 / 塔 / 墙 / 升级上。
	#   大本营满级 / 正在读条 / 正在重生 / 被占领区封锁时，才轮到后面的建造。
	var base_pick: Dictionary = _base_upgrade_candidate(ai)
	if not base_pick.is_empty():
		_try_base_upgrade(ai)
		return
	_try_tech(ai)
	_try_spec(ai)
	# ★★ 2026.10.25：不再用「缺编就整段跳过建造」的硬闸门。
	#   生产预留（`_production_reserve`）先把当前可生产缺口的钱全部扣掉，
	#   建造只能用**扣完补员预算之后的余钱**：这才是「造部队始终优先」，
	#   同时资源真的很多时仍能用富余造塔 / 封边。
	#   `_defense_paused()` 仍保留给测试 / 面板判断，但不再阻断整个建造周期。
	# ★★ 2026.10.25：塔优先于墙 —— 这一 tick 只要真的造了塔，就不再花墙的钱。
	#   等塔目标都满足（或暂时造不了）才轮到中心环 / 边境长墙。
	#   升级放在后面：升级的「攒钱」分支不能把这一 tick 的塔挤掉。
	_try_tower_then_walls(ai)
	# 防御升级每 4 次建造动作穿插一次。
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
	# 钱明显花不完时，同一周期继续补塔 / 补墙 / 升级，别只攒钱。
	if AiEconomyRes.float_excess(ai):
		_try_tower_then_walls(ai)
		if do_upgrade:
			_try_defense_upgrade(ai)


## 先尝试造一座塔；**只有塔这一 tick 没造出来**才允许碰墙。
static func _try_tower_then_walls(ai) -> void:
	var before := _tower_count(ai)
	_try_tower(ai)
	if _tower_count(ai) > before:
		return
	# 塔位还在、只是钱不够：攒钱等塔，不拿这笔钱去造墙。
	if _should_save_for_tower(ai):
		return
	_try_wall_ring(ai)
	_try_border_walls(ai, _wall_border_budget(ai))


# ------------------------------------------------------------------
# 大本营升级
# ------------------------------------------------------------------

## 下一次大本营升级的候选（含成本）。空 = 现在不需要 / 不能升。
## ★ 只做「是否可升级」的结构性判断，不检查部队预留后的余钱；
##   affordability 由 `_try_base_upgrade()` / `update()` 统一判断。
static func _base_upgrade_candidate(ai) -> Dictionary:
	var b = ai.world.find_base_of(ai.faction)
	if b == null or not b.alive or b.neutralized:
		return {}
	if not ai.world.building_can_upgrade(String(b.type)):
		return {}
	if b.is_upgrading() or b.is_respawning():
		return {}
	if int(b.level) >= ai.world.building_max_level(String(b.type)):
		return {}
	# 将领挡位不足时不算「可升本」：先把将领补到 3 / 6，再回来升。
	var need_generals: int = int(ai.cfg.upgrade_limit("base", int(b.level), "max_generals", 0))
	if need_generals > 0 \
			and ai.world.general_count_of(ai.faction) < need_generals:
		return {}
	# 大本营所在区划正被踩占领区：先防守，不升级（也不为它囤钱）。
	if _zone_capture_blocked(ai, ai.world.zones.zone_at(b.tx, b.ty)):
		return {}
	return {"b": b, "cost": ai.world.building_upgrade_cost(b)}


## @return true = 真的开始了大本营升级
static func _try_base_upgrade(ai) -> bool:
	var pick: Dictionary = _base_upgrade_candidate(ai)
	if pick.is_empty():
		return false
	var b = pick["b"]
	var cost: Dictionary = pick.get("cost", {})
	# ★ 资源顺序：部队发展（生产预留）> 升本 > 其它建筑。
	if not _defense_afford(ai, cost):
		return false
	if not CommandRes.apply(ai.world, ai.cfg, {
			"kind": "building_upgrade", "tx": b.tx, "ty": b.ty, "faction": ai.faction}):
		ai.stats["build_failures"] = int(ai.stats.get("build_failures", 0)) + 1
		return false
	ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
	ai.note_status("building")
	return true


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
		if _zone_capture_blocked(ai, zd):
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
		# ★ 2026.10.25：区划特化也走生产预留 —— 先补兵，再谈经济建筑。
		if not _defense_afford(ai, cost):
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
	var cost: Dictionary = _tower_cost(ai)
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


static func _tower_cost(ai) -> Dictionary:
	var cost: Dictionary = {}
	var def_v: Variant = ai.cfg.building_def("tower")
	if typeof(def_v) == TYPE_DICTIONARY:
		var cv: Variant = (def_v as Dictionary).get("cost", {})
		if typeof(cv) == TYPE_DICTIONARY:
			cost = cv
	return cost


## 塔目标还没满、也确实有塔位，但这一 tick 钱不够 —— 此时不许拿钱去造墙，
## 先攒着把塔造出来。这是「造箭塔优先于造城墙」的硬保证。
static func _should_save_for_tower(ai) -> bool:
	if _tower_count(ai) >= _tower_target(ai):
		return false
	var zone = _pick_tower_zone(ai)
	if zone == null:
		return false
	if _pick_tower_tile(ai, zone) == null:
		return false
	return not _defense_afford(ai, _tower_cost(ai))


## 兼容入口：中心环优先，然后按富足门槛补边境长墙（一次最多 `wall_border_per_tick`）。
static func _try_wall(ai) -> void:
	_try_wall_ring(ai)
	_try_border_walls(ai, _wall_border_budget(ai))


static func _try_wall_ring(ai) -> void:
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
		if _zone_capture_blocked(ai, zd):
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


# ------------------------------------------------------------------
# ★★ 2026.10.25：边境封墙（前线优先，资源极富后扩到全境）
# ------------------------------------------------------------------

## 本 tick 允许铺几格边境墙：0 = 条件不满足。
static func _wall_border_budget(ai) -> int:
	if not _wall_border_ready(ai):
		return 0
	var build_cfg: Dictionary = ai.profile.get("build", {})
	return maxi(1, int(build_cfg.get("wall_border_per_tick", 3)))


## 边境墙的硬条件：开关、总墙数余量、资源富足、没有光杆将领。
##
## ★ 补员预算由 `_build_available()` 统一先扣；这里只看「富足 + 没有光杆将领」。
##   资源真的多到扣完补员预算还有余钱时，封边不会和造兵抢钱。
## ★ 只把「一个兵都没有的将领」当红线：连 1 个护卫都没有的队伍先补人，
##   有 1~2 个兵的缺编队不算（它们会被派去驻守，见 ai_army）。
static func _wall_border_ready(ai) -> bool:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("wall_enabled", true)):
		return false
	if not bool(build_cfg.get("wall_border_enabled", true)):
		return false
	if int(build_cfg.get("wall_hard_max", 100)) <= 0:
		return false
	if _wall_count(ai) >= _wall_border_limit(ai):
		return false
	if _wall_border_rich_ratio(ai) < maxf(0.1, float(build_cfg.get("wall_border_rich_mult", 1.5))):
		return false
	if bool(build_cfg.get("wall_border_require_armed_generals", true)) \
			and _bare_general_count(ai) > 0:
		return false
	return true


## 边境墙最多占用的总墙数：给中心环留出 `wall_border_keep_slots` 个空位，
## 免得「长墙铺满上限、新占的区划反而补不了中心环」。
static func _wall_border_limit(ai) -> int:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var hard := maxi(0, int(build_cfg.get("wall_hard_max", 100)))
	var keep := maxi(0, int(build_cfg.get("wall_border_keep_slots", 16)))
	return maxi(0, hard - keep)


## 浮存倍数：粮 / 金各自相对 `max_float_*` 的最大值（1.0 = 现有「钱花不完」线）。
static func _wall_border_rich_ratio(ai) -> float:
	var eco: Dictionary = ai.profile.get("economy", {})
	var food_line := maxf(100.0, float(eco.get("max_float_food", 600.0)))
	var gold_line := maxf(100.0, float(eco.get("max_float_gold", 600.0)))
	return maxf(AiEconomyRes.food(ai) / food_line, AiEconomyRes.gold(ai) / gold_line)


## 资源富足到「全境」档了吗？不到就只封与敌方接壤的前线。
static func _border_scope_all(ai) -> bool:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var full := maxf(0.1, float(build_cfg.get("wall_border_full_rich_mult", 3.0)))
	return _wall_border_rich_ratio(ai) >= full


## 一个「完全没有护卫、也没有在排队」的将领数。只用于边境墙的软闸门。
static func _bare_general_count(ai) -> int:
	var n := 0
	for u in ai.world.units:
		if u == null or not u.alive or String(u.faction) != ai.faction:
			continue
		if u.is_downed() or not u.is_general():
			continue
		if String(u.leader_id) != "":
			continue
		if ai.world.retinue_of(String(u.id), true).is_empty() \
				and int(u.train_queue_size()) <= 0:
			n += 1
	return n


## 铺最多 `max_builds` 格边境墙。每次重新选点（墙线会越来越长，评分会跟着变）。
static func _try_border_walls(ai, max_builds: int) -> void:
	if max_builds <= 0 or not _wall_border_ready(ai):
		return
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var cost: Dictionary = {}
	var def_v: Variant = ai.cfg.building_def("wall")
	if typeof(def_v) == TYPE_DICTIONARY:
		var cv: Variant = (def_v as Dictionary).get("cost", {})
		if typeof(cv) == TYPE_DICTIONARY:
			cost = cv
	# 本 tick 的单位占位只采一次：铺三格墙时不要每格都把 units 扫一遍。
	var occupied := _unit_tiles(ai)
	var built := 0
	var attempts := 0
	var attempt_cap := maxi(1, max_builds * 4)
	while built < max_builds and attempts < attempt_cap:
		attempts += 1
		if _wall_count(ai) >= _wall_border_limit(ai):
			break
		if not _defense_afford(ai, cost, build_cfg):
			break
		var tile: Variant = _pick_border_wall_tile(ai, occupied)
		if tile == null:
			break
		var t: Vector2i = tile
		if CommandRes.apply(ai.world, ai.cfg, {
				"kind": "build", "build_type": "wall",
				"tx": t.x, "ty": t.y, "faction": ai.faction}):
			ai.stats["builds"] = int(ai.stats.get("builds", 0)) + 1
			ai.stats["walls_built"] = int(ai.stats.get("walls_built", 0)) + 1
			ai.stats["walls_border"] = int(ai.stats.get("walls_border", 0)) + 1
			ai.note_status("building")
			built += 1
		else:
			# 只拉黑这一格，继续找下一格；不因为一个格子失败就整轮停手。
			ai.stats["build_failures"] = int(ai.stats.get("build_failures", 0)) + 1
			ai.blocked_tiles[t] = true


## 从所有合格区划的边境格里选一格：**先封与敌方接壤的前线**，没有前线缺口
## 才轮得到中立边；同一档里优先接上已有墙线，其次隘口 / 敌人方向。
static func _pick_border_wall_tile(ai, occupied: Dictionary) -> Variant:
	var front: Variant = _pick_border_wall_tile_pass(ai, occupied, true)
	if front != null:
		return front
	if _border_scope_all(ai):
		return _pick_border_wall_tile_pass(ai, occupied, false)
	return null


static func _pick_border_wall_tile_pass(ai, occupied: Dictionary,
		require_enemy_facing: bool) -> Variant:
	var full := _border_scope_all(ai)
	var best: Variant = null
	var best_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		if _zone_capture_blocked(ai, zd):
			continue
		var enemy_facing := _zone_enemy_facing(ai, zd)
		if require_enemy_facing and not enemy_facing:
			continue
		if not require_enemy_facing and enemy_facing:
			continue
		var threatened := _zone_threatened(ai, zd)
		for t in _border_wall_tiles(ai, zd, full, occupied):
			var tv: Vector2i = t
			var score := _border_tile_score(ai, zd, tv, threatened, enemy_facing)
			if score > best_score + 1e-9:
				best_score = score
				best = tv
			elif absf(score - best_score) <= 1e-9 and best != null:
				var bv: Vector2i = best
				if tv.y < bv.y or (tv.y == bv.y and tv.x < bv.x):
					best = tv
	return best


## 自己的边境格：四邻里至少有一个「同一格不属于本区划、可通行、且不是同方」的地块。
## @param allow_neutral false = 只留与敌方区划接壤的边（前期只封前线）。
static func _border_wall_tiles(ai, zone: Dictionary, allow_neutral: bool,
		occupied: Dictionary) -> Array:
	var out: Array = []
	var zid := int(zone.get("id", -1))
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		if ai.blocked_tiles.has(tv):
			continue
		if not ai.world.map.tile_exists(tv.x, tv.y):
			continue
		if not ai.world.can_build_at(tv.x, tv.y, ai.faction):
			continue
		if ai.world.building_at(tv.x, tv.y) != null:
			continue
		if occupied.has(tv):
			continue
		var has_exit := false
		var has_enemy_exit := false
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
			# 水 / 山本身就是屏障，不用再花一格墙。
			if not ai.world.map.terrain_walkable(n.x, n.y):
				continue
			has_exit = true
			if owner != "":
				has_enemy_exit = true
		if not has_exit:
			continue
		if not allow_neutral and not has_enemy_exit:
			continue
		out.append(tv)
	return out


## 单格边境墙的评分：已有墙邻接 > 出口多 / 隘口 > 受威胁 / 靠敌方 > 离基地近。
static func _border_tile_score(ai, zone: Dictionary, t: Vector2i,
		threatened: bool, enemy_facing: bool) -> float:
	var wall4 := 0
	var wall8 := 0
	var passable8 := 0
	for d in GridRes.DIRS8:
		var n: Vector2i = t + d
		if not ai.world.map.tile_exists(n.x, n.y):
			continue
		if ai.world.map.terrain_walkable(n.x, n.y):
			passable8 += 1
		var b = ai.world.building_at(n.x, n.y)
		if b != null and b.alive and String(b.type) == "wall" and String(b.owner) == ai.faction:
			wall8 += 1
			if d.x == 0 or d.y == 0:
				wall4 += 1
	var exits := 0
	for d in GridRes.DIRS4:
		var n2: Vector2i = t + d
		if not ai.world.map.tile_exists(n2.x, n2.y):
			continue
		var oz = ai.world.zones.zone_at(n2.x, n2.y)
		if oz == null:
			continue
		var zd: Dictionary = oz
		if int(zd.get("id", -1)) == int(zone.get("id", -1)):
			continue
		var owner := String(zd.get("owner", ""))
		if owner != "" and FactionRes.same_side_for_attack(owner, ai.faction):
			continue
		if ai.world.map.terrain_walkable(n2.x, n2.y):
			exits += 1
	var score := float(wall4) * 18.0 + float(wall8) * 5.0
	score += float(maxi(0, 8 - passable8)) * 5.0
	score += float(exits) * 8.0
	if threatened:
		score += 60.0
	if enemy_facing:
		score += 10.0
	var cv: Variant = zone.get("center", null)
	if cv != null:
		var c: Vector2i = cv
		score -= Vector2(float(t.x - c.x), float(t.y - c.y)).length() * 0.05
	var base = ai.world.find_base_of(ai.faction)
	if base != null:
		score -= Vector2(float(t.x - base.tx), float(t.y - base.ty)).length() * 0.08
	return score


## 这个区划有没有邻格属于敌方（不是中立、也不是同方）。
static func _zone_enemy_facing(ai, zone: Dictionary) -> bool:
	for t in (zone.get("tiles", []) as Array):
		var tv: Vector2i = t
		for d in GridRes.DIRS4:
			var n: Vector2i = tv + d
			if not ai.world.map.tile_exists(n.x, n.y):
				continue
			var oz = ai.world.zones.zone_at(n.x, n.y)
			if oz == null:
				continue
			var owner := String((oz as Dictionary).get("owner", ""))
			if owner != "" and not FactionRes.same_side_for_attack(owner, ai.faction):
				return true
	return false


## 本 tick 所有活单位占的格（避免把墙盖在自家 / 敌方单位脚下）。
static func _unit_tiles(ai) -> Dictionary:
	var out: Dictionary = {}
	for u in ai.world.units:
		if u == null or not u.alive or u.is_downed():
			continue
		out[Vector2i(int(u.tx), int(u.ty))] = true
	return out


## 生产预留：先把「现在真的能造出来」的补员缺口全部留住，剩下的才允许建造。
##
## ★★ 2026.10.25：从「固定留 3 单」改成「按当前可生产缺口留」。
##   用户口径是**造部队始终优先**：有 5 支缺编队、每支缺 3 个兵时，
##   不能只留 3 个兵的钱，否则塔 / 墙 / 升级会一路把补员预算吃掉。
## ★ 只算 `pending_recruit_units()`（脱战 / 人口够 / 未满编 / 队列没满）：
##   被人口或战斗卡住的队伍留钱也没用，不能因此把建造永久锁死。
static func _production_reserve(ai) -> Dictionary:
	var eco: Dictionary = ai.profile.get("economy", {})
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var rf := float(eco.get("reserve_food", 80.0))
	var rg := float(eco.get("reserve_gold", 80.0))
	var pending := AiArmyRes.pending_recruit_units(ai)
	var under := AiArmyRes.understrength_team_count(ai)
	if pending > 0 or under > 0:
		var n := maxi(1, int(build_cfg.get("production_reserve_recruits", 6)))
		n = maxi(n, pending)
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


## 有缺编队伍时暂停防御建造，先把钱留给补员 / 补将。
static func _defense_paused(ai) -> bool:
	var build_cfg: Dictionary = ai.profile.get("build", {})
	if not bool(build_cfg.get("pause_defense_when_understrength", true)):
		return false
	return AiArmyRes.understrength_team_count(ai) > 0


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
	var tower_target_met := _tower_count(ai) >= _tower_target(ai)
	for b in ai.world.building_list:
		if b == null or not b.alive or String(b.owner) != ai.faction:
			continue
		var bt := String(b.type)
		if bt != "tower" and bt != "wall":
			continue
		# ★ 2026.10.25：塔目标还没建满时，不升级墙（钱先留给塔）。
		if bt == "wall" and not tower_target_met:
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
		if _zone_capture_blocked(ai, zd):
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
			# ★ 2026.10.25：塔升级永远排在墙升级前面（与「塔优先于墙」同一条口径）。
			score += 1000.0 + float(build_cfg.get("defense_upgrade_tower_bonus", 12.0))
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
## 区划是否被敌方踏进中心 3×3 占领区 —— 这时整块区划不能建造。
static func _zone_capture_blocked(ai, zd) -> bool:
	if ai == null or ai.world == null or zd == null:
		return false
	if not ai.world.has_method("zone_capture_blocked"):
		return false
	return bool(ai.world.zone_capture_blocked(zd, ai.faction))


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
## 其次是有缺口的前线；**只要有前线缺口，后方区划就完全不考虑**。
## 后方目标通常为 0（但配置调大后也能建；仍然排在前线之后）。
static func _pick_tower_zone(ai):
	var build_cfg: Dictionary = ai.profile.get("build", {})
	var front_best = null
	var front_score := -INF
	var rear_best = null
	var rear_score := -INF
	for z in ai.world.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != ai.faction:
			continue
		if zd.get("center", null) == null:
			continue
		# 区划正被踩占领区：不选它造塔，先打退敌人。
		if _zone_capture_blocked(ai, zd):
			continue
		var zid := int(zd.get("id", -1))
		var desired := _zone_tower_target(ai, zd)
		var current := _tower_count_in_zone(ai, zid)
		var deficit := desired - current
		if deficit <= 0:
			continue
		var threatened := _zone_threatened(ai, zd)
		var frontier := _zone_is_frontier(ai, zd)
		var score := float(deficit) * 10.0
		if threatened:
			score += 100.0
		elif frontier:
			score += float(build_cfg.get("tower_frontier_bonus", 4.0))
		var c: Vector2i = zd["center"]
		var base = ai.world.find_base_of(ai.faction)
		if base != null:
			score -= Vector2(float(c.x - base.tx), float(c.y - base.ty)).length() * 0.05
		if threatened or frontier:
			if score > front_score or (is_equal_approx(score, front_score) \
					and (front_best == null or zid < int((front_best as Dictionary).get("id", -1)))):
				front_score = score
				front_best = zd
		else:
			if score > rear_score or (is_equal_approx(score, rear_score) \
					and (rear_best == null or zid < int((rear_best as Dictionary).get("id", -1)))):
				rear_score = score
				rear_best = zd
	return front_best if front_best != null else rear_best


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
