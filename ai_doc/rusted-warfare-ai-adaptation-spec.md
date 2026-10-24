# Rusted Warfare 1.15 AI 系统：逆向事实、可移植架构与实现规范

> **读者**：AI 编码代理 / 自动化实现系统。
> **目标**：让读者不仅能理解 Rusted Warfare 1.15 的 AI，还能据此实现一个可适配其他类似 RTS 的、可测试、可确定性回放的 AI。
> **来源**：对 `Rusted Warfare/game-lib.jar` 的静态反编译（CFR 0.152 + JDK 17 `javap`）。
> **版本**：Game 1.15 / Code 176 / Build #28。
> **性质**：逆向分析文档。反编译代码不是原始源码；混淆名保持原样，语义推断单独标注。

---

## 0. 阅读约定

### 0.1 文档结构

| 部分 | 内容 | 用途 |
|---|---|---|
| Part I | Rusted Warfare 1.15 的可验证事实 | 作为参考实现和行为基线 |
| Part II | 从源游戏抽象出的通用 RTS AI 架构 | 直接用于新游戏 |
| Part III | 数据模型、算法、适配清单、测试计划 | 实现与验收 |
| Appendix | 精确常量、类映射、置信度、术语 | 查表与审计 |

### 0.2 置信度标签

本文对每条关键结论使用以下标签：

| 标签 | 含义 |
|---|---|
| `[observed]` | 在反编译代码中直接看到的行为或常量 |
| `[inferred]` | 由多个调用点、创建上下文或调试输出推断，未直接看到原始命名 |
| `[unused]` | 枚举/字段存在，但本版本未发现有效写入或调用 |
| `[generalized]` | 为适配其他 RTS 而抽象出的设计，不是源游戏事实 |

### 0.3 规范用语

- **MUST**：实现正确性所必需。
- **SHOULD**：强烈建议；偏离时需要记录理由。
- **MAY**：可选扩展。
- **MUST NOT**：禁止；通常与确定性、合法性或性能有关。

### 0.4 时间与距离

- 源游戏逻辑帧率：**60 Hz**。
- 文中 `frame` 表示 60 Hz 逻辑帧；`1 frame ≈ 16.666 ms`。
- 源游戏常量中的距离是游戏世界单位；平方距离阈值常用于比较（如 `28900 = 170²`）。
- 适配其他 RTS 时，**MUST** 将帧常量换算为目标游戏的 tick，并将距离常量按“单位半径/武器射程/地图格尺寸”归一化，不能直接照搬。

### 0.5 重要警告

源游戏的 AI 是一个**规则/效用评分/随机权重/有限状态机**系统，不是行为树、GOAP、MCTS 或机器学习。它有几个明显不符合“公平 AI”预期的设计（例如目标选择使用全局敌方单位表）。本文会明确区分：

1. **源游戏事实**：可以复现的行为。
2. **可复用模式**：值得迁移的架构。
3. **不应照搬的缺陷**：适配新游戏时应修正或参数化。

---

# Part I：Rusted Warfare 1.15 的可验证事实

## 1. 执行摘要

### 1.1 它是什么

`[observed]` Rusted Warfare 的遭遇战 AI 由 `com.corrodinggames.rts.game.a` 包实现。核心是：

```
AI 玩家 game.a.a（继承 game.n / Player）
  ├─ 战略调度：25 / 80 / 250 帧计时器
  ├─ 经济与生产：收入倍率 + 建造评分 + 生产预算
  ├─ 编组管理：基地组 i、战斗组 g、运输组 n/l
  ├─ 目标选择：全局敌方单位表随机挑选
  └─ 命令接口：通过 gameFramework.e 发命令，不直接改单位状态
```

### 1.2 关键行为

| 行为 | 事实 | 置信度 |
|---|---|---|
| 决策频率 | 战略层不是每帧全量决策，而是 25/80/250 帧分层 | `[observed]` |
| 生产模式 | 不是固定 build order；是“建造评分 + 生产预算 + 加权随机” | `[observed]` |
| 攻击目标 | 从全局敌方单位表（内置单位）中随机挑一个，不优先基地/高价值目标 | `[observed]` |
| 侦察 | 没有独立侦察/探索模块 | `[observed]` |
| 视野 | `j()` 在基类单位上几乎不过滤视野；对内置单位，AI 实际上拥有全局敌方单位表 | `[observed]` |
| 难度 | 主要是 AI 收入倍率；Impossible 额外改建造/生产/编组上限 | `[observed]` |
| 运输 | 陆军不可达时进入等待运输组，由运输组运送 | `[observed]` |
| 多人/回放 | AI 和玩家走同一命令接口，因此可进入锁步与回放 | `[observed]` |

### 1.3 可复用模式

1. **分层调度**：战略 / 编组 / 执行分离。
2. **预算制生产**：用预算限制每轮产量，而不是固定队列。
3. **效用评分**：候选建筑/单位按当前局面打分，最高分优先。
4. **状态机编组**：基地组、战斗组、运输组各自有明确生命周期。
5. **命令接口**：AI 只发命令，单位负责执行；便于回放、测试和权限控制。
6. **地图连通性预计算**：开局测试 LAND/HOVER 等移动域是否可达，再决定兵种和运输。
7. **难度参数化**：用收入/节奏/上限做难度，而不是改单位数值。

### 1.4 不应照搬的缺陷

1. 目标选择完全随机且使用全局信息。
2. 没有侦察、威胁地图、目标价值评估。
3. 没有兵种克制/ composition 规划。
4. 建造/生产是局部评分，没有全局 build order 和科技树拓扑规划。
5. 编组时间阈值长，容易小股送兵或长时间不进攻。
6. 防御逻辑主要围绕基地半径，缺少前线/资源点防御。
7. 没有经济浮存控制（float control）；可能长时间囤钱。
8. 没有单位微操（集火、拉扯、阵型、撤退路线）。

---

## 2. 源游戏运行事实

### 2.1 目标身份

| 项目 | 值 |
|---|---|
| 游戏 | Rusted Warfare |
| 版本 | 1.15 |
| Game Code | 176 |
| Build | #28 |
| JAR | `game-lib.jar`，2,639,503 bytes |
| SHA-256 | `8A550A37E2D8A5430866090D4E7D5892F9010B47F52A5A09350FC66C620DEEC9` |
| Java 字节码 | major 52（Java 8） |
| 渲染/框架 | LWJGL 2.9.3 + Slick2D + libRocket |
| 类数量 | 1698（反编译 170,465 行 Java） |
| AI 包 | `com.corrodinggames.rts.game.a` |

### 2.2 类映射

| 类 | 角色 | 置信度 |
|---|---|---|
| `game.a.a` | AI 玩家，继承 `game.n` | `[observed]` |
| `game.a.i` | 基地组 | `[observed]` |
| `game.a.g` | 攻击/防御组 | `[observed]` |
| `game.a.n` | 运输组 | `[observed]` |
| `game.a.l` | 等待运输组 | `[observed]` |
| `game.a.h` | 编组基类（持有单位列表） | `[observed]` |
| `game.a.o` | 编组位置基类 | `[observed]` |
| `game.a.d` | 单位权重列表 | `[observed]` |
| `game.a.e` | 权重条目（单位类型 + 权重） | `[observed]` |
| `game.a.f` | 小型工具函数（随机元素、动作筛选） | `[observed]` |
| `game.a.j` | 基地组状态枚举 `a/b/c` | `[observed]` |
| `game.a.k` | 基地组角色枚举 `a/b/c` | `[inferred]` |
| `game.a.a.a` | AI 插件基类 | `[observed]` |
| `game.a.a.d` | 核弹 AI 插件 | `[observed]` |
| `game.n` | 玩家/队伍基类，难度、收入、阵营关系 | `[observed]` |
| `gameFramework.n.f` | MissionEngine：地图 AI 配置、生存模式 | `[observed]` |
| `units.custom.ag` | 自定义单位加载器，解析 `[ai]` 段 | `[observed]` |

### 2.3 AI 玩家状态字段

`game.a.a` 继承 `game.n`。以下字段直接影响 AI：

| 字段 | 含义 | 置信度 |
|---|---|---|
| `aX` | AI 被禁用 | `[observed]` |
| `aY` | Basic AI 模式；`i.c()` 返回 `null`，跳过高级建造评分 | `[observed]` |
| `aZ` | AI 灭亡/休眠 | `[observed]` |
| `U` | 生存模式 AI | `[observed]` |
| `aJ` bit 0 | Turtling/龟缩模式 | `[observed]` |
| `x` / `y` | 锁定难度值 / 是否启用锁定 | `[observed]` |
| `z` | 网络/主机下发的难度覆盖 | `[observed]` |
| `bF` | 当前缓存的难度值（`C()` 的结果） | `[observed]` |
| `bJ` | AI 插件列表（`game.a.a.a`） | `[observed]` |
| `bE` | 单位计数缓存 | `[observed]` |

### 2.4 调度器

`[observed]` 主循环是 `game.a.a.a(float f2)`。`f2` 是 60 Hz 帧增量。

| 周期 | 计时器 | 动作 |
|---|---|---|
| 每帧 | — | `super.a(f2)`、首次运行分析、计时器累加 |
| 25 帧（≈0.42 s） | `aP` | 分配累积时间给编组；挑最多 2 个“饥饿”编组执行 `b()`/`d()` |
| 80 帧（≈1.33 s） | `aL` | `n()`：刷新编组、分配闲置单位、创建基地/攻击/防御/运输组、处理基地受攻击 |
| 250 帧（≈4.17 s） | `aN` | `m()`：统计单位、运行 AI 插件、选择生产目标、发建造/升级命令、创建扩展基地/工兵组 |
| 1000 帧（≈16.7 s） | `by` | 维护周期：清理异常单位、检查单位数量 |

伪代码：

```text
function AI_TICK(dtFrames):
    super.update(dtFrames)                 # 收入、玩家基础逻辑
    if disabled or defeated: return

    if firstRun:
        findCommandCenter()
        precomputeMovementConnectivity()

    aP += dtFrames
    if aP > 25:
        distributeTimeToGroups()
        updateAtMostTwoStarvedGroups()
        aP -= 25

    aL += dtFrames
    if aL > 80:
        refreshGroups()
        assignIdleUnits()
        createBaseCombatTransportGroups()
        handleBaseUnderAttack()
        aL -= 80

    aN += dtFrames
    if aN > 250:
        countUnits()
        runAiPlugins()
        chooseProductionTarget()
        issueBuildAndUpgradeCommands()
        manageExpansionAndBuilderGroups()
        aN -= 250
```

**首次运行分析** `[observed]`：

1. 找到自己的 Command Center。
2. 对每个敌方 Command Center / 地图出生点，用寻路引擎测试：
   - `ao.b`：普通陆军；
   - `ao.f`：悬浮/两栖。
3. 结果写入 `bh`、`bi`、`bj`、`bk` 等连通性标志。
4. `ai()` / `aj()` 由此决定是否需要运输。
5. `i.v()` 由此决定陆军/悬浮/空军生产权重。

---

## 3. 经济、建造与生产

### 3.1 收入倍率

`[observed]` `game.n`：

```text
function E():
    diff = C()                         # aiDifficulty
    mul = 1.0
    if diff > 0: mul = 1.0 + diff * 0.4
    else:        mul = 1.0 + diff * 0.3
    if diff == 3: mul += 1.5           # Impossible
    return mul

function AI_INCOME(dt):
    if not isAI: normalIncome(dt); return
    addCredits(E() * dt)
```

| `aiDifficulty` | 名称 | 收入倍率 |
|---|---|---|
| -2 | Very Easy | 0.4× |
| -1 | Easy | 0.7× |
| 0 | Medium | 1.0× |
| 1 | Hard | 1.4× |
| 2 | Very Hard | 1.8× |
| 3 | Impossible | 3.7× |

注意：倍数还会乘以地图/模式的 `D()` 系数；上表是单人或标准遭遇战下的基线。

### 3.2 建造优先级评分

`[observed]` `i.c()` 遍历所有单位类型，按当前局面打分，选择最高分；每个候选有 1% 概率被随机选中（忽略分数），用于打破固定模式。

定义：

- `n3` = 该单位类型的全局数量（`R.a(type, countMode)`）。
- `n4` = 该单位类型在**本基地组**内的数量（`i.c(type)`）。
- `n2` = 玩家全局的工厂类建筑数量（`buildingFactories` 过滤，不是单基地）。
- `credits` = 当前资金。
- `ad()` = Very Hard 及以上（`difficulty >= 2`）。
- `ac()` = Impossible（`difficulty == 3` 或自定义 >300）。

#### 3.2.1 建筑/工厂评分

| 目标 | 条件 | 评分 `f3` |
|---|---|---|
| `landFactory` (`ar.b`) | `n3 < 5 OR n2 == 0` | `n3 == 0 ? 0.8 : (n4 < 2 ? 0.46 / (n3 + 2*n4) : -2)` |
| `airFactory` (`ar.c`) | `n3 < 5 OR n2 == 0` | `n3 == 0 ? 0.48 : (n4 < 2 ? 0.29 / (n3 + n4) : -2)` |
| `seaFactory` (`ar.d`) | 水图 `ah()` 且 `n3 < 5 OR n2 == 0` | `n3 == 0 ? 0.3 : (n4 < 1 ? 0.1 / (n3 + 2*n4) : -2)` |
| `turret` (`ar.f`) | 无额外门槛 | `n4 == 0 ? 0.47 : (n4 < 3 ? 0.35/n4 : (n4 < 4 ? 0.025/n4 : -2))` |
| `antiAirTurret` (`ar.g`) | 无额外门槛 | `n4 == 0 ? 0.42 : (n4 < 3 ? 0.3/n4 : (n4 < 4 ? 0.02/n4 : -2))` |
| `laserDefence` (`ar.y`) | `n4 == 0` | `0.018`，否则 `-2` |
| `repairbay` (`ar.B`) | `n4 == 0` | `0.02`，否则 `-2` |
| `fabricator` (`ar.J`) | `credits > 2000 && n4 < 5` | `n3 == 0 ? 0.11 : 0.07 / (0.2*n3 + n4)`，否则 `-2` |
| `AntiNukeLaucher` (`ar.D`) | 核弹允许、`credits > 2200 && n3 < 4` | `n3 == 0 ? 0.06 : (n4 < 1 ? 0.05 / (n3 + 2*n4) : -2)` |
| `experimentalLandFactory` (`ar.G`) | `ad()` 且 `credits > 15000` | `n3 == 0 ? 0.04 : (credits > 55000 && n3 == 1 ? 0.03 : -2)` |

**重要**：每个候选的 `f3` 初始值为 `-2`；如果条件命中但子分支不满足，**不会保留上一个分数**，而是保持 `-2` 并跳过。不要把它实现成“fallback 到默认分”。

#### 3.2.2 自定义单位评分

`[observed]` `units.custom.ag` 把 `[ai]` 段读入 `custom.l`，`i.c()` 使用：

```text
if disableUse: skip
if maxGlobal != -1 and globalCount >= maxGlobal: skip
if maxEachBase != -1 and baseCount >= maxEachBase: skip

score = buildPriority
if baseCount < recommendedInEachBaseNum:
    score = recommendedPriorityIfUnmet
if baseCount == 0:
    score += noneInBaseExtraPriority
if globalCount == 0:
    score += noneGlobalExtraPriority
if isBuilding and noBuildSpot:
    score = -2
```

#### 3.2.3 选择规则

```text
best = null
bestScore = -1

for type in allUnitTypes:
    score = scoreBuildCandidate(type)
    if score < 0: continue
    if score > bestScore or random() < 0.01:
        best = type
        bestScore = score

return best
```

**工程注意**：源游戏的“1% 随机”是逐候选判断，不是“在最高分和次高分之间二选一”。复现时建议改为显式的 `explorationRate` 参数，并固定随机源。

### 3.3 生产预算

`[observed]` `i.d` 是 AI 的“可生产单位数”预算：

| 属性 | 值/行为 |
|---|---|
| 初始 | `-1.0` |
| 上限 | `3.5` |
| 每成功训练 1 个单位 | `-1.0` |
| 每轮生产循环 | 固定 12 次 `i.v()`；难度不改变循环次数 |
| 陆军攻击上限 | 普通 50 / Impossible 65 |
| 海军上限 | 普通 12 / Impossible 16 |
| 预算增长 | 随时间/资金增长；资金越高、基地越安全，增长越快；低资金时可能被限制到 1.2 |

预算增长不是单一线性公式，而是多个资金阈值分支的叠加。实现新游戏时 **MUST** 重新设计为可配置的增长曲线，例如：

```text
budgetRate =
    baseRate
  + incomeRateCoefficient * min(income, incomeCap)
  - floatPenalty * max(0, credits - reserve)
budget = clamp(budget + budgetRate * dt, 0, maxBudget)
```

### 3.4 兵种选择与移动权重

`[observed]` `i.v()`：

| 地图条件 | LAND | HOVER | AIR |
|---|---|---|---|
| LAND 与 HOVER 都连通 | 0.4 | 0.3 | 剩余 ≈0.3 |
| LAND 不连通 | 0.1 | 0.5 | 0.4 |
| HOVER 不连通 | 0.2 | 0.1 | 0.7 |

注意：第一行代码只显式设置 `0.4/0.3/0.2`，但随机数落在 `[0.7, 1.0)` 时仍会选择 AIR，因此 AIR 实际约为 0.3。

### 3.5 单位权重列表

`[observed]` `game.a.d`：

- 每组维护 `type -> weight`。
- 默认权重为 `10.0`。
- `b()` 从 `ar.ae`（全部内置单位类型）中按过滤器重建列表。
- 选择时按权重累加随机。

组名：

```text
attackingUnitsLand
attackingUnitsHover
attackingUnitsAir
attackingUnitsWater
buildingUnits
transportUnits
transportUnitsFlying
transportUnitsNonFlying
builderUnits
harvesterUnits
extractorUnits
buildingFactories
buildingFactoriesForBuilders
```

### 3.6 科技升级

`[observed]` 科技升级不是固定顺序：

- AI 在资金和工厂/单位数量达到条件时，从可用升级动作中按概率选择。
- 资金阈值包括约 `1300 / 1700 / 2100 / 2800 / 3100 / 4800 / 8000 / 9000 / 10100 / 30000`。
- 某些单位缺失时提高对应升级优先级。
- 升级动作通过命令接口发给单位/建筑。

---

## 4. 基地组 `game.a.i`

### 4.1 角色

`[inferred]` 由创建上下文与调用点推断：

| 角色 | 枚举 | 创建位置 | 说明 |
|---|---|---|---|
| 主基地 | `k.a` | Command Center 或任意可建造单位 | 默认 `j.c`；负责经济、工厂、防御、生产 |
| 扩张基地 | `k.b` | 地图出生点/资源点 | 初始 `j.a`，约 2000 帧后转 `j.c` |
| 工兵/前哨组 | `k.c` | 已有单位位置 | 向前推进建造、补充工兵 |

### 4.2 内部状态

`[observed]` `i.b` 是 `game.a.j`：

| 状态 | 用途 | 置信度 |
|---|---|---|
| `j.a` | 新基地/扩张状态；带 claim 计时器；创建扩张基地和工兵组时赋值 | `[observed]` |
| `j.c` | 正常活动状态；主基地默认；扩张完成后进入 | `[observed]` |
| `j.b` | 未发现写入点 | `[unused]` |

状态转换（观察到的部分）：

```text
create expansion base -> j.a
j.a + claim timer > 2000 frames -> j.c
j.c + no units for > 11000 frames -> delete group
```

### 4.3 生命周期

1. **创建主基地组**：没有基地组时，优先在 Command Center 创建；否则找可建造单位。
2. **分配工兵**：把闲置工兵/可建造单位加入组；工兵不足时从其他基地组借。
3. **寻找建造位置**：`i.a()` 在基地半径内扫描资源块/可建造地块。
4. **选择建造目标**：`i.c()` 评分；`i.g(type)` 检查工兵、价格、可建造性后发命令。
5. **生产单位**：`i.v()` 按预算和移动权重批量训练；每次成功训练扣预算。
6. **扩张**：在地图出生点创建 `k.b`；重叠基地组删除状态更低者。
7. **防御**：检测基地附近敌人，命令范围内单位攻击；低血量单位撤退。
8. **废弃**：长期没有单位则删除组。

### 4.4 关键计时器

| 计时器 | 值 | 作用 |
|---|---|---|
| 建造尝试 `i.e` | `270 + (groupIndex % 15)` 帧；Impossible `190 + (groupIndex % 15)`；建造分 `< 0.2` 再加 `180`；`< 0.08` 再 `+180`（最多 +360） | 多久尝试造一个建筑 |
| 建造后延迟 `i.m` | 约 1000 帧 | 造完后的冷却 |
| 请求工兵 `i.g` | 1800–2500 帧；第二次后显著增加 | 从其他基地组借工兵 |
| 基地废弃 `i.k` | 11000 帧 ≈ 183 s | 无单位超时 |
| 基地安全 `i.v` | 6000 帧 ≈ 100 s | 受攻击状态维持 |
| claim 计时 `i.l` | 2000 帧 ≈ 33 s | 扩张基地 `j.a -> j.c` |

### 4.5 基地选址检查

`[observed]` `a(point)` / `b(point)`：

- 290 范围内没有敌方单位。
- 490 范围内没有其他基地组。
- 160000 平方距离（约 400）内没有已用出生点。
- 地形可通行，且不在不可建造区域。
- 已有多个基地组时，优先远离现有基地。

### 4.6 建造执行

`i.g(type)`：

1. 选择最近/合适的工兵。
2. 找合法建造点（资源点、陆地/水面约束）。
3. 检查 `action.b(unit)` 与 `action.a(unit, false)`。
4. 检查价格是否可负担。
5. 发建造命令。
6. 若无法负担，记录 `lastAttemptedBuilding`、`cannotAffordPrice` 等调试字段。

---

## 5. 战斗组 `game.a.g`

### 5.1 类型

`[observed]`

| 字段 | 含义 |
|---|---|
| `h` | `true` = 攻击组；`false` = 防御组 |
| `A` | 组内单位上限 |
| `B` | 海军组标志 |
| `k` | 关联的基地组（防御回防目标） |
| `w` | 当前主目标（敌方单位） |
| `q` | 是否处于集结/等待阶段 |
| `r` | 是否已找到可用集结点 |
| `u` | 集结计时 |
| `o` | 进攻计时 |
| `l` | 进攻前延迟 |
| `z` | 命令重发/重新选点计时 |
| `G` | 无法到达目标、需要运输的单位 |

### 5.2 攻击组状态机

```text
COLLECT
  -> 收集闲置单位，直到 A 上限或超时
PICK_TARGET
  -> w = AI.as()                 # 随机敌方单位
STAGING
  -> 在 w 附近计算集结点
  -> 检查每个单位能否到达
  -> 不能到达的单位放入 G（等待运输）
  -> 若最近 1000 帧内有单位受伤 -> 取消集结
  -> 若集结 > 17000 帧 -> 强制进攻
ATTACK
  -> 每 800 帧重新下发攻击命令
  -> 只命令能到达 w 的单位
  -> 若没有单位能到达 -> 放弃
DISBAND
  -> 组为空，或
  -> 组内 < 3 个单位且已过 1000 帧，或
  -> 进攻 > 11000 帧
```

### 5.3 集结点计算 `h()`

`[observed]`

- 基础距离 `50–720`，至少 `450`。
- 80% 概率加 `±110°` 角度扰动。
- 80% 概率在距离上再加随机偏移。
- 如果距离过近，强制至少 `450`。
- 用 `a(x, y)` 检查地形/移动类型；用 `R.a(unit, x, y)` 检查单位个体可达性。
- 失败时单位加入 `G`。

### 5.4 防御组

`[observed]` `g.d(float)`：

- 围绕关联基地 `k` 活动。
- 基地被攻击时，找基地附近敌人并回防。
- 如果敌人太强，向随机方向撤退。
- 基地组 `i.i()` 命令基地半径内单位攻击靠近的敌人。
- `i.g()` 找基地范围内敌人；`i.a(60)` 统计附近敌人数量。

### 5.5 组填充

`[observed]` `g.c()`：

- 从闲置单位池中按移动类型/角色筛选。
- 攻击组避免把空军塞进海军组，反之亦然。
- 组满 `A` 后停止。
- 每帧/周期刷新失效引用。

### 5.6 组解散

- `g.p()` 解散，清空单位引用，从 AI 编组列表移除。
- 组员单位死亡/被其他组接管时，`h.n()`/`h.o()` 清理。

---

## 6. 运输组 `game.a.n` / `game.a.l`

### 6.1 `l`：等待运输组

`[observed]`

- 保存暂时无法到达目标的单位。
- 单位距离组中心超过 3600（约 60²）时移除。
- 组为空或超过 5000 帧时解散。

### 6.2 `n`：运输组

`[observed]`

- 寻找运输单位（飞行/非飞行）。
- 从 `G` 列表和 `l` 组中装载单位。
- 选择目标位置，移动到附近，卸载。
- 运输单位死亡/被占用/组为空时解散或重新寻找。
- 是否生产运输单位由 `R.ai()`、当前运输组数量、基地组状态决定。

---

## 7. 目标选择与地图知识

### 7.1 全局目标池

`[observed]` `game.a.a.as()`：

```text
function AS():
    candidates = []
    for u in globalUnitList:
        if u.dead or u.cN != null or u.u(): continue
        if not isEnemy(u.team): continue
        if not J(u): continue
        candidates.append(u)
    return randomChoice(candidates)

function J(u):
    return u.cg() or not isEnemy(u.team)
```

- `isEnemy(team)`：`this.teamId != other.teamId`（`game.n.c`）。
- `isAlly(team)`：`this.teamId == other.teamId`（`game.n.d`）。
- 基类 `units.am.cg()` 直接返回 `true`。
- 因此对内置单位，`J()` 几乎不过滤视野；目标池是全局敌方单位。

### 7.2 辅助目标/位置方法

| 方法 | 用途 |
|---|---|
| `as()` | 随机敌方单位，攻击组主目标 |
| `at()` | 随机敌方单位位置，核弹 AI 用 |
| `am()` | 地图随机点 |
| `an()` | 随机出生点 |
| `ar()` | 随机己方单位，创建工兵/前哨组 |
| `a(point)` | 基地位置合法性 |
| `b(point)` | 基地周围单位密度检查 |

### 7.3 地图连通性

- 首次运行测试 LAND / HOVER 从己方基地到敌方基地/出生点是否连通。
- 结果影响：
  - 是否生产运输单位；
  - 陆军/悬浮/空军生产权重；
  - 攻击组是否把单位放入运输等待列表；
  - 基地扩张位置选择。

### 7.4 行为后果

- AI 会攻击随机远处单位。
- AI 不侦察，但“知道”所有敌方单位。
- AI 不会因为目标在视野外而放弃。
- AI 不会优先指挥中心、炮塔、资源点或高价值单位。

---

## 8. 地图脚本与 Mod 钩子

### 8.1 地图 `team_info`

| 字段 | 效果 |
|---|---|
| `basicAI` | Basic AI；`i.c()` 返回 `null`，跳过高级建造评分 |
| `disabledAI` | 完全禁用 AI |
| `lockAiDifficulty` | 锁定难度 |
| `allyGroup` | 盟友分组 |
| `ai=survival` | 生存模式 AI |
| `credits` | 初始资金 |

### 8.2 单位 INI `[ai]`

| 键 | 作用 |
|---|---|
| `disableUse` | 禁止 AI 使用 |
| `useAsAttacker` | 可进入攻击组 |
| `useAsBuilder` | 可进入工兵/建造组 |
| `buildPriority` | 基础建造评分 |
| `recommendedInEachBaseNum` | 每基地建议数量 |
| `recommendedInEachBasePriorityIfUnmet` | 未达建议数量时的评分 |
| `maxEachBase` | 每基地上限 |
| `maxGlobal` | 全局上限，-1 不限 |
| `nonInBaseExtraPriority` | 本基地没有时额外评分 |
| `noneInBaseExtraPriority` | 本基地完全没有时额外评分 |
| `nonGlobalExtraPriority` | 全局没有时额外评分 |
| `noneGlobalExtraPriority` | 全局完全没有时额外评分 |
| `whenUsingAsHarvester_*` | 采集单位推荐数量/统计 |
| `onlyUseAsHarvester_ifBaseHasUnitTagged` | 采集标签条件 |
| `ai_upgradePriority` | 升级优先级 |
| `ai_isDisabled` | 逻辑表达式禁用 |
| `ai_isHighPriority` | 高优先级标记 |
| `aiTags` | AI 标签，如 `nukeLauncher` |
| `aiUse` | AI 使用方式，如 `launchAmmo` |

### 8.3 AI 插件

`[observed]`

- 插件基类：`game.a.a.a`。
- 列表：`game.a.a.bJ`。
- 当前版本内置核弹插件：`game.a.a.d`。
- 插件可序列化/反序列化（`a(as)` / `a(k)`）。
- 通过 `game.a.a.b` 枚举恢复类型。

核弹插件行为：

1. 通过 `aiTags: nukeLauncher` 找核弹单位。
2. 选择 `launch` / `launchAmmo` 动作。
3. 用 `R.at()` 选随机敌方位置。
4. 在 `b(float)` 中周期性尝试发射/攻击建筑。

---

## 9. 生存模式与战役

| 类型 | 驱动 |
|---|---|
| 遭遇战/沙盒 | `game.a.a` 规则 AI |
| 生存模式 | 复用规则 AI，`map_info.type=survival`，波次配置 + `U` 标志 |
| 战役任务 | MissionEngine + 地图 `triggers` 层；脚本负责剧情/增援/目标 |

生存模式 `[observed]`：

- 波次间隔约 1200 帧；低难度约 3000 帧。
- `survivalWaves` 定义波次。
- `survivalWavesClassic` 选择经典波次。
- AI 玩家的 `U` 为真，进入生存分支，周期性集结/派兵。

---

## 10. 源游戏未知/不确定项

| 项 | 状态 |
|---|---|
| `j.b` 状态 | 枚举存在，未发现写入点；可能是旧版本遗留 |
| `k.b`/`k.c` 的原始命名 | 推断为扩张基地/工兵组；原始源码名未知 |
| 预算增长完整公式 | 多分支叠加；本文只给出上限、扣减、主要阈值 |
| 自定义 AI 插件完整注册流程 | 只确认序列化恢复和核弹插件；其他插件可能未启用 |
| 运行时行为 | 未做动态插桩；所有行为为静态推导 |

---

# Part II：可移植的 RTS AI 架构

> 以下为 `[generalized]`。它不是 Rusted Warfare 的逐行复刻，而是把可复用模式抽象成可适配其他 RTS 的规范。

## 11. 设计目标

一个可适配的 RTS AI **SHOULD** 满足：

1. **可解释**：每个决策都能追溯到候选、分数、限制条件。
2. **可测试**：纯函数优先；世界状态通过快照注入。
3. **确定性**：相同输入、相同随机种子 -> 相同命令序列。
4. **可回放**：AI 通过命令接口行动，不直接改世界。
5. **可配置**：单位、建筑、科技、难度、地图规则都是数据。
6. **可扩展**：目标选择、兵种克制、侦察、经济策略可插拔。
7. **公平性可切换**：支持“全图 AI”和“受视野限制 AI”两种策略。
8. **性能可控**：分层调度、空间索引、缓存、命令去重。

## 12. 分层架构

```text
┌─────────────────────────────────────────────────────┐
│ AiController                                       │
│  - profile: AiProfile                              │
│  - rng: DeterministicRng                           │
│  - state: AiState                                  │
│  - update(world, dtTicks)                          │
└───────────────┬─────────────────────────────────────┘
                │
    ┌───────────┼───────────┬──────────────┬──────────────┐
    ▼           ▼           ▼              ▼              ▼
Economy     BuildPlanner  Production   GroupManager   TargetSelector
    │           │           │              │              │
    └───────────┴───────────┴──────┬───────┴──────────────┘
                                   ▼
                            CommandEmitter
                                   │
                                   ▼
                            RtsWorld / Commands
```

### 12.1 模块职责

| 模块 | 输入 | 输出 | 不负责 |
|---|---|---|---|
| `Economy` | 资源、收入、人口、浮存 | 可花费预算、储备策略 | 具体造什么 |
| `BuildPlanner` | 地图、基地、科技、候选建筑 | 建造候选与分数 | 执行建造 |
| `Production` | 兵种权重、composition 目标、预算 | 训练命令 | 编组 |
| `GroupManager` | 单位池、基地、威胁 | 组创建/更新/解散 | 单位微操 |
| `TargetSelector` | 可见敌人、战略价值、威胁 | 目标 | 路径/命令 |
| `CombatGroup` | 组状态、目标、地形 | 移动/攻击命令 | 生产 |
| `Transport` | 不可达单位、运输单位 | 装载/移动/卸载命令 | 目标选择 |
| `CommandEmitter` | 意图 | 去重、限流后的命令 | 决策 |
| `ThreatMap` | 单位、建筑、地形 | 威胁/价值栅格 | 决策 |
| `Scouting` | 未知区域、侦察单位 | 侦察命令 | 主力决策 |

### 12.2 更新顺序

每个 AI tick **MUST** 按以下顺序执行，避免使用半更新状态：

```text
1. snapshot = world.snapshotForPlayer(aiPlayer)
2. validateState()                    # 清理死亡引用、非法组
3. economy.update(snapshot, dt)
4. threatMap.update(snapshot)
5. scouting.update(snapshot, dt)      # 可选
6. defense.update(snapshot, dt)       # 基地/资源点威胁
7. groupManager.update(snapshot, dt)  # 刷新/创建/解散组
8. production.update(snapshot, dt)    # 训练/科技
9. buildPlanner.update(snapshot, dt)  # 建造/扩张
10. combatGroups.update(snapshot, dt) # 组决策
11. transport.update(snapshot, dt)
12. commandEmitter.flush()
13. state.tick += 1
14. telemetry.record()
```

**不变量**：

- 一个单位同一时刻只能属于一个组（`unit.groupId` 唯一）。
- 组中的单位引用每一 tick 必须验证；死亡/被接管/不可达时移除。
- 目标引用必须验证存活、敌对、可见（按策略）。
- 建造位置必须通过地图/建筑规则校验。
- 预算不能为负；命令不能超过资源。
- 命令必须幂等或可去重；同一单位同一 tick 不能收到冲突命令。
- 迭代顺序必须稳定（按实体 ID 排序），否则随机选择不可复现。

## 13. 领域模型与接口

以下使用 TypeScript 风格伪代码，便于翻译到任何语言。

### 13.1 世界快照

```ts
interface WorldSnapshot {
  tick: number;
  frameDelta: number;                 // 逻辑帧增量
  player: PlayerView;
  players: PlayerView[];
  units: UnitView[];                  // 已按稳定 ID 排序
  buildings: BuildingView[];
  map: MapView;
  visibility: VisibilityView;
  pathing: PathingService;
  commands: CommandService;
  rng: DeterministicRng;
  time: TimeService;
}

interface PlayerView {
  id: PlayerId;
  teamId: TeamId;
  isAI: boolean;
  credits: number;
  incomePerTick: number;
  population: number;
  populationCap: number;
  aiProfile: AiProfile;
}
```

### 13.2 单位视图

```ts
interface UnitView {
  id: UnitId;
  ownerId: PlayerId;
  teamId: TeamId;
  typeId: UnitTypeId;
  position: Vec2;
  radius: number;
  hp: number;
  maxHp: number;
  isAlive: boolean;
  isBuilding: boolean;
  isFactory: boolean;
  isBuilder: boolean;
  isTransport: boolean;
  isHarvester: boolean;
  movementClass: MovementClass;       // LAND | HOVER | AIR | WATER | ...
  roleTags: string[];
  weapon: WeaponProfile;
  cargo?: UnitId[];
  groupId?: GroupId;
  currentOrder?: OrderView;
  lastDamagedTick?: number;
  visibleToPlayer: boolean;
}

type MovementClass = "LAND" | "HOVER" | "AIR" | "WATER" | "AMPHIBIOUS" | "SPACE";
```

### 13.3 地图视图

```ts
interface MapView {
  width: number;
  height: number;
  tileSize: number;
  passable: Record<MovementClass, PassabilityGrid>;
  resourceNodes: ResourceNode[];
  startLocations: Vec2[];
  chokepoints?: Vec2[];
  islands?: Island[];
}

interface PassabilityGrid {
  isPassable(x: number, y: number): boolean;
  componentId(x: number, y: number): number;   // 连通分量
}
```

### 13.4 命令

AI **MUST NOT** 直接修改世界。所有动作通过命令：

```ts
type Command =
  | { kind: "move"; unitIds: UnitId[]; target: Vec2; mode: "normal" | "attackMove" | "patrol" }
  | { kind: "attack"; unitIds: UnitId[]; targetId: UnitId }
  | { kind: "build"; builderIds: UnitId[]; buildingType: BuildingTypeId; position: Vec2 }
  | { kind: "train"; buildingId: UnitId; unitType: UnitTypeId; count: number }
  | { kind: "upgrade"; buildingId: UnitId; upgradeId: UpgradeId }
  | { kind: "load"; transportIds: UnitId[]; passengerIds: UnitId[] }
  | { kind: "unload"; transportIds: UnitId[]; position: Vec2 }
  | { kind: "stop"; unitIds: UnitId[] }
  | { kind: "hold"; unitIds: UnitId[]; position?: Vec2 };

interface CommandService {
  canIssue(cmd: Command): CommandValidation;
  issue(cmd: Command): CommandResult;
  issueMany(cmds: Command[]): CommandResult[];
}
```

### 13.5 适配器接口

```ts
interface RtsAdapter {
  snapshot(world: unknown, playerId: PlayerId): WorldSnapshot;
  unitProfile(typeId: UnitTypeId): UnitProfile;
  buildingProfile(typeId: BuildingTypeId): BuildingProfile;
  movementClassOf(unit: UnitView): MovementClass;
  canReach(from: Vec2, to: Vec2, movement: MovementClass): boolean;
  findBuildSpot(builder: UnitView, buildingType: BuildingTypeId): Vec2 | null;
  canAfford(player: PlayerView, cost: Cost): boolean;
  costOfUnit(typeId: UnitTypeId): Cost;
  costOfBuilding(typeId: BuildingTypeId): Cost;
  upgradePrerequisites(upgradeId: UpgradeId): UpgradeId[];
  unitPrerequisites(typeId: UnitTypeId): UnitTypeId[];
  strategicValue(unit: UnitView): number;
  threatValue(unit: UnitView): number;
}
```

**适配原则**：AI 核心不依赖具体游戏的类；所有游戏差异通过 `RtsAdapter` 和配置注入。

## 14. 数据模型

### 14.1 单位配置

```yaml
unit_types:
  tank:
    role: combat
    movement: LAND
    cost: { credits: 300, population: 1 }
    build_time_ticks: 600
    hp: 1200
    radius: 14
    weapon:
      range: 170
      damage: 30
      cooldown_ticks: 40
      target_domains: [LAND, HOVER]
    tags: [armored, direct_fire]
    ai:
      build_priority: 0.05
      recommended_per_base: 4
      max_per_base: 12
      max_global: 80
      use_as_attacker: true
      use_as_builder: false

  builder:
    role: builder
    movement: LAND
    cost: { credits: 200, population: 1 }
    hp: 400
    radius: 12
    can_build: [land_factory, turret, extractor]
    ai:
      use_as_builder: true
      max_global: 12
```

### 14.2 AI Profile

```yaml
ai_profile:
  scheduler:
    frame_rate: 60
    strategic_interval_ticks: 250
    group_refresh_interval_ticks: 80
    group_starvation_ticks: 25
  economy:
    reserve_credits: 0
    max_float_ratio: 0.25          # 超过收入 25% 的浮存要花掉
    income_multiplier: 1.0
  production:
    budget_max: 3.5
    budget_spend_per_unit: 1.0
    attempts_per_cycle: 12
    army_cap: 50
    sea_cap: 12
    exploration_rate: 0.01
  build:
    build_attempt_interval_ticks: 270
    low_priority_penalty_ticks: 180
    expansion_interval_ticks: 2000
    max_bases: 4
  groups:
    attack_group_cap: 8
    defense_group_caps: [3, 5, 7, 14, 18]
    staging_timeout_ticks: 17000
    attack_command_interval_ticks: 800
    attack_timeout_ticks: 11000
    min_group_size: 3
    damage_cancel_window_ticks: 1000
  targeting:
    policy: global_random          # global_random | visible_weighted | strategic_value
    allow_global_knowledge: true
  difficulty:
    profile: medium
```

### 14.3 地图元数据

```yaml
map:
  type: skirmish               # skirmish | survival | mission
  start_locations: [[100, 100], [900, 900]]
  resource_nodes:
    - { position: [300, 300], amount: 5000, type: credits }
  movement_domains: [LAND, HOVER, AIR, WATER]
  chokepoints:
    - { center: [500, 500], radius: 120 }
```

## 15. 核心算法

### 15.1 效用评分框架

```text
function score(candidate, context):
    if not hardConstraints(candidate, context):
        return -INF

    score = basePriority(candidate)
    score += needBonus(candidate, context)
    score += scarcityBonus(candidate, context)
    score += strategicBonus(candidate, context)
    score -= redundancyPenalty(candidate, context)
    score -= riskPenalty(candidate, context)
    score *= difficulty.costEfficiencyMultiplier

    return clamp(score, 0, 1)
```

**关键要求**：

- 每个 bonus/penalty **MUST** 有明确上限，避免某项支配全部决策。
- 评分 **SHOULD** 归一化到 `[0,1]`，便于组合。
- 硬约束（价格、前置、上限、建造点）**MUST** 先于评分。
- 随机探索 **SHOULD** 用固定随机源，并按候选顺序稳定。

### 15.2 建造规划

```text
function BUILD_TICK(snapshot):
    if not economy.canSpend(): return

    candidates = []
    for buildingType in adapter.buildableTypes(aiPlayer):
        if not prerequisitesMet(buildingType): continue
        if not hasBuilder(): continue
        candidates.push({
            type: buildingType,
            score: scoreBuilding(buildingType, snapshot)
        })

    for expansionSpot in expansionCandidates(snapshot):
        candidates.push({
            type: "expansion_base",
            position: expansionSpot,
            score: scoreExpansion(expansionSpot, snapshot)
        })

    best = selectBest(candidates)
    if best == null: return

    if best.type == "expansion_base":
        issueBuildBase(best.position)
    else:
        issueBuild(best.type)
```

`scoreBuilding` **SHOULD** 包含：

- 当前数量 vs 目标数量；
- 基地内数量 vs 建议数量；
- 是否没有该类型（scarcity）；
- 资源/科技前置；
- 敌方威胁（防御建筑在威胁高时加分）；
- 地图移动域（水图才造船厂）；
- 经济阶段（早期工厂优先，中后期军队/科技优先）；
- 自定义单位权重。

### 15.3 生产规划

```text
function PRODUCTION_TICK(snapshot):
    budget = economy.productionBudget()
    if budget <= 0: return

    composition = compositionPlanner.desired(snapshot)
    candidates = []

    for unitType in adapter.trainableTypes(aiPlayer):
        if not prerequisitesMet(unitType): continue
        if not hasFactoryFor(unitType): continue
        if globalCount(unitType) >= aiMaxGlobal(unitType): continue

        need = composition.need(unitType)
        if need <= 0: continue

        candidates.push({
            type: unitType,
            score: scoreUnit(unitType, need, snapshot)
        })

    for candidate in selectTop(candidates, attemptsPerCycle):
        if budget < costBudget(candidate): break
        if not economy.canAfford(candidate.cost): continue
        if not commandEmitter.canIssue(train(candidate)): continue

        issueTrain(candidate)
        budget -= 1
```

**源游戏的差异**：Rusted Warfare 的预算不是“资源除以价格”，而是“可生产单位数”；资金是否足够由建造动作单独检查。适配时建议改为：

```text
budget = min(
    availableCredits / averageUnitCost,
    productionCapacityPerCycle,
    populationHeadroom
)
```

### 15.4 编组管理

```text
function GROUP_TICK(snapshot):
    validateGroups(snapshot)
    dissolveInvalidGroups(snapshot)

    idleUnits = units not in any group, not dead, not building, valid

    ensureBaseGroup(snapshot)
    assignBuildersToBaseGroups(idleUnits)
    createDefenseGroupsIfNeeded(snapshot)
    createAttackGroupsIfNeeded(snapshot)
    createSeaGroupsIfNeeded(snapshot)
    createTransportGroupsIfNeeded(snapshot)
    assignIdleCombatUnits(snapshot)
```

**不变量**：

- 组创建 **MUST** 检查上限，避免每 tick 无限创建。
- 组引用 **MUST** 在每 tick 验证。
- 组解散 **MUST** 释放单位（`unit.groupId = null`）。
- 运输组 **MUST** 只装载 `canBeTransported` 的单位。

### 15.5 战斗组状态机

```text
states: COLLECT -> PICK_TARGET -> STAGING -> ATTACK -> DISBAND

COLLECT:
    if group.size >= maxSize: goto PICK_TARGET
    if timeout: goto PICK_TARGET
    addIdleUnits()

PICK_TARGET:
    target = targetSelector.pick(group, snapshot)
    if target == null: goto DISBAND
    goto STAGING

STAGING:
    stagingPoint = computeStagingPoint(target)
    if not group.canReach(stagingPoint): 
        moveUnreachableToTransportWaitList()
    if group.tookDamageRecently(cancelWindow):
        goto PICK_TARGET              # 或 DISBAND，按 profile
    if stagingTime > stagingTimeout:
        goto ATTACK
    issueMoveToStagingPoint()

ATTACK:
    if target.dead:
        goto PICK_TARGET
    if attackTimer > attackInterval:
        issueAttack(target)
    if noUnitCanReach(target):
        goto DISBAND
    if group.size < minSize and elapsed > minSizeGrace:
        goto DISBAND
    if attackTime > attackTimeout:
        goto DISBAND

DISBAND:
    releaseUnits()
```

### 15.6 防御/威胁

```text
function DEFENSE_TICK(snapshot):
    threatMap.rebuild(snapshot)

    for base in aiBases:
        threat = threatMap.sum(base.position, base.radius)
        if threat > defenseThreshold(base):
            defenders = groupManager.defenseGroupFor(base)
            if defenders == null:
                defenders = groupManager.createDefenseGroup(base)
            defenders.assignAvailableUnits()
            defenders.moveTo(threat.centroid)
```

`ThreatMap` **SHOULD** 是栅格/四叉树：

- 每个敌方单位按攻击范围、伤害、移动速度、到达时间贡献威胁。
- 己方建筑/资源点按价值贡献“需要防守”的权重。
- 用于：防御组创建、建造位置评分、撤退方向、目标选择。

### 15.7 运输

```text
function TRANSPORT_TICK(snapshot):
    for group in groups:
        unreachable = group.units.filter(u => !path.canReach(u, group.target))
        group.transportWaitList = unreachable

    for transport in idleTransports:
        cargo = selectPassengers(transportWaitList, transport.capacity, transport.movement)
        if cargo.empty: continue
        issueLoad(transport, cargo)
        issueMove(transport, dropOffPoint)
        issueUnload(transport, dropOffPoint)
```

**适配注意**：

- 有些 RTS 没有运输单位；此时跳过整个模块。
- 有些 RTS 运输是瞬移/传送门；用 `TransportPolicy` 抽象。
- 运输路径 **MUST** 检查装载/卸载点的通行性和容量。

### 15.8 目标选择策略

源游戏是 `global_random`。适配其他 RTS 时，**SHOULD** 做成策略接口：

```ts
interface TargetPolicy {
  pick(group: CombatGroup, snapshot: WorldSnapshot): UnitView | null;
}
```

推荐策略：

| 策略 | 说明 | 适用 |
|---|---|---|
| `global_random` | 全局随机敌方单位；复刻源游戏 | 参考/娱乐 |
| `visible_random` | 只在可见敌人中随机 | 公平 AI |
| `nearest_front` | 选距离组最近/前线目标 | 稳健 |
| `strategic_value` | 按建筑价值、资源点、指挥中心、威胁加权 | 聪明 AI |
| `focus_fire` | 选己方部队能快速击杀的目标 | 微操型 |
| `base_rush` | 优先指挥中心/生产建筑 | 进攻型 |
| `defend_threat` | 优先威胁己方基地的目标 | 防守型 |

**公平性开关**：

```yaml
targeting:
  allow_global_knowledge: false
  require_visible: true
  strategic_value_weight: 0.4
  threat_weight: 0.4
  distance_weight: 0.2
```

如果 `allow_global_knowledge: false`，快照 **MUST** 只包含 `visibleToPlayer == true` 的敌方单位。

### 15.9 难度

推荐把难度建模为“参数包”，而不是散落的 if：

```yaml
difficulty_profiles:
  easy:
    income_multiplier: 0.7
    build_interval_multiplier: 1.3
    production_attempts: 8
    army_cap: 35
    reaction_delay_ticks: 30
    exploration_rate: 0.00
  medium:
    income_multiplier: 1.0
    build_interval_multiplier: 1.0
    production_attempts: 12
    army_cap: 50
    reaction_delay_ticks: 15
    exploration_rate: 0.01
  hard:
    income_multiplier: 1.4
    build_interval_multiplier: 0.9
    production_attempts: 14
    army_cap: 60
    reaction_delay_ticks: 10
    exploration_rate: 0.005
  impossible:
    income_multiplier: 3.7
    build_interval_multiplier: 0.7
    production_attempts: 12
    army_cap: 65
    sea_cap: 16
    reaction_delay_ticks: 5
    exploration_rate: 0.0
```

**原则**：

- 难度 **SHOULD** 优先改经济/节奏/上限，而不是单位数值。
- 高难度 **SHOULD NOT** 获得不公平的视野或非法命令；如果使用全局信息，必须显式标注为“AI 作弊”。
- 难度包 **MUST** 可序列化，并在多人游戏中由主机锁定。

## 16. 适配其他 RTS 的检查清单

### 16.1 领域映射

| Rusted Warfare 概念 | 通用概念 | 适配动作 |
|---|---|---|
| `game.n` Player | 玩家/阵营 | 实现 `PlayerView` |
| `units.am` | 单位/建筑基类 | 实现 `UnitView` |
| `ar` 单位类型枚举 | 单位类型注册表 | 用 `UnitTypeId` + `UnitProfile` |
| `ao` 移动类型 | 移动域 | 映射到 `MovementClass` |
| `d` 单位权重列表 | 生产权重 | 用 composition 目标 |
| `i` 基地组 | 经济/建造组 | 实现 `BaseGroup` |
| `g` 战斗组 | 攻击/防御组 | 实现 `CombatGroup` |
| `n/l` 运输组 | 运输系统 | 实现 `TransportManager` |
| `gameFramework.e` | 命令接口 | 实现 `CommandService` |
| `team_info` | 地图 AI 配置 | 映射到 `MapAiConfig` |
| `[ai]` INI | 单位 AI 元数据 | 映射到 `UnitProfile.ai` |

### 16.2 移动域

**MUST** 明确：

- 有哪些移动域（LAND / AIR / WATER / HOVER / AMPHIBIOUS / SPACE / TELEPORT）。
- 每个单位属于哪个域。
- 每个域的地图通行性如何表示（栅格、导航网格、图）。
- 跨域运输如何发生（运输船、运输机、传送门、空投）。
- 连通分量/岛屿如何计算。

源游戏的 `LAND` / `HOVER` 测试和 `ai()`/`aj()` 运输决策是很好的参考，但阈值（290/490/3600/28900）是游戏世界单位，**MUST** 重新标定。

### 16.3 资源模型

| 模型 | 适配 |
|---|---|
| 被动收入（源游戏） | `incomePerTick`；建造评分直接看 credits |
| 采集单位（工人） | 增加 `HarvesterManager`；按资源点分配工人；避免工人闲置 |
| 多资源 | `Cost` 用 map；`canAfford` 逐项检查；评分归一化 |
| 人口/补给 | `populationCap` 作为生产硬约束 |
| 资源点占领 | `ResourceNode` 价值进入威胁地图和目标选择 |

### 16.4 科技树

源游戏没有显式的全局 build order，只做评分。适配新游戏时 **SHOULD** 增加：

- 前置关系图（DAG）。
- 拓扑排序/可达性检查。
- 关键科技路径（如“必须先造工厂才能造坦克”）。
- 科技投资回报评分（短期军队 vs 长期经济）。
- 死锁检测（没有工人/没有工厂/没有资源）。

### 16.5 视野与公平性

**MUST** 明确策略：

```yaml
visibility_policy:
  mode: fair | global | partial
  require_visible_targets: true
  allow_last_known_position: true
  last_known_ttl_ticks: 600
```

- `fair`：只用 `visibleToPlayer` 的敌人。
- `global`：复刻源游戏；必须在 UI/文档中声明 AI 作弊。
- `partial`：可见 + 最后已知位置 + 记忆衰减。

### 16.6 命令模型

**MUST** 检查目标游戏是否支持：

- 单选/框选/编队。
- 移动、攻击、攻击移动、巡逻、守卫、停止、hold。
- 建造、训练、升级、取消。
- 装载/卸载、集结点、姿态。
- 命令队列与 shift 队列。
- 命令冷却/全局 APM 限制。

AI **SHOULD** 通过 `CommandEmitter` 做：

- 去重（同一单位同一命令不重复发）。
- 限流（每 tick/每秒最大命令数）。
- 合并（同一组同一目标合并为一条命令）。
- 冲突检测（同一单位不能同时建造和攻击）。

### 16.7 地图与规模

**MUST** 重新标定：

- 地图尺寸、格子大小、单位半径。
- 武器射程、视野、建造半径。
- 基地间距、扩张点间距。
- 集结点距离、运输卸载距离。
- 寻路成本、路径平滑、拥堵。

源游戏的常量只能作为“量级参考”，不能直接复制。

### 16.8 时间与确定性

- 源游戏是 60 Hz；目标游戏可能是 10/20/30 Hz 或固定步长。
- **MUST** 把所有帧常量换算成目标 tick。
- **MUST** 使用确定性随机源（固定种子、稳定序列）。
- **MUST** 稳定迭代顺序（按实体 ID）。
- **SHOULD** 避免依赖浮点跨平台一致性；多人锁步游戏建议定点数或量化。
- **MUST** 在回放/重连时序列化 AI 状态（组、计时器、目标、预算、随机源）。

### 16.9 多人/回放

- AI 命令 **MUST** 进入与玩家相同的命令流。
- AI **MUST NOT** 直接修改世界状态。
- AI 状态 **SHOULD** 可序列化，便于回放和断线重连。
- AI 难度 **SHOULD** 由主机锁定，避免中途改变。
- 如果 AI 使用全局信息，**MUST** 在多人规则中显式允许或禁用。

### 16.10 UI 与调试

推荐提供：

- AI 状态覆盖层：基地组、战斗组、目标、集结点、运输组。
- 调试日志：`ai_debug(teamId)`，输出预算、建造目标、失败原因。
- 命令计数器：每 tick 命令数、失败数、路径失败数。
- 指标面板：收入、浮存、军队价值、组数量、进攻频率。
- 回放标记：AI 决策点、目标切换、组创建/解散。

---

# Part III：实现蓝图与验收

## 17. 参考实现骨架

```ts
class AiController {
  constructor(
    private adapter: RtsAdapter,
    private profile: AiProfile,
    private state: AiState,
    private rng: DeterministicRng,
    private commandEmitter: CommandEmitter
  ) {}

  update(world: unknown, dtTicks: number): void {
    const snapshot = this.adapter.snapshot(world, this.state.playerId);

    this.state.validate(snapshot);
    this.state.tick += dtTicks;

    this.economy.update(snapshot, dtTicks);
    this.threatMap.update(snapshot);
    this.scouting?.update(snapshot, dtTicks);
    this.defense.update(snapshot, dtTicks);

    if (this.state.tick % this.profile.groups.refreshInterval === 0) {
      this.groupManager.refresh(snapshot);
    }
    if (this.state.tick % this.profile.production.interval === 0) {
      this.production.update(snapshot, dtTicks);
    }
    if (this.state.tick % this.profile.build.interval === 0) {
      this.buildPlanner.update(snapshot, dtTicks);
    }

    this.combatGroups.update(snapshot, dtTicks);
    this.transport.update(snapshot, dtTicks);
    this.commandEmitter.flush();
    this.telemetry.record(snapshot, this.state);
  }
}
```

## 18. 实现步骤（从零到可运行）

### Step 1：定义领域模型

- 实现 `WorldSnapshot`、`UnitView`、`PlayerView`、`MapView`。
- 确保快照是**只读**的，并且按稳定 ID 排序。
- 实现 `RtsAdapter.snapshot()`。

### Step 2：实现命令层

- 实现 `CommandService` 的校验与下发。
- 实现 `CommandEmitter` 的去重/限流/合并。
- 先不发 AI，手工脚本验证命令层。

### Step 3：实现经济与预算

- 计算收入、可花费资金、人口余量。
- 实现 `productionBudget`。
- 加入浮存控制：超过 `maxFloat` 时优先花钱。

### Step 4：实现建造评分

- 定义 `UnitProfile` / `BuildingProfile`。
- 实现硬约束：前置、价格、上限、建造点。
- 实现评分函数与 `explorationRate`。
- 先只造经济/工厂，验证不会卡死。

### Step 5：实现基地组

- 主基地、扩张、工兵分配。
- 建造位置搜索。
- 基地重叠/废弃/防御。
- 加入 `base_group` 调试覆盖层。

### Step 6：实现生产与 composition

- 定义单位角色/标签/移动域。
- 实现 composition 目标（例如 40% 前排、30% 远程、20% 防空、10% 工程）。
- 实现单位权重与上限。
- 验证不会出现“只造一种单位”或“永远不造兵”。

### Step 7：实现战斗组

- 收集/目标/集结/进攻/解散状态机。
- 目标选择策略可插拔。
- 加入集结点、路径失败、运输等待。
- 验证组不会无限增长、不会卡在集结。

### Step 8：实现防御与威胁

- 威胁地图。
- 基地防御组。
- 资源点/前线防御（可选）。
- 撤退/回防。

### Step 9：实现运输

- 等待运输组。
- 运输组装载/移动/卸载。
- 只在有运输单位和不可达单位时启用。

### Step 10：难度、持久化、测试

- 难度参数包。
- AI 状态序列化/反序列化。
- 场景测试、回归测试、确定性测试。
- 指标面板与调参。

## 19. 测试计划

### 19.1 单元测试

**MUST** 覆盖：

- 评分函数：硬约束、上限、缺省值、自定义权重。
- 预算：增长、扣减、下限/上限。
- 组状态机：每个状态转移、超时、解散、受伤取消。
- 目标选择：空目标、死亡目标、不可见目标、策略切换。
- 建造位置：不可通行、被占用、资源点、无工人。
- 运输：容量、装载、卸载、路径失败。
- 序列化：round-trip 后状态一致。

### 19.2 场景矩阵

| 场景 | 目的 |
|---|---|
| 1v1 陆地图 | 基础经济/生产/进攻 |
| 1v1 岛屿图 | 运输与海军 |
| 1v1 纯空图 | 空军权重/防空 |
| 多基地图 | 扩张、基地重叠、防御 |
| 资源贫瘠图 | 浮存控制、扩张优先级 |
| 高威胁图 | 防御组、撤退 |
| 科技树深 | 前置、升级、死锁检测 |
| 生存模式 | 波次、集结、持续生产 |
| 多人回放 | 确定性、命令流、重连 |
| 低帧率/高延迟 | 调度的鲁棒性 |

### 19.3 指标

| 指标 | 目标 |
|---|---|
| 首次进攻时间 | 不超过配置阈值 |
| 军队价值/收入比 | 稳定，不长期囤钱 |
| 建造队列空闲率 | 低于阈值 |
| 路径失败率 | 低于阈值 |
| 卡住单位数 | 0（或可解释） |
| 组解散率 | 不应过高 |
| 命令数/分钟 | 在引擎限制内 |
| 胜率 vs 基线 | 按难度分档 |
| 确定性哈希 | 相同种子/回放完全一致 |
| 非法命令数 | 0 |

### 19.4 确定性测试

```text
for seed in seeds:
    replay = runScenario(seed, aiProfile)
    hash1 = hash(commands, finalState)
    replay2 = runScenario(seed, aiProfile)
    hash2 = hash(commands, finalState)
    assert hash1 == hash2
```

**MUST** 固定：

- 随机源种子与调用顺序。
- 实体迭代顺序。
- 浮点/定点策略。
- 定时器起点。
- AI 状态序列化顺序。

### 19.5 性能测试

- 1000 单位、4 AI、复杂地图下，AI tick 时间 < 预算。
- 评分候选数量大时，使用空间索引/缓存。
- 避免每 tick 重建所有组/全图扫描。
- 目标选择/威胁地图按需更新。

### 19.6 验收标准

一个可交付的 AI **MUST**：

1. 能在新游戏中完成一局标准遭遇战，不崩溃、不卡死。
2. 能建造经济、工厂、军队、防御。
3. 能扩张至少一个基地。
4. 能组织攻击组并攻击。
5. 能处理不可达目标（运输或放弃）。
6. 能根据难度调整经济/节奏/上限。
7. 能在回放/重连中保持确定性。
8. 不产生非法命令。
9. 有调试覆盖层和日志。
10. 有可重复的场景测试。

## 20. 源游戏局限与改进优先级

### 20.1 源游戏局限

| 局限 | 影响 |
|---|---|
| 全局随机目标 | 攻击无重点，容易被牵着走 |
| 无侦察 | 不探索、不控图；依赖全局信息 |
| 无目标价值 | 不优先指挥中心、资源点、生产建筑 |
| 无 composition 规划 | 兵种搭配靠权重，容易被克制 |
| 无 build order | 经济/科技节奏不稳定 |
| 长计时器 | 小股送兵、长时间不进攻 |
| 无经济浮存控制 | 可能囤钱 |
| 无微操 | 不集火、不拉扯、不撤退路线 |
| 防御范围有限 | 资源点/前线防御弱 |

### 20.2 改进优先级

**P0（正确性/公平性）**

1. 明确视野策略；默认 `fair`。
2. 目标选择改为可插拔评分，至少支持 `visible_weighted`。
3. 命令校验/去重/限流。
4. 组引用清理与死锁检测。
5. 确定性随机与稳定迭代。

**P1（明显提升智能）**

1. 威胁地图 + 目标价值。
2. Composition 目标 + 兵种克制矩阵。
3. 建造前置/科技 DAG + 关键路径。
4. 经济浮存控制。
5. 防御组按威胁分配。
6. 进攻组按“可达成目标”筛选，而不是随机。

**P2（高级）**

1. 侦察/地图控制。
2. 多组协同（主攻/佯攻/防守）。
3. 集火/拉扯/阵型/撤退路线。
4. 运输计划与空投。
5. 对手建模（开局侦查、兵种偏好）。
6. 学习/自适应权重（可选，非必需）。

## 21. 迁移到其他 RTS 的常见陷阱

1. **直接复制帧常量**：60 Hz 到 30 Hz 会让所有计时器减半。
2. **直接复制距离常量**：地图格大小/单位半径不同，290/490 可能完全不合理。
3. **忽略移动域**：没有海军/空军的游戏不应创建对应组。
4. **忽略人口/补给**：预算只看钱会导致人口爆仓。
5. **忽略科技前置**：只按分数建造会卡在“没有工厂却想造坦克”。
6. **忽略视野**：公平 AI 不应读取全图。
7. **忽略命令限制**：每 tick 发太多命令会被引擎限流或导致卡顿。
8. **忽略确定性**：随机源/迭代顺序不稳定会导致回放不同步。
9. **忽略运输**：有岛屿/水域的地图会让陆军卡住。
10. **忽略失败反馈**：建造/训练/路径失败必须记录并触发重试/换目标。

## 22. 快速参考：源游戏常量

| 常量 | 值 | 说明 |
|---|---|---|
| 逻辑帧率 | 60 Hz | 所有帧常量基准 |
| 战略调度 | 25 / 80 / 250 帧 | 编组/刷新/生产 |
| 建造尝试 | 270 + N%15 帧 | Impossible 190 + N%15 |
| 低优先级惩罚 | +180（<0.2）；再 +180（<0.08） | 最多 +360 |
| 预算上限 | 3.5 | 生产预算 |
| 每轮生产循环 | 12 次 | 固定；Impossible 不改变循环次数 |
| 陆军上限 | 50 / 65 | 普通 / Impossible |
| 海军上限 | 12 / 16 | 普通 / Impossible |
| 建造后冷却 | ~1000 帧 | 基地组 |
| 基地废弃 | 11000 帧 | 约 183 s |
| 基地安全计时 | 6000 帧 | 约 100 s |
| 扩张 claim | 2000 帧 | 约 33 s |
| 战斗组进攻延迟 | 1000 帧 | 约 16.7 s |
| 攻击命令间隔 | 800 帧 | 约 13.3 s |
| 集结超时 | 17000 帧 | 约 283 s |
| 进攻超时 | 11000 帧 | 约 183 s |
| 集结距离 | 50–720 | 至少 450 |
| 集结角度扰动 | ±110° | 80% 概率 |
| 受伤取消窗口 | 1000 帧 | 约 16.7 s |
| 等待运输解散 | 5000 帧 | `l` 组 |
| 基地选址敌距 | 290 | 世界单位 |
| 基地组间距 | 490 | 世界单位 |
| 出生点间距² | 160000 | 约 400² |

## 23. 术语表

| 术语 | 含义 |
|---|---|
| AI tick | AI 的一次更新；不等同于渲染帧 |
| 逻辑帧 | 固定步长模拟帧；源游戏 60 Hz |
| 基地组 | 管理经济/建造/防御的 AI 组 |
| 战斗组 | 管理攻击/防御单位的 AI 组 |
| 运输组 | 管理装载/运输/卸载的 AI 组 |
| 预算 | AI 每轮可生产单位数/资源额度 |
| 效用评分 | 对候选动作/单位打分并选最高 |
| 威胁地图 | 记录敌方威胁分布的栅格/图 |
| 浮存 | 未花掉的资金；过高会降低效率 |
| 确定性 | 相同输入/种子产生相同输出 |
| 锁步 | 多人游戏中所有客户端按相同命令序列模拟 |

---

## Appendix A：源游戏类/方法索引

| 类/方法 | 作用 |
|---|---|
| `game.a.a.a(float)` | AI 主调度 |
| `game.a.a.m(float)` | 生产/科技/编组 |
| `game.a.a.n(float)` | 编组刷新/创建 |
| `game.a.a.i(float)` | 调试覆盖层 |
| `game.a.a.as()` | 随机敌方单位目标 |
| `game.a.a.at()` | 随机敌方位置 |
| `game.a.a.ar()` | 随机己方单位 |
| `game.a.a.am()` / `an()` | 随机地图点/出生点 |
| `game.a.a.a(point)` / `b(point)` | 基地选址检查 |
| `game.a.i.c()` | 建造评分 |
| `game.a.i.d(float)` | 建造/预算主循环 |
| `game.a.i.v()` | 生产候选/批量训练 |
| `game.a.i.g(type)` | 执行建造 |
| `game.a.i.n()` | 基地组逻辑 |
| `game.a.g.b(float)` | 战斗组主更新（含防御） |
| `game.a.g.c(float)` | 战斗组刷新/移动 |
| `game.a.g.d(float)` | 防御行为 |
| `game.a.g.e(float)` | 攻击行为 |
| `game.a.g.h()` | 集结点计算 |
| `game.a.n.c(float)` | 运输组更新 |
| `game.a.l.c(float)` | 等待运输组更新 |
| `game.n.C()` | 当前难度 |
| `game.n.E()` | 收入倍率 |
| `game.n.c(team)` | 是否敌方 |
| `game.n.d(team)` | 是否友方 |
| `units.am.cg()` | 目标有效性；基类返回 true |
| `units.custom.ag` | `[ai]` 段解析 |
| `gameFramework.n.f` | 地图 AI 配置/生存模式 |

## Appendix B：证据与复现

- 目标：`Rusted Warfare/game-lib.jar`
- SHA-256：`8A550A37E2D8A5430866090D4E7D5892F9010B47F52A5A09350FC66C620DEEC9`
- 反编译：CFR 0.152
- 字节码辅助：JDK 17 `javap -p -c`
- 规模：1698 个类，约 170,465 行 Java
- 主要证据：
  - `game/a/a.java`
  - `game/a/i.java`
  - `game/a/g.java`
  - `game/a/n.java`
  - `game/a/l.java`
  - `game/a/d.java`
  - `game/n.java`
  - `gameFramework/n/f.java`
  - `units/custom/ag.java`

**复现边界**：本文是静态分析。反编译代码不是原始源码；CFR 可能对异常控制流/枚举构造产生不完全等价的结果。所有关键结论均尽量由多个调用点交叉验证；不确定项已标注。

---

## Appendix C：给 AI 实现者的最短行动清单

如果你现在要在一个新 RTS 中实现这套 AI，按以下顺序做：

1. 实现 `WorldSnapshot` 和 `CommandService`。
2. 实现 `AiController.update()` 的分层计时器。
3. 实现经济：收入、预算、浮存。
4. 实现 `BuildPlanner`：硬约束 + 效用评分。
5. 实现基地组：主基地、扩张、工兵。
6. 实现 `Production`：composition + 权重 + 上限。
7. 实现战斗组状态机：收集/目标/集结/进攻/解散。
8. 实现目标选择策略；默认 `fair`，不要默认全局。
9. 实现运输（如果游戏有）。
10. 实现难度参数包。
11. 实现 AI 状态序列化。
12. 写场景测试 + 确定性测试 + 指标面板。
13. 用真实地图调参；不要照搬源游戏常量。
14. 记录所有失败原因，并让 AI 能重试/换目标。

**最终验收**：AI 能在新游戏中完成一局标准遭遇战，经济不断档、军队持续生产、能扩张、能进攻、能运输、能防守、能在回放中完全复现，且不产生非法命令。
