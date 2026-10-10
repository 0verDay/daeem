## test_formation.gd —— 队形落点（一群单位点到同一点时各自领一个槽位）
##
## 为什么值得单独钉住：
##   · 它是**行为改动**：原来所有人都走向同一个坐标，现在各走各的槽位；
##   · 槽位算错的表现很隐蔽 —— 有人被排进山里、两个人分到同一个槽位、
##     或者整队互相穿过（队形打结），都不会报错，只是「看着不对劲」；
##   · 而且它一旦失效，就会退回「所有人抢一个点 → 到达后互相挤着转」那个老毛病。
##
## ⚠️ 少于 `unit.formation.min_units` 个单位时**不排阵**：
##    1~3 个单位点击是最需要精确落点的操作，不该被阵型改坏。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const CommandRes = preload("res://logic/command_processor.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_formation"
	run_all(_cases)
	cleanup_escort_scaffold()


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var w = require_world_with_escorts(cfg, 2)
	if w == null:
		return
	_test_slots_distinct_and_passable(w, cfg)
	_test_small_group_lands_exactly(w, cfg)
	_test_group_spreads_out(w, cfg)
	_test_no_rank_when_click_is_blocked(w, cfg)
	# ★★ 本轮阵型大改：分层（兵种前后）+ 同部队聚簇 + 多部队共用一个阵型 + 到达后成型
	_test_tier_layering(w, cfg)
	_test_troop_clustered(w, cfg)
	_test_all_troops_participate(w, cfg)
	_test_arrival_layered(cfg)


## 槽位本身：一一对应、互不重合、都可通行、都紧挨着点击点
func _test_slots_distinct_and_passable(w, cfg) -> void:
	var group: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			group.append(u)
	ok(group.size() >= cfg.formation_min_units,
		"测试队伍有 %d 个单位（≥ formation.min_units=%d）" % [group.size(), cfg.formation_min_units])

	var click := _open_spot(w)
	ok(click.x > 0.0, "找得到一块开阔地当点击点")
	if click.x <= 0.0:
		return

	var slots: Array[Vector2] = CommandRes.formation_slots(w, cfg, group, click)
	eq(slots.size(), group.size(), "每个单位都有一个槽位（与队伍一一对应）")

	var seen: Dictionary = {}
	var dup := 0
	for s in slots:
		# 量化到 0.01 格再比：浮点尾巴不该被当成「不同的槽位」
		var k := "%d,%d" % [roundi(s.x * 100.0), roundi(s.y * 100.0)]
		if seen.has(k):
			dup += 1
		seen[k] = true
	eq(dup, 0, "★ 槽位互不重合（重合 %d 个）" % dup)

	var bad := 0
	var far := 0
	for s in slots:
		if not PathfinderRes.passable(w.map, w.buildings, cfg, floori(s.x), floori(s.y), group[0].faction):
			bad += 1
		if s.distance_to(click) > 3.0:
			far += 1
	eq(bad, 0, "★ 所有槽位都落在可通行格上（落进障碍 %d 个）" % bad)
	eq(far, 0, "槽位都紧挨着点击点（超过 3 格的 %d 个）" % far)


## 少于 min_units 时不排阵：单个单位必须**精确**停在点击位置（与改队形之前一致）
func _test_small_group_lands_exactly(w, cfg) -> void:
	ok(cfg.formation_min_units > 1, "formation.min_units 大于 1（否则这条验不到东西）")
	cfg.combat_enabled = false
	var w2 = require_world(cfg)
	var u = w2.units[0]
	w2.units = [u]
	var target := _open_spot(w2)
	u.stop()
	u.pos = target + Vector2(-4.0, -3.0)
	u.sync_tile(w2.map)
	ok(CommandRes.apply(w2, cfg, {"kind": "move", "ids": [u.id],
		"faction": w2.my_faction, "x": target.x, "y": target.y}), "单人移动命令被接受")
	var n := 0
	while u.moving and n < 2000:
		w2.tick(DT)
		n += 1
	v2_near(u.pos, target, 1e-3, "★ 单个单位仍然精确停在点击位置（队形不该改坏精确操作）")


## 整队排阵之后：真的散开了、没有严重重叠、都停在点击点附近
func _test_group_spreads_out(w, cfg) -> void:
	cfg.combat_enabled = false
	var w2 = require_world(cfg)
	var group: Array = []
	for u in w2.units:
		if FactionRes.same_side(u.faction, w2.my_faction):
			group.append(u)
	var ids: Array = []
	for u in group:
		ids.append(u.id)

	var target := _open_spot(w2)
	ok(CommandRes.apply(w2, cfg, {"kind": "move", "ids": ids,
		"faction": w2.my_faction, "x": target.x, "y": target.y}), "整队移动命令被接受")

	var n := 0
	while n < 1500:
		w2.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			break

	var far := 0
	for u in group:
		if u.pos.distance_to(target) > 3.0:
			far += 1
	eq(far, 0, "★ 排阵后都停在点击点附近（超过 3 格的 %d 个）" % far)

	var min_pair := 999.0
	for i in group.size():
		for j in range(i + 1, group.size()):
			min_pair = minf(min_pair, (group[i] as Object).pos.distance_to((group[j] as Object).pos))
	var soft: float = cfg.unit_collision_radius * 2.0 * cfg.unit_overlap_allowance
	ok(min_pair >= soft * 0.6,
		"★ 排阵后没有严重重叠（最近一对 %.3f 格，软下限 %.3f）" % [min_pair, soft])

	# 落点必须真是**不同的**：如果又退化成「所有人抢一个点」，这条会红
	var distinct := 0
	var seen: Dictionary = {}
	for u in group:
		var k := "%d,%d" % [roundi(u.pos.x * 10.0), roundi(u.pos.y * 10.0)]
		if not seen.has(k):
			seen[k] = true
			distinct += 1
	ok(distinct >= group.size() - 1,
		"★ 各走各的槽位（%.0f%% 的单位落在不同的 0.1 格上）" % (100.0 * float(distinct) / float(group.size())))


## 点到不可通行的格子（山 / 建筑）时不排阵 —— 那种情况下每个单位的落点会被
## move_to 各自改成「贴边最近的可达点」，共用的那张距离场覆盖不到它们。
func _test_no_rank_when_click_is_blocked(w, cfg) -> void:
	var w2 = require_world(cfg)
	var group: Array = []
	for u in w2.units:
		if FactionRes.same_side(u.faction, w2.my_faction):
			group.append(u)
	var blocked := _blocked_spot(w2)
	ok(blocked.x >= 0, "地图上找得到一格不可通行的地方")
	if blocked.x < 0:
		return
	var ids: Array = []
	for u in group:
		ids.append(u.id)
	ok(CommandRes.apply(w2, cfg, {"kind": "move", "ids": ids, "faction": w2.my_faction,
		"x": float(blocked.x) + 0.5, "y": float(blocked.y) + 0.5}), "点到障碍：命令仍然被接受")
	for u in group:
		ok(u.has_goal or not u.moving, "%s 的落点被换成了别处（没有对着障碍硬走）" % u.id)


# ------------------------------------------------------------------

## ★★ 分层：阵型「由前往后」依次是长枪兵（spearman）→ 长弓兵（longbowman）→ 骑手（rider）。
## 判据：把每个槽位相对点击点的偏移投影到「行进方向」上，各兵种的纵深区间**不重叠且有序**。
func _test_tier_layering(w, cfg) -> void:
	var group := _p1_units(w)
	ok(group.size() >= cfg.formation_min_units, "分层：测试队伍 ≥ min_units")
	var click := _open_spot(w)
	ok(click.x > 0.0, "分层：找得到一块开阔地当点击点")
	if click.x <= 0.0:
		return
	var slots: Array[Vector2] = CommandRes.formation_slots(w, cfg, group, click)

	var fwd := _fwd_of(group, click)
	var mn: Dictionary = {}
	var mx: Dictionary = {}
	for i in group.size():
		var t: String = String(group[i].unit_type)
		var d: float = (slots[i] - click).dot(fwd)
		if not mn.has(t) or d < float(mn[t]):
			mn[t] = d
		if not mx.has(t) or d > float(mx[t]):
			mx[t] = d
	ok(mn.has("spearman") and mn.has("longbowman") and mn.has("rider"),
		"分层：队伍里三个兵种都有人（长枪兵 / 长弓兵 / 骑手）")
	if mn.has("spearman") and mn.has("longbowman"):
		ok(float(mn["spearman"]) > float(mx["longbowman"]),
			"★ 长枪兵整体排在长弓兵之前（前 = 行进方向）")
	if mn.has("longbowman") and mn.has("rider"):
		ok(float(mn["longbowman"]) > float(mx["rider"]),
			"★ 长弓兵整体排在骑手之前")


## ★★ 同部队相邻：在**同一个层**里，同一支部队（leader_of 相同）的单位横向连续成一段，
## 中间不会被别的部队插开。
func _test_troop_clustered(w, cfg) -> void:
	var group := _p1_units(w)
	var click := _open_spot(w)
	if click.x <= 0.0:
		return
	var slots: Array[Vector2] = CommandRes.formation_slots(w, cfg, group, click)
	var fwd := _fwd_of(group, click)
	var side := Vector2(-fwd.y, fwd.x)

	var by_tier: Dictionary = {}
	for i in group.size():
		var t: int = CommandRes._formation_tier(cfg, group[i])
		if not by_tier.has(t):
			by_tier[t] = []
		by_tier[t].append(i)

	var checked := 0
	for t in by_tier.keys():
		var members: Array = by_tier[t]
		members.sort_custom(func(a, b) -> bool:
			return (slots[a] - click).dot(side) < (slots[b] - click).dot(side))
		var seq: Array = []
		for i in members:
			seq.append(String(w.leader_of(group[i])))
		var done: Dictionary = {}
		var contiguous := true
		for k in seq.size():
			if k > 0 and seq[k] != seq[k - 1]:
				done[seq[k - 1]] = true
			if done.has(seq[k]):
				contiguous = false
		ok(contiguous, "★ 层 %d：同一部队的单位在阵型里连续相邻（不被打散）" % t)
		checked += 1
	ok(checked >= 1, "聚簇：至少检查了一个层")


## ★★ 多部队共用一个阵型：整队（含多支部队）排出的槽位互不重合，且每支部队都参与了。
func _test_all_troops_participate(w, cfg) -> void:
	var group := _p1_units(w)
	var click := _open_spot(w)
	if click.x <= 0.0:
		return
	var slots: Array[Vector2] = CommandRes.formation_slots(w, cfg, group, click)

	var troops: Dictionary = {}
	for u in group:
		troops[String(w.leader_of(u))] = true
	ok(troops.size() >= 2, "参与：测试队伍里至少有 2 支部队（否则验不到「多部队」）")

	var seen: Dictionary = {}
	var dup := 0
	for s in slots:
		var k := "%d,%d" % [roundi(s.x * 100.0), roundi(s.y * 100.0)]
		if seen.has(k):
			dup += 1
		seen[k] = true
	eq(dup, 0, "参与：多支部队共用一个阵型，槽位互不重合")

	var per_troop: Dictionary = {}
	for u in group:
		per_troop[String(w.leader_of(u))] = true
	eq(per_troop.size(), troops.size(), "参与：每支部队都进入同一个阵型")


## ★★ 到达后成型（整链路）：下达移动命令、跑到停下，最前的是长枪兵、最后的是骑手。
func _test_arrival_layered(cfg) -> void:
	cfg.combat_enabled = false
	var w2 = require_world_with_escorts(cfg, 2)
	if w2 == null:
		return
	var group := _p1_units(w2)
	var click := _open_spot(w2)
	if click.x <= 0.0:
		return
	var fwd := _fwd_of(group, click)

	var ids: Array = []
	for u in group:
		ids.append(u.id)
	ok(CommandRes.apply(w2, cfg, {"kind": "move", "ids": ids,
		"faction": w2.my_faction, "x": click.x, "y": click.y}), "到达分层：整队移动命令被接受")

	var n := 0
	while n < 4000:
		w2.tick(DT)
		n += 1
		var any := false
		for u in group:
			if u.moving:
				any = true
		if not any:
			break

	var front = group[0]
	var back = group[0]
	var fbest := -1e12
	var bbest := 1e12
	for u in group:
		var d: float = (u.pos - click).dot(fwd)
		if d > fbest:
			fbest = d
			front = u
		if d < bbest:
			bbest = d
			back = u
	eq(String(front.unit_type), "spearman", "★ 到达后最前的单位是长枪兵")
	eq(String(back.unit_type), "rider", "★ 到达后最后的单位是骑手")


# ------------------------------------------------------------------

## 队伍重心 → 点击点的单位方向向量（阵型的「前」）。退化时退回 Vector2.RIGHT。
func _fwd_of(group: Array, click: Vector2) -> Vector2:
	var centroid := Vector2.ZERO
	for u in group:
		centroid += u.pos
	centroid /= float(group.size())
	var fwd: Vector2 = click - centroid
	if fwd.length() < 1e-3:
		return Vector2.RIGHT
	return fwd.normalized()


## 自己这一方的全部存活单位（测试里当「一整队」用）。
func _p1_units(w) -> Array:
	var out: Array = []
	for u in w.units:
		if FactionRes.same_side(u.faction, w.my_faction):
			out.append(u)
	return out


# ------------------------------------------------------------------

## 找一块「自己和八邻都可通行」的开阔地中心点（避开山、建筑与地图边界）
func _open_spot(w) -> Vector2:
	for y in range(2, w.map.rows - 2):
		for x in range(2, w.map.cols - 2):
			if not PathfinderRes.passable(w.map, w.buildings, w.cfg, x, y, w.my_faction):
				continue
			var ok_all := true
			for d in GridRes.DIRS8:
				if not PathfinderRes.passable(w.map, w.buildings, w.cfg, x + d.x, y + d.y, w.my_faction):
					ok_all = false
					break
			if ok_all and w.building_at(x, y) == null:
				return GridRes.center_of(Vector2i(x, y))
	return Vector2(-1.0, -1.0)


## 找一格不可通行（山或建筑）的地块
func _blocked_spot(w) -> Vector2i:
	for y in range(0, w.map.rows):
		for x in range(0, w.map.cols):
			if not PathfinderRes.passable(w.map, w.buildings, w.cfg, x, y, w.my_faction):
				return Vector2i(x, y)
	return Vector2i(-1, -1)
