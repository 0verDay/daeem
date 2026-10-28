# Rusted Warfare 1.15 联网协议与 120 FPS 流畅机制：逆向规范

> **读者**：AI 编码代理 / 需要实现类似 RTS 联机同步的工程系统。
> **目标**：理解 Rusted Warfare 1.15 的联网协议、锁步调度、校验/重同步与高刷新渲染机制；并据此设计一个可适配其他 RTS 的确定性联机层。
> **来源**：对 `Rusted Warfare/game-lib.jar` 的静态反编译（CFR 0.152 + JDK 17 `javap`）。
> **版本**：Game 1.15 / Code 176 / Build #28。
> **性质**：逆向分析；反编译代码不是原始源码，混淆名保持原样；推断内容单独标注。

---

## 0. 阅读约定

### 0.1 文档结构

| 部分 | 内容 |
|---|---|
| Part I | Rusted Warfare 联网协议的可验证事实 |
| Part II | 锁步、固定步进、追赶、校验/重同步的算法 |
| Part III | 迁移到其他 RTS 的协议设计与测试清单 |
| Appendix | 精确参数、包类型、证据与置信度 |

### 0.2 置信度

| 标签 | 含义 |
|---|---|
| `[observed]` | 反编译代码中直接看到 |
| `[inferred]` | 由多个调用点、日志或创建上下文推断 |
| `[generalized]` | 为适配其他 RTS 抽象出的设计，不是源游戏事实 |
| `[unused]` | 存在但本版本未发现有效使用 |

### 0.3 规范用语

- **MUST**：协议正确性/确定性所必需。
- **SHOULD**：推荐；偏离需记录理由。
- **MAY**：可选。
- **MUST NOT**：禁止。

### 0.4 时间单位

- 源游戏逻辑帧率：**60 Hz**。
- `1 frame = 1/60 s ≈ 16.667 ms`。
- 文中 `frame` 默认指逻辑帧；渲染帧会单独说明。
- 源游戏的 `bx` 是逻辑帧号，`by` 是逻辑时间（毫秒）。

---

# Part I：可验证的联网事实

## 1. 执行摘要

### 1.1 一句话结论

`[observed]` 它不是 120Hz 联机模拟。联机逻辑是 **60Hz 锁步**；120/144/300 FPS 是渲染/输入/相机层。所谓“120 帧联机流畅”来自：

```
60Hz 确定性模拟
+ 10 帧命令批处理（约 6 批/秒）
+ 只同步命令，不同步状态
+ 120/300 FPS 独立渲染
+ 10 帧指令缓冲吸收抖动
+ 落后追帧 / 动态 stepRate
+ 约 5 秒一次的校验和 + 全量 resync
```

### 1.2 关键数字

| 项目 | 值 | 置信度 |
|---|---|---|
| 默认游戏端口 | 5123 | `[observed]` |
| LAN 发现端口 | 5005（UDP） | `[observed]` |
| 逻辑帧率 | 60 Hz | `[observed]` |
| 帧批大小 `Q` | 10 逻辑帧 ≈ 166.7ms | `[observed]` |
| 初始偏移 `R` | 0 | `[observed]` |
| 默认 stepRate | 1.0；最小 0.1；lag 时 2.0 | `[observed]` |
| 校验周期 | 约 300 帧 = 5 秒 | `[observed]` |
| 渲染目标 | 300（highRefreshRate）/ 120 FPS | `[observed]` |
| 帧批频率 | 约 6 批/秒 | 推导 |
| TCP 读超时 | 约 15 秒 | `[observed]` |
| 客户端连接超时 | TCP 7s / UDP 5s | `[observed]` |

### 1.3 关键结论

1. **命令锁步**：网络只传玩家命令、帧边界、周期校验和，不广播单位位置/血量/资源。
2. **服务器调度**：服务器维护 `X`（下一个阻塞帧），每批把 `X` 推进 `Q=10`。
3. **客户端等待**：客户端模拟到 `X` 后设置 `Y=true`，等待下一批帧包。
4. **固定步进**：渲染可以 120/300 FPS，但模拟按 `currentStepRate=1.0` 固定 60 步/秒。
5. **追赶**：落后 30/90/120/600 帧时额外追帧；持续 lag 时 stepRate 提升到 2.0。
6. **校验/重同步**：type 30/31 校验和；type 35 发送完整 `gameSave` 重载。
7. **没有状态广播**：带宽主要取决于命令数量，不随单位数量线性增长。
8. **没有找到实体位置插值**：高刷新主要改善相机/输入/UI，单位逻辑仍 60Hz。

---

## 2. 协议分层

```text
┌──────────────────────────────────────────────────────┐
│ 应用层：锁步 / 命令 / 校验 / 重同步                  │
│  - FrameBatch(type 10), ClientCommand(type 20)       │
│  - Checksum(type 30/31), Resync(type 35)             │
├──────────────────────────────────────────────────────┤
│ 序列化：as / k (DataStream)                          │
│  - writeUTF, int/float/bool, 长度前缀 block           │
│  - 命名 GZIP block（大块数据）                        │
├──────────────────────────────────────────────────────┤
│ 分帧：c 连接 / d 接收 / e 发送                        │
│  - [int32 length][int32 type][payload]               │
│  - type <= 100 进游戏队列；type > 100 系统包          │
├──────────────────────────────────────────────────────┤
│ 传输：TCP 5123（默认）/ RUDP over UDP（可选）         │
├──────────────────────────────────────────────────────┤
│ 发现：UDP 5005 广播 ping/pong                        │
└──────────────────────────────────────────────────────┘
```

### 2.1 类映射

| 类 | 职责 | 置信度 |
|---|---|---|
| `gameFramework.j.ad` | NetworkEngine：包分发、锁步调度、校验、重同步 | `[observed]` |
| `gameFramework.j.c` | 单个连接；发送/接收 worker；连接状态 | `[observed]` |
| `gameFramework.j.d` | 接收线程；读 `[length][type][payload]` | `[observed]` |
| `gameFramework.j.e` | 发送线程；写 `[length][type][payload]` | `[observed]` |
| `gameFramework.j.ao` | 服务器监听：TCP `ServerSocket` / UDP RUDP | `[observed]` |
| `gameFramework.j.af` | LAN 发现 UDP 广播 | `[observed]` |
| `gameFramework.j.as` / `k` | 输出/输入 DataStream 封装 | `[observed]` |
| `gameFramework.j.at` | GZIP 输出块 | `[observed]` |
| `gameFramework.j.au` | 包对象：连接、类型、payload、延迟/可靠标志 | `[observed]` |
| `a.a.h` | 自研可靠 UDP（RUDP）Socket | `[observed]` |
| `a.a.b` | RUDP ServerSocket | `[observed]` |
| `game.i.b` | 固定步进、追帧、等待 | `[observed]` |
| `java.u` | 桌面渲染目标帧率 / Slick 回调 | `[observed]` |

---

## 3. 线格式与传输

### 3.1 TCP 分帧

每个 TCP 包：

```text
int32 payloadLength
int32 packetType
byte[payloadLength] payload
```

`[observed]` 接收线程：

1. `readInt()` 读长度。
2. `readInt()` 读类型。
3. 按长度循环读满 payload。
4. `type > 100`：系统/大厅包，直接处理。
5. `type <= 100`：游戏包，放入 `aN` 队列，由游戏线程消费。

### 3.2 包长限制

`[observed]` 当 `length > 10000` 时，按连接状态限制：

| 状态 | 最大长度 |
|---|---|
| 服务器连接 | 50,000,000 bytes |
| 已注册客户端 | 1,000,000 bytes |
| 预注册客户端 | 10,000 bytes |

超过上限直接拒绝，避免恶意大包导致内存问题。

### 3.3 TCP 参数

| 参数 | 值 |
|---|---|
| 默认端口 | 5123（`networkPort`） |
| `TCP_NODELAY` | 开启 |
| 服务器 accept 后 `SO_TIMEOUT` | 约 15 秒 |
| 客户端 TCP 连接超时 | 约 7 秒 |
| 客户端 UDP 连接超时 | 约 5 秒 |
| 发送 | 每连接一个 SendWorker + `BufferedOutputStream` |
| 接收 | 每连接一个 ReceiveWorker |

### 3.4 序列化

`[observed]` `as` / `k` 封装 Java `DataOutputStream` / `DataInputStream`：

- `writeUTF` / `readUTF`：Java modified UTF-8。
- `int`、`float`、`double`、`long`、`boolean`、`short`。
- 长度前缀 byte[] / 文件 / 流。
- 命名块：`as.e("gameSave")` 开始，`as.a("gameSave")` 结束；块名和长度写入流。
- GZIP：`at` 包装 `GZIPOutputStream`，用于 `as.a(name, true)` 的命名块。

**工程结论** `[inferred]`：帧包很小，通常不压缩；GZIP 主要出现在 `gameSave`、`saveCompression`、初始化/自定义单位等大块数据。

### 3.5 UDP / RUDP

`[observed]`

- `udpInMultiplayer` 设置决定是否使用 UDP 游戏传输。
- `a.a.h` 是可靠 UDP 实现：ACK、累计确认、重传定时器、keepalive、空段定时器。
- `a.a.b` 是 RUDP ServerSocket：`DatagramSocket` + 虚拟连接。
- `au.e` 是包的可靠标志；游戏帧包在 UDP 下带可靠标志。
- LAN 发现使用独立的 UDP 5005：
  - 广播魔数 `com.corrodinggames.rts`
  - 版本号
  - `ping` / `pong`
  - 服务器在 `pong` 中返回玩家数
  - 仅用于服务器列表，不承载游戏帧。

---

## 4. 包类型目录

`[observed]` 编号来自 `ad` 的 `switch`；部分名称来自日志，部分为语义推断。

| 类型 | 方向 | 载荷/作用 | 置信度 |
|---|---|---|---|
| `10` | 服务器 → 客户端 | 帧批：`nextBlockingFrame`、命令数、命令列表 | `[observed]` |
| `20` | 客户端 → 服务器 | 客户端命令；服务器校验玩家/队伍后排队 | `[observed]` |
| `30` | 服务器 → 客户端 | 同步校验和请求：帧号 + checksum | `[observed]` |
| `31` | 客户端 → 服务器 | 校验和状态：客户端本地 checksum | `[observed]` |
| `35` | 服务器 → 客户端 | 重同步：帧号、时间、stepRate、`gameSave` | `[observed]` |
| `105` | 客户端 → 服务器 | 获取服务器信息 | `[observed]` |
| `106` | 服务器 → 客户端 | 服务器信息/设置 | `[observed]` |
| `115` | 服务器 → 客户端 | 加入/队伍/设置同步 | `[inferred]` |
| `116` | 服务器 → 客户端 | 玩家/准备状态 | `[inferred]` |
| `120` | 服务器 → 客户端 | 开始游戏：地图/存档/设置 | `[observed]` |
| `160` | 双向 | 预注册信息 | `[observed]` |
| `161` | 双向 | 预注册信息响应 | `[observed]` |
| `170` | 服务器 → 客户端 | 成为服务器/主机迁移 | `[observed]` |
| `175/176` | 中继 | 客户端转发/中继 | `[observed]` |
| `178` | 重连 | 重连到服务器 | `[observed]` |

### 4.1 type 10：帧批

`[observed]` 载荷：

```text
int32 nextBlockingFrame
int32 commandCount
repeat commandCount:
    Command
```

客户端处理：

1. 读 `nextBlockingFrame`。
2. 读命令数量。
3. 每条命令的 frame 设为当前 `X`。
4. 加入命令队列。
5. `X = nextBlockingFrame`。

### 4.2 type 20：客户端命令

`[observed]` 服务器处理：

1. 找到连接对应的玩家。
2. 读取命令。
3. 校验玩家/队伍/命令合法性。
4. 排入命令队列。
5. 在下一次帧批中按帧号发送。

### 4.3 type 30/31：校验和

`[observed]`

- 服务器 type 30：`frame` + `checksum`。
- 客户端 type 31：本地 checksum。
- 服务器比较；不匹配标记 desync。
- 周期约 `300` 帧（5 秒）；不是每帧校验。

### 4.4 type 35：重同步

`[observed]` 载荷：

```text
int32 version/zero
int32 frame
int32 timeMs
float stepRate
float 1.0
boolean flag1
boolean flag2
named block "gameSave"
    byte[] save
end block
```

客户端：

1. 读取帧号、时间、stepRate、标志。
2. 读取 `gameSave` 块。
3. 调用 GameSaver 重载。
4. 恢复 `bx` / `by`。
5. 设置 stepRate。
6. 继续锁步。

### 4.5 type 120：开始游戏

`[observed]` 服务器发送：

- 地图类型/地图数据或存档
- 对局设置
- 初始 `gameSave`（视模式）
- 启动标志

客户端加载后进入锁步。

---

## 5. 会话生命周期

```text
1. Discover
   - UDP 5005 broadcast ping/pong
   - 或直接输入 IP

2. Connect
   - TCP 5123 或 UDP RUDP
   - 建立连接对象 c
   - 启动 SendWorker / ReceiveWorker

3. Pre-register / Info
   - type 105/160/161
   - 版本、玩家名、连接信息

4. Lobby / Join
   - type 106/115/116
   - 队伍、设置、自定义单位
   - 校验网络版本、核心单位 SHA-256

5. Start
   - type 120
   - 地图/初始存档/设置

6. Lockstep
   - type 10/20
   - 10 帧批处理
   - 周期 type 30/31

7. Resync / Reconnect
   - type 35（全量存档）
   - type 178（重连）
   - type 175/176（中继）
```

### 5.1 加入校验

`[observed]`

- 网络版本。
- 游戏版本。
- 自定义单位内容/核心单位 checksum（SHA-256）。
- 地图/Mod/队伍一致性。

失败表现：

- “Server sync mismatch”
- “Missing unit”
- 拒绝加入或踢出。

---

# Part II：锁步、步进与追赶

## 6. 锁步调度算法

### 6.1 状态变量

| 变量 | 含义 | 初始值 |
|---|---|---|
| `X` | 下一个阻塞帧 | 0 |
| `Q` | 每批推进的逻辑帧数 | 10 |
| `R` | 起始偏移 | 0 |
| `Y` | 是否等待网络 | false |
| `bx` | 当前模拟帧 | 0 |
| `by` | 当前模拟时间 ms | 0 |
| `stepRate` | 每个模拟步推进的帧数 | 1.0 |
| `checksumPeriod` | 校验周期 | 300 帧 |

### 6.2 服务器算法

```text
function SERVER_NETWORK_UPDATE(dtFrames):
    if not gameRunning:
        return

    if bx >= X - R:
        nextFrame = X + Q

        packet = new Packet(type=10)
        packet.writeInt(nextFrame)

        commandsForX = commands.where(cmd.frame == X)
        packet.writeInt(commandsForX.count)
        for cmd in commandsForX:
            packet.writeCommand(cmd)

        sendToAllClients(packet)
        X = nextFrame
```

关键点：

- 服务器不是每帧发；每 `Q=10` 帧发一次。
- 发送的是“当前 X 帧的命令 + 下一个阻塞帧号”。
- 服务器把 `X` 推进到 `X+Q` 后继续模拟。
- 客户端会在 `X` 处等待，直到收到这一批。

### 6.3 客户端算法

```text
function CLIENT_ON_FRAME_BATCH(packet):
    nextFrame = packet.readInt()
    count = packet.readInt()

    for i in 0..count:
        cmd = packet.readCommand()
        cmd.frame = X
        commandQueue.add(cmd)

    X = nextFrame


function CLIENT_SIMULATION_STEP():
    if bx >= X:
        Y = true
        return WAIT

    network.checkFrame()
    simulateOneFrame()
    bx += 1
```

### 6.4 为什么是 10 帧

`[observed]` `Q=10` 在重置时设置；`R=0`。

- 10 帧 = 166.7ms（60Hz）。
- 约 6 批/秒。
- 给客户端命令留出网络传输窗口。
- 批处理减少包数量与协议开销。
- 代价是指令延迟至少约 166ms（再加 RTT）。

### 6.5 命令延迟与顺序

- 客户端命令 type 20 发送到服务器。
- 服务器校验后排队。
- 服务器在下一个帧批中按 `cmd.frame == X` 发送。
- 客户端在 `X` 执行。

**注意**：不同命令的 `cmd.frame` 如何赋值取决于命令控制器；本文只确认帧批按 `X` 收集和发送。实现新游戏时 **MUST** 明确定义“命令在哪个逻辑帧生效”，否则无法确定性回放。

---

## 7. 固定步进与渲染解耦

### 7.1 渲染目标

`[observed]` `java/u`：

```text
if settings.highRefreshRate:
    container.setTargetFrameRate(300)
else:
    container.setTargetFrameRate(120)
```

`preferences.ini` 默认：

```ini
highRefreshRate:true
renderVsync:false
renderSmoothDelta:false
```

实际 FPS 受显示器/VSync/驱动/负载限制。

### 7.2 固定累加器

`[observed]` `game.i.b` 简化：

```text
G += renderDelta

while G > currentStepRate:
    G -= currentStepRate

    if network.shouldWait():
        break

    network.checkFrame()
    simulate(currentStepRate)
```

- `currentStepRate` 默认 1.0。
- 1.0 表示每个模拟步推进 1 个逻辑帧 = 60 步/秒。
- 渲染可以 120/300 FPS；模拟不会因此变成 120/300Hz。

### 7.3 实体插值

`[inferred]` 反编译代码中未发现实体位置插值/lerp 实现；`renderSmoothDelta` 只是平滑 update delta。

因此：

- 高刷新主要提升相机、输入、UI、动画。
- 单位逻辑位置仍是 60Hz 更新。
- 不要宣称“120Hz 单位模拟”。

---

## 8. 等待、追帧与动态 stepRate

### 8.1 等待

```text
if bx >= X:
    Y = true
    stop simulation until next batch
```

`ad.a(step, false)` 在 `bx >= X` 时设置 `Y=true`。`game.i.b` 检测到 `Y` 后停止当前帧的模拟。

### 8.2 追帧

`[observed]` 客户端落后时：

| 条件 | 行为 |
|---|---|
| `bx < X - 30` | 设置 fast-forward 标志 |
| `bx < X - 90` | 额外执行模拟步 |
| `bx < X - 120` | 额外执行模拟步 |
| `bx < X - 600` | 额外执行模拟步 |
| `ae > stepRate * 3` | 额外执行模拟步 |

这些额外步进让客户端追上服务器，而不是永久等待。

### 8.3 动态 stepRate

`[observed]` 服务器检测持续 lag（`O > 8` 且 `P > 4`）时：

- 发送系统命令，把 stepRate 从 1.0 改成 2.0。
- stepRate 2.0 表示每个模拟步推进 2 个逻辑帧。
- 逻辑时间加速，追回差距。
- 之后可恢复 1.0。

约束：

- `setCurrentStepRate` 拒绝 `< 0.1` 的值。
- 默认 `1.0`。
- 重同步包也会携带 stepRate。

### 8.4 加载/阻塞

`[observed]` `I()` 检查是否应暂停：

- 如果 `isGoingToBlockThisFrame()` 为真，返回 true。
- 游戏循环会暂停模拟，避免加载/阻塞期间继续推进。

---

## 9. 校验和、desync 与 resync

### 9.1 周期

`[observed]`

- `checksumPeriod = 300` 帧 = 5 秒。
- 服务器维护 `ah`（最近校验帧）和 checksum list。
- 服务器在窗口中间发送 type 30。
- 客户端 type 31 回报本地 checksum。
- 服务器比较；不一致标记 desync。

### 9.2 重同步

`[observed]` type 35：

- 服务器生成完整 `gameSave`。
- 包内包含帧号、时间、stepRate、标志、`gameSave` 块。
- 客户端重载存档，恢复 `bx`/`by`，继续。
- 有 quick resync 路径，使用较小存档数据。

### 9.3 没有 rollback

`[inferred]` 未发现状态回滚/rollback 代码；同步修复依赖：

- 等待
- 追帧
- stepRate 加速
- 全量/快速 resync

---

## 10. 为什么看起来 120 帧流畅

### 10.1 机制组合

| 机制 | 作用 |
|---|---|
| 60Hz 固定逻辑 | 确定性、可回放、低 CPU |
| 120/300 FPS 渲染 | 相机/输入/UI 流畅 |
| 10 帧批处理 | 约 6 包/秒，低带宽 |
| 命令锁步 | 不广播单位状态 |
| 10 帧缓冲 | 吸收 RTT 抖动 |
| 追帧/stepRate | 保持同步 |
| 周期校验 | 检测 desync，不阻塞每帧 |
| GZIP 大块 | 减少存档/初始化传输 |
| TCP_NODELAY / RUDP | 降低小包延迟/避免队头阻塞 |

### 10.2 代价

| 代价 | 说明 |
|---|---|
| 输入延迟 | 约 166ms + RTT |
| 锁步等待 | 包晚到会短暂停住 |
| TCP 队头阻塞 | 丢包会阻塞后续包 |
| 追帧加速 | 落后太多时画面/逻辑变快 |
| 重同步 | desync 时加载存档 |
| 无插值 | 高 FPS 下单位逻辑仍 60Hz |

---

# Part III：迁移到其他 RTS 的协议设计

> 以下为 `[generalized]`。目标不是复刻 Rusted Warfare，而是实现“低网络频率 + 高渲染频率 + 确定性锁步”的同类方案。

## 11. 推荐架构

```text
Transport
  - reliable ordered stream (TCP) 或 reliable UDP
  - framing: [len][type][payload]
  - discovery: optional UDP broadcast

Session
  - handshake / version / content checksum
  - lobby / start / reconnect / relay

DeterministicSimulation
  - fixed tick (30/60 Hz)
  - command queue by tick
  - stable entity IDs / stable iteration
  - deterministic RNG

FrameScheduler
  - server: next blocking tick X
  - batch size Q (e.g., 4/6/10 ticks)
  - clients wait at X
  - command window / input delay

CatchUp
  - wait if ahead
  - fast-forward if behind
  - dynamic stepRate/time dilation

Integrity
  - periodic state checksum
  - desync detection
  - full/quick resync

Render
  - independent render rate
  - optional interpolation (recommended if logic < render)
```

## 12. 关键设计选择

### 12.1 逻辑 tick 与渲染帧率

| 选择 | 建议 |
|---|---|
| 逻辑 tick | 30 / 60 Hz；RTS 推荐 30–60 |
| 渲染 | 60 / 120 / 144 / 240 / 300 FPS 独立 |
| 插值 | 如果 tick < 渲染，建议做实体位置插值；源游戏未发现 |
| 固定步长 | **MUST** 用累加器，不能用可变 dt 直接模拟 |
| 确定性 | **MUST** 固定 RNG、迭代顺序、浮点策略 |

### 12.2 批大小与输入延迟

```yaml
network_profile:
  tick_rate: 60
  batch_ticks: 10          # Q
  input_delay_ticks: 10    # 约 166ms
  checksum_period_ticks: 300
  max_packet_bytes: 1048576
```

- 批越大：包越少、抗抖动越好，但输入延迟越高。
- 批越小：输入更跟手，但包更多、对抖动更敏感。
- RTS 推荐 6–10 帧批；竞技性强的 RTS 可 3–6 帧。
- **MUST** 在 UI 中显示/配置输入延迟，避免玩家误以为卡顿。

### 12.3 命令模型

```ts
interface Command {
  tick: number;          // 生效逻辑帧
  playerId: PlayerId;
  kind: CommandKind;
  payload: unknown;
}
```

**MUST** 定义：

- 命令何时生效（tick）。
- 命令的确定性序列化。
- 命令合法性校验（玩家/队伍/资源/冷却/位置）。
- 重复命令去重。
- 命令顺序稳定。

### 12.4 校验和

```ts
interface Checksum {
  tick: number;
  value: bigint;         // 稳定哈希
  entities: number;      // 采样数量
}
```

**MUST**：

- 哈希输入稳定（实体 ID 排序、固定字段顺序）。
- 周期可配置（例如 1–5 秒）。
- 不匹配时记录帧号、玩家、局部状态。
- 支持全量 resync 和可选快速 resync。

### 12.5 重同步

- 全量 resync：服务器发送完整世界快照。
- 快速 resync：发送差异/最近状态。
- 客户端加载后恢复 tick/time/stepRate。
- **MUST** 保证 resync 不改变后续随机序列。

### 12.6 传输

| 方案 | 适用 |
|---|---|
| TCP | 实现简单、稳定；注意队头阻塞 |
| RUDP | 低延迟、避免 HOL；需要 ACK/重传/顺序/去重 |
| WebRTC DataChannel | 浏览器/跨平台；可控可靠/不可靠通道 |
| 自定义 UDP | 高性能；实现成本高 |

**SHOULD**：

- 小包 `TCP_NODELAY` 或 UDP。
- 大块（存档/初始化）GZIP。
- 包长上限。
- 连接限流/防 DoS。
- 版本/内容校验。

---

## 13. 实现伪代码

### 13.1 服务器

```text
function SERVER_TICK(dt):
    accumulate(dt)

    while accumulator >= tickRate:
        accumulator -= tickRate

        if not gameRunning: continue

        if bx >= X - R:
            nextFrame = X + Q
            batch = collectCommandsFor(X)
            sendFrameBatch(nextFrame, batch)
            X = nextFrame

        simulateOneTick()
        bx += 1
```

### 13.2 客户端

```text
function CLIENT_TICK(dt):
    accumulate(dt)

    while accumulator >= tickRate:
        accumulator -= tickRate

        if bx >= X:
            waiting = true
            break

        simulateOneTick()
        bx += 1

    if waiting and noPackets:
        renderOnly()
```

### 13.3 命令接收

```text
function ON_CLIENT_COMMAND(cmd):

    if not validPlayer(cmd.player): reject
    if not validTeam(cmd.player): reject
    if not validCommand(cmd): reject

    cmd.tick = nextExecutableTick()
    commandQueue.push(cmd)
```

---

## 14. 移植检查清单

### 14.1 确定性

- [ ] 固定逻辑 tick / 固定步长。
- [ ] 稳定实体 ID 与迭代顺序。
- [ ] 确定性 RNG（种子 + 调用顺序固定）。
- [ ] 浮点策略明确（定点/量化/统一平台）。
- [ ] 命令序列化稳定。
- [ ] 回放/重连状态可序列化。

### 14.2 网络

- [ ] 分帧格式固定。
- [ ] 包长上限。
- [ ] 握手/版本/内容校验。
- [ ] 命令合法性校验。
- [ ] 批大小与输入延迟可配置。
- [ ] 等待/追帧/stepRate 策略。
- [ ] 校验和周期与重同步。
- [ ] 中继/重连/主机迁移（可选）。

### 14.3 渲染

- [ ] 逻辑与渲染解耦。
- [ ] 高刷新目标可配置。
- [ ] 如果逻辑 < 渲染，考虑实体插值。
- [ ] VSync / frame pacing 可配置。
- [ ] 相机/输入/UI 使用渲染 delta。

### 14.4 运维

- [ ] 服务器/客户端日志：帧号、X、stepRate、RTT、丢包、desync。
- [ ] 诊断面板：等待时间、追赶次数、重同步次数。
- [ ] 版本/内容不匹配的明确提示。
- [ ] 防 DoS：连接数、包长、命令速率。

---

## 15. 测试矩阵

| 场景 | 目标 |
|---|---|
| 60Hz 逻辑 + 120 FPS 渲染 | 无漂移、无额外逻辑步 |
| 60Hz 逻辑 + 300 FPS 渲染 | 帧率不改变模拟速度 |
| 人为 100ms RTT | 10 帧缓冲可吸收；无 desync |
| 人为 300ms RTT | 等待/追帧；不崩溃 |
| 5% 丢包 TCP | 队头阻塞；检查卡顿边界 |
| 5% 丢包 RUDP | 重传/顺序；检查追赶 |
| 客户端暂停/加载 | 不推进模拟；恢复后追帧 |
| 服务器卡顿 | 客户端等待；恢复后追帧 |
| 长时间运行 | 无内存增长/无 tick 漂移 |
| 重同步 | 全量/快速 resync 后继续一致 |
| 回放 | 相同命令/种子产生相同结果 |
| 高单位数 | 命令同步带宽不随单位数线性增长 |

### 15.1 验收标准

- 120/300 FPS 渲染下，逻辑仍稳定 60 tick/s。
- 10 帧批处理下，客户端无永久等待。
- 落后时能追帧，且不会越过 `X`。
- 校验失败能触发 resync 并恢复。
- 回放/重连命令序列一致。
- 包长/连接数/命令速率有上限。
- 版本/内容不匹配有明确拒绝。

---

## 16. 常见错误

1. **把 120 FPS 当成 120Hz 逻辑**：会导致 CPU/带宽爆炸。
2. **直接用可变 dt 模拟**：不确定、不可回放。
3. **每帧广播状态**：带宽随单位数增长。
4. **批次过大**：输入延迟高；批次过小：抖动敏感。
5. **没有命令合法性校验**：客户端可发非法命令。
6. **没有稳定迭代顺序**：随机/哈希不稳定，desync。
7. **没有包长上限**：恶意大包耗尽内存。
8. **TCP 队头阻塞未评估**：丢包时卡顿。
9. **重同步不恢复 RNG/时间**：resync 后继续 desync。
10. **没有 UI 提示输入延迟**：玩家误以为操作不跟手。

---

## 17. 源游戏常量与证据

### 17.1 常量

| 常量 | 值 |
|---|---|
| 游戏端口 | 5123 |
| LAN 发现端口 | 5005 |
| 逻辑帧率 | 60 Hz |
| 批大小 Q | 10 |
| 起始偏移 R | 0 |
| stepRate 默认/最小/追赶 | 1.0 / 0.1 / 2.0 |
| 校验周期 | 300 帧 ≈ 5s |
| 快速追赶阈值 | 30 / 90 / 120 / 600 帧 |
| TCP 读超时 | 15s |
| 客户端连接超时 | TCP 7s / UDP 5s |
| 渲染目标 | 300（highRefreshRate）/ 120 |
| 帧包类型 | 10 |
| 客户端命令 | 20 |
| 校验和 | 30 / 31 |
| 重同步 | 35 |
| 开始游戏 | 120 |

### 17.2 证据

- 目标：`Rusted Warfare/game-lib.jar`
- SHA-256：`8A550A37E2D8A5430866090D4E7D5892F9010B47F52A5A09350FC66C620DEEC9`
- 反编译：CFR 0.152
- 字节码辅助：JDK 17 `javap -p -c`
- 规模：1698 类，约 170,465 行 Java
- 主要证据：
  - `gameFramework/j/ad.java`
  - `gameFramework/j/c.java`
  - `gameFramework/j/d.java`
  - `gameFramework/j/e.java`
  - `gameFramework/j/ao.java`
  - `gameFramework/j/af.java`
  - `gameFramework/j/as.java`
  - `gameFramework/j/k.java`
  - `gameFramework/j/at.java`
  - `game/i.java`
  - `java/u.java`
  - `a/a/h.java`
  - `a/a/b.java`

### 17.3 不确定性

| 项 | 状态 |
|---|---|
| 部分大厅包名称 | 由 switch/日志推断，原始命名未知 |
| 实体位置插值 | 未发现；不能证明绝对不存在 |
| GZIP 使用范围 | 主要在大块；帧包通常不压缩 |
| 运行时实际 FPS/延迟 | 未抓包/未插桩；受平台和设置影响 |
| `R` 的完整语义 | 初始 0；未发现其他赋值 |
| `Q` 的完整语义 | 初始 10；用于帧批推进 |

---

## Appendix A：最小实现清单

如果要在新 RTS 中实现同类协议，按这个顺序：

1. 固定 tick 模拟 + 确定性 RNG。
2. 命令 schema + 合法性校验。
3. `[len][type][payload]` 分帧。
4. TCP 或 RUDP 传输。
5. 服务器 `X/Q/R` 帧批调度。
6. 客户端等待/追帧/stepRate。
7. 周期 checksum。
8. 全量/快速 resync。
9. 高刷新渲染独立于逻辑。
10. 日志、诊断、测试矩阵。

**最终验收**：120/300 FPS 渲染下逻辑稳定 60 tick/s；10 帧批处理不永久等待；落后可追帧；desync 可 resync；回放一致；非法命令被拒绝。
