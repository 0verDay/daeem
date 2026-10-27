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
## ★★ 2026.10.26：第二行建筑（2 级大本营解锁）—— 内部 id 与基础版分开，显示名不同。
const TYPE_STONE_WALL := "stone_wall"
const TYPE_WATCH_TOWER := "watch_tower"
## 区划中心：地图编辑器在「区块」页签里给每个区划指定的那一格。
##
## ★ 它是**中立物**（用户需求：无血量、无敌、没有攻击手段，且**不阻挡任何单位**）：
##     · owner = ""（不属于任何阵营）→ 一切 `same_side*` 判据恒为 false，
##       但本轮的 `blocks_*` / `body_blocks_*` 四个标志**都是 false** ⇒ 谁都能进、谁都能站；
##     · 没有血量（`take_damage` 对它无效）、没有攻击手段（不进 update_towers）；
##     · 不会被索敌 / 被箭塔锁定 / 被拆（`invulnerable`）。
## ★ 点它 = 看它所属区划的详情（`world.zone_center_at()` → HUD / 详情面板）。
const TYPE_ZONE_CENTER := "zone_center"

## 建筑定义表。blocks_* 是**格级**、body_blocks_* 是**本体级** —— 别按阵营写死，
## 两侧都走 same_side_for_attack()，见下面 blocks() / body_blocks() 的注释。
##
## ★★ 可建造的建筑（大本营 / 城墙 / 箭塔）的定义在 config.json 的 `building` 段**
##    （editor：tools/unit_editor 的「建筑」页），这里是**内置兜底** ——
##    `def()` 读的是 `cfg.building_def(type, DEFS.get(type, …))`，**config 里写的键优先**。
##    搬家的理由：建造页原本是遍历这张表生成的，于是「编辑器里加一栋楼」在游戏里根本
##    出不来（一个死字段）。现在加建筑 = 加一条 config，代码一行不改。
##    ★ **视野半径（战争迷雾）也是一个「每类型一个值」**：`building.<type>.vision`
##      （城墙 5 / 箭塔 12 / 大本营 9），在 `create()` 时抄进 `b.vision`
##      —— 与 `unit.types.<id>.vision` → `u.vision` 完全对称，见 `vision` 字段的说明。
## ★ 这张表剩下的两件事：
##    · **区划中心**（`zone_center`）—— 它不是建筑（无血量 / 无敌 / 不可拆），
##      编辑器不管它，所以它只在这里定义；
##    · 未知类型的兜底（手改地图写出一个不认识的 type 时按城墙算）。
const DEFS := {
	"base": {
		"id": "base", "name": "大本营", "buildable": false,
		# 本体小于一格 → 整格不再封锁（缝隙留给移动碰撞去管）
		"blocks_player": false, "blocks_enemy": false,
		# 本体：挡敌方、不挡己方
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"wall": {
		"id": "wall", "name": "木墙", "buildable": true,
		# 城墙填满整格：敌方连格子都进不来（语义与从前一致）
		"blocks_player": false, "blocks_enemy": true,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"tower": {
		"id": "tower", "name": "哨塔", "buildable": true,
		"blocks_player": false, "blocks_enemy": false,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"stone_wall": {
		"id": "stone_wall", "name": "石墙", "buildable": true,
		"blocks_player": false, "blocks_enemy": true,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"watch_tower": {
		"id": "watch_tower", "name": "警戒塔", "buildable": true,
		"blocks_player": false, "blocks_enemy": false,
		"body_blocks_player": false, "body_blocks_enemy": true,
	},
	"zone_center": {
		"id": "zone_center", "name": "区划中心", "buildable": false,
		# ★ 两侧都 false：**不阻挡任何单位**（本格可通行、本体也不挡移动）。
		#   它仍然是无血量 / 无敌的中立物（见 take_damage），只是不再挡路。
		"blocks_player": false, "blocks_enemy": false,
		"body_blocks_player": false, "body_blocks_enemy": false,
		# 无血量 / 无敌（见 take_damage）；也没有攻击手段
		"invulnerable": true,
	},
}

## 完全不认识的 type 按它算（宁可挡死也不要漏 —— 与从前 `DEFS.get(type, DEFS["wall"])` 一致）
const FALLBACK_DEF := {
	"id": "unknown", "name": "建筑", "buildable": false,
	"blocks_player": false, "blocks_enemy": true,
	"body_blocks_player": false, "body_blocks_enemy": true,
}

## ★ 这个建筑类型是不是「配置里定义的建筑」（区划中心不是 —— 它是中立障碍）
static func is_building_type(cfg: ConfigRes, type: String) -> bool:
	return type != TYPE_ZONE_CENTER and cfg != null and cfg.has_building_type(type)

var type: String = TYPE_WALL
var tx: int = 0
var ty: int = 0
var owner: String = FactionRes.DEFAULT_FACTION
var zone_id: int = -1
var hp: float = 300.0
var hp_max: float = 300.0
var alive: bool = true

## ★★ 这一栋认得的配置对象（`create()` 塞进来的）。
##   为什么挂在实例上而不是当参数一路传：`def()` / `display_name()` / `blocks()` /
##   `body_blocks()` 这些方法在渲染、寻路、索敌里被到处调用，全改成带 cfg 的参数会
##   牵动一大片签名（而它们的语义就是「这一栋楼自己是什么」）。
var cfg: ConfigRes = null

## 上一次施加的**科技血量倍率**（1.0 = 没加成）——见 `apply_hp_bonus()` 的粘性说明。
var tech_hp_mult: float = 1.0
## ★ 这栋建筑**建出来时的上限**（config 给的那个数，永不被科技 / 等级改写）。
## 上限每次都是「基础值 × 等级倍率 × 科技倍率」重算，而不是在旧上限上再乘一次 ——
## 这样升级 / 降级 / 科技启用弃用反复切换都不会累积误差，弃用后能精确回到原值。
var base_hp_max: float = 300.0
## ★ 上次按等级算出来的上限倍率（见 `apply_hp_bonus`）
var level_hp_mult: float = 1.0

## ★★ 大本营被击毁后，该阵营的残余建筑会进入「中立化」：保留 owner（区划归属不变），
##   但停止开火 / 升级，并由视图统一画成灰色。见 world.neutralize_faction()。
var neutralized: bool = false

## ★★ 等级与升级读条（见 logic/upgrade.gd）。
##   等级从 1 起；`upgrade_*` 是**读条状态**（remaining/total <= 0 = 没在读条）。
##   ⚠️ 它们挂在建筑自己身上（与「招募队列挂在将领 / 区划上」同一个理由：
##      「这栋楼正在干嘛」属于这栋楼）。
var level: int = 1
var upgrade_remaining: float = 0.0
var upgrade_total: float = 0.0
## 升级已经扣掉的钱（取消时按它全额退款）
var upgrade_cost_food: float = 0.0
var upgrade_cost_gold: float = 0.0

## ★★ 将领重生队列（只对**大本营**有意义；见 logic/world.gd 的 on_general_death）。
##
## · `respawn_queue` 的**队首**就是正在倒计时的那位，后面是排队的；
## · 存的是**单位对象**（RefCounted）而不是 id：阵亡将领已经从 `world.units`
##   摘掉了，这个队列是它唯一的引用（重生时再放回 units）；
## · 串行：队首读完才轮到下一位（用户口径「进入大本营的招募队列」）；
## · 队列不为空时 `is_respawning()` 为真，`upgrade.can_upgrade()` 会拒新升级。
var respawn_queue: Array = []       # [{ "unit": <RefCounted>, "secs": float }]
var respawn_active: bool = false
var respawn_remaining: float = 0.0
var respawn_total: float = 0.0

## ★ 客机展示用（快照写入；权威侧自己是空的）。
##   ⚠️ 客机不持有死将对象，所以只同步「几个人 / 当前是谁 / 剩几秒」这一组展示字段。
var respawn_remote_count: int = 0
var respawn_remote_remaining: float = 0.0
var respawn_remote_total: float = 0.0
var respawn_remote_name: String = ""

## ★★ 视野半径（**格**）—— 战争迷雾用（见 logic/fog.gd）。
##
## ★ 与单位的 `u.vision` 是**完全对称**的一处：数值来自 config 的
##   `building.<type>.vision`（没写就退回 `fog.vision_building`），
##   在 `create()` 那一刻就抄到对象身上 —— 于是迷雾每帧只读这一个字段，
##   不做「每帧每建筑一次 JSON 下潜」。
## ⚠️ 它不是玩法数值：阻挡、血量、攻击一律不受它影响，改它只改变「玩家能看见什么」。
var vision: float = 9.0

## ---- 箭塔（以及任何 attackable = true 的建筑）----
var cooldown_left: float = 0.0

## ★★ 建造读条（config 的 `building.<type>.build_sec`；0 = 瞬发，默认）。
##   读条期间：**不开火**（还没有战斗力），但已经在图上、也照常能被打。
##   ⚠️ 它**不是**升级读条（`upgrade_*`）—— 两条互不相干：建造读条一栋楼只有一次。
var build_remaining: float = 0.0
var build_total: float = 0.0

## ---- 渲染用（不进快照、纯表现）----
var last_target = null      # 最近锁定的目标单位，画攻击线用
## ★★ 2026.10.27：塔的索敌节流（秒）。没目标时不必每帧扫全部单位 ——
##   见 `combat.update_towers()`；0 = 这一帧可以扫。
var target_scan_cd: float = 0.0
var flash: float = 0.0      # 受击闪光 1 → 0（红色覆盖，沿用）
## ★★ 受击反应（本轮新增）：被打中时置 1，按 `combat.hit_flash_sec` 衰减（视图画闪白 + 振动）。
var hit_flash: float = 0.0


static func create(cfg: ConfigRes, p_type: String, p_tx: int, p_ty: int, p_owner: String, p_zone_id: int = -1) -> RefCounted:
	var b = new()
	b.cfg = cfg
	b.type = p_type
	b.tx = p_tx
	b.ty = p_ty
	b.owner = p_owner
	b.zone_id = p_zone_id
	b.hp_max = b.max_hp_from_config(cfg)
	b.base_hp_max = b.hp_max
	b.hp = b.hp_max
	# ★ 视野半径同样在生出来那一刻定下来（战争迷雾只读它，见上面 `vision` 的说明）。
	#   区划中心（中立障碍）不走这条路：它不给任何阵营视野，值多少都无所谓。
	b.vision = cfg.building_vision_of(p_type)
	return b


## 该类型的基础血量（来自 config.json 的 `building.<type>.hp_max`）。
## ★ 本轮起是**通用**的：设计师新加的建筑也能有自己的血量（从前是按类型写死的 if/match）。
func max_hp_from_config(cfg: ConfigRes) -> float:
	if type == TYPE_ZONE_CENTER:
		return 0.0          # ★ 无血量（无敌，见 take_damage）
	return cfg.building_max_hp(type)


## 这个建筑是不是「无敌」的（区划中心）。
## 无敌的建筑不吃伤害、不可拆除，也不该被索敌——`take_damage` 与
## `command_processor.apply_demolish` 都读它，别在两处各写一个类型判断。
func is_invulnerable() -> bool:
	return bool(def().get("invulnerable", false))


## 是不是大本营（重生队列 / 升级阻塞都只针对它）。
func is_base() -> bool:
	return type == TYPE_BASE


func is_neutralized() -> bool:
	return neutralized


func def() -> Dictionary:
	var fallback: Dictionary = DEFS.get(type, FALLBACK_DEF)
	if cfg == null:
		return fallback
	# ★ config 优先（见 DEFS 上面那段说明）：名字 / 阻挡语义 / 能不能建造…都在数据里
	return cfg.building_def(type, fallback)


func display_name() -> String:
	return String(def().get("name", type))


## ---- 攻击（大本营 / 城墙这类 attackable = false 的建筑没有攻击手段）----
##
## ★★ 本轮起是**通用**的：原来写死 `type == TYPE_TOWER`，于是「编辑器里新加一栋炮塔」
##    永远打不出伤害。现在判据是 config 的 `attackable`，数值按**当前等级**取
##    （`upgrade.levels.<type>[k].damage` 写了就用它，没写用基础值）。
## ⚠️ 老名字 `tower_*` 保留：HUD 与测试都在用（语义 = 「这一栋的攻击数值」）。

## 这一栋现在能不能攻击（不能攻击的类型不会进 update_towers）
func is_attackable(cfg: ConfigRes) -> bool:
	if cfg == null:
		return type == TYPE_TOWER       # 没有 cfg 的极端情况：保持旧行为
	return cfg.building_attackable(type)


func attack_damage(cfg: ConfigRes) -> float:
	if not is_attackable(cfg):
		return 0.0
	return float(cfg.building_attack_of(type, level)["damage"])


func attack_range(cfg: ConfigRes) -> float:
	if not is_attackable(cfg):
		return 0.0
	return float(cfg.building_attack_of(type, level)["range"])


func attack_cooldown(cfg: ConfigRes) -> float:
	if not is_attackable(cfg):
		return 0.0
	return float(cfg.building_attack_of(type, level)["cooldown"])


func tower_damage(cfg: ConfigRes) -> float:
	return attack_damage(cfg)


func tower_range(cfg: ConfigRes) -> float:
	return attack_range(cfg)


func tower_cooldown(cfg: ConfigRes) -> float:
	return attack_cooldown(cfg)


## ---- 建造读条（config 的 build_sec；0 = 瞬发，默认）----

## 开始建造读条（world.add_building 里调；sec <= 0 就什么都不做 = 瞬发）
func start_construction(sec: float) -> void:
	if sec <= 0.0:
		return
	build_total = sec
	build_remaining = sec


## 这一栋现在是不是**还在建造**（读条中不能开火）
func is_under_construction() -> bool:
	return build_total > 0.0


## 建造进度（0~1；不是建造中 → 1.0 = 已经好了）
func build_progress() -> float:
	if build_total <= 0.0:
		return 1.0
	return clampf(1.0 - build_remaining / build_total, 0.0, 1.0)


## 建造还要多久（秒）
func build_eta() -> float:
	return maxf(0.0, build_remaining)


## 读条走完（world 的建造 tick 里调）：立刻可战斗
func finish_construction() -> void:
	build_remaining = 0.0
	build_total = 0.0


## 该建筑**整格**是否阻挡某个阵营的单位（只给 A* 用）。
##
## ★★ 判定基准是 `same_side_for_attack(faction, owner)`（「是不是自己人**或盟友**」），
##    **不是** `faction == 'player'`，也**不再是**严格的 `same_side`。
##    · 同阵营：城墙 `blocks_player=false` ⇒ 放行（与从前一致）；
##    · 盟友：现在也走 `blocks_player` ⇒ 放行（「同边的单位可以跨越同边的建筑」）；
##    · 其它（敌对 / 中立）：走 `blocks_enemy` ⇒ 挡死。
##    ⚠️ 旧写法用 `same_side`（严格 a==b）时盟友互相阻挡；本轮按需求改成盟友也放行。
##
## ⚠️ 大本营 / 箭塔在这里**对谁都返回 false**：它们本体小于一格，整格不封，
##    真正的阻挡交给 body_blocks() + 移动碰撞（见文件头）。
func blocks(faction: String) -> bool:
	if FactionRes.same_side_for_attack(faction, owner):
		return bool(def().get("blocks_player", true))
	return bool(def().get("blocks_enemy", true))


## 该建筑的**本体**是否阻挡某个阵营（只给移动碰撞用）。
## 城墙 body_scale = 1.0，所以它这里与 blocks() 等价；大本营 / 箭塔只挡敌方。
## ★ 判据与 `blocks()` 逐字一致：`same_side_for_attack`（同阵营**或盟友**放行）。
func body_blocks(faction: String) -> bool:
	if FactionRes.same_side_for_attack(faction, owner):
		return bool(def().get("body_blocks_player", false))
	return bool(def().get("body_blocks_enemy", true))


## 本体边长占一格的比例（config.json；缺省按整格算，宁可挡死也不要漏）
## ★ 走 config 上按类型的缓存 —— 这个函数在索敌里会被「每单位每建筑」调用。
func body_scale(cfg: ConfigRes) -> float:
	return cfg.building_body_scale(type)


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
## ★ 是否能被打死由 `building.<type>.destructible` 决定（默认 true）。
##   大本营现在也是 true：被打到 0 就会倒下，随后该阵营整体中立化（见 world）。
##
## ★ 区划中心**无敌**（`invulnerable`）：直接返回 false，一点血都不掉、也不闪红。
##
## @return bool **本击是否造成了摧毁**（false = 没打死 / 早就死了 / 无敌）。
##
## ⚠️ 返回值语义是「刚才这一下打死了它」，**不是**「它现在还活着」。
##    HTML 版用的是后者，于是同一帧里第二个攻击者打一栋已经 0 血的墙，
##    也会再广播一次 building_down —— 三个将领围着一堵墙就是三条重复事件。
##    调用方只该在**首次**摧毁时广播（见 combat.attack_building）。
##
## ★★ 2026.10.26：建筑对**远程伤害**免伤 90%（`building.<type>.ranged_reduction`）。
##   · `incoming_ranged` 只由**投掷物**命中建筑时传 true（近战传 false / 不传）；
##   · `ignore_reduction` 是「攻城标签」（投石车）：攻城伤害不走远程减免；
##   · 故意**不用** `combat.damage_reduction_cap`（那是单位的 75% 封顶），否则 90% 会被压成 75%。
func take_damage(cfg: ConfigRes, amount: float, _source = null,
		incoming_ranged: bool = false, ignore_reduction: bool = false) -> bool:
	if not alive:
		return false                       # 早就死了，不重复报销
	if is_invulnerable():
		return false                       # ★ 区划中心：无血量、无敌，连闪光都不给
	flash = 1.0
	hit_flash = 1.0          # ★ 受击反应：闪白 + 左右振动（视图读它）
	var destructible: bool = cfg.building_destructible(type)
	var floor_hp: float = 1.0 if not destructible else 0.0
	if incoming_ranged and not ignore_reduction:
		amount *= 1.0 - clampf(cfg.building_ranged_reduction(type), 0.0, 0.99)
	hp = maxf(floor_hp, hp - amount)
	if hp <= 0.0:
		# 就地标记；真正的摘除由 world.tick() 末尾统一做（逻辑层不在遍历中改集合）
		alive = false
		return true
	return false


## 是否处于「还在场、可被选/可被打」的状态
func is_selectable() -> bool:
	return alive


# ------------------------------------------------------------------
# 血量上限：等级倍率 × 科技倍率（见 logic/upgrade.gd 与 world._apply_tech_effects）
#
# ★★ 上限只有一个算法：`base_hp_max × level_hp_mult × tech_hp_mult`。
#   两个倍率各自「粘性」（记住上次施加的值，没变就什么都不做），
#   最终都落到 `refresh_hp_max()` —— 于是「升级」与「科技启用 / 弃用」
#   不会互相覆盖，也不会因为调用顺序不同得出不同的数。
# ------------------------------------------------------------------

## 某个等级对应的血量倍率（由 `logic/upgrade.gd` 的配置表给；没配 → 1.0）
func level_mult_from(cfg: ConfigRes) -> float:
	if not cfg.has_upgrade(type):
		return 1.0
	return cfg.upgrade_hp_mult(type, level)


## 施加「建筑血量 +10%」这类**科技**倍率（**粘性**：倍率没变就什么都不做）。
##
## 玩家确认的口径：加成作为**倍率实时生效** —— 已经建好的城墙也一起提升，
## 弃用之后回到 1.0。
## ⚠️ 区划中心血量是 0（无敌建筑）：`base_hp_max = 0` 时只改倍率、不动血量，
##   否则会算出 0 * ratio = 0 这种没意义的「血量」。
func apply_hp_bonus(mult: float) -> void:
	var m: float = maxf(0.01, mult)
	if absf(m - tech_hp_mult) < 1e-9:
		return
	tech_hp_mult = m
	refresh_hp_max()


## 按等级重算上限（升级读完时由 world 调；倍率没变时是空操作）
func apply_level_mult(mult: float) -> void:
	var m: float = maxf(0.01, mult)
	if absf(m - level_hp_mult) < 1e-9:
		return
	level_hp_mult = m
	refresh_hp_max()


## ★★ 唯一的「上限怎么算」：基础值 × 等级 × 科技，当前血量**按比例**带过去。
##
## 为什么是「从基础值重算 + 按比例缩放当前血量」而不是「当前上限 / 当前血量直接乘」：
##   · 反复乘会累积误差，弃用 / 降级时回不到原值；
##   · 一块被打掉一半的城墙在 +10% 或升一级之后，应当**仍然是剩一半**。
func refresh_hp_max() -> void:
	if base_hp_max <= 0.0:
		return                          # 区划中心：没有血量这回事
	var ratio: float = 1.0
	if hp_max > 0.0:
		ratio = clampf(hp / hp_max, 0.0, 1.0)
	hp_max = base_hp_max * level_hp_mult * tech_hp_mult
	hp = hp_max * ratio


## 这栋建筑现在有没有升级读条在跑（见 logic/upgrade.gd）
func is_upgrading() -> bool:
	return upgrade_total > 0.0


## 升级读条进度（0~1；没在读条 → 0）—— 视图只读它，不自己算
func upgrade_progress() -> float:
	if not is_upgrading():
		return 0.0
	return clampf(1.0 - upgrade_remaining / upgrade_total, 0.0, 1.0)


## 升级还要多久（秒）
func upgrade_eta() -> float:
	return maxf(0.0, upgrade_remaining)


# ------------------------------------------------------------------
# ★★ 将领重生队列（大本营专用；规则见 logic/world.gd 的 _tick_base_respawns）
# ------------------------------------------------------------------

## 大本营现在有没有重生任务（正在倒计时，或还有排队的）。
## ★ 客机侧由快照写入 `respawn_remote_count`，所以这个判据同时覆盖两边。
func is_respawning() -> bool:
	return respawn_active or not respawn_queue.is_empty() or respawn_remote_count > 0


## 队列里一共有几位（含正在倒计时的那位）。
func respawn_count() -> int:
	if respawn_queue.is_empty() and respawn_remote_count > 0:
		return respawn_remote_count
	return respawn_queue.size()


## 正在倒计时的那位（没有 → null；客机侧没有对象，返回 null）。
func respawn_current():
	if respawn_queue.is_empty():
		return null
	var e: Variant = respawn_queue[0]
	if typeof(e) != TYPE_DICTIONARY:
		return null
	return (e as Dictionary).get("unit", null)


## 当前正在重生的是谁（显示名；客机侧退回快照里的名字）。
func respawn_current_name() -> String:
	var u = respawn_current()
	if u != null:
		return String(u.name)
	return respawn_remote_name


## 当前这一位的读条进度（0~1；没有在倒计时 → 0）。
func respawn_progress() -> float:
	if respawn_queue.is_empty():
		if respawn_remote_total <= 0.0:
			return 0.0
		return clampf(1.0 - respawn_remote_remaining / respawn_remote_total, 0.0, 1.0)
	if not respawn_active or respawn_total <= 0.0:
		return 0.0
	return clampf(1.0 - respawn_remaining / respawn_total, 0.0, 1.0)


## 当前这一位还要多久（秒）。
func respawn_eta() -> float:
	if respawn_queue.is_empty():
		return maxf(0.0, respawn_remote_remaining)
	return maxf(0.0, respawn_remaining)


## 入队一位阵亡将领（`secs` = 它自己的重生时长）。
func enqueue_respawn(unit, secs: float) -> void:
	if unit == null:
		return
	respawn_queue.append({"unit": unit, "secs": maxf(0.0, secs)})
	if not respawn_active:
		_start_next_respawn()


## 把队首提到「正在倒计时」（队列空 → 回到空闲）。
func _start_next_respawn() -> void:
	if respawn_queue.is_empty():
		respawn_active = false
		respawn_remaining = 0.0
		respawn_total = 0.0
		return
	var e: Variant = respawn_queue[0]
	respawn_active = true
	var secs := 0.0
	if typeof(e) == TYPE_DICTIONARY:
		secs = float((e as Dictionary).get("secs", 0.0))
	respawn_total = maxf(0.0, secs)
	respawn_remaining = respawn_total


## 推进当前这一位的倒计时。
## @return 本帧完成重生的单位对象数组（调用方负责把它们放回 world.units）。
## ★ 与招募读条同一套「一帧可能读完好几单」的预算算法（guard 防病态数据）。
func tick_respawn_queue(dt: float) -> Array:
	var done: Array = []
	if not respawn_active:
		_start_next_respawn()
	var budget: float = maxf(0.0, dt)
	var guard := 0
	while respawn_active and guard < 16:
		guard += 1
		if respawn_remaining > budget:
			respawn_remaining -= budget
			break
		budget -= respawn_remaining
		respawn_remaining = 0.0
		var e: Variant = respawn_queue.pop_front()
		if typeof(e) == TYPE_DICTIONARY:
			var u: Variant = (e as Dictionary).get("unit", null)
			if u != null:
				done.append(u)
		_start_next_respawn()
		if budget <= 0.0:
			break
	return done


## 清空队列（大本营被摧毁 / 中立化 / 被强制移除时用）。
## ★ 队列里是死将对象，清掉之后没有别的引用 → 它们就是**永久阵亡**。
func clear_respawn_queue() -> void:
	respawn_queue.clear()
	respawn_active = false
	respawn_remaining = 0.0
	respawn_total = 0.0
	respawn_remote_count = 0
	respawn_remote_remaining = 0.0
	respawn_remote_total = 0.0
	respawn_remote_name = ""


## 客机应用快照：只写展示字段（本机权威侧不走这里）。
func apply_respawn_snapshot(count: int, remaining: float, total: float, who: String) -> void:
	respawn_remote_count = maxi(0, count)
	respawn_remote_remaining = maxf(0.0, remaining)
	respawn_remote_total = maxf(0.0, total)
	respawn_remote_name = who
