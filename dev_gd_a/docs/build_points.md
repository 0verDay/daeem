# 建造点位 / 边缘区 / 城墙环（2026.11.18 新机制）

> 本文是「建筑只能建在随机生成的预置点位上、城墙只围区划中心、边缘区只限制巡逻」
> 这套规则的**权威说明**。
> 涉及：`logic/level.gd`、`logic/zone.gd`、`logic/world.gd`、
> `logic/command_processor.gd`、`logic/ai_build.gd`、`logic/garrison_ai.gd`、
> `view/hud.gd`、`view/overlay_view_3d.gd`、`view/build_point_view_3d.gd`、
> `data/config.json` 的 `build` 段、战役编辑器（`tools/campaign_editor/`）。

---

## 0. 用户口径（2026.11.18）

- **建造点位不再写在地图里**。每关在战役编辑器「区划」页给**每个区划**填一个数量
  （`zones[].build_point_count`）；**进图时**按这个数量随机生成点位。
- 数量**缺省 = `config.build.points_per_zone`（当前 2）**，填 `0` = 这个区**不生成**点位。
- 生成时**排除**：
  - **边缘区**（`zones[].no_go`，与阵地性 AI 的巡逻禁区**是同一个东西**）；
  - **区划中心**与中心外的**城墙环**；
  - 山地 / 水域；
  - **当前已有建筑**占的格（地图预置 / 大本营 / 区划中心 / 关卡摆放）。
- 战役编辑器里**非城墙建筑可以放在本区任意可通行格**（不再只认地图点位）；
  城墙仍只能围**区划中心**那一圈。
- **地图编辑器不再读 / 写 / 补** `zone_list[].build_points`；老图里遗留的键运行时忽略，
  地图编辑器保存时丢掉。
- 每局**真随机**，但必须同步：房主把本局随机种子（`world.rand_salt`）随合作 `start`
  发给客机，客机用同一个种子生成同一套点位。

---

## 1. 数据

### 1.1 关卡 `zones[]`

```json
"zones": [
  {
    "id": 0,
    "owner": "F1",
    "no_go": [[3, 4], [4, 4]],
    "build_point_count": 3
  }
]
```

| 键 | 含义 |
|---|---|
| `owner` | 开局归属（空串 = 无主） |
| `no_go` | **边缘区**：这一区不进巡逻 / 不生成点位的格子集合；可省略 |
| `build_point_count` | 进图时随机生成几个建造点位；缺键 = config 默认 2，`0` = 不生成 |

- 数据仍是**关卡层**：每关可以不同。地图 JSON 没有这两个字段。
- 读取入口：`logic/level.gd` 的 `zone_no_go` / `zone_build_point_counts`。
- 战役编辑器负责写入；地图编辑器不再接触。

### 1.2 地图 `zone_list[].build_points`

**已废弃**：运行时 `logic/map_data.gd` 不再读，地图编辑器不再写 / 补。
老地图里还留着这个键也不会生效；保存一次地图后它自然消失。

### 1.3 运行时生成

`zone.generate_build_points(map, counts, blocked, rand_salt)`：

1. 每个区划取 `counts[zid]`，缺键用 `config.build.points_per_zone`，负数按 0；
2. 候选格 = 该区划自己的地块里满足：
   - 存在、可通行（山地 / 水域不行）；
   - 不是区划中心、不在中心的城墙环上；
   - 不在边缘区里；
   - 不在 `blocked`（所有已落成建筑占的格）里；
3. 用 `RandomNumberGenerator` 洗牌取前 N 个；候选不够就少生成，不报错；
4. 输出按 `(y, x)` 排序，重建「格 → 点位所属区划」反查表。

调用时机：`world.reset()` 在所有固定建筑（地图预置 / 各方大本营 / 区划中心 /
关卡 `start_buildings`）都就位之后；换图（`swap_map`）末尾也重新生成一次。

### 1.4 随机与同步

- 种子 = `world.rand_salt` + 区划 id + 地图尺寸；**同一局内可复现**。
- 合作模式：`net/host_session.gd` 的 `start` 包带 `rand_salt`；
  `view/game_scene3d.gd` 的客机把它传给 `create_from_level(..., seed_value)`。
- 单机/回放要固定布局时，给 `World.create_from_level` 传 `seed_value` 即可。

---

## 2. 规则

### 2.1 非城墙建筑：只能落在点位

权威判据：`world.build_reject_reason(type, tx, ty, faction)` → `""` 才可建。

拒因码（事件 `build_rejected.reason` 同值）：

| 码 | 含义 |
|---|---|
| `not_build_point` | 非城墙建筑，但这一格不是任何区划的建造点位 |
| `not_zone_center` | 城墙，但落点不是某个区划中心 |
| `wall_no_space` | 城墙环一圈全被地形 / 建筑挡住，没有可建位置 |
| `occupied_or_terrain` | 地形不可建 / 已被建筑占住 |
| `not_in_zone` | 不是自己的区划 |
| `under_capture` | 区划正被敌方踩中心（整块禁建） |
| `base_level` | 大本营等级不够（石墙 / 警戒塔等第二行建筑） |
| `cost` | 资源不足 |

- 「自己的区划」= `world.accepts_owner(zone.owner, faction)`；
- **拆掉建筑后点位仍然存在**，可以再建。

### 2.2 城墙：一张牌围一圈

- 落点 = 某个**区划中心格**；
- 建的位置 = `world.wall_ring_buildable_tiles(zid, faction)`：
  几何环（`zone.wall_ring_tiles_of()`，默认 1 层 = 3×3 外圈 8 格）逐格过滤：
  在图上、在演出边界内、可通行、没被建筑占住、**属于自己阵营的区划**、没被敌方踩中心；
- **一次 `build` 命令把这一圈建满**，花费按**一张牌**算；
- 被山脉 / 水域 / 已有建筑 / 邻区挡住的格子直接跳过；
- 一圈没有可建位置时拒绝（`wall_no_space`），不扣钱。

### 2.3 边缘区

- 数据键仍是 `zones[].no_go`（**只改界面叫法**，现有数据零迁移）；
- 语义：**阵地性 AI 不会巡逻至其区划的边缘区** —— 只影响巡逻目标点，
  不挡走路、不影响追击 / 守中心 / 攻城警报；
- **建造点位也不会生成在边缘区里**；
- 编辑器里按区划手涂任意格子；区划中心、别人的地、整块区划都被当场拦住。

---

## 3. 配置（`data/config.json` → `build` 段）

| 键 | 默认 | 含义 |
|---|---|---|
| `points_per_zone` | 2 | 关卡没填 `build_point_count` 时的默认生成数量 |
| `drop_radius_tiles` | 1.5 | 拖牌时指针离点位多远算「落在它上面」 |
| `wall_ring_radius` | 1 | 城墙环层数（1 = 中心 3×3 外圈 8 格） |

装载进 `ConfigRes`：`build_points_per_zone` / `build_drop_radius_tiles` /
`build_wall_ring_radius`。

---

## 4. 界面（拖拽建造）

1. 从手牌拖起建筑牌 → `hud._begin_build_drag()`：
   - `world.build_anchors_for(type, my_faction)` 算出所有可落点：
     普通建筑 = 己方区划里「空着的点位」；城墙 = 己方区划的**中心格**；
   - `overlay.drag_anchor_tiles` 拿到同一份列表 → 逐个画小方框 + 中心亮点。
2. 指针移动 → `hud._update_build_drag_preview()`：
   - 若指针与某锚点中心的世界距离 ≤ `drop_radius_tiles`，吸附到最近的那个；
   - 地图上没有 3D 建筑虚影；卡牌本身淡到 0.72；
   - 圆形范围指示有进出动画（0.18s / 0.12s）。
3. 松手 → `hud._commit_card_build_drag()`：发 `{"kind":"build",...}`；
   权威侧（`command_processor.apply_build`）再判一次。
4. `view/build_point_view_3d.gd` 常驻显示己方空点位（碎石 / 断木），
   拖建筑牌时高亮；点位是进图随机生成的，所以**每次开局位置可能不同**。

---

## 5. AI

`logic/ai_build.gd` 与玩家走同一条命令路径：

- 箭塔 / 粮田 / 房屋 / 矿脉：只从 `world.build_points_of_zone(zid)` 里挑空位；
- 城墙：`_try_wall_ring()` 发一条「以区划中心为落点」的 build 命令；
- 经济建筑与箭塔共用一个区划的点位；`_resource_building_capacity()` 按**实时空点位数**
  计算，**不假设每区 2 个**；
- 点位数量由关卡决定，AI 的「单区划多塔 / 多资源建筑」目标会被实际点位数夹住。

---

## 6. 编辑器

### 6.1 战役编辑器（`tools/campaign_editor/`）

「区划」页每区一行：

```
区划名 | 开局归属 | 边缘区 N 格 [涂刷/停止] [清空] | 点位 [3]
```

- 「点位」= `zones[].build_point_count`（进图时生成几个；0 = 不生成）；
- 「涂刷」= 边缘区（红色网点），只影响巡逻 / 点位生成；
- 换地图 / 新建关卡时，边缘区与点位数量**整张重建**（默认 = config 的 2）。

**摆放建筑**：

- 非城墙建筑：本区任意可通行格（不能压区划中心、同一格不能叠两栋）；
- 城墙：只能围区划中心那一圈（画布上有橙色虚线）；
- 落点不合法的建筑在载入 / 换图时**直接删掉**，导出前再拦一次。

### 6.2 地图编辑器（`tools/map_editor/`）

- **不再编辑建造点位**：没有「建造点位」栏、没有画布标记、导出不写 `build_points`；
- 老图里的 `build_points` 读进来直接丢掉；
- 地形 / 区划 / 中心 / 产能 / 人口上限照旧。

---

## 7. 校验

运行时 `logic/level.gd` 与战役编辑器 `model.py` 同一套 code：

| code | 级别 | 判据 |
|---|---|---|
| `zone_build_count_zone_missing` | block | 数量指向一个地图上不存在的区划 |
| `zone_build_count_negative` | block | 数量是负数（0 合法） |
| `zone_build_count_no_space` | warn | 数量 > 0，但边缘区 / 城墙环 / 已有建筑把候选格占光了 |

边缘区原有五条 `zone_no_go_*` 保持不变。

编辑器独有的建筑落点校验：

| code | 判据 |
|---|---|
| `building_not_in_zone` | 非城墙建筑不在任何区划里 |
| `building_not_buildable` | 山地 / 水域 / 区划中心（由 `_ck_points` 报） |
| `building_not_in_wall_ring` | 城墙不在任何区划中心的环上 |
| `building_overlap` | 同一格叠了两栋非城墙建筑 |

---

## 8. 测试

- `tests/test_build_points.gd`：
  - 地图里的 `build_points` 不再读；
  - `zones[].build_point_count` 的宽容读法（0 / 负数 / 缺键 / 非数字）；
  - 生成数量、0 = 不生成、同种子可复现、排除边缘区、排除已有建筑；
  - 点位合法性、落点规则、城墙整圈、锚点过滤。
- `tests/test_ai_commander.gd`：AI 只从生成的点位里挑；被入侵时补塔位置是本区可用点位。
- `tests/test_zone_no_go.gd`：边缘区读入 / 巡逻路线零边缘区格。
- 战役编辑器：`python dev_gd_a/tools/campaign_editor/test_model.py`、
  `test_app.py`；地图编辑器：`python dev_gd_a/tools/map_editor/test_model.py`、
  `test_app.py`。
- 全量回归：`tools/run-tests.ps1`。

---

## 9. 已知限制 / 后续

1. **点位是随机的，编辑器看不到具体坐标**：这是「每局随机」的直接结果；
   作者摆建筑时只需要保证在本区可通行格上，运行时会把已有建筑排除掉。
2. **候选不够就少生成**：小地块 / 边缘区占满 / 建筑挤满时可能一个都生成不出来；
   编辑器会给 `zone_build_count_no_space` 警告。
3. **地图老数据的 `build_points`**：运行时忽略；地图编辑器保存时丢弃。
4. **随机同步只走合作 `start` 包**：单机 / 回放要固定布局请传 `seed_value`。
