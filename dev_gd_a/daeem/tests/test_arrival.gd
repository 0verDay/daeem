## test_arrival.gd —— 到达行为回归（拥挤时不准「挤着转」）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CollisionRes = preload("res://logic/collision.gd")
const FactionRes = preload("res://logic/faction.gd")

const ESCORTS_PER_GENERAL := 3

const DT := 1.0 / 60.0

func _initialize() -> void:
	_case_name = "test_arrival"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_solo_still_exact(cfg)
	_test_pair_settles(cfg)
	_test_crowd_settles(cfg)
	_test_crowd_stays_still(cfg)
	_test_speed_budget_in_crowd(cfg)
	_test_jam_giveup_bounds_effort(cfg)

func _test_solo_still_exact(cfg) -> void:
	var w = require_world(cfg)
	var u = w.units[0]
	w.units = [u]
	var target = GridRes.center_of(Vector2i(10, 15))
	u.stop()
	u.pos = GridRes.center_of(Vector2i(4, 15))
	u.sync_tile(w.map)
	u.order_move(w, cfg, target)
	var n := 0
	var cap: int = frames_at_baseline(cfg, 2000)
	while u.moving and n < cap:
		w.tick(DT)
		n += 1
	v2_near(u.pos, target, 1e-3, "★ 单人点到空地时仍然精确停在点击位置（没有被拥挤逻辑改坏）")
	ok(not u.moving, "单人到达后 moving = false")
	ok(u.facing.x > 0.9, "★ 单人到达后朝向仍然朝右（%.2f, %.2f）" % [u.facing.x, u.facing.y])

func _test_pair_settles(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world(cfg)
	_clear_zone_centers(w)
	_keep_player_units(w)
	ok(w.units.size() >= 3, "世界上至少 3 个己方单位（实际 %d）" % w.units.size())
	if w.units.size() < 3:
		return
	var a = w.units[0]
	var b = w.units[1]
	var extra = w.units[2]
	_place(extra, Vector2i(2, 2), w)            # 第三位挪到角落，别掺和
	_place(a, Vector2i(8, 15), w)
	_place(b, Vector2i(9, 15), w)
	var target: Vector2 = GridRes.center_of(Vector2i(13, 15))
	a.order_move(w, cfg, target)
	b.order_move(w, cfg, target)

	var settled := -1
	var moving_frames := 0
	var first_stop := -1
	var n := 0
	var cap: int = frames_at_baseline(cfg, 3000)
	while n < cap:
		w.tick(DT)
		n += 1
		for u in [a, b]:
			if u.moving:
				moving_frames += 1
		if first_stop < 0 and (not a.moving or not b.moving):
			first_stop = n
		if settled < 0 and not a.moving and not b.moving:
			settled = n
	print("   [pair] 先停于 %d，都停于 %d，移动单位·帧=%d，间距 %.3f 格"
		% [first_stop, settled, moving_frames, a.pos.distance_to(b.pos)])

	ok(settled > 0, "★★ 两个将领点到同一点后**都停下了**（第 %d 帧）" % settled)
	ok(settled > 0 and settled < frames_at_baseline(cfg, 200),
		"★★ 停下所需时间 ≈ 纯走路的时间，没有「到点后互相挤很久」（%d 帧 < %d）"
		% [settled, frames_at_baseline(cfg, 200)])
	ok(first_stop > 0 and settled - first_stop < frames_at_baseline(cfg, 60),
		"★★ 两个单位几乎同时停下（相隔 %d 帧 < %d），没有来回挤"
		% [settled - first_stop, frames_at_baseline(cfg, 60)])

	var pa: Vector2 = a.pos
	var pb: Vector2 = b.pos
	for i in 300:
		w.tick(DT)
	ok(a.pos.distance_to(pa) < 0.6 and b.pos.distance_to(pb) < 0.6,
		"★★ 停下之后不再互相挤（漂移 %.3f / %.3f 格）"
		% [a.pos.distance_to(pa), b.pos.distance_to(pb)])

func _place(u, tile: Vector2i, w) -> void:
	u.stop()
	u.pos = GridRes.center_of(tile)
	u.sync_tile(w.map)

func _test_crowd_settles(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	if w == null:
		return
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	ok(group.size() >= 6, "世界里至少有 6 个单位（实际 %d）" % group.size())

	var settled := -1
	var moving_unit_frames := 0
	var n := 0
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
		w.tick(DT)
		n += 1
		for u in group:
			if u.moving:
				moving_unit_frames += 1
		if settled < 0:
			var any := false
			for u in group:
				if u.moving:
					any = true
			if not any:
				settled = n
	print("   [crowd] 全部停下于第 %d 帧，移动单位·帧=%d" % [settled, moving_unit_frames])

	ok(settled > 0, "★ 整队点到同一点后**全部停下了**（第 %d 帧）" % settled)

	var ideal = float(group.size()) * 8.0 / (cfg.unit_speed * DT)
	ok(settled > 0 and settled < frames_at_baseline(cfg, 1500),
		"★ 停下来的时间在合理范围内（%d 帧 < %d；基线速度下的实测基准是 694）"
		% [settled, frames_at_baseline(cfg, 1500)])
	ok(float(moving_unit_frames) < ideal * 3.5,
		"★ 总移动量没有爆炸（%.0f 单位·帧，8 格理想值 ≈ %.0f，上限 %.0f）"
		% [moving_unit_frames, ideal, ideal * 3.5])

	var spread := 2.5 + 0.35 * maxf(0.0, float(group.size() - CROWD_N))
	var far := 0
	for u in group:
		if u.pos.distance_to(target) > spread:
			far += 1
	eq(far, 0, "★ 所有单位都落在目标 %.1f 格以内（没有谁被挤到别处；%d 个单位）" % [
		spread, group.size()])

func _test_crowd_stays_still(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	if w == null:
		return
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	var n := 0
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
		w.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			break

	var pos0: Dictionary = {}
	var face0: Dictionary = {}
	for u in group:
		pos0[u.id] = u.pos
		face0[u.id] = u.facing
	var max_drift := 0.0
	var max_turn := 0.0
	for i in 300:
		w.tick(DT)
		for u in group:
			max_drift = maxf(max_drift, u.pos.distance_to(pos0[u.id]))
			max_turn = maxf(max_turn, rad_to_deg(absf((face0[u.id] as Vector2).angle_to(u.facing))))
	print("   [crowd] 停下后 300 帧：漂移 %.4f 格，朝向变化 %.1f°" % [max_drift, max_turn])
	ok(max_drift < 0.01, "★ 停下后不再漂移（最大 %.4f 格）" % max_drift)
	ok(max_turn < 1.0, "★ 停下后朝向不再乱转（最大 %.1f°）" % max_turn)

	var min_pair := 999.0
	for i in group.size():
		for j in range(i + 1, group.size()):
			min_pair = minf(min_pair, (group[i] as Object).pos.distance_to((group[j] as Object).pos))
	var soft: float = CollisionRes.radius(cfg) * 2.0 * cfg.num("unit.overlap_allowance", 0.7)
	ok(min_pair >= soft * 0.6, "★ 停稳后没有严重重叠（最近一对 %.3f 格，软下限 %.3f）" % [min_pair, soft])

func _test_speed_budget_in_crowd(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	if w == null:
		return
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)
	var worst := 0.0
	var worst_ratio := 0.0
	var prev: Dictionary = {}
	for u in group:
		prev[u.id] = u.pos
	var SKIP := 3
	for i in 500:
		w.tick(DT)
		var measure := i >= SKIP
		for u in group:
			if measure and u.moving and not u.settling:
				var d: float = u.pos.distance_to(prev[u.id])
				var b: float = maxf(1e-9, cfg.unit_speed_of(String(u.unit_type)) * DT)
				if d / b > worst_ratio:
					worst_ratio = d / b
					worst = d
			prev[u.id] = u.pos
	var ratio_cap: float = 1.6 * maxf(1.0, float(group.size()) / CROWD_N)
	ok(worst_ratio <= ratio_cap,
		"★ 拥挤下移动位移仍不超预算太多（最大 %.4f 格 = %.2f× 该单位自己的预算，上限 %.2f×；%d 个单位）"
		% [worst, worst_ratio, ratio_cap, group.size()])

func _test_jam_giveup_bounds_effort(cfg) -> void:
	cfg.combat_enabled = false
	var w = require_world_with_escorts(cfg, ESCORTS_PER_GENERAL)
	if w == null:
		return
	_clear_zone_centers(w)
	_keep_player_units(w)
	var target = GridRes.center_of(Vector2i(6, 12))
	var group: Array = []
	for u in w.units:
		group.append(u)
		u.order_move(w, cfg, target)

	var all_settled := -1
	var n := 0
	var cap: int = frames_at_baseline(cfg, 1200)
	while n < cap:
		w.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			all_settled = n
			break
	ok(all_settled > 0, "全部停下（第 %d 帧）" % all_settled)

	ok(all_settled > 0 and all_settled < frames_at_baseline(cfg, 1200),
		"★ 挤不过去时会认账，不会无限努力（%d 帧 < %d）" % [all_settled, frames_at_baseline(cfg, 1200)])

	for u in group:
		ok(not u.moving, "结束后 %s 不处于移动状态" % u.id)

func _keep_player_units(w) -> void:
	var kept: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			kept.append(u)
	w.units = kept

const CROWD_N := 12

func _clear_zone_centers(w) -> void:
	for b in w.building_list.duplicate():
		if b.type == "zone_center":
			w.remove_building(b, true)
	w.refresh_ownership()
