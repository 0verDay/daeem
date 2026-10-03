# DAEEM 战役编辑器（`tools/campaign_editor`）

Python + tkinter，**零第三方依赖**，一个目录装完，双击 `campaign_editor.bat` 就能进。

它管的是**战役与关卡**：谁参展、谁可玩、谁挂什么 AI、往哪打、开局摆放、目标与失败条件。
数据落在 `daeem/data/campaigns/<id>/`：

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

在 `dev_gd_a` 目录下也能用模块形式跑：

```
python -m tools.campaign_editor --selftest
```

参数：

| 参数 | 作用 |
|---|---|
| `--project` | Godot 工程目录（默认 `dev_gd_a/daeem`，与另两个编辑器同一个默认值） |
| `--new ID` | 在 `data/campaigns/ID/` 下建一个战役（顺手建第一关：**一关都没有的战役读不出来**） |
| `--name` / `--map` | 配合 `--new`：战役显示名 / 第一关用哪张地图 |
| `--selftest` | 不开窗口跑自检（列地图 / 列战役 / 跑校验 / 在临时目录里做一次往返） |
| `--list` | 列出所有战役目录后退出 |

双击 `campaign_editor.bat` 一样（拖一个**战役目录**到它上面 = 直接开那一个）。

## 六个工具的分工（这是最重要的一段）

| 谁 | 管什么 | 数据在哪 |
|---|---|---|
| `tools/map_editor` | 地形 / 区划 / 中心 / 地图自带的大本营 | `data/maps/<id>/map.json` |
| `tools/unit_editor` | 兵种 / 将领 / 建筑 / 科技数值 | `data/config.json` |
| **`tools/campaign_editor`**（本工具） | **战役与关卡 —— 含开局部队（将领 + 附属兵）的摆放** | `data/campaigns/<id>/` |

本工具**只引用地图、只读配置**：地形 / 区划 / 中心是**从地图读出来画成背景**的，
要改它们请点界面上的「打开地图编辑器」（它会给 `map_editor` 传 `--map <当前关的地图 id>`）。
这条分工**写在界面上**（摆放页画布上方那行黄字），不只是写在这里。

> ⚠️ **地图预置单位（`map.json` 的 `units[]`）已经废弃**：运行时不再读它，地图编辑器
> 导出时也会把它丢掉。敌人开局站在那里，只能靠**关卡的摆放**（见下）。
>
> ⚠️ **`config.json` 的 `unit.general.escort` 也已经删掉**：开局带几个兵**不再有全局缺省**，
> 完全由本工具的摆放页决定。unit_editor 里那三个将领仍然能编类型与数值，但**没有**「附带几个兵」这一项。

## ★★ 所见即所得：开局部队就是你摆出来的那些

**摆放页画布上有什么，进游戏就有什么**（这是本工具现在最硬的一条约定）。
画笔有四档，开局部队靠前两档摆出来：

| 画笔 | 摆出来的是 | 注意 |
|---|---|---|
| **将领** | `kind: "general"` + `将领序号`（自动取「已有最大序号 + 1」） | 序号决定用哪一套将领数值（1 长枪兵 / 2 长弓兵 / 3 骑手） |
| **附属兵** | 普通兵种 + **`escort_of`（属于第几位将领）** | 下拉里只有**这一方已经摆好的**将领 —— 先把将领摆下来 |
| 单位 | 普通摆放单位（**不是**附属兵） | 例如守渡口的驻军：配 `zone` + 将领性 AI |
| 建筑 | 开局就立着的建筑 | |

* 画布上**附属兵**画成绿色虚线连到它的将领，方块右上角带一个「属」字 —— 一眼看出哪个兵跟着谁。
* 导出时**将领自动排在它自己的兵前面**（`world.units` 的前几个必须是将领，这是运行时的硬约定），
  所以你「先摆兵、后补将领」也没关系。
* ★★ **某一方只要摆了附属兵，运行时就整个接管这一方**：连那 3 位将领也得你自己摆。
  一个都没摆的一方 → 运行时照旧自动生成 3 位将领（**但不带任何兵**）。
* ★ **AI 那一方也照此办理**：谁摆了就给谁，不再有「只给本机操作那一方」的区别。
* 想看一局到底有多少单位，用命令行自检最省事：

```
python dev_gd_a/tools/campaign_editor --selftest
```

它会逐方打出 `开局部队：摆了 3 位将领 + 15 个附属兵 —— 运行时整个接管这一方（不再自动生成将领）`。

> 历史（为什么会有这一节）：开局附属兵以前由 `config.json` 的一个全局数决定，
> 画布上**看不到**，于是「编辑器里只摆 3 个、进游戏却有 20 多个」。现在那条路已经拆掉。

## 五个页签

### ① 战役

战役名 / 简介 / 默认模式（`solo` / `coop`）/**关卡顺序**。

* 左边的列表就是关卡顺序；`▲ 上移` / `▼ 下移` 改顺序，`＋ 新建关卡` / `－ 删除关卡` 增删。
* 顺序写进 `campaign.json` 的 `levels[]` —— **文件名的字典序只是没写顺序时的兜底**。
* 删除关卡只从 `levels[]` 里移除，**不删文件**（编辑器不替人删文件：删错了没法撤销）。
* 右栏是 `factions[]`（`id` / 名字 / 颜色 / **可玩**）。`playable: true` = 玩家能选谁。

### ② 关卡

当前关的名字 / 模式 / 地图 / **目标** / **额外失败条件**。

* 地图下拉扫 `data/maps/`（`hidden` 与 `placeholder` 的图**照样列出来**，只是标一句
  「仅战役」/「占位」——`hidden` 只是不进自由对战的地图选择条）。
* 模式一改，玩家席位数跟着变（合作 = 2 个席位，单人 = 1 个）。
* **目标**：第一版只有一种 —— 「守住某个区划 N 秒」。区划从当前地图里读。
* **额外失败条件**：第一批只有「指定区划失守」（`zone_lost`）；
  「大本营被拆」那条是**常开的**，不写在这里。

### ③ 阵营与 AI

上栏是**玩家席位**（1 或 2 个：阵营 + 大本营），下栏是**每一方一行**：

| 字段 | 说明 |
|---|---|
| AI 类型 | 无（`none`）/ 阵营性（`faction`）/ 将领性（`general`） |
| 大本营 | 关卡点位；留空 = 用地图的 `faction_bases` |
| 资源倍率 | `resource_mult`：只乘**收入**（难度旋钮：2.0 = 两倍产出） |
| 开局粮食 / 黄金 | 这一方资源池的初值 |
| 进攻目标 | 最近敌方区划（缺省）/ 指定区划 / 指定格 / 指定建筑 / 某方的家 |
| 高级 AI 参数 | 折叠区；**留空 = 继承 `config.json`**，旁边显示推荐值 |

★ **开局部队不在这一页摆**（也没有「这一方带几个兵」这种全局数字了）——
   它在 **④ 摆放页**里一个兵一个兵摆出来，见上一节与 ④。

★ **给「可玩」阵营配 AI 是允许的**（界面上有灰字说明）：运行时按选中的席位摘掉 ——
本局谁在被玩，谁就不动。所以校验**不拦**它。

★ 「进攻目标」在 ③（下拉）与 ④（点画布）**两处都能改，底层是同一个字段**
（`LevelModel.factions[i].attack_target`），两边都走 `set_attack_target()`，
改完统一重建界面 —— 这是最容易写成不一致的地方，`test_app.py` 专门钉了它。

### ④ 摆放

画布：**左键**放东西 / 选中，**右键**删，**滚轮**以光标为锚点缩放，
**中键拖动**或**空格 + 左键拖动**平移视野，
**`Esc`** 退出「设进攻目标」模式，底部状态栏显示「格坐标 / 地形 / 区划 / 上面有什么」。

* ★ **平移有两种按法**：**中键拖动**，或**按住空格 + 左键拖动**（笔记本 / 触控板没有中键时用这条）。
  按住空格期间左键**不再放东西、也不改选中**，鼠标指针变成十字箭头（`fleur`）——
  一眼看出「现在是拖画面，不是摆东西」。松开空格立刻回到「放东西 / 选中」。
* ★ 左键是「**按下**起来、**松开**才落地」的：按下与松开之间挪了 3 像素以上就当成**拖动**，
  这一次不算「点」（`DRAG_TOLERANCE`，与 `map_editor` 同一个值）—— 手抖不会顺手多摆一个兵。
* ★ **空格要画布拿着键盘焦点才收得到**：tk 的按钮点过之后会拿住焦点（`takefocus=0` 只管 Tab 遍历），
  而空格在 tk 里是「激活焦点控件」—— 那样「按住空格拖画面」会变成「反复点最后按过的那颗按钮」。
  所以本工具的按钮点完都把焦点交还画布（`_focus_canvas()`），摆/删/选之后也补一次
  （那几步会整块重建画布，新画布默认没有焦点）。
* ⚠️ 拖动期间 **tk 不保证发 `<B1-Motion>`**（实测带 B1 位的 `<Motion>` 走的是 `<Motion>` 那条绑定），
  所以拖动在 `on_motion` 里按 `state` 的 B1 位**也**分派一遍，不是只靠 `<B1-Motion>`。

* 画笔：**单位 / 附属兵 / 将领 / 建筑** + 兵种（从 `config.json` 读）+ 归属阵营；
  选「附属兵」时多一行「**属于将领**」（只列这一方已摆好的将领）。
* 选中已有的东西 → 右栏改它的全部字段（归属 / 兵种 / **属于将领** / 将领序号 /
  `zone` / `hold` / AI / 名字）。
* **附属部队**：`start_units[].escort_of` 记「属于第几位将领」（1 起，指将领的 `将领序号`）。
  进游戏时运行时会把它落成 `unit.leader_id` ⇒ 它在游戏里**真的是那位将领的部队**
  （点一个兵选中整队、将领濒死时它去集结、将领死了它算「部队没了」）。
* ★ **大本营不算「已有」**：它在阵营页里改，**不允许**在摆放页删 ——
  免得出现「没有大本营」的关卡（那是校验第 4 条要拦的）。
* 画布画**关卡层**：摆放 + 大本营 + 目标区划高亮 + 各方进攻目标的箭头
  + **附属兵到将领的虚线**。地图自带的预置建筑不在画布里（改它去 map_editor）。
* 摆放**不做自动避让**：允许你把东西压在区划中心格上，但**导出会拦**（校验第 5 条）。

### ⑤ 校验与导出

跑那 16 条硬拦截 + 4 条警告，逐条显示「通过 / 警告 / 拦截」。
**有拦截项时禁止写文件**（这是硬要求，不是提示）。写完显示写了哪些文件。
本页还有「一键打开地图编辑器」（当前关的地图）。

## 校验清单（`model.validate_campaign`）

`code` 与 `logic/level.gd` 的 `_ck_*` **逐字一致** —— 编辑器、测试、运行时三边靠它对暗号。

**拦截（`block`，不许导出）**

| code | 判据 |
|---|---|
| `map_missing_field` | 关卡没写 `map` |
| `map_not_found` | `map` 在 `data/maps/` 里不存在 |
| `players_empty` | 一个玩家席位都没有 |
| `players_count_solo` / `players_count_coop` | 单人 ≠ 1 个席位 / 合作 ≠ 2 个席位 |
| `player_no_faction` | 有席位没写 faction |
| `players_same_faction` | 两个席位同一阵营 |
| `faction_no_base` | 关卡点名的阵营没有大本营（关卡没给、地图也没给） |
| `point_on_zone_center` | 大本营 / 摆放压在某区划的中心格上 |
| `point_on_mountain` | 大本营 / 摆放落在山地（不可通行） |
| `point_outside` | 在地图外 |
| `playable_not_same_side` | 有 ≥2 个可玩阵营但它们不互为同方 |
| `objective_unowned` | 目标区划开局归属为空 |
| `objective_not_players` | 目标区划开局归属方与玩家席位不同方 |
| `objective_empty` / `objective_too_many` / `objective_kind` / `objective_no_zone` / `objective_zone_missing` / `objective_hold_sec` | 目标必须恰好 1 项、`hold_zone`、区划存在、`hold_sec > 0` |
| `attack_target_zone` / `attack_target_outside` / `attack_target_mountain` / `attack_target_kind` / `attack_target_base` / `attack_target_shape` | 进攻目标引用的区划 / 格 / 建筑必须存在且可通行，`kind` 必须是四种之一 |
| `fail_kind` / `fail_no_zone` / `fail_zone_missing` / `fail_zone_is_objective` | 失败条件只支持 `zone_lost`；区划存在且不是目标区划 |
| **`fail_zone_unowned`** | ★ 失败条件的区划**开局无主**（第一帧就判负） |
| **`fail_zone_not_players`** | ★ 失败条件的区划开局归**非玩家同方**（同上） |
| `unit_general_no_zone` | 摆放里 `ai: "general"` 的项没有 `zone`（它会在原地发呆） |
| `unit_no_faction` | 摆放单位没写 `faction` |
| `faction_unknown` | 摆放里引用了「地图 `factions` ∪ 关卡 `factions` ∪ 玩家席位」之外的阵营 |
| **`escort_no_general`** | ★ 附属兵写了 `escort_of: N`，但这一方**没有**「将领序号 = N」的将领 —— 它进游戏没有队长 |
| **`escort_is_general`** | ★ 一个**将领**自己写了 `escort_of`（将领不能当别人的附属兵） |
| **`general_index_dup`** | ★ 同一方有两位将领写着**同一个** `将领序号` —— 附属兵该跟谁就不确定了 |

★ 为什么 `fail_zone_unowned` / `fail_zone_not_players` 也要拦：
`zone_lost` 的判据是「这一区**不再**归玩家同方 ⇒ 立刻判负」。
如果它**开局就不归玩家同方**，那个条件**第一帧就成立、第一帧就判负** ——
整关一进去就输（逻辑层实测到 `reason = zone_lost:6`、`held = 0.1`）。
它们与 `objective_unowned` / `objective_not_players` 是**同一个坑的两面**。

**警告（`warn`，不挡导出）**

| code | 判据 |
|---|---|
| `no_attack_target` | 有挂 `ai == "faction"` 的阵营，但一个都没写 `attack_target` |
| `attack_target_own_land` | 某 AI 阵营的 `attack_target`（zone 型）指向自己占的区划 |
| `ally_unknown` | `allies` 里出现未定义的阵营 id |
| `overload_hint` | 某一方 `attack_repeat_sec <= 3` **且** `resource_mult >= 2.0`（「可能压不住」） |
| **`escort_faction_no_general`** | ★ 某一方摆了附属兵却**一个将领都没摆**（运行时整个接管这一方 ⇒ 这些兵群龙无首） |

`overload_hint` 来自 `dev_plan_7` 9.1 风险 4：出兵间隔很小 + 资源倍率很高 = 一波接一波。
**是警告不是拦截** —— 那是设计者的自由，编辑器只把已知的坑指出来。

## 数据契约（改任何一处都要同步改逻辑层）

* **LF 行尾、无 BOM**：写文件时 `encoding="utf-8"` + `newline="\n"`；读的时候宽容 `utf-8-sig`
  （Windows 记事本写出来的 UTF-8 常带 BOM，而 `json.loads` 见到 BOM 直接报错）。
* **省略等于默认值的字段**：`resource_mult == 1.0` / `start_food == 0` / `base` 没写 /
  `attack_target` 没写 / `start_units[].escort_of == -1` / `faction_ai` / `general_ai`
  为 `None` 时**都不写**。
* ★★ 但 `start_units[]` 里**源文件写过**的键要原样写回去（`general_index` / `ai` / `zone`）：
  `{"general_index": 1}` 与「没写」在别人眼里是两件事。每个单位自己记一份 `declared`
  键表（照关卡顶层 `_declared` 那一套）；`hold` 例外 —— `false` 与「没写」在运行时完全同义。
* `players[].base` **没写就不写这个键** —— 与 `{"base": [-1,-1]}` 是两件事。
* `zones[].owner == ""` 是「**显式清空**这一区的开局归属」，与「没提这一区」是两件事。
* 关卡 `factions[]` 里写了的那一方**一律写出来**（它表达「关卡点名了这一方」），
  但那一行里的默认字段照样省掉。
* 关卡 JSON 里**本编辑器不认识**的字段（含 `_comment`）原样带回去 ——
  导入 → 导出不许掉字段。
* **`model.py` 与 `levelfile.py` 不许 `import tkinter`**（数据层的测试不开窗；
  校验逻辑只有一份，界面只是它的一个消费者）。
* **往返比较按「语义」而不是「字节」**（`levelfile.canonical_payload`）：数字统一成 float、
  无意义的数组排序（`zones` / `factions` / `start_units` / `start_buildings` / …）、
  **字典的键顺序抹平**。最后一条是实测踩到才加的：`escort_of` 是导出时最后追加的键，
  与作者手写的键序不同，按位置比会报成「往返不一致」这种假红。
* **`escort_of` 指的是「将领序号」（`general_index`），不是「列表里第几个」**：
  运行时要靠它找队长，编辑器画连线 / 校验 / 导出的将领优先排序三处都走同一个判据
  （`model.general_with_index()`）。改这里就三处一起改。

## 测试

```
python dev_gd_a/tools/campaign_editor/test_model.py   # 不开窗（数据层）
python dev_gd_a/tools/campaign_editor/test_app.py     # 开窗（界面），跑完自动 withdraw()
```

两份都靠**退出码**表达成败（0 = 全绿），并打印 `[CASE] ... passed N / failed M`。
两份都不需要 pytest。

* `test_model.py` 覆盖：往返（逐字段一致 / LF / 无 BOM / 不多写默认值 / **键序不影响比对**）、覆盖规则、
  **那 18 条校验每条各一个坏样例**（含 `playable_not_same_side`、`objective_unowned`、
  `fail_zone_unowned`、`overload_hint` 这些），AI 指派三种取值、四种 `attack_target` 的往返、
  **附属部队：`escort_of` 的读写 / `escorts_of()` 数数 / 四条新校验（没队长、将领当兵、序号重复、
  整方接管警告）/ 导出把将领排在兵前面**、
  目标与失败条件的强制、坏输入（坏 JSON / 文件不存在 / 目录被删 → `ModelError`）、
  新增 / 删除 / 排序关卡，以及一条兜底断言：
  **整场测试结束后真 `data/campaigns/**`、`data/maps/**`、`data/config.json` 逐字节未改**
  （测试只动 `.tmp_campaign_editor_test/` 里的副本）。
  ⚠️ 那条兜底断言会在**别人同时改 `data/`**（例如地图编辑器正在改 `frontier/map.json`）时变红 ——
  它是这么设计的（用来抓「测试顺手写了真文件」），并发编辑时重跑一次即可。
* `test_app.py` 覆盖：页签切换、画布放置 / 删除 / 缩放、`Esc` 退出目标模式、
  **★ 空格 + 左键拖动平移（含「带 B1 位的 `<Motion>` 也能拖」「拖过画面不算点击」
  「空格 + 左键轻点既不放东西也不移视野」「没按空格时单击照旧放东西」
  「输入框里按空格不被画布抢走」「换页签丢掉平移状态」，并断言 `<KeyPress-space>` /
  `<ButtonRelease-1>` **真的绑在画布上** —— 只有回调存在不算接上）**、
  ③ 与 ④ 改同一个字段的一致性、**④ 的附属部队（摆将领 → 摆附属兵 → 指定归属 →
  删掉将领后被校验拦住）**、
  导出拦截对话框、一键跳转（**假 subprocess**，不真起地图编辑器）、
  侧边栏「装得下就不许滚」。
  起不了 Tk 的机器上会打印 `[skip]` 并以 0 退出（与另两个编辑器同一套做法）。

★ **校验的用例钉在测试自己造的一张合成地图上**（`synthetic_map()`），
不钉 `data/maps/dongzheng`：样例数据是**别人也在改**的东西，把用例钉在上面会出现
「样例数据搬家 → 校验器的测试红」这种指不到原因的失败（真踩过）。

## 已知的取舍（`dev_plan_7` 6.6）

1. **不做撤销 / 重做**（另两个编辑器也没有；数据都在 JSON 里，改坏了「重新载入」）；
2. **不做剧本预览**（不能「按一下播放看 AI 会不会打过来」）—— 预览要进游戏跑一关；
3. 摆放**不做自动避让**（允许压在中心格上，导出会拦）；
4. **不做「每方一份目标」**（可玩阵营必须同方）；
5. ❓ **不做「这一关大概多久成形 / 每波几个兵」的估算提示** —— 用户明确不要
   （所以 `model.py` 里没有 `estimate()`）；
6. **不做「一批刷 N 个兵」的批量摆放**（附属兵一个兵一个坐标地摆）——
   真要做请加在摆放页（例如刷完一个继续刷下一个），别绕开 `escort_of`。

## 什么时候该回头改

* 逻辑层加了新的失败条件种类（单位全灭 / 关键建筑被拆 / 限时 / 累计阵亡）→
  `FAIL_ZONE_LOST` 那张表加一项，界面下拉与校验各加一条；
* 运行时开始支持「每方一份目标」→ `objectives[]` 加 `for: faction`，校验第 7/8 条跟着改；
* 运行时的「自动生成 3 位将领」改了（`world.create_generals()` 里那个 `for i in 3`）→
  `model.GENERAL_SLOTS`、README 里「某一方摆了附属部队就整个接管」那段一起改；
* `escort_of` 的语义改成「按摆放顺序」而不是「按 `general_index`」→
  `general_with_index()` / `ordered_start_units()` / 校验三处一起改（现在都钉在 `general_index` 上）；
* `map_editor` 的 `--map` 参数改名 → 改 `app.EditorApp.open_map_editor()` 里那一行。
