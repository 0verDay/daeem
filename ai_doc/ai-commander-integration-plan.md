# DAEEM · AI 指挥官与「合作 AI 队友」接入方案（计划稿）

> 状态：**设计稿 / 历史实现记录**。M1~M5 已落地；后续行为仍在迭代。
> ★ **当前实际行为请先读 [ai-commander-current-status.md](ai-commander-current-status.md)**；
>   本文只保留接入方案与早期实现过程，旧测试数字 / 旧规则可能已被覆盖。
> ★ 后续（2026.10.24 晚）：按实测反馈重做了**按队补员 / 守军轮换 / 区划中心扩张 / 大小队分工 / 巡逻**，
>   并把招募底层改成**移动兵营**（受击暂停、脱战继续）；读条中的将领也可巡逻 / 出征，
>   小股部队会按可见敌军规模避战。
> 依据：[`rusted-warfare-ai-adaptation-spec.md`](rusted-warfare-ai-adaptation-spec.md)（下称「RW 规范」）
> 勘察对象：`dev_gd_a/daeem/`（Godot 4.7.2 mono；测试基线以下方的「当前实现状态」为准）
> 目标：把 RW 规范里的「分层调度 / 效用评分 / 预算制生产 / 编组状态机 / 命令层 / 难度参数包」改造成适合本作的**阵营指挥官 AI**，先作为合作模式的第二席位 AI 队友接入；自定义对战房间本轮不实现，只保留可复用设计。

---

## 0. 结论先行

1. **新增第三种 AI：`commander`（阵营指挥官 AI）**。它不再像现有 `garrison` / `reddot` 那样「没有大本营、没有资源库、不建造」，而是拥有：
   - 自己的大本营与基地区划；
   - 自己的粮食 / 黄金资源池与每秒收入；
   - 招将、招兵、升级大本营、启用科技、区划特化、建箭塔；
   - 一支由「将领 + 附属兵」组成的军队，会集结、行军、驻守、扩张、回防。
2. **本轮接入范围只做「合作模式 AI 队友」**：房主在开局前二选一——真人队友 **或** AI 队友，两者不同时存在。AI 队友占用合作关的第二席位（现成的基地 / 开局摆放 / 目标判定全部沿用）。
3. **不做自定义对战房间**。但 AI 从第一天起就按「可当对手」设计：公平视野、难度参数包、目标选择、自动战略模式（`auto`）都保留；未来做单人对战房间时，只需补「房间 UI / 基地槽位分配 / 歼灭胜负」三块，AI 本体不改。
4. **四条指令**：
   - **行军**：玩家点地图选目标点；AI 全军**行军攻击**到该点，路上遇敌就打，到达后驻守；目标是敌方区划中心时尝试占领。
   - **发展**：不主动扩张；守家、补员、升级大本营、启用科技、做区划特化、在边境建箭塔。
   - **扩张**：优先夺取与己方领土相邻的中立 / 敌方区划；派出一支分队去区划中心读条，其余守家；拿下一块再找下一块。
   - **屯兵**：玩家点地图选集结点；AI 把军队集结到该点并驻守、持续补员，不主动扩张。
5. **玩家只下「战略指令」，不微操 AI 单位**。AI 的所有动作仍然走 `command_processor`（建造 / 招募 / 升级 / 科技 / 移动 / 行军攻击），不直接改世界状态；这样将来联机、回放、测试都能复用。
6. **公平 AI**：默认只使用自己（与队友共享）的战争迷雾视野，不读全图；难度只改收入倍率、生产/建造节奏、军队上限、反应延迟，不改单位数值、不送兵、不全图开图。
7. **确定性**：不使用引擎全局随机数；用 `world.unit_rand()` / 固定种子 + 稳定迭代顺序；同一局同一种子可复现同样的指令序列。

---

## 1. 已确认的口径

| 问题 | 你的决定 | 对设计的影响 |
|---|---|---|
| 合作模式 AI 队友与真人队友是否共存 | **房主开局前二选一，不同时存在** | AI 队友固定占第二席位；真人队友路径完全不变；不做「第三友军阵营」 |
| 自定义对战房间 | **本地单机，但本轮不做**；只需知道 AI 未来会用于它 | 本轮只做 AI 本体 + 合作接入；不写房间 UI、不做基地槽位分配、不做歼灭胜负 |
| 「行军」语义 | **行军攻击 + 到点驻守** | 用 `attack_move`；到点后不再主动推进；目标是敌方区划中心时自然进入占领读条 |
| 「屯兵」集结点 | **由玩家再指定一个集结点** | 点「屯兵」后进入选点模式；未选点前保持原指令 |
| AI 对手数量 / 队伍 | 本轮不做 | 未来再定；AI 保留 `auto` 自动战略与难度参数，方便以后直接当对手 |

---

## 2. 现状勘察（决定方案边界的代码事实）

### 2.1 现有两种 AI

| AI | 实现 | 有无大本营 | 有无资源库 | 行为 |
|---|---|---|---|---|
| 阵地性 `garrison` | [`logic/garrison_ai.gd`](../dev_gd_a/daeem/logic/garrison_ai.gd) | 无 | 无（资源无限） | 附属于一个区划，巡逻、警戒、不追出区划、脱战免费补兵、濒死免费再起 |
| 红点性 `reddot` | [`logic/red_dot_ai.gd`](../dev_gd_a/daeem/logic/red_dot_ai.gd) | 无 | 无 | 按函数式时间表在指定地块刷满编将领，带整队行军到目标 |

关键结论：**这两套 AI 都不能直接改造成「会经营、会建造、会扩张」的指挥官**。它们的设计前提就是「没有经济、没有基地」，硬塞经济会破坏现有地图 / 战役的平衡与测试。因此新增 `commander`，而不是改 `garrison` / `reddot`。

### 2.2 经济与建造

- 收入：`zones.production_of(faction)` 聚合该阵营占领区划的每秒产能；`world._accumulate_production()` 算速率，`EconomyRes.tick()` 加到资源池。
- 资源池：`world.resource_pool_for(faction)` 目前只给 `player_seats` 发池子，其余一律 `null`（= 无限）。`commander` 必须在这里拿到**自己的**池子。
- 建造：`command_processor.apply_build()` 校验 `world.can_build_at()` + `world.zone_allows_build()`，**只能建在自己的区划里**；本作**没有工兵单位**，所以 AI 只要选中合法地块就能直接建造。可建造类型目前只有 `wall` / `tower`。
- 招兵：`world.start_recruit(kind, leader_id, faction)`，将领必须站在**己方区划**内；扣该将领所在区划的人口。将领自己就是兵营，队列最多 5。
- 招将：`world.start_zone_recruit(kind, zone_id, faction)`，在区划中心旁生成新将领；需要己方区划 + 人口。
- 升级：`world.start_building_upgrade(tx, ty, faction)`，大本营 1→2→3，解锁招兵行 / 科技上限 / 将领上限。
- 科技：`world.set_tech_active(id, on, faction)`，免费但受大本营等级与「最多同时 N 条」限制；效果按阵营生效。
- 区划特化：`world.start_zone_specialize(zone_id, spec, faction)`，粮食 / 黄金 / 人口三选一，读条。
- 占领：单位必须站在**区划中心 3×3** 内才读条；同一时刻只有一方能读；双方同场会冻住。链接：[`logic/zone.gd`](../dev_gd_a/daeem/logic/zone.gd)。

### 2.3 合作模式与联机

- 房主跑唯一权威世界；客机只收快照、不发世界 tick（[`view/game_scene3d.gd`](../dev_gd_a/daeem/view/game_scene3d.gd)）。
- 客机命令必须 `cmd.faction == guest_seat`，由 `host_session` 校验后交给 `command_processor`（[`net/host_session.gd`](../dev_gd_a/daeem/net/host_session.gd)）。
- 快照由 `logic/snapshot.gd` 生成，30Hz 全量；事件走 `event_codec`。
- 合作大厅 `view/coop_lobby.gd` 目前是「建房 / 加入 / 准备 / 地图选择」三态，必须有一个真人客机才能开始。
- 合作关 = `mode: "coop"` 的关卡；第二席位有自己现成的基地与 `start_units`（例如 `02_twin_line.json` 的 F2 有 3 位将领 + 附属兵）。这是 AI 队友可以直接继承的资产。

### 2.4 阵营 / 目标 / 胜负

- `player_seats` = 本机负责建基地 / 开钱包的席位；`player_factions` = 本机**实际操作**的席位（= `player_seats` 减去被 AI 接管的）。
- `world.ai_kind_of(faction)` 决定「这一方这一局挂什么 AI」；`_is_ai_piloted()` 是开局后口径。
- 目标：`hold_zone` / `capture_zone`；常开失败 = 玩家席位大本营被拆；`defend` 只认 `player_factions`（[`logic/objective.gd`](../dev_gd_a/daeem/logic/objective.gd)）。
- 盟友：`FactionRes.same_side_for_attack()` = 同阵营或盟友；区划占领、索敌、建筑通行都认它。AI 队友与玩家必须登记为盟友（合作关本来就有 `allies: [["F1","F2"]]`）。

### 2.5 视图 / UI

- `logic/` 是纯 `RefCounted`，禁止 `Node` / `get_tree()` / 读输入；跨文件只用 `preload` 常量。
- HUD 是 `CanvasLayer` 上的 `Control`；已有浮动面板范式：`view/options_panel.gd`（居中 overlay）、`view/objective_panel.gd`（左上目标栏）、`view/hover_tip.gd`（命令卡上方详情）。
- 输入唯一入口是 `view/input_controller.gd`；它已有 `order_mode`（移动 / 攻击 / 行军 / 停止）状态机，可扩展「AI 指令选点」模式。
- 3D 覆盖层 `view/overlay_view_3d.gd` 负责屏幕空间标记；可以在这里画 AI 目标环。

---

## 3. 对 RW 规范的取舍（本地化映射）

### 3.1 直接采用的模式

| RW 规范 | 本作落点 |
|---|---|
| 分层调度（25 / 80 / 250 帧） | 改成时间制：`army` 0.6s、`strategic` 2.0s、`command` 每帧去重；秒数进 config |
| 效用评分选建造 / 生产 | `BuildPlanner` / `Production` 对候选打分，硬约束（价格、前置、上限、地块）先于评分 |
| 预算制生产 | 用「资源 ÷ 单位均价 + 人口余量 + 军队上限」算每轮可下的单数，不照搬「3.5 单位预算」 |
| 编组状态机 | `Army` 管「将领 + 附属兵」编队；`march / develop / expand / mass / auto` 是战略状态，具体目标/集结/进攻是子状态 |
| 命令接口 | 全部走 `command_processor`；AI 不直接改 `unit` / `building` 字段 |
| 难度参数包 | `ai.commander.difficulty.*` 只改收入、节奏、上限、反应延迟 |
| 公平视野 | 用 `fog.unit_visible()` / `fog.known_buildings()`；不默认全图 |
| 确定性 / 可回放 | 固定种子、稳定顺序、AI 状态可导出；联机只跑房主侧 |
| 调试指标 | `world.ai_panel_state()` + 可选覆盖层 + 计数器（命令数 / 拒绝数 / 路径失败） |

### 3.2 明确不照搬的缺陷

| RW 缺陷 | 本作做法 |
|---|---|
| 全局随机目标（全图敌方单位表） | 只在**可见敌人 + 已记住的敌方建筑 + 公开的区划归属**里选；按战略价值 / 距离 / 威胁打分 |
| 没有侦察、没有威胁图 | 不要求独立侦察兵；用「军队视野 + 已占区划 + 敌方建筑记忆」构成轻量威胁图 |
| 没有兵种克制 / 编成规划 | 按 `unit.types` 的 `unit_class` / `ranged` / `siege` 做权重；看到敌方骑兵多就多出长枪兵，看到箭塔多就补投石车 |
| 没有 build order / 科技拓扑 | 用「大本营等级 → 招兵行 / 科技阶数」的硬门槛做前置 DAG；不写死固定开局 |
| 长计时器导致长时间不进攻 | 用「军队价值 / 目标价值 / 时间」三因子决定进攻时机；`auto` 模式下超时强制推进 |
| 没有经济浮存控制 | `max_float` + `reserve`：钱超过阈值就优先升级 / 科技 / 特化 / 箭塔；低于 reserve 只保防守 |
| 没有微操 | 不做集火 / 拉扯；只做「整队行军攻击 + 到点驻守 + 回防」三件事，符合本作单位 AI 的粒度 |

### 3.3 本作没有、直接跳过的模块

- **运输组**：本作没有运输单位，水域不可通行；`Transport` 模块不实现。
- **海军 / 空军 / 移动域**：只有陆地单位；不做 LAND/HOVER/AIR 权重与连通性预计算。
- **生存模式 / 战役触发器**：本轮不做；AI 只服务合作模式与未来的遭遇战。
- **锁定步 / 回放**：本作目前没有回放；仍按确定性写，避免以后返工。

### 3.4 常量换算

RW 规范里的帧常量（25/80/250/270/1000/11000/17000 帧）**一个都不直接抄**。本作是秒制 `world.tick(dt)`，全部改成 config 秒数：

| 用途 | RW 参考 | 本作建议默认 |
|---|---|---|
| 军队层决策 | 25 帧 ≈ 0.42s | `army_interval_sec = 0.6` |
| 战略层决策 | 250 帧 ≈ 4.17s | `strategic_interval_sec = 2.0` |
| 建造尝试 | 270 帧 ≈ 4.5s | `build_interval_sec = 2.5`（受难度缩放） |
| 生产尝试 | 每轮 12 次 | `production_interval_sec = 1.0`，每轮最多 `production_attempts = 3` |
| 进攻超时 | 11000 帧 ≈ 183s | `auto_attack_timeout_sec = 180` |
| 集结超时 | 17000 帧 ≈ 283s | `march_arrive_timeout_sec = 90` |
| 受伤取消集结 | 1000 帧 ≈ 16.7s | 不单独做；改用「回防优先级」 |

---

## 4. 总体架构

### 4.1 模块图

```text
world.gd
 ├─ ai_roster_cfg[]                     现有：这一局挂哪些 AI
 ├─ ai_kind_overrides{}                 ★ 新增：合作 AI 队友把第二席位改成 commander
 ├─ ai_profiles{}                       ★ 新增：每方的难度 / 参数覆盖
 ├─ ai_directives{}                     ★ 新增：世界可见的指令状态（进快照）
 ├─ ai_faction_resources{}              ★ 新增：commander 的资源池（进快照）
 ├─ ai_commanders{}                     ★ 新增：房主侧 AI 控制器（不进快照）
 ├─ reddot_states[]                     现有
 └─ tick()
      ├─ … 现有战斗 / 经济 / 招募 / 升级 …
      ├─ GarrisonAiRes.update()
      ├─ RedDotAiRes.update()
      └─ CommanderAi.update_all()       ★ 新增
```

```text
CommanderAI（每个 commander 阵营一个）
 ├─ Profile          难度 + 配置 + 阵营覆盖
 ├─ Economy          收入 / 预算 / 储备 / 浮存
 ├─ Threat           轻量威胁图（可见敌人 + 己方区划 / 建筑价值）
 ├─ BuildPlanner     大本营升级 / 科技 / 特化 / 箭塔 / 城墙（可选）
 ├─ Production       招将 / 招兵 / 编成 / 补员
 ├─ Army             将领编队 / 行军 / 驻守 / 扩张 / 回防
 └─ CommandEmitter   去重 / 限流 / 失败记录
```

### 4.2 状态归属（必须写进代码注释的契约）

| 状态 | 放哪 | 为什么 |
|---|---|---|
| 当前指令（`kind` / 目标点 / 序号 / 开始时间 / 状态） | `world.ai_directives[faction]` | 世界状态；客机也要显示；进快照 |
| AI 资源池 | `world.ai_faction_resources[faction]` | 世界状态；`resource_pool_for()` 的唯一来源；进快照 |
| AI 控制器内部（计时器、预算、编组缓存、上一次命令、威胁缓存） | `world.ai_commanders[faction]` | 房主侧运行态；不进快照；客机不需要 |
| 难度 / 参数覆盖 | `world.ai_profiles[faction]` | 开局配置；不随 tick 变；进 `start` 数据（未来联机时） |
| AI 的「工厂」= 将领、大本营、区划 | 现有 `units` / `building_list` / `zones` | 不另建一套；AI 与玩家共用玩法对象 |
| UI 面板位置 / 折叠状态 | `view/ai_order_panel.gd` | 纯本地显示状态，不进世界 |

**铁律**：`ai_commanders` 只在**权威侧**（`with_ai == true` 的房主 / 单机）存在；客机即使收到快照也只更新 `ai_directives` / `ai_faction_resources`，不创建控制器，不跑 AI。

### 4.3 每 tick 顺序

```text
world.tick(dt):
  1. 现有：科技效果 / 区划占领 / 人口 / 归属 / 士气
  2. 现有：玩家席位经济
  2.5 ★ commander 经济：每个 commander 阵营
        rate = _accumulate_production(f, false, seat_tech_effects[f])
        rate *= difficulty.income_mult
        EconomyRes.tick(cfg, dt, rate, ai_faction_resources[f])
  3. 现有：招募 / 升级 / 重生读条
  4. 现有：单位移动 / 战斗
  5. 现有：箭塔 / 投掷物 / 建筑效果
  6. 现有：GarrisonAi.update / RedDotAi.update
  7. ★ CommanderAi.update_all(world, cfg, dt)
  8. 现有：收尸 / 碰撞 / 迷雾 / 胜负 / 目标
```

为什么排在现有两种 AI 之后：三者互不共享状态；commander 的指令要在本帧战斗与位置结算之后基于最新局面做决策，下一帧生效，与现有 AI 的时序一致。

### 4.4 确定性

1. **随机源**：优先用 `world.unit_rand(key, k)`（纯函数 + 每局盐）；需要连续随机时用 `RandomNumberGenerator`，种子由 `hash("%s|%d" % [faction, world.rand_salt])` 派生，状态存在控制器里。
2. **迭代顺序**：`world.units` / `building_list` / `zones.zones` 的现有顺序即稳定顺序；候选打分同分时按 id 字典序 / 坐标排序决定，不用 `Array.sort()` 的不稳定比较。
3. **不依赖帧率**：所有计时器用 `dt` 累加；不用「每 N 帧」。
4. **AI 状态可导出**：`CommanderAI.debug_state()` 返回一个纯字典（指令、预算、目标、编队 id、计时器），测试用它做 hash；未来存档 / 回放直接复用。
5. **不在 AI 里读鼠标 / 场景树**：AI 只读 world / cfg。

### 4.5 公平视野

```gdscript
# AI 能看到的敌人
for u in world.units:
    if not u.alive: continue
    if not FactionRes.same_side_for_attack(u.faction, ai_faction):
        if world.fog.unit_visible(ai_faction, u): ...
# AI 能看到的敌方建筑：当前可见 + 曾经见过的
for b in world.fog.known_buildings(ai_faction): ...
```

- 区划归属是公开信息（地图上的占领状态），AI 可以读。
- `ai.commander.fog_mode = "fair" | "global"`；默认 `fair`。`global` 只给未来的「作弊难度」用，必须在 UI / 文档里标注。
- 合作 AI 队友与玩家共享迷雾桶（`FactionRes.side_of`）⇒ AI 看到的就是玩家看到的，不会偷看。

---

## 5. AI 指挥官详细设计

### 5.1 Profile 与难度

新增 config：

```json
"ai": {
  "commander": {
    "_comment": "阵营指挥官 AI。全部数值按秒；难度只改经济/节奏/上限，不改单位数值。",
    "default_profile": "normal",
    "intervals": {
      "army_interval_sec": 0.6,
      "strategic_interval_sec": 2.0,
      "build_interval_sec": 2.5,
      "production_interval_sec": 1.0,
      "production_attempts": 3,
      "retry_sec": 3.0
    },
    "economy": {
      "reserve_food": 80.0,
      "reserve_gold": 80.0,
      "max_float_food": 600.0,
      "max_float_gold": 600.0
    },
    "march": {
      "arrive_radius": 3.0,
      "hold_radius": 7.0,
      "reissue_sec": 6.0,
      "arrive_timeout_sec": 90.0
    },
    "mass": {
      "arrive_radius": 3.0,
      "hold_radius": 6.0
    },
    "expand": {
      "squad_ratio": 0.65,
      "min_squad_units": 4,
      "capture_hold_sec": 8.0,
      "next_target_delay_sec": 4.0
    },
    "defense": {
      "threat_radius": 10.0,
      "recall_ratio": 0.35,
      "base_low_hp_ratio": 0.45,
      "recall_cooldown_sec": 20.0
    },
    "production": {
      "general_target": 2,
      "max_queue_per_leader": 3,
      "composition": [
        {"type": "spearman", "weight": 0.42},
        {"type": "longbowman", "weight": 0.24},
        {"type": "rider", "weight": 0.16},
        {"type": "knight", "weight": 0.08},
        {"type": "catapult", "weight": 0.05},
        {"type": "grain_cart", "weight": 0.05}
      ]
    },
    "build": {
      "tower_max": 6,
      "tower_frontier_bonus": 4.0,
      "base_upgrade_priority": 10.0,
      "tech_priority": ["..."],
      "wall_enabled": false
    },
    "auto": {
      "attack_after_sec": 150.0,
      "attack_after_army_ratio": 0.7
    },
    "difficulty": {
      "easy": {
        "income_mult": 0.8, "army_cap": 10, "build_interval_mult": 1.3,
        "production_interval_mult": 1.4, "reaction_delay_sec": 2.0,
        "start_food": 150.0, "start_gold": 150.0
      },
      "normal": {
        "income_mult": 1.0, "army_cap": 16, "build_interval_mult": 1.0,
        "production_interval_mult": 1.0, "reaction_delay_sec": 1.2,
        "start_food": 250.0, "start_gold": 250.0
      },
      "hard": {
        "income_mult": 1.2, "army_cap": 22, "build_interval_mult": 0.8,
        "production_interval_mult": 0.8, "reaction_delay_sec": 0.7,
        "start_food": 350.0, "start_gold": 350.0
      }
    }
  }
}
```

- 难度只缩放：`income_mult`、`build_interval`、`production_interval`、`army_cap`、`reaction_delay`、初始资源。
- 不缩放单位攻击 / 血量；不额外送兵；不做全图视野。
- 所有键进 `config.gd` 的 `_cache_scalars()` / `_cache_ai()`（按项目规范，避免每帧 `num("a.b.c")`）。

### 5.2 经济

```text
pool = world.ai_faction_resources[faction]
income = world._accumulate_production(faction, false, tech_effects[faction])
income *= difficulty.income_mult
EconomyRes.tick(cfg, dt, income, pool)

available = max(0, pool - reserve)
float_excess = max(0, pool.food - max_float_food) + max(0, pool.gold - max_float_gold)
```

规则：

1. 低于 `reserve`：只允许「防守向」花费（补箭塔、修大本营、再起将领），停止招兵 / 升科技。
2. 高于 `max_float`：提高建造 / 升级 / 科技 / 特化权重，优先把钱花掉。
3. 生产预算：
   ```text
   budget = floor(min(
       available.food / avg_food_cost,
       available.gold / max(1, avg_gold_cost),
       army_cap - current_army,
       population_headroom
   ))
   ```
   `avg_*_cost` 用当前可招兵种的平均值；`population_headroom` 由将领所在区划人口与 `recruit_population_cost` 估算。
4. 所有扣费走现有 `world.start_recruit()` / `apply_build()` / `start_building_upgrade()` / `start_zone_specialize()`；AI 不自己扣钱，避免「账对不上」。
5. 资源池为 0 时不会卡死：AI 会先发展经济、升级、等收入，而不是每帧重试。

### 5.3 建造规划

候选与评分（硬约束先过滤）：

| 候选 | 硬约束 | 评分要点 |
|---|---|---|
| 升级大本营 | 有大本营、未满级、买得起、不在读条 | 基础分最高；2 级 / 3 级解锁招兵行与科技阶数，前期优先 |
| 建箭塔 | 己方区划、可建、买得起、未达 `tower_max` | 边境区（与敌方 / 中立区相邻）+ `tower_frontier_bonus`；基地周围至少 1 座 |
| 启用科技 | 大本营等级够、有空槽、未启用 | 按 `tech_priority`；经济发展期选产量 / 人口，军事期选血量 / 攻击 |
| 区划特化 | 己方区划、未特化、未在读条、买得起 | 粮食 / 黄金按当前缺口；人口区划优先人口特化 |
| 城墙（可选，默认关） | 同上；不能堵死自己的唯一通路 | 只在边境狭窄处；默认关闭，避免把 AI 自己关起来 |
| 扩张（不是建筑） | 有相邻可夺取区划 | 见 5.7；不算建造，但共用「战略候选」列表 |

地块选择（箭塔 / 城墙）：

1. 只在自己区划内，`world.can_build_at()` + `world.zone_allows_build()` 通过。
2. 避开区划中心格、大本营格、已有建筑、单位密集格。
3. 优先「靠近区划中心 / 靠近边境 / 周围有 2 格以上己方地块」的位置。
4. 用一个 `blocked_tiles` 黑名单记录被拒 / 会堵路的位置，避免每帧重试同一格。
5. 建塔后按 `building_revision` 重新评估；不每帧扫描全图。

执行：

```gdscript
CommandRes.apply(world, cfg, {
    "kind": "build", "build_type": "tower",
    "tx": tile.x, "ty": tile.y, "faction": faction
})
```

失败时记录 `build_rejected` 的 reason（`cost` / `not_in_zone` / `occupied_or_terrain`），按 `retry_sec` 冷却，不刷屏。

### 5.4 生产与编成

1. **可招兵种**：`world.recruit_list()` + `world.is_unit_recruitable()` + `world.unit_recruit_unlocked(faction, kind)`；按 `tier` 过滤。
2. **编成权重**：config `composition` 打底，再按可见敌方构成微调：
   - 敌方骑兵占比 > 35% → 长枪兵权重 +0.15；
   - 敌方远程占比 > 35% → 骑手 / 马弓手权重 +0.1；
   - 敌方箭塔 / 城墙 > 0 → 投石车权重 +0.1（只在 3 级大本营解锁后）；
   - 己方粮车为 0 且军队 ≥ 8 → 粮车权重 +0.05（最多 1 辆）。
3. **将领管理**（本作最关键的一条）：
   - 将领 = 兵营。军队出门时，**至少留一位将领在己方基地区划内**负责生产。
   - 若只有 1 位将领且指令是 `march` / `mass` / `expand`：
     - 先尝试在基地区划中心 `start_zone_recruit()` 招一位新将领（花 AI 池子的钱）；
     - 新将领出来前，生产暂停；出门的将领照常打仗。
   - 若所有将领都不在己方区划：把「离基地最近、没有交战」的那位召回；召回期间不招兵。
   - 将领濒死且 `revive_ready()`：`world.start_revive()`（花 AI 池子的钱，不免费）；再起读条期间不重复下单。
4. **队列**：每个将领最多同时排 `max_queue_per_leader` 个；优先补「编制缺口」而不是无脑堆兵。
5. **军队上限**：`army_cap` 按难度；达到上限后停止招兵，把钱转到升级 / 科技 / 特化 / 箭塔。
6. **重试**：被拒（`cost` / `population` / `tier` / `zone`）时按 `retry_sec` 冷却，换下一个候选，不每帧刷同一条。

### 5.5 军队与编队

**编队单位**：以「将领 + 其附属兵」为一队（`world.group_of(leader)` / `world.leader_of()`）。不把附属兵从将领身边拆走。

**军队层职责**：

```text
1. validate：清理死亡 / 无主 / 不可用引用
2. defense：基地 / 己方区划受威胁 → 计算回防队伍
3. directive：按当前指令决定「谁去哪、做什么」
4. issue：整队下命令（order_group_attack_move / move），去重
5. record：写 debug_state（目标、队伍、上次命令时间）
```

**命令去重**：

- 每队记录 `last_order_kind` / `last_target_tile` / `last_order_sec`。
- 同一队、同一目标、还在移动 / 还在打 → 不重发。
- 目标变了 / 队伍空闲 / 超过 `reissue_sec` 且不在目标半径内 → 重发。
- 重发用 `CommandProcessor.order_group_attack_move(world, cfg, group, pt)`（它已经处理队形、通行、招募锁）。

**驻守**：

- 到达目标半径后不再下新命令；让 `combat.gd` 的警戒 / 追击逻辑接管。
- 若整队被追出 `hold_radius`，下一次 army tick 把它拉回来。
- 不设 `hold_position=true`（那是驻防 AI 的语义）；用「不再下新命令 + 目标半径检查」实现。

**回防**：

- 每 `army_interval_sec` 检查一次：己方大本营 / 基地区划 / 目标区划是否受威胁。
- 威胁定义：可见敌方单位在 `threat_radius` 内，或区划中心正在被敌方占领读条。
- 回防比例：`recall_ratio`（默认 35%）；大本营血量 < `base_low_hp_ratio` 时全军回防。
- 回防有 `recall_cooldown`，避免一有风吹草动就全军折返。
- `march` 途中也回防；回防结束后继续原指令（目标点保留）。

### 5.6 目标选择（公平 + 战略价值）

**可选目标池**：

1. 可见敌方单位（`fog.unit_visible`）；
2. 当前可见 / 曾经见过的敌方建筑（`fog.known_buildings`）；
3. 敌方 / 中立区划中心（区划归属公开）；
4. 敌方大本营（如果已知）。

**评分**（只在 `auto` / `expand` / 回防里用；`march` / `mass` 用玩家指定点）：

```text
score =
    base_value(kind)                 # 大本营 > 区划中心 > 箭塔 > 普通单位
  + zone_value(zone)                # 产能 / 人口价值
  + adjacency_bonus                 # 与己方领土相邻
  - distance_penalty / map_diag
  - threat_penalty                  # 目标附近敌方军力过强
```

- 不做全图随机；不选「视野外且从未见过」的目标。
- 同一分时按 `zone_id` / 建筑 key / 单位 id 稳定排序。
- `expand` 优先「相邻中立区划」；没有相邻中立再打相邻敌方区划；都没有才打最近敌方大本营。
- `auto` 的推进目标 = 最近的敌方区划中心 / 大本营；若目标不可达（水域 / 被墙封死），换下一个。

### 5.7 扩张

```text
function EXPAND_TICK():
    candidates = []
    for zone in zones adjacent to my zones:
        if zone.owner is me or ally: continue
        if zone.center == null: continue
        candidates.append(zone with score)
    if candidates empty:
        target = nearest enemy zone center / enemy base
    else:
        target = best candidate
    army = field teams (exclude home general)
    if army.size < min_squad_units: wait / produce
    order_group_attack_move(army, center_of(target))
    if target.owner becomes my side:
        hold_sec += dt
        if hold_sec >= capture_hold_sec:
            next target after delay
```

- 读条需要单位站在中心 3×3；AI 的行军攻击到达后会自然停下打附近的敌人；若没有敌人，单位会在中心附近停住并读条。
- 拿下一块后，若买得起且是边境，建一座箭塔；然后找下一块。
- 不建新大本营（本作大本营不可建造）；「扩张」= 占地 + 前哨箭塔。

### 5.8 科技 / 升级 / 特化

- **大本营升级**：`develop` / `expand` 前期最高优先级；2 级解锁第 2 行兵种与 2 阶科技，3 级解锁第 3 行与 3 阶科技。
- **科技**：`ai.commander.build.tech_priority` 按 id 顺序尝试；`world.tech_can_activate(id, faction)` 通过才启用。默认优先级建议：
  1. 粮食 / 黄金产量类；
  2. 人口增长类；
  3. 建筑 / 将领血量类；
  4. 其余。
- **区划特化**：只对「己方、无特化、不在读条」的区划；按当前粮食 / 黄金 / 人口缺口选；优先基地区划与高产能区划。
- **将领再起**：见 5.4；费用从 AI 池子扣，不免费。

### 5.9 调试与指标

`world.ai_panel_state(faction)` 返回：

```gdscript
{
  "faction": "F2",
  "name": "红方",
  "kind": "commander",
  "directive": "march",
  "target": Vector2i(12, 8),
  "target_label": "行军至 (12, 8)",
  "army": 9,
  "army_cap": 16,
  "generals": 2,
  "food": 320.0,
  "gold": 280.0,
  "status": "补员中",       # 补员 / 建造 / 升级 / 行军 / 驻守 / 回防 / 缺粮
  "serial": 3,
  "reason": ""
}
```

可选调试覆盖层（默认关，config 开关）：

- 画 AI 目标点、当前扩张目标区划、军队集结点、回防点；
- 打印每 5 秒一次：指令 / 目标 / 军队数 / 资源 / 最近 3 条命令的接受情况；
- 计数器：`orders_issued` / `orders_rejected` / `path_failures` / `build_failures` / `recruit_failures`。

---

## 6. 四条指令的语义与状态机

### 6.1 指令表

| 指令 | 玩家输入 | 军队行为 | 生产 / 建造 | 结束 / 切换 |
|---|---|---|---|---|
| **行军** `march` | 点按钮 → 点地图选目标 | 全军（除留守将领）行军攻击到目标点；路上遇敌就打；到达后驻守；目标为敌方区划中心时尝试占领 | 正常补员；优先保证留守将领在基地 | 直到玩家换指令；目标丢失 / 不可达 → 原地驻守并提示 |
| **发展** `develop` | 点按钮（无需选点） | 不主动出击；军队留在基地区划 / 己方区划内；受威胁时回防 | 优先升级大本营、科技、特化、箭塔；军队上限用 `develop_army_cap`（`army_cap` 的 60%） | 直到玩家换指令 |
| **扩张** `expand` | 点按钮（无需选点） | 派 65% 军队（至少 4 人）去相邻可夺取区划中心；其余守家 | 补员；拿下后建前哨箭塔 | 直到玩家换指令；没有可扩张目标时转「打最近敌方基地」 |
| **屯兵** `mass` | 点按钮 → 点地图选集结点 | 全军行军攻击到集结点，到达后驻守；不主动扩张；受威胁时在集结点附近反击 | 补员到 `army_cap`；不建前哨 | 直到玩家换指令 |
| **自动** `auto` | 不出现在面板；给未来的 AI 对手用 | 发展 → 到时间 / 兵力阈值后扩张 → 打最近敌方基地 / 区划 | 同发展 / 扩张 | 仅当 commander 不是玩家盟友时作为默认 |

### 6.2 状态机

```text
                 ┌──────────────┐
                 │   develop    │◄──────── 玩家点「发展」
                 └──────┬───────┘
                        │ 玩家点「扩张」
                        ▼
                 ┌──────────────┐
                 │   expand     │
                 └──────┬───────┘
                        │ 玩家点「行军」/「屯兵」
                        ▼
              ┌────────────────────┐
              │  march / mass      │
              │  (需目标点)         │
              └─────────┬──────────┘
                        │ 目标完成 / 不可达 / 玩家换指令
                        ▼
                 回 develop / expand / 原地驻守
```

- **指令切换是即时的**：新指令覆盖旧指令；已经在执行的旧命令不会立刻取消（单位会走完当前路径），下一次 army tick 会按新指令重新下命令。
- **目标点校验**：`march` / `mass` 必须在地图内、可通行（`Pathfinder.passable`）；不可通行时拒绝并提示。
- **目标丢失**：如果目标格被建筑占住 / 地形变化，`march` 改为「最近可达点」，并提示。
- **军队被打光**：保持当前指令，重新招兵，攒够 `min_squad_units` 后再去目标；不自动改指令。
- **玩家没有下过任何指令**：AI 队友默认 `develop`；AI 对手默认 `auto`。

### 6.3 命令 schema

新增命令（走现有命令流）：

```gdscript
{
  "kind": "ai_order",
  "faction": "p1",          // 下单的玩家席位（防冒充；联机时客机必须是自己的席位）
  "ai_faction": "F2",       // 被指挥的 AI 阵营
  "order": "march",         // march / develop / expand / mass
  "x": 12.0,                // 仅 march / mass
  "y": 8.0
}
```

校验（`world.set_ai_directive()` 一处）：

1. `ai_faction` 存在、`ai_kind_of(ai_faction) == "commander"`、未被中立化；
2. `FactionRes.same_side_for_attack(ai_faction, faction)` 为真（只能指挥同方 AI）；
3. `order` 在允许集合内；`march` / `mass` 必须带合法坐标；
4. 目标格可通行、地图内；
5. 通过 → 写入 `world.ai_directives`，发 `ai_order_accepted`；失败 → 发 `ai_order_rejected`（带 reason，`faction` = 下单方，HUD 显示红字）。

事件示例：

```gdscript
{"type": "ai_order_accepted", "faction": "p1", "ai_faction": "F2", "order": "march",
 "target": Vector2i(12, 8)}
{"type": "ai_order_rejected", "faction": "p1", "ai_faction": "F2", "order": "march",
 "reason": "unreachable"}
```

---

## 7. 合作模式 AI 队友接入

### 7.1 大厅：二选一

在 `view/coop_lobby.gd` 的大厅态加一行「队友类型」：

```text
队友类型   [ 真人队友 ] [ AI 队友 ]
难度       [ 简单 ] [ 普通 ] [ 困难 ]     ← 仅 AI 队友时显示
地图       [ 边关 · 渡口 ] [ 双子防线 ] …  ← 现有合作地图列表
```

行为：

- **真人队友**：完全走现有流程（建房 / 加入 / 准备 / 开始）；一个字不改。
- **AI 队友**：不连接中继、不建房；选择地图与难度后直接「开始」。第二席位由 `commander` 接管。
- 模式在开局前锁定；AI 模式下不会再有真人加入（也不显示房间码 / 房间列表）。
- 选 AI 模式后如果之前已经连了服务器：先 `leave_room()` + 关闭 transport，再切模式。
- 默认难度「普通」；默认地图 = 当前合作地图列表第一项。

UI 可以复用现有席位卡：自己 = 房主，第二席位显示「AI 队友 · 普通」。地图选择沿用 `_open_map_select()` / `_map_cards`；难度用一个小的循环按钮（点一下切下一档），不必新做弹窗。

### 7.2 开局：本地 AI 合作局

新增入口（不经过 `HostSession`）：

```text
view/coop_lobby.gd
  signal solo_started(campaign_id, level_id, ai_setup)
        │
        ▼
view/menu_secondary_panel.gd → menu_chrome.gd → start_screen.gd
        │
        ▼
view/main.gd  _on_coop_solo_started(campaign_id, level_id, ai_setup)
        │  载入 campaign + level（与现有 _on_coop_host_started 同一段）
        ▼
view/game_scene3d.gd  start_coop_solo(level, ai_setup)
```

`start_coop_solo`：

```gdscript
cfg = ConfigRes.load_default()
seats = level.coop_roster()                  # [F1, F2]
host_seat = String(seats[0])
ai_seat = String(seats[1])
overrides = {ai_seat: LevelRes.AI_COMMANDER}
profiles = {ai_seat: {"difficulty": ai_setup.get("difficulty", "normal")}}
world = WorldRes.create_from_level(cfg, level, host_seat, seats, true, overrides, profiles)
_assemble()
coop_role = "solo"                            # 不建 HostSession，不连 transport
coop_level = level
_disable_coop_pause()
```

- `World.create_from_level()` 增加两个可选参数：`ai_overrides: Dictionary = {}`、`ai_profiles: Dictionary = {}`；在 `reset()` 之前写到 `world.ai_kind_overrides` / `world.ai_profiles`。现有调用不传，行为不变。
- `world.ai_kind_of(faction)` 增加一条：** override 优先**（在 `neutralized` 判断之后、`ai_roster_cfg` 之前）。
- `start_coop_host()`（真人队友）保持原签名与原逻辑；它不传 override，所以第二席位仍是玩家。
- `coop_role == "solo"` 时：
  - 不建 `HostSession` / `ClientSession`；
  - `world.tick()` 照常跑；
  - `_shutdown_coop()` 跳过 session / transport；
  - `return_to_menu` / 结算流程与现有合作局一致。

### 7.3 世界装配：AI 队友拿到什么

| 项目 | 现状 | AI 队友模式 |
|---|---|---|
| 第二席位基地 | 合作关 `players[].base` / 地图 `faction_bases` | 不变，照建 |
| 第二席位开局部队 | 合作关 `start_units`（将领 + 附属兵） | 不变，照建，交给 AI 控制 |
| 第二席位资源池 | `player_resources[F2]` + 每秒收入 | **改用 `ai_faction_resources[F2]`**；收入走 5.2；玩家 HUD 不读它 |
| 第二席位是否算玩家 | `player_seats` 有、`player_factions` 有 | `player_seats` 有、`player_factions` **没有**（因为是 AI 接管） |
| 目标 `defend` | 两个席位都算 | 只算 F1；AI 队友的基地丢了**不判负**（只是少一个帮手） |
| 迷雾 | `side_of` 共享 | 不变，AI 与玩家共享视野 |
| 阵营关系 | 合作关 `allies` | 不变；`ai_order` 用 `same_side_for_attack` 校验 |
| 暂停 | 合作局禁用 | 不变 |

**`resource_pool_for()` 的优先级**：

```gdscript
func resource_pool_for(faction: String) -> Variant:
    if _is_commander_ai(faction):
        return ai_faction_resources.get(faction, null)   # 有自己的池子
    if player_seats.has(faction):
        ...                                              # 现有玩家池
    return null                                          # garrison/reddot = 无限
```

`_reset_player_pools()` 仍为两个席位建池（保持现有测试与快照兼容），但 AI 队友的池子不会被使用；`resource_pool_for` 优先返回 AI 池。

**收入循环**：

- `world.tick()` 在现有玩家席位经济之后，遍历 `commander_factions()`：
  - `rate = _accumulate_production(fid, false, seat_tech_effects[fid])`
  - `rate *= profile.income_mult`
  - `EconomyRes.tick(cfg, dt, rate, ai_faction_resources[fid])`
- `_refresh_seat_tech_effects()` 的 `seats` 列表加上 `commander_factions()`，保证 AI 启用的科技效果真的落到它的建筑 / 单位 / 产量上。

**基地兜底**：

- `apply_faction_layout()` 的 `with_base` 改成 `player_factions.has(f) or _is_commander_ai(f)`。
- 合作关本来就给第二席位建基地；这个改动是给未来的「AI 对局」兜底，也让 AI 队友在数据异常时仍有一个家。
- `spawn_faction_units()`：如果某 commander 阵营在 `_apply_level_placement()` 之后一个单位都没有（例如关卡没摆），补一位 `create_generals()` 的 #0 将领；正常合作关有 `start_units`，不会触发。

### 7.4 指令链路（单机 / 未来联机）

单机 AI 合作局：

```text
AI 面板按钮
  → view/ai_order_panel.gd 发出 order_requested(order, ai_faction)
  → view/game_scene3d.gd 组装 {kind:"ai_order", faction:my_faction, ai_faction, order, x, y}
  → command_processor.apply()
  → world.set_ai_directive()
  → CommanderAI 下一次 army tick 读取
```

未来联机（真人房主 + AI 队友，或客机也想指挥）：

- 房主侧跑 CommanderAI；客机只收快照。
- 客机的面板同样可以发 `ai_order`；`host_session` 已有校验要求 `cmd.faction == guest_seat`，所以命令里的 `faction` 是客机自己的席位，`ai_faction` 是 AI 队友；`world.set_ai_directive` 用 `same_side_for_attack` 校验同方即可。
- 本轮不做「真人 + AI 队友同时存在」，但这条链路天然支持；以后放开时不需要改协议。

### 7.5 快照与事件

`logic/snapshot.gd` 新增两个短字段：

| 字段 | 内容 | 用途 |
|---|---|---|
| `aid` | `{faction: {"k": "march", "x": 12.0, "y": 8.0, "s": 3, "t": 123.4}}` | 客机面板显示当前指令 / 目标 / 序号 |
| `air` | `{faction: {"food": 320.0, "gold": 280.0}}` | 客机面板显示 AI 资源 |

- `to_snapshot()`：只发 commander 阵营，按 faction 排序；`x/y` 用 float。
- `apply_snapshot()`：写 `world.ai_directives` / `world.ai_faction_resources`；缺字段 = 保持现状（现有约定）。
- 客机不创建 `ai_commanders`；面板的军队数量从 `world.units` 现算。
- 事件 `ai_order_accepted` / `ai_order_rejected` 的所有字段都是基本类型，`event_codec` 无需改动。
- `game_interaction.gd` 增加一条：`ai_order_rejected` → `hud.show_notice("AI 队友无法执行：…")`；`ai_order_accepted` 可以只在面板状态里体现，不刷红字。

### 7.6 面板可见性

- `world.ai_teammates_for(my_faction)` 返回「与 `my_faction` 同方、`ai_kind == commander`」的阵营列表。
- 面板只在列表非空时创建 / 显示；传统真人合作局没有 commander，面板不存在。
- 单人战役 / 自由对战也不显示（本轮没有 commander）。
- 如果未来 AI 对手模式：玩家与 AI 不同方，列表为空，不显示。

---

## 8. 浮动面板 UI/UX

### 8.1 版式

```text
┌──────────────────────────────────┐
│ AI 队友 · 红方                 ▾ │  ← 标题栏可拖动 / 点击折叠
├──────────────────────────────────┤
│ [ 行军 ] [ 发展 ] [ 扩张 ] [ 屯兵 ] │  ← 2×2 或 1×4，当前指令高亮
├──────────────────────────────────┤
│ 指令  行军至 (12, 8)              │
│ 部队  9 / 16                      │
│ 资源  粮 320 · 金 280             │
│ 状态  补员中 / 建造箭塔           │
└──────────────────────────────────┘
```

- 默认位置：右上角设置按钮下方，离右缘 16px、离顶 96px；宽 320、高 190（按 1920×1080 设计稿）。
- 可拖动：按住标题栏拖；位置只存在本地（`view/ai_order_panel.gd`），不进快照。
- 可折叠：点标题栏右侧箭头；折叠后只剩一条 40px 高的标题条，避免挡视线。
- 当前指令按钮：琥珀金描边 + 实心淡底（与「选中科技」同一套视觉语言，不新造颜色）。
- 资源行只在权威侧显示真实数字；客机显示快照值；没有数据时显示「—」。
- 手机端：宽 260、高 168；按钮最小 44×44；默认放在右上但避开设置按钮；拖动用触摸。
- 面板 `mouse_filter = STOP`；`hud.point_hits_ui()` 包含它，避免点面板时相机滚屏 / 缩放。

### 8.2 按钮行为

| 按钮 | 行为 |
|---|---|
| 行军 | 进入「选点模式」；面板提示「点击地图选择行军目标」；左键点地图 → 发 `ai_order(march, x, y)`；右键 / Esc 取消 |
| 发展 | 立即发 `ai_order(develop)`；不需要选点 |
| 扩张 | 立即发 `ai_order(expand)`；不需要选点 |
| 屯兵 | 进入「选点模式」；提示「点击地图选择集结点」；左键点地图 → 发 `ai_order(mass, x, y)`；右键 / Esc 取消 |

- 选点模式复用 `view/input_controller.gd` 的 `order_mode`：
  - 新增 `ai_march_pick` / `ai_mass_pick` 两个模式；
  - `begin_ai_order_pick(order, ai_faction)`；
  - 左键点击时发 `command_issued`（`kind = "ai_order"`），而不是对选中单位下命令；
  - 与现有建造 / 移动 / 攻击模式互斥；进入时清掉当前选中单位的命令模式。
- 选点过程中在鼠标位置画一个淡色圆环（覆盖层），确认后消失。
- 命令被拒时：面板状态行显示红字原因 2 秒，并走 `hud.show_notice`；不弹模态框。

### 8.3 地图标记

- 在 `view/overlay_view_3d.gd` 增加 `ai_target_marks`：
  - 当前 commander 的指令目标点画一个**友军色（黄）的细圆环 + 小旗**；
  - 目标区划中心画一个更淡的方框；
  - 只在面板可见 / 玩家选中 AI 队友时显示，避免长期遮挡地图；
  - 目标变化时更新，位置不变时只重提绘制命令（与现有覆盖层缓存同一套）。
- 可选：行军途中用一条虚线连到目标（默认关，避免画面太乱）。

### 8.4 提示文案

- 行军：`AI 队友已接受：行军至 (x, y)`；到达：`AI 队友已抵达行军目标`。
- 发展：`AI 队友已转为发展`。
- 扩张：`AI 队友开始扩张`；拿下：`AI 队友已占领 <区划名>`。
- 屯兵：`AI 队友开始在 (x, y) 集结`。
- 拒绝：`无法指挥该 AI（不是你的队友）` / `目标点不可到达` / `AI 队友已倒下`。
- 文案全部放 `data/config.json` 的 `ui.ai_panel.*`，不在 view 里写死中文。

---

## 9. 数据与配置

### 9.1 新增 config 段

- `ai.commander.*`：见 5.1。
- `ui.ai_panel.*`：面板几何 / 颜色 / 文案 / 折叠尺寸。
- `coop.lobby.ai_teammate.*`：默认难度、按钮文案、模式提示。

建议默认值（设计稿，最终以实机调参为准）：

```json
"ui": {
  "ai_panel": {
    "width": 320.0,
    "height": 190.0,
    "margin_right": 16.0,
    "margin_top": 96.0,
    "collapsed_height": 40.0,
    "mobile_width": 260.0,
    "mobile_height": 168.0,
    "font_size": 15,
    "title_font_size": 18,
    "button_gap": 6.0,
    "target_pick_hint": "点击地图选择目标",
    "buttons": {
      "march": "行军",
      "develop": "发展",
      "expand": "扩张",
      "mass": "屯兵"
    }
  }
}
```

### 9.2 关卡 / 地图字段（本轮只增加读取，不要求现有数据填写）

- `factions[].ai = "commander"`：让某一方挂指挥官 AI。
- `factions[].commander_ai = { "difficulty": "normal", ... }`：按阵营覆盖。
- 未来自定义对战会用到；本轮合作 AI 队友通过 `ai_kind_overrides` 设置，不必改关卡 JSON。

`logic/level.gd`：

- 新增 `AI_COMMANDER := "commander"`；
- `_ai_kind()` 接受 `"commander"`；
- `_read_level_factions()` 透传 `commander_ai`；
- `merged_ai_factions()` 把 `commander_ai` 带进名单；
- `world._ai_cfg_with_override()` 支持用 `commander_ai` 覆盖默认参数（与 `garrison_ai` / `reddot_ai` 同一个白名单式合并）。

### 9.3 不改的现有数据

- 现有 `data/maps/*` 一个字不改；
- 现有 `data/campaigns/*` 一个字不改；
- 现有 `ai.factions`（garrison/reddot）不动；
- 现有 `garrison` / `reddot` 参数不动。

---

## 10. 文件级改动清单

### 10.1 新增文件

| 文件 | 内容 |
|---|---|
| `logic/ai_commander.gd` | 指挥官控制器：Profile、调度器、指令状态机、对外 `setup/update/debug_state/panel_state` |
| `logic/ai_economy.gd` | 收入 / 预算 / reserve / float / 可负担判断（纯函数 + 小状态） |
| `logic/ai_build.gd` | 建造 / 升级 / 科技 / 特化候选与评分；地块选择 |
| `logic/ai_army.gd` | 编队、行军、驻守、扩张、回防、目标选择 |
| `logic/ai_profile.gd` | 难度包与 config / 关卡覆盖的合并（纯函数） |
| `view/ai_order_panel.gd` | 浮动面板：4 按钮、状态、拖动、折叠、选点提示 |
| `tests/test_ai_commander.gd` | 经济 / 生产 / 建造 / 科技 / 指令 / 确定性单测 |
| `tests/test_ai_directives.gd` | 四条指令的行为与切换、拒绝原因 |
| `tests/test_coop_ai_teammate.gd` | 大厅二选一、`start_coop_solo`、世界装配、快照 |
| `tests/test_ai_order_panel.gd` | 面板几何 / 按钮 / 选点 / 折叠 / 手机布局 |

### 10.2 修改文件

| 文件 | 改动 |
|---|---|
| `logic/world.gd` | `ai_kind_overrides` / `ai_profiles` / `ai_directives` / `ai_faction_resources` / `ai_commanders`；`create_from_level()` 可选参数；`ai_kind_of()` override；`resource_pool_for()`；收入循环；`apply_faction_layout()`；`_refresh_seat_tech_effects()`；`tick()` 调 CommanderAI；`set_ai_directive()` / `ai_directive_of()` / `ai_panel_state()` / `ai_teammates_for()`；`reset()` 清理与初始化 |
| `logic/command_processor.gd` | `"ai_order"` 分支；转发到 `world.set_ai_directive()` |
| `logic/snapshot.gd` | `aid` / `air` 的写入与回读 |
| `logic/level.gd` | `AI_COMMANDER`；`_ai_kind`；`commander_ai` 透传；`merged_ai_factions` |
| `logic/config.gd` | `ai.commander` / `ui.ai_panel` / `coop.lobby.ai_teammate` 的缓存与访问器 |
| `logic/objective.gd` | 本轮只确认不误判 AI 队友（`defend` 用 `player_factions`，已成立）；不新增目标类型 |
| `view/game_scene3d.gd` | `start_coop_solo()`；AI 面板装配与显示；`ai_order` 命令组装；AI 目标标记；`_shutdown_coop()` 兼容 solo |
| `view/main.gd` | `_on_coop_solo_started()`；载入关卡并调 `start_coop_solo` |
| `view/start_screen.gd` / `menu_chrome.gd` / `menu_secondary_panel.gd` | 把 `coop_lobby.solo_started` 冒泡到 `main.gd` |
| `view/coop_lobby.gd` | 队友类型二选一；AI 难度；AI 模式本地开始；AI 模式不连中继 |
| `view/hud.gd` | 创建 / 定位 / 刷新 AI 面板；`point_hits_ui` / `blocks_wheel_zoom` / `handle_touch` 纳入面板 |
| `view/input_controller.gd` | `ai_march_pick` / `ai_mass_pick` 模式；`begin_ai_order_pick()`；点击发 `ai_order` 命令 |
| `view/overlay_view_3d.gd` | AI 指令目标环 / 旗帜 / 可选的扩张目标框 |
| `view/game_interaction.gd` | `ai_order_rejected` → 红字提示 |
| `data/config.json` | 新增 `ai.commander` / `ui.ai_panel` / `coop.lobby.ai_teammate` |
| `README.md` / `ai_doc/README.md` / `ai_doc/ai-commander-current-status.md` | 完成后补「AI 指挥官 / 合作 AI 队友」的现状与索引；本文只保留设计稿 |

> 说明：`logic/ai_*.gd` 按项目风格放在 `logic/` 扁平目录，文件名 snake_case，不写 `class_name`，跨文件引用用 preload 常量。如果实现时觉得 5 个文件太碎，可以合并成 3 个（controller / economy+build / army），但职责边界不要混。

---

## 11. 分阶段实施计划

### M1 · 指挥官骨架 + 经济 + 发展

**做**：

- `commander` AI 类型、world 字段、`ai_kind_overrides`、`resource_pool_for`；
- AI 资源池、收入、初始资源、`_refresh_seat_tech_effects` 纳入 commander；
- 控制器骨架（计时器、状态、`debug_state`）；
- `develop`：守家、补员、升级大本营、科技、特化、箭塔；
- 基础回防。

**验收**：

- 用合作关 `02_twin_line` + AI 队友开局，AI 第二席位有基地、将领、资源、收入；
- 60 秒内：AI 招出至少 3 个单位、大本营开始升级或已升级、没有负资源、没有非法命令；
- 现有 `test_ai` / `test_campaign_ai` / `test_coop_*` 全绿（没有 commander 时行为不变）。

### M2 · 四条指令 + 军队

**做**：

- `world.set_ai_directive()` / `ai_directive_of()` / `ai_panel_state()`；
- `ai_order` 命令与事件；
- `march` / `mass` / `expand` / `develop` 状态机；
- 编队、行军攻击、驻守、回防；
- 留守将领管理、再起；
- 确定性随机与命令去重。

**验收**：

- 面板还没做时，用命令直接驱动：`march` 到点、`mass` 集结、`expand` 拿下一块中立区、`develop` 不出击；
- 指令切换即时生效；非法目标 / 不同方 AI 被拒；
- 同一 `rand_salt` 跑两遍，指令序列 hash 一致。

### M3 · 合作大厅 + 浮动面板

**做**：

- 大厅「真人 / AI」二选一 + 难度 + 本地开始；
- `start_coop_solo` + main 信号链；
- `view/ai_order_panel.gd`；HUD 装配；输入选点模式；目标标记；
- 快照 `aid` / `air`（为未来联机预留，也方便测试）。

**验收**：

- 主界面 → 合作模式 → AI 队友 → 选图 → 开始，能进合作关；
- 面板四个按钮可用；行军 / 屯兵点地图能下达；发展 / 扩张一键下达；
- 面板可拖动 / 折叠；不挡住底部命令卡；手机布局不重叠；
- 真人队友路径完全不变（现有 `test_coop_lobby` / `test_coop_entry` 全绿）。

### M4 · 扩张 + 建造 / 科技 / 特化完善

**做**：

- `expand` 的相邻区划选择、分队、读条、前哨箭塔；
- 建造评分完善（边境 / 缺口 / 黑名单）；
- 科技优先级、区划特化选择；
- 回防优先级与低血量全军回防；
- AI 资源浮存控制。

**验收**：

- 合作关 3 分钟内，AI 能拿下至少一块中立区划并建起前哨箭塔；
- AI 大本营能到 2 级（普通难度）；资源不长期爆仓；
- 玩家基地被攻击时，AI 会回防（不要求百发百中，但要有可观察的折返）。

### M5 · 打磨 / 性能 / 回归

**做**：

- 难度三档调参；
- AI 调试覆盖层（开关）；
- 性能：AI tick 在 200 单位 / 3 个 commander 下 < 1ms（目标，实测再调）；
- 移动端适配；
- 文档与手玩清单；
- 全量回归 + 语法检查。

**验收**：

- `tools/run-tests.ps1` 全绿（含新增套件）；
- `tools/check-syntax.ps1` 全绿；
- 手玩清单逐条通过；
- 没有 commander 的旧局行为逐位不变（关键回归）。

### M6 · 未来自定义对战（本轮不做，只列接口）

- 房间 UI / 基地槽位分配 / 歼灭胜负；
- `ai_kind = commander`、`auto` 模式、难度包、资源池已经就绪；
- 预计只需新增 `logic/skirmish_setup.gd` + `view/skirmish_lobby.gd` + `objective` 的 `annihilation` 类型，不改 AI 本体。

---

## 12. 测试计划

### 12.1 单元测试（新增）

`tests/test_ai_commander.gd`：

1. **创建**：`ai_kind_overrides` 把第二席位变成 commander；`ai_commanders` 有且只有一个；资源池存在；基地 / 将领存在。
2. **经济**：收入按区划产能 × 难度倍率；扣费只走世界接口；资源不为负；reserve / max_float 生效。
3. **生产**：只招已解锁兵种；军队上限 / 人口 / 队列上限生效；将领不在己方区划时不招；留守将领逻辑（只有 1 位将领时先招新将领）。
4. **建造**：大本营升级优先；箭塔只在己方区划；被占地块 / 无钱时不建；失败进入冷却。
5. **科技 / 特化**：只启用可启用的；槽位满了不启用；特化只对己方未特化区划。
6. **再起**：濒死且 ready → `start_revive`；费用从 AI 池扣。
7. **确定性**：固定 `rand_salt` + 固定初始状态，跑两次 120 秒，`debug_state()` 的指令序列 / 目标序列 hash 一致。

`tests/test_ai_directives.gd`：

1. 默认 `develop`；AI 对手默认 `auto`（用一个手工构造的敌对 commander 测试）。
2. `march`：命令接受、目标写入、军队行军到点、到达后不再推进。
3. `mass`：命令接受、军队集结到点、不扩张。
4. `expand`：选中相邻中立区、派分队、读条、归属翻转、下一目标。
5. `develop`：不主动离开基地区划；受威胁回防。
6. 指令切换：march → develop 立即改变行为；旧路径不导致卡死。
7. 拒绝：不同方 / 非 commander / 非法坐标 / 地图外；事件 reason 正确。
8. 目标丢失 / 不可达：原地驻守 + 提示，不崩溃。

`tests/test_coop_ai_teammate.gd`：

1. 大厅 AI 模式：不连中继；难度默认普通；开始信号带 `ai_setup`。
2. `start_coop_solo`：世界两个席位；第二席位 `ai_kind == commander`；`player_factions` 只有第一席位。
3. 目标 `defend` 只含第一席位；AI 基地被拆不判负（用 `force_outcome` 之前的 `objective_state` 检查）。
4. `ai_order` 从房主席位发出 → 接受；从第二席位（AI）发出 → 拒绝；从不同方 → 拒绝。
5. 快照 `aid` / `air` 往返：客机式应用后 `ai_directive_of` 一致；缺字段不炸。
6. 真人队友路径：`start_coop_host` 不受影响（回归）。

`tests/test_ai_order_panel.gd`：

1. 面板只在有 commander 队友时存在；没有时不建。
2. 四个按钮文本 / 顺序 / 当前指令高亮。
3. 行军 / 屯兵进入选点；点地图发 `ai_order`；右键 / Esc 取消。
4. 发展 / 扩张一键发命令，不进入选点。
5. 拖动标题栏改变位置；折叠 / 展开尺寸。
6. 1920×1080 与手机尺寸下不与底栏 / 小地图 / 设置按钮重叠。
7. `hud.point_hits_ui` / `blocks_wheel_zoom` 包含面板。

### 12.2 集成 / 场景

- **合作关 02_twin_line + AI 队友**（无头跑 120~180 秒）：
  - AI 有基地 / 收入 / 招兵 / 升级；
  - 依次下达四条指令，观察状态与单位位置；
  - 记录 `orders_rejected` / `build_failures` / `path_failures`，应接近 0。
- **低资源 / 无中立区 / 单将领**：AI 不崩溃、不卡死、不无限重试。
- **AI 队友基地被拆**：AI 中立化、面板状态变为不可用、玩家不判负。
- **真人合作回归**：现有 `test_coop_*` 全绿。

### 12.3 回归

- `powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1`
- `powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1`
- 现有 7494 项断言全绿；新增套件计入总数。
- 重点回归：`test_ai` / `test_ai_target` / `test_campaign_ai` / `test_coop_seats` / `test_coop_objective` / `test_coop_game_scene` / `test_snapshot_coop` / `test_protocol` / `test_session`。

### 12.4 手玩验收清单

- [ ] 主界面 → 合作模式 → 选「AI 队友」→ 选「边关 · 渡口」→ 普通 → 开始，能进关。
- [ ] 第二席位有基地、部队；AI 会自己招兵 / 升级 / 建塔。
- [ ] 点「发展」：AI 不出击，基地附近有兵；会补员。
- [ ] 点「行军」→ 点地图：AI 全军开过去，路上遇敌就打，到点停下驻守；地图上有目标环。
- [ ] 点「扩张」：AI 去相邻中立区，读条占下；拿下一块后继续找下一块。
- [ ] 点「屯兵」→ 点地图：AI 集结到该点并停下，不主动扩张。
- [ ] 玩家基地被攻击：AI 会回防。
- [ ] 面板可拖动、可折叠；不挡命令卡；手机横屏能点。
- [ ] 选「真人队友」：现有建房 / 加入 / 准备流程与之前完全一样。
- [ ] 没有 AI 队友时（战役 / 自由对战）：看不到面板，行为不变。

---

## 13. 风险与兼容性

| 风险 | 影响 | 缓解 |
|---|---|---|
| AI 改动波及现有 garrison / reddot | 旧地图 / 战役行为变化 | 所有新逻辑都按 `ai_kind == commander` 分支；旧路径不碰；全量回归 |
| `player_seats` / `player_factions` 混用 | AI 队友被算成玩家（目标 / 判负 / 钱包） | 第二席位 override 为 commander → `player_factions` 自动排除；`defend` 只认 `player_factions`；测试钉住 |
| AI 队友抢玩家的钱 | 玩家资源被扣 | `resource_pool_for` 对 commander 优先返回 AI 池；AI 的招募 / 建造 / 升级全带 `faction` |
| AI 经济太强 / 太弱 | 合作体验差 | 难度参数包只改收入 / 节奏 / 上限；先在 02_twin_line 上手玩调 |
| 单将领出门导致停产 | AI 后续不补兵 | 留守将领机制 + 区划招将；测试「只有 1 位将领 + march」 |
| AI 卡在不可达目标 | 站着发呆 | `Pathfinder.passable` 预检 + 失败换目标 + 超时回退 |
| AI 每帧重下命令 | 单位抖动 / 性能 | 去重 + `reissue_sec` + 只在目标变化 / 空闲时重发 |
| 面板挡操作 / 手机重叠 | 手感差 | 可拖动 / 折叠；几何进 config；手机单独尺寸；测试重叠 |
| 快照新增字段破坏客机 | 联机异常 | 缺字段 = 保持现状（现有约定）；`apply_snapshot` 只写两个字典；测试往返 |
| 确定性漂移 | 回放 / 测试不稳 | 固定种子 + 稳定排序 + 不用引擎 RNG；测试 hash |
| 未来自定义对战改 AI 本体 | 返工 | 现在就保留 `auto`、难度包、公平视野、基地兜底；未来只补外围 |
| 性能 | 大兵团卡顿 | AI 0.6s / 2s 分层；候选数量小；不每帧全图扫描；实测再调 |

### 兼容性承诺

1. `with_ai == false` 的世界：`ai_commanders` 为空、`ai_directives` 为空、`ai_faction_resources` 为空；现有测试行为不变。
2. 没有 `commander` 的局：`resource_pool_for` 对非玩家席位仍返回 `null`；garrison/reddot 仍免费；`_refresh_seat_tech_effects` / `_refresh_production` 的席位列表不变。
3. 真人合作局：`start_coop_host` 不传 override；第二席位仍是玩家；HUD / 目标 / 钱包逻辑不变。
4. 现有 `config.json` 缺 `ai.commander` 段时：`config.gd` 用代码默认值兜底（与现有 `ai.garrison` / `ai.reddot` 同一套宽容读取），不崩。
5. 现有地图 / 关卡数据不改；新增字段全部可选。

---

## 14. 未来自定义对战（本轮只设计，不实现）

> 你的口径：本轮只需要把 AI 做出来；自定义对战房间以后再做。下面是「AI 已经为它准备了什么」和「以后还要补什么」，避免将来返工。

### 14.1 已经具备

- `commander` AI 类型与 `ai_kind_overrides`；
- 独立资源池 + 收入；
- 大本营 / 将领 / 招兵 / 升级 / 科技 / 特化 / 箭塔；
- `auto` 战略模式（发展 → 扩张 → 进攻）；
- 难度参数包；
- 公平视野；
- 命令层 / 快照 / 确定性；
- `ai_order` 可选（未来 AI 对手不听玩家，但接口在）。

### 14.2 以后要补

1. **基地槽位分配**：地图目前只给 p1/p2 基地。未来需要一个 `logic/skirmish_setup.gd`：
   - 先用地图 `faction_bases` 的现有槽位；
   - 不够时，在地图边缘 / 现有基地最远点生成候选槽位（要求可通行、不同区划、避开区划中心 / 建筑）；
   - 按「与已有基地的最小距离最大」贪心分配，确定性排序；
   - 每个 AI 一个大本营 + 一个基地区划。
2. **歼灭胜负**：`objective.gd` 增加 `annihilation`：
   - 胜利 = 所有敌对阵营大本营被拆；
   - 失败 = 玩家席位大本营被拆（现有常开规则）；
   - `objective_state.enemies` 在 setup 时写入；
   - 不要求新增关卡 / 战役数据。
3. **自定义房间 UI**：`view/skirmish_lobby.gd`，入口可以挂在主界面左侧「自定义」按钮（当前是空面板）。
   - 地图列表（`map_library`，排除 `hidden`）；
   - AI 数量 1~3（玩家 + 最多 3 AI）；
   - 每个 AI 的难度；
   - 开始 → 构造一个内存 `Level`（`mode: "skirmish"`）→ `World.create_from_level()`。
4. **玩家 + AI 的队伍关系**：本轮不做；未来可加 `allies` 生成 / 队伍 UI。

### 14.3 不建议现在做的事

- 不要为了「以后可能用」先写 `skirmish_lobby.gd` / 基地槽位分配 / `annihilation`：没有 UI 与数据，代码只会变成死代码，且会被现有测试忽略。
- 不要把 commander 硬编码进 `config.ai.factions`：那会让现有自由对战 / 战役多出一个会经营的 AI，破坏平衡与回归。
- 不要改 `garrison` / `reddot` 的经济语义：它们「没有资源库」是现有地图与战役的设计前提。

---

## 15. 需要你确认的点

请逐条确认；有异议我按你的口径改计划，再开始动代码。

1. **范围**：本轮只做「AI 指挥官 + 合作模式 AI 队友（第二席位，二选一）」，不做自定义对战房间；AI 本体按「未来可当对手」设计（`auto` / 难度 / 公平视野）。
2. **AI 队友的基地与经济**：AI 队友使用第二席位现成的基地 / 开局部队，并拥有**独立**资源池（不与玩家共用）；第二席位不再算「玩家的家」（它的基地丢了不判负）。
3. **四条指令**：行军 = 行军攻击 + 到点驻守；发展 = 守家 / 补员 / 升级 / 科技 / 特化 / 箭塔；扩张 = 相邻区划逐个占；屯兵 = 玩家选集结点后全军集结驻守。
4. **面板**：右上角浮动面板，可拖动 / 折叠，四个按钮，行军 / 屯兵需要点地图选点；只在有 AI 队友时出现。
5. **AI 不作弊**：默认公平视野，不读全图；难度只改收入 / 节奏 / 上限 / 反应延迟，不改单位数值。
6. **不改旧数据**：现有地图 / 战役 / garrison / reddot 配置不动；旧局行为逐位不变。
7. **验收**：现有 78 套 / 7494 项断言全绿 + 新增 AI / 面板 / 合作 AI 队友套件全绿 + 手玩清单通过。

确认后我按 M1 → M5 顺序实施；每个里程碑先跑测试再进入下一阶段。

---

## 附录 A · 关键代码位置速查

| 主题 | 文件 |
|---|---|
| 世界容器 / tick / 经济 / AI 名单 | [`logic/world.gd`](../dev_gd_a/daeem/logic/world.gd) |
| 命令唯一入口 | [`logic/command_processor.gd`](../dev_gd_a/daeem/logic/command_processor.gd) |
| 关卡 / AI 类型 / 合并 | [`logic/level.gd`](../dev_gd_a/daeem/logic/level.gd) |
| 目标与胜负 | [`logic/objective.gd`](../dev_gd_a/daeem/logic/objective.gd) |
| 阵地性 AI | [`logic/garrison_ai.gd`](../dev_gd_a/daeem/logic/garrison_ai.gd) |
| 红点性 AI | [`logic/red_dot_ai.gd`](../dev_gd_a/daeem/logic/red_dot_ai.gd) |
| 阵营 / 盟友 | [`logic/faction.gd`](../dev_gd_a/daeem/logic/faction.gd) |
| 区划占领 | [`logic/zone.gd`](../dev_gd_a/daeem/logic/zone.gd) |
| 迷雾 | [`logic/fog.gd`](../dev_gd_a/daeem/logic/fog.gd) |
| 快照 | [`logic/snapshot.gd`](../dev_gd_a/daeem/logic/snapshot.gd) |
| 配置缓存 | [`logic/config.gd`](../dev_gd_a/daeem/logic/config.gd) |
| 合作大厅 | [`view/coop_lobby.gd`](../dev_gd_a/daeem/view/coop_lobby.gd) |
| 主流程 | [`view/main.gd`](../dev_gd_a/daeem/view/main.gd) |
| 游戏内场景 | [`view/game_scene3d.gd`](../dev_gd_a/daeem/view/game_scene3d.gd) |
| HUD | [`view/hud.gd`](../dev_gd_a/daeem/view/hud.gd) |
| 输入 | [`view/input_controller.gd`](../dev_gd_a/daeem/view/input_controller.gd) |
| 3D 覆盖层 | [`view/overlay_view_3d.gd`](../dev_gd_a/daeem/view/overlay_view_3d.gd) |
| 测试脚手架 | [`tests/test_case.gd`](../dev_gd_a/daeem/tests/test_case.gd) |

## 附录 B · 与 RW 规范的对应章节

| 本文 | RW 规范 |
|---|---|
| 4.3 每 tick 顺序 | Part II 12.2 |
| 5.1 难度 | Part II 15.9 |
| 5.2 经济 | Part II 15.3 / Part I 3 |
| 5.3 建造 | Part II 15.2 / Part I 3.2 |
| 5.4 生产 | Part II 15.3 / Part I 3.3~3.5 |
| 5.5 军队 | Part II 15.4~15.5 / Part I 5 |
| 5.6 目标 | Part II 15.8 / Part I 7 |
| 5.7 扩张 | Part II 15.2 / Part I 4.5 |
| 5.9 调试 | Part II 16.10 |
| 6 指令 | Part II 15.5 的本地化 |
| 12 测试 | Part II 19 |
| 13 风险 | Part II 21 |
| 14 未来 | Part II 16.1~16.9 |

---

## 16. 实施记录（2026.10.24）

### 16.1 已落地

| 里程碑 | 内容 | 主要文件 |
|---|---|---|
| M1 | `commander` 类型 / 配置合并 / 独立资源池 / 收入 / 大本营 / 基础控制器 / 生产 / 建造 / 科技 / 特化 / 箭塔 | `logic/ai_profile.gd`、`ai_economy.gd`、`ai_build.gd`、`ai_commander.gd`、`world.gd`、`config.gd`、`level.gd` |
| M2 | `ai_order` 命令；行军 / 发展 / 扩张 / 屯兵四条状态机；回防 / 留守将领 / 军队编组 / 目标缓存 | `logic/command_processor.gd`、`logic/ai_army.gd`、`logic/ai_commander.gd` |
| M3 | 合作大厅真人 / AI 二选一；`start_coop_solo`；主流程信号链；HUD 浮动面板；地图选点；主界面 `ai_test` 观战入口 | `view/coop_lobby.gd`、`view/menu_*`、`view/start_screen.gd`、`view/main.gd`、`view/game_scene3d.gd`、`view/hud.gd`、`view/ai_order_panel.gd`、`view/input_controller.gd` |
| M4 | 快照 `aid` / `air`；面板客机只读；目标环；拒绝提示；确定性 seed | `logic/snapshot.gd`、`view/overlay_view_3d.gd`、`view/game_interaction.gd`、`logic/world.gd` |
| M5 | 新测试 4 套 + 全量回归；文档更新 | `tests/test_ai_commander.gd`、`test_ai_order_panel.gd`、`test_coop_ai_teammate.gd`、`test_ai_observer.gd`、`README.md`、`ai_doc/README.md`、`ai_doc/ai-commander-current-status.md` |

### 16.2 实际数值取舍

- `develop_cap_ratio` 从计划里的 `0.6` 提到 **`0.85`**：合作关 `02_twin_line` 一开局就有 18 人，
  0.6 × 26 = 15.6 < 18，AI 会**永远不补员**（实测发现）；0.85 × 26 ≈ 22，既有补员空间，也不至于把
  「发展」变成「全军出击」。
- 面板在 1920 设计空间里从右上角**左移 300px**：实机截图发现原位置会压住右侧部队列表
  （`SQUAD_RECT.x = 1680`），现在右缘停在列表左侧；高度从 190 提到 236，四行状态不再互相压字。
- 目标环半径从 2.2 格缩到 **1.3 格**：2.2 格在最大缩放档下直径约 500px，太抢戏。
- **军队上限改为动态**：`Σ(每位在场将领 1 + 有效编制) × 难度 army_cap_ratio`
  （简单 0.6 / 普通 0.8 / 困难 1.0）。3 位 1 级将领普通约 29；10 位 3 级将领普通约 128。
  难度里的 `army_cap` 只在没有将领时兜底。
- **补将目标改为按大本营等级**：`general_target_by_base_level = [3, 6, 10]`，
  仍受大本营 `max_generals`（3/6/10）与 20 秒招募冷却限制；大后期可以到 10 位将领。
- **新增 ai_test 观战入口**：`data/campaigns/demo/levels/ai_test.json` + 主界面按钮。
  `World.observer_mode = true` 时被观察方仍算目标 / 判负口径的玩家阵营，但由 commander AI 控制；
  输入命令全部丢弃，命令卡 / 页签隐藏，AI 面板只读显示指令、目标、兵力、将领、资源与状态。
- 观战局默认指令改为 `expand`；`ai_test` 地图补了黄金产能（原来 7 块区划全是 food，AI 招完兵后
  金=0，既建不了塔也补不了将）；开局将领改为 `general_0`（不占 #1-9 招募池），大后期可到 10 位；
  补将不再只在“顶满目标上限”时尝试，且会遍历己方各区划；箭塔上限 4→6。
- **AI 默认自主 `auto`**：兵力低于 35% 先发展，35%~80% 扩张，80% 以上 / 45 秒后
  没有中立区就进攻最近敌方目标；没有敌人可打时派 1 支 field team 巡逻（默认 9 秒一班）。
- **生产 / 外勤角色分离**：生产只允许基地区划内、未读条、无移动 / 攻击命令的留守将领当兵营；
  没有合格留守将领就等，不再“退而求其次”抓队列最短的外勤队长。`home_leader()` 也不再在
  基地无将领时退回“离基地最近的队长”，避免把外勤队误判成留守；只有一位将领时 `auto` 不派它出去，
  先补出第二位形成“一守一攻”。
- **固定生产将领**：`production_leader_id` 一旦选定，就只有它当兵营；它读条时生产等待，
  不会换成另一位基地将领（否则 4 位基地将领会被轮流钉在招募上，外勤队全不动）。
  当前生产将领离开基地 / 阵亡才重新选。
- **玩家四指令改为 60 秒临时倾向**：`set_ai_directive` 写 `until`，到期由
  `_tick_ai_directive_holds()` 自动回 `auto`；面板显示“指令剩余 Ns”。

### 16.3 验证

- `tools/check-syntax.ps1`：**205 个 .gd 全部通过**（logic / view / tests / net）。
- `tools/run-tests.ps1`：**81 套 / 7698 项断言全绿**（含新增 4 套 157 项）。
  - ⚠️ 本机 DSH 沙箱下 `user://` 不可写，`test_water.gd` 需要把 `APPDATA` 指到工程内
    （否则失败在「能写临时地图」这个前提上，与本轮代码无关）。
- 新增测试：
  - `test_ai_commander.gd`（82）：配置 / 经济 / 生产 / 建造 / 四指令 / 临时倾向到期 / 自主 / 巡逻 / 生产-外勤角色分离 / 命令链路 / 回防 / 动态军队上限与补将 / 快照 / 确定性；
  - `test_ai_order_panel.gd`（24）：面板布局 / 四按钮 / 折叠 / 无 AI 时隐藏 / 大厅模式切换；
  - `test_coop_ai_teammate.gd`（27）：`start_coop_solo` / 第二席位 / 面板可见 / 选点下令 / 真人合作不受影响；
  - `test_ai_observer.gd`（24）：主界面 ai_test 观战局 / AI 接管 F1 / 默认扩张 / 命令卡隐藏 / 输入与面板只读 / 命令丢弃 / ai_test 黄金与开局将领 #0。

### 16.4 明确未做（按确认口径）

- 自定义对战房间 / 基地槽位 / 多 AI 数量选择 / `annihilation` 模式；
- AI 对手的专用开局 UI（但 `auto` 战略、难度包、基地兜底已经就位）；
- 网络合作里的「真人 + AI 队友同时存在」——按确认口径，二者二选一。

### 16.5 2026.10.25 之后的增量

16.5 及以后属于**实现增量**，已从设计稿移出，避免把历史计划当成现状：

- 当前行为、配置、测试基线：[ai-commander-current-status.md](ai-commander-current-status.md)
- 按日期的完整变更：[../CHANGELOG.md](../CHANGELOG.md)

