## tutorial.gd —— 新手教程 1（ce_xs_1）的演出剧本。
##
## ★★ 整段教程是一条**顺序演出**：
##   `on_start` 里用 `wait_until` 等玩家完成每一步，再继续下一步；
##   不注册并行的 zone / condition 触发器（这样「第 7 步之后」不会提前发生）。
##
## 流程对应需求：
##   1  地图左侧生成将领（暂时锁定）
##   2  对话「即使是世间名将，也不能疏于训练」
##   3  把将领交给玩家（部队 1）
##   4  对话「前进，占领第一个区划」
##   5  目标「占领区划 - ...」
##   6  c0 中心 + 占领范围呼吸高亮
##   7  玩家占领 c0 → 目标完成
##   8  对话「我记得，这还是我们当年起兵的地方」
##   9  对话「那年，你一呼百应」+ 500 粮
##   10 目标「招募五队协防军 ...」+ 协防军按钮呼吸高亮
##   11 招满 5 队（10 个单位）→ 目标完成
##   12 对话「枪打出头鸟，官兵要来逮你了」
##   13 地图最左侧生成红点（枪将 + 弓，原地行军）
##   14 对话「无论如何，会战兵力是11对2，优势在我」
##   15 目标「击败敌军 ...」
##   16 两个敌人呼吸高亮；只允许双击右键行军攻击
##   17 两个敌人被击败 → 目标完成
##   18 扩图到 ce_xs_1_b；右侧区划生成枪将 + 枪 + 弓
##   19 对话「现在是时候迎接新时代了」
##   20 目标「占领区划」+ 右侧区划呼吸高亮
##   21 玩家占领右侧区划 → 胜利
##
## ⚠️ 剧本只描述「发生什么」；不要读输入、不要直接改视图。
extends RefCounted

const RED_GENERAL_TAG := "tut_red_general"
const RED_ARCHER_TAG := "tut_red_archer"
const HERO_TAG := "tut_hero"
const BACK_MAP_PATH := "res://data/maps/ce_xs_1/ce_xs_1_b.json"
## ★★ 新手教程 2（ce_xs_2）。
const TUT2_LOCK := "tut2_intro_lock"
const TUT2_BACK_MAP_PATH := "res://data/maps/ce_xs_2/ce_xs_2_b.json"
const TUT2_ENEMY_ZONES := [1, 2, 3]
const TUT2_ZONE_CENTERS := [[18, 2], [39, 21], [2, 21]]


## 按关卡分派：同一个教程战役里 ce_xs_1 / ce_xs_2 是两条独立剧本。
static func build(director, world) -> void:
	var lid := String(world.level.id) if world != null and world.level != null else ""
	if lid == "ce_xs_2":
		_build_ce_xs_2(director, world)
	else:
		_build_ce_xs_1(director, world)


static func _build_ce_xs_1(director, world) -> void:
	director.on_start([
		# 1) 地图左侧生成将领：玩家阵营、暂时锁定、快捷键 1 = 部队 1。
		{"kind": "spawn_unit", "faction": "p1", "general": 11, "name": "将领",
			"spawn": {"tile": [2, 5]}, "hotkey": "1", "locked": true,
			"tag": HERO_TAG},
		# 2)
		{"kind": "dialogue", "text": "即使是世间名将，也不能疏于训练"},
		# 3)
		{"kind": "unit_control", "targets": {"tag": HERO_TAG}, "locked": false},
		# 3b) 玩家还没选部队时，让这位将领发光提示。
		{"kind": "guide_selection", "targets": {"tag": HERO_TAG},
			"id": "tut_guide_hero", "period": 1.1, "strength": 1.0},
		# 4)
		{"kind": "dialogue", "text": "前进，占领第一个区划"},
		# 5)
		{"kind": "objective_set", "title": "占领区划",
			"desc": "左键/框选可选中部队，选中部队后右键地面可移动部队"},
		# 6)
		{"kind": "glow_zone", "zones": [0], "period": 1.6, "strength": 0.85,
			"id": "tut_zone0"},

		# 7) 玩家占领第一个区划
		{"kind": "wait_until", "condition": func(): return _zone_owner(world, 0) == "p1"},
		{"kind": "objective_done"},
		{"kind": "stop_glow", "zones": [0], "id": "tut_zone0"},
		# 8)
		{"kind": "dialogue", "text": "我记得，这还是我们当年起兵的地方"},
		# 9)
		{"kind": "dialogue", "text": "那年，你一呼百应"},
		{"kind": "grant_resources", "food": 500},
		# 10)
		{"kind": "objective_set", "title": "招募五队协防军",
			"desc": "选中部队后点击右下角招募命令卡或按Q - 一个部队最多同时招募五个单位"},
		{"kind": "glow_command_card", "unit_kind": "dy_guard"},
		# 10b) 没选中部队 → 己方部队发光；没在单位页 → 单位页签发光。
		{"kind": "guide_selection", "targets": {"faction": "p1"}, "tab": "unit",
			"id": "tut_guide_recruit", "period": 1.1, "strength": 1.0},

		# 11) 招满 5 队（一队 = 枪 + 弓，共 10 个单位）
		{"kind": "wait_until", "condition": func(): return _guard_count(world) >= 10},
		{"kind": "objective_done"},
		{"kind": "glow_command_card", "unit_kind": ""},
		{"kind": "guide_clear", "id": "tut_guide_recruit"},
		# 12)
		{"kind": "dialogue", "text": "枪打出头鸟，官兵要来逮你了"},
		# 13) 地图最左侧：一个协防军枪将 + 一个协防军弓，行军到出生点 = 不移动
		{"kind": "spawn_unit", "faction": "enemy", "general": 1,
			"unit_type": "dy_spear_guard", "name": "协防军枪将",
			"spawn": {"tile": [0, 3]}, "tag": RED_GENERAL_TAG,
			"attack_move": {"tile": [0, 3]}, "red_dot_wave": true},
		{"kind": "spawn_unit", "faction": "enemy", "unit_type": "dy_archer_guard",
			"spawn": {"tile": [0, 7]}, "tag": RED_ARCHER_TAG,
			"attack_move": {"tile": [0, 7]}},
		# 14)
		{"kind": "dialogue", "text": "无论如何，会战兵力是11对2，优势在我"},
		# 15)
		{"kind": "objective_set", "title": "击败敌军",
			"desc": "选中部队后双击右键可行军攻击"},
		# 16)
		{"kind": "glow_object", "targets": [{"tag": RED_GENERAL_TAG}, {"tag": RED_ARCHER_TAG}],
			"period": 1.4, "strength": 0.9, "id": "tut_red"},
		{"kind": "input_policy", "block_single_right_click": true},

		# 17) 两个敌人都被击败 / 倒地
		{"kind": "wait_until", "condition": func(): return _red_wave_cleared(world)},
		{"kind": "objective_done"},
		{"kind": "stop_glow", "id": "tut_red"},
		{"kind": "input_policy", "block_single_right_click": false},

		# 18) 扩图 + 右侧区划三个敌人
		{"kind": "map_expand", "map": "ce_xs_1_b", "path": BACK_MAP_PATH,
			"fade_sec": 0.6, "focus": {"zone": 1}},
		{"kind": "spawn_unit", "faction": "enemy", "general": 1,
			"unit_type": "dy_spear_guard", "name": "协防军枪将",
			"spawn": {"tile": [14, 4]}, "tag": "tut_right_general"},
		{"kind": "spawn_unit", "faction": "enemy", "unit_type": "dy_spear_guard",
			"spawn": {"tile": [15, 5]}, "tag": "tut_right_spear"},
		{"kind": "spawn_unit", "faction": "enemy", "unit_type": "dy_archer_guard",
			"spawn": {"tile": [14, 6]}, "tag": "tut_right_archer"},
		# 19)
		{"kind": "dialogue", "text": "现在是时候迎接新时代了"},
		# 20)
		{"kind": "objective_set", "title": "占领区划", "desc": ""},
		{"kind": "glow_zone", "zones": [1], "period": 1.6, "strength": 0.85,
			"id": "tut_zone1"},

		# 21) 占领右侧区划 → 胜利
		{"kind": "wait_until", "condition": func(): return _zone_owner(world, 1) == "p1"},
		{"kind": "objective_done"},
		{"kind": "stop_glow", "zones": [1], "id": "tut_zone1"},
		{"kind": "outcome", "result": "win"},
	], {"skippable": false})


# ------------------------------------------------------------------
# 条件辅助（纯读 world）
# ------------------------------------------------------------------

static func _zone_owner(world, zid: int) -> String:
	if world == null or world.zones == null:
		return ""
	var z = world.zone_by_id(zid)
	return String((z as Dictionary).get("owner", "")) if z != null else ""


## 玩家名下「协防军」单位数（一次招募 = 枪 + 弓 = 2 个）。
static func _guard_count(world) -> int:
	if world == null:
		return 0
	var n := 0
	for u in world.units:
		if u == null or not u.alive:
			continue
		if String(u.faction) != String(world.my_faction):
			continue
		var t := String(u.unit_type)
		if t == "dy_spear_guard" or t == "dy_archer_guard":
			n += 1
	return n


## 某个 tag 的敌人是否已被击败（阵亡 / 濒死 / 中立化都算）。
static func _defeated(world, tag: String) -> bool:
	if world == null:
		return true
	for u in world.units:
		if u == null or String(u.tag) != tag:
			continue
		if u.alive and not u.is_downed() and not u.neutralized:
			return false
	return true


static func _red_wave_cleared(world) -> bool:
	return _defeated(world, RED_GENERAL_TAG) and _defeated(world, RED_ARCHER_TAG)


# ------------------------------------------------------------------
# 新手教程 2（ce_xs_2）：夺下 c0 → 建设 → 扩图 → 占领三个区划
# ------------------------------------------------------------------

static func _build_ce_xs_2(director, world) -> void:
	var steps: Array = [
		# 1) 开局锁所有输入；基地由剧本摆在 (5,7)，建筑不占区（关卡字段）。
		{"kind": "lock_input", "id": TUT2_LOCK},
		{"kind": "spawn_building", "faction": "p1", "type": "base",
			"spawn": {"tile": [5, 7]}, "tag": "tut2_base"},

		# 2) 己方 10 个单位：2 将 + 4 枪 + 4 弓；全部自动攻击行军到 c0 中心。
		{"kind": "spawn_unit", "faction": "p1", "general": 1,
			"unit_type": "dy_spear_guard", "name": "协防军枪将",
			"spawn": {"tile": [2, 6]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "p1", "general": 2,
			"unit_type": "dy_archer_guard", "name": "协防军弓将",
			"spawn": {"tile": [2, 8]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "p1", "unit_type": "dy_spear_guard",
			"count": 2, "spawn": {"tile": [1, 5]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "p1", "unit_type": "dy_spear_guard",
			"count": 2, "spawn": {"tile": [3, 5]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "p1", "unit_type": "dy_archer_guard",
			"count": 2, "spawn": {"tile": [3, 9]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "p1", "unit_type": "dy_archer_guard",
			"count": 2, "spawn": {"tile": [4, 9]}, "attack_move": {"tile": [8, 8]}},

		# 2b) 敌方 3 个单位：枪将 + 枪 + 弓；同样攻击行军到中心。
		{"kind": "spawn_unit", "faction": "enemy", "general": 1,
			"unit_type": "dy_spear_guard", "name": "协防军枪将",
			"spawn": {"tile": [11, 6]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "enemy", "unit_type": "dy_spear_guard",
			"spawn": {"tile": [11, 7]}, "attack_move": {"tile": [8, 8]}},
		{"kind": "spawn_unit", "faction": "enemy", "unit_type": "dy_archer_guard",
			"spawn": {"tile": [11, 8]}, "attack_move": {"tile": [8, 8]}},

		# 3) 玩家方拿下 c0 中心 → 解锁输入。
		{"kind": "wait_until", "condition": func(): return _zone_owner(world, 0) == "p1"},
		{"kind": "unlock_input", "id": TUT2_LOCK},

		# 4) 对话 + 5) 资源
		{"kind": "dialogue", "text": "我们终于拿下了这个地方，现在是时候休养生息了"},
		{"kind": "grant_resources", "food": 1000, "gold": 1000},

		# 6) 建设目标：6 个木墙 / 哨塔 + 2 个粮田；计数实时刷新、不重播打字机。
		{"kind": "objective_set", "title": "建立防御0/6 建造粮田0/2",
			"desc": "在建筑页签中选择哨塔/木墙/粮田进行建造", "quiet": true},
		{"kind": "wait_until", "condition": func(): return _tut2_build_goal(world)},
		{"kind": "objective_done"},

		# 7) 扩图到 b；随后把其余三个区划给敌人并各放 1 将 + 6 兵（阵地 AI）。
		{"kind": "map_expand", "map": "ce_xs_2_b", "path": TUT2_BACK_MAP_PATH,
			"fade_sec": 0.6, "focus": {"zone": 0}, "boundary": "full"},
		# 7b) 在 c1/c2/c3 靠 c0 的两格宽边带设置阵地 AI 禁行区；并在索敌层
		#     禁止守军自动打自己区划外的建筑（见 combat.nearest_enemy_building）。
		{"kind": "call", "fn": func(): _tut2_apply_border_no_go(world)},
		{"kind": "call", "fn": func(): _tut2_assign_enemy_zones(world)},
	]
	# 三个区划各一个枪将 + 6 个协防军（3 枪 3 弓），绑到该区划的阵地 AI。
	for i in TUT2_ENEMY_ZONES.size():
		var zid: int = int(TUT2_ENEMY_ZONES[i])
		steps.append({
			"kind": "spawn_unit", "faction": "enemy", "general": 1,
			"unit_type": "dy_spear_guard", "name": "协防军枪将",
			"spawn": {"tile": TUT2_ZONE_CENTERS[i]}, "zone": zid,
			"escort_count": 6,
			"escort_list": [
				"dy_spear_guard", "dy_spear_guard", "dy_spear_guard",
				"dy_archer_guard", "dy_archer_guard", "dy_archer_guard",
			],
			"escort_types": [
				{"type": "dy_spear_guard", "weight": 3},
				{"type": "dy_archer_guard", "weight": 3},
			],
		})
	# 8) 对话 + 9) 占领任务与胜利
	steps.append_array([
		{"kind": "dialogue", "text": "现在我们兵精粮足，正式勃勃生机万物竞发之时，扩大战果！"},
		{"kind": "objective_set", "title": "占领剩余区划0/3", "desc": "", "quiet": true},
		{"kind": "wait_until", "condition": func(): return _tut2_capture_goal(world)},
		{"kind": "objective_done"},
		{"kind": "outcome", "result": "win"},
	])
	director.on_start(steps, {"skippable": false})


## 在三个敌区**靠 c0 的两格宽边带**设置禁行区（用户 2026.11.07）。
##
## 判据：敌区地块到 c0 任意地块的切比雪夫距离 ≤ 2。对 c1 是底部两行，
## 对 c2/c3 是左右两列 —— 形状由地图决定，不写死坐标。禁行区只约束巡逻点；
## “不索敌玩家建筑”由 combat.nearest_enemy_building 的守军区划过滤保证。
static func _tut2_apply_border_no_go(world) -> void:
	if world == null or world.zones == null:
		return
	var c0 = world.zone_by_id(0)
	if c0 == null:
		return
	var c0_set := {}
	for t in (c0.get("tiles", []) as Array):
		c0_set[t] = true
	var raw := {}
	for zid in TUT2_ENEMY_ZONES:
		var z = world.zone_by_id(int(zid))
		if z == null:
			continue
		var band: Array = []
		for t in (z.get("tiles", []) as Array):
			var p: Vector2i = t
			var near := false
			for dy in range(-2, 3):
				if near:
					break
				for dx in range(-2, 3):
					if c0_set.has(Vector2i(p.x + dx, p.y + dy)):
						near = true
						break
			if near:
				band.append(p)
		if not band.is_empty():
			raw[int(zid)] = band
	world.zones.apply_no_go(raw)


## 把 c1/c2/c3 直接判给敌人（不是建筑占区；本关该机制已关闭）。
static func _tut2_assign_enemy_zones(world) -> void:
	if world == null or world.zones == null:
		return
	for zid in TUT2_ENEMY_ZONES:
		var z = world.zone_by_id(int(zid))
		if z == null:
			continue
		var zd: Dictionary = z
		zd["owner"] = "enemy"
		var by: Variant = zd.get("progress_by", null)
		if by is Dictionary:
			for k in (by as Dictionary).keys():
				(by as Dictionary)[k] = 0.0
			(by as Dictionary)["enemy"] = 1.0
		zd["progress"] = 1.0
		zd["capture_faction"] = ""
		zd["capture_state"] = ""
		zd["claimed_by"] = "story"
	world.refresh_ownership()
	world.refresh_zone_production()
	world.mark_vision_dirty()


## 建设目标：返回 true = 两项都完成；同时把 0/6、0/2 的实时计数写进目标标题。
static func _tut2_build_goal(world) -> bool:
	var walls := _tut2_count_buildings(world, ["wall", "tower"])
	var farms := _tut2_count_buildings(world, ["farm"])
	_tut2_set_title(world, "建立防御%d/6 建造粮田%d/2"
		% [mini(walls, 6), mini(farms, 2)])
	return walls >= 6 and farms >= 2


## 占领目标：只数剩余三个区划（c1/c2/c3）。
static func _tut2_capture_goal(world) -> bool:
	var n := 0
	for zid in TUT2_ENEMY_ZONES:
		if _zone_owner(world, int(zid)) == "p1":
			n += 1
	_tut2_set_title(world, "占领剩余区划%d/3" % n)
	return n >= 3


static func _tut2_count_buildings(world, types: Array) -> int:
	if world == null:
		return 0
	var n := 0
	for b in world.building_list:
		if b == null or not b.alive:
			continue
		if String(b.owner) != String(world.my_faction):
			continue
		if b.is_under_construction():
			continue
		if types.has(String(b.type)):
			n += 1
	return n


static func _tut2_set_title(world, title: String) -> void:
	if world == null:
		return
	var o: Variant = world.story_objective
	if o is Dictionary and not (o as Dictionary).is_empty():
		(o as Dictionary)["title"] = title
