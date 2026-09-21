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

## 队形：本次命令要「借哪张距离场」拼路线（全队共用的那张）。
## (-1,-1) = 不用场，走普通的「一次寻路到自己的落点」。
## ★ 它只在一次 order_move_via_field 内部有效 —— 是**调用期的临时提示**，不是持久状态。
var _field_tile: Vector2i = Vector2i(-1, -1)

## jam_timer：想走到终点、但每帧都被挤回来（进度被抵消）的累计时间。
##
## ★ 它解决的是「推挤能把单位推走的距离（一帧最多 ~0.25 格）远大于它自己的
##   移动速度（基线 0.04 格/帧，1/4 速度下只有 0.01 格/帧）」这个数量级失衡：人群里的单位可能**永远走不到终点**，
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
## 上一次「为追击而重算路径」时，目标所在的位置。
##
## ★★ 用途：追击时不再无条件按周期重算路径，而是**只在目标真的挪过地方**时才重算。
##    为什么必须这样（实测）：1000 个单位追击 = 每秒 3000+ 次完整寻路，
##    而目标是墙 / 建筑 / 站定的单位时那些计算全是白费 —— 实机行军攻击因此掉到
##    **49 ms/帧（20 fps）**，而且帧一慢 dt 变大、同一帧里到期的重寻路更多，是正反馈。
##    哨兵值取一个离任何目标都很远的点，保证「刚发现目标」时一定会算一次。
var last_repath_to: Vector2 = Vector2(-99999.0, -99999.0)

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

## ---- 招募队列：**将领自己就是兵营**（星际争霸那套「一个在读条 + 最多四个排队」）----
##
## ★ 为什么状态挂在单位上而不是 world 里另开一张表：
##   队列天然属于某个将领（它死了队列就该没），而 world.units 已经是权威列表；
##   另开一张「将领 id → 队列」的表就多出一份要对齐、要快照、要清理的状态。
## ★ 读条期间将领被**钉在原地**（不能移动、不能攻击，见 world.tick 的 _tick_recruitment
##   与 _pin_training_leaders）—— 所以 train_anchor 必须记住开招那一刻的位置。
var train_kind: String = ""            ## 正在读条的那个兵种（空 = 没在读条）
var train_remaining: float = 0.0       ## 这一单还剩几秒
var train_total: float = 0.0           ## 这一单总共几秒（渲染画进度条要分母）
var train_queue: Array[String] = []    ## 排队的兵种（最多 queue_max - 1 个）
## 这一队已经花掉的粮食 / 黄金 / 人口 —— **将领阵亡要按它退款**。
## 用累加值而不是「查当前队列」：成本表哪天改了，退款也不会退错数目。
var train_cost_food: float = 0.0
var train_cost_gold: float = 0.0
var train_cost_pop: float = 0.0
## 人口是从哪个区划扣的（退款要还回**同一个**区划）
var train_zone_id: int = -1
## 招募期间钉住的位置（开招那一刻的 pos）
var train_anchor: Vector2 = Vector2.ZERO

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


# ------------------------------------------------------------------
# 招募队列（将领 = 兵营）
# ------------------------------------------------------------------

## 这个单位现在是不是「正在招募」（在读条，或还有排队的）。
## ★ 这就是「钉在原地」的判据：true 时 world.tick 跳过它的移动与战斗，
##   命令层也会把它从 move / attack 的目标里剔掉。
func is_training() -> bool:
	return train_kind != "" or not train_queue.is_empty()


## 队列里一共有几个（含正在读条的那个）
func train_queue_size() -> int:
	var n: int = train_queue.size()
	if train_kind != "":
		n += 1
	return n


## 正在读条那个的进度（0~1；没在读条时 0）
func train_progress() -> float:
	if train_kind == "" or train_total <= 0.0:
		return 0.0
	return clampf(1.0 - train_remaining / train_total, 0.0, 1.0)


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
##
## @param settle `true` = 目的是「**站到某个点上**」，落点被占时要在附近挑一个空位。
##        `false` = 目的是「**向某个点靠近**」（追击移动中的敌人）—— **跳过挑空位**。
##
## ★★ 为什么 `settle` 这个参数是本项目最值钱的一个开关（实测）：
##    追击时落点永远是**敌人脚下那一格**，而敌人正站在那儿 —— 于是 `_arrival_congested`
##    必然为真，每一次追击寻路都白跑一遍 `_find_arrival_slot`：
##      · 先 `reachable_tiles()` 建一遍全图可达掩码（C# 内核单次 ~0.5 ms）；
##      · 再对十几个候选点各扫一遍 `world.units`（1000 个单位）—— 单次 ~226 µs。
##    1000 个单位行军攻击时，**同一帧**有几百个单位首次锁定目标（索敌是批量算的，
##    所以它们天然同步），于是一帧里几百次 226 µs = **200+ ms 的单帧卡顿**，
##    实机表现就是行军攻击掉到 20 fps。而追击**根本不需要空位**：
##    进入攻击距离就会 `update_combat` → `halt()` 站住开火，那一步轮不到落点判定。
##
##    挑空位本身是对的 —— 它是为「玩家点一个点、一群人都要走过去站好」服务的
##    （见 `_arrival_congested` 的注释）。所以这里是**分流**，不是删功能。
func move_to(world, cfg: ConfigRes, world_pt: Vector2, settle: bool = true) -> bool:
	move_to_calls += 1
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
	var _dest_ok := PathfinderRes.passable(map, world.buildings, cfg, dest_tile.x, dest_tile.y, faction)
	if not _dest_ok:
		var near = PathfinderRes.nearest_reachable_point(map, world.buildings, cfg, from, dest_tile, world_pt, faction, 32, world.crowd)
		if near != null:
			# ⚠️ 连落点所在的格一起换掉：贴边落点常常就在（不可通行的）目标格边缘上，
			#    而 A* 的终点必须是可通行格 —— 只换点不换格，find_path 会直接返回 null
			#    （那样连点山都点不动了，实测踩过）。
			dest_pt = near["pt"]
			dest_tile = near["tile"]
		else:
			var alt = PathfinderRes.nearest_reachable(map, world.buildings, cfg, from, dest_tile, faction, 20, world.crowd)
			if alt == null:
				alt = PathfinderRes.nearest_reachable(map, world.buildings, cfg, from, dest_tile, faction, 60, world.crowd)
			if alt == null:
				return false
			dest_tile = alt
			dest_pt = GridRes.center_of(alt)

	var tile_path = _tile_path(world, cfg, from, dest_tile)
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
	var pts := PathfinderRes.smooth_path(map, world.buildings, cfg, raw, faction, world.crowd)
	# ★ 第二步：把拉直后剩下的硬拐角圆化。
	#   拉直只减少路径点，单位却是「走到路点才允许转向」，所以拐弯原本发生在**一帧之内**
	#   （实测直角弯单帧转角 63°）。圆化把转向摊到十几帧里。
	#   安全性：圆角曲线落在折线的凸包内，且结果里每一段都过 segment_clear 兜底。
	pts = PathfinderRes.round_corners(map, world.buildings, cfg, pts, faction, world.crowd)
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
	# ★ settle = false（追击）时整段跳过 —— 理由见 move_to 的 @param。
	var settled_here := false
	if settle and _arrival_congested(world, cfg, dest_pt):
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


## 追击移动：目标**近且直线无阻挡**时直接走直线，不走距离场 / A* / 拉直 / 圆角 / 落点挑选。
##
## ★★ 为什么单开一条入口（实测，行军攻击 20 fps 的第二大头）：
##    · `move_to` 走的是「以**目标格**为终点的距离场」，于是每个**不同的敌人所在格**
##      都要建一张新场 —— 而建场是**一次全图 Dijkstra**（C# 内核约 0.5 ms），LRU 只有 4 张。
##      索敌是批量算的，几百个单位天然**同一帧**首次锁定目标 → 同一帧几十个新目标格
##      → 几十次 Dijkstra → 实测单帧 `mv/tile` 峰值 **21.5 ms**。
##    · 拉直（smooth_path）/ 圆角（round_corners）是为「长距离行军」服务的：
##      几格之内的追击用不上它们。

## 安全性：不满足「够近 + 直线可切」就**原样退回 move_to(settle=false)**，
## 所以绕山 / 贴墙 / 隔墙追击的行为与从前完全一致（test_path_feel / test_diagonal 盯着）。
func chase_to(world, cfg: ConfigRes, target_pos: Vector2) -> bool:
	if pos.distance_to(target_pos) <= cfg.chase_direct_range \
			and PathfinderRes.segment_clear(world.map, world.buildings, cfg, pos,
				target_pos, faction, world.crowd):
		_set_direct_path(target_pos)
		return true
	return move_to(world, cfg, target_pos, false)


## 直接给一条两点直线路径（追击专用，见 chase_to）。
## ⚠️ 字段复位必须和 move_to 保持一致：少复位一个 best_dist / stuck_timer，
##    「卡住认账」那套逻辑就会带着上一条路的进度继续算（docs/pitfalls.md 3.2 同款）。
func _set_direct_path(p: Vector2) -> void:
	var pts: Array[Vector2] = [p]
	path = pts
	goal = p
	has_goal = true
	moving = true
	settling = false
	jam_timer = 0.0
	best_dist = INF
	stuck_timer = 0.0


## 地块路线：优先走 world 的 C# **距离场**（一次建场、全队共用那条路线），
## 内核不可用时回退 pathfinder.find_path 的 A*（普通版引擎 / 还没构建 C#）。
##
## ★ 为什么不是每个单位各跑一次 A*：实测 100×100 图上单次 A* = 19 ms，
##   1000 个单位群编就是 **17 秒的命令帧冻结**。距离场把「N 次 A*」压成「1 次 Dijkstra」。
##   两条路的代价口径逐条对齐（通行 / 对角守卫 / 地形代价 / 建筑惩罚），
##   所以「场找得到、A* 找不到」这类不一致不会出现。
func _tile_path(world, cfg: ConfigRes, from: Vector2i, to: Vector2i) -> Variant:
	if world.crowd != null:
		if _field_tile.x >= 0:
			# 队形：全队共用一张「到 _field_tile」的距离场，各自的落点从它拼出来
			return world.crowd.tile_path_via(world, cfg, from, to, _field_tile, faction)
		return world.crowd.tile_path(world, cfg, from, to, faction)
	return PathfinderRes.find_path(world.map, world.buildings, cfg, from, to, faction)


## 队形专用：走到 dest_pt，路线借「到 field_tile 的距离场」拼出来。
##
## 为什么要有单独的入口而不是改 move_to 的签名：那个「借哪张场」只是**这一次调用**的
## 临时提示，不该变成单位上的持久状态（下一轮命令就作废了）。放在这里一进一出，最不容易忘。
func order_move_via_field(world, cfg: ConfigRes, dest_pt: Vector2, field_tile: Vector2i) -> bool:
	_field_tile = field_tile
	var ok := order_move(world, cfg, dest_pt)
	_field_tile = Vector2i(-1, -1)
	return ok


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
	# ★ 无敌建筑（区划中心）不接受攻击命令：它 owner 是空字符串，`same_side` 拦不住，
	#   放进来会变成「走过去对着打不掉的柱子敲一辈子」，而且 ordered_building 黏住之后
	#   敌人贴脸了它也不还手。见 combat.nearest_enemy_building() 的同一条守卫。
	if b.has_method("is_invulnerable") and b.is_invulnerable():
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


## 队形版的行军攻击：走到 dest_pt（自己的槽位），但终点判定仍然以**全队目标点**为准。
## ⚠️ attack_move_goal 必须是全队目标点而不是槽位 —— 「到点了就算完成」那条判定
##    用的是它（见 combat.update_unit），写槽位的话每个单位都要走到自己那格里才算完，
##    队尾的人会因为差半格而一直保持行军攻击状态。
func order_attack_move_at(world, cfg: ConfigRes, dest_pt: Vector2, field_tile: Vector2i) -> bool:
	_field_tile = field_tile
	var ok := order_attack_move(world, cfg, dest_pt)
	_field_tile = Vector2i(-1, -1)
	if ok:
		attack_move_goal = GridRes.center_of(field_tile)
	return ok


# ------------------------------------------------------------------
# 到达落点（拥挤时就近找空位）
# ------------------------------------------------------------------

## 单位之间的最小圆心距离（与 collision.gd 用同一套口径）
func min_unit_distance(cfg: ConfigRes) -> float:
	return maxf(0.0, cfg.unit_collision_radius) * 2.0 \
		* clampf(cfg.unit_overlap_allowance, 0.0, 1.0)


## 这个落点是否会被别人占着（窄口径：只看那些**已经到达落点附近并停下来**的单位）。
##
## 为什么不看「正在移动的单位」：那群人正在一起赶路，彼此离得远，看他们没意义。
## 真正要避开的只有「已经站定在那儿的人」。
##
## ★★ 先用**格差**筛一遍再算距离：这是群编命令帧里唯一的 O(n²)——
##    1000 个单位下一个命令就是 100 万次「属性访问 + 开方」。
##    最小圆心距只有 0.252 格，所以「格差 > 1」的人根本不可能落在半径内，
##    一次整数比较就能挡掉。实测这一条把命令帧砍掉一大截。
func _arrival_congested(world, cfg: ConfigRes, p: Vector2) -> bool:
	var need: float = min_unit_distance(cfg)
	if need <= 0.0:
		return false
	var t := Vector2i(floori(p.x), floori(p.y))
	var near_tiles := 1 if need < 1.0 else int(ceilf(need)) + 1
	for other in world.units:
		if other == self or not other.alive:
			continue
		if other.moving:
			continue                     # 还在赶路的：不算占位
		if absi(other.tx - t.x) > near_tiles or absi(other.ty - t.y) > near_tiles:
			continue
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
	var region = PathfinderRes.reachable_tiles(world.map, world.buildings, cfg, from, faction, world.crowd)

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


func _slot_ok(world, cfg: ConfigRes, p: Vector2, faction: String, region, need: float) -> bool:
	var t := Vector2i(floori(p.x), floori(p.y))
	if not world.map.terrain.has(t.x, t.y):
		return false
	if not PathfinderRes.passable(world.map, world.buildings, cfg, t.x, t.y, faction):
		return false
	# ★ 本体级：格级放行了不代表站得住（大本营 / 箭塔的本体挡敌方）
	if CollisionRes.body_blocked_at(world, cfg, faction, p, CollisionRes.radius(cfg)):
		return false
	if not PathfinderRes.in_region(region, world.map.terrain.idx(t.x, t.y)):
		return false
	# ★ 同 _arrival_congested：先用格差筛，再算距离（最小间距远小于一格）
	var near_tiles := 1 if need < 1.0 else int(ceilf(need)) + 1
	for other in world.units:
		if other == self or not other.alive:
			continue
		if absi(other.tx - t.x) > near_tiles or absi(other.ty - t.y) > near_tiles:
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


## ★ 换目标时调用：清掉重寻路的限流，并把「上次算路时目标在哪」推回哨兵值，
##   保证刚锁定目标那一下**一定**会算一次路径（否则若旧目标恰好离新目标很近，
##   距离判据会以为旧路还行，单位会沿着上一条命令的旧路走）。
func reset_repath() -> void:
	repath_timer = 0.0
	last_repath_to = Vector2(-99999.0, -99999.0)


## 只脱离「当前在打谁」，**不动**玩家的命令
## （行军攻击要能在打完一个之后继续走，所以 combat.gd 的「目标没了」都走这里）
func drop_engagement() -> void:
	target = null
	target_building = null
	anchor = null
	reset_repath()


## 把连续位置换算成所在地块（tx/ty 只用于占区块 / 资源 / 箭塔 / 警戒判定）
func sync_tile(map) -> void:
	tx = clampi(floori(pos.x), 0, map.terrain.cols - 1)
	ty = clampi(floori(pos.y), 0, map.terrain.rows - 1)


## 只在**真的跨了格**的时候才改 tx/ty。
##
## ★ 为什么不是直接调 sync_tile：单位一帧只走 speed*dt（1/4 速度下 ≈ 0.01 格），而一格是 1 格 ——
##   也就是平均每 25 帧才换一格，原来却每帧都 floori 两次 + clampi 两次 + 写两个属性。
##   （sync_tile 本身保留：碰撞把单位推开之后要走那条路，那里确实可能跨格。）
func _sync_tile_if_changed(map) -> void:
	var nx := clampi(floori(pos.x), 0, map.terrain.cols - 1)
	var ny := clampi(floori(pos.y), 0, map.terrain.rows - 1)
	if nx != tx:
		tx = nx
	if ny != ty:
		ty = ny


## 一帧最多推进几段路径（见 STEP_GUARD_MIN 的注释）。
## 按地图对角线算：一条直线路径的拐点数不会超过它经过的格数，
## 所以这个护栏对正常行军永远是「走得到」，只拦住真正的病态路径。
## ⚠️ 地图尺寸现在是地图编辑器说了算（可以远大于 24×16），所以这里**不能写死**。
## ⚠️ 它也不该大到失去意义：*4 之后 1000×1000 的地图是 5600 段/帧，
##    而一帧真要跑 5600 段本身就是病态路径，护栏照旧能拦住。
##
## ★★ 结果按地图尺寸缓存（静态）：它只跟 cols/rows 有关，而原来
##    **每个单位每帧**都要算一次 `sqrt(cols² + rows²)` —— 1000 个单位就是每帧 1000 次开方。
static var _guard_key: int = -1
static var _guard_val: int = 0
## ★ 诊断计数器：真正进过 move_to（= 寻路）多少次。只有基准读它，逻辑不依赖。
##   和 CombatRes.repath_calls 一起看，就能分清「次数太多」还是「单次太贵」。
static var move_to_calls: int = 0


func step_guard(map) -> int:
	var key: int = map.terrain.cols * 4096 + map.terrain.rows
	if key != _guard_key:
		_guard_key = key
		var diagonal := sqrt(float(map.terrain.cols * map.terrain.cols
				+ map.terrain.rows * map.terrain.rows))
		_guard_val = maxi(STEP_GUARD_MIN, int(diagonal * STEP_GUARD_FACTOR))
	return _guard_val


## 平滑移动：路径点是格坐标（最后一个点就是玩家点击的位置）。
## 每帧按剩余距离沿折线推进；跨过拐点时把多余距离**带到下一段**，
## 这样即使一帧跨过好几个地块，速度也是均匀的、不会抖动或卡顿。
func step_along_path(world, cfg: ConfigRes, dt: float) -> void:
	var map = world.map
	# 本帧还剩多少距离预算。循环里会被消耗掉，所以先留一份给「到达处理」用：
	# 判断「谁更接近目标」时要把这一帧的剩余预算也算进去，否则人人都在
	# 自己上一帧的位置上比远近，先到的可能反而落不到那个点。
	#
	# ★ 这里刻意**内联 speed()**：那是每单位每帧一次的方法调用，
	#   而它内部又只是「查一次基础速度 + 查一次森林」。语义与 speed() 完全一致。
	var base_speed: float = cfg.unit_speed_of(kind)
	var on_forest: bool = map != null and map.is_forest(tx, ty)
	var remaining: float = base_speed * (cfg.unit_forest_mult if on_forest else 1.0) * dt

	# recenter 与 remaining 同步消耗：到达判定要用的是**循环之后还剩多少预算**，
	# 而不是本帧开头的预算（否则到达时又走一段，总位移会超过速度预算）。
	var recenter: float = remaining
	var guard := 0
	# ★ 护栏上限提到循环外：原来它写在 while 条件里，**每走一段都要重算一次**（含开方）
	var guard_limit := step_guard(map)

	while remaining > 1e-9 and not path.is_empty() and guard < guard_limit:
		guard += 1
		# 变量名刻意不叫 node：logic/ 里出现 Node 相关字样一律视作架构违规信号
		# （见 docs/architecture.md 第一条铁律），叫 waypoint 也不容易被误读成场景节点
		var waypoint: Vector2 = path[0]
		var delta := waypoint - pos
		var d := delta.length()

		if d <= 1e-6:                     # 已经在这一段终点上
			path.remove_at(0)
			_sync_tile_if_changed(map)
			continue

		# ★ 方向向量只算一次。原来 `delta / d` 在下面两个分支里各写了一遍
		#   （每次都是一次 Vector2 除法）。
		var dir := delta / d
		# ★ 朝向只在**真的变了**的时候才写：facing / last_dir 是脚本属性，
		#   两次属性写比一次比较贵，而直线行军时方向根本不变（1000 单位每帧省 2000 次写入）。
		if absf(dir.x - last_dir.x) > 1e-4 or absf(dir.y - last_dir.y) > 1e-4:
			last_dir = dir
			facing = dir

		if remaining >= d:
			# 走完这一段还有余量 → 落到拐点，继续走下一段
			pos = waypoint
			remaining -= d
			recenter = remaining
			path.remove_at(0)
			_sync_tile_if_changed(map)
		else:
			# 本帧走不完这一段 → 沿方向推进，单位停在地块之间的连续位置上
			pos += dir * remaining
			remaining = 0.0
			recenter = 0.0
			_sync_tile_if_changed(map)

	# ★★ 到达判定：用**距离**，并且用**进度停滞**兜底。
	#
	# 为什么不能只看「路径空了」：路径的最后一个路点就是终点本身，
	#   而人群里这「最后一段」可能**永远走不完** ——
	#   推挤一帧能把单位推走约 0.25 格，它自己一帧只走 0.04 格（1/4 速度下 0.01 格），
	#   于是它一直 moving=true、path 非空，却一步也没靠近终点。
	#   实测：12 个单位点到同一点，2000 帧停不下来、总行程 87 格（本该 8 格）、
	#   方向反转 8000+ 次 —— 肉眼看就是「到达后互相挤着转」。
	# 所以判定有两条，满足任意一条就落位：
	#   1. 到终点的距离 ≤ 本帧预算（真的走到了）；
	#   2. **连续 jam_giveup_sec 秒没有更接近终点**（挤不过去，认账）。
	if not has_goal:
		return                          # 目标已被清掉（交战中 halt 等），什么都不用做
	# ⚠️ 进度用的是「到**终点**的直线距离」，不是「沿路径还剩多少」。
	#    这里踩过一次（加区划中心之后调走过一版）：改成「路径剩余长度」之后，
	#    拥挤的人群永远停不下来 —— 因为每帧的推进都会让 `path` 变短一点，
	#    `stuck_timer` 就被一直清零，`jam_giveup_sec` 那套认账逻辑彻底失效
	#    （实测：12 个单位 1200 帧仍在 moving）。**别再改回去**。
	#
	# ★ 试过并**否决**的第三种口径（单位速度降到 1/4 之后，为了修「绕路被误判成挤住」）：
	#   用「上一帧净位移在路径方向上的投影」当进展判据。它不成立的原因是**数量级**：
	#   1/4 速度下单位一帧只走 0.005 格，而碰撞一帧能推 0.25 格 —— 位移信号完全被
	#   推挤噪声淹没，任何阈值都分不开「在赶路」和「被推着抖」。实测后果是
	#   12 个单位 12000 帧都停不下来（stuck_timer 被噪声一直清零）。
	#   上面这个「到终点距离的**历史最好值**」能用，正因为它是**取记录**而不是逐帧看
	#   变化：噪声在最小值附近来回，很少能刷新记录。
	#   → 速度变慢之后，能调的只有 `unit.jam_giveup_sec` 这一个旋钮（见 config.json）。
	var dist_now: float = pos.distance_to(goal)
	if dist_now < best_dist - 1e-4:
		best_dist = dist_now
		stuck_timer = 0.0
	else:
		stuck_timer += dt
	# ★★ 路径走完 = 到达，哪怕离 goal 还差一点。
	#
	# 为什么必须兜这一条：`world.tick()` 只在 `path` 非空时才调 step_along_path，
	#   所以「path 空了、moving 还是 true」是个**死状态** —— 单位永远不动、
	#   也永远不结束移动（HUD 一直显示在走，settling 的推力权重也一直算在它头上）。
	#
	# 路径末点**不一定**等于 goal：move_to() 是**先建路径、后挑备用落点**的
	#   （`_arrival_congested` 命中时 goal 被换成 0.1~0.2 格外的空位），
	#   于是走完路径那一刻 `dist_now` 可能远大于本帧预算，`arrived` 判不到。
	#   实测（单位速度降到 1/4、12 个单位点到同一点）：走到第 2720 帧必现，
	#   该单位从此冻住不再动；基线速度下同一段代码只是没被走到。
	#   兜底之后它会像 settling 一样就地落位 —— 那本来就是「备用落点」的语义。
	var arrived: bool = path.is_empty() or dist_now <= remaining + ARRIVE_EPS
	var gave_up: bool = stuck_timer >= cfg.unit_jam_giveup_sec
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
## ⚠️ 必须防死循环：人群里回位可能永远失败（一帧被推走 0.25 格、自己只能走 0.04 格，
##    1/4 速度下是 0.01 格）。
##    所以回位次数用尽之后就放弃，就地待着 —— 否则会退化成「永远挤着转」，
##    那正是这条逻辑要修的病。
func reclaim_settled_spot(world, cfg: ConfigRes) -> void:
	if moving or not has_settled_goal or not alive:
		return
	var back_dist: float = maxf(0.02, cfg.unit_settle_return_dist)
	if pos.distance_to(settled_goal) <= back_dist:
		return
	if settle_attempts >= cfg.unit_settle_max_attempts:
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
