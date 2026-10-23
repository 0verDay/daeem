## test_zone_capture.gd —— 区块占领的完整规则（手玩定的版本）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const FactionRes = preload("res://logic/faction.gd")
const ZoneRes = preload("res://logic/zone.gd")

const DT := 1.0 / 60.0

func full_sec(cfg) -> float:
	return float(cfg.capture_time_sec)

func half_sec(cfg) -> float:
	return full_sec(cfg) * 0.5

func _run_to(w, z: Dictionary, faction: String, target: float) -> float:
	var v := _progress(z, faction)
	var guard := 0
	while v < target - 1e-9 and guard < 200000:
		w.tick(DT)
		v = _progress(z, faction)
		guard += 1
	return v

func _run_until_owner(w, z: Dictionary, owner: String) -> int:
	var n := 0
	while String(z["owner"]) != owner and n < 200000:
		w.tick(DT)
		n += 1
	return n

func _run_until_zero(w, z: Dictionary, faction: String) -> int:
	var n := 0
	while _progress(z, faction) > 0.0 and n < 200000:
		w.tick(DT)
		n += 1
	return n

func _initialize() -> void:
	_case_name = "test_zone_capture"
	run_all(_cases)
	cleanup_escort_scaffold()

func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	_test_solo_reading(cfg)
	_test_contested_freezes(cfg)
	_test_enemy_enters_then_wiped(cfg)
	_test_reader_leaves(cfg)
	_test_owned_zone_flip(cfg)
	_test_strict_blocking(cfg)
	_test_no_two_bars(cfg)
	_test_speed_curve(cfg)
	_test_requires_center_proximity(cfg)
	_test_auto_centers(cfg)

func _neutral_spot(w, cfg) -> Dictionary:
	for z in w.zones.zones:
		if String(z["owner"]) != "":
			continue
		var tiles := _ring_tiles(w, z, cfg)
		if tiles.size() >= 2:
			return {"zone": z, "tile": tiles[0], "tile2": tiles[1]}
	return {}

func _ring_tiles(w, z: Dictionary, cfg) -> Array:
	var r: int = maxi(0, int(cfg.zone_capture_radius_tiles))
	var c: Variant = z["center"]
	var out: Array = []
	if c == null:
		return out
	var center: Vector2i = c
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var t := Vector2i(center.x + dx, center.y + dy)
			if w.can_build_at(t.x, t.y):
				out.append(t)
	return out

func _put(u, tile: Vector2i, w) -> void:
	u.stop()
	u.pos = GridRes.center_of(tile)
	u.sync_tile(w.map)

func _tough(u) -> void:
	u.hp_max = 99999.0
	u.hp = 99999.0

func _progress(z: Dictionary, faction: String) -> float:
	return float((z["progress_by"] as Dictionary).get(faction, 0.0))

func _state(z: Dictionary) -> String:
	return String(z["capture_state"])

func _bar_faction(z: Dictionary) -> String:
	return String(z["capture_faction"])

func _test_solo_reading(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	ok(not spot.is_empty(), "找得到一个无主区块")
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]

	var g = w.unit_by_id("general-0")
	w.units = [g]                        # 隔离：只留一个单位
	_put(g, spot["tile"], w)
	eq(_state(z), "", "开局（还没 tick）没有进度条")
	w.tick(1.0)
	near(_progress(z, "p1"), 1.0 / full_sec(cfg), 1e-3,
		"★ 只有我的单位在区块里 → 读我的条（1 秒 = %.2f%%）" % (100.0 / full_sec(cfg)))
	eq(_state(z), "reading", "状态是「在读」")
	eq(_bar_faction(z), "p1", "这条条属于玩家")
	var half := _run_to(w, z, "p1", 0.5)
	near(half, 0.5, 0.02, "跑到一半（%.1f 秒的读条，实际停在 %.3f）" % [half_sec(cfg), half])
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6, "对手那条一直是 0（严格阻塞：不能同时读）")
	_run_until_owner(w, z, "p1")
	eq(String(z["owner"]), "p1", "★ 读满 %.0f 秒 → 区块归玩家" % full_sec(cfg))
	eq(String(z["claimed_by"]), "unit", "归属来源是「单位占领」")
	eq(_state(z), "", "占下来之后不再画条（底色表示归属）")
	near(float(z["progress"]), 0.0, 1e-6, "progress 汇总也跟着收掉")

func _test_contested_freezes(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")
	w.units = [g]
	_put(g, spot["tile"], w)
	var frozen_at := _run_to(w, z, "p1", 0.5)
	near(frozen_at, 0.5, 0.02, "先让玩家读到一半（%.1f 秒）" % half_sec(cfg))

	var e = w.spawn_enemy(spot["tile2"].x, spot["tile2"].y)
	ok(e != null, "敌人进入同一个中心邻域")
	if e == null:
		return
	e.hold_position = true               # 别让它跑掉
	_tough(g)                            # ⚠️ 双方都打不死：不然几秒后一方阵亡，争抢就结束了
	_tough(e)
	w.units = [g, e]

	w.tick(1.0)
	eq(_state(z), "frozen", "★ 双方同场 → 状态变成「冻住」")
	near(_progress(z, "p1"), frozen_at, 1e-6, "★★ 正在读的那条**一点都不涨**（读条停止）")
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6, "★ 后来这一方也读不了（无法读条）")
	eq(_bar_faction(z), "p1", "条还是玩家那条（冻住的是它）")

	for i in 3:
		w.tick(1.0)
	near(_progress(z, "p1"), frozen_at, 1e-6, "★ 冻住不是下降：3 秒后还是那个值")
	eq(_state(z), "frozen", "状态仍然是冻住")

func _test_enemy_enters_then_wiped(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")
	w.units = [g]
	_put(g, spot["tile"], w)
	var before := _run_to(w, z, "p1", 0.5)
	near(before, 0.5, 0.02, "玩家先读到一半（%.1f 秒）" % half_sec(cfg))

	var e = w.spawn_enemy(spot["tile2"].x, spot["tile2"].y)
	if e == null:
		return
	e.hold_position = true
	_tough(e)
	w.units = [g, e]
	w.tick(1.0)
	eq(_state(z), "frozen", "双方同场 → 先冻住")
	var frozen_v := _progress(z, "p1")
	g.take_damage(cfg, w, 9999.0, null)
	w.units = [e]                        # 玩家单位已阵亡离场

	var decay: float = float(cfg.decay_per_sec)
	w.tick(1.0)
	eq(_state(z), "decaying", "★ 读条方不在场 → 状态变成「回落」")
	near(_progress(z, "p1"), frozen_v - decay, 1e-3,
		"★ 回落速率 = config 的 %.4f/秒（冻结值 %.3f → %.3f）" % [decay, frozen_v, frozen_v - decay])
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6,
		"★★ B 还没开始读（严格阻塞：等 A 归零）")
	eq(_bar_faction(z), "p1", "条还是 A 那条（它正在退）")

	_run_until_zero(w, z, "p1")
	near(_progress(z, "p1"), 0.0, 1e-6, "A 的条降到 0（%.4f/秒，共约 %.0f 秒）" % [decay, 1.0 / decay])
	w.tick(1.0)                          # ★ 归零那一帧还没轮到 B；下一帧才开读
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "★ A 归零之后，条换成了 B 的")
	eq(_state(z), "reading", "★ 这时才开始读 B 的条")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度在涨")

	_run_until_owner(w, z, FactionRes.NPC_FACTION)
	eq(String(z["owner"]), FactionRes.NPC_FACTION, "★ B 读满 %.0f 秒 → 区块归 B" % full_sec(cfg))

func _test_reader_leaves(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")
	w.units = [g]
	_put(g, spot["tile"], w)
	var before_left := _run_to(w, z, "p1", 0.5)
	near(before_left, 0.5, 0.02, "玩家读到一半（%.1f 秒）" % half_sec(cfg))

	_put(g, Vector2i(0, w.map.rows - 1), w)
	var decay2: float = float(cfg.decay_per_sec)
	w.tick(1.0)
	eq(_state(z), "decaying", "★ 人走了 → 状态是「回落」")
	near(_progress(z, "p1"), before_left - decay2, 1e-3,
		"★ 1 秒退 %.4f（%.3f → %.3f）" % [decay2, before_left, before_left - decay2])
	eq(_bar_faction(z), "p1", "退的还是玩家那条")

	_run_until_zero(w, z, "p1")
	near(_progress(z, "p1"), 0.0, 1e-6, "★ 最终退到 0")
	eq(_state(z), "", "退完之后没有条可画")
	eq(String(z["owner"]), "", "区块仍然无主")

func _test_owned_zone_flip(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")

	w.units = [g]
	_put(g, spot["tile"], w)
	_run_until_owner(w, z, "p1")
	eq(String(z["owner"]), "p1", "玩家先占下这块地（%.0f 秒）" % full_sec(cfg))

	w.tick(1.0)
	eq(_state(z), "", "主人在自己的地里不读条")
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6, "对手也没进度")

	_put(g, Vector2i(0, w.map.rows - 1), w)
	var e = w.spawn_enemy(spot["tile"].x, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true
	_tough(g)
	_tough(e)
	w.units = [e]
	var read_to := _run_to(w, z, FactionRes.NPC_FACTION, 0.5)
	near(read_to, 0.5, 0.02, "★ 地块已有主、只有 B 在场 → 读 B 的条（读到一半）")
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "条是 B 的")

	_put(g, spot["tile"], w)
	w.units = [g, e]
	w.tick(1.0)
	eq(_state(z), "frozen", "★ 主家的兵回来 → 读条停止（冻住）")
	var b_at := _progress(z, FactionRes.NPC_FACTION)
	near(b_at, 0.5, 0.02, "B 的条冻在刚才那个值")

	_tough(e)
	e.take_damage(cfg, w, 9999.0, null)
	w.units = [g]
	w.tick(1.0)
	eq(_state(z), "decaying", "B 被清掉 → B 的条开始回落")
	ok(_progress(z, FactionRes.NPC_FACTION) < b_at, "B 的进度在下降")
	eq(String(z["owner"]), "p1", "区块归属没变（还是玩家的）")

func _test_strict_blocking(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")

	w.units = [g]
	_put(g, spot["tile"], w)
	var peak := _run_to(w, z, "p1", 0.5)
	_put(g, Vector2i(0, w.map.rows - 1), w)
	var dec3: float = float(cfg.decay_per_sec)
	w.tick(0.5)                          # A 退掉半秒的量
	var after_half := peak - dec3 * 0.5

	var e = w.spawn_enemy(spot["tile"].x, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true
	w.units = [e]
	w.tick(1.0)
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6,
		"★ 严格阻塞：A 还没归零，B 一点都不涨")
	eq(_state(z), "decaying", "此时画面上的条仍然是 A 在回落")
	ok(_progress(z, "p1") < after_half, "A 继续回落（%.3f < %.3f）" % [_progress(z, "p1"), after_half])

	_run_until_zero(w, z, "p1")
	w.tick(1.0)
	eq(_state(z), "reading", "★ A 归零之后 B 才开始读")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度开始涨了")

func _test_speed_curve(cfg) -> void:
	var spot := _neutral_spot(require_world(cfg), cfg)
	if spot.is_empty():
		ok(false, "人数加成用例需要一块无主区块")
		return

	var max_mult: float = float(cfg.zone_speed_max_mult)
	var k: float = float(cfg.zone_speed_curve_k)
	var p: float = float(cfg.zone_speed_curve_power)
	var zmod = ZoneRes

	near(zmod.speed_multiplier(1, max_mult, k, p), 1.0, 1e-9, "★ 1 人 = x1（基准速度）")
	for n in range(2, 11):
		var m: float = zmod.speed_multiplier(n, max_mult, k, p)
		ok(m > zmod.speed_multiplier(n - 1, max_mult, k, p) - 1e-9,
			"%d 人比 %d 人快（单调不减）" % [n, n - 1])
		ok(m < max_mult + 1e-9, "%d 人的倍率不超过上限 x%.1f" % [n, max_mult])
	ok(zmod.speed_multiplier(11, max_mult, k, p) > zmod.speed_multiplier(10, max_mult, k, p),
		"11 人仍然比 10 人快一点（渐近于上限，没有硬截断）")
	ok(zmod.speed_multiplier(10, max_mult, k, p) > 1.0 + 0.6 * (max_mult - 1.0),
		"★ 10 人明显接近上限（%.3f / %.1f）" % [zmod.speed_multiplier(10, max_mult, k, p), max_mult])

	var inc: Array[float] = []
	for n in range(2, 11):
		inc.append(zmod.speed_multiplier(n, max_mult, k, p)
			- zmod.speed_multiplier(n - 1, max_mult, k, p))
	ok(inc[0] <= inc[1],
		"★ 先慢后快：第 1 个新兵(+%.3f)不是收益最大的，第 2 个更大(+%.3f)" % [inc[0], inc[1]])
	ok(inc[1] > inc[2],
		"★ 峰值出现在第 2~3 个人之间（+%.3f > +%.3f），之后开始放缓" % [inc[1], inc[2]])
	var peak: float = inc[0]
	for v in inc:
		peak = maxf(peak, v)
	ok(inc[2] < peak and inc[5] < peak and inc[8] < peak,
		"★ 第 4 / 第 7 / 第 10 个人的收益都低于峰值（%.3f）" % peak)
	var early: float = zmod.speed_multiplier(3, max_mult, k, p) - 1.0
	var total: float = zmod.speed_multiplier(10, max_mult, k, p) - 1.0
	ok(early / total < 0.55,
		"★ 前 3 个人只拿到全部加成的 %.0f%%（先快后慢的话会明显过半）" % (early / total * 100.0))

	near(zmod.speed_multiplier(2, max_mult, k, p), 1.119, 1e-3, "★ 2 人 = x1.119")
	near(zmod.speed_multiplier(4, max_mult, k, p), 1.357, 1e-3, "★ 4 人 = x1.357")
	near(zmod.speed_multiplier(7, max_mult, k, p), 1.553, 1e-3, "★ 7 人 = x1.553")
	near(zmod.speed_multiplier(10, max_mult, k, p), 1.659, 1e-3, "★ 10 人 = x1.659")

	var w1 = require_world(cfg)
	var spot1 := _neutral_spot(w1, cfg)
	if spot1.is_empty():
		return
	var g1 = w1.unit_by_id("general-0")
	w1.units = [g1]
	_put(g1, spot1["tile"], w1)
	w1.tick(1.0)
	var solo: float = _progress(spot1["zone"], "p1")
	near(solo, 1.0 / full_sec(cfg), 1e-3, "1 人 1 秒 = 基准 %.3f" % (1.0 / full_sec(cfg)))

	var w2 = require_world_with_escorts(cfg, 2)
	var spot2 := _neutral_spot(w2, cfg)
	if spot2.is_empty():
		return
	var squad: Array = []
	for u2 in w2.units:
		if u2.faction == w2.my_faction and u2.alive and squad.size() < 4:
			squad.append(u2)
	eq(squad.size(), 4, "凑得出 4 个己方单位")
	if squad.size() < 4:
		return
	var tile2: Vector2i = spot2["tile"]
	w2.units = squad
	for i in squad.size():
		_put(squad[i], Vector2i(tile2.x, tile2.y), w2)
	w2.tick(1.0)
	var four: float = _progress(spot2["zone"], "p1")
	var expect4: float = 1.0 / full_sec(cfg) * zmod.speed_multiplier(4, max_mult, k, p)
	near(four, expect4, 1e-3,
		"★ 4 人 1 秒 = 基准 × %.3f（实际 %.4f，1 人是 %.4f）"
		% [zmod.speed_multiplier(4, max_mult, k, p), four, solo])
	ok(four > solo, "★ 人多确实读得更快（4 人 %.4f > 1 人 %.4f）" % [four, solo])

	var w3 = require_world(cfg)
	var spot3 := _neutral_spot(w3, cfg)
	if spot3.is_empty():
		return
	var g3 = w3.unit_by_id("general-0")
	var e3 = w3.spawn_enemy(spot3["tile2"].x, spot3["tile2"].y)
	if e3 == null:
		return
	e3.hold_position = true
	_put(g3, spot3["tile"], w3)
	_put(e3, spot3["tile2"], w3)
	w3.units = [g3, e3]
	w3.tick(1.0)
	near(_progress(spot3["zone"], "p1"), 0.0, 1e-6,
		"★ 双方同场时人数加成也救不了：玩家一点都读不动")
	near(_progress(spot3["zone"], FactionRes.NPC_FACTION), 0.0, 1e-6, "敌人同样读不动")

func _test_no_two_bars(cfg) -> void:
	var w = require_world(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-0")
	var e = w.spawn_enemy(spot["tile2"].x, spot["tile2"].y)
	if e == null:
		return
	e.hold_position = true

	w.units = [g, e]
	_put(g, spot["tile"], w)
	_put(e, spot["tile2"], w)
	var both := 0
	for i in 240:
		w.tick(DT)
		var p := _progress(z, "p1")
		var en := _progress(z, FactionRes.NPC_FACTION)
		if p > 1e-6 and en > 1e-6:
			both += 1
	eq(both, 0, "★★ 任何一帧都不会同时存在两条非零进度（严格阻塞的硬约束）")

	var bar: Dictionary = w.zones.capture_bar(z)
	eq(float(bar["value"]), _progress(z, String(bar["faction"])),
		"capture_bar 给出的值就是那个阵营的进度")
	ok(["", "reading", "frozen", "decaying"].has(String(bar["state"])),
		"状态取值只有这四种")

func _test_requires_center_proximity(cfg) -> void:
	var w = require_world(cfg)
	var g = w.unit_by_id("general-0")
	w.units = [g]

	var found: Dictionary = {}
	for z in w.zones.zones:
		if String(z["owner"]) != "":
			continue
		var ins := _ring_tiles(w, z, cfg)
		var outs: Variant = _outside_ring_tile(w, z, cfg)
		if not ins.is_empty() and outs != null:
			found = {"zone": z, "inside": ins[0], "outside": outs}
			break
	ok(not found.is_empty(), "★ 找得到一个「中心邻域内外都有空地」的无主区块")
	if found.is_empty():
		return
	var z: Dictionary = found["zone"]

	_put(g, found["inside"], w)
	w.tick(1.0)
	ok(_progress(z, "p1") > 0.0, "★ 站在中心 3×3 内 → 正常读条")
	eq(_state(z), "reading", "状态在读")

	_run_to(w, z, "p1", 0.5)
	var before := _progress(z, "p1")
	_put(g, found["outside"], w)
	var stayed: bool = w.zones.zone_at(int(found["outside"].x), int(found["outside"].y)) == z
	ok(stayed, "（前提）挪到的那一格仍在**本区块**里、但离中心更远")
	w.tick(1.0)
	ok(_progress(z, "p1") < before,
		"★★ 同区块但邻域外 → 不算在场（进度 %.4f → %.4f 开始回落）" % [before, _progress(z, "p1")])
	eq(_state(z), "decaying", "状态是「回落」")
	eq(String(z["owner"]), "", "★★ 离中心太远 ⇒ 占不下来（区块仍无主）")

func _outside_ring_tile(w, z: Dictionary, cfg) -> Variant:
	var r: int = maxi(0, int(cfg.zone_capture_radius_tiles))
	var c: Variant = z["center"]
	if c == null:
		return null
	var center: Vector2i = c
	var best: Variant = null
	var best_d := 1 << 30
	for t in z["tiles"]:
		var tile: Vector2i = t
		var d: int = maxi(absi(tile.x - center.x), absi(tile.y - center.y))
		if d <= r or d >= best_d:
			continue
		if not w.can_build_at(tile.x, tile.y):
			continue
		best = tile
		best_d = d
	return best

func _test_auto_centers(cfg) -> void:
	var map = require_map(cfg)
	if map == null:
		return
	map.zones_centers = {}
	var zs = ZoneRes.build_from_map(map, cfg, ["p1", "enemy"])
	ok(zs != null and zs.zones.size() > 0, "抹掉中心之后仍然建得出区块")
	if zs == null:
		return
	var missing := 0
	var outside := 0
	for z in zs.zones:
		if z["center"] == null:
			missing += 1
			continue
		var c: Vector2i = z["center"]
		if zs.lookup[c.y * zs.cols + c.x] != int(z["id"]):
			outside += 1
	eq(missing, 0, "★★ 每个区块都被补上了中心（不补的话它们永远占不了）")
	eq(outside, 0, "★ 补出来的中心落在**它自己的地块**上")
