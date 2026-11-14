# 更新记录

> 本文件由原 README 的更新日志拆出，按时间倒序保留。项目概览、快速开始和文档索引见 [README.md](README.md)。  
> AI 的**当前行为**不要从本文件推断，请看 [ai-commander-current-status.md](ai_doc/ai-commander-current-status.md)。

## dev_gd_a

本版本为在godot引擎内的原型开发，仅展示完整的局内玩法

### 2026.11.14（第十轮）测试断言全面align到新模型

把上一轮遗留的「按旧队列模型写的断言」全部改成新行为，套件回到基线（只剩两条既有失败：`test_ai_test_campaigns` 11 + `test_unit_traits` 1）。

- `test_recruit_queue.gd`：整文件重写 —— 「入队 / 读条 / 取消 / 退款 / ETA」全部换成**即时招募**：当场出兵、无队列、无「招募中」、连招无冷却、满编/欠钱/没人口/敌方区划/防冒充逐条拒因、三个兵落在不同格、命令路径同样即时、区划招将即时且**招走后牌消失**、快照往返后已出生的兵仍在。
- `test_zone_recruit.gd`：取消/退款/队列上限那几节改成「没有队列可取消（取消被拒）」「连招多位不同将领各自落地」；特性断言从「队列里带着 swift」改成「招出来的将领身上带着 swift」；命令路径改成「即时出人 + cancel 被拒」。
- `test_ui.gd`：招募页从「固定九宫格 = 将领 1..9」改成「**只列还没被招走的将领**」（招走一位少一张）；区划招募卡那段改成「点一下当场出人 + 招走的那张牌从手牌消失」；五格队列面板 / ETA / 汇总那套断言删掉（面板已无内容），只保留「永远收起」；`recruit_queued` 事件断言改成 `unit_recruited`；单点招募从「进入读条」改成「当场多一个兵」（并先腾出编制名额，避免受前面用例的 cap 影响）。
- `test_retinue` / `test_downed` / `test_ai` / `test_clan` / `test_general_traits`：入队 → 当场出兵；「阵亡退款」→「钱当场花掉、不退」；「组合单位占 1 个队列格」→「一次出整包」；「队列里带特性」→「将领身上带特性」。
- 全量：**122 套 / 11404 项 = 11392 过 / 12 红**（红的仍是那两条既有失败）。

### 2026.11.14（第九轮）点空地不再清选中 / 招走后招募页那张牌消失

1. **需求**：「取消掉单击取消选中的逻辑，只能通过右侧标签栏和点击部队选中/退选」+「当将领被招募后，将领招募页的该将领牌会消失」。
2. **单击不再取消选中**（`input_controller._on_left_click`）：
   - 点**空地** ⇒ **什么都不做**（原来末尾那句 `select_units([])` 删掉）—— 随手点一下地图不会再把队伍弄丢；
   - 点**已经选中的部队**（含它旗下附属兵）⇒ 退选；
   - 点别的己方部队 / 敌单位 / 建筑 / 区划中心 ⇒ 照旧换成那一个；
   - 右侧标签栏那条本来就是「点一次选中、再点一次反选」（`gesture_release → _toggle_team`），没动。
   - Esc 的级联也照旧（没选中 → 开菜单 / 有选中 → 清选中）。
3. **招募页招走后消失**：`world.general_recruit_available(faction)` = `general_recruit_roster()` 去掉**已拥有**的；HUD 的 `_zone_recruit_entries()` 改读它 ⇒ 招走一位，那张牌**从牌面上消失**（不再是灰着占位），剩下的牌顺次收拢。
   ⚠️ `general_recruit_roster()` 本身不改（它是九宫格的权威清单，测试 / 编辑器 / AI 都还按它看全局），只加一层过滤。
4. **验证**（窗口探针）：点部队 → `sel=1`；点空地 → `sel=1`（不清）；再点同一支部队 → `sel=0`；区划招将领成功后 `general_recruit_available` 9 → 8 且不再包含该将领。
5. **⚠️ 仍未完成（与上一轮同一批）**：`test_recruit_queue.gd`、`test_zone_recruit.gd`、`test_ui.gd`（59 红）、`test_downed.gd`、`test_retinue.gd` 里仍按**旧队列模型**断言。产品代码已按新模型跑通（探针为证），测试迁移待做。

### 2026.11.14（第八轮）拖拽不取消选中 / 招募全面即时化 / 冷却前沿改直线

1. **需求**：「拖拽移动时不需要取消选中」+「单位招募不需要队列了，招募变为即时，只要拖拽单位牌生效就是招募完成」+「操作页的填充冷却的进度条是底边的形状，不需要贴合底边，只需要是直线即可」。口径：**招募冷却也去掉**、**区划招将领一起即时化**、**读条牌 / 取消牌 / `train_sec` 一起清掉**。
2. **拖拽不取消选中**：左键**按下那一下**就执行了单击（选中 / 清空），而「这一下其实是拖地图」要等越过阈值才知道 —— 于是拖一下地图队伍就没了。
   ⇒ 重新引入「按下前快照」（`_save_selection_snapshot` / `_restore_selection_snapshot`），真的转成平移时按原样还原（单位 / 建筑 / 区划 / 敌人四种选中都还原，走既有 `select_*` 入口）。
3. **冷却前沿改直线**：暗纱原来用 `corner_radius_all = 9` ⇒ 下沿（冷却前沿）顺着牌底圆角拐弯。改成**只给上面两个角**圆角、下沿 0 半径 ⇒ 前沿是一条水平直线，牌顶仍贴着卡片圆角。
4. **招募即时化（核心）**：
   - `world.start_recruit()` 入队 → **当场生成**：扣完钱直接走 `_spawn_from_recruit()`（与「读条完成」同一条出生路径，出生格 / 组合单位 / 继承命令 / 光环全不变）；不再写 `train_cost_*` 记账（没有队列可退）。
   - `world.start_zone_recruit()` 同样当场 `_spawn_zone_recruit()`（区划招将领也是即时）；`_spawn_zone_recruit()` 改成可显式接收「招募方 / 特性」，兼容旧字段。
   - 删掉 `_tick_recruitment` / `_tick_zone_recruitment` / `_start_training` / `_start_zone_training` / `_start_next_zone_queue` 与它们的 tick 调用；`can_recruit` 去掉「队列已满」这一关（**编制上限仍在**）。
   - HUD：删掉「读条牌（×N + 进度）」「取消招募牌」、`_progress_leader` / `_sync_card_queue` / `_has_recruit_progress_card`、单位页格子的 `queue_progress` / `queue_count` 同步、`_card_sig` 里那段队列签名。
   - 多选招募的摊单判据从「队列最短」换成「**队伍人数最少**」（`_pick_recruit_leader`）—— 队列恒为 0 之后旧判据会永远挑第一支。
   - 冷却：单位牌本来就没有冷却（`ready` 只由大本营等级决定），即时化后连招只受钱 / 人口 / 编制上限约束 ✓；**将领招募池**那条全局冷却（`general_recruit_cooldown_*`）**保留**（它是「招走一位后多久能招下一位」的池子节奏，不是队列读条）。
5. **验证**：窗口探针实测「单位页拖出一张枪兵牌 → `retinue 0 → 1`、`training=false`、`queue=0`、扣粮」；连招第二单再 +1。
6. **⚠️ 未完成（测试迁移）**：套件里还有按**旧队列模型**写的断言要改写 —— `test_recruit_queue.gd`（整文件 25 处 / 82 项红）、`test_zone_recruit.gd`（21）、`test_ui.gd`（区划招募页 + 五格面板，37）、`test_downed.gd`（3，将领阵亡退款已无意义）、`test_retinue.gd`（2）。产品代码已按新模型跑通，测试迁移未完。
7. **落点**：`logic/world.gd`、`view/{hud,input_controller,command_card}.gd`、探针已删。

### 2026.11.14（第七轮）冷却遮罩改「填充」/ 修跨页残留 / PC 输入大改（右键空、左拖平移）

1. **需求**：「当我的单位移动时，我的建筑牌也会有进度条」+「进度条还是需要改为填充而不是一根条」+「将 pc 端的右键逻辑和拖拽逻辑大改：右键取消掉移动/行军/攻击指令，完全由出牌代替，左键拖拽改为移动视角，取消掉拖拽选框」。
2. **跨页残留（bug）**：命令卡那九颗按钮是**跨页复用**的 —— 操作页盖上的冷却标记，切到建筑页会留在同一颗按钮上，于是「我的单位移动时，建筑牌也有进度条」。
   ⇒ `set_entries()` 换页时**先把遮罩收掉**；`set_order_cooldown()` 也按条目类型逐格收回（非 `order` 条目一律隐藏）。
3. **进度条 → 填充**：原来是一条 6px 的细条（底槽 + 金色走条），用户口径要「填充而不是一根条」。
   ⇒ 每格改成一张**暗纱**（`Panel` + 圆角 `StyleBoxFlat`，圆角跟着牌走、不会顶出方角）：高度 = **剩余冷却比例**，贴牌顶往下长；随冷却推进下沿一路往上退（牌面从下往上露出来），下沿那条 2px 亮线就是「冷却前沿」。API 仍是 `set_order_cooldown(left, total)`（传剩余秒数，0 = 没冷却）。
   ⚠️ 踩过：早先传「已过比例」时 0 既表示「刚开始」又表示「没冷却」，冷却结束后牌面会一直盖着纱。
4. **右键完全空着**：`_on_right_click()` 收成一个**明确的空实现** —— 单击 / 双击都不再发移动 / 行军 / 攻击，也不再退出建造 / 命令模式（退出走 Esc 或再点同一格）。
   - 唯一保留的一支：**观战授权**（`observer_ai_orders`，ai_test_2 的 AI 面板选点）的「右键 = 取消选点」——那不是玩家下令，且是该模式唯一的取消入口。
   - 手机端原来靠转调 `_on_right_click` 下命令，右键空掉后会静默失效 ⇒ `touch_tap` / 连点两下改走新出口 `issue_order_at()`（与操作牌同一条下达路径），手机手感不变。
5. **左键拖拽 = 平移视角 + 惯性**：`_begin_drag` / `handle_mouse_motion` / `_finish_drag` 那条状态机从「框选」改成「拖拽平移」——
   - 越过 `ui.drag_select_min_px` 阈值才转档（单击仍是一次选中，不会因为几像素抖动变成平移）；
   - 平移量与中键那条同一口径：`pan_screen(-delta)`，1:1 「抓着地图拖」；
   - 松手后**带惯性滑行**：速度 = 拖动中指数平滑出来的屏幕速度，`exp(-dt/0.16)` 衰减，约 0.5 秒滑完，上限 2600px/s；任何新输入（按下 / 滚轮 / 中键 / 键盘 / 触屏）立刻掐掉；
   - `is_dragging_box()` / `is_panning()` 都并进了「平移中 / 滑行中」，边缘滚屏照旧让路。
6. **取消框选 + 不要多选**：PC 不再调 `box_select*`；左键点单位永远是「换成这一支」（`select_units([hit])`），Shift / Ctrl 加选与「再点一次取消」都去掉。`box_select()` / `box_select_screen()` **保留**给手机端双指框选（那条路一点没动）。
7. **测试**：`test_ui` **1461 项**（把框选用例整段改写成拖拽平移：越阈值才转档、相机真的跟手、松手起滑行且 2 秒内自停、拖拽不改选中、拖到底栏上继续跟手；右键改用例全部改成「不发命令」；冷却断言改成读遮罩高度）；`test_friendly_building` 13、`test_view3d` 336 改成出牌路径。全量 **122 套 / 11681 项 = 11669 过 / 12 红**（红的仍是 `test_ai_test_campaigns` 11 + `test_unit_traits` 1）。
8. **落点**：`view/{command_card,input_controller,game_scene3d}.gd`、`tests/{test_ui,test_friendly_building,test_view3d}.gd`；展示图 `shots/42_cooldown_veil.png`。

### 2026.11.14（第六轮·修）操作牌冷却「看起来没生效」的三处真因

用户报：「我发现操作牌的冷却并没有生效」。查下来是**三个各自独立的坑**，一起修：

1. **`cell.disabled` 挡不住拖拽**（功能性，主因）：Godot 的 `Control` 是**先发 `gui_input` 信号、再走 `_gui_input` 虚函数**，而 `Button.disabled` 只让 `pressed` 不触发 —— 所以置灰的牌照样能被 `command_card._on_cell_gui_input` 拖起来、照样能在松手时下达命令。
   ⇒ 新增 `command_card._card_ready(i)`，在 `_on_cell_gui_input`（按下）与 `_update_drag_position`（越过上拖阈值）两处各判一次；`hud._commit_order_drag()` 再兜一道（拒绝 + 提示「这张操作牌还在冷却（x.x 秒）」）。
2. **冷却只按「队长」记账**：玩家完全可以只选中一队**亲兵**（没有将领本人），那时按队长 id 取 key 一个都拿不到 ⇒ 冷却静默不生效。
   ⇒ 改成按**部队 id**：附属兵用 `leader_id`（本来就是所属部队 id），将领用自己 `id`。一支部队只有一个 key。
3. **进度条看不见**：原来走 `IconView.set_progress()`，那条进度画在**图标区**，而操作牌没有图标蒙版、只有一个大字形 —— 走条被字形压住，几乎看不出来。
   ⇒ `command_card` 每条命令格新增 `CdTrack`/`CdFill` 两个 `ColorRect`，画一条**贴牌底**（名字条上方）的 6px 进度条，3 秒里从左往右长满后整条消失。
   ⚠️ API 传的是**剩余秒数**（`set_order_cooldown(left, total)`）而不是「已过比例」：0 既表示「刚开始」又表示「没冷却」，两者分不开（实测冷却结束后牌底留着一条空槽）。

**测试**：`test_ui` **1468 项**，新增「冷却中拖不起来」「冷却中松手也下达不了」「牌面进度条可见 / 有过半那一段」；另外把两处写死的松手像素改成「先找一个不被 UI 盖住的地图点」（测试视口比设计空间小，写死的点可能正好压在面板上，被 `point_hits_ui` 判成取消）。全量 **122 套 / 11688 项 = 11676 过 / 12 红**（红的仍是 `test_ai_test_campaigns` 11 + `test_unit_traits` 1）。

### 2026.11.14（第六轮）操作牌：拖出选点（旗帜虚影 / 攻击吸附）+ 每队 3 秒冷却

1. **需求**：「操作牌拖出后，可在地图上选择落点，落点将以一个旗帜虚影显示，「攻击」牌会有额外的旗帜吸附效果，会吸附到鼠标落点最近的敌方单位/建筑上，「暂停（停止）」牌没有旗帜虚影；操作牌在拖出并松手后，落点处即为操作点」+「部队的操作牌有三秒冷却，每个部队单独计算，拖出生效并回到手牌后，牌面会出现进度条提示冷却」。
2. **下达方式（新）**：不再「点格子 → 进命令模式 → 再点地图」。拖起即出虚影，**松手处就是操作点** ——
   - `input_controller.issue_order_at(mode, screen_pos)`：在**指定屏幕点**下达，走的是原来 `_issue_order_click()` 那条共用路径（同样的命令字典），只是落点由参数给，并且**不进命令模式**；
   - 「停止」牌不走选点：拖出松手就地 `request_stop()`（也没有虚影）。
3. **旗帜虚影**：`hud._begin/_update/_end_order_ghost()` 管落点与吸附，`overlay_view_3d._draw_order_ghost()` 画（屏幕空间：贴地双圆环 + 旗杆 + 三角旗面），`game_scene3d._sync_order_ghost()` 每帧把状态抄给 overlay。颜色跟牌走：**绿=移动 / 黄=行军 / 红=攻击**；吸附上敌人时更红一档并多套一圈。
   - 拖起的牌被抬到指针**上方**（`ORDER_DRAG_LIFT`）并变半透明（0.72）—— 否则 216×206 的牌会把虚影整个盖住（实测截图就是一片牌面）。
   - 指回 UI（手牌 / 面板）⇒ 虚影收起；**松手在 UI 上 = 取消**（不下达、不进冷却），与建筑牌「拖回手牌取消」同一套手感。
4. **攻击吸附**：`hud._nearest_foe_for_order()` 取 90px 内最近的敌方单位 / 建筑。判据与真正下达那一路**逐条一致**（活着、看得见（战争迷雾）、不同阵营、非无敌、濒死将领不算）—— 否则会出现「旗吸上去了，松手却说这里没有敌人」（实测踩到：吸到雾里的一栋塔）。吸不到 ⇒ 牌退回 + 提示「这里没有敌人」，**不进冷却**。
5. **3 秒冷却（每支部队）**：`_order_cd` 按**队长 id** 记（多选取最慢的那支，下达时给所有选中的队长都起冷却）。冷却中整页 `ready = false`（格子变灰、拖不起来）+ 牌面进度条（`command_card.set_order_cooldown()`，每帧只推 `IconView.set_progress()`，不重建九格；只有「可不可用」这一位进 `_card_sig()`）。冷却**由 `command_issued` 信号触发**，所以「拖出松手」和「键盘 Q/W/E/A + 点地图」两条路都算，不会出现两套规则。
6. **顺带修的**：触摸松手原来用 `get_mouse_position()` 当落点（触屏根本没有鼠标，会打在不相干的地方）⇒ `finish_touch_drag(i, pos)` 现在接受手指最后的位置（`hud._lp_last_pos`）。
7. **测试**：`test_ui` **1463 项**新增/改写 —— 拖起时指针还在手牌上所以「暂无虚影」、拖到地图上出现虚影、「松手即下达 move」、下达后进冷却、冷却过半进度条 ≈50%、3 秒后恢复、拖回手牌取消（不下达 / 不进冷却 / 虚影不残留）、触屏拖出同样下达并起冷却。全量 **122 套 / 11683 项 = 11671 过 / 12 红**（红的仍是 `test_ai_test_campaigns` 11 + `test_unit_traits` 1）。
8. **落点**：`view/{hud,input_controller,command_card,overlay_view_3d,game_scene3d}.gd`、`tests/test_ui.gd`；展示图 `shots/40_order_ghost_move.png` / `shots/41_order_ghost_attack.png`。

### 2026.11.14（第五轮）投影层级 / 去掉四角 / 页签悬停金填 / 科技牌「打出」/ 卡面渐显 / 资源卡再收窄

1. **需求**：「科技卡牌的底色与其他卡牌不同，需要更改，科技卡牌的阴影似乎也被裁剪了；手牌不需要有悬停时的四个角了，页签栏也不需要、悬停效果改为金色填充；页签栏的黑色似乎在金色的上面；科技卡牌拖拽往上生效后以金色填充形态放回手牌、取消启用则把牌打出；卡牌没被打出并被拖回手牌时应逐渐显示卡面；粮食和黄金面板水平距离再小一些」。
2. **投影层级（第 1、3 条同一根因）**：`StyleBoxFlat` 的绘制顺序是「投影 → 底 → 描边」，而填充层画在按钮**下面** ⇒ ① 底纹透明时（页签 / 科技格）投影直接**压在金上**，把金色压成暗金（用户看到的「黑色在金色上面」）；② 科技格原来用 `bg_empty()`（0.55 半透明）当卡身，投影渗进卡内，比命令卡暗一大截（用户看到的「底色不同」）；③ 卡框 `clip_contents = true` 又把这一层投影裁在框里（用户看到的「阴影被裁剪」）。
   **修法**：投影搬进填充层 —— `fill_button` 新增 `_ensure_shadow()`（读宿主 `normal` 的投影参数，**复制一份**再把四档底纹的投影清 0、绝不改共享对象）与 `_draw_shadow()`（画在底色与金的**下面**）；`ui_style.card_normal()` 的底改**全透明**（卡身统一由 `set_base_bg(bg())` 出，命令卡 / 科技卡逐像素一致）；科技格 `base_bg` 从 `bg_empty()` 改成 `bg()`；卡片 `clip_contents` 关掉（否则填充层的投影出不了卡框）。
3. **去掉四角括号（第 2 条）**：`fill_button` 新增 `set_reticle(b, on)`（整层 `button_reticle` 不建 / 已建则拆掉）。手牌格、科技格、页签这三处都关掉 —— 它们的反馈由「抬起 + 描边渐变 + 金色填充」给。页签另外加 `set_hover_fill(b, true)`：**悬停即填满、移开退回**，并且 `_is_lit()` 让它和「当前页」用同一档**亮金**（否则悬停那片金比当前页暗一档，实测 182,129,37 vs 240,191,96）。
4. **科技牌拖拽（第 4 条）**：`tech_grid` 现在按「松手前本来是不是启用着」分两种回手动画 —— 未启用 → 启用：飞回手牌 + 金色填满；启用 → 取消：先**打出去**（上飞 170px + 淡出 0.16s），再从扇位**飞回**并淡入。顺带修了两个真 bug：① hud `refresh()` → `_layout_fan()` 会把牌**瞬间摆回扇位**，导致「飞回去」根本看不出动作（现在先记住松手那一刻的位置再还原）；② 回手动画没带 `modulate`，取消启用后那张牌会**永远看不见**（现在 `_animate_card_back` 一并淡回 1）。
5. **卡面渐显（第 5 条）**：`command_card._set_drag_face_alpha()` —— 建筑牌拖到地图上淡出（让出建造预览）、**拖回手牌范围就 0.12s 淡回来**。判据在**本地坐标**里（`(0,0)..CARD_RECT.size` 外扩 40），⚠️ 不能拿 `CARD_RECT` 直接 `has_point()`（那是屏幕坐标，会永远判成「不在手牌」）。
6. **资源卡（第 6 条）**：`TOP_COLUMN_W` 120 → **100**（`TOP_COLUMN_X` 1358），右缘仍贴着小地图（1458）；4 位数（26 号字 ≈56px）仍然装得下。
7. **测试**：`test_ui` **1444 项**（资源卡 100 宽 / 大卡 100×350）；`test_fill_button` 200、`test_button_style` 16、`test_hover_fill` 120、`test_press_fx` 35、`test_settings_menu` 59、`test_quit_confirm` 71 全绿；全量 **122 套 / 11664 项 = 11652 过 / 12 红**，12 条红仍是 `test_ai_test_campaigns`（11）与 `test_unit_traits`（1）。
8. **落点**：`view/{fill_button,ui_style,tech_grid,command_card,page_tabs,ui_layout}.gd`、`tests/test_ui.gd`。

### 2026.11.14（第四轮）资源卡收窄（只装 4 位数）+ 地图再放大

1. **需求**：「粮食和黄金面板在水平方向上太大了，缩小一些，只要最多支持四位数即可，地图在竖直方向上还需要扩大一些」。
2. **资源卡**：宽 **194 → 120**（`TOP_COLUMN_W`），并改成**贴着小地图**右对齐（右缘 = 地图左缘 − 6）。120 的账：数字 26 号字 4 位数约 56px、标题「粮食」13 号约 26px、圆章 45px ⇒ 最宽那行是数字，两侧各还能留 32px；实测 `1234 / 9999` 都装得下（`test_ui` 有一条按字体量算的硬断言）。
3. **地图**：`MAP_RECT` **300×275 → 430×350**。⚠️ 这里是「只加高不会让地图变大」的那个几何事实：小地图是整张图按比例缩进面板的（`minimap.map_rect()`），只加高只会多出上下黑边 —— 所以宽度跟着涨到 430（430/350 = 1.229 ≈ 地图 27:22），**地形现在铺满整个面板、没有黑边**，线性尺寸比上一版（300×244）大 43%。
4. **将领列**：`SQUAD_RECT` 顶边 311 → **386**（5 行到 808，离页签列顶边 914 还有 106）。这已经是下限 —— 再加高就会压到页签。
5. **落点**：`view/ui_layout.gd`（`MAP_RECT` / `TOP_COLUMN_X,W` / `RES_HALF_H` 175 / 四行 y / `SQUAD_RECT`）、`tests/test_ui.gd`。资源大卡与小地图**同高同上下缘**（26..376），右列看起来是一整块方块。
6. **测试**：`test_ui` **1443 项**；全量 `tools/run-tests.ps1` **122 套 / 11663 项 = 11651 过 / 12 红**，12 条红仍是**改动前就有**的 `test_ai_test_campaigns`（11）与 `test_unit_traits`（1）。

### 2026.11.14（第三轮）选项入口改 Esc / 资源牌合并竖排 / 地图再高一点

1. **需求**：「把选项按钮删除，相应的打开菜单逻辑接到 esc 下；将资源面板改为竖直排列，竖直方向为：图标，文本，数字，增长数字；同时再把地图在竖直方向上扩大一些，将领标签可以再往下一些」。追问确认：手机端不看（返回键当菜单入口）、资源牌「合并成一张大卡，中间分隔」。
2. **选项按钮删除**：`hud._build_settings_button()` / `settings_button` / `_settings_face_style` / `_sync_settings_face` / `_on_settings_hover` 整条线删除，`ui_layout` 的 `SETTINGS_RECT` / `SETTINGS_RADIUS` 一起删（也不再进 `interactive_rects`）。
   **入口改成**：① PC —— `input_controller.handle_key` 的 Esc 级联**最后一档**：建造 / 指令 / 框选 / 招募取消都取消不掉、且**什么都没选中**时才 `open_menu_requested` → `hud._on_open_menu_requested()`；Esc 在选项页**开着**时由 `hud.handle_key` 最前面那一档负责**关**。② 安卓 —— `main._on_android_back` 改成 toggle（开着关、关着开），退游戏走「返回键 → 选项页 → 返回主菜单」。
   ⚠️ Esc 仍然是「一层层退出来」：先退建造 / 指令 / 框选，再清选中，最后才开菜单 —— 不要为了「一键开菜单」把它提前。
3. **资源牌**：从「两块 194×66 独立筹码」改成**一张 194×274 大卡**（`RES_BAR_RECT`，上 27、下 301，与地图下缘齐平），上半粮食 / 下半黄金，中间 1px 分隔线（`ResDivider`，两端缩进 `RES_PAD_X`）；每块内部**竖排四行**：圆章图标（45×45）→ 文本（13 号「粮食 / 黄金」）→ 数字（26 号库存，最显眼）→ 增长数字（13 号 `(+1.2)`）。四行水平居中。节点名 `ResText_*` / `ResRate_*` / `ResTitle_*` / `ResIcon_*` 保持不变（`_refresh_resource_bar` 与测试都按名字取）。
4. **地图 / 将领列**：`MAP_RECT` 300×225 → **300×275**（下缘 301，与资源大卡下缘齐平）；`SQUAD_RECT` 顶边 262 → **311**（底边 733，离页签列 914 还有 181）。
5. **测试**：`test_ui` **1441 项**（资源块整段重写：一张卡 / 分隔线 / 四行 y 递增 / 四行水平居中 / 数字字号最大；新增「节点树里没有 SettingsButton」）、`test_settings_menu` **59 项**（开菜单改按 Esc、再按 Esc 关；触屏悬停那条改用命令卡第一格）、`test_quit_confirm` **71 项**（安卓返回 = 选项页 toggle）；全量 `tools/run-tests.ps1` **122 套 / 11661 项 = 11649 过 / 12 红**，12 条红仍是**改动前就有**的 `test_ai_test_campaigns`（11）与 `test_unit_traits`（1）。
6. **落点**：`view/{hud,input_controller,main,ui_layout}.gd`、`tests/{test_ui,test_settings_menu,test_quit_confirm}.gd`。

### 2026.11.14（第二轮）HUD 布局再调：地图放大 / 部队上限 5 / 选项回圆币 / 手牌居中 / 详情栏贴左

1. **需求**：「把小地图变大一些，最大部队数改为 5 个，同时将将领标签向下移动一些，选项按钮不需要那么大，只需要原来的那个圆形小按钮即可；再将手牌放至屏幕底部中央，将部队详细信息栏往屏幕左侧靠」。
2. **小地图**：`MAP_RECT` 238×148 → **300×225**（右缘仍 1894，左缘 1594）。左列（选项 / 粮食 / 黄金）随之**整体左移 62**（1456 → 1394），右缘 1588 与地图留 6px 缝。
3. **部队上限 5**：这是**规则**改动（追问确认）——`config.json` 的 `upgrade.levels.base[].max_generals` **2/5/6 → 2/4/5**，同时 `SQUAD_SLOTS` 6 → 5、`team_slots.MAX_SLOTS` 6 → 5（数字键随之只到 5，`input_controller` 本来就是按 `SQUAD_SLOTS` 循环）。将领列 `SQUAD_RECT` 顶边 178 → **262**（用户要的「向下移动一些」），底边 684 不变。
4. **选项按钮**：从「194×66 筹码」**恢复成 54×54 圆币**（圆角 27 = 半个边长，`fill_button` 的 `circle_shape` 也开回来），放在那一列**最上面、靠右对齐**（右缘与粮食 / 黄金对齐）。
5. **手牌居中**：`CARD_RECT` 左缘 796 → **539**（= `(1920 − 842) / 2`），竖直仍贴底。摆放改成新加的 `apply_bottom_center()`（左右锚 50% + 贴下沿），命中区改用新加的 `center_shift()`（**只吃半个** `shift.x`）—— 贴左 / 贴右 / 居中三种锚法的修正量各不相同，混用就是「看得见但点不中」。`tech_grid`（科技九格与手牌逐像素重合）同改。**悬停说明面板**随之从「牌手左缘 → 页签列右缘」改成**与手牌同宽同中心**（`HOVER_W = CARD_RECT.size.x`），否则它会横穿整个屏幕去够右侧页签。
6. **详情栏贴左**：`DETAIL_V2_RECT` 左缘 395 → **27**（377×260 不变）。顺手把 `detail_v2.gd` 里另抄的那份 `PANEL_RECT` 删掉、改读 `ui_layout.DETAIL_V2_RECT`（两份不同步会「看得见但点不中」）。播报 / 对话栈原本贴屏幕底（x 27，下沿 1048）会和它叠在一起 ⇒ 改到**详情栏正上方**（下沿 786）。
7. **测试**：`test_ui` **1431 项**（几何全改新口径 + 超宽窗口改按 `center_shift` 断言 + 成员格拦滚屏按「是否在最外圈 44px 带里」逐颗对账）、`test_base_limits` **140 项**（上限 2/4/5）、`test_ai_commander` **348 项**（补将目标 4/5）、`test_zone_recruit` **176 项**（队列 5 单已占满 5 个名额 ⇒ 第 6 单先撞 `general_limit`，口径见 route.md 6043 的判据顺序）；全量 `tools/run-tests.ps1` **122 套 / 11650 项 = 11638 过 / 12 红**，12 条红仍是**改动前就有**的 `test_ai_test_campaigns`（11）与 `test_unit_traits`（1）。
8. **落点**：`view/ui_layout.gd`（含新增 `apply_bottom_center` / `center_shift`）、`view/hud.gd`、`view/command_card.gd`、`view/tech_grid.gd`、`view/hover_tip.gd`、`view/detail_v2.gd`、`view/team_slots.gd`、`view/input_controller.gd`、`logic/{config,ai_build,ai_profile,upgrade}.gd`、`data/config.json`。

### 2026.11.14（第一轮）局内 HUD 五项调整（边缘滚屏缓停 / 地图挪右上 / 页签圆角 / 卡牌悬停缓动 / 将领牌去竖线）

1. **需求 ①**：「鼠标移动到屏幕边缘滚屏时，移动视角停下时的过度移动」→ 追问后确认是**停下太硬、像急刹**。边缘滚屏原来是「每帧按贴边深度（平方曲线）给速度，鼠标一离开边缘带**立刻归零**」。现在起步**仍然瞬间给满**（否则会觉得「推到边缘要等一下才动」），抬手则按**指数衰减**收干：帧率无关（60/90/120Hz 轨迹一致），`camera.edge_stop_sec = 0.08` 秒后基本停住；鼠标进 UI / 开始拖拽 / 跟随镜头时仍然**立刻让位**（不然残速会和它们抢相机）。
2. **需求 ②**：「将地图面板放到屏幕右上角，地图左侧放一列 ui：选项按钮 / 粮食数 / 黄金数」。小地图从**左下角**搬到**右上角**并缩到 **238×148**（右上角那条 238 宽的竖带原本被「将领 1~6」占着，而用户要求**将领列表不动**，让路的是地图）；右侧原来横排的两枚资源筹码改成**竖排**，并把选项按钮从「54×54 圆币」改成**同宽同高的圆角筹码**（194×66、圆角 12），三块左缘/宽度完全对齐（x 1456..1650）。播报/对话栈原来贴在小地图上沿，现在给了自己的锚（**屏幕左下角**，宽度仍是 328，文字排版不变）。
3. **需求 ③**：「右下角页签栏的底板是矩形的，圆角被底板影响到了」。两个真根因一起修：① `fill_button` 画在按钮**背后**的「常驻底色 + 金色填充」原来是**矩形**（`draw_rect` / `draw_texture_rect_region`）⇒ 满格时四角从圆角描边外面顶出来；现在底色改用圆角 StyleBox、填充改成**圆角多边形 + 逐顶点 uv**（贴图仍是原来那条竖向渐变，颜色分布一个像素没变，只换轮廓）。② 页签的底纹是**全透明 + 带投影**，而投影 `shadow_offset = (0,4)` 直接露在按钮内部 ⇒ 顶部一条「没投影」的浅色横带、右侧从圆角外探出，看起来就是方底板；这一档改成**零偏移投影**（内部均匀、外部是一圈跟着圆角走的对称晕光）。
4. **需求 ④**：「卡牌在静止到悬停态时需要有缓动效果」。抬起 / 摆正原来**一帧到位**，现在走 `0.14s` ease-out（落回同一档，杀掉了它和入场/拖牌 Tween 抢同一属性的情况）；描边与底色不再由引擎**整块换 StyleBox**（那是瞬间跳色），而是 normal/hover/disabled **共用一份** StyleBox、颜色按泛光进度逐帧插值 ⇒ 牌抬起的同时描边由暗金渐变到亮金、底色渐隐（只有「按下」仍是瞬时换档，那是点击反馈）。
5. **需求 ⑤**：「将领标签右侧的竖线可以去掉」——`troop_row` 里那条右缘尖角前的 1px「肩线」删除（右缘尖角的形状由 `_shape()` 表达，不靠那条线）。
6. **配置**：`camera.edge_stop_sec = 0.08`（0 = 回到旧的硬刹；越大越柔，但收手后多滑的距离也越长）。其余几何进 `view/ui_layout.gd`（`MAP_RECT` / `TOP_COLUMN_*` / `RES_BAR_RECT` / `SETTINGS_RECT` / `SETTINGS_RADIUS` / `NOTICE_*`）。
7. **落点**：`view/game_scene3d.gd`（`_edge_vel` / `_decay_edge_velocity`）、`view/ui_layout.gd`、`view/hud.gd`（地图 / 资源列 / 选项筹码 / 位置与锚点）、`view/notice_stack.gd`、`view/fill_button.gd`、`view/ui_style.gd`、`view/command_card.gd`、`view/troop_row.gd`、`logic/config.gd`、`data/config.json`。
8. **测试**：`test_ui` **1425 项**（几何断言改成新口径：地图在右上、资源竖排、选项筹码与列对齐）、`test_base_broadcast` **67 项**（播报与对话改锚自己的左下角）、`test_feel` **40 项**（新增边缘滚屏收手缓动 6 项：单调衰减 / `edge_stop_sec` 后残速 < 6% / 帧率无关 / 残速兜底 / `=0` 时回到硬刹）；全量 `tools/run-tests.ps1` **122 套 / 11644 项 = 11632 过 / 12 红**，12 条红全部是**改动前就有**的 `test_ai_test_campaigns`（11）与 `test_unit_traits`（1），见 [`feel_optimization_plan.md`](dev_gd_a/docs/feel_optimization_plan.md) 第 8 节。

### 2026.11.12 主菜单光标 + 按钮「瞄准框」交互（PC）

1. **需求 ①**：把游戏内的自绘光标用到主菜单 —— 平时是**主题金箭头**（热点在尖端），鼠标底下是**可交互控件**时才变成**金圈点**；按住整体收 14%。系统光标只在菜单显示期间隐藏，进游戏 / 窗口失焦 / 指针移出都会立刻还原。
2. **判定**：`view/menu_cursor.gd` 用 `Viewport.gui_get_hovered_control()` + 四条收口（STOP / BaseButton 未禁用 / 自绘手型 / 文本输入）；被禁用按钮和铺满屏幕的遮罩不会误判成「可点」。
3. **需求 ②**：所有按钮的悬停 / 按下换成统一的**瞄准框**语言 —— 悬停 = 四角 L 形括号 + 底边细线；按下 = 括号向内扣 + 1px 内框；松开 = 外扩回声环。宽扁列表行改「左缘竖条 + 底边细线」，文字导航改 `|— 战役 —|`，图标按钮在图标外补括号。
4. **落点**：新增 `view/button_reticle.gd`（画在按钮**上面**的一层，避免被不透明底纹盖住）、`view/menu_cursor.gd`；`fill_button.gd` 每帧喂状态、旧四边泛光保留为 `ui.button_style = "glow"`；`press_fx.gd` 改画四角内扣；`menu_text_button.gd` 改成**松手确认**并加两端竖线 / 选中亮金；`menu_corner_button.gd` / `menu_back_button.gd` 补括号。
5. **配置**：`ui.button_style / reticle_arm / reticle_gap / reticle_width / reticle_alpha / reticle_underline / menu_cursor_scale`，全部进 `data/config.json`。
6. **测试**：新增 `test_button_style` 16 / `test_menu_cursor` 13；`test_fill_button` 200、`test_start_flow` 61、`test_menu_deck` 39、`test_menu_hover_touch` 21、`test_menu_corner_buttons` 105、`test_hover_fill` 120、`test_press_fx` 35 全过；全量套件结果见 [`dev_gd_a/docs/ui_interaction_system.md`](dev_gd_a/docs/ui_interaction_system.md)。
7. **文档与渲染图**：新增 `dev_gd_a/docs/ui_interaction_system.md` + `ui_button_states.png` / `ui_cursor_states.png` / `ui_menu_after.png`。

### 2026.11.9 特性标签化（单位 / 将领分池）+ buff_editor → tech_editor

1. **需求 ①**：「把所有『单位特性』与『将领特性』打包为单独的标签（将领特性仅适用于将领，单位特性仅适用于单位），并相应地更改单位编辑器中的逻辑，为任意当前的单位 / 将领灵活设置特殊的特性」。
2. **数据**（`data/config.json`）：新增 **`unit.unit_traits`** 池（13 条：对骑兵 +25%/+70%、对步兵 +10%/+25%/+50%、远程减伤 25/30/50/55/90%、近战减伤 25/30%、稳定）；每个兵种从 `unit.types.<id>.traits`（内嵌四键）改成 **`trait_ids`** 数组；老式内嵌 `traits` 仍然被读。
3. **逻辑**（`logic/config.gd`）：新增 `_cache_unit_traits()` / `_normalize_unit_trait()` / `unit_trait_ids()` / `unit_trait_def()` / `unit_trait_name()` / `unit_trait_short()` / `unit_trait_desc()`；`unit_traits_of()` 现在 = **内嵌 traits ⊕ trait_ids 点名的标签**（attack_vs_class / 两条减伤相加、免疫取或），`unit.create()` / `reapply_type()` 的读取点不变。`unit.gd` 只加了注释。
4. **单位编辑器**：页签从 2 个变 4 个 —— **单位 / 单位特性 / 将领特性 / 建筑**。两个特性页是各自的**池**（列表 + 增删 + 名字 / 短名 / 说明 / 效果表单），「单位」页只负责给兵种 / 将领**挂多条标签**（一行一条 + 「＋ 加特性」下拉 + 每行「移除」）。删掉池里一条时，挂着它的兵种 / 将领自动摘掉；老式内嵌 traits 在兵种表单里给一行 ⚠ 只读提示。
5. **需求 ②**：「buff_editor 似乎无法打开了，将 buff_editor 改为 tech_editor，需要编辑当前已有的所有科技的数值属性」。
6. **tech_editor**：`tools/buff_editor` → **`tools/tech_editor`**（`buff_editor.bat` → `tech_editor.bat`，README / 测试 / 文档同步）。原因：原工具读 `morale.max` 等键，而 2026.11.5 砍士气时把 `morale` 段整段删了 ⇒ 一打开就抛 `config 里缺少 morale.max`。现在它只编辑 `tech.*`：全局上限 / 每阶金耗、`tech.list` 9 条、`tech.clan_list` 13 条、每派 9 个槽位；左栏按「全局 / 原生科技 / 派系科技 / 科技页」分组，全部页面按 config **现算**。
7. **测试**：`tools/unit_editor/test_model.py` **1113 项**、`test_app.py` **328 项**；`tools/tech_editor/test_model.py` **95 项**、`test_app.py` **80 项**；`daeem/tests/test_unit_editor.gd` 的 `_test_traits` 重写（池 / trait_ids / 老式合并 / 未知 id），`test_unit_traits.gd` 在「洗坏键」那一节先清掉 `trait_ids` 以隔离老写法。⚠️ 本机没有 Godot 可执行文件，GDScript 侧只做了静态核对（未跑）。
8. **文档**：`README.md` / `dev_gd_a/docs/README.md` / `dev_gd_a/docs/route.md` / `tools/*/README.md` 全部改到新路径与新特性模型；`tools/buff_editor/` 已删除。

### 2026.11.5 阵地性 AI：区划禁行区（战役编辑器可编辑）

1. **需求**：「为游戏中的阵地性 ai 添加区划禁行区，阵地性ai不会巡逻至其区划的禁行区，禁行区要可以用战役编辑器编辑」。
2. **口径**：每条区划各自一组禁行格（任意形状）；**只影响巡逻目标点**（不挡走路、不改寻路，追击 / 守中心 / 攻城警报不受影响）；只放**关卡层**（自由对战没有）；编辑器涂刷；游戏内不可见。
3. **数据**：关卡 `zones[]` 新增可选 `no_go: [[x,y],...]`；`logic/level.gd` 宽容读入、`zone_no_go_*` 五条校验（缺区划 / 越界 / 别人的地 / 盖中心 / 整块）。「整块」按**除中心外的巡逻候选格**算。
4. **运行时**：`zone.apply_no_go()` 装配成 `no_go_by_id`（只收属于该区划的格子）；`garrison_ai._build_route()` 先剔禁行格再切扇区，兜底点也不落在禁行格；整区禁行 ⇒ 原地待命（不崩、不走进去）。
5. **战役编辑器**：区划页改成「左画布 + 右栏（归属 + 禁行区）」，每区一行「涂刷 / 停止 / 清空 / 禁行 N 格」；左键涂、右键擦；中心 / 别人的地 / 整块当场拒绝；导出只在非空时写、按 (y,x) 排序；换图连带清空。
6. **测试**：新增 `tests/test_zone_no_go.gd`（42 项）；`campaign_editor` 的 `test_model` 新增 `[1d]`、`test_app` 新增 `[4h]`。全量 GDScript **109 套 / 11076 项 = 11075 过 / 1 红**：唯一红是 `test_menu_glow_fade` 的菜单雕版像素位置断言（两次跑值不同，属动画时序抖动，与本功能无关）；`test_model` 另有 2 条 config 断言因工作区未提交的 `config.json` 改动而红。

### 2026.11.5 按钮动效重做：悬停 / 长按泛光，选中才填充

1. **需求**：鼠标悬停 / 移动端按住时按钮**内泛光**；只有**点击切换选中**的按钮（页签当前页 / 科技已启用 / 备战磁贴 / 面板已打开）才播**金色填充**，选中填满、取消选中退回。
2. **拆成三条动效**（`view/fill_button.gd`）：`_glow` 管悬停（四边向中心、不改字色），`_fill` 管选中（金色自下而上），`_flash_*` 管点击（快速填满再退回）。悬停不再产生金色填充；旧的「确认按下瞬间补满」（`press_snap`）删除，由第 8 条的「点击闪光」接替。
3. **泛光画法**：四条边各一张向内渐隐的 alpha 斜坡（1px `GradientTexture2D`，全项目共用），四角两条带子叠加 ⇒ 角上最亮、中心不亮，与主菜单四角按钮的泛光同一观感；颜色可点 = 金、禁用 = 灰；强度 / 宽度 / 时长读 `ui.hover_glow_*`（**0.50 / 0.22 / 0.08s / 0.12s**；★ 按用户反馈把强度 0.34 → 0.50、「开始泛光」0.18s → 0.08s）。
4. **选中填充**：`set_latched(b, on, instant)` —— 默认播填充动画，`instant = true` 给「打开界面时已经选中」（直接满格）；页签 / 科技格用 `_primer_done` 只在第一次同步时 instant。逐字翻面去掉「latched 立刻翻黑」的捷径（否则选中动画头 0.1 秒是黑字压黑底），科技格已启用的原色也改回亮色。
5. **备战磁贴**：选中从「2px 金线描边」改成**金色填充满格**（图标按填充进度自动反色、名字条淡出、名字翻成压金暗色），按用户口径**不再额外加描边**。
6. **测试**：`test_fill_button` 重写为 **200 项**；`test_prepare` **261 项**、`test_settings_menu` **59 项**；`test_ui` / `test_press_fx` / `test_tech` / `test_hover_fill` / `test_sfx` 全绿；`tools/check-syntax.ps1` 266 文件 ALL OK。
7. **配置**：`ui` 新增 `hover_glow_alpha` / `hover_glow_band` / `hover_glow_sec` / `hover_glow_out_sec`；删除 `press_snap_sec` / `press_snap_hold_sec`。
8. **点击闪光（按用户反馈追加）**：「按下时整颗缩一下」不算点击反馈 —— 普通动作按钮（命令卡的操作格 / 招募将领格、战役合作列表行、选项页 / 结算页、地图选择、战役阵营）点一下**快速闪一次金**：0.06s 填满 → 0.02s 保持 → 0.10s 退回，**不翻字色**（避免满格那两帧文字闪黑）。页签 / 科技启用 / 备战磁贴 / 面板已打开有自己的选中填充，不闪；裸按钮（AI 指令面板 / 返回箭头 / 四角图标 / 纯文字大按钮）本轮不接。配置 `ui.click_flash_sec` / `click_flash_hold_sec` / `click_flash_out_sec`。
9. **建造命令的选中填充**：建筑命令卡里点一格建筑 = **选中这条建造命令**，那一格**金色填满**（与页签 / 科技启用同一条选中口径，字色跟着金的前沿翻）。点另一栋 → 旧格反向退回、新格填满；再点同一格 / Esc / 右键退出建造模式 → 当前格退回；放置建筑后模式仍在，填充保持。实现走 `hud._build_entry()` 的 `active` + `_card_sig()` 的 `bt:<id>` + `command_card` 的 `set_latched`；建造格不再「点击一闪」（选中填充就是反馈），其它页格子照旧闪。`test_ui` 1387 → **1395 项**。
10. **单位按钮不闪金（按用户反馈）**：局内**单位页的招募格**点击后**不再金色填充闪过**（用户原话「局内的单位按钮，点击后不需要金色填充闪过」）—— 点一下排进招募队列，右侧队列 / 红字就是反馈；该格也没有选中态。`command_card` 对 `recruit` 条目关掉点击闪光（建造格见第 9 条；操作页 / 招募将领页照旧闪）。`test_ui` 1395 → **1398 项**。

### 2026.11.5 将领：派系归属 / 阶 / 0 阶大本营成长 / 加将领按钮

1. **需求**：① 单位编辑器的将领要加**派系归属**（原生 / 王朝 / 帝国，一位可属多个），运行时按该派系在**备战界面**显示；② 0 阶将领要加「成长」选项，所有 0 阶将领随**局内大本营升级**获得加成（占位：加血量 / 攻击力）；③ 单位编辑器要有**加将领的按钮**。
2. **数据**（`data/config.json` 的 `unit.general`）：新增 `tiers`（与 `types` 同序，0~3；开局 #0 = 0 阶）、`factions`（一个 id 数组，可多派；缺项 = 三派全算）、`growth`（`hp_max_per_level` 30 / `damage_per_level` 3，只作用于 0 阶）；**删掉** `recruit.zone.list[].tier` 那 9 份（阶只留一处：`unit.general.tiers`）。
3. **逻辑**：`config.gd` 新增 `general_tier_at / general_is_zero_tier / general_factions_at / general_in_faction / general_growth_bonus / general_count`；`unit.gd` 新增 `apply_general_growth()`（上限 = 基础 × 科技倍率 + 成长，当前血量按增量带过去）与 `general_growth_damage`（`combat_damage()` 最后加）；`world.create_general()` 出生算一次、`refresh_general_growth()` 在大本营**升级完成 / 建好 / 被拆**时重算（场上已有的 0 阶将领当场涨）；`snapshot` 重建将领后也重算一次。
4. **视图**：备战页「将领」一节改成按当前派系过滤（`prepare_roster_list`），详情页显示「派系归属」与「成长（0 阶）」（`prepare_detail_view`）。★ 右面板仍然只有王朝 / 帝国两枚按钮 ⇒ **只勾「原生」的将领不上备战页**（用户拍板）。
5. **单位编辑器**：将领列表加「阶 / 派系」两列；将领表单加阶下拉、三派复选框、0 阶专属「成长（0 阶）」一栏；操作栏加 **「＋ 新建将领…」**（名字 / 类型 / 阶）—— 只追加 `unit.general.*` 同序表，**不进招募九宫格**；新将领 kind 从 `general_11` 起（`general_10` 永远不存在，第 10 档是 `general_0`）。将领仍**不能删 / 不能插队**。
6. **测试**：`test_model` 977 项 / `test_app` 320 项 / `test_unit_editor.gd` 286 项 / `test_prepare.gd` 253 项；`test_logic` 270、`test_smoke` 132、`test_ui` 1387、`test_recruit_queue` 272、`test_snapshot_coop` 43、`test_upgrade` 165 全绿。⚠️ `test_zone_recruit` / `test_general_traits` / `test_downed` 在本轮之前就有断言与当前默认配置不符（用 `git worktree` 在 HEAD 上复现过），不是本次引入的。

### 2026.11.2 阵地性 AI 警戒唤醒：没威胁就静止（降设备 / 联机负载）
1. **需求**：阵地性 AI 只在「玩家 / 敌对 AI 的部队进入自身 10 格内」或「敌对 AI 的区划扩张到离自身区划一个区划外（相隔一个区划）」时启动巡逻，否则静止。**只关巡逻** —— 交战 / 守区划中心 / 脱战无消耗招兵 / 濒死无消耗再起照常运行
2. **判据**：① 任一敌对单位（`same_side_for_attack` 之外）离守将 ≤ `ai.garrison.alert_troop_radius_tiles`（默认 **10**，平方距离）；② 任一敌对**已占领**区划在**区划邻接图**里离我的归属区划 ≤ `ai.garrison.alert_zone_gap`（默认 **2** = 相邻 + 隔一个区划；`1` = 只相邻）。复检周期 `alert_check_sec` 默认 **0.5 s**，结果缓存在 `unit.garrison_alert_active`（不进快照）
3. **区划邻接表**：`logic/zone.gd` 装配期按地块四连通建一次（`neighbors_by_id` / `neighbors_of()` / `zones_within()`），阵地 AI 判定不逐格扫地块；区划形状不规则，直线距离会判错「隔着一条河」的假近邻
4. **唤醒首巡错峰**：静止期 `patrol_timer` 保持 0，上升沿用 `patrol_interval × _phase01(unit)` 重排 —— 一次区划易主不会让整片守军同帧寻路（复用 2026.10.28 的错峰机制）
5. **回退**：`ai.garrison.alert_enabled = false` 逐位回到旧行为；`tests/bench_dscj.gd` 新增 `DAEEM_GARRISON_ALERT=0/1` A/B 开关
6. **实测（dscj，258 单位 / 34 位带队守将，20 秒）**：`world.tick` **9.54 → 7.63 ms/帧（−20%）**；平均移动单位 **160.5 → 8.8**；30 Hz 增量快照（不按视野过滤的上限口径）**25.9 → 18.0 KB（−30%，0.74 → 0.52 MB/s）**。★ **按客机视野过滤时**（真实合作局口径）首 20 秒两者都是 **7.2 KB / 0.21 MB/s，基本不变** —— 看不见的守军本来就不发，而开局醒着的几位都在客机视野外；带宽收益只出现在「客机看得见、但还没进 10 格」的窄带（箭塔视野 12 格 > 唤醒半径 10 格）。所以**真正稳赚的是房主 CPU**，联机侧是「少 95% 移动单位 ⇒ 客机插值 / 合并的脏字段更少」；`ai/garrison` 本身几乎不变（0.311 → 0.289 ms）—— 省的是**移动链**（单位步进 / 群体碰撞 / 区划在场扫描），不是 A*
7. **测试**：`test_campaign_ai` 新增 22 条（静默不生成路线 / 开关关掉回旧行为 / 9 格唤醒 / 12 格重新静止 / `gap=1` vs `2` / 敌对区划失去归属后重新静止）；新增量尺 `tests/bench_garrison_alert.gd`（全图与客机视野两条快照口径）

### 2026.11.2 招募读条改由将领决定 + 单位编辑器修好「派系兵种不在招募表」
1. **数据**：新增 `unit.general.recruit_sec`（与 `unit.general.types` 同序，10 项，默认 **10 秒**）= 这位将领当兵营时**整批**读条几秒；`recruit.list[]` 与 `clan.list[].recruit[]` 里的 `train_sec` **全部删除**（共 20 条 —— 兵种自己不再有读条时间）
2. **逻辑**：`world.leader_recruit_sec(leader)`（真实对象 / 假队长字典都收）→ `_start_training` 用它开读条；`config.general_recruit_sec(i)` 现读 JSON，缺项 / 越界 / ≤0 退回 `recruit.batch_sec`（仍是 10 秒，老配置行为不变）。口径 = 用户原话：「无论队列长短、队列中的单位类型如何，招募时间始终由招募单位的将领决定，默认 10」
3. **HUD**：单位页悬停的「读条 X 秒」改成显示**招兵那位将领**的值（`_unit_recruit_sec()`）；区划招将页仍读 `recruit.zone.list[].train_sec`（那是「招这位将领出来」的读条，另一件事）
4. **单位编辑器（修 bug）**：招募条目定位从「只查全局 `recruit.list`」改成「全局 + `clan.list[].recruit[]`」—— 王朝 / 帝国的派系兵种现在**能读出造价**、也能直接改（写回它实际所在的那张表，标题会写 `clan:dynasty` 这样的来源），不再误报「不在招募表」
5. **单位编辑器（组合单位）**：协防军枪 / 弓、御林军剑盾 / 弓 / 着甲骑这 5 个**零件**没有自己的招募条目（由「协防军」/「御林军」整包 `spawn`），现在列表显示「随「协防军」」、详情页说明「整包生成、造价在那一单上」，既不谎报也没有改不动的输入框
6. **单位编辑器（读条）**：单位页的「招募秒」整栏移除；将领页新增 **「招兵读条」**（写 `unit.general.recruit_sec[i]`，清空 = 回默认 10），将领列表那一列改成「招兵秒」；原「招募时间」改名为「区划招募读条」以免和它混淆
7. **单位编辑器（新增一栏）**：左下多了 **「组合招募单（一次出多个兵）」** —— 协防军（`dy_guard`）/ 御林军（`dy_royal`）的 `kind` **不是** `unit.types` 里的兵种，单位页永远列不出来，于是它们的**整包造价之前无处可改**（用户报的「找不到修改协防军招募消耗的条目」）。现在能改 名字 / 方框字 / 说明 / **整包**粮·金·人口，并只读显示「这一单会生成谁」；判据是「kind 在不在 `unit.types` 里」，以后再加这种单会自动出现
8. **测试**：`test_recruit_queue` 新增 `_test_leader_recruit_sec`（默认 10 / 改将领后跟着变 / 加单与兵种都不影响 / 已在读的批次不重算，**272 项**）；`test_unit_types` / `test_retinue` / `test_clan` 改用 `leader_recruit_sec` 等；编辑器 `test_model` **789 项** / `test_app` **238 项**（新增派系兵种造价读写、组合零件显示、组合招募单整包造价三组）

### 2026.11.2 王朝战车换成专属原画（第八个由占位转真素材的派系兵种）
1. `data/config.json`：`unit.types.dy_chariot` 从**占位**（`sprite` 留空 + `sprite_tint = faction`）改为**专属原画** —— 新增 `sprite = res://assets/units/dy_chariot.png`、`sprite_tint` 改为 `art`；数值 / 特性 / 冲锋参数一行未动
2. 素材来自 `art_draft/units/王朝战车.png`（512×384），按既有约定落到 `assets/units/<兵种 id>.png`，并由 Godot 真正导入（`dy_chariot.png.import`，`compress/mode=0`，与其余兵种原画同参）—— 只写路径不导入会让渲染层**静默退回剪影**
3. **立牌尺寸按用户口径显式覆盖**：单兵 1×1 ⇒ 战车 `sprite_ratio = [2, 1.5]`（器械大类默认是 2×1）。画布变成 128×96，原画 4:3 正好占满 —— 实测内容 118×84、占牌宽 **92%**、底边贴地，既没有拉伸变形，也没有 2×1 时那圈左右空档
4. `tests/test_unit_art.gd` 的 `CLAN_ART_TYPES` 加入 `dy_chariot`（七个 → 八个），并新增 `RATIO_OVERRIDES` 表把「显式覆盖比例」与「按大类默认」区分开：路径 / 导入 / art 档 / 文件名 = 兵种 id / 立牌比例 / 烘图有实质像素 / 两两不同全部覆盖（**112 项**）；`config.json`、`view/unit_sprite_3d.gd`、`view/unit_view_3d.gd` 的注释同步成「八个 / 战车 2×1.5」
5. 地图单字仍显示 `icon`（战），悬停白边 / 选中金边的口径不变 —— 三档描边都是运行时按阵营烘的，不需要新素材

### 2026.11.2 单位冲锋（被动动量）实装
1. 新增 `unit.types.<id>.charge` 数据块：`min_distance / max_distance / turn_max_deg / speed_bonus / damage_bonus / knock_distance / knock_stun_sec / splash_radius / splash_damage_ratio / cooldown_sec`
2. 7 个近战骑兵 / 战车获得冲锋：骑手 / 骑士 / 斥候 / 御林军骑兵 / 帝国骑手 / 冠军骑士 / 战车；远程骑兵（马弓手 / 游侠）不冲锋
3. 触发 = 连续直线移动达到阈值；急转、停下、被击退/眩晕、新命令、到达终点清零；`halt()` 故意不清（保证接触瞬间打出冲锋）
4. 首次近战接触立即结算额外伤害 + 击退；战车额外有范围伤害 / 范围击退；帝国科技「骑士精神」`charge_damage_mult` 加法追加 +100%
5. 表现：阵营色立牌发光（`INSTANCE_CUSTOM.b`）+ 脚下尘环 + 命中冲击波圈 + 复用受击闪白/音效；无新图片 / 音频素材
6. `unit_editor` 单位页新增「冲锋」section；`buff_editor` 的 `charge_damage_mult` 说明改为真实语义
7. 新增 `tests/test_charge.gd`（52 项）；`test_clan_tech` / `test_unit_editor` / 编辑器测试全过；`test_view3d` 有一条**既有**的建筑贴地断言失败（改动前基线同样失败，与冲锋无关）

### 2026.10.31 修复长按命令卡后移出按钮松手、填充一直保持的 bug
1. 根因：`view/fill_button.gd` 的 `_on_button_up()` 无条件把 `_hovered` 写回 `true`。事件顺序是「长按 → 移出按钮（`mouse_exited` 把悬停清掉）→ 松手（`button_up` 又写回 true）」⇒ 之后再也没有 `mouse_exited` 来清它，`_goal()` 一直是 1，填充永远停在满格
2. 修复：动画器新增 `_pointer_down` / `_left_while_pressed` 两个状态位；`mouse_exited` 只在**按住期间**记下「离开过」，`_on_button_up()` 按这一位决定是否把悬停钉回去（离开过就保持 false，走 `DRAIN_TIME` 反向渐出）
3. 边角：按住期间移出后又移回按钮再松手 → `mouse_entered` 会清掉标记，悬停仍然成立；原地松手保持满格；按钮隐藏时把按住 / 离开标记一起作废，避免迟到的 `button_up` 把悬停钉回去
4. 测试：`test_fill_button.gd` 新增「长按移出后松手必须渐出到空」「原地松手保持满格」「移出又移回后松手仍算悬停」三条用例（**150 项全过**）

### 2026.10.31 无操作建筑 / 敌方 / 友方选中时隐藏右下角页签与命令卡
1. `view/hud.gd` 的 `_tab_plan()` 收紧为「**只给自己的可操作对象**发页签」：自己的部队 / 单位、自己的大本营、自己的区划中心；其余一律返回**空页列表**
2. 新增 `_units_all_own()` / `_buildings_all_own()` / `_zone_is_own()` 三个归属判据：友军单位 / 建筑、敌方任何建筑单位、非自己的区划中心都不再拿到操作入口；自己的无操作建筑（木墙 / 哨塔 / 石墙 / 警戒塔 / 粮田 / 房屋 / 矿脉…）仍由 `_building_has_actions()` 判空
3. `_sync_tabs()`：空页列表 = **页签列 + 3×3 命令卡整块隐藏**（`page_tabs.visible = false` 连 `TabsFrame` 外框，`command_card.visible = false`）；可见性每帧写回，改选自己的部队 / 大本营 / 区划中心或空手时一起恢复
4. 删除 `view/page_tabs.gd` 的 `PAGE_NONE` 空页签常量与 `LABELS` 项 —— 选中敌方 / 友方不再立「有格子但没东西」的占位页签
5. `view/ui_layout.gd` 的 `interactive_rects()` / `bottom_bar_rects()` 参数改为 `command_ui_visible`（同时管命令卡与页签）；`hud.point_hits_ui()` / `blocks_edge_scroll()` / `blocks_wheel_zoom()` 按整块可见性传参 —— 隐藏后不再吞地图手势 / 边缘滚屏 / 滚轮缩放
6. `view/page_tabs.gd` / `view/ui_layout.gd` 的文件头与注释同步新口径
7. 测试：`test_ui.gd` 改为断言「页签 + 命令卡整块隐藏 / 0 颗 / 当前页清空」，并补「所有非大本营 / 非区划中心建筑类型的判据覆盖」「敌方单位 / 建筑 / 区划全部隐藏（友方在输入层同走 `selected_enemy`）」「隐藏后重新选自己的对象或空手能恢复」「隐藏块不再拦手势 / 滚轮」等用例（**1380 项全过**）；`test_ai_observer` / `test_settings_menu` / `test_touch` / `test_hover_fill` 保持通过

### 2026.10.29 战役菜单新增三个 ai_test 测试战役（简单 / 中等 / 困难）
1. `data/campaigns/demo/levels/` 新增 `ai_test_easy.json` / `ai_test_normal.json` / `ai_test_hard.json`：`between_moutains` 1v1，双方各 1 名开局将领、100 粮 / 100 金；两边都写 `ai: "commander"` + `commander_ai.difficulty`（easy / normal / hard）——玩家在详情页选哪一方，运行时就把那一方的 AI 摘掉，另一边按本关难度接管
2. `data/campaigns/demo/campaign.json` 的 `levels[]` 追加三关；`data/campaigns_menu.json` 新增 `c4` / `c5` / `c6` 三个独立战役条目，分别指向这三关
3. `view/campaign_map_panel.gd` 从「一面旗 + I/II/III 章节栏」改为**每个真实战役一面旗**：遍历菜单数据，取每份战役的第一个真实章节建旗；点任意旗进详情。`view/menu_deck_layout.gd` 新增 `campaign_flags()`（一排居中、窄屏等比缩小），删除不再使用的章节栏布局
4. 三个测试关的阵营显示名改为「下方（南军）」/「上方（北军）」，详情页两个按钮任选一方
5. 测试：`test_campaign_menu` 改为多旗断言（65 项）；新增 `test_ai_test_campaigns`（数据 / 难度 / 双席位装配 / 菜单 / 真实场景，91 项）；`test_all_levels_outcome` 自动覆盖三关 × 两席位（257 项）；`test_campaign`（312）/ `test_campaign_seats`（95）保持通过；战役编辑器 `test_app` 的关卡树精确列表同步
6. 难度完全由关卡数据驱动，`view/main.gd` / `view/game_scene3d.gd` / `logic/world.gd` 一行未改；主菜单左上角的 ai_test / see_ai 行为不变

### 2026.10.29 单位维护费按阶提高 + AI 富余时补满编制
1. `data/config.json`：单位维护费整体提高约 **2.5~3 倍**，并按**阶**拉开差距 —— 一阶 长枪 **0.08** / 长弓 **0.10**；二阶 骑手 **0.18** / 粮车 **0.12**；三阶 骑士 **0.32** / 马弓 **0.26** / 投石车 **0.40**。`unit.classes` 上的值只作兜底（0.08 / 0.18 / 0.40）
2. `logic/ai_army.gd` 新增 `team_target()`：浮存超过 `economy.max_float_food/gold`（默认 600）且 `ai.commander.production.fill_to_cap_when_rich` 开着时，`recruit_candidates()` 的目标从 `home_team_size` / `field_team_size` 抬到 `1 + effective_retinue_cap`（编制上限）；钱不够时仍是旧行为
3. 补将判定 `understaffed_team_count()` 仍按基础目标走 —— 否则富余 AI 会先把现有两支队伍塞满，却不补第三位将领
4. `logic/ai_profile.gd` + `data/config.json`：新增 `production.fill_to_cap_when_rich`（默认 `true`，可回滚旧行为）
5. 测试：`test_economy` 维护费表改为按阶断言（**74/74**）；`test_ai_commander` 新增 `_test_rich_fill_to_cap`（穷/富目标、越过基础目标继续补员、开关回滚）并把「富余时最大队伍」断言改成「不超过编制上限」（**341/341**）。顺手修了 `_test_auto_captures_zones` 的陈旧断言：开局探索会在 180 秒内把安全区划占完，常规扩张（`expands`）自然没有新目标，改成「常规任务或开局顺路占领」二者其一即可

### 2026.10.29 升本播报改到小地图上方 + 弹出 / 上移 / 上浮动效
1. `view/broadcast_banner.gd`：位置从屏幕顶部居中改到**左下角小地图正上方**（宽度 = 小地图 400，底边离小地图 `ui.broadcast.bottom_gap` 8px，贴左贴底）；最新的通知贴着地图，旧的通知向上堆
2. 新通知从左侧滑入（`pop_sec` 0.22s，easeOutBack 轻微回弹）并淡入；旧通知整体上移一格（`move_sec` 0.18s）；到期 / 被 `max_lines` 挤掉的那条向上飘 `exit_rise` 24px 并淡出。正在退场的那条不占 `max_lines`，允许短暂多一行
3. `data/config.json` 的 `ui.broadcast`：删 `width` / `top`，新增 `bottom_gap` / `pop_sec` / `move_sec` / `exit_rise`；宽度固定取小地图宽度。`view/hud.gd` 的注释同步
4. 测试：`test_base_broadcast` 46 → **67 项**（新增锚点 / 位置、最新在下、旧的上移、左滑入、上浮淡出、关动画直接终态）；全量 **95 套 / 8575 项断言全部通过**

### 2026.10.29 修复占领进度条多边形报错 + 主将濒死士气机制
1. `view/overlay_view_3d.gd`：新增 `_valid_screen_triangle()` —— 挡掉 NaN / INF / 坐标爆掉 / 重合点 / 共线三角形；`_screen_triangles()` 与 `_draw_zone_capture()` 双重校验，修实机 `Invalid polygon data, triangulation failed`
2. `logic/morale.gd` + `config.json`：新增 `morale.leader_down_drain`（默认 **3 点/秒**）。主将**濒死（倒地）**期间，整队士气 = 常规区划速率 + 粮车光环 - 3/s（增加和减少都叠加）；再起后保持当前值、恢复正常规则
3. 修复 C# 士气内核（`_tick_all_csharp`）：濒死 / 阵亡队长的士气原来没有填入分组数组，队员会镜像 **0**（用户报的「主将死后士气掉得很快」）。现在先填锚士气再 skip，且只锚到**还活着**的队长（与 GDScript `team_leader()` 同口径）
4. 测试：`test_view3d.gd` 新增 6 条退化三角形断言（264）；`test_morale.gd` 新增濒死士气下降 / 队员镜像 / 再起恢复 / C# 后端断言（70）。全量 **95 套 / 8554 项断言全部通过**

### 2026.10.29 主菜单新增 see_ai（看海）：between_moutains 双 AI 对战
1. `view/menu_deck.gd` / `view/start_screen.gd` 新增 `see_ai_pressed` 信号与 `see_ai` 按钮；位置在左上角 `ai_test` 正下方（同一 260×56、间隔 12px、同一显示条件），文案走 `menu.deck.main.see_ai_button`（默认 `see_ai`）
2. `view/main.gd` 新增 `_on_see_ai_button_pressed()`：仍载入 `ai_test_battle`（between_moutains），但走 `game.start_ai_observer(..., reveal_all=true)` —— p1 / p2 全部由 commander 接管，玩家是纯 spectator（`observer_mode`，不选边、无目标、不判负），并**显示全图**；AI 的逻辑视野仍是正常迷雾（不给他们开天眼）
3. `view/menu_deck_layout.gd` 新增 `screen_see_ai_button()`；`data/config.json` 的 `menu.deck.main` 新增 `see_ai_button`
4. `tests/test_ai_test_duel.gd`：验证两颗按钮同时存在 / 尺寸一致 / see_ai 在 ai_test 下方 / 显示条件一致；以及 see_ai 入口的观战装配（双方 commander、玩家不属于任何一方、无目标、看海全图显示但 AI 逻辑视野不变）。全量 **95 套 / 8536 项断言全部通过**

### 2026.10.29 起手资源：commander 默认 0 + 战役编辑器按阵营配置
1. **commander AI 默认不再附带额外资源**：`ai_profile.gd` 与 `data/config.json` 的 `difficulty.*.start_food/start_gold` 全部改为 **0**；难度只改收入 / 节奏 / 上限 / 反应延迟
2. 关卡 `factions[]` 每一项新增可选 `start_food` / `start_gold`（`logic/level.gd` 的 `faction_meta`；只收数字、负值夹 0、缺键 = 不覆盖这一方）
3. `logic/world.gd` 的 `_apply_level_start_resources()` 改为**逐阵营**覆盖：在 `reset()` 末尾把写了起手资源的那一方写到它的玩家池 / AI 池；没写的保持默认（玩家 `cfg.start_*`、commander 0）
4. 删除旧的「合作 AI 队友把玩家抬到 normal 250」逻辑（`_align_player_start_with_commander_ally`）—— 起手资源不再由难度或同方 AI 推导
5. `data/campaigns/demo/levels/ai_test_battle.json` / `between_moutains.json`：p1 / p2 各写 `start_food: 100` / `start_gold: 100`；实测第一次占领约 **28 秒**、第二支将领约 **114 秒**（100 金买不起 200 金的将领，必须先占黄金区划攒钱）
6. **战役编辑器**：`FactionEntry` 新增 `start_food` / `start_gold`（`None` = 不写），`model.py` 负责读写；`app.py` 的③阵营页每一方下面多一行「起手 粮 / 金」输入框（留空 = 不配置，填 0 = 显式写 0）
7. 测试：GDScript 全量 **95 套 / 8517 项断言全部通过**（`test_ai_commander` 325、`test_ai_test_duel` 129）；战役编辑器 `test_model` 341 / `test_app` 258 全部通过

### 2026.10.29 commander AI 开局发展：先占周围安全区划
1. `logic/ai_army.gd` 新增开局安全区目标选择 `_pick_early_capture_target()`：与己方相邻、**无主**、中心附近没有可见敌人，按粮食 / 黄金 / 人口缺口 + 距离评分；`_pick_explore_target()` 现在优先返回它，只有没有安全区划时才回到远处的普通探索
2. 开局探索队到达安全区划中心后**站住读条**（`_hold_early_capture()`），直到归属翻过来或附近出现敌人；旧逻辑「欧氏距离 ≤3 格就换下一个目标」永远凑不满 `capture_time_sec`（16 秒），所以开局一块地都占不下来
3. 占下一块后继续找下一块安全区划（`_at_owned_zone_center()` 给这次外出续时间），不再「到点 → 回家 → 再出门」循环
4. `understaffed_team_count()` 跳过正在外面的开局探索队：它无法在己方区划外招募附属兵，旧逻辑会一直把它算成「未装备队伍」，从而**挡住第二支将领**直到 60 秒探索结束 —— 这是开头 70~110 秒才第一次占领的直接原因
5. 配置新增 `ai.commander.early_explore.capture_safe`（默认 `true`）；`ai_profile.gd` 与 `data/config.json` 同步
6. `between_moutains` 实测（normal，p2 为 commander）：第一次占领由约 **110 秒**提前到约 **30 秒**，70 秒内拿下 4 块周围区划，经济与补将随之启动
7. 测试：`test_ai_commander.gd` 新增 `_test_duel_early_capture`（ai_test_battle 开局 60 秒内占领）；更新开局探索用例以验证「站住中心读条 / 占下后才换目标」；`_test_auto_captures_zones` 增加「90 秒内首占」断言。全量 **95 套 / 8494 项断言全部通过**

### 2026.10.29 主菜单 ai_test：between_moutains 随机选边 vs commander AI
1. `data/campaigns/demo/levels/ai_test_battle.json` 的目标地图由 `ai_test_2` 改为 **`between_moutains`**；两边都标成可玩、`ai: none`，并各摆一位开局将领（南军主将 / 北军主将），保证随机到任意一方都能直接开打
2. `view/main.gd` 的 ai_test 入口改成**每次按下随机**把 p1 / p2 之一给玩家，另一个席位在运行时覆盖成 commander（新入口 `game.start_level_vs_commander()`）；随机结果不写进关卡 JSON —— 同一份数据两边都写 `ai: none`
3. `view/game_scene3d.gd`：`start_level()` 新增可选 `ai_overrides` / `ai_profiles` 参数（不传 = 与以前逐位一致，老调用点零改动），并新增 `start_level_vs_commander()` 装配入口（内部只把「AI 那一方」写成 commander + normal 难度）
4. 新增 `tests/test_ai_test_duel.gd`（111 条）：目标图 / 双方可玩 / 按阵营分开的目标 / 玩家当 p1 与当 p2 两种装配（双方基地、开局将领、只有另一方是 commander、输入与 HUD 不是观战）/ 主菜单按钮的真实入口 / 随机结果两边都会出现

### 2026.10.30 主菜单左侧：雕版**轮播**（两张图交替扫描）
1. 第二张图（骑士 + 风车）走同一套流程：`tools/bake_menu_plate.py` 改成 **PLATES 表**（每张图自己的裁切 / 尺寸 / 画框内缩），可以一次烘两张、也可以只烘某一张；产物 `assets/menu/menu_plate_2.png`（1280×1080，白线 + alpha，8% 覆盖率）。第一张的产物与之前**逐字节一致**
2. 拆成两层：`etched_plate.gd` 只剩「画一张」（自己的 shader 材质 + `set_scan_x()` / `set_alpha()`）；**时间线**搬到新的 `plate_cycle.gd`（N 个 `etched_plate` 子控件 + 绝对时钟），`start_screen` / 测试 / bench 的调用点基本没动
3. 一档 = **扫描 9s → 停留 3s → 溶解 0.8s**；溶解发生在两档交界，上一张渐隐与下一张渐显**同时**进行（做成溶解而不是「先空一段再亮」：左边那块才不会闪一下空场）
4. 下一张淡进来的时候它的扫描头**停在画外左缘**，淡完才开始扫 —— 不会出现「淡进来时已经扫了一半」
5. 动效总开关关掉 / 进战斗停表时，钉在「第 0 张、扫描头在画面中间」那一帧（仍然不是空画面）
6. 配置：`menu.plate.images`（轮播的图，按顺序；读不到的会跳过，全读不到时用第一张兜底）+ `menu.plate.fade_sec`（溶解时长）
7. 测试拆成两份：`test_menu_plate.gd`（95 条：两张蒙版、shader、落位、参数）+ `test_menu_plate_cycle.gd`（76 条：轮播时间线、溶解不空场、下一张从最左边起扫、整轮回绕、冻结帧）
8. 顺手修了 `tests/bench_menu_shot.gd` / `test_menu_glow_fade.gd` 里已经失效的 `flag_button()`（战役页 API 早前改名成 `flag_buttons()`）
   ⚠️ `tests/test_start_flow.gd` 仍然引用已删除的 `chapter_buttons()` / `selected_chapter()`，那是战役页重构留下的，**没有动**

### 2026.10.28 移动端主菜单：去掉悬停，按下即点亮
1. 新增静态开关 `theme.hover_enabled()` / `set_hover_enabled()`（默认 = **非 `mobile`**）。★ 触屏按下去时引擎会模拟一次 `mouse_entered`，松开却**不补 `mouse_exited`** —— 桌面那套悬停态在手机上会**卡住**：横线一直亮、角泛光一直亮、填充按钮一直满金（后者以前靠 `start_screen` 在触摸松手时 `clear_hover_in` 兜底）
2. 战役 / 合作 / 演义（`menu_text_button`）：移动端忽略悬停事件，左右横线改由**按住 / 松开**驱动，松手回短横线 —— 悬停与点击合并成同一个反馈
3. 四角按钮（`menu_corner_button`）：亮金判定收进纯函数 `lit_for(hovered, pressed, hover_on)` —— 桌面听悬停、移动端听按住
4. 四角泛光（`menu_corner_glow`）：`set_hover()` 在移动端直接忽略；新增 `set_lit()` 由「按下 / 松开」驱动。侧栏灰层那条「强行熄灯」、以及 `set_sidebar_dimmed` 都改走 `set_lit(false)` —— 否则移动端熄不掉
5. 填充按钮（`fill_button._goal`）：移动端把「悬停」换成「按住」（`is_pressed()`），松手退回去。★ 这条是**全局**的：手机上 HUD 的按钮同样受益（以前点一下会一直满金）
6. 新增 `tests/test_menu_hover_touch.gd`（21 条）：移动端悬停不产生任何视觉、按住才亮、松手回位、`set_lit(false)` 熄得掉、四角 `lit_for` 的三档分支

### 2026.10.28 主菜单左侧：参考图的**雕版图** + 从左往右扫描金线
1. 主菜单左边那块空白（1920 设计空间下是 1280×1080）现在是用户那张参考图本身：先烘成**只有线**的**雕版蒙版**（`assets/menu/menu_plate.png`，白线 + alpha，1280×1080），再由 `plate_scan.gdshader` 按 `theme.palette.accent` 上色
2. 时间线只有一个动作：一道窄亮前沿**从左往右**扫过整幅画（9 秒），扫过的线留一段余晖再回落，扫完歇 3 秒，一轮 12 秒；★ 一进菜单扫描头在**画外左缘**（`start_frac = 0`）—— 点进来的那一刻它从最左边开始扫，而不是一进来就已经在中间
3. ★ 为什么这次用贴图（与「零贴图」那条口径不冲突）：那条口径管的是**UI 零件**（按钮图标 / 徽记 / 边框 —— 要跟主题变色、任意尺寸锐利，必须现画）；这一幅是**一张具体的插画**，程序化重画只能得到「有点像」（上一版那座程序化塔已被用户否掉）。于是**形状用贴图、颜色和光用代码**：贴图只存线条蒙版，换主题不用重烘
4. 烘图工具 `tools/bake_menu_plate.py`（开发期，不进游戏）：裁掉左边缆索段、切掉原图那圈**双线画框**（不切会只剩三条边、像画坏了），按亮度 + 暖度抽线，中值滤波去 JPEG 雪花，等比 cover 到 1280×1080
5. 落位 = **拉伸铺满**（`fit_rect()`，`menu.plate.fit` 默认 `fill`）：横竖各自拉满，**任何分辨率都不留空**。★ 手机宽屏的逻辑宽度会到 2400，左区因此是 1680（21:9 能到 1840），按等比铺只会有 1280 宽、两侧各空出 200~280px（用户报的「左右两侧有空」）。代价是非等比拉伸 —— 实测拉到 1.3~1.44 倍，这组线稿只是「胖一点」，比两侧黑边可接受。另留 `cover` 模式：等比裁切，宽屏贴顶（保塔冠、裁底部碎石）、窄屏贴右（保塔身）
6. 时间线仍是**绝对时钟**：能拨到任意一秒截图；动效总开关关掉时**钉在「扫描头在画面中间」那一帧**（按位置冻结，改了时长/起点也仍然落在中间）
7. 接线在 `view/start_screen.gd`：夹在 `Background` 与 `Intro` 之间、矩形止于右侧面板左缘（`clip_contents`）；进战斗停表。★ 切到战役 / 合作再切回主菜单时，雕版**跟着主面板一起横移**（`_sync_art_x()` 每帧把它的 x 对到「主面板当前位置 − 副栏宽」，右缘永远贴着主面板左缘）—— 不是原地淡出再突然淡入；回程是同一段滑动滑回来，所以看着是连续的一次横移
8. 颜色走主题金：雕版线 = `theme.palette.accent`（琥珀金），扫描头那一小段 = `accent_bright`（亮金），底色压到 0.24 的 alpha —— 不扫的时候是一张暗铜版，扫到的地方才是亮的。⚠️ 这是「accent 只给主行动」那条预算的明确例外（用户口径：贴合主题色），它只出现在主菜单左侧、且九成时间是暗的
9. ★★ 入场编排（用户口径）：点击进入游戏 → **logo 与游戏名右移、右侧面板同时渐显** → **面板完全站好之后**，四角泛光与左侧雕版**同时**渐显。落位那一整段里两者严格为 0（`_play_intro_morph` 把它们按死），渐显在 `_finish_intro()` 里同一帧发起：同一个时长（`menu.plate.fade_in_sec`，默认 0.6s）、同一条曲线（SINE / EASE_IN_OUT）—— 曲线只要不一致，同一时刻两者的透明度就不同，看着就是「一个先亮」。
   ⚠️ 踩到的坑：自定义 canvas_item shader 里写 `COLOR = ...` 会**整个覆盖**引擎注入的 modulate，节点的 `modulate.a` 淡入于是完全失效 —— alpha 从 0 爬到 1，画面亮度一动不动，雕版在 alpha 刚离开 0 的那一帧就以全亮出现（用户报的「一步到位」正是这个）。修法是在 fragment 开头 `vec4 tint = COLOR;` 再乘回去；`tests/test_menu_plate.gd` 里留了一条看门狗（shader 源码必须含 `tint.a`）
10. 顺带把 `ai_test` 调试入口从**屏幕正中**挪到左上角（260×56）：原来正好压在插画正中
11. 新增 `tests/test_menu_plate.gd`（84 条）与 `tests/bench_menu_plate.gd`（六张扫描分帧截图，只用于人工看样子）

### 2026.10.28 四角按钮的命中区改成贴角三角
1. 载入 / 好友 / 设置三颗角按钮不再是 56×56 的方形可点区：控件本身换成贴着对应角的 **180×180 方框**，真正能点/能悬停的只有靠近这个角的三角形（与右上角退出/返回的三角命中区同一尺寸、同一形状）
2. 三角判定收进 `menu_deck_layout.corner_has_point()`，四角共用一份：右上角退化为原来的 `x >= y`，四角按钮与 `menu_corner_hit` 都改走它；判定先卡方框，否则底角那颗的三角会延伸到「自定义/备战」上吞掉点击
3. 图标仍画在原来的 56×56 位置（`icon_rect`），位置、大小、悬停变金色都不变；`main_menu_panel` 在布局时分别给「触发框」和「图标框」定位
4. `tests/test_menu_corner_buttons.gd` 补到 105 条：四角的贴角点能点、对角半区点不到、图标中心必在三角内、三颗主按钮与底部动作条的中心不被三角吃掉，外加真实鼠标的「点三角外不发信号 / 点贴角处才发信号」

### 2026.10.28 菜单泛光的渐显 / 渐隐
1. 入场：主菜单四角泛光从 0 起，随底板一起渐显（`start_screen` 入场补间里多一路 `apply_glow_alpha`），不再一进场就常亮
2. 切页：泛光跟着「聚焦页」走 —— 主菜单 / 战役 / 详情 / 合作 / 房间 / 准备之间互切时，离开的那一页渐隐、当前页渐显，时长 `menu.deck.glow_fade_sec`（默认 0.26s，比 0.46s 的滑动先收尾）
3. 一块面板的「泛光组」= 右上角角光 + 顶部标题半圆光 +（主菜单）另外三颗角按钮的角光，统一走 `menu_page.set_glows()` / `glow_alpha()`；每块面板自己决定怎么变暗
4. 顶部半圆光只压纹理 alpha，标题文字不跟着变淡；侧栏灰层落下时泛光照旧强制熄灭
5. 整块面板本来就在渐显的那一页（`_move(..., fade=true)`）泛光直接给满，避免和面板自己的 0→1 叠成两段渐显
6. 动效关闭、地图选择层开合走同一套接口：前者瞬间到位，后者跟着面板整体渐显/渐隐
7. 新增 `tests/test_menu_glow_fade.gd`（38 条）：入场中段必须既不是 0 也不是 1、切页两端的终值、标题不跟着淡、动效关闭不留中间态

### 2026.10.28 主菜单四角按钮（载入 / 好友 / 设置）
1. 右侧主菜单面板新增三颗角按钮：**左上「载入」、左下「好友」、右下「设置」**（56×56，离边 40px），与右上角退出 X 同一圈、同一画法
2. 图标全部程序化 draw，无贴图无字体：载入＝托盘 + 下扎箭头，好友＝大小两个人形，设置＝齿轮；线宽 2.4，悬停换 `accent_bright`，tooltip 分别是 载入 / 好友 / 设置
3. 「左下 / 右下」取的是**不含底部自定义·备战动作条**的内容区底边（y=H-120）再往上 40px，所以三颗角按钮都落在动作条之上、与三颗主按钮不相交
4. 三颗按钮各自带一块角泛光（`menu_corner_glow.gd` 扩成四角，默认仍是右上）；亮起与熄灭跟按钮悬停联动，侧栏灰层落下时强制熄灭
5. `menu_close_button.gd` 并入 `menu_corner_button.gd`（退出 X 就是其中 `ICON_CLOSE`，几何/线宽/悬停色完全不变），四颗角按钮只有一套画法
6. 四张泛光贴片共用一份缓存：右上角烘焙一次，其余三角按 x/y 镜像得到，不再各跑一遍 256×256 逐像素循环
7. 暂不接点击逻辑：只发 `load_pressed` / `friends_pressed` / `settings_pressed`，页面不动

### 2026.10.28 编辑器有用表：地图 / 战役 / 关卡收口
1. 有用表迁到 `daeem/data/editor_visible.json`；新增共享读写模块 `tools/editor_catalog.py`
2. 地图编辑器移除手动「导入地图…」按钮与 Ctrl+O；工具栏「可见地图」只列表里的三张，导出到 `data/maps/<id>/` 后自动把 `<id>` 写回表并刷新菜单
3. 战役编辑器「战役」页关卡树只列使用有用表地图的关卡（当前 `mt / dscj / ai_test_2 / ai_test_battle`）；地图下拉 / 新建关卡只列三张 + 当前关卡的图
4. 战役编辑器保存 / `--new` 自动把战役 id 写回表的 `campaigns`；`--list` / 启动 / 自检只列有用战役
5. 旧测试关卡与旧图仍留在磁盘供运行时/测试使用，只从编辑器界面隐藏；`crossing + ferry` 维持物理归档
6. 测试：战役编辑器新增 `show_all_levels` 钩子保持旧断言，并新增关卡树过滤断言；地图编辑器更新按钮断言、新增可见地图菜单断言；新增 `test_editor_catalog.py`

### 2026.10.28 编辑器内容收口
1. 物理归档旧内容：`data/maps/crossing/` → `archive/maps/crossing/`，`data/campaigns/ferry/` → `archive/campaigns/ferry/`（说明与恢复命令见 `archive/README.md`）
2. 新增编辑器可见范围（后续版本迁到 `daeem/data/editor_visible.json`，并扩展为地图 / 战役 / 关卡的有用表）
3. 地图编辑器默认打开图改为 `main_test`；旧图在不同版本里分别由「导入地图…」或命令行 `--map` 打开
4. 战役编辑器地图下拉默认三张，编辑旧关卡时只额外追加当前关卡正在用的那张；新建关卡只列三张
5. `frontier / arena / dongzheng / ai_test` 仍被运行时/测试引用，保留在 `data/maps`，只从编辑器可见列表隐藏；逐条引用见 `tools/README-editor-scope.md`

### 2026.10.28 ai_test 按钮移到屏幕正中央
1. `ai_test` 从主菜单右侧面板移到 **屏幕正中央**（400×64）
2. 只在主菜单页显示：开场转场、战役、合作各页自动隐藏，不遮挡正常 UI

### 2026.10.28 主菜单标题与分隔线
1. 主菜单 DAE 字号由 36 提到 42（`menu.deck.main.name_size`）
2. 标题与下方按钮之间新增左右两端渐隐的金色分隔线（320×1，渐隐 40px；`menu.deck.main.rule_fade`）

### 2026.10.28 菜单细节与缩略图区划线
1. 房间码清除 `x` 常驻显示，改为 36×36 的金色线框按钮；不再随输入内容隐藏
2. 合作过渡页两面旗帜放大到 380×620，间距 180，顶部 y=210
3. 修复开场页 → 主菜单的 logo / 游戏名重影：转场期间先隐藏主菜单自己的 logo 与名字，徽记落位目标改为实际徽记矩形，结束时同帧切换
4. 游戏内标题 `menu.title` 由 `DAEEM` 改为 `DAE`
5. 主菜单「战役 / 合作 / 演义」左右线长度翻倍（静止与悬停同步），并钳制在按钮范围内
6. `map_thumb` 缩略图补区划分割线（1px、暗金、alpha 0.42），合作准备页 / 地图卡片 / 战役详情统一生效；战役过渡页继续用 `map_preview` 的现成区划线

### 2026.10.28 主菜单 / 战役 / 合作模式 UI-UX 调整
1. 右上角退出 / 返回按钮统一向左下移动 16px；三角命中区由 140×140 扩到 180×180（避开房间列表刷新按钮），手机端更好点
2. 合作过渡页底部新增静态提示「——点击空白处进入房间列表——」（`coop.lobby.click_blank_hint`），不挡空白点击
3. 合作准备页地图缩略图四边内缩 12px；选择地图卡片缩略图内缩 8px，均与边框留出间距
4. AI 队友准备页主按钮文案改为「开始」（`coop.lobby.ai_teammate.labels.start_ai`）
5. 房间列表标题不再拼接房间数；刷新按钮贴列表面板右缘留 12px，高度增至 56px（向下延伸），「房间列表」标题同高并垂直居中
6. 房间码输入框上移贴近面板上边距，数字键盘同步上移并把按键加高到 80px；「清空」键改为输入框内的 `x`
7. 「创建 / 加入房间」按钮移到与数字 0 同一行，占第 2、3 格（两个按钮宽度）

### 2026.10.28 主菜单新增 ai_test 测试入口
1. 主菜单中央（「演义」下方、底部栏上方）新增一颗 `ai_test` 文字按钮；文案读 `menu.deck.main.ai_test_button`
2. 点击后**跳过战役过渡页**，直接进入 `ai_test_battle` 关：`ai_test_2` 地图上的纯 1v1，玩家控制 p2（右下基地）对 command AI p1（左上基地）
3. 复用现有 `main._on_direct_level_requested()` 入口与 `ai_test_battle.json` 数据，不新增关卡 / 不改地图；AI 难度走配置默认 `normal`
4. 新按钮独立于「战役 / 合作 / 演义」三颗主按钮，不参与选中态，也不影响原有 `main_buttons()` 断言

### 2026.10.28 性能优化收尾（结束）
1. **用户确认手机端与电脑端都已流畅运行，性能优化正式结束**；不再安排性能轮次
2. 一页交接写进 `dev_gd_a/docs/mobile.md` **第 25 节**：现状（真机 ≈60 fps / 桌面 `bench_dscj` 4.76~4.86 ms/帧）、**唯一一份关键设置表**（`sim.*` / `unit.*_backend` / `fog.*` / `ai.garrison.decision_interval_sec` / `ui.mobile_*` / `render.mobile_*`，每项都带「怎么退」）、历轮落地汇总、**8 条经验**、再开性能工作的排查顺序（先 `ui.show_perf` → 均值查 `tick` 分段 / max 查周期性重活 → 最后才考虑结构改造）
3. 决策与边界另记 `docs/route.md` **第六十六节**：三条边界（手机 30 Hz 逻辑 + 60 fps 渲染、开关必须能一键回退、C# 只用于整段可批量的数值内核），以及**明确不做**的五项（`units` 整段 C# / packed 路径 / fog 增量索引 / 快照编码 / 客户端预测）与各自理由
4. `docs/README.md` 的「读哪一篇」「当前状态」与 `docs/architecture.md` 的「状态存在哪」同步更新（新增：驻防 AI 节流状态、视野版本号两条）

### 2026.10.28 性能第六轮：units 实测 / fog 版本号闸门 / 驻防 AI 10 Hz
1. **先修测量**：`world.tick` 单位循环里每单位两次无效 `_prof()` 与从未赋值的分段变量删除 —— 此前 `units/combat`、`units/reclaim`、`units/step` 三个读数**恒为 0**；新增 `u/timers` 与 `Unit.path_pops` 诊断计数器
2. **units**：实测 256 单位 `units 1.06~1.10 ms/帧`（combat 0.55~0.58 / step 0.26~0.28），`path_pops` 仅 **0.21~0.26 次/帧** ⇒ 推翻「成本在 `Array.remove_at(0)`」与「整段下沉 C#」两条旧判断，本轮**不做** C# 内核（决策表见 `docs/mobile.md` §24.4）
3. **fog 变更检测**：新增 `map.vision_revision` 版本号闸门（`fog.revision_gate`，默认开）——单位**真的跨格**时 +1，单位进出场 / 阵亡 / 建筑增删 / 归属变动走 `world.mark_vision_dirty()`；`_collect_flat` 顺带内联地形换算与阵营索引。dscj 实测命中率 12%、省 0.01~0.02 ms（大胜需要增量索引，未做）；新增 `tests/test_fog_revision.gd` **30 项**双路校验（两个 `FogRes`，300 帧逐字节相等）
4. **驻防 AI 降频**：`ai.garrison.decision_interval_sec`（默认 0.1 = 10 Hz，0 = 旧行为）；决策体所有计时器按**累加 dt** 推进；濒死复活不降频、改走缓存的 AI 将领短列表；删除 256 次字典插入、区划线性查找与每帧 `capture_bar()` 分配。实测 `ai/garrison` **0.565~0.600 → 0.269~0.348 ms**
5. 配置新增 `fog.revision_gate` / `fog.verify_revision` / `ai.garrison.decision_interval_sec`（均在 `config.json` 带注释与回退说明）；`tests/bench_dscj.gd` 新增 `DAEEM_FOG_GATE` / `DAEEM_GARRISON_INTERVAL` 两个 A/B 旋钮
6. 本轮只跑相关套件（未跑全量）：`test_fog` 183、`test_fog_revision` 30、`test_ai*` 462、`test_campaign*` 487、`test_logic` 265、`test_time_step` 24、`test_view*` 358、`test_snapshot*` 74、`test_ui*` 1448、`test_zone*` 301、`test_recruit_queue` 248、`test_attack_orders` 107、`test_retaliation` 51、`test_alliance` 78、`test_session` 33、`test_collision` 15、`test_crowd_path` 12、`test_morale` 58、`test_downed` 265、`test_minimap*` 59、`test_smoke` 132 —— 全过；`test_unit_backend_equiv`（强制 csharp）8 项通过

### 2026.10.26 建筑改版：木墙 / 哨塔 + 石墙 / 警戒塔 + 取消建筑升级 + 远程免伤 90%
1. 显示名：`wall` = **木墙**、`tower` = **哨塔**（内部 id 不变，地图 / 战役数据不用迁移）
2. 新增 **石墙**（`stone_wall`，700 血 / 120·120 / 5s）与 **警戒塔**（`watch_tower`，550 血 / 180·180 / 7s / 攻击 16、射程 4、间隔 0.7s、视野 15），放在建筑页**第二行**，需要 **2 级大本营**（1 级时可见但置灰）
3. **取消建筑升级**：`upgrade.levels` 只剩大本营；木墙 / 哨塔 / 石墙 / 警戒塔不再有等级表，选中它们时右下角没有升级入口；AI 也不再升级墙塔
4. **所有建筑对远程伤害免伤 90%**（`building.<type>.ranged_reduction`，缺省 0.9）：投掷物命中建筑只掉 10%；近战与**攻城（投石车）**走自己的伤害标签，仍全额
5. 选中建筑时详情面板写「远程免伤 90%」；建造页悬停写攻击 / 免伤 / 解锁等级
6. 新增 `tests/test_building_defense.gd` **26 项** + `tests/test_building_tiers.gd` **24 项**；聚焦套件 `test_ai_commander` 310 / `test_upgrade` 236 / `test_ui` 1260 / `test_unit_editor` 193 / `test_smoke` 132 全过；三个 Python 编辑器测试 571 + 209 + 331 + 245 全过（本轮未跑全量）

### 2026.10.26 合作 AI 队友起手资源对齐 + 行军主动结束
1. `ai_test_hz` 这类「合作关 + 同方 commander」的局：玩家席位起手资源抬到 **normal 难度基准 250 粮 / 250 金**，不再 0/0；友军 AI 仍按它自己的难度拿起手（easy 150 / hard 350）。只影响合作 AI 队友局，真人合作 / 战役 / 观战 / 普通对战不变（`world._align_player_start_with_commander_ally()`）
2. 「行军」不再只能等 60 秒：所有被派出的队都进入目标点 3 格、没有交战目标、且目标点 7 格内无可见敌人时，立即结束回到 `auto`；仍有敌人 / 没到点 / 仍在交战则继续，最迟 60 秒到期。面板会先显示 2.5 秒「已抵达」。「屯兵」保持 60 秒（`ai_army._march_reached_clear()` / `world.end_ai_directive()`）
3. 新增 `march.end_when_clear`（默认 `true`）可关掉提前结束；`arrive_radius` / `hold_radius` 从本轮起真正生效
4. 新增 `tests/test_ai_commander.gd` **21 项**（起手资源 / 行军主动结束）；该套件 **309 / 309** 通过，`test_ai_order_panel` 24 / 24、`test_ai_observer` 57 / 57 通过（本轮未跑全量）

### 2026.10.25 将领头顶标识：敌 / 友键帽 + 选中名牌 + 固定编号
1. 己方键帽显示**固定编号**（第 10 支写 `0`）；合作队友「友」、敌人「敌」；观战**所有将**按被观战方为「友」、另一方为「敌」，且不按迷雾过滤
2. 敌 / 友选中**只出键帽**（不泄露兵种 / 编制 / 士气）；己方选中出名牌：键帽 + 兵种 + 名字 + 编制 + 士气条
3. 多个己方名牌**不再退回键帽**：围绕各自头顶上下 / 左右找空位，保证展开的标签栏互不重叠；被让得较远的画一条细引线回头顶（10 张同时展开也验过）
4. 新增 `view/team_slots.gd` **固定编队槽位**：开局按 `world.units` 顺序分配 1..10，之后阵亡 / 复活**不改号**；阵亡将仍占槽、右栏置灰显示「重生 N 秒」，复活回原号；新将补**最小空槽**（阵亡占着的不算空）
5. 地图键帽 / 右栏部队列表 / 数字键 / 左栏详情编号共用同一份槽位；按阵亡将的数字键**不选人**，只提示「第 N 支部队：重生 N 秒 / 已阵亡」
6. 新增 `tests/test_team_markers.gd` **8 项** + `tests/test_team_slots.gd` **15 项**；全量 **83 个测试文件 / 8163 条断言** 全部通过

### 2026.10.24 AI 指挥官与合作 AI 队友
1. 新增第三种 AI `commander`：有独立大本营、资源池、收入，会招将 / 招兵 / 升级大本营 / 启用科技 / 区划特化 / 建箭塔
2. 合作模式开局前二选一：真人队友 / AI 队友；AI 队友占第二席位，不连中继，也能共享视野
3. 合作 AI 队友支持四条浮动面板指令：**行军**（选目标点）、**发展**、**扩张**、**屯兵**（选集结点）
4. AI 默认公平视野（不读全图），难度只改收入 / 节奏 / 军队上限 / 反应延迟
5. 军队上限跟着在场将领动态计算（每位将领的有效编制之和 × 难度比例）；补将目标按大本营 1/2/3 级为 3/6/10，大后期可到 10 位将领
6. 新增 `logic/ai_*.gd`、`view/ai_order_panel.gd`；设计稿见 `ai_doc/ai-commander-integration-plan.md`
7. 自定义对战房间本轮**未实现**，但 AI 的 `auto` 战略 / 难度包 / 基地兜底已为它预留
8. 主界面新增 **ai_test** 按钮：进入 `ai_test` 观战关，AI 接管 F1，玩家只读观察 AI 的指令 / 经济 / 建造 / 招兵 / 军队逻辑（右下命令卡隐藏，AI 面板只读）
9. ai_test 地图补黄金产能；补将不再只在顶满上限时尝试、会遍历己方区划；开局将领改为 `general_0`，大后期可到 10 位将领；箭塔上限 6
10. AI 默认改为**自主战略**（发展 → 扩张 → 进攻），玩家四条指令只保持 **60 秒** 的倾向权重，到期回到自主；自主发展时会派小队巡逻
11. AI 生产与外勤角色分离：**按队补员**（守军补满后轮换出门、新队接防），不再让一支部队一路招到全族上限；没有任何队伍在「光杆司令」状态下出门
12. AI 扩张改为**派队伍到区划中心读条**：按经济需求（缺粮 / 缺金 / 缺人口）+ 相邻 + 距离 + 守备评分挑目标；小队占中立、大队打敌方区划 / 大本营，拿下一块再换下一块
13. 招募改为**移动兵营**：下单时只要在己方区划且脱战，之后将领可随意移动 / 攻击；读条完成在将领**当前周围**生成单位；战斗或受击会暂停读条，脱战后继续（队列与已扣费用保留）
14. 读条中的将领**也可以被派去巡逻 / 出征**（守军够出门规模时可被换下来）；小股部队会按可见敌军规模绕开成规模敌军，扩张 / 巡逻 / 进攻都不硬碰（`expand.threat_radius` / `avoid_enemy_ratio`、`patrol.threat_radius` / `avoid_enemy_ratio`）
15. 主界面新增 **ai_test_2** 按钮：进入 `ai_test_2` 观战关，AI 接管 p1；与只读的 `ai_test` 不同，这一关**保留 AI 面板四颗指令按钮**（行军 / 发展 / 扩张 / 屯兵），玩家观战的同时可以给 AI 下指令
16. 指挥官 AI 会处理倒地将领：能再起就**再起**；敌后 / 离家太远且没兵时**召回**回大本营（`ai.commander.revive`）
17. AI 的所有移动目标点都会夹进地图内（基地贴边、巡逻环、区划中心 +1.5 等不再把部队派到图外）
18. AI 队伍粘合巡检：将领在走而附属兵掉队 / 停下（且不在战斗）时，**重发整队命令**，不单独调某个兵；召回会立刻清掉该将领旗下所有部队（与玩家召回同一条 `world.recall_general()`）
19. AI 清空区划守军后不会再因为「队伍掉编」直接放弃：目标无人防守时，残队也继续去中心读条占领；进攻目标同理
20. AI 队伍职能：`line` / `ranged` / `guerrilla` 轮换。远程队以远程编成为主、留少量抗线，停在目标射程外，前排倒光就整队后撤；游击队只打守军很少的边界区划，敌人一多就撤
21. 受击反击改为**队伍优先**：所属队伍有命令时（玩家或 AI 的移动 / 攻击 / 行军攻击 / 救援）不进入默认单兵复仇；AI 会立即重判「整队反击还是继续撤」并重发整队命令。只有队伍没有命令时，单个单位才默认反击
22. AI 箭塔改为按战略角色灵活布置：不再「一区一塔」，前线 / 被入侵区划可多座，后方默认少建；前线塔压向靠敌方的边界并尽量覆盖多段边，被入侵时优先贴区划中心补塔；资源富余时会追加目标数量、动用 reserve、同周期多建；不做「隔一格 / 最近建过就不建」的人为限制，位置只由战术评分决定（`ai.commander.build`）
23. AI 会在前线 / 被入侵区划围绕区划中心 3×3 外圈连续建城墙，缺口会补；箭塔和城墙都会在受威胁 / 前线区划升级，升级与建塔、建墙按周期穿插（`_try_wall()` / `_try_defense_upgrade()`）
24. AI 招将不再固定从大本营：按「被入侵 > 前线 > 大本营兜底」顺序选区划；前线刚招出的未成形队伍遇敌会整队后撤（`_general_recruit_zones()` / `_avoid_bad_fights()`）
25. AI 经济规划：建造前先预留下一轮补员 / 补将预算；有队伍缺编时暂停防御建造（只保留被入侵时的紧急城墙），避免城墙 / 塔把单位生产挤死（`_production_reserve()` / `_defense_paused()`）

### 2026.10.25 AI 封边与闲置部队
1. AI 城墙不再只围区划中心 3×3：资源富足后沿**己方边境**连续铺墙。前期只封与敌方接壤的前线（粮/金任一 > 1.5×`max_float`），到 3×`max_float` 再补中立接壤的整圈边境；每 tick 最多 3 格，给中心环留 16 个墙位（`ai.commander.build` 的 `wall_border_*`）
2. 封边评分优先「接上已有墙线」和「隘口 / 出口少的格」，其次受威胁 / 靠敌方的边；不占单位脚下、水路山口不重复封，地图边缘视为天然屏障
3. 闲置部队调度：**缺编队**（有 1~2 个兵、但不到 `min_field_units`）去己方前线区划中心 / 隘口驻守，敌人明显更多才撤；**满编队**去敌方 / 中立边界外侧侦察，遇接近自己规模的敌军整队撤，顺路占没有守军的空区划（`ai.commander.idle`）
4. **放宽部队数量**：外勤队目标 4→6、守军 6→8、同时训练将领 2→4、每将队列 3→4、每 tick 生产尝试 3→6；普通难度 `army_cap_ratio` 0.8→1.0、`army_cap` 26→36（简单 24 / 困难 48）。补将门槛改为「现有队伍至少到目标 - 2」才招新将，避免半编队旁边又冒光杆（`understaffed_team_count()`）
5. **造部队始终优先**：生产预留不再固定留 3 单，而是按「当前真的能生产出来的缺口」全部扣留；大本营升级 / 区划特化也走同一预算。缺兵且不在己方人口区 / 野外的队伍会被叫回最近人口区补员（`pending_recruit_units()` / `_recall_understrength_for_recruit()`）
6. **建造优先级**：同一 tick 只要造出箭塔就不再花墙的钱；钱只够墙不够塔时先攒塔；塔目标没建满时不升级墙，箭塔升级永远排在城墙升级前面。前线（受威胁 / 与敌方接壤）有塔缺口时，后方塔目标再大也先造前线（`_try_tower_then_walls()` / `_pick_tower_zone()`）
7. **受击整队反应**：有指挥官 AI 的一方，任何单位挨打都先交给 AI 检查该队当前任务，再决定**整队反击**（行军攻击到攻击者方位）或**整队撤到安全区**（普通移动，撤退路上不停下来打）；不再出现「一个兵自己追出去、其他兵原地站着」。侦察队受击直接收队，不反击。整队命令会清掉成员的单兵受击反击状态；粘合巡检（含守军）也会把「正在打自己目标但已掉队」的兵拉回队伍（`world.on_unit_attacked()` / `react_to_attacked()` / `_cohesion_tick()`）
8. **区划布防**：前线守备名额 3→4，另加 4 个「区划布防」名额；闲置满编队会被铺到**与敌方接壤 / 与中立接壤但暂时没敌人**的己方边境、侧翼区划，一区一队，优先受威胁 > 敌方邻接 > 中立邻接。守备分配现在发生在巡逻之前，不会先被巡逻拉去大本营 / 中场；大本营区划留给守军，不占名额（`_assign_zone_guards()` / `_pick_zone_guard()`）
9. **受击即时命令冷却**：同一队两次受击即时命令至少间隔 2 秒，再加 2.8 秒「反击 / 撤退模式锁」；锁定期内其它逻辑（巡逻 / 扩张 / 守备 / 粘合 / 回撤 / 玩家 march、mass、develop 重发）都不抢方向盘。同一片交火内的新攻击者（6 格内）不会重新选反击目标；撤退已在去同一个集结点时不再重发。避免短兵相接时队伍在「反击 ↔ 撤退」之间反复抽搐（`reaction.cooldown_sec` / `mode_hold_sec` / `counter_lock_radius`，`_react_locked()`）
10. **开局探索**：开局只有一支初始部队时，不再绕基地左左右右巡逻；改为普通移动出去探一圈（优先中立 / 空区划，顺路占空区划，不主动进攻）。到探索点后**不会立刻回基地再出门**，而是换下一个远处的点继续探；只有超时 / 没有下一个目标时才回基地休整。第二支将领出现或开局 60 秒后自动停止，交回正常军队逻辑（`_early_explore_tick()` / `ai.commander.early_explore`）
11. **占领区禁止建造**：敌方活单位进入某区划中心 3×3 占领区后，该区划整块禁止建造，直到敌人离开 / 被清除（进度回落不算，已离开就恢复）；`can_build_at(..., faction)` 与建造命令共用这条判据，拒绝事件 reason = `under_capture`。AI 同步适配：被踩占领区的区划不选作造塔 / 封墙目标，不升级该区建筑、不特化该区、不升级大本营（`world.zone_capture_blocked()` / `zone_capture_blocks_build()` / `_zone_capture_blocked()`）
12. **开局 60 秒扩张期**：`min_field_units` 3→1、`squad_units` 3→1，1 人队也允许出门占无守军区划；**不再强制大本营区划留一支守军**（`require_garrison=false`），将领走出基地不会被下一 tick 抓回去；守备 / 区划布防暂缓，补员回撤也暂停，避免把刚出去的小队拽回来。60 秒后自动恢复 3 人门槛、大本营守军、守备与常规回撤（`ai.commander.early_game` / `is_early_game()` / `_min_units()` / `_squad_units()`）
13. **清空敌方区划后占领**：敌方区划的守军被清空时，`_required_units_for_zone()` 不再硬卡 `enemy_zone_min_units=7`，改按小队规模派兵；已经站在敌方 / 中立区划里、附近无敌人但没有任务的队伍，由 `_capture_cleared_zone_tick()` 直接派往区划中心读条，且侦察 / 守备 / 巡逻不会抢走它
14. **交战中掉队回收**：将领正在打目标时，`_cohesion_tick()` 不再整队跳过；`_pull_stragglers()` 只把后方停住的附属兵用普通移动拉向将领，不打断将领当前目标（`cohesion.max_distance_tiles`）
15. **资源顺序：部队发展 > 升本 > 建造建筑**：`ai_build.update()` 先尝试大本营升级；只要还有下一级可升，本轮没升成（钱不够）就**攒钱**，不再把余钱花到科技 / 特化 / 塔 / 墙 / 防御升级上。大本营已满级 / 正在读条 / 正在重生 / 被占领区封锁时才继续常规建造；升本本身仍先扣生产预留（`_base_upgrade_candidate()` / `_try_base_upgrade()`）
16. **大本营将领挡位**：升二本要求 3 名将领，升三本要求 6 名将领；门槛取当前等级配置的 `max_generals`（1 级 3 / 2 级 6），不足时 `UpgradeRes.can_upgrade()` 返回 `generals`，建造命令拒绝并显示提示。AI 的 `_base_upgrade_candidate()` 同样在不足时返回空，不会把「当前升不了的本」当成攒钱目标（`upgrade.gd` / `ai_build.gd` / `hud.upgrade_reject_text()`）
17. **濒死将领不进入索敌**：C# 批量索敌的 `_tgt_alive` 改成「可攻击掩码」（`is_attackable()`，倒地 = 0），否则最近目标是倒地将领会把结果过滤成 null、后面的活兵永远轮不到；`ordered_target` 倒地时命令作废；飞行中的投掷物也不再追着倒地单位。人群分离仍用原来的 `alive` 掩码，倒地将领照旧占位（`crowd_bridge.gd` / `combat.gd` / `projectile.gd`）
18. **不再绕基地四角巡逻**：普通巡逻点去掉了大本营外围四个点，只走己方区划中心（含前线）；只有基地一个区划时队伍不会在左上右下之间反复进出。开局探索到点后换下一个远点，不再「到点 → 回基地 → 休整 → 再出门」循环（`_patrol_points()` / `_early_explore_tick()`）
19. **外勤队启动 / 防闲置**：没有任何外勤队时，即使守军没补满也先招一位将领当外勤；补员优先补未成形的外勤队。没有满编外勤队时，允许 1 人队去占**完全无守军的无主区划**（有守军的敌方区划仍要凑够规模）。已有扩张 / 进攻任务的残队不再被 `_regroup` 往基地拉，避免「目标 ↔ 基地」每帧互相覆盖导致抽搐（`_production_tick()` / `_pick_bootstrap_team()` / `_regroup()`）

### 2026.10.24 单位招募扩展
1. 单位招募页签改成三行：第 1 行长枪兵 / 长弓兵，第 2 行骑手 / 粮车，第 3 行骑士 / 马弓手 / 投石车；第 2 / 3 行分别需要大本营 2 / 3 级
2. 新增粮车：骑兵 / 远程标签，不攻击，只花粮食，持续为周围 3 格友军提升士气（多辆不叠加）
3. 新增骑士 / 马弓手 / 投石车：骑士高护甲高攻击 + 远程减伤；马弓手无护甲 + 远程减伤 + 移动射击；投石车为器械 / 攻城，攻击是 1.5 格范围伤害
4. 新增固定护甲、攻城无视远近战减伤、范围伤害、移动射击、士气光环等机制
5. 粮车被选中时，脚下显示紧贴地面的细线范围圈
6. 新增开发者快捷键 Ctrl+3：本机控制阵营的大本营立即升到 3 级（免费；正在升级时按取消升级退款）

### 2026.10.23 将领招募系统更新
1. 为游戏添加了"将领特性"机制，现在将领可以为其部队加buff了
2. 更改了将领招募机制，现在将领招募后会进入全局冷却（但数值还是占位数值）
3. 添加并更改了将领的再起/召回机制
4. 新增开发者快捷键ctrl+1为本机粮食/黄金+1000
5. 添加了更多的占位将领，并更改了将领招募页签，现在招募将领有了大本营阶数限制

### 2026.10.22 升级系统更新
1. 为大本营添加了攻击力，套的是箭塔的逻辑
2. 实装了大本营升级效果及其附属的统领将领上限增加和科技解锁效果
3. 更新了科技页签
4. 为单位添加了受击反击逻辑
5. 新增了buff_editor，用于敏捷调整buff数值
6. 增大了选中单位的范围，现在操作似乎更顺手了些
7. 为单位添加了独特属性，如长枪兵的骑兵特攻
8. 为游戏添加了胜利/失败画面，并添加了开发者快捷键ctrl+w和ctrl+l快速胜利和快速失败
9. 更改了将领标签的点击逻辑并优化了将领标签的泛光效果

### 2026.10.21 合作模式小更
1. 今天偷懒了
2. 部署并测试了服务端，现在能正常联机了
3. 更新了详细信息ui栏，并为手机端做了新适配
4. 为游戏内添加了山/水/树的占位建模
5. 为合作模式添加了测试后门，现在可以点击ctrl+q为合作模式房间添加一个虚空队友

### 2026.10.20 合作模式大更
1. 现在还没有测试，另外，新包的合作模式暂时不可用，因为还没把新服务端上传
2. 为合作模式添加了一张测试用的地图：登神长阶
3. 为合作模式设计并应用了新ui
4. 更改了游戏内ui，使将领标签显示在右侧边栏，战役目标显示在左上角
5. 为游戏添加了新地形：水域，不可移动，不阻挡视野
6. 优化了战役编辑器并使其更更健壮
7. 为项目整体调了色（虽然好像和没调之前没差太多）
8. 优化了战役过渡面板及其选择阵营面板
9. 为后续开发写了一大堆文档（因为我今天上了一节马原），预计明天更合作模式和游戏内的详细信息ui栏

**合作模式大厅还没验证，明天早上优先验证这个！**

### 2026.10.19 合作模式与战役更新
1. 为游戏添加了合作模式框架并部署在了服务器端，现在可以联机游玩了
2. 为战役模式添加了nsoc同款的缓冲界面和选择阵营界面
3. 优化了游戏的渐入渐出动画和游戏内的旗帜动画
4. 修复了游戏进入过渡动画点击过快时的图标消失的bug
5. 修复了选中单位后右键点击友军建筑无法移动的bug
6. 为战役中的红点性ai添加了小地图的菱形红点
7. 统一了敌人/友军/己方的标识颜色
8. 优化了战役过渡画面的进度条显示
9. 为游戏添加了退出确认浮层

### 2026.10.18 双端适配与优化
1. 为游戏添加了主菜单的战役菜单和游戏内的选项菜单，基本抄的nsoc
2. 优化了手机端的按键逻辑与表现
3. 优化了选框绘制与作用逻辑
4. 为游戏中的移动/行军旗帜添加了动效
5. 优化了手机端的性能，现在基本能60帧运行了

### 2026.10.17 安卓端适配与优化
1. 预计明天上传包体，今天深夜还在更新
2. 设计并应用了安卓端的操作逻辑
3. 为地图边界添加了描边，想的是抄《帝国时代4》的地图边界，后续还有待考虑
4. 因为导出的游戏在我的手机上跑到了20帧，所以晚上一直在优化，目前已经可以跑到50帧了，真神了我说
5. 现在是10.18凌晨一点，完成了包体更新，现在提到了60帧左右，可以暂停性能优化了，接下来要优化一下手机端的操作逻辑（最好电脑端也同步修改一些），比如选框不需要贴合3D地面，比如手机点击按钮时的错误动画

### 2026.10.16 ui/ux更新
1. 复用了前面项目nsoc的主界面ui/ux改造了当前游戏的主界面ui/ux（当然有一点点更改）

### 2026.10.15 GameLinkAgent更新
1. 简单来说，本项目今天没有任何更新，但负责本项目的联机开发agent更新了，详情见
```
https://github.com/yuyi-yutie/GameLinkAgent
```

### 2026.10.14 士气系统更新
1. 修复了红点性ai的行军bug，修复了游戏开始时选中单位的bug，修复了可以建造建筑并占领其他区划的bug，修复了详细信息栏阻挡框选的bug
2. 去除了游戏开始时生成初始将领和建筑的逻辑，确保所见即所得
3. 优化了战役编辑器的摆放页
4. 精简了测试
5. 为游戏添加了士气系统，并调优了数值（后续可能再调）
6. 在详细信息栏添加了单位的血量和士气显示
7. 修改了地图编辑器中的区划产能默认值

### 2026.10.13 新测试战役
1. 应用了test_main地图到新的战役中，并将以此作为主要测试战役（不过大部分已经测完了）

### 2026.10.12 开发留档
1. 预估明天上传本次更新
2. 新建了test_main地图，后续以此地图进行编辑器与游戏测试
3. 优化了数值
4. 正在优化三大编辑器

### 2026.10.11 编辑器更新与优化
1. 修改了三大编辑器，使其操作逻辑更顺畅
2. 优化了单位的寻路和阵型逻辑，也一并优化了游戏帧率
3. 为区划中心更改了占领机制
4. 全面启用3D/2D管线，废除2D管线
5. 添加鼠标中键视角操作
6. 修复地图显示bug，并优化了摄像机视野
7. 修改了红点的生成逻辑，现在红点可以随机在所有被配置了红点生成属性的地块生成了
8. 立个flag，在10.18前做出可玩战役，并在10.18后开始写合作模式

### 2026.10.10 开发留档
1. 因为打塔科夫去了所以有些验收出了问题，今天的日志合并到明天
2. 战役编辑器中还需要改点东西
3. 红点性ai不需要分配阵营（或者让ai自动为其分配一个特殊阵营）
4. 设计师要可以在阵营界面中新建阵营

### 2026.10.9 ai与编辑器更新
1. 将游戏中的ai逻辑简化了，现在只有阵地性ai与红点性ai，红点性ai暂时没有实测
2. 相应地为适配ai逻辑，更新了编辑器的功能
3. 为大本营和箭塔，区划中心建了占位的模型，同时为区划中心添加了模型动画
4. 后续考虑优化编辑器界面和视野缩放

### 2026.10.8 视觉效果更新
1. 更新了单位/建筑受击闪白
2. 更新了远程单位射出抛射物，抛射物用占位方块替代
3. 添加了占位用的2D单位素材和3D建筑素材
5. 增加了建筑透明化机制
6. 添加了单位下贴花和将领下贴花
7. 修复了模型上下颠倒的问题，修复了单位寻路bug
8. 前两天一天是转移地点，一天是纯懒，现在接着更新

### 2026.10.5 3D更新
1. 将游戏从2D升到了3D
2. 修复了ai的某些bug，如识别建筑错误，边界抽搐等
3. 后续还需要人工跑测3D下某些逻辑是否完整复刻

### 2026.10.4 ui/ux更新
1. 向游戏添加了ui主题
2. 添加了选中敌人的逻辑
3. 用ai写了一个占位战役，但这个战役挺不行的，不打算启用
4. 修复了一些bug并新增了一些bug
5. 道阻且长

### 2026.10.3 战役编辑器更新
1. 为将领添加了死亡保护机制
2. 更新并完善了战役编辑器的逻辑，现在可以真正使用战役编辑器编辑原有战役了
3. 为占位目标（占领/守住某区划）增加了兼容性
4. 修复了一些ai方面的bug
5. 后续考虑调数值和做战役原型

### 2026.10.2 ai与战役更新plus
1. 更新了ai逻辑，现在的ai可以自主巡逻了
2. 更新了战役双选，现在单个战役可以选择不同阵营达成不同胜利目标
3. 添加了区划描边
4. 调整了占位战役，使其方便测试
5. 后续要为将领添加死亡保护和调试数值，或许可以考虑将囊关之战的原型加进去

### 2026.10.1 ai与战役更新
1. 昨天从杭州回南昌了，所以停更了一天狠狠打塔科夫
2. 完善了一下ai，但还没有完全完善，还需要加入如单位的巡逻和随机移动让ai看起来更自由
3. 创建了一个战役编辑器campaign_editor，且支持与map_editor直接联动，但我还没掌握这个东西要怎么用
4. 创建了占位战役
5. 预计明天做一个可以玩的战役出来

### 2026.9.29 一半更新

1. 加入了战争迷雾和单位视野系统，并同步更新了单位编辑器
2. 更新了选择地图界面，目前还是占位逻辑
3. 更新了游戏内的设置界面，为其添加了全屏和退出到菜单的功能
4. 更新了ai逻辑，但还没有完善，目前支持为任何一p分配ai，且支持敌友分配
6. 后续考虑加入新手教程和单人战役编辑器

### 2026.9.28 单位编辑器更新

1. 优化了详细信息面板的显示
2. 加入了资源显示面板
3. 加入了详细操作悬停面板
4. 在tools中加入了unit_editor用于敏捷调整数值，目前可调单位/建筑/科技数值
5. 后续考虑加入战争迷雾和占位战役

### 2026.9.27 分类更新

1. 更新了区划分类和单位分类
2. 区划目前分三类，粮食区划，黄金区划，人口区划，相应地特化也会不一样
3. 单位目前分两类，步兵和骑兵（后续考虑加入攻城武器），具体加了三个占位单位，长枪兵，弓箭手，骑兵，并为其添加了对应的占位素材
4. 后续考虑完善将领招募系统

### 2026.9.24 科技更新

1. 把占位的科技系统实装了，加入了9个占位科技
2. 为建筑和区划中心添加了升级和特化系统，目前设定为建筑可升级两次，区划可有三种占位特化
3. 后续考虑为区划系统添加功能，包括"特产区划和特化限制"，地图编辑器对特产区划的适配等

### 2026.9.23 气愤更新

1. 加入了将领招募系统，并向其中添加了占位将领，后续还待完善该将领招募系统的招募周期和资源消耗逻辑
2. 重做了右下角的页签栏，现在选中单位/建筑/将领会有不同的页签显示
3. 没有人打塔科夫，没有人玩游戏，这个世界完蛋了，今天就更这么点

### 2026.9.22 小地图与ui完善

1. 详细信息ui已经完善，包括左侧部队切换面板和右侧详细信息面板
2. 完善了招募的ui（作为占位ui已经很完善了）
3. 为小地图增加了按住拖动鼠标移动视角的操作
4. 后续考虑加入将领招募和更多单位，并完善招募系统

### 2026.9.21 小地图与ui更新

1. 主要为游戏内添加了小地图和新的详细信息ui，但详细信息ui还没完善
2. 小地图还需要添加一个按住拖动鼠标可以移动视角的操作
3. 更新了基础的招募系统，招募的ui还没做适配
4. 艹

### 2026.9.20 技术栈更换

1. 加入了C#以解决多单位寻路的优化问题，当前预期的单位数为1000，地图大小为100x100
2. 增强了地图编辑器，并加入了区划中心
3. 完善了测试地图
4. 为游戏加入了占位用的进入游戏界面和主界面
5. 加入人口属性，但现在还没有和单位招募联动
6. 删除了dev_html

### 2026.9.18/19 引擎迁入和地图编辑器更新

1. 将项目迁移到了godot引擎中，并完整复现了html版的所有内容
2. 为游戏加入了初步的ui
3. 增设了地图编辑器，设计师可以在此tool中编辑地图
4. 修改了默认的测试地图
5. 完善了单位的寻路和索敌逻辑，并设置了基本的按键映射

## dev_html

（命名dev为develop版本）本版本为原型阶段html的开发，仅展示玩法，目前已经删除

### 2026.9.17 简要联机更新

1. 初步加入了联机模块
2. 目前支持双方通过浏览器进行互联网联机对战

### 2026.9.12 更新
1. 初始化了占位地图，加入了地块和区块的概念，加入了占点的基本玩法
2. 加入了基本的数字键选中编队逻辑和建造逻辑
3. 为单位加入了攻击和警戒逻辑
4. 初始化了基本的镜头逻辑
5. 目前单位寻路还存在问题，但无关紧要，放引擎里再优化

