# 手机端：操作、UI 与性能排查记录

> 本文是「手机端适配」这一轮的完整交接文档：**做了什么、为什么这么做、实测到哪一步、还剩什么**。
> 新任务可以直接从这里接手，不必重新翻聊天记录。
> 相关文件：`view/touch_controller.gd`、`view/input_controller.gd`、`view/game_scene3d.gd`、
> `view/hud.gd`、`view/minimap.gd`、`view/overlay_view_3d.gd`、`view/fill_button.gd`。

---

## 0. 一句话现状

- **操作逻辑**：手机端已可用（单指拖视野 / 双指框选 / 单击下令 / 双击行军 / 长按 UI 看悬停）。
- **底栏 UI**：详细信息面板已自适应拉伸，与「阵营/盾徽/旗帜」不再有缝。
- **渲染器**：已切到 **Mobile**（`rendering/renderer/rendering_method="mobile"`），Release 导出。
- **性能**：从「Debug 20 帧」提升到「Release 36 帧（66 单位）」；但 **CPU 仍 ~40ms/帧**，
  其中逻辑与视图同步只占 ~10ms，**约 30ms 落在绘制阶段**（overlay / 小地图 / 2D 合成）。
- **下一步重点**：优化 `overlay_view_3d._draw()`（每帧全屏矢量化重画）与小地图绘制。

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

### 1.3 实测读数（手机左上角性能读数）

| 阶段 | 帧率 | CPU（平均/峰值） | 备注 |
|---|---|---|---|
| Debug 导出、Forward+ | ~20 | — | 渲染器还是 Forward+，且是 Debug 包 |
| Release、Mobile、0.75 3D 缩放 | 25 | 45/— ms | 修「按钮主题覆盖风暴」之前 |
| Release、Mobile、**颜色缓存修复后** | **36** | **39.9/40 ms** | 最新 |

最新一帧的分段（单位：ms/帧）：

```
FPS 36 · mobile · release · C# · 66u · map 29x22
2400x1080 · CPU 39.9/40.0ms · DC 155
tk 8.1 (u 2.0 fg 2.1 z 1.0) | vu 1.0 vb 1.1 | rest 29.6
```

- `tk` = `world.tick` 总耗时；`u` 单位循环、`fg` 迷雾、`z` 区划。
- `vu` / `vb` = 单位 / 建筑视图同步。
- `rest` = 帧时间减去上面这些分段后剩下的部分。
- **结论：逻辑（8ms）和视图同步（2ms）都不是问题；`rest 29.6ms` 是瓶颈。**
- 注意：`CPU 39.9ms` 与 `FPS 36`（≈27.8ms/帧）对不上，说明 `Performance.TIME_PROCESS`
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
   - 手机端重画频率节流到 **15Hz**（`ui.mobile_minimap_hz`）。

3. **overlay 血条**
   - 原来每个单位最多 **3~5 次 `palette.to_px`**，且**无屏幕外剔除**。
   - 现在每个单位**一次投影**（新增 `unit_view_3d.quad_screen_size()`）+ 视口外（留 64px）剔除。

4. **地面 / 迷雾重烘**
   - 原来每 15 帧重烘时都 `Image.create` + `ImageTexture.create_from_image`（新建 + 显存上传）。
   - 现在**复用 Image / 贴图缓冲**，尺寸不变时 `ImageTexture.update()` 原地更新。

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
     单位点仍是逐单位 `draw_rect`。手机端 15Hz 重画，仍是不小的一笔。

3. **2D UI 的填充**
   - 窗口 2400×1080，`canvas_items` 模式下 **2D UI 按全分辨率绘制**；
     半透明面板约占屏幕 31%，叠在 3D 上（3D 仍要完整渲染）。
   - `mobile_3d_scale = 0.75` 只降低 3D 分辨率，不影响 2D。

4. **GPU 呈现 / 透明层**
   - 地面（不透明）+ 迷雾（全屏 alpha）+ 地图边界（透明 shader）+ 半透明 UI。
   - `DC 155` 正常，不是合批问题；但填充率在 2400×1080 上仍有成本。

---

## 3. 建议的下一步（按优先级）

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
- 或把重画频率从 15Hz 再降到 ~10Hz（手机上感知不明显）。

### P2：2D 分辨率（可选，牺牲清晰度）

- 若确认是填充率：把 `window/stretch/mode` 从 `canvas_items` 改成 `viewport`
  （整个游戏按 1920×1080 渲染再放大），GPU 负载固定，UI 会略软。
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

手机端顶部**偏右**的四行读数（`ui.show_perf = true`，默认开；仅 `OS.has_feature("mobile")` 时创建）。
★ 位置从左上角挪到 `x = 620`：左上角会被部队列表 / 将领 UI 挡住，读数看不清。

```
FPS 46 · mobile · release · crowd C# · 66u · map 29x22
2400x1080 · 120Hz · vs off · fr 19.1 (9.8~33.4)ms · proc 37.3/37.3ms · DC 160
tk 8.9 (u 2.0 fg 2.0 z 1.2) | vu 1.1 vb 1.2 | rest …
ec … rc … tw … ai … | col … co … ob … | hs … hd … sq … dov … dmm … | cm … rb …
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
- 120Hz 屏上 **60fps 的预算是 16.7ms**；`fr` 平均 19.1ms 就只差 ~2.4ms。
- `fr (min~max)` 的跨度大 → 周期性尖峰（HUD 刷新 / 小地图 / 重烘），
  优先把周期性任务降频或摊到多帧，而不是优化平均值。

> 读数的实现：`view/hud.gd` 的 `_build_perf_readout` / `_update_perf_readout`；
> 分段计时复用工程原有的 `profile_on` / `profile_us`（`logic/world.gd`、`view/game_scene3d.gd`）。
> 手机端会打开 `profile_on`；桌面/无头不创建读数、也不开计时。

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
| `view/squad_panel.gd` | 手机端刷新节流 |
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

---

## 11. 下次接手的最短路径

1. 先跑 Release，读三行性能读数，确认 `mobile` / `release` / `crowd C#`。
2. 看 `rest` 是否仍占大头：
   - 是 → 做第 3 节 P0（overlay 静态/动态拆分）+ P1（小地图迷雾烘图）。
   - 否，`tk` 大 → 看 `u`（单位循环）/ `fg`（迷雾）/ `z`（区划）。
   - 否，`vu/vb` 大 → 看 `unit_view_3d.sync` / `building_view_3d.sync`。
3. 每次改完都跑 `tools/run-tests.ps1`，并真机复测三行读数。

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
（27×22 = 594 次查询 + 594 个图元；手机上还有 15Hz 节流）。

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

1. Release 包进游戏，看左上角三行读数：
   - `rest` 应该比上一轮的 **29.6ms** 明显下降（相机静止时最明显）；
   - `FPS` / `CPU` 才是最终判据，不要只看某一帧。
2. 相机**保持不动**几秒，再平移 / 缩放，观察 `static_rebuild_count` 只在后一种情况下增加。
3. 小地图上的迷雾应与大地图一致；单位移动时不会有「迷雾方块跟不上」的滞后
   （掩码变化后下一次 15Hz 重画就会重烘）。

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
"mobile_max_fps": 0,
```

- ★★ **默认已经是 `false`**：手机端进游戏时直接
  `DisplayServer.window_set_vsync_mode(VSYNC_DISABLED)`，按原始帧时间跑，
  不再被刷新率量化到 45/40/30 档；
- 代价是可能有撕裂、发热/耗电增加；看到撕裂就把 `mobile_vsync` 改回 `true`；
- `mobile_max_fps` ⇒ `Engine.max_fps`（0 = 不限）。保持 0。

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

第 4 行现在会给出 `ec / rc / tw / ai / col / co / ob` 的真实拆分。
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
- `troop_grid._apply()`：格子内容（含 hp / hp_max / 士气 / 编制数）没变不重画；
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
- 选中变化强制全刷：`refresh()` + squad 各一次。
