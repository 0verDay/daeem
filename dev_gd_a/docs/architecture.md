# Godot 版 DAEEM · 架构

> 本文回答「代码放哪、谁依赖谁、状态存在哪」。
> 路线与里程碑见 [`route.md`](route.md)，HTML → Godot 的对照见 [`porting.md`](porting.md)。

---

## 一、一句话架构

**逻辑是纯数据类，渲染是场景节点，两者之间只有「读状态 + 收命令」两条线。**

```
      输入（鼠标/键盘）
            │  产出「命令」字典
            ▼
  ┌──────────────────────────┐
  │  logic/  纯 RefCounted    │   ← 不认识 Node、不认识场景树
  │  World / Unit / Building  │   ← 唯一拥有真实状态的地方
  │  Pathfinder / Zone ...    │   ← 不开窗口就能跑（测试、将来的服务器）
  └──────────────────────────┘
            │  读状态（每帧） / 可选：to_snapshot()
            ▼
  ┌──────────────────────────┐
  │  view/   Node2D / Control │   ← 只画，不改逻辑状态
  │  TerrainView / UnitView   │
  │  CameraRig / Hud          │
  └──────────────────────────┘
```

**铁律**（违反任何一条都会让后面的测试与联机变难）：

1. `logic/` 里**不许出现** `Node`、`Node2D`、`Control`、`SceneTree`、`get_tree()`、`@onready`
2. `logic/` 里**不许读输入**（`Input`、`InputEvent`、鼠标位置）—— 输入只产出命令
3. `view/` 里**不许改逻辑状态**（不写 `unit.hp = ...`）—— 只能读 + 发命令
4. 所有可调数值来自 `config.json`，代码里不写字面量

---

## 二、目录结构

```
dev_gd_a/daeem/
├── project.godot                 # 已就绪（4.7 / Forward Plus / D3D12）
├── icon.svg
├── data/                         # ★ 纯数据，不含代码
│   ├── config.json               #   全部可调数值（对应 HTML 版 js/config.js）
│   └── map_01.json               #   地形 / 大本营 / 出生点 / （将来）区块划分├── logic/                        # ★ 纯逻辑：extends RefCounted，禁止碰场景树
│   ├── grid.gd                   #   网格工具 + 索引换算 + 方向集（DIRS4/DIRS8/octile）
│   ├── pathfinder.gd             #   A*（四连通或八方向）+ segment_clear（超覆盖 DDA）
│   │                             #   + smooth_path（拉直）+ round_corners（拐角圆化）
│   ├── faction.gd                #   阵营模型：is_player_faction / same_side
│   ├── map_data.gd               #   载入地图（地形 + exists 存在格 + zones 区块网格）、连通性修正
│   ├── unit.gd                   #   单位：移动 + 战斗 + 警戒 + 复活（本轮不做复活）
│   ├── building.gd               #   建筑定义与实例：blocks(faction) / 血量
│   ├── zone.gd                   #   区块占领（每阵营独立进度）；区块划分读地图的 zones 网格，
│   │                             #   老地图（没有该字段）退回 6×4 均分占位
│   ├── economy.gd                #   资源产出
│   ├── combat.gd                 #   战斗结算与事件（索敌 / 开火 / 拆建筑）
│   ├── command_processor.gd      #   ★ 命令的唯一入口（move / build / demolish）
│   ├── snapshot.gd               #   ★ to_snapshot / apply_snapshot（本轮用于调试，将来是网络包体）
│   └── world.gd                  #   世界容器：持有 units / buildings / zones，推进 tick()
├── view/                         # 渲染：Node2D / Control，禁止改逻辑状态
│   ├── main.tscn / main.gd       #   入口场景：装配 world + view + hud
│   ├── terrain_view.gd           #   地形（TileMapLayer）
│   ├── building_view.gd          #   建筑（Node2D + 血条 + 受击闪光）
│   ├── unit_view.gd              #   单位（Node2D + 血条 + 交战标记）
│   ├── zone_view.gd              #   区块轮廓 + 占领进度
│   ├── overlay.gd                #   攻击线 / 建造预览 / 移动标记（**不画**选中范围圈）
│   ├── camera_rig.gd             #   相机：方向键平移 / 边缘滚屏 / 光标锚点缩放
│   ├── input_controller.gd       #   ★ 输入 → 命令（唯一允许读鼠标的地方）
│   ├── ui_layout.gd              #   ★ UI 的全部几何常量（照参考图的像素稿）+ 贴边规则
│   ├── ui_style.gd               #   UI 配色与 StyleBox 工厂
│   ├── hud.gd                    #   UI 装配：左部队列表 / 左下地图占位 / 底栏 / 右上设置
│   ├── squad_panel.gd            #   左侧「部队 1~10」（动态生成，点了只选中）
│   ├── detail_panel.gd           #   底栏「详细信息」：左选中详情 / 右资源 + 日志
│   ├── command_card.gd           #   右下 3×3 命令卡（内容随页签切换）
│   └── page_tabs.gd              #   单位 / 建筑 / 科技（科技点不动）
└── tests/                        # 无头断言测试（不进游戏包）
    ├── test_smoke.gd             #   脚手架自检 + 网格工具
    ├── test_logic.gd             #   玩法规则（移动 / 战斗 / 建造 / 占领 / 快照…）
    ├── test_view.gd              #   渲染层接线（能挂上树、跑帧不炸、中文字体）
    ├── test_ui.gd                #   ★ 新 UI：几何对着参考图、部队列表 / 命令卡 / 招募 / 右键手势
    ├── test_attack_orders.gd     #   ★ 攻击命令：点名打单位 / 建筑、行军攻击、索敌建筑
    ├── test_zone_capture.gd      #   ★ 占领进度显示：无主 / 我的地 / 别人的地 三种情况
    ├── test_map_editor.gd        #   ★ 地图编辑器导出的地图：exists 存在格（地图外不可通行）
    │                             #   + zones 区块网格（非矩形区块、空区块保留）
    └── test_building_body.gd     #   ★ 建筑本体：尺寸居中、挡敌不挡己、缝隙能穿、城墙回归
```

**地图编辑器**在 `dev_gd_a/tools/map_editor/`（Python + tkinter，**不在游戏包里**，
只是往 `data/` 里写 JSON）：见 [`../tools/map_editor/README.md`](../tools/map_editor/README.md)。

**为什么 `data/` 放项目根而不是 `logic/` 里**：数据将来要被地图编辑器生成、被人手改、
被服务器读，放根目录最中性。Godot 会把项目根下的 `.json` 一起导出（非资源文件默认包含）。

---

## 三、逻辑 ↔ 渲染 怎么连

三条线，**没有第四条**：

### 3.1 输入 → 命令（`input_controller.gd`）

这是唯一允许读鼠标的地方。它把玩家意图变成命令字典，交给 `command_processor`：

```gdscript
# view/input_controller.gd（示意）
func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseButton and event.pressed:
        var world := _screen_to_world(event.position)
        if event.button_index == MOUSE_BUTTON_LEFT:
            _cmd.emit({"kind": "select", "at": world})
        elif event.button_index == MOUSE_BUTTON_RIGHT:
            _cmd.emit({"kind": "move", "ids": _selected_ids(), "x": world.x, "y": world.y})
```

```gdscript
# logic/command_processor.gd（示意）
func apply(world: World, cmd: Dictionary) -> bool:
    match cmd.get("kind", ""):
        "move":     return _apply_move(world, cmd)
        "build":    return _apply_build(world, cmd)
        "demolish": return _apply_demolish(world, cmd)
        _:          return false
```

> 第 1 轮联机时，唯一的改动是：`view/` 发命令给网络层，网络层绕一圈服务器回来再进 `command_processor`。
> **`logic/` 完全不动。** 这就是现在花力气分边界的全部回报。

### 3.2 逻辑 → 渲染（每帧读状态）

`view/` 每帧从 `world` 读状态并同步到节点。两种做法，按对象数量选：

- **数量少且需要交互**（单位、建筑）：为每个逻辑对象持有一个 `Node2D`，`_process` 里同步位置/血量
- **数量多且不需要交互**（区块、地形）：一个节点画全部，例如 `zone_view.gd` 用 `_draw()` 画 24 个矩形

```gdscript
# view/unit_view.gd（示意：只读 + 只画，不改逻辑）
func _process(_dt: float) -> void:
    for u in _world.units:
        var node: Node2D = _nodes.get(u.id)
        if node == null:
            continue
        node.position = u.world_pos * CELL      # 逻辑坐标(格) → 屏幕像素
        node.visible = u.alive
```

**对象增删**：`world.units` 是权威列表；`view/` 只在**数量或 id 集合变化时**重建节点映射，
不要每帧 `queue_free()` 重建（HTML 版每次整表替换建筑的做法在 Godot 里会造成明显卡顿）。

### 3.3 快照（本轮：调试用；第 1 轮：网络包体）

```gdscript
# logic/snapshot.gd
static func to_snapshot(world: World) -> Dictionary: ...
static func apply_snapshot(world: World, snap: Dictionary, now_ms: int) -> void: ...
```

本轮就写、就测（往返一致、缺字段不炸），但**只用于调试与以后的存档/回放**。
字段名用短名（`i/f/k/x/y/h`）是为了第 1 轮省带宽，现在顺手做了。

**快照里不放的**：路径（`path`）、地形、相机、UI、日志。
理由见 [`route.md`](route.md) 第四节 —— 只发结果，不发过程。

---

## 四、坐标系与常量（**最容易出错的地方**）

### 4.1 两套坐标，一条换算

| 坐标 | 单位 | 用在哪 | 说明 |
|---|---|---|---|
| **逻辑坐标** | 格（`float`） | `logic/` 全部 | (0,0) = 地图左上角；一格 = 1.0 |
| **像素坐标** | px | `view/` 全部 | `像素 = 逻辑 × CELL_SIZE` |

- `CELL_SIZE` 默认 **64.0**（渲染常量，放 `config.json` 的 `render.cell_px`）
- 逻辑层的所有数值（速度、射程、警戒半径）**一律用格** ——
  改格宽只影响观感，不影响平衡（HTML 版把两者混在一起的教训）
- 单位半径 = `0.1` 格（HTML 版 `radiusFactor`），直径 0.2 格

```gdscript
# logic/grid.gd（示意）
static func tile_of(p: Vector2) -> Vector2i:
    return Vector2i(floori(p.x), floori(p.y))

static func center_of(t: Vector2i) -> Vector2:
    return Vector2(p.x + 0.5, p.y + 0.5)
```

### 4.2 必须继承 HTML 版的三条坐标约定

HTML 版为坐标错位吃过一次大亏（画面只画在左上角 1/dpr 区域，鼠标换算却按 CSS 像素）。
Godot 里 DPR 由引擎处理，**但下面三条要原样继承**：

1. **相机与输入换算用同一套屏幕坐标**：鼠标 → 世界一律走 `get_global_mouse_position()`
   或 `Camera2D.get_screen_center_position()`，不要自己手算一遍
2. **单位位置是连续浮点，不吸附格心**：`tx/ty` 只作为「所在地块」的缓存，用于占区块/射程/警戒判定
3. **点到哪走到哪**：右键目标是鼠标所指的世界坐标，不是格心；
   点到山/城墙/建筑时自动改走**最近的可达格**（且必须过滤「从起点真走得到」）

---

## 五、状态放哪（权威归属表）

**一句话：所有真实状态在 `logic/world.gd` 一棵树上，`view/` 只有缓存的节点。**

| 状态 | 归属 | 备注 |
|---|---|---|
| 地形、大本营坐标、出生点 | `logic/map_data.gd` | 只读，载入时建好 |
| 单位（位置/血量/路径/目标/冷却） | `logic/unit.gd` | 唯一权威 |
| 招募序号（新兵 id） | `logic/world.gd` | `_recruit_serial`，只增不减（否则 id 会撞名） |
| 建筑（类型/格位/所属/血量） | `logic/building.gd` | 用数组存，另建 `Vector2i → Building` 查询字典 |
| 建筑本体的尺寸（占一格的比例） | `data/config.json` → `building.<type>.body_scale` | 渲染与碰撞**共用**这一个数（`building.body_rect()` / `palette.building_rect()`） |
| 地图上预置的建筑 | `data/map_01.json` 的 `buildings` → `logic/map_data.gd` 的 `prefab_buildings` → `world.reset()` 放置 | 坐标与归属全在 JSON 里，代码不写死；不影响区块归属（zone 只认玩家阵营） |
| 区块（`owner` / `progress_by`） | `logic/zone.gd` | **每阵营独立进度**，不要退回单一 `progress` |
| 资源、己方地块数 | `logic/economy.gd` | |
| 相机 / 缩放 | `view/camera_rig.gd` | 纯表现，不进快照 |
| 选中列表 | `view/input_controller.gd` | 纯本地，**不进命令流**（第 1 轮也一样） |
| 玩家下达的攻击命令 | `logic/unit.gd` 的 `ordered_target` / `ordered_building` / `has_attack_move` | 与「这一帧在打谁」（`target` / `target_building`）**分开存**，见 route.md 12.3 |
| UI 几何（面板位置与尺寸） | `view/ui_layout.gd` | 纯常量，照参考图的像素稿；其它 view 文件不写坐标字面量 |
| 当前页签（单位 / 建筑） | `view/page_tabs.gd` | 纯本地显示状态，只决定命令卡里有什么 |
| 事件（击杀 / 建筑被拆 / 招募…） | `logic/world.gd` 收集 → `world.tick()` 返回 | **逻辑层不写 UI 文案**；当前没有界面显示它们（日志按需求删了，见 route.md 第十节） |
| 谁是房主 / 我的阵营 | 第 1 轮再加 | 本轮固定为单机阵营 |

> **建筑为什么不用 `TileMapLayer` 当权威**：一个地块只能有一个建筑，
> 用 `Vector2i → Building` 字典查询更快、更明确，也不会和地形的图块数据纠缠。
> 地形可以用 `TileMapLayer`（只读），但**通行性判定读 `map_data`，不读 TileMap** ——
> 否则图块换一张图就可能改变玩法。

---

## 六、测试脚手架

### 6.1 入口（已验证可行，见 [`pitfalls.md`](pitfalls.md) 第一节）

Godot 的 `--script` 要求脚本 `extends SceneTree`，框架会调 `_initialize()`：

```gdscript
# tests/test_smoke.gd
extends SceneTree

var _pass := 0
var _fail := 0

func _initialize() -> void:
    _test_grid_tools()
    print("通过 %d 项，失败 %d 项" % [_pass, _fail])
    # ★ 退出码是唯一的成败信号，必须显式分支写清楚。
    #   ⚠️ GDScript **没有** Python 那种 `a if cond else b` 三元表达式：
    #      写成 quit(1 if _fail > 0 else 0) 不会报错，但语义不对 —— 别抄。
    if _fail > 0:
        quit(1)
    else:
        quit(0)

func ok(cond: bool, what: String) -> void:
    if cond:
        _pass += 1
    else:
        _fail += 1
        printerr("  [FAIL] %s" % what)
```

**为什么退出码这么重要**：runner 靠退出码判定成败，而不是靠解析输出文本。
一旦退出码永远返回 0，整套测试就变成了"永远绿灯"的摆设 —— 这比没有测试更糟。

### 6.2 为什么要套一层 runner

`tests/` 会变成七八个文件，逐个敲命令行容易漏（HTML 版的 `run-all-tests.py` 就是为这个写的）。
所以做一个 `tools/run-tests.ps1`：遍历 `tests/test_*.gd` 逐个跑，汇总「N 个文件 / M 项断言 / 失败 K」。

**顺带解决一个已知问题**：HTML 版的 runner 在中文 Windows 上因为控制台是 GBK、
脚本却打印 `✔` 而**直接崩掉**。Godot 这边同理 —— runner 里显式设置 UTF-8 输出
（`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`），别用 emoji，用 `OK` / `FAIL`。

### 6.3 集成测试（本轮不做，第 1 轮再考虑）

「无头跑真实主循环 N 帧再断言世界状态」这条路**已验证技术上可行**
（`_process` 在无头下会被真实调用，`Camera2D` 等类也存在），
但有一个坑：`_initialize()` 里 `root.add_child()` **静默失效**，必须 `await process_frame` 之后才能挂节点。
本轮 M0~M5 用纯逻辑断言 + 手玩验收即可，不引入这层复杂度。

---

## 七、命名与风格

- 文件与变量 `snake_case`，类名 `PascalCase`（Godot 官方风格，与 HTML 版的 `camelCase` 不同）
- **不写 `class_name`**：实测 `--script` 模式下全局类名表不可用（没有编辑器缓存），
  所以跨文件引用一律用**每个文件顶部的 preload 常量**，例如
  `const PathfinderRes = preload("res://logic/pathfinder.gd")`。
  详见 [`pitfalls.md`](pitfalls.md) 1.5.3 —— 那里有完整的「哪种写法能用、哪种不能」对照表。
  类名只在注释里出现，用来指代「哪个文件」。
- 逻辑层的类没有 `Node` 血缘（`RefCounted`），所以**不能用 `class_name` 之外的 Godot 反射**，
  这也正是它能在无头测试里跑起来的原因
- **注释写「为什么」，不写「是什么」** —— HTML 版最有价值的部分就是
  「这个坑当时是怎么踩的」那些注释（例如「这里必须传 force，否则基地被打爆还立着」）。
  迁移时**把这些注释一起搬过来**，见 [`porting.md`](porting.md) 第五节的搬运清单
