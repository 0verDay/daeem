## hud.gd —— 新 UI（UI 改版：**废弃**原来的「顶栏 + 右侧选中面板 + 底部日志」）
##
## 布局逐像素照参考图（1920×1080），几何全部写在 view/ui_layout.gd 里：
##
##   右上 选项（80×160）★ 点它弹出**选项页菜单**（继续 / 设置 / 返回主菜单，见 `_build_options_panel`）
##   右侧 部队 1~10（10 槽 × 56 高，数字 1..9/0 + 名字 + 当前/上限，见 view/troop_row.gd）
##   左上 目标栏（`※目标` / `- 描述`，有目标才显示，见 view/objective_panel.gd）
##   左下 小地图（400×400：整张地图 + 视野框，左键点击移动镜头、按住拖动跟手，见 view/minimap.gd）
##   底栏 y 820..1080（★ 右下整组按 13/12 放大到 260，详细信息保持 260）：
##     资源面板 185×56（**本版新增**：粮食 / 黄金**竖着排**两行；下缘压在详细信息面板顶边
##                       y=820 上、宽度与左列列表一致、左缘对齐 x=402，数值每帧读 `world.resources`，
##                       见 `_build_resource_bar()`）
##     左下详情栏只在有有效选中时显示；空选中时不再显示阵营盾徽占位牌
##     详细信息 616.5×260（左栏 = 部队/单位列表；右栏 = 图标 / 名称 / 属性与特性）
##       ★ 数值那一块现在**只有正文**：顶上那行「详细信息」标题按需求去掉了
##     命令卡 3×3（每格 86.67，内容随页签实时切换）
##     页签（**按选中对象动态显示**：自己的部队 = 操作 / 单位；自己区划中心 = 招募；
##           自己大本营 = 操作 / 科技；自己的其它建筑 = 操作（里面的「拆除」牌）；
##           什么都没选中 = 建筑 + 科技；敌方 / 友方任何建筑单位 → **页签 + 命令卡整块隐藏**）
##     ★★ 2026.11.19：科技页现在是**一排扇形卡牌**（和手牌同一套 `card_fan_*` 几何，
##       最多 9 张、从左到右按阶分组），不再是九宫格 —— 它由 view/tech_grid.gd 画在最上层，
##       只有「科技」页才显示，见 _refresh_tech_grid()。
##
## ★ 仍然是纯表现：只读 world 与输入层的本地状态，从不改逻辑状态；
##   要改世界只有一条路 —— 让 input_controller 发命令（见 _on_card_entry）。
## ★ 全部用代码搭 Control 树、不建 .tscn：纯文本、可 diff、无头测试能直接实例化检查，
##   代价是不能在编辑器里可视化调布局 —— 原型阶段这个取舍仍然划算。
## ★ 事件翻译（逻辑事件 → 中文一行）**只在这里**做：逻辑层不写 UI 文案。
##
## ★★ 选项页菜单的两个动作**不由本文件执行**（本轮改）：
##    「全屏」与「返回主菜单」一个动的是窗口模式、一个动的是整个流程（要销毁本场景），
##    两件都是 view/main.gd 的地盘。所以这里只**发信号**，谁执行见
##    `fullscreen_toggled` / `return_to_menu_requested` 的注释。
extends CanvasLayer

## 选项页里点了「全屏 / 窗口化」—— ★ 只是一个请求，真正切窗口模式的是 view/main.gd
## （它同时管着 Ctrl+Q 那条快捷键，两处必须是同一份实现）。
signal fullscreen_toggled
## 选项页里点了「返回主菜单」—— ★ 同上：真正拆场景、把开场页放回来的是 view/main.gd。
signal return_to_menu_requested

const ConfigRes = preload("res://logic/config.gd")
const FactionRes = preload("res://logic/faction.gd")
const BuildingRes = preload("res://logic/building.gd")
const EconomyRes = preload("res://logic/economy.gd")
const UpgradeRes = preload("res://logic/upgrade.gd")

const UiLayoutRes = preload("res://view/ui_layout.gd")
const UiStyleRes = preload("res://view/ui_style.gd")
## ★ 动效开关（`animations_enabled()`）：卡牌悬停面板「等牌站稳再出现」要读它。
const ThemeRes = preload("res://view/theme.gd")
const SquadPanelRes = preload("res://view/squad_panel.gd")
const DetailPanelRes = preload("res://view/detail_panel.gd")
const DetailV2Res = preload("res://view/detail_v2.gd")
const TroopGridRes = preload("res://view/troop_grid.gd")
const CommandCardRes = preload("res://view/command_card.gd")
## ★★ 命令卡格子里的**金线图标**（单位页不再写兵种名字，改画它）。
##   hud 这一层只做「条目 → 兵种 id → 图形 role」的翻译，画法在 view/unit_card_icon.gd。
const UnitCardIconRes = preload("res://view/unit_card_icon.gd")
const PageTabsRes = preload("res://view/page_tabs.gd")
const TechGridRes = preload("res://view/tech_grid.gd")
## ★★ 2026.11.19：卡牌悬停面板 —— 浮在**悬停那张牌的侧边**（取代原来左下角那块固定说明牌）。
const CardHoverPanelRes = preload("res://view/card_hover_panel.gd")
const MinimapRes = preload("res://view/minimap.gd")
## ★★ 左上角目标栏（战役 / 合作；M12.1 新增，2026.10.20 改为左上两行）。见 view/objective_panel.gd。
const ObjectivePanelRes = preload("res://view/objective_panel.gd")
## ★★ 左下角小地图正上方的播报横幅（大本营升级）。见 view/broadcast_banner.gd。
const BroadcastBannerRes = preload("res://view/broadcast_banner.gd")
const SideColorRes = preload("res://view/side_color.gd")
## ★★ 选项页菜单（仿 nsoc）：HUD 右上角「选项」与主菜单右上角「选项」共用同一套。
const OptionsPanelRes = preload("res://view/options_panel.gd")
## ★★ 合作 AI 队友的浮动指令面板（只在有同方 commander 时出现）。
const AiOrderPanelRes = preload("res://view/ai_order_panel.gd")
## ★★ 悬停时「金色自下而上填进来」的那套动效（见 view/fill_button.gd）。
const FillButtonRes = preload("res://view/fill_button.gd")

signal dialogue_finished(id: int)
## 玩家点击左侧对话框、请求跳过对话（由 `game_scene3d` 接给演出导演）。
signal dialogue_skip_requested(id: int)

var cfg: ConfigRes = null
var world = null
var input_ctrl = null
var camera_rig = null
## ★★ 稳定编队槽位（见 view/team_slots.gd）：右栏 / 左栏详情 / 数字键共用。
var team_slots = null
## ★★ 3D 投影助手（`view/palette.gd` 的实例）：小地图的「视野框 / 点击跳转」要用它
##    （2D 回退已随 2D 栈删除）。由 `setup()` 传进来、再原样转交给小地图。
var palette = null

var squad_panel: Control = null
var detail_panel: PanelContainer = null
var detail_v2: Control = null
## 旧字段保留为 null，避免旧测试/调用方读取时报错；不再创建盾徽占位牌。
var faction_placeholder: PanelContainer = null
var _detail_home_position := Vector2.ZERO
var _detail_slide_tween: Tween = null
## ★★ 2026.11.16 第二轮（用户口径）：「所有左下面板在出现时都需要有**向右滑动**的出现动画」。
##   左下角详情牌用这一套参数：从目标位置**左侧** `DETAIL_SLIDE_FROM_X` 出发，
##   `DETAIL_SLIDE_SEC` 秒缓出到位。（卡牌悬停面板在牌旁边淡入，不走这一条。）
const DETAIL_SLIDE_SEC := 0.16
const DETAIL_SLIDE_FROM_X := -72.0
var command_card: Control = null
var page_tabs: Control = null
## ★ 科技九格（盖在命令卡上，只有「科技」页才显示）。见 view/tech_grid.gd。
var tech_grid: Control = null
## ★★ 建筑牌被拖起期间的状态（见 `_on_card_drag_started` / `_commit_card_build_drag`）：
##   · `drag_build_anchors` —— 这一张牌**所有能落**的锚点（`world.build_anchors_for()`：
##     普通建筑 = 己方区划的空点位；城墙 = 己方区划中心），拖起那一刻算一次；
##   · `drag_build_anchor`  —— 指针当前落在哪个锚点的圆形范围里（null = 没吸附）；
##     松手时**只认它**（用户口径：在圆形范围指示内放下 = 在点位处建造）；
##   · `drag_build_tile`    —— 吸附到的格子（= 锚点格；没吸附 = (-1,-1)）。
##     ★ 保留这个名字是因为 3D 虚影（game_scene3d）与旧测试都在读它。
##   · 圆半径来自 config 的 `build.drop_radius_tiles`（overlay 用它画投影圆）。
## ★★ 2026.11.17：拖建筑牌**也能升级** —— 同种建筑（己方、没满级）同样是「能落点」：
##   · `drag_upgrade_targets` —— 地块 → 建筑（`world.building_upgrade_targets()`）；
##     拖起那一刻算一次，它的格子一起塞进 `drag_anchor_tiles` ⇒ overlay 画同一种高亮；
##   · `drag_build_upgrade`   —— 指针吸附到的**可升级建筑**（null = 没吸附到建筑）。
##     ⚠️ 与 `drag_build_anchor` 互斥：吸附到建筑就是升级，吸附到空点位就是建造。
var drag_build_active: bool = false
var drag_build_type := ""
var drag_build_screen_pos := Vector2.ZERO
var drag_build_tile := Vector2i(-1, -1)
var drag_build_anchors: Array = []
var drag_build_anchor: Variant = null
var drag_upgrade_targets: Dictionary = {}
var drag_build_upgrade: Variant = null
var drag_build_radius: float = 1.5
## ★★ 虚影要显示在哪：普通建筑 = 吸附点（没吸附 = 指针所在格，虚影常驻）；
##    城墙 = 一圈墙段，围「吸附到的中心」或「离指针最近的己方区划中心」。
var drag_build_pointer_tile := Vector2i(-1, -1)

## ★★ 2026.11.15 第二轮：**招募将领**的拖牌状态（与建筑同一套手感，见下）。
##   · `drag_recruit_anchors` —— 这一张牌所有能落的区划中心（`can_recruit_zone` 为空）；
##   · `drag_recruit_anchor` / `drag_recruit_tile` —— 吸附到的那个中心。
var drag_recruit_active: bool = false
var drag_recruit_kind := ""
var drag_recruit_screen_pos := Vector2.ZERO
var drag_recruit_tile := Vector2i(-1, -1)
var drag_recruit_anchors: Array = []
var drag_recruit_anchor: Variant = null
var drag_recruit_radius: float = 1.5
## ★★ 2026.11.19：单位牌的拖拽目标是**任意己方将军**（不是区划中心）。
##   true 时 `drag_recruit_unit_anchors` 里是 `{"unit": u, "tile": tx,ty}`。
var drag_recruit_unit_mode: bool = false
var drag_recruit_unit_anchors: Array = []

## ★★ 交给 overlay 的**统一拖牌锚点状态**（建筑 / 招募共用一套画法）：
##   圈从内往外扩散、离开时缩回；颜色由 `drag_anchor_kind` + `drag_anchor_ok` 决定。
var drag_anchor_active: bool = false
var drag_anchor_kind := ""
var drag_anchor_tiles: Array = []
var drag_anchor_tile := Vector2i(-1, -1)
var drag_anchor_ok: bool = true
var drag_anchor_radius: float = 1.5

## ★★ 建筑牌拖拽结束（拖回手牌 / 落在空处）时的提示：只在真的把牌拖到地图上过才提示，
##    免得「拖起来又拖回去」也弹一句红字。
var _drag_build_left_hand: bool = false
var _recruit_play_context: Dictionary = {}
## ★★ 卡牌悬停面板：鼠标停在手牌 / 科技牌上时，浮在**牌的左侧**（顶边对齐）。
##    见 view/card_hover_panel.gd（纯显示、不吃鼠标、不跟牌一起缩放）。
var card_hover: Control = null
## ★★ 将领卡的**第二块**面板：浮在牌的右侧，只列这位将领的特性（名称 + 说明）。
##    其余卡牌没有这一块（`clear()` 掉）。
var general_trait_panel: Control = null
## ★★ 2026.11.19：面板要等牌**站稳**再出现（用户口径）。牌自己的抬起 / 放大是 0.14s，
##    邻牌最迟再晚 0.025s 让开 ⇒ 0.18s 之后面板才淡入。中途换牌 / 移开 / 拖牌都会作废。
const CARD_HOVER_SHOW_DELAY := 0.18
## 「等牌站稳再弹」那一段计时（Tween；`_dismiss_hover` / 换牌会 kill）。
var _hover_show_tween: Tween = null
## ★★ 左上角目标栏：有目标才显示（老路径 / 自由对战整块隐藏）。
var objective_panel: Control = null
## ★★ 左下角小地图正上方的播报横幅（大本营升级；`ui.broadcast` 的尺寸与时长）。
##    它现在同时也是**对话**的宿主（见 view/notice_stack.gd）。
var broadcast_banner: Control = null
## ★★ 演出模态盾：对话 / 锁 UI 时盖在所有 HUD 之上（通知栈自己 z 更高）。
var story_shield: Control = null
## 资源飘字（给资源时从资源条旁边上浮淡出的数字）。
var _resource_floats: Array = []
## ★★ 合作 AI 队友的浮动指令面板（null = 本局没有 AI 队友 / 还没建）。
var ai_panel: Control = null
## ★★ 观战模式：隐藏命令卡 / 页签，只保留查看用 UI。
var observer_mode: bool = false
## ★★ 选项页控制器（overlay + 居中面板；见 view/options_panel.gd）。
##   `settings_panel` 只是它的 overlay 别名（兼容 main.gd / 旧测试）。
var options_panel = null
var settings_panel: Control = null
var fullscreen_button: Button = null
var return_menu_button: Button = null
## 左下角的小地图（400×400）。★ 变量名仍然是占位时代的 `map_placeholder`：
## 测试（tests/test_ui.gd）按这个名字断言它的位置与尺寸，换名字只会白改一把。
var map_placeholder: Control = null
var minimap: Control = null
## 资源条（粮食 / 黄金，横排）—— 详细信息面板**正上方**那一条。见 `_build_resource_bar()`。
var resource_bar: Panel = null
## ★★ 2026.10.29：上一次写进资源条的文字（键 = "food" / "gold"）。
##   资源条每帧刷一次，而 `(+n)` 显示到 0.1 ⇒ 一秒里也变不了几次；存一份上次的字符串，
##   没变就整段跳过（不重设 text、不重设 font_color）。
var _res_last_text: Dictionary = {}

var _root: Control = null

## 提示行（红字，约 ui.notice_sec 秒）——「招募被拒」这类操作的可见反馈。
## ★ 它不是被删掉的日志栏：只显示**最近一次**被拒的一句话，不保留历史。
var _notice_timer: float = 0.0

## ★★ F2：命令被拒时命令卡短暂染红（秒；0 = 不在闪）。
var _reject_flash_left: float = 0.0

## ★★ 手机端 HUD 刷新节流（桌面 / 无头恒为 0 = 每帧；见 config 的 ui._mobile_refresh_comment）。
##   `refresh()` 每帧要全表扫一遍单位 + 重拼详情文案，手机上不必 60Hz。
var _refresh_interval: float = 0.0
var _refresh_accum: float = 0.0
## ★★ 手机端 4 槽轮转（见 `_mobile_tick()`）：把「资源条 / 详细信息 / 部队列表」
##   拆到不同节拍上，避免同一帧叠出几毫秒的尖峰。
var _mobile_phase: int = 0
var _mobile_force_full: bool = false
var _mobile_ui_stagger: bool = false
## 本次刷新内的「选中部队」缓存：`_tab_plan()` 与详情分支共用一次扫描。
var _tick_troops: Array = []
var _tick_cache_on: bool = false
## 诊断计数：`_compute_selected_troops()` 被调了几次（测试断言「一次刷新只扫一次」）。
var troops_scans: int = 0

## ★ 手机端性能读数（见 `_build_perf_readout`）：Label + 刷新计时
var _perf_label: Label = null
var _perf_accum: float = 0.0
## 0.5 秒窗口内的 `_process` 耗时（秒）：和 / 峰值 / 帧数 —— 用来把「浮动很大」量化成平均/峰值
var _perf_cpu_sum: float = 0.0
var _perf_cpu_max: float = 0.0
var _perf_cpu_n: int = 0
## ★★ 同一窗口内的**真实帧间隔**（`dt` 的和）。与 `Performance.TIME_PROCESS` 不同，
##   它包含 vsync 等待 —— 是玩家实际感受到的「每帧多少毫秒」。
##   判读：`fr` ≈ `CPU` ⇒ CPU/GPU 真的算不完；`fr` ≫ `CPU` ⇒ 在等 vsync / 显示。
var _perf_dt_sum: float = 0.0
## ★★ 同一窗口内 `dt` 的**最小 / 最大**。平均值会把「周期性的重活」抹平：
##   如果 max 远大于 min（例如 10ms ~ 33ms），说明不是每帧都慢，而是某些帧被
##   HUD 刷新 / 小地图 / 迷雾重算 / 地面重烘这类周期性任务顶爆了。
var _perf_fr_min: float = INF
var _perf_fr_max: float = 0.0
## 窗口内 HUD 刷新总耗时（微秒）与三个分项：shell / detail / squad。
## 它们不在 `_process` 的分段里，是 `rest` 的主要候选之一。
var _perf_hud_sum: float = 0.0
var _perf_shell_sum: float = 0.0
var _perf_detail_sum: float = 0.0
var _perf_squad_sum: float = 0.0

## 中文字体（HUD 的 theme 里那一份）——转给需要自己 draw_string 的子控件
## （详细信息左栏的「部队方块 / 将领头像网格」）。主题里没字体时是 null，那边会退回引擎默认字体。
var _font: Font = null

## 详细信息左栏「当前展开的那支部队」的**部队编号**（1 起；0 = 还没定）。
##
## ★ 为什么要记住它：玩家点了下半某一格将领头像之后，左栏上半要一直停在那支部队上，
##   不能每一帧都被「默认第一支」抢回去。部队在 world 里是**算出来的**（没有 Squad 对象），
##   所以这里记的是**编号**（与左侧部队列表同一套口径），每帧按编号重新查那支队伍。
var _detail_troop_number: int = 0


# ------------------------------------------------------------------
# 右下「页签 + 命令卡」：显示哪几页**由当前选中的东西决定**
#
# ★★ 需求原话：
#   · 自己的部队 / 单位 → 两颗页签：**操作**（对部队下达的指令）+ **单位**（招募单位的页）
#   · 自己的大本营     → 操作 + **科技**（升级大本营那一格在操作页；科技照旧）
#   · 自己的区划中心   → **招募**（九宫格的将领，点了排进这个区划的招募队列）
#   · 自己的**无操作建筑**（木墙 / 哨塔 / 资源建筑…）
#                      → **页签 + 命令卡整块隐藏**
#   · **敌方 / 友方任何建筑 / 单位** → **页签 + 命令卡整块隐藏**
#     ★ 原话：「页签和命令卡都要隐藏，选中敌方/友方任何建筑/单位时，右下角标签都隐藏」。
#   · 什么都没选中   → **建筑**（城墙 / 箭塔的建造入口）+ **科技**两页
#     ★ 科技那颗与选中大本营时是**同一页**（同一个 PAGE_TECH、同一套九格）——
#       需求原话：「该科技页签也会同步到选中大本营时的科技页签中」。
#
# ★ 这一层的分工：`_tab_plan()` 说「现在该有哪几页、默认停哪页」，
#   `_rebuild_card()` 说「这一页里有哪些格子」，page_tabs / command_card 什么都不判断；
#   科技九格的内容与显隐由 `_refresh_tech_grid()` 推给 view/tech_grid.gd。
# ------------------------------------------------------------------

## 当前这一屏页签属于哪一类选中（"unit" / "zone" / "base" / "building" / "empty"）。
## ★ 它是「记住玩家上次停在哪一页」的键（见 `_page_memory`）。
## ⚠️ 「什么都没选中」用它自己的 "empty" 这一档：它与选中大本营那档（"base"）
##   页列表不同，记忆必须分开 —— 否则点过大本营（停在科技页）之后，
##   一松开选中就会直接停在科技页，而空手那一屏的默认页是「建筑」。
var _tab_kind: String = ""
## ★★ 悬停面板现在**是谁**弹出来的：来源（"card" / "tech"）+ 格子序号。
## 为什么要记这一对（本轮实测踩到的顺序问题）：`mouse_exited` 与 `mouse_entered`
## **不保证**谁先到 —— 从 A 格移到 B 格时，若 B 的 enter 先到、A 的 exit 后到，
## 光凭「收到 exit 就收面板」会把 B 刚弹出来的面板收掉（表现：面板闪一下就没）。
## 所以 exit 只在**它确实是当前这一格**时才收（见 `_on_hover_out`）。
var _hover_src: String = ""
var _hover_index: int = -1

## ★★ 手机端「长按 UI 格 = 悬停详情」的监视状态（见 `handle_touch` / `_tick_long_press`）。
##   手机上没有鼠标悬停：手指按在命令卡 / 科技格上时**不要**立刻弹详情（那会每点一下闪一下），
##   而是**按住 `touch.long_press_sec` 秒**之后才弹。松手时收起，并吞掉这一次「激活」
##   （长按只是为了看说明，不该顺手把那一格点下去）。
##   · `_lp_src` / `_lp_index`：长按的是哪一格（"card" / "tech" / "buff"）；
##   · `_lp_active`：正在按住；`_lp_press_ms` / `_lp_press_pos`：按下时间 / 落点；
##   · `_lp_shown`：详情已经弹出（松手据此收起）。
var _lp_src: String = ""
var _lp_index: int = -1
var _lp_active: bool = false
var _lp_press_ms: int = 0
var _lp_press_pos: Vector2 = Vector2.ZERO
## ★★ 2026.11.14：手指**最后**的位置 —— 操作牌松手时它就是「落点」
##   （触屏没有鼠标，`get_mouse_position()` 会停在不相干的地方）。
var _lp_last_pos: Vector2 = Vector2.ZERO
var _lp_shown: bool = false
## 命令牌向上滑动时转为拖牌；短点与长按说明仍走既有触摸处理。
var _lp_card_dragging: bool = false
## ★★ 上一次画命令卡时算出来的**内容签名**（见 `_card_sig()`）。
## `refresh()` 每帧比一次：签名变了就重建 —— 页签组合没变、但「选中的东西」或
## 「选中对象的权威状态」变了，靠的就是这一条（手玩报的「改选箭塔还写着升级城墙」）。
var _card_sig_key: String = ""
## 上一次推给 page_tabs 的配置（kind + 页列表）。每帧比一次，不变就不重推 ——
## 否则每帧都会重建命令卡。
var _tab_key: String = ""
## ★★ 2026.11.19：选中己方对象时自动跳页的「上一次选中签名」。
##   只在这里记住，玩家手动切页不会被强行拉回去。
var _page_jump_sig: String = ""
## ★★ 2026.11.19：`_sync_tabs()` 正在按**选中对象**重排页签时为 true。
##   此时 `page_tabs.set_pages()` 可能同步发 `page_changed` —— 这里先压制它，
##   避免「同一次选中变化」被播两遍；真正的整手牌入场统一由
##   `_animate_hand_on_selection_change()` 在刷新末尾播。
##   玩家自己点页签 / Tab 切页仍然走 `_on_page_changed()`，动效保留。
var _sync_tabs_guard: bool = false
## ★★ 2026.11.19：当前「己方部队 / 建筑」选中签名。签名变化时整手牌播一次入场，
##   包括「部队 ↔ 建筑」这种页签 / 手牌不同的切换（用户口径）。
var _hand_anim_sig: String = ""
## ★★ 2026.11.19：X 页签收起状态。true = 手牌 / 页签 / 科技格整块隐藏，
##   直到玩家重新选中对象或点空地（`local_ui_changed`）才恢复。
var _hand_collapsed: bool = false
## 收起动作内部会清选中，要避免 `local_ui_changed` 立刻把手牌又放回来。
var _collapsing_hand: bool = false


func setup(p_cfg: ConfigRes, p_world, p_input, theme: Theme, p_camera_rig = null,
		p_palette = null, p_team_slots = null) -> void:
	cfg = p_cfg
	world = p_world
	input_ctrl = p_input
	camera_rig = p_camera_rig
	# ★★ 2026.11.14 第三轮：选项按钮删掉之后，**Esc 是 PC 上唯一的入口**
	#   （安卓走返回键，见 main._on_android_back）。这里接输入控制器的请求信号。
	#   ⚠️ 用 is_connected 挡一道：同一份 input_ctrl 可能先后喂给重建的 HUD
	#     （重开一局 / 换关），重复 connect 会开两次菜单。
	if input_ctrl != null and input_ctrl.has_signal("open_menu_requested") \
			and not input_ctrl.open_menu_requested.is_connected(_on_open_menu_requested):
		input_ctrl.open_menu_requested.connect(_on_open_menu_requested)
	# ★★ 2026.11.15：操作牌与它的 3 秒冷却一起删除 —— 右键直接下令，不需要冷却钩子。
	# ★★ 编队槽位（稳定编号）：右栏 / 左栏详情 / 数字键共用同一份（见 view/team_slots.gd）。
	team_slots = p_team_slots
	# ★★ 投影助手一并收下并转交给小地图（见 `_build_minimap`）：这样小地图一建出来
	#    就拿着完整的 3D 口径，不必等调用方事后再 setup 一次。
	palette = p_palette
	_font = theme.default_font if theme != null else null

	# ★★ 手机端：HUD 文本刷新上限（桌面 / 无头恒为 0 = 每帧，行为与原来一致）。
	_refresh_interval = 0.0
	_mobile_ui_stagger = false
	if OS.has_feature("mobile") and cfg != null and cfg.mobile_hud_refresh_hz > 0.0:
		_refresh_interval = 1.0 / cfg.mobile_hud_refresh_hz
		_mobile_ui_stagger = bool(cfg.mobile_ui_stagger)

	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE     # 空白处的鼠标事件一律穿透给地图
	if theme != null:
		_root.theme = theme
	add_child(_root)

	_build_minimap()
	# ★ 让小地图的第一次重画错开 HUD 槽位（手机端避免同一帧叠加重活）
	if minimap != null:
		minimap.stagger_redraw(0.37)
	# ★ 资源条要在详细信息面板**之前**建：两块在屏幕上上下紧贴，
	#   先建的那块在下层 —— 万一以后谁把资源条调高了，它压住的是面板上沿而不是反过来。
	_build_resource_bar()
	# ★ 目标条在资源条之后、详细信息之前：它只影响屏幕上沿，与底栏无关。
	_build_objective_panel()
	# ★ 播报横幅紧跟着建（贴左下角、压在小地图上沿，与左上目标条不重叠）。
	_build_broadcast_banner()
	_build_detail_panel()
	_build_command_card()
	_build_page_tabs()
	# ★ 悬停面板最后建（在命令卡 / 科技牌**之上**）：它画在牌的侧边，
	#   z_index 也压过牌（见 view/card_hover_panel.gd）。
	_build_card_hover()
	_build_ai_panel()
	_build_squad_panel()
	# ★★ 选项页**最后建**：它是浮在别的 UI 之上的模态 overlay（z_index=200）
	_build_options_panel()

	# ★★ 最后建（压在最上层）：手机端性能读数（FPS · 内核 · 单位数）。
	_build_perf_readout()

	_rebuild_card()
	refresh()

	# ★★ 手机端：部队列表改由 HUD 的 4 槽调度器驱动，关掉它自己的 `_process`
	#   （否则它和 HUD 是各自独立的计时器，很容易叠在同一帧）。
	#   桌面 / 测试保持它自己的每帧刷新。
	# ★★ 2026.11.19：X 收起后，任何一次选中 / 点空地（local_ui_changed）都恢复手牌。
	#   桌面 / 手机都接；手机那条另有 `_on_mobile_ui_changed` 做全刷节拍。
	if input_ctrl != null \
			and not input_ctrl.local_ui_changed.is_connected(_on_local_ui_changed):
		input_ctrl.local_ui_changed.connect(_on_local_ui_changed)
	if _refresh_interval > 0.0:
		if _mobile_ui_stagger and squad_panel != null:
			squad_panel.set_process(false)
		# 选中变化（点选 / 框选 / 取消）→ 下一个节拍立即全刷，不等槽位轮转
		if input_ctrl != null and not input_ctrl.local_ui_changed.is_connected(_on_mobile_ui_changed):
			input_ctrl.local_ui_changed.connect(_on_mobile_ui_changed)


## 选中 / 本地 UI 变化：下个节拍走一次完整刷新（shell + detail + squad）。
func _on_mobile_ui_changed() -> void:
	_mobile_force_full = true


## ★★ 2026.11.19：X 收起后，只要玩家重新选中对象或点空地，就恢复手牌。
##   `_collapsing_hand` 期间不响应（收起动作自己会清选中）。
func _on_local_ui_changed() -> void:
	if _collapsing_hand or not _hand_collapsed:
		return
	_hand_collapsed = false
	# 强制下一次 `_sync_tabs()` 重新推页签（收起时把 key 清掉了）。
	_tab_key = ""
	# 选中 / 点空地那一下就要把手牌放回来，不等下一次 HUD 刷新。
	_sync_tabs()


func _process(dt: float) -> void:
	# ★★ 手机端：HUD 文本按上限频率刷（桌面 / 测试每帧；见 config 的 ui._mobile_refresh_comment）。
	var do_refresh := false
	if _refresh_interval <= 0.0:
		do_refresh = true
	else:
		_refresh_accum += dt
		if _refresh_accum >= _refresh_interval:
			_refresh_accum = 0.0
			do_refresh = true
	if do_refresh:
		# ★★ 手机端 4 槽轮转；桌面 / 测试 / 回退开关都走一次全刷。
		#   计时在 `refresh()` / `_timed_*()` 内部做（只在读数开着时付时钟调用）。
		if _refresh_interval > 0.0 and _mobile_ui_stagger:
			_mobile_tick()
		else:
			refresh()
	_tick_notice(dt)
	_tick_reject_flash(dt)
	_tick_broadcast(dt)
	_tick_resource_floats(dt)
	_tick_long_press()
	# ★ 手机端性能读数：约 2Hz 刷新（见 `_build_perf_readout`）。
	if _perf_label != null:
		_perf_accum += dt
		# ★★ 分段采样只在「完整读数」开着时才做：默认只显示 FPS 的那一档
		#   （`ui.show_perf_detail = false`）不必要每帧问一次 `Performance.get_monitor`，
		#   也不该把 `world.profile_on` 打开（那是真机排查才付的开销）。
		if cfg != null and cfg.show_perf_detail:
			# ★ 每帧采样 `_process` 耗时，攒 0.5 秒再算平均/峰值 —— 「浮动很大」要看这两个数。
			var cpu_sec: float = Performance.get_monitor(Performance.TIME_PROCESS)
			_perf_cpu_sum += cpu_sec
			_perf_cpu_max = maxf(_perf_cpu_max, cpu_sec)
			_perf_dt_sum += dt
			_perf_fr_min = minf(_perf_fr_min, dt)
			_perf_fr_max = maxf(_perf_fr_max, dt)
			_perf_cpu_n += 1
		if _perf_accum >= 0.5:
			_perf_accum = 0.0
			_update_perf_readout()
			# ★ 分段计时只在「完整读数」那一档才清：默认档根本没开过 profile_on
			if cfg != null and cfg.show_perf_detail:
				_reset_profiles()
			_perf_cpu_sum = 0.0
			_perf_cpu_max = 0.0
			_perf_dt_sum = 0.0
			_perf_fr_min = INF
			_perf_fr_max = 0.0
			_perf_hud_sum = 0.0
			_perf_shell_sum = 0.0
			_perf_detail_sum = 0.0
			_perf_squad_sum = 0.0
			_perf_cpu_n = 0


## ★★ 手机端性能读数（默认**只有 FPS**，左上角）。
##
## 口径（本轮用户要求）：「把顶上显示性能的信息去掉了，只需要保留 FPS 即可，
##   且把 FPS 显示移动到最左上」。
##   · 默认（`ui.show_perf_detail = false`）＝ 左上一行 `FPS 60`；
##     不打开 `world.profile_on`、也不打开场景层的 `perf_enable` —— 那些是真机排查
##     才付的开销，日常玩不该有。
##   · 把 `ui.show_perf_detail` 改 true ⇒ 回到原来那块 4 行完整读数
##     （帧时间 / CPU / draw call / 逻辑与场景分段），排查时照旧能用。
## ⚠️ 只在手机显示（`OS.has_feature("mobile")`）且 `ui.show_perf` 为真；
##    桌面 / 无头 / 测试都不会创建它（不改变任何现有几何与断言）。
func _build_perf_readout() -> void:
	if cfg == null or not cfg.show_perf:
		return
	if not OS.has_feature("mobile"):
		return
	_perf_label = Label.new()
	_perf_label.name = "PerfReadout"
	_perf_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★★ 贴**最左上角**（本轮口径）。部队列表已经移到右侧，这里不会压住将领行；
	#   目标栏可见时 `_refresh_shell()` 会把读数挪到目标栏下方。描边保证压在地图亮色上也读得出。
	_perf_label.position = Vector2(6.0, 2.0)
	# ★ 完整读数要 4 行（`show_perf_detail = true` 时）；只显示 FPS 时这两行字装得下。
	_perf_label.size = Vector2(1240.0, 84.0) if cfg.show_perf_detail else Vector2(320.0, 34.0)
	_perf_label.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
	_perf_label.add_theme_color_override("font_color", UiStyleRes.text())
	_perf_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	_perf_label.add_theme_constant_override("outline_size", 3)
	_root.add_child(_perf_label)
	# ★★ 打开分段计时（逻辑层与场景层各有一套 `profile_us`）——只有「完整读数」才需要；
	#   手机上本来才开，桌面/无头永远不付这个开销。
	if cfg.show_perf_detail:
		if world != null:
			world.profile_on = true
		var gs := get_parent()
		if gs != null and gs.has_method("perf_enable"):
			gs.perf_enable()
	_update_perf_readout()


## 把两套分段计时（逻辑 `world.profile_us` + 场景 `game.profile_us`）清零，准备下一个 0.5 秒窗口。
func _reset_profiles() -> void:
	if world != null:
		world.profile_reset()
	var gs := get_parent()
	if gs != null and gs.has_method("profile_reset"):
		gs.profile_reset()


## 三行读数（真机排查用）：
##   `FPS 25 · mobile · release · C# · 66u · map 27x22`
##   `2560x1080 · CPU 45.0/48.0ms · DC 150`
##   `tk 30.0 (u 20.0 fg 6.0 z 2.0) | vu 0.8 vb 0.2 | rest 12.0`
##
## ★ 怎么读：
##   · 第 2 行 CPU 平均 ≈ `1000/FPS` ⇒ **CPU 卡**；CPU 很小而 FPS 低 ⇒ **渲染 / GPU 卡**；
##     平均小、峰值大 ⇒ 周期性尖峰。
##   · 第 3 行把 CPU 拆开（全部是 **ms/帧**）：`tk` = `world.tick` 总耗时；
##     括号里是它的子项：`u` 单位循环 / `fg` 迷雾 / `z` 区划；
##     `vu` / `vb` = 单位 / 建筑视图同步；`rest` = CPU 减去场景各段后剩下的部分
##     （HUD、部队列表、小地图、按钮动效都在这一栏）。**哪项接近 CPU 总量，就是它在吃时间。**
func _update_perf_readout() -> void:
	if _perf_label == null:
		return
	# ★★ 默认档（本轮口径）：**只显示 FPS**，一行、左上角。
	#   完整那 4 行（帧时间 / CPU / DC / 分段）要靠 `ui.show_perf_detail = true` 才出现；
	#   那一档同时会打开 `world.profile_on` / 场景层 profiling（见 `_build_perf_readout`）。
	if cfg == null or not cfg.show_perf_detail:
		_perf_label.text = "FPS %d" % int(Engine.get_frames_per_second())
		_perf_label.add_theme_color_override("font_color", UiStyleRes.text())
		return
	if world == null:
		return
	# ★★ 这一栏只说**群编内核**（碰撞 / 索敌 / 距离场）用的是哪种实现，
	#   不代表整个工程的语言 —— 工程主体是 GDScript（logic/ + view/），
	#   C# 只有 logic/crowd/ 那两个文件。写成 `crowd C#` 免得被误读成「项目是 C#」。
	var kernel := "crowd C#"
	var bad := false
	if world.crowd != null and not world.crowd.available():
		kernel = "crowd GD(O(N^2))"
		bad = true
	# 配置里的渲染方式（本工程主设置 = mobile）。
	var method := String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	if method != "mobile":
		bad = true
	var n: float = float(maxi(1, _perf_cpu_n))
	var cpu_avg: float = (_perf_cpu_sum / n) * 1000.0
	var cpu_max: float = _perf_cpu_max * 1000.0
	# ★★ 真实帧间隔（含 vsync 等待）。它才是「玩家感受到的每帧毫秒数」。
	var frame_ms: float = (_perf_dt_sum / n) * 1000.0
	var dc: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var win: Vector2i = DisplayServer.window_get_size()
	# 屏幕刷新率（拿不到就是 0）。判 vsync 卡档时看它：90Hz → 45/30，120Hz → 60/40。
	var hz: float = DisplayServer.screen_get_refresh_rate()
	var vs := "on" if cfg != null and cfg.mobile_vsync else "off"
	var build := "debug" if OS.is_debug_build() else "release"
	var cols: int = 0
	var rows: int = 0
	if world.map != null:
		cols = int(world.map.cols)
		rows = int(world.map.rows)
	# 逻辑层（`world.tick` 内部的分段）
	var lp: Dictionary = world.profile_us
	var ms_u: float = float(lp.get("units", 0)) / 1000.0 / n
	var ms_fog: float = float(lp.get("fog", 0)) / 1000.0 / n
	var ms_z: float = float(lp.get("zones", 0)) / 1000.0 / n
	# 场景层（`game_scene3d._process` 的分段；HUD 的父节点就是它）
	var sp: Dictionary = {}
	var gs := get_parent()
	if gs != null and gs.has_method("profile_snapshot"):
		sp = gs.profile_snapshot()
	var ms_in: float = float(sp.get("input", 0)) / 1000.0 / n
	var ms_tick: float = float(sp.get("tick", 0)) / 1000.0 / n
	var ms_vu: float = float(sp.get("view/units", 0)) / 1000.0 / n
	var ms_vb: float = float(sp.get("view/buildings", 0)) / 1000.0 / n
	var ms_vo: float = float(sp.get("view/other", 0)) / 1000.0 / n
	var ms_ov: float = float(sp.get("view/overlay", 0)) / 1000.0 / n
	var ms_gb: float = float(sp.get("ground.rebake", 0)) / 1000.0 / n
	var ms_cam: float = float(sp.get("camera", 0)) / 1000.0 / n
	# ★★ `tk` 之外还有这些（都在 world.tick 里，但不在上面那三个子项里）
	var ms_ec: float = float(lp.get("economy", 0)) / 1000.0 / n
	var ms_rc: float = float(lp.get("recruit", 0)) / 1000.0 / n
	var ms_tw: float = float(lp.get("towers", 0)) / 1000.0 / n
	var ms_ai: float = float(lp.get("ai", 0)) / 1000.0 / n
	var ms_col: float = float(lp.get("collision", 0)) / 1000.0 / n
	var ms_co: float = float(lp.get("collect", 0)) / 1000.0 / n
	var ms_ob: float = float(lp.get("objective", 0)) / 1000.0 / n
	# ★★ HUD 刷新与两个自绘层的**实际 `_draw` 时间**（它们不在 `_process` 的分段里，
	#    正是 `rest` 的主要候选）。`draw/*` 是 overlay / minimap 在 `_draw` 里自己累加的。
	var ms_hud: float = _perf_hud_sum / 1000.0 / n
	var ms_hs: float = _perf_shell_sum / 1000.0 / n
	var ms_hd: float = _perf_detail_sum / 1000.0 / n
	var ms_sq: float = _perf_squad_sum / 1000.0 / n
	var ms_dov: float = float(lp.get("draw/overlay", 0)) / 1000.0 / n
	var ms_dmm: float = float(lp.get("draw/minimap", 0)) / 1000.0 / n
	var scene_total: float = ms_in + ms_tick + ms_vu + ms_vb + ms_vo + ms_ov + ms_gb + ms_cam
	# ★★ `rest` 必须按**真实帧间隔**算，不能按 `proc`：
	#    `Performance.TIME_PROCESS` 在手机上会包含 vsync 等待，实测 `proc 45ms / fr 24.4ms`，
	#    拿它减分段会得出一笔根本不存在的 30ms。用 `fr` 才是「这一帧还剩多少没被分段覆盖」。
	# ★ 再把 hud / 两个自绘层的 `_draw` 也扣掉 —— 剩下的才是**引擎 / GPU / 其它 UI**。
	var rest: float = maxf(0.0, frame_ms - scene_total - ms_hud - ms_dov - ms_dmm)
	# 刚建好还没采过样时 `_perf_fr_min` 是 INF —— 别把 "inf" 打到屏幕上
	var fr_min_ms: float = _perf_fr_min * 1000.0 if _perf_fr_min != INF else 0.0
	var fr_max_ms: float = _perf_fr_max * 1000.0
	_perf_label.text = (
		"FPS %d · %s · %s · %s · %du · map %dx%d\n" +
		"%dx%d · %dHz · vs %s · fr %.1f (%.1f~%.1f)ms · proc %.1f/%.1fms · DC %d\n" +
		"tk %.1f (u %.1f fg %.1f z %.1f) | vu %.1f vb %.1f | rest %.1f\n" +
		"ec %.1f rc %.1f tw %.1f ai %.1f | col %.1f co %.1f ob %.1f | hs %.1f hd %.1f sq %.1f dov %.1f dmm %.1f | cm %.1f rb %.1f") % [
		int(Engine.get_frames_per_second()), method, build, kernel, world.units.size(), cols, rows,
		win.x, win.y, int(round(hz)), vs, frame_ms, fr_min_ms, fr_max_ms,
		cpu_avg, cpu_max, dc,
		ms_tick, ms_u, ms_fog, ms_z, ms_vu, ms_vb, rest,
		ms_ec, ms_rc, ms_tw, ms_ai, ms_col, ms_co, ms_ob,
		ms_hs, ms_hd, ms_sq, ms_dov, ms_dmm, ms_cam, ms_gb]
	_perf_label.add_theme_color_override("font_color",
		UiStyleRes.warn() if bad else UiStyleRes.text())


# ------------------------------------------------------------------
# 搭界面
# ------------------------------------------------------------------

## 右上角 238×148 的「地图」= 真的小地图（view/minimap.gd）：
## 整张地图 + 玩家当前的视野框 + 左键点击移动镜头 + **按住拖动跟手移视角**。
##
## ★★ 2026.11.14：地图从**左下角**搬到**右上角**（用户口径：「将地图面板放到屏幕
##   右上角」）。于是贴边锚点也反了：原来是「贴左 + 贴下」，现在是「贴右 + 贴上」。
##   ⚠️ `apply_rect` 的后两个参数就是 anchor_right / anchor_bottom —— 写错一个，
##     窗口一变宽 / 变高地图就会跑到屏幕外（而且 16:9 时不报错，只有非 16:9 才看出来）。
##
## ★ 结构是「有底的容器 + 自绘控件」两层：
##   外层的 PanelContainer 只提供与其它面板一致的底板 / 描边，内层的 minimap 控件
##   负责全部绘制与点击。
##   ⚠️ **外层必须是 IGNORE**：Godot 的鼠标事件从父到子传递，父控件只要是 STOP，
##      子控件的 `_gui_input` 永远收不到事件 —— 表现就是「小地图画得好好的，但点它没反应」。
##      容器不需要吃事件（它什么都不做），所以这里直接放行。
##   ⚠️ 内层用 PRESET_FULL_RECT：容器的 content margin 会让它比外层小 8px（主题给的），
##      所以不写任何坐标，让它自己跟着缩。
func _build_minimap() -> void:
	map_placeholder = PanelContainer.new()
	map_placeholder.name = "MapPlaceholder"
	map_placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var map_frame := UiStyleRes.panel_style(UiStyleRes.bg_soft(), UiStyleRes.line())
	map_frame.set_corner_radius_all(4)
	map_frame.shadow_color = Color(0.0, 0.0, 0.0, 0.76)
	map_frame.shadow_size = 7
	map_frame.shadow_offset = Vector2(0.0, 5.0)
	map_placeholder.add_theme_stylebox_override("panel", map_frame)
	UiLayoutRes.apply_rect(map_placeholder, UiLayoutRes.MAP_RECT, true, false)
	_root.add_child(map_placeholder)

	minimap = MinimapRes.new()
	minimap.name = "Minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_placeholder.add_child(minimap)
	minimap.setup(cfg, world, camera_rig, palette)


## 资源面板：**一张大卡**，卡内两块（粮食 / 黄金）各自**竖排**四行。
##
## ★★ 2026.11.14 第三轮（用户口径）：「将资源面板改为竖直排列，竖直方向为：
##   图标，文本，数字，增长数字」+「合并成一张大卡，中间分隔」。
##
##   卡片 194×274（`UiLayoutRes.RES_BAR_RECT`，贴列左缘 1394、上缘 27），
##   上半 0..137 = 粮食、下半 137..274 = 黄金，中间一条 1px 分隔线；
##   每一块内部从上到下：
##     圆章图标 45×45（金边圆章 + 一个汉字：粮 / 金）
##     文本     13 号「粮食 / 黄金」（暗白，说明这是哪一种资源）
##     数字     26 号（库存，卡里最显眼的一行）
##     增长     13 号「(+1.2)」（每秒净额，负数是告警色）
##   四行**水平居中**：这一列只有 194 宽，居中最稳（旧版是「圆章在左、文字在右」的
##   横排，竖排之后视觉重量才落在这张卡的轴线上）。
##
## ★ 数值**每帧**从 `world.resources` 取（见 `_refresh_resource_bar`）：
##   它是权威值（economy.tick 往里累加、招募 / 升级从里扣），界面只在显示层格式化。
## ★ `mouse_filter = IGNORE`：整块只有字和色块，点不动也不需要拦鼠标
##   （边缘滚屏照样能在它上面工作，见 ui_layout.interactive_rects 的规矩）。
## ★ 节点的**名字不能改**（`ResText_粮` / `ResRate_粮` / `ResTitle_*` / `ResIcon_*`）：
##   `_refresh_resource_bar()` 按名字取控件，测试也按名字找。
func _build_resource_bar() -> void:
	# ★ 重新建控件 ⇒ 上一份「写进去的文字」作废（否则新 Label 会因为
	#   「文字没变」而一直空着 —— 重开一局 / 重建 HUD 时会踩到）。
	_res_last_text.clear()
	resource_bar = Panel.new()
	resource_bar.name = "ResourceBar"
	resource_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# ★★ 大卡自己就是底纹（不再有「每块一张筹码」的中间层）：
	#   圆角 12 + 2px 暗金边 + 下投影，与其它面板同一套。
	var card := StyleBoxFlat.new()
	card.bg_color = UiStyleRes.bg()
	card.border_color = UiStyleRes.line()
	card.set_border_width_all(2)
	card.set_corner_radius_all(12)
	card.shadow_color = Color(0.0, 0.0, 0.0, 0.72)
	card.shadow_size = 6
	card.shadow_offset = Vector2(0.0, 5.0)
	resource_bar.add_theme_stylebox_override("panel", card)
	# ★ 贴右上 ⇒ anchor_right + anchor_top。
	UiLayoutRes.apply_rect(resource_bar, UiLayoutRes.RES_BAR_RECT, true, false)
	_root.add_child(resource_bar)

	var w: float = UiLayoutRes.TOP_COLUMN_W
	var icon: float = UiLayoutRes.RES_ICON
	var icon_x: float = (w - icon) * 0.5
	# 两块：粮食在上、黄金在下（下半块整体下移 RES_HALF_H）
	var rows := [
		{"short": "粮", "label": "粮食", "color": Color(0.85, 0.72, 0.32), "y": 0.0},
		{"short": "金", "label": "黄金", "color": Color(0.95, 0.80, 0.20), "y": UiLayoutRes.RES_HALF_H},
	]
	for r in rows:
		var y0: float = float(r["y"])
		# ① 圆章图标（45×45 金边正圆 + 一个汉字）
		var chip := Label.new()
		chip.name = "ResIcon_" + String(r["short"])
		chip.text = String(r["short"])
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		chip.clip_text = true
		chip.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		chip.add_theme_color_override("font_color", Color(0.10, 0.09, 0.06))
		var cs := StyleBoxFlat.new()
		cs.bg_color = r["color"]
		cs.border_color = UiStyleRes.accent_bright()
		cs.set_border_width_all(2)
		cs.set_corner_radius_all(24)
		chip.add_theme_stylebox_override("normal", cs)
		resource_bar.add_child(chip)
		# ⚠️ 位置 / 尺寸都在 `add_child` **之后**设（进树之前主题里的中文字体还没继承到，
		#    Label 会按引擎兜底字体算一次最小高度并**把 set_size 的结果夹掉**）。
		chip.position = Vector2(icon_x, y0 + UiLayoutRes.RES_ICON_Y)
		chip.size = Vector2(icon, icon)

		# ② 文本（「粮食 / 黄金」）
		var title := Label.new()
		title.name = "ResTitle_" + String(r["short"])
		title.text = String(r["label"])
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		title.clip_text = true
		title.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		title.add_theme_color_override("font_color", UiStyleRes.text_dim())
		resource_bar.add_child(title)
		title.position = Vector2(0.0, y0 + UiLayoutRes.RES_TITLE_Y)
		title.size = Vector2(w, 18.0)

		# ③ 数字（库存）—— 卡里最显眼的一行
		var value := Label.new()
		value.name = "ResText_" + String(r["short"])
		value.mouse_filter = Control.MOUSE_FILTER_IGNORE
		value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		value.clip_text = true
		value.add_theme_font_size_override("font_size", 26)
		value.add_theme_color_override("font_color", UiStyleRes.text())
		resource_bar.add_child(value)
		value.position = Vector2(0.0, y0 + UiLayoutRes.RES_VALUE_Y)
		value.size = Vector2(w, 32.0)

		# ④ 增长数字（每秒净额）
		var rate := Label.new()
		rate.name = "ResRate_" + String(r["short"])
		rate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rate.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		rate.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		rate.clip_text = true
		rate.add_theme_font_size_override("font_size", UiStyleRes.FS_SMALL)
		rate.add_theme_color_override("font_color", UiStyleRes.hp_high())
		resource_bar.add_child(rate)
		rate.position = Vector2(0.0, y0 + UiLayoutRes.RES_RATE_Y)
		rate.size = Vector2(w, 16.0)

	# ⑤ 中间那条分隔线（两块之间；两端各缩进 RES_PAD_X，不顶到圆角上）
	var divider := ColorRect.new()
	divider.name = "ResDivider"
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lc: Color = UiStyleRes.line()
	divider.color = Color(lc.r, lc.g, lc.b, 0.55)
	resource_bar.add_child(divider)
	divider.position = Vector2(UiLayoutRes.RES_PAD_X, UiLayoutRes.RES_DIVIDER_Y)
	divider.size = Vector2(UiLayoutRes.TOP_COLUMN_W - UiLayoutRes.RES_PAD_X * 2.0, 1.0)

	_refresh_resource_bar()


## ★★ 左上角目标栏（战役 / 合作；M12.1，2026.10.20 改为两行）。
## 它自己读 `world.objective_state`，HUD 只负责建一次 + 每帧 `sync()`。
func _build_objective_panel() -> void:
	objective_panel = ObjectivePanelRes.new()
	# ⚠️ 先 add_child、再 setup：与资源条 / 选项页同一条坑（进树前拿不到主题字体）。
	_root.add_child(objective_panel)
	objective_panel.setup(cfg, world, _font)


## ★★ 左下角小地图正上方的播报横幅（大本营升级）。建一次，之后 `show_broadcast()` 往里塞。
func _build_broadcast_banner() -> void:
	# 模态盾先建（z 低于通知栈）：只在对话 / 锁 UI 时显示。
	story_shield = Control.new()
	story_shield.name = "StoryShield"
	story_shield.set_anchors_preset(Control.PRESET_FULL_RECT)
	story_shield.mouse_filter = Control.MOUSE_FILTER_STOP
	story_shield.z_index = 300
	story_shield.visible = false
	_root.add_child(story_shield)

	broadcast_banner = BroadcastBannerRes.new()
	# ★ 通知栈必须压在盾之上（否则对话自己也被挡住）。
	broadcast_banner.z_index = 310
	_root.add_child(broadcast_banner)
	broadcast_banner.setup(cfg, _font)
	if broadcast_banner.has_signal("dialogue_started"):
		broadcast_banner.dialogue_started.connect(_on_dialogue_started)
	if broadcast_banner.has_signal("dialogue_finished"):
		broadcast_banner.dialogue_finished.connect(_on_dialogue_finished)
	if broadcast_banner.has_signal("skip_requested"):
		broadcast_banner.skip_requested.connect(_on_dialogue_skip_requested)


func _on_dialogue_started(_id: int) -> void:
	set_story_shield(true)


func _on_dialogue_finished(id: int) -> void:
	set_story_shield(false)
	dialogue_finished.emit(id)


## 点击对话框 → 请演出跳过这一波对话；没有宿主接时退回「一步快速通过」。
func _on_dialogue_skip_requested(id: int) -> void:
	if dialogue_skip_requested.get_connections().is_empty():
		fast_forward_dialogue()
		return
	dialogue_skip_requested.emit(id)


## 演出模态盾（对话 / 锁 UI）。盾本身只挡 GUI；细粒度动作锁在 input_controller。
func set_story_shield(on: bool) -> void:
	if story_shield != null:
		story_shield.visible = bool(on)


## 压一条对话；返回对话 id（导演用它等 `dialogue_finished`）。
func show_dialogue(text: String, opts: Dictionary = {}) -> int:
	if broadcast_banner == null:
		return -1
	return broadcast_banner.push_dialogue(text, opts)


func advance_dialogue() -> bool:
	return broadcast_banner != null and broadcast_banner.advance_dialogue()


## ★ 点击 / 触摸：一步快速通过当前对话（补全打字 + 立即退场）。
func fast_forward_dialogue() -> bool:
	return broadcast_banner != null and broadcast_banner.fast_forward_dialogue()


## 请求跳过对话（有演出时由 `game_scene3d` 跳过这一波；没有则退回一步快速通过）。
func skip_dialogue() -> bool:
	return broadcast_banner != null and broadcast_banner.request_skip_dialogue()


func clear_dialogue() -> void:
	if broadcast_banner != null:
		broadcast_banner.clear_dialogue()
	set_story_shield(false)


func has_dialogue() -> bool:
	return broadcast_banner != null and broadcast_banner.has_dialogue()


func dialogue_typing() -> bool:
	return broadcast_banner != null and broadcast_banner.dialogue_typing()


## ★★ 给资源时的可见反馈：资源条旁边上浮数字 + 左下通知栈一条播报。
func show_resource_gain(food: float, gold: float) -> void:
	var parts: Array = []
	if food > 0.0:
		parts.append("粮食 +%d" % int(round(food)))
	if gold > 0.0:
		parts.append("黄金 +%d" % int(round(gold)))
	if parts.is_empty():
		return
	var text := "获得 " + "　".join(parts)
	if broadcast_banner != null:
		broadcast_banner.push(text, UiStyleRes.accent())
	_spawn_resource_floats(food, gold)


func _spawn_resource_floats(food: float, gold: float) -> void:
	if resource_bar == null:
		return
	var font_size := 18
	var sec := 1.2
	var rise := 36.0
	if cfg != null:
		font_size = maxi(8, int(cfg.num("story.resource_float.font_size", 18.0)))
		sec = maxf(0.05, cfg.num("story.resource_float.sec", 1.2))
		rise = maxf(0.0, cfg.num("story.resource_float.rise_px", 36.0))
	var rows: Array = []
	if food > 0.0:
		rows.append("+%d 粮" % int(round(food)))
	if gold > 0.0:
		rows.append("+%d 金" % int(round(gold)))
	for i in rows.size():
		var label := Label.new()
		label.name = "ResGainFloat"
		label.text = String(rows[i])
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", font_size)
		label.add_theme_color_override("font_color", UiStyleRes.accent())
		label.z_index = 60
		_root.add_child(label)
		label.size = Vector2(160.0, float(font_size) + 8.0)
		var base := resource_bar.position
		label.position = Vector2(
			base.x + resource_bar.size.x - label.size.x,
			base.y - label.size.y - 4.0 - float(i) * (float(font_size) + 4.0))
		_resource_floats.append({
			"label": label,
			"y0": label.position.y,
			"age": 0.0,
			"sec": sec,
			"rise": rise,
		})


func _tick_resource_floats(dt: float) -> void:
	if _resource_floats.is_empty():
		return
	var keep: Array = []
	for it in _resource_floats:
		var d: Dictionary = it
		var age := float(d.get("age", 0.0)) + maxf(0.0, dt)
		d["age"] = age
		var sec := maxf(0.05, float(d.get("sec", 1.2)))
		var q := clampf(age / sec, 0.0, 1.0)
		var label: Label = d.get("label", null)
		if label != null and is_instance_valid(label):
			label.position = Vector2(label.position.x,
				float(d.get("y0", 0.0)) - float(d.get("rise", 36.0)) * q)
			label.modulate = Color(1.0, 1.0, 1.0, 1.0 - q)
		if q >= 1.0:
			if label != null and is_instance_valid(label):
				label.queue_free()
		else:
			keep.append(d)
	_resource_floats = keep


## 测试 / 诊断：当前还在显示的资源飘字条数。
func resource_float_count() -> int:
	return _resource_floats.size()


## 播一条「某阵营大本营升级完成」。
##
## ★ 由 `view/game_interaction.gd` 在收到 `upgrade_done` 时调用（**不过**「是不是我的事件」
##   那道筛选 —— 这是一条要给所有人看的播报）。
## ★ 文案里的席位用**阵营 id 原样**（p1 / p2 / F1 …），不用 `faction_label_of`
##   的显示名 —— 用户口径：「px(x为玩家席位)大本营已升至n级」。
## ★ 颜色用**本机视角**的三色档（自己蓝 / 友军黄 / 敌人红，见 view/side_color.gd）。
func show_broadcast(faction: String, target_level: int) -> void:
	if broadcast_banner == null:
		return
	var color: Color = SideColorRes.color(cfg, world, faction)
	broadcast_banner.push(broadcast_banner.format_text(faction, target_level), color)


func _tick_broadcast(dt: float) -> void:
	if broadcast_banner != null:
		broadcast_banner.tick(dt)


## 资源条上的两个数字：**每帧**从权威值（`world.resources`）重新格式化。
## ★ 取整显示（与命令卡的消耗文案同一口径，见 `_cost_text`）：
##   资源是浮点累加的，直接印会看到「119.99999」。
## ★ `world` 为 null 时按 0 显示 —— 界面不该因为逻辑层还没准备好就报错。
func _refresh_resource_bar() -> void:
	if resource_bar == null:
		return
	var res: Dictionary = {}
	if world != null:
		res = world.resources
	var pairs := [
		{"short": "粮", "key": "food", "label": "粮食"},
		{"short": "金", "key": "gold", "label": "黄金"},
	]
	# ★★ 净额只问一次（`net_per_sec` 会拼两份小字典；放进循环里就白算一遍）
	var net_rates: Dictionary = world.net_per_sec() if world != null else {}
	for p in pairs:
		var l := resource_bar.get_node_or_null("ResText_" + String(p["short"])) as Label
		var rate_label := resource_bar.get_node_or_null("ResRate_" + String(p["short"])) as Label
		if l == null or rate_label == null:
			continue
		var key := String(p["key"])
		# ★★ 2026.10.29：资源条 = **数值 + 每秒净增长**（产能 − 维护费 − 科技金耗）。
		#   净额由 world 统计（`net_per_sec`），界面只负责写出来 —— 扣费口径只有一处。
		var net := float(net_rates.get(key, 0.0))
		var amount_text := "%d" % int(round(float(res.get(key, 0.0))))
		var rate_text := _rate_text(net)
		var text := amount_text + "|" + rate_text
		# ★ 只在文字真的变了时才写控件 + 换颜色：`add_theme_color_override` 每帧调是白花钱，
		#   而显示到 0.1 的净额一秒里也变不了几次。
		if String(_res_last_text.get(key, "")) == text:
			continue
		_res_last_text[key] = text
		l.text = amount_text
		rate_label.text = rate_text
		# 净额是负的 ⇒ 用告警色（断粮 / 科技烧钱时玩家一眼能看见）。
		var negative := net < -0.05
		l.add_theme_color_override("font_color", UiStyleRes.warn() if negative else UiStyleRes.text())
		rate_label.add_theme_color_override("font_color",
			UiStyleRes.warn() if negative else UiStyleRes.hp_high())


## ★★ 资源条上那个 `(+n)` 的写法：**一律带正负号**、1 位小数。
##   ★ 0 附近（|n| < 0.05）一律写成 `(+0.0)` —— 否则 `-0.0` 会被印成 `(+-0.0)`
##     （浮点里 `-0.0 >= 0.0` 为真，但 `%.1f` 会印出负号，看着像 bug）。
static func _rate_text(rate: float) -> String:
	var v: float = 0.0 if absf(rate) < 0.05 else rate
	return "(%s%.1f)" % ["+" if v >= 0.0 else "", v]


func _build_detail_panel() -> void:
	detail_panel = DetailPanelRes.new()
	_root.add_child(detail_panel)
	# ★ 字体要传进去：详细信息左栏的「部队方块 / 将领头像网格」自己 draw_string，
	#   而 Godot 默认字体没有中文字形（不传就是满屏方框）。
	detail_panel.setup(world, _font)
	detail_panel.queue_cell_activated.connect(_on_queue_cell_activated)
	detail_panel.troop_activated.connect(_on_troop_activated)
	detail_panel.unit_activated.connect(_on_grid_unit_activated)
	detail_panel.building_activated.connect(_on_grid_building_activated)
	# ★★ 旧面板只作为测试/兼容数据源保留（全透明、不吃输入）；屏幕上是 detail_v2。
	#    保持 visible=true 是为了旧测试的 _draw / 几何断言仍然成立。
	detail_panel.modulate = Color(1, 1, 1, 0)
	detail_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ignore_controls(detail_panel)
	detail_v2 = DetailV2Res.new()
	_root.add_child(detail_v2)
	detail_v2.setup(world, _font)
	_detail_home_position = detail_v2.position
	detail_v2.unit_selected.connect(_on_detail_v2_unit_selected)
	detail_v2.entry_selected.connect(_on_detail_v2_entry_selected)


## 把旧详情面板整棵子树设成不吃输入（它只给旧测试/兼容接口读状态）。
func _ignore_controls(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_controls(c)


func _build_command_card() -> void:
	command_card = CommandCardRes.new()
	_root.add_child(command_card)
	command_card.setup()
	command_card.entry_activated.connect(_on_card_entry)
	command_card.card_drag_started.connect(_on_card_drag_started)
	command_card.card_drag_moved.connect(_on_card_drag_moved)
	command_card.card_drag_finished.connect(_on_card_drag_finished)
	# ★ 科技九格**后加**（在命令卡之上）：两套内容在屏幕上完全重合，
	#   只有「科技」页时科技那一层才显示（见 _rebuild_card 末尾的 set_visible_page）。
	tech_grid = TechGridRes.new()
	_root.add_child(tech_grid)
	tech_grid.setup()
	tech_grid.cell_activated.connect(_on_tech_cell_activated)
	# ★★ 2026.11.19：科技牌拖起来时，牌旁边的悬停说明也要立刻收起（与手牌同一条）。
	tech_grid.cell_drag_started.connect(_on_tech_card_drag_started)
	tech_grid.cell_drag_finished.connect(_on_tech_drag_finished)


func _on_card_drag_started(entry: Dictionary, screen_pos: Vector2) -> void:
	# ★★ 2026.11.19（用户口径）：「卡牌拖出时悬停面板应该消失」——
	#   拖牌那一刻牌已经离开手牌位，旁边的说明再挂着就是在讲一张不存在的牌。
	_dismiss_hover()
	var kind := String(entry.get("type", ""))
	if kind == "base_upgrade":
		_begin_base_upgrade_drag(screen_pos)
		return
	if kind == "build":
		_begin_build_drag(entry, screen_pos)
		return
	# ★★ 2026.11.19（用户口径）：单位牌拖出 → 任意己方将军都是落点；
	#   如果当前已选中部队，镜头**立刻一次性**聚焦到主选中部队。
	if kind == "recruit":
		_begin_recruit_drag(entry, screen_pos)
		_focus_selected_troops_once()
		return
	# ★★ 2026.11.15 第二轮：将领牌拖出 → 己方区划中心成为落点（圈内松手 = 招募）。
	if (kind == "general_drag" or kind == "zone_recruit") \
			and bool(entry.get("ready", false)):
		_begin_recruit_drag(entry, screen_pos)


func _on_card_drag_moved(entry: Dictionary, screen_pos: Vector2) -> void:
	if drag_build_active and (String(entry.get("type", "")) == "base_upgrade" \
			or String(entry.get("build_type", "")) == drag_build_type):
		_update_build_drag_preview(screen_pos)
		return
	if drag_recruit_active:
		_update_recruit_drag_preview(screen_pos)


func _on_card_drag_finished(entry: Dictionary, screen_pos: Vector2, index: int) -> void:
	var kind := String(entry.get("type", ""))
	if (kind == "build" or kind == "base_upgrade") and drag_build_active:
		_update_build_drag_preview(screen_pos)
		var built: bool = _commit_card_build_drag()
		_clear_card_build_drag()
		if built:
			# ★ 生效：牌向上淡出并缩小消失；**只把这**张牌淡回槽位，不重排整手牌。
			# ★★ 2026.11.19：大本营升到满级后这张牌已被移除 —— 不要拿它的下标去动画
			#   下一张牌（否则塔牌会从大本营的位置飞出来）。
			var still_same: bool = index >= 0 and index < command_card.entries().size() \
				and String(command_card.entry_at(index).get("type", "")) == kind
			if still_same:
				command_card.play_drag_success(index, screen_pos, true)
		else:
			# ★ 拒绝 / 取消：牌飞回手牌栏；只有**真的丢在地图上但建不了**才闪红
			#   （拖回手牌 = 取消，不该像出错）。
			command_card.animate_card_back(index)
			if _drag_build_left_hand and not point_hits_ui(screen_pos):
				flash_reject()
		return
	if (kind == "general_drag" or kind == "zone_recruit") and drag_recruit_active:
		_update_recruit_drag_preview(screen_pos)
		var ui_release := point_hits_ui(screen_pos)
		var recruited: bool = _commit_recruit_drag()
		_clear_card_recruit_drag()
		if recruited:
			# ★★ 2026.11.16（用户口径）：生效后只收这一张，不刷新整页手牌。
			command_card.play_drag_success(index, screen_pos, true)
		else:
			command_card.animate_card_back(index)
			if not ui_release:
				flash_reject()
		return
	if kind == "recruit":
		# ★★ 2026.11.15 修 bug：**在 UI 上松手（拖回手牌 / 页签 / 面板）= 取消**。
		#   旧版不看松手位置，拖回手牌也照样发招募命令 —— 玩家看到的是「牌收回来了，
		#   兵却招出来了」。判据与建造 / 操作牌同一条：`point_hits_ui()`。
		if point_hits_ui(screen_pos):
			if drag_recruit_active:
				_clear_card_recruit_drag()
			command_card.animate_card_back(index)
			return
		# ★★ 2026.11.19：单位页的牌拖到己方将军圈内 = 招到那位将军名下。
		if drag_recruit_active and drag_recruit_unit_mode:
			_update_recruit_drag_preview(screen_pos)
			var recruited_unit: bool = _commit_recruit_drag()
			_clear_card_recruit_drag()
			if recruited_unit:
				command_card.play_drag_success(index, screen_pos, true)
			else:
				command_card.animate_card_back(index)
				flash_reject()
			return
		var played_kind := String(entry.get("unit_kind", ""))
		_recruit_play_context = {"kind": played_kind, "screen_pos": screen_pos}
		if _on_card_entry(entry):
			_refresh_card_if_changed()
			if not _recruit_play_context.is_empty():
				# ★★ 2026.11.16（用户口径）：生效后只收这一张，不刷新整页手牌。
				command_card.play_drag_success(index, screen_pos, true)
			_recruit_play_context.clear()
			return
		_recruit_play_context.clear()
		command_card.animate_card_back(index)
		flash_reject()
		return
	# ★★ 2026.11.19（用户口径）：「拆除」牌**拖到地图上松手**才拆。
	#   · 松回任意 UI 上 = 取消（与其它牌同一条判据，不会误拆）；
	#   · 拖出 UI 松手 = 对**当前主选中建筑**发拆除命令；
	#   · 成功 = 新卡从屏幕下方升回手牌位；失败 = 飞回原槽位 + 红闪。
	if kind == "building_demolish":
		if point_hits_ui(screen_pos):
			command_card.animate_card_back(index)
			return
		if _on_building_action(entry):
			command_card.play_drag_success(index, screen_pos, true)
		else:
			command_card.animate_card_back(index)
			flash_reject()
		return
	# 其它牌（理论上没有拖拽语义）：在 UI 上松手一律当取消，不做任何动作 ——
	# 免得「拖回手牌」被当成一次点击（与单位牌那个 bug 同源）。
	if point_hits_ui(screen_pos):
		command_card.animate_card_back(index)
		return
	# ★★ 2026.11.19（用户口径）：成功使用 → 新卡从屏幕下方升回手牌位；
	#   失败 / 被拒 → 旧卡飞回槽位（线性缩回原尺寸）。
	if _on_card_entry(entry):
		command_card.play_drag_success(index, screen_pos, true)
	else:
		command_card.animate_card_back(index)


## 科技牌拖起来：牌旁边的悬停说明立刻收起（与手牌同一条，见 `_on_card_drag_started`）。
func _on_tech_card_drag_started(_id: String, _screen_pos: Vector2) -> void:
	_dismiss_hover()


func _on_tech_drag_finished(id: String, screen_pos: Vector2, _index: int) -> void:
	# ★★ 2026.11.15（用户口径）：科技牌也要和建筑 / 单位牌同一条放回逻辑 ——
	#   松手在任意 UI 上（拖回手牌 / 页签 / 面板）= 取消，不启用、不弃用。
	#   科技牌的回手动画由 tech_grid 自己播（见 tech_grid._finish_touch_drag）。
	if point_hits_ui(screen_pos):
		return
	_on_tech_cell_activated(id)


## ★★ 2026.11.19：拖单位牌时，把镜头**一次性**移到当前主选中部队 / 将领。
## 不是跟随：只调一次 `center_on_tile_smooth`，之后镜头照常由玩家控制。
func _focus_selected_troops_once() -> void:
	if camera_rig == null or input_ctrl == null:
		return
	var u = input_ctrl.first_selected_leader()
	if u == null:
		for cand in input_ctrl.selected_units:
			if cand != null and cand.alive:
				u = cand
				break
	if u == null or not camera_rig.has_method("center_on_tile"):
		return
	camera_rig.center_on_tile(u.pos)


## 拖起建筑牌：记下这张牌的类型 / 所有可落点，并立刻算一次「指针落在哪」。
##
## ★★ 2026.11.15：拖起那一刻就把「这一张牌所有能落的位置」算出来 ——
##   overlay 靠它画**全部点位的高亮**（用户口径：拖拽时所有可建点位高亮）。
##   建筑牌不改变世界（只是读取），所以只算一次；松手后清理。
## ★★ 2026.11.19：大本营牌 = 拖到**当前己方大本营**上升级。
## 复用建筑拖拽那一整套（圆形范围 / 吸附 / 绿色判定 / 成功回手），
## 只是“可落点”固定为那一栋大本营。
func _begin_base_upgrade_drag(screen_pos: Vector2) -> void:
	if world == null or cfg == null:
		return
	var base = world.find_base_of(String(world.my_faction))
	if base == null or int(base.level) >= world.building_level_cap(base):
		return
	drag_build_active = true
	drag_build_type = "base"
	drag_build_tile = Vector2i(-1, -1)
	drag_build_anchor = null
	drag_build_upgrade = null
	drag_build_pointer_tile = Vector2i(-1, -1)
	_drag_build_left_hand = false
	drag_build_radius = cfg.build_drop_radius_tiles if cfg != null else 1.5
	drag_build_anchors = []
	drag_upgrade_targets = {Vector2i(int(base.tx), int(base.ty)): base}
	drag_anchor_active = true
	drag_anchor_kind = "build"
	drag_anchor_radius = drag_build_radius
	drag_anchor_tiles = [Vector2i(int(base.tx), int(base.ty))]
	_update_build_drag_preview(screen_pos)


func _begin_build_drag(entry: Dictionary, screen_pos: Vector2) -> void:
	var build_type := String(entry.get("build_type", ""))
	if build_type == "" or not bool(entry.get("ready", true)) or world == null:
		return
	drag_build_active = true
	drag_build_type = build_type
	drag_build_tile = Vector2i(-1, -1)
	drag_build_anchor = null
	drag_build_upgrade = null
	drag_build_pointer_tile = Vector2i(-1, -1)
	_drag_build_left_hand = false
	drag_build_radius = cfg.build_drop_radius_tiles if cfg != null else 1.5
	drag_build_anchors = world.build_anchors_for(build_type, world.my_faction)
	# ★★ 同种建筑 = 另一种「能落点」：拖起那一刻算一次（与建造点位同一套高亮）。
	drag_upgrade_targets = world.building_upgrade_targets(build_type, world.my_faction)
	drag_anchor_active = true
	drag_anchor_kind = "build"
	drag_anchor_radius = drag_build_radius
	drag_anchor_tiles = []
	for a in drag_build_anchors:
		if typeof(a) == TYPE_DICTIONARY:
			drag_anchor_tiles.append(a["tile"])
	# ★ 同种建筑也进高亮列表（overlay 对建筑格画同样的框 + 点，圈由吸附步决定）
	for tile in drag_upgrade_targets.keys():
		if not drag_anchor_tiles.has(tile):
			drag_anchor_tiles.append(tile)
	_update_build_drag_preview(screen_pos)


## 拖动中：算「指针落在哪个锚点的圆形范围里」。
##
## ★★ 用户口径（2026.11.15）：建筑牌只能落在**预置建造点位**上；拖到点位**附近**时
##   该点位周围出现**圆形范围指示**，在圈内松手 = 在那个点位建造。
##   ⇒ 判定 = 世界坐标（格）里，指针到锚点中心的距离 ≤ `build.drop_radius_tiles`。
##   多个锚点都在圈内时取**最近**的那个（不会出现「松手落到了另一个点」）。
## ★ 指针压在 HUD 上 / 出界 / 没锚点 ⇒ 不吸附（松手 = 取消）。
## ★★ 但**虚影常驻**（用户口径）：没吸附时普通建筑跟着指针格、城墙跟着「最近的
##   己方区划中心」，只有指针在 HUD 上时才收起。
func _update_build_drag_preview(screen_pos: Vector2) -> void:
	drag_build_screen_pos = screen_pos
	drag_build_tile = Vector2i(-1, -1)
	drag_build_anchor = null
	drag_build_upgrade = null
	drag_build_pointer_tile = Vector2i(-1, -1)
	drag_anchor_tile = Vector2i(-1, -1)
	drag_anchor_ok = false
	if palette == null or world == null \
			or (drag_build_anchors.is_empty() and drag_upgrade_targets.is_empty()):
		return
	if point_hits_ui(screen_pos):
		return
	var logic: Variant = palette.to_logic(screen_pos)
	if logic == null:
		return
	_drag_build_left_hand = true
	var p: Vector2 = logic
	drag_build_pointer_tile = Vector2i(floori(p.x), floori(p.y))
	var best: Variant = null
	var best_d := INF
	var best_upgrade: Variant = null
	var best_upgrade_d := INF
	for a in drag_build_anchors:
		if typeof(a) != TYPE_DICTIONARY:
			continue
		var tile: Vector2i = a["tile"]
		var d: float = Vector2(float(tile.x) + 0.5, float(tile.y) + 0.5).distance_to(p)
		if d > drag_build_radius + 1e-6:
			continue
		if d < best_d - 1e-6:
			best_d = d
			best = a
	# ★★ 同种建筑：同样按「指针到格子中心的距离 ≤ drop_radius」吸附。
	#   两者都在圈里时取**更近**的那个；一样近时优先**升级**（指针正压在那栋楼上，
	#   玩家想表达的显然是升级，而不是在旁边空地新建一栋）。
	for tile_v in drag_upgrade_targets.keys():
		var ut: Vector2i = tile_v
		var ud: float = Vector2(float(ut.x) + 0.5, float(ut.y) + 0.5).distance_to(p)
		if ud > drag_build_radius + 1e-6:
			continue
		if ud < best_upgrade_d - 1e-6:
			best_upgrade_d = ud
			best_upgrade = drag_upgrade_targets[ut]
	if best != null and best_upgrade != null:
		if best_upgrade_d <= best_d + 1e-6:
			best = null
		else:
			best_upgrade = null
	if best_upgrade != null:
		drag_build_upgrade = best_upgrade
		drag_build_tile = Vector2i(int(best_upgrade.tx), int(best_upgrade.ty))
	else:
		drag_build_anchor = best
		if best != null:
			drag_build_tile = best["tile"]
	drag_anchor_tile = drag_build_tile
	drag_anchor_ok = _card_build_anchor_valid() \
		if (best != null or best_upgrade != null) else false


## 拖起将领牌：区划中心成为落点（只列**现在真的能招**的中心）。
##
## ★ 判据全部走权威侧：`world.can_recruit_zone()` 为空才算可落点
##   （已拥有 / 阶数不足 / 将领满员 / 冷却中 / 队列满 都会把那个中心排除掉）。
func _begin_recruit_drag(entry: Dictionary, screen_pos: Vector2) -> void:
	if world == null or input_ctrl == null:
		return
	var kind := String(entry.get("unit_kind", ""))
	if kind == "":
		return
	drag_recruit_active = true
	drag_recruit_kind = kind
	drag_recruit_tile = Vector2i(-1, -1)
	drag_recruit_anchor = null
	drag_recruit_radius = cfg.build_drop_radius_tiles if cfg != null else 1.5
	drag_recruit_anchors = []
	drag_recruit_unit_anchors = []
	drag_recruit_unit_mode = String(entry.get("type", "")) == "recruit"
	if drag_recruit_unit_mode:
		# 单位牌：任一己方将军都是落点（圆圈指示与建造点位同一套）。
		for u in world.units:
			if u == null or not u.alive or not u.is_general():
				continue
			if String(u.faction) != String(world.my_faction):
				continue
			if u.has_method("is_downed") and u.is_downed():
				continue
			drag_recruit_unit_anchors.append({
				"unit": u, "tile": Vector2i(int(u.tx), int(u.ty))})
	else:
		# 将领牌：区划中心是落点（原逻辑）。
		if world.zones == null:
			return
		for z in world.zones.zones:
			if typeof(z) != TYPE_DICTIONARY:
				continue
			var zd: Dictionary = z
			if zd.get("center", null) == null:
				continue
			var zid := int(zd.get("id", -1))
			if zid < 0:
				continue
			if world.can_recruit_zone(kind, zid, world.my_faction) != "":
				continue
			drag_recruit_anchors.append({"tile": zd["center"], "zone_id": zid})
	drag_anchor_active = true
	drag_anchor_kind = "recruit"
	drag_anchor_radius = drag_recruit_radius
	drag_anchor_tiles = []
	if drag_recruit_unit_mode:
		for a in drag_recruit_unit_anchors:
			drag_anchor_tiles.append((a as Dictionary)["tile"])
	else:
		for a in drag_recruit_anchors:
			drag_anchor_tiles.append((a as Dictionary)["tile"])
	_update_recruit_drag_preview(screen_pos)


## 拖动中：最近的可招募区划中心（半径内才吸附；虚影 / 圈同理）。
func _update_recruit_drag_preview(screen_pos: Vector2) -> void:
	drag_recruit_screen_pos = screen_pos
	drag_recruit_tile = Vector2i(-1, -1)
	drag_recruit_anchor = null
	drag_anchor_tile = Vector2i(-1, -1)
	drag_anchor_ok = false
	var anchors: Array = drag_recruit_unit_anchors \
		if drag_recruit_unit_mode else drag_recruit_anchors
	if palette == null or world == null or anchors.is_empty():
		return
	if point_hits_ui(screen_pos):
		return
	var logic: Variant = palette.to_logic(screen_pos)
	if logic == null:
		return
	var p: Vector2 = logic
	var best: Variant = null
	var best_d := INF
	for a in anchors:
		var d: float
		if drag_recruit_unit_mode:
			var u = (a as Dictionary).get("unit", null)
			if u == null or not is_instance_valid(u) or not u.alive:
				continue
			d = u.pos.distance_to(p)
		else:
			var tile: Vector2i = (a as Dictionary)["tile"]
			d = Vector2(float(tile.x) + 0.5, float(tile.y) + 0.5).distance_to(p)
		if d > drag_recruit_radius + 1e-6:
			continue
		if d < best_d - 1e-6:
			best_d = d
			best = a
	if best == null:
		return
	drag_recruit_anchor = best
	drag_recruit_tile = (best as Dictionary)["tile"]
	drag_anchor_tile = drag_recruit_tile
	drag_anchor_ok = _recruit_anchor_ok(best)


## 吸附到的那个区划中心，现在**钱 / 人口**够不够（规则那部分已由锚点筛选保证）。
func _recruit_anchor_ok(anchor: Variant) -> bool:
	if anchor == null or world == null:
		return false
	if drag_recruit_unit_mode:
		var u = (anchor as Dictionary).get("unit", null)
		if u == null or not is_instance_valid(u) or not u.alive:
			return false
		if world.can_recruit(drag_recruit_kind, String(u.id), world.my_faction) != "":
			return false
		return world.can_afford_recruit(drag_recruit_kind, String(u.id)) == ""
	var zid := int((anchor as Dictionary).get("zone_id", -1))
	return world.can_afford_zone_recruit(drag_recruit_kind, zid) == ""


## 在圈内松手 = 在那个区划里招募这位将领。@return true = 命令已发出。
func _commit_recruit_drag() -> bool:
	if drag_recruit_kind == "" or input_ctrl == null or world == null:
		return false
	if drag_recruit_anchor == null:
		if not point_hits_ui(drag_recruit_screen_pos):
			if drag_recruit_unit_mode:
				show_notice("把单位牌拖到己方将军的圈里再松手")
			else:
				show_notice("把将领牌拖到区划中心的圈里再松手：那里才是招募的落点")
		return false
	if drag_recruit_unit_mode:
		var u = (drag_recruit_anchor as Dictionary).get("unit", null)
		if u == null or not is_instance_valid(u) or not u.alive:
			show_notice("这位将军不在了")
			return false
		var why_u: String = world.can_recruit(drag_recruit_kind, String(u.id), world.my_faction)
		if why_u != "":
			show_notice(recruit_reject_text(why_u, drag_recruit_kind))
			return false
		var afford_u: String = world.can_afford_recruit(drag_recruit_kind, String(u.id))
		if afford_u != "":
			show_notice("招募%s：%s" % [drag_recruit_kind,
				"资源不足" if afford_u == "cost" else "人口不足"])
			return false
		return input_ctrl.request_recruit_for(drag_recruit_kind, u)
	var zid := int((drag_recruit_anchor as Dictionary).get("zone_id", -1))
	var why: String = world.can_recruit_zone(drag_recruit_kind, zid, world.my_faction)
	if why != "":
		show_notice(_zone_recruit_reject_text(why, drag_recruit_anchor))
		return false
	var afford: String = world.can_afford_zone_recruit(drag_recruit_kind, zid)
	if afford != "":
		show_notice("招募这位将领：%s" % ("资源不足" if afford == "cost" else "区划人口不足"))
		return false
	return input_ctrl.request_zone_recruit_at(drag_recruit_kind, zid)


## 区划招募拒因 → 玩家看得懂的一句话（拖拽与点选共用）。
func _zone_recruit_reject_text(reason: String, _entry: Variant = null) -> String:
	match reason:
		"owned":
			return "这位将领已经拥有，不能重复招募"
		"tier":
			return "大本营阶数不足，招不了这位将领"
		"general_limit":
			return "将领已达上限（最多 %d 名）：升级大本营可以提高上限" \
				% world.base_max_generals(world.my_faction)
		"cooldown":
			return "将领招募冷却中：还需 %s 秒" % _fmt_num(
				world.general_recruit_cooldown_left(world.my_faction))
		"queue_full":
			return "这个区划的招募队列满了"
		"zone_owner", "zone_not_found":
			return "只能在自己区划的中心招募将领"
		"kind":
			return "这位将领不在可招募名单里"
	return "这位将领现在不能招募"


## 这一格作为 `build_type` 的落点现在能不能用（**不含吸附**：只问逻辑层）。
##
## ★ 保留这个名字 / 签名：3D 虚影（game_scene3d）与旧测试都读它。
##   它现在只做「规则 + 钱」两件事，锚点/圈的判定在 `_card_build_anchor_valid()`。
func _card_build_tile_valid(build_type: String, tile: Vector2i) -> bool:
	if world == null or cfg == null or tile.x < 0 or tile.y < 0 \
			or not world.map.terrain.has(tile.x, tile.y):
		return false
	if not world.building_unlocked(world.my_faction, build_type):
		return false
	if not world.can_place_building(build_type, tile.x, tile.y, world.my_faction):
		return false
	var raw: Variant = cfg.get_path_value("building.%s.cost" % build_type)
	var cost: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {}
	return EconomyRes.can_afford(world.resource_pool_for(String(world.my_faction)), cost)


## 当前吸附到的锚点是否**真的能落**（吸附 + 规则 + 钱）。
## ★★ 两种落点：空点位 = 建造（老逻辑）；同种建筑 = 升级（2026.11.17）。
func _card_build_anchor_valid() -> bool:
	if drag_build_upgrade != null:
		return world.building_upgrade_reason(drag_build_upgrade, world.my_faction) == ""
	if drag_build_anchor == null or drag_build_type == "":
		return false
	var tile: Vector2i = (drag_build_anchor as Dictionary)["tile"]
	return _card_build_tile_valid(drag_build_type, tile)


## 松手：在圈内 = 发建造命令 / 升级命令；否则只给提示（拖回手牌静默取消）。
## @return true = 命令已发出。
func _commit_card_build_drag() -> bool:
	if drag_build_type == "":
		return false
	# ★★ 吸附到**同种建筑** ⇒ 这次拖拽是「升级」，不是新建（用户口径 2026.11.17）。
	if drag_build_upgrade != null:
		return _commit_building_upgrade(drag_build_upgrade)
	# ★ 没吸附到任何点位：拖到空地 / 拖回手牌都算取消，给一句明确提示
	#   （只在真的把牌拖到地图上过才提示，免得「拖起来又拖回去」也弹红字）。
	if drag_build_anchor == null:
		# 拖回手牌 / 右栏 = 取消（不提示）；真的把牌丢在地图空处才提示。
		if _drag_build_left_hand and not point_hits_ui(drag_build_screen_pos):
			show_notice(_drag_build_miss_text())
		return false
	var tile: Vector2i = (drag_build_anchor as Dictionary)["tile"]
	if not world.building_unlocked(world.my_faction, drag_build_type):
		show_notice("这个大本营等级还建不了%s" % drag_build_type)
		return false
	var reason: String = world.build_reject_reason(drag_build_type, tile.x, tile.y,
		world.my_faction)
	if reason != "":
		show_notice(build_reject_text(reason))
		return false
	if not _card_build_tile_valid(drag_build_type, tile):
		show_notice("建造资源不足，建不了")
		return false
	input_ctrl.command_issued.emit({
		"kind": "build", "build_type": drag_build_type,
		"tx": tile.x, "ty": tile.y,
		# ★ 城墙要按区划整圈建：把 zone_id 一并带上（权威侧也接受只给中心格）。
		"zone_id": int((drag_build_anchor as Dictionary).get("zone_id", -1)),
		"faction": world.my_faction,
	})
	return true


## 松手落在同种建筑上 = **升级那一栋**（瞬时：命令发出后逻辑层当场 +1 级）。
## ★ 走的还是现成的那条命令（`building_upgrade`）：联机同步、快照、事件都不用另开一条路。
func _commit_building_upgrade(b) -> bool:
	if b == null or input_ctrl == null or world == null:
		return false
	var why: String = world.building_upgrade_reason(b, world.my_faction)
	if why != "":
		show_notice(_upgrade_reject_text(why, b))
		return false
	return input_ctrl.request_building_upgrade(b)


## 升级拒因 → 玩家看得懂的一句话（拖拽用；大本营那一格走的是操作页自己的文案）。
func _upgrade_reject_text(reason: String, b) -> String:
	var name_s: String = b.display_name() if b != null and b.has_method("display_name") else "这栋建筑"
	match reason:
		"max_level":
			return "%s已经是最高级了" % name_s
		# ★★ 2026.11.18：教堂的等级被大本营压住（不是「满了」，是「大本营还不够高」）。
		"base_level_cap":
			return "%s的等级不能超过己方大本营：先把大本营升上去" % name_s
		"owner":
			return "只能升级自己的%s" % name_s
		"cost":
			return "升级%s的资源不足" % name_s
		"generals":
			return "将领数量不够，升不了%s" % name_s
		"respawning":
			return "大本营正在排队重生将领，暂时不能升级"
		"building":
			return "%s还在建造中，建好才能升级" % name_s
		"neutralized":
			return "大本营没了，残余建筑不能再升级"
		"type":
			return "这一种建筑不能升级"
	return "%s现在不能升级" % name_s


## 拖到「空处」时的提示 —— 如果那格正好有一栋同种建筑但升不了，说清楚原因。
func _drag_build_miss_text() -> String:
	var tile: Vector2i = drag_build_pointer_tile
	if drag_build_type == "base":
		if world != null and tile.x >= 0 and tile.y >= 0:
			var bb = world.building_at(tile.x, tile.y)
			if bb != null and bb.alive and bb.is_base():
				var why_b: String = world.building_upgrade_reason(bb, world.my_faction)
				if why_b != "":
					return _upgrade_reject_text(why_b, bb)
		return "把大本营牌拖到己方大本营上松手，才能升级"
	if world != null and tile.x >= 0 and tile.y >= 0:
		var b = world.building_at(tile.x, tile.y)
		if b != null and b.alive and String(b.type) == drag_build_type:
			var why: String = world.building_upgrade_reason(b, world.my_faction)
			if why != "":
				return _upgrade_reject_text(why, b)
	if "wall" in String(drag_build_type):
		return "城墙只能建在己方区划中心的周围：把牌拖到高亮的位置再松手"
	return "建筑只能建在区划的建造点位上（同种建筑上松手 = 升级）：把牌拖到高亮的位置再松手"


func _clear_card_build_drag() -> void:
	drag_build_active = false
	drag_build_type = ""
	drag_build_tile = Vector2i(-1, -1)
	drag_build_anchors = []
	drag_build_anchor = null
	drag_build_upgrade = null
	drag_upgrade_targets = {}
	drag_build_pointer_tile = Vector2i(-1, -1)
	_drag_build_left_hand = false
	_clear_drag_anchor()


func _clear_card_recruit_drag() -> void:
	drag_recruit_active = false
	drag_recruit_kind = ""
	drag_recruit_tile = Vector2i(-1, -1)
	drag_recruit_anchors = []
	drag_recruit_anchor = null
	drag_recruit_unit_mode = false
	drag_recruit_unit_anchors = []
	_clear_drag_anchor()


func _clear_drag_anchor() -> void:
	drag_anchor_active = false
	drag_anchor_kind = ""
	drag_anchor_tiles = []
	drag_anchor_tile = Vector2i(-1, -1)
	drag_anchor_ok = false


## ★★ 命令卡某一类格子的呼吸高亮（教程「协防军」按钮）。
func set_command_card_glow(kind: String) -> void:
	if command_card != null:
		command_card.set_glow_kind(kind)


## ★★ 教程引导：让某一页签呼吸高亮（空串 = 关闭）。
func set_page_tab_attention(page: String) -> void:
	if page_tabs != null:
		page_tabs.set_attention(page)


func _build_page_tabs() -> void:
	page_tabs = PageTabsRes.new()
	_root.add_child(page_tabs)
	page_tabs.setup(_font)
	page_tabs.page_changed.connect(_on_page_changed)


## ★★ 卡牌悬停面板 —— 鼠标停在哪张手牌 / 科技牌上，就在**牌的左侧**浮一块说明。
##
## 需求原话（2026.11.19）：「悬停面板的顶部需要与卡面的顶部对齐，同时悬停面板固定在
##   卡面左侧显示」⇒ 面板顶边 = 牌顶边、永远在左侧（见 ui_layout.card_hover_panel_position）。
##   再一轮：「将领卡牌的悬停……卡面右侧会额外出现一个显示其将领特性的面板」
##   ⇒ 将领卡会同时开两块：左侧主面板（名称/造价/简述）+ 右侧特性面板。
##
## ★ 面板是纯显示（`MOUSE_FILTER_IGNORE`），盖住谁都不会抢谁的鼠标；
##   位置按**牌的最终姿势**算（`cell_pose_rect(i, true)`），不读正在动的控件坐标。
##
## ★ 手牌与科技牌**共用**这两块面板：它们在屏幕上逐像素重合，
##   分成两套就会出现「切页那一刻旧面板还没收掉」。
##
## ★ 接线只有两条：`cell_hovered` → 弹（`_on_hover_in`）、`cell_unhovered` → 收
##   （`_on_hover_out`）。文案由 `_card_hover_content()` 现取 —— 本控件不认识任何玩法概念，
##   与 command_card / tech_grid 同一条边界（它们只报「第几格」）。
func _build_card_hover() -> void:
	card_hover = CardHoverPanelRes.new()
	_root.add_child(card_hover)
	card_hover.setup(_font, UiLayoutRes.CARD_HOVER_PANEL_W)
	# 将领特性面板：同一套牌面，窄一点（236），挂在牌的右侧。
	general_trait_panel = CardHoverPanelRes.new()
	_root.add_child(general_trait_panel)
	general_trait_panel.setup(_font, UiLayoutRes.CARD_HOVER_TRAIT_W)
	command_card.cell_hovered.connect(_on_hover_in.bind("card"))
	command_card.cell_unhovered.connect(_on_hover_out.bind("card"))
	tech_grid.cell_hovered.connect(_on_hover_in.bind("tech"))
	tech_grid.cell_unhovered.connect(_on_hover_out.bind("tech"))


## ★★ 2026.11.14 第三轮（用户口径）：「把选项按钮删除，相应的打开菜单逻辑接到 esc 下」。
##
## 所以屏幕上**没有**选项按钮了 —— 入口只剩两条纯键盘 / 系统手势：
##   · PC：Esc（input_controller.handle_key 的 Esc 级联：先取消建造 / 指令 /
##     框选 / 招募取消，都没有时才开菜单；菜单开着时 Esc = 关 —— 见 handle_key）
##   · 安卓：返回键（main._on_android_back：菜单开着 → 关；否则 → 开）
##
## ⚠️ 别再为了「有个可见入口」把按钮加回来（SETTINGS_RECT 已从 ui_layout 删除）。
##   选项页本身仍然是**居中的模态 overlay**，见 view/options_panel.gd。

## ★★ 选项页菜单（仿 nsoc）：overlay + 居中面板，一级「继续 / 设置 / 返回主菜单」，
##    二级「设置」里是「全屏 / 窗口化」+「返回」。见 view/options_panel.gd。
##
## ★ 旧版那个贴在按钮下方的两格下拉已经删掉：现在整块是**模态 overlay**，
##   点空白处 / 「继续」都会关；它自己不改窗口、不拆场景，只发 HUD 的信号
##   （`fullscreen_toggled` / `return_to_menu_requested`）。
## ★ 兼容字段：`settings_panel` 仍指向 overlay（旧测试 / main.gd 的
##   `set_settings_menu_open(false)` 不用改）。
## ★★ 合作 AI 队友的浮动指令面板。
## ★ 建在选项页之前：选项页是模态 overlay（z_index=200），必须压在它上面；
##   面板只在有同方 commander 时由 `sync()` 自己显示。
func _build_ai_panel() -> void:
	ai_panel = AiOrderPanelRes.new()
	ai_panel.name = "AiOrderPanel"
	add_child(ai_panel)
	ai_panel.setup(cfg, _font)
	ai_panel.bind_world(world)


## ★★ 观战：玩家不下命令，右下命令卡与页签整块收起；AI 面板保留。
## `allow_ai_orders = true`（ai_test_2）时 AI 面板「求援」按钮仍可点，其余仍是只读。
func set_observer(on: bool, allow_ai_orders: bool = false) -> void:
	observer_mode = on
	if command_card != null:
		command_card.visible = not on
	if page_tabs != null:
		page_tabs.visible = not on
	if ai_panel != null:
		var fid := String(world.my_faction) if on and world != null else ""
		ai_panel.set_observer(fid, allow_ai_orders)
		ai_panel.sync()


func _build_options_panel() -> void:
	options_panel = OptionsPanelRes.new()
	options_panel.name = "OptionsPanel"
	_root.add_child(options_panel)
	options_panel.setup(_root, _font, cfg, {
		"style": "hud",
		"resume_label": cfg.str_val("settings.continue_text", "继续"),
		"settings_label": cfg.str_val("settings.panel_title", "设置"),
		"back_label": cfg.str_val("settings.back_text", "返回"),
		"panel_title": cfg.str_val("settings.panel_title", "设置"),
		"exit_label": cfg.str_val("settings.menu_text", "返回主菜单"),
		"fullscreen_on_text": cfg.str_val("settings.fullscreen_on_text", "窗口化"),
		"fullscreen_off_text": cfg.str_val("settings.fullscreen_off_text", "全屏"),
		"fullscreen_action": Callable(self, "_on_fullscreen_pressed"),
		"exit_action": Callable(self, "_on_return_menu_pressed"),
	})
	options_panel.opened.connect(_on_options_opened)
	options_panel.closed.connect(_on_options_closed)
	settings_panel = options_panel.overlay
	fullscreen_button = options_panel.fullscreen_button
	return_menu_button = options_panel.exit_button


## ★ 选项页开 / 关**不再联动任何按钮**（2026.11.14 第三轮：按钮已删除）。
##   这两个回调保留着，是因为选项页自己会发 `opened` / `closed`
##   （将来要加别的联动 —— 例如暂停 BGM —— 接在这里）。
func _on_options_opened() -> void:
	pass


func _on_options_closed() -> void:
	pass


## `input_controller` 请求开选项页（Esc 取消到底、什么都没得取消时才会发）。
##
## ★ 只开不关：**关**走 `hud.handle_key`（Esc）与 `main._on_android_back`（返回键），
##   免得「按住 Esc 一帧开一次、下一帧又关掉」这种鬼畜。
func _on_open_menu_requested() -> void:
	set_settings_menu_open(true)


## 选项页开着就收起来，关着就弹出来（Esc / 安卓返回键都走这里）。
func toggle_settings_menu() -> void:
	set_settings_menu_open(options_panel != null and not options_panel.is_open())


## 直接指定选项页开 / 关（Esc、安卓返回键、测试、以及「返回主菜单」都会用到）。
func set_settings_menu_open(open: bool) -> void:
	if options_panel == null:
		return
	if open:
		options_panel.open()
	else:
		options_panel.close()


## 「全屏 / 窗口化」文案刷新（选项页每次打开时会自己刷；这里留一个给测试 / 兼容用的入口）。
func _refresh_fullscreen_label() -> void:
	if options_panel != null:
		options_panel.refresh_fullscreen()


func _fullscreen_label() -> String:
	if _is_fullscreen():
		return cfg.str_val("settings.fullscreen_on_text", "窗口化")
	return cfg.str_val("settings.fullscreen_off_text", "全屏")


## 现在是不是全屏（含独占全屏）——与 view/main.gd 的那条判据同源。
func _is_fullscreen() -> bool:
	var mode: int = DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## 「全屏」被按下 —— ★ 只发信号：切窗口模式的是 view/main.gd
## （它同时管着 Ctrl+Q，两处必须是同一份实现，见那里的 `toggle_fullscreen`）。
func _on_fullscreen_pressed() -> void:
	fullscreen_toggled.emit()


## 「返回主菜单」被按下 —— ★ 同样只发信号：拆游戏场景、把开场页放回来都是
## view/main.gd 的事（本文件只是界面，不该去动兄弟节点）。
func _on_return_menu_pressed() -> void:
	return_to_menu_requested.emit()


func _build_squad_panel() -> void:
	squad_panel = SquadPanelRes.new()
	_root.add_child(squad_panel)
	squad_panel.setup(cfg, world, input_ctrl, _font, team_slots)
	# ★★ 详情焦点改为听输入层的统一信号：单击标签 / 数字键、双击快速选中都会发，
	#   触摸端也走同一条（squad_panel 不再自己 emit troop_focused）。
	#   复用 `_on_troop_activated`（点左栏下半将领格也走它：只改展开哪一支，不动选中集合）。
	if input_ctrl != null and not input_ctrl.general_focused.is_connected(_on_troop_activated):
		input_ctrl.general_focused.connect(_on_troop_activated)


# ------------------------------------------------------------------
# 命令卡的内容（随页签切换）
# ------------------------------------------------------------------

func _on_page_changed(page: String) -> void:
	# ★★ 2026.11.19：X 不是内容页 —— 收起手牌 + 取消全部选中；再点一次恢复。
	if page == PageTabsRes.PAGE_CLOSE:
		if _hand_collapsed:
			_hand_collapsed = false
			_tab_key = ""
			_sync_tabs()
		else:
			_collapse_hand()
		return
	# ★ 收起状态下点任意内容扇区 = 恢复手牌并切到那一页。
	if _hand_collapsed:
		_hand_collapsed = false
		_tab_key = ""
		if page_tabs != null:
			page_tabs.visible = true
		if command_card != null:
			command_card.visible = true
	# ★★ 2026.11.19：选中另一个建筑 / 部队时，`set_pages()` 也会同步发这个信号。
	#   那一路先不在这里播 —— 统一由 `_animate_hand_on_selection_change()` 播一次，
	#   否则「换选中 + 换页」会叠两遍。玩家 `select_page()` / Tab 切页仍在这里播。
	_rebuild_card(not _sync_tabs_guard)


## X 页签：收起手牌并取消全部选中。★ 圆盘保留（用户口径：点扇区可恢复）。
func _collapse_hand() -> void:
	_hand_collapsed = true
	_collapsing_hand = true
	if input_ctrl != null:
		input_ctrl.select_units([])
	_collapsing_hand = false
	if page_tabs != null:
		page_tabs.visible = true
		page_tabs.set_page_silent(PageTabsRes.PAGE_CLOSE)
	if command_card != null:
		command_card.visible = false
	if tech_grid != null:
		tech_grid.set_visible_page(false)
	# 让下一次恢复时强制重推页签（`_page` 现在停在 close）。
	_tab_key = ""


## 「这一屏没有右下角」—— **页签列 + 命令卡整块隐藏**（不是立一颗空页签）。
##
## ★ 需求原话：「页签和命令卡都要隐藏，选中敌方/友方任何建筑/单位时，
##   右下角标签都隐藏」。
## ★ 空页列表就是唯一判据：`_sync_tabs()` 看到它就把 `page_tabs` 与 `command_card`
##   一起 `visible = false`（页签的外框 `TabsFrame` 是它的子节点，一并收起）。
func _hidden_command_ui_plan() -> Dictionary:
	return {"kind": "noop", "pages": [], "default": ""}


## 这一栋建筑现在有没有可操作项（决定右下角给不给页签）。
##   · 大本营   → 有（操作页里是升级 / 重生状态）
##   · 区划中心 → 有（招募页；点中心走 `selected_zone` 那条路）
##   · 其余建筑 → ★ 2026.11.19 起也有：操作页里是「拆除」卡牌
##     （木墙 / 哨塔 / 石墙 / 警戒塔 / 粮田 / 房屋 / 矿脉 / 教堂…）。
##   ⚠️ 能显示操作页 ≠ 能拆：大本营由逻辑层硬拒，区划中心是无敌中立障碍，
##      `_building_order_entries()` 只给非大本营挂「拆除」格。
func _building_has_actions(b) -> bool:
	if b == null or world == null:
		return false
	if not b.alive:
		return false
	# 无敌的非中心建筑没有「拆除」入口。
	if String(b.type) != BuildingRes.TYPE_ZONE_CENTER and b.is_invulnerable():
		return false
	return true


## 这一批单位是不是**全部属于本机那一方**。
## ★ 右下角只给自己一方的对象下命令：友军（same_side 但不是自己）与敌方任何
##   建筑 / 单位都整块隐藏（需求原话：「选中敌方/友方任何建筑/单位时，右下角标签都隐藏」）。
func _units_all_own(units: Array) -> bool:
	if world == null:
		return false
	for u in units:
		if u == null or String(u.faction) != String(world.my_faction):
			return false
	return true


## 这一批建筑是不是**全部属于本机那一方**（友军建筑同样不算「自己」）。
func _buildings_all_own(buildings: Array) -> bool:
	if world == null:
		return false
	for b in buildings:
		if b == null or String(b.owner) != String(world.my_faction):
			return false
	return true


## 这个区划是不是**本机那一方**的（友军 / 中立 / 敌方都不是）。
func _zone_is_own(z: Dictionary) -> bool:
	return world != null and String(z.get("owner", "")) == String(world.my_faction)


## 按当前选中对象算出「默认停在哪一页」。
##
## ★★ 2026.11.19（用户口径）：圆盘页签**永远只有 5 个**（单位 / 将领 / 建筑 / 科技 / X），
##   不再因为选中对象而增减 / 隐藏。选部队时默认单位页、选建筑 / 区划时默认建筑页，
##   只是「上一次停在哪一页」的记忆分桶不同；玩家随时可以点任意扇区切过去。
func _tab_plan() -> Dictionary:
	var pages := [PageTabsRes.PAGE_BUILD, PageTabsRes.PAGE_UNIT,
		PageTabsRes.PAGE_GENERAL, PageTabsRes.PAGE_TECH]
	if input_ctrl == null:
		return {"kind": "none", "pages": [], "default": ""}
	if input_ctrl.selected_zone != null:
		return {"kind": "building", "pages": pages,
			"default": PageTabsRes.PAGE_BUILD}
	if not input_ctrl.selected_buildings.is_empty():
		return {"kind": "building", "pages": pages,
			"default": PageTabsRes.PAGE_BUILD}
	if not _selected_troops(input_ctrl.selected_units).is_empty():
		return {"kind": "unit", "pages": pages,
			"default": PageTabsRes.PAGE_UNIT}
	if _selected_enemy_kind() != "":
		return {"kind": "enemy", "pages": pages,
			"default": PageTabsRes.PAGE_BUILD}
	return {"kind": "empty", "pages": pages,
		"default": PageTabsRes.PAGE_BUILD}


## 每帧把「该显示哪几页」推给 page_tabs，并同步命令卡的显隐。
##
## ★ 页列表没变（比如点完将领 1 又点将领 2）时**什么都不做** ——
##   玩家自己切到「单位」页之后，不该被下一帧抢回「操作」页。
## ★ 换了一类选中时，优先回到这一类**上次停的那一页**（`_page_memory`），
##   没有记录才用它自己的默认页。
## ★★ 2026.11.19：页签改为**固定 5 项的圆盘**，不再因为选中对象而增减。
##   `_tab_plan()` 只决定「默认停在哪一页」与页记忆的 kind；圆盘本身始终可点。
##   观战时整块隐藏；X 收起时只收手牌，圆盘保留（点扇区 / 再点 X 恢复）。
func _sync_tabs() -> void:
	if page_tabs == null:
		return
	if observer_mode:
		page_tabs.visible = false
		if command_card != null:
			command_card.visible = false
		return
	# X 收起：手牌 / 科技九格收起，但圆盘保留 —— 玩家点任意扇区就能恢复。
	if _hand_collapsed:
		page_tabs.visible = true
		page_tabs.set_page_silent(PageTabsRes.PAGE_CLOSE)
		if command_card != null:
			command_card.visible = false
		if tech_grid != null:
			tech_grid.set_visible_page(false)
		return
	var plan := _tab_plan()
	var pages: Array = (plan["pages"] as Array).duplicate()
	# ★★ 可见性**每帧都写**：下面的 `key == _tab_key` 短路会跳过「同一类选中」的刷新，
	#   而 visible 也可能被别的入口（观战 / 测试 / 以后的外部调用）改过。
	var show_ui := not pages.is_empty()
	page_tabs.visible = show_ui
	if command_card != null:
		command_card.visible = show_ui
	var kind := String(plan["kind"])
	# ★★ 2026.11.19：选中己方对象时自动跳到对应页（只在**选中变了**时跳一次，
	#   玩家随后手动切页不会被每帧拉回去）。
	if show_ui:
		var hint := _selection_page_hint()
		var sel_sig := _selection_anim_sig()
		if hint != "" and sel_sig != "" and sel_sig != _page_jump_sig:
			_page_jump_sig = sel_sig
			_tab_kind = kind
			if page_tabs.page() != hint:
				_sync_tabs_guard = true
				page_tabs.select_page(hint)
				_sync_tabs_guard = false
		elif sel_sig == "":
			_page_jump_sig = ""
	var key := kind
	if not show_ui:
		key += "|hidden"
	for p in pages:
		key += "|" + String(p)
	if key == _tab_key:
		return
	_tab_kind = kind
	_tab_key = key
	if not show_ui:
		# 观战 / 剧本隐藏：把圆盘内部状态清空，恢复时重新建立。
		_sync_tabs_guard = true
		page_tabs.set_pages([], "")
		_sync_tabs_guard = false
		return
	# ★★ 2026.11.19：不记忆「换页签前停在哪一页」。
	#   没选中 / 敌人 / 友军时**保持当前页**；只有 X 收起（当前页是 close）或还没选过页时
	#   才落到默认页。这样点空地取消选中不会把页签抢回建筑 / 操作页。
	var preferred := ""
	var cur_page := String(page_tabs.page())
	if cur_page == "" or cur_page == PageTabsRes.PAGE_CLOSE:
		preferred = String(plan["default"])
	# ★★ 2026.11.19：这一段是「按选中对象换默认页」，不是玩家主动切页 ——
	#   `set_pages()` 里的同步 page_changed 不播入场动效（见 `_on_page_changed`）。
	_sync_tabs_guard = true
	page_tabs.set_pages(pages, preferred)
	_sync_tabs_guard = false
	_rebuild_card()


## 现在该显示 / 操作哪个区划的招募队列与招募页：
##   · 点区划中心 → 它是 `selected_zone`；
##   · 万一那栋中心建筑是**从别的路**被选进 `selected_buildings` 的（框选选不到它，
##     见 input_controller.box_select 的过滤），这里也能从它的格子反查出所属区划。
func _recruit_zone():
	if input_ctrl == null or world == null:
		return null
	if input_ctrl.selected_zone != null:
		return input_ctrl.selected_zone
	var b = _primary_building()
	if b != null and b.type == BuildingRes.TYPE_ZONE_CENTER:
		return world.zone_center_zone_at(b.tx, b.ty)
	return null


## ★★ 右栏右上角那块面板显示什么（**两种内容共用一个控件**，见 view/recruit_queue.gd）：
##   ① 建筑升级 / 大本营重生队列的**单条读条**；
##   ② 区划中心自己的**招募队列**（点中心 → 招募页那套）；
##   ③ 都没有 → 收起来。
##
## @param holder 当前主选中的东西：**区划字典**（选中区划详情）或**建筑**（选中建筑）
##
## ★ 优先级是「读条 > 队列」：同一块地方，正在读条的那件事更该被看见。
func _refresh_progress_panel(holder) -> void:
	if holder == null:
		detail_panel.set_queue(null)
		return
	var b = null
	if typeof(holder) != TYPE_DICTIONARY:
		b = holder

	# ① 建筑升级读条
	if b != null and b.is_upgrading():
		detail_panel.set_progress_bar(
			"升级%s" % b.display_name(),
			"升 %d 级" % (b.level + 1),
			b.upgrade_progress(), b.upgrade_eta(), true)
		return
	# ①.5 大本营的将领重生队列（串行；条上写当前那一位与剩余秒数）
	if b != null and b.is_base() and b.is_respawning():
		detail_panel.set_progress_bar(
			"将领重生 %d" % b.respawn_count(),
			b.respawn_current_name(),
			b.respawn_progress(), b.respawn_eta(), false)
		return
	# ② 区划中心的招募队列（原本就有的那套）
	var rz = _recruit_zone()
	detail_panel.set_queue(rz, rz != null)


## 按当前页重组命令卡。
##
## 六张表都是**数据驱动 / 固定文案**的，这里不写死兵种名：
##   建筑页 ← config.json 的 building 段里 buildable = true 的那几项（默认是城墙 / 箭塔）
##   单位页 ← config.json 的 recruit.list（三行七种兵，按 tier = 大本营等级解锁）
##   招募页 ← world.general_recruit_slots（池子抽出的三位，排进**区划**的队列）
##   操作页 ← 大本营的升级格（部队已没有操作页）
##   科技页 ← config.json 的 tech.list（九条占位科技）—— ★ 它**不走命令卡**：
##            九格由 view/tech_grid.gd 画（另一套三态样式 + 两行文字），
##            所以这里把命令卡清空、再让科技那一层显示出来。
## 键位按参考图顺序 Q/W/E/A/S/D/Z/X/C 依次分配（第 0 项 = Q）。
##
## ★★ `rebuild_card()` 是**给界面与测试的公开入口**：正常流程里由 `_sync_tabs()` /
##   `_on_page_changed()` / 建筑操作那两条命令流调它；单独留一个公开名是为了
##   「权威状态被**外部**改了」的场合 —— 最典型的是测试：`world.tick()` 推进读条之后，
##   界面那一格还没重画。
func rebuild_card() -> void:
	_rebuild_card()


func _rebuild_card(animate_cards: bool = false) -> void:
	if command_card == null:
		return
	# ★★ 2026.11.14：命令卡重建（换页 / 换选中 / 换状态）时把**旗帜虚影收掉** ——
	#   否则「拖着一张操作牌时部队死了 / 换了选中 / 切了页」会留下一面挂在屏幕上的旗。
	#   ⚠️ 只在「本来就没在拖」时收：拖拽途中每帧都可能重建（签名变了），
	#     那时候收掉等于虚影一闪一闪。
	if command_card == null or not command_card._dragging_card:
		# ★★ 2026.11.15：建筑 / 招募的锚点与虚影同样要收 ——
		#   否则「拖牌途中切页 / 牌被收走」会在地图上留下一圈圈和半透明墙。
		if drag_build_active:
			_clear_card_build_drag()
		if drag_recruit_active:
			_clear_card_recruit_drag()
	if observer_mode:
		command_card.visible = false
		return
	var entries: Array = []
	var page := String(page_tabs.page()) if page_tabs != null else ""
	match page:
		PageTabsRes.PAGE_BUILD:
			# ★★ 2026.10.26：建筑页也改成**按行解锁**（与单位页同一套 `tier`）：
			#    第 1 行木墙 / 哨塔（1 级大本营），第 2 行石墙 / 警戒塔（2 级）。
			#    不足 3 个的格子留空；不可建造的格子 `ready = false`（置灰 + 悬停写原因）。
			entries = _build_entries()
		PageTabsRes.PAGE_UNIT:
			# ★★ 2026.11：单位页读的是**这一方派系**的招募表（王朝 / 帝国与原生是两张表），
			#    不再写死 config 的 `recruit.list`。派系解析与「原生回落」都在 world 里
			#    （见 world.clan_of / cfg.clan_recruit_list）。
			entries = _unit_hand_entries()
		PageTabsRes.PAGE_RECRUIT:
			# ★★ 本轮起招募页是**池子抽出来的一手**（不是 config 里三条写死的卡）：
			#    内容 = world.general_recruit_slots()，冷却中整页置灰。
			entries = _zone_recruit_entries()
		PageTabsRes.PAGE_GENERAL:
			# ★★ 2026.11.15 第二轮：无选中时的「将领」页 —— 与上面招募页**同一份数据**，
			#   区别只有两处：条目类型是 `general_drag`（拖到哪个中心就在哪个区划招），
			#   以及下面点选路径不再有「选中的区划」可用（点格只给一句拖拽提示）。
			entries = _general_recruit_entries()
		PageTabsRes.PAGE_ORDER:
			# ★★ 本轮起「操作」页**不只属于部队**：选中建筑时它画的是
			#    升级 / 特化那一套（需求：「为所有单位/建筑都添加上『操作』页签」）。
			entries = _order_entries_for_selection()
	var old_entries: Array = command_card.entries()
	command_card.set_entries(entries)
	if false:
		# ★★ 2026.11.14：读条牌已删（招募即时）——这一段不再需要。
		if false:
			command_card.animate_queue_insert(old_entries,
				String(_recruit_play_context.get("kind", "")),
			_recruit_play_context.get("screen_pos", Vector2.ZERO))
			_recruit_play_context.clear()
	if animate_cards and page != PageTabsRes.PAGE_TECH:
		command_card.animate_deck_in()
	# ★★ 记下「这一屏是按哪个签名画的」：`refresh()` 每帧比一次，签名一变就重建
	#    （见 `_card_sig()`）。写在**画完之后**：中间任何一步改了会进签名的状态，
	#    下一帧都会被重新比出来，不会漏。
	_card_sig_key = _card_sig()
	# ★ 换页 = 换了九格的内容（甚至换了**哪一层**在画：科技页是 tech_grid 盖在上面）：
	#   悬停面板必须跟着收起来。
	#   ⚠️ 为什么非显式收不可：鼠标正停在一格上时把那一层**藏起来**（切页会把 tech_grid
	#      整个隐藏），Godot **不会**补发 `mouse_exited` —— 不收的话那块说明会一直挂在
	#      屏幕右上角，看着像界面卡死了。
	_dismiss_hover()
	# ★ 科技那一层只有「科技」页才显示。这一句放在这里（而不是只放在 refresh 里）：
	#   `_rebuild_card` 是「页变了」那一刻同步跑的，玩家切页那一下
	#   **必须立刻**把九格盖上 / 掀开 —— 等到下一帧才变就是肉眼可见的一帧错页。
	_refresh_tech_grid(page == PageTabsRes.PAGE_TECH)
	if animate_cards and page == PageTabsRes.PAGE_TECH and tech_grid != null:
		tech_grid.animate_deck_in()


## 单位页的手牌：**只有招募牌本身**。
##
## ★★ 2026.11.14（用户口径）：「单位招募时不需要队列了，招募变为即时的，只要拖拽单位牌
##   生效就是招募完成」+ 清掉「读条牌 / 取消招募牌 / train_sec」。
##   ⇒ 原来插在最左边那张「读条中 ×N + 拖出即停招」的牌**整块删掉**：
##     现在拖出一张单位牌，松手那一刻兵就出来了（见 `world.start_recruit`）。
func _unit_hand_entries() -> Array:
	return _recruit_entries("recruit",
		world.recruit_list(world.my_faction) if world != null else [])



## 把科技九格的内容推给 view/tech_grid.gd。
##
## @param visible 这一屏现在是不是「科技」页 —— 不是的话整块盖起来（命令卡照常画）。
##
## ★★ 它由 `refresh()` **每帧**调用，而**不是**挂在 `_rebuild_card()` 里：
##   `_rebuild_card` 只在「页签组合变了 / 玩家切页」时才跑（`_sync_tabs` 有短路），
##   而科技九格的高亮取决于**权威的启用状态** —— 玩家点一下格子就会变，
##   那时页签组合一点没变。挂在 `_rebuild_card` 里的话，
##   点上去要等下一次切页才看见高亮（实测就是这个症状）。
##   ⚠️ 每帧调不会白花钱：tech_grid 内部比对内容，没变就什么都不做。
##
## ★ 内容**照旧更新**（哪怕这一页没显示）：切回科技页时不会闪一下空白，
##   而且「大本营的科技页」与「空手的科技页」共用这一份数据（同一颗页签、同一套九格）。
func _refresh_tech_grid(visible: bool) -> void:
	if tech_grid == null or world == null:
		return
	# ★★ 给每条科技补上**图标路径**（`tech_<id>.png`，见 tools/bake_unit_card_icon.py 的
	#   科技那一段：没有原画，是按名字画的占位金线图形）。
	#   ★ 在这里补而不是让 tech_grid 自己查：与命令卡同一条边界 ——
	#     格子控件只收路径字符串，不认识「兵种 / 建筑 / 科技 / 蒙版目录」这些事。
	#   ★ 每个 dict 都 `duplicate()`：`world.tech_entries()` 返回的是逻辑层的字典，
	#     直接往里塞键等于从视图改逻辑数据。
	var list: Array = []
	for item in world.tech_entries():
		var e: Dictionary = (item as Dictionary).duplicate()
		e["icon_mask"] = UnitCardIconRes.mask_for_tech(String(e.get("id", "")))
		list.append(e)
	tech_grid.set_entries(list)
	tech_grid.set_visible_page(visible)


# ------------------------------------------------------------------
# ★★ 卡牌悬停面板：内容（2026.11.19 重做）
#
# 需求原话：「面板内容：单位 = 名称 + 造价 + 标签 + 简短描述；建筑 = 名称 + 造价 + 简述；
#   将领 = 名称 + 造价 + 特性 + 简述；科技 = 名称 + 简述」。
#   ⇒ 这一节只给**手牌 / 科技牌**产出文案；其余（操作页对部队下达的那几条指令：
#     移动 / 攻击 / 行军 / 停止）返回空字典 ⇒ **不弹面板**（而不是弹一块空的）。
#
# ★ 为什么文案在 hud 而不在两个格子控件里：
#   与「拒因码 → 中文」同一条约定 ——**界面词只在这一个文件里**。
#   command_card / tech_grid 只报「第几格」，数值与说明在这里按 config 与
#   **权威状态**现取，于是不会出现「界面写着旧数值」那种漂移。
# ------------------------------------------------------------------

## 鼠标进入某一格。@param src "card"（命令卡）/"tech"（科技牌）
func _on_hover_in(index: int, src: String) -> void:
	_hover_src = src
	_hover_index = index
	var entry := _hover_entry(src, index)
	# ★ 将领卡有两块：左侧主面板 + 右侧特性面板（`t` 为空 = 只有一块）。
	_show_card_hover(_card_hover_content(src, entry), _trait_panel_content(src, entry),
		src, index)


## 把一份悬停内容铺到面板上。
##
## ★★ 2026.11.19（用户口径）：「面板应当在卡牌**放大并移动稳定后**再出现」——
##   所以第一次出现要等 `CARD_HOVER_SHOW_DELAY`（牌的抬起 / 放大 / 邻牌让开总共
##   约 0.165s：`HOVER_RAISE_SEC 0.14 + 邻牌最迟 0.025`）。这段时间里：
##     · 鼠标换到别的牌 / 移开 → 计时作废（`_dismiss_hover` 会 kill）；
##     · 面板已经开着（同页换牌）→ **不等**，当场换内容与位置（牌在动，但面板按
##       「最终姿势」定位，本来就不会被正在变大的牌压到；再闪一下反而像坏了）。
## ★ 位置要的是「牌的**最终**姿势」：鼠标进入这一格的那一帧，牌还在从原位往上长、
##   邻牌还在从让开位回收 —— 读控件当前坐标会把面板算歪，最后就是「面板压在原卡上」。
##   所以走 `cell_pose_rect(i, true)`（见 ui_layout）。
## ★ 空字典 = 这一格没有说明（操作页那几条部队指令）⇒ 收起来。
func _show_card_hover(d: Dictionary, t: Dictionary, src: String, index: int) -> void:
	if card_hover == null:
		return
	if d.is_empty():
		_dismiss_hover()
		return
	# 已经开着：直接换内容 / 换位置，不重播出现动画，也不重新等。
	if card_hover.showing() or _trait_panel_showing():
		_cancel_hover_show()
		_apply_card_hover(d, t, src, index)
		return
	_cancel_hover_show()
	if not ThemeRes.animations_enabled():
		_apply_card_hover(d, t, src, index)
		return
	# 等牌站稳再弹（`tween_interval` + 回调；中途换牌 / 离开会 kill 掉它）。
	_hover_show_tween = create_tween()
	_hover_show_tween.tween_interval(CARD_HOVER_SHOW_DELAY)
	_hover_show_tween.tween_callback(
		_reveal_card_hover.bind(d.duplicate(true), t.duplicate(true), src, index))


## 延时到点：确认鼠标还停在同一格，再真正弹面板。
func _reveal_card_hover(d: Dictionary, t: Dictionary, src: String, index: int) -> void:
	_hover_show_tween = null
	if card_hover == null or card_hover.showing():
		return
	if src != _hover_src or index != _hover_index:
		return
	_apply_card_hover(d, t, src, index)


## 按「牌的最终姿势」把两块面板摆好：左 = 主面板，右 = 将领特性（`t` 空就收掉）。
func _apply_card_hover(d: Dictionary, t: Dictionary, src: String, index: int) -> void:
	var ctrl = _hover_cell_control(src, index)
	if ctrl == null:
		_dismiss_hover()
		return
	var rect: Rect2 = ctrl.cell_pose_rect(index, true)
	if not d.is_empty():
		card_hover.show_card(d, rect, view_size(), -1)
	if general_trait_panel != null:
		if t.is_empty():
			general_trait_panel.clear()
		else:
			general_trait_panel.show_card(t, rect, view_size(), 1)


func _trait_panel_showing() -> bool:
	return general_trait_panel != null and general_trait_panel.showing()


## 作废「等牌站稳再弹」那一段计时。
func _cancel_hover_show() -> void:
	if _hover_show_tween != null:
		if _hover_show_tween.is_valid():
			_hover_show_tween.kill()
		_hover_show_tween = null


## 某一格对应的控件（取「最终姿势矩形」用）。
func _hover_cell_control(src: String, index: int) -> Control:
	if src == "tech":
		return tech_grid if tech_grid != null else null
	return command_card if command_card != null else null


## 鼠标离开某一格。★ 只有「确实是我这一格」才收 —— 见 `_hover_src` 那段说明
## （enter / exit 的先后顺序不保证，无脑收会把刚弹出来的面板闪掉）。
func _on_hover_out(index: int, src: String) -> void:
	if src != _hover_src or index != _hover_index:
		return
	_dismiss_hover()


## 收起悬停面板（两块都收），并清掉「现在是谁弹的」那个记号
func _dismiss_hover() -> void:
	_hover_src = ""
	_hover_index = -1
	_cancel_hover_show()
	if card_hover != null:
		card_hover.clear()
	if general_trait_panel != null:
		general_trait_panel.clear()


# ------------------------------------------------------------------
# ★★ 手机端：长按 UI 格 = 显示悬停详情（见 `_lp_*` 那组字段）
#
#   手机没有「悬停」，所以要一个替身：按住某一格够久就弹详情，松手收起。
#   短按仍然是正常的激活（点下去 / 下命令）——两条路靠时间分开。
#   ⚠️ 手指按下的那一刻，emulate_mouse_from_touch 会让这一格**立刻**收到 mouse_entered；
#      所以这里在按下时给 command_card / tech_grid 打一个 `touch_suppress_hover`，
#      把「立刻弹」挡掉，等长按计时到了再自己调 `hover()`。
# ------------------------------------------------------------------

## ★★ 屏幕某点是不是落在 HUD 的可交互控件上（给 touch_controller 判「手势起点在不在 UI 上」）。
##
## ★ 与 `blocks_edge_scroll` 的区别：这里**不带**「屏幕最外圈永远放行」那条例外 ——
##   手势起点落在贴边的命令卡 / 部队列表上就该算 UI（不能从控件上起一次拖视野 / 框选）。
func point_hits_ui(global_pos: Vector2) -> bool:
	var vp := view_size()
	if ai_panel != null and ai_panel.visible and ai_panel.get_global_rect().has_point(global_pos):
		return true
	# ★★ 详细信息隐藏时，它那块区域恢复地图手势（命令卡 / 页签仍然算 UI）。
	# ★★ 右下角整块隐藏时（无操作建筑 / 敌方 / 友方任何建筑单位）卡与页签一起让路 ——
	#    屏幕上没东西可点。
	var detail_on := is_detail_visible()
	var cmd_on := _command_ui_visible()
	# ★★ 2026.11.19：X 收起后命令卡隐藏、但圆盘仍在 —— 圆盘自己也要吃掉点击。
	if page_tabs != null and page_tabs.visible \
			and page_tabs.get_global_rect().has_point(global_pos):
		return true
	var tabs_n: int = page_tabs.page_count() if cmd_on and page_tabs != null else 0
	if UiLayoutRes.point_hits_any(
			UiLayoutRes.interactive_rects(vp, detail_on, cmd_on, tabs_n), global_pos):
		return true
	return UiLayoutRes.point_hits_any(
		UiLayoutRes.bottom_bar_rects_v2(vp, detail_on, cmd_on), global_pos)


## 接收一个触摸事件（由 game_scene3d 在 `_input` 里转发）。
func handle_touch(event: InputEventScreenTouch) -> void:
	# ★★ 右侧将领标签优先：单击 / 双击 / 长按都由 squad_panel → input_ctrl 处理。
	#   命中标签时整串触摸（按下 + 抬起）都归它，不再走命令卡 / 科技格的长按详情。
	if squad_panel != null and squad_panel.handle_touch(event):
		return
	if event.pressed:
		# 新的一次触摸：清掉上一轮遗留的「吞掉激活」，并重置长按监视。
		_lp_active = false
		_lp_shown = false
		_lp_card_dragging = false
		_lp_src = ""
		_lp_index = -1
		_clear_buff_hover()
		var hit := _cell_at_screen(event.position)
		if hit.is_empty():
			return
		_lp_src = String(hit.get("src", ""))
		_lp_index = int(hit.get("index", -1))
		_lp_active = true
		_lp_press_ms = Time.get_ticks_msec()
		_lp_press_pos = event.position
		_lp_last_pos = event.position
		if _lp_src == "card" and command_card != null:
			command_card.begin_touch_drag(_lp_index, event.position)
		elif _lp_src == "tech" and tech_grid != null:
			tech_grid.begin_touch_drag(_lp_index, event.position)
		# 挡住「按下的模拟鼠标立刻弹详情」，并在按住期间先把上一块的详情收掉。
		_set_touch_suppress(true)
		_dismiss_hover()
		return
	# 抬起
	var was_shown: bool = _lp_shown
	var was_src: String = _lp_src
	var was_index: int = _lp_index
	var was_card_dragging: bool = _lp_card_dragging
	_set_touch_suppress(false)
	_lp_active = false
	_lp_shown = false
	_lp_card_dragging = false
	if was_src == "card" and command_card != null:
		if was_card_dragging:
			# _input 先于 Button 的模拟 mouse-up；延后一拍再派发拖牌动作。
			# ★★ 2026.11.14：把**手指最后的位置**一起带上 —— 操作牌「拖出松手 = 落点」，
			#   拿鼠标位置会打在屏幕上完全不相干的地方（触屏根本没有鼠标）。
			command_card.call_deferred("finish_touch_drag", was_index, _lp_last_pos)
		else:
			command_card.finish_touch_drag(was_index, _lp_last_pos)
	elif was_src == "tech" and tech_grid != null:
		if was_card_dragging:
			tech_grid.call_deferred("finish_touch_drag", was_index)
		else:
			tech_grid.finish_touch_drag(was_index)
	# ★★ 手机端「没有悬停」：手指一抬起，就把整个 HUD 的悬停**作废**（本轮修用户报的 bug）。
	#
	#   症状：手指移开后，游戏内某颗按钮（命令卡 / 页签 / 设置…）的金色填充还留着。
	#   成因与主菜单同一条：`emulate_mouse_from_touch` 的模拟鼠标**停在原地、不补发
	#   `mouse_exited`**，而 `fill_button` 在按下 / 抬起时把 `_hovered` 钉住 ⇒ 没人复位。
	#   ⚠️ 必须**延迟一帧**：Button 的 `button_up` 在 `_input` 之后才跑，同步清会被钉回去。
	#   与「常驻满格（latched）」互不干扰：选项页开着时那颗按钮是 latched，不会因此暗掉。
	call_deferred("_clear_hud_hover")
	if was_shown:
		_dismiss_hover()
		_clear_buff_hover()
		# 长按只打开说明；手牌现在必须上拖松手才会打出，不会有触摸释放误激活。


## 触摸抬起之后清整棵 HUD 的悬停（延迟一帧调用）。
func _clear_hud_hover() -> void:
	FillButtonRes.clear_hover_in(self)


## 手指在 UI 上滑动：动得够远就取消这次长按（那是想拖动 / 划走，不是想看详情）。
func handle_touch_drag(event: InputEventScreenDrag) -> void:
	# ★ 将领标签：滑走超过阈值 → 取消这次标签按住（单击 / 长按都不再触发）。
	if squad_panel != null:
		squad_panel.handle_touch_drag(event)
	if (_lp_active or _lp_card_dragging) and not _lp_shown \
			and (_lp_src == "card" or _lp_src == "tech"):
		var dragging := false
		if _lp_src == "card" and command_card != null:
			dragging = command_card.move_touch_drag(_lp_index, event.position)
			_lp_last_pos = event.position
		elif _lp_src == "tech" and tech_grid != null:
			dragging = tech_grid.move_touch_drag(_lp_index, event.position)
		if dragging:
			_lp_card_dragging = true
			_lp_active = false
			_lp_shown = false
			_dismiss_hover()
			return
		var pan_threshold := cfg.touch_pan_min_px if cfg != null else 12.0
		if event.position.distance_to(_lp_press_pos) > pan_threshold:
			_lp_active = false
			_lp_last_pos = event.position
			if _lp_src == "card" and command_card != null:
				command_card.finish_touch_drag(_lp_index, _lp_last_pos)
			elif _lp_src == "tech" and tech_grid != null:
				tech_grid.finish_touch_drag(_lp_index)
		return
	if not _lp_active or _lp_shown:
		return
	if event.position.distance_to(_lp_press_pos) > cfg.touch_pan_min_px:
		_lp_active = false
		_set_touch_suppress(false)
		_clear_buff_hover()


## 每帧推进长按计时（在 `_process` 里调）。
func _tick_long_press() -> void:
	if not _lp_active or _lp_shown or cfg == null:
		return
	if Time.get_ticks_msec() - _lp_press_ms < int(cfg.touch_long_press_sec * 1000.0):
		return
	_lp_shown = true
	if _lp_src == "buff":
		var bb = _buff_bar()
		if bb != null:
			bb.hover_at(_lp_index)
	elif _lp_src == "tech" and tech_grid != null:
		tech_grid.hover(_lp_index)
	elif command_card != null:
		command_card.hover(_lp_index)


## 让命令卡 / 科技格 / buff 条「暂时忽略鼠标进入」——手机端按下的那一刻先别弹详情。
func _set_touch_suppress(on: bool) -> void:
	if command_card != null:
		command_card.touch_suppress_hover = on
	if tech_grid != null:
		tech_grid.touch_suppress_hover = on
	var bb = _buff_bar()
	if bb != null:
		bb.touch_suppress_hover = on
		if on:
			bb.clear_hover()


## 屏幕点落在哪一格上：`{"src": "card"/"tech"/"buff", "index": i}`；不在任何格上时返回空字典。
## ★ 科技页盖在命令卡上，所以在显示时优先判它（与它 `mouse_filter` 的优先级一致）。
## ★ buff 条在详细信息右栏里，不与命令卡 / 科技格重叠；放在最前判只是让它先命中。
func _cell_at_screen(pos: Vector2) -> Dictionary:
	var bb = _buff_bar()
	if bb != null and bb.visible:
		for i in bb.count():
			if bb.buff_global_rect(i).has_point(pos):
				return {"src": "buff", "index": i}
	if tech_grid != null and tech_grid.visible:
		var ti := _cell_index_at(tech_grid, pos)
		if ti >= 0:
			return {"src": "tech", "index": ti}
	if command_card != null:
		var ci := _cell_index_at(command_card, pos)
		if ci >= 0:
			return {"src": "card", "index": ci}
	return {}


func _cell_index_at(grid: Control, pos: Vector2) -> int:
	for i in UiLayoutRes.CARD_SLOTS:
		var cell: Control = grid.cell_at(i)
		if cell != null and cell.get_global_rect().has_point(pos):
			return i
	return -1


## 详细信息右栏里的 buff 条（没有 / 还没建时返回 null）
func _buff_bar():
	return detail_panel.buff_bar_control() if detail_panel != null else null


## 收起 buff 的悬停浮窗（手机松手 / 拖动取消时用）
func _clear_buff_hover() -> void:
	var bb = _buff_bar()
	if bb != null:
		bb.clear_hover()


## 悬停到的那一格数据。命令卡与科技九格是**两份不同形状**的 entries，所以按来源取。
func _hover_entry(src: String, index: int) -> Dictionary:
	if src == "tech":
		return tech_grid.entry_at(index) if tech_grid != null else {}
	return command_card.entry_at(index) if command_card != null else {}


## 某一格的悬停内容：`{name, tag, cost, traits, desc, note}`；
## **空字典 = 这一格没有说明**（不弹面板）。
##
## 覆盖的几类（就是需求点的那四样 + 兜底）：
##   · **单位**   → `recruit`（单位页那几张兵种牌）/ `zone_recruit`（区划招募抽的一手）
##   · **将领**   → `general_drag`（将领页拖到区划中心的那张牌）
##   · **建筑**   → `build`（建筑页的可建建筑）
##   · **科技**   → 科技牌（那份数据没有 `type`，按 `src == "tech"` 分派）
##   · **兜底**   → 大本营升级 / 建造操作这类：名称 + 造价 + 一句结果/说明
func _card_hover_content(src: String, entry: Dictionary) -> Dictionary:
	if entry.is_empty():
		return {}
	if src == "tech":
		return _hover_tech(entry)
	match String(entry.get("type", "")):
		"build":
			return _hover_build(entry)
		"base_upgrade":
			return _hover_base_upgrade(entry)
		"recruit", "zone_recruit":
			# ★ 选中区划中心时「将领」页的牌也是 `zone_recruit` —— 按 kind 分到将领那一档。
			if ConfigRes.general_index_of(String(entry.get("unit_kind", ""))) >= 0:
				return _hover_general(entry)
			return _hover_recruit(entry)
		"general_drag":
			return _hover_general(entry)
		"building_upgrade", "building_upgrade_cancel", "building_upgrade_max", \
				"building_respawn", "building_demolish":
			return _hover_building(entry)
	return {}


## 一份悬停内容：`{name, tag, cost, traits, desc, note}`
## —— 画法在 `view/card_hover_panel.gd`，本函数只负责「写什么」。
##   @param cost   造价格 `[{label, value}]`（空数组 = 不画那一排，科技就是这样）
##   @param traits 特性胶囊文字（空数组 = 连小标题一起不画；只有将领有）
##   @param desc   一句短描述（占位：见 `_unit_brief` / `_general_brief` 的注释）
##   @param note   置灰原因（空串 = 不画）
func _hover_data(name: String, tag: String, cost: Array = [], traits: Array = [],
		desc: String = "", note: String = "") -> Dictionary:
	return {"name": name, "tag": tag, "cost": cost, "traits": traits,
		"desc": desc, "note": note}


## 条目里那一小份造价（招募表带过来的；缺了就是空 → 写成「免费」）
func _entry_cost(entry: Dictionary) -> Dictionary:
	var v: Variant = entry.get("cost", {})
	return v if typeof(v) == TYPE_DICTIONARY else {}


## 造价 → 悬停面板的紧凑「标签 + 数值」串（面板上一横排，不再是四个大格子）。
## ★ 只列真正花的那一两项（0 金不占位）；都不花 = 一格「免费」。
func _cost_pairs(cost: Dictionary) -> Array:
	var out: Array = []
	var food := float(cost.get("food", 0.0))
	if food > 0.0:
		out.append({"label": "粮食", "value": _fmt_num(food)})
	var gold := float(cost.get("gold", 0.0))
	if gold > 0.0:
		out.append({"label": "黄金", "value": _fmt_num(gold)})
	if out.is_empty():
		out.append({"label": "造价", "value": "免费"})
	return out


## 兵种名的**一行写法**：近战步兵 / 远程步兵 / 近战骑兵 / 远程骑兵 / 器械。
## ★ 与 `cfg.unit_class_line()` 只差「近战」二字：那条对近战只写「步兵」，
##   而悬停这一行要一眼看出远近（用户示例：「70粮 近战步兵 …」）。
##   大类名仍然取 config（`unit.classes.<id>.name`），代码里不另抄一份「步兵 / 骑兵」。
func _class_short(ut: String) -> String:
	if not cfg.has_unit_type(ut):
		return ""
	var cls: String = cfg.unit_class_of(ut)
	var cls_name: String = cfg.class_display_name(cls)
	if cls == ConfigRes.CLASS_SIEGE:
		return cls_name                    # 器械不分远近
	return ("远程" if cfg.unit_is_ranged(ut) else "近战") + cls_name


## 这一格要介绍的**兵种 id 列表**（一般就一个；组合条目是多个）。
## ★ 组合条目的 `kind` 是**组合 id**（`dy_guard` 等），不是兵种 id ——
##   直接拿去查 `unit_type_of()` 会退到兜底兵种，写出来的兵种 / 特性全是错的。
##   所以先看 `spawn`（与 `_recruit_icon_type()` 同一条口径）。
func _unit_types_of(entry: Dictionary) -> Array:
	var out: Array = []
	var spawn: Variant = entry.get("spawn")
	if typeof(spawn) == TYPE_ARRAY:
		for it in (spawn as Array):
			if typeof(it) != TYPE_DICTIONARY:
				continue
			var t := String((it as Dictionary).get("type", ""))
			if t != "" and not out.has(t):
				out.append(t)
	if out.is_empty():
		var one: String = cfg.unit_type_of(String(entry.get("unit_kind", "")))
		if one != "":
			out.append(one)
	return out


## 这一格现在**不能招**的一句话原因（能招时返回空串 ⇒ 悬停只剩「消费 + 特性」）。
## ★ 置灰的格子点下去什么都不发生，悬停是玩家唯一能知道「为什么」的地方 ——
##   所以只有这一档才多写一句（用户口径「非必要不写」里那个「必要」就是它）。
func _unit_lock_note(entry: Dictionary) -> String:
	var is_zone := String(entry.get("type", "")) == "zone_recruit" \
		or String(entry.get("type", "")) == "general_drag"
	if is_zone:
		match String(entry.get("lock_reason", "")):
			"owned": return "已拥有"
			"tier": return "阶数不足"
			"cap": return "将领已满"
			"cooldown": return "冷却中"
		return ""
	if not bool(entry.get("ready", true)):
		return "需%s级大本营" % _fmt_num(float(entry.get("min_base", entry.get("tier", 1))))
	return ""


## ★★ 2026.11.19：建筑页的大本营牌 —— 造价 + 升到几级 + 为什么不能升。
func _hover_base_upgrade(entry: Dictionary) -> Dictionary:
	var base = world.find_base_of(String(world.my_faction)) if world != null else null
	var title := String(entry.get("name", "大本营"))
	if base == null:
		return _hover_data(title, "升级", [], [], "把这张牌拖到己方大本营上升级",
			"大本营不存在")
	var chips: Array = ["升到%d级" % (int(base.level) + 1)]
	var note := ""
	if not bool(entry.get("ready", true)):
		note = _upgrade_reject_text(String(entry.get("lock_reason", "")), base)
	var d := _hover_data(title, "升级", _cost_pairs(world.building_upgrade_cost(base)),
		chips, "把这张牌拖到己方大本营上升级", note)
	d["caption"] = "结 果"
	return d


## 建筑（建筑页那几格：木墙 / 哨塔 / 石墙 / 警戒塔）—— 造价 + 一句说明。
## ★ 说明优先取 `building.<type>.brief`（2026.11.19 新增的简述字段；占位阶段可以是空的），
##   没写就退回原来那句长的 `desc`。
func _hover_build(entry: Dictionary) -> Dictionary:
	var t := String(entry.get("build_type", ""))
	var cost: Variant = cfg.get_path_value("building.%s.cost" % t)
	var note := ""
	if not bool(entry.get("ready", true)):
		# ★ 用 `min_base`（教堂 = 1）—— 写 tier 的话会显示「需 3 级大本营」，
		#   而它其实开局就能造。
		note = "需%s级大本营" % _fmt_num(float(entry.get("min_base", entry.get("tier", 1))))
	return _hover_data(String(entry.get("name", "")), "建筑",
		_cost_pairs(cost if typeof(cost) == TYPE_DICTIONARY else {}), [],
		_building_brief(t), note)


## 建筑的简述：作者写的 `brief` 优先，否则用原来的 `desc`（占位阶段就这样）。
func _building_brief(t: String) -> String:
	if cfg == null:
		return ""
	var brief := _config_text("building.%s.brief" % t)
	if brief.strip_edges() != "":
		return brief
	return _config_text("building.%s.desc" % t)


## 招募：单位页那几个兵种（`recruit`）+ 区划招募抽的一手（`zone_recruit`）。
## ★ 类别标签 = 兵种名（`近战·骑兵`）；组合条目先写「×N」再列这一包的兵种。
## ★ 单位**不显示特性胶囊**（需求只要「名称 + 造价 + 标签 + 简述」）——
##   特性折进那一句简述里（见 `_unit_brief`）。
func _hover_recruit(entry: Dictionary) -> Dictionary:
	var kind := String(entry.get("unit_kind", ""))
	var types: Array = _unit_types_of(entry)
	return _hover_data(String(entry.get("name", "")), _tag_of_types(types),
		_cost_pairs(_entry_cost(entry)), [], _unit_brief(types, kind),
		_unit_lock_note(entry))


## 将领牌（`general_drag` / 区划里的将领）：左侧主面板只写名称 + 造价 + 简述。
## ★ 2026.11.19（用户口径）：特性**不再挤在主面板里**，改由右侧那块
##   `general_trait_panel` 单独展示（见 `_trait_panel_content`）。
func _hover_general(entry: Dictionary) -> Dictionary:
	var kind := String(entry.get("unit_kind", ""))
	var types: Array = _unit_types_of(entry)
	return _hover_data(String(entry.get("name", "")), "将领",
		_cost_pairs(_entry_cost(entry)), [],
		_general_brief(types, kind), _unit_lock_note(entry))


## 将领卡右侧那块「将领特性」面板的内容：`{rows: [{name, desc}]}`。
## **空字典 = 不弹**（不是将领 / 这位将领没有特性 / 是科技牌）。
func _trait_panel_content(src: String, entry: Dictionary) -> Dictionary:
	if entry.is_empty() or src == "tech":
		return {}
	if ConfigRes.general_index_of(String(entry.get("unit_kind", ""))) < 0:
		return {}
	var rows := _general_trait_rows(String(entry.get("unit_kind", "")))
	if rows.is_empty():
		return {}
	return {"rows": rows}


## 一位将领的特性清单：`[{name, desc}]`（数据源 `unit.general.trait_ids` ⊕
## `unit.general_traits.<id>`，与实战读的是同一份）。
func _general_trait_rows(kind: String) -> Array:
	var out: Array = []
	if cfg == null:
		return out
	var gidx: int = ConfigRes.general_index_of(kind)
	if gidx < 0:
		return out
	for tid in cfg.general_traits_at(gidx):
		var id := String(tid)
		var nm: String = cfg.general_trait_name(id)
		if nm == "":
			continue
		out.append({"name": nm, "desc": cfg.general_trait_desc(id)})
	return out


## 兵种标签那一行：`近战·骑兵` / `×3 近战·步兵 · 远程·步兵`。
func _tag_of_types(types: Array) -> String:
	var tags: Array = []
	for t in types:
		var cls: String = _class_short(String(t))
		if cls == "":
			continue
		# 「近战骑兵」→「近战·骑兵」；「器械」不分远近，原样留着
		if cls.begins_with("近战"):
			cls = "近战·" + cls.substr(2)
		elif cls.begins_with("远程"):
			cls = "远程·" + cls.substr(2)
		if not tags.has(cls):
			tags.append(cls)
	var sub := " · ".join(tags)
	if types.size() > 1:
		sub = "×%d %s" % [types.size(), sub]
	return sub


## 一个兵的**一句简述**（占位阶段的写法：兵种 + 特性方向）。
##
## ★★ 文案来源顺序：
##   ① `unit.types.<id>.brief` —— 2026.11.19 新增的简述字段（编辑器以后暴露；
##      用户口径「先用占位文本，后续在编辑器中暴露出来字段」）；
##   ② 没写 → 自动拼一句占位：「近战骑兵；对步兵造成额外伤害，受远程伤害减少。」
##      （与用户给的示例「信念坚定的战士，对骑兵造成额外伤害，对近战减伤」同一句式）。
## ★ 自动拼的部分只写**方向**、不带数值 —— 数值平衡一动，文案就过时了。
func _unit_brief(types: Array, kind: String) -> String:
	if types.is_empty():
		return ""
	if types.size() > 1:
		return "一支混编部队：%s。" % _tag_of_types(types)
	var ut := String(types[0])
	if cfg == null or not cfg.has_unit_type(ut):
		return ""
	var authored := _config_text("unit.types.%s.brief" % ut)
	if authored.strip_edges() != "":
		return authored
	var cls: String = _class_short(ut)
	var phrases: Array = []
	var tr: Dictionary = cfg.unit_traits_of(ut)
	var vs: Variant = tr.get("attack_vs_class", {})
	if typeof(vs) == TYPE_DICTIONARY:
		var classes: Array = (vs as Dictionary).keys()
		classes.sort()
		for c in classes:
			if float((vs as Dictionary)[c]) > 0.0:
				phrases.append("对%s造成额外伤害" % cfg.class_display_name(String(c)))
	if float(tr.get("ranged_reduction", 0.0)) > 0.0:
		phrases.append("受远程伤害减少")
	if float(tr.get("melee_reduction", 0.0)) > 0.0:
		phrases.append("受近战伤害减少")
	if bool(tr.get("knockback_immune", false)):
		phrases.append("免疫击退")
	if phrases.is_empty():
		return "%s。" % cls if cls != "" else ""
	# ★ 用「，」不用「；」：面板只有 300 宽，折行时「；」会让第一行只剩半句。
	return "%s，%s。" % [cls, "，".join(phrases)]


## 将领本人的特性名（胶囊）。★ 只取 `general_traits`，不掺兵种特性。
func _general_trait_names(kind: String) -> Array:
	var out: Array = []
	if cfg == null:
		return out
	var gidx: int = ConfigRes.general_index_of(kind)
	if gidx < 0:
		return out
	for tid in cfg.general_traits_at(gidx):
		var nm: String = cfg.general_trait_name(String(tid))
		if nm != "" and not out.has(nm):
			out.append(nm)
	return out


## 将领的一句简述（占位写法：兵种 + 一句风味）。
##   ★ `unit.general.brief`（按将领序号）写了就优先用。
##   ★ 2026.11.19：特性已经搬到右侧专门的「将领特性」面板，这里**不再罗列特性名**
##     （否则同一块屏上写两遍）。
func _general_brief(types: Array, kind: String) -> String:
	if cfg == null:
		return ""
	var gidx: int = ConfigRes.general_index_of(kind)
	if gidx >= 0:
		var authored := _config_text("unit.general.brief.%d" % gidx)
		if authored.strip_edges() != "":
			return authored
	var cls := _class_short(String(types[0])) if not types.is_empty() else ""
	if cls == "":
		return "身经百战的将领。"
	return "身经百战的%s将领。" % cls


## 建筑操作那一格（升级 / 取消 / 已满级 / 重生中 / 拆除）—— 造价 + 一句结果。
func _hover_building(entry: Dictionary) -> Dictionary:
	var b = _primary_building()
	if b == null and input_ctrl != null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	var title := String(entry.get("name", ""))
	if b == null:
		return _hover_data(title, "操作")
	var d := {}
	match String(entry.get("type", "")):
		"building_upgrade":
			d = _hover_data(title, "升级", _cost_pairs(world.building_upgrade_cost(b)),
				["升到%d级" % (b.level + 1)], "")
		"building_upgrade_cancel":
			d = _hover_data(title, "取消升级", _cost_pairs(
					{"food": b.upgrade_cost_food, "gold": b.upgrade_cost_gold}),
				["全额退还"], "")
		"building_respawn":
			d = _hover_data(title, "重生中", [], ["重生队列 %d 位" % b.respawn_count()], "")
		"building_upgrade_max":
			return _hover_data(title, "已满级", [], [], "已经升到当前上限。")
		"building_demolish":
			d = _hover_data(title, "拆除", [], ["建筑移除"],
				"把卡牌拖到地图上松手；不返还建造资源")
		_:
			return _hover_data(title, "操作")
	d["caption"] = "结 果"
	return d


## 科技牌 —— 名称 + 一句说明（科技不花资源，所以没有造价那一排）。
## ★ 说明用 config 里那句 `desc`（如「玩家总体粮食产能 +10%」）；
##   已启用 / 不可取消写在 note 里。
func _hover_tech(entry: Dictionary) -> Dictionary:
	var desc := String(entry.get("desc", ""))
	if desc.strip_edges() == "":
		desc = String(entry.get("line", ""))
	return _hover_data(String(entry.get("name", "")), "科技", [], [], desc,
		_tech_lock_note(entry))


## 这条科技现在**启不了**的一句话原因（能启时返回空串）。
## ★ 与招募格同一条口径：灰色格子点下去没反应，悬停是唯一能说明原因的地方，
##   所以只有这一档多写一句。
func _tech_lock_note(entry: Dictionary) -> String:
	if world != null and world.is_tech_active(String(entry.get("id", ""))):
		return "已启用（不可取消）"
	if bool(entry.get("available", true)):
		return ""
	match String(entry.get("reason", "")):
		"tier":
			return "需高阶大本营"
		"limit":
			return "名额已满"
		"played":
			return "已启用（不可取消）"
		"destroyed":
			return "已销毁"
	return "不可启用"


## 大本营某一级的四条限制（给详情栏用）。
func _base_limits_text(level: int) -> String:
	if cfg == null:
		return ""
	var g: int = cfg.upgrade_limit("base", level, "max_generals", 0)
	var bonus: int = cfg.upgrade_limit("base", level, "retinue_cap_bonus", 0)
	var t: int = cfg.upgrade_limit("base", level, "max_techs", 0)
	var tier: int = cfg.upgrade_limit("base", level, "max_tech_tier", 0)
	return "将领上限 %d · 编制 %+d · 科技 %d 个（最高 %d 阶）" % [g, bonus, t, tier]


## ★★ 2026.10.26 建筑页内容：与单位页同一套「按行解锁」。
##   行号 = `building.<type>.tier`（1 = 1 级大本营，2 = 2 级大本营）。
##   ★★ 2026.10.30：同一行内可以用 `building.<type>.slot`（1..3）指定列；
##   没写的按 config 顺序自动补空位。不足 3 个的格子留空字典；
##   未解锁的格子 `ready = false`（command_card 置灰）。
func _build_entries() -> Array:
	var slots: Array = []
	for _i in UiLayoutRes.CARD_SLOTS:
		slots.append({})
	if cfg == null:
		return slots
	# ★★ 2026.11.19（用户口径）：大本营牌固定在建筑页第 1 格（Q）。
	#   拖到己方大本营上 = 升级；大本营满级（默认 3 级）后这张牌从手牌移除。
	var base = null
	var base_show := false
	var base_cap := 3
	if world != null:
		base = world.find_base_of(String(world.my_faction))
		if base != null:
			base_cap = world.building_level_cap(base)
			base_show = int(base.level) < base_cap
	if base_show:
		var why: String = world.building_upgrade_reason(base, world.my_faction)
		slots[0] = {
			"type": "base_upgrade",
			"name": String(base.display_name()),
			"desc": "拖到己方大本营上升级（%d → %d 级）" % [
				int(base.level), int(base.level) + 1],
			"icon_mask": UnitCardIconRes.mask_for_building(String(base.type)),
			"tier": 1,
			"min_base": 1,
			"base_level": int(base.level),
			"ready": why == "",
			"lock_reason": why,
		}
	# ① 按 tier 分组（组内保持 config 顺序）。
	var rows: Dictionary = {}
	# ★★ 2026.11.18：建筑页按**派系**过滤 —— 教堂只有「帝国·教会军」有这张牌，
	#   其余派系根本看不到它（而不是「看得到、点下去被拒」）。
	var bclan := ""
	if world != null:
		bclan = String(world.clan_of(String(world.my_faction)))
	for d in cfg.buildable_building_defs_for(bclan):
		var e: Dictionary = d
		var bid := String(e.get("id", ""))
		# ★★ 2026.11.19（用户口径）：城墙不再出现在建筑页 —— 木墙 / 石墙只能由
		#   战役编辑器预先摆放，玩家和 AI 都没有建造入口。
		if BuildingRes.is_wall_type(bid):
			continue
		var tier := clampi(cfg.building_tier(bid), 1, 3)
		if not rows.has(tier):
			rows[tier] = []
		(rows[tier] as Array).append(e)
	# ② 每一行：先放显式 slot，再按 config 顺序补空位。
	for tier_v in rows.keys():
		var tier := int(tier_v)
		var row_start: int = (tier - 1) * 3
		var list: Array = rows[tier]
		var used: Dictionary = {}
		if base_show and tier == 1:
			used[0] = true             # Q 格被大本营牌占住
		var explicit: Dictionary = {}
		for d in list:
			var e: Dictionary = d
			var bid := String(e.get("id", ""))
			var col := cfg.building_slot(bid)
			if col < 1 or col > 3:
				continue
			var idx: int = row_start + col - 1
			if idx < row_start or idx >= row_start + 3 or idx >= UiLayoutRes.CARD_SLOTS:
				continue
			if base_show and idx == 0:
				continue               # Q 让给大本营牌
			if used.has(idx):
				continue                 # 同一格重复写：先到先得，后来者走自动补位
			used[idx] = true
			explicit[bid] = true
			# ★★ 2026.11.18：解锁等级读 `min_base`（缺省 = tier）—— 教堂写 `tier: 3` 只是因为
			#   它要占第 3 行那个空位，真正的解锁等级是 1（开局就能造）。见 cfg.building_min_base()。
			slots[idx] = _build_entry(e, bid, tier, cfg.building_min_base(bid))
		var cursor: int = row_start
		for d in list:
			var e: Dictionary = d
			var bid := String(e.get("id", ""))
			if explicit.has(bid):
				continue
			while cursor < row_start + 3 and used.has(cursor):
				cursor += 1
			# 一行最多 3 个：多出来的不画（不静默挤到下一行）。
			if cursor >= row_start + 3 or cursor >= UiLayoutRes.CARD_SLOTS:
				continue
			used[cursor] = true
			slots[cursor] = _build_entry(e, bid, tier, cfg.building_min_base(bid))
			cursor += 1
	var level: int = world.unit_recruit_level(world.my_faction) if world != null else 1
	for i in slots.size():
		var s: Dictionary = slots[i]
		if s.is_empty():
			continue
		# 大本营牌的 ready / 锁定原因按「这一栋现在能不能升」算，不走 tier 解锁。
		if String(s.get("type", "")) == "base_upgrade":
			continue
		s["base_level"] = level
		# ★ 解锁判定用 `min_base`（教堂 = 1），而不是「画在第几行」。
		s["ready"] = int(s.get("min_base", s.get("tier", 1))) <= level
		if not bool(s["ready"]):
			s["lock_reason"] = "tier"
	return slots


## 建筑页的一格（名字 / 说明 / tier / 图标）；具体落在哪一格由 `_build_entries()` 决定。
## @param tier      排版用的行号（决定画在第几行）
## @param min_base  解锁所需的大本营等级（缺省 = tier；教堂 = 1）
func _build_entry(e: Dictionary, bid: String, tier: int, min_base: int = -1) -> Dictionary:
	return {
		"type": "build",
		"build_type": bid,
		"name": String(e.get("name", "")),
		# ★★ 建筑图标：从 .glb 抽边线烘出来的等轴测线稿（见 tools/bake_unit_card_icon.py
		#   的「建筑」那一段）。格子排版和单位页一致：图标 + 一行名字，说明进悬停面板。
		"icon_mask": UnitCardIconRes.mask_for_building(bid),
		"desc": String(e.get("desc", "")),
		"tier": tier,
		"min_base": tier if min_base < 0 else min_base,
	}


## ★★ 单位页那一页的「读条 X 秒」= **招兵这位将领**的招兵读条（见 world.leader_recruit_sec）：
##   2026.11.2 起兵种自己不再有读条时间，队列长短 / 兵种构成都不影响它。
## 没选中将领 / 没有 world ⇒ 退回 `leader_recruit_sec(null)` 的默认值（10 秒）。
func _unit_recruit_sec() -> float:
	if world == null:
		return 0.0
	var leader = input_ctrl.first_selected_leader() if input_ctrl != null else null
	return world.leader_recruit_sec(leader)


## 把一张招募表（本派系的单位表 / 全局的区划招将表）翻成命令卡的条目。
## @param entry_type 抛给 hud._on_card_entry 的动作类型（"recruit" = 排进将领 / "zone_recruit" = 排进区划）
## @param list       ★★ 2026.11：**表本身**由调用方给（不再让本函数自己去 config 按路径取）——
##                   单位页要的是「这一方派系」的表（`world.recruit_list(my_faction)`），
##                   而派系解析在 world / config 那一侧，视图不该自己拼路径。
##
## ★★ 单位页现在是**三行按大本营等级解锁**（需求）：
##   `tier` = 行号 = 需要的大本营等级。这里按 tier 把条目摆到
##   `(tier - 1) * 3 + 行内序号` 的格子里；某一行不满 3 个就**留空**（空字典）。
##   命令卡那边（view/command_card.gd）把空字典当空格子画，不显示名字、点了不做事。
##
## ★ 为什么不在 config 的 list 里塞空占位条目：那会凭空多出「兵种」，
##   单位编辑器 / 招募队列 / 测试都会把它当真。空格子只在**视图这一层**存在。
func _recruit_entries(entry_type: String, list: Variant) -> Array:
	var slots: Array = []
	for _i in UiLayoutRes.CARD_SLOTS:
		slots.append({})
	if typeof(list) != TYPE_ARRAY:
		return slots
	# 每一行下一个空位（缺省 = 该行第一格）—— 同一行按 config 顺序从左到右。
	var next_slot: Dictionary = {}
	for item in (list as Array):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = item
		var tier := clampi(int(e.get("tier", 1)), 1, 3)
		var row_start: int = (tier - 1) * 3
		var col: int = int(next_slot.get(tier, row_start))
		# 一行最多 3 个：多出来的**不画**（不静默挤到下一行）。
		if col < row_start or col >= row_start + 3 or col >= UiLayoutRes.CARD_SLOTS:
			continue
		next_slot[tier] = col + 1
		var icon_type := _recruit_icon_type(e)
		# ★★ 组合条目（一次出 2 / 3 个兵）用**它自己那张**蒙版：几个小人已经按
		#   「o o」/「o + o o」摆好烘在图里了（见 tools/bake_unit_card_icon.py 的
		#   `combo_boxes()`）。没有组合蒙版时退回「第一个兵种」那张单兵图。
		var combo_mask := UnitCardIconRes.mask_for_combo(String(e.get("kind", "")))
		slots[col] = {
			"type": entry_type,
			"unit_kind": String(e.get("kind", "")),
			"name": String(e.get("label", e.get("kind", ""))),
			# ★★ 这一格画哪张**图标**（需求：「招募单位的按钮内的文字改为图标」）。
			#   主路径是 `icon_mask`（该兵种原画烘出来的金线蒙版，见
			#   view/unit_card_icon.gd 与 tools/bake_unit_card_icon.py）；
			#   `icon_role` 是蒙版缺失时的矢量兜底。
			#   ★ 两张都由本层算好再塞进条目：命令卡不认识「兵种 / 原画 / 蒙版目录」
			#     这三件事，它只收路径字符串。
			"icon_mask": combo_mask if combo_mask != "" \
				else UnitCardIconRes.mask_for_unit(cfg, icon_type),
			"icon_role": UnitCardIconRes.role_of(cfg, icon_type),
			"desc": String(e.get("desc", "")),
			# ★★ 悬停详情要用的字段，一并带在条目里（见 `_hover_recruit`）：
			#   两张招募表（recruit.list / recruit.zone.list）字段名一样，
			#   所以「单位页」与「招募页」的详情共用同一段代码，不各写一份。
			#   ★★ 2026.11：单位页的价钱走 `world.recruit_cost_for()` —— 派系科技会改价
			#     （礼乐：金转粮 / 圈地制：金打七折），**将领光环的「招募骑兵 -25%」也在这里**，
			#     **显示价必须与实扣价同源**，否则悬停写 50 金、实际扣 37.5 金。
			#     区划招将页不受这些影响，仍是原值。
			"cost": world.recruit_cost_for(String(e.get("kind", "")), world.my_faction,
					input_ctrl.first_selected_leader() if input_ctrl != null else null) \
				if (world != null and entry_type == "recruit") else e.get("cost", {}),
			# ★★ 2026.11.2：单位页的读条时长**不是兵种的属性**，而是「招兵那位将领」的
			#   招兵读条（world.leader_recruit_sec）。区划招将页才读条目自己的 train_sec。
			"train_sec": _unit_recruit_sec() if entry_type == "recruit" \
				else e.get("train_sec", 0.0),
			"population_cost": e.get("population_cost", 0),
			# ★ 组合条目（一包 2~3 个兵）的清单：悬停那一行要按**真正生成的兵种**
			#   取兵种与特性（见 `_unit_types_of`），不能拿组合 id 去查兵种表。
			"spawn": e.get("spawn", []),
			"tier": tier,
		}
	# ★★ 行号解锁状态：由**权威侧**的 `unit_recruit_level` 算（没有大本营按 1 级）。
	#   不可招募的格子 `ready = false` → 命令卡置灰；悬停写原因。
	var level: int = world.unit_recruit_level(world.my_faction) if world != null else 1
	for i in slots.size():
		var d: Dictionary = slots[i]
		if d.is_empty():
			continue
		d["base_level"] = level
		d["ready"] = int(d.get("tier", 1)) <= level
		if not bool(d["ready"]):
			d["lock_reason"] = "tier"
	# ★★ 2026.11.14：招募即时化之后**没有队列了** —— 原来挂在格子上的
	#   「读条进度 / ×N 角标」整块删掉（拖出一张牌 = 兵当场出来）。
	return slots


## 招募条目 → 拿哪个**兵种 id** 去取图标。
##
## ★ 组合条目（协防军一包 2 人 / 御林军一包 3 人）取**第一个生成兵种**的图形当作
##   这一包的「脸」；整包到底出哪几个兵写在悬停详情面板里（见 `_hover_recruit`）。
##   ⚠️ 不能直接拿 `kind`：`dy_guard` / `dy_royal` 是**组合条目的 id**，不是兵种 id
##      （`cfg.unit_type_of("dy_guard")` 会退到兜底兵种，画出来的图标就是错的）。
func _recruit_icon_type(e: Dictionary) -> String:
	var spawn: Variant = e.get("spawn")
	if typeof(spawn) == TYPE_ARRAY and not (spawn as Array).is_empty():
		var first: Variant = (spawn as Array)[0]
		if typeof(first) == TYPE_DICTIONARY:
			var t := String((first as Dictionary).get("type", ""))
			if t != "":
				return t
	return String(e.get("kind", ""))


## ★★ 招募页的内容：**固定九宫格**（#1-9）+ 每位将领的阶数 / 已拥有 / 冷却状态。
##
## ★ 与单位页的区别：单位页读 config 的那张固定表；招募页读的是**权威状态**
##   （`world.general_recruit_state`：已拥有、阶数、将领上限、全局冷却）。
## ★ 不可招募的格子 `ready = false` → `command_card` 把按钮置灰；悬停时
##   `fill_button` 自动填**灰色**（与科技锁定格同一套灰档），详情写明原因。
## ★ 每条带上 `recruit_cooldown_sec`（这位将领自己的属性）与 `cooldown_left`（全局剩余）。
func _zone_recruit_entries() -> Array:
	var out: Array = []
	if world == null:
		return out
	# ★★ 2026.11.14（用户口径）：招走的那位**从牌面上消失**（见 world.general_recruit_available）
	for kind_v in world.general_recruit_available(world.my_faction):
		var kind := String(kind_v)
		var e: Dictionary = world.recruit_entry(kind)
		if e.is_empty():
			continue
		var s: Dictionary = world.general_recruit_state(world.my_faction, kind)
		out.append({
			"type": "zone_recruit",
			"unit_kind": kind,
			"name": String(e.get("label", kind)),
			"desc": String(e.get("desc", "")),
			"tier": int(s.get("tier", 1)),
			"owned": bool(s.get("owned", false)),
			"lock_reason": String(s.get("reason", "")),
			"base_level": int(s.get("base_level", 0)),
			"cost": e.get("cost", {}),
			"train_sec": e.get("train_sec", 0.0),
			"population_cost": e.get("population_cost", 0),
			"recruit_cooldown_sec": float(e.get("recruit_cooldown_sec", 0.0)),
			"cooldown_left": float(s.get("cooldown_left", 0.0)),
			"ready": bool(s.get("ready", false)),
		})
	return out


## ★★ 无选中时的「将领」页：与选中区划中心时的招募页**同一份数据**，
## 只把动作类型换成 `general_drag` —— 松手落在哪个区划中心，就在哪个区划招募。
func _general_recruit_entries() -> Array:
	var out: Array = _zone_recruit_entries()
	for i in out.size():
		var e: Dictionary = out[i]
		e["type"] = "general_drag"
		out[i] = e
	return out


## 「操作」页（**只剩建筑**）：大本营的升级 / 取消升级。
##
## ★★ 2026.11.15 第三轮（用户口径）：**部队不再有操作页** —— 移动 / 锁定攻击 / 行军
##   全部回到**右键**（单击 = 移动或锁定攻击，双击 = 行军攻击），命令冷却一并取消。
##   所以选中部队时页签只剩「单位」一页（见 _tab_plan()）；
##   这个函数现在只服务「选中建筑 / 大本营」那一路。
func _order_entries_for_selection() -> Array:
	if input_ctrl == null:
		return []
	if input_ctrl.selected_zone != null:
		return []
	if input_ctrl.selected_buildings.is_empty():
		return []
	return _building_order_entries(_primary_building())


## 某个区划的**中心建筑**（那一格上立着的中立障碍；找不到 → null）。
##
## ★ 为什么要这一层：选中区划时 `selected_buildings` 是空的，而升级 / 特化那一套
##   是按**建筑类型**分派的（大本营 / 城墙 / 箭塔 / 区划中心各一套）——
##   所以要先从区划的中心格反查出那栋建筑，才能走同一条判据。
func _zone_center_building_of(zone):
	if zone == null or typeof(zone) != TYPE_DICTIONARY or world == null:
		return null
	var c: Variant = (zone as Dictionary).get("center", null)
	if c == null:
		return null
	var t: Vector2i = c
	return world.building_at(t.x, t.y)


## 建筑「操作」页的格子（**数据驱动**，文案与数值都来自 config）：
##   · 大本营 → **升级**那一格（读条中则换成「取消升级」；满级 / 重生中等状态照旧）；
##   · 其它建筑 → ★ 2026.11.19 起多一张**「拆除」**卡牌（拖到地图上松手才拆）；
##   · 区划中心 → 没有操作页内容（走招募页）。
##
## ★ 升级那几档互斥，所以大本营最多 1 格；非大本营则在升级格之外多挂一张拆除牌。
##   「读条中不给新的升级请求」这条规则由逻辑层把关（拒因 `busy`），
##   界面只是**不给入口**；两处都做是有意的。
##
## @param b 要画哪一栋（默认 = `_primary_building()`）
## @param sel_zone 选中的那个**区划字典**（保留参数，当前不再使用）
func _building_order_entries(b = null, sel_zone = null) -> Array:
	# ⚠️ 默认参数是 null，这里**不能**用 `var b = ...` 再赋一次
	#   （那会报「同名变量」）；直接用参数缺省值兜底。
	if b == null:
		b = _primary_building()
	if b == null or not b.alive:
		return []
	# 区划中心：没有操作（区域特化已移除；它也是无敌中立障碍，不可拆）。
	if b.type == BuildingRes.TYPE_ZONE_CENTER:
		return []
	var out: Array = []
	if world.building_can_upgrade(b.type):
		if b.is_upgrading():
			out.append({
				"type": "building_upgrade_cancel",
				"name": "取消升级",
				"desc": "取消这次升级，全额退还已经扣掉的粮食与黄金（当前等级不变）",
			})
		elif b.is_base() and b.is_respawning():
			# ★★ 大本营正在排队重生将领 → 不能开始新的升级（进行中的升级上面已经处理）。
			out.append({
				"type": "building_respawn",
				"name": "重生中",
				"desc": "大本营正在为重生的将领排队：%d 位，当前剩 %s 秒；完成前不能升级" % [
					b.respawn_count(), _fmt_num(b.respawn_eta())],
				"ready": false,
			})
		else:
			var max_lv: int = world.building_level_cap(b)
			if b.level >= max_lv:
				out.append({
					"type": "building_upgrade_max",
					"name": "已满级",
					"desc": "%s 已经是最高等级（%d 级）" % [b.display_name(), max_lv],
				})
			else:
				# ★★ 2026.11.17：升级是**瞬时**的 —— 文案不再提读条 / 取消退款（用户口径）。
				out.append({
					"type": "building_upgrade",
					"name": "升级%s" % b.display_name(),
					"desc": "升到 %d 级：%s（立刻完成，血量补满）" % [
						b.level + 1, _cost_text(world.building_upgrade_cost(b))],
				})
	# ★★ 2026.11.19（用户口径）：所有己方建筑（大本营 / 区划中心除外）都能拆。
	#   拆除是**拖拽**动作：把这张牌拖出 UI、在地图上松手才发命令
	#   （见 `_on_card_drag_finished` 的 `building_demolish` 分支）。
	if not b.is_base() and not b.is_invulnerable():
		out.append({
			"type": "building_demolish",
			"name": "拆除",
			"desc": "把这张牌拖到地图上松手，拆除选中的%s（不返还建造资源）"
				% b.display_name(),
		})
	return out


## 消耗的一行中文（「粮食 100 / 黄金 100」；空的一句「免费」）
func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for k in ["food", "gold"]:
		var v := float(cost.get(k, 0.0))
		if v > 0.0:
			parts.append("%s %s" % ["粮食" if k == "food" else "黄金", _fmt_num(v)])
	return " / ".join(parts) if not parts.is_empty() else "免费"


## 点了科技九格里的某一格 = **打出一张科技牌**（2026.11.18 起单向：不能取消）。
##
## ★★ 科技打出后永久启用：再次点已启用的格子只提示，不会再发命令。
## ★ 名额满了：本地先给一句提示并直接返回（逻辑层同样会拒并留 `tech_rejected`）。
func _on_tech_cell_activated(id: String) -> void:
	if input_ctrl == null or world == null or id == "":
		return
	if world.is_tech_active(id):
		show_notice("这条科技已经启用，不能取消")
		return
	var active_n: int = world.active_tech_ids().size()
	if active_n >= 3:
		show_notice("已启用 3 个科技：其余科技手牌已销毁")
		return
	if world.tech_remaining_slots() <= 0:
		var max_n: int = world.tech_max_active()
		show_notice("最多只能同时启用 %d 个科技：升级大本营后再启用" % max_n)
		return
	if not input_ctrl.request_tech_toggle(id, true):
		show_notice("这条科技现在启用不了")
		return
	# ★ 立刻按**权威状态**重画一次（下一帧也会重画，但玩家点下去那一下就该看见高亮变化）。
	#   顺序有意如此：先发命令、再由权威状态决定画成什么样 ——
	#   界面永远不自作主张地翻转本地高亮。
	refresh()
	# ★ 悬停面板还开着的话，那两行（「状态 …」「点这一格 = …」）也要跟着变 ——
	#   玩家的鼠标正停在这一格上，不重算的话它要等鼠标移开再移回来才更新（看着像没生效）。
	_refresh_hover()


## 卡牌悬停面板还开着时，按**权威状态**重算一次内容。
##
## ★ 只在「点了那一格」这种**状态当场变了**的路径上调（见 `_on_tech_cell_activated`）：
##   悬停进来的那一帧已经取过一次，没必要每帧重量一遍。
func _refresh_hover() -> void:
	if card_hover == null or _hover_src == "":
		return
	var entry := _hover_entry(_hover_src, _hover_index)
	var d := _card_hover_content(_hover_src, entry)
	if d.is_empty():
		_dismiss_hover()
		return
	_show_card_hover(d, _trait_panel_content(_hover_src, entry), _hover_src, _hover_index)


## 按 config 路径取一段**文本**（取不到 / 不是字符串 → 空串）。
## ★ 悬停面板的 `brief`（简述）字段走这里读 —— 占位阶段允许整段缺失。
func _config_text(path: String) -> String:
	if cfg == null:
		return ""
	var v: Variant = cfg.get_path_value(path)
	return v if typeof(v) == TYPE_STRING else ""


## 命令卡 → 动作。★ 这里只调输入层的接口，自己绝不碰逻辑状态。
func _on_card_entry(entry: Dictionary) -> bool:
	if input_ctrl == null:
		return false
	match String(entry.get("type", "")):
		"build":
			# ★★ 2026.10.26：建筑页第二行（石墙 / 警戒塔）要 2 级大本营。
			#    置灰的格子按钮点不到；这里再判一次是保险（键盘 / 直接 activate_index 也走这条路）。
			if not bool(entry.get("ready", true)):
				show_notice("大本营升到 %d 级才能建造%s（当前 %d 级）" % [
					int(entry.get("tier", 1)), String(entry.get("name", "")),
					int(entry.get("base_level", 1))])
				return false
			# ★★ 2026.11.15：**点选建造已删除** —— 建筑只能把牌拖到地图上的建造点位上。
			#   键盘快捷键（Q/W/…）也走这条路，所以这里统一给一句可执行的提示，
			#   而不是“点了没反应”。
			show_notice("建筑牌要拖到地图上：普通建筑拖到高亮的建造点位，城墙拖到区划中心")
			return false
		"recruit_cancel_all":
			if not input_ctrl.request_recruit_cancel_all():
				show_notice("现在没有可停止的招募队列")
			else:
				return true
		"recruit":
			# ★★ 单位页的「按行解锁」：第 2 / 3 行要先把大本营升到 2 / 3 级。
			#    置灰的格子按钮点不到；这里再判一次是保险（键盘 / 直接 activate_index
			#    也走这条路），顺便给一句明确的原因。
			if not bool(entry.get("ready", true)):
				show_notice("大本营升到 %d 级才能招募这个兵种（当前 %d 级）" % [
					int(entry.get("tier", 1)), int(entry.get("base_level", 1))])
				return false
			# ★ 没选中将领时**不发命令**（命令里必须带 leader_id），所以这里要自己给一句
			#   可见反馈 —— 否则玩家点了 Q 什么都没发生，看起来像功能坏了。
			#   逻辑层拒掉的其它原因走事件那条路（见 game_scene._consume_events）。
			if not input_ctrl.request_recruit(String(entry.get("unit_kind", ""))):
				show_notice("先选中一个将领，才能把新兵排到它名下")
			else:
				return true
		"zone_recruit":
			# 区划招募（点区划中心 → 招募页）：命令里必须带 zone_id，没选中区划就不发。
			# ★ 不可招募的格子（已拥有 / 阶数不足 / 将领满员 / 冷却中）都置灰、
			#   按钮点不到；这里再判一次只是保险（键盘 / 直接 activate_index 也走这条路）。
			if not bool(entry.get("ready", true)):
				match String(entry.get("lock_reason", "")):
					"owned":
						show_notice("这位将领已经拥有，不能重复招募")
					"tier":
						show_notice("大本营升到 %d 级才能招募这位将领（当前 %d 级）" % [
							int(entry.get("tier", 1)), int(entry.get("base_level", 0))])
					"cap":
						show_notice("将领已达上限（最多 %d 名）：升级大本营可以提高上限"
							% world.base_max_generals(world.my_faction))
					"cooldown":
						show_notice("将领招募冷却中：还需 %s 秒"
							% _fmt_num(float(entry.get("cooldown_left", 0.0))))
					_:
						show_notice("这位将领现在不能招募")
				return false
			if not input_ctrl.request_zone_recruit(String(entry.get("unit_kind", ""))):
				show_notice("先点一个区划中心，才能在这个区划里招募")
		"general_drag":
			# ★★ 2026.11.15：无选中时的「将领」页 —— 落点由**拖到哪里**决定，
			#   所以点这一格不会有动作（与建筑页同一套口径：给一句能照做的提示）。
			show_notice("将领牌要拖到己方区划中心的圈里松手：落点就是招募的区划")
		"building_upgrade", "building_upgrade_cancel":
			return _on_building_action(entry)
		"base_upgrade":
			# ★★ 2026.11.19：大本营牌只能拖到大本营上，不走点击。
			show_notice("把大本营牌拖到己方大本营上松手，才能升级")
			return false
		"building_demolish":
			# ★ 拆除必须走**拖拽**：键盘 / 点击到这里只给一句可执行的提示，
			#   避免一次误触就把建筑拆了。
			show_notice("把「%s」拖到地图上松手才能拆除" % String(entry.get("name", "拆除")))
			return false
	return false


## ★ 建筑「操作」页那几格 → 命令（升级 / 取消升级 / 拆除）。
##
## ★ 与其它格子同一条约定：这里只调输入层的接口发命令，自己绝不碰逻辑状态。
##   目标（哪栋建筑）由**当前选中**决定：命令里带地块坐标。
## ★ 被拒时的提示走 `upgrade_rejected` 事件（game_scene → 左栏红字），
##   所以这里不为「钱不够 / 满级」再写一份判断 —— 规则只有逻辑层一份。
##
## @return 命令是否发出（拆除拖拽成功与否靠它决定播哪种收尾动画）
func _on_building_action(entry: Dictionary) -> bool:
	var t := String(entry.get("type", ""))
	# ★ 目标建筑：选中区划时 `selected_buildings` 是空的（两种选中互斥），
	#   所以要先从区划的中心格反查出那栋建筑 —— 与操作页画格子用的是同一条判据。
	var b = _primary_building()
	if b == null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	if b == null:
		show_notice("先选中一栋建筑")
		return false
	var ok := false
	match t:
		"building_upgrade":
			ok = input_ctrl.request_building_upgrade(b)
		"building_upgrade_cancel":
			ok = input_ctrl.request_building_upgrade_cancel(b)
		"building_demolish":
			ok = input_ctrl.request_building_demolish(b)
	# ★★ 点完立刻按**权威状态**重画一遍操作页。
	#
	# 为什么必须有这一句（**实测踩到的**）：操作页的内容跟权威状态走
	#   （读条一开始，「升级」那格就该变成「取消升级」；特化一做，三个特化就该并成
	#   「取消特化」一格），而 `_rebuild_card()` 原来只在「页签组合变了」时才跑 ——
	#   点完那一格页签一点没变，于是命令卡还画着旧内容（看着像点了没反应）。
	# ⚠️ 这里**直接调 `_rebuild_card()`**，不走 `refresh()`：
	#   `refresh()` 里那条 `_sync_tabs()` 有「页签组合没变就什么都不做」的短路，
	#   正好会把这次重建吃掉（实测就是这样）。
	# ★★ 拆除例外：建筑已经离场，操作页下一帧会整块收起；这一帧先别重建，
	#   让 `play_drag_success()` 的「新卡从下方升起」完整播完。
	if t != "building_demolish":
		_rebuild_card()
	return ok


## 点了信息栏里那块面板上的某一格 = **取消那一格**（招募队列 = 取消那一单；
## 单条读条 = 取消这次升级）。
##
## ★ 队列主人有两种（选中将领 / 选中区划），两条取消命令的形状不同
##   （leader_id vs zone_id），所以这里按当前选中分派 —— 视图不猜，只看选中状态。
## ★★ 单条读条（建筑升级，见 view/recruit_queue.gd）和「招募队列」共用同一块面板，
##   所以先问面板「你现在是哪一种」（`detail_panel.queue_is_bar()`）。
## ★ 这里只发命令（`*_cancel`）：退多少钱、等级怎么变全在权威侧算，
##   界面下一帧按权威状态重画 —— 所以本地不需要自己「删格子」。
func _on_queue_cell_activated(slot: int) -> void:
	if input_ctrl == null or detail_panel == null:
		return
	# ① 单条读条（建筑升级）
	if detail_panel.queue_is_bar():
		var b = _primary_building()
		if b == null:
			show_notice("现在没有可以取消的升级")
			return
		if not input_ctrl.request_building_upgrade_cancel(b):
			show_notice("现在没有可以取消的升级")
		_rebuild_card()
		return
	# ② 招募队列（原本那套）
	if input_ctrl.selected_zone != null:
		if not input_ctrl.request_zone_recruit_cancel(slot):
			show_notice("现在没有可以取消的招募")
		return
	if not input_ctrl.request_recruit_cancel(slot):
		show_notice("现在没有可以取消的招募")
	_rebuild_card()


## 点了左栏下半网格里的一格**将领** = 把那一支部队换成「当前展开」的那一支，
## 同时右栏切到那支部队的将领。
##
## ★ 需求原话：「若玩家点选下方 1333 排列的将领，则会将展开的部队转换成选中的部队，
##   相应地，展开将领变为选中的部队将领」。
##   ⇒ 这里**只改「展开哪一支」**（记住编号 + 刷一帧），**不碰选中集合**：
##     选中是玩家在地图上 / 左侧列表里做的决定，点一下格子不该把它改掉。
## ★ 编号 → 部队：按**与左侧部队列表完全相同的口径**数一遍己方队长
##   （view/squad_panel.gd 的 _collect_teams 是同一套判据）。
## ⚠️ 编号得**真的在当前选中的部队里**才认（喂 99 这种不存在的编号 → 什么都不变）：
##   以前不查也能跑，是因为 `_pick_troop` 下一帧会退回第一支 —— 但那样
##   「先把展开改成 99、再由 _pick_troop 退回默认」不是本意，干脆在这里就拒掉。
func _on_troop_activated(number: int) -> void:
	if world == null or number <= 0:
		return
	if not _troop_number_selected(number):
		return
	_detail_troop_number = number      # 下一帧就展开它（别被「默认第一支」抢回去）
	refresh()


## 这个部队编号（1 起）现在是不是**选中的**部队之一
func _troop_number_selected(number: int) -> bool:
	for t in _selected_troops(input_ctrl.selected_units):
		if int(t["number"]) == number:
			return true
	return false


## 新版详情列表点了某个单位：只切右栏显示，不改选中集合（与旧网格同一条约定）。
## ⚠️ 写的是与地图点选**同一个** `clicked_unit`，并把 `selection_origin` 记成 "click"。
func _on_detail_v2_unit_selected(u) -> void:
	if input_ctrl == null or u == null or world == null:
		return
	# ★ 点的是**另一支部队**里的单位：先把「当前展开」切到那一支，
	#   否则 _right_unit() 会按「点击的不是展开那支的成员」退回它的将领。
	var leader = world.team_leader(u)
	if leader == null:
		leader = u
	for t in _selected_troops(input_ctrl.selected_units):
		if (t as Dictionary).get("leader", null) == leader:
			_detail_troop_number = int((t as Dictionary).get("number", 0))
			break
	input_ctrl.clicked_unit = u
	input_ctrl.selection_origin = "click"
	refresh()


## 新版详情列表点了某个建筑：把主选中换成它（区划 / 敌人是单选，点自己即可）。
func _on_detail_v2_entry_selected(entry: Dictionary) -> void:
	if input_ctrl == null:
		return
	var kind := String(entry.get("entry_kind", ""))
	if kind == "building":
		var b = entry.get("ref", null)
		if b != null:
			input_ctrl.selected_building = b
			refresh()



## 点了左栏下半网格里的一格**单位**（只有「只选中一支部队」时才是单位格）。
##
## ★ 需求原话：「当玩家只选中了单个部队时……下方 333 排列显示选中的部队的单位」+
##   「点单位格则右栏切到那个单位」。
##   ⇒ 只把右栏切过去（写 `input_ctrl.clicked_unit`），**不动选中集合** ——
##     点一下左栏不该改变「命令发给谁」。顺序的选择手柄留给玩家单击地图那一下。
## ⚠️ 这里写的是与地图点选**同一个** `clicked_unit`，并且顺手把
##   `selection_origin` 记成 "click"：右栏的显示规则是「单击选中 → 显示点到的那个单位，
##   拖拽框选 → 显示展开那支部队的将领」（手玩原话），点左栏的格子属于前者。
func _on_grid_unit_activated(index: int) -> void:
	if input_ctrl == null or world == null:
		return
	var u = _grid_unit_at(index)
	if u == null:
		return
	input_ctrl.clicked_unit = u
	input_ctrl.selection_origin = "click"
	refresh()


## 左栏下半网格里第 index 个格子现在画的是哪个单位（没有 → null）
func _grid_unit_at(index: int):
	if detail_panel == null:
		return null
	var grid = detail_panel.grid_control()
	if grid == null or grid.mode != TroopGridRes.MODE_UNITS:
		return null
	return grid.unit_at(index)


## 点了左栏下半网格里的一格**建筑** = 把「主选中」换成它：
## 右栏详情、左上那一格、地图上的高亮全部跟着走。
##
## ★ 与单位格同一条约定：**点一下左栏不改「选中了哪些」**（这一批仍然是这一批），
##   只改「现在正在看哪一个」—— 所以这里只写 `input_ctrl.selected_building`
##   （它是 `selected_buildings` 里的成员，见 input_controller 里那两个字段的说明）。
func _on_grid_building_activated(index: int) -> void:
	if input_ctrl == null or world == null:
		return
	var b = _grid_building_at(index)
	if b == null:
		return
	input_ctrl.selected_building = b
	refresh()


## 左栏下半网格里第 index 个格子现在画的是哪个建筑（没有 → null）
func _grid_building_at(index: int):
	if detail_panel == null:
		return null
	var grid = detail_panel.grid_control()
	if grid == null or grid.mode != TroopGridRes.MODE_BUILDINGS:
		return null
	return grid.building_at(index)


## 选中的建筑里**主选中**的那一个（右栏显示它）。
## 正常情况就是 `input_ctrl.selected_building`；万一它不在这一批里（不该发生）
## 就退回第一个 —— 总之这一支保证「有选中建筑时一定返回一个非 null 的建筑」。
func _primary_building():
	if input_ctrl == null:
		return null
	var list: Array = input_ctrl.selected_buildings
	var b = input_ctrl.selected_building
	if b != null and list.has(b):
		return b
	return list[0] if not list.is_empty() else null


## 一批建筑 → 左栏那 10 个格子要的数据（短字 / 名字 / 第二行血量）。
## ★ 走这一层组装而不是让 detail_panel 自己去问建筑：网格与那一格都只认这几个字段
##   （建筑没有 `name` 属性，名字得走 `display_name()`）。
func _building_entries(buildings: Array) -> Array:
	var out: Array = []
	for b in buildings:
		out.append({
			"ref": b,
			"name": b.display_name(),
			"short": _building_short(b),
			"sub": "%d/%d" % [int(round(b.hp)), int(round(b.hp_max))],
		})
	return out


# ------------------------------------------------------------------
# 提示行（红字）：操作被拒时的可见反馈
# ------------------------------------------------------------------

## 显示一句话，约 ui.notice_sec 秒后自动消失（空串 = 立刻收起）
func show_notice(text: String) -> void:
	if detail_panel == null:
		return
	if text == "":
		_notice_timer = 0.0
		detail_panel.set_notice("")
		if detail_v2 != null:
			detail_v2.set_notice("")
		return
	detail_panel.set_notice(text)
	if detail_v2 != null:
		detail_v2.set_notice(text)
	_notice_timer = cfg.num("ui.notice_sec", 2.0)


func _tick_notice(dt: float) -> void:
	if _notice_timer <= 0.0:
		return
	_notice_timer -= dt
	if _notice_timer <= 0.0:
		_notice_timer = 0.0
		if detail_panel != null:
			detail_panel.set_notice("")
		if detail_v2 != null:
			detail_v2.set_notice("")


## ★★ F2：命令被拒 → 命令卡短暂染红（与左栏红字、地面红环同一条反馈）。
## 只染 `command_card` 这一层，不动页签 / 详细信息；0.18 秒后恢复。
func flash_reject(sec: float = 0.18) -> void:
	_reject_flash_left = maxf(_reject_flash_left, sec)
	if command_card != null:
		command_card.modulate = Color(1.0, 0.55, 0.55, 1.0)


func _tick_reject_flash(dt: float) -> void:
	if _reject_flash_left <= 0.0:
		return
	_reject_flash_left -= dt
	if _reject_flash_left <= 0.0:
		_reject_flash_left = 0.0
		if command_card != null:
			command_card.modulate = Color.WHITE


## 命令卡正在闪红吗（测试读它）
func reject_flash_active() -> bool:
	return _reject_flash_left > 0.0


## 提示还在不在（测试读它；游戏里没人读）
func notice_active() -> bool:
	return _notice_timer > 0.0


func notice_text() -> String:
	return detail_panel.notice_text() if detail_panel != null else ""


## 招募被拒的**拒因码 → 中文**。★ 这一层翻译只在这里做（逻辑层只给码，不写 UI 文案）。
##
## 拒因码是 logic/world.gd 的 can_recruit / can_afford_recruit / can_recruit_zone 产出的：
##   kind / leader / faction / zone / zone_owner / zone_not_found / queue_full / cost / population
##   / **downed**（★ 本轮新增：将领濒死倒地，不能继续造兵）
##   / **cooldown** / **pool**（★★ 本轮新增：全局招募冷却 / 不在当前三个槽位里）
## ★ 注意两个「区划」拒因是**不同的话**：
##   · "zone"          将领招募时它是「将领不站在己方区划里」；
##   · "zone_owner"    区划招募时它是「这个区划不属于你」。
##   （"zone_not_found" 才是「没有这个区划」—— 前两者都别拿来当它用。）
## ★ `max_count` 来自事件里的 max（区划招募的队列上限可能与单位那条不同）——
##   没带就用单位那条表的上限。
## ★ `cooldown_left` 来自事件的 cooldown（冷却拒因要写「还需 N 秒」）。
func recruit_reject_text(reason: String, kind: String, max_count: int = 0,
		cooldown_left: float = 0.0) -> String:
	match reason:
		"kind":
			return "这个兵种不在可招募表里"
		"leader":
			return "先选中一个将领，才能把新兵排到它名下"
		"downed":
			return "将领已经倒地濒死：它不能再造兵（在造的那一单已作废并全额退款）"
		"faction":
			return "不能给别的阵营的将领招募"
		"zone":
			return "只能在己方区划内招募（将领现在站的地方不属于你）"
		"combat":
			return "将领正在交战：脱战 %d 秒后才能开始招募（已排上的单子只会暂停，不会取消）" % (
				int(round(cfg.recruit_combat_idle_sec)) if cfg != null else 10)
		"zone_owner":
			return "只能在自己区划里招募（这个区划不属于你）"
		"zone_not_found":
			return "找不到这个区划"
		"cap":
			return "该将领已满编：先升级大本营提高编制上限，或等部队有损失"
		"general_limit":
			var gcap: int = world.base_max_generals(world.my_faction) if world != null else 0
			return "将领已达上限（最多 %d 名）：升级大本营可以提高上限" % gcap
		"cooldown":
			return "将领招募冷却中：还需 %s 秒" % _fmt_num(maxf(0.0, cooldown_left))
		"owned":
			return "这位将领已经拥有，不能重复招募"
		"tier":
			# ★★ 两张表都有 tier，但语义不同：
			#   · 区划招将 = 将领阶数（1-9 号分三阶）；
			#   · 单位页   = **行号 = 需要的大本营等级**（第 2 行 2 级、第 3 行 3 级）。
			#   先判是不是区划招募表，别把兵种当将领去查（会退成 1 阶、文案全错）。
			if world == null:
				return "大本营等级不足"
			if world.is_zone_recruitable(kind):
				return "大本营升到 %d 阶才能招募这位将领" % world.general_recruit_tier(kind)
			return "大本营升到 %d 级才能招募这个兵种（当前 %d 级）" % [
				world.recruit_tier(kind), world.unit_recruit_level(world.my_faction)]
		"queue_full":
			var cap: int = max_count if max_count > 0 else world.recruit_queue_max()
			return "招募队列已满（最多 %d 个）" % cap
		"cost":
			var c: Dictionary = world.recruit_cost(kind)
			return "粮食或黄金不足（需要 粮食 %d / 黄金 %d）" % [
				int(round(float(c.get("food", 0.0)))), int(round(float(c.get("gold", 0.0))))]
		"population":
			return "该区划人口不足（需要 %d 人口）" % int(round(world.recruit_population_cost(kind)))
	return "无法招募"


## 指令被拒的**拒因码 → 中文**（与上面那条同一条约定：逻辑层只给码）。
##
## 现行拒因（都由 `world.order_lock_reason()` 产出）：
##   · ★ `downed`   —— 将领濒死倒在地上，它自己不接受任何指令。
##   · ★★ `leader_downed` —— **附属兵**在队长濒死期间不接受指令。
##     与上面那条的区别：`downed` 拒的是将领本人，`leader_downed` 拒的是它的部队。
##     用户口径原话：「其旗下部队应当立刻行军攻击至其将领位置以保护他，
##     并且在将领再起前不接受玩家或 ai 的指令」。
##   · `recruiting` —— **历史码**（2026.10.24 起招募不再锁单位，逻辑层已不再产出）。
##     保留这一条只为兼容旧事件 / 旧录像里的拒因，不至于显示成「下不了」。
func order_reject_text(reason: String) -> String:
	match reason:
		"recruiting":
			return "（旧版本）将领正在招募单位，不接受指令；现在招募已不再锁定部队"
		"downed":
			return "将领已经倒地濒死：它自己不能行动，先让它「再起」或「召回」（它辖下的部队照常能打）"
		"leader_downed":
			return "该部队的主将已经倒地：它们正在赶去保护主将，主将「再起 / 召回」前不接受指令"
		"neutralized":
			return "这个大本营已经被摧毁：该阵营的单位已失去指挥，不能再行动或攻击"
	return "这条指令现在下不了"


## ★★ 2026.11.18：单位身上的**状态** → 顶带 buff 槽的条目（view/buff_bar.gd 的格式）。
##
## ★ 顺序 = `status_list()`（排序后），所以同一组状态每次画的位置都一致，不会闪。
## ★ 一个状态只占一格：字是 `unit.status.<id>.short`，悬停标题 / 正文是 name / desc。
func _unit_status_buffs(u) -> Array:
	var out: Array = []
	if u == null or cfg == null:
		return out
	for sid in u.status_list():
		var id := String(sid)
		out.append({
			"id": id,
			"text": cfg.unit_status_short(id),
			"name": cfg.unit_status_name(id),
			"tip_title": cfg.unit_status_name(id),
			"tip_body": cfg.unit_status_desc(id),
		})
	return out


## ★★ 建造被拒（`build_rejected` 的 reason → 中文；F2 之前这条事件**根本没有界面反馈**）。
## 码见 logic/command_processor.gd 的 `apply_build()`。
func build_reject_text(reason: String) -> String:
	match reason:
		"base_level":
			return "需要更高等级的大本营才能建造这个"
		"occupied_or_terrain":
			return "这里不能建造（地形不可建 / 已有建筑）"
		"not_in_zone":
			return "只能在己方区划内建造"
		"under_capture":
			return "这个区划正在被占领，暂时不能建造"
		"not_build_point":
			return "建筑只能建在区划的建造点位上（把建筑牌拖到高亮的点上）"
		"not_zone_center":
			return "城墙只能建在区划中心周围：把城墙牌拖到高亮的区划中心上"
		"wall_no_space":
			return "这个区划中心周围的城墙位置已经建满 / 被挡住，建不了墙"
		"wall_preplaced":
			return "城墙只能由地图设计预先摆放，不能在局内建造"
		"cost":
			return "资源不足，建不了"
		# ★★ 2026.11.18：教堂这套专属建筑的两条新拒因。
		"clan":
			return "这个派系不能建造这种建筑（教堂只有帝国·教会军能造）"
		"per_zone_limit":
			return "这个区划里同类型的建筑已经达到上限（教堂每区划限一座）"
		"base_level_cap":
			return "教堂的等级不能超过己方大本营的等级：先把大本营升上去"
	return "这里建不了"


## ★★ AI 队友指令被拒（`ai_order_rejected` 的 reason → 中文）。
## 码见 logic/world.gd 的 `set_ai_directive()`。
func ai_order_reject_text(reason: String) -> String:
	match reason:
		"no_ai":
			return "这一局没有可指挥的 AI 队友"
		"not_commander":
			return "这一方不是可指挥的 AI 队友"
		"not_ally":
			return "你只能给同方的 AI 队友下指令"
		"bad_order":
			return "不认识这条 AI 指令"
		"out_of_map":
			return "目标点在地图外"
		"unreachable":
			return "目标点不可到达（水域 / 被建筑占住）"
	return "这条 AI 指令现在下不了"


## 科技被拒的**拒因码 → 中文**（逻辑层只给码：见 logic/tech.gd 的 can_activate）。
##   "limit"    已经启用满了（科技不可取消，升级大本营提高上限）
##   "played"   这条科技已经启用过（不可重复打出 / 不可取消）
##   "destroyed" 已启用 3 条，其余手牌已销毁
##   "unknown"  没有这条科技（手改数据 / 旧快照才会有）
func tech_reject_text(reason: String) -> String:
	var max_n: int = world.tech_max_active() if world != null else 3
	match reason:
		"limit":
			return "最多只能同时启用 %d 个科技：升级大本营后再启用" % max_n
		"played":
			return "这条科技已经启用，不能取消 / 不能再次打出"
		"destroyed":
			return "已启用 3 个科技：其余科技手牌已销毁"
		"tier":
			var t: int = world.tech_max_tier() if world != null else 3
			return "这条科技超出当前大本营允许的阶数（最高第 %d 阶）：升级大本营后再启用" % t
		"unknown":
			return "没有这条科技"
	return "这条科技现在启用不了"


## 建筑升级 / 区划特化被拒的**拒因码 → 中文**（码见 logic/upgrade.gd 的那几处判定）。
## 与招募 / 科技同一条约定：逻辑层只给码 + **对象**，文案只在这里。
##
## ★★ `busy` 那条文案必须**点名是哪个对象、并说明什么都没发生**（实测报回来的）：
##   玩家原话是「详细信息栏经常显示『这一项正在读条…』，但我什么都没做」。
##   原因有两层：
##     ① 「正在读条」的东西**可能不是玩家自己下的单** —— 敌方 AI 也会升级自己的建筑
##        （实测：样例第一关开局第 0 帧，E1 的城墙就已经在升级了）；
##     ② 旧文案只有一个「这一项」：既不说哪一项、也不说「这一下没有生效」，
##        于是看起来像凭空冒出来的报错。
##   ⇒ 现在带上对象名，并明说「这一下没有生效（没扣资源、也没排队）」。
##
## @param evt 可选：那条 `upgrade_rejected` 事件本身（带 `building` / `zone_id`）。
##        不传也能用（退回旧的那句泛泛文案）。
func upgrade_reject_text(reason: String, evt: Variant = null) -> String:
	match reason:
		"busy":
			var who := _reject_target_name(evt)
			if who != "":
				return "「%s」正在读条：这一下没有生效（没扣资源、也没排队）。等它读完，或者点信息栏那一格取消" % who
			return "这一项正在读条：等它读完，或者点信息栏那一格取消"
		"max_level":
			return "已经是最高等级了"
		"generals":
			# ★ 数字全部来自事件（逻辑层算好的 target_level / need / have），不在这里写死 3 / 6。
			return "将领数量不足：升到 %d 级需要 %d 名将领（当前 %d 名）" % [
				int(evt.get("target_level", 0)) if typeof(evt) == TYPE_DICTIONARY else 0,
				int(evt.get("need", 0)) if typeof(evt) == TYPE_DICTIONARY else 0,
				int(evt.get("have", 0)) if typeof(evt) == TYPE_DICTIONARY else 0]
		"cost":
			return "粮食或黄金不足"
		"neutralized":
			return "这个阵营已经失去大本营：残余建筑无法再升级"
		"respawning":
			return "大本营正在为重生的将领排队：队列清空之前不能开始新的升级"
		"owner":
			return "只能升级自己的建筑"
		"type":
			return "这种建筑不能升级"
		"idle":
			return "现在没有可以取消的读条"
	return "这一项现在做不了"


## 被拒的那**一个对象**的人话名字（建筑 → 显示名；区划 → 区划名）。
## ★ 只做「对象 → 名字」这一层翻译，不判断「这是谁的」—— 那属于逻辑层。
func _reject_target_name(evt: Variant) -> String:
	if typeof(evt) != TYPE_DICTIONARY:
		return ""
	var d: Dictionary = evt
	var b = d.get("building", null)
	if b != null and b.has_method("display_name"):
		return String(b.display_name())
	var zid := int(d.get("zone_id", -1))
	if zid >= 0 and world != null:
		var z = world.zone_by_id(zid)
		if z != null:
			var zd: Dictionary = z
			var nm := String(zd.get("name", "")).strip_edges()
			return nm if nm != "" else ("区划 c%d" % zid)
	return ""


# ------------------------------------------------------------------
# 键盘 / 鼠标
# ------------------------------------------------------------------

## 命令卡 / 科技九格上的九个字母键（有内容的格优先于其它绑定）。
## 由 view/main.gd 在 input_controller 之前调用。
##
## ★★ 科技页时九格由 `tech_grid` 盖在命令卡上画，所以**先问它**：
##   两层的几何完全重合，判定顺序必须与鼠标命中（`_cell_at_screen`）一致。
func handle_key(event: InputEventKey) -> bool:
	# ★★ 2026.11.14 第三轮：**选项页开着时 Esc = 关**。
	#   选项按钮已按用户要求删除，这里是它在 PC 上唯一的键盘出口；
	#   必须放在最前面（模态优先），否则 Esc 会被命令卡 / 输入控制器的级联吃掉。
	if options_panel != null and options_panel.is_open():
		if event != null and event.pressed and not event.echo \
				and (event.keycode == KEY_ESCAPE or event.physical_keycode == KEY_ESCAPE):
			options_panel.close()
			return true
	# ★★ 对话优先：空格 / 回车推进当前对话（逐字未完成时先补全）。
	if broadcast_banner != null and broadcast_banner.has_dialogue():
		if broadcast_banner.handle_key(event):
			return true
	if tech_grid != null and tech_grid.visible:
		return tech_grid.handle_key(event)
	if command_card == null:
		return false
	return command_card.handle_key(event)


## ★★ Tab = 切换右下角页签（Shift+Tab 反向）。
##
## ★ 由 `game_scene3d._input` 在 **GUI 之前**调用：Tab 同时是 Godot 的「焦点导航」
##   按键，等 `_unhandled_input` 时可能已经被 GUI 吃掉，焦点还会乱跑。
## ★ 选项页是模态 → 让 Tab 留给它做焦点导航；观战 / UI 隐藏 / 只有一页时也不消费。
## @return true = 真的切了页（调用方应 `set_input_as_handled()`）
func handle_tab_key(event: InputEventKey) -> bool:
	if event == null or not event.pressed or event.echo or event.keycode != KEY_TAB:
		return false
	if page_tabs == null or not page_tabs.visible:
		return false
	if options_panel != null and options_panel.is_open():
		return false
	return page_tabs.cycle_page(-1 if event.shift_pressed else 1)


## 鼠标是不是停在**可点的控件**上（部队行 / 命令卡 / 页签 / 设置）。
##
## ★ 边缘滚屏要给这些地方让路，否则鼠标一移到底栏上镜头就自己跑。
##   但**只有能点的控件**才让路：详细信息面板全是文字，让它也让路的话，
##   底栏盖住屏幕下沿 → 鼠标永远滚不到地图下方（这条是实测撞出来的）。
##
## ★★ 屏幕**最外圈**（config.camera.edge_size 之内）永远不许拦 —— 这一条是补的
##    （手玩报的 bug：「鼠标移到将领按钮那边的屏幕边缘，屏幕不会滚动」）：
##   左侧部队列表是 x 0..119 的控件，整条压着左边缘，于是左边缘那一段永远滚不动。
##   凡贴边的控件都有这个毛病（命令卡压下边缘、设置压上边缘），所以判据写成
##   「先看在不在最外圈」，与 camera_rig 的滚屏触发区同源。
func blocks_edge_scroll(global_pos: Vector2) -> bool:
	# ★ 选项页是模态 overlay：开着的时候鼠标在哪个边缘都不该滚地图
	if options_panel != null and options_panel.is_open():
		return true
	if ai_panel != null and ai_panel.visible and ai_panel.get_global_rect().has_point(global_pos):
		return true
	# ★★ 2026.11.19：圆盘在 X 收起后仍然可见（命令卡隐藏），它也要拦住边缘滚屏。
	if page_tabs != null and page_tabs.visible \
			and page_tabs.get_global_rect().has_point(global_pos):
		return true
	var vp := view_size()
	var margin: float = cfg.camera_edge_size if cfg != null else 0.0
	if UiLayoutRes.in_edge_band(vp, global_pos, margin):
		return false
	var tabs_n: int = page_tabs.page_count() if _command_ui_visible() and page_tabs != null else 0
	if UiLayoutRes.point_hits_any(
			UiLayoutRes.interactive_rects(vp, is_detail_visible(), _command_ui_visible(), tabs_n),
			global_pos):
		return true
	return UiLayoutRes.point_hits_any(_detail_hit_rects(), global_pos)


## 详情牌里**真正能点**的那几个小方块（屏幕坐标）。
## ★ 面板本身不再整块登记（见 ui_layout.interactive_rects 的注释）：只有能点的地方
##   才拦边缘滚屏，其余「只有文字」的部分照样让鼠标滚到屏幕边缘。
func _detail_hit_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if detail_v2 == null or not detail_v2.visible:
		return out
	var origin := detail_v2.global_position
	for r in detail_v2.interactive_rects():
		var rr: Rect2 = r
		out.append(Rect2(rr.position + origin, rr.size))
	return out


## 鼠标是不是停在**底栏**上（详细信息 / 阵营 / 命令卡 / 页签 —— **不含**左下小地图）。
##
## 需求原话：「当鼠标位于下方除地图外的 ui 栏时，应当禁用鼠标滚轮缩放地图，
##            当鼠标移出下边栏，需要恢复」。
##
## ★ 与 `blocks_edge_scroll` 是**两条不同的规则**（别合并，理由见 ui_layout 里
##   `bottom_bar_rects` 的注释）：那条只拦「能点的控件」，这条拦**整条底栏** ——
##   详细信息面板里只有文字的地方不能拦边缘滚屏，但滚轮缩放在那儿照样该停。
## ★ 小地图不算「ui 栏」：鼠标停在它上面时滚轮照旧缩放地图（需求里的「除地图外」）。
## ★ 判据由调用方**每次事件**传进来（game_scene 用的是那一下滚轮自己的坐标）：
##   鼠标一移出底栏，下一下滚动就恢复缩放 —— 没有「记得复位」的状态。
func blocks_wheel_zoom(global_pos: Vector2) -> bool:
	if options_panel != null and options_panel.is_open():
		return true
	if ai_panel != null and ai_panel.visible and ai_panel.get_global_rect().has_point(global_pos):
		return true
	if page_tabs != null and page_tabs.visible \
			and page_tabs.get_global_rect().has_point(global_pos):
		return true
	return UiLayoutRes.point_hits_any(
		UiLayoutRes.bottom_bar_rects_v2(view_size(), is_detail_visible(), _command_ui_visible()),
		global_pos)


## ★★ 当前这一屏「操作」页该画哪几格 —— 用一个**短字符串签名**表达（见 `_card_sig()`）。
##
## 为什么需要它（手玩报的 bug）：「先选中城墙、再改选箭塔，右下角还写着『升级城墙』」——
## `_sync_tabs()` 只在**页签组合**变了时才重建命令卡，而城墙与箭塔属于**同一类选中**
## （kind 都是 building、页都是 [操作]）⇒ 页签那一路察觉不到「换了一栋楼」。
## 同一类问题的另一面：两个**种类不同**的区划中心轮流点（能做哪几档特化不一样）。
##
## 做法：把「与内容有关的那些事实」拼成签名，`refresh()` 每帧比一次，变了就重建。
## ⚠️ 签名只放**便宜、稳定**的字段（枚举字符串 + 地块 / 区划 id + 等级 + 两个布尔），
##    不放对象引用，也**不放读条百分比**（那一格画的是「取消升级」/「取消特化」，
##    与读了几成无关；放进去就变成每变 1% 白重建一次）。
func _card_sig() -> String:
	if input_ctrl == null or page_tabs == null or world == null:
		return ""
	var parts: Array[String] = [String(page_tabs.page())]
	# ★★ 2026.11.15：建筑页不再有「选中的建造命令」（点选建造已删除，只剩拖牌），
	#   所以签名里不再拼 `build_type` —— 页签切换本身已经由第一项覆盖。
	# ① 选中的建筑（选中区划时用「它的中心建筑」代替 —— 与 `_building_order_entries` 同一条判据）
	var b = _primary_building()
	if b == null and input_ctrl.selected_zone != null:
		b = _zone_center_building_of(input_ctrl.selected_zone)
	if b != null:
		parts.append("b:%s@%d,%d:lv%d:up%d" % [
			b.type, b.tx, b.ty, b.level, 1 if b.is_upgrading() else 0])
	# ② 选中的那个区划：种类决定详情栏的种类行。
	var z = _recruit_zone()
	if z != null and typeof(z) == TYPE_DICTIONARY:
		var zd: Dictionary = z
		parts.append("z:%d:%s" % [int(zd.get("id", -1)), world.zone_kind_of(zd)])
	# ★★ 招募页的九宫格状态：固定阵容本身不变，但下面这些会变 ——
	#    · 大本营升级 → tier 解锁；
	#    · 招走 / 取消 / 关卡开局拥有 → taken；
	#    · 将领死亡 / 重生 / 上限变化 → cap；
	#    · 冷却开始 / 结束 → 整页灰 ⇄ 可点。
	#    ⚠️ 不放剩余秒数，否则命令卡会每秒重建一次。
	if String(page_tabs.page()) == PageTabsRes.PAGE_RECRUIT \
			or String(page_tabs.page()) == PageTabsRes.PAGE_GENERAL:
		var taken_key := ",".join(PackedStringArray(world.general_recruit_owned_kinds(world.my_faction)))
		parts.append("gr:%d:%d:%d:%s:%d" % [
			world.base_level_of(world.my_faction),
			world.general_count_of(world.my_faction),
			world.base_max_generals(world.my_faction),
			taken_key,
			1 if world.general_recruit_cooldown_left(world.my_faction) > 0.0 else 0,
		])
	# ★★ 单位页也要把大本营等级放进签名：升级完成那一刻第 2 / 3 行要**当场**解锁
	#    （不放进来的话，格子会一直灰到玩家切一次页 —— 与招募页同一类坑）。
	if String(page_tabs.page()) == PageTabsRes.PAGE_UNIT:
		parts.append("ur:%d" % world.unit_recruit_level(world.my_faction))
	# ③ 选中部队 / 什么都没选中这两档**不进签名**：它们的命令卡内容只由页签决定
	#    （单位页来自 config、建筑页来自 config、科技页由科技那一层画），
	#    与「选中了哪一支部队」无关 —— 放进去只会每次换选中都白重建一遍。
	return "|".join(parts)



## 命令卡的内容变了就重建（每帧按签名比一次，见 `_card_sig()`）。
## ★ 绝大多数帧是空转（签名没变直接返回）——这比「每帧无条件重建」便宜得多，
##   也比「只在切页时重建」正确：**换了一栋同类建筑 / 换了一个种类的区划中心**都算内容变了。
func _refresh_card_if_changed() -> void:
	if _card_sig() != _card_sig_key:
		_rebuild_card()


## ★★ 2026.11.19：当前选中的**己方部队 / 建筑**签名。
##   · 部队：排序后的单位 id（同一批单位换顺序不算换选中）；
##   · 建筑：排序后的 `type@tx,ty`（城墙 → 箭塔也算换选中）；
##   · 己方区划中心：`z:<id>`（它是通过 `selected_zone` 选中的）；
##   · 空 / 敌方 / 友军 → 空串（不播手牌入场）。
func _selection_anim_sig() -> String:
	if input_ctrl == null or world == null:
		return ""
	if not input_ctrl.selected_units.is_empty() \
			and _units_all_own(input_ctrl.selected_units):
		# ★ 用「部队队长 id」而不是每个小兵的 id：同一支部队补员 / 阵亡不会
		#   触发整手牌重播；换到另一支部队才会变。
		var ids: Array[String] = []
		for u in input_ctrl.selected_units:
			if u == null or not u.alive:
				continue
			var key := String(u.leader_id)
			if key == "":
				key = String(u.id)
			if not ids.has(key):
				ids.append(key)
		ids.sort()
		return ("u:" + ",".join(ids)) if not ids.is_empty() else ""
	if not input_ctrl.selected_buildings.is_empty() \
			and _buildings_all_own(input_ctrl.selected_buildings):
		var keys: Array[String] = []
		for b in input_ctrl.selected_buildings:
			if b != null and b.alive:
				keys.append("%s@%d,%d" % [String(b.type), int(b.tx), int(b.ty)])
		keys.sort()
		return ("b:" + ",".join(keys)) if not keys.is_empty() else ""
	if input_ctrl.selected_zone != null and _zone_is_own(input_ctrl.selected_zone):
		var zd: Dictionary = input_ctrl.selected_zone
		return "z:%d" % int(zd.get("id", -1))
	return ""


## ★★ 2026.11.19（用户口径）：选中己方对象时，圆盘自动跳到对应页：
##   · 己方部队 → 单位
##   · 己方普通建筑 → 建筑
##   · 己方区划中心 → 将领
##   · 己方大本营 → 科技
## 敌方 / 友军 / 什么都没选中 → 返回 ""（保持当前页）。
func _selection_page_hint() -> String:
	if input_ctrl == null or world == null:
		return ""
	if not input_ctrl.selected_units.is_empty() \
			and _units_all_own(input_ctrl.selected_units):
		return PageTabsRes.PAGE_UNIT
	if input_ctrl.selected_zone != null and _zone_is_own(input_ctrl.selected_zone):
		return PageTabsRes.PAGE_GENERAL
	if not input_ctrl.selected_buildings.is_empty() \
			and _buildings_all_own(input_ctrl.selected_buildings):
		var has_base := false
		var has_zone := false
		for b in input_ctrl.selected_buildings:
			if b == null or not b.alive:
				continue
			if String(b.type) == BuildingRes.TYPE_BASE:
				has_base = true
			elif String(b.type) == BuildingRes.TYPE_ZONE_CENTER:
				has_zone = true
		if has_base:
			return PageTabsRes.PAGE_TECH
		if has_zone:
			return PageTabsRes.PAGE_GENERAL
		return PageTabsRes.PAGE_BUILD
	return ""


## 选中对象变了、且新选中对象是**己方部队 / 建筑**时，整手牌播一次入场。
## ★ 只认选中变化：同一对象每帧刷新不会重播；手动切页由 `_on_page_changed` 负责。
func _animate_hand_on_selection_change() -> void:
	var sig := _selection_anim_sig()
	if sig == _hand_anim_sig:
		return
	_hand_anim_sig = sig
	if sig == "":
		return
	if command_card == null or not command_card.visible:
		return
	var page := String(page_tabs.page()) if page_tabs != null else ""
	if page == PageTabsRes.PAGE_TECH:
		if tech_grid != null and tech_grid.visible:
			tech_grid.animate_deck_in()
		return
	command_card.animate_deck_in()


## 当前设计空间大小（canvas_items + expand 拉伸后可能比 1920×1080 大）
func view_size() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(UiLayoutRes.DESIGN_W, UiLayoutRes.DESIGN_H)
	return vp.get_visible_rect().size


# ------------------------------------------------------------------
# 每帧刷新文本
# ------------------------------------------------------------------

## 全量刷新（桌面 / 无头 / 测试的路径；手机端回退开关也走它）。
##
## ★★ 手机端正常走 `_mobile_tick()` 的 4 槽轮转，不在这里一次做完。
##   但无论哪条路，**桌面 / 测试的 `refresh()` 语义完全不变**：
##   资源条 + 页签 + 命令卡 + 科技格 + 详细信息，一次全刷。
func refresh() -> void:
	if world == null or input_ctrl == null or detail_panel == null:
		return
	_begin_tick_cache()
	_timed_shell()
	_timed_detail()
	_end_tick_cache()


## ★★ 手机端 4 槽轮转（节拍 = `ui.mobile_hud_refresh_hz`，默认 20Hz）：
##   槽 0 shell → 槽 1 detail → 槽 2 shell + squad → 槽 3 detail。
##   ⇒ shell / detail 各 10Hz，squad 5Hz；每个节拍只承担一块重活，
##   避免「HUD + 部队列表」在同一帧叠出几毫秒的尖峰。
##
## ★ 选中变化（`input_ctrl.local_ui_changed`）会把 `_mobile_force_full` 置真，
##   下一个节拍直接走完整 `refresh()` + squad，忽略槽位。
func _mobile_tick() -> void:
	if _mobile_force_full:
		_mobile_force_full = false
		refresh()
		_timed_squad()
		return
	_begin_tick_cache()
	match _mobile_phase:
		0:
			_timed_shell()
		1:
			_timed_detail()
		2:
			_timed_shell()
			_timed_squad()
		_:
			_timed_detail()
	_end_tick_cache()
	_mobile_phase = (_mobile_phase + 1) % 4


# --- 计时包装：只在手机读数开着时付时钟调用 ---------------------------------

func _timed_shell() -> void:
	if _perf_label == null:
		_refresh_shell()
		return
	var t0: int = Time.get_ticks_usec()
	_refresh_shell()
	_add_perf_usec("shell", Time.get_ticks_usec() - t0)


func _timed_detail() -> void:
	if _perf_label == null:
		_refresh_detail()
		return
	var t0: int = Time.get_ticks_usec()
	_refresh_detail()
	_add_perf_usec("detail", Time.get_ticks_usec() - t0)


func _timed_squad() -> void:
	if squad_panel == null:
		return
	if _perf_label == null:
		squad_panel.refresh()
		return
	var t0: int = Time.get_ticks_usec()
	squad_panel.refresh()
	_add_perf_usec("squad", Time.get_ticks_usec() - t0)


func _add_perf_usec(part: String, usec: int) -> void:
	if usec <= 0:
		return
	_perf_hud_sum += float(usec)
	match part:
		"shell":
			_perf_shell_sum += float(usec)
		"detail":
			_perf_detail_sum += float(usec)
		"squad":
			_perf_squad_sum += float(usec)


# --- 一次刷新内共享的「选中部队」扫描（去掉重复的 O(单位数)） ----------------

func _begin_tick_cache() -> void:
	_tick_troops = _compute_selected_troops(input_ctrl.selected_units)
	_tick_cache_on = true


func _end_tick_cache() -> void:
	_tick_cache_on = false


## 资源条 / 页签 / 命令卡 / 科技九格 —— 与「选中了什么」无关或只按签名比。
func _refresh_shell() -> void:
	# ★ 资源条先刷（它只读 `world.resources`，与选中了什么无关）
	_refresh_resource_bar()
	# ★★ 目标条也只读世界状态（`world.objective_state`），与选中无关；
	#    放在 shell 这一档刷（手机端 10Hz 足够，进度条不需要 60Hz）。
	if objective_panel != null:
		objective_panel.sync()
		# ★ 手机端 FPS 读数原本在左上 (6,2)，会与新的左上目标栏重叠：
		#   目标栏可见时把它挪到目标栏下方，不可见时回原位。
		if _perf_label != null:
			var perf_y := 2.0
			if objective_panel.visible:
				perf_y = objective_panel.position.y + objective_panel.size.y + 6.0
			_perf_label.position = Vector2(6.0, perf_y)
	# ★★ 页签先按「现在选中了什么」推上去（自己的部队 = 操作/单位；自己的区划中心 = 招募；
	#    自己的大本营 = 操作/科技；无操作建筑 / 敌方 / 友方任何建筑单位 = **页签 + 命令卡
	#    整块隐藏**；什么都没选中 = 建筑 + 科技）。
	#    命令卡的内容跟着页签走（page_tabs 发 page_changed → _rebuild_card）。
	_sync_tabs()
	# ★★ 命令卡的内容按签名比一次（见 `_card_sig()`）：页签组合没变、但
	#   「选中的东西换了」（城墙 → 箭塔）或者「选中对象的权威状态变了」（开始升级 /
	#   取消升级 / 区划特化到哪一步）时，那一格必须跟着重画 ——
	#   这是手玩报的「改选箭塔，右下角还写着升级城墙」那个 bug 的修法。
	_refresh_card_if_changed()
	# ★ 科技九格（内容 / 高亮都取决于权威的启用状态）：
	#   命令卡那条路只在「签名变了」时跑（`_refresh_card_if_changed`），跟不上
	#   「玩家点了一格科技」这种变化。
	_refresh_tech_grid(page_tabs != null and String(page_tabs.page()) == PageTabsRes.PAGE_TECH)
	# ★★ 2026.11.19（用户口径）：选中任意己方部队 / 建筑（含部队 ↔ 建筑切换）时，
	#   整手牌播一次入场动效。手动切页仍由 `_on_page_changed` 播，不会重复。
	_animate_hand_on_selection_change()
	# ★ AI 队友面板：只在有同方 commander 时显示，状态读 world（客机读快照）。
	if ai_panel != null:
		ai_panel.world = world
		ai_panel.sync()


## 现在有没有「能查看详细信息」的选中对象：
##   己方部队 / 建筑 / 区划 / 敌方单位或建筑 —— 有任何一个就显示详细信息栏；
##   全都没有（开局、点空地清空选中）→ 整块隐藏。
func has_detail_selection() -> bool:
	if input_ctrl == null:
		return false
	if not input_ctrl.selected_units.is_empty():
		return true
	if not input_ctrl.selected_buildings.is_empty():
		return true
	if input_ctrl.selected_zone != null:
		return true
	if input_ctrl.selected_enemy != null:
		return true
	return false


## 新版详情面板是否显示：选中己方部队 / 建筑 / 区划 / 敌方都显示；空选中时隐藏。
func _detail_should_show() -> bool:
	if input_ctrl == null or world == null:
		return false
	if input_ctrl.selected_enemy != null:
		return true
	if input_ctrl.selected_zone != null:
		return true
	if not input_ctrl.selected_buildings.is_empty():
		return true
	if input_ctrl.selected_building != null:
		return true
	# ★ 选中己方部队（队长 / 附属兵 / 框选 / 编组）都显示详情；
	#   完全没有选中时左下区域保持空白。
	return not input_ctrl.selected_units.is_empty()


## 详细信息面板现在是否可见（隐藏时它那块区域恢复地图交互，见 ui_layout 的两个 rects）。
func is_detail_visible() -> bool:
	return detail_v2 != null and detail_v2.visible


## 右下角「命令卡 + 页签」整块现在是否可见。
## ★ 它不只影响画面：`point_hits_ui()` / `blocks_edge_scroll()` / `blocks_wheel_zoom()`
##   也要按它决定「右下角还算不算 UI」—— 否则隐藏之后仍有一块看不见的死区
##   吞手势 / 边缘滚屏 / 滚轮。
## ★ 两个控件由 `_sync_tabs()` 一起开关；这里同时看两者，任何一边被外部关掉
##   都不会把隐形的格子继续算成可点区域。
func _command_ui_visible() -> bool:
	return page_tabs != null and page_tabs.visible \
		and command_card != null and command_card.visible


## 详细信息面板：敌人 → 区划 → 建筑 → 部队 四种互斥选中，一次只走一支。
func _refresh_detail() -> void:
	# ★★ 没有可查看的对象 → 整块隐藏（用户本版需求）。
	#    ★ 内容仍然照常刷到「空态」：重新显示时不会闪上一帧的旧内容，
	#      测试 / 排查也能直接读面板内部状态。
	var show_any := has_detail_selection()
	var show_v2 := _detail_should_show()
	var was_visible := detail_v2 != null and detail_v2.visible
	# ★★ 旧面板保持 visible（旧测试要看几何 / _draw），但全透明、不吃输入；
	#    屏幕上显示的是 detail_v2。新版只在「具体对象」选中时显示。
	if detail_panel.visible != show_any:
		detail_panel.visible = show_any
	detail_panel.modulate = Color(1, 1, 1, 0)
	if detail_v2 != null:
		if not show_v2:
			if _detail_slide_tween != null and _detail_slide_tween.is_running():
				_detail_slide_tween.kill()
			detail_v2.position = _detail_home_position
		detail_v2.visible = show_v2
		# ★★ 2026.11.16 第二轮（用户口径）：「所有左下面板在出现时都需要有**向右滑动**的
		#   出现动画」⇒ 不再只管**部队**：建筑 / 区划 / 敌方选中同样滑进来
		#   （原来那句 `and _has_unit_detail_selection()` 是「只有部队才滑」的旧口径）。
		if show_v2 and not was_visible:
			_play_detail_slide_in()
	# ★ 详细信息是**左右两栏**（第三轮改版，见 view/detail_panel.gd 的文件头）：
	#   左栏 = 当前展开的那支部队（上半）+ 选中部队的将领头像网格（下半）
	#   右栏 = 选中单位的头像 / 名称 / buff / 基础数值（★ 数值那块的「详细信息」标题已删）
	# 选中对象的四种互斥情况：敌人 → 区划 → 建筑 → 单位（见下）
	# ★★ 敌人排在最前：它是**唯一**一种「选中了但不给任何操作入口」的对象，
	#    落到下面任何一支都会把敌人当自己人显示（升级按钮、军队编组…）。
	if _selected_enemy_kind() != "":
		_refresh_enemy_detail()
		return
	# ★ 区划这一支：标题那一行写**区划名本身**（不再套「区划「xx」」那层壳），
	#   正文里也不再出现「区划「xx」」那一行（需求：「选中区划中心时去掉『区划[xx]』文本」）。
	if input_ctrl.selected_zone != null:
		detail_panel.set_troops(null, [])
		detail_panel.set_unit_avatar_text("区")
		# ★ 区划没有血量 → 头像底部那条血条不画。
		detail_panel.set_unit_avatar_hp(0.0, false)
		detail_panel.set_unit_name(_zone_title(input_ctrl.selected_zone))
		# ★★ 本次：当前人口只给**自己 / 友军**的区划看（用户原话：「如果是友军/己方区划，
		#   额外显示其当前人口数量」）—— 敌方与中立区划的「现在有多少人」属于对手的情报。
		# ★★ 本版：两列表格（左 = 类型 / 大小，右 = 产能多排 + 当前人口 + 特化）。
		var zrows: Dictionary = _zone_detail_rows(input_ctrl.selected_zone,
			_zone_is_friendly(input_ctrl.selected_zone))
		detail_panel.set_detail_rows(zrows["left"], zrows["right"])
		detail_panel.set_buffs([])
		_v2_show_zone(input_ctrl.selected_zone)
		# ★ 右栏右上角那块面板（招募队列 / 单条读条共用，见 _refresh_progress_panel）
		_refresh_progress_panel(input_ctrl.selected_zone)
		return
	if not input_ctrl.selected_buildings.is_empty():
		# ★★ 选中建筑（可能是一整批：框选建筑时，见 input_controller.box_select）：
		#   左栏 = 和部队**同一套 1 + 3×3 版式** —— 左上第 1 格是**主选中**那个建筑
		#   （右栏正在显示它），下面 9 格是其余选中的建筑（超过 9 个滚轮翻页）；
		#   点下面某一格 = 把主选中换成它（右栏与地图高亮跟着变，见 _on_grid_building_activated）。
		var b = _primary_building()
		var bentries := _building_entries(input_ctrl.selected_buildings)
		detail_panel.set_buildings(bentries, b)
		detail_panel.set_unit_avatar_text(_building_short(b))
		# ★ 建筑也有血量 → 头像底部画它的血条。
		detail_panel.set_unit_avatar_hp(b.hp_ratio(), true)
		detail_panel.set_unit_name(b.display_name())
		var brows: Dictionary = _building_detail_rows(b)
		detail_panel.set_detail_rows(brows["left"], brows["right"])
		detail_panel.set_buffs([])
		_v2_show_building(b, bentries)
		# 右栏那块面板：升级 / 特化读条 > 区划中心的招募队列 > 收起来
		_refresh_progress_panel(b)
		return

	# 选中的部队（按「队长」分组，顺序 = 左侧部队列表）：
	# 上半画**当前展开**的那一支的将领格，下半网格两种语义共用（见 detail_panel 文件头）：
	#   · 选中多支 → 画**其余**部队的将领（展开的那支不重复出现）
	#   · 只选中一支 → 画这支部队的**单位**（超 9 个滚轮翻页）
	var troops := _selected_troops(input_ctrl.selected_units)
	var current := _pick_troop(troops)
	var troop = null if current < 0 else troops[current]
	var troop_units: Array = []
	var unit_shorts: Array = []
	if troop != null and troops.size() == 1:
		troop_units = troop.get("units", [])
		unit_shorts = _unit_shorts(troop_units)
	detail_panel.set_troops(troop, _troops_without(troops, current), troop_units, unit_shorts)

	# 右栏：**地图上点到的那个单位优先**，否则是当前展开那支部队的将领
	# （需求原话：「默认为左侧栏中选中的部队将领头像，玩家点地图上某个单位时，
	#            该选中的单位为玩家点击的那个单位」）。
	var shown = _right_unit(troop)
	detail_panel.set_unit_avatar_text("" if shown == null else _unit_short(shown))
	# ★ 头像底部血条：没选中单位 → 不画；否则按它的血量比例画。
	detail_panel.set_unit_avatar_hp(1.0 if shown == null else shown.hp_ratio(), shown != null)
	# 头像只有图标 + 血条。
	detail_panel.set_unit_name("" if shown == null else String(shown.name))
	var urows: Dictionary = _unit_detail_rows(shown)
	detail_panel.set_detail_rows(urows["left"], urows["right"])
	# ★★ 2026.11.18：顶带那排 buff 槽现在**真的挂东西**了 —— 单位身上的状态
	#   （自由 / 水性 / 溺水 / 血战到底 / 信仰不死）。文字取自 config 的 unit.status，
	#   悬停浮窗用同一条 desc（与「水性地形」那些机制文案单一来源）。
	detail_panel.set_buffs(_unit_status_buffs(shown))
	# ★ 招募队列：显示**当前选中的第一个将领**的（选中整队时队长排在最前，
	#   见 input_controller.first_selected_leader）。没选中将领 → 整块收起来。
	detail_panel.set_queue(_queue_leader(troop), false)
	_v2_show_troops(troops, current, troop, shown)


## 左下角面板「向右滑进来」的**唯一实现**（详情牌用）。
##
## ★ 只动 `position:x`：y 由「贴底」锚点管，窗口缩放 / 中途再滑一次都不会被拉走；
##   `home_x` 是**建控件时量到的**目标 x（锚点左对齐 ⇒ 与父容器尺寸无关）。
func _left_slide_in(ctrl: Control, home_x: float) -> Tween:
	if ctrl == null:
		return null
	ctrl.position.x = home_x + DETAIL_SLIDE_FROM_X
	var tw := create_tween()
	tw.tween_property(ctrl, "position:x", home_x, DETAIL_SLIDE_SEC) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	return tw


func _play_detail_slide_in() -> void:
	if detail_v2 == null:
		return
	if _detail_slide_tween != null and _detail_slide_tween.is_running():
		_detail_slide_tween.kill()
	_detail_slide_tween = _left_slide_in(detail_v2, _detail_home_position.x)


func _has_unit_detail_selection() -> bool:
	return input_ctrl != null and input_ctrl.selected_enemy == null \
		and input_ctrl.selected_zone == null \
		and input_ctrl.selected_buildings.is_empty() \
		and input_ctrl.selected_units != null \
		and not input_ctrl.selected_units.is_empty()



# ------------------------------------------------------------------
# 新版详情面板（detail_v2）的数据组装
# ------------------------------------------------------------------

func _v2_show_troops(troops: Array, current: int, troop, shown) -> void:
	if detail_v2 == null:
		return
	var num := 0 if troop == null else int(troop.get("number", 0))
	detail_v2.set_roster(troops, num, shown)
	# 编制（当前人数 / 上限）：头部徽标 + 三格数值的第一格都用它
	var count := 0
	var cap := 0
	if troop != null:
		count = (troop.get("units", []) as Array).size()
		cap = _retinue_cap(troop.get("leader", null), count)
	var multi := troops.size() > 1
	var badge := "已选 %d 队" % troops.size() if multi \
		else ("编制 %d/%d" % [count, cap] if cap > 0 else "")
	var sub := _troop_title(troop)
	var icon_text := "" if shown == null else _unit_short(shown)
	var title := "" if shown == null else String(shown.name)
	var show_header_hp := shown != null
	if shown != null:
		var tags := _unit_tags(shown)
		if tags != "":
			sub = "%s · %s" % [sub, tags] if not multi else tags
		# 移速放副标题（数值三格里排不下了，而它又是玩家常看的一条）
		sub = "%s · 移速 %s" % [sub, _speed_text(shown)]
	if multi and troop != null:
		var focus_leader = troop.get("leader", null)
		icon_text = str(num)
		title = (String(focus_leader.name) if focus_leader != null else _troop_title(troop)) + "的部队"
		sub = "编制 %d/%d" % [count, cap]
		var focus_tags := "" if shown == null else _unit_tags(shown)
		if focus_tags != "":
			sub += " · " + focus_tags
		show_header_hp = false
	detail_v2.set_header(icon_text, title, sub,
		1.0 if shown == null else shown.hp_ratio(), show_header_hp, badge)
	detail_v2.set_stats(_v2_unit_stats(shown, count, cap))
	detail_v2.set_info_groups(_unit_info_groups(shown))
	detail_v2.set_notice(_notice_text())


## 一支部队的编制上限（与部队列表同一条口径：world.effective_retinue_cap）。
func _retinue_cap(leader, count: int) -> int:
	var cap: int = UiLayoutRes.UNIT_CAP
	if world != null and world.has_method("effective_retinue_cap") and leader != null:
		cap = int(world.effective_retinue_cap(leader))
	return maxi(cap, count)


## 单位的四格数值：编制 / 血量 / 攻击 / 防御
## （第一格绿色 —— 方向稿 `.hero-stat:first-child b`；移速走头部副标题，不占格子）
func _v2_unit_stats(shown, count: int, cap: int) -> Array:
	var stats: Array = [
		{"label": "编制", "value": "%d/%d" % [count, cap], "hot": true},
		{"label": "血量", "value": "—", "hot": false},
		{"label": "攻击", "value": "—", "hot": false},
		{"label": "防御", "value": "—", "hot": false},
	]
	if shown == null:
		return stats
	stats[1]["value"] = "%d%%" % int(round(float(shown.hp_ratio()) * 100.0))
	var dmg: int = int(round(shown.combat_damage(cfg)))
	stats[2]["value"] = "—" if dmg <= 0 else _fmt_num(dmg)
	stats[3]["value"] = _fmt_num(float(shown.armor))
	return stats


func _v2_show_building(b, entries: Array) -> void:
	if detail_v2 == null or b == null:
		return
	# 左列只留名字；血量等数值不在这次「简化」范围内显示。
	var simple: Array = []
	for e in entries:
		if e is Dictionary:
			var d: Dictionary = (e as Dictionary).duplicate()
			d["sub"] = ""
			simple.append(d)
	detail_v2.set_small_entries(simple, b, "building")
	detail_v2.set_header(_building_short(b), b.display_name(),
		"Lv%d · 归属 %s" % [int(b.level), _owner_text(String(b.owner))],
		b.hp_ratio(), true, "Lv%d" % int(b.level))
	detail_v2.set_stats([
		{"label": "等级", "value": "%d/%d" % [int(b.level),
			int(world.building_level_cap(b))], "hot": true},
		{"label": "血量", "value": "%d%%" % int(round(b.hp_ratio() * 100.0)), "hot": false},
		{"label": "远程免伤", "value": "%d%%" % int(round(
			cfg.building_ranged_reduction(String(b.type)) * 100.0)), "hot": false},
	])
	detail_v2.set_info_groups(_building_info_groups(b))
	detail_v2.set_notice(_notice_text())



func _v2_show_zone(z: Dictionary) -> void:
	if detail_v2 == null or z.is_empty():
		return
	var entry := {"ref": z, "name": _zone_title(z), "short": "区", "sub": ""}
	# ★ 区划招将的读条画在这一行底部（不再加「停招」小按钮）。
	var prog := 0.0
	if world.zone_is_training(z):
		prog = clampf(float(world.zone_train_progress(z)), 0.0, 1.0)
	entry["progress"] = prog
	detail_v2.set_small_entries([entry], z, "zone")
	var kind: Dictionary = world.zones.kind_entry_of(z)
	detail_v2.set_header("区", _zone_title(z),
		"%s · 归属 %s" % [String(kind.get("name", "区划")), _owner_text(String(z.get("owner", "")))],
		0.0, false, "人口 %d" % world.zones.population_floor(z))
	detail_v2.set_stats(_v2_zone_stats(z))
	detail_v2.set_info_groups(_zone_info_groups(z))
	detail_v2.set_notice(_notice_text())


## 区划的三格数值：粮食 / 黄金 / 人口上限（每秒产能）
func _v2_zone_stats(z: Dictionary) -> Array:
	var prod: Dictionary = z.get("production", {})
	var food := float(prod.get("food", 0.0))
	var gold := float(prod.get("gold", 0.0))
	var pop_cap := float(world.zones.population_cap_of(z)) if world != null else 0.0
	return [
		{"label": "粮食", "value": "+%s/s" % _fmt_num(food), "hot": true},
		{"label": "黄金", "value": "+%s/s" % _fmt_num(gold), "hot": false},
		{"label": "人口上限", "value": _fmt_num(pop_cap), "hot": false},
	]


func _v2_show_enemy_unit(e) -> void:
	if detail_v2 == null or e == null:
		return
	var entry := {"ref": e, "name": String(e.name), "short": _unit_short(e), "sub": ""}
	detail_v2.set_small_entries([entry], e, "enemy")
	detail_v2.set_header(_unit_short(e), String(e.name), _unit_tags(e),
		e.hp_ratio(), true, "敌军")
	var dmg: int = int(round(e.combat_damage(cfg)))
	detail_v2.set_stats([
		{"label": "血量", "value": "%d%%" % int(round(e.hp_ratio() * 100.0)), "hot": true},
		{"label": "攻击", "value": "—" if dmg <= 0 else _fmt_num(dmg), "hot": false},
		{"label": "防御", "value": _fmt_num(float(e.armor)), "hot": false},
	])
	detail_v2.set_info_groups(_enemy_unit_info_groups(e))
	detail_v2.set_notice(_notice_text())


func _v2_show_enemy_building(e) -> void:
	if detail_v2 == null or e == null:
		return
	var entry := {"ref": e, "name": e.display_name(), "short": _building_short(e), "sub": ""}
	detail_v2.set_small_entries([entry], e, "enemy")
	detail_v2.set_header(_building_short(e), e.display_name(),
		"Lv%d · 归属 %s" % [int(e.level), _owner_text(String(e.owner))],
		e.hp_ratio(), true, "敌军")
	detail_v2.set_stats([
		{"label": "血量", "value": "%d%%" % int(round(e.hp_ratio() * 100.0)), "hot": true},
		{"label": "等级", "value": _fmt_num(float(e.level)), "hot": false},
		{"label": "远程免伤", "value": "%d%%" % int(round(
			cfg.building_ranged_reduction(String(e.type)) * 100.0)), "hot": false},
	])
	detail_v2.set_info_groups(_building_info_groups(e))
	detail_v2.set_notice(_notice_text())


## 右侧提示：沿用旧的 notice（红字）。
func _notice_text() -> String:
	return detail_panel.notice_text() if detail_panel != null else ""


func _troop_title(troop) -> String:
	var names := ["", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
	var n := 0 if troop == null else int(troop.get("number", 0))
	if n >= 1 and n < names.size():
		return "部队" + names[n]
	return "部队"


func _unit_info_groups(u) -> Array:
	if u == null:
		return []
	var gen := _general_trait_entries(u)
	var unit_lines := _unit_trait_lines(u)
	# ★ 「属性」那一行（兵种 / 远近战 / 攻城）已经挪到头部的副标题里（方向稿的 `.hero-head small`），
	#   这里不再重复一遍。
	var out: Array = []
	# ★ 没有的特性组不画「无」——只显示玩家实际拥有的信息。
	if not gen.is_empty():
		out.append({"label": "将领特性", "type": "traits", "h": 74, "traits": gen})
	if not unit_lines.is_empty():
		out.append({"label": "单位特性", "type": "columns", "h": 90,
			"columns": _split_two_columns(unit_lines)})
	return out


func _enemy_unit_info_groups(u) -> Array:
	if u == null:
		return []
	var gen := _general_trait_entries(u)
	var lines := _unit_trait_lines(u)
	var out: Array = []
	if not gen.is_empty() and not lines.is_empty():
		out.append({"label": "特性", "type": "traits2", "h": 164,
			"general": gen, "unit_lines": lines})
	elif not gen.is_empty():
		out.append({"label": "特性", "type": "traits", "h": 74, "traits": gen})
	elif not lines.is_empty():
		out.append({"label": "特性", "type": "columns", "h": 90,
			"columns": [lines]})
	return out


func _building_info_groups(b) -> Array:
	if b == null:
		return []
	# ★ 等级 / 血量 / 远程免伤 / 归属都进了头部与三格数值，这里只留那些**独占**的信息。
	var lines: Array = []
	if String(b.type) == BuildingRes.TYPE_BASE:
		lines.append(_base_limits_text(int(b.level)))
	if b.is_attackable(cfg):
		lines.append("攻击 %s/%ss" % [
			_fmt_num(b.attack_damage(cfg)), _fmt_num(b.attack_cooldown(cfg))])
	else:
		lines.append("攻击 —")
	if b.neutralized:
		lines.append("已中立化")
	return [{"label": "特殊", "type": "text", "h": 164, "lines": lines}]


func _zone_info_groups(z: Dictionary) -> Array:
	if z.is_empty():
		return []
	var growth := float(z.get("population_growth_bonus", 0.0))
	var lines: Array = ["大小 %d 地块" % int(z.get("tile_count", 0))]
	if _zone_is_friendly(z) and world != null:
		lines.append("现有人口 %d" % world.zones.population_floor(z))
	# ★ 没有建筑加成就不显示那一条，不拿「无」占一行。
	if growth > 0.0:
		lines.append("建筑加成 人口 +%s/s" % _fmt_num(growth))
	return [{"label": "特殊", "type": "text", "h": 128, "lines": lines}]


func _unit_tags(u) -> String:
	var parts: Array = []
	if u == null:
		return ""
	if String(u.unit_class) != "":
		parts.append(cfg.class_display_name(String(u.unit_class)))
	parts.append("远程" if bool(u.ranged) else "近战")
	if bool(u.siege):
		parts.append("攻城")
	return " / ".join(parts)


func _unit_class_text(u) -> String:
	if u == null:
		return ""
	return cfg.class_display_name(String(u.unit_class))


func _general_trait_entries(u) -> Array:
	var out: Array = []
	if u == null or cfg == null:
		return out
	if u.has_method("has_general_aura") and u.has_general_aura():
		for tid in u.aura_traits:
			out.append({"name": cfg.general_trait_name(String(tid)),
				"desc": cfg.general_trait_desc(String(tid))})
	return out


## 单位自身特性（**不含**将领光环）：将领那一组单独显示。
func _unit_trait_lines(u) -> Array:
	var out: Array = []
	if u == null:
		return out
	for line in _attack_bonus_lines(u):
		if String(line).contains("（将）"):
			continue
		out.append(line)
	for line in _defense_bonus_lines(u):
		if String(line).contains("（将）"):
			continue
		out.append(line)
	return out


func _split_two_columns(lines: Array) -> Array:
	# ★ 两列每列只有 104px 宽：长文案（例如粮车的「回血光环……」）挤成两列会互相压字。
	#   只要有一行偏长，就退回**单列**，让它们从上往下排。
	for line in lines:
		if String(line).length() > 12:
			return [lines]
	var left: Array = []
	var right: Array = []
	for i in lines.size():
		if i < 2:
			left.append(lines[i])
		else:
			right.append(lines[i])
	return [left, right]


func _owner_text(owner: String) -> String:
	if world == null:
		return "—"
	if owner == "" or owner == "neutral":
		return "中立"
	if String(world.my_faction) == owner:
		return "己方"
	return "敌方"

## 选中部队分组：[{"leader": 队长, "number": 部队编号, "units": [该队单位…]}]。
##
## ★ 口径必须与左侧部队列表（view/squad_panel.gd）**完全一致**：
##   同方在场、`is_team_leader`、最多 SQUAD_SLOTS 支；编号优先取 `team_slots` 的
##   **稳定槽位**（阵亡 / 复活后不变），没有槽位表时才退回存活顺序。
func _selected_troops(units: Array) -> Array:
	# ★ 一次刷新内只扫一遍：`_tab_plan()` 与详情分支共用 `_begin_tick_cache()` 的结果。
	if _tick_cache_on:
		return _tick_troops
	return _compute_selected_troops(units)


## `_selected_troops()` 的实际实现（每次调用都会扫一遍 `world.units`）。
func _compute_selected_troops(units: Array) -> Array:
	troops_scans += 1
	var out: Array = []
	if world == null:
		return out
	if team_slots != null:
		team_slots.sync(world)
	var index_of: Dictionary = {}
	var n := 0
	for u in world.units:
		if not u.alive:
			continue
		if not FactionRes.same_side(u.faction, world.my_faction):
			continue
		if not world.is_team_leader(u):
			continue
		n += 1
		if n > UiLayoutRes.SQUAD_SLOTS:
			break
		if not units.has(u):
			continue
		index_of[u.id] = out.size()
		var no := n
		if team_slots != null:
			var s := int(team_slots.slot_of(u))
			if s > 0:
				no = s
		out.append({"leader": u, "number": no, "units": [u]})
	# 第二遍：把选中列表里的亲兵塞进它们队长那一组（选中列表已经是整队展开过的，
	# 所以这一步只是把「成员」补齐；找不到队长分组的（队长不在列表里）就忽略）。
	for u2 in units:
		if u2 == null or not u2.alive:
			continue
		if world.is_team_leader(u2):
			continue
		var leader = world.team_leader(u2)
		if leader == null or not index_of.has(leader.id):
			continue
		(out[int(index_of[leader.id])]["units"] as Array).append(u2)
	return out


## 「当前展开」的是第几支：优先 `_detail_troop_number`（玩家点的那一支），
## 它不在选中里了就退回第一支；一支都没有 → -1。
func _pick_troop(troops: Array) -> int:
	if troops.is_empty():
		_detail_troop_number = 0
		return -1
	for i in troops.size():
		if int(troops[i]["number"]) == _detail_troop_number:
			return i
	# ★ 记住的那一支已经不在选中里了（玩家改选了别人）→ 忘掉它，
	#   否则「选中 A → 又从左侧列表改选 B」时左栏会一直停在 A 上。
	_detail_troop_number = int(troops[0]["number"])
	return 0


## 下半网格要画的部队 = 选中的部队**去掉正在展开的那一支**。
##
## ★ 手玩原话：「被展开的部队不需要在下方的九宫格中显示」——它已经在上半那一行里了，
##   再列一次只会让人以为那是两支部队。
func _troops_without(troops: Array, skip: int) -> Array:
	var out: Array = []
	for i in troops.size():
		if i == skip:
			continue
		out.append(troops[i])
	return out


## 右栏要显示的单位。手玩把规则说死了（第四轮改版后按「怎么选中的」分）：
##
##   · 玩家**拖拽框选** / 点左侧部队列表 / 按 1-2-3 → 显示**展开那支部队的将领**；
##   · 玩家**鼠标单击地图上的某个单位** → 显示**玩家点到的那个单位**；
##   · 玩家点左栏下半**单位格** → 右栏切到那个单位（hud 那边会顺手记成 "click"）；
##   · 点**其余部队**的将领格（= 换展开）→ 右栏跟着变成那支部队的将领。
##
## 落点：
##   · 「这一次选中是怎么来的」由 `input_ctrl.selection_origin` 记（"click" / "drag"）；
##   · 「点到了谁」由 `input_ctrl.clicked_unit` 记（点地图 / 点左栏单位格都会写它）；
##   · `troop` 是**左栏当前展开**的那一支，所以「点到的是不是展开那支的成员」用
##     `_in_troop()` 一问就知道 —— 是就显示它，不是就退回展开那支的将领。
##
## ⚠️ 为什么不用「选中列表的最后一个」当判据（第一版就是那么写的）：一次点选与一次框选
##   出来的 selected_units 长得一模一样，框选之后右栏会莫名其妙报某个亲兵（实机截图见过）。
func _right_unit(troop):
	var leader = null if troop == null else troop.get("leader", null)
	var clicked = null
	if input_ctrl != null and String(input_ctrl.selection_origin) == "click":
		clicked = input_ctrl.clicked_unit
	if clicked != null and clicked.alive and _in_troop(clicked, troop):
		return clicked
	return leader


## 这个单位是不是**某一支部队的成员**（含它自己就是队长的情况）
func _in_troop(u, troop) -> bool:
	if u == null or troop == null:
		return false
	var units: Array = troop.get("units", [])
	return units.has(u)


## 一串单位在左栏格子方框里的**短字**（与 unit_roster.short_name 同一套口径，
## 由 detail_panel 转交给网格 —— 网格不认识 world，所以短字在这里算好）。
func _unit_shorts(units: Array) -> Array:
	var out: Array = []
	var roster = detail_panel.roster_control() if detail_panel != null else null
	for u in units:
		out.append("" if roster == null else roster.short_name(u))
	return out


## 招募队列跟着哪一位将领：当前展开那支部队的队长（没展开就退回选中列表里第一个队长）
func _queue_leader(troop):
	if troop != null:
		var l = troop.get("leader", null)
		if l != null:
			return l
	return input_ctrl.first_selected_leader() if input_ctrl != null else null


# ------------------------------------------------------------------
# 选中的敌人（敌对单位 / 敌对建筑）
#
# 需求原话：「玩家可以选中敌对单位/建筑（且只能单个选中），但其右下角不会显示任何页签
#            （有格子，但格子内没东西）」。
#
# ★ 这一节只做**显示**：操作入口一个都不给（页签那一列见 `_tab_plan` 的 enemy 分支，
#   命令卡是空的）。所以这里的文案也**不出现任何己方动作**（升级 / 特化 / 招募 / 编队）。
# ------------------------------------------------------------------

## 现在选中的敌人是单位还是建筑（""=没选中敌人）。
##
## ★ 判据只有一处：`input_ctrl.selected_enemy_kind()` —— 单位与建筑在 logic/ 里
##   没有共同基类，那种「靠字段猜类型」的事只该在一个地方做（见那个函数的注释）。
func _selected_enemy_kind() -> String:
	if input_ctrl == null:
		return ""
	return String(input_ctrl.selected_enemy_kind())


## 选中敌人时把详细信息面板刷成「它是什么」。
##
## ★★ 左栏**整块留空**（`set_troops(null, [])`）：左栏那 1 + 3×3 是「选中的己方部队 /
##    建筑」的编组视图，敌人只有**一个**、也进不了编组 —— 填进去只会让玩家以为
##    自己能指挥它。右栏照常报它的名称与数值（那是「看一眼它多硬」该有的信息）。
## ★ 右上角那块面板（招募队列 / 读条）也不给：`set_queue(null)`。
## ★ 选中**敌方的区划中心**时走的是这条路（不是区划详情那一条，见 input_controller
##   `_on_left_click` 里的归属判定）—— 否则玩家能给敌人的区划做特化。
func _refresh_enemy_detail() -> void:
	var e = input_ctrl.selected_enemy
	if e == null:
		return
	detail_panel.set_troops(null, [])
	detail_panel.set_queue(null)
	match _selected_enemy_kind():
		"unit":
			detail_panel.set_unit_avatar_text(_unit_short(e))
			detail_panel.set_unit_avatar_hp(e.hp_ratio(), true)
			detail_panel.set_unit_name(String(e.name))
			var urows: Dictionary = _unit_detail_rows(e)
			detail_panel.set_detail_rows(urows["left"], urows["right"])
			detail_panel.set_buffs([])
			_v2_show_enemy_unit(e)
		"building":
			detail_panel.set_unit_avatar_text(_building_short(e))
			detail_panel.set_unit_avatar_hp(e.hp_ratio(), true)
			detail_panel.set_unit_name(e.display_name())
			var brows: Dictionary = _building_detail_rows(e)
			detail_panel.set_detail_rows(brows["left"], brows["right"])
			detail_panel.set_buffs([])
			_v2_show_enemy_building(e)


# ------------------------------------------------------------------
# 右栏两列详情的**行构造**（本版新布局）
#
#   单位：左列 = 血量 / 攻击（+攻击增益）；右列 = 移速 / 防御（+防御增益）
#   建筑：左列 = 血量 / 攻击；右列 = 移速（—）/ 防御
#   区划中心：左列 = 类型 / 大小；右列 = 产能（占多排）+ 当前人口 + 特化
#
# ★ 行格式：`{"text": String, "small": bool, "dim": bool}`（见 view/detail_rows.gd）。
# ★ 所有文案只在这一节组装；detail_panel 只负责排版。
# ------------------------------------------------------------------

## 区划的标题（右栏「单位名称」那一行显示的）：只写区划名本身。
func _zone_title(z: Dictionary) -> String:
	return String(z["name"])


## 建筑的短字（头像方块里的占位）
func _building_short(b) -> String:
	var n: String = b.display_name()
	return n.substr(0, 1) if n.length() > 0 else "建"


## 选中单位的短字（头像方块里的占位）：将领 = 名字首字，兵种 = 招募表里的 short
func _unit_short(u) -> String:
	if u == null:
		return ""
	if world != null and world.is_recruitable(String(u.kind)):
		return world.recruit_short_of(String(u.kind))
	var n: String = String(u.name)
	return n.substr(0, 1) if n.length() > 0 else "?"


## 一条主数值行（13 号字、正文色）
func _row(text: String) -> Dictionary:
	return {"text": text, "small": false, "dim": false}


## 一条增益行（11 号字、次要色；文案自己带「- 」前缀）
func _small_row(text: String) -> Dictionary:
	return {"text": text, "small": true, "dim": true}


## 把 row 字典拼成旧接口那种「左 \t 右」文本（测试 / 旧调用点用）
func _rows_text(rows: Dictionary) -> String:
	var left: Array = rows.get("left", [])
	var right: Array = rows.get("right", [])
	var out: Array[String] = []
	for i in maxi(left.size(), right.size()):
		var l: String = _row_text(left, i)
		var r: String = _row_text(right, i)
		out.append("%s\t%s" % [l, r] if r != "" else l)
	return "\n".join(out)


func _row_text(rows: Array, i: int) -> String:
	if i < 0 or i >= rows.size():
		return ""
	var row = rows[i]
	if row is Dictionary:
		return String((row as Dictionary).get("text", ""))
	return String(row)


## 移动速度：**基础值 + 地形变化**，如 `3(-1.5)`（3 = 原始移速，-1.5 = 森林减益）。
## 没有变化时只写基础值。
func _speed_text(u) -> String:
	if u == null or not u.has_method("speed"):
		return "—"
	var base: float = float(u.speed(cfg, null))
	var cur: float = float(u.speed(cfg, world.map if world != null else null))
	var delta: float = cur - base
	if absf(delta) < 0.05:
		return _fmt_num(base)
	return "%s(%s%s)" % [_fmt_num(base), "+" if delta > 0.0 else "", _fmt_num(delta)]


## 单位的两列详情（血量/攻击 | 移速/防御）。
func _unit_detail_rows(shown) -> Dictionary:
	var left: Array = []
	var right: Array = []
	if shown == null:
		return {"left": [_row("未选中")], "right": []}

	left.append(_row("血量 %d/%d" % [int(round(shown.hp)), int(round(shown.hp_max))]))
	right.append(_row("移速 %s" % _speed_text(shown)))

	# ---- 左列第二排起：攻击力 / 攻击频率 + 攻击增益 ----
	if shown.is_downed():
		left.append(_row("攻击 —"))
		left.append(_small_row("- 濒死：无法行动"))
	else:
		var dmg: int = int(round(shown.combat_damage(cfg)))
		if dmg <= 0:
			left.append(_row("攻击 —"))
		else:
			left.append(_row("攻击 %s/%ss" % [_fmt_num(dmg),
				_fmt_num(shown.combat_cooldown(cfg, world))]))
	for line in _attack_bonus_lines(shown):
		left.append(_small_row("- %s" % line))
	# ★★ 将领特性（部队光环）的名字：效果行由上下两列按类型分别显示，
	#    这里单独写一条名字，让玩家知道「这些（将）字增益来自哪几条特性」。
	#    ★★ 2026.11：一位将领可以带多条 ⇒ 用「、」连起来。
	if shown.has_method("has_general_aura") and shown.has_general_aura():
		var names: Array = []
		for tid in shown.aura_traits:
			names.append(cfg.general_trait_name(String(tid)))
		left.append(_small_row("- 特性 %s" % "、".join(names)))

	# ---- 右列第二排起：防御力 + 防御增益 ----
	# ★★ 「防御」现在就是**固定护甲值**（本轮新增）：每次受击先减这么多点。
	var armor_v: int = int(round(float(shown.armor)))
	right.append(_row("防御 %d（每击先减）" % armor_v if armor_v > 0 else "防御 0"))
	for line in _defense_bonus_lines(shown):
		right.append(_small_row("- %s" % line))
	return {"left": left, "right": right}


## 攻击特殊增益：**兵种特性**「对某大类伤害 +x%」（config 的 `unit.types.<id>.traits`）。
##
## ★ 文案里的「骑兵 / 步兵」取自 config 的 `unit.classes`（`cfg.class_display_name`，
##   **参数是大类 id 本身**）—— 代码里不写中文字面量，以后改大类名只改 JSON。
##   ⚠️ 别用 `cfg.unit_class_name(cls)`：那条的参数是**单位类型 id**（"rider"），
##     拿大类 id（"cavalry"）去查会兜底成步兵，整句变成「对步兵伤害」。
## ★ 按大类 id 排序再输出：字典的顺序不该影响每次刷新时的行序（同一单位两次刷新
##   行序不同会让 detail_rows 的签名一直变、每帧重画）。
## ⚠️ 这里显示的是**特性本身**（静态规则），不是「这一次打谁生效了」。
func _attack_bonus_lines(u) -> Array[String]:
	var out: Array[String] = []
	if u == null or cfg == null or not u.has_method("attack_multiplier_vs_class"):
		return out
	var bonus: Dictionary = u.attack_bonus_vs_class
	var classes: Array = bonus.keys()
	classes.sort()
	for cls in classes:
		var pct: int = int(round(float(bonus[cls]) * 100.0))
		if pct <= 0:
			continue
		out.append("对%s +%d%%" % [cfg.class_display_name(String(cls)), pct])
	# ★★ 将领特性（步兵 / 骑兵特攻）：与兵种特性同列，但标一个「（将）」——
	#   两者在 unit.attack_multiplier_vs_class 里是**加算**的，分开写才能看出各占多少。
	var aura: Dictionary = u.aura_attack_vs_class
	var aura_classes: Array = aura.keys()
	aura_classes.sort()
	for cls in aura_classes:
		var pct2: int = int(round(float(aura[cls]) * 100.0))
		if pct2 <= 0:
			continue
		out.append("对%s +%d%%（将）" % [cfg.class_display_name(String(cls)), pct2])
	# ★★ 本轮新增的兵种玩法（静态规则；从单位出生时抄好的字段读）。
	if bool(u.siege):
		out.append("攻城：无视远近减伤")
	if float(u.splash_radius) > 0.0:
		out.append("范围伤害 %s 格" % _fmt_num(u.splash_radius))
	if bool(u.move_shoot):
		out.append("移动射击")
	if float(u.heal_aura_rate) > 0.0:
		out.append("回血光环 %s/秒（%s 格）" % [
			_fmt_num(u.heal_aura_rate), _fmt_num(u.heal_aura_radius)])
	# ★★ 2026.11：击退 / 直线穿透（王朝投石车、帝国扭力弩炮）。
	#   两条都只在**配了**的兵种上出现（0 / false ⇒ 一个字都不加，老文案逐位不变）。
	if float(u.knockback_distance) > 0.0 or float(u.knockback_stun_sec) > 0.0:
		out.append("击退 %s 格 / 眩晕 %s 秒" % [
			_fmt_num(u.knockback_distance), _fmt_num(u.knockback_stun_sec)])
	if bool(u.pierce):
		out.append("直线穿透")
	return out


## 防御特殊增益：兵种特性 / 将领抵抗（全部是静态或已抄到单位的数）。
func _defense_bonus_lines(u) -> Array[String]:
	var out: Array[String] = []
	if u == null:
		return out
	# ★★ 兵种特性：对远程减伤（只有写了 traits.ranged_reduction 的兵种才有）
	if float(u.ranged_damage_reduction) > 0.0:
		out.append("远程减伤 +%d%%" % int(round(float(u.ranged_damage_reduction) * 100.0)))
	# ★★ 2026.11：对**近战**减伤（「远近免伤+」的另一半）与**稳定**。
	#   顺序放在远程那条之后：老单位的文案数组逐位不变（它们这两条都是 0 / false）。
	if float(u.melee_damage_reduction) > 0.0:
		out.append("近战减伤 +%d%%" % int(round(float(u.melee_damage_reduction) * 100.0)))
	if bool(u.knockback_immune):
		out.append("稳定：免击退/眩晕")
	# ★★ 将领特性：近战 / 远程抵抗（两者互斥，同一单位只会有一条）。
	#   标「（将）」是因为它们与上面那条同类。
	if float(u.aura_melee_reduction) > 0.0:
		out.append("近战减伤 +%d%%（将）" % int(round(float(u.aura_melee_reduction) * 100.0)))
	if float(u.aura_ranged_reduction) > 0.0:
		out.append("远程减伤 +%d%%（将）" % int(round(float(u.aura_ranged_reduction) * 100.0)))
	return out


## 建筑的两列详情（区划中心 → 走区划那一套）。
func _building_detail_rows(b) -> Dictionary:
	if b == null:
		return {"left": [_row("未选中")], "right": []}
	if b.type == BuildingRes.TYPE_ZONE_CENTER:
		var z = world.zone_of_center_building(b)
		if typeof(z) == TYPE_DICTIONARY:
			return _zone_detail_rows(z, _zone_is_friendly(z))
	var left: Array = []
	var right: Array = []
	left.append(_row("血量 %d/%d" % [int(round(b.hp)), int(round(b.hp_max))]))
	right.append(_row("移速 —"))
	if b.is_attackable(cfg):
		left.append(_row("攻击 %s/%ss" % [
			_fmt_num(b.attack_damage(cfg)), _fmt_num(b.attack_cooldown(cfg))]))
	else:
		left.append(_row("攻击 —"))
	# ★★ 2026.10.26：所有建筑对远程伤害免伤 90%（攻城伤害不走这一条）。
	right.append(_row("远程免伤 %d%%" % int(round(
		cfg.building_ranged_reduction(String(b.type)) * 100.0))))
	if String(b.type) == BuildingRes.TYPE_BASE:
		right.append(_row("等级 %d/%d" % [b.level, world.building_level_cap(b)]))
		right.append(_small_row(_base_limits_text(b.level)))
		if b.neutralized:
			right.append(_row("已中立化"))
	return {"left": left, "right": right}


## 区划中心的两列详情：左 = 类型 / 大小；右 = 产能（多排）+ 当前人口 + 建筑加成。
func _zone_detail_rows(z: Dictionary, show_population: bool = true) -> Dictionary:
	var left: Array = []
	var right: Array = []
	var kind_entry: Dictionary = world.zones.kind_entry_of(z)
	var kind_name := String(kind_entry.get("name", "区划"))
	left.append(_row(kind_name))
	left.append(_row("大小 %d 地块" % int(z["tile_count"])))

	var prod: Dictionary = z["production"]
	# ★ 基础产能是每秒绝对值；大本营 / 房屋的固定人口加成直接叠进显示值。
	var food := float(prod["food"])
	var gold := float(prod["gold"])
	var pop := float(prod["population"]) + float(z.get("population_growth_bonus", 0.0))
	var pop_cap := float(world.zones.population_cap_of(z))
	right.append(_row("粮食 %s/s" % _fmt_num(food)))
	right.append(_row("黄金 %s/s" % _fmt_num(gold)))
	right.append(_row("人口 %s/s" % _fmt_num(pop)))
	right.append(_row("人口上限 %s" % _fmt_num(pop_cap)))
	if show_population:
		right.append(_row("现有人口 %d" % world.zones.population_floor(z)))
	var growth_bonus := float(z.get("population_growth_bonus", 0.0))
	if growth_bonus > 0.0:
		right.append(_small_row("- 建筑人口加成 +%s/s" % _fmt_num(growth_bonus)))
	# ★★ 将领招募冷却：选中己方区划时给一行常驻倒计时，
	#    玩家不必把鼠标停在灰卡上才知道还要等多久。
	if show_population and world != null:
		var cd_left: float = world.general_recruit_cooldown_left(world.my_faction)
		if cd_left > 0.0:
			left.append(_small_row("将领招募冷却 %ss" % _fmt_num(cd_left)))
	return {"left": left, "right": right}


## 旧接口：单位文案（两侧拼成 `左 \t 右`，测试 / 旧调用点仍可读）。
## ⚠️ 新代码请直接用 `_unit_detail_rows()` 喂 detail_panel.set_detail_rows()。
func _unit_text(shown, _troops: Array = []) -> String:
	return _rows_text(_unit_detail_rows(shown))


## 旧接口：建筑文案。
func _building_text(b) -> String:
	return _rows_text(_building_detail_rows(b))


## 旧接口：区划中心文案。
func _zone_text(z: Dictionary, show_population: bool = true) -> String:
	return _rows_text(_zone_detail_rows(z, show_population))


## 旧接口：敌对单位文案（本版与己方同一套两列布局）。
func _enemy_unit_text(u) -> String:
	return _unit_text(u)


## 旧接口：敌对建筑文案（本版与己方同一套两列布局）。
func _enemy_building_text(b) -> String:
	return _building_text(b)


## 这个区划是不是**自己 / 友军**的（用于「当前人口给不给看」与「给不给操作页签」）。
##
## ★ 判据走 `FactionRes.same_side`（盟友算同一方）—— 与占领 / 资源 / 视界那几处同一套口径。
## ★ 空 owner（无主）恒为 false：`same_side(任何, "")` 为假（见 logic/faction.gd）。
func _zone_is_friendly(z: Dictionary) -> bool:
	if z == null or world == null:
		return false
	return FactionRes.same_side(String(z.get("owner", "")), String(world.my_faction))


## 数字显示：整数就不带小数点；小数最多 3 位、末尾的 0 去掉
## （与地图编辑器 / 导出的 JSON 同一种写法）。
##
## ⚠️ 这里踩过一次（实机刷屏报错）：
##     `E 0:00:28:967 hud.gd:770 @ _fmt_num(): String formatting error:
##      unsupported format character` —— 小数那一路原来写的是 `"%g" % v`，
##     而 **Godot 的 `%` 格式化没有 `%g`**（支持的是 %s %c %d %o %x %X %f %v %%），
##     于是「区划的人口产能不是整数」时每帧都报一次，还连着后面所有取值一起失败。
##   现在用 `%f`（Godot 一定支持）+ 手工去掉尾部的 0 与小数点 —— 结果与原意一致，
##   也不依赖引擎版本对格式符的支持范围。
func _fmt_num(v: float) -> String:
	if is_nan(v) or is_inf(v):
		return "0"
	if absf(v - round(v)) < 1e-9:
		return "%d" % int(round(v))
	var s := "%.3f" % v
	while s.ends_with("0"):
		s = s.substr(0, s.length() - 1)
	if s.ends_with("."):
		s = s.substr(0, s.length() - 1)
	return s


# ------------------------------------------------------------------
# 事件：本版**不再显示**
#
# 按需求把「详细信息」右栏的事件日志整块删掉了，所以这里没有 consume_events /
# push_line / toast / _format_event —— 逻辑层照旧把事件收集进 world.tick() 的返回值
# （那是「逻辑不写 UI」这条边界，测试也在用），只是当前没有任何界面把它们画出来。
#
# ★ 想恢复日志：把 detail_panel 里的日志栏加回来、在这里把事件翻成文案即可，
#   事件本身一条都没少（types 见 logic/world.gd 与 logic/combat.gd 的 push_event）。
# ------------------------------------------------------------------
