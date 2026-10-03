## test_downed.gd —— ★★ 将领**濒死保护**（本轮新增，config.json 的 revive 段）
##
## 需求原文（逐条对照，这一份断言就是它的机器版）：
##   1.「被攻击血量降至 0 的将领进入濒死状态，若濒死状态的将领旗下部队全部死亡，
##      则该将领死亡，若否（仍存在部队），则该将领血量从 0 提升至 1，并持续缓慢回复，
##      每 3 秒回复 1% 血量，依此法回复的血量不会高于 20%（回复期间血量一定不会因
##      其他因素下降，只增不减；特殊地，回复期间若其旗下部队全部死亡，则该将领也立即死亡）」
##   2.「在将领濒死期间，该将领无法被选中为攻击对象且不会受到伤害（无论是行军攻击
##      还是指定攻击都不行）」
##   3.「拥有该将领的玩家可以选中该将领，若其血量回复至 10% 及以上，则其操作栏中
##      会出现『再起』按钮，点击后可消耗资源使其脱离濒死状态重新投入战斗」
##   4.「同样地，要为 ai 做将领濒死系统的新适配，ai 在将领濒死后可在符合条件时使用
##      资源让其再起，同时濒死的将领也会占用 ai 的将领槽位暂时阻止招募新将领，
##      直到该将领真正死亡」
## 手玩补充（用户拍板的四条，别按需求原文改回去）：
##   ·「无附属部队时**直接死亡**，不进濒死」；
##   ·「将领濒死后无法移动，视作倒在原地」⇒ 集结点是**固定的倒下点**；
##   ·「只要点击再起，就将这个将领视作是单位，读条期间暂停全灭判定」；
##   ·「再起时该将领血量是多少，再起后就是多少」。
##
## ⚠️ 这一份**用真的 tick / take_damage / 命令流**，不直接写字段（除了「故意把血量
##    打到 0」那一下）—— 濒死这套规则的价值就在于它跨了 unit / world / combat /
##    command_processor 四个文件，只调某一个函数是验不出来的。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const FactionRes = preload("res://logic/faction.gd")

## 一帧的秒数：与其它测试同一个口径，tick 的账才对得起来
const DT := 1.0 / 60.0
const MY := "p1"
# ⚠️ 不要在这里再声明 DEFAULT_MAP_PATH：父类 test_case.gd 已经有了
#    （重复声明会直接 Parse Error："already exists in parent class"，实测踩到）。


func _initialize() -> void:
	_case_name = "test_downed"
	run_all(_cases)
	cleanup_escort_scaffold()


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config_table(cfg)
	_test_downed_entry(cfg)
	_test_no_retinue_dies_at_once(cfg)
	_test_immune_and_unattackable(cfg)
	_test_no_attack_line_when_downed(cfg)
	_test_regen_rate_and_cap(cfg)
	_test_wipe_kills_downed(cfg)
	_test_rally_retinue(cfg)
	_test_revive_gate_and_cost(cfg)
	_test_revive_channel_and_cancel(cfg)
	_test_revive_keeps_hp(cfg)
	_test_recruit_queue_cleared(cfg)
	_test_tech_recalc(cfg)
	_test_snapshot_round_trip(cfg)
	_test_ai(cfg)


# ------------------------------------------------------------------
# 工具
# ------------------------------------------------------------------
func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold


## 把区划产能清零：要「对账」的用例必须调它，否则 tick 期间资源一直在涨。
func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}


## 把某个将领打到 0 血（走**真的** take_damage，所以濒死那套分支全都会执行）。
func _smash(cfg, w, g) -> void:
	g.take_damage(cfg, w, g.hp + 9999.0, null)


## ★★ 把濒死将领的血量顶到「上限的 ratio 那一档」——**必须三个字段一起写**。
##
## 为什么不能只写 `hp`：濒死状态机里血量有两个刻度 ——
##   · `hp`        给渲染 / HUD 读的当前血量；
##   · `nd_regen_hp` 回复记账（`tick_near_death` 在它之上加 1%），
##   · `nd_hp_ratio` 按比例对齐用的刻度（`world._apply_tech_effects` 与 `_finish_revive` 读它）。
## 只改 `hp` 会让记账落后，下一次回复虽然会被 `max(记账, hp)` 兜住（不会掉血），
## 但**多了 1% 的台阶**，于是「再起后血量 = 点再起时那个数」这条断言会假失败（实测）。
func _set_downed_hp(g, ratio: float) -> void:
	g.hp = g.hp_max * ratio
	g.nd_regen_hp = g.hp
	g.nd_hp_ratio = ratio


## 跑 n 秒（按 DT 一帧帧 tick），返回期间收集到的事件。
func _run_secs(w, secs: float) -> Array:
	var out: Array = []
	var frames := int(round(secs / DT))
	for _i in frames:
		out.append_array(w.tick(DT))
	return out


func _count_events(events: Array, type_name: String) -> int:
	var n := 0
	for e in events:
		if String(e.get("type", "")) == type_name:
			n += 1
	return n


## 给某个将领塞一个**额外的活兵**（测试自己要摆布「旗下还有没有部队」时用）。
## ★ 为什么需要它：地图开局自带的附属兵是固定那几位，而「全灭 / 不全灭」这类用例
##   需要精确控制「这一刻旗下有几个人」——自己造一个比去数地图更稳。
func _add_mate(cfg, w, leader) -> Variant:
	var m = UnitRes.create(cfg, "%s-testmate" % leader.id, "试验兵",
		Vector2i(leader.tx, leader.ty), leader.faction, leader.unit_type,
		"", String(leader.id), String(leader.unit_type), -1)
	m.hp_max = 1000.0
	m.base_hp_max = 1000.0
	m.hp = 1000.0
	w.units.append(m)
	return m


# ------------------------------------------------------------------
# 一、数值表来自 config.json（代码里不写字面量）
# ------------------------------------------------------------------
func _test_config_table(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	# ★ 用户拍板的造价：粮食 200 / 黄金 200（可调），读条 5 秒。
	var cost: Dictionary = w.revive_cost()
	near(float(cost.get("food", 0.0)), 200.0, 1e-6, "★ 再起消耗 200 粮食（config.revive.cost）")
	near(float(cost.get("gold", 0.0)), 200.0, 1e-6, "★ 再起消耗 200 黄金")
	near(w.revive_channel_sec(), 5.0, 1e-6, "★ 再起读条 5 秒")
	near(w.revive_ready_ratio(), 0.1, 1e-6, "★ 血量到 10% 才允许再起")
	near(cfg.revive_regen_sec, 3.0, 1e-6, "★ 每 3 秒回复一次")
	near(cfg.revive_regen_ratio, 0.01, 1e-6, "★ 每次回复 1% 血量上限")
	near(cfg.revive_regen_cap_ratio, 0.2, 1e-6, "★ 回复天花板 = 20% 血量上限")


# ------------------------------------------------------------------
# 二、进入濒死：0 血 → 1 点血、钉在原地、不再是「活着能打」的单位
# ------------------------------------------------------------------
func _test_downed_entry(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	ok(g != null, "（前提）有 general-1")
	if g == null:
		return
	ok(g.is_general(), "（前提）它确实是将领类单位")
	ok(not w.retinue_of(g.id, true).is_empty(), "（前提）它开局带着附属兵")

	# 先把它的位置挪到地图中间，再用一条真实的移动命令让它「在路上」——
	# 这样才验得出「进濒死会清掉现有命令、就地倒下」。
	var tile := Vector2i(g.tx, g.ty)
	var dest := GridRes.center_of(Vector2i(tile.x + 3, tile.y))
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [g.id],
		"x": dest.x, "y": dest.y, "faction": MY}), "先给将领下一条移动命令")
	ok(g.moving, "（前提）它确实在走")

	var before_pos: Vector2 = g.pos
	_smash(cfg, w, g)

	ok(g.alive, "★ 将领没有直接死（它旗下还有部队）")
	ok(g.is_downed(), "★★ 它进入了濒死状态")
	near(g.hp, 1.0, 1e-6, "★ 血量从 0 提升至 1（需求原文）")
	ok(not g.moving and g.path.is_empty(), "★ 倒在原地：移动命令被清掉")
	ok(g.target == null and g.target_building == null, "★ 交战目标也清掉了")
	v2_near(g.pos, before_pos, 1e-6, "★ 位置没有变（就地倒下）")
	v2_near(g.downed_anchor, before_pos, 1e-6, "★ 倒下点 = 它站着的那一点（集结点用它）")
	eq(g.deaths, 0, "★ 濒死不记一次阵亡（它不是死了）")
	ok(w.is_order_locked(g), "★ 濒死的将领不接受指令")
	eq(w.order_lock_reason(g), "downed", "★ 拒因码是 downed（界面据此说「倒地」而不是「招募中」）")
	ok(g.is_attackable() == false, "★★ 它不再是可以被打的目标")


# ------------------------------------------------------------------
# 三、用户拍板：无附属部队时**直接死亡**，不进濒死
# ------------------------------------------------------------------
func _test_no_retinue_dies_at_once(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	ok(g != null, "（前提）有 general-3")
	if g == null:
		return
	# 先把它旗下的兵**真的打死**（走 take_damage，不是从数组里删）——
	# 然后 tick 一帧让世界把尸体清掉，于是「旗下没有活兵」这件事成立。
	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	w.tick(DT)
	ok(w.retinue_of(g.id, true).is_empty(), "（前提）它旗下已经一个活兵都没有")

	_smash(cfg, w, g)
	ok(not g.alive, "★★ 无附属部队时直接死亡（用户拍板）")
	ok(not g.is_downed(), "★ 而且**没有**进入濒死")
	eq(g.deaths, 1, "★ 记了一次阵亡")
	ok(not w.has_living_retinue(g), "（旁证）has_living_retinue 对它返回 false")


# ------------------------------------------------------------------
# 四、免疫伤害 + 不能被选为攻击目标（自动索敌 / 指定攻击 / 箭塔都算）
# ------------------------------------------------------------------
func _test_immune_and_unattackable(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	var hp_before: float = g.hp

	# ---- ① 直接挨打：一点血都不掉 ----
	g.take_damage(cfg, w, 9999.0, null)
	near(g.hp, hp_before, 1e-6, "★★ 濒死期间不会受到任何伤害")
	ok(g.alive and g.is_downed(), "★ 挨了 9999 伤害还倒着（濒死 = 无敌）")

	# ---- ② 跑到它旁边的敌人**不会**锁定它 ----
	#     把敌人摆在它正旁边（0 格），并在它脚下画一个可攻击的建筑当对照。
	var foe = w.spawn_enemy(g.tx + 1, g.ty)
	ok(foe != null, "刷出一个测试敌人")
	if foe != null:
		foe.hold_position = true
		foe.drop_engagement()
		var got: bool = CombatAcquire(w, cfg, foe)
		ok(not got or foe.target != g, "★★ 自动索敌不会把濒死的将领当成目标")
		# 而且它**不能**被玩家指定为攻击目标
		var attacker = w.unit_by_id("general-2")
		var ok_order: bool = attacker.order_attack_unit(w, cfg, g)
		ok(not ok_order, "★★ 指定攻击（右键点它）也被拒绝")
		ok(attacker.ordered_target == null, "★ 被拒之后没有留下 ordered_target")

	# ---- ③ 建筑（箭塔）也不打它 ----
	#     ★ 判据就在 `combat.update_towers` 的 `u.is_attackable()` 那一句上。
	#       塔的 owner 取一个**敌对**阵营，摆在它旁边，跑一秒看它掉不掉血。
	#     ⚠️ 基线要在**这一段开跑之前**重新取：上面的自动索敌那一段自己也在跑世界
	#        （濒死回复每 3 秒加 1% 血），拿进入本节时那个 hp 当基线会假失败。
	var hp_tower0: float = g.hp
	var tw = w.add_building("tower", g.tx + 1, g.ty + 1, FactionRes.NPC_FACTION, true, true)
	ok(tw != null, "（前提）在它旁边立起一座敌方箭塔")
	if tw != null:
		_run_secs(w, 2.0)
		# ★ 2 秒内最多发生 0~1 次**规则内**的自动回复（1% 上限），所以容差给足 1%；
		#   塔那一发伤害是 40，真打中的话会掉得远远超过这个数（而且会把它打死）。
		near(g.hp, hp_tower0, g.hp_max * cfg.revive_regen_ratio + 1e-6,
			"★★ 箭塔也不会伤害濒死的将领")
		ok(g.alive and g.is_downed(), "★ 挨了这一会儿它仍然倒着（没被塔打死）")


## 让一个单位跑一次真实的自动索敌（走 combat 的公开静态函数）。
## ★ 之所以包一层：`CombatRes` 与 `UnitRes` 互相 preload 会形成循环依赖，
##   所以测试文件里也只用局部 preload 的常量（见 test_case.gd 的引用约定）。
func CombatAcquire(w, cfg, u) -> bool:
	var cls: GDScript = load("res://logic/combat.gd")
	if cls == null:
		return false
	return cls.acquire_target(w, cfg, u, -1)


# ------------------------------------------------------------------
# 四之二、★★ 濒死不该留下「攻击特效连线」（本轮修的 bug）
#
# 玩家实测报回来的现象：「进入濒死的敌方将领有概率一直和我的某个单位连线（触发攻击特效）」。
# 根因：攻击线渲染读的是 `attack_flash` + `last_target`，而濒死的将领整段单位逻辑
#   （`combat.update_unit`）都被跳过 ⇒ 那个 1.0 永不衰减，`last_target` 也一直指着对方。
#   （`_die()` 走的是 `stop()` → `clear_target()`，那条路本来就没问题 ——
#     漏的只是「进濒死」这一条新路，正是本轮新增的分支。）
# 修法两条：`enter_near_death()` 当场灭掉特效与残留目标；`tick_near_death()` 里也每帧衰减。
# ------------------------------------------------------------------
func _test_no_attack_line_when_downed(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var foe = w.spawn_enemy(g.tx + 1, g.ty)
	ok(foe != null, "（前提）刷出一个贴脸的敌人")
	if foe == null:
		return
	foe.hold_position = true

	# ---- 先让将领真的开一火：这样它身上带着 flash=1.0 与 last_target ----
	g.drop_engagement()
	g.target = foe
	g.attack_cd = 0.0
	CombatUpdate(w, cfg, g)                  # 贴脸 ⇒ 这一帧就会开火
	ok(g.last_target == foe, "（前提）它刚刚开过火（last_target 指着敌人）")
	near(g.attack_flash, 1.0, 1e-6, "（前提）开火特效亮着（attack_flash = 1）")

	# ---- 打到 0 血 → 进濒死 ----
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它进了濒死")

	# ① 进濒死那一帧就必须灭掉：否则画面上立刻就是一条永久连线
	near(g.attack_flash, 0.0, 1e-6, "★★ 进濒死时开火特效当场清零（不会留下连线）")
	ok(g.last_target == null, "★★ 残留的 last_target 也清掉（渲染那两个字段它都读）")
	ok(g.last_building == null, "★ last_building 一起清")

	# ② 假装它倒下那一刻特效还没灭（例如以后有人改了 `enter_near_death`）：
	#    `tick_near_death` 必须**每帧衰减**它 —— 濒死期间没有任何别的代码会碰这个字段。
	g.attack_flash = 1.0
	g.last_target = foe
	var secs: float = cfg.flash_sec_safe * 1.5
	_run_secs(w, secs)
	near(g.attack_flash, 0.0, 1e-6,
		"★★ 濒死期间开火特效也会自己衰减（%.2f 秒后归零）" % secs)

	# ③ 反证：一个**活着的**单位在同样的时间里也必须归零（同一条衰减口径）
	var g2 = w.unit_by_id("general-2")
	g2.attack_flash = 1.0
	_run_secs(w, secs)
	near(g2.attack_flash, 0.0, 1e-6, "★ 活着单位的特效同样归零（口径一致）")


## 跑一次 `combat.update_combat`（同上：局部 load，避免循环 preload）。
func CombatUpdate(w, cfg, u) -> void:
	var cls: GDScript = load("res://logic/combat.gd")
	if cls == null:
		return
	cls.update_combat(w, cfg, u)


# ------------------------------------------------------------------
# 五、回复：每 3 秒 +1% 上限、总量封顶 20%、只增不减
# ------------------------------------------------------------------
func _test_regen_rate_and_cap(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")

	var step: float = g.hp_max * cfg.revive_regen_ratio      # 每 3 秒该加多少（= 上限的 1%）
	near(g.hp, 1.0, 1e-6, "（起点）1 点血")

	# ---- 第一次回复发生在**一个完整周期之后**（需求：每 3 秒回复 1%）----
	_run_secs(w, 2.0)
	near(g.hp, 1.0, 1e-6, "★ 2 秒时还没回（周期是 3 秒）")
	_run_secs(w, 1.5)
	near(g.hp, 1.0 + step, 0.05, "★★ 3 秒后回复了 1% 上限")

	# ---- 再跑一段：每次都只涨不跌 ----
	var prev: float = g.hp
	var dropped := false
	for _i in 40:
		_run_secs(w, 0.5)
		if g.hp < prev - 1e-9:
			dropped = true
		prev = g.hp
	ok(not dropped, "★★ 回复期间血量只增不减")

	# ---- 跑很久：封顶在 20% ----
	_run_secs(w, 120.0)
	var cap: float = g.hp_max * cfg.revive_regen_cap_ratio
	near(g.hp, cap, 1e-3, "★★ 回复量封顶在 20% 血量上限")
	ok(g.hp <= cap + 1e-6, "★ 永远不会高于 20%")
	ok(g.is_downed(), "★★ 回到 20% 之后**仍然是濒死**（必须点再起才真正解除）")
	ok(g.revive_ready(cfg), "★ 20% ≥ 10%，所以「再起」现在可点")
	near(g.nd_regen_progress(cfg), 1.0, 1e-6, "★ 回复进度条满了")


# ------------------------------------------------------------------
# 六、旗下部队全灭 → 濒死的将领立即死亡
# ------------------------------------------------------------------
func _test_wipe_kills_downed(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-2")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	ok(g.alive, "（前提）它还活着")

	# 把它旗下的兵全部打死（走真实伤害），再 tick 一帧 —— 判定发生在这一帧的
	# `unit.tick_near_death` 里。
	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	var evts: Array = w.tick(DT)
	ok(not g.alive, "★★ 濒死期间旗下部队全灭 ⇒ 将领立即死亡")
	ok(not g.is_downed(), "★ 死亡时濒死状态被清掉（不留幽灵）")
	eq(g.deaths, 1, "★ 记了一次阵亡")
	# ⚠️ kill 事件的总数不写死：同一帧里「它旗下的兵被杀」也各发一条，
	#   条数取决于地图给这位将领配了几个兵。要钉的是「它自己那一条在里面」。
	ok(_count_events(evts, "kill") >= 1, "★ 发了 kill 事件（其中一条是它自己）")
	eq(_count_events(evts, "leader_lost"), 1, "★ 另发一条 leader_lost（带 reason）")


# ------------------------------------------------------------------
# 七、进入濒死时，旗下部队解除命令并向**倒下点**行军攻击
# ------------------------------------------------------------------
func _test_rally_retinue(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var mates: Array = w.retinue_of(g.id, true)
	ok(not mates.is_empty(), "（前提）它有附属兵")

	# 先把整队派到很远的地方（并确认它们真的在赶路）
	var far := GridRes.center_of(Vector2i(
		clampi(g.tx + 8, 0, w.map.cols - 1), clampi(g.ty + 6, 0, w.map.rows - 1)))
	var ids: Array = [g.id]
	for m in mates:
		ids.append(m.id)
	CommandRes.apply(w, cfg, {"kind": "move", "ids": ids, "x": far.x, "y": far.y, "faction": MY})
	var moved := false
	for m in mates:
		if m.moving:
			moved = true
	ok(moved, "（前提）至少有一个附属兵在赶路")

	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）将领已经倒下")

	# ★ 断言：每一个活着的附属兵都变成了「往倒下点行军攻击」
	var anchor: Vector2 = g.downed_anchor
	var rallied := 0
	for m in mates:
		if m.has_attack_move and m.attack_move_goal.distance_to(anchor) < 0.01:
			rallied += 1
	ok(rallied > 0, "★★ 附属兵解除旧命令、改成行军攻击到**倒下点**（%d 个）" % rallied)
	ok(rallied == mates.size(), "★ 全部附属兵都收到了这条集结令")
	for m in mates:
		ok(m.ordered_target == null, "★ 旧的点名目标也被清掉了（「解除所有命令」）")


# ------------------------------------------------------------------
# 八、再起的门槛、扣费与拒因
# ------------------------------------------------------------------
func _test_revive_gate_and_cost(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")

	# ---- ① 血量不到 10%：拒因 "hp"（界面上那颗格子就是灰的）----
	ok(not g.revive_ready(cfg), "★ 刚倒下时（1 点血）还没到 10%，不能再起")
	eq(w.revive_reject_reason(g, MY), "hp", "★ 拒因码 = hp")
	ok(not w.start_revive(g.id, MY), "★ 这时再起被拒")
	near(w.resources["food"], 1000.0, 1e-6, "★ 被拒时**一分钱都不扣**")

	# ---- ② 把血量顶到 10%：可以了 ----
	_set_downed_hp(g, 0.1)
	ok(g.revive_ready(cfg), "★ 血量到 10% ⟹ 允许再起")
	eq(w.revive_reject_reason(g, MY), "", "★ 拒因码为空")

	# ---- ③ 钱不够：拒因 "cost" ----
	_give(w, 10.0, 1000.0)
	eq(w.revive_reject_reason(g, MY), "cost", "★ 粮食不够的拒因码 = cost")
	ok(not w.start_revive(g.id, MY), "★ 钱不够时再起被拒")
	ok(not g.is_reviving(), "★ 而且没有开始读条")

	# ---- ④ 钱够了：入队即扣（与招募同一套）----
	_give(w, 500.0, 500.0)
	ok(w.start_revive(g.id, MY), "★★ 钱够了就能再起")
	near(w.resources["food"], 300.0, 1e-6, "★★ 再起**立刻**扣掉 200 粮食")
	near(w.resources["gold"], 300.0, 1e-6, "★★ 立刻扣掉 200 黄金")
	ok(g.is_reviving(), "★ 进入了读条状态")
	near(g.revive_total, w.revive_channel_sec(), 1e-6, "★ 读条总时长 = config 的 5 秒")

	# ---- ⑤ 读条期间再点一次 = 拒因 "channeling"（界面换成「取消再起」那一格）----
	eq(w.revive_reject_reason(g, MY), "channeling", "★ 读条中不能再下一单")
	ok(not w.start_revive(g.id, MY), "★ 重复下单被拒")
	near(w.resources["food"], 300.0, 1e-6, "★ 重复下单没有再扣钱")

	# ---- ⑥ 防冒充：别人家的阵营下不了这个命令 ----
	eq(w.revive_reject_reason(g, "p2"), "faction", "★ 别的阵营不能替它再起")


# ------------------------------------------------------------------
# 九、读条：暂停全灭判定、取消全额退款、读完脱离濒死
# ------------------------------------------------------------------
func _test_revive_channel_and_cancel(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.1)
	ok(w.start_revive(g.id, MY), "（前提）再起入队")
	ok(g.is_reviving(), "（前提）它在读条")

	# ---- ① ★★ 读条期间暂停全灭判定（用户拍板：「点击再起就把该将领视作单位」）----
	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	_run_secs(w, 0.5)
	ok(g.alive and g.is_downed(), "★★ 读条期间手下兵全死光，将领**没有**当场死亡")
	ok(g.is_reviving(), "★ 读条没有被打断")

	# ---- ② 读条推进 ----
	_run_secs(w, 2.0)
	ok(g.is_reviving(), "★ 2 秒时还在读条")
	ok(g.revive_progress() > 0.3 and g.revive_progress() < 0.7,
		"★ 读条进度与秒数对得上（约 40%%~60%%，实测 %.2f）" % g.revive_progress())

	# ---- ③ 取消：全额退款、回到「只是濒死」 ----
	near(w.resources["food"], 800.0, 1e-6, "（对账）此刻只扣了那 200")
	ok(w.cancel_revive(g.id, MY), "★ 取消读条成功")
	ok(not g.is_reviving(), "★ 不再是读条状态")
	near(w.resources["food"], 1000.0, 1e-6, "★★ 取消**全额退还** 200 粮食")
	near(w.resources["gold"], 1000.0, 1e-6, "★★ 黄金也全额退还")
	ok(g.is_downed(), "★ 它仍然是濒死的（取消 ≠ 死亡，也 ≠ 复活）")
	ok(not w.cancel_revive(g.id, MY), "★ 没在读条时再取消：返回 false（不重复退钱）")
	near(w.resources["food"], 1000.0, 1e-6, "★ 没有凭空多出资源")

	# ---- ④ 再下一次，跑完 5 秒：脱离濒死 ----
	ok(w.start_revive(g.id, MY), "再下一单")
	ok(g.is_reviving(), "（前提）它在读条")
	# ★★ 读条期间**全灭判定是暂停的**（用户拍板：「点击再起就把该将领视作单位」）——
	#    所以哪怕它旗下**一个兵都没有**，这 5 秒也不会把它判死。
	#    这正是本节要验的那条：下面这一段**故意不补兵**，直接跑完读条。
	var evts: Array = _run_secs(w, 6.0)
	ok(not g.is_downed(), "★★ 一个兵都没有也读完了（读条期间暂停全灭判定）")
	ok(g.alive, "★ 它还活着")
	ok(g.is_attackable(), "★★ 重新成为可被攻击 / 可被锁定的单位")
	ok(not w.is_order_locked(g), "★ 重新接受指令")
	ok(_count_events(evts, "leader_revived") >= 1, "★ 发了一条 leader_revived 事件")


# ------------------------------------------------------------------
# 十、用户拍板：「再起时血量是多少，再起后就是多少」
# ------------------------------------------------------------------
func _test_revive_keeps_hp(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-2")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.15)
	# ⚠️ 补一个自己的活兵：地图上真的有敌人，它开局的兵可能在这 5 秒里被打光，
	#    那时它会因为「全灭判定」当场阵亡（规则如此），而本节只验补血那一件事。
	_add_mate(cfg, w, g)
	var hp_at_click: float = g.hp
	ok(w.start_revive(g.id, MY), "（前提）再起入队")
	ok(w.has_living_retinue(g), "（前提）读条开始时它旗下确实有活兵")
	var mate_n0: int = w.retinue_of(g.id, true).size()
	_run_secs(w, 6.0)
	ok(g.alive, "（前提）它还活着（没有全灭）· 读条前后附属兵 %d → %d" % [
		mate_n0, w.retinue_of(g.id, true).size()])
	ok(not g.is_downed(), "（前提）已经脱离濒死")
	# ★★ 容差**必须**把「站起来之后己方领地回血 4/秒」算进去（见 combat.update_unit
	#    那一条），否则这条断言验的是别的东西 —— 实测：6 秒的窗口里前 5 秒是读条、
	#    最后 1 秒它已经站在自己地盘上回血，血量会从 17.6 涨到 21.5。
	#    真正要钉的是：「再起**不会**把血量重置成满血 / 1 点」（用户拍板的那条口径）。
	var post_secs: float = 6.0 - cfg.revive_channel_sec
	var tol: float = g.hp_max * cfg.revive_regen_ratio * 2.0 + 4.0 * post_secs + 0.5
	near(g.hp, hp_at_click, tol,
		"★★ 再起后血量 = 点再起时的血量（外加读条期间的自动回复与站起来之后的领地回血）")
	ok(g.hp < g.hp_max - 1e-6, "★★ 再起**不是**满血复活（血量就是点下去时那个数）")
	ok(g.hp > 1.0 + 1e-6, "★★ 也不是被打回 1 点")
	ok(g.combat_damage(cfg) > 0.0, "★ 它能重新投入战斗（攻击数值照旧）")


# ------------------------------------------------------------------
# 十之二、★★ 正在招募的将领被打进濒死 ⇒ 招募队列当作战废并全额退款
#
# 实测报回来的现象：「我看到一个濒死的将领没有任何单位，最后还是招募了一个单位出来，
#   我把这个单位打死之后这个将领才死」。
# 根因：`_tick_recruitment` 只看 `alive`，而濒死者**仍然 alive** ⇒ 读条照走、兵照出，
#   而那个兵又算「旗下有部队」⇒ 全灭判定永远不成立，将领靠「一直在造兵」续命。
# 修法：进濒死时 `_release_recruit(leader, true, "leader_downed")`（作废 + 全额退款），
#   并在 `_tick_recruitment` 里补一道 `is_downed()` 的保险。
# ------------------------------------------------------------------
func _test_recruit_queue_cleared(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g.tx, g.ty)
	z["population"] = 10.0
	_no_income(w)                            # 对账：别让区划产出掺进来

	# ---- 排一单（入队即扣 50 粮 / 50 金 / 1 人口）----
	var kind := "spearman"
	ok(w.start_recruit(kind, g.id, "p1"), "（前提）将领开始招募")
	ok(g.train_queue_size() > 0, "（前提）它确实在读条")
	near(float(w.resources["food"]), 950.0, 1e-4, "（前提）已经扣了 50 粮食")
	near(float(z["population"]), 9.0, 1e-4, "（前提）已经扣了 1 人口")

	# ---- 把它打进濒死 ----
	_smash(cfg, w, g)
	ok(g.is_downed(), "★★ 它进了濒死")
	eq(g.train_queue_size(), 0, "★★★ 招募队列**整个作废**（不留任何一单）")
	near(float(w.resources["food"]), 1000.0, 1e-4, "★★ 已扣的粮食**全额退还**")
	near(float(w.resources["gold"]), 1000.0, 1e-4, "★★ 黄金也全额退还")
	near(float(z["population"]), 10.0, 1e-4, "★★ 人口也退回去了")
	eq(w.can_recruit(kind, g.id, MY), "downed",
		"★★ 濒死期间不能再下单（拒因码 downed）")

	# ---- 等足够久：**一个兵都不该冒出来** ----
	var n0: int = w.retinue_of(g.id, true).size()
	var evts: Array = _run_secs(w, 12.0)     # 招募读条只要 10 秒
	eq(w.retinue_of(g.id, true).size(), n0, "★★★ 等了 12 秒也没有新兵冒出来（原来会出一个）")
	ok(g.alive and g.is_downed(), "★ 它还是倒着（没有因为『又造了个兵』续命，但也没死）")

	# ---- 它的部队被打光 ⇒ 立即死亡（这条判据现在真的生效了）----
	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	_run_secs(w, 0.2)
	ok(not g.alive, "★★★ 打光它旗下部队之后它当场死亡（不再被招募队列吊着）")
	ok(_count_events(evts, "leader_downed") >= 1, "★ 期间发过 leader_downed 事件")


# ------------------------------------------------------------------
# 十一、科技改血量上限：濒死期间只改上限、不动当前血量（守住「只增不减」），
#       站起来那一刻再按比例对齐。
# ------------------------------------------------------------------
func _test_tech_recalc(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	# 手动顶到「上限的 15%」（回复到 20% 之前的一个中间档）
	_set_downed_hp(g, 0.15)
	var hp_before: float = g.hp
	var hp_max_before: float = g.hp_max

	# 施加一个将领血量科技倍率（世界走的就是这个入口）
	g.apply_hp_bonus(1.5)
	ok(g.hp_max > hp_max_before, "★ 血量上限确实涨了")
	# ★★ 这一条是实测抓到的真 bug：`world._apply_tech_effects()` 会遍历所有单位调
	#    `apply_hp_bonus`，而它算的是「按比例缩放当前血量」——对濒死者来说那等于把
	#    回复出来的血**覆盖掉**（实测 16.5 → 2.1，正是需求禁止的「血量下降」）。
	near(g.hp, hp_before, 1e-6, "★★ 濒死期间科技改上限**不许动当前血量**（只增不减）")
	near(g.nd_regen_hp, hp_before, 1e-6, "★ 回复记账也没被覆盖")

	# 站起来那一刻才按比例对齐（上限涨了、占比不变）
	g.nd_hp_ratio = 0.15
	g.start_revive(cfg)
	g.revive_remaining = 1e-6              # 直接把读条走完（不改配置）
	w.tick(DT)
	ok(not g.is_downed(), "（前提）已经站起来")
	near(g.hp / g.hp_max, 0.15, 1e-6, "★★ 站起来那一刻按比例对齐（占上限的 15%）")

	# 弃用之后回到 1.0：上限回落到基础值，当前血量不会超过上限
	var hp_max_now: float = g.hp_max
	g.apply_hp_bonus(1.0)
	ok(g.hp_max < hp_max_now, "★ 弃用科技后上限回落到基础值")
	ok(g.hp <= g.hp_max + 1e-6, "★ 当前血量不会超过上限")


# ------------------------------------------------------------------
# 十二、快照：濒死状态是权威状态，必须能往返
# ------------------------------------------------------------------
func _test_snapshot_round_trip(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.12)
	g.nd_regen_hp = g.hp
	ok(w.start_revive(g.id, MY), "（前提）它正在读条再起")

	var snap: Dictionary = SnapshotRes.to_snapshot(w)
	# 造一个新世界，把快照盖上去
	var w2 = require_world(cfg)
	SnapshotRes.apply_snapshot(w2, cfg, snap)
	var g2 = w2.unit_by_id(g.id)
	ok(g2 != null, "（前提）新世界里也有这个将领")
	if g2 == null:
		return
	ok(g2.downed, "★★ 快照往返后仍然是濒死状态")
	ok(g2.is_reviving(), "★★ 再起读条也一起过来了")
	near(g2.revive_remaining, g.revive_remaining, 0.05, "★ 读条剩余秒数对得上")
	near(g2.hp, g.hp, 1.0, "★ 血量对得上")
	ok(not g2.is_attackable(), "★★ 客机侧它也**不是**可攻击目标（否则两边会打架）")
	ok(w2.is_order_locked(g2), "★ 客机侧它同样不接受指令")

	# ★ 老快照（没有 nd 字段）必须**保持本地现状**，不能把濒死状态静默清掉
	var legacy: Dictionary = { "units": [{ "i": g.id, "h": int(round(g.hp)) }] }
	SnapshotRes.apply_snapshot(w2, cfg, legacy)
	ok(g2.downed, "★ 缺 nd 字段的老快照不会把濒死状态清掉（缺字段 = 保持现状）")


# ------------------------------------------------------------------
# 十三、AI：占槽位 + 符合条件时自己再起
# ------------------------------------------------------------------
func _test_ai(cfg) -> void:
	var cls := script_at("res://logic/world.gd")
	if cls == null:
		return
	# ★ 这一节必须用**带 AI 的世界**（`with_ai = true`），否则 ai_factions 是空的。
	var w = cls.create(cfg, DEFAULT_MAP_PATH, true)
	ok(w != null, "（前提）带 AI 的世界能建出来")
	if w == null:
		return
	ok(not w.ai_factions.is_empty(), "（前提）这一局确实有阵营 AI")

	var ai_f: String = String((w.ai_factions[0] as Dictionary)["faction"])
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == ai_f and u.is_general():
			g = u
			break
	ok(g != null, "（前提）AI 那一边有将领")
	if g == null:
		return

	# 给它一个**自己的活兵**，这样「濒死时旗下还有部队」这条前提不受地图摆布。
	_add_mate(cfg, w, g)
	_give(w, 0.0, 0.0)
	# ★ 先把玩家的钱清空（w.resources 是玩家池），AI 的钱在它自己的池子里。
	_smash(cfg, w, g)
	ok(g.is_downed(), "★★ AI 的将领也会进入濒死（同一套规则）")
	ok(g.alive, "★ 它仍然是 alive —— 因此照旧占着将领槽位")

	# ---- ① 占槽位：AI 的将领名单里仍然有它（= 不会去补招一位新的）----
	var listed := 0
	for u in w.units:
		if u.alive and String(u.faction) == ai_f and u.is_general():
			listed += 1
	var found := false
	for u in w.units:
		if u == g:
			found = true
	ok(found and listed > 0, "★★ 濒死的将领仍在世界单位表里、仍被算作这一方的将领（占槽位）")

	# ---- ② 血量不到 10%：AI 不会下单（会白花钱）----
	# ★★ 必须先把**所有**区划的产能清零：AI 的钱是「占领区划的产能」每帧加进去的
	#    （见 faction_ai._income），不清的话下面那条「扣了多少」的断言会被收入淹没。
	_no_income(w)
	var pool: Dictionary = w.resource_pool_for(ai_f)
	pool["food"] = 2000.0
	pool["gold"] = 2000.0
	var evts_early: Array = w.tick(DT)
	ok(not g.is_reviving(), "★★ 血量不到 10% 时 AI 不会再起（与玩家同一个门槛）")
	ok(_count_events(evts_early, "revive_started") == 0, "★ 这一帧没有下再起单")
	# ⚠️ 这里**不**断言「AI 的钱一动没动」：AI 同时也在干别的事（招兵 / 升级），
	#    那是它的正常经营，与本节无关。要钉的是「它没有下这一单」。

	# ---- ③ 顶到 10%：AI 在下一帧自己花资源再起 ----
	_set_downed_hp(g, w.revive_ready_ratio())
	var food_before: float = float(pool["food"])
	var evts: Array = w.tick(DT)
	ok(g.is_reviving(), "★★★ AI 在符合条件时自己花了资源让将领再起")
	near(float(pool["food"]), food_before - float(w.revive_cost().get("food", 0.0)), 1e-3,
		"★★ AI 花的是**它自己池子**里的钱（不是玩家的）")
	near(w.resources["food"], 0.0, 1e-6, "★★ 玩家的钱一分没动")
	ok(_count_events(evts, "revive_started") >= 1, "★ 发了一条 revive_started")

	# ---- ④ 跑完读条：AI 的将领重新可用 ----
	_run_secs(w, 6.0)
	ok(not g.is_downed(), "★★ AI 的将领读条结束后脱离濒死")
	ok(g.is_attackable(), "★ 它重新成为可攻击目标")
