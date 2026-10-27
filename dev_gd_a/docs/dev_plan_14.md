# dev_plan_14 —— 主菜单 / 战役 / 合作 菜单 UI 大改

> 状态：**待确认（2026-10-27）**。本文件只写计划，不改代码。
> 参考图：`art_draft/main_menu/*.png`（纯黑白线稿，只用来确定排布关系，尺寸可调）。
> 工程：`dev_gd_a/daeem/`（Godot 4.7 mono，1920×1080 设计分辨率，`stretch/aspect=expand`）。
> 约束：不改 `README.md`；不引入新的图片依赖；所有面板继续用代码搭 Control 树。

---

## 0. 已确认的决策（来自本轮提问）

| 项 | 决策 |
|---|---|
| 视觉风格 | **沿用现有暗金风格**：深色面板 + 1px 暗金描边 + 暖白字；线稿只参考排布，不做白底黑块。 |
| 设置入口 | **只保留右上角退出 X**；主菜单的「选项/全屏/退出」面板移除。Ctrl+Q 仍保留全屏切换。 |
| 战役章节 | I / II / III **只做选中反馈，不切地图、不换内容**；本轮战役地图固定显示 `c1` 的唯一真实关 `demo/mt`（main_test）。 |
| 占位关卡详情 | 代码里保留兜底：真遇到没有真实关卡的数据时，照常打开详情并显示禁用的「暂不可用」按钮；本轮唯一旗帜指向真实关，所以界面上不可达。 |
| 战役过渡取消 | **进入战役过渡后不可取消**：Esc / 安卓返回不生效，不提供返回按钮。 |
| 合作准备返回 | **回到来源页**：AI 路线回「合作」过渡页；真人房间路线回「房间」页。 |
| 合作 AI 难度 | 固定 `normal`；准备页本轮不加难度选择器。 |
| 合作准备边距 | 面板贴屏幕四边，不留 24px 外边距（与参考图一致）。 |
| 左移侧栏 | **所有被左移成侧栏的面板整体不可交互**：加一层灰色遮罩，遮罩 `mouse_filter=STOP`，X、战役/合作/演义、旗帜等全部点不到。 |

### 本轮不做

- 「演义」「自定义」「备战」的实际逻辑（可以点击，但不跳转；保留按下反馈）。
- 章节切换逻辑（I/II/III 只高亮选中，战役地图固定显示 c1 的唯一真实关 `demo/mt`）。
- 新中继协议、房间协议、联机规则。
- 游戏内 HUD / 3D 场景 / 结算画面。
- 主菜单的账号、设置、全屏 UI（Ctrl+Q 仍可用）。

---

## 1. 现有实现盘点

### 1.1 菜单入口

- `view/main.gd`
  - 创建 `StartScreen`（`view/start_screen.gd`），连接 `campaign_level_chosen / coop_* / quit_requested`。
  - 单人关：`_on_menu_campaign_level_chosen(campaign_id, level_id, faction)` → 载入战役/关卡 → `_show_level_transition()`（`view/level_transition.gd`）。
  - 合作：`coop_session.gd` 发出的 `host_started / guest_started / solo_started` 三个信号。
  - 返回主菜单：`return_to_menu()` → `start_screen.reset_panels()` + `open_menu()`。
- `view/start_screen.gd`
  - 入场页 + 主菜单两页；主菜单由 `menu_deck.gd`（页面栈 / 横向滑动）+ 五块面板组成：
    `main_menu_panel.gd / campaign_map_panel.gd / campaign_detail_panel.gd / coop_start_panel.gd / coop_room_panel.gd / coop_ready_panel.gd`，
    外加覆盖在准备页上的 `coop_map_picker.gd`。
  - 入场点击后有一段「徽记 / 标题 / 金线落位」动画（`_play_intro_morph()`）。
- `view/menu_deck_layout.gd`：所有面板的几何常量；`view/menu_page.gd`：面板基类（背景 / 泛光标题 / 返回 / 灰层）。
- `view/menu_banner.gd` / `menu_faction_button.gd` / `menu_map_backdrop.gd` / `menu_glow_header.gd` 等：新菜单的零件。
- `view/coop_session.gd`：合作网络会话（无绘制），房间列表、创建/加入、准备/开始、房主地图广播、AI 队友。
- `view/level_transition.gd`：全屏过渡页；左地图 / 右简报 / 底部进度条与呼吸提示；阵营已在详情页选好，本页不可取消。

### 1.2 数据

- `data/campaigns_menu.json`：菜单显示数据；当前 `c1` 只有一章 `main_test`（指向 `demo/mt`），`c2/c3` 是占位章节。
- `data/campaigns/<id>/campaign.json`：真实战役关卡；每关 JSON 的 `factions[]` 带 `id/name/color/playable`。
- `logic/campaign_menu_db.gd`：读菜单 JSON；`is_placeholder_chapter()` 判断占位。
- `logic/campaign_library.gd` / `logic/campaign.gd` / `logic/level.gd`：载入真实战役与关卡。
- `logic/level_brief.gd`：标题、简报、可玩阵营、目标文案的唯一整理处。
- `logic/coop_catalog.gd`：一个 `mode="coop"` 关卡 = 一张合作地图；合作地图目录。
- `net/lobby.gd` / `net/relay_transport.gd` / `net/room_directory.gd`：合作联机逻辑。

### 1.3 测试现状

与菜单强相关的测试：

- `tests/test_start_flow.gd`：入场、主菜单三按钮 / 底部两按钮、战役 → 详情 → 过渡 → 游戏。
- `tests/test_menu_deck.gd`：页面栈、横向位置、侧栏灰层真正挡点击、返回、动效关闭同步到位。
- `tests/test_campaign_menu.gd`：章节选中反馈、详情、占位兜底、灰层。
- `tests/test_level_transition.gd`：两面板、加载、提示、不可取消、进入信号。
- `tests/test_coop_menu.gd` / `test_coop_lobby.gd`：合作三页、AI 准备、地图选择、真实中继会话流程。
- `tests/test_settings_menu.gd`：局内设置 + 返回主菜单（主菜单不再有「选项」）。
- `tests/bench_menu_shot.gd`：当前菜单截图脚本。

> 本次是「大改」，上述测试会按新结构重写，而不是在原断言上打补丁。

---

## 2. 目标状态机

```text
INTRO（入场页，保留）
  └─ 点击任意处 ── logo/名称落位、主面板渐显 ─→ MAIN

MAIN（主菜单，右侧 640 面板）
  ├─ 战役 ─→ CAMPAIGN（右侧 1280 战役地图）
  │            └─ 点击旗帜 ─→ CAMPAIGN_DETAIL（右侧 640 详情）
  │                              └─ 点击阵营 ─→ CAMPAIGN_START（全屏过渡，不可取消）
  │                                                └─ 加载完成 + 点击 ─→ GAME
  ├─ 合作 ─→ COOP_START（右侧 1280 合作过渡）
  │            ├─ 点击虚位旗帜 ─→ COOP_READY(AI)（右侧 640 准备）
  │            └─ 点击旗帜外空白 ─→ COOP_ROOM（右侧 640 房间）
  │                                      └─ 创建/加入成功 ─→ COOP_READY(HUMAN)
  ├─ 演义 / 自定义 / 备战：按下反馈，不跳转
  └─ 右上角 X ─→ 退出确认（现有 quit_confirm）

COOP_READY（任意来源）
  └─ 点击地图缩略图 ─→ COOP_MAP（右侧 640 滑入）
        └─ 确认/返回 ─→ COOP_READY（面板从右侧滑出）

返回：
  MAIN 的 X        → 退出确认
  CAMPAIGN         → MAIN
  CAMPAIGN_DETAIL  → CAMPAIGN
  COOP_START       → MAIN
  COOP_ROOM        → COOP_START（退出房间）
  COOP_READY(AI)   → COOP_START（清掉本地 AI 房间）
  COOP_READY(HUMAN)→ COOP_ROOM（保留房间，只把准备面板滑出）
  COOP_MAP         → COOP_READY（取消选择）
  CAMPAIGN_START   → 无返回（Esc / 安卓返回被吞掉）
  GAME             → 现有「设置 → 返回主菜单」
```

---

## 3. 布局规格（1920×1080 设计空间）

### 3.1 三段面板

- 侧栏宽 `SIDE_W = 640`（1/3）；宽栏 `WIDE_W = 1280`（2/3）；高度铺满 `H = 1080`。
- 响应式：`SIDE_W = clamp(round(screen_w / 3.0), 520, 720)`，`WIDE_W = screen_w - SIDE_W`。
  - 1920 → 640 / 1280；
  - 2400 → 720 / 1680；
  - 1280 → 520 / 760。
- 所有新面板上下贴边，左右按上表；不再保留 `menu.chrome.expanded_margin = 24`。

各页的面板位置（x 单位 px，设计基准 1920）：

| 页面 | MainPanel | CampaignPanel | DetailPanel | CoopPanel | RoomPanel | ReadyPanel | MapPanel |
|---|---:|---:|---:|---:|---:|---:|---:|
| MAIN | `1280` | — | — | — | — | — | — |
| CAMPAIGN | `0` | `640` | — | — | — | — | — |
| CAMPAIGN_DETAIL | 隐藏 | `0` | `1280` | — | — | — | — |
| COOP_START | `0` | — | — | `640` | — | — | — |
| COOP_ROOM | 隐藏 | — | — | `0` | `1280` | — | — |
| COOP_READY(AI) | 隐藏 | — | — | `0` | — | `1280` | — |
| COOP_READY(ROOM) | 隐藏 | — | — | `0` | `1280`→滑出 | `1280` | — |
| COOP_MAP | 隐藏 | — | — | `0` | — | `1280` | `1280`（在 Ready 之上） |

> 表中的「隐藏」是转场完成后的状态；转场中移动中的面板保持可见。

### 3.2 主菜单面板（640×1080）

```text
┌──────────────────────────────────────────────┐ 0
│                                        [ X ] │ 24..80
│                                              │
│                 ┌──────────────┐             │ 72
│                 │              │             │
│                 │   logo 200²  │             │
│                 │              │             │
│                 └──────────────┘             │ 272
│                 ┌──────────────┐             │ 304
│                 │  DAEEM 名称  │  240×52     │
│                 └──────────────┘             │ 356
│                                              │
│        ┌────────────────────────┐            │ 440
│        │          战役          │  400×100   │
│        └────────────────────────┘            │
│        ┌────────────────────────┐            │ 600
│        │          合作          │  400×100   │
│        └────────────────────────┘            │
│        ┌────────────────────────┐            │ 760
│        │          演义          │  400×100   │
│        └────────────────────────┘            │
│                                              │
│ ┌──────────────────────┬───────────────────┐ │ 930
│ │       自定义         │       备战        │ │
│ └──────────────────────┴───────────────────┘ │ 1080
└──────────────────────────────────────────────┘
```

- 退出 X：56×56，距右/上各 24；程序化 `_draw` 两条斜线，无贴图。点击 → `quit_requested`（现有退出确认）。
- logo：200×200 方形框，内部放现有 `view/menu_emblem.gd` 的徽记（可旋转）。
- 名称：240×52 面板 + `DAEEM` 带字距字标（约 36px / tracking 8），字色沿用 `menu.menu_title_color` / `menu.menu_title_gold_color`。
- 三颗主按钮：400×100，垂直间距 60；悬停仍用 `fill_button.gd` 的「金色自下而上填满」。
- 底部条：640×150，水平两等分；中间一条 1px 金线分隔。
- 主面板整体背景：`bg_bottom` 高不透明度（≈0.94）+ 1px 金线；与现有暗金皮肤一致。

### 3.3 战役地图面板（1280×1080）

```text
┌──────────────────────────────────────────────────────────────┐
│              ▒▒▒ 半圆泛光 + 「战役」 ▒▒▒              [返回] │
│                                                              │
│      ┌────────┐                                              │
│      │ 旗帜   │                         ┌────┐               │
│      │        │                         │ I  │               │
│      │        │                         ├────┤               │
│      └────────┘                         │ II │               │
│                                          ├────┤               │
│                                          │III │               │
│                                          └────┘               │
└──────────────────────────────────────────────────────────────┘
```

- 地图底图：**已按 2026-10-27 追加修订移除**；现在战役面板是纯暗底，不再有上下暗角。
- 顶部泛光：`view/menu_glow_header.gd`，宽约 460、高约 150，锚在面板顶部中央；标题「战役」44px，水平居中，压在泛光中心。
- 返回：56×56，右上 24px；点击回 MAIN。
- 旗帜：`view/menu_banner.gd`，约 200×260 的小型按钮，放在面板中心；**本轮只放一面**，固定指向 `demo/mt`。旗帜上显示章节名 `main_test`。
- 右侧章节栏：宽 100，垂直居中；I/II/III 三颗 84×84，间隔 16；选中实心金/亮边，未选中金线透明底。
- 章节栏点击：**只切换选中高亮，不重建底图、不换旗帜、不改详情数据**；当前地图始终是 `c1 → demo/mt`。
- 占位数据兜底：`CampaignDetailPanel` 仍支持「无真实关卡」的禁用按钮；本轮唯一旗帜是真关，所以界面上不会走到。

### 3.4 战役详情面板（640×1080）

```text
┌──────────────────────────────────────────────┐
│              ▒▒▒ 半圆泛光 + 「详情」 ▒▒▒ [返回]│
│                                              │
│            ┌────────────────────┐            │ 150
│            │                    │            │
│            │   地图缩略图 400²   │            │
│            │                    │            │
│            └────────────────────┘            │ 550
│                                              │
│   ┌──────────────────────────────────────┐   │ 570
│   │  关卡名 / 关卡描述 / 简报             │   │
│   └──────────────────────────────────────┘   │ 770
│                                              │
│   ┌───────────────┐  ┌───────────────┐       │ 790
│   │  阵营一       │  │  阵营二       │       │
│   └───────────────┘  └───────────────┘       │ 890
│   ┌───────────────┐  ┌───────────────┐       │ 910
│   │  （第三）     │  │  （第四）     │       │ 1010
│   └───────────────┘  └───────────────┘       │
└──────────────────────────────────────────────┘
```

- 地图缩略图：400×400，复用 `view/map_thumb.gd`；本轮取 `demo/mt` 的地图 `main_test`；无真实地图时画占位地图（兜底）。
- 描述块：560×200，标题 + `RichTextLabel` 自动换行；内容优先章节 `description`，其次 `LevelBrief.briefing_text(level)`，占位则写「该关卡尚未开放」。
- 阵营按钮：动态生成；本轮 `demo/mt` 有蓝方 / 红方两个可玩阵营，两列 270×100。每颗显示「阵营名 + 目标」+ 左侧阵营色竖条。
  - 1 个：560×100 通栏；
  - 2 个：两列 270×100；
  - 3–4 个：2×2；
  - >4 个：两列 + `ScrollContainer`（当前数据最多 2 个，先按 4 个封顶，超出滚动）。
- 占位关卡：一个 560×100 的禁用按钮「暂不可用」，无阵营数据。
- 点击阵营：发 `faction_chosen(campaign_id, level_id, faction_id)`，进入战役过渡。

### 3.5 战役过渡（全屏覆盖，不是横向 deck 的一页）

```text
┌──────────────────────────────────────────────────────────────┐
│ ┌────────────────────────┐  ┌────────────────────────────┐   │ 40
│ │                        │  │ 东征·第一章 · 单人 · 蓝方   │   │
│ │     地图缩略图 900²    │  │ 关卡名                    │   │
│ │                        │  │ 简报正文                  │   │
│ │                        │  │                            │   │
│ └────────────────────────┘  └────────────────────────────┘   │ 920
│                                                              │
│ ┌──────────────────────────────────────────────────────────┐ │ 960
│ │               加载进度条 / 点击进入游戏                  │ │
│ └──────────────────────────────────────────────────────────┘ │ 1040
└──────────────────────────────────────────────────────────────┘
```

- 边距 40，左右面板各约 900×880，间距 40；底部条 1840×80。
- 左侧 `MapPreview`（保留现有 `view/map_preview.gd` 的目标/区划/大本营显示）。
- 右侧：小字「战役名 · 单人/合作 · 出战阵营」、关卡名、1px 金线、简报。
- 底部：真实 `ResourceLoader.load_threaded_request` 进度；加载完成后进度条下滑出画，提示文字「————点击进入游戏————」淡入并呼吸。
- 无阵营面板、无返回按钮；Esc / 安卓返回被吞掉。
- 进入时由 `main.gd` 统一黑屏转场（现有 `_fade_to_black/_fade_from_black`）。

### 3.6 合作过渡面板（1280×1080）

```text
┌──────────────────────────────────────────────────────────────┐
│              ▒▒▒ 半圆泛光 + 「合作」 ▒▒▒              [返回] │
│                                                              │
│          ┌────────────┐        ┌────────────┐               │
│          │            │        │            │               │
│          │  玩家旗帜  │        │ 虚位以待   │               │
│          │            │        │   +        │               │
│          └────────────┘        └────────────┘               │
│                                                              │
│          点击空白区域进入房间列表                             │
└──────────────────────────────────────────────────────────────┘
```

- 两面旗帜各约 340×560，水平居中留 220 间距；左侧玩家旗（金/暖白），右侧虚位旗（虚线边、低透明度、中央 `+` 或「虚位以待」）。
- 点右侧虚位旗 → `coop_session.enter_ai_mode()` → `COOP_READY`，`mode=ai`，难度 `normal`。
- 点两面旗帜之外的任意区域 → `COOP_ROOM`。
- 返回 → MAIN。
- 底部可加一行淡色提示（可选，不抢视觉）。

### 3.7 合作房间面板（640×1080）

```text
┌──────────────────────────────────────────────┐
│              ▒▒▒ 半圆泛光 + 「房间」 ▒▒▒ [返回]│
│  ┌────────────────────────────────────────┐  │ 150
│  │ 房间列表   [刷新]                      │  │
│  │ ┌────────────────────────────────────┐ │  │
│  │ │ 123456  等待中                     │ │  │
│  │ │ 654321  已满                       │ │  │
│  │ └────────────────────────────────────┘ │  │
│  └────────────────────────────────────────┘  │ 590
│  ┌────────────────────────────────────────┐  │ 610
│  │ 房间码  [ 1 2 3 4 5 6 ]               │  │
│  │ ┌────┬────┬────┐                       │  │
│  │ │ 1  │ 2  │ 3  │                       │  │
│  │ ├────┼────┼────┤                       │  │
│  │ │ 4  │ 5  │ 6  │                       │  │
│  │ ├────┼────┼────┤                       │  │
│  │ │ 7  │ 8  │ 9  │                       │  │
│  │ ├────┼────┼────┤                       │  │
│  │ │ 0  │ 清空│ 加入/创建                │  │
│  │ └────┴────┴────┘                       │  │
│  └────────────────────────────────────────┘  │ 1030
└──────────────────────────────────────────────┘
```

- 房间列表：复用现有 `ElasticScrollList` / `RoomDirectory`，行显示 `房间码 + 状态`；只允许点「等待中」的行，点了填入房间码。
- 输入块：6 位数字显示 + 3 列数字键盘 + 动作按钮（房间不存在 → 「创建房间」；存在且可加入 → 「加入房间」；已满/游戏中 → 禁用）。
- 创建/加入成功（收到 `room_state`）→ `COOP_READY(HUMAN)`；状态行显示连接/错误信息。
- 返回 → 退出房间 → `COOP_START`。
- 不显示中继地址输入（沿用 `net.relay_url`）。

### 3.8 合作准备面板（640×1080）

```text
┌──────────────────────────────────────────────┐
│              ▒▒▒ 半圆泛光 + 「详情」 ▒▒▒ [返回]│
│            ┌────────────────────┐            │ 150
│            │  地图缩略图 400²   │ ← 点击换图  │
│            └────────────────────┘            │ 550
│   ┌──────────────────────────────────────┐   │ 570
│   │  地图名 / 地图描述                    │   │ 770
│   └──────────────────────────────────────┘   │
│        房间码 123456 · 等待队友/已准备        │ 795
│   ┌──────────────────────────────────────┐   │ 820
│   │        准备 / 开始 / 等待队友         │   │ 908
│   └──────────────────────────────────────┘   │
└──────────────────────────────────────────────┘
```

- 地图缩略图：400×400，复用 `map_thumb.gd`；左上角房主可点，覆盖「点击更换地图」提示；客机只读并显示「由房主选择地图」。
- 地图选择：点击缩略图，`view/coop_map_picker.gd` 作为**右侧 640×1080 面板从右滑入**，压在准备面板之上；准备面板保持原位。面板内是「选择地图」标题 + 地图卡片网格（3 列，176×200，纵向滚动）+ 确认/取消；只对房主/AI 开放。确认后 `coop_session.select_map(entry)`，地图面板滑出；取消直接滑出，不改当前地图。
- 地图描述：地图名 + `CoopCatalog.entries[].desc`。
- 状态行：房间码 + `等待队友加入 / 等待队友准备 / 已准备 / 本地 AI 队友`（本轮确认允许加这一行小字）。
- 底部动作：
  - AI：`开始`（启用）。
  - 房主：无队友 → `等待队友加入`（禁用）；有队友未准备 → `等待队友准备`；已准备 → `开始`。
  - 客机：`准备` / `取消准备`。
- 返回：
  - AI → `COOP_START`（清掉本地 AI 会话）。
  - 真人 → `COOP_ROOM`（保留房间，准备面板滑出、房间面板滑回）。
- `不需要再让 UI 面板和屏幕边界有一定距离`：本面板从 y=0 到 1080 贴边，内部才留 40px 内容边距。

---

## 4. 新导航层（MenuDeck）

### 4.1 职责

`view/menu_deck.gd`：

- 只做「页面栈 + 横向滑动 + 面板显隐 + 输入闸」，不认识战役/联机规则。
- 拥有并布局：`MainMenuPanel`、`CampaignMapPanel`、`CampaignDetailPanel`、`CoopStartPanel`、`CoopRoomPanel`、`CoopReadyPanel`。
- 对外方法：
  - `goto_main()`、`goto_campaign()`、`goto_campaign_detail(chapter)`；
  - `goto_coop_start()`、`goto_coop_room()`、`goto_coop_ready(source)`；
  - `back()`、`reset_to_main(instant)`、`current_page()`、`is_busy()`、`open_map_picker()`、`close_map_picker()`。
- 对外访问器（测试用）：`main_panel()`、`campaign_panel()`、`campaign_detail_panel()`、`coop_start_panel()`、`coop_room_panel()`、`coop_ready_panel()`、`map_picker()`。

### 4.2 转场表

| 动作 | 移动的面板 | 说明 |
|---|---|---|
| MAIN → CAMPAIGN | Main `1280→0`；Campaign `1920→640`（从右滑入） | 主菜单贴左，战役面板占右 2/3 |
| CAMPAIGN → MAIN | 反向 | Campaign 滑出右，Main 回右 |
| CAMPAIGN → DETAIL | Campaign `640→0`；Detail `1920→1280` | Campaign 左移，Detail 从右滑入 |
| DETAIL → CAMPAIGN | 反向 | Detail 滑出右，Campaign 回 `640` |
| MAIN → COOP_START | Main `1280→0`；Coop `1920→640` | 与战役同构 |
| COOP_START → MAIN | 反向 | |
| COOP_START → COOP_ROOM | Coop `640→0`；Room `1920→1280` | |
| COOP_ROOM → COOP_START | 反向 | 同时退出房间 |
| COOP_START → COOP_READY | Coop `640→0`；Ready `1920→1280` | |
| COOP_ROOM → COOP_READY | Room `1280→1920`（滑出右）；Ready `1920→1280`（滑入右） | Ready 延迟约 0.06s 起跑，避免同一位置完全重叠 |
| COOP_READY → COOP_ROOM | 反向 | 保留房间 |
| COOP_READY → COOP_START | Ready 滑出右；Coop `0→640`；Main 保持 `0`（仍在灰层） | AI 路线，清本地会话 |
| COOP_READY → COOP_MAP | MapPicker `1920→1280`（从右滑入，压在 Ready 之上） | Ready 不动；只对房主/AI |
| COOP_MAP → COOP_READY | MapPicker `1280→1920`（滑出右） | 取消/确认都滑出；确认先应用地图 |
- 动效时长默认 0.42s（`menu.deck.transition_sec`），`TRANS_CUBIC` / `EASE_IN_OUT`；进入面板同时 0.28s 淡入。
- `ThemeRes.animations_enabled() == false` 或时长 ≤ 0 → 直接到终态。
- 转场期间铺一层全屏透明 `TransitionShield`（`mouse_filter = STOP`），挡住所有点击；转场完成再撤。
- 窗口尺寸变化：非转场时立即重排；转场中只更新数据，结束后落到新位置。

### 4.3 返回 / Esc / 安卓返回

- `start_screen.handle_back() -> bool`：
  - 地图选择面板打开 → 关闭面板，返回 true；
  - `menu_deck.current_page() != MAIN` → `menu_deck.back()`，返回 true；
  - MAIN → 返回 false（由 main 弹退出确认）。
- `start_screen._unhandled_input` 处理 Esc：调用 `handle_back()`；若 false，交给 main 的退出确认。
- `main._on_android_back()`：游戏内逻辑不变；菜单内先问 `start_screen.handle_back()`；`CAMPAIGN_START` 打开时直接吞掉（不可取消）。
- `CAMPAIGN_START` 的 `_unhandled_input` 消费 Esc，不发 `cancelled`。

### 4.4 侧栏灰层（左移面板不可交互）

- 每个可能被左移的面板（Main / Campaign / Coop）内部都加一层 `SidebarDim`：
  - `ColorRect` 铺满面板；
  - 颜色：暗灰半透明 `Color(0.10, 0.10, 0.11, 0.66)`，压在面板所有内容之上；
  - 灰层不仅 `z_index` 高，还要 `move_to_front()`：GUI 命中测试按子节点顺序，
    子树内容是在基类灰层之后才加进来的，只调 z 仍会点到后面的按钮。
  - `mouse_filter = STOP`，挡住该面板内所有点击/hover；
  - 默认隐藏。
- 面板处于「侧栏位」（`x == 0` 且不是当前主操作面板）时显示灰层：
  - `MAIN`：主面板在右，灰层隐藏；
  - `CAMPAIGN / COOP_START`：主面板在左 → 灰层显示；
  - `CAMPAIGN_DETAIL`：战役面板在左 → 灰层显示；
  - `COOP_ROOM / COOP_READY`：合作面板在左 → 灰层显示。
- 转场时灰层随面板一起淡入/淡出（0.2s）；转场结束按最终状态钉死。
- 侧栏变灰时调用 `FillButtonRes.clear_hover_in(panel)` / `clear_latched_in(panel)`，避免按钮停在金色满格或悬停态。
- 灰层显示期间，侧栏上的 X、三个按钮、底栏、章节/旗帜都不可点；退出/返回只能通过当前右侧面板的返回按钮或先回主菜单。
- 测试要断言：灰层可见时，对侧栏按钮中心点一下不会改变页面/不会退出。

---

## 5. 组件清单

### 5.1 新增

| 文件 | 作用 |
|---|---|
| `view/menu_deck.gd` | 页面栈 / 横向滑动 / 面板显隐 / 输入闸。 |
| `view/menu_deck_layout.gd` | 新菜单的几何常量与 `panel_rect` / `main_layout` / `campaign_layout` / `detail_layout` / `coop_layout` / `room_layout` / `ready_layout` 静态函数。 |
| `view/menu_glow_header.gd` | 半圆形泛光 + 居中标题；程序化纹理，无贴图。 |
| `view/menu_close_button.gd` | 程序化 X（两条斜线）；56×56；hover 提亮。 |
| `view/menu_back_button.gd` | 56×56 方块返回按钮（`‹`），统一样式。 |
| `view/menu_banner.gd` | 旗帜：旗杆 + 旗面 + 顶部横杆；支持玩家/空位/关卡三种状态；hover/选中。 |
| `view/menu_faction_button.gd` | 阵营按钮：左侧阵营色条 + 阵营名 + 目标；按钮底层用 `fill_button`。 |
| ~~`view/menu_map_backdrop.gd`~~ | 已移除；战役面板改为纯暗底。 |
| `view/main_menu_panel.gd` | 主菜单面板。 |
| `view/campaign_map_panel.gd` | 战役地图面板。 |
| `view/campaign_detail_panel.gd` | 战役详情面板。 |
| `view/coop_start_panel.gd` | 合作过渡面板。 |
| `view/coop_room_panel.gd` | 合作房间面板。 |
| `view/coop_ready_panel.gd` | 合作准备面板。 |
| `view/coop_map_picker.gd` | 合作地图选择面板：640×1080，从右滑入，压在准备面板之上。 |
| `view/coop_session.gd` | 合作会话/网络控制器（无绘制）；从 `coop_lobby.gd` 抽出联机逻辑。 |
| `logic/campaign_menu_brief.gd` | 把菜单章节解析成可显示数据：`campaign/level/playable/map/title/description/placeholder`。 |

### 5.2 修改

| 文件 | 改动 |
|---|---|
| `view/start_screen.gd` | 移除 `menu_chrome/panel_expand/menu_secondary_panel/options/test 按钮`；改为 `MenuDeck`；入场落位目标改为主面板 logo/名称；新增 `handle_back()` 与 deck 访问器。 |
| `view/main.gd` | 连接新的 `campaign_level_chosen(campaign_id, level_id, faction)`；`_show_level_transition` 增加 faction 参数；安卓返回先走菜单返回；移除主菜单 options 连接。 |
| `view/level_transition.gd` | 重写为新的两面板过渡页；去掉阵营面板/选择；faction 由外部传入；不可取消。 |
| `view/menu_theme.gd` | 新增 `deck_panel()`、`block_button()`、`glow_color()` 等；复用现有金/字色。 |
| `view/menu_background.gd` | 基本不动；必要时把中心辉光调淡，给左侧留白。 |
| `view/coop_map_card.gd` | 改为读取 `menu_deck_layout.gd` 的卡片尺寸（或保留 `coop_layout` 仅作卡片常量）。 |
| `logic/campaign_menu_db.gd` | 章节可带可选 `flag_x/flag_y/map_id`（不写则默认中心）；保持旧数据兼容。 |
| `data/config.json` | 新增 `menu.deck` 段（文案、字号、时长、alpha）；旧 `menu.chrome` / `menu.campaign_menu` / `menu.transition` 保留但不再被新代码读取，待清理。 |
| `tests/test_case.gd` | 移除 `open_campaign_panel` 等旧 helper，换 `open_campaign` / `open_campaign_detail` / `open_coop_*`。 |

### 5.3 废弃 / 删除（本轮完成后）

- `view/menu_chrome.gd`
- `view/panel_expand.gd`
- `view/menu_secondary_panel.gd`
- `view/campaign_menu.gd`
- `view/campaign_carousel.gd`
- `view/coop_lobby.gd`
- `view/coop_layout.gd`（若 `coop_map_card` 不再需要）
- `tests/test_menu_chrome.gd`
- 旧的主菜单 options 测试段

> 删除前先确认没有其他脚本 preload；目前引用集中在上述菜单/测试文件。

---

## 6. 页面行为细则

### 6.1 入场页 → 主菜单

保留现有入场页：徽记 + DAEEM + 金线 + 「点击任意处进入游戏」+ 启动黑幕 + 扫光。

点击后：

1. 主面板 `visible = true`、`modulate.a = 0`，放在最终右侧位置；主面板内容（logo/名称/按钮/底栏）alpha 0，便于量目标矩形。
2. 主面板背景 0.35s 渐显；内容在 0.25s 后 0.25s 渐显。
3. 入场徽记 / 标题用 0.5s 缓动到主面板 logo 方框 / 名称条：
   - 位置、尺寸一起过渡；
   - 标题字号从 128 → 36、tracking 从 26 → 8；
   - 金线淡出，点击提示淡出。
4. 动画期间 `_intro.z_index` 提到 deck 之上，保证移动中的 logo/名称不被渐显的面板盖住；结束后恢复并隐藏入场页。
5. 完成后：`page = PAGE_MENU`，主面板按钮可点。
6. 动效关闭 / 时长 0：直接切页，不建 tween。

### 6.2 主菜单

- 战役 → `deck.goto_campaign()`。
- 合作 → `deck.goto_coop_start()`。
- 演义 → 只播放按下态，不跳转。
- 自定义 / 备战 → 只播放按下态，不跳转。
- X → `quit_requested`（main 弹现有 `quit_confirm.gd`）；**只在 MAIN 页可点**。
- 从子页面返回时，主面板从左侧滑回右侧；不要重置选中章节/合作会话（除明确退出）。
- 主面板在侧栏位时显示 `SidebarDim`，X/三个按钮/底栏全部不可点。

### 6.3 战役地图

- 数据：`CampaignMenuDb.load_campaigns()`；当前固定使用第 0 项 `c1`，旗帜固定指向其唯一真实章节 `main_test → demo/mt`。
- 章节按钮 I/II/III：
  - 点击 → **只切换选中高亮**，不重建底图、不换旗帜、不改详情数据；
  - 保留 `selected_chapter` 状态供以后接真实章节切换。
- 旗帜点击 → `deck.goto_campaign_detail(current_chapter)`。
- 返回 → `deck.goto_main()`。
- 地图底图：已移除；不再烘地形、不再画暗角。
- 旗帜位置默认面板正中，尺寸约 200×260。
- 占位数据兜底仍写在 `CampaignDetailPanel` 里（无真实关卡 → 禁用按钮），本轮界面不可达。
- 进入详情页后战役面板到侧栏位，显示 `SidebarDim`，旗帜/章节按钮不再可点。

### 6.4 战役详情

- 解析章节：
  - `campaign_id/level_id` 都有 → 载入 `campaign/level`，取 `LevelBrief.playable_entries()`、`LevelBrief.briefing_text()`、`level.map`；
  - 任一为空 → 占位。
- 缩略图：有地图 → `MapThumb`；无地图 → 占位地图（同 §6.3 占位画法）。
- 描述：优先章节 `description`；为空用 `LevelBrief.briefing_text()`；占位写「该关卡尚未开放」。
- 阵营按钮：
  - 文案：`阵营名` + 小字目标（`LevelBrief.goal_text`）；
  - 颜色：左侧 6px 本阵营色条；按钮底暗金线框；
  - 点击 → `faction_chosen(campaign_id, level_id, faction_id)`。
- 占位：一个禁用按钮「暂不可用」。
- 返回 → `deck.back()`（回战役地图）。

### 6.5 战役过渡

- 由 `main` 创建，`start_screen` 整层还在（只是被覆盖）；与现有流程一致。
- `setup(cfg, font, campaign, level, faction)`。
- 不再显示阵营选择；标题区显示「战役名 · 单人/合作 · 阵营名」。
- 加载：`ResourceLoader.load_threaded_request("res://view/game_scene3d.gd")`，真实进度；加载完成后条下滑、提示淡入/呼吸。
- 点击提示 → `enter_requested(faction)`；main 黑屏 → 收过渡页 → 建世界 → 淡入。
- 若建世界失败：收掉过渡页，回到战役详情/主菜单，不能卡在黑屏；用现有 `_on_campaign_level_chosen` 的失败分支兜底。
- 不可取消：Esc 被 `_unhandled_input` 吞掉；`cancel()` 仅保留给测试/程序化清理，不接 UI。

### 6.6 合作过渡

- 进入时 `coop_session.enter_room_mode()` 预取房间列表（也可在 ROOM 页再取）。
- 玩家旗帜：显示「你 / player」；点击无逻辑（仅 hover）。
- 虚位旗帜：点击 → `coop_session.enter_ai_mode()` → `deck.goto_coop_ready("coop_start")`。
- 面板空白处（不是两面旗帜、不是返回）点击 → `deck.goto_coop_room()`。
- 返回 → `coop_session.leave_all()` → `deck.goto_main()`；返回按钮在合作面板右上，面板激活时可用。
- 旗帜外区域用面板的 `gui_input` 收点击；旗帜自身 `STOP`，避免冒泡成「进房间」。
- 主面板在侧栏位显示 `SidebarDim`，X/三个按钮/底栏全部不可点。

### 6.7 合作房间

- 进入 `COOP_ROOM` 时启动房间列表轮询（2s），离开停止。
- 房间列表行：`房间码 + 状态`；只允许等待中的行点击填入房间码。
- 数字键盘 + 6 位显示；`LineEdit` 仍可保留接收键盘输入（移动端可只用键盘）。
- 动作按钮：
  - 6 位且无此房 → 创建；
  - 6 位且可加入 → 加入；
  - 已满/游戏中 → 禁用并显示原因。
- 创建/加入成功：收到 `room_state` → `deck.goto_coop_ready("coop_room")`。
- 返回 → `coop_session.leave_room()` → `deck.goto_coop_start()`。
- 错误/连接状态显示在列表底部的小字，不弹窗。
- 合作面板在左侧显示 `SidebarDim`，其旗帜/返回不可点；房间面板的返回才是唯一返回入口。

### 6.8 合作准备

- 会话状态：
  - `mode=ai`：玩家 + AI；`is_host=true`、`guest=true`、`ready=true`（逻辑上的本地房间，不连服务器）。
  - `mode=host`：等待 guest；guest 加入/准备由 `room_state` 更新。
  - `mode=guest`：自己准备/取消准备；房主开始后收到 `guest_started`。
- 地图缩略图：
  - 房主/AI：点击 → `deck.open_map_picker()`（右侧 640 面板从右滑入，准备面板不动）；确认后 `coop_session.select_map(entry)`，面板滑出；房主会广播 `room_cfg`。
  - 客机：禁用点击，显示「由房主选择地图」。
- 地图选择面板：`coop_map_picker.gd`，标题「选择地图」；3 列 170×200 地图卡 + 滚动；底部「确认 / 取消」；点卡片只高亮，确认才应用。
- 动作按钮：
  - AI：`开始` → `coop_session.start()` → `coop_solo_started`；
  - 房主：按 §3.8 的状态切换；`开始` → `host_started`；
  - 客机：`准备/取消准备` → `lobby.ready()`。
- 返回：
  - AI：`coop_session.leave_all()` → `deck.goto_coop_start()`；
  - 真人：`deck.goto_coop_room()`，不离开房间。
- 进入游戏：`start_screen.close()`；`main` 建合作局；返回主菜单走现有 `return_to_menu()`，会话清理。
- 合作面板在左侧显示 `SidebarDim`，旗帜/返回不可点；准备面板的返回才是唯一返回入口。

---

## 7. 合作会话抽取（coop_session.gd）

### 7.1 为什么抽

`coop_lobby.gd` 目前同时承担：UI 三态、联机、房间列表、AI 模式、地图选择。新 UI 是三个独立面板，继续把 UI 写在一个 1400 行文件里会难以维护。抽取后：

- `view/coop_session.gd`：只做状态 + 网络 + 数据；
- 三个面板只做显示与转发；
- 现有协议/中继/房间目录代码不动。

### 7.2 对外接口（草案）

```gdscript
signal rooms_changed(rooms: Array)
signal status_changed(text: String)
signal room_entered(role: String, code: String)
signal room_state_changed(state: Dictionary)
signal room_config_changed(entry: Dictionary)
signal host_started(campaign_id: String, level_id: String, transport)
signal guest_started(payload: Dictionary, transport)
signal solo_started(campaign_id: String, level_id: String, ai_setup: Dictionary)
signal error(text: String)
signal left_room()

func setup(cfg) -> void
func entries() -> Array
func current_entry() -> Dictionary
func select_map(entry: Dictionary) -> void
func enter_ai_mode() -> void
func enter_room_mode() -> void
func refresh_rooms() -> void
func create_or_join(code: String) -> void
func set_ready(on: bool) -> void
func start() -> void
func leave_room() -> void
func leave_all() -> void
func is_ai() -> bool
func is_host() -> bool
func room_code() -> String
func guest_joined() -> bool
func guest_ready() -> bool
```

### 7.3 从 `coop_lobby.gd` 迁移的逻辑

- `_ensure_lobby / _relay_url / _on_lobby_connected / _on_transport_error / _on_lobby_error / _on_lobby_closed`
- `_refresh_rooms / _http_url / _start_room_timer / _on_rooms_completed`
- `_on_room_state / _on_room_config / _on_guest_started`
- `_begin_join_or_create / _send_pending_action`
- `_update_room_action` 的状态判定 → 暴露 `can_start / should_wait / ready` 查询
- `_start_host / _leave_room / _reset_network`
- `_start_ai_solo` → `start()`
- `_open_map_select / _apply_pending_map / _broadcast_room_cfg` 的数据部分
- `_load_catalog / _map_data_for / _update_room_preview` 的数据部分

不迁移：所有 `Panel/Button/Label/Tween`、`coop_layout.gd` 坐标、返回按钮托管、AI 模式 UI 开关。

### 7.4 兼容

- `net/lobby.gd`、`net/relay_transport.gd`、`net/room_directory.gd`、`net/protocol.gd` 不改。
- `coop.lobby.*` 配置文案继续复用；新增少量标题文案放 `menu.deck`。
- `test_coop_lobby.gd` 改为直接测 `coop_session`；`test_coop_ui.gd` 改为测新三面板。
- `test_ai_order_panel.gd` 里「AI 模式」那一小段改用 `coop_session.enter_ai_mode()`，不再实例化旧大厅。

---

## 8. 配置 / 数据

### 8.1 新增 `menu.deck`

建议结构（具体数值可调）：

```jsonc
"menu": {
  "deck": {
    "panel_ratio": 0.3333,
    "panel_min_w": 520,
    "panel_max_w": 720,
    "transition_sec": 0.42,
    "panel_fade_sec": 0.28,
    "content_pad": 40,
    "main": {
      "exit_size": 56,
      "exit_margin": 24,
      "logo_size": 200,
      "logo_top": 72,
      "name_w": 240,
      "name_h": 52,
      "name_gap": 32,
      "button_w": 400,
      "button_h": 100,
      "button_gap": 60,
      "button_top": 440,
      "bottom_h": 150,
      "buttons": ["战役", "合作", "演义"],
      "bottom_buttons": ["自定义", "备战"]
    },
    "titles": {
      "campaign": "战役",
      "detail": "详情",
      "coop": "合作",
      "room": "房间",
      "ready": "详情",
      "back": "返回"
    },
    "campaign": {
      "glow_w": 460,
      "glow_h": 150,
      "flag_w": 200,
      "flag_h": 400,
      "chapter_btn": 84,
      "chapter_gap": 16
    },
    "detail": {
      "thumb": 400,
      "desc_h": 200,
      "faction_h": 100,
      "faction_gap": 20
    },
    "coop": {
      "flag_w": 280,
      "flag_h": 560,
      "flag_gap": 200
    },
    "room": {
      "list_h": 440,
      "input_h": 420
    },
    "ready": {
      "thumb": 400,
      "desc_h": 200,
      "action_h": 88
    }
  }
}
```

> 旧 `menu.chrome` / `menu.campaign_menu` / `menu.transition` 先保留，避免一次性删配置导致其他测试/工具找不到键；新代码只读 `menu.deck` 与既有 `coop.lobby.*`。

### 8.2 战役数据

- `data/campaigns_menu.json` 结构不变；只更新 `c1` 章节的 `description`：去掉旧的「长按进入」，改为「点击旗帜进入详情；蓝方守 / 红方攻」一类与新交互一致的文案。
- `logic/campaign_menu_db.gd` 的章节解析新增可选字段（不写则默认）：
  - `flag_x` / `flag_y`：旗帜在战役地图中的归一化位置，默认 `0.5 / 0.55`；
  - `map_id`：可选；不写则从 `campaign_id/level_id` 反查真实关卡地图。
- `logic/campaign_menu_brief.gd` 统一解析：
  - `placeholder`、`campaign`、`level`、`entries`、`map`、`title`、`description`；
  - 菜单页/详情页/测试都从这里取，避免各写一份。
- 合作地图目录继续用 `logic/coop_catalog.gd`。

---

## 9. 动效 / 交互细节

| 项 | 规格 |
|---|---|
| 主面板入场 | 0.35s 淡入；内容 0.25s 后淡入 0.25s |
| logo/名称落位 | 0.5s，`TRANS_CUBIC / EASE_IN_OUT`；位置+尺寸+字号+字距 |
| 横向转场 | 0.42s，`TRANS_CUBIC / EASE_IN_OUT` |
| 面板淡入 | 0.28s |
| hover 金填充 | 复用 `fill_button.gd`，不下调时长 |
| 旗帜 hover | 放大 1.02 + 亮边；按下略缩 0.98 |
| 章节按钮选中 | 实心金底 + 近黑字（或填充层 latched） |
| 泛光 | 静态；不呼吸、不闪烁 |
| 动效总开关 | 所有 tween 前判 `ThemeRes.animations_enabled()`；关闭时立即到终态 |
| 转场输入 | `TransitionShield` 全屏 STOP；转场中 back/按钮全部无效 |
| 触摸 hover | 继续走 `start_screen._input` 的触摸抬起清理 |

---

## 10. 测试计划

### 10.1 更新 / 新增

| 测试 | 内容 |
|---|---|
| `test_start_flow.gd` | 保留入场页/点击/启动淡入断言；主界面改为新面板：右侧、logo/名称、三按钮、底栏、X；点击 X 弹退出确认；演义/自定义/备战不跳转；入场落位后主面板不透明。 |
| 新增 `test_menu_deck.gd` | 六页 x 坐标、显隐、转场后状态、返回栈、转场输入闸、窗口尺寸变化、动效关闭时瞬时到位；侧栏 `SidebarDim` 可见时点击侧栏按钮/ X 无效。 |
| `test_campaign_menu.gd` → `test_campaign_flow.gd` | 章节数据解析；战役页一面旗帜固定 `demo/mt`；点旗进详情；I/II/III 点击只选中；详情缩略图/描述/2 个阵营按钮；占位数据兜底（直接 API）；返回动效终态。 |
| `test_level_transition.gd` → `test_campaign_start.gd` | 两面板布局；无阵营面板；faction 由 setup 传入；加载进度真实推进；进度条落画后提示可点；点击发 `enter_requested(faction)`；Esc/安卓返回被吞。 |
| 新增 `test_coop_menu.gd` | 合作过渡两面旗；点虚位旗进 AI 准备；点空白进房间；房间列表/数字键盘（不连网）；准备页地图/描述/动作按钮；AI/房主/客机三种状态；返回来源。 |
| `test_coop_lobby.gd` → 保留名字，改测 `coop_session` | 房间列表解析、创建/加入、host/guest、准备/开始、地图广播、断开清理；使用现有 `tests/fake_transport.gd`。 |
| `test_coop_ui.gd` | 删除旧三态 UI 断言；几何/状态断言并入 `test_coop_menu.gd`。 |
| `test_coop_entry.gd` | 主菜单「合作」按钮 → 合作过渡页；不再走「合作模式」撑开面板。 |
| `test_settings_menu.gd` | 删除主菜单 options 段；保留局内设置菜单（全屏/返回主菜单）断言。 |
| `test_ai_order_panel.gd` | AI 队友模式改用 `coop_session.enter_ai_mode()`；不再实例化旧大厅。 |
| `tests/test_case.gd` | 删除旧 `open_campaign_panel`；新增 `open_campaign` / `open_campaign_detail` / `open_coop_ready` 等 helper。 |
| `tests/test_menu_chrome.gd` | 删除（旧外壳不存在）。 |
| `tests/bench_menu_shot.gd` | 重写截图序列：`01_intro`、`02_main`、`03_campaign`、`04_campaign_detail`、`05_campaign_start`、`06_coop_start`、`07_coop_room`、`08_coop_ready`、`09_main_hover`。 |
| `tests/bench_ai_lobby_shot.gd` | 改为截图新的合作准备页（AI 模式）。 |

### 10.2 视觉验收

- 用 `bench_menu_shot.gd` 真实渲染 1920×1080；再跑 2400×1080 与 1280×720 各一张（可在脚本里覆盖窗口尺寸），检查：
  - 面板贴边、无裁切；
  - logo/名称在 640 宽面板内不出界；
  - 三颗按钮/底栏不重叠；
  - 战役旗帜/章节栏不压边；
  - 详情阵营按钮在 1/2/4 个时不溢出；
  - 合作旗帜在 1280 宽面板内居中；
  - 准备页地图/描述/按钮不越界。
- 对比基线截图：`shots/01_intro.png`、`shots/02_menu.png`、`shots/03_campaign.png`、`shots/08_level_transition.png`（当前版本，已生成，仅作迁移前参考）。

### 10.3 命令

```powershell
cd dev_gd_a/daeem
powershell -ExecutionPolicy Bypass -File tools/check-syntax.ps1
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_start_flow
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_menu_deck
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_campaign
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_coop
powershell -ExecutionPolicy Bypass -File tools/run-tests.ps1 -Filter test_level_transition
& 'C:\D\GodotEngine\gd4.7.2mono\Godot_v4.7.2-stable_mono_win64_console.exe' --path . --script res://tests/bench_menu_shot.gd
```

最后跑一次全量 `tools/run-tests.ps1`（允许耗时）。

---

## 11. 实施顺序

1. **骨架与量尺**：`menu_deck_layout.gd` + `menu_deck.gd` + 六个空面板；先放色块/占位文字，跑截图确认 640/1280 的六页位置。
2. **主菜单**：`main_menu_panel.gd` + `menu_close_button.gd` + 入场落位改造；截图确认 logo/名称/按钮/底栏。
3. **战役线**：`campaign_map_panel.gd` + `campaign_detail_panel.gd` + `campaign_menu_brief.gd` + 旗帜组件；打通「战役 → 详情 → 返回」。
4. **战役过渡**：重写 `level_transition.gd`，main 传入 faction；打通进入游戏与失败兜底。
5. **合作会话**：抽 `coop_session.gd`，先让原测试/假 transport 能跑；再接三块面板。
6. **合作三页**：`coop_start_panel.gd` → `coop_room_panel.gd` → `coop_ready_panel.gd` + 地图选择面板；打通 AI/房主/客机。
7. **导航/返回/退出**：Esc、安卓返回、X、`reset_to_main`、转场输入闸。
8. **测试与截图**：重写测试，跑过滤/全量，调视觉。
9. **清理**：删旧菜单文件与旧测试，更新 `test_case.gd` 注释；确认没有残留 preload。

---

## 12. 已确认的补充 / 仍按假设执行

1. **I/II/III**：已确认**只做选中反馈**，不切地图；唯一旗帜固定 `demo/mt`（main_test）。
2. **演义/自定义/备战**：保持可点击、有按下态、无跳转，不加「暂未开放」toast。
3. **合作过渡空白点击**：整个面板空白区都当作「进房间」；旗帜/返回/标题除外。
4. **合作准备页状态行**：已确认允许加；按钮上方显示房间码/等待队友/本地 AI。
5. **地图选择面板**：已确认要参考当前游戏；做成**右侧 640×1080 面板从右滑入**，准备面板不移动，内含卡片网格 + 确认/取消。
6. **主菜单左侧空白**：保留现有暗色渐变 + 中心辉光，不放插画。
7. **战役过渡不可取消**：建世界失败时自动收掉过渡页回战役详情，不会卡黑屏。
8. **旧配置文件**：`menu.chrome` / `menu.campaign_menu` / `menu.transition` 先留着不删；新代码只读 `menu.deck`。
9. **左移侧栏**：已确认全部不可交互；每个左移面板加灰色遮罩，遮罩挡住 X、三个按钮、底栏、旗帜/章节按钮。

---

## 13. 验收标准

- [ ] 主菜单：左侧留空；右侧 640 面板；X 退出确认；logo + 名称；战役/合作/演义；自定义/备战。
- [ ] 入场点击：主面板渐显，logo 与名称平移到主面板，不闪、不重叠、不点到不可见按钮。
- [ ] 战役：主菜单左移；1280 战役面板；半圆泛光「战役」；`main_test` 地图 + 中央旗帜；右侧 I/II/III 只切选中高亮；旗帜可点；返回。
- [ ] 详情：战役面板左移；640 详情面板；泛光「详情」；缩略图；描述；`demo/mt` 的 2 个动态阵营按钮（蓝方/红方）；返回。
- [ ] 战役过渡：两面板 + 底部加载/呼吸提示；真实进度；点击进入正确阵营；不可取消；失败兜底。
- [ ] 合作过渡：主菜单左移；1280 面板；泛光「合作」；玩家旗 + 虚位旗；空位 → AI 准备；空白 → 房间；返回。
- [ ] 合作房间：640 面板；泛光「房间」；房间列表 + 数字输入；创建/加入 → 准备；返回退出。
- [ ] 合作准备：640 面板贴边；泛光「详情」；可点地图缩略图 + 地图描述；点击缩略图右侧滑入地图选择面板（卡片网格 + 确认/取消）；准备/开始状态；返回来源。
- [ ] 左移侧栏：主面板/战役面板/合作面板在左侧时都有灰色遮罩，内部 X、按钮、旗帜、返回全部不可点。
- [ ] 动效总开关关闭时，全部页面瞬时到位且可操作。
- [ ] 旧菜单文件/测试清理后，`check-syntax.ps1` 与全量测试通过。
- [ ] `bench_menu_shot.gd` 产出 9 张新截图，人工检查无裁切/重叠。


## 14. 追加修订（2026-10-27）

在已验收版本上按用户反馈继续调整：

- 主菜单 logo、DAEEM 名称条、右上角退出/返回都不再画边框；退出/返回改为右上角向左下铺开的金色径向泛光，悬停时提亮并略扩。
- 战役面板去掉地图底图与上下暗角；中央只留一面 200×260 的小型关卡旗帜。
- 战役页左侧主菜单的「战役」按钮、合作页左侧的「合作」按钮改为满金填充 + 深色字；选中面板盖在灰层之上，但不接收鼠标。
- 主菜单在进入详情/房间/准备等深层页面时跟着当前面板一起向左滑出（0 → -SIDE_W），返回时滑回 0；战役/合作过渡页仍保留完整左侧栏。
- 战役过渡底部去掉方形面板，只留进度条与「点击进入游戏」呼吸提示。
- 合作过渡到房间/准备改为 QUINT 缓动 + 入场淡入；主菜单同时左移，减少硬切。
- 点虚位旗加入 AI 后，旗帜内容变为「AI 队友 / 已加入」，并停止响应点击；返回合作过渡后恢复「虚位以待」。


## 15. 追加修订（2026-10-27 第二轮）

- 右上角泛光整体调暗（基准 0.16、悬停 0.55），悬停不再放大范围，只提升亮度。
- 退出/返回的真实命中区改为右上角 140×140 直角三角形（`x >= y`）；视觉按钮仍为 56×56 的 X/‹，三角形外不响应。
- 战役关卡旗从 200×260 再缩到 170×210；`MenuBanner._has_point` 只接受旗面 + 旗杆，透明边距不再算按钮。
- 合作过渡进入房间时，合作面板从 x=640 开始向左滑入，不再先瞬移到 0；与主菜单左滑、房间淡入同步，消除僵硬感。


## 16. 追加修订（2026-10-27 第三轮）

- 右上角泛光缩到 240×240，改为沿左下对角线衰减的扇形（不再以角落为圆心的同心圆），并在左/下边界淡出，去掉矩形硬边。
- 悬停只提亮、不扩大；离开时立即回到初始 `_hot=0`，避免移开后比初始更亮。
- 主菜单三颗主按钮高度 100→84；底部自定义/备战高度 150→120。
- 合作旗帜取消竖杆，改为布面上沿一根实心横线；战役旗帜仍保留竖杆 + 顶杆，两种旗帜明确区分。
- 第 4 条用户未填写内容，待补充。


## 17. 追加修订（2026-10-27 第四轮）

- 右上角光效改为真正的“上边 + 右边”边缘辉光：在 240×240 区域内沿两条边衰减，离开边缘迅速变暗；不再有方形/圆形填充。
- 悬停只提高边缘亮度，不扩大尺寸；移出时 `_hot` 立即归零，保证与初始强度一致。
- 主菜单战役/合作/演义改为纯文字按钮（无方框）：悬停时左右各渐显一根“————”。
- 选中模式在灰层之上放一块纯文字 + 左右横线的标记层；面板左滑、变暗后横线仍保持满亮。
- 战役/合作/演义按钮高度 100→84，自定义/备战高度 150→120。
- 合作旗帜取消竖杆，布面上沿只有一根实心横线；战役旗帜仍保留竖杆。


## 18. 追加修订（2026-10-27 第五轮）

- 右上角边缘泛光的默认强度提升到原悬停强度（0.55）；悬停进一步拉到 0.95。
- 悬停仍不改变范围，只改变亮度；移出后回到 0.55。


## 19. 追加修订（2026-10-27 第六轮）

- 战役/合作/演义的左右横线改为常驻：默认是较短（0.42 长度）的暗金色“——”。
- 悬停时横线增长到满长（1.0）并提亮为金色“————”；移出后回落到短暗横线。
- 选中模式仍使用满长金色横线，并在灰层之上的标记层中保持原样。
