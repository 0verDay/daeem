## red_dot_ai.gd —— **红点性 AI**：按**长冷却**在地图指定区域刷「满编将领」的一波敌人。
##
## 需求原文（逐条对照）：
##   1. 「有冷却且冷却时间较长地在地图的特定区域生成若干满编将领」
##      → 每个红点阵营一条状态（`world.reddot_states`），计时器到点就**一次性**刷
##        `ai.reddot.generals` 位将领；每位将领**当场自带** `retinue` 个附属兵（满编），
##        出生点落在关卡给的**生成区域**里（`spawn_region`，点 + 半径 / 区划二选一）。
##        ⚠️ 冷却与每波规模都可在关卡里按阵营覆盖（`reddot_ai` 字典），见 `world.reddot_ai_cfg`。
##   2. 「让这些将领向某目标点行军移动」
##      → 每一位将领带着它的满编队伍走**同一条命令路径**（玩家 A 键 / 阵地 AI 巡逻
##        用的是同一个 `CommandProcessorRes.order_group_attack_move`），
##        目标点沿用关卡字段 `attack_target`（没写就退回「离它最近的敌方区划中心 / 敌方大本营」）。
##
## ★★ 与阵地性 AI（`logic/garrison_ai.gd`）的分工：
##   · 阵地性 —— 附属于区划、原地巡逻、无消耗招兵（守卫）；
##   · 红点性 —— 无归属区划、只在冷却到点时刷一波、然后一路行军（进攻）。
##   两者判据互斥：红点刷出来的将领 `garrison_zone_id < 0` ⇒ 阵地 AI 不会碰它们。
##
## ★ 状态放在 `world.reddot_states`（每项一个字典）——它是**世界状态的一部分**
##   （与 tech / objective 同源），将来进快照时就在 world 上。
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
const CommandProcessorRes = preload("res://logic/command_processor.gd")


## ★★ 建出这一局该跑的红点 AI（由 `world.reset()` 在所有单位就位之后调一次）。
##
## @return Array[Dictionary]，每项：
##   {faction, params, spawn_region, timer, waves_left, serial}
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
			# 第一波也要等一个冷却（「冷却时间较长」）。
			"timer": float(params["cooldown_sec"]),
			"waves_left": int(params["waves"]),
			"serial": 0,
		})
	return out


## 每帧推进所有红点 AI。
static func update(world, cfg: ConfigRes, dt: float) -> void:
	if dt <= 0.0 or world.reddot_states.is_empty():
		return
	for st in world.reddot_states:
		var left: int = int(st.get("waves_left", 0))
		st["timer"] = float(st.get("timer", 0.0)) - dt
		if float(st["timer"]) > 0.0:
			continue
		var params: Dictionary = st["params"]
		st["timer"] = float(params["cooldown_sec"])
		# `waves` 语义：0 = 无限波（默认）；> 0 = 只刷这么多波。
		if left > 0:
			st["waves_left"] = left - 1
		_launch_wave(world, cfg, st)


## 刷一波：`generals` 位满编将领，各带 `retinue` 个附属兵，一起行军攻击目标点。
##
## ★ 出生点、目标点都可能在**没有**数据 / 全被占住时取不到 —— 取不到就**不发这一波**
##   （计时器照旧重置，下一轮再试），绝不对着空坐标刷。
static func _launch_wave(world, cfg: ConfigRes, st: Dictionary) -> void:
	var faction := String(st["faction"])
	var params: Dictionary = st["params"]
	var goal = _resolve_target(world, faction)
	if goal == null:
		return
	var goal_pt: Vector2 = GridRes.center_of(goal)
	var count: int = maxi(1, int(params["generals"]))
	var retinue: int = maxi(0, int(params["retinue"]))
	var region: Variant = st.get("spawn_region", null)
	var serial: int = int(st.get("serial", 0))
	var sent := 0
	for n in count:
		var tile := _pick_spawn_tile(world, cfg, faction, region, n)
		if tile.x < 0:
			continue                        # 这一波这一位没地方站 —— 跳过它
		var g = _spawn_general(world, cfg, faction, n, serial, tile)
		if g == null:
			continue
		_fill_retinue(world, cfg, g, faction, retinue)
		# 整队行军攻击（与玩家 / 阵地 AI 同一条命令路径）。
		if CommandProcessorRes.order_group_attack_move(world, cfg, world.group_of(g), goal_pt):
			sent += 1
	st["serial"] = serial + 1
	if sent > 0:
		world.push_event({
			"type": "red_dot_wave",
			"faction": faction,
			"leaders": sent,
			"x": int(goal.x),
			"y": int(goal.y),
		})


## 造一位红点将领（唯一 id，避免多波之间撞名）。
##
## ★ 用 `UnitRes.create` 直接造（不走 `world.create_general`）：后者的 id 是
##   canonical 的 `general-<fid>-N`，多波会重复；红点将领是**一次性**的，需要唯一 id。
## ★ `general_index` 仍按序号取（决定它套哪一份数值覆盖 / 用哪个兵种）——
##   序号在 0..2 之间循环，于是三波各刷三种将领（长枪 / 长弓 / 骑兵）。
static func _spawn_general(world, cfg: ConfigRes, faction: String, n: int,
		serial: int, tile: Vector2i):
	var gi: int = n % 3
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


## 给一位红点将领补满 `count` 个附属兵（**当场生成**，不等读条 —— 这就是「满编」）。
static func _fill_retinue(world, cfg: ConfigRes, g, faction: String, count: int) -> void:
	var utype := String(g.unit_type)
	var pending: Array = [g]
	for k in count:
		var etile: Vector2i = world._ring_tile(g, faction, k + 1, pending)
		var e = UnitRes.create(cfg, "%s-r%d" % [String(g.id), k + 1], utype, etile,
			faction, utype, "", String(g.id), utype, -1)
		if e == null:
			continue
		world.units.append(e)
		pending.append(e)


## 挑一个生成格：关卡 `spawn_region` 决定锚点与半径。
##
## `spawn_region` 支持的形状（与 `attack_target` 同一套宽容度）：
##   · {"kind": "zone",  "zone": n}          → 在这个区划的地块里挑
##   · {"kind": "point", "x": X, "y": Y, "radius": R} → 以 (X,Y) 为心、R 格内挑
##   · 缺省 / 认不出来 → 用这一方的出生点当锚、`ai.reddot.spawn_radius` 当半径
##
## ★ 只挑**能站人**的格（可通行 + 无建筑 + 没被这一波已生成的单位占住）——
##   与出生点 / 招募共用同一套判据（`_can_stand`）。
static func _pick_spawn_tile(world, cfg: ConfigRes, faction: String,
		region: Variant, n: int) -> Vector2i:
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
	# 1) 有区划地块列表就在里面挑一个能站的；否则在锚点周围按半径找。
	if not tiles.is_empty():
		for t in tiles:
			var tt: Vector2i = t
			if _can_stand(world, cfg, faction, tt):
				return tt
	# 2) 锚点周围：按 ring 由近到远找第一个能站的格。
	return _ring_walkable(world, cfg, faction, anchor, maxi(0, int(radius)))


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
