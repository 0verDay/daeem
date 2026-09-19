# Godot 版 DAEEM · HTML 原型对照

> 本文是**搬运工的对照表**：HTML 版的每个文件对应 Godot 版的哪个文件、哪些能照搬、哪些必须重写、哪些干脆不要。
> 行数是 HTML 版当时的实际规模（`dev_html/`），用来估工作量。
>
> 架构约定见 [`architecture.md`](architecture.md)；每条坑的细节见 [`pitfalls.md`](pitfalls.md)。

---

## 一、总账

| | HTML 版 | Godot 版（本轮） |
|---|---|---|
| 语言 | 原生 ES Module（JS） | GDScript |
| 逻辑位置 | `js/*.js`（与渲染混在 main.js 里） | `logic/`（纯 `RefCounted`） |
| 渲染 | `js/render.js` 手写 Canvas 2D | `view/`（`TileMapLayer` + `Node2D`） |
| UI | `index.html` + `css/style.css` | `view/hud.gd` + `view/ui_layout.gd` 等（代码搭 `Control` 树；布局照参考图，见 route.md 第九节） |
| 坐标 | CSS 像素 + DPR 换算 | 逻辑用「格」，渲染乘 `CELL_SIZE` |
| 数值 | `js/config.js`（JS 对象字面量） | `data/config.json` |
| 地图 | `js/map.js` 手写字符数组 | `data/map_01.json` |
| 测试 | Node + Python 双套（657 项） | `tests/*.gd`（纯逻辑 + 渲染/UI 接线断言，现在 **12 个套件 / 997 项**） |
| 联机 | `js/net.js` + `net/serve.py` | **本轮不做**（第 1 轮） |

**工作量感性估计**（行数为实测）：

| 部分 | 行数 | 本轮要不要搬 |
|---|---|---|
| 玩法规则（`config`/`util`/`path`/`map`/`zone`/`building`/`unit`/`faction`，共 8 个模块） | **1675** | ✅ 全搬（拆成 `logic/`） |
| 联机客户端 `net.js` | 456 | ⚠️ 只搬快照部分 |
| 渲染 `render.js` | 860 | ❌ 重写（Canvas → 节点） |
| 入口 `main.js`（含 DOM 接线、联机、HUD） | 1636 | ⚠️ 拆三份，只搬逻辑 |
| **`js/` 合计** | **4627** | —— |

也就是说：**真正要搬的规则大约 1700 行**，其中 A*、直线拉直、战斗、占领、城墙这几块
（约 800 行）是核心，也是踩坑最集中的地方。其余是 DOM 接线与联机，本轮不需要。
行列里的行数都含结尾空行，各模块的精确值见第二节表格。

---

## 二、逐模块对照

| HTML 源文件 | 行数 | Godot 对应 | 处置 |
|---|---|---|---|
| `js/config.js` | 185 | `data/config.json` | **翻译**：JS 对象 → JSON。数值一个不改 |
| `js/util.js` | 111 | `logic/grid.gd` | **重写**：`Grid` 类、`DIRS4` / `DIRS8`、octile 距离（A* 用线性扫描取最小，没用 `MinHeap`） |
| `js/path.js` | 285 | `logic/pathfinder.gd` | **照搬算法**：A* / `segment_clear` / `smooth_path` / `reachable_tiles`；**另加**八方向 + `round_corners`（见 route.md 第七节的有意偏离） |
| `js/map.js` | 168 | `logic/map_data.gd` + `data/map_01.json` | **拆分**：数据进 JSON，逻辑留下 |
| `js/zone.js` | 178 | `logic/zone.gd` | **照搬规则**（含 `progress_by`） |
| `js/building.js` | 136 | `logic/building.gd` | **照搬**：`blocks(faction)` / 血量 / 箭塔 |
| `js/unit.js` | 528 | `logic/unit.gd` + `logic/combat.gd` | **拆分**：移动一段、战斗一段 |
| `js/faction.js` | 84 | `logic/faction.gd` | **照搬**：两条方向相反的规则 |
| `js/net.js` | 456 | `logic/snapshot.gd`（只留快照部分） | **只搬快照**：序列化/应用/缺字段容忍 |
| `js/render.js` | 860 | `view/*` | **重写**：不再手绘 Canvas，改用节点与 `TileMapLayer` |
| `js/main.js` | 1636 | `logic/world.gd` + `view/main.gd` + `view/input_controller.gd` | **拆三份**（见下） |
| `index.html` | 192 | `view/main.tscn` + `view/hud.gd`（+ `ui_layout` / `command_card` 等） | **重搭**：HTML 结构 → `Control` 树；UI 改版后布局以参考图为准（route.md 第九节） |
| `css/style.css` | 239 | `view/ui_style.gd`（StyleBox 工厂）+ Godot Theme | **重做**：面板 / 部队行 / 命令格 / 页签的四态样式都在这里 |
| `net/serve.py` | 485 | —— | **本轮不搬**，第 1 轮按同样思路重写 |
| `tools/*`（17 个脚本） | ~5000 | `tools/run-tests.ps1` + `tests/*.gd` | **只留思想**：纯逻辑断言 + 一键 runner |

> **行数口径**：以上全部为「文本按换行符切分后的段数」，**含结尾空行**，
> 与第一节汇总表同源。同一份文件在不同工具下会差 1（有的工具不数结尾空行），
> 所以引用时请用本表，不要另算一遍 —— 数字对不上就会变成新的一种"文档说谎"。

### 2.1 `main.js` 是最需要拆的（1636 行 → 三个位置）

它今天同时干着四件事，在 Godot 里必须分开：

| `main.js` 里的内容 | 去处 | 说明 |
|---|---|---|
| `state` 对象、`update(dt)` 主循环、`checkVictory` | `logic/world.gd` | 逻辑状态与推进 |
| `onCombatEvent`（日志/收尸/胜负） | `logic/world.gd` 收集事件 → `view/hud.gd` 展示 | **逻辑不直接写 UI**（事件由 `tick()` 末尾统一交出去，别在开头清空 —— 否则命令事件会被丢掉，见 route.md 9.4） |
| `initDom` / `bindUI` / `updateHud` / `resizeCanvas` | `view/hud.gd` + `view/ui_layout.gd` / `squad_panel.gd` / `detail_panel.gd` / `command_card.gd` / `page_tabs.gd`、`view/main.gd` | 纯表现；几何集中在 `ui_layout.gd` |
| `pointerInfo` / 键鼠处理 / `orderMove` / `tryBuildAt` | `view/input_controller.gd` → 命令 | 输入只产命令 |
| 联机接线（`initNet` / `handleNetWelcome` / `ensureLocalWorld` / 准备界面） | **本轮不要** | 第 1 轮再按命令/快照边界接 |
| `window.RTS` 调试句柄 | `view/main.gd` 里挂一个 `RTS` 单例或 `Engine` 元数据 | 调试手感的替代品，值得保留 |

---

## 三、函数级对照（核心算法）

这些函数**算法要一模一样**，写法改 GDScript 即可。名字建议保持对应，方便两边对着读。

| HTML | Godot 建议 | 签名要点 |
|---|---|---|
| `findPath(state, from, to, faction)` | `Pathfinder.find_path(map, buildings, from: Vector2i, to: Vector2i, faction) -> Array[Vector2i]` | 返回**不含起点、含终点**；不可达返回 `null`/空 |
| `segmentClear(state, ax, ay, bx, by, faction)` | `Pathfinder.segment_clear(...) -> bool` | **起点格不检查**；对角穿越要双检 |
| `smoothPath(state, points, faction)` | `Pathfinder.smooth_path(...)` | 贪心：每次跳到「直线可达的最远点」 |
| `reachableTiles(state, from, faction)` | `Pathfinder.reachable_tiles(...) -> Dictionary` | 按阵营通行规则做 BFS |
| `nearestReachable(state, from, target, faction, r)` | `Pathfinder.nearest_reachable(...)` | **必须过滤「from 真走得到」** |
| `findBlockingWallToward(state, from, to, faction)` | `Pathfinder.find_blocking_wall_toward(...)` | 两个条件：挨着自己可达区 + 离目标最近 |
| `Unit.moveTo(state, worldPt)` | `Unit.move_to(world: World, p: Vector2) -> bool` | 终点是鼠标像素位置；不可达时改走最近可达格 |
| `Unit.stepAlongPath(state, dt)` | `Unit.step_along_path(world: World, dt: float)` | 每帧距离预算 = 速度×格宽×dt；跨拐点带余量 |
| `Unit.updateCombat(state)` | `Combat.update_unit(world, unit, dt)` | 够得着就站住打；追太远就放弃 |
| `Unit.updateBuildingCombat(state)` | `Combat.update_building_target(...)` | 建筑占满整格 → 攻击距离额外算半格 |
| `Unit.tickRespawn(state, dt)` | *本轮不做* | 复活是对战机制 |
| `Building.blocks(faction)` | `Building.blocks(faction) -> bool` | `same_side(faction, owner)` |
| `updateTowers(state, dt)` | `Combat.update_towers(world, dt)` | **索敌用 `same_side`**，别抄成 `==` |
| `updateZones(state, dt)` | `Zone.update(world, dt)` | 每阵营独立进度；渲染用的 `progress` 取领先者 |
| `ownedTileCount(state, owner)` | `Zone.owned_tile_count(world, owner) -> int` | 按区块统计（不是逐格） |
| `makeSnapshot(state)` / `applySnapshot(...)` | `Snapshot.to_snapshot(world)` / `apply_snapshot(...)` | 短字段名；只发结果 |

---

## 四、必须照抄的数值（`config.json` 的初始内容）

**这些数字不是随便填的**，是 HTML 版调过手感的结果。迁移时先原样搬，再按 Godot 的观感微调。

| 项 | 值 | 备注 |
|---|---|---|
| 地图 | 24 × 16 格，**四连通 → Godot 版改成八方向**（有意偏离，见 route.md 第七节） | 「地块数量不变」是全程约束 |
| 渲染格宽 | `CELL_SIZE` | HTML 是 120px；Godot 建议先 64px |
| 单位速度 | 2.4 格/秒 | = 60fps 下 0.04 格/帧 |
| 森林减速 | × 0.5 | |
| 单位半径 | 0.1 格 | 直径只占格宽 20%（**刻意的**，单位远小于地块） |
| 将领 | 伤害 26 / 射程 1 格 / 间隔 0.9s / 生命 200 | |
| 测试敌人 | 伤害 10 / 射程 1 格 / 间隔 1.2s / 生命 60 / 速度 1.8 格/s | |
| 警戒半径 | 4 格 | |
| 追击上限 | 警戒半径 × 1.8 | |
| 追击重寻路间隔 | 0.3s | 不要每帧重算 |
| 拆建筑伤害 | 40 | **所有攻击者都是 40**，节奏随各自 `cooldown` |
| 城墙生命 | 300 | 敌人 40/1.2s → 约 9.6s 拆一堵 |
| 箭塔 | 伤害 12 / 射程 3 格 / 间隔 0.8s | 打**最近**的敌人，不误伤己方 |
| 大本营生命 | 1000 | 单机保底 1 血、永远打不掉 |
| 区块划分 | 6 × 4 = 24 块 | 每块 16 格（占位规则，等地图编辑器） |
| 占领耗时 | 4 秒 | 多个同阵营单位**不叠加**加速 |
| 进度回退 | 0.6 / 秒 | |
| 资源 | 每己方地块 1 粮食 + 1 黄金 / 秒 | |
| 相机 | 缩小到能看全图 / 放大 1.6 / 键盘平移 900 px/s / 边缘滚屏边距 44px、最高 1500 px/s | |

---

## 五、注释也要搬（**这部分是 HTML 版最值钱的资产**）

HTML 版的代码注释里藏着一批「当时为什么这么写」的记录，**删掉它们等于把踩过的坑重新挖开**。
迁移时至少要把这些注释一起搬过去（对应 [`pitfalls.md`](pitfalls.md) 第三节）：

| 位置 | 要搬的注释内容 |
|---|---|
| `path.js` `nearestReachable` | 「必须加一层从 `from` 真的走得到的过滤，否则 BFS 第一圈返回墙另一侧的格子」 |
| `path.js` `segmentClear` | 「用超覆盖 DDA……起点所在格不检查，因为单位可能正站在后来被建筑占住的格子上」 |
| `unit.js` `moveTo` | 「`moveTo()` 原地不动时也返回 true，所以不能只看它判断是不是到位了」 |
| `building.js` `removeBuilding` | 「`force` 是给战斗摧毁用的；不传会留下『基地被打爆却还立着』的坏状态」 |
| `building.js` `blocks` | 「判定基准从『是不是 player』改成『是不是我自己人』」 |
| `zone.js` 顶部 | 「进度改成每阵营独立存在 `progress_by` 里，旧的单一 `progress` 会互相抵消」 |
| `main.js` `applyFactionLayout` | 「多阵营共存时必须**追加**本阵营部队，整体替换会让房主手里只剩一方的兵」 |
| `main.js` `checkVictory` | 「分母必须是**在场**的阵营，不是名单里的席位」（这条导致了「一打开就判 P1 赢」的线上事故） |
| `main.js` `resetMatch` | 「只清理 NPC 敌人；写成 `=== 'enemy'` 会让所有玩家单位被跳过，重开一局后一个单位都不剩」 |
| `net.js` `applySnapshot` | 「缺 `match` 字段时保持本地状态，不能当成未结束把它重置掉」 |
| `render.js` 顶部 | 「相机数学与所有输入换算一律使用同一套屏幕坐标」 |

---

## 六、明确**不要**搬的东西

| 不要搬 | 为什么 |
|---|---|
| `js/net.js` 的 WebSocket 客户端 | 本轮不做联机（第 1 轮按命令/快照边界重写） |
| `net/serve.py` | 第 1 轮重写；它和游戏逻辑零耦合，搬过来也没用 |
| `main.js` 的 DOM 接线、`resizeCanvas`、DPR 处理 | Godot 引擎负责这些，手写只会引入新 bug |
| `render.js` 的手绘地形 | 换成 `TileMapLayer` |
| 死代码（`unit.radius`、`keepDead`、`lastSnapTime`、`RESOURCES`、`manhattan`、`claimedBy`、`progressLead`） | 等于白送技术债，见 [`pitfalls.md`](pitfalls.md) 3.12 |
| 浏览器测试（`browser-test.py` / `test-module-version.py`） | 依赖无头 Chromium，且 Godot 有更好的验证方式 |
| 单文件打包器（`build_single_file.py`） | Godot 自己会导出 |

---

## 七、映射一个具体例子（建立手感用）

**HTML（`unit.js` 的移动一段）**：

```js
stepAlongPath(state, dt) {
  let remaining = this.speed * CONFIG.cell * dt;   // 本帧可移动的像素距离
  while (remaining > 1e-9 && this.path && this.path.length > 0) {
    const node = this.path[0];
    const d = Math.hypot(node.x - this.px, node.y - this.py);
    if (remaining >= d) { this.px = node.x; this.py = node.y; remaining -= d; this.path.shift(); }
    else { this.px += (dx / d) * remaining; remaining = 0; }
  }
}
```

**Godot（`logic/unit.gd`）**：

```gdscript
func step_along_path(world: World, dt: float) -> void:
    # 逻辑坐标是「格」：速度(格/秒) × dt，不再乘 CELL_SIZE
    var remaining := speed() * dt
    var guard := 0
    while remaining > 1e-9 and not path.is_empty() and guard < step_guard(map):
        guard += 1                              # 防止病态路径死循环（按地图尺寸算，见 unit.gd）
        var node: Vector2 = path[0]
        var delta := node - pos
        var d := delta.length()
        if d <= 1e-6:
            path.pop_front()
            continue
        if remaining >= d:
            pos = node
            remaining -= d
            path.pop_front()
        else:
            pos += delta / d * remaining
            remaining = 0.0
    if path.is_empty():
        pos = goal_pt if goal_pt != null else pos
        moving = false
```

**三处刻意的差异**：

1. **不乘 `CELL_SIZE`** —— 逻辑坐标本身就是「格」，像素换算只在 `view/` 做
2. **加了 `guard`** —— HTML 版靠 `path.shift()` 必然收敛，Godot 里显式设上限更稳
3. `goal_pt` 用 `Variant`/可空约定要写清楚 —— GDScript 的 `Vector2` 不能为 null，
   要么用 `has_goal: bool`，要么用 `Vector2.INF` 当哨兵值（**选一种并全项目统一**）
