## test_path_feel.gd —— 寻路手感回归（拐角圆化 / 贴边落点 / 近距离点选）
##
## 这三条都是玩家报出来的「手感」问题，每一轮都能悄悄退回去，所以必须钉住：
##   1. 拐角生硬：单位是「走到路点才允许转向」，拐弯原本发生在一帧之内（实测 58°）
##   2. 点不可通行格：落点原本被钉在那一格的**格心**，跟你点格内哪个位置无关
##   3. 点自己脚下附近：原来会因为一个**像素口径**的阈值（0.5 = 半格）而一动不动。
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
## 一条真的有硬拐角的路线：**(0,3) → (2,7)**。
##
## ⚠️ 这条路线是怎么挑出来的：这张图里 p1 大本营周围有一根**区划中心**柱在 (0,5)，
##    旁边还有山，所以只能绕过去 —— 于是 A* 给的是「右 → 下 → 右」三段，
##    在 (1,5) 和 (1,6) 两个点各有一次约 45° 的转向（实测关掉圆化时单帧转角 45°）。
##    ⚠️ 换地图时这条也要跟着改：写死的坐标一旦落在山那边 / 直线上，
##       它就会变成一条直线，下面所有断言都会以「0.0°」的形式假失败。
## 一条真的有硬拐角的路线 —— 用**运行时挑**，不写死坐标。
##
## 为什么要挑而不写死：换地图时写死的坐标可能落在山那边 / 直线上，
##   于是「关掉圆化时单帧转角很大」这条断言会以 `0.0°` 的形式静默假失败
##   （换地图时真的踩到了，而且是**看起来像功能坏了**的那种失败）。
##   挑法：在候选路线里找「一条关掉圆化时 ≥3 点且单帧转角 > 25°」的路线。
##
## ⚠️ 候选表是**照着当前 `test_map.json`（27×22）实测挑的**（每组都是关掉圆化、
##    跑完全程、记录路径点与真实轨迹单帧转角得到的）。换图之后这一节最容易红。
##    红的时候先看打印出来的 `[corner]` 那几行：全是「路径 1 点 / 0.0°」就说明
##    这些坐标在新图上已经不成 L 形了 —— 用探针重新挑几条，别去改下面的阈值。
func _pick_corner_route(cfg) -> Dictionary:
	var candidates := [
		# 实测：5 点、单帧 90.0°（最典型的一条，也最磨不出别的毛病）
		[Vector2i(10, 10), Vector2i(4, 11)],
		# 实测：8 点、单帧 90.0°（地图东南角绕山）
		[Vector2i(18, 17), Vector2i(12, 14)],
		# 实测：5 点、71.5°
		[Vector2i(4, 6), Vector2i(25, 12)],
		# 实测：5 点、71.4°（拐弯最多的一条）
		[Vector2i(1, 3), Vector2i(18, 19)],
	]
	var was_enabled: bool = cfg.bool_val("path.corner_round_enabled", true)
	cfg.path_corner_round_enabled = false
	for c in candidates:
		var r: Dictionary = _run_move(cfg, c[0], GridRes.center_of(c[1]))
		print("   [corner] %s → %s：路径 %d 点，单帧最大转角 %.1f°" % [
			str(c[0]), str(c[1]), (r["path"] as Array).size(), float(r["max_turn"])])
		if (r["path"] as Array).size() >= 3 and float(r["max_turn"]) > 25.0:
			cfg.path_corner_round_enabled = was_enabled
			return {"from": c[0], "to": c[1], "raw": r}
	cfg.path_corner_round_enabled = was_enabled
	return {}


func _test_corner_rounding(cfg) -> void:
	var picked := _pick_corner_route(cfg)
	ok(not picked.is_empty(), "★ 找得到一条真有硬拐角的路线（换地图时这条要先过）")
	if picked.is_empty():
		return
	var from: Vector2i = picked["from"]
	var to: Vector2 = GridRes.center_of(picked["to"])
	var raw: Dictionary = picked["raw"]

	var was_enabled: bool = cfg.bool_val("path.corner_round_enabled", true)

	ok(float(raw["max_turn"]) > 20.0, "关闭圆化时单帧转角很大（实测 %.1f°，说明这条用例确实有硬拐角）" % raw["max_turn"])
	v2_near(raw["end"], to, 0.05, "关闭圆化时也能走到目标")

	cfg.path_corner_round_enabled = true
	var rounded := _run_move(cfg, from, to)
	ok((rounded["path"] as Array).size() > (raw["path"] as Array).size(),
		"★ 开启圆化后路径点变多（被细分成弧线）")
	ok(float(rounded["max_turn"]) < float(raw["max_turn"]) * 0.5,
		"★ 圆化把单帧转角压到原来的一半以下（%.1f° → %.1f°）" % [raw["max_turn"], rounded["max_turn"]])
	ok(float(rounded["max_turn"]) < 15.0, "★ 圆化后单帧转角小于 15°（实测 %.1f°）" % rounded["max_turn"])
	ok(int(rounded["frames"]) <= int(raw["frames"]) + 5, "圆化不会让路程变长（帧数 %d → %d）" % [raw["frames"], rounded["frames"]])
	v2_near(rounded["end"], to, 0.05, "★ 圆化后仍然精确到达点击位置（末点没被切掉）")

	cfg.path_corner_round_enabled = was_enabled

	# 直线路径不该被圆化动到（没有拐点）。
	# ⚠️ 走「一排干净地、且两端都在同一区块里」的横线：区划中心（中立障碍柱）会挡路，
	#    被挡住的直线会被拉直成好几个点 —— 验的就不是「圆化对直线无副作用」了。
	#    当前图上取 `y=14` 那一行的 x=6..11（实测关掉圆化时路径就是 1 个点）。
	var straight := _run_move(cfg, Vector2i(6, 14), GridRes.center_of(Vector2i(11, 14)))
	eq((straight["path"] as Array).size(), 1, "直线路径仍然是 1 个点（圆化对直线无副作用）")


# ------------------------------------------------------------------
# 2. 圆化后的路径不许把单位带进障碍里
# ------------------------------------------------------------------
func _test_rounded_path_is_walkable(cfg) -> void:
	var picked := _pick_corner_route(cfg)
	if picked.is_empty():
		ok(false, "圆化轨迹用例：先得挑到一条有拐角的路线")
		return
	var from: Vector2i = picked["from"]
	var to: Vector2 = GridRes.center_of(picked["to"])
	var r := _run_move(cfg, from, to)
	var w = r["world"]
	var u = r["unit"]
	var bad := 0
	for p in (r["trace"] as Array):
		var t := Vector2i(floori((p as Vector2).x), floori((p as Vector2).y))
		if not PathfinderRes.passable(w.map, w.buildings, cfg, t.x, t.y, u.faction):
			bad += 1
	eq(bad, 0, "★ 圆化后的轨迹全程都在可通行格上（没有靠圆角穿墙 / 翻山）")

	# 每个圆角段自身仍然必须过 segment_clear（这是「不穿墙」的机制性保证）
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
#    另：点到「己方打不进」的格子（敌方城墙）时，仍然要贴到离点击最近的边界上。
# ------------------------------------------------------------------
func _test_own_base_landing(cfg) -> void:
	var w = WorldRes.create(cfg)
	var b = w.find_base_of("p1")
	ok(b != null, "有大本营")
	if b == null:
		return
	var u = w.units[0]

	# ★ 从**南边的邻格**走近大本营，点在**大本营格内靠南**的位置。
	#
	# ⚠️ 起点不能写成「base + 4 格」：这张图上大本营的右上方有山、右边有墙，
	#    东边是一整排障碍 —— 那个起点根本走不到大本营，`order_move` 直接 false
	#    （实测：单位一步没动、距点击 3.6 格）。改成南边那一格（真正的邻格）。
	var click: Vector2 = Vector2(float(b.tx) + 0.9, float(b.ty) + 0.5)
	var start := Vector2i(b.tx, b.ty + 1)
	u.stop()
	u.pos = GridRes.center_of(start)
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, click), "点大本营：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	var center := GridRes.center_of(Vector2i(b.tx, b.ty))
	ok(u.pos.distance_to(click) < 0.45,
		"★ 己方单位直接走到了大本营本体上的点击处（距点击点 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.distance_to(center) < 0.5, "落点在目标格内")
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, u.tx, u.ty, u.faction),
		"★ 大本营那一格对己方是可通行的（本体不阻挡己方）")


## 「贴边落点」这套机制仍然要作用在**己方进不去**的格子（用到的 p2 的城墙）时，
## 落点贴到那格边界，而不是钉到格心或原地不动。
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
		"★ 落点贴着那堵墙（距点击点 %.3f 格）" % u.pos.distance_to(click))
	ok(u.pos.x <= float(spot.x) + 0.05,
		"★ 从左边来就停在墙的左边（贴边落点，不钉到格心）")


# ------------------------------------------------------------------
# 4. 点不可通行格（山 / 连片建筑内部）仍然要有合理落点
# ------------------------------------------------------------------
func _test_click_for_impassable(cfg) -> void:
	var w = WorldRes.create(cfg)
	var u = w.units[0]

	# 点一座山：必须给出落点、走得到、且停在可通行格上
	#
	# ⚠️ 不能「扫到第一座山就用」：这张图北边那片大片山在连通性修正封掉的
	#    p1 走不到的区域里，拿它当目标时 `order_move` 直接返回 false
	#    （实测：单位一步没动、距山格 2.236 格）。所以要求这座山
	#    **至少有一个邻格是 p1 真的走得到的**。
	var mountain := Vector2i(-1, -1)
	var region = PathfinderRes.reachable_tiles(w.map, w.buildings, cfg, Vector2i(u.tx, u.ty), u.faction)
	for y in w.map.rows:
		for x in w.map.cols:
			if w.map.terrain_walkable(x, y):
				continue
			for d in GridRes.DIRS8:
				var nb := Vector2i(x + d.x, y + d.y)
				if w.map.terrain.has(nb.x, nb.y) and PathfinderRes.in_region(region, w.map.terrain.idx(nb.x, nb.y)):
					mountain = Vector2i(x, y)
					break
			if mountain.x >= 0:
				break
		if mountain.x >= 0:
			break
	ok(mountain.x >= 0, "地图上有 p1 走得到的山")
	if mountain.x < 0:
		return
	# 起点：这座山旁边那一格（保证走得到，且是「从旁边点山」的入射方向）。
	var start := Vector2i(-1, -1)
	for d in GridRes.DIRS8:
		var nb := Vector2i(mountain.x + d.x, mountain.y + d.y)
		if w.map.terrain.has(nb.x, nb.y) and PathfinderRes.in_region(region, w.map.terrain.idx(nb.x, nb.y)):
			start = nb
			break
	u.stop()
	u.pos = GridRes.center_of(start)
	u.sync_tile(w.map)
	ok(u.order_move(w, cfg, GridRes.center_of(mountain)), "点山：命令被接受")
	var n := 0
	while u.moving and n < 3000:
		w.tick(DT)
		n += 1
	# 贴边落点会在山那一格的边缘上，所以不能要求「所处地块可通行」；
	# 要保证的是：离山边足够近，而且没有跑进山体内部（格心）。
	var mc := GridRes.center_of(mountain)
	ok(u.pos.distance_to(mc) <= 1.05, "点山后贴到了山边（距山格心 %.3f 格）" % u.pos.distance_to(mc))
	ok(not PathfinderRes.occupied(w.buildings, u.tx, u.ty), "点山后没停在建筑上")

	# 整格都不可通行时不能报错 / 不能失败：落点必须有效。
	var occ := PathfinderRes.occupied(w.buildings, u.tx, u.ty)
	ok(not occ, "落点有效（不是被占住的格子）")
