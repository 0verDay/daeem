# DAEEM 联机中继

这是**房主权威**结构里的哑中继：只按房间转发消息，不跑游戏逻辑、不解析
`cmd` / `snap` 内容、不保存对局。服务器不装 Godot，只需要 Python。

当前定稿（2026.10.19）：**腾讯云 Windows + 公网 IPv4 + 明文 `ws://` + nssm**。
不上域名、不占 IIS 的 443；现有网站不受影响。

---

## 本次实测（2026.10.19）

已部署到腾讯云 Windows（构建 10.0.20348），当前可用地址：

| 项 | 值 |
|---|---|
| 中继 | `ws://159.75.154.122:8770/ws` |
| 健康 | `http://159.75.154.122:8770/health` |
| 服务 | nssm `DAEEMRelay`（Automatic） |
| 监听 | `0.0.0.0:8770` |
| build | `coop-m13.1` |
| Python | `C:\Program Files\python\python.exe` |
| nssm | `C:\tools\nssm.exe` |
| 暂存 | `C:\daeem_stage\server` |
| 服务目录 | `C:\daeem\server` |
| 日志 | `C:\daeem\logs\relay.{out,err}.log` |
| 备份 | `C:\daeem\backup\server-<时间戳>` |

实际部署命令：

```powershell
powershell -ExecutionPolicy Bypass -File C:\daeem_stage\server\deploy.ps1 `
    -ServerRoot C:\daeem `
    -Python "C:\Program Files\python\python.exe" `
    -Nssm C:\tools\nssm.exe `
    -PublicIp 159.75.154.122 `
    -OpenFirewall
```

结果：`DEPLOY OK http://159.75.154.122:8770/health`；
`/health` 返回 `{"ok":true,"rooms":0,"players":0,"uptime":...,"build":"coop-m13.1"}`。
公网 host/guest 探针跑完 `hello → create_room → join → ready(guest) → start → cmd → snap → bye`，
两端 `PROBE ... OK`，退出后 `/rooms` 为空。

客户端 `data/config.json` 的 `net.relay_url` 已指向该地址；大厅不再提供手改输入框（地址以配置为准）。
首次部署踩到的 nssm `set` 顺序坑见 `docs/pitfalls.md` 5.73。

> 客户端快照默认 **30Hz**（M12.7）。按 `tests/bench_snapshot.gd` 的测量，
> 136 / 336 / 536 单位约 **0.94 / 2.24 / 3.54 MB/s**（单向）；中继只做转发，
> 不解析快照正文。若公网带宽紧张，客户端可把 `net.snapshot_hz` 调到 20。

---

## 本机跑通（M12.3）

```powershell
# 一条命令：起中继 + 房主探针 + 客机探针，最后打印 RUN LOCAL OK
powershell -ExecutionPolicy Bypass -File server/run-local.ps1
```

它会跑：

```text
hello -> create_room(123456) -> join -> ready(guest) -> start
      -> cmd(guest->host) -> snap(host->guest) -> bye
```

日志在 `server/logs/`：

- `relay.out.log` / `relay.err.log`
- `host.out.log` / `host.err.log`
- `guest.out.log` / `guest.err.log`

### 单独跑

```powershell
python server/daeem_relay.py --host 127.0.0.1 --port 8770
python server/probe_relay.py --role host  --url ws://127.0.0.1:8770/ws --room 123456
python server/probe_relay.py --role guest --url ws://127.0.0.1:8770/ws --room 123456
```

### 中继测试

```powershell
python server/test_relay.py
```

覆盖：握手、房间转发、分片、掩码、长度 126/127、close。
Godot 侧另有一个自包含测试：

```powershell
godot --headless --path . --script res://tests/test_relay_transport.gd
```

它自己用 `OS.create_process` 起中继（端口 8773），没有 Python 时会 SKIP。

---

## 云上部署（IPv4）

服务器：腾讯云 Windows，公网 IPv4，Python 3.11+，nssm。

### 一键部署（推荐）

在服务器上以**管理员** PowerShell 运行。推荐先把 `server/` 放到**暂存目录**
（例如 `C:\daeem_stage\server`），再由脚本把运行文件复制到 `C:\daeem\server`：

```powershell
# 0. 把本机 dev_gd_a\daeem\server\ 整个目录复制到服务器的 C:\daeem_stage\server

# 1. 先看计划，不改系统
powershell -ExecutionPolicy Bypass -File C:\daeem_stage\server\deploy.ps1 -ServerRoot C:\daeem -DryRun

# 2. 真正部署；-PublicIp 只影响最后那行提示
powershell -ExecutionPolicy Bypass -File C:\daeem_stage\server\deploy.ps1 `
    -ServerRoot C:\daeem `
    -Python C:\Python312\python.exe `
    -Nssm C:\tools\nssm.exe `
    -PublicIp <公网IPv4>
```

> 脚本也兼容「就地部署」：把 `server/` 直接放到 `C:\daeem\server` 再运行
> `C:\daeem\server\deploy.ps1` 也可以（检测到源目录 = 目标目录时会跳过复制）。
> 但推荐暂存目录，这样服务目录里只会留下 `daeem_relay.py` 与 `README.md`。

脚本行为（与 `docs/handoff_12.md` 6.2 一致）：

1. 前置检查：管理员权限、Python、nssm、`daeem_relay.py`、TCP 端口是否被**服务树之外**的进程占用。
2. **先备份** `<ServerRoot>\server` 到 `<ServerRoot>\backup\server-<时间戳>`（含哈希校验）；
   备份失败就停，不覆盖旧版本。
3. 停旧服务 → 只复制 `daeem_relay.py` 与 `README.md`（不复制 `logs/`、`__pycache__/`、探针）。
4. 安装或更新 nssm 服务：`--host 0.0.0.0 --port 8770 --max-rooms 64 --build <config.net.build>`，
   日志 `C:\daeem\logs\relay.{out,err}.log`，开机自启、崩溃重启、日志轮转。
5. 启动并轮询 `http://127.0.0.1:8770/health`；失败时打印服务状态和 `relay.err.log` 最后 50 行，
   自动恢复备份并重启旧版本，最后以非 0 退出。
6. 成功打印一行 `DEPLOY OK http://<ip>:<port>/health`。

常用参数：

| 参数 | 默认 | 说明 |
|---|---|---|
| `-ServerRoot` | `C:\daeem` | 服务目录 = `<ServerRoot>\server`，日志 = `<ServerRoot>\logs` |
| `-Python` | 自动查找 | 必须是 nssm 能启动的 `python.exe` 完整路径 |
| `-Nssm` | 自动查找 | `nssm.exe` 完整路径 |
| `-Port` | `8770` | 改端口后客户端 `relay_url` 要同步 |
| `-ServiceName` | `DAEEMRelay` | Windows 服务名 |
| `-MaxRooms` | `64` | 中继房间上限 |
| `-Build` | 读 `data/config.json` | 缺省回落 `coop-m13.1`，必须与客户端一致 |
| `-PublicIp` | 空 | 仅用于最后的 `DEPLOY OK` 提示 |
| `-OpenFirewall` | 关 | 幂等添加 Windows 防火墙入站规则；云安全组仍需在控制台放行 |
| `-DryRun` | 关 | 只打印计划并校验输入，不改服务 / 文件 / 防火墙 |

> 脚本**不碰 IIS、不占 443、不停 `W3SVC`**。重复运行是幂等的：服务已存在时只更新参数，
> 防火墙规则已存在时不重复添加。

### 手工步骤（脚本不可用时的备用）

1. 复制 `server/` 到服务器，例如 `C:\daeem\server`。
2. 建日志目录 `C:\daeem\logs`。
3. 安全组放行 **TCP 8770**（不要只放行 127.0.0.1）。
4. nssm 注册服务：

```powershell
nssm install DAEEMRelay "C:\Python312\python.exe" "C:\daeem\server\daeem_relay.py --host 0.0.0.0 --port 8770 --max-rooms 64 --build coop-m13.1"
nssm set DAEEMRelay AppDirectory  C:\daeem\server
nssm set DAEEMRelay AppStdout     C:\daeem\logs\relay.out.log
nssm set DAEEMRelay AppStderr     C:\daeem\logs\relay.err.log
nssm set DAEEMRelay AppRotateFiles 1
nssm set DAEEMRelay Start SERVICE_AUTO_START
nssm start DAEEMRelay
```

5. 健康检查：

```powershell
curl http://<公网IPv4>:8770/health
# {"ok":true,"rooms":0,"players":0,"uptime":1.2,"build":"coop-m13.1"}
```

6. 客户端：

```json
"net": {
  "relay_url": "ws://<公网IPv4>:8770/ws",
  "build": "coop-m13.1"
}
```

### 注意

- **明文 `ws://`**：房间码 / 命令 / 快照在公网可见；只适合朋友内测。
- 不做 TLS、不占 443、不碰现有 IIS 网站。
- 以后要 `wss://`：加域名反代 / 证书，只改 `relay_url`。
- 不做断线重连、服务端游戏逻辑、账号、匹配、观战、持久化。
- 房主掉线 = 这一局结束；客机掉线 = 房主继续（中继只发 `bye`，不接管）。

---

## 中继行为

- `GET /health`：进程存活、房间数、连接数、uptime、build。
- `GET /rooms`：房间码 / 人数 / 状态（不暴露 IP）；大厅的「房间列表」直接读它。
- `WS /ws`：游戏连接。
- 房间码 **6 位数字 0-9**（与大厅键盘一致；旧字母码不再有效）。
- 一条连接一行日志；不打印消息正文。
- 客机 `ready` 是**开关**（`body.ready`），可取消准备；房主点「开始」只要求客机已准备。
- 客机 `bye`：房主收到 `bye` + `room_state`，房间保留；房主 `bye`：双方收摊。
- 心跳：20 秒 ping，60 秒无 pong 断开。
