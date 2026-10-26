# AI 指挥官当前实现状态

> 本文描述**当前代码实际行为**，不是设计愿景。最后同步：2026-10-26。  
> 代码优先顺序：`logic/ai_*.gd` → `logic/upgrade.gd` / `logic/world.gd` → `data/config.json`。

## 1. 范围与模块

AI 指挥官（`commander`）是第三种 AI，和 `garrison`、`reddot` 并列。它拥有独立大本营、资源池和收入，会招将、招兵、升级、建塔 / 墙、扩张和进攻。

| 文件 | 职责 |
|---|---|
| `logic/ai_commander.gd` | 总控制器：tick、指令、经济、生产、反应、统计、状态 |
| `logic/ai_army.gd` | 队伍、守军、生产编成、扩张 / 进攻 / 侦察 / 守备 / 巡逻 / 粘合 |
| `logic/ai_build.gd` | 大本营升级、科技、区划特化、哨塔、木墙（**不升级**墙塔） |
| `logic/ai_economy.gd` | 经济评分、保留金、富余判断 |
| `logic/ai_profile.gd` | 默认参数；与 `data/config.json` 的 `ai.commander` 合并 |
| `logic/ai_observer` / `view/ai_order_panel.gd` | 观战与四条玩家指令 |

## 2. 每 tick 的顺序

控制器按不同 interval 分派，不是所有逻辑每帧都跑：

1. **军队**（`army_interval_sec`，默认 0.6s，`ai_army._auto()`）：
   守军 / 轮换 → 开局探索 → 回撤 → 缺兵回人口区 → 避战 →
   继续进攻 / 扩张 / 进攻判定 → 清空区划占领 → 侦察 →
   前线守备 → 区划布防 → 巡逻。
2. **生产**（`production_interval_sec`，默认 1s）：补将、按队补员、读条。
3. **建造**（`build_interval_sec`，默认 2.5s）：当前优先级见第 5 节。
4. **战略**（`strategic_interval_sec`，默认 2s）：`auto` 战略、目标、统计。

受击反应是事件驱动的（`world.on_unit_attacked()`），不属于上面的固定 tick 顺序；它通过反应冷却 / 模式锁阻止其它调度抢方向盘。

所有随机都走 `world.unit_rand`；排序使用稳定比较，避免额外 RNG。

## 3. 开局阶段（0~60 秒）

配置：`ai.commander.early_explore` / `early_game`。

- 开局只允许 **1 人队**出门，`min_field_units` / `min_squad_units` 临时降为 1。
- **不强制大本营区划留守军**（`require_garrison=false`），避免刚出门的初始将领被下一 tick 抓回。
- 守备 / 区划布防暂缓，补员回撤暂停。
- 初始唯一部队执行**开局探索**：普通移动去中立 / 空区划，顺路占空区；不主动进攻。
- 到达一个探索点后**换下一个远处点继续探**，不会「到点 → 回家 → 休整 → 再出门」循环；门口出现敌人时结束探索，交给正常防守。
- 第二支将领出现或 60 秒到期后结束探索，恢复 3 人出门门槛、守军、守备和常规回撤。

> 60 秒后到第二将领训练完成之间可能有一段短暂空档，这是正常的招募 / 训练时间；AI 不会在这段时间派光杆司令去送，但会在有外勤将后立刻恢复扩张。

## 4. 军队与占领

### 4.1 队伍

- 队伍 = 将领 + 其附属兵；AI 以**整队**下令，不单独调动某个兵。
- `field_teams` 不含守军；守军补满后可通过 `maybe_rotate_garrison()` 换下来。
- 职能：`line` / `ranged` / `guerrilla`，按将领顺序轮换；远程队留抗线，游击队只打弱守备。

### 4.2 生产

- 按队补员：守军补到 `home_team_size`，外勤补到 `field_team_size`。
- 没有外勤队时，**即使守军没补满也先招一位将领当外勤**，避免 60 秒后没有队伍可派。
- 没有满编外勤队时，补员**优先补未成形的外勤队**，不再永远先补守军。
- 招将不固定在大本营：按「被入侵 > 前线 > 大本营兜底」顺序选区划。

### 4.3 扩张 / 占领

- 目标按经济需求（缺粮 / 缺金 / 缺人口）+ 相邻 + 距离 + 守备评分选择。
- 有守军的敌方区划仍要求 `enemy_zone_min_units`（默认 7）或按守军强度；**守军清空后**改按小队规模，不再硬卡 7。
- 已进入敌方 / 中立区划、附近无敌人且没有任务的队伍，由 `_capture_cleared_zone_tick()` 直接去中心读条；侦察 / 守备 / 巡逻通过 `_is_capturing_cleared_zone()` 让路。
- 没有满编外勤队时，允许 **1 人队占完全无守军的无主区划**（`_pick_bootstrap_team()`）；有守军的敌方区划不走这条。
- 已有扩张 / 进攻任务的残队不会被 `_regroup()` 拉回基地，避免「目标 ↔ 基地」每帧互相覆盖。

### 4.4 闲置与防抽搐

- 巡逻点只包含**己方区划中心**，不再包含大本营外围四个点；只有基地一个区划时队伍不会绕基地四角。
- 缺编队可去己方前线中心 / 隘口驻守；满编队可去边界侦察；没有安全目标时守备。
- 将领交战时，`_cohesion_tick()` 只把后方停住的附属兵用普通移动拉向将领，不打断将领当前目标。
- 受击反应有冷却和模式锁；锁定期内其它调度不抢方向盘。

### 4.5 行军指令的主动结束

- 玩家「行军」不再只能等 `command_hold_sec`（默认 60 秒）到期。
- 每个 army tick（默认 0.6 秒）检查一次：**所有被派出的队**都进入目标点 `march.arrive_radius`（3 格）、没有任何队还挂着 `target` / `target_building`、且目标点 `march.hold_radius`（7 格）内**没有可见敌人** → 立即 `world.end_ai_directive()` 回到 `auto`。
- 仍有敌人 / 仍在交战 / 还有队伍没到点 → 继续行军，最迟 60 秒到期；`end_when_clear=false` 可关掉提前结束。
- 结束后面板会有 2.5 秒「已抵达」状态；目标点是敌方区划中心时，`auto` 的 `_capture_cleared_zone_tick()` 会接续读条，不会凭空放弃占领。
- 「屯兵」(`mass`) **不加**这条：它本来就是集结驻守，仍只靠 60 秒到期。

## 5. 资源与建造优先级

当前口径：**部队发展 > 升本 > 建造建筑**。

- `_production_reserve()` 先扣当前可生产缺口（补员 / 补将）的预算。
- 大本营还有下一级可升时，`ai_build.update()` 只尝试升本；本轮钱不够就**攒钱**，不进入科技 / 特化 / 塔 / 墙。
- 大本营满级、正在读条、正在重生、被占领区封锁，或将领挡位不足时，升本候选为空，才走常规建造。
- 升本后如果进入下一级，仍重复「先升本」；这是有意行为：非军事建造会在大本营未满级时长期让路。

### 5.1 大本营将领挡位

| 当前等级 | 升级目标 | 要求将领数 | 来源 |
|---|---:|---:|---|
| 1 | 2 本 | 3 | `max_generals` |
| 2 | 3 本 | 6 | `max_generals` |
| 3 | 已满 | — | — |

- `UpgradeRes.can_upgrade()` 不足时返回 `generals`，HUD 显示提示。
- `ai_build._base_upgrade_candidate()` 同样先卡挡位，不会把当前升不了的本当成攒钱目标。
- 将领计数沿用 `world.general_count_of()`，包含训练 / 重生队列。

### 5.2 占领区禁建

敌方活单位进入区划中心 3×3 占领区后：

- `world.zone_capture_blocked()` 为真；
- `can_build_at(..., faction)` / 建造命令拒绝，reason = `under_capture`；
- AI 不选该区造塔 / 封墙，不升级该区建筑、不特化、不升大本营。

### 5.3 合作 AI 队友的玩家起手资源

- 只在**合作关**（`level.mode == "coop"`）且有**同方 commander**时生效（`ai_test_hz` 就是这种局）。
- 玩家席位起手 = `max(cfg.start_food/gold, normal 难度基准)`；当前 normal 基准是 **250 粮 / 250 金**。
- **固定 normal 基准，不跟随 AI 实际难度**：选 hard 时玩家仍是 250，友军 AI 自己拿 350。
- 真人双人合作（没有 commander）、战役、观战、普通对战都**不抬**。
- 实现：`world._align_player_start_with_commander_ally()`，在 `_setup_ai_commanders()` 末尾执行。
- AI 仍然花自己的 `ai_faction_resources`（`resource_pool_for()` 优先返回它），不会花玩家的钱。

### 5.4 建筑改版（2026.10.26）

- 显示名：`wall` = **木墙**，`tower` = **哨塔**（内部 id 不变，地图 / 战役数据不用迁移）。
- 新增 **石墙**（`stone_wall`）/ **警戒塔**（`watch_tower`），建筑页第 2 行，需要 2 级大本营。
- **取消建筑升级**：`upgrade.levels` 只剩大本营；`UpgradeRes.can_upgrade()` 对非大本营直接返回 `type`，`world.building_can_upgrade()` 也只看大本营。
- AI 行为不变：继续造木墙 / 哨塔，**不再升级**任何墙塔；本轮 AI 不使用石墙 / 警戒塔。
- 所有建筑对**投掷物**伤害免伤 90%（`building.<type>.ranged_reduction`，缺省 0.9）；近战与攻城（投石车）全额。

## 6. 战斗与索敌

- **濒死将领不可被选中**：C# 批量索敌的 `_tgt_alive` 是「可攻击掩码」（`is_attackable()`，倒地 = 0）；人群分离仍用 `alive`，倒地将领照旧占位。
- `update_unit()` 发现 `ordered_target` 不可攻击时清命令；`update_combat()` 对已锁定但刚倒地的目标当场脱战。
- 飞行中的投掷物不再追倒地单位。
- 索敌到建筑：除无驻防归属的 `NPC` 测试敌人外，任何阵营在警戒半径内发现可打建筑都会还手。

## 7. 配置入口

- 默认值：`logic/ai_profile.gd`。
- 覆盖值：`data/config.json` 的 `ai.commander`。
- 常用段：
  - `early_explore` / `early_game`
  - `production` / `expand` / `patrol` / `idle` / `cohesion`
  - `march`（`arrive_radius` / `hold_radius` / `reissue_sec` / `end_when_clear`）
  - `build` / `reaction` / `roles`
  - `difficulty`

## 8. 测试基线

2026-10-26 本轮聚焦（未跑全量）：

- `test_ai_commander.gd`：**309** 项通过（新增起手资源 / 行军主动结束 21 项）。
- `test_ai_order_panel.gd`：24 项通过。
- `test_ai_observer.gd`：57 项通过。
- `world.gd` / `ai_army.gd` / `ai_profile.gd` / `test_ai_commander.gd` 的 `--check-only` 均通过。

上一次全量（2026-10-25）：

- `tools/check-syntax.ps1`：**205** 个 `.gd` 通过。
- `tools/run-tests.ps1`：**81 套 / 8092 项断言全部通过**。
- 重点套件：
  - `test_ai_commander.gd`（288）：生产、建造、扩张、占领、开局探索、防闲置、优先级。
  - `test_ai_observer.gd`（57）：观战入口、AI 接管、只读 / 可下令。
  - `test_downed.gd`（265）：濒死保护、索敌排除、再起 / 召回。
  - `test_upgrade.gd`（237）：升级、特化、将领挡位、占领区禁建。

## 9. 已知取舍

- 大本营升不满时，非军事建造会长期让路；这是「升本优先」的直接代价。
- 60 秒探索结束后，第二将领训练完成前存在短暂空档。
- 正常行军路径仍可能穿过大本营区划；这不是专门绕圈，而是路径规划结果。
- 行军提前结束会把方向盘交回 `auto`：刚清空的区划若还在读条，由 `_capture_cleared_zone_tick()` 接续；`auto` 也可能转去别的战略目标（玩家可再下行军）。
- 停火判定只看**目标点 `hold_radius` 内的可见敌人**；远处 / 迷雾里的敌人不会阻止结束。
- AI 的确定性依赖 `world.unit_rand` 和稳定排序；改 AI 时不要引入额外 RNG。
