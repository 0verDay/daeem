## test_zone_capture.gd —— 区块占领的完整规则（手玩定的版本）
##
## 规则原话（手玩给的）：
##   1. 中立区块：**仅存在 A 方单位**时读 A 的条，满 → A 占领；
##      **同时存在 AB 方单位**时无法读条，若正在读某一方的条则**读条停止**；
##   2. A 方地块：**仅存在 B 方单位**时读 B 的条，满 → B 占领；同时在 AB → 无法读条、停止；
##   3. 特殊：A 读条中 B 进入并把 A 杀光 → A 的条**缓慢下降**，降到 0 之后才轮到读 B 的条；
##      A 读条中 A 的单位全移出区块 → A 的条缓慢下降至 0；
##   其余同上。
##
## 从这些规则能推出三条**实现上的硬约束**，这套断言就是围着它们写的：
##   · 同一时刻**最多只有一条**进度条（严格阻塞：别人没归零就不开读）—— UI 只画一条
##   · 双方同场时那条**冻住**（不涨不降不清零）—— UI 给它加白描边
##   · 只有「有进度但人不在场」才回落（缓慢：config 的 decay_per_sec = 0.125/秒）
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const FactionRes = preload("res://logic/faction.gd")

const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_zone_capture"
	run_all(_cases)


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


## 找一个无主区块里的空地
func _neutral_spot(w, cfg) -> Dictionary:
	for z in w.zones.zones:
		if String(z["owner"]) != "":
			continue
		var cx: int = (int(z["x0"]) + int(z["x1"])) / 2
		var cy: int = (int(z["y0"]) + int(z["y1"])) / 2
		for r in range(0, 6):
			for dy in range(-r, r + 1):
				for dx in range(-r, r + 1):
					var t := Vector2i(cx + dx, cy + dy)
					if w.can_build_at(t.x, t.y):
						return {"zone": z, "tile": t}
	return {}


## 把单位挪到某个地块中心（并同步 tx/ty）
func _put(u, tile: Vector2i, w) -> void:
	u.stop()
	u.pos = GridRes.center_of(tile)
	u.sync_tile(w.map)


## 让单位打不死（争抢/回落这类用例要的是稳定状态，不是把对方打死）
func _tough(u) -> void:
	u.hp_max = 99999.0
	u.hp = 99999.0


func _progress(z: Dictionary, faction: String) -> float:
	return float((z["progress_by"] as Dictionary).get(faction, 0.0))


func _state(z: Dictionary) -> String:
	return String(z["capture_state"])


func _bar_faction(z: Dictionary) -> String:
	return String(z["capture_faction"])


# ------------------------------------------------------------------
# 1. 中立区块 + 只有一方 → 读它的条，满则占领
# ------------------------------------------------------------------
func _test_solo_reading(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	ok(not spot.is_empty(), "找得到一个无主区块")
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]

	var g = w.unit_by_id("general-1")
	w.units = [g]                        # 隔离：只留一个单位
	_put(g, spot["tile"], w)
	eq(_state(z), "", "开局（还没 tick）没有进度条")
	w.tick(1.0)
	near(_progress(z, "p1"), 0.25, 1e-3, "★ 只有我的单位在区块里 → 读我的条（1 秒 = 25%）")
	eq(_state(z), "reading", "状态是「在读」")
	eq(_bar_faction(z), "p1", "这条条属于玩家")
	w.tick(1.0)
	near(_progress(z, "p1"), 0.5, 1e-3, "站 2 秒 → 50%")
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6, "对手那条一直是 0（严格阻塞：不能同时读）")
	for i in 3:
		w.tick(1.0)
	eq(String(z["owner"]), "p1", "读满 4 秒 → 区块归玩家")
	eq(String(z["claimed_by"]), "unit", "归属来源是「单位占领」")
	eq(_state(z), "", "占下来之后不再画条（底色表示归属）")
	near(float(z["progress"]), 0.0, 1e-6, "progress 汇总也跟着收掉")


# ------------------------------------------------------------------
# 2. 双方同场 → 无法读条；正在读的那条**冻住**
# ------------------------------------------------------------------
func _test_contested_freezes(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")
	w.units = [g]
	_put(g, spot["tile"], w)
	w.tick(2.0)
	var frozen_at := _progress(z, "p1")
	near(frozen_at, 0.5, 1e-3, "先让玩家读到 50%")

	# 敌人进入同一区块
	var e = w.spawn_enemy(spot["tile"].x + 1, spot["tile"].y)
	ok(e != null, "敌人进入同一区块")
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

	# 冻住不随时间变化（跑 3 秒还是原值，也没开始降）
	for i in 3:
		w.tick(1.0)
	near(_progress(z, "p1"), frozen_at, 1e-6, "★ 冻住不是下降：3 秒后还是 50%")
	eq(_state(z), "frozen", "状态仍然是冻住")


# ------------------------------------------------------------------
# 3. ★ A 读条中 B 进入并把 A 杀光 → A 缓慢降到 0 之后才读 B 的条
# ------------------------------------------------------------------
func _test_enemy_enters_then_wiped(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")
	w.units = [g]
	_put(g, spot["tile"], w)
	w.tick(2.0)
	near(_progress(z, "p1"), 0.5, 1e-3, "玩家先读到 50%")

	# 敌人的兵进来，然后把玩家清光（模拟击杀）
	var e = w.spawn_enemy(spot["tile"].x + 1, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true
	_tough(e)
	w.units = [g, e]
	w.tick(1.0)
	eq(_state(z), "frozen", "双方同场 → 先冻住")
	g.take_damage(cfg, w, 9999.0, null)
	w.units = [e]                        # 玩家单位已阵亡离场

	# A 的条开始缓慢下降（0.125/秒），B 还不能读（严格阻塞）
	w.tick(1.0)
	eq(_state(z), "decaying", "★ 读条方不在场 → 状态变成「回落」")
	near(_progress(z, "p1"), 0.375, 1e-3, "★ 回落速率 = config 的 0.125/秒（0.5 → 0.375）")
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6,
		"★★ B 还没开始读（严格阻塞：等 A 归零）")
	eq(_bar_faction(z), "p1", "条还是 A 那条（它正在退）")

	# 再跑几秒：A 归零，下一帧 B 才开始读
	for i in 3:
		w.tick(1.0)
	near(_progress(z, "p1"), 0.0, 1e-3, "A 的条降到 0（0.125/秒，3 秒后已归零）")
	w.tick(1.0)                          # ★ 归零那一帧还没轮到 B；下一帧才开读
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "★ A 归零之后，条换成了 B 的")
	eq(_state(z), "reading", "★ 这时才开始读 B 的条")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度在涨")

	# B 读满 → 占领
	for i in 5:
		w.tick(1.0)
	eq(String(z["owner"]), FactionRes.NPC_FACTION, "★ B 读满 4 秒 → 区块归 B")


# ------------------------------------------------------------------
# 4. A 读条中 A 的单位全移出区块 → 缓慢降至 0（B 不在场）
# ------------------------------------------------------------------
func _test_reader_leaves(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")
	w.units = [g]
	_put(g, spot["tile"], w)
	w.tick(2.0)
	near(_progress(z, "p1"), 0.5, 1e-3, "玩家读到 50%")

	# 走到区块外（挪到地图另一头）
	_put(g, Vector2i(0, w.map.rows - 1), w)
	w.tick(1.0)
	eq(_state(z), "decaying", "★ 人走了 → 状态是「回落」")
	near(_progress(z, "p1"), 0.375, 1e-3, "★ 1 秒退 0.125（0.5 → 0.375）")
	eq(_bar_faction(z), "p1", "退的还是玩家那条")

	var n := 0
	while _progress(z, "p1") > 0.0 and n < 600:
		w.tick(0.5)
		n += 1
	near(_progress(z, "p1"), 0.0, 1e-6, "★ 最终退到 0")
	eq(_state(z), "", "退完之后没有条可画")
	eq(String(z["owner"]), "", "区块仍然无主")


# ------------------------------------------------------------------
# 5. 已有主的区块：只有 B 在场 → 读 B 的条；读满 → 易主
# ------------------------------------------------------------------
func _test_owned_zone_flip(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")

	# 先让玩家占下来
	w.units = [g]
	_put(g, spot["tile"], w)
	for i in 5:
		w.tick(1.0)
	eq(String(z["owner"]), "p1", "玩家先占下这块地")

	# 玩家站着不动：主人不读条
	w.tick(1.0)
	eq(_state(z), "", "主人在自己的地里不读条")
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6, "对手也没进度")

	# 敌人独自进入（玩家撤走）→ 读敌人的条
	_put(g, Vector2i(0, w.map.rows - 1), w)
	var e = w.spawn_enemy(spot["tile"].x, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true
	_tough(g)
	_tough(e)
	w.units = [e]
	w.tick(1.0)
	eq(_state(z), "reading", "★ 地块已有主、只有 B 在场 → 读 B 的条")
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "条是 B 的")
	near(_progress(z, FactionRes.NPC_FACTION), 0.25, 1e-3, "B 的进度 25%")

	# A 的单位杀回来（放回区块里）→ 双方同场 → 停止
	_put(g, spot["tile"], w)
	w.units = [g, e]
	w.tick(1.0)
	eq(_state(z), "frozen", "★ 主家的兵回来 → 读条停止（冻住）")
	near(_progress(z, FactionRes.NPC_FACTION), 0.25, 1e-3, "B 的条冻在 25%")

	# 再把 B 清掉 → B 的条回落；A 是主人，本来就不读条
	e.take_damage(cfg, w, 9999.0, null)
	w.units = [g]
	w.tick(1.0)
	eq(_state(z), "decaying", "B 被清掉 → B 的条开始回落")
	ok(_progress(z, FactionRes.NPC_FACTION) < 0.25, "B 的进度在下降")
	eq(String(z["owner"]), "p1", "区块归属没变（还是玩家的）")


# ------------------------------------------------------------------
# 6. 严格阻塞：别人没归零，新来的一方不开读
# ------------------------------------------------------------------
func _test_strict_blocking(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")

	# A 读到 0.5 然后离开（开始回落）
	w.units = [g]
	_put(g, spot["tile"], w)
	w.tick(2.0)
	_put(g, Vector2i(0, w.map.rows - 1), w)
	w.tick(0.5)                          # A 退到 0.4375

	# B 独自进入：因为 A 还没归零，B 读不了
	var e = w.spawn_enemy(spot["tile"].x, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true
	w.units = [e]
	w.tick(1.0)
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6,
		"★ 严格阻塞：A 还没归零，B 一点都不涨")
	eq(_state(z), "decaying", "此时画面上的条仍然是 A 在回落")
	ok(_progress(z, "p1") < 0.4375, "A 继续回落")

	# 等 A 归零 → B 立刻开读
	var n := 0
	while _progress(z, "p1") > 0.0 and n < 600:
		w.tick(0.5)
		n += 1
	w.tick(1.0)
	eq(_state(z), "reading", "★ A 归零之后 B 才开始读")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度开始涨了")


# ------------------------------------------------------------------
# 7. ★ 同一时刻最多只有一条进度（UI 只画一条的前提）
# ------------------------------------------------------------------
func _test_no_two_bars(cfg) -> void:
	var w = WorldRes.create(cfg)
	var spot := _neutral_spot(w, cfg)
	if spot.is_empty():
		return
	var z: Dictionary = spot["zone"]
	var g = w.unit_by_id("general-1")
	var e = w.spawn_enemy(spot["tile"].x + 1, spot["tile"].y)
	if e == null:
		return
	e.hold_position = true

	# 把场景摆成「双方都在区块里、双方都想占」并跑一段时间，逐帧检查
	w.units = [g, e]
	_put(g, spot["tile"], w)
	_put(e, Vector2i(spot["tile"].x + 1, spot["tile"].y), w)
	var both := 0
	for i in 240:
		w.tick(DT)
		var p := _progress(z, "p1")
		var en := _progress(z, FactionRes.NPC_FACTION)
		if p > 1e-6 and en > 1e-6:
			both += 1
	eq(both, 0, "★★ 任何一帧都不会同时存在两条非零进度（严格阻塞的硬约束）")

	# 条只有一条：capture_bar 指向的那个阵营的进度 = progress 汇总
	var bar: Dictionary = w.zones.capture_bar(z)
	eq(float(bar["value"]), _progress(z, String(bar["faction"])),
		"capture_bar 给出的值就是那个阵营的进度")
	ok(["", "reading", "frozen", "decaying"].has(String(bar["state"])),
		"状态取值只有这四种")
