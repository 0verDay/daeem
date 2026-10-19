# DAEEM 双人合作 · 交接文档（M12）

> 交接时间：2026.10.19
> 适用对象：**下一个接手 M12 的 AI / 开发者**
> 当前结论：**M12.1 ~ M12.7 已全部完成；公网部署已跑通（`ws://159.75.154.122:8770/ws`）；
> 快照默认 30Hz，并加了背压 / 客机合并 / apply 索引优化；文档已收口。
> 唯一保留的可选项是客机视觉插值。**
>
> 本文是执行入口。`dev_plan_12.md` 是方案与背景，`route.md` 第五十~五十三节是已落地记录，
> 两者冲突时**以本文和当前代码为准**。

---

## 0. 先看这三句话

1. **不要重做 M12.1 ~ M12.7。** 合作大厅、房主/客机接线、真实中继、目标条、公网部署、文档收口、
   30Hz 快照与联机优化都已完成。
2. **公网链路已跑通**：腾讯云 Windows + nssm `DAEEMRelay`，`ws://159.75.154.122:8770/ws`；
   公网 `/health` 与 host/guest 探针通过；首次 PC+Android 联机由用户确认成功（未逐项记录）。
   快照默认 **30Hz**，带发送端背压 + 客机合并；见 `route.md` 第五十三节。
3. **没有必须做的下一步**。唯一可选项是**客机视觉插值**（第 7 节）；断线重连 / 客机接管 /
   暂停 / TLS / IIS / 打包 / commit 仍按用户拍板的边界不做。

---

## 1. 当前状态（已验收）

| 里程碑 | 状态 | 关键落点 |
|---|---|---|
| M12.1 席位判据 + 目标条 | ✅ 完成 | `logic/world.gd`、`logic/command_processor.gd`、`logic/upgrade.gd`、`view/objective_panel.gd`、`view/hud.gd` |
| M12.2 快照 + 协议 + 假连接会话 | ✅ 完成 | `logic/snapshot.gd`、`net/protocol.gd`、`net/transport.gd`、`net/event_codec.gd`、`net/host_session.gd`、`net/client_session.gd` |
| M12.3 真实中继 + 本机双进程 | ✅ 完成 | `server/daeem_relay.py`、`server/relay_client.py`、`server/probe_relay.py`、`server/run-local.ps1`、`net/relay_transport.gd` |
| M12.4 合作大厅 + 游戏内接线 | ✅ 完成 | `net/lobby.gd`、`view/coop_lobby.gd`、`view/menu_secondary_panel.gd`、`view/menu_chrome.gd`、`view/start_screen.gd`、`view/main.gd`、`view/game_scene3d.gd` |
| M12.5 公网部署 + 真机对局 | ✅ 完成（2026.10.19） | `server/deploy.ps1`、`server/README.md`；腾讯云 Windows + nssm `DAEEMRelay`；`ws://159.75.154.122:8770/ws`；公网 `/health` + host/guest 探针通过；首次 PC+Android 联机由用户确认成功（未逐项记录） |
| M12.6 文档收口 | ✅ 完成 | `route.md` 第五十二节、`architecture.md`、`pitfalls.md` 5.73~5.76、`docs/README.md`、`server/README.md`、`mobile.md` 第 20 节；根 `README.md` **未改**（需用户明确同意） |
| M12.7 快照 30Hz + 联机优化 | ✅ 完成（2026.10.19） | `data/config.json`（`snapshot_hz=30` / `snapshot_buffer_limit_kb=1024`）、`net/host_session.gd`（配置 + 背压）、`net/client_session.gd`（合并）、`net/transport.gd` / `net/relay_transport.gd`（`buffered_amount`）、`logic/snapshot.gd`（id 索引 / 跳过未移动 `sync_tile`）、`tests/bench_snapshot.gd` | 30Hz 测量见 `route.md` 53.1；M12 套件 **213** 项、relay 6、语法 159 全绿 |

### 1.1 已验收的自动化数字

| 套件 | 项数 |
|---|---|
| `test_coop_seats.gd` | 41 |
| `test_coop_objective.gd` | 26 |
| `test_snapshot_coop.gd` | 29 |
| `test_protocol.gd` | 19 |
| `test_session.gd` | 33 |
| `test_coop_tech.gd` | 13 |
| `test_relay_transport.gd` | 14 |
| `test_coop_lobby.gd` | 12 |
| `test_coop_entry.gd` | 8 |
| `test_coop_game_scene.gd` | 18 |
| `server/test_relay.py` | 6 |
| `server/run-local.ps1` | `RUN LOCAL OK` |
| `check-syntax.ps1` | **159 个文件 ALL OK** |
| `tests/bench_snapshot.gd` | 30Hz 体积 / 时序数字（量尺，不进 run-tests） |

回归（最近一次实测）：

- `test_start_flow` 130
- `test_campaign_menu` 116
- `test_ui` 1148
- `test_coop_objective` 26
- 更早的 `test_logic` 280 / `test_tech` 116 / `test_upgrade` 221 / `test_campaign_seats` 72 /
  `test_outcome` 71 / `test_ai` 54 也全绿。

> ⚠️ `test_coop_game_scene` 退出时可能打印 5 个 ObjectDB leak + 2 个 resource 警告；
> 退出码是 0，属于测试退出时的旧对象未清，不是产品失败。
> `test_coop_entry` / `test_coop_lobby` 可能打印 `Nodes with non-equal opposite anchors`
> 警告，来自既有的 `menu_secondary_panel.attach()`，不影响断言。

**本次 M12.5 / M12.6 / M12.7 收尾复核（2026.10.19）**：上表 10 个 coop 套件合计 **213 项**全绿，
`server/test_relay.py` **6 项** OK，`check-syntax.ps1` **159 个文件 ALL OK**。
公网 `http://159.75.154.122:8770/health` 返回 `ok:true` / `build:coop-m12.2`；
公网 host/guest 探针完成 `hello → create_room → join → ready → start → cmd → snap → bye`，
两端 `PROBE ... OK`，退出后 `/rooms` 为空。30Hz 基准数字见 `route.md` 第五十三节。

---

## 2. 环境与固定命令

本机（当前）路径：

```text
工程根：C:\Users\yy197\Documents\GitHub\daeem
Godot： C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe
Python：C:\Users\yy197\AppData\Local\Programs\Python\Python314\python.exe
```

Python 只有标准库；**没有** `websockets` / `aiohttp` / `pytest`。中继和探针必须保持零第三方依赖。

所有 Godot 命令都在 `dev_gd_a/daeem` 下跑：

```powershell
cd dev_gd_a\daeem

# 语法
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1

# 本机中继 + 房主/客机探针
powershell -ExecutionPolicy Bypass -File server\run-local.ps1

# Python 中继测试
python server\test_relay.py

# 单测（示例）
& $godot --headless --path . --script res://tests/test_coop_lobby.gd
```

`run-local.ps1` 默认起 `127.0.0.1:8770`，日志在 `server/logs/`（已被 `server/.gitignore` 忽略）。

---

## 3. 先跑一遍基线（接手后前 15 分钟）

按顺序跑，全绿再改代码：

```powershell
cd dev_gd_a\daeem

python server\test_relay.py
powershell -ExecutionPolicy Bypass -File server\run-local.ps1
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1

$godot = "C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe"
& $godot --headless --path . --script res://tests/test_coop_lobby.gd
& $godot --headless --path . --script res://tests/test_coop_entry.gd
& $godot --headless --path . --script res://tests/test_coop_game_scene.gd
& $godot --headless --path . --script res://tests/test_start_flow.gd
```

预期：

- `server/test_relay.py`：`Ran 6 tests ... OK`
- `run-local.ps1`：`PROBE host OK`、`PROBE guest OK`、`RUN LOCAL OK`
- `check-syntax.ps1`：`ALL OK: 152 file(s) parse and compile`
- 三个合作套件：12 / 8 / 18 项，失败 0
- `test_start_flow`：130 项，失败 0

如果 Python 不在 PATH，`test_coop_lobby` / `test_relay_transport` 会 SKIP；这时不能把 SKIP 当作通过。

---

## 4. 架构与一次对局的真实流程

### 4.1 拓扑

```text
房主 Godot ──(WebSocket ws://)──> Python 哑中继 <──(WebSocket ws://)── 客机 Godot
   │                                                                    │
   └── 唯一权威 world：tick / AI / 目标 / 胜负 / 30Hz 全量快照             └── world 只是壳：不 tick / 不跑 AI
```

- **房主权威**：所有 `logic/` 只在房主跑；客机只发命令、收快照。
- **中继哑**：`server/daeem_relay.py` 只按房间转发，不 import 游戏逻辑，不解析 `cmd`/`snap` 正文。
- **transport 可替换**：`net/transport.gd` 是接口；`net/relay_transport.gd` 是 WebSocket 实现。
  以后 Steam P2P 只换 transport，不动协议与会话。

### 4.2 大厅 → 游戏的交接（容易接错的地方）

```text
主界面 test_2 / 合作模式按钮
  → view/coop_lobby.gd
      → net/lobby.gd
          → RelayTransport
              → 中继 /ws

房主点开始：
  lobby.take_transport()       ← 断开 lobby 的 message 处理器
  → main._on_coop_host_started()
  → game_scene3d.start_coop_host(campaign, level, transport)
  → HostSession.setup(...)
  → HostSession.start_game(campaign_id, level_id)  ← 这条 start 发给客机

客机收到 start：
  Lobby 先 take_transport()
  → guest_started(payload, transport)
  → main._on_coop_guest_started()
  → game_scene3d.start_coop_guest(payload, transport)
  → Level.from_data(payload.level_data) + ClientSession
```

★ **transport 只能有一个主人**：
`Lobby.take_transport()` 会断开 lobby 自己对 `message` / `closed` 的连接。
如果绕过大厅直接 new `HostSession`，会出现「大厅和游戏同时收包」；不要这么做。

### 4.3 房主 / 客机在 `game_scene3d.gd` 的差异

| 项 | 房主 `coop_role == "host"` | 客机 `coop_role == "guest"` |
|---|---|---|
| world | `create_from_level(..., true)`，跑 AI | `create_from_level(..., false)`，不跑 AI |
| 每帧 | `world.tick()` + `host_session.tick()` | **不 tick**，只 `client_session.poll()` |
| 命令 | `_on_command()` 直接 `CommandRes.apply` | `client_session.send_command()` |
| 快照 | 30Hz 发送（`net.snapshot_hz`） | 收到后 `apply_snapshot()`，`drop_dead_selection()`；一帧只应用最后一条 |
| 事件 | 本地 tick 产生，自己消费 | `events_received` → `_consume_events()` |
| 暂停 | `pause_allowed=false` | `pause_allowed=false` |
| 席位 | `seats[0]`（F1） | `seats[1]`（F2） |

### 4.4 协议 / 房间的硬约定

- 信封：`{"v":1,"t":"...","seq":N,"ts":ms,"body":{...}}`
- build：`coop-m12.2`（`net/protocol.gd` 的 `BUILD`、`config.net.build`、中继 `--build` 三处必须一致）。
- 房间码：6 位，字母表去掉 `0/O/1/I`。测试用 `CAMP23` / `FRWD23` / `LNGH23`。
- 关键消息：`hello` / `create_room` / `join_room` / `ready` / `start` / `cmd` / `snap` / `event` / `bye`。
- `start` 的 body 至少包含：`campaign`、`level_id`、`level_data`、`seats`、`guest_seat`。
- `HostSession` 校验 `by` / `faction` / `seq`；非法命令丢弃，不执行。
- `snap` 是**全量结果**；缺字段 = 保持本地现状。

---

## 5. 文件地图（改哪里）

### 5.1 逻辑 / 网络

| 文件 | 责任 |
|---|---|
| `logic/world.gd` | 席位 / 资源 / 科技 / `refresh_after_snapshot()` / `accepts_owner()` |
| `logic/snapshot.gd` | 全量快照；`pres` 在多人局不回退到 `res` |
| `logic/level.gd` | `coop_roster()`；`from_data()`（客机从 `level_data` 建 Level） |
| `net/protocol.gd` | 信封、版本、build、房间码 |
| `net/transport.gd` | transport 接口（message / connected / closed / send_text / poll） |
| `net/relay_transport.gd` | Godot `WebSocketPeer` 实现；8 MiB 缓冲；`poll()` 返回 void |
| `net/host_session.gd` | 房主侧：收客机命令、30Hz 快照（带背压）、事件、`bye` |
| `net/client_session.gd` | 客机侧：发命令、应用快照、收事件、`bye` |
| `net/lobby.gd` | 建房 / 加入 / 准备 / 收 start；`take_transport()` 交接 |
| `net/event_codec.gd` | 事件里的对象引用 ↔ 单位 id / 建筑 key |

### 5.2 视图 / 流程

| 文件 | 责任 |
|---|---|
| `view/coop_lobby.gd` | 大厅 UI；节点名 `CreateBtn` / `JoinBtn` / `ReadyBtn` / `StartBtn` / `RoomCode` / `RelayUrl` |
| `view/menu_secondary_panel.gd` | `with_coop_lobby`；`coop_lobby()`；两层合作信号 |
| `view/menu_chrome.gd` | `CoopBtn`；`open_coop_panel()`；信号上抛 |
| `view/start_screen.gd` | `test_2` 的 `coop` 标记；打开合作面板 |
| `view/main.gd` | 载入合作战役/关卡；`start_coop_host/guest`；失败时关 transport |
| `view/game_scene3d.gd` | 房主/客机主循环、命令路由、退出清理、暂停禁用 |
| `view/input_controller.gd` | `pause_allowed` |

### 5.3 服务器 / 测试

| 文件 | 责任 |
|---|---|
| `server/daeem_relay.py` | 零依赖 RFC6455 中继；`/health` `/rooms` `/ws`；房间 / 心跳 |
| `server/relay_client.py` | 标准库 WebSocket 客户端（测试 / 探针用） |
| `server/probe_relay.py` | 本机 host / guest 探针 |
| `server/test_relay.py` | 6 项中继边界测试 |
| `server/run-local.ps1` | 中继 + 两个探针一条命令 |
| `server/README.md` | 本机跑通 + IPv4/nssm 部署步骤（**已有，先读**） |
| `tests/test_coop_lobby.gd` | 真实中继上的大厅测试 |
| `tests/test_coop_entry.gd` | `test_2` 打开合作大厅 |
| `tests/test_coop_game_scene.gd` | 两个 GameScene3D 的房主/客机测试 |
| `tests/test_relay_transport.gd` | Godot ↔ Python 中继 |

---

## 6. M12.5 公网部署（已完成，2026.10.19）

### 6.1 用户已拍板的部署口径

用户 2026.10.19 明确说：

> “怎么方便怎么来，用 IPv4 吧。”

已经写进 `docs/dev_plan_12.md` §7.3 和 `server/README.md`：

| 项 | 定稿 |
|---|---|
| 服务器 | 腾讯云 Windows（构建 10.0.20348） |
| 地址 | `ws://159.75.154.122:8770/ws`（实测） |
| 传输 | 明文 WebSocket；**不做 TLS / 域名 / IIS / 443** |
| 监听 | `0.0.0.0:8770` |
| 安全组 | 只放行 TCP 8770；RDP 单独限制来源 |
| 托管 | nssm 服务 `DAEEMRelay`；开机自启 / 崩溃重启 |
| 健康 | `http://159.75.154.122:8770/health`（实测） |
| Python / nssm | `C:\Program Files\python\python.exe` / `C:\tools\nssm.exe` |
| 暂存 / 服务目录 | `C:\daeem_stage\server` / `C:\daeem\server` |
| 日志 | `C:\daeem\logs\relay.{out,err}.log`，轮转 |
| 客户端 | `data/config.json` 的 `net.relay_url`（已指向实测地址） |
| 以后 | 要 `wss://` 只改 `relay_url`；协议 / 会话不动 |

**现有 IIS 网站不受影响**：中继只占 8770，不抢 443，不碰站点绑定。

### 6.2 要创建的文件：`server/deploy.ps1`

**已创建并在云服务器实跑成功（2026.10.19）**：幂等部署 + 备份 + 健康检查 + 回滚。
实际部署命令与 `/health` 结果见 `server/README.md` 的「本次实测」和 `route.md` 52.1；
`6.5` 的首次 PC+Android 联机由用户确认成功（逐项记录未留）。用法见 `server/README.md` 的
「一键部署（推荐）」。以下参数与要求是它的实现口径。

> ⚠️ 首次部署踩到并修掉：nssm 的 `set` 顺序必须是 `nssm set <服务> <参数> <值>`
> （见 `pitfalls.md` 5.73）；以及源目录 = 目标目录时的自复制（5.74）。

建议参数（可按实际服务器调整，但写进 README）：

```powershell
param(
    [string]$ServerRoot = "C:\daeem",
    [string]$Python = "C:\Python312\python.exe",
    [string]$Nssm = "C:\tools\nssm.exe",
    [int]$Port = 8770,
    [string]$ServiceName = "DAEEMRelay",
    [switch]$DryRun
)
```

必须满足：

1. **幂等**：重复跑不重复装服务、不重复加防火墙规则（安全组是云控制台，不在脚本里）。
2. **先备份**：`C:\daeem\server` 或至少 `daeem_relay.py` 备份带时间戳；备份失败就停，不覆盖。
3. **检查前置**：管理员权限、`$Python` 存在、`$Nssm` 存在、端口 8770 未被别的进程占用。
4. **只复制运行所需**：`daeem_relay.py`、`server/README.md`；不要复制 `logs/`、`__pycache__/`、
   `test_relay.py` / `probe_relay.py`（可留作排查，但不要作为服务入口）。
5. **注册 / 更新 nssm**：
   - `nssm install` 或 `nssm set`（服务已存在时更新，不重复 install）
   - `AppDirectory = <ServerRoot>\server`
   - 启动参数：`daeem_relay.py --host 0.0.0.0 --port <Port> --max-rooms 64`
   - `AppStdout` / `AppStderr`、`AppRotateFiles`
   - `Start SERVICE_AUTO_START`
6. **启动 + 健康检查**：`Invoke-RestMethod http://127.0.0.1:<Port>/health`，重试到超时；
   失败时打印服务状态和 `relay.err.log` 最后 50 行，并以非 0 退出。
7. **回滚**：健康检查失败时，停止服务、恢复备份、再启动旧版本；如果旧版本也起不来，明确报错，
   不要假装成功。
8. **不改 IIS**：不执行 `appcmd`，不碰 443，不停 `W3SVC`。
9. **`.ps1` 只用 ASCII**：本工程约定（PowerShell 5.1 中文编码会出问题）。
10. **成功输出一行**：`DEPLOY OK http://<ip>:<port>/health`（或类似固定标记），方便验收。

★ 不要依赖 `Start-Process -PassThru` 的 `ExitCode` 判成功：Windows PowerShell 5.1 下
重定向子进程可能给 `$null`。健康检查 / 固定输出才是判据（`run-local.ps1` 已踩过，见
`docs/pitfalls.md` 5.71）。

### 6.3 手工部署步骤（如果先不写脚本）

以 `server/README.md` 为准，核心是：

```powershell
# 服务器上
mkdir C:\daeem\logs -Force
# 复制 server/ 到 C:\daeem\server

nssm install DAEEMRelay "C:\Python312\python.exe" "C:\daeem\server\daeem_relay.py --host 0.0.0.0 --port 8770 --max-rooms 64"
nssm set DAEEMRelay AppDirectory  C:\daeem\server
nssm set DAEEMRelay AppStdout     C:\daeem\logs\relay.out.log
nssm set DAEEMRelay AppStderr     C:\daeem\logs\relay.err.log
nssm set DAEEMRelay AppRotateFiles 1
nssm set DAEEMRelay Start SERVICE_AUTO_START
nssm start DAEEMRelay

curl http://127.0.0.1:8770/health
```

云控制台安全组：放行 **TCP 8770**；不要放行 0.0.0.0/0 的 RDP。

### 6.4 客户端改地址

两台客户端都改 `dev_gd_a/daeem/data/config.json`：

```json
"net": {
  "relay_url": "ws://<公网IPv4>:8770/ws",
  "build": "coop-m12.2"
}
```

注意：

- 公网 IP 如果是**临时 IP**，云主机重启可能变；要么绑 EIP，要么每次改配置。
- `build` 必须和中继的 `--build`（默认 `coop-m12.2`）一致；不一致会被 `hello` 拒绝。
- 明文 `ws://`：房间码 / 命令 / 快照在公网可见，只适合朋友内测。
- 不改现有 IIS 站点；不占 443。

### 6.5 M12.5 验收清单（已完成）

在服务器上：

```powershell
curl http://127.0.0.1:8770/health
curl http://159.75.154.122:8770/health
curl http://159.75.154.122:8770/rooms
```

期望 `/health` 至少：

```json
{"ok":true,"rooms":0,"players":0,"uptime":1.2,"build":"coop-m12.2"}
```

两台客户端：

1. 都能进主界面 → `test_2` → 合作模式。
2. 房主创建房间，拿到 6 位码；客机输入同码加入。
3. 双方准备；房主「开始」；两端进 `02_twin_line`。
4. 房主只能选/指挥 F1；客机只能选/指挥 F2；点队友单位选不中但仍可见。
5. 客机造墙 / 招兵，房主能看到；房主操作客机能看到。
6. 两人资源条各花各的；客机资源不跟房主变。
7. 目标条两边都走；守满 120 秒双方显示守住；丢掉 c1 双方显示失败与原因。
8. 客机关窗口：房主继续，提示「队友已离开」。
9. 房主关窗口：客机回主界面，提示「房主已离开」。
10. 现有 IIS 网站仍可访问（如果服务器上有）；中继没有占用 443。
11. 服务重启：`nssm restart DAEEMRelay` 后 `/health` 恢复；客户端旧房间不重连，需重新建房。

✅ **2026.10.19 已完成**：公网 `/health` 返回 `ok:true` / `build:coop-m12.2`；
host/guest 探针跑完 `hello → create_room → join → ready → start → cmd → snap → bye`；
首次 PC+Android 联机由用户确认成功。⚠️ 逐项手玩记录没有留下，后续若要正式验收，
仍按上面 1~11 条重跑一遍。

### 6.6 部署常见坑

| 坑 | 症状 | 处理 |
|---|---|---|
| 只监听 `127.0.0.1` | 服务器本机 curl 通，公网不通 | `--host 0.0.0.0` |
| 安全组没放行 8770 | 公网超时 | 云控制台入站规则 TCP 8770 |
| Windows 防火墙挡 | 同上 | 本机防火墙放行 8770（脚本可选） |
| `build` 不一致 | 大厅报版本错误 | 改 `config.net.build` 或中继 `--build` |
| 公网 IP 变了 | 客户端连旧 IP | 绑 EIP / 改 `relay_url` |
| 服务账户无权写日志 | 服务起不来 | 给 `C:\daeem\logs` 写权限，或改日志路径 |
| 端口被 IIS / 别的服务占用 | 中继退出 | `Get-NetTCPConnection -LocalPort 8770`；换端口要同步客户端 |
| 用 `Start-Process.ExitCode` 判成功 | 明明成功却报失败 | 用 `/health` + 固定输出判断 |
| nssm `set` 参数顺序写反 | nssm 打印 Usage 并退出 1；服务已 install 但无参数 | 必须是 `nssm set <服务> <参数> <值>`（pitfalls 5.73） |
| 源目录 = 目标目录 | 部署脚本复制失败 | 用暂存目录；脚本已检测同路径跳过（pitfalls 5.74） |

---

## 7. 唯一可选项：客机视觉插值（M12.4 遗留，质量项）

当前客机每 30Hz 把快照位置直接写入 `unit.pos`，视觉上会跳。方案（见 `dev_plan_12.md` 5.4）：

- 客机保留 `pos` 为**权威位置**（选中 / 射程 / 迷雾 / 命令都用它）。
- 视图层另存 `render_pos`（建议放在 `view/unit_view_3d.gd` 的字典里，**不要污染 `logic/unit.gd`**）。
- 每帧向 `pos` 做指数插值；房主 / 单机 `render_pos == pos`，行为逐位不变。
- 投掷物同理（`view/projectile_view_3d.gd`）；命中结算仍用权威值。
- 断言：单机 / 房主不启用插值；客机 `render_pos` 收敛到 `pos`；选中/射程仍读 `pos`。

M12.5 已完成；如果玩家觉得客机跳动影响可玩性，再做这一项。它不进本轮验收，
也不阻塞任何已完成功能。

---

## 8. 明确不做 / 不要越过

| 不做 | 说明 |
|---|---|
| 断线重连 | 用户拍板；房主掉线 = 本局结束 |
| 客机接管 | 客机不跑逻辑、不判胜负 |
| 合作暂停 | 合作局 `pause_allowed=false`；P 只提示 |
| 3 人 / 观战 / 匹配 / 房间列表 | 固定 2 人，房间码即身份 |
| TLS / 域名 / IIS / 443 | 用户选择明文 IPv4 `ws://` |
| Steam P2P 实装 | 以后只换 transport |
| 新玩法 / 数值 / 新兵种 | 本轮只做联机 |
| 打包 / 导出 / commit / push | 本仓库没有留下导出产物；导出配置（`include_filter="*.json"`、Android `INTERNET`）已补齐；实际打包由用户侧执行；仍不 commit / push |
| 改根目录 `README.md` | 需要用户明确同意 |

另外：

- `test_2` 现在打开合作大厅；不要把它改回直接进 `02_twin_line`。
- 单人 `test_1` / `test_3` / 战役菜单路径必须保持不变。
- `logic/` 不认房间、不认 transport、不认暂停；这些都在 `net/` / `view/`。
- 不要为了“优化”把 `HostSession` / `ClientSession` 合成一层；房主和客机的职责不同。

---

## 9. 执行状态（M12 已完成）

1. **基线**：第 3 节命令已跑过；10 个 coop 套件 **213 项**、`server/test_relay.py` **6 项**、
   `check-syntax.ps1` **159 文件**全绿（含并行新增的过渡 / 退出确认文件）。
2. **M12.5**：已按 §6 部署到腾讯云；公网 `/health` 与 host/guest 探针通过；
   §6.5 的首次 PC+Android 联机由用户确认成功（逐项记录未留）。
3. **M12.6**：`route.md` 第五十二节、`architecture.md`、`pitfalls.md` 5.73~5.76、
   `docs/README.md`、`server/README.md`、`mobile.md` 第 20 节已更新。
4. **M12.7**：默认 **30Hz** + 发送端背压 + 客机快照合并 + `apply_snapshot` id 索引；
   测量见 `route.md` 第五十三节，基准脚本 `tests/bench_snapshot.gd`。
5. **可选**：客机视觉插值（§7），不影响已完成功能。
6. **重新部署**：先 `-DryRun`，再按 §6.2 跑；根 `README.md` 只有用户明确同意才改。

---

## 10. 交接时不要忘的“现状事实”

- 当前分支/工作区没有 commit；所有 M12 改动都在工作区。
- 工程根 `README.md` 没改（需要用户明确同意）。
- 本仓库没有留下导出产物；导出配置（`include_filter="*.json"`、Android `INTERNET`）已补齐。
- 已首次 PC+Android 联机成功（用户确认，未逐项记录）；正式手玩验收清单仍可按 §6.5 重跑。
- `server/deploy.ps1` 已在云服务器实跑成功；首次部署修掉 nssm `set` 顺序与自复制两个坑。
- 公网：`ws://159.75.154.122:8770/ws`；服务 `DAEEMRelay`；端口 `8770`；build `coop-m12.2`。
- 快照默认 **30Hz**（`net.snapshot_hz`）；发送端 1 MiB 背压；客机一帧只应用最后一条；
  `apply_snapshot` 已把 `world.unit_by_id()` 的 O(n²) 改成一次性 id 索引。
- 30Hz 测量用 `tests/bench_snapshot.gd`（不进 run-tests）；数字见 `route.md` 第五十三节。
- 中继零第三方依赖；Python 3.11+ 即可。
- `server/logs/` 和 `__pycache__/` 已在 `server/.gitignore` 忽略。
- 客户端 `data/config.json` 的 `net.relay_url` 已指向公网地址；大厅仍可手改。
- 房间码字母表去掉 `0/O/1/I`；测试码 `CAMP23` 合法。
- `test_coop_game_scene` 的 leak warning 是测试退出清理问题，不是失败。

---

## 11. 关键文档索引

| 文档 | 用途 |
|---|---|
| [`dev_plan_12.md`](dev_plan_12.md) | 方案、协议、席位、里程碑、风险（**§13 已更新为交接状态**） |
| [`route.md`](route.md) 第五十 ~ 五十三节 | M12.3 ~ M12.7 已落地记录、部署与 30Hz 测量 |
| [`architecture.md`](architecture.md) | 分层、联机会话、部署 / 导出的“状态放哪”表 |
| [`pitfalls.md`](pitfalls.md) | 5.66~5.82 的实测坑（快照 / JSON / polling / PowerShell / nssm / 导出 / 30Hz） |
| [`../daeem/tests/bench_snapshot.gd`](../daeem/tests/bench_snapshot.gd) | 快照体积 / 序列化 / apply / fog 的测量基准 |
| [`mobile.md`](mobile.md) 第 20 节 | Android 联机（实验性）与导出前提 |
| [`../daeem/server/README.md`](../daeem/server/README.md) | 本机跑通 + 一键部署 + 本次实测 |
| [`../daeem/data/config.json`](../daeem/data/config.json) | `net.relay_url` / `net.build` / `coop.lobby.*` |
| [`../daeem/export_presets.cfg`](../daeem/export_presets.cfg) | `*.json` 包含过滤 / Android `INTERNET` 权限 |

---

## 12. 给下一个 AI 的一句话

**M12.1~M12.7 已全部完成：公网中继 `ws://159.75.154.122:8770/ws` 已跑通（服务
`DAEEMRelay`），快照默认 30Hz 并带背压 / 客机合并，文档已收口；首次 PC+Android 联机由用户
确认成功。不要重做已完成的部分；唯一可选项是客机视觉插值。断线重连/客机接管/暂停/
TLS/IIS/打包/commit 都不在本轮范围。**
