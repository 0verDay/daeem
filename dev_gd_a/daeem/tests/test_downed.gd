## test_downed.gd —— ★★ 将领**濒死保护**（本轮新增，config.json 的 revive 段）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const SnapshotRes = preload("res://logic/snapshot.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0
const MY := "p1"

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
	_test_rescue_lock(cfg)
	_test_rescue_lock_released_on_revive(cfg)
	_test_revive_gate_no_cost(cfg)
	_test_revive_channel_and_cancel(cfg)
	_test_revive_keeps_hp(cfg)
	_test_recall(cfg)
	_test_normal_death_respawn(cfg)
	_test_serial_respawn_queue(cfg)
	_test_no_base_permanent_death(cfg)
	_test_respawn_keeps_identity(cfg)
	_test_recruit_queue_cleared(cfg)
	_test_tech_recalc(cfg)
	_test_snapshot_round_trip(cfg)
	_test_ai(cfg)

func _give(w, food: float, gold: float) -> void:
	w.resources["food"] = food
	w.resources["gold"] = gold

func _no_income(w) -> void:
	for z in w.zones.zones:
		z["production"] = {"food": 0.0, "gold": 0.0, "population": 0.0}

func _smash(cfg, w, g) -> void:
	g.take_damage(cfg, w, g.hp + 9999.0, null)

func _set_downed_hp(g, ratio: float) -> void:
	g.hp = g.hp_max * ratio
	g.nd_regen_hp = g.hp
	g.nd_hp_ratio = ratio

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


func _first_event(events: Array, type_name: String) -> Dictionary:
	for e in events:
		if String(e.get("type", "")) == type_name:
			return e
	return {}

func _add_mate(cfg, w, leader) -> Variant:
	var m = UnitRes.create(cfg, "%s-testmate" % leader.id, "试验兵",
		Vector2i(leader.tx, leader.ty), leader.faction, leader.unit_type,
		"", String(leader.id), String(leader.unit_type), -1)
	m.hp_max = 1000.0
	m.base_hp_max = 1000.0
	m.hp = 1000.0
	w.units.append(m)
	return m

func _test_config_table(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	ok(not w.has_method("revive_cost"), "★★ 再起不再消耗资源（revive.cost / revive_cost 已移除）")
	near(w.revive_channel_sec(), 5.0, 1e-6, "★ 再起读条 5 秒")
	near(w.revive_ready_ratio(), 0.1, 1e-6, "★ 血量到 10% 才允许再起")
	near(cfg.revive_regen_sec, 3.0, 1e-6, "★ 每 3 秒回复一次")
	near(cfg.revive_regen_ratio, 0.01, 1e-6, "★ 每次回复 1% 血量上限")
	near(cfg.revive_regen_cap_ratio, 0.2, 1e-6, "★ 回复天花板 = 20% 血量上限")
	near(w.revive_respawn_sec(), 20.0, 1e-6, "★ 正常阵亡 → 20 秒后在大本营重生")
	near(w.revive_recall_respawn_sec(), 10.0, 1e-6, "★ 召回阵亡 → 10 秒后重生（更短）")

func _test_downed_entry(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	ok(g != null, "（前提）有 general-1")
	if g == null:
		return
	ok(g.is_general(), "（前提）它确实是将领类单位")
	ok(not w.retinue_of(g.id, true).is_empty(), "（前提）它开局带着附属兵")

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

func _test_no_retinue_dies_at_once(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	ok(g != null, "（前提）有 general-3")
	if g == null:
		return
	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	w.tick(DT)
	ok(w.retinue_of(g.id, true).is_empty(), "（前提）它旗下已经一个活兵都没有")

	_smash(cfg, w, g)
	ok(not g.alive, "★★ 无附属部队时直接死亡（用户拍板）")
	ok(not g.is_downed(), "★ 而且**没有**进入濒死")
	eq(g.deaths, 1, "★ 记了一次阵亡")
	ok(not w.has_living_retinue(g), "（旁证）has_living_retinue 对它返回 false")

func _test_immune_and_unattackable(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	var hp_before: float = g.hp

	g.take_damage(cfg, w, 9999.0, null)
	near(g.hp, hp_before, 1e-6, "★★ 濒死期间不会受到任何伤害")
	ok(g.alive and g.is_downed(), "★ 挨了 9999 伤害还倒着（濒死 = 无敌）")

	var foe = w.spawn_enemy(g.tx + 1, g.ty)
	ok(foe != null, "刷出一个测试敌人")
	if foe != null:
		foe.hold_position = true
		foe.drop_engagement()
		var got: bool = CombatAcquire(w, cfg, foe)
		ok(not got or foe.target != g, "★★ 自动索敌不会把濒死的将领当成目标")
		var attacker = w.unit_by_id("general-2")
		var ok_order: bool = attacker.order_attack_unit(w, cfg, g)
		ok(not ok_order, "★★ 指定攻击（右键点它）也被拒绝")
		ok(attacker.ordered_target == null, "★ 被拒之后没有留下 ordered_target")

	var hp_tower0: float = g.hp
	var tw = w.add_building("tower", g.tx + 1, g.ty + 1, FactionRes.NPC_FACTION, true, true)
	ok(tw != null, "（前提）在它旁边立起一座敌方箭塔")
	if tw != null:
		_run_secs(w, 2.0)
		near(g.hp, hp_tower0, g.hp_max * cfg.revive_regen_ratio + 1e-6,
			"★★ 箭塔也不会伤害濒死的将领")
		ok(g.alive and g.is_downed(), "★ 挨了这一会儿它仍然倒着（没被塔打死）")

func CombatAcquire(w, cfg, u) -> bool:
	var cls: GDScript = load("res://logic/combat.gd")
	if cls == null:
		return false
	return cls.acquire_target(w, cfg, u, -1)

func _test_no_attack_line_when_downed(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var foe = w.spawn_enemy(g.tx + 1, g.ty)
	ok(foe != null, "（前提）刷出一个贴脸的敌人")
	if foe == null:
		return
	foe.hold_position = true

	g.drop_engagement()
	g.target = foe
	g.attack_cd = 0.0
	CombatUpdate(w, cfg, g)                  # 贴脸 ⇒ 这一帧就会开火
	ok(g.last_target == foe, "（前提）它刚刚开过火（last_target 指着敌人）")
	near(g.attack_flash, 1.0, 1e-6, "（前提）开火特效亮着（attack_flash = 1）")

	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它进了濒死")

	near(g.attack_flash, 0.0, 1e-6, "★★ 进濒死时开火特效当场清零（不会留下连线）")
	ok(g.last_target == null, "★★ 残留的 last_target 也清掉（渲染那两个字段它都读）")
	ok(g.last_building == null, "★ last_building 一起清")

	g.attack_flash = 1.0
	g.last_target = foe
	var secs: float = cfg.flash_sec_safe * 1.5
	_run_secs(w, secs)
	near(g.attack_flash, 0.0, 1e-6,
		"★★ 濒死期间开火特效也会自己衰减（%.2f 秒后归零）" % secs)

	var g2 = w.unit_by_id("general-2")
	g2.attack_flash = 1.0
	_run_secs(w, secs)
	near(g2.attack_flash, 0.0, 1e-6, "★ 活着单位的特效同样归零（口径一致）")

func CombatUpdate(w, cfg, u) -> void:
	var cls: GDScript = load("res://logic/combat.gd")
	if cls == null:
		return
	cls.update_combat(w, cfg, u)

func _test_regen_rate_and_cap(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")

	var step: float = g.hp_max * cfg.revive_regen_ratio      # 每 3 秒该加多少（= 上限的 1%）
	near(g.hp, 1.0, 1e-6, "（起点）1 点血")

	_run_secs(w, 2.0)
	near(g.hp, 1.0, 1e-6, "★ 2 秒时还没回（周期是 3 秒）")
	_run_secs(w, 1.5)
	near(g.hp, 1.0 + step, 0.05, "★★ 3 秒后回复了 1% 上限")

	var prev: float = g.hp
	var dropped := false
	for _i in 40:
		_run_secs(w, 0.5)
		if g.hp < prev - 1e-9:
			dropped = true
		prev = g.hp
	ok(not dropped, "★★ 回复期间血量只增不减")

	_run_secs(w, 120.0)
	var cap: float = g.hp_max * cfg.revive_regen_cap_ratio
	near(g.hp, cap, 1e-3, "★★ 回复量封顶在 20% 血量上限")
	ok(g.hp <= cap + 1e-6, "★ 永远不会高于 20%")
	ok(g.is_downed(), "★★ 回到 20% 之后**仍然是濒死**（必须点再起才真正解除）")
	ok(g.revive_ready(cfg), "★ 20% ≥ 10%，所以「再起」现在可点")
	near(g.nd_regen_progress(cfg), 1.0, 1e-6, "★ 回复进度条满了")

func _test_wipe_kills_downed(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-2")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	ok(g.alive, "（前提）它还活着")

	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	var evts: Array = w.tick(DT)
	ok(not g.alive, "★★ 濒死期间旗下部队全灭 ⇒ 将领立即死亡")
	ok(not g.is_downed(), "★ 死亡时濒死状态被清掉（不留幽灵）")
	eq(g.deaths, 1, "★ 记了一次阵亡")
	ok(_count_events(evts, "kill") >= 1, "★ 发了 kill 事件（其中一条是它自己）")
	eq(_count_events(evts, "leader_lost"), 1, "★ 另发一条 leader_lost（带 reason）")
	var base = w.find_base_of(MY)
	ok(base != null and base.is_respawning(), "★★ 阵亡将领进入大本营重生队列")
	if base != null:
		eq(base.respawn_count(), 1, "★ 队列里 1 位（正常阵亡 20 秒）")

func _test_rally_retinue(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var mates: Array = w.retinue_of(g.id, true)
	ok(not mates.is_empty(), "（前提）它有附属兵")

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

	var anchor: Vector2 = g.downed_anchor
	var rallied := 0
	for m in mates:
		if m.has_attack_move and m.attack_move_goal.distance_to(anchor) < 0.01:
			rallied += 1
	ok(rallied > 0, "★★ 附属兵解除旧命令、改成行军攻击到**倒下点**（%d 个）" % rallied)
	ok(rallied == mates.size(), "★ 全部附属兵都收到了这条集结令")
	for m in mates:
		ok(m.ordered_target == null, "★ 旧的点名目标也被清掉了（「解除所有命令」）")

func _test_rescue_lock(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var mates: Array = w.retinue_of(g.id, true)
	ok(not mates.is_empty(), "（前提）它有附属兵")
	if mates.is_empty():
		return
	var m = mates[0]

	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）将领已经倒下")

	eq(w.order_lock_reason(m), "leader_downed",
		"★★ 队长濒死 ⇒ 附属兵被锁（拒因码 leader_downed）")
	ok(w.is_order_locked(m), "★★ 附属兵现在不接受任何指令")
	ok(not CommandRes.apply(w, cfg, {"kind": "move", "ids": [m.id],
		"x": float(m.tx + 3), "y": float(m.ty), "faction": MY}),
		"★★ 玩家把附属兵派走的命令**被拒**（将领再起前不接受指令）")

	ok(m.has_attack_move, "★★ 被锁的同时，救援集结令照旧生效（锁不等于发呆）")
	ok(m.is_rescuing(), "★★ 它处于「救援中」状态（意图挂在单位上）")

	for _i in int(2.0 / DT):
		w.tick(DT)
	ok((m.has_attack_move or m.is_rescuing() or m.pos.distance_to(g.downed_anchor) <= 1.2),
		"★★ 跑 2 秒后它**仍在**执行救援（命令丢了就由 update_rescue_orders 重发）")

func _test_rescue_lock_released_on_revive(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	var mates: Array = w.retinue_of(g.id, true)
	if mates.is_empty():
		ok(false, "（前提）它有附属兵")
		return
	var m = mates[0]
	_give(w, 2000.0, 2000.0)
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）已经倒下")
	eq(w.order_lock_reason(m), "leader_downed", "（前提）部队被锁住")

	_set_downed_hp(g, 0.2)
	ok(w.start_revive(g.id, MY), "（前提）再起下单成功")
	for _i in int((cfg.revive_channel_sec + 0.5) / DT):
		w.tick(DT)
	ok(not g.is_downed(), "★★ 将领已经站起来了")
	ok(not m.is_rescuing(), "★★ 救援意图自动结束（队长不再濒死）")
	eq(w.order_lock_reason(m), "", "★★ 部队恢复可指挥（拒因码清空）")
	ok(CommandRes.apply(w, cfg, {"kind": "move", "ids": [m.id],
		"x": float(m.tx + 3), "y": float(m.ty), "faction": MY}),
		"★★ 再起之后玩家又能指挥它了")

func _test_revive_gate_no_cost(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 0.0, 0.0)                       # ★ 一分钱都没有，验证再起免费
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")

	ok(not g.revive_ready(cfg), "★ 刚倒下时（1 点血）还没到 10%，不能再起")
	eq(w.revive_reject_reason(g, MY), "hp", "★ 拒因码 = hp")
	ok(not w.start_revive(g.id, MY), "★ 这时再起被拒")
	near(w.resources["food"], 0.0, 1e-6, "★ 被拒时资源不变")

	_set_downed_hp(g, 0.1)
	ok(g.revive_ready(cfg), "★ 血量到 10% ⟹ 允许再起")
	eq(w.revive_reject_reason(g, MY), "", "★ 拒因码为空（不再有 cost 这一条）")

	ok(w.start_revive(g.id, MY), "★★ 0 资源也能再起（免费）")
	near(w.resources["food"], 0.0, 1e-6, "★★ 再起不扣粮食")
	near(w.resources["gold"], 0.0, 1e-6, "★★ 再起不扣黄金")
	ok(g.is_reviving(), "★ 进入了读条状态")
	near(g.revive_total, w.revive_channel_sec(), 1e-6, "★ 读条总时长 = config 的 5 秒")

	eq(w.revive_reject_reason(g, MY), "channeling", "★ 读条中不能再下一单")
	ok(not w.start_revive(g.id, MY), "★ 重复下单被拒")
	near(w.resources["food"], 0.0, 1e-6, "★ 重复下单也不会扣钱")

	eq(w.revive_reject_reason(g, "p2"), "faction", "★ 别的阵营不能替它再起")

func _test_revive_channel_and_cancel(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	_no_income(w)                            # 对账：别让区划产出掺进来（本轮起区划基础产能是固定值）
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.1)
	ok(w.start_revive(g.id, MY), "（前提）再起入队")
	ok(g.is_reviving(), "（前提）它在读条")

	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 9999.0, null)
	_run_secs(w, 0.5)
	ok(g.alive and g.is_downed(), "★★ 读条期间手下兵全死光，将领**没有**当场死亡")
	ok(g.is_reviving(), "★ 读条没有被打断")

	_run_secs(w, 2.0)
	ok(g.is_reviving(), "★ 2 秒时还在读条")
	ok(g.revive_progress() > 0.3 and g.revive_progress() < 0.7,
		"★ 读条进度与秒数对得上（约 40%%~60%%，实测 %.2f）" % g.revive_progress())

	ok(w.cancel_revive(g.id, MY), "★ 取消读条成功")
	ok(not g.is_reviving(), "★ 不再是读条状态")
	near(w.resources["food"], 1000.0, 1e-6, "★★ 再起免费，取消也不会退钱")
	near(w.resources["gold"], 1000.0, 1e-6, "★★ 黄金同样不变")
	ok(g.is_downed(), "★ 它仍然是濒死的（取消 ≠ 死亡，也 ≠ 复活）")
	ok(not w.cancel_revive(g.id, MY), "★ 没在读条时再取消：返回 false")

	ok(w.start_revive(g.id, MY), "再下一单")
	ok(g.is_reviving(), "（前提）它在读条")
	var evts: Array = _run_secs(w, 6.0)
	ok(not g.is_downed(), "★★ 一个兵都没有也读完了（读条期间暂停全灭判定）")
	ok(g.alive, "★ 它还活着")
	ok(g.is_attackable(), "★★ 重新成为可被攻击 / 可被锁定的单位")
	ok(not w.is_order_locked(g), "★ 重新接受指令")
	ok(_count_events(evts, "leader_revived") >= 1, "★ 发了一条 leader_revived 事件")

func _test_revive_keeps_hp(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-2")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.15)
	_add_mate(cfg, w, g)
	var hp_at_click: float = g.hp
	ok(w.start_revive(g.id, MY), "（前提）再起入队")
	ok(w.has_living_retinue(g), "（前提）读条开始时它旗下确实有活兵")
	var mate_n0: int = w.retinue_of(g.id, true).size()
	_run_secs(w, 6.0)
	ok(g.alive, "（前提）它还活着（没有全灭）· 读条前后附属兵 %d → %d" % [
		mate_n0, w.retinue_of(g.id, true).size()])
	ok(not g.is_downed(), "（前提）已经脱离濒死")
	var post_secs: float = 6.0 - cfg.revive_channel_sec
	var tol: float = g.hp_max * cfg.revive_regen_ratio * 2.0 + 4.0 * post_secs + 0.5
	near(g.hp, hp_at_click, tol,
		"★★ 再起后血量 = 点再起时的血量（外加读条期间的自动回复与站起来之后的领地回血）")
	ok(g.hp < g.hp_max - 1e-6, "★★ 再起**不是**满血复活（血量就是点下去时那个数）")
	ok(g.hp > 1.0 + 1e-6, "★★ 也不是被打回 1 点")
	ok(g.combat_damage(cfg) > 0.0, "★ 它能重新投入战斗（攻击数值照旧）")

## ★★ 召回：静默击杀旗下部队 → 将领阵亡 → 大本营重生队列 10 秒 → 阻塞升级。
func _test_recall(cfg) -> void:
	var w = require_world_with_escorts(cfg, 2)
	var upg = load("res://logic/upgrade.gd")
	var g = w.unit_by_id("general-1")
	var base = w.find_base_of(MY)
	ok(g != null and base != null, "（前提）将领与大本营都在")
	if g == null or base == null:
		return
	_give(w, 10000.0, 10000.0)
	var mates: Array = w.retinue_of(g.id, true).duplicate()
	ok(not mates.is_empty(), "（前提）它带着附属兵")

	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）将领已经濒死")

	var evts: Array = []
	ok(w.recall_general(g.id, MY), "★ 召回命令被接受")
	evts.append_array(w.tick(DT))

	ok(not g.alive, "★★ 召回后将领立即阵亡")
	for m in mates:
		ok(not m.alive, "★★ 旗下部队被静默击杀")
		ok(not w.units.has(m), "★ 而且立即离开 world.units（不走死亡清理）")
	eq(w.retinue_of(g.id, true).size(), 0, "★ 名下不再有任何活兵")
	var kill_evts := 0
	for e in evts:
		if String(e.get("type", "")) == "kill" and (e.get("unit", null) == g or mates.has(e.get("unit", null))):
			kill_evts += 1
	eq(kill_evts, 1, "★★ 只有将领自己的 kill 事件（部队不触发死亡效果）")
	var lost_evts := 0
	for e in evts:
		if String(e.get("type", "")) == "leader_lost" and e.get("unit", null) == g:
			lost_evts += 1
	eq(lost_evts, 1, "★ 将领走正常阵亡逻辑（leader_lost +1）")

	ok(base.is_respawning(), "★★ 将领进入大本营重生队列")
	eq(base.respawn_count(), 1, "队列里 1 位")
	ok(base.respawn_eta() <= 10.0 + 1e-6, "★★ 召回的重生时长 = 10 秒（实际 %.2f）" % base.respawn_eta())
	eq(upg.can_upgrade(w, base, MY), "respawning",
		"★★ 重生队列不为空 → 大本营不能开始新升级")
	ok(not w.start_building_upgrade(base.tx, base.ty, MY), "升级命令被拒")
	var rej_evts: Array = w.tick(DT)
	var rej: Dictionary = _first_event(rej_evts, "upgrade_rejected")
	eq(String(rej.get("reason", "")), "respawning", "拒因码 = respawning")

	_run_secs(w, 9.0)
	ok(not g.alive, "★ 9 秒还没重生")
	ok(base.is_respawning(), "★ 仍然在重生队列里")

	_run_secs(w, 1.5)
	ok(g.alive, "★★ 10 秒后将领在大本营重生")
	ok(w.unit_by_id(g.id) != null, "★ 回到 world.units")
	near(g.hp, g.hp_max, 1e-6, "★★ 重生满血")
	ok(not base.is_respawning(), "★ 队列清空")
	eq(upg.can_upgrade(w, base, MY), "", "★★ 重生完成后大本营恢复可升级")


## ★★ 正常阵亡（没有召回）：20 秒后重生。
func _test_normal_death_respawn(cfg) -> void:
	var w = require_world_with_escorts(cfg, 1)
	var base = w.find_base_of(MY)
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	# 造一个没有附属兵的将领：直接走「无兵即死」这条路。
	var g = UnitRes.create(cfg, "respawn-20s", "测试将", Vector2i(base.tx + 2, base.ty + 2),
		MY, "general_4", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 3)
	w.units.append(g)
	_smash(cfg, w, g)
	ok(not g.alive, "★★ 没有附属兵 → 当场阵亡")
	ok(base.is_respawning(), "★ 进入大本营重生队列")
	ok(base.respawn_eta() <= 20.0 + 1e-6, "★ 正常阵亡 = 20 秒（实际 %.2f）" % base.respawn_eta())

	_run_secs(w, 19.0)
	ok(not g.alive, "★ 19 秒还没重生")
	_run_secs(w, 1.5)
	ok(g.alive, "★★ 20 秒后重生")
	ok(not base.is_respawning(), "★ 队列清空")


## ★★ 串行：两位将领先后阵亡，前一位出来后才轮到下一位开始倒计时。
func _test_serial_respawn_queue(cfg) -> void:
	var w = require_world_with_escorts(cfg, 1)
	var base = w.find_base_of(MY)
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	var a = UnitRes.create(cfg, "serial-a", "甲", Vector2i(base.tx + 1, base.ty + 1),
		MY, "general_4", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 3)
	var b = UnitRes.create(cfg, "serial-b", "乙", Vector2i(base.tx + 2, base.ty + 2),
		MY, "general_5", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 4)
	w.units.append(a)
	w.units.append(b)
	_smash(cfg, w, a)
	_smash(cfg, w, b)
	eq(base.respawn_count(), 2, "★ 队列里两位")
	eq(base.respawn_eta(), 20.0, "★ 只有队首在倒计时（20 秒）")

	_run_secs(w, 21.0)
	ok(a.alive, "★★ 20 秒后第一位重生")
	ok(not b.alive, "★★ 第二位还没出来（串行，不并行计时）")
	ok(base.is_respawning(), "★ 队列还有一位 → 大本营仍然忙")
	ok(base.respawn_eta() <= 19.2, "★ 第一位出来后才开始第二位的倒计时")

	_run_secs(w, 20.0)
	ok(b.alive, "★★ 再等 20 秒，第二位也重生")
	ok(not base.is_respawning(), "★ 队列清空")


## ★★ 没有可用大本营 → 永久阵亡（不排队、不重生）。
func _test_no_base_permanent_death(cfg) -> void:
	var w = require_world_with_escorts(cfg, 1)
	var base = w.find_base_of(MY)
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	ok(w.remove_building(base, true), "（前提）强制移除大本营（模拟被摧毁）")
	var g = UnitRes.create(cfg, "no-base-general", "无家将", Vector2i(2, 2),
		MY, "general_4", "", "", UnitRes.UNIT_TYPE_SPEARMAN, 3)
	w.units.append(g)
	_smash(cfg, w, g)
	ok(not g.alive, "★ 将领阵亡")
	w.tick(DT)
	ok(w.unit_by_id(g.id) == null, "★★ 没有大本营 → 直接从 world 消失（永久阵亡）")
	ok(not base.is_respawning(), "★ 没有任何重生队列")


## ★★ 重生后身份 / 特性 / 快捷键保持不变。
func _test_respawn_keeps_identity(cfg) -> void:
	var w = require_world_with_escorts(cfg, 1)
	var base = w.find_base_of(MY)
	ok(base != null, "（前提）有大本营")
	if base == null:
		return
	var g = UnitRes.create(cfg, "identity-general", "老将", Vector2i(base.tx + 2, base.ty + 2),
		MY, "general_5", "5", "", UnitRes.UNIT_TYPE_LONGBOWMAN, 4)
	w.units.append(g)
	_smash(cfg, w, g)
	_run_secs(w, 21.0)
	ok(g.alive, "（前提）已经重生")
	eq(String(g.id), "identity-general", "★ id 保持")
	eq(String(g.name), "老将", "★ 名字保持")
	eq(String(g.kind), "general_5", "★ kind 保持")
	eq(String(g.unit_type), UnitRes.UNIT_TYPE_LONGBOWMAN, "★ 兵种保持")
	eq(int(g.general_index), 4, "★ 将领档保持")
	eq(String(g.hotkey), "5", "★ 快捷键保持")
	eq(String(g.general_trait), "", "★ 词条已停用：重生后仍没有词条")
	near(g.hp, g.hp_max, 1e-6, "★ 满血回归")


func _test_recruit_queue_cleared(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	_give(w, 1000.0, 1000.0)
	var z = w.zones.zone_at(g.tx, g.ty)
	z["population"] = 10.0
	_no_income(w)                            # 对账：别让区划产出掺进来

	var kind := "spearman"
	var rcost: float = float((w.recruit_cost(kind) as Dictionary).get("food", 0.0))
	ok(w.start_recruit(kind, g.id, "p1"), "（前提）将领开始招募")
	ok(g.train_queue_size() > 0, "（前提）它确实在读条")
	near(float(w.resources["food"]), 1000.0 - rcost, 1e-4, "（前提）已经扣了一单的粮（= config 定价）")
	near(float(z["population"]), 9.0, 1e-4, "（前提）已经扣了 1 人口")

	_smash(cfg, w, g)
	ok(g.is_downed(), "★★ 它进了濒死")
	eq(g.train_queue_size(), 0, "★★★ 招募队列**整个作废**（不留任何一单）")
	near(float(w.resources["food"]), 1000.0, 1e-4, "★★ 已扣的粮食**全额退还**")
	near(float(w.resources["gold"]), 1000.0, 1e-4, "★★ 黄金也全额退还")
	near(float(z["population"]), 10.0, 1e-4, "★★ 人口也退回去了")
	eq(w.can_recruit(kind, g.id, MY), "downed",
		"★★ 濒死期间不能再下单（拒因码 downed）")

	var n0: int = w.retinue_of(g.id, true).size()
	var evts: Array = _run_secs(w, 12.0)     # 招募读条只要 10 秒
	eq(w.retinue_of(g.id, true).size(), n0, "★★★ 等了 12 秒也没有新兵冒出来（原来会出一个）")
	ok(g.alive and g.is_downed(), "★ 它还是倒着（没有因为『又造了个兵』续命，但也没死）")

	for m in w.retinue_of(g.id, true):
		m.take_damage(cfg, w, m.hp + 999999.0, null)
	_run_secs(w, 0.2)
	ok(not g.alive, "★★★ 打光它旗下部队之后它当场死亡（不再被招募队列吊着）")
	ok(_count_events(evts, "leader_downed") >= 1, "★ 期间发过 leader_downed 事件")

func _test_tech_recalc(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-3")
	_smash(cfg, w, g)
	ok(g.is_downed(), "（前提）它已经濒死")
	_set_downed_hp(g, 0.15)
	var hp_before: float = g.hp
	var hp_max_before: float = g.hp_max

	g.apply_hp_bonus(1.5)
	ok(g.hp_max > hp_max_before, "★ 血量上限确实涨了")
	near(g.hp, hp_before, 1e-6, "★★ 濒死期间科技改上限**不许动当前血量**（只增不减）")
	near(g.nd_regen_hp, hp_before, 1e-6, "★ 回复记账也没被覆盖")

	g.nd_hp_ratio = 0.15
	g.start_revive(cfg)
	g.revive_remaining = 1e-6              # 直接把读条走完（不改配置）
	w.tick(DT)
	ok(not g.is_downed(), "（前提）已经站起来")
	near(g.hp / g.hp_max, 0.15, 1e-6, "★★ 站起来那一刻按比例对齐（占上限的 15%）")

	var hp_max_now: float = g.hp_max
	g.apply_hp_bonus(1.0)
	ok(g.hp_max < hp_max_now, "★ 弃用科技后上限回落到基础值")
	ok(g.hp <= g.hp_max + 1e-6, "★ 当前血量不会超过上限")

func _test_snapshot_round_trip(cfg) -> void:
	var w = require_world_with_escorts(cfg, 3)
	var g = w.unit_by_id("general-1")
	_give(w, 1000.0, 1000.0)
	_smash(cfg, w, g)
	_set_downed_hp(g, 0.12)
	g.nd_regen_hp = g.hp
	ok(w.start_revive(g.id, MY), "（前提）它正在读条再起")

	var snap: Dictionary = SnapshotRes.to_snapshot(w)
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

	var legacy: Dictionary = { "units": [{ "i": g.id, "h": int(round(g.hp)) }] }
	SnapshotRes.apply_snapshot(w2, cfg, legacy)
	ok(g2.downed, "★ 缺 nd 字段的老快照不会把濒死状态清掉（缺字段 = 保持现状）")

func _test_ai(cfg) -> void:
	var cls := script_at("res://logic/world.gd")
	if cls == null:
		return
	var w = cls.create(cfg, DEFAULT_MAP_PATH, true)
	ok(w != null, "（前提）带 AI 的世界能建出来")
	if w == null:
		return
	var ai_f := ""
	for f in w.factions:
		if w.ai_kind_of(String(f)) != "none":
			ai_f = String(f)
			break
	ok(ai_f != "", "（前提）这一局确实有 AI 阵营")
	# ★ 新口径：AI / 无大本营的阵营不再自动生成开局将；这里手动摆一位，
	#   专门验「AI 的将领也走同一套濒死 / 再起规则」。
	var g = null
	for u in w.units:
		if u.alive and String(u.faction) == ai_f and u.is_general():
			g = u
			break
	if g == null:
		g = w.create_general(ai_f, 0, 0)
		if g != null:
			w.units.append(g)
	ok(g != null, "（前提）AI 那一边有将领")
	if g == null:
		return

	_add_mate(cfg, w, g)
	_give(w, 0.0, 0.0)
	_smash(cfg, w, g)
	ok(g.is_downed(), "★★ AI 的将领也会进入濒死（同一套规则）")
	ok(g.alive, "★ 它仍然是 alive —— 因此照旧占着将领槽位")

	var listed := 0
	for u in w.units:
		if u.alive and String(u.faction) == ai_f and u.is_general():
			listed += 1
	var found := false
	for u in w.units:
		if u == g:
			found = true
	ok(found and listed > 0, "★★ 濒死的将领仍在世界单位表里、仍被算作这一方的将领（占槽位）")

	_no_income(w)
	var evts_early: Array = w.tick(DT)
	ok(not g.is_reviving(), "★★ 血量不到 10% 时 AI 不会再起（与玩家同一个门槛）")
	ok(_count_events(evts_early, "revive_started") == 0, "★ 这一帧没有下再起单")

	_set_downed_hp(g, w.revive_ready_ratio())
	var evts: Array = w.tick(DT)
	ok(g.is_reviving(), "★★★ AI 在符合条件时自己让将领再起（无消耗）")
	ok(_count_events(evts, "revive_started") >= 1, "★ 发了一条 revive_started")

	_run_secs(w, 6.0)
	ok(not g.is_downed(), "★★ AI 的将领读条结束后脱离濒死")
	ok(g.is_attackable(), "★ 它重新成为可攻击目标")
