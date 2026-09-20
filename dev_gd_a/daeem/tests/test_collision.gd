## test_collision.gd —— 单位碰撞与局部避让（软分离 + 谁给谁让路）
##
## 这套测试盯的是四件容易悄悄错掉的事：
##   1. **软分离生效**：叠在同一格的单位会被分开（实测过：不写断言的话，
##      权重配错、迭代次数配 0、或者忘了在 world.tick 里调用，都不会报错）
##   2. **谁给谁让路**：有移动命令的推得动待命的（反过来不行）
##   3. **推挤不许破坏地形与建筑规则**：不能把单位推进山 / 敌方城墙里
##   4. **推挤只改位置、不改意图**：被推的单位不能忘了自己要去哪
##
## ★ 还要盯一条「反向」要求：**寻路必须仍然不认识单位**。
##   一旦有人把「别的单位占着这格」塞进 A*，两队兵就会互相把对方当墙 → 死锁。
##   见 logic/collision.gd 顶部那段说明。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CollisionRes = preload("res://logic/collision.gd")
const PathfinderRes = preload("res://logic/pathfinder.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_collision"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_radius_and_conf(cfg)
	_test_separation_happens(cfg)
	_test_soft_overlap_allowed(cfg)
	_test_commanded_pushes_idle(cfg)
	_test_push_respects_terrain(cfg)
	_test_push_keeps_intent(cfg)
	_test_idle_units_still_separate(cfg)
	_test_pathfinding_ignores_units(cfg)


## 参数与基本约定
func _test_radius_and_conf(cfg) -> void:
	var r: float = CollisionRes.radius(cfg)
	ok(r > 0.0, "碰撞半径是正数")
	ok(r < 0.5, "★ 碰撞半径远小于一格（%.2f 格）—— 单位本来就远小于地块" % r)
	var allowance: float = cfg.num("unit.overlap_allowance", 1.0)
	ok(allowance > 0.0 and allowance <= 1.0, "重叠允许比例在 (0, 1] 内")
	ok(cfg.num("unit.push_moving_weight", 0.0) + cfg.num("unit.push_idle_weight", 0.0) > 0.0,
		"★ 推力权重不能都是 0（那样谁也推不动谁，而且不会报错）")
	ok(cfg.bool_val("unit.collision_enabled", true), "默认开启碰撞")


## 硬分离：两个单位叠在同一点，跑一帧后必须被分开
func _test_separation_happens(cfg) -> void:
	var w = WorldRes.create(cfg)
	var a = w.units[0]
	var b = w.units[1]
	var tile := Vector2i(2, 13)
	a.stop()
	b.stop()
	# 刻意叠在**同一个坐标**上（圆心重合是最难的退化情况：没有方向可用）
	a.pos = GridRes.center_of(tile)
	b.pos = a.pos
	a.sync_tile(w.map)
	b.sync_tile(w.map)

	var before: float = a.pos.distance_to(b.pos)
	eq(before, 0.0, "先造出圆心完全重合的退化情况")
	w.tick(DT)
	var after: float = a.pos.distance_to(b.pos)
	ok(after > before, "★ 一帧之后被分开了（%.4f → %.4f）" % [before, after])

	# 跑一会儿应该稳定在「允许的最小距离」附近，并且不再抖
	var r: float = CollisionRes.radius(cfg)
	var allowance: float = cfg.num("unit.overlap_allowance", 0.7)
	var min_dist: float = r * 2.0 * allowance
	for i in 60:
		w.tick(DT)
	var d: float = a.pos.distance_to(b.pos)
	ok(d >= min_dist - 0.02, "稳定后距离不小于允许的最小距离（%.3f ≥ %.3f）" % [d, min_dist])
	ok(d <= min_dist + 0.15, "稳定后没有分得太开（%.3f）" % d)


## 软分离：允许少量重叠（overlap_allowance < 1 时不该硬顶到「刚好相切」）
func _test_soft_overlap_allowed(cfg) -> void:
	var r: float = CollisionRes.radius(cfg)
	var allowance: float = cfg.num("unit.overlap_allowance", 0.7)
	var hard: float = r * 2.0
	var soft: float = hard * allowance
	ok(soft < hard, "软分离的最小距离小于硬碰撞（%.3f < %.3f）" % [soft, hard])

	var w = WorldRes.create(cfg)
	var a = w.units[0]
	var b = w.units[1]
	var tile := Vector2i(2, 13)
	a.stop()
	b.stop()
	a.pos = GridRes.center_of(tile)
	b.pos = a.pos + Vector2(soft * 0.5, 0.0)      # 叠得比软下限还近
	a.sync_tile(w.map)
	b.sync_tile(w.map)
	for i in 30:
		w.tick(DT)
	var d: float = a.pos.distance_to(b.pos)
	ok(d >= soft - 0.02, "还是被推到了软下限之上（%.3f）" % d)
	ok(d < hard, "★ 停在软下限附近而不是硬相切（%.3f < %.3f）" % [d, hard])


## ★ 谁给谁让路：有移动命令的单位推得动待命的单位
func _test_commanded_pushes_idle(cfg) -> void:
	var r: float = CollisionRes.radius(cfg)
	var allowance: float = cfg.num("unit.overlap_allowance", 0.7)
	var soft: float = r * 2.0 * allowance

	var w = WorldRes.create(cfg)
	var mover = w.units[0]
	var idler = w.units[1]
	var tile := Vector2i(2, 13)
	mover.stop()
	idler.stop()
	mover.pos = GridRes.center_of(tile)
	idler.pos = mover.pos + Vector2(soft * 0.4, 0.0)
	mover.sync_tile(w.map)
	idler.sync_tile(w.map)

	# 让 mover 真的处于「有命令」状态（moving = true 且 path 非空）
	var ok_move: bool = mover.order_move(w, cfg, GridRes.center_of(Vector2i(8, 13)))
	ok(ok_move and mover.moving and mover.path.size() > 0, "mover 处于有命令状态")

	var mover_before: Vector2 = mover.pos
	var idler_before: Vector2 = idler.pos
	w.tick(DT)
	var mover_moved: float = mover.pos.distance_to(mover_before)
	var idler_moved: float = idler.pos.distance_to(idler_before)

	ok(idler_moved > 0.0, "待命的那个被推动了（%.4f 格）" % idler_moved)
	ok(idler_moved > mover_moved * 2.0,
		"★ 待命的那个被推得比有命令的多得多（%.4f vs %.4f）" % [idler_moved, mover_moved])

	# 反向验证：把 mover 的意图清掉，两个都是待命 → 应当各推一半
	var w2 = WorldRes.create(cfg)
	var a = w2.units[0]
	var b = w2.units[1]
	a.stop()
	b.stop()
	a.pos = GridRes.center_of(tile)
	b.pos = a.pos + Vector2(soft * 0.4, 0.0)
	a.sync_tile(w2.map)
	b.sync_tile(w2.map)
	var a_before: Vector2 = a.pos
	var b_before: Vector2 = b.pos
	w2.tick(DT)
	var da: float = a.pos.distance_to(a_before)
	var db: float = b.pos.distance_to(b_before)
	ok(da > 0.0 and db > 0.0, "两个都待命时双方都会被推开")
	ok(absf(da - db) < 0.02, "两个都待命时各推一半（%.4f vs %.4f）" % [da, db])


## 推挤不许把单位推进山里 / 推穿不能穿的建筑
func _test_push_respects_terrain(cfg) -> void:
	var w = WorldRes.create(cfg)
	# 找一处「可通行格紧挨着山」的位置
	var spot := Vector2i(-1, -1)
	var mtn := Vector2i(-1, -1)
	for y in range(0, w.map.rows - 1):
		for x in range(0, w.map.cols - 1):
			if w.map.terrain_walkable(x, y) and not w.map.terrain_walkable(x + 1, y):
				spot = Vector2i(x, y)
				mtn = Vector2i(x + 1, y)
				break
		if spot.x >= 0:
			break
	ok(spot.x >= 0, "找得到「紧挨着山」的空地")
	if spot.x < 0:
		return

	var r: float = CollisionRes.radius(cfg)
	var allowance: float = cfg.num("unit.overlap_allowance", 0.7)
	var soft: float = r * 2.0 * allowance

	var a = w.units[0]
	var b = w.units[1]
	a.stop()
	b.stop()
	# 把 a 紧贴山的右边界放，b 从左边压过来 → 推挤方向指向山里
	a.pos = Vector2(float(spot.x) + 1.0 - 0.02, float(spot.y) + 0.5)
	b.pos = a.pos - Vector2(soft * 0.5, 0.0)
	a.sync_tile(w.map)
	b.sync_tile(w.map)

	for i in 30:
		w.tick(DT)
	ok(w.map.terrain_walkable(a.tx, a.ty), "★ 被推的单位没有被推进山里")
	ok(w.map.terrain_walkable(b.tx, b.ty), "★ 推人的单位也没被反推进山里")


## ★ 推挤只改位置、不改意图：被推的单位不能忘了自己要去哪
func _test_push_keeps_intent(cfg) -> void:
	var w = WorldRes.create(cfg)
	var a = w.units[0]
	var b = w.units[1]
	var tile := Vector2i(2, 13)
	a.stop()
	b.stop()
	a.pos = GridRes.center_of(tile)
	b.pos = a.pos + Vector2(0.01, 0.0)
	a.sync_tile(w.map)
	b.sync_tile(w.map)

	var target := GridRes.center_of(Vector2i(9, 13))
	ok(b.order_move(w, cfg, target), "b 有移动命令")
	var goal_before: Vector2 = b.goal
	ok(b.moving, "b 正在移动")

	w.tick(DT)
	ok(b.moving, "★ 被推了一下之后仍然在移动（没有发呆）")
	v2_near(b.goal, goal_before, 1e-6, "★ 目标点没有被推挤改掉")

	# 跑到底：它必须仍然能走到目标附近（推挤不会让它永远到不了）
	var n := 0
	while b.moving and n < 3000:
		w.tick(DT)
		n += 1
	# 用「同一格」而不是「同一点」判定：路口被队友挤开是正常的
	var dt := Vector2i(floori(b.pos.x), floori(b.pos.y))
	var tt := Vector2i(floori(target.x), floori(target.y))
	ok(maxi(absi(dt.x - tt.x), absi(dt.y - tt.y)) <= 1,
		"被推挤之后仍然走到了目标附近（落点 %s，目标 %s）" % [str(b.pos), str(target)])


## 两个待命单位叠在一起时也要分开（否则出生点会一直叠着）——顺带验证这是稳定的
func _test_idle_units_still_separate(cfg) -> void:
	var w = WorldRes.create(cfg)
	var a = w.units[0]
	var b = w.units[1]
	var tile := Vector2i(2, 13)
	a.stop()
	b.stop()
	a.pos = GridRes.center_of(tile)
	b.pos = a.pos
	a.sync_tile(w.map)
	b.sync_tile(w.map)

	for i in 120:
		w.tick(DT)
	var d: float = a.pos.distance_to(b.pos)
	ok(d > 0.0, "两个待命单位最终也分开了（%.4f 格）" % d)

	# 稳定：再跑 60 帧位置不该来回抖
	var a_pos: Vector2 = a.pos
	var b_pos: Vector2 = b.pos
	for i in 60:
		w.tick(DT)
	ok(a.pos.distance_to(a_pos) < 0.02 and b.pos.distance_to(b_pos) < 0.02,
		"分开之后位置稳定（不再抖）")


## ★★ 反向要求：寻路必须仍然不认识单位
##
## 如果哪天有人把「别的单位占着这格」塞进 A*，两队兵就会互相把对方当墙 ——
## 双方都认为无路可走，于是死锁。这条断言把那个行为钉死在「不允许」。
func _test_pathfinding_ignores_units(cfg) -> void:
	var w = WorldRes.create(cfg)
	var a = w.units[0]
	var b = w.units[1]

	# 把 b 摆在 a 到目标的必经之路上（正中间那格）
	# ⚠️ 用 y=14 这一行：y=13 那一行每隔 4 格有一根区划中心（中立障碍柱），
	#    而 (5,13) 正好是其中一根 —— 那个断言验的是「站着**单位**的格子仍然可通行」，
	#    被障碍柱占着就变成在验另一件事了。
	var from := Vector2i(2, 14)
	var to := Vector2i(8, 14)
	a.stop()
	b.stop()
	a.pos = GridRes.center_of(from)
	b.pos = GridRes.center_of(Vector2i(5, 14))
	a.sync_tile(w.map)
	b.sync_tile(w.map)

	# 寻路结果必须与「路上有没有人」无关：同一条直线，长度不变
	var path = PathfinderRes.find_path(w.map, w.buildings, cfg, from, to, "p1")
	ok(path != null, "路中间站着一个单位时，寻路仍然成功")
	if path != null:
		var manhattan: int = absi(to.x - from.x) + absi(to.y - from.y)
		var oct := GridRes.octile_distance(to.x - from.x, to.y - from.y)
		ok((path as Array).size() <= int(oct + 0.5) + 1,
			"寻路没有被单位挡住而绕远（%d 步）" % (path as Array).size())

	# 单位也不会被当成不可通行
	ok(PathfinderRes.passable(w.map, w.buildings, cfg, b.tx, b.ty, "p1"),
		"★ 站着单位的格子对寻路仍然『可通行』（单位不进寻路）")

	# 端到端：a 真的能穿过 b 所在的位置走到目标
	ok(a.order_move(w, cfg, GridRes.center_of(to)), "a 收到移动命令")
	var n := 0
	while a.moving and n < 3000:
		w.tick(DT)
		n += 1
	var at := Vector2i(floori(a.pos.x), floori(a.pos.y))
	ok(maxi(absi(at.x - to.x), absi(at.y - to.y)) <= 1,
		"★ 路上有人也走到了目标（落点 %s）" % str(a.pos))
