## story_consts.gd —— 演出系统的**唯一常量表**。
##
## ★ 为什么把字符串常量集中在这里：
##   导演、剧本、测试三处都会写 `"lock_input"` / `"camera"` / `"kill"` 这些字面量；
##   三处各写一份，改一个名字就会静默失效（不报错，只是那一步永远不执行）。
##   所以所有 kind / 动作类别 / 事件名都从这里取。
##
## ⚠️ 跨文件引用只用 preload 常量，不写全局 `class_name`
##    （`--script` 无头跑时全局类名表不可用）。
extends RefCounted


# ------------------------------------------------------------------
# 输入动作类别（allowlist 的键）
# ------------------------------------------------------------------
const ACT_CAMERA := "camera"
const ACT_SELECT := "select"
const ACT_ORDER := "order"
const ACT_RECRUIT := "recruit"
const ACT_BUILD := "build"
const ACT_TECH := "tech"
const ACT_UPGRADE := "upgrade"
const ACT_REVIVE := "revive"
const ACT_UI := "ui"
const ACT_PAUSE := "pause"
## 对话自己的推进输入（点击 / 空格）。
const ACT_DIALOGUE := "dialogue"
## Esc 跳过演出。
const ACT_SKIP := "skip"

const ALL_ACTIONS := [
	ACT_CAMERA, ACT_SELECT, ACT_ORDER, ACT_RECRUIT, ACT_BUILD,
	ACT_TECH, ACT_UPGRADE, ACT_REVIVE, ACT_UI, ACT_PAUSE,
	ACT_DIALOGUE, ACT_SKIP,
]


# ------------------------------------------------------------------
# 演出步骤 kind
# ------------------------------------------------------------------
const STEP_WAIT := "wait"
const STEP_LOCK_INPUT := "lock_input"
const STEP_UNLOCK_INPUT := "unlock_input"
const STEP_CAMERA_MOVE := "camera_move"
const STEP_CAMERA_LOCK := "camera_lock"
const STEP_CAMERA_UNLOCK := "camera_unlock"
const STEP_CAMERA_FOLLOW := "camera_follow"
const STEP_MAP_BOUNDARY := "map_boundary"
const STEP_MAP_BOUNDARY_EXPAND := "map_boundary_expand"
const STEP_MAP_EXPAND := "map_expand"
const STEP_GRANT_RESOURCES := "grant_resources"
const STEP_KILL_UNITS := "kill_units"
const STEP_DESTROY_BUILDINGS := "destroy_buildings"
const STEP_DIALOGUE := "dialogue"
const STEP_SPAWN_RED_DOT := "spawn_red_dot"
const STEP_SPAWN_UNIT := "spawn_unit"
const STEP_SPAWN_BUILDING := "spawn_building"
const STEP_GLOW_OBJECT := "glow_object"
const STEP_GLOW_ZONE := "glow_zone"
const STEP_STOP_GLOW := "stop_glow"
const STEP_GLOW_COMMAND_CARD := "glow_command_card"
const STEP_GUIDE_SELECTION := "guide_selection"
const STEP_GUIDE_CLEAR := "guide_clear"
const STEP_OBJECTIVE_SET := "objective_set"
const STEP_OBJECTIVE_DONE := "objective_done"
const STEP_INPUT_POLICY := "input_policy"
const STEP_UNIT_CONTROL := "unit_control"
const STEP_SET_VAR := "set_var"
const STEP_OUTCOME := "outcome"
const STEP_WAIT_UNTIL := "wait_until"
const STEP_CALL := "call"
const STEP_END := "end"


# ------------------------------------------------------------------
# 触发器 kind
# ------------------------------------------------------------------
const TRIGGER_START := "start"
const TRIGGER_TIME := "time"
const TRIGGER_ZONE_OWNER := "zone_owner"
const TRIGGER_EVENT := "event"
const TRIGGER_UNIT_DEAD := "unit_dead"
const TRIGGER_BUILDING_DESTROYED := "building_destroyed"
const TRIGGER_COMMAND := "command"
const TRIGGER_CONDITION := "condition"


# ------------------------------------------------------------------
# 常用世界事件名（真正的事件名仍以 logic/world.gd / unit.gd / combat.gd 为准）
# ------------------------------------------------------------------
const EV_KILL := "kill"
const EV_LEADER_DOWNED := "leader_downed"
const EV_BUILDING_DOWN := "building_down"
const EV_BUILDING_READY := "building_ready"
const EV_TERRITORY_CHANGED := "territory_changed"
const EV_TECH_CHANGED := "tech_changed"
const EV_UPGRADE_DONE := "upgrade_done"


## 这把锁是否允许某个动作（allow 是数组或字典都认）。
static func allow_has(allow: Variant, action: String) -> bool:
	if allow == null:
		return true
	if typeof(allow) == TYPE_ARRAY:
		return (allow as Array).has(action)
	if typeof(allow) == TYPE_DICTIONARY:
		return bool((allow as Dictionary).get(action, false))
	return false


## 把 allow 归一成字典（导演内部用字典做交集更快）。
static func normalize_allow(allow: Variant) -> Dictionary:
	var out: Dictionary = {}
	if typeof(allow) == TYPE_ARRAY:
		for a in (allow as Array):
			out[String(a)] = true
	elif typeof(allow) == TYPE_DICTIONARY:
		for k in (allow as Dictionary).keys():
			if bool((allow as Dictionary)[k]):
				out[String(k)] = true
	else:
		# ★ null / 缺省 = **锁定全部玩法输入**（不是「全部允许」）。
		#   但保留 `dialogue` / `skip`：锁定期间仍要能读对话、跳过演出。
		out[ACT_DIALOGUE] = true
		out[ACT_SKIP] = true
	return out
