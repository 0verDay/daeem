extends RefCounted
##
## 全部可调数值的唯一来源（读 data/config.json）。
##
## 铁律（docs/architecture.md 第一节）：代码里不写游戏数值字面量。
## 于是「调平衡」永远只改一个文本文件，不必翻代码。
##
## 用法：
##     var cfg := Config.load_default()      # 全项目入口调用一次
##     var g := World.new(cfg)               # 逻辑层持有它
##     cfg.cell_px                           # 像素换算只在这里（view/ 用）
##     cfg.num("combat.aggro_range", 4.0)    # 取任意路径，带默认值
##
## ⚠️ 数值路径用 `.` 分隔（"unit.types.spearman.damage"）。返回的是 JSON 里的原始类型，
##    取标量请走 num / int_val / bool_val，别自己 as float（GDScript 会静默变 0）。
##

## ⚠️ 跨文件引用只用**自己文件里的 preload 常量**：命令行 `--script` 下全局 class_name
##    表不可用，写 `GridRes` 作类型会直接 Parse Error（见 docs/pitfalls.md 第五节）。
const GridRes = preload("res://logic/grid.gd")

const DEFAULT_CONFIG_PATH := "res://data/config.json"
const DEFAULT_MAP_PATH := "res://data/test_map.json"

## 缓存 JSON 的字典形式（阵营 id → 字典 / 颜色名 → 字典 这类查找用得着）
var data: Dictionary = {}

## ---- 常用标量（载入时算好，避免逻辑层到处 `num("...")`）----
## ⚠️ cell_px 是**全项目唯一允许存在的像素常量**，而且它只该被 view/ 读
##    （palette.to_px / tile_rect / unit_radius_px）。logic/ 里出现它 = 坐标单位混用的信号。
##    它放在这里而不是 view/，只是为了让所有可调数值集中在同一个 JSON 里。
var cell_px: float = 128.0
var cols: int = 24
var rows: int = 16

## ---- 相机：边缘滚屏的「贴边多宽算边缘」----
## ★ 这个值有**两个**读法，必须同源：camera_rig 用它决定「鼠标贴边多深开始滚」，
##   hud 用它决定「屏幕最外圈永远允许滚屏、控件不许拦」（见 ui_layout.in_edge_band）。
##   两处各写一个 44 就会出现「看着能滚、其实被控件拦住」这种错位。
var camera_edge_size: float = 44.0

## ---- 框选：左键移动超过多少像素才算「拖框」（见 config.json 的 ui._comment）----
var drag_select_min_px: float = 6.0

## ---- 小地图拖动视角（见 config.json 的 minimap._comment）----
## ★ 与 drag_select_min_px 同一种单位（**屏幕像素**）：判据不该跟着相机缩放漂移。
##   两个数长得像但用途不同：上面那个决定「拖框选单位」，这两个决定「拖小地图移视角」。
var minimap_drag_min_px: float = 4.0
## ★ 按住多少秒算「长按」（0 = 只按像素阈值判定）。
##   ⚠️ 它只影响「多快进入拖动态」，不影响按下那一刻的跳转 —— 见 view/minimap.gd 的状态机。
var minimap_drag_hold_sec: float = 0.18

var unit_speed: float = 0.6
var unit_forest_mult: float = 0.5
var unit_hp_max: float = 200.0
var unit_radius_factor: float = 0.1

## ---- 碰撞（★ 每帧每单位都会读；原先走 num() 每次都要 split(".") + 逐层下潜）----
var unit_collision_enabled: bool = true
var unit_collision_backend: String = "csharp"
var unit_collision_radius: float = 0.18
var unit_overlap_allowance: float = 0.7
var unit_collision_iterations: int = 3
var unit_collision_slack: float = 0.01
var unit_push_moving_weight: float = 1.0
var unit_push_idle_weight: float = 0.2

## ---- 到达 / 认账（同样在每单位每帧的路径上）----
var unit_jam_giveup_sec: float = 2.4
var unit_settle_return_dist: float = 0.22
var unit_settle_max_attempts: int = 3

## ---- 队形落点（见 config.json 的 _formation_comment）----
var formation_min_units: int = 4
var formation_spacing_scale: float = 1.15
var formation_aspect: float = 1.6
var formation_max_slots: int = 400

## ---- 寻路（A* 每个节点 / 每条线段都在读）----
var path_diagonal: bool = true
var path_diagonal_corner_cut: bool = false
var path_building_penalty: float = 12.0
var path_corner_round_enabled: bool = true
var path_corner_round_cutting: float = 0.35
var path_corner_round_min_angle_deg: float = 20.0

## ---- 单位类型表（config.json 的 unit.types / unit.classes / unit.general）----
##
## ★★ 这是「单位是什么」的唯一来源（见 data/config.json 的 _types_comment）：
##   · `_unit_types`   —— 类型 id → 整套数值（血量 / 速度 / 半径 / 战斗三件套 / 兵种标签）
##   · `_unit_classes` —— 兵种大类（步兵 / 骑兵）的显示名
##   · `_general_types`—— 三个开局将领（以及 general_N）各自的类型，来自 unit.general.types
## ★ 与下面的战斗数值表同一条规矩：**载入时整理好、之后只读**。
##   这些查询全在「每帧每单位」的路径上（unit_hp_of / unit_combat_of / unit_radius_of），
##   所以表里存的是**算好的标量**，而不是每次去 split(".") 下潜 JSON。
var _unit_types: Dictionary = {}
var _unit_classes: Dictionary = {}
var _general_types: Array = []
## 每个将领开局带几个**同类型**的兵（原 unit.subordinate.count）—— 见 unit.general.escort
var general_escort: int = 0
## 查不到类型时的兜底战斗数值（= 第一个将领类型，也就是长枪兵那一档）。
## ★ 为什么兜底是长枪兵而不是测试敌人：本项目踩过「二元判断（是将领吗？不是就当敌人）
##   把新加的类型静默当成测试敌人」这个坑（见 docs/pitfalls.md 5.x）——
##   兜底落在敌人身上就会让「漏配一个类型」表现为「它变成了 60 血」。
var _combat_fallback: Dictionary = {"damage": 10.0, "range": 1.0, "cooldown_sec": 1.2}

## 战斗数值表：**载入时建好、之后只读**（原先每次 unit_combat_of() 都新建一个字典）
var combat_enabled: bool = true
var aggro_range: float = 4.0
var leash_factor: float = 1.8
var repath_sec: float = 0.3
## 追击时，目标从上一次算路的位置挪出这么多格，才值得重算一次路径。
## ★ 见 unit.gd `last_repath_to` 的说明：只按周期无条件重算会让 1000 单位追击
##   掉到 20 fps。0 = 退回旧的「按周期无条件重算」。
var repath_min_move: float = 0.5
## 追击目标在这个距离内（格）且直线可切时，直接走直线（见 unit.chase_to）。
## ★ 为什么要有这个开关：每个不同的敌人所在格都要一张新距离场（全图 Dijkstra），
##   几百个单位同帧锁定目标时就是几十次 Dijkstra —— 实测单帧 21.5 ms。
var chase_direct_range: float = 8.0
var flash_sec: float = 0.22
## 受击闪光的除数（= max(0.01, flash_sec)）。
## ★ 预计算：闪光衰减那句在**每单位每帧**的路径上，而 `maxf(0.01, cfg.flash_sec)`
##   每次都要算一遍常数。
var flash_sec_safe: float = 0.22
var building_damage: float = 40.0
## 测试敌人的那几个数（单位类型的战斗数值已搬进 unit.types，见 _unit_types）。
## ★ 保留这几个字段只是「同一份数的另一个名字」：_cache_unit_types() 会把
##   unit.types.enemy 那一档抄进来，老调用方与测试按它们读仍然对得上。
var enemy_damage: float = 10.0
var enemy_range: float = 1.0
var enemy_cooldown: float = 1.2

var zone_cols: int = 6
var zone_rows: int = 4
## 1 个单位独自占下一个区块要多少秒（= 占领速率 1/capture_time_sec 的倒数）。
## 历史：4 → 32（需求「占领速度缩小为原来的 1/8」）。
var capture_time_sec: float = 32.0
## 读条方**不在场**时，进度每秒回落多少（进度比例/秒）。
## 历史：0.125 → 0.03125（需求「自然占领进度降低速度缩小为原来的 1/4」）。
## ⚠️ 与 capture_time_sec 的缩放倍数不同（1/4 vs 1/8），别顺手改成一样。
var decay_per_sec: float = 0.03125
## ★★ 人数加成曲线的三个参数（见 zone.speed_multiplier / data/config.json 的 _capture_comment）：
##   · zone_speed_max_mult  —— 满编时趋近的倍率上限（x2）。
##   · zone_speed_curve_k   —— 归一化分母的常数：**越大越平缓**（要更多人才能接近上限）。
##   · zone_speed_curve_power —— 曲线的指数：`倍率 = 1 + (max-1) × t^p`，t = (n-1)/(n-1+k)。
##     ★ 必须 > 1 才叫「先慢后快」（t^p 在 n=1..10 上是凸的）；= 1 会退化成「先快后慢」。
var zone_speed_max_mult: float = 2.0
var zone_speed_curve_k: float = 2.5
var zone_speed_curve_power: float = 1.7
var zone_owned_by_building: bool = true

var food_per_tile_per_sec: float = 1.0
var gold_per_tile_per_sec: float = 1.0
var start_food: float = 0.0
var start_gold: float = 0.0

## ---- 科技（config.json 的 tech 段）----
## ★ 与战斗数值表一样：**载入时整理好、之后只读**（科技页每帧按它重画九格，
##   而这是「每帧 × 9 格」的路径，不该每次去 split(".") 下潜 JSON）。
## ★ 效果字段留在**每个条目自己的字典里**（`entry["effect"]`），
##   聚合那一步在 logic/tech.gd。这里只负责「表怎么读、怎么查」。
var tech_max_active: int = 3
var _tech_list: Array = []
var _tech_by_id: Dictionary = {}

## ---- 建筑升级（config.json 的 upgrade.levels）+ 区划特化（zone_spec）----
## ★ 与科技表一样：**载入时整理好、之后只读**（升级判定与每帧读条都要用）。
## ★ 升级表按**建筑类型**分开存（base / wall / tower 各一张等级表，下标 0 = 1 级）；
##   特化表是一张全局表（三档，cost / time_sec 是共用的默认值，条目可覆盖）。
var _upgrade_levels: Dictionary = {}
var _spec_list: Array = []
var _spec_by_id: Dictionary = {}
var _spec_cost: Dictionary = {}
var _spec_time_sec: float = 0.0

## ---- 区划种类（config.json 的 zone_kind 段）----
## ★★ 游戏里只有三种区划（粮食 / 黄金 / 人口），**没有「默认区划」那一档**：
##   地图没写 kind 的区划（老图 / 手写图）按 `zone_kind_default()` 那一种算。
## ★ 每种给两样东西：
##   · `production` —— **编辑器选种类时同步进数字输入框的预设值**（每地块每秒）；
##     游戏里**不**拿它当兜底：地图没写 production 的区划一律算 0（用户确认保持老图行为）。
##   · `specs`      —— 这种区划**能选**哪些特化（需求：粮食区划仅能黄金 / 人口特化…）。
## ★ 同样是**载入时整理好、之后只读**（区划详情每帧读名字 / 特化判定每次点击都读白名单）。
var _zone_kind_default: String = "population"
var _zone_kind_list: Array = []
var _zone_kind_by_id: Dictionary = {}

var respawn_sec: float = 0.0
var destructible_base: bool = false

## 一帧最多按多少秒推进逻辑（防止「帧慢→dt 大→活更多→更慢」的死亡螺旋）
var sim_max_dt: float = 0.05

var enemy_speed: float = 0.45
var enemy_hp: float = 60.0


## 载入配置。失败时返回 null，并把原因写进 last_error —— 调用方必须处理
## （静默用一份默认值会让「JSON 写错了」表现为「手感莫名不对」，最难查）。
static var last_error: String = ""


static func load_default():
	var cfg = new()
	if not cfg._load(DEFAULT_CONFIG_PATH):
		return null
	return cfg


func _load(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		last_error = "打不开配置文件：%s" % path
		push_error(last_error)
		return false
	var text := f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		last_error = "config.json 不是合法 JSON 对象：%s" % path
		push_error(last_error)
		return false

	data = parsed
	_cache_scalars()
	return true


func _cache_scalars() -> void:
	cols = int_val("grid.cols", 24)
	rows = int_val("grid.rows", 16)
	cell_px = num("render.cell_px", 128.0)

	camera_edge_size = num("camera.edge_size", 44.0)
	drag_select_min_px = num("ui.drag_select_min_px", 6.0)
	minimap_drag_min_px = num("minimap.drag_min_px", 4.0)
	minimap_drag_hold_sec = num("minimap.drag_hold_sec", 0.18)

	unit_speed = num("unit.speed", 0.6)
	unit_forest_mult = num("unit.forest_mult", 0.5)
	unit_hp_max = num("unit.hp_max", 200.0)
	unit_radius_factor = num("unit.radius_factor", 0.1)

	unit_collision_enabled = bool_val("unit.collision_enabled", true)
	unit_collision_backend = str_val("unit.collision_backend", "csharp")
	unit_collision_radius = num("unit.collision_radius", 0.18)
	unit_overlap_allowance = num("unit.overlap_allowance", 0.7)
	unit_collision_iterations = int_val("unit.collision_iterations", 3)
	unit_collision_slack = num("unit.collision_slack", 0.01)
	unit_push_moving_weight = num("unit.push_moving_weight", 1.0)
	unit_push_idle_weight = num("unit.push_idle_weight", 0.2)

	unit_jam_giveup_sec = num("unit.jam_giveup_sec", 2.4)
	unit_settle_return_dist = num("unit.settle_return_dist", 0.22)
	unit_settle_max_attempts = int_val("unit.settle_max_attempts", 3)

	formation_min_units = int_val("unit.formation.min_units", 4)
	formation_spacing_scale = num("unit.formation.spacing_scale", 1.15)
	formation_aspect = maxf(1.0, num("unit.formation.aspect", 1.6))
	formation_max_slots = int_val("unit.formation.max_slots", 400)

	path_diagonal = bool_val("path.diagonal", true)
	path_diagonal_corner_cut = bool_val("path.diagonal_corner_cut", false)
	path_building_penalty = num("path.building_penalty", 12.0)
	path_corner_round_enabled = bool_val("path.corner_round_enabled", true)
	path_corner_round_cutting = num("path.corner_round_cutting", 0.35)
	path_corner_round_min_angle_deg = num("path.corner_round_min_angle_deg", 20.0)

	combat_enabled = bool_val("combat.enabled", true)
	aggro_range = num("combat.aggro_range", 4.0)
	leash_factor = num("combat.leash_factor", 1.8)
	repath_sec = num("combat.repath_sec", 0.3)
	repath_min_move = num("combat.repath_min_move", 0.5)
	chase_direct_range = num("combat.chase_direct_range", 8.0)
	flash_sec = num("combat.flash_sec", 0.22)
	flash_sec_safe = maxf(0.01, flash_sec)
	building_damage = num("combat.building_damage", 40.0)

	zone_cols = int_val("zone.zone_cols", 6)
	zone_rows = int_val("zone.zone_rows", 4)
	capture_time_sec = num("zone.capture_time_sec", 32.0)
	decay_per_sec = num("zone.decay_per_sec", 0.03125)
	zone_speed_max_mult = num("zone.speed_max_mult", 2.0)
	zone_speed_curve_k = num("zone.speed_curve_k", 2.5)
	zone_speed_curve_power = num("zone.speed_curve_power", 1.7)
	zone_owned_by_building = bool_val("zone.zone_owned_by_building", true)

	food_per_tile_per_sec = num("resource.food_per_tile_per_sec", 1.0)
	gold_per_tile_per_sec = num("resource.gold_per_tile_per_sec", 1.0)
	start_food = num("resource.start_food", 0.0)
	start_gold = num("resource.start_gold", 0.0)

	respawn_sec = num("pvp.respawn_sec", 8.0)
	destructible_base = bool_val("pvp.destructible_base", false)
	sim_max_dt = num("sim.max_dt", 0.05)

	_cache_techs()
	_cache_upgrades()
	_cache_zone_kinds()
	_cache_zone_specs()
	# ★★ 单位类型表（unit.types / unit.classes / unit.general）—— 必须在其它
	#   单位字段之后调：它拿 unit_speed / unit_hp_max / unit_radius_factor 当兜底值，
	#   并且会顺手把「测试敌人」那几个兼容字段填好。
	#   于是 enemy_hp / enemy_speed / enemy_damage… 不再是**另一份**配置，
	#   而是这张表里 enemy 那一档的别名（见 _cache_unit_types）。
	_cache_unit_types()


# ------------------------------------------------------------------
# 单位类型（config.json 的 unit.types / unit.classes / unit.general）
#
# ★★ 这一层回答四个问题（判定与文案在别处）：
#   1. 有哪些单位类型、各自什么数值（unit_hp_of / unit_speed_of / unit_radius_of /
#      unit_combat_of —— 全都是「每帧每单位」的查询）；
#   2. 某个 kind 属于哪个单位类型（unit_type_of：兵种 id 就是它自己，
#      将领 kind 走 unit.general.types）；
#   3. 它是**步兵还是骑兵**、远不远（unit_class_of / unit_is_ranged）——
#      「后续按兵种做额外伤害」就读这两个；
#   4. 三个开局将领各是什么类型、各带几个同类型的兵（general_type_at / general_escort_count）。
# ⚠️ 表里查不到的 kind 一律**退回兜底值**（而不是当成测试敌人）：手写地图里写错一个
#   kind 不该让那个单位变成 60 血的敌人 —— 那正是本项目踩过的坑（见 _combat_fallback）。
# ------------------------------------------------------------------

## 载入时整理单位类型表（**只读**，之后别再改它）。
func _cache_unit_types() -> void:
	_unit_types = {}
	_unit_classes = {}
	_general_types = []

	# 1) 兵种大类（unit.classes）：id → 显示名（带 / 不带远近两种说法）
	var raw_classes: Variant = get_path_value("unit.classes")
	if typeof(raw_classes) == TYPE_DICTIONARY:
		for cid in (raw_classes as Dictionary).keys():
			var c: Variant = (raw_classes as Dictionary)[cid]
			if typeof(c) != TYPE_DICTIONARY:
				continue
			var cd: Dictionary = c
			_unit_classes[String(cid)] = {
				"id": String(cid),
				"name": String(cd.get("name", cid)),
				"ranged_name": String(cd.get("ranged_name", cd.get("name", cid))),
			}

	# 2) 单位类型表（unit.types）
	var raw: Variant = get_path_value("unit.types")
	if typeof(raw) == TYPE_DICTIONARY:
		for tid in (raw as Dictionary).keys():
			var t: Variant = (raw as Dictionary)[tid]
			if typeof(t) != TYPE_DICTIONARY:
				continue
			var td: Dictionary = t
			var id := String(tid)
			var cls := String(td.get("class", CLASS_INFANTRY))
			if not _unit_classes.has(cls):
				cls = CLASS_INFANTRY          # 写错 class 就当步兵，而不是留一个查不到的大类
			_unit_types[id] = {
				"id": id,
				"name": String(td.get("name", id)),
				"class": cls,
				"ranged": bool(td.get("ranged", false)),
				"hp_max": maxf(1.0, float(td.get("hp_max", unit_hp_max))),
				"speed": maxf(0.0, float(td.get("speed", unit_speed))),
				"radius_factor": clampf(float(td.get("radius_factor", unit_radius_factor)), 0.01, 0.5),
				"combat": {
					"damage": maxf(0.0, float(td.get("damage", 0.0))),
					"range": maxf(0.0, float(td.get("range", 1.0))),
					"cooldown_sec": maxf(0.01, float(td.get("cooldown_sec", 1.0))),
				},
			}

	# 3) 开局将领（general_N 同序）各自的类型
	var types: Variant = get_path_value("unit.general.types")
	if typeof(types) == TYPE_ARRAY:
		for item in (types as Array):
			var sid := String(item)
			if _unit_types.has(sid):
				_general_types.append(sid)
	if _general_types.is_empty() and _unit_types.has(UNIT_TYPE_SPEARMAN):
		_general_types.append(UNIT_TYPE_SPEARMAN)
	general_escort = maxi(0, int_val("unit.general.escort", 0))

	# 4) 兜底值 + 测试敌人的兼容字段（都来自同一张表，不再是第二份配置）
	var fb: Variant = _unit_types.get(String(_general_types[0]), null) if not _general_types.is_empty() else null
	if typeof(fb) == TYPE_DICTIONARY:
		_combat_fallback = (fb as Dictionary)["combat"]
	var e: Variant = _unit_types.get(KIND_ENEMY, null)
	if typeof(e) == TYPE_DICTIONARY:
		var ed: Dictionary = e
		var ec: Dictionary = ed["combat"]
		enemy_hp = float(ed["hp_max"])
		enemy_speed = float(ed["speed"])
		enemy_damage = float(ec["damage"])
		enemy_range = float(ec["range"])
		enemy_cooldown = float(ec["cooldown_sec"])


## 某个 kind 对应的**单位类型 id**。
##   · 兵种 id（spearman / longbowman / rider / enemy…）→ 它自己；
##   · general → unit.general.types[0]；general_N → types[N-1]；
##   · 其它（写错的 kind）→ 原样返回，各 `unit_*_of()` 会退回兜底值。
func unit_type_of(kind: String) -> String:
	if _unit_types.has(kind):
		return kind
	var idx := general_index_of(kind)
	if idx >= 0 and idx < _general_types.size():
		return String(_general_types[idx])
	return kind


## kind 是不是「将领类」（general / general_N）？是的话返回它的序号（0 起），否则 -1。
##
## ★ 判据只看 kind 前缀，**不看 leader_id** —— 测试敌人的 leader_id 也是空的，
##   靠「有没有队长」分不出将领与敌人（见 logic/unit.gd 的 is_general()）。
## ★ 集中在这里一处：unit.gd / world.gd / 渲染都调它，免得各写一份前缀判断慢慢漂开。
## ★★ 它是 **static** 的（只读常量、不看配置实例）：`unit.is_general()` 要在
##    「手里只有一个 preload 常量、没有 cfg 实例」的地方调它（例如渲染与单测）。
static func general_index_of(kind: String) -> int:
	if kind == KIND_GENERAL:
		return 0
	if kind.begins_with("general_"):
		var tail := kind.substr(8)
		if tail.is_valid_int():
			return maxi(0, int(tail) - 1)
	return -1


## 这个 kind 是不是将领类
func is_general_kind(kind: String) -> bool:
	return general_index_of(kind) >= 0


## 表里有没有这个单位类型
func has_unit_type(id: String) -> bool:
	return _unit_types.has(id)


## 全部单位类型 id（**顺序不保证** —— 只用来遍历，不当界面顺序）
func unit_type_ids() -> Array:
	return _unit_types.keys()


## 某个类型的条目（**只读**，别改返回的字典）；查不到返回空字典
func unit_type_entry(id: String) -> Dictionary:
	var e: Variant = _unit_types.get(unit_type_of(id), null)
	return e if typeof(e) == TYPE_DICTIONARY else {}


## 三个开局将领（以及 general_N）各自的类型 id
func general_types() -> Array:
	return _general_types


## 第 i 个将领（0 起）的类型；越界退回第一个（再没有就退回 general）
func general_type_at(i: int) -> String:
	if _general_types.is_empty():
		return KIND_GENERAL
	if i < 0 or i >= _general_types.size():
		return String(_general_types[0])
	return String(_general_types[i])


## 每个将领开局带几个同类型的兵
func general_escort_count() -> int:
	return general_escort


## 兵种大类：infantry（步兵）/ cavalry（骑兵）—— 「后续额外伤害」的主键
func unit_class_of(id: String) -> String:
	var e := unit_type_entry(id)
	return String(e.get("class", CLASS_INFANTRY))


## 是不是远程单位（长弓兵那种；将来的马弓手也是骑兵 + 远程）
func unit_is_ranged(id: String) -> bool:
	return bool(unit_type_entry(id).get("ranged", false))


## 大类的显示名（步兵 / 骑兵）—— 不带远近
func unit_class_name(id: String) -> String:
	var c: Variant = _unit_classes.get(unit_class_of(id), null)
	if typeof(c) != TYPE_DICTIONARY:
		return ""
	return String((c as Dictionary).get("name", ""))


## 大类的显示名，**带远近**（远程步兵 / 远程骑兵 / 步兵 / 骑兵）—— HUD 用这一条。
## ★ 「弓箭手算作远程步兵、马弓手算作远程骑兵」就是这一行拼出来的。
func unit_class_line(id: String) -> String:
	var c: Variant = _unit_classes.get(unit_class_of(id), null)
	if typeof(c) != TYPE_DICTIONARY:
		return ""
	var cd: Dictionary = c
	if unit_is_ranged(id):
		return String(cd.get("ranged_name", cd.get("name", "")))
	return String(cd.get("name", ""))


# ------------------------------------------------------------------
# 通用取值
# ------------------------------------------------------------------

## 按 "a.b.c" 路径取一个字典/数组。取不到返回 null。
func get_path_value(path: String) -> Variant:
	var cur: Variant = data
	for part in path.split("."):
		if typeof(cur) == TYPE_DICTIONARY:
			if not (cur as Dictionary).has(part):
				return null
			cur = (cur as Dictionary)[part]
		elif typeof(cur) == TYPE_ARRAY:
			var i := int(part)
			var arr := cur as Array
			if i < 0 or i >= arr.size():
				return null
			cur = arr[i]
		else:
			return null
	return cur


func num(path: String, fallback: float) -> float:
	var v: Variant = get_path_value(path)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return fallback


func int_val(path: String, fallback: int) -> int:
	var v: Variant = get_path_value(path)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return int(v)
	return fallback


func bool_val(path: String, fallback: bool) -> bool:
	var v: Variant = get_path_value(path)
	if typeof(v) == TYPE_BOOL:
		return v
	return fallback


func str_val(path: String, fallback: String) -> String:
	var v: Variant = get_path_value(path)
	if typeof(v) == TYPE_STRING:
		return v
	return fallback


# ------------------------------------------------------------------
# 配色
# ------------------------------------------------------------------

## JSON 里的颜色字符串 → Color。
## 支持 "#rrggbb" 与 "rgba(r,g,b,a)" 两种（与 HTML 版的 CSS 颜色写法一致）。
static func parse_color(s: String, fallback: Color = Color.MAGENTA) -> Color:
	var t := s.strip_edges()
	if t.begins_with("#"):
		return Color(t)
	if t.begins_with("rgba(") or t.begins_with("rgb("):
		var open := t.find("(")
		var close := t.find(")")
		if open < 0 or close < 0 or close <= open:
			return fallback
		var parts := t.substr(open + 1, close - open - 1).split(",")
		var vals: Array[float] = []
		for p in parts:
			vals.append(float(p.strip_edges()))
		if vals.size() < 3:
			return fallback
		var a := vals[3] if vals.size() >= 4 else 1.0
		# 通道值有两个约定：0~255（CSS）或 0~1。按最大值自动判断。
		var scale := 1.0 / 255.0 if maxf(maxf(vals[0], vals[1]), vals[2]) > 1.0 else 1.0
		return Color(vals[0] * scale, vals[1] * scale, vals[2] * scale, a)
	return fallback


## 取 colors.* 里的一项
func color(key: String) -> Color:
	var v: Variant = get_path_value("colors." + key)
	if typeof(v) == TYPE_STRING:
		return parse_color(v)
	return Color.MAGENTA


## 阵营配色。未登记的阵营退回 player —— 保证「配色表只到 p4」这类情况不会崩，
## 也不会把 p5~p8 悄悄画成别的阵营的颜色（见 docs/pitfalls.md 3.12）。
func faction_color(faction: String, field: String = "main") -> Color:
	var v: Variant = get_path_value("colors.faction.%s.%s" % [faction, field])
	if typeof(v) == TYPE_STRING:
		return parse_color(v)
	var fallback: Variant = get_path_value("colors.faction.player.%s" % field)
	if typeof(fallback) == TYPE_STRING:
		return parse_color(fallback)
	return Color.MAGENTA


## 攻击线颜色（由 [r,g,b] 通道 + alpha 现算）。
## HTML 版是拼字符串（`${prefix}${alpha})`，要求每项都以逗号结尾），很脆；
## 这里用 Color 对象，改 alpha 不会拼坏。
func faction_line_color(faction: String, alpha: float) -> Color:
	var v: Variant = get_path_value("colors.faction.%s.line" % faction)
	if typeof(v) != TYPE_ARRAY:
		v = get_path_value("colors.faction.player.line")
	var c := Color(1, 1, 1, alpha)
	if typeof(v) == TYPE_ARRAY and (v as Array).size() >= 3:
		var arr := v as Array
		c = Color(float(arr[0]) / 255.0, float(arr[1]) / 255.0, float(arr[2]) / 255.0, alpha)
	return c


# ------------------------------------------------------------------
# 地图
# ------------------------------------------------------------------

## 单位半径（**格**）—— 将领的默认半径。
## ★ 这里返回的是格，因为 logic/ 全程用格：aggro_range 是 4（格），单位半径也必须是格，
##   否则射程会莫名多出半格。渲染时才乘 cell_px 画圆。
##   ⚠️ 不要写成 unit_radius_factor * cell_px —— 那是像素，混进逻辑判定就会错位
##   （HTML 版的同类事故见 docs/pitfalls.md 3.1）。
## 建筑本体边长比例（config 的 `building.<type>.body_scale`）+ 按类型的缓存。
##
## ★ 为什么要有这个缓存：索敌（nearest_enemy_building）会**每单位每建筑**调一次
##   `body_half()` → `body_scale()`，而原来的写法是
##   `cfg.num("building.%s.body_scale" % type, 1.0)` ——
##   每次一次字符串格式化 + split(".") + 逐层下潜。1000 个单位待命时这一项就是每帧几万次。
var _body_scale_cache: Dictionary = {}


func building_body_scale(type: String) -> float:
	var cached: Variant = _body_scale_cache.get(type, null)
	if cached != null:
		return cached
	var v: float = clampf(num("building.%s.body_scale" % type, 1.0), 0.05, 1.0)
	_body_scale_cache[type] = v
	return v


func unit_radius() -> float:
	return unit_radius_factor


## 某个单位类型对应的单位半径（格）。查不到类型就用兜底值。
##
## ★ 半径是**逻辑参数**而不是纯美术参数：警戒距离要减它、攻击距离要加它
##   （见 combat.gd），所以它必须和战斗数值放在同一张表里。
##   碰撞半径是另一套（unit.collision_radius），两者刻意分开：碰撞要的是「挤不挤」，
##   半径要的是「占多大地方」，混在一起会让小单位挤不过窄口。
## ⚠️ 参数可以是**单位类型 id**，也可以是 kind（将领 kind 会自动换算，见 unit_type_of）。
func unit_radius_of(id: String) -> float:
	var e := unit_type_entry(id)
	if e.is_empty():
		return unit_radius_factor
	return float(e.get("radius_factor", unit_radius_factor))


## 单位类型 id 常量（与 logic/unit.gd 的 const 保持一致）。
## ⚠️ 这里刻意只是字符串字面量而不是 preload：config.gd 是依赖图最底层，
##    让它去 import unit.gd 会形成环（unit.gd 已经 preload 了 config.gd）。
##    unit.gd 那边用 `const X := ConfigRes.X` 引用这里，保证只有一处字面量。
const KIND_GENERAL := "general"
const KIND_ENEMY := "enemy"
const UNIT_TYPE_SPEARMAN := "spearman"
const UNIT_TYPE_LONGBOWMAN := "longbowman"
const UNIT_TYPE_RIDER := "rider"
## 兵种大类（unit.classes）—— 后续「按兵种做额外伤害」的主键。
const CLASS_INFANTRY := "infantry"
const CLASS_CAVALRY := "cavalry"


## 某个单位类型的最大生命
func unit_hp_of(id: String) -> float:
	var e := unit_type_entry(id)
	if e.is_empty():
		return unit_hp_max
	return float(e.get("hp_max", unit_hp_max))


## 某个单位类型的基础移动速度（格 / 秒；森林减速在 unit.speed() 里另外乘）
func unit_speed_of(id: String) -> float:
	var e := unit_type_entry(id)
	if e.is_empty():
		return unit_speed
	return float(e.get("speed", unit_speed))


## 某个单位类型的攻击数值 {damage, range, cooldown_sec}。
## ★ 返回的是**共享的只读字典**（载入时建好），调用方不许改它 ——
##   原先这里每次都新建一个字典，而它每帧每单位都要被读一次。
func unit_combat_of(id: String) -> Dictionary:
	var e := unit_type_entry(id)
	if e.is_empty():
		return _combat_fallback
	var c: Variant = e.get("combat", null)
	return c if typeof(c) == TYPE_DICTIONARY else _combat_fallback


## 某个单位类型的显示名（长枪兵 / 长弓兵 / 骑手 / 测试敌人）。将领类返回「将领」。
func unit_name_of(id: String) -> String:
	# ⚠️ 先判将领：general / general_N 的 unit_type_of() 会算出一个兵种，
	#    不先拦住的话「将领 2」会显示成「长弓兵」（那是它的**类型**，不是它的名字）。
	if is_general_kind(id) and not _unit_types.has(id):
		return "将领"
	var e := unit_type_entry(id)
	if e.is_empty():
		return "单位"
	return String(e.get("name", "单位"))


func zone_capture_color(faction: String) -> Color:
	# 无主（读条还没开始）与「本地玩家那一方」都用那档中性蓝
	# ⚠️ 这里原来还写着 `faction == "player"` —— 那是 p1 的旧别名，已经没有了
	#    （单机 / 房主现在就是 p1，走下面那条 faction_color）。
	if faction == "":
		return color("zone_player")
	return faction_color(faction, "main")


# ------------------------------------------------------------------
# 科技（config.json 的 tech 段）
#
# ★ 与上面的战斗数值表同一条规矩：**载入时整理好、之后只读**。
#   科技页每帧要按这张表重画 3×3 九格（名字 / 第二行小字 / 悬停详情 / 是否已启用），
#   而 `num()` 那种写法每次都要 split(".") + 逐层下潜。
# ------------------------------------------------------------------

func _cache_techs() -> void:
	tech_max_active = maxi(1, int_val("tech.max_active", 3))
	_tech_list = []
	_tech_by_id = {}
	var raw: Variant = get_path_value("tech.list")
	if typeof(raw) != TYPE_ARRAY:
		return
	for item in (raw as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var src: Dictionary = item
		var id := String(src.get("id", ""))
		if id == "":
			continue                       # 没有 id 就没法启用 / 弃用 —— 条目直接丢掉
		var name := String(src.get("name", id))
		var eff: Variant = src.get("effect")
		# ★ line 与 desc 缺省时从 name 兜底（**不**从 effect 现拼文案：
		#   逻辑层不写 UI 文案，效果说明是数据里给的）。
		var line := String(src.get("line", ""))
		var desc := String(src.get("desc", ""))
		var entry := {
			"id": id,
			"name": name,
			"line": line,
			"desc": desc,
			"effect": (eff as Dictionary) if typeof(eff) == TYPE_DICTIONARY else {},
		}
		_tech_list.append(entry)
		_tech_by_id[id] = entry


## 全部科技条目（顺序 = 命令卡九格的顺序；**只读**，别改返回的字典）
func tech_list() -> Array:
	return _tech_list


## 某个科技的条目（查不到返回空字典）
func tech_entry(id: String) -> Dictionary:
	return _tech_by_id.get(id, {})


func has_tech(id: String) -> bool:
	return _tech_by_id.has(id)


## 同一时间最多能启用几个（科技页拒绝第 4 个时的判据）
func tech_max() -> int:
	return tech_max_active


# ------------------------------------------------------------------
# 建筑升级（config.json 的 upgrade 段）
#
# ★★ 等级口径：`levels` 是**等级表**，**最大等级 = 条数**（这里 3 条 ⇒ 1→2→3）。
#    所有查询都按「等级 → 下标 = 等级 - 1」换算，越界一律返回空 / 0 ——
#    不在代码里写死 3：以后加等级只加一条 JSON。
# ------------------------------------------------------------------

func _cache_upgrades() -> void:
	_upgrade_levels = {}
	var raw: Variant = get_path_value("upgrade.levels")
	if typeof(raw) != TYPE_DICTIONARY:
		return
	for type in (raw as Dictionary).keys():
		var rows: Variant = (raw as Dictionary)[type]
		if typeof(rows) != TYPE_ARRAY:
			continue
		var table: Array = []
		for item in (rows as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var d: Dictionary = item
			var cost: Variant = d.get("cost", {})
			table.append({
				"level": int(d.get("level", table.size() + 1)),
				"hp_mult": maxf(0.01, float(d.get("hp_mult", 1.0))),
				"cost": (cost as Dictionary) if typeof(cost) == TYPE_DICTIONARY else {},
				"time_sec": maxf(0.0, float(d.get("time_sec", 0.0))),
			})
		_upgrade_levels[String(type)] = table


## 某个建筑类型有没有升级表（区划中心没有 → 它的操作页只有特化）
func has_upgrade(type: String) -> bool:
	return not upgrade_levels(type).is_empty()


## 某个建筑类型的等级表（只读；下标 0 = 1 级）
func upgrade_levels(type: String) -> Array:
	var v: Variant = _upgrade_levels.get(type, [])
	return v if typeof(v) == TYPE_ARRAY else []


## 最大等级（= 等级表的条数；没有表 → 1，也就是「不能升」）
func upgrade_max_level(type: String) -> int:
	return maxi(1, upgrade_levels(type).size())


## 某个等级那一行（越界返回空字典）
func upgrade_row(type: String, level: int) -> Dictionary:
	var rows := upgrade_levels(type)
	var i: int = level - 1
	if i < 0 or i >= rows.size():
		return {}
	return rows[i]


## 某个等级的**血量上限倍率**（= 该行 hp_mult；越界按 1.0）
func upgrade_hp_mult(type: String, level: int) -> float:
	var row := upgrade_row(type, level)
	return maxf(0.01, float(row.get("hp_mult", 1.0))) if not row.is_empty() else 1.0


## 「从 level 升到 level+1」要花的钱 / 读条秒数（已经是最高级 → 空字典 / 0）。
## ★ 读的是**目标等级那一行**（`level` 级那行写的是「升到它」的代价，
##   所以 1 级那行没有 cost —— 这正好表达「开局就是 1 级，不用花钱」）。
func upgrade_cost_to(type: String, level: int) -> Dictionary:
	var row := upgrade_row(type, level + 1)
	var c: Variant = row.get("cost", {})
	return c if typeof(c) == TYPE_DICTIONARY else {}


func upgrade_time_to(type: String, level: int) -> float:
	var row := upgrade_row(type, level + 1)
	return maxf(0.0, float(row.get("time_sec", 0.0)))


# ------------------------------------------------------------------
# 区划种类（config.json 的 zone_kind 段）
#
# ★★ 这一层只回答四件事（判定与文案在别处）：
#   1. 有哪几种区划、各自叫什么（`zone_kind_list` / `zone_kind_name`）；
#   2. 地图没写 kind 时算哪一种（`zone_kind_default`）；
#   3. 选这个种类时编辑器该同步出什么产量（`zone_kind_production`；
#      ⚠️ 游戏侧**不用**它兜底：没写 production 就是 0）；
#   4. 这个种类允许做哪些特化（`zone_kind_specs` / `zone_kind_allows_spec`）。
# ⚠️ 表里查不到的 kind 一律退回 `default` 那一档 —— 地图可以被手改，
#   写一个不认识的 kind 不该让游戏崩，也不该让那个区划凭空多出产量。
# ------------------------------------------------------------------

func _cache_zone_kinds() -> void:
	_zone_kind_list = []
	_zone_kind_by_id = {}
	var raw: Variant = get_path_value("zone_kind.list")
	if typeof(raw) == TYPE_ARRAY:
		for item in (raw as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var src: Dictionary = item
			var id := String(src.get("id", ""))
			if id == "":
				continue                       # 没有 id 就查不到，条目直接丢掉
			# 预设产能：只留三档、负数当 0（与地图那边的夹法一致）
			var prod_out := {"food": 0.0, "gold": 0.0, "population": 0.0}
			var prod: Variant = src.get("production", {})
			if typeof(prod) == TYPE_DICTIONARY:
				for k in prod_out.keys():
					prod_out[k] = maxf(0.0, float((prod as Dictionary).get(k, 0.0)))
			# 允许的特化 id 列表（顺序 = 界面上的顺序）
			var spec_out: Array = []
			var specs: Variant = src.get("specs", [])
			if typeof(specs) == TYPE_ARRAY:
				for s in (specs as Array):
					var sid := String(s)
					if sid != "" and not spec_out.has(sid):
						spec_out.append(sid)
			var entry := {
				"id": id,
				"name": String(src.get("name", id)),
				"line": String(src.get("line", "")),
				"production": prod_out,
				"specs": spec_out,
			}
			_zone_kind_list.append(entry)
			_zone_kind_by_id[id] = entry

	# 默认种类：配置里写了且真的存在才用它；否则优先 "population"（用户确认的默认），
	# 再否则退回第一个条目。
	# ⚠️ 不能直接取「表里的第一个」：配置顺序一变，默认种类就跟着变
	#    （`zone_kind.list` 的第一个恰好是 food，那会让「地图没写 kind」变成粮食区划）。
	var want := str_val("zone_kind.default", "")
	if want != "" and _zone_kind_by_id.has(want):
		_zone_kind_default = want
	elif _zone_kind_by_id.has("population"):
		_zone_kind_default = "population"
	elif not _zone_kind_list.is_empty():
		_zone_kind_default = String((_zone_kind_list[0] as Dictionary)["id"])
	else:
		_zone_kind_default = "population"


## 全部区划种类（顺序 = 界面上显示的顺序；**只读**，别改返回的字典）
func zone_kind_list() -> Array:
	return _zone_kind_list


## 地图没写 kind 的区划算哪一种（用户确认 = population）
func zone_kind_default() -> String:
	return _zone_kind_default


func has_zone_kind(id: String) -> bool:
	return _zone_kind_by_id.has(id)


## 某个种类的条目；**查不到退回默认那一档**（手改地图写错 kind 时的兜底）。
func zone_kind_entry(id: String) -> Dictionary:
	var k := id
	if not _zone_kind_by_id.has(k):
		k = _zone_kind_default
	if not _zone_kind_by_id.has(k) and not _zone_kind_list.is_empty():
		k = String((_zone_kind_list[0] as Dictionary)["id"])
	return _zone_kind_by_id.get(k, {})


## 某个种类的显示名（查不到 → 默认那一档的名字；再查不到 → id 原样）
func zone_kind_name(id: String) -> String:
	var e := zone_kind_entry(id)
	if e.is_empty():
		return id
	return String(e.get("name", id))


## 这个种类「选种类时同步进数字输入框」的那三个数（每地块每秒）。
## ⚠️ 拷贝一份给调用方：条目里的字典是**共享只读**的，被谁改一下就会污染整张表。
func zone_kind_production(id: String) -> Dictionary:
	var e := zone_kind_entry(id)
	var p: Variant = e.get("production", {})
	var out := {"food": 0.0, "gold": 0.0, "population": 0.0}
	if typeof(p) == TYPE_DICTIONARY:
		for k in out.keys():
			out[k] = float((p as Dictionary).get(k, 0.0))
	return out


## 这个种类允许做哪些特化（id 数组）
func zone_kind_specs(id: String) -> Array:
	var e := zone_kind_entry(id)
	var v: Variant = e.get("specs", [])
	return v if typeof(v) == TYPE_ARRAY else []


## 这个种类能不能做这种特化（逻辑层「按种类限制特化」的唯一判据）
func zone_kind_allows_spec(kind: String, spec_id: String) -> bool:
	return zone_kind_specs(kind).has(spec_id)


# ------------------------------------------------------------------
# 区划特化（config.json 的 zone_spec 段）
# ------------------------------------------------------------------

func _cache_zone_specs() -> void:
	_spec_list = []
	_spec_by_id = {}
	var c: Variant = get_path_value("zone_spec.cost")
	_spec_cost = (c as Dictionary) if typeof(c) == TYPE_DICTIONARY else {}
	_spec_time_sec = maxf(0.0, float(num("zone_spec.time_sec", 0.0)))
	var raw: Variant = get_path_value("zone_spec.list")
	if typeof(raw) != TYPE_ARRAY:
		return
	for item in (raw as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var src: Dictionary = item
		var id := String(src.get("id", ""))
		if id == "":
			continue
		var eff: Variant = src.get("effect", {})
		var entry := {
			"id": id,
			"name": String(src.get("name", id)),
			"line": String(src.get("line", "")),
			"desc": String(src.get("desc", "")),
			"effect": (eff as Dictionary) if typeof(eff) == TYPE_DICTIONARY else {},
		}
		_spec_list.append(entry)
		_spec_by_id[id] = entry


## 全部特化条目（顺序 = 操作页里那三格的顺序；只读）
func spec_list() -> Array:
	return _spec_list


func spec_entry(id: String) -> Dictionary:
	return _spec_by_id.get(id, {})


func has_spec(id: String) -> bool:
	return _spec_by_id.has(id)


## 特化的消耗 / 读条时间（条目没写就退回 zone_spec 的共用默认值）
func spec_cost(id: String) -> Dictionary:
	var c: Variant = spec_entry(id).get("cost", null)
	if typeof(c) == TYPE_DICTIONARY:
		return c
	return _spec_cost


func spec_time_sec(id: String) -> float:
	var v: Variant = spec_entry(id).get("time_sec", null)
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return maxf(0.0, float(v))
	return _spec_time_sec
