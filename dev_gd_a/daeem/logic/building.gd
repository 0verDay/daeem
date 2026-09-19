## building.gd —— 建筑：大本营 / 城墙 / 箭塔（对应 HTML 版 js/building.js）
##
## ★★ 两套「挡不挡」是分开的（这是 UI 改版之后重做的碰撞模型，别再混在一起）：
##
##   1. **格级** `blocks(faction)` —— 只给 A* 用：这一格整体能不能走。
##      城墙 = 填满整格 → 敌方整格不可进；己方放行。
##      大本营 / 箭塔 = 本体小于一格，**整格对谁都不封**（缝隙要能走）。
##
##   2. **本体级** `body_blocks(faction)` —— 只给移动碰撞用：本体那块方块挡不挡。
##      本体永远居中，边长 = body_scale × 格宽（body_scale 在 config.json 里）。
##      规则：**挡敌方、不挡己方**。城墙的 body_scale = 1.0，于是「本体挡」≡「整格挡」，
##      与从前的行为逐位一致。
##
##   为什么大本营/箭塔不再整格阻挡：需求是「本体阻挡敌方，但敌方可以从建筑空隙穿过，
##   本体不阻挡己方」。整格阻挡就没法让出缝隙（见 docs/route.md 第十节）。
##
## 其余核心规则：
##   - 每个地块最多一个建筑
##   - **城墙有血量**：被敌人打光就塌，让出一条路；敌人「先靠近、再拆」见 combat.gd
##   - 箭塔：每 cooldown 秒对射程内**最近的**敌人造成单体伤害
##   - 所有数值来自 config.json，这里不写死数字
extends RefCounted

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")

const TYPE_BASE := "base"
const TYPE_WALL := "wall"
const TYPE_TOWER := "tower"

## 建筑定义表。blocks_* 是**格级**、body_blocks_* 是**本体级** —— 别按阵营写死，
## 两侧都走 same_side()，见下面 blocks() / body_blocks() 的注释。
const DEFS := {
	"base": {
		"id": "base", "name": "大本营", "buildable": false,
		# 本体小于一格 → 整格不再封锁（缝隙留给移动碰撞去管）
		"blocks_player": false, "blocks_enemy": false,
		# 本体：挡敌方、不挡己方
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"wall": {
		"id": "wall", "name": "城墙", "buildable": true,
		# 城墙填满整格：敌方连格子都进不来（语义与从前一致）
		"blocks_player": false, "blocks_enemy": true,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"tower": {
		"id": "tower", "name": "箭塔", "buildable": true,
		"blocks_player": false, "blocks_enemy": false,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
}

var type: String = TYPE_WALL
var tx: int = 0
var ty: int = 0
var owner: String = FactionRes.DEFAULT_FACTION
var zone_id: int = -1
var hp: float = 300.0
var hp_max: float = 300.0
var alive: bool = true

## ---- 箭塔 ----
var cooldown_left: float = 0.0

## ---- 渲染用（不进快照、纯表现）----
var last_target = null      # 最近锁定的目标单位，画攻击线用
var flash: float = 0.0      # 受击闪光 1 → 0


static func create(cfg: ConfigRes, p_type: String, p_tx: int, p_ty: int, p_owner: String, p_zone_id: int = -1) -> RefCounted:
	var b = new()
	b.type = p_type
	b.tx = p_tx
	b.ty = p_ty
	b.owner = p_owner
	b.zone_id = p_zone_id
	b.hp_max = b.max_hp_from_config(cfg)
	b.hp = b.hp_max
	return b


## 该类型的基础血量（来自 config.json）
func max_hp_from_config(cfg: ConfigRes) -> float:
	match type:
		TYPE_BASE:
			return cfg.num("building.base.hp_max", 1000.0)
		TYPE_WALL:
			return cfg.num("building.wall.hp_max", 300.0)
		TYPE_TOWER:
			return cfg.num("building.tower.hp_max", 300.0)
	return 300.0


func def() -> Dictionary:
	return DEFS.get(type, DEFS["wall"])


func display_name() -> String:
	return String(def().get("name", type))


## 箭塔数值（config.json；非箭塔返回 0）
func tower_damage(cfg: ConfigRes) -> float:
	return cfg.num("building.tower.damage", 0.0) if type == TYPE_TOWER else 0.0


func tower_range(cfg: ConfigRes) -> float:
	return cfg.num("building.tower.range", 0.0) if type == TYPE_TOWER else 0.0


func tower_cooldown(cfg: ConfigRes) -> float:
	return cfg.num("building.tower.cooldown", 0.0) if type == TYPE_TOWER else 0.0


## 该建筑**整格**是否阻挡某个阵营的单位（只给 A* 用）。
##
## ★★ 判定基准必须是 `same_side(faction, owner)`（「是不是我自己人」），
##    **不是** `faction == 'player'`。
##    原来只有两个阵营时这两种写法等价（城墙的 blocks_player=false / blocks_enemy=true
##    恰好就是「自己人不挡、外人挡」），所以单机行为逐位不变；
##    但联机下 p2 的城墙对 p1 必须阻挡，旧写法会错误地放行 —— 见 docs/pitfalls.md 3.7。
##
## ⚠️ 大本营 / 箭塔在这里**对谁都返回 false**：它们本体小于一格，整格不封，
##    真正的阻挡交给 body_blocks() + 移动碰撞（见文件头）。
func blocks(faction: String) -> bool:
	if FactionRes.same_side(faction, owner):
		return bool(def().get("blocks_player", true))
	return bool(def().get("blocks_enemy", true))


## 该建筑的**本体**是否阻挡某个阵营（只给移动碰撞用）。
## 城墙 body_scale = 1.0，所以它这里与 blocks() 等价；大本营 / 箭塔只挡敌方。
func body_blocks(faction: String) -> bool:
	if FactionRes.same_side(faction, owner):
		return bool(def().get("body_blocks_player", false))
	return bool(def().get("body_blocks_enemy", true))


## 本体边长占一格的比例（config.json；缺省按整格算，宁可挡死也不要漏）
func body_scale(cfg: ConfigRes) -> float:
	return clampf(cfg.num("building.%s.body_scale" % type, 1.0), 0.05, 1.0)


## 本体半边长（格）
func body_half(cfg: ConfigRes) -> float:
	return body_scale(cfg) * 0.5


## 本体矩形（**格**坐标，居中放在自己那一格里）。
## ★ 渲染与碰撞都读它 —— 视觉大小与碰撞大小必须是同一个数，不许各写一套内缩量。
func body_rect(cfg: ConfigRes) -> Rect2:
	var half := body_half(cfg)
	return Rect2(Vector2(tx + 0.5 - half, ty + 0.5 - half), Vector2(half * 2.0, half * 2.0))


## 线段（格坐标）是否切进本体（pad = 单位半径之类的外扩量）。
## 给寻路的拉直用：本体小于一格之后，整格判定放行了，直线还得自己避开本体。
func blocks_segment(cfg: ConfigRes, a: Vector2, b: Vector2, pad: float) -> bool:
	var r := body_rect(cfg)
	r = r.grow(maxf(0.0, pad))
	return _segment_hits_rect(a, b, r)


## 建筑中心（**格**坐标，逻辑层全程用格）
func center() -> Vector2:
	return Vector2(tx + 0.5, ty + 0.5)


## 点到本体的最近点（用来算「挤不挤得过去」的缝宽）
func closest_point_on_body(cfg: ConfigRes, p: Vector2) -> Vector2:
	var r := body_rect(cfg)
	return Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))


## 线段 vs 轴对齐矩形（slab 法）。
## 不用 Geometry2D / Rect2 的现成函数是刻意的：这两个 API 在不同 Godot 版本里
## 名字与语义都变过，而这段只有十几行、还能直接写断言（见 tests/test_building_body.gd）。
static func _segment_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	var d := b - a
	var tmin := 0.0
	var tmax := 1.0
	# x 轴
	if absf(d.x) < 1e-12:
		if a.x < r.position.x or a.x > r.end.x:
			return false
	else:
		var t1: float = (r.position.x - a.x) / d.x
		var t2: float = (r.end.x - a.x) / d.x
		tmin = maxf(tmin, minf(t1, t2))
		tmax = minf(tmax, maxf(t1, t2))
		if tmin > tmax:
			return false
	# y 轴
	if absf(d.y) < 1e-12:
		if a.y < r.position.y or a.y > r.end.y:
			return false
	else:
		var t3: float = (r.position.y - a.y) / d.y
		var t4: float = (r.end.y - a.y) / d.y
		tmin = maxf(tmin, minf(t3, t4))
		tmax = minf(tmax, maxf(t3, t4))
		if tmin > tmax:
			return false
	return true


## 血量比例（渲染 / HUD 用）
func hp_ratio() -> float:
	if hp_max <= 0.0:
		return 0.0
	return clampf(hp / hp_max, 0.0, 1.0)


## 受到伤害（单位拆建筑都走这里）：扣血 + 记一次受击闪光。
##
## ★ 大本营**默认不可摧毁**：血量最低留 1，避免出现「活着但血量 0」的状态（单机行为）。
##   对战模式把 config.pvp.destructible_base 打开，它就能被真正打掉 ——
##   打掉某一方的大本营 = 那一方落败，这就是胜负条件。
##
## @return bool **本击是否造成了摧毁**（false = 没打死 / 早就死了）。
##
## ⚠️ 返回值语义是「刚才这一下打死了它」，**不是**「它现在还活着」。
##    HTML 版用的是后者，于是同一帧里第二个攻击者打一栋已经 0 血的墙，
##    也会再广播一次 building_down —— 三个将领围着一堵墙就是三条重复事件。
##    调用方只该在**首次**摧毁时广播（见 combat.attack_building）。
func take_damage(cfg: ConfigRes, amount: float, _source = null) -> bool:
	if not alive:
		return false                       # 早就死了，不重复报销
	flash = 1.0
	var destructible: bool = cfg.destructible_base
	var floor_hp: float = 1.0 if (type == TYPE_BASE and not destructible) else 0.0
	hp = maxf(floor_hp, hp - amount)
	if hp <= 0.0:
		# 就地标记；真正的摘除由 world.tick() 末尾统一做（逻辑层不在遍历中改集合）
		alive = false
		return true
	return false


## 是否处于「还在场、可被选/可被打」的状态
func is_selectable() -> bool:
	return alive
