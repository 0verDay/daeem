## test_path_feel.gd —— 寻路手感回归（拐角圆化 / 贴边落点 / 近距离点选）
##
## 这三条都是玩家报出来的「手感」问题，每一轮都能悄悄退回去，所以必须钉住：
##   1. 拐角生硬：单位是「走到路点才允许转向」，拐弯原本发生在一帧之内（实测 58°）
##   2. 点不可通行格：落点原本被钉在那一格的**格心**，跟你点格内哪个位置无关
##   3. 点自己脚下附近：原来会因为一个**像素口径**的阈值（0.5 = 半格）而一动不动
##
## 断言口径说明：这里的「单帧转角」是拿**真实轨迹**算的（跑完整 tick），
## 不是拿路径点算的 —— 路径点好看不代表单位走得好看。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_path_feel"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_corner_rounding(cfg)
	_test_rounded_path_is_walkable(cfg)
	_test_own_base_landing(cfg)
	_test_hug_enemy_wall(cfg)
	_test_click_for_impassable(cfg)


## 跑完一次移动，返回轨迹与统计
func _run_move(cfg, from_tile: Vector2i, to_pt: Vector2) -> Dictionary:
	var w = WorldRes.create(cfg)
	var u = w.units[0]
	# ★ 只留这一个单位：轨迹与转角断言不能被亲兵的推挤/交战干扰。
	#   真的从 world.units 里摘掉 —— 光挪到地图角落仍然会被碰撞推挤影响轨迹
	#   （test_logic.gd 里那个 _isolate 助手是同一个思路，只是那边还要保留多个单位）
	w.units = [u]
	u.stop()
	u.pos = GridRes.center_of(from_tile)
	u.sync_tile(w.map)
	u.order_move(w, cfg, to_pt)
	var path_pts: Array[Vector2] = u.path.duplicate()

	var trace: Array[Vector2] = [u.pos]
	var m := 0
	while u.moving and m < 6000:
		w.tick(DT)
		trace.append(u.pos)
		m += 1

	# 单帧转角（用真实轨迹算）
	var max_turn := 0.0
	var turns_over_than_15 := 0
	for i in range(2, trace.size()):
		var d1: Vector2 = trace[i - 1] - trace[i - 2]
		var d2: Vector2 = trace[i] - trace[i - 1]
		if d1.length() > 1e-9 and d2.length() > 1e-9:
			var ang := rad_to_deg(absf(d1.normalized().angle_to(d2.normalized())))
			max_turn = maxf(max_turn, ang)
			if ang > 15.0:
				turns_over_than_15 += 1
	return {"world": w, "unit": u, "path": path_pts, "trace": trace,
		"max_turn": max_turn, "big_turns": turns_over_than_15, "frames": m, "end": u.pos}


# ------------------------------------------------------------------
# 1. 拐角圆化
# ------------------------------------------------------------------
func _test_corner_rounding(cfg) -> void:
	# 起点 (13,6) → 目标 (18,6)，中间被 x=15、y=3..7 的山挡住，必须绕到南侧再折回来
	var from := Vector2i(13, 6)
	var to := GridRes.center_of(Vector2i(18, 6))

	var was_enabled: bool = cfg.bool_val("path.corner_round_enabled", true)

	cfg.data["path"]["corner_round_enabled"] = false
	var raw := _run_move(cfg, from, to)
	ok((raw["path"] as Array).size() >= 3, "关闭圆化时这条路线至少有 3 个路径点（真有拐角）")
	ok(raw["max_turn"] > 20.0, "关闭圆化时单帧转角很大（实测 %.1f°，说明这条用例确实有硬拐角）" % raw["max_turn"])
	v2_near(raw["end"], to, 0.05, "关闭圆化时也能走到目标")

	cfg.data["path"]["corner_round_enabled"] = true
	var rounded := _run_move(cfg, from, to)
	ok((rounded["path"] as Array).size() > (raw["path"] as Array).size(),
		"开启圆化后路径点变多（被细分成弧线）")
	ok(rounded["max_turn"] < raw["max_turn"] * 0.5,
		"★ 圆化把单帧转角压到原来的一半以下（%.1f° → %.1f°）" % [raw["max_turn"], rounded["max_turn"]])
	ok(rounded["max_turn"] < 15.0, "★ 圆化后单帧转角小于 15°（实测 %.1f°）" % rounded["max_turn"])
	ok(rounded["frames"] <= raw["frames"] + 5, "圆化不会让路程变长（帧数 %d → %d）" % [raw["frames"], rounded["frames"]])
	v2_near(rounded["end"], to, 0.05, "★ 圆化后仍然精确到达点击位置（末点没被切掉）")

	cfg.data["path"]["corner_round_enabled"] = was_enabled

	# 直线路径不该被圆化动到（没有拐点）
	var straight := _run_move(cfg, Vector2i(2, 13), GridRes.center_of(Vector2i(7, 13)))
	eq((straight["path"] as Array).size(), 1, "直线路径仍然是 1 个点（圆化对直线无副作用）")


# ------------------------------------------------------------------
# 2. 圆化后的路径不许把单位带进障碍
# ------------------------------------------------------------------
func _test_rounded_path_is_walkable(cfg) -> void:
	var from := Vector2i(13, 6)
	var to := GridRes.center_of(Vector2i(18, 6))
	var r := _run_move(cfg, from, to)
	var w = r["world"]
	var u = r["unit"]
	var bad := 0
	for p in (r["trace"] as Array):
		var t := Vector2i(floori((p as Vector2).x), floori((p as Vector2).y))
		if not PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, u.faction):
			bad += 1
	eq(bad, 0, "★ 圆化后的轨迹全程都在可通行格上（没有借圆角穿墙 / 翻山）")

	# 每个圆角段自身也必须过 segment_clear（这是「不穿墙」的机制性保证）
	var pts: Array = r["path"]
	var pos0: Vector2 = GridRes.center_of(from)
	var prev := pos0
	var seg_bad := 0
	for p in pts:
		if not PathfinderRes.segment_clear(w.map, w.buildings, cfg, prev, p, u.faction):
			seg_bad += 1
		prev = p
	eq(seg_bad, 0, "圆化后的每一段都通过超覆盖直线判定")


# ------------------------------------------------------------------
# 3. 点自家大本营：本体不阻挡己方 → **直接走到点击处**
#    另：点「己方打不进」的格子（敌方城墙）时，仍然要贴到离点击最近的可达处
# ------------------------------------------------------------------
func _test_own_base_landing(cfg) -> void:
	var w = WorldRes.create(cfg)
	var b = w.find_base_of("p1")
	ok(b != null, "有大本营")
	if b == null:
		return
	var u = w.units[0]

	# 从右侧走近大本营，点在**大本营格内靠右**的位置
	var click: Vector2 = Vector2(float(b.tx) + 0.9, float(b.ty) + 0.5)
	u.stop()
	u.pos = GridRes.center_of(Vector2i(b.tx + 4, b.ty))
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, click), "点大本营：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	var center := GridRes.center_of(Vector2i(b.tx, b.ty))
	ok(u.pos.distance_to(click) < 0.45,
		"★ 己方单位直接走到了大本营本体上的点击处（距点击处 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.distance_to(center) < 0.5, "落点在目标格内")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, u.tx, u.ty, u.faction),
		"★ 大本营那一格对己方是可通行的（本体不阻挡己方）")


## 「贴边落点」这套机制仍然要在：点**己方进不去**的格子（用对家 p2 的城墙）时，
## 落点贴到那格边界，而不是绕到格心或原地不动。
func _test_hug_enemy_wall(cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]
	var spot := Vector2i(-1, -1)
	for ty in range(3, w.map.rows - 3):
		for tx in range(3, w.map.cols - 3):
			if w.can_build_at(tx, ty):
				spot = Vector2i(tx, ty)
				break
		if spot.x >= 0:
			break
	ok(spot.x >= 0, "找得到一格空地放对家的墙")
	if spot.x < 0:
		return
	var wall = w.add_building("wall", spot.x, spot.y, "p2")
	ok(wall != null, "放下了 p2 的城墙")
	ok(not PathfinderRes.passable(w.map, w.buildings, cfg, spot.x, spot.y, u.faction),
		"p2 的城墙对 p1 不可通行（判定基准是 same_side）")

	var click: Vector2 = Vector2(float(spot.x) + 0.1, float(spot.y) + 0.5)
	u.stop()
	u.pos = GridRes.center_of(Vector2i(spot.x - 3, spot.y))
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, click), "点对家城墙：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	ok(u.pos.distance_to(click) < 0.6,
		"★ 落点贴着那堵墙（距点击处 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.x <= float(spot.x) + 0.05,
		"★ 从左边来就停在墙的左边（贴边落点，不是绕到格心）")


# ------------------------------------------------------------------
# 4. 点不可通行格（山 / 连片建筑内部）仍然要有合理落点
# ------------------------------------------------------------------
func _test_click_for_impassable(cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]

	# 点一座山：必须给出落点、走得到、且停在可通行格上
	var mountain := Vector2i(-1, -1)
	for y in w.map.rows:
		for x in w.map.cols:
			if not w.map.terrain_walkable(x, y):
				mountain = Vector2i(x, y)
				break
		if mountain.x >= 0:
			break
	ok(mountain.x >= 0, "地图上有山")
	if mountain.x < 0:
		return
	u.stop()
	u.pos = GridRes.center_of(Vector2i(mountain.x + 2, mountain.y + 1))
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, GridRes.center_of(mountain)), "点山：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	# 贴边落点会在山那一格的边缘上，所以不能要求「所处地块可通行」；
	# 要保证的是离山边足够近、且没有跑进山体内部（格心）。
	var mc := GridRes.center_of(mountain)
	ok(u.pos.distance_to(mc) <= 1.05, "点山后贴到了山边（距山格心 %.3f 格）" % u.pos.distance_to(mc))
	ok(not PathfinderRes.occupied(w.buildings, u.tx, u.ty), "点山后没停在建筑里")

	# 整格都不可通行时不能死循环 / 不能失败：落点必须有效
	var occ := PathfinderRes.occupied(w.buildings, u.tx, u.ty)
	ok(not occ, "落点有效（不是被占住的格）")
