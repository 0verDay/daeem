## unit.gd —— 单位（3 个将领占位单位 + 调试用测试敌人）
##              （对应 HTML 版 js/unit.js 的「状态 + 移动」那一半）
##
## 移动：**点到哪走到哪，能走直线就走直线**。
##   - A* 只负责给出「绕开山 / 城墙该走哪几个格子」的路线；
##   - 随后用 pathfinder.smooth_path() 把这条路线「拉直」：只要两点之间直线全程可通行
##     就直接走直线，不再沿格心走阶梯（这就是以前「能走直线却走曲线」的原因：
##     中间路径点全都在格心上）；
##   - 终点仍然是玩家点击的那个**精确位置**，不吸附地块中心；
##   - 点到的格子不可通行（山 / 城墙 / 建筑）时，自动改走到最近的可达格；
##   - 站在森林里会减速（unit.forest_mult）。
##   单位不要求与地块一一对应 —— 多个单位可以叠在同一格（**有意的**，见 route.md 第六节）。
##
## 战斗 / 警戒 / 拆建筑在 combat.gd（HTML 版把这两半挤在一个文件里，这里拆开）。
##
## ⚠️ 位置一律是**格**（连续浮点），不是像素。像素只在 view/ 出现。
extends RefCounted

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const CollisionRes = preload("res://logic/collision.gd")
const FactionRes = preload("res://logic/faction.gd")

const KIND_GENERAL := "general"
const KIND_ENEMY := "enemy"
## 亲兵：将领辖下的附属单位（出生在将领旁边，选中将领时一起被选中）
const KIND_SUBORDINATE := "subordinate"

## 路径推进一步的最大段数（防止病态路径把一帧卡死）。
##
## ★ 它**不是地图上限**，而是「一帧最多跨几个路径点」的护栏。原来的值是写死的 512 ——
##   地图一大（比如 1000×1000 的编辑器地图）就会出现「这一帧本该走到终点，却因为数到 512
##   就停了」：症状不是报错，而是大图上的单位走得比小图上慢，一帧一帧地爬。
##   现在按地图尺寸算（见 step_guard）：护栏跟着地图一起长大，
##   小地图上仍然是 512 那个量级，大图上不会限制正常行军。
const STEP_GUARD_MIN := 512
##: 护栏 = 地图对角线 × 这个系数（一条直线路径的拐点数不会超过它的格数）
const STEP_GUARD_FACTOR := 4

## 距离容差（**格**）。
## ★ 逻辑层一切距离都是「格」，所以任何「够不够近」的阈值都必须按格来写 ——
##   代码里出现 0.5 这种数字时，先问一句：这是像素还是格？
##   （把像素阈值误用到格上，就是「点得越准越不动」那个 bug 的根因。）
const EPS := 0.001

## 到达判定的额外容差（格）。距离 ≤ 本帧剩余预算 + 它 才算「到了」。
## 1e-4 格 = 0.0064px，只是用来吸收浮点误差，不构成「提前停下」。
const ARRIVE_EPS := 1e-4

var id: String = ""
var name: String = ""
var kind: String = KIND_GENERAL
var faction: String = FactionRes.DEFAULT_FACTION
var hotkey: String = ""

## ★ 所属队长（将领）的 id。空 = 自己就是队长（将领）或不属于任何队伍（测试敌人）。
##
## 这就是「队伍」的全部数据结构：**不引入新的 Squad 类**，
## 队伍 = { leader_id == 空的那个单位 } ∪ { leader_id == leader.id 的那些 }。
## 为什么不单独建一个队伍对象：那样一来「单位死了要通知队伍」「队伍要跟着换队长」
## 全都要额外维护，而这些都是可以推出来的。现在由 `world.group_of(id)` 现算，
## 单位总数只有几十个，代价可以忽略。
var leader_id: String = ""

## 连续位置（格）
var pos: Vector2 = Vector2.ZERO
## 所在地块缓存：只用于占区块 / 资源 / 箭塔 / 警戒判定
var tx: int = 0
var ty: int = 0

var hp: float = 200.0
var hp_max: float = 200.0
var alive: bool = true

## 朝向：**单位向量**（不是 ±1）。
## ★ 八方向之后必须改成向量 —— 原来那个 `int ±1` 只能表示左右，
##   斜着走、斜着开火时朝向就画不出来了（渲染只画一条水平线，看着像没转）。
var facing: Vector2 = Vector2.RIGHT
## 最近一次「明确」的移动/攻击方向。停下之后 facing 用它保留朝向，
## 免得单位停下来时朝向被归一化成一堆零。
var last_dir: Vector2 = Vector2.RIGHT

## 剩余路径（**格**坐标点的数组，最后一个点就是玩家点击的位置）
var path: Array[Vector2] = []
var has_goal: bool = false
var goal: Vector2 = Vector2.ZERO
var moving: bool = false

## settling：本次移动的目标点被别人占着，所以是「就近停下」而不是走到精确落点。
##
## 用途只有一个 —— 决定**推力权重**：settling 的单位仍然算「有命令」，
## 于是别人推它时它会同等对抗。否则它会一直被判成待命（轻的一侧），
## 被人群无限推着走，人群永远静不下来。
var settling: bool = false

## jam_timer：想走到终点、但每帧都被挤回来（进度被抵消）的累计时间。
##
## ★ 它解决的是「推挤能把单位推走的距离（一帧最多 ~0.25 格）远大于它自己的
##   移动速度（0.04 格/帧）」这个数量级失衡：人群里的单位可能**永远走不到终点**，
##   于是一直保持 moving=true 被推来推去 —— 实测三个将领 2000 帧停不下来、
##   总行程 83 格（本该 8 格）、方向反转 5708 次，肉眼看就是「挤着转」。
##   超时之后就认账：在附近找个空位落位、结束移动。
var jam_timer: float = 0.0

## 站定之后的落点，以及「被推离它多远就该回去」。
##
## ★ 这是「到达后互相挤着转」的最后一块：到达之后 `path` 是空的，
##   所以 `step_along_path` 整个函数**都不会被执行**（调用处判的是 `path.is_empty()`），
##   于是被推走的单位没有任何机制走回去 —— 实测将领就这样被推着漂了 2000 帧、
##   总行程 83 格（本该 8 格）。所以到达时要记住落点，
##   每帧 reclaim_settled_spot() 发现被推远了就自己回去。
var settled_goal: Vector2 = Vector2.ZERO
var has_settled_goal: bool = false
## 已经回位过几次（防死循环：反复被推走就别再回了，就地待着）
var settle_attempts: int = 0

## 进度停滞检测：本次移动中「离终点最近到过多少」，以及「连续多久没更接近」。
## 用途见 step_along_path 的到达判定 —— 人群里最后一段可能**永远走不完**，
## 只有靠「一直没有进度」才能判断出「挤不过去，该认账了」。
var best_dist: float = INF
var stuck_timer: float = 0.0

## ---- 战斗 / 警戒 ----
var target = null             # 当前交战的敌方单位
var target_building = null    # 当前正在拆的建筑（敌人拆城墙走这条路）
var anchor: Variant = null    # 发现目标时所站的位置，用于「追出去多远」的判定
var attack_cd: float = 0.0
var attack_flash: float = 0.0
var last_target = null        # 最近一次开火的目标单位（渲染攻击线用）
var last_building = null      # 最近一次攻击的建筑（渲染攻击线用）
var repath_timer: float = 0.0

## ---- 玩家下达的攻击命令（右键点敌人 / 右键点建筑 / 双击行军攻击）----
##
## ★ 与 `target` / `target_building` 的分工：
##   · `target` / `target_building` 是**这一帧在打谁**（自动警戒与玩家命令都写它）；
##   · 下面这两个是**玩家明确指定的那个目标**，用于两条特例：
##       1. 覆盖自动警戒（警戒不会把玩家的命令顶掉）；
##       2. **不受追击上限约束** —— 那是「它自己追出去多远」的限制，
##          而玩家点名要打的目标，就该一路追（与 SC2 右键点敌人一致）。
##   · 目标死了 / 被摧毁 → 自动清空（见 combat.gd）。
var ordered_target = null
var ordered_building = null
## 行军攻击（SC2 的 A 键）：先走到 attack_move_goal，路上遇到敌人就停下来打，
## 打完了**继续走**（见 combat.gd 的 update_unit 末尾）。
var has_attack_move: bool = false
var attack_move_goal: Vector2 = Vector2.ZERO

## ---- 阵亡与复活（config.pvp；单机开关永远关着）----
var death_timer: float = 0.0  # > 0 表示已阵亡且正在等复活
var deaths: int = 0

## ★ 驻守（地图预置单位用的开关）：true = **不执行推进 AI**，原地待着。
## 迎战不受影响 —— 有人靠近照样会打（警戒与战斗是另一条路，见 combat.gd）。
## 用处：地图上摆几个「测试用守军」时，不希望它们开局就朝玩家据点行军。
var hold_position: bool = false

## ---- 纯表现的本地标志 ----
## selected：由 view/input_controller 写、view/overlay 与 unit_view 读。
## ★ 它不是权威状态：不进快照、不进命令流（第 1 轮联机时也一样）。
##   挂在逻辑对象上只是因为「选中」天然属于某个单位，省一层映射表。
var selected: bool = false


static func create(cfg: ConfigRes, p_id: String, p_name: String, tile: Vector2i, p_faction: String, p_kind: String = KIND_GENERAL, p_hotkey: String = "", p_leader_id: String = "") -> RefCounted:
	var u = new()
	u.id = p_id
	u.name = p_name
	u.kind = p_kind
	u.faction = p_faction
	u.hotkey = p_hotkey
	u.leader_id = p_leader_id
	u.pos = GridRes.center_of(tile)
	u.tx = tile.x
	u.ty = tile.y
	# ★ 数值走 cfg.unit_*_of(kind)：原来写的是「是将领吗？不是就当敌人」，
	#    加了第三种兵种之后那个二元判断会**静默把亲兵当成测试敌人**（60 血）。
	u.hp_max = cfg.unit_hp_of(p_kind)
	u.hp = u.hp_max
	return u


## 是否正在等待复活（单机永远 false —— 死亡即离场）
func awaiting_respawn() -> bool:
	return (not alive) and death_timer > 0.0


## 基础移动速度（格 / 秒）；森林里减半
func speed(cfg: ConfigRes, map) -> float:
	var base: float = cfg.unit_speed_of(kind)
	var on_forest: bool = map != null and map.is_forest(tx, ty)
	return base * (cfg.unit_forest_mult if on_forest else 1.0)


## 该单位的战斗数值（将领 / 亲兵 / 敌人各自配置，见 cfg.unit_combat_of）
func combat_damage(cfg: ConfigRes) -> float:
	return float(cfg.unit_combat_of(kind)["damage"])


func combat_range(cfg: ConfigRes) -> float:
	return float(cfg.unit_combat_of(kind)["range"])


func combat_cooldown(cfg: ConfigRes) -> float:
	return float(cfg.unit_combat_of(kind)["cooldown_sec"])


## 警戒半径（格）
func aggro_range(cfg: ConfigRes) -> float:
	return cfg.aggro_range


## 追击上限（格）：目标离「警戒起点」超过这个距离就放弃
func leash_range(cfg: ConfigRes) -> float:
	return cfg.aggro_range * cfg.leash_factor


# ------------------------------------------------------------------
# 移动
# ------------------------------------------------------------------

## 底层移动：把单位送到某个**格坐标点**（点到哪走到哪 + 能走直线就走直线）。
## 不会动交战目标 —— 追击用它；玩家的明确命令走 order_move()。
##
## ★ 返回 true 只代表「命令下达成功」，**不代表已经到位**。
##   ⚠️ 原地不动时它也返回 true（HTML 版就是因为只看返回值判断「到位了没」，
##      导致敌人站在墙边发呆，永远不拆墙 —— 见 docs/pitfalls.md 3.2）。
##      判断「到位了没」请读 moving / path。
func move_to(world, cfg: ConfigRes, world_pt: Vector2) -> bool:
	var map = world.map
	var from := Vector2i(tx, ty)

	var dest_pt := world_pt
	var dest_tile := Vector2i(
		clampi(floori(world_pt.x), 0, map.terrain.cols - 1),
		clampi(floori(world_pt.y), 0, map.terrain.rows - 1)
	)

	# 点到不可通行的格子（山 / 城墙 / 建筑）→ 自动改走到**离点击最近**的可行走点。
	#
	# ★ 这里刻意分两步走，别把顺序搞反：
	#   1. 先问「点击那一格里，离我点的地方最近的可行走点在哪」——
	#      多半就是点击位置本身投影到边界上（点建筑靠哪侧就贴到哪侧）；
	#   2. 那一格整格都进不去（山 / 越界 / 落在墙另一侧）时，才退回
	#      「从目标往外扩圈找最近的、且我真的走得到的格子」。
	if not PathfinderRes.passable(map, world.buildings, cfg, dest_tile.x, dest_tile.y, faction):
		var near = PathfinderRes.nearest_reachable_point(map, world.buildings, cfg, from, dest_tile, world_pt, faction)
		if near != null:
			# ⚠️ 连落点所在的格一起换掉：贴边落点常常就在（不可通行的）目标格边缘上，
			#    而 A* 的终点必须是可通行格 —— 只换点不换格，find_path 会直接返回 null
			#    （那样连点山都点不动了，实测踩过）。
			dest_pt = near["pt"]
			dest_tile = near["tile"]
		else:
			var alt = PathfinderRes.nearest_reachable(map, world.buildings, cfg, from, dest_tile, faction, 20)
			if alt == null:
				alt = PathfinderRes.nearest_reachable(map, world.buildings, cfg, from, dest_tile, faction, 60)
			if alt == null:
				return false
			dest_tile = alt
			dest_pt = GridRes.center_of(alt)

	var tile_path = PathfinderRes.find_path(map, world.buildings, cfg, from, dest_tile, faction)
	if tile_path == null:
		return false

	# 地块路线 → 折线：中间点走格心，**最后一点就是点击（或贴边）的精确位置**
	var raw: Array[Vector2] = [pos]
	for n in tile_path:
		raw.append(GridRes.center_of(n))
	if tile_path.size() > 0:
		raw[raw.size() - 1] = dest_pt
	elif pos.distance_to(dest_pt) > EPS:
		# ★ 起点与终点在同一格时 A* 返回空路线，但**点击位置本身仍然要走到**。
		#
		# ⚠️ 这里原来写的是 `> 0.5`，而 0.5 是**像素**口径的阈值 ——
		#    在「格」为单位的坐标系里它就是**半格**。后果是：
		#    「鼠标点得越准，单位越不动」：点 0.05 / 0.2 / 0.45 格外都一动不动，
		#    而且 move_to 还返回 true，界面以为命令成功了。
		#    这正是 docs/pitfalls.md 3.2 那个「原地不动也返回 true」的同款陷阱。
		#    格宽 64px 时 0.001 格 = 0.064px，用 EPS 兜底既不影响手感，又不会漏掉微调。
		raw.append(dest_pt)

	# ★ 第一步：把折线拉直。开阔地带只剩一条直线，遇到山 / 城墙才保留拐点。
	var pts := PathfinderRes.smooth_path(map, world.buildings, cfg, raw, faction)
	# ★ 第二步：把拉直后剩下的硬拐角圆化。
	#   拉直只减少路径点，单位却是「走到路点才允许转向」，所以拐弯原本发生在**一帧之内**
	#   （实测直角弯单帧转角 63°）。圆化把转向摊到十几帧里。
	#   安全性：圆角曲线落在折线的凸包内，且结果里每一段都过 segment_clear 兜底。
	pts = PathfinderRes.round_corners(map, world.buildings, cfg, pts, faction)
	# 丢掉第一个点（那是当前位置，不需要走）
	var trimmed: Array[Vector2] = []
	for i in range(1, pts.size()):
		trimmed.append(pts[i])

	path = trimmed
	if trimmed.is_empty():
		# 已经在目标位置上：清空路径与目标，并保证 has_goal = false
		has_goal = false
		moving = false
		goal = Vector2.ZERO
		return true

	# 期望落点：目标被占时会换成一个空位（见 step_along_path 的到达处理）
	var settled_here := false
	if _arrival_congested(world, cfg, dest_pt):
		var alt_slot = _find_arrival_slot(world, cfg, dest_pt, faction, from)
		if alt_slot != null:
			dest_pt = alt_slot
			settled_here = true

	goal = dest_pt
	has_goal = true
	moving = true
	# settling：这一方是「因为拥挤才就近停」——它仍然算有命令，被推时会同等对抗
	settling = settled_here
	jam_timer = 0.0
	# 进度检测复位：新的目标 = 新的「最近距离」
	best_dist = INF
	stuck_timer = 0.0
	# ⚠️ 这里**不要**清 settled_spot / settle_attempts：
	#    `reclaim_settled_spot()` 也是走 move_to 来回到落点的，
	#    如果 move_to 里把它清掉，回位动作就会**自己把计数器清零**，
	#    于是「最多回位 3 次」永远不生效 —— 实测直接就退化成 12 个单位永远 moving=true。
	#    真正的「新命令」由 order_move() 负责清零。
	return true


## 玩家 / AI 下达移动命令（点到哪走到哪）。
## 会清除当前交战目标：明确的移动命令优先于警戒。
func order_move(world, cfg: ConfigRes, world_pt: Vector2) -> bool:
	var ok := move_to(world, cfg, world_pt)
	if ok:
		clear_target()
		# 真正的「新命令」：旧落点与回位计数一起作废。
		# ⚠️ 清零放在这里而不是 move_to —— 否则回位动作会把自己的计数器清零（见 move_to 的注释）。
		clear_settled_spot()
	return ok


# ------------------------------------------------------------------
# 玩家下达的攻击命令（右键点敌人 / 右键点建筑 / 双击行军攻击）
# ------------------------------------------------------------------

## 优先攻击某个敌对单位（右键单击敌人）。
## @return 命令是否被接受（不是自己人、还活着）
func order_attack_unit(world, cfg: ConfigRes, enemy) -> bool:
	if enemy == null or not enemy.alive:
		return false
	if FactionRes.same_side(enemy.faction, faction):
		return false
	drop_engagement()
	target = enemy
	ordered_target = enemy
	ordered_building = null
	has_attack_move = false
	clear_settled_spot()
	return true


## 优先攻击某个敌对建筑（右键单击建筑）。
func order_attack_building(world, cfg: ConfigRes, b) -> bool:
	if b == null or not b.alive:
		return false
	if FactionRes.same_side(b.owner, faction):
		return false
	drop_engagement()
	target_building = b
	ordered_building = b
	ordered_target = null
	has_attack_move = false
	clear_settled_spot()
	return true


## 行军攻击（SC2 的 A 键）：走到 world_pt，路上遇到敌人就停下来打，打完了继续走。
## 与「普通移动」的区别就在「路上会打」—— 普通移动是明确命令，遇敌不停。
func order_attack_move(world, cfg: ConfigRes, world_pt: Vector2) -> bool:
	var ok := move_to(world, cfg, world_pt)
	if not ok:
		return false
	drop_engagement()          # 先脱离当前交战：新命令优先
	ordered_target = null
	ordered_building = null
	has_attack_move = true
	attack_move_goal = world_pt
	clear_settled_spot()
	return true


# ------------------------------------------------------------------
# 到达落点（拥挤时就近找空位）
# ------------------------------------------------------------------

## 单位之间的最小圆心距离（与 collision.gd 用同一套口径）
func min_unit_distance(cfg: ConfigRes) -> float:
	return maxf(0.0, cfg.num("unit.collision_radius", 0.18)) * 2.0 \
		* clampf(cfg.num("unit.overlap_allowance", 0.7), 0.0, 1.0)


## 这个落点是否会被别人占着（窄口径：只看那些**已经到达落点附近并停下来**的单位）。
##
## 为什么不看「正在移动的单位」：那群人正在一起赶路，彼此离得远，看他们没意义。
## 真正要避开的只有「已经站定在那儿的人」。
func _arrival_congested(world, cfg: ConfigRes, p: Vector2) -> bool:
	var need: float = min_unit_distance(cfg)
	if need <= 0.0:
		return false
	for other in world.units:
		if other == self or not other.alive:
			continue
		if other.moving:
			continue                     # 还在赶路的：不算占位
		if other.pos.distance_to(p) < need:
			return true
	return false


## 目标点被别人占着时，在附近找一个「可通行 + 没别人 + 走得到」的空位。
##
## 搜索顺序：先沿「目标 → 自己」这条线往回退（不会跑到墙另一边），
## 再绕目标一圈。找不到就返回 null —— 调用方会用原目标点（或原地不动）。
##
## @param reach 本帧还剩的移动预算（格）。有它的话可以选得**离目标更近**的候选，
##        而不是死板地按搜索顺序取第一个。
func _find_arrival_slot(world, cfg: ConfigRes, want: Vector2, faction: String, from: Vector2i, reach: float = 0.0) -> Variant:
	var need: float = min_unit_distance(cfg)
	if need <= 0.0:
		return null
	var step: float = maxf(0.05, need * 0.6)
	# 可达区域只算一次：空位必须「真的从起点走得到」，
	# 否则会给出墙另一侧的落点（docs/pitfalls.md 3.3 那个坑的同一类）
	var region := PathfinderRes.reachable_tiles(world.map, world.buildings, cfg, from, faction)

	# 收集候选，然后挑「离目标最近」的那个。加 horizon 是为了不把远处的空位也算进来。
	var cands: Array[Vector2] = []
	var horizon: float = maxf(step * 1.5, reach * 2.0)
	var toward_self := pos - want
	if toward_self.length() > 1e-6:
		var back := toward_self.normalized()
		for k in range(1, 7):
			var p := want + back * step * float(k)
			if p.distance_to(want) > horizon:
				break
			if _slot_ok(world, cfg, p, faction, region, need):
				cands.append(p)
	for ring in range(1, 5):
		for i in 12:
			var ang := TAU * float(i) / 12.0
			var p2 := want + Vector2(cos(ang), sin(ang)) * step * float(ring)
			if p2.distance_to(want) > horizon:
				continue
			if _slot_ok(world, cfg, p2, faction, region, need):
				cands.append(p2)
	if cands.is_empty():
		return null
	var best: Vector2 = cands[0]
	for c in cands:
		if c.distance_to(want) < best.distance_to(want) - 1e-9:
			best = c
	return best


func _slot_ok(world, cfg: ConfigRes, p: Vector2, faction: String, region: Dictionary, need: float) -> bool:
	var t := Vector2i(floori(p.x), floori(p.y))
	if not world.map.terrain.has(t.x, t.y):
		return false
	if not PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, faction):
		return false
	# ★ 本体级：格级放行了不代表站得住（大本营 / 箭塔的本体挡敌方）
	if CollisionRes.body_blocked_at(world, cfg, faction, p, CollisionRes.radius(cfg)):
		return false
	if not region.has(world.map.terrain.idx(t.x, t.y)):
		return false
	for other in world.units:
		if other == self or not other.alive:
			continue
		if other.pos.distance_to(p) < need:
			return false
	return true


## 就地停下（**保留**交战目标）：进入攻击距离后站住开火
func halt() -> void:
	path = []
	has_goal = false
	moving = false
	settling = false
	goal = Vector2.ZERO


## 完全停止：停下并脱离交战
func stop() -> void:
	halt()
	clear_target()
	clear_settled_spot()


## 脱离当前交战目标（单位与建筑都清掉）
func clear_target() -> void:
	drop_engagement()
	# 玩家的攻击命令（点名目标 / 行军攻击）也一起作废：
	# 「停止」「移动」这类明确命令本来就该覆盖掉旧命令。
	ordered_target = null
	ordered_building = null
	has_attack_move = false


## 只脱离「当前在打谁」，**不动**玩家的命令
## （行军攻击要能在打完一个之后继续走，所以 combat.gd 的「目标没了」都走这里）
func drop_engagement() -> void:
	target = null
	target_building = null
	anchor = null
	repath_timer = 0.0


## 把连续位置换算成所在地块（tx/ty 只用于占区块 / 资源 / 箭塔 / 警戒判定）
func sync_tile(map) -> void:
	tx = clampi(floori(pos.x), 0, map.terrain.cols - 1)
	ty = clampi(floori(pos.y), 0, map.terrain.rows - 1)


## 一帧最多推进几段路径（见 STEP_GUARD_MIN 的注释）。
## 按地图对角线算：一条直线路径的拐点数不会超过它经过的格数，
## 所以这个护栏对正常行军永远是「走得到」，只拦住真正的病态路径。
## ⚠️ 地图尺寸现在是地图编辑器说了算（可以远大于 24×16），所以这里**不能写死**。
## ⚠️ 它也不该大到失去意义：*4 之后 1000×1000 的地图是 5600 段/帧，
##    而一帧真要跑 5600 段本身就是病态路径，护栏照旧能拦住。
func step_guard(map) -> int:
	var diagonal := sqrt(float(map.terrain.cols * map.terrain.cols
			+ map.terrain.rows * map.terrain.rows))
	return maxi(STEP_GUARD_MIN, int(diagonal * STEP_GUARD_FACTOR))


## 平滑移动：路径点是格坐标（最后一个点就是玩家点击的位置）。
## 每帧按剩余距离沿折线推进；跨过拐点时把多余距离**带到下一段**，
## 这样即使一帧跨过好几个地块，速度也是均匀的、不会抖动或卡顿。
func step_along_path(world, cfg: ConfigRes, dt: float) -> void:
	var map = world.map
	# 本帧还剩多少距离预算。循环里会被消耗掉，所以先留一份给「到达处理」用：
	# 判断「谁更接近目标」时要把这一帧的剩余预算也算进去，否则人人都在
	# 自己上一帧的位置上比远近，先到的可能反而落不到那个点。
	var remaining: float = speed(cfg, map) * dt

	# recenter 与 remaining 同步消耗：到达判定要用的是**循环之后还剩多少预算**，
	# 而不是本帧开头的预算（否则到达时又走一段，总位移会超过速度预算）。
	var recenter: float = remaining
	var guard := 0

	while remaining > 1e-9 and not path.is_empty() and guard < step_guard(map):
		guard += 1
		# 变量名刻意不叫 node：logic/ 里出现 Node 相关字样一律视作架构违规信号
		# （见 docs/architecture.md 第一条铁律），叫 waypoint 也不容易被误读成场景节点
		var waypoint: Vector2 = path[0]
		var delta := waypoint - pos
		var d := delta.length()

		if d <= 1e-6:                     # 已经在这一段终点上
			path.remove_at(0)
			sync_tile(map)
			continue

		# 朝向跟着**这一步的实际方向**走（八方向下不再只有左右）
		last_dir = delta / d
		facing = last_dir

		if remaining >= d:
			# 走完这一段还有余量 → 落到拐点，继续走下一段
			pos = waypoint
			remaining -= d
			recenter = remaining
			path.remove_at(0)
			sync_tile(map)
		else:
			# 本帧走不完这一段 → 沿方向推进，单位停在地块之间的连续位置上
			pos += delta / d * remaining
			remaining = 0.0
			recenter = 0.0
			sync_tile(map)

	# ★★ 到达判定：用**距离**，并且用**进度停滞**兜底。
	#
	# 为什么不能只看「路径空了」：路径的最后一个路点就是终点本身，
	#   而人群里这「最后一段」可能**永远走不完** ——
	#   推挤一帧能把单位推走约 0.25 格，它自己一帧只走 0.04 格，
	#   于是它一直 moving=true、path 非空，却一步也没靠近终点。
	#   实测：12 个单位点到同一点，2000 帧停不下来、总行程 87 格（本该 8 格）、
	#   方向反转 8000+ 次 —— 肉眼看就是「到达后互相挤着转」。
	# 所以判定有两条，满足任意一条就落位：
	#   1. 到终点的距离 ≤ 本帧预算（真的走到了）；
	#   2. **连续 jam_giveup_sec 秒没有更接近终点**（挤不过去，认账）。
	if not has_goal:
		return                          # 目标已被清掉（交战中 halt 等），什么都不用做
	var dist_now: float = pos.distance_to(goal)
	if dist_now < best_dist - 1e-4:
		best_dist = dist_now
		stuck_timer = 0.0
	else:
		stuck_timer += dt
	var arrived: bool = dist_now <= recenter + ARRIVE_EPS
	var gave_up: bool = stuck_timer >= cfg.num("unit.jam_giveup_sec", 0.6)
	if not arrived and not gave_up:
		return                          # 既没到、也没卡住：继续走

	var landing: Vector2 = goal
	if gave_up:
		var s = _find_arrival_slot(world, cfg, goal, faction, Vector2i(tx, ty), recenter)
		landing = s if s != null else pos      # 找不到空位就原地停
	elif _arrival_congested(world, cfg, landing):
		var s2 = _find_arrival_slot(world, cfg, landing, faction, Vector2i(tx, ty), recenter)
		if s2 != null:
			landing = s2
	settling = settling or gave_up
	# ⚠️ 这里**不要再挪单位**。
	#    到达时（dist ≤ 本帧预算）上面的循环已经把位置精确推到终点了；
	#    提前认账时（gave_up）也只是「就地停」，不该再往前走一段。
	#
	#    踩过的坑：第一版在这里又补了一段位移（想让「谁更接近终点」公平），
	#    结果最后落位那一帧走了「循环推的 0.04 + 补的 0.024 = 0.0644」，
	#    超过速度预算 0.04 —— 表现为最后一帧轻微一跳，
	#    被 test_logic 的「每帧位移不超过速度预算」断言抓住。
	#    只有「落到另一个空位」时才需要动，而且那点位移也必须算在预算里。
	if recenter > 0.0 and pos.distance_to(landing) > EPS:
		pos += (landing - pos).normalized() * minf(recenter, pos.distance_to(landing))
	sync_tile(map)
	jam_timer = 0.0
	stuck_timer = 0.0
	# 记住落点：之后被推离它太远时要自己走回去（见 reclaim_settled_spot）
	settled_goal = landing
	has_settled_goal = true
	settle_attempts = 0
	path = []
	has_goal = false
	moving = false
	goal = Vector2.ZERO


## 站定之后被推离落点太远 → 自己走回去。
##
## 为什么需要单独一个函数：到达之后 `path` 是空的，`world.tick()` 里那句
## `if not u.path.is_empty(): u.step_along_path(...)` 就**不会执行**，
## 所以被推走的单位没有任何机制走回去，只能一直被推着漂。
##
## 由 world.tick() 每帧调用（放在碰撞消解**之前**：先决定要不要回位，再让碰撞摆位置）。
##
## ⚠️ 必须防死循环：人群里回位可能永远失败（一帧被推走 0.25 格、自己只能走 0.04 格）。
##    所以回位次数用尽之后就放弃，就地待着 —— 否则会退化成「永远挤着转」，
##    那正是这条逻辑要修的病。
func reclaim_settled_spot(world, cfg: ConfigRes) -> void:
	if moving or not has_settled_goal or not alive:
		return
	var back_dist: float = maxf(0.02, cfg.num("unit.settle_return_dist", 0.22))
	if pos.distance_to(settled_goal) <= back_dist:
		return
	if settle_attempts >= int(cfg.num("unit.settle_max_attempts", 3.0)):
		return                                  # 挤不进去就算了，就地待着
	settle_attempts += 1
	move_to(world, cfg, settled_goal)


## 站定落点是否还有效（新命令 / 停下时作废）
func clear_settled_spot() -> void:
	has_settled_goal = false
	settled_goal = Vector2.ZERO
	settle_attempts = 0


## 受到伤害
##
## ⚠️ 只有 world.pvp_enabled 时才开复活。单机必须是「死了就没了」的行为，
##    否则「杀死测试敌人」这件事在单机下就不再成立（见 docs/pitfalls.md 3.8：
##    HTML 版的复活一开始泄漏进了单机）。
func take_damage(cfg: ConfigRes, world, amount: float, _source = null) -> bool:
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0 and alive:
		alive = false
		stop()
		deaths += 1
		var sec := 0.0
		if world != null and world.pvp_enabled:
			sec = maxf(0.0, cfg.respawn_sec)
		death_timer = sec
		if world != null:
			world.push_event({"type": "kill", "unit": self, "source": _source})
	return alive


## 复活倒计时。到点后满血、回到自家大本营旁边、清空所有交战状态。
##
## 位置用「单位序号」决定（general-p2-2 → 第 2 个位置），而不是按死亡次数漂移 ——
## 这样同一批将领每次复活的站位是固定、可预测的，不会几轮之后跑到奇奇怪怪的地方。
##
## @return bool 本帧是否发生了复活
func tick_respawn(cfg: ConfigRes, world, dt: float) -> bool:
	if alive or death_timer <= 0.0:
		return false
	death_timer = maxf(0.0, death_timer - dt)
	if death_timer > 0.0:
		return false

	var home = world.home_base_of(faction)
	var pick_tile := Vector2i(tx, ty)
	if home != null:
		var slot := _slot_from_id()
		var ring: Array[Vector2i] = [
			Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1),
			Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1),
		]
		for k in ring.size():
			var o: Vector2i = ring[(slot - 1 + k) % ring.size()]
			var nx: int = home.x + o.x
			var ny: int = home.y + o.y
			if PathfinderRes.passable(world.map, world.buildings, cfg, nx, ny, faction):
				pick_tile = Vector2i(nx, ny)
				break

	alive = true
	hp = hp_max
	pos = GridRes.center_of(pick_tile)
	tx = pick_tile.x
	ty = pick_tile.y
	path = []
	has_goal = false
	moving = false
	goal = Vector2.ZERO
	clear_target()
	attack_cd = 0.0
	world.push_event({"type": "respawn", "unit": self})
	return true


## id 末尾的数字（general-p2-2 → 2），用于复活站位
func _slot_from_id() -> int:
	var parts := id.split("-")
	var tail := String(parts[parts.size() - 1])
	if tail.is_valid_int():
		return maxi(1, int(tail))
	return 1


## 血量比例（渲染 / HUD 用）
func hp_ratio() -> float:
	if hp_max <= 0.0:
		return 0.0
	return clampf(hp / hp_max, 0.0, 1.0)
