## test_time_step.gd —— **固定逻辑步长**（2026.10.28）的回归。
##
## 钉住三件事（这三件错了都会表现为「游戏整体变快 / 变慢 / 单位一抽一抽」）：
##   1. 步数换算：攒够才走、不多走、不少走；`max_steps` 夹住；没开时一步不走。
##   2. 长期不漂移：60 帧 × 1/60 秒、步长 1/30 ⇒ **恰好 30 步**（游戏速度不变）。
##   3. 插值口径：`begin_logic_step()` 只在开插值时记起点；
##      `render_pos_of()` 在 alpha = 0 / 0.5 / 1 时分别是「起点 / 中点 / 终点」。
##
## ⚠️ 这一份**不改 config.json 的默认值**（桌面默认 step_sec = 0 = 旧行为）——
##    前两组用例直接测纯函数，第三组用 `render_alpha` 手工驱动，所以跑在哪里都一样。
extends "res://tests/test_case.gd"

const Game3DRes = preload("res://view/game_scene3d.gd")
const WorldRes = preload("res://logic/world.gd")
const UnitRes = preload("res://logic/unit.gd")


func _initialize() -> void:
	_case_name = "test_time_step"
	run_all(_run)


func _run() -> void:
	_steps_basic()
	_steps_long_run()
	_interpolation()


## 1) 步数换算
func _steps_basic() -> void:
	var step: float = 1.0 / 30.0
	var frame: float = 1.0 / 60.0

	var a: Array = Game3DRes.take_logic_steps(0.0, step, 4)
	eq(int(a[0]), 0, "累加器为 0 ⇒ 这一步不走")
	near(float(a[1]), 0.0, 1e-9, "累加器为 0 ⇒ 剩余量仍是 0")

	a = Game3DRes.take_logic_steps(frame, step, 4)
	eq(int(a[0]), 0, "半帧（1/60）不够一步（1/30）⇒ 不走")
	near(float(a[1]), frame, 1e-9, "没走的那半帧必须原样留在累加器里")

	a = Game3DRes.take_logic_steps(step, step, 4)
	eq(int(a[0]), 1, "刚好一步 ⇒ 走一步")
	near(float(a[1]), 0.0, 1e-9, "走完一步后累加器归零")

	# 一帧攒了 3.5 步（就是卡了一下）⇒ 走 3 步，留下半步
	a = Game3DRes.take_logic_steps(step * 3.5, step, 4)
	eq(int(a[0]), 3, "攒了 3.5 步 ⇒ 走 3 步")
	near(float(a[1]), step * 0.5, 1e-6, "剩下半步留在累加器里")

	# 一次攒了 10 步（长时间卡顿）⇒ 被 max_steps 夹住，不一次补完
	a = Game3DRes.take_logic_steps(step * 10.0, step, 4)
	eq(int(a[0]), 4, "一帧最多补 4 步（sim.step_max_steps）")
	near(float(a[1]), step * 6.0, 1e-6, "没补完的部分留着（最多让游戏时间变慢，不放大卡顿）")

	# 关掉固定步长（step = 0）⇒ 一步不走、累加器不动
	a = Game3DRes.take_logic_steps(1.0, 0.0, 4)
	eq(int(a[0]), 0, "step = 0（未启用）⇒ 一步不走")
	near(float(a[1]), 1.0, 1e-9, "step = 0 时累加器原样返回")


## 2) 长期不漂移：这是「游戏速度」的唯一保证
func _steps_long_run() -> void:
	var step: float = 1.0 / 30.0
	var frame: float = 1.0 / 60.0
	var accum: float = 0.0
	var steps: int = 0
	for i in 60:
		accum += frame
		var pair: Array = Game3DRes.take_logic_steps(accum, step, 4)
		steps += int(pair[0])
		accum = float(pair[1])
	eq(steps, 30, "60 帧 × 1/60 s @ 30 Hz ⇒ 恰好 30 步（一秒就是一秒）")
	ok(accum < step, "剩余量始终小于一步（不会攒出额外的步）")

	# 渲染 120 fps + 逻辑 30 Hz ⇒ 4 帧一步，一秒仍是 30 步
	accum = 0.0
	steps = 0
	for i in 120:
		accum += 1.0 / 120.0
		var pair2: Array = Game3DRes.take_logic_steps(accum, step, 4)
		steps += int(pair2[0])
		accum = float(pair2[1])
	eq(steps, 30, "120 帧 × 1/120 s @ 30 Hz ⇒ 仍是 30 步（帧率不影响游戏速度）")


## 3) 插值口径：位置在两次逻辑步之间线性插值
func _interpolation() -> void:
	var cfg = load("res://logic/config.gd").load_default()
	ok(cfg != null, "配置载入成功")
	if cfg == null:
		return
	var world = WorldRes.create(cfg, "res://data/maps/frontier/map.json", false)
	ok(world != null, "世界建起来了")
	if world == null:
		return
	var u = UnitRes.create(cfg, "t-1", "测试兵", Vector2i(5, 5), world.my_faction, "spearman")
	world.units.append(u)
	u.pos = Vector2(10.0, 10.0)
	u.prev_pos = Vector2(10.0, 10.0)

	# 没开插值（默认）：`render_pos_of` 必须原样返回 u.pos
	eq(world.render_alpha, 1.0, "默认 render_alpha = 1（不插值）")
	eq(world.render_pos_of(u), u.pos, "alpha = 1 ⇒ 直接返回 u.pos（与旧版逐位一致）")

	# alpha = 1 时 begin_logic_step 不该写任何东西
	u.prev_pos = Vector2(99.0, 99.0)
	world.begin_logic_step()
	eq(u.prev_pos, Vector2(99.0, 99.0), "alpha = 1 ⇒ begin_logic_step 不写 prev_pos（零开销短路）")

	# 开插值：记起点 → 单位往前走 → 三个 alpha 点上的位置
	world.render_alpha = 0.0
	world.begin_logic_step()
	eq(u.prev_pos, Vector2(10.0, 10.0), "begin_logic_step 把当前位置记成插值起点")
	u.pos = Vector2(12.0, 10.0)
	v2_near(world.render_pos_of(u), Vector2(10.0, 10.0), 1e-5, "alpha = 0 ⇒ 画在起点")
	world.render_alpha = 0.5
	v2_near(world.render_pos_of(u), Vector2(11.0, 10.0), 1e-5, "alpha = 0.5 ⇒ 画在两点中间")
	world.render_alpha = 1.0
	v2_near(world.render_pos_of(u), Vector2(12.0, 10.0), 1e-5, "alpha = 1 ⇒ 画在终点")
