## test_csharp_bridge.gd —— 阶段 0/1：C# 通路验证 + 与 GDScript 版的等价性
##
## 这个文件回答四件事，任何一条不成立，「把每帧逐单位工作下沉到 C#」的方案就不能走：
##   1. 无头测试模式（`--headless --script`）下 Godot 有没有加载 C# 程序集；
##   2. GDScript 能不能拿到 C# 对象、调实例方法、收到 Packed 数组回程；
##   3. 跨语言调用的粒度差多少（1000 次小调用 vs 1 次批量）—— 决定内核接口按「批」划；
##   4. ★★ 碰撞内核与 logic/collision.gd **算出来的位置是否一致** ——
##      这是「加速了但没改玩法」唯一可信的证据（不然手感悄悄变了没人知道）。
##
## ⚠️ 用 load() 而不是 preload()：--script 启动时全局类表不可用（见 test_case.gd 的说明）。
##    而且 load 失败时能干净地记一条失败断言，而不是整个文件 Parse Error。
extends "res://tests/test_case.gd"

const PROBE_PATH := "res://logic/crowd/CrowdProbe.cs"
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")
const CombatRes = preload("res://logic/combat.gd")
const FactionRes = preload("res://logic/faction.gd")

const N := 1000
const DT := 1.0 / 60.0


func _initialize() -> void:
	_case_name = "test_csharp_bridge"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return

	var probe = _load_probe()
	if probe == null:
		return

	# 1) 程序集确实加载了，而且是这一份构建
	eq(probe.BuildTag(), "daeem-csharp-bridge-1", "C# 程序集已加载且标记匹配")
	eq(probe.Ping(), 42, "C# 实例方法可调用")

	# 2) 批量入参 / 出参两条路都通
	var values := PackedFloat64Array()
	values.resize(N)
	for i in N:
		values[i] = 1.0
	eq(probe.SumDoubles(values), float(N), "批量入参（PackedFloat64Array %d 个元素）正确" % N)

	var src := PackedFloat32Array()
	src.resize(N)
	for i in N:
		src[i] = float(i)
	var doubled: PackedFloat32Array = probe.Twice(src)
	eq(doubled.size(), N, "批量出参（PackedFloat32Array）长度正确")
	eq(doubled[N - 1], float((N - 1) * 2), "批量出参内容正确")

	# 3) 粒度对比：只打印，不断言（时间随机器波动，写成断言会变成随机红灯）
	_report_granularity(probe)

	# 4) ★ 等价性：两套实现必须算出同一个结果
	_test_kernel_is_active(cfg)
	_test_collision_matches_gdscript(cfg)
	_test_targeting_matches_gdscript(cfg)
	_test_targeting_with_filtered_units(cfg)
	_test_no_friendly_fire(cfg)


## ★★ 索敌结果**绝不能指向同一方的单位**（手玩报的 bug：新生成的友军单位有的会打友军）。
##
## 根因在下标映射那条「图快」的捷径上：
##   第一遍打包会**跳过**「在赶路」的单位（它们这一帧不索敌），第二遍再把它们
##   **追加到末尾**；而写回结果时写的是 `if m == n: _target_idx = res` ——
##   以为「打包个数 == 单位个数」就等于「打包下标 == 单位下标」。
##   **不等价**：只要被跳过的单位不全在数组末尾，打包顺序就是被打乱的，而 m 照样能凑到 n。
##
## 串位之后的症状正是友军误伤：某个自己人读到了**敌方那一格**的结果，
## 而那一格的目标恰好是一个自己人 → 它把友军当成敌人（`acquire_target` 信任内核结果，
## 拿到就直接锁定，不会再判一次阵营）。
##
## ⚠️ 为什么以前抓不到：老用例里「移动中的单位」都排在数组**最前面或最后面**，
##    顺序刚好没被打乱（见 _test_targeting_with_filtered_units 的注释）——
##    必须让「移动中的自己人」夹在站定的自己人中间才会露出来。
func _test_no_friendly_fire(cfg) -> void:
	var w = WorldRes.create(cfg)
	if w.crowd == null or not w.crowd.available():
		ok(false, "C# 索敌内核可用（友军误伤是内核结果的下标映射问题）")
		return

	# 自己人 4 个（第 2 个在赶路，**夹在中间**），敌人 4 个站定（让两边都在索敌）
	var batch: Array = []
	for i in 4:
		var u = UnitRes.create(cfg, "ff-a-%d" % i, "a", Vector2i(0, 0), "p1", UnitRes.KIND_SUBORDINATE)
		u.pos = Vector2(10.5, 8.5 + float(i) * 0.5)
		u.sync_tile(w.map)
		batch.append(u)
	for i in 4:
		var e = UnitRes.create(cfg, "ff-b-%d" % i, "b", Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
		e.pos = Vector2(12.5, 8.5 + float(i) * 0.5)
		e.sync_tile(w.map)
		batch.append(e)
	# ★ 第 2 个自己人「在赶路」：第一遍会被跳过、第二遍被追加到末尾 → 顺序被打乱
	batch[1].moving = true
	batch[1].has_goal = true
	w.units = batch

	w.tick(DT)

	# 1) 桥上的原始映射（绕过一切下游守卫，直接验「打包下标 → 单位下标」）
	var raw_bad := 0
	var raw_first := ""
	for i in w.units.size():
		var raw = w.crowd.target_at(w, i)
		if raw == null:
			continue
		if FactionRes.same_side(String(raw.faction), String((w.units[i] as Variant).faction)):
			raw_bad += 1
			if raw_first == "":
				raw_first = "%s 指向了友军 %s" % [(w.units[i] as Variant).id, raw.id]
	eq(raw_bad, 0, "★ 内核返回的目标永远不是同一方（串位 %d 个；%s）" % [raw_bad, raw_first])

	# 2) 真正落到单位上的目标（下游还会再判一道阵营，这里验的是「整条链」）
	var bad := 0
	var first := ""
	for u in w.units:
		if u.target == null:
			continue
		if FactionRes.same_side(String(u.target.faction), String(u.faction)):
			bad += 1
			if first == "":
				first = "%s 把 %s 当成了敌人" % [u.id, u.target.id]
	eq(bad, 0, "★ 没有任何单位把友军当成目标（%d 个；%s）" % [bad, first])


## ★★ 「有单位被过滤掉」时的索敌必须仍然正确。
##
## 这是第 7 轮引入过的**真 bug** 的回归：索敌只把「本帧会被问到」的单位打包进内核
## （索敌方 + 可能成为目标的敌方），而内核返回的是**打包数组里的下标** ——
## 调用方要的是**单位下标**，忘了翻译就会串位：索敌索到无关的单位，
## 或者拿不到位子退回去扫建筑（表现就是「错过近处的敌人去打远处的墙」）。
##
## ⚠️ 为什么常规验证都抓不到它：
##   · 单元测试里单位少，几乎总是**全部打包** → 两种下标恰好相等 → 正确；
##   · 1000 单位基准只有**一个阵营**、没有敌人 → 内核结果全是 -1 → 映射错了也看不出来。
##   暴露条件是「大批自己人在行军（被过滤）+ 有敌人」—— 也就是真实对局。
func _test_targeting_with_filtered_units(cfg) -> void:
	var w = WorldRes.create(cfg)
	w.tick(DT)                       # 先建表

	# 30 个自己人排在**最前面**、并且处于「移动中」→ 会被索敌过滤掉
	# ⚠️ `path` 是 Array[Vector2]（有类型的数组），必须用同样带类型的变量装，
	#    直接赋 `[Vector2(...)]` 字面量会报类型错、整个函数静默中止（断言一条都不跑）。
	var fake_path: Array[Vector2] = [Vector2(8.0, 18.0)]
	var batch: Array = []
	for i in 30:
		var m = UnitRes.create(cfg, "flt-m%d" % i, "m", Vector2i(0, 0), "p1", UnitRes.KIND_SUBORDINATE)
		m.pos = Vector2(6.0 + float(i % 6) * 0.4, 20.0 + float(i / 6) * 0.4)
		m.sync_tile(w.map)
		m.moving = true
		m.has_goal = true
		m.path = fake_path
		batch.append(m)

	# 被测的索敌者：一个**待命**的自己人
	var spot := Vector2(10.5, 10.5)
	var watcher = UnitRes.create(cfg, "flt-w", "w", Vector2i(0, 0), "p1", UnitRes.KIND_SUBORDINATE)
	watcher.pos = spot
	watcher.sync_tile(w.map)
	batch.append(watcher)

	# 三个敌人：最近的那个是明确答案。
	# ⚠️ 把它们标成「移动中」是为了让它们**不进索敌方**（否则双方都在索敌，
	#    过滤就退化成「全部打包」，这条测试也就验不到下标映射了）。
	#    路径留空 → 它们这一帧不会真的动。
	var want = UnitRes.create(cfg, "flt-e0", "e", Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
	want.pos = spot + Vector2(1.5, 0.0)
	want.sync_tile(w.map)
	want.moving = true
	batch.append(want)
	for i in 2:
		var far = UnitRes.create(cfg, "flt-e%d" % (i + 1), "e", Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
		far.pos = spot + Vector2(0.0, 2.5 + float(i))
		far.sync_tile(w.map)
		far.moving = true
		batch.append(far)

	w.units = batch
	var wi: int = batch.find(watcher)
	w.tick(DT)                       # refresh_targets + update_unit 都在这一帧里

	ok(w.crowd != null and w.crowd.available(), "C# 索敌内核可用")
	eq(watcher.target, want, "★ 有自己人在行军被过滤掉时，仍然锁定**最近的那个敌人**")
	eq(w.crowd.target_at(w, wi), want, "★ 内核查询接口返回同一个敌人（打包下标 → 单位下标没串位）")


## ★★ 警戒索敌的两套实现必须挑出**同一个**目标。
##
## 为什么这条重要：内核版把「每个待命单位扫一遍全部单位」的 O(n²) 换成了按阵营分组，
## 判定条件写了三处（敌对 = 阵营下标不同 / 命中 = 距离−体积 ≤ 警戒 / 取最近且平局取小下标），
## 任何一处写错都不会报错，只会表现成「单位有时不还手」「打近的反而追远的」。
func _test_targeting_matches_gdscript(cfg) -> void:
	var w = WorldRes.create(cfg)
	if w.crowd == null or not w.crowd.available():
		ok(false, "C# 索敌内核可用")
		return

	# 造两拨人：p1 一拨、enemy 一拨，位置固定（确定性，便于比对）
	var batch: Array = []
	for i in 12:
		var u = UnitRes.create(cfg, "tg-a-%d" % i, "a", Vector2i(0, 0), "p1", UnitRes.KIND_SUBORDINATE)
		u.pos = Vector2(4.0 + float(i % 4) * 1.3, 6.0 + float(i / 4) * 1.1)
		u.sync_tile(w.map)
		batch.append(u)
	for i in 12:
		var e = UnitRes.create(cfg, "tg-b-%d" % i, "b", Vector2i(0, 0), "enemy", UnitRes.KIND_ENEMY)
		e.pos = Vector2(5.1 + float(i % 4) * 1.3, 7.2 + float(i / 4) * 1.1)
		e.sync_tile(w.map)
		batch.append(e)
	w.units = batch

	w.tick(DT)                       # 让 refresh_targets 跑一次（结果按 frame_serial 对齐）

	# 内核给出的选择
	var kernel_pick: Array = []
	for i in w.units.size():
		var t = w.crowd.target_at(w, i)
		kernel_pick.append(-1 if t == null else w.units.find(t))

	# 参考实现：传 idx = -1 → 强制走 combat.acquire_target 里的逐个扫描分支
	var ref_pick: Array = []
	for i in w.units.size():
		var u = w.units[i]
		u.target = null
		CombatRes.acquire_target(w, cfg, u, -1)
		ref_pick.append(-1 if u.target == null else w.units.find(u.target))

	var mismatch := 0
	var first_bad := ""
	for i in kernel_pick.size():
		if int(kernel_pick[i]) != int(ref_pick[i]):
			mismatch += 1
			if first_bad == "":
				first_bad = "单位 %d：内核=%d 参考=%d" % [i, int(kernel_pick[i]), int(ref_pick[i])]
	ok(w.units.size() == 24, "造出两拨人（%d 个）" % w.units.size())
	ok(kernel_pick.filter(func(x): return int(x) >= 0).size() > 0, "内核确实挑出了目标（不是全空）")
	eq(mismatch, 0, "★ 内核索敌与 GDScript 版挑出同一个目标（不一致 %d 个；%s）" % [mismatch, first_bad])


## 碰撞内核真的被挂上了吗（否则「测试全绿」可能只是悄悄退回了慢路径）
func _test_kernel_is_active(cfg) -> void:
	var w = WorldRes.create(cfg)
	ok(w.crowd != null, "world 建出了碰撞桥")
	if w.crowd == null:
		return
	ok(w.crowd.available(), "★ C# 碰撞内核可用（说明跑的是加速路径，不是 GDScript 回退）")
	eq(cfg.str_val("unit.collision_backend", "csharp"), "csharp", "config 默认走 C# 后端")


## ★★ 等价性对照：同一批单位、同一份抖动，两套实现跑完后的位置必须一致。
##
## 为什么这条断言最重要：性能可以慢慢调，但「换了个碰撞实现、手感悄悄变了」
## 是没人能靠肉眼发现的那类问题。这条断言把它变成红灯。
##
## 用 8 个**刻意挤在一起**的单位（含一个正在移动的，好让推力权重的那条分支也走到），
## 跑 40 帧 —— 挤得越厉害，配对顺序的影响越大，越能抓出实现差异。
func _test_collision_matches_gdscript(cfg) -> void:
	var slow := _run_overlap_scenario(cfg, "gdscript")
	var fast := _run_overlap_scenario(cfg, "csharp")
	if slow.size() != fast.size() or slow.is_empty():
		ok(false, "两个场景应当产出同样多的单位")
		return
	var worst := 0.0
	for i in slow.size():
		worst = maxf(worst, (slow[i] as Vector2).distance_to(fast[i]))
	ok(worst < 1e-4, "★ C# 内核与 GDScript 版位置一致（最大偏差 %.6f 格）" % worst)


func _run_overlap_scenario(cfg, backend: String) -> Array:
	# ★ 用 cfg 上的字段切后端（不再是改 cfg.data —— 那些值现在都是载入时算好的）
	cfg.unit_collision_backend = backend
	var w = WorldRes.create(cfg)
	# ★ 只留这一批：将领/亲兵的推挤会把对照搅浑
	var batch: Array = []
	for i in 8:
		var u = UnitRes.create(
			cfg, "eq-%d" % i, "eq", Vector2i(2, 13), w.my_faction, UnitRes.KIND_SUBORDINATE
		)
		# 4 个一列、两行，间距远小于最小圆心距（0.252）→ 一开始就全在互相重叠
		u.pos = Vector2(2.5 + float(i % 4) * 0.05, 13.5 + float(i / 4) * 0.04)
		u.sync_tile(w.map)
		batch.append(u)
	w.units = batch
	# 让其中一个有移动命令：推力权重那条分支（有命令的推得动待命的）才会被走到
	batch[0].order_move(w, cfg, Vector2(8.5, 13.5))

	for _f in 40:
		w.tick(DT)

	var out: Array = []
	for u in w.units:
		out.append(u.pos)
	cfg.unit_collision_backend = "csharp"   # 复原，别影响后面的用例
	return out


func _load_probe():
	var s = load(PROBE_PATH)
	if s == null:
		ok(false, "C# 脚本能载入：%s（引擎必须是 mono 版，且工程已用 dotnet build 构建）" % PROBE_PATH)
		return null
	var probe = s.new()
	if probe == null:
		ok(false, "C# 类能实例化：%s" % PROBE_PATH)
		return null
	return probe


## 量一次「1000 次跨语言小调用」vs「1 次 1000 元素的批量调用」。
## 这两个数字之比就是内核接口必须按批划的理由。
func _report_granularity(probe) -> void:
	var rounds := 10

	# 1000 次「一个 double 进、一个 double 出」
	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for _r in rounds:
		for _i in N:
			acc += probe.AddScalar(1.0, 2.0)
	var small_us := float(Time.get_ticks_usec() - t0) / float(rounds)

	# 1 次「1000 个元素进、一个 double 出」
	var values := PackedFloat64Array()
	values.resize(N)
	for i in N:
		values[i] = 3.0
	var t1 := Time.get_ticks_usec()
	var acc2 := 0.0
	for _r in rounds:
		acc2 += probe.SumDoubles(values)
	var bulk_us := float(Time.get_ticks_usec() - t1) / float(rounds)

	ok(acc > 0.0 and acc2 > 0.0, "粒度测试两条路都真的执行了")
	print("[BENCH] csharp call granularity (%d units):" % N)
	print("[BENCH]   %d x small call : %8.1f us/frame  (= %.3f us/call)" % [N, small_us, small_us / float(N)])
	print("[BENCH]   1 x bulk call   : %8.1f us/frame" % bulk_us)
	if bulk_us > 0.0:
		print("[BENCH]   ratio           : %8.1fx" % (small_us / bulk_us))
	print("[BENCH]   => kernel API must be batched, not per-unit")
