## test_unit_backend_equiv.gd —— **单位循环两种后端（GDScript / C#）的逐字段等价测试**。
##
## ★★ 这个文件是「把单位循环下沉到 C#」的**红绿灯**，先说清它的三层作用：
##   1. **确定性**（默认就跑）：两个同种子、同后端的同关卡世界，跑 N 帧后逐字段一致。
##      这一层不过，任何等价测试都没有意义 —— 世界本身都不确定，还谈什么「两个后端一样」。
##   2. **等价性**（内核实装后自动生效）：一边 GDScript、一边 C#，逐帧推进、逐字段比对。
##      判据是**完全相等**（`==`，不是容差）：同一组 double 运算按同样顺序做，结果必须逐位相同。
##      允许容差就等于允许「两个后端各算各的」，那正是这个测试要防的事。
##   3. **后端真的生效了吗**：`world.unit_sim_used` 读的是**实际**跑的后端。
##      配了 csharp 却回退成 gdscript 时，等价测试会「绿得毫无意义」——
##      所以这里显式断言它（`DAEEM_UNIT_BACKEND=csharp` 时强制要求真跑 C#）。
##
## 用法：
##   godot --headless --path . --script res://tests/test_unit_backend_equiv.gd
##   $env:DAEEM_UNIT_BACKEND="csharp"   # 强制要求 C# 后端真的生效（未实装时本测试会红）
extends "res://tests/test_case.gd"

const LevelRes = preload("res://logic/level.gd")
const WorldRes = preload("res://logic/world.gd")

const LEVEL := "res://data/campaigns/demo/levels/dscj.json"
const DT := 1.0 / 60.0
const FRAMES := 240
const SEED := 4242


func _initialize() -> void:
	_case_name = "unit_backend_equiv"
	run_all(_cases)


func _cases() -> void:
	var cfg = require_config()
	if cfg == null:
		return
	var want: String = OS.get_environment("DAEEM_UNIT_BACKEND")
	if want == "":
		want = "gdscript"

	var a = _make_world(cfg)
	var b = _make_world(cfg)
	if a == null or b == null:
		ok(false, "两个世界都能建出来（%s）" % LEVEL)
		return
	ok(a.units.size() == b.units.size(), "两个世界的单位数一致（%d）" % a.units.size())
	ok(a.units.size() >= 100, "用的是够大的关卡（%d 单位）" % a.units.size())

	# ── 逐帧推进：两边各自用自己的后端（cfg 是共享对象，所以按「跑之前」切） ──
	for i in FRAMES:
		cfg.unit_sim_backend = "gdscript"
		a.tick(DT)
		cfg.unit_sim_backend = want
		b.tick(DT)

	eq(a.unit_sim_used, "gdscript", "A 世界跑的是 GDScript 后端")
	if want == "csharp":
		# ★ 这一条是"别绿得毫无意义"的闸门：配了 csharp 就必须真跑 csharp。
		#   后缀标明**下沉到哪一步**了（当前是 `csharp(morale)`；整段搬完会是 `csharp(units)`）。
		ok(String(b.unit_sim_used).begins_with("csharp"),
			"B 世界**真的**跑在 C# 后端上（实际 %s）" % String(b.unit_sim_used))
	else:
		eq(b.unit_sim_used, "gdscript", "B 世界跑的是 GDScript 后端（当前默认）")

	# ── 逐字段比对 ──
	var mism := 0
	var first := ""
	var b_by_id: Dictionary = {}
	for u in b.units:
		b_by_id[String(u.id)] = u
	for ua in a.units:
		var ub: Variant = b_by_id.get(String(ua.id), null)
		if ub == null:
			mism += 1
			if first == "":
				first = "%s：B 世界没有这个单位" % String(ua.id)
			continue
		var d: String = _diff(ua, ub)
		if d != "":
			mism += 1
			if first == "":
				first = "%s：%s" % [String(ua.id), d]
	eq(mism, 0, "逐字段等价（%d 帧后 0 处不同%s）" % [
		FRAMES, "" if first == "" else "；第一处 = " + first])

	# ── 事件条数（同种子 + 同规则 ⇒ 必须一样） ──
	ok(a.frame_serial == b.frame_serial, "帧序号一致（%d / %d）" % [a.frame_serial, b.frame_serial])
	near(a.time, b.time, 1e-9, "世界时间一致（%.4f / %.4f）" % [a.time, b.time])

	# ── 诊断：把 256 个单位的状态打包成数组要多久（决定"分片下沉"值不值） ──
	_pack_cost_probe(cfg, a)


## 两个单位在这一帧**必须完全相同**的字段。返回 "" = 一致，否则返回第一处不同。
##
## ★ 选字段的原则：这些是「单位循环的输出」——位置 / 血量 / 士气 / 移动意图 / 目标 / 计时器。
##   玩家的 UI 状态（选中、悬停）不在这里：它们不属于逻辑层。
func _diff(ua, ub) -> String:
	if (ua.pos as Vector2) != (ub.pos as Vector2):
		return "pos %s != %s" % [str(ua.pos), str(ub.pos)]
	if int(ua.tx) != int(ub.tx) or int(ua.ty) != int(ub.ty):
		return "tile (%d,%d) != (%d,%d)" % [int(ua.tx), int(ua.ty), int(ub.tx), int(ub.ty)]
	if float(ua.hp) != float(ub.hp):
		return "hp %.6f != %.6f" % [float(ua.hp), float(ub.hp)]
	if float(ua.morale) != float(ub.morale):
		return "morale %.6f != %.6f" % [float(ua.morale), float(ub.morale)]
	if bool(ua.moving) != bool(ub.moving):
		return "moving %s != %s" % [str(ua.moving), str(ub.moving)]
	if ua.path.size() != ub.path.size():
		return "path %d != %d" % [ua.path.size(), ub.path.size()]
	if float(ua.attack_cd) != float(ub.attack_cd):
		return "attack_cd %.6f != %.6f" % [float(ua.attack_cd), float(ub.attack_cd)]
	if float(ua.hit_flash) != float(ub.hit_flash):
		return "hit_flash %.6f != %.6f" % [float(ua.hit_flash), float(ub.hit_flash)]
	if float(ua.repath_timer) != float(ub.repath_timer):
		return "repath_timer %.6f != %.6f" % [float(ua.repath_timer), float(ub.repath_timer)]
	if bool(ua.alive) != bool(ub.alive):
		return "alive %s != %s" % [str(ua.alive), str(ub.alive)]
	var ta := "" if ua.target == null else String(ua.target.id)
	var tb := "" if ub.target == null else String(ub.target.id)
	if ta != tb:
		return "target '%s' != '%s'" % [ta, tb]
	var ba := "" if ua.target_building == null else "%s@%d,%d" % [
		String(ua.target_building.type), int(ua.target_building.tx), int(ua.target_building.ty)]
	var bb := "" if ub.target_building == null else "%s@%d,%d" % [
		String(ub.target_building.type), int(ub.target_building.tx), int(ub.target_building.ty)]
	if ba != bb:
		return "building '%s' != '%s'" % [ba, bb]
	return ""


## 把 N 个单位的核心状态打包进 Packed 数组要多久（µs/单位）。
##
## ★★ 这条探针的意义：它决定「分片下沉」可不可行 ——
##   如果打包成本已经接近被下沉那段的成本，那分片就是白干，
##   只能把**整段决策**搬过去（这也是 `config.unit_sim_backend` 的注释里写的那条结论）。
func _pack_cost_probe(cfg, w) -> void:
	var n: int = w.units.size()
	if n <= 0:
		return
	var iters := 20
	var t0 := Time.get_ticks_usec()
	for _k in iters:
		var px := PackedFloat64Array()
		var py := PackedFloat64Array()
		var hp := PackedFloat64Array()
		var mo := PackedFloat64Array()
		var idx := PackedInt32Array()
		px.resize(n)
		py.resize(n)
		hp.resize(n)
		mo.resize(n)
		idx.resize(n)
		var i := 0
		for u in w.units:
			px[i] = u.pos.x
			py[i] = u.pos.y
			hp[i] = u.hp
			mo[i] = u.morale
			idx[i] = int(u.tx)
			i += 1
	var us: float = float(Time.get_ticks_usec() - t0) / float(iters)
	print("[equiv] 打包 %d 个单位（5 条数组）≈ %.0f µs/帧（%.2f µs/单位）" % [
		n, us, us / float(n)])
	print("[equiv] 对照：士气的 GDScript 全程 ≈ 2.4 µs/单位 ⇒ 分片下沉的收益上限很低")


func _make_world(cfg):
	var lv = LevelRes.load_level(null, LEVEL, cfg)
	if lv == null:
		return null
	return WorldRes.create_from_level(cfg, lv, "F1", ["F1", "F2"], true, {}, {}, SEED)
