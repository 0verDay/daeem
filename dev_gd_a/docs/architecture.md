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
5. **C# 内核（`logic/crowd/*.cs`）与 `logic/` 同规矩**：不碰场景树、不读输入、不存游戏数值。
   它是「同一层逻辑换了个语言」，不是表现层。另外两条引擎硬要求：
   · **文件名必须等于类名**（PascalCase），所以那一层的文件名与 GDScript 的 snake_case 不同；
   · 跨语言调用**必须按批**：实测 1000 次小调用 = 518 µs/帧，1 次批量 = 4.8 µs/帧（差 108 倍），
     所以 `logic/crowd/` 的接口一律收发整条 Packed 数组，不做「每个单位调一次」。
6. **`view/` 每帧只允许发命令，不允许逐单位写逻辑状态**；单位数量到 1000 之后，
   「每个逻辑对象配一个 Node2D」这条老做法不再成立（见 3.2）
7. **`config.json` 的可调数值读 `Config` 上「载入时算好」的字段，不要用 `cfg.num("a.b.c")`**。
   `num()` / `bool_val()` 每次都要 `split(".")` + 逐层下潜，而这些值出现在**每帧每单位**的
   内层循环里（碰撞半径、推力权重、认账时间、地形代价…）。1000 单位下实测这一项就是
   每帧几万次字符串切分。
   · 加新数值：在 `config.json` 里加，同时在 `config.gd` 的 `_cache_scalars()` 里加一行；
   · **载入之后 `cfg.data` 不再是权威** —— 测试要改开关请直接改字段
     （例如 `cfg.path_diagonal = false`），改 `cfg.data[...]` 不会有任何效果；
   · `map_data.is_forest()` / `terrain_cost()` 读的是**地形掩码**，
     手改 `map.terrain` 之后必须调 `map.rebuild_terrain_masks()`

---

## 二、目录结构

```
dev_gd_a/daeem/
├── project.godot                 # 已就绪（4.7 / Forward Plus / D3D12）
├── icon.svg
├── data/                         # ★ 纯数据，不含代码
│   ├── config.json               #   全部可调数值（对应 HTML 版 js/config.js）
│   └── maps/                     #   ★ 地图：**一个地图一个目录**，目录名就是地图的 id
│       ├── frontier/map.json     #     随游戏发布的默认地图（地形 / 区划网格 zones /
│       │                         #     区划中心 zone_centers / 区划种类 zone_list[].kind /
│       │                         #     区划产能 zone_list[].production（游戏以它为准）/
│       │                         #     人口上限 zone_list[].population_cap（没填 = 1）/
│       │                         #     各阵营大本营 faction_bases / name = 选择条上的显示名）
│       └── arena/map.json        #     占位图（只为证明「多一个目录 = 多一个选项」）
│                                 #   ★ `allies`（阵营归属，本轮新增）：`[["enemy","ai"]]`
│                                 #     表示这两方是**同方**（不互相攻击 / 不争夺同一区划）。
│                                 #     是**地图数据**，所以只有写了它的那张图生效。
├── logic/                        # ★ 纯逻辑：extends RefCounted，禁止碰场景树
│   ├── grid.gd                   #   网格工具 + 索引换算 + 方向集（DIRS4/DIRS8/octile）
│   ├── pathfinder.gd             #   A*（四连通或八方向）+ segment_clear（超覆盖 DDA）
│   │                             #   + smooth_path（拉直）+ round_corners（拐角圆化）
│   ├── faction.gd                #   阵营模型：is_player_faction / same_side / is_ai_faction
│   │                             #   ★★ 阵营归属（盟友，本轮新增）：`allies` 表 +
│   │                             #     `allied()` / `same_side_for_attack()`（攻击口径 =
│   │                             #     同阵营或盟友）/ `side_of()`（同一方的代表 id，
│   │                             #     占领判定用它把盟友算成一方）。关系来自**地图数据**
│   │                             #     （`map.json` 的 `allies`，见 route.md 第三十六节）。
│   │                             #     ⚠️ `same_side` **不看**盟友：它还管建筑通行与寻路
│   ├── map_data.gd               #   载入地图（地形 + exists 存在格 + zones 区块网格）、连通性修正
│   │                             #   + ★ 预置单位可带 `zone`（归属区划，给防御性 AI）
│   │                             #   + ★ `zone_list[].owner`（开局归属）+ set_faction_base()（config 给的基地）
│   ├── map_library.gd            #   ★ 扫 data/maps/ 列出所有地图（开场主界面那条**地图选择条**的
│   │                             #     唯一数据源）：目录名 = id，地图 json 的 name = 显示名
│   │                             #     → 加一张图 = 加一个目录，不改代码、不改配置
│   ├── unit.gd                   #   单位：移动 + 战斗 + 警戒 + 复活（本轮不做复活）
│   │                             #   + ★ 招募队列（将领自己就是兵营：train_* 字段）
│   │                             #   + ★ 驻防 AI 的字段（garrison_zone_id / patrol_timer /
│   │                             #     combat_idle_timer / retarget_cd）+ retinue_size()
│   ├── building.gd               #   建筑定义与实例：blocks(faction) / 血量
│   ├── zone.gd                   #   区块占领（每阵营独立进度）+ 区划中心 / 人口 / 产能；
│   │                             #   ★ 区划**种类**（kind：粮食 / 黄金 / 人口）只决定能做哪些特化，
│   │                             #     产量永远以地图 zone_list[].production 的数字为准
│   │                             #   区块划分读地图的 zones 网格，老地图退回 6×4 均分占位
│   │                             #   + ★ apply_initial_ownership()（地图写的开局归属）
│   ├── economy.gd                #   资源产出 + 扣费（can_afford / spend / try_spend）
│   │                             #   ★ 池子是 null ⇒「这一方没有资源库 = 资源无限」
│   ├── tech.gd                   #   ★ 科技：占位表（config.tech.list）+ 每阵营的启用状态
│   │                             #     + 效果聚合（每地块加产量 / 血量倍率 / 人口增长倍率）
│   │                             #     规则：同一时间最多启用 config.tech.max_active 条
│   ├── fog.gd                    #   ★ 战争迷雾：**按阵营**算「谁能看见哪一格」
│   │                             #     · 视野半径是**两张对称的类型表**：
│   │                             #       `unit.types.<id>.vision`（将领可被
│   │                             #        unit.general.stats[i].vision 覆盖）与
│   │                             #        `building.<type>.vision`
│   │                             #       —— 没写那个键各自退回 fog.vision_default /
│   │                             #        fog.vision_building，在 create() 时抄进
│   │                             #        u.vision / b.vision
│   │                             #     · 视线被**山脉**挡住（其他地形不挡），走 DDA 视线
│   │                             #     · 敌方**建筑**「见过一次就永久记住」（被摧毁才忘），
│   │                             #       敌方**单位**只显示当前视野内的（不保留记忆）
│   │                             #     · **只影响显示**：战斗 / 索敌 / 寻路 / 占领都不看它
│   │                             #     · 性能：按格缓存视野扇区 + 没变化就不重算
│   ├── upgrade.gd                #   ★ 建筑升级 + 区划特化（右下「操作」页里那几格）
│   │                             #     升级：等级 1→N（config.upgrade.levels），血量上限 ×倍率
│   │                             #     特化：粮食 / 黄金 = 每地块每秒 +0.5；人口 = 本区划人口产量 ×1.25；
│   │                             #     能做哪几档由**区划种类**（config.zone_kind.list[].specs）决定
│   │                             #     两者都是**读条**（复用招募那块面板）、入队即扣费、可取消退款
│   ├── combat.gd                 #   战斗结算与事件（索敌 / 开火 / 拆建筑）
│   ├── garrison_ai.gd            #   ★★ **阵地性 AI**（本轮重做；原 general_ai.gd）：
│   │                             #     附属在一个**区划**下（state 挂在单位身上），
│   │                             #     在归属区划里按间隔巡逻、不追出一个区划（追出去当场脱战 + 再战冷却），
│   │                             #     脱战满 combat_idle_sec 且不满员时**无消耗**招兵（free = true）
│   │                             #     —— ★ 补员**兵种按将领自己的规格权重**抽（_pick_recruit_kind）；
│   │                             #     将领濒死且血量回门槛 → **无消耗立刻再起**（_tick_revive）
│   ├── red_dot_ai.gd             #   ★★ **红点性 AI**（本轮重做为**函数式时间表**）：
│   │                             #     第 x 波的生成时间由 wave_time_expr（y=ax+b，分钟）给出、
│   │                             #     将领数由 general_count_expr 给出；将领类型按 general_weights 抽；
│   │                             #     每位将领**当场**生成 escort_count 个随机附属兵；生成地点优先
│   │                             #     spawn_tiles（关卡选中的地块）→ spawn_region → 出生点；
│   │                             #     再带整队向 attack_target 行军（order_group_attack_move）
│   ├── expr.gd                   #   ★★ **线性表达式** `y = a·x + b` 的解析 / 求值（红点时间表用）
│   ├── command_processor.gd      #   ★ 命令的唯一入口（move / build / demolish）
│   ├── snapshot.gd               #   ★ to_snapshot / apply_snapshot（本轮用于调试，将来是网络包体）
│   ├── crowd/                    #   ★ 群体碰撞的 C# 内核（1000 单位群编的性能前提）
│   │   ├── CrowdKernel.cs        #     空间哈希 + 软分离 + 本体推出（语义与 collision.gd 一致）
│   │   ├── CrowdProbe.cs         #     跨语言通路探针（桥测试用）
│   │   └── crowd_bridge.gd       #     ★ logic ↔ 内核的**唯一**接口：建表 + 批量编解码 + 回退
│   └── world.gd                  #   世界容器：持有 units / buildings / zones / tech / upgrade，
│                                 #   推进 tick()；★ 也持有 AI 的权威状态
│                                 #   （`ai_roster_cfg` / `reddot_states` / `with_ai`）
├── daeem.csproj                  # C# 工程（Godot.NET.Sdk）。★ 引擎必须用 mono(.NET) 版
├── NuGet.config                  # 本地包源（引擎自带 nupkgs；本机没有外网到 nuget.org）
├── view/                         # 渲染：Node2D / Control，禁止改逻辑状态
│   ├── main.tscn / main.gd       #   入口场景：白屏入场页 → 主界面（地图选择条 + test）→ 游戏内场景；
│   │                             #   ★ 只做连接：把「按下 test + 选了哪张地图」翻译成 game_scene.start(那张图)
│   ├── start_screen.gd           #   ★ 开场两页（白底，不走 ui_style）：入场页的呼吸提示 +
│   │                             #   主界面那条**地图选择条**（选项来自 logic/map_library.gd 扫目录）
│   ├── map_select.gd             #   ★ 地图选择条本体（**自己画的按钮 + 自己的 PopupMenu**）：
│   │                             #   不用引擎 OptionButton —— 点开列表后按钮上那行字会变空白
│   │                             #   （实测，见 route.md 34.9）；对外 API 与 OptionButton 同名同义
│   ├── game_scene.gd             #   **2D 遗留栈**的游戏内场景：装配 world + view + hud，跑主循环
│   │                             #   （★ 真机入口**已经是 3D** 的 `game_scene3d.gd`，见下一行）
│   ├── game_scene3d.gd           #   ★★ **真 3D 游戏内场景**：装配 world + 3D 视图 + HUD，
│   │                             #      跑主循环（`Camera3D` 固定俯角，只平移 / 缩放）
│   ├── game_interaction.gd       #   ★ 与渲染无关的交互核心（事件提示 / 命令卡派发）：**已抽出**，
│   │                             #      并且**已被 3D 场景委派使用**；2D 那份仍是自己的实现（遗留项）
│   ├── ground_view.gd            #   3D 地面：一整块 `PlaneMesh` + 一张烘出来的地形贴图；
│   │                             #      **迷雾是另一块平面**（两层各 1 次 draw call）
│   ├── unit_view_3d.gd           #   3D 单位：`MultiMesh` 按「阵营 × 是否将领」分桶 + billboard
│   ├── unit_sprite_3d.gd         #   程序化兵人立牌贴图（SDF 光栅化，按变体缓存）
│   ├── building_view_3d.gd       #   3D 建筑：`MultiMesh` + `BoxMesh`（★ 视觉高度 ≠ 逻辑高度）
│   ├── overlay_view_3d.gd        #   3D 版的覆盖层（屏幕空间：选中圈 / 标记 / 拖框 / 建造预览）
│   ├── palette.gd                #   ★★ 坐标换算的**唯一**出处（3D 版）：**实例类**，持有 `Camera3D`；
│   │                             #      `to_px` = `unproject_position`、`to_logic` = 地面射线求交
│   │                             #      ⇒「格 ↔ 屏幕」的正反两面由**同一台相机**导出
│   ├── palette2d.gd              #   ⚠️ **只服务 2D 遗留栈**的老静态签名；新 3D 代码不许 preload 它
│   ├── terrain_view.gd           #   地形（TileMapLayer）
│   ├── fog_view.gd               #   ★ 战争迷雾的**灰色遮罩**（本版新增）：把 logic/fog.gd
│   │                             #     算出来的视野掩码烘成「1 像素 = 1 格」的贴图，
│   │                             #     一次 draw_texture_rect 铺满地图（与格数无关）
│   │                             #     ⚠️ 它只管「盖灰」；「谁不该被画出来」由各视图自己
│   │                             #       问 fog.unit_visible / building_visible
│   ├── building_view.gd          #   建筑（Node2D + 血条 + 受击闪光）
│   ├── unit_view.gd              #   单位（Node2D + 血条 + 交战标记）
│   ├── unit_icon.gd              #   ★ 单位在地图上的 2D 图标（线条「预制体」+ 烘成贴图）
│   │                             #     按（单位类型 × 是否将领）一张图；将领的描边更粗
│   ├── zone_view.gd              #   区块轮廓 + 占领进度
│   ├── overlay.gd                #   攻击线 / 建造预览 / 移动标记（**不画**选中范围圈）
│   ├── camera_rig.gd             #   相机：方向键平移 / 边缘滚屏 / 光标锚点缩放
│   ├── input_controller.gd       #   ★ 输入 → 命令（唯一允许读鼠标的地方）
│   │                             #     + 左侧键**框选**那条状态机（按下 → 移动 → 松开，见 route.md 16.3）
│   ├── ui_layout.gd              #   ★ UI 的全部几何常量（照参考图的像素稿）+ 贴边规则
│   ├── ui_style.gd               #   UI 配色与 StyleBox 工厂
│   ├── hud.gd                    #   UI 装配：左部队列表 / 左下地图占位 / 底栏 / 右上设置
│   │                             #   ★ 右上设置点开是**二级菜单**（全屏 / 返回主菜单）：
│   │                             #     面板只发两个信号，执行在 view/main.gd
│   │                             #     （窗口模式与整个流程都归它管）
│   │                             #     ★ 也是**界面词**的唯一出处（拒因码 → 中文、悬停详情文案）
│   ├── hover_tip.gd              #   ★ 悬停详情面板（本版新增）：住在**命令卡正上方**，
│   │                             #     水平范围 = 命令卡 + 右边那一列页签那一整段
│   │                             #     （**左缘对命令卡左缘、右缘对页签列右缘**，宽 340），
│   │                             #     高度按悬停到的文本**动态缩放**（向上长，下缘离命令卡 8px）
│   │                             #     ⚠️ 高度**只问 Label 自己**（get_minimum_size），
│   │                             #     不许拿 Font.get_multiline_string_size 顶替（见 pitfalls 5.52）
│   │                             #     文案由 hud 喂（`_hover_detail`），本控件只排版与画
│   ├── squad_panel.gd            #   左侧「部队 1~10」（动态生成，点了只选中）
│   ├── detail_panel.gd           #   ★ 底栏「详细信息」：**左右两栏**（第四轮改版）
│   │                             #     左 = view/unit_roster.gd（上）+ view/troop_grid.gd（下）
│   │                             #     右 = 选中单位头像 / 名称 / buff 占位 / 数值 + 招募五格
│   ├── unit_roster.gd            #   ★ 左栏上半：**当前展开 / 唯一选中那支部队的将领格**
│   │                             #     （40×40 方框 + 右边一行「将领名称 x/y」；只有这一格）
│   ├── troop_grid.gd             #   ★ 左栏下半：**3×3 = 9 格的网格**，两种语义共用
│   │                             #     多选 → 其余部队的将领（点一格 = 换展开哪一支）
│   │                             #     单选 → 这支部队的单位（点一格 = 右栏切到那个单位；
│   │                             #             超过 9 个用滚轮翻页，一次一页）
│   ├── recruit_queue.gd          #   ★ 右栏右上角那块面板：招募队列（1 大 + 4 小 + 读条）
│   │                             #     可点：点某一格 = 取消那一格（发 *_cancel 命令）
│   │                             #     ★ 也用来显示**单条读条**（建筑升级 / 区划特化，
│   │                             #       见 set_bar()：需求要的「复用招募单位的面板」）
│   ├── command_card.gd           #   右下 3×3 命令卡（内容随页签切换）
│   │                             #     ★ 每格还报 `cell_hovered / cell_unhovered`（鼠标悬停），
│   │                             #       hud 收到后弹 hover_tip —— **不报内容，只报第几格**
│   ├── tech_grid.gd              #   ★ 右下 3×3 科技九格（**盖在命令卡上**，只有「科技」页显示）
│   │                             #     九条占位科技来自 config.json 的 tech.list；
│   │                             #     已启用 = 实心蓝高亮；点一下 = 启用 / 弃用（发 tech_toggle）
│   └── page_tabs.gd              #   右下那一列**动态页签**（按选中对象决定显示哪几颗：
│                                 #     部队 = 操作/单位，**所有建筑 = 操作**（+ 大本营的科技 /
│                                 #     区划中心的招募），什么都没选中 = 建筑 + 科技）
└── tests/                        # 无头断言测试（不进游戏包）
    ├── test_smoke.gd             #   脚手架自检 + 网格工具
    ├── test_logic.gd             #   玩法规则（移动 / 战斗 / 建造 / 占领 / 快照…）
    ├── test_view.gd              #   渲染层接线（能挂上树、跑帧不炸、中文字体）
    ├── test_ui.gd                #   ★ 新 UI：几何对着参考图、部队列表 / 命令卡 / 招募 / 右键手势 /
    │                             #     **悬停详情面板**（命令卡 + 页签列那一段的宽 + 下缘 + 按文本长高 + 折行不被裁 + 换页收起）
    │                             #     ⚠️ 它必须在 **GameScene**（按下 test 之后那个）上断言 ——
    │                             #     在 main.tscn 的根上取 hud 会报错并静默跳过整节（pitfalls 5.35）
    ├── test_attack_orders.gd     #   ★ 攻击命令：点名打单位 / 建筑、行军攻击、索敌建筑
    ├── test_zone_capture.gd      #   ★ 占领进度显示：无主 / 我的地 / 别人的地 三种情况
    ├── test_recruit_queue.gd     #   ★ 招募队列：消耗 / 人口 / 队列上限 5 / 读条 10 秒 /
    │                             #     格心生成 + 排开 / 区划限制 / 读条期间钉住 / 阵亡退款 / 快照
    ├── test_tech.gd              #   ★ 科技：九条占位铺满 3×3 / 启用与弃用 / 最多同时 3 条（第 4 条被拒
    │                             #     + tech_rejected 事件）/ 三类效果（每地块加产量、建筑与将领
    │                             #     血量倍率实时生效、己方区划人口增长 +10%）/ reset 清零 / 命令层
    ├── test_upgrade.gd           #   ★ 建筑升级 + 区划特化：等级表与血量倍率 / 入队即扣费 / 读条 /
    │                             #     取消退款 / 满级封顶 / 「特化只能选一个」/ 取消特化也要读条 /
    │                             #     特化只影响本区块且与科技叠加 / 命令层
    ├── test_map_editor.gd        #   ★ 地图编辑器导出的地图：exists 存在格（地图外不可通行）
    │                             #   + zones 区块网格（非矩形区块、空区块保留）
    ├── test_ai.gd                #   ★★ 两种 AI（本轮新增）：阵营 AI（自己的资源库 / 资源随
    │                             #     占领区划增长 / 资源倍率 / 招将 → 招兵 → 升级 → 出兵）
    │                             #     + 将领性（防御性）AI（归属区划巡逻 / 不追出一个区划 /
    │                             #     脱战 10 秒无消耗招兵）+ 两条 AI 判据互斥（133 项）
    ├── test_unit_editor.gd       #   ★ 单位编辑器改的那些数**游戏侧真的读**：建筑定义（config 优先）
    │                             #     / 建造读条（读条不开火、读完开火、开局 instant）/ 逐级攻击 /
    │                             #     将领独立数值 / 新建筑能建能打 / 建造页读 config
    ├── test_building_body.gd     #   ★ 建筑本体：尺寸居中、挡敌不挡己、缝隙能穿、城墙回归
    └── test_fog.gd               #   ★ 战争迷雾（本版新增）：合成地图上的视野规则（山脉挡视线 /
                                  #     森林不挡 / 半径边界 / 按阵营各算各的 / 建筑给视野 /
                                  #     中立障碍不给）+ 敌方建筑「见过就永久记住、摧毁才忘」+
                                  #     敌方单位不保留记忆 + 灰色遮罩的掩码与贴图 +
                                  #     真地图上「迷雾里的敌人点不中」+ 没变化就不重算
```

**地图编辑器**在 `dev_gd_a/tools/map_editor/`（Python + tkinter，**不在游戏包里**，
只是往 `data/` 里写 JSON）：见 [`../tools/map_editor/README.md`](../tools/map_editor/README.md)。

**单位编辑器**在 `dev_gd_a/tools/unit_editor/`（同样是 Python + tkinter、同样不在游戏包里）：
它写的是 `data/config.json`（单位 / 将领 / 建筑 / 科技的全部数值，含本轮新增的**将领编制上限**
`unit.general.caps` —— 战役编辑器里配的附属单位生成数量以它封顶）。
两个工具的分工：地图编辑器管**地形与区划**（`data/maps/<id>/map.json`），
单位编辑器管**数值**（`config.json`）。
见 [`../tools/unit_editor/README.md`](../tools/unit_editor/README.md)。

**地图目录的约定（一个地图一个目录）**：`data/maps/<id>/map.json`，目录名就是地图的 id；
地图 json 里可选的 `name` 是开场主界面那条**地图选择条**上显示的名字（没写就用目录名）。
★ 选择条的选项由 `logic/map_library.gd` **扫目录**得出（不是配置里列的清单），
所以**加一张地图 = 加一个目录**：代码、`config.json`、选择条都不用动。
`id` / `name` 两个字段编辑器不编辑，但会原样带过去（见 `tools/map_editor/mapfile.py` 的
`PRESERVED_KEYS`）。

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

> ★★ **1000 单位那档已经把上面第一条改掉了**：`unit_view.gd` 现在是「一个 CanvasItem 画全部」，
> 而且单位本体走**贴图**而不是 `draw_circle / draw_arc` —— 实测那两个 API **完全不参与 2D 合批**
> （`draw_circle ×1000 → 997 个 draw call、18.4 ms`），换成同一张贴图之后 1000 个单位合成一个批次；
> 绘制命令还要**按图元类型 / 按贴图分组**（同一类连着画才合得了批）。
> 单位图标（`unit_icon.gd`）也是按这条走的：线条画的「预制体」**烘成十来张贴图**，
> 而不是每个单位一个节点 / 一个场景 —— 理由见 [`route.md`](route.md) 26.4。

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

### 4.3 ★★ 真 3D 场景：第三套坐标（世界是 `y = 0` 的平面，投影交给引擎）

**逻辑格一个都没变**，变的是「格 → 屏幕」这一步：它现在由一台**真实的 `Camera3D`** 给出。

> ⚠️ 本节原先写的是那一版 **2.5D 纵向压扁**（`ContentRoot.scale = (1, squash)`）。
> 它后来被**连续推翻两次**（菱形等距 → 手算真透视），最终落到真 3D ——
> 每次「为什么当初那么做、后来为什么推翻」记在 [`route.md`](route.md) 四十一节，
> 设计与实测记在 [`../dev_plan_9.md`](../dev_plan_9.md)。

| 名字 | 定义 | 谁用 |
|---|---|---|
| 逻辑坐标（格） | 一格 = `1.0`，`(0,0)` = 左上角 | `logic/` 全部、`data/maps/*.json`、**所有单位位置 / 半径 / 射程** |
| 世界坐标（3D） | 逻辑格 `(x, y)` → 世界点 `(x · cell_px, 0, y · cell_px)`：地面是 `y = 0` 的水平面 | `Node3D` 节点的摆放（地面 / 单位 / 建筑） |
| 屏幕像素 | 相机把世界点投到视口上（左上角为原点） | `CanvasLayer` 上的覆盖层与 HUD（用 `palette.to_px` 定位） |

- ★★ 换算**只有** `view/palette.gd` 一处，而且它是个**实例类**（`PaletteRes.create(cfg, cam)`）：
  `to_px` = `cam.unproject_position(世界点)`；`to_logic` = `cam.project_ray_normal()` 与地面求交。
  **正向与逆向由同一台相机导出** ⇒ 不存在「画用一套、鼠标换算用另一套」（pitfalls 3.1）。
- ★★ **为什么投影交给引擎**：手算那版要自己维护四个投影量（`proj_a / proj_b / proj_zero_y / proj_offset`），
  改任何一处都得重推公式，而且出过两个真问题 ——
  「向下滑动时地块越来越大」与「拖框起点在相机移动时自己漂」。
  交给引擎之后，投影 / 求交 / 相机数学**只有一份实现**。
  ⚠️ 这条的代价是：**相机必须先真的进场景树**（否则没有视口，投影 API 全部退化成零值，见 pitfalls 10.3）；
  `far` 也必须跟着相机距离走（默认 4000，见 pitfalls 10.1）。
- ★ 相机**不俯仰旋转**（俯角由相机位置表达），平移只沿世界 X / Z
  ⇒ 同一个格在任何位置看到的**屏幕尺寸完全相同**。
  ★ 透视仍然在（近大远小：同一格在画面下方更大，实测 y=2 行 → y=20 行是 **1.28 倍**），
  但「尺寸随相机移动而变」这件事从根上不存在。
- ★★ **覆盖层与「字 / 血条」留在屏幕空间**（`CanvasLayer` 上的 `Control`），用 `to_px` 定位：
  天然 1:1、不受透视影响、也不必为每个标记建 3D 节点。
  ⚠️ **透视下一个格在屏幕上不是矩形而是梯形** ⇒ 必须**逐个角投**；
  `tile_poly` / `quad_poly` / `building_poly` 返回的是**四个点**，不是 `Rect2`
  ——「只投中心再套一个矩形」在 3D 下四角都是错的。
- ★ **地面是一整块 `PlaneMesh` + 一张烘出来的贴图**（网格线与区块归属是**贴图上的像素**
  ⇒ 天然连续，不可能出现「斜着的区块线互相穿插」）；
  **迷雾是另一块平面 + 另一张贴图**（它每帧都在变，而地形图只在归属变化时重烘），两层各 1 次 draw call。
- ★ 单位与建筑各自用 `MultiMesh` 合批：单位按「**阵营 × 是否将领**」分桶
  （`MultiMesh` 不支持逐实例贴图 ⇒ 变体数 = 阵营数 × 2，本项目是个位数），立牌用材质自带的 billboard；
  建筑是一个单位 `BoxMesh` 靠**逐实例非等比缩放**表达尺寸差异。
- ★ **视觉高度 ≠ 逻辑高度**：建筑的 3D 高度是**纯表现**常量（`render.building_height.<type>`），
  寻路 / 碰撞 / 攻击一律读 `logic/building.gd` 的 `body_scale`（一格里的**平面块**）。
  `logic/` 里没有、也不会加「高度」字段；单位也**不投阴影**（材质 `SHADING_MODE_UNSHADED`）。
- ★ **HUD 整个复用 2D 那版**：它是 `CanvasLayer` 上的 `Control`，本来就不吃 3D 变换；
  它对世界的唯一依赖是「通过 `camera_rig` 知道我现在看的是哪一块」⇒
  把 `camera_rig` 换成一个 3D **替身**（`center_on_px` / `get_viewport_rect` / `cam`）就够了。
- ★★ **入口现状**：`view/main.tscn` → `view/main.gd` **已经切到 3D**
  （`GameSceneRes = res://view/game_scene3d.gd`），全套 **38 文件 / 5338 项 / fail 0**。
  ⚠️ 这一步**不是「改一行 `preload`」**：从「只切 preload」（85 项失败）到全绿一共走了 **8 步**，
  每一步都在补一个**视图层交互接口** —— 主循环的暂停门、`_unhandled_input` 的「先问 HUD」、
  `_consume_events` 命名对齐、`level_playing` / `level_campaign`、开局自动选中……
  完整曲线记在 route.md 四十一节与 [`../dev_plan_9.md`](../dev_plan_9.md) 6.1。
  ★ 另外 `main.gd` 那个字段必须退到 `Node`（原本标 `Node2D`，装不下 `Node3D` ⇒
  整个 `main.gd` 载不进来、主界面起不来，见 pitfalls 10.8）。
  ★ `view/game_interaction.gd`（与渲染无关的交互核心）**已抽出、已被 3D 使用**；
  2D 那份仍是自己的实现 ⇒ 「两边共用一份」是遗留项。
- ⚠️ **2D 遗留栈还在仓库里**（`game_scene.gd` / `camera_rig.gd` / `terrain_view.gd` / `zone_view.gd` /
  `fog_view.gd` / `overlay.gd` / `unit_view.gd` / `building_view.gd` / `minimap.gd`），
  它们仍用自己那套 2D 换算，出处是 **`view/palette2d.gd`**（老静态签名）。
  ★ 新写的 3D 代码一律不许 `preload` 它 —— 要用投影就走 `view/palette.gd` 的实例 API。
- 取舍、里程碑与真踩到的坑：见 [`../dev_plan_9.md`](../dev_plan_9.md) 与 [`route.md`](route.md) 四十一节。

---

## 五、状态放哪（权威归属表）

**一句话：所有真实状态在 `logic/world.gd` 一棵树上，`view/` 只有缓存的节点。**

| 状态 | 归属 | 备注 |
|---|---|---|
| 地形、阵营大本营坐标、出生点 | `logic/map_data.gd` | 只读，载入时建好；老式「单数 base」只作兼容兜底（见 route.md 14.3） |
| 单位（位置/血量/路径/目标/冷却） | `logic/unit.gd` | 唯一权威 |
| 招募队列（`train_kind` / `train_remaining` / `train_queue` / `train_anchor`…） | `logic/unit.gd` | ★ **将领自己就是兵营**，队列挂在它身上（它死了队列就没）；读条期间它被钉在 `train_anchor` 上，位置由 `world._pin_training_leaders()` 每帧摁回去；★ 它**和它辖下的部队**都不接玩家指令（`world.is_order_locked()` 是唯一判据） |
| 招募序号（新兵 id） | `logic/world.gd` | `_recruit_serial`，只增不减（否则 id 会撞名） |
| 建筑（类型/格位/所属/血量） | `logic/building.gd` | 用数组存，另建 `Vector2i → Building` 查询字典 |
| 建筑本体的尺寸（占一格的比例） | `data/config.json` → `building.<type>.body_scale` | 渲染与碰撞**共用**这一个数（`building.body_rect()` / `palette.building_rect()`） |
| 地图上预置的建筑 | `data/maps/frontier/map.json` 的 `buildings` → `logic/map_data.gd` 的 `prefab_buildings` → `world.reset()` 放置 | 坐标与归属全在 JSON 里，代码不写死；不影响区块归属（zone 只认玩家阵营） |
| 区块（`owner` / `progress_by`） | `logic/zone.gd` | **每阵营独立进度**，不要退回单一 `progress` |
| 区划**中心** / 产能 / 人口 / **人口上限** | `logic/zone.gd`（区块字典的 `center` / `production` / `population` / `population_cap`）；中心那一格上另有一栋 `TYPE_ZONE_CENTER` 建筑 | 中心、产能与**人口上限**都来自地图 JSON（上限缺字段 = 1，见 route.md 16.1）；人口是**运行时累积**的，每区划各算各的，**涨到上限就停**（见 route.md 14.5 / 16.1）；目前**唯一的消耗**是招募（每个单位扣将领所在区划 1 人口） |
| 资源、己方地块数 | `logic/economy.gd` | 招募的扣费**不受** `economy.enabled` 影响（那个开关只管建造免费） |
| ★★ **各阵营的资源库** | `logic/world.gd` 的 `resource_pool_for(faction)` | ★ 本轮口径：**AI 阵营没有资源库**（旧的 `ai_resources` 已删）—— 非本机席位一律返回 **null = 资源无限**（招募 / 再起 / 红点刷兵都不花钱）。只有玩家席位走 `resources` / `player_resources`（「谁下单、扣谁的钱」的唯一判据，见 route.md 33.4） |
| ★★ **红点 AI 的状态** | `logic/world.gd` 的 `reddot_states[]`（每项 `{faction, params, spawn_region, elapsed, wave_index, waves_cap, serial}`），规则在 `logic/red_dot_ai.gd` | 它是**世界状态**（与 `tech.active_by_faction` 同源），不是界面状态。`setup()` 在 `world.reset()` 末尾建；每帧 `red_dot_ai.update()` 推进（累计时间 ≥ `wave_time_expr(第 n 波)` 就发一波，一帧可补发多波） |
| ★★ **将领的附属单位规格（本轮新增）** | `logic/unit.gd` 的 `retinue_target`（目标编队规模）+ `retinue_types`（`[{type, weight}]`），规则在 `logic/world.gd` 的 `fill_general_retinue()` / `pick_weighted_type()` | ★ 挂在**将领单位自己**身上：摆放时按关卡 `escort_count` / `escort_types` 写入并**当场生成满编随机附属兵**；阵地补员按同一份权重抽兵种；`world.escort_target_of(fid, index)` 读它（没设过才退回 `ai.garrison.min_retinue`）。权重抽样的随机种子由 `(将领 id, 序号)` 派生（确定性，可复现） |
| ★★ **阵地性 AI 的状态** | `logic/unit.gd` 的 `garrison_zone_id` / `patrol_timer` / `combat_idle_timer` / `retarget_cd` / `garrison_recruit_timer`，规则在 `logic/garrison_ai.gd` | ★ 挂在**单位自己**身上（与 `train_*` 同一个理由：它天然属于某个将领，单位没了状态就该没）。它**不**在 world 上另开一张表，也**不**进任何资源库 |
| ★ AI 阵营的名单与出生锚点 | `data/config.json` 的 `ai.factions[]`（`{id, ai, base}`，ai 缺省 = `garrison`） | 名单决定「谁由 AI 驱动」；★ 本轮 AI **没有大本营、没有资源库** —— `base` 只是**出生锚点**（`_register_config_bases()` 不看 `with_ai`），将来算将领站位用；名单里的一方若没有点位会落到 (0,0) 顶掉区块 11 的中心（route.md 33.5 坑①） |
| ★ 地图里 NPC 阵营的开局归属 | `data/maps/frontier/map.json` 的 `zone_list[].owner` → `logic/map_data.gd` 的 `zones_owners` → `logic/zone.gd` 的 `apply_initial_ownership()` | 玩家那一方的地靠出生点大本营自动收归（`refresh_building_ownership`），那条**只认玩家阵营** —— 所以 NPC 的地必须能在地图里直接写出来 |
| ★ 这一局开不开 AI | `logic/world.gd` 的 `with_ai`（`World.create(cfg, map, with_ai)`，默认 true） | 开了就多一整个 AI 阵营（阵地性的将领 / 红点刷兵）。★ 本轮 AI **没有大本营、没有资源池**（只有玩家席位才有大本营）。测试 / 基准走 `tests/test_case.require_world()`（= `with_ai = false`），要验 AI 的用例才用默认那条（route.md 33.4） |
| ★★ **战役与关卡数据** | `data/campaigns/<id>/campaign.json` + `levels/*.json` → `logic/campaign.gd`、`logic/level.gd`、`logic/campaign_library.gd` | ★ **只读**：`Campaign` 管元信息与关卡顺序，`Level` 管一关的全部字段与**唯一的覆盖实现**（`merge_over_map`）。**它不改地图**：关卡是「地图 id + 覆盖层」，没写的字段一律用地图的（route.md 第三十七节、dev_plan_7 1.3.3） |
| ★★ **这一局用哪张图 / 哪一关** | `logic/world.gd` 的 `level`（**null = 不做战役**）与 `_merged`（合并后的地图 + AI 名单缓存） | 入口是 `World.create_from_level()`；`create()` 是「按一张图直接开一局」的老路径。★ `level == null` 时新代码**一个字段都不动**（向后兼容那一条） |
| ★★ **合并后的 AI 名单** | `logic/world.gd` 的 `ai_roster_cfg`（每项 `{id, ai, base, attack_target, garrison_ai, reddot_ai, spawn_region, from_level, source}`；★ `reddot_ai` 里含 `wave_time_expr` / `general_count_expr` / `general_weights` / `spawn_tiles` / `escort_count` / `escort_types`） | 由 `logic/level.gd` 的 `merged_ai_factions()` **一处**合并出来（关卡显式写了 `ai` 的优先，其余照旧吃 `config.ai.factions`）。★ 有 `level` 时 `source == "config"` 的那些**不进这一局** —— 「这一关有哪些阵营」由关卡数据说了算。`ai` 取值 `garrison` / `reddot` / `none`（旧值 `faction` / `general` 读入时归一成 `garrison`） |
| ★★ **本机负责的席位** | `logic/world.gd` 的 `player_seats`（= `reset()` 的 `roster`） | 「谁的大本营要建 / 谁有独立钱包」用它。★ 顺序 = 席位顺序（房主第 1 个、客机第 2 个） |
| ★★ **本机在操作的席位** | `logic/world.gd` 的 `player_factions`（= `player_seats` 里 `ai_kind_of == "none"` 的那些） | 「**谁的家算玩家的家 / 目标归谁**」用它。★★ 它与 `player_seats` 在「选边关」里**不一样**：roster 是 `[我选的那一方, 敌人那一方]`（两边的家都要建出来），但敌人那一方**本机不操作** ⇒ 它交给 AI、也不算玩家的家。判「同方」与判「席位」是两件事，混用会静默改玩法（route.md 37.18） |
| ★★ **阵地性 AI 的巡逻路线** | `logic/garrison_ai.gd`：`unit.patrol_points` / `patrol_index` / `patrol_dir` / `patrol_zone_id`（**存在单位自己身上**） | 每位驻防守将一条自己的路线：**按 `zone_count` 切扇区**（第几段由 `_sector_of` 按 id 稳定派生）+ 段内用**由 id 派生的固定种子**随机取点 ⇒ 看起来杂乱、但逐点可复现（**不许用引擎随机数**，见 route.md 37.19）。★ 参数 `ai.garrison.patrol_points` / `patrol_spread_tiles`，可按阵营覆盖 |
| ★★ **这一方的 AI 指派** | `logic/world.gd` 的 `ai_kind_of(fid)`（关卡点名优先，其余退回 `config.ai.factions`）→ `"garrison"` / `"reddot"` / `"none"` | 「**谁该被 AI 接管**」用它 —— ★ 注意这是**组装期**口径：`my_faction`（本机在操作的那一方）不算 AI，**其余每一方**都按自己的指派算。`_is_ai_piloted()` 是**开局后**口径（把 `my_faction` 排除），判据是 `!= "none"` |
| ★★ **每个玩家席位的资源池** | `logic/world.gd` 的 `player_resources`（"faction" → `{food, gold}`）+ `resource_pool_for(faction)` | ★ 本机席位那一份**就是** `world.resources` 这个对象本身（不是副本）—— HUD 读它、扣费走 `resource_pool_for()`、快照发它，三者天然同一份数。合作模式下两人各花各的（route.md 第三十七节 / dev_plan_7 3.7） |
| ★★ **选边关的目标** | `logic/level.gd` 的 `objectives[].for` + `objective_for(fid)`；目标种类 `hold_zone` / `capture_zone` | 一关两个可玩阵营各打各的时，**每个阵营一条目标**（`for` 点名给谁）。运行时由 `objective.setup(..., seat_arg = my_faction)` 取**本机席位**那条；`capture_zone` = 归属翻成自己那一帧**立刻判胜**（route.md 37.18） |
| ★★ **目标与胜负** | `logic/world.gd` 的 `objective_state`（`{kind, zone, sec, held, state, reason, defend, fail, seat}`），规则在 `logic/objective.gd` | ★ 它是**世界状态**：`reset()` 末尾由 `ObjectiveRes.setup()` 建好（HUD 第一帧就读得到），`tick()` **末尾**推进（目标最后判 ⇒ 「这一帧刚守满」立刻结算）。★ `level == null` 时是一份空状态（`kind == ""`），一个玩法行为都不受影响 |
| ★ 结算播报去重 | `logic/world.gd` 的 `_objective_reported` | 结算之后 world **继续 tick**（不做 UI 冻结）—— 不记一笔就会每帧发一条 `level_end` |
| ★★ **迷雾按哪一方算** | `logic/fog.gd` 的分桶键 = `FactionRes.side_of(阵营)` | 合作模式两人**共享视野**（用户拍板）；单机时 `side_of(p1) == "p1"` ⇒ 与从前逐位一致。★ 三类查询（`tile_visible` / `unit_visible` / `building_visible`）必须**一起**走同一个键（route.md 第三十七节） |
| ★ 地图目录里的「战役专用图」 | `data/maps/<id>/map.json` 的 `hidden: true` → `logic/map_library.gd` 的 `is_hidden()` | ★ 它**不进自由对战的选择条**，也不当默认图（加一张战役图不该改变「不选就按 test」进的那一局）。关卡照样按 id 直接引用它；占位图（`placeholder`）**照样列出**、只是不当默认 —— 两种标记含义不同，别合并 |
| ★★ **「这一局从哪一关开的」** | `view/game_scene.gd` 的 `level_playing` / `level_campaign`（**老路径上都是 null**） | ★ 它们是**界面层**的记账（`world` 自己持有 `level` 才是权威）：给「返回关卡列表 / 结算面板」这类以后的界面用。入口两条：`start(map_path)`（老路）与 `start_level(campaign, level, faction)`（战役路）——**只差「世界怎么造出来」**，之后完全同一条尾 |
| ★ 单人战役的**占位**入口 | 主界面 `campaign_test` 按钮 → `view/campaign_test.gd`（列单人关 + 选阵营 + 开始）→ `view/main.gd` 接 `level_chosen` → `game.start_level()` | ★ 它**只是占位**（正式入口那一套是规划书 5.1~5.4）：界面不认识 `world` / `game_scene`，扫战役目录与建世界都在 `main`；关卡列表**只列单人关**（合作要两个席位，那条路给不了）。见 route.md 37.11 |
| 相机 / 缩放 | `view/camera_rig.gd` | 纯表现，不进快照。★ 它的 `camera.edge_size` 与 HUD 的「屏幕最外圈不拦滚屏」是**同一个数**（`cfg.camera_edge_size`） |
| 选中列表 | `view/input_controller.gd` | 纯本地，**不进命令流**（第 1 轮也一样）。★ 左键**点选**与左键**框选**（拖出矩形，见 route.md 16.3）走的是同一个入口 `select_units()` —— 它会用 `world.expand_to_groups()` 把「一个单位」展开成「它所属的整支部队」 |
| 玩家下达的攻击命令 | `logic/unit.gd` 的 `ordered_target` / `ordered_building` / `has_attack_move` | 与「这一帧在打谁」（`target` / `target_building`）**分开存**，见 route.md 12.3 |
| UI 几何（面板位置与尺寸） | `view/ui_layout.gd` | 纯常量，照参考图的像素稿；其它 view 文件不写坐标字面量 |
| 当前页签（操作 / 单位 / 招募 / 科技 / 建筑） | `view/page_tabs.gd` + `hud._tab_plan()` | 纯本地显示状态，只决定命令卡里有什么；**显示哪几颗由当前选中对象决定**（route.md 二十二节），每一类选中各记「上次停在哪一页」（`hud._page_memory`）。★ 科技页在**选中大本营**与**什么都没选中**两处都出现，是同一颗页签、同一套九格 |
| **悬停到哪一格 / 悬停面板写什么** | 序号由 `view/command_card.gd` · `view/tech_grid.gd` 报（`cell_hovered` / `cell_unhovered`）；**文案**由 `hud._hover_detail()` 现取；面板本身是 `view/hover_tip.gd` | 纯本地显示状态，**不进命令、不进快照**。★ 与点击同一条划分：格子控件只报「第几格」，**界面词只在 hud 一处**（`_hover_detail` 那一段）；对应关系见 route.md 第二十七节 |
| 科技的启用状态（谁启用了哪几条） | `logic/tech.gd` 的 `active_by_faction`（由 `logic/world.gd` 持有并暴露查询） | ★ 它是**世界状态**（影响产量 / 血量 / 人口），不是界面状态：界面每帧读 `world.tech_entries()` 画高亮，命令只有 `tech_toggle` 一条。效果数值全在 `data/config.json` 的 `tech.list` |
| 建筑升级的读条（等级 / 进度 / 已扣的钱） | `logic/building.gd` 的 `level` / `upgrade_*` 字段；规则在 `logic/upgrade.gd` | ★ 与「招募队列挂在将领 / 区划上」同一个理由：「这栋楼正在干嘛」属于这栋楼。命令只有 `building_upgrade` / `building_upgrade_cancel` 两条（按**地块**定位） |
| 区划特化（已选哪一种 / 读条 / 已扣的钱） | `logic/zone.gd` 的 `spec_*` 字段；规则在 `logic/upgrade.gd` | `spec_done` = 已经生效的特化（**跟着地块走**，区划易主保留）；`spec_kind` = 正在读条的那一单。命令 `zone_specialize` / `zone_spec_cancel` / `zone_spec_bar_cancel` |
| 建筑血量上限的**两个倍率**（等级 × 科技） | `logic/building.gd` 的 `base_hp_max` / `level_hp_mult` / `tech_hp_mult` → `refresh_hp_max()` | ★ 上限只有这一个算法：**基础值 × 等级倍率 × 科技倍率**；当前血量按比例缩放。升级读完由 `world.apply_building_level_hp()` 落一次 |
| 科技的三类效果（每地块加产量 / 血量上限倍率 / 区划人口增长倍率） | `logic/tech.gd` 的 `effects_of()` → `world.tech_effects` | 每帧在 `tick()` 开头重算；启用 / 弃用时 `_apply_tech_effects()` **立即**落到对象上（血量按比例缩放、上限从 `base_hp_max` 重算） |
| **战争迷雾（谁能看见哪一格 + 已知的敌方建筑）** | `logic/fog.gd`（由 `logic/world.gd` 持有并暴露成 `world.fog`） | ★ 它是**派生数据**：只读 `map.terrain` + 各单位 / 建筑的位置算出来，**不进快照**（联机时各端各算一遍）。`world.tick()` 末尾按需重算（`fog.refresh_needed()`）；`reset()` 末尾也算一次，于是进游戏第一帧之前就有正确的迷雾。★ 单位 / 建筑各自的视野半径在 `unit.vision` 字段上（出生时从 config 抄进对象） |
| 视野半径的数值 | `data/config.json` 的 `fog.vision_default` / `fog.vision_building` / `unit.types.<id>.vision` / `unit.general.stats[i].vision` / **`building.<type>.vision`** | ★ **单位与建筑各有一张「每类型一个值」的表**，两处完全对称。游戏侧只读 `cfg.unit_vision_of()` / `cfg.general_vision_at()` / `cfg.building_vision_of()`（后两个的兜底分别是 `fog.vision_default` 与 `fog.vision_building`）；编辑器（tools/unit_editor）改的是同一批键 |
| 灰色遮罩的颜色与不透明度 | `data/config.json` 的 `fog.mask_color` / `fog.mask_alpha` → `cfg.fog_mask_color` | 纯显示；`view/fog_view.gd` 烘的贴图只存「看得见 / 看不见」，颜色靠 `draw_texture_rect` 的 modulate —— 换颜色不必重烘贴图 |
| 操作页的「命令模式」（点了移动 / 攻击 / 行军之后等左键点地图） | `view/input_controller.gd` 的 `order_mode` | 纯本地输入状态，与 `build_type` 同源、互斥；命令照旧只走 `command_issued` |
| 招募队列的实现细节（进度、五个格子的几何） | `logic/unit.gd` 的 `train_*` 字段 / `logic/zone.gd` 的 `train_*` 字段（**区划招募**）+ `view/recruit_queue.gd` | 进度由 `unit.train_progress()` / `world.zone_train_progress()` 算好，视图只取色与填格子（不让视图自己发明判定，见 pitfalls 5.20）；同一个控件显示「将领的队列」或「区划的队列」（`set_queue(holder, is_zone)`） |
| 事件（击杀 / 建筑被拆 / 招募…） | `logic/world.gd` 收集 → `world.tick()` 返回 | **逻辑层不写 UI 文案**；目前只翻译三条：`recruit_rejected` / `order_rejected` → 左栏那行红字、`unit_recruited` → 把新兵选上（`view/game_scene.gd` → `hud` / `input_controller`） |
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
