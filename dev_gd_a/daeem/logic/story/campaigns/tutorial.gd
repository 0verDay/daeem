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


static func build(director, world) -> void:
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
