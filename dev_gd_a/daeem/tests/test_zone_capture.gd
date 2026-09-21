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
##   · 只有「有进度但人不在场」才回落（缓慢：config 的 decay_per_sec 每秒）
##
## ★★ 下面的秒数全部走 `full_sec()` / `half_sec()`，**不写死任何绝对秒数**：
##   本轮需求把占领速度降到原来的 1/8（capture_time_sec 4 → 32）、回落降到 1/4
##    （decay_per_sec 0.125 → 0.03125），写死的 2 秒 / 5 秒 / 25% 会一次性全红。
##    现在「读到一半」永远是 `half_sec()`，config 再怎么调都只改这一处。
extends "res://tests/test_case.gd"

const GridRes = preload("res://logic/grid.gd")
const ConfigRes = preload("res://logic/config.gd")
const WorldRes = preload("res://logic/world.gd")
const FactionRes = preload("res://logic/faction.gd")
## ★ 人数加成曲线的静态函数在 zone.gd 上（speed_multiplier），直接 preload 调它 ——
##   命令行 --script 下全局 class_name 表不可用，跨文件引用必须走 preload 常量
##   （见 docs/pitfalls.md 第五节）。
const ZoneRes = preload("res://logic/zone.gd")

const DT := 1.0 / 60.0


## 1 个单位独自占满一条要多少秒（= config.zone.capture_time_sec）
func full_sec(cfg) -> float:
	return float(cfg.capture_time_sec)


## 读到一半（50%）要多少秒
func half_sec(cfg) -> float:
	return full_sec(cfg) * 0.5


## 跑到「进度到一个明确的值」为止（tick 累加，比写死秒数稳）
## ★ 不追求精确等于 target（浮点累加会有 1e-9 级误差），返回实际值供断言比较。
func _run_to(w, z: Dictionary, faction: String, target: float) -> float:
	var v := _progress(z, faction)
	var guard := 0
	while v < target - 1e-9 and guard < 200000:
		w.tick(DT)
		v = _progress(z, faction)
		guard += 1
	return v


## 跑到某一方**占下**这个区块为止（返回跑了几帧；guard 防死循环）
func _run_until_owner(w, z: Dictionary, owner: String) -> int:
	var n := 0
	while String(z["owner"]) != owner and n < 200000:
		w.tick(DT)
		n += 1
	return n


## 跑到某一方的进度归零为止
func _run_until_zero(w, z: Dictionary, faction: String) -> int:
	var n := 0
	while _progress(z, faction) > 0.0 and n < 200000:
		w.tick(DT)
		n += 1
	return n


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
	_test_speed_curve(cfg)


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
	# ★ 1 个单位的速率 = 1/full_sec（人数加成在 n=1 时正好是 x1，见 _test_speed_curve）
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
	var frozen_at := _run_to(w, z, "p1", 0.5)
	near(frozen_at, 0.5, 0.02, "先让玩家读到一半（%.1f 秒）" % half_sec(cfg))

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
	near(_progress(z, "p1"), frozen_at, 1e-6, "★ 冻住不是下降：3 秒后还是那个值")
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
	var before := _run_to(w, z, "p1", 0.5)
	near(before, 0.5, 0.02, "玩家先读到一半（%.1f 秒）" % half_sec(cfg))

	# 敌人的兵进来，然后把玩家清光（模拟击杀）
	var e = w.spawn_enemy(spot["tile"].x + 1, spot["tile"].y)
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

	# A 的条开始缓慢下降（decay_per_sec/秒），B 还不能读（严格阻塞）
	var decay: float = float(cfg.decay_per_sec)
	w.tick(1.0)
	eq(_state(z), "decaying", "★ 读条方不在场 → 状态变成「回落」")
	near(_progress(z, "p1"), frozen_v - decay, 1e-3,
		"★ 回落速率 = config 的 %.4f/秒（冻结值 %.3f → %.3f）" % [decay, frozen_v, frozen_v - decay])
	near(_progress(z, FactionRes.NPC_FACTION), 0.0, 1e-6,
		"★★ B 还没开始读（严格阻塞：等 A 归零）")
	eq(_bar_faction(z), "p1", "条还是 A 那条（它正在退）")

	# ★★★ 这里**必须用 while 跑到真的归零**，不能写死「跑 3 秒」：
	#    把满条退完要 1/decay_per_sec = %.0f 秒（本轮从 8 秒变成 32 秒），
	#    原来那句「for i in 3: tick(1.0) 后已归零」按新速率根本到不了 0。
	_run_until_zero(w, z, "p1")
	near(_progress(z, "p1"), 0.0, 1e-6, "A 的条降到 0（%.4f/秒，共约 %.0f 秒）" % [decay, 1.0 / decay])
	w.tick(1.0)                          # ★ 归零那一帧还没轮到 B；下一帧才开读
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "★ A 归零之后，条换成了 B 的")
	eq(_state(z), "reading", "★ 这时才开始读 B 的条")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度在涨")

	# B 读满 → 占领
	_run_until_owner(w, z, FactionRes.NPC_FACTION)
	eq(String(z["owner"]), FactionRes.NPC_FACTION, "★ B 读满 %.0f 秒 → 区块归 B" % full_sec(cfg))


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
	var before_left := _run_to(w, z, "p1", 0.5)
	near(before_left, 0.5, 0.02, "玩家读到一半（%.1f 秒）" % half_sec(cfg))

	# 走到区块外（挪到地图另一头）
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
	_run_until_owner(w, z, "p1")
	eq(String(z["owner"]), "p1", "玩家先占下这块地（%.0f 秒）" % full_sec(cfg))

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
	var read_to := _run_to(w, z, FactionRes.NPC_FACTION, 0.5)
	near(read_to, 0.5, 0.02, "★ 地块已有主、只有 B 在场 → 读 B 的条（读到一半）")
	eq(_bar_faction(z), FactionRes.NPC_FACTION, "条是 B 的")

	# A 的单位杀回来（放回区块里）→ 双方同场 → 停止
	_put(g, spot["tile"], w)
	w.units = [g, e]
	w.tick(1.0)
	eq(_state(z), "frozen", "★ 主家的兵回来 → 读条停止（冻住）")
	var b_at := _progress(z, FactionRes.NPC_FACTION)
	near(b_at, 0.5, 0.02, "B 的条冻在刚才那个值")

	# 再把 B 清掉 → B 的条回落；A 是主人，本来就不读条
	#
	# ⚠️ 这里必须先 `_tough(e)` 再打死它：`_tough(g)` 只让**玩家**打不死，
	#    而这一句要清掉的是**敌人** —— 不上就打不动它（take_damage 之后还活着），
	#    于是「敌人离场」这个前提根本没成立（本轮真踩过）。
	# ⚠️ 而且进度必须**读到一半再冻**：从 0 直接冻的话只有 dt 那么一点值，
	#    一帧回落（decay=0.03125/秒）就正好归零，state 会变成 ""（没条可画）
	#    而不是 "decaying" —— 那是「恰好退完」，不是功能坏了。
	_tough(e)
	e.take_damage(cfg, w, 9999.0, null)
	w.units = [g]
	w.tick(1.0)
	eq(_state(z), "decaying", "B 被清掉 → B 的条开始回落")
	ok(_progress(z, FactionRes.NPC_FACTION) < b_at, "B 的进度在下降")
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

	# A 读到一半然后离开（开始回落）
	w.units = [g]
	_put(g, spot["tile"], w)
	var peak := _run_to(w, z, "p1", 0.5)
	_put(g, Vector2i(0, w.map.rows - 1), w)
	var dec3: float = float(cfg.decay_per_sec)
	w.tick(0.5)                          # A 退掉半秒的量
	var after_half := peak - dec3 * 0.5

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
	ok(_progress(z, "p1") < after_half, "A 继续回落（%.3f < %.3f）" % [_progress(z, "p1"), after_half])

	# 等 A 归零 → B 立刻开读
	_run_until_zero(w, z, "p1")
	w.tick(1.0)
	eq(_state(z), "reading", "★ A 归零之后 B 才开始读")
	ok(_progress(z, FactionRes.NPC_FACTION) > 0.0, "B 的进度开始涨了")


## ------------------------------------------------------------------
## 8. ★★ 人数加成：同阵营单位越多读条越快（本轮新机制）
## ------------------------------------------------------------------
## 需求原话：「当 1 个单位占领某个区域时，速率为 x1，随着进入的友方单位增加，
##            速率会逐渐增加，到 10 人时速率趋近于最大值 x2」。
## 已确认口径：1 人 = 基准（capture_time_sec 那个速率）；倍率 =
##   1 + (max_mult - 1) × (n-1) / (n-1 + k)，S 型、k 默认 2.5、上限 x2。
##
## ★ 怎么造「同一方 N 个单位」：把这方的单位**逐个挪进区块**（不用真的招募——
##   招募要读条 10 秒，而这里要验的是占领速率）。
func _test_speed_curve(cfg) -> void:
	var spot := _neutral_spot(WorldRes.create(cfg), cfg)
	if spot.is_empty():
		ok(false, "人数加成用例需要一块无主区块")
		return

	var max_mult: float = float(cfg.zone_speed_max_mult)
	var k: float = float(cfg.zone_speed_curve_k)
	var p: float = float(cfg.zone_speed_curve_power)
	var zmod = ZoneRes

	# ---- 1) 曲线本身（纯静态函数，不依赖世界）----
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

	# ---- 2) ★★ 曲线形状：先慢后快（本轮返工两次才对的那一条）----
	#    「先快后慢」（也就是错的）长这样：p=1 时第 2 个人 +0.286，之后一路变小；
	#    「先慢后快」（需求要的）必须是：**前 1~3 个人的增量最小**，峰值不出现在最前面。
	#    引擎实测（k=2.5、p=1.7）：
	#      n1→2 +0.119　n2→3 +0.133　n3→4 +0.105　n4→5 +0.081 … n9→10 +0.029
	#    ⚠️ 用 p=1（纯 t）或 smoothstep 都会让这两条红 —— 它们是「先快后慢」。
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
	# 「先慢后快」的判定式：前 3 个人总共带来的增量 < 峰值那一段的 2 倍
	#   （如果曲线是先快后慢，前 3 个人就会吃掉绝大部分增量）
	var early: float = zmod.speed_multiplier(3, max_mult, k, p) - 1.0
	var total: float = zmod.speed_multiplier(10, max_mult, k, p) - 1.0
	ok(early / total < 0.55,
		"★ 前 3 个人只拿到全部加成的 %.0f%%（先快后慢的话会明显过半）" % (early / total * 100.0))

	# ---- 3) 曲线取值的**精确钉子**（k=2.5、p=1.7、上限 2.0）----
	#    改公式或改 k/p 时这几条会立刻红 —— 这正是它们的用处。
	#    数值由引擎实算（不是手算）：见 data/config.json 的 _capture_table_comment。
	near(zmod.speed_multiplier(2, max_mult, k, p), 1.119, 1e-3, "★ 2 人 = x1.119")
	near(zmod.speed_multiplier(4, max_mult, k, p), 1.357, 1e-3, "★ 4 人 = x1.357")
	near(zmod.speed_multiplier(7, max_mult, k, p), 1.553, 1e-3, "★ 7 人 = x1.553")
	near(zmod.speed_multiplier(10, max_mult, k, p), 1.659, 1e-3, "★ 10 人 = x1.659")

	# ---- 2) 真世界里对得上：1 人 vs 4 人，同样 tick 1 秒 ----
	var w1 = WorldRes.create(cfg)
	var spot1 := _neutral_spot(w1, cfg)
	if spot1.is_empty():
		return
	var g1 = w1.unit_by_id("general-1")
	w1.units = [g1]
	_put(g1, spot1["tile"], w1)
	w1.tick(1.0)
	var solo: float = _progress(spot1["zone"], "p1")
	near(solo, 1.0 / full_sec(cfg), 1e-3, "1 人 1 秒 = 基准 %.3f" % (1.0 / full_sec(cfg)))

	# 4 人：把同一方的 4 个单位塞进同一个区块
	var w2 = WorldRes.create(cfg)
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

	# ---- 3) 加成不能跨阵营：敌人也在场时谁都读不动（既有规则不受影响）----
	var w3 = WorldRes.create(cfg)
	var spot3 := _neutral_spot(w3, cfg)
	if spot3.is_empty():
		return
	var g3 = w3.unit_by_id("general-1")
	var e3 = w3.spawn_enemy(spot3["tile"].x + 1, spot3["tile"].y)
	if e3 == null:
		return
	e3.hold_position = true
	_put(g3, spot3["tile"], w3)
	_put(e3, Vector2i(spot3["tile"].x + 1, spot3["tile"].y), w3)
	w3.units = [g3, e3]
	w3.tick(1.0)
	near(_progress(spot3["zone"], "p1"), 0.0, 1e-6,
		"★ 双方同场时人数加成也救不了：玩家一点都读不动")
	near(_progress(spot3["zone"], FactionRes.NPC_FACTION), 0.0, 1e-6, "敌人同样读不动")


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
