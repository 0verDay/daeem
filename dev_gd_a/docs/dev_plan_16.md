# dev_plan_16 —— 两个新派系：王朝·义勇军 / 帝国·教会军

> 状态：**已实现（2026-11-18）**。
> 工程：`dev_gd_a/daeem/`。数据全在 `data/config.json`，规则在 `logic/`，视图只读数据。
> 需求原话见 `CHANGELOG.md` 的 2026.11.18 那一条；本文记录**实现口径**与**踩到的坑**。

---

## 0. 已确认的决策（本轮问答）

| 项 | 决策 |
|---|---|
| 接入方式 | **新增两个独立 clan**（`dynasty_volunteer` / `empire_church`），现有 `dynasty` / `empire` **逐位不变**；另加一个展示关（`ai_test_clan`）。 |
| 备战界面 | **加上了**（2026.11.18 第二版）：`LoadoutRes.FACTIONS` 四枚竖排按钮，见 §2.10。 |
| 素材 | 12 个新兵种**不写 `sprite`** ⇒ `view/unit_sprite_3d.gd` 自动退成**单字立牌**（字来自 `icon`）。教堂同理走占位。 |
| 教堂归属 | **仅教会军可建**；每区划限 1 座；1→2 级；**等级上限 = 当前大本营等级**。 |
| 自由税 | 改成对**含「自由」**的单位收税（与「不自由税」互补；两条都点 = 全员交税）。 |
| 「自由」 | **永久单位属性**：在带教堂（≥1 级）的区划里招募那一刻写死，离开区划也保留。 |
| 「自由瘟疫」 | **区划属性**；伤害是**固定值**（`zone.plague_damage_per_sec`），对区内**所有没有自由的单位**生效（**含友军 / 自家非自由单位**）。 |
| 侵略如火 | **单位还在敌方区划里就生效，走开立刻恢复**（不写死到区划上）。 |
| 血战到底 | 扣的是**当前血量**（每秒 5% 血上限），**对将领也生效**；每单位只触发一次。 |
| 溺水 | **只做数据预留**（用户拍板）：效果全部接好，但**目前没有任何路径能拿到这条状态**。 |

---

## 1. 数据（`data/config.json`）

### 1.1 两个派系

| 项 | 王朝·义勇军 `dynasty_volunteer` | 帝国·教会军 `empire_church` |
|---|---|---|
| 图标 | 义 | 教 |
| 招募 | 6 条（2 / 2 / 2 按一 / 二 / 三阶） | 6 条（2 / 1 / 3） |
| 方略 | 9 格（7 条 + 2 空） | 9 格（7 条 + 2 空） |
| 建筑白名单 | **不写** ⇒ 全都能造 | `["church"]` ⇒ 只能造普通建筑 + 教堂 |
| 主题 | 人海 / 水网 / 血战 | 信仰 / 自由 / 瘟疫 |

### 1.2 方略（`tech.clan_list`）

义勇军：`dv_blitz` 侵略如火（1）· `dv_immovable` 不动如山（2）· `dv_blood_war` 血战到底（3）·
`dv_guerrilla` 游击战术（3）· `dv_water` 会水（3）+ 复用 `tech_speed_rush`（1）· `dg_levy` 征召民兵（2）。

教会军：`ec_unfree_tax` 不自由税（1）· `ec_free_tax` 自由税（2）· `ec_bathe` 沐浴自由（2）·
`ec_undying` 信仰不死（3）· `ec_missionary` 传教（3）+ 复用 `tech_speed_rush`（1）· `tech_unbreakable`（3）。

> ★ 复用同一个 id 是**故意的**（「征召民兵 / 速战速决 / 无懈可击」在需求里就是「同游戏中已有的方略」）：
> 效果只有一份数据，两派的槽位表都引用它。

### 1.3 单位状态（`unit.status`，新机制）

| id | 名 | 效果键 |
|---|---|---|
| `water_walk` | 水性 | `water_walk` / `water_speed_mult: 0.5` |
| `drowning` | 溺水 | `immobilize` / `damage_taken_add: 1.0` / `hp_drain_ratio: 0.05` |
| `freedom` | 自由 | `hp_mult: 0.1` / `attack_add: 0.1` / `armor_mult: 0.1` / `plague_immune` |
| `blood_war` | 血战到底 | `attack_add: 0.5` / `hp_drain_ratio: 0.05` |
| `undying` | 信仰不死 | `invincible`（那 3 秒） |

> ★★ **与 `unit.unit_traits` 的区别（最重要的一句）**：
> 特性 = 兵种**天生**的静态标签（永远不变）；**状态 = 运行期属性**（兵种 / 方略 / 建筑 / 机制都能加减）。
> 两张表分开存、分开洗（`_cache_unit_traits` / `_cache_unit_status`），互不覆盖。

### 1.4 兵种（`unit.types`）

义勇军：`dv_bandit` 流寇（1 远步）· `dv_jinfan` 锦帆（1 近步，**天生水性**）· `dv_greenwood` 绿林（2 近步，范围 + 对步兵）·
`dv_grass_cart` 草车（2 器械支援，比粮车便宜但更弱）· `dv_xiangma` 响马（3 骑射，对骑兵）· `dv_arrowstorm` 万箭穿心（3 器械，6 段齐射）。

教会军：`ec_pilgrim` 朝圣者（1 近步，对骑兵）· `ec_faith_archer` 信仰弓手（1 远步，对步兵）· `ec_preacher` 传教士（2 近骑，侦察 + 自愈）·
`ec_flail` 神圣连枷（3 近步，**范围攻城**）· `ec_templar` 圣殿骑士（3 近骑，稳定 + 远近免伤）· `ec_relic_cart` 圣物推车（3 器械，强治疗光环）。

### 1.5 教堂（`building.church` + `upgrade.levels.church`）

本文件独有的键（其它建筑不写 = 行为不变）：

- `clans: ["empire_church"]` —— **这一种建筑允许哪些派系造**（空 = 不限）。
  ★★ 2026.11.18 修正：这是「额外建筑」的判据，**不是**「这一派只能造这些」——
  没写 `clans` 的通用建筑（墙 / 塔 / 田 / 房屋 / 矿脉）照旧每一派都能造。
- `per_zone_limit: 1` —— 同区划同类型上限；
- `max_level_by_base: true` —— 等级上限再被**己方大本营等级**压一次；
- `min_base: 1` —— **解锁所需的大本营等级**（缺省 = `tier`）。教堂写 `tier: 3` 只是因为它要占
  建筑页那唯一的空格子（第 3 行第 2 列），真正开局就该能造 —— 它是这个派系的核心玩法。
  漏了这个键的症状：教堂牌在 1 级大本营时是灰的，悬停写「需 3 级大本营」。
- `freedom_recruit` / `plague_from_level` / `plague_adjacent` —— 1 级给自由 / 2 级起染疫 / 连相邻区划。

---

## 2. 机制与落点（改哪儿、为什么）

### 2.1 状态：谁能改、谁只读

- `logic/config.gd`：洗表（`_normalize_unit_status`）、合并（`status_effects_merged`）、只读访问器。
- `logic/unit.gd`：**唯一**的状态容器与效果落地点 —— `grant_statuses()`（幂等）、`status_rev`（补写版本号）、
  `tick_status()`（掉血 / 自愈 / 无敌倒计时）、`effective_armor()`（防御的唯一口径）、`_try_fatal_survive()`。
- `logic/world.gd`：`_tick_unit_statuses()` 每帧给「版本号对不上」的单位补一遍 `statuses_for_unit()`
  （目前只有「会水 → 步兵拿水性」）。
  ★ 为什么用版本号而不是在 8 个出生点各写一行：出生路径有 8 条，漏一条就是「这个兵天生不会水」这类静默 bug。

### 2.2 水性 → 跨水域

`Pathfinder` 的全部公开入口都多了一个可选 `water := false`（默认 = 老行为逐位不变）。
`unit.gd` 在 13 个调用点传 `is_water_walker()`；**会水单位绕开 C# 距离场**（内核把水域当墙），走 GDScript A*。
代价：会水单位单次寻路 ~19 ms（100×100 图），但它们很少，且不影响队里其他人。

### 2.3 侵略如火 → 区划倍率

`world._refresh_zone_effects()` 每帧重算：逐区划数「这一方有几个活单位站在敌方区划里」，
把 `production_mult` / `population_mult` 写进**区划字典**；`zone.production_of()` 与
`update_population_multi()` 读它们（缺键 = 1.0）。
★ 不缓存：教堂被拆 / 兵走开 / 归属变了，下一帧自动回到中性。

### 2.4 教堂 / 自由 / 自由瘟疫

- 准入：`world.building_allowed_for_faction()`（建筑侧 `clans` 白名单 + 派系侧 `clan.buildings`，**取并集**）、
  `zone_building_count()`、`building_level_cap(b)`。
  ★★ 2026.11.18 修的坑：`clan.buildings` 一度被当成**排他**白名单 ⇒ 教会军只剩教堂一格、
  连粮田都被拒（AI 也建不了经济建筑）。现在它是**额外**清单：通用建筑谁都造，
  写了 `clans` 的才只有名单里的派系能造。判据只有一处 —— `cfg.clan_can_build()`。
- 等级：`upgrade.can_upgrade_reason()` 改读 `world.building_level_cap(b)`（拒因 `base_level_cap`）。
- 解锁：建筑页那三行的行号 = 解锁等级；教堂用 `min_base: 1` 覆盖（`cfg.building_min_base()`），
  `hud._build_entries()` 的 `ready` 与悬停的「需 N 级大本营」都读它。
- 自由：`world.grant_recruit_statuses(u)`（招募完成那一刻，判**落点所在区划**有没有己方教堂）。
- 瘟疫：`world._refresh_zone_effects()` 每帧按「2 级教堂 + 传教」重写 `z["plague"]`；
  `world._tick_plague()` 对染疫区划里**没有自由**的单位每秒扣固定血（`zone.plague_damage_per_sec`）。
  ★ 瘟疫烧死**不触发**致命伤保护（否则「血战到底」= 无敌）。
- 传教：只认 `world.is_out_of_combat(u)`（与招募读条 / 屯田制同一个「脱战」定义）。

### 2.5 两条致命伤保护（`unit.take_damage`）

顺序固定：① 血战到底（回满 + 暴走，每单位一次）→ ② 信仰不死（锁血 1 + 3 秒无敌，20 秒冷却）→ ③ 将领濒死 → ④ 阵亡。
★ 信仰不死用户没写次数，这里按**冷却**实现（`fatal_invincible_cooldown`，缺省 20 秒）；
★ 无敌期间 `take_damage` 在**最前面**就返回（连闪白都不发生）。

### 2.6 多段齐射（万箭穿心）

`unit.load_burst_def()` 抄参数；`combat.attack_unit()` 打出第 1 段后进入**长装填**并把剩余段数交给
`u.start_burst()`；`combat.tick_burst()` 每帧补一段（不重置 `attack_cd`，目标死了 / 跑远了整段取消）。
★ 伤害在第 1 段那一刻就烘好：装填期间攻击力变化不回溯。

### 2.7 视图

- 建筑页：`cfg.buildable_building_defs_for(world.clan_of(my_faction))` —— 非教会军**看不到**教堂那张牌。
- 详情栏顶带 buff 槽：`hud._unit_status_buffs(u)` 读 `unit.status`（第一次真的有内容）。
- 拒因文案：`clan` / `per_zone_limit` / `base_level_cap` 三条中文。
- 等级显示三处改读 `world.building_level_cap(b)`（教堂的 1/2 与「1/3」不会错）。

### 2.8 联机

`snapshot._unit_fields` 新增 `sts`（状态 id 逗号串）/ `bwa`（暴走态）；
`apply_snapshot` 用 `u.set_status_list()` 恢复；缺字段 = 老快照 ⇒ 保持本地现状（与其它字段同一条约定）。

### 2.9 教堂的 3D 模型（Blender）

| 项 | 值 |
|---|---|
| 文件 | `assets/models/church_l1_lowpoly.glb`（1 级）/ `church_l2_lowpoly.glb`（2 级） |
| 规格 | 1 单位 = 1 格、底边 y = 0、正面朝 −Y（局内朝相机）、0.96 / 1.016 见方、高 1.90 / 2.26 格 |
| 面数 | 180 / 298（低模，与其它建筑同量级） |
| 顶点色 | rgb = 材质原色；**a = 阵营色遮罩**（屋顶 / 尖顶 / 十字 = 1，墙体门窗 = 0） |
| 登记 | `view/building_view_3d.gd` 的 `BUILDING_MODELS["church"]`（1 级）+ `BUILDING_MODEL_LEVELS["church"] = {1, 2}` |
| 图标 | `assets/ui/card_icon/building_church.png`（`tools/bake_church_icon.py` 从 glb 抽边线烘的线稿） |

![教堂两档模型（左 1 级 / 右 2 级）](img/church_preview.png)

★★ **加模型时最容易踩的一脚**：Blender 的 glTF 导出器**默认把顶点色写成 VEC3**（alpha 直接丢掉）。
Godot 读进来 alpha 全退化成 1 ⇒ 整栋被染成阵营色（看着像「没有贴图」）。
解法是在材质里把**顶点色的 Alpha 也接到 Principled 的 Alpha 上**（外观仍是 OPAQUE），导出器才会写 VEC4。
`tools/bake_building_vertex_mask.py` 就是为这个坑写的补丁脚本；这次是**从源头**解决，不需要补丁。
校验办法：`tests/test_clan_volunteer_church.gd` 第 17 节会断言两档模型的 `a=1` 与 `a=0` 都存在。

⚠️ **重新导出前要记得两件事**（这次的 Blender 场景为了对比，把两个模型分别摆在 x = ∓0.85）：
1. 把 `lp_church_l1` / `lp_church_l2` 的 `location` 归零（GLB 的节点变换会带上物体位置）；
2. 把顶点色的 Alpha 重新接回 Principled 的 Alpha（否则又变回 VEC3）；
   出完图再摘掉，Blender 里的预览才不会是「只剩屋顶漂着」。

### 2.10 备战界面接入两个新派系

- **清单只有一份**：`LoadoutRes.FACTIONS = ["dynasty", "dynasty_volunteer", "empire_church", "empire"]`，
  `view/prepare_panel.gd` 直接读它（以前两处各抄一份，加派系必漏改一处）。
- **按钮布局**：右侧那一列**等高切分**（`LayoutRes.prepare_faction(w, h, index, count)`，默认 2 ⇒ 老行为不变）；
  字号按「槽高 / 字数」自适应，3 字短名在 4 个槽里仍保持 40px。
- **短名**：`clan.list[].short` + `cfg.clan_short_of()` —— 竖排按钮不能显示「王朝·义勇军」这种 6 字全名。
- **将领**：`unit.general.factions` 里通用 10 位勾上两个新派系，专属 4 位各归母派系的分支
  ⇒ 四页都是「通用 10 + 专属 2 = 12 位」。
- **详情卡**：`_find_recruit()` 改成按 `cfg.clan_ids()` 全查（原来写死三张表）。
- **将领仍按阶分小标题**（零 / 一 / 二 / 三阶）：这一版**没有**改它的排版。
  ★ 2026.11.18 备注：用户后来澄清「第一张牌隔得太远」说的是**局内手牌**、不是备战页
  （而且那条已经好了）；一度改成「平铺网格 + 阶角标」的版本**已回退**，
  iew/prepare_roster_list.gd 与 HEAD 逐位一致。


---

## 3. 怎么玩到它

1. **备战页**（主菜单 → 备战）右侧现在有**四枚**竖排按钮：王朝 / 义勇军 / 教会军 / 帝国。
   选哪一枚，右面板的「将领 / 单位 / 科技」三节就整体换成那一派的数据，左面板点磁贴看详情；
   合作模式带出去的出战配置也跟着这一份走。
2. **战役菜单** → 「东征·第一章」→ 找到 `测试·新派系（义勇军 vs 教会军）`（`ai_test_clan`）。
   双方都写 `ai: commander`：你在详情页选哪一方，那一方就归你手操，另一边交给指挥官 AI。
3. **无头测试**：`godot --headless --path dev_gd_a/daeem --script res://tests/test_clan_volunteer_church.gd`
   （300 项）与 `tests/test_prepare.gd`（326 项，含「切到新派系后三节真的有内容」）。
4. 想让某一关用新派系：在关卡 JSON 的 `factions[]` 里写 `"clan": "dynasty_volunteer"` / `"empire_church"`
   （战役编辑器的「③ 阵营」页也能选）。

★ 从备战页进**普通关卡**时，玩家席位的派系仍会被备战配置覆盖（关卡自己写的 `clan` 只决定 AI 那一方）——
这是原有规则，不是新 bug；想手操新派系请直接用上面的第 1 / 2 条。

---

## 4. 兼容性（原生 / 王朝 / 帝国为什么逐位不变）

| 新东西 | 缺省 | 对老派系的影响 |
|---|---|---|
| `Pathfinder` 的 `water` 参数 | `false` | 无（水域仍不可通行） |
| 区划 `production_mult` / `population_mult` | 缺键 = 1.0 | 无 |
| `z["plague"]` | 恒 false（没有教堂 / 传教） | 无 |
| `unit.status` 池 | 空 / 没有授予 | 无（`status_effects_merged([])` 全是 0） |
| `_try_fatal_survive` | `fatal_*` 全是 0 | 无（第一次判断就 false） |
| `_try_church` | 派系不在白名单 | 无（第一条就 return false） |
| 快照 `sts` / `bwa` | 空 / 0 | 无（老快照缺字段 ⇒ 保持现状） |
| `clan.short` | 缺键 = 空 = 用全名 | 无 |
| `prepare_faction(..., count)` | 默认 2 | 无（老调用还是上下各一半） |
| `BUILDING_MODELS["church"]` | 只有教会军能造 | 无（其它派系的建筑页没有这张牌） |

---

## 5. 已知缺口 / 后续

1. **新派系的单位 / 科技还没有 2D 图标**：备战页 / 命令卡的磁贴走「单字占位」（`label.substr(0,1)`），
   与「素材先用字代替图案」的口径一致。要补就跑 `tools/bake_unit_card_icon.py --commit`
   （先给新兵种配 `sprite`、给新科技补 `TECH_SHAPES` 条目），再把 `test_unit_card_icon` 的张数改掉。
2. **溺水不可达**：效果全在，但没有「剥夺水性」的机制（用户口径：只做数据预留）。
3. **AI 造教堂偏晚**：它排在升本 / 补兵 / 经济建筑之后（`_bare_general_count() > 0` 时不出手），
   实测在展示关里约 4 分钟后才出现。想更早，就把 `_try_church()` 在 `ai_build.update()` 里往前挪、
   或放宽那条「先补兵」闸门。
4. **数值全是占位**：没有做过一轮平衡（`dv_*` / `ec_*` 的 hp / damage / cost 都可能偏强或偏弱）。
5. **`test_upgrade` 有一条既存红灯**（「弃用科技后只剩等级那一份」）：那是「科技一次性」改动带来的旧断言
   （`set_tech_active(id, false)` 现在恒返回 false），与本次派系无关。

---

## 6. 改动清单

| 文件 | 改动 |
|---|---|
| `data/config.json` | `unit.status`（新）· `unit.types`+12 · `unit.types.*.status_ids/self_heal_per_sec/burst` · `clan.list`+2 · `tech.clan_list`+10 · `building.church` · `upgrade.levels.church` · `zone.plague_damage_per_sec` |
| `logic/config.gd` | 状态池与访问器 · `clan.buildings` 白名单 · `buildable_building_defs_for` · `building_clans/per_zone_limit/max_level_by_base/freedom_recruit/plague_*` · `unit_status_ids_of/self_heal/burst` |
| `logic/unit.gd` | 状态字段与效果 · `effective_armor` · `_try_fatal_survive` · `tick_status` · 多段齐射字段 · 水域移速 · 攻速科技 |
| `logic/world.gd` | 新效果键访问器 · `_refresh_zone_effects` / `_tick_plague` / `_tick_unit_statuses` · `statuses_for_unit` / `grant_recruit_statuses` / `church_level_in_zone` · `building_allowed_for_faction` / `zone_building_count` / `building_level_cap` · 收税 `_unit_tax_gold` · `_tech_hp_mult_for` 支持兵种大类 |
| `logic/zone.gd` | `production_of` / `update_population_multi` 读区划倍率 |
| `logic/pathfinder.gd` | 全部入口加可选 `water` |
| `logic/combat.gd` | 溺水禁手 · 状态攻击加成 · 沐浴自由 · `tick_burst` · 攻速科技 |
| `logic/tech.gd` | `default_effects()` 新增 20 个键 |
| `logic/upgrade.gd` | 等级上限改读 `world.building_level_cap(b)` |
| `logic/ai_build.gd` | `_try_church()` |
| `logic/snapshot.gd` | `sts` / `bwa` 两个快照字段 |
| `view/hud.gd` | 建筑页按派系过滤 · 状态 buff 槽 · 三条拒因文案 · 等级显示 |
| `view/building_view_3d.gd` | `BUILDING_MODELS["church"]` + `BUILDING_MODEL_LEVELS["church"]`（1/2 级） |
| `view/prepare_panel.gd` | 派系按钮读 `LoadoutRes.FACTIONS`（4 枚）· 短名 · 字号自适应 |
| `view/prepare_faction_button.gd` | `set_font_size()` |
| `view/prepare_detail_view.gd` | `_find_recruit()` 按 `clan_ids()` 全查 |
| `view/menu_deck_layout.gd` | `prepare_faction(w, h, index, count=2)` 等高切分 |
| `logic/loadout.gd` | `FACTIONS` +2（4 个派系） |
| `assets/models/church_l1_lowpoly.glb` / `church_l2_lowpoly.glb` | 新模型（Blender 现做，180 / 298 面） |
| `assets/ui/card_icon/building_church.png` | 新建筑图标（从 glb 抽边线烘的线稿） |
| `tools/bake_church_icon.py` | 一次性烘图脚本（只烘教堂那张） |
| `data/campaigns/demo/levels/ai_test_clan.json` | 新展示关 |
| `data/campaigns/demo/campaign.json` | 关卡表 +1 |
| `tests/test_clan_volunteer_church.gd` | 新增（300 项） |
| `tests/test_prepare.gd` | 四枚按钮 + 新派系三节内容（326 项） |
| `tests/test_loadout.gd` / `tests/test_unit_editor.gd` / `tests/test_unit_card_icon.gd` / `tests/test_ui.gd` | 派系归属 / 建筑数量 / 图标张数 / 空格子断言随数据同步 |
