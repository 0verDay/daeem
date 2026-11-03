# tools/ 说明

## run-tests.ps1 —— 一键跑完所有无头测试

```powershell
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_path   # 只跑名字含 test_path 的
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -List               # 只列出要跑哪些
```

行为：遍历 `tests/test_*.gd`，逐个用

```powershell
<Godot>_console.exe --headless --path <工程根> --script res://tests/test_xxx.gd
```

跑一遍，**靠退出码判定成败**，最后打一张汇总表。任一文件失败或崩溃 → 整体退出码 1。

引擎路径优先取环境变量 `$env:GODOT_EXE`，其次才是本机的
`C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe`。

> ⚠️ **为什么是 mono 版**：工程里有一份 C# 群体内核（`logic/crowd/*.cs`，
> 1000 单位群编的性能前提）。**普通版 Godot 不会加载 C# 程序集** ——
> 用普通版跑，碰撞会自动退回 GDScript 实现（不会崩，但慢 200 倍），
> 而 `test_csharp_bridge.gd` 会直接红。跑测试请统一用 mono 版。

### 三条不能改的约定

1. **必须用 `_console.exe`**。GUI 版（`..._win64.exe`）会 detach，
   stdout 抓不到、`$LASTEXITCODE` 是空的 —— 那等于测试没有结论。
2. **必须靠退出码**，不要改成解析输出文本。一旦退出码永远返回 0，
   整套测试就变成「永远绿灯」的摆设，比没有测试更糟。
3. **这个 .ps1 文件里只许写 ASCII**。中文 Windows 的 PowerShell 5.1 会把
   无 BOM 的 `.ps1` 当 GBK 解码，任何中文字面量都会变成乱码并**直接解析报错**
   （`-Encoding UTF8` 救不了：引擎在脚本有机会设置编码之前就已经解码完了）。
   所以中文说明放在这个 md 里，脚本本身只输出 `[OK]` / `[FAIL]` / `ALL PASS`。

### 单跑某一个

```powershell
& 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe' `
  --headless --path 'C:\Users\yy197\Documents\GitHub\daeem\dev_gd_a\daeem' `
  --script res://tests/test_smoke.gd
```

只想知道某个脚本**结构上**能不能过（不执行）：

```powershell
& 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe' `
  --headless --path '<工程根>' --check-only --script res://logic/grid.gd
```

`--check-only` 是排查 GDScript 解析/编译问题最快的一条路，
它比跑整个测试更早、更准地指出出错的行号。

## setup-font.ps1 —— 把中文字体拷进 assets/ 并导入

Godot 默认字体没有中文字形，不装字体的话 HUD 与事件日志全是方框。
跑一次：

```powershell
powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1
powershell -ExecutionPolicy Bypass -File tools/setup-font.ps1 -Force   # 重新拷一份
```

它做两件事：

1. 从 `C:\Windows\Fonts` 拷一份中文字体到 `assets/fonts/`（**不进 git**，
   见 `.gitignore`）。换台机器重新跑一次即可。
2. 再跑一次 `--headless --import`（引擎路径与 run-tests.ps1 同一套约定：
   `$env:GODOT_EXE` 优先，否则 `C:\D\GodotEngine\gd4.7.2mono\..._console.exe`）。

> ⚠️ **第 2 步不能省。** `view/font_loader.gd` 先找 `res://assets/fonts/...`，
> 而这条路径**只有被 Godot 导入过**（旁边有 `.import`）才成立；没导入就会退到
> `C:\Windows\Fonts`，按 `config.json` 里的候选顺序**抓到另一份字体**（雅黑，而不是刚拷进去的黑体）。
> 游戏照样显示中文，但**字体度量不一样**：`tests/test_ui.gd` 里 4 条「文字装得下」的断言会红，
> 而红的原因跟代码无关（在一台全新机器上实测过：不导入 4094/4098，导入之后 4098/4098）。
>
> 找不到引擎时脚本会黄字提醒，然后**保留已拷好的字体**退出（退出码 0）；导入失败
> （或跑的是会 detach 的 GUI 版、`$LASTEXITCODE` 为空）则退出码 1 ——
> 别让「其实是没导入」被当成绿灯。

## bake_unit_sprites.py —— 把美术素材烘成 3D 立牌贴图

```powershell
python tools/bake_unit_sprites.py            # 默认读 ../../../art_draft/test_assets，写到 assets/test_units
python tools/bake_unit_sprites.py --src <素材目录> --out <输出目录> --art <art_draft 根目录>
```

产物：

- `SpearMan/spearman.png`：人 + 剑（剑当长枪用）。
- `LongbowMan/longbowman.png`：人 + 弓。
- `Rider/rider.png`、`GrainCart/grain_cart.png`、`Knight/knight.png`、
  `HorseArcher/horse_archer.png`、`Catapult/catapult.png`：`art_draft/` 根目录的
  **整张原画**（`骑手.png`、`粮车.png`、`骑士.png`、`马弓手.png`、`投石车.png`）原样拷贝。
- `GLYPH_TARGETS` 目前为空。将来若某兵种缺素材，把它加进这个表即可继续生成**单字**占位
  （字从 `data/config.json` 的 `unit.types.<id>.icon` 现读，不会两处不一致）。
- `Projectile/arrow.png` / `arrow_white.png`：箭的投射物贴图（白剪影那张给材质染阵营色）。

改了 `art_draft/test_assets` 的源图、`art_draft/` 根目录的原画、或改了某个兵种的 `icon` 之后重跑一次即可；
跑完让 Godot 导入（`--headless --import`）再进游戏。

## bake_unit_card_icon.py —— 烘命令卡 / 科技格的**图标蒙版**（兵种 / 建筑 / 科技）

```powershell
python tools/bake_unit_card_icon.py                        # 出对比图（不写 assets/）
python tools/bake_unit_card_icon.py --only rider,catapult --ascii
python tools/bake_unit_card_icon.py --commit --style etch
```

一次烘**三套**东西，产物都在 `assets/ui/card_icon/`（384×384）：

| 前缀 | 来源 | 画法 |
|---|---|---|
| `<原画文件名>` | 兵种的 2D 原画 | 抠黑描边 → **细化成中线** → 加粗 |
| `combo_<条目 kind>` | 一次出 2/3 个兵的组合条目 | 小人在各自格子里单独取线，摆成「o o」/「o + o o」 |
| `building_<建筑类型>` | `view/building_view_3d.gd` 的 `BUILDING_MODELS`（.glb） | 抽折角边 + z-buffer 消隐 → **等轴测线稿** |
| `tech_<科技 id>` | 没有原画，按名字手画 | `TECH_SHAPES` 里的矢量占位图形 + 阶数点 |

- **源清单不写死**：兵种读 `data/config.json` 里所有非空 `sprite`（现在 15 张），
  建筑读 `BUILDING_MODELS`（现在 8 个可建造的），科技读 `tech.list` + `tech.clan_list`（22 条）。
  加了兵种 / 建筑 / 科技，脚本自动跟上。
- **组合条目也自动跟上**：config 里带 `spawn`（≥2 个兵种）的招募条目会额外烘一张
  `combo_<条目 kind>.png` —— 2 个排成「o o」、3 个排成「o」在上「o o」在下，
  每个小人按自己的格子缩放、竖直居中，整块仍留 6% 外边距（`combo_boxes()`）。
- **三版风格**：`relief`（实心金浮雕）、`flat`（纯剪影 + 亮边）、
  `etch`（**金线线稿，当前采用**：把黑描边细化成一根中线再加粗，87px 下仍连续）。
  `etch` 的两个关键点写在脚本的 ETCH_* 旁边：黑边阈值 0.16、连通域必须用 **8 连通**
  （4 连通会把斜线判成碎点，整条线被当噪点删掉 —— 这就是「线断成一节一节」的成因）。
- **建筑不是「描 3D 渲染图」**：脚本直接读 .glb 的顶点 / 三角，按折角阈值取边，
  再用 z-buffer 做消隐，等轴测投影（方位 42°、俯角 28°）之后画线。三个坑都写在
  `_visible_edges` / `_zbuffer` / `bake_building` 旁边：**薄壳的边界边要无条件保留**
  （否则墙像被切掉一半）、**深度方向别写反**（写反只剩几根线）、**空像素要单独判**
  （zb 是 inf 时 `zz <= inf` 恒真，背后看不见的边会漏画成悬空线）。
  另外每条边按采样点判可见，**短缺口会被补齐**（≤6 个采样点）—— 这是「割裂感」的正解。
- **科技是占位**：`TECH_SHAPES` 里一条科技一组折线，右下角点数 = 阶数。
  以后有真原画，换掉同名 png 即可，运行时不用改。
- **产物约定**（`--commit`）：
  · `relief` / `flat`：**RGB = 明暗 / A = 形状**；
  · `etch`：**RGB = 白 / A = 线覆盖率**（乘主题金就是纯金线）。
  运行时不加 shader，直接 `draw_texture_rect(tex, rect, false, ink)` —— `ink`（主题金）
  乘上去就上色，换皮肤不用重烘，锁灰档与悬停压金翻面自动继承（见 `view/unit_card_icon.gd`）。
- **`.import` 里要开 mipmap**（`mipmaps/generate=true`）：384 → 86.67 的缩量很大，
  不开 mipmap 细线会闪。`--commit` 会**自动**把它打开（`_ensure_mipmaps()`），不用手改。
  运行时的图标层用 `TEXTURE_FILTER_LINEAR_WITH_MIPMAPS`。
- **`--preview`** 写到仓库根 `art_draft/card_icon/`：`preview_<style>.png`（220px 大图）、
  `preview_small.png`（**真实格子尺寸 87px**，判断辨识度看这张）、`contact_sheet.png`，
  另外 `preview_buildings.png` / `preview_techs.png` 是建筑与科技的单行大图。
  ⚠️ 大图那几张必须**先把子图缩到格子大小再贴**（`_scaled()`）—— 早先直接贴 384px 原图会
  互相压盖、右下被裁，「预览里有的单位只剩一角」就是那一步的锅，不是蒙版坏了。

> ⚠️ 换了素材 / 改了风格要重跑 `--commit`，再 `--headless --import`。
> 缺 `.import` 时 `ResourceLoader.exists()` 为 false，运行时会**静默退回矢量金线兜底** ——
> 症状是「改了素材但画面没变」（与 `setup-font.ps1` 那个坑同一类）。


## 引擎路径

`C:\D\GodotEngine\...` 只在本机成立。脚本允许用 `$env:GODOT_EXE` 覆盖，
否则换台机器会全跑不了。**不要**为了图省事把引擎拷进工作区（会让仓库变脏）。
