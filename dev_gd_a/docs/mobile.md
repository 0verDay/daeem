# 手机端：操作、UI 与性能排查记录

> 本文是「手机端适配 + 性能调优」的完整交接文档：**做了什么、为什么这么做、实测到哪一步、还剩什么**。
> 新任务可以直接从这里接手，不必重新翻聊天记录。
> ★★ **性能任务从这里接手：[第 25 节「收尾」](#25-收尾性能优化到此结束20261028)** ——
>    一句话现状、**唯一一份关键设置表**、历轮汇总、8 条经验、验收 / 回退命令、何时才需要再开。
>    第 17 节是较早的「当前配置总览」，已被第 25 节取代（内容仍可参考）。
> ★★ **2026.10.27 的第四轮（目标 90 帧 / 覆盖层静态层 / 索敌负缓存）见第 22 节** ——
>    那一节有「改前 vs 改后」的桌面分段表，接手性能任务先看它。
> ★★ **2026.10.28 的第五轮（固定逻辑步长：手机 30 → 60 帧）见第 23 节** ——
>    那一节讲清「逻辑步数 = 渲染帧数」这个不动点，以及 `sim.step_sec` / `sim.mobile_step_sec` 怎么调、怎么回退。
> ★★ **2026.10.28 的第六轮（units 实测 / fog 版本号闸门 / 驻防 AI 10 Hz）见第 24 节** ——
>    那一节给出 units 的**真实分段**与「C# 下沉值不值」的结论，以及两个新开关的回退办法。
> ★★ **收尾（2026.10.28）：性能优化已结束，见第 25 节** ——
>    用户确认手机与电脑都流畅；那一节是一页交接（设置 / 经验 / 回退 / 何时再开）。
> 相关文件：`view/touch_controller.gd`、`view/input_controller.gd`、`view/game_scene3d.gd`、
> `view/hud.gd`、`view/minimap.gd`、`view/overlay_view_3d.gd`、`view/fill_button.gd`、
> `view/detail_panel.gd`、`view/troop_grid.gd`、`view/squad_panel.gd`、
> `logic/FogKernel.cs`、`logic/fog.gd`、`logic/crowd/CrowdKernel.cs`。

---

## 0. 一句话现状

- **操作逻辑**：手机端已可用（单指拖视野 / 双指框选 / 单击下令 / 双击行军 / 长按 UI 看悬停）；
  双指框选时会实时预览「将被选中的整支部队 / 框里的己方建筑」（阵营色遮罩）。
- **底栏 UI**：详细信息面板已自适应拉伸，与「阵营/盾徽/旗帜」不再有缝。
- **渲染器**：已切到 **Mobile**（`rendering/renderer/rendering_method="mobile"`），Release 导出。
- **性能（2026.10.28 最新）**：手机单机 + command AI 跑 `dscj`（**256 单位 / 27×42**）已能
  **≈60 fps**（固定逻辑步长 30 Hz + 60 fps 渲染，见第 23 节）。下面这条是更早一轮
  66 单位小图的读数，留作对照：
- **性能（2026.10.27，66 单位）**：66 单位 / 29×22 图上，Release + vsync off + `max_fps=60`：
  - 4 槽 UI 调度后实测 **57~65fps**，`fr 15.3 (11.1~16.7)ms`；
  - **周期性尖峰已消失**（`fr` 最大值不再到 25/33ms），`rest` 从 7.8ms 降到 **3.4ms**；
  - `tk 7.5`（u 1.9 / fg 1.5 / z 1.0）、`vu 1.0 vb 1.1`、`dov 1.7`、`sq 0.2`。
- **已落的性能改造**：overlay 静态投影缓存、小地图迷雾烘图、
  **大地图迷雾「精确检测 + 脏格重绘 + 0.1s 合并」**（见 2.2 第 4 条）、
  **C# `FogKernel.cs`**（视野）与 `CrowdKernel.cs`（碰撞/索敌/寻路）、
  HUD 4 槽调度 + 内容没变不重排、按钮主题查表缓存的静息快路径、
  **固定逻辑步长（30 Hz 逻辑 / 60 fps 渲染）**（第 23 节）、
  **fog 版本号闸门 + 驻防 AI 10 Hz 决策**（第 24 节）。
- **下一步重点**：**没有了 —— 性能优化已收尾**（手机 / 桌面都流畅，见第 25 节）。
  以后新增玩法若踩到预算，按 §25.5 的排查顺序先测量再动手；
  ★ `units` 的 C# 下沉**已实测论证为不值得**（第 24 节四），不要再从那里开刀。

---

## 1. 测试环境与真机数据

### 1.1 工程与工具

- Godot **4.7.2 .NET (mono)**；Windows 开发。
- JDK：`C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot`
- Android SDK：`C:\Users\yy197\AppData\Local\Android\Sdk`
- Godot 调试密钥库：`C:/Users/yy197/AppData/Roaming/Godot/keystores/debug.keystore`
  （别名 `androiddebugkey`，密码 `android`）
- 工程导出预设：Android / arm64-v8a / `texture_format/etc2_astc=true`。

### 1.2 真机

- 屏幕原生分辨率 **3200×1440**。
- 游戏内 `DisplayServer.window_get_size()` 实测报过 **2560×1080**、后来 **2400×1080**
  （Android 可能做了显示缩放；以读数里的数字为准）。
- 地图 **29×22**（默认 `frontier` 是 27×22，用户这一局是 29×22）。
- 单位 **66**。

### 1.3 实测读数（手机性能读数；现在在顶部偏右）

| 阶段 | 帧率 | CPU（平均/峰值） | 备注 |
|---|---|---|---|
| Debug 导出、Forward+ | ~20 | — | 渲染器还是 Forward+，且是 Debug 包 |
| Release、Mobile、0.75 3D 缩放 | 25 | 45/— ms | 修「按钮主题覆盖风暴」之前 |
| Release、Mobile、颜色缓存修复后 | 36 | 39.9/40 ms | overlay 静态缓存之前 |
| Release、Mobile、静态投影缓存 + C# FogKernel | ~52 | — | vsync off，`fr 19.1ms` |
| **Release、Mobile、4 槽 UI 调度** | **57~65** | — | **`fr 15.3 (11.1~16.7)ms`，锁 60** |

最新一帧的分段（单位：ms/帧，**4 槽 UI 调度后**）：

```
FPS 57 · mobile · release · crowd C# · 66u · map 29x22
2400x1080 · 120Hz · vs off · fr 15.3 (11.1~16.7)ms · proc 26.5/26.9ms · DC 139
tk 7.5 (u 1.9 fg 1.5 z 1.0) | vu 1.0 vb 1.1 | rest 3.4
ec 0.1 rc 0.1 tw 1.4 ai 0.8 col 0.3 co 0.0 ob 0.0 | hs 0.0 hd 0.0 sq 0.2 dov 1.7 dmm 0.2 | cm 0.1 rb 0.0
```

- `tk` = `world.tick` 总耗时；`u` 单位循环、`fg` 迷雾（C# 内核）、`z` 区划。
- `vu` / `vb` = 单位 / 建筑视图同步。
- `rest = fr − 所有分段 − hud − dov − dmm`；现在只剩 **3.4ms**（引擎 / GPU / 其它 UI）。
- `hs / hd / sq` 是 HUD 三个槽位的**每帧平均值**；`0.0` 表示低于 0.05ms。
- **结论：`fr` 最大值已经不超过 16.7ms，周期性尖峰消失；当前主要可控项是
  `dov 1.7` 与 `tw 1.4`。**
- 注意：`proc 26.5ms` 与 `fr 15.3ms` 对不上，说明 `Performance.TIME_PROCESS`
  更接近「整帧耗时」而不是纯 `_process` 回调耗时；`rest` 里包含**绘制阶段**。

---

## 2. 性能结论（按层拆解）

### 2.1 渲染器（已解决）

- 之前工程 `project.godot` 里**没有** `rendering/renderer/rendering_method`，
  `config/features` 还是 `"Forward Plus"` ⇒ **Android 一直在跑 Forward+**。
- 现已写入：
  ```ini
  config/features=PackedStringArray("4.7", "C#", "Mobile")
  renderer/rendering_method="mobile"
  ```
- ⚠️ **编辑器是权威**：Godot 保存工程时会以编辑器内存里的渲染方式重写这两个键。
  改完后要在「项目设置 → 渲染 → 渲染方式」确认是 **Mobile** 并保存；否则下一次编辑器保存可能又变回 Forward+。
- 本项目场景全 `unshaded`、无光照 / 后处理 / 阴影，换 Mobile 后画面基本无差。

### 2.2 已修掉的每帧开销

1. **按钮「主题覆盖风暴」**（本轮最大的一处）
   - `view/fill_button.gd` 的 `FillAnimator._sync_text()` 原来**每帧无条件**给按钮和子 Label
     写 `add_theme_color_override(...)`，即使颜色没变。
   - Godot 每次写都会让 Control 收到 `THEME_CHANGED` → **文字重新排版**。
     界面上几十个按钮 × 每帧 × 每条字 1~4 个槽位，手机上就是几十毫秒。
   - 现已加颜色缓存 `_applied`：**只有颜色真的变了才写**。
   - 实测：25 帧 → **36 帧**。

2. **小地图地形层**
   - 原来每帧重画 594 个地形 `draw_rect`（地形永不变化）。
   - 现在烘成 **1 像素/格的 `ImageTexture`**（换地图才重烘），每帧一次 `draw_texture_rect`。
   - 手机端重画频率节流到 **10Hz**（`ui.mobile_minimap_hz`），并错开 HUD 槽位。

3. **overlay 血条**
   - 原来每个单位最多 **3~5 次 `palette.to_px`**，且**无屏幕外剔除**。
   - 现在每个单位**一次投影**（新增 `unit_view_3d.quad_screen_size()`）+ 视口外（留 64px）剔除。

4. **地面 / 迷雾重烘**
   - 原来每 15 帧重烘时都 `Image.create` + `ImageTexture.create_from_image`（新建 + 显存上传）。
   - 现在**复用 Image / 贴图缓冲**，尺寸不变时 `ImageTexture.update()` 原地更新。
   - ★★ 本轮再修**大地图迷雾延迟**：变更检测从「18 格抽样签名 + 每 15 帧查一次」
     改成 **每帧整块掩码 memcmp**（`ground.rebake_fog()`），重烘由
     `cfg.fog_rebake_min_sec`（默认 0.1s）合并；并且只重画**状态翻了的格**
     （诊断字段 `ground.fog_painted_tiles`）。
     旧写法在 100×100 图上漏检率 >96%，灰雾会几秒~几十秒不刷新；现在是「当帧发现、
     ≤100ms 内出图」。代价是每帧多一次 10KB 级 memcmp（可忽略），
     单次重绘从 O(全部格) 降到 O(变化格)。

5. **HUD / 部队列表 / 科技格**
   - 手机端 HUD 以 **20Hz 节拍**跑，但**每个节拍只做一块**（4 槽轮转，见第 16 节）：
     shell 10Hz / 详细信息 10Hz / 部队列表 5Hz；
   - 选中变化（`input_ctrl.local_ui_changed`）会立即全刷一次，不等槽位；
   - 详情文本 / 头像 / 3×3 格子 / 招募队列都加了「内容没变就不重排」的早退；
   - 科技格内部本来就会比对内容，未额外改。

### 2.3 剩余瓶颈（`rest ≈ 29.6ms`）

按可能性排序：

1. **`view/overlay_view_3d.gd` 的 `_draw()`：每帧无条件整屏重画。**
   - `sync()` 每帧 `queue_redraw()`（设计如此）。
   - `_draw()` 每帧做：
     - 网格：`2×(cols+1+rows+1)` 个端点逐点 `palette.to_px`（29×22 ≈ 104 次投影）；
     - 区划轮廓：几何有缓存，但**每帧重新投影**全部边界边（几百~上千次）；
     - 占领触发区：每区划约 8 次投影 + 最多 4 个 `draw_polygon`；
     - 占领进度条：逐地块投影 + `draw_colored_polygon`；
     - 单位血条：遍历全部单位（已做单次投影 + 视口剔除）。
   - 这些投影是 GDScript 逐次调用 `Camera3D.unproject_position`，手机上很贵。

2. **`view/minimap.gd` 的 `_draw()`**
   - 地形已烘贴图；但**迷雾仍是逐格**（`rows×cols` 次 `tile_visible` + `draw_rect`），
     单位点仍是逐单位 `draw_rect`。当时手机端 15Hz 重画，仍是不小的一笔。

3. **2D UI 的填充**
   - 窗口 2400×1080，`window/stretch/mode = "viewport"` + `aspect = "expand"`
     ⇒ **2D UI 仍按 2400×1080 绘制**；半透明面板约占屏幕 31%，叠在 3D 上
     （3D 仍要完整渲染）。
   - `mobile_3d_scale = 0.75` 只降低 3D 分辨率，不影响 2D。

4. **GPU 呈现 / 透明层**
   - 地面（不透明）+ 迷雾（全屏 alpha）+ 地图边界（透明 shader）+ 半透明 UI。
   - `DC 155` 正常，不是合批问题；但填充率在 2400×1080 上仍有成本。

---

## 3. 建议的下一步（按优先级）

> ★ 本节是**历史计划**：P0（overlay 静态投影缓存）与 P1（小地图迷雾烘图 / 降频）
> 已经在第 12 节落地；HUD 的周期性尖峰在第 16 节落地。
> **当前真正的下一步见第 17 节**（先压 `dov` 与 `tw`）。

### P0：overlay 拆「静态层 / 动态层」

目标：`overlay._draw()` 在**相机不动、归属不变**时不做重复投影。

- 把网格、区划轮廓、占领触发区（这些只依赖**相机 + 区划归属**）缓存成**屏幕坐标数组**，
  以「相机变换 + 区划 revision」为键；键没变就复用，只重新 `draw_multiline`。
- 动态部分（单位血条、拖框、建造预览）保持每帧更新。
- 更彻底的做法：拆成两个 `CanvasItem`（静态层只在相机移动 / 归属变化时 `queue_redraw`）。
- 收益预估：相机静止时这部分成本接近 0；移动时也只重算必要时。

### P1：小地图迷雾烘贴图 / 再降频

- 迷雾层按 1 像素/格（或 2px/格）烘成 `ImageTexture`，只在掩码变化时 `update()`；
  `_draw` 里一次 `draw_texture_rect`。
- 或把重画频率从 15Hz 再降到 ~10Hz（手机上感知不明显）。**已做：现在是 10Hz。**

### P2：2D 分辨率（可选，牺牲清晰度）

- 若确认是填充率：把 `window/stretch/mode` 从 `canvas_items` 改成 `viewport`
  （整个游戏按 1920×1080 渲染再放大），GPU 负载固定，UI 会略软。
  **已做：`project.godot` 现在是 `viewport` + `expand`**（宽屏下视口仍会到 2400×1080）。
- 或继续把 `render.mobile_3d_scale` 从 0.75 降到 0.6 / 0.55（只影响 3D）。

### P3：其它可选项

- `world.tick` 里单位被完整打包 3~4 遍（`refresh_targets` / 主循环 / `resolve_all`）——
  66 单位下不是主因，但大兵团时可看。
- `ground_view._zone_signature()` / `overlay._zone_edge_signature()` 每帧各拼字符串；
  可以改成 `world.zones` 的整数 revision。
- `_collect_destroyed_buildings()` 每帧 `building_list.duplicate()`。
- HUD 的 `_selected_troops()` 每 refresh 会被算两次（`refresh` + `_tab_plan`），可复用。

---

## 4. 性能读数说明（下次排查直接用）

手机端**左上角**的读数。★ **默认只有一行 `FPS 60`**
（`ui.show_perf = true`、`ui.show_perf_detail = false`）；把 `ui.show_perf_detail` 改成 `true`
才是下面这四行完整读数（那一档同时会打开 `profile_on` / 场景层 profiling）。仅 `OS.has_feature("mobile")` 时创建。

★ 位置：左上角 `(6, 2)` —— 左侧部队列表从 `y = 40` 才开始，压不到它。
早先那一版挪到 `x = 620` 是为了躲开列表（四行读数太宽）；现在默认只有一行 FPS，
放回左上角更省地方，也不挡地图中部。要四行读数时它仍从左上角起、向右铺 1240px。

```
FPS 57 · mobile · release · crowd C# · 66u · map 29x22
2400x1080 · 120Hz · vs off · fr 15.3 (11.1~16.7)ms · proc 26.5/26.9ms · DC 139
tk 7.5 (u 1.9 fg 1.5 z 1.0) | vu 1.0 vb 1.1 | rest 3.4
ec 0.1 rc 0.1 tw 1.4 ai 0.8 col 0.3 co 0.0 ob 0.0 | hs 0.0 hd 0.0 sq 0.2 dov 1.7 dmm 0.2 | cm 0.1 rb 0.0
```

- 第 1 行：帧率 / 渲染方式 / debug|release / 群编内核 / 单位数 / 地图格数。
  - 渲染方式应为 `mobile`；`crowd` 那一栏应为 **`crowd C#`**
    （若是 `crowd GD(O(N^2))` 说明 C# 群编内核没打进包）。
    ⚠️ 它**只表示群编内核**（碰撞 / 索敌 / 距离场），**不代表整个工程是 C#** ——
    工程主体是 GDScript，C# 只有 crowd 内核 + `logic/FogKernel.cs`（详见第 14 节）。
- 第 2 行：窗口分辨率 / 屏幕刷新率 / vsync 开关 / **真实帧间隔** / `proc`
  （引擎的 `Performance.TIME_PROCESS`）平均/峰值 / draw call。
  - ★★ `fr` 是本轮新增的：它来自 `_process(dt)` 的累加，**包含 vsync 等待**，
    是玩家实际感受到的「每帧多少毫秒」。括号里是窗口内的 **min~max**：
    max 远大于 min（例如 `9.8~33.4`）说明不是每帧都慢，而是**周期性尖峰**。
  - ⚠️ `proc` 在手机上实测会出现 **`proc 45ms` 而 `fr 24.4ms`** ——
    它把 vsync 等待也算进去了，**不能**当作「脚本耗时」。
    旧版读数拿 `proc - 分段` 算 `rest`，会得出一笔不存在的 30ms（本轮已修）。
- 第 3 行：分段耗时（ms/帧）：
  - `tk` = `world.tick`；`u` 单位 / `fg` 迷雾 / `z` 区划；
  - `vu` / `vb` = 单位 / 建筑视图同步；
  - ★ `rest = fr − 所有分段 − hud − dov − dmm`（**按真实帧间隔算**），
    剩下的是引擎 / GPU / 其它 UI / vsync 等待。`hud` 是下面三块之和。
- 第 4 行：其余具名分段：
  - `ec` 经济 / `rc` 招募 / `tw` 箭塔与投掷物 / `ai` 两种 AI；
  - `col` 碰撞 / `co` 收尸 / `ob` 目标判定；
  - `hs` HUD shell（资源条 / 页签 / 命令卡 / 科技格）/
    `hd` 详细信息 / `sq` 左侧部队列表；
  - `dov` overlay 的 `_draw` / `dmm` 小地图的 `_draw`；
  - `cm` 相机 / `rb` 地面重烘。
  - ★ `hs / hd / sq` 是**每帧平均值**（节拍 20Hz、各槽 5~10Hz 的实际代价已摊进去）。
  - ★ `dov` / `dmm` 是**命令录制**时间（不含 GPU 执行），但足以判断自绘层是不是大头。

判读：

- `fr ≈ 1000/FPS`；`fr` ≫ 所有分段之和 ⇒ 时间花在**没被计时的地方**
  （GPU / 引擎 / 其它 UI），不是逻辑算不完。
- 120Hz 屏上 **60fps 的预算是 16.7ms**；当前 `fr` 平均 **15.3ms**，已经在预算内。
- `fr (min~max)` 的跨度大 → 周期性尖峰（HUD 刷新 / 小地图 / 重烘），
  优先把周期性任务降频或摊到多帧，而不是优化平均值。

> 读数的实现：`view/hud.gd` 的 `_build_perf_readout` / `_update_perf_readout`；
> 分段计时复用工程原有的 `profile_on` / `profile_us`（`logic/world.gd`、`view/game_scene3d.gd`）。
> ★ **只有 `ui.show_perf_detail = true` 才会打开 `profile_on`**；默认只显示 FPS 时不付这份开销。
> 桌面 / 无头不创建读数、也不开计时。

---

## 5. Android 导出（Release 签名）

Debug 包用 Godot 自动的调试密钥库；**Release 必须配置发布密钥库**，否则报「找不到发布密钥库」。

### 5.1 只做性能测试（最快）

在 Godot 导出对话框 → Android 预设 → Keystore：

- Release Keystore：`C:/Users/yy197/AppData/Roaming/Godot/keystores/debug.keystore`
- Release Keystore User：`androiddebugkey`
- Release Keystore Password：`android`

与 Debug 包同一把密钥 ⇒ 可直接覆盖安装。

### 5.2 正式发布（不要用调试密钥）

```powershell
& "C:\Program Files\Eclipse Adoptium\jdk-17.0.20.101-hotspot\bin\keytool.exe" `
  -genkeypair -v -keystore "$env:USERPROFILE\daeem-release.keystore" `
  -alias daeem -keyalg RSA -keysize 2048 -validity 10000
```

用正式密钥签的包与调试包签名不同，安装前要先卸载旧包。

> ⚠️ 发布密钥库的路径 / 密码**不要写进仓库**（`export_presets.cfg` 也不要提交）。

---

## 6. 触摸操作：最终口径

### 6.1 手势

| 手势 | 行为 | 实现位置 |
|---|---|---|
| 单指拖动（起点不在 UI 上） | 拖动视野 | `touch_controller.MODE_PAN` |
| 按住 ≥ `pan_hold_sec` 后拖动 | 拖动视野（长按拖动） | 同上（时间判据） |
| 单指单击 | 没选中 → 选中；已有选中 → **只下命令**（敌人=攻击、其余=移动），**绝不改选** | `input_controller.touch_tap` |
| 双击 | 行军（`attack_move`） | `input_controller.touch_double_tap` |
| 双指滑动 | 框选；选框两角 = 两指当前位置（实时） | `touch_controller` + `input_controller.touch_box_set` |
| 长按 UI 格（≈0.4s） | 显示悬停详情；松手不触发该格 | `hud.handle_touch` + `fill_button` / `command_card` / `tech_grid` |

### 6.2 关键判据

- **单击 = 时间短且移动小**：`tap_max_sec`（0.3s）+ `tap_max_move_px`（18px）。
- **拖动 = 移动够远或按住够久**：`pan_min_px`（24px）或 `pan_hold_sec`（0.18s）。
- 移动处于「超过单击容差、又没到拖动阈值」时**什么都不做**（不误发命令）。
- **第二根手指落下 = 一律切框选**，即使第一根已经在拖视野（会先停掉拖视野）。
- **触摸设备（`OS.has_feature("mobile")`）**：
  - 地图侧**完全不认鼠标**（包括 `emulate_mouse_from_touch` 造的模拟鼠标）；
    HUD / 小地图走 GUI，不受影响。
  - **关闭边缘滚屏**（`_edge_scroll_on = false`），并跳过每帧的 `blocks_edge_scroll()`。
- 改选 / 取消选中：双指空框、左侧部队列表、Esc（不再靠单击地图）。
- 起点在 UI 上的手势一律忽略（交给 GUI）。

### 6.3 注意

- `emulate_mouse_from_touch` **保持开启**（菜单 / 按钮 / 列表靠它）；
  游戏内地图侧显式屏蔽模拟鼠标，避免「一次触摸被处理两遍」和「点地图清空选中」。
- `touch_device` 只看 `OS.has_feature("mobile")`，不看 `DisplayServer.is_touchscreen_available()`
  （否则带触摸屏的桌面笔记本会失去鼠标操作地图的能力）。
- 双击的第一下按单击**立即生效**、第二下升级为行军（不引入单击延迟）。

---

## 7. 底栏自适应（已修复）

- 问题：手机横屏（宽于 16:9）时，详细信息面板贴左、阵营/命令卡/页签贴右，中间裂开一条缝。
- 修复：`view/ui_layout.gd` 的 `apply_stretched_detail()`：
  - 面板左缘钉 400、**右缘钉到阵营列左缘**（offset `-490`）；
  - 多出来的宽度**全部进右栏**（`DetailRight.size_flags_horizontal = EXPAND_FILL`）；
  - `detail_panel._layout_right(right_w)` 在右栏宽度变化时重摆数值框 / 招募队列 / 名称列 / 正文右栏；
  - 左栏 350 固定，阵营仍 150 固定。
- 1920 基准下与旧几何逐像素一致；`bottom_bar_rects()` 改用拉伸后的矩形，
  滚轮缩放屏蔽仍然正确。

---

## 8. 本轮涉及的文件

| 文件 | 内容 |
|---|---|
| `project.godot` | `renderer/rendering_method="mobile"`；`config/features` 含 `"Mobile"`；横屏 orientation |
| `export_presets.cfg` | Android 补 `texture_format/etc2_astc=true`（Release keystore 在编辑器里配，不入库） |
| `data/config.json` | `touch.*`、`render.mobile_3d_scale`、`ui.mobile_hud_refresh_hz`、`ui.mobile_minimap_hz`、`ui.show_perf` |
| `logic/config.gd` | 上述键的缓存字段（载入时算好） |
| `view/touch_controller.gd` | **新文件**：手势识别（拖视野 / 单击 / 双击 / 双指框选 / 双指切换） |
| `view/input_controller.gd` | `touch_tap` / `touch_double_tap` / `touch_box_set` / `touch_box_end` / `set_touch_panning` |
| `view/game_scene3d.gd` | 触摸接线、`touch_device`、地图侧屏蔽鼠标、关边缘滚屏、移动端 3D 缩放、`perf_enable` / `profile_snapshot` |
| `view/hud.gd` | 长按 UI→悬停、`point_hits_ui`、手机端刷新节流、性能读数 |
| `view/fill_button.gd` | 悬停状态在隐藏时失效、`clear_hover_in`、**颜色覆盖缓存（性能修复）** |
| `view/command_card.gd` / `tech_grid.gd` | `touch_suppress_hover`；`hover/unhover` 直接发信号 |
| `view/start_screen.gd` | 进游戏 / 回菜单时清按钮悬停 |
| `view/ui_layout.gd` | 详细信息面板拉伸、右栏动态宽度函数、`bottom_bar_rects` |
| `view/detail_panel.gd` | 面板拉伸 + 右栏重排（`_layout_right`） |
| `view/minimap.gd` | 地形烘图 + 手机端重画节流 |
| `view/overlay_view_3d.gd` | 血条单次投影 + 屏幕外剔除 |
| `view/unit_view_3d.gd` | `quad_screen_size()`（宽高一次算完） |
| `view/squad_panel.gd` | 手机端刷新节流；触摸手势入口（单击反选 / 双击跳转 / 长按跟随，行在手机端 `MOUSE_FILTER_IGNORE`，由 `hud.handle_touch()` 在 GUI 之前优先路由） |
| `view/ground_view.gd` | 地面/迷雾烘图缓冲复用（`ImageTexture.update`） |
| `logic/crowd/crowd_bridge.gd` | C# 内核不可用时 `push_warning` |
| `tests/test_touch.gd` | **新文件**：触摸手势与命令的回归测试 |
| `tests/test_ui.gd` / `test_view3d.gd` / `test_fill_button.gd` / `test_settings_menu.gd` | 对应回归断言 |
| `docs/architecture.md` | 新文件与自适应底栏的说明 |

---

## 9. 测试

```powershell
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1
```

- 当前：**48 个测试文件 / 5776 项断言 / 全部通过**。
- 与手机端相关的重点用例：
  - `tests/test_touch.gd`：单击/双击/拖动/长按拖动/双指框选/双指从拖视野切框选/UI 起点忽略。
  - `tests/test_ui.gd`：底栏拉伸几何、触摸设备屏蔽鼠标。
  - `tests/test_fill_button.gd`：隐藏时悬停作废、`clear_hover_in`、颜色覆盖缓存。
  - `tests/test_settings_menu.gd`：返回主菜单后按钮不残留悬停。

---

## 10. 已知坑 / 注意事项

1. **渲染器设置会被编辑器重写**：`renderer/rendering_method` 以编辑器为准；
   若文件里那行消失，说明编辑器内存里仍是 Forward+。
2. **Debug 导出慢很多**：测性能必须用 Release（C#/GDScript 的 debug 构建都未优化）。
3. **`Performance.TIME_PROCESS` 的语义**：实测它更接近「整帧」，不是纯 `_process`；
   所以 `rest` 里包含绘制阶段。读分段时不要把它当成「纯脚本时间」。
4. **`mobile_3d_scale` 只降 3D**：2D UI 仍按窗口分辨率（2400×1080）。
5. **`emulate_mouse_from_touch` 不能关**：菜单/按钮/列表依赖它；只在游戏内地图侧屏蔽。
6. **触摸设备判定只看移动平台**：桌面带触摸屏时鼠标照常可用。
7. **地图规模影响迷雾/小地图**：迷雾刷新是 O(贡献格 × 地图格数)；
   大图（如 100×100）会显著放大开销，排查时要看读数里的 `map WxH`。
8. **`profile_on` 只在手机读数开启时打开**；桌面/无头不付这个开销。
9. **★★ GDScript 源码里不能写 `\u0000`**：Godot 的 Unicode 词法解析会报
   `Unicode parsing error ... Unexpected NUL character`（脚本被解析几次就报几次）。
   要用「未初始化哨兵」就写普通字符串（如 `"#none#"`）或另开一个 `bool`。
   本轮在 `view/troop_grid.gd` 踩过一次。
10. **★★ vsync / 锁帧的现状**：
    - `render.mobile_vsync = false`（默认）：手机端按原始帧时间跑；
    - `render.mobile_max_fps = 60`（默认）：进游戏时 `Engine.max_fps = 60`；
    - 锁帧在 `game_scene3d._assemble()` 生效，所以**主菜单不锁**；要连菜单一起锁，
      得在启动时（`view/main.gd` / 项目设置 `application/run/max_fps`）设置。
11. **★★ HUD 4 槽调度**：`ui.mobile_ui_stagger = true`（默认）时，手机端每个节拍只做
    一块（shell / 详细信息 / 部队列表）；`false` 回退到旧的「每个节拍全刷」。
    读数里 `hs / hd / sq` 是每帧平均值，`0.0` 只表示低于 0.05ms，不是没测到。
12. **★★ C# 内核有 GDScript 回退**：`fog.backend = "gdscript"` 可切回旧实现；
    `unit.collision_backend = "gdscript"` 同理。改了 C# 必须重新构建
    （`dotnet build daeem.csproj -c Debug`，导出时 Godot 会自动构建）。

---

## 11. 下次接手的最短路径

1. 先跑 Release，读**四行**读数，确认 `mobile` / `release` / `crowd C#` / `vs off`。
2. 看 `fr (min~max)`：
   - 跨度大（例如 `11~33`）→ 还有周期性尖峰：先看 `hs / hd / sq / dov / dmm`；
   - `max` 已经 ≤16.7ms → 帧时间已够 60fps；`FPS` 偏低只可能是锁帧 / 显示 / 热降频。
3. 看 `rest`：
   - `rest` 大 → 引擎 / GPU / 其它 UI；降 2D 分辨率或减少透明层；
   - `dov` 大 → overlay `_draw`（下一步拆静态 / 动态层）；
   - `tw` 大 → 箭塔 / 投掷物 / 建筑效果循环。
4. `tk` 大 → 看 `u`（单位）/ `fg`（迷雾，已 C#）/ `z`（区划）/ `ai`。
5. 每次改完都跑 `tools/run-tests.ps1`，并真机复测四行读数。

---

## 12. 第二轮性能优化（本轮：静态层缓存 + 小地图迷雾烘图）

对应第 3 节的 **P0 / P1**。判据仍然是「相机静止时不该重复做同一件事」。

### 12.1 overlay 静态层缓存（P0）

`view/overlay_view_3d.gd` 原来每帧都重新投影：

- 网格：整张图 `(cols+1)+(rows+1)` 条线，逐端点 `palette.to_px`；
- 区划轮廓：每块地的边界边全部重投；
- 占领触发区：每区块 8 次投影（内框 + 外框四角）。

现在把这三层的结果缓存成**屏幕坐标数组**，键是：

```
相机 global_transform + 相机投影矩阵 + 视口尺寸 + 区划签名（id / 地块数 / owner）
```

键没变 ⇒ 一次投影都不做，只重新提交 `draw_multiline` / `draw_polygon`。
相机动了或归属变了 ⇒ 当场重建一次（与原来的每帧成本相同，不会更慢）。

额外的小优化：区划轮廓在缓存时顺便做**屏幕外包围盒剔除**（拉近视角后地图上大部分轮廓都在屏幕外），既省 draw 调用也省 GPU 裁剪。

保持**每帧更新**的动态部分（不缓存）：

- 单位血条（跟单位位置走）；
- 占领进度条（每帧都在涨）；
- 建造预览 / 拖框（跟随鼠标 / 手指）。

诊断字段：`overlay.static_rebuild_count`（缓存重建次数）。
真机验证：相机不动时这个数应该**停在原地**，一平移 / 缩放就加 1。

### 12.2 小地图迷雾烘图（P1）

`view/minimap.gd` 原来每次重画都逐格 `tile_visible` + `draw_rect`
（27×22 = 594 次查询 + 594 个图元；当时手机端还有 15Hz 节流，现已降到 10Hz）。

现在与地形层同一套做法：

- 迷雾掩码烘成 **1 像素 / 格** 的 `ImageTexture`，`_draw` 里一次 `draw_texture_rect`；
- 只在**掩码真的变了**时重烘；
- 判据是**整块 `PackedByteArray` 逐字节比较**（不是抽样），所以局部变化也不会漏
  （29×22 = 594 字节，100×100 也只有 1 万字节，比较成本可忽略）；
- 贴图缓冲复用（尺寸不变时 `ImageTexture.update()`，不重新分配显存）。

诊断字段：`minimap.fog_bake_count`（烘图次数）。单位不动时它应该保持不变。

### 12.3 已经生效的 P2

`project.godot` 的 `window/stretch/mode` 已经是 **`viewport`**（工作区已改，不是本轮改的）。
如果真机上仍然确认是填充率瓶颈，还可以继续：

- `render.mobile_3d_scale` 从 0.75 降到 0.6 / 0.55（只影响 3D）；
- 或用 `Window.content_scale_factor` 给 2D UI 定一个 < 1 的渲染比例（会牺牲 UI 清晰度，
  且会影响布局尺寸，未做）。

### 12.4 复测方法

1. Release 包进游戏，看顶部偏右的四行读数：
   - `rest` 应该比上一轮的 **29.6ms** 明显下降（相机静止时最明显）；
   - `FPS` / `fr` 才是最终判据，不要只看某一帧。
2. 相机**保持不动**几秒，再平移 / 缩放，观察 `static_rebuild_count` 只在后一种情况下增加。
3. 小地图上的迷雾应与大地图一致；单位移动时不会有「迷雾方块跟不上」的滞后
   （掩码变化后下一次 10Hz 重画就会重烘）。

### 12.5 回归测试

```powershell
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_view3d
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_minimap
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_fog
```

- `test_view3d.gd`：网格 / 区划轮廓 / 触发区剔除的几何断言 +
  **静态层缓存的失效判据**（相机静止不重建、移动后重建；本轮全绿，164 项）。
- `test_minimap.gd`：小地图几何与视野框（10 项）。
- `test_fog.gd`：迷雾掩码 / 烘图 / 小地图可见性 +
  **小地图迷雾的复用与重烘** + **C# / GDScript 掩码逐字节等价**（155 项）。

---

## 13. 「手机能跑大型游戏，为什么跑这个只有 43~47 帧？」

### 13.1 先分清两件事

**（A）vsync 把帧率量化到刷新率的整数分之一。**

帧率不是连续值：开着 vsync 时，一帧必须在下一个刷新周期前完成，否则就等下一个：

| 屏幕刷新率 | 一个周期 | 跑不进去 ⇒ 掉到 | 再跑不进 ⇒ |
|---|---|---|---|
| 60Hz | 16.7ms | 30fps | 20fps |
| 90Hz | 11.1ms | **45fps** | 30fps |
| 120Hz | 8.3ms | 60fps | **40fps** |

**43~47 帧正是「90Hz 屏上刚好差一点点、每帧都被推到 22.2ms」的样子**
（或 120Hz 屏上在 40/60 之间来回）。此时真实帧时间可能只有 **12~13ms**，只差 1~2ms
就能翻到 90fps —— 看起来却像「只有 45 帧」。

**（B）Godot 的主线程是单线程 GDScript。**

大型手游是原生 C++ / Unity / UE，逻辑多线程、渲染与逻辑重叠；这个工程是
**Godot + GDScript**：`world.tick`、视图同步、HUD、按钮动效全在同一条主线程上，
ARM 手机上 GDScript 的解释开销远大于桌面。所以「场景看起来简单」不等于「每帧很便宜」。
读数里 `tk` / `vu` / `vb` / `rest` 就是这条主线程的账。

### 13.2 本轮新增的两个诊断开关

`data/config.json` → `render`：

```json
"mobile_vsync": false,
"mobile_max_fps": 60,
```

- ★★ **默认已经是 `false`**：手机端进游戏时直接
  `DisplayServer.window_set_vsync_mode(VSYNC_DISABLED)`，按原始帧时间跑，
  不再被刷新率量化到 45/40/30 档；
- 代价是可能有撕裂、发热/耗电增加；看到撕裂就把 `mobile_vsync` 改回 `true`；
- `mobile_max_fps` ⇒ `Engine.max_fps`（**默认 60 = 锁 60 帧**；0 = 不限；90 = 放开到 90）。
  锁帧能避免偶尔跑到 90/100 帧带来的发热与帧时间抖动。

只在 `OS.has_feature("mobile")` 时应用，桌面 / 无头 / 测试完全不受影响。

### 13.3 判读步骤

1. 默认（`mobile_vsync = false`）跑一次，记下四行读数（重点是 `fr`、`tk` 和第 4 行）。
2. 想看 vsync 的影响时，把 `mobile_vsync` 改成 `true` 再导出一次，对比：
   - **帧率掉到 45 / 40 / 30 这类整齐的档位** ⇒ 是 vsync 在量化；
   - **帧率几乎不变** ⇒ 主线程真的要那么久，继续看 `tk/vu/vb/rest`。
3. `fr` 与 `proc` 的关系：`fr` 是真实帧间隔；`proc` 是引擎的
   `Performance.TIME_PROCESS`（手机上会把 present / vsync 等待算进去，
   实测出现过 `proc 45ms` 而 `fr 24.4ms`，**不可当作脚本耗时**）。

### 13.4 本轮顺手拆掉的每帧 UI 开销

`view/fill_button.gd` 的 `FillAnimator._process` 对**每颗按钮每帧**都会调 `_sync_text()`。
原来它每次都：

1. 遍历按钮上所有已登记的字；
2. 调 `_panel_color()` —— 里面是 `get_theme_stylebox()`（**theme 查表**，最多 4 个槽）；
3. 对每条字算两次亮度比较。

本轮：

- `_panel_color()` 那一段其实是给一个**没人读的局部变量** `under` 用的（旧的
  「比对比度选色」删掉后遗留），直接拆掉；
- `_sync_text()` 加**静息快路径**：填充进度没变、没有待处理的字、颜色档位没变
  ⇒ 立即返回。悬停动画期间进度每帧在变，仍然逐帧同步（行为不变）；
- 所有「进度没变但颜色状态变了」的入口（换档 / 改原色 / 改底色）改走
  `_force_sync_text()`，不会漏同步。

收益随按钮数量线性增长（游戏内命令卡 / 页签 / 部队列表 / 底栏合计几十颗）。
`tests/test_fill_button.gd`（130 项）与 `tests/test_ui.gd`（1142 项）全绿。

---

## 14. 这个工程到底是 C# 还是 GDScript？

### 14.1 实际构成（按本仓库数出来的）

| 部分 | 文件数 | 行数 | 说明 |
|---|---|---|---|
| GDScript | **129** | **~46,600** | `logic/` + `view/` + `tests/` 的全部主体 |
| C# | **3** | **~1,650** | `CrowdKernel.cs` + `CrowdProbe.cs` + `FogKernel.cs` |

- `logic/` 约 12,900 行 GDScript（World / Unit / Combat / Zone / AI / Pathfinder…）；
- `view/` 约 13,900 行 GDScript（3D 视图 / HUD / 输入 / 覆盖层…）；
- C# 目前只有两块**纯数字内核**：空间哈希碰撞 / 索敌 / Dijkstra（CrowdKernel），
  以及视野扇区 / 山脉视线 / 掩码合并（FogKernel）。它们都不持有游戏状态、不碰场景树，
  只是「同样语义的数字循环换了个语言」。

### 14.2 为什么不是全 C#

1. **历史原因**：工程是从 HTML/JS 版逐模块移植到 GDScript 的（见 `porting.md`），
   `logic/` 刻意做成纯 `RefCounted`（不碰 Node、不读输入），所以能无头测试、将来能上服务器。
2. **C# 是靠实测加进来的，不是默认语言**：1000 单位时 GDScript 碰撞是
   n(n-1)/2 × 迭代（实测 **605 ms/帧**）、索敌 O(n²)（**283 ms/帧**），
   才把这几段数值循环下沉到 C#。66 单位时这些成本本来就很小。
3. **读数里的 `C#` 容易误读**：它原来只表示 `world.crowd.available()`。
   本轮已改成 **`crowd C#`**，明确它只是「群编内核」这一项。

### 14.3 「Godot 单线程」的准确说法

Godot 的**脚本主循环**默认是单线程：`_process` / `_draw` 命令录制 / UI / 游戏逻辑
都在主线程上跑。这与用 GDScript 还是 C# **无关** ——

- C# 方法默认也在主线程执行；开线程要自己写 `System.Threading` / `Task`，
  并且回调回场景树仍要 `call_deferred`；
- GDScript ↔ C# 每次调用都有跨语言开销（实测 1000 次小调用 518 µs/帧，
  一次批量 4.8 µs/帧），所以内核接口一律收发整条 Packed 数组。

⇒ **「项目里有 C#」不等于「游戏逻辑跑在多线程原生代码上」。**
主线程一帧的账仍然是：`world.tick`（GDScript，~8ms）+ 视图同步 + HUD/按钮 + 绘制。

### 14.4 真要再快，按这个顺序做

1. **先确认瓶颈**（第 13 节）：关 vsync 看 `fr`；`tk` 大 → 逻辑；`rest` 大 → 视图/UI/绘制。
2. **把实测最热的 GDScript 循环搬进 C# 内核**（例如 `world.tick` 的逐单位循环，
   或 `unit_view_3d.sync` 的打包）。必须**按批**：一次调用处理整张数组，
   不要「每单位调一次 C#」。
3. **真正的多线程**：`logic/` 已经是「纯 RefCounted、不碰 Node」，
   具备放后台线程的前提；但视图每帧读状态，需要**快照 / 双缓冲**（逻辑写一份、
   视图读另一份），这是设计级改动，不是改几行。
4. **逻辑 tick 与渲染解耦**：RTS 常用固定 20~30Hz 逻辑 + 渲染插值。
   这是手机上最划算的一档，但要保证「单位移动看起来仍然平滑」，需要补插值。

---

## 15. C# 迁移第一块：FogKernel（已完成）

### 15.1 为什么先搬迷雾

真机 68 单位 / 120Hz 的读数是：

```
tk 11.0 (u 2.9 fg 2.7 z 0.9) | vu 1.4 vb 1.4
```

`fg = 2.7ms` 是**单个最大的可独立搬走的数字循环**：它不依赖任何对象引用
（只需要「哪一方、哪一格、半径多少」+ 山脉掩码），也没有玩法规则，
所以搬走它风险最低、也最容易做**逐字节等价验证**。

### 15.2 做了什么

新增 `logic/FogKernel.cs`（`[GlobalClass] FogKernel : RefCounted`）：

- `SetupMap(cols, rows, mountainMask)` —— 建地图表；
- `BuildSight(sideCount, sides, tiles, radii, count)` —— **一次调用**算出所有方的掩码，
  返回 `sideCount × cols × rows` 的扁平 `byte[]`；
- 输出与 `fog.gd` 的旧实现**逐字节一致**：扇区规则、山脉挡视线（DDA）、
  半径规则、穿格点的两侧判定全部照搬；
- 扇区缓存改存**稀疏可见格下标**（`int[]`），OR 时不再遍历整张地图；
- `fog.gd` 保留原实现作为回退，`data/config.json` 的 `fog.backend`
  可在 `csharp` / `gdscript` 之间切换；普通版 Godot（无 .NET）自动回退。

### 15.3 怎么证明没改玩法

`tests/test_fog.gd` 新增了 **C# vs GDScript 掩码逐字节对比**：

- 同一份地图（含山脉 / 森林 / 三阵营 / 多个半径 / 建筑视野）；
- 两份 `Fog` 实例，一份走内核、一份强制 `kernel = null`；
- `update()` 后逐方比较 `sight[side]` 的每一个字节，再挪动单位重复一次。

结果：**test_fog 155 项全绿**；全量 **48 文件 / 5776 项断言全绿**。

### 15.4 下一步（按真机第 4 行读数决定顺序）

> ★ 最新读数见 **17.3**：`fg` 已降到 1.5ms；当前最大可控项是
> `dov 1.7`（overlay draw）与 `tw 1.4`。下表的 C# 候选留作后续参考。

第 4 行会给出 `ec / rc / tw / ai / col / co / ob` 的真实拆分。
下一块优先搬**单项最大且自包含**的：

| 候选 | 当前成本 | 迁移方式 | 风险 |
|---|---|---|---|
| `u` 单位循环（`CombatRes.tick_frame`） | 2.9ms | 需要把 Unit 的状态打包成数组；先在 GDScript 打包、C# 算、再写回 | 高（玩法规则多） |
| `ai`（阵地 / 红点） | 待读数 | 每帧批量：把所有将领状态压成数组，C# 出「本帧命令」 | 中 |
| `z` 区划 | 0.9ms | 已经是分桶 O(n)；收益小 | 低 |
| `vu/vb` 视图同步 | 2.8ms | 需要保留 Godot 节点调用，C# 只能帮打包 | 中 |

原则不变：**接口按批**、**保留 GDScript 回退**、**逐字节 / 逐字段等价测试**、
**`config` 可 A/B**。不追求「一次性全翻成 C#」，先保证每一步都能回退、都能测。

---

## 16. UI 刷新调度：4 个槽位（本轮）

### 16.1 问题

HUD 原来每个节拍（20Hz）都做一次**全量**刷新：
资源条 + 页签 + 命令卡 + 科技九格 + 详细信息（扫单位 / 拼文案 / 重排）+ 部队列表。
单次可能就是几毫秒，落在某一帧上就把 `fr` 顶过 16.7ms —— 表现就是
「偶尔 100 帧，很快掉到 45」，而平均值看着只有 19ms。

### 16.2 做法

手机端（`OS.has_feature("mobile")` 且 `ui.mobile_hud_refresh_hz > 0`）
不再直接调 `refresh()`，而是按 20Hz 节拍轮转 4 个槽：

| 槽 | 内容 | 实际频率 |
|---|---|---|
| 0 | `_refresh_shell()`：资源条 / 页签 / 命令卡签名 / 科技九格 | 10Hz |
| 1 | `_refresh_detail()`：详细信息面板 | 10Hz |
| 2 | `_refresh_shell()` + `squad_panel.refresh()` | 10Hz / 5Hz |
| 3 | `_refresh_detail()`：详细信息面板 | 10Hz |

- **桌面 / 无头 / 测试仍然每帧走 `refresh()` 全量刷新**（行为完全不变）。
- `squad_panel` 在手机端关掉自己的 `_process`，由 HUD 调度器驱动；
  桌面仍由它自己刷新。
- **选中变化立即全刷**：HUD 连接了 `input_ctrl.local_ui_changed`，
  下一个节拍执行 `refresh() + squad_panel.refresh()`，不等槽位。
- 切页仍由 `page_tabs.page_changed` 直接触发命令卡重建 / 科技格显隐，不经过调度器。
- 小地图默认降到 **10Hz**，并用 `stagger_redraw(0.37)` 把第一次重画错开 HUD 槽位。

### 16.3 内容没变就不重排

配合调度器，几处高频 setter 加了早退：

- `detail_panel.set_detail()`：同一文本 + 同一可用高度 → 不 split、不 `_fit_body_text()`；
- `set_unit_name()` / 头像字 / 血量 / 士气：值没变不写 Label / 不 `queue_redraw()`；
- `troop_grid._apply()`：格子内容（含 hp / hp_max / 士气 / 编制数）没变不重画。
  ⚠️ 它存的是**应用那一刻的内容快照**，不是直接比较 `ref.hp` —— 同一个对象被喂两次时
  两边读到的是同一个实时值，掉血后仍然「相等」，血条会停在旧值上（被 `test_ui` 抓到）。
- `recruit_queue.refresh()`：已经收起且内容为空 → 直接返回。

### 16.4 开关与回退

`data/config.json` → `ui`：

```json
"mobile_hud_refresh_hz": 20,
"mobile_ui_stagger": true,
"mobile_minimap_hz": 10
```

- `mobile_ui_stagger = false` ⇒ 回退到旧的「每个节拍一次性全刷」；
- 若觉得资源条 / 页签更新太慢，把节拍提到 24~30Hz（各槽同比提高）；
- 读数里 `hs / hd / sq` 分别是三块的实际耗时；哪一块仍大就继续拆那一块。

### 16.5 测试

`tests/test_ui.gd` 新增：

- 一次 `refresh()` 只扫一遍 `world.units`（`troops_scans` +1，而不是 +2）；
- 同一详情文本重喂 → `fit_calls` 不增加；
- 4 槽轮转：槽 2 才刷部队列表；每拍只扫一次单位；
- 选中变化强制全刷：`refresh()` + squad 各一次；
- 3×3 网格：同一批格子重喂不重画、血量变化必须重画（防止快照比较写错方向）。

---

## 17. 当前最终状态（交接速查）

### 17.1 关键配置（`data/config.json`）

| 键 | 值 | 作用 |
|---|---|---|
| `rendering/renderer/rendering_method` | `mobile` | 手机渲染器 |
| `render.mobile_3d_scale` | `0.6` | 只降 3D 分辨率（自适应探针的最低下限另算） |
| `render.mobile_vsync` | `false` | 手机端不等 vsync，按原始帧时间跑 |
| `render.mobile_max_fps` | `90` | 进游戏时 `Engine.max_fps = 90` |
| `sim.step_sec` | `0` | **固定逻辑步长**（0 = 关 = 每渲染帧一步，见 §23） |
| `sim.mobile_step_sec` | `0.0333333` | 手机端逻辑 30 Hz（仅移动平台；0 = 关） |
| `fog.backend` | `csharp` | 视野走 `logic/FogKernel.cs`，可切 `gdscript` |
| `unit.collision_backend` | `csharp` | 群编走 `CrowdKernel.cs` |
| `ui.mobile_hud_refresh_hz` | `20` | HUD 调度节拍（4 槽各 10/5Hz） |
| `ui.mobile_ui_stagger` | `true` | 4 槽轮转；`false` 回退全量刷新 |
| `ui.mobile_minimap_hz` | `5` | 小地图重画频率，并错开 HUD 槽位 |
| `ui.show_perf` | `true` | 手机端四行性能读数 |

### 17.2 最近几轮落地的性能改动

| 改动 | 文件 | 结果 |
|---|---|---|
| overlay 静态投影缓存 + 屏幕外剔除 | `view/overlay_view_3d.gd` | 相机静止不重投影 |
| 小地图迷雾烘贴图（掩码逐字节比较） | `view/minimap.gd` | 迷雾从逐格画变成一次贴图 |
| C# 视野内核 + 逐字节等价测试 | `logic/FogKernel.cs`、`logic/fog.gd` | `fg 2.7 → 1.5ms` |
| 手机 HUD 4 槽调度 + 选中变化全刷 | `view/hud.gd` | `rest 7.8 → 3.4ms`，尖峰消失 |
| 详情 / 头像 / 网格 / 队列「没变不重排」 | `detail_panel.gd`、`troop_grid.gd`、`recruit_queue.gd` | `hs/hd` 降到 <0.05ms/帧 |
| 按钮每帧主题查表 / 重复字色同步 | `view/fill_button.gd` | 静息按钮接近 0 成本 |
| vsync / 锁帧开关 | `project` 配置 + `game_scene3d.gd` | `vs off` + `max_fps=60` |
| **固定逻辑步长（30 Hz 逻辑 / 独立渲染）** | `game_scene3d.gd`、`world.gd`、`logic/config.gd` | **dscj 256 单位：CPU 7.69 → 4.82 ms/帧（−37%），真机 30 → 60 fps**（§23） |
| 3×3 淡出位图 + 树/建筑逐帧热点 | `view/fade_stamp.gd`、`terrain_props_view.gd`、`building_view_3d.gd` | `view/buildings` 0.309 → 0.250 ms；这两层原先不在任何 profile 里 |
| 客机不再每快照 `fog.reset_cache()` | `logic/world.gd` | 客机 CPU↓，且修好「见过的敌方建筑」在客机上被清空 |
| `side_of()` 记忆化 / 区划容器复用 / 迷雾烘图读掩码 | `faction.gd`、`zone.gd`、`ground_view.gd` | `zones` −17%；迷雾逐格调用全部降为一次下标 |

### 17.3 最新真机读数（锁 60 前）

```
FPS 57 · mobile · release · crowd C# · 66u · map 29x22
2400x1080 · 120Hz · vs off · fr 15.3 (11.1~16.7)ms · proc 26.5/26.9ms · DC 139
tk 7.5 (u 1.9 fg 1.5 z 1.0) | vu 1.0 vb 1.1 | rest 3.4
ec 0.1 rc 0.1 tw 1.4 ai 0.8 col 0.3 co 0.0 ob 0.0 | hs 0.0 hd 0.0 sq 0.2 dov 1.7 dmm 0.2 | cm 0.1 rb 0.0
```

- `fr` 最大值已经不超过 16.7ms —— **周期性尖峰已解决**；
- 配置锁 60 后的最终帧率待真机复测确认；
- 若还要更多余量：先做 `dov`（overlay 静态/动态分层），再做 `tw`（箭塔/投掷物）。

### 17.4 接手检查清单

1. 用 **Release** 导出；确认读数第 1 行是 `mobile` / `release` / `crowd C#`。
   ★ 默认只显示一行 `FPS`：要那四行分段就把 `ui.show_perf_detail` 改成 `true`。
2. 确认第 2 行 `vs off`、`fr` 平均 ~16.7ms、`max` ≤16.7ms。
3. 如果出现 `Unicode parsing error`，先搜 `.gd` 里的 `\u0000`（见第 10 节第 9 条）。
4. 改完代码跑 `tools/run-tests.ps1`（当前 **48 文件 / 5822 项全绿**）；
   改了 C# 先 `dotnet build daeem.csproj -c Debug`。
5. 想回退某一块：`fog.backend=gdscript` / `unit.collision_backend=gdscript` /
   `ui.mobile_ui_stagger=false` / `ui.show_perf_detail=false`。

---

## 18. 操作手感修复（本轮：悬停残留 / 按下反馈 / 框选跟手 / 读数瘦身）

这一轮**没有动玩法**，只修手机端「手指用起来不对」的四处，外加把性能读数收成一行。
四处都补了断言（总数 5776 → **5806**，本轮结束时是 **5822**），全部在无头环境可复现。

### 18.1 长按按钮后移开手指，悬停还挂着

**症状**：在主菜单长按一颗按钮再抬起手指，那颗按钮的金色填充**一直留着**，
要再点别处才恢复。

**根因**：`fill_button` 在 `button_down` / `button_up` 里把 `_hovered` **钉住**
（某些平台按下时模拟鼠标会先「离开」，不钉的话按下去金反而退回去）。
而触摸抬起后 `emulate_mouse_from_touch` 的模拟鼠标**停在原地**、不会补发
`mouse_exited` ⇒ 没有任何一条路把 `_hovered` 复位。
`_sync_hover_filter()` 的自愈只在 `mouse_filter == IGNORE` 时才按坐标重算，压不住这条路。

**修法**：`view/start_screen.gd` 新增 `_input()` —— 收到**触摸抬起**
（`InputEventScreenTouch.pressed == false`）就 `call_deferred` 清整层悬停
（`FillButtonRes.clear_hover_in`）。

⚠️ **必须延迟一帧**：`_input` 早于 Button 的 `button_up`，同步清会被
`_on_button_up()` 那句「钉住悬停」在同一帧里又置回 true。
⚠️ 只认触摸事件：桌面鼠标仍靠真实的 `mouse_entered` / `mouse_exited`。

回归：`tests/test_menu_chrome.gd` 的 `_test_touch_release_clears_hover`。

### 18.2 点下去「立刻满格、随后自己退回去」

**症状**：点主菜单任一颗入口按钮，背景**瞬间**变满金，然后慢慢降下去。
用户要的是「**点的时候正向填充，返回的时候反向渐出**」。

**根因**（两个叠在一起）：
1. `menu_theme.button_selected()` 是**实心金**，被挂成了这些按钮的 `pressed` 底纹 ——
   底纹是**瞬时**的，和「自绘填充还在按 `FILL_TIME` 慢慢涨」叠在一起，第一眼就是满格；
2. 面板一撑开，`panel_expand` 把按钮的 `mouse_filter` 压成 `IGNORE` ⇒ 悬停被自愈清掉 ⇒
   那片金**在面板还开着的时候就退回去**。

**修法**：
- 所有挂了填充动效的菜单按钮，`pressed` 底纹改成 `button_fill_latched()`
  （**透明底 + 亮描边**）：按下只换描边，那片金完全交给填充层
  （`menu_chrome` / `menu_secondary_panel` / `campaign_menu` / `start_screen` / `map_select`）；
- `menu_chrome` 新增 `_latch_origin()`：点开面板时把**这一颗**按钮
  `set_latched(true)`（同一时刻只有一颗），面板收起
  （`panel_expand.reversed`）时 `_on_panel_reversed()` 解除 ⇒ 走 `DRAIN_TIME` **反向渐出**。
- `_on_panel_reversed()` 顺带清一次悬停：转场会把过滤器压成 IGNORE 再还原，
  还原那一下会按**鼠标坐标**把悬停算回来 —— 手机上那是模拟鼠标（还停在当初点的位置），
  不清理的话「返回之后按钮又自己亮起来」。
- `start_screen.open_menu()` 另外 `clear_latched_in(self)`：进游戏前点开的面板，
  回主菜单时解除常驻 ⇒ 反向渐出在「回来」那一刻才播。

回归：`test_menu_chrome.gd` 的 `_test_pressed_style_not_solid`（按下态必须透明底）、
`_test_expand` / `_test_reverse` 里的 `is_latched` 断言。

### 18.3 双指框选：右上 / 左下两个角不跟手

**症状**：右手在上、左手在下拉框时，选框的**右上角与左下角**离手指差一截；
换成另一条对角线（左上 / 右下）就正常。

**根因**（两层）：
1. `touch_controller._update_box()` 传给 `touch_box_set()` 的是**屏幕矩形的左上 / 右下**
   （`rr.position` / `rr.end`），它们只有在「一根手指左上、一根右下」时才等于手指；
   另一条对角线时它们落在**另一对组合点**上，真正属于那两根手指的两个角**没有被采集过**；
2. 即便喂的是两指本身，选框仍是按**世界轴对齐矩形**存、由 overlay 投影四个角 ——
   3D 相机是**透视**的，世界矩形的远端边投影回来会缩进 ⇒ 那两个角天然会偏。

**修法**：
- `touch_controller` 改喂**两指自己的坐标**（`_first_two_points()`），
  世界矩形负责「框到谁」，不再被屏幕盒子的组合点污染；
- `input_controller` 新增 `drag_screen_box` / `drag_screen_valid`，
  `touch_box_set(..., screen_a, screen_b)` 时一并记下**屏幕矩形**；
- `overlay_view_3d._draw_drag_box()` 在 `drag_screen_valid` 时**直接按屏幕矩形画**
  ⇒ 两个角逐像素落在手指上；松手 / 取消时作废，PC 那条世界四边形路径**一个字没改**。

⚠️ 取舍：判定仍用世界矩形（`box_select`），所以「画出来的框」与「选中范围」在透视的
远端有一点点差 —— 这是这套相机本身的几何，PC 一直如此；本轮只保证**手指上的两个角**精确。

回归：`tests/test_touch.gd` 的 `_test_two_finger_box_screen_rect`（含反斜对角线）。

### 18.4 性能读数：只留 FPS，移到左上

- 新配置 `ui.show_perf_detail`（**默认 false**）：
  - `false` ⇒ 左上角 `(6, 2)` 一行 `FPS 60`；**不**打开 `world.profile_on` /
    场景层 `perf_enable()`（那是真机排查才该付的开销，每帧一次 `Performance.get_monitor` 也省了）；
  - `true` ⇒ 回到原来那 4 行完整分段读数，位置同一处（向右铺 1240px）。
- `ui.show_perf` 仍是总开关（关掉一个字都不显示）。
- 涉及：`view/hud.gd`（`_build_perf_readout` / `_update_perf_readout` / `_process` 采样门）、
  `logic/config.gd`、`data/config.json`。

### 18.5 本轮涉及的文件

| 文件 | 改动 |
|---|---|
| `view/fill_button.gd` | 新增 `clear_latched_in()`（整棵子树解除常驻） |
| `view/start_screen.gd` | `_input()` 触摸抬起清悬停；`open_menu()` 解除常驻 |
| `view/menu_chrome.gd` | 点开面板锁住入口按钮、收起解除；按下态改透明底；收起时清悬停 |
| `view/menu_secondary_panel.gd` / `view/campaign_menu.gd` / `view/start_screen.gd` | 按下态改 `button_fill_latched()` |
| `view/touch_controller.gd` | 框选改喂两指本身 + 屏幕矩形 |
| `view/input_controller.gd` | `drag_screen_box` / `drag_screen_valid`，`touch_box_set` 多两个可选参数 |
| `view/overlay_view_3d.gd` | 触摸框选按屏幕矩形画 |
| `view/game_scene3d.gd` | 把屏幕矩形喂给 overlay |
| `view/hud.gd` / `logic/config.gd` / `data/config.json` | 读数只留 FPS（默认）、左上角；`ui.show_perf_detail` |
| `tests/test_touch.gd`（+9）/ `test_fill_button.gd`（+4）/ `test_menu_chrome.gd`（+17） | 回归断言 |

---

## 19. 操作手感修复·第二轮（框选判定 / 游戏内悬停 / 按下兜底）

第 18 节改完之后真机手玩又报了三条，这一轮补齐。**仍然没有动玩法**，只动「手指的判定口径」
与「按下反馈」。

### 19.1 框到了单位，却「有概率」没选中它（连同整支部队）

**症状**：双指框选时，明明看着框住了一个兵，松手却没选中它 —— 于是它所在的整支部队
也跟着没被选中。「有概率」= 取决于框画在单位的**哪个高度**上。

**根因**（两条，第 ② 条才是这个 bug 的真凶）：

1. **坐标系**：第 18 节把**画出来的框**改成了屏幕矩形，但**判定**还在用世界矩形
   （`box_select` 判 `rect.has_point(u.pos)`）。透视下「屏幕矩形 ⇄ 世界矩形」不是逆变换，
   两者形状对不上；
2. **判定对象**：单位在画面上是一张**立牌**（从脚底锚点 `u.pos` 向上
   `QUAD_W × QUAD_H_RATIO` 格，见 `view/unit_view_3d.gd`）。旧判定只问
   「**脚底那个点**」在不在框里 —— 玩家框住的是**看见的牌**，把框画在牌的上半部分时
   锚点在框外，于是「框住了却没选中」。框得越高越容易中招，所以看起来是「有概率」。
   漏了那个单位，`expand_to_groups` 自然也就没有它这一队可展开。

**修法**：
- 新增 `input_controller.box_select_screen(screen_rect)`：**在屏幕空间**判定，
  与画出来的框同一口径；
- 判定对象改成**立牌的屏幕矩形** `_unit_icon_screen_rect(u)`：
  底边 = 脚底锚点、宽 = `QUAD_W` 格（从投影算，跟着缩放变大变小）、高 = 宽 × `QUAD_H_RATIO`
  ⇒ **框到图标任何一部分都算框到**；
- `touch_box_end()` 改走它（没有屏幕点时退回世界矩形，无头 / 2D 老路径照旧）；
- 建筑仍按中心点判（`_buildings_in_screen_rect`）；
- 整队展开仍在 `select_units()` → `world.expand_to_groups()`：框到队长或任一附属兵
  都等于整支部队，**这条没有被绕过**；
- ★★ **PC 也一起统一了**（后续追加）：`_begin_drag` / `handle_mouse_motion` 同样记
  `drag_screen_box`，`_finish_drag()` 也走 `box_select_screen()`。于是
  **两端画出来的框都是屏幕矩形、判的都是立牌图标的屏幕矩形**，不再有「PC 判世界矩形 + 锚点」
  这条分叉；overlay 那条世界四边形绘制路径退化成「没有屏幕矩形时的兜底」。
  `box_select()`（世界矩形 + 锚点）保留，只给「没有投影（无头 / 2D 老路径）」与诊断调用用。

回归：
- `tests/test_touch.gd` 的 `_test_box_select_screen_and_group` ——
  ① 20×20 的小框套住脚底 → 选中，且框里（按图标矩形算）每个己方单位都被选中；
  ② **只框住立牌上半部分、脚底在框外** → 仍然选中（旧口径必漏的那一形）；
  ③ 两种情况下都展开成**整支部队**，且没有「框外又不属于框内部队」的单位被多选。
- `tests/test_ui.gd` 的 `_test_box_select_icon_body` —— 同一形在 **PC** 上走真实鼠标事件
  （按下 → 移动 → 抬起）复验：只框住立牌上半身也选中，并展开成整支部队。

⚠️ 顺带修掉同一文件里一条**老 flaky**：`_test_long_press_pan` 原来用
`create_timer(秒)` 等「长按」，而 `touch_controller` 判的是 `Time.get_ticks_msec()`（墙钟）。
`--script` 模式首帧 delta 可能很大，两者会错开 ⇒ 这条用例约一半概率变红。
现在改成**按墙钟轮询**（`while Time.get_ticks_msec() - press_ms < hold_ms: await process_frame`）。

### 19.2 游戏内按钮：手指移开后仍然满填充

**症状**：局内的设置 / 命令卡 / 页签等按钮，点一下再移开手指，金色填充留在上面。

**根因**：与第 18 节主菜单那条完全同源 —— `emulate_mouse_from_touch` 的模拟鼠标停在原地、
不补发 `mouse_exited`，而 `fill_button` 在按下 / 抬起时把 `_hovered` 钉住。上一轮只修了
`start_screen`（主菜单那一层），**HUD 这一层还没修**。

**修法**：`hud.handle_touch()` 在**抬起**分支 `call_deferred("_clear_hud_hover")`，
延迟一帧后 `FillButtonRes.clear_hover_in(self)` 清整棵 HUD 的悬停。
- 延迟一帧是必须的：Button 的 `button_up` 在 `_input` 之后才跑；
- **常驻满格（latched）不受影响**：选项页开着时那颗按钮照样是满格。

回归：`tests/test_settings_menu.gd` 的 `_test_touch_release_clears_hud_hover`。

### 19.3 按下兜底：确认按下 → 背景瞬间填满

**症状**：快速点按时，正向填充（0.18s）还没跑完手指就抬起来了 —— 玩家「明明按了」，
却几乎看不到满格反馈。

**修法**：`fill_button` 在 `setup_host()` 里接上宿主的 `pressed` 信号 →
`_on_pressed_snap()`：把 `_fill` 直接顶到 **1.0**（同时刷字色、重绘）。
- 只对**可点**的按钮生效（`_available == false` 的空槽 / 占位格不参与）；
- **不改目标**（`_goal()` 不动）：该锁在满格的（菜单入口）继续锁着，该渐出的
  （命令卡 / 一次性按钮）照旧按 `DRAIN_TIME` 渐出 —— 于是既保证「按了就有满格反馈」，
  又不破坏第 18 节那两段动画。

回归：`tests/test_fill_button.gd` 的 `_test_pressed_snaps_full`。

### 19.4 本轮涉及的文件

| 文件 | 改动 |
|---|---|
| `view/input_controller.gd` | 新增 `box_select_screen()` / `_buildings_in_screen_rect()`；`touch_box_end()` 改走屏幕判定 |
| `view/hud.gd` | 触摸抬起 → 延迟一帧清整层悬停（`_clear_hud_hover`） |
| `view/fill_button.gd` | `pressed` → `_on_pressed_snap()`（瞬间满格兜底） |
| `tests/test_touch.gd`（+4）/ `test_fill_button.gd`（+2）/ `test_settings_menu.gd`（+3） | 回归断言 |

---

## 20. Android 联机（实验性，2026.10.19）

M12 的联机层是 Godot `WebSocketPeer`，与平台无关；手机可以作为客户端连公网中继
`ws://159.75.154.122:8770/ws`，与 PC 同房。推荐 **PC 做房主、手机做客机**（房主跑完整
世界 / AI / 30Hz 快照，客机只发命令收快照）。

### 20.1 导出前必须改的两处

1. `export_presets.cfg` 的 `include_filter="*.json"`（Windows + Android）：
   地图 / 战役 / `config.json` 是**非资源 JSON**，不加进不了 PCK。
2. Android 的 `permissions/internet=true`：默认 `false`，手机端会连不上中继。

### 20.2 Android 构建

- 用 mono 版 Godot 与 mono Android 导出模板（本机已装 `4.7.2.stable.mono`）。
- `daeem.csproj` 的 Android 目标是 **net9.0**；需要 .NET 9 SDK / targeting pack。
- 需要 Android SDK + JDK 17；首次真机用 debug 导出（debug keystore）。
- 明文 `ws://` 若被 Android 明文流量策略拦截：自定义 manifest 打开
  `android:usesCleartextTraffic="true"`，或把中继换成 `wss://`。

### 20.3 大厅 / 输入

- 中继地址与房间码是 `LineEdit`，点进去用系统虚拟键盘；大厅版式是桌面 760px 宽，
  手机上只做过首次联机确认，没有逐像素验收。
- 手机作为客机时，触屏选中 / 框选 / 命令走既有的 `view/touch_controller.gd`。

### 20.4 已知限制

- 快照默认 **30Hz**（M12.7），没有插值，客机单位仍会按 30Hz 跳（与 PC 客机一致）。
- 30Hz 的客机 `apply + fog` 实测约 1.1 / 3.1 / 4.7 / 7.2 ms（36 / 136 / 336 / 536 单位）；
  手机做客机时建议 PC 做房主；若 500+ 单位掉帧，可把 `net.snapshot_hz` 回 20。
- 手机端只保证“能连、能玩”；性能与布局没有正式验收。
- 断线重连、客机接管、合作暂停、TLS 都不做。

---

## 21. 框选预览遮罩（2026.10.26）

### 21.1 口径

- **触摸端没有「悬停」**：模拟鼠标的位置在手指抬起后就停在原地，拿它做高亮会在屏幕上
  一直亮着一个兵 ⇒ 触摸端**只在双指框选期间**出遮罩，拖框之外一律不出。
- 双指框选的预览与桌面同一套**三级优先**：
  1. 框里的**己方单位**（严格同阵营）→ 这些单位**所属整支部队**一起亮（框外同队成员也亮）；
  2. 框里没有己方单位、但有**己方建筑** → 框里那一批建筑全亮；
  3. 都没有 → 什么都不亮（触摸端没有「光标单目标」这一档）。
- **判定口径必须等于松手后真正选中的范围**：触摸端用 `box_select_screen` 的同一套
  判据（单位按**立牌屏幕矩形**相交 + `ui.box_select_pad_px`；建筑按格中心屏幕点），
  桌面端用 `box_select` 的世界矩形。两条都在 `input_controller._hover_from_box()` 里分派。
- 松手后立刻收掉（遮罩按 `render.hover_fill_sec` 淡出 0.1s）。

### 21.2 性能

框选预览的判定与「松手那一次」同价（每个己方单位两次立牌投影）。手机上没必要 60Hz 地做，
所以触摸端**每 2 帧算一次**、奇数帧保留上一帧的预览（不清空，否则会闪）。桌面端不动
（世界矩形是一次点比较，很便宜）。

### 21.3 涉及的文件

| 文件 | 改动 |
|---|---|
| `view/input_controller.gd` | `_hover_from_box()` 按端分派判定口径；`touch_mode` / `hover_from_box` / 触摸端 2 帧降频 |
| `view/game_scene3d.gd` | 每帧镜像 `input_ctrl.touch_mode = touch_device`；`_hover_*_for_view()` 触摸端只放行框选预览 |
| `view/building_view_3d.gd` | `set_hover()` 收**地块数组**（框里可以多栋建筑） |
| `tests/test_hover_fill.gd` | 触摸端屏幕框 / 建筑 / 空框 / 无屏幕框回退 / 视图放行 的断言 |

### 21.4 真机验收

1. 双指框住一个兵（框只压住立牌一部分也算）：整支部队（含框外的同队成员）一起罩阵营色。
2. 双指框住一段己方城墙 / 塔：框里那几栋一起罩色；框到兵和建筑时只有兵亮。
3. 松手后遮罩 0.1 秒内消失，选中结果与遮罩亮起的那一批一致。
4. 单指点击地图**不应**出现任何遮罩。

---

## 22. 第四轮性能优化（2026.10.27：目标 90 帧 / 底线 60）

> 口径：**按 90 帧做，最低不能低于 60**（用户拍板）。设备 = 第二代骁龙 8。
> 这一轮**只动性能**，不改任何玩法规则；全量 `tools/run-tests.ps1` **87 文件 / 7982 断言全绿**
> （数字在加了 `tests/test_unit_backend_equiv.gd` 之后从 86/7974 变成 87/7982）。

> **★ 只想看结论 / 接手这轮的人，直接跳到最后：[22.19 本轮结算（一页看完）](#2219-本轮结算一页看完)。**
> 22.7 ~ 22.18 是按时间顺序追加的现场记录（每个问题 → 根因 → 改动 → 实测），
> 中间有几处**被测试打回**的尝试也留在里面 —— 那是刻意保留的，避免下次再踩。

### 22.1 先量清楚：桌面基准（`tests/bench_fps_3d.gd`，66 单位，1920×1080）

| 段 | 本轮之前 | 本轮之后 | 变化 |
|---|---|---|---|
| **墙钟 avg** | 5.90 ms | **4.64 ms** | **−21%** |
| `_process` 合计 | 2.70 | 2.41 | −11% |
| `tick`（逻辑） | 2.00 | 1.69 | −16% |
| `units`（单位循环） | 0.95 | 0.66 | −31% |
| `u/acquire`（索敌） | 0.404 | **0.075** | **−82%** |
| `u/morale`（士气） | 0.173 | 0.165 | — |
| `draw/overlay`（覆盖层 `_draw`） | 1.24 | **0.49** | **−61%** |
| `ov/capture_area`（占领触发区） | 0.675 | **≈0** | −100%（搬进静态层） |
| `draw/minimap` | 0.45 | 0.44 | —（手机端本来就是 5Hz） |

200 单位时：`avg 8.92 ms / tick 4.18 ms` ⇒ 单位循环斜率约 **18 µs/单位/帧**（桌面）。
**这条斜率就是「能不能上 300 单位」的真实尺子**，与引擎无关。

### 22.2 这一轮改了四处（都可单独回退）

1. **覆盖层拆静态层**（`view/overlay_layer.gd` 新增 + `overlay_view_3d` 改接线）
   - 网格 / 区划轮廓 / 占领触发区只随「相机 + 归属」变化，却跟血条一起每帧重录。
   - 现在它们在一个独立子节点里（`show_behind_parent = true` 保证画在宿主之下），
     只在 `_static_key_changed()` 为真时 `queue_redraw()`；相机静止时这段是 **0 成本**。
   - ⚠️ 绘制代码必须写在**子节点自己的 `_draw()`** 里：从宿主调 `node.draw_polygon()`
     会报 "Drawing is only allowed inside this node's `_draw()`"（实测）。
     所以分工是「宿主只算几何（`build_static_layer_data`）、子节点只发绘制」。
2. **三角化退出热路径**（`overlay_view_3d`）
   - 占领触发区每帧对每个梯形调一次 `Geometry2D.triangulate_polygon()`；进度条每格还要再拆一次。
   - 现在：四边形用**面积 + 凸性**判可画（4 次叉积），凸多边形走**扇形三角化**，
     凹 / 自交才回落到原生耳切；进度条的三角只拆一次并在同一帧复用。
3. **建筑索敌的负缓存**（`logic/unit.gd` 的 `bscan_*` + `logic/combat.gd`）
   - 没有敌方**单位**可锁的兵，每帧都会再问一次「附近有没有敌方建筑」（3×3 网格查询）。
   - 现在把「查过、结果是 null」连同**位置 / 半径 / `building_revision`** 一起记住；
     三项都没变 ⇒ 直接跳过。**精确判据**（返回值只由这三项 + 阵营决定）。
   - 顺带：`world._bgrid` 为空时直接返回；`FactionRes.same_side_for_attack` 在
     **没结盟**时不再拼 `_pair_key`（那条在每帧每单位的路径上）。
4. **建筑视图缓存**（`view/building_view_3d.gd`）
   - `_height_of()` 的 `"render.building_height.%s"` 配置查表按类型缓存；
   - `_transform_of()` 的静态部分（位置 / 缩放）按「建筑实例 + `building_revision`」缓存，
     受击振动仍是每帧现算的偏移量。

### 22.3 自适应分辨率：改成「降了没用就停手」

`view/game_scene3d.gd` 的 `_mobile_scale_tick` 原来是「帧率低就降 3D 分辨率」。
它在这个游戏上是**错的**：66 单位时 `rest`（GPU + 呈现）只占约 22%，降分辨率几乎不涨帧，
却把画面从 0.6 一路拖到 0.5 —— 玩家看到的是「莫名变糊」。

现在是 **A/B 探测**：每降一档，1.5 秒后比对帧率；涨不到 3% 就**还原这一档**并
`_mobile_scale_locked = true`（本次关卡不再尝试），并 `push_warning` 记一笔。
阈值也改成跟着 `mobile_max_fps` 走（× 0.55 / × 0.92），不再是写死的 26 / 52。

### 22.4 配置变更

| 键 | 旧 | 新 | 说明 |
|---|---|---|---|
| `render.mobile_max_fps` | 60 | **90** | 按 90 帧跑；它同时是自适应阈值的基准 |
| `render.mobile_3d_scale` | 0.6 | 0.6（不变） | 由 A/B 探测决定要不要降 |
| `render.mobile_auto_scale` | true | true | 降了没用会自动锁死 |

### 22.5 真机怎么验（四行读数）

把 `ui.show_perf_detail` 改成 `true`，进游戏后看：

1. 第 1 行 `mobile / release / crowd C#`；
2. 第 2 行 `vs off`、`fr` 平均 ≈ **11.1ms**（90 帧预算），`max` 不应长期超过 11.1；
3. 第 3 行 `dov` 应明显小于上一轮（覆盖层静态化之后）；
4. 第 4 行 `u/...` 不在读数里，但 `tk` 应比上一轮低 15% 上下。

判读：
- `fr` 贴着 11.1 但偶尔跳到 16.7 ⇒ 还有单帧尖峰，先看 `hs/hd/sq/dov/dmm`；
- `fr` 稳定在 13~14 ⇒ 还差 20%，下一刀应该砍 **`tk`**（逻辑），不是分辨率；
- 只看到画面变糊、帧率不动 ⇒ 自适应已经会自动锁死；若没有，说明那次降档被 A/B 探测判成「有用」，
  把 `render.mobile_auto_scale` 关掉复测一次。

### 22.6 还差多少（诚实版）

按桌面斜率折算到手机（约 ×3.75）：
- 66 单位：本轮之后 `tick ≈ 6.3ms`，帧 ≈ **12.5ms 上下（≈80 帧）**；
- 要到稳定的 90（11.1ms），还差约 **1.4ms**，只可能来自两处：
  1. **`tk` 再降**：`fog`（0.29）/ `zones`（0.23）/ `towers`（0.08）各自都能降到 20~30Hz
     （都是 dt 驱动的派生量），代价是要动 `world.tick` 的节流策略、并且要补计时断言；
  2. **`rest`**：真机确认是不是 GPU 之后，再决定降 `mobile_3d_scale` 还是给 2D 定渲染比例。
- **300 单位 @90 帧**：`tick` 单帧就会到 ≈ 11ms，**GDScript 主线程做不到** ——
  那需要把单位循环整段下沉 C#（`CrowdKernel` / `FogKernel` 是现成模板）。

### 22.7 2026.10.27 追加：dscj 的 20 帧与「守军集体不动」的根因

**（A）守军不动 = 一个自我维持的死锁**（`logic/garrison_ai.gd`，不是本轮性能改动引入的 ——
把本轮改动整体 stash 掉之后现象一模一样）：

```gdscript
if int(u.patrol_zone_id) == -2:          # ← 每帧都重置
    u.patrol_timer = patrol_interval * _phase01(u)
u.patrol_timer -= dt
if u.patrol_timer <= 0.0:                # ← 于是永远到不了 0
```

`patrol_zone_id` 只有 `_patrol_leader() → _ensure_route()` 才写成真实区划，而那条路要先让
计时器归零。计时器每帧被重新武装成 `interval × 相位`（0.3~4 秒）⇒ 归零永远不发生 ⇒
巡逻永不触发 ⇒ `patrol_zone_id` 永远是 -2 ⇒ 下一帧又重置。**不报错、不自愈。**

- 实测（dscj，256 单位，30 秒）：`patrol_zone_id` 恒为 -2，最大位移 **0.13 格**；
- 修法：错峰只在「计时器还没走过」时做一次（`and u.patrol_timer <= 0.0`）；
- 修复后同一场景：**222 / 258 个单位在 30 秒内移动过，最大位移 8.74 格**。

⚠️ 这条修复会让 dscj **变重**（守军真的开始走 → 迷雾每帧重算、巡逻寻路真的发生）。
之前那 20 帧是「一潭死水」跑出来的，不要拿它当基线。

**（B）dscj 的 20 帧是规模问题，不是回归**。桌面实测（`world.tick`，257 单位 / 27×42）：

```
world.tick 7.26 ms/帧
  units 2.93 (combat 1.67: morale 0.62 / acquire 0.38 / 其它 0.67;  step 0.70)
  fog   1.26
  ai    0.79 (garrison 0.77)
  zones 0.67
  collision 0.50
```

按手机 ≈ ×3.5 折算 ≈ **25ms 逻辑**，加视图 / 覆盖层 / 呈现 → 20~25 帧。
66 单位时 `tick` 只有 1.7ms（桌面）⇒ **dscj 这一个关卡的兵力是普通关卡的四倍**。

折算结论（同一条斜率的三种读法）：
| 单位数 | 桌面 tick | 手机 tick（×3.5） | 手机整帧（估） |
|---|---|---|---|
| 66 | 1.7 ms | 6 ms | ~12.5 ms ≈ 80 fps |
| 128 | 3.2 ms | 11 ms | ~19 ms ≈ 52 fps |
| 256 | 7.3 ms | 25 ms | ~35 ms ≈ 28 fps |

⇒ **90 帧的可行区间是 ≤64 单位；256 单位要 90 帧只能把逻辑搬进 C#**。
（C# 之后 `tick` 预计 7.3 → 2.5~3 ms（桌面），手机整帧 ≈ 13~15ms，也就是 60~70 帧；
再要 90 还得继续压 `fog` / `zones` / 视图。）

### 22.8 2026.10.27 追加：联机「同步慢几秒」的根因

**现象**：修好守军巡逻之后，PC↔手机联机从「能玩」变成「落后几秒」。

**实测**（dscj 256 单位，房主侧 10 秒采样）：

| 指标 | 修守军之前 | 修守军之后 |
|---|---|---|
| 活动单位 | 22 | 256 |
| 单条增量快照 | ~2 KB | **26.6 KB** |
| 30Hz 下的出站吞吐 | ~0.06 MB/s | **0.78 MB/s** |
| 事件流量 | ≈0 | ≈0（与它无关） |

移动端链路按文档实测只有 **0.3~0.6 MB/s** ⇒ 0.78 MB/s 必然堆积。

**为什么现有的 `snapshot_buffer_limit_kb` 没挡住**：它读的是
`WebSocketPeer.get_current_outbound_buffered_amount()` —— **本机 socket 的**积压。
字节一交给内核 / 中继，这一侧就归零了，真正的队列在**中继和手机上**。
于是带宽不够时它永远不触发，队列在中继里越堆越长 —— 玩家看到的就是「慢几秒」。

**修法**（`net/host_session.gd`）：加一条**每秒快照字节预算** `net.snapshot_budget_kb_per_sec`
（默认 256 KB/s）。它不看任何人报的缓冲，只看「我们自己这一秒推了多少字节」，
超了就跳过这一帧快照（下一帧发最新状态，旧帧没有补发意义）。
⇒ 吞吐被硬性夹住，延迟有上界，与链路 / 中继 / 平台都无关。

实测（假连接 + dscj）：5 秒内发 27 条、跳过 123 条，吞吐 ≈ 0.25 MB/s
（按 27.4 KB/条折算 ≈ 9 条/秒）。

**代价与调法**：客机目前**没有插值**，9 条/秒会比 30 条/秒跳。
- 链路好就调大：`512` ≈ 18 条/秒；`1024` ≈ 30 条/秒（只在好链路上可行）；
- 想更省就调小：`128` ≈ 4~5 条/秒（很跳，但延迟最小）。

**下一步（真正把 30Hz 拿回来）**：减小单条体积。`_unit_fields` 已经是短字段 + 增量，
但每条里 256 个单位仍各自重复 `i`（id 字符串）与 `ut`（兵种）。改成**按字段并行的数组**
（`ids/ut/x/y/h/...` 各一条数组）预计能砍 40% 以上 ⇒ 256 单位也能回到 15~20 Hz。
这是一次协议格式改动，房主与客机必须同版本，建议单独一轮做。

### 22.9 2026.10.27 追加：客机插值（9Hz 快照也能跑出 90Hz 的平滑）

**问题**：带宽预算把快照压到 ~9 条/秒之后，客机单位「一格一格跳」。

**★ 先说清楚一件事**：这**不是** C# 能解决的问题 —— 逻辑搬进 C# 只会让**房主**算得更快，
客机看到的仍是 9Hz 的位置序列。要让画面平滑，唯一正确的做法是**客机插值**
（网络频率与显示频率解耦），这也是后面「本地 30Hz 模拟」要用的同一套机制。

**做法**（三处，全部只在客机生效）：
1. `logic/unit.gd` 加 `prev_pos`（= 上一帧画在哪）；`logic/world.gd` 加 `render_alpha`
   （1.0 = 不插值，房主 / 单机 / 测试永远是 1.0）与 `render_pos_of(u)`；
2. `logic/snapshot.gd` 应用快照时：`prev_pos = 这一帧**真正画在屏幕上**的位置`
   （`render_pos_of`，不是旧的 `pos`）—— 否则「上一段插值没走完就来了新快照」会回跳；
   位置没变的单位 `prev_pos = pos`（否则 alpha 归零那一刻会跳回上一条快照）；
3. `net/client_session.gd` 每帧把 `render_alpha` 从 0 推到 1，窗口 = **实测快照间隔 × 1.2**
   （夹在 60~400ms）—— 于是 9Hz 会自动配 ~116ms 的窗口，不需要改任何配置。

**视图侧统一入口**：`unit_view_3d.render_pos_of()`。立牌、贴花、选中圈、**血条**全走它 ——
血条要是还用 `u.pos`，在 9Hz 下会跟立牌错开半格（肉眼可见）。

**实测**（headless，dscj 256 单位，8.7Hz 快照，6 秒）：
- 单帧最大位移 **0.039 格**，跳变帧 **0**；
- 对照：不插值时每 7 帧一次 **0.35 格**（正是「一格一格跳」）。

**回归风险**：`render_alpha` 在房主 / 单机下恒为 1.0 ⇒ `render_pos_of` 直接返回 `u.pos`，
与加这个功能之前逐位一致；`test_view3d`(258) / `test_snapshot_coop`(42) 等全绿。

### 22.10 2026.10.27 追加：单位循环下沉 C#（第一刀：士气）

**等价测试骨架先立**：`tests/test_unit_backend_equiv.gd`
- 同种子建两个 dscj 世界（256 单位），逐帧推进，**逐字段完全相等**（不是容差）；
- `world.unit_sim_used` 读的是**实际**跑的后端；配了 `csharp` 却回退时它会红 ——
  否则「等价测试绿得毫无意义」（拿两条 GDScript 路径互相比）。
- 默认跑「gdscript vs gdscript」= 顺便钉**确定性**；
  `$env:DAEEM_UNIT_BACKEND="csharp"` 时强制要求真跑 C#。

**落地顺序上的一个关键决定**：士气原来夹在 `combat.update_unit` 里（A 士气→A 战斗→B 士气→B 战斗，
逐个交错）。要批量就只能**把它挪成单位循环之前的一整遍**（两个后端都改）——
于是所有单位同一时刻结算士气/回复，再统一结算战斗。
- 唯一的行为差别：满血单位同一帧既回血又挨打时，现在先回血再挨打（原来取决于它在列表里的位置）；
- 踩到的坑：濒死将领原来因为 `update_unit` 第一句就 `return` 而**不吃**士气回血，
  挪成独立一遍后必须显式 `skip is_downed()`，否则双倍回复（`test_downed` 当场变红，5.9 vs 2.4）。

**内核**：`logic/unit/UnitMoraleKernel.cs`（`[GlobalClass]`，接口按批：几条 `int[] / double[] / byte[]` 进，
一个 `double[]` 出）。语义关键：**按下标顺序、就地推进** —— 队员读 `m[anchor]` 时，
若队长下标更小，读到的就是本帧已更新的值，与 GDScript 的逐单位顺序**精确一致**。

**实测**（桌面，dscj 256 单位，600 帧）：

| 后端 | `world.tick` |
|---|---|
| gdscript | 10.768 ms/帧 |
| **csharp(morale)** | **9.894 ms/帧** |
| 差值 | **−0.873 ms（−8%）** |

等价性：240 帧后 **0 处不同**（pos / tile / hp / morale / moving / path / attack_cd / hit_flash /
repath_timer / target / target_building 全字段）。

**为什么这一刀只值 8%**：组包 + 写回实测 0.2~0.7 µs/单位，而士气本身才 2.4 µs/单位。
真正的收益要等**整段 `update_unit`** 也搬过去（那时组包只发生一次，而不是每个子系统一次）。
这一刀的价值是**把流水线跑通**：开关、数组接口、等价测试、回退路径，后面每一刀都复用。

### 22.11 2026.10.27 追加：C# 下沉第二刀与两处「零分配」改造

**已落地（按实测收益排序）**

| 改动 | 类型 | 实测 |
|---|---|---|
| 士气 + 回血档位 → `UnitMoraleKernel.cs` | C# 内核 | `tick` **10.77 → 9.89 ms**（−8%） |
| 迷雾采集：`side_of()` 每帧缓存 | 去重复计算 | `fog` **1.26 → 1.08 ms** |
| 占领分桶：字典+Array → 纯整型链表 | 零分配 | 结构性改进，本机噪声下测不出显著差异 |

**关于「哪个才值得搬 C#」的实测结论**（dscj 256 单位，桌面）：

| 段 | ms/帧 | 成本真正花在哪 | 搬 C# 值不值 |
|---|---|---|---|
| `units`（combat/step/acquire） | 3.6~4.2 | **`Array` 前移（`path.remove_at(0)`）、对象属性写入、内核查表** | 低 —— 这些开销搬过去也照旧存在，除非连 `u.path` 的数据结构一起改（牵动快照/AI/测试） |
| `ai`（garrison） | 1.4~1.5 | 规则分支 + 字典 | 中 |
| `zones` | 1.2 | 已改成整型链表 | 已优化 |
| `fog` | 1.1~1.2 | 字典插入/遍历（剩下的部分） | **高** |
| `collision` | 0.9 | 已经是 C# | — |
| `morale` | 0.7 | **已 C#** | 已下沉 |

⇒ **下一刀应当切 `fog` 的采集本体**（字典去重 → 扁平数组 + 内核内去重），
而不是 `step_along_path`：后者的成本是 `Array` 的 `remove_at(0)`，那是 GDScript 的数据结构开销，
C# 侧只能把结果写回来，反而多一次组包。

**测量方法上的一个提醒**：本机同代码多次运行在 7.6~12.0 ms 之间漂移（±15%），
所以「单次前后对比」不可信。可信的是**同进程内 A/B**（像上面士气那一行：一个进程里跑两个后端），
或同一份 profile 里各段的**比例**。

### 22.12 2026.10.27 追加：fog 采集现状与「下一步该怎么做」

**已落地**：`_collect_contributors` 里 `FactionRes.side_of()` 的每帧缓存
（它内部要做联盟连通搜索 + 分配数组，原来每个单位/建筑都调一次）。
实测 `fog` 1.26 → **1.08 ms**。

**已论证但本轮未落地**（留给下一轮单独做，因为要动 fog 的核心判定）：

- 现在的管线是「字典（同格取最大半径）→ 再遍历字典压成三条数组」，两遍字典操作；
- 可以完全去掉字典：`FogKernel.BuildSight` 对同一格的多条贡献是**逐条 OR**，
  而半径 r1<r2 时 r1 的扇区 ⊆ r2 的扇区，**OR 的单调性保证「不去重、全部 OR」与「同格取最大半径」结果逐位相同**；
- 于是采集可以直接写进三条 Packed 数组，「有没有变」用**原生数组比较**（`==` 走 memcmp）代替遍历字典。
- ⚠️ 前提是扇区算法保持「半径越大看得越多」（以后若加真实遮挡，这条等价要重新论证）。
- ⚠️ 变更判定要注意：新判据（整表比较）比旧的（只比格集合）**更严**——半径变化也会触发重建，
  那只是多算一次，不会漏更新；反过来才会出 bug。

**方法论上的教训（本轮踩到）**：用行号切割脚本改 GDScript 极危险 ——
一次偏移就把相邻函数（`_build_sight_gdscript`）整段覆盖掉，而这在静态检查里看不出来。
改这类文件一律用**唯一文本锚点**替换，并且改完立刻跑对应测试。

### 22.13 2026.10.27 追加：fog 扁平表（字典彻底去掉）

**做了什么**：`_collect_contributors` 的「字典（同格取最大半径）→ 再遍历字典压成三条数组」
换成 `_collect_flat()`：直接把每一份贡献写进三条 Packed 数组，**完全不建字典**。

**为什么可以不去重**（这是整件事的关键论证）：
`FogKernel.BuildSight` 对同一格的贡献是**逐条 OR**，而半径 r1 < r2 时
「r1 的扇区」⊆「r2 的扇区」—— 由 OR 的单调性，
「不去重、全部 OR」与「同格取最大半径再 OR」结果**逐位相同**。
⚠️ 前提是「半径越大看得越多」；以后若加真实遮挡，这条要重新论证。

**变更判定**：从「遍历字典比对格集合」换成**原生数组比较**（`==` 走 memcmp）。
新判据比旧的更**严**（连半径与顺序一起比）—— 严的后果只是多重建一次，不会漏更新。

**实测**（同进程，dscj 256 单位 / 500 帧）：

| | fog 段 |
|---|---|
| 优化前（字典） | 1.26 ms/帧 |
| 每帧 `side_of` 缓存 | 1.08 ms/帧 |
| **扁平表（本次）** | **0.896 ms/帧** |

合计 **−0.36 ms（−29%）**。

**等价性**：同种子两个世界（一边 `fog.backend=gdscript`、一边 `csharp`）跑 400 帧，
每 30 帧逐方比对掩码 → **0 处不同**（逐字节相等）。`test_fog` 153 条断言全过。

**清理**：旧的 `_build_sight_csharp()`（从字典二次打包）已删除，避免以后有人误用一份过期 `_contrib`。

### 22.14 2026.10.27 追加：阵地性 AI 少一遍全表扫描 + 一次「安静机器」的稳定基线

**改动**（`logic/garrison_ai.gd`）：原来是**两遍**全量 `for u0 in world.units` ——
第一遍建 `alive_ids` / `retinues`，第二遍挑巡逻队长。现在合并成一遍：
第一遍同时收集「候选队长」（活着 + 有归属区划 + 没濒死），第二遍只走候选（dscj 里 34 人，而不是 256）。

⚠️ 不能把 `is_patrol_leader()` 直接挪进第一遍：它要查 `alive_ids`，而那个字典必须**填完**才准
（队长可能排在自己队员之后）。所以判身份留在第二遍，只是遍历范围小了。

**稳定基线**（机器安静时连跑 3 次，dscj 256 单位 / 500 帧，全部 `unit.sim_backend = csharp`）：

```
world.tick  6.16 ~ 6.49 ms/帧
  units     2.15 ~ 2.26
  ai        0.81 ~ 0.85      ← 合并扫描后
  fog       0.60 ~ 0.63
  zones     0.64 ~ 0.66
  morale    0.36 ~ 0.38
  collision 0.50 ~ 0.53
```

**★ 测量纪律（这次踩到了）**：同一份代码在有负载的机器上测出来是 9.2~12.0 ms，
安静时是 6.2~6.5 ms —— **差 50%**。所以：
- 只在「连跑 3 次、方差 < 5%」时采信绝对值；
- 跨时间点的对比一律看**同一次运行内的比例**，或者同进程 A/B。

按 6.2 ms 折算（手机 ≈ ×3.5）⇒ 逻辑约 **22 ms**；dscj 的 256 单位在手机上应当从 ~20 帧
升到 **30 帧上下**（还要加视图与呈现）。这已经是「一潭死水」那版没法比的 —— 但现在守军真的在动。

### 22.15 2026.10.27 追加：联机延迟与「太跳跃」——做了与没做的

**先纠一个我试过但被测试拦回的改动**：想从增量快照里去掉 `ut`（兵种），
它看起来是静态字段，256 个单位每条重复 `"ut":"spearman"`，占 22.1 KB 里的 ~3.8 KB（17%）。
但 `test_snapshot_delta` 有两条断言明确钉着它：

> 「兵种 ut 每帧都带（客机据此纠正兵种不一致）」
> 「快照 ut 把已有单位的兵种纠正回房主（不再一端骑兵一端步兵）」

⇒ 它是**建单位不一致时的自愈机制**，不是冗余。省掉 → 两端兵种可能永久不一致。**已回退。**

**真正做了的**：`net.snapshot_budget_kb_per_sec` 256 → **384**。

| | 每条增量 | 预算 | 实际速率 |
|---|---|---|---|
| 之前 | 22.1 KB | 256 KB/s | ~11.6 条/秒 |
| 现在 | 22.1 KB | 384 KB/s | ~17 条/秒 |

配合客机插值，端到端延迟大约从 ~86 ms 降到 ~59 ms，单位也不再一格一格跳。
（384 KB/s 仍在你文档记的 0.3~0.6 MB/s 链路范围内；链路好可以试 512，差就退回 256。）

**要再降一半，只能改编码**（下一轮）：
1. `ut` 发成**兵种小整数下标**（关键帧发表格），256 × 15 字节 → 256 × 2，省 ~3.3 KB；
2. 单位 id 发成**数字句柄**（关键帧发映射），省 ~2.5 KB；
3. 单位条目从字典改**并行数组**（`{"x":[...],"y":[...]}`），键名只出现一次，省 ~6 KB。

三条合起来 22.1 KB → ~10 KB，同样 384 KB/s 下能跑 **~38 条/秒**（30Hz 有富余）。
这是一次**协议格式改动**（`to_snapshot` / `merge_delta` / `apply_snapshot` 三处 + 两端同版本），
必须专门一轮做，且 `test_snapshot_delta` / `test_snapshot_coop` 要跟着更新。

### 22.16 2026.10.27 追加：快照带宽改成**自适应**（固定预算的两头都不对）

**问题**：384 KB/s 固定预算下用户仍觉得「跳」。算一下就明白：单条增量 **22.1 KB**，
384 KB/s ⇒ **17 条/秒**。而 `net.snapshot_hz` 的设计目标是 30 —— 好链路上白白浪费一半以上。

**做法**（`net/host_session.gd`）：预算不再写死，改成每秒结算一次的闭环。

- 反馈信号：`buffered_amount()`（本机 socket 积压）。链路真跟不上时它会先涨 ——
  门槛设在 **8 KB**（正常空链路是 0），比原来「塞满 64 KB 才拦」灵敏得多；
- 撞到积压 ⇒ 预算 **×0.7**（不低于 `snapshot_budget_min_kb`，默认 128）；
- 没积压、且窗口内**确实在跳帧** ⇒ 预算 **×1.25**（不高于 `snapshot_budget_max_kb`，默认 1024）。

**实测闭环**（假连接，脚本化推进时间）：

| 阶段 | 预算 |
|---|---|
| 起始 | 384 KB/s（≈17 条/秒） |
| 空链路 12 秒 | **937 KB/s**（≈30 条/秒，到 `snapshot_hz` 上限） |
| 拥塞 6 秒（积压 100 KB） | **128 KB/s**（≈5.8 条/秒，很跳但延迟最小） |
| 恢复 8 秒 | **610 KB/s** 并继续爬 |

⚠️ 踩到的坑（已有注释）：自适应原本写在背压 `return` **之后**，于是「一直拥塞 ⇒ 每条都提前
返回 ⇒ 结算永远不跑 ⇒ 预算永远不降」—— 正好是要它降的场景失效。结算必须排在任何 return 之前。

**效果**：好链路从 17 条/秒回到 **30 条/秒**（延迟 ~86ms → ~33ms），差链路自动退到 5.8 条/秒
保证不积压。两个参数都能在 config 里关掉 / 改范围。

**还剩下的**：单条 22.1 KB 里 ~10 KB 是重复的键名与字符串（`"i":"general-df-12"`、
`"ut":"spearman"`）。要再往下压只能改编码（兵种发整数下标、id 发数字句柄、条目改并行数组），
那是协议格式改动，需要两端同版本，单独一轮做。

### 22.17 2026.10.27 追加：**指令延迟**（用户实测：主机立刻响应、客机很慢）

这一条把方向彻底扭对了 —— 之前一直在压**快照带宽**，而症状是「**下移动命令后**客机才延迟」，
说明瓶颈是**指令往返**：

```
客机点右键 → 上行 cmd（RTT/2）→ 主机执行 → 等下一个快照节拍 → 下行 → 客机应用 → 插值再摊一段
```

主机端不经过任何一步，所以永远"立刻响应"。三处一起改：

1. **执行完客机命令就立刻补发一条快照**（`host_session._handle_command` → `send_snapshot(true)`）。
   命令本身就是"结果变了"的确定信号，没理由再等一个节拍 —— 最多省一整个 `snap_interval`。
   `force=true` 只绕过**每秒字节预算**（一次性一条），socket 背压仍然生效。
2. **`snapshot_hz` 30 → 40**（节拍 33ms → 25ms）。
3. 上一节的自适应预算保证：弱链路上 40Hz 跑不动时会自动降到能跑的速率，不会硬撑成堆积。

⚠️ `test_session` 原本把「默认 30Hz」写死，被这道改动打红。断言的本意是
「按 config 装配（夹在 10~60）」，已改成读 `cfg.num("net.snapshot_hz")` ——
**调频率的手感实验不该等于改测试**。

**还剩多少延迟**（好链路、40Hz）：上行 RTT/2 + 25ms 等待 + 25ms 快照传播 + 插值 ~30ms ≈ **80~100ms**。
再往下就只能靠**客户端预测**：客机下命令时立刻让**自己的**单位动起来（按直线先走），
收到权威快照后再校正。那是最后一刀，且必须只对"自己的单位 + 移动类命令"做，
否则会引入"单位穿墙/抖动"这类更难查的问题。

### 22.18 2026.10.27 追加：**按视野过滤快照**（联机延迟/跳动的真正病根）

**用户问**：「为什么之前至少能流畅联机，现在不行？」——答案是这次终于量到了：
快照把**全图 256 个单位**都发给了客机，而客机那一方「本方 + 看得见」只有 **26** 个。

```
总单位 256 · 属于本方 22 · 本方 + 看得见的 = 26
⇒ 快照里 230 个（90%）是客机既看不见、也不属于它的单位
```

这解释了两件事：
- **以前能流畅**：巡逻死锁把 234 个守军冻住了，它们的增量只剩 `"i"/"ut"`（没有坐标变化），
  一条快照约 9~10KB；
- **修好巡逻之后变差**：256 个单位真的在走 ⇒ 每条都要带 x/y ⇒ 22KB。**游戏从"假装有 256 个单位"
  变成真的在跑 256 个**，而联机层一直在无视视野地全量广播。

**改法**（`snapshot.to_snapshot(..., viewer_side)`）：
- 属于**同一方**（`side_of`，含盟友）⇒ 永远发；
- 其余只在**客机那一方的视野掩码**里该格非 0 时发；
- 出了视野的单位进 `"gone"` 列表，客机 `world.drop_unit_ids()` 把它从本地删掉。

⚠️ `gone` 这一条**不能省**：不删会留下幽灵单位 —— 画面上被迷雾遮住，却还在
`units` 里贡献视野、参与点选，**迷雾会越算越亮、点空地也会选中看不见的人**。
它也必须**在建索引之前**处理，且 `merge_delta` 要把多条 `gone` **并起来**（不能只留最后一条）。

**实测**（dscj，600 条）：单条 **22.1KB → 7.5KB（−66%）**；客机单位数恒定在 26，
并随单位进出视野正确变化（26 → 28）。`viewer_side == ""`（测试 / 回放 / 单人）⇒ 完全不过滤，
行为与从前逐位一致。

**顺手修掉的信息泄露**：以前客机手里握着全图敌军的位置数据（只是画面上被雾遮住），
现在它根本拿不到。

全量 `87 文件 / 7,982 断言 / 0 失败`。带宽从 ~0.66MB/s 降到 ~0.22MB/s（40Hz 时），
已经回到「以前流畅」的水平以下。

---

### 22.19 本轮结算（一页看完）

> 这一节是 22.7 ~ 22.18 的**汇总**：按「问题 → 根因 → 改动 → 实测」四列，加上配置旋钮与剩余待办。
> 细节与踩过的坑在各小节里，这里只给结论与数字。

#### 一、五个问题、五条根因

| # | 现象 | 根因 | 改动 |
|---|---|---|---|
| 1 | dscj 守军**集体不动** | `garrison_ai` 的「首次巡逻错峰」把计时器写成了**每帧重置**，而 `patrol_zone_id` 只有 `_patrol_leader()` 才会被赋值 ⇒ **自我维持的死锁** | 错峰只在「计时器还没走过」时做一次 |
| 2 | dscj 手机上只有 **20 帧** | 256 个单位 / 27×42 地图，桌面 `world.tick` 已 7.6ms；**兵力是普通关卡的四倍** | 分段优化（见三）+ 说明 90 帧的可行区间是 ≤64 单位 |
| 3 | 联机**同步慢几秒** | 守军复活后活动单位 22 → 256，单条快照 2KB → **22.1KB**，30Hz = 0.78MB/s，而移动端链路只有 0.3~0.6MB/s | 每秒字节预算（后改自适应）+ 客机插值 |
| 4 | 联机**太跳跃** | ①画面没有插值（网络 9~17Hz vs 显示 90Hz）；②**90% 的带宽发给了客机看不见的单位** | ①客机插值；②**按视野过滤快照** |
| 5 | 下命令后**客机延迟很高、主机却很快** | ①命令要走 主机执行 → 等下一个快照节拍 → 下行；②带宽被浪费 90% | ①执行完命令**立刻补发快照**；②视野过滤；③`snapshot_hz` 30 → 40 |

> ★ 3/4/5 其实是**同一件事的三个阶段**：把 ①号 bug 修好 ⇒ 游戏真的开始跑 256 个单位 ⇒
> 一直存在的「无视视野全量广播」暴露出来。**不是联机变差了，是游戏变真了。**

#### 二、性能改动与实测（dscj 256 单位，安静机器连跑 3 次取稳定值）

| 改动 | 类型 | 效果 |
|---|---|---|
| 士气 + 回血档位 → `logic/unit/UnitMoraleKernel.cs` | C# 内核（按批） | `tick` −8%（同进程 A/B −0.873ms），逐字段 0 处不同 |
| 迷雾采集：`side_of()` 每帧缓存 | 去重复计算 | `fog` 1.26 → 1.08 ms |
| 迷雾：字典 → **扁平表 + 原生数组比较** | 零字典 | `fog` 1.08 → **0.60~0.63 ms**（−29%） |
| 占领分桶：`Dictionary` + `Array` → **整型链表** | 零分配 | 结构性（噪声下测不出显著差异） |
| 阵地性 AI：**两遍全表扫描 → 一遍** | 少一次遍历 | `ai` 1.19 → **0.81~0.85 ms** |

稳定基线（`unit.sim_backend = csharp`）：

```
world.tick  6.16 ~ 6.49 ms/帧
  units 2.15~2.26 · ai 0.81~0.85 · fog 0.60~0.63
  zones 0.64~0.66 · morale 0.36~0.38 · collision 0.50~0.53
```

#### 三、联机三件套（真正的修复）

1. **`snapshot_budget_kb_per_sec` 改成自适应**（`snapshot_budget_adaptive`，默认 1）：
   每秒结算一次，撞到 socket 积压 ⇒ ×0.7（≥128KB/s）；没积压且仍在跳帧 ⇒ ×1.25（≤1024KB/s）。
   实测闭环：空链路 12 秒爬到 **937KB/s**，拥塞 6 秒退到 **128KB/s**，恢复后重新爬。
2. **客机插值**：`unit.prev_pos` + `world.render_alpha` + `world.render_pos_of()`；
   窗口 = 实测快照间隔 × 1.2（9Hz 自动配 ~116ms）。立牌 / 贴花 / 选中圈 / **血条**全走同一个入口。
   实测：8.7Hz 下**单帧最大位移 0.039 格、跳变帧 0**（不插值是每 7 帧一次 0.35 格）。
3. **按视野过滤快照**（`to_snapshot(..., viewer_side)`）：同方永远发，其余只在客机视野内发；
   出视野的进 `"gone"`，客机 `world.drop_unit_ids()` 删掉。
   实测：单条 **22.1KB → 7.5KB（−66%）**，客机世界 256 → **26** 个单位。

#### 四、配置旋钮（都在 `data/config.json`）

| 键 | 默认 | 说明 |
|---|---|---|
| `net.snapshot_hz` | 40 | 快照目标频率（代码夹在 10~60） |
| `net.snapshot_budget_adaptive` | 1 | 0 = 关掉自适应，用下面的固定值 |
| `net.snapshot_budget_kb_per_sec` | 384 | 固定值 / 自适应起点 |
| `net.snapshot_budget_min_kb` / `_max_kb` | 128 / 1024 | 自适应上下限 |
| `net.snapshot_buffer_limit_kb` | 64 | socket 积压超过它就跳帧（粗粒度背压） |
| `unit.sim_backend` | csharp | `gdscript` = 永远可用的回退路径 |
| `unit.collision_backend` | csharp | 同上 |
| `fog.backend` | csharp | 同上 |

#### 五、怎么验证（不用读代码）

- 全量测试：`powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1`（期望 `ALL PASS`）；
- **两个后端等价**：`$env:DAEEM_UNIT_BACKEND="csharp"` 后跑 `tests/test_unit_backend_equiv.gd`
  —— 它会在「配了 csharp 却回退成 gdscript」时**变红**，防止"绿得毫无意义"；
- 性能：`tests/bench_fps_3d.gd`（窗口化，非 headless）+ `DAEEM_PROFILE=1`；
- 真机：`ui.show_perf = true` + `ui.show_perf_detail = true`，看 `fr` 平均与 `max`。

#### 六、测量纪律（这一轮踩得最痛的一条）

同一份代码：**机器有负载时 9.2~12.0ms，安静时 6.16~6.49ms，差 50%。**
⇒ 只看「连跑 3 次、方差 <5%」的绝对值；跨时间点的对比一律用**同进程 A/B** 或**同一次运行内的比例**。

#### 七、剩余待办（按实测收益排序）

| 项 | ms/帧 | 为什么还没做 |
|---|---|---|
| `units` 2.2 | 最大一块 | 成本在 `path.remove_at(0)` 的**数组前移**与对象属性写入 —— 搬 C# 救不了，必须把 `u.path` 换成 packed 数组（牵动快照 / AI / 测试三处） |
| `snapshot` 编码 | 带宽 | 7.5KB 里仍有重复键名与字符串；改并行数组 + 兵种小整数 + id 句柄可再降 ~50%，但要两端同版本 |
| 客户端预测 | 延迟 | 剩下的延迟是到中继的**网络 RTT**，只有预测能把"看得见的等待"变成"看不见的校正" |
| `zones` 0.65 | 中等 | 分桶已改整型链表，`_advance_zone` 状态机仍是 GDScript |

#### 八、被测试打回的两处（**别再试**）

1. **从增量快照里删掉 `ut`**（兵种）：占 22.1KB 的 17%，看着像冗余。
   但 `test_snapshot_delta` 明确钉着「兵种 ut 每帧都带（客机据此纠正兵种不一致）」——
   它是**建单位不一致的自愈机制**。已回退。
2. **把士气当"分片"下沉**：实测打包成本 0.2~0.7 µs/单位，而士气全程才 2.4 µs/单位，
   碎刀会被组包吃掉大半。**要搬就整段搬**（这也是 `unit.sim_backend` 注释里的结论）。

---

## 23. 第五轮：手机 30 帧 → 60 帧（2026.10.28：固定逻辑步长 + 逐帧热点清除）

> 本节目录：① 要解决什么 · ② 先复现（`bench_dscj`） · ③ 根因（不动点） · ④ 方案（固定步长）
> · ⑤ 同时清掉的 9 处逐帧热点 · ⑥ 实测 · ⑦ 测试 · ⑧ 新增诊断分段 · ⑨ 怎么调 / 怎么回退 · ⑩ 剩余待办

#### 一、这一轮要解决什么

联机那一侧已经顺了（见 §22 与 `net/` 里的字节预算），但**手机单机 + command AI 跑
`dscj`（256 单位 / 27×42）只有 30 fps 左右**。

这一轮做两件事，按收益排序：

1. **把「逻辑步数 = 渲染帧数」这个结构改掉**（固定逻辑步长，手机 30 Hz）；
2. **清掉一批每帧固定开销**（`side_of`、树/建筑的 3×3 探测、迷雾烘图、区划容器…）。

结果：用户真机实测 **≈ 60 fps**；同一场景在桌面上的纯 CPU 从 **7.69 → 4.82 ms/帧（−37%）**。

#### 二、先复现：`tests/bench_dscj.gd`（新增）

`bench_fps_3d` 用的是 fallback 默认图 + 手动摆的一坨单位，**没有 command AI**，
和用户报的那一局不是同一个成本结构。所以另起一份，直接走
`main.gd` 的 `_on_coop_solo_started()` 那条路（`demo` 战役的 `dscj` 关 + `coop_ai`）。

★ 它与墙钟基准的关键差别：**手动驱动 `game._process(1/60)` 并逐次计时**。

* 量到的是**纯 CPU 帧成本**（逻辑 + 视图同步），不含呈现 / vsync；
* dt 固定 1/60 ⇒ 每帧要做的活与实机 60 Hz 一致（headless 那种 0.2 ms 的假 dt 量不出东西）；
* 每次调用之间 `await process_frame`，让 `_draw`（overlay / 小地图）也照常跑一遍。

```powershell
# 复现手机行为（30 Hz 逻辑 + 60 fps 渲染）
$env:DAEEM_DSCJ_STEP="33"; $env:DAEEM_DSCJ_FRAMES="180"
<Godot>_console.exe --headless --path . --script res://tests/bench_dscj.gd
# 对照：旧行为（每帧 tick）
$env:DAEEM_DSCJ_STEP="0"
```

读法：`CPU xx ms/帧` 是这一局一帧要多少 CPU；手机按 **×2.5** 估算；
下面两张分段表告诉钱花在哪（`tick` / `view/*` / `draw/*` / `props/*`）。

#### 三、根因：逻辑步数跟着渲染帧数走

旧写法（`view/game_scene3d.gd` 的 `_process`）：

```gdscript
events = world.tick(minf(dt, cfg.sim_max_dt))   # 每个渲染帧推进一次逻辑
```

于是**帧率越高，每秒跑的逻辑步越多、CPU 越贵**，系统稳定在一个不动点上：
手机停在 30 fps —— 一旦升到 40 fps 就多跑 33% 的逻辑步，立刻又掉回 30。
这就是「怎么优化都卡在 30」的真正原因，而不是某一项特别慢。

这与 `performance_and_network_doc/` 里那条 **MUST** 完全对应：
*「用固定步长模拟，不用可变 dt 直接驱动逻辑；把渲染帧率与逻辑 tick 解耦」*。

#### 四、方案：固定逻辑步长（桌面默认关，手机 30 Hz）

| 配置键 | 默认 | 作用 |
|---|---|---|
| `sim.step_sec` | `0` | 逻辑步长（秒）。**0 = 关闭 = 旧行为**（每渲染帧一步） |
| `sim.mobile_step_sec` | `0.0333333` | 手机端步长（仅当 `OS.has_feature("mobile")` 且 `step_sec == 0`） |
| `sim.step_max_steps` | `4` | 一帧最多补几步（防止长时间卡顿后一次补一大堆） |
| `sim.max_dt` | `0.05` | 仍在用：单帧最多推进多少秒（防死亡螺旋） |

实现要点（`view/game_scene3d.gd`）：

* 累加器：`_logic_accum += min(dt, sim_max_dt)`，攒够 `logic_step_sec` 才走一步；
* 步数换算抽成**纯函数** `take_logic_steps(accum, step, max_steps)`，测试直接钉它；
* **游戏速度不变**：60 帧 × 1/60 s @ 30 Hz ⇒ 恰好 30 步；120 帧 × 1/120 s 也一样
  （`tests/test_time_step.gd` 的断言）；
* **插值**：`world.begin_logic_step()` 在每步之前把 `u.prev_pos = u.pos` 记一笔，
  之后 `render_alpha = 累加量 / 步长`，视图统一走 `world.render_pos_of()`。
  ⚠️ 插值**只在走过第一步之后**才启用 —— 新建单位的 `prev_pos` 是零向量，
  提前插值会让它们从原点飞过来；
* **投掷物要外推**：否则 30 Hz 逻辑下箭是一跳一跳的。`view/projectile_view_3d.gd`
  用 `render_alpha × world.last_step_dt / p.duration` 按同一速度往前推；
* **客机不受影响**：客机不 tick，`render_alpha` 仍由 `net/client_session` 按快照驱动
  （两条路只共用同一个字段，互不覆盖）；
* 暂停时不累加（`running == false` 时整段不跑），恢复后不会瞬间补一大堆。

为什么手机取 30 Hz 而不是 60 Hz：**逻辑速度一样，但 tick 次数减半**。
RTS 的决策密度本来就在 10~30 Hz 量级，30 Hz 逻辑 + 60 Hz 渲染的画面与 60 Hz 逻辑
逐帧几乎不可分辨，而 CPU 直接省一半。

#### 五、同时清掉的逐帧热点（都做了行为等价性核对）

| # | 位置 | 改法 | 为什么值得 |
|---|---|---|---|
| 1 | `logic/faction.gd` | `side_of()` 加结果缓存（`set_allies` / `clear_allies` 时失效） | 它每次要建 1 字典 + 1 数组 + `sort()`，而它在**每帧几千次**的路径上（迷雾逐格、快照逐单位、区划逐单位、视图逐建筑/逐树） |
| 2 | `view/fade_stamp.gd`（新增） | 「3×3 内有可见单位」由**每对象 9 次 `Vector2i` + 哈希**换成**一张位图 + 1 次下标** | 树按 `tree_spacing = 0.5` 撒，100×100 图可达上万棵；建筑（墙上限 240）另算一遍 |
| 3 | `view/terrain_props_view.gd` | 淡出/迷雾/建筑占位都走位图与底层数组；装配时缓存「哪几格在图内」；位图与上一帧相同就整段跳过 | 这层原先**完全不在任何 profile 里**（一直算进 `rest`，是手机上最大的黑盒） |
| 4 | `view/building_view_3d.gd` | 主循环与旗面两趟共用同一张位图；`owner\|type` 桶键按「上一把」记忆；`Color.to_html()` 加缓存 | 原来是**两趟全量扫描 + 每栋两次字符串拼接 + 两遍 9 格探测** |
| 5 | `view/ground_view.gd` | 迷雾烘图的全图逐格循环不再调 `tile_visible()`，改为一次性读本方位图 | 29×22 = 638 次 / 100×100 = 1 万次，每次重烘都跑 |
| 6 | `logic/world.gd` | `refresh_after_snapshot()` **不再 `fog.reset_cache()`** | 那是客机每收一条快照（≤40 Hz）就把视野扇区缓存 / C# 地形表**从零重建**一遍；更要紧的是它会清掉 `_sighted` ⇒ **「敌方建筑见过一次就永久记住」在客机上被静默废掉**（房主上还在）。这是**性能 + 正确性**双修 |
| 7 | `logic/zone.gd` | 占领判定的容器（每区块 2 字典 + 1 数组）按 zid **复用**，每帧只 `clear()` | 24 个区块 = 每帧 72 次分配；实测 `zones` 0.334 → 0.278 ms（−17%） |
| 8 | `view/unit_view_3d.gd` | `has_method("render_pos_of")` 结果缓存（`setup()` 复位） | 每单位每帧问 2~3 次，而 `has_method` 是字符串查表 + 分派 |
| 9 | `logic/world.gd` | `_collect_destroyed_buildings()` 改**倒序按下标扫**，不再 `building_list.duplicate()` | 原来每帧一次 O(建筑数) 的数组复制 |

#### 六、实测

**主场景（`dscj` 256 单位 + command AI，手动 1/60 驱动，桌面 headless）**

| 指标 | 旧行为（每帧 tick） | 固定步长 30 Hz | 变化 |
|---|---|---|---|
| CPU / 帧 | 7.69 ms | **4.82 ms** | **−37%** |
| `tick` | 6.04 ms | **3.22 ms** | **−47%** |
| `fog` | 0.61 | 0.31 | −49%（跑得少一半） |
| `zones` | 0.50 | 0.25 | −50% |
| 手机估算（×2.5） | 19.2 ms ≈ 52 fps | **12.1 ms ≈ 83 fps** | — |

**分项 A/B（`bench_crowd` / `bench_fps_3d`，交替采样）**

* `zones` 0.334 → **0.278 ms**（256 单位，4 次采样一致）；
* `view/buildings` 0.309 → **0.250 ms**（64 单位）；
* `tick` 总量在测试图上落在噪声里（那些图森林稀疏，第 2~4 条的收益要等真实地图才显形）。

> 测量纪律仍然沿用 §22 第六条：同一份代码在机器有负载时会差 50%，
> 所以这里的结论一律来自**同进程 A/B** 或**同一次运行内的比例**。

#### 七、测试

* 全量 `tools/run-tests.ps1`：**88 文件 / 8006 断言 / ALL PASS**（基线 87 / 7982）；
* 新增 `tests/test_time_step.gd`（24 条）钉住三件事：
  1. 步数换算：攒够才走、`max_steps` 夹住、`step = 0` 时一步不走；
  2. **长期不漂移**：60 帧 @ 1/60 s & 30 Hz ⇒ 恰好 30 步；120 帧 @ 1/120 s 也是 30 步；
  3. 插值口径：`alpha = 0 / 0.5 / 1` ⇒ 起点 / 中点 / 终点，`begin_logic_step()` 只在
     `alpha < 1` 时写 `prev_pos`。

**踩到的坑（已修，记在这里免得再犯）**：`tests/test_fog.gd` 用的是 **FakeWorld 桩对象**，
没有 `profile_on` / `profile_sub`。新加的计时如果直接 `world.profile_on`，会抛错并**中断整个
`fog.update`** —— 表现是 38 条断言全红、「迷雾一片空白」。
⇒ 诊断计时一律 `world.get("profile_on") == true` + `world.has_method("profile_sub")`。

#### 八、新增的诊断分段（下次排查直接用）

第 4 行读数现在多了这些（都只在 `ui.show_perf_detail = true` 时计时）：

| 键 | 含义 |
|---|---|
| `z/update` / `z/population` / `z/ownership` | 区划「占领读条 / 人口累加 / 归属刷新」三段 |
| `fog/build` / `fog/prune` | 视野掩码构建 / 「见过的建筑」清理 |
| `props/fade` / `props/fog` | 树 / 山块的淡出判定 / 迷雾压暗 |

★ 还发现一件**不是问题**的事：`draw/minimap` 在桌面上约 1 ms/帧，但手机端被
`ui.mobile_minimap_hz`（当前 **5 Hz**）节流 ⇒ 手机上摊到每帧只有 ~0.08 ms。
**桌面读数里的这一项不要当成手机的成本。**

#### 九、怎么调 / 怎么回退

* 觉得 30 Hz 逻辑「不够跟手」：`sim.mobile_step_sec` 改 `0.02`（50 Hz）或 `0`（关掉、回旧行为），
  改数值即可，不用动代码；
* 某台机器仍然吃力：`0.05`（20 Hz）比旧行为仍省一半以上；
* 想让桌面也走固定步长：`sim.step_sec = 0.0166667`（逻辑速度不变，只是与帧率解耦）；
* **回退到旧行为**：`sim.step_sec = 0` 且 `sim.mobile_step_sec = 0`。

#### 十、剩余待办（2026.10.28 第六轮已清掉前三条，见第 24 节）

| 项 | ms/帧（桌面，60 fps 渲染） | 状态 |
|---|---|---|
| `units` 单位循环 | 1.7 / 256 单位 | ✅ **只做了清扫 + 测量，不做 C# 下沉**。真实分段见 §24.3；按决策规则（step 0.27 < 0.5、combat 0.56 < 1.2）收益不够，停止投入 |
| `fog` 变更检测 | 0.45 | ✅ 版本号闸门 + 采集微优化（§24.2）。**dscj 这种 256 单位一直在走的局面命中率只有 12%** ⇒ 只省 0.01~0.02 ms；大胜只能靠增量索引（未做） |
| `ai/garrison` | 0.79 | ✅ 决策 10 Hz + 缓存将领短列表 + 去掉 zone 线性查找与 `capture_bar()` 分配（§24.2）：**0.565~0.600 → 0.269~0.348 ms** |
| `draw/minimap` | 1.0（**桌面**，手机 5 Hz 已节流） | 若要继续压：把迷雾层也烘成贴图（地形已经这么做了） |
| `view/units` | 0.80 | 已是 MultiMesh 单批；剩余是逐单位投影与 `set_instance_*` |

---

## 24. 第六轮：units 实测 / fog 版本号闸门 / 驻防 AI 10 Hz（2026.10.28）

> 本节目录：① 方法 · ② 改动与实测 · ③ units 的真实分段 · ④ C# 边界结论（**别再试**）
> · ⑤ 配置旋钮与回退 · ⑥ 怎么验证 · ⑦ 剩余待办

### 一、方法：先修测量，再动刀

动工前发现**测量本身是坏的**：

- `world.tick` 的单位循环里每单位调两次 `_prof()`（`c0` / `_c1`，共 512 次/帧），而
  `t_combat / t_reclaim / t_step` 声明后**从未赋值** ⇒ `units/combat`、`units/reclaim`、
  `units/step` 三个读数**恒为 0**。§23 里那组细分是上一版代码留下的，已经作废。
- 修法：删掉两行无效调用与死变量；`profile_on` 与两个闪光衰减系数（`dt / flash_sec_safe`、
  `dt / hit_flash_sec_safe`）改成每帧算一次；给计时器衰减段加 `u/timers`。
- 另外给 `Unit` 加诊断计数器 `path_pops`，直接回答「`Array.remove_at(0)` 是不是病根」。

测量口径沿用 §22 六：同一台机器、连跑、只看同一次运行内的比例；A/B 用环境变量切开关，
不改 `config.json`。`tests/bench_dscj.gd` 新增 `DAEEM_FOG_GATE` / `DAEEM_GARRISON_INTERVAL`
两个 A/B 旋钮，并打印 `path_pops`、`move_to`、`repath` 与 fog 闸门命中率。

### 二、改动与实测

| 改动 | 类型 | 实测（dscj 256 单位，30 Hz 逻辑 + 60 fps 手动驱动） |
|---|---|---|
| 驻防 AI：决策降频 10 Hz（`ai.garrison.decision_interval_sec`，传入**累加 dt**） | 规则层节流 | `ai/garrison` **0.565~0.600 → 0.269~0.348 ms**（−43~55%），`ai` 0.68~0.70 → 0.39~0.44 |
| 驻防 AI：`alive_ids` 的 256 次字典插入删除（改走 `world.team_leader()`） | 少一次全表写 | 含在上面 |
| 驻防 AI：`zone_by_id()` 线性查找 → 一次决策建一张 `zid → zone` 表 | 去 O(队数 × 区划数) | 含在上面 |
| 驻防 AI：`_center_under_attack` 不再每队长每帧 `capture_bar()` 分配 Dictionary | 零分配 | 含在上面 |
| 驻防 AI：濒死复活每步只走「AI 将领短列表」（决策时缓存，dscj ≈ 34 个） | 30 Hz 256 → 34 次判断 | 0.315~0.348 → **0.269~0.348**（这一步单独再省 ~0.05） |
| fog：**版本号闸门**（`map.vision_revision` + `fog.revision_gate`） | 少一次采集 | `fog` 0.199~0.202 → 0.182~0.193 ms；**命中率只有 12.1%**（见 §24.2 的注） |
| fog：`_collect_flat` 采集微优化（阵营→方下标一张表、地形格换算内联） | 去重复查找 | 含在上面（闸门不命中时也省一点） |
| 单位循环：删死代码 + 每帧算一次衰减系数 + 修好细分计时 | 清扫 | `units` 1.06~1.10（与改前 1.09~1.11 持平），但四个子分段第一次有真实数字 |

总账（`CPU/帧`）：**5.11~5.19 → 4.76~4.84 ms（−0.3~0.4）**，`tick` 3.39~3.48 → 3.09~3.15。

**★ 关于 fog 闸门命中率（必须如实说）**：dscj 里 256 个单位一直在走，
按 30 Hz × 约 1.4 格/秒算，**每一步都有十来个单位跨格** ⇒ 版本号几乎每帧都变。
实测 11 次命中 / 80 次采集（12.1%），所以闸门在「打起来的战斗」里只值 0.01~0.02 ms。
它真正有用的场景是**单位停着**（驻守、布阵、看地图）——那时采集可以被整段跳过。
要在这个局面拿到大胜，只有 §2.1 里说的「增量索引」（格子→来源的增删表），
那是**另一轮 + 最高风险**，本轮不做。

### 三、units 的真实分段（第一次可读，替换掉 §23 里作废的旧表）

```
units                    1.06 ~ 1.10 ms/帧
  units/combat           0.55 ~ 0.58   ← update_unit（决策 + 追击 + 开火）
    u/timers             0.05 ~ 0.06   （五个计时器衰减，纯算术）
    u/acquire            0.18 ~ 0.20   （索敌；已经是 C# 批量内核的结果取用）
  units/step             0.255 ~ 0.284 ← 沿路推进
  units/reclaim          0.015
  其余                   ≈ 0.24       （循环本身 + 每单位分支 / 方法调用）
```

诊断：`path_pops` **0.21~0.26 次/帧**（256 个单位）。
⇒ 「成本在 `Array.remove_at(0)` 的数组前移」这条判断**不成立**：
单位一秒只走一格多，路点几秒才消费一次。§22.19 的结论（要救得先换 packed 数组）
比 §23.10 的「整段下沉 C#」更接近事实，但两条都不是本轮的主要矛盾。

### 四、C# 边界结论（决策表已执行）

| 实测 | 结论 |
|---|---|
| `units/step` ≥ 0.5 ms | ❌ 未达到（0.26~0.28） |
| `units/combat` ≥ 1.2 ms | ❌ 未达到（0.55~0.58） |
| ⇒ | **本轮不写 C# 内核，也不做 `u.path` 数据结构改造。** |

理由（写下来免得下次重新论证）：
- `update_unit` 的每一支都要回调世界（`move_to` 寻路、`push_event`、`ProjectileRes.spawn`、
  `world.unit_by_id`），整段下沉 = 把战斗 / 移动重写一遍（≥1000 行 + 完整 GDScript 回退），
  而它现在只占 **0.56 ms**（约整帧 CPU 的 11%）；
- 碎刀更不划算：§22.10 已实测组包 0.2~0.7 µs/单位，而 `u/timers` 全程才 0.05 ms；
- 真要 90 帧，剩下的钱在 `view/units`、`draw/minimap`、overlay，不在这里。

**下次如果单位数翻倍（≥500）再回来看这张表**：那时 `units` 会线性涨到 ~2.2 ms，
决策规则可能翻面 —— 但请先看「≥500 单位是不是本来就该改关卡设计」这个更便宜的选项。

### 五、配置旋钮与回退

| 键 | 默认 | 说明 / 回退 |
|---|---|---|
| `fog.revision_gate` | `1` | `0` = 关闸门，回到「每帧全量采集 + 数组比较」（**回退开关**） |
| `fog.verify_revision` | `0` | `1` = 闸门说「没变」时再全量校验一次，不一致则 `push_warning` 并按全量重建（排查「迷雾不刷新」用） |
| `ai.garrison.decision_interval_sec` | `0.1` | `0` = 每个逻辑步都决策（**回退开关**）；调大更省，但巡逻 / 守中心的反应会变慢 |

⚠️ **闸门漏钩子 = 迷雾静默冻结**（不报错、只是不刷新）。新增任何
「让某格多出 / 少掉一个视野来源」的路径，必须在 `world.mark_vision_dirty()` 里补一次；
位置变化不用管 —— `unit.sync_tile()` / `_sync_tile_if_changed()` 会自己在**真的跨格**时推进。
`tests/test_fog_revision.gd` 用「同一世界两个 FogRes、一个走闸门一个强制全量、300 帧逐字节比对」
兜这件事。

### 六、怎么验证

```powershell
cd dev_gd_a/daeem
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_fog      # 含 test_fog_revision
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_ai
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_campaign_ai
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_logic
$env:DAEEM_UNIT_BACKEND="csharp"
& '<godot>' --headless --path . --script res://tests/test_unit_backend_equiv.gd

# bench（A/B 只切环境变量，不改 config.json）
$env:DAEEM_DSCJ_STEP="33"; $env:DAEEM_DSCJ_FRAMES="180"
$env:DAEEM_FOG_GATE="1"; $env:DAEEM_GARRISON_INTERVAL="0.1"   # 本轮
& '<godot>' --headless --path . --script res://tests/bench_dscj.gd
$env:DAEEM_FOG_GATE="0"; $env:DAEEM_GARRISON_INTERVAL="0"     # 旧行为
```

本轮已跑：`check-syntax`（228 文件全过）、`test_fog` 183、`test_fog_revision` 30、
`test_ai*` 462、`test_campaign*` 487、`test_logic` 265、`test_time_step` 24、
`test_view*` 358、`test_snapshot*` 74、`test_ui*` 1448、`test_zone*` 301、
`test_recruit_queue` 248、`test_attack_orders` 107、`test_retaliation` 51、
`test_alliance` 78、`test_session` 33、`test_collision` 15、`test_crowd_path` 12、
`test_morale` 58、`test_downed` 265、`test_minimap*` 59、`test_smoke` 132 —— 全过。
**真机帧率与「迷雾会不会延迟刷新 / 守将反应是否更迟钝」需要你在手机上验**
（`ui.show_perf = true` + `ui.show_perf_detail = true`）。

### 七、剩余待办

| 项 | 值 | 为什么没做 |
|---|---|---|
| fog 增量索引（格子 → 来源的增删表） | 能把 0.19 压到 ~0.08 | 新数据结构 + 失效逻辑，风险最高；本轮闸门只值 0.02，先不做 |
| units 整段 C# | ~0.6 → ~0.3（估） | §24.4：收益不匹配工程量 |
| `draw/minimap` 1.0（桌面） | 手机 5 Hz 已节流 | 要继续压就把迷雾层也烘成贴图 |
| `view/units` 0.80 | — | 逐单位投影 + `set_instance_*`；要再压得改成按批写矩阵 |

---

## 25. 收尾：性能优化到此结束（2026.10.28）

> **结论**：用户确认 **手机端与电脑端都已流畅运行**，性能优化工作**正式结束**。
> 这一节是**一页交接**：现状、关键设置、历轮汇总、经验、验收 / 回退、**什么时候才需要再开**。
> 以后接手性能任务，先读这里；需要细节再按表里的节号往回翻。

### 25.1 现状（验收口径）

| 平台 | 场景 | 状态 |
|---|---|---|
| Android（真机） | `dscj` 256 单位 / 27×42 + command AI，30 Hz 逻辑 + 渲染 | **流畅（≈60 fps）**，用户 2026.10.28 确认 |
| Windows（桌面） | 同上，手动 1/60 驱动（纯 CPU） | **4.76~4.86 ms/帧**（基准见 §24.2） |
| 桌面 / 无头 | 单元测试、基准、编辑器 | 不受移动端开关影响（`OS.has_feature("mobile")` 门控） |

> ★ 真机帧率是**用户手动验收**的；自动化只能证明「逻辑与分段开销」。再开性能工作前
> 请先按 §25.5 拿一次 `ui.show_perf` 读数，不要凭印象。

### 25.2 关键设置（唯一一份，全部在 `data/config.json`）

**A. 逻辑节拍与插值**

| 键 | 默认 | 作用 | 怎么退 |
|---|---|---|---|
| `sim.step_sec` | `0` | 固定逻辑步长（0 = 每渲染帧一步 = 旧行为） | 设 0.0166667 让桌面也解耦；保持 0 即旧行为 |
| `sim.mobile_step_sec` | `0.0333333` | 手机端步长（仅 `step_sec == 0` 时生效） | `0` = 手机也回旧行为；`0.05` = 20 Hz 更省 |
| `sim.step_max_steps` | `4`* | 一帧最多补几步（防卡顿后一次补一大堆） | *代码默认 4，`config.json` 没写也生效 |
| `sim.max_dt` | `0.05` | 单帧最多推进多少秒（防死亡螺旋） | 调小更稳、严重掉帧时时间走得更慢 |

**B. 后端选择（C# 内核都有 GDScript 回退）**

| 键 | 默认 | 作用 |
|---|---|---|
| `unit.sim_backend` | `csharp` | 士气 + 回血档位走 `UnitMoraleKernel`（`gdscript` = 纯回退） |
| `unit.collision_backend` | `csharp` | 碰撞 / 索敌 / 寻路走 `CrowdKernel` |
| `fog.backend` | `csharp` | 视野扇区走 `FogKernel` |

**C. 变更检测 / 重活节流**

| 键 | 默认 | 作用 | 怎么退 |
|---|---|---|---|
| `fog.revision_gate` | `1` | 迷雾只在「有人换格 / 单位进出场 / 建筑增删 / 归属变动」时重算 | `0` = 每帧全量采集比较 |
| `fog.verify_revision` | `0` | 闸门判「没变」时再做一次全量校验并告警（排查用） | 平时保持 0 |
| `fog.rebake_min_sec` | `0.1` | 迷雾贴图最短重烘间隔 | 调大更省、观感更滞后 |
| `ai.garrison.decision_interval_sec` | `0.1` | 驻防 AI 决策周期（10 Hz；计时器按累加 dt 推进） | `0` = 每帧决策；`0.05` = 20 Hz |
| `ui.mobile_hud_refresh_hz` | `20.0` | 手机 HUD 刷新节拍（桌面每帧） | `0` = 不节流 |
| `ui.mobile_ui_stagger` | `true` | 手机 HUD 摊到 4 个槽位，削周期性尖峰 | `false` = 一次性全刷 |
| `ui.mobile_minimap_hz` | `5.0` | 手机小地图重画频率上限 | `0` = 不节流 |

**D. 移动端画面（只影响手机）**

| 键 | 默认 | 作用 |
|---|---|---|
| `render.mobile_3d_scale` | `0.6`（config；代码兜底 0.75） | 3D 渲染分辨率缩放（UI 不受影响） |
| `render.mobile_auto_scale` | `true` | 连续掉到 26fps 以下自动减 0.05（最低 0.5），回到 52fps 以上再加回 |
| `render.mobile_vsync` | `false` | 关 vsync 看真实帧率（代价是可能撕裂） |
| `render.mobile_max_fps` | `90`（config；代码兜底 60） | 帧率上限（0 = 不限；也是自适应分辨率的判据基准） |

**E. 诊断**

| 键 | 默认 | 作用 |
|---|---|---|
| `ui.show_perf` | 见 config | 左上角性能读数（FPS / 帧时间） |
| `ui.show_perf_detail` | `false` | 展开 4 行分段（`tk` / `vu` / `dov` / `rest` 与 `tick` 子分段） |
| `DAEEM_PROFILE` / `DAEEM_DSCJ_*` | — | 基准脚本用的环境变量（见 §24.6） |

### 25.3 历轮落地（性能相关的全部轮次）

| 轮次 | 主题 | 关键改动 | 实测 |
|---|---|---|---|
| §12 | 第二轮 | overlay 静态投影缓存、小地图迷雾烘图、地形块 | 周期性尖峰下降 |
| §15 | C# `FogKernel` | 视野扇区下沉 C#（按格缓存） | 视野不再逐格射线 |
| §16 | HUD 4 槽调度 | 手机 HUD 分槽 + 内容没变不重排 | 尖峰消失（`fr` max 不再到 25/33ms） |
| §20 | Android 真机 | Mobile 渲染器 / stretch viewport / 自适应分辨率 / vsync 关闭 | 真机可玩 |
| §22 | 第四轮（目标 90 帧） | overlay 拆静态/动态、索敌负缓存、快照按视野过滤 + 自适应预算 + 客机插值 | 联机三件套落地 |
| §23 | 第五轮（30 → 60 帧） | **固定逻辑步长 + 插值**、9 处逐帧热点 | CPU **7.69 → 4.82 ms/帧**；真机 30 → 60 |
| §24 | 第六轮 | units 实测（**不做 C# 下沉**）、fog 版本号闸门、驻防 AI 10 Hz | `ai/garrison` **0.57~0.60 → 0.27~0.35**；CPU 5.1 → 4.8 |

### 25.4 经验（跨轮，按重要性；下次先看这 8 条）

1. **先修测量，再优化**。本轮开头发现 `units/*` 三个分段**恒为 0**（累加变量没赋值）、
   循环里还留着每单位两次空 `_prof()`。测量错了，后面所有判断都错（[`pitfalls.md`](pitfalls.md) 5.86）。
2. **机器状态能差 50%**。同一份代码 9.2~12.0ms vs 6.2~6.5ms。只采信「连跑 3 次、方差 <5%」，
   跨时间点一律用**同进程 A/B** 或**同一次运行内的比例**（§22 六）。
3. **先找结构问题，再抠单点**。最大的那一刀不是某项快，而是「逻辑步数 = 渲染帧数」这个不动点；
   改成固定步长后 `tick` 直接减半（§23）。
4. **周期性尖峰要摊开，不要硬扛**：HUD 分槽、迷雾重烘合并、小地图降频、AI 分层 ——
   都是「把活摊到多帧 / 降频」，比逐项微优化有效（taste：宁可稍旧一点，也要稳的帧预算）。
5. **变更检测优先于重算**：迷雾扇区缓存 → 扁平表 → 版本号闸门；地形 chunk 同理。
   但**闸门只值它在场景里的命中率**：dscj 一直在走，命中率 12%（§24.2），
   要更大收益只能上增量索引（没做）。
6. **C# 只在「整段、无回调、可批量」时才划算**。士气那刀 8%，碎刀被组包吃掉；
   `units` 实测算完 ROI 后**明确不做**（§24.4）。搬之前先量 `per-unit µs` 与组包成本。
7. **每个改动留一个数字回退**。上面 A~D 四张表里每一项都能用 `config.json` 一个数退回去；
   没有回退开关的优化不要合入。
8. **文档会自相矛盾**：§23.10 说「整段下沉 C#」、§22.19 说「搬 C# 救不了」。
   遇到这种情况**以实测为准**，并把结论连同反例写进文档（§24.3 / §24.4）。

### 25.5 什么时候才需要再开性能工作（排查顺序）

1. **先看读数**：`ui.show_perf` 的 `fr` 平均与 **max**。均值高 = 每帧都贵；max 高 = 周期性尖峰。
2. **周期性尖峰**：按 §22 的清单查「每 N 秒 / 每 N 帧做一次重活」——
   HUD 全刷、迷雾重烘、小地图、快照批量应用、AI 全局重规划。
3. **均值高**：`ui.show_perf_detail` 看 `tk` 分段，谁最大查谁（§24.3 有一份真实分段的读法）。
4. **先问「这一局是不是本来就超规模」**：dscj 256 单位是普通关的四倍；
   90 帧的可行区间在 30 Hz 逻辑下是 ≤64 单位量级（§22.7）。
5. **最后才考虑结构改造**（C# 整段、packed 路径、增量索引、快照编码）——
   每一件的收益与风险都在 §24.4 / §24.7 里写着，别从那里开刀。

### 25.6 验收 / 回退（一条命令一件事）

```powershell
cd dev_gd_a/daeem
# 语法（最快、报行号最准）
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
# 相关套件（性能改动涉及 fog / ai / 单位循环 / 时间步）
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_fog
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_ai
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_logic
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_time_step
# 桌面基准（A/B 只切环境变量）
$env:DAEEM_DSCJ_STEP="33"; $env:DAEEM_DSCJ_FRAMES="180"
$env:DAEEM_FOG_GATE="1"; $env:DAEEM_GARRISON_INTERVAL="0.1"
& '<mono Godot>_console.exe' --headless --path . --script res://tests/bench_dscj.gd
# 真机：ui.show_perf + ui.show_perf_detail
```

**一键回退到「没做本轮优化」**：`fog.revision_gate = 0` + `ai.garrison.decision_interval_sec = 0`
（本轮两项）；再往回退到固定步长之前：`sim.step_sec = 0` 且 `sim.mobile_step_sec = 0`。

### 25.7 明确不做（写下来防止反复）

| 没做 | 为什么 |
|---|---|
| `units` 整段下沉 C# | 实测 `units` 只占 ~1.1ms/帧；`update_unit` 每一支都回调世界（寻路 / 事件 / 投掷物），整段重写 ≥1000 行（§24.4） |
| `u.path` 改 packed 数组 + 游标 | `path_pops` 实测 0.21~0.26 次/帧，`remove_at(0)` 不是病根（§24.3） |
| fog 增量索引 | 能把 fog 从 0.19 压到 ~0.08，但要维护「格子→来源」的增删表与失效逻辑，风险最高（§24.7） |
| 快照编码（并行数组 / 兵种整数 / id 句柄） | 视野过滤后单条已 7.5KB，带宽够用；改协议要两端同版本（§22.19 七） |
| 客户端预测 | 剩下的延迟是网络 RTT，属于联机手感，不属于性能（§22.17） |
| 服务端 tick / 多线程 | 单机与双人合作都不需要，且会破坏确定性测试（§22 / §23） |

> **优化结束**。以后新增玩法若踩到预算，按 §25.5 的顺序先测量、再决定 ——
> 不要凭「感觉哪里慢」直接改代码。
