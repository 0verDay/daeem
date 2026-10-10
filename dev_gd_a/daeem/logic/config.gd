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
## ★ 与地图目录有关的常量**只有一个源头**（`logic/map_library.gd` 的 MAPS_DIR /
##   FALLBACK_MAP_PATH）：默认地图路径就是它给的兜底值，这里不重复写字符串字面量。
const MapLibraryRes = preload("res://logic/map_library.gd")

const DEFAULT_CONFIG_PATH := "res://data/config.json"
## ★ 默认地图：`data/maps/<id>/map.json` 里的那一张（一个地图一个目录）。
## ⚠️ 开场主界面那条**地图选择条**用的是 `logic/map_library.gd` 扫出来的结果
##    （几张图就有几个选项），这里的常量只是**没有地图目录时**的兜底
##    —— 加地图不用改这一行，往 data/maps/ 下放个新目录就行。
const DEFAULT_MAP_PATH := MapLibraryRes.FALLBACK_MAP_PATH

## 缓存 JSON 的字典形式（阵营 id → 字典 / 颜色名 → 字典 这类查找用得着）
var data: Dictionary = {}

## ---- 常用标量（载入时算好，避免逻辑层到处 `num("...")`）----
## ⚠️ cell_px 是**全项目唯一允许存在的像素常量**，而且它只该被 view/ 读
##    （palette.to_px / tile_rect / unit_radius_px）。logic/ 里出现它 = 坐标单位混用的信号。
##    它放在这里而不是 view/，只是为了让所有可调数值集中在同一个 JSON 里。
var cell_px: float = 128.0

## ---- ★★ 斜俯视真透视（见 config.json 的 render._comment）----
## ★★ 世界空间：逻辑格 (x, y) → 地面点 (x·cell_px, **0**, y·cell_px)。
##    也就是「世界是一块水平地面，格是地面上的方格」，镜头在斜上方俯视。
##    投影 = 视图矩阵 + 透视除法 ⇒ **近大远小**（参考图里墙呈梯形的唯一来源）。
##    logic/ 依然完全不知道这件事：单位位置、半径、射程、寻路全都还是「格」。
## ⚠️ 这些是**渲染常量**（与 cell_px 同性质），而且出现在每格每帧的内层循环里，
##    必须走 _cache_scalars() 算好，不许用 cfg.num("render.camera_pitch_deg")。
var cam_pitch: float = 0.0        # 俯角（弧度）
var cam_height: float = 4000.0    # 镜头离地面高度（世界像素）
var cam_fov: float = 0.0          # 竖直视场角（弧度）
## 投影因子（`to_px` 内层循环直接用）：
##   u = x / (A + y·B)   v = y / (A + y·B)     —— A、B 只跟 pitch / height / fov / 视口高有关
##   推导：相机在 (0, H·cosθ, −H·sinθ) 朝原点俯视 θ；地面点 (x, 0, y) 经视图矩阵后
##         z_cam = (A + y·B)，透视除法后 ndc_x = x / (z_cam·aspect·tan(fov/2))，ndc_y = −(v−1)
##   于是屏幕像素 = (u·vp_w, v·vp_h)，其中视口比已并入 A。
var proj_a: float = 1.0
var proj_b: float = 0.0
## 视口尺寸（投影的 ndc → 像素这一步用它；由 view 层在 setup 时喂进来）
var proj_vp_w: float = 1920.0
var proj_vp_h: float = 1080.0
## 并入量（palette 做乘加时读它们，见 `_recompute_projection`）
var proj_tan_half: float = 1.0
var proj_aspect: float = 1.0
var proj_vp_half: Vector2 = Vector2(960.0, 540.0)
## 「相机在地面上的那一点」对应的竖直像素量（= H·cosθ）——
## ★ 它决定**格 y = 0 那条线落在屏幕哪里**：为了让地面中心落在视口中心，
##   palette.to_px 里减掉它（否则整张地图会整体偏上或偏下）。
var proj_zero_y: float = 0.0
## ★★ 投影后的**整体平移**（屏幕像素）——「让地图居中」用它。
##
## 为什么需要它：上面的推导把「格 y = 0」放在**视口中心**，于是整张地图
##   （格 y ∈ [0, rows]）会整体落在屏幕**下半部分**（实测：22 行的图落在 y ≈ 1500~2400，
##   而视口只有 1080 高 ⇒ 地图整个在屏幕外面，单位全被剔除）。
##   修法不是改投影公式，而是**平移投影结果**：`proj_offset = 视口中心 − 地图中心`。
##   game_scene 在开局算一次；测试要自己设（见 tests/test_case.gd 的 setup_projection）。
var proj_offset: Vector2 = Vector2.ZERO
## 建筑与单位按「脚下 Y」排前后（关掉 = 平铺层级，用来二分定位问题）
var depth_sort: bool = true
## 字 / 血条 / 选中光晕 / 地面标记**不被投影压扁**（屏幕 1:1）
var ui_compensate: bool = true

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

## ---- ★★ 战争迷雾（config.json 的 fog 段 + unit.types.<id>.vision）----
##
## 迷雾**只作用于显示**（见 logic/fog.gd）：这几个数不进任何玩法判定，
## 所以它们不在「每帧每单位」的热路径上，但仍然按同一条规矩在载入时算好。
##
##   · fog_enabled        —— 总开关（关掉 = 回到「全图可见」，行为与加迷雾之前一致）；
##   · fog_vision_default —— `unit.types.<id>` 没写 vision 时用它的**单位**视野半径（格）；
##   · fog_vision_building—— `building.<type>` 没写 vision 时用它的**建筑**视野半径（格）。
##     ★ 这两条是**对称的两个兜底**：单位一个、建筑一个。真正生效的值优先取各自
##       类型表里那个键（`cfg.unit_vision_of()` / `cfg.building_vision_of()`）。
##   · fog_mask_color / fog_mask_alpha —— 灰色遮罩的样子（纯显示）。
var fog_enabled: bool = true
var fog_vision_default: float = 8.0
var fog_vision_building: float = 9.0
var fog_mask_color: Color = Color(0.0, 0.0, 0.0, 0.45)

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

## ---- 阵型分层：兵种「由前往后」的层次序（见 config.json 的 _tier_comment）----
## 值越小越靠前。没登记的兵种取 formation_tier_default（默认 = 中间层）。
var formation_tier_order: Dictionary = {}
var formation_tier_default: int = 1

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
## ★★ 将领的**数值覆盖**（本轮新增，config.json 的 `unit.general.stats`）。
##   `_general_stats[i]` = 第 i 位将领写了的键（空字典 = 完全跟随所属兵种）；
##   `_general_names[i]` = 它的显示名覆盖（空字符串 = 没写）；
##   `_general_combat[i]` = 预拼好的战斗字典（没覆盖的那几位**共享**兵种那一份）。
var _general_stats: Array = []
var _general_names: Array = []
var _general_combat: Array = []
## ★★ 每位将领的**编制上限**（config.json 的 `unit.general.caps`，与 types 同序）。
##   它是「目标编队规模」：摆放的将领开局生成到它、阵地 AI 脱战补到它、
##   红点将领的附属兵数也以它封顶（见 logic/expr.gd 与 tools/unit_editor）。
##   ★ 缺省 / 越界一律 11（与界面那个常量 UNIT_CAP 同值，但两者暂时各自独立）。
var _general_caps: Array = []
## 单位类型 id → 地图上显示的那**一个字**（config 的 `unit.types.<id>.icon`）。
## ★ 空串 = 配置里没写（`unit_icon_of` 退成名字的第一个字）。
## ★★ 它是**数据**而不是美术：设计师在单位编辑器里给每个兵种挑一个字，
##    新加的兵种也就有了自己的样子（见 view/unit_icon.gd 的文件头）。
var _unit_icons: Dictionary = {}
## ★★ 单位类型 id → 3D 立牌的**素材路径**（config 的 `unit.types.<id>.sprite`）。
## ★ 空串 = 配置里没写 → 渲染层退回程序化剪影（见 view/unit_sprite_3d.gd 的 bake）。
## ★ 与 `_unit_icons` 同一口径：**数据**而不是代码里的字面量，加兵种只改 JSON。
var _unit_sprites: Dictionary = {}
## ★★ 开局**没有**任何「每位将领带几个兵」的全局缺省（本轮口径变更）。
##
## 原先是 `unit.general.escort`（一个数或一个数组）+ `general_escort_count()` /
## `general_escort_at(index)` 两个读法。**整条已删除**，理由是「所见即所得」：
##   开局场上有多少兵，必须**完全等于**关卡 `start_units[]` 里摆出来的那些。
## 于是：
##   · 编制不再来自 config，而是**关卡 `start_units[].escort_of`**（逐兵一个坐标，
##     `escort_of` = 归属将领序号，1 起，与 `general_index` 同规）；
##   · 关卡没摆 ⇒ 将领开局**光杆**（0 个附属兵），绝不补任何缺省；
##   · 运行时唯一的读法是 `Level.escort_leader_index()` ⊕ `world.escort_target_of()`。
## ⚠️ 所以这里**故意不再留**任何 escort 字段与查询函数 ——
##    留一个「全局缺省」就等于又给了第二条真相来源，正是本轮要拆掉的东西。
## 查不到类型时的兜底战斗数值（= 第一个将领类型，也就是长枪兵那一档）。
## ★ 为什么兜底是长枪兵而不是测试敌人：本项目踩过「二元判断（是将领吗？不是就当敌人）
##   把新加的类型静默当成测试敌人」这个坑（见 docs/pitfalls.md 5.x）——
##   兜底落在敌人身上就会让「漏配一个类型」表现为「它变成了 60 血」。
var _combat_fallback: Dictionary = {"damage": 10.0, "range": 1.0, "cooldown_sec": 1.2}

## 战斗数值表：**载入时建好、之后只读**（原先每次 unit_combat_of() 都新建一个字典）
var combat_enabled: bool = true
var aggro_range: float = 4.0
var leash_factor: float = 1.8
## ★★ 因为追击上限（leash）放弃之后，多久**不许再自动锁定单位**（秒）。
##
## 为什么必须有它（实测报回来的 bug：单位在区划边界「原地抽搐」）：
##   放弃那一下只清 `target`，而目标**还在警戒半径里** —— 下一帧 `acquire_target`
##   立刻又把它锁上，而锁定那一刻 `anchor` 就是当前位置（距离 0，判据必然通过）
##   ⇒ 再走一格又超上限、又放弃 …… 一帧一放一锁 = 原地抽搐。
##   冷却期内它只待命，抖动的回路就断了。
## ⚠️ 只挡**自动索敌**：玩家点名的目标、行军攻击继续走、拆建筑都不受影响。
var leash_release_cd: float = 0.5
## ★★ 濒死救援期间的警戒半径倍率（本次修 bug 新增；见 `combat.acquire_target`）。
## 赶去救倒下的队长时警戒半径缩到 `aggro_range × 这个值`，
## 免得路过的敌人把援军拽进追击、把救援集结令吃掉。0 = 完全不还手，1 = 与平时一样。
var rescue_aggro_mult: float = 0.4
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
## ★★ 受击动效（闪白 + 左右振动）的时长（秒）——见 combat.hit_flash_sec。
var hit_flash_sec: float = 0.18
## 预计算：受击衰减那句在「每单位每帧」的路径上，别每次算 maxf(0.01, ...)。
var hit_flash_sec_safe: float = 0.18
var building_damage: float = 40.0
## ★★ 射箭投掷物（远程单位 / 可攻击建筑）的飞行速度与时长夹取（见 logic/projectile.gd）。
## ★ 预计算进字段：它们在「每枚投掷物每帧」的路径上，不许用 `cfg.num("combat....")`。
var projectile_speed: float = 12.0
var projectile_min_sec: float = 0.08
var projectile_max_sec: float = 0.6
## ★★ 「测试敌人」的那几个数值字段（enemy_damage / enemy_range / enemy_cooldown /
##    enemy_speed / enemy_hp）**本次随单位类型一起删除**（用户口径：「把所有的『敌』
##    这个具体单位变成『长枪兵』」）。
##    它们原本只是 `unit.types.enemy` 那一档的「另一个名字」，现在没有那一档了，
##    留着只会让人以为「还有一个敌人类型可以调」。调试刷兵现在刷**长枪兵**，
##    数值一律走 `unit.types.spearman`（读法：`cfg.unit_hp_of(UNIT_TYPE_SPEARMAN)`）。

var zone_cols: int = 6
var zone_rows: int = 4
## 1 个单位独自占下一个区块要多少秒（= 占领速率 1/capture_time_sec 的倒数）。
## 历史：4 → 32（需求「占领速度缩小为原来的 1/8」）。
var capture_time_sec: float = 32.0
## 读条方**不在场**时，进度每秒回落多少（进度比例/秒）。
## 历史：0.125 → 0.03125（需求「自然占领进度降低速度缩小为原来的 1/4」）。
## ⚠️ 与 capture_time_sec 的缩放倍数不同（1/4 vs 1/8），别顺手改成一样。
var decay_per_sec: float = 0.03125
## ★★ 占领半径（格）：**单位必须离区划中心的切比雪夫距离 ≤ 它**才算「在场」。
##   1 ⇒ 3×3（中心格 + 周围 8 格，即需求里的「3x3」）；0 ⇒ 只有中心格本身。
##   ⚠️ 中心格上通常立着「区划中心」那栋中立障碍 ⇒ 实际能站的是周围那 8 格。
##   它同时管**读条方是谁 / 主人是否在场挡人 / 人走后进度回落**三处判定（同一口径）。
var zone_capture_radius_tiles: int = 1
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

## ---- ★★ 将领**濒死保护**（config.json 的 revive 段；规则见 logic/unit.gd / world.gd）----
##
## 六个数各管一件事，全部在 config 里可调（用户要求「消耗写 config，可调」）：
##   · `revive_cost`        —— 「再起」要花的粮食 / 黄金（入队即扣，取消全额退）；
##   · `revive_channel_sec` —— 「再起」的读条秒数（0 = 瞬发）；
##   · `revive_ready_ratio` —— 血量到上限的这个比例才允许再起（= 10%）；
##   · `revive_regen_sec` / `revive_regen_ratio` —— 每几秒回上限的百分之几（= 每 3 秒 1%）；
##   · `revive_regen_cap_ratio` —— 自然回复的天花板（= 上限的 20%）。
##
## ★ 为什么整段在载入时算好：这些数在**每帧每濒死将领**的路径上（回复计时），
##   而且 UI 悬停 / 拒因文案也要读同一份 —— 与 unit_hp_max / aggro_range 同一条规矩，
##   不在调用点重下潜一次 JSON（那样两处口径一定会漂）。
var revive_cost: Dictionary = {}
var revive_channel_sec: float = 0.0
var revive_ready_ratio: float = 0.1
var revive_regen_sec: float = 3.0
var revive_regen_ratio: float = 0.01
var revive_regen_cap_ratio: float = 0.2

## 一帧最多按多少秒推进逻辑（防止「帧慢→dt 大→活更多→更慢」的死亡螺旋）
var sim_max_dt: float = 0.05


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

	# ★★ 斜俯视真透视（见字段声明处的注释）：
	#   · pitch 夹在 [5°, 90°]：90 = 正俯视（proj_b 趋 0 ⇒ 退化成仿射），太小则地平线进画面；
	#   · height / fov 只影响「一格占屏幕多大」，不影响逻辑。
	cam_pitch = deg_to_rad(clampf(num("render.camera_pitch_deg", 55.0), 5.0, 89.0))
	cam_height = maxf(1.0, num("render.camera_distance", 3600.0))
	cam_fov = deg_to_rad(clampf(num("render.camera_fov_deg", 40.0), 5.0, 120.0))
	_recompute_projection()
	depth_sort = bool_val("render.depth_sort", true)
	ui_compensate = bool_val("render.ui_compensate", true)

	# ---- ⚠️ 以下这一段原本就在 `_cache_scalars()` 里 ----
	#   ★ 一次大段替换曾把它与函数头切断，症状是
	#     `Parse Error: Could not preload resource script "res://logic/config.gd"`
	#     —— 它是全工程的依赖，一旦解析失败**所有**测试文件都变成 "Compilation failed"。
	#     教训：改动长函数时，替换块的两端要落在**函数边界**上，别停在函数体中间。
	camera_edge_size = num("camera.edge_size", 44.0)
	drag_select_min_px = num("ui.drag_select_min_px", 6.0)
	minimap_drag_min_px = num("minimap.drag_min_px", 4.0)
	minimap_drag_hold_sec = num("minimap.drag_hold_sec", 0.18)

	unit_speed = num("unit.speed", 0.6)
	unit_forest_mult = num("unit.forest_mult", 0.5)
	unit_hp_max = num("unit.hp_max", 200.0)
	unit_radius_factor = num("unit.radius_factor", 0.1)

	# ★ 迷雾：开关 / 兜底视野 / 遮罩颜色（颜色走 parse_color，与 colors.* 同一套写法）
	fog_enabled = bool_val("fog.enabled", true)
	fog_vision_default = maxf(0.0, num("fog.vision_default", 8.0))
	fog_vision_building = maxf(0.0, num("fog.vision_building", 9.0))
	fog_mask_color = parse_color(str_val("fog.mask_color", "#000000"))
	fog_mask_color.a = clampf(num("fog.mask_alpha", 0.45), 0.0, 1.0)

	unit_collision_enabled = bool_val("unit.collision_enabled", true)
	unit_collision_backend = str_val("unit.collision_backend", "csharp")
	unit_collision_radius = num("unit.collision_radius", 0.18)
	unit_overlap_allowance = num("unit.overlap_allowance", 0.7)
	unit_collision_iterations = int_val("unit.collision_iterations", 3)
	unit_collision_slack = num("unit.collision_slack", 0.01)
	unit_push_moving_weight = num("unit.push_moving_weight", 1.0)
	unit_push_idle_weight = num("unit.push_idle_weight", 0.2)

	unit_jam_giveup_sec = num("unit.jam_giveup_sec", 2.4)
	# ★★ 必须**明显大于碰撞一次能推开多少**（平衡时约 0.22~0.23 格），否则每帧都触发回位、
	#    两个单位点同一个点时来回挤很久（见 config.json 的 _settle_comment）。
	unit_settle_return_dist = num("unit.settle_return_dist", 0.5)
	unit_settle_max_attempts = int_val("unit.settle_max_attempts", 3)

	formation_min_units = int_val("unit.formation.min_units", 4)
	formation_spacing_scale = num("unit.formation.spacing_scale", 1.15)
	formation_aspect = maxf(1.0, num("unit.formation.aspect", 1.6))
	formation_max_slots = int_val("unit.formation.max_slots", 400)
	formation_tier_order = _load_tier_order()
	formation_tier_default = int_val("unit.formation.tier_default", 1)

	path_diagonal = bool_val("path.diagonal", true)
	path_diagonal_corner_cut = bool_val("path.diagonal_corner_cut", false)
	path_building_penalty = num("path.building_penalty", 12.0)
	path_corner_round_enabled = bool_val("path.corner_round_enabled", true)
	path_corner_round_cutting = num("path.corner_round_cutting", 0.35)
	path_corner_round_min_angle_deg = num("path.corner_round_min_angle_deg", 20.0)

	combat_enabled = bool_val("combat.enabled", true)
	aggro_range = num("combat.aggro_range", 4.0)
	leash_factor = num("combat.leash_factor", 1.8)
	leash_release_cd = maxf(0.0, num("combat.leash_release_cd", 0.5))
	rescue_aggro_mult = clampf(num("combat.rescue_aggro_mult", 0.4), 0.0, 1.0)
	repath_sec = num("combat.repath_sec", 0.3)
	repath_min_move = num("combat.repath_min_move", 0.5)
	chase_direct_range = num("combat.chase_direct_range", 8.0)
	flash_sec = num("combat.flash_sec", 0.22)
	flash_sec_safe = maxf(0.01, flash_sec)
	hit_flash_sec = maxf(0.01, num("combat.hit_flash_sec", 0.18))
	hit_flash_sec_safe = maxf(0.01, hit_flash_sec)
	building_damage = num("combat.building_damage", 40.0)
	# ★★ 投掷物飞行（见 logic/projectile.gd）。速度必须 > 0，否则时长会除零；
	#   时长的上下夹取保证「贴脸也看得见飞一下」且「远距离不飞太久」。
	projectile_speed = maxf(0.1, num("combat.projectile_speed", 12.0))
	projectile_min_sec = maxf(0.0, num("combat.projectile_min_sec", 0.08))
	projectile_max_sec = maxf(projectile_min_sec + 0.001, num("combat.projectile_max_sec", 0.6))

	zone_cols = int_val("zone.zone_cols", 6)
	zone_rows = int_val("zone.zone_rows", 4)
	capture_time_sec = num("zone.capture_time_sec", 32.0)
	decay_per_sec = num("zone.decay_per_sec", 0.03125)
	# ★ 占领半径（格）：负数当 0（只认中心格），保证 `update()` 里的邻域循环合法。
	zone_capture_radius_tiles = maxi(0, int_val("zone.capture_radius_tiles", 1))
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

	# ★★ 将领濒死保护（见上面那组字段的说明）。cost 走与招募 / 升级同一套形状
	#    （{"food":…, "gold":…}），所以 EconomyRes.can_afford / spend 直接就能用。
	revive_cost = _read_cost("revive.cost")
	revive_channel_sec = maxf(0.0, num("revive.channel_sec", 5.0))
	# ⚠️ `ready_ratio` 夹到 (0, 1]：写成 0 会让「0 血就能再起」（绕开需求里的 10% 门槛），
	#    写成负数更没意义。上限 1.0 = 必须回满才让再起。
	revive_ready_ratio = clampf(num("revive.ready_ratio", 0.1), 0.0001, 1.0)
	revive_regen_sec = maxf(0.01, num("revive.regen_sec", 3.0))
	revive_regen_ratio = maxf(0.0, num("revive.regen_ratio", 0.01))
	# 天花板至少得够得着门槛，否则「再起」永远点不亮（配错数据时给一条活路：
	# 取两者的较大值，而不是让玩家面对一颗永远灰着的格子）。
	revive_regen_cap_ratio = clampf(
		maxf(num("revive.regen_cap_ratio", 0.2), revive_ready_ratio), 0.0, 1.0)

	_cache_techs()
	_cache_upgrades()
	_cache_zone_kinds()
	_cache_zone_specs()
	# ★ AI（本轮新增）：阵营 AI 的名单 + 两种 AI 的行为参数（见 _cache_ai）。
	_cache_ai()
	# ★★ 单位类型表（unit.types / unit.classes / unit.general）—— 必须在其它
	#   单位字段之后调：它拿 unit_speed / unit_hp_max / unit_radius_factor 当兜底值。
	_cache_unit_types()


## 视口尺寸变了就重算投影常数（view 层在 setup 时喂一次；窗口拉伸时再喂一次）。
func set_viewport_size(w: float, h: float) -> void:
	proj_vp_w = maxf(1.0, w)
	proj_vp_h = maxf(1.0, h)
	_recompute_projection()


## 重算投影常数 —— **透视投影的唯一出处**（palette 只读这几个数）。
##
## 推导（相机在 (0, H·cosθ, +H·sinθ) 朝 −z 方向俯视 θ，地面是 y = 0）：
##   地面点 P = (x, 0, y) 经视图矩阵（先平移 −cam，再绕 X 轴转）后：
##       x_cam = x
##       z_cam = H·sinθ − y·cosθ        （相机前方为正；格 y 越大离镜头**越近**）
##   透视除法（竖直视场角 + 宽高比）：
##       ndc_x = x_cam / (z_cam · aspect · tan(fov/2))
##       ndc_y = (H·cosθ + y·sinθ) / (z_cam · tan(fov/2))
##   屏幕像素：屏幕.x = vp_w/2·(1 + ndc_x)、屏幕.y = vp_h/2·(1 + ndc_y)
##
## ⚠️ 这一处是全项目「近大远小」的**唯一**来源：改 pitch / height / fov 只改这里，
##    palette 的 to_px / to_logic 只是把它写成乘加与它的逆。
func _recompute_projection() -> void:
	proj_tan_half = tan(cam_fov * 0.5)
	proj_aspect = proj_vp_w / maxf(1.0, proj_vp_h)
	proj_vp_half = Vector2(proj_vp_w * 0.5, proj_vp_h * 0.5)
	# A、B：深度 d = A + y_px·B（y_px = 格 y × cell_px）。
	# ★★ 符号是**这一档最容易搞反的地方**（实测反过一次：近处格子反而更小）：
	#    镜头在「地面 +z 那一侧」朝 −z 看 ⇒ 格 y 越大（越靠屏幕下方）离镜头**越近**，
	#    所以深度里那一项必须是 **− y·cosθ**。
	proj_a = cam_height * sin(cam_pitch)
	proj_b = -cos(cam_pitch)
	# 「相机看向地面上哪一点」的竖直量：格 y = 0 那条线要在视口中心
	#   ⇒ 屏幕 y 的分子里保留 + y_px·sinθ（与 proj_b 的符号配套，见 palette.to_px）
	proj_zero_y = cam_height * cos(cam_pitch)


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
#   4. 三个开局将领各是什么类型、叫什么名字（general_type_at / general_name_at）。
#      ⚠️ 「各带几个兵」**不在这一层**（本轮口径变更）：开局附属兵完全由关卡的
#         `start_units[].escort_of` 摆放决定，config 里没有任何缺省（见上面那段说明）。
# ⚠️ 表里查不到的 kind 一律**退回兜底值**（而不是当成测试敌人）：手写地图里写错一个
#   kind 不该让那个单位变成 60 血的敌人 —— 那正是本项目踩过的坑（见 _combat_fallback）。
# ------------------------------------------------------------------

## 载入时整理单位类型表（**只读**，之后别再改它）。
func _cache_unit_types() -> void:
	_unit_types = {}
	_unit_classes = {}
	_general_types = []
	_unit_sprites = {}

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
				# ★ 视野半径（格）：战争迷雾用。没写 → fog.vision_default。
				"vision": maxf(0.0, float(td.get("vision", fog_vision_default))),
				"combat": {
					"damage": maxf(0.0, float(td.get("damage", 0.0))),
					"range": maxf(0.0, float(td.get("range", 1.0))),
					"cooldown_sec": maxf(0.01, float(td.get("cooldown_sec", 1.0))),
				},
			}
			# 地图上那个字：没写这个键就是空串（`unit_icon_of` 会退成名字的第一个字）
			_unit_icons[id] = String(td.get("icon", ""))
			# 3D 立牌素材路径：没写就是空串（渲染层退回程序化剪影）
			_unit_sprites[id] = String(td.get("sprite", ""))

	# 3) 开局将领（general_N 同序）各自的类型
	var types: Variant = get_path_value("unit.general.types")
	if typeof(types) == TYPE_ARRAY:
		for item in (types as Array):
			var sid := String(item)
			if _unit_types.has(sid):
				_general_types.append(sid)
	if _general_types.is_empty() and _unit_types.has(UNIT_TYPE_SPEARMAN):
		_general_types.append(UNIT_TYPE_SPEARMAN)

	# 3.2) ★★ 每位将领的**编制上限**（config.json 的 `unit.general.caps`，本轮新增）。
	#   与 types 同序；缺省 / 越界在 `general_cap_at()` 里统一退到 11。
	_general_caps = []
	var caps_raw: Variant = get_path_value("unit.general.caps")
	if typeof(caps_raw) == TYPE_ARRAY:
		for item in (caps_raw as Array):
			if typeof(item) == TYPE_INT or typeof(item) == TYPE_FLOAT:
				_general_caps.append(maxi(0, int(item)))

	# ⚠️ 这里**不再读** `unit.general.escort`：本轮把「全局开局编制」整个删掉了
	#    （开局有几个附属兵 = 关卡 `start_units[].escort_of` 摆了几个，
	#     见本文件上面那段说明与 `Level.escort_leader_index()`）。
	# ★ 于是 `config.json` 里**残留**的 `escort` 键会被**静默忽略**：`get_path_value()`
	#   只在**主动查**某个路径时才看它，没人查的键等于不存在，不会报错、也不会警告。
	#   这一条是有意的 —— 另一路 agent 正在改 config 与单位编辑器，两边不必同步落地。

	# 3.5) ★★ 将领的**数值覆盖**（config.json 的 `unit.general.stats`，本轮新增；
	#      editor：tools/unit_editor 的「单位」页 → 将领）。
	#   · 下标 = 将领序号（与 types 同序）；`general` 与 `general_N` 共用同一个槽位
	#     （general_index_of 那套规则），所以开局那三位与区划招募出来的对得上。
	#   · **没写的键 = 跟随所属兵种** —— 空字典 `{}` 就是「完全等于那一档兵种」，
	#     与加这张表之前的行为逐位一致。
	#   ⚠️ 覆盖只认数字键与 name：别的键（写错了 / 将来加的）在这里就被丢掉，
	#      免得 `stat_overrides.get("damage")` 拿到一个字符串。
	_general_stats = []
	_general_names = []
	var stats_raw: Variant = get_path_value("unit.general.stats")
	if typeof(stats_raw) == TYPE_ARRAY:
		for item in (stats_raw as Array):
			var ov: Dictionary = {}
			var nm := ""
			if typeof(item) == TYPE_DICTIONARY:
				var d: Dictionary = item
				for key in ["hp_max", "speed", "damage", "range", "cooldown_sec", "vision"]:
					var v: Variant = d.get(key, null)
					if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
						ov[key] = float(v)
				if typeof(d.get("name", null)) == TYPE_STRING:
					nm = String(d["name"])
			_general_stats.append(ov)
			_general_names.append(nm)

	# 4) 兜底值（来自同一张表，不再是第二份配置）
	#
	# ★★ 本次删除：原来这里还有一段「把 unit.types.enemy 抄进 enemy_hp / enemy_speed /
	#    enemy_damage 那几个兼容字段」—— 随着「敌」这个单位类型被删除（用户口径：
	#    「把所有的『敌』这个具体单位变成『长枪兵』」），那几个字段也一起没了。
	#    调试刷兵现在用长枪兵，读法就是 `cfg.unit_hp_of(UNIT_TYPE_SPEARMAN)`。
	var fb: Variant = _unit_types.get(String(_general_types[0]), null) if not _general_types.is_empty() else null
	if typeof(fb) == TYPE_DICTIONARY:
		_combat_fallback = (fb as Dictionary)["combat"]

	# 5) ★ 每位将领预拼一份 combat 字典：`unit_combat_of()` 的契约是「返回**共享的只读字典**」
	#    （每帧每单位都要读，不新建），所以覆盖也要在载入时拼好。
	#    没覆盖的那几位**直接共享所属兵种那一份** —— 一个字典都不多建。
	_general_combat = []
	for i in _general_types.size():
		var ov: Dictionary = _general_stats[i] if i < _general_stats.size() else {}
		var tid := String(_general_types[i])
		var base: Dictionary = _combat_fallback
		if _unit_types.has(tid):
			base = (_unit_types[tid] as Dictionary)["combat"]
		if ov.has("damage") or ov.has("range") or ov.has("cooldown_sec"):
			_general_combat.append({
				"damage": float(ov.get("damage", base["damage"])),
				"range": float(ov.get("range", base["range"])),
				"cooldown_sec": float(ov.get("cooldown_sec", base["cooldown_sec"])),
			})
		else:
			_general_combat.append(base)


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


## ★★ 宽松读一份「权重条目表」：每项保留它自己的标识键（附属单位用 `type`、
##   将领类型用 `general`），并把 `weight` 归一成**非负 float**；坏项直接丢掉。
##
## ★ 为什么放在这里当**静态**工具：config 的 `ai.reddot.general_weights` /
##   `ai.reddot.escort_types` 与关卡 `start_units[].escort_types` 是**同一种形状**，
##   读法必须只有一份（否则「权重怎么算合法」会在两处慢慢漂开）。
##
## @return Array，每项 `{<原标识键>: ..., "weight": float}`（`weight` 一定存在）
static func normalize_weight_list(v: Variant) -> Array:
	var out: Array = []
	if typeof(v) != TYPE_ARRAY:
		return out
	for item in (v as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = item
		var w: Variant = d.get("weight", null)
		if typeof(w) != TYPE_INT and typeof(w) != TYPE_FLOAT:
			continue
		var e: Dictionary = d.duplicate(true)
		e["weight"] = maxf(0.0, float(w))
		out.append(e)
	return out


## ★★ 权重表里各项 `weight` 的和（编辑器校验「必须为 1」用；运行时用它做归一化分母）。
static func weight_total(entries: Array) -> float:
	var total := 0.0
	for e in entries:
		if typeof(e) == TYPE_DICTIONARY:
			total += float((e as Dictionary).get("weight", 0.0))
	return total


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


## ★★ 第 i 位将领（0 起）的**编制上限**（config.json 的 `unit.general.caps`）。
##   缺省 / 越界一律 **11**（与界面常量 UNIT_CAP 同值）。
##   ★ 累积 11 这个数是手玩定的：见 view/ui_layout.gd 的 UNIT_CAP 注释。
const GENERAL_CAP_DEFAULT := 11

func general_cap_at(i: int) -> int:
	if i < 0 or i >= _general_caps.size():
		return GENERAL_CAP_DEFAULT
	return int(_general_caps[i])


## ⚠️ 这里原先还有两个「开局编制」的读法（本轮**整个删掉**）：
##   · `general_escort_count()`     —— `unit.general.escort` 的第一个值；
##   · `general_escort_at(index)`   —— 逐将那一份（下标越界按长度循环）。
## 新口径下**没有任何全局缺省**：开局有几个附属兵完全等于关卡 `start_units[]` 里
## 摆了几个（`escort_of` 指向哪位将领）。要问「这位将领的目标编制」请用
## `world.escort_target_of(fid, general_index)`。
## ★ 不保留「读不到就返回 0」的兼容函数是**有意的**：留一个恒 0 的接口会让
##   调用点看起来还在工作，而这个接口存在的意义已经没有了（见文件上方那段说明）。


# ------------------------------------------------------------------
# 将领的数值覆盖（config.json 的 unit.general.stats）—— 本轮新增
#
# ★★ 为什么要有一层覆盖，而不是「直接把 unit.types.<类型> 改掉」：
#   「将领 = 带类型的队长」这条设计还在（改兵种数值，所有该类型的兵与将领一起变），
#   而需求又要求「将领可以单独调血量 / 攻击」—— 两者只能靠**覆盖**共存：
#   没写的键跟随兵种，写了的键归这位将领。
#
# ★ 查的是**序号**（0 起），与 unit.general.types 同序。
#   ⚠️ 不要用 kind 去查：开局那三位的 kind 都是 `general`（见 world.create_generals），
#      `general` 与 `general_N` 靠 general_index_of 映射到同一个序号 ——
#      单位对象在 create 时就知道自己是第几位（unit.general_index），
#      所以数值是**单位自己**带上身的，不是每次按 kind 去猜。
# ------------------------------------------------------------------

## 第 index 位将领写了的数值（只读，别改返回的字典；空字典 = 完全跟随兵种）
func general_stat_overrides(index: int) -> Dictionary:
	if index < 0 or index >= _general_stats.size():
		return {}
	return _general_stats[index]


## 第 index 位将领的**显示名覆盖**（没写 → 空字符串，调用方自己兜底「将领」/「将领 N」）
func general_name_at(index: int) -> String:
	if index < 0 or index >= _general_names.size():
		return ""
	return _general_names[index]


## 第 index 位将领的**生效战斗字典**（覆盖 ⊕ 所属兵种）—— 共享只读字典，别改。
func general_combat_at(index: int) -> Dictionary:
	if index < 0 or index >= _general_combat.size():
		return _combat_fallback
	return _general_combat[index]


## 第 index 位将领的**生效血量 / 速度**（覆盖 ⊕ 所属兵种）。
## ★ 给悬停详情与编辑器对照用；单位自己那边在 create 时就把值抄走了（见 unit.gd）。
func general_hp_at(index: int) -> float:
	var ov: Dictionary = general_stat_overrides(index)
	var type_id := general_type_at(index)
	if ov.has("hp_max"):
		return float(ov["hp_max"])
	return unit_hp_of(type_id)


func general_speed_at(index: int) -> float:
	var ov: Dictionary = general_stat_overrides(index)
	var type_id := general_type_at(index)
	if ov.has("speed"):
		return float(ov["speed"])
	return unit_speed_of(type_id)


## ★★ 第 index 位将领的**生效视野半径**（覆盖 ⊕ 所属兵种）。
##
## ★ 与 general_hp_at / general_speed_at 同一条口径：写了的键归这位将领，
##   没写的跟随它所属兵种那一档。迷雾每帧按**单位自己**的 `vision` 取值
##   （见 logic/fog.gd），所以这里主要是给编辑器与悬停详情对照用。
func general_vision_at(index: int) -> float:
	var ov: Dictionary = general_stat_overrides(index)
	if ov.has("vision"):
		return float(ov["vision"])
	return unit_vision_of(general_type_at(index))


## ★★ 某个单位类型的**视野半径（格）** —— 战争迷雾唯一读的地方。
##
## 口径：从单位所在的**格心**算半径，视线被**山脉**挡住（见 logic/fog.gd）。
##   · 参数可以是单位类型 id，也可以是 kind（将领会被换算成它所属的类型，
##     与 unit_hp_of / unit_combat_of 完全一致）；
##   · 查不到的类型 → `fog.vision_default`（不是 0：漏配一个类型不该让那个单位变成瞎子）。
func unit_vision_of(id: String) -> float:
	var e := unit_type_entry(id)
	if e.is_empty():
		return fog_vision_default
	return maxf(0.0, float(e.get("vision", fog_vision_default)))


## ★★ 建筑类型表里的视野半径（格）—— 与 `unit.types.<id>.vision` **对称**的那一处。
##
## ★ 优先级（老地图 / 老配置的行为不变）：
##   1. `building.<type>.vision` 写了 → 用它（编辑器「建筑」页那一栏写的就是它）；
##   2. 没写 → `fog.vision_building`（默认 9，也就是加类型表之前那个共用值）；
##   3. 类型根本不存在（手改地图写了一个不认识的 type）→ 同样退回 `fog.vision_building`。
##
## ★ 热路径提醒：战争迷雾**不调这个函数** —— 建筑在 `create()` 时就把值抄进
##   `b.vision` 了（与单位的 `u.vision` 同一个口径）。这个查询口是给
##   悬停详情 / 测试 / 编辑器对照用的。
func building_vision_of(type: String) -> float:
	if type == "" or not has_building_type(type):
		return fog_vision_building
	return maxf(0.0, num("building.%s.vision" % type, fog_vision_building))


## 建筑的**兜底**视野半径（`fog.vision_building`）——没有类型 / 没写 `vision` 时用它。
func building_vision() -> float:
	return fog_vision_building


## ★★ 单位在地图上显示的那**一个字**（config 的 `unit.types.<id>.icon`）。
##
## 本轮改版（用户需求：「地图上的所有单位图标都改下，改为只显示一个字作为其 2D 图像」）：
## 原来这里返回的是**一份线条画预制体的名字**（枪 / 弓 / 骑 / 叉四份，见 view/unit_icon.gd），
## 现在直接就是地图上要画的**那个字**本身。
##
## 取值顺序（前一个没有就用后一个）：
##   1. `unit.types.<类型>.icon`（**正好一个字符**；编辑器里那一栏写的就是它）；
##   2. 单位名字的第一个字（没写 icon 时的兜底 —— 手写地图 / 老配置里的怪 kind 也有字可画）；
##   3. `"?"`（名字也是空的，理论上到不了这儿）。
##
## ⚠️ 参数可以是**单位类型 id**，也可以是 kind（将领类会被换算成它所属的类型）——
##   于是「将领 1」画的是长枪兵那个字（将领本身不单独配字；它靠描边更粗与普通兵区分）。
func unit_icon_of(id: String) -> String:
	var tid := unit_type_of(id)
	var icon: Variant = _unit_icons.get(tid, null)
	if typeof(icon) == TYPE_STRING and String(icon) != "":
		return String(icon).substr(0, 1)          # 防御：手改配置写了两个字也只画一个
	var name := unit_name_of(tid)
	if name != "":
		return name.substr(0, 1)
	return "?"


## ★★ 单位类型 id → **3D 立牌素材路径**（config 的 `unit.types.<id>.sprite`）。
##
## ★ 与 `unit_icon_of` 完全同一条口径：
##   · 参数可以是**单位类型 id**，也可以是 kind（将领类会被换算成它所属的类型）；
##   · 空串 = 没配 / 查不到类型 → 渲染层退回程序化剪影（见 view/unit_sprite_3d.gd 的 bake_asset）。
##   ⇒ 这一层只回答「用哪个文件」，**不去加载资源**（config 是依赖图最底层，不碰 Texture）。
func unit_sprite_of(id: String) -> String:
	var tid := unit_type_of(id)
	var v: Variant = _unit_sprites.get(tid, "")
	return String(v) if typeof(v) == TYPE_STRING else ""


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


## 读一份 `{"food": n, "gold": n}` 形状的**消耗**（招募 / 升级 / 特化 / 再起共用这一套）。
##
## ★ 为什么要这个函数（本轮新增）：`EconomyRes.can_afford` / `spend` 认的就是这个形状，
##   而 `get_path_value` 返回 Variant —— 直接在调用点 `if typeof(...) == TYPE_DICTIONARY`
##   判一次的话，每个新消耗点都要抄一遍（抄漏一次就是「钱不够也放行」这种安静的错误）。
## ★ 缺字段 / 类型不对 → 返回**空字典**（= 免费），与 `recruit_cost` 的兜底同义。
func _read_cost(path: String) -> Dictionary:
	var v: Variant = get_path_value(path)
	if typeof(v) == TYPE_DICTIONARY:
		return v
	return {}


## 读阵型分层表 `{"spearman":0,"longbowman":1,"rider":2}` → Dictionary[String,int]。
## ★ 缺字段 / 类型不对 → 空字典（谁都没登记 ⇒ 全体走 formation_tier_default）。
func _load_tier_order() -> Dictionary:
	var v: Variant = get_path_value("unit.formation.tier_order")
	var out: Dictionary = {}
	if typeof(v) == TYPE_DICTIONARY:
		for k in (v as Dictionary).keys():
			var val = (v as Dictionary)[k]
			if typeof(val) == TYPE_INT or typeof(val) == TYPE_FLOAT:
				out[String(k)] = int(val)
	return out


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


## ★★ 运行时登记的阵营颜色："faction" → {"main": Color, "sel": Color, "bar": Color}。
##
## 为什么需要它：配色表（`colors.faction.*`）里只有 p1~p8 / enemy / ai 这些**内置**阵营 id，
## 而**战役可以用自己的阵营 id**（`campaign.json` 的 `factions[].color` 就是给它们准备的）。
## 不登记的话 `faction_color("F1")` 会一路退到兜底的 **品红** ——
## 症状是「整个战场一片紫、分不清敌我」（实测踩到：样例战役的 F1/E1 就是这么来的）。
##
## ★ 状态放在 config 上而不是 view 上：`view/` 里所有取色都走 `cfg.faction_color()`
##   （单位 / 建筑 / 区块 / 小地图），在这里登记一处就全通了 —— 不必给每个 view 传调色板。
## ★ 生命周期：每次 `world.reset()` 按关卡数据重登记一遍（见 `world._register_level_colors`），
##   所以换一局不会串色。
var _faction_color_override: Dictionary = {}


## ★★ 登记一个阵营的三个颜色（`main` 主色 / `sel` 选中态 / `bar` 血条）。
##
## @param main / sel / bar 十六进制或 `rgba(...)`（与 config 里其它颜色同一种写法）
## @return bool 认出来了没有（**写错了**会返回 false 并保持原样，不会悄悄设成黑色）
##
## ⚠️ 只在**内容认得出来**时才登记：写错的颜色宁可让它退回原来的兜底
##   （一品红总比「所有阵营都变成黑色」好查 —— 后者看起来像渲染坏了）。
func register_faction_color(faction: String, main: String, sel: String = "", bar: String = "") -> bool:
	var fid := faction.strip_edges()
	if fid == "":
		return false
	# ⚠️ 这几个用 `=` 而不是 `:=`：`_parse_color_or_null()` 返回 Variant（null 或 Color），
	#    对它用 `:=` 会被引擎当成错误（"The variable type is being inferred from a Variant value"）。
	var m = _parse_color_or_null(main)
	if m == null:
		return false
	# sel / bar 没给就跟 main 走（只给一个颜色的战役数据也能用）
	var s = m
	var b = m
	if sel.strip_edges() != "":
		var sv = _parse_color_or_null(sel)
		if sv != null:
			s = sv
	if bar.strip_edges() != "":
		var bv = _parse_color_or_null(bar)
		if bv != null:
			b = bv
	_faction_color_override[fid] = {"main": m, "sel": s, "bar": b}
	return true


## 这个阵营有没有被登记过颜色（给测试与排查用）。
func has_faction_color(faction: String) -> bool:
	return _faction_color_override.has(faction)


## 清掉运行时登记的颜色（重开一局 / 换战役时用）。
func clear_faction_colors() -> void:
	_faction_color_override = {}


## 解析一个颜色字符串：**认得出来**返回 Color，认不出来返回 null。
##
## ⚠️ 与 `parse_color(v, fallback)` 的差别：那个「认不出来就给兜底」，
##    所以它分不出「解析失败」与「解析成了兜底色」；登记颜色时需要这个区分。
func _parse_color_or_null(text: String) -> Variant:
	var t := text.strip_edges()
	if t == "":
		return null
	var sentinel := Color(0.0, 0.0, 0.0, 0.0)   # 不会被当成合法配色的哨兵
	var got := parse_color(t, sentinel)
	if got == sentinel:
		return null
	return got


## 取 colors.* 里的一项
func color(key: String) -> Color:
	var v: Variant = get_path_value("colors." + key)
	if typeof(v) == TYPE_STRING:
		return parse_color(v)
	return Color.MAGENTA


## 阵营配色。未登记的阵营退回 player —— 保证「配色表只到 p4」这类情况不会崩，
## 也不会把 p5~p8 悄悄画成别的阵营的颜色（见 docs/pitfalls.md 3.12）。
##
## ★★ 查找顺序（**先看运行时登记的，再看配色表**）：
##   1. `register_faction_color()` 登记过的（**战役自己的阵营 id**，比如 F1/E1）——
##      它必须在配色表之前，否则「战役想覆盖内置 id 的颜色」会被配色表压住；
##   2. `colors.faction.<id>.<field>`（内置的 p1~p8 / enemy / ai）；
##   3. `colors.faction.player.<field>`（老的兜底键，当前 config 里没有）；
##   4. `Color.MAGENTA` —— ⚠️ **走到这一步就是「忘了登记颜色」**：
##      画面上表现为「整个战场一片紫、敌我分不清」。战役里出现紫色先查这条
##      （见 docs/pitfalls.md 8.1）。
func faction_color(faction: String, field: String = "main") -> Color:
	var over: Variant = _faction_color_override.get(faction, null)
	if typeof(over) == TYPE_DICTIONARY:
		var got: Variant = (over as Dictionary).get(field, null)
		if got is Color:
			return got
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
## 建筑攻击三件套的缓存（键 = "类型|等级"，见 building_attack_of）
var _building_attack_cache: Dictionary = {}


func building_body_scale(type: String) -> float:
	var cached: Variant = _body_scale_cache.get(type, null)
	if cached != null:
		return cached
	var v: float = clampf(num("building.%s.body_scale" % type, 1.0), 0.05, 1.0)
	_body_scale_cache[type] = v
	return v


# ------------------------------------------------------------------
# 建筑定义（config.json 的 `building` 段）—— 本轮从 building.gd 的 DEFS 搬过来
#
# ★★ 为什么搬：地图编辑器管地形、单位编辑器管数值 —— 而「有哪些建筑、各自什么名字」
#   原本写死在 logic/building.gd 的 DEFS 里，设计师加一栋楼**游戏里根本出不来**
#   （建造页是遍历 DEFS 生成的）。搬进 config 之后：
#     · 加一栋建筑 = 往 building 段加一条（编辑器有「新建建筑」按钮）；
#     · 名字 / 说明 / 快捷键 / 能不能建造 / 阻挡语义 全都在数据里。
#   DEFS 剩下两件事：**区划中心**（它不是建筑，编辑器不管它）+ 未知类型的兜底。
#
# ⚠️ config.gd 是依赖图最底层，**不能** preload logic/building.gd（会成环），
#    所以「兜底定义」由调用方传进来：`cfg.building_def(type, DEFS.get(type, {}))`。
# ------------------------------------------------------------------

## 某个建筑类型的完整定义：`fallback`（内置兜底）⊕ config 里写的键（**config 优先**）。
func building_def(type: String, fallback: Dictionary = {}) -> Dictionary:
	var out: Dictionary = fallback.duplicate()
	var raw: Variant = get_path_value("building.%s" % type)
	if typeof(raw) == TYPE_DICTIONARY:
		for key in (raw as Dictionary).keys():
			var k := String(key)
			if k.begins_with("_"):            # `_defs_comment` 这类注释键
				continue
			out[k] = (raw as Dictionary)[key]
	return out


## config 里有没有这个建筑类型（建造命令的准入判据）
func has_building_type(type: String) -> bool:
	return typeof(get_path_value("building.%s" % type)) == TYPE_DICTIONARY


## config 里定义的全部建筑类型 id（顺序 = 文件里的顺序）
func building_type_ids() -> Array:
	var out: Array = []
	var raw: Variant = get_path_value("building")
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	for key in (raw as Dictionary).keys():
		var k := String(key)
		if k.begins_with("_"):
			continue
		if typeof((raw as Dictionary)[key]) == TYPE_DICTIONARY:
			out.append(k)
	return out


## 右下「建筑」页要显示的那几项（`buildable = true`），每项 = 完整的建筑定义。
func buildable_building_defs() -> Array:
	var out: Array = []
	for type in building_type_ids():
		var d := building_def(type)
		if bool(d.get("buildable", false)):
			out.append(d)
	return out


## 建筑的基础血量上限（等级 / 科技都是在它上面乘倍率）
func building_max_hp(type: String) -> float:
	return maxf(0.0, num("building.%s.hp_max" % type, 300.0))


## ★ 建造读条秒数（config 的 `building.<type>.build_sec`）。**0 = 瞬发**（默认）。
func building_build_sec(type: String) -> float:
	return maxf(0.0, num("building.%s.build_sec" % type, 0.0))


## ★ 能不能攻击（config 的 `building.<type>.attackable`）。不打勾就不读攻击三件套。
func building_attackable(type: String) -> bool:
	return bool_val("building.%s.attackable" % type, false)


## ★★ 某个等级的攻击三件套 {damage, range, cooldown}：
##   等级行里写了就用它（`upgrade.levels.<type>[k].damage` …），没写就用
##   `building.<type>` 那一档的基础值。← 于是「现在的数据」逐位不变（等级行里没写）。
##
## ★ 按 (类型, 等级) 缓存：箭塔每开一炮都要读一次，而 `num()` 那种写法每次都要
##   split(".") + 逐层下潜；配置在运行期不会变，缓存是安全的。
func building_attack_of(type: String, level: int) -> Dictionary:
	var key := "%s|%d" % [type, level]
	var cached: Variant = _building_attack_cache.get(key, null)
	if cached != null:
		return cached
	var dmg := num("building.%s.damage" % type, 0.0)
	var rng := num("building.%s.range" % type, 0.0)
	var cd := num("building.%s.cooldown" % type, 0.0)
	var row := upgrade_row(type, level)
	var atk: Variant = row.get("attack", null)
	if typeof(atk) == TYPE_DICTIONARY:
		var a: Dictionary = atk
		dmg = float(a.get("damage", dmg))
		rng = float(a.get("range", rng))
		cd = float(a.get("cooldown", cd))
	var out := {"damage": maxf(0.0, dmg), "range": maxf(0.0, rng), "cooldown": maxf(0.01, cd)}
	_building_attack_cache[key] = out
	return out


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
			# ★ 本轮新增：这一级**可以**自带攻击三件套（不写 = 沿用 building.<type> 的基础值）。
			#   只收数字键：写错的键在这里就被丢掉，免得 building_attack_of 拿到字符串。
			var atk: Dictionary = {}
			for key in ["damage", "range", "cooldown"]:
				var v: Variant = d.get(key, null)
				if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
					atk[key] = float(v)
			table.append({
				"level": int(d.get("level", table.size() + 1)),
				"hp_mult": maxf(0.01, float(d.get("hp_mult", 1.0))),
				"cost": (cost as Dictionary) if typeof(cost) == TYPE_DICTIONARY else {},
				"time_sec": maxf(0.0, float(d.get("time_sec", 0.0))),
				"attack": atk,
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


# ------------------------------------------------------------------
# AI（config.json 的 ai 段）—— 两种 AI：阵地性 / 红点性
#
# ★ 与科技 / 升级 / 区划那几张表同一条规矩：**载入时整理好、之后只读**。
#
# ★★ 分工（规则分别在 logic/garrison_ai.gd 与 logic/red_dot_ai.gd）：
#   · `ai.factions[]` —— 全局兜底名单：一张图上可以点名几个 AI 阵营（id + 出生锚点）。
#     它们默认是**阵地性 AI**（缺省 `ai` 字段 = "garrison"）。
#   · `ai.garrison`  —— 阵地性 AI 的行为参数（巡逻间隔 / 半径 / 脱战多久算闲 /
#                        多久查一次招兵 / 满员门槛）。
#   · `ai.reddot`    —— 红点性 AI 的行为参数（冷却 / 每波将领数 / 每位满编数 / 生成半径 / 波数）。
# ⚠️ 表是空的（老配置 / 手改删掉这一节）时**两种 AI 都不跑** —— 行为与加它们之前一致。
# ⚠️ AI 阵营**没有资源库、没有大本营**（本轮口径）：`ai.factions[].base` 只是
#    「将领出生锚点」，不建任何建筑；红点阵营靠关卡 `spawn_region` 刷兵。
# ------------------------------------------------------------------

## 「每帧每 AI」的读取口：AI 的阵营表（只读，别改返回的数组）
var _ai_factions: Array = []
## AI 的行为参数（整理成同一层字典，省得每帧下潜 JSON）。
var _ai_garrison_cfg: Dictionary = {}
var _ai_reddot_cfg: Dictionary = {}


func _cache_ai() -> void:
	_ai_factions = []
	_ai_garrison_cfg = {}
	_ai_reddot_cfg = {}

	var raw: Variant = get_path_value("ai.factions")
	if typeof(raw) == TYPE_ARRAY:
		for item in (raw as Array):
			if typeof(item) != TYPE_DICTIONARY:
				continue
			var src: Dictionary = item
			var id := String(src.get("id", ""))
			if id == "":
				continue
			# ⚠️ 玩家席位（p1…p8）**不许**出现在这里：那会变成「AI 接管玩家的阵营」。
			var base := Vector2i(-1, -1)
			var b: Variant = src.get("base", null)
			if typeof(b) == TYPE_ARRAY and (b as Array).size() >= 2:
				base = Vector2i(int((b as Array)[0]), int((b as Array)[1]))
			_ai_factions.append({
				"id": id,
				# 出生锚点（不是大本营建筑）：用来算将领站位，见 map.spawn_layout_for。
				"base": base,
				# 缺省是阵地性 AI；允许在这里点名 reddot（一般由关卡点名，不写这里）。
				"ai": String(src.get("ai", "garrison")),
			})

	_ai_garrison_cfg = {
		"patrol_interval_sec": maxf(0.1, num("ai.garrison.patrol_interval_sec", 4.0)),
		"patrol_leash_tiles": maxf(1.0, num("ai.garrison.patrol_leash_tiles", 1.0)),
		"combat_idle_sec": maxf(0.0, num("ai.garrison.combat_idle_sec", 10.0)),
		"retarget_cooldown_sec": maxf(0.0, num("ai.garrison.retarget_cooldown_sec", 5.0)),
		"recruit_check_sec": maxf(0.1, num("ai.garrison.recruit_check_sec", 2.0)),
		"min_retinue": maxi(0, int(num("ai.garrison.min_retinue", 3.0))),
		# ★★ 巡逻路线（让同一个区划里的几位守将**不要挤在同一点**）：
		#   · `patrol_points`：每位守将分到几个巡逻点（1 = 老行为：只去一个点）；
		#   · `patrol_spread_tiles`：巡逻点之间最多相隔几格。
		#   ★ 路线本身是**由单位 id 派生的固定种子**算出来的（确定性伪随机）。
		"patrol_points": maxi(1, int(num("ai.garrison.patrol_points", 3.0))),
		"patrol_spread_tiles": maxf(1.0, num("ai.garrison.patrol_spread_tiles", 3.0)),
		# ★★ 巡逻**带兵**：附属兵离带队将领超过这么多格就会被重新叫上。
		"patrol_retinue_leash_tiles": maxf(1.0, num("ai.garrison.patrol_retinue_leash_tiles", 3.0)),
	}
	# ★★ 红点 AI 的函数式时间表与随机规格（本轮新增）。全部**宽容读取**：
	#   读不出来一律退回默认（'x' / 空表），决不让一份坏数据把这一局卡死。
	var rd_wave: Variant = get_path_value("ai.reddot.wave_time_expr")
	if typeof(rd_wave) != TYPE_STRING or String(rd_wave).strip_edges() == "":
		rd_wave = "x"
	var rd_count: Variant = get_path_value("ai.reddot.general_count_expr")
	if typeof(rd_count) != TYPE_STRING or String(rd_count).strip_edges() == "":
		rd_count = "x"
	# spawn_tiles：config 缺省是空表（关卡才填）。兼容 `[x,y]` 数组 / 字典两种写法。
	var rd_tiles: Array = []
	var rd_tiles_raw: Variant = get_path_value("ai.reddot.spawn_tiles")
	if typeof(rd_tiles_raw) == TYPE_ARRAY:
		for t in (rd_tiles_raw as Array):
			if typeof(t) == TYPE_ARRAY and (t as Array).size() >= 2:
				rd_tiles.append(Vector2i(int((t as Array)[0]), int((t as Array)[1])))
	_ai_reddot_cfg = {
		# 生成区域缺省半径（格）。
		"spawn_radius": maxf(0.0, num("ai.reddot.spawn_radius", 4.0)),
		# 波数：0 = 无限（默认）；> 0 = 只刷这么多波。
		"waves": maxi(0, int(num("ai.reddot.waves", 0.0))),
		# ★★ 函数式时间表：第 x 波的生成时间（分钟）/ 将领数（y = a·x + b）。
		"wave_time_expr": String(rd_wave),
		"general_count_expr": String(rd_count),
		# ★★ 关卡选中的「红点生成地块」（config 里默认空 → 退回 spawn_region / 出生点）。
		"spawn_tiles": rd_tiles,
		# ★★ 将领类型权重（`[{general, weight}]`）与共享附属单位规格（`[{type, weight}]`）。
		"general_weights": normalize_weight_list(get_path_value("ai.reddot.general_weights")),
		"escort_count": maxi(0, int(num("ai.reddot.escort_count", 4.0))),
		"escort_types": normalize_weight_list(get_path_value("ai.reddot.escort_types")),
	}


## 全部「AI 阵营」条目（每项 {id, base, ai}；只读）
func ai_factions() -> Array:
	return _ai_factions


## 阵地性 AI 的行为参数（只读；键见 `_cache_ai()`）
func ai_garrison_cfg() -> Dictionary:
	return _ai_garrison_cfg


## 红点性 AI 的行为参数（只读；键见 `_cache_ai()`）
func ai_reddot_cfg() -> Dictionary:
	return _ai_reddot_cfg


## 这个阵营是不是「由 AI 接管」的（单机 / 联机都能问：AI 只跑在权威侧）
func is_ai_faction(fid: String) -> bool:
	for e in _ai_factions:
		if String((e as Dictionary)["id"]) == fid:
			return true
	return false
