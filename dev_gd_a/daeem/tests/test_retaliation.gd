## test_retaliation.gd —— 受击反击（2026.10.22）
##
## 需求：
##   · 单个单位被**其他单位**攻击时，立刻转为行军攻击那个敌方单位；
##   · 反击会**阻断程序下达的命令**（将领招募时的警戒 / 将领死亡时的警戒 / 巡逻…）；
##   · 反击**不会阻断玩家下达的命令**（玩家点的移动 / 攻击 / 行军攻击照旧执行）；
##   · 建筑（箭塔）打过来不触发；同阵营不触发。
##
## 这里同时钉住「反击结束后程序命令能恢复」（救援集结）与「开关关掉 = 旧行为」。
extends "res://tests/test_case.gd"

const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const BuildingRes = preload("res://logic/building.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_retaliation"
	_run()


func _run() -> void:
	var cfg = require_config()
	if cfg == null:
		quit(1)
		return
	var w = require_world(cfg)
	if w == null:
		quit(1)
		return
	_place_all_far(w)
	_test_program_order_broken(cfg, w)
	_test_player_move_not_broken(cfg, w)
	_test_player_attack_move_not_broken(cfg, w)
	_test_player_attack_not_broken(cfg, w)
	_test_only_hit_unit(cfg, w)
	_test_building_and_friendly(cfg, w)
	_test_recruit_guard_broken(cfg, w)
	_test_rescue_guard_broken_and_resumed(cfg, w)
	_test_switch(cfg, w)
	print("[CASE] %s -> 通过 %d 项，失败 %d 项" % [_case_name, _pass, _fail])
	if _fail > 0:
		for n in _failed_names:
			print("[CASE]   FAILED: %s" % n)
		quit(1)
	else:
		quit(0)


# ----------------------------------------------------------------------
# 1) 程序命令（行军攻击 / 巡逻）被反击打断
# ----------------------------------------------------------------------
func _test_program_order_broken(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_v", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(5, 5))
	var foe = _mk(w, cfg, "r_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(10, 5))
	victim.hp_max = 1000.0
	victim.hp = 1000.0
	# 程序命令：行军攻击去 (2,2)（驻防巡逻 / 救援用的就是这一条）
	ok(victim.order_attack_move(w, cfg, Vector2(2.5, 2.5)), "（前提）程序行军攻击命令被接受")
	ok(victim.has_attack_move, "（前提）现在在执行程序行军攻击")
	ok(not victim.player_order, "（前提）它不是玩家命令")

	var d0: float = victim.pos.distance_to(foe.pos)
	victim.take_damage(cfg, w, 10.0, foe)
	eq(victim.target, foe, "★★ 被打中 → 立刻锁定攻击者")
	eq(victim.retaliate_target, foe, "★★ 进入受击反击状态")
	ok(not victim.has_attack_move, "★★ 程序行军攻击被打断（has_attack_move = false）")
	ok(victim.is_retaliating(), "is_retaliating() 为真")

	CombatRes.tick_frame(w, cfg, victim, DT, -1)
	ok(not victim.path.is_empty() or victim.moving, "★★ 下一帧开始朝攻击者移动")
	var d1: float = victim.pos.distance_to(foe.pos)
	ok(d1 < d0, "★★ 距离在缩短（%.3f → %.3f）" % [d0, d1])


# ----------------------------------------------------------------------
# 2) 玩家移动 / 行军攻击 / 点名攻击：反击**不得**打断
# ----------------------------------------------------------------------
func _test_player_move_not_broken(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_mv", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(15, 5))
	var foe = _mk(w, cfg, "r_mv_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(20, 5))
	victim.hp_max = 1000.0
	victim.hp = 1000.0
	var ok_cmd: bool = CommandRes.apply_move(w, cfg, {
		"kind": "move", "ids": [victim.id], "x": 15.5, "y": 10.5, "faction": "p1"})
	ok(ok_cmd, "（前提）玩家移动命令被接受")
	ok(victim.has_active_player_order(), "（前提）玩家移动正在执行")

	var goal_x: float = victim.goal.x
	victim.take_damage(cfg, w, 10.0, foe)
	eq(victim.target, null, "★★ 玩家移动中挨打：不转为攻击（target 仍为空）")
	eq(victim.retaliate_target, null, "★★ 不进入反击")
	ok(victim.has_goal and victim.moving, "★★ 移动命令照旧执行")
	near(victim.goal.x, goal_x, 1e-6, "★ 目标点没有被改写")

	# 玩家命令走完之后（halt 模拟到达）⇒ 再挨打就该反击了
	victim.halt()
	ok(not victim.has_active_player_order(), "（前提）移动命令已经结束")
	victim.take_damage(cfg, w, 10.0, foe)
	eq(victim.retaliate_target, foe, "★ 命令完成后挨打 → 正常反击")

	# 反击途中玩家下新移动命令 ⇒ 玩家命令**覆盖**反击（不是被反击挡住）
	ok(CommandRes.apply_move(w, cfg, {
		"kind": "move", "ids": [victim.id], "x": 15.5, "y": 7.5, "faction": "p1"}),
		"★★ 反击中玩家仍能下新命令")
	eq(victim.retaliate_target, null, "★★ 玩家命令清掉了反击目标")
	eq(victim.target, null, "★★ 新移动命令也清掉了交战目标")
	ok(victim.has_active_player_order(), "★★ 现在是玩家命令在执行")


func _test_player_attack_move_not_broken(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_am", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(15, 8))
	var foe = _mk(w, cfg, "r_am_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(20, 8))
	victim.hp_max = 1000.0
	victim.hp = 1000.0
	ok(CommandRes.apply_attack_move(w, cfg, {
		"kind": "attack_move", "ids": [victim.id], "x": 15.5, "y": 12.5, "faction": "p1"}),
		"（前提）玩家行军攻击被接受")
	ok(victim.has_attack_move and victim.player_order, "（前提）玩家行军攻击正在执行")

	victim.take_damage(cfg, w, 10.0, foe)
	eq(victim.target, null, "★★ 玩家行军攻击中挨打：不转为攻击")
	ok(victim.has_attack_move, "★★ 行军攻击状态没被清掉（照旧边走边打）")
	eq(victim.retaliate_target, null, "★★ 不进入反击")


func _test_player_attack_not_broken(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_at", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(15, 11))
	var named = _mk(w, cfg, "r_at_t", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(17, 11))
	var other = _mk(w, cfg, "r_at_o", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(19, 11))
	victim.hp_max = 1000.0
	victim.hp = 1000.0
	ok(CommandRes.apply_attack(w, cfg, {
		"kind": "attack", "ids": [victim.id], "target_id": named.id, "faction": "p1"}),
		"（前提）玩家点名攻击被接受")
	eq(victim.ordered_target, named, "（前提）点名的目标 = named")

	victim.take_damage(cfg, w, 10.0, other)
	eq(victim.ordered_target, named, "★★ 被第三方打中：仍然打玩家点名的那个")
	eq(victim.target, named, "★★ 不转去打第三方")
	eq(victim.retaliate_target, null, "★★ 不进入反击")


# ----------------------------------------------------------------------
# 3) 只影响被打中的单个单位
# ----------------------------------------------------------------------
func _test_only_hit_unit(cfg, w) -> void:
	var leader = _mk(w, cfg, "r_l", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(20, 15))
	var mate = _mk(w, cfg, "r_l_m", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(21, 15),
		leader.id)
	var foe = _mk(w, cfg, "r_l_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(24, 15))
	mate.hp_max = 1000.0
	mate.hp = 1000.0
	mate.take_damage(cfg, w, 10.0, foe)
	eq(mate.retaliate_target, foe, "★ 被打中的那个兵反击")
	eq(leader.retaliate_target, null, "★★ 同队的其他人**不**跟着反击（单个单位）")
	eq(leader.target, null, "队长没有目标")


# ----------------------------------------------------------------------
# 4) 建筑 / 同阵营不触发
# ----------------------------------------------------------------------
func _test_building_and_friendly(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_b", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(25, 5))
	var friend = _mk(w, cfg, "r_b_f", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(26, 5))
	var tower = BuildingRes.create(cfg, "tower", 27, 5, "p2", -1)
	victim.hp_max = 1000.0
	victim.hp = 1000.0

	victim.take_damage(cfg, w, 10.0, tower, true)
	eq(victim.retaliate_target, null, "★★ 箭塔（建筑）打过来不触发反击")
	eq(victim.target, null, "目标仍为空")

	victim.take_damage(cfg, w, 10.0, friend)
	eq(victim.retaliate_target, null, "★★ 同阵营打过来不触发反击")
	ok(not victim.is_retaliating(), "is_retaliating() 仍为假")


# ----------------------------------------------------------------------
# 5) 将领招募时的「只警戒」被反击打断（且命令层仍然锁着）
# ----------------------------------------------------------------------
func _test_recruit_guard_broken(cfg, w) -> void:
	var leader = _mk(w, cfg, "r_rec", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(5, 15))
	var mate = _mk(w, cfg, "r_rec_m", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(6, 15),
		leader.id)
	var foe = _mk(w, cfg, "r_rec_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(9, 15))
	leader.train_kind = UnitRes.UNIT_TYPE_SPEARMAN
	leader.train_remaining = 10.0
	mate.hp_max = 1000.0
	mate.hp = 1000.0
	ok(w.is_order_locked(mate), "（前提）招募期间整个队伍被命令锁住")
	ok(not CommandRes.apply_move(w, cfg, {
		"kind": "move", "ids": [mate.id], "x": 5.5, "y": 18.5, "faction": "p1"}),
		"（前提）玩家命令被拒（只警戒）")

	mate.take_damage(cfg, w, 10.0, foe)
	eq(mate.retaliate_target, foe, "★★ 招募期的警戒被打断：附属兵转去反击")
	CombatRes.tick_frame(w, cfg, mate, DT, -1)
	ok(mate.is_retaliating() and (not mate.path.is_empty() or mate.moving),
		"★★ 它真的开始朝攻击者走（不是只挂个目标）")


# ----------------------------------------------------------------------
# 6) 将领倒下后的救援集结：被打断；反击结束后恢复
# ----------------------------------------------------------------------
func _test_rescue_guard_broken_and_resumed(cfg, w) -> void:
	var leader = _mk(w, cfg, "r_res", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(10, 15))
	var mate = _mk(w, cfg, "r_res_m", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(12, 15),
		leader.id)
	var foe = _mk(w, cfg, "r_res_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(16, 15))
	leader.hp = 1.0
	leader.enter_near_death(cfg.revive_regen_sec)
	w.rally_retinue_to_leader(leader)
	ok(mate.is_rescuing(), "（前提）附属兵处于救援集结状态")
	ok(mate.has_attack_move, "（前提）它正朝倒下的将领行军攻击")

	mate.take_damage(cfg, w, 10.0, foe)
	eq(mate.retaliate_target, foe, "★★ 救援集结被打断：转去打攻击者")
	ok(not mate.has_attack_move, "★★ 救援的行军攻击状态被清掉")

	# 反击目标还活着时，救援逻辑的「补一次集结令」不能把反击顶掉
	mate.halt()
	w.update_rescue_orders()
	eq(mate.target, foe, "★★ 救援重发**不能**覆盖还活着的反击目标")
	ok(not mate.has_attack_move, "反击期间不会被重新挂上行军攻击")

	# 攻击者没了 ⇒ 反击结束，救援重新下发
	foe.alive = false
	w.update_rescue_orders()
	ok(mate.has_attack_move, "★★ 反击结束 → 救援集结自动恢复")
	eq(mate.retaliate_target, null, "反击状态已清")


# ----------------------------------------------------------------------
# 7) 开关：关掉 = 旧行为
# ----------------------------------------------------------------------
func _test_switch(cfg, w) -> void:
	var victim = _mk(w, cfg, "r_sw", "p1", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(5, 20))
	var foe = _mk(w, cfg, "r_sw_f", "p2", UnitRes.UNIT_TYPE_SPEARMAN, Vector2i(9, 20))
	victim.hp_max = 1000.0
	victim.hp = 1000.0
	var old: bool = cfg.retaliation_enabled
	cfg.retaliation_enabled = false
	victim.take_damage(cfg, w, 10.0, foe)
	eq(victim.retaliate_target, null, "★★ 开关关掉 → 不反击（旧行为）")
	cfg.retaliation_enabled = old


# ----------------------------------------------------------------------
# 工具
# ----------------------------------------------------------------------
func _mk(w, cfg, id: String, faction: String, unit_type: String, tile: Vector2i,
		leader_id: String = ""):
	var u = UnitRes.create(cfg, id, "测", tile, faction, unit_type, "", leader_id,
		unit_type, -1)
	w.units.append(u)
	return u


## 把世界原有单位挪远，避免它们干扰「谁在打谁」的断言。
func _place_all_far(w) -> void:
	var i := 0
	for u in w.units:
		if not u.alive:
			continue
		u.pos = Vector2(float(maxi(1, w.map.cols - 6)) + float(i % 5),
			float(maxi(1, w.map.rows - 3)))
		u.sync_tile(w.map)
		i += 1
