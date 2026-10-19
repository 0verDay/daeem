# dev_plan_12 · 双人合作模式（联机）——实施方案

> 本文是**独立编号的第 12 份规划文档**（第 10 份已缺失，第 11 份是性能专题）。
> 它与 [`route.md`](route.md) 的「第 N 轮」体系无关：route.md 记的是**已经落地**的现状，
> 本文记的是**接下来要做什么、按什么顺序做、怎么验收**。
>
> **本轮只出方案，不改代码**（用户 2026.10.19 明确选择）。
>
> 三条约定沿用本工程：
> 1. **不含工时估算**，只排顺序、依赖与验收。
> 2. 每条设计都要能回答「**谁读它 / 缺了怎么办 / 断言在哪**」。
> 3. ★ = 已拍板或不能改的硬约定；⚠️ = 已实测踩过的坑或必须写进断言的边界；
>    ❓ = 还要拍板的小项（本文已尽量清零，剩余项集中在第十二节）。

---

## 实施状态（2026.10.19）

| 里程碑 | 状态 | 落点 | 断言 |
|---|---|---|---|
| **M12.1 席位判据 + 目标条** | ✅ **已完成** | `world.accepts_owner()` / `is_own_seat()`；`level.coop_roster()`；`command_processor` / `upgrade` 的归属判据收口；`view/objective_panel.gd` + `hud.gd` + `ui_layout.gd`；`config.coop.objective` | `test_coop_seats.gd` 41 项 + `test_coop_objective.gd` 26 项；`test_ui` 1148 / `test_upgrade` 221 / `test_logic` 280 / `test_campaign_seats` 72 / `test_outcome` 71 / `test_attack_orders` 108 全绿 |
| **M12.2 快照 + 协议 + 会话** | ✅ **已完成** | `logic/snapshot.gd`（pres/obj/tech/建筑与单位血量上限/建筑升级/区划特化）；`logic/world.gd`（按席位科技效果 `seat_tech_effects` + `refresh_after_snapshot()`）；`net/protocol.gd`、`net/transport.gd`、`net/event_codec.gd`、`net/host_session.gd`、`net/client_session.gd`；`tests/fake_transport.gd` | `test_snapshot_coop.gd` 29 + `test_protocol.gd` 19 + `test_session.gd` 25 + `test_coop_tech.gd` 13；`test_logic` 280 / `test_tech` 116 / `test_ui` 1148 / `test_campaign_seats` 72 / `test_outcome` 71 / `test_upgrade` 221 / `test_ai` 54 全绿 |
| **M12.3 本机双进程** | ✅ **已完成** | `server/daeem_relay.py`（零依赖 RFC6455 中继）、`server/relay_client.py`、`server/probe_relay.py`、`server/run-local.ps1`、`server/test_relay.py`；`net/relay_transport.gd`；`tests/test_relay_transport.gd` | `server/test_relay.py` 6 项（握手 / 分片 / 掩码 / 126/127 / close / 房间转发）；`run-local.ps1` 一条命令 `RUN LOCAL OK`；`test_relay_transport.gd` 13 项 |
| **M12.4 合作大厅** | ✅ **已完成** | `net/lobby.gd`；`view/coop_lobby.gd`；`menu_secondary_panel` / `menu_chrome` / `start_screen` / `main.gd` 接线；`game_scene3d.start_coop_host/guest`；`test_2` 改为合作入口；合作局禁用暂停 | `test_coop_lobby.gd` 12 + `test_coop_entry.gd` 8 + `test_coop_game_scene.gd` 18；`test_start_flow` 130 / `test_campaign_menu` 116 / `test_ui` 1148 全绿 |
| **M12.5 公网部署** | ✅ **已完成（2026.10.19）** | `server/deploy.ps1`（幂等 / 备份 / 健康检查 / 回滚 / `-DryRun`）；腾讯云 Windows + nssm `DAEEMRelay`；`ws://159.75.154.122:8770/ws`；`server/README.md` 实测记录 | 公网 `/health` 返回 `ok:true`；host/guest 探针完成 `hello → create_room → join → ready → start → cmd → snap → bye`，两端 `PROBE ... OK`；首次 PC+Android 联机由用户确认成功（未逐项记录） |
| **M12.6 文档收口** | ✅ **已完成** | `route.md` 第五十二节；`handoff_12.md`；`architecture.md`；`pitfalls.md` 5.73~5.76；`docs/README.md`；`server/README.md`；`mobile.md` 第 20 节 | 文档与实测一致；根 `README.md` 未改（需用户明确同意） |
| **M12.7 快照 30Hz + 联机优化** | ✅ **已完成（2026.10.19）** | `net.snapshot_hz = 30` / `snapshot_buffer_limit_kb = 1024`；`host_session` 背压；`client_session` 合并；`transport` / `relay_transport` 的 `buffered_amount()`；`snapshot.apply_snapshot()` id 索引；`tests/bench_snapshot.gd` | M12 套件 **213** + relay 6 + 语法 159 全绿；30Hz 测量见 `route.md` 第五十三节 |

> ⚠️ **M12.1 落地时纠正了本文初稿的一条错误假设**：`FactionRes.same_side()` 本来就是严格同阵营
> （`a == b`），盟友在 `same_side_for_attack()` 里。所以合作模式不需要 `strict_seat_owner` 开关；
> 见 4.2 的修订。
>
> ✅ `test_2` 已在 M12.4 改成**合作大厅入口**（不再直接进 `02_twin_line`）；直接调用
>   `main._on_level_entry_pressed("demo","02_twin_line")` 的旧测试仍可走单人路径。
>
> ⚠️ M12.4 的已知限制：客机快照 20Hz **直接写位置**，没有做视觉插值；先保证状态一致与
>   命令正确，插值放后续优化。
>
> ✅ **M12.5 已在 2026.10.19 部署**：腾讯云 Windows + nssm `DAEEMRelay`，
>   公网 `ws://159.75.154.122:8770/ws`；公网 `/health` 与 host/guest 探针通过。
>   ✅ **M12.6 文档已收口**（`route.md` 第五十二节 / `pitfalls.md` 5.73~5.76 / `mobile.md` 第 20 节）。
>   ★ 唯一保留的可选项是**客机视觉插值**。

---

## 〇、一页结论

| # | 项 | 结论 |
|---|---|---|
| 1 | **目标** | 两名玩家各指挥一个同方阵营，共同对抗 AI，打通现有合作关 `demo/02_twin_line`（守住 c1 120 秒）。 |
| 2 | **交付状态** | **M12.1 ~ M12.7 已全部落地**；公网已部署到 `ws://159.75.154.122:8770/ws`（服务 `DAEEMRelay`），公网 `/health` + host/guest 探针通过；快照默认 30Hz + 背压 / 客机合并；首次 PC+Android 联机由用户确认成功。唯一可选项：客机视觉插值。 |
| 3 | **网络拓扑** | **房主权威 + 哑中继**：房主跑全部 `logic/`，客机只发命令、收快照；中继只转发，不 import 任何游戏逻辑。 |
| 4 | **传输层** | 先做 **WebSocket 中继**（云服务器上跑一个 Python 单文件）；**传输接口与协议分离**，以后换 Steam P2P 只换 transport，不动协议与会话。 |
| 5 | **本轮验收环境** | **公网中继 + 两台客户端**：`ws://159.75.154.122:8770/ws`（腾讯云 Windows）；本机探针与首次 PC+Android 联机均已跑通。 |
| 6 | **席位** | 房主 = `players[0]`，客机 = `players[1]`；**各指挥自己的阵营**，资源各自独立，视野共享。 |
| 7 | **关卡入口** | 「合作模式」面板只列 `mode == "coop"` 的关；当前就是 `demo/02_twin_line`。 |
| 8 | **不做的** | 断线重连、合作暂停、观战、3 人以上、匹配/房间列表、反作弊、TLS、Steam 实装；Android 只做首次联机确认，不做逐项验收。 |
| 9 | **最小可玩闭环** | 本机起中继 → 两个客户端建房/加入 → 进 `02_twin_line` → 两人各控一方、共享视野、各自资源 → 目标进度可见 → 一方关掉另一方有提示。 |

**一句话**：「两个玩家在同一个世界里，各自只能动自己的兵」已经在本机两个进程和**公网
两台机器**（含首次 Android 客户端）里跑通；Steam P2P 是以后换一层 transport 的事，
不是这一轮的事。

---

## 一、已拍板的口径

### 1.1 用户本轮拍板（2026.10.19）

| # | 问题 | 结论 |
|---|---|---|
| 1 | 这一轮交付到哪一步 | **先出书面方案**，不改代码 |
| 2 | 联机技术路线 | 「我有一台云服务器，后续想移植为 Steam P2P，**怎么方便怎么来**」→ 落成 **房主权威 + 可替换 transport**，先 WebSocket 中继，后 Steam P2P |
| 3 | 验收环境 | **先本机双进程，云上后置** |
| 4 | 合作入口列哪些关 | **只列 `mode == "coop"` 的关** |
| 5 | 操作权限 | **各指挥自己的阵营**；资源各自独立；视野共享；不能指挥队友的兵 |
| 6 | 既有边界 | **都不改**：房主权威、无断线重连、无合作暂停、20Hz 全量快照、客机不接管 |

> ★ **为什么选「中继」而不是 ENet 直连**：ENet 直连要求房主机器公网可达或做端口映射；
> 中继让双方都只做出站连接，跨 NAT 最省事，而用户手上正好有一台云服务器。
> 以后换 Steam P2P，Valve 的通道解决的也是同一件事 —— 所以 `transport` 抽象现在就要留。

### 1.2 从 dev_plan_7 继承、仍然有效的部分

- 合作固定 **2 人**，房间码即身份，**不做房间列表**。
- **房主跑逻辑**：tick、AI、目标与胜负判定；客机**不 tick、不跑 AI、不判胜负**。
- 中继只按「房主 → 客机」「客机 → 房主」两条规则转发；服务器上没有游戏规则。
- 命令**只放意图不放结果**；快照**只发结果不发过程**；快照**缺字段 = 保持本地现状**。
- 明文 `ws://`、无鉴权、无反作弊、无断线重连；房主掉线 = 这一局结束。
- 房间码 6 位大写字母数字，去掉易混的 `0/O/1/I`。

### 1.3 与 dev_plan_7 的偏离（必须按现状改）

dev_plan_7 写在 AI 重做与「选边关」之前，下面几条**不要照抄**：

| dev_plan_7 的旧口径 | 现状（以此为准） |
|---|---|
| 两种 AI：阵营性 `faction_ai` / 将领性 `general_ai` | 现在是 **阵地性 `garrison_ai` + 红点性 `red_dot_ai`**；AI 阵营没有大本营与资源库 |
| 目标只有 `hold_zone` | 现在还有 **`capture_zone`**，且支持「选边关」按阵营取目标 |
| 阵营不能同时可玩 + 挂 AI | 可以；**运行时按本局玩家席位摘 AI** |
| 关卡只列单人关 | 现在要反过来：**合作面板只列 `mode == "coop"` 的关**；单人战役走 test_1/3 与战役菜单 |
| 快照补 6 组字段 | 现状还要补 **按席位资源、目标状态、科技、建筑升级、区划特化、事件**（见第五节） |

---

## 二、现状核对（代码级）

### 2.1 已经有的

| 能力 | 落点 | 说明 |
|---|---|---|
| 双人合作关数据 | `data/campaigns/demo/levels/02_twin_line.json` | 两个 `players[]` 席位（F1/F2），同方，共享视野，各自大本营 |
| 两席位装配 | `logic/world.gd:create_from_level()` + `logic/level.gd:build_roster()` | `roster` 是两个席位；`my_faction` 排第一；`player_seats` / `player_factions` 已区分 |
| 按席位资源 | `world.player_resources` + `resource_pool_for()` | 每个玩家席位一份；`world.resources` 是本机席位那一份的别名 |
| 共享视野 | `logic/fog.gd` 按 `FactionRes.side_of()` 分桶 | 同方共享，第三方看不到 |
| 目标与胜负 | `logic/objective.gd` | 守住 / 攻占、丢即负、大本营被拆、额外失败条件 |
| 命令 / 快照边界 | `logic/command_processor.gd`、`logic/snapshot.gd` | 已经是「命令进、快照出」的形状 |
| 阵营 AI | `logic/garrison_ai.gd`、`logic/red_dot_ai.gd` | 按阵营挂，玩家席位自动摘掉 |

### 2.2 缺口（按严重程度）

| # | 缺口 | 现状证据 | 后果 |
|---|---|---|---|
| 1 | **没有网络层** | 仓库里没有 `net/`、没有 `server/` | 两人无法联机 |
| 2 | **没有合作入口** | 主菜单「合作模式」撑开的是空面板（`menu_chrome.gd` 的注释写明） | 玩家进不去合作关 |
| 3 | **席位判据没有收口** | `input_controller` / `command_processor` 用 `FactionRes.same_side(..., world.my_faction)`；读 `logic/faction.gd` 确认 `same_side` **本来就是严格同阵营**（`a == b`），盟友是 `same_side_for_attack` | 本地其实已经「各控各的」；缺的是把「每端 `my_faction` / `roster` 同序」在装配层钉死，并把判据收成 `accepts_owner()`，免得以后误用盟友判据 |
| 4 | **快照缺字段** | `snapshot.to_snapshot()` 只发 `units/buildings/zones/projectiles/res/owned/time`；没有 `pres` / `obj` / `tech` / 建筑升级 / 区划特化 / 事件 | 客机资源是错的、目标面板是空的、升级与特化读条不显示 |
| 5 | **客机不会刷新派生数据** | `fog.update()` 与 `refresh_ownership()` 都在 `world.tick()` 里；客机不 tick | 客机迷雾/归属停在开局 |
| 6 | **没有客机位置插值** | 3D 单位视图直接读 `u.pos`，`apply_snapshot()` 直接把权威位置写进 `u.pos` | 20Hz 快照下客机单位会一顿一顿 |
| 7 | **目标进度没有 UI** | `view/` 里没有任何 `objective_state` / `level_end` 的读取 | 玩家看不到「守住 c1 92/120 秒」，也不知道为什么输 |
| 8 | **房主逻辑仍有 my_faction 中心** | `world.tick()` 里科技加成、区划人口加成、领地事件都只按 `my_faction` 算 | 客机席位的科技/人口加成在房主侧不生效（资源本身是各算各的） |
| 9 | **同机 test_2 是「一人控两方」** | `main.gd` 取 `playable[0]`，`build_roster()` 把两个席位都塞进 roster；输入只按 `same_side` 过滤 | 今天按 test_2 能进，但不是双人合作，只是一个人多控 |

### 2.3 关键代码路径（改的时候按这张表找）

| 路径 | 现在做什么 | 本轮要接什么 |
|---|---|---|
| `view/main.gd:_on_level_entry_pressed()` | 载战役 → 取关卡 → 取第一个可玩阵营 → `game.start_level()` | 合作走另一条：大厅 → `start_coop()` |
| `view/game_scene3d.gd:start_level()` | `build_roster()` + `create_from_level()` + `_assemble()` | 增加房主 / 客机两种启动参数 |
| `view/game_scene3d.gd:_process()` | 每帧 `world.tick()` + 同步视图 | 房主 tick；客机只 `session.poll()` + 应用快照 + 刷新派生数据 |
| `view/game_scene3d.gd:_on_command()` | 直接 `CommandRes.apply()` | 房主直接执行；客机交给 `session.send_command()` |
| `view/input_controller.gd` | 选中 / 建造 / 招募都按 `world.my_faction` + `same_side` | 选中保持 `same_side`（队友可查看）；建造 / 招募 / 下令改成「严格等于自己的席位」 |
| `logic/command_processor.gd` | `cmd.faction` 缺省取 `world.my_faction`；单位收集按 `same_side` | 房主校验 `by` / `faction`，收集按**严格归属** |
| `logic/snapshot.gd` | 只发基础状态 | 补第五节那几组字段 |
| `logic/world.gd:tick()` | 科技 / 人口 / 领地事件按 `my_faction` | 按本机席位 + 其余玩家席位各算一遍 |
| `view/menu_chrome.gd` | 合作按钮 → 空面板 | 合作按钮 → `view/coop_lobby.gd` |
| `view/menu_secondary_panel.gd` | 只支持战役菜单 / 空面板 | 增加合作大厅内容区 |

---

## 三、总体架构

### 3.1 拓扑

```
房主（players[0]）                          客机（players[1]）
┌─────────────────────────┐                ┌─────────────────────────┐
│ input_controller        │                │ input_controller        │
│   ↓ 命令                 │                │   ↓ 命令                 │
│ host_session            │                │ client_session          │
│   ↓                      │                │   ↓ 上行 cmd             │
│ command_processor       │                │ transport               │
│   ↓                      │                │   ↑ 下行 snap / event    │
│ world.tick() 60Hz       │                │ world（不 tick）         │
│   ↓ 20Hz                 │                │   ↑ apply_snapshot       │
│ snapshot.to_snapshot()  │                │   ↓ 渲染 / HUD           │
└──────────┬──────────────┘                └──────────▲──────────────┘
           │ WebSocket                                │ WebSocket
           └──────────────► 哑中继 ◄──────────────────┘
                    只转发，不 import 任何游戏逻辑
```

### 3.2 `net/` 层（新增，与 `logic/`、`view/` 平级）

| 文件 | 类型 | 职责 | 不做什么 |
|---|---|---|---|
| `net/protocol.gd` | 纯 `RefCounted` | 消息类型常量、协议版本、信封编解码与校验；非法消息返回错误而不是崩 | 不碰 socket、不碰世界 |
| `net/transport.gd` | 纯 `RefCounted`（接口 / 文档） | 定义 `connect / send_reliable / send_unreliable / poll / close` 与四个信号 | 不实现具体网络 |
| `net/relay_transport.gd` | `Node` | 包 `WebSocketPeer`：连接中继、收发包、断开 | 不做自动重连 |
| `net/host_session.gd` | `Node` | 房间生命周期、席位分配、校验客机命令、20Hz 快照、事件广播 | 不渲染、不读输入 |
| `net/client_session.gd` | `Node` | 上行命令、下行快照（交给 `snapshot.apply_snapshot`）、房主离开时收摊 | 不 tick、不跑 AI |
| `net/lobby.gd` | `Node` | 建房 / 加入 / 房间码 / 准备状态；**与具体 transport 解耦** | 不建世界、不载关卡 |

> ★ **为什么要有 `transport.gd` 这一层**：用户明确说以后想换 Steam P2P。
> 换 Steam 时只新增 `net/steam_transport.gd`（GodotSteam 的 P2P 通道 + 大厅），
> `protocol` / `host_session` / `client_session` / `view` 一行不改。
> ⚠️ Steam P2P 的第一版只能保证「可靠消息 + 不可靠消息」两种通道；
> 命令走可靠、快照走不可靠（丢了就等下一帧），这条现在就在接口里分开。

### 3.3 一次对局的时序

```
房主                         中继                         客机
 │ hello                       │                            │
 │ create_room(level)         │                            │
 │◄──────── room_state ───────│                            │
 │                            │◄──────── hello ────────────│
 │                            │◄──────── join_room ────────│
 │◄──────── room_state ───────┼──────── room_state ───────►│
 │◄──────── ready ────────────┼──────── ready ────────────►│
 │ start(level_data) ────────►│──────── start ────────────►│
 │ 建 world（房主席位）        │                            │ 建 world（客机席位，不 tick）
 │ tick + 20Hz snap ─────────►│──────── snap ─────────────►│ apply_snapshot + 刷新派生数据
 │◄──────── cmd ──────────────┼◄──────── cmd ──────────────│
 │ 校验 → command_processor   │                            │
 │◄──────── event ────────────┼──────── event ────────────►│ HUD 播报
 │ bye（房主退出）────────────►│──────── bye ──────────────►│ 回主界面 + 提示
```

### 3.4 单机路径不变

- `main._on_test_pressed()`（直开一张图）与 `main._on_level_entry_pressed()`（单人战役）**保持原样**。
- 合作走**第三条入口**：`view/coop_lobby.gd` → `main` → `game.start_coop()`。
- 只有「合作」这一条路会创建 session；没有 session 时 `game_scene3d` 的行为与今天逐位一致。
- 这是硬门槛：现有全量测试必须全绿，`test_2` 的旧行为（同机一人控两方）可以保留给测试，
  但界面上不再把它当合作入口。

### 3.5 协议消息表

一条消息 = JSON 对象，信封固定：`{"v":1, "t":"<类型>", "seq":n, "ts":ms, "body":{…}}`。
`seq` 每连接单调递增；`ts` 现在就带上（以后做录像 / 排查时序用）。

| `t` | 方向 | body | 说明 |
|---|---|---|---|
| `hello` | 客户端 → 中继 | `{proto:1, game:"daeem", build:"<常量>"}` | 握手；`build` 不一致时中继拒绝 |
| `create_room` | 房主 → 中继 | `{mode:"coop", campaign, level}` | 建房；房间元信息只用于显示，不含世界状态 |
| `join_room` | 客机 → 中继 | `{room:"ABC123"}` | 加入；房间不存在 / 满 / 已开局 → `err` |
| `room_state` | 中继 → 双方 | `{room, host_seat, guest_seat, ready, campaign, level}` | 成员与准备状态 |
| `ready` | 双方 → 中继 | `{ready:true}` | 准备；两边都准备后房主「开始」才亮 |
| `start` | 房主 → 中继 → 客机 | `{campaign, level_id, level_data:{…}, seats:[...], host_seat, guest_seat, build}` | 开局；**关卡数据由房主发**，客机不必有同一个战役目录 |
| `cmd` | 客机 → 房主 | `{by:"F2", cmd:{kind, …}}` | 玩家命令；**序号用信封 `seq`**（每个连接内必须递增），房主按 4.3 校验 |
| `snap` | 房主 → 客机 | `{seq, snap:{…}}` | 20Hz 世界快照；WebSocket 下可靠有序，Steam P2P 下走不可靠通道 |
| `event` | 房主 → 客机 | `{items:[…]}` | 播报 / 胜负；立刻发，不等下一个 20Hz |
| `ping` / `pong` | 双向 | `{t}` | 保活 + HUD 延迟显示 |
| `bye` | 双向 | `{reason}` | 主动离开；房主 `bye` = 这一局结束 |
| `err` | 中继 → 客户端 | `{code, msg}` | 房间不存在 / 房间满 / 版本不符 / 房间已开局 |

- ⚠️ `start` 里的 `level_data` 是**关卡层**（`players` / `start_units` / `objectives` / `allies` …），
  不是地图；地图仍由本地 `data/maps/<map_id>/` 读。两端 `build` 一致 ⇒ 地图一致；
  以后真要跨版本，再把地图数据也塞进 `start`。
- ⚠️ 客机 `world` 用 `level_data` + `with_ai=false` 建出来；**不能**用本地战役目录重新载入，
  否则「房主的关卡被手改过、客机还是旧数据」会悄悄分叉。
- ⚠️ `snap` 不做确认 / 重传：丢一帧就等下一帧（50ms）；命令必须可靠。

---

## 四、席位与权限（本轮最关键的一节）

### 4.1 席位分配

| 角色 | 阵营 | `world.my_faction` | `roster` | 资源 | 视野 |
|---|---|---|---|---|---|
| 房主 | `players[0]` | 房主席位 | `[房主, 客机]` | 房主自己的池 | 同方共享 |
| 客机 | `players[1]` | 客机席位 | `[房主, 客机]` | 客机自己的池 | 同方共享 |

- 两端都**建两个大本营、两支部队**（`roster` 两个席位），但各自只操作自己那一方。
- `player_seats` 两端都是两个；`player_factions` 也是两个（合作关两方都没挂 AI）。
- 目标判定走「玩家同方」：客机守住也算，房主守住也算。
- ★★ **`roster` 必须两端同序**：固定 `[players[0], players[1]]`，**不要**直接复用
  `level.build_roster(cfg, my_faction)` —— 那个函数会把本机席位排到第一（为了单人 / 选边关的
  「目标按第一个席位取」），两端会得到不同的顺序。而 `world.reset()` 会拿 `factions[0]` 当
  `primary` 传给 `map.spawn_layout_for()`，顺序不同可能让两端开局出生点不同。
  合作关两个席位同方、目标相同，不需要「本机排第一」；`my_faction` 单独传，不靠 roster 顺序表达。
- 新增 `level.coop_roster()`（返回 `seats()` 的原序）或由 `start_coop()` 直接传 `level.seats()`；
  ⚠️ 不要改 `build_roster()` 的旧语义（单人 / 选边关还在用）。

### 4.2 ★★ 席位归属：真正的判据是「同阵营」，不是「同方盟友」

★★ **先纠正本文初稿里一个写错的假设**（2026.10.19 落地 M12.1 时读代码核对）：

`FactionRes.same_side()` 的实现就是 `a == b`（**严格同阵营**），
「盟友」那一套在 `same_side_for_attack()` 里。所以合作两人虽然是盟友，
`input_controller` / `command_processor` 现在用的 `same_side` **已经**把队友挡在命令之外了。
⇒ **不需要** `strict_seat_owner` 开关，也不需要把 `same_side` 换成「更严格」的比较；
需要的是下面四件事：

1. 每个客户端的 `my_faction` = **自己的席位**（房主 F1 / 客机 F2）；
2. 两端 `roster` 同序（见 4.1），否则开局出生点可能不同；
3. 把判据收成有名字的 `world.accepts_owner()`，**别让以后的人误用 `same_side_for_attack`**
   （那个是「能不能打」的判据，不是「能不能指挥」的判据）；
4. 网络层仍然校验 `by` / `faction`（见 4.3）—— 这不是修本地漏洞，是**防客机改包**。

```gdscript
# logic/world.gd（M12.1 已落地）
## 这一方的东西归不归本机操作：内部就是严格同阵营。
func is_own_seat(faction: String) -> bool:
    return accepts_owner(faction, my_faction)

## 命令层 / 规则层用的归属判据：actual 这一方的东西，能不能被 cmd_faction 操作。
func accepts_owner(actual: String, cmd_faction: String) -> bool:
    if actual == "" or cmd_faction == "":
        return false
    return FactionRes.same_side(actual, cmd_faction)   # a == b，不是盟友
```

改造点分**两层**：**选中（查看）**与**下令（改状态）**不是一回事。

| 层 | 位置 | 改法（M12.1） |
|---|---|---|
| 选中 | `view/input_controller.gd` 左键点 / 框选友军 | 保持 `same_side`（严格同阵营；队友的点不到，自然也不会被框进命令） |
| 选中 | `view/input_controller.gd` 点敌人 | 仍走 `same_side_for_attack` 的**取反**（敌人 / 非盟友） |
| 下令 | `view/input_controller.gd` 停止 / 命令模式 | `_commandable_selected()` 先按 `world.is_own_seat()` 滤一遍 |
| 下令 | `view/input_controller.gd` 招募 / 区划招募 / 再起 | `first_selected_leader()` / 区划归属都走 `is_own_seat()` |
| 下令 | `logic/command_processor.gd:_collect_units()` | `world.accepts_owner(u.faction, owner_faction)` |
| 下令 | `logic/command_processor.gd` 建筑类命令 | `world.accepts_owner(b.owner, owner_faction)` |
| 下令 | `logic/upgrade.gd` 升级 / 特化 | `world.accepts_owner(...)`；取消类函数的 `world` 参数可选，老测试不传仍走 `same_side` |
| 下令 | `world.can_recruit` / `can_recruit_zone` / `zone_allows_build` / `leader_zone_owned` | `accepts_owner(...)`（旧行为逐位不变，只是判据有了名字） |
| 资源 | `command_processor.apply_build()` | 钱从 `world.resource_pool_for(owner)` 出，不再写死 `world.resources`（客机建造不该花房主的钱） |

> ★ 为什么仍然值得加 `accepts_owner()`：`same_side` 和 `same_side_for_attack` 名字太像，
> 而本工程已经有「盟友不互相打、但建筑对盟友放行」那一套。把「谁能操作谁」收成**一个名字**，
> 以后真要给某张图开「盟友可指挥」，只改这一处，不用追 20 个调用点。
> ⚠️ 合作时「选中队友的兵」**不允许**（`same_side` 严格）：不是怕你下令，而是选中集合本身
> 就是命令的输入；先点不到，后面 `_collect_units` 那一层才是第二道。

### 4.3 命令信封与房主校验

客机发上来的命令必须带发送者：

```json
{"by": "F2", "cmd": {"kind": "move", "ids": ["..."], "x": 4.5, "y": 9.0, "faction": "F2"}}
```

房主收到后按顺序校验，任一不过就**丢弃并记一行日志**（不回错误，避免被探测）：

1. `by` 必须等于这个连接被分配的席位；
2. `cmd.faction` 必须等于 `by`（缺省时补 `by`，但**不允许**客机自己写别的 faction）；
3. 单位的 `faction` 必须严格等于 `by`（不是 `same_side`）；
4. 建筑的 `owner` 必须严格等于 `by`；
5. 信封的 `seq` 必须递增（同一连接内）；重复 / 倒退的丢弃。

> ★ 这不是反作弊，是**防自己写错**：两人同时下单时，「谁的钱被扣、谁的兵在动」必须唯一确定。
> ⚠️ 客机在本地也会做一次同样的过滤（选中层），但**房主那一层不能省** —— 客机可以被改。

### 4.4 按席位资源与科技

- 资源：`world.player_resources` 已经按席位；`resource_pool_for()` 已经是唯一扣费入口；
  `world.resources` 是本机席位那一份的**同一个对象**，HUD 不用改。
- 科技：`logic/tech.gd` 本来就是按阵营存（`effects_of(faction)`），但 `world.tech_effects`
  只缓存了 `my_faction` 那一份。**M12.2 已落地**：
  - 新增 `world.seat_tech_effects: {faction: Dictionary}`；
  - `_refresh_production()` 对每个玩家席位各取一份（`_accumulate_production(..., eff)`）；
  - ★ 人口增长**不能**「对每个席位各调一次 `update_population`」——那个函数会遍历全部区划，
    调两次就把基础增长算两遍。新增 `zones.update_population_multi(dt, owner_mults)`：
    **每个区划只长一次**，按它自己的 owner 取倍率；
  - `_apply_tech_effects()` 的血量上限加成也按席位遍历（只影响 `owner == 该席位` 的单位 / 建筑）。
  - `world.tech_effects` 保留为 `seat_tech_effects[my_faction]` 的别名，`view/` 不用改。
- ⚠️ 血量加成那一条要小心：现有实现是「按版本号触发 + 只遍历同方」；
  改成按席位遍历时，**同一支部队不能被加两次**（合作两人是盟友，`same_side` 会重叠）。
  判据必须是 `u.faction == 该席位`，不是 `same_side`。`test_coop_tech.gd` 钉住这条。

### 4.5 目标与胜负

- `objective.setup()` 已经接收 `defend` 席位数组；合作时两个席位都在 `defend` 里。
- 房主 tick 目标；客机不 tick，只从快照 `obj` 读 `held / state / reason`。
- 「目标区划丢掉即负」「大本营全部被拆」等规则**不变**，只换数据来源。
- ⚠️ 客机的 `world.objective_state` 必须**只被快照写**，不能在本地 `setup()` 后又按空状态 tick。
- ★★ **合作关只允许一条「通用目标」**（`objectives[].for` 为空），不允许按阵营各配一条：
  `level.objective_for(fid)` 会按 `fid` 取，两端 `my_faction` 不同 ⇒ 房主与客机可能拿到不同目标，
  而客机只收房主一份 `obj`。装配时（`start_coop()`）与编辑器导出校验各拦一次：
  「合作关的目标不能带 `for`，请改成一条对所有玩家成立的共享目标」。

---

## 五、快照补全

> ✅ **M12.7 起默认 30Hz**（`net.snapshot_hz`，代码夹 10~60），并加了发送端背压
> （出站缓冲 > 1 MiB 跳过快照）与客机快照合并（每轮只应用最后一条）；
> 实测与改动见 [`route.md`](route.md) 第五十三节。下面 20Hz 的描述保留为当时的方案记录。

### 5.1 新增字段

| 字段 | 形状 | 为什么必须发 | 客机怎么用 |
|---|---|---|---|
| `pres` | `{"F1": [food, gold], "F2": [...]}` | 现有 `res` 只有一份池，客机会把房主的钱当成自己的 | 只写自己席位那一份；`world.resources` 指向它 |
| `obj` | `{kind, zone, held, sec, state, reason}` | 客机要画目标进度与判负原因 | 写 `world.objective_state` 的只读副本 |
| `tech` | `{"F1": [ids], "F2": [ids]}` | 客机要画科技九格高亮 | 写 `world.tech` 的按阵营状态 |
| `units[].mh` | int | 单位血量上限（含科技 / 等级加成） | 画血条比例 |
| `buildings[].lv` | int | 建筑等级 | 画等级 / 升级后的血量 |
| `buildings[].mh` | int | 血量上限 | 血条比例 |
| `buildings[].uk` | int（1/0） | 是否在升级读条 | 画升级读条 |
| `buildings[].ur` | float | 升级剩余秒 | 同上 |
| `zones[].sk` | string | 区划特化读条的种类（空 = 没读条） | 画特化读条 |
| `zones[].sr` | float | 特化剩余秒 | 同上 |
| `zones[].sd` | string | 已完成特化 id | 画特化结果 |
| `zones[].st` | float | 特化总秒数 | 进度条分母 |
| `zones[].sx` | bool | 这一单是不是「取消特化」 | 文案 / 进度颜色 |

> ★ 字段名继续用短名；**缺字段 = 保持本地现状**，不要当成 0 / false。
> 这是 HTML 版踩过的坑（旧快照把结算画面打回进行中），`test_snapshot_coop.gd` 要专门盯。
> ⚠️ `res`（单份）仍是旧字段：**只有单席位**（`player_seats.size() <= 1`）才回落到它；
> 合作局（两个席位）缺 `pres` 时按「坏快照」保持本地现状，否则会把房主的钱覆盖到客机头上。
> ★ 配套的 `world.seat_tech_effects`（每席位科技效果）在 M12.2 落地：房主的科技不会加到
> 客机的单位 / 建筑上；`test_coop_tech.gd` 钉住「各吃各的」。

### 5.2 事件

- `world.tick()` 返回的事件数组**不塞进快照**，走单独的 `event` 消息（立刻发，不等 20Hz）。
- 事件类型先接这几条：`unit_recruited` / `recruit_rejected` / `order_rejected` / `ai_attack_launched` /
  `objective_progress` / `level_end`。
- 客机把事件交给**与房主同一个**消费函数（从 `game_scene3d._consume_events()` 抽出来），
  避免「房主看得到、客机看不到」的两份文案。

### 5.3 客机应用快照后的派生刷新

客机不 tick，所以下面这些必须显式刷新（新增 `world.refresh_after_snapshot()`）：

| 派生数据 | 现在只在 tick 里做 | 客机怎么刷 |
|---|---|---|
| 迷雾 | `fog.update()` | 应用快照后调一次 |
| 建筑 / 区划归属缓存 | `refresh_ownership()` | 同上 |
| 选中集合里的死亡单位 | `input_ctrl.drop_dead_selection()` | 快照后调一次 |
| 资源显示 | `world.resources` | `pres` 里自己那一份 |

### 5.4 位置插值

- 现状 3D 单位视图直接读 `u.pos`；`apply_snapshot()` 把权威位置直接写进 `pos` ⇒ 20Hz 下会跳。
- 方案：客机保留 `pos` 为**权威位置**（选中 / 射程 / 迷雾用它），另加一个**显示位置**
  `render_pos`，视图层优先读它；每帧向 `pos` 做指数插值。
- 房主 / 单机不启用插值（`render_pos` 始终等于 `pos`），行为逐位不变。
- 投掷物同理：`projectile` 的显示位置插值，命中结算仍按权威值。

---

## 六、合作大厅与界面

### 6.1 入口

```
主界面 → 右下「合作模式」按钮
  └── view/coop_lobby.gd（撑开的面板内容区，与战役菜单同一套版式）
       ├── 创建房间：选战役 + 关卡（只列 mode == "coop"）→ 显示 6 位房间码
       ├── 加入房间：输入房间码 → 显示双方席位 / 准备状态
       ├── 准备：两边都准备 → 房主「开始」亮
       └── 开始：房主发 start（含关卡数据）→ 双方进游戏
```

- **不做房间列表**：只输房间码。
- **不做选阵营**：房主固定 `players[0]`，客机固定 `players[1]`。
- 关卡下拉的数据源：`campaign_library` 扫出来的战役 + 关卡，过滤 `mode == "coop"`。
  当前只有 `demo / 02_twin_line`；以后加合作关只加数据。
- 错误提示一行：房间不存在 / 房间满 / 版本不一致 / 已开局。
- 几何常量全部进 `view/ui_layout.gd`，文案与字号进 `data/config.json` 的 `coop` 段。
- 手机端：`LineEdit` 用系统虚拟键盘；**本轮只验收 PC**，手机端只保证不崩。

### 6.2 局内 HUD

| 新增 | 内容 | 落点 |
|---|---|---|
| 目标条 | 「守住 c1 · 92/120 秒」+ 进度条；失败时写原因 | `view/objective_panel.gd`（新）或 HUD 内嵌一条 |
| 合作信息 | 右上角小字：`合作 · 房主/客机 · ping 42ms` | `view/hud.gd` |
| 队友状态 | 「队友已就位 / 队友掉线 / 房主已离开」 | 复用底栏提示带 |
| 结束提示 | 「本关守住！」/「本关失守：目标区划失守」+ 返回主菜单 | 不做结算面板；一行提示 + 一颗按钮 |

> ⚠️ 所有几何仍然只进 `ui_layout.gd`；新面板要配「装得下」断言（字体度量是本工程丢过人的地方）。
> ★ 目标 UI 是**本轮必须做**的：没有它，合作关玩家不知道在守什么、也不知道为什么输。
> 现有代码里 `view/` 完全没有读 `objective_state`，这是要补的空白，不是改样式。

### 6.3 返回与掉线

| 情况 | 行为 |
|---|---|
| 房主点「返回主菜单」/ 关窗口 | 发 `bye`；客机回主界面并提示「房主已离开」 |
| 客机点「返回主菜单」/ 关窗口 | 发 `bye`；房主那一局继续（AI 照跑、目标照判），提示「队友已离开」 |
| 中继断开 | 双方回主界面，提示「与服务器断开」 |
| 房主掉线 | 客机回主界面；**不接管** |
| 版本 / build 不一致 | 中继拒绝；提示「两边版本不一致」 |

> ★ 不做断线重连：这是用户本轮拍板保留的边界。房主掉线 = 这一局结束。
> ★ 不做合作暂停：单人暂停键在合作里禁用，或只暂停本地 UI（不冻世界）。

---

## 七、服务器与传输

### 7.1 先本机，后云上

| 阶段 | 做什么 | 验收 |
|---|---|---|
| **本机** | 中继跑 `127.0.0.1` 随机端口；`server/run-local.ps1` 起中继 + 房主探针 + 客机探针 | 一条命令 exit 0 |
| **云上** | 腾讯云 Windows + nssm 托管；放行 TCP 端口；`/health` 可 curl | 两台机器真的能开局 |

### 7.2 中继

- `server/daeem_relay.py`：**单文件、标准库、零第三方依赖**；自实现 RFC6455 的服务端最小子集
  （握手 / 掩码解包 / 文本帧 / ping-pong / close）。
- 只做两件事：按房间转发；维护房间与健康检查。
- 路由：
  - `GET /health` → `{"ok": true, "rooms": n, "players": n, "uptime": s}`
  - `GET /rooms` → 运维用，不暴露 IP（界面不做列表）
  - `WS /ws` → 游戏连接
- 房间码 6 位大写字母数字，去掉 `0/O/1/I`；一个房间 1 房主 + 1 客机。
- 日志一条连接一行，不打游戏内容。
- ⚠️ 自实现 WebSocket 必须有测试：握手、分片、掩码、长度 126/127、close 五条各一个用例。
  如果以后觉得自实现风险高，可以换成 `websockets` 库 —— 但会破坏「零依赖单文件」，
  本轮先按零依赖做。

### 7.3 云上部署（已完成，2026.10.19：IPv4 + `ws://` + Windows/nssm）

用户 2026.10.19 拍板：**怎么方便怎么来，直接用公网 IPv4**。
服务器是腾讯云 Windows，已有备案域名但上面跑着网站，**联机中继不占域名 / 不占 443 / 不动 IIS**。

**实测已完成**：`server/deploy.ps1` 部署成功，公网 `/health` 与 host/guest 探针通过；
具体命令、日志路径与结果见 [`route.md`](route.md) 52.1 与 `server/README.md`「本次实测」。

| 项 | 定稿 |
|---|---|
| 对外地址 | `ws://159.75.154.122:8770/ws`（实测） |
| 传输 | 明文 WebSocket；**不做 TLS、不做域名、不走 IIS** |
| 服务器监听 | `0.0.0.0:8770`（不是 127.0.0.1） |
| 安全组 | 只放行 TCP **8770**（RDP 单独限制来源） |
| 进程托管 | `nssm` 服务 `DAEEMRelay`，开机自启 / 崩溃重启 |
| 健康检查 | `http://<公网IPv4>:8770/health` |
| 房间 | 6 位码；一房 1 房主 + 1 客机；无持久化 |
| 日志 | `C:\daeem\logs\relay.{out,err}.log`，nssm 轮转 |

```powershell
nssm install DAEEMRelay "C:\Python312\python.exe" "C:\daeem\server\daeem_relay.py --host 0.0.0.0 --port 8770 --max-rooms 64"
nssm set DAEEMRelay AppDirectory  C:\daeem\server
nssm set DAEEMRelay AppStdout     C:\daeem\logs\relay.out.log
nssm set DAEEMRelay AppStderr     C:\daeem\logs\relay.err.log
nssm set DAEEMRelay AppRotateFiles 1
nssm set DAEEMRelay Start SERVICE_AUTO_START
nssm start DAEEMRelay
curl http://127.0.0.1:8770/health
```

- 客户端配置：`"relay_url": "ws://<公网IPv4>:8770/ws"`。
- `server/deploy.ps1` 幂等：备份 → 复制 → 重启服务 → `/health`；不改 IIS。
- **明文风险已知悉**：房间码 / 命令 / 快照在公网可被看见或篡改；只适合朋友内测。
- 以后如果要 `wss://`：加域名 / 反代 / 证书即可，**只改 `relay_url`**，协议 / 会话 / 逻辑不动。
- 不做自动更新、监控告警、多实例负载均衡。

### 7.4 Steam P2P（以后，不在本轮）

- 只新增 `net/steam_transport.gd`：Steam 大厅负责建房 / 加入，P2P 通道负责收发。
- 协议、会话、逻辑、视图都不改；房主权威不变。
- 需要 GodotSteam 插件与导出配置，属于**打包 / 发布**阶段的事，本轮不做。

---

## 八、文件清单

### 8.1 新增

```
net/protocol.gd
net/transport.gd
net/event_codec.gd
net/relay_transport.gd
net/host_session.gd
net/client_session.gd
net/lobby.gd
net/steam_transport.gd          ← 以后；本轮只留接口说明
view/coop_lobby.gd
view/objective_panel.gd
server/daeem_relay.py
server/relay_client.py        ← 测试 / 探针用的标准库 WebSocket 客户端
server/probe_relay.py         ← 本机 host / guest 探针
server/test_relay.py
server/run-local.ps1
server/deploy.ps1             ← 云上部署（M12.5）
server/README.md              ← 本机跑通 + IPv4 部署 + 运维
tests/fake_transport.gd
tests/test_coop_seats.gd
tests/test_snapshot_coop.gd
tests/test_protocol.gd
tests/test_session.gd
tests/test_coop_tech.gd
tests/test_coop_lobby.gd
tests/test_coop_entry.gd
tests/test_coop_game_scene.gd
tests/test_coop_objective.gd
```

### 8.2 修改

| 文件 | 改什么 |
|---|---|
| `logic/world.gd` | `is_own_seat()` / `accepts_owner()`（判据收口）；`seat_tech_effects`（按席位科技）；`refresh_after_snapshot()`；`tick()` 里按席位算科技 / 人口 / 领地事件 |
| `logic/command_processor.gd` | 严格归属校验；`by` / `faction` / `seq` 校验入口（或放在 session 层，见下） |
| `logic/level.gd` | 新增 `coop_roster()`（原序席位）；合作关目标 / 席位的装配校验 |
| `logic/upgrade.gd` | 升级 / 特化归属判断走 `is_own_seat()` |
| `logic/snapshot.gd` | 第五节那批字段 + `refresh_after_snapshot()` 的调用边界 |
| `view/input_controller.gd` | 选中 / 建造 / 招募 / 升级按 `is_own_seat()`；合作时只选自己的单位 |
| `view/game_scene3d.gd` | `start_coop()`；`_process()` 房主 / 客机分支；`_on_command()` 路由；客机应用快照与派生刷新；目标 HUD 接线 |
| `view/main.gd` | 合作大厅 → `start_coop()`；拆场景时关 session |
| `view/menu_chrome.gd` | 合作按钮撑开的内容区改成合作大厅 |
| `view/menu_secondary_panel.gd` | 支持 `with_coop_lobby` |
| `view/hud.gd` | 合作信息 / 队友状态 / 目标条 / 结束提示；命令卡不做「队友灰态」（队友本来就选不中，见 4.2） |
| `view/ui_layout.gd` | 合作面板、目标条、ping 的全部几何常量 |
| `data/config.json` | `coop` 段（文案、字号、房间码长度、快照频率、ping 间隔） |
| `docs/architecture.md` | 落地后补「状态放哪」：session / transport / 席位严格归属 |
| `docs/pitfalls.md` | 落地后补本轮实测坑 |

> ★ `view/ui_layout.gd` 仍是**唯一**写几何的地方；`logic/` 仍是纯 `RefCounted`，不碰 `Node`。
> ★ 新增文件一律用 `preload` 常量，不写 `class_name`（无头 `--script` 时全局类名表不可用）。

---

## 九、测试与验收

### 9.1 无头断言

| 套件 | 盯什么 |
|---|---|
| `test_coop_seats.gd` | 房主 / 客机两个世界：各自 `my_faction` 正确；**两端 `factions` 顺序一致（`[players[0], players[1]]`）**；`player_seats` 两个；`is_own_seat()` 只认自己；客机命令碰房主的兵被拒；资源各扣各的；共享视野；目标 defend 两个席位 |
| `test_snapshot_coop.gd` | 新增字段往返；缺字段时保持本地现状；`pres` 只写自己；`obj` 写目标；单位 / 建筑血量上限；升级 / 特化读条字段 |
| `test_protocol.gd` | 编解码往返；缺字段 / 版本不符 / 未知类型被拒而不是崩；`seq` / `by` 校验 |
| `test_session.gd` | 假 transport：客机命令上行被校验；房主快照往返；房主 `bye` 让客机收摊；客机 `bye` 房主继续；非法 `by` 丢弃 |
| `test_coop_tech.gd` | 两个玩家席位各吃各的科技：客机的粮食 / 人口 / 建筑加固不加到房主头上 |
| `test_coop_lobby.gd` | 真实中继：建房 / 加入 / 准备 / 开始按钮 / transport 交接 |
| `test_coop_entry.gd` | `test_2` 带 `coop` 标记，按下去打开合作大厅而不是单人关 |
| `test_coop_game_scene.gd` | 房主 / 客机两个 GameScene3D：客机不 tick、快照写回、命令经 host_session、暂停禁用、两边目标条 |
| `test_coop_objective.gd` | 客机只读 `obj`；目标进度 / 胜负 / 原因与房主一致；不会在本地重新 setup 后判负；**带 `for` 的合作目标在装配时被拒** |
| `server/test_relay.py` | 握手 / 分片 / 掩码 / 长度 126/127 / close 五条 + 房间转发 |
| `server/run-local.ps1` | 中继 + 房主探针 + 客机探针一条命令跑完，`RUN LOCAL OK` |
| `tests/test_relay_transport.gd` | Godot `WebSocketPeer` ↔ Python 中继：连接 / 建房 / 加入 / start / cmd / snap / close |

### 9.2 回归

- `tools/run-tests.ps1` 全量必须全绿。
- 单机路径（`_on_test_pressed`）与单人战役路径（test_1 / test_3 / 战役菜单）**行为逐位不变**。
- `test_campaign_seats.gd` / `test_outcome.gd` / `test_campaign_ai.gd` / `test_fog.gd` 是硬回归。
- 老路径 `roster` 为空时，`accepts_owner()` 仍走 `same_side`（严格同阵营），行为逐位不变。
- 三个编辑器的测试不受影响（本文不改 `data/campaigns/` 结构）。

### 9.3 手玩验收（不截屏）

1. 起中继；开两个客户端（或一个窗口 + 一个 `--headless` 探针）。
2. 房主建 `02_twin_line` 房间，拿到 6 位码；客机输码加入。
3. 双方准备 → 房主开始 → 两端进同一关。
4. 房主只能选中 / 指挥 F1；客机只能选中 / 指挥 F2；**点队友的兵选不中（严格同阵营），
   但仍然看得见**；敌方单位 / 建筑照旧可以点开查看。
5. 客机造一栋墙 / 招一个兵，房主那边能看到；房主的操作客机也能看到。
6. 两人的钱各花各的；客机的资源条不跟着房主变。
7. 迷雾：房主看到的区域客机也亮；敌方没看到的区域仍然黑。
8. 目标条跟着走；守满 120 秒双方都显示「本关守住」；把 c1 丢掉双方都显示失败与原因。
9. 客机关窗口：房主继续打，提示「队友已离开」；房主关窗口：客机回主界面，提示「房主已离开」。
10. 老路径回归：test_1 / test_3 / 战役菜单照旧能进、能打。

---

## 十、里程碑（只排顺序与依赖）

| # | 里程碑 | 目标 | 主要落点 | 验收 |
|---|---|---|---|---|
| **M12.0** | **方案** | 本文 | `docs/dev_plan_12.md` | 用户确认口径 |
| **M12.1** | **席位严格化 + 目标 UI（不联网）** | 两个本地世界各自只控自己；目标条可见 | `world.gd`、`command_processor.gd`、`upgrade.gd`、`input_controller.gd`、`objective_panel.gd` | `test_coop_seats.gd` / `test_coop_objective.gd` 全绿；单人路径逐位不变 |
| **M12.2** | **快照 + 协议 + 假连接会话** ✅ **已完成** | 快照能往返、会话能跑 | `snapshot.gd`、`net/protocol.gd`、`net/transport.gd`、`net/event_codec.gd`、`net/host_session.gd`、`net/client_session.gd` | `test_snapshot_coop.gd` / `test_protocol.gd` / `test_session.gd` / `test_coop_tech.gd` 全绿 |
| **M12.3** | **本机双进程最小闭环** ✅ **已完成** | 中继 + 两个探针，无 UI | `server/daeem_relay.py`、`server/relay_client.py`、`server/probe_relay.py`、`server/run-local.ps1`、`server/test_relay.py`、`net/relay_transport.gd`、`tests/test_relay_transport.gd` | `RUN LOCAL OK`；日志能看出建房 / 加入 / 开局 / 命令 / 快照 / 断开；RFC6455 五类边界全绿 |
| **M12.4** | **合作大厅 UI** ✅ **已完成** | 玩家能从主界面建房 / 加入 / 开局 | `net/lobby.gd`、`view/coop_lobby.gd`、`menu_chrome.gd`、`menu_secondary_panel.gd`、`start_screen.gd`、`main.gd`、`game_scene3d.gd`、`config.json` | `test_coop_lobby.gd` / `test_coop_entry.gd` / `test_coop_game_scene.gd` 全绿 |
| **M12.5** | **云上部署** ✅ **已完成（2026.10.19）** | 腾讯云 nssm + 两台机器对局 | `server/deploy.ps1`、`server/README.md`；腾讯云 Windows + nssm `DAEEMRelay`；`ws://159.75.154.122:8770/ws` | `/health` 公网可 curl；host/guest 探针 OK；首次 PC+Android 联机由用户确认成功（未逐项记录） |
| **M12.6** | **文档收口** ✅ **已完成** | 把落地口径写回文档 | `route.md` 第五十二节、`architecture.md`、`pitfalls.md` 5.73~5.76、`docs/README.md`、`server/README.md`、`mobile.md` 第 20 节；根 `README.md` **未改**（需用户明确同意） | 文档数字与实测一致；M12 套件 204 项 + relay 6 + 语法 152 全绿 |
| **M12.7** | **快照 30Hz + 联机优化** ✅ **已完成（2026.10.19）** | 20Hz → 30Hz；慢网络不堆积；客机只应用最新快照 | `data/config.json`（`snapshot_hz` / `snapshot_buffer_limit_kb`）、`net/host_session.gd`、`net/client_session.gd`、`net/transport.gd`、`net/relay_transport.gd`、`logic/snapshot.gd`、`tests/bench_snapshot.gd` | 30Hz 测量见 `route.md` 53.1；M12 套件 213 + relay 6 + 语法 159 全绿 |

**依赖关系**：M12.1 → M12.2 → M12.3 → M12.4 → M12.5；M12.6 最后。
★ M12.1 单独做，是为了先把「谁的东西归谁」在**没有网络**的情况下钉死；
网络层只搬运已经对的命令与快照 —— 这是把联机风险压到最低的排法。

---

## 十一、风险与对策

| # | 风险 | 对策 |
|---|---|---|
| 1 | **20Hz 快照没有插值** → 客机单位一顿一顿 | 第五节 5.4：`render_pos` 显示插值；断言「房主 / 单机 render_pos == pos」 |
| 2 | **快照缺字段** → 客机资源 / 目标 / 升级错 | 第五节清单 + `test_snapshot_coop.gd` 的缺字段容忍断言 |
| 3 | **把「能不能打」的盟友判据误用成「能不能指挥」** | 第四节 `accepts_owner()` 统一走严格同阵营；`test_coop_seats` 专门造「客机命令房主单位」的反例 |
| 4 | **客机世界与房主漂开** | `start` 带完整关卡数据 + 版本 / build；快照是唯一真相；ping 里带 `unit_count`，差 > 20% 时 HUD 黄字 |
| 5 | **房主 p1 中心逻辑** → 客机科技 / 人口加成不生效 | 第四节 4.4：`seat_tech_effects` + 按席位遍历；断言两个席位的产量 |
| 6 | **自实现 WebSocket 有坑** | 只做文本帧 + 小消息；五条测试；不做二进制 / 压缩扩展 |
| 7 | **快照膨胀** | 先量：`run-local.ps1` 打每秒字节数；超过阈值再上「只发变化」；本轮不提前优化 |
| 8 | **房主掉线 = 这一局结束** | 用户拍板保留；界面明确提示；不做重连 |
| 9 | **Steam P2P 以后要改协议** | transport 接口现在就分开；协议 / 会话不依赖 WebSocket |
| 10 | **Android 房间码输入 / 触屏** | 本轮只验收 PC；手机端只保证不崩；虚拟键盘与触屏布局留到打包阶段 |
| 11 | **文档与代码漂开** | 每个里程碑收口时更新 `architecture.md` / `pitfalls.md`；不把计划写成现状 |

---

## 十二、明确不做（本轮 / 本方案范围）

| 不做 | 为什么 / 什么时候回头 |
|---|---|
| 断线重连 | 用户拍板保留「不做」；房主掉线即结束 |
| 合作暂停 | 需要双方同意机制；单人暂停照旧 |
| 3 人及以上 / 观战 / 录像 | 合作固定 2 人；回放等存档那一条 |
| 匹配 / 房间列表 / 账号 | 房间码即身份 |
| 反作弊 / TLS / 鉴权 | 用户取舍；明文 `ws://`，房间码即口令 |
| Steam P2P 实装 | 以后只换 transport；需要 GodotSteam 与打包 |
| Android 逐项联机验收 | 首次 PC+Android 联机已确认；不做逐项验收，手机端仍只保证“能连、能玩” |
| 结算面板 / 关卡简报 | 只做一行结束提示；简报字段继续不读 |
| 新玩法 / 新兵种 / 新建筑 | 本文只做联机与席位，不改数值 |
| 改根目录 `README.md` | 除用户明确要求，否则不动 |
| 打包 / 导出 | 导出配置已补齐（`*.json` 包含过滤、Android `INTERNET`）；本仓库不提交导出产物，实际打包由用户侧执行 |

### 12.1 原先待确认的小项（现已全部确定）

| # | 小项 | 默认做法 |
|---|---|---|
| 1 | 合作局里单人暂停键怎么处理 | 禁用；或只暂停本地 UI，不冻世界 |
| 2 | 客机掉线后房主是否继续 | 继续（与 dev_plan_7 一致） |
| 3 | 目标条放屏幕上方还是右下 | 先放上方居中，几何进 `ui_layout.gd`，手玩后再调 |
| 4 | 云服务器端口 / 域名 | 默认 `8770`、明文 `ws://`；部署时再确认 |
| 5 | 房间码是否加密码 | 不加；6 位码即口令 |

**最终采用**：暂停禁用；客机掉线房主继续；目标条上方居中；端口 `8770` / 明文 `ws://`；
房间码不加密码。

---

## 十三、交接状态（M12 已完成）

> ✅ **M12.1 ~ M12.7 已全部完成**：公网部署已跑通（`ws://159.75.154.122:8770/ws`），
> 快照默认 30Hz 并带背压 / 客机合并，文档已收口。不要再从 M12.1 重做；
> 入口仍是 [`handoff_12.md`](handoff_12.md)。
> ★ 唯一保留的可选项是**客机视觉插值**（见 handoff 第 7 节）。

后续接手注意事项：

1. 先读 [`handoff_12.md`](handoff_12.md) + `route.md` 第五十二节 + `server/README.md`；
   不要按 `dev_plan_7` 的 AI 旧口径写。
2. 公网地址 / 服务名 / 端口：`159.75.154.122` / `DAEEMRelay` / `8770`；改地址只改
   `data/config.json` 的 `net.relay_url`（或大厅输入框），协议 / 会话 / 逻辑不动。
3. 每次改动后跑对应套件 + `tools/check-syntax.ps1`；单人路径必须逐位不变。
4. `server/deploy.ps1` 只写 ASCII；重新部署先 `-DryRun`，失败会自动回滚。
5. 断线重连、客机接管、合作暂停、TLS/IIS/443、3 人 / 观战 / 匹配仍不在范围内。
6. 不碰根 `README.md`、不改 `data/maps/*/map.json` 的既有字段语义、不改单机入口。
7. 所有新几何进 `view/ui_layout.gd`；所有新文案 / 数值进 `data/config.json`；`logic/` 不碰 `Node`。
8. 导出时保留 `export_presets.cfg` 的 `include_filter="*.json"` 与 Android
   `permissions/internet=true`；否则包体会缺地图 / 配置或手机连不上中继。

