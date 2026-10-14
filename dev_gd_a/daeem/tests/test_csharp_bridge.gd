## test_csharp_bridge.gd —— 阶段 0/1：C# 通路验证 + 与 GDScript 版的等价性
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

	eq(probe.BuildTag(), "daeem-csharp-bridge-1", "C# 程序集已加载且标记匹配")
	eq(probe.Ping(), 42, "C# 实例方法可调用")

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

	_report_granularity(probe)

	_test_kernel_is_active(cfg)
	_test_collision_matches_gdscript(cfg)
	_test_targeting_matches_gdscript(cfg)
	_test_targeting_with_filtered_units(cfg)
	_test_no_friendly_fire(cfg)

func _test_no_friendly_fire(cfg) -> void:
	var w = require_world(cfg)
	if w.crowd == null or not w.crowd.available():
		ok(false, "C# 索敌内核可用（友军误伤是内核结果的下标映射问题）")
		return

	var batch: Array = []
	for i in 4:
		var u = UnitRes.create(cfg, "ff-a-%d" % i, "a", Vector2i(0, 0), "p1", UnitRes.UNIT_TYPE_SPEARMAN)
		u.pos = Vector2(10.5, 8.5 + float(i) * 0.5)
		u.sync_tile(w.map)
		batch.append(u)
	for i in 4:
		var e = UnitRes.create(cfg, "ff-b-%d" % i, "b", Vector2i(0, 0), "enemy", UnitRes.UNIT_TYPE_SPEARMAN)
		e.pos = Vector2(12.5, 8.5 + float(i) * 0.5)
		e.sync_tile(w.map)
		batch.append(e)
	batch[1].moving = true
	batch[1].has_goal = true
	w.units = batch

	w.tick(DT)

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

func _test_targeting_with_filtered_units(cfg) -> void:
	var w = require_world(cfg)
	w.tick(DT)                       # 先建表

	var fake_path: Array[Vector2] = [Vector2(8.0, 18.0)]
	var batch: Array = []
	for i in 30:
		var m = UnitRes.create(cfg, "flt-m%d" % i, "m", Vector2i(0, 0), "p1", UnitRes.UNIT_TYPE_SPEARMAN)
		m.pos = Vector2(6.0 + float(i % 6) * 0.4, 20.0 + float(i / 6) * 0.4)
		m.sync_tile(w.map)
		m.moving = true
		m.has_goal = true
		m.path = fake_path
		batch.append(m)

	var spot := Vector2(10.5, 10.5)
	var watcher = UnitRes.create(cfg, "flt-w", "w", Vector2i(0, 0), "p1", UnitRes.UNIT_TYPE_SPEARMAN)
	watcher.pos = spot
	watcher.sync_tile(w.map)
	batch.append(watcher)

	var want = UnitRes.create(cfg, "flt-e0", "e", Vector2i(0, 0), "enemy", UnitRes.UNIT_TYPE_SPEARMAN)
	want.pos = spot + Vector2(1.5, 0.0)
	want.sync_tile(w.map)
	want.moving = true
	batch.append(want)
	for i in 2:
		var far = UnitRes.create(cfg, "flt-e%d" % (i + 1), "e", Vector2i(0, 0), "enemy", UnitRes.UNIT_TYPE_SPEARMAN)
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

func _test_targeting_matches_gdscript(cfg) -> void:
	var w = require_world(cfg)
	if w.crowd == null or not w.crowd.available():
		ok(false, "C# 索敌内核可用")
		return

	var batch: Array = []
	for i in 12:
		var u = UnitRes.create(cfg, "tg-a-%d" % i, "a", Vector2i(0, 0), "p1", UnitRes.UNIT_TYPE_SPEARMAN)
		u.pos = Vector2(4.0 + float(i % 4) * 1.3, 6.0 + float(i / 4) * 1.1)
		u.sync_tile(w.map)
		batch.append(u)
	for i in 12:
		var e = UnitRes.create(cfg, "tg-b-%d" % i, "b", Vector2i(0, 0), "enemy", UnitRes.UNIT_TYPE_SPEARMAN)
		e.pos = Vector2(5.1 + float(i % 4) * 1.3, 7.2 + float(i / 4) * 1.1)
		e.sync_tile(w.map)
		batch.append(e)
	w.units = batch

	w.tick(DT)                       # 让 refresh_targets 跑一次（结果按 frame_serial 对齐）

	var kernel_pick: Array = []
	for i in w.units.size():
		var t = w.crowd.target_at(w, i)
		kernel_pick.append(-1 if t == null else w.units.find(t))

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

func _test_kernel_is_active(cfg) -> void:
	var w = require_world(cfg)
	ok(w.crowd != null, "world 建出了碰撞桥")
	if w.crowd == null:
		return
	ok(w.crowd.available(), "★ C# 碰撞内核可用（说明跑的是加速路径，不是 GDScript 回退）")
	eq(cfg.str_val("unit.collision_backend", "csharp"), "csharp", "config 默认走 C# 后端")

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
	cfg.unit_collision_backend = backend
	var w = require_world(cfg)
	var batch: Array = []
	for i in 8:
		var u = UnitRes.create(
			cfg, "eq-%d" % i, "eq", Vector2i(2, 13), w.my_faction, UnitRes.UNIT_TYPE_SPEARMAN
		)
		u.pos = Vector2(2.5 + float(i % 4) * 0.05, 13.5 + float(i / 4) * 0.04)
		u.sync_tile(w.map)
		batch.append(u)
	w.units = batch
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

func _report_granularity(probe) -> void:
	var rounds := 10

	var t0 := Time.get_ticks_usec()
	var acc := 0.0
	for _r in rounds:
		for _i in N:
			acc += probe.AddScalar(1.0, 2.0)
	var small_us := float(Time.get_ticks_usec() - t0) / float(rounds)

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
