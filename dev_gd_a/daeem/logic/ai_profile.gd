## ai_profile.gd —— 阵营指挥官 AI 的「难度 + 配置 + 阵营覆盖」合并（纯函数）。
##
## 产出是一个**扁平可读的字典**：控制器只读它，不再每帧下潜 JSON。
## 合并顺序（后者覆盖前者）：
##   1. 代码里的 DEFAULTS（防 config.json 缺键 / 老存档没有这一段）
##   2. config.json 的 `ai.commander`
##   3. 关卡 / 地图那一方的 `commander_ai`
##   4. 运行时覆盖（`world.ai_profiles[faction]`；合作 AI 队友的难度从这里进）
##
## ★ 难度是「参数包」：只改收入 / 节奏 / 上限 / 初始资源，不改单位数值。
## ★ 这个文件不读 world、不碰节点；测试可以直接调 `build()`。
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")

## 代码兜底：config.json 缺 `ai.commander` 时也能跑（与现有 ai.garrison / ai.reddot
## 的「宽容读取」同一条口径）。数值与 data/config.json 里的默认值保持一致。
const DEFAULTS := {
	"default_profile": "normal",
	"intervals": {
		"army_interval_sec": 0.6,
		"strategic_interval_sec": 2.0,
		"build_interval_sec": 2.5,
		"production_interval_sec": 1.0,
		"production_attempts": 3,
		"retry_sec": 3.0,
	},
	"economy": {
		"reserve_food": 80.0,
		"reserve_gold": 80.0,
		"max_float_food": 600.0,
		"max_float_gold": 600.0,
	},
	"march": {
		"arrive_radius": 3.0,
		"hold_radius": 7.0,
		"reissue_sec": 6.0,
		"arrive_timeout_sec": 90.0,
	},
	"mass": {
		"arrive_radius": 3.0,
		"hold_radius": 6.0,
	},
	"expand": {
		# ★★ 2026.10.24 重做：不再用「总兵力 × squad_ratio」这种跟全局上限绑定的口径，
		#    改成「按**队**凑够人数再派」。单位都是**总人数（含将领本人）**。
		"min_field_units": 3,        # 低于这个数不许出门（防光杆司令）
		"squad_units": 3,            # 打无主 / 无守军区划的小队规模
		"enemy_zone_min_units": 7,   # 打敌方区划的最低规模（看不到守军也按这个算）
		"assault_units": 10,         # 打敌方大本营的最低规模
		"assault_timeout_sec": 90.0, # 一轮进攻的最长时间（避免追一个打不掉的目标）
		"expand_timeout_sec": 75.0,  # 一块地打多久拿不下来就拉黑换目标
		"threat_radius": 6.0,        # 评估目标区划「周围有多少敌人」的半径（格）
		"avoid_enemy_ratio": 1.35,   # 目标附近敌人 ≥ 我方 × 这个倍率 ⇒ 不派小队去硬碰
		# ★ 经济需求评分：当前收入离目标越远，对应产能的区划加分越多。
		"target_food_income": 4.0,
		"target_gold_income": 4.0,
		"target_population_ratio": 0.35,
		"defender_weight": 0.8,
		"distance_weight": 0.15,
		"capture_hold_sec": 8.0,
		"next_target_delay_sec": 4.0,
		# 兼容旧配置（旧代码用这两个字段；新代码只在缺新键时回退）
		"squad_ratio": 0.65,
		"min_squad_units": 4,
	},
	"defense": {
		"threat_radius": 10.0,
		"recall_ratio": 0.35,
		"base_low_hp_ratio": 0.45,
		"recall_cooldown_sec": 20.0,
		"hold_sec": 8.0,
	},
	"production": {
		"general_target": 2,
		"general_target_by_base_level": [3, 6, 10],
		"general_recruit_min_army_ratio": 0.0,
		"develop_cap_ratio": 0.85,
		"max_queue_per_leader": 3,
		# ★★ 2026.10.24：按「队」补员，不再让一支部队一路招到全族上限。
		"home_team_size": 6,          # 守军补到这么多人后轮换出门
		"field_team_size": 4,         # 外勤队的目标规模（含将领）
		"max_training_leaders": 2,    # 同时读条的将领数上限（不是「只有 1 个兵营」）
		"min_garrison_replace_escorts": 1,  # 接替守军至少要有几个兵
		"dispatch_training_home": true,     # 读条中的守军只要够出门规模，就可以被换下来去巡逻
		"composition": [
			{"type": "spearman", "weight": 0.42},
			{"type": "longbowman", "weight": 0.24},
			{"type": "rider", "weight": 0.16},
			{"type": "knight", "weight": 0.08},
			{"type": "catapult", "weight": 0.05},
			{"type": "grain_cart", "weight": 0.05},
		],
	},
	"build": {
		"tower_max": 30,
		"tower_hard_max": 30,
		"tower_front_towers": 3,
		"tower_threat_towers": 5,
		"tower_rear_towers": 0,
		"tower_rich_bonus_max": 3,
		"production_reserve_recruits": 3,
		"pause_defense_when_understrength": true,
		"tower_threat_radius": 9.0,
		"tower_cover_radius": 4,
		"wall_enabled": true,
		"wall_hard_max": 100,
		"defense_upgrade_enabled": true,
		"defense_upgrade_tower_bonus": 12.0,
		"tower_frontier_bonus": 4.0,
		"base_upgrade_priority": 10.0,
		"tech_priority": [],
	},
	"patrol": {
		"enabled": true,
		"interval_sec": 5.0,
		"max_teams": 2,
		"threat_radius": 7.0,        # 巡逻点周围多大范围内的敌人会被算进风险
		"avoid_enemy_ratio": 1.25,   # 敌人 ≥ 我方 × 这个倍率 ⇒ 不把小队派去这个点
		"home_when_alone": true,     # 只有守军一支队伍时，允许它（读条中）去基地附近巡逻
	},
	# ★ 濒死将领：再起 / 召回巡检。再起免费；召回是「回大本营重开」。
	"revive": {
		"interval_sec": 0.75,             # 多快检查一次倒地将领
		"recall_escort_threshold": 1,     # 敌后 / 危险时，活着的附属兵 ≤ 这个数就召回
		"recall_distance_tiles": 7.0,     # 离家超过这个距离、又没兵，就召回
		"danger_radius": 6.0,             # 评估「附近敌人 / 友军」的半径
	},
	# ★ 队伍粘合：将领在走 / 停时，发现非战斗的附属兵掉队，就**重发整队命令**。
	"cohesion": {
		"enabled": true,
		"interval_sec": 1.2,
		"max_distance_tiles": 4.0,        # 超过这个距离就认为掉队（战斗中单位除外）
	},
	# ★ 队伍职能：按将领顺序轮换；职能同时影响招兵编成与战术。
	"roles": {
		"cycle": ["line", "ranged", "guerrilla"],
		"ranged": {
			"composition": [
				{"type": "longbowman", "weight": 0.45},
				{"type": "horse_archer", "weight": 0.20},
				{"type": "catapult", "weight": 0.08},
				{"type": "spearman", "weight": 0.17},
				{"type": "knight", "weight": 0.07},
				{"type": "grain_cart", "weight": 0.03},
			],
			"standoff_tiles": 4.5,       # 停在目标这个距离外，靠射程输出
			"frontline_min": 1,          # 至少保留几个非远程兵抗线
		},
		"guerrilla": {
			"composition": [
				{"type": "rider", "weight": 0.40},
				{"type": "horse_archer", "weight": 0.30},
				{"type": "spearman", "weight": 0.20},
				{"type": "longbowman", "weight": 0.10},
			],
			"max_enemy_strength": 3.0,   # 只打没有防备 / 守军很少的边界
			"avoid_ratio": 0.9,          # 敌人接近这个比例就撤（游击队不硬碰）
		},
	},
	# ★ 受击后的整队决策：有命令时不进入默认复仇，由 AI 决定反击还是继续撤。
	"reaction": {
		"cooldown_sec": 0.7,
		"danger_radius": 6.0,
		"counter_ratio": 1.15,          # 敌人 ≤ 我方 × 这个倍率 ⇒ 整队反击
		"retreat_counter_ratio": 0.75,  # 正在撤退时，敌人 ≤ 我方 × 这个倍率才回头
	},
	"auto": {
		"develop_until_ratio": 0.35,
		"expand_until_ratio": 0.8,
		"attack_after_sec": 45.0,
	},
	"difficulty": {
		"easy": {
			"income_mult": 0.8, "army_cap": 18, "army_cap_ratio": 0.6,
			"build_interval_mult": 1.3, "production_interval_mult": 1.4,
			"reaction_delay_sec": 2.0, "start_food": 150.0, "start_gold": 150.0,
		},
		"normal": {
			"income_mult": 1.0, "army_cap": 26, "army_cap_ratio": 0.8,
			"build_interval_mult": 1.0, "production_interval_mult": 1.0,
			"reaction_delay_sec": 1.2, "start_food": 250.0, "start_gold": 250.0,
		},
		"hard": {
			"income_mult": 1.2, "army_cap": 34, "army_cap_ratio": 1.0,
			"build_interval_mult": 0.8, "production_interval_mult": 0.8,
			"reaction_delay_sec": 0.7, "start_food": 350.0, "start_gold": 350.0,
		},
	},
}


## 建一份「这一方这一局」的指挥官参数。
##
## @param cfg          Config（读 `ai_commander_cfg()`）
## @param faction      阵营 id（只用于报错 / 调试）
## @param roster       `world.ai_roster_cfg`（找这一方的 `commander_ai` 覆盖）
## @param overrides    `world.ai_profiles`（按阵营的运行时覆盖）
static func build(cfg, faction: String, roster: Array, overrides: Dictionary) -> Dictionary:
	var base: Dictionary = _deep(DEFAULTS)
	var raw: Dictionary = {}
	if cfg != null and cfg.has_method("ai_commander_cfg"):
		var v: Variant = cfg.ai_commander_cfg()
		if typeof(v) == TYPE_DICTIONARY:
			raw = v
	base = _merge(base, raw)

	# 关卡 / 地图那一方的覆盖
	var entry_ov: Dictionary = {}
	for item in roster:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		if String(d.get("id", "")) != faction:
			continue
		var ca: Variant = d.get("commander_ai", null)
		if typeof(ca) == TYPE_DICTIONARY:
			entry_ov = (ca as Dictionary).duplicate(true)
		break

	# 运行时覆盖（合作 AI 队友难度从这里进）
	var run_ov: Dictionary = {}
	var rv: Variant = overrides.get(faction, null)
	if typeof(rv) == TYPE_DICTIONARY:
		run_ov = (rv as Dictionary).duplicate(true)

	var merged_ov: Dictionary = _merge(entry_ov, run_ov)
	var diff_name := String(merged_ov.get("difficulty", base.get("default_profile", "normal"))).strip_edges().to_lower()
	var diffs: Dictionary = base.get("difficulty", DEFAULTS["difficulty"])
	if not diffs.has(diff_name):
		diff_name = "normal"
	if not diffs.has(diff_name):
		diff_name = "easy"
	var diff: Dictionary = diffs.get(diff_name, {})

	# 覆盖里的「非 difficulty」键也直接盖到顶层（白名单式：只盖已有键）
	var flat: Dictionary = merged_ov.duplicate(true)
	flat.erase("difficulty")
	base = _merge(base, flat)

	# 把难度包摊平成控制器好读的字段
	base["difficulty_name"] = diff_name
	base["income_mult"] = _f(diff, "income_mult", 1.0)
	base["army_cap"] = _i(diff, "army_cap", 26)
	base["army_cap_ratio"] = clampf(_f(diff, "army_cap_ratio", 0.8), 0.1, 2.0)
	base["build_interval_mult"] = maxf(0.1, _f(diff, "build_interval_mult", 1.0))
	base["production_interval_mult"] = maxf(0.1, _f(diff, "production_interval_mult", 1.0))
	base["reaction_delay_sec"] = maxf(0.0, _f(diff, "reaction_delay_sec", 1.2))
	base["start_food"] = maxf(0.0, _f(diff, "start_food", 250.0))
	base["start_gold"] = maxf(0.0, _f(diff, "start_gold", 250.0))
	return base


## 读一个子字典的浮点值（缺键 / 类型不对 → fallback）。
static func _f(d: Dictionary, key: String, fallback: float) -> float:
	var v: Variant = d.get(key, null)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return fallback


static func _i(d: Dictionary, key: String, fallback: int) -> int:
	var v: Variant = d.get(key, null)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return int(v)
	return fallback


## 深拷贝（Dictionary / Array 递归；其它值按值拷贝）。
static func _deep(v: Variant) -> Variant:
	match typeof(v):
		TYPE_DICTIONARY:
			var out: Dictionary = {}
			for k in (v as Dictionary).keys():
				out[k] = _deep((v as Dictionary)[k])
			return out
		TYPE_ARRAY:
			var arr: Array = []
			for item in (v as Array):
				arr.append(_deep(item))
			return arr
		_:
			return v


## 把 `over` 逐键盖到 `base` 上（两边都是字典；嵌套字典递归）。
## ★ base 里没有的键也会带进来：config 以后加新键不用改这里；控制器只读它认识的键。
static func _merge(base: Dictionary, over: Dictionary) -> Dictionary:
	var out: Dictionary = _deep(base)
	for k in over.keys():
		if not out.has(k):
			out[k] = _deep(over[k])
			continue
		var bv: Variant = out[k]
		var ov: Variant = over[k]
		if typeof(bv) == TYPE_DICTIONARY and typeof(ov) == TYPE_DICTIONARY:
			out[k] = _merge(bv, ov)
		else:
			out[k] = _deep(ov)
	return out
