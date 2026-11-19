## test_build_points.gd —— ★★ 建造点位 / 城墙环（2026.11.18 新机制）
##
## 用户口径：
##   · 建造点位**不再写在地图里**：关卡 `zones[].build_point_count` 决定每区生成几个，
##     进图时随机生成；缺省 = config 的 2，0 = 不生成；
##   · 生成时排除**边缘区**（`zones[].no_go`）与**已有建筑**；
##   · 玩家 / AI 仍只能在这些点位上建非城墙建筑；
##   · 木墙 / 石墙只能建在区划中心周围：一张牌把中心那一圈建满，
##     被地形（山脉 / 水域）/ 已有建筑挡住的位置跳过。
##
## 这一套用例盯的是**权威判据**（world.build_reject_reason / build_anchors_for /
## build_wall_ring / zone.generate_build_points），界面拖拽的手感在 test_ui 里另有一条。
extends "res://tests/test_case.gd"

const CommandRes = preload("res://logic/command_processor.gd")
const LevelRes = preload("res://logic/level.gd")
const MapDataRes = preload("res://logic/map_data.gd")

func _initialize() -> void:
	_case_name = "test_build_points"
	run_all(_cases)

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_config(cfg)
	_test_map_reader(cfg)
	_test_level_counts(cfg)
	_test_points_are_valid(cfg)
	_test_generation(cfg)
	_test_placement_rules(cfg)
	_test_wall_ring(cfg)
	_test_anchors(cfg)


func _test_config(cfg) -> void:
	eq(cfg.build_points_per_zone, 2, "★ 每个区划 2 个建造点位（config.build.points_per_zone）")
	near(cfg.build_drop_radius_tiles, 1.5, 1e-6,
		"★ 拖放吸附半径 1.5 格（config.build.drop_radius_tiles）")
	eq(cfg.build_wall_ring_radius, 1, "★ 城墙环 1 层（区划中心 3×3 外圈）")


## ★★ 地图里遗留的 `zone_list[].build_points` **不再读**（点位改由关卡数量生成）。
func _test_map_reader(cfg) -> void:
	var m = MapDataRes.new()
	m._read_zones(cfg, [[0, 0], [0, 0]], [{
		"id": 0, "name": "甲", "center": [0, 0],
		"build_points": [[1, 0], [1, 1]],
	}])
	ok(m.get("zones_build_points") == null,
		"★★ 地图里的 build_points 不再读进 MapData（点位不属于地图了）")


## ★★ 关卡 `zones[].build_point_count` 的宽容读法：0 / 负数 / 缺键 / 非数字。
func _test_level_counts(_cfg) -> void:
	var d: Dictionary = LevelRes._read_zone_build_point_counts([
		{"id": 0, "build_point_count": 0},
		{"id": 1, "build_point_count": 3},
		{"id": 2, "build_point_count": -1},
		{"id": 3},
		{"id": 4, "build_point_count": "x"},
		"坏项",
	])
	eq(int(d.get(0, -99)), 0, "★★ 0 也读进来（明确不生成，不能当缺键）")
	eq(int(d.get(1, -99)), 3, "★ 正数读进来")
	eq(int(d.get(2, -99)), -1, "★ 负数原样收下（交给校验报）")
	ok(not d.has(3), "★ 缺键 = 不在这张表里（运行时用 config 默认 2）")
	ok(not d.has(4), "★ 非数字 = 不在这张表里")


## ★★ 每个区划的点位都必须是「它自己的地块、可通行、不在中心 / 城墙环上」。
func _test_points_are_valid(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var ring: int = cfg.build_wall_ring_radius
	var seen: Dictionary = {}
	var total := 0
	var zones_with_room := 0
	for z in w.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		var zid := int(zd.get("id", -1))
		var center: Variant = zd.get("center", null)
		var pts: Array = w.build_points_of_zone(zid)
		ok(pts.size() <= cfg.build_points_per_zone,
			"★ 区划 c%d 的点位不超过 %d 个（实际 %d）"
			% [zid, cfg.build_points_per_zone, pts.size()])
		if center != null and (zd.get("tiles", []) as Array).size() >= 8:
			zones_with_room += 1
			ok(pts.size() >= 1, "★ 区划 c%d 有地块就至少补得出 1 个点位" % zid)
		for p in pts:
			var t: Vector2i = p
			total += 1
			eq(w.build_point_zone(t.x, t.y), zid, "★ 点位落在它自己的区划里（c%d）" % zid)
			ok(w.map.terrain_walkable(t.x, t.y), "★ 点位是可通行地形（不能是山 / 水）")
			ok(w.building_at(t.x, t.y) == null,
				"★★ 点位没有压在已有建筑上（大本营 / 预置建筑都不行）")
			ok(not w.zones.is_no_go(zid, t.x, t.y),
				"★★ 点位不在边缘区里（生成规则）")
			if center != null:
				var c: Vector2i = center
				ok(t != c, "★ 点位不是区划中心那一格")
				ok(maxi(absi(t.x - c.x), absi(t.y - c.y)) > ring,
					"★ 点位不在中心 %d 格内的城墙环上" % ring)
			ok(not seen.has(t), "★ 点位不重复")
			seen[t] = true
	ok(zones_with_room > 0, "（前提）地图上有足够地块的区划")
	eq(seen.size(), total, "★ 全场点位去重后数量一致（%d 个）" % total)


## ★★ 落点规则：非城墙建筑只能落在己方区划的空点位上。
func _test_placement_rules(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var anchors: Array = w.build_anchors_for("tower", "p1")
	ok(not anchors.is_empty(), "（前提）p1 有空着的建造点位")
	if anchors.is_empty():
		return
	var a: Dictionary = anchors[0]
	var tile: Vector2i = a["tile"]
	ok(w.can_place_building("tower", tile.x, tile.y, "p1"), "★ 空点位可以建哨塔")

	# 己方区划里、但**不是**点位的空地：拒绝，拒因 not_build_point。
	var off := Vector2i(-1, -1)
	for ty in w.map.rows:
		for tx in w.map.cols:
			if w.build_point_zone(tx, ty) >= 0:
				continue
			if not w.zone_allows_build(tx, ty, "p1"):
				continue
			if w.can_build_at(tx, ty, "p1"):
				off = Vector2i(tx, ty)
				break
		if off.x >= 0:
			break
	ok(off.x >= 0, "（前提）己方区划里有非点位的空地")
	if off.x >= 0:
		eq(w.build_reject_reason("tower", off.x, off.y, "p1"), "not_build_point",
			"★★ 非建造点位 → not_build_point")
		ok(not w.can_place_building("tower", off.x, off.y, "p1"), "★★ 非点位不能建")

	# 点上已经有楼 → 这个点不再可用（锚点里也不该再出现）。
	w.add_building("tower", tile.x, tile.y, "p1", true, true)
	ok(not w.can_place_building("tower", tile.x, tile.y, "p1"), "★★ 点位被占后不能重复建")
	var after: Array = w.build_anchors_for("tower", "p1")
	var still := false
	for b in after:
		if Vector2i(b["tile"]) == tile:
			still = true
	if still:
		ok(false, "★★ 被占的点位不该再出现在可落点里")


## ★★ 随机生成：数量 / 0 = 不生成 / 排除边缘区 / 排除已有建筑 / 同种子可复现。
func _test_generation(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	# 找一个地块够多的区划，避免「候选不够」把断言搅浑。
	var zid := -1
	for z in w.zones.zones:
		var zd: Dictionary = z
		if (zd.get("tiles", []) as Array).size() >= 10:
			zid = int(zd.get("id", -1))
			break
	ok(zid >= 0, "（前提）有地块够多的区划")
	if zid < 0:
		return

	# 数量 0 → 一个都不生成。
	w.zones.generate_build_points(w.map, {zid: 0}, {}, 12345)
	eq(w.build_points_of_zone(zid).size(), 0, "★★ 数量 0 = 不生成任何点位")

	# 数量 3 → 生成 3 个（候选够时）；同一种子重算结果一致。
	w.zones.generate_build_points(w.map, {zid: 3}, {}, 12345)
	var pts: Array = w.build_points_of_zone(zid).duplicate()
	ok(pts.size() >= 1, "★ 数量 3 → 至少生成 1 个（候选不够时少生成，不报错）")
	if pts.is_empty():
		return
	w.zones.generate_build_points(w.map, {zid: 3}, {}, 12345)
	eq(w.build_points_of_zone(zid), pts, "★★ 同一种子重算 → 同一套点位（联机可复现）")

	# 边缘区：已有点位里拿一格标成边缘区 → 重新生成时它必须被排除。
	var edge_tile: Vector2i = pts[0]
	w.zones.apply_no_go({zid: [edge_tile]})
	w.zones.generate_build_points(w.map, {zid: 3}, {}, 12345)
	ok(not (w.build_points_of_zone(zid) as Array).has(edge_tile),
		"★★ 边缘区里的格子不会被选成建造点位")
	for p in w.build_points_of_zone(zid):
		var t: Vector2i = p
		ok(not w.zones.is_no_go(zid, t.x, t.y), "★ 生成的点位都不在边缘区里")
	w.zones.apply_no_go({})

	# 已有建筑：在第一个点位上盖楼 → 重新生成时该格被排除。
	pts = w.build_points_of_zone(zid).duplicate()
	var occ: Vector2i = pts[0]
	w.add_building("tower", occ.x, occ.y, "p1", true, true)
	var blocked: Dictionary = {}
	for b in w.building_list:
		if b != null and b.alive:
			blocked[Vector2i(int(b.tx), int(b.ty))] = true
	w.zones.generate_build_points(w.map, {zid: 3}, blocked, 12345)
	ok(not (w.build_points_of_zone(zid) as Array).has(occ),
		"★★ 已有建筑占的格不会被选成建造点位")
	for p in w.build_points_of_zone(zid):
		var t: Vector2i = p
		ok(w.building_at(t.x, t.y) == null, "★ 生成的点位都没有压在建筑上")
		ok(w.map.terrain_walkable(t.x, t.y), "★ 生成的点位都可通行")


## ★★ 2026.11.19（用户口径）：城墙不再能建造 —— 只能由战役编辑器预先摆放。
func _test_wall_ring(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	eq(w.build_anchors_for("wall", "p1").size(), 0,
		"★★ 木墙没有建造锚点（局内不能建造）")
	eq(w.build_anchors_for("stone_wall", "p1").size(), 0,
		"★★ 石墙也没有建造锚点")
	# 找一个己方区划中心（只用来验证「就算落点对也拒绝」）。
	var center := Vector2i(-1, -1)
	var zid := -1
	for z in w.zones.zones:
		if typeof(z) != TYPE_DICTIONARY:
			continue
		var zd: Dictionary = z
		if String(zd.get("owner", "")) != "p1":
			continue
		var cv: Variant = zd.get("center", null)
		if cv != null:
			center = cv
			zid = int(zd.get("id", -1))
			break
	ok(center.x >= 0 and zid >= 0, "（前提）p1 有区划中心")
	if center.x < 0 or zid < 0:
		return
	w.resources["food"] = 10000.0
	w.resources["gold"] = 10000.0
	var food_before := float(w.resources.get("food", 0.0))
	var wall_before := _wall_count(w)
	for bt in ["wall", "stone_wall"]:
		eq(w.build_reject_reason(String(bt), center.x, center.y, "p1"),
			"wall_preplaced", "★★ %s 的建造拒因 = wall_preplaced" % bt)
		ok(not CommandRes.apply(w, cfg, {
			"kind": "build", "build_type": String(bt), "zone_id": zid,
			"tx": center.x, "ty": center.y, "faction": "p1"}),
			"★★ 即使是区划中心，也不能建 %s" % bt)
		w.tick(0.01)
	eq(_wall_count(w), wall_before, "★★ 两条墙命令都没建出任何墙")
	near(float(w.resources.get("food", 0.0)), food_before, 0.5,
		"★★ 被拒时没有扣钱（tick 的产出误差不计）")

	# 设计师预置仍然可行：直接 `add_building`（战役编辑器走同一条路）。
	var ring: Array = w.wall_ring_buildable_tiles(zid, "p1")
	ok(not ring.is_empty(), "（前提）区划中心周围还有位置可以放预置城墙")
	if not ring.is_empty():
		var t: Vector2i = ring[0]
		ok(w.add_building("wall", t.x, t.y, "p1", true, true) != null,
			"★★ 预置（非建造命令）仍然能放城墙")
		eq(_wall_count(w), wall_before + 1, "★ 预置墙体真的出现在地图上")


func _wall_count(w) -> int:
	var n := 0
	for b in w.building_list:
		if b != null and b.alive and String(b.type) == "wall":
			n += 1
	return n


## ★★ 界面拖牌用的锚点：只看**己方**、城墙看中心、普通建筑看空点位。
func _test_anchors(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var pts: Array = w.build_anchors_for("tower", "p1")
	ok(not pts.is_empty(), "★ 非城墙建筑有锚点")
	for a in pts:
		var t: Vector2i = a["tile"]
		ok(w.build_point_zone(t.x, t.y) >= 0, "★ 普通锚点都是建造点位")
		var z = w.zones.zone_at(t.x, t.y)
		ok(z != null and String((z as Dictionary).get("owner", "")) == "p1",
			"★ 普通锚点只在己方区划里")
		ok(w.can_place_building("tower", t.x, t.y, "p1"), "★ 锚点当下确实能建")

	# ★★ 2026.11.19：城墙只能预置，没有运行时锚点 / 不能建造。
	eq(w.build_anchors_for("wall", "p1").size(), 0, "★★ 城墙没有运行时锚点")
	eq(w.build_anchors_for("stone_wall", "p1").size(), 0, "★★ 石墙也没有运行时锚点")

	# 别的阵营拿不到 p1 的点位；中立区划不算。
	var p2_pts: Array = w.build_anchors_for("tower", "p2")
	for a in p2_pts:
		var t: Vector2i = a["tile"]
		var z = w.zones.zone_at(t.x, t.y)
		ok(z != null and String((z as Dictionary).get("owner", "")) == "p2",
			"★ 锚点按下单方阵营过滤")
		ok(w.build_point_zone(t.x, t.y) >= 0, "★ 对方锚点也是点位")

	# 空阵营（观战 / 未选边）没有锚点。
	eq(w.build_anchors_for("tower", "").size(), 0, "★ 没有阵营 → 没有可落点")
