# dev_plan_15 —— 战役演出系统（前置框架）

> 状态：**已实现（2026-11-06）**。实现与本文的差异见文末「实现状态」。
> 目标：做一个**可复用、不暴露编辑器**的演出模块；剧本在战役代码里写死。
> 本轮范围：**B** —— 全部演出效果实现并有无头测试；后续同一天接入了**新手教程 1**。
> 后续追加：红点生成、生成单位 / 建筑、呼吸泛光、剧情目标 / 输入策略 / 控制权 / 教程引导、新手教程 1（2026-11-06 同日）。
> 工程：`dev_gd_a/daeem/`。

---

## 0. 已确认的决策（来自本轮问答）

| 项 | 决策 |
|---|---|
| 触发方式 | **B：事件触发**（时间点、区划易主、单位死亡、建筑被毁、目标进度、玩家命令等）。触发后跑一段线性演出。 |
| 合作模式 | **A：只做单人战役**。合作模式不跑演出。 |
| 输入锁粒度 | 按**动作类别** allowlist：`camera / select / order / recruit / build / tech / upgrade / revive / ui / pause`；对话额外有 `dialogue / skip`。 |
| 跳过演出 | 允许。点击对话继续算允许输入。**必须玩家操作才能结束的演出不可跳过**。 |
| 镜头 | 目标支持格 / 单位 / 建筑 / 区划中心；要时长、缓动、缩放；移动后可选「继续锁定」或「跟随目标」。镜头锁定时小地图、F、Home、边缘滚屏全部禁用。 |
| 地图边界 | **B + D**：B = 单位 / 建筑可活动范围；D = 真正的**换一张更大的地图**（旧状态保留，黑屏转场，只允许扩大）。 |
| 目标引用 | 接受在 `start_units` / `start_buildings` 里加可选 `tag`，编辑器**不显示**但读写原样保留。击杀 / 摧毁支持正常流程 / 静默流程。**不强制摧毁大本营**。 |
| 对话 | 点击 / 空格继续；脚本推进；默认定时自动推进；打字机，点击第一次跳过逐字、第二次跳过整条；多条排队；和播报同一套栈，对话出现时播报上移；**模态**。 |
| 资源 | 只给**本机玩家**；只给粮食 / 黄金；直接加资源池；要飘字 + 播报。 |
| 代码组织 | **一个战役一个剧本文件**；本轮做到 B（全部效果 + 测试，不接关卡）。 |
| 测试 | 无头单测；不做截图测试。 |

---

## 1. 现状盘点

工程里**没有**演出 / 触发器 / 对话系统。可挂的现成入口：

- 每帧主循环：`view/game_scene3d.gd:_process`（`world.tick()` 之后拿到 `events`）。
- 事件源：`world.push_event()` 已产出 `kill` / `building_down` / `leader_downed` / `zone_recruited` / `upgrade_done` / `territory_changed` / `tech_changed` / `level_end` 等。
- 输入：`view/input_controller.gd`（键鼠 + 命令）+ HUD 自身按钮；`view/game_scene3d.gd:_input/_unhandled_input` 是路由层。
- 镜头：`game_scene3d.center_on_tile_precise / pan_screen / zoom_at / clamp_look_point`。
- 地图边界：目前只有**相机夹取**（`clamp_look_point`）和**金线**（`view/map_border_view.gd`）；没有可变的玩法边界。
- 地图尺寸：`logic/map_data.gd` 读入后 `cols / rows / terrain / exists` 固定；`ground_view` / `terrain_props_view` / `map_border_view` 会在 `setup()` 时把地图尺寸烘进网格 / 贴图。
- 左下播报：`view/broadcast_banner.gd`，固定行高、队列、新通知在下、旧通知上移、到期上浮淡出。
- 资源：`world.resources`（本机席位别名）/ `world.player_resources` / `world.ai_faction_resources`。
- 单位 / 建筑：`world.units`、`world.building_list`；单位有运行时 `id`，建筑没有 id。
- `logic/snapshot.gd` 是**联机快照**，不是完整存档：它不覆盖 AI 控制器内部状态、科技启用全量、地图 / 区划结构等，不能直接拿来换图。

---

## 2. 目标与边界

### 2.1 本模块是什么

- 一个**演出导演**（`StoryDirector`）：加载战役剧本、监听事件、按顺序执行演出步骤、管理输入锁 / 镜头 / 边界 / 对话。
- 一个**剧本注册表**：`战役 id → 剧本脚本`。
- 一组**效果**：锁输入、锁输入 + allowlist、强制镜头、锁定 / 扩展玩法边界、换图扩图、给资源、击杀单位、摧毁建筑、播报 / 对话。
- 一个**左下通知栈**：播报和对话共用；对话是模态、带打字机、自动推进、排队。

### 2.2 本模块不是什么

- **不是编辑器里的触发器 UI**。剧本只在 `logic/story/campaigns/<campaign_id>.gd` 里写死。
- **不是合作同步系统**。本轮合作模式不启用演出。
- **不是通用任务系统**。目标 / 失败条件仍走 `logic/objective.gd`；演出只读它们的状态。
- **不是存档系统**。换图保留当前局内状态，但不写磁盘、不跨进程。

### 2.3 启用条件

只在「单人战役关卡」启用：

- `game_scene3d.start_level(campaign, level, faction, ..., enable_story = true)`；
- `start_level_vs_commander()` 调 `start_level(..., enable_story = false)`（ai_test 不跑演出）；
- `start_coop_*` / `start_ai_observer` / 自由对战 `start()` 都不创建导演。

---

## 3. 模块结构

```
logic/story/
├── story_director.gd          # 导演：触发器、演出队列、步骤状态机、输入锁、跳过
├── story_triggers.gd          # 触发器匹配（纯函数 / 小对象）
├── story_actions.gd           # 效果实现：资源 / 击杀 / 摧毁 / 边界 / 换图 / 目标解析
├── story_registry.gd          # 战役 id → 剧本脚本（显式 preload 表）
├── story_consts.gd            # 动作类别、步骤 kind、事件 kind 的常量
└── campaigns/
    └── demo.gd                # 样例战役的剧本（本轮只放骨架 / 注释，不接内容）

view/
└── notice_stack.gd            # 由 broadcast_banner.gd 泛化：播报 + 对话同一套栈
                               # 保留 broadcast_banner.gd 作为兼容入口（或改名后保留旧 API）
```

> ⚠️ 跨文件只用 `preload` 常量，不写全局 `class_name`（`--script` 无头跑时全局类名表不可用）。

---

## 4. 运行模型

### 4.1 生命周期

```
game_scene3d._assemble()
  └─ story = StoryDirector.new()
     story.setup(host = game_scene3d, world, campaign_id, level_id)

每帧 game_scene3d._process(dt)
  ├─ world.tick(dt) → events
  └─ story.tick(dt, events)
       ├─ 1. 推进当前演出步骤（wait / 镜头 / 换图 / 对话等待…）
       ├─ 2. 检查触发器（时间 / 状态 / 事件）
       ├─ 3. 触发器命中 → 创建一个演出，放进队列
       └─ 4. 当前演出结束后，从队列取下一个
```

**同一时刻只有一个演出在跑**；触发器命中的新演出**排队**，不会插队打断当前演出。
对话的逐字 / 自动推进由 HUD 的通知栈自己走（它每帧 tick），导演只等 `dialogue_finished` 信号。

### 4.2 触发器

剧本里注册：

```gdscript
static func build(d, world) -> void:
    d.on_start([...steps...])
    d.on_time(90.0, [...])
    d.on_zone_owner(2, "F1", [...])
    d.on_unit_dead({"tag": "old_captain"}, [...])
    d.on_building_destroyed({"tag": "gate"}, [...])
    d.on_event("upgrade_done", {"kind": "building_upgrade"}, [...])
    d.on_command("order_move", [...])
    d.on_condition(func() -> bool: return ..., [...])
```

| 触发器 | 判据 | 备注 |
|---|---|---|
| `on_start` | 导演第一次 tick | 每个触发器默认只触发一次 |
| `on_time(sec)` | `world.time >= sec` | 用逻辑时间，暂停不推进 |
| `on_zone_owner(zone, owner)` | `world.zone_by_id(zone)["owner"] == owner` | 每 tick 轮询；默认只触发一次 |
| `on_unit_dead(filter)` | `kill` / `leader_downed` 事件 + filter | 支持 tag / id / faction / kind |
| `on_building_destroyed(filter)` | `building_down` 事件 + filter | 支持 tag / type / owner / tile |
| `on_event(type, filter)` | 任意 `world` 事件 | filter 是字段子集匹配 |
| `on_command(kind)` | `game_scene3d._on_command` 转发 | 用于「玩家下了某个命令」 |
| `on_condition(callable)` | 每 tick 调用一次 | 用于「单位走到某区域」这类自定义条件 |

所有触发器默认 `once = true`；可传 `{"once": false, "cooldown": 5.0}` 做重复触发。
触发器按注册顺序检查，保证确定性。

### 4.3 演出步骤（线性）

一个演出 = `{steps: Array, skippable: bool, id: String}`。
步骤是字典，导演按 `index` 顺序执行；每个步骤可以有 `wait` / `duration` / `await` 行为。

| `kind` | 参数 | 说明 |
|---|---|---|
| `wait` | `sec` | 等待若干秒 |
| `lock_input` | `id?`, `allow: [动作类别]`, `persist?: bool` | 压入一把输入锁；`allow` 里的动作仍可用；**不写 `allow` = 锁定全部玩法输入**（仍保留 `dialogue` / `skip`） |
| `unlock_input` | `id?` | 释放指定锁；不传 = 释放这一演出创建的锁 |
| `camera_move` | `target`, `sec`, `zoom?`, `ease?`, `lock?`, `follow?`, `persist?` | 锁定并强制移动镜头 |
| `camera_lock` | `persist?` | 只锁镜头 |
| `camera_unlock` | — | 解锁镜头 |
| `camera_follow` | `target` | 移动结束后继续跟随目标 |
| `map_boundary` | `rect: [x,y,w,h]` 或 `full: true` | 设置**玩法边界**（单位 / 建筑可活动范围） |
| `map_boundary_expand` | `rect` | 只允许**包含旧边界**的新矩形；否则报错不执行 |
| `map_expand` | `map: "<map_id>"`, `path?`, `fade_sec?`, `focus?`, `boundary?` | 黑屏换到更大的地图；`path` 可直接指定地图文件 |
| `grant_resources` | `food?`, `gold?` | **只给本机玩家**；直接加资源池（`faction` 保留键但会被忽略） |
| `kill_units` | `targets: [目标], silent?: bool` | 强制击杀 |
| `destroy_buildings` | `targets: [目标], silent?: bool` | 强制摧毁（大本营会被拒绝） |
| `spawn_red_dot` | `faction`, `spawn`, `target`, `count?`, `general?`, `general_weights?`, `escort_count?`, `escort_types?`, `name?`, `tag?`, `wave?` | 生成红点将领（默认满编附属兵）并向 target 行军攻击；推 `red_dot_wave` |
| `spawn_unit` | `faction`, `unit_type`, `count?`, `spawn`, `general?`, `name?`, `tag?`, `escort_count?`, `escort_types?`, `hotkey?`, `locked?`, `attack_move?`, `red_dot_wave?`, `announce?` | 生成普通单位 / 将领；默认静默；可锁定控制权 / 生成后行军 |
| `spawn_building` | `faction`, `type`, `spawn`, `tag?`, `announce?` | 生成建筑；默认跳过建造读条、静默 |
| `glow_object` | `targets`, `color?`, `period?`, `duration?`, `strength?`, `id?` | 给单位 / 建筑 / 区划中心加呼吸泛光（金色外轮廓 + 地面光环 + 向外波纹） |
| `glow_zone` | `zone`/`zones`, `color?`, `period?`, `duration?`, `strength?`, `id?` | 给整个区划的占领范围 + 区划中心加呼吸高亮 |
| `stop_glow` | `targets?`, `zones?`, `id?` | 停止泛光；都不写 = 清掉全场 |
| `glow_command_card` | `unit_kind` | 让命令卡中对应兵种格呼吸高亮（描边 + 方形波纹；空串 = 关闭） |
| `guide_selection` | `targets?`, `tab?`, `id?`, `period?`, `strength?` | 教程引导：没选中部队时让己方部队呼吸；没在指定页签时让页签呼吸 |
| `guide_clear` | `id?` | 关闭教程引导（泛光 + 页签高亮） |
| `objective_set` | `title`, `desc`, `state?`, `zone?` | 设置左上角**剧情目标**（新目标逐字打字机） |
| `objective_done` | — | 当前剧情目标标记为「已完成」（文字从左到右划去） |
| `input_policy` | `block_single_right_click?: bool` | 演出期输入策略（只挡单击右键，保留双击行军） |
| `unit_control` | `targets`, `locked?` | 暂时锁定 / 放开玩家对单位的控制 |
| `set_var` | `key`, `value` | 写剧本临时变量（`world.story_vars`） |
| `outcome` | `result: "win"/"lose"`, `reason?` | 剧情判胜 / 判负（走正常结算） |
| `dialogue` | `text`, `auto_sec?`, `type_sec?`, `skippable?` | 弹出对话并等待推进 |
| `wait_until` | `condition: Callable`, `skippable?: bool` | 等玩家操作 / 条件成立；可标记不可跳过 |
| `call` | `fn: Callable` | 调一段战役专属逻辑 |
| `end` | — | 立即结束当前演出 |

**演出的清理语义：**

- `lock_input` / `camera_lock` / `camera_move` 默认在演出结束或跳过时自动释放；
  加 `"persist": true` 则保留，由后续步骤 / 触发器 `unlock`。
- `map_boundary` / `map_expand` / `grant_resources` / `kill_units` / `destroy_buildings`
  是**世界状态变更**，跳过演出**不撤销**。
- 跳过时：清空当前对话、释放本演出的输入锁和镜头锁、停止镜头移动、结束当前演出。

### 4.4 跳过规则

- `Esc` = 请求跳过当前演出。
- 演出 `skippable: false`，或当前步骤是 `wait_until` 且 `skippable: false` → 忽略跳过请求。
- 对话正在逐字 → **第一次点击 / 空格**补全整条；**第二次**推进下一条。
- `Esc` 不参与「补全逐字」，它直接请求跳过整段演出（可跳过时）。
- 不可跳过的演出可以给玩家一个允许输入（例如 `allow: ["select", "order"]`）去完成条件。

---

## 5. 输入锁

### 5.1 动作类别

```
camera   镜头平移 / 缩放 / 跟随 / 小地图点击 / F / Home / 边缘滚屏
select   点选 / 框选 / 数字键选将
order    右键命令 / 行军 / 攻击 / 停止 / 命令卡操作页
recruit  招募 / 取消招募
build    建造 / 取消建造
tech     科技启用 / 弃用
upgrade  升本 / 取消升本
revive   再起 / 召回
ui       HUD 按钮 / 选项 / 页签
pause    暂停
dialogue 点击 / 空格推进对话
skip     Esc 跳过演出
```

### 5.2 锁栈

导演持有 `Array[{id, allow: Dictionary}]`：

- `is_input_allowed(action)`：**所有**锁都允许该动作才返回 true（取交集，最严格）。
- 没有锁 → 全部允许。
- 同名 `id` 的锁再次压入 = 更新 allow（不会叠成两把）。
- `unlock_input(id)` 移除指定锁；不传 id = 移除当前演出创建的锁。

### 5.3 接入点

- `input_controller` 增加 `action_gate: Callable`，在 `handle_key` / `handle_mouse_button` /
  `_on_left_click` / `_on_right_click` / `set_order_mode` / `set_build_type` /
  `request_recruit*` / `request_zone_recruit*` / `request_tech_toggle` /
  `request_building_upgrade*` / `request_revive*` / `request_recall` 开头问 `_action_ok(...)`。
- `game_scene3d` 的相机方法（`pan_screen` / `zoom_at` / `center_on_tile*` / `fit_to_map` /
  `_camera_update` 里的键鼠边缘滚屏）在 `story_camera_locked` 时直接拒绝玩家输入；
  导演的强制镜头走内部直摆，不受这条限制。
- HUD 按钮：`ui` 不被允许时，在 HUD 上方显示一层全屏 `StoryShield`（`MOUSE_FILTER_STOP`），
  挡住所有 GUI；`ui` 被允许时，按钮能点，但最终命令仍会在 `input_controller` 的动作闸门被拦。
- 暂停：`pause` 不被允许时，`P` / `Esc` 暂停被吃掉。
- 对话模态：对话显示期间自动压入一把 `{allow: ["dialogue", "skip"]}` 的锁 + 全屏盾；
  对话框自身在盾之上，接收点击 / 空格推进。

> ⚠️ 全屏盾只负责「连 HUD 按钮也点不到」；细粒度 allowlist 仍由动作闸门负责。
> 两者不能互相替代。

---

## 6. 镜头

### 6.1 目标解析

`target` 支持：

```gdscript
{"tile": [x, y]}                 # 格坐标
{"unit": "<tag>"}                # 单位 tag
{"unit_id": "general-F1-1"}      # 运行时 id
{"building": "<tag>"}            # 建筑 tag
{"building_tile": [x, y]}        # 建筑格
{"zone": 3}                      # 区划中心
{"base": "F1"}                   # 阵营大本营
```

解析到格坐标后，走 `game_scene3d.center_on_tile_precise()`；移动过程由场景用
`Tween` / 手动插值完成（跟 `ThemeRes.animations_enabled()` 联动，关闭动画时瞬移）。

### 6.2 锁定 / 跟随

- `camera_move` 默认：移动期间锁镜头，移动结束后**保持锁定**在原地。
- `lock: false`：移动结束后把镜头还给玩家。
- `follow: true`：移动结束后继续跟随目标（目标移动时镜头跟着走）。
- `camera_unlock`：解除锁定并停止跟随。
- 锁定期间：`pan_screen` / `zoom_at` / `center_on_tile*` / `fit_to_map` / 小地图点击 /
  `F` / `Home` / 边缘滚屏 / 方向键全部无效。
- 强制移动本身不受锁定影响（内部直摆）。

---

## 7. 地图边界（B：玩法边界）

### 7.1 数据

在 `logic/map_data.gd` 增加：

```gdscript
var active_rect: Rect2i          # 单位 / 建筑可活动范围（格）；默认整张地图
func set_active_rect(r: Rect2i) -> void
func in_active_rect(tx: int, ty: int) -> bool
func reset_active_rect() -> void
```

> 放在 `MapData` 上是因为 `Pathfinder.passable()` 只拿得到 `map`，拿不到 `world`。
> `MapData` 是每局一份的运行时对象，改它不会影响磁盘数据。

### 7.2 判据

- `Pathfinder.passable()`：`map.in_active_rect(x, y)` 不成立 → false。
- `Pathfinder.find_path()` / `reachable_tiles()` 自然继承（它们走 passable）。
- `Pathfinder.segment_clear()`：
  - 线段两端 / 包围盒不在 `active_rect` 内时，**跳过 C# 内核**，走 GDScript DDA（它逐格问 passable）。
  - `reachable_tiles()` 的 C# 内核同理：`active_rect` 不是整图时不用内核。
- `world.can_build_at()`：边界外不能建。
- 单位出生 / 重生 / 招募落点：边界外 → 找最近的边界内可站格。
- 红点 AI 的生成地块：过滤到边界内。
- 大本营 / 区划中心 / 预置建筑不受影响（它们已经存在）。

### 7.3 视觉

`view/map_border_view.gd` 改为画 `world.map.active_rect` 的金线，而不是固定整张地图：

- `map_boundary` 设置后，金线移到新的可玩矩形；
- `map_boundary_expand` / `map_expand` 后，金线跟着扩大；
- 金线仍是纯表现，不参与逻辑。

### 7.4 与地图扩展的关系

- `map_boundary` 只改 `active_rect`，不换地图。
- `map_expand` 换到更大的地图后，默认 `active_rect = 新地图整图`；
  也可以在步骤里再给 `boundary` 指定一个更小的矩形。
- `map_boundary_expand` 只允许新矩形**包含旧矩形**；否则 `push_error` 并跳过该步骤。

---

## 8. 地图扩展（D：换更大的地图）

### 8.1 口径

一个「可扩展地图」由**两张地图数据**组成：

- 旧地图（关卡 JSON 的 `map`）；
- 新地图（更大，旧区域地形 / 存在格必须逐格一致）。

演出步骤：

```gdscript
{"kind": "map_expand", "map": "dongzheng_big", "fade_sec": 0.6}
```

流程：

```
黑屏淡出 → 校验新地图 → world.swap_map(new_map_path)
         → 重建地图相关视图 → 刷新 HUD / 小地图 → 设置新边界
         → 黑屏淡入 → 通知导演步骤完成
```

### 8.2 校验（必须严格，失败不改任何状态）

- 新地图文件存在。
- `new.cols >= old.cols` 且 `new.rows >= old.rows`，且至少一个维度严格变大。
- 旧区域逐格比对：
  - `new.terrain.data[idx] == old.terrain.data[idx]`
  - `new.exists.data[idx] == old.exists.data[idx]`
- 旧地图的每个区划 id 在新地图里仍然存在（否则旧区划状态无处恢复）。
- 旧区域的**区划网格**与**区划中心位置**也必须一致（否则旧建筑 / 占领状态会挂到错误的地块上）。
- 任何一条不满足 → `push_error`，保持旧地图与旧状态，演出继续（不崩）。

### 8.3 `world.swap_map(new_map_path)`（**原地换图，不重建世界**）

为什么原地换：这样单位 / 建筑 / 科技 / 资源 / AI 控制器 / 目标状态 / 时间 / 招募队列
全部保留，不需要把整个 `World` 重造一遍；只有「地图相关结构」需要重建。

步骤：

1. `MapData.load_from(new_map_path, cfg)`。
2. 执行 8.2 校验。
3. 保存旧区划状态：`{id: {owner, progress, capture_faction, capture_state, population, ...}}`。
4. `world.map = new_map`；`map.active_rect = 新地图整图`。
5. 重建 `world.buildings` 网格（新尺寸）与 `_building_at`；`building_revision += 1`。
6. `world.zones = ZoneRes.build_from_map(new_map, cfg, factions)`；
   把步骤 3 的状态按 id 覆盖回去；新区划保留新地图自己的开局归属。
7. 补建**新增区划的中心**（只给 `building_at(center) == null` 的区划建，避免重复）。
8. 把新地图**旧区域之外**的预置建筑加进来（大本营跳过；已占格自动拒）。
9. 迷雾：保留 `_sighted`（见过的敌方建筑）与 `_display_reveal`；清掉 `sight` / 扇区缓存 /
   内核地图缓存，下一帧按新地图重算。
10. 碰撞：`crowd.reset_cache()`（下次 tick 按新地图重建地形 / 建筑表）。
11. `fog.update(self)` / `refresh_ownership()` / `refresh_zone_production()` / `mark_vision_dirty()` 收口。
12. 返回 true。

### 8.4 视图重建（`game_scene3d`）

换图后必须重建把地图尺寸烘进几何 / 贴图的层：

- `ground`（地面 PlaneMesh + 地形贴图 + 迷雾贴图）
- `terrain_props`（树 / 山 / 水 MultiMesh）
- `map_border`（金线网格）

做法：`queue_free()` 旧节点，按原来的 `setup()` 重新建一份；
`units` / `buildings` / `projectiles` / `overlay` / `order_flags` / `attack_marks` /
`charge_fx` 不烘地图尺寸，换图后照常 `sync()` 即可。
`hud.minimap` 清掉迷雾缓存并 `queue_redraw()`；HUD 其余部分读 `world`，不需要重建。
相机 `clamp_look_point()` 用新地图尺寸重新夹取；需要时按 `focus` 对准。

### 8.5 黑屏转场

- 在 `game_scene3d` 增加一个全屏 `ColorRect`（独立 CanvasLayer，压在 HUD 之上、对话之下或之上按需）。
- `fade_out_sec` / `fade_in_sec` 来自 `story.map_expand` 配置。
- 黑屏期间冻结输入与逻辑 tick；换图完成后恢复。
- 动画关闭时直接切黑 / 切回，不建 Tween。

### 8.6 已保留 / 不保留

保留：

- 单位（位置、血量、将领状态、招募队列、濒死 / 再起、冲锋等）
- 建筑（类型、位置、归属、血量、等级、升级队列、重生队列）
- 区划（归属、占领进度、人口、产能、特化）
- 玩家 / AI 资源、科技启用状态、目标与失败条件、时间、AI 控制器对象与指令
- 迷雾里「见过的敌方建筑」

不保留 / 重置：

- 新区域的迷雾（未探索，按正常规则点亮）
- 新区域的区划初始归属（来自新地图数据）
- 新区域的区划中心 / 预置建筑（按新地图补建）
- 寻路 / 碰撞 / 视野缓存（下一帧重建）

---

## 9. 左下通知栈（播报 + 对话）

### 9.1 泛化 `broadcast_banner.gd`

保留现有公开 API（`push` / `format_text` / `tick` / `line_*` / `active_count`），
内部改成通用行：

```
row = {
  kind: "broadcast" | "dialogue",
  text, color,
  height,            # 播报 = ui.broadcast.line_height；对话 = 按文本量测
  age, hold,
  typing, type_total, type_done,
  auto_timer, auto_sec,
  exit_start_age, ...
}
```

- 布局从下往上：最新一行在最下面；每行高度不同，按累计高度重排。
- 播报行 `mouse_filter = IGNORE`；对话行 `MOUSE_FILTER_STOP`，点击 / 空格推进。
- 对话出现时，已有播报**整体上移**（和现在新播报顶旧播报同一套 reflow）。
- 对话是**模态**：显示期间通知栈 `z_index = 310`，全屏盾 `z_index = 300`。
- 队列：同一时刻只显示一条**未读**对话；推进后它上浮淡出，下一条从下方出现，
  旧对话 / 播报继续上移。最多保留 `story.dialogue.history_max` 条历史行。

### 9.2 对话状态机

```
出现 → 逐字（type_sec/字）
     → 逐字完成
     → 等待：点击 / 空格 / 脚本推进 / auto_sec 到期
     → 推进：当前行上浮淡出，下一条（或结束）
```

- 点击 / 空格：
  - 逐字未完成 → **补全整条**；
  - 逐字已完成 → **推进下一条**。
- `auto_sec` 从**逐字完成**开始计时；`auto_sec <= 0` = 不自动推进。
- `advance_dialogue()`：导演 / 剧本可随时立刻推进（用于「玩家做了某个操作 → 对话立刻结束」）。
- 推进后发 `dialogue_finished(id)`；导演据此继续下一步。

### 9.3 资源飘字

- `hud.show_resource_gain(food, gold)`：
  - 在资源条旁边生成两行上浮淡出的数字（`+100 粮` / `+50 金`），时长 / 位移 / 字号来自 `story.resource_float.*`；
  - 同时往通知栈塞一条播报（普通播报行，不是对话）。
- 只给本机玩家；选边关只给玩家实际操作的阵营。

---

## 10. 数据契约：`tag`

### 10.1 关卡 JSON

```jsonc
"start_units": [
  {"faction": "E1", "kind": "general_1", "x": 11, "y": 4, "tag": "old_captain"}
],
"start_buildings": [
  {"type": "tower", "x": 5, "y": 3, "owner": "F1", "tag": "north_gate"}
]
```

- `tag` 可选、字符串、仅运行时 / 剧本使用。
- 编辑器（`tools/campaign_editor`）**不显示**这个字段，但 `model.py` 必须：
  - 读入 `tag`；
  - 写出 `tag`；
  - 没写时不要凭空补空串（保持原文件最小 diff）。
- 地图 `buildings[]` 也支持可选 `tag`（与关卡同构）。

### 10.2 运行时

- `Unit.tag` / `Building.tag` 新增字段。
- `world._place_faction_units()` / `world.add_building()` 把 tag 写进去。
  `add_building` 末尾加可选参数 `tag: String = ""`，老调用点不受影响。
- `world.story_find_units(spec)` / `world.story_find_buildings(spec)` 或
  `story_actions.gd` 里的解析函数负责按 tag / id / 坐标 / 阵营 / 类型找目标。

### 10.3 目标解析

```gdscript
# 单位
{"tag": "old_captain"}
{"unit_id": "general-F1-1"}
{"faction": "E1", "kind": "general", "index": 0}
{"faction": "E1", "unit_type": "spearman", "index": 1}
{"tile": [11, 4]}
{"faction": "E1", "zone": 3}

# 建筑
{"tag": "north_gate"}
{"type": "tower", "owner": "F1"}
{"type": "tower", "tile": [5, 3]}
{"base": "F1"}
```

- 解析不到 → 记一条 `push_warning`，该目标跳过，不崩。
- 同一 spec 命中多个 → 全部执行（并 `push_warning` 提示 tag 不唯一）。
- `destroy_buildings` 命中大本营 → 拒绝并 `push_error`（用户保证不会用，但这里兜底）。

### 10.4 击杀 / 摧毁流程

- `silent: false`（默认）：
  - 单位：`u.die_now(cfg, world, "story")` → 正常 `kill` 事件、将领濒死 / 重生队列、胜负判定；
  - 建筑：`b.take_damage(cfg, b.hp + 1, null, false, true)` + `building_down` →
    下一帧 `_collect_destroyed_buildings()` 正常收尸 / 大本营中立化。
- `silent: true`：
  - 单位：标记 `alive = false`、停止移动 / 攻击、从 `world.units` 移除，**不推任何事件**；
  - 建筑：`world.remove_building(b, true)`，**不推 `building_down`、不触发大本营中立化**。
- 大本营在两种模式下都拒绝强制摧毁。

---

## 11. 配置键（`data/config.json` 的 `story` 段）

| 键 | 默认 | 说明 |
|---|---:|---|
| `story.dialogue.type_sec` | `0.03` | 每字打字机间隔（秒） |
| `story.dialogue.auto_sec` | `4.0` | 逐字完成后自动推进的等待；`<= 0` = 不自动 |
| `story.dialogue.history_max` | `5` | 同时保留的历史行数 |
| `story.dialogue.min_height` | `64` | 对话行最小高度 |
| `story.dialogue.max_height` | `220` | 对话行最大高度（超出内部滚动 / 截断） |
| `story.dialogue.font_size` | `18` | 对话字号 |
| `story.dialogue.pad_x` | `16` | 对话左右内边距 |
| `story.dialogue.pad_y` | `12` | 对话上下内边距 |
| `story.skip.key` | `"Escape"` | 跳过演出的按键（`space` / `enter` / `q` 也认） |
| `story.camera.move_sec` | `1.2` | 默认镜头移动时长 |
| `render.story_glow_*` | 见 config | 呼吸泛光的颜色 / 本体强度 / 光环尺寸 / 外壳倍率（`_story_glow_comment`） |
| `story.camera.ease` | `"cubic"` | 缓动（`linear` / `cubic`） |
| `story.map_expand.fade_out_sec` | `0.5` | 换图黑屏淡出 |
| `story.map_expand.fade_in_sec` | `0.5` | 换图黑屏淡入 |
| `story.resource_float.sec` | `1.2` | 资源飘字时长 |
| `story.resource_float.rise_px` | `36` | 上浮距离 |
| `story.resource_float.font_size` | `18` | 飘字字号 |


所有数值读入时 clamp；不在代码里写死。

---

## 12. 改动清单

### 新增

| 文件 | 作用 |
|---|---|
| `logic/story/story_director.gd` | 导演：触发器、演出队列、步骤状态机、输入锁、跳过 |
| `logic/story/story_triggers.gd` | 触发器匹配 |
| `logic/story/story_actions.gd` | 效果实现 + 目标解析 + 生成红点 / 单位 / 建筑 + 泛光状态 |
| `logic/story/story_glow.gd` | 呼吸泛光曲线 / 颜色解析（视图与单位本体共用） |
| `logic/story/story_registry.gd` | 战役 id → 剧本脚本 |
| `logic/story/story_consts.gd` | 动作 / 步骤 / 事件常量 |
| `logic/story/campaigns/demo.gd` | 样例剧本骨架（本轮不接内容） |
| `view/notice_stack.gd` | 播报 + 对话通用栈 |
| `view/story_glow_view.gd` | 呼吸泛光：地面光环 + 建筑外壳 |
| `view/story_glow_shell.gdshader` | 建筑泛光外壳（反向壳） |
| （HUD 内）`StoryShield` | 模态 / UI 锁全屏盾（建在 `view/hud.gd` 里，不单独成文件） |
| `tests/test_story_director.gd` | 触发器 / 队列 / 锁 / 跳过 / 资源 / 击杀 / 摧毁 / 边界 |
| `tests/test_story_dialogue.gd` | 通知栈：打字机 / 点击 / 自动 / 排队 |
| `tests/test_story_scene.gd` | 场景 / HUD 接线冒烟 |
| `tests/test_story_tags.gd` | `start_units[].tag` / `start_buildings[].tag` 落点 |
| `tests/test_story_spawn.gd` | 红点 / 单位 / 将领 / 建筑生成 + 导演步骤分发 |
| `tests/test_story_glow.gd` | 泛光状态 / 曲线 / 停止 / 时长 |
| `tests/test_tutorial.gd` | 教程 1 数据 / 剧本 / 21 步纯逻辑流程 |
| `tests/test_tutorial_scene.gd` | 教程 1 与 3D 场景 / HUD / 目标面板接线 |
| `tests/test_map_expand.gd` | `world.swap_map` 校验与状态保留 |
| `tests/test_map_expand_scene.gd` | 换图后视图层重建冒烟 |

### 修改

| 文件 | 改动 |
|---|---|
| `logic/level.gd` | `start_units[]` / `start_buildings[]` 读 `tag`；校验可选重复 tag |
| `logic/unit.gd` | `tag` 字段 |
| `logic/building.gd` | `tag` 字段 |
| `logic/map_data.gd` | `active_rect` / `set_active_rect` / `in_active_rect` / `reset_active_rect`；预置建筑读 `tag` |
| `logic/pathfinder.gd` | `passable` 查 `active_rect`；`segment_clear` / `reachable_tiles` 在内核与边界冲突时退回 GDScript |
| `logic/world.gd` | `add_building(..., tag)`；`swap_map`；`set_boundary` / `reset_boundary`；`story_kill_unit` / `story_destroy_building`；`grant_resources` |
| `logic/fog.gd` | `on_map_changed()`：清 sight / 扇区 / 内核缓存，保留 `_sighted` / `_display_reveal` |
| `logic/crowd/crowd_bridge.gd` | 换图后 `reset_cache()` 即可（确认 `_map_ref` 失效） |
| `view/game_scene3d.gd` | 创建 / tick 导演；输入闸门；镜头锁定与强制移动；换图流程；视图重建；黑屏 |
| `view/input_controller.gd` | `action_gate` + 各动作入口检查 |
| `view/hud.gd` | 用 `notice_stack` 替换 / 包装 `broadcast_banner`；`show_dialogue` / `advance_dialogue` / `show_resource_gain`；对话模态盾 |
| `view/broadcast_banner.gd` | 保留兼容 API，内部改调 / 继承 `notice_stack` |
| `view/map_border_view.gd` | 画 `active_rect` 的金线；支持重建 |
| `view/ground_view.gd` / `terrain_props_view.gd` | 不改内部：由 `game_scene3d._rebuild_map_views()` 重新建节点 |
| `view/minimap.gd` | 换图后清迷雾缓存并重画 |
| `tools/campaign_editor/model.py` | `tag` 读写（不显示 UI） |
| `tools/campaign_editor/test_model.py` / `test_app.py` | tag 往返测试 |
| `data/config.json` | 新增 `story` 段 |
| `docs/architecture.md` / `docs/route.md` / `docs/README.md` | 记录本轮系统 |

---

## 13. 测试计划（无头，不做截图）

### 13.1 `test_story_director.gd`

- `on_start` / `on_time` / `on_event` / `on_zone_owner` / `on_condition` 都能触发；
- 默认只触发一次；`once: false` + cooldown 可重复；
- 多个触发器同时命中 → 按注册顺序排队；
- 当前演出未结束时，新演出进入队列，不打断；
- `skippable: false` 时 `Esc` 无效；
- 可跳过时，跳过会释放本演出的锁 / 镜头 / 对话，下一演出继续。

### 13.2 `test_story_dialogue.gd`

- 播报 / 对话共用栈；新行在下、旧行上移；
- 对话逐字：`type_sec` 推进；点击第一次补全、第二次推进；
- `auto_sec` 到期自动推进；
- 多条对话排队：同一时刻只有一条未读；
- 对话出现时播报上移；
- 模态：对话期间 `is_input_allowed("order") == false`，`"dialogue" == true`；
- 脚本 `advance_dialogue()` 立刻推进；
- 关闭动画时直接完成，不留下半透明行。

### 13.3 `test_story_actions.gd`

- `grant_resources`：给本机玩家粮食 / 黄金；HUD 回调收到飘字 + 播报；
- `kill_units`：tag / id / 坐标 / 阵营+类型+序号都能命中；正常流程推 `kill`，静默流程不推；
- `destroy_buildings`：tag / type+owner / tile 命中；正常流程推 `building_down`，静默不推；
- 大本营被拒绝；
- 目标不存在 → 不崩、记 warning；
- `silent` 流程不触发再起 / 重生 / 中立化。

### 13.4 `test_story_boundary.gd`

- `map_boundary` 设置后，`Pathfinder.passable()` 在边界外 false、边界内 true；
- `can_build_at()` 边界外 false；
- `map_boundary_expand` 允许包含旧矩形的扩展；缩小 → 拒绝且状态不变；
- `map_expand` 后 `active_rect` = 新地图整图（或指定矩形）；
- 边界不是整图时，`reachable_tiles()` / `segment_clear()` 仍遵守边界（C# 内核被绕过）。

### 13.5 `test_map_expand.gd`

在测试里临时写两张小地图 JSON（`user://` 或 `tests/` 临时目录）：

- 小图 6×6 → 大图 8×8，旧区域地形 / exists 一致；
- 放单位、建筑、区划归属、资源、科技、时间；
- `swap_map()` 后：地图尺寸变大、旧区域逐格一致、单位 / 建筑 / 区划 / 资源 / 科技 / 时间保留；
- 新区域区划中心补建、旧中心不重复；
- 新区域迷雾从未探索开始；
- 缩小地图 / 旧区域地形不一致 → 返回 false 且旧地图 / 旧状态不变。

### 13.6 其它

- `test_campaign*`：`tag` 读入 / 写出 / 往返；
- `tools/campaign_editor` 的 model / app 测试：tag 不被丢弃；
- `test_base_broadcast.gd`：现有播报断言全部保持；
- `tools/check-syntax.ps1`；
- 定向跑：
  ```powershell
  powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
  powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_story
  powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_map_expand
  powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_base_broadcast
  powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_campaign
  ```
- 最后按需跑全量；不做截图 / 视觉回归。

---

## 14. 实施顺序

1. **基础设施**：`story_consts` / `story_registry` / `tag` 数据契约 / `config.story`。
2. **通知栈**：`notice_stack` 泛化（播报 + 对话 + 打字机 + 排队 + 模态）；保持旧播报测试全绿。
3. **导演核心**：触发器、演出队列、步骤状态机、输入锁、跳过；用 fake host 做纯逻辑测试。
4. **场景接线**：`game_scene3d` 创建 / tick；输入闸门；镜头强制移动 / 锁定；HUD 对话 / 资源飘字。
5. **玩法边界**：`MapData.active_rect` + Pathfinder / 建造 / 重生 / 红点过滤 + 金线。
6. **地图扩展**：`world.swap_map` + 校验 + 状态保留 + 视图重建 + 黑屏转场 + 测试。
7. **收尾**：`demo.gd` 骨架、文档、全量相关测试、清理临时文件。

---

## 15. 风险 / 需要特别盯的点

| 风险 | 处理 |
|---|---|
| 换图后视图层尺寸不同步 | 只重建 `ground` / `terrain_props` / `map_border`；其它层换图后 `sync()`；无头测 `swap_map` 逻辑，视觉由用户验收。 |
| C# 寻路内核绕过边界 | 边界不是整图时，`reachable_tiles` / `segment_clear` 跳过内核，走 GDScript。 |
| 区划 id 在新地图里变了 | `swap_map` 严格校验；缺 id → 拒绝换图。 |
| 旧区域地形不一致 | 逐格比对；不一致 → 拒绝换图，不进入半坏状态。 |
| 新地图新增建筑 / 中心重复 | 只给 `building_at == null` 的格补建；旧区域不重复。 |
| AI 控制器状态 | 原地换图保留同一个 `World` 与 AI 对象；不重建控制器。 |
| 对话 / 播报相互顶掉 | 统一行高 reflow；对话模态盾在通知栈之下；旧播报照常到期。 |
| 标签重复 | 解析命中多个 → 全部执行 + warning；后续可在关卡校验里加重复 tag 警告。 |
| 编辑器丢 tag | `model.py` 读写 tag，不显示 UI；model/app 测试覆盖。 |
| 合作模式误启用 | 只有 `start_level(enable_story=true)` 才创建导演；合作 / 观战 / ai_test 全部关闭。 |

---

## 16. 本轮不做

- 具体关卡的演出内容（本轮只做系统 + 测试）。
- 合作模式同步。
- 编辑器里的演出 / 触发器 UI。
- 对话头像 / 说话人立绘 / 语音 / 分支选项。
- 存档 / 跨进程读档。
- 缩放地图（只允许扩大）。
- 小地图 / 相机边界的额外可视提示（金线跟随 active_rect 已足够）。

---

## 17. 实现状态（2026-11-06）

| 项 | 状态 |
|---|---|
| 导演 / 触发器 / 队列 / 输入锁 / 跳过 | ✅ `logic/story/story_director.gd`；`test_story_director.gd` 70 项（新步骤分发自 `test_story_spawn.gd`） |
| 播报 + 对话通知栈 | ✅ `view/notice_stack.gd`；`broadcast_banner.gd` 保留为兼容子类；`test_base_broadcast.gd` 67 项 + `test_story_dialogue.gd` **31** 项 |
| 场景 / HUD 接线 | ✅ `game_scene3d` 的 `story_*` 宿主方法、输入闸门、镜头、黑屏；`test_story_scene.gd` **20** 项 |
| 给资源 / 击杀 / 摧毁 / tag 目标解析 | ✅ `logic/story/story_actions.gd` + `world.story_*`；`test_story_tags.gd` 9 项 |
| 红点 / 单位 / 将领 / 建筑生成 | ✅ `spawn_red_dot` / `spawn_unit` / `spawn_building`；`test_story_spawn.gd` 38 项 |
| 呼吸泛光 | ✅ `story_glow.gd` + `view/story_glow_view.gd` + `unit_flash.gdshader`；`test_story_glow.gd` 21 项 |
| 玩法边界（B） | ✅ `MapData.active_rect` + Pathfinder / 建造 / 金线；`test_story_director.gd` 内的边界用例 |
| 地图扩展（D） | ✅ `world.swap_map` + 视图重建 + 黑屏；`test_map_expand.gd` 23 项 + `test_map_expand_scene.gd` 9 项 |
| 配置 | ✅ `data/config.json` 的 `story` 段（含 `objective` / `dialogue.exit_rise`） |
| 编辑器 tag 保留 | ✅ `tools/campaign_editor/model.py` 读写 `tag`（不显示 UI） |
| **新手教程 1** | ✅ `data/campaigns/tutorial/` + `logic/story/campaigns/tutorial.gd`；21 步完整流程；`test_tutorial.gd` 53 项 + `test_tutorial_scene.gd` **37** 项 |
| **新手教程 2** | ⏳ 只有主菜单 `ce_xs_2` 按钮，点击无逻辑（用户口径） |

### 17.1 新手教程 1（ce_xs_1）

- 地图：`ce_xs_1_a` →（剧本扩图）`ce_xs_1_b`；玩家固定 `p1` = 王朝，c0 开局无主、无大本营。
- 关卡：`data/campaigns/tutorial/campaign.json` + `levels/ce_xs_1.json`
  - `map_path` 直接指向 `ce_xs_1_a.json`（同一目录里放 A/B 两张图）
  - `story_driven: true`：胜负由剧本判定，不要求 `objectives[]`
  - `no_player_base: true`：玩家不开局建大本营（否则区划会瞬间归玩家）
  - `zones[0].population = 10` / `population_cap = 12`：够招 5 队协防军
- 剧本：`logic/story/campaigns/tutorial.gd`
  - 一条 `on_start` 顺序演出，用 `wait_until` 等「占领 / 招满 / 击败 / 再占领」
  - 生成将领 → 对话 → 移交控制权 → 占领 c0 → 招募 5 队 → 红点（枪将 + 弓）→ 击败 → 扩图 → 右侧三个敌人 → 占领 c1 → 判胜
  - 红点「行军目标 = 出生点」用 `spawn_unit.attack_move` 实现
  - 第 16 步用 `input_policy.block_single_right_click` 只挡单击右键，保留双击行军
- 主菜单入口：`view/menu_deck.gd` / `start_screen.gd` / `main.gd`
  - `ce_xs_1` 直接进教程；`ce_xs_2` 只有按钮、暂无逻辑

### 17.2 2026-11-06 追加的演出表现

- **呼吸泛光加强**：
  - 单位 / 建筑地面圆环：亮度呼吸 + **由内向外扩散的圆环波纹**（参考右键目标圆环）
  - 命令卡 / 页签的方形按钮：描边 + 淡金底呼吸 + **向外扩散的方形波纹**
  - 区划范围：填充 / 边界增亮
  - 配置：`render.story_glow_strength` / `story_glow_ripple_*` / `story_glow_ring_alpha`
- **目标面板**：
  - 新目标逐字打字机（标题 → 描述；布局按完整文本量，不跳）
  - 完成时一条线从左往右划过每一行文字
  - 配置：`story.objective.type_sec` / `strike_sec`
- **对话**：
  - 点击对话行 = 一步快速通过（补全打字 + 立即退场）
  - 退场上移 48px；下一条等旧对话完全退场后才出现（不再覆盖）
  - 配置：`story.dialogue.exit_rise`
- **教程引导**：
  - `guide_selection` / `guide_clear` 两个步骤
  - 控制权移交：没选中部队时让该将领呼吸发光
  - 招募阶段：没选中部队 → 己方部队发光；没停在「单位」页 → 单位页签呼吸
  - 选中部队 + 切到单位页后自动收掉
  - 说明：「单位」页签只在选中单位后存在，所以没选单位时先亮部队

**已知未覆盖 / 后续：**

- 合作模式不启用演出（本轮口径）。
- 编辑器里的演出编辑器 / 触发器 UI 不做。
- 教程 2 只有按钮、没有关卡 / 剧本。
- AI 控制器内部状态：原地换图保留同一个 `World` 与 AI 对象；没有做「换图前后 AI 行为的专项回归」，由实际关卡验收。
- 对话头像 / 说话人立绘 / 语音 / 分支选项不做。
