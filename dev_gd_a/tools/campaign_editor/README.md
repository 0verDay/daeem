# DAEEM 战役编辑器（`tools/campaign_editor`）

Python + tkinter，**零第三方依赖**，一个目录装完，双击 `campaign_editor.bat` 就能进。

它管的是**战役与关卡**：谁参展、谁可玩、谁挂什么 AI、往哪打、开局建筑 / 单位 /
附属单位规格 / 区划归属 / 红点生成配置、目标与失败条件。数据落在 `daeem/data/campaigns/<id>/`：

```
data/campaigns/<campaign_id>/           ← 目录名 = 战役 id（与「一个地图一个目录」同构）
├── campaign.json                       ← 战役元信息 + 关卡顺序
└── levels/
    ├── 01_beachhead.json               ← 关卡文件（顺序以 campaign.json 的 levels[] 为准）
    └── 02_twin_line.json
```

## 跑法

在仓库根目录：

```
python dev_gd_a/tools/campaign_editor                      # 打开上次那个战役；没有就挑第一个
python dev_gd_a/tools/campaign_editor data/campaigns/demo   # 直接打开一个战役目录
python dev_gd_a/tools/campaign_editor --new my_campaign     # 新建一个战役（真的落盘）
python dev_gd_a/tools/campaign_editor --selftest            # 不开窗口，跑一遍数据层自检
python dev_gd_a/tools/campaign_editor --list                # 列出所有战役目录
```

在 `dev_gd_a` 目录下也能用模块形式跑：`python -m tools.campaign_editor --selftest`。

参数：

| 参数 | 作用 |
|---|---|
| `--project` | Godot 工程目录（默认 `dev_gd_a/daeem`，与另两个编辑器同一个默认值） |
| `--new ID` | 在 `data/campaigns/ID/` 下建一个战役（顺手建第一关：**一关都没有的战役读不出来**） |
| `--name` / `--map` | 配合 `--new`：战役显示名 / 第一关用哪张地图 |
| `--selftest` | 不开窗口跑自检（列地图 / 列战役 / 跑校验 / 在临时目录里做一次往返） |
| `--list` | 列出所有战役目录后退出 |

双击 `campaign_editor.bat` 一样（拖一个**战役目录**到它上面 = 直接开那一个）。

## 三个工具的分工

| 谁 | 管什么 | 数据在哪 |
|---|---|---|
| `tools/map_editor` | 地形 / 区划 / 中心 / 地图自带的大本营 | `data/maps/<id>/map.json` |
| `tools/unit_editor` | 兵种 / 将领（含**编制上限**）/ 建筑 / 科技数值 | `data/config.json` |
| **`tools/campaign_editor`**（本工具） | **战役与关卡** —— 开局建筑 / 单位 / 附属单位规格 / 区划归属 / 红点配置 | `data/campaigns/<id>/` |

本工具**只引用地图、只读配置**：地形 / 区划 / 中心是**从地图读出来画成背景**的，
要改它们请点界面上的「打开地图编辑器」（它会给 `map_editor` 传 `--map <当前关的地图 id>`）。

> ⚠️ **地图预置单位（`map.json` 的 `units[]`）已经废弃**：运行时不再读它，地图编辑器
> 导出时也会把它丢掉。敌人开局站在那里，只能靠**关卡的摆放**（③ 阵营页摆点 + ④ 摆放页摆单位）。

## ★★ 开局部队 = 摆将领 + 配「附属单位规格」

**不再有逐兵摆放**（旧的 `start_units[].escort_of` 只在读旧数据时兼容）。本轮改法是：
**在画布上摆将领 → 在侧栏给这位将领设一份规格**，运行时会**当场随机生成**满编附属兵
（`logic/world.gd` 的 `fill_general_retinue`），阵地 AI 脱战后也**按同一份规格**补员。

规格两项：

| 字段 | 意思 |
|---|---|
| `escort_count` | 生成几个（**不能超过这位将领的编制上限** —— 在 unit_editor 的「将领」页改，`unit.general.caps`） |
| `escort_types` | `[{"type": <兵种 id>, "weight": <float>}]`：按权重随机抽兵种，**权重和必须为 1** |

* 红点性 AI 的将领用**红点页里那份共享规格**（同一个模板）。
* ★ **某一方只要摆了将领，运行时就整个接管这一方**：连那 3 位将领都得你自己摆；
  一个将领都没摆的一方 → 运行时照旧自动生成 3 位将领（**且它们光杆**，由阵地 AI 按
  `ai.garrison.min_retinue` 自己招）。

## 七个页签

### ① 战役

战役名 / 简介 / 默认模式（`solo` / `coop`）/**关卡顺序**。

* 左边的列表就是关卡顺序；`▲ 上移` / `▼ 下移` 改顺序，`＋ 新建关卡` / `－ 删除关卡` 增删。
* 顺序写进 `campaign.json` 的 `levels[]` —— **文件名的字典序只是没写顺序时的兜底**。
* 删除关卡只从 `levels[]` 里移除，**不删文件**（编辑器不替人删文件：删错了没法撤销）。
* 右栏是 `factions[]`（`id` / 名字 / 颜色 / **可玩**）。`playable: true` = 玩家能选谁。

### ② 关卡

当前关的名字 / 模式 / 地图 / **目标** / **额外失败条件**。

* 地图下拉扫 `data/maps/`（`hidden` 与 `placeholder` 的图**照样列出来**，只是标一句「仅战役」/「占位」）。
* 模式一改，玩家席位数跟着变（合作 = 2 个席位，单人 = 1 个）。
* **目标**：第一版只有一种 —— 「守住某个区划 N 秒」/「攻占某个区划」。
* **额外失败条件**：第一批只有「指定区划失守」（`zone_lost`）；「大本营被拆」那条是**常开的**。

### ③ 阵营

上栏是**玩家席位**（1 或 2 个：阵营 + 大本营），下栏是**每一方一行**：

| 字段 | 说明 |
|---|---|
| 大本营 | 关卡点位（★ AI **不建大本营**，这个点位只当出生锚点）；留空 = 用地图的 `faction_bases` |

★★ **AI（类型 / 进攻目标 / 生成区域 / 高级参数）不在这一页、也不在编辑器里改**（用户要求：
「我不会通过编辑器改动 ai」）。⚠️ 这些字段**一个字没动** —— 编辑器仍然原样读、原样写
（不会丢），要改就直接手改关卡 JSON 的 `factions[]`（`ai` / `attack_target` /
`spawn_region` / `garrison_ai` / `reddot_ai`）。校验照旧按这些字段给提示/拦截。

★ **开局部队不在这一页摆** —— 在 **④ 摆放页**里摆将领 + 配规格。

### ④ 摆放

画布：**左键**放 / 选，**右键**删，**滚轮**以光标为锚点缩放，
**中键拖动**或**空格 + 左键拖动**平移视野，**`Esc`** 退出「设进攻目标」模式。

* 左键是「**按下**起来、**松开**才落地」的：挪了 3 像素以上就当成拖动（`DRAG_TOLERANCE`）。
* ⚠️ 拖动期间 **tk 不保证发 `<B1-Motion>`**，所以在 `on_motion` 里按 `state` 的 B1 位**也**分派一遍。
* **画笔三档**：**将领 / 单位 / 建筑** + 兵种（从 `config.json` 读）+ 归属阵营。
  （★ **没有「附属兵」这一档**了 —— 附属单位按规格随机生成。）
* **建筑所见即所得**：城墙 = 横贯整格的粗线、箭塔 = 居中的圆、大本营 = 居中的方块。
* 选中**将领** → 侧栏出现「**附属单位规格**」编辑器（生成数量 + 可变长度的「兵种 / 权重」行，
  实时显示权重和与编制上限；≠1 / 超上限会红字提示，导出会被拦）。
* 选中普通单位 → 归属 / 兵种 / `zone` / `hold` / AI / 名字。
* ★ **大本营不算「已有」**：它在阵营页里改，**不允许**在摆放页删。
* 摆放**不做自动避让**：允许你压在区划中心格上，但**导出会拦**。

### ⑤ 区划

一张表 —— 每一块地开局归哪个阵营（写 `zones[].owner`）。

* 「（用地图的）」= **不写这个键**（用地图自带的 `zone_list[].owner`）；
* 「（清空 = 无主）」= **显式写空串**（`owner: ""`）—— 与「没提这一区」是两件事。

### ⑥ 红点（单独页签）

* **生成地块**：在画布上左键点空地 = 加入 / 移出「红点生成地块」（游戏里这些格子的外观
  **没有任何区别**；只是出生点集合）。校验会拦地图外 / 山上的地块。
* **生成时间表**：`生成频率` 与 `将领数` 两个 `y = a·x + b` 表达式（`x` = 波次；频率的 `y`
  单位是**分钟**）。例：`x+1` → 第 1 波 2min、第 2 波 3min；`2x+1` → 第 1 波 3min。
  空着 = 用 `config.ai.reddot` 的默认（都是 `x`）。
* **将领类型和权重**：三位占位将领各一行权重（和必须为 1）。
* **附属单位规格（共享）**：所有红点将领共用（生成数量 + 兵种权重）。

### ⑦ 校验与导出

跑全部硬拦截 + 警告，逐条显示「通过 / 警告 / 拦截」。**有拦截项时禁止写文件**。
本页还有「一键打开地图编辑器」（当前关的地图）。

## 校验清单（`model.validate_campaign`）

`code` 与 `logic/level.gd` 的 `_ck_*` **逐字一致** —— 编辑器、测试、运行时三边靠它对暗号。

**拦截（`block`，不许导出）** —— 原有的点位 / 席位 / 目标 / 进攻目标 / 阵营检查（18 条）仍然保留；
**本轮新增**：

| code | 判据 |
|---|---|
| `escort_count_negative` | 将领 / 红点的附属单位数量是负数 |
| `escort_count_over_cap` | 数量超过该将领的**编制上限**（`unit.general.caps`） |
| `escort_types_missing` | 设了数量却没给类型权重表 |
| `escort_weights_sum` | 附属单位权重和 ≠ 1 |
| `escort_type_unknown` | 引用了 config 里没有的兵种 |
| `reddot_expr_invalid` | 生成频率 / 将领数表达式解析不了（只支持 `y=ax+b`） |
| `reddot_general_weights_sum` | 将领类型权重和 ≠ 1 |
| `reddot_spawn_tile_invalid` | 红点生成地块在地图外 / 山上 |

★ **旧模型（`escort_of` 逐兵摆放）**：本工具不再产出，但仍然**读得进、校验得了**
（`escort_no_general` / `escort_is_general` / `general_index_dup` / 警告 `escort_faction_no_general`），
所以老数据不会因为改了模型就读不出来。

**警告（`warn`，不挡导出）**：`no_attack_target` / `attack_target_own_land` / `ally_unknown` /
`faction_no_color`。

## 数据契约（改任何一处都要同步改逻辑层）

* **LF 行尾、无 BOM**：写文件时 `encoding="utf-8"` + `newline="\n"`；读的时候宽容 `utf-8-sig`。
* **省略等于默认值的字段**：`base` / `attack_target` / `garrison_ai` / `reddot_ai` / `spawn_region`
  为 `None` 时**都不写**。
* ★★ `start_units[]` 里**源文件写过**的键要原样写回去（每个单位自己记一份 `declared` 键表）；
  `escort_count`（≥0 就写，含 0 = 明确的「别补兵」）/ `escort_types`（非空或源里出现过才写）。
* `factions[].reddot_ai` 的新键：`wave_time_expr` / `general_count_expr` / `general_weights` /
  `spawn_tiles` / `escort_count` / `escort_types`。
* `players[].base` **没写就不写这个键** —— 与 `{"base": [-1,-1]}` 是两件事。
* `zones[].owner == ""` 是「**显式清空**这一区的开局归属」，与「没提这一区」是两件事。
* 关卡 JSON 里**本编辑器不认识**的字段（含 `_comment`）原样带回去 —— 导入 → 导出不许掉字段。
* **`model.py` 与 `levelfile.py` 不许 `import tkinter`**（数据层的测试不开窗；校验逻辑只有一份）。
* **往返比较按「语义」而不是「字节」**（`levelfile.canonical_payload`）：数字统一成 float、
  无意义的数组排序、**字典的键顺序抹平**。

## 测试

```
python dev_gd_a/tools/campaign_editor/test_model.py   # 不开窗（数据层）
python dev_gd_a/tools/campaign_editor/test_app.py     # 开窗（界面），跑完自动 withdraw()
```

两份都靠**退出码**表达成败（0 = 全绿），并打印 `[CASE] ... passed N / failed M`；不需要 pytest。

* `test_model.py` 覆盖：往返（逐字段一致 / LF / 无 BOM / 不多写默认值 / **键序不影响比对**）、覆盖规则、
  校验每条坏样例、AI 指派三种取值、四种 `attack_target` 的往返、附属部队（旧 `escort_of` 模型 +
  导出把将领排在兵前面）、目标与失败条件的强制、坏输入、增删排序关卡，
  以及一条兜底断言：**整场测试结束后真 `data/**` 逐字节未改**（测试只动临时副本里的副本）。
* `test_app.py` 覆盖：页签切换（**七个页签**）、画布放置 / 删除 / 缩放、`Esc` 退出目标模式、
  空格 + 左键拖动平移、③ 与 ④ 改同一个字段的一致性、**④ 的附属单位规格（摆将领 → 配数量 + 权重 →
  超上限 / 权重和 ≠1 被校验拦住）**、新页（区划 / 红点）能进、导出拦截对话框、一键跳转（假 subprocess）、
  侧边栏「装得下就不许滚」。起不了 Tk 的机器会打印 `[skip]` 并以 0 退出。

★ **校验的用例钉在测试自己造的一张合成地图 / 合成战役上**，
不钉 `data/maps/dongzheng` 或 `data/campaigns/demo`：样例数据是**别人也在改**的东西。

## 界面主题

浅色（白）+ 极简的一整套（页面底 / 卡片面 / 输入面三层灰 + 一条冷色强调色），按钮是**圆角**的。
与另两个编辑器共用同一套做法（各自留一份 `app.py` 里的 `UI` / `RButton` / `_apply_theme`）：

* **下拉框选中后不能变白**：clam 主题在 `readonly` 状态下会把下拉框的底落回浅灰
  （实测 `dcdad5`），光 `style.configure` 压不住 —— 必须 `style.map` 把 `readonly` /
  `active` / `disabled` 这几个状态一起按下去。
* **改一个数值不再闪白**：整块重建控件（`refresh_all`）时用 `LockWindowUpdate` 把绘制
  锁住、建完再一次性解开（`_NoRepaint`）。⚠️ **别改成 `WM_SETREDRAW`** —— 那会把窗口的
  激活状态一起搞乱（实测：跑完一个用例之后，下一个新建的窗口拿不到键盘焦点）。

## 已知取舍

1. **不做撤销 / 重做**（另两个编辑器也没有；数据都在 JSON 里，改坏了「重新载入」）；
2. **不做剧本预览**（要预览就进游戏跑一关）；
3. 摆放**不做自动避让**（允许压在中心格上，导出会拦）；
4. **不做「每方一份目标」**（可玩阵营必须同方）；
5. **不做「一批刷 N 个兵」的批量摆放** —— 附属单位本来就按规格随机生成。

## 什么时候该回头改

* 逻辑层加了新的失败条件种类 → `FAIL_ZONE_LOST` 那张表加一项，界面下拉与校验各加一条；
* 运行时的「自动生成 3 位将领」改了（`world.create_generals()` 里那个 `for i in 3`）→
  `model.GENERAL_SLOTS`、README 里「摆了将领就整个接管」那段一起改；
* `escort_count` / `escort_types` 的语义改了 → 逻辑层 `level.gd` / `world.fill_general_retinue`
  与本文件的校验三处一起改；
* 红点的时间 / 将领数不再是 `y=ax+b` → `logic/expr.gd` 与 `model.expr_coefficients` 一起改；
* `map_editor` 的 `--map` 参数改名 → 改 `app.EditorApp.open_map_editor()` 里那一行。
