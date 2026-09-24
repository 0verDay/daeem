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
## ⚠️ 数值路径用 `.` 分隔（"combat.general.damage"）。返回的是 JSON 里的原始类型，
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

## ---- 亲兵数值（unit_*_of(kind) 每帧每单位都会查一次）----
var sub_hp_max: float = 80.0
var sub_speed: float = 0.6
var sub_damage: float = 14.0
var sub_range: float = 1.0
var sub_cooldown_sec: float = 1.1
var sub_radius_factor: float = 0.065

## 战斗数值表：**载入时建好、之后只读**（原先每次 unit_combat_of() 都新建一个字典）
var _combat_general: Dictionary = {}
var _combat_enemy: Dictionary = {}
var _combat_subordinate: Dictionary = {}

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
var general_damage: float = 26.0
var general_range: float = 1.0
var general_cooldown: float = 0.9
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

	sub_hp_max = num("unit.subordinate.hp_max", 80.0)
	sub_speed = num("unit.subordinate.speed", unit_speed)
	sub_damage = num("unit.subordinate.damage", 14.0)
	sub_range = num("unit.subordinate.range", 1.0)
	sub_cooldown_sec = num("unit.subordinate.cooldown_sec", 1.1)
	sub_radius_factor = num("unit.subordinate.radius_factor", unit_radius_factor)

	combat_enabled = bool_val("combat.enabled", true)
	aggro_range = num("combat.aggro_range", 4.0)
	leash_factor = num("combat.leash_factor", 1.8)
	repath_sec = num("combat.repath_sec", 0.3)
	repath_min_move = num("combat.repath_min_move", 0.5)
	chase_direct_range = num("combat.chase_direct_range", 8.0)
	flash_sec = num("combat.flash_sec", 0.22)
	flash_sec_safe = maxf(0.01, flash_sec)
	building_damage = num("combat.building_damage", 40.0)
	general_damage = num("combat.general.damage", 26.0)
	general_range = num("combat.general.range", 1.0)
	general_cooldown = num("combat.general.cooldown_sec", 0.9)
	enemy_damage = num("combat.enemy.damage", 10.0)
	enemy_range = num("combat.enemy.range", 1.0)
	enemy_cooldown = num("combat.enemy.cooldown_sec", 1.2)

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

	enemy_speed = num("debug.enemy_speed", 0.45)
	enemy_hp = num("debug.enemy_hp", 60.0)

	_cache_techs()
	_cache_upgrades()
	_cache_zone_specs()

	# 战斗数值表：建一次、之后只读。
	# ⚠️ 调用方**不要改**返回的字典（它是共享的）—— 要改数值就改 JSON 后重新 load。
	_combat_general = {"damage": general_damage, "range": general_range, "cooldown_sec": general_cooldown}
	_combat_enemy = {"damage": enemy_damage, "range": enemy_range, "cooldown_sec": enemy_cooldown}
	_combat_subordinate = {"damage": sub_damage, "range": sub_range, "cooldown_sec": sub_cooldown_sec}


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


## 某个单位种类对应的单位半径（格）。
##
## ★ 亲兵比将领小一点，所以「谁大谁小」一眼能看出来 —— 但那只是**体积**，
##   它会影响判定（警戒距离减体积、攻击距离加体积），所以是个逻辑参数而不是纯美术参数。
##   碰撞半径是另一套（unit.collision_radius），两者刻意分开：碰撞要的是「挤不挤」，
##   体积要的是「占多大地方」，混在一起会让小单位挤不过窄口。
func unit_radius_of(kind: String) -> float:
	if kind == KIND_SUBORDINATE:
		return sub_radius_factor
	return unit_radius_factor


## 单位种类 id（与 logic/unit.gd 的 const 保持一致）。
## ⚠️ 这里刻意只是字符串字面量而不是 preload：config.gd 是依赖图最底层，
##    让它去 import unit.gd 会形成环（unit.gd 已经 preload 了 config.gd）。
const KIND_SUBORDINATE := "subordinate"


## 某个单位种类的最大生命
func unit_hp_of(kind: String) -> float:
	match kind:
		"enemy":
			return enemy_hp
		KIND_SUBORDINATE:
			return sub_hp_max
	return unit_hp_max


## 某个单位种类的基础移动速度（格 / 秒；森林减速在 unit.speed() 里另外乘）
func unit_speed_of(kind: String) -> float:
	match kind:
		"enemy":
			return enemy_speed
		KIND_SUBORDINATE:
			return sub_speed
	return unit_speed


## 某个单位种类的攻击数值 {damage, range, cooldown_sec}。
## ★ 返回的是**共享的只读字典**（载入时建好），调用方不许改它 ——
##   原先这里每次都新建一个字典，而它每帧每单位都要被读一次。
func unit_combat_of(kind: String) -> Dictionary:
	match kind:
		"enemy":
			return _combat_enemy
		KIND_SUBORDINATE:
			return _combat_subordinate
	return _combat_general


## 某个单位种类的显示名
func unit_name_of(kind: String) -> String:
	var v = get_path_value("unit.%s.name" % kind)
	if typeof(v) == TYPE_STRING:
		return v
	return "敌人" if kind == "enemy" else "将领"


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
#   科技页每帧要按这张表重画 3×3 九格（名字 / 第二行小字 / tooltip / 是否已启用），
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
