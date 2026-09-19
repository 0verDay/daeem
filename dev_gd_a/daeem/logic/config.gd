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
const DEFAULT_MAP_PATH := "res://data/map_01.json"

## 缓存 JSON 的字典形式（阵营 id → 字典 / 颜色名 → 字典 这类查找用得着）
var data: Dictionary = {}

## ---- 常用标量（载入时算好，避免逻辑层到处 `num("...")`）----
## ⚠️ cell_px 是**全项目唯一允许存在的像素常量**，而且它只该被 view/ 读
##    （palette.to_px / tile_rect / unit_radius_px）。logic/ 里出现它 = 坐标单位混用的信号。
##    它放在这里而不是 view/，只是为了让所有可调数值集中在同一个 JSON 里。
var cell_px: float = 64.0
var cols: int = 24
var rows: int = 16

var unit_speed: float = 2.4
var unit_forest_mult: float = 0.5
var unit_hp_max: float = 200.0
var unit_radius_factor: float = 0.1

var combat_enabled: bool = true
var aggro_range: float = 4.0
var leash_factor: float = 1.8
var repath_sec: float = 0.3
var flash_sec: float = 0.22
var building_damage: float = 40.0
var general_damage: float = 26.0
var general_range: float = 1.0
var general_cooldown: float = 0.9
var enemy_damage: float = 10.0
var enemy_range: float = 1.0
var enemy_cooldown: float = 1.2

var zone_cols: int = 6
var zone_rows: int = 4
var capture_time_sec: float = 4.0
var decay_per_sec: float = 0.125
var zone_owned_by_building: bool = true

var food_per_tile_per_sec: float = 1.0
var gold_per_tile_per_sec: float = 1.0
var start_food: float = 0.0
var start_gold: float = 0.0

var respawn_sec: float = 0.0
var destructible_base: bool = false

var enemy_speed: float = 1.8
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
	cell_px = num("render.cell_px", 64.0)

	unit_speed = num("unit.speed", 2.4)
	unit_forest_mult = num("unit.forest_mult", 0.5)
	unit_hp_max = num("unit.hp_max", 200.0)
	unit_radius_factor = num("unit.radius_factor", 0.1)

	combat_enabled = bool_val("combat.enabled", true)
	aggro_range = num("combat.aggro_range", 4.0)
	leash_factor = num("combat.leash_factor", 1.8)
	repath_sec = num("combat.repath_sec", 0.3)
	flash_sec = num("combat.flash_sec", 0.22)
	building_damage = num("combat.building_damage", 40.0)
	general_damage = num("combat.general.damage", 26.0)
	general_range = num("combat.general.range", 1.0)
	general_cooldown = num("combat.general.cooldown_sec", 0.9)
	enemy_damage = num("combat.enemy.damage", 10.0)
	enemy_range = num("combat.enemy.range", 1.0)
	enemy_cooldown = num("combat.enemy.cooldown_sec", 1.2)

	zone_cols = int_val("zone.zone_cols", 6)
	zone_rows = int_val("zone.zone_rows", 4)
	capture_time_sec = num("zone.capture_time_sec", 4.0)
	decay_per_sec = num("zone.decay_per_sec", 0.125)
	zone_owned_by_building = bool_val("zone.zone_owned_by_building", true)

	food_per_tile_per_sec = num("resource.food_per_tile_per_sec", 1.0)
	gold_per_tile_per_sec = num("resource.gold_per_tile_per_sec", 1.0)
	start_food = num("resource.start_food", 0.0)
	start_gold = num("resource.start_gold", 0.0)

	respawn_sec = num("pvp.respawn_sec", 8.0)
	destructible_base = bool_val("pvp.destructible_base", false)

	enemy_speed = num("debug.enemy_speed", 1.8)
	enemy_hp = num("debug.enemy_hp", 60.0)


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
		return num("unit.subordinate.radius_factor", unit_radius_factor)
	return unit_radius()


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
			return num("unit.subordinate.hp_max", 80.0)
	return unit_hp_max


## 某个单位种类的基础移动速度（格 / 秒；森林减速在 unit.speed() 里另外乘）
func unit_speed_of(kind: String) -> float:
	match kind:
		"enemy":
			return enemy_speed
		KIND_SUBORDINATE:
			return num("unit.subordinate.speed", unit_speed)
	return unit_speed


## 某个单位种类的攻击数值 {damage, range, cooldown_sec}
func unit_combat_of(kind: String) -> Dictionary:
	match kind:
		"enemy":
			return {"damage": enemy_damage, "range": enemy_range, "cooldown_sec": enemy_cooldown}
		KIND_SUBORDINATE:
			return {
				"damage": num("unit.subordinate.damage", 14.0),
				"range": num("unit.subordinate.range", 1.0),
				"cooldown_sec": num("unit.subordinate.cooldown_sec", 1.1),
			}
	return {"damage": general_damage, "range": general_range, "cooldown_sec": general_cooldown}


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
