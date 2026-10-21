# dev_plan_13 —— 水域地形 / 合作大厅改版 / 局内 UI 调整

> 状态：**已实施（2026-10-20）**。A（水域）/ B（局内 UI）/ C（合作大厅）均已完成；
> 新增/更新的测试见每节末尾与 §7。中继协议升级到 `coop-m13.1`，旧字母房间码失效。
> 参考图：`art_draft/1.png`（大厅）、`art_draft/2.png`（房间）、`art_draft/3.png`（地图选择）、`art_draft/4.png`（将领标签）。
> 工程：`dev_gd_a/daeem/`（Godot 4.7 mono）+ `dev_gd_a/tools/`（三个 Python tkinter 编辑器）。

### 实施结果速览

| 阶段 | 主要落点 | 验证 |
|---|---|---|
| A 水域 | `map_editor` 四种地形 + `~`；`map_data.gd` 的 `water` / `is_water` / 封岛跳过水域；`crowd_bridge` 同步；三套渲染器配色；campaign editor 水域不可通行 | `tools/map_editor/test_model.py`、`test_app.py`；`tools/campaign_editor/test_model.py`；`tests/test_water.gd` |
| B 局内 UI | 右侧将领标签 `view/troop_row.gd` + `squad_panel.gd`（数字 1..9/0、名字、`当前/上限`、灰线、右缘向左泛光，紧贴右边缘、泛光不改白字颜色）；左上目标栏 `view/objective_panel.gd`（`※简称` / `- 描述`，自由 `desc` + 可选 `short`）；底栏 `ui_layout.gd` 右下整组 13/12 放大、详细信息 988 宽 | `tests/test_ui.gd`、`test_coop_objective.gd` |
| C 合作大厅 | 数字房间码；`GET /rooms` 房间列表 + 刘海/刷新（独立边框面板 + 橡皮筋拖动列表）；`view/coop_lobby.gd` 三态 + 滑动动效 + 返回语义 + 收回时整体缩小；`logic/coop_catalog.gd`（coop 关卡=地图）；`net/room_directory.gd`；房主 `room_cfg` 同步 | `tests/test_coop_lobby.gd`、`test_coop_ui.gd`、`test_coop_catalog.gd`、`test_room_directory.gd`、`test_protocol.gd`、`server/test_relay.py` |

---

## 0. 已确认的决策

| 项 | 决策 |
|---|---|
| 房间码 | **纯 6 位数字 0-9**；同步改客户端协议与 Python 中继，并重新部署中继 |
| 中继地址 | **去掉大厅输入框**，一律读 `data/config.json` 的 `net.relay_url` |
| 房间列表数据 | **复用中继现有的 `GET /rooms`**（HTTP 轮询），列表上方加一条“刘海”标题栏 + 右侧刷新按钮；技术栈用 Godot 自带 `HTTPRequest`，不新增依赖 |
| 房间列表条目 | **房间码 + 状态**（等待中 / 已满 / 游戏中）；只有“等待中”可点 |
| 合作地图来源 | **一个 `mode="coop"` 关卡 = 一张合作地图**；选地图就是选该 coop 关卡，开局仍发该关卡的 `level_data` |
| 返回语义 | 2.png 返回 = 退出房间回大厅；3.png 返回 = 放弃改图回房间；3.png 只有“确认”才应用地图 |
| 目标栏 | 固定两行：`※简称` / `- 描述`；简称按目标种类（守住 = 坚守、占领 = 攻占），可用 `objectives[].short` 覆盖；**描述是自由文本，可包含进度信息**；不再画进度条 |
| 将领标签 | 第 10 个显示数字 **0**；编制 = **队长 + 附属兵**；上限 = `cfg.general_cap_at(该将领序号)`（默认 11） |
| 底栏对齐 | **把右下整组（阵营 / 命令卡 / 页签）按 13/12 等比放大到高 260、顶边抬到 820**；详细信息保持 `y=820,h=260`，宽度从 1030 缩到 988（右缘左移让位） |

### 仍未确认、但本轮按以下假设执行（可在批准时改）

1. 输入 6 位码且房间存在但“已满 / 游戏中”时，按钮显示 **“房间已满” / “对局中”并禁用**（设计图只写了“进入房间”）。
2. 房间列表 **每 2 秒自动刷新一次**，同时保留手动刷新按钮；进入 / 离开 / 创建 / 加入后立即刷新。
3. 目标描述的自由文本本轮只支持**关卡 JSON 字段** `objectives[].desc`；战役编辑器暂不新增输入框（手改 JSON 即可）。
4. 目前只有 `demo/02_twin_line` 一个 coop 关卡，因此合作地图列表现阶段只有 1 项；列表逻辑按多张图设计。
5. 右下整组的“等比放大”指**面板 / 格子的几何**按 13/12 放大；字号保持现有档位（避免 1~2px 级字号跳变，视觉上仍协调）。

---

## 1. 现状分析（与本次改动相关的部分）

### 1.1 地形

- 地图编辑器：`tools/map_editor/model.py` 的 `TERRAIN_CHARS / TERRAIN_ORDER / TERRAIN_LABELS / DEFAULT_COLORS`，`mapfile.py` 负责 layout 图例的导入导出。
- 游戏侧：`daeem/logic/map_data.gd` 是地形的唯一入口。
  - `terrain_walkable()` 只认“存在 + 不是山”；
  - `_seal_unreachable()` 会把 BFS 走不到的**非山**格改成山；
  - `is_mountain()` 只服务战争迷雾的视线；
  - `crowd/crowd_bridge.gd` 为了性能**绕开** `terrain_walkable()`，直接比较 `"mountain"`；
  - 渲染：`ground_view.gd`、`minimap.gd`、`map_preview.gd`、`palette.gd` 各自 `match` 三种地形；
  - 配色：`data/config.json` 的 `colors.*`。
- 战役编辑器也会读地图 layout：`tools/campaign_editor/model.py` 的 `_TERRAIN_BY_NAME` 与 `walkable` 集合。**不改它，水域会被当成草地**，大本营 / 单位摆放校验会失效。

### 1.2 合作大厅

- 入口：主界面右下“合作模式” → `menu_chrome.gd` 撑开面板 → `menu_secondary_panel.gd` 里放 `view/coop_lobby.gd`。
- 会话：`net/lobby.gd`；中继：`server/daeem_relay.py`；协议：`net/protocol.gd`。
- 现状 UI 是一列：中继地址、关卡下拉、房间码输入、创建 / 加入 / 准备 / 开始按钮、状态行。
- 中继已支持：任意房间码创建（仅校验字符集）、`/rooms` HTTP 列表、`room_state` 广播、`start` 转发。
- 现状限制：`ready` 只能置 true（不能取消）；`start` 要求 `ready_host && ready_guest`；房间列表没有客户端实现；房间配置（地图）没有下发机制。
- `menu_secondary_panel` 的“返回”按钮归面板所有，`coop_lobby` 目前**碰不到它**；3.png 要把返回到左上角，必须做一次按钮托管 / 委托。

### 1.3 局内 UI

- 将领列表：`view/squad_panel.gd` + `ui_layout.gd` 的 `SQUAD_RECT(1680,180,240,560)`，10 行 × 56，紧贴右边缘；每行数字 1..9/0 + 名字 + 当前/上限。
- 目标栏：`view/objective_panel.gd`，左上 `OBJECTIVE_RECT(20,16,560,96)`，`※简称` / `- 描述` 两行，无进度条。
- 详细信息：`DETAIL_RECT(400,820,988,260)`。
- 右下组：`FACTION_RECT / CARD_RECT / TABS_RECT` 都放大到 `y=820,h=260`。
- 悬停浮窗：`hover_tip.gd`，下缘 `HOVER_BOTTOM = CARD_RECT.y - 8 = 812`，宽度 = 命令卡 + 页签列（368.333）。
- 资源条：`RES_BAR_RECT(400,764,200,56)`，下缘紧贴详细信息顶边 820。

---

## 2. 改动一：新增“水域”地形

### 2.1 数据约定

| 项 | 值 |
|---|---|
| 地形 id | `water` |
| layout 图例字符 | `~` |
| 显示名 | 水域 |
| 移动 | **阻挡**（与山地一样不可通行） |
| 视线 / 战争迷雾 | **不阻挡**（只有 `mountain` 挡） |
| 建造 / 出生 / 寻路 | 不可通行 ⇒ 自动不可建造、不会作为出生点、A* 绕开 |
| 移动消耗 | 无意义（不可达）；`terrain_cost` 不改 |
| 旧地图 | 不含 `~` ⇒ 行为逐位不变 |
| 未知字符 | 仍按草地兜底（与现状一致） |

颜色新增 `colors.water`，建议 `#2e4f66`（深蓝灰，与现有暗色地形协调）；不新增 `water_edge`，避免多一套没有用到的配置。

### 2.2 地图编辑器（`tools/map_editor/`）

1. `model.py`
   - `TERRAIN_CHARS["water"] = "~"`；`CHAR_TERRAINS` 自动反查。
   - `TERRAIN_ORDER = ("grass", "forest", "mountain", "water")`；`TERRAIN_LABELS["water"] = "水域"`。
   - `DEFAULT_COLORS["water"] = "#2e4f66"`。
   - `_zone_problems()`：区划中心落在水域时加一条与“山地”同级的提醒（“游戏里单位进不去，那一格会看不出区别”）。
   - 文件头“地形只有三种”的说明改成四种，并写明水域“挡路不挡视线”。
2. `app.py`
   - `redraw()` 读 `water_rgb`，地形分支加 `water`。
   - 单格 / 框选的地形按钮已经按 `TERRAIN_ORDER` 循环，**自动多出第四颗**；只需确认侧边栏高度 / 滚动仍然正常。
   - 状态栏 / 坐标行用 `TERRAIN_LABELS`，自动显示“水域”。
3. `mapfile.py`
   - 导入 `CHAR_TERRAINS.get(ch, "grass")`、导出 `TERRAIN_CHARS.get(...)` 已经自动支持 `~`；只更新文件头图例说明与导出注释。
4. `data/config.json`
   - `colors` 段加 `"water": "#2e4f66"`。
   - 地图编辑器通过 `load_config` 读它，不写死配色。
5. 测试
   - `test_model.py`：`t_terrain_order` 改为四元组；新增“`~` 往返一致”“`fill_rect_terrain(..., "water")` 生效”断言；把原来拿 `"water"` 当非法地形的用例改成 `"lava"`。
   - `test_app.py`：单格 / 批量地形按钮集合改为四个；点“水域”后格子与文字正确。
6. README / 图例
   - `tools/map_editor/README.md` 与 `mapfile.py` / `gen_arena_map.py` 的图例说明补 `~ 水域`；把“三种地形”改成“四种”。

### 2.3 战役编辑器联动（`tools/campaign_editor/`）

不改的话，水域在战役编辑器里会显示成草地、且能被选为大本营 / 单位 / 红点 / 进攻目标。

1. `model.py`
   - `_TERRAIN_BY_NAME` 加 `"water": "~"`, `"~": "~"`。
   - 读 layout 时 `walkable` 判据从 `ch != "#"` 改为 `ch not in ("#", "~")`。
   - `point_on_mountain` 类错误文案改为“山地 / 水域”（或新增 `point_unwalkable`，保持旧 code 兼容）。
2. `app.py`
   - 地形配色表加 `"water"`。
3. `test_model.py`
   - 补一格水域 fixture，断言 `walkable_at()` 为 false、错误码正确。
4. `tools/campaign_editor/README.md` 图例补水域。

### 2.4 游戏逻辑（`daeem/logic/`）

1. `map_data.gd`
   - 新增 `const TERRAIN_WATER := "water"`；`LAYOUT_LEGEND["~"] = TERRAIN_WATER`。
   - `terrain_walkable()`：`t != TERRAIN_MOUNTAIN and t != TERRAIN_WATER`。
   - `_seal_unreachable()`：**跳过水域**，否则 BFS 走不到的水域会被改成山，进而错误地挡视线。这是本改动最容易漏的一条。
   - `rebuild_terrain_masks()`：增加 `_water_mask`；新增 `is_water()`（与 `is_forest / is_mountain` 同一条掩码口径）。
   - 文件头“三种地形”的说明改成四种，并写清“水挡路不挡视线”。
   - `_read_units` 的“落在不可通行地形”提示自然覆盖水域。
2. `crowd/crowd_bridge.gd`
   - `_build_terrain()` 的直接比较改成 `String(cells[i]) not in ["mountain", "water"]`（或抽一个 `_is_blocking_terrain()`），否则人群寻路会把水域当可走。
3. `logic/fog.gd`
   - **不改**：它只问 `is_mountain()`，水域天然不挡视线。计划里明确写一条回归测试钉住这一点。

### 2.5 渲染 / 配色

| 文件 | 改动 |
|---|---|
| `view/ground_view.gd` | `_bake()` 与 `terrain_color_at()` 加 `water -> cfg.color("water")` |
| `view/minimap.gd` | `_terrain_texture()` 加 water 分支 |
| `view/map_preview.gd` | `_build_terrain()` 加 `_c_water` |
| `view/palette.gd` | `terrain_color()` 加 water |
| `data/config.json` | `colors.water` |
| `logic/config.gd` | 不需要改：`color()` 直接读 `colors.*` |

### 2.6 测试与验收

- `python tools/map_editor/test_model.py`、`test_app.py` 全绿。
- `python tools/campaign_editor/test_model.py` 全绿。
- Godot 新增 `tests/test_water.gd`（或并入 `test_map_editor.gd` / `test_smoke.gd`）：
  1. 用 `~` 的 layout 载入地图，`terrain_at == "water"`；
  2. `terrain_walkable == false`；
  3. `is_mountain == false` ⇒ 迷雾视线不被水挡；
  4. `flood_fill_terrain` 不穿过水域；
  5. `_seal_unreachable` 后水域仍是 `water`（没被改成 mountain）；
  6. 水面格不会被 `nearest_walkable()` 选中；
  7. `rebuild_terrain_masks()` 后 `is_water` 与地形一致。
- 手工验收：地图编辑器画一条河 → 导出 → 游戏内单位绕行、视线可穿过；小地图 / 战斗缩略图显示水色。

### 2.7 风险

- **最大风险**是 `_seal_unreachable` 与 `crowd_bridge` 两处“非山即可走”的假设；计划用测试钉死。
- 战役编辑器若不改，会把水当草地；已纳入本阶段。
- 老地图无 `~`，无兼容风险；新增字符不会与现有 `B` 冲突。

---

## 3. 改动二：合作模式大厅改版

### 3.1 状态机

```
LOBBY  ──输入 6 位码 / 点房间行──►  ROOM  ──点地图预览（仅房主）──►  MAP_SELECT
   ▲                                  │                                  │
   └──────── 返回 / 退出房间 ──────────┘◄──────── 确认 / 返回放弃 ───────┘
```

- 三个状态共用同一个 `coop_lobby.gd`，内部用 `_state` 与 Tween 控制三块面板的位置。
- `LOBBY`：左 / 中席位 + 右侧大厅面板。
- `ROOM`：席位不动，大厅面板右滑出、房间配置面板左滑入。
- `MAP_SELECT`：席位整体左滑出，房间配置面板滑到左侧，地图列表面板从右侧滑入，返回按钮从右上滑到左上。
- 动效总开关关闭时直接呈现终态（沿用 `ThemeRes.animations_enabled()` 的口径）。

### 3.2 网络与协议

#### 3.2.1 房间码改为纯数字

- `net/protocol.gd`
  - `valid_room_code()` / `normalize_room_code()` 改为“6 位，全部 `0-9`”；
  - 保留 `strip_edges()`；
  - 去掉“排除 0/O/1/I”的旧说明。
- `server/daeem_relay.py`
  - `ROOM_ALPHABET = "0123456789"`；
  - `valid_room_code()` 同步；
  - `_new_code()` 仍用 `secrets.choice`；
  - 文档字符串里的示例码改成 `123456`。
- `Protocol.BUILD` / `net.build` / relay `DEFAULT_BUILD` 统一升到 `coop-m13.1`，避免新旧客户端混连。
- 旧字母码失效；中继需重新部署（用户已确认）。
- 同步改 `server/test_relay.py`、`server/probe_relay.py`、`server/run-local.ps1`、`server/README.md`、`tests/test_protocol.gd`、`tests/test_coop_lobby.gd` 里的示例码。

#### 3.2.2 准备 / 开始规则

现状：`ready` 只能置 true；`start` 要求双方 ready。新设计是“客机准备 / 主机开始”，主机不准备。

- `net/lobby.gd`
  - `ready(value: bool = true)` 发送 `{"ready": value}`；
  - `is_ready()` 改为“客机已准备”（或保留“双方”另起 `guest_ready()`，UI 只用 `guest_ready`）；
  - 新增 `leave_room()`、`send_room_config()`、`room_config_changed` 信号。
- 中继 `_ready(peer, body)`
  - 读 `body.get("ready", True)`，按角色置 `ready_host` / `ready_guest`；
  - 任一角色取消准备时，`status` 从 `ready` 退回 `full`；
  - 广播 `room_state`。
- 中继 `_start(peer, msg)`
  - 只要求 `room.guest is not None and room.ready_guest`；
  - 不再要求 `ready_host`（主机按钮本身就是“开始”）；
  - 仍只允许 host 发起。
- 客户端 UI
  - 客机：按钮 `准备` ↔ `取消准备`；
  - 主机：客机未准备时按钮禁用、文案“等待队友准备”；客机准备后变“开始”、可点；
  - 客机离开 / 取消准备：主机按钮立即回到禁用。

#### 3.2.3 房间配置（地图）同步

`start` 只带 `level_data`；地图选择必须在大厅阶段同步给客机，否则客机看不到房主选了什么。

- 新消息类型常量 `T_ROOM_CFG := "room_cfg"`（中继不解析，走现有 `_forward` 转发）。
- 主机选择地图后发送：
  ```json
  {"campaign":"demo","level":"02_twin_line","map_id":"dongzheng",
   "map_name":"东征","summary":"守住 c1 120 秒"}
  ```
- 主机在 `room_state` 首次显示 `guest=true` 时补发一次，避免客机加入前错过。
- 客机只读；收到后更新房间面板的缩略图 / 描述，并显示“由房主选择地图”。
- 客机不发送 `room_cfg`；中继转发到客机。
- 客机地图选择界面不可进入（点击预览无反应，或提示“由房主选择”）。

#### 3.2.4 退出房间

- `LOBBY` 的返回：关闭整个合作面板（沿用 `menu_secondary_panel.back_pressed`）。
- `ROOM` 的返回：
  - 主机：`leave_room()` → 中继 `_close_room`（客机收到 `bye`）→ 本地关闭 transport → 回 `LOBBY`；
  - 客机：`leave_room()` → 发送 `bye` → 本地关闭 transport → 回 `LOBBY`；
  - 回大厅后立即刷新房间列表。
- `MAP_SELECT` 的返回：只丢弃 `_pending_map`，回 `ROOM`，不碰网络。

### 3.3 房间列表（HTTP）

中继已有：

```
GET /rooms -> {"ok":true,"rooms":[{"code":"123456","host":true,"guest":false,"status":"lobby"}, ...]}
```

客户端新增 `net/room_directory.gd`（纯 RefCounted，可无头测试）：

- `http_url_from_ws(ws_url)`：
  - `ws://host:port/ws` → `http://host:port/rooms`
  - `wss://...` → `https://...`
  - 去掉 `/ws`，换成 `/rooms`；保留端口与查询串（如有）。
- `parse_rooms(text)`：解析 `ok / rooms[]`，逐项规范成
  `{code, status, joinable}`：
  - `lobby` → 等待中，`joinable=true`
  - `full` / `ready` → 已满，`joinable=false`
  - `playing` → 游戏中，`joinable=false`
  - 未知 status → 原样显示、不可点。
- `sort`：按房间码升序，稳定。

`view/coop_lobby.gd` 里：

- 一个 `HTTPRequest` 节点，同一时刻只允许一个请求；
- 进入 `LOBBY` 时立即拉一次；之后每 `coop.lobby.room_refresh_sec`（默认 2.0）拉一次；
- “刘海”右侧刷新按钮强制拉一次；
- 创建 / 加入 / 退出后立即拉一次；
- 请求失败：保留旧列表，显示“列表获取失败（可直接输码）”，不阻塞创建 / 加入；
  超时放宽到 8 秒，手机弱网不误判整页不可用。
- 列表项点击 = 把房间码填进输入框（不直接加入，避免误触）。
- 列表本体用 `view/elastic_scroll_list.gd`：支持**上下拖动**、越界有橡皮筋阻尼、松手回弹；
  外面再套一块独立的 `RoomListBox` 边框面板（后续加更多滑动效果不用改结构）。
  - 合作大厅显式打开 `set_allow_empty_drag(true)`：**没有房间时**也能拖动空列表里的提示文字，便于验证手感。

“刘海”设计：

```
┌──────────────────────────────────────────────┐
│  房间列表  12                         [刷新] │  ← 56px 高，刷新按钮离边框 12px
├──────────────────────────────────────────────┤
│  123456                          等待中      │
│  654321                          已满        │
│  112233                          游戏中      │
└──────────────────────────────────────────────┘
```

### 3.4 界面布局（1920×1080 设计空间）

统一使用 `view/coop_layout.gd` 存几何常量（与 `ui_layout.gd` 同一条思路），`coop_lobby.gd` 不写坐标字面量。
窗口比例变化时，把整组内容放在一个居中的 **1792×880 舞台**里；舞台左右留白，避免超宽屏把席位和面板拉散。

#### 1.png：大厅

```
┌──────────────────────────────────────────────────────────────┐
│                                                   [返回]      │
│  ┌────────────┐      ┌────────────┐      ┌────────────────┐  │
│  │  玩家席位   │      │  队友席位   │      │  房间列表(刘海) │  │
│  │  player    │      │  等待队友…  │      │  ...           │  │
│  │  房主       │      │            │      ├────────────────┤  │
│  └────────────┘      └────────────┘      │  房间码 [____×] │  │
│                                            ├────────────────┤  │
│                                            │  1   2   3      │  │
│                                            │  4   5   6      │  │
│                                            │  7   8   9      │  │
│                                            │  0   [进入/创建] │  │
│                                            └────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

建议常量：

| 元素 | Rect2 |
|---|---|
| 玩家席位 | `(120, 180, 360, 700)` |
| 队友席位 | `(640, 180, 360, 700)` |
| 大厅面板 | `(1372, 140, 500, 800)`（右缘与返回按钮对齐） |
| 返回按钮（右上） | `(1712, 48, 160, 80)` |

面板内部（相对大厅面板，内边距 24）：

- 刘海：`y=24, h=56`；左“房间列表 / 数量”，右“刷新”按钮 `80×36`，离刘海边框 12px。
- 列表：`y=80, h=300`，`ScrollContainer + VBox`；行高 44；空状态“暂无房间”。
- 房间码标签：`y=396`；输入框 `y=420, h=64`，清除按钮 `40×40` 贴输入框右侧内部。
- 键盘：`y=524`，4 行 × 56 高，行距 8；三列每列 142.67 宽、列距 12。
  - 第 4 行：`0` 占 1 列；动作按钮占 2 列（长条）。
- 状态行：`y=760`，13 号字。

#### 2.png：房间

```
┌──────────────────────────────────────────────────────────────┐
│                                                   [返回]      │
│  ┌────────────┐      ┌────────────┐      ┌────────────────┐  │
│  │  玩家席位   │      │  队友席位   │      │  地图缩略图     │  │
│  │  player    │      │  player    │      │  点击更换地图   │  │
│  │  房主       │      │  已准备     │      ├────────────────┤  │
│  └────────────┘      └────────────┘      │  地图描述       │  │
│                                            ├────────────────┤  │
│                                            │  准备 / 开始    │  │
│                                            └────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

- 房间面板与大厅面板同尺寸 `(1372, 140, 500, 800)`。
- 上方缩略图按钮：`24,24,452,440`；显示 `map_thumb` + 地图名 + 一行“点击更换地图”。
- 中间描述面板：`24,480,452,180`，`RichTextLabel` / `Label` 自动换行，可滚动。
- 下方动作按钮：`24,680,452,72`。
  - 客机：准备 / 取消准备；
  - 主机：等待队友准备（禁用）/ 开始。
- 席位卡片显示：名字（player）、身份（房主 / 队友）、状态（已准备 / 未准备 / 等待队友…）。
- 客机的地图预览**不置 disabled**，改用 `FillButton.set_grey()`：鼠标悬停 / 手指长按会出现灰填，
  点击也会补满灰填，但 `_open_map_select()` 对客机直接返回，所以没有任何逻辑；
  避免触摸下“灰填一半就退、之后再也点不动”的假死。

#### 3.png：地图选择

```
┌──────────────────────────────────────────────────────────────┐
│ [返回]                                                       │
│  ┌────────────┐   ┌────────────────────────────────────┐     │
│  │  地图缩略图 │   │  选择地图                          │     │
│  │            │   │  ┌────┐ ┌────┐ ┌────┐             │     │
│  ├────────────┤   │  │地图1│ │地图2│ │地图3│             │     │
│  │  地图描述   │   │  └────┘ └────┘ └────┘             │     │
│  ├────────────┤   │  ...（可滚动）                     │     │
│  │  确认       │   │                                    │     │
│  └────────────┘   └────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

- 房间面板左滑到 `(60, 140, 500, 800)`（尺寸不变，避免动画中重排子控件）。
- 地图面板从右侧滑入到 `(760, 140, 600, 800)`。
- 返回按钮滑到 `(60, 48, 160, 80)`。
- 地图卡片：3 列，每张 `170×200`；缩略图 `170×130`，名称 24 高，简介 20 高；选中描边加亮 + 淡金底。
- 左侧房间面板的预览 / 描述随卡片选择实时更新；下方按钮变“确认”；
- “确认”应用 `_pending_map` → 回 `ROOM`；“返回”丢弃 `_pending_map` → 回 `ROOM`。

### 3.5 返回按钮托管

现状：`menu_secondary_panel.gd` 创建并持有返回按钮，`coop_lobby` 无法移动它。

方案（最小改动）：

1. `menu_secondary_panel._build_content()` 在创建 `_coop_lobby` 后调用
   `_coop_lobby.attach_back_button(_back_btn)`。
2. `coop_lobby` 保存引用，在 `LOBBY / ROOM / MAP_SELECT` 之间用 Tween 改它的位置：
   - 先把锚点拍平成 `TOP_LEFT` 并记录初始矩形；
   - 目标 = `coop_layout.back_rect(state)`；
   - 动效关闭时直接设位置；
   - 退出合作面板时恢复锚点 / 位置（避免污染下一次撑开）。
3. 返回按钮的 `pressed` 仍归面板；面板的 `_on_back_pressed()` 先问大厅：
   ```gdscript
   if _coop_lobby != null and _coop_lobby.handle_back():
       return
   back_pressed.emit()
   ```
   - `LOBBY`：`handle_back()` 返回 false → 面板收起；
   - `ROOM`：退出房间、回 `LOBBY`，返回 true；
   - `MAP_SELECT`：取消改图、回 `ROOM`，返回 true。
4. 面板收起时 `coop_lobby` 的 `_exit_tree()` 负责关闭 HTTP 请求 / WebSocket / 恢复按钮。

### 3.6 交互动效

- 时长：`coop.lobby.anim_sec`，默认 0.32s；`TRANS_CUBIC / EASE_IN_OUT`。
- `LOBBY → ROOM`：
  - 大厅面板 x 从 1300 → 1920（右滑出），同时 alpha 1→0；
  - **面板右缘 = 返回按钮右缘 = 屏幕宽 − 48**；手机横屏比 1920 宽时右侧面板仍贴右，
    两个席位在左侧可用区居中（不再整页缩在左边、右侧空一大片）。
  - 房间面板 x 从 1920 → 1372，alpha 0→1；
  - 席位不动。
- `ROOM → MAP_SELECT`：
  - 玩家 / 队友席位 x -= 800，alpha → 0；
  - 房间面板 x 1372 → 60；
  - 地图面板 x 1920 → 760，alpha 0→1；
  - 返回按钮 x 1712 → 60；y 保持 48（与战役面板同距）；
  - 房间面板下方按钮在动画结束后切成“确认”（或动画中途切，二选一，计划取结束后切，避免文字在滑动中跳动）。
- 反向：逐项 Tween 回初值。
- **面板收回**：`CoopLobby` 监听 `resized`，按撑满时的尺寸把整块内容**等比缩小**
  （`pivot_offset = size/2`），而不是让绝对坐标的内容被裁成「整体往右下跑」。
- 所有 Tween 存成员变量，切状态前 `kill()`，防止连点。
- 动画期间禁用输入（面板整体 `mouse_filter = IGNORE` 或按钮 disabled），结束后恢复。

### 3.7 地图目录 / 缩略图 / 描述

新增 `logic/coop_catalog.gd`（纯 RefCounted，可测试）：

- `entries(cfg)`：
  - 复用 `CampaignLibrary.coop_campaigns(cfg)` + `load_campaign_by_option`；
  - 遍历 `campaign.levels`，只取 `lv.mode == "coop"`；
  - 每项：
    ```gdscript
    {
      "campaign": campaign_id,
      "level": level_id,
      "level_obj": lv,
      "map_id": lv.map_id,
      "map_path": "res://data/maps/<id>/map.json",
      "map_name": 地图 JSON 的 name（缺省 = map_id）,
      "desc": lv.briefing 拼接（缺省 = lv.summary()）,
    }
    ```
  - 按 `map_id` / `campaign/level` 稳定排序；同一张地图出现多个 coop 关卡时全部列出（设计图按“地图”展示，实施时可用 `map_id` 去重取第一个，计划取“全部列出”，避免隐藏关卡）。
- 地图缩略图：新增 `view/map_thumb.gd`：
  - 输入 `logic/map_data.gd` 的 `MapData`；
  - `_draw()` 画地形色块 + 区划边界，不画目标 / 大本营 / 出生点；
  - 复用 `colors.grass/grass_alt/forest/mountain/water`；
  - 1 像素/格的 `ImageTexture` 缓存，`NEAREST` 放大；
  - 尺寸由父控件决定，按地图宽高比居中。
- 地图数据缓存：`coop_catalog.gd` 内用 `Dictionary` 按路径缓存 `MapData`，避免每次刷新列表都重新解析 JSON / 做连通性修正。
- 地图描述：`lv.briefing` 是多行数组，界面按行拼接；空则用 `lv.summary()`。

### 3.8 错误与边界

| 场景 | 行为 |
|---|---|
| `/rooms` 请求失败 | 保留旧列表，刘海右侧显示“列表获取失败”；创建 / 加入仍可用 |
| 输入不足 6 位 | 动作按钮禁用、置灰，**不显示文字** |
| 6 位、房间存在且等待中 | 按钮“加入房间”，可点 |
| 6 位、房间存在但已满 / 游戏中 | 按钮“房间已满” / “对局中”，禁用（按 0 节假设） |
| 6 位、房间不存在 | 按钮“创建房间”，可点 |
| 创建时码已被占用 | 中继 `code_taken` → 刷新列表 → 按“房间存在”状态重算按钮 → 提示 |
| 加入时房间已消失 | 中继 `no_room` → 刷新列表 → 提示“房间不存在，列表已刷新” |
| 客机中途退出 | 中继清空 guest，房主收到 `room_state`，按钮回“等待队友准备” |
| 房主退出 | 中继关房，客机收到 `bye`，回大厅并提示“房主已离开” |
| 连接断开 | 回大厅、清房间状态、显示“连接已断开”，刷新按钮可重连 |
| 服务端 build 不匹配 | 明确显示“服务端版本不匹配（需部署 coop-m13.1）”，不被“连接已断开”覆盖 |
| 房间列表为空 | 显示“暂无房间，输入房间码创建” |
| 未选中任何 coop 地图 | 房间面板显示“无可用合作地图”，开始按钮禁用 |

### 3.9 测试

新增 / 修改：

1. `tests/test_coop_lobby.gd`（真实中继）
   - 数字房间码 `123456`；
   - 房主创建 → 客机加入；
   - 客机准备 / 取消准备 → `room_state` 的 `ready_guest` 正确；
   - 客机准备后房主“开始”可用；**房主自己不需要准备**；
   - 房主发 `room_cfg`，客机收到并更新地图；
   - 客机退出 → 房主回等待；房主退出 → 客机收到 `bye`。
2. `tests/test_coop_ui.gd`（无网络）
   - 状态机 `LOBBY → ROOM → MAP_SELECT`；
   - 房间码键盘：点 1~9 / 0、清除、不足 6 位禁用；
   - 按钮文案三态：进入 / 创建 / 房间已满；
   - 房间列表状态映射与“只有等待中可点”；
   - 返回语义：ROOM 回 LOBBY、MAP 回 ROOM 且不应用；
   - 动效关闭时直接终态。
3. `tests/test_room_directory.gd`（纯函数）
   - ws→http 转换（含 wss / 端口 / 查询串）；
   - 解析 `lobby/full/ready/playing/未知`；
   - 非法 JSON / 缺字段不崩。
4. `tests/test_protocol.gd`
   - `valid_room_code("123456") == true`；
   - 字母 / 长度不对 / 空 → false；
   - `normalize_room_code`。
5. `server/test_relay.py`
   - 数字码创建 / 加入；
   - `ready {ready:false}` 取消；
   - `start` 只要求客机 ready；
   - `/rooms` 状态。
6. `tests/test_coop_entry.gd`
   - 新大厅的节点名：`RoomList` / `CodeEdit` / `ActionBtn` / `SelfSeat` / `MateSeat` / `RoomPanel` / `MapPanel`；
   - 旧的 `CreateBtn` / `JoinBtn` 断言删除或改为新节点。

---

## 4. 改动三：局内 UI

### 4.1 将领列表移到右侧（参考 4.png）

#### 几何

| 项 | 旧 | 新 |
|---|---|---|
| `SQUAD_RECT` | `(0,40,120,600)` | `(1680,180,240,560)` |
| `SQUAD_ROW_H` | 60 | 56 |
| 贴边 | 左 | 右（`anchor_right = true`，右缘 = 1896，留 24px） |
| 起始 y | 40 | 180（避开右上角 `SETTINGS_RECT(1840,0,80,160)`） |
| 槽位数 | 10 | 10 |

#### 单行结构（4.png 的映射）

```
┌──────────────────────────────────────────────┐
│  将领名字                        ┌────┐  │  │
│  7/11                            │ 1  │  │  │
│                                  └────┘  │  │
└──────────────────────────────────────────────┘
   ↑名字/编制                ↑灰色分隔线 ↑数字块 ↑最右竖线（泛光起点）
```

- 从右到左：
  1. 最右竖线（2px，金色 / 选中更亮）= 泛光起点；
  2. 数字块（44×44，深底 + 细边，数字 1~9 / 第 10 个为 0，字号 20）；
  3. 灰色竖分隔线（1~2px，`text_faint` 半透明）；
  4. 左侧文本区：第一行将领名字（14 号），第二行编制 `当前/上限`（12 号、暗色）。
- 行背景：默认极淡深色；悬停 / 选中时金色填充**从最右竖线向左**推进。
- 空槽：数字仍显示，名字“…” / 编制“--/--”，整体 alpha 降低；点击无反应。
- 选中态：泛光保持满格 + 最右竖线加亮；悬停态：临时泛光，移开退回去。

#### 实现

- 新增 `view/troop_row.gd`（`extends Button`，无原生 text）：
  - `_draw()` 画行底、右竖线、数字块、分隔线、名字、编制；
  - 自绘泛光（金色渐变 alpha），Tween `glow: 0→1`（悬停 / 选中）与 `1→0`；
  - 文本颜色**保持暖白**，不随泛光变深色（用户 2026.10.20 第二轮明确要求）；
  - 保留 `Button` 的 `pressed` / `mouse_entered` / `mouse_exited`，测试仍可直接 `pressed.emit()`。
- `view/squad_panel.gd` 重写：
  - 10 个 `TroopRow`，不再用 `Button.text`；
  - `refresh()` 设置 `number / name / formation / selected`；
  - 编制上限：`cfg.general_cap_at(leader.general_index)`；`general_index < 0` 时用 `UiLayoutRes.UNIT_CAP`；`cap = maxi(cap, team.size())` 防止显示“7/5”；
  - 保留 `slot_count / slot_text / slot_filled / slot_units / slot_button / slot_active` 给测试；
  - 去掉整块半透明底板（或改成极淡的行底板），避免右侧多一块大黑条。
- `ui_layout.gd` 增加行内常量：
  - `SQUAD_NUM_SIZE = 44`
  - `SQUAD_DIVIDER_X = 178`
  - `SQUAD_TEXT_X = 8`
  - `SQUAD_NAME_W = 164`
  - `SQUAD_NUM_X = 186`
  - `SQUAD_EDGE_X = 238`
- 兼容：`point_hits_any` / `interactive_rects` 用 `squad_slot_rect(i)`，自动跟着右移；右侧边缘滚屏会被列表拦住（与旧左侧行为对称）。

#### 测试

- `test_ui.gd`：
  - `SQUAD_RECT` 宽 240、位置贴右、10×56；
  - 第 1 槽名字 = 将领名、编制 = `队伍人数/上限`；
  - 第 10 槽数字显示 0；
  - 空槽 `slot_filled == false`；
  - 点行只选中、镜头不动（原断言保留）；
  - 右缘 / 分隔线 / 数字块的几何断言（可量 `TroopRow` 的局部矩形）。
- `test_ui` 里原先按 120 宽量文本的断言改为 240 宽。

### 4.2 目标栏移到左上角（两行）

#### 布局

| 项 | 值 |
|---|---|
| `OBJECTIVE_RECT` | `(20, 16, 560, 自动高度)`，贴左、贴上 |
| 标题 | `※` + 目标简称（守住 = `坚守`、占领 = `攻占`；`objectives[].short` 可覆盖），16 号，金色 |
| 描述 | `- <desc>`，14 号，暖白；自动换行，最大宽 560 |
| 背景 | 半透明深色 + 左侧 3px 金色竖条（保留现有“目标”辨识度） |
| 进度条 | **删除** |
| 交互 | `mouse_filter = IGNORE`，不进 `interactive_rects` |

#### 文案

- 第二行 = `- ` + 描述。
- 描述来源优先级：
  1. `objectives[].desc`（关卡 JSON 新增字段，自由文本）；
  2. 缺省 = `level.objective_label(fid)` + 进度：
     - `hold_zone` 运行中：`守住 c1（已守 32/120 秒）`
     - `hold_zone` 胜利：`守住 c1（已守住）`
     - `hold_zone` 失败：`守住 c1（本关失守）`
     - `capture_zone`：`占领 c1（等待占领 / 已占领）`
- 自由描述支持占位符（可选）：
  - `{held}` 已守秒数、`{sec}` 目标秒数、`{zone}` 区划名、`{state}` 状态。
  - 若作者写了 `desc`，界面**原样使用**；只有写了占位符才替换，不自动追加进度（“描述中可以有进度信息”由作者决定）。
- 胜负状态：在描述后追加 `（本关守住！）` / `（本关失守：原因）`，颜色切金 / 红。

#### 实现

- `view/objective_panel.gd` 改为 `Panel` + `VBoxContainer`：
  - `_title: Label`、`_desc: Label`；
  - `sync()` 更新文本、颜色、可见性，并 `reset_size()` / 按内容算高度；
  - 不再 `_draw()` 进度条；
  - 保留 `title_text()` / `desc_text()` / `progress_text()` 查询接口给测试（`progress_text` 可保留并返回进度串，但不再画）。
- `logic/level.gd`
  - `_read_objectives()` 增加 `"desc": String(d.get("desc","")).strip_edges()`；
  - 新增 `objective_desc(fid, state)`（或只提供字段，拼装放视图层；计划放 `level.gd`，保证“文案只有一个来源”）。
- `tools/campaign_editor/model.py`
  - `_load_objectives()` / `_objective_to_dict()` **原样保留 `desc` 字段**（本轮不加输入框，但保存一次不能把作者手写的描述丢掉）；
  - `test_model.py` 增加一条“带 desc 的关卡往返一致”断言。
- `data/config.json` 的 `coop.objective` 增加：
  - `title_prefix: "※"`、`hold_short: "坚守"`、`capture_short: "攻占"`、`desc_prefix: "- "`
  - `desc_prefix: "- "`
  - `auto_hold: "守住 %s（已守 %d/%d 秒）"` 等兜底格式（可选）。
- 手机端 FPS 读数目前在 `(6,2)`，会与左上目标重叠：
  - 目标可见时，把 `PerfReadout` 下移到目标栏底边 + 8；
  - 目标不可见时恢复 `(6,2)`；只在手机端生效。

#### 测试

- `test_ui.gd` / `test_coop_objective.gd`：
  - 目标可见时位置贴左上（`position.x < 100`、`position.y < 100`）；
  - 第一行 “※” + 简称；
  - 第二行以“- ”开头，包含区划名与进度（默认描述）；
  - 自定义 `desc` 原样显示、占位符替换；
  - 不再有进度条（或 `progress_ratio` 仍可查询但不画）；
  - 目标不可见时整块隐藏；
  - 手机 `PerfReadout` 不与目标重叠。

### 4.3 详细信息栏与右下组平齐

用户选择（已修订）：**保留详细信息 `y=820,h=260`，把右下整组按 13/12 等比放大到高 260、顶边 820；同时把详细信息宽度 1030 → 988，右缘左移让位。**

#### 几何

放大系数 `k = 260 / 240 = 13 / 12 ≈ 1.08333`，以**右下角**为锚点等比放大：

| 常量 | 旧 | 新 |
|---|---|---|
| `BAR_TOP` / `BAR_H` | 840 / 240 | **820 / 260** |
| `FACTION_RECT` | `(1430,840,150,240)` | `(1389.1667,820,162.5,260)` |
| `CARD_RECT` | `(1580,840,240,240)` | `(1551.6667,820,260,260)` |
| `TABS_RECT` | `(1820,840,100,240)` | `(1811.6667,820,108.3333,260)` |
| `DETAIL_RECT` | `(400,820,1030,260)` | `(400,820,988,260)` |
| `DETAIL_CONTENT_H` | 240 | 240（不变） |
| `DETAIL_LEFT_W` | 350 | 350（不变） |
| `DETAIL_RIGHT_W` | 645 | **603**（= 968 − 350 − 15） |
| `DETAIL_BODY_W` | 641 | **599**（= 603 − 4） |
| `DETAIL_BODY_COL2_W` | 417 | **375**（= 599 − 216 − 8） |
| `QUEUE_X` | 328 | **286**（= 599 − 313） |
| `UNIT_NAME_W` | 236 | **194**（右缘让开招募队列） |
| `DETAIL_BODY_H` / `NOTICE_Y` / `DETAIL_LEFT_H` | 116 / 220 / 220 | 不变（面板高度没变） |
| `RES_BAR_RECT` | `(400,764,200,56)` | 不变（下缘仍贴 820） |
| `HOVER_BOTTOM` | 832 | **812**（= 820 − 8） |
| `HOVER_W` | 340 | **368.3333**（= 1920 − 1551.6667） |

- 放大后右下组左缘 = `1389.1667`；详细信息右缘 = `400 + 988 = 1388`，留约 **1.17px** 缝，不重叠。
- 命令卡 / 科技九格每格 = `260 / 3 ≈ 86.6667`；页签列 3 颗时每颗 `≈86.6667`，2 颗时 `130`，1 颗时 `260`（公式不变）。
- 阵营占位面板变宽变高；文字仍居中，字号保持 `FS_TITLE`。
- 详细信息左缘仍贴小地图右缘（x=400），只从右侧缩短；左栏 350 / 中缝 15 不变，缩掉的 42px 全部从右栏扣。
- `detail_panel.gd` 里所有按 `DETAIL_RIGHT_W` 推算的宽度会跟着变；写死的 `UNIT_NAME_W` / `QUEUE_X` / `DETAIL_BODY_W` / `DETAIL_BODY_COL2_W` 要按上表重算。
- 不再需要“区划详情自动缩小字号”这条取舍；240 高的正文容量与现在一致。

#### 悬停浮窗

现状：`HOVER_BOTTOM = CARD_RECT.y - HOVER_GAP = 832`，宽度 = 命令卡 + 页签列（340）。

- 统一为 `HOVER_BOTTOM = BAR_TOP - HOVER_GAP`（`BAR_TOP = 820`）⇒ **812**；这样浮窗随底栏顶边上移 20px。
- 宽度 `HOVER_W = DESIGN_W - CARD_RECT.x` ⇒ **368.3333**（命令卡左缘从 1580 左移到 1551.6667）。
- 增加断言：浮窗矩形不得与 `DETAIL_RECT` / `TABS_RECT` 相交；浮窗下缘与底栏顶边保持 8px。
- 这样“悬停页签栏的浮窗信息”既跟着放大后的命令卡加宽，也整体上移，不会压住详细信息。

#### 测试

- `test_ui.gd`：
  - 四块底栏面板顶边都等于 **820**、底边都等于 1080；
  - `DETAIL_RECT.size.y == 260`、`DETAIL_CONTENT_H == 240`；
  - 右下组尺寸 = 旧尺寸 × 13/12（允许 0.01 误差）；
  - `DETAIL_RECT` 右缘 < `FACTION_RECT` 左缘（不重叠）；
  - 资源条下缘 == 820；
  - 区划详情 7 行文本仍在面板内（`body_font_size()` 允许保持 13）；
  - 悬停浮窗下缘 812、宽 368.3333、不与详细信息 / 页签相交；
  - 截图对比（可选）：`shots/` 新图，确认视觉上顶边齐平、右组更饱满。

---

## 5. 文件改动清单

### 5.1 水域

| 文件 | 改动 |
|---|---|
| `daeem/logic/map_data.gd` | `TERRAIN_WATER`、图例 `~`、walkable、seal 跳过、water mask、`is_water`、注释 |
| `daeem/logic/crowd/crowd_bridge.gd` | 阻挡表加 water |
| `daeem/view/ground_view.gd` | 水色 |
| `daeem/view/minimap.gd` | 水色 |
| `daeem/view/map_preview.gd` | 水色 |
| `daeem/view/palette.gd` | 水色 |
| `daeem/data/config.json` | `colors.water` |
| `tools/map_editor/model.py` | 地形表 / 标签 / 默认色 / 校验 |
| `tools/map_editor/app.py` | 绘制水色 |
| `tools/map_editor/mapfile.py` | 图例注释 |
| `tools/map_editor/README.md` | 四地形说明 |
| `tools/map_editor/test_model.py` / `test_app.py` | 断言更新 + 水域用例 |
| `tools/campaign_editor/model.py` | `_TERRAIN_BY_NAME`、walkable、错误文案 |
| `tools/campaign_editor/app.py` | 水色 |
| `tools/campaign_editor/test_model.py` | 水域 fixture |
| `daeem/tests/test_water.gd`（新） | 见 2.6 |

### 5.2 合作大厅

| 文件 | 改动 |
|---|---|
| `daeem/net/protocol.gd` | 数字房间码、`T_ROOM_CFG`、BUILD |
| `daeem/net/lobby.gd` | 准备开关、离开房间、房间配置收发、房间列表无关 |
| `daeem/net/room_directory.gd`（新） | ws→http、房间列表解析 |
| `daeem/view/coop_lobby.gd` | 重写三状态 UI / 键盘 / 列表 / 动效 |
| `daeem/view/coop_layout.gd`（新） | 大厅几何常量 |
| `daeem/view/troop_seat.gd`（新） | 席位卡片 |
| `daeem/view/coop_map_card.gd`（新） | 地图列表卡片 |
| `daeem/view/map_thumb.gd`（新） | 地图缩略图绘制 |
| `daeem/logic/coop_catalog.gd`（新） | coop 关卡 / 地图目录 |
| `daeem/view/menu_secondary_panel.gd` | 托管返回按钮、`handle_back()` 委托 |
| `daeem/data/config.json` | `net.build`、`coop.lobby.*`、`coop.map.*` 文案 / 时长 |
| `daeem/server/daeem_relay.py` | 数字码、ready 开关、start 条件、BUILD |
| `daeem/server/test_relay.py` / `probe_relay.py` / `run-local.ps1` / `deploy.ps1` / `README.md` | 数字码 / 新规则 / BUILD 默认值 |
| `daeem/tests/test_protocol.gd` | 数字码 |
| `daeem/tests/test_coop_lobby.gd` | 新流程 |
| `daeem/tests/test_coop_entry.gd` | 新节点名 |
| `daeem/tests/test_coop_ui.gd`（新） | 无网络 UI 状态机 |
| `daeem/tests/test_room_directory.gd`（新） | URL / 解析 |
| `docs/dev_plan_12.md` / `docs/architecture.md` | 更新“不做房间列表 / 房间码字母”的旧口径 |

### 5.3 局内 UI

| 文件 | 改动 |
|---|---|
| `daeem/view/ui_layout.gd` | `SQUAD_RECT`、右下组矩形 / 底栏常量、`DETAIL_RECT` 宽度、`HOVER_W/HOVER_BOTTOM`、行内常量 |
| `daeem/view/detail_panel.gd` | 右栏宽度相关常量（`UNIT_NAME_W / QUEUE_X / 正文宽度`）随 603 重算 |
| `daeem/view/squad_panel.gd` | 重写为右侧标签 |
| `daeem/view/troop_row.gd`（新） | 单行绘制 / 泛光 |
| `daeem/view/objective_panel.gd` | 左上两行、去进度条 |
| `daeem/logic/level.gd` | `objectives[].desc` 解析 / 文案 |
| `tools/campaign_editor/model.py` | 目标 `desc` 字段往返保留（不加输入框） |
| `tools/campaign_editor/test_model.py` | `desc` 往返断言 |
| `daeem/view/detail_panel.gd` | 注释、依赖常量、自动缩字验证 |
| `daeem/view/hover_tip.gd` | 以 `BAR_TOP` 为基准 |
| `daeem/data/config.json` | `coop.objective.title/desc_prefix`、可能的兜底格式 |
| `daeem/tests/test_ui.gd` | 大量几何 / 文案断言更新 |
| `daeem/tests/test_coop_objective.gd` | 两行目标断言 |
| `daeem/tests/test_view.gd` / `test_view3d.gd` | 若引用旧 squad / detail 尺寸则更新 |

---

## 6. 实施顺序（建议 3 个独立提交）

### 阶段 A：水域地形（低风险，先做）

1. 地图编辑器 + 配置颜色 + 编辑器测试；
2. 战役编辑器联动；
3. 游戏 `map_data` + `crowd_bridge` + 渲染；
4. Godot `test_water` / 现有测试回归；
5. 文档图例。

验收：地图编辑器能画水；游戏内水挡路不挡视线；小地图 / 缩略图显示水色；旧图行为不变。

### 阶段 B：局内 UI

1. `ui_layout` 常量与测试同步；
2. `TroopRow` + `SquadPanel`；
3. `ObjectivePanel` + `level.desc`；
4. 右下组等比放大 + 详细信息横向缩窄 + 资源条 / 悬停浮窗几何；
5. 截图与测试。

验收：右侧 10 个将领标签、泛光方向正确；左上两行目标；底栏四块顶边齐平；区划详情不溢出。

### 阶段 C：合作大厅（最大，最后做）

1. 中继：数字码 / ready 开关 / start 条件 / BUILD；
2. `protocol` / `lobby` / `room_directory` + 单元测试；
3. `coop_catalog` / `map_thumb` / `coop_layout`；
4. `coop_lobby` 三状态 UI + 动效 + 返回托管；
5. 房间列表 HTTP + 刷新；
6. 集成测试（真实中继）与手动双端验收；
7. 部署中继 + 更新 `net.relay_url` / `net.build`。

验收：双端都显示房间列表；输 6 位数字进房 / 建房；准备 / 开始；房主改图客机同步；2.png / 3.png 的滑动与返回语义正确。

---

## 7. 总验收清单

- [x] 地图编辑器地形栏出现“水域”，可单格 / 框选刷；导出 `~`、重新导入一致。
- [x] 战役编辑器不再把水域当草地（大本营 / 单位 / 红点 / 进攻目标校验会拦）。
- [x] 游戏内水域不可通行、不挡视线、不可建造；孤岛修正不会把水改成山。
- [x] 旧地图（无 `~`）加载行为与现在逐位一致。
- [x] 合作大厅：1.png / 2.png / 3.png 三态布局与动效；返回语义正确。
- [x] 房间码纯 6 位数字；键盘 1~9/0；清除按钮；按钮三态。
- [x] 房间列表“刘海”+ 刷新；每项码 + 状态；只有等待中可点。
- [x] 客机准备 / 取消；主机开始；主机无需准备。
- [x] 房主选图 → 客机同步；确认 / 放弃语义正确。
- [x] 右侧将领标签：数字 1~9/0、名字、当前/上限、右缘泛光向左。
- [x] 左上目标：`※简称` / `- 描述`；描述可自由写、可含进度；无进度条。
- [x] 详细信息与右下组顶边齐平（820）；右下组按 13/12 放大；详细信息宽度 988；资源条紧贴；悬停浮窗位置正确。
- [x] 全部 Godot / Python / 中继测试通过；双端联机由 `test_coop_lobby` + `server/run-local.ps1` 自动化验收。

---

## 8. 风险与暂不做

### 风险

1. **水域与视线**：`_seal_unreachable` 若不跳过水，会把水改成山，直接违反“不挡视线”；已列为必测项。
2. **房间列表 HTTP**：部署在反向代理后 `/rooms` 可能不可达；失败时只降级列表，不影响创建 / 加入。若实际不可用，再切到 WS `list_rooms`（需改中继）。
3. **中继部署**：数字房间码与 BUILD 升级要求服务端同步更新；旧客户端会被 build 拒绝。
4. **大厅动效**：返回按钮归 `menu_secondary_panel` 所有，锚点拍平 / 恢复若处理不好，会影响下一次撑开；计划用“记录初始矩形 + 退出恢复”并加测试。
5. **右下组放大 / 详细信息缩窄**：命令卡 / 科技九格 / 页签 / 阵营面板都按 13/12 变大，详细信息右栏从 645 缩到 603，长文案会更早换行或触发缩字；需用 `test_ui` + 截图确认没有重叠、没有文字溢出。
6. **右侧将领列表与设置按钮**：列表从 y=180 开始避开设置按钮；若以后设置按钮变高，需要再调。
7. **coop 地图只有 1 张**：地图列表逻辑按多张设计，但本轮只能验收 1 项；新增第 2 个 coop 关卡即可验证多项布局。

### 本轮不做

- 不做 3 人以上房间、匹配、账号、观战、断线重连。
- 不做房间密码、房间列表分页 / 搜索。
- 不做合作地图的独立 `coop:true` 地图目录（按“coop 关卡 = 地图”）。
- 不做战役编辑器的目标描述输入框（只支持 JSON 字段）。
- 不改水域的移动消耗 / 桥梁 / 渡河机制。
- 不改将领列表的底层队伍逻辑（仍用 `world.group_of`）。

---

## 9. 需要批准的点

请确认：

1. 是否按本文三个阶段实施（A 水域 → B 局内 UI → C 合作大厅）。
2. 0 节“仍未确认的假设”里，是否有需要改的（尤其“房间已满”按钮文案、2 秒自动刷新、目标描述只支持 JSON）。
3. 是否接受中继重新部署与 BUILD 升级（数字房间码的必要条件）。
4. 是否接受右下组按 13/12 放大到 260、详细信息宽度 1030 → 988（右缘左移约 42px）。

批准后我再开始改代码，并按阶段提交、逐项跑测试。
