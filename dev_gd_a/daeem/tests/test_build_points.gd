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


## ★★ 城墙环：一张牌建整圈；被建筑 / 地形挡住的位置跳过；只扣一张牌的费。
func _test_wall_ring(cfg) -> void:
	var w = require_world(cfg)
	if w == null:
		return
	var wall_anchors: Array = w.build_anchors_for("wall", "p1")
	ok(not wall_anchors.is_empty(), "（前提）p1 有可以围墙的区划中心")
	if wall_anchors.is_empty():
		return
	var wa: Dictionary = wall_anchors[0]
	var center: Vector2i = wa["tile"]
	var zid := int(wa["zone_id"])
	var ring_size: int = w.zones.wall_ring_tiles_of(zid).size()
	ok(ring_size >= 3 and ring_size <= 8,
		"（前提）几何城墙环最多 8 格（这张图这个中心在边上，实际 %d 格）" % ring_size)
	# ★ 环上**属于己方**、能建的那几格才是这一张牌真正要建的位置。
	#   （中心贴着区划边界时，环会有一部分落在邻区 —— 那些格子不是「自己的区划」，
	#     按「只能在自己区划里建造」的既有规则跳过；这是数据形状，不是 bug。）
	var owned_ring: Array = w.wall_ring_buildable_tiles(zid, "p1")
	ok(not owned_ring.is_empty(), "（前提）环上至少有几格属于自己的区划")
	if owned_ring.is_empty():
		return
	# 钱要够：整圈只扣**一张牌**的费。
	w.resources["food"] = 10000.0
	w.resources["gold"] = 10000.0

	# 先占掉环上一格（用一栋哨塔），再把另一格改成山 —— 两种遮挡都要被跳过。
	var occupied: Vector2i = owned_ring[0]
	w.add_building("tower", occupied.x, occupied.y, "p1", true, true)
	var mountain := Vector2i(-1, -1)
	for t in owned_ring:
		var tv: Vector2i = t
		if tv == occupied:
			continue
		w.map.terrain.set_cell(tv.x, tv.y, "mountain")
		mountain = tv
		break
	ok(mountain.x >= 0, "（前提）环上另有一格改成山脉")
	var expected: Array = w.wall_ring_buildable_tiles(zid, "p1")
	ok(expected.size() >= 1, "（前提）环上还剩能建的格子（实际 %d）" % expected.size())

	var wall_cost: Dictionary = cfg.building_def("wall").get("cost", {})
	var food_cost: float = float((wall_cost as Dictionary).get("food", 0.0))
	var food_before := float(w.resources.get("food", 0.0))
	var cmd := {"kind": "build", "build_type": "wall",
		"tx": center.x, "ty": center.y, "zone_id": zid, "faction": "p1"}
	ok(CommandRes.apply(w, cfg, cmd), "★★ 墙牌落在区划中心上被接受")
	var built := 0
	for t in expected:
		var tv: Vector2i = t
		var b = w.building_at(tv.x, tv.y)
		if b != null and String(b.type) == "wall":
			built += 1
	eq(built, expected.size(), "★★ 一张牌把环上所有空位建满（跳过建筑与山脉）")
	ok(w.building_at(occupied.x, occupied.y) != null
			and String(w.building_at(occupied.x, occupied.y).type) == "tower",
		"★★ 被建筑占住的位置保持原样（不在遮挡处重建）")
	ok(w.building_at(mountain.x, mountain.y) == null,
		"★★ 山脉那一格没有建墙")
	near(float(w.resources.get("food", 0.0)), food_before - food_cost, 1e-3,
		"★★ 整圈只扣**一张牌**的费用（%.0f）" % food_cost)

	# 环已经建满（剩下的位置全被挡住）：再建必须被拒，且不扣钱。
	var food_after := float(w.resources.get("food", 0.0))
	ok(not CommandRes.apply(w, cfg, cmd), "★★ 环上没有空位后不能再建墙")
	eq(w.build_reject_reason("wall", center.x, center.y, "p1"), "wall_no_space",
		"★★ 拒因 = wall_no_space")
	near(float(w.resources.get("food", 0.0)), food_after, 1e-3, "★★ 被拒时不扣钱")

	# 城墙的落点必须是区划中心（普通点位 → not_zone_center）。
	var tower_anchors: Array = w.build_anchors_for("tower", "p1")
	if not tower_anchors.is_empty():
		var pt: Vector2i = tower_anchors[0]["tile"]
		eq(w.build_reject_reason("wall", pt.x, pt.y, "p1"), "not_zone_center",
			"★★ 城墙不能建在普通点位上")


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

	var walls: Array = w.build_anchors_for("wall", "p1")
	ok(not walls.is_empty(), "★ 城墙有锚点（区划中心）")
	for a in walls:
		var t: Vector2i = a["tile"]
		ok(w.zone_center_zone_at(t.x, t.y) != null, "★ 城墙锚点都是区划中心")
		ok(w.can_place_building("wall", t.x, t.y, "p1"), "★ 城墙锚点当下确实能建")

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
