# dev_plan_11　1000 单位帧时间优化（先量准，再优化）—— 设计与实测

> 本文是**独立编号的第 11 份规划文档**（第 10 份与 route.md 第四十一节在一次事故中损坏、已删）。
> 与本工程既有口径一致：不含工时估算；每条都回答「谁读它 / 缺了怎么办 / 判据在哪」；
> ★ = 已拍板或不能改的硬约定；⚠️ = 已实测踩过的边界；❓ = 还要拍板的小项（见第六节）。
>
> 现状总纲见 [`docs/route.md`](docs/route.md) 第四十三节（本文的精简版），
> 架构见 [`docs/architecture.md`](docs/architecture.md)。

---

## 〇、一页结论

| # | 目标 | 状态 | 数字 |
|---|---|---|---|
| 1 | 修好量尺（`bench_fps_3d` 的双重 `_process`） | ✅ | 墙钟不再重复计数；分项改由场景内部累计 |
| 2 | 拿到可信的按节分诊表 | ✅ | 见第 4.2 节 |
| 3 | 视图合并 + 迷雾单次采集 + 建筑空间索引 | ✅ | `_process` **22.90 → 17.02 ms/帧**（−26%） |
| 4 | 逻辑层 `units` 循环本体（~1.9 ms） | ⏳ 未做 | 见 5.2 |

**一句话**：先把「量什么」这件事弄对（本机墙钟里约 18 ms 是引擎/呈现的固定开销，与游戏无关），
再把视图层里明显的重复遍历合并掉、把迷雾的「同帧两次采集」去掉、把「最近敌建筑」改成查**建筑空间索引**；
逻辑层的 `units` 循环本体需要更大的设计动作，单独排一轮。

---

## 一、已拍板的口径（来自用户三问）

1. ★ **先量准真实 3D 整帧**，再按数据优化（不先猜热点）。
2. ★ **范围全开**：`logic/` + `view/` + `logic/crowd/*.cs` + 基准脚本都可动。
3. ★ **不加性能回归断言**：性能只靠 `bench_*` 人工看，不进 `tools/run-tests.ps1`。
4. ★ **硬护栏**：玩法行为逐位不变；`logic/` 纯 `RefCounted`（不碰 `Node`）；结果确定性
   （**不许**用随机数决定结果 —— 存档 / 回放依赖它）；现有测试保持绿；数值进 `config.json`；
   不写 `class_name`（用 `preload` 常量）。

---

## 二、为什么「先量准」：两份基准原本是打架的

| 基准 | 场景 | 数字（文件注释里记的） |
|---|---|---|
| `tests/bench_crowd.gd` | 无头、`with_ai=false`、纯逻辑、1000 单位/100×100、同一团 | 逻辑 ≈5.9–6.0 ms/帧 |
| `dev_plan_9` 记的 `bench_fps_3d` | 真实 3D 场景、AI 开、1000 单位 | 整帧 82.35 ms/帧 |

**根因（已读代码确认）**：`tests/bench_fps_3d.gd` 把 `game` 挂进树（`root.add_child(game)`），
**又在循环里手动调 `game._process(1/60)`** ⇒ 引擎每帧还会再调一次 `_process`，
同一次 `_process` 每帧跑两遍 ⇒ `avg` 与分项互相污染。

---

## 三、M0 —— 修正量尺（已完成）

* `tests/bench_fps_3d.gd`：**去掉双重驱动**（不再手动调 `_process`），墙钟只量真实帧间隔；
  加机器漂移校准（首尾各跑一次参考负载）；`DAEEM_PROFILE=0` 可关剖析（用来验证剖析不改结论）。
* `view/game_scene3d.gd`：新增可选逐节剖析 `profile_on` / `profile_us` / `profile_reset()`
  （与 `logic/world.gd` 同款，默认关闭，关闭时只多几次 `if`）；分段：
  `input` / `tick` / `view/units` / `view/buildings` / `view/other` / `view/overlay` / `ground.rebake` / `camera`。
* `tests/bench_crowd.gd`：修键名（`enemy_ai` → `ai`，与 `world.tick` 注册的键对齐，否则那一行永远打 0）。

---

## 四、M1 —— 分诊表（已完成）

### 4.1 一个必须先知道的事实：本机的墙钟不能用

1000 单位、真实 3D 场景、AI 开、1920×1080、vsync off：

* `_process`（逻辑 + 视图同步）= 22.90 ms/帧；
* 墙钟 `avg` ≈ 39 ms，其中约 **18 ms 是引擎/呈现的固定开销，与游戏无关** ——
  实测 `DAEEM_HIDE=ground,fog,units,buildings` avg **完全不变**（39.23），1 单位时也有 ~12 ms。
* ⇒ ★ **可动指标是 `_process` 与它的分项表**，不是墙钟 fps。

### 4.2 分项（优化前，ms/帧）

| 节 | 前 | 层 |
|---|---|---|
| units（含 combat 4.49 / step 1.34 / reclaim 0.21） | 7.92 | 逻辑 |
| view/units | 4.446 | 视图 |
| fog | 2.90 | 逻辑 |
| view/buildings | 1.997 | 视图 |
| collision | 1.55 | 逻辑 |
| zones / ai / towers / recruit | 0.83 / 0.71 / 0.46 / 0.26 | 逻辑 |

诊断：视图侧 `unit_view_3d` 每帧对 `world.units` 走**三遍**、`building_view_3d` 的
`_fade_marked_tiles()` 又走一遍 —— **每帧约 4 遍单位遍历 + 4 遍迷雾查询**。

---

## 五、M2 —— 优化

### 5.1 已完成

| 改动 | 落点 | 效果 |
|---|---|---|
| 单位层三遍遍历合并成一遍（顺带收集「可见将领 / 选中或动效单位」两张小表） | `view/unit_view_3d.gd` | view/units ↓ |
| 建筑层复用单位层算好的「可见单位所在格」（不再自己扫一遍 + 迷雾） | `view/building_view_3d.gd` + `view/game_scene3d.gd` | view/buildings **1.997 → 0.248** |
| 淡出判定从「单位标 3×3 + 建筑查 1 格」改成「单位标 1 格 + 建筑查自己 3×3」（语义等价） | 同上 | 每单位少 8 次字典写 |
| 选中集合为空时整段跳过每单位 `String(id)` + 两次查表；变体键记忆上一把 | `view/unit_view_3d.gd` | view/units **4.446 → 2.778** |
| `refresh_needed` 采集后紧随的 `update` 复用（同帧不再采两遍） | `logic/fog.gd` | fog **2.90 → 2.232** |
| `nearest_enemy_building` 改查**建筑空间索引**（粗网格，按 `building_revision` 按需重建），中立 / 无敌建表时剔除 | `logic/combat.gd` + `logic/world.gd` | 单该函数 **~2.9 → ~1.2 ms**；units **7.92 → 6.141** |
| `tick` 单位循环变量静态类型化 | `logic/world.gd` | （噪声内，保留） |

⚠️ 三处「消费一次 / 按需重建」的语义要点：
* `building_view_3d._fade_marked_tiles()` 读后即清 —— 「单独调 `sync()`」（测试）与「每帧喂」两条路都对；
* `fog.update()` 只在「紧邻 `refresh_needed` 之后」复用那一次采集（那一次装的是**当前**世界，不是上一帧）；
* `combat.nearest_enemy_building` 在网格不新鲜时先补建一次（测试直接调的路径），结果**逐位一致**。

**`_process` 22.90 → 17.02 ms/帧**（−26%）；`tools/run-tests.ps1` 全量 **43 套 / 5226 项 / ALL PASS**。

### 5.2 未做（见 5.1 之后；需更大的设计动作，单独排一轮）

| # | 目标 | 事实 / 根因 | 做法 |
|---|---|---|---|
| 1 | **units 循环本体 ~1.9 ms** | 1000 次 `tick_frame` 调用 + 逐单位 GDScript 分支（冷却 / 早退 / 索敌入口） | 只能在 `logic/` 或内核层做更大的重构（搬去 C# / 减少逐单位调用） |
| 2 | **collision 1.55 / units/step 1.27** | 内核批次 + 路径推进（已接近边际） | 收益已小，优先级低 |

### 5.3 明确不做（防「顺手做了」）

不做「把 3D 渲染成 2D 贴图」式折中；不引入美术资源；不动玩法规则与数值平衡；
不为了性能牺牲确定性；不改 `data/maps`、`data/campaigns`、三个 Python 编辑器。

---

## 六、❓ 还要拍板的小项

| # | 问题 | 建议 |
|---|---|---|
| 1 | 本机 ~18 ms 的「引擎/呈现固定开销」要不要单独查（可能与 D3D12 呈现 / 窗口有关，与游戏无关） | 可以先不管 —— 它不进 `_process`，换台机器 / 换驱动可能自然消失；真要查就从「1 单位时也有 12 ms」入手 |
| 2 | 逻辑层（combat / fog）要不要现在排下一轮 | 建议排：这两项加起来 ~7 ms，是 `_process` 的最大头 |
| 3 | 是否引入「性能回归断言」 | 按用户口径**不加**（只在 `bench_*` 人工看） |

---

## 七、怎么跑

```powershell
# 逻辑（无头，一个进程只跑一个场景 —— 见 bench_crowd 的漂移说明）
$env:DAEEM_ONLY='idle'; <mono Godot>_console.exe --headless --path <工程> --script res://tests/bench_crowd.gd
$env:DAEEM_ONLY='move'; <mono Godot>_console.exe --headless --path <工程> --script res://tests/bench_crowd.gd

# 真实 3D 帧（**不加** --headless）
$env:DAEEM_FPS_UNITS='1000'; $env:DAEEM_FPS_FRAMES='120'
<mono Godot>_console.exe --path <工程> --script res://tests/bench_fps_3d.gd
# 隐藏图层二分固定渲染开销：$env:DAEEM_HIDE='ground,fog,units,buildings'
# 关掉剖析对比：$env:DAEEM_PROFILE='0'
```

**读数字的顺序**：先看 machine drift（>1.3 直接作废）→ 再看 p95 / 长帧 → 再看分项 → 最后才看平均。
