# Rusted Warfare 1.15 性能压力与极多单位优化：逆向规范

> **读者**：AI 编码代理 / 需要实现类似 RTS 高性能模拟与渲染的工程系统。
> **目标**：识别 Rusted Warfare 在数百到上千单位下的真实性能压力点，提取可迁移的优化模式，并给出适配其他 RTS 的实现与测试规范。
> **来源**：对 `Rusted Warfare/game-lib.jar` 的静态反编译（CFR 0.152 + JDK 17 `javap`）。
> **版本**：Game 1.15 / Code 176 / Build #28。
> **性质**：逆向分析；反编译代码不是原始源码；推断内容单独标注。

---

## 0. 阅读约定

### 0.1 结构

| 部分 | 内容 |
|---|---|
| Part I | 可验证的性能事实与压力点 |
| Part II | 模拟、空间索引、寻路、渲染、移动端的具体机制 |
| Part III | 迁移到其他 RTS 的性能设计、指标与测试 |
| Appendix | 精确参数、证据与置信度 |

### 0.2 置信度

| 标签 | 含义 |
|---|---|
| `[observed]` | 反编译代码中直接看到 |
| `[inferred]` | 由多个调用点/日志/上下文推断 |
| `[generalized]` | 为适配其他 RTS 抽象出的设计，不是源游戏事实 |
| `[unused]` | 存在但未发现有效使用 |

### 0.3 规范用语

- **MUST**：性能/正确性所必需。
- **SHOULD**：推荐；偏离需记录理由。
- **MAY**：可选。
- **MUST NOT**：禁止。

### 0.4 基准

- 逻辑 tick：**60 Hz**。
- 渲染：120 / 300 FPS 目标（受显示器/VSync/负载限制）。
- 省电模式：约 **31 FPS**（32.26ms 休眠）。
- 默认单位上限：单机 **1000**；联机主机 **250**（`preferences.ini`）。

---

# Part I：性能事实与压力点

## 1. 执行摘要

### 1.1 一句话结论

`[observed]` 它不是“无限单位也高帧”。它把性能压力拆成四层：

```
1. 模拟预算固定：60Hz 逻辑，渲染独立
2. AI 分层：25 / 80 / 250 帧，不是每帧全量重规划
3. 邻接查询局部化：32×32 UnitGeoIndex + 队伍桶
4. 渲染先裁剪/缓存：屏幕裁剪、1024px 地图块、图集、LOD、移动端降级
```

### 1.2 关键数字

| 项目 | 值 | 置信度 |
|---|---|---|
| 逻辑频率 | 60 Hz | `[observed]` |
| 渲染目标 | 300（高刷）/ 120 FPS | `[observed]` |
| 省电模式 | ~31 FPS | `[observed]` |
| 单机单位上限 | 1000 | `[observed]` |
| 联机主机单位上限 | 250 | `[observed]` |
| 空间网格 | 32×32 | `[observed]` |
| 格子尺寸 | 地图宽/32、地图高/32 | `[observed]` |
| 地图块 | 约 1024px | `[observed]` |
| 可见地图块 | 约 3×3 + 软边 | `[observed]` |
| PathSolver | 最多 2 个（1 基础 + 1 额外） | `[observed]` |
| 寻路延迟预算 | 12–360 帧 | `[observed]` |
| AI 战略计时 | 25 / 80 / 250 帧 | `[observed]` |
| LOD 阈值 | 缩放 &lt; 0.45 / &lt; 0.3 | `[observed]` |

### 1.3 核心判断

1. **模拟是单线程 60Hz**：屏幕裁剪只降低渲染压力，不降低模拟成本。
2. **空间索引是极多单位的关键**：碰撞/选择/范围查询只扫附近格子。
3. **寻路是限流系统**：最多 2 个 solver，按距离给延迟，低优先级排队。
4. **渲染压力被缓存和裁剪吸收**：屏幕裁剪、地图块 FBO、图集、雾/小地图缓存。
5. **移动端靠主动降级**：省电帧率、renderDensity、safe mode、OOM 回退。
6. **没有看到通用单位对象池**：主要靠数组、缓存、路径内存池；GC 压力仍可能存在。

---

## 2. 性能压力目录

| 压力点 | 最坏复杂度/风险 | 源游戏对策 | 置信度 |
|---|---|---|---|
| 单位更新 | O(n) / 每逻辑 tick | 固定 60Hz；数组式对象列表 | `[observed]` |
| AI 决策 | 全局重规划成本高 | 25/80/250 帧分层；编组级决策 | `[observed]` |
| 邻接查询/碰撞 | O(n²) | UnitGeoIndex 32×32 + 队伍桶 | `[observed]` |
| 寻路 | 大量 A* 请求 | 最多 2 个 solver；延迟预算；低优先级 | `[observed]` |
| 单位绘制 | 数千 draw call | 屏幕裁剪列表；图集；按层排序；LOD | `[observed]` |
| 地图绘制 | 每帧全图 | 1024px 块预渲染 FBO，只画可见块 | `[observed]` |
| 雾/小地图 | 每帧全图 | 缓存、尺寸变化才重建 | `[observed]` |
| 队伍颜色 | 每单位每帧染色 | LazyColoring / 队伍 shader | `[observed]` |
| 内存/GC | 临时对象/贴图 | 自定义数组、缓存、路径内存池 | `[observed]` |
| 移动端 | 分辨率/发热/内存 | 省电帧率、renderDensity、safe mode、OOM 回退 | `[observed]` |

---

# Part II：机制拆解

## 3. 模拟与 AI：固定预算

### 3.1 固定 60Hz 逻辑

`[observed]` `game.i.b`：

```text
G += renderDelta

while G > currentStepRate:
    G -= currentStepRate
    if network.shouldWait(): break
    simulate(currentStepRate)
```

- `currentStepRate` 默认 1.0。
- 1.0 = 每个模拟步推进 1 个逻辑帧 = 60 步/秒。
- 渲染 120/300 FPS 不会让模拟变成 120/300Hz。

**适配规则**：

- **MUST** 用固定步长模拟，不用可变 `dt` 直接驱动逻辑。
- **SHOULD** 把渲染帧率与逻辑 tick 解耦。
- 如果逻辑 tick < 渲染 FPS，**SHOULD** 考虑实体位置插值；源游戏未发现实体插值。

### 3.2 AI 分层计时

`[observed]` `game.a.a`：

| 周期 | 动作 |
|---|---|
| 每帧 | 首次运行分析、计时器累加、收入/玩家基础逻辑 |
| 25 帧 | 挑最多 2 个“饥饿”编组执行决策 |
| 80 帧 | 刷新编组、分配闲置单位、创建基地/攻击/防御/运输组 |
| 250 帧 | 统计单位、选生产目标、发建造/升级命令、创建扩张/工兵组 |

**适配规则**：

- 高开销全局规划 **SHOULD** 降频。
- 局部单位行为可以每 tick 跑，但邻接查询 **MUST** 用空间索引。
- AI **SHOULD** 有调试开关，避免调试逻辑影响正式性能。

### 3.3 数组式对象列表

`[observed]` `gameFramework.utility.s`：

- 内部是 `w[]` 数组。
- 直接返回 backing array 遍历（`s.a()`）。
- 扩容按约 50% 增长（小列表固定 12）。
- `am.bE`（单位快表）、`w.er`（fastGameObjectList）都使用它。

**适配规则**：

- 热路径 **MUST NOT** 每帧创建大量 `ArrayList`/迭代器/临时对象。
- **SHOULD** 使用数组、池化列表或 free-list。
- 迭代顺序 **MUST** 稳定，兼顾确定性与缓存局部性。

---

## 4. UnitGeoIndex：32×32 空间网格

### 4.1 结构

`[observed]` `game.units.f.c`：

- 网格固定 `32 × 32`。
- 格子尺寸：
  - `cellW = map.width / 32`
  - `cellH = map.height / 32`
- 每个格子有：
  - 全部单位桶
  - 按队伍划分的桶
- 每个单位记录当前格子和队伍：`dl`、`dm`、`dn`。
- 单位跨格或换队时才从旧桶删除、插入新桶。
- 批量更新 `a()` 会遍历单位快表，只在格子/队伍变化时移动。

### 4.2 查询

`[observed]` 半径查询：

```text
function QUERY_RADIUS(x, y, r):
    x0 = cellOf(x - r)
    x1 = cellOf(x + r)
    y0 = cellOf(y - r)
    y1 = cellOf(y + r)

    result = []
    for cx in x0..x1:
        for cy in y0..y1:
            for unit in grid[cx][cy].bucket:
                if distanceSq(unit, x, y) <= r*r:
                    result.add(unit)
    return result
```

- 某些查询会额外加 50 的边距。
- 队伍过滤可用每队独立的桶。
- 它用于碰撞/重叠、框选、范围伤害、治疗、侦测、自定义单位“附近单位”逻辑。

### 4.3 复杂度

- 插入/删除：O(1)（跨格时）。
- 半径查询：O(k + c)，k = 命中/扫描单位数，c = 覆盖的格子数。
- 避免了 O(n²) 全单位两两比较。

### 4.4 适配规则

- 网格单元 **SHOULD** 按“最大常见查询半径/单位密度”选择。
- 如果地图很大、单位很密，固定 32×32 可能过粗；可用四叉树/哈希网格/分层网格。
- **MUST** 支持队伍/阵营过滤，减少无关单位扫描。
- **MUST** 在单位跨格时增量更新，不要每帧重建整个索引。
- **SHOULD** 为查询提供“临时结果数组”复用，避免分配。

---

## 5. 寻路：排队、限流、延迟预算

### 5.1 Solver 数量

`[observed]` `gameFramework.k.l`：

```text
solvers.add(new PathSolver())
if availableProcessors() > 1:
    solvers.add(new PathSolver())
```

- 最多 **2 个** solver，不是每核一个。
- 每个 solver 是 daemon 线程，优先级 10，独立队列。

### 5.2 代价网格

`[observed]`

- LAND / HOVER / AIR / WATER 等移动类型各有独立路径成本数组。
- 地图加载时预计算成本；可见区域可能有额外更新。
- 不同移动域不共用一张图。

### 5.3 请求延迟

`[observed]` 路径请求有 `t`（允许延迟），按距离设置：

| 距离 | 允许延迟 |
|---|---|
| 很近 | 12–16 帧 |
| 近 | 24 帧 |
| 中 | 50 帧 |
| 远 | 100–200 帧 |
| 联机 | 180 / 360 帧 |

低优先级路径还会额外增加延迟，并可能被合并/取消。

### 5.4 内存

`[observed]`

- PathOpenList 有内存池。
- 超过 50000 项时清理，避免无限增长。
- 路径对象有完成/超时/取消状态。

### 5.5 适配规则

- **MUST** 把寻路放到 worker/job 系统，不要在主线程同步算大量路径。
- **SHOULD** 给每个请求设 deadline/优先级，避免“所有单位同时寻路”。
- **SHOULD** 缓存常用路径/流场；源游戏没有明显流场，但可扩展。
- **MUST** 区分移动域；不要让空军和陆军共用同一张代价图。
- **SHOULD** 使用对象池/内存池，避免 GC。

---

## 6. 渲染：裁剪、缓存、图集、LOD

### 6.1 屏幕裁剪列表

`[observed]` `game.i.c`：

1. 遍历 `w.er` 快表。
2. 对每个对象调用 `w.a(engine)`。
3. 单位 `am.a(l)` 检查屏幕矩形 `l.cO.b(x, y)`。
4. 同时检查队伍可见性/隐藏状态。
5. 可见对象进入 `X`。
6. 可见集合变化时交换 `W` / `X`，避免每帧重新分配。
7. 渲染只遍历 `W`。
8. 按 `w.ei` 排序：`em`（绘制层）→ `en` → `ep`（Y 坐标）。

**注意**：

- 这是 2D 屏幕矩形裁剪，不是 3D 遮挡/视锥剔除。
- 它降低绘制，不降低模拟成本。
- 可见对象集合排序每帧可能发生；单位很多时排序也是压力点。

### 6.2 地图块缓存

`[observed]` `game.b.c`：

- 地图切成约 **1024px** 的 layer buffer。
- 可见区域通常约 **3×3** 块；软边再额外一份。
- 每块预渲染到 FBO/纹理；只重画可见块。
- 屏幕尺寸变化/块不足时才扩展或重建。
- `smoothFog_cache`、minimap FBO 也是缓存，尺寸不变就不全量重算。

**适配规则**：

- 静态地形 **SHOULD** 预渲染到 chunk texture。
- 动态地形/建筑变化 **MUST** 只重画受影响的 chunk。
- 雾/小地图 **SHOULD** 用脏标记，不要每帧全图。
- chunk 尺寸按内存/可见范围/更新频率权衡。

### 6.3 纹理图集

`[observed]` `gameFramework.m.f` `BitmapOrTextureAlias`：

- 把大量小图打包到一张大纹理。
- 以图像对象为 key 缓存子区域。
- 图像版本变化时失效重打包。
- 图集满时重建缓存。
- `-disable_atlas` 可关闭。

**适配规则**：

- 小精灵 **SHOULD** 进图集，减少纹理绑定/状态切换。
- 图集 **MUST** 支持动态失效/重打包。
- 图集尺寸 **MUST** 受设备上限约束；移动端可用多张图集/分页。
- 大图（背景/地形）不要塞进小图集。

### 6.4 队伍颜色懒加载

`[observed]` `gameFramework.m.h` `LazyColoring`：

- 支持队伍 shader 时直接着色。
- 否则 CPU 生成染色 bitmap 并缓存。
- 不会每单位每帧重新染色。

**适配规则**：

- 队伍色 **SHOULD** 用 shader/材质参数，而不是 CPU 逐像素改图。
- 无 shader 时 **MUST** 缓存染色结果。
- 颜色缓存 **MUST** 在图像/队伍变化时失效。

### 6.5 LOD 与画质开关

`[observed]` 渲染循环：

- `cX < 0.45`：关闭一部分层/效果。
- `cX < 0.3`：进一步关闭。
- 可关闭：`shaderEffects`、`renderExtraLayers`、`renderExtraShadows`、`renderClouds`、`renderFancyWater`。
- 可缩放：`renderDensity`、`uiRenderScale`、`renderDoubleScale`。
- 可切换：VBO（`-disable_vbos`/`-force_vbos`）、图集（`-disable_atlas`）。

**适配规则**：

- 缩放越远，细节越少；**SHOULD** 用 LOD/层开关。
- 移动端 **SHOULD** 提供画质档位，而不是一个固定配置。
- 动态分辨率/渲染密度 **SHOULD** 可调。

---

## 7. 地图、雾、小地图

`[observed]`

- 地图块 FBO 缓存。
- `smoothFog_cache` 尺寸变化才重建。
- minimap FBO 缓存，脏时才更新。
- OOM 时地图块可退化为空 buffer，并关闭 smooth fog fading。

**适配规则**：

- 静态地图 **MUST** 缓存。
- 雾/小地图 **SHOULD** 增量更新/脏标记。
- 内存不足 **MUST** 有降级路径，不要直接崩溃。
- 缓存重建 **MUST** 避免在同一帧做太多（可分帧）。

---

## 8. 移动端：主动降级

### 8.1 帧率

`[observed]` `gameFramework.z`：

| 模式 | 休眠 | 约 FPS |
|---|---|---|
| 高刷新 | 3.33ms | 300 |
| 普通 | 16.39ms | 61 |
| 省电 | 32.26ms | 31 |

- `batterySaving` 直接降帧，减少发热/耗电。
- 桌面渲染目标：`highRefreshRate ? 300 : 120`。

### 8.2 分辨率

`[observed]`

- `renderDensity`：内部渲染密度。
- `uiRenderScale`：UI 渲染缩放。
- `renderDoubleScale`：进一步降低 UI 像素密度。
- 超大屏幕自动提高 UI 缩放。

### 8.3 Safe Mode / OOM 回退

`[observed]`

- 连续加载失败 → safe mode：
  - 关 mods
  - 关 `newRender`
  - 关 `shaderEffects`
  - 关 `teamShaders`
- extra safe mode 进一步降级。
- 地图块 OOM → 空 layer buffer + 关闭 smooth fog fading + `System.gc()`。
- 贴图/染色 OOM → fallback 纹理。
- 日志记录 `Runtime.maxMemory()`、native heap 等。

### 8.4 Mod 资源

`[observed]`

- 自定义单位图片有 `image cacheHits / cacheMisses`。
- `cache/mods-info.cachedata` 缓存 mod-info。
- 支持懒加载；`disableModLazyLoad`。
- Safe mode 跳过 mod 数据。

### 8.5 适配规则

- **MUST** 提供画质/帧率档位。
- **SHOULD** 提供动态分辨率或 render scale。
- **MUST** 有 OOM/加载失败降级，而不是崩溃。
- **SHOULD** 预热/缓存资源，避免对局中卡顿。
- **MUST** 监控内存/热度/帧时间（至少日志）。

---

## 9. 内存与 GC

### 9.1 源游戏的做法

`[observed]`

- 自定义数组列表（`s`）避免 `ArrayList` 包装。
- 单位快表、对象快表。
- UnitGeoIndex 固定数组。
- 路径 open-list 内存池（>50000 清理）。
- 纹理/染色/图集/地图块缓存。
- 自定义单位图片/ ModInfo 缓存。
- OOM fallback。

### 9.2 未发现

`[inferred]`

- 没有发现通用单位对象池。
- 投射物/特效没有明显池化证据。
- 因此极端单位/特效数量下仍可能有 GC/分配压力。

### 9.3 适配规则

- 热路径 **MUST NOT** 每帧分配大量对象。
- **SHOULD** 用对象池/free-list 管理单位、投射物、特效、路径节点、临时数组。
- **SHOULD** 用 SoA/数组而不是大量小对象（视语言/引擎）。
- **MUST** 有内存预算和降级策略。

---

# Part III：迁移到其他 RTS

## 10. 性能设计蓝图

```text
Simulation
  - fixed tick 30/60 Hz
  - stable IDs / deterministic iteration
  - array/SoA storage
  - spatial index (grid/quadtree/hash)
  - job system for pathfinding/collision

AI
  - strategic tick 1–5s
  - group tick 0.5–1s
  - unit behavior every tick
  - no global replanning per unit per tick

Rendering
  - culling (screen/frustum/occlusion as applicable)
  - chunked terrain + cache
  - texture atlas + batching
  - team color shader/cache
  - LOD + dynamic resolution
  - frame pacing

Mobile
  - quality profiles
  - frame caps
  - memory budgets
  - OOM/load-failure fallback
  - telemetry
```

## 11. 推荐数据结构

### 11.1 空间索引

```ts
interface SpatialIndex<T> {
  insert(entity: T): void;
  remove(entity: T): void;
  update(entity: T): void;              // 位置/队伍变化时
  queryRadius(x: number, y: number, r: number, team?: TeamId): T[];
  queryRect(rect: Rect, team?: TeamId): T[];
}
```

实现选择：

| 场景 | 推荐 |
|---|---|
| 固定大小地图、中等密度 | 固定网格（如 32×32 / 64×64） |
| 大地图、密度不均 | 四叉树/哈希网格 |
| 超多单位、频繁范围查询 | 分层网格 + 队伍桶 |
| 动态障碍 | 网格 + 局部重建/流场 |

### 11.2 对象存储

```ts
interface UnitStore {
  units: Unit[];                 // 或 SoA
  freeIds: UnitId[];             // 复用
  spatial: SpatialIndex<Unit>;
  updateAll(dt: number): void;
}
```

**MUST**：

- 稳定 ID。
- 删除时从空间索引移除。
- 迭代顺序稳定。
- 热路径避免分配。

### 11.3 路径请求

```ts
interface PathRequest {
  unitId: UnitId;
  from: Vec2;
  to: Vec2;
  movement: MovementClass;
  priority: number;
  deadlineTick: number;
}
```

## 12. 性能预算与指标

### 12.1 帧预算

按目标 FPS 分配：

```text
budgetMs = 1000 / targetFPS
simulationBudget = 0.4 * budgetMs
renderBudget = 0.5 * budgetMs
reserve = 0.1 * budgetMs
```

RTS 建议：

- 逻辑 60Hz，渲染 60–300 FPS。
- 如果逻辑 30Hz，渲染 60 FPS 时优先考虑插值。
- 移动端省电档可 30 FPS。

### 12.2 指标

| 指标 | 目标 |
|---|---|
| 逻辑 tick 时间 | < 预算 |
| 可见单位 draw call | 受控；用图集/批处理降低 |
| 空间查询数量 | 可统计；避免全表扫描 |
| 寻路队列长度 | 有上限；超时降级 |
| 寻路平均/95% 延迟 | 在预算内 |
| 帧时间 95%/99% | 稳定 |
| GC/分配速率 | 低且平稳 |
| 纹理绑定/秒 | 图集后下降 |
| 地图 chunk 重建/秒 | 低 |
| 移动端内存峰值 | 低于设备预算 |
| OOM/降级次数 | 可监控 |

### 12.3 性能测试矩阵

| 场景 | 目标 |
|---|---|
| 100 / 500 / 1000 单位 | 逻辑/渲染预算 |
| 全屏单位 + 特效 | overdraw/draw call |
| 大地图 + 多基地 | chunk 缓存/寻路 |
| 大量单位同时寻路 | 队列/延迟 |
| 大量范围伤害 | 空间索引查询 |
| 低端移动设备 | 省电/降级 |
| 内存紧张 | OOM 回退 |
| 长时间运行 | 无泄漏/漂移 |

### 12.4 验收标准

- 1000 单位下逻辑 tick 不超过预算。
- 全屏单位下帧时间 95% 在预算内。
- 空间查询不出现全表扫描（可观测）。
- 寻路队列有上限，超时能降级/放弃。
- 地图/雾/小地图缓存按预期复用。
- 移动端有画质/帧率档位，OOM 不崩溃。
- 关键指标可日志/可视化。

---

## 13. 常见性能反模式

1. 每帧全单位两两碰撞 -> O(n²)。
2. 每个单位每帧同步寻路 -> 主线程卡死。
3. 每帧重画整张地图/tile -> GPU/CPU 爆炸。
4. 每个单位每帧重新染色 -> CPU 爆炸。
5. 每帧创建大量 `ArrayList`/临时对象 -> GC 抖动。
6. 可变 dt 直接驱动逻辑 -> 不确定、不可回放。
7. 只做屏幕裁剪但模拟仍全量 -> 高估优化效果。
8. 没有寻路/查询上限 -> 峰值卡顿。
9. 移动端不降级 -> 发热/掉帧/OOM。
10. 没有性能指标 -> 无法定位瓶颈。

---

## 14. 源游戏参数与证据

### 14.1 参数

| 参数 | 值 |
|---|---|
| 逻辑 tick | 60 Hz |
| 渲染目标 | 300（高刷）/ 120 FPS |
| 省电 | ~31 FPS |
| 单机单位上限 | 1000 |
| 联机主机单位上限 | 250 |
| 空间网格 | 32×32 |
| 地图块 | ~1024px |
| 可见块 | ~3×3 + 软边 |
| PathSolver | 最多 2 |
| 寻路延迟 | 12–360 帧 |
| AI 计时 | 25 / 80 / 250 帧 |
| LOD | 缩放 < 0.45 / < 0.3 |

### 14.2 证据

- 目标：`Rusted Warfare/game-lib.jar`
- SHA-256：`8A550A37E2D8A5430866090D4E7D5892F9010B47F52A5A09350FC66C620DEEC9`
- 反编译：CFR 0.152
- 字节码辅助：JDK 17 `javap -p -c`
- 规模：1698 类，约 170,465 行 Java
- 主要证据：
  - `game/i.java`：固定步进、屏幕裁剪列表、W/X
  - `game/units/f/c.java`：UnitGeoIndex
  - `gameFramework/k/l.java`、`o.java`：PathEngine/PathSolver
  - `game/b/c.java`：地图 chunk/FBO
  - `gameFramework/m/f.java`：图集
  - `gameFramework/m/h.java`：LazyColoring
  - `gameFramework/w.java`、`gameFramework/utility/s.java`：对象列表/排序
  - `gameFramework/z.java`、`java/u.java`：帧率/省电
  - `gameFramework/SettingsEngine.java`：画质/密度/省电设置

### 14.3 不确定性

| 项 | 状态 |
|---|---|
| 通用单位对象池 | 未发现；不能证明绝对不存在 |
| 实体位置插值 | 未发现 |
| 碰撞层关系表使用路径 | 仅确认存在，实际查询入口未全部追踪 |
| 运行时 FPS/瓶颈 | 未 profiler；受地图/单位组合/设备影响 |
| 移动端默认画质 | 取决于设备/设置，不是固定值 |

---

## Appendix：最小优化清单

如果在新 RTS 中复刻类似性能：

1. 固定 tick + 可变渲染。
2. 数组/SoA 对象存储，避免热路径分配。
3. 空间索引（网格/四叉树）+ 队伍桶。
4. 寻路 job 化 + deadline + 优先级 + 内存池。
5. 屏幕/视锥裁剪；地图 chunk 缓存。
6. 纹理图集；队伍色 shader/缓存。
7. LOD + 动态分辨率 + 画质档位。
8. 雾/小地图脏标记缓存。
9. 移动端省电/降级/OOM 回退。
10. 指标、日志、性能测试矩阵。
