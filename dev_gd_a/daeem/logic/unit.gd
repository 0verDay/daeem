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
## ★★ 单位类型 id（兵种）：长枪兵 / 长弓兵 / 骑手 / 测试敌人。
## 权威定义在 data/config.json 的 `unit.types`（数值、步兵还是骑兵、远不远都在那里），
## 这里只是**同一批字符串的常量别名** —— 字面量只写一处（config.gd），
## 免得「改了 JSON 里的 id、代码里还留着一个旧字面量」这种查不出来的错。
const UNIT_TYPE_SPEARMAN := ConfigRes.UNIT_TYPE_SPEARMAN
const UNIT_TYPE_LONGBOWMAN := ConfigRes.UNIT_TYPE_LONGBOWMAN
const UNIT_TYPE_RIDER := ConfigRes.UNIT_TYPE_RIDER
## 兵种大类：步兵 / 骑兵
const CLASS_INFANTRY := ConfigRes.CLASS_INFANTRY
const CLASS_CAVALRY := ConfigRes.CLASS_CAVALRY

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
## ★★ 单位类型（兵种）：长枪兵 / 长弓兵 / 骑手 / 测试敌人。
##
## 与 `kind` 的分工（这是本轮引入的两个字段，别混起来）：
##   · `kind`     —— 单位**类别**：general（将领）/ general_N（区划招募的将领）/
##                   兵种 id（普通单位）/ enemy（测试敌人）。招募表、快照、
##                   「谁能当队长」都按它判。
##   · `unit_type`—— 这个单位**是什么兵**。普通单位 = 自己的 kind；
##                   将领 = unit.general.types 里被赋予的那一个（将领 1 长枪兵、
##                   将领 2 长弓兵、将领 3 骑手）—— 所以将领的 kind 分不出兵种，
##                   必须有这个字段。
## ★ 数值（血 / 速度 / 半径 / 攻击三件套）一律按 `unit_type` 查表 ——
##   于是「将领的数值 = 它所属类型的数值」（用户确认的口径）自动成立。
var unit_type: String = ""
## ★★ 这是**第几位将领**（0 起；非将领 = -1），以及它的**数值覆盖**。
##
## 为什么要这两个字段（本轮新增，config 的 `unit.general.stats`）：
##   需求是「将领可以单独调血量 / 攻击」，而将领的 kind 分不出谁是谁 ——
##   开局那三位的 kind **都是 `general`**（见 world.create_generals），
##   只有「序号」能区分。于是序号在 create 时由调用方给（开局的 i、
##   区划招募的 general_index_of(kind)），数值那一刻就拼好带在身上：
##   没写的键 = 跟随所属兵种（`stat_overrides` 里就没有那个键）。
##
## ⚠️ 覆盖必须**落在单位自己身上**，不能在 `unit_hp_of()` 里按 kind 查 ——
##    否则三位将领的 kind 相同，会一起被第 0 位覆盖掉（一个很安静的错）。
var general_index: int = -1
var stat_overrides: Dictionary = {}
## 兵种大类（infantry / cavalry）与「是不是远程」。
##
## ★★ 为什么要**存在单位上**而不是每次查表：这两个字段就是「后续按兵种做额外伤害」
##    的标签（步兵 / 骑兵，远近是另一维 —— 弓箭手 = 远程步兵、马弓手 = 远程骑兵）。
##    伤害判定在每帧每单位的路径上，创建时算好、之后只读，比每次下潜 JSON 便宜。
var unit_class: String = CLASS_INFANTRY
var ranged: bool = false
## ★★ 视野半径（**格**）—— 战争迷雾用（见 logic/fog.gd）。
##
## ★ 与 hp_max / unit_class 同一个口径：**生出来那一刻就把 config 里的数抄到身上**，
##   之后迷雾每帧只读这一个字段（不做「每帧每单位一次 JSON 下潜」）。
##   · 值来自 `cfg.unit_vision_of(unit_type)`，也就是
##     `unit.types.<类型>.vision`，将领还叠加 `unit.general.stats[i].vision` 的覆盖
##     （`cfg.general_vision_at(i)`）；
##   · ⚠️ 它不是玩法数值：战斗 / 索敌 / 射程一律不受它影响，
##     改它只改变「玩家能看见什么」。
var vision: float = 8.0
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

## 上一次施加的**科技血量倍率**（1.0 = 没加成）。
## ★ 它只服务于 `apply_hp_bonus()` 的「粘性」：倍率没变就什么都不做 ——
##   没有它的话，反复施加会把当前血量反复放大（见那个函数的注释）。
var tech_hp_mult: float = 1.0
## ★ 这个单位**生出来时的生命上限**（config 给的那个数，永不被科技改写）。
## 科技倍率每次都是「基础值 × 倍率」重算上限，而不是在旧上限上再乘一次 ——
## 这样启用 / 弃用 / 反复切换都不会累积误差，弃用后能精确回到原值。
var base_hp_max: float = 200.0

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
## ★★ 「追击参照点」：自动索敌锁定目标时记下**当时所在的位置**，之后**只由
## `combat._refresh_leash_anchor()` 按目标走的路线往前挪**，用于「追出去多远」的判定。
##
## ⚠️ 它**不能**在每次 `acquire_target` 里都无条件重置（实测报回来的 bug：
##    单位在区划边界原地抽搐）：锁定那一刻距离当然是 0 ⇒ 判据必然通过，走一格就超上限、
##    放弃，下一帧又锁上 …… 一帧一放一锁。见 `leash_cd` 与 config 的 `leash_release_cd`。
var anchor: Variant = null
var attack_cd: float = 0.0
## 开火特效的剩余量（1 → 0，`flash_sec` 秒衰减完）。**渲染攻击线**读它。
## ⚠️ 它必须**每帧衰减**，而濒死的将领整段单位逻辑都被跳过 —— 所以
##    `tick_near_death()` 里也要衰减一次（否则倒下那一刻的 1.0 会永远留着，
##    画面上就是「濒死的将领一直和某个单位连着一条线」，实测报回来的 bug）。
var attack_flash: float = 0.0
var last_target = null        # 最近一次开火的目标单位（渲染攻击线用）
var last_building = null      # 最近一次攻击的建筑（渲染攻击线用）
var repath_timer: float = 0.0
## ★★ 因为追击上限（leash）放弃之后，还要等几秒才允许**再自动锁定单位**。
## 见 config 的 `combat.leash_release_cd` 与 `combat.acquire_target` 里的那一句。
## ★ 与驻防将领的 `retarget_cd` 是**两件事**（那个由 general_ai 驱动、管「不追出区划」），
##   不要合并：玩家阵营的普通单位也要防这个抖动。
var leash_cd: float = 0.0
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

## ---- ★★ 将领**濒死**（本轮新增，见 config.json 的 revive 段）----
##
## 需求：将领被打到 0 血不立刻死，而是「濒死」——期间**无敌**（谁也点不到它、
## 箭塔也不打它）、**不能动也不能打**、血量**只增不减**地慢慢回到上限的 20%；
## 玩家（或 AI）花资源点「再起」，读条结束后才真正回到战场。
##
## ★ 为什么这些状态挂在**单位自己**身上（而不是 world 里另开一张「濒死表」）：
##   与招募队列同一条理由 —— 濒死天然属于某个将领（它死了状态就该没），
##   而 `world.units` 已经是权威列表。另开一张表就多出一份要对齐、要快照、
##   要在「单位被摘出列表」时清理的状态（漏一处就是幽灵将领）。
##
## ★★ `downed` 与 `alive` 的分工（这是本机制最容易搞混的一处）：
##   · `downed == true` **仍然 `alive == true`** —— 因此它照旧占着 AI 的将领槽位
##     （`_generals_of` 只看 alive）、照旧进 zone 读条、照旧被渲染；
##   · 「能不能被打 / 能不能被选中为攻击目标」的唯一判据是 `is_attackable()`
##     （= alive and not downed），**不是** alive。别在别处另写一份。
var downed: bool = false
## 离下一次回复还有几秒（每 `revive.regen_sec` 秒回 1% 上限）。
var nd_regen_timer: float = 0.0
## 已经回复出来的血量（**绝对量**；写进 hp 的就是它）——见 `nd_hp_ratio`。
var nd_regen_hp: float = 0.0
## ★★ 回复量的**比例口径**：`nd_hp_ratio = hp / hp_max` 在「濒死回复」这一路上的镜像。
##
## 为什么不能用 `hp / hp_max` 现算：科技（leader_hp_mult）会在回复期间改 `hp_max`，
## 而需求要的是「按比例重算」（上限 200 → 220 时，30 血（15%）变 33 血（仍是 15%））。
## 记下比例之后，`hp_max` 一变只要 `hp = hp_max × nd_hp_ratio` 就精确成立，
## 不会因为浮点误差在长时间回复后漂出一个百分点。
var nd_hp_ratio: float = 0.0
## 「再起」的读条：剩余 / 总秒数（`revive_pending` = 正在读条）。
## ⚠️ 与招募的 train_* 是**两套独立字段**，不要合并：将领可能同时在招兵（读条）与再起，
##   而两者的规则完全不同（招兵期间被钉住、再起期间无敌且暂停全灭判定）。
var revive_remaining: float = 0.0
var revive_total: float = 0.0
## ★★ 「正在读条再起」这个**布尔开关**（本轮新增）。
##
## 为什么不能只看 `revive_remaining > 0`（这是实测踩到的一个真 bug）：
##   `revive_remaining` 会在**读完的那一帧**被减到 0，于是「全灭判定暂停」那一条
##   在同一次调用里立刻失效 —— 而函数是**先**走「读条完成 → 站起来」那一支的
##   直接 `return`，全灭判定整段被跳过。结果：读条读完的那一帧如果它旗下正好一个兵
##   都没有，它就**带着 0 个兵活着站起来了**（实测：`kill_unit_now` 送不走的将领，
##   它会在场上以一个「没有部队却活着」的幽灵状态继续存在）。
##   ⇒ 「暂停到什么时候」必须由一个**显式开关**表达，而不是从倒计时里推。
var revive_pending: bool = false
## 倒下的位置（濒死期间钉在这上面：用户拍板「将领濒死后无法移动，视作倒在原地」）。
## 附属兵的行军攻击目标也是它（**固定点**，不跟踪移动 —— 它本来就动不了）。
var downed_anchor: Vector2 = Vector2.ZERO

## ★ 驻守（地图预置单位用的开关）：true = **不执行推进 AI**，原地待着。
## 迎战不受影响 —— 有人靠近照样会打（警戒与战斗是另一条路，见 combat.gd）。
## 用处：地图上摆几个「测试用守军」时，不希望它们开局就朝玩家据点行军。
var hold_position: bool = false

## ---- ★★ 将领性（防御性）AI 的归属（本轮新增，见 logic/general_ai.gd）----
##
## `garrison_zone_id` = 这个将领**负责的区划 id**（-1 = 不归任何将领性 AI 管）。
##
## ★ 为什么是「区划 id」而不是「巡逻点坐标」：需求的整段语义都挂在区划上 ——
##   「在其归属的区划中有时间间隔地巡逻」「不会追击超过一个区划」「在脱战后招兵」。
##   存 id 之后，巡逻目标（区划中心）与「追出区划了没有」两件事都只是**一次查表**，
##   而存坐标就得自己维护一套「这些点属于哪个区划」的映射。
## ★ 归属从两处来：
##   · 地图 `units[]` 里的 `zone` 字段（地图作者明写，见 map_data._read_units）；
##   · 出生时所在的那一格（区划中心招出来的守将 —— 本轮还没有这条路，留着给以后）。
## ★ 有它的单位**不再跑 enemy_ai 的推进逻辑**（与 hold_position 同一条效果，
##   见 enemy_ai.gd 的说明）：它只巡逻自己那一亩地。
var garrison_zone_id: int = -1
## 下一次巡逻移动还有几秒（由 general_ai 每帧递减，<= 0 时朝**下一个巡逻点**走一趟）。
var patrol_timer: float = 0.0
## ★★ 这位守将自己的**巡逻路线**（巡逻点，网格坐标；空 = 还没算，general_ai 会补算）。
##
## ⚠️ **必须存在单位自己身上**（不是每帧现算）：路线要「换一个点再走」得记住走到第几个；
##   而且它由 `_patrol_zone_id` + `id` 派生，重算一次结果也一样（确定性伪随机）。
var patrol_points: Array[Vector2i] = []
## 走到路线里的第几个点了（走到底之后**折返**，不是回头从第一个重来）。
var patrol_index: int = 0
## 折返方向：+1 = 往数组后面走，-1 = 往回走。
var patrol_dir: int = 1
## 这条路线是**给哪个区划**算的（区划换了 / 被改派 → 重算路线）。
var patrol_zone_id: int = -2
## 距上一次「正在交战」过去了多久（秒）。达到 ai.general.combat_idle_sec 就认为脱战。
var combat_idle_timer: float = 0.0
## ★★ 再战冷却：> 0 时这个驻防将领**不接战**（见到敌人也不锁）。
##
## 作用（本轮口径调整后**只剩一件事**）：放弃追击、走上返程那一刻拉起来，
##   让它在回家路上不被同一个敌人立刻再锁一次。
##   ⚠️ 「不再抖动」的主保证本轮换成了**距离判据**（见 `chase_alert_range`）：
##      原来只靠这个冷却挡抖动，而冷却是**按时钟**的 —— 冷却一结束，如果敌人还在
##      警戒半径里，它又追出去、又被叫回来，几分钟内来回抽。
var retarget_cd: float = 0.0
## ★★ 「我正在回家的路上」（见 logic/general_ai.gd 的返程那一段）。
##   它保证返程**只下一道命令**（不是每帧重下 —— 那会把路径一帧一帧重置、
##   人永远走不回家，看着就是在区划边缘原地抽）。走到家或来了新命令才清。
var returning_home: bool = false
## 「我正在回家」已经持续了多久（秒）。**返程必须有终点**（本轮修 bug）：
## 实测（真地图 frontier 上的集成探针）：一次放弃追击之后它一直卡在别人区划边缘、
## `returning_home` 挂了 25 秒都没清 —— 而清不掉的后果是 `general_ai.update()` 第 5 步
## **永远被跳过** ⇒ 它再也接不到新巡逻命令，等于定死在那儿。
## ⇒ 用这个计时给返程兜一个上限（见 `RETURN_HOME_MAX_SEC`），超了就当到家、恢复巡逻。
var returning_home_sec: float = 0.0
## ★★ 正在追击某个敌人（本轮新增的「追击」状态）。
##
## 语义（用户口径）：「巡逻时发现敌人后向该敌人追击，当该敌人死亡或在自己的
##   警戒范围外时，放弃追击转为立刻返回所属区划继续巡逻」。
##   · 置真：combat 刚锁上一个敌人（= 巡逻中警戒到了）；
##   · 置假：敌人死了 / 跑出警戒范围 / 又踩出自己区划 / 卡住追不动 ⇒ 转回家。
var chasing: bool = false
## 追击的**起点**（发现敌人那一刻它自己站的位置）。警戒范围的判据就量它：
## 「敌人离我**当初发现它的地方**有没有超出警戒范围」。用固定起点而不是
## 「我离敌人多远」，是为了让「追到底 → 目标掉头跑 → 追出警戒范围就回家」
## 这条链闭合 —— 判据只跟目标的移动有关，跟我自己被挤到哪无关（不然会抖）。
var chase_anchor: Vector2 = Vector2.ZERO
## 发现敌人那一刻，**敌人离我有多远**（= 这一轮实际生效的警戒范围）。
## 它天然落在 [`attack_range`, `aggro_range`] 之间（能锁上就说明在警戒半径内），
## 于是「贴脸发现」只追一两个身位、「远远发现」才追得远，比写死一个半径更自然。
var chase_alert_range: float = 0.0
## 追击中「原地不动」持续了多久（追不到 / 被卡住）—— 超过阈值就放弃追击转回家。
var chase_stuck_timer: float = 0.0
## 上一帧的位置（只给 `chase_stuck_timer` 判「这一帧动没动」用）。
var chase_last_pos: Vector2 = Vector2.ZERO
## 下一次检查「要不要无消耗招兵」还有几秒（把 O(附庸兵数) 的统计摊到几秒一次）。
var garrison_recruit_timer: float = 0.0

## ---- 纯表现的本地标志 ----
## selected：由 view/input_controller 写、view/overlay 与 unit_view 读。
## ★ 它不是权威状态：不进快照、不进命令流（第 1 轮联机时也一样）。
##   挂在逻辑对象上只是因为「选中」天然属于某个单位，省一层映射表。
var selected: bool = false


## @param p_unit_type 单位类型（兵种）id。空 = 由 kind 推（普通单位推出来就是它自己，
##        将领推出来是 unit.general.types[0]）—— **开局那三个将领必须显式传**，
##        因为它们 kind 都是 general，只有这个参数能区分谁是谁。
## @param p_general_index 第几位将领（0 起；非将领 / 附属兵传 -1）。
##        ★ 它决定要不要套 `unit.general.stats` 里那一份**数值覆盖**
##          （见 unit.gd 上面 `stat_overrides` 的说明）。
static func create(cfg: ConfigRes, p_id: String, p_name: String, tile: Vector2i, p_faction: String, p_kind: String = KIND_GENERAL, p_hotkey: String = "", p_leader_id: String = "", p_unit_type: String = "", p_general_index: int = -1) -> RefCounted:
	var u = new()
	u.id = p_id
	u.name = p_name
	u.kind = p_kind
	u.unit_type = p_unit_type if p_unit_type != "" else cfg.unit_type_of(p_kind)
	u.unit_class = cfg.unit_class_of(u.unit_type)
	u.ranged = cfg.unit_is_ranged(u.unit_type)
	u.faction = p_faction
	u.hotkey = p_hotkey
	u.leader_id = p_leader_id
	u.general_index = p_general_index
	if p_general_index >= 0:
		u.stat_overrides = cfg.general_stat_overrides(p_general_index)
	u.pos = GridRes.center_of(tile)
	u.tx = tile.x
	u.ty = tile.y
	# ★ 数值走 cfg.unit_*_of(unit_type)：原来写的是「是将领吗？不是就当敌人」，
	#    加了第三种兵种之后那个二元判断会**静默把新兵种当成测试敌人**（60 血）。
	#    现在每个单位类型都在 config.unit.types 里明确定义，查不到才用兜底值。
	# ★★ 将领的**数值覆盖**在这里落地（没写的键 = 跟随所属兵种那一档）。
	u.hp_max = float(u.stat_overrides.get("hp_max", cfg.unit_hp_of(u.unit_type)))
	u.base_hp_max = u.hp_max
	u.hp = u.hp_max
	# ★ 视野半径同样在出生那一刻定下来（战争迷雾只读它，见上面 `vision` 的说明）。
	#   将领走 general_vision_at（覆盖 ⊕ 所属兵种），普通单位走 unit_vision_of。
	if p_general_index >= 0:
		u.vision = cfg.general_vision_at(p_general_index)
	else:
		u.vision = cfg.unit_vision_of(u.unit_type)
	return u


## 这个单位是不是**将领**（开局的 general，或区划招募出来的 general_N）。
##
## ★ 判据是 kind，**不是 leader_id**：测试敌人的 leader_id 也是空的，
##   用「有没有队长」分不出将领与敌人（那样测试敌人会被画成粗描边的将领）。
## ★ 这是渲染（描边更粗）与「将领吃的科技加成」共用的判据，别在别处另写一份。
func is_general() -> bool:
	return ConfigRes.general_index_of(kind) >= 0


## 是不是骑兵（后续「按兵种额外伤害」的标签之一）
func is_cavalry() -> bool:
	return unit_class == CLASS_CAVALRY


## 是否正在等待复活（单机永远 false —— 死亡即离场）
func awaiting_respawn() -> bool:
	return (not alive) and death_timer > 0.0


# ------------------------------------------------------------------
# ★★ 将领濒死（config.json 的 revive 段；规则细节见文件上方那组字段的说明）
# ------------------------------------------------------------------

## 这个单位现在是不是**濒死**（倒在原地、无敌、不能动也不能打）。
func is_downed() -> bool:
	return alive and downed


## ★★ **能不能被打 / 能不能被选为攻击目标**的唯一判据。
##
## ⚠️ 别在索敌 / 开火 / 点选里写 `alive`：濒死的将领照样 `alive == true`，
##    用 alive 判就会变成「已经倒地的将领还在挨打」（需求明确禁止）。
##    与 `is_general()` 一样，这是个**只有一处实现**的判据 —— 多写一份迟早会漂开。
func is_attackable() -> bool:
	return alive and not downed


## 现在是不是「已经点了再起、正在读条」。
##
## ★ 它的语义不止是「有个进度条」：从点下再起那一刻起，该将领**被视为单位**，
##   全灭判定**暂停**（用户拍板）—— 见 `tick_near_death()`。
## ★ 判据是那个显式开关 `revive_pending`（不是倒计时 > 0）：读完的那一帧倒计时已经归零，
##   用它当判据会让「读完 → 站起来」那一步把全灭判定整段跳过（见 `revive_pending` 的说明）。
func is_reviving() -> bool:
	return downed and revive_pending


## 濒死将领的血量到「允许再起」那条线了吗（config 的 revive.ready_ratio，默认 10%）。
##
## ★ 判据放在**单位**上而不是界面里：这是玩法规则（逻辑层也要用它拒命令），
##   界面只是拿它决定那一格亮不亮。
func revive_ready(cfg: ConfigRes) -> bool:
	if not downed or hp_max <= 0.0:
		return false
	return hp / hp_max >= cfg.revive_ready_ratio - 1e-9


## 濒死回复的进度（0~1；渲染 / 信息栏画那条小进度条用）。
## ★ 分母是**回复天花板**而不是 hp_max：这条进度要表达的是「离回复满还差多少」。
func nd_regen_progress(cfg: ConfigRes) -> float:
	if not downed:
		return 0.0
	var cap: float = hp_max * cfg.revive_regen_cap_ratio
	if cap <= 0.0:
		return 1.0
	return clampf(nd_regen_hp / cap, 0.0, 1.0)


## 「再起」读条进度（0~1；没在读条时 0）
func revive_progress() -> float:
	if revive_remaining <= 0.0 or revive_total <= 0.0:
		return 0.0
	return clampf(1.0 - revive_remaining / revive_total, 0.0, 1.0)


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


## 这个将领现在有**几个兵账**（= 队列里排着的 + 已经生成出来的附属兵）。
##
## ★★ 「满员」的唯一判据就是它 —— 见 logic/general_ai.gd 与 faction_ai.gd：
##   两边都用 `retinue_size() >= min_retinue` 判「补够了没有」，
##   各写一套「算不算满」迟早会漂开（一个看队列、一个不看，AI 就会永远补不满）。
## ★ 为什么两个都要算：「已经排上队、还在读条」的那几个**迟早会出来**，
##   不把它们算进去的话，AI 每帧都会觉得「还差人」而反复下单 —— 队列会瞬间堆满上限。
##   ⚠️ `train_queue_size()` 已经把正在读条的那个算进去了，别再 `+1`（会虚报一个兵）。
## ⚠️ `world.retinue_of()` 是遍历 world.units 的（O(单位数)），所以这个函数
##   只该在**几秒一次**的 AI 决策里调，不要塞进每帧每单位的循环。
func retinue_size(world) -> int:
	return world.retinue_of(id, false).size() + train_queue_size()


## 这个单位是不是「将领性（防御性）AI」管的驻防将领（见 logic/general_ai.gd）。
## ★ 判据只有 garrison_zone_id 一处：地图写了 zone、或出生在某个区划里。
func is_garrison() -> bool:
	return garrison_zone_id >= 0


## 正在读条那个的进度（0~1；没在读条时 0）
func train_progress() -> float:
	if train_kind == "" or train_total <= 0.0:
		return 0.0
	return clampf(1.0 - train_remaining / train_total, 0.0, 1.0)


## 基础移动速度（格 / 秒）；森林里减半。
## ★ 按 `unit_type` 查表（不是 kind）：将领的速度 = 它所属兵种的速度 ——
##   于是「骑手型的将领跑得更快」是数据决定的，代码里没有特例。
## ★ 将领自己填过速度就用它（config 的 unit.general.stats，见 stat_overrides）。
func speed(cfg: ConfigRes, map) -> float:
	var base: float = float(stat_overrides.get("speed", cfg.unit_speed_of(unit_type)))
	var on_forest: bool = map != null and map.is_forest(tx, ty)
	return base * (cfg.unit_forest_mult if on_forest else 1.0)


## 该单位的战斗数值（按单位类型查 config.unit.types，见 cfg.unit_combat_of）。
## ★★ 将领自己填过的那一项优先（config 的 unit.general.stats）——
##    没填的**不比**、直接走兵种那一档（`get(键, 兵种值)` 一句就表达了「跟随」）。
func combat_damage(cfg: ConfigRes) -> float:
	return float(stat_overrides.get("damage", cfg.unit_combat_of(unit_type)["damage"]))


func combat_range(cfg: ConfigRes) -> float:
	return float(stat_overrides.get("range", cfg.unit_combat_of(unit_type)["range"]))


func combat_cooldown(cfg: ConfigRes) -> float:
	return float(stat_overrides.get("cooldown_sec",
		cfg.unit_combat_of(unit_type)["cooldown_sec"]))


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
		# ★★ 顺手清掉「刚因为追击上限放弃过」的冷却：那是**自动索敌**的节流，
		#    玩家明确下了命令之后，它就只该管「别再自己追出去」，不该拦住新命令。
		leash_cd = 0.0
		# 真正的「新命令」：旧落点与回位计数一起作废。
		# ⚠️ 清零放在这里而不是 move_to —— 否则回位动作会把自己的计数器清零（见 move_to 的注释）。
		clear_settled_spot()
		# ★★ 新命令也把「回家」与「追击」状态清掉（本轮修 bug）：它们是**驻防 AI 追击那一段**
		#    的私有标志，玩家 / 别的 AI 一旦下了新命令，那一段就该作废 —— 留着的话，
		#    驻防将领的第 5 步（巡逻）会永远被跳过，人就定死在原地了。
		returning_home = false
		returning_home_sec = 0.0
		clear_chase()
	return ok


## 清掉「正在追击」这一整套状态（本轮新增）。
##
## 谁该调它：任何**结束追击**的路径（放弃追击 / 到了新命令 / 濒死 / 阵亡清理）。
## ⚠️ 单独一个函数是刻意的：这几个字段要一起清干净（留一个 `chasing = true`
##    而 `target` 已经没了，下一帧就会又走一遍「放弃追击」的收尾逻辑）。
func clear_chase() -> void:
	chasing = false
	chase_alert_range = 0.0
	chase_stuck_timer = 0.0
	chase_last_pos = pos


# ------------------------------------------------------------------
# 玩家下达的攻击命令（右键点敌人 / 右键点建筑 / 双击行军攻击）
# ------------------------------------------------------------------

## 优先攻击某个敌对单位（右键单击敌人）。
## @return 命令是否被接受（不是自己人、还活着）
##
## ★★ 判据走 `same_side_for_attack`（同阵营 **或盟友**）：加了阵营归属之后，
##    玩家**手动点名**也不该能指挥一方去打它的盟友 ——
##    否则「友善」只挡住了自动索敌，右键一点照样能挑起来（那不是需求要的东西）。
func order_attack_unit(world, cfg: ConfigRes, enemy) -> bool:
	# ★★ 濒死的将领**不能被选为攻击对象**（需求原话：「无论是行军攻击还是
	#    指定攻击都不行」）——所以点名这一路也要挡住。
	#    ⚠️ 用 `is_attackable()` 而不是 `alive`：濒死者是 alive 的，用 alive 判会漏掉。
	#    这里返回 false 会让命令层推一条 `order_rejected`（见 _collect_units 那一路：
	#    整队里只要还有能打的，命令照旧发出去，只是这一个目标被挡掉）。
	if enemy == null or not enemy.is_attackable():
		return false
	if FactionRes.same_side_for_attack(enemy.faction, faction):
		return false
	drop_engagement()
	leash_cd = 0.0             # 新命令：清掉自动索敌的节流（见 config.leash_release_cd）
	target = enemy
	ordered_target = enemy
	ordered_building = null
	has_attack_move = false
	clear_settled_spot()
	return true


## 优先攻击某个敌对建筑（右键单击建筑）。
##
## ★ 判据同样走 `same_side_for_attack`（见 `order_attack_unit` 的说明）。
func order_attack_building(world, cfg: ConfigRes, b) -> bool:
	if b == null or not b.alive:
		return false
	if FactionRes.same_side_for_attack(b.owner, faction):
		return false
	# ★ 无敌建筑（区划中心）不接受攻击命令：它 owner 是空字符串，`same_side` 拦不住，
	#   放进来会变成「走过去对着打不掉的柱子敲一辈子」，而且 ordered_building 黏住之后
	#   敌人贴脸了它也不还手。见 combat.nearest_enemy_building() 的同一条守卫。
	if b.has_method("is_invulnerable") and b.is_invulnerable():
		return false
	drop_engagement()
	leash_cd = 0.0             # 新命令：清掉自动索敌的节流（见 config.leash_release_cd）
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
	leash_cd = 0.0             # 新命令：清掉自动索敌的节流（见 config.leash_release_cd）
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


## ★★ 把「上一次开火」的渲染残留清掉（攻击线读的就是这两样 + `attack_flash`）。
##
## 为什么要单独一个函数（本轮修 bug 收口）：**只要单位这一帧不跑单位逻辑，
## `attack_flash` 就不会衰减**（衰减在 `combat.update_unit` 的开头），
## 于是 flash 冻在非零值上、攻击线**永远留着**。实测报回来的两个入口：
##   · 将领**开始招募**（读条期间整段逻辑被跳过，见 `world.tick` 第 4 步）；
##   · 将领**倒下**（濒死整段逻辑被跳过，`enter_near_death()` 已经就地清过一次）。
## ⇒ 凡是「要把它从『正常单位』切出去」的地方，都调一下这个函数。
func clear_attack_fx() -> void:
	attack_flash = 0.0
	last_target = null
	last_building = null


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
	var base_speed: float = cfg.unit_speed_of(unit_type)
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
##
## ★★ 将领的**濒死**分支（本轮新增，见 config.json 的 revive 段）：
##    将领血量归零时不再直接死，而是进「濒死」——前提是它**旗下还有存活部队**
##    （判定在 `world.enter_near_death` 里，因为「旗下有谁」要看整个 world.units）；
##    已经濒死的单位**免疫一切伤害**，所以第一句直接挡掉（`is_attackable()`）。
##
## @return 本击之后这个单位**还能不能被当作在场单位**（true = 还活着 / 或已濒死）
func take_damage(cfg: ConfigRes, world, amount: float, _source = null) -> bool:
	# ★ 濒死 = 无敌：需求原话「在将领濒死期间，该将领无法被选中为攻击对象且不会受到伤害」。
	#   ⚠️ 这一句同时兜住了「读条中被打断」：读条期间仍然免疫（用户拍板）。
	if downed:
		return true
	hp = maxf(0.0, hp - amount)
	if hp <= 0.0 and alive:
		# ★★ 将领先走「濒死」这条路：world 决定它到底是倒下去还是当场阵亡
		#    （旗下还有兵 → 濒死；一个兵都没有 → 直接死，用户拍板）。
		#    ⚠️ 判据用 `world.has_method(...)`：unit 不能 preload world（循环依赖），
		#      而测试里也真的存在「不给 world 就直接扣血」的调用。
		if is_general() and world != null and world.has_method("enter_near_death") \
				and world.enter_near_death(self):
			return alive
		_die(cfg, world, _source)
	return alive


## ★ 当场阵亡（含濒死判定失败、与「濒死期间旗下部队全灭」那一条）。
##
## ★ 为什么单独抽出来：死亡这件事现在有**三条**入口（吃到致命伤、进濒死时发现没兵、
##   濒死期间兵全死光），三条都要做同一套收尾（停手 / 计数 / 事件），
##   抄三份的话「哪次忘了 push_event」会表现成「将领没了但界面什么都没说」。
func _die(cfg: ConfigRes, world, _source = null) -> void:
	if not alive:
		return
	# ★★ 濒死 / 读条中的状态一起清掉：它们是「还活着」的附属状态，
	#    不清的话（比如在读条中被判死）会留下一个 hp=0、downed=true 的幽灵对象。
	downed = false
	nd_regen_hp = 0.0
	nd_hp_ratio = 0.0
	nd_regen_timer = 0.0
	revive_pending = false
	revive_remaining = 0.0
	revive_total = 0.0
	alive = false
	stop()
	deaths += 1
	var sec := 0.0
	if world != null and world.pvp_enabled:
		sec = maxf(0.0, cfg.respawn_sec)
	death_timer = sec
	if world != null:
		world.push_event({"type": "kill", "unit": self, "source": _source})


## 立刻死亡（对外入口：world 判定「旗下部队全灭」时调它）。
func die_now(cfg: ConfigRes, world, reason: String = "") -> void:
	if not alive:
		return
	_die(cfg, world, null)
	if world != null and reason != "":
		world.push_event({"type": "leader_lost", "unit": self, "reason": reason})


## ★★ 每帧推进「濒死」这一套状态（回复 + 全灭判定 + 再起读条）。
##
## 调用点只有一个：`logic/combat.gd` 的 `tick_frame()`（在「这一帧做什么」之前）。
## 为什么不做成 world.tick 里的另一个循环：那会让 tick 多一遍 O(单位数) 的扫描，
## 而这件事**本来就只属于将领**，挂在单位自己的每帧更新上最省。
##
## 规则（逐条对应需求）：
##   1. **再起读条**：推进剩余秒数，读完 → 脱离濒死（**血量不变**，用户拍板）；
##   2. **全灭判定**：旗下存活部队（含队列里在读条 / 排队的兵）空 → 立即死亡；
##      ⚠️ **正在读条再起时暂停**（用户拍板：「只要点击再起，就将这个将领视作是单位」）——
##      判据是显式开关 `revive_pending`，**不是** `revive_remaining > 0`（见它的说明）；
##   3. **回复**：每 `regen_sec` 秒回 `regen_ratio × hp_max`，总量封顶
##      `regen_cap_ratio × hp_max`，**只增不减**（濒死期间不吃伤害 + 基准取较大值）。
func tick_near_death(cfg: ConfigRes, world, dt: float) -> void:
	if not downed or not alive:
		return
	# ★★ 先衰减**开火特效**（本轮修 bug）：这一帧之后马上就可能 `return` 掉
	#    （读条读完 / 部队全灭），而濒死期间 `combat.update_unit` 整段不跑 ——
	#    不在这里衰减的话 `attack_flash` 会永远停在倒下那一刻的值，
	#    渲染就会一直画那条攻击线（见 `attack_flash` 的字段说明）。
	if attack_flash > 0.0:
		attack_flash = maxf(0.0, attack_flash - dt / cfg.flash_sec_safe)
	# ★★ 顺序不能反：**先推进再起读条**（这一帧读完就站起来），
	#    **再**跑全灭判定（有开关就跳过）。
	#    ⚠️ 反过来（先判全灭）会让「正在读条的最后一帧」被全灭判定抢先生效 ——
	#      用户拍板说过读条期间暂停全灭判定，那一帧正是它最该生效的时候。
	#
	# ---- 1) 再起读条 ----
	if revive_pending:
		revive_remaining = maxf(0.0, revive_remaining - dt)
		if revive_remaining <= 0.0:
			_finish_revive(world)
			return
	# ---- 2) 全灭判定（读条期间暂停 —— 开关是 `revive_pending`，不是倒计时）----
	if not revive_pending and not _has_living_retinue(world):
		die_now(cfg, world, "retinue_wiped")
		return
	# ---- 3) 缓慢回复血量（只增不减）----
	# ★ 停下条件是「已经到天花板」：进入濒死那一刻 hp 已经是 1 点（需求原文的
	#   「从 0 提升至 1」），所以这里**不能**用 `hp > 0` 当门槛 —— 那会让回复一次都不发生。
	#   ⚠️ 回复量写在 `nd_regen_hp` 上（不是 `hp += …`）：科技改 `hp_max` 时，
	#      比例对齐（`_finish_revive`）与「只增不减」的下限都要用它，
	#      见 `apply_hp_bonus` 与下面那条 `max(记账, 当前血量)` 的说明。
	#
	# ★★ 计时器初值必须是**一个完整周期**（`enter_near_death` 里按 config 设的）：
	#    设 0 的话，「<= 0 就回一次」这条判据会在**进入濒死后的第一帧**立刻兑现一次 ——
	#    实测症状是「几乎瞬间回满 1%」（3 秒周期变成 1/60 秒），
	#    而需求要的是「每 3 秒回复」。这个坑很隐蔽：它看起来像「回复调快了」，
	#    其实是初始化漏了。
	var cap: float = hp_max * cfg.revive_regen_cap_ratio
	if nd_regen_hp >= cap - 1e-9:
		return
	nd_regen_timer -= dt
	if nd_regen_timer > 0.0:
		return
	# ★★ 计时器是 `+= regen_sec` 而不是 `= regen_sec`：一帧跨过多个周期时
	#    （dt 大 / regen_sec 配得小）时间轴**不漂** —— 与招募读条那条预算算法同一套计较。
	nd_regen_timer += cfg.revive_regen_sec
	# ⚠️ 基准取 `max(记账, 当前血量)` 而不是只用记账：两者在正常情况下逐帧相等，
	#    但**任何**从别处写 `hp` 的动作（测试摆场面、以后新加的增益）都会让记账落后 ——
	#    那时「hp = 记账 + 1%」会把血量**往下压**，正好违反需求里那条「只增不减」。
	#    取较大值之后，回复永远只可能把血量抬高（这条判据是免费的，一次比较）。
	var base: float = maxf(nd_regen_hp, hp)
	nd_regen_hp = minf(cap, base + hp_max * cfg.revive_regen_ratio)
	nd_hp_ratio = nd_regen_hp / hp_max if hp_max > 0.0 else 0.0
	hp = nd_regen_hp


## 旗下**还有没有存活部队**（含队列里在读条 / 排队的兵）。
##
## ★ 口径与 `retinue_size()` 一致（= `world.retinue_of(id, true)` + 队列里的账）：
##   「排上队、还在读条」的那几个迟早会出来，它们当然算「旗下还有部队」——
##   否则会出现「将领刚倒下、因为援兵还在读条就被判死」这种最冤的死法。
func _has_living_retinue(world) -> bool:
	if world == null:
		# 没有 world（无头测试直接调）时**按还有部队处理**：宁可让它留着，
		# 也不要让「世界没传进来」表现成「将领当场暴毙」。
		return true
	if not world.retinue_of(id, true).is_empty():
		return true
	return train_queue_size() > 0


## ★★ 进入濒死（由 `world.enter_near_death()` 在确认「旗下还有部队」之后调）。
##
## 做四件事，顺序不能反：
##   1. `stop()` —— 清掉移动 / 玩家命令 / 交战（「倒在原地」= 什么都不做了）；
##      ⚠️ 必须在记 anchor **之前**调：`stop()` 只改 path / 命令，**不改 pos**，
##         所以 anchor 取到的仍然是它倒下的那一刻的位置；
##   2. 记下倒下点 `downed_anchor`（附属兵的行军目标，也是钉住的位置）；
##   3. 血量归零 → **再抬到 1 点**：需求原文「若否（仍存在部队），则该将领血量
##      从 0 提升至 1，并持续缓慢回复」。★ 回复记账（`nd_regen_hp`）从这 1 点开始，
##      于是「每 3 秒 +1% 上限」是这个 1 点**之上**的增量，总量仍然封顶 20%；
##   4. 标记 downed（此后免疫伤害、不可被选为攻击对象、不能动也不能打）。
##
## @param regen_sec 回复周期（config 的 `revive.regen_sec`，默认 3 秒）。
##        ⚠️ 必须由调用方传进来：`nd_regen_timer` 是「离下一次回复还有几秒」，
##        初值留 0 的话 `tick_near_death` 里那条「<= 0 就回一次」的判据会**在
##        进入濒死后的第一帧立刻兑现** —— 实测症状是「几乎瞬间回满 1%」
##        （3 秒周期实际变成 1/60 秒），而需求要的是「每 3 秒回复」。
##        unit 不能 preload config（会与 config 的单位类型表形成循环依赖），
##        所以这个值只能从外面给（调用方 `world.enter_near_death()`）。
func enter_near_death(regen_sec: float = 3.0) -> void:
	if not alive or downed:
		return
	stop()
	# ★★ 顺手把**攻击特效**也灭掉（本轮修 bug）：
	#   `stop()` → `clear_target()` → `drop_engagement()` 清的是 `target` / `anchor`，
	#   而**渲染攻击线读的是 `attack_flash` + `last_target`** —— 那两个字段它是故意不动的
	#   （打完一发之后线要留 flash_sec 秒才淡掉）。
	#   倒下之后整段单位逻辑被跳过 ⇒ flash 永不衰减、`last_target` 也一直指着那个人，
	#   画面上就是「濒死的将领一直和某个单位连着一条线」（实测报回来的 bug）。
	#   ★ 这一手现在收口在 `clear_attack_fx()` 里（招募开始时是同一个坑的第二个人口）。
	clear_attack_fx()
	downed_anchor = pos
	downed = true
	hp = minf(hp_max, 1.0)
	nd_regen_hp = hp
	nd_hp_ratio = hp / hp_max if hp_max > 0.0 else 0.0
	# 第一次回复发生在一个完整周期之后（见 tick_near_death 那段 ⚠️）。
	nd_regen_timer = maxf(0.01, regen_sec)
	# 刚倒下时当然没有在读条（「再起」要等血量回到 10% 才允许点）。
	revive_pending = false
	revive_remaining = 0.0
	revive_total = 0.0


## 开始「再起」读条（扣费由 `world.start_revive()` 负责 —— 这里只管状态）。
func start_revive(cfg: ConfigRes) -> void:
	revive_pending = true
	revive_total = maxf(0.0, cfg.revive_channel_sec)
	revive_remaining = revive_total
	# ★ 0 秒读条（配置成瞬发）时 `revive_remaining` 是 0，那样进度条与「还剩几秒」
	#   都会显示成 0。用一个极小正值当哨兵：下一帧 tick 立刻读完。
	if revive_remaining <= 0.0:
		revive_remaining = 1e-6
		revive_total = 1e-6


## 取消「再起」读条（回到「只是濒死」的状态；退款由 world 负责）。
## ★ 取消之后**全灭判定立刻恢复**（`revive_pending = false`）—— 这正是「退款」的代价。
func cancel_revive() -> void:
	revive_pending = false
	revive_remaining = 0.0
	revive_total = 0.0


## 读条结束 → 真正脱离濒死。
##
## ★★ **不改血量**（用户拍板：「再起时该将领血量是多少，再起后就是多少」）——
##   所以这里一个 hp 赋值都没有。脱险之后它照旧从当前这点血开始，
##   靠己方领地的缓慢回血（combat.gd 那一条）慢慢恢复。
func _finish_revive(world) -> void:
	downed = false
	revive_pending = false
	revive_remaining = 0.0
	revive_total = 0.0
	# ★★ 站起来这一刻要把「濒死期间科技改过的血量上限」对齐一次：
	#    濒死期间 `apply_hp_bonus()` **只改上限、不动当前血量**（那是为了守住
	#    「回复期间只增不减」），所以按上限重算当前血量的那一步挪到了这里 ——
	#    比例仍然取 `nd_hp_ratio`（= 回复到哪一档），于是「上限涨了、占比不变」照旧成立。
	if hp_max > 0.0 and nd_hp_ratio > 0.0:
		hp = clampf(hp_max * nd_hp_ratio, 1.0, hp_max)
	nd_regen_hp = 0.0
	nd_hp_ratio = 0.0
	nd_regen_timer = 0.0
	# ★ 满血 / 0 血的边界：读条期间不会掉血，所以这里 hp 至少是 1%（或 0 血那 1 点）。
	#   仍然兜一下：万一 hp 是 0（0 秒读条 + 还没回过血），给它 1 点，
	#   否则它会以一个「0 血但活着」的状态回到战场（下一次挨打立刻又濒死）。
	if hp <= 0.0:
		hp = minf(hp_max, 1.0)
	# 交战的余数清掉：刚站起来不该继承倒下前的追击路径（那些路径是给「倒下点」的）。
	clear_target()
	attack_cd = 0.0
	# ★ 再战冷却：站起来那一下附近往往还有敌人，用驻防将领那条冷却挡住
	#   「一睁眼就被同一个敌人再锁一次」（见 retarget_cd 的说明）。
	retarget_cd = maxf(retarget_cd, 1.0)
	if world != null:
		world.push_event({"type": "leader_revived", "unit": self})



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


# ------------------------------------------------------------------
# 科技：血量倍率（见 logic/tech.gd 与 world._apply_tech_effects）
# ------------------------------------------------------------------

## ★★ 施加「将领血量 +10%」这类科技倍率（**粘性**：倍率没变就什么都不做）。
##
## 玩家确认的口径：加成作为**倍率实时生效** —— 已存在的将领也一起提升，
## 弃用之后回到 1.0。
##
## 为什么必须粘性（`tech_hp_mult` 记住上一次的值）：
##   倍率变了要**按比例缩放当前血量**（一块半血的血条在 +10% 之后仍然是半血），
##   而「按比例」这件事只有在「知道上一次乘的是几」时才做得对。
##   不记的话，`hp *= mult` 每调一次就再乘一次 —— 半血的兵会越乘越满。
##
## ⚠️ 血量为 0 / 单位不在场时不缩放（分母没有意义，复活时会走 `hp = hp_max`）。
##
## ★★ 濒死将领（本轮新增）：**只改上限，当前血量与回复记账一概不动** ——
##   那是「回复期间血量只增不减」这条需求在代码里的落点（见下面那段 ⚠️⚠️）。
##   比例存在 `nd_hp_ratio` 里，站起来那一刻（`_finish_revive`）才按它把当前血量对齐，
##   于是「上限涨了、占比不变」（用户拍板）在**能安全对齐的时刻**成立。
##
## ⚠️⚠️ 为什么濒死期间一律不许改 `hp`（实测踩到的真 bug）：
##    `world._apply_tech_effects()` 会遍历所有单位调这个函数，而它算的是
##    「按比例缩放当前血量」—— 对濒死者来说，那等于**把回复出来的血覆盖掉**
##    （实测：本应 16.5 血的濒死将领被压回 2.1，正是需求里禁止的「血量下降」）。
func apply_hp_bonus(mult: float) -> void:
	var m: float = maxf(0.01, mult)
	if absf(m - tech_hp_mult) < 1e-9:
		return
	tech_hp_mult = m
	if base_hp_max <= 0.0:
		return
	# ★ 上限**从基础值重新算**（`base_hp_max × 倍率`），不是在旧上限上再乘一次 ——
	#   见 `base_hp_max` 的说明（弃用之后要能精确回到原值）。
	if downed:
		hp_max = base_hp_max * m
		return
	var ratio: float = 1.0
	if hp_max > 0.0:
		ratio = clampf(hp / hp_max, 0.0, 1.0)
	hp_max = base_hp_max * m
	hp = hp_max * ratio

