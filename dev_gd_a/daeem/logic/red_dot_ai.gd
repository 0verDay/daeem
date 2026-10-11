## red_dot_ai.gd —— **红点性 AI**：按**函数式时间表**在地图指定区域刷「满编将领」的一波敌人。
##
## 需求原文（逐条对照）：
##   1. 「生成满编的随机单位，附属到其旗下」——
##      → 每位红点将领**当场**生成 `escort_count` 个附属兵（满编），兵种按
##        `escort_types` 的权重**随机**抽（`world.fill_general_retinue()`，
##        与「关卡摆放的将领开局带兵」是同一条路）。
##   2. 「生成频率 = y 和 x 的函数表达式（y = 波次时间 / min，x = 波次）」——
##      → `wave_time_expr`（默认 `x`），`logic/expr.gd` 解析 `y = a·x + b`。
##        例：`x` → 第 1 波 1min、第 2 波 2min；`x+1` → 第 1 波 2min、第 2 波 3min。
##   3. 「生成的将领数 = 函数表达式」—— → `general_count_expr`（默认 `x`）。
##   4. 「将领类型和权重」—— → `general_weights`（每项 `{general, weight}`）。
##   5. 「选中地图地块作为红点生成地块」—— → `spawn_tiles`（优先于 `spawn_region` / 出生点）。
##
## ★★ 与阵地性 AI（`logic/garrison_ai.gd`）的分工：
##   · 阵地性 —— 附属于区划、原地巡逻、无消耗招兵（守卫）；
##   · 红点性 —— 无归属区划、按时间表刷一波、然后一路行军（进攻）。
##   两者判据互斥：红点刷出来的将领 `garrison_zone_id < 0` ⇒ 阵地 AI 不会碰它们。
##
## ★ 参数来自 `world.reddot_ai_cfg(fid)`（config `ai.reddot` ⊕ 关卡 `reddot_ai` 覆盖）。
## ★ 状态放在 `world.reddot_states`（每项一个字典）——它是**世界状态的一部分**。
##
## ⚠️ 跨文件引用只用**本文件里的 preload 常量**（`--script` 下全局 class_name 不可用）。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const GridRes = preload("res://logic/grid.gd")
const LevelRes = preload("res://logic/level.gd")
const FactionRes = preload("res://logic/faction.gd")
const UnitRes = preload("res://logic/unit.gd")
const BuildingRes = preload("res://logic/building.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const ExprRes = preload("res://logic/expr.gd")
const CommandProcessorRes = preload("res://logic/command_processor.gd")


## ★★ 建出这一局该跑的红点 AI（由 `world.reset()` 在所有单位就位之后调一次）。
##
## @return Array[Dictionary]，每项：
##   {faction, params, spawn_region, elapsed, wave_index, waves_cap, serial}
##
## 名单来自 `world.ai_roster_cfg`（关卡点名优先 + config 兜底，唯一实现在 logic/level.gd）。
## 只收 `ai == "reddot"` 的那些，且**玩家在操作的那一方不建**。
static func setup(world, cfg: ConfigRes) -> Array:
	var out: Array = []
	for item in world.ai_roster_cfg:
		var entry: Dictionary = item
		var fid := String(entry.get("id", ""))
		if fid == "":
			continue
		if world.player_factions.has(fid):
			continue                        # 玩家在操作这一方 ⇒ 运行时把它的 AI 摘掉
		if String(entry.get("ai", LevelRes.AI_NONE)) != LevelRes.AI_REDDOT:
			continue
		var params: Dictionary = world.reddot_ai_cfg(fid)
		out.append({
			"faction": fid,
			"params": params,
			# 生成区域：关卡 `spawn_region`（没写 → 用这一方的出生点当锚、默认半径）。
			"spawn_region": entry.get("spawn_region", null),
			# ★ 从 0 起累计时间；第 x 波在 `wave_time_expr(x)` 分钟到点（x 从 1 起）。
			"elapsed": 0.0,
			"wave_index": 0,
			# 波数上限：0 = 无限（默认）；> 0 = 只刷这么多波。
			"waves_cap": maxi(0, int(params.get("waves", 0))),
			"serial": 0,
		})
	return out


## 每帧推进所有红点 AI：把「时间已到」的波依次发出去。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if dt <= 0.0 or world.reddot_states.is_empty():
		return
	for st in world.reddot_states:
		st["elapsed"] = float(st.get("elapsed", 0.0)) + dt
		var params: Dictionary = st["params"]
		var wave_expr := String(params.get("wave_time_expr", "x"))
		var count_expr := String(params.get("general_count_expr", "x"))
		var cap: int = int(st.get("waves_cap", 0))
		# ★ 一帧里可能跨过好几个到点时间（dt 大 / train_sec 小 / 快进）⇒ 用 while 补发。
		var guard := 0
		while guard < 64:
			guard += 1
			var next_wave: int = int(st.get("wave_index", 0)) + 1
			if cap > 0 and next_wave > cap:
				break
			var t_min := ExprRes.eval_linear(wave_expr, float(next_wave))
			if is_nan(t_min):
				t_min = float(next_wave)     # 表达式坏了 → 退回默认 'x'（每 1 分钟一波）
			if t_min * 60.0 > float(st["elapsed"]):
				break
			st["wave_index"] = next_wave
			_launch_wave(world, cfg, st, next_wave, count_expr)


## 刷一波：`general_count_expr(wave)` 位满编将领（类型按 `general_weights` 抽），
## 每位当场带 `escort_count` 个随机附属兵，一起行军攻击目标点。
##
## ★ 出生点、目标点都可能在**没有**数据 / 全被占住时取不到 —— 取不到就**不发这一波**
##   （下一帧重试），绝不对着空坐标刷。
static func _launch_wave(world, cfg: ConfigRes, st: Dictionary, wave: int, count_expr: String) -> void:
	var faction := String(st["faction"])
	var params: Dictionary = st["params"]
	var goal = _resolve_target(world, faction)
	if goal == null:
		return
	var goal_pt: Vector2 = GridRes.center_of(goal)
	# 将领数：y = general_count_expr(wave)，四舍五入；解析失败 → 1 位。
	var raw := ExprRes.eval_linear(count_expr, float(wave))
	var count: int = 1
	if not is_nan(raw):
		count = maxi(1, int(round(raw)))
	var escort_count: int = maxi(0, int(params.get("escort_count", 0)))
	var escort_types: Array = params.get("escort_types", [])
	var general_weights: Array = params.get("general_weights", [])
	var region: Variant = st.get("spawn_region", null)
	var spawn_tiles: Array = params.get("spawn_tiles", [])
	var serial: int = int(st.get("serial", 0))
	var sent := 0
	for n in count:
		var tile := _pick_spawn_tile(world, cfg, faction, region, spawn_tiles, n)
		if tile.x < 0:
			continue                        # 这一波这一位没地方站 —— 跳过它
		var gi := _pick_general_index(world, general_weights, serial, n)
		var g = _spawn_general(world, cfg, faction, gi, serial, n, tile)
		if g == null:
			continue
		# ★★ 满编的随机附属单位：规格写进单位，并**当场生成**。
		if escort_count > 0:
			g.retinue_target = escort_count
			g.retinue_types = escort_types
			world.fill_general_retinue(g, escort_count, escort_types)
		# 整队行军攻击（与玩家 / 阵地 AI 同一条命令路径）。
		if CommandProcessorRes.order_group_attack_move(world, cfg, world.group_of(g), goal_pt):
			sent += 1
	st["serial"] = serial + 1
	if sent > 0:
		world.push_event({
			"type": "red_dot_wave",
			"faction": faction,
			"wave": wave,
			"leaders": sent,
			"x": int(goal.x),
			"y": int(goal.y),
		})


## 按 `general_weights` 抽这一位将领的**类型序号**（0 起）。
##
## @param general_weights `[{ "general": 1..3, "weight": <float> }]`
##   · 空表 / 权重和 ≤ 0 → 退回旧行为 `n % 3`（够用且可预测）；
##   · 否则按权重抽（种子由 `(serial, n)` 派生，可复现）。
static func _pick_general_index(world, general_weights: Array, serial: int, n: int) -> int:
	var total := 0.0
	for e in general_weights:
		if typeof(e) == TYPE_DICTIONARY:
			total += float((e as Dictionary).get("weight", 0.0))
	if total <= 0.0:
		return maxi(0, n % 3)
	var roll: float = float(world.unit_rand("reddot-general|%d" % serial, n)) * total
	var acc := 0.0
	var last := 0
	for e in general_weights:
		var d: Dictionary = e
		var gi := maxi(0, int(d.get("general", 1)) - 1)
		last = gi
		acc += float(d.get("weight", 0.0))
		if roll <= acc:
			return gi
	return last


## 造一位红点将领（唯一 id，避免多波之间撞名）。
##
## ★ 用 `UnitRes.create` 直接造（不走 `world.create_general`）：后者的 id 是
##   canonical 的 `general-<fid>-N`，多波会重复；红点将领是**一次性**的，需要唯一 id。
## ★ `general_index` 由权重抽定（决定它套哪一份数值覆盖 / 用哪个兵种）。
static func _spawn_general(world, cfg: ConfigRes, faction: String, gi: int,
		serial: int, n: int, tile: Vector2i):
	var gname: String = cfg.general_name_at(gi)
	if gname == "":
		gname = "将领 %d" % (gi + 1)
	var utype: String = cfg.general_type_at(gi)
	var uid := "reddot-%s-%d-%d" % [faction, serial, n]
	var g = UnitRes.create(cfg, uid, gname, tile, faction, UnitRes.KIND_GENERAL,
		str(gi + 1), "", utype, gi)
	if g == null:
		return null
	world.units.append(g)
	return g


## 挑一个生成格：优先关卡选的**红点生成地块**（`spawn_tiles`），
## 否则退回 `spawn_region`（point+radius / zone），再否则用这一方的出生点。
##
## ★ 只挑**能站人**的格（可通行 + 无建筑 + 没被这一波已生成的单位占住）。
static func _pick_spawn_tile(world, cfg: ConfigRes, faction: String,
		region: Variant, spawn_tiles: Array, n: int) -> Vector2i:
	# 1) 关卡选中的红点生成地块（从第 n 个开始轮着挑，避免几个将领挤同一格）。
	if not spawn_tiles.is_empty():
		var sz := spawn_tiles.size()
		for k in sz:
			var tt := _tile_of_any(spawn_tiles[(n + k) % sz])
			if _can_stand(world, cfg, faction, tt):
				return tt
	# 2) 退回 spawn_region / 出生点。
	var radius: float = float(world.reddot_ai_cfg(faction).get("spawn_radius", 4.0))
	var anchor: Vector2i = world.home_base_of(faction)
	var tiles: Array = []
	if typeof(region) == TYPE_DICTIONARY:
		var rd: Dictionary = region
		var kind := String(rd.get("kind", ""))
		if kind == "zone":
			var z = world.zone_by_id(int(rd.get("zone", -1)))
			if z != null:
				tiles = (z as Dictionary).get("tiles", [])
		elif kind == "point":
			anchor = Vector2i(int(rd.get("x", anchor.x)), int(rd.get("y", anchor.y)))
			radius = float(rd.get("radius", radius))
	if not tiles.is_empty():
		for t in tiles:
			var tt2: Vector2i = t
			if _can_stand(world, cfg, faction, tt2):
				return tt2
	return _ring_walkable(world, cfg, faction, anchor, maxi(0, int(radius)))


## 把 `spawn_tiles` / `spawn_region` 里的一个坐标项归一成 Vector2i（认 `[x,y]` / 字典 / Vector2i）。
static func _tile_of_any(t: Variant) -> Vector2i:
	if typeof(t) == TYPE_VECTOR2I:
		return t
	if typeof(t) == TYPE_ARRAY and (t as Array).size() >= 2:
		return Vector2i(int((t as Array)[0]), int((t as Array)[1]))
	if typeof(t) == TYPE_DICTIONARY:
		var d: Dictionary = t
		return Vector2i(int(d.get("x", -1)), int(d.get("y", -1)))
	return Vector2i(-1, -1)


## 以 `anchor` 为心、`radius` 格为半径，由近到远找第一个能站人的格（找不到 → (-1,-1)）。
static func _ring_walkable(world, cfg: ConfigRes, faction: String,
		anchor: Vector2i, radius: int) -> Vector2i:
	if _can_stand(world, cfg, faction, anchor):
		return anchor
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue                # 只看这一圈
				var t := Vector2i(anchor.x + dx, anchor.y + dy)
				if _can_stand(world, cfg, faction, t):
					return t
	return Vector2i(-1, -1)


## 这一格现在能不能站人（可通行 + 没有建筑 + 没被部队占住）。
static func _can_stand(world, cfg: ConfigRes, faction: String, t: Vector2i) -> bool:
	if not world.map.tile_exists(t.x, t.y):
		return false
	if not PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, faction):
		return false
	if world.building_at(t.x, t.y) != null:
		return false
	return not world._tile_taken(t, null)


## 行军目标点：**先问关卡数据**（`attack_target`），没写就退回「离这一方最近的敌方区划中心 /
## 敌方大本营」—— 与旧的阵营 AI 同一条口径（盟友的地 / 家不算敌方）。
static func _resolve_target(world, faction: String) -> Variant:
	if world.has_method("level_attack_target"):
		var t: Variant = world.level_attack_target(faction)
		if t != null:
			return t
	return _default_target(world, faction)


static func _default_target(world, faction: String) -> Variant:
	if world.zones == null:
		return null
	var home: Vector2i = world.home_base_of(faction)
	var best: Variant = null
	var best_d := INF
	for z in world.zones.zones:
		var owner := String((z as Dictionary)["owner"])
		if owner == "" or FactionRes.same_side_for_attack(owner, faction):
			continue
		var c: Variant = (z as Dictionary).get("center", null)
		if c == null:
			continue
		var d: float = GridRes.octile_distance((c as Vector2i).x - home.x, (c as Vector2i).y - home.y)
		if d < best_d:
			best_d = d
			best = c
	if best != null:
		return best
	for b in world.building_list:
		if not b.alive or b.type != BuildingRes.TYPE_BASE:
			continue
		if FactionRes.same_side_for_attack(String(b.owner), faction):
			continue
		var d2: float = GridRes.octile_distance(b.tx - home.x, b.ty - home.y)
		if d2 < best_d:
			best_d = d2
			best = Vector2i(b.tx, b.ty)
	return best
