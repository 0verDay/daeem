# 更新记录

> 本文件由原 README 的更新日志拆出，按时间倒序保留。项目概览、快速开始和文档索引见 [README.md](README.md)。  
> AI 的**当前行为**不要从本文件推断，请看 [ai-commander-current-status.md](ai_doc/ai-commander-current-status.md)。

## dev_gd_a

本版本为在godot引擎内的原型开发，仅展示完整的局内玩法

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

